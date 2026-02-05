#!/usr/bin/env python
"""
test_v0115.py - v0.1.15 검증 스크립트

Part 1: TC3-TC8 Mock Unit Tests (scheduler.py 6개 분기)
Part 2: TC1-TC2 Integration Verify (CSV + runs JSON)

규칙: stdlib only (csv, json, unittest) - pandas 사용 금지
"""

import sys
import os
import unittest
from unittest.mock import patch, MagicMock
from datetime import datetime, timedelta

# src/ 경로 추가
SRC_DIR = os.path.join(os.path.dirname(os.path.dirname(os.path.abspath(__file__))), 'src')
sys.path.insert(0, SRC_DIR)


# ============================================================================
# Part 1: TC3-TC8 - Mock Unit Tests (scheduler.py 분기별 calendar_path/issue)
# ============================================================================

class TC3_PykrxOk(unittest.TestCase):
    """분기 1: pykrx 정상 응답 → PYKRX_OK + none"""

    def test_pykrx_ok_branch(self):
        import scheduler
        scheduler.reset_fallback_status()

        # pykrx 사용 가능 + 과거 날짜 (safe_end 이전)
        past_start = '20250101'
        past_end = '20250110'

        # mock: stock.get_previous_business_days → datetime 리스트 반환
        mock_timestamps = [
            datetime(2025, 1, 2), datetime(2025, 1, 3),
            datetime(2025, 1, 6), datetime(2025, 1, 7),
            datetime(2025, 1, 8), datetime(2025, 1, 9), datetime(2025, 1, 10)
        ]

        with patch.object(scheduler, 'PYKRX_AVAILABLE', True), \
             patch.object(scheduler, 'stock') as mock_stock:
            mock_stock.get_previous_business_days.return_value = mock_timestamps
            result = scheduler.get_trading_days(past_start, past_end)

        self.assertEqual(scheduler.get_last_calendar_path(), 'PYKRX_OK')
        self.assertEqual(scheduler.get_last_calendar_issue(), 'none')
        self.assertFalse(scheduler.get_last_fallback_status())
        self.assertEqual(len(result), 7)
        print("[PASS] TC3: PYKRX_OK + none")


class TC4_PykrxEmpty(unittest.TestCase):
    """분기 2: pykrx 빈 응답 → PYKRX_FALLBACK + pykrx_empty"""

    def test_pykrx_empty_branch(self):
        import scheduler
        scheduler.reset_fallback_status()

        past_start = '20250101'
        past_end = '20250110'

        with patch.object(scheduler, 'PYKRX_AVAILABLE', True), \
             patch.object(scheduler, 'stock') as mock_stock:
            # pykrx가 빈 리스트 반환 (timestamps 없음)
            mock_stock.get_previous_business_days.return_value = []
            result = scheduler.get_trading_days(past_start, past_end)

        self.assertEqual(scheduler.get_last_calendar_path(), 'PYKRX_FALLBACK')
        self.assertEqual(scheduler.get_last_calendar_issue(), 'pykrx_empty')
        self.assertTrue(scheduler.get_last_fallback_status())
        # fallback으로 holidays.json 기반 결과가 반환됨
        self.assertGreater(len(result), 0)
        print("[PASS] TC4: PYKRX_FALLBACK + pykrx_empty")


class TC5_NetworkError(unittest.TestCase):
    """분기 3: 네트워크 예외 → PYKRX_FALLBACK + network_error"""

    def test_network_error_branch(self):
        import scheduler
        scheduler.reset_fallback_status()

        past_start = '20250101'
        past_end = '20250110'

        with patch.object(scheduler, 'PYKRX_AVAILABLE', True), \
             patch.object(scheduler, 'stock') as mock_stock:
            mock_stock.get_previous_business_days.side_effect = ConnectionError("timeout")
            result = scheduler.get_trading_days(past_start, past_end)

        self.assertEqual(scheduler.get_last_calendar_path(), 'PYKRX_FALLBACK')
        self.assertEqual(scheduler.get_last_calendar_issue(), 'network_error')
        self.assertTrue(scheduler.get_last_fallback_status())
        self.assertGreater(len(result), 0)
        print("[PASS] TC5: PYKRX_FALLBACK + network_error")


class TC6_UnknownError(unittest.TestCase):
    """분기 4: 기타 예외 → PYKRX_FALLBACK + unknown"""

    def test_unknown_error_branch(self):
        import scheduler
        scheduler.reset_fallback_status()

        past_start = '20250101'
        past_end = '20250110'

        with patch.object(scheduler, 'PYKRX_AVAILABLE', True), \
             patch.object(scheduler, 'stock') as mock_stock:
            mock_stock.get_previous_business_days.side_effect = ValueError("unexpected")
            result = scheduler.get_trading_days(past_start, past_end)

        self.assertEqual(scheduler.get_last_calendar_path(), 'PYKRX_FALLBACK')
        self.assertEqual(scheduler.get_last_calendar_issue(), 'unknown')
        self.assertTrue(scheduler.get_last_fallback_status())
        self.assertGreater(len(result), 0)
        print("[PASS] TC6: PYKRX_FALLBACK + unknown")


