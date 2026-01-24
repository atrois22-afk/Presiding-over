# CONTEXT — PG-1 Cook Minigame Audit Index

> Version: v1.6.4
> Updated: 2026-01-25
> Previous: v1.6.3 (Gate 템플릿 적용)

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
| Server | S-12~S-14 | 🔶 APPROVED |
| Client | C-09, C-11 | 🔶 APPROVED |

Evidence (Public):
- PG1_Implementation_Checklist.md v1.6.4
- S-11 A/B delta: dishCount 0 -> 1
- C-08 timer fallback log
- C-06 corrected policy (disabled in prod)
- PG-1.1 Approval: ChatGPT (Auditor), 2026-01-25
- Gate 1st commit: S-15/C-10 (FallbackReason + Phase)

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

### Server (S-01~S-11)
- S-01~S-09: Session/Judgment/Protection/Remote/Telemetry
- S-10: STALE_COOK_SESSION guard
- S-11: cook_minigame dish completion hotfix

### Client (C-01~C-08)
- C-01~C-04: CookGaugeUI (semi-modal, accessibility/input blocking, judgment display)
- C-05: Tap capture (clientPos/clientTime) + pending display
- C-06: corrected handling (policy: disabled in prod)
- C-07: gaugeSpeed from server
- C-08: timer fallback maintained

## Known Issues (Non-blocking)
- P2: SendCraftComplete path's CraftResponse (mode=timer/complete) processed first,
  CookTapResponse judgment display may be skipped (function: dish creation/serve transition OK)
