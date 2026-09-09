"""Tests for the hermetic BYOM discovery-journey driver's manifest emitter.

These cover the parts of `test/e2e/byom/run-discovery-journey.py` that decide
what the signed evidence will eventually say: the step/requirement tables, the
observation truthfulness rules, and the fail-closed redaction of captured
documents and step assertions. Running the ten CLI steps needs a built macOS
`macprovider-cli` and is covered by `make test-byom-discovery-journey`.
"""

from __future__ import annotations

import importlib.util
import json
import shutil
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path

from scripts.check_spec_governance import (
    PROVIDER_BYOM_DISCOVERY_FALSE_OBSERVATIONS,
    PROVIDER_BYOM_DISCOVERY_JOURNEY_ID,
    PROVIDER_BYOM_DISCOVERY_STEP_ID_ORDER,
    PROVIDER_BYOM_DISCOVERY_STEP_REQUIREMENT_IDS,
    PROVIDER_BYOM_DISCOVERY_TRUE_OBSERVATIONS,
)

REPO_ROOT = Path(__file__).resolve().parents[2]
DRIVER_PATH = REPO_ROOT / "test" / "e2e" / "byom" / "run-discovery-journey.py"
OPERATOR_FINGERPRINT = "b" * 64


def load_driver():
    spec = importlib.util.spec_from_file_location("byom_discovery_journey_driver", DRIVER_PATH)
    module = importlib.util.module_from_spec(spec)
    assert spec.loader is not None
    spec.loader.exec_module(module)
    return module


driver = load_driver()
evidence = driver.evidence_contract


def head_commit() -> str:
    return subprocess.run(
        ["git", "rev-parse", "HEAD"], cwd=REPO_ROOT, capture_output=True, text=True, check=True
    ).stdout.strip()


DISCOVERY_DOCUMENT = {
    "schema": "provider_byom_discovery.v1",
    "candidates": [
        {
            "candidate_id": "byom_" + "a" * 52,
            "admission_state": "local_only",
            "admission_state_source": "local_default",
            "provider_guidance": {
                "state_label_key": "byom.local.local_only",
                "state_meaning_key": "byom.local.opaque_endpoint_not_earning",
                "next_action": "evaluate",
                "transition_reason_code": "capability_unevaluated",
                "earning_path_class": "local_inventory_only",
            },
        }
    ],
}
EVALUATION_DOCUMENT = {
    "schema": "provider_byom_evaluation.v1",
    "health_result": "passed",
    "mutation_summary": {"production_config_mutated": False, "coordinator_state_mutated": False},
}
DRY_RUN_DOCUMENT = {
    "schema": "model_admission_offer_dry_run.v1",
    "would_submit": False,
    "likely_admission_state": "local_only",
    "likely_admission_state_source": "local_default",
}


class DriverContractTests(unittest.TestCase):
    """The driver's own tables must mirror the governance tables exactly."""

    def test_step_requirement_table_stays_inside_governance(self) -> None:
        """Each step may claim only the requirements it exercises, plus the
        release-evidence requirement the journey proves as a whole; the union
        must still cover every requirement mapped to the journey."""
        contract = evidence.DISCOVERY_CONTRACT
        covered: set[str] = set()
        for step, requirements in driver.STEP_REQUIREMENT_IDS.items():
            allowed = contract.allowed_step_requirement_ids(step)
            self.assertEqual(len(set(requirements)), len(requirements), step)
            self.assertLessEqual(set(requirements), allowed, step)
            self.assertLessEqual(
                set(PROVIDER_BYOM_DISCOVERY_STEP_REQUIREMENT_IDS[step]),
                set(requirements),
                f"{step} dropped a requirement subject it exercises",
            )
            covered |= set(requirements)
        self.assertEqual(covered, set(contract.promotable_requirement_ids))

    def test_step_ids_cover_the_normative_journey(self) -> None:
        self.assertEqual(sorted(driver.STEP_REQUIREMENT_IDS), sorted(PROVIDER_BYOM_DISCOVERY_STEP_ID_ORDER))

    def test_observation_names_match_governance(self) -> None:
        self.assertEqual(set(driver.TRUE_OBSERVATIONS), set(PROVIDER_BYOM_DISCOVERY_TRUE_OBSERVATIONS))
        self.assertEqual(set(driver.FALSE_OBSERVATIONS), set(PROVIDER_BYOM_DISCOVERY_FALSE_OBSERVATIONS))
        self.assertEqual(
            set(driver.TRUE_OBSERVATIONS) & set(driver.FALSE_OBSERVATIONS),
            set(),
            "an observation cannot be both required-true and required-false",
        )

    def test_journey_identity_constants(self) -> None:
        self.assertEqual(driver.JOURNEY_ID, PROVIDER_BYOM_DISCOVERY_JOURNEY_ID)
        self.assertEqual(driver.RUN_MANIFEST_SCHEMA, evidence.RUN_MANIFEST_SCHEMA)
        self.assertEqual(driver.ENVIRONMENT_CLASS, "hermetic-loopback")
        self.assertTrue((REPO_ROOT / driver.HARNESS_NAME).is_file())


