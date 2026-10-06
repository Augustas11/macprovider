from __future__ import annotations

import contextlib
import copy
import hashlib
import io
import json
import os
import shutil
import subprocess
import sys
import tempfile
import unittest
from datetime import date, datetime, timezone
from pathlib import Path

from scripts.check_spec_governance import (
    PRIVACY_CLASS_BETA_JOURNEY_ID,
    ValidationResult,
    _signed_journey_result_satisfies,
    _validate_signed_journey_result,
)
from scripts.tests.test_journey_result_tools import generate_acceptance_key, load_promoter_module
from scripts.tests.test_spec_governance import base_repository, signed_journey_envelope, write_repository

REPO_ROOT = Path(__file__).resolve().parents[2]
SCRIPTS = REPO_ROOT / "scripts"
if str(SCRIPTS) not in sys.path:
    sys.path.insert(0, str(SCRIPTS))

import privacy_class_beta_journey_evidence as contract  # noqa: E402

if str(SCRIPTS / "tests") not in sys.path:
    sys.path.insert(0, str(SCRIPTS / "tests"))
import privacy_primary_fixture as primary_fixture  # noqa: E402

SOURCE = "journeys/evidence/privacy-class-beta-20261006T043016Z.redacted.json"
BUNDLE = "journeys/evidence/privacy-class-beta-20261006T043016Z"
SOURCE_SHA = "cab10eabb216394f1fcfd729330a4e656a840e0a"
SIGNER = SCRIPTS / "sign-journey-result.py"
NOW = datetime(2026, 10, 7, tzinfo=timezone.utc)


def remanifest(bundle_dir: Path) -> None:
    rows = []
    for path in sorted(bundle_dir.rglob("*"), key=lambda item: ("./" + item.relative_to(bundle_dir).as_posix()).encode()):
        relative = path.relative_to(bundle_dir).as_posix()
        if path.is_file() and relative != contract.MANIFEST_NAME:
            rows.append(f"{hashlib.sha256(path.read_bytes()).hexdigest()}  ./{relative}\n")
    (bundle_dir / contract.MANIFEST_NAME).write_text("".join(rows), encoding="utf-8")


