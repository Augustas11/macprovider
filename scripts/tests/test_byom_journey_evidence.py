"""Tests for the SPEC-046 / SPEC-047 BYOM signed-journey evidence tooling."""

from __future__ import annotations

import copy
import importlib.util
import json
import shutil
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path

from scripts.check_spec_governance import (
    CREDENTIAL_SHAPE_PATTERN_FRAGMENTS,
    LOCAL_CONSUMER_ENDPOINT_FORBIDDEN_METADATA_RE,
    NETWORK_MODEL_ADMISSION_ARTIFACT_ID,
    NETWORK_MODEL_ADMISSION_EXECUTION_MODE,
    NETWORK_MODEL_ADMISSION_JOURNEY_ID,
    NETWORK_MODEL_ADMISSION_MONEY_PATH_TABLES,
    NETWORK_MODEL_ADMISSION_STEP_ID_ORDER,
    PROVIDER_BYOM_DISCOVERY_ARTIFACT_ID,
    PROVIDER_BYOM_DISCOVERY_EXECUTION_MODE,
    PROVIDER_BYOM_DISCOVERY_JOURNEY_ID,
    PROVIDER_BYOM_DISCOVERY_STEP_ID_ORDER,
    ValidationResult,
    _validate_network_model_admission_journey_result,
    _validate_provider_byom_discovery_journey_result,
)

REPO_ROOT = Path(__file__).resolve().parents[2]
FIXTURES = REPO_ROOT / "scripts" / "tests" / "fixtures" / "byom_journeys"
OPERATOR_FINGERPRINT = "a" * 64


def load_module(name: str, filename: str):
    scripts = str(REPO_ROOT / "scripts")
    inserted = scripts not in sys.path
    if inserted:
        sys.path.insert(0, scripts)
    spec = importlib.util.spec_from_file_location(name, REPO_ROOT / "scripts" / filename)
    module = importlib.util.module_from_spec(spec)
    assert spec.loader is not None
    try:
        spec.loader.exec_module(module)
        return module
    finally:
        if inserted:
            sys.path.remove(scripts)


evidence_module = load_module("byom_journey_evidence_under_test", "byom_journey_evidence.py")
BYOMEvidenceError = evidence_module.BYOMEvidenceError


def head_commit(root: Path) -> str:
    return subprocess.run(
        ["git", "rev-parse", "HEAD"], cwd=root, capture_output=True, text=True, check=True
    ).stdout.strip()


