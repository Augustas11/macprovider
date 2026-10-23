#!/usr/bin/env bash
# Canary swap for the CLI release train (docs/releases/cli-release-train.md
# "Promotion gate" item 5, canary install/join smoke): put the verified signed
# candidate on the canary provider and get it back to buyer_serving, or put
# the previous version back.
#
# Usage:
#   scripts/ops/canary-swap.sh check --version V [--tarball PATH]
#   MACPROVIDER_OPS_OWNER=<label> scripts/ops/canary-swap.sh swap --version V
#
# check (read-only, local): the archive holds only regular, relative members,
#   and every shipped metallib (mlx.metallib and the SwiftPM bundle's
#   default.metallib) carries every kernel the pinned MLX core loads by name
#   (scripts/mlx-metallib-kernels.py, phase3-binary/mlx-metallib-required-kernels.json).
#   The 1.8.254 candidate failed exactly this. --tarball checks any archive.
#   check and swap also refuse a candidate whose baked catalog-release/
#   (release_id, release.json and rate-card.json generated_at) differs from
#   what Pearl serves at COORDINATOR_URL /v1/autotune-release and /v1/rate-card:
#   the canary would fail to join with rate_card_update_required (1.8.262).
#   Activate the catalog first (scripts/ops/catalog-activate.sh).
# swap: only the verified candidate bytes recorded by cli-release.sh
#   signed_byte_verification (the tarball sha256 must match the entry in that
#   run's signed checksums.txt). check, then under the live-ops lock: stop the
#   buyer runner, stage the tarball and lib/canary-swap-remote.sh on the canary
#   over STUDIO_SSH and start it detached, so a dropped ssh session cannot cut
#   a swap or a rollback short; this side polls its log and result. The remote
#   pauses and drains, backs up the install dir, swaps the payload, restarts and
#   resumes. A provider process restart or exit (crash loop), or a /v1/status
#   silence of CANARY_STATUS_TIMEOUT_S (default 120) after the candidate
#   reported its model loaded, restores the backup and resumes the previous
#   version once it is buyer_serving again. Silence while the model loads is
#   not a failure (a large model keeps /v1/status silent for minutes): with
#   the same pid alive it is bounded by CANARY_READY_TIMEOUT_S. The buyer runner is
#   restarted on every exit. A successful swap records the canary_swap marker
#   that `cli-release.sh next --done canary_smoke --probe` requires.
#
# Env (or ~/.config/macprovider/ops.env): COORDINATOR_URL, STUDIO_SSH (local = this Mac),
# STUDIO_SSH_KEY, STUDIO_STATUS_PORT, CANARY_RUNNER_STOP_CMD and
# CANARY_RUNNER_START_CMD (run on this Mac; "none" when no buyer runner
# feeds the canary), CANARY_INSTALL_DIR (default ~/macprovider on the canary),
# CANARY_LAUNCHD_LABEL (default live.malibu.provider), CANARY_CTL_SOCKET
# (default the canary user's temp dir macprovider-cli/ctl.sock),
# CANARY_STATUS_TIMEOUT_S (120), CANARY_READY_TIMEOUT_S (1800),
# CANARY_DRAIN_TIMEOUT_S (600), CANARY_STABLE_S (120), CANARY_POLL_S (5).
#
# Exit codes: 0 ok; 2 usage; 3 refused (nothing changed); 4 refused on the
# canary before the swap (provider resumed); 5 candidate failed, previous
# version restored and buyer_serving; 6 recovery needs the operator.
set -euo pipefail
# shellcheck source-path=SCRIPTDIR disable=SC2034  # OPS_NAME is read by lib/common.sh
OPS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
OPS_NAME=canary-swap
# shellcheck source=lib/common.sh
. "$OPS_DIR/lib/common.sh"

usage() { sed -n '2,/^set -euo pipefail$/p' "${BASH_SOURCE[0]}" | sed -e '$d' -e 's/^# \{0,1\}//'; }

CMD="${1:-}"
[ "$#" -gt 0 ] && shift
V=""
TARBALL=""
TARBALL_OVERRIDE=""
while [ "$#" -gt 0 ]; do
  case "$1" in
    --version) [ "$#" -ge 2 ] || { usage >&2; exit 2; }; V="$2"; shift 2 ;;
    --tarball) [ "$#" -ge 2 ] || { usage >&2; exit 2; }; TARBALL="$2"; TARBALL_OVERRIDE=1; shift 2 ;;
    -h|--help) usage; exit 0 ;;
    *) usage >&2; exit 2 ;;
  esac
