# FoodTruck Changelog

> 코드 수정 이력. Claude가 수정할 때마다 기록.

---

## 2026-02-01

### QA 통합 테스트 (S-29.2 + NoticeUI) ✅ ALL PASS

**범위:** S-29.2 Stale Lifecycle + NoticeUI 최소 표시 시간 + 클라/서버 동기화

**결과:** 7/7 TC PASS

| TC ID | 범위 | 결과 |
|-------|------|------|
| TC-NOTICE-01 | 최소 표시 2초 + TTL | ✅ PASS |
| TC-NOTICE-02 | 큐 스트레스 (5개+) | ✅ PASS |
| TC-NOTICE-SRV-01 | Q2 중복 방지 (세션 1회) | ✅ PASS |
| TC-S29.2-REG-01 | 라이프사이클 0→1→2→폐기 | ✅ PASS |
| TC-S29.2-REG-02 | ESCAPE 후순위/fallback | ✅ PASS |
| TC-ORD-01 | CancelOrder→ESCAPE 재평가 | ✅ PASS |
| TC-SYNC-01 | 폐기 후 클라 동기화 | ✅ PASS |

**핵심 증거 (log.md 23:57~23:59 KST):**
```
MIN_DISPLAY_QUEUE elapsed=0.57 queueLen=1  ← TC-NOTICE-01/02
ESCAPE_SKIP_STALE level=2                  ← TC-S29.2-REG-02
ESCAPE_FALLBACK_STALE2 reason=no_alternative
STALE_DISCARD → dishKeys=3→2              ← TC-SYNC-01
```

---

### A: 팝업 메시지 개선 - 레시피명 포함 (v0.2.3.5)

**목적:** Stale 알림에 어떤 요리인지 명시 (예: "Bacon Lettuce가 식었습니다")

**수정 파일 (4개):**

| 파일 | 변경 |
|------|------|
| DataService.lua | `SendNotice` 시그니처에 `extra` 파라미터 추가 |
| OrderService.lua | stale notice 전송 시 `{ dishKey = dishKey }` 포함 |
| ClientController.lua | `RE_ShowNotice` 수신 시 `extra` 전달 |
| NoticeUI.lua | `StaleTemplates` + `GetRecipeNameFromDishKey()` + Show에서 포맷 |

**메시지 변경:**
```
이전: "요리가 조금 식었습니다. (Stale I)"
이후: "Bacon Lettuce가 조금 식었습니다. (Stale I)"
```

**fallback:** 레시피명 조회 실패 시 기존 메시지 사용

**추가 수정 (한글 이름):**
- `GetRecipeNameFromDishKey()`: `recipe.name` → `recipe.nameKo or recipe.name`
- 한글 이름 우선 표시, fallback으로 영어

**TC-NOTICE-MSG-01:** ✅ PASS (visual confirmed) - 한글 레시피명 표시 확인

---

### C: Orphan 배지 UI 개선 ✅ PASS

**목적:** 고아 요리 배지 시인성 향상 (하단 텍스트 → 우측 상단 배지)

**수정 파일 (1개):**

| 파일 | 변경 |
|------|------|
| MainHUD.lua | OrphanLabel 스타일/위치 변경, 상태 변화 로그 추가 |

**변경 내용:**

| 항목 | 변경 전 | 변경 후 |
|------|---------|---------|
| 위치 | 좌측 하단 (Y=75) | **우측 상단** |
| 스타일 | 텍스트만 (배경 없음) | **배지** (배경색 + 둥근 모서리) |
| 텍스트 | `🧾 고아: %d개 (상세)` | **`ORPHAN %d`** |
| 크기 | TextSize 13 | **14 Bold** |
| 표시 방식 | 텍스트 비움 | **Visible false** |

**로그:** `[PG2_UI] ORPHAN_BADGE_UPDATE total=%d visible=%s` (상태 변화 시에만)

**겹침 방지:** MaterialsLabel 우측 여백 확보 (1, -20 → 1, -130)

**TC-UI-ORPHAN-01:** ✅ PASS (스크린샷 + ORPHAN_BADGE_UPDATE 로그 확인)

---

### 동시 폐기 알림 누락 수정

**이슈:** 두 종류 요리가 동시에 폐기되면 알림 1개만 표시 (RATE_LIMIT)

**원인:**
```lua
-- 변경 전: code만으로 rate limit
lastShownByCode[code]  -- dish_24, dish_18 둘 다 "stale_discard"로 동일
```

**수정:**
```lua
-- 변경 후: code + 식별자로 rate limit
local id = (extra and (extra.dishKey or extra.key)) or ""
local rateKey = code .. "_" .. tostring(id)
lastShownByCode[rateKey]  -- "stale_discard_dish_24", "stale_discard_dish_18" 별도
```

**효과:**
- 같은 요리 + 같은 알림 → 차단 (스팸 방지 유지)
- **다른 요리** + 같은 알림 → 허용 (정보 누락 해소)

**TC-NOTICE-RL-01:** ✅ PASS (로그 확인: dish_10 SHOW_PROCEED, dish_8 MIN_DISPLAY_QUEUE→SHOW_PROCEED)

---

### S-30: Manual Discard 서버 구현 (P0 - UI 없이 서버만)

**목적:** Stale II 요리 수동 폐기 기능 (SSOT: Docs/S30_Manual_Discard_SSOT.md)

**수정 파일 (4개):**

| 파일 | 변경 |
|------|------|
| Main.server.lua | `RE_ManualDiscard` RemoteEvent 생성 |
| OrderService.lua | `ManualDiscard()` 함수 추가 (Stale II 검증 + 폐기) |
| RemoteHandler.lua | `RE_ManualDiscard` 핸들러 + `Stale2Keys` 동기화 |
| DataService.lua | `GetStale2Keys()` 헬퍼 추가 |
| ClientController.lua | `stale2Set` 클라이언트 상태 추가 |

**핵심 로직 (OrderService:ManualDiscard):**
1. playerData 유효성 검사
2. 쿨다운 체크 (uid 기반 0.5초)
3. inventory[dishKey] > 0 검사
4. staleCounts[dishKey][2] > 0 검사 (Stale II만 폐기 가능)
5. 폐기 처리 (inventory--, staleCounts[2]--)
6. Stale2Keys 동기화 반환

**지적 A 수정 (ChatGPT 감리):**
```lua
-- 변경 전: staleCounts[dishKey] nil 시 크래시
staleCounts[dishKey][2] = stale2Qty - 1

-- 변경 후: defensive nil check
if not staleCounts[dishKey] then
    warn("[OrderService] S-30|WARN uid=%d dishKey=%s staleCounts entry unexpectedly nil")
    staleCounts[dishKey] = { [0] = 0, [1] = 0, [2] = stale2Qty }
end
staleCounts[dishKey][2] = stale2Qty - 1
```

**동기화 패턴 (Stale2Keys):**
- 서버: `stale2Keys` 배열 (Stale II인 dishKey 목록만)
- 클라: `stale2Set` 테이블 (O(1) 조회용 Set 변환)
- 목적: staleCounts 전체 동기화 대신 최소 데이터만 전송

**상태:** ✅ S-30 완료 (2026-02-01 08:30 KST)

**P0 테스트 결과 (Direct Call):**

| TC ID | 시나리오 | 결과 | 로그 증거 |
|-------|----------|------|-----------|
| TC-S30-01 | Stale II 폐기 | ✅ PASS | `MANUAL_DISCARD uid=-1 dishKey=dish_10 remaining=1` |
| TC-S30-02 | Fresh 폐기 거부 | ✅ PASS | `DISCARD_DENIED reason=not_stale2 stale2=0` |
| TC-S30-03 | 연타 거부 | ✅ PASS | `DISCARD_DENIED reason=cooldown dt=0.00` |

**Remote 경로 테스트 결과:**

| TC ID | 시나리오 | 결과 | 로그 증거 |
|-------|----------|------|-----------|
| TC-S30-REM-01 | Stale II 폐기 | ✅ PASS | `MANUAL_DISCARD` + `DISCARD_RECV success=true` |
| TC-S30-REM-02 | 연타 거부 | ✅ PASS | `DISCARD_DENIED reason=cooldown` + `DISCARD_RECV error=cooldown` |
| TC-S30-REM-03 | Fresh 거부 | ✅ PASS | `DISCARD_DENIED reason=not_stale2` + `DISCARD_RECV error=not_stale2` |

**ChatGPT 감리 후속 조치 (2026-02-01):**

| 지적 | 조치 |
|------|------|
| (P1) SSOT §9 reason 불일치 | SSOT 문서 수정 (`not_stale2`, `no_qty`, `invalid_key`, `no_data`, `recovery`) |
| (P1) ManualDiscardCooldowns 메모리 누수 | `CleanupPlayer()`에 `ManualDiscardCooldowns[uid] = nil` 추가 |
| (P2) RECOVERY 상태 체크 누락 | `ManualDiscard()`에 `ShouldRejectAction()` 가드 추가 |
| (Q1) DEBUG 코드 제거 | Main.server.lua RE_DebugSetStale2, OrderService.lua S-30\|DEBUG 로그 제거 |

**Remote 경로 수정:**

| 파일 | 변경 |
|------|------|
| ClientController.lua | `DiscardResponse` 스코프 화이트리스트 추가 + 로그 |

**원인:** 서버가 `DiscardResponse` 스코프로 전송하지만 클라가 처리 안함 → `UNKNOWN_SCOPE` 경고
**해결:** Response 화이트리스트에 `DiscardResponse` 추가

