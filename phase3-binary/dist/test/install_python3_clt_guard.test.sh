#!/usr/bin/env bash
# Verifies the #1285/#1286/#1575 python3/CLT guard. A stock Mac whose only
# python3 is the Command Line Tools stub must bootstrap a pinned standalone
# interpreter instead of hanging or requiring a GUI click. A broken/blocking
# PATH shim must still FAIL FAST with exit 8. A Mac with a real python3 must
# NOT be blocked. In headless mode a CLT stub at /usr/bin/python3 is replaced
# by the same verified interpreter rather than requiring CLT.
set -euo pipefail
REPO_ROOT="$(cd "$(dirname "$0")/../../.." && pwd)"
INSTALL_SH="$REPO_ROOT/phase3-binary/dist/install.sh"
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT

# Extract stub detection, bootstrap, probe, per-interpreter check, and entrypoint.
awk '/^_python3_is_clt_stub\(\)/{cap=1}
     cap{print}
     /^ensure_python3_usable\(\)/{inlast=1}
     cap && inlast && /^}$/{exit}' "$INSTALL_SH" > "$TMP/guard.sh"
grep -q '^_python3_is_clt_stub()' "$TMP/guard.sh" || { echo "could not extract _python3_is_clt_stub" >&2; exit 1; }
grep -q '^bootstrap_standalone_python3()' "$TMP/guard.sh" || { echo "could not extract bootstrap_standalone_python3" >&2; exit 1; }
grep -q '^_python3_runs_quickly()' "$TMP/guard.sh" || { echo "could not extract _python3_runs_quickly" >&2; exit 1; }
grep -q '^ensure_python3_usable()' "$TMP/guard.sh" || { echo "could not extract ensure_python3_usable" >&2; exit 1; }
printf 'die() { echo "DIE:$1"; exit "$1"; }\nlog() { :; }\n' >> "$TMP/guard.sh"

# Real executable python3 shims the probe can actually run.
GOOD="$TMP/good-python3"; printf '#!/bin/sh\nexit 0\n' > "$GOOD"; chmod +x "$GOOD"
BROKEN="$TMP/broken-python3"; printf '#!/bin/sh\nexit 1\n' > "$BROKEN"; chmod +x "$BROKEN"
BLOCK="$TMP/blocking-python3"; printf '#!/bin/sh\nsleep 3600\n' > "$BLOCK"; chmod +x "$BLOCK"
# Adversarial shim: exits 0 for `-c` (what a naive probe uses) but BLOCKS on `-`
# (stdin script mode — what the installer actually uses). Proves the probe must
# match the real invocation style. (round-3 HIGH)
STDINBLOCK="$TMP/stdinblock-python3"
printf '#!/bin/sh\ncase "${1:-}" in -c) exit 0 ;; *) sleep 3600 ;; esac\n' > "$STDINBLOCK"; chmod +x "$STDINBLOCK"

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
    HOME="$TMP/home"
    mkdir -p "$HOME"
    HEADLESS="$hl"; ROOT_PYTHON3_BIN="$rootpy"
    ROOT_INSTALL_PYTHON_DIR="$TMP/root-python"
    mkdir -p "$ROOT_INSTALL_PYTHON_DIR/bin"
    publish_root_install_python() {
      mkdir -p "$ROOT_INSTALL_PYTHON_DIR/bin"
      ln -sf "${INSTALL_PYTHON3:-$GOOD}" "$ROOT_INSTALL_PYTHON_DIR/bin/python3"
      return 0
    }
    # Default fail-closed unless a test explicitly supplies a bootstrap python.
    MACPROVIDER_PYTHON_BOOTSTRAP_DISABLE="${MACPROVIDER_PYTHON_BOOTSTRAP_DISABLE:-1}"
    MACPROVIDER_BOOTSTRAP_PYTHON3="${MACPROVIDER_BOOTSTRAP_PYTHON3:-}"
    MACPROVIDER_TEST_ALLOW_BOOTSTRAP_OVERRIDE="${MACPROVIDER_TEST_ALLOW_BOOTSTRAP_OVERRIDE:-0}"
    ensure_python3_usable && echo "OK"
  )
}

