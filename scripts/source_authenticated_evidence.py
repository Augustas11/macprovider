#!/usr/bin/env python3
"""Validate source-authenticated evidence envelope authenticity.

This is the B1 foundation only. It verifies producer Ed25519 signatures,
registry authorization, caller-bound run/nonce/deployment expectations, bounded
canonical JSON, and replay/tamper resistance for source-authenticated exports.
It deliberately does not prove refusal completeness, absence of rows, refund
semantics, or source-record projection meaning; producer APIs and promotion
joins are future work.

Canonical JSON note: this module admits only a safe ASCII/string, integer,
boolean, null, array, object subset. For that subset, the sorted compact UTF-8
encoding below is the JCS byte form used for signatures. Non-ASCII strings,
floats, and unsafe integers are rejected rather than treated as general RFC 8785
JCS support.
"""
from __future__ import annotations

import argparse
import base64
import datetime as _dt
import hashlib
import json
import os
import pathlib
import re
import subprocess
import sys
import tempfile
from dataclasses import dataclass
from typing import Any

ENVELOPE_SCHEMA = "macprovider.source-authenticated-export-envelope.v1"
SIGNED_SCHEMA = "macprovider.source-authenticated-export.v1"
REGISTRY_SCHEMA = "macprovider.source-evidence-key-registry.v1"
SIGNATURE_DOMAIN_NAME = "macprovider.source-authenticated-export.v1"
SIGNATURE_DOMAIN = (SIGNATURE_DOMAIN_NAME + "\n").encode("ascii")
ED25519_SPKI_DER_PREFIX = bytes.fromhex("302a300506032b6570032100")
MAX_SAFE_INTEGER = 9_007_199_254_740_991
MAX_INPUT_BYTES = 2 * 1024 * 1024
MAX_RECORDS = 1_000
MAX_REQUEST_SCOPES = 1_000
SAFE_ASCII_RE = re.compile(r"^[ -~]+$")
KEY_ID_RE = re.compile(r"^[A-Za-z0-9._:-]{1,128}$")
PRODUCER_RE = re.compile(r"^(gateway|coordinator)$")
ROLE_RE = re.compile(r"^[a-z][a-z0-9_]{0,63}$")
DOMAIN_RE = re.compile(r"^[a-z][a-z0-9_.:-]{0,127}$")
INSTANCE_RE = re.compile(r"^[A-Za-z0-9._:-]{1,128}$")
SOURCE_SHA_RE = re.compile(r"^[0-9a-f]{40}$")
UUID_RE = re.compile(r"^[0-9a-f]{8}-[0-9a-f]{4}-[1-5][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$")
HEX64_RE = re.compile(r"^[0-9a-f]{64}$")
B64URL_RE = re.compile(r"^[A-Za-z0-9_-]+$")
UTCMS_RE = re.compile(r"^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}\.\d{3}Z$")
COORDINATOR_NO_DISPATCH_ROLE = "no_dispatch_refusal"
COORDINATOR_SOURCE_SNAPSHOT_SCHEMA = "macprovider.coordinator-source-snapshot.v1"
COORDINATOR_NO_DISPATCH_RECORD_SCHEMA = "macprovider.coordinator-no-dispatch-record.v1"
COORDINATOR_NO_DISPATCH_CLOSURE_SCHEMA = "macprovider.coordinator-no-dispatch-closure.v1"
COORDINATOR_CONTRACT_VERSION = "coordinator-no-dispatch-v1"
COORDINATOR_REGISTRY_DIGEST_RE = re.compile(r"^sha256:[0-9a-f]{64}$")



class EvidenceError(ValueError):
    pass


def fail(path: str, message: str) -> None:
    raise EvidenceError(f"{path}: {message}")


def _reject_duplicate_keys(pairs: list[tuple[str, Any]]) -> dict[str, Any]:
    seen: set[str] = set()
    duplicates: list[str] = []
    out: dict[str, Any] = {}
    for key, value in pairs:
        if key in seen:
            duplicates.append(key)
        seen.add(key)
        out[key] = value
    if duplicates:
        raise EvidenceError(f"duplicate JSON key(s): {sorted(set(duplicates))}")
    return out


