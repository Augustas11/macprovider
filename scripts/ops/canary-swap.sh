#!/usr/bin/env bash
# Canary swap for the CLI release train (docs/releases/cli-release-train.md
# "Promotion gate", canary install/join smoke): put the verified signed
# candidate on the canary provider and get it back to buyer_serving, or put
# the previous payload back.
#
# Usage:
#   scripts/ops/canary-swap.sh check --version V [--tarball PATH]
#   MACPROVIDER_OPS_OWNER=<label> scripts/ops/canary-swap.sh swap --version V [--tarball PATH]
#
# check (read-only, local): the candidate tarball is the verified one
#   (binary sha256 == the signed_byte_verification record), holds no links,
#   and every shipped metallib (mlx.metallib and the SwiftPM bundle's
#   default.metallib) carries every kernel the pinned MLX core loads by name
#   (scripts/mlx-metallib-kernels.py, phase3-binary/mlx-metallib-required-kernels.json).
#   The 1.8.254 candidate failed exactly this and crash-looped the canary.
# swap: check, then under the live-ops lock: stop the buyer runner, stage the
#   tarball on the canary over STUDIO_SSH, and run lib/canary-swap-remote.sh
#   there (pause + drain, back up the install dir, payload-only swap, restart,
#   resume). A provider process restart or /v1/status silence for
#   CANARY_STATUS_TIMEOUT_S (default 120) restores the backup and resumes the
#   previous version automatically. The buyer runner is restarted on every exit.
#
# The tarball defaults to the verified bytes recorded by cli-release.sh
# (signed_byte_verification bytes_dir). Record the result afterwards with
#   scripts/ops/cli-release.sh next --done canary_smoke --probe
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
# payload restored and resumed; 6 restore needs the operator.
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

OPS_SCOPE="cli-release-$V"
if [ -z "$TARBALL" ]; then
  bytes_dir="$(marker_field "$OPS_SCOPE" signed_byte_verification 'd.get("bytes_dir")')"
  [ -n "$bytes_dir" ] && [ -d "$bytes_dir" ] ||
    refuse "no verified candidate bytes for v$V; run scripts/ops/cli-release.sh signed_byte_verification first or pass --tarball"
  TARBALL="$bytes_dir/macprovider-cli-v$V-darwin-arm64.tar.gz"
fi
[ -f "$TARBALL" ] || refuse "candidate tarball not found: $TARBALL"

check_candidate() {
  local payload="$OPS_TMP_DIR/payload" want got libs
  rm -rf "$payload"
  mkdir -p "$payload"
  tar -xzf "$TARBALL" -C "$payload" || refuse "cannot extract $TARBALL"
  if find "$payload" \( -type l -o -type b -o -type c -o -type p \) -print | grep . >/dev/null; then
    refuse "$TARBALL contains links or device files"
  fi
  [ -f "$payload/macprovider-cli" ] || refuse "$TARBALL lacks macprovider-cli"
  [ -f "$payload/mlx.metallib" ] || refuse "$TARBALL lacks mlx.metallib"
  want="$(marker_field "$OPS_SCOPE" signed_byte_verification 'd.get("binary_sha256")')"
  if [ -n "$want" ]; then
    got="$(shasum -a 256 "$payload/macprovider-cli" | awk '{print $1}')"
    [ "$got" = "$want" ] || refuse "macprovider-cli sha256 $got is not the verified candidate binary $want"
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

check_candidate
[ "$CMD" = swap ] || exit 0

require_studio_ssh
case "${STUDIO_STATUS_PORT:-}" in ""|*[!0-9]*) refuse "STUDIO_STATUS_PORT must be set and numeric" ;; esac
[ -n "${MACPROVIDER_OPS_OWNER:-}" ] || refuse "MACPROVIDER_OPS_OWNER is required for swap (live-ops lock owner)"
[ -n "${CANARY_RUNNER_STOP_CMD:-}" ] && [ -n "${CANARY_RUNNER_START_CMD:-}" ] ||
  refuse "set CANARY_RUNNER_STOP_CMD and CANARY_RUNNER_START_CMD (none when no buyer runner feeds the canary)"
for n in "${CANARY_STATUS_TIMEOUT_S:-120}" "${CANARY_READY_TIMEOUT_S:-1800}" "${CANARY_DRAIN_TIMEOUT_S:-600}" \
  "${CANARY_STABLE_S:-120}" "${CANARY_POLL_S:-5}"; do
  case "$n" in ""|*[!0-9]*) refuse "CANARY_*_S values must be whole seconds" ;; esac
done

"$OPS_DIR/live-lock.sh" acquire "$MACPROVIDER_OPS_OWNER" --purpose "$OPS_NAME:v$V" --bind-pid >&2 ||
  refuse "live-ops lock is held by another owner"
# shellcheck disable=SC2034  # released by cleanup_ops in lib/common.sh
OPS_LOCK_OWNER="$MACPROVIDER_OPS_OWNER"

RUNNER_STOPPED=0
# shellcheck disable=SC2329  # EXIT trap
finish() {
  local rc=$?
  trap - EXIT
  if [ "$RUNNER_STOPPED" = 1 ]; then
    if bash -c "$CANARY_RUNNER_START_CMD" >&2; then
      log "buyer runner restarted"
    else
      log "!!! buyer runner restart failed: run CANARY_RUNNER_START_CMD by hand"
      [ "$rc" != 0 ] || rc=6
    fi
  fi
  cleanup_ops
  exit "$rc"
}
trap finish EXIT

if [ "$CANARY_RUNNER_STOP_CMD" != none ]; then
  bash -c "$CANARY_RUNNER_STOP_CMD" >&2 || refuse "buyer runner stop failed; nothing swapped"
  RUNNER_STOPPED=1
  log "buyer runner stopped"
fi

sha="$(shasum -a 256 "$TARBALL" | awk '{print $1}')"
stage="\$HOME/macprovider-canary-staging/v$V-$(date -u +%Y%m%dT%H%M%SZ)"
studio_ssh "mkdir -p \"$stage\" && cat > \"$stage/candidate.tar.gz\"" < "$TARBALL" ||
  refuse "could not stage the candidate on the canary"
log "staged v$V on the canary ($sha)"

q() {
  case "$1" in *"'"*) refuse "canary setting contains a single quote: $1" ;; esac
  printf "'%s'" "$1"
}
rc=0
studio_ssh "bash -s -- \"$stage/candidate.tar.gz\" $(q "$sha") $(q "$V") $(q "${CANARY_INSTALL_DIR:-}") \
$(q "${CANARY_LAUNCHD_LABEL:-live.malibu.provider}") $(q "${CANARY_CTL_SOCKET:-}") $(q "$STUDIO_STATUS_PORT") \
$(q "${CANARY_STATUS_TIMEOUT_S:-120}") $(q "${CANARY_READY_TIMEOUT_S:-1800}") $(q "${CANARY_DRAIN_TIMEOUT_S:-600}") \
$(q "${CANARY_STABLE_S:-120}") $(q "${CANARY_POLL_S:-5}")" < "$OPS_DIR/lib/canary-swap-remote.sh" || rc=$?
case "$rc" in
  0) log "canary serves v$V; record it: scripts/ops/cli-release.sh next --done canary_smoke --probe" ;;
  4) log "canary refused the swap before touching the payload; provider resumed on its previous version" ;;
  5) log "v$V FAILED on the canary; the previous payload was restored and resumed. Do not promote v$V." ;;
  *) log "!!! canary swap exited $rc: check the canary now (see the messages above)" ;;
esac
exit "$rc"
