from __future__ import annotations

import importlib.util
import json
import tempfile
import unittest
from pathlib import Path

from scripts.check_spec_governance import (
    LOCAL_CONSUMER_ENDPOINT_ARTIFACT_ID,
    LOCAL_CONSUMER_ENDPOINT_EXECUTION_MODE,
    LOCAL_CONSUMER_ENDPOINT_JOURNEY_ID,
    LOCAL_CONSUMER_ENDPOINT_STEP_ID_ORDER,
    ValidationResult,
    _validate_local_consumer_endpoint_journey_result,
)

REPO_ROOT = Path(__file__).resolve().parents[2]
FINGERPRINT = "a" * 64


def load_builder():
    path = REPO_ROOT / "scripts" / "build-local-consumer-endpoint-journey-result.py"
    import sys

    scripts = str(REPO_ROOT / "scripts")
    inserted = scripts not in sys.path
    if inserted:
        sys.path.insert(0, scripts)
    spec = importlib.util.spec_from_file_location("local_consumer_endpoint_builder", path)
    module = importlib.util.module_from_spec(spec)
    assert spec.loader is not None
    try:
        spec.loader.exec_module(module)
        return module
    finally:
        if inserted:
            sys.path.remove(scripts)


def valid_signed(*, requirement_ids=None, extra_requirement=None, **overrides):
    ids = list(requirement_ids or ["SPEC-045-R008"])
    if extra_requirement:
        ids.append(extra_requirement)
    signed = {
        "journey_id": LOCAL_CONSUMER_ENDPOINT_JOURNEY_ID,
        "execution_mode": LOCAL_CONSUMER_ENDPOINT_EXECUTION_MODE,
        "requirement_ids": ids,
        "observations": {
            "bearer_tokens_redacted": True,
            "generated_local_token_used_as_api_key": True,
            "held_reservation_survived_restart": True,
            "local_base_url_configured": True,
            "openai_sdk_used": True,
            "over_budget_denial_observed": True,
            "permitted_chat_completion_observed": True,
            "raw_prompt_output_redacted": True,
            "recovery_release_observed": True,
            "redacted_artifacts_reviewed": True,
            "staging_or_production_gateway": True,
            "fake_gateway_used": False,
            "local_token_logged": False,
            "raw_completion_logged": False,
            "raw_prompt_logged": False,
            "upstream_credential_logged": False,
        },
        "candidate_identity": {
            "buyer_credential_fingerprint": FINGERPRINT,
            "cli_binary_sha256": FINGERPRINT,
            "cli_version": "1.8.99-test",
            "gateway_kind": "staging",
            "ledger_sha256": FINGERPRINT,
            "local_endpoint_base_url_sha256": FINGERPRINT,
            "local_token_fingerprint": FINGERPRINT,
            "log_capture_sha256": FINGERPRINT,
            "model_id": "model-test",
            "rate_card_sha256": FINGERPRINT,
            "sdk_name": "openai-python",
            "sdk_version": "2.0.0",
            "status_capture_sha256": FINGERPRINT,
            "upstream_gateway_origin_sha256": FINGERPRINT,
        },
        "artifacts": [
            {
                "id": LOCAL_CONSUMER_ENDPOINT_ARTIFACT_ID,
                "sha256": FINGERPRINT,
                "source": "journeys/evidence/local-consumer-endpoint-staging.redacted.json",
            }
        ],
        "steps": [
            {"id": step_id, "status": "pass", "artifacts": [LOCAL_CONSUMER_ENDPOINT_ARTIFACT_ID]}
            for step_id in LOCAL_CONSUMER_ENDPOINT_STEP_ID_ORDER
        ],
    }
    signed.update(overrides)
    return signed


