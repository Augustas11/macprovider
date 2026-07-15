#!/usr/bin/env bash
# Wrapper for the canary buyer probe. Resolves credentials, runs exactly one
# bounded probe, and writes a Prometheus textfile + a rotated JSON artifact. Intended to be
# invoked by launchd (com.streamvc.canary-buyer.plist) on a lab Mac, or by hand.
#
# Token resolution order:
#   1. $MACPROVIDER_BUYER_TOKEN (if already exported)
#   2. ~/.config/macprovider/buyer-api-key  (the documented harness location)
#
# The token is never echoed. Diagnostics go to stderr / the launchd log.
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

: "${CANARY_BASE:=https://api.streamvc.live}"
: "${CANARY_TOKEN_FILE:=${HOME:-/nonexistent}/.config/macprovider/buyer-api-key}"
: "${CANARY_OPERATOR_TOKEN_FILE:=${HOME:-/nonexistent}/.config/macprovider/operator-api-key}"
: "${CANARY_HEARTBEAT_FILE:=${HOME:-/nonexistent}/.config/macprovider/canary-heartbeat-url}"
: "${CANARY_EXPECTED_FLEET_FILE:=${HOME:-/nonexistent}/.config/macprovider/canary-expected-fleet.json}"
: "${CANARY_METRICS_OUT:=${HOME:-/nonexistent}/.local/state/canary-buyer/canary_buyer.prom}"
: "${CANARY_JSON_OUT:=${HOME:-/nonexistent}/.local/state/canary-buyer/artifacts}"
: "${CANARY_DISABLE_FILE:=${HOME:-/nonexistent}/.local/state/canary-buyer/DISABLED}"
# Optional: export CANARY_PUSHGATEWAY=https://host:9091 to push instead of/along
# with the textfile. A scheduled unit should also set CANARY_ENABLE_FILE; its
# absence keeps the shipped schedule fail-closed until the production gate is
# approved.