def load_json_bytes(data: bytes, label: str = "$") -> Any:
    if len(data) > MAX_INPUT_BYTES:
        fail(label, f"input exceeds {MAX_INPUT_BYTES} bytes")
    try:
        text = data.decode("utf-8")
    except UnicodeDecodeError as exc:
        fail(label, f"must be UTF-8 JSON: {exc}")
    if _raw_json_depth_exceeds(text, 512):
        fail(label, "JSON nesting exceeds safe parser depth")
    try:
        value = json.loads(
            text,
            object_pairs_hook=_reject_duplicate_keys,
            parse_float=lambda raw: (_ for _ in ()).throw(EvidenceError(f"floats are not admitted in source evidence JSON: {raw}")),
        )
    except json.JSONDecodeError as exc:
        fail(label, f"invalid JSON: {exc}")
    except RecursionError:
        fail(label, "JSON nesting exceeds safe parser depth")
    return value


def load_json_file(path: pathlib.Path, label: str = "$") -> Any:
    with path.open("rb") as fh:
        data = fh.read(MAX_INPUT_BYTES + 1)
    return load_json_bytes(data, label)




def _raw_json_depth_exceeds(text: str, limit: int) -> bool:
    depth = 0
    in_string = False
    escaped = False
    for ch in text:
        if in_string:
            if escaped:
                escaped = False
            elif ch == "\\":
                escaped = True
            elif ch == '"':
                in_string = False
            continue
        if ch == '"':
            in_string = True
        elif ch == "{" or ch == "[":
            depth += 1
            if depth > limit:
                return True
        elif ch == "}" or ch == "]":
            depth = max(0, depth - 1)
    return False

def canonical_bytes(value: Any) -> bytes:
    _validate_canonical_subset(value, "$")
    return json.dumps(value, ensure_ascii=False, separators=(",", ":"), sort_keys=True).encode("utf-8")


def _validate_canonical_subset(value: Any, path: str) -> None:
    if value is None or isinstance(value, bool):
        return
    if isinstance(value, int):
        if isinstance(value, bool) or value < 0 or value > MAX_SAFE_INTEGER:
            fail(path, f"integer must be in 0..{MAX_SAFE_INTEGER}")
        return
    if isinstance(value, float):
        fail(path, "floats are not admitted")
    if isinstance(value, str):
        require_ascii(value, path, max_len=4096, allow_empty=True)
        return
    if isinstance(value, list):
        if path.count(".") + path.count("[") > 64:
            fail(path, "JSON nesting exceeds safe canonical depth")
        if len(value) > MAX_RECORDS:
            fail(path, f"array has too many items; max {MAX_RECORDS}")
        for i, item in enumerate(value):
            _validate_canonical_subset(item, f"{path}[{i}]")
        return
    if isinstance(value, dict):
        if path.count(".") + path.count("[") > 64:
            fail(path, "JSON nesting exceeds safe canonical depth")
        for key in value:
            require_ascii(key, f"{path} key", max_len=128)
        for key in sorted(value):
            _validate_canonical_subset(value[key], f"{path}.{key}")
        return
    fail(path, f"unsupported JSON value type {type(value).__name__}")


def exact_keys(obj: Any, keys: set[str], path: str) -> dict[str, Any]:
    if not isinstance(obj, dict):
        fail(path, "must be an object")
    missing = keys - obj.keys()
    extra = obj.keys() - keys
    if missing or extra:
        fail(path, f"missing {sorted(missing)} extra {sorted(extra)}")
    return obj


def require_ascii(value: Any, path: str, *, pattern: re.Pattern[str] | None = None, max_len: int = 128, allow_empty: bool = False) -> str:
    if not isinstance(value, str):
        fail(path, "must be a string")
    if not allow_empty and not value:
        fail(path, "must be non-empty")
    if len(value.encode("utf-8")) > max_len:
        fail(path, f"must be at most {max_len} UTF-8 bytes")
    if value and SAFE_ASCII_RE.fullmatch(value) is None:
        fail(path, "must be printable ASCII only")
    if value != value.strip():
        fail(path, "must not have leading or trailing whitespace")
    if pattern is not None and pattern.fullmatch(value) is None:
        fail(path, f"does not match {pattern.pattern}")
    return value


def require_bool(value: Any, path: str) -> bool:
    if not isinstance(value, bool):
        fail(path, "must be a boolean")
    return value


