#!/usr/bin/env bash
# Verifies the #1285/#1286 python3/CLT guard. A stock Mac whose only python3 is
# the non-functional Command Line Tools stub, OR a Mac whose python3 is broken or
# blocking (e.g. a hung shim earlier in PATH — the public-installer bypass the
# final audit reproduced), must FAIL FAST with exit 8 (mapped by Malibu to an
# actionable "install developer tools" message) instead of hanging. A Mac with a
# real, working python3 must NOT be blocked. In headless mode the system root
# interpreter (/usr/bin/python3, run as root) must also be proven usable.
set -euo pipefail
REPO_ROOT="$(cd "$(dirname "$0")/../../.." && pwd)"
INSTALL_SH="$REPO_ROOT/phase3-binary/dist/install.sh"
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT

# Extract all three guard functions (probe + per-interpreter check + entrypoint).
awk '/^_python3_runs_quickly\(\)/{cap=1}
     cap{print}
     /^ensure_python3_usable\(\)/{inlast=1}
     cap && inlast && /^}$/{exit}' "$INSTALL_SH" > "$TMP/guard.sh"
grep -q '^_python3_runs_quickly()' "$TMP/guard.sh" || { echo "could not extract _python3_runs_quickly" >&2; exit 1; }
grep -q '^ensure_python3_usable()' "$TMP/guard.sh" || { echo "could not extract ensure_python3_usable" >&2; exit 1; }
printf 'die() { echo "DIE:$1"; exit "$1"; }\n' >> "$TMP/guard.sh"

# Real executable python3 shims the probe can actually run.
GOOD="$TMP/good-python3"; printf '#!/bin/sh\nexit 0\n' > "$GOOD"; chmod +x "$GOOD"
BROKEN="$TMP/broken-python3"; printf '#!/bin/sh\nexit 1\n' > "$BROKEN"; chmod +x "$BROKEN"
BLOCK="$TMP/blocking-python3"; printf '#!/bin/sh\nsleep 3600\n' > "$BLOCK"; chmod +x "$BLOCK"

# A real developer dir that actually contains an executable python3.
DEVDIR="$TMP/devdir"; mkdir -p "$DEVDIR/usr/bin"
printf '#!/bin/sh\nexit 0\n' > "$DEVDIR/usr/bin/python3"; chmod +x "$DEVDIR/usr/bin/python3"

expect() { # <label> <actual> <expected>
  [ "$2" = "$3" ] || { echo "$1: expected '$3', got '$2'" >&2; exit 1; }
}

# ── Part 1: path / CLT gating (probe stubbed OK to isolate the branch logic) ──
# run_guard <py-path> <xcodeselect-p-output> <xcodeselect-p-rc> [HEADLESS] [ROOT_PY]
run_guard() {
  local pypath="$1" xp_out="$2" xp_rc="$3" hl="${4:-0}" rootpy="${5:-/usr/bin/python3}"
  (
    set +e
    source "$TMP/guard.sh"
    _python3_runs_quickly() { return 0; }   # isolate gating from execution
    command() { if [ "${1:-}" = "-v" ] && [ "${2:-}" = "python3" ]; then printf '%s\n' "$pypath"; return 0; fi; builtin command "$@"; }
    xcode-select() {
      case "${1:-}" in
        -p|--print-path) [ -n "$xp_out" ] && printf '%s\n' "$xp_out"; return "$xp_rc" ;;
        --install) return 0 ;;
        *) return 0 ;;
      esac
    }
    HEADLESS="$hl"; ROOT_PYTHON3_BIN="$rootpy"
    ensure_python3_usable && echo "OK"
  )
}

# A) real python3 elsewhere -> accepted
expect "A real-python3"      "$(run_guard "$GOOD" "" 0)"          "OK"
# B) /usr/bin/python3 stub + NO developer dir -> die 8
expect "B stub-no-CLT"       "$(run_guard /usr/bin/python3 "" 2 1)" "DIE:8"
# C) /usr/bin/python3 + valid developer dir -> accepted
expect "C CLT-backed"        "$(run_guard /usr/bin/python3 "$DEVDIR" 0)" "OK"
# D) /usr/bin/python3 + STALE developer dir -> die 8
expect "D stale-devdir"      "$(run_guard /usr/bin/python3 "$TMP/gone-devdir" 0 1)" "DIE:8"
# E) no python3 at all -> die 8
expect "E no-python3"        "$(run_guard "" "" 2 1)"             "DIE:8"

# ── Part 2: the real bounded probe (good / broken / blocking) ────────────────
probe_rc() { ( set +e; source "$TMP/guard.sh"; MACPROVIDER_PY_PROBE_BUDGET=2 _python3_runs_quickly "$1" 2>/dev/null; echo $? ) ; }
expect "P good-exec"     "$(probe_rc "$GOOD")"   "0"
expect "P broken-exec"   "$(probe_rc "$BROKEN")" "1"
expect "P blocking-exec" "$(probe_rc "$BLOCK")"  "124"   # times out, not hangs

# ── Part 3: HIGH — a blocking non-system python3 dies 8 (does NOT hang) ───────
run_guard_probe() { # <py-path> [HEADLESS] [ROOT_PY]  (real probe, small budget)
  local pypath="$1" hl="${2:-0}" rootpy="${3:-/usr/bin/python3}"
  (
    set +e
    source "$TMP/guard.sh"
    command() { if [ "${1:-}" = "-v" ] && [ "${2:-}" = "python3" ]; then printf '%s\n' "$pypath"; return 0; fi; builtin command "$@"; }
    xcode-select() { case "${1:-}" in --install) return 0;; *) return 0;; esac; }
    MACPROVIDER_PY_PROBE_BUDGET=2; HEADLESS="$hl"; ROOT_PYTHON3_BIN="$rootpy"
    ensure_python3_usable 2>/dev/null && echo "OK"
  )
}
expect "H1 blocking-nonsystem" "$(run_guard_probe "$BLOCK")" "DIE:8"
expect "H2 good-nonsystem"     "$(run_guard_probe "$GOOD")"  "OK"

# ── Part 4: MEDIUM — headless root interpreter validated independently ────────
# User python3 is a good non-system interpreter, but the system root interpreter
# (ROOT_PYTHON3_BIN) is blocking -> die 8 (would otherwise wedge root helpers).
expect "M1 headless-root-blocking" "$(run_guard_probe "$GOOD" 1 "$BLOCK")" "DIE:8"
expect "M2 headless-root-good"     "$(run_guard_probe "$GOOD" 1 "$GOOD")"  "OK"

# ── Part 5: ordering — guard runs before validate_install_dir (first python3) ─
grep -Eq 'ensure_python3_usable' "$INSTALL_SH" || { echo "guard not wired into installer" >&2; exit 1; }
python3 - "$INSTALL_SH" <<'PY'
import sys
s = open(sys.argv[1]).read()
main = s[s.rindex("\nmain() {"):]
assert main.index("ensure_python3_usable") < main.index("validate_install_dir"), \
    "guard must run before validate_install_dir (first python3 user)"
assert "python3" not in main[main.index("for tool in"):main.index("done", main.index("for tool in"))], \
    "python3 must not be in the generic require_tool loop"
print("order ok")
PY

echo "python3/CLT guard ok"
