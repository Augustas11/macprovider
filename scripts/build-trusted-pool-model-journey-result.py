#!/usr/bin/env python3
"""Build the JOURNEY-TRUSTED-POOL-MODEL redacted evidence and journey-result payload.

`capture` reads an operator capture directory (layout in
journeys/JOURNEY-TRUSTED-POOL-MODEL.md), verifies the captured signed pool
events with `coordinator-cli trust-pool-admin verify-manifest`, normalizes
every record into the closed redacted evidence schema (identities become
salted fingerprints, response bodies digests, raw files digests and sizes),
and then runs the same semantic validator `payload` runs. It writes the
redacted evidence and, beside it, the signed manifest bundle the payload step
re-verifies.

`payload` re-runs that full semantic validator over the committed evidence,
re-verifies the committed manifest bundle with the reviewed coordinator-cli,
and builds the unsigned journey-result payload. The result summary, step
assertions and observations are derived, never taken from free text.
"""

from __future__ import annotations

import argparse
import hashlib
import importlib.util
import json
import re
import secrets
import struct
import subprocess
import sys
from copy import deepcopy
from datetime import date, datetime, timedelta, timezone
from email.utils import parsedate_to_datetime
from pathlib import Path
from types import ModuleType
from typing import Any

from check_spec_governance import (
    JOURNEY_RESULT_PAYLOAD_SCHEMA,
    TRUSTED_POOL_MODEL_ARTIFACT_ID,
    TRUSTED_POOL_MODEL_CANDIDATE_IDENTITY_KEYS,
    TRUSTED_POOL_MODEL_EXECUTION_MODE,
    TRUSTED_POOL_MODEL_FIXED_OBSERVATIONS,
    TRUSTED_POOL_MODEL_JOURNEY_ID,
    TRUSTED_POOL_MODEL_OBSERVATION_KEYS,
    TRUSTED_POOL_MODEL_PROMOTABLE_REQUIREMENT_IDS,
    TRUSTED_POOL_MODEL_SHA256_IDENTITY_KEYS,
    TRUSTED_POOL_MODEL_STEP_ID_ORDER,
)


def die(message: str) -> None:
    print(f"build-trusted-pool-model-journey-result: {message}", file=sys.stderr)
    raise SystemExit(1)


def load_base_builder() -> ModuleType:
    path = Path(__file__).resolve().with_name("build-trusted-pool-external-runtime-journey-result.py")
    spec = importlib.util.spec_from_file_location("trusted_pool_external_runtime_builder", path)
    if spec is None or spec.loader is None:
        die("could not load the trusted-pool external-runtime journey-result builder")
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


# The generic capture, redaction and git helpers are the external-runtime
# builder's (loaded by path; that builder is a script, not a package). Their
# failures report under this builder's name. Every journey-specific rule
# lives here.
base = load_base_builder()
base.die = die
require = base.require
require_string = base.require_string
sha256_hex = base.sha256_hex
fingerprint = base.fingerprint


EVIDENCE_SCHEMA = "macprovider.trusted-pool-model-evidence.v2"
VERIFICATION_SCHEMA = "macprovider.trust-pool-manifest-verification.v1"
JOURNEY_ID = "JOURNEY-TRUSTED-POOL-MODEL"
REPOSITORY = "Augustas11/macprovider"
ARTIFACT_ID = "redacted-trusted-pool-model"
EVIDENCE_PREFIX = "journeys/evidence/trusted-pool-model-"
BUNDLE_ROOT_FILE = "root-issuer-registered.json"
ROUTE_SNAPSHOT_V2 = "spec022-route-snapshot-v2"
DISCLOSURE_CLASS = "pool_attested_unverified"
DISCLOSURE_TEXT = "Pool-attested, not network-verified"
PRICE_SOURCE = "pool_creator_signed"
SUMMARY = (
    "pool-scoped native mlx_cache and R016-attested GGUF entries, verified against the signed manifest chain, "
    "served and settled verified with payable credits at the signed entry rates, refused outside the pool, "
    "and revoked at the current generation"
)
MAX_EVIDENCE_DAYS = 30
INT64_MAX = 2**63 - 1
MAX_POOL_MODEL_CONTEXT = 1 << 20
BOUNDS_TAG = b"macprovider/spec005/pool-model-pricing-bounds/v1"
BOUNDS_DIGEST_TOKENS = 1_048_576
REQUIREMENT_RE = re.compile(r"^SPEC-[0-9]{3}-R[0-9]{3}$")
COMMIT_RE = re.compile(r"^[0-9a-f]{40}$")
SHA256_RE = re.compile(r"^[0-9a-f]{64}$")
DATETIME_Z_RE = re.compile(r"^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z$")
RFC3339_RE = re.compile(r"^([0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2})(\.[0-9]{1,9})?(Z|[+-][0-9]{2}:[0-9]{2})$")
DATE_RE = re.compile(r"^[0-9]{4}-[0-9]{2}-[0-9]{2}$")
RUN_ID_RE = re.compile(r"^trusted-pool-model-[0-9]{8}T[0-9]{6}Z$")
POOL_ID_RE = re.compile(r"^[A-Za-z0-9_-]{8,64}$")
SLUG_RE = re.compile(r"^[a-z0-9][a-z0-9-]{0,62}$")
LICENSE_RE = re.compile(r"^(?:LicenseRef-[A-Za-z0-9][A-Za-z0-9.-]{0,63}|[A-Za-z0-9][A-Za-z0-9.+-]{0,63})$")
TOKEN_RE = re.compile(r"^[a-z][a-z0-9_]{0,63}$")
REQUEST_ID_RE = re.compile(r"^[A-Za-z0-9][A-Za-z0-9._:-]{0,127}$")
VERSION_RE = re.compile(r"^v[0-9]+\.[0-9]+\.[0-9]+$")
SHORT_TOKEN_RE = base.SHORT_TOKEN_RE
ACCEPTED_ID_RE = base.ACCEPTED_ID_RE
GGUF_ALGORITHM = "macprovider.gguf-file.v1"
SNAPSHOT_ALGORITHM = "macprovider.snapshot-manifest.v1"
RUNTIME_FORMAT = {
    "llamacpp_loopback": GGUF_ALGORITHM,
    "lmstudio_loopback": GGUF_ALGORITHM,
    "ollama_loopback": GGUF_ALGORITHM,
    "mlx_cache": SNAPSHOT_ALGORITHM,
    "mlxlm_loopback": SNAPSHOT_ALGORITHM,
    "omlx_loopback": SNAPSHOT_ALGORITHM,
}
NATIVE_RUNTIME = "mlx_cache"

ENTRY_KINDS = {
    "native": {
        "algorithm": SNAPSHOT_ALGORITHM,
        "engine": "mlx_cache",
        "route_runtime_source": None,
        "usage_source": "coordinator_observed",
    },
    "gguf": {
        "algorithm": GGUF_ALGORITHM,
        "engine": "llamacpp_loopback",
        "route_runtime_source": "llamacpp_loopback",
        "usage_source": "pool_operator_attested",
    },
}
# precondition -> exact observed facts (None = the value is checked below).
PRECONDITION_FACTS = {
    "deploy-build": {"production": True, "coordinator_version": None, "gateway_version": None, "contains_commit": None},
    "trusted-pools-enabled": {"coordinator": True, "gateway": True},
    "pricing-bounds-configured": {"bounds_set": True},
    "gateway-route-snapshot-v2": {"advertised": True},
    "payout-disabled": {"payout_enabled": False},
}
PRECONDITION_IDS = tuple(PRECONDITION_FACTS)
MANIFEST_ROLES = ("native_genesis", "window_rotation", "price_change", "entry_removal", "gguf_added", "attestation_removal")
RATE_KEYS = ("prompt_rate_per_mtok", "prompt_cache_hit_rate_per_mtok", "completion_rate_per_mtok")
BOUNDS_KEYS = tuple(f"{edge}_{rate}" for rate in RATE_KEYS for edge in ("min", "max"))
PRE_BIND_STATES = {"offer_submitted", "sandbox_probe_only", "network_visible_unpriced", "network_admitted_unsettled"}
ENTRY_KEYS = (
    "pool_model_id", "artifact_hash_algorithm", "artifact_hash", "allowed_runtime_sources", "license",
    "paid_serving_attested", *RATE_KEYS, "disclosure_class", "max_context_tokens",
)
RAW_IDENTITY_FIELDS = (
    "creator_account_id", "buyer_account_id", "native_member_provider_id", "native_member_account_id",
    "gguf_member_provider_id", "gguf_member_account_id", "other_pool_id", "operator_identity",
)
# capture-relative directory -> (entry kind or None for either, streaming)
PAID_REQUESTS = {
    "requests/native-nonstream": ("native", False),
    "requests/native-stream": ("native", True),
    "requests/gguf-nonstream": ("gguf", False),
    "requests/gguf-stream": ("gguf", True),
    "rotation/window-only/after": (None, False),
    "rotation/price-change/inflight": (None, False),
    "rotation/price-change/after": (None, False),
    "rotation/entry-removal/inflight": ("native", False),
    "pause/resumed": (None, False),
    "restart/after": (None, False),
}
# capture-relative directory -> (allowed HTTP statuses, allowed error codes).
# The attestation-removal refusal keeps its entry but loses its only member;
# the exact closed code is not pinned by a spec, so the no-member family is
# allowed (it must still dispatch nothing and refund).
REFUSALS = {
    "refusals/no-pool-header": ((404,), ("model_not_found",)),
    "refusals/other-pool": ((404,), ("model_not_found",)),
    "refusals/wrong-engine": ((503,), ("engine_unavailable",)),
    "pause/paused": ((503,), ("pool_unavailable",)),
    "rotation/entry-removal/after": ((404,), ("model_not_found",)),
    "rotation/attestation-removal/after": ((404, 503), (
        "model_not_found", "engine_unavailable", "no_providers_available", "model_unavailable", "provider_unavailable",
        "pool_unavailable")),
}
STEP_ASSERTIONS = {
    "step-01-preconditions": "the #1816 build is deployed coordinator, then gateway, then member CLIs; trusted pools, bounds, route_snapshot_v2 and payout-disabled facts hold",
    "step-02-pricing-bounds-and-owner-authority": "int64-safe pricing bounds whose recomputed digest every route carries hold every signed rate; the owner map reload applied",
    "step-03-pool-genesis-with-entries": "the signed manifest chain verifies against the root registration; genesis carries exactly the native mlx_cache entry",
    "step-04-non-creator-members": "a delegated non-creator native member and a non-creator GGUF member whose recorded owner account is the attested account",
    "step-05-proposal-bundles": "each signed entry equals its pool_model_proposal.v1 bundle's identity",
    "step-06-offer-binding": "each member's offer binds pool-scoped catalog_priced under the exact signed-manifest actor; never settlement_capable",
    "step-07-pool-models-disclosure": "the pool models view lists exactly the signed entries as closed pool-model objects; the global view and global route snapshots carry none",
    "step-08-native-entry-paid": "native mlx_cache entry served, joined end to end, settled verified with a payable credit recomputed from the frozen entry rates",
    "step-09-attested-member-paid": "GGUF entry served by the attested member, pool_operator_attested, joined end to end, verified, payable at the recomputed entry rates",
    "step-10-refusals": "no pool header, another pool and a wrong engine fail closed with no route snapshot or ledger row and one refunded reservation",
    "step-11-window-rotation-no-gap": "a window-only rotation keeps the terms digest, rebinds after activation, and serves on both sides of the boundary",
    "step-12-price-change-in-flight": "an attempt dispatched before the price change activates settles after it at its snapshot rates; the member re-offers and later attempts use the new rates",
    "step-13-current-generation-revocation": "entry removal and attestation removal revoke the bindings after activation; the in-flight attempt settles; later requests are refused",
    "step-14-pause-resume-rollback": "a paused pool refuses, resumes serving, and the rollback preflight blocks m9 and clears p1816",
    "step-15-restart-ordering": "the coordinator restarts before the gateway and the pool model serves after the restart",
    "step-16-redaction": "closed schema; prompts, completions, keys, locators and raw identities absent; raw files kept as digests",
}
LOCATOR_PATTERNS = (
    re.compile(r"[A-Za-z][A-Za-z0-9+.-]*://"),
    re.compile(r"(?<![0-9.])[0-9]{1,3}(?:\.[0-9]{1,3}){3}(?![0-9.])"),
    # IPv6: four or more groups, or a "::" compression (an HH:MM:SS time has three).
    re.compile(r"(?i)(?<![0-9a-f:])(?:(?:[0-9a-f]{1,4}:){3,7}[0-9a-f]{1,4}|[0-9a-f]{0,4}::[0-9a-f]{0,4}(?::[0-9a-f]{1,4})*)(?![0-9a-f:])"),
    re.compile(r"(?:^|[\s\"'=(])(?:/|~/|[A-Za-z]:\\)[A-Za-z0-9._-]"),
    re.compile(r"(?i)\b[a-z0-9-]+(?:\.[a-z0-9-]+)*\.(?:tech|com|net|org|io|dev|local|internal|lan|corp|home|ts\.net)\b"),
)


# ---- small typed helpers ----


def obj(value: Any, keys: set[str] | tuple[str, ...], where: str) -> dict[str, Any]:
    """A closed object: exactly these keys."""
    if not isinstance(value, dict):
        die(f"{where} must be an object")
    want = set(keys)
    if set(value) != want:
        missing, extra = sorted(want - set(value)), sorted(set(value) - want)
        die(f"{where} must have exactly its keys (missing {missing}, unexpected {extra})")
    return value


def is_int(value: Any) -> bool:
    return isinstance(value, int) and not isinstance(value, bool)


def int_in(value: Any, where: str, low: int = 0, high: int = INT64_MAX) -> int:
    if not is_int(value) or not low <= value <= high:
        die(f"{where} must be an integer in [{low}, {high}]")
    return value


def as_int(value: Any, where: str) -> int:
    """SQL rows may carry an integer as text; anything else is refused."""
    if isinstance(value, str) and re.fullmatch(r"-?[0-9]{1,19}", value):
        return int(value)
    if not is_int(value):
        die(f"{where} must be an integer")
    return value


def hex64(value: Any, where: str) -> str:
    return require_string(value, SHA256_RE, where)


def token(value: Any, where: str) -> str:
    return require_string(value, TOKEN_RE, where)


def bool_of(value: Any, where: str) -> bool:
    if not isinstance(value, bool):
        die(f"{where} must be a boolean")
    return value


def list_of(value: Any, where: str) -> list[Any]:
    if not isinstance(value, list):
        die(f"{where} must be a list")
    return value


def rfc3339_ms(value: Any, where: str) -> int:
    if not isinstance(value, str):
        die(f"{where} must be an RFC 3339 timestamp")
    match = RFC3339_RE.fullmatch(value)
    if not match:
        die(f"{where} must be an RFC 3339 timestamp")
    offset = "+00:00" if match.group(3) == "Z" else match.group(3)
    moment = datetime.fromisoformat(match.group(1) + offset)
    fraction = (match.group(2) or ".0")[1:]
    return int(moment.timestamp()) * 1000 + int(fraction.ljust(9, "0")[:3])


def z_seconds(value: Any, where: str) -> int:
    require_string(value, DATETIME_Z_RE, where)
    return rfc3339_ms(value, where) // 1000


def round_half_even(numerator: int, denominator: int) -> int:
    """billing.RoundHalfEven for the non-negative values a ledger row holds."""
    quotient, remainder = divmod(numerator, denominator)
    twice = remainder * 2
    if twice < denominator:
        return quotient
    if twice > denominator:
        return quotient + 1
    return quotient if quotient % 2 == 0 else quotient + 1


