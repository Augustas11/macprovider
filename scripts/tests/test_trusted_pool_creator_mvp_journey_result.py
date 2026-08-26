from __future__ import annotations

import hashlib
import importlib.util
import json
import tempfile
import unittest
from pathlib import Path

from scripts.check_spec_governance import (
    TRUSTED_POOL_CREATOR_MVP_ARTIFACT_ID,
    TRUSTED_POOL_CREATOR_MVP_JOURNEY_ID,
    TRUSTED_POOL_CREATOR_MVP_STEP_ID_ORDER,
    ValidationResult,
    _signed_journey_result_satisfies,
    _validate_trusted_pool_creator_mvp_journey_result,
)

REPO_ROOT = Path(__file__).resolve().parents[2]
FINGERPRINT = "a" * 64


def load_builder():
    path = REPO_ROOT / "scripts" / "build-trusted-pool-creator-mvp-journey-result.py"
    import sys

    scripts = str(REPO_ROOT / "scripts")
    inserted = scripts not in sys.path
    if inserted:
        sys.path.insert(0, scripts)
    spec = importlib.util.spec_from_file_location("trusted_pool_creator_mvp_builder", path)
    module = importlib.util.module_from_spec(spec)
    assert spec.loader is not None
    try:
        spec.loader.exec_module(module)
        return module
    finally:
        if inserted:
            sys.path.remove(scripts)


def valid_signed(*, requirement_ids=None, extra_requirement=None, **overrides):
    ids = list(requirement_ids or ["SPEC-043-R002"])
    if extra_requirement:
        ids.append(extra_requirement)
    signed = {
        "journey_id": TRUSTED_POOL_CREATOR_MVP_JOURNEY_ID,
        "execution_mode": "isolated-candidate-trusted-pool-creator-mvp",
        "requirement_ids": ids,
        "captured_at": "2026-08-25T05:54:25Z",
        "expires_at": "2026-08-25",
        "observations": {
            "approved_creator_record_bound": True,
            "buyer_authorization_enforced": True,
            "candidate_manifest_accepted": True,
            "creator_admin_authorized_only": True,
            "creator_suspension_root_compromise_freeze_verified": True,
            "delegation_revocation_verified": True,
            "descendant_signer_rejection_verified": True,
            "emergency_pause_exercised": True,
            "fail_closed_no_global_fallback": True,
            "isolated_environment": True,
            "no_duplicate_settlement": True,
            "no_private_key_upload": True,
            "no_raw_prompt_output_artifact": True,
            "pool_existence_oracle_within_threshold": True,
            "raw_prompt_output_redacted": True,
            "restart_reconstruction_verified": True,
            "root_registration_replay_checked": True,
            "settlement_labels_bound": True,
            "successful_pooled_request": True,
            "coordinator_blind_claimed": False,
            "global_fallback_observed": False,
            "payout_ready_mutated": False,
            "privacy_pool_claimed": False,
            "production_side_effects": False,
            "public_announcement_without_reviewed_artifact_observed": False,
            "unrestricted_creator_admin_observed": False,
        },
        "pool_rejection_timing": {
            "floor_ms": 50,
            "method": "active_sleep_to_floor",
            "sample_count_per_class": 16,
            "classes_covered": ["unknown", "unauthorized", "disabled"],
            "p95_delta_ms": 1.5,
            "p99_delta_ms": 2.0,
            "mann_whitney_p_value": 0.42,
            "statistical_test": "two-sided Mann-Whitney U with normal approximation; fail if p < 0.01",
        },
        "candidate_identity": {
            "approval_record_id": "approval-alpha",
            "approval_record_version": "2",
            "artifact_set_sha256": FINGERPRINT,
            "buyer_credential_fingerprint": FINGERPRINT,
            "clock_skew_allowance_seconds": 60,
            "coordinator_build_id": "coordinator-build-alpha",
            "coordinator_config_sha256": FINGERPRINT,
            "creator_account_fingerprint": FINGERPRINT,
            "creator_agreement_id": "agreement-alpha",
            "creator_agreement_expires_at": "2026-09-01T00:00:00Z",
            "creator_agreement_grace_ends_at": "2026-09-08T00:00:00Z",
            "creator_agreement_version": "1",
            "effective_config_digest": FINGERPRINT,
            "environment_id": "candidate-alpha",
            "feature_flag_digest": FINGERPRINT,
            "gate_check_id": "gate-check-alpha",
            "gateway_build_id": "gateway-build-alpha",
            "gateway_config_sha256": FINGERPRINT,
            "governance_file_digest": FINGERPRINT,
            "lifecycle_state": "active",
            "manifest_core_digest": FINGERPRINT,
            "manifest_version": "7",
            "maximum_ttl_seconds": 86400,
            "operation_ids_fingerprint": FINGERPRINT,
            "pool_generation": "11",
            "pool_id": "pool_alpha",
            "pricing_schedule_id": "pricing-alpha",
            "pricing_schedule_version": "3",
            "provider_build_id": "provider-build-alpha",
            "provider_identity_fingerprint": FINGERPRINT,
            "readiness_observations_fingerprint": FINGERPRINT,
            "reviewed_distribution_artifact_digest": FINGERPRINT,
            "root_issuer_fingerprint": FINGERPRINT,
            "route_snapshot_digest": FINGERPRINT,
            "verifier_challenge": "challenge-alpha",
            "verifier_command": "scripts/run-trusted-pool-creator-mvp-journey",
            "verifier_result": "pass",
        },
        "artifacts": [
            {
                "id": TRUSTED_POOL_CREATOR_MVP_ARTIFACT_ID,
                "sha256": FINGERPRINT,
                "source": "journeys/evidence/trusted-pool-creator-mvp-alpha.redacted.json",
            }
        ],
        "steps": [
            {"id": step_id, "status": "pass", "artifacts": [TRUSTED_POOL_CREATOR_MVP_ARTIFACT_ID]}
            for step_id in TRUSTED_POOL_CREATOR_MVP_STEP_ID_ORDER
        ],
    }
    signed.update(overrides)
    return signed


