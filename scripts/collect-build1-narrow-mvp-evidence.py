#!/usr/bin/env python3
"""Collect a redacted Build 1 narrow MVP physical-staging evidence bundle.

The collector intentionally does not run production services, mint payout
material, or claim acceptance from fixtures. Operators provide a closed,
redacted capture manifest from an actual staging run; this tool digests the
source captures, assembles the validator-owned schema, and runs the validator
before writing the final bundle.
"""

from __future__ import annotations

import argparse
import copy
import datetime as _dt
import hashlib
import importlib.util
import json
import os
import stat
import subprocess
import sys
import tempfile
from pathlib import Path
from typing import Any


SCRIPT_DIR = Path(__file__).resolve().parent
VALIDATOR_PATH = SCRIPT_DIR / "validate-build1-narrow-mvp-evidence.py"
_spec = importlib.util.spec_from_file_location("build1_narrow_mvp_evidence_validator", VALIDATOR_PATH)
if not _spec or not _spec.loader:
    raise RuntimeError(f"cannot load validator from {VALIDATOR_PATH}")
validator = importlib.util.module_from_spec(_spec)
sys.modules[_spec.name] = validator
_spec.loader.exec_module(validator)


CAPTURE_MANIFEST_SCHEMA = "macprovider.build1-narrow-mvp-evidence-capture.v1"
SOURCE_CAPTURE_SCHEMA = "macprovider.build1-narrow-mvp-source-capture.v1"
BLOCKER_SCHEMA = "macprovider.build1-narrow-mvp-evidence-blockers.v1"
CAPTURE_COMMAND = "scripts/collect-build1-narrow-mvp-evidence --redacted"
MAX_SOURCE_CAPTURE_BYTES = 16 * 1024 * 1024

SOURCE_CAPTURE_FILE_KEYS = (
    "physical_run_log",
    "request_transcript",
    "status_before",
    "status_after",
    "provider_receipt_audit",
    "coordinator_route_snapshot",
    "coordinator_settlement_verdict",
    "redaction_report",
)

SOURCE_CAPTURE_DIGEST_KEYS = {
    "physical_run_log": "physical_run_log_sha256",
    "request_transcript": "request_transcript_sha256",
    "status_before": "status_before_sha256",
    "status_after": "status_after_sha256",
    "provider_receipt_audit": "provider_receipt_audit_sha256",
    "coordinator_route_snapshot": "coordinator_route_snapshot_sha256",
    "coordinator_settlement_verdict": "coordinator_settlement_verdict_sha256",
    "redaction_report": "redaction_report_sha256",
}

SOURCE_CAPTURE_TOOLS = {
    "physical_run_log": "macprovider-cli-physical-run-summary",
    "request_transcript": "staging-gateway-request-transcript",
    "status_before": "macprovider-cli-local-status",
    "status_after": "macprovider-cli-local-status",
    "provider_receipt_audit": "macprovider-cli-receipt-audit",
    "coordinator_route_snapshot": "staging-coordinator-route-snapshot",
    "coordinator_settlement_verdict": "staging-coordinator-settlement-verdict",
    "redaction_report": "operator-redaction-review",
}

SOURCE_CAPTURE_ENVELOPE_KEYS = {
    "schema_version",
    "capture_kind",
    "source_tool",
    "captured_at",
    "event_id",
    "payload_jcs_sha256",
    "payload",
}

MANIFEST_KEYS = {
    "schema_version",
    "capture",
    "source_captures",
    "staging_config",
    "hardware",
    "runtime",
    "artifact_feed",
    "preparation",
    "provider",
    "admission",
    "request",
    "route_snapshot_v1",
    "settlement",
    "settlement_verdict",
}

CAPTURE_KEYS = {"started_at", "completed_at", "binary_version", "binary_sha256"}


class CaptureError(Exception):
    """Raised when the redacted evidence capture cannot be trusted."""


def die(message: str) -> None:
    print(f"collect-build1-narrow-mvp-evidence: {message}", file=sys.stderr)
    raise SystemExit(1)


def utc_now_z() -> str:
    return _dt.datetime.now(_dt.UTC).strftime("%Y-%m-%dT%H:%M:%SZ")


