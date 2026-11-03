#!/usr/bin/env bash
# Pearl buyer-runner reservation of the Studio canary target.
#
# The buyer runner keeps every CB row of the Studio canary busy, so a proof
# request finds no idle capacity (native MTP routes ordinary, no provider
# available, CB self-check deferred). This pauses ONLY the Studio target: it
# removes that one row from the runner's targets.json (timestamped backup next
# to it), restarts the runner so its other targets keep their traffic, and
# restores the exact backup bytes with one more restart. The whole service is
# never stopped. Runs lib/buyer-runner-target.py over PEARL_SSH.
#
# Usage (standalone; sourcing it from an entry point gives the same functions):
#   MACPROVIDER_OPS_OWNER=<label> scripts/ops/lib/runner-reserve.sh pause-studio
#   MACPROVIDER_OPS_OWNER=<label> scripts/ops/lib/runner-reserve.sh restore
#   MACPROVIDER_OPS_OWNER=<label> scripts/ops/lib/runner-reserve.sh with-studio-paused -- CMD [ARG...]
#   scripts/ops/lib/runner-reserve.sh status
#
# with-studio-paused restores on every exit of CMD, on its failure, and on
# INT/TERM/HUP of this process (CMD is sent TERM first). restore is idempotent:
# with no outstanding reservation it reports absent and changes nothing. A
# reservation held by another owner is refused, never taken over.
#
# Env: PEARL_SSH (as lib/common.sh), MACPROVIDER_OPS_OWNER,
# RUNNER_STUDIO_PROVIDER_PREFIX (the Studio target's provider_id prefix in
# targets.json; "none" when no buyer runner feeds the canary),
# PEARL_RUNNER_TARGETS (default /opt/malibu-buyer-runner/targets.json),
# PEARL_RUNNER_RESERVE_DIR (default /var/lib/macprovider-ops).
# Exit codes: 0 ok; 2 usage; 3 refused (nothing changed); other: failure.

RUNNER_RESERVE_ACTIVE=0
RUNNER_RESERVE_CHILD=""

runner_reserve_enabled() { [ "${RUNNER_STUDIO_PROVIDER_PREFIX:-}" != none ]; }

# runner_reserve_check: refuse (exit 3) on unusable settings, before any change.
runner_reserve_check() {
  [[ "${RUNNER_STUDIO_PROVIDER_PREFIX:-}" =~ ^[a-z0-9][a-z0-9-]{5,63}$ ]] ||
    refuse "RUNNER_STUDIO_PROVIDER_PREFIX must be the Studio target's provider_id prefix (or none); see scripts/ops/README.md"
  [[ "${MACPROVIDER_OPS_OWNER:-}" =~ ^[A-Za-z0-9._@:-]{1,80}$ ]] ||
    refuse "MACPROVIDER_OPS_OWNER must name the session that owns the runner reservation"
  [[ "${PEARL_RUNNER_TARGETS:-/opt/malibu-buyer-runner/targets.json}" =~ ^/[A-Za-z0-9._/-]+$ ]] &&
    [[ "${PEARL_RUNNER_RESERVE_DIR:-/var/lib/macprovider-ops}" =~ ^/[A-Za-z0-9._/-]+$ ]] ||
    refuse "PEARL_RUNNER_TARGETS and PEARL_RUNNER_RESERVE_DIR must be absolute plain paths"
  require_pearl_ssh
}

# runner_reserve_remote COMMAND [ARGS...]: one helper command on Pearl.
runner_reserve_remote() {
  runner_reserve_check
  local cmd="$1"
  shift
  pearl_ssh "python3 - $cmd --path ${PEARL_RUNNER_TARGETS:-/opt/malibu-buyer-runner/targets.json} --state-dir ${PEARL_RUNNER_RESERVE_DIR:-/var/lib/macprovider-ops} --provider-prefix $RUNNER_STUDIO_PROVIDER_PREFIX --owner $MACPROVIDER_OPS_OWNER $*" \
    < "$OPS_LIB_DIR/buyer-runner-target.py"
}

