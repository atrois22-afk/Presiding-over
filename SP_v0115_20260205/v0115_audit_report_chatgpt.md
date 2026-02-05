# SWING_PREDICTOR v0.1.15 감리 요청

> **요청일**: 2026-02-05 13:19 KST
> **요청자**: 시공사 (Claude)
> **대상**: v0.1.15 코드 변경 전체
> **ZIP**: `v0115_audit_20260205_1319.zip` (8개 파일, 76KB)

---

## 1. 변경 배경 (Root Cause)

### 7주간 CALL = 0 문제
- `calendar_fallback=true`가 100% 발생 (360 records)
- 원인: `safe_end = today - 3days`로 인해 generate 모드(미래 날짜 D+1~D+5)에서 pykrx가 절대 호출되지 않음
- "미래 날짜라 holidays.json 사용" (정상)과 "pykrx 실패" (열화)가 동일하게 `fallback_src='pykrx_empty'`로 기록
- **의미적 문제**: 정상 경로를 열화로 오분류 → quality=DEGRADED → trade_call=NO_CALL

---

## 2. v0.1.15 변경 요약

### 2.1 scheduler.py — calendar_path/calendar_issue 2-tier 분리

**6개 분기 매핑 (SSOT):**

| 분기 | 조건 | calendar_path | calendar_issue |
|------|------|---------------|----------------|
| 1 | pykrx 정상 응답 | PYKRX_OK | none |
| 2 | pykrx 빈 응답 | PYKRX_FALLBACK | pykrx_empty |
| 3 | 네트워크 예외 | PYKRX_FALLBACK | network_error |
| 4 | 기타 예외 | PYKRX_FALLBACK | unknown |
| 5 | pykrx 미설치 | HOLIDAYS_ONLY | pykrx_unavailable |
| 6 | 미래/최근 날짜 | FUTURE_DATE_SKIP | none |

- enum 상수: scheduler.py가 유일 정의 (SSOT), logger.py는 기록만
- `_check_and_record_invariant()`: 단조증가 + 주말미포함 검증 (위반 시 기록, 크래시 안 함)

### 2.2 logger.py — CSV 스키마 확장 + trade_call 정책

**신규 컬럼 3개 (36 → 39):**
- `calendar_path`: 어떤 경로로 거래일 결정 (위 6개 값)
- `calendar_issue`: 열화 상태 (none / pykrx_empty / network_error / unknown / pykrx_unavailable)
- `call_authorized`: --allow-call 플래그 반영 (true/false)

**`determine_trade_call()` 신규 함수 (v0.1.15 핵심):**
```python
def determine_trade_call(status, calendar_path, clamp_applied, valid_forecast, anchor_match, allow_call):
    if status != 'SUCCESS': return 'NO_CALL'
    if clamp_applied: return 'NO_CALL'
    if not valid_forecast: return 'NO_CALL'
    if not anchor_match: return 'NO_CALL'
    if calendar_path not in {'FUTURE_DATE_SKIP', 'PYKRX_OK'}: return 'NO_CALL'
    if not allow_call: return 'NO_CALL'
    return 'CALL'
```

- CALL 허용 calendar_path: `FUTURE_DATE_SKIP`, `PYKRX_OK` (2개만)
- 나머지 (PYKRX_FALLBACK, HOLIDAYS_ONLY): 무조건 NO_CALL
- `allow_call=False`면 모든 조건 충족해도 NO_CALL (안전장치)
- calendar_issue whitelist 검증: 유효하지 않은 값 → warnings + 'none' 강제

### 2.3 predictor.py — --allow-call CLI + call chain

**`--allow-call` 인수 추가:**
```
python predictor.py --mode generate --allow-call
```
- `action='store_true'`, `default=False`
- 미지정 시: 모든 trade_call = NO_CALL (기존 .bat 파일 안전)
- 지정 시: 조건 충족 레코드만 CALL

**Call chain threading:**
- `run_daily(allow_call)` → `generate_predictions(allow_call)` → `create_prediction_record(allow_call)`
- `run_daily(allow_call)` → `backfill_failed(allow_call)`
- `_save_run_summary_json(allow_call)` → runs JSON entries[]에 `call_authorized` 기록

**runs JSON entries[] 변경:**
- generate/backfill: `call_authorized` 키 포함
- update: `call_authorized` 키 생략 (의미 없음)
- generate: `calendar_path`, `calendar_issue` 스케줄 블록에 추가

**MODEL_VERSION: 0.1.14 → 0.1.15**

### 2.4 config/holidays.json — 국군의날 추가

- `20241001` 추가 (2024년부터 법정공휴일)
- notes에 `"20241001": "국군의날 (2024년부터 법정공휴일)"` 추가
- `last_updated`: 2025-12-22 → 2026-02-05

### 2.5 문서 승격