class BYOMJourneyCaptureTests(unittest.TestCase):
    """Capture-side enforcement of the journey step, requirement, and redaction contracts."""

    def setUp(self) -> None:
        self.temp = Path(tempfile.mkdtemp(prefix="byom-journey-capture-"))
        self.addCleanup(shutil.rmtree, self.temp, True)
        self.source_sha = head_commit(REPO_ROOT)

    def staged_manifest(self, selector: str) -> tuple[Path, dict]:
        # A fresh staging directory per call, so a subTest loop over rejection
        # cases never inherits the previous iteration's mutated capture files.
        staged = Path(tempfile.mkdtemp(prefix=f"{selector}-", dir=self.temp)) / selector
        shutil.copytree(FIXTURES / selector, staged)
        manifest_path = staged / "run-manifest.json"
        return manifest_path, json.loads(manifest_path.read_text(encoding="utf-8"))

    def capture(self, selector: str, manifest: dict | None = None, manifest_path: Path | None = None) -> dict:
        if manifest_path is None:
            manifest_path, default = self.staged_manifest(selector)
            manifest = default if manifest is None else manifest
        if manifest is not None:
            manifest_path.write_text(json.dumps(manifest, indent=2), encoding="utf-8")
        contract = evidence_module.contract_for(selector)
        return evidence_module.build_evidence(
            REPO_ROOT,
            contract,
            manifest_path,
            source_sha=self.source_sha,
            operator_role="release-operator",
            operator_identity_fingerprint=OPERATOR_FINGERPRINT,
            hardware_profile="ci-hermetic-runner",
            candidate="cli-fixture",
            captured_at="2026-09-08T00:00:00Z",
            expires_at=None,
            summary="fixture journey run",
        )

    def mutate(self, selector: str, mutator) -> tuple[dict, Path]:
        manifest_path, manifest = self.staged_manifest(selector)
        mutator(manifest, manifest_path.parent)
        return manifest, manifest_path

    def assert_capture_fails(self, selector: str, mutator, fragment: str) -> None:
        manifest, manifest_path = self.mutate(selector, mutator)
        with self.assertRaises(BYOMEvidenceError) as caught:
            self.capture(selector, manifest, manifest_path)
        self.assertIn(fragment, str(caught.exception))

    def test_discovery_fixture_produces_schema_valid_evidence(self) -> None:
        evidence = self.capture("discovery")
        self.assertEqual("macprovider.provider-byom-discovery-evidence.v1", evidence["schema_version"])
        self.assertEqual(PROVIDER_BYOM_DISCOVERY_JOURNEY_ID, evidence["journey_id"])
        self.assertEqual(PROVIDER_BYOM_DISCOVERY_EXECUTION_MODE, evidence["execution_mode"])
        self.assertEqual("hermetic-loopback", evidence["environment"]["class"])
        self.assertEqual(
            list(PROVIDER_BYOM_DISCOVERY_STEP_ID_ORDER), [step["id"] for step in evidence["steps"]]
        )
        self.assertEqual([f"SPEC-046-R{index:03d}" for index in range(1, 9)], evidence["requirement_ids"])
        for step in evidence["steps"]:
            self.assertEqual([PROVIDER_BYOM_DISCOVERY_ARTIFACT_ID], step["artifacts"])
            for document in step["documents"]:
                # Digests, never the captured documents themselves.
                self.assertEqual(64, len(document["sha256"]))
                self.assertNotIn("path", document)

    def test_admission_fixture_carries_money_path_zero_rows(self) -> None:
        evidence = self.capture("admission")
        self.assertEqual("macprovider.network-model-admission-evidence.v1", evidence["schema_version"])
        self.assertEqual(NETWORK_MODEL_ADMISSION_EXECUTION_MODE, evidence["execution_mode"])
        self.assertEqual(
            list(NETWORK_MODEL_ADMISSION_STEP_ID_ORDER), [step["id"] for step in evidence["steps"]]
        )
        money_path = evidence["observations"]["money_path_zero_rows"]
        self.assertEqual(sorted(NETWORK_MODEL_ADMISSION_MONEY_PATH_TABLES), sorted(money_path))
        self.assertEqual({0}, set(money_path.values()))

    def test_rejects_unknown_step_id(self) -> None:
        def mutator(manifest, _root):
            manifest["steps"][0]["id"] = "step-99-invented"

        self.assert_capture_fails("discovery", mutator, "unknown JOURNEY-PROVIDER-BYOM-DISCOVERY step id")

    def test_rejects_missing_required_step(self) -> None:
        def mutator(manifest, _root):
            del manifest["steps"][3]

        self.assert_capture_fails("admission", mutator, "missing JOURNEY-NETWORK-MODEL-ADMISSION step(s)")

    def test_rejects_requirement_the_step_does_not_exercise(self) -> None:
        def mutator(manifest, _root):
            manifest["steps"][0]["requirement_ids"] = ["SPEC-046-R005"]

        self.assert_capture_fails("discovery", mutator, "is not a requirement this step exercises")

    def test_rejects_requirement_id_from_another_spec(self) -> None:
        def mutator(manifest, _root):
            manifest["steps"][0]["requirement_ids"] = ["SPEC-022-R001"]

        self.assert_capture_fails("admission", mutator, "is not a requirement this step exercises")

    def test_rejects_incomplete_requirement_coverage(self) -> None:
        def mutator(manifest, _root):
            for step in manifest["steps"]:
                step["requirement_ids"] = [
                    item for item in step["requirement_ids"] if item != "SPEC-046-R006"
                ] or ["SPEC-046-R008"]

        self.assert_capture_fails("discovery", mutator, "SPEC-046-R006")

    def test_rejects_url_in_assertion(self) -> None:
        def mutator(manifest, _root):
            manifest["steps"][1]["assertion"] = "adapter answered on http://127.0.0.1:11434/api/tags"

        self.assert_capture_fails("discovery", mutator, "contains a url")

    def test_rejects_absolute_path_in_assertion(self) -> None:
        def mutator(manifest, _root):
            manifest["steps"][0]["assertion"] = "scanned /Users/operator/.cache/huggingface for weights"

        self.assert_capture_fails("discovery", mutator, "contains an absolute path")

    def test_rejects_hostname_in_assertion(self) -> None:
        def mutator(manifest, _root):
            manifest["steps"][1]["assertion"] = "status readback came from coordinator.malibu.tech"

        self.assert_capture_fails("admission", mutator, "contains a hostname")

    def test_rejects_credential_in_assertion(self) -> None:
        def mutator(manifest, _root):
            manifest["steps"][1]["assertion"] = "authorization: Bearer abcdefghijklmnopqrstuvwxyz012345"

        self.assert_capture_fails("admission", mutator, "credential-like value")

    def test_rejects_captured_document_containing_a_credential(self) -> None:
        def mutator(manifest, root):
            document = root / "captures" / "discover-mlx-cache.json"
            document.write_text(
                json.dumps({"schema": "provider_byom_discovery.v1", "token": "ghp_" + "a" * 24}),
                encoding="utf-8",
            )

        self.assert_capture_fails("discovery", mutator, "credential-like value")

    def write_capture(self, root, payload: dict) -> None:
        (root / "captures" / "discover-mlx-cache.json").write_text(json.dumps(payload), encoding="utf-8")

    def assert_captured_document_rejected(self, payload: dict, fragment: str) -> None:
        def mutator(_manifest, root):
            self.write_capture(root, payload)

        self.assert_capture_fails("discovery", mutator, fragment)

    def test_rejects_captured_document_whose_schema_differs_from_the_manifest(self) -> None:
        self.assert_captured_document_rejected(
            {"schema": "model_admission_status.v1", "candidates": []},
            "does not match the captured document's top-level schema",
        )

    def test_rejects_captured_document_without_a_top_level_schema(self) -> None:
        self.assert_captured_document_rejected(
            {"candidates": []},
            "does not match the captured document's top-level schema",
        )

    def test_rejects_captured_document_that_is_not_a_json_object(self) -> None:
        def mutator(_manifest, root):
            (root / "captures" / "discover-mlx-cache.json").write_text(
                json.dumps(["provider_byom_discovery.v1"]), encoding="utf-8"
            )

        self.assert_capture_fails("discovery", mutator, "must be a JSON object document")

    def test_rejects_captured_document_with_an_absolute_path(self) -> None:
        def mutator(manifest, root):
            for step in manifest["steps"]:
                for document in step.get("documents", []):
                    document["path"] = str((root / document["path"]).resolve())
                    break
                else:
                    continue
                break

        self.assert_capture_fails("discovery", mutator, "must be relative to the run manifest directory")

    def test_rejects_captured_document_path_escaping_the_manifest_directory(self) -> None:
        def mutator(manifest, root):
            escaped = root.parent / "escaped-capture.json"
            escaped.write_text(json.dumps({"schema": "provider_byom_discovery.v1"}), encoding="utf-8")
            for step in manifest["steps"]:
                for document in step.get("documents", []):
                    document["path"] = "../escaped-capture.json"
                    break
                else:
                    continue
                break

        self.assert_capture_fails("discovery", mutator, "must be relative to the run manifest directory")

    def test_rejects_captured_document_with_duplicate_json_keys(self) -> None:
        def mutator(_manifest, root):
            (root / "captures" / "discover-mlx-cache.json").write_text(
                '{"schema": "provider_byom_discovery.v1", "schema": "model_admission_status.v1"}',
                encoding="utf-8",
            )

        self.assert_capture_fails("discovery", mutator, "must not contain duplicate JSON keys")

    def test_rejects_captured_document_containing_a_url(self) -> None:
        self.assert_captured_document_rejected(
            {"schema": "provider_byom_discovery.v1", "note": "http://runtime.invalid/api/tags"},
            "contains a url",
        )

    def test_rejects_captured_document_containing_an_absolute_path(self) -> None:
        self.assert_captured_document_rejected(
            {"schema": "provider_byom_discovery.v1", "note": "/Users/operator/.cache/huggingface"},
            "contains an absolute path",
        )

    def test_rejects_captured_document_containing_a_hostname(self) -> None:
        self.assert_captured_document_rejected(
            {"schema": "provider_byom_discovery.v1", "note": "read back from coordinator.malibu.tech"},
            "contains a hostname",
        )

    def test_rejects_captured_document_containing_an_ip_literal(self) -> None:
        self.assert_captured_document_rejected(
            {"schema": "provider_byom_discovery.v1", "note": "bound 10.11.12.13"},
            "contains an ipv4 literal",
        )

    def test_rejects_captured_document_containing_a_localhost_reference(self) -> None:
        self.assert_captured_document_rejected(
            {"schema": "provider_byom_discovery.v1", "note": "adapter answered on localhost"},
            "contains a localhost reference",
        )

    # The hostname rule is shape-based rather than a fixed suffix allowlist, so a
    # suffix the old list never enumerated must still fail closed -- in a manifest
    # assertion and in the bytes of a captured document.
    HOSTNAMES_OUTSIDE_THE_OLD_SUFFIX_LIST = (
        "provider-mac.xyz",
        "pool.example.co.uk",
        "provider-mac.lan",
        "mac-mini.home",
        "provider-mac.corp",
        "runtime.invalid",
    )

    def test_rejects_hostname_with_a_suffix_outside_the_old_fixed_list(self) -> None:
        for hostname in self.HOSTNAMES_OUTSIDE_THE_OLD_SUFFIX_LIST:
            with self.subTest(hostname=hostname):

                def mutator(manifest, _root, hostname=hostname):
                    manifest["steps"][1]["assertion"] = f"status readback came from {hostname}"

                self.assert_capture_fails("admission", mutator, "contains a hostname")

    def test_rejects_captured_document_hostname_outside_the_old_fixed_list(self) -> None:
        for hostname in self.HOSTNAMES_OUTSIDE_THE_OLD_SUFFIX_LIST:
            with self.subTest(hostname=hostname):
                self.assert_captured_document_rejected(
                    {"schema": "provider_byom_discovery.v1", "note": f"read back from {hostname}"},
                    "contains a hostname",
                )

    def test_rejects_captured_document_containing_an_ipv6_literal(self) -> None:
        for literal in ("2001:0db8:85a3:0000:0000:8a2e:0370:7334", "fe80::1ff:fe23:4567:890a", "::1"):
            with self.subTest(literal=literal):
                self.assert_captured_document_rejected(
                    {"schema": "provider_byom_discovery.v1", "note": f"bound {literal}"},
                    "contains an ipv6 literal",
                )

    # Token shapes the sibling governance scanner already covered while the BYOM
    # scanner did not: `sk-proj-`, `sk-` carrying `_`/`-`, and a lowercase AKIA.
    TOKEN_SHAPES_FROM_THE_GOVERNANCE_SIBLING = (
        "sk-proj-ABCDEFGHIJKLMNOPQRSTUVWX",
        "sk-ABCDEFGHIJ_KLMNOPQRSTUV-WX",
        "akiaabcdefghijklmnop",
        "github_pat_" + "a" * 24,
        "xoxb-" + "a" * 24,
        "mp_" + "a" * 20,
    )

    def test_rejects_token_shapes_covered_by_the_governance_sibling(self) -> None:
        for token in self.TOKEN_SHAPES_FROM_THE_GOVERNANCE_SIBLING:
            with self.subTest(token=token):

                def mutator(manifest, _root, token=token):
                    manifest["steps"][1]["assertion"] = f"offer echoed {token}"

                self.assert_capture_fails("admission", mutator, "credential-like value")

    def test_rejects_captured_document_token_shapes_covered_by_the_sibling(self) -> None:
        for token in self.TOKEN_SHAPES_FROM_THE_GOVERNANCE_SIBLING:
            with self.subTest(token=token):
                self.assert_captured_document_rejected(
                    {"schema": "provider_byom_discovery.v1", "note": f"echoed {token}"},
                    "credential-like value",
                )

    def test_legitimate_dns_shaped_values_still_capture(self) -> None:
        # The tightened rule must not reject the DNS-shaped value shapes the
        # contract legitimately emits, so prove them through a real capture.
        def mutator(manifest, _root):
            manifest["steps"][0]["assertion"] = (
                "schema macprovider.provider-byom-discovery-evidence.v1 with document "
                "provider_byom_discovery.v1, harness run-cli-onboarding-e2e.py, "
                "SnapshotManifestV1 at 1.8.117 for SPEC-046-R001 in step-01-discover-mlx-cache"
            )

        manifest, manifest_path = self.mutate("discovery", mutator)
        evidence = self.capture("discovery", manifest, manifest_path)
        self.assertIn("SnapshotManifestV1", evidence["steps"][0]["assertion"])
        self.assertEqual("test/e2e/byom/run-cli-onboarding-e2e.py", evidence["harness"]["name"])

    def test_rejects_secret_bearing_observation_key(self) -> None:
        def mutator(manifest, _root):
            manifest["observations"]["provider_token_seen"] = False

        self.assert_capture_fails("admission", mutator, "unexpected key(s)")

    def test_rejects_nonzero_money_path_row(self) -> None:
        def mutator(manifest, _root):
            manifest["observations"]["money_path_zero_rows"]["ledger_request_credits"] = 1

        self.assert_capture_fails("admission", mutator, "must be the integer 0")

    def test_rejects_missing_money_path_table(self) -> None:
        def mutator(manifest, _root):
            del manifest["observations"]["money_path_zero_rows"]["payout_attempts"]

        self.assert_capture_fails("admission", mutator, "payout_attempts")

    def test_rejects_false_required_observation(self) -> None:
        def mutator(manifest, _root):
            manifest["observations"]["mlx_cache_discovered"] = False

        self.assert_capture_fails("discovery", mutator, "observations.mlx_cache_discovered must be true")

    def test_rejects_true_forbidden_observation(self) -> None:
        def mutator(manifest, _root):
            manifest["observations"]["non_settlement_state_created_provider_credit"] = True

        self.assert_capture_fails(
            "admission", mutator, "observations.non_settlement_state_created_provider_credit must be false"
        )

    def test_rejects_unknown_environment_class(self) -> None:
        def mutator(manifest, _root):
            manifest["environment_class"] = "production-provider"

        self.assert_capture_fails("discovery", mutator, "environment_class must be one of")

    def test_rejects_failed_step(self) -> None:
        def mutator(manifest, _root):
            manifest["steps"][2]["status"] = "fail"

        self.assert_capture_fails("admission", mutator, "status must equal 'pass'")

    def test_rejects_journey_id_mismatch(self) -> None:
        def mutator(manifest, _root):
            manifest["journey_id"] = NETWORK_MODEL_ADMISSION_JOURNEY_ID

        self.assert_capture_fails("discovery", mutator, "journey_id must equal")


