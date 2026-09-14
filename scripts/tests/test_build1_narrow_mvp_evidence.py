from __future__ import annotations

import importlib.util
import sys
import unittest
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parents[2]
SCRIPT = REPO_ROOT / "scripts" / "validate-build1-narrow-mvp-evidence.py"
_spec = importlib.util.spec_from_file_location("build1_narrow_mvp_evidence", SCRIPT)
assert _spec and _spec.loader
mod = importlib.util.module_from_spec(_spec)
sys.modules[_spec.name] = mod
_spec.loader.exec_module(mod)

REQUEST_ID = "req-build1-mvp-1"
PROVIDER_ID = "mp-provider-1"
HARDWARE_CONTEXT_ID = "hw-m2-max-1"
ADMISSION_EVENT_ID = "adm-build1-mvp-1"
ROUTE_SNAPSHOT_DIGEST = "9" * 64
CANDIDATE_CATALOG_DIGEST = "3" * 64
USAGE = {
    "billable_input_tokens": 80,
    "billable_output_tokens": 120,
    "delivered_output_bytes": 960,
    "observed_input_tokens": 80,
    "observed_output_tokens": 120,
}


def valid_evidence() -> dict:
    evidence = {
        "schema_version": mod.SCHEMA_VERSION,
        "build_id": mod.BUILD_ID,
        "validation_scope": "schema_valid_structural_only",
        "evidence_class": "physical_staging",
        "captured_at": "2026-09-14T10:00:00Z",
        "repository": {"name": "Augustas11/macprovider", "commit": "1" * 40, "branch": "codex/build1-mvp-narrow"},
        "scope": {
            "production_activation_enabled": False,
            "production_enforcement_changed": False,
            "production_rewards_enabled": False,
            "payout_jobs_enabled": False,
            "payout_execution_enabled": False,
            "release_published": False,
        },
        "capture": {
            "command": "scripts/collect-build1-narrow-mvp-evidence --redacted",
            "started_at": "2026-09-14T09:55:00Z",
            "completed_at": "2026-09-14T10:00:00Z",
            "binary_version": "0.4.0-test",
            "binary_sha256": "5" * 64,
            "redaction_passed": True,
            "skipped": False,
            "operator_notes": "redacted physical staging run",
            "source_captures": {
                "review_required": True,
                "manifest_sha256": "a" * 64,
                "physical_run_log_sha256": "b" * 64,
                "request_transcript_sha256": "c" * 64,
                "status_before_sha256": "d" * 64,
                "status_after_sha256": "e" * 64,
                "provider_receipt_audit_sha256": "f" * 64,
                "coordinator_route_snapshot_sha256": "1" * 64,
                "coordinator_settlement_verdict_sha256": "2" * 64,
                "redaction_report_sha256": "3" * 64,
            },
        },
        "profile": {
            "catalog_key": mod.CATALOG_KEY,
            "model_id": mod.MODEL_ID,
            "runtime_source": mod.RUNTIME_SOURCE,
            "artifact_id": mod.ARTIFACT_ID,
            "model_revision": mod.MODEL_REVISION,
            "artifact_hash_algorithm": mod.ARTIFACT_HASH_ALGORITHM,
            "artifact_hash": mod.ARTIFACT_HASH,
            "rate": {
                "rate_card_key": mod.RATE_CARD_KEY,
                "prompt_rate_per_mtok": mod.PROMPT_RATE,
                "prompt_cache_hit_rate_per_mtok": mod.CACHED_PROMPT_RATE,
                "completion_rate_per_mtok": mod.COMPLETION_RATE,
                "provider_share_bps": mod.PROVIDER_SHARE_BPS,
                "global_multiplier_ppm": mod.GLOBAL_MULTIPLIER_PPM,
                "usd_per_million_credits": mod.USD_PER_MILLION_CREDITS,
            },
        },
        "environment": {
            "class": "staging",
            "verified_model_settlement_mode": "enforce",
            "staging_isolated": True,
            "production_endpoints_untouched": True,
            "credentials_redacted": True,
            "secrets_redacted": True,
        },
        "staging_config": {
            "environment_id": "staging-build1-mvp",
            "verified_model_settlement_mode": "enforce",
            "coordinator_url_redacted": True,
            "gateway_url_redacted": True,
            "rewards_disabled": True,
            "operator_payment_jobs_disabled": True,
            "operator_payment_execution_disabled": True,
            "production_enforcement_unchanged": True,
            "policy_version": mod.ROUTE_SNAPSHOT_POLICY_VERSION,
            "config_source_kind": "deploy_config_snapshot",
            "config_digest": "c" * 64,
            "deploy_event_id": "deploy-build1-mvp-1",
            "captured_at": "2026-09-14T09:54:00Z",
            "settlement_mode_source": "redacted staging coordinator config capture",
            "rewards_disabled_source": "redacted staging job config capture",
            "operator_payment_jobs_disabled_source": "redacted staging job config capture",
            "operator_payment_execution_disabled_source": "redacted staging operator config capture",
            "production_enforcement_source": "redacted production config diff capture",
            "rewards_disabled_evidence_digest": "d" * 64,
            "operator_payment_jobs_disabled_evidence_digest": "e" * 64,
            "operator_payment_execution_disabled_evidence_digest": "f" * 64,
            "production_enforcement_evidence_digest": "0" * 64,
        },
        "hardware": {
            "context_id": HARDWARE_CONTEXT_ID,
            "chip": "Apple M2 Max",
            "ram_gb": 64,
            "free_disk_bytes": 100_000_000_000,
            "os_version": "macOS 15.6",
            "binary_version": "0.4.0-test",
            "binary_sha256": "5" * 64,
        },
        "runtime": {
            "source": mod.RUNTIME_SOURCE,
            "mlx_version": "0.26.0",
            "context_profile": "batch-1-context-4096",
            "max_concurrency": 1,
            "hardware_context_id": HARDWARE_CONTEXT_ID,
        },
        "artifact_feed": {
            "freshness": "fresh",
            "signature_verified": True,
            "release_bound": True,
            "measured_size": True,
            "size_bytes": 4_900_000_000,
            "feed_sha256": "2" * 64,
            "candidate_catalog_sha256": CANDIDATE_CATALOG_DIGEST,
            "release_id": "build1-mvp-staging-release-20260914",
            "artifact_feed_signer_key_id": mod.TRUSTED_ARTIFACT_FEED_SIGNER_KEY_ID,
            "verification_status": "verified",
            "primary_artifact_id": mod.ARTIFACT_ID,
            "artifact_hash_algorithm": mod.ARTIFACT_HASH_ALGORITHM,
            "artifact_hash": mod.ARTIFACT_HASH,
            "route_binding": {
                "artifact_feed_sha256": "2" * 64,
                "artifact_id": mod.ARTIFACT_ID,
                "artifact_hash": mod.ARTIFACT_HASH,
                "artifact_hash_algorithm": mod.ARTIFACT_HASH_ALGORITHM,
                "artifact_feed_signer_key_id": mod.TRUSTED_ARTIFACT_FEED_SIGNER_KEY_ID,
                "candidate_catalog_body_digest": CANDIDATE_CATALOG_DIGEST,
            },
        },
        "preparation": {
            "status": "adopted",
            "artifact_hash": mod.ARTIFACT_HASH,
            "size_bytes": 4_900_000_000,
            "available_disk_bytes": 100_000_000_000,
            "staged_bytes": 4_900_000_000,
            "snapshot_manifest_verified": True,
            "cancellation_preserves_active_model": True,
            "recovery_safe": True,
            "adopted_model_id": mod.MODEL_ID,
            "inventory_digest": "4" * 64,
            "weights_manifest_sha256": "6" * 64,
        },
        "provider": {
            "kind": "physical_mlx_cli",
            "fake_provider": False,
            "provider_id": PROVIDER_ID,
            "binary_sha256": "5" * 64,
            "binary_version": "0.4.0-test",
            "pid": 4242,
            "hardware_context_id": HARDWARE_CONTEXT_ID,
            "runtime_source": mod.RUNTIME_SOURCE,
            "receipt_key_available": True,
            "receipt_audit_cursor_before": "cursor-redacted-1",
            "status_before": {
                "endpoint": "GET /v1/status",
                "status": "ready",
                "model_loaded": True,
                "model": mod.MODEL_ID,
                "model_hash": mod.ARTIFACT_HASH,
                "model_hash_algorithm": mod.ARTIFACT_HASH_ALGORITHM,
                "weights_manifest_sha256": "6" * 64,
                "weights_manifest_algorithm": mod.WEIGHTS_MANIFEST_ALGORITHM,
            },
            "status_after": {
                "endpoint": "GET /v1/status",
                "status": "ready",
                "model_loaded": True,
                "model": mod.MODEL_ID,
                "model_hash": mod.ARTIFACT_HASH,
                "model_hash_algorithm": mod.ARTIFACT_HASH_ALGORITHM,
                "weights_manifest_sha256": "6" * 64,
                "weights_manifest_algorithm": mod.WEIGHTS_MANIFEST_ALGORITHM,
            },
            "correlation": {
                "source": "receipt_audit",
                "event_type": "receipt_issued",
                "timestamp": "2026-09-14T09:59:00Z",
                "cursor": "cursor-redacted-2",
                "served_count_supporting_only": True,
                "request_id": REQUEST_ID,
                "provider_id": PROVIDER_ID,
                "model_id": mod.MODEL_ID,
                "tokens_out": USAGE["billable_output_tokens"],
                "ttft_ms": 125,
                "unix_ts": 1789379940,
                "receipt_metadata_present": True,
            },
        },
        "admission": {
            "event_id": ADMISSION_EVENT_ID,
            "source": "coordinator",
            "environment_id": "staging-build1-mvp",
            "state": "settlement_capable",
            "provider_id": PROVIDER_ID,
            "model_id": mod.MODEL_ID,
            "catalog_key": mod.CATALOG_KEY,
            "artifact_hash": mod.ARTIFACT_HASH,
            "receipt_key_available": True,
            "verified_model_settlement_mode": "enforce",
            "rate_card_key": mod.RATE_CARD_KEY,
            "model_admission_candidate_id": "byom-build1-mvp-candidate",
            "model_admission_coordinator_event_id": "7" * 64,
            "model_admission_served_model_ref": "mlx-cache:llama-3.2-3b-instruct-4bit",
            "model_admission_catalog_model_key": mod.CATALOG_KEY,
            "model_admission_discovery_digest_sha256": "8" * 64,
            "model_admission_evaluation_digest_sha256": "9" * 64,
        },
        "request": {
            "request_id": REQUEST_ID,
            "model": mod.MODEL_ID,
            "streaming": False,
            "response_status": 200,
            "actual_mlx_inference": True,
            "route_provider_id": PROVIDER_ID,
            "admission_event_id": ADMISSION_EVENT_ID,
            "usage": dict(USAGE),
        },
        "route_snapshot": {
            "route_snapshot_digest": ROUTE_SNAPSHOT_DIGEST,
            "artifact_binding_digest": "8" * 64,
            "artifact_binding_source": "route_snapshot_referenced_immutable_record",
            "artifact_binding": {
                "artifact_feed_sha256": "2" * 64,
                "artifact_id": mod.ARTIFACT_ID,
                "artifact_hash": mod.ARTIFACT_HASH,
                "artifact_hash_algorithm": mod.ARTIFACT_HASH_ALGORITHM,
                "artifact_feed_signer_key_id": mod.TRUSTED_ARTIFACT_FEED_SIGNER_KEY_ID,
                "candidate_catalog_body_digest": CANDIDATE_CATALOG_DIGEST,
            },
            "route_snapshot_v1": {
                "account_scope": "staging-build1-mvp-account",
                "request_id": REQUEST_ID,
                "attempt_n": 0,
                "provider_id": PROVIDER_ID,
                "provider_session_id": "session-redacted-1",
                "provider_generation_id": "generation-redacted-1",
                "paid_entrypoint": "staging-gateway-chat-completions",
                "provider_receipt_key_id": "ed25519-sha256:" + "1" * 64,
                "provider_receipt_key_source": "auth_session",
                "model_id": mod.MODEL_ID,
                "provider_reported_model_hash": mod.ARTIFACT_HASH,
                "provider_reported_model_hash_algorithm": mod.ARTIFACT_HASH_ALGORITHM,
                "expected_catalog_model_hash": mod.ARTIFACT_HASH,
                "expected_catalog_model_hash_algorithm": mod.ARTIFACT_HASH_ALGORITHM,
                "catalog_id": mod.CATALOG_KEY,
                "catalog_body_digest": CANDIDATE_CATALOG_DIGEST,
                "model_admission_candidate_id": "byom-build1-mvp-candidate",
                "model_admission_coordinator_event_id": "7" * 64,
                "model_admission_served_model_ref": "mlx-cache:llama-3.2-3b-instruct-4bit",
                "model_admission_catalog_model_key": mod.CATALOG_KEY,
                "model_admission_discovery_digest_sha256": "8" * 64,
                "model_admission_evaluation_digest_sha256": "9" * 64,
                "artifact_feed_sha256": "2" * 64,
                "artifact_id": mod.ARTIFACT_ID,
                "artifact_hash": mod.ARTIFACT_HASH,
                "artifact_hash_algorithm": mod.ARTIFACT_HASH_ALGORITHM,
                "artifact_feed_signer_key_id": mod.TRUSTED_ARTIFACT_FEED_SIGNER_KEY_ID,
                "artifact_candidate_catalog_sha256": CANDIDATE_CATALOG_DIGEST,
                "catalog_signature_key_id": "candidate-catalog-staging-key",
                "catalog_signature_pubkey_fingerprint": "ed25519-sha256:" + "2" * 64,
                "catalog_expires_at_unix_ms": 1_789_380_600_000,
                "spec008_hash_status": "hash_verified",
                "route_snapshot_policy_version": mod.ROUTE_SNAPSHOT_POLICY_VERSION,
                "route_snapshot_mode": "enforce",
                "route_decision_ts_unix_ms": 1_789_379_910_000,
                "request_start_ts_unix_ms": 1_789_379_911_000,
                "pending_deadline_seconds": 300,
                "prompt_hash_basis": "gateway-canonical-request-v1",
                "prompt_hash": "a" * 64,
            },
        },
        "settlement": {
            "verified": True,
            "request_id": REQUEST_ID,
            "provider_id": PROVIDER_ID,
            "model_id": mod.MODEL_ID,
            "catalog_key": mod.CATALOG_KEY,
            "artifact_hash": mod.ARTIFACT_HASH,
            "hardware_context_id": HARDWARE_CONTEXT_ID,
            "route_snapshot_digest": ROUTE_SNAPSHOT_DIGEST,
            "attempt_n": 0,
            "usage": dict(USAGE),
            "cached_billable_input_tokens": 0,
            "credits": 4,
            "provider_share_credits": 4,
            "rate": {
                "rate_card_key": mod.RATE_CARD_KEY,
                "prompt_rate_per_mtok": mod.PROMPT_RATE,
                "prompt_cache_hit_rate_per_mtok": mod.CACHED_PROMPT_RATE,
                "completion_rate_per_mtok": mod.COMPLETION_RATE,
                "provider_share_bps": mod.PROVIDER_SHARE_BPS,
                "global_multiplier_ppm": mod.GLOBAL_MULTIPLIER_PPM,
                "usd_per_million_credits": mod.USD_PER_MILLION_CREDITS,
            },
        },
        "settlement_verdict": {
            "outcome": "verified",
            "receipt_verification_outcome": "verified",
            "request_id": REQUEST_ID,
            "attempt_n": 0,
            "provider_id": PROVIDER_ID,
            "provider_receipt_key_id": "ed25519-sha256:" + "1" * 64,
            "model_id": mod.MODEL_ID,
            "provider_reported_model_hash": mod.ARTIFACT_HASH,
            "expected_catalog_model_hash": mod.ARTIFACT_HASH,
            "catalog_id": mod.CATALOG_KEY,
            "catalog_body_digest": CANDIDATE_CATALOG_DIGEST,
            "route_snapshot_digest": ROUTE_SNAPSHOT_DIGEST,
            "route_snapshot_mode": "enforce",
            "receipt_version": "4",
            "terminal_state": "normal_done",
            "hardware_context_id": HARDWARE_CONTEXT_ID,
            "usage": dict(USAGE),
            "cached_billable_input_tokens": 0,
            "credits": 4,
            "provider_share_credits": 4,
            "artifact_binding": {
                "artifact_feed_sha256": "2" * 64,
                "artifact_id": mod.ARTIFACT_ID,
                "artifact_hash": mod.ARTIFACT_HASH,
                "artifact_hash_algorithm": mod.ARTIFACT_HASH_ALGORITHM,
                "artifact_feed_signer_key_id": mod.TRUSTED_ARTIFACT_FEED_SIGNER_KEY_ID,
                "candidate_catalog_body_digest": CANDIDATE_CATALOG_DIGEST,
            },
        },
        "production_blockers": {
            "production_activation_enabled": False,
            "production_enforcement_changed": False,
            "production_rewards_enabled": False,
            "payout_jobs_enabled": False,
            "payout_execution_enabled": False,
            "release_published": False,
            "qualification": "not_activated",
        },
    }
    artifact_digest = mod._jcs_sha256(evidence["route_snapshot"]["artifact_binding"])
    route_digest = mod._jcs_sha256(evidence["route_snapshot"]["route_snapshot_v1"])
    evidence["route_snapshot"]["artifact_binding_digest"] = artifact_digest
    evidence["route_snapshot"]["route_snapshot_digest"] = route_digest
    evidence["settlement"]["route_snapshot_digest"] = route_digest
    evidence["settlement_verdict"]["route_snapshot_digest"] = route_digest
    return evidence


