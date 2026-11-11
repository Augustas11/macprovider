#!/usr/bin/env bash
# Step 0 (host): create/start the fake-Pearl VM from lima-macprovider-2084.yaml
# and install what Pearl has plus a Go toolchain (every build happens in the
# VM). Idempotent. A fresh VM for an acceptance run: E2E_FRESH_VM=1 deletes
# and recreates the instance first.
set -euo pipefail
. "$(dirname "$0")/env.sh"
if [ "${E2E_FRESH_VM:-0}" = 1 ] && limactl list -q | grep -qx "$E2E_VM"; then
  e2e_log "deleting VM $E2E_VM for a fresh run"
  limactl delete --force "$E2E_VM"
fi
if ! limactl list -q | grep -qx "$E2E_VM"; then
  e2e_log "creating VM $E2E_VM"
  limactl create --name="$E2E_VM" --tty=false "$E2E_HARNESS/lima-macprovider-2084.yaml"
fi
if [ "$(limactl list "$E2E_VM" --format '{{.Status}}')" != Running ]; then
  e2e_log "starting VM $E2E_VM"
  limactl start "$E2E_VM" --timeout 30m
fi
vm_script <<'SH'
set -euo pipefail
export DEBIAN_FRONTEND=noninteractive
need=""
for p in nginx sqlite3 python3 python3-yaml python3-nacl postgresql postgresql-client acl curl jq openssl git make golang-go rsync dnsutils openssh-server ca-certificates psmisc lsof util-linux perl; do
  dpkg -s "$p" >/dev/null 2>&1 || need="$need $p"
done
if [ -n "$need" ]; then apt-get update -qq; apt-get install -qq -y $need >/dev/null; fi
[ -e /usr/local/bin/go ] || ln -s /usr/lib/go/bin/go /usr/local/bin/go
timedatectl set-timezone UTC || true
getent group macprovider >/dev/null || groupadd --system macprovider
id macprovider >/dev/null 2>&1 || useradd --system --gid macprovider --home-dir /var/lib/macprovider --shell /usr/sbin/nologin macprovider
install -d -o root -g macprovider -m 0750 /opt/macprovider
install -d -o root -g macprovider -m 0750 /etc/macprovider
install -d -o macprovider -g macprovider -m 0750 /var/lib/macprovider /var/log/macprovider
install -d -m 0700 /root/e2e
go version
SH
e2e_log "VM $E2E_VM ready"
