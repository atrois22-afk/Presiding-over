"""
스케줄 생성기 모듈
- 단일(SINGLE) + 세트(SET) target_date 생성
- KRX 거래일 캘린더 기반
- 휴장/연휴 처리
- calendar_path / calendar_issue 2-tier 추적 (v0.1.15)
- calendar_fallback 추적 (레거시 호환)
- invariant 검증 (v0.1.15: monotonicity, range, weekend)

GUIDE v0.1.15 기준 구현
"""

from datetime import datetime, timedelta
from typing import List, Dict, Optional, Tuple, Set
from pathlib import Path
import warnings
import json

# pykrx 임포트 (거래일 캘린더용)
try:
    from pykrx import stock
    PYKRX_AVAILABLE = True
except ImportError:
    PYKRX_AVAILABLE = False
    warnings.warn("pykrx not available. Using fallback calendar.")

# =============================================================================
# v0.1.15: calendar_path / calendar_issue enum 상수 (SSOT)
# scheduler.py가 유일 정의. logger.py는 이 값을 그대로 기록만 함.
# =============================================================================

CALENDAR_PATH_FUTURE_DATE_SKIP = 'FUTURE_DATE_SKIP'
CALENDAR_PATH_PYKRX_OK = 'PYKRX_OK'
CALENDAR_PATH_PYKRX_FALLBACK = 'PYKRX_FALLBACK'
CALENDAR_PATH_HOLIDAYS_ONLY = 'HOLIDAYS_ONLY'

CALENDAR_ISSUE_NONE = 'none'
CALENDAR_ISSUE_PYKRX_EMPTY = 'pykrx_empty'
CALENDAR_ISSUE_NETWORK_ERROR = 'network_error'
CALENDAR_ISSUE_UNKNOWN = 'unknown'
CALENDAR_ISSUE_PYKRX_UNAVAILABLE = 'pykrx_unavailable'

# calendar_issue 허용 값 whitelist (대소문자 엄격)
VALID_CALENDAR_ISSUES = {
    CALENDAR_ISSUE_NONE,
    CALENDAR_ISSUE_PYKRX_EMPTY,
    CALENDAR_ISSUE_NETWORK_ERROR,
    CALENDAR_ISSUE_UNKNOWN,
    CALENDAR_ISSUE_PYKRX_UNAVAILABLE,
}

# =============================================================================
# 공휴일 로드
# =============================================================================

HOLIDAYS: Set[str] = set()

# calendar_fallback 추적 (레거시 호환)
_LAST_USED_FALLBACK: bool = False
_LAST_FALLBACK_REASON: Optional[str] = None

# v0.1.15: calendar_path / calendar_issue 2-tier 추적
_LAST_CALENDAR_PATH: Optional[str] = None
_LAST_CALENDAR_ISSUE: str = CALENDAR_ISSUE_NONE

# v0.1.15: invariant 위반 기록 (런 단위)
_INVARIANT_VIOLATIONS: List[Dict] = []


def get_last_fallback_status() -> bool:
    """마지막 get_trading_days() 호출이 fallback을 사용했는지 반환 (레거시)"""
    return _LAST_USED_FALLBACK


def get_last_fallback_reason() -> Optional[str]:
    """마지막 fallback 원인 반환 (레거시)"""
    return _LAST_FALLBACK_REASON


def get_last_calendar_path() -> Optional[str]:
    """
    마지막 get_trading_days() 호출의 캘린더 경로 반환 (v0.1.15)

    Returns:
        'FUTURE_DATE_SKIP': 미래 날짜 → holidays.json 사용 (정상 경로)
        'PYKRX_OK': pykrx 정상 응답
        'PYKRX_FALLBACK': pykrx 호출 후 fallback
        'HOLIDAYS_ONLY': pykrx 미설치
        None: 아직 호출되지 않음
    """
    return _LAST_CALENDAR_PATH


def get_last_calendar_issue() -> str:
    """
    마지막 get_trading_days() 호출의 캘린더 이슈 반환 (v0.1.15)

    Returns:
        'none': 이슈 없음 (정상)
        'pykrx_empty': pykrx 빈 응답
        'network_error': 네트워크 예외
        'unknown': 기타 예외
        'pykrx_unavailable': pykrx 미설치
    """
    return _LAST_CALENDAR_ISSUE


def get_invariant_violations() -> List[Dict]:
    """현재 런의 invariant 위반 목록 반환 (v0.1.15)"""
    return _INVARIANT_VIOLATIONS.copy()


