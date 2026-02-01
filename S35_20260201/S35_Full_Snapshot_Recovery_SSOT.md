# S-35 Full Snapshot Recovery — Client Self-Heal (SSOT)

**Doc Path:** `Docs/SSOT/S35_Full_Snapshot_Recovery_SSOT.md`
**Status:** DRAFT
**Owner:** Cloud AI
**Related:** S-33 (Client Audit), S-36 (Schema Spec)
**Last Updated:** 2026-02-01

---

## 0) 목적

S-33(P1)의 탐지(Audit) 결과, 클라이언트 로컬 상태가 서버 권위 상태와 불일치할 가능성이 확인되면, 클라이언트가 서버에 Full Snapshot을 요청하여 로컬 상태를 권위 스냅샷으로 덮어쓰기(self-heal) 한다.

- **목표:** "조용히 깨짐"을 자동 복구 경로로 수렴
- **범위:** Inventory / Orders / Stale2Keys / Wallet / Cooldown (S-36 스키마 준수)

---

## 1) 비목표 (OUT)

- 스냅샷에 기반한 "부분 merge" 최적화 (P2)
- 서버/클라 전체 프로토콜 재설계
- 악성/치팅 대응(보안 강화) 전부 (단, 최소한의 rate-limit/validation은 포함)

---

## 2) 결정 항목 (Decisions)

### D1. 트리거 조건 (Client)

S-33 Audit에서 아래 위반 발생 시 snapshot 요청 후보:

| auditKey | 트리거 조건 |
|----------|-------------|
| `st2_missing_inventory`, `st2_zero_qty` | 1회 발생 → debounce 후 요청 |
| `ord_bad_shape`, `ord_bad_reserved_key` | 1회 발생 → debounce 후 요청 |
| `inv_negative` | **debounce 1.0s → 재검증 → 여전히 음수면 요청** |

**inv_negative 특별 처리 이유:**
- 서버가 음수를 보내는 경우, snapshot 받아도 같은 값 → 복구 무의미
- debounce + 재검증으로 일시적 race condition 필터링
- 전역 rate-limit(30s)으로 무한 루프 방지

### D2. 요청/응답 채널

- **요청:** `RE_RequestFullSnapshot` (Client → Server)
- **응답:** `RE_SyncState`를 통해 `scope="FullSnapshotResponse"` 전송 (Server → Client)
- 기존 `HandleServiceResponse` 파이프라인 재사용 (관측/로직 일관성)

### D3. Rate-limit / Debounce (필수)

**Client:**
- `debounce = 1.0s` (audit spam을 한 번에 묶기)
- `minInterval = 30s` (uid 기준, 전역)
- 동일 세션에서 연속 audit 위반이 나도 30초에 1번만 요청

**Server:**
- uid 기준 `minInterval = 30s`로 동일하게 차단
- 차단 시 무응답 또는 WARN 로그 (거부 응답 없음, 노이즈 최소화)

### D4. Snapshot 범위 (P1 필수)

서버가 내려주는 스냅샷에 포함:

| 필드 | 필수 | 비고 |
|------|------|------|
| `inventory` | ✅ | 혼합 스키마 (S-36) |
| `orders` | ✅ | reserved 필드 포함 |
| `Stale2Keys` | ✅ | 배열 → 클라에서 Set 변환 |
| `wallet` | ✅ | UI/표시 일관성 |
| `cooldown` | ✅ | 버튼/연타 제어 일관성 |

**원칙:** "게임 진행/UX에 영향을 주는 클라 캐시"는 스냅샷에 포함

### D5. 적용 정책 (Client Apply)

`FullSnapshotResponse` 수신 시:
```lua
ClientData.inventory = snapshot.inventory
ClientData.orders = snapshot.orders
ClientData.stale2Set = ToSet(snapshot.Stale2Keys)
ClientData.wallet = snapshot.wallet
ClientData.cooldown = snapshot.cooldown
```

**병합 금지:** 로컬 state를 신뢰하지 않고 "권위 덮어쓰기"로 단순화

### D6. RECOVERY 상태 연계

- Client가 이미 RECOVERY 상태이거나, 서버가 데이터 로드 실패 상태면:
  - 스냅샷 요청은 무시/보류 (추가 부하/혼란 방지)

### D7. 스키마 위반 스냅샷 정책

- 스냅샷이 S-36 스키마를 위반해도 **적용한다** (서버가 권위)
- 단, 로그를 남긴다: `S-35|SNAPSHOT_APPLY_WARN schema_violation=...`
- 적용 후 S-33 audit이 다시 문제를 "탐지"하도록 유지
- **거절/RECOVERY 전환 금지** (복구 불가 루프 방지)

### D8. Observability (로그키)

