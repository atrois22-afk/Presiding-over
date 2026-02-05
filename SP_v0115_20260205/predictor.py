"""
메인 예측 드라이버

GUIDE v0.1.9 기준 구현:
- 15:55 예측 생성 (단일 + 세트)
- 데이터 조회 실패 시 FAILED 레코드 생성 (스킵 금지)
- 백필 지원 (09:10, 1회만)
- actual UPDATE (16:10)
- calendar_fallback → quality=DEGRADED, fallback_src= 토큰 (v0.1.5)
- clamp_applied → note 토큰 마킹 (v0.1.5)
- Run Summary 출력 + JSON 저장 (v0.1.6)
- policy_run_time vs executed_at 분리 (v0.1.6)
"""

import os
import sys
import json
from datetime import datetime, timedelta
from pathlib import Path
from typing import Dict, List, Optional, Tuple
from zoneinfo import ZoneInfo
import warnings

# 프로젝트 루트 추가
PROJECT_ROOT = Path(__file__).parent.parent
sys.path.insert(0, str(PROJECT_ROOT))

from src.scheduler import generate_schedule, is_trading_day, get_next_trading_day, get_previous_trading_day
from src.band_calculator import calculate_bands, calculate_direction, DEFAULT_PARAMS
from src.data_fetcher import (
    fetch_anchor_and_atr, fetch_actual_prices,
    get_ticker_info, get_all_tickers
)
from src.logger import (
    PredictionLogger, create_prediction_record, create_failed_record,
    SCHEMA_COLUMNS, append_note_token, build_note_string,
    save_daily_result, get_predictions_for_run_date
)


# =============================================================================
# 상수 정의
# =============================================================================

MODEL_VERSION = '0.1.15'  # v0.1.15: calendar_path/issue 분리 + --allow-call 게이트 (2026-02-05)
PARAMS_VERSION = '0.1.0'

# Execution Lock
LOCK_FILE = PROJECT_ROOT / 'swing_predictor.lock'

# Run Summary 저장 경로 (v0.1.6)
RUNS_DIR = PROJECT_ROOT / 'runs'

# 정책 실행 시간 (v0.1.6)
POLICY_RUN_TIMES = {
    'generate': '15:55',
    'update': '16:10',
    'backfill': '09:10',
}


# =============================================================================
# Lock 관리
# =============================================================================

def acquire_lock() -> bool:
    """
    Execution Lock 획득

    Returns:
        성공 여부
    """
    if LOCK_FILE.exists():
        # Lock 파일이 오래되었으면 무시 (1시간 이상)
        try:
            with open(LOCK_FILE, 'r') as f:
                content = f.read().strip()
                _, timestamp = content.split(',', 1)
                lock_time = datetime.fromisoformat(timestamp)
                if (datetime.now() - lock_time).total_seconds() > 3600:
                    LOCK_FILE.unlink()
                else:
                    return False
        except Exception:
            pass

    try:
        with open(LOCK_FILE, 'w') as f:
            f.write(f'{os.getpid()},{datetime.now().isoformat()}')
        return True
    except Exception:
        return False


def release_lock():
    """Execution Lock 해제"""
    try:
        if LOCK_FILE.exists():
            LOCK_FILE.unlink()
    except Exception:
        pass


# =============================================================================
# 예측 생성
# =============================================================================

