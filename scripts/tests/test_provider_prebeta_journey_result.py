from __future__ import annotations

import hashlib
import json
import os
import shutil
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path

from scripts.check_spec_governance import ValidationResult, _validate_signed_journey_result


REPO_ROOT = Path(__file__).resolve().parents[2]
BUILDER = REPO_ROOT / "scripts" / "build-provider-prebeta-journey-result.py"
SIGNER = REPO_ROOT / "scripts" / "sign-journey-result.py"
EVIDENCE_SOURCE = "journeys/evidence/provider-prebeta-admission-demo.redacted.json"


def run(*args: str, cwd: Path) -> subprocess.CompletedProcess[str]:
    return subprocess.run([*args], cwd=cwd, text=True, capture_output=True, check=False)


def generate_acceptance_key(root: Path) -> str:
    openssl = shutil.which("openssl")
    if openssl is None:
        raise unittest.SkipTest("openssl is required")
    security = root / "security"
    security.mkdir(parents=True, exist_ok=True)
    private_key = root / "private.pem"
    public_key = security / "acceptance-candidate-signing-public.pem"
    subprocess.run(
        [openssl, "genpkey", "-algorithm", "EC", "-pkeyopt", "ec_paramgen_curve:P-256", "-out", str(private_key)],
        check=True,
        stdout=subprocess.DEVNULL,
        stderr=subprocess.DEVNULL,
    )
    subprocess.run(
        [openssl, "pkey", "-in", str(private_key), "-pubout", "-out", str(public_key)],
        check=True,
        stdout=subprocess.DEVNULL,
        stderr=subprocess.DEVNULL,
    )
    return private_key.read_text(encoding="utf-8")


def base_conformance() -> dict:
    return {
        "$schema": "../schemas/spec-conformance-v1.schema.json",
        "schema_version": "spec-conformance-v1",
        "baseline": {"commit": "0" * 40, "captured_at": "2026-07-16"},
        "specs": [],
        "requirements": [
            {
                "requirement_id": "SPEC-010-R001",
                "spec_id": "SPEC-010",
                "state": "pending",
                "evidence": [],
                "journeys": ["JOURNEY-PROVIDER-PREBETA-ADMISSION"],
                "gap": {"verdict": "UNKNOWN", "owner": "@Augustas11", "issue": "https://github.com/Augustas11/macprovider/issues/895", "rationale": "pending physical evidence"},
            },
            {
                "requirement_id": "SPEC-010-R002",
                "spec_id": "SPEC-010",
                "state": "pending",
                "evidence": [],
                "journeys": [],
                "gap": {"verdict": "UNKNOWN", "owner": "@Augustas11", "issue": "https://github.com/Augustas11/macprovider/issues/614", "rationale": "not mapped here"},
            },
        ],
    }


def base_evidence(source_commit: str) -> dict:
    return {
        "schema_version": "macprovider.provider-prebeta-admission-evidence.v1",
        "journey_id": "JOURNEY-PROVIDER-PREBETA-ADMISSION",
        "run_id": "provider-prebeta-admission-demo",
        "requirement_ids": ["SPEC-010-R001"],
        "repository": {"name": "Augustas11/macprovider", "commit": source_commit},
        "captured_at": "2026-08-05T06:00:00Z",
        "expires_at": "2027-08-05",
        "operator": {"role": "provider-prebeta-operator", "identity_fingerprint": hashlib.sha256(b"operator").hexdigest()},
        "environment": {
            "class": "physical-provider-prebeta-admission",
            "hardware_profile": "apple-silicon-redacted",
            "candidate": "provider-cli:redacted-release-candidate",
        },
        "result": {"status": "pass", "summary": "Physical provider-prebeta admission evidence passed."},
        "steps": [
            {"id": "step-01-private-prebeta-authorization", "status": "pass", "assertion": "private prebeta authorization posture was captured"},
            {"id": "step-02-install-launch-identity", "status": "pass", "assertion": "install, launchd state, and provider identity were captured"},
            {"id": "step-03-provider-registration-admission", "status": "pass", "assertion": "coordinator registration and admission verdict were captured"},
            {"id": "step-04-catalog-autotune-readiness", "status": "pass", "assertion": "catalog row and autotune model readiness were captured"},
            {"id": "step-05-hardware-evidence-verifier", "status": "pass", "assertion": "hardware evidence submission and verifier verdict were captured"},
            {"id": "step-06-provider-runtime-routing", "status": "pass", "assertion": "runtime health and routing eligibility were captured"},
            {"id": "step-07-buyer-serving-smoke", "status": "pass", "assertion": "buyer smoke routed to the newly admitted provider"},
            {"id": "step-08-redaction-and-correlation", "status": "pass", "assertion": "redaction preserves correlation without secrets"},
        ],
        "redaction": {
            "secrets_redacted": True,
            "operator_identity_redacted": True,
            "local_account_names_redacted": True,
            "private_keys_redacted": True,
            "raw_signature_redacted": True,
        },
        "observations": {
            "provider_identity": "provider:redacted-demo",
            "buyer_smoke_request": "request:redacted-demo",
        },
    }