validate_user_file() {
  local path="$1" label="$2" metadata owner mode
  [[ ! -L "$path" && -f "$path" && -r "$path" ]] || {
    echo "canary: $label must be a readable regular file, not a symlink: $path" >&2
    return 2
  }
  if [[ "$(uname -s)" == "Darwin" ]]; then
    metadata="$(stat -f '%u %Lp' "$path" 2>/dev/null)" || metadata=""
  else
    metadata="$(stat -c '%u %a' "$path" 2>/dev/null)" || metadata=""
  fi
  if [[ -z "$metadata" ]]; then
    echo "canary: cannot inspect $label ownership/mode: $path" >&2
    return 2
  fi
  read -r owner mode <<<"$metadata"
  if [[ "$owner" != "$(id -u)" || ! "$mode" =~ ^[0-7]{3,4}$ || $((8#$mode & 0077)) -ne 0 || $((8#$mode & 0400)) -eq 0 ]]; then
    echo "canary: $label must be owned by uid $(id -u) and mode 0400 or 0600: $path" >&2
    return 2
  fi
}

if [[ -e "$CANARY_DISABLE_FILE" ]]; then
  echo "canary: class=emergency_disabled sentinel=$CANARY_DISABLE_FILE; no requests issued" >&2
  exit 0
fi
if [[ -n "${CANARY_ENABLE_FILE:-}" && ! -e "$CANARY_ENABLE_FILE" ]]; then
  echo "canary: class=not_enabled gate=$CANARY_ENABLE_FILE; no requests issued" >&2
  exit 0
fi

if [[ -z "${MACPROVIDER_BUYER_TOKEN:-}" && -n "${CREDENTIALS_DIRECTORY:-}" && -r "$CREDENTIALS_DIRECTORY/buyer_token" ]]; then
  MACPROVIDER_BUYER_TOKEN="$(tr -d '[:space:]' < "$CREDENTIALS_DIRECTORY/buyer_token")"
  export MACPROVIDER_BUYER_TOKEN
fi
if [[ -z "${CANARY_HEARTBEAT_URL:-}" && -n "${CREDENTIALS_DIRECTORY:-}" && -r "$CREDENTIALS_DIRECTORY/heartbeat_url" ]]; then
  CANARY_HEARTBEAT_URL="$(tr -d '\r\n' < "$CREDENTIALS_DIRECTORY/heartbeat_url")"
fi
if [[ -z "${CANARY_OPERATOR_TOKEN:-}" && -n "${CREDENTIALS_DIRECTORY:-}" && -r "$CREDENTIALS_DIRECTORY/operator_token" ]]; then
  CANARY_OPERATOR_TOKEN="$(tr -d '[:space:]' < "$CREDENTIALS_DIRECTORY/operator_token")"
  export CANARY_OPERATOR_TOKEN
fi
if [[ -z "${CANARY_OPERATOR_TOKEN:-}" && ( -e "$CANARY_OPERATOR_TOKEN_FILE" || -L "$CANARY_OPERATOR_TOKEN_FILE" ) ]]; then
  validate_user_file "$CANARY_OPERATOR_TOKEN_FILE" CANARY_OPERATOR_TOKEN_FILE
  CANARY_OPERATOR_TOKEN="$(tr -d '[:space:]' < "$CANARY_OPERATOR_TOKEN_FILE")"
  export CANARY_OPERATOR_TOKEN
fi
if [[ -z "${CANARY_HEARTBEAT_URL:-}" && ( -e "$CANARY_HEARTBEAT_FILE" || -L "$CANARY_HEARTBEAT_FILE" ) ]]; then
  validate_user_file "$CANARY_HEARTBEAT_FILE" CANARY_HEARTBEAT_FILE
  CANARY_HEARTBEAT_URL="$(tr -d '\r\n' < "$CANARY_HEARTBEAT_FILE")"
fi
# The heartbeat URL is a write-only monitor secret and is not needed by Node or
# any other child. Keep it in the wrapper shell, not inherited process
# environments; curl receives it only through stdin below.
export -n CANARY_HEARTBEAT_URL 2>/dev/null || true
if [[ -n "${CREDENTIALS_DIRECTORY:-}" && -r "$CREDENTIALS_DIRECTORY/expected_fleet" ]]; then
  CANARY_EXPECTED_FLEET_FILE="$CREDENTIALS_DIRECTORY/expected_fleet"
  export CANARY_EXPECTED_FLEET_FILE
fi
if [[ -z "${CREDENTIALS_DIRECTORY:-}" && ( -e "$CANARY_EXPECTED_FLEET_FILE" || -L "$CANARY_EXPECTED_FLEET_FILE" ) ]]; then
  validate_user_file "$CANARY_EXPECTED_FLEET_FILE" CANARY_EXPECTED_FLEET_FILE
fi

probe_mode="${CANARY_MODE:-liveness}"
for ((i = 1; i <= $#; i++)); do
  if [[ "${!i}" == "--mode" ]]; then
    next=$((i + 1))
    if ((next <= $#)); then probe_mode="${!next}"; fi
  fi
done

if [[ "$probe_mode" == "liveness" && -z "${MACPROVIDER_BUYER_TOKEN:-}" ]]; then
  if [[ -e "$CANARY_TOKEN_FILE" || -L "$CANARY_TOKEN_FILE" ]]; then
    validate_user_file "$CANARY_TOKEN_FILE" CANARY_TOKEN_FILE
    MACPROVIDER_BUYER_TOKEN="$(tr -d '[:space:]' < "$CANARY_TOKEN_FILE")"
    export MACPROVIDER_BUYER_TOKEN
  else
    echo "canary: no token in \$MACPROVIDER_BUYER_TOKEN and $CANARY_TOKEN_FILE not readable" >&2
    exit 2
  fi
fi

export CANARY_BASE CANARY_METRICS_OUT CANARY_JSON_OUT CANARY_DISABLE_FILE CANARY_EXPECTED_FLEET_FILE

# launchd runs with a minimal PATH that usually lacks Homebrew, so a bare `node`
# would fail every scheduled run. Resolve it explicitly.
export PATH="/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:$PATH"
NODE_BIN="${CANARY_NODE_BIN:-$(command -v node || true)}"
if [[ -z "$NODE_BIN" ]]; then
  echo "canary: node not found on PATH; set \$CANARY_NODE_BIN to the node binary" >&2
  exit 2
fi
CURL_BIN="${CANARY_CURL_BIN:-$(command -v curl || true)}"
if [[ -z "$CURL_BIN" ]]; then
  echo "canary: curl not found; set \$CANARY_CURL_BIN to the curl binary" >&2
  exit 2
fi

if [[ "$probe_mode" == "qualification" ]]; then
  PROBE_TIMEOUT_SECONDS="${CANARY_PROBE_TIMEOUT_SECONDS:-330}"
else
  PROBE_TIMEOUT_SECONDS="${CANARY_PROBE_TIMEOUT_SECONDS:-120}"
fi
if [[ -n "${CANARY_DEGRADED_RETRIES:-}" && "${CANARY_DEGRADED_RETRIES}" != "0" ]]; then
  echo "canary: class=configuration_error CANARY_DEGRADED_RETRIES is disabled; degraded probes must not amplify load" >&2
  exit 2
fi
if [[ ! "$PROBE_TIMEOUT_SECONDS" =~ ^([6-9][0-9]|[1-8][0-9]{2}|900)$ ]]; then
  echo "canary: CANARY_PROBE_TIMEOUT_SECONDS must be an integer in 60...900 without leading zeros" >&2
  exit 2
fi
PROBE_TIMEOUT_SECONDS=$((10#$PROBE_TIMEOUT_SECONDS))
TIMEOUT_BIN="${CANARY_TIMEOUT_BIN:-$(command -v timeout || true)}"
if [[ -z "$TIMEOUT_BIN" || ! -x "$TIMEOUT_BIN" ]]; then
  echo "canary: timeout not found; every probe requires CANARY_TIMEOUT_BIN (GNU timeout/gtimeout)" >&2
  exit 2
fi

# Artifact rotation (keep newest 200) is handled inside probe.mjs in Node, so no
# filename can be misparsed by the shell into an unintended delete.

# Optional dead-man's-switch heartbeat. When CANARY_HEARTBEAT_URL is set (an
# https BetterStack / healthchecks-style ping URL), the wrapper pings it ONLY
# when the probe exits 0 (healthy). A degraded run (with --fail-on-degraded) or a
# probe that never runs leaves the heartbeat stale, so the upstream monitor
# alerts. The heartbeat URL carries no buyer token, but we still require https so
# a mispointed URL can't be reached over cleartext
# (CANARY_ALLOW_INSECURE_HEARTBEAT=1 is the only local-test escape hatch and
# is scoped to this heartbeat only).
if [[ "${CANARY_REQUIRE_HEARTBEAT:-0}" == "1" && -z "${CANARY_HEARTBEAT_URL:-}" ]]; then
  echo "canary: CANARY_REQUIRE_HEARTBEAT=1 but CANARY_HEARTBEAT_URL is unset" >&2
  exit 2
fi

probe_command=(
  "$NODE_BIN" "$HERE/probe.mjs"
  --metrics-out "$CANARY_METRICS_OUT"
  --json-out "$CANARY_JSON_OUT"
  "$@"
)
probe_command=(
  "$TIMEOUT_BIN" --signal=TERM --kill-after=5 "${PROBE_TIMEOUT_SECONDS}s"
  "${probe_command[@]}"
)

if [[ -n "${CANARY_HEARTBEAT_URL:-}" ]]; then
  if [[ "$CANARY_HEARTBEAT_URL" == *$'\n'* || "$CANARY_HEARTBEAT_URL" == *$'\r'* ]]; then
    echo "canary: CANARY_HEARTBEAT_URL contains a forbidden newline" >&2
    exit 2
  fi
  if [[ "$CANARY_HEARTBEAT_URL" != https://* && "${CANARY_ALLOW_INSECURE_HEARTBEAT:-}" != "1" ]]; then
    echo "canary: CANARY_HEARTBEAT_URL must be https (CANARY_ALLOW_INSECURE_HEARTBEAT=1 is test-only)" >&2
    exit 2
  fi
  if CANARY_HEARTBEAT_URL='' "${probe_command[@]}"; then
    :
  else
    rc=$?
    echo "canary: class=probe_failed exit=$rc; no retry; heartbeat NOT pinged" >&2
    exit "$rc"
  fi
  heartbeat_protocols='=https'
  if [[ "${CANARY_ALLOW_INSECURE_HEARTBEAT:-}" == "1" ]]; then
    heartbeat_protocols='=http,https'
  fi
  heartbeat_config_url="${CANARY_HEARTBEAT_URL//\\/\\\\}"
  heartbeat_config_url="${heartbeat_config_url//\"/\\\"}"
  if ! heartbeat_status="$(printf 'url = "%s"\n' "$heartbeat_config_url" | \
      "$CURL_BIN" -q --config - --proto "$heartbeat_protocols" --max-redirs 0 \
      -sS -o /dev/null -w '%{http_code}' -m 10 2>/dev/null)"; then
    echo "canary: class=heartbeat_delivery_failed ping failed after a healthy probe" >&2
    exit 3
  fi
  if [[ ! "$heartbeat_status" =~ ^2[0-9][0-9]$ ]]; then
    echo "canary: class=heartbeat_delivery_failed HTTP $heartbeat_status after a healthy probe" >&2
    exit 3
  fi
  exit 0
fi

exec "${probe_command[@]}"
