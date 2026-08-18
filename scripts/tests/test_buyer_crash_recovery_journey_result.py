from __future__ import annotations

import importlib.util
import unittest
from pathlib import Path

from scripts.check_spec_governance import (
    BUYER_CRASH_RECOVERY_JOURNEY_ID,
    BUYER_CRASH_RECOVERY_STEP_ID_ORDER,
    ValidationResult,
    _validate_buyer_crash_recovery_journey_result,
)

REPO_ROOT = Path(__file__).resolve().parents[2]


def load_builder():
    path = REPO_ROOT / "scripts" / "build-buyer-crash-recovery-journey-result.py"
    import sys

    scripts = str(REPO_ROOT / "scripts")
    inserted = scripts not in sys.path
    if inserted:
        sys.path.insert(0, scripts)
    spec = importlib.util.spec_from_file_location("buyer_crash_recovery_builder", path)
    module = importlib.util.module_from_spec(spec)
    assert spec.loader is not None
    try:
        spec.loader.exec_module(module)
        return module
    finally:
        if inserted:
            sys.path.remove(scripts)


def valid_signed(*, requirement_ids=None, extra_requirement=None, **overrides):
    ids = list(requirement_ids or ["SPEC-005-R003"])
    if extra_requirement:
        ids.append(extra_requirement)
    signed = {
        "journey_id": BUYER_CRASH_RECOVERY_JOURNEY_ID,
        "execution_mode": "isolated-candidate-crash-recovery",
        "requirement_ids": ids,
        "observations": {
            "settlement_mode": "observe",
            "job_enabled": False,
            "payout_ready_mutated": False,
            "production_side_effects": False,
            "isolated_environment": True,
            "identity_fallback_recovered": True,
            "orphan_quarantined": True,
            "idempotent_rescan": True,
            "recovery_source": "startup_scan",
            "production_pearl": False,
        },
        "steps": [{"id": step_id, "status": "pass", "artifacts": ["a"]} for step_id in BUYER_CRASH_RECOVERY_STEP_ID_ORDER],
    }
    signed.update(overrides)
    return signed


class BuyerCrashRecoveryJourneyResultTests(unittest.TestCase):
    def test_valid_observe_payload_promotes_r003(self) -> None:
        result = ValidationResult()
        signed = valid_signed()
        _validate_buyer_crash_recovery_journey_result(
            signed,
            "SPEC-005-R003",
            [BUYER_CRASH_RECOVERY_JOURNEY_ID],
            signed["steps"],
            "evidence[0]",
            result,
        )
        self.assertEqual([], result.errors)

    def test_rejects_r007_promotion(self) -> None:
        result = ValidationResult()
        signed = valid_signed(requirement_ids=["SPEC-022-R007"])
        _validate_buyer_crash_recovery_journey_result(
            signed,
            "SPEC-022-R007",
            [BUYER_CRASH_RECOVERY_JOURNEY_ID],
            signed["steps"],
            "evidence[0]",
            result,
        )
        self.assertTrue(any("cannot promote SPEC-022-R007" in error for error in result.errors))

    def test_rejects_r008_promotion(self) -> None:
        result = ValidationResult()
        signed = valid_signed(requirement_ids=["SPEC-022-R008"])
        _validate_buyer_crash_recovery_journey_result(
            signed,
            "SPEC-022-R008",
            [BUYER_CRASH_RECOVERY_JOURNEY_ID],
            signed["steps"],
            "evidence[0]",
            result,
        )
        self.assertTrue(any("cannot promote SPEC-022-R008" in error for error in result.errors))

    def test_rejects_job_enabled(self) -> None:
        result = ValidationResult()
        signed = valid_signed()
        signed["observations"]["job_enabled"] = True
        _validate_buyer_crash_recovery_journey_result(
            signed,
            "SPEC-005-R003",
            [BUYER_CRASH_RECOVERY_JOURNEY_ID],
            signed["steps"],
            "evidence[0]",
            result,
        )
        self.assertTrue(any("job_enabled" in error for error in result.errors))

    def test_rejects_production_pearl(self) -> None:
        result = ValidationResult()
        signed = valid_signed()
        signed["observations"]["production_pearl"] = True
        _validate_buyer_crash_recovery_journey_result(
            signed,
            "SPEC-005-R003",
            [BUYER_CRASH_RECOVERY_JOURNEY_ID],
            signed["steps"],
            "evidence[0]",
            result,
        )
        self.assertTrue(any("production_pearl" in error for error in result.errors))

    def test_rejects_missing_step(self) -> None:
        result = ValidationResult()
        signed = valid_signed()
        signed["steps"] = signed["steps"][:-1]
        _validate_buyer_crash_recovery_journey_result(
            signed,
            "SPEC-005-R003",
            [BUYER_CRASH_RECOVERY_JOURNEY_ID],
            signed["steps"],
            "evidence[0]",
            result,
        )
        self.assertTrue(any("missing crash-recovery physical steps" in error for error in result.errors))

    def test_builder_rejects_enforce_ids_and_job_enabled(self) -> None:
        builder = load_builder()
        self.assertFalse(hasattr(builder, "require_candidate_identity"))
        with self.assertRaises(SystemExit):
            builder.parse_requirement_ids("SPEC-022-R007", {"requirement_ids": ["SPEC-022-R007"]})
        with self.assertRaises(SystemExit):
            builder.parse_requirement_ids("SPEC-022-R008", {"requirement_ids": ["SPEC-022-R008"]})
        self.assertEqual(
            builder.parse_requirement_ids(
                "SPEC-005-R003",
                {"requirement_ids": ["SPEC-005-R003"]},
            ),
            ["SPEC-005-R003"],
        )
        with self.assertRaises(SystemExit):
            builder.require_observations({"settlement_mode": "enforce"})
        with self.assertRaises(SystemExit):
            builder.require_observations(
                {
                    "settlement_mode": "observe",
                    "job_enabled": True,
                    "payout_ready_mutated": False,
                    "production_side_effects": False,
                    "isolated_environment": True,
                    "identity_fallback_recovered": True,
                    "orphan_quarantined": True,
                    "idempotent_rescan": True,
                    "recovery_source": "startup_scan",
                    "production_pearl": False,
                }
            )
        with self.assertRaises(SystemExit):
            builder.require_observations(
                {
                    "settlement_mode": "observe",
                    "job_enabled": False,
                    "payout_ready_mutated": False,
                    "production_side_effects": False,
                    "isolated_environment": True,
                    "identity_fallback_recovered": True,
                    "orphan_quarantined": True,
                    "idempotent_rescan": True,
                    "recovery_source": "startup_scan",
                    "production_pearl": True,
                }
            )


if __name__ == "__main__":
    unittest.main()
