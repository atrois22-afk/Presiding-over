# CONTEXT — PG-1 Cook Minigame Audit Index

> Version: v1.8.0
> Updated: 2026-01-25
> Previous: v1.7.0 (PG-1 CLOSED, PG-2 Contract opened)

## Current Status

### PG-1 Core (SEALED)
| Scope | Items | Status |
|---|---|---|
| Server | S-01~S-11 | 🔒 SEALED |
| Client | C-01~C-08 | 🔒 SEALED |

### PG-1.1 Extension
| Scope | Items | Status |
|---|---|---|
| **Priority Gate** | S-15/C-10 | ✅ **DONE** (v1.6.4) |
| Server | S-12~S-14 | ✅ **DONE** (v1.6.5) |
| Client | C-09, C-11 | ✅ **DONE** (v1.6.6) |

Evidence (Public):
- PG1_Implementation_Checklist.md v1.6.6
- S-11 A/B delta: dishCount 0 -> 1
- C-08 timer fallback log
- C-06 corrected policy (disabled in prod)
- PG-1.1 Approval: ChatGPT (Auditor), 2026-01-25
- Gate 1st commit: S-15/C-10 (FallbackReason + Phase)
- S-12~S-14: CookTimePhase server implementation
- **C-09/C-11 (v1.6.6)**: MainHUD wrapper functions + UI transition

### PG-1 Integration (Pending)
| Item | Description | Status |
|---|---|---|
| I-02 | cookScore -> tip calculation | Pending |
| I-03 | recipe <-> difficulty mapping | Pending |

## PG-1.1 Audit Decision (Official)

```
[AUDIT_DECISION] PG-1.1 Option B (Minigame + CookTimePhase(duration) 분리) = APPROVED
[AUDIT_DECISION] CraftSpeed 적용 = CookTimePhase duration만 단축(a) APPROVED
[AUDIT_GATE] S-15/C-10(응답·로그 의미 분리) = REQUIRED FIRST COMMIT
[AUDIT_SCOPE] PG-1 Core(S-01~S-11, C-01~C-08) = UNCHANGED / SEALED 유지
[AUDIT_DATE] 2026-01-25 KST / Auditor: ChatGPT
```

**공정성 고정**: 게이지 난이도/속도는 모든 플레이어 동일(스킬 기반)

## Gate 1st Commit (v1.6.4) ✅ DONE

> **Completion**: 2026-01-25
> **Auditor**: ChatGPT — APPROVED

### Field Name Standard
- 서버: `FallbackReason` (PascalCase) 표준
- 클라: `response.FallbackReason or response.fallbackReason` 호환

### Phase Minimum Guarantee
- `cook_minigame`: 최소 `Phase="MINIGAME_START"` 포함
- CookTimePhase: 절대 `mode="timer"` 사용 금지

### Exit Evidence (Fallback)
```
[Client] [C-10] CraftResponse mode=timer phase=nil fallbackReason=FEATURE_DISABLED slotId=1
[Client] [C-10] TimerFallback mode=timer fallbackReason=FEATURE_DISABLED slotId=1
```

### Exit Evidence (Minigame)
```
[Client] [C-10] CraftResponse mode=cook_minigame phase=MINIGAME_START fallbackReason=nil slotId=1
```

## FallbackReason (v1.6.3 Gate minimum)

```
- FEATURE_DISABLED
```

**Policy:**
- Timer fallback is defined as: `mode="timer" AND FallbackReason != nil`
- CookTimePhase must never use `mode="timer"` and must never include FallbackReason
- v1.6.3 fixes the minimum reason set to `FEATURE_DISABLED`; reasons may be extended later without changing the fallback predicate

## SEALED Exception Hotfix — S-11

- Issue (P0): cook_minigame path missing dish creation/completion signal
- Cause: cook_minigame CraftItem early return skips timer complete path (SendCraftComplete)
- Fix: SubmitCookTap success=true triggers dish creation + SendCraftComplete
- Approved: ChatGPT (Auditor), 2026-01-25 (A/B delta evidence)

## SEALED Exception Hotfix — S-16

- Issue (P0): SubmitCookTap 실패 시 슬롯 영구 잠금
- Cause: too_early/too_late/session_expired 등 실패 경로에서 SetSlotLock(false) 미호출
- Fix: UnlockOnce 헬퍼 함수 + 모든 return 경로에서 슬롯 락 해제 보장
- Approved: ChatGPT (Auditor), 2026-01-25

Exit Evidence (S-16):
```
[CraftingService] S-16|SLOT_UNLOCK uid=N slot=N reason=cook_tap_failed:too_early
```

## SEALED Exception Hotfix — S-17

