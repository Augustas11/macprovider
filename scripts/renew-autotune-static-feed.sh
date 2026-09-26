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
# the key lives — operator laptop or a production-release GitHub Actions runner),
# pushes only signed bytes to Pearl, and does the symlink swap + SIGHUP over SSH.
#
# Primary always-on signer: .github/workflows/renew-autotune-static-feed-signed.yml
# (Wednesday 16:00 UTC, production-release). This script is that job's deploy
# path and the laptop fallback. Do not install a Pearl systemd signer and do
# not install a laptop LaunchAgent as the SLA.
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
#   PEARL_SSH_IDENTITY       optional OpenSSH private-key file (CI deploy; 0600/0400)
#   PEARL_SSH_KNOWN_HOSTS    pinned known_hosts when PEARL_SSH_IDENTITY is set
#                            (default: scripts/dist/malibu-download-known_hosts)
#   REMOTE_AUTOTUNE_DIR      remote autotune root (default: /opt/macprovider/autotune)
#   COORDINATOR_UNIT         systemd unit name (default: macprovider-coordinator)
#   COORDINATOR_HEALTH_URL   URL that returns the served rate-card (default: https://coordinator.malibu.tech/v1/rate-card)
#   AUTOTUNE_STATIC_KEY_ID   signing key id (default: streamvc-autotune-static-v4)
#   AUTOTUNE_STATIC_PRIVATE_KEY_PATH  override key path (default: ~/.config/macprovider/keys/autotune-static-<ver>.private.base64)
#   OPENSSL_BIN              optional absolute OpenSSL 3 path (CI sealed bottle)
#   RELEASE_ID_PREFIX        version prefix (default: published)
#   RELEASE_ID_SUFFIX        version suffix (default: inband-provenance-v1)
#   GITHUB_SHA               when set (Actions), restamp that commit instead of origin/main

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

PEARL_SSH="${PEARL_SSH:-pearl}"
REMOTE_AUTOTUNE_DIR="${REMOTE_AUTOTUNE_DIR:-/opt/macprovider/autotune}"
# Allowlisted HERE, before any use in a remote shell string (the post-activation
# previous-release fetch below runs long before the deploy section's guards).
case "$REMOTE_AUTOTUNE_DIR" in ""|*[!A-Za-z0-9._/-]*) echo "unsafe REMOTE_AUTOTUNE_DIR: $REMOTE_AUTOTUNE_DIR" >&2; exit 1 ;; esac
COORDINATOR_UNIT="${COORDINATOR_UNIT:-macprovider-coordinator}"
COORDINATOR_HEALTH_URL="${COORDINATOR_HEALTH_URL:-https://coordinator.malibu.tech/v1/rate-card}"
KEY_ID="${AUTOTUNE_STATIC_KEY_ID:-streamvc-autotune-static-v4}"
RELEASE_ID_PREFIX="${RELEASE_ID_PREFIX:-published}"
RELEASE_ID_SUFFIX="${RELEASE_ID_SUFFIX:-inband-provenance-v1}"

DEPLOY=0
[ "${1:-}" = "--deploy" ] && DEPLOY=1

WORKTREE=""
PREVIOUS_RELEASE_DIR=""
STAGING=""
LOCK_HELD=""
LOCK_HELPER=""
LOCK_HELPER_DIR=""
WINDOW_HELPER=""

log()   { printf '[renew-autotune] %s\n' "$*"; }
fatal() { printf '[renew-autotune] ERROR: %s\n' "$*" >&2; exit 1; }

