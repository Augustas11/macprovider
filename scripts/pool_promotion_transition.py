#!/usr/bin/env python3
"""SPEC-043 PoolPromotionTransitionV1 validator and rollback-resistant ledger.

Candidate JOURNEY-TRUSTED-POOL-CREATOR-MVP envelopes remain evidence-only until
`scripts/promote-signed-journey-result.py` consumes a sibling PoolPromotionTransitionV1.
This module never mutates specs/CONFORMANCE.json. A valid production-promotion
artifact may be verified and consumed into journeys/ledgers/spec-043-promotion-auth.jsonl
without promoting any SPEC-043 row.
"""

from __future__ import annotations

import argparse
import base64
import fcntl
import json
import os
import re
import subprocess
import sys
import tempfile
from contextlib import contextmanager
from datetime import datetime, timedelta, timezone
from pathlib import Path
from typing import Any, Iterator

try:
    from check_spec_governance import (
        DATETIME_Z_RE,
        JOURNEY_RESULT_ENVELOPE_SCHEMA,
        JOURNEY_RESULT_PAYLOAD_SCHEMA,
        JOURNEY_RESULT_PUBLIC_KEY_SHA256,
        JOURNEY_RESULT_SIGNING_ALGORITHM,
        JOURNEY_RESULT_SIGNING_KEY_ID,
        POOL_PROMOTION_TRANSITION_ENVELOPE_SCHEMA,
        SHA256_HEX_RE,
        TRUSTED_POOL_CREATOR_MVP_JOURNEY_ID,
        DuplicateJSONKeyError,
        ValidationResult,
        _canonical_json_bytes,
        _canonical_json_sha256,
        _expect_keys,
        _expect_object,
        _load_json,
        _unique_json_object,
        _verify_journey_result_signature,
        resolve_trusted_openssl,
    )
except ImportError:  # pragma: no cover - package import used by unittest
    from scripts.check_spec_governance import (
        DATETIME_Z_RE,
        JOURNEY_RESULT_ENVELOPE_SCHEMA,
        JOURNEY_RESULT_PAYLOAD_SCHEMA,
        JOURNEY_RESULT_PUBLIC_KEY_SHA256,
        JOURNEY_RESULT_SIGNING_ALGORITHM,
        JOURNEY_RESULT_SIGNING_KEY_ID,
        POOL_PROMOTION_TRANSITION_ENVELOPE_SCHEMA,
        SHA256_HEX_RE,
        TRUSTED_POOL_CREATOR_MVP_JOURNEY_ID,
        DuplicateJSONKeyError,
        ValidationResult,
        _canonical_json_bytes,
        _canonical_json_sha256,
        _expect_keys,
        _expect_object,
        _load_json,
        _unique_json_object,
        _verify_journey_result_signature,
        resolve_trusted_openssl,
    )


POOL_PROMOTION_TRANSITION_PAYLOAD_SCHEMA = "spec-043-promotion-auth-v1"
POOL_PROMOTION_TRANSITION_SIGNING_DOMAIN = b"macprovider.pool-promotion-transition.v1\n"
PRODUCTION_RELEASE_KEY_ID = "macprovider-spec043-production-release-p256-v1"
PRODUCTION_RELEASE_PURPOSE = "production-release-approver"
PRODUCTION_ENVIRONMENT_CLASS = "production"
KEYRING_PATH = Path("security/spec-043-production-release-keyring.json")
LEDGER_PATH = Path("journeys/ledgers/spec-043-promotion-auth.jsonl")
SPEC043_PROMOTION_LEDGER = {
    "named_subsystem": "spec043-promotion-ledger",
    "store_type": "append-only-jsonl",
    "path": str(LEDGER_PATH),
    "deployment_target": "repository-governance-ledger",
    "backup_restore_policy": "independent-of-coordinator-snapshots",
    "availability_sla": "best-effort-until-production-key-registration",
}
LEDGER_SCHEMA_VERSION = "spec-043-promotion-auth-ledger-v1"
LEDGER_INIT_TYPE = "ledger_init"
LEDGER_CONSUMED_TYPE = "consumed_authorization"
CANONICAL_LEDGER_INIT = {
    "type": LEDGER_INIT_TYPE,
    "schema_version": LEDGER_SCHEMA_VERSION,
    "named_subsystem": SPEC043_PROMOTION_LEDGER["named_subsystem"],
    "store_type": SPEC043_PROMOTION_LEDGER["store_type"],
    "deployment_target": SPEC043_PROMOTION_LEDGER["deployment_target"],
    "backup_restore_policy": SPEC043_PROMOTION_LEDGER["backup_restore_policy"],
    "availability_sla": SPEC043_PROMOTION_LEDGER["availability_sla"],
}
RESERVED_CANDIDATE_VALUES = frozenset(
    {
        PRODUCTION_RELEASE_KEY_ID,
        POOL_PROMOTION_TRANSITION_PAYLOAD_SCHEMA,
        POOL_PROMOTION_TRANSITION_ENVELOPE_SCHEMA,
    }
)
LEDGER_REVOCATION_TYPE = "key_revocation"
LEDGER_EMERGENCY_DISABLE_TYPE = "emergency_disable"
CONSUMED_AUTHORIZATION_REQUIRED = {
    "type",
    "schema_version",
    "named_subsystem",
    "journey_id",
    "run_id",
    "authorization_id",
    "pool_id",
    "transition_epoch",
    "key_id",
    "journey_result_digest",
    "recorded_at",
    "promotion_transition_source",
    "promotion_transition_digest",
}
MAX_AUTHORIZATION_TTL = timedelta(hours=24)
DEFAULT_CLOCK_SKEW = timedelta(seconds=300)
RBAC_ROLE = "production-release-approver"
TARGET_LIFECYCLE_TRANSITION = "active"

