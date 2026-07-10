#!/usr/bin/env bash
# Wrapper for the canary buyer probe. Resolves the buyer token, runs the probe,
# and writes a Prometheus textfile + a rotated JSON artifact. Intended to be
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
: "${CANARY_METRICS_OUT:=${HOME:-/nonexistent}/.local/state/canary-buyer/canary_buyer.prom}"
: "${CANARY_JSON_OUT:=${HOME:-/nonexistent}/.local/state/canary-buyer/artifacts}"
# Optional: export CANARY_PUSHGATEWAY=http://host:9091 to push instead of/along
# with the textfile.

if [[ -z "${MACPROVIDER_BUYER_TOKEN:-}" && -n "${CREDENTIALS_DIRECTORY:-}" && -r "$CREDENTIALS_DIRECTORY/buyer_token" ]]; then
  MACPROVIDER_BUYER_TOKEN="$(tr -d '[:space:]' < "$CREDENTIALS_DIRECTORY/buyer_token")"
  export MACPROVIDER_BUYER_TOKEN
fi
if [[ -z "${CANARY_HEARTBEAT_URL:-}" && -n "${CREDENTIALS_DIRECTORY:-}" && -r "$CREDENTIALS_DIRECTORY/heartbeat_url" ]]; then
  CANARY_HEARTBEAT_URL="$(tr -d '\r\n' < "$CREDENTIALS_DIRECTORY/heartbeat_url")"
  export CANARY_HEARTBEAT_URL
fi

if [[ -z "${MACPROVIDER_BUYER_TOKEN:-}" ]]; then
  if [[ -r "$CANARY_TOKEN_FILE" ]]; then
    MACPROVIDER_BUYER_TOKEN="$(tr -d '[:space:]' < "$CANARY_TOKEN_FILE")"
    export MACPROVIDER_BUYER_TOKEN
  else
    echo "canary: no token in \$MACPROVIDER_BUYER_TOKEN and $CANARY_TOKEN_FILE not readable" >&2
    exit 2
  fi
fi

export CANARY_BASE CANARY_METRICS_OUT CANARY_JSON_OUT

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

DEGRADED_RETRIES="${CANARY_DEGRADED_RETRIES:-0}"
RETRY_DELAY_SECONDS="${CANARY_RETRY_DELAY_SECONDS:-15}"
PROBE_TIMEOUT_SECONDS="${CANARY_PROBE_TIMEOUT_SECONDS:-}"
if [[ ! "$DEGRADED_RETRIES" =~ ^[0-3]$ ]]; then
  echo "canary: CANARY_DEGRADED_RETRIES must be an integer in 0...3 without leading zeros" >&2
  exit 2
fi
if [[ ! "$RETRY_DELAY_SECONDS" =~ ^(0|[1-9][0-9]{0,2})$ ]]; then
  echo "canary: CANARY_RETRY_DELAY_SECONDS must be an integer in 0...300 without leading zeros" >&2
  exit 2
fi
DEGRADED_RETRIES=$((10#$DEGRADED_RETRIES))
RETRY_DELAY_SECONDS=$((10#$RETRY_DELAY_SECONDS))
if (( RETRY_DELAY_SECONDS > 300 )); then
  echo "canary: CANARY_RETRY_DELAY_SECONDS must be an integer in 0...300 without leading zeros" >&2
  exit 2
fi
if [[ -n "$PROBE_TIMEOUT_SECONDS" ]]; then
  if [[ ! "$PROBE_TIMEOUT_SECONDS" =~ ^([6-9][0-9]|[1-8][0-9]{2}|900)$ ]]; then
    echo "canary: CANARY_PROBE_TIMEOUT_SECONDS must be an integer in 60...900 without leading zeros" >&2
    exit 2
  fi
  PROBE_TIMEOUT_SECONDS=$((10#$PROBE_TIMEOUT_SECONDS))
  TIMEOUT_BIN="${CANARY_TIMEOUT_BIN:-$(command -v timeout || true)}"
  if [[ -z "$TIMEOUT_BIN" ]]; then
    echo "canary: timeout not found; set CANARY_TIMEOUT_BIN when CANARY_PROBE_TIMEOUT_SECONDS is configured" >&2
    exit 2
  fi
fi

# Artifact rotation (keep newest 200) is handled inside probe.mjs in Node, so no
# filename can be misparsed by the shell into an unintended delete.

# Optional dead-man's-switch heartbeat. When CANARY_HEARTBEAT_URL is set (an
# https BetterStack / healthchecks-style ping URL), the wrapper pings it ONLY
# when the probe exits 0 (healthy). A degraded run (with --fail-on-degraded) or a
# probe that never runs leaves the heartbeat stale, so the upstream monitor
# alerts. The heartbeat URL carries no buyer token, but we still require https so
# a mispointed URL can't be reached over cleartext (CANARY_ALLOW_INSECURE=1
# bypasses, for local testing only).
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
if [[ -n "$PROBE_TIMEOUT_SECONDS" ]]; then
  probe_command=(
    "$TIMEOUT_BIN" --signal=TERM --kill-after=5 "${PROBE_TIMEOUT_SECONDS}s"
    "${probe_command[@]}"
  )
fi

if [[ -n "${CANARY_HEARTBEAT_URL:-}" ]]; then
  if [[ "$CANARY_HEARTBEAT_URL" != https://* && "${CANARY_ALLOW_INSECURE:-}" != "1" ]]; then
    echo "canary: CANARY_HEARTBEAT_URL must be https (set CANARY_ALLOW_INSECURE=1 to allow http)" >&2
    exit 2
  fi
  attempt=0
  while :; do
    if "${probe_command[@]}"; then
      heartbeat_protocols='=https'
      if [[ "${CANARY_ALLOW_INSECURE:-}" == "1" ]]; then
        heartbeat_protocols='=http,https'
      fi
      if ! heartbeat_status="$("$CURL_BIN" -q --proto "$heartbeat_protocols" --max-redirs 0 \
          -sS -o /dev/null -w '%{http_code}' -m 10 "$CANARY_HEARTBEAT_URL" 2>/dev/null)"; then
        echo "canary: heartbeat ping failed after a healthy probe" >&2
        exit 3
      fi
      if [[ ! "$heartbeat_status" =~ ^2[0-9][0-9]$ ]]; then
        echo "canary: heartbeat returned HTTP $heartbeat_status after a healthy probe" >&2
        exit 3
      fi
      exit 0
    else
      rc=$?
    fi
    if (( attempt >= DEGRADED_RETRIES )); then
      echo "canary: probe exited $rc; heartbeat NOT pinged (dead-man switch will fire)" >&2
      exit "$rc"
    fi
    attempt=$((attempt + 1))
    echo "canary: probe exited $rc; retrying full probe in ${RETRY_DELAY_SECONDS}s ($attempt/$DEGRADED_RETRIES)" >&2
    sleep "$RETRY_DELAY_SECONDS"
  done
fi

exec "${probe_command[@]}"
