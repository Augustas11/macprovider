from __future__ import annotations

import importlib.util
import json
import unittest
from pathlib import Path

from scripts.check_spec_governance import (
    BUYER_PAID_PATH_JOURNEY_ID,
    BUYER_PAID_PATH_STEP_ID_ORDER,
    SIGNED_JOURNEY_RESULT_ALLOWED_KEYS,
    SIGNED_JOURNEY_RESULT_REQUIRED_KEYS,
    ValidationResult,
    _expect_keys,
    _validate_buyer_paid_path_journey_result,
)

REPO_ROOT = Path(__file__).resolve().parents[2]


def load_builder():
    path = REPO_ROOT / "scripts" / "build-buyer-paid-path-journey-result.py"
    import sys

    scripts = str(REPO_ROOT / "scripts")
    inserted = scripts not in sys.path
    if inserted:
        sys.path.insert(0, scripts)
    spec = importlib.util.spec_from_file_location("buyer_paid_path_builder", path)
    module = importlib.util.module_from_spec(spec)
    assert spec.loader is not None
    try:
        spec.loader.exec_module(module)
        return module
    finally:
        if inserted:
            sys.path.remove(scripts)


def valid_signed(*, requirement_ids=None, extra_requirement=None, retrieval_exposed=False, **overrides):
    ids = list(requirement_ids or ["SPEC-006-R001"])
    if extra_requirement:
        ids.append(extra_requirement)
    signed = {
        "journey_id": BUYER_PAID_PATH_JOURNEY_ID,
        "execution_mode": "isolated-candidate-paid-path",
        "requirement_ids": ids,
        "observations": {
            "settlement_mode": "observe",
            "enforce_activated": False,
            "payout_ready_mutated": False,
            "production_side_effects": False,
            "buyer_receipt_retrieval_exposed": retrieval_exposed,
            "isolated_environment": True,
            "raw_prompt_output_redacted": True,
            "bearer_tokens_redacted": True,
        },
        "candidate_identity": {
            "gateway_base_url_sha256": "a" * 64,
            "coordinator_config_sha256": "b" * 64,
            "rate_card_sha256": "c" * 64,
            "rate_card_version": "test-rate-card",
            "rate_card_matched_key": "default",
            "signed_catalog_id": "integration-catalog",
            "signed_catalog_key_id": "integration-catalog-key",
            "autotune_catalog_version": "test-autotune",
            "autotune_catalog_sha256": "d" * 64,
            "verified_model_sha256": "e" * 64,
        },
        "steps": [{"id": step_id, "status": "pass", "artifacts": ["a"]} for step_id in BUYER_PAID_PATH_STEP_ID_ORDER],
    }
    signed.update(overrides)
    return signed


