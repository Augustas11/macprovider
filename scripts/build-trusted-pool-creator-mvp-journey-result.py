#!/usr/bin/env python3
"""Build a non-promoting Trusted Pool creator-MVP journey-result payload from redacted evidence."""

from __future__ import annotations

import argparse
import hashlib
import importlib.util
import json
import re
import subprocess
import sys
from copy import deepcopy
from datetime import date, datetime, timezone
from pathlib import Path
from types import ModuleType
from typing import Any

from check_spec_governance import (
    JOURNEY_RESULT_PAYLOAD_SCHEMA,
    TRUSTED_POOL_CREATOR_MVP_ARTIFACT_ID,
    TRUSTED_POOL_CREATOR_MVP_EVIDENCE_REQUIREMENT_IDS,
    TRUSTED_POOL_CREATOR_MVP_EXECUTION_MODE,
    TRUSTED_POOL_CREATOR_MVP_JOURNEY_ID,
    TRUSTED_POOL_CREATOR_MVP_STEP_ID_ORDER,
)


EVIDENCE_SCHEMA = "macprovider.trusted-pool-creator-mvp-evidence.v1"
JOURNEY_ID = "JOURNEY-TRUSTED-POOL-CREATOR-MVP"
REPOSITORY = "Augustas11/macprovider"
ARTIFACT_ID = "redacted-trusted-pool-creator-mvp"
REQUIREMENT_RE = re.compile(r"^SPEC-[0-9]{3}-R[0-9]{3}$")
COMMIT_RE = re.compile(r"^[0-9a-f]{40}$")
DATETIME_Z_RE = re.compile(r"^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z$")
DATE_RE = re.compile(r"^[0-9]{4}-[0-9]{2}-[0-9]{2}$")
FINGERPRINT_RE = re.compile(r"^[0-9a-f]{64}$")
GIT_FILE_MATCH_ERROR = "redacted evidence source bytes must match --evidence-sha"
SIGNED_REDACTION_FIELDS = (
    "secrets_redacted",
    "operator_identity_redacted",
    "local_account_names_redacted",
)


def die(message: str) -> None:
    print(f"build-trusted-pool-creator-mvp-journey-result: {message}", file=sys.stderr)
    raise SystemExit(1)


def load_layer2_builder() -> ModuleType:
    path = Path(__file__).resolve().with_name("build-trusted-pool-layer2-journey-result.py")
    spec = importlib.util.spec_from_file_location("trusted_pool_layer2_builder", path)
    if spec is None or spec.loader is None:
        die("could not load Trusted Pool Layer 2 journey-result builder")
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


layer2 = load_layer2_builder()


def require_string(value: Any, pattern: re.Pattern[str] | None, location: str) -> str:
    if not isinstance(value, str) or not value:
        die(f"{location} must be a non-empty string")
    if pattern is not None and not pattern.fullmatch(value):
        die(f"{location} has invalid format")
    return value


def require_object(value: Any, location: str) -> dict[str, Any]:
    if not isinstance(value, dict):
        die(f"{location} must be an object")
    return value


def require_evidence_source(root: Path, source: str) -> tuple[str, Path]:
    normalized = layer2.repository_relative(root, source, "redacted evidence source")
    name = Path(normalized).name
    if not normalized.startswith("journeys/evidence/trusted-pool-creator-mvp-") or not name.endswith(".redacted.json"):
        die("redacted evidence source must be journeys/evidence/trusted-pool-creator-mvp-*.redacted.json")
    path = root / normalized
    candidate = root
    for component in Path(normalized).parts:
        candidate = candidate / component
        if candidate.is_symlink():
            die(f"redacted evidence source is absent or unsafe: {normalized}")
    if not path.is_file() or path.is_symlink():
        die(f"redacted evidence source is absent or unsafe: {normalized}")
    return normalized, path


def parse_requirement_ids(raw: str | None, evidence: dict[str, Any]) -> list[str]:
    covered = evidence.get("requirement_ids")
    if not isinstance(covered, list) or not all(isinstance(item, str) for item in covered):
        die("evidence.requirement_ids must be an array of strings")
    input_ids = list(covered) if raw is None else [item.strip() for item in raw.split(",") if item.strip()]
    if not input_ids:
        die("requirement_ids must not be empty")
    if len(set(input_ids)) != len(input_ids):
        die("requirement_ids must be unique")
    invalid = [item for item in input_ids if not REQUIREMENT_RE.fullmatch(item)]
    if invalid:
        die(f"invalid requirement id(s): {', '.join(invalid)}")
    overclaimed = [item for item in input_ids if item not in covered]
    if overclaimed:
        die(f"--requirement-ids must be covered by evidence.requirement_ids: {', '.join(overclaimed)}")
    forbidden = [item for item in input_ids if item not in TRUSTED_POOL_CREATOR_MVP_EVIDENCE_REQUIREMENT_IDS]
    if forbidden:
        die(f"trusted-pool creator MVP journey-result cannot promote {', '.join(forbidden)}")
    return input_ids