done
case "$CMD" in check|swap|recover-air|restore-air) ;; -h|--help) usage; exit 0 ;; *) usage >&2; exit 2 ;; esac
if [ "$CMD" = recover-air ] || [ "$CMD" = restore-air ]; then
  [ "${MACPROVIDER_OPS_ENTRYPOINT:-}" = 1 ] && [ "$V" = 1.8.260 ] || refuse "Air recovery runs only through the guarded Air entrypoint"
  [ -n "${AIR_RECOVERY_PROVIDER_SHA256:-}" ] && [ -n "${AIR_RECOVERY_CONFIG:-}" ] && [ -n "${AIR_RECOVERY_BINARY_SHA256:-}" ] || refuse "Air recovery identity is missing"
  [[ "${AIR_RECOVERY_CONFIG_SHA256:-}" =~ ^[0-9a-f]{64}$ ]] || refuse "Air recovery baseline config digest is missing"
fi
is_semver "$V" || { usage >&2; exit 2; }
[ "$CMD" = check ] || [ -z "$TARBALL" ] ||
  refuse "swap takes only the verified candidate bytes; --tarball is for check"

OPS_SCOPE="cli-release-$V"
ASSET="macprovider-cli-v$V-darwin-arm64.tar.gz"
TARBALL_SHA=""

# bind_verified_tarball: TARBALL becomes the verified run's asset, and its
# sha256 must equal the entry in that run's signature-verified checksums.txt.
bind_verified_tarball() {
  local bytes_dir want_checksums got_checksums
  bytes_dir="$(marker_field "$OPS_SCOPE" signed_byte_verification 'd.get("bytes_dir")')"
  want_checksums="$(marker_field "$OPS_SCOPE" signed_byte_verification 'd.get("checksums_sha256")')"
  [ -n "$bytes_dir" ] && [ -d "$bytes_dir" ] && [ -n "$want_checksums" ] ||
    refuse "no verified candidate bytes for v$V; run the cli-release.sh signed_byte_verification step first"
  got_checksums="$(shasum -a 256 "$bytes_dir/checksums.txt" | awk '{print $1}')"
  [ "$got_checksums" = "$want_checksums" ] ||
    refuse "$bytes_dir/checksums.txt is not the signature-verified checksums.txt"
  TARBALL="$bytes_dir/$ASSET"
  [ -f "$TARBALL" ] || refuse "verified candidate tarball not found: $TARBALL"
  TARBALL_SHA="$(awk -v a="$ASSET" '$2 == a { print $1 }' "$bytes_dir/checksums.txt" | head -n1)"
  [ -n "$TARBALL_SHA" ] && [ "$(shasum -a 256 "$TARBALL" | awk '{print $1}')" = "$TARBALL_SHA" ] ||
    refuse "$TARBALL does not match its signed checksums.txt entry"
}

# candidate_manifest: the required-kernel manifest of the commit the candidate
# was built from (signed_byte_verification candidate_sha), not this checkout's.
# check --tarball without a verified candidate uses this checkout's manifest.
candidate_manifest() {
  local sha path="phase3-binary/mlx-metallib-required-kernels.json" out="$OPS_TMP_DIR/mlx-required-kernels.json"
  sha="$(marker_field "$OPS_SCOPE" signed_byte_verification 'd.get("candidate_sha")')"
  if [ "$CMD" = check ] && [ -n "$TARBALL_OVERRIDE" ]; then
    printf '%s\n' "$REPO_ROOT/$path"
    return
  fi
  is_sha40 "$sha" || refuse "the signed_byte_verification record names no candidate_sha"
  if git -C "$REPO_ROOT" cat-file -e "$sha:$path" 2>/dev/null; then
    git -C "$REPO_ROOT" show "$sha:$path" >"$out"
  else
    curl -fsSL --proto '=https' --max-time 60 \
      "https://raw.githubusercontent.com/$(gh_repo)/$sha/$path" -o "$out" ||
      refuse "cannot read $path at candidate commit $sha"
  fi
  printf '%s\n' "$out"
}

