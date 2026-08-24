from __future__ import annotations

import importlib.util
import json
import tempfile
import unittest
import hashlib
from pathlib import Path

from scripts.check_spec_governance import (
    TRUSTED_POOL_LAYER2_ARTIFACT_ID,
    TRUSTED_POOL_LAYER2_JOURNEY_ID,
    TRUSTED_POOL_LAYER2_STEP_ID_ORDER,
    ValidationResult,
    _signed_journey_result_satisfies,
    _validate_trusted_pool_layer2_journey_result,
)

REPO_ROOT = Path(__file__).resolve().parents[2]
FINGERPRINT = "a" * 64


def load_builder():
    path = REPO_ROOT / "scripts" / "build-trusted-pool-layer2-journey-result.py"
    import sys

    scripts = str(REPO_ROOT / "scripts")
    inserted = scripts not in sys.path
    if inserted:
        sys.path.insert(0, scripts)
    spec = importlib.util.spec_from_file_location("trusted_pool_layer2_builder", path)
    module = importlib.util.module_from_spec(spec)
    assert spec.loader is not None
    try:
        spec.loader.exec_module(module)
        return module
    finally:
        if inserted:
            sys.path.remove(scripts)


def valid_signed(*, requirement_ids=None, extra_requirement=None, **overrides):
    ids = list(requirement_ids or ["SPEC-042-R002"])
    if extra_requirement:
        ids.append(extra_requirement)
    signed = {
        "journey_id": TRUSTED_POOL_LAYER2_JOURNEY_ID,
        "execution_mode": "isolated-candidate-trusted-pool-layer2-mvp",
        "requirement_ids": ids,
        "observations": {
            "isolated_environment": True,
            "raw_prompt_output_redacted": True,
            "successful_pooled_request": True,
            "pool_required_fail_closed": True,
            "pool_id_bound_to_route_snapshot": True,
            "pool_selection_authorized": True,
            "tenant_isolation_fail_closed_after_generation_bump": True,
            "production_side_effects": False,
            "global_fallback_observed": False,
            "unauthorized_pool_oracle_observed": False,
            "coordinator_plaintext_privacy_claimed": False,
            "provider_operator_blindness_claimed": False,
            "payout_ready_mutated": False,
        },
        "candidate_identity": {
            "pool_id": "pool_alpha",
            "manifest_version": "7",
            "pool_generation": "11",
            "manifest_core_digest": FINGERPRINT,
            "route_snapshot_digest": FINGERPRINT,
            "gateway_config_sha256": FINGERPRINT,
            "coordinator_config_sha256": FINGERPRINT,
            "provider_identity_fingerprint": FINGERPRINT,
            "buyer_credential_fingerprint": FINGERPRINT,
        },
        "artifacts": [
            {
                "id": TRUSTED_POOL_LAYER2_ARTIFACT_ID,
                "sha256": FINGERPRINT,
                "source": "journeys/evidence/trusted-pool-layer2-alpha.redacted.json",
            }
        ],
        "steps": [{"id": step_id, "status": "pass", "artifacts": [TRUSTED_POOL_LAYER2_ARTIFACT_ID]} for step_id in TRUSTED_POOL_LAYER2_STEP_ID_ORDER],
    }
    signed.update(overrides)
    return signed


