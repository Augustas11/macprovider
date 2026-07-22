#!/usr/bin/env python3

from __future__ import annotations

import importlib.util
import json
import os
from pathlib import Path
import sqlite3
import subprocess
import sys
import tempfile
import unittest


MODULE_PATH = Path(__file__).with_name("aead_rekey_oneshot.py")
SPEC = importlib.util.spec_from_file_location("aead_rekey_oneshot", MODULE_PATH)
assert SPEC and SPEC.loader
HARNESS = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(HARNESS)


def ts(second: int) -> str:
    return f"2026-07-22T12:00:{second:02d}.000000000Z"


def passing_capture(gate: str = "request_threshold") -> dict:
    provider = {
        "provider_id": "mp-dedicated",
        "assigned_id": "assigned-one",
        "connected_at": ts(0),
        "binary_version": "v1.8.58",
        "safety_telemetry": {"compatibility_set_id": "set-reviewed"},
        "state": "ready",
        "routing_eligible": True,
        "encrypted_leg": True,
    }
    return {
        "gate": gate,
        "expected_provider_id": "mp-dedicated",
        "expected_pool_size": 1,
        "health_initial": {"status": "ok", "version": "v1.8.49"},
        "health_final": {
            "status": "ok",
            "version": "v1.8.49",
            "pool_degraded": 0,
            "pool_draining": 0,
            "pool_unavailable": 0,
        },
        "requests": [
            {
                "request_index": 0,
                "role": "sentinel",
                "external_request_id": "external-sentinel",
                "started_at": ts(1),
                "ended_at": ts(4),
                "http_status": 200,
                "outcome": "ok",
                "response_excerpt": '{"choices":[{}]}',
            },
            {
                "request_index": 1,
                "role": "trigger",
                "external_request_id": "external-trigger",
                "started_at": ts(2),
                "ended_at": ts(7),
                "http_status": 200,
                "outcome": "ok",
                "response_excerpt": '{"choices":[{}]}',
            },
        ],
        "request_log": [
            {
                "ts_utc": ts(4),
                "request_id": "old-epoch-sentinel",
                "external_request_id": "external-sentinel",
                "provider_assigned_id": "assigned-one",
                "latency_ms": 3000,
                "queue_wait_ms": 0,
                "status": 200,
                "error_code": None,
                "retried": 0,
                "attempt_n": 0,
            },
            {
                "ts_utc": ts(7),
                "request_id": "buyer-0",
                "external_request_id": "external-trigger",
                "provider_assigned_id": "assigned-one",
                "latency_ms": 5000,
                "queue_wait_ms": 2000,
                "status": 200,
                "error_code": None,
                "retried": 0,
                "attempt_n": 0,
            },
        ],
        "pool_samples": [
            {"observed_at": ts(1), "poolz": {"pool": [provider], "summary": {"ready": 1}}},
            {
                "observed_at": ts(2),
                "poolz": {"pool": [dict(provider, state="busy")], "summary": {"busy": 1}},
            },
            {"observed_at": ts(7), "poolz": {"pool": [provider], "summary": {"ready": 1}}},
        ],
        "events": [
            {
                "time": ts(3),
                "event": "aead_rekey",
                "provider_id": "mp-dedicated",
                "assigned_id": "assigned-one",
                "request_id": "buyer-0",
                "kid": "old-kid",
                "reason": gate,
                "decision": "rotate_in_band",
            },
            {
                "time": ts(5),
                "event": "aead_rekey_committed",
                "provider_id": "mp-dedicated",
                "assigned_id": "assigned-one",
                "request_id": "buyer-0",
                "rekey_id": "rekey-one",
                "old_kid": "old-kid",
                "new_kid": "new-kid",
                "reason": gate,
                "decision": "continue_same_session",
            },
        ],
    }