**Exit Criteria:**
- [x] 서버: ManualDiscard 함수 구현 (Stale II 검증 + 폐기)
- [x] 서버: 쿨다운, RECOVERY 가드, 메모리 정리
- [x] Remote 경로: RE_ManualDiscard → RemoteHandler → OrderService → 클라 동기화
- [x] 클라: DiscardResponse 처리 + 로그
- [x] 테스트: P0 3/3 PASS, Remote 3/3 PASS (총 6 TC)

**QA 스모크 테스트 (2026-02-01 08:42):**

| 항목 | 결과 |
|------|------|
| A) CraftComplete (인벤 증가) | ✅ PASS |
| B) DeliverOrder (인벤 감소) | ✅ PASS |
| C) Cancel/Timeout (주문 취소/리필) | ✅ PASS |
| D) Stale2Keys 동기화 회귀 | ✅ PASS |
| E) Orphan 배지 상태 전이 | ✅ PASS |

**S-30 서버/Remote: CLOSED (5/5 스모크 PASS)**

---

### S-30: P1 UI 구현 (Stale II 폐기 패널)

**목적:** Stale II 요리 수동 폐기 UI (SSOT: Docs/Audit/S30_P1_UI_Checklist.md)

**수정 파일 (2개):**

| 파일 | 변경 |
|------|------|
| MainHUD.lua | Stale2DiscardPanel 추가, 후보 선택/폐기 버튼/확인 모달 |
| ClientController.lua | SCOPE_ORDER에 `stale2Set` 추가 (StateChanged 발화) |

**UI 구조:**
- 위치: InventoryFrame 하단 (조건부 표시)
- 패널: stale2Set 비어있으면 숨김, 있으면 표시 + InventoryFrame 높이 동적 조절
- 후보 목록: 최대 5개 버튼, 초과 시 `+N` 표시
- 선택: 단일 선택 (토글), stale2Set에서 사라지면 자동 해제
- 폐기 버튼: 선택 없으면 비활성
- 확인 모달: 1회 생성, show/hide 토글 (메모리 누수 방지)

**버그 수정 (2026-02-01 09:05):**
- 확인 모달 ZIndex 100→200 (EndDay 프레임과 충돌로 모달 안 보임)
- 모달 자식 요소(Message, ConfirmButton, CancelButton) ZIndex=201 추가

**핵심 함수:**
- `RenderStale2DiscardPanel()`: 후보 목록 렌더링 + 패널 표시/숨김
- `OnCandidateSelect(dishKey)`: 후보 선택 토글
- `OnDiscardButtonClick()`: 확인 모달 표시
- `ShowDiscardConfirmModal(dishKey)`: 확인 모달 생성/표시
- `ExecuteDiscard()`: RE_ManualDiscard:FireServer(dishKey)

**로그:**
- `S-30|UI_RENDER candidates=%d selected=%s`
- `S-30|UI_SELECT dishKey=%s`
- `S-30|UI_CONFIRM_OPEN dishKey=%s`
- `S-30|UI_SEND dishKey=%s`

**상태:** ✅ S-30 P1 UI CLOSED (2026-02-01 09:12 KST)

**P1 UI 테스트 케이스:**

| TC ID | 시나리오 | 결과 |
|-------|----------|------|
| TC-S30-UI-01 | Stale II 후보 표시 + 선택 + 폐기 | ✅ PASS |
| TC-S30-UI-02 | 후보 0개 시 패널 숨김 | ✅ PASS |
| TC-S30-UI-03 | 연속 폐기 (2초 간격) | ✅ PASS |

**증거 (log.md 09:12 KST):**
```
UI_RENDER candidates=2 → UI_SELECT dish_31 → MANUAL_DISCARD success
UI_RENDER candidates=1 → UI_SELECT dish_7  → MANUAL_DISCARD success
UI_RENDER candidates=0 (패널 숨김)
```

---

### S-31: Patience Timeout → Stale 승격 (구현 완료)

**목적:** patience_timeout(손님 떠남)으로 주문 취소 시, 예약된 요리 Stale 승격/폐기

**SSOT:** `Docs/SSOT/S31_PatienceTimeout_Upgrade_SSOT.md`

**수정 파일 (1개):**

| 파일 | 변경 |
|------|------|
| OrderService.lua | Feature Flag + HandleTimeoutStaleUpgrade 함수 + CancelOrder 훅 |

**핵심 결정 (SSOT 기준):**

| 결정 | 내용 |
|------|------|
| D2 | 중복 승격 방지: `order.timeoutUpgradeHandledAt` |
| D4 | 실행 순서: 스냅샷 → 처리 → 마킹 → ClearReservation |
| D5 | RECOVERY 상태 스킵 |
| D7 | serveDeadline 유예 중이면 CancelOrder 자체가 blocked → S-31 미실행 |

**Feature Flag:**
- `S31_TIMEOUT_UPGRADE_ENABLED = false` (기본 OFF)
- 테스트 후 ON 권고

**로그 키:**
- `S-31|TIMEOUT_UPGRADE uid=... slot=... dishKey=... from=... to=...`
- `S-31|TIMEOUT_DISCARD uid=... slot=... dishKey=... fromLevel=... reason=timeout_rotten`
- `S-31|SKIP uid=... slot=... reason=...`

**상태:** ✅ DORMANT (Flag OFF, 2026-02-01 10:15 KST)

**DORMANT 사유:**
- 현 밸런스: patience(60초) > serveDeadline 사이클(~24초)
- 요리가 먼저 Rotten 폐기됨 → patience_timeout 거의 발생 안 함
- S-31은 "안전장치"로 존재, 밸런스 조정 시 활성화 가능

**활성화 조건:**
- patienceMax 단축 또는 serveDeadline 연장 시 Flag ON

**회귀 테스트:**

| TC ID | 시나리오 | 기대 | 결과 |
|-------|----------|------|------|
| TC-S31-NOOP-01 | Flag OFF + 정상 플레이 | S-31 로그 0건 | ✅ PASS |

**TC-S31-NOOP-01 PASS 조건:**
- 포함 기대: `S-29.2|STALE_DISCARD` 또는 `S-26|GRACE_EXPIRED`
- 부재 기대: `S-31|*` (0건)
- WARN 허용: `ORDER_CANCELED reason=patience_timeout` (드물게 발생 가능, S-31 미실행이면 OK)

---

### S-33: P1 Minimal Audit 구현 (Client Sync Integrity Guard)

**목적:** 동기화가 "조용히 깨지는" 케이스를 가볍게 탐지/로그 (SSOT: Docs/SSOT/S33_P1_Minimal_Audit_SSOT.md)

**수정 파일 (1개):**

| 파일 | 변경 |
|------|------|
| ClientController.client.lua | S-33 Config/Rate-limit + AuditInventory/Orders/Stale2Set 함수 + 호출 삽입 |

**구현 결정사항:**

| ID | 내용 |
|----|------|
| D1 | 실행 위치: `updatedScopes` 기반 조건부 실행 (G4.1 invariant 이후) |
| D2 | 실행 모드: AUDIT_ONLY 기본, ASSERT_MODE는 Studio에서만 (`RunService:IsStudio()`) |
| D3 | Rate-limit: `uid|auditKey` 키, minInterval=1.0s |
| D6 | stale2Set 검증 트리거: `updatedScopes["stale2Set"] OR updatedScopes["inventory"]` |
| D7 | qty 정수 판정: `qty % 1 == 0` (Lua number는 float) |

**Audit 함수:**
- `AuditInventory(inventory)`: I33-P1-INV-01 (dish_ key 패턴, qty 정수/음수)
- `AuditOrders(orders)`: I33-P1-ORD-01 (reservedDishKey 패턴, reservedStaleLevel 범위)
- `AuditStale2Set(stale2Set, inventory)`: I33-P1-ST2-01 (stale2Set ⊆ inventory, qty≥1)

**로그 포맷:**
- `[Client] S-33|AUDIT_WARN key=<auditKey> uid=<uid> <details>`
- `[Client] S-33|AUDIT_ASSERT key=<auditKey> uid=<uid> <details>` (Studio)

**auditKey 값:**
- `inv_negative`, `inv_bad_key`, `inv_bad_qty`
- `ord_bad_shape`, `ord_bad_reserved_key`
- `st2_missing_inventory`, `st2_zero_qty`

**상태:** ✅ CLOSED (2026-02-01 11:00 KST)

**테스트 케이스:**

| TC ID | 시나리오 | 결과 |
|-------|----------|------|
| TC-S33-01 | inv_negative (manual injection) | ✅ PASS |
| TC-S33-03 | rate-limit (1초 내 반복 3회 → 1회만 출력) | ✅ PASS |
| TC-S33-04 | orders reservedDishKey 형식 오류 | ✅ PASS |
| TC-S33-02 | stale2Set ⊄ inventory | 🔲 NOT RUN (no debug hooks; manual injection avoided) |

**수정사항 (TC 이후):**
- `AuditInventory` key 패턴 검증 완화: 재료 키(숫자) 노이즈 방지
  - 변경 전: 모든 key에 `^dish_%d+$` 강제 → `inv_bad_key dishKey=1` 노이즈 발생
  - 변경 후: `dish_` prefix가 있는 것만 패턴 검증, 재료 키는 스킵
