import copy
import importlib.util
import json
import math
import os
import stat
import subprocess
import sys
import tempfile
import unittest
from datetime import datetime
from datetime import timedelta
from datetime import timezone
from pathlib import Path
from unittest import mock


SCRIPT = Path(__file__).resolve().parents[1] / "measure_gate_a5_opoi_false_positives.py"
SPEC = importlib.util.spec_from_file_location("gate_a5_counter", SCRIPT)
COUNTER = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(COUNTER)

START = datetime(2026, 9, 26, tzinfo=timezone.utc)
CAMPAIGN = {
    "campaign_id": "campaign-1646",
    "provider_id": "mp-test",
    "run_id": "run-a5",
}
TUPLE = {
    "hardware": "Mac14,13/M3 Ultra/192GB",
    "model": "qwen/qwen3.6-27b",
    "quantization": "bf16",
    "kv_mode": "paged-fp16",
    "runtime_revision": "metallib/kernel",
    "binary_version": "1.8.201",
}
ARTIFACT = {
    "packaged_artifact_sha256": "a" * 64,
    "runtime_bundle_sha256": "b" * 64,
}
EVALUATOR = {
    "evaluator_revision": "eval-v4",
    "challenge_bank_revision": "bank-v7",
}


def timestamp(seconds):
    value = START + timedelta(seconds=seconds)
    return value.isoformat().replace("+00:00", "Z")


def digest(text):
    return COUNTER.sha256(text.encode())


def source_capture(event, locator=None):
    payload = "payload:" + event["challenge_id"]
    response = "response:" + event["event_id"]
    return {
        "locator": locator or "capture://" + event["event_id"],
        "identity": {
            key: event[key]
            for key in (
                "event_id",
                "pair_id",
                "arm",
                "request_id",
                "workload_stratum",
            )
        },
        "challenge": {
            "challenge_id": event["challenge_id"],
            "challenge_issuance_id": event["challenge_issuance_id"],
            "payload": payload,
            "payload_sha256": digest(payload),
        },
        "response": {
            "transcript": response,
            "transcript_sha256": digest(response),
        },
        "evaluation": {
            **event["evaluator"],
            "output": "pass" if event["opoi_pass"] else "fail",
        },
        "runtime": copy.deepcopy(event["execution"]),
        "provenance": {
            "campaign": copy.deepcopy(event["campaign"]),
            "tuple": copy.deepcopy(event["tuple"]),
            "artifact": copy.deepcopy(event["artifact"]),
        },
        "observed_at": event["observed_at"],
    }


