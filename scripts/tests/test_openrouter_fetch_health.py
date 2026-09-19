#!/usr/bin/env python3
"""Unit tests for scripts/check-openrouter-fetch-health.py."""

from __future__ import annotations

import importlib.util
import io
import json
import tempfile
import unittest
from contextlib import redirect_stderr, redirect_stdout
from pathlib import Path

REPO = Path(__file__).resolve().parents[2]
SCRIPT = REPO / "scripts" / "check-openrouter-fetch-health.py"
SPEC = importlib.util.spec_from_file_location("check_openrouter_fetch_health", SCRIPT)
health = importlib.util.module_from_spec(SPEC)
assert SPEC.loader is not None
SPEC.loader.exec_module(health)

NOW = "2026-09-19T04:00:00Z"


def _run(argv: list[str]) -> tuple[int, str, str]:
    stdout = io.StringIO()
    stderr = io.StringIO()
    with redirect_stdout(stdout), redirect_stderr(stderr):
        try:
            code = health.main(argv)
        except SystemExit as exc:
            code = int(exc.code or 0)
    return code, stdout.getvalue(), stderr.getvalue()


class OpenRouterFetchHealthTests(unittest.TestCase):
    def test_http_200_is_ok(self) -> None:
        code, out, err = _run(["--key-status", "200", "--skip-key-probe"])
        self.assertEqual(code, 0, err)
        self.assertIn("key probe HTTP 200 OK", out)
        self.assertIn("[openrouter-fetch-health] OK", out)
        self.assertNotIn("sk-or-", out + err)
        self.assertNotIn("Bearer", out + err)

    def test_http_401_alarms_without_echoing_a_key(self) -> None:
        code, out, err = _run(["--key-status", "401"])
        self.assertEqual(code, 1)
        self.assertIn("ALARM:", err)
        self.assertIn("HTTP 401", err)
        self.assertIn("OPENROUTER_API_KEY rejected", err)
        self.assertNotIn("sk-or-", out + err)
        self.assertNotIn("Bearer", out + err)

    def test_http_403_alarms(self) -> None:
        code, _, err = _run(["--key-status", "403"])
        self.assertEqual(code, 1)
        self.assertIn("HTTP 403", err)

    def test_http_500_alarms(self) -> None:
        code, _, err = _run(["--key-status", "500"])
        self.assertEqual(code, 1)
        self.assertIn("HTTP 500", err)
        self.assertNotIn("rejected", err)

    def test_fresh_archive_is_ok(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            archive = Path(tmp)
            (archive / "openrouter-catalog-proposal-2026-09-18T12-00-00Z.json").write_text(
                json.dumps({"generated_at": "2026-09-18T12:00:00Z", "status": "proposal_only_never_applied"}),
                encoding="utf-8",
            )
            code, out, err = _run(
                [
                    "--skip-key-probe",
                    "--snapshot-archive",
                    str(archive),
                    "--now",
                    NOW,
                    "--max-snapshot-age-hours",
                    "48",
                ]
            )
            self.assertEqual(code, 0, err)
            self.assertIn("archive freshness OK", out)

    def test_stale_archive_alarms(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            archive = Path(tmp)
            (archive / "openrouter-pricing-snapshot-old.json").write_text(
                json.dumps({"generated_at": "2026-09-16T04:00:00Z"}),
                encoding="utf-8",
            )
            code, _, err = _run(
                [
                    "--skip-key-probe",
                    "--snapshot-archive",
                    str(archive),
                    "--now",
                    NOW,
                    "--max-snapshot-age-hours",
                    "48",
                ]
            )
            self.assertEqual(code, 1)
            self.assertIn("ALARM:", err)
            self.assertIn("72.0h old", err)
            self.assertIn("openrouter-catalog-propose.yml", err)

    def test_empty_archive_alarms(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            code, _, err = _run(
                ["--skip-key-probe", "--snapshot-archive", tmp, "--now", NOW]
            )
            self.assertEqual(code, 1)
            self.assertIn("no snapshot or catalog-proposal", err)

    def test_missing_archive_alarms(self) -> None:
        code, _, err = _run(
            ["--skip-key-probe", "--snapshot-archive", "/tmp/does-not-exist-openrouter-archive"]
        )
        self.assertEqual(code, 1)
        self.assertIn("is missing", err)


if __name__ == "__main__":
    unittest.main()
