# S35_Implementation_Checklist

**Doc Path:** `Docs/Audit/S35_Implementation_Checklist.md`
**Feature:** S-35 Full Snapshot Recovery (Client Self-Heal)
**Status:** ✅ IMPLEMENTED (TC 대기)
**SSOT:** `Docs/SSOT/S35_Full_Snapshot_Recovery_SSOT.md`
**Related:** S-33 (Audit), S-36 (Schema)
**Updated:** 2026-02-01

---

## 0) 목표

- S-33 Audit에서 불일치 탐지 시, 클라가 서버에 Full Snapshot을 요청하고
- 서버 권위 스냅샷으로 ClientData를 **교체(merge 금지)**하여 self-heal한다.
- 응답은 **RE_SyncState + scope="FullSnapshotResponse"**로 통일한다.

---

## 1) 범위 / 비범위 재확인

### IN
- Client: trigger(debounce/revalidation/rate-limit) + request + apply
- Server: request 수신 + rate-limit + snapshot payload 구성 + RE_SyncState 전송
- Snapshot fields: inventory/orders/Stale2Keys/wallet/cooldown

### OUT
- 부분 merge/증분 최적화(P2)
- Debug Remote/Studio 전용 핸들러 추가(원칙적으로 금지)
- 보안/치팅 방어 전면 강화(최소 rate-limit/기본 validation만)

---

## 2) 선행 조건 체크

- [x] S-33 P1(P1.5 포함) CLOSED 상태 확인
- [x] S-36 Inventory/Orders schema 문서 존재 및 팀 합의 상태
- [x] ClientController에서 `RE_SyncState` 수신 후 scope별 apply 경로가 존재(또는 추가 가능)
- [x] Server 쪽에서 "현재 권위 상태"를 한 번에 구성 가능한 헬퍼 접근 가능
  - 예: PlayerData에서 inventory/orders/wallet/cooldown, DataService에서 Stale2Keys 생성

---

## 3) 구현 작업 체크리스트 (Client)

### C1. 트리거 소스 정의 (S-33 Audit 연계)
- [x] S-33 Audit에서 위반 발생 시 `_s35TriggerCandidate(auditKey, ctx, isInvNegative)` 호출하도록 연결
- [x] 대상 auditKey:
  - st2_missing_inventory, st2_zero_qty (AuditStale2Set)
  - ord_bad_shape, ord_bad_reserved_key (AuditOrders)
  - inv_negative (특수 처리) (AuditInventory)

### C2. debounce + rate-limit
- [x] debounce: 1.0s (동일 세션 내 후보를 묶음) - `S35_DEBOUNCE_SECONDS`
- [x] rate-limit: uid 기준 30s (전역) - `S35_RATE_LIMIT_SECONDS`
- [x] 로그:
  - `S-35|SNAPSHOT_REQ ...` (_s35SendRequest)
  - `S-35|SNAPSHOT_SKIP reason=rate_limit|recovery|revalidation_pass`

### C3. inv_negative 재검증 (핵심)
- [x] inv_negative 발생 시 **즉시 요청 금지** - `isInvNegative=true`
- [x] 1.0s 후 해당 dishKey qty 재확인 - `task.delay(S35_REVALIDATION_DELAY, ...)`
- [x] 여전히 음수면 요청 / 아니면 `revalidation_pass`로 skip

### C4. Request Remote
- [x] Remote 이름 확정: `RE_RequestFullSnapshot` (Client → Server)
- [x] payload 최소화:
  - reasonKey(auditKey), requestId
- [x] 서버 요청 실패/무응답 시: 조용히 종료(노이즈 최소화)

### C5. Apply: FullSnapshotResponse
- [x] `RE_SyncState(scope="FullSnapshotResponse", response)` 수신 처리 추가/확인
- [x] 적용 정책(merge 금지):
  - ClientData.inventory = snapshot.inventory
  - ClientData.orders = snapshot.orders
  - ClientData.stale2Set = ToSet(snapshot.Stale2Keys)
  - ClientData.wallet = snapshot.wallet
  - ClientData.cooldown = snapshot.cooldown
- [ ] 스키마 위반이어도 **적용** + `S-35|SNAPSHOT_APPLY_WARN schema_violation=...` (P2)
- [x] apply 후 StateChanged 발화(최소):
  - inventory, orders, stale2Set, wallet, cooldown

