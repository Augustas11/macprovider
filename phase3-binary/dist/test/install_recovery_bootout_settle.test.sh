#!/usr/bin/env bash
set -euo pipefail

# Issue #1421: launchd keeps reporting a just-booted-out service as loaded for a
# short window while it tears the job down. recover.sh's stop_loaded_service
# used to bootout and then let the caller assert "still loaded?" with no settle
# wait, so a failed FIRST install (nothing was loaded before it) would boot out
# its own just-created service and immediately trip
#   "provider service is active even though it was inactive before the failed install"
# -> recovery_failed -> "automatic rollback failed" on a clean rollback.
#
# stop_loaded_service must wait for the unload to settle after bootout, succeed
# once the service actually unloads, and still fail cleanly (bounded, no hang)
# if the service genuinely stays loaded.

REPO_ROOT="$(cd "$(dirname "$0")/../../.." && pwd)"
INSTALL_SH="$REPO_ROOT/phase3-binary/dist/install.sh"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

python3 - "$INSTALL_SH" > "$TMP/functions.sh" <<'PY'
import sys

names = ["recovery_failed", "service_loaded", "service_identity_matches", "stop_loaded_service"]
lines = open(sys.argv[1], encoding="utf-8").read().splitlines()
for name in names:
    found = False
    for index, line in enumerate(lines):
        if not line.startswith(name + "()"):
            continue
        found = True
        depth = 0
        for body_line in lines[index:]:
            print(body_line)
            depth += body_line.count("{") - body_line.count("}")
            if depth == 0:
                break
        break
    if not found:
        raise SystemExit(f"{name} not found")
PY

[ -s "$TMP/functions.sh" ] || { echo "failed to extract recover.sh helpers" >&2; exit 1; }

LABEL="live.malibu.provider"
PLIST="/Library/LaunchDaemons/live.malibu.provider.plist"
PROGRAM="/Users/example/.local/bin/macprovider-cli"

# Harness: mock recovery_launchctl. "print" reports the service as loaded (exit
# 0 + a valid identity block matching PROGRAM/PLIST) for the first
# PRINT_LOADED_CALLS invocations, then reports it unloaded (exit 1). "bootout"
# is logged and succeeds. sleep is a no-op so the settle loop runs instantly.
run_stop() {
  print_loaded_calls="$1"
  identity_program="$2"
  arg_shape="${3:-6}"   # 6 = provider (2 alternates + message); 5 = legacy/watchdog (1 alternate + message)
  : > "$TMP/calls.log"
  printf '%s\n' "$print_loaded_calls" > "$TMP/print-remaining"
  PATH="/usr/bin:/bin" \
  CALLS_LOG="$TMP/calls.log" PRINT_REMAINING_FILE="$TMP/print-remaining" \
  FUNCTION_PATH="$TMP/functions.sh" RECOVERY_DIR="$TMP" \
  REC_LAUNCHD_DOMAIN="system" ARG_SHAPE="$arg_shape" \
  IDENTITY_PROGRAM="$identity_program" IDENTITY_PATH="$PLIST" \
  LABEL="$LABEL" PLIST="$PLIST" PROGRAM="$PROGRAM" \
  bash -c '
    set -uo pipefail
    recovery_log() { printf "%s\n" "$*" >> "$CALLS_LOG.log"; }
    sleep() { :; }
    recovery_launchctl() {
      verb="$1"
      printf "%s\n" "$verb" >> "$CALLS_LOG"
      case "$verb" in
        print)
          remaining="$(cat "$PRINT_REMAINING_FILE")"
          if [ "$remaining" -gt 0 ]; then
            printf "%s\n" "$((remaining - 1))" > "$PRINT_REMAINING_FILE"
            printf "\tprogram = %s\n\tpath = %s\n" "$IDENTITY_PROGRAM" "$IDENTITY_PATH"
            return 0
          fi
          return 1
          ;;
        bootout) return 0 ;;
        *) return 0 ;;
      esac
    }
    # shellcheck disable=SC1090
    source "$FUNCTION_PATH"
    if [ "$ARG_SHAPE" = "5" ]; then
      # Legacy/watchdog call shape: one alternate program, then the message.
      stop_loaded_service "$LABEL" "$PLIST" "$PROGRAM" "" "the legacy service"
    else
      stop_loaded_service "$LABEL" "$PLIST" "$PROGRAM" "" "" "the transaction provider service"
    fi
  '
}

