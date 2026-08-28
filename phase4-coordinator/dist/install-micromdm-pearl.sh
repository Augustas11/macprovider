#!/usr/bin/env bash
# install-micromdm-pearl.sh — install MicroMDM on Pearl behind coordinator nginx.
#
# Idempotent. Does NOT restart the coordinator. Does NOT overwrite live nginx
# unless --apply-nginx is passed (prefers deploying nginx via the normal Pearl
# deploy that installs dist/nginx-coordinator.malibu.tech.conf).
#
# Prerequisites:
#   - SSH as root to Pearl (same key as deploy-pearl-vps.sh)
#   - MDM APNs push cert + matching private key available locally
#
# Usage (from repo root or this directory):
#   bash phase4-coordinator/dist/install-micromdm-pearl.sh \
#     --push-cert ~/Secrets/macprovider-mdm-apns/MDM_push_certificate.pem \
#     --push-key  ~/Secrets/macprovider-mdm-apns/mdmcert.download.push.key \
#     --push-key-password-file ~/Secrets/macprovider-mdm-apns/.push-password
#
# Environment:
#   SSH_KEY   default: ~/.ssh/pearl_operator_ed25519
#   VPS_HOST  default: 159.223.165.194
#   VPS_USER  default: root
#   DOMAIN    default: coordinator.malibu.tech
#   MICROMDM_VERSION default: v1.13.1

set -euo pipefail

SSH_KEY="${SSH_KEY:-$HOME/.ssh/pearl_operator_ed25519}"
VPS_HOST="${VPS_HOST:-159.223.165.194}"
VPS_USER="${VPS_USER:-root}"
DOMAIN="${DOMAIN:-coordinator.malibu.tech}"
MICROMDM_VERSION="${MICROMDM_VERSION:-v1.13.1}"
SERVER_URL="https://${DOMAIN}"

PUSH_CERT=""
PUSH_KEY=""
PUSH_KEY_PASSWORD_FILE=""
APPLY_NGINX=0
SKIP_APNS_UPLOAD=0

usage() {
  sed -n '2,25p' "$0" | sed 's/^# \{0,1\}//'
  exit 2
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --push-cert) PUSH_CERT="$2"; shift 2 ;;
    --push-key) PUSH_KEY="$2"; shift 2 ;;
    --push-key-password-file) PUSH_KEY_PASSWORD_FILE="$2"; shift 2 ;;
    --apply-nginx) APPLY_NGINX=1; shift ;;
    --skip-apns-upload) SKIP_APNS_UPLOAD=1; shift ;;
    -h|--help) usage ;;
    *) echo "unknown arg: $1" >&2; usage ;;
  esac
done

if [[ -z "$PUSH_CERT" || -z "$PUSH_KEY" ]]; then
  echo "error: --push-cert and --push-key are required" >&2
  exit 1
fi
[[ -f "$PUSH_CERT" ]] || { echo "missing cert: $PUSH_CERT" >&2; exit 1; }
[[ -f "$PUSH_KEY" ]] || { echo "missing key: $PUSH_KEY" >&2; exit 1; }

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
UNIT_SRC="$SCRIPT_DIR/systemd/micromdm.service"
NGINX_SRC="$SCRIPT_DIR/nginx-coordinator.malibu.tech.conf"
[[ -f "$UNIT_SRC" ]] || { echo "missing unit: $UNIT_SRC" >&2; exit 1; }

SSH=(ssh -i "$SSH_KEY" -o ConnectTimeout=10 -o BatchMode=yes -p 22 "$VPS_USER@$VPS_HOST")
SCP=(scp -i "$SSH_KEY" -o ConnectTimeout=10 -o BatchMode=yes -P 22)

log() { printf '[micromdm-install] %s\n' "$*"; }

# Generate or reuse API key on Pearl.
log "ensuring API key + directories on Pearl"
"${SSH[@]}" bash -s <<'REMOTE'
set -euo pipefail
install -d -m 0755 /opt/micromdm/bin
install -d -m 0700 /var/lib/micromdm
install -d -m 0700 /var/lib/micromdm/repo
install -d -m 0700 /etc/micromdm
install -d -m 0700 /etc/micromdm/apns
if [[ ! -f /etc/micromdm/api-key ]]; then
  umask 077
  openssl rand -hex 32 > /etc/micromdm/api-key
  chmod 600 /etc/micromdm/api-key
fi
if [[ ! -f /etc/micromdm/env ]]; then
  umask 077
  cat > /etc/micromdm/env <<EOF
MICROMDM_API_KEY=$(cat /etc/micromdm/api-key)
EOF
  chmod 600 /etc/micromdm/env
fi
REMOTE

WORKDIR="$(mktemp -d "${TMPDIR:-/tmp}/micromdm-pearl.XXXXXX")"
cleanup() { rm -rf "$WORKDIR"; }
trap cleanup EXIT

log "downloading MicroMDM ${MICROMDM_VERSION}"
curl -fsSL -o "$WORKDIR/micromdm.zip" \
  "https://github.com/micromdm/micromdm/releases/download/${MICROMDM_VERSION}/micromdm_${MICROMDM_VERSION}.zip"
unzip -qo "$WORKDIR/micromdm.zip" -d "$WORKDIR/extract"
install -m 0755 "$WORKDIR/extract/build/linux/micromdm" "$WORKDIR/micromdm"
install -m 0755 "$WORKDIR/extract/build/linux/mdmctl" "$WORKDIR/mdmctl"