ENVELOPE_REQUIRED = {"schema_version", "signatures", "signed"}
SIGNATURE_REQUIRED = {"algorithm", "key_id", "signature", "signed_sha256", "verified_at", "verifier"}
SIGNED_REQUIRED = {
    "schema_version",
    "journey_id",
    "run_id",
    "journey_result_digest",
    "candidate_environment_id",
    "live_activation_target",
    "pool_id",
    "environment_id",
    "environment_class",
    "coordinator_build_id",
    "gateway_build_id",
    "provider_build_id",
    "schema_migration_hash",
    "effective_config_digest",
    "feature_flag_digest",
    "governance_file_digest",
    "approval_record_id",
    "approval_record_version",
    "creator_agreement_id",
    "creator_agreement_version",
    "creator_agreement_expires_at",
    "creator_agreement_grace_ends_at",
    "pricing_schedule_id",
    "pricing_schedule_version",
    "reviewed_distribution_artifact_digest",
    "root_issuer_fingerprint",
    "gate_check_id",
    "routeable_snapshot_digest",
    "pool_generation",
    "transition_epoch",
    "authorization_id",
    "verifier_challenge",
    "authorized_actor",
    "credential_id",
    "rbac_role",
    "authorized_at",
    "expiry",
    "target_lifecycle_transition",
}
SHA256_FIELDS = {
    "journey_result_digest",
    "schema_migration_hash",
    "effective_config_digest",
    "feature_flag_digest",
    "governance_file_digest",
    "reviewed_distribution_artifact_digest",
    "root_issuer_fingerprint",
    "routeable_snapshot_digest",
}
POSITIVE_INT_FIELDS = {
    "run_id",
    "approval_record_version",
    "creator_agreement_version",
    "pricing_schedule_version",
    "pool_generation",
    "transition_epoch",
}
UTC_FIELDS = {
    "creator_agreement_expires_at",
    "creator_agreement_grace_ends_at",
    "authorized_at",
    "expiry",
}
NONEMPTY_STRING_FIELDS = {
    "candidate_environment_id",
    "live_activation_target",
    "pool_id",
    "environment_id",
    "coordinator_build_id",
    "gateway_build_id",
    "provider_build_id",
    "approval_record_id",
    "creator_agreement_id",
    "pricing_schedule_id",
    "gate_check_id",
    "authorization_id",
    "verifier_challenge",
    "authorized_actor",
    "credential_id",
}
CANDIDATE_FORBIDDEN_KEYS = frozenset(
    {
        "journey_result_digest",
        "live_activation_target",
        "authorization_id",
        "consumed_authorization_id",
        "production_authorization_id",
        "transition_epoch",
        "production_transition_epoch",
        "target_lifecycle_transition",
        "promotion_verification",
        "promotion_verification_result",
        "promotion_authorization",
        "promotion_authorization_signature",
        "production_release_key_id",
        "production_release_approver_key_id",
    }
)
CANDIDATE_FORBIDDEN_KEY_FRAGMENTS = (
    "journeyresultdigest",
    "liveactivationtarget",
    "authorizationid",
    "transitionepoch",
    "targetlifecycletransition",
    "promotionverification",
    "promotionauthorization",
    "productionrelease",
)


def _normalized_field_name(key: str) -> str:
    return re.sub(r"[^a-z0-9]", "", key.lower())
KEYRING_KEY_REQUIRED = {
    "key_id",
    "purpose",
    "issuer",
    "valid_from",
    "valid_until",
    "allowed_environment_classes",
    "public_key_path",
}


def _parse_utc(value: Any, location: str, result: ValidationResult) -> datetime | None:
    if not isinstance(value, str) or not DATETIME_Z_RE.fullmatch(value):
        result.error(location, "must be an ISO UTC timestamp like 2026-08-04T12:34:56Z")
        return None
    return datetime.strptime(value, "%Y-%m-%dT%H:%M:%SZ").replace(tzinfo=timezone.utc)


def _positive_int(value: Any, location: str, result: ValidationResult) -> int | None:
    if isinstance(value, bool) or not isinstance(value, int) or value < 1:
        result.error(location, "must be a positive integer")
        return None
    return value


def _nonempty_string(value: Any, location: str, result: ValidationResult) -> str | None:
    if not isinstance(value, str) or not value:
        result.error(location, "must be a non-empty string")
        return None
    return value


def _reject_symlinks(path: Path, location: str, result: ValidationResult) -> bool:
    if path.is_symlink() or path.parent.is_symlink():
        result.error(location, f"must not be a symlink: {path}")
        return False
    return True


def _safe_repo_file(root: Path, relative: Path, location: str, result: ValidationResult) -> Path | None:
    try:
        candidate = (root / relative).resolve()
        candidate.relative_to(root.resolve())
    except (OSError, ValueError) as exc:
        result.error(location, f"invalid repository path {relative.as_posix()!r}: {exc}")
        return None
    if not _reject_symlinks(candidate, location, result):
        return None
    if not candidate.is_file():
        result.error(location, f"missing file: {relative.as_posix()}")
        return None
    return candidate


def candidate_forbidden_fields(value: Any, prefix: str = "") -> list[str]:
    found: list[str] = []
    if isinstance(value, dict):
        for key, item in value.items():
            location = f"{prefix}.{key}" if prefix else key
            normalized = _normalized_field_name(key)
            if key in CANDIDATE_FORBIDDEN_KEYS or any(
                fragment in normalized for fragment in CANDIDATE_FORBIDDEN_KEY_FRAGMENTS
            ):
                found.append(location)
            if normalized in {"schemaversion", "promotionschemaversion"} and item in RESERVED_CANDIDATE_VALUES:
                found.append(location)
            if normalized in {"keyid", "productionreleasekeyid"} and item == PRODUCTION_RELEASE_KEY_ID:
                found.append(location)
            if isinstance(item, str) and item in RESERVED_CANDIDATE_VALUES:
                found.append(location)
            found.extend(candidate_forbidden_fields(item, location))
    elif isinstance(value, list):
        for index, item in enumerate(value):
            found.extend(candidate_forbidden_fields(item, f"{prefix}[{index}]"))
    return found


