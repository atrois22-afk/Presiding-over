"""
CSV 로거 모듈

GUIDE v0.1.15 기준 구현:
- 39개 필드 스키마 (v0.1.15: calendar_path, calendar_issue, call_authorized 추가)
- PK: (ticker, run_date, forecast_type, set_id, target_date)
- actual UPDATE 지원 (16:10 KST)
- 업데이트 불변성 (예측값 수정 금지, 메타 갱신 허용)
- UPDATE API 2개: recovery(FAILED→SUCCESS), meta(메타만)
- trade_call: v0.1.15 calendar_path 기반 세분화 + allow_call CLI 게이트
  - CALL 허용: FUTURE_DATE_SKIP/PYKRX_OK + 레코드 조건 충족 + allow_call=True
  - CALL 차단: PYKRX_FALLBACK/HOLIDAYS_ONLY (allow_call 무관)
- shadow_call: calendar_fallback 제외, 레코드 조건만 판정 (v0.1.14 유지)
- quality: 사실 기반 게이트 (변경 없음, calendar_fallback 포함)
- FAILED 레코드: quality=N/A, trade_call=NO_CALL, shadow_call=SHADOW_NO_CALL
- v0.1.15: calendar_issue whitelist invariant (대소문자 엄격)

note 토큰 표준 사전 (v0.1.6):
- calendar_fallback: pykrx fallback 사용됨
- fallback_src={reason}: pykrx_unavailable|pykrx_empty|network_error|unknown
- clamp_applied: Hard Clamp 발동
- data_missing_anchor: anchor 데이터 조회 실패
- data_missing_atr: ATR 데이터 조회 실패
- backfill: 백필로 복구됨
- backfill_failed_{HHMM}: 백필 실패 (시간 기록)
- run_summary_write_failed: run_summary.json 저장 실패 (KPI 분모 제외)
"""

import os
import csv
import warnings
from datetime import datetime
from typing import Dict, List, Optional, Tuple
from pathlib import Path


# =============================================================================
# 상수 정의
# =============================================================================

# 프로젝트 경로
PROJECT_ROOT = Path(__file__).parent.parent
DATA_DIR = PROJECT_ROOT / 'data'

# 스키마 정의 (39개 필드) - v0.1.15
SCHEMA_COLUMNS = [
    # 메타 정보 (6개)
    'run_date',
    'run_time',
    'ticker',
    'forecast_type',
    'set_id',
    'target_date',

    # 입력값 (4개)
    'anchor_price',
    'anchor_date',
    'atr14',
    'horizon',

    # 예측값 (7개)
    'low_band_lo',
    'low_band_hi',
    'high_band_lo',
    'high_band_hi',
    'close_band_lo',
    'close_band_hi',
    'safe_buy',

    # 실제값 (4개) - 사후 UPDATE
    'actual_low',
    'actual_high',
    'actual_close',
    'actual_filled_at',

    # 메타/버전 (6개)
    'model_version',
    'params_version',
    'status',
    'valid_forecast',
    'data_asof',
    'note',

    # 세트 지표 (4개) - SET일 때만
    'set_coverage_low',
    'set_coverage_high',
    'set_coverage_close',
    'set_worst_dev',

    # 복구/품질/콜 추적 (5개) - v0.1.14
    'recovery_attempts',
    'last_updated_at',
    'quality',
    'trade_call',
    'shadow_call',

    # v0.1.15: 캘린더 경로/이슈/CALL 승인 (3개)
    'calendar_path',      # FUTURE_DATE_SKIP / PYKRX_OK / PYKRX_FALLBACK / HOLIDAYS_ONLY
    'calendar_issue',     # none / pykrx_empty / network_error / unknown / pykrx_unavailable
    'call_authorized',    # true / false (--allow-call CLI 플래그)
]

# v0.1.15: CALL 허용 calendar_path (scheduler.py SSOT와 일치해야 함)
_CALL_ALLOWED_CALENDAR_PATHS = {'FUTURE_DATE_SKIP', 'PYKRX_OK'}

# v0.1.15: calendar_issue whitelist (scheduler.py SSOT와 일치해야 함)
_VALID_CALENDAR_ISSUES = {'none', 'pykrx_empty', 'network_error', 'unknown', 'pykrx_unavailable'}

# 기본 경로
DEFAULT_LOG_DIR = Path(__file__).parent.parent / 'data'
DEFAULT_LOG_FILE = 'prediction_log.csv'


# =============================================================================
# Primary Key 함수
# =============================================================================

def make_pk(ticker: str, run_date: str, forecast_type: str, set_id: str, target_date: str) -> Tuple:
    """
    Primary Key 생성

    PK: (ticker, run_date, forecast_type, set_id, target_date)

    Args:
        ticker: 종목 코드
        run_date: 예측 생성일 (YYYYMMDD)
        forecast_type: SINGLE 또는 SET
        set_id: 세트 ID (SINGLE이면 "SINGLE")
        target_date: 예측 대상일 (YYYYMMDD)

    Returns:
        PK 튜플
    """
    return (ticker, run_date, forecast_type, set_id, target_date)


def pk_from_row(row: Dict) -> Tuple:
    """딕셔너리에서 PK 추출"""
    return make_pk(
        row['ticker'],
        row['run_date'],
        row['forecast_type'],
        row['set_id'],
        row['target_date']
    )


