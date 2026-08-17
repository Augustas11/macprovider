from __future__ import annotations

import unittest

from scripts.check_spec_governance import (
    BUYER_PAID_PATH_JOURNEY_ID,
    BUYER_PAID_PATH_STEP_ID_ORDER,
    ValidationResult,
    _validate_buyer_paid_path_journey_result,
)


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


if __name__ == "__main__":
    unittest.main()