def journey_result_digest(envelope: dict[str, Any]) -> str:
    return _canonical_json_sha256(envelope)


def _load_keyring(root: Path, result: ValidationResult) -> dict[str, Any] | None:
    path = _safe_repo_file(root, KEYRING_PATH, str(KEYRING_PATH), result)
    if path is None:
        return None
    keyring = _load_json(path, result)
    if not isinstance(keyring, dict):
        result.error(str(KEYRING_PATH), "must be a JSON object")
        return None
    if keyring.get("schema_version") != "spec-043-launch-keyring-v1":
        result.error(str(KEYRING_PATH), "schema_version must equal 'spec-043-launch-keyring-v1'")
    keys = keyring.get("keys")
    if not isinstance(keys, list):
        result.error(f"{KEYRING_PATH}.keys", "must be an array")
        return None
    return keyring


def _load_ledger_records(root: Path, result: ValidationResult) -> list[dict[str, Any]]:
    path = root / LEDGER_PATH
    if path.is_symlink() or path.parent.is_symlink():
        result.error(str(LEDGER_PATH), "must not be a symlink")
        return []
    if not path.is_file():
        result.error(str(LEDGER_PATH), "missing append-only promotion ledger")
        return []
    records: list[dict[str, Any]] = []
    try:
        text = path.read_text(encoding="utf-8")
    except OSError as exc:
        result.error(str(LEDGER_PATH), f"cannot read: {exc}")
        return []
    for line_number, raw in enumerate(text.splitlines(), start=1):
        line = raw.strip()
        if not line:
            continue
        try:
            record = json.loads(line, object_pairs_hook=_unique_json_object)
        except DuplicateJSONKeyError as exc:
            result.error(f"{LEDGER_PATH}:{line_number}", f"duplicate JSON object key {exc.args[0]!r}")
            continue
        except json.JSONDecodeError as exc:
            result.error(f"{LEDGER_PATH}:{line_number}", f"invalid JSON: {exc}")
            continue
        if not isinstance(record, dict):
            result.error(f"{LEDGER_PATH}:{line_number}", "ledger record must be a JSON object")
            continue
        records.append(record)
    return records


def _ledger_state(records: list[dict[str, Any]], *, as_of_index: int | None = None) -> dict[str, Any]:
    run_high_water: dict[str, int] = {}
    consumed_authorization_ids: set[str] = set()
    pool_epochs: dict[str, int] = {}
    revoked_keys: set[str] = set()
    emergency_disabled_keys: set[str] = set()
    iterable = records if as_of_index is None else records[:as_of_index]
    for record in iterable:
        record_type = record.get("type")
        if record_type == LEDGER_CONSUMED_TYPE:
            journey_id = record.get("journey_id")
            run_id = record.get("run_id")
            authorization_id = record.get("authorization_id")
            pool_id = record.get("pool_id")
            transition_epoch = record.get("transition_epoch")
            if isinstance(journey_id, str) and isinstance(run_id, int) and not isinstance(run_id, bool):
                run_high_water[journey_id] = max(run_high_water.get(journey_id, 0), run_id)
            if isinstance(authorization_id, str) and authorization_id:
                consumed_authorization_ids.add(authorization_id)
            if isinstance(pool_id, str) and isinstance(transition_epoch, int) and not isinstance(transition_epoch, bool):
                pool_epochs[pool_id] = max(pool_epochs.get(pool_id, 0), transition_epoch)
        elif record_type == LEDGER_REVOCATION_TYPE:
            key_id = record.get("key_id")
            if isinstance(key_id, str) and key_id:
                revoked_keys.add(key_id)
        elif record_type == LEDGER_EMERGENCY_DISABLE_TYPE:
            key_id = record.get("key_id")
            if isinstance(key_id, str) and key_id:
                emergency_disabled_keys.add(key_id)
    return {
        "run_high_water": run_high_water,
        "consumed_authorization_ids": consumed_authorization_ids,
        "pool_epochs": pool_epochs,
        "revoked_keys": revoked_keys,
        "emergency_disabled_keys": emergency_disabled_keys,
    }


def _consumed_authorization_record_valid(record: dict[str, Any]) -> bool:
    if set(record) != CONSUMED_AUTHORIZATION_REQUIRED:
        return False
    if record.get("type") != LEDGER_CONSUMED_TYPE:
        return False
    if record.get("schema_version") != LEDGER_SCHEMA_VERSION:
        return False
    if record.get("named_subsystem") != SPEC043_PROMOTION_LEDGER["named_subsystem"]:
        return False
    for field in ("journey_id", "authorization_id", "pool_id", "key_id"):
        value = record.get(field)
        if not isinstance(value, str) or not value:
            return False
    if record.get("key_id") == JOURNEY_RESULT_SIGNING_KEY_ID:
        return False
    run_id = record.get("run_id")
    epoch = record.get("transition_epoch")
    if isinstance(run_id, bool) or not isinstance(run_id, int) or run_id < 1:
        return False
    if isinstance(epoch, bool) or not isinstance(epoch, int) or epoch < 1:
        return False
    digest = record.get("journey_result_digest")
    if not isinstance(digest, str) or not SHA256_HEX_RE.fullmatch(digest):
        return False
    transition_digest = record.get("promotion_transition_digest")
    if not isinstance(transition_digest, str) or not SHA256_HEX_RE.fullmatch(transition_digest):
        return False
    source = record.get("promotion_transition_source")
    if not isinstance(source, str) or not source.startswith("journeys/evidence/") or not source.endswith(".json"):
        return False
    if Path(source).is_absolute() or ".." in Path(source).parts:
        return False
    recorded_at = record.get("recorded_at")
    return isinstance(recorded_at, str) and bool(DATETIME_Z_RE.fullmatch(recorded_at))