def require_int(value: Any, path: str, lo: int = 0, hi: int = MAX_SAFE_INTEGER) -> int:
    if not isinstance(value, int) or isinstance(value, bool) or not (lo <= value <= hi):
        fail(path, f"must be an integer in {lo}..{hi}")
    return value


def require_timestamp_ms(value: Any, path: str) -> str:
    ts = require_ascii(value, path, pattern=UTCMS_RE, max_len=24)
    try:
        _dt.datetime.strptime(ts, "%Y-%m-%dT%H:%M:%S.%fZ").replace(tzinfo=_dt.timezone.utc)
    except ValueError as exc:
        fail(path, f"invalid UTC millisecond timestamp: {exc}")
    return ts


def parse_timestamp_ms(value: str) -> _dt.datetime:
    return _dt.datetime.strptime(value, "%Y-%m-%dT%H:%M:%S.%fZ").replace(tzinfo=_dt.timezone.utc)


def decode_b64url(value: Any, path: str, expected_len: int) -> bytes:
    text = require_ascii(value, path, pattern=B64URL_RE, max_len=256)
    if "=" in text:
        fail(path, "must be unpadded base64url")
    padding = "=" * ((4 - len(text) % 4) % 4)
    try:
        raw = base64.urlsafe_b64decode((text + padding).encode("ascii"))
    except Exception as exc:  # pragma: no cover - exact exception varies by Python
        fail(path, f"invalid base64url: {exc}")
    if len(raw) != expected_len:
        fail(path, f"must decode to {expected_len} bytes")
    if base64.urlsafe_b64encode(raw).decode("ascii").rstrip("=") != text:
        fail(path, "must be canonical unpadded base64url")
    return raw


def sha256_hex(data: bytes) -> str:
    return hashlib.sha256(data).hexdigest()


@dataclass(frozen=True)
class ExpectedExport:
    producer: str
    role: str
    instance_id: str
    source_sha: str
    run_id: str
    challenge_nonce: str
    domain: str
    now: _dt.datetime
    max_age_seconds: int = 300


def validate_registry(registry: Any, *, now: _dt.datetime | None = None, require_nonempty: bool = True) -> dict[str, dict[str, Any]]:
    reg = exact_keys(registry, {"schema_version", "keys"}, "$registry")
    if reg["schema_version"] != REGISTRY_SCHEMA:
        fail("$registry.schema_version", f"must equal {REGISTRY_SCHEMA}")
    keys = reg["keys"]
    if not isinstance(keys, list):
        fail("$registry.keys", "must be an array")
    if require_nonempty and not keys:
        fail("$registry.keys", "approved production registry is empty; fail closed until a reviewed source key exists")
    by_id: dict[str, dict[str, Any]] = {}
    for i, raw in enumerate(keys):
        path = f"$registry.keys[{i}]"
        row = exact_keys(
            raw,
            {
                "key_id",
                "algorithm",
                "public_key",
                "producer",
                "instance_id",
                "permitted_roles",
                "permitted_domains",
                "not_before",
                "not_after",
                "revoked_at",
                "reviewed_source_constraints",
            },
            path,
        )
        key_id = require_ascii(row["key_id"], f"{path}.key_id", pattern=KEY_ID_RE)
        if key_id in by_id:
            fail(f"{path}.key_id", "duplicate key_id")
        if row["algorithm"] != "ed25519":
            fail(f"{path}.algorithm", "must equal ed25519")
        decode_b64url(row["public_key"], f"{path}.public_key", 32)
        require_ascii(row["producer"], f"{path}.producer", pattern=PRODUCER_RE)
        require_ascii(row["instance_id"], f"{path}.instance_id", pattern=INSTANCE_RE)
        roles = _unique_ascii_array(row["permitted_roles"], f"{path}.permitted_roles", ROLE_RE, max_items=16)
        domains = _unique_ascii_array(row["permitted_domains"], f"{path}.permitted_domains", DOMAIN_RE, max_items=16)
        if not roles:
            fail(f"{path}.permitted_roles", "must not be empty")
        if not domains:
            fail(f"{path}.permitted_domains", "must not be empty")
        not_before = require_timestamp_ms(row["not_before"], f"{path}.not_before")
        not_after = require_timestamp_ms(row["not_after"], f"{path}.not_after")
        revoked = row["revoked_at"]
        if revoked is not None:
            require_timestamp_ms(revoked, f"{path}.revoked_at")
        constraints = exact_keys(row["reviewed_source_constraints"], {"source_sha_allowlist", "notes"}, f"{path}.reviewed_source_constraints")
        shas = _unique_ascii_array(constraints["source_sha_allowlist"], f"{path}.reviewed_source_constraints.source_sha_allowlist", SOURCE_SHA_RE, max_items=64)
        if not shas:
            fail(f"{path}.reviewed_source_constraints.source_sha_allowlist", "must not be empty")
        require_ascii(constraints["notes"], f"{path}.reviewed_source_constraints.notes", max_len=512)
        if parse_timestamp_ms(not_before) >= parse_timestamp_ms(not_after):
            fail(path, "key validity window is empty or inverted")
        by_id[key_id] = row
    return by_id


