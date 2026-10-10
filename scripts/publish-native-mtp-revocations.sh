#!/usr/bin/env bash
# Sign and publish the SPEC-023 §12.5 native-MTP emergency-revocation feed.
#
# The coordinator serves /v1/native-mtp-revocations.<key>.json(.sig) from
# `autotune.native_mtp_revocations_dir` (deployed as
# $REMOTE_REVOCATION_DIR/current, a symlink to one batch directory), choosing
# the newest issued, unexpired, correctly signed slot. This script signs a
# batch of slots OFF the coordinator host with the static-feed key, verifies
# it, uploads it as a new batch, and atomically retargets `current`.
#
# Two callers, both on demand (no schedule since #1938; providers keep the
# newest verified slot in force after it ages out):
#   - a feed restamp of a native-bound release (renew-autotune-static-feed.sh
#     --deploy);
#   - an operator emergency: add the admission-tuple identity to the revoked
#     source, run this with --deploy from the operator Mac, then commit the
#     source change. The new batch starts now, so every generation exceeds the
#     slot being served; providers adopt it within one 15-minute poll.
#
# Default is DRY-RUN (sign + verify locally, nothing uploaded).
#
# Env:
#   PEARL_SSH, PEARL_SSH_IDENTITY, PEARL_SSH_KNOWN_HOSTS  as renew-autotune-static-feed.sh
#   REMOTE_REVOCATION_DIR      remote root (default: /opt/macprovider/native-mtp-revocations)
#   AUTOTUNE_STATIC_KEY_ID     revocation signer key id (default: streamvc-autotune-static-v4);
#                              must equal the admission sidecar's revocation_signer_key_id
#   AUTOTUNE_STATIC_PRIVATE_KEY_PATH  raw base64 key file (default:
#                              ~/.config/macprovider/keys/autotune-static-<ver>.private.base64)
#   NATIVE_MTP_REVOKED_SOURCE  revoked set (default: phase3-binary/catalog/autotune/native-mtp-revocations-source.json)
#   NATIVE_MTP_REVOCATION_DAYS slot coverage in days (default: 14)
#   NATIVE_MTP_REVOCATION_KEEP batches retained on the host (default: 3)

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

log()   { printf '[native-mtp-revocations] %s\n' "$*"; }
fatal() { printf '[native-mtp-revocations] ERROR: %s\n' "$*" >&2; exit 1; }

DEPLOY=0
[ "${1:-}" = "--deploy" ] && DEPLOY=1

PEARL_SSH="${PEARL_SSH:-pearl}"
REMOTE_REVOCATION_DIR="${REMOTE_REVOCATION_DIR:-/opt/macprovider/native-mtp-revocations}"
KEY_ID="${AUTOTUNE_STATIC_KEY_ID:-streamvc-autotune-static-v4}"
KEY_VERSION="${KEY_ID##*-}"
KEY_PATH="${AUTOTUNE_STATIC_PRIVATE_KEY_PATH:-$HOME/.config/macprovider/keys/autotune-static-${KEY_VERSION}.private.base64}"
REVOKED_SOURCE="${NATIVE_MTP_REVOKED_SOURCE:-$REPO_ROOT/phase3-binary/catalog/autotune/native-mtp-revocations-source.json}"
DAYS="${NATIVE_MTP_REVOCATION_DAYS:-14}"
KEEP="${NATIVE_MTP_REVOCATION_KEEP:-3}"

case "$REMOTE_REVOCATION_DIR" in ""|*[!A-Za-z0-9._/-]*) fatal "unsafe REMOTE_REVOCATION_DIR" ;; esac
case "$PEARL_SSH" in ""|*[!A-Za-z0-9._@-]*) fatal "unsafe PEARL_SSH" ;; esac
case "$KEY_ID" in ""|*[!A-Za-z0-9._-]*) fatal "unsafe AUTOTUNE_STATIC_KEY_ID" ;; esac
case "$DAYS" in ""|*[!0-9]*) fatal "NATIVE_MTP_REVOCATION_DAYS must be a positive integer" ;; esac
case "$KEEP" in ""|*[!0-9]*|0) fatal "NATIVE_MTP_REVOCATION_KEEP must be a positive integer" ;; esac
[ "$DAYS" -ge 14 ] || fatal "NATIVE_MTP_REVOCATION_DAYS must cover at least 14 days"
[ -f "$KEY_PATH" ] || fatal "signing key file not found (path not printed)"
[ -f "$REVOKED_SOURCE" ] || fatal "revoked source not found: $REVOKED_SOURCE"

