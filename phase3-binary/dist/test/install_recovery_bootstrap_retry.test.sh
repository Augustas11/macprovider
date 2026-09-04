#!/usr/bin/env bash
set -euo pipefail

# F6 (#1364): launchctl bootstrap can transiently return "Input/output error"
# on a launchd domain that is briefly refusing new services. A single failed
# bootstrap used to trip recovery_failed -> exit 70, leaving the provider down
# and a preserved bundle that hard-blocked the next install. recovery_bootstrap_service
# must retry with backoff, boot out any partial load between attempts, and only
# give up (non-zero, no hang) after a bounded number of attempts.
#
# It must NOT accept an already-loaded label as success (a same-user process
# could have bootstrapped a foreign plist under it, and the caller kickstarts
# before verifying identity — audit security MEDIUM), and a malformed attempts
# override must not cause an unbounded loop (audit code MEDIUM).

REPO_ROOT="$(cd "$(dirname "$0")/../../.." && pwd)"
INSTALL_SH="$REPO_ROOT/phase3-binary/dist/install.sh"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

python3 - "$INSTALL_SH" > "$TMP/function.sh" <<'PY'
import sys

names = ["recovery_positive_int", "recovery_bootstrap_service"]
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

[ -s "$TMP/function.sh" ] || { echo "failed to extract recovery helpers" >&2; exit 1; }

# Harness: a mock recovery_launchctl whose bootstrap behavior is scripted
# per-call through BOOTSTRAP_PLAN ("ok" -> exit 0, anything else -> exit 5, the
# launchd I/O error code), plus a call log. print returns PRINT_RC; bootout is
# recorded and succeeds. A hard ceiling of 20 bootstrap calls converts a
# regressed infinite loop into a clean, assertable failure instead of a hang.
run_bootstrap() {
  bootstrap_plan="$1"
  print_rc="$2"
  attempts_override="$3"
  : > "$TMP/calls.log"
  printf '%s\n' "$bootstrap_plan" > "$TMP/bootstrap-plan"
  PATH="/usr/bin:/bin" \
  CALLS_LOG="$TMP/calls.log" BOOTSTRAP_PLAN_FILE="$TMP/bootstrap-plan" PRINT_RC="$print_rc" \
  FUNCTION_PATH="$TMP/function.sh" ATTEMPTS_OVERRIDE="$attempts_override" bash -c '
    set -uo pipefail
    recovery_log() { :; }
    recovery_launchctl() {
      verb="$1"
      printf "%s\n" "$verb" >> "$CALLS_LOG"
      case "$verb" in
        bootstrap)
          if [ "$(grep -cx bootstrap "$CALLS_LOG")" -gt 20 ]; then exit 99; fi
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
    MACPROVIDER_RECOVERY_BOOTSTRAP_ATTEMPTS="$ATTEMPTS_OVERRIDE"
    MACPROVIDER_RECOVERY_BOOTSTRAP_BACKOFF_SECONDS=0
    source "$FUNCTION_PATH"
    recovery_bootstrap_service system /Library/LaunchDaemons/live.malibu.provider.plist live.malibu.provider
  '
}

bootstrap_count() { grep -cx bootstrap "$TMP/calls.log"; }

# 1. Transient I/O error clears on retry: bootstrap fails twice, succeeds third.
if ! run_bootstrap "$(printf 'fail\nfail\nok')" 1 5; then
  echo "recovery_bootstrap_service did not recover a transient bootstrap I/O error" >&2
  exit 1
fi
if ! grep -qx bootout "$TMP/calls.log"; then
  echo "recovery_bootstrap_service did not bootout a partial load between retries" >&2
  exit 1
fi
if [ "$(bootstrap_count)" -ne 3 ]; then
  echo "expected 3 bootstrap attempts before success, saw $(bootstrap_count)" >&2
  exit 1
fi

# 2. Security: an already-loaded label (print would succeed) must NOT be treated
#    as success. bootstrap never returns ok, so the helper must give up rather
#    than accept whatever foreign plist happens to be loaded under the label.
if run_bootstrap "$(printf 'fail\nfail\nfail')" 0 3; then
  echo "recovery_bootstrap_service accepted an already-loaded label without a successful bootstrap of the expected plist" >&2
  exit 1