# SSH options: laptop uses the operator ssh config (alias `pearl`). CI passes
# PEARL_SSH_IDENTITY + a pinned known_hosts file and must not fall back to
# ssh-agent identities or TOFU.
SSH_OPTS=(-o ConnectTimeout=15 -o BatchMode=yes)
if [ -n "${PEARL_SSH_IDENTITY:-}" ]; then
  case "$PEARL_SSH_IDENTITY" in ""|*[!A-Za-z0-9._/+=@-]*) fatal "unsafe PEARL_SSH_IDENTITY path" ;; esac
  [ -f "$PEARL_SSH_IDENTITY" ] || fatal "PEARL_SSH_IDENTITY is not a file"
  identity_mode="$(stat -f '%A' "$PEARL_SSH_IDENTITY" 2>/dev/null || stat -c '%a' "$PEARL_SSH_IDENTITY" 2>/dev/null || echo '')"
  case "$identity_mode" in
    600|400) ;;
    *) fatal "PEARL_SSH_IDENTITY $PEARL_SSH_IDENTITY has permissions $identity_mode; expected 0600 or 0400" ;;
  esac
  PEARL_SSH_KNOWN_HOSTS="${PEARL_SSH_KNOWN_HOSTS:-$SCRIPT_DIR/dist/malibu-download-known_hosts}"
  case "$PEARL_SSH_KNOWN_HOSTS" in ""|*[!A-Za-z0-9._/+=@-]*) fatal "unsafe PEARL_SSH_KNOWN_HOSTS path" ;; esac
  [ -f "$PEARL_SSH_KNOWN_HOSTS" ] || fatal "PEARL_SSH_KNOWN_HOSTS is not a file"
  SSH_OPTS+=(
    -i "$PEARL_SSH_IDENTITY"
    -o IdentitiesOnly=yes
    -o "UserKnownHostsFile=$PEARL_SSH_KNOWN_HOSTS"
    -o StrictHostKeyChecking=yes
    -p 22
  )
fi
case "$PEARL_SSH" in ""|*[!A-Za-z0-9._@-]*) fatal "unsafe PEARL_SSH: $PEARL_SSH" ;; esac

SSH() { ssh "${SSH_OPTS[@]}" "$PEARL_SSH" "$@"; }
RSYNC_RSH="ssh"
for _ssh_opt in "${SSH_OPTS[@]}"; do
  RSYNC_RSH="$RSYNC_RSH $_ssh_opt"
done

# #1688: the Pearl activation machinery (helper shipping, locked publish, window,
# swap, SIGHUP, exact rollback) is shared with the catalog-content lane.
# shellcheck source=scripts/lib/autotune-activate.sh
. "$SCRIPT_DIR/lib/autotune-activate.sh"

cleanup() {
  local rc=$?
  # Release the remote publish lock if this run acquired it (MED-3).
  if [ -n "$LOCK_HELD" ]; then
    SSH "rmdir '$REMOTE_AUTOTUNE_DIR/.renew.lock'" >/dev/null 2>&1 || true
  fi
  aa_cleanup_remote_helpers
  [ -n "$STAGING" ] && [ -d "$STAGING" ] && rm -rf "$STAGING"
  [ -n "$PREVIOUS_RELEASE_DIR" ] && [ -d "$PREVIOUS_RELEASE_DIR" ] && rm -rf "$PREVIOUS_RELEASE_DIR"
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
if [ -n "${GITHUB_SHA:-}" ]; then
  # Actions: restamp the approved workflow commit, not a floating origin/main.
  case "$GITHUB_SHA" in
    *[!0-9a-fA-F]*) fatal "unsafe GITHUB_SHA" ;;
  esac
  [ "${#GITHUB_SHA}" -eq 40 ] || fatal "GITHUB_SHA must be a 40-character commit"
  git -C "$REPO_ROOT" cat-file -e "${GITHUB_SHA}^{commit}" \
    || fatal "GITHUB_SHA $GITHUB_SHA is not in this checkout"
  git -C "$REPO_ROOT" worktree add --quiet --detach "$WORKTREE" "$GITHUB_SHA"
  # generate reads the previous ledger via CATALOG_RELEASE_BASE_REF (default
  # origin/main). A fetch-depth:1 Actions checkout has the SHA but not that
  # remote-tracking ref. Bind the ledger to the same reviewed commit.
  export CATALOG_RELEASE_BASE_REF="$GITHUB_SHA"
  log "built ephemeral worktree at $WORKTREE (GITHUB_SHA ${GITHUB_SHA:0:12})"
