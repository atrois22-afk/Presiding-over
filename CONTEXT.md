# CONTEXT — PG-1 Cook Minigame Audit Index

> Version: v1.6
> Updated: 2026-01-25
> Previous: v1.5 (Server S-01~S-10 SEALED)

## Current Sealed

### PG-1 Core (SEALED)
| Scope | Items | Status |
|---|---|---|
| Server | S-01~S-11 | SEALED |
| Client | C-01~C-08 | SEALED |

Evidence (Public):
- PG1_Implementation_Checklist.md v1.6
- S-11 A/B delta: dishCount 0 -> 1
- C-08 timer fallback log
- C-06 corrected policy (disabled in prod)

### PG-1 Integration (Pending)
| Item | Description | Status |
|---|---|---|
| I-02 | cookScore -> tip calculation | Pending |
| I-03 | recipe <-> difficulty mapping | Pending |

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
