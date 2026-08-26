from __future__ import annotations

import base64
import contextlib
import copy
import hashlib
import io
import json
import subprocess
import tempfile
import unittest
from datetime import datetime, timezone
from pathlib import Path

from scripts.check_spec_governance import (
    JOURNEY_RESULT_ENVELOPE_SCHEMA,
    JOURNEY_RESULT_PAYLOAD_SCHEMA,
    JOURNEY_RESULT_PUBLIC_KEY_PATH,
    JOURNEY_RESULT_SIGNING_ALGORITHM,
    JOURNEY_RESULT_SIGNING_DOMAIN,
    JOURNEY_RESULT_SIGNING_KEY_ID,
    ValidationResult,
    _canonical_json_bytes,
    _canonical_json_sha256,
    _signed_journey_result_satisfies,
    resolve_trusted_openssl,
)
from scripts.tests.test_journey_result_tools import load_promoter_module
from scripts.tests.test_spec_governance import base_repository, write_repository
from scripts.pool_promotion_transition import (
    KEYRING_PATH,
    LEDGER_PATH,
    LEDGER_REVOCATION_TYPE,
    LEDGER_SCHEMA_VERSION,
    POOL_PROMOTION_TRANSITION_PAYLOAD_SCHEMA,
    PRODUCTION_RELEASE_KEY_ID,
    consume_pool_promotion_transition,
    journey_result_digest,
    sign_pool_promotion_transition,
    validate_pool_promotion_transition,
    _consumed_authorization_record,
)


REPO_ROOT = Path(__file__).resolve().parents[2]
CLI = REPO_ROOT / "scripts" / "validate-pool-promotion-transition.py"
NOW = datetime(2026, 8, 25, 12, 0, 0, tzinfo=timezone.utc)
NOW_TEXT = "2026-08-25T12:00:00Z"
DIGEST = "ab" * 32


def generate_p256_key(openssl_bin: str, directory: Path, stem: str) -> tuple[str, str]:
    private_key = directory / f"{stem}.pem"
    public_key = directory / f"{stem}.pub.pem"
    subprocess.run(
        [openssl_bin, "genpkey", "-algorithm", "EC", "-pkeyopt", "ec_paramgen_curve:P-256", "-out", str(private_key)],
        check=True,
        stdout=subprocess.DEVNULL,
        stderr=subprocess.DEVNULL,
    )
    subprocess.run(
        [openssl_bin, "pkey", "-in", str(private_key), "-pubout", "-out", str(public_key)],
        check=True,
        stdout=subprocess.DEVNULL,
        stderr=subprocess.DEVNULL,
    )
    return private_key.read_text(encoding="utf-8"), public_key.read_text(encoding="utf-8")


def sign_candidate_envelope(
    signed: dict,
    *,
    private_key_pem: str,
    public_key_pem: str,
    openssl_bin: str,
) -> dict:
    with tempfile.TemporaryDirectory(prefix="candidate-sign.") as directory:
        work = Path(directory)
        private_path = work / "private.pem"
        public_path = work / "public.pem"
        message = work / "message"
        signature_path = work / "signature.der"
        private_path.write_text(private_key_pem, encoding="utf-8")
        private_path.chmod(0o600)
        public_path.write_text(public_key_pem, encoding="utf-8")
        message.write_bytes(JOURNEY_RESULT_SIGNING_DOMAIN + _canonical_json_bytes(signed))
        subprocess.run(
            [openssl_bin, "dgst", "-sha256", "-sign", str(private_path), "-out", str(signature_path), str(message)],
            check=True,
            stdout=subprocess.DEVNULL,
            stderr=subprocess.DEVNULL,
            env={"PATH": "/usr/bin:/bin"},
        )
        signature_b64 = base64.b64encode(signature_path.read_bytes()).decode("ascii")
    return {
        "schema_version": JOURNEY_RESULT_ENVELOPE_SCHEMA,
        "signatures": [
            {
                "algorithm": JOURNEY_RESULT_SIGNING_ALGORITHM,
                "key_id": JOURNEY_RESULT_SIGNING_KEY_ID,
                "signature": signature_b64,
                "signed_sha256": _canonical_json_sha256(signed),
                "verified_at": "2026-08-25T11:00:00Z",
                "verifier": "scripts/tests/test_pool_promotion_transition.py",
            }
        ],
        "signed": signed,
    }


def candidate_payload(**overrides: object) -> dict:
    payload = {
        "schema_version": JOURNEY_RESULT_PAYLOAD_SCHEMA,
        "journey_id": "JOURNEY-TRUSTED-POOL-CREATOR-MVP",
        "run_id": 1,
        "execution_mode": "isolated-candidate-trusted-pool-creator-mvp",
    }
    payload.update(overrides)
    return payload


def ledger_init_line() -> str:
    return (
        '{"type":"ledger_init","schema_version":"spec-043-promotion-auth-ledger-v1",'
        '"named_subsystem":"spec043-promotion-ledger","store_type":"append-only-jsonl",'
        '"deployment_target":"repository-governance-ledger",'
        '"backup_restore_policy":"independent-of-coordinator-snapshots",'
        '"availability_sla":"best-effort-until-production-key-registration"}\n'
    )


def candidate_envelope() -> dict:
    return {
        "schema_version": JOURNEY_RESULT_ENVELOPE_SCHEMA,
        "signatures": [
            {
                "algorithm": "ecdsa-p256-sha256",
                "key_id": JOURNEY_RESULT_SIGNING_KEY_ID,
                "signature": "YQ==",
                "signed_sha256": DIGEST,
                "verified_at": "2026-08-25T11:00:00Z",
                "verifier": "scripts/tests/test_pool_promotion_transition.py",
            }
        ],
        "signed": {
            "schema_version": "macprovider.journey-result.v1",
            "journey_id": "JOURNEY-TRUSTED-POOL-CREATOR-MVP",
            "run_id": 1,
            "execution_mode": "isolated-candidate-trusted-pool-creator-mvp",
        },
    }