- Issue (P0): SubmitCookTap 실패 후 재시도 시 session_already_active 발생
- Cause: S-16은 슬롯 락만 해제, CookSessions 테이블의 세션은 잔존
- Fix: Whitelist 방식 세션 정리 (감리자 승인)
- Approved: ChatGPT (Auditor), 2026-01-25

### Whitelist Policy (SESSION_CLEAR_ERRORS)

| 에러 | 세션 처리 | 이유 |
|------|----------|------|
| `too_early` | 삭제 ✅ | 재시도 허용 필요 |
| `too_late` | 삭제 ✅ | 재시도 허용 필요 |
| `session_expired` | 삭제 ✅ | 명시적 포함 |
| `session_mismatch` | **보존** | 정상 세션 보호 + 디버깅 |
| `session_consumed` | **보존** | 중복 제출 방어 (덮어씀 허용) |

Exit Evidence (S-17):
```
[CraftingService] S-16|SLOT_UNLOCK uid=N slot=N reason=cook_tap_failed:too_early
[CraftingService] S-17|SESSION_CLEAR uid=N slot=N reason=too_early
```

## SEALED Exception Tuning — MIN_COOK_TIME

- Issue (UX): Normal taps at ~0.97s rejected as too_early
- Cause: MIN_COOK_TIME=1.5s was overly conservative
- Fix (Server): PGConfig.MIN_COOK_TIME = 0.5 (was 1.5)
- Fix (Client): CookGaugeUI minCookTime UX guard + "⏳ Wait..." feedback
- Approved: ChatGPT (Auditor), 2026-01-25

### Dual Guard Architecture

| Layer | Role | Behavior |
|-------|------|----------|
| Server | Truth | Validates elapsed ≥ 0.5s, returns `too_early` if violated |
| Client | UX | Blocks tap before 0.5s, shows "⏳ Wait..." (prevents round-trip) |

### Payload Addition

```lua
-- CraftingService.lua cookSessionPayload
minCookTime = PGConfig.MIN_COOK_TIME  -- 클라 UX 가드용
```

Exit Evidence (MIN_COOK_TIME):
```
[CookGaugeUI] Tap blocked: too early (0.32 < 0.50)
```

Evidence excerpt:
- BEFORE_TAP dishCount=0
- S-11|COOK_DISH_CREATED ... dishKey=dish_7
- AFTER_TAP dishCount=1
- SERVE transition success

## C-06 Corrected Policy

- Policy: clientJudgment not sent (design choice) -> corrected=true disabled in prod
- UI handling: corrected=true receives NEUTRAL presentation (no Up/Down distinction), Server=Truth
- Verification: Path verified in Studio, test code removed (clean prod code)

## Implementation Summary

### Server (S-01~S-11) — PG-1 Core SEALED
- S-01~S-09: Session/Judgment/Protection/Remote/Telemetry
- S-10: STALE_COOK_SESSION guard
- S-11: cook_minigame dish completion hotfix

### Server (S-12~S-15) — PG-1.1 Extension
- S-12: SubmitCookTap branching (COOK_TIME_PHASE_ENABLED flag)
- S-13: CraftSpeed application to CookTimePhase duration
- S-14: OnCookTimePhaseComplete (dish creation after duration)
- S-15: FallbackReason + Phase response fields

### Client (C-01~C-08) — PG-1 Core SEALED
- C-01~C-04: CookGaugeUI (semi-modal, accessibility/input blocking, judgment display)
- C-05: Tap capture (clientPos/clientTime) + pending display
- C-06: corrected handling (policy: disabled in prod)
- C-07: gaugeSpeed from server
- C-08: timer fallback maintained

### Client (C-09~C-11) — PG-1.1 Extension
- C-09: CookTimePhase START handling (CookTapResponse phase="COOK_TIME_START")
- C-10: 3-tier CraftResponse branching (timer+fallback / legacy / cook_minigame)
- C-11: COOK_TIME_COMPLETE handling (Phase-based routing in cook_minigame)

## C-09/C-11 Implementation (v1.6.6)

> **Approach**: MainHUD TimerFlow 재사용 + CookTimePhase 전용 래퍼 함수
> **Approved**: ChatGPT (Auditor), 2026-01-25

### MainHUD.lua 추가 함수

```lua
function MainHUD:StartCookTimePhase(slotId, duration, recipeId)
    -- tick() 기반 startTime/endTime 계산
    -- UpdateCraftingState({isActive=true, ...}) 호출
    -- [CookTimePhase] START 로그

function MainHUD:CompleteCookTimePhase(slotId)
    -- UpdateCraftingState({isActive=false, slotId}) 호출
    -- [CookTimePhase] COMPLETE 로그
    -- → BUILD → SERVE 전환
```

### ClientController 호출 패턴

1. **COOK_TIME_START** (CookTapResponse):
   - 0.6초 판정 표시 후 CookGaugeUI Hide
   - `MainHUDInstance:StartCookTimePhase(slotId, remainingDuration, recipeId)`

