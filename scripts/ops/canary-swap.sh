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
# swap: only the verified candidate bytes recorded by cli-release.sh
#   signed_byte_verification (the tarball sha256 must match the entry in that
#   run's signed checksums.txt). check, then under the live-ops lock: stop the
#   buyer runner, stage the tarball and lib/canary-swap-remote.sh on the canary
#   over STUDIO_SSH and start it detached, so a dropped ssh session cannot cut
#   a swap or a rollback short; this side polls its log and result. The remote
#   pauses and drains, backs up the install dir, swaps the payload, restarts and
#   resumes. A provider process restart or a /v1/status silence of
#   CANARY_STATUS_TIMEOUT_S (default 120) restores the backup and resumes the
#   previous version once it is buyer_serving again. The buyer runner is
#   restarted on every exit. A successful swap records the canary_swap marker
#   that `cli-release.sh next --done canary_smoke --probe` requires.
#
# Env (or ~/.config/macprovider/ops.env): STUDIO_SSH (local = this Mac),
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
while [ "$#" -gt 0 ]; do
  case "$1" in
    --version) [ "$#" -ge 2 ] || { usage >&2; exit 2; }; V="$2"; shift 2 ;;
    --tarball) [ "$#" -ge 2 ] || { usage >&2; exit 2; }; TARBALL="$2"; shift 2 ;;
    -h|--help) usage; exit 0 ;;
    *) usage >&2; exit 2 ;;
  esac
done
case "$CMD" in check|swap) ;; -h|--help) usage; exit 0 ;; *) usage >&2; exit 2 ;; esac
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
  if [ "$CMD" = swap ]; then
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
  python3 "$REPO_ROOT/scripts/mlx-metallib-kernels.py" check \
    --manifest "$REPO_ROOT/phase3-binary/mlx-metallib-required-kernels.json" "${libs[@]}" >&2 ||
    refuse "candidate metallib lacks kernels the pinned MLX core loads by name; do not swap it onto the canary"
  log "candidate v$V passed the pre-swap checks"
}

if [ "$CMD" = check ]; then
  [ -n "$TARBALL" ] || bind_verified_tarball
  [ -f "$TARBALL" ] || refuse "candidate tarball not found: $TARBALL"
  check_candidate
  exit 0
fi

BINARY_SHA=""
bind_verified_tarball
check_candidate

require_studio_ssh
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
# shellcheck disable=SC2329  # EXIT trap
finish() {
  local rc=$?
  trap - EXIT
  if [ "$RUNNER_TOUCHED" = 1 ]; then
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

stage="\$HOME/macprovider-canary-staging/v$V-$(date -u +%Y%m%dT%H%M%SZ)"
studio_ssh "umask 077 && mkdir -p \"$stage\" && cat > \"$stage/candidate.tar.gz\"" < "$TARBALL" ||
  refuse "could not stage the candidate on the canary"
studio_ssh "cat > \"$stage/canary-swap-remote.sh\"" < "$OPS_DIR/lib/canary-swap-remote.sh" ||
  refuse "could not stage the swap script on the canary"
log "staged v$V on the canary ($TARBALL_SHA)"

args="\"$stage/candidate.tar.gz\" $(q "$TARBALL_SHA") $(q "$V") $(q "${CANARY_INSTALL_DIR:-}") \
$(q "${CANARY_LAUNCHD_LABEL:-live.malibu.provider}") $(q "${CANARY_CTL_SOCKET:-}") $(q "$STUDIO_STATUS_PORT") \
$(q "$STATUS_TIMEOUT_S") $(q "$READY_TIMEOUT_S") $(q "$DRAIN_TIMEOUT_S") $(q "$STABLE_S") $(q "$POLL_S") \"$stage/result\""
studio_ssh "cd \"$stage\" && nohup bash canary-swap-remote.sh $args > \"$stage/run.log\" 2>&1 < /dev/null &" ||
  refuse "could not start the swap on the canary"

# Poll the detached run until it records its exit code. ssh failures while
# polling are retried; the remote run carries on without this side.
deadline=$(( $(date +%s) + DRAIN_TIMEOUT_S + 2 * READY_TIMEOUT_S + 600 ))
shown=0
rc=""
while [ -z "$rc" ]; do
  # Complete log lines past the ones already shown, the line count, then the
  # result file (empty until the remote run ends).
  if out="$(studio_ssh "f=\"$stage/run.log\"; n=\$(wc -l < \"\$f\" 2>/dev/null || echo 0); n=\$((n)); \
if [ \"\$n\" -gt $shown ]; then sed -n \"$((shown + 1)),\${n}p\" \"\$f\"; fi; \
printf '@@COUNT@@%s\\n@@RESULT@@' \"\$n\"; cat \"$stage/result\" 2>/dev/null || true")"; then
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

case "$rc" in
  0)
    mark_done "$OPS_SCOPE" canary_swap "canary-swap.sh swapped v$V" \
      "$(printf '{"tarball_sha256":"%s","binary_sha256":"%s","kernel_check":"passed"}' "$TARBALL_SHA" "$BINARY_SHA")"
    log "canary serves v$V; record it: scripts/ops/cli-release.sh next --done canary_smoke --probe"
    ;;
  4) log "canary refused the swap before touching the payload; provider resumed on its previous version" ;;
  5) log "v$V FAILED on the canary; the previous version was restored and is buyer_serving. Do not promote v$V." ;;
  *) log "!!! canary swap needs the operator: see the messages above ($stage/run.log on the canary)" ;;
esac
exit "$rc"