# =============================================================================
# CSV 로거 클래스
# =============================================================================

class PredictionLogger:
    """예측 로그 관리자"""

    def __init__(self, log_dir: Optional[Path] = None, log_file: Optional[str] = None):
        """
        Args:
            log_dir: 로그 디렉토리 경로
            log_file: 로그 파일명
        """
        self.log_dir = Path(log_dir) if log_dir else DEFAULT_LOG_DIR
        self.log_file = log_file or DEFAULT_LOG_FILE
        self.log_path = self.log_dir / self.log_file

        # 디렉토리 생성
        self.log_dir.mkdir(parents=True, exist_ok=True)

        # CSV 파일 초기화 (없으면 헤더만 생성)
        self._init_csv()

    def _init_csv(self):
        """CSV 파일 초기화 (헤더 생성)"""
        if not self.log_path.exists():
            with open(self.log_path, 'w', newline='', encoding='utf-8') as f:
                writer = csv.DictWriter(f, fieldnames=SCHEMA_COLUMNS)
                writer.writeheader()

    def _load_all(self) -> List[Dict]:
        """전체 로그 로드"""
        if not self.log_path.exists():
            return []

        with open(self.log_path, 'r', encoding='utf-8') as f:
            reader = csv.DictReader(f)
            return list(reader)

    def _save_all(self, rows: List[Dict]):
        """
        전체 로그 저장 (atomic write: temp → rename)

        부분 손상 방지를 위해 임시 파일에 먼저 쓰고 rename
        """
        import tempfile
        import shutil

        # 임시 파일에 먼저 쓰기
        temp_fd, temp_path = tempfile.mkstemp(
            suffix='.csv',
            prefix='prediction_log_',
            dir=self.log_dir
        )

        try:
            with os.fdopen(temp_fd, 'w', newline='', encoding='utf-8') as f:
                writer = csv.DictWriter(f, fieldnames=SCHEMA_COLUMNS)
                writer.writeheader()
                for row in rows:
                    # 스키마에 맞게 필드 정리
                    cleaned = {col: row.get(col, '') for col in SCHEMA_COLUMNS}
                    writer.writerow(cleaned)

            # 성공하면 원본 파일로 교체 (atomic rename)
            shutil.move(temp_path, self.log_path)

        except Exception as e:
            # 실패 시 임시 파일 삭제
            if os.path.exists(temp_path):
                os.remove(temp_path)
            raise e

    def insert(self, record: Dict) -> bool:
        """
        새 예측 레코드 삽입

        PK 중복 시 삽입 거부 (업데이트 불변성)

        Args:
            record: 예측 레코드 딕셔너리

        Returns:
            성공 여부
        """
        # PK 추출
        new_pk = pk_from_row(record)

        # 기존 로그 로드
        rows = self._load_all()

        # PK 중복 체크
        for existing in rows:
            if pk_from_row(existing) == new_pk:
                print(f"[WARN] PK 중복, 삽입 거부: {new_pk}")
                return False

        # 스키마에 맞게 필드 정리
        cleaned = {col: record.get(col, '') for col in SCHEMA_COLUMNS}

        # 추가
        rows.append(cleaned)
        self._save_all(rows)
        return True

    def insert_batch(self, records: List[Dict]) -> Tuple[int, int]:
        """
        여러 레코드 일괄 삽입

        Args:
            records: 예측 레코드 리스트

        Returns:
            (성공 수, 실패 수)
        """
        rows = self._load_all()
        existing_pks = {pk_from_row(r) for r in rows}

        success = 0
        failed = 0

        for record in records:
            new_pk = pk_from_row(record)
            if new_pk in existing_pks:
                print(f"[WARN] PK 중복, 스킵: {new_pk}")
                failed += 1
            else:
                cleaned = {col: record.get(col, '') for col in SCHEMA_COLUMNS}
                rows.append(cleaned)
                existing_pks.add(new_pk)
                success += 1

        self._save_all(rows)
        return (success, failed)

    def update_actual(
        self,
        ticker: str,
        run_date: str,
        forecast_type: str,
        set_id: str,
        target_date: str,
        actual_low: int,
        actual_high: int,
        actual_close: int
    ) -> bool:
        """
        실제값 UPDATE

        GUIDE v0.1.3: target_date 장 마감 후 16:10 KST에 1회만 UPDATE
        actual 값만 수정 가능, 예측값은 불변

        Args:
            ticker: 종목 코드
            run_date: 예측 생성일
            forecast_type: SINGLE 또는 SET
            set_id: 세트 ID
            target_date: 예측 대상일
            actual_low: 실제 저가
            actual_high: 실제 고가
            actual_close: 실제 종가

        Returns:
            성공 여부
        """
        pk = make_pk(ticker, run_date, forecast_type, set_id, target_date)
        rows = self._load_all()

        found = False
        for row in rows:
            if pk_from_row(row) == pk:
                # 이미 actual이 있으면 스킵 (1회만 UPDATE)
                if row.get('actual_filled_at'):
                    print(f"[WARN] 이미 actual UPDATE 완료: {pk}")
                    return False

                # actual 값 업데이트
                row['actual_low'] = str(actual_low)
                row['actual_high'] = str(actual_high)
                row['actual_close'] = str(actual_close)
                row['actual_filled_at'] = datetime.now().strftime('%Y-%m-%d %H:%M:%S')
                found = True
                break

        if not found:
            print(f"[ERROR] 레코드 없음: {pk}")
            return False

        self._save_all(rows)
        return True

    def update_set_metrics(
        self,
        ticker: str,
        run_date: str,
        set_id: str,
        set_coverage_low: float,
        set_coverage_high: float,
        set_coverage_close: float,
        set_worst_dev: float
    ) -> int:
        """
        세트 지표 UPDATE (세트 완료 후)

        Args:
            ticker: 종목 코드
            run_date: 예측 생성일
            set_id: 세트 ID
            set_coverage_low: 저가 밴드 포함률
            set_coverage_high: 고가 밴드 포함률
            set_coverage_close: 종가 밴드 포함률
            set_worst_dev: 최악 이탈 (ATR 배수)

        Returns:
            업데이트된 레코드 수
        """
        rows = self._load_all()
        updated = 0

        for row in rows:
            if (row['ticker'] == ticker and
                row['run_date'] == run_date and
                row['set_id'] == set_id and
                row['forecast_type'] == 'SET'):

                row['set_coverage_low'] = f'{set_coverage_low:.4f}'
                row['set_coverage_high'] = f'{set_coverage_high:.4f}'
                row['set_coverage_close'] = f'{set_coverage_close:.4f}'
                row['set_worst_dev'] = f'{set_worst_dev:.4f}'
                updated += 1

        if updated > 0:
            self._save_all(rows)

        return updated

    # =========================================================================
    # UPDATE API v0.1.2 - 복구/메타 갱신
    # =========================================================================

    def update_prediction_meta(
        self,
        ticker: str,
        run_date: str,
        forecast_type: str,
        set_id: str,
        target_date: str,
        note: Optional[str] = None,
        quality: Optional[str] = None
    ) -> bool:
        """
        메타 정보만 갱신 (예측값 수정 금지)

        SUCCESS/FAILED 모두에서 사용 가능
        note는 append 방식 (| 구분자)

        Args:
            ticker, run_date, forecast_type, set_id, target_date: PK
            note: 추가할 노트 (기존에 append)
            quality: OK 또는 DEGRADED

        Returns:
            성공 여부
        """
        pk = make_pk(ticker, run_date, forecast_type, set_id, target_date)
        rows = self._load_all()

        found = False
        for row in rows:
            if pk_from_row(row) == pk:
                # note: append 방식
                if note:
                    existing_note = row.get('note', '')
                    if existing_note:
                        row['note'] = f"{existing_note}|{note}"
                    else:
                        row['note'] = note

                # quality: 덮어쓰기
                if quality:
                    row['quality'] = quality

                # last_updated_at 자동 갱신
                row['last_updated_at'] = datetime.now().strftime('%Y-%m-%d %H:%M:%S')

                found = True
                break

        if not found:
            print(f"[ERROR] 레코드 없음: {pk}")
            return False

        self._save_all(rows)
        return True

    def update_prediction_recovery(
        self,
        ticker: str,
        run_date: str,
        forecast_type: str,
        set_id: str,
        target_date: str,
        anchor_price: int,
        anchor_date: str,
        atr14: float,
        band_result: Dict,
        run_time: str = '09:10',
        note: str = 'backfill'
    ) -> bool:
        """
        FAILED → SUCCESS 복구 (backfill용)

        전제조건: 기존 status == 'FAILED'
        예측값 전체 갱신 + status=SUCCESS + recovery_attempts +1

        Args:
            ticker, run_date, forecast_type, set_id, target_date: PK
            anchor_price: 새 기준가
            anchor_date: anchor 날짜
            atr14: 새 ATR
            band_result: BandResult.to_dict() 결과
            run_time: 복구 시각 (기본 09:10)
            note: 노트 (기본 'backfill')

        Returns:
            성공 여부
        """
        pk = make_pk(ticker, run_date, forecast_type, set_id, target_date)
        rows = self._load_all()

        found = False
        for row in rows:
            if pk_from_row(row) == pk:
                # 전제조건: FAILED만 허용
                if row.get('status') != 'FAILED':
                    print(f"[WARN] FAILED 아님, 복구 거부: {pk} (status={row.get('status')})")
                    return False

                # 예측값 갱신
                row['anchor_price'] = str(anchor_price)
                row['anchor_date'] = anchor_date
                row['atr14'] = f'{atr14:.2f}'
                row['low_band_lo'] = str(band_result['low_band_lo'])
                row['low_band_hi'] = str(band_result['low_band_hi'])
                row['high_band_lo'] = str(band_result['high_band_lo'])
                row['high_band_hi'] = str(band_result['high_band_hi'])
                row['close_band_lo'] = str(band_result['close_band_lo'])
                row['close_band_hi'] = str(band_result['close_band_hi'])
                row['safe_buy'] = str(band_result['safe_buy'])

                # 상태 전환
                row['status'] = 'SUCCESS'
                row['run_time'] = run_time
                row['valid_forecast'] = str(band_result.get('valid_forecast', True))

                # note: append 방식
                existing_note = row.get('note', '')
                if existing_note:
                    row['note'] = f"{existing_note}|{note}"
                else:
                    row['note'] = note

                # quality 재계산: determine_quality() 중앙 로직 사용
                valid_forecast = band_result.get('valid_forecast', True)
                clamp_applied = band_result.get('clamp_applied', False)
                is_fallback = 'calendar_fallback' in row['note']
                anchor_match = (anchor_date == run_date)

                quality = determine_quality(
                    calendar_fallback=is_fallback,
                    clamp_applied=clamp_applied,
                    valid_forecast=valid_forecast,
                    anchor_match=anchor_match
                )
                row['quality'] = quality

                # trade_call 재계산: status=SUCCESS (복구 완료), quality, valid_forecast 조합
                row['trade_call'] = 'CALL' if (
                    quality == 'OK' and valid_forecast
                ) else 'NO_CALL'

                # shadow_call 재계산 (v0.1.14): calendar_fallback 제외
                row['shadow_call'] = determine_shadow_call(
                    clamp_applied=clamp_applied,
                    valid_forecast=valid_forecast,
                    anchor_match=anchor_match
                )

                # recovery_attempts +1
                attempts = int(row.get('recovery_attempts', 0) or 0)
                row['recovery_attempts'] = str(attempts + 1)

                # last_updated_at
                row['last_updated_at'] = datetime.now().strftime('%Y-%m-%d %H:%M:%S')

                found = True
                break

        if not found:
            print(f"[ERROR] 레코드 없음: {pk}")
            return False

        self._save_all(rows)
        print(f"[INFO] 복구 완료: {pk}")
        return True

    def update_failed_note(
        self,
        ticker: str,
        run_date: str,
        forecast_type: str,
        set_id: str,
        target_date: str,
        note: str
    ) -> bool:
        """
        FAILED 레코드 note만 갱신 (backfill 실패 기록용)

        recovery_attempts +1도 함께 수행

        Args:
            ticker, run_date, forecast_type, set_id, target_date: PK
            note: 추가할 노트

        Returns:
            성공 여부
        """
        pk = make_pk(ticker, run_date, forecast_type, set_id, target_date)
        rows = self._load_all()

        found = False
        for row in rows:
            if pk_from_row(row) == pk:
                if row.get('status') != 'FAILED':
                    print(f"[WARN] FAILED 아님, 갱신 거부: {pk}")
                    return False

                # note: append 방식
                existing_note = row.get('note', '')
                if existing_note:
                    row['note'] = f"{existing_note}|{note}"
                else:
                    row['note'] = note

                # recovery_attempts +1
                attempts = int(row.get('recovery_attempts', 0) or 0)
                row['recovery_attempts'] = str(attempts + 1)

                # last_updated_at
                row['last_updated_at'] = datetime.now().strftime('%Y-%m-%d %H:%M:%S')

                found = True
                break

        if not found:
            print(f"[ERROR] 레코드 없음: {pk}")
            return False

        self._save_all(rows)
        return True

    def get_failed_records(self, run_date: str) -> List[Dict]:
        """FAILED 레코드 조회 (backfill 대상)"""
        rows = self._load_all()
        return [
            r for r in rows
            if r['run_date'] == run_date and r.get('status') == 'FAILED'
        ]

    def get_by_pk(
        self,
        ticker: str,
        run_date: str,
        forecast_type: str,
        set_id: str,
        target_date: str
    ) -> Optional[Dict]:
        """PK로 레코드 조회"""
        pk = make_pk(ticker, run_date, forecast_type, set_id, target_date)
        rows = self._load_all()

        for row in rows:
            if pk_from_row(row) == pk:
                return row

        return None

    def get_by_target_date(self, target_date: str) -> List[Dict]:
        """target_date로 레코드 조회 (actual UPDATE용)"""
        rows = self._load_all()
        return [r for r in rows if r['target_date'] == target_date]

    def get_pending_actuals(self, target_date: str) -> List[Dict]:
        """actual UPDATE가 필요한 레코드 조회"""
        rows = self._load_all()
        return [
            r for r in rows
            if r['target_date'] == target_date and not r.get('actual_filled_at')
        ]

    def get_recent_singles(self, ticker: str, count: int = 20) -> List[Dict]:
        """최근 단일 예측 조회 (보정 트리거 판단용)"""
        rows = self._load_all()
        singles = [
            r for r in rows
            if r['ticker'] == ticker and r['forecast_type'] == 'SINGLE'
        ]
        # run_date 기준 정렬 (최신순)
        singles.sort(key=lambda x: x['run_date'], reverse=True)
        return singles[:count]