log "installing binaries + unit"
install -m 0755 "$SCRIPT_DIR/systemd/micromdm-serve.sh" "$WORKDIR/micromdm-serve.sh"
"${SCP[@]}" "$WORKDIR/micromdm" "$WORKDIR/mdmctl" "$WORKDIR/micromdm-serve.sh" \
  "$VPS_USER@$VPS_HOST:/opt/micromdm/bin/"
"${SSH[@]}" 'chmod 0755 /opt/micromdm/bin/micromdm /opt/micromdm/bin/mdmctl /opt/micromdm/bin/micromdm-serve.sh'
"${SCP[@]}" "$UNIT_SRC" "$VPS_USER@$VPS_HOST:/etc/systemd/system/micromdm.service"


# Write server-url into a drop-in so DOMAIN is configurable without editing the unit in git.
"${SSH[@]}" bash -s -- "$SERVER_URL" <<'REMOTE'
set -euo pipefail
SERVER_URL="$1"
install -d -m 0755 /etc/systemd/system/micromdm.service.d
cat > /etc/systemd/system/micromdm.service.d/override.conf <<EOF
[Service]
Environment=MICROMDM_SERVER_URL=${SERVER_URL}
EOF
chmod 644 /etc/systemd/system/micromdm.service.d/override.conf
systemctl daemon-reload
systemctl enable micromdm.service
systemctl restart micromdm.service
systemctl --no-pager --full status micromdm.service | head -20
REMOTE

log "uploading APNs push cert + key"
"${SCP[@]}" "$PUSH_CERT" "$VPS_USER@$VPS_HOST:/etc/micromdm/apns/PushCertificate.pem"
"${SCP[@]}" "$PUSH_KEY" "$VPS_USER@$VPS_HOST:/etc/micromdm/apns/PushPrivateKey.key"
if [[ -n "$PUSH_KEY_PASSWORD_FILE" ]]; then
  [[ -f "$PUSH_KEY_PASSWORD_FILE" ]] || { echo "missing password file" >&2; exit 1; }
  "${SCP[@]}" "$PUSH_KEY_PASSWORD_FILE" "$VPS_USER@$VPS_HOST:/etc/micromdm/apns/PushPrivateKey.password"
  "${SSH[@]}" 'chmod 600 /etc/micromdm/apns/PushPrivateKey.password'
fi
"${SSH[@]}" 'chmod 600 /etc/micromdm/apns/PushCertificate.pem /etc/micromdm/apns/PushPrivateKey.key'

if [[ "$SKIP_APNS_UPLOAD" -eq 0 ]]; then
  log "configuring mdmctl + uploading push cert into MicroMDM"
  "${SSH[@]}" bash -s -- "$SERVER_URL" <<'REMOTE'
set -euo pipefail
SERVER_URL="$1"
API_KEY="$(cat /etc/micromdm/api-key)"
export HOME=/root
install -d -m 0700 /root/.micromdm

# Prefer traditional RSA PEM for mdmctl (rejects PKCS#8).
KEY_UPLOAD=/etc/micromdm/apns/PushPrivateKey.rsa.pem
if [[ -f /etc/micromdm/apns/PushPrivateKey.password ]]; then
  openssl rsa \
    -in /etc/micromdm/apns/PushPrivateKey.key \
    -passin file:/etc/micromdm/apns/PushPrivateKey.password \
    -traditional \
    -out "$KEY_UPLOAD"
else
  openssl rsa -in /etc/micromdm/apns/PushPrivateKey.key -traditional -out "$KEY_UPLOAD"
fi
chmod 600 "$KEY_UPLOAD"

/opt/micromdm/bin/mdmctl config set \
  -name pearl \
  -server-url "http://127.0.0.1:8080" \
  -api-token "$API_KEY"
/opt/micromdm/bin/mdmctl config switch -name pearl
/opt/micromdm/bin/mdmctl mdmcert upload \
  -cert /etc/micromdm/apns/PushCertificate.pem \
  -private-key "$KEY_UPLOAD"
echo "APNs push certificate uploaded"
REMOTE
fi

if [[ "$APPLY_NGINX" -eq 1 ]]; then
  log "installing nginx site from tracked dist (nginx -t && reload)"
  [[ -f "$NGINX_SRC" ]] || { echo "missing nginx conf: $NGINX_SRC" >&2; exit 1; }
  "${SCP[@]}" "$NGINX_SRC" "$VPS_USER@$VPS_HOST:/etc/nginx/sites-available/coordinator.malibu.tech"
  "${SSH[@]}" 'nginx -t && systemctl reload nginx'
fi

log "smoke: local MicroMDM version + public scep/mdm path presence"
"${SSH[@]}" bash -s <<'REMOTE'
set -euo pipefail
curl -fsS -o /dev/null -w 'local_version_http=%{http_code}\n' http://127.0.0.1:8080/version || true
ss -lntp | grep -E ':8080\b' || { echo 'micromdm not listening on 8080' >&2; exit 1; }
REMOTE

log "done. Next:"
log "  1) Ensure nginx has /v1/enroll + /mdm/ + /scep (deploy or --apply-nginx)"
log "  2) Set tier2.mdm in /etc/macprovider/coordinator.pearl-overlays.yaml and restart coordinator"
log "  3) POST /v1/enroll smoke + malibu-cli enroll on a test Mac"
