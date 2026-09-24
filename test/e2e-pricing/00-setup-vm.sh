#!/usr/bin/env bash
# Tier E2 step 0: create/start the "fake Pearl" Lima VM and give it the Pearl
# host shape the operator lane and deploy-pearl-vps.sh assume:
#   - root SSH (test key), pinned host key
#   - packages Pearl has (nginx, sqlite3, python3, postgresql, certbot, acl, ...)
#   - `macprovider` system user, /opt/macprovider, /etc/macprovider, /var/lib/macprovider
#   - test-CA TLS certs at the Let's Encrypt paths for coordinator/stats.malibu.tech
#   - Postgres roles/dbs for the stats + onboarding DSNs
# Idempotent. Never touches the macprovider-540 VM or any production host.
set -euo pipefail
. "$(dirname "$0")/env.sh"

LIMA_YAML="$E2E_HARNESS/lima-macprovider-1693.yaml"
if ! limactl list -q | grep -qx "$E2E_VM"; then
  e2e_log "creating VM $E2E_VM"
  limactl create --name="$E2E_VM" --tty=false "$LIMA_YAML"
fi
if [ "$(limactl list "$E2E_VM" --format '{{.Status}}')" != Running ]; then
  e2e_log "starting VM $E2E_VM"
  limactl start "$E2E_VM" --timeout 20m
fi

# ---- test keys (never operator keys) ---------------------------------------
mkdir -p "$E2E_KEYS"; chmod 700 "$E2E_KEYS"
[ -f "$E2E_KEYS/pearl_root_ed25519" ] || ssh-keygen -q -t ed25519 -N '' -C e2e-pearl-root -f "$E2E_KEYS/pearl_root_ed25519"
[ -f "$E2E_KEYS/canary_ed25519" ] || ssh-keygen -q -t ed25519 -N '' -C e2e-canary -f "$E2E_KEYS/canary_ed25519"
[ -f "$E2E_KEYS/tag_signing_ed25519" ] || ssh-keygen -q -t ed25519 -N '' -C e2e@test.invalid -f "$E2E_KEYS/tag_signing_ed25519"
# autotune static-feed key: raw 32-byte Ed25519 seed, base64 (resign-autotune-static.sh format)
if [ ! -f "$E2E_KEYS/autotune.private.base64" ]; then
  openssl genpkey -algorithm ed25519 -outform DER 2>/dev/null | tail -c 32 | base64 >"$E2E_KEYS/autotune.private.base64"
  chmod 600 "$E2E_KEYS/autotune.private.base64"
fi
python3 - "$E2E_KEYS/autotune.private.base64" "$E2E_KEYS/autotune.public.base64" <<'PY'
import base64, subprocess, sys
seed = base64.b64decode(open(sys.argv[1]).read().strip())
der = bytes.fromhex("302e020100300506032b657004220420") + seed
pub = subprocess.run(["openssl", "pkey", "-inform", "DER", "-pubout", "-outform", "DER"], input=der,
                     capture_output=True, check=True).stdout[-32:]
open(sys.argv[2], "w").write(base64.b64encode(pub).decode() + "\n")
PY
# Tier-2 catalog key (sign-catalog.go keygen format)
if [ ! -f "$E2E_KEYS/tier2.priv" ]; then
  (cd "$E2E_SRC_REPO" && go run scripts/sign-catalog.go keygen -public-out "$E2E_KEYS/tier2.pub" -private-out "$E2E_KEYS/tier2.priv")
fi
# Pearl runtime release signing key (P-256, as ops/pearl-updater/release-signing-public.pem)
[ -f "$E2E_KEYS/release-signing.key" ] || { openssl genpkey -algorithm EC -pkeyopt ec_paramgen_curve:P-256 -out "$E2E_KEYS/release-signing.key" 2>/dev/null; chmod 600 "$E2E_KEYS/release-signing.key"; }
# Test CA + server cert for the malibu.tech names (nginx on the VM)
if [ ! -f "$E2E_KEYS/ca.pem" ]; then
  openssl req -x509 -newkey ec -pkeyopt ec_paramgen_curve:prime256v1 -nodes -days 3650 -subj "/CN=macprovider e2e test CA" \
    -keyout "$E2E_KEYS/ca.key" -out "$E2E_KEYS/ca.pem" 2>/dev/null
  openssl req -newkey ec -pkeyopt ec_paramgen_curve:prime256v1 -nodes -subj "/CN=coordinator.malibu.tech" \
    -keyout "$E2E_KEYS/server.key" -out "$E2E_KEYS/server.csr" 2>/dev/null
  printf 'subjectAltName=DNS:coordinator.malibu.tech,DNS:stats.malibu.tech,DNS:api.malibu.tech\n' >"$E2E_KEYS/san.ext"
  openssl x509 -req -in "$E2E_KEYS/server.csr" -CA "$E2E_KEYS/ca.pem" -CAkey "$E2E_KEYS/ca.key" -CAcreateserial \
    -days 825 -extfile "$E2E_KEYS/san.ext" -out "$E2E_KEYS/server.pem" 2>/dev/null
