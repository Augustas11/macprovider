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
import threading
import time
from types import SimpleNamespace
from typing import Any
import unittest
import uuid


MODULE_PATH = Path(__file__).with_name("aead_rekey_oneshot.py")
SPEC = importlib.util.spec_from_file_location("aead_rekey_oneshot", MODULE_PATH)
assert SPEC and SPEC.loader
HARNESS = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(HARNESS)

SENTINEL_EXTERNAL_ID = "11111111-1111-4111-8111-111111111111"
TRIGGER_EXTERNAL_ID = "22222222-2222-4222-8222-222222222222"
SENTINEL_INTERNAL_ID = "33333333-3333-4333-8333-333333333333"
TRIGGER_INTERNAL_ID = "44444444-4444-4444-8444-444444444444"
POST_COMMIT_EXTERNAL_ID = "55555555-5555-4555-8555-555555555555"
POST_COMMIT_INTERNAL_ID = "66666666-6666-4666-8666-666666666666"


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
        "source": "fixture",
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
                "external_request_id": SENTINEL_EXTERNAL_ID,
                "accepted_request_id": SENTINEL_EXTERNAL_ID,
                "started_at": ts(1),
                "admitted_at": ts(1),
                "ended_at": ts(4),
                "http_status": 200,
                "outcome": "ok",
                "response_excerpt": '{"choices":[{}]}',
            },
            {
                "request_index": 1,
                "role": "trigger",
                "external_request_id": TRIGGER_EXTERNAL_ID,
                "accepted_request_id": TRIGGER_EXTERNAL_ID,
                "started_at": ts(2),
                "ended_at": ts(7),
                "http_status": 200,
                "outcome": "ok",
                "response_excerpt": '{"choices":[{}]}',
            },
            {
                "request_index": 2,
                "role": "post_commit",
                "external_request_id": POST_COMMIT_EXTERNAL_ID,
                "accepted_request_id": POST_COMMIT_EXTERNAL_ID,
                "started_at": ts(6),
                "ended_at": ts(7),
                "http_status": 200,
                "outcome": "ok",
                "response_excerpt": '{"choices":[{}]}',
            },
        ],
        "request_log": [
            {
                "ts_utc": ts(1),
                "request_id": SENTINEL_INTERNAL_ID,
                "external_request_id": SENTINEL_EXTERNAL_ID,
                "provider_assigned_id": "assigned-one",
                "latency_ms": 3000,
                "queue_wait_ms": 0,
                "status": 200,
                "error_code": None,
                "retried": 0,
                "attempt_n": 0,
            },
            {
                "ts_utc": ts(2),
                "request_id": TRIGGER_INTERNAL_ID,
                "external_request_id": TRIGGER_EXTERNAL_ID,
                "provider_assigned_id": "assigned-one",
                "latency_ms": 5000,
                "queue_wait_ms": 2000,
                "status": 200,
                "error_code": None,
                "retried": 0,
                "attempt_n": 0,
            },
            {
                "ts_utc": ts(6),
                "request_id": POST_COMMIT_INTERNAL_ID,
                "external_request_id": POST_COMMIT_EXTERNAL_ID,
                "provider_assigned_id": "assigned-one",
                "latency_ms": 1000,
                "queue_wait_ms": 0,
                "status": 200,
                "error_code": None,
                "retried": 0,
                "attempt_n": 0,
            },
        ],
        "pool_samples": [
            {"observed_at": ts(1), "poolz": {"pool": [dict(provider)], "summary": {"ready": 1}}},
            {"observed_at": ts(2), "poolz": {"pool": [dict(provider)], "summary": {"ready": 1}}},
            {"observed_at": ts(7), "poolz": {"pool": [dict(provider)], "summary": {"ready": 1}}},
        ],
        "events": [
            {
                "time": ts(3),
                "event": "aead_rekey",
                "provider_id": "mp-dedicated",
                "assigned_id": "assigned-one",
                "request_id": f"req-{TRIGGER_INTERNAL_ID}",
                "kid": "old-kid",
                "reason": gate,
                "decision": "rotate_in_band",
            },
            {
                "time": ts(5),
                "event": "aead_rekey_committed",
                "provider_id": "mp-dedicated",
                "assigned_id": "assigned-one",
                "request_id": f"req-{TRIGGER_INTERNAL_ID}",
                "rekey_id": "rekey-one",
                "old_kid": "old-kid",
                "new_kid": "new-kid",
                "reason": gate,
                "decision": "continue_same_session",
            },
        ],
    }