check_candidate() {
  local payload="$OPS_TMP_DIR/payload" want got libs
  rm -rf "$payload"
  mkdir -p "$payload"
  python3 - "$TARBALL" "$payload" <<'PY' || refuse "$TARBALL has unsafe or unexpected members"
import os, sys, tarfile
src, dest = sys.argv[1], sys.argv[2]
with tarfile.open(src, "r:gz") as tar:
    members, seen = tar.getmembers(), set()
    for m in members:
        name = os.path.normpath(m.name)
        if m.name.startswith("/") or name == ".." or name.startswith("../") or name in seen:
            sys.exit("unsafe member name: %r" % m.name)
        if not (m.isfile() or m.isdir()):
            sys.exit("non-regular member: %r" % m.name)
        seen.add(name)
    for m in members:
        tar.extract(m, dest, set_attrs=False)
PY
  [ -f "$payload/macprovider-cli" ] || refuse "$TARBALL lacks macprovider-cli"
  [ -f "$payload/mlx.metallib" ] || refuse "$TARBALL lacks mlx.metallib"
  if [ "$CMD" != check ]; then
    want="$(marker_field "$OPS_SCOPE" signed_byte_verification 'd.get("binary_sha256")')"
    got="$(shasum -a 256 "$payload/macprovider-cli" | awk '{print $1}')"
    [ -n "$want" ] && [ "$got" = "$want" ] ||
      refuse "macprovider-cli sha256 $got is not the verified candidate binary ${want:-<unrecorded>}"
    BINARY_SHA="$got"
  fi
  libs=("$payload/mlx.metallib")
  if [ -f "$payload/mlx-swift_Cmlx.bundle/Contents/Resources/default.metallib" ]; then
    libs+=("$payload/mlx-swift_Cmlx.bundle/Contents/Resources/default.metallib")
  fi
  python3 "$REPO_ROOT/scripts/mlx-metallib-kernels.py" check --manifest "$(candidate_manifest)" "${libs[@]}" >&2 ||
    refuse "candidate metallib lacks kernels the pinned MLX core loads by name; do not swap it onto the canary"
  log "candidate v$V passed the pre-swap checks"
}

# check_catalog_live: a candidate whose baked catalog release is not the one
# Pearl serves fails the canary join with rate_card_update_required (1.8.262).
# Compare the baked catalog-release/ release_id and generated_at stamps with
# the coordinator's /v1/autotune-release and /v1/rate-card; refuse on any
# difference, and when Pearl's catalog cannot be read.
check_catalog_live() {
  local payload="$OPS_TMP_DIR/payload" base verdict
  [ -f "$payload/catalog-release/release.json" ] || refuse "$TARBALL lacks catalog-release/release.json"
  base="$(coordinator_url)"
  [ -n "$base" ] || refuse "COORDINATOR_URL is unset; cannot compare the baked catalog with Pearl's"
  [ "$(http_get "$base/v1/autotune-release" "$OPS_TMP_DIR/live-release.json")" = 200 ] &&
    [ "$(http_get "$base/v1/rate-card" "$OPS_TMP_DIR/live-rate-card.json")" = 200 ] ||
    refuse "cannot read Pearl's live catalog from $base/v1/autotune-release and /v1/rate-card"
  verdict="$(python3 - "$payload/catalog-release" "$OPS_TMP_DIR/live-release.json" "$OPS_TMP_DIR/live-rate-card.json" <<'PY'
import json, os, sys
cand, live_rel_path, live_card_path = sys.argv[1:4]
def load(path):
    with open(path) as f:
        return json.load(f)
try:
    rel, live_rel, live_card = load(os.path.join(cand, "release.json")), load(live_rel_path), load(live_card_path)
    card = load(os.path.join(cand, "rate-card.json")) if os.path.exists(os.path.join(cand, "rate-card.json")) else None
except (OSError, ValueError) as exc:
    print("ERR unreadable catalog: %s" % exc); sys.exit(0)
cid, lid = rel.get("release_id"), live_rel.get("release_id")
diffs = []
if not cid or cid != lid:
    diffs.append("release_id")
if rel.get("generated_at") != live_rel.get("generated_at"):
    diffs.append("release.json generated_at %s vs %s" % (rel.get("generated_at"), live_rel.get("generated_at")))
if card is not None and (card.get("generated_at"), card.get("version")) != (live_card.get("generated_at"), live_card.get("version")):
    diffs.append("rate-card.json generated_at/version %s vs %s" % (card.get("generated_at"), live_card.get("generated_at")))
print("%s %s %s %s" % ("DIFF" if diffs else "OK", cid or "<none>", lid or "<none>", "; ".join(diffs)))
PY
)"
  local kind cid lid diffs
  read -r kind cid lid diffs <<<"$verdict"
  case "$kind" in
    OK) log "candidate bakes the catalog Pearl serves ($cid)" ;;
    DIFF) refuse "candidate bakes catalog $cid; Pearl serves $lid: activate the catalog first (scripts/ops/catalog-activate.sh) [differs: $diffs]" ;;
    *) refuse "cannot compare the baked catalog with Pearl's: ${verdict#ERR }" ;;
  esac
}