def load_mapped_creator_requirements(root: Path) -> set[str]:
    conformance = layer2.load_object(root / "specs" / "CONFORMANCE.json", "spec conformance")
    requirements = conformance.get("requirements")
    if not isinstance(requirements, list):
        die("specs/CONFORMANCE.json requirements must be an array")
    mapped: set[str] = set()
    for row in requirements:
        if not isinstance(row, dict):
            continue
        journeys = row.get("journeys")
        if isinstance(journeys, list) and TRUSTED_POOL_CREATOR_MVP_JOURNEY_ID in journeys and row.get("state") == "pending":
            requirement_id = row.get("requirement_id")
            if isinstance(requirement_id, str):
                mapped.add(requirement_id)
    return mapped


def require_steps(value: Any) -> list[dict[str, Any]]:
    if not isinstance(value, list):
        die("steps must be an array")
    by_id: dict[str, dict[str, Any]] = {}
    for index, item in enumerate(value):
        step = require_object(item, f"steps[{index}]")
        step_id = require_string(step.get("id"), None, f"steps[{index}].id")
        if step_id in by_id:
            die(f"duplicate step id: {step_id}")
        if step.get("status") != "pass":
            die(f"{step_id}.status must equal 'pass'")
        assertion = require_string(step.get("assertion"), None, f"{step_id}.assertion")
        layer2.reject_forbidden_overclaim_text(assertion, f"{step_id}.assertion")
        artifacts = step.get("artifacts")
        if artifacts is None:
            artifacts = [ARTIFACT_ID]
        if not isinstance(artifacts, list) or not artifacts or any(item != ARTIFACT_ID for item in artifacts):
            die(f"{step_id}.artifacts must reference {ARTIFACT_ID}")
        by_id[step_id] = {"id": step_id, "status": "pass", "assertion": assertion, "artifacts": [ARTIFACT_ID]}
    missing = [step_id for step_id in TRUSTED_POOL_CREATOR_MVP_STEP_ID_ORDER if step_id not in by_id]
    extra = [step_id for step_id in by_id if step_id not in TRUSTED_POOL_CREATOR_MVP_STEP_ID_ORDER]
    if missing:
        die(f"missing trusted-pool creator MVP step(s): {', '.join(missing)}")
    if extra:
        die(f"unknown trusted-pool creator MVP step(s): {', '.join(extra)}")
    return [by_id[step_id] for step_id in TRUSTED_POOL_CREATOR_MVP_STEP_ID_ORDER]


def require_observations(value: Any) -> dict[str, Any]:
    observations = require_object(value, "observations")
    true_fields = {
        "approved_creator_record_bound",
        "buyer_authorization_enforced",
        "candidate_manifest_accepted",
        "creator_admin_authorized_only",
        "emergency_pause_exercised",
        "fail_closed_no_global_fallback",
        "isolated_environment",
        "no_duplicate_settlement",
        "no_private_key_upload",
        "no_raw_prompt_output_artifact",
        "raw_prompt_output_redacted",
        "restart_reconstruction_verified",
        "root_registration_replay_checked",
        "settlement_labels_bound",
        "successful_pooled_request",
        "creator_suspension_root_compromise_freeze_verified",
        "delegation_revocation_verified",
        "descendant_signer_rejection_verified",
        "pool_existence_oracle_within_threshold",
    }
    false_fields = {
        "coordinator_blind_claimed",
        "global_fallback_observed",
        "payout_ready_mutated",
        "privacy_pool_claimed",
        "production_side_effects",
        "public_announcement_without_reviewed_artifact_observed",
        "unrestricted_creator_admin_observed",
    }
    missing = (true_fields | false_fields) - set(observations)
    if missing:
        die(f"observations missing keys: {sorted(missing)}")
    extra = set(observations) - (true_fields | false_fields)
    if extra:
        die(f"observations has unknown keys: {sorted(extra)}")
    for field in sorted(true_fields):
        if observations.get(field) is not True:
            die(f"observations.{field} must be true")
    for field in sorted(false_fields):
        if observations.get(field) is not False:
            die(f"observations.{field} must be false")
    return deepcopy(observations)