class BuyerPaidPathJourneyResultTests(unittest.TestCase):
    def test_valid_observe_payload_promotes_entrypoint(self) -> None:
        result = ValidationResult()
        signed = valid_signed()
        _validate_buyer_paid_path_journey_result(
            signed,
            "SPEC-006-R001",
            [BUYER_PAID_PATH_JOURNEY_ID],
            signed["steps"],
            "evidence[0]",
            result,
        )
        self.assertEqual([], result.errors)

    def test_rejects_r007_promotion(self) -> None:
        result = ValidationResult()
        signed = valid_signed(requirement_ids=["SPEC-022-R007"])
        _validate_buyer_paid_path_journey_result(
            signed,
            "SPEC-022-R007",
            [BUYER_PAID_PATH_JOURNEY_ID],
            signed["steps"],
            "evidence[0]",
            result,
        )
        self.assertTrue(any("cannot promote SPEC-022-R007" in error for error in result.errors))

    def test_rejects_r008_promotion(self) -> None:
        result = ValidationResult()
        signed = valid_signed(requirement_ids=["SPEC-022-R008"])
        _validate_buyer_paid_path_journey_result(
            signed,
            "SPEC-022-R008",
            [BUYER_PAID_PATH_JOURNEY_ID],
            signed["steps"],
            "evidence[0]",
            result,
        )
        self.assertTrue(any("cannot promote SPEC-022-R008" in error for error in result.errors))

    def test_rejects_r006_while_retrieval_unexposed(self) -> None:
        result = ValidationResult()
        signed = valid_signed(requirement_ids=["SPEC-022-R006"], retrieval_exposed=False)
        _validate_buyer_paid_path_journey_result(
            signed,
            "SPEC-022-R006",
            [BUYER_PAID_PATH_JOURNEY_ID],
            signed["steps"],
            "evidence[0]",
            result,
        )
        self.assertTrue(any("cannot promote SPEC-022-R006" in error for error in result.errors))

    def test_allows_r006_when_retrieval_exposed(self) -> None:
        result = ValidationResult()
        signed = valid_signed(requirement_ids=["SPEC-022-R006"], retrieval_exposed=True)
        _validate_buyer_paid_path_journey_result(
            signed,
            "SPEC-022-R006",
            [BUYER_PAID_PATH_JOURNEY_ID],
            signed["steps"],
            "evidence[0]",
            result,
        )
        self.assertEqual([], result.errors)

    def test_rejects_enforce_activated(self) -> None:
        result = ValidationResult()
        signed = valid_signed()
        signed["observations"]["enforce_activated"] = True
        _validate_buyer_paid_path_journey_result(
            signed,
            "SPEC-006-R001",
            [BUYER_PAID_PATH_JOURNEY_ID],
            signed["steps"],
            "evidence[0]",
            result,
        )
        self.assertTrue(any("enforce_activated" in error for error in result.errors))

    def test_signed_payload_allowlist_accepts_candidate_identity(self) -> None:
        self.assertIn("candidate_identity", SIGNED_JOURNEY_RESULT_ALLOWED_KEYS)
        schema = json.loads((REPO_ROOT / "schemas" / "journey-result-v1.schema.json").read_text(encoding="utf-8"))
        self.assertIn("candidate_identity", schema["$defs"]["signed"]["properties"])
        result = ValidationResult()
        signed = {
            "schema_version": "macprovider.journey-result.v1",
            "journey_id": BUYER_PAID_PATH_JOURNEY_ID,
            "requirement_ids": ["SPEC-006-R001"],
            "repository": {"name": "Augustas11/macprovider", "commit": "a" * 40},
            "captured_at": "2026-08-17T00:00:00Z",
            "expires_at": "2026-09-16",
            "operator": {"role": "acceptance-operator", "identity_fingerprint": "a" * 64},
            "environment": {"class": "isolated-candidate-paid-path"},
            "artifacts": [],
            "result": {"status": "pass"},
            "steps": [],
            "redaction": {
                "secrets_redacted": True,
                "operator_identity_redacted": True,
                "local_account_names_redacted": True,
            },
            "candidate_identity": {"rate_card_matched_key": "default"},
        }
        _expect_keys(signed, SIGNED_JOURNEY_RESULT_REQUIRED_KEYS, SIGNED_JOURNEY_RESULT_ALLOWED_KEYS, "signed", result)
        self.assertEqual([], result.errors)

    def test_rejects_missing_candidate_identity(self) -> None:
        result = ValidationResult()
        signed = valid_signed()
        del signed["candidate_identity"]
        _validate_buyer_paid_path_journey_result(
            signed,
            "SPEC-006-R001",
            [BUYER_PAID_PATH_JOURNEY_ID],
            signed["steps"],
            "evidence[0]",
            result,
        )
        self.assertTrue(any("candidate_identity" in error for error in result.errors))

    def test_rejects_missing_step(self) -> None:
        result = ValidationResult()
        signed = valid_signed()
        signed["steps"] = signed["steps"][:-1]
        _validate_buyer_paid_path_journey_result(
            signed,
            "SPEC-006-R001",
            [BUYER_PAID_PATH_JOURNEY_ID],
            signed["steps"],
            "evidence[0]",
            result,
        )
        self.assertTrue(any("missing paid-path physical steps" in error for error in result.errors))

    def test_rejects_r003_crash_recovery(self) -> None:
        result = ValidationResult()
        signed = valid_signed(requirement_ids=["SPEC-005-R003"])
        _validate_buyer_paid_path_journey_result(
            signed,
            "SPEC-005-R003",
            [BUYER_PAID_PATH_JOURNEY_ID],
            signed["steps"],
            "evidence[0]",
            result,
        )
        self.assertTrue(any("cannot promote SPEC-005-R003" in error for error in result.errors))

    def test_builder_rejects_r007_and_missing_observe(self) -> None:
        builder = load_builder()
        with self.assertRaises(SystemExit):
            builder.parse_requirement_ids("SPEC-022-R007", {"requirement_ids": ["SPEC-022-R007"]})
        with self.assertRaises(SystemExit):
            builder.parse_requirement_ids("SPEC-005-R003", {"requirement_ids": ["SPEC-005-R003"]})
        with self.assertRaises(SystemExit):
            builder.parse_requirement_ids(
                "SPEC-022-R006",
                {"requirement_ids": ["SPEC-022-R006"]},
            )
        self.assertEqual(
            builder.parse_requirement_ids(
                "SPEC-022-R006",
                {
                    "requirement_ids": ["SPEC-022-R006"],
                    "observations": {"buyer_receipt_retrieval_exposed": True},
                },
            ),
            ["SPEC-022-R006"],
        )
        with self.assertRaises(SystemExit):
            builder.require_observations({"settlement_mode": "enforce"})
        with self.assertRaises(SystemExit):
            builder.require_candidate_identity({"rate_card_matched_key": "default"})


if __name__ == "__main__":
    unittest.main()
