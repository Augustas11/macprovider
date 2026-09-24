#!/usr/bin/env bash
# Canary stand-in (tier E2 evidence (c)) in a sandboxed HOME on this Mac.
#
# GAP (recorded, not faked away): the real branch-HEAD macprovider-cli cannot be
# the canary here: (1) the only launchd provider slot on this Mac
# (gui/<uid>/live.malibu.provider) runs the operator's PRODUCTION provider and
# must not be touched; (2) the CLI trusts only the production catalog keys, so
# it cannot adopt a test-signed release; (3) buyer-serving needs an MLX model
# download. The lane's canary contract is exercised end to end instead through
# this stand-in: the unmodified ops/pearl-updater/catalog-canary-proof.py (and
# the deploy's embedded proof) runs over the lane's SSH command line (routed by
# bin/ssh into this sandbox HOME), reads the sandbox LaunchAgent plist, the
# stand-in's live text vnode via /usr/sbin/lsof, and its /v1/status; the
# coordinator admits the stand-in (fakeprov serve) over a real WS session
# through an SSH tunnel, and /v1/pool/check judges it.
#   e2e_canary_install <release-dir>   install binary/plist/config/catalog files
#   e2e_canary_start | e2e_canary_stop | e2e_canary_status
set -euo pipefail
. "$(dirname "${BASH_SOURCE[0]}")/../env.sh"
. "$(dirname "${BASH_SOURCE[0]}")/common.sh"
CH="$E2E_CANARY_HOME"
e2e_canary_install() {
  local rel="$1"
  mkdir -p "$CH/.config/macprovider" "$CH/Library/LaunchAgents" "$CH/macprovider/catalog-release" "$CH/.e2e"
  chmod 700 "$CH" "$CH/.config/macprovider"
  printf '%s\n' "$E2E_CANARY_PROVIDER_ID" >"$CH/.config/macprovider/provider_id"
  vm "cat /root/e2e/token-$E2E_CANARY_PROVIDER_ID" >"$CH/.config/macprovider/provider-token"
  chmod 600 "$CH/.config/macprovider/provider-token"
  install -m 0755 "$E2E_HARNESS/fakeprov/dist/fakeprov-darwin-arm64" "$CH/macprovider/macprovider-cli"
  cat >"$CH/.config/macprovider/config.yaml" <<CFG
# e2e canary stand-in config (fakeprov serve --config)
port: 19191
coordinator_ws: ws://127.0.0.1:$E2E_PROVIDER_LOCAL_PORT/ws/provider
provider_id: $E2E_CANARY_PROVIDER_ID
token_file: $CH/.config/macprovider/provider-token
http_listen: 127.0.0.1:$E2E_CANARY_ENDPOINT_PORT
endpoint_url: http://127.0.0.1:$E2E_CANARY_ENDPOINT_PORT
catalog_from_coordinator: http://127.0.0.1:$E2E_BUYER_LOCAL_PORT
settlement: true
CFG
  /usr/bin/python3 - "$CH" <<'PY'
import plistlib, sys
h = sys.argv[1]
plistlib.dump({"Label": "live.malibu.provider",
               "ProgramArguments": [h + "/macprovider/macprovider-cli", "serve", "--config", h + "/.config/macprovider/config.yaml"],
               "RunAtLoad": True}, open(h + "/Library/LaunchAgents/live.malibu.provider.plist", "wb"))
PY
  for f in release.json trusted-keys.json tier2-catalog.json rate-card.json rate-card.json.sig autotune-candidates.json \
      autotune-candidates.json.sig demand-rank.json demand-rank.json.sig; do
    install -m 0644 "$rel/$f" "$CH/macprovider/catalog-release/$f"
  done
}
e2e_canary_launchctl() { env E2E_CANARY_HOME="$CH" "$E2E_HARNESS/canary-bin/launchctl" "$@"; }
e2e_canary_start() { e2e_canary_launchctl bootstrap; }
e2e_canary_stop() { e2e_canary_launchctl bootout; }
e2e_canary_status() { curl -fsS --max-time 5 http://127.0.0.1:19191/v1/status; }