run_guard_vars() {
  local pypath="$1" xp_out="$2" xp_rc="$3" hl="${4:-0}" rootpy="${5:-/usr/bin/python3}"
  (
    set +e
    source "$TMP/guard.sh"
    _python3_runs_quickly() { return 0; }
    command() { if [ "${1:-}" = "-v" ] && [ "${2:-}" = "python3" ]; then printf '%s\n' "$pypath"; return 0; fi; builtin command "$@"; }
    xcode-select() {
      case "${1:-}" in
        -p|--print-path) [ -n "$xp_out" ] && printf '%s\n' "$xp_out"; return "$xp_rc" ;;
        --install) return 0 ;;
        *) return 0 ;;
      esac
    }
    HOME="$TMP/home"
    mkdir -p "$HOME"
    HEADLESS="$hl"; ROOT_PYTHON3_BIN="$rootpy"
    ROOT_INSTALL_PYTHON_DIR="$TMP/root-python"
    mkdir -p "$ROOT_INSTALL_PYTHON_DIR/bin"
    publish_root_install_python() {
      mkdir -p "$ROOT_INSTALL_PYTHON_DIR/bin"
      ln -sf "${INSTALL_PYTHON3:-$GOOD}" "$ROOT_INSTALL_PYTHON_DIR/bin/python3"
      return 0
    }
    MACPROVIDER_PYTHON_BOOTSTRAP_DISABLE="${MACPROVIDER_PYTHON_BOOTSTRAP_DISABLE:-1}"
    MACPROVIDER_BOOTSTRAP_PYTHON3="${MACPROVIDER_BOOTSTRAP_PYTHON3:-}"
    MACPROVIDER_TEST_ALLOW_BOOTSTRAP_OVERRIDE="${MACPROVIDER_TEST_ALLOW_BOOTSTRAP_OVERRIDE:-0}"
    ensure_python3_usable && printf 'OK ROOT=%s INSTALL=%s\n' "$ROOT_PYTHON3_BIN" "$INSTALL_PYTHON3"
  )
}

# A) real python3 elsewhere -> accepted
expect "A real-python3"      "$(run_guard "$GOOD" "" 0)"          "OK"
# B) /usr/bin/python3 stub + NO developer dir + bootstrap disabled -> die 8
expect "B stub-no-CLT"       "$(run_guard /usr/bin/python3 "" 2 1)" "DIE:8"
# B2) same stub, but a supplied standalone interpreter unblocks setup (#1575)
expect "B stub-bootstrap"    "$(MACPROVIDER_TEST_ALLOW_BOOTSTRAP_OVERRIDE=1 MACPROVIDER_PYTHON_BOOTSTRAP_DISABLE=0 MACPROVIDER_BOOTSTRAP_PYTHON3="$GOOD" run_guard /usr/bin/python3 "" 2 0)" "OK"
# C) /usr/bin/python3 + valid developer dir -> accepted
expect "C CLT-backed"        "$(run_guard /usr/bin/python3 "$DEVDIR" 0)" "OK"
# D) /usr/bin/python3 + STALE developer dir + bootstrap disabled -> die 8
expect "D stale-devdir"      "$(run_guard /usr/bin/python3 "$TMP/gone-devdir" 0 1)" "DIE:8"
# D2) stale developer dir + bootstrap -> accepted
expect "D stale-bootstrap"   "$(MACPROVIDER_TEST_ALLOW_BOOTSTRAP_OVERRIDE=1 MACPROVIDER_PYTHON_BOOTSTRAP_DISABLE=0 MACPROVIDER_BOOTSTRAP_PYTHON3="$GOOD" run_guard /usr/bin/python3 "$TMP/gone-devdir" 0 0)" "OK"
# E) no python3 at all + bootstrap disabled -> die 8
expect "E no-python3"        "$(run_guard "" "" 2 1)"             "DIE:8"
# E2) no python3 + bootstrap -> accepted
expect "E no-python-bootstrap" "$(MACPROVIDER_TEST_ALLOW_BOOTSTRAP_OVERRIDE=1 MACPROVIDER_PYTHON_BOOTSTRAP_DISABLE=0 MACPROVIDER_BOOTSTRAP_PYTHON3="$GOOD" run_guard "" "" 2 0)" "OK"