def load_json_object(path: Path, label: str) -> dict[str, Any]:
    def reject_constant(value: str) -> None:
        raise ValueError(f"non-standard JSON number {value!r} is not allowed")

    try:
        with path.open("r", encoding="utf-8") as fh:
            loaded = json.load(fh, parse_constant=reject_constant)
    except Exception as exc:  # noqa: BLE001 - CLI should report parse/load failures.
        raise CaptureError(f"{label} is not valid JSON: {exc}") from exc
    if not isinstance(loaded, dict):
        raise CaptureError(f"{label} must be a JSON object")
    return loaded


def require_exact_keys(obj: dict[str, Any], expected: set[str], label: str) -> None:
    actual = set(obj)
    if actual != expected:
        missing = validator._safe_sorted_keys(expected - actual)
        extra = validator._redacted_extra_summary(actual - expected)
        raise CaptureError(f"{label} must contain exactly expected fields; missing={missing} extra={extra}")


def require_object(value: Any, label: str) -> dict[str, Any]:
    if not isinstance(value, dict):
        raise CaptureError(f"{label} must be an object")
    return value


def require_child_object(parent: dict[str, Any], key: str, label: str) -> dict[str, Any]:
    if key not in parent:
        raise CaptureError(f"{label}.{key} is required")
    return require_object(parent[key], f"{label}.{key}")


def sha256_bytes(data: bytes) -> str:
    return hashlib.sha256(data).hexdigest()


def jcs_sha256(value: Any) -> str:
    return validator._jcs_sha256(value)


def write_json_atomically(path: Path, payload: dict[str, Any]) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    encoded = json.dumps(payload, indent=2, sort_keys=True) + "\n"
    fd, tmp_name = tempfile.mkstemp(prefix=f".{path.name}.", suffix=".tmp", dir=str(path.parent))
    try:
        with os.fdopen(fd, "w", encoding="utf-8") as fh:
            fh.write(encoded)
        os.replace(tmp_name, path)
    finally:
        try:
            os.unlink(tmp_name)
        except FileNotFoundError:
            pass


def git_value(root: Path, *args: str) -> str:
    try:
        completed = subprocess.run(
            ["git", *args],
            cwd=str(root),
            capture_output=True,
            text=True,
            check=False,
        )
    except OSError as exc:
        raise CaptureError(f"git {' '.join(args)} failed: {exc}") from exc
    if completed.returncode != 0:
        raise CaptureError(f"git {' '.join(args)} failed")
    return completed.stdout.strip()


def repository_context(root: Path) -> dict[str, str]:
    return {
        "name": "Augustas11/macprovider",
        "commit": git_value(root, "rev-parse", "HEAD"),
        "branch": git_value(root, "branch", "--show-current"),
    }


def resolve_capture_path(manifest_dir: Path, raw: Any, label: str) -> Path:
    if not isinstance(raw, str) or not raw:
        raise CaptureError(f"{label} must be a non-empty relative path")
    candidate = Path(raw)
    if candidate.is_absolute() or ".." in candidate.parts:
        raise CaptureError(f"{label} must stay relative to the capture manifest")
    unresolved = manifest_dir / candidate
    try:
        stat_result = unresolved.lstat()
    except OSError as exc:
        raise CaptureError(f"{label} is absent or unsafe") from exc
    if unresolved.is_symlink():
        raise CaptureError(f"{label} must not be a symlink")
    resolved = unresolved.resolve()
    try:
        resolved.relative_to(manifest_dir.resolve())
    except ValueError as exc:
        raise CaptureError(f"{label} must stay under the capture manifest directory") from exc
    if not resolved.is_file():
        raise CaptureError(f"{label} is absent or unsafe")
    if not (stat_result.st_mode & 0o170000) == 0o100000:
        raise CaptureError(f"{label} must be a regular file")
    return resolved


def scan_redacted_source(data: bytes, label: str) -> dict[str, Any]:
    if len(data) > MAX_SOURCE_CAPTURE_BYTES:
        raise CaptureError(f"{label} exceeds {MAX_SOURCE_CAPTURE_BYTES} bytes")
    try:
        text = data.decode("utf-8")
    except UnicodeDecodeError as exc:
        raise CaptureError(f"{label} must be UTF-8 text") from exc
    result = validator.ValidationResult()
    try:
        parsed = json.loads(text)
    except json.JSONDecodeError as exc:
        validator._check_string_forbidden(text, f"source_captures.{label}", label, result)
        raise CaptureError(f"{label} must be a redacted JSON object") from exc
    if not isinstance(parsed, dict):
        raise CaptureError(f"{label} must be a redacted JSON object")
    validator._walk_forbidden(parsed, f"source_captures.{label}", result)
    if result.errors:
        first = "; ".join(result.errors[:5])
        raise CaptureError(f"{label} failed redaction scan: {first}")
    return parsed