def bounds_digest(bounds: dict[str, int]) -> str:
    """poolmanifest.PoolModelPricingBounds.SHA256Hex."""
    body = BOUNDS_TAG + b"".join(struct.pack(">Q", bounds[key]) for key in BOUNDS_KEYS)
    return hashlib.sha256(body).hexdigest()


def owner_map_digest(account_providers: dict[str, list[str]]) -> tuple[str, dict[str, str]]:
    """trustpool.Registry.SetProviderOwnerAccounts: provider -> owner digest."""
    owners: dict[str, str] = {}
    ambiguous: set[str] = set()
    for account, providers in account_providers.items():
        account = account.strip()
        if not account:
            continue
        for provider in providers:
            provider = provider.strip()
            if not provider:
                continue
            if provider in owners and owners[provider] != account:
                ambiguous.add(provider)
            owners[provider] = account
    for provider in ambiguous:
        del owners[provider]
    digest = hashlib.sha256()
    for provider in sorted(owners):
        digest.update(f"{provider}\x00{owners[provider]}\n".encode("utf-8"))
    return digest.hexdigest(), owners


# ---- capture: read and normalize ----


class Capture:
    """Reads capture files once, recording each raw file's digest and size."""

    def __init__(self, root: Path) -> None:
        self.root = root
        self.raw: dict[str, dict[str, Any]] = {}

    def read(self, relative: str) -> bytes:
        payload = base.read_capture_file(self.root, relative)
        self.raw[relative] = {"sha256": sha256_hex(payload), "bytes": len(payload)}
        return payload

    def exists(self, relative: str) -> bool:
        path = self.root / relative
        return path.is_file() and not path.is_symlink()

    def object(self, relative: str) -> dict[str, Any]:
        value = base.parse_json_bytes(self.read(relative), relative)
        if not isinstance(value, dict):
            die(f"{relative} must be a JSON object")
        return value

    def rows(self, relative: str) -> list[dict[str, Any]]:
        payload = self.read(relative)
        if not payload.strip():
            return []
        value = base.parse_json_bytes(payload, relative)
        if not isinstance(value, list) or not all(isinstance(row, dict) for row in value):
            die(f"{relative} must be a JSON array of row objects")
        return value


def parse_headers(payload: bytes, label: str) -> tuple[int, dict[str, str]]:
    """`curl -D` output; the last response block wins (skips 1xx). A repeated
    header name fails closed rather than hiding a conflicting value."""
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
        key = name.strip().lower()
        if key in headers:
            die(f"{label}: header {key!r} repeats")
        headers[key] = value.strip()
    return int(match.group(1)), headers


def date_header_seconds(headers: dict[str, str], label: str) -> int:
    raw = headers.get("date")
    if not raw:
        die(f"{label}: the response must carry a Date header")
    try:
        return int(parsedate_to_datetime(raw).timestamp())
    except (TypeError, ValueError):
        die(f"{label}: malformed Date header")
    raise AssertionError


def load_run(capture: Capture) -> dict[str, Any]:
    run = capture.object("run.json")
    patterns = {
        "run_id": RUN_ID_RE, "captured_at": DATETIME_Z_RE, "expires_at": DATE_RE, "source_commit": COMMIT_RE,
        "coordinator_version": VERSION_RE, "accepted_id": ACCEPTED_ID_RE, "native_member_cli_sha256": SHA256_RE,
        "gguf_member_cli_sha256": SHA256_RE, "llama_server_build": re.compile(r"^b[0-9]+$"),
        "operator_role": SHORT_TOKEN_RE, "operator_identity": None, "hardware_profile": SHORT_TOKEN_RE,
        "pool_id": POOL_ID_RE, "other_pool_id": POOL_ID_RE, "creator_account_id": None, "buyer_account_id": None,
        "native_member_provider_id": None, "native_member_account_id": None, "gguf_member_provider_id": None,
        "gguf_member_account_id": None,
    }
    obj(run, set(patterns) | {"native_entry", "gguf_entry", "manifest_versions"}, "run.json")
    for field, pattern in patterns.items():
        require_string(run.get(field), pattern, f"run.json.{field}")
    require(run["other_pool_id"] != run["pool_id"], "run.json.other_pool_id must differ from pool_id")
    require(run["native_member_provider_id"] != run["gguf_member_provider_id"], "the native and GGUF members must be different providers")
    entries = {}
    for kind, spec in ENTRY_KINDS.items():
        entry = obj(run.get(f"{kind}_entry"), {"slug", "artifact_hash"}, f"run.json.{kind}_entry")
        slug = require_string(entry["slug"], SLUG_RE, f"run.json.{kind}_entry.slug")
        entries[kind] = {
            "pool_model_id": f"pool/{run['pool_id']}/{slug}",
            "artifact_hash": hex64(entry["artifact_hash"], f"run.json.{kind}_entry.artifact_hash"),
            "algorithm": spec["algorithm"],
        }
    versions = obj(run.get("manifest_versions"), set(MANIFEST_ROLES), "run.json.manifest_versions")
    run["roles"] = {role: int_in(versions[role], f"run.json.manifest_versions.{role}", 1) for role in MANIFEST_ROLES}
    run["entries"] = entries
    return run


def normalize_entry(entry: Any, where: str) -> dict[str, Any]:
    entry = obj(entry, set(ENTRY_KEYS), where)
    out = {key: entry[key] for key in ENTRY_KEYS}
    out["allowed_runtime_sources"] = list(list_of(entry["allowed_runtime_sources"], f"{where}.allowed_runtime_sources"))
    return out


def normalize_members(members: Any, salt: str, where: str) -> list[dict[str, Any]]:
    out = []
    for index, member in enumerate(list_of(members, where)):
        member = obj(member, {"provider_account_id", "runtime_classes"}, f"{where}[{index}]")
        account = require_string(member["provider_account_id"], None, f"{where}[{index}].provider_account_id")
        out.append({"account_fingerprint": fingerprint(account, salt),
                    "runtime_classes": list(list_of(member["runtime_classes"], f"{where}[{index}].runtime_classes"))})
    return out


def normalize_verification(output: Any, salt: str) -> tuple[dict[str, Any], list[dict[str, Any]]]:
    """verify-manifest output -> (manifest_root, manifests) with accounts as
    salted fingerprints. capture and payload both use it, so payload can
    compare the reviewed CLI's fresh output with the committed evidence."""
    output = obj(output, {
        "schema", "pool_id", "creator_account_id", "launch_environment", "root_issuer_key_id",
        "root_issuer_public_key_fingerprint", "root_event_sha256", "manifests",
    }, "verify-manifest output")
    require(output["schema"] == VERIFICATION_SCHEMA, f"verify-manifest output schema must be {VERIFICATION_SCHEMA}")
    root = {
        "pool_id": require_string(output["pool_id"], POOL_ID_RE, "verify-manifest pool_id"),
        "creator_fingerprint": fingerprint(require_string(output["creator_account_id"], None, "verify-manifest creator"), salt),
        "launch_environment": output["launch_environment"],
        "root_issuer_public_key_fingerprint": hex64(output["root_issuer_public_key_fingerprint"], "verify-manifest root fingerprint"),
        "root_event_sha256": hex64(output["root_event_sha256"], "verify-manifest root_event_sha256"),
    }
    manifests = []
    for index, item in enumerate(list_of(output["manifests"], "verify-manifest manifests")):
        where = f"verify-manifest manifests[{index}]"
        item = obj(item, {
            "manifest_version", "manifest_core_digest", "manifest_terms_digest", "prev_manifest_core_hash", "event_sha256",
            "not_before_unix", "expires_at_unix", "encoding", "settlement_mode", "runtime_allowlist", "model_entries",
            "attested_members",
        }, where)
        manifests.append({
            "manifest_version": item["manifest_version"],
            "manifest_core_digest": item["manifest_core_digest"],
            "manifest_terms_digest": item["manifest_terms_digest"],
            "prev_manifest_core_hash": item["prev_manifest_core_hash"],
            "event_sha256": item["event_sha256"],
            "not_before_unix": item["not_before_unix"],
            "expires_at_unix": item["expires_at_unix"],
            "encoding": item["encoding"],
            "settlement_mode": item["settlement_mode"],
            "runtime_allowlist": list(list_of(item["runtime_allowlist"], f"{where}.runtime_allowlist")),
            "model_entries": [normalize_entry(e, f"{where}.model_entries[{i}]") for i, e in enumerate(list_of(item["model_entries"], f"{where}.model_entries"))],
            "attested_members": normalize_members(item["attested_members"], salt, f"{where}.attested_members"),
        })
    return root, manifests


def run_verify_manifest(cli: str, root_path: Path, manifest_paths: list[Path]) -> Any:
    command = [cli, "trust-pool-admin", "verify-manifest", "--root", str(root_path)]
    for path in manifest_paths:
        command += ["--manifest", str(path)]
    try:
        completed = subprocess.run(command, capture_output=True, check=False, timeout=300)
    except OSError as exc:
        die(f"could not run coordinator-cli verify-manifest: {exc}")
    if completed.returncode != 0:
        detail = completed.stderr.decode("utf-8", "replace").strip().splitlines()
        die(f"coordinator-cli verify-manifest refused the signed pool events: {detail[-1] if detail else 'no output'}")
    return base.parse_json_bytes(completed.stdout, "verify-manifest output")


def capture_manifests(capture: Capture, cli: str, salt: str) -> tuple[dict[str, Any], list[dict[str, Any]], dict[str, bytes]]:
    pool_dir = capture.root / "pool"
    versions = sorted(
        int(child.name[1:]) for child in (pool_dir.iterdir() if pool_dir.is_dir() else [])
        if re.fullmatch(r"v[1-9][0-9]{0,8}", child.name) and child.is_dir()
    )
    require(bool(versions), "pool/v<N>/manifest-accepted.json must be captured")
    bundle = {BUNDLE_ROOT_FILE: capture.read(f"pool/{BUNDLE_ROOT_FILE}")}
    paths = []
    for version in versions:
        relative = f"pool/v{version}/manifest-accepted.json"
        payload = capture.read(relative)
        event = base.parse_json_bytes(payload, relative)
        require(isinstance(event, dict) and event.get("event_type") == "manifest_accepted", f"{relative} must be a manifest_accepted event")
        require(event.get("manifest_version") == version, f"{relative} must be version {version}")
        bundle[f"v{version}.json"] = payload
        paths.append(capture.root / relative)
    root, manifests = normalize_verification(run_verify_manifest(cli, capture.root / "pool" / BUNDLE_ROOT_FILE, paths), salt)
    return root, manifests, bundle


def capture_pool_state(capture: Capture, run: dict[str, Any], version: int, salt: str) -> dict[str, Any]:
    where = f"pool/v{version}/get-pool.json"
    pool = capture.object(where).get("pool")
    if not isinstance(pool, dict):
        die(f"{where}.pool must be an object")
    members = list_of(pool.get("members"), f"{where}.members")
    buyers = list_of(pool.get("buyer_accounts"), f"{where}.buyer_accounts")
    entries = pool.get("model_entries")
    attested = pool.get("attested_members")
    return {
        "manifest_version": pool.get("manifest_version"),
        "manifest_core_digest": pool.get("manifest_core_digest"),
        "lifecycle": pool.get("lifecycle"),
        "routeable": pool.get("routeable"),
        "launch_environment": pool.get("launch_environment"),
        "settlement_mode": pool.get("settlement_mode"),
        "runtime_allowlist": list(list_of(pool.get("runtime_allowlist"), f"{where}.runtime_allowlist")),
        "creator_fingerprint": fingerprint(require_string(pool.get("creator_account_id"), None, f"{where}.creator_account_id"), salt),
        "pool_is_journey_pool": pool.get("pool_id") == run["pool_id"],
        "model_entries": [normalize_entry(e, f"{where}.model_entries[{i}]") for i, e in enumerate(entries or [])],
        "attested_members": normalize_members(attested or [], salt, f"{where}.attested_members"),
        "member_fingerprints": sorted(fingerprint(require_string(m, None, f"{where}.members"), salt) for m in members),
        "revoked_count": len(list_of(pool.get("revoked") or [], f"{where}.revoked")),
        "buyer_authorized": run["buyer_account_id"] in buyers,
    }


def capture_preconditions(capture: Capture) -> dict[str, Any]:
    raw = obj(capture.object("preconditions.json"), set(PRECONDITION_IDS), "preconditions.json")
    out = {}
    for key in PRECONDITION_IDS:
        item = obj(raw[key], {"status", "observed", "checked_at"}, f"preconditions.{key}")
        out[key] = {"status": item["status"], "observed": item["observed"], "checked_at": item["checked_at"]}
    return out


def provider_kind(run: dict[str, Any], provider: Any, where: str) -> str:
    for kind in ENTRY_KINDS:
        if provider == run[f"{kind}_member_provider_id"]:
            return kind
    die(f"{where}: provider must be one of the journey members")
    raise AssertionError


def account_fp(value: Any, salt: str) -> str | None:
    return None if value in (None, "") else fingerprint(str(value), salt)


def capture_body(capture: Capture, base_dir: str, stream: bool) -> dict[str, Any]:
    require(capture.exists(f"{base_dir}/response.sse") == stream, f"{base_dir} must capture {'response.sse' if stream else 'response.json'}")
    if not stream:
        body = capture.read(f"{base_dir}/response.json")
        doc = base.parse_json_bytes(body, f"{base_dir}/response.json")
        if not isinstance(doc, dict):
            die(f"{base_dir} body must be an object")
        choices = list_of(doc.get("choices"), f"{base_dir} choices")
        require(len(choices) == 1 and isinstance(choices[0], dict), f"{base_dir} must have exactly one choice")
        message = choices[0].get("message")
        require(isinstance(message, dict) and isinstance(message.get("content"), str), f"{base_dir} message.content must be a string")
        content, finish_reason, usage = message["content"], choices[0].get("finish_reason"), doc.get("usage")
    else:
        body = capture.read(f"{base_dir}/response.sse")
        data_lines = [line[len("data:"):].strip() for line in body.decode("utf-8").replace("\r\n", "\n").split("\n") if line.startswith("data:")]
        require(bool(data_lines) and data_lines[-1] == "[DONE]", f"{base_dir} stream must end with data: [DONE]")
        parts: list[str] = []
        finish_reason, usage = None, None
        for index, raw in enumerate(data_lines[:-1]):
            chunk = base.parse_json_bytes(raw.encode("utf-8"), f"{base_dir} chunk {index}")
            require(isinstance(chunk, dict), f"{base_dir} chunk {index} must be an object")
            for choice in list_of(chunk.get("choices", []), f"{base_dir} chunk {index} choices"):
                require(isinstance(choice, dict), f"{base_dir} chunk {index}: malformed choice")
                delta = choice.get("delta", {})
                require(isinstance(delta, dict), f"{base_dir} chunk {index}: malformed delta")
                if "content" in delta and delta["content"] is not None:
                    require(isinstance(delta["content"], str), f"{base_dir} chunk {index}: delta.content must be a string")
                    parts.append(delta["content"])
                if choice.get("finish_reason"):
                    finish_reason = choice["finish_reason"]
            if chunk.get("usage") is not None:
                usage = chunk["usage"]
        content = "".join(parts)
    require(isinstance(usage, dict), f"{base_dir} must carry a usage object")
    return {
        "stream": stream,
        "finish_reason": require_string(finish_reason, TOKEN_RE, f"{base_dir} finish_reason"),
        "content_sha256": sha256_hex(content.encode("utf-8")),
        "usage": {"prompt_tokens": as_int(usage.get("prompt_tokens"), f"{base_dir} usage.prompt_tokens"),
                  "completion_tokens": as_int(usage.get("completion_tokens"), f"{base_dir} usage.completion_tokens")},
    }