class BYOMJourneyRoundTripTests(unittest.TestCase):
    """Golden fixture round-trip: run manifest -> redacted evidence -> journey-result payload."""

    def setUp(self) -> None:
        self.temp = Path(tempfile.mkdtemp(prefix="byom-journey-roundtrip-"))
        self.addCleanup(shutil.rmtree, self.temp, True)

    def git(self, root: Path, *args: str) -> str:
        return subprocess.run(
            ["git", *args],
            cwd=root,
            capture_output=True,
            text=True,
            check=True,
            env={
                "PATH": "/usr/bin:/bin:/usr/local/bin",
                "HOME": str(root),
                "GIT_AUTHOR_NAME": "test",
                "GIT_AUTHOR_EMAIL": "test@example",
                "GIT_COMMITTER_NAME": "test",
                "GIT_COMMITTER_EMAIL": "test@example",
            },
        ).stdout.strip()

    def make_repo(self) -> Path:
        root = self.temp / "repo"
        (root / "specs").mkdir(parents=True)
        (root / "journeys" / "evidence").mkdir(parents=True)
        self.git(root, "init", "-q", "-b", "main")
        shutil.copy(REPO_ROOT / "specs" / "CONFORMANCE.json", root / "specs" / "CONFORMANCE.json")
        self.git(root, "add", "specs/CONFORMANCE.json")
        self.git(root, "commit", "-qm", "source")
        return root

    def round_trip(self, selector: str, evidence_name: str):
        root = self.make_repo()
        source_sha = self.git(root, "rev-parse", "HEAD")
        contract = evidence_module.contract_for(selector)
        evidence = evidence_module.build_evidence(
            root,
            contract,
            FIXTURES / selector / "run-manifest.json",
            source_sha=source_sha,
            operator_role="release-operator",
            operator_identity_fingerprint=OPERATOR_FINGERPRINT,
            hardware_profile="ci-hermetic-runner",
            candidate="cli-fixture",
            captured_at="2026-09-08T00:00:00Z",
            expires_at=None,
            summary="fixture journey run",
        )
        source = f"journeys/evidence/{evidence_name}"
        evidence_module.write_json_atomically(root / source, evidence)
        self.git(root, "add", source)
        self.git(root, "commit", "-qm", "evidence")
        evidence_sha = self.git(root, "rev-parse", "HEAD")
        payload = evidence_module.build_journey_result_payload(
            root,
            contract,
            source,
            source_sha=source_sha,
            evidence_sha=evidence_sha,
            requirement_ids=None,
        )
        return contract, payload, source

    def test_discovery_round_trip_satisfies_the_governance_validator(self) -> None:
        contract, payload, source = self.round_trip(
            "discovery", "provider-byom-discovery-20260908T000000Z.redacted.json"
        )
        self.assertEqual("macprovider.journey-result.v1", payload["schema_version"])
        self.assertEqual(PROVIDER_BYOM_DISCOVERY_JOURNEY_ID, payload["journey_id"])
        self.assertEqual(source, payload["artifacts"][0]["source"])
        self.assertEqual(PROVIDER_BYOM_DISCOVERY_ARTIFACT_ID, payload["artifacts"][0]["id"])
        for step in payload["steps"]:
            self.assertEqual({"id", "status", "assertion", "artifacts"}, set(step))
        result = ValidationResult()
        _validate_provider_byom_discovery_journey_result(
            payload,
            "SPEC-046-R008",
            [PROVIDER_BYOM_DISCOVERY_JOURNEY_ID],
            payload["artifacts"],
            payload["steps"],
            "evidence[0]",
            result,
        )
        self.assertEqual([], result.errors)

    def test_admission_round_trip_satisfies_the_governance_validator(self) -> None:
        contract, payload, source = self.round_trip(
            "admission", "network-model-admission-20260908T000000Z.redacted.json"
        )
        self.assertEqual(NETWORK_MODEL_ADMISSION_JOURNEY_ID, payload["journey_id"])
        self.assertEqual(NETWORK_MODEL_ADMISSION_ARTIFACT_ID, payload["artifacts"][0]["id"])
        result = ValidationResult()
        _validate_network_model_admission_journey_result(
            payload,
            "SPEC-047-R003",
            [NETWORK_MODEL_ADMISSION_JOURNEY_ID],
            payload["artifacts"],
            payload["steps"],
            "evidence[0]",
            result,
        )
        self.assertEqual([], result.errors)

    def test_builder_refuses_a_requirement_from_another_spec(self) -> None:
        root = self.make_repo()
        source_sha = self.git(root, "rev-parse", "HEAD")
        contract = evidence_module.contract_for("discovery")
        evidence = evidence_module.build_evidence(
            root,
            contract,
            FIXTURES / "discovery" / "run-manifest.json",
            source_sha=source_sha,
            operator_role="release-operator",
            operator_identity_fingerprint=OPERATOR_FINGERPRINT,
            hardware_profile="ci-hermetic-runner",
            candidate="cli-fixture",
            captured_at="2026-09-08T00:00:00Z",
            expires_at=None,
            summary="fixture journey run",
        )
        source = "journeys/evidence/provider-byom-discovery-20260908T000000Z.redacted.json"
        evidence_module.write_json_atomically(root / source, evidence)
        self.git(root, "add", source)
        self.git(root, "commit", "-qm", "evidence")
        evidence_sha = self.git(root, "rev-parse", "HEAD")
        with self.assertRaises(BYOMEvidenceError) as caught:
            evidence_module.build_journey_result_payload(
                root,
                contract,
                source,
                source_sha=source_sha,
                evidence_sha=evidence_sha,
                requirement_ids="SPEC-047-R001",
            )
        self.assertIn("must be covered by evidence.requirement_ids", str(caught.exception))

    def commit_and_build(self, mutator, selector: str = "discovery"):
        """Build a payload from committed evidence a mutator was allowed to hand-edit."""
        root = self.make_repo()
        source_sha = self.git(root, "rev-parse", "HEAD")
        contract = evidence_module.contract_for(selector)
        evidence = evidence_module.build_evidence(
            root,
            contract,
            FIXTURES / selector / "run-manifest.json",
            source_sha=source_sha,
            operator_role="release-operator",
            operator_identity_fingerprint=OPERATOR_FINGERPRINT,
            hardware_profile="ci-hermetic-runner",
            candidate="cli-fixture",
            captured_at="2026-09-08T00:00:00Z",
            expires_at=None,
            summary="fixture journey run",
        )
        mutator(evidence)
        source = f"journeys/evidence/{contract.evidence_prefix.split('/')[-1]}20260908T000000Z.redacted.json"
        evidence_module.write_json_atomically(root / source, evidence)
        self.git(root, "add", source)
        self.git(root, "commit", "-qm", "evidence")
        evidence_sha = self.git(root, "rev-parse", "HEAD")
        return evidence_module.build_journey_result_payload(
            root,
            contract,
            source,
            source_sha=source_sha,
            evidence_sha=evidence_sha,
            requirement_ids=None,
        )

    def assert_builder_rejects(self, mutator, fragment: str, selector: str = "discovery") -> None:
        with self.assertRaises(BYOMEvidenceError) as caught:
            self.commit_and_build(mutator, selector)
        self.assertIn(fragment, str(caught.exception))

    def test_builder_rejects_an_extra_evidence_step(self) -> None:
        def mutator(evidence):
            extra = copy.deepcopy(evidence["steps"][0])
            extra["id"] = "step-99-invented"
            evidence["steps"].append(extra)

        self.assert_builder_rejects(mutator, "unknown JOURNEY-PROVIDER-BYOM-DISCOVERY step id")

    def test_builder_rejects_a_missing_evidence_step(self) -> None:
        def mutator(evidence):
            del evidence["steps"][2]

        self.assert_builder_rejects(mutator, "missing JOURNEY-PROVIDER-BYOM-DISCOVERY step(s)")

    def test_builder_rejects_a_step_requirement_outside_the_allowed_set(self) -> None:
        def mutator(evidence):
            evidence["steps"][0]["requirement_ids"] = ["SPEC-046-R005"]

        self.assert_builder_rejects(mutator, "is not a requirement this step exercises")

    def test_builder_rejects_top_level_requirement_ids_that_are_not_the_step_union(self) -> None:
        def mutator(evidence):
            evidence["requirement_ids"] = [
                item for item in evidence["requirement_ids"] if item != "SPEC-046-R004"
            ]

        self.assert_builder_rejects(mutator, "must equal the union of the evidence step requirement ids")

    def test_builder_rejects_padded_top_level_requirement_ids(self) -> None:
        def mutator(evidence):
            evidence["requirement_ids"] = sorted(evidence["requirement_ids"] + ["SPEC-047-R001"])

        self.assert_builder_rejects(mutator, "must equal the union of the evidence step requirement ids")

    def test_builder_rejects_evidence_that_stops_covering_every_requirement(self) -> None:
        def mutator(evidence):
            for step in evidence["steps"]:
                step["requirement_ids"] = [
                    item for item in step["requirement_ids"] if item != "SPEC-046-R006"
                ] or ["SPEC-046-R008"]
            evidence["requirement_ids"] = sorted(
                {item for step in evidence["steps"] for item in step["requirement_ids"]}
            )

        self.assert_builder_rejects(mutator, "steps do not cover every mapped requirement: SPEC-046-R006")

    def test_builder_rejects_evidence_outside_the_journey_prefix(self) -> None:
        root = self.make_repo()
        source_sha = self.git(root, "rev-parse", "HEAD")
        contract = evidence_module.contract_for("discovery")
        with self.assertRaises(BYOMEvidenceError) as caught:
            evidence_module.build_journey_result_payload(
                root,
                contract,
                "journeys/evidence/buyer-enforce-20260818T051838Z.redacted.json",
                source_sha=source_sha,
                evidence_sha=source_sha,
                requirement_ids=None,
            )
        self.assertIn("redacted evidence source must be", str(caught.exception))