def make_live(capture: dict) -> dict:
    capture["source"] = "live"
    capture["started_at"] = ts(0)
    capture["ended_at"] = ts(7)
    capture["bounds"] = {
        "max_requests": 20,
        "max_seconds": 60,
        "concurrency": 2,
        "max_tokens_per_request": 16,
        "sentinel_max_tokens": 128,
        "request_timeout_seconds": 30,
        "post_commit_successes": 1,
        "automatic_retries": 0,
    }
    capture["events"][0]["_observed_at"] = "2026-07-22T12:00:03.000001Z"
    capture["events"][1]["_observed_at"] = "2026-07-22T12:00:05.000001Z"
    capture["operator_approval_ref"] = "https://github.com/Augustas11/macprovider/issues/540#issuecomment-test"
    capture["approval_attempt_key"] = "a" * 64
    capture["approved_identity"] = {
        "coordinator_sha256": "b" * 64,
        "gateway_sha256": "c" * 64,
        "provider_cli_version": "v1.8.58",
        "provider_compatibility_set_id": "set-reviewed",
    }
    capture["coordinator_process"] = {
        "exact_flag_bindings": {"--config": "/runtime/base.yaml", "--config-overlay": "/runtime/overlay.yaml"},
        "required_log_bound": True,
        "executable": "/runtime/bin/coordinator",
        "executable_sha256": "b" * 64,
        "listen_ports": [18443, 18444],
        "pid": 101,
    }
    capture["gateway_process"] = {
        "exact_flag_bindings": {"--config": "/runtime/gateway.yaml"},
        "executable": "/runtime/bin/gateway",
        "executable_sha256": "c" * 64,
        "listen_ports": [19443],
        "pid": 102,
    }
    capture["config"] = {
        "base_sha256": "d" * 64,
        "overlay_sha256": "e" * 64,
        "listen_bind_address": "127.0.0.1",
        "require_encrypted_leg": True,
        "require_gateway_context": True,
        "routing_max_retries": 0,
        "buyer_port": 18443,
        "provider_port": 18444,
        "encrypted_leg_rekey_after_requests": 6 if capture["gate"] == "request_threshold" else 1000,
        "encrypted_leg_rekey_after_seconds": 3600 if capture["gate"] == "request_threshold" else 6,
    }
    capture["gateway_config"] = {
        "sha256": "f" * 64,
        "listen_bind_address": "127.0.0.1",
        "retry_503_enabled": False,
        "listen_port": 19443,
    }
    capture["runtime_failures"] = []
    return capture


def evaluate(capture: dict) -> dict:
    return HARNESS.evaluate_capture(capture, expected_source=capture.get("source", "fixture"))