class ManifestEmitterTests(unittest.TestCase):
    def setUp(self) -> None:
        self.temp = Path(tempfile.mkdtemp(prefix="byom-discovery-driver-"))
        self.addCleanup(shutil.rmtree, self.temp, True)
        self.builder = driver.ManifestBuilder(self.temp, "byom-discovery-unit", "1.2.3")

    def build_all_steps(self) -> None:
        self.builder.capture("discovery", DISCOVERY_DOCUMENT)
        self.builder.capture("evaluation", EVALUATION_DOCUMENT)
        self.builder.capture("dry-run", DRY_RUN_DOCUMENT)
        for step_id in PROVIDER_BYOM_DISCOVERY_STEP_ID_ORDER:
            if step_id == "step-06-evaluate-candidate":
                document = self.builder.document("evaluate-candidate", "provider_byom_evaluation.v1", "evaluation")
            elif step_id == "step-07-no-production-mutation":
                document = self.builder.document("evaluate-mutation-summary", "provider_byom_evaluation.v1", "evaluation")
            elif step_id == "step-09-state-boundary":
                document = self.builder.document("offer-dry-run", "model_admission_offer_dry_run.v1", "dry-run")
            else:
                document = self.builder.document(
                    step_id.replace("step-", "doc-"), "provider_byom_discovery.v1", "discovery"
                )
            self.builder.add_step(step_id, "Hermetic loopback step passed with a bounded projection.", [document])
        for name in driver.TRUE_OBSERVATIONS:
            self.builder.observe(name, True)
        for name in driver.FALSE_OBSERVATIONS:
            self.builder.observe(name, False)

    def test_emitted_manifest_is_accepted_by_the_capture_contract(self) -> None:
        self.build_all_steps()
        manifest_path = self.builder.write()
        artifact = evidence.build_evidence(
            REPO_ROOT,
            evidence.DISCOVERY_CONTRACT,
            manifest_path,
            source_sha=head_commit(),
            operator_role="release-operator",
            operator_identity_fingerprint=OPERATOR_FINGERPRINT,
            hardware_profile="ci-hermetic-runner",
            candidate="1.2.3",
            captured_at=None,
            expires_at=None,
            summary="hermetic discovery journey",
        )
        self.assertEqual(artifact["journey_id"], PROVIDER_BYOM_DISCOVERY_JOURNEY_ID)
        self.assertEqual(
            [step["id"] for step in artifact["steps"]], list(PROVIDER_BYOM_DISCOVERY_STEP_ID_ORDER)
        )
        self.assertEqual(
            artifact["requirement_ids"], [f"SPEC-046-R{index:03d}" for index in range(1, 9)]
        )
        self.assertEqual(artifact["harness"]["name"], driver.HARNESS_NAME)
        self.assertEqual(artifact["environment"]["class"], "hermetic-loopback")

    def test_manifest_shape_is_the_run_manifest_contract(self) -> None:
        self.build_all_steps()
        manifest = json.loads(self.builder.write().read_text(encoding="utf-8"))
        self.assertEqual(
            set(manifest),
            {
                "schema_version",
                "journey_id",
                "run_id",
                "environment_class",
                "cli_version",
                "harness",
                "steps",
                "observations",
            },
        )
        self.assertEqual(manifest["harness"], {"name": driver.HARNESS_NAME, "status": "pass"})
        self.assertEqual(
            [step["id"] for step in manifest["steps"]], list(PROVIDER_BYOM_DISCOVERY_STEP_ID_ORDER)
        )
        for step in manifest["steps"]:
            self.assertEqual(set(step), {"id", "status", "assertion", "requirement_ids", "documents"})
            self.assertEqual(step["status"], "pass")
            for document in step["documents"]:
                self.assertEqual(set(document), {"id", "schema", "path"})
                self.assertTrue(document["path"].startswith("captures/"))
                self.assertTrue((self.temp / document["path"]).is_file())

    def test_unset_observation_is_refused(self) -> None:
        self.build_all_steps()
        self.builder.observations["candidate_evaluated"] = None
        with self.assertRaises(driver.HarnessFailure) as caught:
            self.builder.write()
        self.assertIn("candidate_evaluated", str(caught.exception))

    def test_required_true_observation_cannot_be_emitted_false(self) -> None:
        self.build_all_steps()
        self.builder.observe("non_loopback_rejected", False)
        with self.assertRaises(driver.HarnessFailure):
            self.builder.write()

    def test_required_false_observation_cannot_be_emitted_true(self) -> None:
        self.build_all_steps()
        self.builder.observe("buyer_traffic_sent", True)
        with self.assertRaises(driver.HarnessFailure):
            self.builder.write()

    def test_unknown_observation_name_is_refused(self) -> None:
        with self.assertRaises(driver.HarnessFailure):
            self.builder.observe("provider_paid_out", True)

    def test_unknown_step_id_is_refused(self) -> None:
        with self.assertRaises(driver.HarnessFailure):
            self.builder.add_step("step-11-invented", "nope", [])

    def test_missing_step_is_refused(self) -> None:
        self.build_all_steps()
        self.builder.steps = [step for step in self.builder.steps if step["id"] != "step-04-reject-non-loopback"]
        with self.assertRaises(driver.HarnessFailure):
            self.builder.write()

    def test_capture_drops_dotted_localization_keys(self) -> None:
        path = self.builder.capture("discovery", DISCOVERY_DOCUMENT)
        stored = json.loads(path.read_text(encoding="utf-8"))
        guidance = stored["candidates"][0]["provider_guidance"]
        self.assertNotIn("state_label_key", guidance)
        self.assertNotIn("state_meaning_key", guidance)
        # Every decision-bearing guidance field survives the redaction.
        self.assertEqual(guidance["next_action"], "evaluate")
        self.assertEqual(guidance["transition_reason_code"], "capability_unevaluated")
        self.assertEqual(guidance["earning_path_class"], "local_inventory_only")
        # The input document is not mutated in place.
        self.assertIn("state_label_key", DISCOVERY_DOCUMENT["candidates"][0]["provider_guidance"])

    def test_capture_refuses_a_document_carrying_unredacted_material(self) -> None:
        for leak in (
            {"schema": "provider_byom_discovery.v1", "origin": "http://127.0.0.1:11434"},
            {"schema": "provider_byom_discovery.v1", "cache": "/Users/someone/.cache/huggingface"},
            {"schema": "provider_byom_discovery.v1", "host": "coordinator.malibu.tech"},
            {"schema": "provider_byom_discovery.v1", "note": "reachable on localhost"},
            {"schema": "provider_byom_discovery.v1", "token": "Authorization: Bearer abcdefghijklmnopqrst"},
        ):
            with self.subTest(leak=sorted(leak)[0]):
                with self.assertRaises(driver.HarnessFailure):
                    self.builder.capture("leaky", leak)
                self.assertFalse((self.temp / "captures" / "leaky.json").exists())

    def test_step_assertions_survive_the_shared_redaction_scan(self) -> None:
        self.build_all_steps()
        manifest = json.loads(self.builder.write().read_text(encoding="utf-8"))
        for step in manifest["steps"]:
            evidence.reject_unredacted_text(step["assertion"], step["id"])

    def test_redaction_review_detects_leaked_material(self) -> None:
        captures = self.temp / "captures"
        captures.mkdir(exist_ok=True)
        self.assertTrue(driver.redaction_review(["clean output"], captures, ["http://127.0.0.1:1"]))
        with self.assertRaises(driver.HarnessFailure):
            driver.redaction_review(["saw http://127.0.0.1:1 once"], captures, ["http://127.0.0.1:1"])


if __name__ == "__main__":
    unittest.main()