class LocalConsumerEndpointJourneyResultTests(unittest.TestCase):
    def test_valid_payload_promotes_spec045_requirement(self) -> None:
        result = ValidationResult()
        signed = valid_signed()
        _validate_local_consumer_endpoint_journey_result(
            signed,
            "SPEC-045-R008",
            [LOCAL_CONSUMER_ENDPOINT_JOURNEY_ID],
            signed["artifacts"],
            signed["steps"],
            "evidence[0]",
            result,
        )
        self.assertEqual([], result.errors)

    def test_allows_only_spec045_requirements(self) -> None:
        for requirement_id in [f"SPEC-045-R{index:03d}" for index in range(1, 9)]:
            result = ValidationResult()
            signed = valid_signed(requirement_ids=[requirement_id])
            _validate_local_consumer_endpoint_journey_result(
                signed,
                requirement_id,
                [LOCAL_CONSUMER_ENDPOINT_JOURNEY_ID],
                signed["artifacts"],
                signed["steps"],
                "evidence[0]",
                result,
            )
            self.assertEqual([], result.errors, requirement_id)

    def test_rejects_non_spec045_requirement(self) -> None:
        result = ValidationResult()
        signed = valid_signed(requirement_ids=["SPEC-006-R001"])
        _validate_local_consumer_endpoint_journey_result(
            signed,
            "SPEC-006-R001",
            [LOCAL_CONSUMER_ENDPOINT_JOURNEY_ID],
            signed["artifacts"],
            signed["steps"],
            "evidence[0]",
            result,
        )
        self.assertTrue(any("cannot promote SPEC-006-R001" in error for error in result.errors))

    def test_rejects_fake_gateway_evidence(self) -> None:
        result = ValidationResult()
        signed = valid_signed()
        signed["observations"]["fake_gateway_used"] = True
        _validate_local_consumer_endpoint_journey_result(
            signed,
            "SPEC-045-R008",
            [LOCAL_CONSUMER_ENDPOINT_JOURNEY_ID],
            signed["artifacts"],
            signed["steps"],
            "evidence[0]",
            result,
        )
        self.assertTrue(any("fake_gateway_used" in error for error in result.errors))

    def test_rejects_missing_openai_sdk_or_recovery_observation(self) -> None:
        for field in ("openai_sdk_used", "generated_local_token_used_as_api_key", "recovery_release_observed"):
            result = ValidationResult()
            signed = valid_signed()
            signed["observations"][field] = False
            _validate_local_consumer_endpoint_journey_result(
                signed,
                "SPEC-045-R008",
                [LOCAL_CONSUMER_ENDPOINT_JOURNEY_ID],
                signed["artifacts"],
                signed["steps"],
                "evidence[0]",
                result,
            )
            self.assertTrue(any(field in error for error in result.errors), field)

    def test_rejects_prompt_or_token_leak_flags(self) -> None:
        for field in ("raw_prompt_logged", "raw_completion_logged", "local_token_logged", "upstream_credential_logged"):
            result = ValidationResult()
            signed = valid_signed()
            signed["observations"][field] = True
            _validate_local_consumer_endpoint_journey_result(
                signed,
                "SPEC-045-R008",
                [LOCAL_CONSUMER_ENDPOINT_JOURNEY_ID],
                signed["artifacts"],
                signed["steps"],
                "evidence[0]",
                result,
            )
            self.assertTrue(any(field in error for error in result.errors), field)

    def test_rejects_invalid_gateway_kind(self) -> None:
        result = ValidationResult()
        signed = valid_signed()
        signed["candidate_identity"]["gateway_kind"] = "fake"
        _validate_local_consumer_endpoint_journey_result(
            signed,
            "SPEC-045-R008",
            [LOCAL_CONSUMER_ENDPOINT_JOURNEY_ID],
            signed["artifacts"],
            signed["steps"],
            "evidence[0]",
            result,
        )
        self.assertTrue(any("gateway_kind" in error for error in result.errors))

    def test_rejects_missing_step_and_step_order_swap(self) -> None:
        result = ValidationResult()
        signed = valid_signed()
        signed["steps"] = signed["steps"][:-1]
        _validate_local_consumer_endpoint_journey_result(
            signed,
            "SPEC-045-R008",
            [LOCAL_CONSUMER_ENDPOINT_JOURNEY_ID],
            signed["artifacts"],
            signed["steps"],
            "evidence[0]",
            result,
        )
        self.assertTrue(any("missing local-consumer endpoint" in error for error in result.errors))

        result = ValidationResult()
        signed = valid_signed()
        signed["steps"][0], signed["steps"][1] = signed["steps"][1], signed["steps"][0]
        _validate_local_consumer_endpoint_journey_result(
            signed,
            "SPEC-045-R008",
            [LOCAL_CONSUMER_ENDPOINT_JOURNEY_ID],
            signed["artifacts"],
            signed["steps"],
            "evidence[0]",
            result,
        )
        self.assertTrue(any("physical steps must be ordered" in error for error in result.errors))

    def test_rejects_signed_free_form_summary_and_assertions(self) -> None:
        result = ValidationResult()
        signed = valid_signed(result={"status": "pass", "summary": "completion: hello"})
        signed["steps"][0]["assertion"] = "prompt: hello"
        _validate_local_consumer_endpoint_journey_result(
            signed,
            "SPEC-045-R008",
            [LOCAL_CONSUMER_ENDPOINT_JOURNEY_ID],
            signed["artifacts"],
            signed["steps"],
            "evidence[0]",
            result,
        )
        self.assertTrue(any("free-form summary" in error for error in result.errors))
        self.assertTrue(any("free-form assertion" in error for error in result.errors))

    def test_builder_rejects_broad_requirement_and_secret_keys(self) -> None:
        builder = load_builder()
        with self.assertRaises(SystemExit):
            builder.parse_requirement_ids("SPEC-006-R001", {"requirement_ids": ["SPEC-006-R001"]})
        with self.assertRaises(SystemExit):
            builder.reject_forbidden_secret_keys({"raw_prompt": "hello"})
        for payload in (
            {"prompt": "hello"},
            {"completion": "hello"},
            {"messages": [{"role": "user", "content": "hello"}]},
        ):
            with self.assertRaises(SystemExit):
                builder.reject_forbidden_secret_keys(payload)
        builder.reject_forbidden_secret_keys(
            {
                "candidate_identity": {
                    "buyer_credential_fingerprint": FINGERPRINT,
                    "local_token_fingerprint": FINGERPRINT,
                }
            }
        )
        with self.assertRaises(SystemExit):
            builder.reject_forbidden_secret_keys({"buyer_credential_fingerprint": "not-a-fingerprint"})
        with self.assertRaises(SystemExit):
            builder.reject_forbidden_secret_keys({"raw_prompt_fingerprint": FINGERPRINT})
        with self.assertRaises(SystemExit):
            builder.require_exact_keys({"status": "pass", "summary": "completion: hello"}, {"status"}, {"status"}, "result")
        with self.assertRaises(SystemExit):
            builder.require_steps(
                [
                    {
                        "id": LOCAL_CONSUMER_ENDPOINT_STEP_ID_ORDER[0],
                        "status": "pass",
                        "assertion": "prompt: hello",
                        "artifacts": [LOCAL_CONSUMER_ENDPOINT_ARTIFACT_ID],
                    }
                ]
            )
        self.assertEqual(
            ["SPEC-045-R001", "SPEC-045-R008"],
            builder.parse_requirement_ids(
                "SPEC-045-R001,SPEC-045-R008",
                {"requirement_ids": ["SPEC-045-R001", "SPEC-045-R008"]},
            ),
        )

    def test_builder_accepts_valid_redacted_evidence_payload(self) -> None:
        builder = load_builder()
        source_sha = "1" * 40
        evidence_sha = "2" * 40
        evidence = {
            "schema_version": "macprovider.local-consumer-endpoint-evidence.v1",
            "journey_id": LOCAL_CONSUMER_ENDPOINT_JOURNEY_ID,
            "requirement_ids": ["SPEC-045-R001", "SPEC-045-R008"],
            "repository": {"name": "Augustas11/macprovider", "commit": source_sha},
            "captured_at": "2026-08-24T00:00:00Z",
            "expires_at": "2999-01-01",
            "operator": {"role": "release-operator", "identity_fingerprint": FINGERPRINT},
            "environment": {
                "class": LOCAL_CONSUMER_ENDPOINT_EXECUTION_MODE,
                "hardware_profile": "ci-staging-runner",
                "candidate": "macprovider-cli-test",
            },
            "result": {"status": "pass"},
            "steps": [
                {
                    "id": step_id,
                    "status": "pass",
                    "artifacts": [LOCAL_CONSUMER_ENDPOINT_ARTIFACT_ID],
                }
                for step_id in LOCAL_CONSUMER_ENDPOINT_STEP_ID_ORDER
            ],
            "redaction": {
                "secrets_redacted": True,
                "operator_identity_redacted": True,
                "local_account_names_redacted": True,
            },
            "observations": valid_signed()["observations"],
            "candidate_identity": valid_signed()["candidate_identity"],
            "run_id": "local-consumer-endpoint-test-run",
        }
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory).resolve()
            source = "journeys/evidence/local-consumer-endpoint-test.redacted.json"
            path = root / source
            path.parent.mkdir(parents=True)
            payload_bytes = (json.dumps(evidence, indent=2) + "\n").encode("utf-8")
            path.write_bytes(payload_bytes)
            original_reachable = builder.require_reachable_commit
            original_ancestor = builder.require_ancestor_commit
            original_git_file = builder.require_git_file_matches
            original_mapped = builder.load_mapped_local_consumer_requirements
            try:
                builder.require_reachable_commit = lambda root, commit, label: None
                builder.require_ancestor_commit = lambda root, ancestor, descendant: None

                def assert_git_file_matches(root, commit, checked_source, expected):
                    self.assertEqual(evidence_sha, commit)
                    self.assertEqual(source, checked_source)
                    self.assertEqual(payload_bytes, expected)

                builder.require_git_file_matches = assert_git_file_matches
                builder.load_mapped_local_consumer_requirements = lambda root: {"SPEC-045-R001", "SPEC-045-R008"}
                result = builder.build_payload(
                    root,
                    source,
                    source_sha=source_sha,
                    evidence_sha=evidence_sha,
                    requirement_ids="SPEC-045-R001,SPEC-045-R008",
                )
            finally:
                builder.require_reachable_commit = original_reachable
                builder.require_ancestor_commit = original_ancestor
                builder.require_git_file_matches = original_git_file
                builder.load_mapped_local_consumer_requirements = original_mapped
        self.assertEqual(LOCAL_CONSUMER_ENDPOINT_JOURNEY_ID, result["journey_id"])
        self.assertEqual(["SPEC-045-R001", "SPEC-045-R008"], result["requirement_ids"])
        self.assertEqual(evidence["candidate_identity"], result["candidate_identity"])


if __name__ == "__main__":
    unittest.main()