fi
if [ "$(bootstrap_count)" -ne 3 ]; then
  echo "expected exactly 3 bootstrap attempts (already-loaded path), saw $(bootstrap_count)" >&2
  exit 1
fi

# 3. Persistent failure gives up cleanly (non-zero) after the bounded attempts
#    with print never consulted for success.
if run_bootstrap "$(printf 'fail\nfail\nfail\nfail')" 1 4; then
  echo "recovery_bootstrap_service reported success despite a persistent bootstrap failure" >&2
  exit 1
fi
if [ "$(bootstrap_count)" -ne 4 ]; then
  echo "expected exactly 4 bootstrap attempts before giving up, saw $(bootstrap_count)" >&2
  exit 1
fi

# 4. Code: a malformed attempts override must not spin forever — it falls back
#    to the default (5) and gives up. The 20-call ceiling would surface a
#    regressed unbounded loop as a count far above 5.
for bad in abc "" 0 -3; do
  if run_bootstrap "$(printf 'fail')" 1 "$bad"; then
    echo "recovery_bootstrap_service reported success with attempts override '$bad'" >&2
    exit 1
  fi
  if [ "$(bootstrap_count)" -ne 5 ]; then
    echo "malformed attempts override '$bad' did not fall back to 5 bounded attempts (saw $(bootstrap_count))" >&2
    exit 1
  fi
done

# A leading-zero value is decoded as decimal (08 -> 8), not treated as octal and
# not rejected: it must produce exactly 8 bounded attempts.
if run_bootstrap "$(printf 'fail')" 1 08; then
  echo "recovery_bootstrap_service reported success with attempts override '08'" >&2
  exit 1
fi
if [ "$(bootstrap_count)" -ne 8 ]; then
  echo "attempts override '08' did not decode to 8 bounded attempts (saw $(bootstrap_count))" >&2
  exit 1
fi

# A valid-but-huge attempts override is clamped to the sane maximum (20), not
# run literally — a fat-fingered value must not schedule a near-infinite loop.
if run_bootstrap "$(printf 'fail')" 1 999999; then
  echo "recovery_bootstrap_service reported success with a huge attempts override" >&2
  exit 1
fi
if [ "$(bootstrap_count)" -ne 20 ]; then
  echo "attempts override 999999 was not clamped to 20 (saw $(bootstrap_count))" >&2
  exit 1
fi

# recovery_positive_int itself: fallbacks and clamps.
positive_int_check() {
  PATH="/usr/bin:/bin" FUNCTION_PATH="$TMP/function.sh" bash -c '
    set -uo pipefail
    source "$FUNCTION_PATH"
    recovery_positive_int "$1" "$2" "${3:-}" "${4:-}"
  ' _ "$1" "$2" "${3:-}" "${4:-}"
}
[ "$(positive_int_check abc 5)" = "5" ] || { echo "positive_int abc did not fall back" >&2; exit 1; }
[ "$(positive_int_check 08 5)" = "8" ] || { echo "positive_int 08 not decoded as decimal 8" >&2; exit 1; }
[ "$(positive_int_check 0 5)" = "5" ] || { echo "positive_int 0 not rejected without allow_zero" >&2; exit 1; }
[ "$(positive_int_check 0 2 allow_zero)" = "0" ] || { echo "positive_int 0 not allowed with allow_zero" >&2; exit 1; }
[ "$(positive_int_check 12345678901 5)" = "5" ] || { echo "positive_int over-length not rejected" >&2; exit 1; }
[ "$(positive_int_check 42 5)" = "42" ] || { echo "positive_int passthrough failed" >&2; exit 1; }
[ "$(positive_int_check 999 5 '' 20)" = "20" ] || { echo "positive_int not clamped to maximum" >&2; exit 1; }
[ "$(positive_int_check 15 5 '' 20)" = "15" ] || { echo "positive_int under-max value altered" >&2; exit 1; }

# The main rollback bootstrap sites route through recovery_bootstrap_service and
# degrade via recovery_bootstrap_failed (which preserves recover.sh + gives the
# re-login/reboot remediation), never a bare recovery_launchctl bootstrap.
python3 - "$INSTALL_SH" <<'PY'
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