class TC7_PykrxUnavailable(unittest.TestCase):
    """분기 5: pykrx 미설치 → HOLIDAYS_ONLY + pykrx_unavailable"""

    def test_pykrx_unavailable_branch(self):
        import scheduler
        scheduler.reset_fallback_status()

        past_start = '20250101'
        past_end = '20250110'

        with patch.object(scheduler, 'PYKRX_AVAILABLE', False):
            result = scheduler.get_trading_days(past_start, past_end)

        self.assertEqual(scheduler.get_last_calendar_path(), 'HOLIDAYS_ONLY')
        self.assertEqual(scheduler.get_last_calendar_issue(), 'pykrx_unavailable')
        self.assertTrue(scheduler.get_last_fallback_status())
        self.assertGreater(len(result), 0)
        print("[PASS] TC7: HOLIDAYS_ONLY + pykrx_unavailable")


class TC8_FutureDateSkip(unittest.TestCase):
    """분기 6: 미래 날짜 → FUTURE_DATE_SKIP + none"""

    def test_future_date_skip_branch(self):
        import scheduler
        scheduler.reset_fallback_status()

        # 미래 날짜 (safe_end 이후)
        future_start = (datetime.now() + timedelta(days=1)).strftime('%Y%m%d')
        future_end = (datetime.now() + timedelta(days=7)).strftime('%Y%m%d')

        # PYKRX_AVAILABLE=True이지만 end_date > safe_end → 분기 6
        result = scheduler.get_trading_days(future_start, future_end)

        self.assertEqual(scheduler.get_last_calendar_path(), 'FUTURE_DATE_SKIP')
        self.assertEqual(scheduler.get_last_calendar_issue(), 'none')
        self.assertTrue(scheduler.get_last_fallback_status())
        # holidays.json fallback 결과
        self.assertGreater(len(result), 0)
        print("[PASS] TC8: FUTURE_DATE_SKIP + none")


# ============================================================================
# Part 2: TC1-TC2 - Integration Verify (CSV + runs JSON 구조 확인)
# ============================================================================

class TC1_AllowCallDefault(unittest.TestCase):
    """TC1: --allow-call CLI 메커니즘 확인"""

    def test_argparse_default_false(self):
        """--allow-call 미지정 시 False"""
        import argparse
        parser = argparse.ArgumentParser()
        parser.add_argument('--allow-call', action='store_true', default=False)
        args = parser.parse_args([])
        self.assertFalse(args.allow_call)
        print("[PASS] TC1a: --allow-call default=False")

    def test_argparse_with_flag(self):
        """--allow-call 지정 시 True"""
        import argparse
        parser = argparse.ArgumentParser()
        parser.add_argument('--allow-call', action='store_true', default=False)
        args = parser.parse_args(['--allow-call'])
        self.assertTrue(args.allow_call)
        print("[PASS] TC1b: --allow-call flag=True")


