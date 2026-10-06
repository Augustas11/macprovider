from __future__ import annotations

import contextlib
import email.utils
import hashlib
import importlib.util
import io
import json
import os
import re
import shutil
import subprocess
import sys
import tempfile
import unittest
from datetime import datetime, timezone
from pathlib import Path

from scripts.check_spec_governance import (
    TRUSTED_POOL_MODEL_ARTIFACT_ID,
    TRUSTED_POOL_MODEL_JOURNEY_ID,
    TRUSTED_POOL_MODEL_PROMOTABLE_REQUIREMENT_IDS,
    TRUSTED_POOL_MODEL_STEP_ID_ORDER,
    ValidationResult,
    _revalidate_trusted_pool_model_evidence,
    _validate_trusted_pool_model_journey_result,
)

REPO_ROOT = Path(__file__).resolve().parents[2]
POOL = "uTestPool1816abcd"
OTHER_POOL = "otherPool9999xyz"
CREATOR = "acct-creator-test"
BUYER = "acct-buyer-test"
NATIVE_PROV = "mp-native-test-0001"
NATIVE_ACCT = "acct-native-member"
GGUF_PROV = "mp-gguf-test-0002"
GGUF_ACCT = "acct-gguf-member"
NATIVE_HASH = "a1" * 32
GGUF_HASH = "b2" * 32
NATIVE_SLUG = "qwen25-05b-mlx8"
GGUF_SLUG = "qwen25-05b-q8-gguf"
SOURCE = "a" * 40
# The Pearl #1816 order: genesis (native only), keeper window rotation, native
# price change, native entry removal (zero entries), GGUF added (native
# re-added, GGUF entry, R016 attestation), keeper rotation, attestation removal.
ROLES = {"native_genesis": 1, "window_rotation": 2, "price_change": 3, "entry_removal": 4, "gguf_added": 5, "attestation_removal": 7}
VERSIONS = (1, 2, 3, 4, 5, 6, 7)
T0 = int(datetime(2026, 10, 5, 0, 0, tzinfo=timezone.utc).timestamp())
NATIVE_RATES = {"prompt_rate_per_mtok": 20000, "prompt_cache_hit_rate_per_mtok": 5000, "completion_rate_per_mtok": 40000}
NATIVE_NEW_RATES = {"prompt_rate_per_mtok": 30000, "prompt_cache_hit_rate_per_mtok": 7500, "completion_rate_per_mtok": 60000}
GGUF_RATES = {"prompt_rate_per_mtok": 25000, "prompt_cache_hit_rate_per_mtok": 6000, "completion_rate_per_mtok": 50000}
BOUNDS = {
    "min_prompt_rate_per_mtok": 13500, "max_prompt_rate_per_mtok": 425000,
    "min_prompt_cache_hit_rate_per_mtok": 3375, "max_prompt_cache_hit_rate_per_mtok": 106250,
    "min_completion_rate_per_mtok": 27000, "max_completion_rate_per_mtok": 2160000,
}
MULTIPLIER, SHARE = 1_000_000, 9000
PROMPT, COMPLETION = 4000, 1200


def load_builder():
    path = REPO_ROOT / "scripts" / "build-trusted-pool-model-journey-result.py"
    scripts = str(REPO_ROOT / "scripts")
    inserted = scripts not in sys.path
    if inserted:
        sys.path.insert(0, scripts)
    spec = importlib.util.spec_from_file_location("trusted_pool_model_builder", path)
    module = importlib.util.module_from_spec(spec)
    assert spec.loader is not None
    try:
        spec.loader.exec_module(module)
        return module
    finally:
        if inserted:
            sys.path.remove(scripts)


BUILDER = load_builder()

FAKE_CLI = r'''#!/usr/bin/env python3
import hashlib, json, sys
from pathlib import Path
args = sys.argv[1:]
paths = {"--root": [], "--manifest": [], "--snapshot": []}
i = 2
while i < len(args):
    paths[args[i]].append(args[i + 1])
    i += 2
template = json.loads(Path(__file__).with_name("verification.json").read_text())
if args[:2] == ["trust-pool-admin", "verify-route-snapshot"]:
    out = []
    for path in paths["--snapshot"]:
        doc = json.loads(Path(path).read_text())
        if template.get("refuse_snapshots"):
            sys.exit("billing: invalid route snapshot")
        out.append({"route_snapshot_digest": hashlib.sha256(json.dumps(doc, sort_keys=True, separators=(",", ":")).encode()).hexdigest()})
    print(json.dumps(out))
    sys.exit(0)
if args[:2] != ["trust-pool-admin", "verify-manifest"]:
    sys.exit("usage")
root_bytes = Path(paths["--root"][0]).read_bytes()
if json.loads(root_bytes).get("event_type") != "root_issuer_registered" or template.get("refuse"):
    sys.exit("trustpool: root issuer signature verification failed")
supplied = {}
for path in paths["--manifest"]:
    raw = Path(path).read_bytes()
    supplied[json.loads(raw)["manifest_version"]] = (raw, json.loads(raw))
newest = max(supplied)
out = {k: v for k, v in template.items() if k not in ("manifests", "refuse", "refuse_snapshots")}
out["root_event_sha256"] = hashlib.sha256(root_bytes).hexdigest()
out["newest_manifest_version"] = newest
items = []
for m in template["manifests"]:
    if m["manifest_version"] > newest:
        continue
    m = dict(m)
    m["event_sha256"] = None
    if m["manifest_version"] in supplied:
        raw, event = supplied[m["manifest_version"]]
        if event.get("manifest_core_digest") != m["manifest_core_digest"]:
            sys.exit("trustpool: invalid manifest snapshot")
        m["event_sha256"] = hashlib.sha256(raw).hexdigest()
    items.append(m)
out["manifests"] = items
print(json.dumps(out))
'''
GOLDEN = json.loads((REPO_ROOT / "testdata" / "spec015" / "route_snapshot_golden.json").read_text())["vectors"]


def write(path: Path, value) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    if isinstance(value, (bytes, str)):
        path.write_bytes(value if isinstance(value, bytes) else value.encode("utf-8"))
    else:
        path.write_text(json.dumps(value), encoding="utf-8")


def core(version: int) -> str:
    return format(version, "064x")


def entry(pool: str, kind: str, rates: dict) -> dict:
    native = kind == "native"
    return {
        "pool_model_id": f"pool/{pool}/{NATIVE_SLUG if native else GGUF_SLUG}",
        "artifact_hash_algorithm": "macprovider.snapshot-manifest.v1" if native else "macprovider.gguf-file.v1",
        "artifact_hash": NATIVE_HASH if native else GGUF_HASH,
        "allowed_runtime_sources": ["mlx_cache"] if native else ["llamacpp_loopback"],
        "license": "Apache-2.0",
        "paid_serving_attested": True,
        **rates,
        "disclosure_class": "pool_attested_unverified",
        "max_context_tokens": 8192,
    }


def version_content(pool: str, version: int) -> tuple[list, list]:
    """(model entries, attested members) of each version in the Pearl order."""
    entries, attested = [entry(pool, "native", NATIVE_RATES)], []
    if version >= 3:
        entries = [entry(pool, "native", NATIVE_NEW_RATES)]
    if version == 4:
        entries = []
    if version >= 5:
        entries = sorted([entry(pool, "native", NATIVE_NEW_RATES), entry(pool, "gguf", GGUF_RATES)], key=lambda e: e["pool_model_id"])
        attested = [{"provider_account_id": GGUF_ACCT, "runtime_classes": ["llamacpp_loopback"]}]
    if version >= 7:
        attested = []
    return entries, attested


def synthetic_verification(pool: str = POOL) -> dict:
    terms = {1: "11", 2: "11", 3: "33", 4: "44", 5: "55", 6: "55", 7: "77"}
    manifests = []
    for version in VERSIONS:
        entries, attested = version_content(pool, version)
        manifests.append({
            "manifest_version": version, "manifest_core_digest": core(version), "manifest_terms_digest": terms[version] * 32,
            "prev_manifest_core_hash": core(version - 1) if version > 1 else "0" * 64, "event_sha256": None,
            "not_before_unix": T0 + version * 3600, "expires_at_unix": T0 + (version + 1) * 3600, "encoding": 2,
            "settlement_mode": "enforce", "runtime_allowlist": ["llamacpp_loopback"],
            "model_entries": entries, "attested_members": attested,
        })
    return {
        "schema": "macprovider.trust-pool-manifest-verification.v2", "pool_id": pool, "creator_account_id": CREATOR,
        "launch_environment": "candidate", "root_issuer_key_id": "root-1", "root_issuer_public_key_fingerprint": "c" * 64,
        "root_event_sha256": "0" * 64, "newest_manifest_version": VERSIONS[-1], "manifests": manifests,
    }