def validate_source_capture_envelope(parsed: dict[str, Any], key: str) -> tuple[dict[str, Any], dict[str, Any]]:
    require_exact_keys(parsed, SOURCE_CAPTURE_ENVELOPE_KEYS, f"source_captures.{key}")
    if parsed.get("schema_version") != SOURCE_CAPTURE_SCHEMA:
        raise CaptureError(f"source_captures.{key}.schema_version must equal {SOURCE_CAPTURE_SCHEMA!r}")
    if parsed.get("capture_kind") != key:
        raise CaptureError(f"source_captures.{key}.capture_kind must equal {key!r}")
    if parsed.get("source_tool") != SOURCE_CAPTURE_TOOLS[key]:
        raise CaptureError(f"source_captures.{key}.source_tool does not match the required source")
    captured_at = require_iso_z(parsed.get("captured_at"), f"source_captures.{key}.captured_at")
    event_id = parsed.get("event_id")
    if not isinstance(event_id, str) or not validator.REQUEST_ID_RE.fullmatch(event_id):
        raise CaptureError(f"source_captures.{key}.event_id has invalid shape")
    payload = require_object(parsed.get("payload"), f"source_captures.{key}.payload")
    payload_digest = parsed.get("payload_jcs_sha256")
    if not isinstance(payload_digest, str) or not validator.HEX64_RE.fullmatch(payload_digest):
        raise CaptureError(f"source_captures.{key}.payload_jcs_sha256 has invalid shape")
    if payload_digest != jcs_sha256(payload):
        raise CaptureError(f"source_captures.{key}.payload_jcs_sha256 does not match payload")
    metadata = {
        "captured_at": captured_at,
        "event_id": event_id,
        "source_tool": parsed["source_tool"],
    }
    return payload, metadata


def source_capture_material(manifest_path: Path, manifest: dict[str, Any]) -> tuple[dict[str, Any], dict[str, Any], dict[str, Any]]:
    source_captures = require_object(manifest.get("source_captures"), "source_captures")
    require_exact_keys(source_captures, set(SOURCE_CAPTURE_FILE_KEYS), "source_captures")
    manifest_dir = manifest_path.parent.resolve()
    digests: dict[str, Any] = {
        "review_required": True,
        "manifest_sha256": sha256_bytes(manifest_path.read_bytes()),
    }
    payloads: dict[str, Any] = {}
    metadata: dict[str, Any] = {}
    seen_sources: set[tuple[int, int]] = set()
    seen_realpaths: set[Path] = set()
    for key in SOURCE_CAPTURE_FILE_KEYS:
        path = resolve_capture_path(manifest_dir, source_captures[key], f"source_captures.{key}")
        data, source_identity = read_regular_file_no_follow(path, f"source_captures.{key}")
        if source_identity in seen_sources or path.resolve() in seen_realpaths:
            raise CaptureError(f"source_captures.{key} must be a unique source capture file")
        seen_sources.add(source_identity)
        seen_realpaths.add(path.resolve())
        parsed = scan_redacted_source(data, key)
        digests[SOURCE_CAPTURE_DIGEST_KEYS[key]] = sha256_bytes(data)
        payload, capture_metadata = validate_source_capture_envelope(parsed, key)
        payloads[key] = payload
        metadata[key] = capture_metadata
    return digests, payloads, metadata


def read_regular_file_no_follow(path: Path, label: str) -> tuple[bytes, tuple[int, int]]:
    flags = os.O_RDONLY
    if hasattr(os, "O_NOFOLLOW"):
        flags |= os.O_NOFOLLOW
    try:
        fd = os.open(path, flags)
    except OSError as exc:
        raise CaptureError(f"{label} is absent or unsafe") from exc
    try:
        stat_result = os.fstat(fd)
        if not stat.S_ISREG(stat_result.st_mode):
            raise CaptureError(f"{label} must be a regular file")
        chunks: list[bytes] = []
        total = 0
        while True:
            chunk = os.read(fd, 1024 * 1024)
            if not chunk:
                break
            total += len(chunk)
            if total > MAX_SOURCE_CAPTURE_BYTES:
                raise CaptureError(f"{label} exceeds {MAX_SOURCE_CAPTURE_BYTES} bytes")
            chunks.append(chunk)
        return b"".join(chunks), (stat_result.st_dev, stat_result.st_ino)
    finally:
        os.close(fd)