else
  git -C "$REPO_ROOT" fetch --quiet origin
  git -C "$REPO_ROOT" worktree add --quiet --detach "$WORKTREE" origin/main
  log "built ephemeral worktree at $WORKTREE (origin/main $(git -C "$WORKTREE" rev-parse --short HEAD))"
fi

CAT_DIR="$WORKTREE/phase3-binary/catalog/autotune"
STATIC_DIR="$WORKTREE/phase3-binary/dist/static"

# Re-stamp version + generated_at ONLY, at the SOURCE. Content is otherwise
# byte-identical: candidate/demand carry a published-<date> version; rate-card's
# version is a rows-hash and MUST NOT change on a freshness-only renewal.
#
# `catalog-release.py restamp` owns which files are sources and which are
# generated. rate-card.json is now MATERIALISED from rate-card-source.json by the
# `generate` below, so re-dating rate-card.json here would be overwritten by that
# same generate and the atomic-release check would then abort this renewal on a
# stale rate-card generated_at. The generator exclusively writes rate-card.json.
log "re-stamping release source inputs for $RELEASE_ID"
( cd "$WORKTREE" && python3 scripts/catalog-release.py restamp \
    --release-id "$RELEASE_ID" --generated-at "$NOW_ISO" )

# SPEC-023 §3.7.8: a freshness renewal NEVER activates the artifact feed. With
# neither variable set this stays the four-feed renewal it has always been, even
# once autotune-artifacts-source.json is committed with unmeasured size_bytes.
# Once a release IS artifact-bound, AUTOTUNE_PREVIOUS_RELEASE_DIR names the
# previous signed release directory the §3.7.4 rebinding check requires.
# SPEC-023 §3.7.8: once a release is artifact-bound, every later cut must
# authenticate the PREVIOUS signed release (cross-release rebinding, intake
# transitions), and `generate` fails closed without it. The scheduled renewal
# fetches the live coordinator's current release directory as that input when
# the operator has not named one, so the monthly freshness cron keeps working
# after activation instead of stranding providers at the 30-day horizon. The
# fetched bytes are AUTHENTICATED by `generate` (keyring + ledger binding +
# signer equality), never trusted by path.
ARTIFACT_FEED_STATE="$( cd "$WORKTREE" && python3 scripts/catalog-release.py status | sed -n 's/^artifact-feed state *: *//p' )"
case "$ARTIFACT_FEED_STATE" in
  post-activation|post_activation)
    if [ -z "${AUTOTUNE_PREVIOUS_RELEASE_DIR:-}" ]; then
      # Dry-run keeps its no-contact contract: it never talks to Pearl, so a
      # post-activation dry-run needs the operator to name the directory.
      [ "$DEPLOY" = 1 ] ||
        fatal "post-activation renewal dry-run needs AUTOTUNE_PREVIOUS_RELEASE_DIR (the previous signed release directory); dry-run makes no contact with $PEARL_SSH"
      PREVIOUS_RELEASE_DIR="$(mktemp -d -t macprovider-feed-previous.XXXXXXXX)"
      log "post-activation catalog: fetching the live signed release from $PEARL_SSH:$REMOTE_AUTOTUNE_DIR/current as the previous release"
      SSH "tar -C '$REMOTE_AUTOTUNE_DIR/current' -cf - ." | tar -C "$PREVIOUS_RELEASE_DIR" -xf - ||
        fatal "cannot fetch the live signed release from $PEARL_SSH; set AUTOTUNE_PREVIOUS_RELEASE_DIR to the previous signed release directory"
      AUTOTUNE_PREVIOUS_RELEASE_DIR="$PREVIOUS_RELEASE_DIR"
    fi
    ;;
  pre-activation|pre_activation|activation) ;;
  *) fatal "cannot determine the artifact-feed state from catalog-release.py status (got '${ARTIFACT_FEED_STATE}')" ;;