- `S33_ASSERT_MODE = false` 기본값으로 변경 (TC 연속 실행 보장)
- SSOT I33-P1-INV-01 업데이트: 혼합 스키마(재료+요리) 명시
- **(P1.5)** `_s33Assert()` Studio hard-gate 추가: `S33_ASSERT_MODE and RunService:IsStudio()` 조건으로 Production error 방지

---

### S-36: Inventory/Orders Schema Specification (SSOT 문서)

**목적:** Inventory/Orders/Stale2Set 혼합 스키마를 공식 문서로 고정하여 drift 방지

**생성 파일:**
- `Docs/SSOT/S36_Inventory_Orders_Schema_SSOT.md`

**핵심 결정:**
- D1: Inventory는 혼합 스키마 (재료=숫자키, 요리=dish_%d+)
- D2: qty는 정수/비음수, 0 표현 차이 허용
- D3: Orders reserved 필드 (reservedDishKey, reservedStaleLevel)
- D4: stale2Set ⊆ inventory(요리 키 영역)
- D5: 서버=정규화 책임, 클라=관대한 파서

**상태:** ✅ APPROVED (2026-02-01)

---

### S-35: Full Snapshot Recovery (구현 완료)

**목적:** S-33 탐지 후 클라이언트 self-heal (서버 권위 스냅샷으로 덮어쓰기)

**SSOT:** `Docs/SSOT/S35_Full_Snapshot_Recovery_SSOT.md`
**Checklist:** `Docs/Audit/S35_Implementation_Checklist.md`

**수정 파일 (4개):**

| 파일 | 변경 |
|------|------|
| Main.server.lua | RE_RequestFullSnapshot Remote 생성 |
| DataService.lua | BuildFullSnapshot() 함수 추가 |
| RemoteHandler.lua | RE_RequestFullSnapshot 핸들러 (rate-limit 30s) |
| ClientController.client.lua | S-35 섹션 전체 (trigger, debounce, apply) |

**핵심 결정 (D1~D8):**
- D1: 트리거 조건 (inv_negative는 debounce+재검증, 나머지는 1회 발생)
- D2: RE_SyncState + "FullSnapshotResponse" 통일
- D3: Rate-limit 30s, Debounce 1.0s
- D4: Inventory/Orders/Stale2Keys/Wallet/Cooldown 포함
- D5: 권위 덮어쓰기 (병합 금지)
- D7: 스키마 위반해도 apply + warn 로그

**TC 결과:** ⏳ PENDING (Studio 테스트 대기)

| TC ID | 범위 | 결과 |
|-------|------|------|
| TC-S35-01 | mismatch → snapshot → heal | ⏳ |
| TC-S35-02 | Rate-limit (30s) | ⏳ |
| TC-S35-03 | inv_negative 재검증 | ⏳ |
| TC-S35-04 | 스키마 위반 apply | ⏳ |
| TC-S35-05 | Server bad_state drop | ⏳ |

**상태:** ✅ IMPLEMENTED (TC 대기)

---

### S-35: 감리 피드백 반영 (P0+P1)

**감리자:** ChatGPT (2026-02-01)
**판정:** 구조/아키텍처 타당, P0 3개 + P1 2개 보강 필요

**P0 수정 (필수):**

| # | 지적 | 수정 내용 |
|---|------|----------|
| 1 | rid 가드 없음 | `_s35LastRequestedRid` 추가, 응답 시 stale_rid 무시 |
| 2 | StateChanged 순서 | inventory → stale2Set → orders → wallet → cooldown |
| 3 | schema_violation warn | `SNAPSHOT_APPLY_WARN` 로그 추가 (D7 준수) |

**P1 수정 (권장):**

| # | 지적 | 수정 내용 |
|---|------|----------|
| 1 | orders deep copy | nested table 안전 복사 추가 |
| 2 | rate-limit cleanup | PlayerRemoving에서 cache 정리 |

**수정 파일:**
- `ClientController.client.lua`: rid 가드, 순서 수정, schema warn
- `DataService.lua`: orders deep copy 보강
- `RemoteHandler.lua`: PlayerRemoving cleanup 추가

**상태:** ✅ P0+P1 반영 완료 (재감리 대기)

---

## 2026-01-31

### NoticeUI 최소 표시 시간 + 다중 큐 지원 (v0.2.3.4)

**요청:** 알림이 연속으로 도착할 때 첫 번째 메시지가 즉시 덮어씌워지는 문제

**수정 내용:**

| 항목 | 변경 전 | 변경 후 |
|------|---------|---------|
| 최소 표시 시간 | 없음 (즉시 덮어쓰기) | **2초** |
| 큐 방식 | 단일 (`pendingNotice`) | **배열** (`pendingQueue`) |
| 다중 메시지 | 1개만 보류 | **무제한 순차 처리** |

**수정 파일 (1개):**

| 파일 | 변경 |
|------|------|
| NoticeUI.lua | `NOTICE_MIN_DISPLAY=2.0`, `currentNoticeStartTime`, `pendingQueue[]` |

**핵심 로직:**
```lua
-- 최소 표시 시간 체크 (2초)
local elapsed = now - currentNoticeStartTime
if currentCode and elapsed < NOTICE_MIN_DISPLAY then
    -- 큐에 추가 후 대기
    table.insert(pendingQueue, { code, severity, messageKey })
    -- 최소 시간 후 큐 처리 스케줄링
    task.delay(waitTime, processQueue)
    return
end
```

**동작 예시:**
```
메시지1 도착 (t=0) → 즉시 표시
메시지2 도착 (t=1) → 큐 추가 (elapsed=1 < 2초)
메시지3 도착 (t=1.5) → 큐 추가
... t=2.1 → 메시지2 표시 ...
... t=4.1 → 메시지3 표시 ...
```

**상태:** ✅ 구현 완료

---

### S-29.2 Stale Lifecycle MVP 구현 + 버그픽스 3건

**구현 목표:**
- 납품 실패(serveDeadline 15초 만료) 반복 시 요리가 Stale(0→1→2→3)로 승격
- Rotten(3)에서 자동 폐기되어 ESCAPE 무한 연명 차단

---

#### 버그 #1: Stale II 완전 배제로 인한 orphan 영구 정체

**문제:**
- ESCAPE_MULTI에서 `staleLevel >= 2` 요리를 완전 배제
- Fresh/Stale-I 요리가 없으면 Stale II 요리가 주문에 배치 안 됨
- 결과: serveDeadline 경로 없음 → Rotten 진행 불가 → 영구 orphan

**수정 내용:**

| 파일 | 변경 |
|------|------|
| OrderService.lua | ESCAPE_MULTI에 fallback 로직 추가 |
| S29_2_MVP_Definition.md | §7.3 ESCAPE 배치 정책 추가, 로그 키 6개로 확장 |

**수정 코드:**
```lua
-- Fresh/Stale-I 없고 Stale II만 있으면 fallback 사용
if not selectedDish and fallbackStale2 then
    selectedDish = fallbackStale2.dish
    selectedStaleLevel = fallbackStale2.level
    print("[OrderService] S-29.2|ESCAPE_FALLBACK_STALE2 ...")
end
```

---

#### 버그 #2: CancelOrder 후 ESCAPE 미호출

**문제:**
- `patience_timeout` → `CancelOrder` → `RefillOrders` 후 `ValidateBoardEscapePath` 미호출
- orphan 요리가 ESCAPE 매칭 안 됨 → Stale 진행 불가

**로그 증거:**
```
23:01:37.202  ORDER_CANCELED slot=1 reason=patience_timeout
23:01:37.202  REFILL slots=1 recipes=[14,3,30]
(ESCAPE_MULTI_START 없음!)
23:01:37.237  [PG2][ORPHAN] total=2  ← 여전히 orphan
```

**수정 내용:**

| 파일 | 변경 |
|------|------|
| OrderService.lua | CancelOrder 끝에 `ValidateBoardEscapePath` 추가 |
| S29_2_MVP_Definition.md | I-S29.2-06 ESCAPE 재평가 보장 불변식 추가 |

**수정 코드:**
```lua
-- CancelOrder 끝부분
local filledSlots = {}
if self.RefillOrders then
    filledSlots = self:RefillOrders(player)
end

-- S-29.2 버그픽스
local excludeSlotId = filledSlots[1] or slotId
self:ValidateBoardEscapePath(player, excludeSlotId)
```

---

#### 버그 #3: STALE_DISCARD 후 클라이언트 인벤토리 미동기화

**문제:**
- 서버에서 `STALE_DISCARD` 후 인벤토리 감소
- 클라이언트에 인벤토리 동기화 안 됨 → orphan UI에 폐기된 요리 계속 표시

**로그 증거:**
```
23:21:09.369  [서버] STALE_DISCARD dish_21 fromLevel=2 reason=stale_rotten
23:21:09.404  [클라] [PG2][ORPHAN] total=2  ← 폐기 후에도 2개!
```

**수정 내용:**

| 파일 | 변경 |
|------|------|
| RemoteHandler.lua | `BroadcastOrders` 시그니처에 optional `inventory` 파라미터 추가 |
| OrderService.lua | RotateSlot, CancelOrder에서 `BroadcastOrders` 호출 시 `inventory` 전달 |

**수정 코드:**
```lua
-- RemoteHandler.lua
function RemoteHandler:BroadcastOrders(player, orders, meta, inventory)
    -- ... 기존 코드 ...
    if inventory then
        local invToSend = {}
        for k, v in pairs(inventory) do
            invToSend[tostring(k)] = v  -- 0도 포함
        end
        response.Updates.Inventory = invToSend
    end
end

-- OrderService.lua (RotateSlot, CancelOrder)
_remoteHandler:BroadcastOrders(player, playerData.orders, meta, playerData.inventory)
```