def capture_paid(capture: Capture, run: dict[str, Any], salt: str, base_dir: str, stream: bool) -> dict[str, Any]:
    status, headers = parse_headers(capture.read(f"{base_dir}/response.headers"), f"{base_dir}/response.headers")
    rid = require_string(headers.get("x-request-id"), REQUEST_ID_RE, f"{base_dir} X-Request-ID")
    record = {
        "x_request_id": rid,
        "date_unix": date_header_seconds(headers, base_dir),
        "status": status,
        "headers": {
            "engine": headers.get("x-macprovider-engine"),
            "model_disclosure": headers.get("x-macprovider-model-disclosure"),
            "pool_manifest_core_digest": headers.get("x-macprovider-pool-manifest-core-digest"),
        },
        "body": capture_body(capture, base_dir, stream),
        "request_log": [],
        "route_snapshots": [],
        "attempt_outputs": [],
        "receipt_verdicts": [],
        "ledger": [],
        "quota_reservations": [],
        "usage_events": [],
    }
    for row in capture.rows(f"{base_dir}/request_log.json"):
        record["request_log"].append({
            "request_id": row.get("request_id"), "attempt_n": as_int(row.get("attempt_n"), f"{base_dir} request_log.attempt_n"),
            "external_request_id": row.get("external_request_id"), "pool_id": row.get("pool_id"),
            "status": as_int(row.get("status"), f"{base_dir} request_log.status"),
        })
    for row in capture.rows(f"{base_dir}/route_snapshots.json"):
        where = f"{base_dir} route_snapshots"
        record["route_snapshots"].append({
            "request_id": row.get("request_id"), "attempt_n": as_int(row.get("attempt_n"), f"{where}.attempt_n"),
            "provider": provider_kind(run, row.get("provider_id"), where),
            "route_snapshot_mode": row.get("route_snapshot_mode"),
            "route_snapshot_policy_version": row.get("route_snapshot_policy_version"),
            "route_snapshot_digest": row.get("route_snapshot_digest"),
            "pool_id": row.get("pool_id"), "model_id": row.get("model_id"),
            "expected_model_hash_source": row.get("expected_model_hash_source"),
            "pool_model_id": row.get("pool_model_id"),
            "manifest_version": as_int(row.get("manifest_version"), f"{where}.manifest_version"),
            "manifest_core_digest": row.get("manifest_core_digest"),
            "pool_generation": as_int(row.get("pool_generation"), f"{where}.pool_generation"),
            "runtime_source": row.get("runtime_source") or None,
            "pool_operator_account_fp": account_fp(row.get("pool_operator_account_id"), salt),
            "pool_member_account_fp": account_fp(row.get("pool_member_account_id"), salt),
            "expected_catalog_model_hash": row.get("expected_catalog_model_hash"),
            "expected_catalog_model_hash_algorithm": row.get("expected_catalog_model_hash_algorithm"),
            "provider_reported_model_hash": row.get("provider_reported_model_hash"),
            "provider_reported_model_hash_algorithm": row.get("provider_reported_model_hash_algorithm"),
            **{f"pool_model_{rate}": as_int(row.get(f"pool_model_{rate}"), f"{where}.pool_model_{rate}") for rate in RATE_KEYS},
            "pool_model_pricing_bounds_sha256": row.get("pool_model_pricing_bounds_sha256"),
            "pool_model_global_multiplier_ppm": as_int(row.get("pool_model_global_multiplier_ppm"), f"{where}.pool_model_global_multiplier_ppm"),
            "pool_model_provider_share_bps": as_int(row.get("pool_model_provider_share_bps"), f"{where}.pool_model_provider_share_bps"),
            "route_decision_ts_unix_ms": as_int(row.get("route_decision_ts_unix_ms"), f"{where}.route_decision_ts_unix_ms"),
        })
    for row in capture.rows(f"{base_dir}/attempt_outputs.json"):
        where = f"{base_dir} attempt_outputs"
        record["attempt_outputs"].append({
            "request_id": row.get("request_id"), "attempt_n": as_int(row.get("attempt_n"), f"{where}.attempt_n"),
            "provider": provider_kind(run, row.get("provider_id"), where),
            "terminal_state": row.get("terminal_state"), "usage_source": row.get("usage_source"),
            "terminal_state_ts_unix_ms": as_int(row.get("terminal_state_ts_unix_ms"), f"{where}.terminal_state_ts_unix_ms"),
        })
    for row in capture.rows(f"{base_dir}/receipt_verdicts.json"):
        where = f"{base_dir} receipt_verdicts"
        record["receipt_verdicts"].append({
            "request_id": row.get("request_id"), "attempt_n": as_int(row.get("attempt_n"), f"{where}.attempt_n"),
            "provider": provider_kind(run, row.get("provider_id"), where),
            "receipt_result": row.get("receipt_result"), "settlement_outcome": row.get("settlement_outcome"),
            "reason": row.get("reason"), "closed": as_int(row.get("closed"), f"{where}.closed"),
            "pool_label_status": row.get("pool_label_status"), "route_snapshot_digest": row.get("route_snapshot_digest"),
            "provider_reported_model_hash": row.get("provider_reported_model_hash"),
            "expected_catalog_model_hash": row.get("expected_catalog_model_hash"),
            "model_id": row.get("model_id"), "model_hash": row.get("model_hash"),
            "received_at_unix_ms": as_int(row.get("received_at_unix_ms"), f"{where}.received_at_unix_ms"),
        })
    for row in capture.rows(f"{base_dir}/ledger.json"):
        where = f"{base_dir} ledger"
        record["ledger"].append({
            "id": as_int(row.get("id"), f"{where}.id"), "request_id": row.get("request_id"),
            "attempt_n": as_int(row.get("attempt_n"), f"{where}.attempt_n"),
            "provider": provider_kind(run, row.get("provider_id"), where), "status": row.get("status"),
            **{field: (None if row.get(field) is None else as_int(row.get(field), f"{where}.{field}")) for field in (
                "charged_prompt_tokens", "cached_prompt_tokens", "completion_tokens", "estimated_completion_tokens")},
            "usage_source": row.get("usage_source"),
            **{field: as_int(row.get(field), f"{where}.{field}") for field in (
                "prompt_rate_per_mtok", "completion_rate_per_mtok", "global_multiplier_ppm", "gross_credits",
                "provider_share_bps", "provider_credits", "quarantined", "payable")},
        })
    for row in capture.rows(f"{base_dir}/quota_reservations.json"):
        where = f"{base_dir} quota_reservations"
        record["quota_reservations"].append({
            "request_id": row.get("request_id"), "status": row.get("status"),
            "settled_tokens": as_int(row.get("settled_tokens"), f"{where}.settled_tokens"),
            "settlement_hold": as_int(row.get("settlement_hold"), f"{where}.settlement_hold"),
        })
    for row in capture.rows(f"{base_dir}/usage_events.json"):
        where = f"{base_dir} usage_events"
        record["usage_events"].append({
            "request_id": row.get("request_id"),
            "prompt_tokens": as_int(row.get("prompt_tokens"), f"{where}.prompt_tokens"),
            "completion_tokens": as_int(row.get("completion_tokens"), f"{where}.completion_tokens"),
            "token_source": row.get("token_source"), "outcome": row.get("outcome"),
        })
    return record


def capture_refusal(capture: Capture, base_dir: str) -> dict[str, Any]:
    status, headers = parse_headers(capture.read(f"{base_dir}/response.headers"), f"{base_dir}/response.headers")
    body = base.parse_json_bytes(capture.read(f"{base_dir}/response.json"), f"{base_dir}/response.json")
    error = body.get("error") if isinstance(body, dict) else None
    require(isinstance(error, dict), f"{base_dir} body must carry an error object")
    reservations = []
    for row in capture.rows(f"{base_dir}/quota_reservations.json"):
        reservations.append({
            "request_id": row.get("request_id"), "status": row.get("status"),
            "settled_tokens": as_int(row.get("settled_tokens"), f"{base_dir} settled_tokens"),
            "settlement_hold": as_int(row.get("settlement_hold"), f"{base_dir} settlement_hold"),
        })
    return {
        "x_request_id": require_string(headers.get("x-request-id"), REQUEST_ID_RE, f"{base_dir} X-Request-ID"),
        "date_unix": date_header_seconds(headers, base_dir),
        "status": status,
        "error_code": token(error.get("code"), f"{base_dir} error.code"),
        "route_snapshot_count": len(capture.rows(f"{base_dir}/route_snapshots.json")),
        "ledger_row_count": len(capture.rows(f"{base_dir}/ledger.json")),
        "quota_reservations": reservations,
    }


def capture_admission(capture: Capture, run: dict[str, Any]) -> list[dict[str, Any]]:
    actor_re = re.compile(rf"^pool_manifest:{re.escape(run['pool_id'])}:[0-9]{{1,10}}:[0-9a-f]{{64}}$")
    out = []
    for row in capture.rows("admission/model-admission-events.json"):
        where = "model-admission-events"
        actor = row.get("actor")
        if not (isinstance(actor, str) and (actor_re.fullmatch(actor) or TOKEN_RE.fullmatch(actor))):
            actor = "other"
        version = row.get("pool_manifest_version")
        out.append({
            "id": as_int(row.get("id"), f"{where}.id"),
            "provider": provider_kind(run, row.get("provider_id"), where),
            "state": token(row.get("state"), f"{where}.state"),
            "reason_code": None if row.get("reason_code") in (None, "") else token(row.get("reason_code"), f"{where}.reason_code"),
            "actor": actor,
            "binding_scope": row.get("binding_scope"),
            "pool_id": row.get("pool_id"),
            "pool_model_id": row.get("pool_model_id"),
            "pool_manifest_version": None if version is None else as_int(version, f"{where}.pool_manifest_version"),
            "pool_manifest_core_digest": row.get("pool_manifest_core_digest"),
            "expected_catalog_model_hash_algorithm": row.get("expected_catalog_model_hash_algorithm"),
            "expected_catalog_model_hash": row.get("expected_catalog_model_hash"),
            "created_at_unix_ms": rfc3339_ms(row.get("created_at_utc"), f"{where}.created_at_utc"),
        })
    return out


def capture_models(capture: Capture) -> dict[str, Any]:
    pool_items = []
    other = 0
    for item in list_of(capture.object("models/pool.json").get("data"), "models/pool.json data"):
        require(isinstance(item, dict), "models/pool.json items must be objects")
        if str(item.get("id", "")).startswith("pool/") or "macprovider_pool_model" in item:
            pool_items.append({"id": item.get("id"), "object": item.get("object"), "pool_model": item.get("macprovider_pool_model")})
        else:
            other += 1
    global_pool_ids = []
    global_pool_objects = 0
    for item in list_of(capture.object("models/global.json").get("data"), "models/global.json data"):
        require(isinstance(item, dict), "models/global.json items must be objects")
        if str(item.get("id", "")).startswith("pool/"):
            global_pool_ids.append(item["id"])
        if "macprovider_pool_model" in item:
            global_pool_objects += 1
    never = capture.rows("never-global.json")
    require(len(never) == 1, "never-global.json must hold one count row")
    return {
        "pool_view": pool_items,
        "pool_view_other_count": other,
        "global_view_pool_ids": global_pool_ids,
        "global_view_pool_objects": global_pool_objects,
        "never_global_count": as_int(obj(never[0], {"n"}, "never-global row")["n"], "never-global.n"),
    }


def capture_rollback(capture: Capture) -> dict[str, Any]:
    out = {}
    for tier in ("m9", "p1816"):
        where = f"rollback/preflight-{tier}"
        rc_text = capture.read(f"{where}.rc").decode("utf-8").strip()
        require(re.fullmatch(r"[0-9]{1,3}", rc_text) is not None, f"{where}.rc must hold the exit status")
        report_bytes = capture.read(f"{where}.json")
        report = base.parse_json_bytes(report_bytes, f"{where}.json")
        require(isinstance(report, dict) and isinstance(report.get("manifest_history"), dict), f"{where}.json must be the preflight report")
        cannot = report["manifest_history"].get("cannot_replay")
        out[tier] = {
            "exit_status": int(rc_text),
            "rollback_blocked": report.get("rollback_blocked"),
            "target_tier": report["manifest_history"].get("target_tier"),
            "cannot_replay_count": len(list_of(cannot, f"{where}.json cannot_replay")),
            "report_sha256": sha256_hex(report_bytes),
        }
    return out


def capture_owner_authority(capture: Capture, run: dict[str, Any], salt: str) -> dict[str, Any]:
    reload = obj(capture.object("config/owner-authority-reload.json"), {
        "bounds_set", "provider_owner_account_ids_applied", "provider_owner_account_ids_providers",
        "provider_owner_account_ids_sha256",
    }, "config/owner-authority-reload.json")
    mapping = capture.object("config/provider-owner-account-ids.json")
    for account, providers in mapping.items():
        require(isinstance(providers, list) and all(isinstance(p, str) for p in providers),
                f"provider-owner-account-ids.{account} must be a list of provider ids")
    digest, owners = owner_map_digest(mapping)
    require(digest == reload["provider_owner_account_ids_sha256"],
            "the recomputed provider_owner_account_ids digest must equal the reload log's")
    require(len(owners) == reload["provider_owner_account_ids_providers"], "the owner map size must equal the reload log's provider count")
    owner = owners.get(run["gguf_member_provider_id"])
    require(owner is not None, "the GGUF member must have exactly one recorded owner account")
    return {
        "reload": dict(reload),
        "owner_map_digest_recomputed": True,
        "gguf_provider_owner_fingerprint": fingerprint(owner, salt),
    }


