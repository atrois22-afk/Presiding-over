# PG-1 Cook 미니게임 - 전체 맥락 문서

**Date**: 2026-01-25
**For**: ChatGPT (Auditor) - 새 채팅방에서 전체 맥락 파악용
**From**: Claude (Implementer)

---

## 1. 프로젝트 배경

### 1.1 FoodTruck이란?
Roblox 기반 Food Truck Simulator 게임. Papa's 게임의 시스템을 복제하여 구현.

### 1.2 거버넌스
| 역할 | 담당 | 책임 |
|------|------|------|
| 설계 감리자 | ChatGPT | SSOT/Contract 준수 검토, 아키텍처 결정 |
| 구현 주체 | Claude | 코드 작성, 논리 오류 지적 |
| 총괄 시행사 | User | 최종 승인권 |

### 1.3 현재까지 완료된 Phase
- P0~P4: 기본 시스템 (주문, 배달, 제작, 업그레이드) SEALED
- W2~W3: 레시피 확장 (30개) SEALED
- P6-P2: Production Logging SEALED

### 1.4 PG (Fun Replication) 목표
Papa's의 **"시스템"** 뿐 아니라 **"재미"**(타이밍/정밀도)까지 복제

---

## 2. PG-1 Cook 미니게임 개요

### 2.1 핵심 컨셉
기존: 레시피 클릭 → 타이머 대기 → 완성
PG-1: 레시피 클릭 → **타이밍 게이지 미니게임** → 판정에 따른 품질

### 2.2 게이지 동작
- 0~100 범위에서 좌우 왕복
- 목표 영역(예: 40~60)에서 탭하면 높은 판정
- 판정: Perfect > Great > Good > OK > Bad

### 2.3 서버 권한 원칙
- 클라이언트 판정은 **임시 UI용**
- 서버가 **독립적으로 게이지 위치 계산** (seed + elapsed)
- 최종 판정은 서버 기준

---

## 3. 구현 완료 항목 (S-01 ~ S-09 + cookScore Hook)

### 3.1 CraftingService 확장 (S-01~S-05)

| 항목 | 함수 | 설명 |
|------|------|------|
| S-01 | StartCookSession | 세션 생성 (seed, gaugeSpeed, targetZone) |
| S-02 | CookSessions 구조 | 세션 데이터 저장 |
| S-03 | CalculateJudgment | 판정 계산 (튜토리얼 ±8, 일반 ±5) |
| S-04 | ApplyProtection | Perfect→Great 다운 시 보호 |
| S-05 | SubmitCookTap | 서버 독립 재현 + 판정 반환 |

### 3.2 RemoteHandler 확장 (S-06~S-07)

| 항목 | 내용 |
|------|------|
| S-06 | RE_CraftItem 응답에 Mode 분기 (cook_minigame / timer) |
| S-07 | RE_SubmitCookTap 핸들러 추가 |

### 3.3 Error/Notice 매핑 (S-08)

| Error | NoticeCode | 설명 |
|-------|------------|------|
| session_already_active | cook_already_active | 이미 조리 중 |
| session_expired | cook_session_expired | 시간 초과 |
| session_not_found | cook_session_error | 세션 없음 |
| session_consumed | cook_already_submitted | 중복 탭 |

### 3.4 텔레메트리 (S-09)
ProductionLogger.LogCookJudgment 추가

### 3.5 cookScore Hook (감리자 승인 Push 아키텍처)

**흐름:**
```
CraftingService:SubmitCookTap
    ↓ cookScore 계산 (Perfect=1.0, Great=0.9, ...)
    ↓
OrderService:SetCookScore(userId, slotId, cookScore, sessionId)
    ↓
OrderCookScores[userId][slotId] = { cookScore, sessionId }
    ↓
OrderService:DeliverOrder
    ↓ GetCookScore (읽은 후 삭제, 기본값 1.0)
    ↓ tip 계산 (I-02에서 구현 예정)
```

**설계 결정:**
- Push 방식 (CraftingService → OrderService) - 순환 의존성 방지
- 런타임 전용 (DataStore 저장 X) - Orphan 데이터 방지
- 1회성 소비 (GetCookScore 시 삭제) - 중복 사용 방지

---

## 4. 아키텍처 결정 사항

### 4.1 Feature Flag
```lua
-- FeatureFlags.lua
COOK_MINIGAME_ENABLED = false  -- 런타임 토글
```
- Flag ON: Mode = "cook_minigame" + CookSession 반환
- Flag OFF: Mode = "timer" + 기존 타이머 흐름 (fallback)

### 4.2 게이지 설정 (PGConfig.lua)
```lua
GAUGE_CONFIG = {
    Easy = { speed = 100, targetZone = {35, 65} },
    Medium = { speed = 133, targetZone = {40, 60} },
    Hard = { speed = 200, targetZone = {45, 55} },
}
```

### 4.3 판정 영역 (JUDGMENT_ZONES)
```lua
-- 중심으로부터의 거리
Perfect = 5,  -- 튜토리얼: 8
Great = 10,
Good = 15,
OK = 20,
-- 그 외 = Bad
```

### 4.4 점수 (JUDGMENT_SCORES)
```lua
Perfect = 1.0,
Great = 0.9,
Good = 0.7,
OK = 0.5,
Bad = 0.25,
```

---

## 5. 감리 논의 포인트

### 5.1 sessionId 검증 (감리자 지적)

**현재 구현:**
- SetCookScore에서 sessionId 저장만, 검증 없음

**Claude 반론:**
- CraftingService에서 이미 방어 (session.consumed 체크)
- SetCookScore까지 도달하는 건 정상 경로만
- 중복 검증은 관심사 분리 원칙 위반 가능성

**결정 대기**: 감리자 판단

### 5.2 GetCookScore 호출 타이밍 (감리자 지적)

**현재 구현:**
- DeliverOrder 내 reward 계산 직후 호출

**Claude 반론:**
- 해당 시점은 이미 모든 검증 완료 후
- 이후 실패 경로 없음 (사실상 성공 확정)

**결정 대기**: 감리자 판단

---

## 6. 미완료 항목

| 항목 | 상태 | 설명 |
|------|------|------|
| I-02 | 대기 | cookScore 기반 팁 계산 공식 |
| I-03 | 대기 | 레시피 난이도별 게이지 매핑 |
| C-01~C-08 | 대기 | 클라이언트 UI 구현 |

---

## 7. 파일 목록

| 파일 | 설명 |
|------|------|
| FoodTruck_Fun_Replication_Roadmap_v0.3.2.md | PG 전체 로드맵 |
| PG1_Implementation_Checklist.md | 체크리스트 (v1.3) |
| PGConfig.lua | 게이지/판정 설정 SSOT |
| FeatureFlags.lua | Feature Flag 정의 |
| CraftingService.lua | Cook 미니게임 핵심 로직 |
| OrderService.lua | cookScore Hook 구현 |
| RemoteHandler.lua | RE_SubmitCookTap 핸들러 |
| ProductionLogger.lua | 텔레메트리 (S-09) |

---

## 8. 검토 요청 사항

1. S-01~S-09 구현 정합성
2. cookScore Push 아키텍처 타당성
3. sessionId 검증 추가 필요 여부
4. GetCookScore 호출 타이밍 적절성

---

**Implementer**: Claude (Opus 4.5)
**Awaiting**: Auditor Review