def signed_payload(digest: str, **overrides: object) -> dict:
    payload = {
        "schema_version": POOL_PROMOTION_TRANSITION_PAYLOAD_SCHEMA,
        "journey_id": "JOURNEY-TRUSTED-POOL-CREATOR-MVP",
        "run_id": 1,
        "journey_result_digest": digest,
        "candidate_environment_id": "candidate-trusted-pool-creator-mvp",
        "live_activation_target": "production-trusted-pool-creator-mvp",
        "pool_id": "pool_creator_mvp_001",
        "environment_id": "production-trusted-pool-creator-mvp",
        "environment_class": "production",
        "coordinator_build_id": "coordinator-test",
        "gateway_build_id": "gateway-test",
        "provider_build_id": "provider-test",
        "schema_migration_hash": DIGEST,
        "effective_config_digest": DIGEST,
        "feature_flag_digest": DIGEST,
        "governance_file_digest": DIGEST,
        "approval_record_id": "approval-1",
        "approval_record_version": 1,
        "creator_agreement_id": "agreement-1",
        "creator_agreement_version": 1,
        "creator_agreement_expires_at": "2026-12-01T00:00:00Z",
        "creator_agreement_grace_ends_at": "2026-12-08T00:00:00Z",
        "pricing_schedule_id": "pricing-1",
        "pricing_schedule_version": 1,
        "reviewed_distribution_artifact_digest": DIGEST,
        "root_issuer_fingerprint": DIGEST,
        "gate_check_id": "gate-check-1",
        "routeable_snapshot_digest": DIGEST,
        "pool_generation": 1,
        "transition_epoch": 1,
        "authorization_id": "authz-1",
        "verifier_challenge": "challenge-1",
        "authorized_actor": "ops-approver",
        "credential_id": "cred-1",
        "rbac_role": "production-release-approver",
        "authorized_at": "2026-08-25T11:00:00Z",
        "expiry": "2026-08-26T11:00:00Z",
        "target_lifecycle_transition": "active",
    }
    payload.update(overrides)
    return payload


def write_promotion_root(root: Path, openssl_bin: str, *, register_key: bool = True) -> dict:
    acceptance_private, acceptance_public = generate_p256_key(openssl_bin, root, "acceptance")
    production_private, production_public = generate_p256_key(openssl_bin, root, "production-release")
    security = root / "security"
    security.mkdir(parents=True, exist_ok=True)
    (root / JOURNEY_RESULT_PUBLIC_KEY_PATH).write_text(acceptance_public, encoding="utf-8")
    (root / "security" / "spec-043-production-release-p256-v1.pem").write_text(production_public, encoding="utf-8")
    keyring = {
        "schema_version": "spec-043-launch-keyring-v1",
        "purpose": "production-release-approver",
        "allowed_environment_classes": ["production"],
        "keys": [],
    }
    if register_key:
        keyring["keys"] = [
            {
                "key_id": PRODUCTION_RELEASE_KEY_ID,
                "purpose": "production-release-approver",
                "issuer": "macprovider-ops",
                "valid_from": "2026-01-01T00:00:00Z",
                "valid_until": "2027-01-01T00:00:00Z",
                "allowed_environment_classes": ["production"],
                "public_key_path": "security/spec-043-production-release-p256-v1.pem",
            }
        ]
    (root / KEYRING_PATH).write_text(json.dumps(keyring, indent=2) + "\n", encoding="utf-8")
    ledger = root / LEDGER_PATH
    ledger.parent.mkdir(parents=True, exist_ok=True)
    ledger.write_text(ledger_init_line(), encoding="utf-8")
    candidate = sign_candidate_envelope(
        candidate_payload(),
        private_key_pem=acceptance_private,
        public_key_pem=acceptance_public,
        openssl_bin=openssl_bin,
    )
    digest = journey_result_digest(candidate)
    envelope = sign_pool_promotion_transition(
        signed_payload(digest),
        private_key_pem=production_private,
        public_key_pem=production_public,
        key_id=PRODUCTION_RELEASE_KEY_ID,
        openssl_bin=openssl_bin,
        verified_at="2026-08-25T11:00:00Z",
    )
    evidence_dir = root / "journeys" / "evidence"
    evidence_dir.mkdir(parents=True, exist_ok=True)
    transition_source = "journeys/evidence/pool-promotion-transition.json"
    (root / transition_source).write_text(json.dumps(envelope) + "\n", encoding="utf-8")
    return {
        "private_pem": production_private,
        "public_pem": production_public,
        "acceptance_private": acceptance_private,
        "acceptance_public": acceptance_public,
        "candidate_key_sha256": hashlib.sha256(acceptance_public.encode("utf-8")).hexdigest(),
        "candidate": candidate,
        "envelope": envelope,
        "digest": digest,
        "transition_source": transition_source,
    }


def signed_promoter_pair(fixture: dict, commit: str, openssl_bin: str) -> tuple[dict, dict]:
    candidate = sign_candidate_envelope(
        candidate_payload(
            repository={"name": "Augustas11/macprovider", "commit": commit},
            captured_at="2026-08-25T11:00:00Z",
            expires_at="2026-08-25",
        ),
        private_key_pem=fixture["acceptance_private"],
        public_key_pem=fixture["acceptance_public"],
        openssl_bin=openssl_bin,
    )
    envelope = sign_pool_promotion_transition(
        signed_payload(journey_result_digest(candidate)),
        private_key_pem=fixture["private_pem"],
        public_key_pem=fixture["public_pem"],
        key_id=PRODUCTION_RELEASE_KEY_ID,
        openssl_bin=openssl_bin,
        verified_at="2026-08-25T11:00:00Z",
    )
    return candidate, envelope