class EvaluateCaptureTests(unittest.TestCase):
    def test_success_handoff_records_required_evidence(self) -> None:
        result = HARNESS.evaluate_capture(passing_capture())
        self.assertEqual(result["verdict"], "PASS", result["reasons"])
        self.assertEqual(result["identity"]["assigned_id"], "assigned-one")
        self.assertEqual(result["rekey"]["old_kid"], "old-kid")
        self.assertEqual(result["rekey"]["new_kid"], "new-kid")
        self.assertEqual(result["metrics"]["rekey_window_overlapping_requests"], 2)

    def test_age_handoff_uses_same_analyzer(self) -> None:
        result = HARNESS.evaluate_capture(passing_capture("age_threshold"))
        self.assertEqual(result["verdict"], "PASS", result["reasons"])

    def test_reconnect_or_legacy_close_is_fail(self) -> None:
        capture = passing_capture()
        second_provider = dict(capture["pool_samples"][-1]["poolz"]["pool"][0])
        second_provider["connected_at"] = ts(4)
        capture["pool_samples"][-1]["poolz"]["pool"] = [second_provider]
        capture["events"].append(
            {
                "time": ts(4),
                "provider_id": "mp-dedicated",
                "assigned_id": "assigned-one",
                "message": "provider websocket disconnected",
            }
        )
        result = HARNESS.evaluate_capture(capture)
        self.assertEqual(result["verdict"], "FAIL")
        self.assertTrue(any("provider identity changed" in reason for reason in result["reasons"]))
        self.assertTrue(any("close/reconnect" in reason for reason in result["reasons"]))

    def test_providerless_close_log_is_fail_in_single_provider_pool(self) -> None:
        capture = passing_capture()
        capture["events"].append(
            {"time": ts(4), "message": "provider websocket closing"}
        )
        result = HARNESS.evaluate_capture(capture)
        self.assertEqual(result["verdict"], "FAIL")
        self.assertTrue(any("close/reconnect" in reason for reason in result["reasons"]))

    def test_provider_cli_or_compatibility_identity_drift_is_fail(self) -> None:
        capture = passing_capture()
        final_provider = capture["pool_samples"][-1]["poolz"]["pool"][0]
        final_provider["binary_version"] = "v1.8.59"
        final_provider["safety_telemetry"] = {"compatibility_set_id": "set-other"}
        result = HARNESS.evaluate_capture(capture)
        self.assertEqual(result["verdict"], "FAIL")
        self.assertTrue(any("provider identity changed" in reason for reason in result["reasons"]))

    def test_buyer_503_is_fail(self) -> None:
        capture = passing_capture()
        capture["requests"][0].update(
            http_status=503,
            outcome="http_error",
            response_excerpt='{"error":{"code":"no_provider_available"}}',
        )
        result = HARNESS.evaluate_capture(capture)
        self.assertEqual(result["verdict"], "FAIL")
        self.assertIn("buyer observed HTTP 503", result["reasons"])
        self.assertIn("buyer observed no_provider_available", result["reasons"])

    def test_missing_kid_evidence_is_fail(self) -> None:
        capture = passing_capture()
        capture["events"][1]["new_kid"] = ""
        result = HARNESS.evaluate_capture(capture)
        self.assertEqual(result["verdict"], "FAIL")
        self.assertTrue(any("missing old_kid" in reason for reason in result["reasons"]))

    def test_trigger_must_map_to_rekey_request_id(self) -> None:
        capture = passing_capture()
        capture["request_log"][1]["request_id"] = "different-internal-request"
        result = HARNESS.evaluate_capture(capture)
        self.assertEqual(result["verdict"], "FAIL")
        self.assertTrue(any("harness trigger" in reason for reason in result["reasons"]))

    def test_old_epoch_sentinel_must_drain_before_commit(self) -> None:
        capture = passing_capture()
        capture["request_log"][0]["ts_utc"] = ts(2)
        capture["request_log"][0]["latency_ms"] = 500
        result = HARNESS.evaluate_capture(capture)
        self.assertEqual(result["verdict"], "FAIL")
        self.assertTrue(any("old-epoch" in reason for reason in result["reasons"]))

    def test_dry_run_cli_writes_json_and_markdown(self) -> None:
        with tempfile.TemporaryDirectory() as temp_text:
            temp = Path(temp_text)
            fixture = temp / "capture.json"
            output = temp / "evidence"
            fixture.write_text(json.dumps(passing_capture()), encoding="utf-8")
            completed = subprocess.run(
                [
                    sys.executable,
                    str(MODULE_PATH),
                    "--gate",
                    "request_threshold",
                    "--dry-run-fixture",
                    str(fixture),
                    "--output-dir",
                    str(output),
                ],
                check=False,
                capture_output=True,
                text=True,
                timeout=5,
            )
            self.assertEqual(completed.returncode, 0, completed.stderr)
            evidence = json.loads((output / "evidence.json").read_text(encoding="utf-8"))
            self.assertEqual(evidence["result"]["verdict"], "DRY-RUN-PASS")
            self.assertNotIn("response_excerpt", evidence["capture"]["requests"][0])
            self.assertIn("**DRY-RUN-PASS**", (output / "evidence.md").read_text(encoding="utf-8"))

    def test_runtime_failure_cannot_be_hidden_in_dry_run(self) -> None:
        capture = passing_capture()
        capture["runtime_failures"] = ["poolz monitor failed"]
        result = HARNESS.evaluate_capture(capture)
        self.assertEqual(result["verdict"], "FAIL")
        self.assertTrue(any("runtime failure" in reason for reason in result["reasons"]))

    def test_required_post_commit_success_count_is_enforced(self) -> None:
        capture = passing_capture()
        capture["bounds"] = {"post_commit_successes": 3}
        result = HARNESS.evaluate_capture(capture)
        self.assertEqual(result["verdict"], "FAIL")
        self.assertTrue(any("required 3" in reason for reason in result["reasons"]))