def require_candidate_identity(value: Any) -> dict[str, Any]:
    identity = require_object(value, "candidate_identity")
    fingerprint_fields = {
        "buyer_credential_fingerprint",
        "coordinator_config_sha256",
        "creator_account_fingerprint",
        "artifact_set_sha256",
        "effective_config_digest",
        "feature_flag_digest",
        "gateway_config_sha256",
        "governance_file_digest",
        "manifest_core_digest",
        "operation_ids_fingerprint",
        "provider_identity_fingerprint",
        "readiness_observations_fingerprint",
        "reviewed_distribution_artifact_digest",
        "root_issuer_fingerprint",
        "route_snapshot_digest",
    }
    integer_fields = {
        "clock_skew_allowance_seconds",
        "maximum_ttl_seconds",
    }
    string_fields = {
        "approval_record_id",
        "approval_record_version",
        "coordinator_build_id",
        "creator_agreement_id",
        "creator_agreement_expires_at",
        "creator_agreement_grace_ends_at",
        "creator_agreement_version",
        "environment_id",
        "gate_check_id",
        "gateway_build_id",
        "lifecycle_state",
        "manifest_version",
        "pool_generation",
        "pool_id",
        "pricing_schedule_id",
        "pricing_schedule_version",
        "provider_build_id",
        "verifier_challenge",
        "verifier_command",
        "verifier_result",
    }
    missing = (fingerprint_fields | integer_fields | string_fields) - set(identity)
    if missing:
        die(f"candidate_identity missing keys: {sorted(missing)}")
    for field in sorted(fingerprint_fields):
        require_string(identity.get(field), FINGERPRINT_RE, f"candidate_identity.{field}")
    for field in sorted(integer_fields):
        value = identity.get(field)
        if not isinstance(value, int) or isinstance(value, bool):
            die(f"candidate_identity.{field} must be an integer")
    maximum_ttl = identity.get("maximum_ttl_seconds")
    if isinstance(maximum_ttl, int) and not isinstance(maximum_ttl, bool) and (maximum_ttl <= 0 or maximum_ttl > 86400):
        die("candidate_identity.maximum_ttl_seconds must be between 1 and 86400")
    clock_skew = identity.get("clock_skew_allowance_seconds")
    if isinstance(clock_skew, int) and not isinstance(clock_skew, bool) and (clock_skew < 0 or clock_skew > 300):
        die("candidate_identity.clock_skew_allowance_seconds must be between 0 and 300")
    for field in sorted(string_fields):
        require_string(identity.get(field), None, f"candidate_identity.{field}")
    for field in ("creator_agreement_expires_at", "creator_agreement_grace_ends_at"):
        require_string(identity.get(field), DATETIME_Z_RE, f"candidate_identity.{field}")
    if identity.get("verifier_result") != "pass":
        die("candidate_identity.verifier_result must equal 'pass'")
    return deepcopy(identity)


def reject_creator_mvp_secret_keys(evidence: dict[str, Any]) -> None:
    # Required observation field names may contain fragments such as
    # "authorization"; scan the rest of the artifact and observation values.
    sanitized = deepcopy(evidence)
    observations = sanitized.pop("observations", None)
    layer2.reject_forbidden_secret_keys(sanitized)
    if not isinstance(observations, dict):
        return
    for key, item in observations.items():
        if isinstance(item, str):
            layer2.reject_forbidden_secret_keys({"_": item}, f"$.observations.{key}")
        elif isinstance(item, (dict, list)):
            layer2.reject_forbidden_secret_keys(item, f"$.observations.{key}")