def build_evidence(capture_dir: Path, cli: str) -> tuple[dict[str, Any], dict[str, bytes]]:
    if capture_dir.is_symlink() or not capture_dir.is_dir():
        die("--capture-dir must be a directory")
    base.require_no_symlink_components(capture_dir, "--capture-dir")
    capture = Capture(capture_dir)
    run = load_run(capture)
    salt = secrets.token_hex(32)
    run["fingerprint_salt"] = salt
    manifest_root, manifests, bundle = capture_manifests(capture, cli, salt)
    counts: dict[str, int] = {}
    for row in capture.rows("pool/trustpool-events.json"):
        event_type = token(row.get("event_type"), "trustpool-events.event_type")
        require(event_type not in counts, f"trustpool-events repeats {event_type}")
        counts[event_type] = as_int(row.get("n"), f"trustpool-events.{event_type}.n")
    proposals = {}
    for kind in ENTRY_KINDS:
        bundle_doc = capture.object(f"proposals/{kind}.json")
        entry = bundle_doc.get("model_entry") if isinstance(bundle_doc.get("model_entry"), dict) else {}
        proposals[kind] = {
            "schema": bundle_doc.get("schema"), "pool_id": bundle_doc.get("pool_id"),
            "runtime_source": bundle_doc.get("runtime_source"),
            "catalog_model_key_null": bundle_doc.get("catalog_model_key") is None,
            "pool_model_id": entry.get("pool_model_id"), "artifact_hash_algorithm": entry.get("artifact_hash_algorithm"),
            "artifact_hash": entry.get("artifact_hash"),
            "creator_fields_null": entry.get("license") is None and entry.get("paid_serving_attested") is None,
        }
    deploy = capture.object("deploy.json")
    restart = capture.object("restart/order.json")
    probes = []
    for index, probe in enumerate(capture.rows("rotation/window-only/probes.json")):
        probe = obj(probe, {"at", "status", "pool_model_id"}, f"probes[{index}]")
        probes.append({"at_unix": z_seconds(probe["at"], f"probes[{index}].at"), "status": as_int(probe["status"], f"probes[{index}].status"),
                       "pool_model_id": probe["pool_model_id"]})
    evidence = {
        "schema_version": EVIDENCE_SCHEMA,
        "journey_id": JOURNEY_ID,
        "run_id": run["run_id"],
        "requirement_ids": sorted(TRUSTED_POOL_MODEL_PROMOTABLE_REQUIREMENT_IDS),
        "repository": {"name": REPOSITORY, "commit": run["source_commit"]},
        "captured_at": run["captured_at"],
        "expires_at": run["expires_at"],
        "operator": {"role": run["operator_role"], "identity_fingerprint": fingerprint(run["operator_identity"], salt)},
        "environment": {"class": TRUSTED_POOL_MODEL_EXECUTION_MODE, "hardware_profile": run["hardware_profile"], "candidate": run["accepted_id"]},
        "result": {"status": "pass", "summary": SUMMARY},
        "steps": derived_steps(),
        "redaction": {"secrets_redacted": True, "operator_identity_redacted": True, "local_account_names_redacted": True},
        "observations": None,
        "candidate_identity": None,
        "identities": {
            "creator_fingerprint": fingerprint(run["creator_account_id"], salt),
            "buyer_fingerprint": fingerprint(run["buyer_account_id"], salt),
            "native_provider_fingerprint": fingerprint(run["native_member_provider_id"], salt),
            "native_account_fingerprint": fingerprint(run["native_member_account_id"], salt),
            "gguf_provider_fingerprint": fingerprint(run["gguf_member_provider_id"], salt),
            "gguf_account_fingerprint": fingerprint(run["gguf_member_account_id"], salt),
            "other_pool_fingerprint": fingerprint(run["other_pool_id"], salt),
        },
        "entries": {kind: dict(run["entries"][kind]) for kind in ENTRY_KINDS},
        "roles": dict(run["roles"]),
        "preconditions": capture_preconditions(capture),
        "deploy_order": {key: z_seconds(deploy.get(key), f"deploy.{key}") for key in (
            "coordinator_deployed_at", "gateway_deployed_at", "native_member_cli_installed_at", "gguf_member_cli_installed_at")},
        "pricing_bounds": dict(capture.object("config/pricing-bounds.json")),
        "owner_authority": capture_owner_authority(capture, run, salt),
        "manifest_root": manifest_root,
        "manifests": manifests,
        "pool_state": {str(run["roles"][role]): capture_pool_state(capture, run, run["roles"][role], salt) for role in MANIFEST_ROLES},
        "event_counts": dict(sorted(counts.items())),
        "proposals": proposals,
        "admission": capture_admission(capture, run),
        "models": capture_models(capture),
        "requests": {name: capture_paid(capture, run, salt, name, stream) for name, (_, stream) in PAID_REQUESTS.items()},
        "refusals": {name: capture_refusal(capture, name) for name in REFUSALS},
        "window_probes": probes,
        "rollback_preflight": capture_rollback(capture),
        "restart": {key: z_seconds(restart.get(key), f"restart.{key}") for key in ("coordinator_restarted_at", "gateway_restarted_at")},
        "raw_documents": None,
    }
    require(len(restart) == 2 and len(deploy) == 4, "deploy.json and restart/order.json must hold exactly their timestamps")
    evidence["raw_documents"] = dict(sorted(capture.raw.items()))
    latest = max(manifests, key=lambda m: m["manifest_version"])
    bounds = evidence["pricing_bounds"]
    bounds_ok = set(bounds) == set(BOUNDS_KEYS) and all(is_int(bounds[k]) and 0 <= bounds[k] <= INT64_MAX for k in BOUNDS_KEYS)
    evidence["candidate_identity"] = {
        "coordinator_version": run["coordinator_version"],
        "accepted_id": run["accepted_id"],
        "native_member_cli_sha256": run["native_member_cli_sha256"],
        "gguf_member_cli_sha256": run["gguf_member_cli_sha256"],
        "llama_server_build": run["llama_server_build"],
        "pool_id": run["pool_id"],
        "native_pool_model_id": run["entries"]["native"]["pool_model_id"],
        "native_artifact_hash": run["entries"]["native"]["artifact_hash"],
        "gguf_pool_model_id": run["entries"]["gguf"]["pool_model_id"],
        "gguf_artifact_hash": run["entries"]["gguf"]["artifact_hash"],
        "manifest_version": latest["manifest_version"],
        "manifest_core_digest": latest["manifest_core_digest"],
        "pricing_bounds_sha256": bounds_digest(bounds) if bounds_ok else "0" * 64,
        "fingerprint_salt": salt,
    }
    evidence["observations"] = {**TRUSTED_POOL_MODEL_FIXED_OBSERVATIONS, "buyer_visible_usage_equals_debit": False}
    # The observations are derived by the validator; fill them, then check.
    evidence["observations"] = validate_evidence(evidence, now=datetime.now(timezone.utc), fill_observations=True)
    reject_raw_identifiers(evidence, run)
    for name, payload in bundle.items():
        event = base.parse_json_bytes(payload, name)
        base.reject_forbidden_secret_keys(event, f"bundle.{name}")
    return evidence, bundle


def reject_raw_identifiers(evidence: dict[str, Any], run: dict[str, Any]) -> None:
    text = json.dumps(evidence, sort_keys=True)
    for field in RAW_IDENTITY_FIELDS:
        if run[field] in text:
            die(f"redacted evidence would contain the raw {field}")


# ---- the semantic validator (capture and payload) ----


def derived_steps() -> list[dict[str, Any]]:
    return [
        {"id": step_id, "status": "pass", "assertion": STEP_ASSERTIONS[step_id], "artifacts": [ARTIFACT_ID]}
        for step_id in TRUSTED_POOL_MODEL_STEP_ID_ORDER
    ]


class Journey:
    """The validated, cross-indexed view of one evidence document."""

    def __init__(self, ev: dict[str, Any]) -> None:
        self.ev = ev
        self.ids = ev["identities"]
        self.pool_id = ev["candidate_identity"]["pool_id"]
        self.entries = ev["entries"]
        self.roles = ev["roles"]
        self.manifests = {m["manifest_version"]: m for m in ev["manifests"]}

    def entry_kind(self, pool_model_id: Any, where: str) -> str:
        for kind, entry in self.entries.items():
            if entry["pool_model_id"] == pool_model_id:
                return kind
        die(f"{where}: pool_model_id must be one of the journey's entries")
        raise AssertionError

    def manifest(self, version: int, where: str) -> dict[str, Any]:
        if version not in self.manifests:
            die(f"{where}: manifest version {version} must be captured (pool/v{version}/) and verified")
        return self.manifests[version]

    def activation_ms(self, role: str) -> int:
        return self.manifests[self.roles[role]]["not_before_unix"] * 1000

    def role_of(self, version: int, where: str) -> str:
        """The role whose terms are in force at a version: the latest role
        manifest at or below it, with an equal policy terms digest."""
        manifest = self.manifest(version, where)
        candidates = [role for role in MANIFEST_ROLES if self.roles[role] <= version]
        require(bool(candidates), f"{where}: manifest_version {version} precedes native_genesis")
        role = max(candidates, key=lambda r: self.roles[r])
        require(manifest["manifest_terms_digest"] == self.manifests[self.roles[role]]["manifest_terms_digest"],
                f"{where}: manifest_version {version} terms must equal the {role} manifest's terms")
        return role

    def entry_at(self, version: int, pool_model_id: str, where: str) -> dict[str, Any]:
        for entry in self.manifest(version, where)["model_entries"]:
            if entry["pool_model_id"] == pool_model_id:
                return entry
        die(f"{where}: the entry must be in the version {version} core")
        raise AssertionError

    def attested_at(self, version: int) -> dict[str, list[str]]:
        return {m["account_fingerprint"]: m["runtime_classes"] for m in self.manifests[version]["attested_members"]}


def check_header(ev: dict[str, Any], now: datetime) -> None:
    obj(ev, {
        "schema_version", "journey_id", "run_id", "requirement_ids", "repository", "captured_at", "expires_at", "operator",
        "environment", "result", "steps", "redaction", "observations", "candidate_identity", "identities", "entries", "roles",
        "preconditions", "deploy_order", "pricing_bounds", "owner_authority", "manifest_root", "manifests", "pool_state",
        "event_counts", "proposals", "admission", "models", "requests", "refusals", "window_probes", "rollback_preflight",
        "restart", "raw_documents",
    }, "evidence")
    require(ev["schema_version"] == EVIDENCE_SCHEMA, f"schema_version must equal {EVIDENCE_SCHEMA!r}")
    require(ev["journey_id"] == JOURNEY_ID, f"journey_id must equal {JOURNEY_ID!r}")
    require_string(ev["run_id"], RUN_ID_RE, "run_id")
    require(ev["requirement_ids"] == sorted(TRUSTED_POOL_MODEL_PROMOTABLE_REQUIREMENT_IDS), "requirement_ids must be the journey's promotable set")
    repository = obj(ev["repository"], {"name", "commit"}, "repository")
    require(repository["name"] == REPOSITORY, f"repository.name must equal {REPOSITORY!r}")
    require_string(repository["commit"], COMMIT_RE, "repository.commit")
    captured = z_seconds(ev["captured_at"], "captured_at")
    expires = date.fromisoformat(require_string(ev["expires_at"], DATE_RE, "expires_at"))
    captured_day = datetime.fromtimestamp(captured, timezone.utc).date()
    require(captured <= int(now.timestamp()) + 300, "captured_at must not be in the future")
    require(captured_day <= expires <= captured_day + timedelta(days=MAX_EVIDENCE_DAYS),
            f"expires_at must be within {MAX_EVIDENCE_DAYS} days of captured_at")
    operator = obj(ev["operator"], {"role", "identity_fingerprint"}, "operator")
    require_string(operator["role"], SHORT_TOKEN_RE, "operator.role")
    hex64(operator["identity_fingerprint"], "operator.identity_fingerprint")
    environment = obj(ev["environment"], {"class", "hardware_profile", "candidate"}, "environment")
    require(environment["class"] == TRUSTED_POOL_MODEL_EXECUTION_MODE, f"environment.class must equal {TRUSTED_POOL_MODEL_EXECUTION_MODE!r}")
    require_string(environment["hardware_profile"], SHORT_TOKEN_RE, "environment.hardware_profile")
    require_string(environment["candidate"], ACCEPTED_ID_RE, "environment.candidate")
    require(ev["result"] == {"status": "pass", "summary": SUMMARY}, "result must be the derived pass result")
    require(ev["steps"] == derived_steps(), "steps must be the derived physical steps")
    require(ev["redaction"] == {"secrets_redacted": True, "operator_identity_redacted": True, "local_account_names_redacted": True},
            "redaction must be the fixed redaction record")
    identity = obj(ev["candidate_identity"], TRUSTED_POOL_MODEL_CANDIDATE_IDENTITY_KEYS, "candidate_identity")
    for field in TRUSTED_POOL_MODEL_SHA256_IDENTITY_KEYS:
        hex64(identity[field], f"candidate_identity.{field}")
    require(identity["accepted_id"] == environment["candidate"], "candidate_identity.accepted_id must equal environment.candidate")
    require_string(identity["coordinator_version"], VERSION_RE, "candidate_identity.coordinator_version")
    require_string(identity["llama_server_build"], re.compile(r"^b[0-9]+$"), "candidate_identity.llama_server_build")
    require_string(identity["pool_id"], POOL_ID_RE, "candidate_identity.pool_id")
    int_in(identity["manifest_version"], "candidate_identity.manifest_version", 1)
    obj(ev["identities"], {
        "creator_fingerprint", "buyer_fingerprint", "native_provider_fingerprint", "native_account_fingerprint",
        "gguf_provider_fingerprint", "gguf_account_fingerprint", "other_pool_fingerprint",
    }, "identities")
    entries = obj(ev["entries"], set(ENTRY_KINDS), "entries")
    for kind, spec in ENTRY_KINDS.items():
        entry = obj(entries[kind], {"pool_model_id", "artifact_hash", "algorithm"}, f"entries.{kind}")
        prefix = f"pool/{identity['pool_id']}/"
        require(isinstance(entry["pool_model_id"], str) and entry["pool_model_id"].startswith(prefix)
                and SLUG_RE.fullmatch(entry["pool_model_id"][len(prefix):]) is not None, f"entries.{kind}.pool_model_id must be pool/<pool_id>/<slug>")
        hex64(entry["artifact_hash"], f"entries.{kind}.artifact_hash")
        require(entry["algorithm"] == spec["algorithm"], f"entries.{kind}.algorithm must be {spec['algorithm']}")
        require(identity[f"{kind}_pool_model_id"] == entry["pool_model_id"] and identity[f"{kind}_artifact_hash"] == entry["artifact_hash"],
                f"candidate_identity {kind} entry must equal entries.{kind}")
    require(entries["native"]["pool_model_id"] != entries["gguf"]["pool_model_id"], "the two entries must differ")
    require(entries["native"]["artifact_hash"] != entries["gguf"]["artifact_hash"], "the two entries must hash differently")
    ids = ev["identities"]
    require(ids["native_provider_fingerprint"] != ids["gguf_provider_fingerprint"], "the native and GGUF members must be different providers")
    for kind in ENTRY_KINDS:
        require(ids[f"{kind}_account_fingerprint"] != ids["creator_fingerprint"], f"the {kind} member's account must not be the creator (a non-creator member)")


def check_roles(j: Journey) -> None:
    roles = obj(j.roles, set(MANIFEST_ROLES), "roles")
    for role in MANIFEST_ROLES:
        int_in(roles[role], f"roles.{role}", 1)
    # Only these orderings are fixed (the Pearl run: genesis, window,
    # price change, entry removal, GGUF added, keepers, attestation removal).
    require(len(set(roles.values())) == len(roles), "manifest_versions must name six different manifests")
    require(all(roles["native_genesis"] < roles[role] for role in MANIFEST_ROLES[1:]), "manifest_versions.native_genesis must be the smallest")
    require(roles["window_rotation"] < roles["price_change"] < roles["entry_removal"],
            "manifest_versions must order window_rotation < price_change < entry_removal")
    require(roles["attestation_removal"] > roles["gguf_added"], "manifest_versions.attestation_removal must follow gguf_added")


def check_entry_grammar(entry: dict[str, Any], manifest: dict[str, Any], where: str) -> None:
    obj(entry, set(ENTRY_KEYS), where)
    prefix = f"pool/{manifest['pool_id']}/"
    require(isinstance(entry["pool_model_id"], str) and entry["pool_model_id"].startswith(prefix)
            and SLUG_RE.fullmatch(entry["pool_model_id"][len(prefix):]) is not None, f"{where}.pool_model_id must be pool/<pool_id>/<slug>")
    require(entry["artifact_hash_algorithm"] in (GGUF_ALGORITHM, SNAPSHOT_ALGORITHM), f"{where}.artifact_hash_algorithm")
    hex64(entry["artifact_hash"], f"{where}.artifact_hash")
    sources = list_of(entry["allowed_runtime_sources"], f"{where}.allowed_runtime_sources")
    require(bool(sources) and sources == sorted(set(sources)), f"{where}.allowed_runtime_sources must be sorted and unique")
    for source in sources:
        require(RUNTIME_FORMAT.get(source) == entry["artifact_hash_algorithm"], f"{where}: runtime {source!r} does not pair with the hash format")
        require(source == NATIVE_RUNTIME or source in manifest["runtime_allowlist"], f"{where}: loopback runtime {source!r} must be allowlisted")
    require_string(entry["license"], LICENSE_RE, f"{where}.license")
    require(entry["paid_serving_attested"] is True, f"{where}.paid_serving_attested must be true")
    for rate in RATE_KEYS:
        int_in(entry[rate], f"{where}.{rate}")
    require(entry["prompt_cache_hit_rate_per_mtok"] <= entry["prompt_rate_per_mtok"], f"{where}: cache-hit rate must be at most the prompt rate")
    require(entry["disclosure_class"] == DISCLOSURE_CLASS, f"{where}.disclosure_class")
    int_in(entry["max_context_tokens"], f"{where}.max_context_tokens", 1, MAX_POOL_MODEL_CONTEXT)