def reset_fallback_status():
    """
    fallback/calendar/invariant 상태 초기화 (새 예측 세션 시작 시)

    Note (v0.1.5 감리 정책):
        generate_schedule() 호출 전에 반드시 이 함수를 호출해야 함.
        현재 generate_schedule() 내부에서 자동 호출됨.
    """
    global _LAST_USED_FALLBACK, _LAST_FALLBACK_REASON
    global _LAST_CALENDAR_PATH, _LAST_CALENDAR_ISSUE
    global _INVARIANT_VIOLATIONS
    _LAST_USED_FALLBACK = False
    _LAST_FALLBACK_REASON = None
    _LAST_CALENDAR_PATH = None
    _LAST_CALENDAR_ISSUE = CALENDAR_ISSUE_NONE
    _INVARIANT_VIOLATIONS = []


def _check_and_record_invariant(trading_days: List[str], start_date: str, end_date: str):
    """
    거래일 목록 invariant 검증 (v0.1.15)

    위반 시: 신호 차단(DEGRADED) + 기록 + 계속 실행 (프로세스 중단 안 함)

    Checks:
        1. 단조 증가 (monotonicity)
        2. 범위 내 (start_date <= each <= end_date)
        3. 주말 미포함
    """
    global _INVARIANT_VIOLATIONS

    if not trading_days:
        return

    # 1. Monotonicity
    for i in range(1, len(trading_days)):
        if trading_days[i] <= trading_days[i - 1]:
            _INVARIANT_VIOLATIONS.append({
                'type': 'monotonicity',
                'detail': f'{trading_days[i - 1]} >= {trading_days[i]}',
                'range': f'{start_date}~{end_date}',
            })
            return

    # 2. Range check
    if trading_days[0] < start_date or trading_days[-1] > end_date:
        _INVARIANT_VIOLATIONS.append({
            'type': 'range',
            'detail': f'{trading_days[0]}~{trading_days[-1]} not in {start_date}~{end_date}',
            'range': f'{start_date}~{end_date}',
        })
        return

    # 3. No weekends
    for day in trading_days:
        dt = datetime.strptime(day, '%Y%m%d')
        if dt.weekday() >= 5:
            _INVARIANT_VIOLATIONS.append({
                'type': 'weekend',
                'detail': f'{day} is weekday={dt.weekday()}',
                'range': f'{start_date}~{end_date}',
            })
            return


def _load_holidays():
    """공휴일 목록 로드"""
    global HOLIDAYS
    config_path = Path(__file__).parent.parent / 'config' / 'holidays.json'

    if config_path.exists():
        try:
            with open(config_path, 'r', encoding='utf-8') as f:
                data = json.load(f)
                for year, dates in data.get('holidays', {}).items():
                    HOLIDAYS.update(dates)
        except Exception as e:
            warnings.warn(f"Failed to load holidays: {e}")

# 모듈 로드 시 공휴일 로드
_load_holidays()


