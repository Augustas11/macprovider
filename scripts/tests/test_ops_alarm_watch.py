#!/usr/bin/env python3
"""Unit tests for scripts/ops_alarm_watch.py."""

from __future__ import annotations

import datetime as dt
import importlib.util
import unittest
from pathlib import Path

REPO = Path(__file__).resolve().parents[2]
SPEC = importlib.util.spec_from_file_location("ops_alarm_watch", REPO / "scripts" / "ops_alarm_watch.py")
watch = importlib.util.module_from_spec(SPEC)
assert SPEC.loader is not None
SPEC.loader.exec_module(watch)

NOW = dt.datetime(2026, 10, 9, 12, 0, tzinfo=dt.timezone.utc)


def run(created: str, status: str = "completed", conclusion: str = "success", event: str = "schedule") -> dict:
    return {"databaseId": 1, "event": event, "status": status, "conclusion": conclusion,
            "createdAt": created, "url": "https://example.invalid/run/1"}


def classify(runs: list[dict], **kw) -> tuple[str, str]:
    return watch.classify(runs, NOW, kw.get("waiting", 1.0), kw.get("running", 3.0),
                          kw.get("age", 192.0), kw.get("stale_only", False))


class OpsAlarmWatchTest(unittest.TestCase):
    def test_latest_success_is_healthy(self) -> None:
        self.assertEqual(classify([run("2026-10-06T16:00:00Z")]), ("success", ""))

    def test_cancelled_renewal_alarms(self) -> None:
        result, reason = classify([run("2026-10-06T16:00:00Z", conclusion="cancelled"),
                                   run("2026-09-29T16:00:00Z")])
        self.assertEqual(result, "alarm")
        self.assertIn("cancelled", reason)

    def test_later_success_clears_earlier_cancellation(self) -> None:
        self.assertEqual(classify([run("2026-10-06T16:00:00Z", conclusion="cancelled"),
                                   run("2026-10-07T16:00:00Z")])[0], "success")

    def test_plain_failure_is_left_to_the_in_run_alarm(self) -> None:
        self.assertEqual(classify([run("2026-10-06T16:00:00Z", conclusion="failure")])[0], "success")

    def test_waiting_for_approval_over_an_hour_alarms(self) -> None:
        result, reason = classify([run("2026-10-09T10:30:00Z", status="waiting", conclusion=""),
                                   run("2026-10-02T16:00:00Z")])
        self.assertEqual(result, "alarm")
        self.assertIn("waiting for environment approval", reason)

    def test_waiting_under_an_hour_is_fine(self) -> None:
        self.assertEqual(classify([run("2026-10-09T11:30:00Z", status="waiting", conclusion=""),
                                   run("2026-10-02T16:00:00Z")])[0], "success")

    def test_stuck_in_progress_alarms(self) -> None:
        self.assertEqual(classify([run("2026-10-09T06:00:00Z", status="in_progress", conclusion="")])[0], "alarm")

    def test_no_recent_run_alarms(self) -> None:
        result, reason = classify([run("2026-09-20T16:00:00Z")])
        self.assertEqual(result, "alarm")
        self.assertIn("schedule disabled", reason)
        self.assertEqual(classify([])[0], "alarm")

    def test_other_events_are_ignored(self) -> None:
        self.assertEqual(classify([run("2026-10-08T16:00:00Z", conclusion="cancelled", event="push"),
                                   run("2026-10-06T16:00:00Z")])[0], "success")

    def test_stale_only_ignores_cancellations(self) -> None:
        self.assertEqual(classify([run("2026-10-09T06:00:00Z", conclusion="cancelled")],
                                  age=24.0, stale_only=True)[0], "success")
        self.assertEqual(classify([run("2026-10-07T06:00:00Z")], age=24.0, stale_only=True)[0], "alarm")


if __name__ == "__main__":
    unittest.main()
