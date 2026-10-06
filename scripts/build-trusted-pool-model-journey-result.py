#!/usr/bin/env python3
"""Build the JOURNEY-TRUSTED-POOL-MODEL redacted evidence and journey-result payload.

`capture` reads an operator capture directory (layout in
journeys/JOURNEY-TRUSTED-POOL-MODEL.md), checks every physical step, and
writes the redacted evidence. It never copies a prompt, completion, key,
locator, or raw account/provider id into its output: identities become salted
fingerprints and every raw capture file is kept only as a sha256 and a byte
count. `payload` turns committed redacted evidence into the unsigned
journey-result payload the signing workflow signs.
"""

from __future__ import annotations

import argparse
import importlib.util
import json
import re
import secrets
import sys
from copy import deepcopy
from datetime import date
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


# The capture, redaction and git helpers are the external-runtime builder's;
# their failures report under this builder's name.
base = load_base_builder()
base.die = die
require = base.require
require_string = base.require_string
require_object = base.require_object
as_int = base.as_int
sha256_hex = base.sha256_hex
fingerprint = base.fingerprint


EVIDENCE_SCHEMA = "macprovider.trusted-pool-model-evidence.v1"
JOURNEY_ID = "JOURNEY-TRUSTED-POOL-MODEL"
REPOSITORY = "Augustas11/macprovider"
ARTIFACT_ID = "redacted-trusted-pool-model"
EVIDENCE_PREFIX = "journeys/evidence/trusted-pool-model-"
ROUTE_SNAPSHOT_V2 = "spec022-route-snapshot-v2"
DISCLOSURE_CLASS = "pool_attested_unverified"
DISCLOSURE_TEXT = "Pool-attested, not network-verified"
PRICE_SOURCE = "pool_creator_signed"
REQUIREMENT_RE = re.compile(r"^SPEC-[0-9]{3}-R[0-9]{3}$")
COMMIT_RE = re.compile(r"^[0-9a-f]{40}$")
SHA256_RE = re.compile(r"^[0-9a-f]{64}$")
DATETIME_Z_RE = re.compile(r"^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z$")
DATE_RE = re.compile(r"^[0-9]{4}-[0-9]{2}-[0-9]{2}$")
RUN_ID_RE = re.compile(r"^trusted-pool-model-[0-9]{8}T[0-9]{6}Z$")
POOL_ID_RE = re.compile(r"^[A-Za-z0-9_-]{8,64}$")
SLUG_RE = re.compile(r"^[a-z0-9][a-z0-9-]{0,62}$")
SPDX_RE = re.compile(r"^(?:LicenseRef-[A-Za-z0-9.-]{1,64}|[A-Za-z0-9][A-Za-z0-9.+-]{0,63})$")
ERROR_CODE_RE = re.compile(r"^[a-z][a-z0-9_]{0,63}$")
SHORT_TOKEN_RE = base.SHORT_TOKEN_RE
ACCEPTED_ID_RE = base.ACCEPTED_ID_RE
VERSION_RE = re.compile(r"^v[0-9]+\.[0-9]+\.[0-9]+$")