def _unique_ascii_array(value: Any, path: str, pattern: re.Pattern[str], *, max_items: int) -> list[str]:
    if not isinstance(value, list):
        fail(path, "must be an array")
    if len(value) > max_items:
        fail(path, f"must have at most {max_items} items")
    out: list[str] = []
    seen: set[str] = set()
    for i, item in enumerate(value):
        s = require_ascii(item, f"{path}[{i}]", pattern=pattern)
        if s in seen:
            fail(f"{path}[{i}]", "duplicate item")
        seen.add(s)
        out.append(s)
    return out


def validate_typed_projection(signed: dict[str, Any], registry_digest: str) -> dict[str, Any]:
    """Validate source-specific record meaning for roles this consumer knows.

    B1a authenticity remains role-opaque by default. The first typed projection
    is deliberately narrow: coordinator no-dispatch refusal exports may contain
    only all-or-nothing closed_terminal records with exact settlement absence.
    """
    if signed["producer"] != "coordinator" or signed["role"] != COORDINATOR_NO_DISPATCH_ROLE:
        return {"typed_projection": "opaque_authenticity_only"}
    validate_coordinator_snapshot(signed["snapshot"], registry_digest)
    generated_at = parse_timestamp_ms(signed["generated_at"])
    scopes = signed["request_scopes"]
    records = signed["records"]
    if not records:
        fail("$envelope.signed.records", "coordinator no-dispatch export must contain closed records; unavailable scopes are not signed")
    if len(records) != len(scopes):
        fail("$envelope.signed.records", "must match request_scopes one-for-one for closed all-or-nothing export")
    record_scopes: list[str] = []
    terminal_kinds: set[str] = set()
    for i, record in enumerate(records):
        validate_coordinator_no_dispatch_record(record, f"$envelope.signed.records[{i}]", generated_at)
        record_scopes.append(record["request_scope_commitment"])
        terminal_kinds.add(record["terminal_kind"])
    if record_scopes != scopes:
        fail("$envelope.signed.records", "record request_scope_commitment values must exactly equal sorted request_scopes")
    return {
        "typed_projection": "coordinator_no_dispatch_closed_terminal_v1",
        "terminal_kinds": sorted(terminal_kinds),
    }


def validate_coordinator_snapshot(snapshot: Any, registry_digest: str) -> dict[str, Any]:
    snap = exact_keys(
        snapshot,
        {
            "schema_version",
            "producer_contract_version",
            "registry_bundle_digest",
            "closure_table_schema",
            "db_fence_schema",
            "record_schema",
            "canonicalization",
            "scope_hmac",
        },
        "$envelope.signed.snapshot",
    )
    expected = {
        "schema_version": COORDINATOR_SOURCE_SNAPSHOT_SCHEMA,
        "producer_contract_version": COORDINATOR_CONTRACT_VERSION,
        "closure_table_schema": "coordinator_source_no_dispatch_closures.v1",
        "db_fence_schema": "coordinator_source_no_dispatch_fence.v1",
        "record_schema": COORDINATOR_NO_DISPATCH_RECORD_SCHEMA,
        "canonicalization": "ascii-jcs-subset-v1",
        "scope_hmac": "hmac-sha256-length-prefixed-v1",
    }
    for key, want in expected.items():
        if snap[key] != want:
            fail(f"$envelope.signed.snapshot.{key}", f"must equal {want}")
    require_ascii(snap["registry_bundle_digest"], "$envelope.signed.snapshot.registry_bundle_digest", pattern=COORDINATOR_REGISTRY_DIGEST_RE, max_len=71)
    if snap["registry_bundle_digest"] != registry_digest:
        fail("$envelope.signed.snapshot.registry_bundle_digest", "must equal sha256 of canonical registry bytes used by verifier")
    return snap