if [ "$CMD" = check ]; then
  [ -n "$TARBALL" ] || bind_verified_tarball
  [ -f "$TARBALL" ] || refuse "candidate tarball not found: $TARBALL"
  check_candidate
  check_catalog_live
  exit 0
fi

BINARY_SHA=""
bind_verified_tarball
check_candidate
[ "$CMD" != swap ] || check_catalog_live

require_studio_ssh
record_air_result() {
  local action="$1" code="$2"
  case "$action:$code" in recover-air:0|recover-air:4|recover-air:5|restore-air:5) ;;
    *) return 0 ;;
  esac
  mark_done "$OPS_SCOPE" air_recovery_result "guarded signed Air recovery returned" \
    "$(python3 -c 'import json,sys; print(json.dumps(dict(stage=sys.argv[1],provider_id_sha256=sys.argv[2],action=sys.argv[3],exit_code=int(sys.argv[4]))))' "$stage" "$AIR_RECOVERY_PROVIDER_SHA256" "$action" "$code")"
}
case "${STUDIO_STATUS_PORT:-}" in ""|*[!0-9]*) refuse "STUDIO_STATUS_PORT must be set and numeric" ;; esac
[ -n "${MACPROVIDER_OPS_OWNER:-}" ] || refuse "MACPROVIDER_OPS_OWNER is required for swap (live-ops lock owner)"
[ -n "${CANARY_RUNNER_STOP_CMD:-}" ] && [ -n "${CANARY_RUNNER_START_CMD:-}" ] ||
  refuse "set CANARY_RUNNER_STOP_CMD and CANARY_RUNNER_START_CMD (none when no buyer runner feeds the canary)"
STATUS_TIMEOUT_S="${CANARY_STATUS_TIMEOUT_S:-120}"
READY_TIMEOUT_S="${CANARY_READY_TIMEOUT_S:-1800}"
DRAIN_TIMEOUT_S="${CANARY_DRAIN_TIMEOUT_S:-600}"
STABLE_S="${CANARY_STABLE_S:-120}"
POLL_S="${CANARY_POLL_S:-5}"
for n in "$STATUS_TIMEOUT_S" "$READY_TIMEOUT_S" "$DRAIN_TIMEOUT_S" "$STABLE_S" "$POLL_S"; do
  case "$n" in ""|*[!0-9]*) refuse "CANARY_*_S values must be whole seconds" ;; esac
done

q() {
  case "$1" in *"'"*) refuse "canary setting contains a single quote: $1" ;; esac
  printf "'%s'" "$1"
}
q "${CANARY_INSTALL_DIR:-}" >/dev/null
q "${CANARY_LAUNCHD_LABEL:-}" >/dev/null
q "${CANARY_CTL_SOCKET:-}" >/dev/null

"$OPS_DIR/live-lock.sh" acquire "$MACPROVIDER_OPS_OWNER" --purpose "$OPS_NAME:v$V" --bind-pid >&2 ||
  refuse "live-ops lock is held by another owner"
# shellcheck disable=SC2034  # released by cleanup_ops in lib/common.sh
OPS_LOCK_OWNER="$MACPROVIDER_OPS_OWNER"

