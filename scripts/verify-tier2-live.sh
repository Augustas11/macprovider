#!/usr/bin/env bash
# Read-only SPEC-008 live verifier.
#
# Full observe-mode verifies:
# - gateway /v1/status and coordinator /healthz are healthy
# - gateway /v1/models exposes tier2.model_hash.state with require_verified=false
# - operator /poolz has at least one v1.2.5+ provider with hash_status=hash_verified
#
# Enforced mode verifies the C2 post-apply state:
# - the same health and /poolz provider checks as full mode
# - gateway /v1/models exposes require_verified=true and model_hash.state=all
#
# B6-ready mode verifies the v1.2.6+ encrypted provider rollout is ready for
# C4a activation without requiring the C4a config flip to have happened.
#
# Encrypted-leg mode verifies the C4a post-apply state.
#
# Attested mode verifies the C4b readiness/post-apply provider-attestation state.
#
# Catalog-only mode verifies catalog disclosure without requiring a verified
# upgraded provider. Use catalog-only immediately after C1 observe activation;
# use full after provider v1.2.5 rollout, enforced after C2, b6-ready after
# provider v1.2.6 encrypted-leg rollout, encrypted-leg after C4a, and attested
# before and after C4b.

set -euo pipefail

usage() {
  cat <<'USAGE'
usage: scripts/verify-tier2-live.sh [--full|--catalog-only|--enforce-ready|--enforced|--b6-ready|--encrypted-leg|--attested]

Environment:
  GATEWAY_ORIGIN        default: https://api.streamvc.live
  COORDINATOR_ORIGIN   default: https://coordinator.streamvc.live
  DEMO_TOKEN           required unless VERIFY_TIER2_FIXTURES is set
  OPERATOR_KEY         required for --full/--enforce-ready/--enforced/--b6-ready/
                       --encrypted-leg/--attested unless VERIFY_TIER2_FIXTURES is set
  VERIFY_TIER2_FIXTURES optional directory with status.json, healthz.json,
                       models.json, and poolz.json for local parser testing
USAGE
}

mode="full"
case "${1:---full}" in
  --full) mode="full" ;;
  --catalog-only) mode="catalog-only" ;;
  --enforce-ready) mode="enforce-ready" ;;
  --enforced) mode="enforced" ;;
  --b6-ready) mode="b6-ready" ;;
  --encrypted-leg) mode="encrypted-leg" ;;
  --attested) mode="attested" ;;
  -h|--help) usage; exit 0 ;;
  *) usage >&2; exit 2 ;;
esac

GATEWAY_ORIGIN="${GATEWAY_ORIGIN:-https://api.streamvc.live}"
COORDINATOR_ORIGIN="${COORDINATOR_ORIGIN:-https://coordinator.streamvc.live}"

if [ -z "${VERIFY_TIER2_FIXTURES:-}" ]; then
  [ -n "${DEMO_TOKEN:-}" ] || { echo "verify-tier2-live: DEMO_TOKEN is required" >&2; exit 2; }
  if [ "$mode" = "full" ] || [ "$mode" = "enforce-ready" ] || [ "$mode" = "enforced" ] || [ "$mode" = "b6-ready" ] || [ "$mode" = "encrypted-leg" ] || [ "$mode" = "attested" ]; then
    [ -n "${OPERATOR_KEY:-}" ] || { echo "verify-tier2-live: OPERATOR_KEY is required for --$mode" >&2; exit 2; }
  fi
fi

python3 - "$mode" "$GATEWAY_ORIGIN" "$COORDINATOR_ORIGIN" <<'PY'
import json
import os
import re
import sys
import urllib.error
import urllib.request

MAX_RESPONSE_BYTES = 1024 * 1024


class NoRedirect(urllib.request.HTTPRedirectHandler):
    def redirect_request(self, req, fp, code, msg, headers, newurl):
        return None


opener = urllib.request.build_opener(
    urllib.request.ProxyHandler({}),
    NoRedirect(),
)

mode, gateway_origin, coordinator_origin = sys.argv[1:4]
gateway_origin = gateway_origin.rstrip("/")
coordinator_origin = coordinator_origin.rstrip("/")
fixtures = os.environ.get("VERIFY_TIER2_FIXTURES", "").strip()

def fail(message):
    raise SystemExit(f"verify-tier2-live: {message}")