class ProviderPrebetaJourneyResultTests(unittest.TestCase):
    def make_repo(self, evidence_mutation=None, conformance_mutation=None) -> tuple[tempfile.TemporaryDirectory[str], Path, str, str]:
        directory = tempfile.TemporaryDirectory()
        root = Path(directory.name)
        (root / "specs").mkdir()
        (root / "journeys" / "evidence").mkdir(parents=True)
        conformance = base_conformance()
        if conformance_mutation is not None:
            conformance_mutation(conformance)
        (root / "specs" / "CONFORMANCE.json").write_text(json.dumps(conformance, indent=2) + "\n", encoding="utf-8")
        run("git", "init", cwd=root)
        run("git", "config", "user.name", "test", cwd=root)
        run("git", "config", "user.email", "test@example.com", cwd=root)
        run("git", "add", "specs/CONFORMANCE.json", cwd=root)
        run("git", "commit", "-m", "seed conformance", cwd=root)
        source_commit = run("git", "rev-parse", "HEAD", cwd=root).stdout.strip()
        evidence = base_evidence(source_commit)
        if evidence_mutation is not None:
            evidence_mutation(evidence)
        (root / EVIDENCE_SOURCE).write_text(json.dumps(evidence, indent=2) + "\n", encoding="utf-8")
        run("git", "add", EVIDENCE_SOURCE, cwd=root)
        run("git", "commit", "-m", "add provider evidence", cwd=root)
        evidence_commit = run("git", "rev-parse", "HEAD", cwd=root).stdout.strip()
        return directory, root, source_commit, evidence_commit

    def test_builder_emits_core_signed_payload(self) -> None:
        directory, root, source_commit, evidence_commit = self.make_repo()
        self.addCleanup(directory.cleanup)
        output = root / "payload.json"

        completed = subprocess.run(
            [
                sys.executable,
                str(BUILDER),
                "--root",
                str(root),
                "--source-sha",
                source_commit,
                "--evidence-sha",
                evidence_commit,
                "--output",
                str(output),
                EVIDENCE_SOURCE,
            ],
            text=True,
            capture_output=True,
            check=False,
        )

        self.assertEqual(0, completed.returncode, completed.stderr)
        payload = json.loads(output.read_text(encoding="utf-8"))
        self.assertEqual("macprovider.journey-result.v1", payload["schema_version"])
        self.assertEqual("JOURNEY-PROVIDER-PREBETA-ADMISSION", payload["journey_id"])
        self.assertEqual(["SPEC-010-R001"], payload["requirement_ids"])
        self.assertEqual(source_commit, payload["repository"]["commit"])
        self.assertEqual("physical-provider-prebeta-admission", payload["execution_mode"])
        artifact = payload["artifacts"][0]
        self.assertEqual("redacted-provider-prebeta-admission", artifact["id"])
        self.assertEqual(EVIDENCE_SOURCE, artifact["source"])
        self.assertEqual(hashlib.sha256((root / EVIDENCE_SOURCE).read_bytes()).hexdigest(), artifact["sha256"])
        self.assertEqual("step-07-buyer-serving-smoke", payload["steps"][6]["id"])

    def test_signed_provider_prebeta_payload_passes_canonical_validator(self) -> None:
        directory, root, source_commit, evidence_commit = self.make_repo()
        self.addCleanup(directory.cleanup)
        private_key = generate_acceptance_key(root)
        trusted_hash = hashlib.sha256((root / "security" / "acceptance-candidate-signing-public.pem").read_bytes()).hexdigest()
        payload = root / "payload.json"
        envelope = root / "journeys" / "evidence" / "provider-prebeta-admission-demo.journey-result.signed.json"
        completed = subprocess.run(
            [
                sys.executable,
                str(BUILDER),
                "--root",
                str(root),
                "--source-sha",
                source_commit,
                "--evidence-sha",
                evidence_commit,
                "--output",
                str(payload),
                EVIDENCE_SOURCE,
            ],
            text=True,
            capture_output=True,
            check=False,
        )
        self.assertEqual(0, completed.returncode, completed.stderr)
        env = os.environ.copy()
        env["MACPROVIDER_ACCEPTANCE_SIGNING_KEY_PEM"] = private_key
        openssl = shutil.which("openssl")
        if openssl is None:
            raise unittest.SkipTest("openssl is required")
        completed = subprocess.run(
            [
                sys.executable,
                str(SIGNER),
                "--root",
                str(root),
                "--input",
                str(payload),
                "--output",
                str(envelope.relative_to(root)),
                "--verified-at",
                "2026-08-05T06:05:00Z",
                "--openssl-bin",
                openssl,
            ],
            env=env,
            text=True,
            capture_output=True,
            check=False,
        )
        self.assertEqual(0, completed.returncode, completed.stderr)

        result = ValidationResult()
        self.assertTrue(
            _validate_signed_journey_result(
                root,
                str(envelope.relative_to(root)),
                "SPEC-010-R001",
                ["JOURNEY-PROVIDER-PREBETA-ADMISSION"],
                {source_commit},
                trusted_hash,
                openssl,
                "provider-prebeta",
                result,
            ),
            result.errors,
        )
        self.assertEqual([], result.errors)

    def test_canonical_validator_rejects_artifact_requirement_mismatch(self) -> None:
        directory, root, source_commit, evidence_commit = self.make_repo()
        self.addCleanup(directory.cleanup)
        private_key = generate_acceptance_key(root)
        trusted_hash = hashlib.sha256((root / "security" / "acceptance-candidate-signing-public.pem").read_bytes()).hexdigest()
        payload_path = root / "payload.json"
        completed = subprocess.run(
            [
                sys.executable,
                str(BUILDER),
                "--root",
                str(root),
                "--source-sha",
                source_commit,
                "--evidence-sha",
                evidence_commit,
                "--output",
                str(payload_path),
                EVIDENCE_SOURCE,
            ],
            text=True,
            capture_output=True,
            check=False,
        )
        self.assertEqual(0, completed.returncode, completed.stderr)
        payload = json.loads(payload_path.read_text(encoding="utf-8"))
        payload["requirement_ids"] = ["SPEC-010-R001", "SPEC-010-R002"]
        payload_path.write_text(json.dumps(payload, indent=2) + "\n", encoding="utf-8")
        envelope = root / "journeys" / "evidence" / "provider-prebeta-admission-demo.journey-result.signed.json"
        env = os.environ.copy()
        env["MACPROVIDER_ACCEPTANCE_SIGNING_KEY_PEM"] = private_key
        openssl = shutil.which("openssl")
        if openssl is None:
            raise unittest.SkipTest("openssl is required")
        completed = subprocess.run(
            [
                sys.executable,
                str(SIGNER),
                "--root",
                str(root),
                "--input",
                str(payload_path),
                "--output",
                str(envelope.relative_to(root)),
                "--verified-at",
                "2026-08-05T06:05:00Z",
                "--openssl-bin",
                openssl,
            ],
            env=env,
            text=True,
            capture_output=True,
            check=False,
        )
        self.assertEqual(0, completed.returncode, completed.stderr)

        result = ValidationResult()
        self.assertFalse(
            _validate_signed_journey_result(
                root,
                str(envelope.relative_to(root)),
                "SPEC-010-R001",
                ["JOURNEY-PROVIDER-PREBETA-ADMISSION"],
                {source_commit},
                trusted_hash,
                openssl,
                "provider-prebeta",
                result,
            )
        )
        self.assertTrue(any("must exactly match signed.requirement_ids" in error for error in result.errors), result.errors)

    def test_builder_rejects_unmapped_requirement(self) -> None:
        def claim_unmapped_requirement(evidence: dict) -> None:
            evidence["requirement_ids"] = ["SPEC-010-R002"]

        directory, root, source_commit, evidence_commit = self.make_repo(claim_unmapped_requirement)
        self.addCleanup(directory.cleanup)
        completed = subprocess.run(
            [
                sys.executable,
                str(BUILDER),
                "--root",
                str(root),
                "--source-sha",
                source_commit,
                "--evidence-sha",
                evidence_commit,
                "--output",
                str(root / "payload.json"),
                EVIDENCE_SOURCE,
            ],
            text=True,
            capture_output=True,
            check=False,
        )

        self.assertNotEqual(0, completed.returncode)
        self.assertIn("must be pending and mapped", completed.stderr)

    def test_builder_rejects_requirement_input_that_overclaims_evidence(self) -> None:
        def map_second_requirement(conformance: dict) -> None:
            conformance["requirements"][1]["journeys"] = ["JOURNEY-PROVIDER-PREBETA-ADMISSION"]
            conformance["requirements"][1]["gap"]["issue"] = "https://github.com/Augustas11/macprovider/issues/895"

        directory, root, source_commit, evidence_commit = self.make_repo(conformance_mutation=map_second_requirement)
        self.addCleanup(directory.cleanup)
        completed = subprocess.run(
            [
                sys.executable,
                str(BUILDER),
                "--root",
                str(root),
                "--source-sha",
                source_commit,
                "--evidence-sha",
                evidence_commit,
                "--requirement-ids",
                "SPEC-010-R002",
                "--output",
                str(root / "payload.json"),
                EVIDENCE_SOURCE,
            ],
            text=True,
            capture_output=True,
            check=False,
        )

        self.assertNotEqual(0, completed.returncode)
        self.assertIn("must exactly match evidence.requirement_ids", completed.stderr)

    def test_builder_rejects_source_sha_that_differs_from_evidence_commit(self) -> None:
        directory, root, source_commit, evidence_commit = self.make_repo()
        self.addCleanup(directory.cleanup)
        completed = subprocess.run(
            [
                sys.executable,
                str(BUILDER),
                "--root",
                str(root),
                "--source-sha",
                evidence_commit,
                "--evidence-sha",
                evidence_commit,
                "--output",
                str(root / "payload.json"),
                EVIDENCE_SOURCE,
            ],
            text=True,
            capture_output=True,
            check=False,
        )

        self.assertNotEqual(0, completed.returncode)
        self.assertIn("repository.commit must exactly match --source-sha", completed.stderr)

    def test_builder_rejects_non_ancestor_source_sha(self) -> None:
        directory = tempfile.TemporaryDirectory()
        self.addCleanup(directory.cleanup)
        root = Path(directory.name)
        (root / "specs").mkdir()
        (root / "journeys" / "evidence").mkdir(parents=True)
        (root / "specs" / "CONFORMANCE.json").write_text(json.dumps(base_conformance(), indent=2) + "\n", encoding="utf-8")
        run("git", "init", cwd=root)
        run("git", "config", "user.name", "test", cwd=root)
        run("git", "config", "user.email", "test@example.com", cwd=root)
        run("git", "add", "specs/CONFORMANCE.json", cwd=root)
        run("git", "commit", "-m", "seed conformance", cwd=root)
        base_branch = run("git", "branch", "--show-current", cwd=root).stdout.strip()
        run("git", "checkout", "-b", "side-source", cwd=root)
        (root / "side.txt").write_text("side source\n", encoding="utf-8")
        run("git", "add", "side.txt", cwd=root)
        run("git", "commit", "-m", "side source", cwd=root)
        side_source_commit = run("git", "rev-parse", "HEAD", cwd=root).stdout.strip()
        run("git", "checkout", base_branch, cwd=root)
        evidence = base_evidence(side_source_commit)
        (root / EVIDENCE_SOURCE).write_text(json.dumps(evidence, indent=2) + "\n", encoding="utf-8")
        run("git", "add", EVIDENCE_SOURCE, cwd=root)
        run("git", "commit", "-m", "add evidence on main", cwd=root)
        evidence_commit = run("git", "rev-parse", "HEAD", cwd=root).stdout.strip()

        completed = subprocess.run(
            [
                sys.executable,
                str(BUILDER),
                "--root",
                str(root),
                "--source-sha",
                side_source_commit,
                "--evidence-sha",
                evidence_commit,
                "--output",
                str(root / "payload.json"),
                EVIDENCE_SOURCE,
            ],
            text=True,
            capture_output=True,
            check=False,
        )

        self.assertNotEqual(0, completed.returncode)
        self.assertIn("must be an ancestor", completed.stderr)

    def test_builder_rejects_missing_buyer_smoke_step(self) -> None:
        def mutate(evidence: dict) -> None:
            evidence["steps"] = [step for step in evidence["steps"] if step["id"] != "step-07-buyer-serving-smoke"]

        directory, root, source_commit, evidence_commit = self.make_repo(mutate)
        self.addCleanup(directory.cleanup)
        completed = subprocess.run(
            [
                sys.executable,
                str(BUILDER),
                "--root",
                str(root),
                "--source-sha",
                source_commit,
                "--evidence-sha",
                evidence_commit,
                "--output",
                str(root / "payload.json"),
                EVIDENCE_SOURCE,
            ],
            text=True,
            capture_output=True,
            check=False,
        )

        self.assertNotEqual(0, completed.returncode)
        self.assertIn("step-07-buyer-serving-smoke", completed.stderr)


if __name__ == "__main__":
    unittest.main()
