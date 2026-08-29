#!/usr/bin/env bash
# End-to-end proof for #1286: on a fresh, non-developer Mac (python3 is only the
# /usr/bin/python3 Command Line Tools stub, no CLT installed), the installer must
# FAIL FAST with an actionable error instead of hanging on the hidden CLT dialog.
# Drives install.sh exactly as Malibu does: `bash -s -- <flags>` fed on stdin.
set -euo pipefail
[ "$(uname -s)" = "Darwin" ] || { echo "SKIP: macOS only" >&2; exit 0; }
REPO_ROOT="$(cd "$(dirname "$0")/../../.." && pwd)"
INSTALL_SH="$REPO_ROOT/phase3-binary/dist/install.sh"
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
pass(){ printf '  \342\234\223 %s\n' "$*"; }

# run install.sh via bash -s (app's exact method) with a hard kill-timer.
# echoes "EXIT:<code>" or "HANG" — never blocks the suite.
run_installer() {  # $1=script  $2=extra PATH prefix  $3=timeout_s ; rest via env already set
  local script="$1" pathpref="$2" t="$3" home; home="$(mktemp -d)"
  ( HOME="$home" MACPROVIDER_PORT=8899 PATH="$pathpref:/usr/bin:/bin:/usr/sbin:/sbin" \
      bash -s -- --dry-run < "$script" > "$TMP/out.log" 2>&1 & p=$!
    for _ in $(seq 1 "$t"); do kill -0 $p 2>/dev/null || break; sleep 1; done
    if kill -0 $p 2>/dev/null; then echo HANG; kill -9 $p 2>/dev/null; else wait $p; echo "EXIT:$?"; fi )
}

# ---- Fresh-Mac simulation: no CLT. xcode-select -p fails; python3 resolves to
# ---- /usr/bin/python3 (exactly where the real CLT stub lives). ----
mkdir -p "$TMP/nocltbin"
cat > "$TMP/nocltbin/xcode-select" <<'EOF'
#!/usr/bin/env bash
case "${1:-}" in -p|--print-path) echo "xcode-select: error: no developer tools" >&2; exit 2;;
  --install) exit 0;; *) exit 0;; esac
EOF
chmod +x "$TMP/nocltbin/xcode-select"

echo "== #1286 fresh-Mac (no-CLT) e2e =="

# 1) WITH the guard (this branch): must exit 8 fast, NOT hang, with the message.
r="$(run_installer "$INSTALL_SH" "$TMP/nocltbin" 12)"
[ "$r" = "EXIT:8" ] || { echo "FAIL: expected fast EXIT:8, got '$r'"; tail -5 "$TMP/out.log"; exit 1; }
grep -qiE "Command Line Developer Tools" "$TMP/out.log" || { echo "FAIL: missing actionable CLT message"; tail -5 "$TMP/out.log"; exit 1; }
pass "guarded installer FAILS FAST (exit 8, ~instant) with actionable CLT message — no hang"

# 2) COUNTERFACTUAL — old installer (origin/main, pre-guard) with a BLOCKING
#    python3 stub HANGS. Proves the guard fixes a real hang.
git -C "$REPO_ROOT" show origin/main:phase3-binary/dist/install.sh > "$TMP/old-install.sh"
mkdir -p "$TMP/hangbin"
cp "$TMP/nocltbin/xcode-select" "$TMP/hangbin/xcode-select"
cat > "$TMP/hangbin/python3" <<'EOF'
#!/usr/bin/env bash
# Simulate the CLT stub blocking on the hidden install dialog.
sleep 3600
EOF
chmod +x "$TMP/hangbin/python3"
r="$(run_installer "$TMP/old-install.sh" "$TMP/hangbin" 8)"
[ "$r" = "HANG" ] || { echo "FAIL: expected OLD installer to HANG on blocking python3, got '$r'"; exit 1; }
pass "pre-guard installer HANGS on a blocking python3 stub (the real bug) — guard prevents it"

# 3) NO FALSE POSITIVE — real python3 + CLT present: installer proceeds (dry-run).
mkdir -p "$TMP/cltbin"
cat > "$TMP/cltbin/xcode-select" <<'EOF'
#!/usr/bin/env bash
case "${1:-}" in -p|--print-path) echo "/Library/Developer/CommandLineTools"; exit 0;; *) exit 0;; esac
EOF
chmod +x "$TMP/cltbin/xcode-select"
r="$(run_installer "$INSTALL_SH" "$TMP/cltbin" 25)"
[ "$r" = "EXIT:0" ] || { echo "FAIL: healthy Mac should complete dry-run (EXIT:0), got '$r'"; tail -5 "$TMP/out.log"; exit 1; }
pass "healthy Mac (real python3 + CLT) proceeds normally — no false positive"

echo "== #1286 fresh-Mac e2e OK =="
echo "NOTE: real notarized DMG + Malibu.app GUI on a genuinely CLT-free Mac/VM is the T3 canary before messaging providers; a sandbox cannot run the app bundle."