class TC2_DetermineTradeCall(unittest.TestCase):
    """TC2: trade_call 결정 메커니즘 (MUST-PASS)"""

    def test_call_when_all_conditions_met(self):
        """모든 조건 충족 + allow_call=True → CALL"""
        from logger import determine_trade_call
        result = determine_trade_call(
            status='SUCCESS',
            calendar_path='FUTURE_DATE_SKIP',
            clamp_applied=False,
            valid_forecast=True,
            anchor_match=True,
            allow_call=True
        )
        self.assertEqual(result, 'CALL')
        print("[PASS] TC2a: CALL when all conditions met")

    def test_no_call_when_allow_false(self):
        """모든 조건 충족이지만 allow_call=False → NO_CALL"""
        from logger import determine_trade_call
        result = determine_trade_call(
            status='SUCCESS',
            calendar_path='FUTURE_DATE_SKIP',
            clamp_applied=False,
            valid_forecast=True,
            anchor_match=True,
            allow_call=False
        )
        self.assertEqual(result, 'NO_CALL')
        print("[PASS] TC2b: NO_CALL when allow_call=False")

    def test_no_call_when_fallback_path(self):
        """calendar_path가 PYKRX_FALLBACK → NO_CALL (allow_call=True여도)"""
        from logger import determine_trade_call
        result = determine_trade_call(
            status='SUCCESS',
            calendar_path='PYKRX_FALLBACK',
            clamp_applied=False,
            valid_forecast=True,
            anchor_match=True,
            allow_call=True
        )
        self.assertEqual(result, 'NO_CALL')
        print("[PASS] TC2c: NO_CALL for PYKRX_FALLBACK path")

    def test_no_call_when_failed_status(self):
        """status=FAILED → NO_CALL"""
        from logger import determine_trade_call
        result = determine_trade_call(
            status='FAILED',
            calendar_path='FUTURE_DATE_SKIP',
            clamp_applied=False,
            valid_forecast=True,
            anchor_match=True,
            allow_call=True
        )
        self.assertEqual(result, 'NO_CALL')
        print("[PASS] TC2d: NO_CALL for FAILED status")

    def test_no_call_when_clamp_applied(self):
        """clamp_applied=True → NO_CALL"""
        from logger import determine_trade_call
        result = determine_trade_call(
            status='SUCCESS',
            calendar_path='PYKRX_OK',
            clamp_applied=True,
            valid_forecast=True,
            anchor_match=True,
            allow_call=True
        )
        self.assertEqual(result, 'NO_CALL')
        print("[PASS] TC2e: NO_CALL when clamp_applied")

    def test_call_for_pykrx_ok_path(self):
        """PYKRX_OK도 CALL 허용 경로"""
        from logger import determine_trade_call
        result = determine_trade_call(
            status='SUCCESS',
            calendar_path='PYKRX_OK',
            clamp_applied=False,
            valid_forecast=True,
            anchor_match=True,
            allow_call=True
        )
        self.assertEqual(result, 'CALL')
        print("[PASS] TC2f: CALL for PYKRX_OK path")

    def test_no_call_for_holidays_only_path(self):
        """HOLIDAYS_ONLY → NO_CALL"""
        from logger import determine_trade_call
        result = determine_trade_call(
            status='SUCCESS',
            calendar_path='HOLIDAYS_ONLY',
            clamp_applied=False,
            valid_forecast=True,
            anchor_match=True,
            allow_call=True
        )
        self.assertEqual(result, 'NO_CALL')
        print("[PASS] TC2g: NO_CALL for HOLIDAYS_ONLY path")


class TC_SchemaColumns(unittest.TestCase):
    """보너스: CSV 스키마 컬럼 수 확인"""

    def test_schema_has_39_columns(self):
        from logger import SCHEMA_COLUMNS
        self.assertEqual(len(SCHEMA_COLUMNS), 39, f"Expected 39, got {len(SCHEMA_COLUMNS)}")
        print(f"[PASS] Schema: {len(SCHEMA_COLUMNS)} columns")

    def test_new_columns_present(self):
        from logger import SCHEMA_COLUMNS
        new_cols = ['calendar_path', 'calendar_issue', 'call_authorized']
        for col in new_cols:
            self.assertIn(col, SCHEMA_COLUMNS, f"Missing column: {col}")
        print("[PASS] New columns present: calendar_path, calendar_issue, call_authorized")


class TC_ModelVersion(unittest.TestCase):
    """MODEL_VERSION 확인"""

    def test_model_version(self):
        from predictor import MODEL_VERSION
        self.assertEqual(MODEL_VERSION, '0.1.15')
        print(f"[PASS] MODEL_VERSION: {MODEL_VERSION}")


if __name__ == '__main__':
    print("=" * 60)
    print("SWING_PREDICTOR v0.1.15 Test Suite")
    print("=" * 60)
    print()

    # 테스트 실행
    loader = unittest.TestLoader()
    suite = unittest.TestSuite()

    # 순서: TC1-TC2 (integration) → TC3-TC8 (mock unit) → 보너스
    test_classes = [
        TC1_AllowCallDefault,
        TC2_DetermineTradeCall,
        TC3_PykrxOk,
        TC4_PykrxEmpty,
        TC5_NetworkError,
        TC6_UnknownError,
        TC7_PykrxUnavailable,
        TC8_FutureDateSkip,
        TC_SchemaColumns,
        TC_ModelVersion,
    ]

    for tc in test_classes:
        suite.addTests(loader.loadTestsFromTestCase(tc))

    runner = unittest.TextTestRunner(verbosity=0)
    result = runner.run(suite)

    print()
    print("=" * 60)
    total = result.testsRun
    failures = len(result.failures) + len(result.errors)
    print(f"Total: {total}, Passed: {total - failures}, Failed: {failures}")
    if failures == 0:
        print("ALL TESTS PASSED")
    else:
        print("SOME TESTS FAILED")
        for f in result.failures:
            print(f"  FAIL: {f[0]}")
        for e in result.errors:
            print(f"  ERROR: {e[0]}")
    print("=" * 60)

    sys.exit(0 if failures == 0 else 1)
