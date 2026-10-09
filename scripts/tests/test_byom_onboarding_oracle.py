import copy
import importlib.util
from pathlib import Path
import unittest


ROOT = Path(__file__).resolve().parents[2]
SPEC = importlib.util.spec_from_file_location(
    "byom_onboarding_e2e", ROOT / "test/e2e/byom/run-cli-onboarding-e2e.py"
)
HARNESS = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(HARNESS)


class BYOMOnboardingOracleTests(unittest.TestCase):
    def setUp(self):
        self.document = {
            "schema": "model_admission_offer_dry_run.v1",
            "candidate_id": "byom_test_candidate",
            "served_model_ref": HARNESS.SERVED_MODEL_REF,
            # The harness fixture is a deliberately noncatalog model (#1830):
            # no artifact identity, so no catalog key and no earning path.
            "catalog_model_key": None,
            "would_submit": True,
            "reason_code": "no_trusted_catalog_match",
            "likely_admission_state": "offerable",
            "likely_admission_state_source": "local_default",
            "warnings": ["evaluation_required"],
            "provider_guidance": {
                "state_meaning_key": "byom.offer_dry_run.no_earning_path_v0_1",
                "earning_path_class": "no_earning_path_in_v0_1",
                "transition_reason_code": "no_trusted_catalog_match",
                "next_action": "submit_offer",
            },
        }

    def check(self, document, requests=None):
        HARNESS.assert_catalog_offer_dry_run(
            document, "byom_test_candidate", [] if requests is None else requests
        )

    def test_accepts_local_eligibility_without_submission(self):
        self.check(self.document)

    def test_rejects_stale_or_unsafe_top_level_oracles(self):
        for field, value in (
            ("schema", "model_admission_status.v1"),
            ("candidate_id", "different_candidate"),
            ("served_model_ref", "different_model"),
            ("catalog_model_key", "qwen3-8b"),
            ("would_submit", False),
            ("would_submit", 1),
            ("reason_code", "evaluation_required"),
            ("likely_admission_state", "offer_submitted"),
            ("likely_admission_state", "settlement_capable"),
            ("likely_admission_state_source", "coordinator"),
            ("warnings", []),
            ("warnings", ["catalog_match_unverified"]),
            ("warnings", ["evaluation_required", "catalog_match_unverified"]),
            ("warnings", "evaluation_required"),
        ):
            with self.subTest(field=field, value=value):
                document = copy.deepcopy(self.document)
                document[field] = value
                with self.assertRaises(HARNESS.HarnessFailure):
                    self.check(document)

    def test_rejects_premature_earning_and_action_guidance(self):
        for field, value in (
            ("state_meaning_key", "byom.admission.settlement_capable"),
            ("earning_path_class", "settlement_capable"),
            ("transition_reason_code", None),
            ("next_action", "maintain_runtime"),
        ):
            with self.subTest(field=field):
                document = copy.deepcopy(self.document)
                document["provider_guidance"][field] = value
                with self.assertRaises(HARNESS.HarnessFailure):
                    self.check(document)

    def test_rejects_missing_contract_fields(self):
        # An absent catalog_model_key reads as null, which is the expected
        # noncatalog value, so only the other fields are required.
        for field in [name for name in self.document if name != "catalog_model_key"]:
            with self.subTest(field=field):
                document = copy.deepcopy(self.document)
                del document[field]
                with self.assertRaises(HARNESS.HarnessFailure):
                    self.check(document)

    def test_rejects_any_coordinator_contact(self):
        for method in ("GET", "POST"):
            with self.subTest(method=method):
                with self.assertRaises(HARNESS.HarnessFailure):
                    self.check(self.document, [{"method": method}])


if __name__ == "__main__":
    unittest.main()