def build_fixture(count=60):
    frame = []
    for index in range(count + 20):
        challenge_id = f"challenge-{index:04d}"
        stratum = ("short", "long")[index % 2]
        frame.append(
            {
                "challenge_id": challenge_id,
                "workload_stratum": stratum,
                "challenge_payload_sha256": digest("payload:" + challenge_id),
            }
        )

    sampling = {
        "selection_method": "sha256_ranked_without_replacement",
        "selection_seed": "seed-1646",
        "frame_revision": "frame-v8",
        "frame_sha256": COUNTER.sha256(COUNTER.canonical_json(frame)),
        "candidate_frame": frame,
        "workload_strata": ["short", "long"],
        "challenge_design": "unique_without_replacement",
        "arm_order_method": "seeded_balanced_alternation",
    }
    scheduled_pairs = []
    pairs = []
    captures = []

    for index in range(count):
        stratum, ordinal, rank, entry = COUNTER.expected_selection(sampling, index)
        companion_challenge = f"comp-challenge-{index}"
        companion = {
            "request_id": f"comp-req-{index}",
            "event_id": f"comp-event-{index}",
            "row_index": 1,
            "challenge_id": companion_challenge,
            "challenge_payload_sha256": digest("payload:" + companion_challenge),
            "workload_stratum": stratum,
        }
        scheduled = {
            "pair_id": f"p{index:04d}",
            "selection_index": index,
            "selection_digest": rank,
            "challenge_id": entry["challenge_id"],
            "challenge_payload_sha256": entry["challenge_payload_sha256"],
            "challenge_issuance_id": f"issuance-{index:04d}",
            "workload_stratum": stratum,
            "scheduled_at": timestamp(index * 30 + 5),
            "arm_order": COUNTER.expected_arm_order(
                sampling["selection_seed"], stratum, ordinal
            ),
            "batch_request_id": f"batch-req-{index}",
            "batch_event_id": f"batch-event-{index}",
            "serial_request_id": f"serial-req-{index}",
            "serial_event_id": f"serial-event-{index}",
            "intended_batch_depth": 2,
            "companions": [companion],
        }
        scheduled_pairs.append(scheduled)

        focal_member = {
            "event_id": scheduled["batch_event_id"],
            "request_id": scheduled["batch_request_id"],
            "row_index": 0,
            "challenge_id": scheduled["challenge_id"],
            "challenge_payload_sha256": scheduled["challenge_payload_sha256"],
            "workload_stratum": stratum,
        }
        members = [focal_member, copy.deepcopy(companion)]
        batch_execution = {
            "mode": "continuous_batching",
            "forward_id": f"forward-{index}",
            "row_count": 2,
            "row_index": 0,
            "members": members,
        }
        base_event = {
            "campaign": copy.deepcopy(CAMPAIGN),
            "tuple": copy.deepcopy(TUPLE),
            "artifact": copy.deepcopy(ARTIFACT),
            "evaluator": copy.deepcopy(EVALUATOR),
            "pair_id": scheduled["pair_id"],
            "challenge_issuance_id": scheduled["challenge_issuance_id"],
            "workload_stratum": stratum,
            "opoi_pass": True,
        }
        if scheduled["arm_order"] == "batch_then_serial":
            batch_offset, serial_offset = 10, 20
        else:
            batch_offset, serial_offset = 20, 10

        batch = {
            **copy.deepcopy(base_event),
            "event_id": scheduled["batch_event_id"],
            "observed_at": timestamp(index * 30 + batch_offset),
            "arm": "batching",
            "challenge_id": scheduled["challenge_id"],
            "request_id": scheduled["batch_request_id"],
            "execution": copy.deepcopy(batch_execution),
        }
        companion_execution = copy.deepcopy(batch_execution)
        companion_execution["row_index"] = 1
        companion_event = {
            **copy.deepcopy(base_event),
            "event_id": companion["event_id"],
            "observed_at": batch["observed_at"],
            "arm": "batch_companion",
            "challenge_id": companion["challenge_id"],
            "request_id": companion["request_id"],
            "execution": companion_execution,
        }
        serial_member = {
            "event_id": scheduled["serial_event_id"],
            "request_id": scheduled["serial_request_id"],
            "row_index": 0,
            "challenge_id": scheduled["challenge_id"],
            "challenge_payload_sha256": scheduled["challenge_payload_sha256"],
            "workload_stratum": stratum,
        }
        serial = {
            **copy.deepcopy(base_event),
            "event_id": scheduled["serial_event_id"],
            "observed_at": timestamp(index * 30 + serial_offset),
            "arm": "serial_control",
            "challenge_id": scheduled["challenge_id"],
            "request_id": scheduled["serial_request_id"],
            "execution": {
                "mode": "serial",
                "forward_id": None,
                "row_count": 1,
                "row_index": 0,
                "members": [serial_member],
            },
        }

        batch_source = source_capture(batch)
        serial_source = source_capture(serial)
        companion_source = source_capture(companion_event)
        captures.extend([batch_source, serial_source, companion_source])
        pairs.append(
            {
                "pair_id": scheduled["pair_id"],
                "batching": COUNTER.derive_event(batch_source),
                "serial_control": COUNTER.derive_event(serial_source),
            }
        )

    plan = {
        "schema": COUNTER.PLAN_SCHEMA,
        "version": COUNTER.VERSION,
        "campaign": copy.deepcopy(CAMPAIGN),
        "tuple": copy.deepcopy(TUPLE),
        "artifact": copy.deepcopy(ARTIFACT),
        "evaluator": copy.deepcopy(EVALUATOR),
        "window": {"start": timestamp(0), "end": timestamp(3600)},
        "max_pair_gap_seconds": 60,
        "sampling_design": sampling,
        "scheduled_pairs": scheduled_pairs,
    }
    plan_digest = COUNTER.sha256(COUNTER.canonical_json(plan))
    raw_bundle = {
        "schema": COUNTER.RAW_SCHEMA,
        "version": COUNTER.VERSION,
        "captures": captures,
    }
    raw_bytes = COUNTER.canonical_json(raw_bundle)
    raw_digest = COUNTER.sha256(raw_bytes)
    document = {
        "schema": COUNTER.INPUT_SCHEMA,
        "version": COUNTER.VERSION,
        "plan": plan,
        "plan_sha256": plan_digest,
        "plan_receipt": {
            "schema": COUNTER.RECEIPT_SCHEMA,
            "version": COUNTER.VERSION,
            "plan_sha256": plan_digest,
            "received_at": timestamp(-60),
        },
        "raw_bundle_sha256": raw_digest,
        "source_review": {
            "schema": COUNTER.SOURCE_REVIEW_SCHEMA,
            "version": COUNTER.VERSION,
            "plan_sha256": plan_digest,
            "raw_bundle_sha256": raw_digest,
            "reviewer_identity": "reviewer-principal",
            "reviewer_role": "independent_source_reviewer",
            "reviewed_at": timestamp(3600),
            "disposition": "approved",
        },
        "pairs": pairs,
    }
    return document, raw_bundle, raw_bytes


BASE_DOCUMENT, BASE_RAW_BUNDLE, BASE_RAW_BYTES = build_fixture()


def fixture():
    return copy.deepcopy(BASE_DOCUMENT), copy.deepcopy(BASE_RAW_BUNDLE), BASE_RAW_BYTES


def find_capture(raw_bundle, event_id):
    return next(
        capture
        for capture in raw_bundle["captures"]
        if capture["identity"]["event_id"] == event_id
    )


def refresh_raw_digest(document, raw_bundle):
    raw_bytes = COUNTER.canonical_json(raw_bundle)
    raw_digest = COUNTER.sha256(raw_bytes)
    document["raw_bundle_sha256"] = raw_digest
    document["source_review"]["raw_bundle_sha256"] = raw_digest
    return raw_bytes


def refresh_plan_bindings(document):
    plan_digest = COUNTER.sha256(COUNTER.canonical_json(document["plan"]))
    document["plan_sha256"] = plan_digest
    document["plan_receipt"]["plan_sha256"] = plan_digest
    document["source_review"]["plan_sha256"] = plan_digest


def measured(document, raw_bundle, raw_bytes=None):
    if raw_bytes is None:
        raw_bytes = refresh_raw_digest(document, raw_bundle)
    return COUNTER.measure(
        document,
        raw_bundle,
        COUNTER.sha256(raw_bytes),
        {"verified": True},
    )


def set_outcome(document, raw_bundle, index, arm, passed):
    scheduled = document["plan"]["scheduled_pairs"][index]
    if arm == "batch":
        pair_key = "batching"
        event_id = scheduled["batch_event_id"]
    else:
        pair_key = "serial_control"
        event_id = scheduled["serial_event_id"]
    capture = find_capture(raw_bundle, event_id)
    capture["evaluation"]["output"] = "pass" if passed else "fail"
    document["pairs"][index][pair_key] = COUNTER.derive_event(capture)


