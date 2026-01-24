# PG-1 (Cook 미니게임) 구현 체크리스트

**Version**: v1.6.4
**Created**: 2026-01-20
**Updated**: 2026-01-25
**Status**: 🔒 **PG-1 Core SEALED** (S-01~S-11, C-01~C-08), 🔶 **PG-1.1 Gate 1st DONE** (S-15/C-10)
**Changes**: v1.6.4 - Gate 1st commit 완료 (S-15/C-10), FallbackReason+Phase 고정
**Previous**: v1.6.3 - Gate 템플릿 적용
**Reference**: `FoodTruck_Fun_Replication_Roadmap_v0.3.2.md` §2

---

## PG-1.1 Audit Decision (Official)

```
[AUDIT_DECISION] PG-1.1 Option B (Minigame + CookTimePhase(duration) 분리) = APPROVED
[AUDIT_DECISION] CraftSpeed 적용 = CookTimePhase duration만 단축(a) APPROVED
[AUDIT_GATE] S-15/C-10(응답·로그 의미 분리) = REQUIRED FIRST COMMIT
[AUDIT_SCOPE] PG-1 Core(S-01~S-11, C-01~C-08) = UNCHANGED / SEALED 유지
[AUDIT_DATE] 2026-01-25 KST / Auditor: ChatGPT
```