- `GUIDE_v0.1.14.md` → `GUIDE_v0.1.15.md` (헤더 Phase 2 반영)
- `AUDIT_REPORT_v0.1.14.md` → `AUDIT_REPORT_v0.1.15.md` (헤더 업데이트)
- `CLAUDE.md`: 버전/파일참조/change log 동기화

---

## 3. 테스트 결과

```
SWING_PREDICTOR v0.1.15 Test Suite
18 tests, 18 passed, 0 failed

TC1a: --allow-call default=False          PASS
TC1b: --allow-call flag=True              PASS
TC2a: CALL when all conditions met        PASS
TC2b: NO_CALL when allow_call=False       PASS
TC2c: NO_CALL for PYKRX_FALLBACK path    PASS
TC2d: NO_CALL for FAILED status           PASS
TC2e: NO_CALL when clamp_applied          PASS
TC2f: CALL for PYKRX_OK path             PASS
TC2g: NO_CALL for HOLIDAYS_ONLY path      PASS
TC3:  PYKRX_OK + none                    PASS (mock)
TC4:  PYKRX_FALLBACK + pykrx_empty       PASS (mock)
TC5:  PYKRX_FALLBACK + network_error     PASS (mock)
TC6:  PYKRX_FALLBACK + unknown           PASS (mock)
TC7:  HOLIDAYS_ONLY + pykrx_unavailable  PASS (mock)
TC8:  FUTURE_DATE_SKIP + none            PASS (mock)
Schema: 39 columns                        PASS
New columns present                       PASS
MODEL_VERSION: 0.1.15                     PASS
```

- TC3-TC8: `unittest.mock.patch.object`으로 pykrx 6개 분기 검증 (stdlib only, pandas 미사용)
- End-to-end dry run: `calendar_path=FUTURE_DATE_SKIP`, `calendar_issue=none` 확인

---

## 4. 배포 상태

| 항목 | 상태 |
|------|------|
| 코드 변경 | 완료 (scheduler.py, logger.py, predictor.py) |
| 스케줄러 | 3개 모두 재활성화 (Ready) |
| .bat 파일 | `--allow-call` **미추가** (안전 상태) |
| trade_call | 현재 모든 레코드 NO_CALL (의도된 상태) |
| CALL 활성화 | Administrator가 .bat에 `--allow-call` 추가 시 |

---

## 5. 감리 요청 사항

### 5.1 코드 리뷰 대상 (ZIP 내 파일)
1. `src/scheduler.py` — 6분기 calendar_path/issue 매핑, invariant 체크
2. `src/logger.py` — determine_trade_call(), 스키마 39컬럼, whitelist 검증
3. `src/predictor.py` — --allow-call CLI, call chain, runs JSON
4. `scripts/test_v0115.py` — 18개 테스트 케이스
5. `config/holidays.json` — 20241001 추가

### 5.2 확인 요청 질문

1. **determine_trade_call() 조건 순서**: status → clamp → valid_forecast → anchor_match → calendar_path → allow_call. 이 순서가 정책적으로 올바른가?

2. **CALL 허용 calendar_path 2개**: FUTURE_DATE_SKIP + PYKRX_OK만 허용. PYKRX_FALLBACK / HOLIDAYS_ONLY 차단이 적절한가?

3. **FAILED 레코드 calendar 컨텍스트**: FAILED 레코드에도 calendar_path/calendar_issue를 기록 (schedule 레벨 속성이므로). 적절한가?

4. **--allow-call 영구 설계**: 임시 플래그가 아닌 영구 운영 안전장치로 설계. 이전 합의대로 구현되었는가?

---

## 6. 변경 파일 목록

| 파일 | 변경 유형 | 핵심 변경 |
|------|-----------|-----------|
| src/scheduler.py | 수정 | calendar_path/issue enum, 6분기 매핑, invariant |
| src/logger.py | 수정 | +3 컬럼, determine_trade_call(), whitelist |
| src/predictor.py | 수정 | --allow-call, call chain, MODEL_VERSION 0.1.15 |
| config/holidays.json | 수정 | +20241001, last_updated |
| scripts/test_v0115.py | **신규** | 18 TC (unittest, stdlib only) |
| GUIDE_v0.1.15.md | 승격 | v0.1.14 → v0.1.15 헤더 |
| AUDIT_REPORT_v0.1.15.md | 승격 | v0.1.14 → v0.1.15 헤더 |
| CLAUDE.md | 수정 | 버전/참조/change log |

> **이전 버전 참고**: ChatGPT 크로스 리뷰 7라운드에서 합의한 설계 그대로 구현했습니다.
> 합의 사항: --allow-call 영구 안전장치, entries[]에 call_authorized, update 모드 key 생략, TC2 MUST-PASS = 메커니즘 검증, stdlib only 테스트.