def http_date(seconds: int) -> str:
    return email.utils.format_datetime(datetime.fromtimestamp(seconds, timezone.utc), usegmt=True)


def iso(seconds: int, fraction: str = "") -> str:
    return datetime.fromtimestamp(seconds, timezone.utc).strftime("%Y-%m-%dT%H:%M:%S") + fraction + "Z"


def headers(status: int, *, request_id: str, at: int, engine: str = "", digest: str = "") -> str:
    reason = {200: "OK", 404: "Not Found", 503: "Service Unavailable"}[status]
    lines = [f"HTTP/2 {status} {reason}", f"date: {http_date(at)}", f"x-request-id: {request_id}"]
    if engine:
        lines += [f"x-macprovider-engine: {engine}", "x-macprovider-model-disclosure: pool_attested_unverified",
                  f"x-macprovider-pool-manifest-core-digest: {digest}"]
    lines.append("content-type: application/json")
    return "\r\n".join(lines) + "\r\n\r\n"


class Fixture:
    def __init__(self, root: Path, verification: dict, events: dict[int, bytes] | None = None, root_event: bytes | None = None,
                 cli: str | None = None):
        self.root = root
        self.verification = verification
        self.pool = verification["pool_id"]
        self.nb = {m["manifest_version"]: m["not_before_unix"] for m in verification["manifests"]}
        self.digest = {m["manifest_version"]: m["manifest_core_digest"] for m in verification["manifests"]}
        self.events = events
        self.root_event = root_event
        self.native_id = f"pool/{self.pool}/{NATIVE_SLUG}"
        self.gguf_id = f"pool/{self.pool}/{GGUF_SLUG}"
        self.capture = root / "capture"
        self.cli = Path(cli) if cli else root / "cli" / "coordinator-cli"
        self.fake = cli is None

    def snapshot_digest(self, snapshot_json: str) -> str:
        path = self.root / "snapshot-for-digest.json"
        path.write_text(snapshot_json)
        out = subprocess.run([str(self.cli), "trust-pool-admin", "verify-route-snapshot", "--snapshot", str(path)],
                             check=True, capture_output=True, text=True).stdout
        return json.loads(out)[0]["route_snapshot_digest"]

    def build(self) -> Path:
        c = self.capture
        if self.fake:
            write(self.cli, FAKE_CLI)
            self.cli.chmod(0o755)
            write(self.cli.with_name("verification.json"), self.verification)
        write(c / "run.json", {
            "run_id": "trusted-pool-model-20261006T010203Z", "captured_at": iso(self.nb[7] + 7200),
            "expires_at": datetime.fromtimestamp(self.nb[7] + 7200 + 20 * 86400, timezone.utc).strftime("%Y-%m-%d"),
            "source_commit": SOURCE, "coordinator_version": "v1.8.219",
            "accepted_id": "Augustas11/macprovider:v1.8.219@" + "b" * 40,
            "native_member_cli_sha256": "c" * 64, "gguf_member_cli_sha256": "d" * 64, "llama_server_build": "b11149",
            "operator_role": "pearl-actor", "operator_identity": "operator-person-name", "hardware_profile": "mac-studio-m3-ultra-256gb",
            "pool_id": self.pool, "other_pool_id": OTHER_POOL, "creator_account_id": CREATOR, "buyer_account_id": BUYER,
            "native_member_provider_id": NATIVE_PROV, "native_member_account_id": NATIVE_ACCT,
            "gguf_member_provider_id": GGUF_PROV, "gguf_member_account_id": GGUF_ACCT,
            "native_entry": {"slug": NATIVE_SLUG, "artifact_hash": NATIVE_HASH},
            "gguf_entry": {"slug": GGUF_SLUG, "artifact_hash": GGUF_HASH},
            "manifest_versions": ROLES,
        })
        facts = {
            "deploy-build": {"production": True, "coordinator_version": "v1.8.219", "gateway_version": "v1.8.219", "contains_commit": SOURCE[:12]},
            "trusted-pools-enabled": {"coordinator": True, "gateway": True},
            "pricing-bounds-configured": {"bounds_set": True},
            "gateway-route-snapshot-v2": {"advertised": True},
            "payout-disabled": {"payout_enabled": False},
        }
        write(c / "preconditions.json", {k: {"status": "pass", "observed": v, "checked_at": iso(T0)} for k, v in facts.items()})
        write(c / "deploy.json", {"coordinator_deployed_at": iso(T0), "gateway_deployed_at": iso(T0 + 300),
                                  "native_member_cli_installed_at": iso(T0 + 600), "gguf_member_cli_installed_at": iso(T0 + 900)})
        write(c / "config/pricing-bounds.json", BOUNDS)
        write(c / "config/rewards.json", {"global_multiplier": 1.0, "provider_share": 0.9})
        write(c / "config/ledger-config-snapshots.json", [
            {"id": 7, "effective_at_utc": iso(T0 - 600), "config_hash": "9" * 64, "provider_share_bps": SHARE, "global_multiplier_ppm": MULTIPLIER}])
        owner_map = {GGUF_ACCT: [GGUF_PROV], "acct-unrelated": ["mp-unrelated-0009"]}
        digest, owners = BUILDER.owner_map_digest(owner_map)
        write(c / "config/provider-owner-account-ids.json", owner_map)
        write(c / "config/owner-authority-reload.json", {"bounds_set": True, "provider_owner_account_ids_applied": True,
                                                         "provider_owner_account_ids_providers": len(owners), "provider_owner_account_ids_sha256": digest})
        write(c / "pool/root-issuer-registered.json", self.root_event or json.dumps({"event_type": "root_issuer_registered", "pool_id": self.pool}))
        newest = VERSIONS[-1]
        current = (self.events or {}).get(newest) or json.dumps({
            "event_type": "manifest_accepted", "pool_id": self.pool, "manifest_version": newest, "manifest_core_digest": self.digest[newest]})
        write(c / "pool/current/manifest-accepted.json", current)
        for version in ROLES.values():
            self.write_get_pool(version, f"pool/v{version}/get-pool.json")
        self.write_get_pool(newest, "pool/current/get-pool.json")
        write(c / "pool/trustpool-events.json", [
            {"event_type": "pool_created", "n": 1}, {"event_type": "root_issuer_registered", "n": 1},
            {"event_type": "manifest_accepted", "n": 7}, {"event_type": "member_admitted", "n": 4},
            {"event_type": "buyer_authorized", "n": 1}, {"event_type": "delegation_granted", "n": 3},
            {"event_type": "lifecycle_changed", "n": 2},
        ])
        for kind, pmid, h, runtime, algo in (("native", self.native_id, NATIVE_HASH, "mlx_cache", "macprovider.snapshot-manifest.v1"),
                                             ("gguf", self.gguf_id, GGUF_HASH, "llamacpp_loopback", "macprovider.gguf-file.v1")):
            write(c / f"proposals/{kind}.json", {"schema": "pool_model_proposal.v1", "pool_id": self.pool, "runtime_source": runtime,
                                                 "catalog_model_key": None, "model_entry": {"pool_model_id": pmid, "artifact_hash": h,
                                                 "artifact_hash_algorithm": algo, "license": None, "paid_serving_attested": None}})
        self.write_admission()
        self.write_models()
        write(c / "never-global.json", [{"n": 0}])
        nb = self.nb
        self.paid("requests/native-nonstream", "native", 1, nb[1] + 60)
        self.paid("requests/native-stream", "native", 6, nb[6] + 60, stream=True)
        self.paid("requests/gguf-nonstream", "gguf", 5, nb[5] + 60)
        self.paid("requests/gguf-stream", "gguf", 6, nb[6] + 90, stream=True)
        self.paid("rotation/window-only/after", "native", 2, nb[2] + 60)
        self.paid("rotation/price-change/inflight", "native", 2, nb[3] - 30, settle=nb[3] + 30)
        self.paid("rotation/price-change/after", "native", 3, nb[3] + 120)
        self.paid("rotation/entry-removal/inflight", "native", 3, nb[4] - 30, settle=nb[4] + 30)
        self.paid("pause/resumed", "gguf", 5, nb[5] + 600)
        self.paid("restart/after", "native", 6, nb[6] + 600)
        self.paid("rotation/attestation-removal/inflight", "gguf", 6, nb[7] - 30, settle=nb[7] + 30, fenced=True)
        self.refusal("refusals/no-pool-header", 404, "model_not_found", nb[5] + 100, None, "native")
        self.refusal("refusals/other-pool", 404, "model_not_found", nb[5] + 110, OTHER_POOL, "native")
        self.refusal("refusals/wrong-engine", 503, "engine_unavailable", nb[5] + 120, self.pool, "gguf", engine="ollama")
        self.refusal("pause/paused", 503, "pool_unavailable", nb[5] + 300, self.pool, "gguf")
        self.refusal("rotation/entry-removal/after", 404, "model_not_found", nb[4] + 100, self.pool, "native")
        self.refusal("rotation/attestation-removal/after", 503, "no_providers_available", nb[7] + 100, self.pool, "gguf")
        self.probe("p1", 1, nb[2] - 30)
        self.probe("p2", 2, nb[2] + 30)
        for tier, rc, blocked, cannot in (("m9", 3, True, ["pool_model_entries/v1"]), ("p1816", 0, False, [])):
            write(c / f"rollback/preflight-{tier}.rc", f"{rc}\n")
            write(c / f"rollback/preflight-{tier}.json", {"pool_route_snapshots": 12, "open_pool_verdicts": 0,
                  "in_window_pool_attempts_without_verdict": 0, "rollback_blocked": blocked,
                  "manifest_history": {"target_tier": tier, "manifests": 7, "v2_snapshots": 7, "runtime_classes": ["llamacpp_loopback"],
                                       "extensions": ["pool_model_entries/v1"], "cannot_replay": cannot}})
        write(c / "restart/order.json", {"coordinator_restarted_at": iso(nb[6] + 10), "gateway_restarted_at": iso(nb[6] + 20)})
        return c

    def manifest(self, version: int) -> dict:
        return next(m for m in self.verification["manifests"] if m["manifest_version"] == version)

    def write_get_pool(self, version: int, relative: str | None = None) -> None:
        m = self.manifest(version)
        members = [NATIVE_PROV] if version < 5 else [GGUF_PROV, NATIVE_PROV]
        write(self.capture / (relative or f"pool/v{version}/get-pool.json"), {"pool": {
            "pool_id": self.pool, "creator_account_id": CREATOR, "lifecycle": "active", "routeable": True,
            "launch_environment": "candidate", "settlement_mode": "enforce", "runtime_allowlist": m["runtime_allowlist"],
            "manifest_version": version, "manifest_core_digest": m["manifest_core_digest"],
            "model_entries": m["model_entries"] or [], "attested_members": m["attested_members"] or [],
            "members": members, "revoked": [], "buyer_accounts": [BUYER],
        }})

    def write_admission(self) -> None:
        nb, snap, gguf_algo = self.nb, "macprovider.snapshot-manifest.v1", "macprovider.gguf-file.v1"

        def event(i, prov, state, reason, at, pmid=None, version=None, h=None, algo=None):
            bound = state == "catalog_priced"
            actor = f"pool_manifest:{self.pool}:{version}:{self.digest[version]}" if bound else ("coordinator" if state == "revoked" else "provider")
            return {"id": i, "provider_id": prov, "state": state, "actor": actor,
                    "reason_code": reason, "binding_scope": "pool" if pmid else None, "pool_id": self.pool if pmid else None,
                    "pool_model_id": pmid, "pool_manifest_version": version,
                    "pool_manifest_core_digest": self.digest[version] if version else None,
                    "expected_catalog_model_hash_algorithm": algo, "expected_catalog_model_hash": h, "created_at_utc": iso(at, ".123456789")}

        n, g = self.native_id, self.gguf_id
        write(self.capture / "admission/model-admission-events.json", [
            event(1, NATIVE_PROV, "offer_submitted", None, nb[1] + 5),
            event(2, NATIVE_PROV, "catalog_priced", "pool_manifest_bound", nb[1] + 10, n, 1, NATIVE_HASH, snap),
            event(3, NATIVE_PROV, "catalog_priced", "pool_manifest_rebound", nb[2] + 5, n, 2, NATIVE_HASH, snap),
            # the price change voids the delegated member's grant; it re-delegates and re-offers
            event(4, NATIVE_PROV, "revoked", "pool_membership_revoked", nb[3] + 5, n, 2, NATIVE_HASH, snap),
            event(5, NATIVE_PROV, "offer_submitted", None, nb[3] + 10),
            event(6, NATIVE_PROV, "catalog_priced", "pool_manifest_bound", nb[3] + 15, n, 3, NATIVE_HASH, snap),
            event(7, NATIVE_PROV, "revoked", "pool_membership_revoked", nb[4] + 5, n, 3, NATIVE_HASH, snap),
            event(8, GGUF_PROV, "offer_submitted", None, nb[5] + 5),
            event(9, GGUF_PROV, "catalog_priced", "pool_manifest_bound", nb[5] + 10, g, 5, GGUF_HASH, gguf_algo),
            event(10, NATIVE_PROV, "offer_submitted", None, nb[5] + 12),
            event(11, NATIVE_PROV, "catalog_priced", "pool_manifest_bound", nb[5] + 15, n, 5, NATIVE_HASH, snap),
            event(12, GGUF_PROV, "revoked", "pool_membership_revoked", nb[7] + 5, g, 5, GGUF_HASH, gguf_algo),
        ])

    def write_models(self) -> None:
        m = self.manifest(5)
        items = []
        for e in m["model_entries"]:
            items.append({"id": e["pool_model_id"], "object": "model", "owned_by": "macprovider", "macprovider_pool_model": {
                "pool_id": self.pool, "pool_model_id": e["pool_model_id"], "artifact_hash_algorithm": e["artifact_hash_algorithm"],
                "artifact_hash": e["artifact_hash"], "manifest_core_digest": m["manifest_core_digest"], "manifest_version": 5,
                "runtime_sources": e["allowed_runtime_sources"], "disclosure_class": "pool_attested_unverified",
                "disclosure_text": "Pool-attested, not network-verified", "price_source": "pool_creator_signed",
                "max_context_tokens": e["max_context_tokens"],
                "price": {**{k: e[k] for k in NATIVE_RATES}, "global_multiplier_ppm": MULTIPLIER}}})
        write(self.capture / "models/pool.json", {"object": "list", "data": items})
        write(self.capture / "models/global.json", {"object": "list", "data": [{"id": "qwen3.6-27b", "object": "model"}]})

    def snapshot_rows(self, kind: str, version: int, coord: str, dispatch: int) -> list:
        native = kind == "native"
        pmid = self.native_id if native else self.gguf_id
        rates = next(e for e in self.manifest(version)["model_entries"] if e["pool_model_id"] == pmid)
        snap = dict(GOLDEN[1 if native else 2]["route_snapshot"])
        h = NATIVE_HASH if native else GGUF_HASH
        algo = "macprovider.snapshot-manifest.v1" if native else "macprovider.gguf-file.v1"
        snap.update({
            "request_id": coord, "attempt_n": 1, "provider_id": NATIVE_PROV if native else GGUF_PROV, "pool_id": self.pool,
            "model_id": pmid, "pool_model_id": pmid, "manifest_version": version, "manifest_core_digest": self.digest[version],
            "pool_generation": 40 + version, "expected_catalog_model_hash": h, "provider_reported_model_hash": h,
            "expected_catalog_model_hash_algorithm": algo, "provider_reported_model_hash_algorithm": algo,
            **{f"pool_model_{k}": rates[k] for k in NATIVE_RATES},
            "pool_model_pricing_bounds_sha256": BUILDER.bounds_digest(BOUNDS), "pool_model_global_multiplier_ppm": MULTIPLIER,
            "pool_model_provider_share_bps": SHARE, "pool_model_config_snapshot_id": 7,
            "route_decision_ts_unix_ms": dispatch * 1000, "request_start_ts_unix_ms": dispatch * 1000 - 100,
        })
        if not native:
            snap.update({"pool_operator_account_id": CREATOR, "pool_member_account_id": GGUF_ACCT})
        text = json.dumps(snap, sort_keys=True)
        return [{"request_id": coord, "attempt_n": 1, "provider_id": snap["provider_id"], "route_snapshot_digest": self.snapshot_digest(text),
                 "route_snapshot_json": text, "created_at_utc": iso(dispatch)}], rates

    def paid(self, name: str, kind: str, version: int, dispatch: int, *, stream: bool = False, settle: int | None = None,
             fenced: bool = False) -> None:
        base = self.capture / name
        rid = "req-" + name.replace("/", "-")
        coord = "coord-" + rid
        native = kind == "native"
        pmid = self.native_id if native else self.gguf_id
        write(base / "response.headers", headers(200, request_id=rid, at=dispatch, engine="mlx_cache" if native else "llamacpp_loopback",
                                                 digest=self.digest[version]))
        if stream:
            chunks = [{"choices": [{"delta": {"content": "1 2 3"}, "finish_reason": None}]},
                      {"choices": [{"delta": {"content": " 4 5"}, "finish_reason": "stop"}]},
                      {"choices": [], "usage": {"prompt_tokens": PROMPT, "completion_tokens": COMPLETION}}]
            write(base / "response.sse", "".join(f"data: {json.dumps(c)}\n\n" for c in chunks) + "data: [DONE]\n\n")
        else:
            write(base / "response.json", {"choices": [{"message": {"role": "assistant", "content": "secret completion text"}, "finish_reason": "stop"}],
                                           "usage": {"prompt_tokens": 52, "completion_tokens": COMPLETION}})
        write(base / "request_log.json", [{"request_id": coord, "attempt_n": 1, "external_request_id": rid, "status": 200, "pool_id": self.pool,
                                           "model": pmid}])
        rows, rates = self.snapshot_rows(kind, version, coord, dispatch)
        write(base / "route_snapshots.json", rows)
        h = NATIVE_HASH if native else GGUF_HASH
        usage = "coordinator_observed" if native else "pool_operator_attested"
        settled_at = (settle if settle is not None else dispatch + 5) * 1000
        provider = NATIVE_PROV if native else GGUF_PROV
        write(base / "attempt_outputs.json", [{"request_id": coord, "attempt_n": 1, "provider_id": provider,
                                              "terminal_state": "normal_done", "usage_source": usage, "terminal_state_ts_unix_ms": settled_at - 1000}])
        write(base / "receipt_verdicts.json", [{
            "request_id": coord, "attempt_n": 1, "provider_id": provider, "receipt_result": "valid",
            "settlement_outcome": "quarantined" if fenced else "verified",
            "reason": "pool_route_fence_not_settlement_eligible" if fenced else "verified_settlement", "closed": 1,
            "pool_label_status": "verified", "route_snapshot_digest": rows[0]["route_snapshot_digest"], "provider_reported_model_hash": h,
            "expected_catalog_model_hash": h, "model_id": pmid, "model_hash": h, "received_at_unix_ms": settled_at,
        }])
        gross = BUILDER.round_half_even((PROMPT * rates["prompt_rate_per_mtok"] + COMPLETION * rates["completion_rate_per_mtok"]) * MULTIPLIER, 10**12)
        write(base / "ledger.json", [{
            "id": 7, "request_id": coord, "attempt_n": 1, "provider_id": provider, "status": "credited",
            "charged_prompt_tokens": PROMPT, "cached_prompt_tokens": None, "completion_tokens": COMPLETION, "estimated_completion_tokens": None,
            "usage_source": "provider_reported", "prompt_rate_per_mtok": rates["prompt_rate_per_mtok"],
            "completion_rate_per_mtok": rates["completion_rate_per_mtok"], "global_multiplier_ppm": MULTIPLIER, "gross_credits": 0 if fenced else gross,
            "provider_share_bps": SHARE, "provider_credits": 0 if fenced else BUILDER.round_half_even(gross * SHARE, 10000),
            "quarantined": 1 if fenced else 0, "payable": 0 if fenced else 1,
            "quarantine_reason": "pool_route_fence_not_settlement_eligible" if fenced else None,
        }])
        if fenced:
            write(base / "quota_reservations.json", [{"request_id": rid, "account_id": BUYER, "status": "refunded", "settled_tokens": 0, "settlement_hold": 0}])
            write(base / "usage_events.json", "")
        else:
            write(base / "quota_reservations.json", [{"request_id": rid, "account_id": BUYER, "status": "settled",
                                                      "settled_tokens": PROMPT + COMPLETION, "settlement_hold": 0}])
            write(base / "usage_events.json", [{"request_id": rid, "prompt_tokens": PROMPT, "completion_tokens": COMPLETION, "token_source": usage,
                                                "outcome": "settled"}])

    def probe(self, label: str, version: int, dispatch: int) -> None:
        base = self.capture / "rotation/window-only/probes" / label
        rid, coord = f"req-probe-{label}", f"coord-probe-{label}"
        write(base / "response.headers", headers(200, request_id=rid, at=dispatch, engine="mlx_cache", digest=self.digest[version]))
        write(base / "request_log.json", [{"request_id": coord, "attempt_n": 1, "external_request_id": rid, "status": 200, "pool_id": self.pool,
                                           "model": self.native_id}])
        rows, _ = self.snapshot_rows("native", version, coord, dispatch)
        write(base / "route_snapshots.json", rows)
        write(base / "quota_reservations.json", [{"request_id": rid, "account_id": BUYER, "status": "settled", "settled_tokens": 10, "settlement_hold": 0}])

    def refusal(self, name: str, status: int, code: str, at: int, pool: str | None, kind: str, engine: str | None = None) -> None:
        base = self.capture / name
        rid = "req-" + name.replace("/", "-")
        write(base / "response.headers", headers(status, request_id=rid, at=at))
        write(base / "response.json", {"error": {"code": code, "message": "x"}})
        write(base / "request.json", {"pool_select": pool, "engine_select": engine, "model": self.native_id if kind == "native" else self.gguf_id,
                                      "stream": False})
        write(base / "request_log.json", "")
        write(base / "route_snapshots.json", "")
        write(base / "ledger.json", "")
        write(base / "quota_reservations.json", [{"request_id": rid, "account_id": BUYER, "status": "refunded", "settled_tokens": 0, "settlement_hold": 0}])


