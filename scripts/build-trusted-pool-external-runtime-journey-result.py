#!/usr/bin/env python3
"""Build the JOURNEY-TRUSTED-POOL-EXTERNAL-RUNTIME redacted evidence and journey-result payload.

`capture` reads an operator capture directory (layout in
journeys/JOURNEY-TRUSTED-POOL-EXTERNAL-RUNTIME.md), checks every physical step,
and writes the redacted evidence. It never copies a prompt, completion, key,
or raw account/provider id into its output. `payload` turns committed redacted
evidence into the unsigned journey-result payload the signing workflow signs.
"""

from __future__ import annotations

import argparse
import hashlib
import hmac
import json
import os
import re
import secrets
import subprocess
import sys
import tempfile
from copy import deepcopy
from datetime import date
from pathlib import Path
from typing import Any

from check_spec_governance import (
    DuplicateJSONKeyError,
    JOURNEY_RESULT_PAYLOAD_SCHEMA,
    TRUSTED_POOL_EXTERNAL_RUNTIME_ARTIFACT_ID,
    TRUSTED_POOL_EXTERNAL_RUNTIME_CANDIDATE_IDENTITY_KEYS,
    TRUSTED_POOL_EXTERNAL_RUNTIME_EXECUTION_MODE,
    TRUSTED_POOL_EXTERNAL_RUNTIME_JOURNEY_ID,
    TRUSTED_POOL_EXTERNAL_RUNTIME_OBSERVATION_KEYS,
    TRUSTED_POOL_EXTERNAL_RUNTIME_PROMOTABLE_REQUIREMENT_IDS,
    TRUSTED_POOL_EXTERNAL_RUNTIME_STEP_ID_ORDER,
    ValidationResult,
    _load_json,
    _unique_json_object,
)


EVIDENCE_SCHEMA = "macprovider.trusted-pool-external-runtime-evidence.v1"
JOURNEY_ID = "JOURNEY-TRUSTED-POOL-EXTERNAL-RUNTIME"
REPOSITORY = "Augustas11/macprovider"
ARTIFACT_ID = "redacted-trusted-pool-external-runtime"
EVIDENCE_PREFIX = "journeys/evidence/trusted-pool-external-runtime-"
RUNTIME_SOURCE = "llamacpp_loopback"
GGUF_HASH_ALGORITHM = "macprovider.gguf-file.v1"
POOL_OPERATOR_ATTESTED = "pool_operator_attested"
REQUIREMENT_RE = re.compile(r"^SPEC-[0-9]{3}-R[0-9]{3}$")
COMMIT_RE = re.compile(r"^[0-9a-f]{40}$")
SHA256_RE = re.compile(r"^[0-9a-f]{64}$")
DATETIME_Z_RE = re.compile(r"^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z$")
DATE_RE = re.compile(r"^[0-9]{4}-[0-9]{2}-[0-9]{2}$")
# preconditions.*.observed is structured, never free text: an object of at
# most 8 named facts. A name is a short snake_case word that names no
# credential; a value is a boolean, a non-negative integer, or a short token
# (a version, a build id, a short commit) with no whitespace, so no prompt,
# completion or sentence fits. A token that is a long hex/base64 run (a raw
# key, digest or credential) is refused: an identity belongs in run.json and
# reaches evidence only as a salted fingerprint.
OBSERVED_MAX_FIELDS = 8
OBSERVED_NAME_RE = re.compile(r"^[a-z][a-z0-9_]{0,31}$")
OBSERVED_TOKEN_RE = re.compile(r"^[A-Za-z0-9][A-Za-z0-9._:+-]{0,63}$")
OBSERVED_CREDENTIAL_NAME_RE = re.compile(r"(key|token|secret|bearer|password|passwd|auth|cookie|credential|private|signature)")
# The run class covers every character a token may hold (including "." and
# ":"), so this measures the whole token: at most 19 characters.
OBSERVED_LONG_RUN_RE = re.compile(r"[A-Za-z0-9+/=_.:-]{20,}")
# Integers stay exactly representable in every JSON consumer.
OBSERVED_MAX_INT = 2**53
# run.json identity fields; evidence carries them only as salted
# fingerprints, never by name or value.
RAW_IDENTITY_FIELDS = ("member_provider_id", "buyer_account_id", "pool_operator_account_id", "operator_identity")
RUN_ID_RE = re.compile(r"^trusted-pool-external-runtime-[0-9]{8}T[0-9]{6}Z$")
ACCEPTED_ID_RE = re.compile(r"^Augustas11/macprovider:v[0-9]+\.[0-9]+\.[0-9]+@[0-9a-f]{7,40}$")
# Free-form run.json descriptors that reach signed evidence: a Hugging
# Face-style repo id, and short lowercase snake/kebab tokens.
MODEL_ID_RE = re.compile(r"^[A-Za-z0-9][A-Za-z0-9._-]{0,95}/[A-Za-z0-9][A-Za-z0-9._-]{0,95}$")
SHORT_TOKEN_RE = re.compile(r"^(?=.{1,48}$)[a-z0-9]+(?:[_-][a-z0-9]+)*$")
PRECONDITION_IDS = ("P1", "P2", "P3", "P4", "P5", "P6", "P7", "P8", "payout-disabled")
REQUEST_KINDS = ("nonstream", "stream")
# name -> (HTTP status, error.code); run plan §5A negative controls.
NEGATIVE_CONTROLS = {
    "no-pool-selector": (503, "engine_unavailable"),
    "no-selector-no-pool": (503, "byom_non_settlement_unavailable"),
    "pool-ollama-selector": (503, "engine_unavailable"),
    "uppercase-selector": (400, "invalid_engine_selection"),
}
STEP_ASSERTIONS = {
    "step-01-preconditions": "P1-P8 and payout-disabled pass on the deployed build",
    "step-02-pool-policy": "pool active and routeable, candidate, one undelegated member, buyer authorized, manifest digest bound",
    "step-03-nonstream-request": "non-streaming 200 served by llamacpp_loopback on the pool member",
    "step-04-stream-request": "streaming 200 served by llamacpp_loopback, finish_reason and [DONE]",
    "step-05-route-snapshots": "route snapshots carry pool, manifest, runtime_source, enforce mode and the GGUF identity",
    "step-06-receipts-and-attempts": "pool_operator_attested attempt output and a closed verified v4 receipt verdict",
    "step-07-ledger-and-finality": "one payable enforce ledger credit to the member and closed verified finality",
    "step-08-gateway-debit": "settled reservation with no hold; debit equals finality equals ledger tokens",
    "step-09-negative-controls": "four controls fail closed with zero route snapshots and zero ledger rows",
    "step-10-gateway-holds": "zero held reservations and zero missing-trailer logs before and after",
    "step-11-redaction": "prompts, completions, keys and raw account ids absent; secret scan passes",
}
FORBIDDEN_KEY_FRAGMENTS = (
    "authorization_header",
    "bearer_token",
    "private_key",
    "raw_secret",
    "raw_signature",
    "raw_token",
    "secret_key",
    "wallet_private",
)
FORBIDDEN_SECRET_VALUE_PATTERNS = (
    re.compile(r"-----BEGIN [A-Z0-9 ]*PRIVATE KEY-----"),
    re.compile(r"(?i)\bauthorization\s*:\s*bearer\s+(?!redacted\b)[A-Za-z0-9._~+/=-]{8,}"),
    re.compile(r"(?i)\bbearer\s+(?!redacted\b)[A-Za-z0-9._~+/=-]{20,}"),
    re.compile(r"\bghp_[A-Za-z0-9_]{20,}\b"),
    re.compile(r"\bgithub_pat_[A-Za-z0-9_]{20,}\b"),
    re.compile(r"\bsk-[A-Za-z0-9]{20,}\b"),
    re.compile(r"\bxox[baprs]-[A-Za-z0-9-]{20,}\b"),
    re.compile(r"\bAKIA[0-9A-Z]{16}\b"),
    re.compile(r"\bmp_[A-Za-z0-9_-]{16,}\b"),
)