def require_source_match(payloads: dict[str, Any], key: str, expected: dict[str, Any], label: str) -> None:
    actual = payloads.get(key)
    if actual != expected:
        raise CaptureError(f"source_captures.{key} does not match {label}")


def require_redaction_report(payloads: dict[str, Any]) -> None:
    report = payloads.get("redaction_report")
    if not isinstance(report, dict) or report.get("redaction_passed") is not True:
        raise CaptureError("source_captures.redaction_report must confirm redaction_passed=true")


def require_source_event_id(metadata: dict[str, Any], key: str, expected: str) -> None:
    if metadata.get(key, {}).get("event_id") != expected:
        raise CaptureError(f"source_captures.{key}.event_id does not match the bound evidence event")


def require_iso_z(value: Any, label: str) -> str:
    if not isinstance(value, str) or not value:
        raise CaptureError(f"{label} must be a non-empty UTC ISO-8601 seconds string")
    require_optional_iso_z(value, label)
    return value


def require_optional_iso_z(value: str | None, label: str) -> str | None:
    if value is None:
        return None
    result = validator.ValidationResult()
    validator._parse_iso_z(value, label, result)
    if result.errors:
        raise CaptureError(f"{label} must be UTC ISO-8601 seconds, e.g. 2026-09-14T10:00:00Z")
    return value


def rate_profile() -> dict[str, Any]:
    return {
        "rate_card_key": validator.RATE_CARD_KEY,
        "prompt_rate_per_mtok": validator.PROMPT_RATE,
        "prompt_cache_hit_rate_per_mtok": validator.CACHED_PROMPT_RATE,
        "completion_rate_per_mtok": validator.COMPLETION_RATE,
        "provider_share_bps": validator.PROVIDER_SHARE_BPS,
        "global_multiplier_ppm": validator.GLOBAL_MULTIPLIER_PPM,
        "usd_per_million_credits": validator.USD_PER_MILLION_CREDITS,
    }


def artifact_binding(feed: dict[str, Any]) -> dict[str, Any]:
    return {
        "artifact_feed_sha256": feed.get("feed_sha256"),
        "artifact_id": validator.ARTIFACT_ID,
        "artifact_hash": validator.ARTIFACT_HASH,
        "artifact_hash_algorithm": validator.ARTIFACT_HASH_ALGORITHM,
        "artifact_feed_signer_key_id": feed.get("artifact_feed_signer_key_id"),
        "candidate_catalog_body_digest": feed.get("candidate_catalog_sha256"),
    }


def with_verified_binding(section: dict[str, Any], binding: dict[str, Any], label: str) -> dict[str, Any]:
    updated = copy.deepcopy(section)
    existing = updated.get("artifact_binding")
    if existing is not None and existing != binding:
        raise CaptureError(f"{label}.artifact_binding does not match artifact-feed authority")
    updated["artifact_binding"] = copy.deepcopy(binding)
    return updated


def with_verified_route_digest(section: dict[str, Any], digest: str, label: str) -> dict[str, Any]:
    updated = copy.deepcopy(section)
    existing = updated.get("route_snapshot_digest")
    if existing is not None and existing != digest:
        raise CaptureError(f"{label}.route_snapshot_digest does not match route_snapshot_v1")
    updated["route_snapshot_digest"] = digest
    return updated