def _consumed_authorization_record(
    envelope: dict[str, Any],
    *,
    transition_source: str,
    recorded_at: str,
) -> dict[str, Any] | None:
    signed = envelope.get("signed")
    signatures = envelope.get("signatures")
    if not isinstance(signed, dict):
        return None
    if not isinstance(signatures, list) or len(signatures) != 1 or not isinstance(signatures[0], dict):
        return None
    signature = signatures[0]
    required_signed = ("journey_id", "run_id", "authorization_id", "pool_id", "transition_epoch", "journey_result_digest")
    if any(field not in signed for field in required_signed) or "key_id" not in signature:
        return None
    return {
        "type": LEDGER_CONSUMED_TYPE,
        "schema_version": LEDGER_SCHEMA_VERSION,
        "named_subsystem": SPEC043_PROMOTION_LEDGER["named_subsystem"],
        "journey_id": signed["journey_id"],
        "run_id": signed["run_id"],
        "authorization_id": signed["authorization_id"],
        "pool_id": signed["pool_id"],
        "transition_epoch": signed["transition_epoch"],
        "key_id": signature["key_id"],
        "journey_result_digest": signed["journey_result_digest"],
        "recorded_at": recorded_at,
        "promotion_transition_source": transition_source,
        "promotion_transition_digest": _canonical_json_sha256(envelope),
    }


def _require_transition_source(
    root: Path,
    transition_source: str,
    envelope: dict[str, Any],
    result: ValidationResult,
) -> str | None:
    relative = Path(transition_source)
    if relative.is_absolute() or ".." in relative.parts:
        result.error("promotion_transition_source", "must be a repository-relative path under journeys/evidence/")
        return None
    normalized = relative.as_posix()
    if not normalized.startswith("journeys/evidence/") or not normalized.endswith(".json"):
        result.error("promotion_transition_source", "must be a JSON file under journeys/evidence/")
        return None
    path = _safe_repo_file(root, Path(normalized), "promotion_transition_source", result)
    if path is None:
        return None
    loaded = load_json_object(path, "promotion_transition_source", result)
    if loaded is None:
        return None
    if _canonical_json_sha256(loaded) != _canonical_json_sha256(envelope):
        result.error("promotion_transition_source", "must match the canonical PoolPromotionTransitionV1 envelope")
        return None
    return normalized


def _consumed_record_bound_to_signed_transition(
    root: Path,
    record: dict[str, Any],
    candidate: dict[str, Any],
    openssl_bin: str,
    trusted_journey_result_public_key_sha256: str,
    ignore_index: int,
) -> bool:
    load_result = ValidationResult()
    path = _safe_repo_file(root, Path(record["promotion_transition_source"]), "promotion_transition_source", load_result)
    if path is None:
        return False
    envelope = load_json_object(path, "promotion_transition_source", load_result)
    if envelope is None or load_result.errors:
        return False
    if _canonical_json_sha256(envelope) != record["promotion_transition_digest"]:
        return False
    projected = _consumed_authorization_record(
        envelope,
        transition_source=record["promotion_transition_source"],
        recorded_at=record["recorded_at"],
    )
    if projected is None or projected != record:
        return False
    recorded_at = _parse_utc(record.get("recorded_at"), "consumed_authorization.recorded_at", ValidationResult())
    if recorded_at is None:
        return False
    result = validate_pool_promotion_transition(
        root,
        envelope,
        candidate,
        now=recorded_at,
        openssl_bin=openssl_bin,
        trusted_journey_result_public_key_sha256=trusted_journey_result_public_key_sha256,
        ignore_index=ignore_index,
    )
    return not result.errors


def creator_mvp_consumed_authorization(
    root: Path,
    candidate: dict[str, Any],
    *,
    openssl_bin: str | None = None,
    trusted_journey_result_public_key_sha256: str = JOURNEY_RESULT_PUBLIC_KEY_SHA256,
) -> bool:
    signed = candidate.get("signed")
    if not isinstance(signed, dict):
        return False
    journey_id = signed.get("journey_id")
    run_id = signed.get("run_id")
    if not isinstance(journey_id, str) or isinstance(run_id, bool) or not isinstance(run_id, int):
        return False
    digest = journey_result_digest(candidate)
    result = ValidationResult()
    records = _load_ledger_records(root, result)
    if result.errors or not records or records[0] != CANONICAL_LEDGER_INIT:
        return False
    try:
        trusted_openssl = resolve_trusted_openssl(openssl_bin)
    except ValueError:
        return False
    matched = False
    for index, record in enumerate(records):
        if index == 0:
            continue
        if record.get("type") != LEDGER_CONSUMED_TYPE:
            continue
        if not _consumed_authorization_record_valid(record):
            return False
        if (
            record.get("journey_id") != journey_id
            or record.get("run_id") != run_id
            or record.get("journey_result_digest") != digest
        ):
            continue
        if not _consumed_record_bound_to_signed_transition(
            root,
            record,
            candidate,
            trusted_openssl,
            trusted_journey_result_public_key_sha256,
            index,
        ):
            return False
        matched = True
    return matched


