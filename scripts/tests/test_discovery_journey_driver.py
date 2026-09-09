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

    def test_capture_keeps_the_whole_document_including_localization_keys(self) -> None:
        """Captures are archived whole (audit R1 F1).

        The digest the signed evidence binds to must cover the CLI's complete
        SPEC-046-R003 envelope, so nothing is stripped before hashing.
        """
        path = self.builder.capture("discovery", DISCOVERY_DOCUMENT)
        stored = json.loads(path.read_text(encoding="utf-8"))
        self.assertEqual(stored, DISCOVERY_DOCUMENT)
        guidance = stored["candidates"][0]["provider_guidance"]
        self.assertEqual(guidance["state_label_key"], "byom.local.local_only")
        self.assertEqual(guidance["state_meaning_key"], "byom.local.opaque_endpoint_not_earning")
        self.assertEqual(guidance["next_action"], "evaluate")
        self.assertEqual(guidance["transition_reason_code"], "capability_unevaluated")
        self.assertEqual(guidance["earning_path_class"], "local_inventory_only")

    def test_capture_refuses_a_hostname_at_a_localization_key_path(self) -> None:
        """The exemption is a closed grammar, not a hole: a real hostname at
        exactly those paths still fails closed."""
        for field in ("state_label_key", "state_meaning_key"):
            document = json.loads(json.dumps(DISCOVERY_DOCUMENT))
            document["candidates"][0]["provider_guidance"][field] = "coordinator.malibu.tech"
            with self.subTest(field=field):
                with self.assertRaises(driver.HarnessFailure):
                    self.builder.capture("leaky-guidance", document)
                self.assertFalse((self.temp / "captures" / "leaky-guidance.json").exists())

    def test_capture_refuses_a_localization_key_shape_in_any_other_field(self) -> None:
        """The exemption is field-scoped: the same string elsewhere is a
        hostname, in another guidance field or outside guidance entirely."""
        for path in (
            ("candidates", 0, "provider_guidance", "next_action"),
            ("candidates", 0, "display_name"),
            ("note",),
        ):
            document = json.loads(json.dumps(DISCOVERY_DOCUMENT))
            target = document
            for key in path[:-1]:
                target = target[key]
            target[path[-1]] = "byom.local.local_only"
            with self.subTest(path=path):
                with self.assertRaises(driver.HarnessFailure):
                    self.builder.capture("leaky-shape", document)
                self.assertFalse((self.temp / "captures" / "leaky-shape.json").exists())

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

    def test_captured_document_digest_survives_the_capture_contract(self) -> None:
        """The whole-document capture is what capture-time validation digests,
        so the same document must pass the contract's own document scan."""
        path = self.builder.capture("discovery", DISCOVERY_DOCUMENT)
        digested = evidence._digest_document(
            self.temp,
            {"id": "doc", "schema": "provider_byom_discovery.v1", "path": "captures/discovery.json"},
            "step-01-discover-mlx-cache",
            0,
        )
        self.assertEqual(digested["bytes"], len(path.read_bytes()))
        self.assertEqual(digested["schema"], "provider_byom_discovery.v1")


class CapturedDocumentScanTests(unittest.TestCase):
    """The scanner rule the driver and capture both run over captured documents."""

    def test_escaped_hostname_in_a_captured_document_still_fails(self) -> None:
        """A JSON escape must not hide a hostname from the decoded walk."""
        temp = Path(tempfile.mkdtemp(prefix="byom-capture-scan-"))
        self.addCleanup(shutil.rmtree, temp, True)
        captures = temp / "captures"
        captures.mkdir()
        escaped = (
            '{"schema": "provider_byom_discovery.v1", '
            '"note": "coordinator\\u002emalibu\\u002etech"}\n'
        )
        (captures / "escaped.json").write_text(escaped, encoding="utf-8")
        with self.assertRaises(evidence.BYOMEvidenceError):
            evidence._digest_document(
                temp,
                {"id": "doc", "schema": "provider_byom_discovery.v1", "path": "captures/escaped.json"},
                "step-01-discover-mlx-cache",
                0,
            )

    def test_localization_key_rule_is_a_closed_grammar(self) -> None:
        for value in (
            "byom.local.offerable",
            "byom.offer_dry_run.not_submitted_not_earning",
        ):
            with self.subTest(accepted=value):
                evidence.reject_unredacted_localization_key(value, "$.provider_guidance.state_label_key")
        for value in (
            "coordinator.malibu.tech",
            "byom.local",
            "BYOM.Local.Offerable",
            "byom.local.offerable.",
            "notbyom.local.offerable",
            "byom.local.offerable http://127.0.0.1:1",
        ):
            with self.subTest(rejected=value):
                with self.assertRaises(evidence.BYOMEvidenceError):
                    evidence.reject_unredacted_localization_key(
                        value, "$.provider_guidance.state_label_key"
                    )

    def test_emitted_evidence_scan_keeps_no_exemption(self) -> None:
        """`assert_redacted` is unchanged: evidence never carries guidance."""
        with self.assertRaises(evidence.BYOMEvidenceError):
            evidence.assert_redacted({"provider_guidance": {"state_label_key": "byom.local.offerable"}})


