#!/usr/bin/env bash
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/../../.." && pwd)"
WATCHDOG="$REPO_ROOT/ops/macprovider-watchdog/watchdog.sh"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

make_fake_common() {
  mkdir -p "$TMP/bin" "$TMP/home/.config/macprovider" "$TMP/logs"
  cat > "$TMP/home/.config/macprovider/config.yaml" <<'EOF'
provider_id: provider-test
port: 18080
EOF
  cat > "$TMP/bin/launchctl" <<'EOF'
#!/usr/bin/env bash
echo "$*" >> "$WATCHDOG_TEST_LAUNCHCTL_LOG"
EOF
  cat > "$TMP/bin/sysctl" <<'EOF'
#!/usr/bin/env bash
echo boot-a
EOF
  chmod +x "$TMP/bin/launchctl"
  chmod +x "$TMP/bin/sysctl"
}

run_watchdog() {
  HOME="$TMP/home" \
  PATH="$TMP/bin:/usr/bin:/bin:/usr/sbin:/sbin" \
  MACPROVIDER_LOG_DIR="$TMP/logs" \
  MACPROVIDER_BINARY_PATH="$TMP/home/macprovider/macprovider-cli" \
  MACPROVIDER_CURL="$TMP/bin/curl" \
  WATCHDOG_TEST_LAUNCHCTL_LOG="$TMP/launchctl.log" \
  bash "$WATCHDOG"
}

make_fake_common
cat > "$TMP/bin/pgrep" <<'EOF'
#!/usr/bin/env bash
exit 1
EOF
chmod +x "$TMP/bin/pgrep"
: > "$TMP/launchctl.log"
run_watchdog
if grep -F 'kickstart -k' "$TMP/launchctl.log" >/dev/null; then
  echo "companion watchdog must not kickstart the provider singleton" >&2
  exit 1
fi
grep -F 'launchd KeepAlive is the sole runtime manager' "$TMP/logs/watchdog.log" >/dev/null

rm -rf "$TMP/bin" "$TMP/logs" "$TMP/launchctl.log" "$TMP/home/.local/share/macprovider-watchdog/state"
make_fake_common
mkdir -p "$TMP/home/macprovider"
: > "$TMP/home/macprovider/macprovider-cli"
cat > "$TMP/bin/pgrep" <<'EOF'
#!/usr/bin/env bash
echo 4242
EOF
cat > "$TMP/bin/ps" <<EOF
#!/usr/bin/env bash
echo "$TMP/home/macprovider/macprovider-cli --port 18080"
EOF
cat > "$TMP/bin/curl" <<'EOF'
#!/usr/bin/env bash
case "$*" in
  *127.0.0.1:18080/v1/health*) exit 0 ;;
  *) exit 7 ;;
esac
EOF
cat > "$TMP/bin/lsof" <<'EOF'
#!/usr/bin/env bash
echo 4242
EOF
cat > "$TMP/bin/dscacheutil" <<'EOF'
#!/usr/bin/env bash
exit 1
EOF
cat > "$TMP/bin/host" <<'EOF'
#!/usr/bin/env bash
exit 1
EOF
chmod +x "$TMP/bin/"*
: > "$TMP/launchctl.log"
run_watchdog
if grep -F 'kickstart -k' "$TMP/launchctl.log" >/dev/null; then
  echo "coordinator reachability warning must not kick a locally healthy provider" >&2
  exit 1
fi
grep -F 'boot-a' "$TMP/home/.local/share/macprovider-watchdog/state/armed" >/dev/null

rm -rf "$TMP/bin" "$TMP/logs" "$TMP/launchctl.log" "$TMP/home/.local/share/macprovider-watchdog/state"
make_fake_common
mkdir -p "$TMP/home/macprovider"
: > "$TMP/home/macprovider/macprovider-cli"
cat > "$TMP/bin/pgrep" <<'EOF'
#!/usr/bin/env bash
echo 4242
EOF
cat > "$TMP/bin/ps" <<EOF
#!/usr/bin/env bash
echo "$TMP/home/macprovider/macprovider-cli --port 18080"
EOF
cat > "$TMP/bin/curl" <<'EOF'
#!/usr/bin/env bash
exit 0
EOF
cat > "$TMP/bin/lsof" <<'EOF'
#!/usr/bin/env bash
echo 9999
EOF
chmod +x "$TMP/bin/"*
mkdir -p "$TMP/home/.local/share/macprovider-watchdog/state"
printf "boot-a" > "$TMP/home/.local/share/macprovider-watchdog/state/armed"
: > "$TMP/launchctl.log"
run_watchdog
if grep -F 'kickstart -k' "$TMP/launchctl.log" >/dev/null; then
  echo "companion watchdog must observe unhealthy providers without becoming a second runtime manager" >&2
  exit 1
fi
grep -F 'provider process 4242 failed local /v1/health after arming; leaving restart ownership to launchd KeepAlive' "$TMP/logs/watchdog.log" >/dev/null
grep -F 'launchd KeepAlive is the sole runtime manager' "$TMP/logs/watchdog.log" >/dev/null

echo "watchdog health scope ok"