def valid_signed(**overrides):
    signed = {
        "journey_id": TRUSTED_POOL_MODEL_JOURNEY_ID,
        "execution_mode": "production-operator-internal-pool",
        "environment": {"class": "production-operator-internal-pool", "hardware_profile": "studio", "candidate": "x"},
        "requirement_ids": ["SPEC-042-R015"],
        "observations": {**BUILDER.TRUSTED_POOL_MODEL_FIXED_OBSERVATIONS, "buyer_visible_usage_equals_debit": False},
        "candidate_identity": {
            "coordinator_version": "v1.8.219", "accepted_id": "Augustas11/macprovider:v1.8.219@" + "b" * 40,
            "native_member_cli_sha256": "c" * 64, "gguf_member_cli_sha256": "d" * 64, "llama_server_build": "b11149",
            "pool_id": POOL, "native_pool_model_id": f"pool/{POOL}/{NATIVE_SLUG}", "native_artifact_hash": NATIVE_HASH,
            "gguf_pool_model_id": f"pool/{POOL}/{GGUF_SLUG}", "gguf_artifact_hash": GGUF_HASH, "manifest_version": 7,
            "manifest_core_digest": core(7), "pricing_bounds_sha256": BUILDER.bounds_digest(BOUNDS), "fingerprint_salt": "f" * 64,
        },
        "artifacts": [{"id": TRUSTED_POOL_MODEL_ARTIFACT_ID, "sha256": "e" * 64, "source": "journeys/evidence/x"}],
        "steps": [{"id": step_id, "status": "pass", "artifacts": [TRUSTED_POOL_MODEL_ARTIFACT_ID]} for step_id in TRUSTED_POOL_MODEL_STEP_ID_ORDER],
    }
    signed.update(overrides)
    return signed