RUNNER_TOUCHED=0
REMOTE_STARTED=0
# shellcheck disable=SC2329  # EXIT trap
finish() {
  local rc=$?
  trap - EXIT
  # Once the remote run may have started, only its conclusive result (0, 4, 5)
  # lets buyers back: a signal, a lost launch or exit 6 leaves the runner down.
  if [ "$RUNNER_TOUCHED" = 1 ] && [ "$REMOTE_STARTED" = 1 ] && ! case "$rc" in 0|4|5) true ;; *) false ;; esac; then
    log "!!! buyer runner left STOPPED until the canary is recovered; then run CANARY_RUNNER_START_CMD"
  elif [ "$RUNNER_TOUCHED" = 1 ]; then
    if bash -c "$CANARY_RUNNER_START_CMD" >&2; then
      log "buyer runner restarted"
    else
      log "!!! buyer runner restart failed: run CANARY_RUNNER_START_CMD by hand"
      rc=6
    fi
  fi
  cleanup_ops
  exit "$rc"
}
trap finish EXIT

if [ "$CANARY_RUNNER_STOP_CMD" != none ]; then
  # Marked first: a stop that half-succeeds still gets a restart.
  RUNNER_TOUCHED=1
  bash -c "$CANARY_RUNNER_STOP_CMD" >&2 || refuse "buyer runner stop failed; nothing swapped"
  log "buyer runner stopped"
fi

# A unique stage per run: its log and result belong to this run only.
if [ "$CMD" = restore-air ]; then
  stage="$(marker_field "$OPS_SCOPE" air_recovery_dispatch 'd.get("stage")')"
  [ "$(marker_field "$OPS_SCOPE" air_recovery_dispatch 'd.get("provider_id_sha256")')" = "$AIR_RECOVERY_PROVIDER_SHA256" ] || refuse "Air recovery dispatch belongs to another provider"
  # Join the original detached actor; a recovery attempt must not turn its
  # lock-busy refusal into completion of the original transaction.
  deadline=$(( $(date +%s) + DRAIN_TIMEOUT_S + 2 * READY_TIMEOUT_S + 600 ))
  while studio_ssh 'p=$(cat "$HOME/.macprovider-canary-swap.lock/pid" 2>/dev/null) && kill -0 "$p" 2>/dev/null'; do
    [ "$(date +%s)" -lt "$deadline" ] || refuse "original Air payload actor is still active"
    sleep "$POLL_S"
  done
  original_rc="$(studio_ssh "cat $(q "$stage/result") 2>/dev/null" || true)"
  case "$original_rc" in 0|4|5)
    record_air_result recover-air "$original_rc"
    exit "$original_rc" ;;
  esac
else
  stage="$(studio_ssh "umask 077 && mkdir -p \"\$HOME/macprovider-canary-staging\" && mktemp -d \"\$HOME/macprovider-canary-staging/v$V-XXXXXX\"")" || refuse "could not create a staging dir on the canary"
