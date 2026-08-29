#!/usr/bin/env bash
# Verifies the #1285 python3/CLT-stub guard: a stock Mac whose only python3 is
# the non-functional Command Line Tools stub must FAIL FAST with exit 8 (mapped
# by Malibu to an actionable "install developer tools" message) instead of
# hanging on the hidden CLT install dialog.
set -euo pipefail
REPO_ROOT="$(cd "$(dirname "$0")/../../.." && pwd)"
INSTALL_SH="$REPO_ROOT/phase3-binary/dist/install.sh"
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT

awk '/^ensure_python3_usable\(\)/{i=1} i{print} i&&/^}$/{exit}' "$INSTALL_SH" > "$TMP/guard.sh"
[ -s "$TMP/guard.sh" ] || { echo "could not extract ensure_python3_usable" >&2; exit 1; }
printf 'die() { echo "DIE:$1"; exit "$1"; }\n' >> "$TMP/guard.sh"

# A) real python3 elsewhere (Homebrew/python.org) -> accepted, no die
out="$(
  source "$TMP/guard.sh"
  command() { if [ "${1:-}" = "-v" ] && [ "${2:-}" = "python3" ]; then echo /opt/homebrew/bin/python3; return 0; fi; builtin command "$@"; }
  ensure_python3_usable && echo "OK"
)"
[ "$out" = "OK" ] || { echo "A: real python3 was rejected: $out" >&2; exit 1; }

# B) /usr/bin/python3 stub + NO developer tools -> die 8
rc=0
out="$(
  source "$TMP/guard.sh"
  command() { if [ "${1:-}" = "-v" ] && [ "${2:-}" = "python3" ]; then echo /usr/bin/python3; return 0; fi; builtin command "$@"; }
  xcode-select() { return 1; }
  HEADLESS=1
  ensure_python3_usable
)" || rc=$?
[ "$rc" = "8" ] || { echo "B: expected exit 8 for CLT stub, got $rc ($out)" >&2; exit 1; }

# C) /usr/bin/python3 + developer tools present -> accepted
out="$(
  source "$TMP/guard.sh"
  command() { if [ "${1:-}" = "-v" ] && [ "${2:-}" = "python3" ]; then echo /usr/bin/python3; return 0; fi; builtin command "$@"; }
  xcode-select() { return 0; }
  ensure_python3_usable && echo "OK"
)"
[ "$out" = "OK" ] || { echo "C: CLT-backed python3 was rejected: $out" >&2; exit 1; }

# D) main() calls the guard before the first python3 user (validate_install_dir)
grep -Eq 'ensure_python3_usable' "$INSTALL_SH" || { echo "D: guard not wired into installer" >&2; exit 1; }
python3 - "$INSTALL_SH" <<'PY'
import sys, re
s = open(sys.argv[1]).read()
main = s[s.rindex("\nmain() {"):]
gi = main.index("ensure_python3_usable")
vi = main.index("validate_install_dir")
assert gi < vi, "guard must run before validate_install_dir (first python3 user)"
print("order ok")
PY

echo "python3/CLT guard ok"