---

#### 테스트 결과

| TC | 상태 | 증거 |
|----|------|------|
| TC-S29.2-01 (Happy Path) | ✅ PASS | STALE_UPGRADE 0→1→2, STALE_DISCARD 로그 확인 |
| TC-S29.2-02 (ESCAPE 제한) | ✅ PASS | ESCAPE_SKIP_STALE, ESCAPE_FALLBACK_STALE2 로그 확인 |
| 버그 #3 (인벤 동기화) | ✅ PASS | `dishKeys=2→1→0` 감소 확인 (23:32:16 log.md) |

---

## 2026-01-26

### ESCAPE_MULTI serveDeadline 누락 핫픽스 (08:XX)

**문제:**
- ESCAPE_MULTI가 주문에 요리를 배정할 때 `serveDeadline`을 설정하지 않음
- 결과: `phase=SERVE` 상태인데 `deadline=nil` → 15초 유예 기간 미적용

**로그 증거:**
```
[PG2_UI] TICKET slot=2 phase=SERVE deadline=nil hasInv=true
[PG2_UI] TICKET slot=3 phase=SERVE deadline=nil hasInv=true
```

**원인:**
- ESCAPE_MULTI가 주문 객체를 새로 생성할 때 `reservedDishKey`는 설정하지만 `serveDeadline` 누락
- ReserveDish() 헬퍼와 달리 직접 필드 구성으로 인해 발생

**수정 내용:**

| 파일 | 위치 | 변경 |
|------|------|------|
| OrderService.lua | Line 1546 | `serveDeadline = os.time() + graceSeconds` 추가 |

**수정 코드:**
```lua
-- AS-IS (버그)
playerData.orders[slotId] = {
    slotId = slotId,
    recipeId = selectedDish.recipeId,
    reward = recipe and recipe.reward or 50,
    reservedDishKey = selectedDish.dishKey,
}

-- TO-BE (수정)
local graceSeconds = ServerFlags.SERVE_GRACE_SECONDS or 15
playerData.orders[slotId] = {
    slotId = slotId,
    recipeId = selectedDish.recipeId,
    reward = recipe and recipe.reward or 50,
    reservedDishKey = selectedDish.dishKey,
    serveDeadline = os.time() + graceSeconds,  -- S-26 호환
}
```

**테스트:** ✅ **PASS (2026-01-31 21:40 KST)**
- [x] TC-ESCAPE_MULTI-01: `deadline=1769863273` 확인 (숫자로 정상 설정)
- [x] TC-ESCAPE_MULTI-02: `[15s]` 배지 카운트다운 표시 확인

**테스트 증거 (log.md):**
```
21:40:58.529 [PG2_UI] TICKET slot=1 phase=SERVE deadline=1769863273 hasInv=true
21:41:13.894 [OrderService] S-26|GRACE_EXPIRED uid=10309326624 slot=1 action=rotate patience=33.0
```

---

### S-26/PG2 충돌 핫픽스 (07:XX) - serveDeadline 만료 미처리 버그 수정

**문제:**
- patience=0이 serveDeadline 만료 전에 도달하면:
  - OnTimeout에서 세션을 먼저 제거
  - CancelOrder가 BLOCKED (serveDeadline 보호)
  - 세션 없음 → TickCustomer 안 돌아서 grace_expired 체크 불가
  - `[!]` 배지가 영원히 표시됨

**원인:**
- S-26(serveDeadline 유예)과 PG-2(patience=0 즉시 세션 제거)의 상태 기계 충돌
- OnTimeout에서 RemoveCustomer → CancelOrder 순서가 잘못됨

**수정 내용 (ChatGPT 감리자 승인):**

| 파일 | 변경 |
|------|------|
| CustomerService.lua | OnTimeout 순서 변경: CancelOrder 먼저 → 성공 시에만 RemoveCustomer |
| CustomerService.lua | `pendingGraceExpiry` 플래그로 재진입 방지 |
| OrderService.lua | HandleServeGraceExpired에서 Customer 세션 정리 보장 |

**CustomerService.OnTimeout 변경:**
```lua
-- 기존 (버그)
self:RemoveCustomer(...)  -- 먼저 제거
OS:CancelOrder(...)       -- BLOCKED되어도 세션 없음

-- 수정 (핫픽스)
if session.pendingGraceExpiry then return end  -- 재진입 방지
local cancelled = OS:CancelOrder(...)
if cancelled then
    self:RemoveCustomer(...)  -- 성공 시에만 제거
else
    session.pendingGraceExpiry = true  -- grace_expired까지 대기
end
```

**OrderService.HandleServeGraceExpired 변경:**
```lua
-- 기존
self:CancelOrder(...) or self:RotateSlot(...)
-- Customer 정리 없음!

-- 수정
local cancelled = self:CancelOrder(...)
if cancelled and CS then
    CS:RemoveCustomer(...)  -- cancel 성공 시 Customer 제거
end
-- 또는
local rotated = self:RotateSlot(...)
if rotated and CS then
    CS:RespawnCustomer(...)  -- rotate 시 Customer 리스폰
end
```

**테스트 체크리스트:** ✅ **PASS (2026-01-31 21:41 KST)**
- [x] TC-S26PG2-01: grace_expired 처리 확인 (`patience=33.0`)
- [x] TC-S26PG2-03: RespawnCustomer 호출 확인 (`customer_4 patienceMax=60.0`)
- [x] TC-S26.1: ESCAPE_SKIPPED 확인 (`reason=grace_expired_rotate`)

**테스트 증거 (log.md):**
```
21:41:13.894 [OrderService] S-26|GRACE_EXPIRED uid=10309326624 slot=1 action=rotate patience=33.0
21:41:13.894 [OrderService] S-26|ROTATE uid=10309326624 slot=1 newRecipe=20 reason=grace_expired_rotate
21:41:13.895 [OrderService] S-26.1|ESCAPE_SKIPPED uid=10309326624 slot=1 reason=grace_expired_rotate
21:41:13.895 [CustomerService] S-29|RESPAWN_DONE uid=10309326624 slot=1 newCustomerId=customer_4 reason=grace_expired_rotate
```

**리포트:** `Docs/Audit/S26_PG2_Collision_Bug_Report_20260126.md`

---

### S-27a.3 버그 수정 완료 (06:XX) - 새 dishKey 감지 방식

**기존 버그:**
- 첫 번째 고아(베이컨더블치즈) → Notice 정상 표시 ✅
- 두 번째 고아(슈프림버거/울트라버거 추가) → Notice 안 뜸 ❌
- 원인: `_orphanWasZero` 플래그가 `total=0` 시에만 리셋

**수정 내용 (ChatGPT 감리자 승인):**
| 항목 | 변경 전 | 변경 후 |
|------|---------|---------|
| 트리거 방식 | 0→>0 전이 감지 | **새 dishKey 감지** |
| 세션 상한 | 2회 | **3회** |
| 재알림 정책 | total=0 시 리셋 | **orphanCounts에서 빠진 키 제거** |

**코드 변경:**
| 파일 | 라인 | 변경 |
|------|------|------|
| MainHUD.lua | 71-73 | `_notifiedOrphanKeys = {}` 추가, MAX 2→3 |
| MainHUD.lua | 1596 | 함수 시그니처에 `orphanCounts` 추가 |
| MainHUD.lua | 1614-1648 | `_orphanWasZero` 로직 → 새 dishKey 감지 로직 |
| MainHUD.lua | 1717-1725 | notified 집합에 키 추가 로직 |
| MainHUD.lua | 1767 | `orphan` 테이블 전달 |

**핵심 로직 변경:**
```lua
-- 기존: _orphanWasZero == false면 early return
if not _orphanWasZero then return end

-- 변경: notified에 없는 새 키가 있으면 계속 진행
local newKey = nil
for key in pairs(orphanCounts) do
    if not _notifiedOrphanKeys[key] then
        newKey = key; break
    end
end
if not newKey then return end
```

**결과:**
- 베이컨더블치즈 고아 유지 중 슈프림버거 추가 → Notice ✅
- 슈프림버거 정상화 후 재고아 → Notice ✅ (notified pruning)

---

### S-27a.3 버그 발견 (05:08) - 두 번째 고아 Notice 미표시 (해결됨)

**현상:**
- 첫 번째 고아(베이컨더블치즈) → Notice 정상 표시 ✅
- 두 번째 고아(슈프림버거/울트라버거 추가) → Notice 안 뜸 ❌

**원인 분석:**
- S-27a.3 설계: "0→>0 전이" 시에만 Notice 트리거
- 베이컨더블치즈가 계속 고아 → total이 0으로 안 떨어짐
- `_orphanWasZero = false` 유지 → 전이 체크 실패 → early return

**상태:**
- ✅ **수정 완료** (위 항목 참조)
- 리포트: `Docs/Audit/S27a_Bug_Report_20260126.md`

**NoticeUI 디버그 로그 추가:**
| 파일 | 변경 |
|------|------|
| Client/UI/NoticeUI.lua | RATE_LIMIT, PRIORITY_PENDING, SHOW_PROCEED 로그 추가 |

---

### 튜토리얼 창 위치/크기 조정 (05:20)

**요청:** 금액 표시 아래로 이동, 너비 축소