class OutputDirectoryTests(unittest.TestCase):
    def setUp(self) -> None:
        self.temp = Path(tempfile.mkdtemp(prefix="byom-discovery-out-"))
        self.addCleanup(shutil.rmtree, self.temp, True)

    def test_new_directory_is_created_user_private(self) -> None:
        out = self.temp / "fresh"
        driver.prepare_out_dir(out)
        self.assertTrue(out.is_dir())
        self.assertEqual(out.stat().st_mode & 0o777, 0o700)

    def test_existing_empty_directory_is_accepted(self) -> None:
        out = self.temp / "empty"
        out.mkdir()
        driver.prepare_out_dir(out)

    def test_a_failed_rerun_cannot_reuse_a_stale_manifest_directory(self) -> None:
        """Regression for the stale-manifest finding: a directory that already
        holds a previous run's manifest is refused outright, so a failing rerun
        can never leave that pass manifest sitting there as if it were current."""
        out = self.temp / "used"
        out.mkdir()
        (out / "run-manifest.json").write_text("{}", encoding="utf-8")
        with self.assertRaises(driver.HarnessFailure):
            driver.prepare_out_dir(out)
        # The operator's data is refused, never deleted.
        self.assertTrue((out / "run-manifest.json").is_file())

    def test_a_failed_run_publishes_no_manifest(self) -> None:
        out = self.temp / "failing"
        driver.prepare_out_dir(out)
        builder = driver.ManifestBuilder(out, "byom-discovery-unit", "1.2.3")
        with self.assertRaises(driver.HarnessFailure):
            builder.write()
        self.assertFalse((out / "run-manifest.json").exists())
        self.assertFalse((out / ".run-manifest.json.tmp").exists())


class EvidenceModeBindingTests(unittest.TestCase):
    """Evidence runs must execute the source they name (audit R1 F5)."""

    def test_evidence_mode_refuses_a_binary_override(self) -> None:
        with self.assertRaises(driver.HarnessFailure) as caught:
            driver.build_cli(REPO_ROOT, "/usr/bin/true", True)
        self.assertIn("MACPROVIDER_CLI_BINARY", str(caught.exception))

    def test_non_evidence_mode_keeps_the_local_override(self) -> None:
        self.assertEqual(driver.build_cli(REPO_ROOT, "/usr/bin/true", False), Path("/usr/bin/true"))

    def test_evidence_source_paths_cover_the_executed_surface(self) -> None:
        self.assertEqual(
            sorted(driver.EVIDENCE_SOURCE_PATHS),
            ["phase3-binary", "scripts", "test/e2e/byom"],
        )

    def test_evidence_mode_refuses_a_dirty_tracked_source_tree(self) -> None:
        """Exercised against a scratch repository so a concurrent run of this
        suite can never touch the checkout under test."""
        root = Path(tempfile.mkdtemp(prefix="byom-dirty-tree-"))
        self.addCleanup(shutil.rmtree, root, True)
        git = ["git", "-c", "user.email=t@example.invalid", "-c", "user.name=t"]
        subprocess.run(["git", "init", "-q", str(root)], check=True)
        tracked = root / "scripts" / "byom_journey_evidence.py"
        tracked.parent.mkdir(parents=True)
        tracked.write_text("original\n", encoding="utf-8")
        subprocess.run(git + ["add", "."], cwd=root, check=True)
        subprocess.run(git + ["commit", "-qm", "seed"], cwd=root, check=True)

        driver.require_clean_evidence_source(root)
        # Untracked files cannot change what a committed harness executes.
        (root / "scripts" / "scratch.txt").write_text("note\n", encoding="utf-8")
        driver.require_clean_evidence_source(root)
        # A modified tracked file can, so it fails closed.
        tracked.write_text("modified\n", encoding="utf-8")
        with self.assertRaises(driver.HarnessFailure) as caught:
            driver.require_clean_evidence_source(root)
        self.assertIn("scripts/byom_journey_evidence.py", str(caught.exception))

    def test_the_ci_wrapper_runs_the_driver_in_evidence_mode(self) -> None:
        wrapper = (REPO_ROOT / "scripts" / "test-byom-discovery-journey.sh").read_text(encoding="utf-8")
        self.assertIn("run-discovery-journey.py --evidence --out", wrapper)


if __name__ == "__main__":
    unittest.main()