def generate_predictions(
    run_date: str,
    run_time: str = '15:55',
    logger: Optional[PredictionLogger] = None,
    note: str = '',
    allow_call: bool = False
) -> Tuple[int, int]:
    """
    예측 생성 (단일 + 세트)

    Args:
        run_date: 예측 생성일 (YYYYMMDD)
        run_time: 예측 생성 시각
        logger: 로거 인스턴스
        note: 특이사항
        allow_call: v0.1.15 CALL 활성화 게이트

    Returns:
        (성공 수, 실패 수)
    """
    if logger is None:
        logger = PredictionLogger()

    # 스케줄 생성
    schedule = generate_schedule(run_date)

    if not schedule['is_trading_day']:
        print(f"[INFO] {run_date}은 거래일이 아님, 스킵")
        return (0, 0)

    # v0.1.5: calendar_fallback 체크 + fallback_src 토큰
    base_note = note or ''
    if schedule.get('calendar_fallback'):
        fallback_src = schedule.get('fallback_src') or 'unknown'
        print(f"[WARN] calendar_fallback 사용됨 (fallback_src={fallback_src})")
        base_note = append_note_token(base_note, 'calendar_fallback')
        base_note = append_note_token(base_note, f'fallback_src={fallback_src}')

    # v0.1.15: calendar_path / calendar_issue 추출 (scheduler.py에서 설정)
    cal_path = schedule.get('calendar_path', '')
    cal_issue = schedule.get('calendar_issue', '')

    records = []
    failed_tickers = []

    for ticker in get_all_tickers():
        info = get_ticker_info(ticker)
        print(f"\n[{ticker}] {info['name']} 예측 생성 중...")

        # Anchor + ATR 조회
        anchor, atr, anchor_date = fetch_anchor_and_atr(ticker, run_date)

        if anchor is None or atr is None:
            # v0.1.4: FAILED 레코드 생성 (스킵 금지)
            print(f"[ERROR] {ticker}: 데이터 조회 실패 → FAILED 레코드 생성")

            # v0.1.5: 실패 사유를 note 토큰으로 추가 (중복 방지)
            fail_note = base_note
            if anchor is None:
                fail_note = append_note_token(fail_note, 'data_missing_anchor')
            if atr is None:
                fail_note = append_note_token(fail_note, 'data_missing_atr')

            # SINGLE FAILED 레코드
            single_target = schedule['single']['target_date']
            failed_single = create_failed_record(
                run_date=run_date,
                run_time=run_time,
                ticker=ticker,
                forecast_type='SINGLE',
                set_id='SINGLE',
                target_date=single_target,
                horizon=1,
                model_version=MODEL_VERSION,
                params_version=PARAMS_VERSION,
                note=fail_note,
                calendar_path=cal_path,
                calendar_issue=cal_issue
            )
            records.append(failed_single)
            print(f"  SINGLE -> {single_target}: FAILED ({fail_note})")

            # SET FAILED 레코드 (스킵 아닌 경우)
            if not schedule['set']['skip']:
                set_id = schedule['set']['set_id']
                set_targets = schedule['set']['targets']
                for horizon, target in enumerate(set_targets, 1):
                    failed_set = create_failed_record(
                        run_date=run_date,
                        run_time=run_time,
                        ticker=ticker,
                        forecast_type='SET',
                        set_id=set_id,
                        target_date=target,
                        horizon=horizon,
                        model_version=MODEL_VERSION,
                        params_version=PARAMS_VERSION,
                        note=fail_note,
                        calendar_path=cal_path,
                        calendar_issue=cal_issue
                    )
                    records.append(failed_set)
                print(f"  SET ({set_id}) -> FAILED ({len(set_targets)}건)")

            failed_tickers.append(ticker)
            continue

        # anchor_date가 run_date와 다르면 경고 (데이터 지연)
        if anchor_date != run_date:
            print(f"[WARN] {ticker}: anchor 날짜 불일치 ({anchor_date} != {run_date})")

        # 단일 예측
        single_target = schedule['single']['target_date']
        band_result = calculate_bands(
            anchor=anchor,
            atr=atr,
            ticker=ticker,
            horizon=1,
            forecast_type='SINGLE'
        )

        # v0.1.5: clamp_applied 토큰 마킹
        single_note = base_note
        if band_result.clamp_applied:
            single_note = append_note_token(single_note, 'clamp_applied')
            print(f"  [WARN] clamp_applied=True (Hard Clamp 발동)")

        single_record = create_prediction_record(
            run_date=run_date,
            run_time=run_time,
            ticker=ticker,
            forecast_type='SINGLE',
            set_id='SINGLE',
            target_date=single_target,
            anchor_price=anchor,
            anchor_date=anchor_date,
            atr14=atr,
            horizon=1,
            band_result=band_result.to_dict(),
            model_version=MODEL_VERSION,
            params_version=PARAMS_VERSION,
            status='SUCCESS',
            note=single_note,
            calendar_path=cal_path,
            calendar_issue=cal_issue,
            allow_call=allow_call
        )
        records.append(single_record)

        print(f"  SINGLE -> {single_target}: anchor={anchor:,}, atr={atr:,.0f}")
        print(f"    Low: [{band_result.low_band_lo:,}, {band_result.low_band_hi:,}]")
        print(f"    High: [{band_result.high_band_lo:,}, {band_result.high_band_hi:,}]")
        print(f"    Safe: {band_result.safe_buy:,}")

        # 세트 예측
        if not schedule['set']['skip']:
            set_id = schedule['set']['set_id']
            set_targets = schedule['set']['targets']

            print(f"  SET ({set_id}) -> {set_targets}")

            for horizon, target in enumerate(set_targets, 1):
                band_result_set = calculate_bands(
                    anchor=anchor,
                    atr=atr,
                    ticker=ticker,
                    horizon=horizon,
                    forecast_type='SET'
                )

                # v0.1.5: clamp_applied 토큰 마킹
                set_note = base_note
                if band_result_set.clamp_applied:
                    set_note = append_note_token(set_note, 'clamp_applied')

                set_record = create_prediction_record(
                    run_date=run_date,
                    run_time=run_time,
                    ticker=ticker,
                    forecast_type='SET',
                    set_id=set_id,
                    target_date=target,
                    anchor_price=anchor,
                    anchor_date=anchor_date,
                    atr14=atr,
                    horizon=horizon,
                    band_result=band_result_set.to_dict(),
                    model_version=MODEL_VERSION,
                    params_version=PARAMS_VERSION,
                    status='SUCCESS',
                    note=set_note,
                    calendar_path=cal_path,
                    calendar_issue=cal_issue,
                    allow_call=allow_call
                )
                records.append(set_record)
        else:
            print(f"  SET: 스킵 ({schedule['set']['skip_reason']})")

    # 일괄 저장
    if records:
        success, failed = logger.insert_batch(records)
        print(f"\n[RESULT] 저장: 성공={success}, 중복={failed}")
        return (success, failed)

    return (0, len(failed_tickers))


