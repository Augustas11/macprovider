#!/usr/bin/env bash
# Shared OpenSSH options for Malibu download.malibu.tech Pearl uploads.
# Source after SSH_KEY, VPS_USER, VPS_HOST, and SCRIPT_DIR are set.
#
# Optional overrides:
#   MALIBU_DOWNLOAD_KNOWN_HOSTS — path to pinned known_hosts file
#   MALIBU_DOWNLOAD_SSH_CONNECT_TIMEOUT — seconds (default 15)

: "${SCRIPT_DIR:?SCRIPT_DIR must be set before sourcing malibu-download-ssh.sh}"
: "${SSH_KEY:?SSH_KEY must be set before sourcing malibu-download-ssh.sh}"
: "${VPS_USER:?VPS_USER must be set before sourcing malibu-download-ssh.sh}"
: "${VPS_HOST:?VPS_HOST must be set before sourcing malibu-download-ssh.sh}"

MALIBU_DOWNLOAD_KNOWN_HOSTS="${MALIBU_DOWNLOAD_KNOWN_HOSTS:-$SCRIPT_DIR/dist/malibu-download-known_hosts}"
MALIBU_DOWNLOAD_SSH_CONNECT_TIMEOUT="${MALIBU_DOWNLOAD_SSH_CONNECT_TIMEOUT:-15}"

if [[ ! -f "$MALIBU_DOWNLOAD_KNOWN_HOSTS" ]]; then
  printf '[malibu-download-ssh] ERROR: missing known_hosts: %s\n' "$MALIBU_DOWNLOAD_KNOWN_HOSTS" >&2
  return 1 2>/dev/null || exit 1
fi

malibu_download_ssh() {
  ssh \
    -i "$SSH_KEY" \
    -o "ConnectTimeout=$MALIBU_DOWNLOAD_SSH_CONNECT_TIMEOUT" \
    -o "UserKnownHostsFile=$MALIBU_DOWNLOAD_KNOWN_HOSTS" \
    -o StrictHostKeyChecking=yes \
    -p 22 \
    "$VPS_USER@$VPS_HOST" \
    "$@"
}

malibu_download_scp() {
  scp \
    -i "$SSH_KEY" \
    -o "ConnectTimeout=$MALIBU_DOWNLOAD_SSH_CONNECT_TIMEOUT" \
    -o "UserKnownHostsFile=$MALIBU_DOWNLOAD_KNOWN_HOSTS" \
    -o StrictHostKeyChecking=yes \
    -P 22 \
    "$@"
}