esac
GENERATE_ARGS=(generate --signer-key-id "$KEY_ID")
case "${AUTOTUNE_ACTIVATE_ARTIFACT_FEED:-0}" in
  1|true|yes) GENERATE_ARGS+=(--activate-artifact-feed) ;;
  0|false|no|"") ;;
  *) fatal "AUTOTUNE_ACTIVATE_ARTIFACT_FEED must be 1/0 (got ${AUTOTUNE_ACTIVATE_ARTIFACT_FEED})" ;;
esac
if [ -n "${AUTOTUNE_PREVIOUS_RELEASE_DIR:-}" ]; then
  [ -d "$AUTOTUNE_PREVIOUS_RELEASE_DIR" ] ||
    fatal "AUTOTUNE_PREVIOUS_RELEASE_DIR is not a directory: $AUTOTUNE_PREVIOUS_RELEASE_DIR"
  GENERATE_ARGS+=(--previous-release-dir "$AUTOTUNE_PREVIOUS_RELEASE_DIR")
fi

log "regenerating canonical feed + manifest + ledger for $RELEASE_ID"
( cd "$WORKTREE" && python3 scripts/catalog-release.py "${GENERATE_ARGS[@]}" )

log "signing feed bytes with $KEY_ID (in-memory public-key derivation check; no bytes printed)"
( cd "$WORKTREE" && AUTOTUNE_STATIC_KEY_ID="$KEY_ID" \
  AUTOTUNE_ACTIVATE_ARTIFACT_FEED="${AUTOTUNE_ACTIVATE_ARTIFACT_FEED:-0}" \
  AUTOTUNE_PREVIOUS_RELEASE_DIR="${AUTOTUNE_PREVIOUS_RELEASE_DIR:-}" \
  bash scripts/resign-autotune-static.sh )

# ---------------------------------------------------------------------------
# 2. Assemble the release directory (9 files; 11 once the release is
#    artifact-bound: + autotune-artifacts.json and its .sig) and gate it with
#    verify-directory.
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
# SPEC-023 §3.7.8 Stage A: the freshly generated release.json is the ONLY
# authority on whether this release is artifact-bound. Bound → the feed and
# its sidecar are staged (both required); unbound → neither may exist, or the
# verify-directory gate below would see a stray fifth feed.
staged_artifact_bound="$(python3 - "$CAT_DIR/release.json" <<'PY'
import json, pathlib, sys
feeds = json.loads(pathlib.Path(sys.argv[1]).read_text())["feeds"]
print("bound" if "autotune-artifacts.json" in feeds else "unbound")
PY
)"
if [ "$staged_artifact_bound" = bound ]; then
  [ -f "$CAT_DIR/autotune-artifacts.json" ] && [ -f "$STATIC_DIR/autotune-artifacts.json.sig" ] ||
    fatal "release.json binds autotune-artifacts.json but the generated feed or its sidecar is missing"
  install -m 0644 "$CAT_DIR/autotune-artifacts.json" "$RELEASE_STAGE/autotune-artifacts.json"
  install -m 0644 "$STATIC_DIR/autotune-artifacts.json.sig" "$RELEASE_STAGE/autotune-artifacts.json.sig"
  log "staged artifact-bound five-feed release directory"
else
  for stray in "$CAT_DIR/autotune-artifacts.json" "$STATIC_DIR/autotune-artifacts.json.sig"; do
    [ -e "$stray" ] && fatal "release.json does not bind autotune-artifacts.json but $stray exists"
  done
fi
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

# #1693 L0 one-writer rule: a renewal swaps `current` and SIGHUPs, so it must
# not run while a pricing transaction journal exists (the journal records the
# `current` target and window it will restore). The lane holds the Pearl lock
# set for the whole transaction, so aa_publish's flock -n also refuses while
# a lane is live; this check covers an abandoned journal.
PRICING_TXN="${REMOTE_AUTOTUNE_DIR%/*}/.pricing-txn"
pricing_txn_state="$(SSH "if test -e '$PRICING_TXN' || test -L '$PRICING_TXN'; then echo present; else echo absent; fi")" \
  || fatal "cannot check for a pricing transaction journal at $PRICING_TXN"