def write_promoter_artifacts(root: Path, candidate: dict, envelope: dict) -> tuple[str, str]:
    evidence_dir = root / "journeys" / "evidence"
    evidence_dir.mkdir(parents=True, exist_ok=True)
    candidate_source = "journeys/evidence/trusted-pool-creator-mvp-alpha.signed.json"
    transition_source = "journeys/evidence/pool-promotion-transition.json"
    (root / candidate_source).write_text(json.dumps(candidate, indent=2) + "\n", encoding="utf-8")
    (root / transition_source).write_text(json.dumps(envelope, indent=2) + "\n", encoding="utf-8")
    return candidate_source, transition_source


def forged_consumed_record(digest: str, **overrides: object) -> dict:
    record = {
        "type": "consumed_authorization",
        "schema_version": LEDGER_SCHEMA_VERSION,
        "named_subsystem": "spec043-promotion-ledger",
        "journey_id": "JOURNEY-TRUSTED-POOL-CREATOR-MVP",
        "run_id": 1,
        "authorization_id": "forged-authz",
        "pool_id": "pool_forged",
        "transition_epoch": 1,
        "key_id": PRODUCTION_RELEASE_KEY_ID,
        "journey_result_digest": digest,
        "recorded_at": NOW_TEXT,
        "promotion_transition_source": "journeys/evidence/pool-promotion-transition.json",
        "promotion_transition_digest": DIGEST,
    }
    record.update(overrides)
    return record


def creator_mvp_requirement(root: Path, source: str) -> dict:
    digest = hashlib.sha256((root / source).read_bytes()).hexdigest()
    return {
        "requirement_id": "SPEC-043-R012",
        "journeys": ["JOURNEY-TRUSTED-POOL-CREATOR-MVP"],
        "evidence": [
            {
                "artifact": f"sha256:{digest}",
                "source": source,
                "captured_at": "2026-08-25",
                "expires_at": "2026-08-25",
            }
        ],
    }


