from __future__ import annotations

import importlib.util
import unittest
from pathlib import Path

from scripts.check_spec_governance import (
    BUYER_ENFORCE_JOURNEY_ID,
    BUYER_ENFORCE_STEP_ID_ORDER,
    ValidationResult,
    _validate_buyer_enforce_journey_result,
)

REPO_ROOT = Path(__file__).resolve().parents[2]


def load_builder():
    path = REPO_ROOT / "scripts" / "build-buyer-enforce-journey-result.py"
    import sys

    scripts = str(REPO_ROOT / "scripts")
    inserted = scripts not in sys.path
    if inserted:
        sys.path.insert(0, scripts)
    spec = importlib.util.spec_from_file_location("buyer_enforce_builder", path)
    module = importlib.util.module_from_spec(spec)
    assert spec.loader is not None
    try:
        spec.loader.exec_module(module)
        return module
    finally:
        if inserted:
            sys.path.remove(scripts)


def valid_signed(*, requirement_ids=None, extra_requirement=None, **overrides):
    ids = list(requirement_ids or ["SPEC-022-R007"])
    if extra_requirement:
        ids.append(extra_requirement)
    signed = {
        "journey_id": BUYER_ENFORCE_JOURNEY_ID,
        "execution_mode": "isolated-candidate-enforce",
        "requirement_ids": ids,
        "observations": {
            "settlement_mode_start": "enforce",
            "enforce_activated": True,
            "job_enabled": False,
            "payout_ready_mutated": False,
            "production_side_effects": False,
            "production_pearl": False,
            "isolated_environment": True,
            "raw_prompt_output_redacted": True,
        },
        "steps": [{"id": step_id, "status": "pass", "artifacts": ["a"]} for step_id in BUYER_ENFORCE_STEP_ID_ORDER],
    }
    signed.update(overrides)
    return signed


class BuyerEnforceJourneyResultTests(unittest.TestCase):
    def test_valid_isolated_enforce_payload_promotes_r007(self) -> None:
        result = ValidationResult()
        signed = valid_signed()
        _validate_buyer_enforce_journey_result(
            signed,
            "SPEC-022-R007",
            [BUYER_ENFORCE_JOURNEY_ID],
            signed["steps"],
            "evidence[0]",
            result,
        )
        self.assertEqual([], result.errors)

    def test_allows_r008_r009_r011(self) -> None:
        for requirement_id in ("SPEC-022-R008", "SPEC-022-R009", "SPEC-022-R011"):
            result = ValidationResult()
            signed = valid_signed(requirement_ids=[requirement_id])
            _validate_buyer_enforce_journey_result(
                signed,
                requirement_id,
                [BUYER_ENFORCE_JOURNEY_ID],
                signed["steps"],
                "evidence[0]",
                result,
            )
            self.assertEqual([], result.errors, requirement_id)

    def test_rejects_r003_crash_recovery(self) -> None:
        result = ValidationResult()
        signed = valid_signed(requirement_ids=["SPEC-005-R003"])
        _validate_buyer_enforce_journey_result(
            signed,
            "SPEC-005-R003",
            [BUYER_ENFORCE_JOURNEY_ID],
            signed["steps"],
            "evidence[0]",
            result,
        )
        self.assertTrue(any("cannot promote SPEC-005-R003" in error for error in result.errors))

    def test_rejects_r006_retrieval(self) -> None:
        result = ValidationResult()
        signed = valid_signed(requirement_ids=["SPEC-022-R006"])
        _validate_buyer_enforce_journey_result(
            signed,
            "SPEC-022-R006",
            [BUYER_ENFORCE_JOURNEY_ID],
            signed["steps"],
            "evidence[0]",
            result,
        )
        self.assertTrue(any("cannot promote SPEC-022-R006" in error for error in result.errors))

    def test_rejects_production_pearl(self) -> None:
        result = ValidationResult()
        signed = valid_signed()
        signed["observations"]["production_pearl"] = True
        _validate_buyer_enforce_journey_result(
            signed,
            "SPEC-022-R007",
            [BUYER_ENFORCE_JOURNEY_ID],
            signed["steps"],
            "evidence[0]",
            result,
        )
        self.assertTrue(any("production_pearl" in error for error in result.errors))

    def test_rejects_job_enabled(self) -> None:
        result = ValidationResult()
        signed = valid_signed()
        signed["observations"]["job_enabled"] = True
        _validate_buyer_enforce_journey_result(
            signed,
            "SPEC-022-R007",
            [BUYER_ENFORCE_JOURNEY_ID],
            signed["steps"],
            "evidence[0]",
            result,
        )
        self.assertTrue(any("job_enabled" in error for error in result.errors))

    def test_rejects_missing_step(self) -> None:
        result = ValidationResult()
        signed = valid_signed()
        signed["steps"] = signed["steps"][:-1]
        _validate_buyer_enforce_journey_result(
            signed,
            "SPEC-022-R007",
            [BUYER_ENFORCE_JOURNEY_ID],
            signed["steps"],
            "evidence[0]",
            result,
        )
        self.assertTrue(any("missing enforce physical steps" in error for error in result.errors))

    def test_builder_rejects_paid_path_and_pearl(self) -> None:
        builder = load_builder()
        self.assertFalse(hasattr(builder, "require_candidate_identity"))
        with self.assertRaises(SystemExit):
            builder.parse_requirement_ids("SPEC-005-R003", {"requirement_ids": ["SPEC-005-R003"]})
        with self.assertRaises(SystemExit):
            builder.parse_requirement_ids("SPEC-022-R006", {"requirement_ids": ["SPEC-022-R006"]})
        self.assertEqual(
            builder.parse_requirement_ids(
                "SPEC-022-R007,SPEC-022-R008,SPEC-022-R009,SPEC-022-R011",
                {"requirement_ids": ["SPEC-022-R007", "SPEC-022-R008", "SPEC-022-R009", "SPEC-022-R011"]},
            ),
            ["SPEC-022-R007", "SPEC-022-R008", "SPEC-022-R009", "SPEC-022-R011"],
        )
        with self.assertRaises(SystemExit):
            builder.require_observations({"settlement_mode_start": "observe"})
        with self.assertRaises(SystemExit):
            builder.require_observations(
                {
                    "settlement_mode_start": "enforce",
                    "enforce_activated": True,
                    "job_enabled": False,
                    "payout_ready_mutated": False,
                    "production_side_effects": False,
                    "production_pearl": True,
                    "isolated_environment": True,
                    "raw_prompt_output_redacted": True,
                }
            )


if __name__ == "__main__":
    unittest.main()