case "$pricing_txn_state" in
  absent) ;;
  present) fatal "refusing: pricing transaction journal present at $PRICING_TXN; run scripts/catalog-content-release.sh --recover-pricing-txn" ;;
  *) fatal "unexpected pricing transaction journal state: $pricing_txn_state" ;;
esac

aa_read_live_targets
log "current live release: $CURRENT_TARGET (prior previous-target: ${ORIG_PREVIOUS_TARGET:-<none>})"

aa_refuse_existing_release

# CONTENT-CONTINUITY GUARD: a renewal must change ONLY dates. Compare the new
# feed content (version/generated_at stripped) against the live release; abort
# if models, gates, or rate-card rows differ — a real catalog change must go
# through a reviewed release, never this freshness cron.
# The rules live in `catalog-release.py continuity-check` (feed_continuity_drift)
# so they are unit-tested: candidate/demand/rate-card compared with version +
# generated_at stripped, and the artifact feed compared by PRESENCE and by
# content with its release-derived fields stripped. A renewal that would add,
# drop, or rewrite the artifact feed is a catalog release, not a restamp.
# tier2-catalog.json must match once its signing envelope is stripped (an
# expiry re-sign is freshness; a model change is a content release) and
# trusted-keys.json must be byte-equal: this job copies both from main, so a
# Tier-2 or keyring change merged there must go through the catalog-content
# lane, never this unattended cron.
log "checking content continuity against the live release (freshness-only guard)"
LIVE_SNAPSHOT="$STAGING/live-current"
mkdir -p "$LIVE_SNAPSHOT"
for name in autotune-candidates.json demand-rank.json rate-card.json tier2-catalog.json trusted-keys.json; do
  SSH "cat '$REMOTE_AUTOTUNE_DIR/current/$name'" > "$LIVE_SNAPSHOT/$name" || fatal "cannot read live $name"
done
live_artifact_state="$(SSH "if test -f '$REMOTE_AUTOTUNE_DIR/current/autotune-artifacts.json'; then echo present; else echo absent; fi")" \
  || fatal "cannot determine whether the live release carries autotune-artifacts.json"
case "$live_artifact_state" in
  present)
    SSH "cat '$REMOTE_AUTOTUNE_DIR/current/autotune-artifacts.json'" > "$LIVE_SNAPSHOT/autotune-artifacts.json" \
      || fatal "cannot read live autotune-artifacts.json" ;;
  absent) ;;
  *) fatal "unexpected live artifact-feed state: $live_artifact_state" ;;
esac
( cd "$WORKTREE" && python3 scripts/catalog-release.py continuity-check --incoming "$RELEASE_STAGE" --live "$LIVE_SNAPSHOT" ) \
  || fatal "content drift vs live feed — renewal is freshness-only; this is a content release — use the catalog-content lane, not freshness renewal"
log "content continuity confirmed (dates-only delta)"

