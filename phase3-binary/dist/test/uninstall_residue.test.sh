#!/usr/bin/env bash
# uninstall.sh must remove what a failed or completed install leaves behind
# (observed on a real Mac after a failed onboarding) while keeping what
# SPEC-003 FR-C6 / SPEC-025 §3.4 preserve: provider identity and config,
# model caches, ~/.cache/macprovider and app-owned state. It must not act
# underneath a live installer or after the CLI uninstaller refuses.
# launchctl is stubbed: it acts on the real user session regardless of $HOME.
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/../../.." && pwd)"
UNINSTALL_SH="$REPO_ROOT/phase3-binary/dist/uninstall.sh"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

fail() { echo "FAIL: $*" >&2; exit 1; }
gone() { [ ! -e "$1" ] && [ ! -L "$1" ] || fail "expected removed: $1"; }
kept() { [ -e "$1" ] || fail "expected kept: $1"; }

setup() {
  rm -rf "$TMP/home" "$TMP/tmpdir" "$TMP/systmp" "$TMP/stubs" "$TMP/outside"
  : >"$TMP/calls"
  export HOME="$TMP/home" TMPDIR="$TMP/tmpdir/" MACPROVIDER_NO_PROMPT=1
  export MACPROVIDER_UNINSTALL_SYSTEM_TMPDIR="$TMP/systmp"
  unset ASSERT_UNINSTALL_LOCK_HELD
  unset FAIL_LAUNCHCTL_BOOTOUT
  # Never let the test resolve the developer's real model cache.
  unset HF_HOME HF_HUB_CACHE
  mkdir -p "$HOME" "$TMPDIR" "$MACPROVIDER_UNINSTALL_SYSTEM_TMPDIR" "$TMP/stubs"
  for tool in defaults security; do
    printf '#!/usr/bin/env bash\necho "%s $*" >>"%s"\n' "$tool" "$TMP/calls" >"$TMP/stubs/$tool"
    chmod +x "$TMP/stubs/$tool"
  done
  cat >"$TMP/stubs/launchctl" <<EOF
#!/usr/bin/env bash
if [ "\${ASSERT_UNINSTALL_LOCK_HELD:-0}" = 1 ]; then
  python3 - "\$HOME/.config/macprovider/install.lock" <<'PY'
import fcntl, os, sys
fd = os.open(sys.argv[1], os.O_RDWR)
try:
    fcntl.flock(fd, fcntl.LOCK_EX | fcntl.LOCK_NB)
except BlockingIOError:
    raise SystemExit(0)
raise SystemExit(91)
PY
fi
echo "launchctl \$*" >>"$TMP/calls"
case "\${1:-}" in
  bootout)
    if [ "\${FAIL_LAUNCHCTL_BOOTOUT:-0}" = 1 ]; then
      echo "Boot-out failed: 5: Input/output error" >&2
      exit 5
    fi
    exit 0
    ;;
  print)
    if [ "\${FAIL_LAUNCHCTL_BOOTOUT:-0}" = 1 ]; then
      echo "service = { state = running }"
      exit 0
    fi
    echo "Could not find service \"\${2:-}\" in domain" >&2
    exit 113
    ;;