def _append_ledger_record_locked(handle: Any, record: dict[str, Any], ledger_dir: Path) -> None:
    handle.seek(0, os.SEEK_END)
    handle.write(json.dumps(record, sort_keys=True, separators=(",", ":")) + "\n")
    handle.flush()
    os.fsync(handle.fileno())
    dir_fd = os.open(str(ledger_dir), os.O_RDONLY)
    try:
        os.fsync(dir_fd)
    finally:
        os.close(dir_fd)


@contextmanager
def _exclusive_ledger(root: Path, result: ValidationResult) -> Iterator[Any | None]:
    path = root / LEDGER_PATH
    if path.is_symlink() or path.parent.is_symlink():
        result.error(str(LEDGER_PATH), "must not be a symlink")
        yield None
        return
    if not path.is_file():
        result.error(str(LEDGER_PATH), "missing append-only promotion ledger")
        yield None
        return
    handle = open(path, "a+", encoding="utf-8")
    try:
        fcntl.flock(handle.fileno(), fcntl.LOCK_EX)
        yield handle
    finally:
        try:
            fcntl.flock(handle.fileno(), fcntl.LOCK_UN)
        finally:
            handle.close()


def _validate_candidate_sibling(
    root: Path,
    candidate: dict[str, Any],
    promotion_signed: dict[str, Any],
    trusted_public_key_sha256: str,
    openssl_bin: str,
    result: ValidationResult,
) -> None:
    if candidate.get("schema_version") != JOURNEY_RESULT_ENVELOPE_SCHEMA:
        result.error("candidate.schema_version", f"must equal {JOURNEY_RESULT_ENVELOPE_SCHEMA!r}")
        return
    signatures = candidate.get("signatures")
    signed = candidate.get("signed")
    if not isinstance(signatures, list) or len(signatures) != 1 or not isinstance(signatures[0], dict):
        result.error("candidate.signatures", "must contain exactly one acceptance signature")
        return
    if not _expect_object(signed, "candidate.signed", result):
        return
    if signed.get("schema_version") != JOURNEY_RESULT_PAYLOAD_SCHEMA:
        result.error("candidate.signed.schema_version", f"must equal {JOURNEY_RESULT_PAYLOAD_SCHEMA!r}")
    if signed.get("journey_id") != TRUSTED_POOL_CREATOR_MVP_JOURNEY_ID:
        result.error("candidate.signed.journey_id", f"must equal {TRUSTED_POOL_CREATOR_MVP_JOURNEY_ID!r}")
    candidate_run_id = signed.get("run_id")
    if isinstance(candidate_run_id, bool) or not isinstance(candidate_run_id, int) or candidate_run_id < 1:
        result.error("candidate.signed.run_id", "must be a positive integer")
    elif candidate_run_id != promotion_signed.get("run_id"):
        result.error("pool-promotion-transition.signed.run_id", "must match signed candidate journey run_id")
    signature = signatures[0]
    if signature.get("key_id") != JOURNEY_RESULT_SIGNING_KEY_ID:
        result.error("candidate.signatures[0].key_id", "must equal the acceptance candidate signing key id")
    _verify_journey_result_signature(
        root,
        signed,
        signature,
        trusted_public_key_sha256,
        openssl_bin,
        "candidate.signatures[0]",
        result,
    )


def _verify_signature(
    signed: dict[str, Any],
    signature: dict[str, Any],
    public_key: Path,
    openssl_bin: str,
    location: str,
    result: ValidationResult,
) -> bool:
    encoded = signature.get("signature")
    if not isinstance(encoded, str) or not encoded:
        result.error(f"{location}.signature", "must be a non-empty base64 DER ECDSA signature")
        return False
    try:
        signature_bytes = base64.b64decode(encoded.encode("ascii"), validate=True)
    except (UnicodeEncodeError, ValueError) as exc:
        result.error(f"{location}.signature", f"invalid base64: {exc}")
        return False
    if base64.b64encode(signature_bytes).decode("ascii") != encoded:
        result.error(f"{location}.signature", "must use canonical base64 encoding")
        return False
    if not 64 <= len(signature_bytes) <= 80:
        result.error(f"{location}.signature", "invalid P-256 DER signature length")
        return False
    with tempfile.TemporaryDirectory(prefix="pool-promotion-verify.") as directory:
        tmp = Path(directory)
        message = tmp / "message"
        signature_path = tmp / "signature.der"
        message.write_bytes(POOL_PROMOTION_TRANSITION_SIGNING_DOMAIN + _canonical_json_bytes(signed))
        signature_path.write_bytes(signature_bytes)
        completed = subprocess.run(
            [
                openssl_bin,
                "dgst",
                "-sha256",
                "-verify",
                str(public_key),
                "-signature",
                str(signature_path),
                str(message),
            ],
            stdout=subprocess.DEVNULL,
            stderr=subprocess.PIPE,
            text=True,
            check=False,
            env={"PATH": "/usr/bin:/bin"},
            timeout=20,
        )
    if completed.returncode != 0:
        result.error(f"{location}.signature", "cryptographic verification failed")
        return False
    return True


