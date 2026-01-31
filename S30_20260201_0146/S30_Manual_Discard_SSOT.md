# S-30 SSOT — 수동 폐기 버튼

> 상태: **APPROVED** (2026-02-01)

---

## 1. 목표

플레이어가 보유 인벤토리의 특정 요리를 **수동으로 폐기**하여, orphan 정체/공간 점유를 해소하고 플레이 흐름을 복구한다.

---

## 2. 비목표

- 재활용/직원식/세일/환불 등 "폐기 이후 보상/변환" 시스템은 이번 범위 밖
- Stale 승격 규칙(S-29.2) 변경 없음
- 튜토리얼/업적/경제 밸런스 대개편은 범위 밖
- **staleCounts 전체 동기화는 범위 밖** (Stale2Keys 최소 동기화만 포함)

---

## 3. 폐기 대상 조건

**결정: A) Stale II만 허용**

| 선택지 | 설명 | 채택 |
|--------|------|------|
| A | Stale II만 허용 | ✅ |
| B | Stale I/II만 허용 | |
| C | 모든 요리(Fresh 포함) 허용 | |

**이유:** 실수 폐기 리스크 최소화, S-29.2 페널티 흐름과 정합

---

## 4. UI/UX 플로우

**결정: A) 인벤토리 패널에서 dish 항목 선택 → [폐기] 버튼**

| 선택지 | 설명 | 채택 |
|--------|------|------|
| A | 인벤 항목 선택 → [폐기] 버튼 | ✅ |
| B | 별도 "폐기 모드/탭" | |

**플로우:**
1. 인벤토리 패널에서 Stale II 요리 선택
2. [폐기] 버튼 클릭
3. 확인창: **"[요리명]을 폐기할까요?"** (실수 방지)
4. 확인 → 서버 요청 → 폐기 완료

**조건 불충족 시:**
- 버튼 비활성 + 툴팁: "Stale II 요리만 폐기할 수 있습니다"

**클라 판정 근거:** 클라는 서버가 전송하는 `Updates.Stale2Keys` (Stale II 보유 dishKey 스냅샷 배열)를 기반으로 [폐기] 버튼을 활성/비활성한다. 클라는 수신 시 Set으로 변환하여 O(1) 판정. **최종 판정은 서버(`staleCounts[dishKey][2] > 0`)가 수행**한다.

---

## 5. 비용/패널티

**결정: A) 무료 + 연타 방지 쿨다운 0.5s**

| 선택지 | 설명 | 채택 |
|--------|------|------|
| A | 무료 | ✅ |
| B | 골드 차감 | |
| C | 쿨다운 | |

**이유:** MVP에서 경제/밸런스 연동은 과잉. 무료로 시작하고 필요 시 확장.

**스팸 방지:** 서버 측 0.5s 쿨다운 (연타 방지)

---

## 6. 서버 권위/가드 (필수)

- **서버가 최종 판정.** 클라 요청은 검증 후 처리.
- 검증 체크:
  1. 요청 `dishKey` 수량 > 0
  2. `staleCounts[dishKey][2]` > 0 (Stale II 존재)
  3. 요청 빈도 제한: **uid 기준(전역) 0.5s 쿨다운** (dishKey 무관, 스팸 방지)

---

## 7. 데이터 변경

```lua
playerData.inventory[dishKey] -= 1
staleCounts[dishKey][2] -= 1  -- Stale II 버킷에서 차감
```

**불변식 유지:** `inventory[dishKey] == sum(staleCounts[dishKey])`

---

## 8. 동기화

폐기 후:
1. **OrderResponse로 Orders + Inventory + Stale2Keys를 클라에 전송** (필수)
2. Orphan UI 즉시 반영
3. Notice 표시: "[요리명]을 폐기했습니다"

**Stale2Keys 생성 규칙:**
- 서버에서 `staleCounts[dishKey][2] > 0`인 모든 dishKey를 배열로 구성
- 스냅샷 방식: 전송 시점마다 전체 목록 재구성 (증분 금지)

**주의:** Inventory를 보내는 모든 OrderResponse 경로에서 Stale2Keys도 같이 전송하여 상태 불일치 방지.

---

## 9. 로그 키

```
S-30|MANUAL_DISCARD uid=... dishKey=... level=2 remaining=...
S-30|DISCARD_DENIED uid=... dishKey=... reason=no_stale2|cooldown|qty_zero
```

---

## 10. 테스트 케이스

| TC ID | 시나리오 | PASS 기준 |
|-------|----------|-----------|
| TC-S30-01 | Stale II 1개 → 수동 폐기 | inventory/배지/orphan 갱신 + MANUAL_DISCARD 로그 |
| TC-S30-02 | Fresh 또는 Stale I 선택 → 폐기 시도 | 거부 + DISCARD_DENIED 로그 (또는 버튼 비활성) |
| TC-S30-03 | 연타 시도 (0.5s 이내) | 두 번째 요청 거부 + cooldown 로그 |

---

## 11. 종료 조건 (Exit Criteria)

- [ ] TC-S30-01 PASS
- [ ] TC-S30-02 PASS
- [ ] TC-S30-03 PASS
- [ ] CHANGELOG 기록 완료
- [ ] QA 스모크(5분)에서 회귀 없음

---

## 변경 이력

| 날짜 | 변경 | 작성자 |
|------|------|--------|
| 2026-02-01 | DRAFT 작성 | Claude |
| 2026-02-01 | 필수 보강 3건 반영 + APPROVED | Claude (ChatGPT 감리 승인) |
| 2026-02-01 | Stale2Keys 최소 동기화로 변경 (§2/§4/§8) | Claude (ChatGPT 감리 승인) |