bootout_count() { grep -cx bootout "$TMP/calls.log" || true; }

# 1. RACE (the fix): service still reports loaded for a few polls after bootout,
#    then unloads. stop_loaded_service must settle and succeed (exit 0), having
#    booted out exactly once -- NOT trip recovery_failed.
#    2 loaded calls consumed before the settle loop (service_loaded +
#    service_identity_matches), then 3 more loaded settle polls, then unloaded.
if ! run_stop 5 "$PROGRAM" >/dev/null 2>&1; then
  echo "FAIL(race): stop_loaded_service reported failure while the service was still settling after bootout" >&2
  exit 1
fi
if [ "$(bootout_count)" -ne 1 ]; then
  echo "FAIL(race): expected exactly 1 bootout, saw $(bootout_count)" >&2
  exit 1
fi
# Regression guard: the pre-fix stop_loaded_service returned as soon as it booted
# out, leaving the service still reporting loaded (the settling window unspent),
# so the caller's post-bootout "still loaded?" assertion in recover.sh tripped.
# The fixed function must not return until the unload has actually settled.
remaining_after="$(cat "$TMP/print-remaining")"
if [ "$remaining_after" -ne 0 ]; then
  echo "FAIL(race): stop_loaded_service returned before the service finished unloading ($remaining_after loaded polls unspent); the caller's post-bootout assertion would still trip" >&2
  exit 1
fi

# 2. GENUINE FAILURE (preserved): service never unloads. stop_loaded_service
#    must give up cleanly (exit 70) after the bounded settle loop, not hang.
if run_stop 999 "$PROGRAM" >/dev/null 2>&1; then
  echo "FAIL(stuck): stop_loaded_service reported success even though the service stayed loaded after bootout" >&2
  exit 1
fi
rc=0
run_stop 999 "$PROGRAM" >/dev/null 2>&1 || rc=$?
if [ "$rc" -ne 70 ]; then
  echo "FAIL(stuck): expected recovery_failed exit 70 for a service that never unloads, saw $rc" >&2
  exit 1
fi

# 3. ALREADY UNLOADED (fast path): service not loaded from the start. Must
#    return 0 without booting anything out.
if ! run_stop 0 "$PROGRAM" >/dev/null 2>&1; then
  echo "FAIL(fastpath): stop_loaded_service failed for an already-unloaded service" >&2
  exit 1
fi
if [ "$(bootout_count)" -ne 0 ]; then
  echo "FAIL(fastpath): expected 0 bootouts for an already-unloaded service, saw $(bootout_count)" >&2
  exit 1
fi

# 4. IDENTITY MISMATCH (preserved): service loaded but with a foreign launchd
#    identity. Must recovery_failed (exit 70) and never bootout.
rc=0
run_stop 5 "/opt/foreign/macprovider-cli" >/dev/null 2>&1 || rc=$?
if [ "$rc" -ne 70 ]; then
  echo "FAIL(identity): expected recovery_failed exit 70 on an unexpected launchd identity, saw $rc" >&2
  exit 1
fi
if [ "$(bootout_count)" -ne 0 ]; then
  echo "FAIL(identity): must not bootout a service whose identity did not match, saw $(bootout_count)" >&2
  exit 1
fi

# 5. LEGACY/WATCHDOG 5-ARG SHAPE: the fix lives in the shared helper, which is
#    also called with the 5-argument (one-alternate) shape for legacy/watchdog
#    labels. The same settle-then-succeed behavior must hold there.
if ! run_stop 5 "$PROGRAM" 5 >/dev/null 2>&1; then
  echo "FAIL(5-arg): stop_loaded_service failed for the legacy/watchdog call shape while settling" >&2
  exit 1
fi
if [ "$(bootout_count)" -ne 1 ]; then
  echo "FAIL(5-arg): expected exactly 1 bootout for the legacy/watchdog shape, saw $(bootout_count)" >&2
  exit 1
fi
if [ "$(cat "$TMP/print-remaining")" -ne 0 ]; then
  echo "FAIL(5-arg): stop_loaded_service returned before the legacy/watchdog service finished unloading" >&2
  exit 1
fi

echo "install_recovery_bootout_settle: OK"