class PrivacyClassBetaEvidenceTests(unittest.TestCase):
    pristine: tempfile.TemporaryDirectory | None = None

    @classmethod
    def setUpClass(cls) -> None:
        # The reviewed bundle plus synthetic primary/ exports from the real
        # extractor; the evidence object is recomposed from that bundle. Each
        # test works on a copy of this pristine root.
        cls.pristine = tempfile.TemporaryDirectory()
        root = Path(cls.pristine.name) / "repo"
        for relative in ("specs/CONFORMANCE.json", contract.JOURNEY_PATH, SOURCE):
            (root / relative).parent.mkdir(parents=True, exist_ok=True)
            shutil.copyfile(REPO_ROOT / relative, root / relative)
        shutil.copytree(REPO_ROOT / BUNDLE, root / BUNDLE)
        work = Path(cls.pristine.name) / "work"
        work.mkdir()
        primary_fixture.attach_primary(root / BUNDLE, work)
        evidence = contract.compose_evidence(root, BUNDLE)
        (root / SOURCE).write_text(json.dumps(evidence, indent=2) + "\n", encoding="utf-8")

    @classmethod
    def tearDownClass(cls) -> None:
        if cls.pristine is not None:
            cls.pristine.cleanup()

    def setUp(self) -> None:
        self.tmp: tempfile.TemporaryDirectory | None = None
        self.fresh()

    def fresh(self) -> None:
        if self.tmp is not None:
            self.tmp.cleanup()
        self.tmp = tempfile.TemporaryDirectory()
        self.root = Path(self.tmp.name) / "repo"
        shutil.copytree(Path(self.pristine.name) / "repo", self.root)
        self.evidence = json.loads((self.root / SOURCE).read_text(encoding="utf-8"))

    def tearDown(self) -> None:
        if self.tmp is not None:
            self.tmp.cleanup()

    def bundle_file(self, relative: str) -> Path:
        return self.root / BUNDLE / relative

    def mutate(self, relative: str, old: str, new: str) -> None:
        path = self.bundle_file(relative)
        text = path.read_text(encoding="utf-8")
        self.assertIn(old, text, relative)
        path.write_text(text.replace(old, new, 1), encoding="utf-8")
        remanifest(self.root / BUNDLE)

    def assert_rejected(self, evidence: dict, fragment: str) -> None:
        with self.assertRaises(contract.PrivacyEvidenceError) as caught:
            contract.validate_evidence(self.root, SOURCE, evidence)
        self.assertIn(fragment, str(caught.exception))

    def predicate_errors(self) -> dict[str, list[str]]:
        bundle = contract.load_bundle(self.root, BUNDLE)
        checks = contract.Checks(bundle)
        names = {name for names in contract.STEP_PREDICATES.values() for name in names}
        names |= {name for names in contract.OBSERVATION_PREDICATES.values() for name in names}
        return {name: checks.run(name) for name in sorted(names)}

    # -- committed evidence

    def test_evidence_validates_and_recomposes_exactly(self) -> None:
        contract.validate_evidence(self.root, SOURCE, self.evidence, now=NOW)
        self.assertEqual(self.evidence, contract.compose_evidence(self.root, BUNDLE))
        self.assertEqual({name: [] for name in self.predicate_errors()}, self.predicate_errors())

    def test_requirement_ids_are_the_mapped_set_minus_completion_exclusions(self) -> None:
        expected = [f"SPEC-049-R{index:03d}" for index in range(1, 23)]
        self.assertEqual(expected, contract.journey_requirement_ids(REPO_ROOT))
        self.assertEqual(expected, self.evidence["requirement_ids"])
        for excluded in contract.EXCLUDED_REQUIREMENT_IDS:
            self.assertNotIn(excluded, self.evidence["requirement_ids"])

    def test_release_identity_is_the_tested_binary(self) -> None:
        self.assertEqual("v1.8.215", self.evidence["release_tag"])
        self.assertEqual("d8327fdbbc8f64690015debec2774c22f3d1573669a1b2239cf5ebe8fee37c83", self.evidence["binary_sha256"])
        self.assertEqual("3214ffcc6b706507f9a268cfb400da5c74287ff6", self.evidence["code_cdhash"])
        self.assertEqual("YF7XNRJUG4", self.evidence["team_id"])
        self.assertEqual("live.malibu.provider.cli", self.evidence["signing_identifier"])

    # -- closed object

    def test_rejects_unknown_and_missing_keys(self) -> None:
        extra = dict(self.evidence, operator={"role": "x"})
        self.assert_rejected(extra, "must carry exactly")
        missing = dict(self.evidence)
        missing.pop("code_cdhash")
        self.assert_rejected(missing, "must carry exactly")

    def test_rejects_duplicate_keys(self) -> None:
        text = (self.root / SOURCE).read_text(encoding="utf-8")
        (self.root / SOURCE).write_text(text.replace('"team_id": "YF7XNRJUG4",', '"team_id": "YF7XNRJUG4", "team_id": "YF7XNRJUG4",', 1), encoding="utf-8")
        with self.assertRaises(contract.PrivacyEvidenceError) as caught:
            contract.load_evidence(self.root, SOURCE)
        self.assertIn("duplicate JSON object key", str(caught.exception))

    def test_rejects_wrong_requirement_ids(self) -> None:
        for ids in (
            self.evidence["requirement_ids"] + ["SPEC-049-R023"],
            self.evidence["requirement_ids"][1:],
            list(reversed(self.evidence["requirement_ids"])),
        ):
            self.assert_rejected(dict(self.evidence, requirement_ids=ids), "requirement_ids")

    def test_rejects_release_identity_drift(self) -> None:
        for key, value in (
            ("release_tag", "v1.8.216"),
            ("binary_sha256", "0" * 64),
            ("code_cdhash", "0" * 40),
            ("team_id", "ABCDEFGHIJ"),
            ("signing_identifier", "other.identifier"),
        ):
            self.assert_rejected(dict(self.evidence, **{key: value}), key)

    def test_rejects_expiry_beyond_ninety_days_or_before_capture(self) -> None:
        self.assert_rejected(dict(self.evidence, expires_at="2027-01-04T04:30:17Z"), "90 days")
        self.assert_rejected(dict(self.evidence, expires_at="2026-10-06T04:30:16Z"), "90 days")
        self.assert_rejected(dict(self.evidence, expires_at="2027-01-04"), "RFC3339")
        with self.assertRaises(contract.PrivacyEvidenceError):
            contract.validate_evidence(self.root, SOURCE, self.evidence, now=datetime(2027, 1, 5, tzinfo=timezone.utc))

    def test_rejects_captured_at_that_is_not_the_journey_start(self) -> None:
        self.assert_rejected(dict(self.evidence, captured_at="2026-10-06T04:30:17Z"), "captured_at")

    def test_rejects_step_order_duplicates_status_and_digests(self) -> None:
        steps = copy.deepcopy(self.evidence["steps"])
        swapped = steps[:]
        swapped[0], swapped[1] = swapped[1], swapped[0]
        self.assert_rejected(dict(self.evidence, steps=swapped), "numeric order")
        self.assert_rejected(dict(self.evidence, steps=steps[:-1]), "exactly once")
        duplicated = steps[:-1] + [steps[0]]
        self.assert_rejected(dict(self.evidence, steps=duplicated), "numeric order")
        failed = copy.deepcopy(steps)
        failed[3]["status"] = "fail"
        self.assert_rejected(dict(self.evidence, steps=failed), "status must be 'pass'")
        foreign = copy.deepcopy(steps)
        foreign[0]["artifact_sha256"] = "0" * 64
        self.assert_rejected(dict(self.evidence, steps=foreign), "resolve to a file in the reviewed bundle")
        other_file = copy.deepcopy(steps)
        other_file[0]["artifact_sha256"] = steps[1]["artifact_sha256"]
        self.assert_rejected(dict(self.evidence, steps=other_file), "must be the digest of")
        extra_field = copy.deepcopy(steps)
        extra_field[0]["note"] = "x"
        self.assert_rejected(dict(self.evidence, steps=extra_field), "exactly {step_id, status, artifact_sha256}")

    def test_rejects_self_asserted_or_missing_observations(self) -> None:
        for name in ("posture_verified_by_coordinator", "secret_or_canary_persisted"):
            observations = dict(self.evidence["observations"])
            observations[name] = not observations[name]
            self.assert_rejected(dict(self.evidence, observations=observations), name)
        observations = dict(self.evidence["observations"])
        observations.pop("dyld_env_inert_verified")
        self.assert_rejected(dict(self.evidence, observations=observations), "exactly the 35 contract booleans")
        observations = dict(self.evidence["observations"], extra_verified=True)
        self.assert_rejected(dict(self.evidence, observations=observations), "exactly the 35 contract booleans")
        observations = dict(self.evidence["observations"], dyld_env_inert_verified=1)
        self.assert_rejected(dict(self.evidence, observations=observations), "booleans")

    # -- bundle binding

    def test_rejects_bundle_tamper_unlisted_files_and_manifest_digest(self) -> None:
        path = self.bundle_file("step-06-sip-off-refused/result.txt")
        path.write_text("exit=0 conns_bytes=0\n", encoding="utf-8")
        self.assert_rejected(self.evidence, "does not match MANIFEST.sha256")
        remanifest(self.root / BUNDLE)
        self.assert_rejected(self.evidence, "redaction_manifest_sha256")
        self.bundle_file("extra.txt").write_text("x\n", encoding="utf-8")
        self.assert_rejected(self.evidence, "must list exactly the bundle files")

    def test_bundle_loader_rejects_paths_outside_the_evidence_prefix(self) -> None:
        for relative in ("/etc", "journeys/evidence/privacy-class-beta-x/../../..", "specs"):
            with self.assertRaises(contract.PrivacyEvidenceError):
                contract.load_bundle(self.root, relative)

    def test_rejects_symlinks_in_bundle(self) -> None:
        os.symlink(self.bundle_file("results.tsv"), self.bundle_file("link.txt"))
        self.assert_rejected(self.evidence, "symlinks")

    def test_recomputed_observations_fail_when_artifacts_disagree(self) -> None:
        cases = (
            ("step-01-bind-signed-release/spctl.txt", "source=Notarized Developer ID", "source=Developer ID", "bind_release"),
            ("step-02-privacy-mode-start/privacy-key-on-disk-sweep.json", '"match_count": 0', '"match_count": 1', "key_memory_only"),
            ("step-02-privacy-mode-start/posture-rejections.txt", "0", "1", "posture_verified"),
            ("step-03-debugger-attach-refused/summary.txt", "attached=0", "attached=1", "debugger"),
            ("step-04-core-dump-and-env-refused/env-MACPROVIDER_CB_TRACE/result.txt", "blackhole_connections=0", "blackhole_connections=1", "diag_env"),
            ("step-04-core-dump-and-env-refused/env-dyld/stderr.txt", "", "dyld: loaded\n", "dyld"),
            ("step-04-core-dump-and-env-refused/kv-disk-tier/stderr.txt", "kv_disk_tier_enabled", "other", "config_refusals"),
            ("step-05-unsigned-build-refused/resigned-adhoc/result.txt", "exit=78", "exit=0", "unsigned"),
            ("step-06-sip-off-refused/sip.txt", "disabled", "enabled", "sip_off"),
            ("step-07-canary-stream/canary-stream.meta", "exit=0", "exit=1", "stream"),
            ("step-08-canary-nonstream/disclosure.json", '"usage_privacy_exact": true', '"usage_privacy_exact": false', "nonstream"),
            ("step-08-canary-nonstream/canary-nonstream.stderr", "relays_observe_sizes_timing_and_token_counts", "relays_observe_sizes", "disclosure_exact"),
            ("step-09-redaction-sweep/forced-crash.txt", "core_file=none", "core_file=/cores/core.1", "core_dumps"),
            ("step-09-redaction-sweep/sweep-journey.json", '"match_count": 0', '"match_count": 1', "sweeps_clean"),
            ("step-09-redaction-sweep/receipts.json", '"x_macprovider_receipt_headers": 0', '"x_macprovider_receipt_headers": 1', "receipts"),
            ("step-10-downgrade-negatives/strip-header.code.json", "dispatches_since=0", "dispatches_since=1", "downgrade"),
            ("step-10-downgrade-negatives/truncated.stderr", "; do not resubmit", "", "tamper_truncate"),
            ("step-10-downgrade-negatives/no-failover.json", '{"journey-1839-privacy": 9}', '{"journey-1839-privacy": 8, "journey-1839-plain": 1}', "no_failover"),
            ("step-11-stale-posture-and-quarantine/status-after-stale.txt", "quarantine_count=0", "quarantine_count=1", "stale"),
            ("step-11-stale-posture-and-quarantine/status-after-restart.txt", "quarantine_count=1", "quarantine_count=0", "quarantine_durable"),
            ("step-12-kill-switch/held-reservation.txt", "rejected|privacy_class_disabled", "terminal|", "kill_switch"),
            ("step-12-kill-switch/plaintext.status", "200", "503", "unaffected"),
            ("step-13-enforce-canary/coordinator-settlement-config.txt", "mode: enforce", "mode: observe", "enforce_config"),
            ("step-13-enforce-canary/enforce.json", '"created_before_provider_validation": true', '"created_before_provider_validation": false', "enforce_snapshot"),
            ("step-13-enforce-canary/enforce.json", '"outcome": "relay_blind_settled"', '"outcome": "verified"', "enforce_verdict"),
            ("step-13-enforce-canary/enforce.json", '"payable_credits": 1', '"payable_credits": 0', "enforce_credit"),
            ("step-13-enforce-canary/enforce.json", '"debited_prompt_tokens": 85', '"debited_prompt_tokens": 86', "enforce_debit"),
            ("step-13-enforce-canary/counters-after.json", '"coordinator.db:verified_verdicts": 1', '"coordinator.db:verified_verdicts": 2', "counters"),
            ("step-14-no-capability-provider-excluded/excluded.json", '"relay_blind_reservations": 0', '"relay_blind_reservations": 1', "no_capability"),
            ("step-15-tampered-receipt-quarantined/quarantined.json", '"payable_credits": 0', '"payable_credits": 1', "receipt_quarantine"),
            ("step-15-tampered-receipt-quarantined/fault-build.txt", "Signature=adhoc", "Signature=other", "isolated_fault_build"),
            ("step-16-redaction-review/evidence-sweep.json", '"match_count": 0', '"match_count": 2', "review"),
            ("step-99-live-provider-untouched/live-after.txt", "listener_8080_pid=80036", "listener_8080_pid=1", "live_untouched"),
        )
        for relative, old, new, predicate in cases:
            with self.subTest(predicate=predicate, file=relative):
                self.fresh()
                if old == "":
                    path = self.bundle_file(relative)
                    path.write_text(new, encoding="utf-8")
                    remanifest(self.root / BUNDLE)
                else:
                    self.mutate(relative, old, new)
                checks = contract.Checks(contract.load_bundle(self.root, BUNDLE))
                self.assertTrue(checks.run(predicate), f"{predicate} must fail")
                # Every predicate feeds a step or a contract observation, so
                # composition must refuse the bundle as well.
                self.assertTrue(
                    any(predicate in names for names in contract.STEP_PREDICATES.values())
                    or any(predicate in names for names in contract.OBSERVATION_PREDICATES.values())
                )
        self.fresh()
        self.mutate("step-03-debugger-attach-refused/summary.txt", "attached=0", "attached=1")
        with self.assertRaises(contract.PrivacyEvidenceError):
            contract.compose_evidence(self.root, BUNDLE)

    def test_private_path_or_secret_left_in_bundle_fails_review(self) -> None:
        for text in ("/Users/someone/journey", "\\/Users\\/someone\\/x", "-----BEGIN EC " + "PRIVATE KEY-----", "operator@example.com", "10.1.2.3", "wss://coordinator.example.test/ws", "peer=staging-worker.internal", "addr=2001:db8::1"):
            with self.subTest(text=text):
                self.fresh()
                path = self.bundle_file("step-00b-verify-candidate/compat-id.err")
                path.write_text(text + "\n", encoding="utf-8")
                remanifest(self.root / BUNDLE)
                self.assertTrue(self.predicate_errors()["review"])
                self.assertFalse(contract.recompute(contract.load_bundle(self.root, BUNDLE))[1]["canary_absent_from_all_artifacts_verified"])

    def test_results_must_show_every_kit_step_passing(self) -> None:
        self.mutate("results.tsv", "step-05-unsigned-build-refused\tPASS", "step-05-unsigned-build-refused\tFAIL")
        with self.assertRaises(contract.PrivacyEvidenceError) as caught:
            contract.compose_evidence(self.root, BUNDLE)
        self.assertIn("step-05-unsigned-build-refused must be", str(caught.exception))

    # -- signed payload

    def projection(self) -> dict:
        evidence, data = contract.load_evidence(self.root, SOURCE)
        bundle = contract.validate_evidence(self.root, SOURCE, evidence)
        return contract.project_payload(evidence, SOURCE, hashlib.sha256(data).hexdigest(), bundle, source_sha=SOURCE_SHA, evidence_sha="1" * 40)

    def test_signed_payload_must_equal_the_builder_projection(self) -> None:
        signed = self.projection()
        self.assertEqual([], contract.validate_signed_payload(self.root, signed, "SPEC-049-R001", [PRIVACY_CLASS_BETA_JOURNEY_ID]))
        self.assertEqual("2027-01-03", signed["expires_at"])
        self.assertEqual(self.evidence["requirement_ids"], signed["requirement_ids"])
        for mutate in (
            lambda item: item["observations"].__setitem__("silent_downgrade_observed", True),
            lambda item: item.__setitem__("requirement_ids", item["requirement_ids"] + ["SPEC-049-R023"]),
            lambda item: item.__setitem__("expires_at", "2027-02-01"),
            lambda item: item["candidate_identity"].__setitem__("code_cdhash", "0" * 40),
            lambda item: item.__setitem__("harness", {"name": "x"}),
            lambda item: item["steps"].pop(),
        ):
            signed = self.projection()
            mutate(signed)
            self.assertTrue(contract.validate_signed_payload(self.root, signed, "SPEC-049-R001", [PRIVACY_CLASS_BETA_JOURNEY_ID]))
        signed = self.projection()
        signed["repository"]["commit"] = "2" * 40
        self.assertTrue(contract.validate_signed_payload(self.root, signed, "SPEC-049-R001", [PRIVACY_CLASS_BETA_JOURNEY_ID]))

    def test_signed_payload_cannot_name_excluded_requirements(self) -> None:
        signed = self.projection()
        for requirement_id in sorted(contract.EXCLUDED_REQUIREMENT_IDS):
            errors = contract.validate_signed_payload(self.root, signed, requirement_id, [PRIVACY_CLASS_BETA_JOURNEY_ID])
            self.assertTrue(any(f"cannot promote {requirement_id}" in error for error in errors), requirement_id)