# =============================================================================
# 헬퍼 함수
# =============================================================================

# -----------------------------------------------------------------------------
# note 토큰 관리 (v0.1.5)
# -----------------------------------------------------------------------------

def append_note_token(existing_note: str, new_token: str) -> str:
    """
    note에 토큰 추가 (중복 방지, key=value 충돌 방지)

    v0.1.5 규칙:
    - 토큰은 '|'로 구분
    - 동일 토큰이 이미 존재하면 재추가 금지 (set처럼)
    - key=value 형식의 토큰은 같은 key가 이미 있으면 추가 금지
      (덮어쓰기 금지, 대신 경고 토큰 추가 가능)

    Args:
        existing_note: 기존 note 문자열 (None 또는 빈 문자열 가능)
        new_token: 추가할 토큰

    Returns:
        업데이트된 note 문자열
    """
    if not new_token:
        return existing_note or ''

    existing = existing_note or ''
    tokens = [t.strip() for t in existing.split('|') if t.strip()]

    # key=value 형식 체크
    if '=' in new_token:
        new_key = new_token.split('=')[0]
        # 같은 key가 이미 있는지 확인
        for t in tokens:
            if t.startswith(f"{new_key}="):
                # 이미 같은 key 존재 → 추가하지 않음 (v0.1.5 정책: 덮어쓰기 금지)
                return existing
    else:
        # 단순 토큰: 중복 체크
        if new_token in tokens:
            return existing

    # 토큰 추가
    tokens.append(new_token)
    return '|'.join(tokens)