class ConfigPreflightTests(unittest.TestCase):
    def write_configs(self, overlay: str) -> tuple[Path, Path, tempfile.TemporaryDirectory]:
        temp = tempfile.TemporaryDirectory()
        root = Path(temp.name)
        base = root / "base.yaml"
        base.write_text(
            f"""listen:\n  bind_address: 127.0.0.1\n  buyer_port: 18443\n  provider_port: 18444\ncoordinator:\n  require_gateway_context: true\nrouting:\n  max_retries: 0\nstorage:\n  db_path: {root / 'coordinator.db'}\ntier2:\n  require_encrypted_leg: true\n  encrypted_leg_rekey_after_requests: 10000\n  encrypted_leg_rekey_after_seconds: 3600\n""",
            encoding="utf-8",
        )
        overlay_path = root / "overlay.yaml"
        overlay_path.write_text(overlay, encoding="utf-8")
        return base, overlay_path, temp

    def test_request_overlay_is_bounded(self) -> None:
        base, overlay, temp = self.write_configs(
            "tier2:\n  encrypted_leg_rekey_after_requests: 4\n  encrypted_leg_rekey_after_seconds: 3600\n"
        )
        self.addCleanup(temp.cleanup)
        evidence = HARNESS.validate_config(base, overlay, "request_threshold", 20, 60)
        self.assertEqual(evidence["encrypted_leg_rekey_after_requests"], 4)

    def test_age_overlay_is_bounded(self) -> None:
        base, overlay, temp = self.write_configs(
            "tier2:\n  encrypted_leg_rekey_after_requests: 10000\n  encrypted_leg_rekey_after_seconds: 10\n"
        )
        self.addCleanup(temp.cleanup)
        evidence = HARNESS.validate_config(base, overlay, "age_threshold", 20, 60)
        self.assertEqual(evidence["encrypted_leg_rekey_after_seconds"], 10)

    def test_retry_configuration_is_rejected(self) -> None:
        base, overlay, temp = self.write_configs(
            "routing:\n  max_retries: 1\ntier2:\n  encrypted_leg_rekey_after_requests: 4\n  encrypted_leg_rekey_after_seconds: 3600\n"
        )
        self.addCleanup(temp.cleanup)
        with self.assertRaisesRegex(HARNESS.HarnessError, "max_retries must be 0"):
            HARNESS.validate_config(base, overlay, "request_threshold", 20, 60)

    def test_gateway_retry_is_rejected(self) -> None:
        with tempfile.TemporaryDirectory() as temp_text:
            path = Path(temp_text) / "gateway.yaml"
            path.write_text(
                """listen:\n  bind_address: 127.0.0.1\n  port: 19443\ncoordinator:\n  buyer_url: http://127.0.0.1:18443\n  operator_url: http://127.0.0.1:18444\nretry_503:\n  enabled: true\n""",
                encoding="utf-8",
            )
            with self.assertRaisesRegex(HARNESS.HarnessError, "retry_503.enabled must be false"):
                HARNESS.validate_gateway_config(
                    path,
                    "http://127.0.0.1:19443/v1/chat/completions",
                    "http://127.0.0.1:18444/poolz",
                    {"buyer_port": 18443, "provider_port": 18444},
                )


class ApprovalLedgerTests(unittest.TestCase):
    def test_approval_is_consumed_once_across_output_directories(self) -> None:
        with tempfile.TemporaryDirectory() as temp_text:
            ledger = Path(temp_text) / "attempts.jsonl"
            approval = "https://github.com/Augustas11/macprovider/issues/540#issuecomment-123"
            first = HARNESS.consume_approval_once(
                str(ledger), "request_threshold", approval, "mp-dedicated", "overlay-sha"
            )
            self.assertEqual(os.stat(ledger).st_mode & 0o777, 0o600)
            with self.assertRaisesRegex(HARNESS.HarnessError, "already been consumed"):
                HARNESS.consume_approval_once(
                    str(ledger), "request_threshold", approval, "mp-dedicated", "overlay-sha"
                )
            self.assertEqual(len(first), 64)


class RequestLogTests(unittest.TestCase):
    def test_read_only_join_returns_only_bounded_fields(self) -> None:
        with tempfile.TemporaryDirectory() as temp_text:
            db = Path(temp_text) / "coordinator.db"
            connection = sqlite3.connect(db)
            connection.execute(
                """CREATE TABLE request_log (
                id INTEGER PRIMARY KEY, ts_utc TEXT, request_id TEXT, external_request_id TEXT,
                provider_assigned_id TEXT, latency_ms REAL, queue_wait_ms REAL, status INTEGER,
                error_code TEXT, retried INTEGER, attempt_n INTEGER, buyer_ip TEXT
                )"""
            )
            connection.execute(
                "INSERT INTO request_log VALUES (1,?,?,?,?,?,?,?,?,?,?,?)",
                (ts(4), "internal", "external", "assigned", 1000, 0, 200, None, 0, 0, "private-ip"),
            )
            connection.commit()
            connection.close()
            rows = HARNESS.read_request_log(db, ["external"])
            self.assertEqual(rows[0]["request_id"], "internal")
            self.assertNotIn("buyer_ip", rows[0])


if __name__ == "__main__":
    unittest.main()
