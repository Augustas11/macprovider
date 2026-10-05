#!/usr/bin/env bash
# Step 0 (host): start the fake-Pearl VM (created by test/e2e-1690/00-setup-vm.sh
# from test/e2e-1690/lima-macprovider-1690.yaml) and install what the #1816
# run needs on top of the #1690 package set. Idempotent.
set -euo pipefail
. "$(dirname "$0")/env.sh"
limactl list -q | grep -qx "$E2E_VM" || e2e_die "VM $E2E_VM does not exist; create it with test/e2e-1690/00-setup-vm.sh"
if [ "$(limactl list "$E2E_VM" --format '{{.Status}}')" != Running ]; then
  e2e_log "starting VM $E2E_VM"
  limactl start "$E2E_VM" --timeout 30m
fi
vm_script <<'SH'
set -euo pipefail
export DEBIAN_FRONTEND=noninteractive
need=""
for p in nginx sqlite3 python3 python3-yaml postgresql postgresql-client acl curl jq openssl git make golang-go rsync dnsutils openssh-server ca-certificates psmisc lsof util-linux perl; do
  dpkg -s "$p" >/dev/null 2>&1 || need="$need $p"
done
if [ -n "$need" ]; then apt-get update -qq; apt-get install -qq -y $need >/dev/null; fi
SH
e2e_log "VM $E2E_VM ready"
