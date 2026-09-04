#!/usr/bin/env bash
set -euo pipefail

# F6 (#1364): launchctl bootstrap can transiently return "Input/output error"
# on a launchd domain that is briefly refusing new services. A single failed
# bootstrap used to trip recovery_failed -> exit 70, leaving the provider down
# and a preserved bundle that hard-blocked the next install. recovery_bootstrap_service
# must retry with backoff, boot out any partial load between attempts, treat an
# already-loaded label as success, and only give up (non-zero, no hang) after a
# bounded number of attempts.

REPO_ROOT="$(cd "$(dirname "$0")/../../.." && pwd)"
INSTALL_SH="$REPO_ROOT/phase3-binary/dist/install.sh"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

python3 - "$INSTALL_SH" > "$TMP/function.sh" <<'PY'
import sys

name = "recovery_bootstrap_service"
lines = open(sys.argv[1], encoding="utf-8").read().splitlines()
for index, line in enumerate(lines):
    if not line.startswith(name + "()"):
        continue
    depth = 0
    for body_line in lines[index:]:
        print(body_line)
        depth += body_line.count("{") - body_line.count("}")
        if depth == 0:
            raise SystemExit(0)
raise SystemExit("recovery_bootstrap_service not found")
PY

[ -s "$TMP/function.sh" ] || { echo "failed to extract recovery_bootstrap_service" >&2; exit 1; }

# Harness: a mock recovery_launchctl whose behavior is scripted per-verb through
# files, plus a call log. bootstrap consumes one line of BOOTSTRAP_PLAN each
# call ("ok" -> exit 0, anything else -> exit 5, the launchd I/O error code);
# print returns PRINT_RC; bootout is always recorded and succeeds.
run_bootstrap() {
  bootstrap_plan="$1"
  print_rc="$2"
  max_attempts="$3"
  : > "$TMP/calls.log"
  printf '%s\n' "$bootstrap_plan" > "$TMP/bootstrap-plan"
  PATH="/usr/bin:/bin" \
  CALLS_LOG="$TMP/calls.log" BOOTSTRAP_PLAN_FILE="$TMP/bootstrap-plan" PRINT_RC="$print_rc" \
  FUNCTION_PATH="$TMP/function.sh" MAX_ATTEMPTS="$max_attempts" bash -c '
    set -uo pipefail
    recovery_log() { :; }
    recovery_launchctl() {
      verb="$1"
      printf "%s\n" "$verb" >> "$CALLS_LOG"
      case "$verb" in
        bootstrap)
          plan_line="$(sed -n "1p" "$BOOTSTRAP_PLAN_FILE")"
          sed -i.bak "1d" "$BOOTSTRAP_PLAN_FILE" 2>/dev/null || true
          [ "$plan_line" = "ok" ] && return 0
          return 5
          ;;
        print) return "$PRINT_RC" ;;
        bootout) return 0 ;;
        *) return 0 ;;
      esac
    }
    MACPROVIDER_RECOVERY_BOOTSTRAP_ATTEMPTS="$MAX_ATTEMPTS"
    MACPROVIDER_RECOVERY_BOOTSTRAP_BACKOFF_SECONDS=0
    source "$FUNCTION_PATH"
    recovery_bootstrap_service system /Library/LaunchDaemons/live.malibu.provider.plist live.malibu.provider
  '
}

# 1. Transient I/O error clears on retry: bootstrap fails twice, succeeds third.
if ! run_bootstrap "$(printf 'fail\nfail\nok')" 1 5; then
  echo "recovery_bootstrap_service did not recover a transient bootstrap I/O error" >&2
  exit 1
fi
# It must have booted out the partial load between the failed attempts.
if ! grep -qx bootout "$TMP/calls.log"; then
  echo "recovery_bootstrap_service did not bootout a partial load between retries" >&2
  exit 1
fi
bootstrap_calls="$(grep -cx bootstrap "$TMP/calls.log")"
if [ "$bootstrap_calls" -ne 3 ]; then
  echo "expected 3 bootstrap attempts before success, saw $bootstrap_calls" >&2
  exit 1
fi

# 2. Already-loaded label (print succeeds) is treated as success without needing
#    a further bootstrap to report ok.
if ! run_bootstrap "$(printf 'fail')" 0 5; then
  echo "recovery_bootstrap_service failed even though the label was already loaded" >&2
  exit 1
fi

# 3. Persistent failure gives up cleanly (non-zero) after the bounded attempts
#    and does not hang. print never succeeds either.
if run_bootstrap "$(printf 'fail\nfail\nfail')" 1 3; then
  echo "recovery_bootstrap_service reported success despite a persistent bootstrap failure" >&2
  exit 1
fi
give_up_calls="$(grep -cx bootstrap "$TMP/calls.log")"
if [ "$give_up_calls" -ne 3 ]; then
  echo "expected exactly 3 bootstrap attempts before giving up, saw $give_up_calls" >&2
  exit 1
fi

# The main rollback bootstrap sites route through recovery_bootstrap_service and
# degrade via recovery_bootstrap_failed (which preserves recover.sh + gives the
# re-login/reboot remediation), never a bare recovery_launchctl bootstrap.
python3 - "$INSTALL_SH" <<'PY'
import re
import sys

text = open(sys.argv[1], encoding="utf-8").read()
for label in (
    "could not bootstrap the previous provider service",
    "could not bootstrap the previous legacy provider service",
    "could not bootstrap the previous watchdog service",
    "could not bootstrap the previous legacy watchdog service",
):
    idx = text.index(label)
    line_start = text.rfind("\n", 0, idx) + 1
    line = text[line_start:text.index("\n", idx)]
    if "recovery_bootstrap_service" not in line or "recovery_bootstrap_failed" not in line:
        raise SystemExit(f"rollback bootstrap site not routed through retry helper: {label}")
if "Log out and back in (or reboot)" not in text:
    raise SystemExit("recovery_bootstrap_failed lost its re-login/reboot remediation")
PY

echo "install_recovery_bootstrap_retry.test.sh: PASS"