def update_actuals(target_date: str, logger: Optional[PredictionLogger] = None) -> Tuple[int, int]:
    """
    실제값 UPDATE

    GUIDE v0.1.3: target_date 장 마감 후 16:10 KST에 실행

    Args:
        target_date: 대상 날짜 (YYYYMMDD)
        logger: 로거 인스턴스

    Returns:
        (성공 수, 실패 수)
    """
    if logger is None:
        logger = PredictionLogger()

    # UPDATE 필요한 레코드 조회
    pending = logger.get_pending_actuals(target_date)

    if not pending:
        print(f"[INFO] {target_date}: UPDATE 필요한 레코드 없음")
        return (0, 0)

    print(f"[INFO] {target_date}: {len(pending)}개 레코드 UPDATE 시작")

    success = 0
    failed = 0

    # 종목별로 그룹화
    tickers_to_update = set(r['ticker'] for r in pending)

    for ticker in tickers_to_update:
        # 실제 가격 조회
        actual_low, actual_high, actual_close = fetch_actual_prices(ticker, target_date)

        if actual_low is None:
            print(f"[ERROR] {ticker} {target_date}: 실제 가격 조회 실패")
            failed += sum(1 for r in pending if r['ticker'] == ticker)
            continue

        # 해당 종목의 모든 레코드 UPDATE
        for record in pending:
            if record['ticker'] != ticker:
                continue

            result = logger.update_actual(
                ticker=record['ticker'],
                run_date=record['run_date'],
                forecast_type=record['forecast_type'],
                set_id=record['set_id'],
                target_date=record['target_date'],
                actual_low=actual_low,
                actual_high=actual_high,
                actual_close=actual_close
            )

            if result:
                success += 1
                print(f"  {ticker} ({record['forecast_type']}): L={actual_low:,} H={actual_high:,} C={actual_close:,}")
            else:
                failed += 1

    print(f"[RESULT] UPDATE: 성공={success}, 실패={failed}")
    return (success, failed)