**Client 로그:**
- `S-35|SNAPSHOT_REQ key=<auditKey> reason=<...> uid=<uid>`
- `S-35|SNAPSHOT_APPLY scopes=inventory,orders,stale2Set,wallet,cooldown`
- `S-35|SNAPSHOT_APPLY_WARN schema_violation=<details>`
- `S-35|SNAPSHOT_SKIP reason=rate_limit|recovery|revalidation_pass`

**Server 로그:**
- `S-35|SNAPSHOT_SERVE uid=<uid> bytes=<n> reason=<...>`
- `S-35|SNAPSHOT_DROP uid=<uid> reason=rate_limit|bad_state`

---

## 3) 불변식 (Invariants)

### I35-01 서버 권위 덮어쓰기
- `FullSnapshotResponse` 적용 시, 클라 로컬 상태는 전부 스냅샷으로 교체
- 부분 merge/증분 패치 금지 (P1)

### I35-02 스키마 준수 (soft)
- Inventory/Orders/Stale2Keys는 S-36 스키마를 만족해야 함
- 위반 시에도 적용하되 WARN 로그 (D7)

### I35-03 요청 폭주 방지
- Client/Server 모두 uid 기준 rate-limit 필수 적용

---

## 4) 테스트 케이스 (TC)

### TC-S35-01 (Happy: mismatch → snapshot → heal)
- **Setup:** (Studio only) 로컬 상태를 의도적으로 깨뜨림
  - 예: `ClientData.stale2Set["dish_10"]=true` 인데 `inventory["dish_10"]=nil`
- **Expect:**
  - Client: `S-35|SNAPSHOT_REQ ...`
  - Server: `S-35|SNAPSHOT_SERVE ...`
  - Client: `S-35|SNAPSHOT_APPLY ...`
  - 이후 S-33 audit 경고가 사라짐(또는 감소)

### TC-S35-02 (Rate-limit)
- 30초 내에 audit 위반을 3회 유발
- **Expect:**
  - snapshot 요청은 1회만 발생
  - `S-35|SNAPSHOT_SKIP reason=rate_limit` 또는 요청 없음

### TC-S35-03 (inv_negative 재검증)
- `ClientData.inventory["dish_10"] = -1` 주입
- 1.0s 후 재검증 전에 값을 0으로 복구
- **Expect:**
  - `S-35|SNAPSHOT_SKIP reason=revalidation_pass`
  - snapshot 요청 없음

### TC-S35-04 (스키마 위반 스냅샷 apply)
- 서버가 스키마 위반 스냅샷 전송 (인위적)
- **Expect:**
  - `S-35|SNAPSHOT_APPLY_WARN schema_violation=...`
  - 스냅샷 **적용됨** (거절 안 함)
  - 이후 S-33 audit이 문제 감지

### TC-S35-05 (Server deny / bad state)
- 서버가 RECOVERY/데이터 없음 상태
- **Expect:**
  - `S-35|SNAPSHOT_DROP reason=bad_state` (server)
  - client는 계속 진행하되, S-33 audit 유지

---

## 5) Exit Criteria

- [ ] TC-S35-01 PASS
- [ ] TC-S35-02 PASS
- [ ] TC-S35-03 PASS
- [ ] TC-S35-04 PASS (스키마 위반 apply 확인)
- [ ] TC-S35-05 PASS (또는 NOT RUN + 사유)
- [ ] 로그키/레이트리밋 확인
- [ ] CHANGELOG.md에 TC 결과 기록

---

## 6) 구현 메모 (Cloud AI 참고)

1. ClientController의 `updatedScopes` 패턴과 동일하게:
   - audit이 "요청 후보"를 만들고
   - debounce 후 remote 요청 1회 발생

2. snapshot apply는 **UI가 읽는 단일 source(ClientData)**만 교체

3. `inv_negative` 재검증 로직:
   ```lua
   -- audit에서 inv_negative 발생 시
   _s35PendingRevalidation = { dishKey = key, detectedAt = tick() }

   -- 1.0s 후 재검증
   task.delay(1.0, function()
       if ClientData.inventory[key] and ClientData.inventory[key] < 0 then
           -- 여전히 음수 → snapshot 요청
           RequestFullSnapshot("inv_negative", key)
       else
           -- 복구됨 → 스킵
           log("S-35|SNAPSHOT_SKIP reason=revalidation_pass")
       end
   end)
   ```

4. RE_SyncState 응답 처리:
   ```lua
   if scope == "FullSnapshotResponse" then
       -- D5 적용 정책
       ClientData.inventory = data.inventory
       ClientData.orders = data.orders
       ClientData.stale2Set = ToSet(data.Stale2Keys)
       ClientData.wallet = data.wallet
       ClientData.cooldown = data.cooldown
       -- StateChanged 발화
       for _, s in ipairs({"inventory", "orders", "stale2Set", "wallet", "cooldown"}) do
           ClientEvents.StateChanged:Fire(s, ClientData[s])
       end
   end
   ```