# Ship + verify the helpers, stage the immutable release, then publish under the
# Pearl deploy locks: the continuity gate re-runs under the lock, coverage is
# warn-and-publish (#1688 B2), and a post-swap failure rolls back exactly.
aa_install_helpers
aa_upload_release "$RELEASE_STAGE"
AA_WORK_DIR="$STAGING"
AA_GATE_SNIPPET="$AA_GATE_CONTINUITY_CHECK"
AA_COVERAGE_POLICY=warn
AA_LOCK_MODE=flock
aa_publish

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
renew_served_feed_evidence() {
SERVED_JSON="$(curl -fsS --max-time 20 "$COORDINATOR_HEALTH_URL" 2>/dev/null)" || { AA_EVIDENCE_FAILURE="served rate-card unreachable after reload"; return 1; }
# The check body is plain Python with no backslashes: a backslash-escaped
# quote inside a bash single-quoted f-string is a SyntaxError at deploy time
# (2026-09-16 renewal rolled back a GOOD reload on exactly that), and a
# verifier that cannot run is indistinguishable from a failed activation.
# scripts/tests/test_renew_served_feed_check.py executes this exact block.
if ! printf '%s' "$SERVED_JSON" | python3 -c '
import json, sys
expected = sys.argv[1]
served = json.loads(sys.stdin.read())
gen = served.get("generated_at", "")
ok = gen == expected
verdict = "OK" if ok else "MISMATCH"
print("served generated_at=%s (expected exactly %s) -> %s" % (gen, expected, verdict), file=sys.stderr)
sys.exit(0 if ok else 1)
' "$NOW_ISO"; then
  AA_EVIDENCE_FAILURE="served feed did not activate to this deploy (generated_at != ${NOW_ISO}) after SIGHUP"
  return 1
fi
}
aa_post_activation_evidence renew_served_feed_evidence

log "SUCCESS: coordinator now serving the renewed feed ${RELEASE_DIRNAME} (no restart, fleet undisturbed)."
log "previous release retained as .previous-target -> $CURRENT_TARGET"

# ---------------------------------------------------------------------------
# 5. #1688 B2: coverage report. The renewal is already live and is NEVER undone
#    for coverage: an expired feed strands every provider, a dropped window
#    slot strands only providers that skipped three renewals without a restart.
#    A loss is a loud success: a GitHub Actions ::warning:: plus a
#    renewal_coverage_loss record in Pearl's catalog-window-overrides.jsonl.
# ---------------------------------------------------------------------------
RENEW_COVERAGE_RC="$(printf '%s\n' "$PUBLISH_OUT" | sed -n 's/^RENEW_COVERAGE_RC=//p' | tail -n 1)"
RENEW_COVERAGE_JSON="$(printf '%s\n' "$PUBLISH_OUT" | sed -n 's/^RENEW_COVERAGE_JSON=//p' | tail -n 1)"
# stdout: the uncovered records as a compact JSON list (empty when covered).
# exit 3: coverage unknown (not computed, or a malformed report).
RENEW_COVERAGE_STATE=known
RENEW_COVERAGE_RECORDS="$(python3 - "$RENEW_COVERAGE_RC" "$RENEW_COVERAGE_JSON" <<'PY'
import json, re, sys
rc, raw = sys.argv[1], sys.argv[2]
try:
    if rc not in ("0", "4"):
        raise ValueError(f"coverage exit {rc or '<missing>'}")
    value = json.loads(raw)
    covered, uncovered, total = value["covered"], value["uncovered"], value["advertised_total"]
    if (not isinstance(total, int) or isinstance(total, bool) or total < 0
            or not isinstance(covered, list) or not isinstance(uncovered, list)):
        raise ValueError("coverage report has the wrong shape")
    if (rc == "4") != bool(uncovered):
        raise ValueError(f"coverage exit {rc} does not match its report")
    records = []
    for entry in uncovered:
        rid, sha = entry["release_id"], entry["sha"]
        if not isinstance(rid, str) or re.fullmatch(r"[A-Za-z0-9][A-Za-z0-9._-]{0,191}", rid) is None:
            raise ValueError("coverage report carries an unsafe release id")
        if not isinstance(sha, str) or re.fullmatch(r"[0-9a-f]{64}", sha) is None:
            raise ValueError("coverage report carries a malformed sha")
        counts = {k: entry[k] for k in ("providers", "routing_eligible")}
        if any(not isinstance(v, int) or isinstance(v, bool) or v < 0 for v in counts.values()):
            raise ValueError("coverage report carries a bad count")
        records.append({"release_id": rid, "sha": sha, **counts})
except (ValueError, KeyError, TypeError) as exc:
    print(f"renewal coverage unknown: {exc}", file=sys.stderr)
    sys.exit(3)
