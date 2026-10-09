"""Unit tests for the signed discovery-head freshness alarm."""

from __future__ import annotations

import contextlib
import importlib.util
import io
import json
import sys
import unittest
from pathlib import Path

REPO = Path(__file__).resolve().parents[2]
SCRIPT = REPO / "scripts" / "check-discovery-head-freshness.py"
SPEC = importlib.util.spec_from_file_location("check_discovery_head_freshness", SCRIPT)
freshness = importlib.util.module_from_spec(SPEC)
assert SPEC.loader is not None
SPEC.loader.exec_module(freshness)


class DiscoveryHeadFreshnessTests(unittest.TestCase):
    def run_check(self, threshold: str) -> tuple[int, str, str]:
        head = json.dumps(
            {
                "signed": {
                    "issued_at": "2026-10-09T00:00:00Z",
                    "expires_at": "2026-10-10T00:00:00Z",
                }
            }
        )
        stdout, stderr = io.StringIO(), io.StringIO()
        old_stdin = sys.stdin
        sys.stdin = io.StringIO(head)
        try:
            with contextlib.redirect_stdout(stdout), contextlib.redirect_stderr(stderr):
                try:
                    code = freshness.main(["--min-hours", threshold])
                except SystemExit as exc:
                    code = int(exc.code or 0)
        finally:
            sys.stdin = old_stdin
        return code, stdout.getvalue(), stderr.getvalue()

    def test_non_finite_threshold_alarms(self) -> None:
        for value in ("nan", "inf"):
            with self.subTest(value=value):
                code, _, err = self.run_check(value)
                self.assertEqual(code, 1)
                self.assertIn("must be finite and non-negative", err)


if __name__ == "__main__":
    unittest.main()