def get_trading_days(start_date: str, end_date: str) -> List[str]:
    """
    KRX 거래일 목록 조회

    Args:
        start_date: 시작일 (YYYYMMDD)
        end_date: 종료일 (YYYYMMDD)

    Returns:
        거래일 목록 (YYYYMMDD 형식)

    Note:
        - fallback 사용 여부: get_last_fallback_status()
        - fallback 원인 (v0.1.5): get_last_fallback_reason()
    """
    global _LAST_USED_FALLBACK, _LAST_FALLBACK_REASON
    global _LAST_CALENDAR_PATH, _LAST_CALENDAR_ISSUE

    # 최근 날짜는 pykrx 데이터 지연 가능성이 있어 fallback 우선
    # pykrx는 2~3일 전 데이터까지만 신뢰
    today = datetime.now()
    safe_end = (today - timedelta(days=3)).strftime('%Y%m%d')

    if PYKRX_AVAILABLE and end_date <= safe_end:
        try:
            timestamps = stock.get_previous_business_days(fromdate=start_date, todate=end_date)
            if timestamps:
                # 분기 1: pykrx 정상 응답
                _LAST_USED_FALLBACK = False
                _LAST_FALLBACK_REASON = None
                _LAST_CALENDAR_PATH = CALENDAR_PATH_PYKRX_OK
                _LAST_CALENDAR_ISSUE = CALENDAR_ISSUE_NONE
                result = [ts.strftime('%Y%m%d') for ts in timestamps]
                _check_and_record_invariant(result, start_date, end_date)
                return result
            else:
                # 분기 2: pykrx 빈 응답
                _LAST_USED_FALLBACK = True
                _LAST_FALLBACK_REASON = 'pykrx_empty'
                _LAST_CALENDAR_PATH = CALENDAR_PATH_PYKRX_FALLBACK
                _LAST_CALENDAR_ISSUE = CALENDAR_ISSUE_PYKRX_EMPTY
        except (ConnectionError, TimeoutError, OSError) as e:
            # 분기 3: 네트워크 예외
            warnings.warn(f"pykrx network error: {e}")
            _LAST_USED_FALLBACK = True
            _LAST_FALLBACK_REASON = 'network_error'
            _LAST_CALENDAR_PATH = CALENDAR_PATH_PYKRX_FALLBACK
            _LAST_CALENDAR_ISSUE = CALENDAR_ISSUE_NETWORK_ERROR
        except Exception as e:
            # 분기 4: 기타 예외
            warnings.warn(f"pykrx error: {e}")
            _LAST_USED_FALLBACK = True
            _LAST_FALLBACK_REASON = 'unknown'
            _LAST_CALENDAR_PATH = CALENDAR_PATH_PYKRX_FALLBACK
            _LAST_CALENDAR_ISSUE = CALENDAR_ISSUE_UNKNOWN
    else:
        # pykrx 사용 불가 또는 최근/미래 날짜
        _LAST_USED_FALLBACK = True
        if not PYKRX_AVAILABLE:
            # 분기 5: pykrx 미설치
            _LAST_FALLBACK_REASON = 'pykrx_unavailable'
            _LAST_CALENDAR_PATH = CALENDAR_PATH_HOLIDAYS_ONLY
            _LAST_CALENDAR_ISSUE = CALENDAR_ISSUE_PYKRX_UNAVAILABLE
        else:
            # 분기 6: 미래/최근 날짜 → holidays.json 사용 (정상 경로)
            _LAST_FALLBACK_REASON = 'pykrx_empty'  # 레거시 호환
            _LAST_CALENDAR_PATH = CALENDAR_PATH_FUTURE_DATE_SKIP
            _LAST_CALENDAR_ISSUE = CALENDAR_ISSUE_NONE

    # Fallback: 주말 + 공휴일 제외
    result = []
    current = datetime.strptime(start_date, '%Y%m%d')
    end = datetime.strptime(end_date, '%Y%m%d')

    while current <= end:
        date_str = current.strftime('%Y%m%d')
        # 주말 제외 + 공휴일 제외
        if current.weekday() < 5 and date_str not in HOLIDAYS:
            result.append(date_str)
        current += timedelta(days=1)

    _check_and_record_invariant(result, start_date, end_date)
    return result


def is_trading_day(date_str: str) -> bool:
    """
    해당 날짜가 거래일인지 확인

    Args:
        date_str: 날짜 (YYYYMMDD)

    Returns:
        거래일 여부
    """
    # 전후 7일 범위에서 거래일 목록 조회
    dt = datetime.strptime(date_str, '%Y%m%d')
    start = (dt - timedelta(days=7)).strftime('%Y%m%d')
    end = (dt + timedelta(days=7)).strftime('%Y%m%d')

    trading_days = get_trading_days(start, end)
    return date_str in trading_days


def get_next_trading_day(date_str: str) -> str:
    """
    다음 거래일 조회

    Args:
        date_str: 기준 날짜 (YYYYMMDD)

    Returns:
        다음 거래일 (YYYYMMDD)
    """
    dt = datetime.strptime(date_str, '%Y%m%d')
    end = (dt + timedelta(days=14)).strftime('%Y%m%d')

    trading_days = get_trading_days(date_str, end)

    # 기준일 다음 거래일 찾기
    for day in trading_days:
        if day > date_str:
            return day

    raise ValueError(f"No trading day found after {date_str}")


def get_previous_trading_day(date_str: str) -> Optional[str]:
    """
    직전 거래일 조회 (v0.1.7)

    Args:
        date_str: 기준 날짜 (YYYYMMDD)

    Returns:
        직전 거래일 (YYYYMMDD), 없으면 None

    Note:
        backfill 대상일 계산에 사용.
        예: 월요일 기준 → 금요일 반환 (주말 스킵)
    """
    dt = datetime.strptime(date_str, '%Y%m%d')
    start = (dt - timedelta(days=14)).strftime('%Y%m%d')

    trading_days = get_trading_days(start, date_str)

    # 기준일 이전의 마지막 거래일 찾기
    for day in reversed(trading_days):
        if day < date_str:
            return day

    return None