def die(message: str) -> None:
    print(f"build-trusted-pool-external-runtime-journey-result: {message}", file=sys.stderr)
    raise SystemExit(1)


def sha256_hex(data: bytes) -> str:
    return hashlib.sha256(data).hexdigest()


def fingerprint(value: str, salt: str) -> str:
    """HMAC-SHA256 of an account/provider id keyed by the run's salt.

    The salt is random per evidence build and recorded (non-secret) in
    candidate_identity.fingerprint_salt, so a fingerprint still binds the id
    for anyone who knows it, but a bare sha256 dictionary over known ids no
    longer links runs or reverses the fingerprint.
    """
    return hmac.new(bytes.fromhex(salt), value.encode("utf-8"), hashlib.sha256).hexdigest()


def parse_json_bytes(payload: bytes, label: str) -> Any:
    try:
        return json.loads(payload.decode("utf-8"), object_pairs_hook=_unique_json_object)
    except DuplicateJSONKeyError as exc:
        die(f"{label}: duplicate JSON object key {exc.args[0]!r}")
    except (UnicodeDecodeError, json.JSONDecodeError) as exc:
        die(f"{label}: {exc}")


def read_capture_file(capture: Path, relative: str) -> bytes:
    path = capture / relative
    # No component inside the capture (a subdirectory or the file) may be a
    # symlink, whoever owns it.
    current = capture
    for part in Path(relative).parts:
        current = current / part
        if current.is_symlink():
            die(f"capture file is absent or unsafe: {relative}")
    if not path.is_file():
        die(f"capture file is absent or unsafe: {relative}")
    return path.read_bytes()


def load_capture_object(capture: Path, relative: str) -> dict[str, Any]:
    value = parse_json_bytes(read_capture_file(capture, relative), relative)
    if not isinstance(value, dict):
        die(f"{relative} must be a JSON object")
    return value


def load_capture_rows(capture: Path, relative: str) -> list[dict[str, Any]]:
    """`sqlite3 -json` output: a JSON array of objects, or nothing for no rows."""
    payload = read_capture_file(capture, relative)
    if not payload.strip():
        return []
    value = parse_json_bytes(payload, relative)
    if not isinstance(value, list) or not all(isinstance(row, dict) for row in value):
        die(f"{relative} must be a JSON array of row objects")
    return value


def parse_headers(payload: bytes, label: str) -> tuple[int, dict[str, str]]:
    """Parse `curl -D` output; the last response block wins (skips 1xx)."""
    text = payload.decode("iso-8859-1").replace("\r\n", "\n")
    blocks = [block for block in text.split("\n\n") if block.strip().startswith("HTTP/")]
    if not blocks:
        die(f"{label}: no HTTP status line")
    lines = blocks[-1].strip().split("\n")
    match = re.match(r"^HTTP/[0-9.]+ ([0-9]{3})", lines[0])
    if not match:
        die(f"{label}: malformed status line")
    headers: dict[str, str] = {}
    for line in lines[1:]:
        name, sep, value = line.partition(":")
        if not sep:
            die(f"{label}: malformed header line")
        headers[name.strip().lower()] = value.strip()
    return int(match.group(1)), headers


def require(condition: bool, message: str) -> None:
    if not condition:
        die(message)


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


def as_int(value: Any, location: str) -> int:
    if isinstance(value, bool) or not isinstance(value, int):
        if isinstance(value, str) and re.fullmatch(r"-?[0-9]+", value):
            return int(value)
        die(f"{location} must be an integer")
    return value


def load_run(capture: Path) -> dict[str, Any]:
    run = load_capture_object(capture, "run.json")
    fields = {
        "run_id": RUN_ID_RE,
        "captured_at": DATETIME_Z_RE,
        "expires_at": DATE_RE,
        "source_commit": COMMIT_RE,
        "coordinator_version": re.compile(r"^v[0-9]+\.[0-9]+\.[0-9]+$"),
        "accepted_id": ACCEPTED_ID_RE,
        "member_cli_sha256": SHA256_RE,
        "llama_server_build": re.compile(r"^b[0-9]+$"),
        "gguf_sha256": SHA256_RE,
        "gguf_artifact_id": re.compile(r"^gguf-[a-z0-9-]+$"),
        "model_id": MODEL_ID_RE,
        "operator_role": SHORT_TOKEN_RE,
        "operator_identity": None,
        "hardware_profile": SHORT_TOKEN_RE,
        "pool_id": None,
        "member_provider_id": None,
        "buyer_account_id": None,
        "pool_operator_account_id": None,
    }
    extra = set(run) - set(fields)
    require(not extra, f"run.json has unexpected keys: {sorted(extra)}")
    for field, pattern in fields.items():
        require_string(run.get(field), pattern, f"run.json.{field}")
    return run