# ── Part 2: the real bounded probe (good / broken / blocking) ────────────────
probe_rc() { ( set +e; source "$TMP/guard.sh"; MACPROVIDER_PY_PROBE_BUDGET=2 _python3_runs_quickly "$1" 2>/dev/null; echo $? ) ; }
expect "P good-exec"       "$(probe_rc "$GOOD")"       "0"
expect "P broken-exec"     "$(probe_rc "$BROKEN")"     "1"
expect "P blocking-exec"   "$(probe_rc "$BLOCK")"      "124"   # times out, not hangs
expect "P stdin-blocking"  "$(probe_rc "$STDINBLOCK")" "124"   # -c passes but stdin blocks -> caught

# ── Part 3: HIGH — a blocking non-system python3 dies 8 (does NOT hang) ───────
run_guard_probe() { # <py-path> [HEADLESS] [ROOT_PY]  (real probe, small budget)
  local pypath="$1" hl="${2:-0}" rootpy="${3:-/usr/bin/python3}"
  (
    set +e
    source "$TMP/guard.sh"
    command() { if [ "${1:-}" = "-v" ] && [ "${2:-}" = "python3" ]; then printf '%s\n' "$pypath"; return 0; fi; builtin command "$@"; }
    xcode-select() { case "${1:-}" in --install) return 0;; *) return 0;; esac; }
    MACPROVIDER_PY_PROBE_BUDGET=2; HEADLESS="$hl"; ROOT_PYTHON3_BIN="$rootpy"
    MACPROVIDER_PYTHON_BOOTSTRAP_DISABLE=1
    ensure_python3_usable 2>/dev/null && echo "OK"
  )
}
expect "H1 blocking-nonsystem" "$(run_guard_probe "$BLOCK")"      "DIE:8"
expect "H2 good-nonsystem"     "$(run_guard_probe "$GOOD")"       "OK"
expect "H3 stdin-blocking"     "$(run_guard_probe "$STDINBLOCK")" "DIE:8"   # round-3 HIGH

# ── Part 4: MEDIUM — headless root interpreter validated independently ────────
# User python3 is a good non-system interpreter, but the system root interpreter
# (ROOT_PYTHON3_BIN) is blocking -> die 8 (would otherwise wedge root helpers).
expect "M1 headless-root-blocking" "$(run_guard_probe "$GOOD" 1 "$BLOCK")" "DIE:8"
expect "M2 headless-root-good"     "$(run_guard_probe "$GOOD" 1 "$GOOD")"  "OK"
# M3: headless + CLT stub at default ROOT /usr/bin/python3 + bootstrap python
# publishes a root-owned copy (stubbed here) rather than sudoing $HOME python.
m3="$(MACPROVIDER_TEST_ALLOW_BOOTSTRAP_OVERRIDE=1 MACPROVIDER_PYTHON_BOOTSTRAP_DISABLE=0 MACPROVIDER_BOOTSTRAP_PYTHON3="$GOOD" run_guard_vars /usr/bin/python3 "" 2 1)"
printf '%s\n' "$m3" | grep -Fq "ROOT=$TMP/root-python/bin/python3" \
  || { echo "M3: expected ROOT=$TMP/root-python/bin/python3, got '$m3'" >&2; exit 1; }
printf '%s\n' "$m3" | grep -Fq "INSTALL=$TMP/home/.local/share/macprovider/install-python/bin/python3" \
  || { echo "M3: expected shimed INSTALL under test HOME, got '$m3'" >&2; exit 1; }