def check_manifests(j: Journey, ev: dict[str, Any]) -> None:
    root = obj(ev["manifest_root"], {"pool_id", "creator_fingerprint", "launch_environment",
                                     "root_issuer_public_key_fingerprint", "root_event_sha256"}, "manifest_root")
    require(root["pool_id"] == j.pool_id, "the root registration must be the journey pool's")
    require(root["creator_fingerprint"] == j.ids["creator_fingerprint"], "the root registration's creator must be the journey creator")
    require(root["launch_environment"] == "candidate", "the root registration must be a candidate pool")
    hex64(root["root_issuer_public_key_fingerprint"], "manifest_root.root_issuer_public_key_fingerprint")
    hex64(root["root_event_sha256"], "manifest_root.root_event_sha256")
    versions = [m.get("manifest_version") if isinstance(m, dict) else None for m in list_of(ev["manifests"], "manifests")]
    require(all(is_int(v) and v >= 1 for v in versions) and versions == sorted(set(versions)), "manifests must be unique and in version order")
    for version, manifest in j.manifests.items():
        where = f"manifests[v{version}]"
        obj(manifest, {
            "manifest_version", "manifest_core_digest", "manifest_terms_digest", "prev_manifest_core_hash", "event_sha256",
            "not_before_unix", "expires_at_unix", "encoding", "settlement_mode", "runtime_allowlist", "model_entries",
            "attested_members",
        }, where)
        for field in ("manifest_core_digest", "manifest_terms_digest", "prev_manifest_core_hash", "event_sha256"):
            hex64(manifest[field], f"{where}.{field}")
        start = int_in(manifest["not_before_unix"], f"{where}.not_before_unix", 1)
        require(int_in(manifest["expires_at_unix"], f"{where}.expires_at_unix", 1) > start, f"{where}: window must be non-empty")
        require(manifest["encoding"] == 2, f"{where}: the core must be a v2 policy core")
        require(manifest["settlement_mode"] == "enforce", f"{where}: settlement_mode must be enforce")
        allowlist = list_of(manifest["runtime_allowlist"], f"{where}.runtime_allowlist")
        require("llamacpp_loopback" in allowlist and allowlist == sorted(set(allowlist)), f"{where}: runtime_allowlist must allow llamacpp_loopback")
        if version - 1 in j.manifests:
            require(manifest["prev_manifest_core_hash"] == j.manifests[version - 1]["manifest_core_digest"],
                    f"{where}: prev_manifest_core_hash must chain to version {version - 1}")
            require(start >= j.manifests[version - 1]["not_before_unix"], f"{where}: windows must not go back in time")
        ids = [e.get("pool_model_id") for e in list_of(manifest["model_entries"], f"{where}.model_entries") if isinstance(e, dict)]
        require(ids == sorted(set(ids)) and len(ids) == len(manifest["model_entries"]), f"{where}: model entries must be sorted and unique")
        for index, entry in enumerate(manifest["model_entries"]):
            check_entry_grammar(entry, {**manifest, "pool_id": j.pool_id}, f"{where}.model_entries[{index}]")
        accounts = []
        for index, member in enumerate(list_of(manifest["attested_members"], f"{where}.attested_members")):
            member = obj(member, {"account_fingerprint", "runtime_classes"}, f"{where}.attested_members[{index}]")
            accounts.append(hex64(member["account_fingerprint"], f"{where}.attested_members[{index}].account_fingerprint"))
            classes = list_of(member["runtime_classes"], f"{where}.attested_members[{index}].runtime_classes")
            require(bool(classes) and classes == sorted(set(classes)) and all(c in allowlist for c in classes),
                    f"{where}.attested_members[{index}].runtime_classes must be sorted, unique and allowlisted")
        require(len(set(accounts)) == len(accounts), f"{where}: attested members must be unique")
    for role in MANIFEST_ROLES:
        j.manifest(j.roles[role], f"role {role}")
    # Every other captured manifest is a window-only keeper rotation of the
    # latest role manifest below it: equal terms, entries and attestations.
    role_versions = set(j.roles.values())
    for version, manifest in j.manifests.items():
        if version in role_versions:
            continue
        role = j.role_of(version, f"manifests[v{version}]")
        source = j.manifests[j.roles[role]]
        require(manifest["model_entries"] == source["model_entries"] and manifest["attested_members"] == source["attested_members"],
                f"manifests[v{version}]: a keeper rotation must keep the {role} manifest's entries and attestations")
    latest = j.manifests[max(j.manifests)]
    identity = ev["candidate_identity"]
    require(identity["manifest_version"] == latest["manifest_version"] and identity["manifest_core_digest"] == latest["manifest_core_digest"],
            "candidate_identity manifest must be the newest verified manifest")

    native, gguf = j.entries["native"], j.entries["gguf"]
    gguf_account = j.ids["gguf_account_fingerprint"]

    def entry_ids(role: str) -> list[str]:
        return [e["pool_model_id"] for e in j.manifests[j.roles[role]]["model_entries"]]

    def prior(role: str) -> str:
        earlier = [r for r in MANIFEST_ROLES if j.roles[r] < j.roles[role]]
        return max(earlier, key=lambda r: j.roles[r])

    def check_identity(role: str, kind: str) -> None:
        entry = j.entry_at(j.roles[role], j.entries[kind]["pool_model_id"], f"role {role}")
        require(entry["artifact_hash"] == j.entries[kind]["artifact_hash"] and entry["artifact_hash_algorithm"] == ENTRY_KINDS[kind]["algorithm"],
                f"role {role}: the {kind} entry must have the journey's exact artifact identity")
        engine = ENTRY_KINDS[kind]["engine"]
        require(engine in entry["allowed_runtime_sources"], f"role {role}: the {kind} entry must allow {engine}")

    # Exact role-specific entry and attestation sets (SPEC-042-R015/R016).
    require(entry_ids("native_genesis") == [native["pool_model_id"]], "native_genesis must carry exactly the native entry")
    check_identity("native_genesis", "native")
    for role in MANIFEST_ROLES:
        version = j.roles[role]
        attested = j.attested_at(version)
        live_attestation = j.roles["gguf_added"] <= version < j.roles["attestation_removal"]
        want = {gguf_account: ["llamacpp_loopback"]} if live_attestation else {}
        require(attested == want, f"role {role}: attested members must be exactly {'the GGUF owner for llamacpp_loopback' if want else 'none'}")
        if gguf["pool_model_id"] in entry_ids(role):
            require(version >= j.roles["gguf_added"], f"role {role}: the GGUF entry must not precede gguf_added")
            check_identity(role, "gguf")
        if native["pool_model_id"] in entry_ids(role):
            check_identity(role, "native")
        require(set(entry_ids(role)) <= {native["pool_model_id"], gguf["pool_model_id"]}, f"role {role}: no foreign entries")
    require(entry_ids("gguf_added") == sorted([native["pool_model_id"], gguf["pool_model_id"]]), "gguf_added must carry exactly both entries")
    window, before_window = j.manifests[j.roles["window_rotation"]], j.manifests[j.roles[prior("window_rotation")]]
    require(window["manifest_terms_digest"] == before_window["manifest_terms_digest"], "window_rotation must keep the policy terms digest")
    require(window["manifest_core_digest"] != before_window["manifest_core_digest"], "window_rotation must be a new core")
    require(window["model_entries"] == before_window["model_entries"] and window["attested_members"] == before_window["attested_members"],
            "window_rotation must keep entries and attestations")
    price, before_price = j.manifests[j.roles["price_change"]], j.manifests[j.roles[prior("price_change")]]
    require(price["manifest_terms_digest"] != before_price["manifest_terms_digest"], "price_change must change the policy terms digest")
    require([e["pool_model_id"] for e in price["model_entries"]] == [e["pool_model_id"] for e in before_price["model_entries"]]
            and price["attested_members"] == before_price["attested_members"], "price_change must keep entries and attestations")
    changed = [after for after, was in zip(price["model_entries"], before_price["model_entries"]) if after != was]
    require(len(changed) == 1, "price_change must change exactly one entry")
    was = next(e for e in before_price["model_entries"] if e["pool_model_id"] == changed[0]["pool_model_id"])
    require({k: v for k, v in was.items() if k not in RATE_KEYS} == {k: v for k, v in changed[0].items() if k not in RATE_KEYS}
            and any(was[r] != changed[0][r] for r in RATE_KEYS), "price_change must change only the entry's rates")
    j.price_changed = changed[0]["pool_model_id"]
    before_removal = entry_ids(prior("entry_removal"))
    require(native["pool_model_id"] in before_removal, "the native entry must be present in the manifest before entry_removal")
    require(entry_ids("entry_removal") == [i for i in before_removal if i != native["pool_model_id"]],
            "entry_removal must remove exactly the native entry")
    require(j.attested_at(j.roles[prior("attestation_removal")]).get(gguf_account) is not None,
            "the GGUF owner must be attested in the manifest before attestation_removal")
    require(entry_ids("attestation_removal") == entry_ids(prior("attestation_removal")), "attestation_removal must keep the entries")


def check_pool_state(j: Journey, ev: dict[str, Any]) -> None:
    states = obj(ev["pool_state"], {str(j.roles[role]) for role in MANIFEST_ROLES}, "pool_state")
    for role in MANIFEST_ROLES:
        version = j.roles[role]
        where = f"pool_state[v{version}]"
        state = obj(states[str(version)], {
            "manifest_version", "manifest_core_digest", "lifecycle", "routeable", "launch_environment", "settlement_mode",
            "runtime_allowlist", "creator_fingerprint", "pool_is_journey_pool", "model_entries", "attested_members",
            "member_fingerprints", "revoked_count", "buyer_authorized",
        }, where)
        manifest = j.manifests[version]
        require(state["pool_is_journey_pool"] is True, f"{where}: get-pool must be the journey pool")
        require(state["manifest_version"] == version and state["manifest_core_digest"] == manifest["manifest_core_digest"],
                f"{where}: get-pool must show the verified manifest version and digest")
        require(state["model_entries"] == manifest["model_entries"], f"{where}: get-pool entries must equal the verified core's")
        require(state["attested_members"] == manifest["attested_members"], f"{where}: get-pool attested members must equal the verified core's")
        require(state["settlement_mode"] == "enforce" and state["runtime_allowlist"] == manifest["runtime_allowlist"],
                f"{where}: get-pool policy must equal the verified core's")
        require(state["launch_environment"] == "candidate", f"{where}: launch_environment must be candidate")
        require(state["creator_fingerprint"] == j.ids["creator_fingerprint"], f"{where}: creator must be the journey creator")
        require(state["buyer_authorized"] is True, f"{where}: the buyer must be authorized")
        require(state["lifecycle"] in ("active", "paused") and isinstance(state["routeable"], bool), f"{where}: lifecycle")
        require(bool(state["member_fingerprints"]), f"{where}: the pool must have members")
        for fp in list_of(state["member_fingerprints"], f"{where}.member_fingerprints"):
            hex64(fp, f"{where}.member_fingerprints")
        int_in(state["revoked_count"], f"{where}.revoked_count")
    genesis = states[str(j.roles["native_genesis"])]
    require(genesis["lifecycle"] == "active" and genesis["routeable"] is True, "native_genesis get-pool must be active and routeable")
    require(j.ids["native_provider_fingerprint"] in genesis["member_fingerprints"], "native_genesis members must include the native member")
    added = states[str(j.roles["gguf_added"])]
    for kind in ENTRY_KINDS:
        require(j.ids[f"{kind}_provider_fingerprint"] in added["member_fingerprints"], f"gguf_added members must include the {kind} member")
    counts = ev["event_counts"]
    require(isinstance(counts, dict) and all(TOKEN_RE.fullmatch(k) and is_int(v) and v >= 0 for k, v in counts.items()), "event_counts")
    for event_type, want in (("pool_created", 1), ("root_issuer_registered", 1)):
        require(counts.get(event_type) == want, f"pool history must have exactly {want} {event_type}")
    for event_type, at_least in (("manifest_accepted", max(j.manifests)), ("member_admitted", 2), ("buyer_authorized", 1),
                                 ("delegation_granted", 2), ("lifecycle_changed", 2)):
        require(counts.get(event_type, 0) >= at_least, f"pool history must have at least {at_least} {event_type}")


def check_preconditions(j: Journey, ev: dict[str, Any]) -> None:
    pre = obj(ev["preconditions"], set(PRECONDITION_IDS), "preconditions")
    identity = ev["candidate_identity"]
    for key, facts in PRECONDITION_FACTS.items():
        item = obj(pre[key], {"status", "observed", "checked_at"}, f"preconditions.{key}")
        require(item["status"] == "pass", f"preconditions.{key}.status must equal 'pass'")
        z_seconds(item["checked_at"], f"preconditions.{key}.checked_at")
        observed = obj(item["observed"], set(facts), f"preconditions.{key}.observed")
        for name, want in facts.items():
            if want is not None:
                require(observed[name] is want, f"preconditions.{key}.observed.{name} must be {want!r}")
    observed = pre["deploy-build"]["observed"]
    require(observed["coordinator_version"] == identity["coordinator_version"], "preconditions.deploy-build coordinator_version must equal the candidate's")
    require_string(observed["gateway_version"], VERSION_RE, "preconditions.deploy-build.observed.gateway_version")
    require(observed["contains_commit"] == ev["repository"]["commit"][:12], "preconditions.deploy-build contains_commit must be the source commit's first 12 hex")
    deploy = obj(ev["deploy_order"], {"coordinator_deployed_at", "gateway_deployed_at", "native_member_cli_installed_at",
                                      "gguf_member_cli_installed_at"}, "deploy_order")
    for key, value in deploy.items():
        int_in(value, f"deploy_order.{key}", 1)
    require(deploy["coordinator_deployed_at"] <= deploy["gateway_deployed_at"], "deploy order: the coordinator deploys before the gateway")
    for key in ("native_member_cli_installed_at", "gguf_member_cli_installed_at"):
        require(deploy["gateway_deployed_at"] <= deploy[key], f"deploy order: the gateway deploys before {key}")