def check_preconditions(capture: Path) -> dict[str, Any]:
    raw = load_capture_object(capture, "preconditions.json")
    require(set(raw) == set(PRECONDITION_IDS), f"preconditions.json must name exactly {list(PRECONDITION_IDS)}")
    out: dict[str, Any] = {}
    for key in PRECONDITION_IDS:
        item = require_object(raw[key], f"preconditions.{key}")
        require(set(item) == {"status", "observed", "checked_at"}, f"preconditions.{key} must have status, observed, checked_at")
        require(item["status"] == "pass", f"preconditions.{key}.status must equal 'pass'")
        require_observed_facts(item["observed"], f"preconditions.{key}.observed")
        require_string(item["checked_at"], DATETIME_Z_RE, f"preconditions.{key}.checked_at")
        out[key] = {"status": "pass", "observed": item["observed"], "checked_at": item["checked_at"]}
    return out


def require_observed_facts(value: Any, location: str) -> None:
    if not isinstance(value, dict) or not 1 <= len(value) <= OBSERVED_MAX_FIELDS:
        die(f"{location} must be an object of 1-{OBSERVED_MAX_FIELDS} named facts, not free text")
    for name, fact in value.items():
        if not OBSERVED_NAME_RE.fullmatch(name) or OBSERVED_CREDENTIAL_NAME_RE.search(name):
            die(f"{location}: fact name {name!r} is not an allowed snake_case name")
        if isinstance(fact, bool):
            continue
        if isinstance(fact, int):
            if fact < 0 or fact > OBSERVED_MAX_INT:
                die(f"{location}.{name} must be an integer in [0, 2^53]")
            continue
        if not isinstance(fact, str) or not OBSERVED_TOKEN_RE.fullmatch(fact) or OBSERVED_LONG_RUN_RE.search(fact):
            die(f"{location}.{name} must be a boolean, a non-negative integer, or a short token (no long hex/base64 run)")


def require_no_symlink_components(path: Path, label: str) -> None:
    """Refuse a capture path with a symlink anywhere in it.

    Every component of the absolute path is checked, not just the leaf. A
    root-owned symlink (the OS's own, such as macOS /var and /tmp) is
    allowed; any other symlink could redirect the build to files the
    operator did not capture.
    """
    current = Path(os.path.abspath(path))
    for candidate in [current, *current.parents]:
        if candidate.is_symlink() and candidate.lstat().st_uid != 0:
            die(f"{label} has a symlinked path component: {candidate}")


def check_pool(capture: Path, run: dict[str, Any]) -> dict[str, Any]:
    pool = require_object(load_capture_object(capture, "pool/get-pool.json").get("pool"), "get-pool.pool")
    member, buyer = run["member_provider_id"], run["buyer_account_id"]
    require(pool.get("pool_id") == run["pool_id"], "get-pool pool_id must equal run.json pool_id")
    require(pool.get("lifecycle") == "active", "get-pool lifecycle must be 'active'")
    require(pool.get("routeable") is True, "get-pool routeable must be true")
    require(pool.get("launch_environment") == "candidate", "get-pool launch_environment must be 'candidate'")
    require(pool.get("creator_account_id") == run["pool_operator_account_id"], "get-pool creator_account_id must equal the pool operator account")
    require(pool.get("members") == [member], "get-pool members must be exactly the M1 member")
    require(pool.get("revoked") in ([], None), "get-pool revoked must be empty")
    buyers = pool.get("buyer_accounts")
    require(isinstance(buyers, list) and buyer in buyers, "get-pool buyer_accounts must include the buyer")
    manifest_version = as_int(pool.get("manifest_version"), "get-pool manifest_version")
    require(manifest_version >= 1, "get-pool manifest_version must be at least 1")
    digest = require_string(pool.get("manifest_core_digest"), SHA256_RE, "get-pool manifest_core_digest")
    manifest = load_capture_object(capture, "pool/manifest-accepted.json")
    require(manifest.get("event_type") == "manifest_accepted", "manifest-accepted.json must be a manifest_accepted event")
    require(manifest.get("pool_id") == run["pool_id"], "manifest-accepted.json pool_id must equal run.json pool_id")
    require(manifest.get("manifest_core_digest") == digest, "the submitted manifest digest must equal get-pool manifest_core_digest")
    require(as_int(manifest.get("manifest_version"), "manifest-accepted.json manifest_version") == manifest_version,
            "the submitted manifest version must equal get-pool manifest_version")
    counts: dict[str, int] = {}
    for row in load_capture_rows(capture, "pool/trustpool-events.json"):
        event_type = require_string(row.get("event_type"), None, "trustpool-events.event_type")
        require(event_type not in counts, f"trustpool-events repeats {event_type}")
        counts[event_type] = as_int(row.get("n"), f"trustpool-events.{event_type}.n")
    for event_type, want in (("pool_created", 1), ("root_issuer_registered", 1)):
        require(counts.get(event_type) == want, f"pool history must have exactly {want} {event_type}")
    for event_type in ("manifest_accepted", "member_admitted", "buyer_authorized"):
        require(counts.get(event_type, 0) >= 1, f"pool history must have a {event_type} event")
    require(counts.get("delegation_granted", 0) == 0, "a delegated member cannot be pool_operator_attested")
    return {
        "pool_id": run["pool_id"],
        "lifecycle": "active",
        "routeable": True,
        "launch_environment": "candidate",
        "manifest_version": manifest_version,
        "manifest_core_digest": digest,
        "creator_account_fingerprint": fingerprint(run["pool_operator_account_id"], run["fingerprint_salt"]),
        "member_fingerprints": [fingerprint(member, run["fingerprint_salt"])],
        "buyer_authorized": True,
        "event_counts": dict(sorted(counts.items())),
    }