esac
EOF
  chmod +x "$TMP/stubs/launchctl"
  export PATH="$TMP/stubs:$ORIGINAL_PATH"

  cfg="$HOME/.config/macprovider"
  mkdir -p "$cfg/install-recovery-20260908T022203Z-75088" "$cfg/protected-credentials"
  : >"$cfg/install.lock"
  chmod 600 "$cfg/install.lock"
  for f in autotune-hmac-secret config.yaml provider_id; do echo x >"$cfg/$f"; done

  support="$HOME/Library/Application Support/macprovider"
  mkdir -p "$support/models/mlx-community--Qwen3-8B-4bit/rev/sha" "$support/lifecycle" "$support/protected-credentials-v1"
  : >"$support/lifecycle/.state-v1.json.lock"
  : >"$support/lifecycle/.lease.json.lock"
  echo cred >"$support/protected-credentials-v1/bearer"

  mkdir -p "$HOME/.local/share/macprovider/autoupdate" "$HOME/.local/share/macprovider/install-python" \
    "$HOME/.cache/macprovider/autotune-logs" "$HOME/Library/Caches/macprovider-cli" \
    "$HOME/Library/HTTPStorages/macprovider-cli" "$HOME/Library/Preferences" "$HOME/Library/LaunchAgents" \
    "$HOME/.cache/huggingface/hub/models--mlx-community--Qwen3-8B-4bit"
  : >"$HOME/.local/share/macprovider/autoupdate/pending.json"
  echo x >"$HOME/Library/Preferences/tech.malibu.app.plist"
  echo x >"$HOME/Library/LaunchAgents/live.malibu.provider-install-recovery.plist"

  mkdir -p "$TMP/outside"
  echo precious >"$TMP/outside/keep"
  for root in "${TMPDIR%/}" "$MACPROVIDER_UNINSTALL_SYSTEM_TMPDIR"; do
    echo MAL1-P-code >"$root/macprovider-referral-F1A745EA"
    mkdir -p "$root/tmp.installer/staging" "$root/tmp.unrelated" "$root/macprovider-update-1" "$root/macprovider-python.x1"
    : >"$root/tmp.installer/macprovider-cli-v1.8.122-darwin-arm64.tar.gz"
    echo precious >"$root/tmp.unrelated/data"
    ln -s "$TMP/outside" "$root/macprovider-update-symlink"
  done
}

install_cli_stub() {
  mkdir -p "$HOME/.local/bin"
  cat >"$HOME/.local/bin/macprovider-cli" <<EOF
#!/usr/bin/env bash
echo "cli \$*" >>"$TMP/calls"
exit $1
EOF
  chmod +x "$HOME/.local/bin/macprovider-cli"
}

assert_identity_and_caches_kept() {
  cfg="$HOME/.config/macprovider"
  for f in config.yaml provider_id install.lock autotune-hmac-secret protected-credentials install-recovery-20260908T022203Z-75088; do
    kept "$cfg/$f"
  done
  kept "$HOME/Library/Application Support/macprovider/protected-credentials-v1/bearer"
  kept "$HOME/.local/share/macprovider/install-python"
  kept "$HOME/.cache/macprovider/autotune-logs"
  kept "$HOME/.cache/huggingface/hub/models--mlx-community--Qwen3-8B-4bit"
  kept "$HOME/Library/Preferences/tech.malibu.app.plist"
}

ORIGINAL_PATH="$PATH"

# 1. Failed install (no CLI, no lifecycle tombstone): residue gone, identity kept.
setup
bash "$UNINSTALL_SH" >"$TMP/out" 2>&1 || { cat "$TMP/out"; fail "uninstall exited nonzero"; }
support="$HOME/Library/Application Support/macprovider"
gone "$support/models"; gone "$support/lifecycle"
gone "$HOME/.local/share/macprovider/autoupdate"
gone "$HOME/Library/Caches/macprovider-cli"; gone "$HOME/Library/HTTPStorages/macprovider-cli"
gone "$HOME/Library/LaunchAgents/live.malibu.provider-install-recovery.plist"
for root in "${TMPDIR%/}" "$MACPROVIDER_UNINSTALL_SYSTEM_TMPDIR"; do
  gone "$root/macprovider-referral-F1A745EA"; gone "$root/tmp.installer"
  gone "$root/macprovider-update-1"; gone "$root/macprovider-python.x1"
  kept "$root/tmp.unrelated/data"
done
kept "$TMP/outside/keep"
assert_identity_and_caches_kept
grep -q "launchctl bootout gui/$UID/live.malibu.provider-install-recovery" "$TMP/calls" || fail "install-recovery job not booted out"
grep -qE "^(defaults|security) " "$TMP/calls" && fail "touched app preferences or keychain"

# 2. Completed install: the lifecycle tombstone the CLI keeps is kept too.
setup
echo '{"state":"uninstalled"}' >"$HOME/Library/Application Support/macprovider/lifecycle/state-v1.json"
bash "$UNINSTALL_SH" >"$TMP/out" 2>&1 || { cat "$TMP/out"; fail "uninstall exited nonzero"; }
lifecycle="$HOME/Library/Application Support/macprovider/lifecycle"
kept "$lifecycle/state-v1.json"; kept "$lifecycle/.state-v1.json.lock"; gone "$lifecycle/.lease.json.lock"
gone "$HOME/Library/Application Support/macprovider/models"