def validate(signed, requirement_id="SPEC-042-R015", journeys=None):
    result = ValidationResult()
    _validate_trusted_pool_model_journey_result(signed, requirement_id, journeys if journeys is not None else [TRUSTED_POOL_MODEL_JOURNEY_ID],
                                                signed["artifacts"], signed["steps"], "evidence[0]", result)
    return result.errors


class TrustedPoolModelValidatorTests(unittest.TestCase):
    def test_valid_payload_promotes_each_mapped_requirement(self) -> None:
        for requirement_id in sorted(TRUSTED_POOL_MODEL_PROMOTABLE_REQUIREMENT_IDS):
            self.assertEqual([], validate(valid_signed(requirement_ids=[requirement_id]), requirement_id), requirement_id)

    def test_spec047_r011_is_not_promotable(self) -> None:
        # R011 promotion also needs the model_admission_probe_evidence.v1 record.
        self.assertNotIn("SPEC-047-R011", TRUSTED_POOL_MODEL_PROMOTABLE_REQUIREMENT_IDS)
        self.assertTrue(any("cannot promote SPEC-047-R011" in e for e in validate(valid_signed(requirement_ids=["SPEC-047-R011"]), "SPEC-047-R011")))

    def test_rejects_wrong_fixed_observation(self) -> None:
        for field, bad in (("settlement_mode", "observe"), ("payout_ready_mutated", True), ("global_route_absent", False)):
            signed = valid_signed()
            signed["observations"][field] = bad
            self.assertTrue(any(field in e for e in validate(signed)), field)

    def test_rejects_missing_or_reordered_steps(self) -> None:
        signed = valid_signed()
        signed["steps"] = signed["steps"][:-1]
        self.assertTrue(any("missing" in e for e in validate(signed)))
        signed = valid_signed()
        signed["steps"] = list(reversed(signed["steps"]))
        self.assertTrue(any("ordered" in e for e in validate(signed)))

    def test_rejects_unmapped_journey_and_wrong_mode(self) -> None:
        self.assertTrue(validate(valid_signed(), journeys=["JOURNEY-TRUSTED-POOL-EXTERNAL-RUNTIME"]))
        self.assertTrue(validate(valid_signed(execution_mode="isolated-candidate-paid-path")))

    def test_journey_document_matches_the_contract_exactly(self) -> None:
        # LOW (architect R1): the document's ordered step list and requirement
        # set must equal the machine contract, not merely mention each id.
        text = (REPO_ROOT / "journeys" / f"{TRUSTED_POOL_MODEL_JOURNEY_ID}.md").read_text(encoding="utf-8")
        steps_section = text.split("## Physical steps", 1)[1].split("\n## ", 1)[0]
        ordered = re.findall(r"^\s*[0-9]+\. `(step-[0-9a-z-]+)`", steps_section, re.M)
        self.assertEqual(list(TRUSTED_POOL_MODEL_STEP_ID_ORDER), ordered)
        requirements = re.search(r"^Requirements: (.+)$", text, re.M).group(1)
        self.assertEqual(sorted(TRUSTED_POOL_MODEL_PROMOTABLE_REQUIREMENT_IDS), sorted(x.strip() for x in requirements.split(",")))

    def test_conformance_maps_journey_without_promoting(self) -> None:
        rows = {row["requirement_id"]: row for row in json.loads((REPO_ROOT / "specs" / "CONFORMANCE.json").read_text())["requirements"]}
        for requirement_id in TRUSTED_POOL_MODEL_PROMOTABLE_REQUIREMENT_IDS:
            self.assertIn(TRUSTED_POOL_MODEL_JOURNEY_ID, rows[requirement_id]["journeys"])
            self.assertEqual("pending", rows[requirement_id]["state"])
        self.assertNotIn(TRUSTED_POOL_MODEL_JOURNEY_ID, rows["SPEC-047-R011"]["journeys"])


