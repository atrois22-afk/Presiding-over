# PG-1 cookScore Hook 구현 감리 요청

**Date**: 2026-01-24
**Scope**: S-06~S-09 완료 후 cookScore 연동 훅 구현
**Implementer**: Claude (Opus 4.5)

---

## 1. 구현 범위

### 1.1 이전 세션 완료 항목 (S-01~S-09)
- S-01~S-05: CraftingService Cook 미니게임 핵심 로직
- S-06: RE_CraftItem Mode 분기 (cook_minigame / timer)
- S-07: RE_SubmitCookTap 핸들러
- S-08: Error/NoticeCode 매핑
- S-09: ProductionLogger.LogCookJudgment 텔레메트리

### 1.2 본 세션 구현 항목 (cookScore Hook)
감리자 승인된 **Push 아키텍처** 기반 구현:

| 항목 | 파일 | 설명 |
|------|------|------|
| 저장소 | OrderService.lua | `OrderCookScores[userId][slotId]` 런타임 테이블 |
| Setter | OrderService.lua | `SetCookScore(userId, slotId, cookScore, sessionId)` |
| Getter | OrderService.lua | `GetCookScore(userId, slotId)` - 기본값 1.0, 읽은 후 삭제 |
| Cleanup | OrderService.lua | `CleanupPlayer`에서 전체 정리 |
| Push | CraftingService.lua | `SubmitCookTap` 성공 시 `SetCookScore` 호출 |
| Hook | OrderService.lua | `DeliverOrder`에서 `GetCookScore` 읽기 (I-02 팁 계산 준비) |

---

## 2. 아키텍처 결정 (감리자 확정)

### 2.1 Push vs Pull
- **결정**: Push (CraftingService -> OrderService)
- **이유**: 순환 의존성 방지 (OrderService가 CraftingService 참조 불필요)

### 2.2 런타임 vs 영구 저장
- **결정**: 런타임 전용 (DataStore 저장 X)
- **이유**:
  - Orphan 데이터 방지 (미완료 세션)
  - 불필요한 저장 비용 제거
  - 재접속 시 기본값 1.0 (timer 모드와 동일 취급)

### 2.3 1회성 소비
- **동작**: `GetCookScore` 호출 시 해당 슬롯 데이터 삭제
- **이유**: 동일 cookScore 중복 사용 방지

---

## 3. 변경 파일 상세

### 3.1 OrderService.lua

#### 추가: OrderCookScores 테이블 (Line 60-71)
```lua
--[[
    PG-1: Cook 미니게임 점수 저장 (런타임 전용)
    OrderCookScores[userId][slotId] = { cookScore = number, sessionId = string }
    ...
]]
local OrderCookScores = {}
```

#### 추가: CleanupPlayer 정리 (Line 272-275)
```lua
-- PG-1: cookScore 정리 (PlayerRemoving)
if OrderCookScores[userId] then
    OrderCookScores[userId] = nil
end
```

#### 추가: SetCookScore 함수 (Line 338-359)
```lua
function OrderService:SetCookScore(userId, slotId, cookScore, sessionId)
    -- 파라미터 검증, 테이블 초기화, 로그 출력
    OrderCookScores[userId][slotId] = { cookScore = cookScore, sessionId = sessionId }
    return true
end
```

#### 추가: GetCookScore 함수 (Line 367-375)
```lua
function OrderService:GetCookScore(userId, slotId)
    if OrderCookScores[userId] and OrderCookScores[userId][slotId] then
        local entry = OrderCookScores[userId][slotId]
        OrderCookScores[userId][slotId] = nil  -- 1회성 소비
        return entry.cookScore
    end
    return 1.0  -- 기본값
end
```

#### 추가: DeliverOrder 훅 (Line 1530-1544)
```lua
local cookScore = self:GetCookScore(userId, slotId)
-- TODO(I-02): cookScore 기반 팁 계산: tip = floor(reward * 0.25 * cookScore)
if cookScore ~= 1.0 then
    print(string.format("[OrderService] DELIVER_COOKSCORE uid=%d slot=%d cookScore=%.2f", ...))
end
```

### 3.2 CraftingService.lua

#### 추가: SetCookScore Push (Line 843-846)
```lua
-- 13. cookScore를 OrderService에 Push (DeliverOrder에서 사용)
if OrderService.SetCookScore and type(OrderService.SetCookScore) == "function" then
    OrderService:SetCookScore(userId, slotId, cookScore, session.sessionId)
end
```

---

## 4. 데이터 흐름

```
[클라이언트 탭]
       |
RE_SubmitCookTap
       |
CraftingService:SubmitCookTap
       | (cookScore 계산: Perfect=1.0, Great=0.9, ...)
       |
OrderService:SetCookScore(userId, slotId, cookScore, sessionId)
       |
OrderCookScores[userId][slotId] = { cookScore, sessionId }
       |
[클라이언트 납품]
       |
RE_DeliverOrder
       |
OrderService:DeliverOrder
       | GetCookScore (읽은 후 삭제)
       | tip 계산 (I-02에서 구현)
       |
[주문 완료]
```

---

## 5. 테스트 케이스 (Studio 검증 대기)

| # | 케이스 | 예상 결과 |
|---|--------|----------|
| T1 | Flag ON + 미니게임 완료 + 납품 | cookScore 정상 전달 |
| T2 | Flag OFF + 타이머 완료 + 납품 | cookScore = 1.0 (기본값) |
| T3 | 미니게임 완료 후 재접속 + 납품 | cookScore = 1.0 (런타임 휘발) |
| T4 | 미니게임 없이 납품 | cookScore = 1.0 (기본값) |
| T5 | session_expired 후 납품 | cookScore = 1.0 (세션 무효) |
| T6 | 플레이어 이탈 | OrderCookScores 정리 |

---

## 6. 미완료 항목

| 항목 | 상태 | 설명 |
|------|------|------|
| I-02 | 대기 | cookScore 기반 팁 계산 공식 적용 |
| I-03 | 대기 | 레시피 난이도별 게이지 설정 매핑 |
| C-01~C-08 | 대기 | 클라이언트 UI 구현 |

---

## 7. 검토 요청 사항

1. **Push 아키텍처 구현 정합성**: SetCookScore/GetCookScore 인터페이스
2. **1회성 소비 로직**: GetCookScore에서 삭제 타이밍
3. **기본값 정책**: 1.0 (timer 모드 동일 취급)
4. **로그 포맷**: COOKSCORE_SET, DELIVER_COOKSCORE

---

**Implementer**: Claude (Opus 4.5)
**Awaiting**: Auditor Review (ChatGPT)
