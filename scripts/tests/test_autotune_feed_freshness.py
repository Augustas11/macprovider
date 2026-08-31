#!/usr/bin/env python3
"""Unit tests for scripts/check-autotune-feed-freshness.py."""

from __future__ import annotations

import importlib.util
import io
import json
import sys
import unittest
from contextlib import redirect_stderr, redirect_stdout
from pathlib import Path

REPO = Path(__file__).resolve().parents[2]
SCRIPT = REPO / "scripts" / "check-autotune-feed-freshness.py"
SPEC = importlib.util.spec_from_file_location("check_autotune_feed_freshness", SCRIPT)
freshness = importlib.util.module_from_spec(SPEC)
assert SPEC.loader is not None
SPEC.loader.exec_module(freshness)

NOW = "2026-08-31T04:00:00Z"


def _run(payload: object, argv: list[str]) -> tuple[int, str, str]:
    stdin = json.dumps(payload) if not isinstance(payload, str) else payload
    stdout = io.StringIO()
    stderr = io.StringIO()
    old_stdin = sys.stdin
    sys.stdin = io.StringIO(stdin)
    try:
        with redirect_stdout(stdout), redirect_stderr(stderr):
            try:
                code = freshness.main(argv)
            except SystemExit as exc:
                code = int(exc.code or 0)
    finally:
        sys.stdin = old_stdin
    return code, stdout.getvalue(), stderr.getvalue()


class AutotuneFeedFreshnessTests(unittest.TestCase):
    def test_fresh_feed_is_ok(self) -> None:
        code, out, err = _run(
            {"generated_at": "2026-08-28T11:07:13Z", "version": "x"},
            ["--max-age-days", "20", "--now", NOW],
        )
        self.assertEqual(code, 0, err)
        self.assertIn("[autotune-feed-freshness] OK", out)
        self.assertIn("age=2.7d", out)

    def test_age_at_threshold_alarms(self) -> None:
        code, _, err = _run(
            {"generated_at": "2026-08-11T04:00:00Z"},
            ["--max-age-days", "20", "--now", NOW],
        )
        self.assertEqual(code, 1)
        self.assertIn("ALARM:", err)
        self.assertIn("20.0d old", err)
        self.assertIn("renew-autotune-static-feed.sh --deploy", err)

    def test_age_past_threshold_alarms(self) -> None:
        code, _, err = _run(
            {"generated_at": "2026-08-06T04:00:00Z"},
            ["--max-age-days", "20", "--now", NOW],
        )
        self.assertEqual(code, 1)
        self.assertIn("25.0d old", err)
        self.assertNotIn("EXPIRED", err)

    def test_exact_horizon_is_stale_not_expired(self) -> None:
        code, _, err = _run(
            {"generated_at": "2026-08-01T04:00:00Z"},
            ["--max-age-days", "20", "--now", NOW],
        )
        self.assertEqual(code, 1)
        self.assertIn("30.0d old", err)
        self.assertNotIn("EXPIRED", err)

    def test_past_client_horizon_uses_expired_wording(self) -> None:
        code, _, err = _run(
            {"generated_at": "2026-07-01T04:00:00Z"},
            ["--max-age-days", "20", "--now", NOW],
        )
        self.assertEqual(code, 1)
        self.assertIn("EXPIRED", err)
        self.assertIn("30-day horizon", err)

    def test_weekly_sla_fails_at_seven_days(self) -> None:
        code, _, err = _run(
            {"generated_at": "2026-08-24T04:00:00Z"},
            ["--max-age-days", "7", "--now", NOW],
        )
        self.assertEqual(code, 1)
        self.assertIn("7.0d old", err)

    def test_weekly_sla_passes_inside_seven_days(self) -> None:
        code, out, err = _run(
            {"generated_at": "2026-08-25T04:00:01Z"},
            ["--max-age-days", "7", "--now", NOW],
        )
        self.assertEqual(code, 0, err)
        self.assertIn("OK", out)

    def test_future_dated_feed_alarms(self) -> None:
        code, _, err = _run(
            {"generated_at": "2026-08-31T05:00:00Z"},
            ["--max-age-days", "20", "--now", NOW],
        )
        self.assertEqual(code, 1)
        self.assertIn("in the future", err)

    def test_ten_minute_future_skew_is_tolerated(self) -> None:
        code, out, err = _run(
            {"generated_at": "2026-08-31T04:10:00Z"},
            ["--max-age-days", "20", "--now", NOW],
        )
        self.assertEqual(code, 0, err)
        self.assertIn("OK", out)

    def test_missing_generated_at_fails_closed(self) -> None:
        code, _, err = _run({"version": "x"}, ["--now", NOW])
        self.assertEqual(code, 1)
        self.assertIn("generated_at", err)

    def test_empty_stdin_fails_closed(self) -> None:
        code, _, err = _run("  \n", ["--now", NOW])
        self.assertEqual(code, 1)
        self.assertIn("no rate-card on stdin", err)

    def test_non_object_json_fails_closed(self) -> None:
        code, _, err = _run("[1, 2]", ["--now", NOW])
        self.assertEqual(code, 1)
        self.assertIn("JSON object", err)

    def test_invalid_json_fails_closed(self) -> None:
        code, _, err = _run("{not-json", ["--now", NOW])
        self.assertEqual(code, 1)
        self.assertIn("not valid JSON", err)

    def test_unparseable_timestamp_fails_closed(self) -> None:
        code, _, err = _run(
            {"generated_at": "2026-08-28T11:07:13+00:00"},
            ["--now", NOW],
        )
        self.assertEqual(code, 1)
        self.assertIn("unparseable generated_at", err)

    def test_rejects_max_age_at_or_past_horizon(self) -> None:
        code, _, err = _run({"generated_at": NOW}, ["--max-age-days", "30", "--now", NOW])
        self.assertEqual(code, 1)
        self.assertIn("must be < 30", err)

    def test_rejects_non_positive_max_age(self) -> None:
        code, _, err = _run({"generated_at": NOW}, ["--max-age-days", "0", "--now", NOW])
        self.assertEqual(code, 1)
        self.assertIn("must be positive", err)

    def test_invalid_now_override_fails_closed(self) -> None:
        code, _, err = _run({"generated_at": NOW}, ["--now", "yesterday"])
        self.assertEqual(code, 1)
        self.assertIn("unparseable --now", err)


if __name__ == "__main__":
    unittest.main()