### C6. RECOVERY 연계
- [ ] 클라가 RECOVERY(또는 동등 상태)면 요청 skip (Server에서 처리)
- [ ] skip 로그: `S-35|SNAPSHOT_SKIP reason=recovery` (Server가 drop함)

---

## 4) 구현 작업 체크리스트 (Server)

### S1. Rate-limit
- [x] uid 기준 30s - `_s35RateLimitCache`, `S35_RATE_LIMIT_SECONDS`
- [x] 차단 시:
  - 전송하지 않음
  - `S-35|SNAPSHOT_DROP uid=... reason=rate_limit`

### S2. bad_state 처리
- [x] PlayerData 없음 / 로드 실패 / RECOVERY 상태면:
  - `S-35|SNAPSHOT_DROP reason=bad_state`
  - 응답 전송 없음(노이즈 최소화)

### S3. Snapshot payload 구성
- [x] inventory (S-36 혼합 스키마) - deep copy
- [x] orders (reserved* 포함) - deep copy
- [x] Stale2Keys (배열) - GetStale2Keys() 호출
- [x] wallet / cooldown
- [x] 전송 로그: `S-35|SNAPSHOT_SERVE uid=... bytes=... reason=<auditKey>`

### S4. 응답 전송 경로
- [x] `RE_SyncState:FireClient(player, "FullSnapshotResponse", response)`
- [x] response 형식: 직접 snapshot 객체 전달 (requestId, reasonKey, serverTime 포함)

---

## 5) TC 체크리스트

### TC-S35-01 Happy (mismatch → snapshot → heal)
- [ ] mismatch 유발(Studio manual injection or temp code)
- [ ] Client: SNAPSHOT_REQ
- [ ] Server: SNAPSHOT_SERVE
- [ ] Client: SNAPSHOT_APPLY
- [ ] 이후 S-33 audit 경고 감소/소거 확인

### TC-S35-02 Rate-limit
- [ ] 30초 내 3회 유발
- [ ] 요청 1회만 발생 / skip 확인

### TC-S35-03 inv_negative 재검증
- [ ] inv_negative 주입 후 1.0s 내 정상화
- [ ] SNAPSHOT_SKIP revalidation_pass 확인

### TC-S35-04 스키마 위반 apply
- [ ] 스키마 위반 payload(테스트 환경)
- [ ] APPLY_WARN 기록 + 적용 수행 + S-33 audit 지속 감지

### TC-S35-05 bad_state
- [ ] server bad_state에서 drop 확인
- [ ] 클라 폭주 없음(레이트리밋)

---

## 6) CHANGELOG 반영 (필수)

- [x] `CHANGELOG.md`에 S-35 섹션 추가/갱신
- [ ] TC 결과 기록:
  - TC-S35-01 ⏳
  - TC-S35-02 ⏳
  - TC-S35-03 ⏳
  - TC-S35-04 ⏳
  - TC-S35-05 ⏳

---

## 7) 주의사항

- Debug Remote 추가 금지 원칙 유지(필요 시 TEMP 코드 → 테스트 → 즉시 제거)
- "서버 권위 덮어쓰기" 원칙 위반 금지(merge 금지)
- inv_negative는 반드시 재검증 후 요청(루프 방지)

---

## 8) 구현 결과 요약

### 수정 파일 (4개)

| 파일 | 변경 내용 |
|------|----------|
| `Main.server.lua` | RE_RequestFullSnapshot Remote 생성 (line 62-65) |
| `DataService.lua` | BuildFullSnapshot() 함수 추가 |
| `RemoteHandler.lua` | RE_RequestFullSnapshot 핸들러 (rate-limit 30s) |
| `ClientController.client.lua` | S-35 섹션 전체 (lines 228-325) |

### Client 변경 상세

1. **Config 섹션** (lines 228-246)
   - `S35_DEBOUNCE_SECONDS = 1.0`
   - `S35_RATE_LIMIT_SECONDS = 30`
   - `S35_REVALIDATION_DELAY = 1.0`

2. **_s35ShouldRequest()**: rate-limit 체크
3. **_s35SendRequest()**: Remote 요청 발송
4. **_s35TriggerCandidate()**: debounce + inv_negative 재검증
5. **FullSnapshotResponse 핸들러**: 완전 덮어쓰기 + StateChanged
6. **Audit 함수 연동**: inv_negative, ord_bad_*, st2_* 트리거 연결