def check_pricing(j: Journey, ev: dict[str, Any]) -> dict[str, Any]:
    bounds = obj(ev["pricing_bounds"], set(BOUNDS_KEYS), "pricing_bounds")
    for key in BOUNDS_KEYS:
        int_in(bounds[key], f"pricing_bounds.{key}")
    for rate in RATE_KEYS:
        require(bounds[f"min_{rate}"] <= bounds[f"max_{rate}"], f"pricing bounds min_{rate} must be at most max_{rate}")
    multipliers = {row["pool_model_global_multiplier_ppm"] for item in ev["requests"].values() for row in item["route_snapshots"]}
    require(len(multipliers) == 1, "every pool route must carry one global multiplier")
    multiplier = int_in(next(iter(multipliers)), "pool_model_global_multiplier_ppm", 1)
    for rate in RATE_KEYS:
        require(bounds[f"max_{rate}"] * BOUNDS_DIGEST_TOKENS * multiplier <= INT64_MAX,
                f"pricing bounds max_{rate} times the context ceiling and multiplier must fit int64")
    digest = bounds_digest(bounds)
    require(ev["candidate_identity"]["pricing_bounds_sha256"] == digest, "candidate_identity.pricing_bounds_sha256 must be the recomputed bounds digest")
    for version, manifest in j.manifests.items():
        for entry in manifest["model_entries"]:
            for rate in RATE_KEYS:
                require(bounds[f"min_{rate}"] <= entry[rate] <= bounds[f"max_{rate}"],
                        f"version {version} entry {entry['pool_model_id']} {rate} must be inside the configured bounds")
    owner = obj(ev["owner_authority"], {"reload", "owner_map_digest_recomputed", "gguf_provider_owner_fingerprint"}, "owner_authority")
    reload = obj(owner["reload"], {"bounds_set", "provider_owner_account_ids_applied", "provider_owner_account_ids_providers",
                                   "provider_owner_account_ids_sha256"}, "owner_authority.reload")
    require(reload["bounds_set"] is True and reload["provider_owner_account_ids_applied"] is True, "the bounds and owner map reload must have applied")
    int_in(reload["provider_owner_account_ids_providers"], "owner_authority providers", 1)
    hex64(reload["provider_owner_account_ids_sha256"], "owner_authority sha256")
    require(owner["owner_map_digest_recomputed"] is True, "the owner map digest must have been recomputed")
    # SPEC-042-R016 owner join: provider -> recorded owner -> attested account.
    require(owner["gguf_provider_owner_fingerprint"] == j.ids["gguf_account_fingerprint"],
            "the GGUF member's recorded owner account must be the attested account")
    return {"bounds_digest": digest, "multiplier": multiplier}


def check_proposals(j: Journey, ev: dict[str, Any]) -> None:
    proposals = obj(ev["proposals"], set(ENTRY_KINDS), "proposals")
    for kind, spec in ENTRY_KINDS.items():
        p = obj(proposals[kind], {"schema", "pool_id", "runtime_source", "catalog_model_key_null", "pool_model_id",
                                  "artifact_hash_algorithm", "artifact_hash", "creator_fields_null"}, f"proposals.{kind}")
        require(p["schema"] == "pool_model_proposal.v1" and p["pool_id"] == j.pool_id, f"proposals.{kind} must be the pool's proposal bundle")
        require(p["runtime_source"] == spec["engine"], f"proposals.{kind} runtime_source must be {spec['engine']}")
        require(p["catalog_model_key_null"] is True, f"proposals.{kind} must be an unmatched (non-catalog) model")
        require(p["pool_model_id"] == j.entries[kind]["pool_model_id"] and p["artifact_hash"] == j.entries[kind]["artifact_hash"]
                and p["artifact_hash_algorithm"] == spec["algorithm"], f"proposals.{kind} artifact identity must be the signed entry's")
        require(p["creator_fields_null"] is True, f"proposals.{kind} leaves licence and paid serving to the creator")


def exact_actor(j: Journey, row: dict[str, Any], where: str) -> None:
    version = row["pool_manifest_version"]
    require(is_int(version), f"{where}: pool_manifest_version")
    manifest = j.manifest(version, where)
    require(row["pool_manifest_core_digest"] == manifest["manifest_core_digest"], f"{where}: the binding must name the verified core")
    require(row["actor"] == f"pool_manifest:{j.pool_id}:{version}:{manifest['manifest_core_digest']}",
            f"{where}: actor must be exactly pool_manifest:<pool>:<version>:<core digest>")
    require(row["created_at_unix_ms"] >= manifest["not_before_unix"] * 1000, f"{where}: the binding must follow its core's activation")


def check_admission(j: Journey, ev: dict[str, Any]) -> dict[str, Any]:
    rows = list_of(ev["admission"], "admission")
    for index, row in enumerate(rows):
        obj(row, {"id", "provider", "state", "reason_code", "actor", "binding_scope", "pool_id", "pool_model_id",
                  "pool_manifest_version", "pool_manifest_core_digest", "expected_catalog_model_hash_algorithm",
                  "expected_catalog_model_hash", "created_at_unix_ms"}, f"admission[{index}]")
        require(row["provider"] in ENTRY_KINDS, f"admission[{index}].provider")
        token(row["state"], f"admission[{index}].state")
        if row["reason_code"] is not None:
            token(row["reason_code"], f"admission[{index}].reason_code")
        int_in(row["created_at_unix_ms"], f"admission[{index}].created_at_unix_ms", 1)
        require(row["pool_id"] in (None, j.pool_id), f"admission[{index}]: no foreign pool binding")
    ids = [row["id"] for row in rows]
    require(all(is_int(i) for i in ids) and ids == sorted(set(ids)), "admission events must be unique and in id order")
    out: dict[str, Any] = {}

    def binds(row: dict[str, Any], kind: str, reason: str) -> bool:
        entry = j.entries[kind]
        return (row["state"] == "catalog_priced" and row["binding_scope"] == "pool" and row["reason_code"] == reason
                and row["pool_id"] == j.pool_id and row["pool_model_id"] == entry["pool_model_id"]
                and row["expected_catalog_model_hash"] == entry["artifact_hash"]
                and row["expected_catalog_model_hash_algorithm"] == entry["algorithm"])

    def head_of(revoked: dict[str, Any], mine: list[dict[str, Any]]) -> bool:
        earlier = [r for r in mine if r["id"] < revoked["id"] and r["state"] == "catalog_priced"]
        return bool(earlier) and all(earlier[-1][f] == revoked[f] for f in (
            "pool_model_id", "pool_manifest_version", "pool_manifest_core_digest"))

    for kind in ENTRY_KINDS:
        mine = [row for row in rows if row["provider"] == kind]
        require(all(row["state"] != "settlement_capable" for row in mine), f"the {kind} member must never reach settlement_capable")
        bound = [row for row in mine if binds(row, kind, "pool_manifest_bound")]
        require(bool(bound), f"the {kind} member's offer must bind pool-scoped catalog_priced under the signed-manifest actor")
        for row in mine:
            if row["state"] == "catalog_priced":
                require(row["actor"] == f"pool_manifest:{j.pool_id}:{row['pool_manifest_version']}:{row['pool_manifest_core_digest']}",
                        f"admission id {row['id']}: a pool binding's actor must name its own pool, version and core")
        exact_actor(j, bound[0], f"admission id {bound[0]['id']}")
        out[kind] = {
            "bound": True,
            "unmatched_offer_before_bind": any(r["state"] in PRE_BIND_STATES and r["id"] < bound[0]["id"] for r in mine),
        }
    native_rows = [row for row in rows if row["provider"] == "native"]
    window_version = j.roles["window_rotation"]
    rebound = [row for row in native_rows if binds(row, "native", "pool_manifest_rebound") and row["pool_manifest_version"] == window_version]
    require(bool(rebound), "the delegated native member must be rebound at the window_rotation version")
    exact_actor(j, rebound[0], f"admission id {rebound[0]['id']}")

    # Price change: a substantive change revokes the delegated member's
    # binding; re-delegation alone does not rebind, so it re-offers and binds
    # under the price_change terms.
    changed_kind = j.entry_kind(j.price_changed, "price_change")
    mine = [row for row in rows if row["provider"] == changed_kind]
    price_on, removal_on = j.activation_ms("price_change"), j.activation_ms("entry_removal")
    rebind = None
    for revoked in (r for r in mine if r["state"] == "revoked" and r["reason_code"] == "pool_membership_revoked"
                    and price_on <= r["created_at_unix_ms"] and head_of(r, mine)):
        offers = [r for r in mine if r["state"] == "offer_submitted" and r["id"] > revoked["id"]]
        if not offers:
            continue
        for bound in mine:
            if bound["id"] > offers[0]["id"] and binds(bound, changed_kind, "pool_manifest_bound") \
                    and j.role_of(bound["pool_manifest_version"], "price-change rebind") == "price_change":
                exact_actor(j, bound, f"admission id {bound['id']}")
                rebind = bound["pool_manifest_version"]
                break
        if rebind is not None:
            break
    require(rebind is not None,
            "after price_change the repriced entry's member must be revoked (pool_membership_revoked), re-offer, and bind under the price_change terms")
    # Entry removal: a delegated member's binding is revoked by the removal
    # (pool_manifest_entry_revoked) or, when the term change voided its grant
    # first, by pool_membership_revoked; either way after activation.
    removal = [r for r in native_rows if r["state"] == "revoked" and r["pool_model_id"] == j.entries["native"]["pool_model_id"]
               and r["reason_code"] in ("pool_manifest_entry_revoked", "pool_membership_revoked")
               and r["created_at_unix_ms"] >= removal_on and head_of(r, native_rows)]
    require(bool(removal), "entry removal must revoke the native binding after the removal activates")
    attestation_on = j.activation_ms("attestation_removal")
    gguf_rows = [row for row in rows if row["provider"] == "gguf"]
    revoked_member = [r for r in gguf_rows if r["state"] == "revoked" and r["reason_code"] == "pool_membership_revoked"
                      and r["created_at_unix_ms"] >= attestation_on and head_of(r, gguf_rows)]
    require(bool(revoked_member), "attestation removal must revoke the GGUF binding with pool_membership_revoked after it activates")
    out.update({
        "window_rotation_rebound_version": window_version,
        "price_change_reoffer_bound_version": rebind,
        "entry_removal_revoked_reason": removal[0]["reason_code"],
        "attestation_removal_revoked_reason": "pool_membership_revoked",
    })
    return out


def check_models(j: Journey, ev: dict[str, Any]) -> dict[str, Any]:
    models = obj(ev["models"], {"pool_view", "pool_view_other_count", "global_view_pool_ids", "global_view_pool_objects",
                                "never_global_count"}, "models")
    items = list_of(models["pool_view"], "models.pool_view")
    ids = [item.get("id") if isinstance(item, dict) else None for item in items]
    require(len(ids) == len(set(ids)), "the pool models view must not repeat an id")
    digests = set()
    multipliers = {row["pool_model_global_multiplier_ppm"] for item in ev["requests"].values() for row in item["route_snapshots"]}
    for index, item in enumerate(items):
        where = f"models.pool_view[{index}]"
        item = obj(item, {"id", "object", "pool_model"}, where)
        require(item["object"] == "model", f"{where}.object must be model")
        model = obj(item["pool_model"], {"pool_id", "pool_model_id", "artifact_hash_algorithm", "artifact_hash", "manifest_core_digest",
                                         "manifest_version", "runtime_sources", "disclosure_class", "disclosure_text", "price_source",
                                         "max_context_tokens", "price"}, f"{where}.pool_model")
        require(model["pool_id"] == j.pool_id and model["pool_model_id"] == item["id"] and isinstance(item["id"], str)
                and item["id"].startswith(f"pool/{j.pool_id}/"), f"{where}: pool and entry ids must be the selected pool's")
        version = int_in(model["manifest_version"], f"{where}.manifest_version", 1)
        manifest = j.manifest(version, where)
        require(model["manifest_core_digest"] == manifest["manifest_core_digest"], f"{where}: manifest_core_digest must be that version's")
        digests.add(version)
        entry = j.entry_at(version, item["id"], where)
        require(model["artifact_hash_algorithm"] == entry["artifact_hash_algorithm"] and model["artifact_hash"] == entry["artifact_hash"],
                f"{where}: artifact identity must be the signed entry's")
        require(model["disclosure_class"] == DISCLOSURE_CLASS and model["disclosure_text"] == DISCLOSURE_TEXT
                and model["price_source"] == PRICE_SOURCE, f"{where}: pool-attested disclosure")
        require(model["max_context_tokens"] == entry["max_context_tokens"], f"{where}: max_context_tokens must be the signed entry's")
        sources = list_of(model["runtime_sources"], f"{where}.runtime_sources")
        require(bool(sources) and sources == sorted(set(sources)) and set(sources) <= set(entry["allowed_runtime_sources"]),
                f"{where}: runtime_sources must be a sorted subset of the entry's")
        price = obj(model["price"], {*RATE_KEYS, "global_multiplier_ppm"}, f"{where}.price")
        for rate in RATE_KEYS:
            require(price[rate] == entry[rate], f"{where}: price.{rate} must equal the signed entry rate")
        require(price["global_multiplier_ppm"] in multipliers, f"{where}: price.global_multiplier_ppm must be the routes' multiplier")
    require(len(digests) == 1, "the pool models view must come from one manifest")
    version = next(iter(digests))
    want = sorted(e["pool_model_id"] for e in j.manifests[version]["model_entries"])
    require(sorted(ids) == want, "the pool models view must list exactly the signed entries of its manifest")
    require(want == sorted(e["pool_model_id"] for e in j.entries.values()), "the pool models view must be captured while both entries are live")
    int_in(models["pool_view_other_count"], "models.pool_view_other_count")
    require(models["global_view_pool_ids"] == [] and models["global_view_pool_objects"] == 0, "the global models view must list no pool model")
    require(models["never_global_count"] == 0, "never-global: no route snapshot may carry a pool_model_id without a pool")
    return {"manifest_version": version}