def get_week_last_trading_day(date_str: str) -> str:
    """
    해당 주의 마지막 거래일 조회

    Args:
        date_str: 기준 날짜 (YYYYMMDD)

    Returns:
        해당 주 마지막 거래일 (YYYYMMDD)
    """
    dt = datetime.strptime(date_str, '%Y%m%d')

    # 해당 주 금요일 계산
    days_until_friday = 4 - dt.weekday()
    if days_until_friday < 0:
        days_until_friday += 7
    friday = dt + timedelta(days=days_until_friday)

    # 금요일부터 역순으로 거래일 찾기
    start = dt.strftime('%Y%m%d')
    end = friday.strftime('%Y%m%d')

    trading_days = get_trading_days(start, end)

    if not trading_days:
        raise ValueError(f"No trading day found in week of {date_str}")

    return trading_days[-1]


def get_next_week_trading_days(date_str: str) -> List[str]:
    """
    다음 주 거래일 목록 조회

    Args:
        date_str: 기준 날짜 (YYYYMMDD)

    Returns:
        다음 주 거래일 목록 (YYYYMMDD)
    """
    dt = datetime.strptime(date_str, '%Y%m%d')

    # 다음 주 월요일 계산
    days_until_monday = 7 - dt.weekday()
    next_monday = dt + timedelta(days=days_until_monday)
    next_friday = next_monday + timedelta(days=4)

    return get_trading_days(
        next_monday.strftime('%Y%m%d'),
        next_friday.strftime('%Y%m%d')
    )


def generate_single_target(run_date: str) -> str:
    """
    단일 예측 target_date 생성

    Args:
        run_date: 예측 생성일 (YYYYMMDD)

    Returns:
        단일 예측 대상일 (YYYYMMDD)
    """
    return get_next_trading_day(run_date)


def generate_set_targets(run_date: str) -> List[str]:
    """
    세트 예측 target_date 리스트 생성

    GUIDE v0.1.3 규칙:
    - 월: 수, 목, 금
    - 화: 목, 금
    - 수: 해당 주 마지막 거래일
    - 목: 다음주 월~금
    - 금: 다음주 화~금

    Args:
        run_date: 예측 생성일 (YYYYMMDD)

    Returns:
        세트 예측 대상일 리스트 (YYYYMMDD)
    """
    dt = datetime.strptime(run_date, '%Y%m%d')
    weekday = dt.weekday()  # 0=월, 1=화, ..., 4=금

    if weekday == 0:  # 월요일 -> 수, 목, 금
        # 이번 주 수~금 거래일
        wed = dt + timedelta(days=2)
        fri = dt + timedelta(days=4)
        targets = get_trading_days(wed.strftime('%Y%m%d'), fri.strftime('%Y%m%d'))

    elif weekday == 1:  # 화요일 -> 목, 금
        thu = dt + timedelta(days=2)
        fri = dt + timedelta(days=3)
        targets = get_trading_days(thu.strftime('%Y%m%d'), fri.strftime('%Y%m%d'))

    elif weekday == 2:  # 수요일 -> 해당 주 마지막 거래일
        last_day = get_week_last_trading_day(run_date)
        targets = [last_day]

    elif weekday == 3:  # 목요일 -> 다음주 월~금
        targets = get_next_week_trading_days(run_date)

    elif weekday == 4:  # 금요일 -> 다음주 화~금
        next_week = get_next_week_trading_days(run_date)
        # 월요일 제외
        if len(next_week) > 1:
            targets = next_week[1:]
        else:
            targets = next_week

    else:
        # 주말은 생성 안 함
        targets = []

    return targets


def should_skip_set(run_date: str) -> Tuple[bool, str]:
    """
    세트 스킵 여부 판단

    GUIDE v0.1.3 규칙:
    세트 예측의 target_date가 단일 예측의 target_date와
    완전히 동일한 경우, 세트 예측은 생성하지 않는다.

    Args:
        run_date: 예측 생성일 (YYYYMMDD)

    Returns:
        (스킵 여부, 사유)
    """
    single_target = generate_single_target(run_date)
    set_targets = generate_set_targets(run_date)

    if len(set_targets) == 1 and set_targets[0] == single_target:
        return True, "세트 target이 단일 target과 동일"

    if len(set_targets) == 0:
        return True, "세트 target 없음 (주말)"

    return False, ""