class CaptureCase(unittest.TestCase):
    def setUp(self) -> None:
        self._tmp = tempfile.TemporaryDirectory()
        self.root = Path(self._tmp.name)
        self.fixture = Fixture(self.root, synthetic_verification())
        self.capture = self.fixture.build()

    def tearDown(self) -> None:
        self._tmp.cleanup()

    def build(self):
        return BUILDER.build_evidence(self.capture, str(self.fixture.cli))[0]

    def assert_rejected(self, fragment: str, call=None) -> None:
        stderr = io.StringIO()
        with contextlib.redirect_stderr(stderr), self.assertRaises(SystemExit):
            (call or self.build)()
        self.assertIn(fragment, stderr.getvalue())
        self.assertIn("build-trusted-pool-model-journey-result:", stderr.getvalue())

    def mutate_rows(self, relative: str, **changes) -> None:
        path = self.capture / relative
        rows = json.loads(path.read_text())
        for row in rows:
            row.update(changes)
        path.write_text(json.dumps(rows))

    def mutate_snapshot(self, relative: str, recompute: bool = True, **changes) -> None:
        """Edit the stored route_snapshot_json; by default also re-store the
        digest the coordinator would compute, so the semantic check is what fails."""
        path = self.capture / relative
        rows = json.loads(path.read_text())
        for row in rows:
            snap = json.loads(row["route_snapshot_json"])
            snap.update(changes)
            row["route_snapshot_json"] = json.dumps(snap, sort_keys=True)
            if recompute:
                row["route_snapshot_digest"] = self.fixture.snapshot_digest(row["route_snapshot_json"])
            for field in ("request_id", "attempt_n", "provider_id"):
                row[field] = snap[field]
        path.write_text(json.dumps(rows))
        verdicts = path.with_name("receipt_verdicts.json")
        if recompute and verdicts.exists():
            values = json.loads(verdicts.read_text())
            for verdict in values:
                verdict["route_snapshot_digest"] = rows[0]["route_snapshot_digest"]
            verdicts.write_text(json.dumps(values))

    def mutate_json(self, relative: str, mutate) -> None:
        path = self.capture / relative
        value = json.loads(path.read_text())
        mutate(value)
        path.write_text(json.dumps(value))

    def mutate_verification(self, mutate) -> None:
        mutate(self.fixture.verification)
        write(self.fixture.cli.with_name("verification.json"), self.fixture.verification)

    def revalidate(self, evidence) -> None:
        BUILDER.validate_evidence(evidence, now=datetime.now(timezone.utc))