# 3. Live installer holding install.lock: refuse, change nothing.
setup
python3 - "$HOME/.config/macprovider/install.lock" "$TMP/locked" <<'HOLD' &
import fcntl, os, sys, time
fd = os.open(sys.argv[1], os.O_RDWR)
fcntl.flock(fd, fcntl.LOCK_EX)
open(sys.argv[2], "w").close()
time.sleep(30)
HOLD
holder=$!
for _ in $(seq 1 400); do [ -f "$TMP/locked" ] && break; sleep 0.05; done
[ -f "$TMP/locked" ] || { kill "$holder"; fail "lock holder never acquired install.lock"; }
rm -f "$TMP/locked"
if bash "$UNINSTALL_SH" >"$TMP/out" 2>&1; then kill "$holder"; fail "uninstall ran under a live installer"; fi
kill "$holder" 2>/dev/null || true
wait "$holder" 2>/dev/null || true
grep -q "an installer is still running" "$TMP/out" || fail "live installer not reported"
kept "$HOME/Library/Application Support/macprovider/models"
kept "$HOME/Library/LaunchAgents/live.malibu.provider-install-recovery.plist"
kept "${TMPDIR%/}/tmp.installer"
[ -s "$TMP/calls" ] && fail "launchctl called under a live installer"

# 4. CLI present and succeeds: delegated first, no bogus manifest warning, and
# no default-prefix fallback: with a custom MACPROVIDER_INSTALL_DIR,
# ~/macprovider can be an unrelated directory (the CLI already removed the
# real prefix and the manifest).
setup
install_cli_stub 0
mkdir -p "$HOME/macprovider"
echo unrelated >"$HOME/macprovider/keep"
bash "$UNINSTALL_SH" >"$TMP/out" 2>&1 || { cat "$TMP/out"; fail "uninstall exited nonzero with CLI"; }
grep -q "^cli uninstall --yes$" "$TMP/calls" || fail "CLI uninstaller not invoked"
grep -q "install manifest missing" "$TMP/out" && fail "manifest warning after successful CLI uninstall"
kept "$HOME/macprovider/keep"
gone "$HOME/Library/Application Support/macprovider/models"

# 5. CLI present but refuses: stop without deleting anything else.
setup
install_cli_stub 3
if bash "$UNINSTALL_SH" >"$TMP/out" 2>&1; then fail "uninstall continued after CLI refusal"; fi
grep -q "the CLI uninstaller did not complete" "$TMP/out" || fail "CLI refusal not reported"
kept "$HOME/Library/Application Support/macprovider/models"
kept "${TMPDIR%/}/macprovider-referral-F1A745EA"

# 6. Dry run changes nothing.
setup
bash "$UNINSTALL_SH" --dry-run >"$TMP/out" 2>&1 || fail "dry run exited nonzero"
kept "$HOME/Library/Application Support/macprovider/models"
kept "${TMPDIR%/}/macprovider-referral-F1A745EA"
grep -q "\[dry-run\] rm -rf" "$TMP/out" || fail "dry run did not report removals"

# 7. Installer alive but its flock helper died: install.sh fences on the
# lock's owner record (pid + process start + boot session); so must we.
setup
sleep 30 &
owner=$!
python3 - "$HOME/.config/macprovider/install.lock" "$owner" <<'RECORD'
import json, subprocess, sys
start = subprocess.run(["ps", "-p", sys.argv[2], "-o", "lstart="], capture_output=True, text=True).stdout.strip()
boot = subprocess.run(["/usr/sbin/sysctl", "-n", "kern.bootsessionuuid"], capture_output=True, text=True).stdout.strip()
json.dump({"pid": int(sys.argv[2]), "process_start": start, "boot_session": boot}, open(sys.argv[1], "w"))
RECORD
if bash "$UNINSTALL_SH" >"$TMP/out" 2>&1; then kill "$owner"; fail "uninstall ran under a live installer owner record"; fi
kill "$owner" 2>/dev/null || true
wait "$owner" 2>/dev/null || true
grep -q "an installer is still running" "$TMP/out" || fail "owner-record installer not reported"
kept "$HOME/Library/Application Support/macprovider/models"
# A stale record (owner gone) must not block uninstall.
bash "$UNINSTALL_SH" >"$TMP/out" 2>&1 || { cat "$TMP/out"; fail "stale owner record blocked uninstall"; }