def sign_pool_promotion_transition(
    signed: dict[str, Any],
    *,
    private_key_pem: str,
    public_key_pem: str,
    key_id: str,
    openssl_bin: str,
    verified_at: str,
    verifier: str = "scripts/pool_promotion_transition.py",
) -> dict[str, Any]:
    with tempfile.TemporaryDirectory(prefix="pool-promotion-sign.") as directory:
        work = Path(directory)
        private_path = work / "private.pem"
        public_path = work / "public.pem"
        message = work / "message"
        signature_path = work / "signature.der"
        private_path.write_text(private_key_pem, encoding="utf-8")
        private_path.chmod(0o600)
        public_path.write_text(public_key_pem, encoding="utf-8")
        message.write_bytes(POOL_PROMOTION_TRANSITION_SIGNING_DOMAIN + _canonical_json_bytes(signed))
        sign = subprocess.run(
            [openssl_bin, "dgst", "-sha256", "-sign", str(private_path), "-out", str(signature_path), str(message)],
            capture_output=True,
            check=False,
            env={"PATH": "/usr/bin:/bin"},
        )
        if sign.returncode != 0:
            detail = sign.stderr.decode("utf-8", errors="replace").strip()
            raise RuntimeError(detail or "openssl sign failed")
        verify = subprocess.run(
            [openssl_bin, "dgst", "-sha256", "-verify", str(public_path), "-signature", str(signature_path), str(message)],
            capture_output=True,
            check=False,
            env={"PATH": "/usr/bin:/bin"},
        )
        if verify.returncode != 0:
            raise RuntimeError("openssl verify of freshly signed promotion artifact failed")
        signature_b64 = base64.b64encode(signature_path.read_bytes()).decode("ascii")
    return {
        "schema_version": POOL_PROMOTION_TRANSITION_ENVELOPE_SCHEMA,
        "signatures": [
            {
                "algorithm": JOURNEY_RESULT_SIGNING_ALGORITHM,
                "key_id": key_id,
                "signature": signature_b64,
                "signed_sha256": _canonical_json_sha256(signed),
                "verified_at": verified_at,
                "verifier": verifier,
            }
        ],
        "signed": signed,
    }


def _match_keyring_key(
    root: Path,
    keyring: dict[str, Any],
    key_id: str,
    now: datetime,
    location: str,
    result: ValidationResult,
) -> dict[str, Any] | None:
    keys = keyring.get("keys")
    if not isinstance(keys, list) or not keys:
        result.error(str(KEYRING_PATH), "is fail-closed: no production-release approver key is registered")
        return None
    matches = [item for item in keys if isinstance(item, dict) and item.get("key_id") == key_id]
    if not matches:
        result.error(f"{location}.key_id", f"is not registered in {KEYRING_PATH.as_posix()}")
        return None
    if len(matches) != 1:
        result.error(f"{location}.key_id", "must match exactly one keyring entry")
        return None
    entry = matches[0]
    before = len(result.errors)
    _expect_keys(entry, KEYRING_KEY_REQUIRED, KEYRING_KEY_REQUIRED, f"{KEYRING_PATH}.keys", result)
    if len(result.errors) != before:
        return None
    if entry.get("purpose") != PRODUCTION_RELEASE_PURPOSE:
        result.error(f"{location}.key_id", f"purpose must equal {PRODUCTION_RELEASE_PURPOSE!r}")
    allowed = entry.get("allowed_environment_classes")
    if not isinstance(allowed, list) or PRODUCTION_ENVIRONMENT_CLASS not in allowed:
        result.error(f"{location}.key_id", "allowed environment class must include 'production'")
    valid_from = _parse_utc(entry.get("valid_from"), f"{KEYRING_PATH}.keys.valid_from", result)
    valid_until = _parse_utc(entry.get("valid_until"), f"{KEYRING_PATH}.keys.valid_until", result)
    if valid_from is not None and now < valid_from:
        result.error(f"{location}.key_id", "is not yet valid")
    if valid_until is not None and now > valid_until:
        result.error(f"{location}.key_id", "has expired")
    public_key_path = entry.get("public_key_path")
    if not isinstance(public_key_path, str) or Path(public_key_path).is_absolute() or ".." in Path(public_key_path).parts:
        result.error(f"{KEYRING_PATH}.keys.public_key_path", "must be a relative repository path")
        return None
    public_key = _safe_repo_file(root, Path(public_key_path), f"{KEYRING_PATH}.keys.public_key_path", result)
    if public_key is None:
        return None
    entry = dict(entry)
    entry["_public_key_path"] = public_key
    return entry