PUBLIC_KEY="$(python3 - "$REPO_ROOT/phase3-binary/catalog/autotune/trusted-keys.json" "$KEY_ID" <<'PY'
import json, sys
keys = json.load(open(sys.argv[1]))["keys"]
print(keys[sys.argv[2]]["public_key_base64"])
PY
)" || fatal "key id $KEY_ID is not in the trusted keyring"

STAGING="$(umask 077 && mktemp -d -t macprovider-native-mtp-revocations.XXXXXXXX)"
trap 'rm -rf "$STAGING"' EXIT
# One second ahead of now, so the first new generation is strictly above the
# slot being served even when it was issued this very second.
START="$(python3 -c 'import datetime; print((datetime.datetime.now(datetime.timezone.utc) + datetime.timedelta(seconds=1)).strftime("%Y-%m-%dT%H:%M:%SZ"))')"
BATCH="batch-$(printf '%s' "$START" | tr -d ':-')"
OUT="$STAGING/$BATCH"

python3 "$SCRIPT_DIR/native_mtp_revocation_slots.py" build \
  --key-file "$KEY_PATH" --key-id "$KEY_ID" --revoked "$REVOKED_SOURCE" \
  --start "$START" --days "$DAYS" --out "$OUT"
python3 "$SCRIPT_DIR/native_mtp_revocation_slots.py" verify \
  --dir "$OUT" --key-id "$KEY_ID" --public-key-base64 "$PUBLIC_KEY"

if [ "$DEPLOY" -eq 0 ]; then
  log "DRY-RUN complete: $BATCH signed and verified ($DAYS days from $START); nothing uploaded"
  exit 0
fi

SSH_OPTS=(-o ConnectTimeout=15 -o BatchMode=yes)
if [ -n "${PEARL_SSH_IDENTITY:-}" ]; then
  case "$PEARL_SSH_IDENTITY" in *[!A-Za-z0-9._/+=@-]*) fatal "unsafe PEARL_SSH_IDENTITY path" ;; esac
  PEARL_SSH_KNOWN_HOSTS="${PEARL_SSH_KNOWN_HOSTS:-$SCRIPT_DIR/dist/malibu-download-known_hosts}"
  case "$PEARL_SSH_KNOWN_HOSTS" in *[!A-Za-z0-9._/+=@-]*) fatal "unsafe PEARL_SSH_KNOWN_HOSTS path" ;; esac
  SSH_OPTS+=(-i "$PEARL_SSH_IDENTITY" -o IdentitiesOnly=yes -o "UserKnownHostsFile=$PEARL_SSH_KNOWN_HOSTS" -o StrictHostKeyChecking=yes -p 22)
fi
RSYNC_RSH="ssh"
for opt in "${SSH_OPTS[@]}"; do RSYNC_RSH="$RSYNC_RSH $opt"; done

log "uploading $BATCH to $PEARL_SSH:$REMOTE_REVOCATION_DIR/batches/"
ssh "${SSH_OPTS[@]}" "$PEARL_SSH" "mkdir -p '$REMOTE_REVOCATION_DIR/batches'"
rsync -e "$RSYNC_RSH" -a "$OUT/" "$PEARL_SSH:$REMOTE_REVOCATION_DIR/batches/.incoming-$BATCH/"
# Rename into place, then retarget `current` with one atomic rename of a
# fresh symlink; the coordinator rescans within 10 s. Keep the newest KEEP
# batches (the live one included) as rollback points.
ssh "${SSH_OPTS[@]}" "$PEARL_SSH" "set -e
  cd '$REMOTE_REVOCATION_DIR'
  mv 'batches/.incoming-$BATCH' 'batches/$BATCH'
  ln -sfn 'batches/$BATCH' '.current.tmp'
  mv -T '.current.tmp' 'current'
  ls -1d batches/batch-* | sort | head -n -$KEEP | xargs -r rm -rf"
log "published $BATCH as $REMOTE_REVOCATION_DIR/current ($DAYS days of slots from $START)"
