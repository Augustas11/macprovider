#!/usr/bin/env bash
# Renew the signed SPEC-023 autotune static feed WITHOUT changing its content —
# a freshness re-stamp that clears the client 30-day freshness horizon
# (AutotuneRecommend.swift loadSignedStatic: now - generated_at > 30d fails
# closed and strands any provider that restarts). Since #1268 the coordinator
# hot-reloads the feed on SIGHUP, so this deploys with ZERO provider disruption:
# no coordinator restart, every provider WebSocket stays connected.
#
# SIGNING STAYS OFF THE PRODUCTION HOST. The Ed25519 feed-signing key is the
# thing that protects clients from a compromised coordinator serving forged
# feeds; putting it on Pearl would defeat that. This script signs locally (where
# the key lives), pushes only signed bytes to Pearl, and does the symlink swap +
# SIGHUP over SSH.
#
# Default is DRY-RUN: build + verify a re-dated release locally and stop. Pass
# --deploy to push to the coordinator host. --deploy is fail-closed and atomic,
# and rolls the `current` symlink back (and re-HUPs) if the post-reload health
# check regresses.
#
# Usage:
#   scripts/renew-autotune-static-feed.sh              # build + verify only
#   scripts/renew-autotune-static-feed.sh --deploy     # build, verify, deploy, HUP, verify live
#
# Env:
#   PEARL_SSH                ssh target for the coordinator host (default: pearl)
#   REMOTE_AUTOTUNE_DIR      remote autotune root (default: /opt/macprovider/autotune)
#   COORDINATOR_UNIT         systemd unit name (default: macprovider-coordinator)
#   COORDINATOR_HEALTH_URL   URL that returns the served rate-card (default: https://coordinator.malibu.tech/v1/rate-card)
#   AUTOTUNE_STATIC_KEY_ID   signing key id (default: streamvc-autotune-static-v4)
#   AUTOTUNE_STATIC_PRIVATE_KEY_PATH  override key path (default: ~/.config/macprovider/keys/autotune-static-<ver>.private.base64)
#   RELEASE_ID_PREFIX        version prefix (default: published)
#   RELEASE_ID_SUFFIX        version suffix (default: inband-provenance-v1)

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

PEARL_SSH="${PEARL_SSH:-pearl}"
REMOTE_AUTOTUNE_DIR="${REMOTE_AUTOTUNE_DIR:-/opt/macprovider/autotune}"
COORDINATOR_UNIT="${COORDINATOR_UNIT:-macprovider-coordinator}"
COORDINATOR_HEALTH_URL="${COORDINATOR_HEALTH_URL:-https://coordinator.malibu.tech/v1/rate-card}"
KEY_ID="${AUTOTUNE_STATIC_KEY_ID:-streamvc-autotune-static-v4}"
RELEASE_ID_PREFIX="${RELEASE_ID_PREFIX:-published}"
RELEASE_ID_SUFFIX="${RELEASE_ID_SUFFIX:-inband-provenance-v1}"

DEPLOY=0
[ "${1:-}" = "--deploy" ] && DEPLOY=1

WORKTREE=""
STAGING=""
LOCK_HELD=""

log()   { printf '[renew-autotune] %s\n' "$*"; }
fatal() { printf '[renew-autotune] ERROR: %s\n' "$*" >&2; exit 1; }

cleanup() {
  local rc=$?
  # Release the remote publish lock if this run acquired it (MED-3).
  if [ -n "$LOCK_HELD" ]; then
    ssh -o ConnectTimeout=15 -o BatchMode=yes "$PEARL_SSH" \
      "rmdir '$REMOTE_AUTOTUNE_DIR/.renew.lock'" >/dev/null 2>&1 || true
  fi
  [ -n "$STAGING" ] && [ -d "$STAGING" ] && rm -rf "$STAGING"
  if [ -n "$WORKTREE" ] && [ -d "$WORKTREE" ]; then
    git -C "$REPO_ROOT" worktree remove --force "$WORKTREE" >/dev/null 2>&1 || rm -rf "$WORKTREE"
  fi
  exit $rc
}
trap cleanup EXIT