class TrustedPoolModelCaptureTests(CaptureCase):
    def test_valid_capture_builds_redacted_evidence(self) -> None:
        evidence, bundle = BUILDER.build_evidence(self.capture, str(self.fixture.cli))
        self.assertEqual(BUILDER.EVIDENCE_SCHEMA, evidence["schema_version"])
        self.assertEqual(list(TRUSTED_POOL_MODEL_STEP_ID_ORDER), [s["id"] for s in evidence["steps"]])
        self.assertEqual(BUILDER.SUMMARY, evidence["result"]["summary"])
        self.assertEqual(sorted(TRUSTED_POOL_MODEL_PROMOTABLE_REQUIREMENT_IDS), evidence["requirement_ids"])
        self.assertFalse(evidence["observations"]["buyer_visible_usage_equals_debit"])
        self.assertEqual(["root-issuer-registered.json", "v7.json"], sorted(bundle))
        self.assertEqual(list(VERSIONS), [m["manifest_version"] for m in evidence["manifests"]])
        self.assertEqual(13, evidence["route_snapshot_digests_recomputed"])
        text = json.dumps(evidence)
        for raw in (CREATOR, BUYER, NATIVE_PROV, NATIVE_ACCT, GGUF_PROV, GGUF_ACCT, OTHER_POOL, "operator-person-name", "secret completion text", "1 2 3"):
            self.assertNotIn(raw, text)
        self.revalidate(evidence)
        signed = valid_signed(observations=evidence["observations"], candidate_identity=evidence["candidate_identity"],
                              environment=evidence["environment"], steps=evidence["steps"])
        self.assertEqual([], validate(signed))

    def test_r016_needs_the_attestation_removal_inflight_request(self) -> None:
        shutil.rmtree(self.capture / "rotation/attestation-removal/inflight")
        evidence = self.build()
        self.assertNotIn("SPEC-042-R016", evidence["requirement_ids"])
        self.assertIn("SPEC-042-R015", evidence["requirement_ids"])

    def test_fenced_inflight_must_be_zero_billed(self) -> None:
        for label, path, change, fragment in (
            ("payable", "rotation/attestation-removal/inflight/ledger.json", {"payable": 1}, "no payable credit"),
            ("credited", "rotation/attestation-removal/inflight/ledger.json", {"provider_credits": 5}, "zeroed and quarantined"),
            ("verified", "rotation/attestation-removal/inflight/receipt_verdicts.json", {"settlement_outcome": "verified"}, "settlement_outcome"),
        ):
            with self.subTest(label=label):
                self.setUp()
                self.mutate_rows(path, **change)
                self.assert_rejected(fragment)
        self.setUp()
        write(self.capture / "rotation/attestation-removal/inflight/usage_events.json",
              [{"request_id": "req-rotation-attestation-removal-inflight", "prompt_tokens": 5, "completion_tokens": 1,
                "token_source": "pool_operator_attested", "outcome": "settled"}])
        self.assert_rejected("no buyer-final debit")

    def test_accepts_entry_revoked_reason_for_the_removal(self) -> None:
        self.mutate_json("admission/model-admission-events.json", lambda rows: rows[6].update(reason_code="pool_manifest_entry_revoked"))
        self.build()

    def test_cli_refusal_fails_capture(self) -> None:
        self.mutate_verification(lambda v: v.update(refuse=True))
        self.assert_rejected("verify-manifest refused")

    def test_route_snapshot_digest_is_recomputed(self) -> None:
        self.mutate_snapshot("requests/gguf-nonstream/route_snapshots.json", recompute=False, pool_generation=99)
        self.assert_rejected("recomputed route snapshot digest")

    def test_current_get_pool_must_be_the_newest_manifest(self) -> None:
        self.mutate_json("pool/current/get-pool.json", lambda d: d["pool"].update(manifest_version=6, manifest_core_digest=core(6)))
        self.assert_rejected("current get-pool")

    def test_history_must_be_complete(self) -> None:
        self.mutate_verification(lambda v: v["manifests"].pop(3))
        self.assert_rejected("complete contiguous history")

    def test_get_pool_must_equal_the_verified_core(self) -> None:
        self.mutate_json("pool/v5/get-pool.json", lambda doc: doc["pool"]["model_entries"][0].update(completion_rate_per_mtok=99999))
        self.assert_rejected("get-pool entries must equal the verified core's")

    def test_exact_role_sets(self) -> None:
        foreign = entry(POOL, "gguf", GGUF_RATES)
        foreign.update(pool_model_id=f"pool/{POOL}/zz-foreign", artifact_hash="e" * 64)
        for label, mutate, fragment in (
            ("foreign entry", lambda v: [v["manifests"][i]["model_entries"].append(foreign) for i in (4, 5)], "no foreign entries"),
            ("extra attestation", lambda v: v["manifests"][5]["attested_members"].append({"provider_account_id": "acct-zzz", "runtime_classes": ["llamacpp_loopback"]}),
             "keeper rotation must keep"),
            ("attested before gguf", lambda v: v["manifests"][0]["attested_members"].append({"provider_account_id": GGUF_ACCT, "runtime_classes": ["llamacpp_loopback"]}),
             "attested members must be exactly"),
        ):
            with self.subTest(label=label):
                self.setUp()
                self.mutate_verification(mutate)
                for version in ROLES.values():
                    self.fixture.write_get_pool(version)
                self.fixture.write_get_pool(7, "pool/current/get-pool.json")
                self.assert_rejected(fragment)

    def test_entry_grammar(self) -> None:
        for label, change, fragment in (
            ("context zero", {"max_context_tokens": 0}, "max_context_tokens"),
            ("licence ref", {"license": "LicenseRef-custom"}, "pinned SPDX"),
            ("wrong pairing", {"allowed_runtime_sources": ["llamacpp_loopback"]}, "does not pair"),
            ("unsorted runtimes", {"allowed_runtime_sources": ["mlxlm_loopback", "mlx_cache"]}, "sorted and unique"),
        ):
            with self.subTest(label=label):
                self.setUp()
                self.mutate_verification(lambda v: v["manifests"][0]["model_entries"][0].update(change))
                self.fixture.write_get_pool(1)
                self.assert_rejected(fragment)

    def test_owner_binding(self) -> None:
        owner_map = {"acct-someone-else": [GGUF_PROV]}
        digest, owners = BUILDER.owner_map_digest(owner_map)
        write(self.capture / "config/provider-owner-account-ids.json", owner_map)
        self.mutate_json("config/owner-authority-reload.json", lambda d: d.update(provider_owner_account_ids_sha256=digest,
                                                                                  provider_owner_account_ids_providers=len(owners)))
        self.assert_rejected("recorded owner account must be the attested account")

    def test_owner_map_digest_must_match_the_reload(self) -> None:
        self.mutate_json("config/owner-authority-reload.json", lambda d: d.update(provider_owner_account_ids_sha256="9" * 64))
        self.assert_rejected("recomputed provider_owner_account_ids digest")

    def test_request_joins(self) -> None:
        for label, mutate, fragment in (
            ("foreign usage event", lambda: self.mutate_rows("requests/gguf-stream/usage_events.json", request_id="req-other"),
             "usage event must be the X-Request-ID's"),
            ("foreign ledger", lambda: self.mutate_rows("requests/native-nonstream/ledger.json", attempt_n=2), "join exactly one route snapshot"),
            ("unmapped log", lambda: self.mutate_rows("requests/native-stream/request_log.json", external_request_id="req-other"), "carry the X-Request-ID"),
            ("log model", lambda: self.mutate_rows("requests/native-stream/request_log.json", model="pool/x/y"), "request_log model"),
            ("extra attempt", lambda: self.mutate_json("requests/gguf-nonstream/request_log.json", lambda rows: rows.append(
                dict(rows[0], attempt_n=2))), "exactly one route snapshot"),
            ("foreign buyer", lambda: self.mutate_rows("requests/gguf-nonstream/quota_reservations.json", account_id="acct-other"),
             "journey buyer's"),
            ("provider hash", lambda: self.mutate_snapshot("requests/gguf-nonstream/route_snapshots.json", provider_reported_model_hash="f" * 64),
             "provider-reported"),
            ("verdict digest", lambda: self.mutate_rows("requests/native-nonstream/receipt_verdicts.json", route_snapshot_digest="f" * 64),
             "route snapshot digest"),
            ("generation", lambda: self.mutate_snapshot("requests/native-nonstream/route_snapshots.json", pool_generation=0), "pool_generation"),
            ("receipt model", lambda: self.mutate_rows("requests/gguf-stream/receipt_verdicts.json", model_id="qwen3.6-27b"), "R-13.3"),
        ):
            with self.subTest(label=label):
                self.setUp()
                mutate()
                self.assert_rejected(fragment)

    def test_pricing(self) -> None:
        for label, mutate, fragment in (
            ("gross", lambda: self.mutate_rows("requests/native-nonstream/ledger.json", gross_credits=1), "SPEC-005 recomputation"),
            ("provider", lambda: self.mutate_rows("requests/gguf-nonstream/ledger.json", provider_credits=1), "provider_credits"),
            ("bounds digest", lambda: self.mutate_snapshot("requests/gguf-stream/route_snapshots.json", pool_model_pricing_bounds_sha256="9" * 64),
             "recomputed bounds digest"),
            ("int64", lambda: self.mutate_json("config/pricing-bounds.json", lambda b: b.update(max_completion_rate_per_mtok=2**63)), "pricing_bounds"),
            ("overflow", lambda: self.mutate_json("config/pricing-bounds.json", lambda b: b.update(max_completion_rate_per_mtok=9_000_000_000_000)),
             "must fit int64"),
            ("snapshot rate", lambda: self.mutate_snapshot("requests/gguf-nonstream/route_snapshots.json", pool_model_completion_rate_per_mtok=1),
             "signed entry rate"),
            ("config share", lambda: self.mutate_rows("config/ledger-config-snapshots.json", provider_share_bps=8000), "ledger config snapshot"),
            ("config id", lambda: self.mutate_snapshot("requests/native-nonstream/route_snapshots.json", pool_model_config_snapshot_id=8),
             "captured ledger config snapshot"),
            ("live share", lambda: write(self.capture / "config/rewards.json", {"global_multiplier": 1.0, "provider_share": 0.8}),
             "live rewards"),
        ):
            with self.subTest(label=label):
                self.setUp()
                mutate()
                self.assert_rejected(fragment)

    def test_temporal_boundaries(self) -> None:
        nb = self.fixture.nb
        for label, mutate, fragment in (
            ("inflight after activation", lambda: self.mutate_snapshot("rotation/price-change/inflight/route_snapshots.json",
                                                                       route_decision_ts_unix_ms=(nb[3] + 1) * 1000), "dispatched before the price change"),
            ("settled before activation", lambda: self.mutate_rows("rotation/entry-removal/inflight/receipt_verdicts.json",
                                                                   received_at_unix_ms=(nb[4] - 1) * 1000), "settle after it"),
            ("refusal before activation", lambda: self.fixture.refusal("rotation/entry-removal/after", 404, "model_not_found", nb[4] - 10,
                                                                       self.fixture.pool, "native"), "follow its activation"),
            ("revocation before activation", lambda: self.mutate_json("admission/model-admission-events.json",
                                                                      lambda rows: rows[6].update(created_at_utc=iso(nb[4] - 10))),
             "after the removal activates"),
            ("restart before", lambda: self.mutate_snapshot("restart/after/route_snapshots.json", route_decision_ts_unix_ms=nb[6] * 1000),
             "after the restart"),
            ("fenced dispatched late", lambda: self.mutate_snapshot("rotation/attestation-removal/inflight/route_snapshots.json",
                                                                    route_decision_ts_unix_ms=(nb[7] + 1) * 1000), "before the attestation removal"),
        ):
            with self.subTest(label=label):
                self.setUp()
                mutate()
                self.assert_rejected(fragment)

    def test_probes_are_real_requests_on_both_sides(self) -> None:
        nb = self.fixture.nb
        shutil.rmtree(self.capture / "rotation/window-only/probes/p2")
        self.fixture.probe("p2", 1, nb[2] - 10)
        self.assert_rejected("both sides")
        self.setUp()
        self.mutate_rows("rotation/window-only/probes/p1/request_log.json", external_request_id="req-unrelated")
        self.assert_rejected("carry the X-Request-ID")
        self.setUp()
        self.mutate_snapshot("rotation/window-only/probes/p2/route_snapshots.json", manifest_version=1, manifest_core_digest=core(1))
        self.assert_rejected("window_rotation terms")

    def test_refusals_are_bound_to_their_request(self) -> None:
        for label, path, mutate, fragment in (
            ("wrong model", "rotation/entry-removal/after/request.json", lambda d: d.update(model=f"pool/{POOL}/{GGUF_SLUG}"), "native entry"),
            ("wrong pool", "refusals/other-pool/request.json", lambda d: d.update(pool_select=POOL), "pool selector"),
            ("no engine", "refusals/wrong-engine/request.json", lambda d: d.update(engine_select=None), "select an engine"),
        ):
            with self.subTest(label=label):
                self.setUp()
                self.mutate_json(path, mutate)
                self.assert_rejected(fragment)
        self.setUp()
        path = self.capture / "pause/paused/response.headers"
        path.write_text(path.read_text().replace("content-type", "x-macprovider-model-disclosure: pool_attested_unverified\r\ncontent-type"))
        self.assert_rejected("disclosure header")

    def test_models_view_is_closed(self) -> None:
        def add_foreign(doc):
            item = json.loads(json.dumps(doc["data"][0]))
            item["id"] = item["macprovider_pool_model"]["pool_model_id"] = f"pool/{OTHER_POOL}/x"
            doc["data"].append(item)
        for label, mutate, fragment in (
            ("foreign pool id", add_foreign, "pool and entry ids must be the selected pool's"),
            ("object", lambda d: d["data"][0].update(object="list"), "object must be model"),
            ("missing field", lambda d: d["data"][0]["macprovider_pool_model"].pop("runtime_sources"), "missing ['runtime_sources']"),
            ("duplicate", lambda d: d["data"].append(d["data"][0]), "repeat an id"),
            ("catalog model", lambda d: d["data"].append({"id": "qwen3.6-27b", "object": "model"}), "only the pool's entries"),
            ("runtime subset", lambda d: d["data"][0]["macprovider_pool_model"].update(runtime_sources=[]), "allowed_runtime_sources"),
        ):
            with self.subTest(label=label):
                self.setUp()
                self.mutate_json("models/pool.json", mutate)
                self.assert_rejected(fragment)
        self.setUp()
        self.mutate_json("models/global.json", lambda d: d["data"].append({"id": self.fixture.native_id}))
        self.assert_rejected("global models view")

    def test_revocations_are_exact(self) -> None:
        for label, change, fragment in (
            ("binding actor", (2, {"actor": f"pool_manifest:{POOL}:1:{core(1)}"}), "actor must name its own pool, version and core"),
            ("revocation actor", (6, {"actor": "provider"}), "revocation's actor must be coordinator"),
            ("revocation entry", (6, {"pool_model_id": f"pool/{POOL}/{GGUF_SLUG}"}), "revocation's pool_model_id"),
            ("revocation generation", (11, {"pool_manifest_version": 6, "pool_manifest_core_digest": core(6)}), "revocation's pool_manifest_version"),
            ("revocation hash", (3, {"expected_catalog_model_hash": "f" * 64}), "revocation's expected_catalog_model_hash"),
        ):
            with self.subTest(label=label):
                self.setUp()
                self.mutate_json("admission/model-admission-events.json", lambda rows: rows[change[0]].update(change[1]))
                self.assert_rejected(fragment)
        self.setUp()
        self.mutate_json("admission/model-admission-events.json", lambda rows: rows[6].update(actor="something-else"))
        self.assert_rejected("actor must be provider, coordinator")

    def test_native_readd_needs_a_fresh_binding(self) -> None:
        self.mutate_json("admission/model-admission-events.json", lambda rows: rows.pop(10))
        self.assert_rejected("re-added native entry must be bound again")

    def test_price_change_requires_reoffer(self) -> None:
        self.mutate_json("admission/model-admission-events.json", lambda rows: rows.pop(4))
        self.assert_rejected("re-offer")

    def test_bundle_hygiene(self) -> None:
        self.mutate_json("pool/current/manifest-accepted.json", lambda d: d.update(operation_id="see https://internal.corp/x"))
        self.assert_rejected("bundle v7.json")
        self.setUp()
        (self.capture / "pool/current/manifest-accepted.json").write_text(
            '{"event_type": "manifest_accepted", "event_type": "manifest_accepted", "manifest_version": 7}')
        self.assert_rejected("duplicate JSON object key")

    def test_preconditions_are_exact(self) -> None:
        for label, mutate, fragment in (
            ("payout enabled", lambda p: p["payout-disabled"]["observed"].update(payout_enabled=True), "payout_enabled must be False"),
            ("missing fact", lambda p: p["trusted-pools-enabled"]["observed"].pop("gateway"), "missing ['gateway']"),
            ("wrong commit", lambda p: p["deploy-build"]["observed"].update(contains_commit="b" * 12), "contains_commit"),
        ):
            with self.subTest(label=label):
                self.setUp()
                self.mutate_json("preconditions.json", mutate)
                self.assert_rejected(fragment)

    def test_duplicates_fail_closed(self) -> None:
        path = self.capture / "requests/native-nonstream/response.headers"
        path.write_text(path.read_text().replace("content-type: application/json", "x-request-id: other"))
        self.assert_rejected("repeats")
        self.setUp()
        (self.capture / "config/pricing-bounds.json").write_text('{"min_prompt_rate_per_mtok": 1, "min_prompt_rate_per_mtok": 2}')
        self.assert_rejected("duplicate JSON object key")

    def test_expiry_window(self) -> None:
        self.mutate_json("run.json", lambda r: r.update(expires_at="2099-01-01"))
        self.assert_rejected("within 30 days")

    def test_refusal_requires_one_refunded_reservation(self) -> None:
        write(self.capture / "pause/paused/quota_reservations.json", "")
        self.assert_rejected("exactly one gateway reservation")

    def test_rejects_ordering_violation(self) -> None:
        self.mutate_json("run.json", lambda r: r["manifest_versions"].update(price_change=4, entry_removal=3))
        self.assert_rejected("window_rotation < price_change < entry_removal")

    def test_rejects_symlinked_capture_subdirectory(self) -> None:
        requests = self.capture / "requests"
        elsewhere = self.root / "elsewhere-requests"
        requests.rename(elsewhere)
        requests.symlink_to(elsewhere, target_is_directory=True)
        self.assert_rejected("absent or unsafe")