def load_fixture(name):
    path = os.path.join(fixtures, name)
    with open(path, "r", encoding="utf-8") as f:
        return json.load(f)

def get_json(url, headers=None):
    headers = headers or {}
    req = urllib.request.Request(url, headers=headers)
    try:
        with opener.open(req, timeout=10) as resp:
            if resp.geturl() != url:
                fail(f"GET {url} changed origin or path to {resp.geturl()}")
            content_length = resp.headers.get("Content-Length")
            if content_length is not None:
                try:
                    declared_length = int(content_length)
                except ValueError:
                    fail(f"GET {url} returned invalid Content-Length")
                if declared_length < 0 or declared_length > MAX_RESPONSE_BYTES:
                    fail(f"GET {url} response exceeds size limit")
            raw = resp.read(MAX_RESPONSE_BYTES + 1)
            if len(raw) > MAX_RESPONSE_BYTES:
                fail(f"GET {url} response exceeds size limit")
            status = resp.getcode()
    except urllib.error.HTTPError as exc:
        body = exc.read(MAX_RESPONSE_BYTES + 1)
        if len(body) > MAX_RESPONSE_BYTES:
            fail(f"GET {url} error response exceeds size limit")
        body = body.decode("utf-8", errors="replace")
        fail(f"GET {url} failed with HTTP {exc.code}: {body[:300]}")
    except Exception as exc:
        fail(f"GET {url} failed: {exc}")
    if status < 200 or status >= 300:
        fail(f"GET {url} returned HTTP {status}")
    try:
        return json.loads(raw)
    except json.JSONDecodeError as exc:
        fail(f"GET {url} returned invalid JSON: {exc}")

def source_json(name, url, headers=None):
    if fixtures:
        return load_fixture(name)
    return get_json(url, headers)

def semver_tuple(version):
    version = str(version or "").strip()
    if version.startswith(("v", "V")):
        version = version[1:]
    parts = []
    for raw in version.split("."):
        digits = ""
        for ch in raw:
            if not ch.isdigit():
                break
            digits += ch
        parts.append(int(digits or "0"))
    while len(parts) < 3:
        parts.append(0)
    return tuple(parts[:3])

status = source_json("status.json", f"{gateway_origin}/v1/status")
if status.get("status") != "up" or status.get("degraded") is True:
    fail(f"gateway status is not healthy: {status}")

health = source_json("healthz.json", f"{coordinator_origin}/healthz")
if health.get("status") not in ("ok", "up"):
    fail(f"coordinator health is not ok: {health}")

models_headers = {"X-Demo-Token": os.environ.get("DEMO_TOKEN", "")}
models = source_json("models.json", f"{gateway_origin}/v1/models", models_headers)
tier2 = models.get("tier2")
if not isinstance(tier2, dict):
    fail("/v1/models is missing top-level tier2 block")
model_hash = tier2.get("model_hash")
if not isinstance(model_hash, dict):
    fail("/v1/models is missing tier2.model_hash block")
state = model_hash.get("state")
if state is None:
    fail("/v1/models is missing tier2.model_hash.state")
want_required = mode in ("enforced", "b6-ready", "encrypted-leg", "attested")
if model_hash.get("require_verified") is not want_required:
    fail(f"require_verified is not {str(want_required).lower()}: {model_hash.get('require_verified')!r}")
if model_hash.get("catalog_configured") is not True:
    fail("tier2 model catalog is not configured")
if model_hash.get("catalog_available") is not True:
    fail("tier2 model catalog is not available")
if mode == "full" and state not in ("partial", "all"):
    fail(f"full verification requires verified provider evidence; model_hash.state={state!r}")
if mode in ("enforce-ready", "enforced", "b6-ready", "encrypted-leg", "attested") and state != "all":
    fail(f"{mode} verification requires all models hash-verified; model_hash.state={state!r}")

summary = {
    "mode": mode,
    "gateway_status": status.get("status"),
    "coordinator_status": health.get("status"),
    "pool_ready": health.get("pool_ready"),
    "model_count": len(models.get("data", [])),
    "tier2_phase": tier2.get("phase"),
    "model_hash_state": state,
    "require_verified": model_hash.get("require_verified"),
    "catalog_available": model_hash.get("catalog_available"),
}