command -v git >/dev/null 2>&1     || fatal "git is required"
command -v python3 >/dev/null 2>&1 || fatal "python3 is required"
command -v swift >/dev/null 2>&1   || fatal "swift is required (Ed25519 signing)"

# ---------------------------------------------------------------------------
# 1. Build the re-dated, re-signed release in an EPHEMERAL worktree so this
#    never dirties the caller's checkout (generate/resign rewrite tracked feed
#    files, the Swift baked source, the manifest, and the release ledger).
# ---------------------------------------------------------------------------
NOW_ISO="$(python3 -c 'import datetime; print(datetime.datetime.now(datetime.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ"))')"
TODAY="$(python3 -c 'import datetime; print(datetime.datetime.now(datetime.timezone.utc).strftime("%Y-%m-%d"))')"
RELEASE_ID="${RELEASE_ID_PREFIX}-${TODAY}-${RELEASE_ID_SUFFIX}"

WORKTREE="$(mktemp -d -t macprovider-feed-renew.XXXXXXXX)"
rm -rf "$WORKTREE"
git -C "$REPO_ROOT" fetch --quiet origin
git -C "$REPO_ROOT" worktree add --quiet --detach "$WORKTREE" origin/main
log "built ephemeral worktree at $WORKTREE (origin/main $(git -C "$WORKTREE" rev-parse --short HEAD))"

CAT_DIR="$WORKTREE/phase3-binary/catalog/autotune"
STATIC_DIR="$WORKTREE/phase3-binary/dist/static"

# Re-stamp version + generated_at ONLY. Content is otherwise byte-identical:
# candidate/demand carry a published-<date> version; rate-card's version is a
# rows-hash and MUST NOT change on a freshness-only renewal.
python3 - "$CAT_DIR" "$RELEASE_ID" "$NOW_ISO" <<'PY'
import json, pathlib, sys
cat_dir, release_id, now_iso = pathlib.Path(sys.argv[1]), sys.argv[2], sys.argv[3]
for name in ("autotune-candidates.json", "demand-rank.json"):
    p = cat_dir / name
    obj = json.loads(p.read_text())
    obj["version"] = release_id
    obj["generated_at"] = now_iso
    p.write_text(json.dumps(obj, separators=(",", ":"), sort_keys=True))
rc = cat_dir / "rate-card.json"
obj = json.loads(rc.read_text())
# generated_at is a freshness field only. Pricing provenance is bound to the
# rate-card's CONTENT, not the whole file: the openrouter engine's
# rate_card_reference_digest and the pricing-receipt rate_card_content_sha256
# both canonicalize the card with generated_at excluded, so this freshness-only
# re-stamp is provenance-safe and does not invalidate any archived proposal or
# compute receipt. version is a rows-hash; leave it.
obj["generated_at"] = now_iso
rc.write_text(json.dumps(obj, separators=(",", ":"), sort_keys=True))
print(f"re-stamped candidate/demand version={release_id} generated_at={now_iso} (rate-card date only)")
PY

log "regenerating canonical feed + manifest + ledger for $RELEASE_ID"
( cd "$WORKTREE" && python3 scripts/catalog-release.py generate --signer-key-id "$KEY_ID" )

log "signing feed bytes with $KEY_ID (in-memory public-key derivation check; no bytes printed)"
( cd "$WORKTREE" && AUTOTUNE_STATIC_KEY_ID="$KEY_ID" bash scripts/resign-autotune-static.sh )

# ---------------------------------------------------------------------------
# 2. Assemble the 9-file release directory and gate it with verify-directory.
# ---------------------------------------------------------------------------
CANDIDATE_SHA="$(python3 -c 'import hashlib,sys;print(hashlib.sha256(open(sys.argv[1],"rb").read()).hexdigest())' "$CAT_DIR/autotune-candidates.json")"
RELEASE_DIRNAME="${RELEASE_ID}-${CANDIDATE_SHA:0:16}"

