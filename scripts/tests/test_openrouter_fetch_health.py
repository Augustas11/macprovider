#!/usr/bin/env python3
"""Unit tests for scripts/check-openrouter-fetch-health.py."""

from __future__ import annotations

import importlib.util
import io
import json
import tempfile
import unittest
from decimal import Decimal
from contextlib import redirect_stderr, redirect_stdout
from pathlib import Path
from types import SimpleNamespace
from unittest.mock import patch

from scripts import openrouter_pricing_engine as engine

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


class ActionsProposalFreshnessTests(unittest.TestCase):
    def proposal(self):
        policy = engine.load_json_file(engine.DEFAULT_POLICY_PATH, "policy")
        return engine.build_catalog_proposal(
            [{"model_id": "z-ai/glm-4.5-air", "pricing": {
                "input_per_mtok": "0.15", "completion_per_mtok": "0.85", "benchmark_provider": "A"},
              "demand_request_count_30m": 1000, "endpoint_count": 3,
              "servability": {"verdict": "review", "required_gb": "80",
                              "mlx_repo": "mlx-community/GLM-4.5-Air-4bit", "quant": "4bit",
                              "reasons": ["text-serving build fits fleet residency"]}}],
            policy, now=health.parse_rfc3339_z(NOW, "test"),
            yield_floor_completion_per_mtok=Decimal("0.30"), demand_floor_request_count_30m=500,
        )

    def run_check(self, proposal=None, run=None, runs=None):
        proposal = self.proposal() if proposal is None else proposal
        run = run or {"id": 123, "head_branch": "main", "status": "completed",
                      "conclusion": "success", "event": "schedule"}

        def gh(args, **kwargs):
            if args[1] == "api":
                self.assertIn("branch=main&status=success", args[2])
                return SimpleNamespace(stdout=json.dumps({"workflow_runs": [run] if runs is None else runs}))
            self.assertEqual(args[:4], ["gh", "run", "download", "123"])
            self.assertEqual(args[args.index("--name") + 1], "openrouter-catalog-proposal")
            directory = Path(args[args.index("--dir") + 1])
            (directory / "openrouter-catalog-proposal-current.json").write_text(json.dumps(proposal))
            return SimpleNamespace(stdout="")

        with patch.object(health.subprocess, "run", side_effect=gh):
            return _run(["--key-status", "200", "--actions-repository", "Augustas11/macprovider", "--now", NOW])

    def test_main_producer_retains_the_artifact_required_by_health(self):
        workflow = (REPO / ".github/workflows/openrouter-catalog-propose.yml").read_text()
        uploader = workflow.split("uses: actions/upload-artifact@", 1)[1].split("      - name:", 1)[0]
        self.assertIn("name: openrouter-catalog-proposal", uploader)
        self.assertIn("openrouter-catalog-proposal-*.json", uploader)
        retention = next(line for line in uploader.splitlines() if "retention-days:" in line)
        self.assertGreater(int(retention.split(":", 1)[1]), 2)

    def test_fresh_valid_completed_main_proposal_clears_fetch_health(self):
        code, out, err = self.run_check()
        self.assertEqual(code, 0, err)
        self.assertIn("verified main producer run=123", out)
        self.assertIn("archive freshness OK", out)

    def test_empty_proposal_cannot_clear_health(self):
        proposal = self.proposal()
        proposal["selected"] = []
        code, _, err = self.run_check(proposal)
        self.assertEqual(code, 1)
        self.assertIn("empty", err)

    def test_unreviewed_or_failed_run_cannot_clear_health(self):
        for change in [{"head_branch": "feature"}, {"conclusion": "failure"},
                       {"status": "in_progress"}, {"event": "pull_request"}]:
            run = {"id": 123, "head_branch": "main", "status": "completed",
                   "conclusion": "success", "event": "schedule", **change}
            code, _, err = self.run_check(run=run)
            self.assertEqual(code, 1)
            self.assertIn("not a trusted", err)

    def test_stale_future_or_obsolete_policy_proposal_cannot_clear_health(self):
        for change, expected in [({"generated_at": "2026-09-16T04:00:00Z"}, "72.0h old"),
                                 ({"generated_at": "2026-09-20T04:00:00Z"}, "future"),
                                 ({"policy_version": "old"}, "obsolete pricing policy")]:
            proposal = {**self.proposal(), **change}
            code, _, err = self.run_check(proposal)
            self.assertEqual(code, 1)
            self.assertIn(expected, err)

    def test_malformed_proposal_cannot_clear_health(self):
        proposal = self.proposal()
        proposal["selected"][0]["proposed_completion_per_mtok"] = "NaN"
        code, _, err = self.run_check(proposal)
        self.assertEqual(code, 1)
        self.assertIn("failed validation", err)

    def test_missing_successful_run_remains_alarm(self):
        code, _, err = self.run_check(runs=[])
        self.assertEqual(code, 1)
        self.assertIn("no successful main", err)

    def test_download_error_does_not_echo_subprocess_output(self):
        error = health.subprocess.CalledProcessError(1, ["gh"], stderr="Bearer sk-or-secret")
        with patch.object(health.subprocess, "run", side_effect=error):
            code, out, err = _run(["--key-status", "200", "--actions-repository", "Augustas11/macprovider"])
        self.assertEqual(code, 1)
        self.assertNotIn("sk-or-secret", out + err)

    def test_other_repositories_are_not_trusted(self):
        code, _, err = _run(["--key-status", "200", "--actions-repository", "someone/fork"])
        self.assertEqual(code, 1)
        self.assertIn("only trusts", err)


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

    def test_non_finite_archive_age_threshold_alarms(self) -> None:
        for value in ("nan", "inf"):
            with self.subTest(value=value):
                code, _, err = _run(
                    [
                        "--skip-key-probe",
                        "--snapshot-archive",
                        tempfile.gettempdir(),
                        "--max-snapshot-age-hours",
                        value,
                    ]
                )
                self.assertEqual(code, 1)
                self.assertIn("must be finite and positive", err)


if __name__ == "__main__":
    unittest.main()