class BYOMJourneyGovernanceValidatorTests(unittest.TestCase):
    """Governance registration: the two journey ids get their own strict lane."""

    def signed(self, journey: str) -> dict:
        if journey == "discovery":
            return {
                "journey_id": PROVIDER_BYOM_DISCOVERY_JOURNEY_ID,
                "execution_mode": PROVIDER_BYOM_DISCOVERY_EXECUTION_MODE,
                "requirement_ids": ["SPEC-046-R008"],
                "environment": {"class": "physical-provider", "hardware_profile": "m4-16gb", "candidate": "cli"},
                "observations": {
                    **{
                        field: True
                        for field in (
                            "adapter_failure_warned",
                            "candidate_evaluated",
                            "loopback_runtime_discovered",
                            "local_state_ladder_verified",
                            "mlx_cache_discovered",
                            "non_loopback_rejected",
                            "opaque_endpoint_candidate_discovered",
                            "redacted_artifacts_reviewed",
                            "state_boundary_preserved",
                        )
                    },
                    **{
                        field: False
                        for field in (
                            "buyer_traffic_sent",
                            "provider_credit_created",
                            "raw_completion_logged",
                            "raw_prompt_logged",
                            "runtime_installed",
                            "weights_downloaded",
                        )
                    },
                },
                "steps": [
                    {"id": step_id, "status": "pass", "artifacts": [PROVIDER_BYOM_DISCOVERY_ARTIFACT_ID]}
                    for step_id in PROVIDER_BYOM_DISCOVERY_STEP_ID_ORDER
                ],
                "artifacts": [
                    {
                        "id": PROVIDER_BYOM_DISCOVERY_ARTIFACT_ID,
                        "sha256": "0" * 64,
                        "source": "journeys/evidence/provider-byom-discovery-20260908T000000Z.redacted.json",
                    }
                ],
            }
        return {
            "journey_id": NETWORK_MODEL_ADMISSION_JOURNEY_ID,
            "execution_mode": NETWORK_MODEL_ADMISSION_EXECUTION_MODE,
            "requirement_ids": ["SPEC-047-R003"],
            "environment": {"class": "hermetic-loopback", "hardware_profile": "ci", "candidate": "cli"},
            "observations": {
                **{
                    field: True
                    for field in (
                        "catalog_matched_not_settlement_verified",
                        "default_buyer_invisibility_verified",
                        "dry_run_did_not_submit",
                        "network_visible_unpriced_disclosed",
                        "earning_path_disclosure_verified",
                        "provider_signature_verified",
                        "rejected_opaque_endpoint_verified",
                        "revocation_on_drift_verified",
                        "sandbox_probe_only_blocked_from_paid_routing",
                        "synthetic_probe_used_provider_channel",
                        "settlement_capable_case_verified",
                        "transition_matrix_enforced",
                        "rejected_reoffer_required_fresh_evidence",
                        "withdrawn_reoffer_required_fresh_evidence",
                        "revoked_reoffer_required_fresh_evidence",
                        "withdrawal_verified",
                    )
                },
                **{
                    field: False
                    for field in (
                        "non_settlement_state_created_provider_credit",
                        "provider_price_treated_as_catalog_rate",
                        "raw_completion_logged",
                        "raw_prompt_logged",
                        "secret_field_persisted",
                    )
                },
                "money_path_zero_rows": {table: 0 for table in NETWORK_MODEL_ADMISSION_MONEY_PATH_TABLES},
            },
            "steps": [
                {"id": step_id, "status": "pass", "artifacts": [NETWORK_MODEL_ADMISSION_ARTIFACT_ID]}
                for step_id in NETWORK_MODEL_ADMISSION_STEP_ID_ORDER
            ],
            "artifacts": [
                {
                    "id": NETWORK_MODEL_ADMISSION_ARTIFACT_ID,
                    "sha256": "0" * 64,
                    "source": "journeys/evidence/network-model-admission-20260908T000000Z.redacted.json",
                }
            ],
        }

    def validate(self, journey: str, signed: dict, requirement_id: str, journeys: list[str] | None = None):
        result = ValidationResult()
        validator = (
            _validate_provider_byom_discovery_journey_result
            if journey == "discovery"
            else _validate_network_model_admission_journey_result
        )
        journey_id = (
            PROVIDER_BYOM_DISCOVERY_JOURNEY_ID if journey == "discovery" else NETWORK_MODEL_ADMISSION_JOURNEY_ID
        )
        validator(
            signed,
            requirement_id,
            journeys if journeys is not None else [journey_id],
            signed.get("artifacts", []),
            signed.get("steps", []),
            "evidence[0]",
            result,
        )
        return result.errors

    def test_valid_discovery_payload_passes(self) -> None:
        self.assertEqual([], self.validate("discovery", self.signed("discovery"), "SPEC-046-R008"))

    def test_valid_admission_payload_passes(self) -> None:
        self.assertEqual([], self.validate("admission", self.signed("admission"), "SPEC-047-R003"))

    def test_discovery_payload_cannot_promote_a_foreign_requirement(self) -> None:
        signed = self.signed("discovery")
        signed["requirement_ids"] = ["SPEC-047-R001"]
        errors = self.validate("discovery", signed, "SPEC-047-R001")
        self.assertTrue(any("cannot promote" in error for error in errors), errors)

    def test_admission_payload_rejects_nonzero_money_path_row(self) -> None:
        signed = copy.deepcopy(self.signed("admission"))
        signed["observations"]["money_path_zero_rows"]["request_log"] = 3
        errors = self.validate("admission", signed, "SPEC-047-R003")
        self.assertTrue(any("money_path_zero_rows.request_log" in error for error in errors), errors)

    def test_admission_payload_rejects_boolean_money_path_row(self) -> None:
        signed = copy.deepcopy(self.signed("admission"))
        signed["observations"]["money_path_zero_rows"]["payout_attempts"] = False
        errors = self.validate("admission", signed, "SPEC-047-R003")
        self.assertTrue(any("money_path_zero_rows.payout_attempts" in error for error in errors), errors)

    def test_rejects_missing_named_step(self) -> None:
        signed = copy.deepcopy(self.signed("discovery"))
        signed["steps"] = signed["steps"][:-1]
        errors = self.validate("discovery", signed, "SPEC-046-R008")
        self.assertTrue(any("missing provider BYOM discovery physical steps" in error for error in errors), errors)

    def test_rejects_invented_step(self) -> None:
        signed = copy.deepcopy(self.signed("admission"))
        signed["steps"][0]["id"] = "step-00-invented"
        errors = self.validate("admission", signed, "SPEC-047-R003")
        self.assertTrue(any("unexpected network model admission physical steps" in error for error in errors), errors)

    def test_rejects_wrong_execution_mode(self) -> None:
        signed = copy.deepcopy(self.signed("discovery"))
        signed["execution_mode"] = "isolated-candidate-paid-path"
        errors = self.validate("discovery", signed, "SPEC-046-R008")
        self.assertTrue(any("execution_mode" in error for error in errors), errors)

    def test_rejects_unknown_environment_class(self) -> None:
        signed = copy.deepcopy(self.signed("admission"))
        signed["environment"]["class"] = "production-provider"
        errors = self.validate("admission", signed, "SPEC-047-R003")
        self.assertTrue(any("environment.class" in error for error in errors), errors)

    def test_rejects_artifact_outside_the_journey_evidence_prefix(self) -> None:
        signed = copy.deepcopy(self.signed("discovery"))
        signed["artifacts"][0]["source"] = "journeys/evidence/buyer-enforce-20260818T051838Z.redacted.json"
        errors = self.validate("discovery", signed, "SPEC-046-R008")
        self.assertTrue(any("provider-byom-discovery-" in error for error in errors), errors)

    def test_rejects_requirement_not_mapped_to_this_journey(self) -> None:
        signed = copy.deepcopy(self.signed("admission"))
        errors = self.validate("admission", signed, "SPEC-047-R003", journeys=["JOURNEY-BUYER-PAID-PATH"])
        self.assertTrue(any("must include" in error for error in errors), errors)


