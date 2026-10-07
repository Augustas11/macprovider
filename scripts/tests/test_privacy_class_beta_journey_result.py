from __future__ import annotations

import contextlib
import copy
import base64
import hashlib
import importlib.util
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


SOURCE = "journeys/evidence/privacy-class-beta-20261006T043016Z.redacted.json"
BUNDLE = "journeys/evidence/privacy-class-beta-20261006T043016Z"
SOURCE_SHA = "cab10eabb216394f1fcfd729330a4e656a840e0a"
SIGNER = SCRIPTS / "sign-journey-result.py"
NOW = datetime(2026, 10, 7, tzinfo=timezone.utc)
EXTRACTOR = SCRIPTS / "lab" / "privacy-class-beta" / "extract-primary-evidence.py"


def load_extractor_module():
    spec = importlib.util.spec_from_file_location("privacy_class_beta_primary_extractor", EXTRACTOR)
    assert spec is not None and spec.loader is not None
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


def remanifest(bundle_dir: Path) -> None:
    rows = []
    for path in sorted(bundle_dir.rglob("*"), key=lambda item: ("./" + item.relative_to(bundle_dir).as_posix()).encode()):
        relative = path.relative_to(bundle_dir).as_posix()
        if path.is_file() and relative != contract.MANIFEST_NAME:
            rows.append(f"{hashlib.sha256(path.read_bytes()).hexdigest()}  ./{relative}\n")
    (bundle_dir / contract.MANIFEST_NAME).write_text("".join(rows), encoding="utf-8")


def json_bytes(value: object) -> bytes:
    return (json.dumps(value, sort_keys=True, separators=(",", ":")) + "\n").encode()


def v2_snapshot(captured_at: int, **rows_by_table: list[dict]) -> dict:
    tables = {}
    for table in contract.V2_DB_TABLES:
        columns = list(contract.V2_DB_COLUMNS[table])
        rows = [{column: row.get(column) for column in columns} for row in rows_by_table.get(table, [])]
        tables[table] = {"table": table, "columns": columns, "dropped_columns": [], "row_count": len(rows), "truncated": False, "rows": rows}
    return {"captured_at_unix": captured_at, "tables": tables}


def v2_bundle(manifest_name: str, summary: dict, sources: dict[str, bytes | dict], *, binding: bytes | None = None) -> contract.Bundle:
    files: dict[str, bytes] = {}
    provenance = []
    for kind, relative in contract.V2_SOURCE_CONTRACT[manifest_name].items():
        raw = sources[kind]
        data = raw if isinstance(raw, bytes) else json_bytes(raw)
        files[f"primary/v2/sources/{kind}{Path(relative).suffix}"] = data
        provenance.append({"kind": kind, "path": relative, "sha256": hashlib.sha256(data).hexdigest()})
    manifest = {
        "schema_version": contract.PRIMARY_SCHEMA,
        "profile": contract.V2_SOURCE_PROFILE,
        "provenance": {"raw_sources": provenance},
        "raw_source_sha256": "a" * 64,
        **summary,
    }
    files[f"primary/v2/{manifest_name}"] = json_bytes(manifest)
    if binding is not None:
        files["step-01-bind-signed-release/binding.txt"] = binding
    return contract.Bundle("fixture", files, b"")


class PrivacyClassBetaEvidenceTests(unittest.TestCase):
    pristine: tempfile.TemporaryDirectory | None = None

    @classmethod
    def setUpClass(cls) -> None:
        # The committed reviewed bundle, including its real primary/ exports.
        # Each test works on a copy of this pristine root.
        cls.pristine = tempfile.TemporaryDirectory()
        root = Path(cls.pristine.name) / "repo"
        for relative in ("specs/CONFORMANCE.json", contract.JOURNEY_PATH, contract.JOURNEY_PATH_V2, SOURCE):
            (root / relative).parent.mkdir(parents=True, exist_ok=True)
            shutil.copyfile(REPO_ROOT / relative, root / relative)
        shutil.copytree(REPO_ROOT / BUNDLE, root / BUNDLE)

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
        names = {name for step in contract.PROFILE_V1.step_ids for name in contract.STEP_PREDICATES[step]}
        names |= {name for observation in (*contract.PROFILE_V1.true_observations, *contract.PROFILE_V1.false_observations) for name in contract.OBSERVATION_PREDICATES[observation]}
        return {name: checks.run(name) for name in sorted(names)}

    # -- committed evidence

    def test_committed_evidence_validates_and_recomposes_exactly(self) -> None:
        contract.validate_evidence(self.root, SOURCE, self.evidence, now=NOW)
        self.assertEqual(self.evidence, contract.compose_evidence(self.root, BUNDLE))
        self.assertEqual({name: [] for name in self.predicate_errors()}, self.predicate_errors())

    def test_requirement_ids_are_the_mapped_set_minus_completion_exclusions(self) -> None:
        expected = [f"SPEC-049-R{index:03d}" for index in range(1, 23)]
        self.assertEqual(expected, contract.journey_requirement_ids(REPO_ROOT))
        self.assertEqual(expected, self.evidence["requirement_ids"])
        for excluded in contract.EXCLUDED_REQUIREMENT_IDS:
            self.assertNotIn(excluded, self.evidence["requirement_ids"])

    def test_v2_requirement_ids_cover_baseline_and_v2_extension(self) -> None:
        expected = [f"SPEC-049-R{index:03d}" for index in (*range(1, 23), *range(24, 29))]
        self.assertEqual(expected, contract.journey_requirement_ids(REPO_ROOT, contract.PROFILE_V2))
        self.assertNotIn("SPEC-049-R023", expected)

    def test_v1_evidence_cannot_overclaim_v2(self) -> None:
        v2 = copy.deepcopy(self.evidence)
        v2["schema_version"] = contract.EVIDENCE_SCHEMA_V2
        v2["journey_id"] = contract.JOURNEY_ID_V2
        v2["requirement_ids"] = contract.journey_requirement_ids(REPO_ROOT, contract.PROFILE_V2)
        v2["observations"] = {name: name in contract.PROFILE_V2.true_observations for name in (*contract.PROFILE_V2.true_observations, *contract.PROFILE_V2.false_observations)}
        self.assert_rejected(v2, "results.tsv must hold exactly")

    def test_v2_observation_shape_is_closed(self) -> None:
        base = copy.deepcopy(self.evidence)
        base["schema_version"] = contract.EVIDENCE_SCHEMA_V2
        base["journey_id"] = contract.JOURNEY_ID_V2
        base["requirement_ids"] = contract.journey_requirement_ids(REPO_ROOT, contract.PROFILE_V2)
        base["observations"] = {name: name in contract.PROFILE_V2.true_observations for name in (*contract.PROFILE_V2.true_observations, *contract.PROFILE_V2.false_observations)}

        missing = copy.deepcopy(base)
        missing["observations"].pop("identity_directory_signature_expiry_and_revocation_verified")
        self.assert_rejected(missing, "exactly the 51 contract booleans")

        extra = copy.deepcopy(base)
        extra["observations"]["unexpected_v2_observation"] = True
        self.assert_rejected(extra, "exactly the 51 contract booleans")

        wrong_type = copy.deepcopy(base)
        wrong_type["observations"]["expanded_v2_residual_disclosures_exact_verified"] = 1
        self.assert_rejected(wrong_type, "booleans")

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