def build_note_string(*tokens: str) -> str:
    """
    여러 토큰으로 note 문자열 생성 (중복 방지 적용)

    Args:
        tokens: 추가할 토큰들

    Returns:
        note 문자열
    """
    result = ''
    for token in tokens:
        if token:
            result = append_note_token(result, token)
    return result


# -----------------------------------------------------------------------------
# quality 판정
# -----------------------------------------------------------------------------

def determine_quality(
    calendar_fallback: bool,
    clamp_applied: bool,
    valid_forecast: bool,
    anchor_match: bool
) -> str:
    """
    품질(quality) 판정 중앙 로직

    v0.1.4 정책:
    - OK: 모든 조건 만족 (KPI/보정 대상)
    - DEGRADED: 조건 불만족 (KPI 제외)
    - N/A: FAILED 상태 (이 함수에서는 반환하지 않음, 별도 처리)

    Args:
        calendar_fallback: pykrx fallback 사용 여부
        clamp_applied: 밴드 clamp 적용 여부
        valid_forecast: 유효 예측 여부
        anchor_match: anchor_date == run_date 여부

    Returns:
        'OK' or 'DEGRADED'
    """
    if calendar_fallback:
        return 'DEGRADED'
    if clamp_applied:
        return 'DEGRADED'
    if not valid_forecast:
        return 'DEGRADED'
    if not anchor_match:
        return 'DEGRADED'
    return 'OK'