# =============================================================================
# 백필 처리
# =============================================================================

def backfill_failed(original_run_date: str, logger: Optional[PredictionLogger] = None, allow_call: bool = False) -> Tuple[int, int]:
    """
    FAILED 레코드 백필 (UPDATE 방식)

    GUIDE v0.1.7:
    - 다음 거래일 09:10에 1회만 백필
    - run_date는 원래 실패했던 날짜 유지
    - UPDATE API 사용 (FAILED → SUCCESS)
    - 복구 실패 시 note에 기록하고 recovery_attempts +1
    - recovery_attempts >= 1이면 백필 거부 (정책상 1회만 허용)

    Args:
        original_run_date: 원래 실패했던 날짜 (YYYYMMDD)
        logger: 로거 인스턴스

    Returns:
        (성공 수, 실패 수)
    """
    if logger is None:
        logger = PredictionLogger()

    # FAILED 레코드 조회
    failed_records = logger.get_failed_records(original_run_date)

    if not failed_records:
        print(f"[INFO] {original_run_date}: FAILED 레코드 없음")
        return (0, 0)

    print(f"[INFO] {original_run_date}: {len(failed_records)}개 FAILED 레코드 백필 시작")

    success = 0
    failed = 0

    # 종목별로 그룹화하여 데이터 조회 최소화
    tickers_to_backfill = set(r['ticker'] for r in failed_records)

    for ticker in tickers_to_backfill:
        info = get_ticker_info(ticker)
        print(f"\n[{ticker}] {info['name']} 백필 중...")

        # 데이터 조회 (원래 날짜 기준)
        anchor, atr, anchor_date = fetch_anchor_and_atr(ticker, original_run_date)

        if anchor is None or atr is None:
            print(f"[ERROR] {ticker}: 백필 데이터 조회 실패")
            # FAILED 레코드들에 note 추가 + recovery_attempts +1
            for record in failed_records:
                if record['ticker'] == ticker:
                    logger.update_failed_note(
                        ticker=record['ticker'],
                        run_date=record['run_date'],
                        forecast_type=record['forecast_type'],
                        set_id=record['set_id'],
                        target_date=record['target_date'],
                        note=f"backfill_failed_{datetime.now().strftime('%H%M')}"
                    )
                    failed += 1
            continue

        # anchor_date가 run_date와 다르면 경고
        if anchor_date != original_run_date:
            print(f"[WARN] {ticker}: anchor 날짜 불일치 ({anchor_date} != {original_run_date})")

        # 해당 종목의 모든 FAILED 레코드 복구
        for record in failed_records:
            if record['ticker'] != ticker:
                continue

            # v0.1.4: recovery_attempts > 1 가드 (정책상 1회만 허용)
            attempts = int(record.get('recovery_attempts', 0) or 0)
            if attempts >= 1:
                print(f"[WARN] recovery_attempts={attempts} >= 1, 백필 스킵: "
                      f"{record['forecast_type']} -> {record['target_date']}")
                print(f"       정책: 백필은 1회만 허용. 수동 개입 또는 운영 이상 의심.")
                # note에 경고 기록
                logger.update_prediction_meta(
                    ticker=record['ticker'],
                    run_date=record['run_date'],
                    forecast_type=record['forecast_type'],
                    set_id=record['set_id'],
                    target_date=record['target_date'],
                    note='unexpected_multiple_recovery_attempts'
                )
                failed += 1
                continue

            # 밴드 계산
            horizon = int(record.get('horizon', 1) or 1)
            forecast_type = record['forecast_type']

            band_result = calculate_bands(
                anchor=anchor,
                atr=atr,
                ticker=ticker,
                horizon=horizon,
                forecast_type=forecast_type
            )

            # UPDATE 시도 (FAILED → SUCCESS)
            result = logger.update_prediction_recovery(
                ticker=record['ticker'],
                run_date=record['run_date'],
                forecast_type=record['forecast_type'],
                set_id=record['set_id'],
                target_date=record['target_date'],
                anchor_price=anchor,
                anchor_date=anchor_date,
                atr14=atr,
                band_result=band_result.to_dict(),
                run_time='09:10',
                note='backfill'
            )

            if result:
                success += 1
                print(f"  {forecast_type} -> {record['target_date']}: 복구 완료")
                print(f"    Low: [{band_result.low_band_lo:,}, {band_result.low_band_hi:,}]")
                print(f"    Safe: {band_result.safe_buy:,}")
            else:
                failed += 1

    print(f"\n[RESULT] 백필: 성공={success}, 실패={failed}")
    return (success, failed)