class TrustedPoolModelTamperTests(CaptureCase):
    """CRITICAL (security R1): committed evidence is re-validated in full."""

    def setUp(self) -> None:
        super().setUp()
        self.evidence = self.build()

    def tampered(self, mutate):
        bad = json.loads(json.dumps(self.evidence))
        mutate(bad)
        return bad

    def test_semantically_empty_or_tampered_evidence_is_refused(self) -> None:
        for label, mutate in (
            ("empty requests", lambda e: e.update(requests={})),
            ("empty admission", lambda e: e.update(admission=[])),
            ("empty manifests", lambda e: e.update(manifests=[])),
            ("empty models", lambda e: e["models"].update(pool_view=[])),
            ("empty probes", lambda e: e.update(window_probes=[])),
            ("missing section", lambda e: e.pop("refusals")),
            ("unknown top-level key", lambda e: e.update(notes="anything")),
            ("unknown nested key", lambda e: e["requests"]["requests/native-nonstream"].update(prompt="tell me a story")),
            ("summary with account id", lambda e: e["result"].update(summary=f"served {GGUF_ACCT}")),
            ("summary with prompt text", lambda e: e["result"].update(summary="the buyer asked about dragons")),
            ("step assertion", lambda e: e["steps"][0].update(assertion="whatever")),
            ("observation", lambda e: e["observations"].update(buyer_visible_usage_equals_debit=True)),
            ("ledger credit", lambda e: e["requests"]["requests/gguf-stream"]["ledger"][0].update(provider_credits=10**6)),
            ("raw identity", lambda e: e["identities"].update(creator_fingerprint=CREATOR)),
            ("locator", lambda e: e["requests"]["requests/gguf-stream"].update(x_request_id="http://evil")),
            ("raw document body", lambda e: e["raw_documents"]["run.json"].update(body="x")),
            ("negative attempt", lambda e: [r.update(attempt_n=-1) for key in ("request_log", "route_snapshots", "attempt_outputs",
                                                                                 "receipt_verdicts", "ledger")
                                            for r in e["requests"]["requests/gguf-stream"][key]]),
            ("r016 claimed without inflight", lambda e: e.update(attestation_removal_inflight=None)),
            ("digest count", lambda e: e.update(route_snapshot_digests_recomputed=0)),
        ):
            with self.subTest(label=label):
                self.assert_rejected("", call=lambda: self.revalidate(self.tampered(mutate)))

    def test_governance_revalidates_committed_evidence(self) -> None:
        root = self.root / "repo"
        source = "journeys/evidence/trusted-pool-model-20261006T010203Z.redacted.json"
        payload = (json.dumps(self.evidence, indent=2) + "\n").encode()
        write(root / source, payload)
        artifact = [{"id": TRUSTED_POOL_MODEL_ARTIFACT_ID, "sha256": hashlib.sha256(payload).hexdigest(), "source": source}]
        result = ValidationResult()
        _revalidate_trusted_pool_model_evidence(root, artifact, "evidence[0]", result, "SPEC-042-R016")
        self.assertEqual([], result.errors)
        bad = (json.dumps(self.tampered(lambda e: e.update(requests={})), indent=2) + "\n").encode()
        write(root / source, bad)
        artifact[0]["sha256"] = hashlib.sha256(bad).hexdigest()
        result = ValidationResult()
        _revalidate_trusted_pool_model_evidence(root, artifact, "evidence[0]", result, "SPEC-042-R016")
        self.assertTrue(any("fails the journey validator" in e for e in result.errors))
        # Evidence without the fenced in-flight request cannot promote R016.
        shutil.rmtree(self.capture / "rotation/attestation-removal/inflight")
        partial = (json.dumps(self.build(), indent=2) + "\n").encode()
        write(root / source, partial)
        artifact[0]["sha256"] = hashlib.sha256(partial).hexdigest()
        result = ValidationResult()
        _revalidate_trusted_pool_model_evidence(root, artifact, "evidence[0]", result, "SPEC-042-R016")
        self.assertTrue(any("does not cover SPEC-042-R016" in e for e in result.errors))
        result = ValidationResult()
        _revalidate_trusted_pool_model_evidence(root, artifact, "evidence[0]", result, "SPEC-042-R015")
        self.assertEqual([], result.errors)


