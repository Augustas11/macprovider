#!/usr/bin/env bash
# Tier E2 step 4: seed the "pre-#1693 live" state with the REAL deploy script of
# the pre-#1693 tag ($E2E_TAG_PRE = v1.8.191 + test identities): coordinator
# binary, units, nginx, the signed test release A (bootstrap activation), then
# fake providers + the canary stand-in serving and a buyer key paying.
set -euo pipefail
. "$(dirname "$0")/env.sh"
. "$E2E_HARNESS/lib/common.sh"
. "$E2E_HARNESS/lib/canary.sh"
e2e_write_ssh_config
e2e_checkout "$E2E_TAG_PRE"
e2e_tunnel_up
e2e_push_tools
e2e_tables_add A "$E2E_TAG_PRE"

# Canary stand-in on release A (the tag's release files).
rel="$(mktemp -d)"
for f in release.json trusted-keys.json tier2-catalog.json; do git -C "$E2E_REPO" show "$E2E_TAG_PRE:phase3-binary/catalog/autotune/$f" >"$rel/$f"; done
for f in rate-card.json rate-card.json.sig autotune-candidates.json autotune-candidates.json.sig demand-rank.json demand-rank.json.sig; do
  git -C "$E2E_REPO" show "$E2E_TAG_PRE:phase3-binary/dist/static/$f" >"$rel/$f"
done
e2e_canary_stop || true
e2e_canary_install "$rel"
rm -rf "$rel"
e2e_canary_start
vm "systemctl enable --now e2e-fakeprov@1 e2e-fakeprov@2 >/dev/null 2>&1"

bash "$E2E_HARNESS/lib/install-runtime-pair.sh" "$E2E_TAG_PRE"
e2e_log "running the pre-#1693 deploy-pearl-vps.sh ($E2E_TAG_PRE)"
rc=0
e2e_run_logged 3600 "$E2E_LOGS/deploy-pre.log" \
  bash -c "cd '$E2E_REPO' && . '$E2E_HARNESS/env.sh' && . '$E2E_HARNESS/lib/common.sh' && e2e_lane_env && bash phase4-coordinator/dist/deploy-pearl-vps.sh" || rc=$?
tail -5 "$E2E_LOGS/deploy-pre.log"
[ "$rc" = 0 ] || e2e_die "pre-#1693 deploy failed rc=$rc (log: $E2E_LOGS/deploy-pre.log)"
vm "curl -fsS http://127.0.0.1:8443/healthz; echo; cat /run/macprovider/coordinator-applied-config.json; echo"
e2e_log "pre-#1693 world live"