def determine_trade_call(
    status: str,
    calendar_path: str,
    clamp_applied: bool,
    valid_forecast: bool,
    anchor_match: bool,
    allow_call: bool,
) -> str:
    """
    trade_call 판정 중앙 로직 (v0.1.15)

    calendar_path 기반 세분화 + 레코드 단위 조건 + CLI 게이트.
    근거: scheduler.py get_trading_days() 6개 분기 1:1 매핑

    CALL 허용 경로: FUTURE_DATE_SKIP, PYKRX_OK
    CALL 차단 경로: PYKRX_FALLBACK, HOLIDAYS_ONLY (allow_call 무관)

    레코드 단위 조건 (3개 고정, v0.1.15):
        1. clamp_applied == false
        2. valid_forecast == true
        3. anchor_match == true

    Args:
        status: SUCCESS / FAILED
        calendar_path: scheduler.py가 생성한 캘린더 경로
        clamp_applied: 밴드 clamp 적용 여부
        valid_forecast: 유효 예측 여부
        anchor_match: anchor_date == run_date 여부
        allow_call: --allow-call CLI 플래그

    Returns:
        'CALL' or 'NO_CALL'
    """
    if status != 'SUCCESS':
        return 'NO_CALL'
    # 레코드 단위 조건 (3개 고정)
    if clamp_applied:
        return 'NO_CALL'
    if not valid_forecast:
        return 'NO_CALL'
    if not anchor_match:
        return 'NO_CALL'
    # calendar_path 조건
    if calendar_path not in _CALL_ALLOWED_CALENDAR_PATHS:
        return 'NO_CALL'
    # CLI 게이트
    if not allow_call:
        return 'NO_CALL'
    return 'CALL'


def determine_shadow_call(
    clamp_applied: bool,
    valid_forecast: bool,
    anchor_match: bool
) -> str:
    """
    Shadow Call 판정 중앙 로직 (v0.1.14)

    Phase 2 정책 (동일 조건 원칙):
    - calendar_fallback은 조건에서 제외 (핵심 차이점)
    - clamp_applied, valid_forecast, anchor_match만 판정

    Args:
        clamp_applied: 밴드 clamp 적용 여부
        valid_forecast: 유효 예측 여부
        anchor_match: anchor_date == run_date 여부

    Returns:
        'SHADOW_CALL' or 'SHADOW_NO_CALL'
    """
    if clamp_applied:
        return 'SHADOW_NO_CALL'
    if not valid_forecast:
        return 'SHADOW_NO_CALL'
    if not anchor_match:
        return 'SHADOW_NO_CALL'
    return 'SHADOW_CALL'