def generate_schedule(run_date: str) -> Dict:
    """
    주어진 날짜의 전체 스케줄 생성

    Args:
        run_date: 예측 생성일 (YYYYMMDD)

    Returns:
        {
            'run_date': str,
            'run_time': str,
            'weekday': int,
            'weekday_name': str,
            'is_trading_day': bool,
            'calendar_fallback': bool,  # 레거시 호환
            'fallback_src': str | None,  # 레거시 호환
            'calendar_path': str | None,  # v0.1.15: FUTURE_DATE_SKIP|PYKRX_OK|PYKRX_FALLBACK|HOLIDAYS_ONLY
            'calendar_issue': str,  # v0.1.15: none|pykrx_empty|network_error|unknown|pykrx_unavailable
            'invariant_violations': list,  # v0.1.15: 위반 목록 (비어있으면 정상)
            'single': { 'target_date': str },
            'set': { 'skip': bool, 'skip_reason': str, 'targets': List[str], 'set_id': str }
        }
    """
    # fallback 상태 초기화 (새 스케줄 생성 시) - v0.1.5 감리 필수
    reset_fallback_status()

    dt = datetime.strptime(run_date, '%Y%m%d')
    weekday = dt.weekday()
    weekday_names = ['월', '화', '수', '목', '금', '토', '일']

    result = {
        'run_date': run_date,
        'run_time': '15:55',
        'weekday': weekday,
        'weekday_name': weekday_names[weekday],
        'is_trading_day': is_trading_day(run_date),
        'calendar_fallback': False,
        'fallback_src': None,
        'calendar_path': None,
        'calendar_issue': CALENDAR_ISSUE_NONE,
        'invariant_violations': [],
        'single': None,
        'set': None
    }

    # 거래일이 아니면 스케줄 없음
    if not result['is_trading_day']:
        result['calendar_fallback'] = get_last_fallback_status()
        result['fallback_src'] = get_last_fallback_reason()
        result['calendar_path'] = get_last_calendar_path()
        result['calendar_issue'] = get_last_calendar_issue()
        result['invariant_violations'] = get_invariant_violations()
        return result

    # 단일 예측
    single_target = generate_single_target(run_date)
    result['single'] = {
        'target_date': single_target
    }

    # 세트 예측
    skip, skip_reason = should_skip_set(run_date)
    set_targets = generate_set_targets(run_date)

    result['set'] = {
        'skip': skip,
        'skip_reason': skip_reason,
        'targets': set_targets if not skip else [],
        'set_id': f"SET_{run_date}" if not skip else None
    }

    # 최종 fallback/calendar 상태 기록
    result['calendar_fallback'] = get_last_fallback_status()
    result['fallback_src'] = get_last_fallback_reason()
    result['calendar_path'] = get_last_calendar_path()
    result['calendar_issue'] = get_last_calendar_issue()
    result['invariant_violations'] = get_invariant_violations()

    return result


def generate_week_schedule(start_date: str) -> List[Dict]:
    """
    1주일 스케줄 생성 (테스트/검증용)

    Args:
        start_date: 시작일 (YYYYMMDD, 월요일 권장)

    Returns:
        주간 스케줄 리스트
    """
    dt = datetime.strptime(start_date, '%Y%m%d')

    schedules = []
    for i in range(7):
        current = dt + timedelta(days=i)
        schedule = generate_schedule(current.strftime('%Y%m%d'))
        schedules.append(schedule)

    return schedules


def print_schedule(schedule: Dict) -> None:
    """스케줄 출력 (디버깅용)"""
    print(f"\n=== {schedule['run_date']} ({schedule['weekday_name']}) ===")
    print(f"거래일: {schedule['is_trading_day']}")

    if schedule['single']:
        print(f"단일 target: {schedule['single']['target_date']}")

    if schedule['set']:
        if schedule['set']['skip']:
            print(f"세트: 스킵 ({schedule['set']['skip_reason']})")
        else:
            print(f"세트 targets: {schedule['set']['targets']}")
            print(f"세트 ID: {schedule['set']['set_id']}")


# 테스트 코드
if __name__ == '__main__':
    # 현재 주 스케줄 테스트
    today = datetime.now().strftime('%Y%m%d')

    print("=== 캘린더/스케줄 생성기 테스트 ===")
    print(f"기준일: {today}")
    print(f"pykrx 사용 가능: {PYKRX_AVAILABLE}")

    # 오늘 스케줄
    schedule = generate_schedule(today)
    print_schedule(schedule)

    # 이번 주 스케줄 (월요일부터)
    dt = datetime.strptime(today, '%Y%m%d')
    monday = dt - timedelta(days=dt.weekday())

    print("\n\n=== 주간 스케줄 ===")
    week_schedules = generate_week_schedule(monday.strftime('%Y%m%d'))
    for s in week_schedules:
        print_schedule(s)