def check_paid(j: Journey, ev: dict[str, Any], name: str, want_kind: str | None, stream: bool, pricing: dict[str, Any]) -> dict[str, Any]:
    r = obj(ev["requests"][name], {"x_request_id", "date_unix", "status", "headers", "body", "request_log", "route_snapshots",
                                   "attempt_outputs", "receipt_verdicts", "ledger", "quota_reservations", "usage_events"}, name)
    rid = require_string(r["x_request_id"], REQUEST_ID_RE, f"{name}.x_request_id")
    int_in(r["date_unix"], f"{name}.date_unix", 1)
    require(r["status"] == 200, f"{name} response status must be 200")
    body = obj(r["body"], {"stream", "finish_reason", "content_sha256", "usage"}, f"{name}.body")
    require(body["stream"] is stream, f"{name} must be {'a streaming' if stream else 'a non-streaming'} request")
    token(body["finish_reason"], f"{name}.finish_reason")
    hex64(body["content_sha256"], f"{name}.content_sha256")
    usage = obj(body["usage"], {"prompt_tokens", "completion_tokens"}, f"{name}.usage")

    # Exact join: X-Request-ID -> request_log -> (request_id, attempt_n).
    log = list_of(r["request_log"], f"{name}.request_log")
    require(bool(log), f"{name} request_log must map the X-Request-ID")
    keys = set()
    for row in log:
        obj(row, {"request_id", "attempt_n", "external_request_id", "pool_id", "status"}, f"{name}.request_log")
        require(row["external_request_id"] == rid, f"{name}: every request_log row must carry the X-Request-ID")
        require(row["pool_id"] == j.pool_id, f"{name}: request_log must show the pool")
        require_string(row["request_id"], REQUEST_ID_RE, f"{name}.request_log.request_id")
        keys.add((row["request_id"], row["attempt_n"]))
    snapshots = list_of(r["route_snapshots"], f"{name}.route_snapshots")
    require(bool(snapshots), f"{name} must have route snapshots")
    kind = j.entry_kind(snapshots[0].get("pool_model_id"), name)
    if want_kind is not None:
        require(kind == want_kind, f"{name} must be served from the {want_kind} entry")
    spec, entry = ENTRY_KINDS[kind], j.entries[kind]
    headers = obj(r["headers"], {"engine", "model_disclosure", "pool_manifest_core_digest"}, f"{name}.headers")
    require(headers["engine"] == spec["engine"], f"{name} X-MacProvider-Engine must be {spec['engine']}")
    require(headers["model_disclosure"] == DISCLOSURE_CLASS, f"{name} X-MacProvider-Model-Disclosure must be {DISCLOSURE_CLASS}")
    by_key = {}
    for row in snapshots:
        where = f"{name} route snapshot attempt {row.get('attempt_n')}"
        obj(row, {
            "request_id", "attempt_n", "provider", "route_snapshot_mode", "route_snapshot_policy_version", "route_snapshot_digest",
            "pool_id", "model_id", "expected_model_hash_source", "pool_model_id", "manifest_version", "manifest_core_digest",
            "pool_generation", "runtime_source", "pool_operator_account_fp", "pool_member_account_fp",
            "expected_catalog_model_hash", "expected_catalog_model_hash_algorithm", "provider_reported_model_hash",
            "provider_reported_model_hash_algorithm", *(f"pool_model_{rate}" for rate in RATE_KEYS), "pool_model_pricing_bounds_sha256",
            "pool_model_global_multiplier_ppm", "pool_model_provider_share_bps", "route_decision_ts_unix_ms",
        }, where)
        key = (row["request_id"], row["attempt_n"])
        require(key in keys, f"{where}: the snapshot must belong to the mapped request")
        require(key not in by_key, f"{where}: one snapshot per attempt")
        by_key[key] = row
        require(row["provider"] == kind, f"{where}: provider must be the {kind} member")
        require(row["pool_id"] == j.pool_id and row["expected_model_hash_source"] == "pool_manifest", f"{where}: a pool_manifest-sourced pool route")
        require(row["pool_model_id"] == entry["pool_model_id"] and row["model_id"] == entry["pool_model_id"], f"{where}: the exact entry")
        require(row["expected_catalog_model_hash"] == entry["artifact_hash"] and row["provider_reported_model_hash"] == entry["artifact_hash"],
                f"{where}: expected and provider-reported hashes must be the entry's artifact_hash")
        require(row["expected_catalog_model_hash_algorithm"] == entry["algorithm"] and row["provider_reported_model_hash_algorithm"] == entry["algorithm"],
                f"{where}: hash algorithms must be {entry['algorithm']}")
        require(row["route_snapshot_policy_version"] == ROUTE_SNAPSHOT_V2 and row["route_snapshot_mode"] == "enforce", f"{where}: v2 enforce snapshot")
        hex64(row["route_snapshot_digest"], f"{where}.route_snapshot_digest")
        int_in(row["pool_generation"], f"{where}.pool_generation", 1)
        int_in(row["route_decision_ts_unix_ms"], f"{where}.route_decision_ts_unix_ms", 1)
        version = row["manifest_version"]
        j.role_of(version, where)
        require(row["manifest_core_digest"] == j.manifests[version]["manifest_core_digest"], f"{where}: manifest_core_digest must be version {version}'s")
        signed = j.entry_at(version, entry["pool_model_id"], where)
        for rate in RATE_KEYS:
            require(row[f"pool_model_{rate}"] == signed[rate], f"{where}: pool_model_{rate} must equal the signed entry rate")
        require(row["pool_model_pricing_bounds_sha256"] == pricing["bounds_digest"], f"{where}: the route must carry the recomputed bounds digest")
        require(row["pool_model_global_multiplier_ppm"] == pricing["multiplier"], f"{where}: the route multiplier")
        int_in(row["pool_model_provider_share_bps"], f"{where}.pool_model_provider_share_bps", 0, 10000)
        if spec["route_runtime_source"] is None:
            # SPEC-022 R-13.5: a native mlx_cache route carries no runtime_source.
            for field in ("runtime_source", "pool_operator_account_fp", "pool_member_account_fp"):
                require(row[field] is None, f"{where}: a native route carries no {field}")
        else:
            require(row["runtime_source"] == spec["route_runtime_source"], f"{where}: runtime_source must be {spec['route_runtime_source']}")
            require(row["pool_operator_account_fp"] == j.ids["creator_fingerprint"], f"{where}: pool_operator_account must be the creator")
            require(row["pool_member_account_fp"] == j.ids["gguf_account_fingerprint"], f"{where}: pool_member_account must be the attested owner")
            require("llamacpp_loopback" in j.attested_at(version).get(j.ids["gguf_account_fingerprint"], []),
                    f"{where}: the member's owner must be attested for llamacpp_loopback at version {version}")

    outputs = list_of(r["attempt_outputs"], f"{name}.attempt_outputs")
    for row in outputs:
        obj(row, {"request_id", "attempt_n", "provider", "terminal_state", "usage_source", "terminal_state_ts_unix_ms"}, f"{name}.attempt_outputs")
        require((row["request_id"], row["attempt_n"]) in by_key, f"{name}: every attempt output must join a route snapshot")
    settled = [row for row in outputs if row["usage_source"] == spec["usage_source"] and row["terminal_state"] == "normal_done"]
    require(len(settled) == 1, f"{name} must have exactly one {spec['usage_source']} normal_done attempt output")
    key = (settled[0]["request_id"], settled[0]["attempt_n"])
    snapshot = by_key[key]
    require(settled[0]["provider"] == kind, f"{name}: the settled attempt must be the {kind} member's")
    verdicts = [row for row in list_of(r["receipt_verdicts"], f"{name}.receipt_verdicts")
                if (obj(row, {"request_id", "attempt_n", "provider", "receipt_result", "settlement_outcome", "reason", "closed",
                              "pool_label_status", "route_snapshot_digest", "provider_reported_model_hash",
                              "expected_catalog_model_hash", "model_id", "model_hash", "received_at_unix_ms"}, f"{name}.receipt_verdicts")
                    and (row["request_id"], row["attempt_n"]) == key)]
    require(len(verdicts) == 1, f"{name} settled attempt must have exactly one receipt verdict")
    verdict = verdicts[0]
    for field, want in (("receipt_result", "valid"), ("settlement_outcome", "verified"), ("pool_label_status", "verified"), ("closed", 1),
                        ("provider", kind)):
        require(verdict[field] == want, f"{name} receipt verdict {field} must be {want!r}")
    require(verdict["route_snapshot_digest"] == snapshot["route_snapshot_digest"], f"{name}: the verdict must bind the settled attempt's route snapshot digest")
    require(verdict["provider_reported_model_hash"] == entry["artifact_hash"] and verdict["expected_catalog_model_hash"] == entry["artifact_hash"],
            f"{name}: the verdict hashes must be the entry's artifact_hash")
    require(verdict["model_id"] == entry["pool_model_id"], f"{name}: the receipt model_id must be the pool_model_id (SPEC-022 R-13.3)")
    require(verdict["model_hash"] in (None, entry["artifact_hash"]), f"{name}: the receipt model_hash must be the entry's artifact_hash")
    require(int_in(verdict["received_at_unix_ms"], f"{name}.received_at_unix_ms", 1) >= snapshot["route_decision_ts_unix_ms"],
            f"{name}: settlement must follow dispatch")

    ledger = list_of(r["ledger"], f"{name}.ledger")
    ledger_keys = {"id", "request_id", "attempt_n", "provider", "status", "charged_prompt_tokens", "cached_prompt_tokens", "completion_tokens",
                   "estimated_completion_tokens", "usage_source", "prompt_rate_per_mtok", "completion_rate_per_mtok", "global_multiplier_ppm",
                   "gross_credits", "provider_share_bps", "provider_credits", "quarantined", "payable"}
    for row in ledger:
        obj(row, ledger_keys, f"{name}.ledger")
        require((row["request_id"], row["attempt_n"]) in by_key, f"{name}: every ledger row must join a route snapshot")
    payable = [row for row in ledger if row["payable"] == 1]
    require(len(payable) == 1, f"{name} must have exactly one payable ledger row")
    credit = payable[0]
    require((credit["request_id"], credit["attempt_n"]) == key, f"{name}: the payable credit must be the settled attempt's")
    require(credit["provider"] == kind and credit["quarantined"] == 0, f"{name}: an unquarantined credit to the serving {kind} member")
    require(credit["prompt_rate_per_mtok"] == snapshot["pool_model_prompt_rate_per_mtok"]
            and credit["completion_rate_per_mtok"] == snapshot["pool_model_completion_rate_per_mtok"],
            f"{name}: ledger rates must be the frozen snapshot rates")
    require(credit["global_multiplier_ppm"] == snapshot["pool_model_global_multiplier_ppm"]
            and credit["provider_share_bps"] == snapshot["pool_model_provider_share_bps"], f"{name}: ledger multiplier and share must be the snapshot's")
    prompt = int_in(credit["charged_prompt_tokens"], f"{name} ledger.charged_prompt_tokens")
    cached = 0 if credit["cached_prompt_tokens"] is None else int_in(credit["cached_prompt_tokens"], f"{name} ledger.cached_prompt_tokens", 0, prompt)
    completion = int_in(credit["completion_tokens"], f"{name} ledger.completion_tokens")
    billed_completion = completion
    if credit["usage_source"] == "byte_estimated" and credit["estimated_completion_tokens"] is not None:
        billed_completion = int_in(credit["estimated_completion_tokens"], f"{name} ledger.estimated_completion_tokens")
    else:
        require(credit["usage_source"] == "provider_reported", f"{name}: ledger usage_source must be provider_reported or byte_estimated")
    numerator = ((prompt - cached) * snapshot["pool_model_prompt_rate_per_mtok"] + cached * snapshot["pool_model_prompt_cache_hit_rate_per_mtok"]
                 + billed_completion * snapshot["pool_model_completion_rate_per_mtok"])
    require(numerator * snapshot["pool_model_global_multiplier_ppm"] <= INT64_MAX, f"{name}: credit arithmetic must fit int64")
    gross = round_half_even(numerator * snapshot["pool_model_global_multiplier_ppm"], 10**12)
    provider_credits = round_half_even(gross * snapshot["pool_model_provider_share_bps"], 10000)
    require(credit["gross_credits"] == gross, f"{name}: gross_credits {credit['gross_credits']} must equal the SPEC-005 recomputation {gross}")
    require(credit["provider_credits"] == provider_credits and provider_credits > 0,
            f"{name}: provider_credits {credit['provider_credits']} must equal the recomputation {provider_credits} and be positive")

    reservations = list_of(r["quota_reservations"], f"{name}.quota_reservations")
    require(len(reservations) == 1, f"{name} must have exactly one gateway reservation")
    reservation = obj(reservations[0], {"request_id", "status", "settled_tokens", "settlement_hold"}, f"{name}.quota_reservations")
    require(reservation["request_id"] == rid and reservation["status"] == "settled" and reservation["settlement_hold"] == 0,
            f"{name}: the X-Request-ID's reservation must be settled with no hold")
    events = list_of(r["usage_events"], f"{name}.usage_events")
    require(len(events) == 1, f"{name} must have exactly one gateway usage event")
    event = obj(events[0], {"request_id", "prompt_tokens", "completion_tokens", "token_source", "outcome"}, f"{name}.usage_events")
    require(event["request_id"] == rid, f"{name}: the usage event must be the X-Request-ID's")
    require(event["token_source"] == spec["usage_source"], f"{name} usage event token_source must be {spec['usage_source']}")
    debit = (event["prompt_tokens"], event["completion_tokens"])
    require(debit == (prompt, completion), f"{name} debit {debit} and ledger {(prompt, completion)} tokens must be equal")
    require(reservation["settled_tokens"] == prompt + completion, f"{name}: the reservation must settle the debited tokens")
    require(headers["pool_manifest_core_digest"] == snapshot["manifest_core_digest"],
            f"{name} X-MacProvider-Pool-Manifest-Core-Digest must equal the route snapshot's digest")
    return {
        "kind": kind,
        "version": snapshot["manifest_version"],
        "role": j.role_of(snapshot["manifest_version"], name),
        "rates": {rate: snapshot[f"pool_model_{rate}"] for rate in RATE_KEYS},
        "dispatch_ms": snapshot["route_decision_ts_unix_ms"],
        "settled_ms": verdict["received_at_unix_ms"],
        "usage_equal": (usage["prompt_tokens"], usage["completion_tokens"]) == debit,
    }


def check_refusal(ev: dict[str, Any], name: str, statuses: tuple[int, ...], codes: tuple[str, ...]) -> dict[str, Any]:
    r = obj(ev["refusals"][name], {"x_request_id", "date_unix", "status", "error_code", "route_snapshot_count", "ledger_row_count",
                                   "quota_reservations"}, name)
    rid = require_string(r["x_request_id"], REQUEST_ID_RE, f"{name}.x_request_id")
    require(r["status"] in statuses, f"{name} status must be one of {list(statuses)}, got {r['status']}")
    require(r["error_code"] in codes, f"{name} error.code must be one of {list(codes)}, got {r['error_code']!r}")
    require(r["route_snapshot_count"] == 0, f"{name} must leave no route snapshot")
    require(r["ledger_row_count"] == 0, f"{name} must leave no ledger row")
    reservations = list_of(r["quota_reservations"], f"{name}.quota_reservations")
    require(len(reservations) == 1, f"{name} must have exactly one reservation, refunded")
    reservation = obj(reservations[0], {"request_id", "status", "settled_tokens", "settlement_hold"}, f"{name}.quota_reservations")
    require(reservation["request_id"] == rid and reservation["status"] == "refunded" and reservation["settled_tokens"] == 0
            and reservation["settlement_hold"] == 0, f"{name}: the X-Request-ID's reservation must be refunded")
    return {"date_unix": int_in(r["date_unix"], f"{name}.date_unix", 1)}


def check_probes(j: Journey, ev: dict[str, Any]) -> None:
    probes = list_of(ev["window_probes"], "window_probes")
    boundary = j.activation_ms("window_rotation") // 1000
    at = []
    window_entries = {e["pool_model_id"] for e in j.manifests[j.roles["window_rotation"]]["model_entries"]}
    for index, probe in enumerate(probes):
        probe = obj(probe, {"at_unix", "status", "pool_model_id"}, f"window_probes[{index}]")
        at.append(int_in(probe["at_unix"], f"window_probes[{index}].at_unix", 1))
        require(probe["status"] == 200, f"window_probes[{index}]: a window-only rotation must not gap (status 200)")
        require(probe["pool_model_id"] in window_entries, f"window_probes[{index}]: the probe must request an entry of the rotated core")
    require(at == sorted(at), "window probes must be in time order")
    require(any(t < boundary for t in at) and any(t >= boundary for t in at), "window probes must fall on both sides of the window boundary")


def check_rollback(ev: dict[str, Any]) -> None:
    rollback = obj(ev["rollback_preflight"], {"m9", "p1816"}, "rollback_preflight")
    for tier, want_rc, blocked in (("m9", 3, True), ("p1816", 0, False)):
        item = obj(rollback[tier], {"exit_status", "rollback_blocked", "target_tier", "cannot_replay_count", "report_sha256"}, f"rollback_preflight.{tier}")
        require(item["exit_status"] == want_rc, f"preflight-{tier} must exit {want_rc}")
        require(item["rollback_blocked"] is blocked, f"preflight-{tier} rollback_blocked must be {blocked}")
        require(item["target_tier"] == tier, f"preflight-{tier} target_tier must be {tier}")
        hex64(item["report_sha256"], f"preflight-{tier}.report_sha256")
        if blocked:
            require(int_in(item["cannot_replay_count"], "cannot_replay_count") > 0, "the m9 target must be unable to replay the pool-model cores")
        else:
            require(item["cannot_replay_count"] == 0, "the p1816 target must replay the whole manifest history")