# PATH prepend: bootstrapped python3 must win over /usr/bin/python3.
mkdir -p "$TMP/bootbin"
printf '#!/bin/sh\nexit 0\n' > "$TMP/bootbin/python3"
chmod +x "$TMP/bootbin/python3"
run_path_prepend() {
  (
    set +e
    source "$TMP/guard.sh"
    _python3_runs_quickly() { return 0; }
    xcode-select() {
      case "${1:-}" in
        -p|--print-path) return 2 ;;
        *) return 0 ;;
      esac
    }
    publish_root_install_python() { return 0; }
    HOME="$TMP/home"
    mkdir -p "$HOME"
    PATH="/usr/bin:/bin"
    MACPROVIDER_TEST_ALLOW_BOOTSTRAP_OVERRIDE=1
    MACPROVIDER_PYTHON_BOOTSTRAP_DISABLE=0
    MACPROVIDER_BOOTSTRAP_PYTHON3="$TMP/bootbin/python3"
    HEADLESS=0
    ROOT_PYTHON3_BIN=/usr/bin/python3
    command() { if [ "${1:-}" = "-v" ] && [ "${2:-}" = "python3" ]; then printf '%s\n' /usr/bin/python3; return 0; fi; builtin command "$@"; }
    ensure_python3_usable || exit 1
    builtin command -v python3
  )
}
expect "PATH prepend wins" "$(run_path_prepend)" "$TMP/bootbin/python3"

# ── Part 5: download+verify bootstrap (no network; fake tarball + curl) ──────
mkdir -p "$TMP/python/bin"
printf '#!/bin/sh\nexit 0\n' > "$TMP/python/bin/python3"
chmod +x "$TMP/python/bin/python3"
tar -czf "$TMP/py.tgz" -C "$TMP" python
GOOD_SHA="$(shasum -a 256 "$TMP/py.tgz" | awk '{print $1}')"
mkdir -p "$TMP/curlbin"
cat > "$TMP/curlbin/curl" <<EOF
#!/bin/sh
# Last arg is -o dest in the installer curl invocation.
dest=""
while [ \$# -gt 0 ]; do
  if [ "\$1" = "-o" ]; then
    dest="\$2"
    shift 2
    continue
  fi
  shift
done
[ -n "\$dest" ] || exit 1
cp "$TMP/py.tgz" "\$dest"
EOF
chmod +x "$TMP/curlbin/curl"

run_bootstrap_download() { # $1=expected-sha -> prints INSTALL_PYTHON3 or DIE:n
  local expected="$1"
  (
    set +e
    source "$TMP/guard.sh"
    HOME="$TMP/home"
    mkdir -p "$HOME"
    PATH="$TMP/curlbin:/usr/bin:/bin"
    MACPROVIDER_BOOTSTRAP_PYTHON3=""
    MACPROVIDER_PYTHON_BOOTSTRAP_DISABLE=0
    MACPROVIDER_TEST_ALLOW_BOOTSTRAP_OVERRIDE=1
    MACPROVIDER_BOOTSTRAP_PYTHON_URL="file://$TMP/py.tgz"
    MACPROVIDER_BOOTSTRAP_PYTHON_SHA256="$expected"
    MACPROVIDER_BOOTSTRAP_PYTHON_ASSET="cpython-test.tar.gz"
    MACPROVIDER_BOOTSTRAP_PYTHON_DIR="$TMP/install-python-cache"
    BOOTSTRAP_PYTHON_URL="file://$TMP/py.tgz"
    BOOTSTRAP_PYTHON_SHA256="$expected"
    BOOTSTRAP_PYTHON_ASSET="cpython-test.tar.gz"
    rm -rf "$MACPROVIDER_BOOTSTRAP_PYTHON_DIR"
    bootstrap_standalone_python3 && printf '%s\n' "$INSTALL_PYTHON3"
  )
}

got="$(run_bootstrap_download "$GOOD_SHA")"
[ -x "$got" ] || { echo "bootstrap download: expected executable INSTALL_PYTHON3, got '$got'" >&2; exit 1; }
expect "F hash-mismatch" "$(run_bootstrap_download deadbeef)" "DIE:8"

# ── Part 6: ordering — guard runs before validate_install_dir (first python3) ─
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