**수정:**
| 항목 | 변경 전 | 변경 후 |
|------|---------|---------|
| Size | `0.8, 0, 0, 100` | `0.4, 0, 0, 80` |
| Position | `0.1, 0, 0.85, 0` | `0.5, 0, 0.12, 0` |
| AnchorPoint | `0, 0.5` | `0.5, 0` |

**파일:** `Client/UI/TutorialUI.lua` Line 159-161

---

### S-27a.3: Orphan Notice 세션 1회 → 전이 기반 rate limit

#### ~05:XX - 정책 변경

**문제:**
- 기존: 세션당 1회만 Notice 표시 (`OrphanNoticeShown` boolean)
- 결과: 두 번째/세 번째 고아 발생 시 유저가 놓침

**수정 (전이 기반 + 쿨다운 + 세션 상한):**
1. `OrphanNoticeShown` 제거
2. `ORPHAN_NOTICE_COOLDOWN_SEC = 25`: 연속 Notice 사이 최소 대기
3. `ORPHAN_NOTICE_MAX_PER_SESSION = 2`: 세션당 최대 Notice 횟수
4. `_orphanNoticeCount`, `_lastOrphanNoticeAt`: rate limit 상태 추적

**핵심 로직:**
- orphan 0→>0 전이 시 Notice 후보 시작 (debounce 0.5초)
- debounce 완료 시 rate limit 체크:
  - 쿨다운 25초 미경과 → 차단
  - 세션 상한 2회 도달 → 차단
  - 통과 → Notice 표시, count++

**수정 파일 (1개):**
| 파일 | 변경 내용 |
|------|----------|
| Client/UI/MainHUD.lua | rate limit 상수/변수 추가, MaybeTriggerOrphanNotice 수정 |

**Exit Criteria:**
- E1: 첫 번째 고아 → Notice 정상 표시
- E2: 두 번째 고아 (쿨다운 후) → Notice 정상 표시 (count=2)
- E3: 쿨다운 이내 고아 → Notice 차단 (RATE_LIMIT 로그)
- E4: 세션 상한 도달 후 → Notice 차단

---

### S-27a.2.1: Orphan Notice debounce 구조적 결함 수정

#### ~XX:XX - deferred check 스케줄링 추가

**문제:**
- S-27a.2 debounce 로직에서 `NOTICE_CANDIDATE_START` 후 early return
- 0.5초 후 다른 데이터 업데이트가 없으면 `MaybeTriggerOrphanNotice`가 재호출되지 않음
- 결과: debounce 타임아웃 체크에 도달하지 못해 Notice가 영원히 안 뜸

**수정:**
1. `_orphanDeferredCheckToken`: deferred check 토큰 (중복/무효화 방지)
2. Candidate 시작 시 `task.delay(0.55s)` 스케줄링
3. Deferred check에서 토큰 검증 후 `self:RenderOrphanBadge()` 재호출
4. Orphan이 0으로 복귀하면 토큰 증가로 pending check 무효화

**수정 파일 (1개):**
| 파일 | 변경 내용 |
|------|----------|
| Client/UI/MainHUD.lua | `MaybeTriggerOrphanNotice`에 self 파라미터 추가, deferred check 스케줄링 |

**Exit Criteria:**
- E1: 요리 완료 직후 race에서 Notice 오탐 안 뜸 (S-27a.2 유지)
- E2: grace_expired로 인한 진짜 고아에서 0.5초 후 Notice 뜸
- E3: 일시적 고아(0.5초 미만) 후 복귀 시 Notice 안 뜸

---

### S-27a.2: Orphan Notice 오탐 버그 수정 (sync gate + baseline + debounce)

#### ~05:XX - 버그 수정

**문제 (S-27a.1 이후 추가 발견):**
- 요리 완료 직후 inventory 업데이트가 orders 업데이트보다 먼저 도착
- 일시적으로 `orphan = inv - reserved = 1`이 되어 Notice 오탐 발생
- S-27a.1의 "전이 감지"가 이 일시적 상태를 "진짜 전이"로 오인

**수정 (동기화 게이트 + baseline + 전이 + **debounce**):**
1. `_seenOrdersOnce`, `_seenInventoryOnce`: 동기화 완료 게이트
2. `_orphanBaselineSet`: 첫 동기화 완료 시 baseline만 설정 (Notice 없음)
3. `_orphanWasZero`: 전이(0→>0) 감지용 플래그
4. **`_orphanCandidateSince` + `ORPHAN_NOTICE_DEBOUNCE_SECONDS=0.5`**: 0.5초 이상 유지 시에만 Notice

**핵심 로직:**
- orphan이 0→>0으로 전이되면 "후보" 시작
- 0.5초 이상 유지되면 Notice 표시
- 그 전에 orphan이 0으로 복귀하면 후보 취소 (요리 완료 직후 race 해소)

**수정 파일 (2개):**
| 파일 | 변경 내용 |
|------|----------|
| Client/UI/MainHUD.lua | debounce 로직 추가 (`MaybeTriggerOrphanNotice`) |
| Client/UI/NoticeUI.lua | 임시 디버그 로그 제거 |

**Exit Criteria:**
- E1: 요리 완료 직후 레이스에서 Notice 오탐 안 뜸
- E2: grace_expired로 인한 진짜 고아에서만 Notice 1회 뜸
- E3: 배지는 항상 정상 표시 (일시적 흔들림 허용)
- E4: 세션 시작 기존 dish는 baseline 처리

---

### S-29 + S-29.1: ESCAPE 배정 시 CustomerService 동기화

#### 04:XX - ✅ PASS

**S-29.1 추가 (로그 게이팅 + 캐싱):**
- `S-29|RESPAWN_DONE` 로그: Studio-only로 게이팅
- `GetCustomerService()`: ESCAPE 루프 전 1회 캐시 (`_escapeCS`)

**검증 로그 (03:52 세션):**
```
03:52:59.414 S-24|ESCAPE_MULTI_START dishKinds=1 dishTotal=1
03:52:59.414 S-29|RESPAWN_REMOVE slot=2 reason=escape_multi
03:52:59.414 PG2|LEAVE slot=2 customerId=customer_4 reason=escape_multi
03:52:59.414 PG2|SPAWN slot=2 customerId=customer_5 patienceMax=60.0
03:52:59.414 S-29|RESPAWN_DONE slot=2 newCustomerId=customer_5
03:52:59.414 S-24|ESCAPE_MULTI_DONE assigned=1
03:53:00.080 PG2|PATIENCE_TICK slot=2 old=60.0 new=59.3  ← 새 고객 정상!
```

**TC 결과:**
- TC-S29-01: ✅ PASS (ESCAPE 후 TIMEOUT 없음)
- TC-S29-02: ✅ PASS (customer_5 새 고객 할당)
- TC-S29-03: ✅ PASS (patience=60.0 시작)

**목적:**
- S-28 후속 버그: ESCAPE가 주문을 배정해도 기존 고객이 즉시 TIMEOUT → 주문 취소
- ESCAPE로 주문 교체 시 CustomerService의 고객도 리스폰 (patience 리셋)

**근본 원인:**
- ESCAPE_MULTI_ASSIGN이 주문(orders[slotId])만 교체
- CustomerService의 기존 고객(patience=0 상태) 유지됨
- 결과: 배정 직후 TIMEOUT → ORDER_CANCELED → orphan 무한 루프

**증거 로그 (03:27 세션):**
```
03:28:16.457 ESCAPE_MULTI_DONE assigned=1    ← 배정 성공
03:28:17.123 PG2|TIMEOUT slot=1 customer_1  ← 0.6초 후 타임아웃
03:28:17.123 ORDER_CANCELED slot=1          ← 주문 취소
```

**수정 파일 (2개):**
| 파일 | 변경 내용 |
|------|----------|
| CustomerService.lua | `RespawnCustomer()` 메서드 추가 |
| OrderService.lua | ESCAPE_MULTI_ASSIGN에서 RespawnCustomer 호출 |

**CustomerService.lua 상세:**
| 함수 | 내용 |
|------|------|
| `RespawnCustomer(player, slotId, reason)` | 기존 고객 제거 + 새 고객 스폰 (patience 리셋) |

**OrderService.lua 상세:**
| 위치 | 변경 |
|------|------|
| ESCAPE_MULTI_ASSIGN 내부 (L1564-1568) | 주문 배정 후 `CS:RespawnCustomer(player, slotId, "escape_multi")` 호출 |

**새 로그 포인트:**
- `S-29|RESPAWN_REMOVE` - 기존 고객 제거 (Studio only)
- `S-29|RESPAWN_DONE` - 새 고객 스폰 완료

**상태:** 🔶 구현 완료 → 테스트 필요

**테스트 케이스:**
- TC-S29-01: ESCAPE 배정 후 60초 내 TIMEOUT 없이 SERVE 가능
- TC-S29-02: ESCAPE 직후 새 customerId 할당 확인 (로그)
- TC-S29-03: ESCAPE 직후 patience = 60.0 확인

---

### S-28: 고아 Dish 재배정(ESCAPE) 예약 정합성 버그픽스

#### 03:XX - ✅ PASS (03:27 세션에서 검증 완료)

**목적:**
- S-27a 후속 버그: 고아 dish가 timer_rotate에서 재배정되지 않는 문제 해결
- ESCAPE 트리거/스킵 판단을 "예약(reservedDishKey)" 기반으로 정합화
- 서버/클라 계산 모델 SSOT 통일: `orphanCount = max(0, inv - reservedCount)`