class TrustedPoolCreatorMVPJourneyResultTests(unittest.TestCase):
    def test_valid_payload_accepts_all_spec043_pending_rows(self) -> None:
        for index in range(1, 13):
            requirement_id = f"SPEC-043-R{index:03d}"
            result = ValidationResult()
            signed = valid_signed(requirement_ids=[requirement_id])
            _validate_trusted_pool_creator_mvp_journey_result(
                signed,
                requirement_id,
                [TRUSTED_POOL_CREATOR_MVP_JOURNEY_ID],
                signed["artifacts"],
                signed["steps"],
                "evidence[0]",
                result,
            )
            self.assertEqual([], result.errors, requirement_id)

    def test_rejects_expires_at_after_captured_utc_date(self) -> None:
        result = ValidationResult()
        signed = valid_signed()
        signed["expires_at"] = "2026-08-26"
        _validate_trusted_pool_creator_mvp_journey_result(
            signed,
            "SPEC-043-R012",
            [TRUSTED_POOL_CREATOR_MVP_JOURNEY_ID],
            signed["artifacts"],
            signed["steps"],
            "evidence[0]",
            result,
        )
        self.assertTrue(any("captured_at" in error for error in result.errors))

    def test_rejects_broad_or_unmapped_requirement(self) -> None:
        result = ValidationResult()
        signed = valid_signed(requirement_ids=["SPEC-042-R002"])
        _validate_trusted_pool_creator_mvp_journey_result(
            signed,
            "SPEC-042-R002",
            [TRUSTED_POOL_CREATOR_MVP_JOURNEY_ID],
            signed["artifacts"],
            signed["steps"],
            "evidence[0]",
            result,
        )
        self.assertTrue(any("cannot promote SPEC-042-R002" in error for error in result.errors))

    def test_rejects_privacy_overclaim_flags_and_text(self) -> None:
        result = ValidationResult()
        signed = valid_signed(result={"status": "pass", "summary": "proves Privacy Pool unlinkability"})
        signed["observations"]["privacy_pool_claimed"] = True
        signed["steps"][0]["assertion"] = "coordinator blindness proven"
        _validate_trusted_pool_creator_mvp_journey_result(
            signed,
            "SPEC-043-R002",
            [TRUSTED_POOL_CREATOR_MVP_JOURNEY_ID],
            signed["artifacts"],
            signed["steps"],
            "evidence[0]",
            result,
        )
        self.assertTrue(any("signed.result.summary" in error for error in result.errors))
        self.assertTrue(any("signed.steps[0].assertion" in error for error in result.errors))
        self.assertTrue(any("privacy_pool_claimed" in error for error in result.errors))

    def test_rejects_global_fallback_and_public_visibility_without_review(self) -> None:
        result = ValidationResult()
        signed = valid_signed()
        signed["observations"]["global_fallback_observed"] = True
        signed["observations"]["public_announcement_without_reviewed_artifact_observed"] = True
        _validate_trusted_pool_creator_mvp_journey_result(
            signed,
            "SPEC-043-R005",
            [TRUSTED_POOL_CREATOR_MVP_JOURNEY_ID],
            signed["artifacts"],
            signed["steps"],
            "evidence[0]",
            result,
        )
        self.assertTrue(any("global_fallback_observed" in error for error in result.errors))
        self.assertTrue(any("public_announcement_without_reviewed_artifact_observed" in error for error in result.errors))

    def test_accepts_legacy_pre_freeze_observations(self) -> None:
        result = ValidationResult()
        signed = valid_signed(requirement_ids=["SPEC-043-R012"])
        signed["observations"]["creator_suspension_root_compromise_freeze_verified"] = False
        signed["observations"]["descendant_signer_rejection_verified"] = False
        _validate_trusted_pool_creator_mvp_journey_result(
            signed,
            "SPEC-043-R012",
            [TRUSTED_POOL_CREATOR_MVP_JOURNEY_ID],
            signed["artifacts"],
            signed["steps"],
            "evidence[0]",
            result,
        )
        self.assertEqual(result.errors, [])

    def test_rejects_mixed_freeze_observations(self) -> None:
        result = ValidationResult()
        signed = valid_signed(requirement_ids=["SPEC-043-R012"])
        signed["observations"]["descendant_signer_rejection_verified"] = False
        _validate_trusted_pool_creator_mvp_journey_result(
            signed,
            "SPEC-043-R012",
            [TRUSTED_POOL_CREATOR_MVP_JOURNEY_ID],
            signed["artifacts"],
            signed["steps"],
            "evidence[0]",
            result,
        )
        self.assertTrue(any("freeze observations" in error for error in result.errors))

    def test_rejects_missing_identity_field(self) -> None:
        result = ValidationResult()
        signed = valid_signed()
        signed["candidate_identity"].pop("reviewed_distribution_artifact_digest")
        _validate_trusted_pool_creator_mvp_journey_result(
            signed,
            "SPEC-043-R009",
            [TRUSTED_POOL_CREATOR_MVP_JOURNEY_ID],
            signed["artifacts"],
            signed["steps"],
            "evidence[0]",
            result,
        )
        self.assertTrue(any("reviewed_distribution_artifact_digest" in error for error in result.errors))

    def test_rejects_missing_journey_contract_identity_fields(self) -> None:
        required_fields = (
            "verifier_challenge",
            "coordinator_build_id",
            "gateway_build_id",
            "provider_build_id",
            "effective_config_digest",
            "artifact_set_sha256",
            "creator_agreement_expires_at",
            "creator_agreement_grace_ends_at",
            "gate_check_id",
            "readiness_observations_fingerprint",
            "operation_ids_fingerprint",
        )
        for field_name in required_fields:
            result = ValidationResult()
            signed = valid_signed()
            signed["candidate_identity"].pop(field_name)
            _validate_trusted_pool_creator_mvp_journey_result(
                signed,
                "SPEC-043-R012",
                [TRUSTED_POOL_CREATOR_MVP_JOURNEY_ID],
                signed["artifacts"],
                signed["steps"],
                "evidence[0]",
                result,
            )
            self.assertTrue(any(field_name in error for error in result.errors), field_name)

    def test_rejects_bad_journey_contract_ttl_and_verifier_result(self) -> None:
        result = ValidationResult()
        signed = valid_signed()
        signed["candidate_identity"]["maximum_ttl_seconds"] = 86401
        signed["candidate_identity"]["clock_skew_allowance_seconds"] = 301
        signed["candidate_identity"]["creator_agreement_expires_at"] = "2026-09-01"
        signed["candidate_identity"]["verifier_result"] = "failed"
        _validate_trusted_pool_creator_mvp_journey_result(
            signed,
            "SPEC-043-R012",
            [TRUSTED_POOL_CREATOR_MVP_JOURNEY_ID],
            signed["artifacts"],
            signed["steps"],
            "evidence[0]",
            result,
        )
        self.assertTrue(any("maximum_ttl_seconds" in error for error in result.errors))
        self.assertTrue(any("clock_skew_allowance_seconds" in error for error in result.errors))
        self.assertTrue(any("creator_agreement_expires_at" in error for error in result.errors))
        self.assertTrue(any("verifier_result" in error for error in result.errors))

    def test_rejects_missing_journey_contract_observations(self) -> None:
        required_fields = (
            "no_duplicate_settlement",
            "no_private_key_upload",
            "no_raw_prompt_output_artifact",
            "pool_existence_oracle_within_threshold",
            "delegation_revocation_verified",
            "creator_suspension_root_compromise_freeze_verified",
            "descendant_signer_rejection_verified",
        )
        for field_name in required_fields:
            result = ValidationResult()
            signed = valid_signed()
            signed["observations"].pop(field_name)
            _validate_trusted_pool_creator_mvp_journey_result(
                signed,
                "SPEC-043-R012",
                [TRUSTED_POOL_CREATOR_MVP_JOURNEY_ID],
                signed["artifacts"],
                signed["steps"],
                "evidence[0]",
                result,
            )
            self.assertTrue(any(field_name in error for error in result.errors), field_name)

    def test_rejects_step_order_swap(self) -> None:
        result = ValidationResult()
        signed = valid_signed()
        signed["steps"][0], signed["steps"][1] = signed["steps"][1], signed["steps"][0]
        _validate_trusted_pool_creator_mvp_journey_result(
            signed,
            "SPEC-043-R012",
            [TRUSTED_POOL_CREATOR_MVP_JOURNEY_ID],
            signed["artifacts"],
            signed["steps"],
            "evidence[0]",
            result,
        )
        self.assertTrue(any("physical steps must be ordered" in error for error in result.errors))

    def test_evidence_only_journey_cannot_satisfy_conformant_requirement(self) -> None:
        envelope = {"schema_version": "macprovider.journey-result-envelope.v1", "signatures": [], "signed": valid_signed()}
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            evidence_dir = root / "journeys" / "evidence"
            evidence_dir.mkdir(parents=True)
            source = evidence_dir / "trusted-pool-creator-mvp-alpha.signed.json"
            source.write_text(json.dumps(envelope, indent=2) + "\n", encoding="utf-8")
            digest = hashlib.sha256(source.read_bytes()).hexdigest()
            result = ValidationResult()
            requirement = {
                "requirement_id": "SPEC-043-R002",
                "journeys": [TRUSTED_POOL_CREATOR_MVP_JOURNEY_ID],
                "evidence": [
                    {
                        "artifact": f"sha256:{digest}",
                        "source": "journeys/evidence/trusted-pool-creator-mvp-alpha.signed.json",
                    }
                ],
            }

            self.assertFalse(
                _signed_journey_result_satisfies(
                    root,
                    requirement,
                    "SPEC-043-R002",
                    result,
                    trusted_public_key_sha256="",
                    openssl_bin="openssl",
                )
            )
            self.assertTrue(any("evidence-only and cannot satisfy conformant requirements" in error for error in result.errors))

    def test_builder_rejects_overclaims_and_forbidden_requirements(self) -> None:
        builder = load_builder()
        with self.assertRaises(SystemExit):
            builder.parse_requirement_ids("SPEC-042-R002", {"requirement_ids": ["SPEC-042-R002"]})
        self.assertEqual(
            builder.parse_requirement_ids(
                "SPEC-043-R002,SPEC-043-R005",
                {"requirement_ids": ["SPEC-043-R002", "SPEC-043-R005"]},
            ),
            ["SPEC-043-R002", "SPEC-043-R005"],
        )
        with self.assertRaises(SystemExit):
            builder.require_observations({"successful_pooled_request": True})
        observations = valid_signed()["observations"]
        self.assertEqual(observations, builder.require_observations(observations))
        observations = dict(observations)
        observations["coordinator_blind_claimed"] = True
        with self.assertRaises(SystemExit):
            builder.require_observations(observations)
        freeze = dict(valid_signed()["observations"])
        freeze["creator_suspension_root_compromise_freeze_verified"] = False
        with self.assertRaises(SystemExit):
            builder.require_observations(freeze)
        delegation = dict(valid_signed()["observations"])
        delegation["delegation_revocation_verified"] = False
        with self.assertRaises(SystemExit):
            builder.require_observations(delegation)
        oracle = dict(valid_signed()["observations"])
        oracle["pool_existence_oracle_within_threshold"] = False
        with self.assertRaises(SystemExit):
            builder.require_observations(oracle)
        builder.require_same_utc_day_expiry("2026-08-25T05:54:25Z", "2026-08-25")
        with self.assertRaises(SystemExit):
            builder.require_same_utc_day_expiry("2026-08-25T05:54:25Z", "2026-08-26")
        extra = dict(valid_signed()["observations"])
        extra["authorization_header"] = "sk-proj-" + ("a" * 48)
        with self.assertRaises(SystemExit):
            builder.require_observations(extra)
        with self.assertRaises(SystemExit):
            builder.layer2.reject_forbidden_secret_keys({"notes": "sk-proj-" + ("a" * 48)})
        builder.reject_creator_mvp_secret_keys({"observations": valid_signed()["observations"], "notes": "ok"})
        with self.assertRaises(SystemExit):
            builder.reject_creator_mvp_secret_keys({"authorization_header": "secret", "observations": valid_signed()["observations"]})
        leaked = dict(valid_signed()["observations"])
        leaked["notes"] = "sk-proj-" + ("a" * 48)
        with self.assertRaises(SystemExit):
            builder.reject_creator_mvp_secret_keys({"observations": leaked, "notes": "ok"})

    def test_builder_normalizes_rich_source_redaction_for_signed_payload(self) -> None:
        builder = load_builder()
        rich_redaction = {
            "secrets_redacted": True,
            "operator_identity_redacted": True,
            "local_account_names_redacted": True,
            "artifact_id": "redacted-trusted-pool-creator-mvp",
            "bearer_tokens_redacted": True,
            "buyer_credential_redacted": True,
            "creator_identity_redacted": True,
            "provider_identity_redacted": True,
            "raw_prompt_output_redacted": True,
            "redaction_reviewed_by_human": True,
        }
        self.assertEqual(
            {
                "secrets_redacted": True,
                "operator_identity_redacted": True,
                "local_account_names_redacted": True,
            },
            builder.require_signed_redaction(rich_redaction),
        )

    def test_builder_rejects_false_rich_source_redaction_flag(self) -> None:
        builder = load_builder()
        redaction = {
            "secrets_redacted": True,
            "operator_identity_redacted": True,
            "local_account_names_redacted": True,
            "creator_identity_redacted": False,
        }
        with self.assertRaises(SystemExit):
            builder.require_signed_redaction(redaction)


if __name__ == "__main__":
    unittest.main()