def rebind_route_digest(evidence: dict) -> None:
    route_digest = mod._jcs_sha256(evidence["route_snapshot"]["route_snapshot_v1"])
    evidence["route_snapshot"]["route_snapshot_digest"] = route_digest
    evidence["settlement"]["route_snapshot_digest"] = route_digest
    evidence["settlement_verdict"]["route_snapshot_digest"] = route_digest


class Build1NarrowMVPEvidenceTests(unittest.TestCase):
    def assert_valid(self, payload: dict) -> None:
        result = mod.validate_build1_narrow_mvp_evidence(payload)
        self.assertEqual(result.errors, [])

    def assert_invalid_contains(self, payload: dict, text: str) -> None:
        result = mod.validate_build1_narrow_mvp_evidence(payload)
        self.assertFalse(result.ok)
        self.assertTrue(any(text in error for error in result.errors), result.errors)

    def test_accepts_valid_physical_staging_evidence(self) -> None:
        self.assert_valid(valid_evidence())

    def test_rejects_fixture_or_fake_provider_evidence(self) -> None:
        payload = valid_evidence()
        payload["evidence_class"] = "fixture_integration"
        payload["provider"]["fake_provider"] = True
        self.assert_invalid_contains(payload, "must match required value")
        self.assert_invalid_contains(payload, "fake_provider")

    def test_rejects_observe_mode_or_production_activation(self) -> None:
        payload = valid_evidence()
        payload["environment"]["verified_model_settlement_mode"] = "observe"
        payload["scope"]["production_activation_enabled"] = True
        payload["scope"]["payout_jobs_enabled"] = True
        self.assert_invalid_contains(payload, "verified_model_settlement_mode")
        self.assert_invalid_contains(payload, "production_activation_enabled")
        self.assert_invalid_contains(payload, "payout_jobs_enabled")

    def test_rejects_contradictory_nested_activation_claims(self) -> None:
        payload = valid_evidence()
        payload["operator_summary"] = {
            "production_rewards_enabled": True,
            "payout_execution_enabled": True,
            "release_published": True,
        }
        self.assert_invalid_contains(payload, "must not claim production economic activation")

    def test_rejects_unmeasured_or_mismatched_artifact_size(self) -> None:
        payload = valid_evidence()
        payload["artifact_feed"]["measured_size"] = False
        payload["artifact_feed"]["size_bytes"] = 0
        payload["preparation"]["size_bytes"] = 123
        self.assert_invalid_contains(payload, "measured_size")
        self.assert_invalid_contains(payload, "size_bytes")

    def test_rejects_missing_feed_authority_fields(self) -> None:
        payload = valid_evidence()
        del payload["artifact_feed"]["artifact_feed_signer_key_id"]
        payload["artifact_feed"]["verification_status"] = "asserted"
        payload["artifact_feed"]["route_binding"]["candidate_catalog_body_digest"] = "0" * 64
        self.assert_invalid_contains(payload, "artifact_feed_signer_key_id")
        self.assert_invalid_contains(payload, "verification_status")
        self.assert_invalid_contains(payload, "candidate_catalog_body_digest")

    def test_rejects_unsupported_model_or_rate(self) -> None:
        payload = valid_evidence()
        payload["profile"]["catalog_key"] = "qwen3-8b"
        payload["profile"]["model_id"] = "mlx-community/Qwen3-8B-4bit"
        payload["profile"]["rate"]["completion_rate_per_mtok"] = 1
        self.assert_invalid_contains(payload, "catalog_key")
        self.assert_invalid_contains(payload, "completion_rate_per_mtok")

    def test_rejects_missing_hardware_context(self) -> None:
        payload = valid_evidence()
        del payload["hardware"]
        self.assert_invalid_contains(payload, "missing hardware")

    def test_rejects_hardware_binary_or_settlement_context_mismatch(self) -> None:
        payload = valid_evidence()
        payload["hardware"]["binary_sha256"] = "0" * 64
        payload["settlement"]["hardware_context_id"] = "hw-other"
        self.assert_invalid_contains(payload, "hardware.binary_sha256")
        self.assert_invalid_contains(payload, "settlement.hardware_context_id")

    def test_rejects_provider_identity_mismatch(self) -> None:
        payload = valid_evidence()
        payload["provider"]["provider_id"] = "mp-physical-other"
        self.assert_invalid_contains(payload, "route_provider_id")
        self.assert_invalid_contains(payload, "admission.provider_id")

    def test_rejects_served_count_only_correlation(self) -> None:
        payload = valid_evidence()
        payload["provider"]["correlation"]["source"] = "served_count_only"
        self.assert_invalid_contains(payload, "served_count_only is not accepted")

    def test_rejects_provider_log_without_receipt_metadata(self) -> None:
        payload = valid_evidence()
        payload["provider"]["correlation"]["source"] = "equivalent_provider_log"
        payload["provider"]["correlation"]["event_type"] = "request_completed"
        del payload["provider"]["correlation"]["tokens_out"]
        self.assert_invalid_contains(payload, "event_type")
        self.assert_invalid_contains(payload, "tokens_out")

    def test_rejects_request_id_or_provider_mismatch(self) -> None:
        payload = valid_evidence()
        payload["provider"]["correlation"]["request_id"] = "req-other"
        payload["settlement"]["provider_id"] = "mp-other"
        self.assert_invalid_contains(payload, "provider.correlation.request_id")
        self.assert_invalid_contains(payload, "settlement.provider_id")

    def test_accepts_weights_manifest_distinct_from_snapshot_hash(self) -> None:
        payload = valid_evidence()
        self.assertNotEqual(payload["provider"]["status_before"]["weights_manifest_sha256"], mod.ARTIFACT_HASH)
        self.assert_valid(payload)

    def test_rejects_status_digest_mismatch_or_wrong_endpoint(self) -> None:
        payload = valid_evidence()
        payload["provider"]["status_before"]["endpoint"] = "GET /status"
        payload["provider"]["status_after"]["model_hash"] = "7" * 64
        payload["provider"]["status_after"]["weights_manifest_sha256"] = "8" * 64
        self.assert_invalid_contains(payload, "status_before.endpoint")
        self.assert_invalid_contains(payload, "status_after.model_hash")
        self.assert_invalid_contains(payload, "must match preparation.weights_manifest_sha256")
        self.assert_invalid_contains(payload, "must equal status_before.weights_manifest_sha256")

    def test_rejects_missing_settlement_contract_fields(self) -> None:
        payload = valid_evidence()
        del payload["route_snapshot"]["route_snapshot_v1"]["provider_receipt_key_id"]
        payload["settlement_verdict"]["route_snapshot_mode"] = "observe"
        payload["settlement"]["usage"]["billable_output_tokens"] = 99
        self.assert_invalid_contains(payload, "provider_receipt_key_id")
        self.assert_invalid_contains(payload, "route_snapshot_mode")
        self.assert_invalid_contains(payload, "settlement.usage")

    def test_accepts_accounting_token_usage_fields(self) -> None:
        payload = valid_evidence()
        usage = {
            "billable_input_tokens": 90,
            "billable_output_tokens": 150,
            "delivered_output_bytes": 1200,
            "observed_input_tokens": 90,
            "observed_output_tokens": 150,
        }
        payload["request"]["usage"] = dict(usage)
        payload["provider"]["correlation"]["tokens_out"] = 150
        payload["settlement"]["usage"] = dict(usage)
        payload["settlement"]["credits"] = 5
        payload["settlement"]["provider_share_credits"] = 4
        payload["settlement_verdict"]["usage"] = dict(usage)
        payload["settlement_verdict"]["credits"] = 5
        payload["settlement_verdict"]["provider_share_credits"] = 4
        self.assert_valid(payload)

    def test_rejects_raw_secret_or_endpoint_values(self) -> None:
        for key, value in {
            "raw_url": "https://staging.example.invalid/path",
            "secret_value": "sk-proj_123456789abcdef",
            "raw_path": "/Users/example/.config/macprovider/token",
        }.items():
            payload = valid_evidence()
            payload["environment"][key] = value
            self.assert_invalid_contains(payload, "unredacted endpoint, path, or credential")

    def test_rejects_bare_bearer_tokens_anywhere(self) -> None:
        for mutation in (
            lambda payload: payload["environment"].__setitem__("auth_header_redacted", "Bearer abcdefghijk"),
            lambda payload: payload.__setitem__("headers", {"x-note": "Bearer abcdefghijk"}),
            lambda payload: payload.__setitem__("events", ["ok", "bearer abcdefghijk"]),
        ):
            payload = valid_evidence()
            mutation(payload)
            self.assert_invalid_contains(payload, "credential-shaped value")

    def test_rejects_private_secret_keys_even_when_value_redacted(self) -> None:
        for key in ("private_key", "payout_wallet", "wallet_private_key", "encrypted_payout_wallet", "payout_kek_hex"):
            payload = valid_evidence()
            payload["provider"][key] = "redacted"
            self.assert_invalid_contains(payload, "forbidden secret-bearing key")

    def test_rejects_incorrect_settlement_math(self) -> None:
        payload = valid_evidence()
        payload["settlement"]["credits"] = 999999999
        payload["settlement_verdict"]["credits"] = 999999999
        self.assert_invalid_contains(payload, "must equal 4")

    def test_prices_cached_billable_input_tokens_with_cache_rate(self) -> None:
        payload = valid_evidence()
        usage = {
            "billable_input_tokens": 80,
            "billable_output_tokens": 100,
            "delivered_output_bytes": 800,
            "observed_input_tokens": 80,
            "observed_output_tokens": 100,
        }
        payload["request"]["usage"] = dict(usage)
        payload["provider"]["correlation"]["tokens_out"] = 100
        payload["settlement"]["usage"] = dict(usage)
        payload["settlement"]["cached_billable_input_tokens"] = 80
        payload["settlement"]["credits"] = 3
        payload["settlement"]["provider_share_credits"] = 3
        payload["settlement_verdict"]["usage"] = dict(usage)
        payload["settlement_verdict"]["cached_billable_input_tokens"] = 80
        payload["settlement_verdict"]["credits"] = 3
        payload["settlement_verdict"]["provider_share_credits"] = 3
        self.assert_valid(payload)

        payload["settlement"]["credits"] = 4
        payload["settlement_verdict"]["credits"] = 4
        self.assert_invalid_contains(payload, "settlement.credits")

    def test_rejects_under_floor_physical_ram(self) -> None:
        for ram_gb in (4, 7):
            payload = valid_evidence()
            payload["hardware"]["ram_gb"] = ram_gb
            self.assert_invalid_contains(payload, "hardware.ram_gb")

    def test_rejects_api_key_field_names(self) -> None:
        for key in ("api_key", "openai_api_key", "x_api_key", "client_key"):
            payload = valid_evidence()
            payload["environment"][key] = "redacted"
            self.assert_invalid_contains(payload, "forbidden secret-bearing key")

    def test_rejects_pem_jwt_or_cloud_token_values_under_neutral_keys(self) -> None:
        for value in (
            "-----BEGIN " + "PRIVATE " + "KEY-----\nabc\n-----END " + "PRIVATE " + "KEY-----",
            "eyJhbGciOiJIUzI1NiJ9.eyJzdWIiOiIxMjM0NTY3ODkwIn0.signaturevalue",
            "AIza" + "a" * 32,
            "ya29." + "b" * 32,
            "glpat-" + "c" * 32,
            "?sv=2024-01-01&sig=" + "d" * 32,
        ):
            payload = valid_evidence()
            payload["operator_log"] = value
            self.assert_invalid_contains(payload, "credential-shaped value")

    def test_rejects_textual_or_numeric_activation_claims(self) -> None:
        for key, value in (
            ("production_activation_enabled", "true"),
            ("production_activated", "yes"),
            ("production_rewards_status", "enabled"),
            ("production_settlement_enforced", 1),
        ):
            payload = valid_evidence()
            payload["operator_summary"] = {key: value}
            self.assert_invalid_contains(payload, "must not claim production economic activation")

    def test_rejects_schemeless_hosts_and_private_paths(self) -> None:
        for key, value in (
            ("coordinator_endpoint", "coordinator.malibu.tech/v1"),
            ("gateway_host", "staging.example.invalid/v1"),
            ("operator_log", "coordinator.malibu.app/v1"),
            ("operator_log", "gateway.malibu.ai/v1"),
            ("operator_log", "api.example.cloud/v1"),
            ("operator_log", "staging.example.co/v1"),
            ("coordinator_endpoint", "coordinator/v1"),
            ("gateway_endpoint", "gateway/v1"),
            ("gateway_endpoint", "staging-gateway/v1"),
            ("coordinator_host", "coordinator.malibu.tech"),
            ("gateway_host", "gateway.malibu.tech"),
            ("coordinator_endpoint", "coordinator.malibu.tech"),
            ("gateway_url", "gateway.malibu.tech"),
            ("operator_log", "posted to coordinator.malibu.tech/v1 with redacted credentials"),
            ("events", ["ok", "staging.example.invalid/v1"]),
            ("notes", {"message": "gateway.malibu.tech/v1 completed"}),
            ("operator_log", "~/.config/macprovider/token"),
            ("operator_log", "$HOME/.config/macprovider/token"),
            ("operator_log", "/etc/macprovider/token"),
            ("operator_log", "/home/operator/.ssh/id_ed25519"),
            ("operator_log", "/root/.config/macprovider/keys/autotune-static-v4.private.base64"),
            ("operator_log", "coordinator_internal:8443"),
        ):
            payload = valid_evidence()
            payload["diagnostics"] = {key: value}
            self.assert_invalid_contains(payload, "Build 1 narrow MVP evidence fields")

    def test_rejects_route_time_artifact_binding_drift(self) -> None:
        payload = valid_evidence()
        payload["route_snapshot"]["artifact_binding"]["artifact_feed_signer_key_id"] = "wrong-signer"
        payload["settlement_verdict"]["artifact_binding"]["candidate_catalog_body_digest"] = "0" * 64
        self.assert_invalid_contains(payload, "artifact_feed_signer_key_id")
        self.assert_invalid_contains(payload, "candidate_catalog_body_digest")

    def test_rejects_consistently_wrong_artifact_feed_signer(self) -> None:
        payload = valid_evidence()
        wrong = "wrong-trusted-looking-signer"
        payload["artifact_feed"]["artifact_feed_signer_key_id"] = wrong
        payload["artifact_feed"]["route_binding"]["artifact_feed_signer_key_id"] = wrong
        payload["route_snapshot"]["artifact_binding"]["artifact_feed_signer_key_id"] = wrong
        payload["route_snapshot"]["artifact_binding_digest"] = mod._jcs_sha256(payload["route_snapshot"]["artifact_binding"])
        payload["settlement_verdict"]["artifact_binding"]["artifact_feed_signer_key_id"] = wrong
        self.assert_invalid_contains(payload, "artifact_feed_signer_key_id")

    def test_rejects_route_or_artifact_digest_tampering(self) -> None:
        payload = valid_evidence()
        payload["route_snapshot"]["route_snapshot_digest"] = "0" * 64
        self.assert_invalid_contains(payload, "route_snapshot.route_snapshot_digest")

        payload = valid_evidence()
        payload["route_snapshot"]["artifact_binding_digest"] = "0" * 64
        self.assert_invalid_contains(payload, "artifact_binding_digest")

    def test_rejects_non_verified_spec008_hash_status(self) -> None:
        for status in ("settlement_capable", "hash_mismatch", "hash_invalid", "uncatalogued", "catalog_unavailable"):
            payload = valid_evidence()
            payload["route_snapshot"]["route_snapshot_v1"]["spec008_hash_status"] = status
            payload["route_snapshot"]["route_snapshot_digest"] = mod._jcs_sha256(payload["route_snapshot"]["route_snapshot_v1"])
            payload["settlement"]["route_snapshot_digest"] = payload["route_snapshot"]["route_snapshot_digest"]
            payload["settlement_verdict"]["route_snapshot_digest"] = payload["route_snapshot"]["route_snapshot_digest"]
            self.assert_invalid_contains(payload, "spec008_hash_status")

    def test_rejects_loopback_ip_and_single_label_endpoints(self) -> None:
        for value in (
            "localhost:8080/v1",
            "127.0.0.1:8080/v1",
            "[::1]:8080/v1",
            "coordinator:8080/v1",
            "coordinator:8080",
            "gateway:443",
        ):
            payload = valid_evidence()
            payload["diagnostics"] = {"operator_log": value}
            self.assert_invalid_contains(payload, "credential-shaped value")

    def test_rejects_separator_and_camel_secret_keys(self) -> None:
        for key in ("x-api-key", "api-key", "client-key", "auth-token", "access-token", "private-key", "cloud-token", "authorization-header", "openaiApiKey"):
            payload = valid_evidence()
            payload["diagnostics"] = {key: "redacted"}
            self.assert_invalid_contains(payload, "forbidden secret-bearing key")

    def test_rejects_separator_and_camel_activation_keys(self) -> None:
        for key, value in (
            ("production-activation-enabled", "true"),
            ("production-enforcement-changed", "enabled"),
            ("production.rewards.enabled", "yes"),
            ("economicActivationEnabled", 1),
            ("release-published", "published"),
            ("production_ready", True),
            ("productionQualified", "ready"),
            ("production.qualification", "qualified"),
        ):
            payload = valid_evidence()
            payload["operator_summary"] = {key: value}
            self.assert_invalid_contains(payload, "must not claim production economic activation")

    def test_rejects_nested_disqualifying_acceptance_claims(self) -> None:
        cases = (
            {"skipped": True},
            {"skipped": {"reason": "hardware unavailable"}},
            {"timed-out": "yes"},
            {"timed_out": {"duration": "300s"}},
            {"selected_tests": 0},
            {"fixtureOnly": "true"},
            {"fixture_only": ["deterministic fixture"]},
            {"historical.run": "active"},
            {"historical_run": {"source": "old report"}},
            {"operator_claimed_physical": 1},
            {"evidence_kind": "fixture_integration"},
            {"status": "timed-out"},
            {"status": "timed out"},
            {"kind": "fixture-only"},
            {"kind": "historical run"},
            {"kind": "operator claimed physical"},
            {"kind": "operator-claimed-physical"},
            {"status": "zero selected"},
        )
        for claim in cases:
            payload = valid_evidence()
            payload["contradictory_acceptance"] = claim
            self.assert_invalid_contains(payload, "must not claim skipped")

    def test_rejects_production_blocker_qualification_claims(self) -> None:
        for value in ("qualified", "production ready", "activated"):
            payload = valid_evidence()
            payload["production_blockers"]["qualification"] = value
            self.assert_invalid_contains(payload, "production_blockers.qualification")

    def test_rejects_missing_or_mutated_byom_admission_route_binding(self) -> None:
        payload = valid_evidence()
        del payload["route_snapshot"]["route_snapshot_v1"]["model_admission_candidate_id"]
        payload["route_snapshot"]["route_snapshot_digest"] = mod._jcs_sha256(payload["route_snapshot"]["route_snapshot_v1"])
        payload["settlement"]["route_snapshot_digest"] = payload["route_snapshot"]["route_snapshot_digest"]
        payload["settlement_verdict"]["route_snapshot_digest"] = payload["route_snapshot"]["route_snapshot_digest"]
        self.assert_invalid_contains(payload, "model_admission_candidate_id")

        payload = valid_evidence()
        payload["route_snapshot"]["route_snapshot_v1"]["model_admission_coordinator_event_id"] = "a" * 64
        payload["route_snapshot"]["route_snapshot_digest"] = mod._jcs_sha256(payload["route_snapshot"]["route_snapshot_v1"])
        payload["settlement"]["route_snapshot_digest"] = payload["route_snapshot"]["route_snapshot_digest"]
        payload["settlement_verdict"]["route_snapshot_digest"] = payload["route_snapshot"]["route_snapshot_digest"]
        self.assert_invalid_contains(payload, "model_admission_coordinator_event_id")

    def test_rejects_non_coordinator_route_snapshot_policy_version(self) -> None:
        payload = valid_evidence()
        payload["staging_config"]["policy_version"] = "spec022-build1-mvp-staging-v1"
        payload["route_snapshot"]["route_snapshot_v1"]["route_snapshot_policy_version"] = "spec022-build1-mvp-staging-v1"
        payload["route_snapshot"]["route_snapshot_digest"] = mod._jcs_sha256(payload["route_snapshot"]["route_snapshot_v1"])
        payload["settlement"]["route_snapshot_digest"] = payload["route_snapshot"]["route_snapshot_digest"]
        payload["settlement_verdict"]["route_snapshot_digest"] = payload["route_snapshot"]["route_snapshot_digest"]
        self.assert_invalid_contains(payload, "route_snapshot_policy_version")

    def test_rejects_non_finite_or_fractional_credit_values(self) -> None:
        payload = valid_evidence()
        payload["settlement"]["credits"] = float("nan")
        payload["settlement_verdict"]["credits"] = float("nan")
        self.assert_invalid_contains(payload, "must be an integer")

        payload = valid_evidence()
        payload["settlement"]["credits"] = 4.0
        payload["settlement_verdict"]["credits"] = 4.0
        self.assert_invalid_contains(payload, "must be an integer")

    def test_rejects_expired_catalog_or_bad_event_ordering(self) -> None:
        payload = valid_evidence()
        payload["route_snapshot"]["route_snapshot_v1"]["catalog_expires_at_unix_ms"] = payload["route_snapshot"]["route_snapshot_v1"]["route_decision_ts_unix_ms"]
        payload["route_snapshot"]["route_snapshot_digest"] = mod._jcs_sha256(payload["route_snapshot"]["route_snapshot_v1"])
        payload["settlement"]["route_snapshot_digest"] = payload["route_snapshot"]["route_snapshot_digest"]
        payload["settlement_verdict"]["route_snapshot_digest"] = payload["route_snapshot"]["route_snapshot_digest"]
        self.assert_invalid_contains(payload, "must be after route_decision_ts_unix_ms")

        payload = valid_evidence()
        payload["capture"]["started_at"] = "2026-09-14T10:01:00Z"
        self.assert_invalid_contains(payload, "capture.completed_at")

        payload = valid_evidence()
        payload["provider"]["correlation"]["timestamp"] = "2020-01-01T00:00:00Z"
        self.assert_invalid_contains(payload, "provider.correlation.timestamp")

    def test_rejects_free_text_overclaim_and_does_not_echo_secret_keys(self) -> None:
        for text in (
            "Production is qualified and payouts enabled",
            "Physical acceptance was copied from a historical fixture run",
            "Skipped the physical Mac run; operator claimed inference",
        ):
            payload = valid_evidence()
            payload["capture"]["operator_notes"] = text
            self.assert_invalid_contains(payload, "disallowed production")

        payload = valid_evidence()
        secret_key = "Authorization: Bearer FAKE_SECRET_VALUE_123456"
        payload["diagnostics"] = {secret_key: "redacted"}
        result = mod.validate_build1_narrow_mvp_evidence(payload)
        self.assertFalse(result.ok)
        self.assertFalse(any(secret_key in error for error in result.errors), result.errors)

    def test_rejects_non_ascii_route_snapshot_digest_fields(self) -> None:
        payload = valid_evidence()
        payload["route_snapshot"]["route_snapshot_v1"]["account_scope"] = "staging-cafe\u0301"
        payload["route_snapshot"]["route_snapshot_digest"] = mod._jcs_sha256(payload["route_snapshot"]["route_snapshot_v1"])
        payload["settlement"]["route_snapshot_digest"] = payload["route_snapshot"]["route_snapshot_digest"]
        payload["settlement_verdict"]["route_snapshot_digest"] = payload["route_snapshot"]["route_snapshot_digest"]
        self.assert_invalid_contains(payload, "must be ASCII")

    def test_rejects_stopped_or_unloaded_status(self) -> None:
        payload = valid_evidence()
        payload["provider"]["status_before"]["status"] = "stopped"
        payload["provider"]["status_after"]["model_loaded"] = False
        self.assert_invalid_contains(payload, "status_before.status")
        self.assert_invalid_contains(payload, "status_after.model_loaded")

    def test_rejects_stale_bundles_unix_drift_and_huge_numbers(self) -> None:
        payload = valid_evidence()
        for path in (
            ("captured_at",),
            ("capture", "started_at"),
            ("capture", "completed_at"),
            ("staging_config", "captured_at"),
            ("provider", "correlation", "timestamp"),
        ):
            target = payload
            for key in path[:-1]:
                target = target[key]
            target[path[-1]] = "2020-01-01T00:00:00Z"
        payload["provider"]["correlation"]["unix_ts"] = 1577836800
        payload["route_snapshot"]["route_snapshot_v1"]["route_decision_ts_unix_ms"] = 1577836800000
        payload["route_snapshot"]["route_snapshot_v1"]["request_start_ts_unix_ms"] = 1577836801000
        payload["route_snapshot"]["route_snapshot_v1"]["catalog_expires_at_unix_ms"] = 1577836900000
        payload["route_snapshot"]["route_snapshot_digest"] = mod._jcs_sha256(payload["route_snapshot"]["route_snapshot_v1"])
        payload["settlement"]["route_snapshot_digest"] = payload["route_snapshot"]["route_snapshot_digest"]
        payload["settlement_verdict"]["route_snapshot_digest"] = payload["route_snapshot"]["route_snapshot_digest"]
        self.assert_invalid_contains(payload, "must be on or after 2026-09-14")

        payload = valid_evidence()
        payload["provider"]["correlation"]["unix_ts"] = 1
        self.assert_invalid_contains(payload, "must equal provider.correlation.timestamp seconds")

        payload = valid_evidence()
        payload["diagnostics"] = {"huge": 10 ** 400}
        result = mod.validate_build1_narrow_mvp_evidence(payload)
        self.assertFalse(result.ok)
        self.assertTrue(any("redacted extra key" in error for error in result.errors), result.errors)

        payload = valid_evidence()
        payload["route_snapshot"]["route_snapshot_v1"]["catalog_expires_at_unix_ms"] = 10 ** 40
        result = mod.validate_build1_narrow_mvp_evidence(payload)
        self.assertFalse(result.ok)
        self.assertTrue(any("supported timestamp range" in error for error in result.errors), result.errors)

    def test_rejects_more_endpoint_and_free_text_bypasses(self) -> None:
        for text in (
            "Production payouts are on",
            "Production is live",
            "The physical run was skipped",
        ):
            payload = valid_evidence()
            payload["capture"]["operator_notes"] = text
            self.assert_invalid_contains(payload, "disallowed production")

        payload = valid_evidence()
        payload["environment"]["gateway_note"] = "staging-gateway/v1 with redacted credentials"
        self.assert_invalid_contains(payload, "credential-shaped value")

        payload = valid_evidence()
        payload["capture"]["command"] = "staging-gateway/v1 with redacted credentials"
        self.assert_invalid_contains(payload, "credential-shaped value")

        payload = valid_evidence()
        payload["capture"]["operator_notes"] = "Bearer redacted ABCDEFGHIJKLMNOP"
        self.assert_invalid_contains(payload, "credential-shaped value")

    def test_redacts_unknown_extra_key_names_in_errors(self) -> None:
        secret_key = "Authorization: Bearer TEST_SECRET_TOKEN_123456789"
        payload = valid_evidence()
        payload["request"]["usage"][secret_key] = 1
        result = mod.validate_build1_narrow_mvp_evidence(payload)
        self.assertFalse(result.ok)
        self.assertFalse(any(secret_key in error for error in result.errors), result.errors)

        payload = valid_evidence()
        payload["route_snapshot"]["route_snapshot_v1"][secret_key] = "redacted"
        payload["route_snapshot"]["route_snapshot_digest"] = mod._jcs_sha256(payload["route_snapshot"]["route_snapshot_v1"])
        payload["settlement"]["route_snapshot_digest"] = payload["route_snapshot"]["route_snapshot_digest"]
        payload["settlement_verdict"]["route_snapshot_digest"] = payload["route_snapshot"]["route_snapshot_digest"]
        result = mod.validate_build1_narrow_mvp_evidence(payload)
        self.assertFalse(result.ok)
        self.assertFalse(any(secret_key in error for error in result.errors), result.errors)

    def test_does_not_echo_tainted_cross_binding_values_in_errors(self) -> None:
        cases = (
            lambda payload: payload["staging_config"].__setitem__(
                "environment_id", "/root/.config/macprovider/keys/private"
            ),
            lambda payload: payload["request"].__setitem__(
                "request_id", "sk-projTEST_SECRET_VALUE_123456789"
            ),
            lambda payload: payload["provider"].__setitem__(
                "provider_id", "coordinator_internal:8443"
            ),
        )
        forbidden = (
            "/root/.config/macprovider/keys/private",
            "sk-projTEST_SECRET_VALUE_123456789",
            "coordinator_internal:8443",
        )
        for mutate in cases:
            payload = valid_evidence()
            mutate(payload)
            result = mod.validate_build1_narrow_mvp_evidence(payload)
            self.assertFalse(result.ok)
            for raw in forbidden:
                self.assertFalse(any(raw in error for error in result.errors), result.errors)

    def test_rejects_usage_key_secret_exemptions_and_boolean_rate_number(self) -> None:
        for key in ("access_token_prompt_tokens", "payout_prompt_tokens", "private_key_total_tokens"):
            payload = valid_evidence()
            payload["diagnostics"] = {key: "redacted"}
            self.assert_invalid_contains(payload, "forbidden secret-bearing key")

        payload = valid_evidence()
        payload["profile"]["rate"]["usd_per_million_credits"] = True
        payload["settlement"]["rate"]["usd_per_million_credits"] = True
        self.assert_invalid_contains(payload, "usd_per_million_credits")

    def test_rejects_unknown_top_level_claim_surfaces(self) -> None:
        for text in (
            "Payouts have been processed",
            "Reward payments were distributed",
            "Production settlement is running",
            "We shipped the production release",
            "The Mac test did not run",
            "We used last year’s physical evidence",
        ):
            payload = valid_evidence()
            payload["operator_summary"] = {"note": text}
            self.assert_invalid_contains(payload, "Build 1 narrow MVP evidence fields")

    def test_rejects_overclaim_text_in_required_string_fields(self) -> None:
        cases = (
            (("capture", "command"), "Payouts have been processed"),
            (("repository", "branch"), "We shipped the production release"),
            (("hardware", "os_version"), "Production settlement is running"),
            (("runtime", "context_profile"), "The Mac test did not run"),
            (("artifact_feed", "release_id"), "We used last year’s physical evidence"),
        )
        for path, text in cases:
            payload = valid_evidence()
            target = payload
            for key in path[:-1]:
                target = target[key]
            target[path[-1]] = text
            self.assert_invalid_contains(payload, "disallowed production")

    def test_rejects_nested_unknown_claim_surfaces(self) -> None:
        payload = valid_evidence()
        payload["capture"]["operator_summary"] = {"note": "Payouts have been processed"}
        self.assert_invalid_contains(payload, "disallowed production")

    def test_rejects_huge_rate_numbers_without_crashing(self) -> None:
        payload = valid_evidence()
        payload["profile"]["rate"]["usd_per_million_credits"] = 10 ** 400
        self.assert_invalid_contains(payload, "usd_per_million_credits")

    def test_rejects_environment_and_capture_overclaim_fields(self) -> None:
        for key, value in (("physical_acceptance", True), ("production", "ready"), ("acceptance_passed", True)):
            payload = valid_evidence()
            payload["environment"][key] = value
            self.assert_invalid_contains(payload, "expected fields")

        for text in (
            "Payouts succeeded",
            "Rewards were issued",
            "Production settlement is working",
            "The physical run did not happen",
            "We reused an old test run",
            "The operator says this was physical acceptance",
        ):
            payload = valid_evidence()
            payload["capture"]["command"] = text
            self.assert_invalid_contains(payload, "capture.command")

    def test_rejects_nested_production_ready_claims_outside_environment(self) -> None:
        for container in ("staging_config", "hardware", "runtime", "provider", "settlement"):
            payload = valid_evidence()
            payload[container]["production"] = "ready"
            self.assert_invalid_contains(payload, "must not claim production economic activation")

    def test_rejects_nested_unknown_and_required_field_overclaim_text(self) -> None:
        for container, key, text in (
            ("provider", "notes", "Payouts succeeded"),
            ("runtime", "notes", "Rewards were issued"),
            ("settlement", "notes", "Production settlement is working"),
            ("production_blockers", "production_accepted", True),
        ):
            payload = valid_evidence()
            payload[container][key] = text
            self.assert_invalid_contains(payload, "expected fields")

        for container in ("status_before", "status_after"):
            payload = valid_evidence()
            payload["provider"][container]["production_accepted"] = True
            self.assert_invalid_contains(payload, "expected fields")

        payload = valid_evidence()
        payload["artifact_feed"]["route_binding"]["production_accepted"] = True
        self.assert_invalid_contains(payload, "expected fields")

        for path, text in (
            (("staging_config", "environment_id"), "The operator says this was physical acceptance"),
            (("admission", "model_admission_candidate_id"), "The physical run did not happen"),
            (("provider", "binary_version"), "The physical run did not happen"),
            (("hardware", "chip"), "Apple M2 Max Payouts succeeded"),
            (("hardware", "chip"), "Apple M2 Max; The operator says this was physical acceptance"),
            (("hardware", "chip"), "Apple M2 Max; The physical run did not happen"),
            (("hardware", "chip"), "Apple M2 Max; Production payouts went through"),
            (("hardware", "chip"), "Apple M2 Max; Test results were copied from 2024"),
            (("hardware", "os_version"), "macOS 15.6 Rewards were issued"),
            (("hardware", "os_version"), "macOS 15.6 (Payouts went through)"),
            (("hardware", "os_version"), "macOS 15.6 (The run never happened)"),
            (("hardware", "os_version"), "macOS 15.6 (operator said accepted)"),
            (("runtime", "mlx_version"), "Production settlement is working"),
            (("provider", "receipt_audit_cursor_before"), "We reused an old test run"),
            (("artifact_feed", "release_id"), "payouts_succeeded"),
        ):
            payload = valid_evidence()
            target = payload
            for key in path[:-1]:
                target = target[key]
            target[path[-1]] = text
            if path == ("staging_config", "environment_id"):
                payload["admission"]["environment_id"] = text
            if path == ("admission", "model_admission_candidate_id"):
                payload["route_snapshot"]["route_snapshot_v1"]["model_admission_candidate_id"] = text
                rebind_route_digest(payload)
            if path == ("provider", "binary_version"):
                payload["capture"]["binary_version"] = text
                payload["hardware"]["binary_version"] = text
            result = mod.validate_build1_narrow_mvp_evidence(payload)
            self.assertFalse(result.ok, (path, text, result.errors))

        for route_key, text in (
            ("account_scope", "Production payouts went through"),
            ("paid_entrypoint", "The operator says this was physical acceptance"),
            ("provider_session_id", "The physical run did not happen"),
            ("provider_generation_id", "The physical run did not happen"),
        ):
            payload = valid_evidence()
            payload["route_snapshot"]["route_snapshot_v1"][route_key] = text
            rebind_route_digest(payload)
            result = mod.validate_build1_narrow_mvp_evidence(payload)
            self.assertFalse(result.ok, (route_key, text, result.errors))

    def test_rejects_boolean_settlement_integer_fields(self) -> None:
        for container, key in (
            ("settlement", "attempt_n"),
            ("settlement_verdict", "attempt_n"),
            ("settlement_verdict", "cached_billable_input_tokens"),
        ):
            payload = valid_evidence()
            payload[container][key] = False
            self.assert_invalid_contains(payload, key)

    def test_rejects_overclaim_text_in_staging_sources_and_release_id(self) -> None:
        cases = (
            (("staging_config", "settlement_mode_source"), "Production settlement is working"),
            (("staging_config", "rewards_disabled_source"), "Rewards were issued"),
            (("staging_config", "operator_payment_jobs_disabled_source"), "Payouts succeeded"),
            (("staging_config", "operator_payment_execution_disabled_source"), "Payouts succeeded"),
            (("staging_config", "production_enforcement_source"), "Production is live"),
            (("artifact_feed", "release_id"), "Payouts succeeded"),
        )
        for path, text in cases:
            payload = valid_evidence()
            target = payload
            for key in path[:-1]:
                target = target[key]
            target[path[-1]] = text
            result = mod.validate_build1_narrow_mvp_evidence(payload)
            self.assertFalse(result.ok)
            joined = "\n".join(result.errors)
            if path[0] == "staging_config":
                self.assertIn("must match required value", joined)
            else:
                self.assertIn("invalid shape", joined)


if __name__ == "__main__":
    unittest.main()