def validate_coordinator_no_dispatch_record(record: Any, path: str, generated_at: _dt.datetime) -> dict[str, Any]:
    rec = exact_keys(
        record,
        {
            "schema_version",
            "source",
            "record_kind",
            "request_scope_commitment",
            "projection_status",
            "terminal_kind",
            "privacy",
            "request_log_summary",
            "settlement_absence",
            "closure",
        },
        path,
    )
    constants = {
        "schema_version": COORDINATOR_NO_DISPATCH_RECORD_SCHEMA,
        "source": "coordinator",
        "record_kind": "no_dispatch_terminal",
        "projection_status": "closed_terminal",
    }
    for key, want in constants.items():
        if rec[key] != want:
            fail(f"{path}.{key}", f"must equal {want}")
    require_ascii(rec["request_scope_commitment"], f"{path}.request_scope_commitment", pattern=HEX64_RE, max_len=64)
    terminal_kind = require_ascii(rec["terminal_kind"], f"{path}.terminal_kind", pattern=re.compile(r"^(model_not_found_no_dispatch|pool_unavailable_no_dispatch)$"), max_len=64)
    validate_coordinator_privacy(rec["privacy"], f"{path}.privacy")
    validate_coordinator_request_log_summary(rec["request_log_summary"], terminal_kind, f"{path}.request_log_summary")
    validate_coordinator_settlement_absence(rec["settlement_absence"], f"{path}.settlement_absence")
    validate_coordinator_closure(rec["closure"], generated_at, f"{path}.closure")
    return rec


def validate_coordinator_privacy(value: Any, path: str) -> None:
    privacy = exact_keys(
        value,
        {
            "raw_account_id_emitted",
            "raw_external_request_id_emitted",
            "raw_internal_request_id_emitted",
            "raw_rejected_model_emitted",
            "request_log_model_blank_for_unserved",
        },
        path,
    )
    false_fields = [
        "raw_account_id_emitted",
        "raw_external_request_id_emitted",
        "raw_internal_request_id_emitted",
        "raw_rejected_model_emitted",
    ]
    for field in false_fields:
        if require_bool(privacy[field], f"{path}.{field}") is not False:
            fail(f"{path}.{field}", "must be false")
    if require_bool(privacy["request_log_model_blank_for_unserved"], f"{path}.request_log_model_blank_for_unserved") is not True:
        fail(f"{path}.request_log_model_blank_for_unserved", "must be true")


def validate_coordinator_request_log_summary(value: Any, terminal_kind: str, path: str) -> None:
    summary = exact_keys(
        value,
        {"count", "status", "attempt_n", "provider_assigned", "error_message_class", "terminal_kind_source"},
        path,
    )
    if require_int(summary["count"], f"{path}.count", 0, 1) != 1:
        fail(f"{path}.count", "must equal 1")
    if require_int(summary["attempt_n"], f"{path}.attempt_n", 0, 0) != 0:
        fail(f"{path}.attempt_n", "must equal 0")
    if require_bool(summary["provider_assigned"], f"{path}.provider_assigned") is not False:
        fail(f"{path}.provider_assigned", "must be false")
    if summary["terminal_kind_source"] != "coordinator_source_no_dispatch_closures.terminal_kind":
        fail(f"{path}.terminal_kind_source", "must name closure terminal_kind source")
    expected_by_kind = {
        "model_not_found_no_dispatch": (404, "no_provider_advertised_requested_model"),
        "pool_unavailable_no_dispatch": (503, "pool_unavailable"),
    }
    want_status, want_error = expected_by_kind[terminal_kind]
    if require_int(summary["status"], f"{path}.status", 100, 599) != want_status:
        fail(f"{path}.status", f"must equal {want_status} for {terminal_kind}")
    if summary["error_message_class"] != want_error:
        fail(f"{path}.error_message_class", f"must equal {want_error} for {terminal_kind}")