fi
# 64-hex operator key / service tokens for the test coordinator (never printed)
for n in operator_key gateway_service_token key_hash_secret; do
  [ -f "$E2E_KEYS/$n" ] || { openssl rand -hex 32 >"$E2E_KEYS/$n"; chmod 600 "$E2E_KEYS/$n"; }
done

# ---- root SSH + pinned host key --------------------------------------------
pub="$(cat "$E2E_KEYS/pearl_root_ed25519.pub")"
limactl shell "$E2E_VM" -- sudo bash -c "install -d -m 700 /root/.ssh && touch /root/.ssh/authorized_keys && chmod 600 /root/.ssh/authorized_keys && grep -qxF '$pub' /root/.ssh/authorized_keys || echo '$pub' >> /root/.ssh/authorized_keys"
hostkey="$(limactl shell "$E2E_VM" -- sudo cat /etc/ssh/ssh_host_ed25519_key.pub | awk '{print $1" "$2}')"
printf '%s %s\n' "$E2E_PEARL" "$hostkey" >"$E2E_KEYS/known_hosts"
e2e_write_ssh_config
vm true || e2e_die "root SSH to the VM failed"
e2e_log "root SSH ok"

# ---- packages and the Pearl layout -----------------------------------------
vm_script <<'SH'
set -euo pipefail
export DEBIAN_FRONTEND=noninteractive
need=""
for p in nginx sqlite3 python3 postgresql postgresql-client acl curl jq openssl libdigest-sha-perl util-linux certbot python3-certbot-nginx dnsutils rsync golang-go; do
  dpkg -s "$p" >/dev/null 2>&1 || need="$need $p"
done
if [ -n "$need" ]; then
  apt-get update -qq
  apt-get install -qq -y $need >/dev/null
fi
# catalog-release.py looks for go at fixed paths (FIXED_GO_EXECUTABLES)
[ -e /usr/local/bin/go ] || ln -s /usr/lib/go/bin/go /usr/local/bin/go
getent group macprovider >/dev/null || groupadd --system macprovider
id macprovider >/dev/null 2>&1 || useradd --system --gid macprovider --home-dir /var/lib/macprovider --shell /usr/sbin/nologin macprovider
install -d -o root -g root -m 0755 /opt/macprovider
install -d -o root -g macprovider -m 0750 /etc/macprovider
install -d -o macprovider -g macprovider -m 0750 /var/lib/macprovider
timedatectl set-timezone UTC || true
# Pearl's nginx proxy_cache root (the stats vhost declares /var/cache/nginx/stats).
install -d -o www-data -g www-data -m 0750 /var/cache/nginx
SH
# Warm root's Go build cache: catalog-release.py verifies Tier-2 signatures with
# `go run scripts/sign-catalog.go` under a 60 s timeout, and a cold std-lib
# build under qemu TCG exceeds it (seen as "signature verification timed out").
/usr/bin/ssh -F "$E2E_SSH_CONFIG" "$E2E_PEARL" 'mkdir -p /tmp/e2e-go-warm && cat > /tmp/e2e-go-warm/sign-catalog.go && cd /tmp/e2e-go-warm && go run sign-catalog.go >/dev/null 2>&1; rm -rf /tmp/e2e-go-warm' <"$E2E_SRC_REPO/scripts/sign-catalog.go"
# TLS at the Let's Encrypt live paths (the deploy classifies these as present)
for d in coordinator.malibu.tech stats.malibu.tech; do
  vm "install -d -m 0755 /etc/letsencrypt/live/$d"
  /usr/bin/scp -F "$E2E_SSH_CONFIG" -q "$E2E_KEYS/server.pem" "$E2E_PEARL:/etc/letsencrypt/live/$d/fullchain.pem"
  /usr/bin/scp -F "$E2E_SSH_CONFIG" -q "$E2E_KEYS/server.key" "$E2E_PEARL:/etc/letsencrypt/live/$d/privkey.pem"
  vm "chmod 0600 /etc/letsencrypt/live/$d/privkey.pem; cp /etc/letsencrypt/live/$d/fullchain.pem /etc/letsencrypt/live/$d/cert.pem"
done
e2e_log "VM ready: $(vm 'uname -m; python3 --version; sqlite3 --version | cut -d" " -f1' | tr '\n' ' ')"
