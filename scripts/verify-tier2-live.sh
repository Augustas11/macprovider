#!/usr/bin/env bash
# Read-only SPEC-008 Phase 1 live verifier.
#
# Full mode verifies:
# - gateway /v1/status and coordinator /healthz are healthy
# - gateway /v1/models exposes tier2.model_hash.state with require_verified=false
# - operator /poolz has at least one v1.2.5+ provider with hash_status=hash_verified
#
# Catalog-only mode verifies catalog disclosure without requiring a verified
# upgraded provider. Use catalog-only immediately after C1 observe activation;
# use full after provider v1.2.5 rollout.

set -euo pipefail

usage() {
  cat <<'USAGE'
usage: scripts/verify-tier2-live.sh [--full|--catalog-only]

Environment:
  GATEWAY_ORIGIN        default: https://api.streamvc.live
  COORDINATOR_ORIGIN   default: https://coordinator.streamvc.live
  DEMO_TOKEN           required unless VERIFY_TIER2_FIXTURES is set
  OPERATOR_KEY         required for --full unless VERIFY_TIER2_FIXTURES is set
  VERIFY_TIER2_FIXTURES optional directory with status.json, healthz.json,
                       models.json, and poolz.json for local parser testing
USAGE
}

mode="full"
case "${1:---full}" in
  --full) mode="full" ;;
  --catalog-only) mode="catalog-only" ;;
  -h|--help) usage; exit 0 ;;
  *) usage >&2; exit 2 ;;
esac

GATEWAY_ORIGIN="${GATEWAY_ORIGIN:-https://api.streamvc.live}"
COORDINATOR_ORIGIN="${COORDINATOR_ORIGIN:-https://coordinator.streamvc.live}"

if [ -z "${VERIFY_TIER2_FIXTURES:-}" ]; then
  [ -n "${DEMO_TOKEN:-}" ] || { echo "verify-tier2-live: DEMO_TOKEN is required" >&2; exit 2; }
  if [ "$mode" = "full" ]; then
    [ -n "${OPERATOR_KEY:-}" ] || { echo "verify-tier2-live: OPERATOR_KEY is required for --full" >&2; exit 2; }
  fi
fi

python3 - "$mode" "$GATEWAY_ORIGIN" "$COORDINATOR_ORIGIN" <<'PY'
import json
import os
import sys
import urllib.error
import urllib.request

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
        with urllib.request.urlopen(req, timeout=10) as resp:
            raw = resp.read()
            status = resp.getcode()
    except urllib.error.HTTPError as exc:
        body = exc.read().decode("utf-8", errors="replace")
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
if model_hash.get("require_verified") is not False:
    fail(f"require_verified is not false: {model_hash.get('require_verified')!r}")
if model_hash.get("catalog_configured") is not True:
    fail("tier2 model catalog is not configured")
if model_hash.get("catalog_available") is not True:
    fail("tier2 model catalog is not available")
if mode == "full" and state not in ("partial", "all"):
    fail(f"full verification requires verified provider evidence; model_hash.state={state!r}")

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

if mode == "full":
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

print(json.dumps(summary, indent=2, sort_keys=True))
PY