2. **COOK_TIME_COMPLETE** (CraftResponse):
   - CookGaugeUI 방어적 Hide
   - `MainHUDInstance:CompleteCookTimePhase(slotId)`
   - StateChanged로 inventory 업데이트

### Fallback 충돌 방지 원리

- Timer fallback: `mode="timer" + FallbackReason` → 직접 UpdateCraftingState 호출
- CookTimePhase: `mode="cook_minigame" + Phase` → 래퍼 함수 경유
- **두 경로는 mode 값으로 완전히 분리됨**

## PG-1.1 CookTimePhase Flow (v1.6.6)

```
[Client] CraftRequest (slotId, recipeId)
    ↓
[Server] CraftItem → mode="cook_minigame", Phase="MINIGAME_START"
    ↓
[Client] CookGaugeUI:Show() → user taps
    ↓
[Server] SubmitCookTap → judgment calculated
    ↓
[Server] IF COOK_TIME_PHASE_ENABLED:
    │   → return Phase="COOK_TIME_START", CookTimeDuration=N
    │   → task.delay(N) → OnCookTimePhaseComplete
    │       → dish created
    │       → FireClient Phase="COOK_TIME_COMPLETE"
    └── ELSE: → S-11 immediate dish creation (PG-1 Core)
    ↓
[Client] C-11: COOK_TIME_COMPLETE → hide UI, inventory updated
```

## Track B (PG-1.1 Extension) — 5-line Exit Evidence (PASS)

> **PASS Date**: 2026-01-25
> **Auditor**: ChatGPT — APPROVED

```
1) [Client] [C-10] CraftResponse mode=cook_minigame phase=MINIGAME_START slotId=1
2) [Client] CookTapResponse ... phase=COOK_TIME_START duration=3.00 slotId=1
3) [CookTimePhase] START slotId=1 duration=2.40 recipeId=1
4) [Client] [C-10] CraftResponse mode=cook_minigame phase=COOK_TIME_COMPLETE slotId=1
5) [Client] [C-11] CookTimePhase COMPLETE slotId=1 dishKey=dish_1 recipeId=1
```

## S-19 (P2) UI/UX Layering — PASS

> **PASS Date**: 2026-01-25

### Fix Applied
- Progress bar ZIndex = 1 (restored)
- Status text separated to TextLabel with ZIndex = 2
- Text visible above progress bar

### Exit Evidence
- CookTimePhase 진행 중 progress bar 정상 표시
- 상태 텍스트가 progress bar 위에 표시 (가려짐 없음)

## Known Issues (Non-blocking)
- P2: SendCraftComplete path's CraftResponse (mode=timer/complete) processed first,
  CookTapResponse judgment display may be skipped (function: dish creation/serve transition OK)

---

# PG-2 Customer + Patience System

> Status: CONTRACT OPENED (v0.1)
> Created: 2026-01-25

## Scope

PG-2 = Customer Character + Patience System (Core)
Goal: "PG-1 + PG-2 완료 시 게임이라 부를 수 있음" 기준 충족.

### Split
- **PG-2 Core**: CustomerState + Patience decay + timeout fail + cancel/leave
- **PG-2 Extension**: Customer visuals, 애니메이션, 감정 연출, SFX

## Contract Reference

- FoodTruck: `Docs/PG2_CONTRACT_v0.1.md`

## Exit Evidence (Target)

### Timeout Path (5-line):
```
1) PG2|SPAWN uid=N slot=1 customerId=... patienceMax=60.0
2) PG2|PATIENCE_TICK uid=N slot=1 old=60.0 new=59.0 pct=98.3 reason=idle
3) PG2|TIMEOUT uid=N slot=1 customerId=... patienceNow=0.0
4) PG2|LEAVE uid=N slot=1 customerId=... reason=timeout
5) [OrderService] ORDER_CANCELED uid=N slot=1 reason=patience_timeout
```

### Serve Path (5-line):
```
1) PG2|SPAWN uid=N slot=1 customerId=... patienceMax=60.0
2) PG2|PATIENCE_TICK uid=N slot=1 old=60.0 new=55.0 pct=91.7 reason=crafting
3) DELIVER_SETTLE uid=N slot=1 reward=50 tip=12 total=62
4) PG2|SERVE uid=N slot=1 customerId=... tip=12.00
5) PG2|LEAVE uid=N slot=1 customerId=... reason=served
```

## Implementation Status

| Item | Description | Status |
|------|-------------|--------|
| Contract | PG2_CONTRACT_v0.1.md | ✅ DONE |
| PG2Config | Tuning values | ⏳ Pending |
| CustomerService | Server logic | ⏳ Pending |
| Client UI | Patience bar | ⏳ Pending |
| Exit Evidence | Studio 5-line | ⏳ Pending |
