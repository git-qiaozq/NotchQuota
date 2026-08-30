import json
import os
import tempfile
import unittest
from unittest import mock

import quota_probe


class CodexWindowParsingTests(unittest.TestCase):
    def setUp(self):
        self.now = mock.patch.object(quota_probe, "_now", return_value=1_000_000)
        self.now.start()

    def tearDown(self):
        self.now.stop()

    def test_primary_weekly_window_is_not_mislabeled_as_five_hour(self):
        metrics = quota_probe._codex_metrics_from_rate_limit({
            "primary_window": {
                "used_percent": 1,
                "limit_window_seconds": 604800,
                "reset_at": 1_604_800,
            },
            "secondary_window": None,
        })

        self.assertEqual(metrics, [{
            "label": "周窗口",
            "used_pct": 1,
            "reset": "7d0h",
            "reset_at": 1_604_800,
        }])

    def test_legacy_two_window_response_keeps_display_order(self):
        metrics = quota_probe._codex_metrics_from_rate_limit({
            "primary_window": {
                "used_percent": 20,
                "limit_window_seconds": 18000,
                "reset_at": 1_018_000,
            },
            "secondary_window": {
                "used_percent": 30,
                "limit_window_seconds": 604800,
                "reset_at": 1_604_800,
            },
        })

        self.assertEqual([metric["label"] for metric in metrics], ["5h 窗口", "周窗口"])
        self.assertEqual([metric["used_pct"] for metric in metrics], [20, 30])

    def test_missing_duration_falls_back_to_legacy_positions(self):
        metrics = quota_probe._codex_metrics_from_rate_limit({
            "primary_window": {"used_percent": 5, "reset_at": 1_018_000},
            "secondary_window": {"used_percent": 8, "reset_at": 1_604_800},
        })

        self.assertEqual([metric["label"] for metric in metrics], ["5h 窗口", "周窗口"])


class CursorUsageParsingTests(unittest.TestCase):
    def setUp(self):
        self.now = mock.patch.object(quota_probe, "_now", return_value=1_000_000)
        self.now.start()

    def tearDown(self):
        self.now.stop()

    def test_uses_spending_page_buckets_instead_of_legacy_dollar_ratio(self):
        metrics = quota_probe._cursor_metrics_from_usage({
            "billingCycleEnd": "1086400000",
            "planUsage": {
                "totalSpend": 1484,
                "limit": 2000,
                "autoPercentUsed": 1.2155555555555555,
                "apiPercentUsed": 20.822222222222223,
            },
            "spendLimitUsage": {
                "individualLimit": 500,
                "individualRemaining": 500,
            },
        })

        self.assertEqual(metrics, [
            {"label": "Cursor 模型", "used_pct": 1.2, "reset": "1d0h"},
            {"label": "其他模型", "used_pct": 20.8, "reset": "1d0h"},
            {"label": "按需消费", "text": "$0.00 / $5.00"},
        ])

    def test_missing_bucket_fields_does_not_recreate_inaccurate_legacy_metric(self):
        metrics = quota_probe._cursor_metrics_from_usage({
            "planUsage": {"totalSpend": 1484, "limit": 2000},
            "spendLimitUsage": {},
        })

        self.assertEqual(metrics, [])

    def test_old_cache_schema_is_refetched(self):
        fresh = {
            "id": "cursor", "name": "Cursor", "plan": "Pro",
            "status": "ok", "detail": "实时", "metrics": [],
            "url": quota_probe._CURSOR_SPENDING_URL,
        }
        with tempfile.TemporaryDirectory() as directory:
            cache_path = os.path.join(directory, "cursor.json")
            with open(cache_path, "w") as cache_file:
                json.dump({**fresh, "_cache_version": 1}, cache_file)
            os.utime(cache_path, (999_900, 999_900))
            with mock.patch.object(quota_probe, "_CURSOR_CACHE", cache_path), \
                    mock.patch.object(quota_probe, "_probe_cursor_fresh",
                                      return_value=fresh) as fetch:
                result = quota_probe.probe_cursor()

            fetch.assert_called_once_with()
            self.assertEqual(result, fresh)
            with open(cache_path) as cache_file:
                cached = json.load(cache_file)
            self.assertEqual(cached["_cache_version"],
                             quota_probe._CURSOR_CACHE_VERSION)


if __name__ == "__main__":
    unittest.main()