class TrustedPoolLayer2JourneyResultTests(unittest.TestCase):
    def test_valid_payload_promotes_pool_authority(self) -> None:
        result = ValidationResult()
        signed = valid_signed()
        _validate_trusted_pool_layer2_journey_result(
            signed,
            "SPEC-042-R002",
            [TRUSTED_POOL_LAYER2_JOURNEY_ID],
            signed["artifacts"],
            signed["steps"],
            "evidence[0]",
            result,
        )
        self.assertEqual([], result.errors)

    def test_allows_only_narrow_layer2_mvp_requirements(self) -> None:
        for requirement_id in ("SPEC-042-R002", "SPEC-042-R005", "SPEC-042-R006", "SPEC-042-R010"):
            result = ValidationResult()
            signed = valid_signed(requirement_ids=[requirement_id])
            _validate_trusted_pool_layer2_journey_result(
                signed,
                requirement_id,
                [TRUSTED_POOL_LAYER2_JOURNEY_ID],
                signed["artifacts"],
                signed["steps"],
                "evidence[0]",
                result,
            )
            self.assertEqual([], result.errors, requirement_id)

    def test_rejects_broad_or_unmapped_spec042_promotion(self) -> None:
        result = ValidationResult()
        signed = valid_signed(requirement_ids=["SPEC-042-R001"])
        _validate_trusted_pool_layer2_journey_result(
            signed,
            "SPEC-042-R001",
            [TRUSTED_POOL_LAYER2_JOURNEY_ID],
            signed["artifacts"],
            signed["steps"],
            "evidence[0]",
            result,
        )
        self.assertTrue(any("cannot promote SPEC-042-R001" in error for error in result.errors))

    def test_rejects_privacy_overclaim(self) -> None:
        result = ValidationResult()
        signed = valid_signed()
        signed["observations"]["coordinator_plaintext_privacy_claimed"] = True
        _validate_trusted_pool_layer2_journey_result(
            signed,
            "SPEC-042-R002",
            [TRUSTED_POOL_LAYER2_JOURNEY_ID],
            signed["artifacts"],
            signed["steps"],
            "evidence[0]",
            result,
        )
        self.assertTrue(any("coordinator_plaintext_privacy_claimed" in error for error in result.errors))

    def test_rejects_global_fallback(self) -> None:
        result = ValidationResult()
        signed = valid_signed()
        signed["observations"]["global_fallback_observed"] = True
        _validate_trusted_pool_layer2_journey_result(
            signed,
            "SPEC-042-R005",
            [TRUSTED_POOL_LAYER2_JOURNEY_ID],
            signed["artifacts"],
            signed["steps"],
            "evidence[0]",
            result,
        )
        self.assertTrue(any("global_fallback_observed" in error for error in result.errors))

    def test_rejects_free_text_privacy_overclaim(self) -> None:
        result = ValidationResult()
        signed = valid_signed(result={"status": "pass", "summary": "proves Privacy Pool unlinkability"})
        signed["steps"][0]["assertion"] = "no coordinator blindness claim belongs here"
        _validate_trusted_pool_layer2_journey_result(
            signed,
            "SPEC-042-R002",
            [TRUSTED_POOL_LAYER2_JOURNEY_ID],
            signed["artifacts"],
            signed["steps"],
            "evidence[0]",
            result,
        )
        self.assertTrue(any("signed.result.summary" in error for error in result.errors))
        self.assertTrue(any("signed.steps[0].assertion" in error for error in result.errors))

    def test_rejects_extra_secret_shaped_observation_keys(self) -> None:
        for field_name in ("api_key", "apiKey", "authorization"):
            result = ValidationResult()
            signed = valid_signed()
            signed["observations"][field_name] = "redacted"
            _validate_trusted_pool_layer2_journey_result(
                signed,
                "SPEC-042-R002",
                [TRUSTED_POOL_LAYER2_JOURNEY_ID],
                signed["artifacts"],
                signed["steps"],
                "evidence[0]",
                result,
            )
            self.assertTrue(any("signed.observations" in error and field_name in error for error in result.errors), field_name)

    def test_rejects_missing_candidate_identity(self) -> None:
        result = ValidationResult()
        signed = valid_signed()
        signed.pop("candidate_identity")
        _validate_trusted_pool_layer2_journey_result(
            signed,
            "SPEC-042-R006",
            [TRUSTED_POOL_LAYER2_JOURNEY_ID],
            signed["artifacts"],
            signed["steps"],
            "evidence[0]",
            result,
        )
        self.assertTrue(any("candidate_identity" in error for error in result.errors))

    def test_rejects_missing_step(self) -> None:
        result = ValidationResult()
        signed = valid_signed()
        signed["steps"] = signed["steps"][:-1]
        _validate_trusted_pool_layer2_journey_result(
            signed,
            "SPEC-042-R010",
            [TRUSTED_POOL_LAYER2_JOURNEY_ID],
            signed["artifacts"],
            signed["steps"],
            "evidence[0]",
            result,
        )
        self.assertTrue(any("missing trusted-pool Layer 2 physical steps" in error for error in result.errors))

    def test_rejects_step_order_swap(self) -> None:
        result = ValidationResult()
        signed = valid_signed()
        signed["steps"][0], signed["steps"][1] = signed["steps"][1], signed["steps"][0]
        _validate_trusted_pool_layer2_journey_result(
            signed,
            "SPEC-042-R010",
            [TRUSTED_POOL_LAYER2_JOURNEY_ID],
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
            source = evidence_dir / "trusted-pool-layer2-alpha.signed.json"
            source.write_text(json.dumps(envelope, indent=2) + "\n", encoding="utf-8")
            digest = hashlib.sha256(source.read_bytes()).hexdigest()
            result = ValidationResult()
            requirement = {
                "requirement_id": "SPEC-042-R002",
                "journeys": [TRUSTED_POOL_LAYER2_JOURNEY_ID],
                "evidence": [
                    {
                        "artifact": f"sha256:{digest}",
                        "source": "journeys/evidence/trusted-pool-layer2-alpha.signed.json",
                    }
                ],
            }

            self.assertFalse(
                _signed_journey_result_satisfies(
                    root,
                    requirement,
                    "SPEC-042-R002",
                    result,
                    trusted_public_key_sha256="",
                    openssl_bin="openssl",
                )
            )
            self.assertTrue(any("evidence-only and cannot satisfy conformant requirements" in error for error in result.errors))

    def test_rejects_wrong_artifact_id_and_source(self) -> None:
        result = ValidationResult()
        signed = valid_signed()
        signed["artifacts"] = [{"id": "a", "sha256": FINGERPRINT, "source": "journeys/evidence/other.redacted.json"}]
        _validate_trusted_pool_layer2_journey_result(
            signed,
            "SPEC-042-R002",
            [TRUSTED_POOL_LAYER2_JOURNEY_ID],
            signed["artifacts"],
            signed["steps"],
            "evidence[0]",
            result,
        )
        self.assertTrue(any("signed.artifacts[0].id" in error for error in result.errors))
        self.assertTrue(any("signed.artifacts[0].source" in error for error in result.errors))

    def test_rejects_wrong_step_artifact_reference(self) -> None:
        result = ValidationResult()
        signed = valid_signed()
        signed["steps"][0]["artifacts"] = ["a"]
        _validate_trusted_pool_layer2_journey_result(
            signed,
            "SPEC-042-R002",
            [TRUSTED_POOL_LAYER2_JOURNEY_ID],
            signed["artifacts"],
            signed["steps"],
            "evidence[0]",
            result,
        )
        self.assertTrue(any("signed.steps[0].artifacts" in error for error in result.errors))

    def test_builder_rejects_overclaims_and_forbidden_requirements(self) -> None:
        builder = load_builder()
        with self.assertRaises(SystemExit):
            builder.parse_requirement_ids("SPEC-042-R001", {"requirement_ids": ["SPEC-042-R001"]})
        self.assertEqual(
            builder.parse_requirement_ids(
                "SPEC-042-R002,SPEC-042-R005,SPEC-042-R006,SPEC-042-R010",
                {"requirement_ids": ["SPEC-042-R002", "SPEC-042-R005", "SPEC-042-R006", "SPEC-042-R010"]},
            ),
            ["SPEC-042-R002", "SPEC-042-R005", "SPEC-042-R006", "SPEC-042-R010"],
        )
        with self.assertRaises(SystemExit):
            builder.require_observations({"successful_pooled_request": True})
        observations = valid_signed()["observations"]
        self.assertEqual(observations, builder.require_observations(observations))
        observations = dict(observations)
        observations["provider_operator_blindness_claimed"] = True
        with self.assertRaises(SystemExit):
            builder.require_observations(observations)
        with self.assertRaises(SystemExit):
            builder.reject_forbidden_secret_keys({"raw_prompt": "redacted"})
        for field_name in (
            "password",
            "api_key",
            "access_token",
            "client_secret",
            "apiKey",
            "accessToken",
            "clientSecret",
            "privateKey",
            "refreshToken",
            "sessionToken",
            "bearerToken",
            "authorization",
        ):
            with self.assertRaises(SystemExit, msg=field_name):
                builder.reject_forbidden_secret_keys({field_name: "redacted"})
        for text in ("Privacy Pool unlinkability proven", "coordinator blindness proven", "provider operator blindness proven"):
            with self.assertRaises(SystemExit, msg=text):
                builder.reject_forbidden_overclaim_text(text, "text")


if __name__ == "__main__":
    unittest.main()