**근본 원인:**
- `IsSlotDeliverable()`: reservation 없이도 deliverable=true로 판정
- `GetBoardRecipeIds()`: 예약 여부 무시하고 recipeId 존재만 체크
- 결과: 보드에 동일 recipeId가 있으면 ESCAPE 스킵 → 고아 영구화

**수정 파일 (1개):**
| 파일 | 변경 내용 |
|------|----------|
| OrderService.lua | IsSlotDeliverable, GetDeliverableOrderCount, ValidateBoardEscapePath 수정 |

**OrderService.lua 상세:**
| 함수 | 변경 |
|------|------|
| `IsSlotDeliverable()` | reservation 기반으로 변경: `reservedDishKey` 필수 + 해당 dish 수량 체크 |
| `GetDeliverableOrderCount()` | `IsSlotDeliverable()` 호출로 통일 |
| `ValidateBoardEscapePath()` | boardRecipes → orphanCount + 미예약 슬롯 존재 기준으로 변경 |

**새 로직 (SSOT):**
```
reservedCount[dishKey] = 보드에서 reservedDishKey == dishKey인 슬롯 수
orphanCount[dishKey] = max(0, inventoryCount - reservedCount)

ESCAPE 트리거: orphanCount > 0인 dish가 있고
              그 dish를 받을 미예약 슬롯(IsSlotDeliverable == false)이 존재
```

**로그 변경:**
- `S-24|ESCAPE_SKIPPED reason=all_dishes_represented` → `reason=no_assignable_orphan`

**검증 로그 (03:27 세션):**
```
03:28:16.456 S-24|ESCAPE_MULTI_START dishKinds=1 dishTotal=1
03:28:16.457 S-24|ESCAPE_MULTI_DONE assigned=1  ← ESCAPE 정상 실행 확인!
```

**상태:** ✅ **PASS** (S-29 통합 테스트 시 회귀 확인 예정)

---

## 2026-01-25

### PG-2 Extension 1차: 티켓 상태 배지 (Text-only)

#### 20:XX - 🔶 구현 완료 (테스트 필요)

**목적:**
- 티켓 카드에 예약/SERVE 상태 배지 표시 (텍스트 기반)
- 슬롯별 독립 갱신 (focusedSlot 의존 제거)
- PG-2 Core 연동 준비

**수정 파일 (2개):**
| 파일 | 변경 내용 |
|------|----------|
| ServerFlags.lua | `DEBUG_PG2_UI = false` 플래그 추가 |
| MainHUD.lua | StatusBadge UI 요소 추가, RefreshTicketBadges 함수 구현 |

**MainHUD.lua 상세:**
| 위치 | 변경 |
|------|------|
| CreateOrderBoard (티켓 슬롯 생성) | StatusBadge TextLabel 추가 (우측 상단) |
| RefreshTicketBadges(slotId) | 슬롯별 배지 갱신 ([SERVE✓], [RESERVED], 빈칸) |
| RefreshAllTicketBadges() | 전체 슬롯 일괄 갱신 |
| SetTicketPhase | RefreshTicketBadges 호출 추가 |
| UpdateOrders | RefreshAllTicketBadges 호출 추가 |
| UpdateInventory | RefreshAllTicketBadges 호출 추가 (nil 경로 포함) |

**배지 로직:**
| 조건 | 배지 | 색상 |
|------|------|------|
| reserved + inventory>=1 | `[SERVE✓]` | 녹색 |
| reserved only | `[RESERVED]` | 노란색 |
| else | (빈칸) | - |

**상태:** 🔶 구현 완료 → 테스트 필요 (TC-PG2-UI-01~03)

#### 20:21 - ❌ 테스트 실패 (Bug 2건)

**Bug 1: StatusBadge가 SERVE 버튼에 가려짐** → ✅ 수정됨
- 증상: `[SERVE✓]` 배지가 SERVE 버튼과 겹쳐서 가려짐
- 원인: StatusBadge Position(Y=47px)이 SERVE 버튼 위치와 충돌
- 수정: Position Y=47→6, TextSize 11→13, ZIndex 추가

**Bug 2: Reserved 슬롯 ROTATE (Critical)**
- 증상: `reservedDishKey`가 설정된 슬롯(SERVE 상태)이 60초 후 ROTATE됨
- 로그: `20:21:51 phase=SERVE` → `20:22:24 ROTATE slot=2`
- 원인: OrderService ROTATE 로직에서 reservation 체크 누락 추정

**상태:** ❌ FAIL → S-26으로 수정됨

---

### S-26: SERVE Grace Period + Countdown Badge (Bug 2 Fix)

#### 21:XX - 🔶 구현 완료 (테스트 필요)

**목적:**
- Bug 2 수정: SERVE 대기 중인 슬롯이 rotate/cancel로부터 보호
- 배지를 카운트다운 타이머로 변경 (유예 시간 표시)
- 서버 권위 원칙: serveDeadline은 서버에서 설정, 클라이언트는 표시만

**수정 파일 (3개):**
| 파일 | 변경 내용 |
|------|----------|
| ServerFlags.lua | `SERVE_GRACE_SECONDS = 15` 상수 추가 |
| OrderService.lua | serveDeadline 필드 추가, rotate/cancel 보호 |
| MainHUD.lua | 카운트다운 배지, 1초 갱신 타이머 |

**OrderService.lua 상세:**
| 함수 | 변경 |
|------|------|
| ReserveDish | `order.serveDeadline = os.time() + SERVE_GRACE_SECONDS` 설정 |
| ClearReservation | `order.serveDeadline = nil` 정리 |
| GetFIFOSlot | serveDeadline 유효한 슬롯 rotate 대상 제외 |
| CancelOrder | patience_timeout 시 serveDeadline 보호 가드 (취소 거부) |

**MainHUD.lua 상세:**
| 위치 | 변경 |
|------|------|
| 상수 | `BADGE_UPDATE_INTERVAL = 1` (1초) |
| 변수 | `lastBadgeUpdate = 0` |
| Init (Heartbeat) | 1초 간격 RefreshAllTicketBadges 호출 |
| RefreshTicketBadges | 카운트다운 로직으로 전면 변경 |

**배지 로직 (변경):**
| 조건 | 배지 | 색상 |
|------|------|------|
| serveDeadline 유효 + inventory>=1 | `[Xs]` 카운트다운 | 녹색 |
| serveDeadline 만료 | `[!]` 경고 | 빨강 |
| else | (빈칸) | - |

**보호 동작:**
| 시나리오 | 동작 |
|----------|------|
| rotate_one_slot | GetFIFOSlot에서 serveDeadline 슬롯 제외 → rotate 안 됨 |
| CancelOrder(patience_timeout) | serveDeadline 체크 후 취소 거부 → 보호됨 |

**상태:** 🔶 구현 완료 → 테스트 중

**테스트 케이스:**
- TC-S26-01: dish 제작 후 [15s] 배지 표시 확인
- TC-S26-02: 카운트다운 진행 (15→14→...→0) 확인
- TC-S26-03: 15초 내 rotate/cancel 안 됨 확인 (Bug 2 재현 안 됨)

#### 21:11 - 🔶 1차 테스트 (부분 성공)

**테스트 환경:**
- 시간: 2026-01-25 21:11
- 슬롯 2에서 Supreme Burger (Hard) 제작

**로그 증거:**
```
21:11:21.201 [CraftingService] S-14|COOK_TIME_COMPLETE uid=... slot=2 dishKey=dish_20
21:11:21.201 [MainHUD] P1|PHASE_CHANGED slot=2 phase=SERVE
```

**TC 결과:**
| TC | 결과 | 비고 |
|----|------|------|
| TC-S26-01 | ✅ PASS | [15s] 배지 표시됨 (스크린샷 확인) |
| TC-S26-02 | ⏳ 미확인 | 카운트다운 진행 여부 확인 필요 |
| TC-S26-03 | ✅ PASS | 로테이션 안 됨 (의도된 동작) |

**사용자 질문:** "15초는 나오는데 요리 로테이션은 안되는데 의도한거야?"

**분석:**
- **예, 의도된 동작입니다.**
- S-26의 목적: SERVE 대기 중인 슬롯을 rotate/cancel로부터 보호
- serveDeadline 유효 시간(15초) 내에는 로테이션 대상에서 제외됨
- 이것이 Bug 2 (Reserved 슬롯 ROTATE) 수정의 핵심

**확인 필요 사항:**
1. 카운트다운이 1초씩 감소하는지 (TC-S26-02)
2. 15초 만료 후 로테이션 되는지 (정상 동작)
3. 15초 내 SERVE 버튼 클릭 시 정상 납품되는지

**🚨 사용자 추가 질문:** "15초 후에도 로테이션이 안 되는데 의도한 거냐?"

**분석 (Claude):**
- 현재 rotate는 `ORDER_REFRESH_SECONDS = 60초` 주기로 발생
- serveDeadline 15초 만료 후에도 **즉시 rotate 아님**, 다음 60초 주기까지 대기
- patience_timeout도 serveDeadline 만료 후에야 취소 허용

**설계 질문 (ChatGPT 확인 필요):**
1. 15초 후 **즉시 rotate** vs **다음 60초 주기까지 대기** - 어떤 게 의도?
2. patience_timeout 경로: 15초 만료 후 patience=0이면 즉시 cancel 발생하는가?
3. 배지가 `[!]`로 바뀌는지 확인 필요 (15초 만료 시)

**ChatGPT 답변 (21:XX):** Q1=B, Q2=즉시cancel+중복방지, Q3=즉시액션필요

