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
VALIDATOR = REPO_ROOT / "scripts" / "validate-provider-prebeta-evidence.py"
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
                "implementation": ["provider_prebeta_contract.txt:provider-prebeta-current-selector"],
                "tests": ["provider_prebeta_contract.txt:provider-prebeta-current-selector"],
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
            "binary_version": "1.8.92",
            "compatibility_set": f"Augustas11/macprovider:v1.8.92@{source_commit}",
            "operating_system": "Version 26.5 (Build 25F71)",
            "production_equivalent_conditions": {
                "provider_service": "launchd-managed macprovider-cli serve",
                "network_state_before": "buyer_serving",
                "network_state_after": "buyer_serving",
                "coordinator_connected_before": True,
                "coordinator_connected_after": True,
                "model_loaded_before": True,
                "model_loaded_after": True,
                "thermal_state": "nominal",
                "thermally_throttled": False,
                "memory_pressure": "normal",
            },
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


def add_spec032_conformance(conformance: dict) -> None:
    conformance["requirements"] = [
        {
            "requirement_id": requirement_id,
            "spec_id": "SPEC-032",
            "state": "pending",
            "evidence": [],
            "journeys": ["JOURNEY-PROVIDER-PREBETA-ADMISSION"],
            "implementation": ["provider_prebeta_contract.txt:provider-prebeta-current-selector"],
            "tests": ["provider_prebeta_contract.txt:provider-prebeta-current-selector"],
            "gap": {
                "verdict": "UNKNOWN",
                "owner": "@Augustas11",
                "issue": "https://github.com/Augustas11/macprovider/issues/959",
                "rationale": "pending strict admission matrix evidence",
            },
        }
        for requirement_id in ("SPEC-032-R001", "SPEC-032-R002", "SPEC-032-R003")
    ]


def strict_spec032_steps() -> list[dict]:
    snap_ready = {
        "admission_ceiling_excluded": False,
        "admission_evidence_stale": False,
        "admission_sandboxed": False,
        "routing_eligible": True,
        "serving_capable": True,
    }
    snap_excluded = {
        "admission_ceiling_excluded": True,
        "admission_evidence_stale": False,
        "admission_sandboxed": False,
        "routing_eligible": False,
        "serving_capable": False,
    }
    snap_stale = {
        "admission_ceiling_excluded": False,
        "admission_evidence_stale": True,
        "admission_sandboxed": False,
        "routing_eligible": False,
        "serving_capable": False,
    }
    snap_sandboxed = {
        "admission_ceiling_excluded": False,
        "admission_evidence_stale": False,
        "admission_sandboxed": True,
        "routing_eligible": False,
        "serving_capable": False,
    }
    control = dict(snap_ready)
    rows = [
        ("r001-over-ceiling", "SPEC-032-R001", "over-ceiling heartbeat route-excludes subject", snap_ready, snap_excluded, "autotune_model_cap_exceeded"),
        ("r001-uncatalogued", "SPEC-032-R001", "uncatalogued heartbeat route-excludes subject", snap_excluded, snap_excluded, "autotune_model_uncatalogued"),
        ("r001-clears", "SPEC-032-R001", "in-ceiling heartbeat clears the route exclusion", snap_excluded, snap_ready, None),
        ("r002-expired", "SPEC-032-R002", "expired evidence route-excludes subject", snap_ready, snap_stale, "autotune_evidence_stale_or_mismatched"),
        ("r002-tuple-mismatch", "SPEC-032-R002", "tuple-mismatched evidence route-excludes subject", snap_ready, snap_stale, "autotune_evidence_stale_or_mismatched"),
        ("r002-missing-tuple", "SPEC-032-R002", "missing admitted tuple route-excludes capped subject", snap_ready, snap_stale, "autotune_evidence_stale_or_mismatched"),
        ("r003-sandbox-and-failclosed-reload", "SPEC-032-R003", "evidence-absent subject sandboxed; fail-closed hot-enable reload keeps the evidence-backed control routable", snap_ready, snap_sandboxed, "autotune_evidence_required"),
        ("r003-recovery-sweep", "SPEC-032-R003", "recovery sweep restores healthy control; evidence-absent subject stays sandboxed", snap_sandboxed, snap_sandboxed, "autotune_evidence_required"),
    ]
    steps = []
    for step_id, requirement, assertion, before, after, reason in rows:
        step = {
            "id": step_id,
            "requirement": requirement,
            "status": "pass",
            "assertion": assertion,
            "subject_fingerprint": hashlib.sha256(f"subject:{step_id}".encode()).hexdigest(),
            "subject_before": before,
            "subject_after": after,
            "control_fingerprint": hashlib.sha256(b"control").hexdigest(),
            "control_after": control,
        }
        if reason is not None:
            step["non_admission_reason"] = reason
        if requirement == "SPEC-032-R003":
            step["durable_provider_credentials_minted"] = False
        if step_id == "r003-sandbox-and-failclosed-reload":
            step["fail_closed_reload_observed"] = True
        steps.append(step)
    return steps