class EvaluateCaptureTests(unittest.TestCase):
    def test_success_handoff_records_required_evidence(self) -> None:
        result = evaluate(passing_capture())
        self.assertEqual(result["verdict"], "PASS", result["reasons"])
        self.assertEqual(result["identity"]["assigned_id"], "assigned-one")
        self.assertEqual(result["rekey"]["old_kid"], "old-kid")
        self.assertEqual(result["rekey"]["new_kid"], "new-kid")
        self.assertEqual(result["metrics"]["rekey_window_overlapping_requests"], 2)
        self.assertEqual(result["metrics"]["successful_requests_completed_after_commit"], 1)
        self.assertTrue(result["metrics"]["sentinel_admitted_before_trigger"])
        self.assertEqual(result["metrics"]["pool_states_observed"], ["ready"])

    def test_age_handoff_uses_same_analyzer(self) -> None:
        result = evaluate(passing_capture("age_threshold"))
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
        result = evaluate(capture)
        self.assertEqual(result["verdict"], "FAIL")
        self.assertTrue(any("provider identity changed" in reason for reason in result["reasons"]))
        self.assertTrue(any("close/reconnect" in reason for reason in result["reasons"]))

    def test_providerless_close_log_is_fail_in_single_provider_pool(self) -> None:
        capture = passing_capture()
        capture["events"].append(
            {"time": ts(4), "message": "provider websocket closing"}
        )
        result = evaluate(capture)
        self.assertEqual(result["verdict"], "FAIL")
        self.assertTrue(any("close/reconnect" in reason for reason in result["reasons"]))

    def test_provider_cli_or_compatibility_identity_drift_is_fail(self) -> None:
        capture = passing_capture()
        final_provider = capture["pool_samples"][-1]["poolz"]["pool"][0]
        final_provider["binary_version"] = "v1.8.59"
        final_provider["safety_telemetry"] = {"compatibility_set_id": "set-other"}
        result = evaluate(capture)
        self.assertEqual(result["verdict"], "FAIL")
        self.assertTrue(any("provider identity changed" in reason for reason in result["reasons"]))

    def test_buyer_503_is_fail(self) -> None:
        capture = passing_capture()
        capture["requests"][0].update(
            http_status=503,
            outcome="http_error",
            response_excerpt='{"error":{"code":"no_provider_available"}}',
        )
        result = evaluate(capture)
        self.assertEqual(result["verdict"], "FAIL")
        self.assertIn("buyer observed HTTP 503", result["reasons"])
        self.assertIn("buyer observed no_provider_available", result["reasons"])

    def test_missing_kid_evidence_is_fail(self) -> None:
        capture = passing_capture()
        capture["events"][1]["new_kid"] = ""
        result = evaluate(capture)
        self.assertEqual(result["verdict"], "FAIL")
        self.assertTrue(any("missing old_kid" in reason for reason in result["reasons"]))

    def test_trigger_must_map_to_rekey_request_id(self) -> None:
        capture = passing_capture()
        capture["request_log"][1]["request_id"] = "different-internal-request"
        result = evaluate(capture)
        self.assertEqual(result["verdict"], "FAIL")
        self.assertTrue(any("harness trigger" in reason for reason in result["reasons"]))

    def test_attempt_005_subsecond_timestamps_and_wire_request_id_pass(self) -> None:
        capture = passing_capture()
        capture["requests"][0].update(
            started_at="2026-08-11T14:38:17.294059Z",
            admitted_at="2026-08-11T14:38:17.349916Z",
            ended_at="2026-08-11T14:38:21.788063Z",
        )
        capture["requests"][1].update(
            started_at="2026-08-11T14:38:17.351656Z",
            ended_at="2026-08-11T14:38:22.395662Z",
        )
        capture["requests"][2].update(
            started_at="2026-08-11T14:38:21.800000Z",
            ended_at="2026-08-11T14:38:22.500000Z",
        )
        capture["request_log"][0].update(
            ts_utc="2026-08-11T14:38:17.311515252Z",
            latency_ms=4417,
        )
        capture["request_log"][1].update(
            ts_utc="2026-08-11T14:38:17.368350123Z",
            latency_ms=4983,
        )
        capture["request_log"][2].update(
            ts_utc="2026-08-11T14:38:21.810000000Z",
            latency_ms=600,
        )
        capture["events"][0].update(
            time="2026-08-11T14:38:17Z",
            _observed_at="2026-08-11T14:38:17.382273Z",
        )
        capture["events"][1].update(
            time="2026-08-11T14:38:21Z",
            _observed_at="2026-08-11T14:38:21.773150Z",
        )

        result = evaluate(capture)

        self.assertEqual(result["verdict"], "PASS", result["reasons"])
        self.assertTrue(result["assertions"]["trigger_bound_to_rekey"])
        self.assertTrue(result["assertions"]["admitted_old_epoch_survived"])

    def test_settlement_request_id_correlates_without_relay_prefix(self) -> None:
        capture = passing_capture()
        capture["events"][0]["request_id"] = TRIGGER_INTERNAL_ID
        capture["events"][1]["request_id"] = TRIGGER_INTERNAL_ID

        result = evaluate(capture)

        self.assertEqual(result["verdict"], "PASS", result["reasons"])
        self.assertTrue(result["assertions"]["trigger_bound_to_rekey"])

    def test_trigger_event_mapping_must_be_unique(self) -> None:
        capture = passing_capture()
        capture["request_log"][0]["request_id"] = TRIGGER_INTERNAL_ID
        result = evaluate(capture)
        self.assertEqual(result["verdict"], "FAIL")
        self.assertTrue(any("not unique" in reason for reason in result["reasons"]))
        self.assertTrue(any("map uniquely" in reason for reason in result["reasons"]))

    def test_double_relay_prefix_does_not_correlate(self) -> None:
        capture = passing_capture()
        capture["events"][0]["request_id"] = f"req-req-{TRIGGER_INTERNAL_ID}"
        capture["events"][1]["request_id"] = f"req-req-{TRIGGER_INTERNAL_ID}"
        result = evaluate(capture)
        self.assertEqual(result["verdict"], "FAIL")
        self.assertTrue(any("map uniquely" in reason for reason in result["reasons"]))

    def test_non_string_internal_request_id_does_not_correlate(self) -> None:
        capture = passing_capture()
        capture["request_log"][1]["request_id"] = [TRIGGER_INTERNAL_ID]
        result = evaluate(capture)
        self.assertEqual(result["verdict"], "FAIL")
        self.assertTrue(any("noncanonical internal" in reason for reason in result["reasons"]))

    def test_live_capture_requires_precise_event_observation_times(self) -> None:
        capture = make_live(passing_capture())
        capture["events"][0]["_observed_at"] = "malformed"
        result = evaluate(capture)
        self.assertEqual(result["verdict"], "FAIL")
        self.assertTrue(any("timestamps" in reason for reason in result["reasons"]))

    def test_live_observation_times_require_subsecond_utc(self) -> None:
        for observed_at in ("2026-08-11T12:00:03Z", "2026-08-11T12:00:03.000000"):
            with self.subTest(observed_at=observed_at):
                capture = make_live(passing_capture())
                capture["events"][0]["_observed_at"] = observed_at
                result = evaluate(capture)
                self.assertEqual(result["verdict"], "FAIL")
                self.assertTrue(any("timestamps" in reason for reason in result["reasons"]))

    def test_non_finite_sentinel_latency_does_not_prove_overlap(self) -> None:
        capture = passing_capture()
        capture["request_log"][0]["latency_ms"] = "Infinity"
        result = evaluate(capture)
        self.assertEqual(result["verdict"], "FAIL")
        self.assertTrue(any("old-epoch" in reason for reason in result["reasons"]))

    def test_trigger_request_log_must_remain_outstanding_through_commit(self) -> None:
        capture = passing_capture()
        capture["request_log"][1]["latency_ms"] = 1000
        result = evaluate(capture)
        self.assertEqual(result["verdict"], "FAIL")
        self.assertTrue(any("trigger request_log interval" in reason for reason in result["reasons"]))

    def test_trigger_request_log_rejects_non_finite_latency(self) -> None:
        capture = passing_capture()
        capture["request_log"][1]["latency_ms"] = "NaN"
        result = evaluate(capture)
        self.assertEqual(result["verdict"], "FAIL")
        self.assertTrue(any("trigger request_log interval" in reason for reason in result["reasons"]))

    def test_request_timeout_bound_cannot_exceed_live_cap(self) -> None:
        capture = passing_capture()
        capture["bounds"] = {"max_seconds": 300, "request_timeout_seconds": 121}
        result = evaluate(capture)
        self.assertEqual(result["verdict"], "FAIL")
        self.assertTrue(any("request_log interval" in reason for reason in result["reasons"]))

    def test_live_capture_requires_complete_valid_bounds(self) -> None:
        mutations = (
            lambda capture: capture.pop("bounds"),
            lambda capture: capture["bounds"].pop("request_timeout_seconds"),
            lambda capture: capture["bounds"].update(post_commit_successes=0),
            lambda capture: capture["bounds"].update(post_commit_successes="invalid"),
        )
        for mutate in mutations:
            with self.subTest(mutation=mutate):
                capture = make_live(passing_capture())
                mutate(capture)
                result = evaluate(capture)
                self.assertEqual(result["verdict"], "FAIL")
                self.assertIn("capture bounds are missing or invalid", result["reasons"])

    def test_request_log_intervals_require_explicit_utc(self) -> None:
        for row_index in (0, 1):
            with self.subTest(row_index=row_index):
                capture = passing_capture()
                capture["request_log"][row_index]["ts_utc"] = "2026-07-22T12:00:01.000000"
                result = evaluate(capture)
                self.assertEqual(result["verdict"], "FAIL")
                expected = "old-epoch" if row_index == 0 else "trigger request_log interval"
                self.assertTrue(any(expected in reason for reason in result["reasons"]))

    def test_live_client_timestamps_require_explicit_utc(self) -> None:
        capture = make_live(passing_capture())
        capture["requests"][2]["ended_at"] = "2026-07-22T12:00:06.000000"
        result = evaluate(capture)
        self.assertEqual(result["verdict"], "FAIL")
        self.assertIn("live buyer request timestamps are missing or invalid", result["reasons"])

    def test_every_mapped_request_log_row_requires_explicit_utc(self) -> None:
        capture = make_live(passing_capture())
        capture["request_log"][2]["ts_utc"] = "2026-07-22T12:00:05.000000"
        result = evaluate(capture)
        self.assertEqual(result["verdict"], "FAIL")
        self.assertTrue(any("out-of-bounds timing" in reason for reason in result["reasons"]))

    def test_request_ids_must_be_canonical_uuid_v4(self) -> None:
        capture = passing_capture()
        capture["requests"][0]["external_request_id"] = "not-a-uuid"
        capture["requests"][0]["accepted_request_id"] = "not-a-uuid"
        capture["request_log"][0]["external_request_id"] = "not-a-uuid"
        result = evaluate(capture)
        self.assertEqual(result["verdict"], "FAIL")
        self.assertTrue(any("canonical UUIDv4" in reason for reason in result["reasons"]))

    def test_gateway_must_echo_the_external_request_id(self) -> None:
        capture = passing_capture()
        capture["requests"][0]["accepted_request_id"] = TRIGGER_EXTERNAL_ID
        result = evaluate(capture)
        self.assertEqual(result["verdict"], "FAIL")
        self.assertTrue(any("did not preserve" in reason for reason in result["reasons"]))

    def test_old_epoch_sentinel_must_remain_outstanding_at_rekey_start(self) -> None:
        capture = passing_capture()
        capture["request_log"][0]["ts_utc"] = ts(2)
        capture["request_log"][0]["latency_ms"] = 500
        result = evaluate(capture)
        self.assertEqual(result["verdict"], "FAIL")
        self.assertTrue(any("old-epoch" in reason for reason in result["reasons"]))

    def test_sentinel_client_interval_must_contain_rekey_start(self) -> None:
        capture = passing_capture()
        capture["requests"][0]["ended_at"] = ts(2)
        result = evaluate(capture)
        self.assertEqual(result["verdict"], "FAIL")
        self.assertTrue(any("old-epoch" in reason for reason in result["reasons"]))

    def test_only_dedicated_post_commit_requests_satisfy_bound(self) -> None:
        capture = passing_capture()
        capture["bounds"] = {"max_requests": 10, "post_commit_successes": 3}
        result = evaluate(capture)
        self.assertEqual(result["verdict"], "FAIL")
        self.assertTrue(any("successful buyer request" in reason for reason in result["reasons"]))

    def test_capture_enforces_declared_request_and_time_bounds(self) -> None:
        request_bound = make_live(passing_capture())
        request_bound["bounds"]["max_requests"] = 2
        request_bound["bounds"]["post_commit_successes"] = 1
        result = evaluate(request_bound)
        self.assertEqual(result["verdict"], "FAIL")
        self.assertTrue(any("request bound" in reason for reason in result["reasons"]))

        time_bound = make_live(passing_capture())
        time_bound["bounds"]["max_seconds"] = 5
        time_bound["bounds"]["request_timeout_seconds"] = 5
        result = evaluate(time_bound)
        self.assertEqual(result["verdict"], "FAIL")
        self.assertTrue(any("run bound" in reason for reason in result["reasons"]))

    def test_every_mapped_row_requires_finite_bounded_latency(self) -> None:
        capture = passing_capture()
        capture["request_log"][2]["latency_ms"] = "NaN"
        result = evaluate(capture)
        self.assertEqual(result["verdict"], "FAIL")
        self.assertTrue(any("out-of-bounds timing" in reason for reason in result["reasons"]))

    def test_every_buyer_interval_must_be_ordered(self) -> None:
        capture = passing_capture()
        capture["requests"][2]["started_at"] = ts(8)
        result = evaluate(capture)
        self.assertEqual(result["verdict"], "FAIL")
        self.assertTrue(any("out of order" in reason for reason in result["reasons"]))

    def test_identity_and_cryptographic_fields_must_be_strings(self) -> None:
        mutations = (
            lambda capture: capture["pool_samples"][0]["poolz"]["pool"][0].update(assigned_id=None),
            lambda capture: capture["events"][1].update(old_kid=123),
            lambda capture: capture["events"][1].update(new_kid=[]),
            lambda capture: capture["events"][1].update(rekey_id={}),
        )
        for mutate in mutations:
            with self.subTest(mutation=mutate):
                capture = passing_capture()
                mutate(capture)
                result = evaluate(capture)
                self.assertEqual(result["verdict"], "FAIL")

    def test_live_capture_connection_and_pool_timestamps_are_validated(self) -> None:
        mutations = (
            lambda capture: capture.update(started_at="malformed"),
            lambda capture: capture["pool_samples"][0].update(observed_at="malformed"),
            lambda capture: capture["pool_samples"][0]["poolz"]["pool"][0].update(connected_at=None),
        )
        for mutate in mutations:
            with self.subTest(mutation=mutate):
                capture = make_live(passing_capture())
                mutate(capture)
                result = evaluate(capture)
                self.assertEqual(result["verdict"], "FAIL")

    def test_live_evaluation_requires_source_and_authority_evidence(self) -> None:
        result = HARNESS.evaluate_capture(make_live(passing_capture()), expected_source="live")
        self.assertEqual(result["verdict"], "PASS", result["reasons"])

        capture = make_live(passing_capture())
        capture["source"] = "fixture"
        result = HARNESS.evaluate_capture(capture, expected_source="live")
        self.assertEqual(result["verdict"], "FAIL")
        self.assertTrue(any("trusted evaluation mode" in reason for reason in result["reasons"]))

        for field in ("approved_identity", "coordinator_process", "gateway_process", "config", "gateway_config"):
            with self.subTest(field=field):
                capture = make_live(passing_capture())
                capture.pop(field)
                result = HARNESS.evaluate_capture(capture, expected_source="live")
                self.assertEqual(result["verdict"], "FAIL")

    def test_providerless_rekey_failure_is_rejected(self) -> None:
        capture = passing_capture()
        capture["events"].append({"time": ts(4), "event": "aead_rekey_failed"})
        result = evaluate(capture)
        self.assertEqual(result["verdict"], "FAIL")
        self.assertTrue(any("aead_rekey_failed" in reason for reason in result["reasons"]))

    def test_post_commit_coordinator_row_must_start_after_commit(self) -> None:
        capture = passing_capture()
        capture["request_log"][2]["ts_utc"] = ts(4)
        capture["request_log"][2]["latency_ms"] = 3000
        result = evaluate(capture)
        self.assertEqual(result["verdict"], "FAIL")
        self.assertTrue(any("successful buyer request" in reason for reason in result["reasons"]))

    def test_live_buyer_and_request_log_intervals_stay_in_capture_window(self) -> None:
        capture = make_live(passing_capture())
        capture["requests"][2]["started_at"] = "2026-07-22T12:01:10.000000Z"
        capture["requests"][2]["ended_at"] = "2026-07-22T12:01:11.000000Z"
        capture["request_log"][2]["ts_utc"] = "2026-07-22T12:01:10.000000Z"
        result = evaluate(capture)
        self.assertEqual(result["verdict"], "FAIL")
        self.assertTrue(any("capture" in reason for reason in result["reasons"]))

    def test_pass_critical_scalars_require_exact_types(self) -> None:
        mutations = (
            lambda capture: capture["request_log"][2].update(latency_ms="1000"),
            lambda capture: capture["request_log"][2].update(retried="0"),
            lambda capture: capture["requests"][2].update(http_status=200.0),
            lambda capture: capture["health_final"].update(pool_degraded="0"),
            lambda capture: capture["health_initial"].update(version=123),
        )
        for mutate in mutations:
            with self.subTest(mutation=mutate):
                capture = passing_capture()
                mutate(capture)
                result = evaluate(capture)
                self.assertEqual(result["verdict"], "FAIL")

    def test_malformed_gate_and_health_counters_return_structured_fail(self) -> None:
        capture = passing_capture()
        capture["gate"] = []
        capture["health_final"]["pool_degraded"] = None
        result = evaluate(capture)
        self.assertEqual(result["verdict"], "FAIL")

    def test_sentinel_admission_must_precede_trigger(self) -> None:
        capture = passing_capture()
        capture["requests"][0]["admitted_at"] = ts(3)
        result = evaluate(capture)
        self.assertEqual(result["verdict"], "FAIL")
        self.assertTrue(any("admission" in reason for reason in result["reasons"]))

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
        result = evaluate(capture)
        self.assertEqual(result["verdict"], "FAIL")
        self.assertTrue(any("runtime failure" in reason for reason in result["reasons"]))

    def test_required_post_commit_success_count_is_enforced(self) -> None:
        capture = passing_capture()
        capture["bounds"] = {"post_commit_successes": 3}
        result = evaluate(capture)
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