STAGING="$(mktemp -d -t macprovider-feed-stage.XXXXXXXX)"
RELEASE_STAGE="$STAGING/$RELEASE_DIRNAME"
mkdir -p "$RELEASE_STAGE"
for f in autotune-candidates.json demand-rank.json rate-card.json release.json tier2-catalog.json trusted-keys.json; do
  install -m 0644 "$CAT_DIR/$f" "$RELEASE_STAGE/$f"
done
for f in autotune-candidates.json.sig demand-rank.json.sig rate-card.json.sig; do
  install -m 0644 "$STATIC_DIR/$f" "$RELEASE_STAGE/$f"
done
# Strip any macOS AppleDouble junk before it can reach the release dir.
find "$RELEASE_STAGE" -name '._*' -delete 2>/dev/null || true

log "verifying assembled release directory"
( cd "$WORKTREE" && python3 scripts/catalog-release.py verify-directory --directory "$RELEASE_STAGE" )

log "built release ${RELEASE_DIRNAME}"
log "  candidate sha256 = ${CANDIDATE_SHA}"
log "  generated_at     = ${NOW_ISO}"
ls -1 "$RELEASE_STAGE"

if [ "$DEPLOY" -eq 0 ]; then
  log "DRY-RUN complete (no coordinator contact). Re-run with --deploy to publish."
  exit 0
fi

# ---------------------------------------------------------------------------
# 3. Deploy: push the signed dir, verify content continuity, atomically retarget
#    `current`, keep the prior release as `.previous-target`, SIGHUP, verify.
# ---------------------------------------------------------------------------
SSH() { ssh -o ConnectTimeout=15 -o BatchMode=yes "$PEARL_SSH" "$@"; }

# Allowlist every value interpolated into a remote shell string (MED-1). These are
# operator-supplied, but a stray quote must never reach the remote shell.
case "$REMOTE_AUTOTUNE_DIR" in ""|*[!A-Za-z0-9._/-]*) fatal "unsafe REMOTE_AUTOTUNE_DIR: $REMOTE_AUTOTUNE_DIR" ;; esac
case "$RELEASE_DIRNAME"     in ""|*[!A-Za-z0-9._-]*)  fatal "unsafe RELEASE_DIRNAME: $RELEASE_DIRNAME" ;; esac
case "$COORDINATOR_UNIT"    in ""|*[!A-Za-z0-9._@-]*) fatal "unsafe COORDINATOR_UNIT: $COORDINATOR_UNIT" ;; esac

log "deploy → $PEARL_SSH:$REMOTE_AUTOTUNE_DIR"

# Clock-skew guard (MED-4): generated_at was stamped from THIS host's clock. If it
# runs ahead of the coordinator host, clients reject the feed as future-dated
# (>10min ahead of the client clock). Abort before publishing anything.
REMOTE_EPOCH="$(SSH 'date -u +%s')" || fatal "cannot read remote clock"
LOCAL_EPOCH="$(date -u +%s)"
SKEW=$(( LOCAL_EPOCH - REMOTE_EPOCH ))
if [ "$SKEW" -gt 120 ] || [ "$SKEW" -lt -120 ]; then
  fatal "signing host clock is skewed ${SKEW}s vs $PEARL_SSH; refusing to publish a possibly future-dated feed"
fi

# Serialize publishes with an atomic remote lock (MED-3): mkdir fails if held.
if ! SSH "mkdir '$REMOTE_AUTOTUNE_DIR/.renew.lock'" 2>/dev/null; then
  fatal "another renewal holds $REMOTE_AUTOTUNE_DIR/.renew.lock; refusing to run concurrently"
fi
LOCK_HELD=1

# Capture BOTH the outgoing current target and the existing previous-target, so a
# rollback can restore the exact prior state (MED-2).
CURRENT_TARGET="$(SSH "readlink '$REMOTE_AUTOTUNE_DIR/current'")" || fatal "cannot read current symlink on $PEARL_SSH"
CURRENT_TARGET="${CURRENT_TARGET#./}"
[ -n "$CURRENT_TARGET" ] || fatal "empty current target"
ORIG_PREVIOUS_TARGET="$(SSH "cat '$REMOTE_AUTOTUNE_DIR/.previous-target' 2>/dev/null || true")"
ORIG_PREVIOUS_TARGET="${ORIG_PREVIOUS_TARGET//$'\n'/}"