class PrivacyClassBetaV2RawEvidenceTests(unittest.TestCase):
    @staticmethod
    def b64url(value: bytes) -> str:
        return base64.urlsafe_b64encode(value).decode().rstrip("=")

    def enrollment_fixture(self, *, mutate_second: bool = False) -> contract.Bundle:
        def enrollment(provider: str, identity: str, se: str, enrolled: int) -> dict:
            return {"provider_id": provider, "identity_fingerprint": identity, "se_fingerprint": se, "team_id": "YF7XNRJUG4", "signing_identifier": "live.malibu.provider.cli", "code_cdhash": "1" * 40, "binary_version": "1.8.215", "enrolled_at_unix": enrolled, "revoked_at_unix": None, "revoked_reason": None}

        def key(provider: str, kid: str, accepted: int) -> dict:
            return {"provider_id": provider, "kid": kid, "assigned_session": f"session-{provider}", "key_record_digest": f"digest-{provider}", "not_before_unix": accepted - 1, "expires_at_unix": 500, "accepted_at_unix": accepted, "revoked_at_unix": None, "revocation_retained_until_unix": None, "key_class": "privacy"}

        first = enrollment("provider-a", "A" * 43, "B" * 43, 20)
        second = enrollment("provider-b", "C" * 43, "D" * 43, 30)
        after_second_rows = [first, second]
        if mutate_second:
            after_second_rows = [first, second, enrollment("provider-c", "E" * 43, "F" * 43, 31)]
        attempts = [
            {"case": "first-admission", "status": 200, "provider_id": "provider-a", "response_excerpt": {"usage_macprovider_privacy": {"posture_verified_at_unix": 21}}},
            {"case": "second-admission", "status": 200, "provider_id": "provider-b", "response_excerpt": {"usage_macprovider_privacy": {"posture_verified_at_unix": 31}}},
            {"case": "cross-provider-reuse", "status": 409, "provider_id": "provider-c", "response_excerpt": {"error": {"code": "privacy_enrollment_key_in_use"}}},
            {"case": "failed-posture", "status": 409, "provider_id": "provider-d", "response_excerpt": {"error": {"code": "privacy_posture_signature_failure"}}},
        ]
        sources = {
            "enrollment_before": v2_snapshot(10),
            "enrollment_after_first": v2_snapshot(22, privacy_class_enrollment=[first], relay_blind_key_records=[key("provider-a", "kid-a", 19)]),
            "enrollment_after_second": v2_snapshot(32, privacy_class_enrollment=after_second_rows, relay_blind_key_records=[key("provider-a", "kid-a", 19), key("provider-b", "kid-b", 29)]),
            "enrollment_after_reuse": v2_snapshot(40, privacy_class_enrollment=[first, second], relay_blind_key_records=[key("provider-a", "kid-a", 19), key("provider-b", "kid-b", 29)]),
            "enrollment_after_failed_posture": v2_snapshot(50, privacy_class_enrollment=[first, second], relay_blind_key_records=[key("provider-a", "kid-a", 19), key("provider-b", "kid-b", 29)]),
            "enrollment_clients": {"captured_at_unix": 60, "attempts": attempts},
        }
        summary = {
            "enrollments": [
                {"provider_id": "provider-a", "identity_fingerprint": "A" * 43, "se_fingerprint": "B" * 43, "enrollment_committed_unix": 20, "posture_verified_unix": 21, "active_rows_for_provider": 1},
                {"provider_id": "provider-b", "identity_fingerprint": "C" * 43, "se_fingerprint": "D" * 43, "enrollment_committed_unix": 30, "posture_verified_unix": 31, "active_rows_for_provider": 1},
            ],
            "cross_provider_reuse": {"result_code": "privacy_enrollment_key_in_use", "quarantine_rows_created": 0, "enrollment_rows_created": 0},
            "failed_posture": {"result_code": "privacy_posture_signature_failure", "enrollment_rows_created": 0},
        }
        return v2_bundle("enrollment.json", summary, sources)

    def auto_fixture(self, *, remove_key: bool = False) -> contract.Bundle:
        binding = (REPO_ROOT / BUNDLE / "step-01-bind-signed-release" / "binding.txt").read_bytes()
        identity = contract.Checks(contract.Bundle("fixture", {"step-01-bind-signed-release/binding.txt": binding}, b"")).binding()
        names = ("automatic-eligible", "automatic-ineligible", "automatic-hardening-fallback", "explicit-optout", "explicit-relay-blind")
        requested = {
            "automatic-eligible": (None, None, "privacy", ["privacy_class"]),
            "automatic-ineligible": (None, None, "ordinary", []),
            "automatic-hardening-fallback": (None, None, "ordinary", []),
            "explicit-optout": (False, None, "ordinary", []),
            "explicit-relay-blind": (None, True, "plain_relay_blind", []),
        }
        launches, configs, sessions, summary = [], [], [], []
        for offset, name in enumerate(names):
            privacy, relay, outcome, claims = requested[name]
            launches.append({"name": name, "executable_sha256": identity["binary_sha256"], "arguments": {"privacy_class_beta": privacy, "relay_blind_enabled": relay}, "started_at_unix": 10 + offset})
            configs.append({"name": name, "privacy_class_requested": privacy, "relay_blind_requested": relay})
            sessions.append({"name": name, "provider_id": f"provider-{name}", "accepted_at_unix": 20 + offset, "claims": claims, "effective_mode": outcome})
            reasons = ["not_eligible"] if name == "automatic-ineligible" else ["configuration_changed"] if name == "automatic-hardening-fallback" else []
            summary.append({"name": name, "mode": "off" if privacy is False or relay is not None else "automatic", "source": "launch/config/session/log/db", "outcome": outcome, "bounded_reasons": reasons, "privacy_key_record_count": 1 if name == "automatic-eligible" else 0, "claims": claims, "mode_decision_unix": 10 + offset, "credentials_resolution_unix": 20 + offset})
        key = {"provider_id": "provider-automatic-eligible", "kid": "kid-auto", "assigned_session": "session-auto", "key_record_digest": "digest-auto", "not_before_unix": 9, "expires_at_unix": 100, "accepted_at_unix": 20, "revoked_at_unix": None, "revocation_retained_until_unix": None, "key_class": "privacy"}
        sources = {
            "auto_launch": {"cases": launches},
            "auto_config": {"cases": configs},
            "auto_sessions": {"cases": sessions},
            "auto_logs": {"lines": [
                {"name": "automatic-ineligible", "stream": "stderr", "line": "privacy_class auto_ineligible reasons=not_eligible"},
                {"name": "automatic-hardening-fallback", "stream": "stderr", "line": "privacy_class auto_hardening_failed reasons=configuration_changed"},
            ]},
            "auto_db_before": v2_snapshot(5),
            "auto_db_after": v2_snapshot(30, relay_blind_key_records=[] if remove_key else [key]),
        }
        return v2_bundle("auto-mode.json", {"cases": sorted(summary, key=lambda row: row["name"])}, sources, binding=binding)

    def reenroll_fixture(self, *, leave_key_active: bool = False) -> contract.Bundle:
        provider = "provider-reenroll"
        def enrollment(identity: str, enrolled: int, revoked: int | None = None) -> dict:
            return {"provider_id": provider, "identity_fingerprint": identity, "se_fingerprint": "S" * 43, "team_id": "YF7XNRJUG4", "signing_identifier": "live.malibu.provider.cli", "code_cdhash": "1" * 40, "binary_version": "1.8.215", "enrolled_at_unix": enrolled, "revoked_at_unix": revoked, "revoked_reason": "operator_reenroll" if revoked else None}
        def key(revoked: int | None) -> dict:
            return {"provider_id": provider, "kid": "kid-old", "assigned_session": "session-old", "key_record_digest": "digest-old", "not_before_unix": 1, "expires_at_unix": 100, "accepted_at_unix": 2, "revoked_at_unix": revoked, "revocation_retained_until_unix": 100 if revoked else None, "key_class": "privacy"}
        old, new = enrollment("O" * 43, 5), enrollment("N" * 43, 55)
        changed_key = key(None if leave_key_active else 20)
        changed_q = {"provider_id": provider, "reason": "privacy_enrollment_key_changed", "quarantined_at_unix": 20, "expires_at_unix": 30}
        retry_q = {"provider_id": provider, "reason": "privacy_enrollment_key_changed", "quarantined_at_unix": 35, "expires_at_unix": 45}
        old_revoked = enrollment("O" * 43, 5, 50)
        rejected = {"provider_id": provider, "assigned_session": "session-held", "key_record_digest": "digest-held", "kid": "kid-held", "model": "model", "expires_at_unix": 80, "state": "rejected", "created_at_unix": 10, "privacy_class": 1, "terminal_code": "relay_blind_key_expired", "terminal_at_unix": 50}
        operator = {"provider_id": provider, "cleared_at_unix": 50, "clear_generation": 1}
        sources = {
            "reenroll_initial": v2_snapshot(10, privacy_class_enrollment=[old], relay_blind_key_records=[key(None)]),
            "reenroll_key_change": v2_snapshot(20, privacy_class_enrollment=[old], relay_blind_key_records=[changed_key], privacy_class_quarantine=[changed_q]),
            "reenroll_expiry_retry": v2_snapshot(40, privacy_class_enrollment=[old], relay_blind_key_records=[key(20)], privacy_class_quarantine=[retry_q]),
            "reenroll_operator_clear": v2_snapshot(50, privacy_class_enrollment=[old_revoked], relay_blind_key_records=[key(20)], relay_blind_reservations=[rejected], privacy_class_operator_clear=[operator]),
            "reenroll_after": v2_snapshot(60, privacy_class_enrollment=[old_revoked, new], relay_blind_key_records=[key(20)]),
            "reenroll_clients": {"captured_at_unix": 70, "attempts": [{"case": "post-reenroll-admission", "status": 200, "provider_id": provider, "response_excerpt": {"usage_macprovider_privacy": {"posture_verified_at_unix": 56}}}]},
        }
        summary = {
            "initial": {"active_enrollment_rows": 1, "identity_fingerprint": "O" * 43},
            "key_change": {"quarantine_reason": "privacy_enrollment_key_changed", "privacy_key_records_revoked_count": 1, "active_enrollment_replacements": 0},
            "post_expiry_retry": {"quarantine_reason": "privacy_enrollment_key_changed"},
            "operator_reenroll": {"revoked_old_enrollment_count": 1, "held_privacy_reservations_rejected_count": 1, "quarantine_rows_remaining": 0},
            "after_reenroll": {"new_active_enrollment_rows": 1, "identity_fingerprint": "N" * 43},
        }
        return v2_bundle("reenroll.json", summary, sources)

    def test_v2_summary_without_bound_raw_sources_cannot_pass(self) -> None:
        manifest = {"schema_version": contract.PRIMARY_SCHEMA, "profile": contract.V2_SOURCE_PROFILE, "provenance": {"raw_sources": []}, "raw_source_sha256": "a" * 64, "enrollments": [], "cross_provider_reuse": {}, "failed_posture": {}}
        bundle = contract.Bundle("fixture", {"primary/v2/enrollment.json": json_bytes(manifest)}, b"")
        errors = contract.Checks(bundle, contract.PROFILE_V2).run("v2_enrollment")
        self.assertTrue(any("provenance kinds must be exactly" in error for error in errors), errors)

    def test_v2_enrollment_recomputes_and_source_mutation_changes_result(self) -> None:
        self.assertEqual([], contract.Checks(self.enrollment_fixture(), contract.PROFILE_V2).run("v2_enrollment"))
        errors = contract.Checks(self.enrollment_fixture(mutate_second=True), contract.PROFILE_V2).run("v2_enrollment")
        self.assertTrue(any("exactly one active enrollment" in error or "summary must equal" in error for error in errors), errors)

    def test_auto_and_reenroll_recompute_from_db_logs_and_client_captures(self) -> None:
        self.assertEqual([], contract.Checks(self.auto_fixture(), contract.PROFILE_V2).run("v2_auto_mode"))
        auto_errors = contract.Checks(self.auto_fixture(remove_key=True), contract.PROFILE_V2).run("v2_auto_mode")
        self.assertTrue(any("privacy key advertisement delta" in error for error in auto_errors), auto_errors)
        self.assertEqual([], contract.Checks(self.reenroll_fixture(), contract.PROFILE_V2).run("v2_key_change_reenroll"))
        reenroll_errors = contract.Checks(self.reenroll_fixture(leave_key_active=True), contract.PROFILE_V2).run("v2_key_change_reenroll")
        self.assertTrue(any("must revoke" in error for error in reenroll_errors), reenroll_errors)

    def test_compose_profile_is_explicit_and_defaults_to_v1(self) -> None:
        self.assertIs(contract.profile_for_name("v1"), contract.PROFILE_V1)
        self.assertIs(contract.profile_for_name("v2"), contract.PROFILE_V2)
        with self.assertRaises(contract.PrivacyEvidenceError):
            contract.profile_for_name("automatic")

    def same_studio_sip_off_fixture(self, mutation: str | None = None) -> contract.Bundle:
        binding = (REPO_ROOT / BUNDLE / "step-01-bind-signed-release" / "binding.txt").read_bytes()
        identity = contract.Checks(contract.Bundle("fixture", {"step-01-bind-signed-release/binding.txt": binding}, b"")).binding()
        base = "step-06-sip-off-refused"
        files = {
            "step-01-bind-signed-release/binding.txt": binding,
            f"{base}/sip.txt": b"System Integrity Protection status: disabled.\n",
            f"{base}/host.txt": f"hw.model: {identity['hardware_model']}\nLocalHostName: Malibu-Studio\n".encode(),
            f"{base}/stderr.txt": b"FATAL privacy_class_hardening_failed reasons=sip_disabled\n",
            f"{base}/conns.txt": b"",
            f"{base}/connection-observation.json": json_bytes({
                "schema": "macprovider.privacy-lab-v2.step06-connection-observation.v1",
                "listener": "127.0.0.1:19444",
                "accepted_connections": 0,
                "received_bytes": 0,
                "window_started_unix": 100,
                "window_ended_unix": 101,
                "known_limit": "helper-owned exact loopback listener during provider run window; not a global packet capture",
            }),
            f"{base}/result.txt": b"exit=78 conns_bytes=0\n",
        }
        raw_hashes = {
            name: hashlib.sha256(files[f"{base}/{name}"]).hexdigest()
            for name in ("sip.txt", "host.txt", "stderr.txt", "conns.txt", "connection-observation.json", "result.txt")
        }
        restored = {
            "schema": "macprovider.privacy-lab-v2.step06-restored-validation.v1",
            "step_id": "step-06-sip-off-refused",
            "physical_pass_claimed": False,
            "manual_step06_ready_for_import": True,
            "packet_sha256": "b" * 64,
            "offline_packet_public_projection": {
                "schema": "macprovider.privacy-lab-v2.step06-offline-packet-public-projection.v1",
                "step_id": "step-06-sip-off-refused",
                "candidate": {
                    "binary_sha256": identity["binary_sha256"],
                    "team_id": identity["team_id"],
                    "signing_identifier": identity["signing_identifier"],
                    "cdhash": identity["code_cdhash"],
                },
                "provider_config_sha256": identity["provider_config_sha256"],
                "binding_file_sha256": hashlib.sha256(binding).hexdigest(),
                "prepared_host": {
                    "local_hostname": "Malibu-Studio",
                    "hardware_model": identity["hardware_model"],
                    "sip_status": "System Integrity Protection status: enabled.",
                },
                "coordinator_listener": "127.0.0.1:19444",
            },
            "raw_artifact_sha256": raw_hashes,
            "restored_host": {
                "local_hostname": "Malibu-Studio",
                "hardware_model": identity["hardware_model"],
                "sip_status": "System Integrity Protection status: enabled.",
            },
            "known_network_observation_limit": "connection-observation.json proves the helper-owned loopback listener accepted zero connections on the reviewed coordinator endpoint during the run window; it is not a global packet capture or physical PASS",
        }
        if mutation == "missing_restored":
            return contract.Bundle("fixture", files, b"")
        if mutation == "pass_claim":
            restored["physical_pass_claimed"] = True
        elif mutation == "accepted_connection":
            files[f"{base}/connection-observation.json"] = json_bytes({
                "schema": "macprovider.privacy-lab-v2.step06-connection-observation.v1",
                "listener": "127.0.0.1:19444",
                "accepted_connections": 1,
                "received_bytes": 0,
                "window_started_unix": 100,
                "window_ended_unix": 101,
                "known_limit": "helper-owned exact loopback listener during provider run window; not a global packet capture",
            })
            restored["raw_artifact_sha256"]["connection-observation.json"] = hashlib.sha256(files[f"{base}/connection-observation.json"]).hexdigest()
        elif mutation == "hash_drift":
            restored["raw_artifact_sha256"]["stderr.txt"] = "0" * 64
        elif mutation == "sip_not_restored":
            restored["restored_host"]["sip_status"] = "System Integrity Protection status: disabled."
        elif mutation == "candidate_drift":
            restored["offline_packet_public_projection"]["candidate"]["cdhash"] = "0" * 40
        elif mutation == "config_drift":
            restored["offline_packet_public_projection"]["provider_config_sha256"] = "0" * 64
        elif mutation == "binding_drift":
            restored["offline_packet_public_projection"]["binding_file_sha256"] = "0" * 64
        elif mutation == "different_hardware":
            files[f"{base}/host.txt"] = b"hw.model: MacBookAir10,1\nLocalHostName: Malibu-Studio\n"
            restored["raw_artifact_sha256"]["host.txt"] = hashlib.sha256(files[f"{base}/host.txt"]).hexdigest()
        elif mutation == "prepared_host_drift":
            restored["offline_packet_public_projection"]["prepared_host"]["local_hostname"] = "Other-Studio"
        elif mutation == "listener_drift":
            restored["offline_packet_public_projection"]["coordinator_listener"] = "127.0.0.1:19445"
        elif mutation in {"boolean_connections", "boolean_bytes", "invalid_listener_port", "live_listener_port"}:
            observation = json.loads(files[f"{base}/connection-observation.json"])
            if mutation == "boolean_connections":
                observation["accepted_connections"] = False
            elif mutation == "boolean_bytes":
                observation["received_bytes"] = False
            else:
                listener = "127.0.0.1:99999" if mutation == "invalid_listener_port" else "127.0.0.1:8080"
                observation["listener"] = listener
                restored["offline_packet_public_projection"]["coordinator_listener"] = listener
            files[f"{base}/connection-observation.json"] = json_bytes(observation)
            restored["raw_artifact_sha256"]["connection-observation.json"] = hashlib.sha256(files[f"{base}/connection-observation.json"]).hexdigest()
        files[f"{base}/restored-validation.json"] = json_bytes(restored)
        return contract.Bundle("fixture", files, b"")

    def test_v2_accepts_same_studio_sip_off_only_with_restored_helper_proof(self) -> None:
        coherent = self.same_studio_sip_off_fixture()
        v1_errors = contract.Checks(coherent, contract.PROFILE_V1).run("sip_off")
        self.assertTrue(any("different Mac" in error for error in v1_errors), v1_errors)
        self.assertEqual([], contract.Checks(coherent, contract.PROFILE_V2).run("sip_off"))

        expected = {
            "missing_restored": "bundle file is missing",
            "pass_claim": "must not claim physical PASS",
            "accepted_connection": "must accept zero connections and zero bytes",
            "hash_drift": "hash for stderr.txt must match",
            "sip_not_restored": "must show SIP restored",
            "candidate_drift": "must bind the tested cdhash",
            "config_drift": "must bind the tested provider config",
            "binding_drift": "must bind the reviewed release binding file",
            "different_hardware": "v2 SIP-off host must be the designated Studio hardware",
            "prepared_host_drift": "prepared host must match the restored host name",
            "listener_drift": "projected listener must match the observed listener",
            "boolean_connections": "as integer counts",
            "boolean_bytes": "as integer counts",
            "invalid_listener_port": "must bind a non-live loopback listener",
            "live_listener_port": "must bind a non-live loopback listener",
        }
        for mutation, message in expected.items():
            with self.subTest(mutation=mutation):
                errors = contract.Checks(self.same_studio_sip_off_fixture(mutation), contract.PROFILE_V2).run("sip_off")
                self.assertTrue(any(message in error for error in errors), errors)

    def release_fixture(self, *, tamper_signature: bool = False, valid_failed_metadata: bool = False) -> tuple[contract.Bundle, str]:
        binding = (REPO_ROOT / BUNDLE / "step-01-bind-signed-release" / "binding.txt").read_bytes()
        base = contract.Bundle("fixture", {"step-01-bind-signed-release/binding.txt": binding}, b"")
        identity = contract.Checks(base).binding()
        approved = {"team_id": identity["team_id"], "signing_identifier": identity["signing_identifier"], "code_cdhash": identity["code_cdhash"], "binary_version": identity["binary_version"]}
        metadata = {
            "provider_code_identity": {
                "asset": f"macprovider-cli-v{identity['binary_version']}-darwin-arm64.tar.gz",
                "member": "macprovider-cli",
                "binary_version": identity["binary_version"],
                "binary_sha256": identity["binary_sha256"],
                "team_id": identity["team_id"],
                "signing_identifier": identity["signing_identifier"],
                "slices": [{"arch": "arm64", "code_cdhash": identity["code_cdhash"]}],
            }
        }
        payload = json_bytes(metadata)
        invalid_payload = payload if valid_failed_metadata else json_bytes({})
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            private = root / "private.pem"
            public = root / "public.pem"
            message = root / "metadata.json"
            signature = root / "metadata.sig"
            invalid_message = root / "invalid.json"
            invalid_signature = root / "invalid.sig"
            subprocess.run(["openssl", "genpkey", "-algorithm", "EC", "-pkeyopt", "ec_paramgen_curve:P-256", "-out", str(private)], check=True, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
            subprocess.run(["openssl", "pkey", "-in", str(private), "-pubout", "-out", str(public)], check=True, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
            message.write_bytes(payload)
            invalid_message.write_bytes(invalid_payload)
            subprocess.run(["openssl", "dgst", "-sha256", "-sign", str(private), "-out", str(signature), str(message)], check=True, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
            subprocess.run(["openssl", "dgst", "-sha256", "-sign", str(private), "-out", str(invalid_signature), str(invalid_message)], check=True, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
            public_bytes, signature_bytes, invalid_signature_bytes = public.read_bytes(), signature.read_bytes(), invalid_signature.read_bytes()
        if tamper_signature:
            signature_bytes = bytes([signature_bytes[0] ^ 1]) + signature_bytes[1:]
        provider = "provider-release"
        active_key = {"provider_id": provider, "kid": "kid", "assigned_session": "session", "key_record_digest": "digest", "not_before_unix": 1, "expires_at_unix": 500, "accepted_at_unix": 2, "revoked_at_unix": None, "revocation_retained_until_unix": None, "key_class": "privacy"}
        revoked_key = {**active_key, "revoked_at_unix": 20, "revocation_retained_until_unix": 500}
        eligibility = {
            "approved": {"approved_code_identities": [approved], "denied_cdhashes": [], "metadata_directory_present": True, "provider_id": provider, "client_status": 200, "client_response_excerpt": {"usage_macprovider_privacy": {"posture_verified_at_unix": 10}}},
            "denied": {"approved_code_identities": [approved], "denied_cdhashes": [identity["code_cdhash"]], "metadata_directory_present": True, "provider_id": provider, "client_status": 409, "client_response_excerpt": {"error": {"code": "posture_denied_code_identity"}}},
            "withdrawn": {"approved_code_identities": [], "denied_cdhashes": [], "metadata_directory_present": False, "provider_id": provider, "client_status": 409, "client_response_excerpt": {"error": {"code": "posture_code_identity"}}},
            "invalid_metadata": {"approved_code_identities": [], "denied_cdhashes": [], "metadata_directory_present": True, "provider_id": provider, "client_status": 409, "client_response_excerpt": {"error": {"code": "posture_code_identity"}}},
        }
        sources = {
            "release_metadata": payload,
            "release_signature": signature_bytes,
            "release_invalid_metadata": invalid_payload,
            "release_invalid_signature": invalid_signature_bytes,
            "release_public_key": public_bytes,
            "release_file_stats": {"metadata": {"regular": True, "symlink": False, "bytes": len(payload)}, "signature": {"regular": True, "symlink": False, "bytes": len(signature_bytes)}, "public_key": {"regular": True, "symlink": False, "bytes": len(public_bytes)}},
            "release_eligibility": eligibility,
            "release_approved_db": v2_snapshot(10, relay_blind_key_records=[active_key]),
            "release_denied_db": v2_snapshot(20, relay_blind_key_records=[revoked_key], privacy_class_quarantine=[{"provider_id": provider, "reason": "posture_denied_code_identity", "quarantined_at_unix": 20, "expires_at_unix": 120}]),
            "release_withdrawn_db": v2_snapshot(30, relay_blind_key_records=[revoked_key]),
        }
        summary = {
            "approved_identity": approved,
            "metadata": {"signature_result": "verified", "regular_file": True, "signature_regular_file": True, "failed_metadata_identity_count": 0},
            "eligibility": {"before_withdrawal": "eligible", "after_denied_cdhash": "quarantined", "after_withdrawal_or_expiry": "ineligible"},
        }
        return v2_bundle("release-derived-approval.json", summary, sources, binding=binding), hashlib.sha256(public_bytes).hexdigest()

    def test_release_signature_requires_trusted_key_and_exact_bytes(self) -> None:
        coherent, fixture_key_digest = self.release_fixture()
        self.assertEqual([], contract.Checks(coherent, contract.PROFILE_V2, trusted_release_public_key_sha256=fixture_key_digest).run("v2_release_approval"))
        wrong_pin = contract.Checks(coherent, contract.PROFILE_V2).run("v2_release_approval")
        self.assertTrue(any("repository-trusted release signing key" in error for error in wrong_pin), wrong_pin)
        tampered, fixture_key_digest = self.release_fixture(tamper_signature=True)
        errors = contract.Checks(tampered, contract.PROFILE_V2, trusted_release_public_key_sha256=fixture_key_digest).run("v2_release_approval")
        self.assertTrue(any("cryptographically verify" in error for error in errors), errors)
        valid_failed, fixture_key_digest = self.release_fixture(valid_failed_metadata=True)
        errors = contract.Checks(valid_failed, contract.PROFILE_V2, trusted_release_public_key_sha256=fixture_key_digest).run("v2_release_approval")
        self.assertTrue(any("fail the provider identity schema" in error for error in errors), errors)

    def directory_fixture(self, mutation: str | None = None) -> contract.Bundle:
        active_public, _ = contract.ed25519_sign(b"A" * 32, b"identity")
        revoked_public, _ = contract.ed25519_sign(b"B" * 32, b"identity")
        def entry(public: bytes, enrolled: int, revoked: bool) -> dict:
            return {
                "identity_public_key": self.b64url(public),
                "fingerprint": self.b64url(hashlib.sha256(public).digest()),
                "se_public_key_fingerprint": self.b64url(hashlib.sha256(b"se-" + public).digest()),
                "source": "enrolled",
                "enrolled_at_unix": enrolled,
                "revoked": revoked,
            }

        entries = [
            entry(public, enrolled, revoked)
            for public, enrolled, revoked in ((active_public, 50, False), (revoked_public, 60, True))
        ]
        entries.sort(key=lambda row: row["fingerprint"])
        store = {
            "enrollments": [
                {"provider_id": "provider-active", "identity_fingerprint": next(row["fingerprint"] for row in entries if not row["revoked"]), "se_fingerprint": next(row["se_public_key_fingerprint"] for row in entries if not row["revoked"]), "enrolled_at_unix": next(row["enrolled_at_unix"] for row in entries if not row["revoked"]), "revoked_at_unix": None},
                {"provider_id": "provider-revoked", "identity_fingerprint": next(row["fingerprint"] for row in entries if row["revoked"]), "se_fingerprint": next(row["se_public_key_fingerprint"] for row in entries if row["revoked"]), "enrolled_at_unix": next(row["enrolled_at_unix"] for row in entries if row["revoked"]), "revoked_at_unix": 90},
            ],
            "quarantined_provider_ids": [],
        }
        if mutation == "malformed_se":
            entries[0]["se_public_key_fingerprint"] = "not-base64url"
        elif mutation == "extra_enrolled":
            extra_public, _ = contract.ed25519_sign(b"E" * 32, b"identity")
            entries.append(entry(extra_public, 70, False))
            entries.sort(key=lambda row: row["fingerprint"])
        elif mutation == "missing_enrolled":
            entries = entries[:1]
        elif mutation == "se_mismatch":
            entries[0]["se_public_key_fingerprint"] = self.b64url(b"M" * 32)
        elif mutation == "timestamp_mismatch":
            entries[0]["enrolled_at_unix"] += 1
        elif mutation == "operator_pin":
            entries[0]["source"] = "operator_pin"
        elif mutation == "boolean_timestamp":
            entries[0]["enrolled_at_unix"] = True
        elif mutation == "duplicate_store_rows":
            store["enrollments"].append(dict(store["enrollments"][0]))
        payload_doc = {"version": "privacy-identity-directory-v1", "privacy_class": contract.PRIVACY_CLASS, "issued_at_unix": 100, "expires_at_unix": 400, "entries": entries}
        if mutation == "boolean_issued":
            payload_doc["issued_at_unix"] = True
            payload_doc["expires_at_unix"] = 301
        payload = json.dumps(payload_doc, sort_keys=True, separators=(",", ":")).encode()
        directory_public, signature = contract.ed25519_sign(b"D" * 32, contract._frame(b"macprovider/spec049/identity-directory/v1") + contract._frame(payload))
        envelope = {
            "version": "privacy-identity-directory-envelope-v1",
            "key_id": self.b64url(hashlib.sha256(directory_public).digest()),
            "payload": self.b64url(payload),
            "signature": self.b64url(signature),
        }
        envelope_raw = json_bytes(envelope)
        gateway_raw = envelope_raw
        public_capture = {"algorithm": "ed25519", "public_key": self.b64url(directory_public)}
        headers = {"status": 200, "cache_control": "no-store", "content_type": "application/json", "captured_at_unix": 200, "store_error_code": "privacy_class_unavailable"}
        if mutation == "tampered":
            payload_doc["privacy_class"] = "tampered"
            envelope["payload"] = self.b64url(json.dumps(payload_doc, sort_keys=True, separators=(",", ":")).encode())
            envelope_raw = json_bytes(envelope)
            gateway_raw = envelope_raw
        elif mutation == "wrong_key":
            wrong_public, _ = contract.ed25519_sign(b"W" * 32, b"wrong")
            public_capture["public_key"] = self.b64url(wrong_public)
        elif mutation == "expired":
            headers["captured_at_unix"] = 400
        elif mutation == "revoked":
            store["quarantined_provider_ids"] = ["provider-active"]
        elif mutation == "body_mismatch":
            gateway_raw += b"\n"
        elif mutation == "boolean_header_captured":
            headers["captured_at_unix"] = True
        clients = {
            "captured_at_unix": 400,
            "attempts": [
                {"case": case, "accepted": False, "error_code": f"privacy_directory_{case}"}
                for case in ("tampered", "expired", "revoked", "wrong_key")
            ],
        }
        if mutation == "boolean_client_captured":
            clients["captured_at_unix"] = True
        sources = {
            "directory_envelope": envelope_raw,
            "directory_public_key": public_capture,
            "directory_gateway_body": gateway_raw,
            "directory_gateway_headers": headers,
            "directory_clients": clients,
            "directory_store": store,
            "directory_disclosure": {"residual_risks": list(contract.PRIVACY_RESIDUAL_RISKS_V2)},
        }
        summary = {
            "directory": {"signature_result": "verified", "public_key_pin": self.b64url(directory_public), "key_id": self.b64url(hashlib.sha256(directory_public).digest()), "entry_count": 2, "revoked_entry_count": 1, "ttl_seconds": 300, "body_sha256": hashlib.sha256(json_bytes({"version": "privacy-identity-directory-envelope-v1", "key_id": self.b64url(hashlib.sha256(directory_public).digest()), "payload": self.b64url(payload), "signature": self.b64url(signature)})).hexdigest()},
            "client_rejections": {case: "rejected" for case in sorted(("tampered", "expired", "revoked", "wrong_key"))},
            "gateway": {"body_sha256": hashlib.sha256(json_bytes({"version": "privacy-identity-directory-envelope-v1", "key_id": self.b64url(hashlib.sha256(directory_public).digest()), "payload": self.b64url(payload), "signature": self.b64url(signature)})).hexdigest(), "cache_control": "no-store", "store_error_code": "privacy_class_unavailable"},
            "disclosure": {"residual_risks": list(contract.PRIVACY_RESIDUAL_RISKS_V2)},
        }
        return v2_bundle("directory.json", summary, sources)

    def test_directory_recomputes_crypto_expiry_revocation_and_body_identity(self) -> None:
        self.assertEqual([], contract.Checks(self.directory_fixture(), contract.PROFILE_V2).run("v2_directory"))
        expected = {
            "tampered": "directory signature must verify",
            "wrong_key": "directory signature must verify",
            "expired": "gateway capture must be fresh",
            "revoked": "exactly match store identity/SE/enrollment/revocation facts",
            "body_mismatch": "byte-identical",
            "malformed_se": "canonical 32-byte SE fingerprints",
            "extra_enrolled": "exactly match store identity/SE/enrollment/revocation facts",
            "missing_enrolled": "exactly match store identity/SE/enrollment/revocation facts",
            "se_mismatch": "exactly match store identity/SE/enrollment/revocation facts",
            "timestamp_mismatch": "exactly match store identity/SE/enrollment/revocation facts",
            "operator_pin": "operator_pin entries require raw configured operator pin facts",
            "boolean_timestamp": "canonical 32-byte SE fingerprints",
            "duplicate_store_rows": "must not contain duplicates",
            "boolean_issued": "directory validity window must be bounded",
            "boolean_header_captured": "gateway capture must be fresh",
            "boolean_client_captured": "expired negative capture must be at or after expiry",
        }
        for mutation, message in expected.items():
            with self.subTest(mutation=mutation):
                errors = contract.Checks(self.directory_fixture(mutation), contract.PROFILE_V2).run("v2_directory")
                self.assertTrue(any(message in error for error in errors), errors)

    def test_explicit_v2_profile_composes_and_validates_all_twenty_one_steps(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory) / "repo"
            for relative in ("specs/CONFORMANCE.json", contract.JOURNEY_PATH, contract.JOURNEY_PATH_V2):
                destination = root / relative
                destination.parent.mkdir(parents=True, exist_ok=True)
                shutil.copyfile(REPO_ROOT / relative, destination)
            bundle_dir = root / BUNDLE
            shutil.copytree(REPO_ROOT / BUNDLE, bundle_dir)
            baseline = contract.load_bundle(root, BUNDLE)
            old_disclosure = contract.Checks(baseline, contract.PROFILE_V1).disclosure().encode()
            new_disclosure = contract.privacy_disclosure(
                contract.Checks(baseline, contract.PROFILE_V1).identity("privacy")["relay_blind_fingerprint"],
                contract.PRIVACY_RESIDUAL_RISKS_V2,
            ).encode()
            replaced = 0
            for path in bundle_dir.rglob("*.stderr"):
                data = path.read_bytes()
                if data == old_disclosure:
                    path.write_bytes(new_disclosure)
                    replaced += 1
            self.assertEqual(10, replaced)
            release, fixture_key_digest = self.release_fixture()
            fixtures = (self.same_studio_sip_off_fixture(), self.auto_fixture(), self.enrollment_fixture(), self.reenroll_fixture(), release, self.directory_fixture())
            for fixture in fixtures:
                for relative, data in fixture.files.items():
                    if relative == "step-01-bind-signed-release/binding.txt":
                        continue
                    destination = bundle_dir / relative
                    destination.parent.mkdir(parents=True, exist_ok=True)
                    destination.write_bytes(data)
            sweep_path = bundle_dir / "step-16-redaction-review" / "evidence-sweep.json"
            sweep = json.loads(sweep_path.read_text(encoding="utf-8"))
            sweep["roots"][0]["files_scanned"] = len([path for path in bundle_dir.rglob("*") if path.is_file() and path.name != contract.MANIFEST_NAME and not path.relative_to(bundle_dir).as_posix().startswith("primary/")]) - 3
            sweep_path.write_text(json.dumps(sweep, indent=2, sort_keys=True) + "\n", encoding="utf-8")
            results = (bundle_dir / "results.tsv").read_text(encoding="utf-8")
            marker = "2026-10-06T04:44:43Z\tstep-16-redaction-review"
            extension = "".join(
                f"2026-10-06T04:44:43Z\t{step}\tPASS\tsynthetic raw-fixture wiring check only\n"
                for step in contract.STEP_ID_ORDER_V2[-5:]
            )
            results = results.replace(marker, extension + marker)
            (bundle_dir / "results.tsv").write_text(results, encoding="utf-8")
            remanifest(bundle_dir)
            defaults = dict(contract.Checks.__init__.__kwdefaults__ or {})
            try:
                # Test-only trust injection keeps production pinned to the repo
                # PEM while letting the fixture use an ephemeral private key.
                contract.Checks.__init__.__kwdefaults__["trusted_release_public_key_sha256"] = fixture_key_digest
                contract._RECOMPUTE_CACHE.clear()
                evidence = contract.compose_evidence(root, BUNDLE, profile="v2")
                self.assertEqual(contract.EVIDENCE_SCHEMA_V2, evidence["schema_version"])
                self.assertEqual(contract.JOURNEY_ID_V2, evidence["journey_id"])
                self.assertEqual(21, len(evidence["steps"]))
                self.assertEqual(contract.STEP_ID_ORDER_V2, tuple(row["step_id"] for row in evidence["steps"]))
                contract.validate_evidence(root, SOURCE, evidence, now=NOW)
            finally:
                contract.Checks.__init__.__kwdefaults__.clear()
                contract.Checks.__init__.__kwdefaults__.update(defaults)
                contract._RECOMPUTE_CACHE.clear()


class PrivacyClassBetaGovernanceTests(unittest.TestCase):
    def test_primary_extractor_exports_v2_sources_with_bound_provenance(self) -> None:
        extractor = load_extractor_module()
        self.assertEqual(contract.V2_SOURCE_CONTRACT, extractor.V2_SOURCE_CONTRACT)
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            raw = root / "raw"
            out = root / "out" / "primary"
            source_dir = raw / "evidence" / "v2-source"
            source_dir.mkdir(parents=True)
            provenance = {}
            for manifest, sources in extractor.V2_SOURCE_CONTRACT.items():
                rows = []
                for kind, relative in sources.items():
                    capture = raw / relative
                    capture.parent.mkdir(parents=True, exist_ok=True)
                    capture.write_bytes(b"{}\n" if capture.suffix == ".json" else b"fixture-public-bytes\n")
                    rows.append({"kind": kind, "path": relative, "sha256": hashlib.sha256(capture.read_bytes()).hexdigest()})
                provenance[manifest] = {"raw_sources": rows}
            fixtures = {
                "auto-mode.json": {"profile": contract.V2_SOURCE_PROFILE, "provenance": provenance["auto-mode.json"], "cases": []},
                "enrollment.json": {"profile": contract.V2_SOURCE_PROFILE, "provenance": provenance["enrollment.json"], "enrollments": [], "cross_provider_reuse": {}, "failed_posture": {}},
                "reenroll.json": {"profile": contract.V2_SOURCE_PROFILE, "provenance": provenance["reenroll.json"], "initial": {}, "key_change": {}, "post_expiry_retry": {}, "operator_reenroll": {}, "after_reenroll": {}},
                "release-derived-approval.json": {"profile": contract.V2_SOURCE_PROFILE, "provenance": provenance["release-derived-approval.json"], "approved_identity": {}, "metadata": {}, "eligibility": {}},
                "directory.json": {"profile": contract.V2_SOURCE_PROFILE, "provenance": provenance["directory.json"], "directory": {}, "client_rejections": {}, "gateway": {}, "disclosure": {}},
            }
            for name, value in fixtures.items():
                (source_dir / name).write_text(json.dumps(value, sort_keys=True) + "\n", encoding="utf-8")
            extractor.RAW_ROOT = raw.resolve()
            extractor.export_v2_sources(raw.resolve(), out, extractor.Redactor("/Users/example"), [])
            exported = json.loads((out / "v2" / "auto-mode.json").read_text(encoding="utf-8"))
            self.assertEqual("macprovider.privacy-class-beta-primary.v1", exported["schema_version"])
            self.assertEqual(hashlib.sha256((source_dir / "auto-mode.json").read_bytes()).hexdigest(), exported["raw_source_sha256"])
            self.assertEqual((raw / extractor.V2_SOURCE_CONTRACT["auto-mode.json"]["auto_launch"]).read_bytes(), (out / "v2" / "sources" / "auto_launch.json").read_bytes())

            bad = dict(fixtures["auto-mode.json"])
            bad["provenance"] = copy.deepcopy(provenance["auto-mode.json"])
            bad["provenance"]["raw_sources"][0]["sha256"] = "0" * 64
            (source_dir / "auto-mode.json").write_text(json.dumps(bad, sort_keys=True) + "\n", encoding="utf-8")
            with self.assertRaises(SystemExit):
                extractor.export_v2_sources(raw.resolve(), out, extractor.Redactor("/Users/example"), [])

            bad_duplicate = (source_dir / "auto-mode.json")
            bad_duplicate.write_text('{"profile":"x","profile":"x"}\n', encoding="utf-8")
            with self.assertRaises(SystemExit):
                extractor.export_v2_sources(raw.resolve(), out, extractor.Redactor("/Users/example"), [])

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
            # The working tree's reviewed bundle and evidence, committed in the clone.
            shutil.rmtree(root / BUNDLE, ignore_errors=True)
            shutil.copytree(REPO_ROOT / BUNDLE, root / BUNDLE)
            shutil.copyfile(REPO_ROOT / SOURCE, root / SOURCE)
            # The real signed result is committed at the same path; the fixture
            # signs its own envelope there, so the signer must find it absent.
            (root / SOURCE.replace(".redacted.json", ".journey-result.signed.json")).unlink(missing_ok=True)
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