runner_pause_studio() {
  runner_reserve_enabled || { log "no buyer runner feeds the canary (RUNNER_STUDIO_PROVIDER_PREFIX=none)"; return 0; }
  runner_reserve_check
  # Marked first: a pause that half-succeeds is restored too. A refusal (3)
  # changed nothing and leaves no reservation of this owner to restore.
  RUNNER_RESERVE_ACTIVE=1
  runner_reserve_remote reserve-pause >&2 || {
    local rc=$?
    [ "$rc" != 3 ] || RUNNER_RESERVE_ACTIVE=0
    return "$rc"
  }
  log "buyer runner: Studio target paused for the probe (other targets keep traffic)"
}

runner_restore_studio() {
  runner_reserve_enabled || return 0
  runner_reserve_remote reserve-restore >&2 || {
    local rc=$?
    log "!!! buyer runner Studio target NOT restored: run 'scripts/ops/lib/runner-reserve.sh restore' as owner ${MACPROVIDER_OPS_OWNER:-?}"
    return "$rc"
  }
  RUNNER_RESERVE_ACTIVE=0
  log "buyer runner: Studio target restored"
}

# runner_set_studio_model MODEL_ID: retarget the Studio row's model (one restart).
runner_set_studio_model() {
  runner_reserve_enabled || { log "no buyer runner feeds the canary; runner target unchanged"; return 0; }
  [[ "$1" =~ ^[A-Za-z0-9._/-]{1,160}$ ]] || refuse "unsafe runner model id"
  runner_reserve_remote set-target-model --model "$1" >&2
}

runner_reserve_on_exit() {
  local rc=$?
  trap - EXIT
  if [ "$RUNNER_RESERVE_ACTIVE" = 1 ]; then
    runner_restore_studio || [ "$rc" != 0 ] || rc=1
  fi
  cleanup_ops
  exit "$rc"
}

runner_reserve_signal() {
  [ -z "$RUNNER_RESERVE_CHILD" ] || kill -TERM "$RUNNER_RESERVE_CHILD" 2>/dev/null || true
  exit "$1"
}

# runner_with_studio_paused CMD [ARG...]: CMD (a command or shell function) runs
# with the Studio target paused; the target is restored on every exit.
runner_with_studio_paused() {
  if ! runner_reserve_enabled; then
    "$@"
    return
  fi
  trap runner_reserve_on_exit EXIT
  trap 'runner_reserve_signal 130' INT
  trap 'runner_reserve_signal 143' TERM
  trap 'runner_reserve_signal 129' HUP
  runner_pause_studio || exit $?
  local rc=0
  # In the background so a signal to this process is handled while CMD runs.
  ( "$@" ) &
  RUNNER_RESERVE_CHILD=$!
  wait "$RUNNER_RESERVE_CHILD" || rc=$?
  RUNNER_RESERVE_CHILD=""
  runner_restore_studio || [ "$rc" != 0 ] || rc=1
  trap cleanup_ops EXIT
  trap 'exit 130' INT
  trap 'exit 143' TERM
  trap 'exit 129' HUP
  return "$rc"
}

if [ "${BASH_SOURCE[0]}" = "$0" ]; then
  set -euo pipefail
  # shellcheck disable=SC2034  # OPS_NAME is read by lib/common.sh
  OPS_NAME=runner-reserve
  # shellcheck source=lib/common.sh
  . "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/common.sh"
  usage() { sed -n '2,/^# Exit codes/p' "${BASH_SOURCE[0]}" | sed -e 's/^# \{0,1\}//'; }
  case "${1:-}" in
    pause-studio) runner_pause_studio ;;
    restore) runner_restore_studio ;;
    status) runner_reserve_enabled || { echo '{"phase":"none"}'; exit 0; }
      MACPROVIDER_OPS_OWNER="${MACPROVIDER_OPS_OWNER:-status}" runner_reserve_remote reserve-status ;;
    with-studio-paused)
      shift
      [ "${1:-}" = -- ] || { usage >&2; exit 2; }
      shift
      [ "$#" -gt 0 ] || { usage >&2; exit 2; }
      runner_with_studio_paused "$@" ;;
    -h|--help|help) usage ;;
    *) usage >&2; exit 2 ;;
  esac
fi
