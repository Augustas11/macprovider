from __future__ import annotations

import hashlib
import contextlib
import io
import json
import os
import shutil
import subprocess
import sys
import tempfile
import unittest
import importlib.util
from pathlib import Path

from scripts.check_spec_governance import validate_repository
from scripts.tests.test_spec_governance import (
    SPEC016_PAYOUT_JOURNEY_ID,
    SPEC016_PAYOUT_RUN_ID,
    apply_mutation,
    spec016_payout_signed_envelope,
    signed_journey_envelope,
    write_repository,
    base_repository,
)


REPO_ROOT = Path(__file__).resolve().parents[2]
SIGNER = REPO_ROOT / "scripts" / "sign-journey-result.py"
PROMOTER = REPO_ROOT / "scripts" / "promote-signed-journey-result.py"
PREFLIGHT = REPO_ROOT / "scripts" / "preflight-signed-journey-promotion.py"


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


def load_promoter_module():
    spec = importlib.util.spec_from_file_location("promote_signed_journey_result", PROMOTER)
    if spec is None or spec.loader is None:
        raise AssertionError("could not load promoter module")
    module = importlib.util.module_from_spec(spec)
    sys.path.insert(0, str(REPO_ROOT / "scripts"))
    try:
        spec.loader.exec_module(module)
    finally:
        sys.path.pop(0)
    return module