def require_pool_rejection_timing(value: Any) -> dict[str, Any]:
    timing = require_object(value, "pool_rejection_timing")
    required = {
        "floor_ms",
        "method",
        "sample_count_per_class",
        "classes_covered",
        "p95_delta_ms",
        "p99_delta_ms",
        "mann_whitney_p_value",
        "statistical_test",
    }
    missing = required - set(timing)
    if missing:
        die(f"pool_rejection_timing missing keys: {sorted(missing)}")
    floor_ms = timing.get("floor_ms")
    if not isinstance(floor_ms, int) or isinstance(floor_ms, bool) or floor_ms < 50:
        die("pool_rejection_timing.floor_ms must be an integer >= 50")
    sample_count = timing.get("sample_count_per_class")
    if not isinstance(sample_count, int) or isinstance(sample_count, bool) or sample_count < 8:
        die("pool_rejection_timing.sample_count_per_class must be an integer >= 8")
    require_string(timing.get("method"), None, "pool_rejection_timing.method")
    require_string(timing.get("statistical_test"), None, "pool_rejection_timing.statistical_test")
    classes = timing.get("classes_covered")
    if not isinstance(classes, list) or not classes or any(not isinstance(item, str) or not item for item in classes):
        die("pool_rejection_timing.classes_covered must be a non-empty list of strings")
    required_classes = {"unknown", "unauthorized", "disabled"}
    missing_classes = required_classes - set(classes)
    if missing_classes:
        die(f"pool_rejection_timing.classes_covered missing {sorted(missing_classes)}")
    for field_name in ("p95_delta_ms", "p99_delta_ms", "mann_whitney_p_value"):
        value = timing.get(field_name)
        if not isinstance(value, (int, float)) or isinstance(value, bool):
            die(f"pool_rejection_timing.{field_name} must be a number")
    if timing.get("p95_delta_ms") > 15:
        die("pool_rejection_timing.p95_delta_ms must be <= 15")
    if timing.get("p99_delta_ms") > 25:
        die("pool_rejection_timing.p99_delta_ms must be <= 25")
    if timing.get("mann_whitney_p_value") < 0.01:
        die("pool_rejection_timing.mann_whitney_p_value must be >= 0.01")
    return deepcopy(timing)


def require_same_utc_day_expiry(captured_at: str, expires_at: str) -> None:
    captured_dt = datetime.strptime(captured_at, "%Y-%m-%dT%H:%M:%SZ").replace(tzinfo=timezone.utc)
    if date.fromisoformat(expires_at) != captured_dt.date():
        die("expires_at must equal the UTC calendar date of captured_at")


def require_signed_redaction(value: Any) -> dict[str, bool]:
    redaction = require_object(value, "redaction")
    for field, redacted in sorted(redaction.items()):
        if field.endswith("_redacted") and redacted is not True:
            die(f"redaction.{field} must be true")
    signed_redaction: dict[str, bool] = {}
    for field in SIGNED_REDACTION_FIELDS:
        if redaction.get(field) is not True:
            die(f"redaction.{field} must be true")
        signed_redaction[field] = True
    return signed_redaction


def require_reachable_commit(root: Path, commit: str, label: str) -> None:
    completed = subprocess.run(["git", "cat-file", "-e", f"{commit}^{{commit}}"], cwd=root, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, check=False)
    if completed.returncode != 0:
        die(f"{label} is not a reachable commit")


def require_ancestor_commit(root: Path, ancestor: str, descendant: str) -> None:
    completed = subprocess.run(["git", "merge-base", "--is-ancestor", ancestor, descendant], cwd=root, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, check=False)
    if completed.returncode != 0:
        die("--source-sha must be an ancestor of --evidence-sha")