fi
case "$stage" in /*/macprovider-canary-staging/v"$V"-*) ;; *) refuse "unexpected canary staging dir: $stage" ;; esac
q "$stage" >/dev/null
if [ "$CMD" != restore-air ]; then
  studio_ssh "cat > \"$stage/candidate.tar.gz\"" < "$TARBALL" || refuse "could not stage the candidate on the canary"
fi
remote_name=canary-swap-remote.sh
[ "$CMD" != restore-air ] || remote_name="air-restore-$$.sh"
studio_ssh "umask 077; cat > \"$stage/$remote_name\"" < "$OPS_DIR/lib/canary-swap-remote.sh" ||
  refuse "could not stage the swap script on the canary"
log "staged v$V on the canary ($TARBALL_SHA)"

result_file="$stage/result"
log_file="$stage/run.log"
if [ "$CMD" = restore-air ]; then result_file="$stage/restore-result-$$"; log_file="$stage/restore-$$.log"; fi
args="\"$stage/candidate.tar.gz\" $(q "$TARBALL_SHA") $(q "$V") $(q "${CANARY_INSTALL_DIR:-}") \
$(q "${CANARY_LAUNCHD_LABEL:-live.malibu.provider}") $(q "${CANARY_CTL_SOCKET:-}") $(q "$STUDIO_STATUS_PORT") \
$(q "$STATUS_TIMEOUT_S") $(q "$READY_TIMEOUT_S") $(q "$DRAIN_TIMEOUT_S") $(q "$STABLE_S") $(q "$POLL_S") $(q "$result_file")"
if [ "$CMD" = recover-air ] || [ "$CMD" = restore-air ]; then
  args="$args $(q "$AIR_RECOVERY_PROVIDER_SHA256") $(q "$AIR_RECOVERY_CONFIG") $(q "$AIR_RECOVERY_BINARY_SHA256") $(q "$CMD") $(q "$AIR_RECOVERY_CONFIG_SHA256")"
fi
REMOTE_STARTED=1
if [ "$CMD" = recover-air ]; then
  mark_done "$OPS_SCOPE" air_recovery_dispatch "guarded signed Air payload recovery dispatched" \
    "$(python3 -c 'import json,sys; print(json.dumps({"stage":sys.argv[1],"provider_id_sha256":sys.argv[2],"incumbent_binary_sha256":sys.argv[3],"config_sha256":sys.argv[4]}))' "$stage" "$AIR_RECOVERY_PROVIDER_SHA256" "$AIR_RECOVERY_BINARY_SHA256" "$AIR_RECOVERY_CONFIG_SHA256")"
fi
studio_ssh "cd \"$stage\" && nohup bash $(q "$remote_name") $args > $(q "$log_file") 2>&1 < /dev/null &" ||
  refuse "could not start the swap on the canary"

# Poll the detached run until it records its exit code. ssh failures while
# polling are retried; the remote run carries on without this side.
deadline=$(( $(date +%s) + DRAIN_TIMEOUT_S + 2 * READY_TIMEOUT_S + 600 ))
shown=0
rc=""
while [ -z "$rc" ]; do
  # Complete log lines past the ones already shown, the line count, then the
  # result file (empty until the remote run ends).
  if out="$(studio_ssh "f=$(q "$log_file"); n=\$(wc -l < \"\$f\" 2>/dev/null || echo 0); n=\$((n)); \
if [ \"\$n\" -gt $shown ]; then sed -n \"$((shown + 1)),\${n}p\" \"\$f\"; fi; \
printf '@@COUNT@@%s\\n@@RESULT@@' \"\$n\"; cat $(q "$result_file") 2>/dev/null || true")"; then
    chunk="${out%%@@COUNT@@*}"
    [ -z "$chunk" ] || printf '%s' "$chunk" >&2
    count="${out#*@@COUNT@@}"
    count="${count%%$'\n'*}"
    case "$count" in ''|*[!0-9]*) ;; *) shown="$count" ;; esac
    rc="$(printf '%s' "${out##*@@RESULT@@}" | tr -d '[:space:]')"
  else
    log "canary unreachable while polling; retrying"
  fi
  [ -n "$rc" ] && break
  [ "$(date +%s)" -lt "$deadline" ] || { log "!!! no result from the canary swap by the deadline; check $stage/run.log on the canary"; exit 6; }
  sleep "$POLL_S"
done
case "$rc" in 0|4|5|6) ;; *) log "!!! canary swap reported '$rc'"; exit 6 ;; esac
case "$CMD" in recover-air|restore-air) record_air_result "$CMD" "$rc" ;; esac

case "$rc" in
  0)
    mark_done "$OPS_SCOPE" canary_swap "canary-swap.sh swapped v$V" \
      "$(printf '{"candidate_sha":"%s","checksums_sha256":"%s","tarball_sha256":"%s","binary_sha256":"%s","kernel_check":"passed"}' \
        "$(marker_field "$OPS_SCOPE" signed_byte_verification 'd.get("candidate_sha")')" \
        "$(marker_field "$OPS_SCOPE" signed_byte_verification 'd.get("checksums_sha256")')" \
        "$TARBALL_SHA" "$BINARY_SHA")"
    log "canary serves v$V; record it: scripts/ops/cli-release.sh next --done canary_smoke --probe"
    ;;
  4) log "canary refused the swap before touching the payload; provider resumed on its previous version" ;;
  5) log "v$V FAILED on the canary; the previous version was restored and is buyer_serving. Do not promote v$V." ;;
  *) log "!!! canary swap needs the operator: see the messages above ($stage/run.log on the canary)" ;;
esac
exit "$rc"