**Evidence Repo**: [Presiding-over](https://github.com/atrois22-afk/Presiding-over)
**공정성 고정**: 게이지 난이도/속도는 모든 플레이어 동일(스킬 기반)

---

## 0. 사전 조건 확인

- [x] Roadmap v0.3.2 최종 승인 확인
- [x] CraftingService.lua 현재 상태 파악
- [x] GameData.lua 난이도별 레시피 매핑 확인

---

## 1. 서버 구현 (Server/Services/)

### 1.1 CraftingService 확장

> ⚠️ **구현 순서 중요**: S-01 → S-02 → S-03 → S-04 → S-05 순서로 구현
> (seed/startTime 고정 → 판정 로직 → 보호 구간 → 제출 처리)

- [x] **S-01**: `StartCookSession(player, slotId, recipeId, playerData)` 함수 추가
  - 세션 생성 (sessionId, seed, serverStartTime, gaugeSpeed, uiTargetZone)
  - CraftSpeed 업그레이드 적용: `speedMultiplier = max(0.6, 0.9^(level-1))`
  - Max Level = 5 가드레일 적용 (PGConfig.CRAFTSPEED_MAX_LEVEL)
  - isTutorial 플래그 설정 (`not playerData.tutorialComplete`)

- [x] **S-02**: 세션 저장 구조 정의 *(seed/startTime 먼저 고정)*
  ```lua
  CookSessions[userId][slotId] = {
      sessionId = string,       -- GUID
      recipeId = number,
      seed = number,            -- 1 ~ 2^31-1
      serverStartTime = number, -- os.clock() (내부 전용, 클라 미노출)
      gaugeSpeed = number,
      uiTargetZone = {number, number},  -- UI 표시용 목표 영역
      initialDirection = number, -- 1 or -1
      isTutorial = bool,
      expiresAt = number,       -- os.clock() + TTL
      consumed = bool,
  }
  ```

- [x] **S-03**: `CalculateJudgment(gaugePos, uiTargetZone, gaugeSpeed, toleranceWindowMs, isTutorial)` 함수 추가
  - JUDGMENT_ZONES 적용 (튜토리얼 ±8, 일반 ±5)
  - 허용 윈도우 보정 적용 (`toleranceWindowMs` = 고정값 80ms, 실제 RTT 아님)
  - Perfect/Great/Good/OK/Bad 판정 반환
  - **Note**: 판정은 `JUDGMENT_ZONES` 기준(중심 거리), `uiTargetZone`은 중앙값 계산용

- [x] **S-04**: `ApplyProtection(serverJudgment, clientJudgment, serverGaugePos)` 함수 추가
  - PROTECTION_EPSILON = 1
  - Perfect→Great 다운 시 중심 ±1 보호

- [x] **S-05**: `SubmitCookTap(player, slotId, clientJudgment)` 함수 추가 *(마지막에 통합)*
  - 서버 독립 게이지 재현 (seed + elapsed)
  - `CalculateJudgment()` 호출
  - `ApplyProtection()` 호출
  - cookScore 계산 및 반환

### 1.2 RemoteHandler 확장

> **Contract 확정 (감리자 2026-01-20)**

- [x] **S-06**: `RE_CraftItem` 응답 확장 (Mode 분기)
  - Feature Flag ON: `Mode = "cook_minigame"` + `CookSession` 포함
  - Feature Flag OFF: `Mode = "timer"` + 기존 `CraftTime` (fallback)
  ```lua
  -- cook_minigame 모드 응답
  {
      Success = true,
      SlotId = 1,
      RecipeId = 123,
      Mode = "cook_minigame",
      CookSession = {
          SessionId = "GUID",
          Seed = 123456789,
          GaugeSpeed = 100.0,
          UiTargetZone = {40, 60},
          IsTutorial = true,
          Ttl = 90,
      },
      Updates = { Inventory = {...} },
  }
  ```

- [x] **S-07**: `RE_SubmitCookTap` 이벤트 추가
  - Request: `(slotId, sessionId, clientJudgment)`
  - Response:
  ```lua
  {
      Success = true,
      SlotId = 1,
      SessionId = "GUID",
      ServerGaugePos = 51.2,
      Judgment = "Great",
      CookScore = 0.9,
      Corrected = true,
      Updates = { CraftingState = {...} },
  }
  ```

- [x] **S-08**: Error Code 매핑 (상태머신 필수 처리)
  | Error | NoticeCode | 클라 UX |
  |-------|------------|---------|
  | `session_already_active` | `cook_already_active` | "이미 조리 중" 토스트 |
  | `session_expired` | `cook_session_expired` | "시간 초과" + 재시도 |
  | `session_not_found` | `cook_session_error` | UI 종료 + 재시도 |
  | `session_consumed` | `cook_already_submitted` | 중복 탭 무시 |
  | `feature_disabled` | - | timer fallback |

### 1.3 텔레메트리 (ProductionLogger 확장)

- [x] **S-09**: `COOK_JUDGMENT` 로그 포인트 추가
  - uid_hash, recipeId, serverJudgment, clientJudgment, corrected, isTutorial
  - (선택) rtt_ms - 클라에서 측정 시

### 1.4 방어 로직 (감리자 승인 2026-01-25)

- [x] **S-10**: `SetCookScore` STALE_COOK_SESSION 방어 추가
  - 기존 sessionId와 다른 요청 시 거부 (`return false, "STALE_COOK_SESSION"`)
  - 정책: 실패 시 기본값 1.0 적용 (게임 진행 보장)
  - 로그: `STALE_COOK_SESSION userId=... slot=... incoming=... existing=...`

### 1.5 SEALED 예외 핫픽스 (P0)

> ⚠️ **S-11**: SEALED 예외 적용 (cook_minigame dish 미생성 P0 버그)
> **승인**: ChatGPT (2026-01-25), A/B delta 테스트로 근거 확인 후 승인

- [x] **S-11**: `SubmitCookTap` dish 생성 로직 추가
  - **문제**: cook_minigame 모드에서 CraftItem이 return early → dish 생성 스킵
  - **해결**: SubmitCookTap success=true 확정 시점에 dish 생성 + SendCraftComplete 호출
  - **테스트**: BEFORE_TAP dishCount=0 → AFTER_TAP dishCount=1 (delta=1 확인)
  - **로그**: `S-11|COOK_DISH_CREATED uid=... slot=... dishKey=...`
  - **파일**: `Server/Services/CraftingService.lua`

---

## 2. 클라이언트 구현 (Client/)

### 2.1 UI 컴포넌트 (Client/UI/)

> **구현 완료**: 2026-01-25, `Client/UI/CookGaugeUI.lua` 신규 생성

- [x] **C-01**: `CookGaugeUI.lua` 신규 생성
  - 게이지 바 (0~100)
  - 판정 영역 색상 표시 (Perfect 초록, Good 노랑, OK 주황, Bad 빨강)
  - 패널 크기: 420x200px 고정 (UI 반응형 대응)

- [x] **C-02**: 게이지 애니메이션 구현
  - position += direction * speed * dt
  - 끝 도달 시 direction 반전

- [x] **C-03**: 터치/클릭 인터랙션
  - 50ms 이내 즉시 피드백 (임시 판정)
  - RE_SubmitCookTap 서버 전송 (slotId, sessionId 최소 페이로드)

- [x] **C-04**: 판정 결과 표시
  - Perfect/Great/Good/OK/Bad 텍스트 표시
  - 색상 차등: Perfect=초록, Good=노랑, Bad=빨강
  - 보정(corrected) 시 중립 연출 (TextTransparency 0.3)

### 2.2 클라이언트 로직 (ClientController 확장)

> **구현 완료**: 2026-01-25, `Client/ClientController.client.lua` 확장

- [x] **C-05**: 로컬 임시 판정 계산 (UI Only)
  - 서버 확정 전 애니메이션용
  - 점수/팁/진행에 영향 없음

- [x] **C-05a**: 서버 확정 도착 시 UI 교체 타이밍 *(감리자 지적 반영)*
  - CookTapResponse scope 수신 즉시 처리
  - ShowJudgment(judgment, wasCorrected) 호출

- [x] **C-05b**: 다운보정 애니메이션 규칙 *(감리자 지적 반영)*
  - corrected=true 시 중립 fade 효과 (TextTransparency 0.3)
  - 플레이어 불쾌감 최소화

- [x] **C-06**: 서버 확정 후 보정 처리
  - **정책**: clientJudgment 미전송(설계 선택) → corrected=true는 운영 플로우에서 비활성
  - **UI 처리**: corrected=true가 오면 NEUTRAL 연출 (Up/Down 구분 없음, Server=Truth 유지)
  - **검증**: Studio에서 일회성 Self-Test로 경로 확인 후 제거 (운영 코드 청결 유지)

- [x] **C-07**: 난이도별 게이지 속도 적용
  - 서버에서 전달받은 gaugeSpeed 그대로 사용
  - CraftSpeed 업그레이드 적용된 값 수신

- [x] **C-08**: Mode 분기 처리 (신규)
  - `Mode == "timer"` → 기존 프로그레스 바 흐름 + CookGaugeUI Hide
  - `Mode == "cook_minigame"` → CookGaugeUI:Show() 호출
  - **테스트**: FeatureFlags.COOK_MINIGAME_ENABLED=false 시 timer fallback 확인

---

## 3. 기존 코드 연동

### 3.1 CraftingService 기존 흐름 연결

- [x] **I-01**: `RE_CraftItem` 응답에서 Mode 분기
  - Feature Flag ON → `StartCookSession()` 호출 → `CookSession` 응답
  - Feature Flag OFF → 기존 `task.delay()` 타이머 흐름
  - **⚠️ 재료 차감 시점**: CraftItem 성공 시점 (=세션 시작 시점)에 즉시 차감
    - 미니게임 미완료/만료 시에도 재료 복구 없음 (기존 타이머와 동일한 정책)

  > **NOTE (재료 차감 정책)**
  > 중도 이탈/세션 만료 시 재료 환불 없음. 이는 기존 타이머 모드와 동일한 의도된 설계임.
  > 향후 정책 변경 시 본 항목과 `SubmitCookTap` 로직 동시 수정 필요.

- [ ] **I-02**: cookScore → 기존 채점 시스템 연동
  - Bad: cookScore × 0.25
  - 팁 감소 적용

### 3.2 GameData 연동

- [ ] **I-03**: 레시피 난이도별 게이지 설정 매핑
  - Easy/Medium/Hard → PGConfig.GAUGE_CONFIG 참조

---

## 4. Exit Criteria 검증 (PG1-01~08)

| # | Criteria | 검증 방법 | 상태 |
|---|----------|----------|------|
| PG1-01 | 게이지 UI | 화면에 게이지 표시됨 | ⬜ |
| PG1-02 | 왕복 동작 | 게이지가 끝에서 반전됨 | ⬜ |
| PG1-03 | 클릭 판정 | Perfect~Bad 5단계 판정 | ⬜ |
| PG1-04 | 난이도 차등 | Easy/Medium/Hard 속도 차이 | ⬜ |
| PG1-05 | 점수 연동 | 판정 → cookScore 반영 | ⬜ |
| PG1-06 | 서버 검증 | 서버 독립 재현 판정 | ⬜ |
| PG1-07 | Perfect 목표 | 튜토리얼 80% 달성 가능 | ⬜ |
| PG1-08 | 응답 시간 | 클라 <50ms, 서버 <300ms | ⬜ |

---

## 5. 테스트 시나리오

### 5.1 기본 동작

- [ ] **T-01**: 미니게임 시작 → 게이지 표시
- [ ] **T-02**: 클릭 → 판정 표시 → 게이지 정지
- [ ] **T-03**: 판정별 점수 차등 확인

### 5.2 서버 검증

- [ ] **T-04**: 클라/서버 판정 일치 (정상 케이스)
- [ ] **T-05**: 클라/서버 판정 불일치 → 보정 처리
- [ ] **T-06**: Perfect 보호 구간 동작 확인

### 5.3 업그레이드 연동

- [ ] **T-07**: CraftSpeed Lv1 vs Lv5 게이지 속도 차이
- [ ] **T-08**: Max Level 가드레일 (Lv6+ = 하한선)

### 5.4 엣지 케이스

- [ ] **T-09**: 튜토리얼 중 미니게임 (±8 윈도우)
- [ ] **T-10**: 고정 허용 윈도우(TOLERANCE_WINDOW_MS=80) 적용으로 판정 관대화 확인
  - 예시: `speed=100, toleranceWindow=80ms → 보정거리 = (80/1000) × 100 × 0.5 = 4.0`

---

## 6. 완료 기준

모든 항목 체크 시 PG-1 SEALED:

- [ ] Exit Criteria 8개 모두 PASS
- [ ] 테스트 시나리오 10개 모두 PASS
- [ ] 기존 저장/로드 회귀 없음 확인
- [ ] 감리자 최종 승인

---

## 7. Self-Test 템플릿 (Studio Command Bar)

> **실행 주체**: User (Owner)
> **실행 환경**: Roblox Studio (Play 모드 또는 Command Bar)
> **목적**: S-10 STALE_COOK_SESSION 방어 로직 검증

### 7.1 정상 케이스 (Set → Get 소비 → Get 기본값)

```lua
-- Studio Command Bar에서 실행
local OS = require(game.ServerScriptService.Server.Services.OrderService)
local userId = 12345
local slotId = 1

-- 1. Set
print("=== TEST: Normal Case ===")
local success1 = OS:SetCookScore(userId, slotId, 0.9, "session-abc")
print("Set result:", success1)

-- 2. Get (소비)
local score1 = OS:GetCookScore(userId, slotId)
print("Get #1 (expect 0.9):", score1)

-- 3. Get 다시 (삭제됨, 기본값)
local score2 = OS:GetCookScore(userId, slotId)
print("Get #2 (expect 1.0):", score2)
```

**기대 출력:**
```
=== TEST: Normal Case ===
[OrderService] COOKSCORE_SET userId=12345 slot=1 score=0.90 sessionId=session-abc
Set result: true
Get #1 (expect 0.9): 0.9
Get #2 (expect 1.0): 1.0
```

### 7.2 STALE 인위 케이스 (다른 sessionId로 덮어쓰기 시도)

```lua
-- Studio Command Bar에서 실행
local OS = require(game.ServerScriptService.Server.Services.OrderService)
local userId = 12345
local slotId = 1

-- 1. 기존 값 설정
print("=== TEST: STALE Case ===")
OS:SetCookScore(userId, slotId, 0.9, "session-abc")

-- 2. 다른 sessionId로 덮어쓰기 시도
local success, reason = OS:SetCookScore(userId, slotId, 0.7, "session-xyz")
print("STALE Set result:", success, reason)
```

**기대 출력:**
```
=== TEST: STALE Case ===
[OrderService] COOKSCORE_SET userId=12345 slot=1 score=0.90 sessionId=session-abc
[OrderService] STALE_COOK_SESSION userId=12345 slot=1 incoming=session-xyz existing=session-abc  (warn)
STALE Set result: false STALE_COOK_SESSION
```

### 7.3 결과 공유 시 필수 항목

테스트 완료 후 아래 로그를 복사하여 공유:

| 케이스 | 필수 로그 |
|--------|----------|
| 정상 | `COOKSCORE_SET` + `Get #1` + `Get #2` 값 |
| STALE | `STALE_COOK_SESSION` warn + `success=false` |

---

## 8. PG-1.1 Extension (v1.6.3) — CraftSpeed 의미 일관성 (CookTimePhase 분리)

> **Scope**: PG-1.1 Extension (신규 스코프)
> **Core SEALED 유지**: PG-1 Core (S-01~S-11, C-01~C-08) 변경 금지
> **Design Decision (Auditor)**: Option B 승인 / CraftSpeed는 CookTimePhase duration만 단축
> **Priority Gate**: S-15/C-10 선행 고정 커밋이 **반드시 1순위**

### 8.1 승인 결정 (요약)

- [x] **[DECISION] Q1**: 완료 신호 분리 방식 = **A안 채택** (기존 CraftResponse 유지 + Phase/State 분리)
- [x] **[DECISION] Q2**: Fallback 트리거 = **Reason 기반 명시** (FallbackReason 없는 mode=timer는 fallback으로 간주하지 않음)
- [x] **[FAIRNESS]**: 게이지 난이도/속도는 모든 플레이어 동일(스킬 기반) 유지, CraftSpeed는 CookTimePhase duration 단축만 담당

### 8.2 FallbackReason (v1.6.3 Gate minimum)

```
- FEATURE_DISABLED
```

**Policy:**
- Timer fallback is defined as: `mode="timer" AND FallbackReason != nil`
- CookTimePhase must never use `mode="timer"` and must never include FallbackReason
- v1.6.3 fixes the minimum reason set to `FEATURE_DISABLED`; reasons may be extended later without changing the fallback predicate

### 8.3 Priority Gate (FIRST COMMIT) ✅ DONE

> **Completion**: v1.6.4 (2026-01-25)
> **Auditor**: ChatGPT — APPROVED

#### Field Name Standard (v1.6.4 고정)

- 서버 필드명: `FallbackReason` (PascalCase) 표준
- 클라 normalize: `response.FallbackReason or response.fallbackReason` 호환 처리

#### Phase Minimum Guarantee (v1.6.4 고정)

- `cook_minigame` 응답: 최소 `Phase="MINIGAME_START"` 포함 (Gate 충족)
- CookTimePhase: 절대 `mode="timer"` 사용 금지 (v1.6.3 정책과 정합)

#### S-15 (Server) — Response Semantics Split ✅

- [x] **S-15**: CraftResponse의 의미 분리 고정
  - Timer fallback: `FallbackReason="FEATURE_DISABLED"` 추가
  - cook_minigame: `Phase="MINIGAME_START"` 추가
  - **금지**: CookTimePhase를 `mode="timer"`로 보내지 않음

  **Exit Evidence (FeatureFlag OFF → Fallback):**
  ```
  [Client] [C-10] CraftResponse mode=timer phase=nil fallbackReason=FEATURE_DISABLED slotId=1
  [Client] [C-10] TimerFallback mode=timer fallbackReason=FEATURE_DISABLED slotId=1
  [CookGaugeUI] Hide reason=MODE_TIMER_FALLBACK session=nil
  ```

  **Exit Evidence (FeatureFlag ON → Minigame):**
  ```
  [Client] [C-10] CraftResponse mode=cook_minigame phase=MINIGAME_START fallbackReason=nil slotId=1
  [CookGaugeUI] Show session=... speed=... target={...}
  ```

#### C-10 (Client) — UI Routing Split ✅

- [x] **C-10**: 클라이언트 3단 분기 고정
  - `mode="timer" AND FallbackReason != nil` → MODE_TIMER_FALLBACK
  - `mode="timer"` (no reason) → Legacy timer
  - `mode="cook_minigame"` → PG-1/PG-1.1 처리
  - **금지**: `mode="timer"` 단독 수신으로 fallback 처리

#### Gate 1st Commit Summary (v1.6.4)

| 항목 | 변경 | 파일 |
|------|------|------|
| S-15 | `FallbackReason="FEATURE_DISABLED"` 추가 | CraftingService.lua |
| S-15 | `Phase="MINIGAME_START"` 추가 | CraftingService.lua |
| C-10 | `fallbackReason` 정규화 추가 | ClientController.client.lua |
| C-10 | 3단 분기 (timer+reason, timer, cook_minigame) | ClientController.client.lua |

### 8.4 PG-1.1 Implementation (After Gate)

#### S-12 — Start CookTimePhase after SubmitCookTap success

- [ ] **S-12**: SubmitCookTap success=true 이후 CookTimePhase 시작
  - CookTimePhaseDuration 계산: `baseCookTime × CraftSpeed modifier`
  - `mode="cook_minigame"` 유지 + `Phase="COOK_TIME_START"` 응답 전송

#### S-13 — Apply CraftSpeed to CookTimePhase duration only

- [ ] **S-13**: CraftSpeed 적용 범위 고정
  - **적용**: CookTimePhaseDuration 단축
  - **비적용**: gaugeSpeed/난이도/타겟존

#### S-14 — Dish creation at CookTimePhase completion

- [ ] **S-14**: Dish 생성 시점 이동/고정
  - CookTimePhase COMPLETE 시점에 dishKey 증가 + SendCraftComplete 호출
  - PG-1 Core의 S-11 경로는 "보존"하되, PG-1.1 경로에서는 사용하지 않도록 분리

#### C-09 — UI transition: Minigame → CookTimePhase UI

- [ ] **C-09**: 미니게임 판정 표시 후 CookTimePhase UI로 전환
  - 판정 표시 최소 보장 시간(예: 0.6s) 후 전환(선택)

#### C-11 — CraftSpeed 체감/표시

- [ ] **C-11**: CookTimePhase UI에 duration 표시(또는 진행바) 반영
  - 최소 요구: duration이 CraftSpeed에 의해 단축됨을 UI/로그로 확인 가능

### 8.5 Known Risk (Non-blocking)

- **P2 재발 위험**: CookTapResponse/CraftResponse 순서 경쟁으로 판정 표시 스킵 가능
  - Gate(S-15/C-10)에서 의미 분리 고정 후 재평가

### 8.6 구현 순서 (REQUIRED)

1. **첫 커밋**: S-15/C-10 (응답·로그 의미 분리 키워드 고정)
2. **이후**: S-12 → S-13 → S-14 / C-09 → C-11 순서로 구현

---

**작성자**: Claude (Implementer)
**검토자**: ChatGPT (Auditor), User (Owner)