def check_redaction(ev: dict[str, Any]) -> None:
    base.reject_forbidden_secret_keys(ev)
    base.require_fingerprints_only(ev)
    reject_locators(ev)
    raw = ev["raw_documents"]
    require(isinstance(raw, dict) and bool(raw), "raw_documents must list every raw capture file")
    for name, record in raw.items():
        require(isinstance(name, str) and re.fullmatch(r"[A-Za-z0-9._-]+(?:/[A-Za-z0-9._-]+)*", name) is not None and ".." not in name,
                f"raw_documents key {name!r} must be a relative capture path")
        record = obj(record, {"sha256", "bytes"}, f"raw_documents.{name}")
        hex64(record["sha256"], f"raw_documents.{name}.sha256")
        int_in(record["bytes"], f"raw_documents.{name}.bytes")
    for required_file in ("run.json", "preconditions.json", f"pool/{BUNDLE_ROOT_FILE}", "config/provider-owner-account-ids.json"):
        require(required_file in raw, f"raw_documents must include {required_file}")


def reject_locators(value: Any, location: str = "$") -> None:
    if isinstance(value, dict):
        for key, item in value.items():
            reject_locators(key, f"{location}.<key>")
            reject_locators(item, f"{location}.{key}")
    elif isinstance(value, list):
        for index, item in enumerate(value):
            reject_locators(item, f"{location}[{index}]")
    elif isinstance(value, str):
        if any(pattern.search(value) for pattern in LOCATOR_PATTERNS):
            die(f"{location} contains a URL, host, IP address or absolute path")


def validate_evidence(ev: Any, *, now: datetime, fill_observations: bool = False) -> dict[str, Any]:
    """The full semantic validator over redacted evidence. It returns the
    derived observations; unless filling them at capture, the evidence's
    observations must equal them."""
    if not isinstance(ev, dict):
        die("evidence must be an object")
    check_header(ev, now)
    j = Journey(ev)
    check_roles(j)
    check_preconditions(j, ev)
    check_manifests(j, ev)
    check_pool_state(j, ev)
    requests = obj(ev["requests"], set(PAID_REQUESTS), "requests")
    for name in PAID_REQUESTS:
        require(isinstance(requests[name], dict) and isinstance(requests[name].get("route_snapshots"), list), f"{name} must be a request record")
        for row in requests[name]["route_snapshots"]:
            require(isinstance(row, dict), f"{name} route snapshots must be objects")
    pricing = check_pricing(j, ev)
    check_proposals(j, ev)
    admission = check_admission(j, ev)
    models = check_models(j, ev)
    paid = {name: check_paid(j, ev, name, kind, stream, pricing) for name, (kind, stream) in PAID_REQUESTS.items()}
    obj(ev["refusals"], set(REFUSALS), "refusals")
    refusals = {name: check_refusal(ev, name, statuses, codes) for name, (statuses, codes) in REFUSALS.items()}

    # step-11: window rotation.
    require(paid["rotation/window-only/after"]["role"] == "window_rotation", "rotation/window-only/after must route under the window_rotation terms")
    require(paid["rotation/window-only/after"]["dispatch_ms"] >= j.activation_ms("window_rotation"), "rotation/window-only/after must follow the boundary")
    check_probes(j, ev)
    # step-12: price change in flight.
    inflight, after = paid["rotation/price-change/inflight"], paid["rotation/price-change/after"]
    changed = j.price_changed
    for label, item in (("inflight", inflight), ("after", after)):
        require(j.entries[item["kind"]]["pool_model_id"] == changed, f"rotation/price-change/{label} must request the repriced entry")
    price_on = j.activation_ms("price_change")
    require(inflight["dispatch_ms"] < price_on <= inflight["settled_ms"],
            "rotation/price-change/inflight must be dispatched before the price change activates and settle after it")
    require(j.roles[inflight["role"]] < j.roles["price_change"], "rotation/price-change/inflight must route under the prior terms")
    require(after["role"] == "price_change", "rotation/price-change/after must route under the price_change terms")
    require(inflight["rates"] != after["rates"], "the in-flight attempt must settle at its snapshot's prior rates")
    # step-13: entry and attestation removal.
    removal_on = j.activation_ms("entry_removal")
    removal = paid["rotation/entry-removal/inflight"]
    require(removal["dispatch_ms"] < removal_on <= removal["settled_ms"],
            "rotation/entry-removal/inflight must be dispatched before the entry removal activates and settle after it")
    require(refusals["rotation/entry-removal/after"]["date_unix"] * 1000 >= removal_on, "the entry-removal refusal must follow its activation")
    require(refusals["rotation/attestation-removal/after"]["date_unix"] * 1000 >= j.activation_ms("attestation_removal"),
            "the attestation-removal refusal must follow its activation")
    # step-14/15.
    check_rollback(ev)
    restart = obj(ev["restart"], {"coordinator_restarted_at", "gateway_restarted_at"}, "restart")
    require(int_in(restart["coordinator_restarted_at"], "restart.coordinator", 1) <= int_in(restart["gateway_restarted_at"], "restart.gateway", 1),
            "restart order: the coordinator restarts before the gateway")
    require(paid["restart/after"]["dispatch_ms"] >= restart["gateway_restarted_at"] * 1000, "restart/after must be served after the restart")
    # step-16.
    check_redaction(ev)

    native_served = any(item["kind"] == "native" for item in paid.values())
    attested_served = any(item["kind"] == "gguf" for item in paid.values())
    pre = ev["preconditions"]
    observations = {
        "settlement_mode": "enforce" if all(m["settlement_mode"] == "enforce" for m in j.manifests.values()) else "observe",
        "enforce_activated": all(item["kind"] in ENTRY_KINDS for item in paid.values()),
        "enforce_scope": "pool",
        "production_coordinator": pre["deploy-build"]["observed"]["production"],
        "launch_environment": ev["manifest_root"]["launch_environment"],
        "payout_ready_mutated": pre["payout-disabled"]["observed"]["payout_enabled"],
        "raw_prompt_output_redacted": True,
        "bearer_tokens_redacted": True,
        "native_entry_served": native_served,
        "attested_member_served": attested_served,
        "global_route_absent": models is not None and ev["models"]["never_global_count"] == 0,
        "current_generation_revocation": bool(admission["entry_removal_revoked_reason"]),
        "buyer_visible_usage_equals_debit": all(item["usage_equal"] for item in paid.values()),
    }
    for field, want in TRUSTED_POOL_MODEL_FIXED_OBSERVATIONS.items():
        require(observations[field] == want and type(observations[field]) is type(want), f"derived observation {field} must be {want!r}")
    if not fill_observations:
        require(ev["observations"] == observations, "observations must equal the values derived from the evidence")
    return observations


# ---- payload (runs in the signing workflow) ----


def require_evidence_source(root: Path, source: str) -> tuple[str, Path]:
    normalized = base.repository_relative(root, source, "redacted evidence source")
    name = Path(normalized).name
    if not normalized.startswith(EVIDENCE_PREFIX) or not name.endswith(".redacted.json") or "/" in normalized[len("journeys/evidence/"):]:
        die(f"redacted evidence source must be {EVIDENCE_PREFIX}*.redacted.json")
    path = root / normalized
    candidate = root
    for component in Path(normalized).parts:
        candidate = candidate / component
        if candidate.is_symlink():
            die(f"redacted evidence source is absent or unsafe: {normalized}")
    if not path.is_file():
        die(f"redacted evidence source is absent or unsafe: {normalized}")
    return normalized, path


def bundle_dir_for(source: str) -> str:
    return source[: -len(".redacted.json")] + ".manifests"


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
    forbidden = [item for item in input_ids if item not in TRUSTED_POOL_MODEL_PROMOTABLE_REQUIREMENT_IDS]
    if forbidden:
        die(f"trusted-pool model journey-result cannot promote {', '.join(forbidden)}")
    return input_ids


def load_mapped_requirements(root: Path) -> set[str]:
    conformance = base.load_object(root / "specs" / "CONFORMANCE.json", "spec conformance")
    requirements = conformance.get("requirements")
    if not isinstance(requirements, list):
        die("specs/CONFORMANCE.json requirements must be an array")
    mapped: set[str] = set()
    for row in requirements:
        if isinstance(row, dict) and isinstance(row.get("journeys"), list) and JOURNEY_ID in row["journeys"] and row.get("state") == "pending":
            if isinstance(row.get("requirement_id"), str):
                mapped.add(row["requirement_id"])
    return mapped


def require_candidate_identity(value: Any) -> dict[str, Any]:
    identity = obj(value, TRUSTED_POOL_MODEL_CANDIDATE_IDENTITY_KEYS, "candidate_identity")
    for field in TRUSTED_POOL_MODEL_SHA256_IDENTITY_KEYS:
        hex64(identity[field], f"candidate_identity.{field}")
    return deepcopy(identity)


def reverify_bundle(root: Path, source: str, evidence: dict[str, Any], cli: str, evidence_sha: str) -> None:
    """Re-verify the committed signed pool events with the reviewed
    coordinator-cli and require the verified cores to equal the evidence."""
    bundle = bundle_dir_for(source)
    bundle_path = root / bundle
    if bundle_path.is_symlink() or not bundle_path.is_dir():
        die(f"the signed manifest bundle {bundle} must be committed beside the evidence")
    names = sorted(child.name for child in bundle_path.iterdir())
    want = sorted([BUNDLE_ROOT_FILE] + [f"v{m['manifest_version']}.json" for m in evidence["manifests"]])
    require(names == want, f"the manifest bundle must hold exactly {want}")
    for name in names:
        path = bundle_path / name
        require(path.is_file() and not path.is_symlink(), f"bundle file {name} is unsafe")
        base.require_git_file_matches(root, evidence_sha, f"{bundle}/{name}", path.read_bytes())
    manifests = sorted(evidence["manifests"], key=lambda m: m["manifest_version"])
    output = run_verify_manifest(cli, bundle_path / BUNDLE_ROOT_FILE, [bundle_path / f"v{m['manifest_version']}.json" for m in manifests])
    fresh_root, fresh = normalize_verification(output, evidence["candidate_identity"]["fingerprint_salt"])
    require(fresh_root == evidence["manifest_root"], "the re-verified root registration must equal the evidence's")
    require(fresh == evidence["manifests"], "the re-verified manifests must equal the evidence's verified cores")


def build_payload(root: Path, source: str, *, source_sha: str, evidence_sha: str, requirement_ids: str | None, cli: str) -> dict[str, Any]:
    require_string(source_sha, COMMIT_RE, "--source-sha")
    require_string(evidence_sha, COMMIT_RE, "--evidence-sha")
    source, path = require_evidence_source(root, source)
    evidence_bytes = path.read_bytes()
    evidence = base.parse_json_bytes(evidence_bytes, source)
    if JOURNEY_ID != TRUSTED_POOL_MODEL_JOURNEY_ID or ARTIFACT_ID != TRUSTED_POOL_MODEL_ARTIFACT_ID:
        die("builder constants drifted from check_spec_governance")
    observations = validate_evidence(evidence, now=datetime.now(timezone.utc))
    for label, commit in (("--source-sha", source_sha), ("--evidence-sha", evidence_sha)):
        if not base.git_ok(root, "cat-file", "-e", f"{commit}^{{commit}}"):
            die(f"{label} is not a reachable commit")
    if not base.git_ok(root, "merge-base", "--is-ancestor", source_sha, evidence_sha):
        die("--source-sha must be an ancestor of --evidence-sha")
    if evidence["repository"]["commit"] != source_sha:
        die("repository.commit must exactly match --source-sha")
    base.require_git_file_matches(root, evidence_sha, source, evidence_bytes)
    reverify_bundle(root, source, evidence, cli, evidence_sha)
    selected = parse_requirement_ids(requirement_ids, evidence)
    not_mapped = [item for item in selected if item not in load_mapped_requirements(root)]
    if not_mapped:
        die(f"requirement_ids must be pending and mapped to {JOURNEY_ID}: {', '.join(not_mapped)}")
    if date.fromisoformat(evidence["expires_at"]) < date.today():
        die("expires_at must not be in the past")
    return {
        "schema_version": JOURNEY_RESULT_PAYLOAD_SCHEMA,
        "journey_id": JOURNEY_ID,
        "requirement_ids": selected,
        "repository": {"name": REPOSITORY, "commit": source_sha},
        "captured_at": evidence["captured_at"],
        "expires_at": evidence["expires_at"],
        "operator": deepcopy(evidence["operator"]),
        "environment": deepcopy(evidence["environment"]),
        "artifacts": [{"id": ARTIFACT_ID, "sha256": sha256_hex(evidence_bytes), "source": source}],
        "result": {"status": "pass", "summary": SUMMARY},
        "steps": derived_steps(),
        "redaction": deepcopy(evidence["redaction"]),
        "run_id": evidence["run_id"],
        "execution_mode": TRUSTED_POOL_MODEL_EXECUTION_MODE,
        "observations": {key: observations[key] for key in sorted(TRUSTED_POOL_MODEL_OBSERVATION_KEYS)},
        "candidate_identity": require_candidate_identity(evidence["candidate_identity"]),
    }


def validate_committed_evidence(payload: bytes) -> None:
    """Promotion-time revalidation (check_spec_governance): the full semantic
    validator over committed evidence bytes, without the CLI re-verify."""
    validate_evidence(base.parse_json_bytes(payload, "trusted-pool model redacted evidence"), now=datetime.now(timezone.utc))


def write_bundle(output: Path, bundle: dict[str, bytes]) -> Path:
    name = output.name
    if not name.endswith(".redacted.json"):
        die("--output must end in .redacted.json")
    directory = output.with_name(name[: -len(".redacted.json")] + ".manifests")
    if directory.exists() and (directory.is_symlink() or not directory.is_dir() or any(directory.iterdir())):
        die(f"{directory} already exists; remove it before a new capture")
    directory.mkdir(parents=True, exist_ok=True)
    for file_name, payload in bundle.items():
        (directory / file_name).write_bytes(payload)
    return directory


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    sub = parser.add_subparsers(dest="command", required=True)
    capture = sub.add_parser("capture", help="verify and normalize a capture directory into redacted evidence")
    capture.add_argument("--capture-dir", required=True, help="operator capture directory (journey doc layout)")
    capture.add_argument("--output", required=True, help="journeys/evidence/trusted-pool-model-<run>.redacted.json")
    capture.add_argument("--coordinator-cli", required=True, help="coordinator-cli built from the reviewed main commit")
    payload = sub.add_parser("payload", help="build the unsigned journey-result payload from committed redacted evidence")
    payload.add_argument("redacted_evidence_source", help=f"{EVIDENCE_PREFIX}*.redacted.json")
    payload.add_argument("--root", default=".", help="repository root")
    payload.add_argument("--output", required=True, help="unsigned journey-result payload output path")
    payload.add_argument("--source-sha", required=True, help="deployed source commit captured by the evidence")
    payload.add_argument("--evidence-sha", required=True, help="repository commit containing the redacted evidence")
    payload.add_argument("--requirement-ids", default=None, help="comma-separated requirement IDs to cover")
    payload.add_argument("--coordinator-cli", required=True, help="coordinator-cli built from the reviewed main commit")
    args = parser.parse_args(argv)

    if args.command == "capture":
        output = Path(args.output)
        evidence, bundle = build_evidence(Path(args.capture_dir), args.coordinator_cli)
        directory = write_bundle(output, bundle)
        base.write_json_atomically(output, evidence)
        print(f"build-trusted-pool-model-journey-result: wrote {output} and {directory}")
        return 0
    root = Path(args.root).resolve()
    output = Path(args.output)
    if not output.is_absolute():
        output = root / output
    value = build_payload(root, args.redacted_evidence_source, source_sha=args.source_sha, evidence_sha=args.evidence_sha,
                          requirement_ids=args.requirement_ids, cli=args.coordinator_cli)
    base.write_json_atomically(output, value)
    print(f"build-trusted-pool-model-journey-result: wrote {output}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