def create_failed_record(
    run_date: str,
    run_time: str,
    ticker: str,
    forecast_type: str,
    set_id: str,
    target_date: str,
    horizon: int,
    model_version: str,
    params_version: str,
    note: str = 'data_missing'
) -> Dict:
    """
    FAILED 레코드 생성 헬퍼

    v0.1.4 정책:
    - status=FAILED, quality=N/A, trade_call=NO_CALL
    - 밴드/가격 필드는 빈값("")
    - backfill 대상 조회 가능하도록 PK 필드는 모두 채움

    Args:
        run_date: 예측 생성일 (YYYYMMDD)
        run_time: 예측 생성 시각 (HH:MM)
        ticker: 종목 코드
        forecast_type: SINGLE 또는 SET
        set_id: 세트 ID
        target_date: 예측 대상일 (YYYYMMDD)
        horizon: 세트 인덱스
        model_version: 모델 버전
        params_version: 파라미터 버전
        note: 실패 사유 (data_missing_anchor, data_missing_atr 등)

    Returns:
        FAILED 레코드 딕셔너리
    """
    return {
        'run_date': run_date,
        'run_time': run_time,
        'ticker': ticker,
        'forecast_type': forecast_type,
        'set_id': set_id,
        'target_date': target_date,
        # 입력값 - 빈값 (조회 실패)
        'anchor_price': '',
        'anchor_date': '',
        'atr14': '',
        'horizon': str(horizon),
        # 예측값 - 빈값 (계산 불가)
        'low_band_lo': '',
        'low_band_hi': '',
        'high_band_lo': '',
        'high_band_hi': '',
        'close_band_lo': '',
        'close_band_hi': '',
        'safe_buy': '',
        # 실제값 - 빈값
        'actual_low': '',
        'actual_high': '',
        'actual_close': '',
        'actual_filled_at': '',
        # 메타/버전
        'model_version': model_version,
        'params_version': params_version,
        'status': 'FAILED',
        'valid_forecast': 'False',
        'data_asof': datetime.now().strftime('%Y-%m-%d %H:%M:%S'),
        'note': note,
        # 세트 지표 - 빈값
        'set_coverage_low': '',
        'set_coverage_high': '',
        'set_coverage_close': '',
        'set_worst_dev': '',
        # 복구/품질/콜 - FAILED 전용 값
        'recovery_attempts': '0',
        'last_updated_at': '',
        'quality': 'N/A',
        'trade_call': 'NO_CALL',
        'shadow_call': 'SHADOW_NO_CALL',
        # v0.1.15: FAILED 레코드 기본값
        'calendar_path': '',
        'calendar_issue': '',
        'call_authorized': 'false',
    }


def create_prediction_record(
    run_date: str,
    run_time: str,
    ticker: str,
    forecast_type: str,
    set_id: str,
    target_date: str,
    anchor_price: int,
    anchor_date: str,
    atr14: float,
    horizon: int,
    band_result: Dict,
    model_version: str,
    params_version: str,
    status: str = 'SUCCESS',
    data_asof: Optional[str] = None,
    note: str = '',
    calendar_path: str = '',
    calendar_issue: str = '',
    allow_call: bool = False,
) -> Dict:
    """
    예측 레코드 생성 헬퍼

    Args:
        run_date: 예측 생성일 (YYYYMMDD)
        run_time: 예측 생성 시각 (HH:MM)
        ticker: 종목 코드
        forecast_type: SINGLE 또는 SET
        set_id: 세트 ID
        target_date: 예측 대상일 (YYYYMMDD)
        anchor_price: 기준가
        anchor_date: anchor가 어느 날짜 종가인지 (YYYYMMDD)
        atr14: 14일 ATR
        horizon: 세트 인덱스
        band_result: BandResult.to_dict() 결과
        model_version: 모델 버전
        params_version: 파라미터 버전
        status: SUCCESS 또는 FAILED
        data_asof: 데이터 기준 시각
        note: 특이사항
        calendar_path: 캘린더 경로 (v0.1.15, scheduler.py SSOT)
        calendar_issue: 캘린더 이슈 (v0.1.15, scheduler.py SSOT)
        allow_call: --allow-call CLI 플래그 (v0.1.15)

    Returns:
        레코드 딕셔너리
    """
    # v0.1.15: calendar_issue whitelist invariant
    if calendar_issue and calendar_issue not in _VALID_CALENDAR_ISSUES:
        warnings.warn(f"invalid calendar_issue: '{calendar_issue}', forcing to 'none'")
        calendar_issue = 'none'

    # quality 판정: determine_quality() 중앙 로직 사용 (변경 없음)
    valid_forecast = band_result.get('valid_forecast', True)
    clamp_applied = band_result.get('clamp_applied', False)
    is_fallback = 'calendar_fallback' in note
    anchor_match = (anchor_date == run_date)

    quality = determine_quality(
        calendar_fallback=is_fallback,
        clamp_applied=clamp_applied,
        valid_forecast=valid_forecast,
        anchor_match=anchor_match
    )

    # trade_call 판정 (v0.1.15): calendar_path 기반 세분화 + allow_call 게이트
    trade_call = determine_trade_call(
        status=status,
        calendar_path=calendar_path,
        clamp_applied=clamp_applied,
        valid_forecast=valid_forecast,
        anchor_match=anchor_match,
        allow_call=allow_call,
    )

    # shadow_call 판정 (v0.1.14 유지): calendar_fallback 제외, 레코드 조건만
    shadow_call = determine_shadow_call(
        clamp_applied=clamp_applied,
        valid_forecast=valid_forecast,
        anchor_match=anchor_match
    ) if status == 'SUCCESS' else 'SHADOW_NO_CALL'

    return {
        'run_date': run_date,
        'run_time': run_time,
        'ticker': ticker,
        'forecast_type': forecast_type,
        'set_id': set_id,
        'target_date': target_date,
        'anchor_price': str(anchor_price),
        'anchor_date': anchor_date,
        'atr14': f'{atr14:.2f}',
        'horizon': str(horizon),
        'low_band_lo': str(band_result['low_band_lo']),
        'low_band_hi': str(band_result['low_band_hi']),
        'high_band_lo': str(band_result['high_band_lo']),
        'high_band_hi': str(band_result['high_band_hi']),
        'close_band_lo': str(band_result['close_band_lo']),
        'close_band_hi': str(band_result['close_band_hi']),
        'safe_buy': str(band_result['safe_buy']),
        'actual_low': '',
        'actual_high': '',
        'actual_close': '',
        'actual_filled_at': '',
        'model_version': model_version,
        'params_version': params_version,
        'status': status,
        'valid_forecast': str(valid_forecast),
        'data_asof': data_asof or datetime.now().strftime('%Y-%m-%d %H:%M:%S'),
        'note': note,
        'set_coverage_low': '',
        'set_coverage_high': '',
        'set_coverage_close': '',
        'set_worst_dev': '',
        'recovery_attempts': '0',
        'last_updated_at': '',
        'quality': quality,
        'trade_call': trade_call,
        'shadow_call': shadow_call,
        # v0.1.15: 캘린더 경로/이슈/CALL 승인
        'calendar_path': calendar_path,
        'calendar_issue': calendar_issue,
        'call_authorized': str(allow_call).lower(),
    }