def check_response(capture: Path, kind: str, run: dict[str, Any]) -> dict[str, Any]:
    base = f"requests/{kind}"
    status, headers = parse_headers(read_capture_file(capture, f"{base}/response.headers"), f"{base}/response.headers")
    require(status == 200, f"{kind} response status must be 200")
    require(headers.get("x-macprovider-engine") == RUNTIME_SOURCE, f"{kind} X-MacProvider-Engine must be {RUNTIME_SOURCE}")
    request_id = require_string(headers.get("x-request-id"), None, f"{kind} X-Request-ID")
    require(headers.get("x-provider-id") == run["member_provider_id"], f"{kind} X-Provider-Id must be the pool member")
    if kind == "nonstream":
        body = read_capture_file(capture, f"{base}/response.json")
        doc = require_object(parse_json_bytes(body, f"{base}/response.json"), f"{kind} body")
        choices = doc.get("choices")
        require(isinstance(choices, list) and choices, f"{kind} body must have choices")
        message = require_object(require_object(choices[0], f"{kind} choices[0]").get("message"), f"{kind} message")
        content = message.get("content") if isinstance(message.get("content"), str) else ""
        finish_reason = choices[0].get("finish_reason")
        usage = require_object(doc.get("usage"), f"{kind} usage")
        stream_done = None
    else:
        body = read_capture_file(capture, f"{base}/response.sse")
        data_lines = [
            line[len("data:"):].strip()
            for line in body.decode("utf-8").replace("\r\n", "\n").split("\n")
            if line.startswith("data:")
        ]
        require(data_lines and data_lines[-1] == "[DONE]", f"{kind} stream must end with data: [DONE]")
        parts: list[str] = []
        finish_reason = None
        usage = None
        for index, raw in enumerate(data_lines[:-1]):
            chunk = require_object(parse_json_bytes(raw.encode("utf-8"), f"{kind} chunk {index}"), f"{kind} chunk {index}")
            for choice in chunk.get("choices") or []:
                if not isinstance(choice, dict):
                    continue
                delta = choice.get("delta") if isinstance(choice.get("delta"), dict) else {}
                if isinstance(delta.get("content"), str):
                    parts.append(delta["content"])
                if choice.get("finish_reason"):
                    finish_reason = choice["finish_reason"]
            if isinstance(chunk.get("usage"), dict):
                usage = chunk["usage"]
        require(usage is not None, f"{kind} stream must carry a usage chunk")
        content = "".join(parts)
        stream_done = True
    require(isinstance(finish_reason, str) and finish_reason, f"{kind} must carry a finish_reason")
    out = {
        "status": 200,
        "engine": RUNTIME_SOURCE,
        "request_id": request_id,
        "provider_fingerprint": fingerprint(run["member_provider_id"], run["fingerprint_salt"]),
        "finish_reason": finish_reason,
        "buyer_visible_usage": {
            "prompt_tokens": as_int(usage.get("prompt_tokens"), f"{kind} usage.prompt_tokens"),
            "completion_tokens": as_int(usage.get("completion_tokens"), f"{kind} usage.completion_tokens"),
        },
        "content_sha256": sha256_hex(content.encode("utf-8")),
        "body_sha256": sha256_hex(body),
    }
    if stream_done is not None:
        out["stream_done"] = True
    return out


def check_settlement(capture: Path, kind: str, run: dict[str, Any], pool: dict[str, Any]) -> dict[str, Any]:
    base = f"requests/{kind}"
    request_log = load_capture_rows(capture, f"{base}/request_log.json")
    require(any(row.get("pool_id") == run["pool_id"] for row in request_log), f"{kind} request_log must show the pool")
    snapshots = load_capture_rows(capture, f"{base}/route_snapshots.json")
    require(snapshots, f"{kind} must have route snapshots")
    for row in snapshots:
        where = f"{kind} route snapshot attempt {row.get('attempt_n')}"
        require(row.get("pool_id") == run["pool_id"], f"{where}: pool_id must be the pool")
        require(row.get("runtime_source") == RUNTIME_SOURCE, f"{where}: runtime_source must be {RUNTIME_SOURCE}")
        require(as_int(row.get("manifest_version"), f"{where}.manifest_version") == pool["manifest_version"], f"{where}: manifest_version must match get-pool")
        require(row.get("manifest_core_digest") == pool["manifest_core_digest"], f"{where}: manifest_core_digest must match get-pool")
        require(row.get("pool_operator_account_id") == run["pool_operator_account_id"], f"{where}: pool_operator_account_id must be the pool operator")
        require(row.get("route_snapshot_mode") == "enforce", f"{where}: route_snapshot_mode must be enforce")
        require(row.get("expected_catalog_model_hash") == run["gguf_sha256"], f"{where}: expected_catalog_model_hash must be the GGUF sha256")
        require(row.get("artifact_hash") == run["gguf_sha256"], f"{where}: artifact_hash must be the GGUF sha256")
        require(row.get("artifact_id") == run["gguf_artifact_id"], f"{where}: artifact_id must be {run['gguf_artifact_id']}")
        as_int(row.get("pool_generation"), f"{where}.pool_generation")

    outputs = load_capture_rows(capture, f"{base}/attempt_outputs.json")
    attested = [
        row for row in outputs
        if row.get("usage_source") == POOL_OPERATOR_ATTESTED and row.get("terminal_state") == "normal_done"
    ]
    require(len(attested) == 1, f"{kind} must have exactly one pool_operator_attested normal_done attempt output")
    settled_key = (attested[0].get("request_id"), as_int(attested[0].get("attempt_n"), f"{kind} attempt_n"))
    verdicts = [
        row for row in load_capture_rows(capture, f"{base}/receipt_verdicts.json")
        if (row.get("request_id"), as_int(row.get("attempt_n"), f"{kind} verdict attempt_n")) == settled_key
    ]
    require(len(verdicts) == 1, f"{kind} settled attempt must have exactly one receipt verdict")
    verdict = verdicts[0]
    for field, want in (
        ("receipt_version", 4),
        ("receipt_result", "valid"),
        ("settlement_outcome", "verified"),
        ("reason", "verified_settlement"),
        ("pool_label_status", "verified"),
        ("closed", 1),
    ):
        got = verdict.get(field)
        if isinstance(want, int):
            got = as_int(got, f"{kind} verdict.{field}")
        require(got == want, f"{kind} receipt verdict {field} must be {want!r}")

    ledger = load_capture_rows(capture, f"{base}/ledger.json")
    payable = [row for row in ledger if as_int(row.get("payable"), f"{kind} ledger.payable") == 1]
    require(len(payable) == 1, f"{kind} must have exactly one payable ledger row")
    credit = payable[0]
    require(credit.get("provider_id") == run["member_provider_id"], f"{kind} ledger provider must be the member")
    require(as_int(credit.get("provider_credits"), f"{kind} ledger.provider_credits") > 0, f"{kind} ledger provider_credits must be positive")
    require(as_int(credit.get("quarantined"), f"{kind} ledger.quarantined") == 0, f"{kind} ledger row must not be quarantined")
    require(credit.get("settlement_policy_mode") == "enforce", f"{kind} ledger settlement_policy_mode must be enforce")
    require(credit.get("usage_source") == POOL_OPERATOR_ATTESTED, f"{kind} ledger usage_source must be {POOL_OPERATOR_ATTESTED}")
    ledger_tokens = (
        as_int(credit.get("charged_prompt_tokens"), f"{kind} ledger.charged_prompt_tokens"),
        as_int(credit.get("completion_tokens"), f"{kind} ledger.completion_tokens"),
    )

    finality = load_capture_object(capture, f"{base}/finality.json")
    require(finality.get("closed") is True, f"{kind} finality must be closed")
    require(finality.get("outcome") == "verified", f"{kind} finality outcome must be verified")
    require(finality.get("token_source") == POOL_OPERATOR_ATTESTED, f"{kind} finality token_source must be {POOL_OPERATOR_ATTESTED}")
    finality_tokens = (
        as_int(finality.get("prompt_tokens"), f"{kind} finality.prompt_tokens"),
        as_int(finality.get("completion_tokens"), f"{kind} finality.completion_tokens"),
    )

    reservations = load_capture_rows(capture, f"{base}/quota_reservations.json")
    require(len(reservations) == 1, f"{kind} must have exactly one gateway reservation")
    require(reservations[0].get("status") == "settled", f"{kind} reservation must be settled")
    require(as_int(reservations[0].get("settlement_hold"), f"{kind} settlement_hold") == 0, f"{kind} reservation must not be held")
    events = load_capture_rows(capture, f"{base}/usage_events.json")
    require(len(events) == 1, f"{kind} must have exactly one gateway usage event")
    require(events[0].get("token_source") == POOL_OPERATOR_ATTESTED, f"{kind} usage event token_source must be {POOL_OPERATOR_ATTESTED}")
    debit_tokens = (
        as_int(events[0].get("prompt_tokens"), f"{kind} usage_events.prompt_tokens"),
        as_int(events[0].get("completion_tokens"), f"{kind} usage_events.completion_tokens"),
    )
    require(debit_tokens == finality_tokens == ledger_tokens,
            f"{kind} debit {debit_tokens}, finality {finality_tokens} and ledger {ledger_tokens} tokens must be equal")
    return {
        "coordinator_request_ids": sorted({str(row.get("request_id")) for row in request_log}),
        "route_snapshot_count": len(snapshots),
        "runtime_source": RUNTIME_SOURCE,
        "route_snapshot_mode": "enforce",
        "pool_generation": as_int(snapshots[-1].get("pool_generation"), f"{kind} pool_generation"),
        "settled_attempt_n": settled_key[1],
        "usage_source": POOL_OPERATOR_ATTESTED,
        "receipt_verdict": {
            "receipt_version": 4,
            "receipt_result": "valid",
            "settlement_outcome": "verified",
            "reason": "verified_settlement",
            "pool_label_status": "verified",
            "closed": True,
        },
        "ledger": {
            "payable_rows": 1,
            "provider_fingerprint": fingerprint(run["member_provider_id"], run["fingerprint_salt"]),
            "provider_credits": as_int(credit.get("provider_credits"), f"{kind} ledger.provider_credits"),
            "settlement_policy_mode": "enforce",
        },
        "finality": {"closed": True, "outcome": "verified", "token_source": POOL_OPERATOR_ATTESTED},
        "gateway": {"reservation_status": "settled", "settlement_hold": 0, "token_source": POOL_OPERATOR_ATTESTED},
        "debited_tokens": {"prompt_tokens": debit_tokens[0], "completion_tokens": debit_tokens[1]},
    }