class JourneyResultToolsTests(unittest.TestCase):
    def test_signer_emits_validator_accepted_envelope(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            write_repository(root, base_repository())
            commit = subprocess.check_output(["git", "rev-parse", "HEAD"], cwd=root, text=True).strip()
            private_key = generate_acceptance_key(root)

            payload_path = root / "journey-payload.json"
            envelope = signed_journey_envelope(commit, signatures=[])
            payload_path.write_text(json.dumps(envelope["signed"], indent=2) + "\n", encoding="utf-8")
            evidence_path = root / "journeys" / "evidence" / "signed-result.json"
            env = os.environ.copy()
            env["MACPROVIDER_ACCEPTANCE_SIGNING_KEY_PEM"] = private_key
            openssl = shutil.which("openssl")
            if openssl is None:
                raise unittest.SkipTest("openssl is required")

            subprocess.run(
                [
                    sys.executable,
                    str(SIGNER),
                    "--root",
                    str(root),
                    "--input",
                    str(payload_path),
                    "--output",
                    "journeys/evidence/signed-result.json",
                    "--verified-at",
                    "2026-01-01T00:00:01Z",
                    "--openssl-bin",
                    openssl,
                ],
                env=env,
                check=True,
                stdout=subprocess.DEVNULL,
            )

            conformance_path = root / "specs" / "CONFORMANCE.json"
            conformance = json.loads(conformance_path.read_text(encoding="utf-8"))
            requirement = conformance["requirements"][0]
            requirement["state"] = "conformant"
            requirement["gap"] = None
            requirement["journeys"] = ["JOURNEY-BOOT"]
            digest = hashlib.sha256(evidence_path.read_bytes()).hexdigest()
            requirement["evidence"] = [
                {
                    "artifact": f"commit:{commit}",
                    "source": None,
                    "captured_at": "2026-01-01",
                    "expires_at": "2027-01-01",
                },
                {
                    "artifact": f"sha256:{digest}",
                    "source": "journeys/evidence/signed-result.json",
                    "captured_at": "2026-01-01",
                    "expires_at": "2027-01-01",
                },
            ]
            conformance_path.write_text(json.dumps(conformance, indent=2) + "\n", encoding="utf-8")
            trusted_hash = hashlib.sha256((root / "security" / "acceptance-candidate-signing-public.pem").read_bytes()).hexdigest()

            self.assertEqual([], validate_repository(root, trusted_journey_result_public_key_sha256=trusted_hash).errors)

    def test_signer_rejects_duplicate_key_input(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            write_repository(root, base_repository())
            private_key = generate_acceptance_key(root)
            payload_path = root / "journey-payload.json"
            payload_path.write_text(
                '{"schema_version":"macprovider.journey-result.v1","schema_version":"macprovider.journey-result.v1"}\n',
                encoding="utf-8",
            )
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
                    "journeys/evidence/signed-result.json",
                    "--verified-at",
                    "2026-01-01T00:00:01Z",
                    "--openssl-bin",
                    openssl,
                ],
                env=env,
                capture_output=True,
                text=True,
                check=False,
            )

            self.assertNotEqual(0, completed.returncode)
            self.assertIn("duplicate JSON object key", completed.stderr)
            self.assertFalse((root / "journeys" / "evidence" / "signed-result.json").exists())

    def test_promoter_writes_only_after_signed_gate_accepts(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            write_repository(root, base_repository())
            commit = subprocess.check_output(["git", "rev-parse", "HEAD"], cwd=root, text=True).strip()
            private_key = generate_acceptance_key(root)
            trusted_hash = hashlib.sha256((root / "security" / "acceptance-candidate-signing-public.pem").read_bytes()).hexdigest()
            conformance_path = root / "specs" / "CONFORMANCE.json"
            conformance = json.loads(conformance_path.read_text(encoding="utf-8"))
            conformance["requirements"][0]["journeys"] = ["JOURNEY-BOOT"]
            conformance_path.write_text(json.dumps(conformance, indent=2) + "\n", encoding="utf-8")
            payload_path = root / "journey-payload.json"
            envelope = signed_journey_envelope(commit, signatures=[])
            payload_path.write_text(json.dumps(envelope["signed"], indent=2) + "\n", encoding="utf-8")
            evidence_path = root / "journeys" / "evidence" / "signed-result.json"
            env = os.environ.copy()
            env["MACPROVIDER_ACCEPTANCE_SIGNING_KEY_PEM"] = private_key
            openssl = shutil.which("openssl")
            if openssl is None:
                raise unittest.SkipTest("openssl is required")
            subprocess.run(
                [
                    sys.executable,
                    str(SIGNER),
                    "--root",
                    str(root),
                    "--input",
                    str(payload_path),
                    "--output",
                    "journeys/evidence/signed-result.json",
                    "--verified-at",
                    "2026-01-01T00:00:01Z",
                    "--openssl-bin",
                    openssl,
                ],
                env=env,
                check=True,
                stdout=subprocess.DEVNULL,
            )

            promoter = load_promoter_module()
            with contextlib.redirect_stdout(io.StringIO()):
                promoter.promote(
                    root,
                    "SPEC-001-R001",
                    "journeys/evidence/signed-result.json",
                    base_ref="HEAD",
                    trusted_public_key_sha256=trusted_hash,
                )

            conformance = json.loads(conformance_path.read_text(encoding="utf-8"))
            requirement = conformance["requirements"][0]
            digest = hashlib.sha256(evidence_path.read_bytes()).hexdigest()
            self.assertEqual("conformant", requirement["state"])
            self.assertIsNone(requirement["gap"])
            self.assertIn({"artifact": f"commit:{commit}", "source": None, "captured_at": "2026-01-01", "expires_at": "2027-01-01"}, requirement["evidence"])
            self.assertIn(
                {
                    "artifact": f"sha256:{digest}",
                    "source": "journeys/evidence/signed-result.json",
                    "captured_at": "2026-01-01",
                    "expires_at": "2027-01-01",
                },
                requirement["evidence"],
            )
            self.assertEqual([], validate_repository(root, trusted_journey_result_public_key_sha256=trusted_hash).errors)

    def test_promoter_restores_ledger_when_gate_rejects(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            write_repository(root, base_repository())
            commit = subprocess.check_output(["git", "rev-parse", "HEAD"], cwd=root, text=True).strip()
            generate_acceptance_key(root)
            evidence_path = root / "journeys" / "evidence" / "signed-result.json"
            evidence_path.write_text(json.dumps(signed_journey_envelope(commit), indent=2) + "\n", encoding="utf-8")
            conformance_path = root / "specs" / "CONFORMANCE.json"
            original = conformance_path.read_text(encoding="utf-8")

            completed = subprocess.run(
                [
                    sys.executable,
                    str(PROMOTER),
                    "--root",
                    str(root),
                    "--base-ref",
                    "HEAD",
                    "SPEC-001-R001",
                    "journeys/evidence/signed-result.json",
                ],
                capture_output=True,
                text=True,
                check=False,
            )

            self.assertNotEqual(0, completed.returncode)
            self.assertIn("signed journey-result rejected", completed.stderr)
            self.assertEqual(original, conformance_path.read_text(encoding="utf-8"))

    def test_promoter_rejects_spec016_candidate_only_artifact_without_rewrite(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            repository = base_repository()
            apply_mutation(repository, {"operation": "valid_spec016_payout_signed_journey_result"})
            write_repository(root, repository)
            commit = subprocess.check_output(["git", "rev-parse", "HEAD"], cwd=root, text=True).strip()
            private_key = generate_acceptance_key(root)
            trusted_hash = hashlib.sha256((root / "security" / "acceptance-candidate-signing-public.pem").read_bytes()).hexdigest()
            candidate_path = root / "journeys" / "evidence" / "spec016-payout.candidate.json"
            candidate_path.write_text(
                json.dumps({
                    "schema_version": "macprovider.journey-result-candidate.v1",
                    "journey_id": SPEC016_PAYOUT_JOURNEY_ID,
                    "run_id": SPEC016_PAYOUT_RUN_ID,
                    "promotion_ready": False,
                }, indent=2) + "\n",
                encoding="utf-8",
            )
            artifact_record = {
                "id": "redacted-payout-address-journey",
                "sha256": hashlib.sha256(candidate_path.read_bytes()).hexdigest(),
                "source": "journeys/evidence/spec016-payout.candidate.json",
            }
            payload_path = root / "journey-payload.json"
            envelope = spec016_payout_signed_envelope(commit, artifact_record)
            payload_path.write_text(json.dumps(envelope["signed"], indent=2) + "\n", encoding="utf-8")
            env = os.environ.copy()
            env["MACPROVIDER_ACCEPTANCE_SIGNING_KEY_PEM"] = private_key
            openssl = shutil.which("openssl")
            if openssl is None:
                raise unittest.SkipTest("openssl is required")
            subprocess.run(
                [
                    sys.executable,
                    str(SIGNER),
                    "--root",
                    str(root),
                    "--input",
                    str(payload_path),
                    "--output",
                    "journeys/evidence/signed-result.json",
                    "--verified-at",
                    "2026-01-01T00:00:01Z",
                    "--openssl-bin",
                    openssl,
                ],
                env=env,
                check=True,
                stdout=subprocess.DEVNULL,
            )
            conformance_path = root / "specs" / "CONFORMANCE.json"
            original = conformance_path.read_text(encoding="utf-8")

            promoter = load_promoter_module()
            stderr = io.StringIO()
            with self.assertRaises(SystemExit), contextlib.redirect_stderr(stderr):
                promoter.promote(
                    root,
                    "SPEC-016-R002",
                    "journeys/evidence/signed-result.json",
                    base_ref="HEAD",
                    trusted_public_key_sha256=trusted_hash,
                )

            self.assertIn("SPEC-016 payout journey-result cannot promote candidate-only artifact files", stderr.getvalue())
            self.assertEqual(original, conformance_path.read_text(encoding="utf-8"))

    def test_promoter_does_not_trust_path_hijacked_openssl(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            write_repository(root, base_repository())
            conformance_path = root / "specs" / "CONFORMANCE.json"
            conformance = json.loads(conformance_path.read_text(encoding="utf-8"))
            conformance["requirements"][0]["journeys"] = ["JOURNEY-BOOT"]
            conformance_path.write_text(json.dumps(conformance, indent=2) + "\n", encoding="utf-8")
            commit = subprocess.check_output(["git", "rev-parse", "HEAD"], cwd=root, text=True).strip()
            generate_acceptance_key(root)
            evidence_path = root / "journeys" / "evidence" / "signed-result.json"
            evidence_path.write_text(json.dumps(signed_journey_envelope(commit), indent=2) + "\n", encoding="utf-8")
            fake_bin = root / "fake-bin"
            fake_bin.mkdir()
            fake_openssl = fake_bin / "openssl"
            fake_openssl.write_text("#!/bin/sh\nexit 0\n", encoding="utf-8")
            fake_openssl.chmod(0o755)
            env = os.environ.copy()
            env["PATH"] = f"{fake_bin}:{env.get('PATH', '')}"

            completed = subprocess.run(
                [
                    sys.executable,
                    str(PROMOTER),
                    "--root",
                    str(root),
                    "--base-ref",
                    "HEAD",
                    "SPEC-001-R001",
                    "journeys/evidence/signed-result.json",
                ],
                env=env,
                capture_output=True,
                text=True,
                check=False,
            )

            self.assertNotEqual(0, completed.returncode)
            self.assertIn("signed journey-result rejected", completed.stderr)

    def test_promoter_does_not_trust_ambient_openssl_bin(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            write_repository(root, base_repository())
            conformance_path = root / "specs" / "CONFORMANCE.json"
            conformance = json.loads(conformance_path.read_text(encoding="utf-8"))
            conformance["requirements"][0]["journeys"] = ["JOURNEY-BOOT"]
            conformance_path.write_text(json.dumps(conformance, indent=2) + "\n", encoding="utf-8")
            commit = subprocess.check_output(["git", "rev-parse", "HEAD"], cwd=root, text=True).strip()
            generate_acceptance_key(root)
            evidence_path = root / "journeys" / "evidence" / "signed-result.json"
            evidence_path.write_text(json.dumps(signed_journey_envelope(commit), indent=2) + "\n", encoding="utf-8")
            fake_openssl = root / "fake-openssl"
            fake_openssl.write_text("#!/bin/sh\nexit 0\n", encoding="utf-8")
            fake_openssl.chmod(0o755)
            env = os.environ.copy()
            env["OPENSSL_BIN"] = str(fake_openssl)

            completed = subprocess.run(
                [
                    sys.executable,
                    str(PROMOTER),
                    "--root",
                    str(root),
                    "--base-ref",
                    "HEAD",
                    "SPEC-001-R001",
                    "journeys/evidence/signed-result.json",
                ],
                env=env,
                capture_output=True,
                text=True,
                check=False,
            )

            self.assertNotEqual(0, completed.returncode)
            self.assertIn("signed journey-result rejected", completed.stderr)

    def test_promoter_rejects_untrusted_openssl_override(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            write_repository(root, base_repository())
            fake_openssl = root / "fake-openssl"
            fake_openssl.write_text("#!/bin/sh\nexit 0\n", encoding="utf-8")
            fake_openssl.chmod(0o755)

            completed = subprocess.run(
                [
                    sys.executable,
                    str(PROMOTER),
                    "--root",
                    str(root),
                    "--base-ref",
                    "HEAD",
                    "--openssl-bin",
                    str(fake_openssl),
                    "SPEC-001-R001",
                    "journeys/evidence/signed-result.json",
                ],
                capture_output=True,
                text=True,
                check=False,
            )

            self.assertNotEqual(0, completed.returncode)
            self.assertIn("trusted allowlist", completed.stderr)

    def test_promoter_rejects_absolute_evidence_source(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            write_repository(root, base_repository())
            source = root / "journeys" / "evidence" / "signed-result.json"
            completed = subprocess.run(
                [
                    sys.executable,
                    str(PROMOTER),
                    "--root",
                    str(root),
                    "--base-ref",
                    "HEAD",
                    "SPEC-001-R001",
                    str(source),
                ],
                capture_output=True,
                text=True,
                check=False,
            )

            self.assertNotEqual(0, completed.returncode)
            self.assertIn("repository-relative", completed.stderr)

    def test_promoter_requires_base_ref(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            write_repository(root, base_repository())
            completed = subprocess.run(
                [
                    sys.executable,
                    str(PROMOTER),
                    "--root",
                    str(root),
                    "SPEC-001-R001",
                    "journeys/evidence/signed-result.json",
                ],
                capture_output=True,
                text=True,
                check=False,
            )

            self.assertNotEqual(0, completed.returncode)
            self.assertIn("--base-ref", completed.stderr)

    def test_promoter_rejects_invalid_base_ref_without_rewrite(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            write_repository(root, base_repository())
            commit = subprocess.check_output(["git", "rev-parse", "HEAD"], cwd=root, text=True).strip()
            private_key = generate_acceptance_key(root)
            trusted_hash = hashlib.sha256((root / "security" / "acceptance-candidate-signing-public.pem").read_bytes()).hexdigest()
            conformance_path = root / "specs" / "CONFORMANCE.json"
            conformance = json.loads(conformance_path.read_text(encoding="utf-8"))
            conformance["requirements"][0]["journeys"] = ["JOURNEY-BOOT"]
            conformance_path.write_text(json.dumps(conformance, indent=2) + "\n", encoding="utf-8")
            original = conformance_path.read_text(encoding="utf-8")
            payload_path = root / "journey-payload.json"
            envelope = signed_journey_envelope(commit, signatures=[])
            payload_path.write_text(json.dumps(envelope["signed"], indent=2) + "\n", encoding="utf-8")
            env = os.environ.copy()
            env["MACPROVIDER_ACCEPTANCE_SIGNING_KEY_PEM"] = private_key
            openssl = shutil.which("openssl")
            if openssl is None:
                raise unittest.SkipTest("openssl is required")
            subprocess.run(
                [
                    sys.executable,
                    str(SIGNER),
                    "--root",
                    str(root),
                    "--input",
                    str(payload_path),
                    "--output",
                    "journeys/evidence/signed-result.json",
                    "--verified-at",
                    "2026-01-01T00:00:01Z",
                    "--openssl-bin",
                    openssl,
                ],
                env=env,
                check=True,
                stdout=subprocess.DEVNULL,
            )

            promoter = load_promoter_module()
            stderr = io.StringIO()
            with self.assertRaises(SystemExit), contextlib.redirect_stderr(stderr):
                promoter.promote(
                    root,
                    "SPEC-001-R001",
                    "journeys/evidence/signed-result.json",
                    base_ref="definitely-not-a-real-ref",
                    trusted_public_key_sha256=trusted_hash,
                )

            self.assertIn("cannot load specs/AUTHORITY.json", stderr.getvalue())
            self.assertEqual(original, conformance_path.read_text(encoding="utf-8"))

    def test_promoter_rejects_duplicate_key_ledger_without_rewrite(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            write_repository(root, base_repository())
            conformance_path = root / "specs" / "CONFORMANCE.json"
            malformed = conformance_path.read_text(encoding="utf-8").replace(
                '"requirements": [',
                '"requirements": [],\n  "requirements": [',
                1,
            )
            conformance_path.write_text(malformed, encoding="utf-8")

            completed = subprocess.run(
                [
                    sys.executable,
                    str(PROMOTER),
                    "--root",
                    str(root),
                    "--base-ref",
                    "HEAD",
                    "SPEC-001-R001",
                    "journeys/evidence/signed-result.json",
                ],
                capture_output=True,
                text=True,
                check=False,
            )

            self.assertNotEqual(0, completed.returncode)
            self.assertIn("duplicate JSON object key", completed.stderr)
            self.assertEqual(malformed, conformance_path.read_text(encoding="utf-8"))

    def test_preflight_rejects_stale_selector_without_signing(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            write_repository(root, base_repository())
            source_sha = subprocess.check_output(["git", "rev-parse", "HEAD"], cwd=root, text=True).strip()
            (root / "src" / "example.py").write_text("def example():\n    return False\n", encoding="utf-8")
            subprocess.run(["git", "add", "."], cwd=root, check=True)
            subprocess.run(["git", "commit", "-qm", "change mapped selector"], cwd=root, check=True)

            completed = subprocess.run(
                [
                    sys.executable,
                    str(PREFLIGHT),
                    "--root",
                    str(root),
                    "--source-sha",
                    source_sha,
                    "--requirement-ids",
                    "SPEC-001-R001",
                ],
                capture_output=True,
                text=True,
                check=False,
            )

            self.assertNotEqual(0, completed.returncode)
            self.assertIn("promotion preflight rejected", completed.stderr)
            self.assertIn("does not match current mapped selector fragment 'example'", completed.stderr)

    def test_preflight_accepts_fresh_selector(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            write_repository(root, base_repository())
            source_sha = subprocess.check_output(["git", "rev-parse", "HEAD"], cwd=root, text=True).strip()

            completed = subprocess.run(
                [
                    sys.executable,
                    str(PREFLIGHT),
                    "--root",
                    str(root),
                    "--source-sha",
                    source_sha,
                    "--requirement-ids",
                    "SPEC-001-R001",
                ],
                capture_output=True,
                text=True,
                check=False,
            )

            self.assertEqual(0, completed.returncode, completed.stderr)
            self.assertIn("match current selectors", completed.stdout)


if __name__ == "__main__":
    unittest.main()