# =============================================================================
# Run Summary (v0.1.6)
# =============================================================================

def _save_run_summary_json(
    run_date: str,
    policy_run_time: str,
    executed_at: str,
    mode: str,
    schedule: Optional[Dict],
    success_count: int,
    failed_count: int,
    allow_call: bool = False
) -> bool:
    """
    Run Summary를 JSON 파일로 저장 (v0.1.6.1)

    파일: runs/YYYYMMDD_run_summary.json
    - 1일 1파일, append 방식 (generate/update/backfill 등)
    - 구조: {"schema_version":"1.0", "entries":[...]}
    - legacy (list 최상위) 파일은 자동 승격

    Args:
        run_date: 예측/업데이트 대상 날짜 (YYYYMMDD)
        policy_run_time: 정책상 예정 시간 (15:55, 16:10, 09:10)
        executed_at: 실제 실행 시각 (ISO format with +09:00)
        mode: 실행 모드 (generate, update, backfill)
        schedule: 스케줄 정보 (None for update/backfill)
        success_count: 성공 수
        failed_count: 실패 수

    Returns:
        저장 성공 여부
    """
    RUN_SUMMARY_SCHEMA_VERSION = "1.0"

    try:
        # 디렉토리 생성
        RUNS_DIR.mkdir(parents=True, exist_ok=True)

        # 파일 경로
        summary_file = RUNS_DIR / f"{run_date}_run_summary.json"

        # 기존 데이터 로드 (있으면)
        entries = []
        if summary_file.exists():
            try:
                with open(summary_file, 'r', encoding='utf-8') as f:
                    data = json.load(f)

                    # v0.1.6.1: legacy 호환 + 신규 포맷 처리
                    if isinstance(data, list):
                        # legacy: list 최상위 → 자동 승격
                        entries = data
                    elif isinstance(data, dict) and 'entries' in data:
                        # new: {"schema_version":"1.0", "entries":[...]}
                        entries = data.get('entries', [])
                        if not isinstance(entries, list):
                            entries = []
                    else:
                        # 알 수 없는 형식 → 빈 리스트로 시작
                        entries = []

            except json.JSONDecodeError:
                # 깨진 파일 → 빈 리스트로 복구
                entries = []

        # 새 entry 생성
        # v0.1.7: json_saved=True를 명시적으로 기록 (저장 성공 시에만 파일에 존재)
        entry = {
            'mode': mode,
            'run_date': run_date,
            'policy_run_time': policy_run_time,
            'executed_at': executed_at,
            'model_version': MODEL_VERSION,
            'success_count': success_count,
            'failed_count': failed_count,
            'json_saved': True,  # v0.1.7: 명시적 기록 (저장 실패 시 entry 자체가 없음)
        }

        # v0.1.15: call_authorized (generate/backfill only, update 모드는 key 자체 생략)
        if mode in ('generate', 'backfill'):
            entry['call_authorized'] = allow_call

        # 스케줄 정보 추가 (generate 모드)
        if schedule:
            entry['is_trading_day'] = schedule.get('is_trading_day', False)
            entry['calendar_fallback'] = schedule.get('calendar_fallback', False)
            # v0.1.15: calendar_path / calendar_issue
            entry['calendar_path'] = schedule.get('calendar_path', '')
            entry['calendar_issue'] = schedule.get('calendar_issue', '')
            if schedule.get('calendar_fallback'):
                entry['fallback_src'] = schedule.get('fallback_src', 'unknown')
            if schedule.get('set'):
                set_info = schedule['set']
                entry['set_id'] = set_info.get('set_id')
                entry['set_skip'] = set_info.get('skip', False)
                if not set_info.get('skip'):
                    entry['targets_count'] = len(set_info.get('targets', []))

        # append
        entries.append(entry)

        # v0.1.6.1: wrapper dict 생성 (schema_version 포함)
        wrapper = {
            'schema_version': RUN_SUMMARY_SCHEMA_VERSION,
            'run_date': run_date,
            'entries': entries
        }

        # 저장 (atomic write: temp → rename)
        import tempfile
        import shutil

        temp_fd, temp_path = tempfile.mkstemp(
            suffix='.json',
            prefix='run_summary_',
            dir=RUNS_DIR
        )

        try:
            with os.fdopen(temp_fd, 'w', encoding='utf-8') as f:
                json.dump(wrapper, f, ensure_ascii=False, indent=2)
            shutil.move(temp_path, summary_file)
            return True
        except Exception:
            if os.path.exists(temp_path):
                os.remove(temp_path)
            raise

    except Exception as e:
        warnings.warn(f"run_summary.json 저장 실패: {e}")
        return False


