#!/usr/bin/env bash
# Verifies the #1285/#1286 python3/CLT-stub guard: a stock Mac whose only python3
# is the non-functional Command Line Tools stub must FAIL FAST with exit 8
# (mapped by Malibu to an actionable "install developer tools" message) instead
# of hanging on the hidden CLT install dialog — and must NOT block a Mac that has
# a real, working python3.
set -euo pipefail
REPO_ROOT="$(cd "$(dirname "$0")/../../.." && pwd)"
INSTALL_SH="$REPO_ROOT/phase3-binary/dist/install.sh"
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT

awk '/^ensure_python3_usable\(\)/{i=1} i{print} i&&/^}$/{exit}' "$INSTALL_SH" > "$TMP/guard.sh"
[ -s "$TMP/guard.sh" ] || { echo "could not extract ensure_python3_usable" >&2; exit 1; }
printf 'die() { echo "DIE:$1"; exit "$1"; }\n' >> "$TMP/guard.sh"

# A real developer dir that actually contains an executable python3.
DEVDIR="$TMP/devdir"; mkdir -p "$DEVDIR/usr/bin"
printf '#!/bin/sh\n' > "$DEVDIR/usr/bin/python3"; chmod +x "$DEVDIR/usr/bin/python3"

# run_guard <py-path> <xcodeselect-p-output-or-empty> <xcodeselect-p-rc> [HEADLESS]
# Echoes the guard's outcome: "OK" (returned 0) or "DIE:<code>".
run_guard() {
  local pypath="$1" xp_out="$2" xp_rc="$3" hl="${4:-0}"
  (
    set +e
    source "$TMP/guard.sh"
    command() { if [ "${1:-}" = "-v" ] && [ "${2:-}" = "python3" ]; then printf '%s\n' "$pypath"; return 0; fi; builtin command "$@"; }
    xcode-select() {
      case "${1:-}" in
        -p|--print-path) [ -n "$xp_out" ] && printf '%s\n' "$xp_out"; return "$xp_rc" ;;
        --install) return 0 ;;
        *) return 0 ;;
      esac
    }
    HEADLESS="$hl"
    ensure_python3_usable && echo "OK"
  )
}

expect() { # <label> <actual> <expected>
  [ "$2" = "$3" ] || { echo "$1: expected '$3', got '$2'" >&2; exit 1; }
}

# A) real python3 elsewhere (Homebrew/python.org) -> accepted
expect "A real-python3" "$(run_guard /opt/homebrew/bin/python3 "" 0)" "OK"

# B) /usr/bin/python3 stub + NO developer dir selected -> die 8
expect "B stub-no-CLT" "$(run_guard /usr/bin/python3 "" 2 1)" "DIE:8"

# C) /usr/bin/python3 + a developer dir that actually contains python3 -> accepted
expect "C CLT-backed" "$(run_guard /usr/bin/python3 "$DEVDIR" 0)" "OK"

# D) /usr/bin/python3 + STALE developer dir (selected path has no python3) -> die 8
expect "D stale-devdir" "$(run_guard /usr/bin/python3 "$TMP/gone-devdir" 0 1)" "DIE:8"

# E) no python3 at all -> die 8
expect "E no-python3" "$(run_guard "" "" 2 1)" "DIE:8"

# F) main() calls the guard before the first python3 user (validate_install_dir)
grep -Eq 'ensure_python3_usable' "$INSTALL_SH" || { echo "F: guard not wired into installer" >&2; exit 1; }
python3 - "$INSTALL_SH" <<'PY'
import sys
s = open(sys.argv[1]).read()
main = s[s.rindex("\nmain() {"):]
assert main.index("ensure_python3_usable") < main.index("validate_install_dir"), \
    "guard must run before validate_install_dir (first python3 user)"
print("order ok")
PY

echo "python3/CLT guard ok"