def validate_coordinator_settlement_absence(value: Any, path: str) -> None:
    absence = exact_keys(
        value,
        {"fence", "ledger_request_credits", "settlement_route_snapshots", "settlement_attempt_outputs", "settlement_receipt_verdicts"},
        path,
    )
    if absence["fence"] != "sqlite_triggers_no_future_writes_v1":
        fail(f"{path}.fence", "must equal sqlite_triggers_no_future_writes_v1")
    for table in ["ledger_request_credits", "settlement_route_snapshots", "settlement_attempt_outputs", "settlement_receipt_verdicts"]:
        row = exact_keys(absence[table], {"count", "max_id"}, f"{path}.{table}")
        if require_int(row["count"], f"{path}.{table}.count", 0, 0) != 0:
            fail(f"{path}.{table}.count", "must equal 0")
        if require_int(row["max_id"], f"{path}.{table}.max_id", 0, 0) != 0:
            fail(f"{path}.{table}.max_id", "must equal 0")


def validate_coordinator_closure(value: Any, generated_at: _dt.datetime, path: str) -> None:
    closure = exact_keys(value, {"schema_version", "closed_at_utc", "closure_id_hmac"}, path)
    if closure["schema_version"] != COORDINATOR_NO_DISPATCH_CLOSURE_SCHEMA:
        fail(f"{path}.schema_version", f"must equal {COORDINATOR_NO_DISPATCH_CLOSURE_SCHEMA}")
    closed_at = parse_timestamp_ms(require_timestamp_ms(closure["closed_at_utc"], f"{path}.closed_at_utc"))
    if closed_at > generated_at:
        fail(f"{path}.closed_at_utc", "must not be after signed generated_at")
    require_ascii(closure["closure_id_hmac"], f"{path}.closure_id_hmac", pattern=HEX64_RE, max_len=64)


def validate_envelope(envelope: Any, registry: Any, expected: ExpectedExport, *, openssl_bin: str = "openssl") -> dict[str, Any]:
    if expected.now.tzinfo is None or expected.now.utcoffset() is None:
        fail("expected.now", "must be timezone-aware UTC")
    if expected.now.utcoffset() != _dt.timedelta(0):
        fail("expected.now", "must be UTC")
    if expected.max_age_seconds < 1 or expected.max_age_seconds > 86400:
        fail("expected.max_age_seconds", "must be in 1..86400")
    if expected.domain != SIGNATURE_DOMAIN_NAME:
        fail("expected.domain", f"must equal actual signature domain {SIGNATURE_DOMAIN_NAME}")
    keys = validate_registry(registry, now=expected.now)
    registry_digest = "sha256:" + sha256_hex(canonical_bytes(registry))
    env = exact_keys(envelope, {"schema_version", "signed", "signatures"}, "$envelope")
    if env["schema_version"] != ENVELOPE_SCHEMA:
        fail("$envelope.schema_version", f"must equal {ENVELOPE_SCHEMA}")
    signatures = env["signatures"]
    if not isinstance(signatures, list) or len(signatures) != 1:
        fail("$envelope.signatures", "must contain exactly one signature")
    signed = validate_signed(env["signed"], expected)
    signed_bytes = canonical_bytes(signed)
    sig = exact_keys(signatures[0], {"algorithm", "key_id", "signed_sha256", "signature"}, "$envelope.signatures[0]")
    if sig["algorithm"] != "ed25519":
        fail("$envelope.signatures[0].algorithm", "must equal ed25519")
    key_id = require_ascii(sig["key_id"], "$envelope.signatures[0].key_id", pattern=KEY_ID_RE)
    if key_id not in keys:
        fail("$envelope.signatures[0].key_id", "not present in trusted reviewed registry")
    if sig["signed_sha256"] != sha256_hex(signed_bytes):
        fail("$envelope.signatures[0].signed_sha256", "does not match SHA256(JCS(signed))")
    signature = decode_b64url(sig["signature"], "$envelope.signatures[0].signature", 64)
    key = keys[key_id]
    authorize_key(key, signed, expected, key_id)
    verify_ed25519(openssl_bin, decode_b64url(key["public_key"], f"$registry.keys.{key_id}.public_key", 32), SIGNATURE_DOMAIN + signed_bytes, signature)
    projection = validate_typed_projection(signed, registry_digest)
    return {"signed_sha256": sig["signed_sha256"], "key_id": key_id, "record_count": len(signed["records"]), **projection}


