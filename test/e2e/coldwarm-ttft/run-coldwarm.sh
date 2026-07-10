#!/usr/bin/env bash
# Wrapper for the cold/warm TTFT probe. Resolves the buyer token, then runs the
# requested scenario (warm accumulation, a single cold sample, or a matrix
# rebuild). Intended for launchd/systemd (warm + matrix) or by hand (cold cycles).
#
# Token resolution order (same as P1's run-canary.sh):
#   1. $MACPROVIDER_BUYER_TOKEN (if already exported)
#   2. $COLDWARM_TOKEN_FILE (default ~/.config/macprovider/buyer-api-key)
# The token is never echoed. Diagnostics go to stderr / the service log.
#
# Usage:
#   run-coldwarm.sh --scenario warm --model mlx-community/Qwen3-Coder-30B-A3B-Instruct-4bit
#   (use the FULL id the provider advertises / that /v1/status returns — the short
#    rate-card key qwen3-coder-30b-a3b-instruct 404s post-#510. Or omit --model to
#    auto-derive from /v1/status.)
#   run-coldwarm.sh --scenario cold --state cold      # after inducing cold
#   run-coldwarm.sh --build-matrix
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

: "${COLDWARM_BASE:=https://api.streamvc.live}"
: "${COLDWARM_TOKEN_FILE:=$HOME/.config/macprovider/buyer-api-key}"
: "${COLDWARM_STORE:=$HOME/.local/state/coldwarm-ttft/coldwarm-samples.ndjson}"
: "${COLDWARM_METRICS_OUT:=$HOME/.local/state/coldwarm-ttft/coldwarm.prom}"
: "${COLDWARM_JSON_OUT:=$HOME/.local/state/coldwarm-ttft/artifacts}"

# build-matrix does not need a token (it only reads the local store).
needs_token=1
for a in "$@"; do
  [[ "$a" == "--build-matrix" ]] && needs_token=0
done

if [[ "$needs_token" == "1" && -z "${MACPROVIDER_BUYER_TOKEN:-}" ]]; then
  if [[ -r "$COLDWARM_TOKEN_FILE" ]]; then
    MACPROVIDER_BUYER_TOKEN="$(tr -d '[:space:]' < "$COLDWARM_TOKEN_FILE")"
    export MACPROVIDER_BUYER_TOKEN
  else
    echo "coldwarm: no token in \$MACPROVIDER_BUYER_TOKEN and $COLDWARM_TOKEN_FILE not readable" >&2
    exit 2
  fi
fi

export COLDWARM_BASE COLDWARM_STORE COLDWARM_METRICS_OUT COLDWARM_JSON_OUT

# launchd/systemd run with a minimal PATH that usually lacks Homebrew/node.
export PATH="/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:$PATH"
NODE_BIN="${COLDWARM_NODE_BIN:-$(command -v node || true)}"
if [[ -z "$NODE_BIN" ]]; then
  echo "coldwarm: node not found on PATH; set \$COLDWARM_NODE_BIN to the node binary" >&2
  exit 2
fi

# --build-matrix writes the prom textfile + JSON artifact; probing scenarios only
# append to the store (the matrix is rebuilt separately by the matrix unit).
exec "$NODE_BIN" "$HERE/coldwarm-probe.mjs" \
  --store "$COLDWARM_STORE" \
  --metrics-out "$COLDWARM_METRICS_OUT" \
  --json-out "$COLDWARM_JSON_OUT" \
  "$@"