---

#### 21:XX - 🔶 S-26 Plan A 구현 완료 (테스트 필요)

**ChatGPT 승인 정책:**
- Q1: 옵션 B (15초 후 즉시 후속 처리)
- Q2: serveDeadline 만료 후 patience=0이면 즉시 cancel
- Q3: [!]만 표시는 불완전 → 만료 후 즉시 액션

**정책 확정 (추천 1안):**
```
serveDeadline 만료 시:
├─ patience > 0  → 즉시 rotate (주문 교체)
└─ patience <= 0 → 즉시 cancel (손님 떠남)
```

**수정 파일 (2개):**
| 파일 | 변경 내용 |
|------|----------|
| OrderService.lua | `RotateSlot`, `HandleServeGraceExpired` 함수 추가, `rotate_one_slot` 리팩토링 |
| CustomerService.lua | TickCustomer에 serveDeadline 만료 체크 추가 |

**OrderService.lua 상세:**
| 함수 | 역할 |
|------|------|
| `RotateSlot(player, slotId, reason)` | 슬롯 강제 교체 (공용 함수) |
| `HandleServeGraceExpired(player, slotId, patienceNow)` | 유예 만료 즉시 후속 처리 |
| `rotate_one_slot` | RotateSlot 호출로 리팩토링 |

**CustomerService.lua 상세:**
| 위치 | 변경 |
|------|------|
| `TickCustomer` | serveDeadline 만료 시 `HandleServeGraceExpired` 호출 |

**로그 추가:**
- `S-26|ROTATE uid=%d slot=%d newRecipe=%d reason=%s`
- `S-26|GRACE_EXPIRED uid=%d slot=%d action=%s patience=%.1f`

**상태:** 🔶 구현 완료 → 테스트 중

---

#### 00:06 (2026-01-26) - 🔶 2차 테스트 (부분 성공 + 새 이슈)

**테스트 환경:**
- 시간: 2026-01-26 00:06
- slot=2에서 양상추치즈버거 (dish_12) 제작

**로그 증거:**
```
00:06:43.170 dish_12 제작 완료 (slot=2)
00:06:58.116 S-26|GRACE_EXPIRED slot=2 action=rotate patience=37.1  ← 15초 후!
00:06:58.116 S-26|ROTATE slot=2 newRecipe=26 reason=grace_expired_rotate
00:06:58.116 S-24|ESCAPE_MULTI_START dishKinds=1 dishTotal=1
00:06:58.116 S-24|ESCAPE_MULTI_DONE assigned=1
00:06:58.150 slot=1 recipeId=12, phase=SERVE
```

**TC 결과:**
| TC | 결과 | 비고 |
|----|------|------|
| TC-S26-03 | ✅ PASS | 15초 후 즉시 rotate 발생 |
| 새 이슈 | ⚠️ 발견 | ESCAPE_HELD_DISH 연쇄 동작 |

**새 이슈: ESCAPE_HELD_DISH 연쇄 동작**
- grace_expired rotate 후 dish가 inventory에 남음
- ValidateBoardEscapePath → ESCAPE_HELD_DISH 트리거
- dish_12가 slot=1에 배치됨 → slot=1이 SERVE 상태로!
- UX 혼란: "slot=2 음식이 갑자기 slot=1로 이동한 것 같다"

**설계 질문 (ChatGPT 확인 필요):**
- Q6: grace_expired rotate 시 inventory dish 처리 정책?
- Q7: ESCAPE_HELD_DISH가 즉시 트리거되는 게 의도인가?

**ChatGPT 답변 (00:XX):**
- Q6: 옵션 A 유지 (dish 유지 + ESCAPE 트리거)
- Q7: YES (의도에 부합) - UX 개선만 필요

**ChatGPT 분석:**
- "음식이 이동한 게 아니라 주문이 음식에 맞게 재배치된 것"
- 시스템 관점에선 정상, UI/피드백이 없으니 "텔레포트"처럼 보임
- 정책(A)은 유지, UX만 정리

**결론:**
- S-26 핵심 기능: ✅ 완료 (15초 후 즉시 rotate)
- ESCAPE UX 개선: → **S-27로 분리** (S-26 범위 외)

**상태:** ✅ S-26 PASS (핵심 기능 완료) / S-27 대기 (UX 개선)

---

#### 01:XX (2026-01-26) - 🔶 S-26.1 구현 (ESCAPE 스킵)

**문제 발견 (ChatGPT):**
- S-26과 S-24가 "같은 목적을 서로 반대로 달성"
- S-26 grace_expired → S-24 ESCAPE 즉시 트리거 → 15초 페널티 무력화

**로그 증거 (원인 분석):**
```
S-26|GRACE_EXPIRED slot=2 action=rotate patience=37.1  ← 15초 페널티
S-26|ROTATE slot=2 newRecipe=26 reason=grace_expired_rotate
S-24|ESCAPE_MULTI_START dishKinds=1 dishTotal=1        ← ESCAPE 즉시 발동!
S-24|ESCAPE_MULTI_DONE assigned=1                      ← dish 자동 배정
```

**ChatGPT 결정 (S-26.1):**
> "S-26 grace_expired_*가 발생하면 즉시 rotate/cancel은 유지, 그 직후에는 S-24 ESCAPE를 실행하지 않는다(스킵)"

**수정 파일 (1개):**
| 파일 | 변경 내용 |
|------|----------|
| OrderService.lua | RotateSlot에서 grace_expired 사유일 때 ValidateBoardEscapePath 스킵 |

**OrderService.lua 상세:**
| 위치 | 변경 |
|------|------|
| RotateSlot | `isGraceExpired` 체크 후 ESCAPE 조건부 실행 |
| nil 방어 | `local reasonStr = reason or ""` (로그 출력 전에 정의) |
| 로그 수정 | `S-26\|ROTATE` 로그에서 `reason` → `reasonStr` 사용 (nil 크래시 방지) |
| 로그 추가 | `S-26.1\|ESCAPE_SKIPPED` (IS_STUDIO에서만 출력) |

**예상 동작:**
| 사유 | ESCAPE |
|------|--------|
| timer_rotate | ✅ 실행 |
| grace_expired_rotate | ❌ 스킵 |
| grace_expired_timeout | ❌ 스킵 |

**상태:** ✅ PASS

**테스트 결과 (02:08~02:12):**
| TC | 결과 | 증거 |
|----|------|------|
| TC-S26.1-01 | ✅ PASS | `S-26.1\|ESCAPE_SKIPPED uid=10309326624 slot=1 reason=grace_expired_rotate` |
| TC-S26.1-02 | ✅ PASS | dish가 inventory에 남음 (고아 상태), 새 슬롯에 배정 안 됨 |
| TC-S26.1-03 | ✅ PASS | `S-24\|ESCAPE_MULTI_START/DONE` at timer_rotate (60초 주기) |

**핵심 로그:**
```
02:08:53.425 S-26|GRACE_EXPIRED uid=10309326624 slot=1 action=rotate patience=28.6
02:08:53.425 S-26|ROTATE uid=10309326624 slot=1 newRecipe=23 reason=grace_expired_rotate
02:08:53.425 S-26.1|ESCAPE_SKIPPED uid=10309326624 slot=1 reason=grace_expired_rotate
...
02:09:18.011 S-26|ROTATE uid=10309326624 slot=2 newRecipe=24 reason=timer_rotate
02:09:18.011 S-24|ESCAPE_MULTI_START uid=10309326624 dishKinds=1 dishTotal=1
02:09:18.011 S-24|ESCAPE_MULTI_DONE uid=10309326624 assigned=1
```

---

### S-27a: Orphan Dish 표시 (표시/안내만, 폐기 없음)

#### 01:XX (2026-01-26) - ✅ PASS

**목적:**
- grace_expired로 인해 예약 해제된 고아 dish를 UI에 명확히 표시
- 플레이어 혼란 해소 ("왜 요리가 남아있지?")
- 서버 변경 없이 클라이언트 표시만 (폐기 기능은 S-28 예정)

**고아 계산식:**
```
orphanCount[dishKey] = max(0, inventoryCount[dishKey] - reservedCount[dishKey])
```
- 예: dish_12가 2개, reserved 슬롯 1개 → 고아 1개

**수정 파일 (2개):**
| 파일 | 변경 내용 |
|------|----------|
| MainHUD.lua | InventoryFrame 확장, OrphanLabel 추가, 고아 계산/렌더 함수 |
| NoticeUI.lua | orphan_dish_warning 메시지 추가 |

**MainHUD.lua 상세:**
| 위치 | 변경 |
|------|------|
| CreateInventoryPanel | Frame 높이 80→115, OrphanLabel 추가 |
| 신규: ComputeReservedCounts() | cachedOrders에서 reservedDishKey 카운트 |
| 신규: ComputeOrphanCounts(inv) | orphan = max(inv - reserved, 0) |
| 신규: RenderOrphanBadge() | OrphanLabel 텍스트 갱신 + Notice 1회 |
| UpdateOrders | RenderOrphanBadge() 호출 추가 |
| UpdateInventory | RenderOrphanBadge() 호출 추가 (정상 + nil 경로) |

**UI 표시:**
| 상태 | 표시 |
|------|------|
| 고아 있음 | `🧾 고아: 2개 (루틴버거×1, 베이컨버거×1)` |
| 고아 없음 | (숨김) |