# =============================================================================
# Daily Result 텍스트 저장 (v0.1.13)
# =============================================================================

# 종목명 매핑
TICKER_NAMES = {
    '005930': '삼성전자',
    '000660': 'SK하이닉스',
    '064350': '현대로템',
}

def save_daily_result(run_date: str, predictions: List[Dict]) -> Optional[str]:
    """
    당일 예측 결과를 사람이 읽기 쉬운 텍스트 파일로 저장

    Args:
        run_date: 실행 날짜 (YYYYMMDD)
        predictions: 예측 레코드 리스트

    Returns:
        저장된 파일 경로 (실패 시 None)
    """
    if not predictions:
        return None

    # 디렉토리 생성
    daily_dir = DATA_DIR / 'daily_results'
    daily_dir.mkdir(parents=True, exist_ok=True)

    # 파일 경로
    formatted_date = f"{run_date[:4]}-{run_date[4:6]}-{run_date[6:]}"
    file_path = daily_dir / f"{formatted_date}.txt"

    # 내용 생성
    lines = []
    lines.append(f"{'='*60}")
    lines.append(f"SWING_PREDICTOR 예측 결과")
    lines.append(f"생성일: {formatted_date}")
    lines.append(f"{'='*60}")
    lines.append("")

    # SINGLE 먼저, SET 나중에
    singles = [p for p in predictions if p.get('forecast_type') == 'SINGLE']
    sets = [p for p in predictions if p.get('forecast_type') == 'SET']

    # SINGLE 예측
    if singles:
        lines.append("[ SINGLE 예측 - 익일 ]")
        lines.append("-" * 50)
        for p in singles:
            ticker = p.get('ticker', '')
            name = TICKER_NAMES.get(ticker, ticker)
            target = p.get('target_date', '')
            target_fmt = f"{target[:4]}-{target[4:6]}-{target[6:]}" if len(target) == 8 else target

            low_lo = p.get('low_band_lo', '')
            low_hi = p.get('low_band_hi', '')
            high_lo = p.get('high_band_lo', '')
            high_hi = p.get('high_band_hi', '')
            close_lo = p.get('close_band_lo', '')
            close_hi = p.get('close_band_hi', '')
            safe = p.get('safe_buy', '')

            lines.append(f"")
            lines.append(f"■ {name} ({ticker})")
            lines.append(f"  Target: {target_fmt}")
            lines.append(f"  저가 밴드: {int(low_lo):,} ~ {int(low_hi):,}")
            lines.append(f"  고가 밴드: {int(high_lo):,} ~ {int(high_hi):,}")
            lines.append(f"  종가 밴드: {int(close_lo):,} ~ {int(close_hi):,}")
            lines.append(f"  안전매수가: {int(safe):,}")
        lines.append("")

    # SET 예측
    if sets:
        lines.append("[ SET 예측 - 주간 ]")
        lines.append("-" * 50)

        # 티커별로 그룹화
        from collections import defaultdict
        by_ticker = defaultdict(list)
        for p in sets:
            by_ticker[p.get('ticker', '')].append(p)

        for ticker, preds in by_ticker.items():
            name = TICKER_NAMES.get(ticker, ticker)
            lines.append(f"")
            lines.append(f"■ {name} ({ticker})")

            for p in sorted(preds, key=lambda x: x.get('target_date', '')):
                target = p.get('target_date', '')
                target_fmt = f"{target[4:6]}/{target[6:]}" if len(target) == 8 else target
                horizon = p.get('horizon', '')

                low_lo = p.get('low_band_lo', '')
                low_hi = p.get('low_band_hi', '')
                high_lo = p.get('high_band_lo', '')
                high_hi = p.get('high_band_hi', '')
                close_lo = p.get('close_band_lo', '')
                close_hi = p.get('close_band_hi', '')
                safe = p.get('safe_buy', '')

                lines.append(f"  [{target_fmt}] h={horizon}")
                lines.append(f"    저가: {int(low_lo):,} ~ {int(low_hi):,}")
                lines.append(f"    고가: {int(high_lo):,} ~ {int(high_hi):,}")
                lines.append(f"    종가: {int(close_lo):,} ~ {int(close_hi):,}")
                lines.append(f"    안전매수: {int(safe):,}")
        lines.append("")

    lines.append("=" * 60)
    lines.append(f"총 {len(predictions)}건 (SINGLE {len(singles)} + SET {len(sets)})")
    lines.append("=" * 60)

    # 파일 저장
    try:
        with open(file_path, 'w', encoding='utf-8') as f:
            f.write('\n'.join(lines))
        return str(file_path)
    except Exception as e:
        print(f"[ERROR] daily_result 저장 실패: {e}")
        return None