def check_controls(capture: Path) -> dict[str, Any]:
    out: dict[str, Any] = {}
    for name, (want_status, want_code) in NEGATIVE_CONTROLS.items():
        base = f"controls/{name}"
        status, _ = parse_headers(read_capture_file(capture, f"{base}/response.headers"), f"{base}/response.headers")
        require(status == want_status, f"control {name} status must be {want_status}, got {status}")
        body = require_object(parse_json_bytes(read_capture_file(capture, f"{base}/response.json"), f"{base}/response.json"), f"{name} body")
        code = require_object(body.get("error"), f"control {name} error").get("code")
        require(code == want_code, f"control {name} error.code must be {want_code}, got {code!r}")
        require(load_capture_rows(capture, f"{base}/route_snapshots.json") == [], f"control {name} must leave no route snapshot")
        require(load_capture_rows(capture, f"{base}/ledger.json") == [], f"control {name} must leave no ledger row")
        out[name] = {"status": want_status, "error_code": want_code, "route_snapshots": 0, "ledger_rows": 0}
    return out


def check_holds(capture: Path) -> dict[str, Any]:
    raw = load_capture_object(capture, "gateway-holds.json")
    require(set(raw) == {"before", "after"}, "gateway-holds.json must have before and after")
    out: dict[str, Any] = {}
    for phase in ("before", "after"):
        item = require_object(raw[phase], f"gateway-holds.{phase}")
        require(set(item) == {"held_reservations", "missing_trailer_log_count"}, f"gateway-holds.{phase} keys")
        for field in ("held_reservations", "missing_trailer_log_count"):
            require(as_int(item[field], f"gateway-holds.{phase}.{field}") == 0, f"gateway-holds.{phase}.{field} must be 0")
        out[phase] = {"held_reservations": 0, "missing_trailer_log_count": 0}
    return out


def reject_forbidden_secret_keys(value: Any, location: str = "$") -> None:
    if isinstance(value, dict):
        for key, item in value.items():
            lowered = key.lower()
            if any(fragment in lowered for fragment in FORBIDDEN_KEY_FRAGMENTS):
                if not (lowered.endswith("_redacted") and item is True):
                    die(f"{location}.{key} uses a forbidden secret-bearing field name")
            reject_forbidden_secret_keys(item, f"{location}.{key}")
    elif isinstance(value, list):
        for index, item in enumerate(value):
            reject_forbidden_secret_keys(item, f"{location}[{index}]")
    elif isinstance(value, str):
        if any(pattern.search(value) for pattern in FORBIDDEN_SECRET_VALUE_PATTERNS):
            die(f"{location} contains a forbidden secret-like value")


def require_fingerprints_only(value: Any, location: str = "$") -> None:
    """Identity-bearing evidence fields hold 64-hex salted fingerprints only,
    and no run.json identity field appears by name."""
    if isinstance(value, dict):
        for key, item in value.items():
            if key in RAW_IDENTITY_FIELDS:
                die(f"{location}.{key}: a raw identity field in redacted evidence")
            if key.endswith("_fingerprint"):
                require_string(item, SHA256_RE, f"{location}.{key}")
            elif key.endswith("_fingerprints"):
                if not isinstance(item, list) or not item:
                    die(f"{location}.{key} must be a non-empty list of fingerprints")
                for index, entry in enumerate(item):
                    require_string(entry, SHA256_RE, f"{location}.{key}[{index}]")
            else:
                require_fingerprints_only(item, f"{location}.{key}")
    elif isinstance(value, list):
        for index, item in enumerate(value):
            require_fingerprints_only(item, f"{location}[{index}]")


