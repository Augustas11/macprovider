"""JOURNEY-NATIVE-MTP-SERVING / -RELEASE evidence contract (G10)."""

from __future__ import annotations

import copy
import json
import pathlib
import subprocess
import sys
import tempfile
import unittest
from datetime import datetime, timezone

ROOT = pathlib.Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / "scripts"))

import native_mtp_journey_evidence as contract  # noqa: E402
from scripts.tests import test_catalog_native_mtp_admission as sidecar_fixture  # noqa: E402

CAPTURED = "2026-10-06T12:00:00Z"
NOW = datetime(2026, 10, 7, tzinfo=timezone.utc)


def sidecar_and_policy() -> tuple[bytes, bytes]:
    policy = b'{"policy":"frozen r015"}'
    tuple_input = sidecar_fixture.tuple_input()
    tuple_input["entry"]["benchmark_policy_sha256"] = contract.sha256(policy)
    release = sidecar_fixture.release_input("streamvc-autotune-static-test", b"{}", b"{}")
    generator = contract._sidecar_generator()
    return generator.build(tuple_input, release), policy


def serving_checks() -> dict[str, dict[str, bool]]:
    checks: dict[str, dict[str, bool]] = {step: {"ran": True} for step in contract.SERVING_STEPS if step != contract.MXFP8_STEP}
    for _, step, check, _ in contract.OBSERVATION_SOURCES:
        checks[step][check] = True
    return checks


def step_bytes(step_id: str, checks: dict[str, bool], details: dict | None = None, status: str = "pass") -> bytes:
    return json.dumps({
        "schema_version": contract.STEP_SCHEMA, "step_id": step_id, "status": status,
        "checks": checks, "details": details or {},
    }, sort_keys=True).encode()


class Repo:
    def __init__(self, root: pathlib.Path):
        self.root = root
        self.git("init", "-q", "-b", "main")
        self.git("config", "user.email", "t@example.test")
        self.git("config", "user.name", "t")

    def git(self, *args: str) -> str:
        return subprocess.run(["git", *args], cwd=self.root, check=True, capture_output=True, text=True).stdout.strip()

    def write(self, relative: str, data: bytes) -> None:
        path = self.root / relative
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_bytes(data)

    def commit(self, message: str) -> str:
        self.git("add", "-A")
        self.git("commit", "-q", "-m", message)
        return self.git("rev-parse", "HEAD")

    def bundle(self, relative_dir: str, files: dict[str, bytes]) -> None:
        import shutil
        shutil.rmtree(self.root / relative_dir, ignore_errors=True)
        for relative, data in files.items():
            self.write(f"{relative_dir}/{relative}", data)
        self.write(f"{relative_dir}/{contract.MANIFEST_NAME}", contract.manifest_bytes(files))