print(f"window coverage: {len(covered)} admissible release(s), {total} catalog-advertising "
      f"provider(s), {len(records)} uncovered", file=sys.stderr)
for r in records:
    print(f"  UNCOVERED {r['release_id']} sha={r['sha'][:16]} providers={r['providers']} "
          f"routing_eligible={r['routing_eligible']}", file=sys.stderr)
if records:
    print(json.dumps(records, sort_keys=True, separators=(",", ":")))
PY
)" || RENEW_COVERAGE_STATE=unknown
if [ "$RENEW_COVERAGE_STATE" = unknown ]; then
  printf '::warning title=Autotune renewal coverage unknown::renewal %s published, but connected-provider catalog coverage could not be computed; check /poolz for providers about to fail catalog_incompatible\n' "$RELEASE_DIRNAME"
elif [ -n "$RENEW_COVERAGE_RECORDS" ]; then
  printf '::warning title=Autotune renewal coverage loss::renewal %s published; connected providers advertise catalog release(s) that left the retained window and will be rejected catalog_incompatible on their next hello: %s\n' "$RELEASE_DIRNAME" "$RENEW_COVERAGE_RECORDS"
  COVERAGE_RECORD_B64="$(python3 - "$RENEW_COVERAGE_RECORDS" "$RELEASE_DIRNAME" "$CURRENT_TARGET" "${GITHUB_RUN_ID:-}" <<'PY'
import base64, json, sys
uncovered, incoming, live_target, run_id = sys.argv[1:]
record = {"kind": "renewal_coverage_loss", "uncovered": json.loads(uncovered),
          "incoming": "releases/" + incoming, "live": {"target": live_target}, "run_id": run_id}
print(base64.b64encode(json.dumps(record, sort_keys=True).encode("ascii")).decode("ascii"))
PY
)" || COVERAGE_RECORD_B64=""
  case "$COVERAGE_RECORD_B64" in *[!A-Za-z0-9+/=]*) COVERAGE_RECORD_B64="" ;; esac
  # Same append contract as deploy-pearl-vps.sh _append_catalog_window_override:
  # root-only 0600, O_APPEND|O_NOFOLLOW, regular file only, fsync.
  if [ -n "$COVERAGE_RECORD_B64" ] && SSH "install -d -o macprovider -g macprovider -m 0750 /var/lib/macprovider && python3 -I - '$COVERAGE_RECORD_B64' && logger -t macprovider-renew 'autotune renewal coverage loss for $RELEASE_DIRNAME'" <<'PY'
import base64, datetime, json, os, stat, sys
record = json.loads(base64.b64decode(sys.argv[1], validate=True).decode("ascii"))
if not isinstance(record, dict) or "ts" in record:
    raise SystemExit("renewal coverage record must be a JSON object without ts")
record["ts"] = datetime.datetime.now(datetime.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")
path = "/var/lib/macprovider/catalog-window-overrides.jsonl"
fd = os.open(path, os.O_WRONLY | os.O_APPEND | os.O_CREAT | os.O_NOFOLLOW, 0o600)
try:
    if not stat.S_ISREG(os.fstat(fd).st_mode):
        raise SystemExit(path + " is not a regular file")
    os.fchown(fd, 0, 0)
    os.fchmod(fd, 0o600)
    os.write(fd, (json.dumps(record, sort_keys=True) + "\n").encode("ascii"))
    os.fsync(fd)
finally:
    os.close(fd)
PY
  then
    log "AUDIT TRAIL: renewal_coverage_loss appended to /var/lib/macprovider/catalog-window-overrides.jsonl"
  else
    printf '::warning title=Autotune renewal coverage record failed::could not append renewal_coverage_loss for %s to /var/lib/macprovider/catalog-window-overrides.jsonl\n' "$RELEASE_DIRNAME"
  fi
else
  log "window coverage: every connected provider's catalog release stays admissible"
fi
