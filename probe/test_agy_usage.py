import threading
import time
import unittest
from unittest import mock

import agy_usage


def _session_harness():
    session = object.__new__(agy_usage._AgySession)
    session.master = None
    session.pid = 1
    session.buf = b""
    session.started_at = time.time() - 10
    session.sent_once = False
    session.login_selected = False
    session.auth_waiting = False
    session.auth_retry_attempt = 0
    session.next_auth_retry_at = 0.0
    session.lock = threading.Lock()
    session._is_running = lambda: True
    session._request_usage_once = lambda wait_seconds=9: ([{"group": "GEMINI MODELS"}], "")
    return session


class AuthRecoveryTests(unittest.TestCase):
    def test_auth_retry_backoff_is_bounded(self):
        self.assertEqual(agy_usage._auth_retry_delay(0), 300)
        self.assertEqual(agy_usage._auth_retry_delay(1), 900)
        self.assertEqual(agy_usage._auth_retry_delay(2), 1800)
        self.assertEqual(agy_usage._auth_retry_delay(99), 1800)

    def test_force_refresh_restarts_known_auth_waiting_session(self):
        session = _session_harness()
        session.auth_waiting = True
        session.next_auth_retry_at = time.time() + 300
        restarts = []

        def restart(reason):
            restarts.append(reason)
            session.auth_waiting = False

        session._restart_for_auth = restart
        session._wait_ready = lambda timeout: True

        result = session.fetch_usage(force_restart=True)

        self.assertEqual(result["status"], "ok")
        self.assertEqual(restarts, ["forced refresh"])

    def test_due_background_retry_restarts_auth_waiting_session(self):
        session = _session_harness()
        session.auth_waiting = True
        session.next_auth_retry_at = time.time() - 1
        restarts = []

        def restart(reason):
            restarts.append(reason)
            session.auth_waiting = False

        session._restart_for_auth = restart
        session._wait_ready = lambda timeout: True

        result = session.fetch_usage()

        self.assertEqual(result["status"], "ok")
        self.assertEqual(restarts, ["scheduled auth retry"])

    def test_force_refresh_restarts_newly_detected_auth_wait(self):
        session = _session_harness()
        session.buf = b"Select login method:\nGoogle OAuth\n"
        ready_results = iter((False, True))
        restarts = []

        def restart(reason):
            restarts.append(reason)
            session.buf = b""
            session.auth_waiting = False

        session._restart_for_auth = restart
        session._wait_ready = lambda timeout: next(ready_results)

        result = session.fetch_usage(force_restart=True)

        self.assertEqual(result["status"], "ok")
        self.assertEqual(restarts, ["forced refresh"])


class DaemonProtocolTests(unittest.TestCase):
    def test_force_uses_force_protocol(self):
        with (
            mock.patch.object(agy_usage, "_network_ready", return_value=True),
            mock.patch.object(agy_usage, "_ensure_daemon", return_value={"status": "ok"}),
            mock.patch.object(
                agy_usage, "_daemon_request", return_value={"status": "ok", "groups": []}
            ) as request,
        ):
            result = agy_usage.fetch_usage(force=True)

        self.assertEqual(result["status"], "ok")
        request.assert_called_once_with("usage_force", 43)

    def test_force_replaces_legacy_daemon_protocol(self):
        with (
            mock.patch.object(agy_usage, "_network_ready", return_value=True),
            mock.patch.object(agy_usage, "_ensure_daemon", return_value={"status": "ok"}),
            mock.patch.object(
                agy_usage,
                "_daemon_request",
                side_effect=(
                    {"status": "error", "detail": "未知命令"},
                    {"status": "ok", "groups": []},
                ),
            ) as request,
            mock.patch.object(
                agy_usage, "_replace_legacy_daemon", return_value={"status": "ok"}
            ) as replace,
        ):
            result = agy_usage.fetch_usage(force=True)

        self.assertEqual(result["status"], "ok")
        self.assertEqual(request.call_count, 2)
        replace.assert_called_once_with()


if __name__ == "__main__":
    unittest.main()