class LiveDispatchTests(unittest.TestCase):
    def test_streaming_sentinel_signals_admission_and_uses_uuid_v4(self) -> None:
        state = HARNESS.LiveState()
        args = SimpleNamespace(
            buyer_url="http://127.0.0.1:19443/v1/chat/completions",
            max_requests=20,
            max_tokens=16,
            model="model-a",
            request_timeout_seconds=30,
            sentinel_max_tokens=128,
        )
        release_response = threading.Event()
        observed: dict[str, Any] = {}

        def fake_http_once(url, method, headers, body, timeout_seconds, on_first_body_bytes=None):
            observed["url"] = url
            observed["method"] = method
            observed["headers"] = headers
            observed["body"] = json.loads(body)
            observed["timeout_seconds"] = timeout_seconds
            if on_first_body_bytes is not None:
                on_first_body_bytes(
                    200,
                    {
                        "content-type": "text/event-stream; charset=utf-8",
                        "x-request-id": headers["X-Request-Id"],
                    },
                )
            release_response.wait(2)
            return (
                200,
                {
                    "content-type": "text/event-stream; charset=utf-8",
                    "x-request-id": headers["X-Request-Id"],
                },
                b'data: {"choices":[{"delta":{"content":"ok"}}]}\n\ndata: [DONE]\n\n',
            )

        original_http_once = HARNESS.http_once
        HARNESS.http_once = fake_http_once
        try:
            thread = threading.Thread(
                target=HARNESS.issue_buyer_once,
                args=("sentinel", args, "buyer-token", time.monotonic() + 5, state),
            )
            thread.start()
            self.assertTrue(state.sentinel_admitted_event.wait(1))
            self.assertTrue(thread.is_alive())
            release_response.set()
            thread.join(2)
        finally:
            release_response.set()
            HARNESS.http_once = original_http_once

        self.assertFalse(thread.is_alive())
        request_id = observed["headers"]["X-Request-Id"]
        self.assertEqual(uuid.UUID(request_id).version, 4)
        self.assertTrue(observed["body"]["stream"])
        self.assertEqual(len(state.requests), 1)
        self.assertIn("admitted_at", state.requests[0])
        self.assertEqual(state.requests[0]["outcome"], "ok")

    def test_streaming_sentinel_rejects_invalid_admission_headers(self) -> None:
        state = HARNESS.LiveState()
        args = SimpleNamespace(
            buyer_url="http://127.0.0.1:19443/v1/chat/completions",
            max_requests=20,
            max_tokens=16,
            model="model-a",
            request_timeout_seconds=30,
            sentinel_max_tokens=128,
        )

        def fake_http_once(url, method, headers, body, timeout_seconds, on_first_body_bytes=None):
            if on_first_body_bytes is not None:
                on_first_body_bytes(
                    200,
                    {
                        "content-type": "application/json",
                        "x-request-id": headers["X-Request-Id"],
                    },
                )
            return 200, {}, b"{}"

        original_http_once = HARNESS.http_once
        HARNESS.http_once = fake_http_once
        try:
            HARNESS.issue_buyer_once(
                "sentinel", args, "buyer-token", time.monotonic() + 5, state
            )
        finally:
            HARNESS.http_once = original_http_once

        self.assertFalse(state.sentinel_admitted_event.is_set())
        self.assertTrue(state.dispatch_stop.is_set())
        self.assertEqual(state.requests[0]["outcome"], "transport_error")
        self.assertIn("not text/event-stream", state.requests[0]["error"])

    def test_streaming_response_requires_choices_and_done(self) -> None:
        with self.assertRaisesRegex(HARNESS.HarnessError, "terminal"):
            HARNESS.validate_streaming_buyer_response(b'data: {"choices":[]}\n\n')

    def test_streaming_response_rejects_empty_choice_object(self) -> None:
        with self.assertRaisesRegex(HARNESS.HarnessError, "choices"):
            HARNESS.validate_streaming_buyer_response(
                b'data: {"choices":[{}]}\n\ndata: [DONE]\n\n'
            )

    def test_streaming_response_rejects_error_object(self) -> None:
        with self.assertRaisesRegex(HARNESS.HarnessError, "error object"):
            HARNESS.validate_streaming_buyer_response(
                b'data: {"error":{"code":"provider_failed"}}\n\ndata: [DONE]\n\n'
            )

    def test_streaming_response_rejects_invalid_utf8(self) -> None:
        with self.assertRaisesRegex(HARNESS.HarnessError, "UTF-8"):
            HARNESS.validate_streaming_buyer_response(b"data: \xff\n\ndata: [DONE]\n\n")


if __name__ == "__main__":
    unittest.main()
