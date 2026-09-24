#!/usr/bin/env bash
# Stand-in for `macprovider-pearl-update --apply --tag <tag>` (GAP, recorded):
# deploy-pearl-vps.sh never installs a coordinator binary itself ("refusing
# coordinator-only replacement: install the signed coordinator/gateway pair with
# macprovider-pearl-update first"), and the real updater's apply needs Better
# Stack deadman heartbeats, a canary-buyer service and Pearl->canary-Mac SSH that
# tier E2 cannot provide without touching real services. This installs exactly
# the signed pair from the tag's release stand-in (sha-checked against
# pearl-release.json), with the updater's ownership, then restarts the gateway.
# Usage: install-runtime-pair.sh <tag>
set -euo pipefail
. "$(dirname "$0")/../env.sh"
tag="$1"; rel="$E2E_WORK/gh-releases/$tag"
[ -f "$rel/pearl-release.json" ] || e2e_die "no release stand-in for $tag"
e2e_write_ssh_config
stage="$(mktemp -d)"; trap 'rm -rf "$stage"' EXIT
cp "$rel/pearl-release.json" "$rel/coordinator-linux-amd64" "$rel/coordinator-cli-linux-amd64" "$rel/gateway-linux-amd64" "$stage/"
# The stats sidecars ship as their own signed sidecar release; same stand-in.
cp "$E2E_WORK/bins/$tag"/stats-*-linux-amd64 "$stage/"
COPYFILE_DISABLE=1 tar -C "$stage" -cf - . |
  vm "rm -rf /root/e2e-pair && mkdir -m 700 /root/e2e-pair && tar -xf - -C /root/e2e-pair"
vm_script <<'SH'
set -euo pipefail
cd /root/e2e-pair
python3 - <<'PY'
import hashlib, json
m = json.load(open("pearl-release.json"))
for name, asset in (("coordinator", "coordinator-linux-amd64"), ("gateway", "gateway-linux-amd64")):
    assert hashlib.sha256(open(asset, "rb").read()).hexdigest() == m["components"][name]["sha256"], asset
assert hashlib.sha256(open("coordinator-cli-linux-amd64", "rb").read()).hexdigest() == m["operator_artifacts"]["coordinator_cli"]["sha256"]
PY
install -o root -g macprovider -m 0750 coordinator-linux-amd64 /opt/macprovider/coordinator.e2e-next
install -o root -g macprovider -m 0750 coordinator-cli-linux-amd64 /opt/macprovider/coordinator-cli.e2e-next
install -o root -g macprovider -m 0750 gateway-linux-amd64 /opt/macprovider/gateway.e2e-next
mv -Tf /opt/macprovider/coordinator.e2e-next /opt/macprovider/coordinator
mv -Tf /opt/macprovider/coordinator-cli.e2e-next /opt/macprovider/coordinator-cli
mv -Tf /opt/macprovider/gateway.e2e-next /opt/macprovider/gateway
getent group macprovider-stats >/dev/null || groupadd --system macprovider-stats
id macprovider-stats >/dev/null 2>&1 || useradd --system --gid macprovider-stats --home-dir /nonexistent --shell /usr/sbin/nologin --no-create-home macprovider-stats
install -d -o root -g macprovider-stats -m 0750 /opt/macprovider-stats
for s in stats-inventory-sync stats-billing-mirror stats-hardware-verifier; do
  install -o root -g macprovider-stats -m 0750 $s-linux-amd64 /opt/macprovider-stats/$s
done
systemctl restart macprovider-gateway
if systemctl cat macprovider-coordinator >/dev/null 2>&1 && systemctl is-active --quiet macprovider-coordinator; then
  systemctl restart macprovider-coordinator
fi
rm -rf /root/e2e-pair
SH
e2e_log "runtime pair $tag installed (updater stand-in)"
