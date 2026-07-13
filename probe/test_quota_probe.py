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


if __name__ == "__main__":
    unittest.main()