ENTRY_KINDS = {
    "native": {
        "algorithm": "macprovider.snapshot-manifest.v1",
        "engine": "mlx_cache",
        "allowed_runtime": "mlx_cache",
        "route_runtime_source": None,
        "usage_source": "coordinator_observed",
    },
    "gguf": {
        "algorithm": "macprovider.gguf-file.v1",
        "engine": "llamacpp_loopback",
        "allowed_runtime": "llamacpp_loopback",
        "route_runtime_source": "llamacpp_loopback",
        "usage_source": "pool_operator_attested",
    },
}
PRECONDITION_IDS = (
    "deploy-build",
    "trusted-pools-enabled",
    "pricing-bounds-configured",
    "gateway-route-snapshot-v2",
    "payout-disabled",
)
MANIFEST_ROLES = (
    "native_genesis",
    "gguf_added",
    "window_rotation",
    "price_change",
    "entry_removal",
    "attestation_removal",
)
RATE_KEYS = ("prompt_rate_per_mtok", "prompt_cache_hit_rate_per_mtok", "completion_rate_per_mtok")
BOUNDS_KEYS = tuple(f"{edge}_{rate}" for rate in RATE_KEYS for edge in ("min", "max"))
PRE_BIND_STATES = {"offer_submitted", "sandbox_probe_only", "network_visible_unpriced", "network_admitted_unsettled"}
RAW_IDENTITY_FIELDS = (
    "creator_account_id",
    "buyer_account_id",
    "native_member_provider_id",
    "native_member_account_id",
    "gguf_member_provider_id",
    "gguf_member_account_id",
    "other_pool_id",
    "operator_identity",
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
# capture-relative directory -> (HTTP status, error.code); None = any 4xx/5xx
# with a closed error code.
REFUSALS = {
    "refusals/no-pool-header": (404, "model_not_found"),
    "refusals/other-pool": (404, "model_not_found"),
    "refusals/wrong-engine": (503, "engine_unavailable"),
    "pause/paused": (503, "pool_unavailable"),
    "rotation/entry-removal/after": (404, "model_not_found"),
    "rotation/attestation-removal/after": (None, None),
}
STEP_ASSERTIONS = {
    "step-01-preconditions": "the #1816 build is deployed coordinator, then gateway, then member CLIs; trusted pools, bounds, route_snapshot_v2 and payout-disabled pass",
    "step-02-pricing-bounds-and-owner-authority": "closed pricing bounds hold every signed entry rate; the owner-authority reload applied",
    "step-03-pool-genesis-with-entries": "candidate enforce pool, llamacpp_loopback allowlisted, genesis core carries the native mlx_cache entry",
    "step-04-non-creator-members": "a delegated non-creator native member and an R016-attested non-creator GGUF member",
    "step-05-proposal-bundles": "each signed entry equals its pool_model_proposal.v1 bundle's identity",
    "step-06-offer-binding": "each member's offer binds pool-scoped catalog_priced under the signed-manifest actor; never settlement_capable",
    "step-07-pool-models-disclosure": "the pool models view discloses both entries; the global models view and global route snapshots carry none",
    "step-08-native-entry-paid": "native mlx_cache entry served, settled verified with a payable credit to the delegated member at the entry rates",
    "step-09-attested-member-paid": "GGUF entry served by the R016-attested member, pool_operator_attested, verified, payable at the entry rates",
    "step-10-refusals": "no pool header, another pool and a wrong engine fail closed with no route snapshot or ledger row and a refunded reservation",
    "step-11-window-rotation-no-gap": "a window-only rotation keeps the terms digest, rebinds, and serves with no gap",
    "step-12-price-change-in-flight": "an attempt in flight across a price change settles at its snapshot rates; later attempts use the new rates",
    "step-13-current-generation-revocation": "entry removal and attestation removal revoke the bindings; the in-flight attempt settles; later requests are refused",
    "step-14-pause-resume-rollback": "a paused pool refuses, resumes serving, and the rollback preflight blocks m9 and clears p1816",
    "step-15-restart-ordering": "coordinator restarts before gateway and the pool model serves after the restart",
    "step-16-redaction": "prompts, completions, keys, locators and raw identities absent; raw files kept as digests",
}
LOCATOR_PATTERNS = (
    re.compile(r"[A-Za-z][A-Za-z0-9+.-]*://"),
    re.compile(r"(?<![0-9.])[0-9]{1,3}(?:\.[0-9]{1,3}){3}(?![0-9.])"),
    re.compile(r"(?:^|[\s\"'=(])(?:/|~/)[A-Za-z0-9._-]"),
    re.compile(r"(?i)\b[a-z0-9-]+(?:\.[a-z0-9-]+)*\.(?:tech|com|net|org|io|dev|local|internal|lan|ts\.net)\b"),
)


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
        return (self.root / relative).is_file() and not (self.root / relative).is_symlink()

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


def require_timestamp(value: Any, location: str) -> str:
    return require_string(value, DATETIME_Z_RE, location)


def load_run(capture: Capture) -> dict[str, Any]:
    run = capture.object("run.json")
    fields = {
        "run_id": RUN_ID_RE,
        "captured_at": DATETIME_Z_RE,
        "expires_at": DATE_RE,
        "source_commit": COMMIT_RE,
        "coordinator_version": VERSION_RE,
        "accepted_id": ACCEPTED_ID_RE,
        "native_member_cli_sha256": SHA256_RE,
        "gguf_member_cli_sha256": SHA256_RE,
        "llama_server_build": re.compile(r"^b[0-9]+$"),
        "operator_role": SHORT_TOKEN_RE,
        "operator_identity": None,
        "hardware_profile": SHORT_TOKEN_RE,
        "pool_id": POOL_ID_RE,
        "other_pool_id": POOL_ID_RE,
        "creator_account_id": None,
        "buyer_account_id": None,
        "native_member_provider_id": None,
        "native_member_account_id": None,
        "gguf_member_provider_id": None,
        "gguf_member_account_id": None,
        "native_entry": None,
        "gguf_entry": None,
        "manifest_versions": None,
    }
    extra = set(run) - set(fields)
    require(not extra, f"run.json has unexpected keys: {sorted(extra)}")
    for field, pattern in fields.items():
        if field in ("native_entry", "gguf_entry", "manifest_versions"):
            continue
        require_string(run.get(field), pattern, f"run.json.{field}")
    require(run["other_pool_id"] != run["pool_id"], "run.json.other_pool_id must differ from pool_id")
    for kind in ENTRY_KINDS:
        account = run[f"{kind}_member_account_id"]
        require(account != run["creator_account_id"], f"run.json.{kind}_member_account_id must not be the creator (a non-creator member)")
    require(run["native_member_provider_id"] != run["gguf_member_provider_id"], "the native and GGUF members must be different providers")
    entries: dict[str, dict[str, str]] = {}
    for kind, spec in ENTRY_KINDS.items():
        entry = require_object(run.get(f"{kind}_entry"), f"run.json.{kind}_entry")
        require(set(entry) == {"slug", "artifact_hash"}, f"run.json.{kind}_entry must have exactly slug and artifact_hash")
        slug = require_string(entry.get("slug"), SLUG_RE, f"run.json.{kind}_entry.slug")
        artifact_hash = require_string(entry.get("artifact_hash"), SHA256_RE, f"run.json.{kind}_entry.artifact_hash")
        entries[kind] = {
            "pool_model_id": f"pool/{run['pool_id']}/{slug}",
            "artifact_hash": artifact_hash,
            "algorithm": spec["algorithm"],
        }
    require(entries["native"]["pool_model_id"] != entries["gguf"]["pool_model_id"], "the two entries must have different slugs")
    versions = require_object(run.get("manifest_versions"), "run.json.manifest_versions")
    require(set(versions) == set(MANIFEST_ROLES), f"run.json.manifest_versions must name exactly {list(MANIFEST_ROLES)}")
    roles = {role: as_int(versions[role], f"run.json.manifest_versions.{role}") for role in MANIFEST_ROLES}
    ordered = [roles[role] for role in MANIFEST_ROLES[:4]]
    require(all(1 <= a < b for a, b in zip(ordered, ordered[1:])),
            "manifest_versions native_genesis < gguf_added < window_rotation < price_change must be increasing")
    for role in ("entry_removal", "attestation_removal"):
        require(roles[role] > roles["price_change"], f"manifest_versions.{role} must follow price_change")
    require(roles["entry_removal"] != roles["attestation_removal"], "entry_removal and attestation_removal must be separate manifests")
    run["entries"] = entries
    run["roles"] = roles
    return run


def check_preconditions(capture: Capture) -> dict[str, Any]:
    raw = capture.object("preconditions.json")
    require(set(raw) == set(PRECONDITION_IDS), f"preconditions.json must name exactly {list(PRECONDITION_IDS)}")
    out: dict[str, Any] = {}
    for key in PRECONDITION_IDS:
        item = require_object(raw[key], f"preconditions.{key}")
        require(set(item) == {"status", "observed", "checked_at"}, f"preconditions.{key} must have status, observed, checked_at")
        require(item["status"] == "pass", f"preconditions.{key}.status must equal 'pass'")
        base.require_observed_facts(item["observed"], f"preconditions.{key}.observed")
        require_timestamp(item["checked_at"], f"preconditions.{key}.checked_at")
        out[key] = {"status": "pass", "observed": item["observed"], "checked_at": item["checked_at"]}
    return out


def check_deploy_order(capture: Capture) -> dict[str, Any]:
    raw = capture.object("deploy.json")
    keys = ("coordinator_deployed_at", "gateway_deployed_at", "native_member_cli_installed_at", "gguf_member_cli_installed_at")
    require(set(raw) == set(keys), f"deploy.json must have exactly {list(keys)}")
    stamps = {key: require_timestamp(raw[key], f"deploy.json.{key}") for key in keys}
    require(stamps["coordinator_deployed_at"] <= stamps["gateway_deployed_at"], "deploy order: the coordinator deploys before the gateway")
    for key in keys[2:]:
        require(stamps["gateway_deployed_at"] <= stamps[key], f"deploy order: the gateway deploys before {key}")
    return {"order": ["coordinator", "gateway", "member_cli"], **stamps}


def check_bounds(capture: Capture) -> tuple[dict[str, int], dict[str, Any]]:
    raw = capture.object("config/pricing-bounds.json")
    require(set(raw) == set(BOUNDS_KEYS), f"config/pricing-bounds.json must have exactly {list(BOUNDS_KEYS)}")
    bounds: dict[str, int] = {}
    for key in BOUNDS_KEYS:
        value = raw[key]
        require(isinstance(value, int) and not isinstance(value, bool) and value >= 0, f"pricing bounds {key} must be a non-negative integer")
        bounds[key] = value
    for rate in RATE_KEYS:
        require(bounds[f"min_{rate}"] <= bounds[f"max_{rate}"], f"pricing bounds min_{rate} must be at most max_{rate}")
    reload = capture.object("config/owner-authority-reload.json")
    reload_keys = {
        "reloaded",
        "provider_owner_account_ids_applied",
        "provider_owner_account_ids_providers",
        "provider_owner_account_ids_sha256",
    }
    require(set(reload) == reload_keys, f"config/owner-authority-reload.json must have exactly {sorted(reload_keys)}")
    require(reload["reloaded"] is True, "the bounds and owner-authority reload must have applied")
    require(reload["provider_owner_account_ids_applied"] is True, "provider_owner_account_ids must be applied")
    providers = as_int(reload["provider_owner_account_ids_providers"], "owner-authority-reload providers")
    require(providers >= 1, "the owner map must list the attested member's provider")
    require_string(reload["provider_owner_account_ids_sha256"], SHA256_RE, "owner-authority-reload provider_owner_account_ids_sha256")
    return bounds, {
        "reloaded": True,
        "provider_owner_account_ids_applied": True,
        "provider_owner_account_ids_providers": providers,
        "provider_owner_account_ids_sha256": reload["provider_owner_account_ids_sha256"],
    }


def parse_terms(payload: bytes, label: str) -> dict[str, str]:
    """`trust-pool-admin policy-terms-digest` output: key=value lines."""
    values: dict[str, str] = {}
    for line in payload.decode("utf-8").splitlines():
        if not line.strip():
            continue
        key, sep, value = line.partition("=")
        require(bool(sep), f"{label}: malformed line")
        values[key.strip()] = value.strip()
    require(set(values) == {"pool_id", "manifest_version", "manifest_core_digest", "manifest_terms_digest"},
            f"{label} must be the policy-terms-digest output")
    return values


def load_manifest_version(capture: Capture, run: dict[str, Any], version: int) -> dict[str, Any]:
    """pool/v<N>/: the signed manifest event and its policy terms digest."""
    where = f"pool/v{version}"
    event = capture.object(f"{where}/manifest-accepted.json")
    require(event.get("event_type") == "manifest_accepted", f"{where}/manifest-accepted.json must be a manifest_accepted event")
    require(event.get("pool_id") == run["pool_id"], f"{where}/manifest-accepted.json pool_id must equal run.json pool_id")
    require(as_int(event.get("manifest_version"), f"{where} manifest_version") == version, f"{where}/manifest-accepted.json must be version {version}")
    digest = require_string(event.get("manifest_core_digest"), SHA256_RE, f"{where} manifest_core_digest")
    terms = parse_terms(capture.read(f"{where}/policy-terms-digest.txt"), f"{where}/policy-terms-digest.txt")
    require(terms["pool_id"] == run["pool_id"] and terms["manifest_version"] == str(version) and terms["manifest_core_digest"] == digest,
            f"{where}/policy-terms-digest.txt must describe the same manifest")
    require_string(terms["manifest_terms_digest"], SHA256_RE, f"{where} manifest_terms_digest")
    return {"version": version, "manifest_core_digest": digest, "manifest_terms_digest": terms["manifest_terms_digest"]}


def check_entry_shape(entry: dict[str, Any], where: str) -> dict[str, Any]:
    keys = {
        "pool_model_id", "artifact_hash_algorithm", "artifact_hash", "allowed_runtime_sources", "license",
        "paid_serving_attested", *RATE_KEYS, "disclosure_class", "max_context_tokens",
    }
    require(set(entry) == keys, f"{where} must be the closed get-pool model entry")
    require_string(entry["license"], SPDX_RE, f"{where}.license")
    require(entry["paid_serving_attested"] is True, f"{where}.paid_serving_attested must be true")
    require(entry["disclosure_class"] == DISCLOSURE_CLASS, f"{where}.disclosure_class must be {DISCLOSURE_CLASS}")
    sources = entry["allowed_runtime_sources"]
    require(isinstance(sources, list) and sources and all(isinstance(s, str) for s in sources), f"{where}.allowed_runtime_sources must be a list")
    rates = {key: as_int(entry[key], f"{where}.{key}") for key in RATE_KEYS}
    require(rates["prompt_cache_hit_rate_per_mtok"] <= rates["prompt_rate_per_mtok"], f"{where}: cache-hit rate must be at most the prompt rate")
    return {
        "pool_model_id": entry["pool_model_id"],
        "artifact_hash_algorithm": entry["artifact_hash_algorithm"],
        "artifact_hash": entry["artifact_hash"],
        "allowed_runtime_sources": sorted(sources),
        "license": entry["license"],
        "paid_serving_attested": True,
        "rates": rates,
        "disclosure_class": DISCLOSURE_CLASS,
        "max_context_tokens": as_int(entry["max_context_tokens"], f"{where}.max_context_tokens"),
    }


def load_role_pool(capture: Capture, run: dict[str, Any], role: str, manifest: dict[str, Any]) -> dict[str, Any]:
    version = manifest["version"]
    where = f"pool/v{version}/get-pool.json"
    pool = require_object(capture.object(where).get("pool"), f"{where}.pool")
    require(pool.get("pool_id") == run["pool_id"], f"{where}: pool_id must equal run.json pool_id")
    require(pool.get("creator_account_id") == run["creator_account_id"], f"{where}: creator_account_id must equal run.json")
    require(as_int(pool.get("manifest_version"), f"{where}.manifest_version") == version, f"{where}: manifest_version must be {version}")
    require(pool.get("manifest_core_digest") == manifest["manifest_core_digest"], f"{where}: manifest digest must equal the submitted manifest's")
    require(pool.get("launch_environment") == "candidate", f"{where}: launch_environment must be candidate")
    require(pool.get("settlement_mode") == "enforce", f"{where}: settlement_mode must be enforce")
    allowlist = pool.get("runtime_allowlist")
    require(isinstance(allowlist, list) and "llamacpp_loopback" in allowlist, f"{where}: runtime_allowlist must include llamacpp_loopback")
    entries_raw = pool.get("model_entries")
    require(isinstance(entries_raw, list), f"{where}: model_entries must be a list")
    entries = {}
    for index, item in enumerate(entries_raw):
        entry = check_entry_shape(require_object(item, f"{where}.model_entries[{index}]"), f"{where}.model_entries[{index}]")
        require(entry["pool_model_id"] not in entries, f"{where}: duplicate model entry")
        entries[entry["pool_model_id"]] = entry
    attested_raw = pool.get("attested_members")
    require(isinstance(attested_raw, list), f"{where}: attested_members must be a list")
    attested: dict[str, list[str]] = {}
    for index, item in enumerate(attested_raw):
        member = require_object(item, f"{where}.attested_members[{index}]")
        account = require_string(member.get("provider_account_id"), None, f"{where}.attested_members[{index}].provider_account_id")
        classes = member.get("runtime_classes")
        require(isinstance(classes, list) and all(isinstance(c, str) for c in classes), f"{where}.attested_members[{index}].runtime_classes")
        attested[account] = sorted(classes)
    members = pool.get("members")
    require(isinstance(members, list), f"{where}: members must be a list")
    buyers = pool.get("buyer_accounts")
    require(isinstance(buyers, list) and run["buyer_account_id"] in buyers, f"{where}: buyer_accounts must include the buyer")
    for kind, spec in ENTRY_KINDS.items():
        entry_id = run["entries"][kind]["pool_model_id"]
        if entry_id in entries:
            entry = entries[entry_id]
            require(entry["artifact_hash"] == run["entries"][kind]["artifact_hash"], f"{where}: {kind} entry artifact_hash must equal run.json")
            require(entry["artifact_hash_algorithm"] == spec["algorithm"], f"{where}: {kind} entry must use {spec['algorithm']}")
            require(spec["allowed_runtime"] in entry["allowed_runtime_sources"], f"{where}: {kind} entry must allow {spec['allowed_runtime']}")
    return {
        "role": role,
        "version": version,
        "manifest_core_digest": manifest["manifest_core_digest"],
        "manifest_terms_digest": manifest["manifest_terms_digest"],
        "lifecycle": pool.get("lifecycle"),
        "routeable": pool.get("routeable"),
        "entries": entries,
        "attested": attested,
        "members": list(members),
        "revoked": list(pool.get("revoked") or []),
    }


def check_pool(capture: Capture, run: dict[str, Any], bounds: dict[str, int]) -> dict[str, Any]:
    roles = run["roles"]
    pools: dict[str, dict[str, Any]] = {}
    manifests: dict[int, dict[str, Any]] = {}
    # Every captured version (role and keeper manifests) is checked up front.
    pool_dir = capture.root / "pool"
    for child in sorted(pool_dir.iterdir()) if pool_dir.is_dir() else []:
        match = re.fullmatch(r"v([1-9][0-9]{0,8})", child.name)
        if match and child.is_dir():
            manifests[int(match.group(1))] = load_manifest_version(capture, run, int(match.group(1)))
    for role in MANIFEST_ROLES:
        version = roles[role]
        if version not in manifests:
            manifests[version] = load_manifest_version(capture, run, version)
        pools[role] = load_role_pool(capture, run, role, manifests[version])
    native_id = run["entries"]["native"]["pool_model_id"]
    gguf_id = run["entries"]["gguf"]["pool_model_id"]
    gguf_account = run["gguf_member_account_id"]

    # step-03: genesis carries the native entry; the pool is active and routeable.
    genesis = pools["native_genesis"]
    require(genesis["lifecycle"] == "active" and genesis["routeable"] is True, "native_genesis get-pool must be active and routeable")
    require(native_id in genesis["entries"], "native_genesis core must carry the native entry")
    # step-04: both members are non-creator members; the GGUF member's owner is attested.
    added = pools["gguf_added"]
    require(native_id in added["entries"] and gguf_id in added["entries"], "gguf_added core must carry both entries")
    require("llamacpp_loopback" in added["attested"].get(gguf_account, []), "gguf_added core must attest the GGUF member's owner for llamacpp_loopback")
    require(run["native_member_account_id"] not in added["attested"], "the native member is delegated, not R016-attested")
    for kind in ENTRY_KINDS:
        require(run[f"{kind}_member_provider_id"] in added["members"], f"gguf_added get-pool members must include the {kind} member")
    # step-11: a window-only rotation keeps the terms and the entries byte-equal.
    window = pools["window_rotation"]
    require(window["manifest_terms_digest"] == added["manifest_terms_digest"], "window_rotation must keep the policy terms digest")
    require(window["manifest_core_digest"] != added["manifest_core_digest"], "window_rotation must be a new core")
    require(window["entries"] == added["entries"] and window["attested"] == added["attested"], "window_rotation must keep entries and attestations")
    # step-12: the price change changes exactly one entry's rates.
    price = pools["price_change"]
    require(price["manifest_terms_digest"] != window["manifest_terms_digest"], "price_change must change the policy terms digest")
    require(set(price["entries"]) == set(window["entries"]) and price["attested"] == window["attested"], "price_change must keep entries and attestations")
    changed = [
        entry_id for entry_id in price["entries"]
        if price["entries"][entry_id] != window["entries"][entry_id]
    ]
    require(len(changed) == 1, "price_change must change exactly one entry")
    before, after = window["entries"][changed[0]], price["entries"][changed[0]]
    require(before["rates"] != after["rates"], "price_change must change the entry's rates")
    require({k: v for k, v in before.items() if k != "rates"} == {k: v for k, v in after.items() if k != "rates"},
            "price_change must change only the entry's rates")
    # step-13: entry removal drops the native entry; attestation removal drops the GGUF owner.
    require(native_id not in pools["entry_removal"]["entries"], "entry_removal core must not carry the native entry")
    require(gguf_account not in pools["attestation_removal"]["attested"], "attestation_removal core must not attest the GGUF member's owner")
    for role in ("entry_removal", "attestation_removal"):
        prior = max((r for r in MANIFEST_ROLES if roles[r] < roles[role]), key=lambda r: roles[r])
        if role == "entry_removal":
            require(native_id in pools[prior]["entries"], "the native entry must be present in the manifest before entry_removal")
        else:
            require(gguf_account in pools[prior]["attested"], "the GGUF owner must be attested in the manifest before attestation_removal")
    # step-02: every signed rate sits inside the configured bounds.
    for role, pool in pools.items():
        for entry_id, entry in pool["entries"].items():
            for rate in RATE_KEYS:
                value = entry["rates"][rate]
                require(bounds[f"min_{rate}"] <= value <= bounds[f"max_{rate}"],
                        f"{role} entry {entry_id} {rate} {value} must be inside the configured bounds")

    counts: dict[str, int] = {}
    for row in capture.rows("pool/trustpool-events.json"):
        event_type = require_string(row.get("event_type"), None, "trustpool-events.event_type")
        require(event_type not in counts, f"trustpool-events repeats {event_type}")
        counts[event_type] = as_int(row.get("n"), f"trustpool-events.{event_type}.n")
    for event_type, want in (("pool_created", 1), ("root_issuer_registered", 1)):
        require(counts.get(event_type) == want, f"pool history must have exactly {want} {event_type}")
    for event_type, at_least in (
        ("manifest_accepted", len(set(roles.values()))),
        ("member_admitted", 2),
        ("buyer_authorized", 1),
        ("delegation_granted", 2),
        ("lifecycle_changed", 2),
    ):
        require(counts.get(event_type, 0) >= at_least, f"pool history must have at least {at_least} {event_type}")
    return {"roles": pools, "manifests": manifests, "event_counts": dict(sorted(counts.items())), "price_changed_entry": changed[0]}


def resolve_version(capture: Capture, run: dict[str, Any], pool: dict[str, Any], version: int, where: str) -> dict[str, Any]:
    """The terms in force at a route snapshot's manifest version.

    A keeper rotates windows between the captured role manifests. A snapshot
    at such a version needs pool/v<N>/manifest-accepted.json and
    policy-terms-digest.txt, and its terms digest must equal the latest role
    manifest at or below it: equal terms carry equal entries, prices and
    attestations.
    """
    manifests = pool["manifests"]
    if version not in manifests:
        manifests[version] = load_manifest_version(capture, run, version)
    candidates = [role for role in MANIFEST_ROLES if run["roles"][role] <= version]
    require(bool(candidates), f"{where}: manifest_version {version} precedes native_genesis")
    role = max(candidates, key=lambda r: run["roles"][r])
    role_pool = pool["roles"][role]
    require(manifests[version]["manifest_terms_digest"] == role_pool["manifest_terms_digest"],
            f"{where}: manifest_version {version} terms must equal the {role} manifest's terms")
    return {"role": role, "pool": role_pool, "manifest": manifests[version]}


def parse_body(capture: Capture, base_dir: str, stream: bool) -> dict[str, Any]:
    has_sse = capture.exists(f"{base_dir}/response.sse")
    require(has_sse == stream, f"{base_dir} must capture {'response.sse' if stream else 'response.json'}")
    if not stream:
        body = capture.read(f"{base_dir}/response.json")
        doc = require_object(base.parse_json_bytes(body, f"{base_dir}/response.json"), f"{base_dir} body")
        choices = doc.get("choices")
        require(isinstance(choices, list) and choices, f"{base_dir} body must have choices")
        choice = require_object(choices[0], f"{base_dir} choices[0]")
        message = require_object(choice.get("message"), f"{base_dir} message")
        content = message.get("content") if isinstance(message.get("content"), str) else ""
        finish_reason = choice.get("finish_reason")
        usage = require_object(doc.get("usage"), f"{base_dir} usage")
    else:
        body = capture.read(f"{base_dir}/response.sse")
        data_lines = [
            line[len("data:"):].strip()
            for line in body.decode("utf-8").replace("\r\n", "\n").split("\n")
            if line.startswith("data:")
        ]
        require(bool(data_lines) and data_lines[-1] == "[DONE]", f"{base_dir} stream must end with data: [DONE]")
        parts: list[str] = []
        finish_reason = None
        usage = None
        for index, raw in enumerate(data_lines[:-1]):
            chunk = require_object(base.parse_json_bytes(raw.encode("utf-8"), f"{base_dir} chunk {index}"), f"{base_dir} chunk {index}")
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
        require(usage is not None, f"{base_dir} stream must carry a usage chunk")
        content = "".join(parts)
    require(isinstance(finish_reason, str) and bool(finish_reason), f"{base_dir} must carry a finish_reason")
    return {
        "finish_reason": finish_reason,
        "content_sha256": sha256_hex(content.encode("utf-8")),
        "buyer_visible_usage": {
            "prompt_tokens": as_int(usage.get("prompt_tokens"), f"{base_dir} usage.prompt_tokens"),
            "completion_tokens": as_int(usage.get("completion_tokens"), f"{base_dir} usage.completion_tokens"),
        },
        "stream": stream,
    }


def entry_kind_for(run: dict[str, Any], pool_model_id: Any, where: str) -> str:
    for kind in ENTRY_KINDS:
        if run["entries"][kind]["pool_model_id"] == pool_model_id:
            return kind
    die(f"{where}: pool_model_id must be one of the journey's entries")
    raise AssertionError


def check_paid_request(capture: Capture, run: dict[str, Any], pool: dict[str, Any], base_dir: str,
                       want_kind: str | None, stream: bool) -> dict[str, Any]:
    status, headers = base.parse_headers(capture.read(f"{base_dir}/response.headers"), f"{base_dir}/response.headers")
    require(status == 200, f"{base_dir} response status must be 200, got {status}")
    request_id = require_string(headers.get("x-request-id"), None, f"{base_dir} X-Request-ID")
    require(headers.get("x-macprovider-model-disclosure") == DISCLOSURE_CLASS, f"{base_dir} X-MacProvider-Model-Disclosure must be {DISCLOSURE_CLASS}")
    body = parse_body(capture, base_dir, stream)

    request_log = capture.rows(f"{base_dir}/request_log.json")
    require(any(row.get("pool_id") == run["pool_id"] for row in request_log), f"{base_dir} request_log must show the pool")
    snapshots = capture.rows(f"{base_dir}/route_snapshots.json")
    require(bool(snapshots), f"{base_dir} must have route snapshots")
    kind = entry_kind_for(run, snapshots[0].get("pool_model_id"), base_dir)
    if want_kind is not None:
        require(kind == want_kind, f"{base_dir} must be served from the {want_kind} entry")
    spec = ENTRY_KINDS[kind]
    entry = run["entries"][kind]
    require(headers.get("x-macprovider-engine") == spec["engine"], f"{base_dir} X-MacProvider-Engine must be {spec['engine']}")
    provider = run[f"{kind}_member_provider_id"]
    resolved = None
    bounds_digests: set[str] = set()
    for row in snapshots:
        where = f"{base_dir} route snapshot attempt {row.get('attempt_n')}"
        require(row.get("pool_id") == run["pool_id"], f"{where}: pool_id must be the pool")
        require(row.get("expected_model_hash_source") == "pool_manifest", f"{where}: expected_model_hash_source must be pool_manifest")
        require(row.get("pool_model_id") == entry["pool_model_id"] and row.get("model_id") == entry["pool_model_id"],
                f"{where}: pool_model_id and model_id must be the exact entry")
        require(row.get("expected_catalog_model_hash") == entry["artifact_hash"], f"{where}: expected hash must be the entry's artifact_hash")
        require(row.get("expected_catalog_model_hash_algorithm") == entry["algorithm"], f"{where}: expected hash algorithm must be {entry['algorithm']}")
        require(row.get("route_snapshot_policy_version") == ROUTE_SNAPSHOT_V2, f"{where}: route_snapshot_policy_version must be {ROUTE_SNAPSHOT_V2}")
        require(row.get("route_snapshot_mode") == "enforce", f"{where}: route_snapshot_mode must be enforce")
        require(row.get("provider_id") == provider, f"{where}: provider must be the {kind} member")
        version = as_int(row.get("manifest_version"), f"{where}.manifest_version")
        this = resolve_version(capture, run, pool, version, where)
        require(row.get("manifest_core_digest") == this["manifest"]["manifest_core_digest"], f"{where}: manifest_core_digest must be version {version}'s")
        signed_entry = this["pool"]["entries"].get(entry["pool_model_id"])
        require(signed_entry is not None, f"{where}: the entry must be in the version {version} core")
        for rate in RATE_KEYS:
            require(as_int(row.get(f"pool_model_{rate}"), f"{where}.pool_model_{rate}") == signed_entry["rates"][rate],
                    f"{where}: pool_model_{rate} must equal the signed entry rate")
        bounds_digests.add(require_string(row.get("pool_model_pricing_bounds_sha256"), SHA256_RE, f"{where}.pool_model_pricing_bounds_sha256"))
        if spec["route_runtime_source"] is None:
            # SPEC-022 R-13.5: a native mlx_cache route carries no runtime_source.
            for field in ("runtime_source", "pool_operator_account_id", "pool_member_account_id"):
                require(row.get(field) in (None, ""), f"{where}: a native route carries no {field}")
        else:
            require(row.get("runtime_source") == spec["route_runtime_source"], f"{where}: runtime_source must be {spec['route_runtime_source']}")
            require(row.get("pool_operator_account_id") == run["creator_account_id"], f"{where}: pool_operator_account_id must be the creator")
            require(row.get("pool_member_account_id") == run["gguf_member_account_id"], f"{where}: pool_member_account_id must be the attested member's owner")
            require("llamacpp_loopback" in this["pool"]["attested"].get(run["gguf_member_account_id"], []),
                    f"{where}: the member's owner must be attested for llamacpp_loopback at version {version}")
        resolved = (version, this, signed_entry)
    assert resolved is not None
    version, this, signed_entry = resolved
    require(headers.get("x-macprovider-pool-manifest-core-digest") == this["manifest"]["manifest_core_digest"],
            f"{base_dir} X-MacProvider-Pool-Manifest-Core-Digest must equal the route snapshot's digest")

    outputs = capture.rows(f"{base_dir}/attempt_outputs.json")
    settled = [row for row in outputs if row.get("usage_source") == spec["usage_source"] and row.get("terminal_state") == "normal_done"]
    require(len(settled) == 1, f"{base_dir} must have exactly one {spec['usage_source']} normal_done attempt output")
    key = (settled[0].get("request_id"), as_int(settled[0].get("attempt_n"), f"{base_dir} attempt_n"))
    verdicts = [
        row for row in capture.rows(f"{base_dir}/receipt_verdicts.json")
        if (row.get("request_id"), as_int(row.get("attempt_n"), f"{base_dir} verdict attempt_n")) == key
    ]
    require(len(verdicts) == 1, f"{base_dir} settled attempt must have exactly one receipt verdict")
    for field, want in (("receipt_result", "valid"), ("settlement_outcome", "verified"), ("pool_label_status", "verified"), ("closed", 1)):
        got = verdicts[0].get(field)
        if isinstance(want, int):
            got = as_int(got, f"{base_dir} verdict.{field}")
        require(got == want, f"{base_dir} receipt verdict {field} must be {want!r}")

    ledger = capture.rows(f"{base_dir}/ledger.json")
    payable = [row for row in ledger if as_int(row.get("payable"), f"{base_dir} ledger.payable") == 1]
    require(len(payable) == 1, f"{base_dir} must have exactly one payable ledger row")
    credit = payable[0]
    require(credit.get("provider_id") == provider, f"{base_dir} ledger provider must be the serving {kind} member")
    provider_credits = as_int(credit.get("provider_credits"), f"{base_dir} ledger.provider_credits")
    require(provider_credits > 0, f"{base_dir} ledger provider_credits must be positive")
    require(as_int(credit.get("quarantined"), f"{base_dir} ledger.quarantined") == 0, f"{base_dir} ledger row must not be quarantined")
    for rate in ("prompt_rate_per_mtok", "completion_rate_per_mtok"):
        require(as_int(credit.get(rate), f"{base_dir} ledger.{rate}") == signed_entry["rates"][rate],
                f"{base_dir} ledger {rate} must equal the snapshot's signed entry rate")
    ledger_tokens = (
        as_int(credit.get("charged_prompt_tokens"), f"{base_dir} ledger.charged_prompt_tokens"),
        as_int(credit.get("completion_tokens"), f"{base_dir} ledger.completion_tokens"),
    )
    reservations = capture.rows(f"{base_dir}/quota_reservations.json")
    require(len(reservations) == 1 and reservations[0].get("status") == "settled", f"{base_dir} must have one settled gateway reservation")
    require(as_int(reservations[0].get("settlement_hold"), f"{base_dir} settlement_hold") == 0, f"{base_dir} reservation must not be held")
    events = capture.rows(f"{base_dir}/usage_events.json")
    require(len(events) == 1, f"{base_dir} must have exactly one gateway usage event")
    require(events[0].get("token_source") == spec["usage_source"], f"{base_dir} usage event token_source must be {spec['usage_source']}")
    debit_tokens = (
        as_int(events[0].get("prompt_tokens"), f"{base_dir} usage_events.prompt_tokens"),
        as_int(events[0].get("completion_tokens"), f"{base_dir} usage_events.completion_tokens"),
    )
    require(debit_tokens == ledger_tokens, f"{base_dir} debit {debit_tokens} and ledger {ledger_tokens} tokens must be equal")
    visible = body["buyer_visible_usage"]
    return {
        "request_id": request_id,
        "entry": kind,
        "pool_model_id": entry["pool_model_id"],
        "engine": spec["engine"],
        "disclosure": DISCLOSURE_CLASS,
        "finish_reason": body["finish_reason"],
        "stream": stream,
        "content_sha256": body["content_sha256"],
        "route_snapshot_count": len(snapshots),
        "manifest_version": version,
        "manifest_role": this["role"],
        "manifest_core_digest": this["manifest"]["manifest_core_digest"],
        "rates": dict(signed_entry["rates"]),
        "pricing_bounds_sha256": sorted(bounds_digests),
        "usage_source": spec["usage_source"],
        "receipt_verdict": {"receipt_result": "valid", "settlement_outcome": "verified", "pool_label_status": "verified", "closed": True},
        "ledger": {
            "payable_rows": 1,
            "provider_fingerprint": fingerprint(provider, run["fingerprint_salt"]),
            "provider_credits": provider_credits,
        },
        "gateway": {"reservation_status": "settled", "settlement_hold": 0, "token_source": spec["usage_source"]},
        "debited_tokens": {"prompt_tokens": debit_tokens[0], "completion_tokens": debit_tokens[1]},
        "buyer_visible_usage_equals_debit": (visible["prompt_tokens"], visible["completion_tokens"]) == debit_tokens,
    }


def check_refusal(capture: Capture, base_dir: str, want_status: int | None, want_code: str | None) -> dict[str, Any]:
    status, _ = base.parse_headers(capture.read(f"{base_dir}/response.headers"), f"{base_dir}/response.headers")
    body = require_object(base.parse_json_bytes(capture.read(f"{base_dir}/response.json"), f"{base_dir}/response.json"), f"{base_dir} body")
    code = require_object(body.get("error"), f"{base_dir} error").get("code")
    if want_status is None:
        require(400 <= status <= 599, f"{base_dir} must be refused with a 4xx or 5xx status, got {status}")
        require_string(code, ERROR_CODE_RE, f"{base_dir} error.code")
    else:
        require(status == want_status, f"{base_dir} status must be {want_status}, got {status}")
        require(code == want_code, f"{base_dir} error.code must be {want_code}, got {code!r}")
    require(capture.rows(f"{base_dir}/route_snapshots.json") == [], f"{base_dir} must leave no route snapshot")
    require(capture.rows(f"{base_dir}/ledger.json") == [], f"{base_dir} must leave no ledger row")
    reservations = capture.rows(f"{base_dir}/quota_reservations.json")
    require(all(row.get("status") == "refunded" for row in reservations), f"{base_dir} reservations must be refunded")
    return {"status": status, "error_code": code, "route_snapshots": 0, "ledger_rows": 0, "reservations_refunded": len(reservations)}


def check_proposals(capture: Capture, run: dict[str, Any]) -> dict[str, Any]:
    out = {}
    for kind, spec in ENTRY_KINDS.items():
        where = f"proposals/{kind}.json"
        bundle = capture.object(where)
        require(bundle.get("schema") == "pool_model_proposal.v1", f"{where} must be a pool_model_proposal.v1 bundle")
        require(bundle.get("pool_id") == run["pool_id"], f"{where} pool_id must be the pool")
        require(bundle.get("runtime_source") == spec["allowed_runtime"], f"{where} runtime_source must be {spec['allowed_runtime']}")
        require(bundle.get("catalog_model_key") is None, f"{where} must be an unmatched (non-catalog) model")
        entry = require_object(bundle.get("model_entry"), f"{where}.model_entry")
        want = run["entries"][kind]
        require(entry.get("pool_model_id") == want["pool_model_id"], f"{where} pool_model_id must be the signed entry's")
        require(entry.get("artifact_hash") == want["artifact_hash"] and entry.get("artifact_hash_algorithm") == want["algorithm"],
                f"{where} artifact identity must be the signed entry's")
        require(entry.get("license") is None and entry.get("paid_serving_attested") is None, f"{where} leaves license and paid serving to the creator")
        out[kind] = {"schema": "pool_model_proposal.v1", "pool_model_id": want["pool_model_id"], "artifact_hash": want["artifact_hash"], "matches_signed_entry": True}
    return out


def check_admission(capture: Capture, run: dict[str, Any]) -> dict[str, Any]:
    rows = capture.rows("admission/model-admission-events.json")
    ids = [as_int(row.get("id"), "model-admission-events.id") for row in rows]
    require(ids == sorted(ids) and len(set(ids)) == len(ids), "model-admission-events must be ordered by id ascending")
    actor_prefix = f"pool_manifest:{run['pool_id']}:"
    out: dict[str, Any] = {}
    for kind in ENTRY_KINDS:
        provider = run[f"{kind}_member_provider_id"]
        entry = run["entries"][kind]
        mine = [row for row in rows if row.get("provider_id") == provider]
        require(all(row.get("state") != "settlement_capable" for row in mine), f"the {kind} member must never reach settlement_capable")
        bound = [
            row for row in mine
            if row.get("state") == "catalog_priced" and row.get("binding_scope") == "pool"
            and row.get("reason_code") == "pool_manifest_bound" and row.get("pool_id") == run["pool_id"]
            and row.get("pool_model_id") == entry["pool_model_id"]
            and row.get("expected_catalog_model_hash") == entry["artifact_hash"]
            and row.get("expected_catalog_model_hash_algorithm") == entry["algorithm"]
            and isinstance(row.get("actor"), str) and row["actor"].startswith(actor_prefix)
        ]
        require(bool(bound), f"the {kind} member's offer must bind pool-scoped catalog_priced under the signed-manifest actor")
        first_bound = as_int(bound[0].get("id"), "bound id")
        unmatched_offer = any(row.get("state") in PRE_BIND_STATES and as_int(row.get("id"), "id") < first_bound for row in mine)
        out[kind] = {
            "bound": True,
            "binding_scope": "pool",
            "reason_code": "pool_manifest_bound",
            "actor_is_signed_manifest": True,
            "unmatched_offer_before_bind": unmatched_offer,
            "settlement_capable_events": 0,
        }
    native = run["native_member_provider_id"]
    rebound = [
        row for row in rows
        if row.get("provider_id") == native and row.get("reason_code") == "pool_manifest_rebound"
        and row.get("state") == "catalog_priced"
        and as_int(row.get("pool_manifest_version"), "rebound pool_manifest_version") == run["roles"]["window_rotation"]
    ]
    require(bool(rebound), "the delegated native member must be rebound at the window_rotation version")
    revoked_entry = [
        row for row in rows
        if row.get("provider_id") == native and row.get("state") == "revoked"
        and row.get("reason_code") == "pool_manifest_entry_revoked" and row.get("pool_model_id") == run["entries"]["native"]["pool_model_id"]
    ]
    require(bool(revoked_entry), "entry removal must revoke the native binding with pool_manifest_entry_revoked")
    revoked_member = [
        row for row in rows
        if row.get("provider_id") == run["gguf_member_provider_id"] and row.get("state") == "revoked"
        and row.get("reason_code") == "pool_membership_revoked"
    ]
    require(bool(revoked_member), "attestation removal must revoke the GGUF binding with pool_membership_revoked")
    out["window_rotation_rebound"] = True
    out["entry_removal_revoked"] = "pool_manifest_entry_revoked"
    out["attestation_removal_revoked"] = "pool_membership_revoked"
    return out


def check_models(capture: Capture, run: dict[str, Any], pool: dict[str, Any]) -> dict[str, Any]:
    pool_view = capture.object("models/pool.json")
    data = pool_view.get("data")
    require(isinstance(data, list), "models/pool.json must be a /v1/models list")
    listed = {}
    for item in data:
        if isinstance(item, dict) and isinstance(item.get("id"), str) and item["id"].startswith("pool/"):
            listed[item["id"]] = item
    known_digests = {m["manifest_core_digest"]: v for v, m in pool["manifests"].items()}
    out = {}
    for kind in ENTRY_KINDS:
        entry = run["entries"][kind]
        item = listed.get(entry["pool_model_id"])
        require(item is not None, f"the pool /v1/models view must list the {kind} entry")
        model = require_object(item.get("macprovider_pool_model"), f"models/pool.json {kind} macprovider_pool_model")
        require(model.get("pool_id") == run["pool_id"] and model.get("pool_model_id") == entry["pool_model_id"],
                f"models/pool.json {kind}: pool and entry ids")
        require(model.get("disclosure_class") == DISCLOSURE_CLASS and model.get("disclosure_text") == DISCLOSURE_TEXT
                and model.get("price_source") == PRICE_SOURCE, f"models/pool.json {kind}: pool-attested disclosure")
        require(model.get("artifact_hash") == entry["artifact_hash"] and model.get("artifact_hash_algorithm") == entry["algorithm"],
                f"models/pool.json {kind}: artifact identity")
        digest = model.get("manifest_core_digest")
        require(digest in known_digests, f"models/pool.json {kind}: manifest_core_digest must be a captured manifest's")
        version = known_digests[digest]
        this = resolve_version(capture, run, pool, version, f"models/pool.json {kind}")
        signed_entry = this["pool"]["entries"].get(entry["pool_model_id"])
        require(signed_entry is not None, f"models/pool.json {kind}: the entry must be in that core")
        price = require_object(model.get("price"), f"models/pool.json {kind} price")
        for rate in RATE_KEYS:
            require(as_int(price.get(rate), f"models/pool.json {kind} price.{rate}") == signed_entry["rates"][rate],
                    f"models/pool.json {kind}: price.{rate} must equal the signed entry rate")
        out[kind] = {"listed": True, "disclosure_class": DISCLOSURE_CLASS, "price_source": PRICE_SOURCE, "manifest_version": version}
    global_view = capture.object("models/global.json")
    global_data = global_view.get("data")
    require(isinstance(global_data, list), "models/global.json must be a /v1/models list")
    for item in global_data:
        if isinstance(item, dict):
            require(not str(item.get("id", "")).startswith("pool/"), "the global /v1/models view must list no pool model")
            require("macprovider_pool_model" not in item, "the global /v1/models view must carry no pool model object")
    never_global = capture.rows("never-global.json")
    require(len(never_global) == 1 and as_int(never_global[0].get("n"), "never-global.n") == 0,
            "never-global: no route snapshot may carry a pool_model_id without a pool")
    out["global_view_pool_models"] = 0
    out["global_route_snapshots_with_pool_model"] = 0
    return out


def check_probes(capture: Capture) -> dict[str, Any]:
    probes = capture.rows("rotation/window-only/probes.json")
    require(len(probes) >= 2, "rotation/window-only/probes.json must hold at least two probes across the window boundary")
    stamps = []
    for index, probe in enumerate(probes):
        require(set(probe) == {"at", "status"}, f"probes[{index}] must have exactly at and status")
        stamps.append(require_timestamp(probe["at"], f"probes[{index}].at"))
        require(as_int(probe["status"], f"probes[{index}].status") == 200, f"probes[{index}]: a window-only rotation must not gap (status 200)")
    require(stamps == sorted(stamps), "probes must be in time order")
    return {"probes": len(probes), "all_200": True, "first_at": stamps[0], "last_at": stamps[-1]}


def check_rollback(capture: Capture) -> dict[str, Any]:
    out = {}
    for tier, want_rc, blocked in (("m9", 3, True), ("p1816", 0, False)):
        where = f"rollback/preflight-{tier}"
        rc_text = capture.read(f"{where}.rc").decode("utf-8").strip()
        require(re.fullmatch(r"[0-9]{1,3}", rc_text) is not None, f"{where}.rc must hold the exit status")
        require(int(rc_text) == want_rc, f"{where} must exit {want_rc}, got {rc_text}")
        report = capture.object(f"{where}.json")
        require(report.get("rollback_blocked") is blocked, f"{where}.json rollback_blocked must be {blocked}")
        history = require_object(report.get("manifest_history"), f"{where}.json manifest_history")
        require(history.get("target_tier") == tier, f"{where}.json manifest_history.target_tier must be {tier}")
        cannot = history.get("cannot_replay")
        require(isinstance(cannot, list), f"{where}.json manifest_history.cannot_replay must be a list")
        if blocked:
            require(bool(cannot), f"{where}: the m9 target must be unable to replay the pool-model cores")
        else:
            require(not cannot, f"{where}: the p1816 target must replay the whole manifest history")
        out[tier] = {"exit_status": want_rc, "rollback_blocked": blocked, "cannot_replay": len(cannot)}
    return out


def check_restart(capture: Capture) -> dict[str, Any]:
    raw = capture.object("restart/order.json")
    require(set(raw) == {"coordinator_restarted_at", "gateway_restarted_at"}, "restart/order.json must have the two restart times")
    coordinator = require_timestamp(raw["coordinator_restarted_at"], "restart.coordinator_restarted_at")
    gateway = require_timestamp(raw["gateway_restarted_at"], "restart.gateway_restarted_at")
    require(coordinator <= gateway, "restart order: the coordinator restarts before the gateway")
    return {"order": ["coordinator", "gateway"], "coordinator_restarted_at": coordinator, "gateway_restarted_at": gateway}


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


def require_no_raw_identity_fields(value: Any, location: str = "$") -> None:
    if isinstance(value, dict):
        for key, item in value.items():
            if key in RAW_IDENTITY_FIELDS:
                die(f"{location}.{key}: a raw identity field in redacted evidence")
            require_no_raw_identity_fields(item, f"{location}.{key}")
    elif isinstance(value, list):
        for index, item in enumerate(value):
            require_no_raw_identity_fields(item, f"{location}[{index}]")


def require_run_descriptors(evidence: dict[str, Any]) -> None:
    operator = require_object(evidence.get("operator"), "operator")
    require_string(operator.get("role"), SHORT_TOKEN_RE, "operator.role")
    environment = require_object(evidence.get("environment"), "environment")
    require_string(environment.get("hardware_profile"), SHORT_TOKEN_RE, "environment.hardware_profile")


def revalidate_committed_evidence(evidence: dict[str, Any]) -> None:
    """The payload step signs committed evidence, which may not have come
    through `capture` unchanged: re-run the redaction checks that need no raw
    capture."""
    preconditions = require_object(evidence.get("preconditions"), "preconditions")
    require(set(preconditions) == set(PRECONDITION_IDS), f"preconditions must name exactly {list(PRECONDITION_IDS)}")
    for key in PRECONDITION_IDS:
        item = require_object(preconditions[key], f"preconditions.{key}")
        require(set(item) == {"status", "observed", "checked_at"}, f"preconditions.{key} must have status, observed, checked_at")
        require(item["status"] == "pass", f"preconditions.{key}.status must equal 'pass'")
        base.require_observed_facts(item["observed"], f"preconditions.{key}.observed")
        require_timestamp(item["checked_at"], f"preconditions.{key}.checked_at")
    base.reject_forbidden_secret_keys(evidence)
    base.require_fingerprints_only(evidence)
    require_no_raw_identity_fields(evidence)
    reject_locators(evidence)
    require_run_descriptors(evidence)
    raw = require_object(evidence.get("raw_documents"), "raw_documents")
    for name, record in raw.items():
        record = require_object(record, f"raw_documents.{name}")
        require(set(record) == {"sha256", "bytes"}, f"raw_documents.{name} must be a digest and a byte count")
        require_string(record["sha256"], SHA256_RE, f"raw_documents.{name}.sha256")
        as_int(record["bytes"], f"raw_documents.{name}.bytes")


def reject_raw_identifiers(evidence: dict[str, Any], run: dict[str, Any]) -> None:
    text = json.dumps(evidence, sort_keys=True)
    for field in RAW_IDENTITY_FIELDS:
        if run[field] in text:
            die(f"redacted evidence would contain the raw {field}")


def summarize_pool(run: dict[str, Any], pool: dict[str, Any]) -> dict[str, Any]:
    salt = run["fingerprint_salt"]
    roles = {}
    for role in MANIFEST_ROLES:
        item = pool["roles"][role]
        roles[role] = {
            "manifest_version": item["version"],
            "manifest_core_digest": item["manifest_core_digest"],
            "manifest_terms_digest": item["manifest_terms_digest"],
            "lifecycle": item["lifecycle"],
            "routeable": item["routeable"],
            "entries": [item["entries"][key] for key in sorted(item["entries"])],
            "attested_members": [
                {"account_fingerprint": fingerprint(account, salt), "runtime_classes": classes}
                for account, classes in sorted(item["attested"].items())
            ],
        }
    return {
        "pool_id": run["pool_id"],
        "launch_environment": "candidate",
        "settlement_mode": "enforce",
        "creator_account_fingerprint": fingerprint(run["creator_account_id"], salt),
        "native_member_fingerprint": fingerprint(run["native_member_provider_id"], salt),
        "native_member_account_fingerprint": fingerprint(run["native_member_account_id"], salt),
        "gguf_member_fingerprint": fingerprint(run["gguf_member_provider_id"], salt),
        "gguf_member_account_fingerprint": fingerprint(run["gguf_member_account_id"], salt),
        "native_member_delegated": True,
        "gguf_member_attested": True,
        "manifests": roles,
        "keeper_versions": sorted(v for v in pool["manifests"] if v not in run["roles"].values()),
        "price_changed_entry": pool["price_changed_entry"],
        "event_counts": pool["event_counts"],
    }


def build_evidence(capture_dir: Path) -> dict[str, Any]:
    if capture_dir.is_symlink() or not capture_dir.is_dir():
        die("--capture-dir must be a directory")
    base.require_no_symlink_components(capture_dir, "--capture-dir")
    capture = Capture(capture_dir)
    run = load_run(capture)
    run["fingerprint_salt"] = secrets.token_hex(32)
    preconditions = check_preconditions(capture)
    deploy = check_deploy_order(capture)
    bounds, reload = check_bounds(capture)
    pool = check_pool(capture, run, bounds)
    proposals = check_proposals(capture, run)
    admission = check_admission(capture, run)
    models = check_models(capture, run, pool)
    requests = {
        name: check_paid_request(capture, run, pool, name, kind, stream)
        for name, (kind, stream) in PAID_REQUESTS.items()
    }
    refusals = {name: check_refusal(capture, name, status, code) for name, (status, code) in REFUSALS.items()}
    roles = run["roles"]
    window_after = requests["rotation/window-only/after"]
    require(window_after["manifest_role"] == "window_rotation", "rotation/window-only/after must route under the window_rotation terms")
    changed = pool["price_changed_entry"]
    inflight, after = requests["rotation/price-change/inflight"], requests["rotation/price-change/after"]
    for name, item in (("inflight", inflight), ("after", after)):
        require(item["pool_model_id"] == changed, f"rotation/price-change/{name} must request the repriced entry")
    require(inflight["manifest_version"] < roles["price_change"], "rotation/price-change/inflight must be routed before the price change")
    require(after["manifest_role"] == "price_change", "rotation/price-change/after must route under the price_change terms")
    require(inflight["rates"] != after["rates"], "the in-flight attempt must settle at its snapshot's prior rates")
    removal = requests["rotation/entry-removal/inflight"]
    require(removal["manifest_version"] < roles["entry_removal"], "rotation/entry-removal/inflight must be routed before entry removal")
    bounds_digests = sorted({d for item in requests.values() for d in item["pricing_bounds_sha256"]})
    require(len(bounds_digests) == 1, "every pool route must carry the same pricing-bounds digest")
    for item in requests.values():
        item["pricing_bounds_sha256"] = item["pricing_bounds_sha256"][0]
    probes = check_probes(capture)
    rollback = check_rollback(capture)
    restart = check_restart(capture)
    usage_equal = all(item["buyer_visible_usage_equals_debit"] for item in requests.values())
    latest = max(pool["manifests"])

    evidence = {
        "schema_version": EVIDENCE_SCHEMA,
        "journey_id": JOURNEY_ID,
        "run_id": run["run_id"],
        "requirement_ids": sorted(TRUSTED_POOL_MODEL_PROMOTABLE_REQUIREMENT_IDS),
        "repository": {"name": REPOSITORY, "commit": run["source_commit"]},
        "captured_at": run["captured_at"],
        "expires_at": run["expires_at"],
        "operator": {"role": run["operator_role"], "identity_fingerprint": fingerprint(run["operator_identity"], run["fingerprint_salt"])},
        "environment": {
            "class": TRUSTED_POOL_MODEL_EXECUTION_MODE,
            "hardware_profile": run["hardware_profile"],
            "candidate": run["accepted_id"],
        },
        "result": {
            "status": "pass",
            "summary": "pool-scoped native mlx_cache and R016-attested GGUF entries served, settled verified with payable credits at signed entry rates, refused outside the pool, and revoked at the current generation",
        },
        "steps": [
            {"id": step_id, "status": "pass", "assertion": STEP_ASSERTIONS[step_id], "artifacts": [ARTIFACT_ID]}
            for step_id in TRUSTED_POOL_MODEL_STEP_ID_ORDER
        ],
        "redaction": {
            "secrets_redacted": True,
            "operator_identity_redacted": True,
            "local_account_names_redacted": True,
        },
        "observations": {**TRUSTED_POOL_MODEL_FIXED_OBSERVATIONS, "buyer_visible_usage_equals_debit": usage_equal},
        "candidate_identity": {
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
            "manifest_version": latest,
            "manifest_core_digest": pool["manifests"][latest]["manifest_core_digest"],
            "pricing_bounds_sha256": bounds_digests[0],
            "fingerprint_salt": run["fingerprint_salt"],
        },
        "preconditions": preconditions,
        "deploy_order": deploy,
        "pricing": {"bounds": bounds, "owner_authority_reload": reload},
        "pool": summarize_pool(run, pool),
        "proposals": proposals,
        "admission": admission,
        "models": models,
        "requests": requests,
        "refusals": {**refusals, "other_pool_fingerprint": fingerprint(run["other_pool_id"], run["fingerprint_salt"])},
        "window_rotation": {"terms_digest_kept": True, "probes": probes},
        "rollback_preflight": rollback,
        "restart": restart,
        "raw_documents": dict(sorted(capture.raw.items())),
    }
    reject_raw_identifiers(evidence, run)
    revalidate_committed_evidence(evidence)
    return evidence


# ---- payload (runs in the signing workflow) ----


def require_evidence_source(root: Path, source: str) -> tuple[str, Path]:
    normalized = base.repository_relative(root, source, "redacted evidence source")
    name = Path(normalized).name
    if not normalized.startswith(EVIDENCE_PREFIX) or not name.endswith(".redacted.json"):
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
        if not isinstance(row, dict):
            continue
        journeys = row.get("journeys")
        if isinstance(journeys, list) and JOURNEY_ID in journeys and row.get("state") == "pending":
            requirement_id = row.get("requirement_id")
            if isinstance(requirement_id, str):
                mapped.add(requirement_id)
    return mapped


def require_steps(value: Any) -> list[dict[str, Any]]:
    if not isinstance(value, list):
        die("steps must be an array")
    out: list[dict[str, Any]] = []
    for index, item in enumerate(value):
        step = require_object(item, f"steps[{index}]")
        step_id = require_string(step.get("id"), None, f"steps[{index}].id")
        if step.get("status") != "pass":
            die(f"{step_id}.status must equal 'pass'")
        assertion = require_string(step.get("assertion"), None, f"{step_id}.assertion")
        if step.get("artifacts") != [ARTIFACT_ID]:
            die(f"{step_id}.artifacts must reference {ARTIFACT_ID}")
        out.append({"id": step_id, "status": "pass", "assertion": assertion, "artifacts": [ARTIFACT_ID]})
    if [step["id"] for step in out] != list(TRUSTED_POOL_MODEL_STEP_ID_ORDER):
        die(f"steps must be exactly {list(TRUSTED_POOL_MODEL_STEP_ID_ORDER)} in order")
    return out


def require_observations(value: Any) -> dict[str, Any]:
    observations = require_object(value, "observations")
    if set(observations) != TRUSTED_POOL_MODEL_OBSERVATION_KEYS:
        die(f"observations keys must be exactly {sorted(TRUSTED_POOL_MODEL_OBSERVATION_KEYS)}")
    for field, want in TRUSTED_POOL_MODEL_FIXED_OBSERVATIONS.items():
        if observations.get(field) != want or type(observations.get(field)) is not type(want):
            die(f"observations.{field} must equal {want!r}")
    if not isinstance(observations.get("buyer_visible_usage_equals_debit"), bool):
        die("observations.buyer_visible_usage_equals_debit must be a boolean")
    return deepcopy(observations)


def require_candidate_identity(value: Any) -> dict[str, Any]:
    identity = require_object(value, "candidate_identity")
    if set(identity) != TRUSTED_POOL_MODEL_CANDIDATE_IDENTITY_KEYS:
        die(f"candidate_identity keys must be exactly {sorted(TRUSTED_POOL_MODEL_CANDIDATE_IDENTITY_KEYS)}")
    for field in TRUSTED_POOL_MODEL_SHA256_IDENTITY_KEYS:
        require_string(identity.get(field), SHA256_RE, f"candidate_identity.{field}")
    require_string(identity.get("accepted_id"), ACCEPTED_ID_RE, "candidate_identity.accepted_id")
    require_string(identity.get("coordinator_version"), VERSION_RE, "candidate_identity.coordinator_version")
    require_string(identity.get("llama_server_build"), None, "candidate_identity.llama_server_build")
    pool_id = require_string(identity.get("pool_id"), POOL_ID_RE, "candidate_identity.pool_id")
    for field in ("native_pool_model_id", "gguf_pool_model_id"):
        value = require_string(identity.get(field), None, f"candidate_identity.{field}")
        prefix = f"pool/{pool_id}/"
        if not value.startswith(prefix) or not SLUG_RE.fullmatch(value[len(prefix):]):
            die(f"candidate_identity.{field} must be pool/<pool_id>/<slug>")
    version = identity.get("manifest_version")
    if isinstance(version, bool) or not isinstance(version, int) or version < 1:
        die("candidate_identity.manifest_version must be a positive integer")
    return deepcopy(identity)


def build_payload(root: Path, source: str, *, source_sha: str, evidence_sha: str, requirement_ids: str | None) -> dict[str, Any]:
    require_string(source_sha, COMMIT_RE, "--source-sha")
    require_string(evidence_sha, COMMIT_RE, "--evidence-sha")
    source, path = require_evidence_source(root, source)
    evidence_bytes = path.read_bytes()
    evidence = require_object(base.parse_json_bytes(evidence_bytes, source), "trusted-pool model redacted evidence")
    revalidate_committed_evidence(evidence)
    if evidence.get("schema_version") != EVIDENCE_SCHEMA:
        die(f"schema_version must equal {EVIDENCE_SCHEMA!r}")
    if evidence.get("journey_id") != JOURNEY_ID:
        die(f"journey_id must equal {JOURNEY_ID!r}")
    if JOURNEY_ID != TRUSTED_POOL_MODEL_JOURNEY_ID or ARTIFACT_ID != TRUSTED_POOL_MODEL_ARTIFACT_ID:
        die("builder constants drifted from check_spec_governance")
    for label, commit in (("--source-sha", source_sha), ("--evidence-sha", evidence_sha)):
        if not base.git_ok(root, "cat-file", "-e", f"{commit}^{{commit}}"):
            die(f"{label} is not a reachable commit")
    if not base.git_ok(root, "merge-base", "--is-ancestor", source_sha, evidence_sha):
        die("--source-sha must be an ancestor of --evidence-sha")
    repository = require_object(evidence.get("repository"), "repository")
    if repository.get("name") != REPOSITORY:
        die(f"repository.name must equal {REPOSITORY!r}")
    if require_string(repository.get("commit"), COMMIT_RE, "repository.commit") != source_sha:
        die("repository.commit must exactly match --source-sha")
    base.require_git_file_matches(root, evidence_sha, source, evidence_bytes)

    selected = parse_requirement_ids(requirement_ids, evidence)
    not_mapped = [item for item in selected if item not in load_mapped_requirements(root)]
    if not_mapped:
        die(f"requirement_ids must be pending and mapped to {JOURNEY_ID}: {', '.join(not_mapped)}")

    captured_at = require_string(evidence.get("captured_at"), DATETIME_Z_RE, "captured_at")
    expires_at = require_string(evidence.get("expires_at"), DATE_RE, "expires_at")
    if date.fromisoformat(expires_at) < date.today():
        die("expires_at must not be in the past")
    operator = deepcopy(require_object(evidence.get("operator"), "operator"))
    require_string(operator.get("identity_fingerprint"), SHA256_RE, "operator.identity_fingerprint")
    environment = deepcopy(require_object(evidence.get("environment"), "environment"))
    for field in ("class", "hardware_profile", "candidate"):
        require_string(environment.get(field), None, f"environment.{field}")
    if environment.get("class") != TRUSTED_POOL_MODEL_EXECUTION_MODE:
        die(f"environment.class must equal {TRUSTED_POOL_MODEL_EXECUTION_MODE!r}")
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
        "execution_mode": TRUSTED_POOL_MODEL_EXECUTION_MODE,
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
        base.write_json_atomically(output, build_evidence(Path(args.capture_dir)))
        print(f"build-trusted-pool-model-journey-result: wrote {output}")
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
    base.write_json_atomically(output, value)
    print(f"build-trusted-pool-model-journey-result: wrote {output}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
