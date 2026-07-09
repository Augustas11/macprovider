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
: "${CANARY_TOKEN_FILE:=$HOME/.config/macprovider/buyer-api-key}"
: "${CANARY_METRICS_OUT:=$HOME/.local/state/canary-buyer/canary_buyer.prom}"
: "${CANARY_JSON_OUT:=$HOME/.local/state/canary-buyer/artifacts}"
# Optional: export CANARY_PUSHGATEWAY=http://host:9091 to push instead of/along
# with the textfile.

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

# Artifact rotation (keep newest 200) is handled inside probe.mjs in Node, so no
# filename can be misparsed by the shell into an unintended delete.

exec "$NODE_BIN" "$HERE/probe.mjs" \
  --metrics-out "$CANARY_METRICS_OUT" \
  --json-out "$CANARY_JSON_OUT" \
  "$@"