def generate_keys(root, same_key=False):
    result = {}
    shared_key = None
    for role in ("plan", "reviewer", "evidence"):
        key = shared_key if same_key and shared_key else root / f"{role}-key"
        if not key.exists():
            subprocess.run(
                [COUNTER.SSH_KEYGEN, "-q", "-t", "ed25519", "-N", "", "-f", str(key)],
                check=True,
            )
        if same_key:
            shared_key = key
        principal = f"{role}-principal"
        trust = root / f"{role}-trust"
        public_parts = key.with_suffix(".pub").read_text().split()
        trust.write_text(
            principal + " " + " ".join(public_parts[:2]) + "\n",
            encoding="utf-8",
        )
        result[role] = (key, trust, principal)
    return result


def sign_document(root, document, keyset):
    paths = {}
    principals = {role: keyset[role][2] for role in keyset}
    payloads = {
        "plan": (document["plan"], COUNTER.PLAN_NAMESPACE, "plan"),
        "receipt": (document["plan_receipt"], COUNTER.RECEIPT_NAMESPACE, "reviewer"),
        "source_review": (
            document["source_review"],
            COUNTER.SOURCE_REVIEW_NAMESPACE,
            "reviewer",
        ),
        "evidence": (document, COUNTER.EVIDENCE_NAMESPACE, "evidence"),
    }
    for role, (payload, namespace, key_role) in payloads.items():
        payload_path = root / f"{role}-payload"
        payload_path.write_bytes(COUNTER.canonical_json(payload))
        subprocess.run(
            [
                COUNTER.SSH_KEYGEN,
                "-Y",
                "sign",
                "-f",
                str(keyset[key_role][0]),
                "-n",
                namespace,
                str(payload_path),
            ],
            check=True,
            stdout=subprocess.DEVNULL,
            stderr=subprocess.DEVNULL,
        )
        paths[role + "_signature"] = str(payload_path) + ".sig"
    for role in keyset:
        paths[role + "_trust"] = str(keyset[role][1])
    return paths, principals


def cli_arguments(document_path, raw_path, output_path, paths, principals):
    return [
        str(document_path),
        "--raw-bundle", str(raw_path),
        "--output", str(output_path),
        "--plan-signature", paths["plan_signature"],
        "--receipt-signature", paths["receipt_signature"],
        "--source-review-signature", paths["source_review_signature"],
        "--evidence-signature", paths["evidence_signature"],
        "--plan-trust", paths["plan_trust"],
        "--reviewer-trust", paths["reviewer_trust"],
        "--evidence-trust", paths["evidence_trust"],
        "--plan-principal", principals["plan"],
        "--reviewer-principal", principals["reviewer"],
        "--evidence-principal", principals["evidence"],
    ]