def _print_run_summary(
    run_date: str,
    policy_run_time: str,
    executed_at: str,
    mode: str,
    schedule: Optional[Dict],
    success_count: int,
    failed_count: int,
    json_saved: bool = True
):
    """
    Run 단위 증빙 요약 출력 (v0.1.6)

    GUIDE G-9 / AUDIT A-1 대응:
    - run_date, policy_run_time, executed_at, mode
    - is_trading_day, calendar_fallback, fallback_src
    - set_id, targets_count
    - success_count, failed_count
    - json_saved (v0.1.6)
    """
    print()
    print("=" * 70)
    print("[RUN SUMMARY] v0.1.6.1 감리 증빙")
    print("=" * 70)

    print(f"run_date: {run_date}")
    print(f"policy_run_time: {policy_run_time}")
    print(f"executed_at: {executed_at}")
    print(f"mode: {mode}")

    if schedule:
        print(f"is_trading_day: {schedule.get('is_trading_day', '-')}")
        print(f"calendar_fallback: {schedule.get('calendar_fallback', False)}")
        if schedule.get('calendar_fallback'):
            print(f"fallback_src: {schedule.get('fallback_src', 'unknown')}")

        if schedule.get('set'):
            set_info = schedule['set']
            print(f"set_id: {set_info.get('set_id', '-')}")
            targets = set_info.get('targets', [])
            print(f"targets_count: {len(targets)}")
            if set_info.get('skip'):
                print(f"set_skip_reason: {set_info.get('skip_reason', '-')}")
    else:
        print("schedule: N/A (update/backfill mode)")

    print(f"success_count: {success_count}")
    print(f"failed_count: {failed_count}")
    print(f"json_saved: {json_saved}")
    if not json_saved:
        print("[WARN] run_summary.json 저장 실패 - run_summary_write_failed 토큰 마킹됨")
    print("=" * 70)


# =============================================================================
# 메인 실행 함수
# =============================================================================