# 8. The kernel lock remains held while destructive launchctl/removal work runs.
setup
export ASSERT_UNINSTALL_LOCK_HELD=1
bash "$UNINSTALL_SH" >"$TMP/out" 2>&1 || { cat "$TMP/out"; fail "uninstall did not retain transaction lock"; }

# 9. A trusted manifest binary_path is authoritative for custom-prefix installs.
setup
custom="$HOME/custom-provider"
mkdir -p "$custom"
cat >"$custom/macprovider-cli" <<EOF
#!/usr/bin/env bash
echo "manifest-cli \$*" >>"$TMP/calls"
exit 0
EOF
chmod 700 "$custom/macprovider-cli"
cat >"$HOME/Library/Application Support/macprovider/install_manifest.json" <<EOF
{"install_prefix":"$custom","binary_path":"$custom/macprovider-cli","launchd_labels":[],"launchd_plists":[],"data_dirs":["$custom"]}
EOF
bash "$UNINSTALL_SH" >"$TMP/out" 2>&1 || { cat "$TMP/out"; fail "manifest CLI delegation failed"; }
grep -q "^manifest-cli uninstall --yes$" "$TMP/calls" || fail "manifest binary_path was not delegated"

# 10. Only a parsed uninstalled tombstone is retained.
for state in serving_buyers update_in_progress rollback_in_progress; do
  setup
  printf '{"state":"%s"}\n' "$state" >"$HOME/Library/Application Support/macprovider/lifecycle/state-v1.json"
  bash "$UNINSTALL_SH" >"$TMP/out" 2>&1 || { cat "$TMP/out"; fail "cleanup failed for lifecycle state $state"; }
  gone "$HOME/Library/Application Support/macprovider/lifecycle"
done
setup
printf '{malformed\n' >"$HOME/Library/Application Support/macprovider/lifecycle/state-v1.json"
bash "$UNINSTALL_SH" >"$TMP/out" 2>&1 || { cat "$TMP/out"; fail "cleanup failed for malformed lifecycle state"; }
gone "$HOME/Library/Application Support/macprovider/lifecycle"

# 11. Symlinked support/lifecycle roots fail before any outside deletion.
setup
rm -rf "$HOME/Library/Application Support/macprovider"
ln -s "$TMP/outside" "$HOME/Library/Application Support/macprovider"
if bash "$UNINSTALL_SH" >"$TMP/out" 2>&1; then fail "symlinked support root was accepted"; fi
kept "$TMP/outside/keep"
[ -s "$TMP/calls" ] && fail "commands ran for symlinked support root"
setup
rm -rf "$HOME/Library/Application Support/macprovider/lifecycle"
mkdir -p "$TMP/outside/lifecycle"
echo precious >"$TMP/outside/lifecycle/keep"
ln -s "$TMP/outside/lifecycle" "$HOME/Library/Application Support/macprovider/lifecycle"
if bash "$UNINSTALL_SH" >"$TMP/out" 2>&1; then fail "symlinked lifecycle root was accepted"; fi
kept "$TMP/outside/lifecycle/keep"

# 12. Malformed lock records fail closed without touching installation data.
setup
printf '{malformed\n' >"$HOME/.config/macprovider/install.lock"
if bash "$UNINSTALL_SH" >"$TMP/out" 2>&1; then fail "malformed lock record was accepted"; fi
grep -q "refusing unsafe install lock state" "$TMP/out" || fail "unsafe lock was not reported"
kept "$HOME/Library/Application Support/macprovider/models"

# 13. Fallback cleanup must not remove files underneath a launchd job that
# could not be stopped and is still reported as loaded.
setup
export FAIL_LAUNCHCTL_BOOTOUT=1
if bash "$UNINSTALL_SH" >"$TMP/out" 2>&1; then fail "cleanup continued after launchd stop failure"; fi
grep -q "launchd job is still loaded" "$TMP/out" || fail "loaded launchd job was not reported"
kept "$HOME/Library/Application Support/macprovider/models"
kept "$HOME/Library/LaunchAgents/live.malibu.provider-install-recovery.plist"
kept "${TMPDIR%/}/tmp.installer"

echo "uninstall residue ok"