def assemble_evidence(root: Path, manifest_path: Path, *, captured_at: str | None) -> dict[str, Any]:
    manifest = load_json_object(manifest_path, "capture manifest")
    require_exact_keys(manifest, MANIFEST_KEYS, "capture manifest")
    if manifest.get("schema_version") != CAPTURE_MANIFEST_SCHEMA:
        raise CaptureError(f"schema_version must equal {CAPTURE_MANIFEST_SCHEMA!r}")

    capture = require_object(manifest.get("capture"), "capture")
    require_exact_keys(capture, CAPTURE_KEYS, "capture")

    capture_digests, source_payloads, source_metadata = source_capture_material(manifest_path, manifest)

    feed = copy.deepcopy(require_object(manifest.get("artifact_feed"), "artifact_feed"))
    binding = artifact_binding(feed)
    if feed.get("route_binding") not in (None, binding):
        raise CaptureError("artifact_feed.route_binding does not match artifact-feed authority")
    feed["route_binding"] = copy.deepcopy(binding)

    route_snapshot_v1 = copy.deepcopy(require_object(manifest.get("route_snapshot_v1"), "route_snapshot_v1"))
    route_snapshot_digest = jcs_sha256(route_snapshot_v1)
    binding_digest = jcs_sha256(binding)

    hardware = copy.deepcopy(require_object(manifest.get("hardware"), "hardware"))
    runtime = copy.deepcopy(require_object(manifest.get("runtime"), "runtime"))
    preparation = copy.deepcopy(require_object(manifest.get("preparation"), "preparation"))
    provider = copy.deepcopy(require_object(manifest.get("provider"), "provider"))
    admission = copy.deepcopy(require_object(manifest.get("admission"), "admission"))
    request = copy.deepcopy(require_object(manifest.get("request"), "request"))
    settlement = with_verified_route_digest(
        require_object(manifest.get("settlement"), "settlement"),
        route_snapshot_digest,
        "settlement",
    )
    settlement_verdict = with_verified_route_digest(
        require_object(manifest.get("settlement_verdict"), "settlement_verdict"),
        route_snapshot_digest,
        "settlement_verdict",
    )
    settlement_verdict = with_verified_binding(settlement_verdict, binding, "settlement_verdict")

    physical_run_log = {
        "hardware": hardware,
        "runtime": runtime,
        "artifact_feed": feed,
        "preparation": preparation,
        "provider": provider,
        "admission": admission,
    }
    require_source_match(source_payloads, "physical_run_log", physical_run_log, "hardware/runtime/provider run claims")
    require_source_match(source_payloads, "request_transcript", request, "request")
    require_source_match(
        source_payloads,
        "status_before",
        require_child_object(provider, "status_before", "provider"),
        "provider.status_before",
    )
    require_source_match(
        source_payloads,
        "status_after",
        require_child_object(provider, "status_after", "provider"),
        "provider.status_after",
    )
    require_source_match(
        source_payloads,
        "provider_receipt_audit",
        require_child_object(provider, "correlation", "provider"),
        "provider.correlation",
    )
    require_source_match(source_payloads, "coordinator_route_snapshot", route_snapshot_v1, "route_snapshot_v1")
    require_source_match(source_payloads, "coordinator_settlement_verdict", settlement_verdict, "settlement_verdict")
    require_redaction_report(source_payloads)
    provider_id = provider.get("provider_id")
    request_id = request.get("request_id")
    if isinstance(provider_id, str):
        for key in ("physical_run_log", "status_before", "status_after"):
            require_source_event_id(source_metadata, key, provider_id)
    if isinstance(request_id, str):
        for key in (
            "request_transcript",
            "provider_receipt_audit",
            "coordinator_route_snapshot",
            "coordinator_settlement_verdict",
            "redaction_report",
        ):
            require_source_event_id(source_metadata, key, request_id)

    evidence = {
        "schema_version": validator.SCHEMA_VERSION,
        "build_id": validator.BUILD_ID,
        "validation_scope": "schema_valid_structural_only",
        "evidence_class": "physical_staging",
        "captured_at": captured_at or capture["completed_at"],
        "repository": repository_context(root),
        "scope": {
            "production_activation_enabled": False,
            "production_enforcement_changed": False,
            "production_rewards_enabled": False,
            "payout_jobs_enabled": False,
            "payout_execution_enabled": False,
            "release_published": False,
        },
        "capture": {
            "command": CAPTURE_COMMAND,
            "started_at": capture["started_at"],
            "completed_at": capture["completed_at"],
            "binary_version": capture["binary_version"],
            "binary_sha256": capture["binary_sha256"],
            "redaction_passed": True,
            "skipped": False,
            "operator_notes": "redacted physical staging run",
            "source_captures": capture_digests,
        },
        "profile": {
            "catalog_key": validator.CATALOG_KEY,
            "model_id": validator.MODEL_ID,
            "runtime_source": validator.RUNTIME_SOURCE,
            "artifact_id": validator.ARTIFACT_ID,
            "model_revision": validator.MODEL_REVISION,
            "artifact_hash_algorithm": validator.ARTIFACT_HASH_ALGORITHM,
            "artifact_hash": validator.ARTIFACT_HASH,
            "rate": rate_profile(),
        },
        "environment": {
            "class": "staging",
            "verified_model_settlement_mode": "enforce",
            "staging_isolated": True,
            "production_endpoints_untouched": True,
            "credentials_redacted": True,
            "secrets_redacted": True,
        },
        "staging_config": copy.deepcopy(require_object(manifest.get("staging_config"), "staging_config")),
        "hardware": hardware,
        "runtime": runtime,
        "artifact_feed": feed,
        "preparation": preparation,
        "provider": provider,
        "admission": admission,
        "request": request,
        "route_snapshot": {
            "route_snapshot_digest": route_snapshot_digest,
            "artifact_binding_digest": binding_digest,
            "artifact_binding_source": "route_snapshot_referenced_immutable_record",
            "artifact_binding": copy.deepcopy(binding),
            "route_snapshot_v1": route_snapshot_v1,
        },
        "settlement": settlement,
        "settlement_verdict": settlement_verdict,
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

    validation = validator.validate_build1_narrow_mvp_evidence(evidence)
    if not validation.ok:
        details = "\n  ".join(validation.errors[:25])
        omitted = "" if len(validation.errors) <= 25 else f"\n  ... {len(validation.errors) - 25} more"
        raise CaptureError(f"assembled evidence failed validator:\n  {details}{omitted}")
    return evidence


def blocker_report(root: Path, *, captured_at: str | None) -> dict[str, Any]:
    return {
        "schema_version": BLOCKER_SCHEMA,
        "build_id": validator.BUILD_ID,
        "status": "blocked_missing_redacted_staging_inputs",
        "captured_at": captured_at or utc_now_z(),
        "repository": repository_context(root),
        "required_capture_manifest_schema": CAPTURE_MANIFEST_SCHEMA,
        "required_source_capture_schema": SOURCE_CAPTURE_SCHEMA,
        "required_source_capture_files": list(SOURCE_CAPTURE_FILE_KEYS),
        "required_sections": sorted(MANIFEST_KEYS - {"schema_version", "source_captures"}),
        "non_activation_boundary": {
            "production_activation_enabled": False,
            "production_enforcement_changed": False,
            "production_rewards_enabled": False,
            "payout_jobs_enabled": False,
            "payout_execution_enabled": False,
            "release_published": False,
        },
        "next_action": "run the isolated staging MLX provider journey and provide redacted capture manifest inputs",
    }


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--root", default=".", help="repository root")
    parser.add_argument("--input-manifest", type=Path, help="redacted physical-staging capture manifest")
    parser.add_argument("--output", type=Path, help="validated redacted evidence bundle output")
    parser.add_argument("--blocker-output", type=Path, help="write a blocker report instead of acceptance evidence")
    parser.add_argument("--captured-at", help="override top-level UTC capture timestamp")
    parser.add_argument("--redacted", action="store_true", help="required acknowledgement that source captures are redacted")
    args = parser.parse_args(argv)

    try:
        root = Path(args.root).resolve()
        captured_at = require_optional_iso_z(args.captured_at, "--captured-at")
        if args.input_manifest is None:
            if args.blocker_output is None:
                raise CaptureError("--input-manifest is required unless --blocker-output is supplied")
            write_json_atomically(args.blocker_output, blocker_report(root, captured_at=captured_at))
            print(f"collect-build1-narrow-mvp-evidence: wrote blocker report {args.blocker_output}")
            return 0
        if not args.redacted:
            raise CaptureError("--redacted is required before assembling acceptance evidence")
        if args.output is None:
            raise CaptureError("--output is required with --input-manifest")
        evidence = assemble_evidence(root, args.input_manifest.resolve(), captured_at=captured_at)
        write_json_atomically(args.output, evidence)
    except CaptureError as exc:
        die(str(exc))
    print(f"collect-build1-narrow-mvp-evidence: wrote validated evidence {args.output}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
