#!/usr/bin/env bash
# Verifies #1301: stapler validate is advisory when Gatekeeper already accepted
# the package (online CloudKit/TLS/clock-skew must not die 4), and remains a
# fail-closed notarization gate when spctl was skipped. Checksum verification
# is unchanged and out of this unit.
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/../../.." && pwd)"
INSTALL_SH="$REPO_ROOT/phase3-binary/dist/install.sh"
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT

python3 - "$INSTALL_SH" > "$TMP/fn.sh" <<'PY'
import sys
lines = open(sys.argv[1], encoding="utf-8").read().splitlines()
# The fatal-message constant sits immediately above validate_package().
start = None
for i, line in enumerate(lines):
    if line.startswith("STAPLER_ONLINE_LOOKUP_HINT="):
        start = i
        break
    if line.startswith("validate_package()"):
        start = i
        break
if start is None:
    raise SystemExit("could not find validate_package")
depth = 0
started = False
for line in lines[start:]:
    print(line)
    depth += line.count("{") - line.count("}")
    if "{" in line:
        started = True
    if started and depth == 0:
        break
PY

grep -q '^validate_package()' "$TMP/fn.sh" || { echo "could not extract validate_package" >&2; exit 1; }
grep -q 'stapler_validate=advisory_online_lookup_failed' "$TMP/fn.sh" \
  || { echo "advisory stapler path missing from extracted function" >&2; exit 1; }

# run_validate <spctl-rc|skip> <stapler-rc|skip>
#   spctl-rc: 0 pass, nonzero fail, "skip" = spctl absent
#   stapler-rc: 0 pass, nonzero fail, "skip" = stapler/xcrun absent
run_validate() {
  local spctl_mode="$1" stapler_mode="$2"
  (
    set +e
    # shellcheck disable=SC1090,SC1091
    source "$TMP/fn.sh"
    asset_path="$TMP/fake.pkg"
    require_tool() { return 0; }
    log() { printf 'LOG:%s\n' "$*"; }
    die() { code="$1"; shift; printf 'DIE:%s:%s\n' "$code" "$*"; exit "$code"; }
    command() {
      if [ "${1:-}" = "-v" ]; then
        case "${2:-}" in
          spctl)
            [ "$spctl_mode" != "skip" ] && return 0
            return 1
            ;;
          xcrun)
            [ "$stapler_mode" != "skip" ] && return 0
            return 1
            ;;
          *) builtin command "$@" ;;
        esac
      fi
      builtin command "$@"
    }
    spctl() {
      return "$spctl_mode"
    }
    xcrun() {
      if [ "${1:-}" = "--find" ] && [ "${2:-}" = "stapler" ]; then
        [ "$stapler_mode" != "skip" ] && return 0
        return 1
      fi
      if [ "${1:-}" = "stapler" ] && [ "${2:-}" = "validate" ]; then
        if [ "$stapler_mode" = "0" ]; then
          printf 'The validate action worked!\n'
          return 0
        fi
        printf '%s\n' \
          'A TLS error caused the secure connection to fail.' \
          "CloudKit's response is inconsistent with expectations: (null)" \
          'The validate action failed! Error 68.' >&2
        return "$stapler_mode"
      fi
      return 0
    }
    validate_package && printf 'OK\n'
  )
}

fail() { echo "FAIL: $*" >&2; exit 1; }

# A) spctl pass + stapler online-fail → install proceeds with advisory (the live bug).
out="$(run_validate 0 68 || true)"
printf '%s\n' "$out" | grep -q 'stapler_validate=advisory_online_lookup_failed' \
  || fail "A: expected advisory sublabel, got: $out"
printf '%s\n' "$out" | grep -q 'TLS/CloudKit' \
  || fail "A: advisory should name TLS/CloudKit, got: $out"
printf '%s\n' "$out" | grep -q '^OK$' \
  || fail "A: expected OK after Gatekeeper pass, got: $out"
printf '%s\n' "$out" | grep -q '^DIE:' \
  && fail "A: must not die 4 when Gatekeeper passed, got: $out"

# B) spctl skipped + stapler fail → fail closed with the clock/VPN recovery message.
out="$(run_validate skip 68 || true)"
printf '%s\n' "$out" | grep -q '^DIE:4:' \
  || fail "B: expected DIE:4, got: $out"
printf '%s\n' "$out" | grep -q 'date & time' \
  || fail "B: fatal message must mention date & time, got: $out"
printf '%s\n' "$out" | grep -q 'VPN/proxy' \
  || fail "B: fatal message must mention VPN/proxy, got: $out"
printf '%s\n' "$out" | grep -q 'Retry' \
  || fail "B: fatal message must tell the provider to Retry, got: $out"
printf '%s\n' "$out" | grep -q '^OK$' \
  && fail "B: must not succeed when notarization cannot be established, got: $out"

# C) spctl fail → still die 4 on Gatekeeper; stapler is not a substitute pass.
out="$(run_validate 1 0 || true)"
printf '%s\n' "$out" | grep -q '^DIE:4:package failed Gatekeeper assessment' \
  || fail "C: Gatekeeper failure must still die 4, got: $out"
printf '%s\n' "$out" | grep -q '^OK$' \
  && fail "C: must not succeed after Gatekeeper reject, got: $out"

# D) both pass → stapler success log, no advisory, no die.
out="$(run_validate 0 0 || true)"
printf '%s\n' "$out" | grep -q 'Package stapler validation passed' \
  || fail "D: expected stapler passed log, got: $out"
printf '%s\n' "$out" | grep -q 'advisory_online_lookup_failed' \
  && fail "D: healthy path must not log advisory, got: $out"
printf '%s\n' "$out" | grep -q '^OK$' \
  || fail "D: expected OK, got: $out"

# E) stapler absent after Gatekeeper pass → skip, do not die.
out="$(run_validate 0 skip || true)"
printf '%s\n' "$out" | grep -q 'stapler not found' \
  || fail "E: expected stapler-skipped log, got: $out"
printf '%s\n' "$out" | grep -q '^OK$' \
  || fail "E: expected OK when stapler is absent after Gatekeeper pass, got: $out"

# F) spctl skipped + stapler pass → stapler remains the notarization gate (succeeds).
out="$(run_validate skip 0 || true)"
printf '%s\n' "$out" | grep -q 'Package stapler validation passed' \
  || fail "F: expected stapler passed when it is the only gate, got: $out"
printf '%s\n' "$out" | grep -q '^OK$' \
  || fail "F: expected OK, got: $out"
printf '%s\n' "$out" | grep -q '^DIE:' \
  && fail "F: must not die when stapler establishes notarization, got: $out"

# G) both tools missing → fail closed (checksum-only is not enough for .pkg).
out="$(run_validate skip skip || true)"
printf '%s\n' "$out" | grep -q '^DIE:4:' \
  || fail "G: expected DIE:4 when neither Gatekeeper nor stapler can run, got: $out"
printf '%s\n' "$out" | grep -q 'spctl and stapler were not found' \
  || fail "G: fatal message must name both missing tools, got: $out"
printf '%s\n' "$out" | grep -q 'Retry' \
  || fail "G: fatal message must tell the provider to Retry, got: $out"
printf '%s\n' "$out" | grep -q '^OK$' \
  && fail "G: must not succeed without a notarization gate, got: $out"

echo "install stapler validate ok"
