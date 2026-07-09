#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SETUP="$ROOT/scripts/setup-malibu-download-pearl.sh"
PUBLISH="$ROOT/scripts/publish-malibu-latest-dmg.sh"
VERIFY="$ROOT/scripts/verify-malibu-download.sh"
SSH_HELPER="$ROOT/scripts/malibu-download-ssh.sh"
KNOWN_HOSTS="$ROOT/scripts/dist/malibu-download-known_hosts"
NGINX="$ROOT/scripts/dist/nginx-download.malibu.tech.conf"

fail() {
  echo "FAIL: $*" >&2
  exit 1
}

for f in "$SETUP" "$PUBLISH" "$VERIFY" "$SSH_HELPER"; do
  [[ -f "$f" ]] || fail "missing $f"
  bash -n "$f" || fail "bash -n $f"
done
[[ -f "$KNOWN_HOSTS" ]] || fail "missing $KNOWN_HOSTS"
[[ -f "$NGINX" ]] || fail "missing $NGINX"

grep -q 'malibu-download-known_hosts' "$SSH_HELPER" ||
  fail 'ssh helper should pin Pearl host key via known_hosts'

grep -q 'StrictHostKeyChecking=yes' "$SSH_HELPER" ||
  fail 'ssh helper should enforce StrictHostKeyChecking=yes'

grep -q 'setup-malibu-download-pearl.sh' "$PUBLISH" ||
  grep -q 'Pearl' "$PUBLISH" ||
  fail 'publish script should target Pearl VPS'

grep -q 'MALIBU_DOWNLOAD_WEBROOT' "$PUBLISH" ||
  fail 'publish script should use MALIBU_DOWNLOAD_WEBROOT'

grep -q 'appcast.xml' "$PUBLISH" ||
  fail 'publish script must upload appcast.xml'

grep -q 'name.com' "$SETUP" ||
  fail 'setup script should document name.com DNS'

grep -q 'malibu-download' "$NGINX" ||
  fail 'nginx config should serve /var/www/malibu-download'

grep -q "'/appcast.xml'" "$VERIFY" ||
  fail 'verify script should probe appcast.xml'

echo "PASS: malibu download publish scripts present"