# MED-1 (regression fix): CURRENT_TARGET and ORIG_PREVIOUS_TARGET are read from
# the remote host and later passed through `ssh ... bash -s -- ...`, where the
# remote shell re-parses argv. Validate their shape to exactly
# `releases/<single-segment>` (the coordinator parser's shape) so a crafted
# `current` symlink or `.previous-target` cannot inject remote shell. Empty is
# allowed ONLY for the previous-target.
validate_release_ref() {
  local value="$1" label="$2" allow_empty="$3"
  if [ -z "$value" ]; then
    [ "$allow_empty" = "empty_ok" ] && return 0
    fatal "empty $label"
  fi
  case "$value" in
    releases/*) ;;
    *) fatal "unexpected $label shape (want releases/<id>): $value" ;;
  esac
  local seg="${value#releases/}"
  case "$seg" in
    ""|*[!A-Za-z0-9._-]*) fatal "unsafe $label (single safe segment required): $value" ;;
  esac
}
validate_release_ref "$CURRENT_TARGET" "current target" "no_empty"
validate_release_ref "$ORIG_PREVIOUS_TARGET" "previous-target" "empty_ok"
log "current live release: $CURRENT_TARGET (prior previous-target: ${ORIG_PREVIOUS_TARGET:-<none>})"

# Refuse to publish a release id that already exists (idempotency / no clobber).
if SSH "test -e '$REMOTE_AUTOTUNE_DIR/releases/$RELEASE_DIRNAME'"; then
  fatal "release $RELEASE_DIRNAME already exists on $PEARL_SSH; nothing to do (already renewed with this content+timestamp)"
fi

# CONTENT-CONTINUITY GUARD: a renewal must change ONLY dates. Compare the new
# feed content (version/generated_at stripped) against the live release; abort
# if models, gates, or rate-card rows differ — a real catalog change must go
# through a reviewed release, never this freshness cron.
log "checking content continuity against the live release (freshness-only guard)"
for name in autotune-candidates.json demand-rank.json rate-card.json; do
  live="$(SSH "cat '$REMOTE_AUTOTUNE_DIR/current/$name'")" || fatal "cannot read live $name"
  if ! printf '%s' "$live" | python3 -c '
import json, sys
def norm(o):
    o = dict(o); o.pop("version", None); o.pop("generated_at", None); return json.dumps(o, sort_keys=True)
new = json.load(open(sys.argv[1]))
live = json.loads(sys.stdin.read())
sys.exit(0 if norm(new) == norm(live) else 1)
' "$RELEASE_STAGE/$name"; then
    fatal "content drift in $name vs live feed — renewal is freshness-only; a content change needs a reviewed catalog release, not this cron"
  fi
done
log "content continuity confirmed (dates-only delta)"

# Rollback restores the EXACT prior state — current AND .previous-target — then
# re-HUPs (HIGH-2, MED-2). Idempotent: if the deploy failed before mutating, this
# just rewrites current/previous-target to the values they already hold.
rollback() {
  log "ROLLBACK: restoring current -> $CURRENT_TARGET, .previous-target -> ${ORIG_PREVIOUS_TARGET:-<none>}, re-HUPing"
  SSH bash -s -- "$REMOTE_AUTOTUNE_DIR" "$CURRENT_TARGET" "$ORIG_PREVIOUS_TARGET" "$COORDINATOR_UNIT" <<'RB' || true
set -euo pipefail
root="$1"; cur="$2"; prev="$3"; unit="$4"
ln -sfn "$cur" "$root/.current.rollback"
mv -Tf "$root/.current.rollback" "$root/current"
if [ -n "$prev" ]; then printf '%s\n' "$prev" > "$root/.previous-target"; else rm -f "$root/.previous-target"; fi
pid="$(systemctl show -p MainPID --value "$unit")"
[ -n "$pid" ] && [ "$pid" != "0" ] && kill -HUP "$pid" || true
echo "rolled back to $cur"
RB
}

# Push the new release dir under a staging name first, then move into place.
REMOTE_TMP=".incoming-$RELEASE_DIRNAME.$$"
log "uploading signed release bytes"
rsync -e "ssh -o ConnectTimeout=15 -o BatchMode=yes" -a --delete \
  "$RELEASE_STAGE/" "$PEARL_SSH:$REMOTE_AUTOTUNE_DIR/releases/$REMOTE_TMP/" \
  || fatal "rsync failed"

# Remote publish. The coordinator PID is resolved FIRST so a missing daemon aborts
# BEFORE any mutation (HIGH-2). .previous-target is written verbatim — CURRENT_TARGET
# already carries the `releases/<id>` prefix, so it must NOT be re-prefixed (HIGH-1).
if ! SSH bash -s -- "$REMOTE_AUTOTUNE_DIR" "$REMOTE_TMP" "$RELEASE_DIRNAME" "$CURRENT_TARGET" "$COORDINATOR_UNIT" <<'REMOTE'
set -euo pipefail
root="$1"; incoming="$2"; final="$3"; prev="$4"; unit="$5"
# Resolve the reload target BEFORE mutating anything, so a dead daemon aborts clean.
pid="$(systemctl show -p MainPID --value "$unit")"
[ -n "$pid" ] && [ "$pid" != "0" ] || { echo "coordinator MainPID unavailable; not mutating" >&2; exit 1; }
cd "$root/releases"
chown -R root:macprovider "$incoming"
chmod 0750 "$incoming"; chmod 0640 "$incoming"/*
mv "$incoming" "$final"
# Record the outgoing release (verbatim; already prefixed) so the coordinator admits
# it as `previous` and already-joined nodes on it stay routable across the swap.
printf '%s\n' "$prev" > "$root/.previous-target"
# Atomic symlink swap: create the new link beside `current`, then rename over.
ln -sfn "releases/$final" "$root/.current.next"
mv -Tf "$root/.current.next" "$root/current"
echo "retargeted current -> releases/$final (previous-target=$prev)"
# SIGHUP the running coordinator: in-process config reload (#1268), NOT a restart.
kill -HUP "$pid"
echo "sent SIGHUP to $unit (pid $pid)"
REMOTE
then
  rollback
  fatal "remote publish failed"
fi

log "waiting for hot-reload to apply"
sleep 5

# ---------------------------------------------------------------------------
# 4. Verify THIS deploy activated (exact identity, not just freshness) and roll
#    back on any regression.
# ---------------------------------------------------------------------------
# HIGH-3: require the served generated_at to EXACTLY equal the timestamp this run
# stamped. A window-based freshness check could pass on a prior/concurrent feed
# that happens to be recent; an exact match proves the coordinator reloaded THIS
# release. generated_at is second-precision and unique to this run.
SERVED_JSON="$(curl -fsS --max-time 20 "$COORDINATOR_HEALTH_URL" 2>/dev/null)" || { rollback; fatal "served rate-card unreachable after reload"; }
if ! printf '%s' "$SERVED_JSON" | python3 -c '
import json, sys
expected = sys.argv[1]
served = json.loads(sys.stdin.read())
gen = served.get("generated_at", "")
ok = gen == expected
print(f"served generated_at={gen} (expected exactly {expected}) -> {\"OK\" if ok else \"MISMATCH\"}", file=sys.stderr)
sys.exit(0 if ok else 1)
' "$NOW_ISO"; then
  rollback
  fatal "served feed did not activate to this deploy (generated_at != ${NOW_ISO}) after SIGHUP"
fi

log "SUCCESS: coordinator now serving the renewed feed ${RELEASE_DIRNAME} (no restart, fleet undisturbed)."
log "previous release retained as .previous-target -> $CURRENT_TARGET"