def validate_pool_promotion_transition(
    root: Path,
    envelope: dict[str, Any],
    candidate: dict[str, Any],
    *,
    now: datetime | None = None,
    openssl_bin: str | None = None,
    trusted_journey_result_public_key_sha256: str = JOURNEY_RESULT_PUBLIC_KEY_SHA256,
    location: str = "pool-promotion-transition",
    result: ValidationResult | None = None,
    ignore_index: int | None = None,
) -> ValidationResult:
    result = result or ValidationResult()
    now = now or datetime.now(timezone.utc)
    try:
        trusted_openssl = resolve_trusted_openssl(openssl_bin)
    except ValueError as exc:
        result.error("openssl", str(exc))
        return result

    if not _expect_object(envelope, location, result):
        return result
    _expect_keys(envelope, ENVELOPE_REQUIRED, ENVELOPE_REQUIRED, location, result)
    if envelope.get("schema_version") != POOL_PROMOTION_TRANSITION_ENVELOPE_SCHEMA:
        result.error(f"{location}.schema_version", f"must equal {POOL_PROMOTION_TRANSITION_ENVELOPE_SCHEMA!r}")

    signatures = envelope.get("signatures")
    signed = envelope.get("signed")
    if not isinstance(signatures, list) or len(signatures) != 1:
        result.error(f"{location}.signatures", "must contain exactly one signature")
        return result
    if not _expect_object(signed, f"{location}.signed", result):
        return result
    signature = signatures[0]
    if not _expect_object(signature, f"{location}.signatures[0]", result):
        return result
    _expect_keys(signature, SIGNATURE_REQUIRED, SIGNATURE_REQUIRED, f"{location}.signatures[0]", result)
    if signature.get("algorithm") != JOURNEY_RESULT_SIGNING_ALGORITHM:
        result.error(f"{location}.signatures[0].algorithm", f"must equal {JOURNEY_RESULT_SIGNING_ALGORITHM!r}")
    key_id = signature.get("key_id")
    if key_id == JOURNEY_RESULT_SIGNING_KEY_ID:
        result.error(
            f"{location}.signatures[0].key_id",
            "acceptance candidate key cannot sign a production promotion artifact",
        )
    if not isinstance(key_id, str) or not key_id:
        result.error(f"{location}.signatures[0].key_id", "must be a non-empty string")
        return result
    if signature.get("signed_sha256") != _canonical_json_sha256(signed):
        result.error(f"{location}.signatures[0].signed_sha256", "does not match canonical signed preimage")
    _parse_utc(signature.get("verified_at"), f"{location}.signatures[0].verified_at", result)
    _nonempty_string(signature.get("verifier"), f"{location}.signatures[0].verifier", result)

    _expect_keys(signed, SIGNED_REQUIRED, SIGNED_REQUIRED, f"{location}.signed", result)
    if signed.get("schema_version") != POOL_PROMOTION_TRANSITION_PAYLOAD_SCHEMA:
        result.error(f"{location}.signed.schema_version", f"must equal {POOL_PROMOTION_TRANSITION_PAYLOAD_SCHEMA!r}")
    if signed.get("journey_id") != TRUSTED_POOL_CREATOR_MVP_JOURNEY_ID:
        result.error(f"{location}.signed.journey_id", f"must equal {TRUSTED_POOL_CREATOR_MVP_JOURNEY_ID!r}")
    if signed.get("rbac_role") != RBAC_ROLE:
        result.error(f"{location}.signed.rbac_role", f"must equal {RBAC_ROLE!r}")
    if signed.get("environment_class") != PRODUCTION_ENVIRONMENT_CLASS:
        result.error(f"{location}.signed.environment_class", f"must equal {PRODUCTION_ENVIRONMENT_CLASS!r}")
    if signed.get("target_lifecycle_transition") != TARGET_LIFECYCLE_TRANSITION:
        result.error(f"{location}.signed.target_lifecycle_transition", f"must equal {TARGET_LIFECYCLE_TRANSITION!r}")

    parsed: dict[str, Any] = {}
    for field in NONEMPTY_STRING_FIELDS:
        parsed[field] = _nonempty_string(signed.get(field), f"{location}.signed.{field}", result)
    for field in SHA256_FIELDS:
        value = signed.get(field)
        if not isinstance(value, str) or not SHA256_HEX_RE.fullmatch(value):
            result.error(f"{location}.signed.{field}", "must be a lowercase SHA-256 hex digest")
        else:
            parsed[field] = value
    for field in POSITIVE_INT_FIELDS:
        parsed[field] = _positive_int(signed.get(field), f"{location}.signed.{field}", result)
    for field in UTC_FIELDS:
        parsed[field] = _parse_utc(signed.get(field), f"{location}.signed.{field}", result)

    candidate_environment_id = parsed.get("candidate_environment_id")
    live_activation_target = parsed.get("live_activation_target")
    environment_id = parsed.get("environment_id")
    if (
        isinstance(candidate_environment_id, str)
        and isinstance(live_activation_target, str)
        and candidate_environment_id == live_activation_target
    ):
        result.error(f"{location}.signed.live_activation_target", "must be distinct from the isolated candidate environment")
    if (
        isinstance(environment_id, str)
        and isinstance(live_activation_target, str)
        and environment_id != live_activation_target
    ):
        result.error(f"{location}.signed.environment_id", "must equal live_activation_target")

    authorized_at = parsed.get("authorized_at")
    expiry = parsed.get("expiry")
    if isinstance(authorized_at, datetime) and authorized_at > now + DEFAULT_CLOCK_SKEW:
        result.error(f"{location}.signed.authorized_at", "is in the future beyond the clock-skew allowance")
    if isinstance(expiry, datetime) and expiry <= now:
        result.error(f"{location}.signed.expiry", "authorization has expired")
    if isinstance(authorized_at, datetime) and isinstance(expiry, datetime):
        if expiry <= authorized_at:
            result.error(f"{location}.signed.expiry", "must be after authorized_at")
        elif expiry - authorized_at > MAX_AUTHORIZATION_TTL:
            result.error(f"{location}.signed.expiry", "promotion-authorization TTL must not exceed 24 hours")

    agreement_expires = parsed.get("creator_agreement_expires_at")
    agreement_grace = parsed.get("creator_agreement_grace_ends_at")
    if isinstance(agreement_expires, datetime) and isinstance(agreement_grace, datetime) and agreement_grace < agreement_expires:
        result.error(f"{location}.signed.creator_agreement_grace_ends_at", "must be on or after creator_agreement_expires_at")

    if not _expect_object(candidate, "candidate", result):
        return result
    forbidden = candidate_forbidden_fields(candidate)
    for field in forbidden:
        result.error("candidate", f"contains production-promotion field {field}")
    expected_digest = journey_result_digest(candidate)
    if parsed.get("journey_result_digest") and parsed["journey_result_digest"] != expected_digest:
        result.error(f"{location}.signed.journey_result_digest", "must equal SHA256(canonical signed candidate envelope)")
    _validate_candidate_sibling(
        root,
        candidate,
        signed if isinstance(signed, dict) else {},
        trusted_journey_result_public_key_sha256,
        trusted_openssl,
        result,
    )

    keyring = _load_keyring(root, result)
    records = _load_ledger_records(root, result)
    if not records or records[0] != CANONICAL_LEDGER_INIT:
        result.error(str(LEDGER_PATH), "must start with a canonical ledger_init record")
    state = _ledger_state(records, as_of_index=ignore_index)
    if key_id in state["revoked_keys"]:
        result.error(f"{location}.signatures[0].key_id", "is revoked in the append-only promotion ledger")
    if key_id in state["emergency_disabled_keys"]:
        result.error(f"{location}.signatures[0].key_id", "is emergency-disabled in the append-only promotion ledger")
    if isinstance(keyring, dict) and key_id != JOURNEY_RESULT_SIGNING_KEY_ID:
        entry = _match_keyring_key(root, keyring, key_id, now, f"{location}.signatures[0]", result)
        if entry is not None:
            _verify_signature(signed, signature, entry["_public_key_path"], trusted_openssl, f"{location}.signatures[0]", result)

    run_id = parsed.get("run_id")
    journey_id = signed.get("journey_id")
    if isinstance(run_id, int) and isinstance(journey_id, str):
        high_water = state["run_high_water"].get(journey_id, 0)
        if run_id <= high_water:
            result.error(f"{location}.signed.run_id", f"must be strictly greater than persisted high-water {high_water}")
    authorization_id = parsed.get("authorization_id")
    if isinstance(authorization_id, str) and authorization_id in state["consumed_authorization_ids"]:
        result.error(f"{location}.signed.authorization_id", "has already been consumed")
    pool_id = parsed.get("pool_id")
    transition_epoch = parsed.get("transition_epoch")
    if isinstance(pool_id, str) and isinstance(transition_epoch, int):
        last_epoch = state["pool_epochs"].get(pool_id, 0)
        if transition_epoch <= last_epoch:
            result.error(
                f"{location}.signed.transition_epoch",
                f"must be strictly greater than persisted epoch {last_epoch} for pool_id",
            )
    return result