class BYOMRedactionScannerTests(unittest.TestCase):
    """The fail-closed scanner must be as broad as it claims, and no broader."""

    def assert_rejected(self, text: str) -> None:
        with self.assertRaises(BYOMEvidenceError):
            evidence_module.reject_unredacted_text(text, "$")

    def assert_accepted(self, text: str) -> None:
        evidence_module.reject_unredacted_text(text, "$")

    def test_rejects_any_dns_shaped_hostname(self) -> None:
        for hostname in (
            "provider-mac.xyz",
            "pool.example.co.uk",
            "provider-mac.lan",
            "mac-mini.home",
            "provider-mac.corp",
            "a.b.museum",
            "coordinator.malibu.tech",
            "gateway.internal",
        ):
            with self.subTest(hostname=hostname):
                self.assert_rejected(f"read back from {hostname}")

    def test_rejects_urls_paths_and_ip_literals(self) -> None:
        for text in (
            "https://gateway.example/v1",
            "unix:///var/run/thing.sock",
            "wrote  /Users/operator/.cache/huggingface",
            "wrote  ~/byom-run/captures",
            "bound 10.11.12.13",
            "bound 2001:0db8:85a3:0000:0000:8a2e:0370:7334",
            "bound fe80::1ff:fe23:4567:890a",
            "bound ::1",
            "answered on localhost",
        ):
            with self.subTest(text=text):
                self.assert_rejected(text)

    def test_credential_shapes_are_at_least_the_governance_siblings(self) -> None:
        # Single source of truth: the BYOM scanner compiles the governance
        # module's credential-shape fragments, so it can never drift narrower.
        byom_patterns = {pattern.pattern for pattern in evidence_module.FORBIDDEN_SECRET_VALUE_PATTERNS}
        self.assertTrue(
            set(CREDENTIAL_SHAPE_PATTERN_FRAGMENTS).issubset(byom_patterns),
            sorted(set(CREDENTIAL_SHAPE_PATTERN_FRAGMENTS) - byom_patterns),
        )
        for fragment in CREDENTIAL_SHAPE_PATTERN_FRAGMENTS:
            with self.subTest(fragment=fragment):
                self.assertIn(fragment, LOCAL_CONSUMER_ENDPOINT_FORBIDDEN_METADATA_RE.pattern)

    def test_rejects_token_shapes(self) -> None:
        for token in (
            "sk-proj-ABCDEFGHIJKLMNOPQRSTUVWX",
            "sk-ABCDEFGHIJ_KLMNOPQRSTUV-WX",
            "AKIAABCDEFGHIJKLMNOP",
            "akiaabcdefghijklmnop",
            "ghp_" + "a" * 24,
            "github_pat_" + "a" * 24,
            "xoxb-" + "a" * 24,
            "mp_" + "a" * 20,
            "provider-token-abcdefgh",
            "Bearer " + "a" * 24,
            # Assembled at runtime so the repository secret preflight does not
            # read this test fixture as a real PEM header.
            "-----BEGIN EC PRIVATE " + "KEY-----",
        ):
            with self.subTest(token=token):
                self.assert_rejected(f"value {token} seen")

    def test_accepts_the_allowlisted_and_non_dns_value_shapes(self) -> None:
        # These are the shapes the evidence contract legitimately emits. The
        # schema ids, step ids, requirement ids, run ids and versions are not
        # DNS-shaped at all; the repository source file names are, and are the
        # only entries the hostname allowlist covers.
        for value in (
            "macprovider.provider-byom-discovery-evidence.v1",
            "macprovider.network-model-admission-evidence.v1",
            "macprovider.byom-journey-run.v1",
            "provider_byom_discovery.v1",
            "model_admission_status.v1",
            "step-01-discover-mlx-cache",
            "step-12-redaction-review",
            "SPEC-046-R008",
            "SPEC-047-R003",
            "SnapshotManifestV1",
            "1.8.117",
            "v1.2.3",
            "0.0.0-fixture",
            "byom-discovery-fixture",
            "JOURNEY-PROVIDER-BYOM-DISCOVERY",
            "Augustas11/macprovider",
            "macprovider-acceptance-p256-v1",
            "2026-09-08T00:00:00Z",
            "a" * 64,
            "test/e2e/byom/run-cli-onboarding-e2e.py",
            "run-manifest.json",
            "docs/runbooks/byom-journey-evidence.md",
            "10/10 steps pass. No money-path rows were written.",
        ):
            with self.subTest(value=value):
                self.assert_accepted(value)

    def test_a_file_name_shape_with_an_unlisted_extension_still_fails_closed(self) -> None:
        self.assert_rejected("harness at run-cli-onboarding-e2e.zz")