class ServingEvidenceTest(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.repo = Repo(pathlib.Path(self.tmp.name))
        self.sidecar, self.policy = sidecar_and_policy()
        self.dir = "journeys/evidence/native-mtp-serving-20261006T120000Z"

    def tearDown(self):
        self.tmp.cleanup()

    def files(self, checks=None, details01=None) -> dict[str, bytes]:
        checks = checks or serving_checks()
        files = {"native-mtp-admission.json": self.sidecar, "r015-policy.json": self.policy}
        for step, step_checks in checks.items():
            details = (details01 if details01 is not None else {"entry_index": 0}) if step == "step-01-bind-tuple" else {}
            files[f"steps/{step}.json"] = step_bytes(step, step_checks, details)
        return files

    def compose(self, files) -> dict:
        self.repo.bundle(self.dir, files)
        return contract.compose_serving(contract.load_bundle(self.repo.root, self.dir), captured_at=CAPTURED)

    def test_compose_build_and_governance_round_trip(self):
        evidence = self.compose(self.files())
        self.assertEqual(evidence["requirement_ids"], contract.SERVING_REQUIREMENTS)
        self.assertEqual(len(evidence["steps"]), 14)
        self.assertIsNone(evidence["mxfp8"])
        self.assertTrue(evidence["observations"]["exact_greedy_token_parity_verified"])
        self.assertFalse(evidence["observations"]["cross_row_state_bleed_observed"])
        self.assertEqual(evidence["expires_at"], "2027-01-04T12:00:00Z")
        source = f"{self.dir}.redacted.json"
        self.repo.write(source, json.dumps(evidence, indent=2).encode())
        sha = self.repo.commit("evidence")
        payload = contract.build_payload(self.repo.root, "serving", source, source_sha=sha, evidence_sha=sha, now=NOW)
        self.assertEqual(payload["journey_id"], "JOURNEY-NATIVE-MTP-SERVING")
        self.assertEqual(contract.validate_signed_payload(self.repo.root, payload, "SPEC-048-R007", ["JOURNEY-NATIVE-MTP-SERVING"]), [])
        self.assertTrue(contract.validate_signed_payload(self.repo.root, payload, "SPEC-048-R014", ["JOURNEY-NATIVE-MTP-SERVING"]))
        overclaim = copy.deepcopy(payload)
        overclaim["requirement_ids"].append("SPEC-048-R014")
        self.assertTrue(contract.validate_signed_payload(self.repo.root, overclaim, "SPEC-048-R007", ["JOURNEY-NATIVE-MTP-SERVING"]))

    def test_a_failed_or_missing_check_cannot_compose(self):
        checks = serving_checks()
        checks["step-07-mixed-multirow"]["mixed_multirow_isolation"] = False
        with self.assertRaisesRegex(contract.NativeMTPEvidenceError, "did not pass"):
            self.compose(self.files(checks))
        checks = serving_checks()
        del checks["step-11-accounting"]["receipt_and_accounting_invariance"]
        with self.assertRaisesRegex(contract.NativeMTPEvidenceError, "receipt_and_accounting_invariance"):
            self.compose(self.files(checks))
        checks = serving_checks()
        del checks["step-10-warm-swap"]
        with self.assertRaisesRegex(contract.NativeMTPEvidenceError, "step-10-warm-swap"):
            self.compose(self.files(checks))

    def test_policy_and_tuple_bindings_are_recomputed(self):
        files = self.files()
        files["r015-policy.json"] = b'{"policy":"other"}'
        with self.assertRaisesRegex(contract.NativeMTPEvidenceError, "benchmark policy"):
            self.compose(files)
        with self.assertRaisesRegex(contract.NativeMTPEvidenceError, "entry_index"):
            self.compose(self.files(details01={"entry_index": 3}))

    def test_tampered_bundle_or_self_asserted_evidence_fails(self):
        evidence = self.compose(self.files())
        source = f"{self.dir}.redacted.json"
        forged = dict(evidence)
        forged["sidecar_sha256"] = "f" * 64
        with self.assertRaisesRegex(contract.NativeMTPEvidenceError, "sidecar_sha256"):
            contract.validate_evidence(self.repo.root, "serving", source, forged, now=NOW)
        (self.repo.root / self.dir / "r015-policy.json").write_bytes(b"tampered")
        with self.assertRaisesRegex(contract.NativeMTPEvidenceError, "does not match"):
            contract.validate_evidence(self.repo.root, "serving", source, evidence, now=NOW)

    def test_expired_evidence_fails(self):
        evidence = self.compose(self.files())
        with self.assertRaisesRegex(contract.NativeMTPEvidenceError, "expired"):
            contract.validate_evidence(
                self.repo.root, "serving", f"{self.dir}.redacted.json", evidence,
                now=datetime(2027, 2, 1, tzinfo=timezone.utc),
            )


class ReleaseEvidenceTest(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.repo = Repo(pathlib.Path(self.tmp.name))
        self.repo.write("README", b"base\n")
        self.base = self.repo.commit("base")
        self.repo.write("phase3-binary/feature.swift", b"let native = true\n")
        self.head = self.repo.commit("campaign")
        self.sidecar, _ = sidecar_and_policy()
        self.dir = "journeys/evidence/native-mtp-release-20261006T120000Z"

    def tearDown(self):
        self.tmp.cleanup()

    def bundle_files(self, review_overrides: dict | None = None) -> dict[str, bytes]:
        paths, paths_digest, diff_digest = contract.review_subject(self.repo.root, self.base, self.head, set())
        tree = self.repo.git("rev-parse", f"{self.head}^{{tree}}")
        attestation = json.dumps({"ref": "refs/heads/main", "object": {"sha": self.base, "type": "commit"}}).encode()
        files = {
            "native-mtp-admission.json": self.sidecar,
            "serving-journey-result.signed.json": b'{"signed":true}',
            "target-ref-attestation.json": attestation,
        }
        for step in contract.RELEASE_STEPS:
            details = {"entry_index": 0} if step == "step-03-final-binary-binding" else {}
            files[f"steps/{step}.json"] = step_bytes(step, {"ok": True}, details)
        for lane in contract.REVIEW_LANES:
            review = {
                "schema_version": contract.REVIEW_SCHEMA, "lane": lane, "reviewer_id": f"{lane}-lane",
                "tool_version": "codex", "production_repository": contract.REPOSITORY,
                "production_ref": "refs/heads/main", "target_commit": self.base,
                "target_ref_attestation_sha256": contract.sha256(attestation), "base_commit": self.base,
                "head_commit": self.head, "head_tree_oid": tree, "diff_sha256": diff_digest,
                "reviewed_paths_sha256": paths_digest, "captured_at": CAPTURED,
                "critical": 0, "high": 0, "medium": 0, "low": 2, "info": 1, "verdict": "approved",
            }
            review.update((review_overrides or {}).get(lane, {}))
            files[f"reviews/{lane}.json"] = json.dumps(review, sort_keys=True).encode()
        return files

    def compose(self, files) -> dict:
        self.repo.bundle(self.dir, files)
        return contract.compose_release(
            self.repo.root, contract.load_bundle(self.repo.root, self.dir), captured_at=CAPTURED,
            release_id="published-2026-10-06-native-mtp-v1", base_commit=self.base, head_commit=self.head,
            target_commit=self.base, build_sha256="b" * 64,
        )

    def test_release_evidence_recomputes_the_review_subject(self):
        evidence = self.compose(self.bundle_files())
        self.assertEqual(evidence["requirement_ids"], ["SPEC-048-R014"])
        self.assertEqual(evidence["expires_at"], "2026-11-05T12:00:00Z")
        source = f"{self.dir}.redacted.json"
        self.repo.write(source, json.dumps(evidence).encode())
        evidence_sha = self.repo.commit("release evidence")
        contract.validate_evidence(self.repo.root, "release", source, evidence, now=NOW)
        payload = contract.build_payload(self.repo.root, "release", source, source_sha=self.head, evidence_sha=evidence_sha, now=NOW)
        self.assertEqual(payload["requirement_ids"], ["SPEC-048-R014"])

    def test_a_finding_or_a_stale_diff_blocks_release_evidence(self):
        with self.assertRaisesRegex(contract.NativeMTPEvidenceError, "medium"):
            self.compose(self.bundle_files({"security": {"medium": 1}}))
        with self.assertRaisesRegex(contract.NativeMTPEvidenceError, "diff_sha256"):
            self.compose(self.bundle_files({"code": {"diff_sha256": "0" * 64}}))
        files = self.bundle_files()
        files["target-ref-attestation.json"] = json.dumps({"ref": "refs/heads/main", "object": {"sha": self.head}}).encode()
        with self.assertRaisesRegex(contract.NativeMTPEvidenceError, "target-ref-attestation"):
            self.compose(files)

    def test_base_must_be_the_target_and_a_strict_ancestor(self):
        evidence = self.compose(self.bundle_files())
        bad = dict(evidence, base_commit=self.head, target_commit=self.head)
        with self.assertRaises(contract.NativeMTPEvidenceError):
            contract.validate_release_git(self.repo.root, bad)


if __name__ == "__main__":
    unittest.main()