def validate_signed(value: Any, expected: ExpectedExport) -> dict[str, Any]:
    signed = exact_keys(
        value,
        {"schema_version", "producer", "role", "instance_id", "source_sha", "export_id", "run_id", "challenge_nonce", "generated_at", "request_scopes", "snapshot", "records"},
        "$envelope.signed",
    )
    if signed["schema_version"] != SIGNED_SCHEMA:
        fail("$envelope.signed.schema_version", f"must equal {SIGNED_SCHEMA}")
    require_ascii(signed["producer"], "$envelope.signed.producer", pattern=PRODUCER_RE)
    require_ascii(signed["role"], "$envelope.signed.role", pattern=ROLE_RE)
    require_ascii(signed["instance_id"], "$envelope.signed.instance_id", pattern=INSTANCE_RE)
    require_ascii(signed["source_sha"], "$envelope.signed.source_sha", pattern=SOURCE_SHA_RE)
    require_ascii(signed["export_id"], "$envelope.signed.export_id", pattern=UUID_RE)
    require_ascii(signed["run_id"], "$envelope.signed.run_id", pattern=INSTANCE_RE)
    decode_b64url(signed["challenge_nonce"], "$envelope.signed.challenge_nonce", 32)
    generated_at = require_timestamp_ms(signed["generated_at"], "$envelope.signed.generated_at")
    scopes = _unique_ascii_array(signed["request_scopes"], "$envelope.signed.request_scopes", HEX64_RE, max_items=MAX_REQUEST_SCOPES)
    if scopes != sorted(scopes):
        fail("$envelope.signed.request_scopes", "must be sorted lexicographically")
    if not isinstance(signed["snapshot"], dict):
        fail("$envelope.signed.snapshot", "must be an object")
    if not isinstance(signed["records"], list):
        fail("$envelope.signed.records", "must be an array")
    if len(signed["records"]) > MAX_RECORDS:
        fail("$envelope.signed.records", f"must have at most {MAX_RECORDS} records")
    _validate_canonical_subset(signed["snapshot"], "$envelope.signed.snapshot")
    for i, record in enumerate(signed["records"]):
        if not isinstance(record, dict):
            fail(f"$envelope.signed.records[{i}]", "must be an object")
        _validate_canonical_subset(record, f"$envelope.signed.records[{i}]")
        if "row_id" in record:
            require_int(record["row_id"], f"$envelope.signed.records[{i}].row_id", 1, MAX_SAFE_INTEGER)
    if signed["producer"] != expected.producer:
        fail("$envelope.signed.producer", "does not match caller-expected producer")
    if signed["role"] != expected.role:
        fail("$envelope.signed.role", "does not match caller-expected role")
    if signed["instance_id"] != expected.instance_id:
        fail("$envelope.signed.instance_id", "does not match caller-expected instance_id")
    if signed["source_sha"] != expected.source_sha:
        fail("$envelope.signed.source_sha", "does not match caller-expected reviewed source_sha")
    if signed["run_id"] != expected.run_id:
        fail("$envelope.signed.run_id", "does not match caller-expected run_id")
    if signed["challenge_nonce"] != expected.challenge_nonce:
        fail("$envelope.signed.challenge_nonce", "does not match caller-expected challenge_nonce")
    age = expected.now - parse_timestamp_ms(generated_at)
    if age.total_seconds() < 0:
        fail("$envelope.signed.generated_at", "must not be in the future")
    if age.total_seconds() > expected.max_age_seconds:
        fail("$envelope.signed.generated_at", "is too old for caller freshness window")
    return signed


def authorize_key(key: dict[str, Any], signed: dict[str, Any], expected: ExpectedExport, key_id: str) -> None:
    generated_at = parse_timestamp_ms(signed["generated_at"])
    not_before = parse_timestamp_ms(key["not_before"])
    not_after = parse_timestamp_ms(key["not_after"])
    if not_before > expected.now:
        fail(f"$registry.keys.{key_id}.not_before", "selected key is not yet valid")
    if not_after <= expected.now:
        fail(f"$registry.keys.{key_id}.not_after", "selected key is expired")
    if key["revoked_at"] is not None and parse_timestamp_ms(key["revoked_at"]) <= expected.now:
        fail(f"$registry.keys.{key_id}.revoked_at", "selected key is revoked")
    if generated_at < not_before or generated_at >= not_after:
        fail("$envelope.signed.generated_at", "must fall within selected key validity window")
    if key["producer"] != signed["producer"]:
        fail(f"$registry.keys.{key_id}.producer", "does not authorize signed producer")
    if key["instance_id"] != signed["instance_id"]:
        fail(f"$registry.keys.{key_id}.instance_id", "does not authorize signed instance_id")
    if signed["role"] not in key["permitted_roles"]:
        fail(f"$registry.keys.{key_id}.permitted_roles", "does not authorize signed role")
    if SIGNATURE_DOMAIN_NAME not in key["permitted_domains"]:
        fail(f"$registry.keys.{key_id}.permitted_domains", "does not authorize actual signature domain")
    if signed["source_sha"] not in key["reviewed_source_constraints"]["source_sha_allowlist"]:
        fail(f"$registry.keys.{key_id}.reviewed_source_constraints.source_sha_allowlist", "does not authorize signed source_sha")