def make_spec032_evidence(evidence: dict) -> None:
    evidence["run_id"] = "provider-prebeta-admission-spec032-strict-canary-20260902T120000Z"
    evidence["requirement_ids"] = ["SPEC-032-R001", "SPEC-032-R002", "SPEC-032-R003"]
    evidence["repository"]["git_describe"] = "v1.8.118-29-g00000000"
    evidence["result"] = {"status": "pass", "summary": "Physical strict admission-gate matrix passed."}
    evidence["environment"]["class"] = "physical-provider-prebeta-admission"
    evidence["environment"]["coordinator_identity"] = hashlib.sha256(b"isolated-canary-coordinator").hexdigest()
    evidence["environment"]["production_target"] = "not coordinator.malibu.tech"
    evidence["steps"] = strict_spec032_steps()


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
        (root / "provider_prebeta_contract.txt").write_text("provider-prebeta-current-selector\n", encoding="utf-8")
        run("git", "init", cwd=root)
        run("git", "config", "user.name", "test", cwd=root)
        run("git", "config", "user.email", "test@example.com", cwd=root)
        run("git", "add", "specs/CONFORMANCE.json", "provider_prebeta_contract.txt", cwd=root)
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

    def test_validator_accepts_uncommitted_redacted_evidence(self) -> None:
        directory, root, source_commit, _ = self.make_repo()
        self.addCleanup(directory.cleanup)
        evidence_path = root / EVIDENCE_SOURCE
        evidence = json.loads(evidence_path.read_text(encoding="utf-8"))
        evidence["observations"]["precommit_capture_marker"] = "redacted-current-run"
        evidence_path.write_text(json.dumps(evidence, indent=2) + "\n", encoding="utf-8")

        completed = subprocess.run(
            [
                sys.executable,
                str(VALIDATOR),
                "--root",
                str(root),
                "--source-sha",
                source_commit,
                "--requirement-ids",
                "SPEC-010-R001",
                EVIDENCE_SOURCE,
            ],
            text=True,
            capture_output=True,
            check=False,
        )

        self.assertEqual(0, completed.returncode, completed.stderr)
        self.assertIn("validate-provider-prebeta-evidence: ok", completed.stdout)
        self.assertIn(hashlib.sha256(evidence_path.read_bytes()).hexdigest(), completed.stdout)

    def test_validator_rejects_missing_physical_step(self) -> None:
        directory, root, source_commit, _ = self.make_repo()
        self.addCleanup(directory.cleanup)
        evidence_path = root / EVIDENCE_SOURCE
        evidence = json.loads(evidence_path.read_text(encoding="utf-8"))
        evidence["steps"] = [step for step in evidence["steps"] if step["id"] != "step-05-hardware-evidence-verifier"]
        evidence_path.write_text(json.dumps(evidence, indent=2) + "\n", encoding="utf-8")

        completed = subprocess.run(
            [
                sys.executable,
                str(VALIDATOR),
                "--root",
                str(root),
                "--source-sha",
                source_commit,
                EVIDENCE_SOURCE,
            ],
            text=True,
            capture_output=True,
            check=False,
        )

        self.assertNotEqual(0, completed.returncode)
        self.assertIn("missing provider-prebeta step", completed.stderr)

    def test_validator_rejects_secret_bearing_fields(self) -> None:
        directory, root, source_commit, _ = self.make_repo()
        self.addCleanup(directory.cleanup)
        evidence_path = root / EVIDENCE_SOURCE
        evidence = json.loads(evidence_path.read_text(encoding="utf-8"))
        evidence["observations"]["bearer_token"] = "redacted-value"
        evidence_path.write_text(json.dumps(evidence, indent=2) + "\n", encoding="utf-8")

        completed = subprocess.run(
            [
                sys.executable,
                str(VALIDATOR),
                "--root",
                str(root),
                "--source-sha",
                source_commit,
                EVIDENCE_SOURCE,
            ],
            text=True,
            capture_output=True,
            check=False,
        )

        self.assertNotEqual(0, completed.returncode)
        self.assertIn("forbidden secret-bearing field name", completed.stderr)

    def test_validator_rejects_secret_like_values(self) -> None:
        directory, root, source_commit, _ = self.make_repo()
        self.addCleanup(directory.cleanup)
        evidence_path = root / EVIDENCE_SOURCE
        evidence = json.loads(evidence_path.read_text(encoding="utf-8"))
        evidence["observations"]["operator_note"] = "Authorization: Bearer abcdefghijklmnopqrstuvwxyz012345"
        evidence_path.write_text(json.dumps(evidence, indent=2) + "\n", encoding="utf-8")

        completed = subprocess.run(
            [
                sys.executable,
                str(VALIDATOR),
                "--root",
                str(root),
                "--source-sha",
                source_commit,
                EVIDENCE_SOURCE,
            ],
            text=True,
            capture_output=True,
            check=False,
        )

        self.assertNotEqual(0, completed.returncode)
        self.assertIn("forbidden secret-like value", completed.stderr)

    def test_validator_rejects_expired_evidence(self) -> None:
        directory, root, source_commit, _ = self.make_repo()
        self.addCleanup(directory.cleanup)
        evidence_path = root / EVIDENCE_SOURCE
        evidence = json.loads(evidence_path.read_text(encoding="utf-8"))
        evidence["expires_at"] = "2026-01-01"
        evidence_path.write_text(json.dumps(evidence, indent=2) + "\n", encoding="utf-8")

        completed = subprocess.run(
            [
                sys.executable,
                str(VALIDATOR),
                "--root",
                str(root),
                "--source-sha",
                source_commit,
                EVIDENCE_SOURCE,
            ],
            text=True,
            capture_output=True,
            check=False,
        )

        self.assertNotEqual(0, completed.returncode)
        self.assertIn("expires_at must not be in the past", completed.stderr)

    def test_validator_rejects_evidence_path_traversal(self) -> None:
        directory, root, source_commit, _ = self.make_repo()
        self.addCleanup(directory.cleanup)

        completed = subprocess.run(
            [
                sys.executable,
                str(VALIDATOR),
                "--root",
                str(root),
                "--source-sha",
                source_commit,
                "journeys/evidence/../evidence/provider-prebeta-admission-demo.redacted.json",
            ],
            text=True,
            capture_output=True,
            check=False,
        )

        self.assertNotEqual(0, completed.returncode)
        self.assertIn("must not contain parent traversal", completed.stderr)

    def test_validator_rejects_symlinked_evidence_source(self) -> None:
        directory, root, source_commit, _ = self.make_repo()
        self.addCleanup(directory.cleanup)
        symlink = root / "journeys" / "evidence" / "provider-prebeta-admission-symlink.redacted.json"
        try:
            symlink.symlink_to(root / EVIDENCE_SOURCE)
        except OSError as exc:
            raise unittest.SkipTest(f"symlinks are unavailable: {exc}") from exc

        completed = subprocess.run(
            [
                sys.executable,
                str(VALIDATOR),
                "--root",
                str(root),
                "--source-sha",
                source_commit,
                "journeys/evidence/provider-prebeta-admission-symlink.redacted.json",
            ],
            text=True,
            capture_output=True,
            check=False,
        )

        self.assertNotEqual(0, completed.returncode)
        self.assertIn("must not contain symlink components", completed.stderr)

    def test_validator_rejects_symlinked_evidence_parent(self) -> None:
        directory, root, source_commit, _ = self.make_repo()
        self.addCleanup(directory.cleanup)
        real_evidence_dir = root / "real-evidence"
        real_evidence_dir.mkdir()
        target = real_evidence_dir / "provider-prebeta-admission-demo.redacted.json"
        target.write_text((root / EVIDENCE_SOURCE).read_text(encoding="utf-8"), encoding="utf-8")
        shutil.rmtree(root / "journeys" / "evidence")
        try:
            (root / "journeys" / "evidence").symlink_to(real_evidence_dir)
        except OSError as exc:
            raise unittest.SkipTest(f"symlinks are unavailable: {exc}") from exc

        completed = subprocess.run(
            [
                sys.executable,
                str(VALIDATOR),
                "--root",
                str(root),
                "--source-sha",
                source_commit,
                EVIDENCE_SOURCE,
            ],
            text=True,
            capture_output=True,
            check=False,
        )

        self.assertNotEqual(0, completed.returncode)
        self.assertIn("must not contain symlink components", completed.stderr)

    def test_validator_rejects_stale_current_selector(self) -> None:
        directory, root, source_commit, _ = self.make_repo()
        self.addCleanup(directory.cleanup)
        (root / "provider_prebeta_contract.txt").write_text("provider-prebeta-current-selector changed\n", encoding="utf-8")

        completed = subprocess.run(
            [
                sys.executable,
                str(VALIDATOR),
                "--root",
                str(root),
                "--source-sha",
                source_commit,
                EVIDENCE_SOURCE,
            ],
            text=True,
            capture_output=True,
            check=False,
        )

        self.assertNotEqual(0, completed.returncode)
        self.assertIn("does not match current mapped selector", completed.stderr)

    def test_builder_rejects_secret_like_values(self) -> None:
        def leak_secret_like_value(evidence: dict) -> None:
            evidence["observations"]["operator_note"] = "Bearer abcdefghijklmnopqrstuvwxyz012345"

        directory, root, source_commit, evidence_commit = self.make_repo(leak_secret_like_value)
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
        self.assertIn("forbidden secret-like value", completed.stderr)

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

    def test_builder_allows_requirement_subset_covered_by_evidence(self) -> None:
        def evidence_covers_two_requirements(evidence: dict) -> None:
            evidence["requirement_ids"] = ["SPEC-010-R001", "SPEC-010-R002"]

        directory, root, source_commit, evidence_commit = self.make_repo(evidence_covers_two_requirements)
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
                "--requirement-ids",
                "SPEC-010-R001",
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
        self.assertEqual(["SPEC-010-R001"], payload["requirement_ids"])

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
        self.assertTrue(any("must cover every signed requirement ID" in error for error in result.errors), result.errors)

    def test_canonical_validator_rejects_signed_pass_when_source_artifact_failed(self) -> None:
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
        evidence_path = root / EVIDENCE_SOURCE
        evidence = json.loads(evidence_path.read_text(encoding="utf-8"))
        evidence["result"]["status"] = "fail"
        evidence["steps"][6]["status"] = "fail"
        evidence_path.write_text(json.dumps(evidence, indent=2) + "\n", encoding="utf-8")
        payload = json.loads(payload_path.read_text(encoding="utf-8"))
        payload["artifacts"][0]["sha256"] = hashlib.sha256(evidence_path.read_bytes()).hexdigest()
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
        self.assertTrue(any("source.result.status" in error for error in result.errors), result.errors)
        self.assertTrue(any("source.steps" in error for error in result.errors), result.errors)

    def test_canonical_validator_rejects_false_extra_source_redaction_flag(self) -> None:
        def extra_redaction_failed(evidence: dict) -> None:
            evidence["redaction"]["private_keys_redacted"] = False

        directory, root, source_commit, evidence_commit = self.make_repo(extra_redaction_failed)
        self.addCleanup(directory.cleanup)
        private_key = generate_acceptance_key(root)
        trusted_hash = hashlib.sha256((root / "security" / "acceptance-candidate-signing-public.pem").read_bytes()).hexdigest()
        payload = dict(base_evidence(source_commit))
        payload.update({
            "schema_version": "macprovider.journey-result.v1",
            "artifacts": [
                {
                    "id": "redacted-provider-prebeta-admission",
                    "sha256": hashlib.sha256((root / EVIDENCE_SOURCE).read_bytes()).hexdigest(),
                    "source": EVIDENCE_SOURCE,
                }
            ],
            "execution_mode": "physical-provider-prebeta-admission",
        })
        payload["redaction"] = {
            "secrets_redacted": True,
            "operator_identity_redacted": True,
            "local_account_names_redacted": True,
        }
        payload_path = root / "payload.json"
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
        self.assertTrue(any("source.redaction.private_keys_redacted" in error for error in result.errors), result.errors)

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
        self.assertIn("must be covered by evidence.requirement_ids", completed.stderr)

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

    def test_builder_emits_spec032_strict_matrix_payload(self) -> None:
        directory, root, source_commit, evidence_commit = self.make_repo(
            make_spec032_evidence,
            add_spec032_conformance,
        )
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
        self.assertEqual(["SPEC-032-R001", "SPEC-032-R002", "SPEC-032-R003"], payload["requirement_ids"])
        self.assertEqual({"name": "Augustas11/macprovider", "commit": source_commit}, payload["repository"])
        self.assertNotIn("coordinator_identity", payload["environment"])
        self.assertNotIn("production_target", payload["environment"])
        self.assertEqual("r001-over-ceiling", payload["steps"][0]["id"])
        self.assertEqual("r003-recovery-sweep", payload["steps"][-1]["id"])
        self.assertEqual("physical-provider-prebeta-admission", payload["execution_mode"])

    def test_builder_allows_spec032_subset_from_full_matrix_evidence(self) -> None:
        directory, root, source_commit, evidence_commit = self.make_repo(
            make_spec032_evidence,
            add_spec032_conformance,
        )
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
                "--requirement-ids",
                "SPEC-032-R002",
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
        self.assertEqual(["SPEC-032-R002"], payload["requirement_ids"])
        self.assertEqual(
            ["r002-expired", "r002-tuple-mismatch", "r002-missing-tuple"],
            [step["id"] for step in payload["steps"]],
        )

    def test_validator_rejects_spec032_dry_run_promotion(self) -> None:
        def dry_run(evidence: dict) -> None:
            make_spec032_evidence(evidence)
            evidence["result"]["class"] = "dry-run"
            evidence["result"]["promote"] = False

        directory, root, source_commit, _ = self.make_repo(dry_run, add_spec032_conformance)
        self.addCleanup(directory.cleanup)

        completed = subprocess.run(
            [
                sys.executable,
                str(VALIDATOR),
                "--root",
                str(root),
                "--source-sha",
                source_commit,
                EVIDENCE_SOURCE,
            ],
            text=True,
            capture_output=True,
            check=False,
        )

        self.assertNotEqual(0, completed.returncode)
        self.assertIn("dry-run provider-prebeta evidence cannot be promoted", completed.stderr)

    def test_builder_rejects_spec032_non_physical_environment(self) -> None:
        def non_physical(evidence: dict) -> None:
            make_spec032_evidence(evidence)
            evidence["environment"]["class"] = "isolated-in-process-acceptance-harness"

        directory, root, source_commit, evidence_commit = self.make_repo(non_physical, add_spec032_conformance)
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
        self.assertIn("environment.class must equal 'physical-provider-prebeta-admission'", completed.stderr)

    def test_builder_rejects_spec032_result_promotion_marker(self) -> None:
        def promotion_marker(evidence: dict) -> None:
            make_spec032_evidence(evidence)
            evidence["result"]["promote"] = True

        directory, root, source_commit, evidence_commit = self.make_repo(promotion_marker, add_spec032_conformance)
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
        self.assertIn("result contains unsupported promotion field(s): promote", completed.stderr)

    def test_builder_rejects_spec032_collateral_control_failure(self) -> None:
        def collateral_failure(evidence: dict) -> None:
            make_spec032_evidence(evidence)
            evidence["steps"][0]["control_after"]["routing_eligible"] = False

        directory, root, source_commit, evidence_commit = self.make_repo(collateral_failure, add_spec032_conformance)
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
        self.assertIn("control_after must remain routing-eligible and serving-capable", completed.stderr)

    def test_builder_rejects_spec032_raw_provider_fingerprint(self) -> None:
        def raw_fingerprint(evidence: dict) -> None:
            make_spec032_evidence(evidence)
            evidence["steps"][0]["subject_fingerprint"] = "provider:raw-local-machine-id"

        directory, root, source_commit, evidence_commit = self.make_repo(raw_fingerprint, add_spec032_conformance)
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
        self.assertIn("steps[0].subject_fingerprint has invalid format", completed.stderr)

    def test_builder_rejects_spec032_r003_without_sandbox_or_no_credentials(self) -> None:
        def missing_r003_proof(evidence: dict) -> None:
            make_spec032_evidence(evidence)
            evidence["steps"][6]["subject_after"]["admission_sandboxed"] = False
            evidence["steps"][6]["durable_provider_credentials_minted"] = True

        directory, root, source_commit, evidence_commit = self.make_repo(missing_r003_proof, add_spec032_conformance)
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
        self.assertIn("subject_after.admission_sandboxed must be true for R003", completed.stderr)

    def test_builder_rejects_spec032_advisory_bench_gate_reason(self) -> None:
        def advisory_reason(evidence: dict) -> None:
            make_spec032_evidence(evidence)
            evidence["steps"][0]["non_admission_reason"] = "bench_gate.min_sustained_tps"

        directory, root, source_commit, evidence_commit = self.make_repo(advisory_reason, add_spec032_conformance)
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
        self.assertIn("must not cite advisory bench_gate values", completed.stderr)

    def test_builder_rejects_spec032_wrong_reason_code(self) -> None:
        def wrong_reason(evidence: dict) -> None:
            make_spec032_evidence(evidence)
            evidence["steps"][3]["non_admission_reason"] = "autotune_model_cap_exceeded"

        directory, root, source_commit, evidence_commit = self.make_repo(wrong_reason, add_spec032_conformance)
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
        self.assertIn("non_admission_reason must equal 'autotune_evidence_stale_or_mismatched'", completed.stderr)

    def test_signed_spec032_strict_matrix_payload_passes_canonical_validator(self) -> None:
        directory, root, source_commit, evidence_commit = self.make_repo(
            make_spec032_evidence,
            add_spec032_conformance,
        )
        self.addCleanup(directory.cleanup)
        private_key = generate_acceptance_key(root)
        trusted_hash = hashlib.sha256((root / "security" / "acceptance-candidate-signing-public.pem").read_bytes()).hexdigest()
        payload = root / "payload.json"
        envelope = root / "journeys" / "evidence" / "provider-prebeta-admission-spec032-strict-canary-20260902T120000Z.spec-032-r001-spec-032-r002-spec-032-r003.journey-result.signed.json"
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
                "SPEC-032-R002",
                ["JOURNEY-PROVIDER-PREBETA-ADMISSION"],
                {source_commit},
                trusted_hash,
                openssl,
                "provider-prebeta-spec032",
                result,
            ),
            result.errors,
        )
        self.assertEqual([], result.errors)

    def test_signed_spec032_subset_from_full_matrix_passes_canonical_validator(self) -> None:
        directory, root, source_commit, evidence_commit = self.make_repo(
            make_spec032_evidence,
            add_spec032_conformance,
        )
        self.addCleanup(directory.cleanup)
        private_key = generate_acceptance_key(root)
        trusted_hash = hashlib.sha256((root / "security" / "acceptance-candidate-signing-public.pem").read_bytes()).hexdigest()
        payload = root / "payload.json"
        envelope = root / "journeys" / "evidence" / "provider-prebeta-admission-spec032-strict-canary-20260902T120000Z.spec-032-r002.journey-result.signed.json"
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
                "SPEC-032-R002",
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
                "SPEC-032-R002",
                ["JOURNEY-PROVIDER-PREBETA-ADMISSION"],
                {source_commit},
                trusted_hash,
                openssl,
                "provider-prebeta-spec032-subset",
                result,
            ),
            result.errors,
        )
        self.assertEqual([], result.errors)


if __name__ == "__main__":
    unittest.main()