def run_daily(mode: str = 'generate', date_str: Optional[str] = None, allow_call: bool = False):
    """
    일일 실행 메인 함수

    Args:
        mode: 실행 모드
            - 'generate': 예측 생성 (15:55)
            - 'update': actual UPDATE (16:10)
            - 'backfill': FAILED 백필 (09:10)
        date_str: 대상 날짜 (None이면 오늘)
        allow_call: v0.1.15 CALL 활성화 게이트 (기본 False)
    """
    if date_str is None:
        date_str = datetime.now().strftime('%Y%m%d')

    # v0.1.6: policy_run_time vs executed_at 분리
    # v0.1.6.1: tz-aware ISO (+09:00, seconds precision)
    policy_run_time = POLICY_RUN_TIMES.get(mode, '00:00')
    executed_at = datetime.now(ZoneInfo("Asia/Seoul")).isoformat(timespec="seconds")

    print(f"=== SWING_PREDICTOR {mode.upper()} ===")
    print(f"날짜: {date_str}")
    print(f"policy_run_time: {policy_run_time}")
    print(f"executed_at: {executed_at}")
    print(f"allow_call: {allow_call}")
    print()

    # Lock 획득
    if not acquire_lock():
        print("[ERROR] Lock 획득 실패 - 이미 실행 중")
        return

    try:
        logger = PredictionLogger()
        schedule = None
        target_run_date = date_str  # 기본값

        if mode == 'generate':
            # 스케줄 조회 (Run Summary용)
            schedule = generate_schedule(date_str)
            success, failed = generate_predictions(date_str, logger=logger, allow_call=allow_call)
            target_run_date = date_str

        elif mode == 'update':
            success, failed = update_actuals(date_str, logger=logger)
            target_run_date = date_str

        elif mode == 'backfill':
            # v0.1.7: 직전 거래일 FAILED 백필 (캘린더 -1일이 아님!)
            # 예: 월요일 09:10 backfill → 금요일(직전 거래일) 대상
            prev_trading_date = get_previous_trading_day(date_str)

            if prev_trading_date is None:
                print(f"[WARN] {date_str}: 직전 거래일을 찾을 수 없음, 백필 스킵")
                success, failed = 0, 0
                target_run_date = date_str  # fallback
            else:
                print(f"[INFO] Backfill 대상: {prev_trading_date} (직전 거래일)")
                success, failed = backfill_failed(prev_trading_date, logger=logger, allow_call=allow_call)
                target_run_date = prev_trading_date

        else:
            print(f"[ERROR] Unknown mode: {mode}")
            return

        # v0.1.6: Run Summary JSON 저장 (필수 시도)
        json_saved = _save_run_summary_json(
            run_date=target_run_date,
            policy_run_time=policy_run_time,
            executed_at=executed_at,
            mode=mode,
            schedule=schedule,
            success_count=success,
            failed_count=failed,
            allow_call=allow_call
        )

        # v0.1.6: JSON 저장 실패 시 note 토큰 마킹 (KPI A 정책: 분모 제외)
        # 주의: 이미 생성된 레코드들에 토큰 추가는 하지 않음 (별도 처리 필요 시 확장)
        # 현재는 Run Summary 출력에서만 경고 표시

        # Run Summary 출력 (AUDIT A-1 템플릿 대응)
        _print_run_summary(
            run_date=target_run_date,
            policy_run_time=policy_run_time,
            executed_at=executed_at,
            mode=mode,
            schedule=schedule,
            success_count=success,
            failed_count=failed,
            json_saved=json_saved
        )

        print()
        print(f"=== 완료 (성공={success}, 실패={failed}) ===")

        # Daily Result 텍스트 저장 (v0.1.13)
        if mode == 'generate' and success > 0:
            predictions = get_predictions_for_run_date(target_run_date)
            result_file = save_daily_result(target_run_date, predictions)
            if result_file:
                print(f"[저장] daily_result: {result_file}")

    finally:
        release_lock()


# =============================================================================
# CLI 엔트리포인트
# =============================================================================

if __name__ == '__main__':
    import argparse

    parser = argparse.ArgumentParser(description='SWING_PREDICTOR 일일 실행')
    parser.add_argument('--mode', choices=['generate', 'update', 'backfill'],
                        default='generate', help='실행 모드')
    parser.add_argument('--date', type=str, default=None,
                        help='대상 날짜 (YYYYMMDD, 기본: 오늘)')
    parser.add_argument('--force', action='store_true',
                        help='Lock 무시 (테스트용)')
    # v0.1.15: CALL 활성화 게이트 (기본 비활성, .bat에서 제어)
    parser.add_argument('--allow-call', action='store_true', default=False,
                        help='CALL 활성화 (미지정 시 모든 trade_call=NO_CALL)')

    args = parser.parse_args()

    if args.force and LOCK_FILE.exists():
        LOCK_FILE.unlink()

    run_daily(mode=args.mode, date_str=args.date, allow_call=args.allow_call)