class PoolPromotionTransitionTests(unittest.TestCase):
    def setUp(self) -> None:
        try:
            self.openssl_bin = resolve_trusted_openssl()
        except ValueError as exc:
            raise unittest.SkipTest(str(exc)) from exc

    def test_valid_transition_consumes_authorization(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            fixture = write_promotion_root(root, self.openssl_bin)
            result = consume_pool_promotion_transition(
                root,
                fixture["envelope"],
                fixture["candidate"],
                now=NOW,
                openssl_bin=self.openssl_bin,
                trusted_journey_result_public_key_sha256=fixture["candidate_key_sha256"],
            )
            self.assertEqual([], result.errors)
            ledger = (root / LEDGER_PATH).read_text(encoding="utf-8")
            self.assertIn('"type":"consumed_authorization"', ledger)
            self.assertIn("authz-1", ledger)
            self.assertNotIn("conformant", ledger)

    def test_second_consume_of_same_authorization_id_is_rejected(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            fixture = write_promotion_root(root, self.openssl_bin)
            first = consume_pool_promotion_transition(
                root,
                fixture["envelope"],
                fixture["candidate"],
                now=NOW,
                openssl_bin=self.openssl_bin,
                trusted_journey_result_public_key_sha256=fixture["candidate_key_sha256"],
            )
            self.assertEqual([], first.errors)
            second = consume_pool_promotion_transition(
                root,
                fixture["envelope"],
                fixture["candidate"],
                now=NOW,
                openssl_bin=self.openssl_bin,
                trusted_journey_result_public_key_sha256=fixture["candidate_key_sha256"],
            )
            self.assertTrue(any("already been consumed" in error for error in second.errors))

    def test_rejects_missing_journey_result_digest(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            fixture = write_promotion_root(root, self.openssl_bin)
            envelope = copy.deepcopy(fixture["envelope"])
            del envelope["signed"]["journey_result_digest"]
            result = validate_pool_promotion_transition(
                root,
                envelope,
                fixture["candidate"],
                now=NOW,
                openssl_bin=self.openssl_bin,
                trusted_journey_result_public_key_sha256=fixture["candidate_key_sha256"],
            )
            self.assertTrue(any("journey_result_digest" in error for error in result.errors))

    def test_rejects_wrong_schema_version(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            fixture = write_promotion_root(root, self.openssl_bin)
            envelope = copy.deepcopy(fixture["envelope"])
            envelope["signed"]["schema_version"] = "macprovider.journey-result.v1"
            result = validate_pool_promotion_transition(
                root,
                envelope,
                fixture["candidate"],
                now=NOW,
                openssl_bin=self.openssl_bin,
                trusted_journey_result_public_key_sha256=fixture["candidate_key_sha256"],
            )
            self.assertTrue(any("spec-043-promotion-auth-v1" in error for error in result.errors))

    def test_rejects_acceptance_key_as_approver(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            fixture = write_promotion_root(root, self.openssl_bin)
            envelope = copy.deepcopy(fixture["envelope"])
            envelope["signatures"][0]["key_id"] = JOURNEY_RESULT_SIGNING_KEY_ID
            result = validate_pool_promotion_transition(
                root,
                envelope,
                fixture["candidate"],
                now=NOW,
                openssl_bin=self.openssl_bin,
                trusted_journey_result_public_key_sha256=fixture["candidate_key_sha256"],
            )
            self.assertTrue(any("acceptance candidate key" in error for error in result.errors))

    def test_rejects_non_monotonic_run_id(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            fixture = write_promotion_root(root, self.openssl_bin)
            first = consume_pool_promotion_transition(
                root,
                fixture["envelope"],
                fixture["candidate"],
                now=NOW,
                openssl_bin=self.openssl_bin,
                trusted_journey_result_public_key_sha256=fixture["candidate_key_sha256"],
            )
            self.assertEqual([], first.errors)
            later = sign_pool_promotion_transition(
                signed_payload(fixture["digest"], run_id=1, authorization_id="authz-2", transition_epoch=2),
                private_key_pem=fixture["private_pem"],
                public_key_pem=fixture["public_pem"],
                key_id=PRODUCTION_RELEASE_KEY_ID,
                openssl_bin=self.openssl_bin,
                verified_at="2026-08-25T11:00:00Z",
            )
            result = validate_pool_promotion_transition(
                root,
                later,
                fixture["candidate"],
                now=NOW,
                openssl_bin=self.openssl_bin,
                trusted_journey_result_public_key_sha256=fixture["candidate_key_sha256"],
            )
            self.assertTrue(any("run_id" in error and "high-water" in error for error in result.errors))

    def test_rejects_non_monotonic_transition_epoch(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            fixture = write_promotion_root(root, self.openssl_bin)
            first = consume_pool_promotion_transition(
                root,
                fixture["envelope"],
                fixture["candidate"],
                now=NOW,
                openssl_bin=self.openssl_bin,
                trusted_journey_result_public_key_sha256=fixture["candidate_key_sha256"],
            )
            self.assertEqual([], first.errors)
            later_candidate = sign_candidate_envelope(
                candidate_payload(run_id=2),
                private_key_pem=fixture["acceptance_private"],
                public_key_pem=fixture["acceptance_public"],
                openssl_bin=self.openssl_bin,
            )
            later = sign_pool_promotion_transition(
                signed_payload(journey_result_digest(later_candidate), run_id=2, authorization_id="authz-2", transition_epoch=1),
                private_key_pem=fixture["private_pem"],
                public_key_pem=fixture["public_pem"],
                key_id=PRODUCTION_RELEASE_KEY_ID,
                openssl_bin=self.openssl_bin,
                verified_at="2026-08-25T11:00:00Z",
            )
            result = validate_pool_promotion_transition(
                root,
                later,
                later_candidate,
                now=NOW,
                openssl_bin=self.openssl_bin,
                trusted_journey_result_public_key_sha256=fixture["candidate_key_sha256"],
            )
            self.assertTrue(any("transition_epoch" in error for error in result.errors))

    def test_rejects_candidate_containing_promotion_fields(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            fixture = write_promotion_root(root, self.openssl_bin)
            candidate = copy.deepcopy(fixture["candidate"])
            candidate["signed"]["live_activation_target"] = "production-trusted-pool-creator-mvp"
            envelope = sign_pool_promotion_transition(
                signed_payload(journey_result_digest(candidate)),
                private_key_pem=fixture["private_pem"],
                public_key_pem=fixture["public_pem"],
                key_id=PRODUCTION_RELEASE_KEY_ID,
                openssl_bin=self.openssl_bin,
                verified_at="2026-08-25T11:00:00Z",
            )
            result = validate_pool_promotion_transition(
                root,
                envelope,
                candidate,
                now=NOW,
                openssl_bin=self.openssl_bin,
                trusted_journey_result_public_key_sha256=fixture["candidate_key_sha256"],
            )
            self.assertTrue(any("live_activation_target" in error for error in result.errors))

    def test_journey_envelope_cannot_mutate_ledger(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            fixture = write_promotion_root(root, self.openssl_bin)
            before = (root / LEDGER_PATH).read_bytes()
            result = consume_pool_promotion_transition(
                root,
                fixture["candidate"],
                fixture["candidate"],
                now=NOW,
                openssl_bin=self.openssl_bin,
                trusted_journey_result_public_key_sha256=fixture["candidate_key_sha256"],
            )
            self.assertTrue(result.errors)
            self.assertEqual(before, (root / LEDGER_PATH).read_bytes())

    def test_empty_keyring_is_fail_closed(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            fixture = write_promotion_root(root, self.openssl_bin, register_key=False)
            result = validate_pool_promotion_transition(
                root,
                fixture["envelope"],
                fixture["candidate"],
                now=NOW,
                openssl_bin=self.openssl_bin,
                trusted_journey_result_public_key_sha256=fixture["candidate_key_sha256"],
            )
            self.assertTrue(any("fail-closed" in error for error in result.errors))

    def test_ledger_revocation_survives_keyring_rollback(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            fixture = write_promotion_root(root, self.openssl_bin)
            with (root / LEDGER_PATH).open("a", encoding="utf-8") as handle:
                handle.write(
                    json.dumps(
                        {
                            "type": LEDGER_REVOCATION_TYPE,
                            "schema_version": LEDGER_SCHEMA_VERSION,
                            "key_id": PRODUCTION_RELEASE_KEY_ID,
                            "recorded_at": NOW_TEXT,
                        },
                        sort_keys=True,
                    )
                    + "\n"
                )
            result = validate_pool_promotion_transition(
                root,
                fixture["envelope"],
                fixture["candidate"],
                now=NOW,
                openssl_bin=self.openssl_bin,
                trusted_journey_result_public_key_sha256=fixture["candidate_key_sha256"],
            )
            self.assertTrue(any("revoked" in error for error in result.errors))

    def test_coordinator_state_restore_does_not_rewind_ledger(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            fixture = write_promotion_root(root, self.openssl_bin)
            coordinator_state = root / "coordinator-state.json"
            coordinator_state.write_text('{"consumed":false}\n', encoding="utf-8")
            snapshot = coordinator_state.read_text(encoding="utf-8")
            first = consume_pool_promotion_transition(
                root,
                fixture["envelope"],
                fixture["candidate"],
                now=NOW,
                openssl_bin=self.openssl_bin,
                trusted_journey_result_public_key_sha256=fixture["candidate_key_sha256"],
            )
            self.assertEqual([], first.errors)
            coordinator_state.write_text('{"consumed":true}\n', encoding="utf-8")
            coordinator_state.write_text(snapshot, encoding="utf-8")
            replay = consume_pool_promotion_transition(
                root,
                fixture["envelope"],
                fixture["candidate"],
                now=NOW,
                openssl_bin=self.openssl_bin,
                trusted_journey_result_public_key_sha256=fixture["candidate_key_sha256"],
            )
            self.assertTrue(any("already been consumed" in error for error in replay.errors))

    def test_governance_rejects_promotion_artifact_as_conformant_evidence(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            (root / "journeys" / "evidence").mkdir(parents=True)
            source = "journeys/evidence/pool-promotion-transition.json"
            (root / source).write_text(
                json.dumps(
                    {
                        "schema_version": "macprovider.pool-promotion-transition-envelope.v1",
                        "signatures": [],
                        "signed": {"schema_version": POOL_PROMOTION_TRANSITION_PAYLOAD_SCHEMA},
                    }
                )
                + "\n",
                encoding="utf-8",
            )
            digest = hashlib.sha256((root / source).read_bytes()).hexdigest()
            requirement = {
                "requirement_id": "SPEC-043-R012",
                "journeys": ["JOURNEY-TRUSTED-POOL-CREATOR-MVP"],
                "evidence": [
                    {
                        "artifact": f"sha256:{digest}",
                        "source": source,
                        "captured_at": "2026-08-25",
                        "expires_at": "2027-08-25",
                    }
                ],
            }
            result = ValidationResult()
            satisfied = _signed_journey_result_satisfies(
                root,
                requirement,
                "SPEC-043-R012",
                result,
                "a" * 64,
                self.openssl_bin,
            )
            self.assertFalse(satisfied)
            self.assertTrue(any("sibling production-promotion artifact" in error for error in result.errors))

    def test_governance_keeps_creator_mvp_evidence_only_until_ledger_consume(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            fixture = write_promotion_root(root, self.openssl_bin)
            source = "journeys/evidence/trusted-pool-creator-mvp-alpha.signed.json"
            evidence_path = root / source
            evidence_path.parent.mkdir(parents=True, exist_ok=True)
            evidence_path.write_text(json.dumps(fixture["candidate"]) + "\n", encoding="utf-8")
            digest = hashlib.sha256(evidence_path.read_bytes()).hexdigest()
            requirement = {
                "requirement_id": "SPEC-043-R012",
                "journeys": ["JOURNEY-TRUSTED-POOL-CREATOR-MVP"],
                "evidence": [
                    {
                        "artifact": f"sha256:{digest}",
                        "source": source,
                        "captured_at": "2026-08-25",
                        "expires_at": "2026-08-25",
                    }
                ],
            }
            before = ValidationResult()
            self.assertFalse(
                _signed_journey_result_satisfies(
                    root,
                    requirement,
                    "SPEC-043-R012",
                    before,
                    fixture["candidate_key_sha256"],
                    self.openssl_bin,
                )
            )
            self.assertTrue(any("evidence-only and cannot satisfy conformant requirements" in error for error in before.errors))

            consumed = consume_pool_promotion_transition(
                root,
                fixture["envelope"],
                fixture["candidate"],
                now=NOW,
                openssl_bin=self.openssl_bin,
                trusted_journey_result_public_key_sha256=fixture["candidate_key_sha256"],
            )
            self.assertEqual([], consumed.errors)
            after = ValidationResult()
            _signed_journey_result_satisfies(
                root,
                requirement,
                "SPEC-043-R012",
                after,
                fixture["candidate_key_sha256"],
                self.openssl_bin,
            )
            self.assertFalse(any("evidence-only and cannot satisfy conformant requirements" in error for error in after.errors))

    def test_governance_rejects_forged_consumed_authorization_when_keyring_empty(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            fixture = write_promotion_root(root, self.openssl_bin, register_key=False)
            source = "journeys/evidence/trusted-pool-creator-mvp-alpha.signed.json"
            evidence_path = root / source
            evidence_path.parent.mkdir(parents=True, exist_ok=True)
            evidence_path.write_text(json.dumps(fixture["candidate"]) + "\n", encoding="utf-8")
            digest = journey_result_digest(fixture["candidate"])
            (root / LEDGER_PATH).write_text(
                ledger_init_line() + json.dumps(forged_consumed_record(digest)) + "\n",
                encoding="utf-8",
            )
            result = ValidationResult()
            self.assertFalse(
                _signed_journey_result_satisfies(
                    root,
                    creator_mvp_requirement(root, source),
                    "SPEC-043-R012",
                    result,
                    fixture["candidate_key_sha256"],
                    self.openssl_bin,
                )
            )
            self.assertTrue(any("evidence-only and cannot satisfy conformant requirements" in error for error in result.errors))

    def test_governance_rejects_partial_forged_consumed_authorization_with_registered_key(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            fixture = write_promotion_root(root, self.openssl_bin, register_key=True)
            source = "journeys/evidence/trusted-pool-creator-mvp-alpha.signed.json"
            evidence_path = root / source
            evidence_path.parent.mkdir(parents=True, exist_ok=True)
            evidence_path.write_text(json.dumps(fixture["candidate"]) + "\n", encoding="utf-8")
            digest = journey_result_digest(fixture["candidate"])
            (root / LEDGER_PATH).write_text(
                ledger_init_line()
                + json.dumps(
                    {
                        "type": "consumed_authorization",
                        "journey_id": "JOURNEY-TRUSTED-POOL-CREATOR-MVP",
                        "run_id": 1,
                        "journey_result_digest": digest,
                    }
                )
                + "\n",
                encoding="utf-8",
            )
            result = ValidationResult()
            self.assertFalse(
                _signed_journey_result_satisfies(
                    root,
                    creator_mvp_requirement(root, source),
                    "SPEC-043-R012",
                    result,
                    fixture["candidate_key_sha256"],
                    self.openssl_bin,
                )
            )
            self.assertTrue(any("evidence-only and cannot satisfy conformant requirements" in error for error in result.errors))

    def test_governance_rejects_full_shape_forged_consumed_authorization_with_registered_key(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            fixture = write_promotion_root(root, self.openssl_bin, register_key=True)
            source = "journeys/evidence/trusted-pool-creator-mvp-alpha.signed.json"
            evidence_path = root / source
            evidence_path.parent.mkdir(parents=True, exist_ok=True)
            evidence_path.write_text(json.dumps(fixture["candidate"]) + "\n", encoding="utf-8")
            digest = journey_result_digest(fixture["candidate"])
            fake_source = "journeys/evidence/forged-transition.json"
            (root / fake_source).write_text("{}\n", encoding="utf-8")
            (root / LEDGER_PATH).write_text(
                ledger_init_line()
                + json.dumps(
                    forged_consumed_record(
                        digest,
                        promotion_transition_source=fake_source,
                        promotion_transition_digest=DIGEST,
                    )
                )
                + "\n",
                encoding="utf-8",
            )
            result = ValidationResult()
            self.assertFalse(
                _signed_journey_result_satisfies(
                    root,
                    creator_mvp_requirement(root, source),
                    "SPEC-043-R012",
                    result,
                    fixture["candidate_key_sha256"],
                    self.openssl_bin,
                )
            )
            self.assertTrue(any("evidence-only and cannot satisfy conformant requirements" in error for error in result.errors))

    def test_governance_rejects_signed_invalid_transition_as_consumed_authorization(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            fixture = write_promotion_root(root, self.openssl_bin, register_key=True)
            source = "journeys/evidence/trusted-pool-creator-mvp-alpha.signed.json"
            evidence_path = root / source
            evidence_path.parent.mkdir(parents=True, exist_ok=True)
            evidence_path.write_text(json.dumps(fixture["candidate"]) + "\n", encoding="utf-8")
            invalid = sign_pool_promotion_transition(
                signed_payload(fixture["digest"], rbac_role="read-only-observer"),
                private_key_pem=fixture["private_pem"],
                public_key_pem=fixture["public_pem"],
                key_id=PRODUCTION_RELEASE_KEY_ID,
                openssl_bin=self.openssl_bin,
                verified_at="2026-08-25T11:00:00Z",
            )
            transition_source = "journeys/evidence/invalid-pool-promotion-transition.json"
            (root / transition_source).write_text(json.dumps(invalid) + "\n", encoding="utf-8")
            record = _consumed_authorization_record(
                invalid,
                transition_source=transition_source,
                recorded_at=NOW_TEXT,
            )
            self.assertIsNotNone(record)
            (root / LEDGER_PATH).write_text(ledger_init_line() + json.dumps(record) + "\n", encoding="utf-8")
            result = ValidationResult()
            self.assertFalse(
                _signed_journey_result_satisfies(
                    root,
                    creator_mvp_requirement(root, source),
                    "SPEC-043-R012",
                    result,
                    fixture["candidate_key_sha256"],
                    self.openssl_bin,
                )
            )
            self.assertTrue(any("evidence-only and cannot satisfy conformant requirements" in error for error in result.errors))

    def test_governance_rejects_duplicate_consumed_authorization_id(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            fixture = write_promotion_root(root, self.openssl_bin, register_key=True)
            source = "journeys/evidence/trusted-pool-creator-mvp-alpha.signed.json"
            evidence_path = root / source
            evidence_path.parent.mkdir(parents=True, exist_ok=True)
            evidence_path.write_text(json.dumps(fixture["candidate"]) + "\n", encoding="utf-8")
            consumed = consume_pool_promotion_transition(
                root,
                fixture["envelope"],
                fixture["candidate"],
                now=NOW,
                openssl_bin=self.openssl_bin,
                trusted_journey_result_public_key_sha256=fixture["candidate_key_sha256"],
            )
            self.assertEqual([], consumed.errors)
            ledger = (root / LEDGER_PATH).read_text(encoding="utf-8")
            consumed_lines = [line for line in ledger.splitlines() if '"type":"consumed_authorization"' in line]
            self.assertEqual(1, len(consumed_lines))
            (root / LEDGER_PATH).write_text(ledger.rstrip("\n") + "\n" + consumed_lines[0] + "\n", encoding="utf-8")
            result = ValidationResult()
            self.assertFalse(
                _signed_journey_result_satisfies(
                    root,
                    creator_mvp_requirement(root, source),
                    "SPEC-043-R012",
                    result,
                    fixture["candidate_key_sha256"],
                    self.openssl_bin,
                )
            )
            self.assertTrue(any("evidence-only and cannot satisfy conformant requirements" in error for error in result.errors))

    def test_promoter_rejects_creator_mvp_when_keyring_empty(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            write_repository(root, base_repository())
            commit = subprocess.check_output(["git", "rev-parse", "HEAD"], cwd=root, text=True).strip()
            fixture = write_promotion_root(root, self.openssl_bin, register_key=False)
            candidate, envelope = signed_promoter_pair(fixture, commit, self.openssl_bin)
            candidate_source, transition_source = write_promoter_artifacts(root, candidate, envelope)
            original_conformance = (root / "specs" / "CONFORMANCE.json").read_text(encoding="utf-8")
            original_ledger = (root / LEDGER_PATH).read_text(encoding="utf-8")
            promoter = load_promoter_module()
            stderr = io.StringIO()
            with self.assertRaises(SystemExit), contextlib.redirect_stderr(stderr):
                promoter.promote(
                    root,
                    "SPEC-001-R001",
                    candidate_source,
                    base_ref="HEAD",
                    trusted_public_key_sha256=fixture["candidate_key_sha256"],
                    openssl_bin=self.openssl_bin,
                    promotion_transition=transition_source,
                    now=NOW,
                )
            self.assertIn("is fail-closed: no production-release approver key is registered", stderr.getvalue())
            self.assertEqual(original_conformance, (root / "specs" / "CONFORMANCE.json").read_text(encoding="utf-8"))
            self.assertEqual(original_ledger, (root / LEDGER_PATH).read_text(encoding="utf-8"))
            self.assertNotIn("consumed_authorization", original_ledger)
            self.assertNotIn("consumed_authorization", (root / LEDGER_PATH).read_text(encoding="utf-8"))

    def test_promoter_does_not_consume_when_signed_result_is_rejected(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            write_repository(root, base_repository())
            commit = subprocess.check_output(["git", "rev-parse", "HEAD"], cwd=root, text=True).strip()
            fixture = write_promotion_root(root, self.openssl_bin, register_key=True)
            candidate, envelope = signed_promoter_pair(fixture, commit, self.openssl_bin)
            candidate_source, transition_source = write_promoter_artifacts(root, candidate, envelope)
            original_conformance = (root / "specs" / "CONFORMANCE.json").read_text(encoding="utf-8")
            original_ledger = (root / LEDGER_PATH).read_text(encoding="utf-8")
            promoter = load_promoter_module()
            stderr = io.StringIO()
            with self.assertRaises(SystemExit), contextlib.redirect_stderr(stderr):
                promoter.promote(
                    root,
                    "SPEC-001-R001",
                    candidate_source,
                    base_ref="HEAD",
                    trusted_public_key_sha256=fixture["candidate_key_sha256"],
                    openssl_bin=self.openssl_bin,
                    promotion_transition=transition_source,
                    now=NOW,
                )
            self.assertIn("signed journey-result rejected", stderr.getvalue())
            self.assertEqual(original_conformance, (root / "specs" / "CONFORMANCE.json").read_text(encoding="utf-8"))
            self.assertEqual(original_ledger, (root / LEDGER_PATH).read_text(encoding="utf-8"))
            self.assertNotIn("consumed_authorization", (root / LEDGER_PATH).read_text(encoding="utf-8"))

    def test_cli_consume_accepts_valid_artifact(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            fixture = write_promotion_root(root, self.openssl_bin)
            candidate_path = root / "candidate.json"
            candidate_path.write_text(json.dumps(fixture["candidate"]) + "\n", encoding="utf-8")
            completed = subprocess.run(
                [
                    "python3",
                    str(CLI),
                    "--root",
                    str(root),
                    "--transition",
                    fixture["transition_source"],
                    "--candidate",
                    str(candidate_path),
                    "--consume",
                    "--now",
                    NOW_TEXT,
                    "--openssl-bin",
                    self.openssl_bin,
                    "--trusted-journey-result-public-key-sha256",
                    fixture["candidate_key_sha256"],
                ],
                capture_output=True,
                text=True,
                check=False,
            )
            self.assertEqual(0, completed.returncode, completed.stderr)
            self.assertIn("consumed", completed.stdout)
            self.assertIn("authz-1", (root / LEDGER_PATH).read_text(encoding="utf-8"))

    def test_rejects_unsigned_candidate(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            fixture = write_promotion_root(root, self.openssl_bin)
            candidate = copy.deepcopy(fixture["candidate"])
            candidate["signatures"][0]["signature"] = "YQ=="
            envelope = sign_pool_promotion_transition(
                signed_payload(journey_result_digest(candidate)),
                private_key_pem=fixture["private_pem"],
                public_key_pem=fixture["public_pem"],
                key_id=PRODUCTION_RELEASE_KEY_ID,
                openssl_bin=self.openssl_bin,
                verified_at="2026-08-25T11:00:00Z",
            )
            result = validate_pool_promotion_transition(
                root,
                envelope,
                candidate,
                now=NOW,
                openssl_bin=self.openssl_bin,
                trusted_journey_result_public_key_sha256=fixture["candidate_key_sha256"],
            )
            self.assertTrue(any("signature" in error for error in result.errors))

    def test_rejects_run_id_mismatch(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            fixture = write_promotion_root(root, self.openssl_bin)
            later = sign_pool_promotion_transition(
                signed_payload(fixture["digest"], run_id=100, authorization_id="authz-100"),
                private_key_pem=fixture["private_pem"],
                public_key_pem=fixture["public_pem"],
                key_id=PRODUCTION_RELEASE_KEY_ID,
                openssl_bin=self.openssl_bin,
                verified_at="2026-08-25T11:00:00Z",
            )
            result = validate_pool_promotion_transition(
                root,
                later,
                fixture["candidate"],
                now=NOW,
                openssl_bin=self.openssl_bin,
                trusted_journey_result_public_key_sha256=fixture["candidate_key_sha256"],
            )
            self.assertTrue(any("must match signed candidate journey run_id" in error for error in result.errors))

    def test_rejects_forbidden_field_aliases(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            fixture = write_promotion_root(root, self.openssl_bin)
            candidate = sign_candidate_envelope(
                candidate_payload(
                    consumed_authorization_id="authz-smuggled",
                    production_transition_epoch=1,
                    promotion_verification_result="pass",
                ),
                private_key_pem=fixture["acceptance_private"],
                public_key_pem=fixture["acceptance_public"],
                openssl_bin=self.openssl_bin,
            )
            envelope = sign_pool_promotion_transition(
                signed_payload(journey_result_digest(candidate)),
                private_key_pem=fixture["private_pem"],
                public_key_pem=fixture["public_pem"],
                key_id=PRODUCTION_RELEASE_KEY_ID,
                openssl_bin=self.openssl_bin,
                verified_at="2026-08-25T11:00:00Z",
            )
            result = validate_pool_promotion_transition(
                root,
                envelope,
                candidate,
                now=NOW,
                openssl_bin=self.openssl_bin,
                trusted_journey_result_public_key_sha256=fixture["candidate_key_sha256"],
            )
            joined = "\n".join(result.errors)
            self.assertIn("consumed_authorization_id", joined)
            self.assertIn("production_transition_epoch", joined)
            self.assertIn("promotion_verification_result", joined)

    def test_rejects_camelcase_forbidden_fields(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            fixture = write_promotion_root(root, self.openssl_bin)
            candidate = sign_candidate_envelope(
                candidate_payload(productionReleaseKeyId=PRODUCTION_RELEASE_KEY_ID, promotionVerificationResult="pass"),
                private_key_pem=fixture["acceptance_private"],
                public_key_pem=fixture["acceptance_public"],
                openssl_bin=self.openssl_bin,
            )
            envelope = sign_pool_promotion_transition(
                signed_payload(journey_result_digest(candidate)),
                private_key_pem=fixture["private_pem"],
                public_key_pem=fixture["public_pem"],
                key_id=PRODUCTION_RELEASE_KEY_ID,
                openssl_bin=self.openssl_bin,
                verified_at="2026-08-25T11:00:00Z",
            )
            result = validate_pool_promotion_transition(
                root,
                envelope,
                candidate,
                now=NOW,
                openssl_bin=self.openssl_bin,
                trusted_journey_result_public_key_sha256=fixture["candidate_key_sha256"],
            )
            joined = "\n".join(result.errors)
            self.assertIn("productionReleaseKeyId", joined)
            self.assertIn("promotionVerificationResult", joined)

    def test_missing_ledger_is_fail_closed_and_not_recreated(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            fixture = write_promotion_root(root, self.openssl_bin)
            first = consume_pool_promotion_transition(
                root,
                fixture["envelope"],
                fixture["candidate"],
                now=NOW,
                openssl_bin=self.openssl_bin,
                trusted_journey_result_public_key_sha256=fixture["candidate_key_sha256"],
            )
            self.assertEqual([], first.errors)
            (root / LEDGER_PATH).unlink()
            replay = consume_pool_promotion_transition(
                root,
                fixture["envelope"],
                fixture["candidate"],
                now=NOW,
                openssl_bin=self.openssl_bin,
                trusted_journey_result_public_key_sha256=fixture["candidate_key_sha256"],
            )
            self.assertTrue(any("missing append-only promotion ledger" in error for error in replay.errors))
            self.assertFalse((root / LEDGER_PATH).exists())

    def test_empty_or_malformed_ledger_init_is_fail_closed(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            fixture = write_promotion_root(root, self.openssl_bin)
            (root / LEDGER_PATH).write_text("", encoding="utf-8")
            empty = consume_pool_promotion_transition(
                root,
                fixture["envelope"],
                fixture["candidate"],
                now=NOW,
                openssl_bin=self.openssl_bin,
                trusted_journey_result_public_key_sha256=fixture["candidate_key_sha256"],
            )
            self.assertTrue(any("canonical ledger_init" in error for error in empty.errors))
            self.assertEqual("", (root / LEDGER_PATH).read_text(encoding="utf-8"))
            (root / LEDGER_PATH).write_text('{"type":"ledger_init"}\n', encoding="utf-8")
            malformed = consume_pool_promotion_transition(
                root,
                fixture["envelope"],
                fixture["candidate"],
                now=NOW,
                openssl_bin=self.openssl_bin,
                trusted_journey_result_public_key_sha256=fixture["candidate_key_sha256"],
            )
            self.assertTrue(any("canonical ledger_init" in error for error in malformed.errors))
            self.assertEqual('{"type":"ledger_init"}\n', (root / LEDGER_PATH).read_text(encoding="utf-8"))

    def test_rejects_keyid_value_alias(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            fixture = write_promotion_root(root, self.openssl_bin)
            candidate = sign_candidate_envelope(
                candidate_payload(keyId=PRODUCTION_RELEASE_KEY_ID),
                private_key_pem=fixture["acceptance_private"],
                public_key_pem=fixture["acceptance_public"],
                openssl_bin=self.openssl_bin,
            )
            envelope = sign_pool_promotion_transition(
                signed_payload(journey_result_digest(candidate)),
                private_key_pem=fixture["private_pem"],
                public_key_pem=fixture["public_pem"],
                key_id=PRODUCTION_RELEASE_KEY_ID,
                openssl_bin=self.openssl_bin,
                verified_at="2026-08-25T11:00:00Z",
            )
            result = validate_pool_promotion_transition(
                root,
                envelope,
                candidate,
                now=NOW,
                openssl_bin=self.openssl_bin,
                trusted_journey_result_public_key_sha256=fixture["candidate_key_sha256"],
            )
            self.assertTrue(any("keyId" in error for error in result.errors))


if __name__ == "__main__":
    unittest.main()
