from __future__ import annotations

import contextlib
import importlib.util
import io
import json
import sys
import tempfile
import unittest
from pathlib import Path

from scripts.check_spec_governance import (
    TRUSTED_POOL_MODEL_ARTIFACT_ID,
    TRUSTED_POOL_MODEL_JOURNEY_ID,
    TRUSTED_POOL_MODEL_PROMOTABLE_REQUIREMENT_IDS,
    TRUSTED_POOL_MODEL_STEP_ID_ORDER,
    ValidationResult,
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
NATIVE_ID = f"pool/{POOL}/qwen25-05b-mlx8"
GGUF_ID = f"pool/{POOL}/qwen25-05b-q8-gguf"
BOUNDS_DIGEST = "c3" * 32
# The Pearl #1816 order: genesis (native only), keeper window rotation, native
# price change, native entry removal (zero entries), GGUF added (native re-added,
# GGUF entry, R016 attestation), keeper rotation, attestation removal.
ROLES = {"native_genesis": 1, "window_rotation": 2, "price_change": 3, "entry_removal": 4, "gguf_added": 5, "attestation_removal": 7}
# version -> terms digest; 6 is a keeper (window-only) rotation of gguf_added.
TERMS = {1: "11" * 32, 2: "11" * 32, 3: "33" * 32, 4: "44" * 32, 5: "55" * 32, 6: "55" * 32, 7: "77" * 32}
NATIVE_RATES = {"prompt_rate_per_mtok": 20000, "prompt_cache_hit_rate_per_mtok": 5000, "completion_rate_per_mtok": 40000}
NATIVE_NEW_RATES = {"prompt_rate_per_mtok": 30000, "prompt_cache_hit_rate_per_mtok": 7500, "completion_rate_per_mtok": 60000}
GGUF_RATES = {"prompt_rate_per_mtok": 25000, "prompt_cache_hit_rate_per_mtok": 6000, "completion_rate_per_mtok": 50000}


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


def write(path: Path, value) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    if isinstance(value, (bytes, str)):
        path.write_bytes(value if isinstance(value, bytes) else value.encode("utf-8"))
    else:
        path.write_text(json.dumps(value), encoding="utf-8")


def core(version: int) -> str:
    return format(version, "064x")


def headers(status: int, *, request_id: str = "", engine: str = "", digest: str = "") -> str:
    reason = {200: "OK", 404: "Not Found", 503: "Service Unavailable"}[status]
    lines = [f"HTTP/2 {status} {reason}"]
    if request_id:
        lines.append(f"x-request-id: {request_id}")
    if engine:
        lines.append(f"x-macprovider-engine: {engine}")
        lines.append("x-macprovider-model-disclosure: pool_attested_unverified")
        lines.append(f"x-macprovider-pool-manifest-core-digest: {digest}")
    lines.append("content-type: application/json")
    return "\r\n".join(lines) + "\r\n\r\n"


def entry(kind: str, rates: dict) -> dict:
    native = kind == "native"
    return {
        "pool_model_id": NATIVE_ID if native else GGUF_ID,
        "artifact_hash_algorithm": "macprovider.snapshot-manifest.v1" if native else "macprovider.gguf-file.v1",
        "artifact_hash": NATIVE_HASH if native else GGUF_HASH,
        "allowed_runtime_sources": ["mlx_cache"] if native else ["llamacpp_loopback"],
        "license": "Apache-2.0",
        "paid_serving_attested": True,
        **rates,
        "disclosure_class": "pool_attested_unverified",
        "max_context_tokens": 8192,
    }


def pool_state(version: int) -> dict:
    entries, attested, members = [entry("native", NATIVE_RATES)], [], [NATIVE_PROV]
    if version >= 3:
        entries = [entry("native", NATIVE_NEW_RATES)]
    if version == 4:
        entries = []
    if version >= 5:
        members = [GGUF_PROV, NATIVE_PROV]
        attested = [{"provider_account_id": GGUF_ACCT, "runtime_classes": ["llamacpp_loopback"]}]
        entries = [entry("native", NATIVE_NEW_RATES), entry("gguf", GGUF_RATES)]
    if version >= 7:
        attested = []
    return {"pool": {
        "pool_id": POOL, "creator_account_id": CREATOR, "lifecycle": "active", "routeable": True,
        "launch_environment": "candidate", "settlement_mode": "enforce", "runtime_allowlist": ["llamacpp_loopback"],
        "manifest_version": version, "manifest_core_digest": core(version), "model_entries": entries,
        "attested_members": attested, "members": members, "revoked": [], "buyer_accounts": [BUYER],
    }}


def write_paid(capture: Path, name: str, kind: str, version: int, rates: dict, *, stream: bool = False, rid: str = "") -> None:
    base = capture / name
    rid = rid or "req-" + name.replace("/", "-")
    coord = "coord-" + rid
    native = kind == "native"
    tokens = (40, 12)
    write(base / "response.headers", headers(200, request_id=rid, engine="mlx_cache" if native else "llamacpp_loopback", digest=core(version)))
    if stream:
        chunks = [
            {"choices": [{"delta": {"content": "1 2 3"}, "finish_reason": None}]},
            {"choices": [{"delta": {"content": " 4 5"}, "finish_reason": "stop"}]},
            {"choices": [], "usage": {"prompt_tokens": tokens[0], "completion_tokens": tokens[1]}},
        ]
        write(base / "response.sse", "".join(f"data: {json.dumps(c)}\n\n" for c in chunks) + "data: [DONE]\n\n")
    else:
        write(base / "response.json", {
            "choices": [{"message": {"role": "assistant", "content": "secret completion text"}, "finish_reason": "stop"}],
            "usage": {"prompt_tokens": 52, "completion_tokens": tokens[1]},
        })
    write(base / "request_log.json", [{"request_id": coord, "attempt_n": 1, "status": "ok", "pool_id": POOL}])
    write(base / "route_snapshots.json", [{
        "request_id": coord, "attempt_n": 1, "provider_id": NATIVE_PROV if native else GGUF_PROV,
        "route_snapshot_mode": "enforce", "route_snapshot_policy_version": "spec022-route-snapshot-v2",
        "pool_id": POOL, "model_id": NATIVE_ID if native else GGUF_ID, "expected_model_hash_source": "pool_manifest",
        "pool_model_id": NATIVE_ID if native else GGUF_ID, "manifest_version": version, "manifest_core_digest": core(version),
        "runtime_source": None if native else "llamacpp_loopback",
        "pool_operator_account_id": None if native else CREATOR,
        "pool_member_account_id": None if native else GGUF_ACCT,
        "expected_catalog_model_hash": NATIVE_HASH if native else GGUF_HASH,
        "expected_catalog_model_hash_algorithm": "macprovider.snapshot-manifest.v1" if native else "macprovider.gguf-file.v1",
        **{f"pool_model_{k}": v for k, v in rates.items()},
        "pool_model_pricing_bounds_sha256": BOUNDS_DIGEST,
    }])
    usage = "coordinator_observed" if native else "pool_operator_attested"
    write(base / "attempt_outputs.json", [{"request_id": coord, "attempt_n": 1, "terminal_state": "normal_done", "usage_source": usage}])
    write(base / "receipt_verdicts.json", [{
        "request_id": coord, "attempt_n": 1, "receipt_result": "valid", "settlement_outcome": "verified",
        "reason": "verified_settlement", "closed": 1, "pool_label_status": "verified",
    }])
    write(base / "ledger.json", [{
        "id": 7, "request_id": coord, "attempt_n": 1, "provider_id": NATIVE_PROV if native else GGUF_PROV, "status": "credited",
        "charged_prompt_tokens": tokens[0], "completion_tokens": tokens[1],
        "prompt_rate_per_mtok": rates["prompt_rate_per_mtok"], "completion_rate_per_mtok": rates["completion_rate_per_mtok"],
        "provider_credits": 900, "quarantined": 0, "payable": 1,
    }])
    write(base / "quota_reservations.json", [{"request_id": rid, "status": "settled", "settled_tokens": sum(tokens), "settlement_hold": 0}])
    write(base / "usage_events.json", [{"request_id": rid, "prompt_tokens": tokens[0], "completion_tokens": tokens[1], "token_source": usage}])


def write_refusal(capture: Path, name: str, status: int, code: str) -> None:
    base = capture / name
    write(base / "response.headers", headers(status, request_id="req-" + name.replace("/", "-")))
    write(base / "response.json", {"error": {"code": code, "message": "x"}})
    write(base / "route_snapshots.json", "")
    write(base / "ledger.json", "")
    write(base / "quota_reservations.json", [{"request_id": "r", "status": "refunded", "settlement_hold": 0}])


def make_capture(root: Path) -> Path:
    capture = root / "capture"
    write(capture / "run.json", {
        "run_id": "trusted-pool-model-20261006T010203Z",
        "captured_at": "2026-10-06T01:02:03Z",
        "expires_at": "2099-01-01",
        "source_commit": "a" * 40,
        "coordinator_version": "v1.8.217",
        "accepted_id": "Augustas11/macprovider:v1.8.217@" + "b" * 40,
        "native_member_cli_sha256": "c" * 64,
        "gguf_member_cli_sha256": "d" * 64,
        "llama_server_build": "b11149",
        "operator_role": "pearl-actor",
        "operator_identity": "operator-person-name",
        "hardware_profile": "mac-studio-m3-ultra-256gb",
        "pool_id": POOL,
        "other_pool_id": OTHER_POOL,
        "creator_account_id": CREATOR,
        "buyer_account_id": BUYER,
        "native_member_provider_id": NATIVE_PROV,
        "native_member_account_id": NATIVE_ACCT,
        "gguf_member_provider_id": GGUF_PROV,
        "gguf_member_account_id": GGUF_ACCT,
        "native_entry": {"slug": "qwen25-05b-mlx8", "artifact_hash": NATIVE_HASH},
        "gguf_entry": {"slug": "qwen25-05b-q8-gguf", "artifact_hash": GGUF_HASH},
        "manifest_versions": ROLES,
    })
    write(capture / "preconditions.json", {
        key: {"status": "pass", "observed": {"passed": True, "build": "v1.8.217"}, "checked_at": "2026-10-06T00:00:00Z"}
        for key in BUILDER.PRECONDITION_IDS
    })
    write(capture / "deploy.json", {
        "coordinator_deployed_at": "2026-10-05T10:00:00Z", "gateway_deployed_at": "2026-10-05T10:05:00Z",
        "native_member_cli_installed_at": "2026-10-05T11:00:00Z", "gguf_member_cli_installed_at": "2026-10-05T11:10:00Z",
    })
    write(capture / "config/pricing-bounds.json", {
        "min_prompt_rate_per_mtok": 13500, "max_prompt_rate_per_mtok": 425000,
        "min_prompt_cache_hit_rate_per_mtok": 3375, "max_prompt_cache_hit_rate_per_mtok": 106250,
        "min_completion_rate_per_mtok": 27000, "max_completion_rate_per_mtok": 2160000,
    })
    write(capture / "config/owner-authority-reload.json", {
        "reloaded": True, "provider_owner_account_ids_applied": True,
        "provider_owner_account_ids_providers": 1, "provider_owner_account_ids_sha256": "e" * 64,
    })
    for version in TERMS:
        write(capture / f"pool/v{version}/manifest-accepted.json", {
            "event_type": "manifest_accepted", "pool_id": POOL, "manifest_version": version, "manifest_core_digest": core(version),
        })
        write(capture / f"pool/v{version}/policy-terms-digest.txt",
              f"pool_id={POOL}\nmanifest_version={version}\nmanifest_core_digest={core(version)}\nmanifest_terms_digest={TERMS[version]}\n")
    for version in ROLES.values():
        write(capture / f"pool/v{version}/get-pool.json", pool_state(version))
    write(capture / "pool/trustpool-events.json", [
        {"event_type": "pool_created", "n": 1}, {"event_type": "root_issuer_registered", "n": 1},
        {"event_type": "manifest_accepted", "n": 7}, {"event_type": "member_admitted", "n": 3},
        {"event_type": "buyer_authorized", "n": 1}, {"event_type": "delegation_granted", "n": 3},
        {"event_type": "lifecycle_changed", "n": 2},
    ])
    for kind, pmid, digest_hash, runtime in (("native", NATIVE_ID, NATIVE_HASH, "mlx_cache"), ("gguf", GGUF_ID, GGUF_HASH, "llamacpp_loopback")):
        write(capture / f"proposals/{kind}.json", {
            "schema": "pool_model_proposal.v1", "pool_id": POOL, "runtime_source": runtime, "catalog_model_key": None,
            "model_entry": {
                "pool_model_id": pmid, "artifact_hash": digest_hash,
                "artifact_hash_algorithm": "macprovider.snapshot-manifest.v1" if kind == "native" else "macprovider.gguf-file.v1",
                "license": None, "paid_serving_attested": None,
            },
        })
    actor = f"pool_manifest:{POOL}:1:{core(1)}"

    def event(i, prov, state, reason, pmid=None, version=None, h=None, algo=None):
        return {"id": i, "provider_id": prov, "state": state, "actor": actor, "reason_code": reason,
                "binding_scope": "pool" if pmid else None, "pool_id": POOL if pmid else None, "pool_model_id": pmid,
                "pool_manifest_version": version, "pool_manifest_core_digest": core(version) if version else None,
                "expected_catalog_model_hash_algorithm": algo, "expected_catalog_model_hash": h}

    snap, gguf_algo = "macprovider.snapshot-manifest.v1", "macprovider.gguf-file.v1"
    write(capture / "admission/model-admission-events.json", [
        event(1, NATIVE_PROV, "offer_submitted", "offer_submitted"),
        event(2, NATIVE_PROV, "catalog_priced", "pool_manifest_bound", NATIVE_ID, 1, NATIVE_HASH, snap),
        event(3, NATIVE_PROV, "catalog_priced", "pool_manifest_rebound", NATIVE_ID, 2, NATIVE_HASH, snap),
        # the price change revokes the delegated member; it re-delegates and re-offers
        event(4, NATIVE_PROV, "revoked", "pool_membership_revoked", NATIVE_ID, 2, NATIVE_HASH, snap),
        event(5, NATIVE_PROV, "offer_submitted", "offer_submitted"),
        event(6, NATIVE_PROV, "catalog_priced", "pool_manifest_bound", NATIVE_ID, 3, NATIVE_HASH, snap),
        event(7, NATIVE_PROV, "revoked", "pool_manifest_entry_revoked", NATIVE_ID, 3, NATIVE_HASH, snap),
        event(8, GGUF_PROV, "offer_submitted", "offer_submitted"),
        event(9, GGUF_PROV, "catalog_priced", "pool_manifest_bound", GGUF_ID, 5, GGUF_HASH, gguf_algo),
        event(10, NATIVE_PROV, "offer_submitted", "offer_submitted"),
        event(11, NATIVE_PROV, "catalog_priced", "pool_manifest_bound", NATIVE_ID, 5, NATIVE_HASH, snap),
        event(12, GGUF_PROV, "revoked", "pool_membership_revoked", GGUF_ID, 7, GGUF_HASH, gguf_algo),
    ])

    def listed(kind, rates):
        native = kind == "native"
        return {"id": NATIVE_ID if native else GGUF_ID, "object": "model", "owned_by": "macprovider", "macprovider_pool_model": {
            "pool_id": POOL, "pool_model_id": NATIVE_ID if native else GGUF_ID,
            "artifact_hash_algorithm": "macprovider.snapshot-manifest.v1" if native else "macprovider.gguf-file.v1",
            "artifact_hash": NATIVE_HASH if native else GGUF_HASH, "manifest_core_digest": core(5), "manifest_version": 5,
            "runtime_sources": ["mlx_cache" if native else "llamacpp_loopback"], "disclosure_class": "pool_attested_unverified",
            "disclosure_text": "Pool-attested, not network-verified", "price_source": "pool_creator_signed",
            "max_context_tokens": 8192, "price": {**rates, "global_multiplier_ppm": 1000000},
        }}

    write(capture / "models/pool.json", {"object": "list", "data": [listed("native", NATIVE_NEW_RATES), listed("gguf", GGUF_RATES)]})
    write(capture / "models/global.json", {"object": "list", "data": [{"id": "qwen3.6-27b", "object": "model"}]})
    write(capture / "never-global.json", [{"n": 0}])
    write_paid(capture, "requests/native-nonstream", "native", 1, NATIVE_RATES)
    write_paid(capture, "requests/native-stream", "native", 6, NATIVE_NEW_RATES, stream=True)
    write_paid(capture, "requests/gguf-nonstream", "gguf", 5, GGUF_RATES)
    write_paid(capture, "requests/gguf-stream", "gguf", 6, GGUF_RATES, stream=True)
    write_paid(capture, "rotation/window-only/after", "native", 2, NATIVE_RATES)
    write_paid(capture, "rotation/price-change/inflight", "native", 2, NATIVE_RATES)
    write_paid(capture, "rotation/price-change/after", "native", 3, NATIVE_NEW_RATES)
    write_paid(capture, "rotation/entry-removal/inflight", "native", 3, NATIVE_NEW_RATES)
    write_paid(capture, "pause/resumed", "gguf", 5, GGUF_RATES)
    write_paid(capture, "restart/after", "native", 6, NATIVE_NEW_RATES)
    write_refusal(capture, "refusals/no-pool-header", 404, "model_not_found")
    write_refusal(capture, "refusals/other-pool", 404, "model_not_found")
    write_refusal(capture, "refusals/wrong-engine", 503, "engine_unavailable")
    write_refusal(capture, "pause/paused", 503, "pool_unavailable")
    write_refusal(capture, "rotation/entry-removal/after", 404, "model_not_found")
    write_refusal(capture, "rotation/attestation-removal/after", 503, "no_providers_available")
    write(capture / "rotation/window-only/probes.json", [
        {"at": "2026-10-06T00:10:00Z", "status": 200}, {"at": "2026-10-06T00:10:30Z", "status": 200},
        {"at": "2026-10-06T00:11:00Z", "status": 200},
    ])
    write(capture / "rollback/preflight-m9.rc", "3\n")
    write(capture / "rollback/preflight-m9.json", {
        "pool_route_snapshots": 12, "open_pool_verdicts": 0, "in_window_pool_attempts_without_verdict": 0, "rollback_blocked": True,
        "manifest_history": {"target_tier": "m9", "manifests": 7, "v2_snapshots": 7, "runtime_classes": ["llamacpp_loopback"],
                             "extensions": ["pool_model_entries/v1"], "cannot_replay": ["pool_model_entries/v1"]},
    })
    write(capture / "rollback/preflight-p1816.rc", "0\n")
    write(capture / "rollback/preflight-p1816.json", {
        "pool_route_snapshots": 12, "open_pool_verdicts": 0, "in_window_pool_attempts_without_verdict": 0, "rollback_blocked": False,
        "manifest_history": {"target_tier": "p1816", "manifests": 7, "v2_snapshots": 7, "runtime_classes": ["llamacpp_loopback"],
                             "extensions": ["pool_model_entries/v1"], "cannot_replay": []},
    })
    write(capture / "restart/order.json", {"coordinator_restarted_at": "2026-10-06T02:00:00Z", "gateway_restarted_at": "2026-10-06T02:01:00Z"})
    return capture


def valid_signed(**overrides):
    signed = {
        "journey_id": TRUSTED_POOL_MODEL_JOURNEY_ID,
        "execution_mode": "production-operator-internal-pool",
        "environment": {"class": "production-operator-internal-pool", "hardware_profile": "studio", "candidate": "x"},
        "requirement_ids": ["SPEC-042-R015"],
        "observations": {**BUILDER.TRUSTED_POOL_MODEL_FIXED_OBSERVATIONS, "buyer_visible_usage_equals_debit": False},
        "candidate_identity": {
            "coordinator_version": "v1.8.217",
            "accepted_id": "Augustas11/macprovider:v1.8.217@" + "b" * 40,
            "native_member_cli_sha256": "c" * 64,
            "gguf_member_cli_sha256": "d" * 64,
            "llama_server_build": "b11149",
            "pool_id": POOL,
            "native_pool_model_id": NATIVE_ID,
            "native_artifact_hash": NATIVE_HASH,
            "gguf_pool_model_id": GGUF_ID,
            "gguf_artifact_hash": GGUF_HASH,
            "manifest_version": 7,
            "manifest_core_digest": core(7),
            "pricing_bounds_sha256": BOUNDS_DIGEST,
            "fingerprint_salt": "f" * 64,
        },
        "artifacts": [{"id": TRUSTED_POOL_MODEL_ARTIFACT_ID, "sha256": "e" * 64, "source": "journeys/evidence/x"}],
        "steps": [
            {"id": step_id, "status": "pass", "artifacts": [TRUSTED_POOL_MODEL_ARTIFACT_ID]}
            for step_id in TRUSTED_POOL_MODEL_STEP_ID_ORDER
        ],
    }
    signed.update(overrides)
    return signed


def validate(signed, requirement_id="SPEC-042-R015", journeys=None):
    result = ValidationResult()
    _validate_trusted_pool_model_journey_result(
        signed,
        requirement_id,
        journeys if journeys is not None else [TRUSTED_POOL_MODEL_JOURNEY_ID],
        signed["artifacts"],
        signed["steps"],
        "evidence[0]",
        result,
    )
    return result.errors


class TrustedPoolModelValidatorTests(unittest.TestCase):
    def test_valid_payload_promotes_each_mapped_requirement(self) -> None:
        for requirement_id in sorted(TRUSTED_POOL_MODEL_PROMOTABLE_REQUIREMENT_IDS):
            signed = valid_signed(requirement_ids=[requirement_id])
            self.assertEqual([], validate(signed, requirement_id), requirement_id)

    def test_spec047_r011_is_not_promotable(self) -> None:
        # R011 promotion also needs the model_admission_probe_evidence.v1 record.
        self.assertNotIn("SPEC-047-R011", TRUSTED_POOL_MODEL_PROMOTABLE_REQUIREMENT_IDS)
        signed = valid_signed(requirement_ids=["SPEC-047-R011"])
        self.assertTrue(any("cannot promote SPEC-047-R011" in error for error in validate(signed, "SPEC-047-R011")))

    def test_rejects_wrong_fixed_observation(self) -> None:
        for field, bad in (("settlement_mode", "observe"), ("payout_ready_mutated", True), ("global_route_absent", False)):
            signed = valid_signed()
            signed["observations"][field] = bad
            self.assertTrue(any(field in error for error in validate(signed)), field)

    def test_rejects_foreign_pool_model_id_and_missing_identity(self) -> None:
        signed = valid_signed()
        signed["candidate_identity"]["gguf_pool_model_id"] = "pool/other/slug"
        self.assertTrue(any("gguf_pool_model_id" in error for error in validate(signed)))
        signed = valid_signed()
        del signed["candidate_identity"]["pricing_bounds_sha256"]
        self.assertTrue(any("candidate_identity" in error for error in validate(signed)))

    def test_rejects_missing_or_reordered_steps(self) -> None:
        signed = valid_signed()
        signed["steps"] = signed["steps"][:-1]
        self.assertTrue(any("missing" in error for error in validate(signed)))
        signed = valid_signed()
        signed["steps"] = list(reversed(signed["steps"]))
        self.assertTrue(any("ordered" in error for error in validate(signed)))

    def test_rejects_unmapped_journey_and_wrong_mode(self) -> None:
        self.assertTrue(validate(valid_signed(), journeys=["JOURNEY-TRUSTED-POOL-EXTERNAL-RUNTIME"]))
        self.assertTrue(validate(valid_signed(execution_mode="isolated-candidate-paid-path")))

    def test_journey_definition_lists_the_step_ids(self) -> None:
        text = (REPO_ROOT / "journeys" / f"{TRUSTED_POOL_MODEL_JOURNEY_ID}.md").read_text(encoding="utf-8")
        for step_id in TRUSTED_POOL_MODEL_STEP_ID_ORDER:
            self.assertIn(f"`{step_id}`", text)

    def test_conformance_maps_journey_without_promoting(self) -> None:
        conformance = json.loads((REPO_ROOT / "specs" / "CONFORMANCE.json").read_text(encoding="utf-8"))
        rows = {row["requirement_id"]: row for row in conformance["requirements"]}
        for requirement_id in TRUSTED_POOL_MODEL_PROMOTABLE_REQUIREMENT_IDS:
            self.assertIn(TRUSTED_POOL_MODEL_JOURNEY_ID, rows[requirement_id]["journeys"])
            self.assertEqual("pending", rows[requirement_id]["state"])
        self.assertNotIn(TRUSTED_POOL_MODEL_JOURNEY_ID, rows["SPEC-047-R011"]["journeys"])


class TrustedPoolModelCaptureTests(unittest.TestCase):
    def setUp(self) -> None:
        self._tmp = tempfile.TemporaryDirectory()
        self.root = Path(self._tmp.name)
        self.capture = make_capture(self.root)

    def tearDown(self) -> None:
        self._tmp.cleanup()

    def build(self):
        return BUILDER.build_evidence(self.capture)

    def assert_rejected(self, fragment: str) -> None:
        stderr = io.StringIO()
        with contextlib.redirect_stderr(stderr), self.assertRaises(SystemExit):
            self.build()
        self.assertIn(fragment, stderr.getvalue())
        self.assertIn("build-trusted-pool-model-journey-result:", stderr.getvalue())

    def mutate_rows(self, relative: str, **changes) -> None:
        path = self.capture / relative
        rows = json.loads(path.read_text())
        for row in rows:
            row.update(changes)
        path.write_text(json.dumps(rows))

    def mutate_pool(self, version: int, mutate) -> None:
        path = self.capture / f"pool/v{version}/get-pool.json"
        value = json.loads(path.read_text())
        mutate(value["pool"])
        path.write_text(json.dumps(value))

    def test_valid_capture_builds_redacted_evidence(self) -> None:
        evidence = self.build()
        self.assertEqual(BUILDER.EVIDENCE_SCHEMA, evidence["schema_version"])
        self.assertEqual(list(TRUSTED_POOL_MODEL_STEP_ID_ORDER), [s["id"] for s in evidence["steps"]])
        self.assertEqual(sorted(TRUSTED_POOL_MODEL_PROMOTABLE_REQUIREMENT_IDS), evidence["requirement_ids"])
        self.assertFalse(evidence["observations"]["buyer_visible_usage_equals_debit"])
        self.assertEqual("coordinator_observed", evidence["requests"]["requests/native-nonstream"]["usage_source"])
        self.assertEqual("pool_operator_attested", evidence["requests"]["requests/gguf-stream"]["usage_source"])
        self.assertEqual("price_change", evidence["requests"]["rotation/price-change/after"]["manifest_role"])
        self.assertEqual(NATIVE_RATES, evidence["requests"]["rotation/price-change/inflight"]["rates"])
        self.assertEqual(NATIVE_NEW_RATES, evidence["requests"]["rotation/entry-removal/inflight"]["rates"])
        self.assertEqual([6], evidence["pool"]["keeper_versions"])
        self.assertEqual(3, evidence["admission"]["price_change_reoffer_bound_version"])
        self.assertTrue(evidence["admission"]["native"]["unmatched_offer_before_bind"])
        self.assertIn("run.json", evidence["raw_documents"])
        text = json.dumps(evidence)
        for raw in (CREATOR, BUYER, NATIVE_PROV, NATIVE_ACCT, GGUF_PROV, GGUF_ACCT, OTHER_POOL, "operator-person-name",
                    "secret completion text", "1 2 3"):
            self.assertNotIn(raw, text)
        BUILDER.require_observations(evidence["observations"])
        BUILDER.require_candidate_identity(evidence["candidate_identity"])
        BUILDER.require_steps(evidence["steps"])
        signed = valid_signed(
            observations=evidence["observations"],
            candidate_identity=evidence["candidate_identity"],
            environment=evidence["environment"],
            steps=evidence["steps"],
        )
        self.assertEqual([], validate(signed))

    def test_rejects_wrong_entry_rate_in_snapshot(self) -> None:
        self.mutate_rows("requests/gguf-nonstream/route_snapshots.json", pool_model_completion_rate_per_mtok=1)
        self.assert_rejected("signed entry rate")

    def test_rejects_ledger_rate_not_from_snapshot(self) -> None:
        self.mutate_rows("rotation/price-change/inflight/ledger.json", completion_rate_per_mtok=NATIVE_NEW_RATES["completion_rate_per_mtok"])
        self.assert_rejected("ledger completion_rate_per_mtok")

    def test_rejects_global_identity_source(self) -> None:
        self.mutate_rows("requests/native-stream/route_snapshots.json", expected_model_hash_source="catalog")
        self.assert_rejected("expected_model_hash_source")

    def test_rejects_native_route_with_runtime_source(self) -> None:
        self.mutate_rows("requests/native-nonstream/route_snapshots.json", runtime_source="mlxlm_loopback")
        self.assert_rejected("native route carries no runtime_source")

    def test_rejects_wrong_member_account(self) -> None:
        self.mutate_rows("requests/gguf-stream/route_snapshots.json", pool_member_account_id=CREATOR)
        self.assert_rejected("pool_member_account_id")

    def test_rejects_unverified_or_unpaid(self) -> None:
        self.mutate_rows("requests/native-nonstream/receipt_verdicts.json", settlement_outcome="quarantined")
        self.assert_rejected("receipt verdict")

    def test_rejects_wrong_usage_source(self) -> None:
        self.mutate_rows("requests/gguf-nonstream/usage_events.json", token_source="coordinator_observed")
        self.assert_rejected("token_source")

    def test_rejects_wrong_disclosure_header(self) -> None:
        path = self.capture / "requests/native-nonstream/response.headers"
        path.write_text(path.read_text().replace("pool_attested_unverified", "network_verified"))
        self.assert_rejected("X-MacProvider-Model-Disclosure")

    def test_rejects_keeper_version_with_changed_terms(self) -> None:
        path = self.capture / "pool/v6/policy-terms-digest.txt"
        path.write_text(path.read_text().replace(TERMS[6], "99" * 32))
        self.assert_rejected("terms must equal")

    def test_rejects_uncaptured_snapshot_version(self) -> None:
        self.mutate_rows("requests/gguf-nonstream/route_snapshots.json", manifest_version=9, manifest_core_digest=core(9))
        self.assert_rejected("pool/v9")

    def test_rejects_window_rotation_that_changes_terms(self) -> None:
        path = self.capture / "pool/v2/policy-terms-digest.txt"
        path.write_text(path.read_text().replace(TERMS[2], "98" * 32))
        self.assert_rejected("window_rotation must keep the policy terms digest")

    def test_rejects_price_change_that_changes_more(self) -> None:
        def mutate(pool):
            pool["model_entries"][0]["max_context_tokens"] = 4096
        self.mutate_pool(3, mutate)
        self.assert_rejected("price_change")

    def test_rejects_rate_outside_bounds(self) -> None:
        path = self.capture / "config/pricing-bounds.json"
        value = json.loads(path.read_text())
        value["max_completion_rate_per_mtok"] = 50000
        path.write_text(json.dumps(value))
        self.assert_rejected("inside the configured bounds")

    def test_rejects_creator_owned_native_member(self) -> None:
        path = self.capture / "run.json"
        value = json.loads(path.read_text())
        value["native_member_account_id"] = CREATOR
        path.write_text(json.dumps(value))
        self.assert_rejected("non-creator")

    def test_rejects_refusal_that_dispatched(self) -> None:
        write(self.capture / "refusals/other-pool/route_snapshots.json", [{"request_id": "x"}])
        self.assert_rejected("route snapshot")

    def test_rejects_refusal_wrong_code(self) -> None:
        write(self.capture / "refusals/no-pool-header/response.json", {"error": {"code": "engine_unavailable"}})
        self.assert_rejected("error.code")

    def test_rejects_unrefunded_reservation(self) -> None:
        self.mutate_rows("pause/paused/quota_reservations.json", status="settled")
        self.assert_rejected("refunded")

    def test_rejects_global_listing(self) -> None:
        write(self.capture / "models/global.json", {"data": [{"id": NATIVE_ID}]})
        self.assert_rejected("global /v1/models")

    def test_rejects_never_global_count(self) -> None:
        write(self.capture / "never-global.json", [{"n": 1}])
        self.assert_rejected("never-global")

    def test_rejects_missing_revocation(self) -> None:
        path = self.capture / "admission/model-admission-events.json"
        rows = [row for row in json.loads(path.read_text()) if row["reason_code"] != "pool_membership_revoked"]
        path.write_text(json.dumps(rows))
        self.assert_rejected("pool_membership_revoked")

    def test_rejects_settlement_capable(self) -> None:
        path = self.capture / "admission/model-admission-events.json"
        rows = json.loads(path.read_text())
        rows.append({"id": 99, "provider_id": GGUF_PROV, "state": "settlement_capable"})
        path.write_text(json.dumps(rows))
        self.assert_rejected("settlement_capable")

    def test_rejects_price_inflight_after_change(self) -> None:
        self.mutate_rows("rotation/price-change/inflight/route_snapshots.json", manifest_version=3, manifest_core_digest=core(3),
                         **{f"pool_model_{k}": v for k, v in NATIVE_NEW_RATES.items()})
        self.mutate_rows("rotation/price-change/inflight/ledger.json", prompt_rate_per_mtok=NATIVE_NEW_RATES["prompt_rate_per_mtok"],
                         completion_rate_per_mtok=NATIVE_NEW_RATES["completion_rate_per_mtok"])
        path = self.capture / "rotation/price-change/inflight/response.headers"
        path.write_text(path.read_text().replace(core(2), core(3)))
        self.assert_rejected("before the price change")

    def test_rejects_price_change_without_reoffer(self) -> None:
        # Re-delegation alone does not rebind after a term change: the member
        # must resubmit its offer (test/e2e-1816/vm/s5-rotation.sh reoffer_5).
        path = self.capture / "admission/model-admission-events.json"
        rows = [row for row in json.loads(path.read_text()) if row["id"] != 5]
        path.write_text(json.dumps(rows))
        self.assert_rejected("re-offer")

    def test_rejects_entry_removal_before_price_change(self) -> None:
        path = self.capture / "run.json"
        value = json.loads(path.read_text())
        value["manifest_versions"] = {**ROLES, "price_change": 4, "entry_removal": 3}
        path.write_text(json.dumps(value))
        self.assert_rejected("window_rotation < price_change < entry_removal")

    def test_accepts_gguf_added_before_window_rotation(self) -> None:
        # Only native_genesis-first, window < price < removal, and
        # attestation_removal > gguf_added are fixed.
        evidence = BUILDER.load_run(BUILDER.Capture(self.capture))
        self.assertEqual(ROLES, evidence["roles"])
        path = self.capture / "run.json"
        value = json.loads(path.read_text())
        value["manifest_versions"] = {"native_genesis": 1, "gguf_added": 2, "window_rotation": 3, "price_change": 4,
                                      "entry_removal": 5, "attestation_removal": 6}
        path.write_text(json.dumps(value))
        self.assertEqual(2, BUILDER.load_run(BUILDER.Capture(self.capture))["roles"]["gguf_added"])
        value["manifest_versions"]["attestation_removal"] = 1
        path.write_text(json.dumps(value))
        stderr = io.StringIO()
        with contextlib.redirect_stderr(stderr), self.assertRaises(SystemExit):
            BUILDER.load_run(BUILDER.Capture(self.capture))

    def test_rejects_gap_in_window_rotation(self) -> None:
        write(self.capture / "rotation/window-only/probes.json", [
            {"at": "2026-10-06T00:10:00Z", "status": 200}, {"at": "2026-10-06T00:10:30Z", "status": 503},
        ])
        self.assert_rejected("must not gap")

    def test_rejects_rollback_preflight_not_blocking(self) -> None:
        write(self.capture / "rollback/preflight-m9.rc", "0\n")
        self.assert_rejected("preflight-m9 must exit 3")

    def test_rejects_restart_out_of_order(self) -> None:
        write(self.capture / "restart/order.json", {"coordinator_restarted_at": "2026-10-06T03:00:00Z", "gateway_restarted_at": "2026-10-06T02:01:00Z"})
        self.assert_rejected("restart order")

    def test_rejects_deploy_out_of_order(self) -> None:
        path = self.capture / "deploy.json"
        value = json.loads(path.read_text())
        value["gateway_deployed_at"] = "2026-10-05T09:00:00Z"
        path.write_text(json.dumps(value))
        self.assert_rejected("deploy order")

    def test_rejects_proposal_mismatch(self) -> None:
        path = self.capture / "proposals/gguf.json"
        value = json.loads(path.read_text())
        value["model_entry"]["artifact_hash"] = "0" * 64
        path.write_text(json.dumps(value))
        self.assert_rejected("artifact identity")

    def test_rejects_symlinked_capture_subdirectory(self) -> None:
        requests = self.capture / "requests"
        elsewhere = self.root / "elsewhere-requests"
        requests.rename(elsewhere)
        requests.symlink_to(elsewhere, target_is_directory=True)
        self.assert_rejected("absent or unsafe")

    def test_redaction_rejects_locators_and_raw_identities(self) -> None:
        evidence = self.build()
        BUILDER.revalidate_committed_evidence(evidence)
        for label, mutate in (
            ("url", lambda e: e["result"].__setitem__("summary", "see https://coordinator.example/x")),
            ("host", lambda e: e["result"].__setitem__("summary", "served by coordinator.malibu.tech")),
            ("ip", lambda e: e["result"].__setitem__("summary", "relay 10.0.0.12 answered")),
            ("path", lambda e: e["result"].__setitem__("summary", "db at /var/lib/macprovider/coordinator.db")),
            ("raw identity field", lambda e: e["pool"].__setitem__("buyer_account_id", BUYER)),
            ("raw id as a fingerprint", lambda e: e["pool"].__setitem__("creator_account_fingerprint", CREATOR)),
            ("free text observed", lambda e: e["preconditions"]["deploy-build"].__setitem__("observed", "OPERATOR_KEY=" + "a" * 64)),
            ("raw document body", lambda e: e["raw_documents"].__setitem__("run.json", {"sha256": "a" * 64, "bytes": 1, "body": "x"})),
        ):
            with self.subTest(label=label):
                bad = json.loads(json.dumps(evidence))
                mutate(bad)
                stderr = io.StringIO()
                with contextlib.redirect_stderr(stderr), self.assertRaises(SystemExit):
                    BUILDER.revalidate_committed_evidence(bad)

    def test_fingerprints_are_salted_per_run(self) -> None:
        first, second = self.build(), self.build()
        self.assertNotEqual(first["candidate_identity"]["fingerprint_salt"], second["candidate_identity"]["fingerprint_salt"])
        self.assertNotEqual(first["pool"]["native_member_fingerprint"], second["pool"]["native_member_fingerprint"])

    def test_builder_requirement_ids_are_bounded(self) -> None:
        evidence = {"requirement_ids": sorted(TRUSTED_POOL_MODEL_PROMOTABLE_REQUIREMENT_IDS)}
        self.assertEqual(["SPEC-042-R016"], BUILDER.parse_requirement_ids("SPEC-042-R016", evidence))
        with self.assertRaises(SystemExit):
            BUILDER.parse_requirement_ids("SPEC-047-R011", evidence)
        with self.assertRaises(SystemExit):
            BUILDER.parse_requirement_ids("SPEC-042-R016", {"requirement_ids": ["SPEC-042-R015"]})

    def test_payload_rejects_evidence_outside_the_journey_prefix(self) -> None:
        with self.assertRaises(SystemExit):
            BUILDER.require_evidence_source(REPO_ROOT, "journeys/evidence/trusted-pool-external-runtime-x.redacted.json")


if __name__ == "__main__":
    unittest.main()