def require_run_descriptors(evidence: dict[str, Any]) -> None:
    """The free-form run.json descriptors that reach signed evidence keep
    their capture-time patterns in the committed evidence too."""
    identity = require_object(evidence.get("candidate_identity"), "candidate_identity")
    require_string(identity.get("model_id"), MODEL_ID_RE, "candidate_identity.model_id")
    operator = require_object(evidence.get("operator"), "operator")
    require_string(operator.get("role"), SHORT_TOKEN_RE, "operator.role")
    environment = require_object(evidence.get("environment"), "environment")
    require_string(environment.get("hardware_profile"), SHORT_TOKEN_RE, "environment.hardware_profile")


def revalidate_committed_evidence(evidence: dict[str, Any]) -> None:
    """The payload step signs committed evidence, which may not have come
    through `capture` unchanged: re-run the capture-time redaction checks
    that need no raw capture (observed facts, fingerprints-only identity)."""
    preconditions = require_object(evidence.get("preconditions"), "preconditions")
    require(set(preconditions) == set(PRECONDITION_IDS), f"preconditions must name exactly {list(PRECONDITION_IDS)}")
    for key in PRECONDITION_IDS:
        item = require_object(preconditions[key], f"preconditions.{key}")
        require(set(item) == {"status", "observed", "checked_at"}, f"preconditions.{key} must have status, observed, checked_at")
        require(item["status"] == "pass", f"preconditions.{key}.status must equal 'pass'")
        require_observed_facts(item["observed"], f"preconditions.{key}.observed")
        require_string(item["checked_at"], DATETIME_Z_RE, f"preconditions.{key}.checked_at")
    require_fingerprints_only(evidence)
    require_run_descriptors(evidence)


def reject_raw_identifiers(evidence: dict[str, Any], run: dict[str, Any]) -> None:
    """Account and provider ids appear only as fingerprints in the output."""
    text = json.dumps(evidence, sort_keys=True)
    for field in ("member_provider_id", "buyer_account_id", "pool_operator_account_id", "operator_identity"):
        if run[field] in text:
            die(f"redacted evidence would contain the raw {field}")


def build_evidence(capture: Path) -> dict[str, Any]:
    if capture.is_symlink() or not capture.is_dir():
        die("--capture-dir must be a directory")
    require_no_symlink_components(capture, "--capture-dir")
    run = load_run(capture)
    run["fingerprint_salt"] = secrets.token_hex(32)
    preconditions = check_preconditions(capture)
    pool = check_pool(capture, run)
    requests: dict[str, Any] = {}
    usage_equal = True
    for kind in REQUEST_KINDS:
        response = check_response(capture, kind, run)
        settlement = check_settlement(capture, kind, run, pool)
        visible = response["buyer_visible_usage"]
        debited = settlement["debited_tokens"]
        if (visible["prompt_tokens"], visible["completion_tokens"]) != (debited["prompt_tokens"], debited["completion_tokens"]):
            usage_equal = False
        requests[kind] = {"response": response, "settlement": settlement}
    controls = check_controls(capture)
    holds = check_holds(capture)
    evidence = {
        "schema_version": EVIDENCE_SCHEMA,
        "journey_id": JOURNEY_ID,
        "run_id": run["run_id"],
        "requirement_ids": sorted(TRUSTED_POOL_EXTERNAL_RUNTIME_PROMOTABLE_REQUIREMENT_IDS),
        "repository": {"name": REPOSITORY, "commit": run["source_commit"]},
        "captured_at": run["captured_at"],
        "expires_at": run["expires_at"],
        "operator": {"role": run["operator_role"], "identity_fingerprint": fingerprint(run["operator_identity"], run["fingerprint_salt"])},
        "environment": {
            "class": TRUSTED_POOL_EXTERNAL_RUNTIME_EXECUTION_MODE,
            "hardware_profile": run["hardware_profile"],
            "candidate": run["accepted_id"],
        },
        "result": {
            "status": "pass",
            "summary": "paid non-streaming and streaming requests on a candidate operator pool, served by llamacpp_loopback, settled verified / pool_operator_attested with debit equal to finality and ledger",
        },
        "steps": [
            {"id": step_id, "status": "pass", "assertion": STEP_ASSERTIONS[step_id], "artifacts": [ARTIFACT_ID]}
            for step_id in TRUSTED_POOL_EXTERNAL_RUNTIME_STEP_ID_ORDER
        ],
        "redaction": {
            "secrets_redacted": True,
            "operator_identity_redacted": True,
            "local_account_names_redacted": True,
        },
        "observations": {
            "settlement_mode": "enforce",
            "enforce_activated": True,
            "enforce_scope": "pool",
            "production_coordinator": True,
            "launch_environment": "candidate",
            "payout_ready_mutated": False,
            "raw_prompt_output_redacted": True,
            "bearer_tokens_redacted": True,
            "buyer_visible_usage_equals_debit": usage_equal,
        },
        "candidate_identity": {
            "coordinator_version": run["coordinator_version"],
            "accepted_id": run["accepted_id"],
            "member_cli_sha256": run["member_cli_sha256"],
            "llama_server_build": run["llama_server_build"],
            "gguf_sha256": run["gguf_sha256"],
            "gguf_artifact_id": run["gguf_artifact_id"],
            "model_id": run["model_id"],
            "pool_id": run["pool_id"],
            "manifest_version": pool["manifest_version"],
            "manifest_core_digest": pool["manifest_core_digest"],
            "runtime_source": RUNTIME_SOURCE,
            "fingerprint_salt": run["fingerprint_salt"],
        },
        "preconditions": preconditions,
        "pool": pool,
        "requests": requests,
        "negative_controls": controls,
        "gateway_holds": holds,
    }
    reject_forbidden_secret_keys(evidence)
    reject_raw_identifiers(evidence, run)
    revalidate_committed_evidence(evidence)
    return evidence