def consume_pool_promotion_transition(
    root: Path,
    envelope: dict[str, Any],
    candidate: dict[str, Any],
    *,
    now: datetime | None = None,
    openssl_bin: str | None = None,
    trusted_journey_result_public_key_sha256: str = JOURNEY_RESULT_PUBLIC_KEY_SHA256,
    recorded_at: str | None = None,
    transition_source: str = "journeys/evidence/pool-promotion-transition.json",
) -> ValidationResult:
    result = ValidationResult()
    with _exclusive_ledger(root, result) as handle:
        if handle is None:
            return result
        result = validate_pool_promotion_transition(
            root,
            envelope,
            candidate,
            now=now,
            openssl_bin=openssl_bin,
            trusted_journey_result_public_key_sha256=trusted_journey_result_public_key_sha256,
        )
        if result.errors:
            return result
        source = _require_transition_source(root, transition_source, envelope, result)
        if source is None or result.errors:
            return result
        stamp = recorded_at or (now or datetime.now(timezone.utc)).strftime("%Y-%m-%dT%H:%M:%SZ")
        record = _consumed_authorization_record(envelope, transition_source=source, recorded_at=stamp)
        if record is None:
            result.error("pool-promotion-transition", "cannot project a consumed_authorization ledger record")
            return result
        _append_ledger_record_locked(
            handle,
            record,
            (root / LEDGER_PATH).parent,
        )
        return result
    return result


def load_json_object(path: Path, label: str, result: ValidationResult) -> dict[str, Any] | None:
    value = _load_json(path, result)
    if value is None:
        return None
    if not isinstance(value, dict):
        result.error(label, "must be a JSON object")
        return None
    return value


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--root", default=".", help="repository root")
    parser.add_argument("--transition", required=True, help="PoolPromotionTransitionV1 envelope JSON")
    parser.add_argument("--candidate", required=True, help="signed candidate journey-result envelope JSON")
    parser.add_argument("--consume", action="store_true", help="atomically consume authorization_id into the promotion ledger")
    parser.add_argument("--now", default=None, help="UTC now override, like 2026-08-25T00:00:00Z")
    parser.add_argument("--openssl-bin", default=None, help="absolute path to trusted OpenSSL")
    parser.add_argument(
        "--trusted-journey-result-public-key-sha256",
        default=JOURNEY_RESULT_PUBLIC_KEY_SHA256,
        help="pinned SHA-256 of the candidate journey-result public key",
    )
    args = parser.parse_args(argv)

    root = Path(args.root).resolve()
    result = ValidationResult()
    now = None
    if args.now is not None:
        now = _parse_utc(args.now, "--now", result)
        if result.errors:
            for error in result.errors:
                print(f"error: {error}", file=sys.stderr)
            return 1
    transition_path = Path(args.transition)
    if not transition_path.is_absolute():
        transition_path = root / transition_path
    candidate_path = Path(args.candidate)
    if not candidate_path.is_absolute():
        candidate_path = root / candidate_path
    envelope = load_json_object(transition_path, str(transition_path), result)
    candidate = load_json_object(candidate_path, str(candidate_path), result)
    if envelope is None or candidate is None:
        for error in result.errors:
            print(f"error: {error}", file=sys.stderr)
        return 1
    if args.consume:
        try:
            transition_source = str(transition_path.resolve().relative_to(root))
        except ValueError:
            print("error: --transition must be inside the repository root to consume", file=sys.stderr)
            return 1
        outcome = consume_pool_promotion_transition(
            root,
            envelope,
            candidate,
            now=now,
            openssl_bin=args.openssl_bin,
            trusted_journey_result_public_key_sha256=args.trusted_journey_result_public_key_sha256,
            transition_source=transition_source,
        )
    else:
        outcome = validate_pool_promotion_transition(
            root,
            envelope,
            candidate,
            now=now,
            openssl_bin=args.openssl_bin,
            trusted_journey_result_public_key_sha256=args.trusted_journey_result_public_key_sha256,
        )
    if outcome.errors:
        for error in outcome.errors:
            print(f"error: {error}", file=sys.stderr)
        return 1
    action = "consumed" if args.consume else "validated"
    print(f"pool-promotion-transition: {action} {transition_path}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