**Notice (세션당 1회):**
- 코드: orphan_dish_warning
- 메시지: "주문 만료로 분리된 요리가 있습니다. 다음 주문에 자동 연결될 수 있습니다."

**상태:** ✅ PASS

**테스트 결과 (02:08~02:12):**
| TC | 결과 | 증거 |
|----|------|------|
| TC-S27a-01 | ✅ PASS | 스크린샷: `🧾 고아: 1개 (울트라버거×1)` 표시 |
| TC-S27a-03 | ✅ PASS | grace_expired 직후 고아 라벨 즉시 표시됨 |
| TC-S27a-04 | ✅ PASS | timer_rotate ESCAPE 후 고아 자동 해소 (라벨 숨김) |

**스크린샷 확인:**
- 인벤토리 패널 하단: `🧾 고아: 1개 (울트라버거×1)`
- InventoryFrame 높이 확장 (80→115px) 정상 작동

---

### S-25: S-24 디버그 로그 운영 스팸 정리

#### 19:XX - ✅ S-25 완료 (DEBUG_S24 게이팅)

**목적:**
- S-24 디버그 로그를 `DEBUG_S24` 플래그로 게이팅
- 운영 환경에서 로그 스팸 방지
- 기능/Contract 변경 없음

**수정 파일 (4개):**
| 파일 | 변경 내용 |
|------|----------|
| ServerFlags.lua | `DEBUG_S24 = false` 플래그 추가 |
| OrderService.lua | 7개 로그 DEBUG 게이팅 |
| DataService.lua | 1개 로그 DEBUG 게이팅 |
| MainHUD.lua | 13개 로그 DEBUG 게이팅 |

**로그 분류:**
| 분류 | 개수 | 예시 |
|------|------|------|
| 운영 유지 | 7 | `RECONCILE_*`, `ESCAPE_MULTI_START/DONE`, `SERVE_BLOCKED`, `RESERVATION_MISMATCH` |
| DEBUG 게이팅 | 21 | `INIT_PAYLOAD`, `CLIENT_ORDERS`, `SERVE_BTN`, `AUTO_SERVE`, `ESCAPE_ASSIGN` 등 |

**상태:** ✅ 완료 → 테스트 필요

---

### S-24: Reservation-based Serve Tightening

#### 19:19 - ✅ S-24 PASS (TC-S24-E01 통과)

**테스트 결과:**
```
[S-24|ESCAPE_MULTI_START] dishKinds=4 dishTotal=5
[S-24|ESCAPE_ASSIGN] slot=1 dishKey=dish_24
[S-24|ESCAPE_ASSIGN] slot=2 dishKey=dish_30
[S-24|ESCAPE_ASSIGN] slot=3 dishKey=dish_30
[S-24|ESCAPE_MULTI_DONE] assigned=3
[S-24|AUTO_SERVE] slot=1,2,3 모두 SERVE 활성화
```

**TC 결과:**
- ✅ TC-S24-P1: SERVE 버튼 크래시 없음
- ✅ TC-S24-E01: dish 4종/5개 → 3슬롯 SERVE 성공
- ✅ TC-S24-SYNC: `SERVE_IGNORED no_order` 없음

**상태:** ✅ **PASS**

---

#### 19:20 - P2-FIX: ANY-match → ALL-match 변경 (코드 수정)

**수정 내용:**
| 파일 | 변경 |
|------|------|
| OrderService.lua | `hasMatchingOrder` (ANY-match) → `hasUnmatchedDish` (ALL-match) |

**변경 전:** "하나라도 매칭되면 스킵"
**변경 후:** "모든 dish가 매칭되어야 스킵"

**추가 로그:**
- `S-24|ESCAPE_SKIPPED reason=all_dishes_represented` (전부 매칭 시)

**상태:** ✅ 코드 수정 완료 → 테스트 PASS

---

#### 19:15 - 테스트 실패 (ESCAPE_HELD_DISH 미실행)

**P1 수정:** ✅ PASS (크래시 없음)

**P2 테스트 결과:** ❌ FAIL
- `S-24|ESCAPE_MULTI_DONE` 로그 없음
- slot 2만 SERVE (dish_24)

**근본 원인:**
```lua
if not hasMatchingOrder then  -- ← 여기서 막힘!
    -- ESCAPE 다중 처리
end
```
- `heldDishRecipeIds` = {24, 30, 18, 21}
- `boardRecipes` = {10, 24, 11}
- 24가 보드에 있음 → `hasMatchingOrder = true` → ESCAPE 스킵!

**논리적 결함:**
- 현재: "하나라도 매칭되면 스킵"
- 필요: "모든 dish가 매칭되어야 스킵"

**상태:** ✅ 분석 완료 → P2-FIX 적용

---

#### 19:15 - P1 + P2 수정 완료 (코드 수정)

**P1 수정 (Critical):**
| 파일 | 변경 |
|------|------|
| MainHUD.lua | `cachedOrders` 선언을 line 29로 이동 |
| MainHUD.lua | 기존 line 1340 선언 제거 (주석으로 대체) |

**P2 수정 (High):**
| 파일 | 변경 |
|------|------|
| OrderService.lua | ESCAPE_HELD_DISH 트리거 조건 완화 |

**변경 전:** `deliverableCount == 0`
**변경 후:** `deliverableCount < math.min(#heldDishRecipeIds, ORDER_SLOT_COUNT)`

**상태:** ✅ 코드 수정 완료 → 테스트에서 실패

---

#### 19:10 - ChatGPT 지시문 수신

**ChatGPT 승인:** 즉시 진행 지시

**지시 내용:**
1. P1: `cachedOrders` 상단 이동
2. P2: 트리거 조건 완화 → `deliverableCount < maxDeliverable`

**상태:** ✅ 승인 완료 → 수정 진행

---

#### 19:04 - 테스트 실패 (Runtime Error)

**에러:**
```
MainHUD:1288: attempt to index nil with number
```

**근본 원인:** Lua 스코프 순서 버그
- `OnServeButtonClicked` 함수: 1282번 줄
- `cachedOrders` 선언: 1340번 줄
- Lua에서 local 변수는 선언 이후에만 접근 가능 → nil 에러

**추가 문제:**
- ESCAPE_HELD_DISH 미작동 (`patchedSlots=none`)
- slot 2만 SERVE (reserved=dish_24), 나머지 dish 방치

**상태:** ❌ FAIL - ChatGPT 검토 완료

---

#### 19:XX - 다중 Dish 처리 + 클라이언트 방어 코드 (수정 완료, 테스트 전)

**수정 내용:**

| 파일 | 내용 |
|------|------|
| OrderService.lua | `IsSlotDeliverable` 헬퍼 함수 추가 (슬롯 배달 가능 여부 판정) |
| OrderService.lua | `ESCAPE_HELD_DISH` 다중 dish 처리 (최대 3슬롯 동시 배치, 3동일 방지) |
| MainHUD.lua | `UpdateOrders` 문자열 키 폴백 추가 (`ordersData[tostring(i)]`) |
| MainHUD.lua | `OnServeButtonClicked` 진입 시 상태 로깅 (`S-24\|SERVE_BTN`) |

**목표:**
- TC-S24-03: 5 dish 보유 시 3슬롯 동시 SERVE
- TC-S24-04: `SERVE_IGNORED no_order` 에러 제거

**상태:** 🔶 수정 완료 → 테스트에서 실패

---

#### 18:53 - 부분 성공

**테스트 결과:**
- ✅ slot=1 SERVE 전환 성공 (`S-24|AUTO_SERVE slot=1 reserved=dish_24`)
- ❌ 나머지 dish (dish_30, dish_18, dish_21) 주문 매칭 안 됨
- ❌ SERVE 버튼 클릭 시 `no_order` 에러

**원인:**
1. `ESCAPE_HELD_DISH`가 첫 번째 dish만 처리
2. SERVE 버튼 클릭 시 `cachedOrders` 동기화 문제 의심

---

#### 18:50 - ESCAPE_HELD_DISH 수정

| 파일 | 내용 |
|------|------|
| OrderService.lua | `ESCAPE_HELD_DISH`에서 `reservedDishKey` 설정 추가 |

---

#### 18:45 - 디버그 로그 추가

| 파일 | 내용 |
|------|------|
| DataService.lua | `S-24\|INIT_PAYLOAD` 로그 |
| MainHUD.lua | `S-24\|CLIENT_ORDERS` 로그 |

---

#### 18:42 - ReconcileReservations 호출 추가

| 파일 | 내용 |
|------|------|
| Main.server.lua | PlayerAdded에서 `ReconcileReservations` 호출 |
| OrderService.lua | `RECONCILE_START`, `RECONCILE_DONE` 로그 |

---

#### 18:37 - BroadcastCraftComplete orders 동기화

| 파일 | 내용 |
|------|------|
| RemoteHandler.lua | `BroadcastCraftComplete`에 orders 자동 동기화 |

---

#### 초기 구현

| 파일 | 내용 |
|------|------|
| OrderService.lua | `ReserveDish`, `ClearReservation`, `ReconcileReservations` |
| CraftingService.lua | dish 생성 후 `ReserveDish` 호출 (3곳) |
| MainHUD.lua | C-3 AUTO_SERVE `reservedDishKey` 기반 변경 |

**상태:** 🔶 추가 수정 필요

---

### S-23: 멀티태스킹 UI 오염 (PASS)

| 파일 | 내용 |
|------|------|
| MainHUD.lua | `focusedSlot` 폴백 제거, `other_crafting` → `idle` |

**상태:** ✅ PASS