class TrustedPoolModelPayloadTests(CaptureCase):
    def git(self, root: Path, *args: str) -> str:
        return subprocess.run(["git", *args], cwd=root, check=True, capture_output=True, text=True).stdout.strip()

    def make_repo(self) -> tuple[Path, str, str, str]:
        root = (self.root / "repo")
        root.mkdir()
        root = root.resolve()
        self.git(root, "init", "-q")
        write(root / "specs/CONFORMANCE.json", (REPO_ROOT / "specs" / "CONFORMANCE.json").read_bytes())
        self.git(root, "add", "-A")
        self.git(root, "-c", "user.email=t@t", "-c", "user.name=t", "commit", "-qm", "source")
        source_sha = self.git(root, "rev-parse", "HEAD")
        self.mutate_json("run.json", lambda r: r.update(source_commit=source_sha))
        self.mutate_json("preconditions.json", lambda p: p["deploy-build"]["observed"].update(contains_commit=source_sha[:12]))
        source = "journeys/evidence/trusted-pool-model-20261006T010203Z.redacted.json"
        evidence, bundle = BUILDER.build_evidence(self.capture, str(self.fixture.cli))
        BUILDER.write_bundle(root / source, bundle)
        BUILDER.base.write_json_atomically(root / source, evidence)
        self.git(root, "add", "-A")
        self.git(root, "-c", "user.email=t@t", "-c", "user.name=t", "commit", "-qm", "evidence")
        return root, source, source_sha, self.git(root, "rev-parse", "HEAD")

    def test_payload_end_to_end_and_bundle_tamper(self) -> None:
        root, source, source_sha, evidence_sha = self.make_repo()
        payload = BUILDER.build_payload(root, source, source_sha=source_sha, evidence_sha=evidence_sha,
                                        requirement_ids="SPEC-042-R015,SPEC-042-R016", cli=str(self.fixture.cli))
        self.assertEqual(BUILDER.SUMMARY, payload["result"]["summary"])
        self.assertEqual([], validate(dict(payload, artifacts=payload["artifacts"]), "SPEC-042-R016"))
        with self.assertRaises(SystemExit):
            BUILDER.build_payload(root, source, source_sha=source_sha, evidence_sha=evidence_sha, requirement_ids="SPEC-047-R011",
                                  cli=str(self.fixture.cli))
        bundle_file = root / BUILDER.bundle_dir_for(source) / "v7.json"
        bundle_file.write_text(bundle_file.read_text().replace('"manifest_version": 7', '"manifest_version": 7, "x": 1'))
        stderr = io.StringIO()
        with contextlib.redirect_stderr(stderr), self.assertRaises(SystemExit):
            BUILDER.build_payload(root, source, source_sha=source_sha, evidence_sha=evidence_sha, requirement_ids=None, cli=str(self.fixture.cli))
        self.assertIn("must match --evidence-sha", stderr.getvalue())

    def test_requirement_ids_are_bounded(self) -> None:
        evidence = {"requirement_ids": sorted(TRUSTED_POOL_MODEL_PROMOTABLE_REQUIREMENT_IDS)}
        self.assertEqual(["SPEC-042-R016"], BUILDER.parse_requirement_ids("SPEC-042-R016", evidence))
        with self.assertRaises(SystemExit):
            BUILDER.parse_requirement_ids("SPEC-047-R011", evidence)

    def test_payload_rejects_evidence_outside_the_journey_prefix(self) -> None:
        with self.assertRaises(SystemExit):
            BUILDER.require_evidence_source(REPO_ROOT, "journeys/evidence/trusted-pool-external-runtime-x.redacted.json")


@unittest.skipUnless(os.environ.get("MACPROVIDER_COORDINATOR_CLI"), "set MACPROVIDER_COORDINATOR_CLI to a built coordinator-cli")
class TrustedPoolModelRealCLITests(unittest.TestCase):
    """Signs a real seven-manifest chain with coordinator-cli and runs capture
    against the real verify-manifest."""

    def test_real_signed_chain(self) -> None:
        cli = os.environ["MACPROVIDER_COORDINATOR_CLI"]
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            keys = root / "keys"
            out = subprocess.run([cli, "trust-pool-admin", "keygen", "--out-dir", str(keys), "--manifest-authority-key-id", "ma-1",
                                  "--policy-signer-key-id", "ps-1"], check=True, capture_output=True, text=True).stdout
            pool = re.search(r"^pool_id=(.+)$", out, re.M).group(1)
            custody = root / "custody.json"
            custody.write_text('{"class":"software","description":"test"}\n')
            identity = ["--identity", str(keys / "pool-identity.json"), "--root-issuer-key", str(keys / "root-issuer-key.pem"),
                        "--root-issuer-key-id", "ri-1"]
            subprocess.run([cli, "trust-pool-admin", "sign-root", *identity, "--operation-id", "r1", "--creator-account-id", CREATOR,
                            "--approval-record-id", "ap-1", "--approval-version", "v1", "--launch-environment", "candidate",
                            "--custody-disclosure", str(custody), "--custody-class", "software", "--display-name", "t", "--nonce", "n1",
                            "--nonce-expiry", "2099-01-01T00:00:00Z", "--out", str(root / "root.json")], check=True, capture_output=True)
            events = {}
            for version in VERSIONS:
                entries, attested = version_content(pool, version)
                models = root / f"models-{version}.json"
                models.write_text(json.dumps({"model_entries": [
                    {**{k: e[k] for k in ("pool_model_id", "artifact_hash_algorithm", "artifact_hash", "allowed_runtime_sources", "license",
                                          "paid_serving_attested", "disclosure_class", "max_context_tokens")},
                     "pricing": {k: e[k] for k in NATIVE_RATES}} for e in entries], "attested_members": attested}))
                args = [cli, "trust-pool-admin", "sign-manifest", *identity, "--policy-signer-key", str(keys / "policy-signer-key.pem"),
                        "--operation-id", f"m{version}", "--encoding", "2", "--signer-set-version", "1", "--settlement-mode", "enforce",
                        "--runtime-allowlist", "llamacpp_loopback", "--models", "mlx-community/x", "--min-binary-version", "1.8.123",
                        "--min-attestation-tier", "hardware", "--retention-policy-id", "standard", "--min-eligible-members", "1",
                        "--not-before", iso(T0 + version * 3600), "--expires-at", iso(T0 + (version + 1) * 3600),
                        "--out", str(root / f"v{version}.json")]
                if entries or attested:
                    args += ["--pool-models", str(models)]
                if version == 1:
                    args += ["--manifest-authority-key", str(keys / "manifest-authority-key.pem")]
                else:
                    args += ["--prev", str(root / f"v{version - 1}.json")]
                subprocess.run(args, check=True, capture_output=True)
                events[version] = (root / f"v{version}.json").read_bytes()
            verify = [cli, "trust-pool-admin", "verify-manifest", "--root", str(root / "root.json"), "--manifest", str(root / "v7.json")]
            verification = json.loads(subprocess.run(verify, check=True, capture_output=True, text=True).stdout)
            self.assertEqual(list(VERSIONS), [m["manifest_version"] for m in verification["manifests"]])
            (root / "fx").mkdir()
            fixture = Fixture(root / "fx", verification, events=events, root_event=(root / "root.json").read_bytes(), cli=cli)
            capture = fixture.build()
            evidence, bundle = BUILDER.build_evidence(capture, cli)
            self.assertEqual(7, len(evidence["manifests"]))
            self.assertEqual(evidence["manifests"][0]["manifest_terms_digest"], evidence["manifests"][1]["manifest_terms_digest"])
            self.assertEqual(13, evidence["route_snapshot_digests_recomputed"])
            self.assertEqual(["root-issuer-registered.json", "v7.json"], sorted(bundle))


if __name__ == "__main__":
    unittest.main()