class PrivacyClassBetaGovernanceTests(unittest.TestCase):
    def test_signed_result_is_evidence_only_for_conformance(self) -> None:
        envelope = {"schema_version": "macprovider.journey-result-envelope.v1", "signatures": [], "signed": {"journey_id": PRIVACY_CLASS_BETA_JOURNEY_ID}}
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            source = root / "journeys" / "evidence" / "privacy-class-beta-x.journey-result.signed.json"
            source.parent.mkdir(parents=True)
            source.write_text(json.dumps(envelope) + "\n", encoding="utf-8")
            requirement = {
                "requirement_id": "SPEC-049-R001",
                "journeys": [PRIVACY_CLASS_BETA_JOURNEY_ID],
                "evidence": [{"artifact": f"sha256:{hashlib.sha256(source.read_bytes()).hexdigest()}", "source": "journeys/evidence/privacy-class-beta-x.journey-result.signed.json"}],
            }
            result = ValidationResult()
            self.assertFalse(_signed_journey_result_satisfies(root, requirement, "SPEC-049-R001", result, trusted_public_key_sha256="", openssl_bin="openssl"))
            self.assertTrue(any("privacy-class beta journey-result is evidence-only" in error for error in result.errors))

    def test_promoter_rejects_privacy_class_beta_without_rewrite(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            write_repository(root, base_repository())
            commit = subprocess.check_output(["git", "rev-parse", "HEAD"], cwd=root, text=True).strip()
            generate_acceptance_key(root)
            evidence_path = root / "journeys" / "evidence" / "privacy-class-beta-x.journey-result.signed.json"
            envelope = signed_journey_envelope(commit)
            envelope["signed"]["journey_id"] = PRIVACY_CLASS_BETA_JOURNEY_ID
            evidence_path.write_text(json.dumps(envelope, indent=2) + "\n", encoding="utf-8")
            conformance_path = root / "specs" / "CONFORMANCE.json"
            original = conformance_path.read_text(encoding="utf-8")
            promoter = load_promoter_module()
            stderr = io.StringIO()
            with self.assertRaises(SystemExit), contextlib.redirect_stderr(stderr):
                promoter.promote(root, "SPEC-001-R001", "journeys/evidence/privacy-class-beta-x.journey-result.signed.json", base_ref="HEAD")
            self.assertIn(f"{PRIVACY_CLASS_BETA_JOURNEY_ID} is evidence-only", stderr.getvalue())
            self.assertEqual(original, conformance_path.read_text(encoding="utf-8"))

    def test_builder_signer_and_validator_round_trip_at_an_evidence_commit(self) -> None:
        head = subprocess.check_output(["git", "rev-parse", "HEAD"], cwd=REPO_ROOT, text=True).strip()
        openssl = shutil.which("openssl")
        if openssl is None:
            self.skipTest("openssl is required")
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory) / "clone"
            subprocess.run(["git", "clone", "--quiet", "--shared", "--no-checkout", str(REPO_ROOT), str(root)], check=True)
            subprocess.run(["git", "checkout", "--quiet", head, "--", "specs", "journeys", "security"], cwd=root, check=True)
            work = Path(directory) / "work"
            work.mkdir()
            primary_fixture.attach_primary(root / BUNDLE, work)
            evidence = contract.compose_evidence(root, BUNDLE)
            (root / SOURCE).write_text(json.dumps(evidence, indent=2) + "\n", encoding="utf-8")
            git = ["git", "-c", "user.name=fixture", "-c", "user.email=fixture@invalid", "-c", "commit.gpgsign=false"]
            subprocess.run([*git, "add", "--", "journeys"], cwd=root, check=True)
            subprocess.run([*git, "commit", "--quiet", "--no-verify", "-m", "fixture evidence"], cwd=root, check=True)
            evidence_sha = subprocess.check_output(["git", "rev-parse", "HEAD"], cwd=root, text=True).strip()
            private_key = generate_acceptance_key(root)
            payload_path = Path(directory) / "payload.json"
            payload = contract.build_payload(root, SOURCE, source_sha=SOURCE_SHA, evidence_sha=evidence_sha, now=NOW)
            if date.today() > date.fromisoformat(payload["expires_at"]):
                self.skipTest("committed privacy-class beta evidence has expired")
            payload_path.write_text(json.dumps(payload, indent=2) + "\n", encoding="utf-8")
            envelope = SOURCE.replace(".redacted.json", ".journey-result.signed.json")
            env = dict(os.environ, MACPROVIDER_ACCEPTANCE_SIGNING_KEY_PEM=private_key)
            subprocess.run(
                [sys.executable, str(SIGNER), "--root", str(root), "--input", str(payload_path), "--output", envelope, "--verified-at", "2026-10-06T05:00:00Z", "--openssl-bin", openssl],
                env=env,
                check=True,
                stdout=subprocess.DEVNULL,
            )
            trusted = hashlib.sha256((root / "security" / "acceptance-candidate-signing-public.pem").read_bytes()).hexdigest()
            for requirement_id in payload["requirement_ids"]:
                result = ValidationResult()
                ok = _validate_signed_journey_result(root, envelope, requirement_id, [PRIVACY_CLASS_BETA_JOURNEY_ID], set(), trusted, openssl, "evidence", result)
                self.assertTrue(ok, result.errors)

            forged = copy.deepcopy(payload)
            forged["observations"]["kill_switch_blocks_all_phases_verified"] = False
            payload_path.write_text(json.dumps(forged, indent=2) + "\n", encoding="utf-8")
            subprocess.run(
                [sys.executable, str(SIGNER), "--root", str(root), "--input", str(payload_path), "--output", envelope, "--force", "--verified-at", "2026-10-06T05:00:00Z", "--openssl-bin", openssl],
                env=env,
                check=True,
                stdout=subprocess.DEVNULL,
            )
            result = ValidationResult()
            self.assertFalse(_validate_signed_journey_result(root, envelope, "SPEC-049-R001", [PRIVACY_CLASS_BETA_JOURNEY_ID], set(), trusted, openssl, "evidence", result))
            self.assertTrue(any("builder projection" in error for error in result.errors), result.errors)


if __name__ == "__main__":
    unittest.main()