def build_payload(root: Path, source: str, *, source_sha: str, evidence_sha: str, requirement_ids: str | None) -> dict[str, Any]:
    require_string(source_sha, COMMIT_RE, "--source-sha")
    require_string(evidence_sha, COMMIT_RE, "--evidence-sha")
    source, path = require_evidence_source(root, source)
    evidence, evidence_bytes = layer2.load_object_bytes(path, "Trusted Pool creator MVP redacted evidence")
    reject_creator_mvp_secret_keys(evidence)
    if evidence.get("schema_version") != EVIDENCE_SCHEMA:
        die(f"schema_version must equal {EVIDENCE_SCHEMA!r}")
    if evidence.get("journey_id") != JOURNEY_ID:
        die(f"journey_id must equal {JOURNEY_ID!r}")
    if JOURNEY_ID != TRUSTED_POOL_CREATOR_MVP_JOURNEY_ID:
        die("JOURNEY_ID drifted from TRUSTED_POOL_CREATOR_MVP_JOURNEY_ID")
    if ARTIFACT_ID != TRUSTED_POOL_CREATOR_MVP_ARTIFACT_ID:
        die("ARTIFACT_ID drifted from TRUSTED_POOL_CREATOR_MVP_ARTIFACT_ID")
    require_reachable_commit(root, source_sha, "--source-sha")
    require_reachable_commit(root, evidence_sha, "--evidence-sha")
    require_ancestor_commit(root, source_sha, evidence_sha)
    repository = require_object(evidence.get("repository"), "repository")
    if repository.get("name") != REPOSITORY:
        die(f"repository.name must equal {REPOSITORY!r}")
    evidence_source_sha = require_string(repository.get("commit"), COMMIT_RE, "repository.commit")
    if evidence_source_sha != source_sha:
        die("repository.commit must exactly match --source-sha")
    layer2.require_git_file_matches(root, evidence_sha, source, evidence_bytes)

    selected_requirements = parse_requirement_ids(requirement_ids, evidence)
    mapped = load_mapped_creator_requirements(root)
    not_mapped = [item for item in selected_requirements if item not in mapped]
    if not_mapped:
        die(f"requirement_ids must be pending and mapped to {TRUSTED_POOL_CREATOR_MVP_JOURNEY_ID}: {', '.join(not_mapped)}")

    captured_at = require_string(evidence.get("captured_at"), DATETIME_Z_RE, "captured_at")
    expires_at = require_string(evidence.get("expires_at"), DATE_RE, "expires_at")
    if date.fromisoformat(expires_at) < date.today():
        die("expires_at must not be in the past")
    require_same_utc_day_expiry(captured_at, expires_at)
    operator = deepcopy(require_object(evidence.get("operator"), "operator"))
    require_string(operator.get("role"), None, "operator.role")
    require_string(operator.get("identity_fingerprint"), FINGERPRINT_RE, "operator.identity_fingerprint")
    environment = deepcopy(require_object(evidence.get("environment"), "environment"))
    for field in ("class", "hardware_profile", "candidate"):
        require_string(environment.get(field), None, f"environment.{field}")
    if environment.get("class") != TRUSTED_POOL_CREATOR_MVP_EXECUTION_MODE:
        die(f"environment.class must equal {TRUSTED_POOL_CREATOR_MVP_EXECUTION_MODE!r}")
    result = deepcopy(require_object(evidence.get("result"), "result"))
    if result.get("status") != "pass":
        die("result.status must equal 'pass'")
    if "summary" in result:
        layer2.reject_forbidden_overclaim_text(require_string(result.get("summary"), None, "result.summary"), "result.summary")
    steps = require_steps(evidence.get("steps"))
    redaction = require_signed_redaction(evidence.get("redaction"))
    observations = require_observations(evidence.get("observations"))
    candidate_identity = require_candidate_identity(evidence.get("candidate_identity"))
    harness = require_object(evidence.get("harness"), "harness")
    pool_rejection_timing = require_pool_rejection_timing(harness.get("pool_rejection_timing"))
    artifact_sha = hashlib.sha256(evidence_bytes).hexdigest()
    run_id = require_string(evidence.get("run_id"), None, "run_id")

    return {
        "schema_version": JOURNEY_RESULT_PAYLOAD_SCHEMA,
        "journey_id": JOURNEY_ID,
        "requirement_ids": selected_requirements,
        "repository": {"name": REPOSITORY, "commit": source_sha},
        "captured_at": captured_at,
        "expires_at": expires_at,
        "operator": operator,
        "environment": environment,
        "artifacts": [{"id": ARTIFACT_ID, "sha256": artifact_sha, "source": source}],
        "result": result,
        "steps": steps,
        "redaction": redaction,
        "run_id": run_id,
        "execution_mode": TRUSTED_POOL_CREATOR_MVP_EXECUTION_MODE,
        "observations": observations,
        "candidate_identity": candidate_identity,
        "pool_rejection_timing": pool_rejection_timing,
    }


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("redacted_evidence_source", help="journeys/evidence/trusted-pool-creator-mvp-*.redacted.json")
    parser.add_argument("--root", default=".", help="repository root")
    parser.add_argument("--output", required=True, help="unsigned journey-result payload output path")
    parser.add_argument("--source-sha", required=True, help="expected source/build commit captured by the evidence")
    parser.add_argument("--evidence-sha", required=True, help="expected repository commit containing the redacted evidence")
    parser.add_argument("--requirement-ids", default=None, help="comma-separated requirement IDs to cover")
    args = parser.parse_args(argv)

    root = Path(args.root).resolve()
    output = Path(args.output)
    if not output.is_absolute():
        output = root / output
    payload = build_payload(
        root,
        args.redacted_evidence_source,
        source_sha=args.source_sha,
        evidence_sha=args.evidence_sha,
        requirement_ids=args.requirement_ids,
    )
    layer2.write_json_atomically(output, payload)
    print(f"build-trusted-pool-creator-mvp-journey-result: wrote {output}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