class BYOMJourneyGovernanceSourceTests(unittest.TestCase):
    """Governance re-opens the referenced evidence instead of trusting the signature."""

    def setUp(self) -> None:
        self.temp = Path(tempfile.mkdtemp(prefix="byom-journey-source-"))
        self.addCleanup(shutil.rmtree, self.temp, True)
        self.source = "journeys/evidence/provider-byom-discovery-20260908T000000Z.redacted.json"
        self.evidence = self.build_evidence()
        self.write_evidence(self.evidence)

    def build_evidence(self) -> dict:
        staged = self.temp / "capture"
        shutil.copytree(FIXTURES / "discovery", staged)
        return evidence_module.build_evidence(
            REPO_ROOT,
            evidence_module.contract_for("discovery"),
            staged / "run-manifest.json",
            source_sha=head_commit(REPO_ROOT),
            operator_role="release-operator",
            operator_identity_fingerprint=OPERATOR_FINGERPRINT,
            hardware_profile="ci-hermetic-runner",
            candidate="cli-fixture",
            captured_at="2026-09-08T00:00:00Z",
            expires_at=None,
            summary="fixture journey run",
        )

    def write_evidence(self, evidence: dict) -> None:
        path = self.temp / self.source
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text(json.dumps(evidence, indent=2) + "\n", encoding="utf-8")

    def signed(self, evidence: dict | None = None) -> dict:
        evidence = self.evidence if evidence is None else evidence
        return copy.deepcopy(
            {
                "schema_version": evidence_module.JOURNEY_RESULT_PAYLOAD_SCHEMA,
                "journey_id": evidence["journey_id"],
                "requirement_ids": evidence["requirement_ids"],
                "repository": evidence["repository"],
                "captured_at": evidence["captured_at"],
                "expires_at": evidence["expires_at"],
                "operator": evidence["operator"],
                "environment": evidence["environment"],
                "result": evidence["result"],
                "redaction": evidence["redaction"],
                "run_id": evidence["run_id"],
                "execution_mode": evidence["execution_mode"],
                "observations": evidence["observations"],
                "steps": [
                    {
                        "id": step["id"],
                        "status": "pass",
                        "assertion": step["assertion"],
                        "artifacts": step["artifacts"],
                    }
                    for step in evidence["steps"]
                ],
                "artifacts": [
                    {
                        "id": PROVIDER_BYOM_DISCOVERY_ARTIFACT_ID,
                        "sha256": "0" * 64,
                        "source": self.source,
                    }
                ],
            }
        )

    def validate(self, signed: dict, requirement_id: str = "SPEC-046-R008") -> list[str]:
        result = ValidationResult()
        _validate_provider_byom_discovery_journey_result(
            signed,
            requirement_id,
            [PROVIDER_BYOM_DISCOVERY_JOURNEY_ID],
            signed.get("artifacts", []),
            signed.get("steps", []),
            "evidence[0]",
            result,
            root=self.temp,
        )
        return result.errors

    def test_payload_projected_from_its_source_passes(self) -> None:
        self.assertEqual([], self.validate(self.signed()))

    def test_rejects_signed_requirement_id_the_source_does_not_cover(self) -> None:
        signed = self.signed()
        signed["requirement_ids"] = signed["requirement_ids"] + ["SPEC-047-R001"]
        errors = self.validate(signed)
        self.assertTrue(any("must cover every signed requirement ID" in error for error in errors), errors)

    def test_rejects_source_requirement_ids_that_are_not_the_step_union(self) -> None:
        evidence = copy.deepcopy(self.evidence)
        evidence["requirement_ids"] = evidence["requirement_ids"] + ["SPEC-046-R002"]
        self.write_evidence(evidence)
        errors = self.validate(self.signed())
        self.assertTrue(any("must equal the union" in error for error in errors), errors)

    def test_rejects_signed_payload_carrying_generic_optional_fields(self) -> None:
        for extra in ("harness", "config_before", "candidate", "candidate_identity", "eip712", "signer"):
            with self.subTest(extra=extra):
                signed = self.signed()
                signed[extra] = {"unbound": "value"}
                errors = self.validate(signed)
                self.assertTrue(
                    any("must carry exactly the builder key set" in error for error in errors), errors
                )

    def test_rejects_signed_payload_missing_a_builder_key(self) -> None:
        signed = self.signed()
        del signed["observations"]
        errors = self.validate(signed)
        self.assertTrue(any("must carry exactly the builder key set" in error for error in errors), errors)

    def test_rejects_signed_step_that_disagrees_with_the_source(self) -> None:
        signed = self.signed()
        signed["steps"][0]["assertion"] = "a claim the source evidence never made"
        errors = self.validate(signed)
        self.assertTrue(any("signed steps must match" in error for error in errors), errors)

    def test_rejects_signed_step_dropped_from_the_projection(self) -> None:
        signed = self.signed()
        signed["steps"] = signed["steps"][:-1]
        errors = self.validate(signed)
        self.assertTrue(any("signed steps must match" in error for error in errors), errors)

    def test_rejects_tampered_signed_observation(self) -> None:
        signed = self.signed()
        signed["observations"]["mlx_cache_discovered"] = False
        errors = self.validate(signed)
        self.assertTrue(any("signed observations must match" in error for error in errors), errors)

    def test_rejects_tampered_source_observation(self) -> None:
        evidence = copy.deepcopy(self.evidence)
        evidence["observations"]["raw_prompt_logged"] = True
        self.write_evidence(evidence)
        errors = self.validate(self.signed())
        self.assertTrue(any("must be false" in error for error in errors), errors)

    def test_rejects_source_evidence_step_outside_the_contract(self) -> None:
        evidence = copy.deepcopy(self.evidence)
        evidence["steps"][0]["id"] = "step-00-invented"
        self.write_evidence(evidence)
        errors = self.validate(self.signed())
        self.assertTrue(any("unknown" in error and "step id" in error for error in errors), errors)

    def test_rejects_source_evidence_that_is_not_redacted(self) -> None:
        evidence = copy.deepcopy(self.evidence)
        evidence["steps"][0]["assertion"] = "read back from provider-mac.xyz"
        self.write_evidence(evidence)
        errors = self.validate(self.signed())
        self.assertTrue(any("contains a hostname" in error for error in errors), errors)

    def test_rejects_signed_operator_that_disagrees_with_the_source(self) -> None:
        signed = self.signed()
        signed["operator"]["role"] = "someone-else"
        errors = self.validate(signed)
        self.assertTrue(any("operator" in error and "must match" in error for error in errors), errors)

    def test_rejects_absent_source_artifact(self) -> None:
        (self.temp / self.source).unlink()
        errors = self.validate(self.signed())
        self.assertTrue(any("rejected" in error for error in errors), errors)


class BYOMJourneyConformanceMappingTests(unittest.TestCase):
    """The journey ids the tooling emits must stay mapped and pending in CONFORMANCE.json."""

    def test_every_promotable_requirement_is_pending_and_mapped(self) -> None:
        conformance = json.loads((REPO_ROOT / "specs" / "CONFORMANCE.json").read_text(encoding="utf-8"))
        rows = {row["requirement_id"]: row for row in conformance["requirements"]}
        for journey_id, prefix in (
            (PROVIDER_BYOM_DISCOVERY_JOURNEY_ID, "SPEC-046"),
            (NETWORK_MODEL_ADMISSION_JOURNEY_ID, "SPEC-047"),
        ):
            for index in range(1, 9):
                requirement_id = f"{prefix}-R{index:03d}"
                row = rows[requirement_id]
                self.assertIn(journey_id, row["journeys"], requirement_id)
                self.assertEqual("pending", row["state"], requirement_id)
                self.assertEqual([], row["evidence"], requirement_id)


if __name__ == "__main__":
    unittest.main()