if mode in ("full", "enforce-ready", "enforced", "b6-ready", "encrypted-leg", "attested"):
    pool_headers = {"Authorization": "Bearer " + os.environ.get("OPERATOR_KEY", "")}
    poolz = source_json("poolz.json", f"{coordinator_origin}/poolz", pool_headers)
    providers = poolz.get("pool")
    if not isinstance(providers, list):
        fail("/poolz is missing pool list")
    bad = [
        p for p in providers
        if str(p.get("hash_status", "")).strip() in ("hash_mismatch", "hash_invalid", "catalog_unavailable")
    ]
    if bad:
        fail("pool contains failing hash statuses: " + json.dumps([
            {
                "provider_id": p.get("provider_id"),
                "model_id": p.get("model_id"),
                "binary_version": p.get("binary_version"),
                "hash_status": p.get("hash_status"),
            }
            for p in bad
        ], sort_keys=True))
    updated_verified = [
        p for p in providers
        if semver_tuple(p.get("binary_version")) >= (1, 2, 5)
        and p.get("hash_status") == "hash_verified"
        and str(p.get("model_hash", "")).strip()
    ]
    if not updated_verified:
        fail("no v1.2.5+ provider is hash_verified in /poolz")
    summary["verified_provider_count"] = len(updated_verified)
    summary["verified_providers"] = [
        {
            "provider_id": p.get("provider_id"),
            "model_id": p.get("model_id"),
            "binary_version": p.get("binary_version"),
            "hash_status": p.get("hash_status"),
        }
        for p in updated_verified
    ]

    def ready_routable(provider):
        if not isinstance(provider, dict):
            return False
        if str(provider.get("state") or "") != "ready":
            return False
        try:
            slots_free = int(provider.get("slots_free", 0))
        except (TypeError, ValueError):
            slots_free = 0
        return slots_free > 0

    if mode in ("enforce-ready", "enforced"):
        if not providers:
            fail("hash enforcement requires a non-empty physical provider cohort")
        invalid_snapshot_providers = []
        for provider in providers:
            if (
                provider.get("model_hash_algorithm") != "macprovider.snapshot-manifest.v1"
                or re.fullmatch(r"[0-9a-f]{64}", str(provider.get("model_hash") or "")) is None
                or provider.get("hash_status") != "hash_verified"
                or str(provider.get("state") or "") != "ready"
                or provider.get("routing_eligible") is not True
            ):
                invalid_snapshot_providers.append(
                    {
                        "provider_id": provider.get("provider_id"),
                        "model_id": provider.get("model_id"),
                        "model_hash_algorithm": provider.get("model_hash_algorithm"),
                        "hash_status": provider.get("hash_status"),
                        "state": provider.get("state"),
                        "routing_eligible": provider.get("routing_eligible"),
                    }
                )
        if invalid_snapshot_providers:
            fail(
                "physical provider cohort is not snapshot-manifest hash-verified and buyer-routable: "
                + json.dumps(invalid_snapshot_providers, sort_keys=True)
            )
        summary["snapshot_manifest_provider_count"] = len(providers)

    if mode in ("b6-ready", "encrypted-leg", "attested"):
        tier1 = models.get("tier1_disclosure")
        if not isinstance(tier1, dict):
            fail("/v1/models is missing tier1_disclosure")
        reported = tier1.get("provider_leg_encryption")
        if reported != "all":
            fail(f"tier1_disclosure.provider_leg_encryption={reported!r}, want 'all'")
        encrypted = tier2.get("encrypted_leg")
        if not isinstance(encrypted, dict):
            nested = tier1.get("tier2") if isinstance(tier1.get("tier2"), dict) else {}
            encrypted = nested.get("encrypted_leg") if isinstance(nested, dict) else None
        if not isinstance(encrypted, dict):
            fail("/v1/models is missing tier2.encrypted_leg disclosure")
        if encrypted.get("state") != "all":
            fail(f"tier2.encrypted_leg.state={encrypted.get('state')!r}, want 'all'")
        if encrypted.get("scope") not in ("coordinator_to_provider_only", None):
            fail(f"tier2.encrypted_leg.scope={encrypted.get('scope')!r}, want coordinator_to_provider_only")
        if int(encrypted.get("encrypted_provider_count") or 0) <= 0:
            fail("tier2.encrypted_leg.encrypted_provider_count must be > 0")
        if int(encrypted.get("unencrypted_provider_count") or 0) != 0:
            fail("tier2.encrypted_leg.unencrypted_provider_count must be 0")
        ready_encrypted = []
        ready_plain = []
        for provider in providers:
            if not ready_routable(provider):
                continue
            if provider.get("encrypted_leg") is True:
                ready_encrypted.append(provider)
            else:
                ready_plain.append(provider)
        if ready_plain:
            fail("currently routable providers missing encrypted_leg=true: " + json.dumps([
                {
                    "provider_id": p.get("provider_id"),
                    "model_id": p.get("model_id"),
                    "binary_version": p.get("binary_version"),
                    "encrypted_leg": p.get("encrypted_leg"),
                }
                for p in ready_plain
            ], sort_keys=True))
        if not ready_encrypted:
            fail("no ready encrypted provider found in /poolz")
        ready_old_encrypted = [
            p for p in ready_encrypted
            if semver_tuple(p.get("binary_version")) < (1, 2, 6)
        ]
        if ready_old_encrypted:
            fail("currently routable encrypted providers below v1.2.6: " + json.dumps([
                {
                    "provider_id": p.get("provider_id"),
                    "model_id": p.get("model_id"),
                    "binary_version": p.get("binary_version"),
                    "encrypted_leg": p.get("encrypted_leg"),
                }
                for p in ready_old_encrypted
            ], sort_keys=True))
        ready_b6 = [
            p for p in ready_encrypted
            if semver_tuple(p.get("binary_version")) >= (1, 2, 6)
        ]
        if not ready_b6:
            fail("no ready v1.2.6+ encrypted provider found in /poolz")
        summary["provider_leg_encryption"] = reported
        summary["encrypted_provider_count"] = encrypted.get("encrypted_provider_count")
        summary["ready_encrypted_provider_count"] = len(ready_encrypted)
        summary["ready_b6_provider_count"] = len(ready_b6)
        summary["ready_b6_providers"] = [
            {
                "provider_id": p.get("provider_id"),
                "model_id": p.get("model_id"),
                "binary_version": p.get("binary_version"),
                "hash_status": p.get("hash_status"),
                "encrypted_leg": p.get("encrypted_leg"),
            }
            for p in ready_b6
        ]

    if mode == "attested":
        tier1 = models.get("tier1_disclosure")
        reported = tier1.get("hardware_attestation")
        if reported != "all":
            fail(f"tier1_disclosure.hardware_attestation={reported!r}, want 'all'")
        attestation = tier2.get("attestation")
        if not isinstance(attestation, dict):
            nested = tier1.get("tier2") if isinstance(tier1.get("tier2"), dict) else {}
            attestation = nested.get("attestation") if isinstance(nested, dict) else None
        if not isinstance(attestation, dict):
            fail("/v1/models is missing tier2.attestation disclosure")
        if attestation.get("state") != "all":
            fail(f"tier2.attestation.state={attestation.get('state')!r}, want 'all'")
        if int(attestation.get("attested_provider_count") or 0) <= 0:
            fail("tier2.attestation.attested_provider_count must be > 0")
        if int(attestation.get("unsupported_provider_count") or 0) != 0:
            fail("tier2.attestation.unsupported_provider_count must be 0")
        ready_attested = []
        ready_bad = []
        for provider in providers:
            if not ready_routable(provider):
                continue
            if provider.get("encrypted_leg") is True and str(provider.get("attestation_status") or "") == "attested":
                ready_attested.append(provider)
            else:
                ready_bad.append(provider)
        if ready_bad:
            fail("currently routable providers are not encrypted+attested: " + json.dumps([
                {
                    "provider_id": p.get("provider_id"),
                    "model_id": p.get("model_id"),
                    "binary_version": p.get("binary_version"),
                    "encrypted_leg": p.get("encrypted_leg"),
                    "attestation_status": p.get("attestation_status"),
                }
                for p in ready_bad
            ], sort_keys=True))
        if not ready_attested:
            fail("no ready encrypted+attested provider found in /poolz")
        summary["hardware_attestation"] = reported
        summary["attested_provider_count"] = attestation.get("attested_provider_count")
        summary["ready_attested_provider_count"] = len(ready_attested)

print(json.dumps(summary, indent=2, sort_keys=True))
PY