def write_json_atomically(path: Path, value: dict[str, Any]) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    payload = json.dumps(value, indent=2, sort_keys=False) + "\n"
    with tempfile.NamedTemporaryFile("w", encoding="utf-8", dir=path.parent, prefix=f".{path.name}.", delete=False) as handle:
        temporary = Path(handle.name)
        handle.write(payload)
    try:
        if path.exists() and path.is_symlink():
            die(f"output must not be a symlink: {path}")
        temporary.replace(path)
    finally:
        if temporary.exists():
            temporary.unlink()


# ---- payload (runs in the signing workflow) ----


def load_object(path: Path, label: str) -> dict[str, Any]:
    result = ValidationResult()
    value = _load_json(path, result)
    if result.errors:
        for error in result.errors:
            print(f"error: {error}", file=sys.stderr)
        die(f"{label} rejected")
    if not isinstance(value, dict):
        die(f"{label} must be a JSON object")
    return value


def repository_relative(root: Path, value: str, label: str) -> str:
    candidate = Path(value)
    if candidate.is_absolute():
        die(f"{label} must be repository-relative")
    normalized = candidate.as_posix()
    if normalized.startswith("../") or "/../" in normalized or normalized == "..":
        die(f"{label} must not contain parent traversal")
    resolved = (root / normalized).resolve(strict=False)
    try:
        resolved.relative_to(root)
    except ValueError:
        die(f"{label} must stay inside the repository")
    return normalized


def require_evidence_source(root: Path, source: str) -> tuple[str, Path]:
    normalized = repository_relative(root, source, "redacted evidence source")
    name = Path(normalized).name
    if not normalized.startswith(EVIDENCE_PREFIX) or not name.endswith(".redacted.json"):
        die(f"redacted evidence source must be {EVIDENCE_PREFIX}*.redacted.json")
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
    forbidden = [item for item in input_ids if item not in TRUSTED_POOL_EXTERNAL_RUNTIME_PROMOTABLE_REQUIREMENT_IDS]
    if forbidden:
        die(f"trusted-pool external-runtime journey-result cannot promote {', '.join(forbidden)}")
    return input_ids


def load_mapped_requirements(root: Path) -> set[str]:
    conformance = load_object(root / "specs" / "CONFORMANCE.json", "spec conformance")
    requirements = conformance.get("requirements")
    if not isinstance(requirements, list):
        die("specs/CONFORMANCE.json requirements must be an array")
    mapped: set[str] = set()
    for row in requirements:
        if not isinstance(row, dict):
            continue
        journeys = row.get("journeys")
        if isinstance(journeys, list) and JOURNEY_ID in journeys and row.get("state") == "pending":
            requirement_id = row.get("requirement_id")
            if isinstance(requirement_id, str):
                mapped.add(requirement_id)
    return mapped


def git_ok(root: Path, *args: str) -> bool:
    return subprocess.run(["git", *args], cwd=root, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, check=False).returncode == 0


def require_git_file_matches(root: Path, commit: str, source: str, expected: bytes) -> None:
    completed = subprocess.run(["git", "show", f"{commit}:{source}"], cwd=root, capture_output=True, check=False)
    if completed.returncode != 0:
        die("redacted evidence source must exist at --evidence-sha")
    if completed.stdout != expected:
        die("redacted evidence source bytes must match --evidence-sha")


def require_steps(value: Any) -> list[dict[str, Any]]:
    if not isinstance(value, list):
        die("steps must be an array")
    by_id: dict[str, dict[str, Any]] = {}
    order: list[str] = []
    for index, item in enumerate(value):
        step = require_object(item, f"steps[{index}]")
        step_id = require_string(step.get("id"), None, f"steps[{index}].id")
        if step_id in by_id:
            die(f"duplicate step id: {step_id}")
        if step.get("status") != "pass":
            die(f"{step_id}.status must equal 'pass'")
        assertion = require_string(step.get("assertion"), None, f"{step_id}.assertion")
        if step.get("artifacts") != [ARTIFACT_ID]:
            die(f"{step_id}.artifacts must reference {ARTIFACT_ID}")
        by_id[step_id] = {"id": step_id, "status": "pass", "assertion": assertion, "artifacts": [ARTIFACT_ID]}
        order.append(step_id)
    if order != list(TRUSTED_POOL_EXTERNAL_RUNTIME_STEP_ID_ORDER):
        die(f"steps must be exactly {list(TRUSTED_POOL_EXTERNAL_RUNTIME_STEP_ID_ORDER)} in order")
    return [by_id[step_id] for step_id in order]


def require_observations(value: Any) -> dict[str, Any]:
    observations = require_object(value, "observations")
    if set(observations) != TRUSTED_POOL_EXTERNAL_RUNTIME_OBSERVATION_KEYS:
        die(f"observations keys must be exactly {sorted(TRUSTED_POOL_EXTERNAL_RUNTIME_OBSERVATION_KEYS)}")
    fixed = {
        "settlement_mode": "enforce",
        "enforce_activated": True,
        "enforce_scope": "pool",
        "production_coordinator": True,
        "launch_environment": "candidate",
        "payout_ready_mutated": False,
        "raw_prompt_output_redacted": True,
        "bearer_tokens_redacted": True,
    }
    for field, want in fixed.items():
        if observations.get(field) != want or type(observations.get(field)) is not type(want):
            die(f"observations.{field} must equal {want!r}")
    if not isinstance(observations.get("buyer_visible_usage_equals_debit"), bool):
        die("observations.buyer_visible_usage_equals_debit must be a boolean")
    return deepcopy(observations)


def require_candidate_identity(value: Any) -> dict[str, Any]:
    identity = require_object(value, "candidate_identity")
    if set(identity) != TRUSTED_POOL_EXTERNAL_RUNTIME_CANDIDATE_IDENTITY_KEYS:
        die(f"candidate_identity keys must be exactly {sorted(TRUSTED_POOL_EXTERNAL_RUNTIME_CANDIDATE_IDENTITY_KEYS)}")
    for field in ("member_cli_sha256", "gguf_sha256", "manifest_core_digest", "fingerprint_salt"):
        require_string(identity.get(field), SHA256_RE, f"candidate_identity.{field}")
    require_string(identity.get("accepted_id"), ACCEPTED_ID_RE, "candidate_identity.accepted_id")
    for field in ("coordinator_version", "llama_server_build", "gguf_artifact_id", "model_id", "pool_id"):
        require_string(identity.get(field), None, f"candidate_identity.{field}")
    if identity.get("runtime_source") != RUNTIME_SOURCE:
        die(f"candidate_identity.runtime_source must equal {RUNTIME_SOURCE!r}")
    version = identity.get("manifest_version")
    if isinstance(version, bool) or not isinstance(version, int) or version < 1:
        die("candidate_identity.manifest_version must be a positive integer")
    return deepcopy(identity)