def get_predictions_for_run_date(run_date: str) -> List[Dict]:
    """
    특정 run_date의 예측 레코드 조회

    Args:
        run_date: 실행 날짜 (YYYYMMDD)

    Returns:
        해당 run_date의 예측 레코드 리스트
    """
    csv_path = DATA_DIR / 'prediction_log.csv'
    if not csv_path.exists():
        return []

    with open(csv_path, 'r', encoding='utf-8') as f:
        reader = csv.DictReader(f)
        return [row for row in reader if row.get('run_date') == run_date]


# =============================================================================
# 테스트 코드
# =============================================================================

if __name__ == '__main__':
    import tempfile
    import shutil

    print("=== CSV 로거 테스트 ===")
    print()

    # 임시 디렉토리 생성
    test_dir = Path(tempfile.mkdtemp())
    print(f"테스트 디렉토리: {test_dir}")

    try:
        # 로거 생성
        logger = PredictionLogger(log_dir=test_dir)
        print(f"로그 파일: {logger.log_path}")
        print()

        # 테스트 밴드 결과
        band_result = {
            'low_band_lo': 53200,
            'low_band_hi': 54200,
            'high_band_lo': 55800,
            'high_band_hi': 56800,
            'close_band_lo': 54400,
            'close_band_hi': 55600,
            'safe_buy': 53800,
            'valid_forecast': True,
            'clamp_applied': False,
        }

        # 레코드 생성
        record1 = create_prediction_record(
            run_date='20251219',
            run_time='15:55',
            ticker='005930',
            forecast_type='SINGLE',
            set_id='SINGLE',
            target_date='20251222',
            anchor_price=55000,
            atr14=1500.0,
            horizon=1,
            band_result=band_result,
            model_version='0.1.0',
            params_version='0.1.0',
        )

        # 삽입 테스트
        print("=== 삽입 테스트 ===")
        result = logger.insert(record1)
        print(f"삽입 결과: {result}")

        # 중복 삽입 테스트
        result2 = logger.insert(record1)
        print(f"중복 삽입 결과: {result2} (False 예상)")
        print()

        # 세트 레코드 삽입
        set_targets = ['20251223', '20251224', '20251225']
        set_records = []
        for i, target in enumerate(set_targets, 1):
            rec = create_prediction_record(
                run_date='20251219',
                run_time='15:55',
                ticker='005930',
                forecast_type='SET',
                set_id='SET_20251219',
                target_date=target,
                anchor_price=55000,
                atr14=1500.0,
                horizon=i,
                band_result=band_result,
                model_version='0.1.0',
                params_version='0.1.0',
            )
            set_records.append(rec)

        success, failed = logger.insert_batch(set_records)
        print(f"배치 삽입: 성공={success}, 실패={failed}")
        print()

        # 조회 테스트
        print("=== 조회 테스트 ===")
        found = logger.get_by_pk('005930', '20251219', 'SINGLE', 'SINGLE', '20251222')
        print(f"PK 조회: {found['ticker']} / {found['target_date']}")

        pending = logger.get_pending_actuals('20251222')
        print(f"Pending actuals (20251222): {len(pending)}개")
        print()

        # actual UPDATE 테스트
        print("=== actual UPDATE 테스트 ===")
        update_result = logger.update_actual(
            ticker='005930',
            run_date='20251219',
            forecast_type='SINGLE',
            set_id='SINGLE',
            target_date='20251222',
            actual_low=54000,
            actual_high=56500,
            actual_close=55800
        )
        print(f"UPDATE 결과: {update_result}")

        # 재 UPDATE 시도 (실패해야 함)
        update_result2 = logger.update_actual(
            ticker='005930',
            run_date='20251219',
            forecast_type='SINGLE',
            set_id='SINGLE',
            target_date='20251222',
            actual_low=54000,
            actual_high=56500,
            actual_close=55800
        )
        print(f"재 UPDATE 결과: {update_result2} (False 예상)")
        print()

        # 최종 파일 내용 출력
        print("=== 최종 CSV 내용 (일부) ===")
        with open(logger.log_path, 'r', encoding='utf-8') as f:
            lines = f.readlines()
            for line in lines[:3]:
                print(line.strip()[:100] + '...')

    finally:
        # 정리
        shutil.rmtree(test_dir)
        print()
        print(f"테스트 디렉토리 삭제: {test_dir}")