class GateA5CounterTests(unittest.TestCase):
    def assert_measure_fails(self, document, raw_bundle, raw_bytes=None):
        report = measured(document, raw_bundle, raw_bytes)
        self.assertFalse(report["passed"], report)
        return report

    def assert_evidence_preflight_fails(self, document, raw_bundle):
        raw_bytes = refresh_raw_digest(document, raw_bundle)
        with self.assertRaisesRegex(COUNTER.InputError, "evidence_preflight_failed"):
            COUNTER.preparation_payload(
                document,
                "evidence",
                raw_bundle,
                COUNTER.sha256(raw_bytes),
            )

    def test_valid_pass_and_per_stratum_arm_balance(self):
        document, raw_bundle, raw_bytes = fixture()
        report = measured(document, raw_bundle, raw_bytes)

        self.assertTrue(report["passed"], report["gate_reasons"])
        self.assertEqual(report["focal_row_zero_eligible_denominator"], 60)
        for stratum in ("short", "long"):
            orders = [
                pair["arm_order"]
                for pair in document["plan"]["scheduled_pairs"]
                if pair["workload_stratum"] == stratum
            ]
            self.assertEqual(set(orders), {"batch_then_serial", "serial_then_batch"})
            self.assertLessEqual(
                abs(orders.count("batch_then_serial") - orders.count("serial_then_batch")),
                1,
            )

    def test_reversed_observed_arm_order_fails(self):
        document, raw_bundle, _raw_bytes = fixture()
        scheduled = document["plan"]["scheduled_pairs"][0]
        batch = find_capture(raw_bundle, scheduled["batch_event_id"])
        serial = find_capture(raw_bundle, scheduled["serial_event_id"])
        batch["observed_at"], serial["observed_at"] = (
            serial["observed_at"],
            batch["observed_at"],
        )
        document["pairs"][0]["batching"] = COUNTER.derive_event(batch)
        document["pairs"][0]["serial_control"] = COUNTER.derive_event(serial)

        report = self.assert_measure_fails(document, raw_bundle)
        self.assertIn("invalid_pairs_present", report["gate_reasons"])

    def test_equal_observed_arm_times_fail(self):
        document, raw_bundle, _raw_bytes = fixture()
        scheduled = document["plan"]["scheduled_pairs"][0]
        batch = find_capture(raw_bundle, scheduled["batch_event_id"])
        serial = find_capture(raw_bundle, scheduled["serial_event_id"])
        serial["observed_at"] = batch["observed_at"]
        document["pairs"][0]["serial_control"] = COUNTER.derive_event(serial)

        self.assert_measure_fails(document, raw_bundle)

    def test_exact_five_percent_rate_fails(self):
        document, raw_bundle, _raw_bytes = fixture()
        for index in range(3):
            set_outcome(document, raw_bundle, index, "batch", False)

        report = self.assert_measure_fails(document, raw_bundle)
        self.assertEqual(report["focal_row_zero_false_positive_rate"], 0.05)
        self.assertIn("threshold_not_met", report["gate_reasons"])

    def test_below_five_percent_with_insufficient_confidence_fails(self):
        document, raw_bundle, _raw_bytes = fixture()
        set_outcome(document, raw_bundle, 0, "batch", False)

        report = self.assert_measure_fails(document, raw_bundle)
        self.assertLess(report["focal_row_zero_false_positive_rate"], 0.05)
        self.assertIn("confidence_bound_not_met", report["gate_reasons"])

    def test_known_clopper_pearson_confidence_math(self):
        upper = COUNTER.clopper_pearson_upper(3, 100)

        self.assertTrue(
            math.isclose(
                COUNTER.binomial_cdf(3, 100, upper),
                1.0 - COUNTER.CONFIDENCE_LEVEL,
                rel_tol=1e-10,
            )
        )
        self.assertGreater(upper, 0.03)

    def test_4096_sample_confidence_math(self):
        expected = 1.0 - (1.0 - COUNTER.CONFIDENCE_LEVEL) ** (1.0 / 4096)

        self.assertTrue(
            math.isclose(
                COUNTER.clopper_pearson_upper(0, 4096),
                expected,
                rel_tol=1e-12,
            )
        )

    def test_focal_numerator_is_derived_from_paired_outcomes(self):
        document, raw_bundle, _raw_bytes = fixture()
        set_outcome(document, raw_bundle, 0, "batch", False)

        report = measured(document, raw_bundle)
        self.assertEqual(report["focal_row_zero_false_positive_numerator"], 1)
        self.assertEqual(report["focal_row_zero_eligible_denominator"], 60)

    def test_serial_failure_is_inconclusive_and_fails_closed(self):
        document, raw_bundle, _raw_bytes = fixture()
        set_outcome(document, raw_bundle, 0, "batch", False)
        set_outcome(document, raw_bundle, 0, "serial", False)

        report = self.assert_measure_fails(document, raw_bundle)
        self.assertEqual(report["inconclusive_count"], 1)
        self.assertEqual(report["focal_row_zero_false_positive_numerator"], 0)
        self.assertEqual(report["focal_row_zero_eligible_denominator"], 59)

    def test_companion_outcomes_are_excluded_only_from_focal_metric(self):
        document, raw_bundle, _raw_bytes = fixture()
        companion = find_capture(raw_bundle, "comp-event-0")
        companion["evaluation"]["output"] = "fail"

        report = measured(document, raw_bundle)
        self.assertTrue(report["passed"], report["gate_reasons"])
        self.assertEqual(report["focal_row_zero_false_positive_numerator"], 0)
        self.assertEqual(report["focal_row_zero_eligible_denominator"], 60)

    def test_closed_schemas_reject_unknown_fields(self):
        document, raw_bundle, _raw_bytes = fixture()
        document["unexpected"] = "field"
        find_capture(raw_bundle, "batch-event-0")["unexpected"] = "field"

        self.assert_measure_fails(document, raw_bundle)

    def test_duplicate_json_keys_are_rejected(self):
        with self.assertRaisesRegex(COUNTER.InputError, "duplicate_json_key"):
            COUNTER.loads_bounded(b'{"version":4,"version":4}')

    def test_boolean_versions_are_rejected(self):
        document, raw_bundle, _raw_bytes = fixture()
        document["version"] = True
        raw_bundle["version"] = True

        self.assert_measure_fails(document, raw_bundle)

    def test_utc_window_and_gap_constraints_fail_closed(self):
        mutations = (
            lambda plan: plan["window"].update({"end": plan["window"]["start"]}),
            lambda plan: plan["window"].update({"end": timestamp(3601)}),
            lambda plan: plan.update({"max_pair_gap_seconds": 61}),
        )
        for mutation in mutations:
            with self.subTest(mutation=mutation):
                document, raw_bundle, raw_bytes = fixture()
                mutation(document["plan"])
                self.assert_measure_fails(document, raw_bundle, raw_bytes)

    def test_hostile_utc_types_and_overflow_are_rejected(self):
        hostile_values = (None, True, 7, [], "999999999999-01-01T00:00:00Z")
        for value in hostile_values:
            with self.subTest(value=value):
                with self.assertRaises(COUNTER.InputError):
                    COUNTER.parse_utc(value)

    def test_json_and_jsonl_load_to_the_same_document(self):
        document, _raw_bundle, _raw_bytes = fixture()
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            json_path = root / "evidence.json"
            jsonl_path = root / "evidence.jsonl"
            json_path.write_bytes(COUNTER.canonical_json(document))
            header = {key: value for key, value in document.items() if key != "pairs"}
            rows = [COUNTER.canonical_json(header)]
            rows.extend(COUNTER.canonical_json(pair) for pair in document["pairs"])
            jsonl_path.write_bytes(b"\n".join(rows) + b"\n")

            self.assertEqual(
                COUNTER.load_document(json_path),
                COUNTER.load_document(jsonl_path),
            )

    def test_report_generation_is_deterministic(self):
        document, raw_bundle, raw_bytes = fixture()

        first = measured(document, raw_bundle, raw_bytes)
        second = measured(document, raw_bundle, raw_bytes)
        self.assertEqual(COUNTER.canonical_json(first), COUNTER.canonical_json(second))

    def test_create_only_atomic_output_refuses_overwrite(self):
        with tempfile.TemporaryDirectory() as directory:
            output = Path(directory) / "report.json"
            COUNTER.write_new(output, b"one")

            self.assertEqual(output.read_bytes(), b"one")
            self.assertEqual(stat.S_IMODE(output.stat().st_mode), 0o600)
            with self.assertRaisesRegex(COUNTER.InputError, "output_already_exists"):
                COUNTER.write_new(output, b"two")
            self.assertEqual(list(output.parent.glob(".report.json.*")), [])

    def test_readfile_loops_and_closes_the_descriptor(self):
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "input"
            expected = b"abcdefghijklmnopqrstuvwxyz"
            path.write_bytes(expected)
            original_read = COUNTER.os.read
            original_close = COUNTER.os.close
            closed = []

            def short_read(descriptor, size):
                return original_read(descriptor, min(size, 3))

            def tracked_close(descriptor):
                closed.append(descriptor)
                return original_close(descriptor)

            with mock.patch.object(COUNTER.os, "read", side_effect=short_read):
                with mock.patch.object(COUNTER.os, "close", side_effect=tracked_close):
                    actual = COUNTER.readfile(path, len(expected))

            self.assertEqual(actual, expected)
            self.assertEqual(len(closed), 1)

    def test_plan_digest_mismatch_is_rejected(self):
        document, raw_bundle, raw_bytes = fixture()
        document["plan_sha256"] = "f" * 64

        report = self.assert_measure_fails(document, raw_bundle, raw_bytes)
        self.assertIn("plan_digest_mismatch", report["gate_reasons"])

    def test_receipt_backdating_boundary_is_rejected(self):
        document, raw_bundle, raw_bytes = fixture()
        document["plan_receipt"]["received_at"] = timestamp(0)

        report = self.assert_measure_fails(document, raw_bundle, raw_bytes)
        self.assertIn("plan_receipt_not_pre_window", report["gate_reasons"])

    def test_receipt_plan_mismatch_is_rejected(self):
        document, raw_bundle, raw_bytes = fixture()
        document["plan_receipt"]["plan_sha256"] = "f" * 64

        report = self.assert_measure_fails(document, raw_bundle, raw_bytes)
        self.assertIn("plan_receipt_mismatch", report["gate_reasons"])

    def test_raw_file_digest_mismatch_is_rejected(self):
        document, raw_bundle, raw_bytes = fixture()
        document["raw_bundle_sha256"] = "f" * 64

        report = self.assert_measure_fails(document, raw_bundle, raw_bytes)
        self.assertIn("raw_bundle_file_digest_mismatch", report["gate_reasons"])

    def test_source_challenge_and_response_tamper_are_rejected(self):
        for section, field in (("challenge", "payload"), ("response", "transcript")):
            with self.subTest(section=section):
                document, raw_bundle, _raw_bytes = fixture()
                find_capture(raw_bundle, "batch-event-0")[section][field] = "tampered"
                self.assert_measure_fails(document, raw_bundle)

    def test_source_evaluator_output_is_closed_and_derived(self):
        document, raw_bundle, _raw_bytes = fixture()
        capture = find_capture(raw_bundle, "batch-event-0")
        capture["evaluation"]["output"] = "ambiguous"

        self.assert_measure_fails(document, raw_bundle)

    def test_source_evaluator_revision_tamper_is_rejected(self):
        document, raw_bundle, _raw_bytes = fixture()
        capture = find_capture(raw_bundle, "batch-event-0")
        capture["evaluation"]["evaluator_revision"] = "other-evaluator"

        self.assert_measure_fails(document, raw_bundle)

    def test_contradictory_evaluator_boolean_cannot_be_accepted(self):
        document, raw_bundle, _raw_bytes = fixture()
        capture = find_capture(raw_bundle, "batch-event-0")
        capture["evaluation"]["output"] = "pass"
        capture["evaluation"]["opoi_pass"] = False

        self.assert_measure_fails(document, raw_bundle)

    def test_normalized_outcome_is_derived_from_source_output(self):
        document, raw_bundle, _raw_bytes = fixture()
        capture = find_capture(raw_bundle, "batch-event-0")
        capture["evaluation"]["output"] = "fail"
        document["pairs"][0]["batching"] = COUNTER.derive_event(capture)

        report = measured(document, raw_bundle)
        self.assertEqual(report["focal_row_zero_false_positive_numerator"], 1)

    def test_source_runtime_and_provenance_tamper_are_rejected(self):
        mutations = (
            lambda capture: capture["runtime"].update({"mode": "serial"}),
            lambda capture: capture["provenance"]["campaign"].update(
                {"run_id": "other-run"}
            ),
            lambda capture: capture["provenance"]["artifact"].update(
                {"runtime_bundle_sha256": "f" * 64}
            ),
        )
        for mutation in mutations:
            with self.subTest(mutation=mutation):
                document, raw_bundle, _raw_bytes = fixture()
                mutation(find_capture(raw_bundle, "batch-event-0"))
                self.assert_measure_fails(document, raw_bundle)

    def test_completed_event_divergence_from_source_is_rejected(self):
        document, raw_bundle, _raw_bytes = fixture()
        document["pairs"][0]["batching"]["opoi_pass"] = False

        self.assert_measure_fails(document, raw_bundle)

    def test_source_locator_duplicate_is_rejected(self):
        document, raw_bundle, _raw_bytes = fixture()
        raw_bundle["captures"][1]["locator"] = raw_bundle["captures"][0]["locator"]

        self.assert_measure_fails(document, raw_bundle)

    def test_source_missing_extra_and_event_replay_are_rejected(self):
        for kind in ("missing", "extra", "replay"):
            with self.subTest(kind=kind):
                document, raw_bundle, _raw_bytes = fixture()
                if kind == "missing":
                    raw_bundle["captures"].pop()
                elif kind == "extra":
                    extra = copy.deepcopy(raw_bundle["captures"][0])
                    extra["locator"] = "capture://extra"
                    extra["identity"]["event_id"] = "extra-event"
                    raw_bundle["captures"].append(extra)
                else:
                    raw_bundle["captures"][1]["identity"]["event_id"] = (
                        raw_bundle["captures"][0]["identity"]["event_id"]
                    )
                self.assert_measure_fails(document, raw_bundle)

    def test_source_review_digest_and_plan_mismatch_are_rejected(self):
        for field in ("raw_bundle_sha256", "plan_sha256"):
            with self.subTest(field=field):
                document, raw_bundle, raw_bytes = fixture()
                document["source_review"][field] = "f" * 64
                self.assert_measure_fails(document, raw_bundle, raw_bytes)

    def test_source_review_identity_role_disposition_and_time_are_rejected(self):
        mutations = (
            ("reviewer_identity", ""),
            ("reviewer_role", "operator"),
            ("disposition", "rejected"),
            ("reviewed_at", timestamp(3599)),
        )
        for field, value in mutations:
            with self.subTest(field=field):
                document, raw_bundle, raw_bytes = fixture()
                document["source_review"][field] = value
                self.assert_measure_fails(document, raw_bundle, raw_bytes)

    def test_source_review_signer_identity_mismatch_is_rejected(self):
        document, _raw_bundle, _raw_bytes = fixture()
        principals = {
            "plan": "plan-principal",
            "reviewer": "other-reviewer",
            "evidence": "evidence-principal",
        }

        with self.assertRaisesRegex(
            COUNTER.InputError,
            "source_review_identity_mismatch",
        ):
            COUNTER.verify_authenticity(document, {}, principals)

    def test_frame_cherry_pick_fails_with_recomputed_legacy_digest(self):
        document, raw_bundle, raw_bytes = fixture()
        sampling = document["plan"]["sampling_design"]
        scheduled = document["plan"]["scheduled_pairs"][0]
        replacement = sampling["candidate_frame"][-1]
        scheduled["challenge_id"] = replacement["challenge_id"]
        scheduled["challenge_payload_sha256"] = replacement["challenge_payload_sha256"]
        scheduled["selection_digest"] = COUNTER.sha256(
            "|".join(
                (
                    sampling["selection_seed"],
                    sampling["frame_revision"],
                    scheduled["workload_stratum"],
                    scheduled["challenge_id"],
                    str(scheduled["selection_index"]),
                )
            ).encode()
        )
        refresh_plan_bindings(document)

        self.assert_measure_fails(document, raw_bundle, raw_bytes)

    def test_frame_tamper_seed_mismatch_and_duplicate_entries_fail(self):
        mutations = (
            lambda sampling: sampling["candidate_frame"][0].update(
                {"challenge_id": "tampered"}
            ),
            lambda sampling: sampling.update({"selection_seed": "shopped"}),
            lambda sampling: sampling["candidate_frame"].append(
                copy.deepcopy(sampling["candidate_frame"][0])
            ),
        )
        for mutation in mutations:
            with self.subTest(mutation=mutation):
                document, raw_bundle, raw_bytes = fixture()
                mutation(document["plan"]["sampling_design"])
                refresh_plan_bindings(document)
                self.assert_measure_fails(document, raw_bundle, raw_bytes)

    def test_per_stratum_order_confound_is_rejected(self):
        document, raw_bundle, raw_bytes = fixture()
        scheduled = document["plan"]["scheduled_pairs"]
        same_stratum = [
            pair
            for pair in scheduled
            if pair["workload_stratum"] == scheduled[0]["workload_stratum"]
        ]
        same_stratum[1]["arm_order"] = same_stratum[0]["arm_order"]
        refresh_plan_bindings(document)

        self.assert_measure_fails(document, raw_bundle, raw_bytes)

    def test_companion_missing_extra_replay_and_cross_pair_fail(self):
        for kind in ("missing", "extra", "replay", "cross_pair"):
            with self.subTest(kind=kind):
                document, raw_bundle, _raw_bytes = fixture()
                if kind == "missing":
                    raw_bundle["captures"] = [
                        capture
                        for capture in raw_bundle["captures"]
                        if capture["identity"]["event_id"] != "comp-event-0"
                    ]
                elif kind == "extra":
                    extra = copy.deepcopy(find_capture(raw_bundle, "comp-event-0"))
                    extra["locator"] = "capture://extra-companion"
                    extra["identity"]["event_id"] = "extra-companion"
                    raw_bundle["captures"].append(extra)
                elif kind == "replay":
                    find_capture(raw_bundle, "comp-event-1")["identity"][
                        "event_id"
                    ] = "comp-event-0"
                else:
                    find_capture(raw_bundle, "comp-event-0")["identity"][
                        "pair_id"
                    ] = "p0001"
                self.assert_measure_fails(document, raw_bundle)

    def test_companion_transplant_and_full_binding_tamper_fail(self):
        mutations = (
            lambda capture: capture["challenge"].update(
                {
                    "challenge_id": "comp-challenge-1",
                    "payload": "payload:comp-challenge-1",
                    "payload_sha256": digest("payload:comp-challenge-1"),
                }
            ),
            lambda capture: capture["provenance"]["tuple"].update(
                {"model": "other/model"}
            ),
            lambda capture: capture["evaluation"].update(
                {"evaluator_revision": "other-evaluator"}
            ),
        )
        for mutation in mutations:
            with self.subTest(mutation=mutation):
                document, raw_bundle, _raw_bytes = fixture()
                mutation(find_capture(raw_bundle, "comp-event-0"))
                self.assert_measure_fails(document, raw_bundle)

    def test_companion_own_row_and_membership_tamper_fail(self):
        for kind in ("own_row", "membership"):
            with self.subTest(kind=kind):
                document, raw_bundle, _raw_bytes = fixture()
                companion = find_capture(raw_bundle, "comp-event-0")
                if kind == "own_row":
                    companion["runtime"]["row_index"] = 0
                else:
                    companion["runtime"]["members"].reverse()
                self.assert_measure_fails(document, raw_bundle)

    def test_unexpected_raw_identity_and_repeated_forward_fail(self):
        document, raw_bundle, _raw_bytes = fixture()
        find_capture(raw_bundle, "batch-event-0")["identity"]["event_id"] = "unexpected"
        self.assert_measure_fails(document, raw_bundle)

        document, raw_bundle, _raw_bytes = fixture()
        repeated_forward = find_capture(raw_bundle, "batch-event-0")["runtime"][
            "forward_id"
        ]
        for event_id in ("batch-event-1", "comp-event-1"):
            find_capture(raw_bundle, event_id)["runtime"]["forward_id"] = repeated_forward
        document["pairs"][1]["batching"] = COUNTER.derive_event(
            find_capture(raw_bundle, "batch-event-1")
        )
        self.assert_measure_fails(document, raw_bundle)

    def test_malformed_sampling_schedules_and_pairs_fail_closed(self):
        mutations = (
            lambda document: document["plan"].update({"sampling_design": []}),
            lambda document: document["plan"].update({"scheduled_pairs": {}}),
            lambda document: document.update({"pairs": {}}),
        )
        for mutation in mutations:
            with self.subTest(mutation=mutation):
                document, raw_bundle, raw_bytes = fixture()
                mutation(document)
                self.assert_measure_fails(document, raw_bundle, raw_bytes)

    def test_malformed_captures_executions_and_members_fail_closed(self):
        mutations = (
            lambda capture: capture.update({"evaluation": []}),
            lambda capture: capture.update({"runtime": []}),
            lambda capture: capture["runtime"].update({"members": [None]}),
        )
        for mutation in mutations:
            with self.subTest(mutation=mutation):
                document, raw_bundle, _raw_bytes = fixture()
                mutation(find_capture(raw_bundle, "batch-event-0"))
                self.assert_measure_fails(document, raw_bundle)

    def test_surrogate_source_text_fails_closed_without_crash(self):
        _document, raw_bundle, _raw_bytes = fixture()
        capture = find_capture(raw_bundle, "batch-event-0")
        capture["challenge"]["payload"] = "\ud800"

        self.assertFalse(COUNTER.validate_source_capture(capture))

    def test_numeric_token_bomb_and_size_bounds_are_rejected(self):
        with self.assertRaisesRegex(COUNTER.InputError, "numeric_token_too_long"):
            COUNTER.loads_bounded(b'{"value":' + b"9" * 33 + b"}")

        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "oversized.json"
            path.write_bytes(b"x" * 17)
            with self.assertRaisesRegex(COUNTER.InputError, "input_too_large"):
                COUNTER.readfile(path, 16)

    def test_receipt_source_review_and_evidence_preparation_preflight(self):
        document, raw_bundle, raw_bytes = fixture()

        self.assertEqual(
            COUNTER.preparation_payload(document, "receipt"),
            document["plan_receipt"],
        )
        self.assertEqual(
            COUNTER.preparation_payload(
                document,
                "source_review",
                raw_bundle,
                COUNTER.sha256(raw_bytes),
            ),
            document["source_review"],
        )
        self.assertEqual(
            COUNTER.preparation_payload(
                document,
                "evidence",
                raw_bundle,
                COUNTER.sha256(raw_bytes),
            ),
            document,
        )

    def test_evidence_preflight_rejects_companion_binding_and_row_tamper(self):
        for kind in ("binding", "row"):
            with self.subTest(kind=kind):
                document, raw_bundle, _raw_bytes = fixture()
                companion = find_capture(raw_bundle, "comp-event-0")
                if kind == "binding":
                    companion["identity"]["request_id"] = "transplanted"
                else:
                    companion["runtime"]["row_index"] = 0
                self.assert_evidence_preflight_fails(document, raw_bundle)

    def test_evidence_preflight_rejects_membership_and_incomplete_raw_usage(self):
        document, raw_bundle, _raw_bytes = fixture()
        find_capture(raw_bundle, "comp-event-0")["runtime"]["members"].reverse()
        self.assert_evidence_preflight_fails(document, raw_bundle)

        document, raw_bundle, _raw_bytes = fixture()
        raw_bundle["captures"] = [
            capture
            for capture in raw_bundle["captures"]
            if capture["identity"]["event_id"] != "comp-event-0"
        ]
        self.assert_evidence_preflight_fails(document, raw_bundle)

    @unittest.skipUnless(Path(COUNTER.SSH_KEYGEN).is_file(), "system ssh-keygen required")
    def test_real_signatures_verify_and_source_review_tamper_fails(self):
        document, _raw_bundle, _raw_bytes = fixture()
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            paths, principals = sign_document(root, document, generate_keys(root))
            authenticity = COUNTER.verify_authenticity(document, paths, principals)
            self.assertTrue(authenticity["verified"])

            document["source_review"]["disposition"] = "rejected"
            with self.assertRaisesRegex(
                COUNTER.InputError,
                "source_review_signature_invalid",
            ):
                COUNTER.verify_authenticity(document, paths, principals)

    @unittest.skipUnless(Path(COUNTER.SSH_KEYGEN).is_file(), "system ssh-keygen required")
    def test_same_key_rejection(self):
        document, _raw_bundle, _raw_bytes = fixture()
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            paths, principals = sign_document(
                root, document, generate_keys(root, same_key=True)
            )
            with self.assertRaisesRegex(
                COUNTER.InputError,
                "fingerprints_not_independent",
            ):
                COUNTER.verify_authenticity(document, paths, principals)

    @unittest.skipUnless(Path(COUNTER.SSH_KEYGEN).is_file(), "system ssh-keygen required")
    def test_path_hijack_cannot_accept_invalid_signature(self):
        document, _raw_bundle, _raw_bytes = fixture()
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            paths, principals = sign_document(root, document, generate_keys(root))
            Path(paths["evidence_signature"]).write_text("invalid", encoding="utf-8")
            fake = root / "ssh-keygen"
            fake.write_text("#!/bin/sh\nexit 0\n", encoding="utf-8")
            fake.chmod(stat.S_IRWXU)
            with mock.patch.dict(
                os.environ,
                {"PATH": str(root) + os.pathsep + os.environ.get("PATH", "")},
            ):
                with self.assertRaisesRegex(
                    COUNTER.InputError,
                    "evidence_signature_invalid",
                ):
                    COUNTER.verify_authenticity(document, paths, principals)

    @unittest.skipUnless(Path(COUNTER.SSH_KEYGEN).is_file(), "system ssh-keygen required")
    def test_full_cli_success_writes_durable_report(self):
        document, _raw_bundle, raw_bytes = fixture()
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            document_path = root / "evidence.json"
            raw_path = root / "raw.json"
            output_path = root / "report.json"
            document_path.write_bytes(COUNTER.canonical_json(document))
            raw_path.write_bytes(raw_bytes)
            paths, principals = sign_document(root, document, generate_keys(root))

            result = subprocess.run(
                [
                    sys.executable,
                    str(SCRIPT),
                    *cli_arguments(
                        document_path,
                        raw_path,
                        output_path,
                        paths,
                        principals,
                    ),
                ],
                capture_output=True,
                text=True,
                timeout=30,
            )

            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertEqual(result.stderr, "")
            self.assertTrue(json.loads(output_path.read_text())["passed"])

    def test_cli_failure_writes_report_without_traceback(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            document_path = root / "broken.json"
            raw_path = root / "raw.json"
            output_path = root / "report.json"
            dummy = root / "dummy"
            document_path.write_text("{", encoding="utf-8")
            raw_path.write_text("{}", encoding="utf-8")
            dummy.write_text("x", encoding="utf-8")
            paths = {
                "plan_signature": str(dummy),
                "receipt_signature": str(dummy),
                "source_review_signature": str(dummy),
                "evidence_signature": str(dummy),
                "plan_trust": str(dummy),
                "reviewer_trust": str(dummy),
                "evidence_trust": str(dummy),
            }
            principals = {
                "plan": "plan-principal",
                "reviewer": "reviewer-principal",
                "evidence": "evidence-principal",
            }

            result = subprocess.run(
                [
                    sys.executable,
                    str(SCRIPT),
                    *cli_arguments(
                        document_path,
                        raw_path,
                        output_path,
                        paths,
                        principals,
                    ),
                ],
                capture_output=True,
                text=True,
                timeout=30,
            )

            self.assertEqual(result.returncode, 2)
            self.assertNotIn("Traceback", result.stderr)
            report = json.loads(output_path.read_text())
            self.assertFalse(report["passed"])
            self.assertEqual(report["gate_reasons"], ["malformed_json"])

    @unittest.skipUnless(Path(COUNTER.SSH_KEYGEN).is_file(), "system ssh-keygen required")
    def test_broken_pipe_returns_non_success_after_durable_report(self):
        document, _raw_bundle, raw_bytes = fixture()

        class BrokenStdout:
            def __init__(self, descriptor):
                self.descriptor = descriptor

            class Buffer:
                @staticmethod
                def write(_data):
                    raise BrokenPipeError

                @staticmethod
                def flush():
                    return None

            buffer = Buffer()

            def fileno(self):
                return self.descriptor

        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            document_path = root / "evidence.json"
            raw_path = root / "raw.json"
            output_path = root / "report.json"
            document_path.write_bytes(COUNTER.canonical_json(document))
            raw_path.write_bytes(raw_bytes)
            paths, principals = sign_document(root, document, generate_keys(root))
            arguments = cli_arguments(
                document_path,
                raw_path,
                output_path,
                paths,
                principals,
            )
            arguments.append("--also-stdout")

            protected_descriptor = os.open(os.devnull, os.O_WRONLY)
            try:
                with mock.patch.object(
                    sys,
                    "stdout",
                    BrokenStdout(protected_descriptor),
                ):
                    result = COUNTER.main(arguments)
            finally:
                try:
                    os.close(protected_descriptor)
                except OSError:
                    pass

            self.assertEqual(result, 3)
            self.assertTrue(output_path.is_file())

    def test_package_resolved_remains_untouched(self):
        repository = SCRIPT.parents[1]
        package_resolved = repository / "phase3-binary" / "Package.resolved"
        if not package_resolved.is_file():
            self.skipTest("Package.resolved is not present in this suite copy")

        worktree = subprocess.run(
            ["git", "rev-parse", "--show-toplevel"],
            cwd=repository,
            check=False,
            capture_output=True,
            text=True,
        )
        if worktree.returncode != 0:
            self.skipTest("suite copy is not in a Git worktree")
        if Path(worktree.stdout.strip()).resolve() != repository.resolve():
            self.skipTest("suite copy is not a Git worktree root")

        result = subprocess.run(
            ["git", "diff", "--quiet", "--", "phase3-binary/Package.resolved"],
            cwd=repository,
            check=False,
        )

        self.assertEqual(result.returncode, 0)


if __name__ == "__main__":
    unittest.main()