def build_payload(root: Path, source: str, *, source_sha: str, evidence_sha: str, requirement_ids: str | None) -> dict[str, Any]:
    require_string(source_sha, COMMIT_RE, "--source-sha")
    require_string(evidence_sha, COMMIT_RE, "--evidence-sha")
    source, path = require_evidence_source(root, source)
    evidence_bytes = path.read_bytes()
    evidence = require_object(parse_json_bytes(evidence_bytes, source), "trusted-pool external-runtime redacted evidence")
    reject_forbidden_secret_keys(evidence)
    revalidate_committed_evidence(evidence)
    if evidence.get("schema_version") != EVIDENCE_SCHEMA:
        die(f"schema_version must equal {EVIDENCE_SCHEMA!r}")
    if evidence.get("journey_id") != JOURNEY_ID:
        die(f"journey_id must equal {JOURNEY_ID!r}")
    if JOURNEY_ID != TRUSTED_POOL_EXTERNAL_RUNTIME_JOURNEY_ID or ARTIFACT_ID != TRUSTED_POOL_EXTERNAL_RUNTIME_ARTIFACT_ID:
        die("builder constants drifted from check_spec_governance")
    for label, commit in (("--source-sha", source_sha), ("--evidence-sha", evidence_sha)):
        if not git_ok(root, "cat-file", "-e", f"{commit}^{{commit}}"):
            die(f"{label} is not a reachable commit")
    if not git_ok(root, "merge-base", "--is-ancestor", source_sha, evidence_sha):
        die("--source-sha must be an ancestor of --evidence-sha")
    repository = require_object(evidence.get("repository"), "repository")
    if repository.get("name") != REPOSITORY:
        die(f"repository.name must equal {REPOSITORY!r}")
    if require_string(repository.get("commit"), COMMIT_RE, "repository.commit") != source_sha:
        die("repository.commit must exactly match --source-sha")
    require_git_file_matches(root, evidence_sha, source, evidence_bytes)

    selected = parse_requirement_ids(requirement_ids, evidence)
    not_mapped = [item for item in selected if item not in load_mapped_requirements(root)]
    if not_mapped:
        die(f"requirement_ids must be pending and mapped to {JOURNEY_ID}: {', '.join(not_mapped)}")

    captured_at = require_string(evidence.get("captured_at"), DATETIME_Z_RE, "captured_at")
    expires_at = require_string(evidence.get("expires_at"), DATE_RE, "expires_at")
    if date.fromisoformat(expires_at) < date.today():
        die("expires_at must not be in the past")
    operator = deepcopy(require_object(evidence.get("operator"), "operator"))
    require_string(operator.get("role"), None, "operator.role")
    require_string(operator.get("identity_fingerprint"), SHA256_RE, "operator.identity_fingerprint")
    environment = deepcopy(require_object(evidence.get("environment"), "environment"))
    for field in ("class", "hardware_profile", "candidate"):
        require_string(environment.get(field), None, f"environment.{field}")
    if environment.get("class") != TRUSTED_POOL_EXTERNAL_RUNTIME_EXECUTION_MODE:
        die(f"environment.class must equal {TRUSTED_POOL_EXTERNAL_RUNTIME_EXECUTION_MODE!r}")
    result = deepcopy(require_object(evidence.get("result"), "result"))
    if result.get("status") != "pass":
        die("result.status must equal 'pass'")
    if "summary" in result:
        require_string(result.get("summary"), None, "result.summary")
    steps = require_steps(evidence.get("steps"))
    redaction = deepcopy(require_object(evidence.get("redaction"), "redaction"))
    for field in ("secrets_redacted", "operator_identity_redacted", "local_account_names_redacted"):
        if redaction.get(field) is not True:
            die(f"redaction.{field} must be true")
    observations = require_observations(evidence.get("observations"))
    candidate_identity = require_candidate_identity(evidence.get("candidate_identity"))
    run_id = require_string(evidence.get("run_id"), RUN_ID_RE, "run_id")

    return {
        "schema_version": JOURNEY_RESULT_PAYLOAD_SCHEMA,
        "journey_id": JOURNEY_ID,
        "requirement_ids": selected,
        "repository": {"name": REPOSITORY, "commit": source_sha},
        "captured_at": captured_at,
        "expires_at": expires_at,
        "operator": operator,
        "environment": environment,
        "artifacts": [{"id": ARTIFACT_ID, "sha256": sha256_hex(evidence_bytes), "source": source}],
        "result": result,
        "steps": steps,
        "redaction": redaction,
        "run_id": run_id,
        "execution_mode": TRUSTED_POOL_EXTERNAL_RUNTIME_EXECUTION_MODE,
        "observations": observations,
        "candidate_identity": candidate_identity,
    }


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    sub = parser.add_subparsers(dest="command", required=True)
    capture = sub.add_parser("capture", help="check a capture directory and write the redacted evidence")
    capture.add_argument("--capture-dir", required=True, help="operator capture directory (journey doc layout)")
    capture.add_argument("--output", required=True, help="redacted evidence output path")
    payload = sub.add_parser("payload", help="build the unsigned journey-result payload from committed redacted evidence")
    payload.add_argument("redacted_evidence_source", help=f"{EVIDENCE_PREFIX}*.redacted.json")
    payload.add_argument("--root", default=".", help="repository root")
    payload.add_argument("--output", required=True, help="unsigned journey-result payload output path")
    payload.add_argument("--source-sha", required=True, help="deployed source commit captured by the evidence")
    payload.add_argument("--evidence-sha", required=True, help="repository commit containing the redacted evidence")
    payload.add_argument("--requirement-ids", default=None, help="comma-separated requirement IDs to cover")
    args = parser.parse_args(argv)

    if args.command == "capture":
        output = Path(args.output)
        write_json_atomically(output, build_evidence(Path(args.capture_dir)))
        print(f"build-trusted-pool-external-runtime-journey-result: wrote {output}")
        return 0
    root = Path(args.root).resolve()
    output = Path(args.output)
    if not output.is_absolute():
        output = root / output
    value = build_payload(
        root,
        args.redacted_evidence_source,
        source_sha=args.source_sha,
        evidence_sha=args.evidence_sha,
        requirement_ids=args.requirement_ids,
    )
    write_json_atomically(output, value)
    print(f"build-trusted-pool-external-runtime-journey-result: wrote {output}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