def verify_ed25519(openssl_bin: str, public_key: bytes, message: bytes, signature: bytes) -> None:
    with tempfile.TemporaryDirectory(prefix="macprovider-source-ed25519.") as tmp:
        root = pathlib.Path(tmp)
        pub = root / "public.der"
        msg = root / "message.bin"
        sig = root / "signature.bin"
        pub.write_bytes(ED25519_SPKI_DER_PREFIX + public_key)
        msg.write_bytes(message)
        sig.write_bytes(signature)
        try:
            result = subprocess.run(
                [openssl_bin, "pkeyutl", "-verify", "-pubin", "-keyform", "DER", "-inkey", str(pub), "-rawin", "-sigfile", str(sig), "-in", str(msg)],
                stdout=subprocess.PIPE,
                stderr=subprocess.PIPE,
                text=True,
                check=False,
            )
        except FileNotFoundError:
            fail("openssl", f"executable not found: {openssl_bin}")
    if result.returncode != 0:
        fail("$envelope.signatures[0].signature", "Ed25519 verification failed")


def _default_registry_path() -> pathlib.Path:
    return pathlib.Path(__file__).resolve().parents[1] / "schemas" / "source-evidence-key-registry-v1.json"


def _parse_now(value: str | None) -> _dt.datetime:
    if value is None:
        return _dt.datetime.now(tz=_dt.timezone.utc)
    require_timestamp_ms(value, "--now")
    return parse_timestamp_ms(value)


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("envelope", type=pathlib.Path)
    parser.add_argument("--producer", required=True, choices=["gateway", "coordinator"])
    parser.add_argument("--role", required=True)
    parser.add_argument("--instance-id", required=True)
    parser.add_argument("--source-sha", required=True)
    parser.add_argument("--run-id", required=True)
    parser.add_argument("--challenge-nonce", required=True)
    parser.add_argument("--domain", default=SIGNATURE_DOMAIN_NAME, choices=[SIGNATURE_DOMAIN_NAME], help="semantic domain bound to the export signature bytes")
    parser.add_argument("--now", help="UTC millisecond timestamp for deterministic validation")
    parser.add_argument("--max-age-seconds", type=int, default=300)
    parser.add_argument("--openssl", default=os.environ.get("OPENSSL_BIN", "openssl"))
    args = parser.parse_args(argv)
    try:
        expected = ExpectedExport(
            producer=require_ascii(args.producer, "--producer", pattern=PRODUCER_RE),
            role=require_ascii(args.role, "--role", pattern=ROLE_RE),
            instance_id=require_ascii(args.instance_id, "--instance-id", pattern=INSTANCE_RE),
            source_sha=require_ascii(args.source_sha, "--source-sha", pattern=SOURCE_SHA_RE),
            run_id=require_ascii(args.run_id, "--run-id", pattern=INSTANCE_RE),
            challenge_nonce=args.challenge_nonce,
            domain=args.domain,
            now=_parse_now(args.now),
            max_age_seconds=require_int(args.max_age_seconds, "--max-age-seconds", 1, 86400),
        )
        registry_path = _default_registry_path()
        registry = load_json_file(registry_path, "$registry")
        envelope = load_json_file(args.envelope, "$envelope")
        result = validate_envelope(envelope, registry, expected, openssl_bin=args.openssl)
    except (EvidenceError, OSError) as exc:
        print(f"source_authenticated_evidence: {exc}", file=sys.stderr)
        return 2
    print(json.dumps({"ok": True, **result}, sort_keys=True))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
