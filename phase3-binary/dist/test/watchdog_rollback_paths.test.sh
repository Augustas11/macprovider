#!/usr/bin/env bash
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/../../.." && pwd)"
STANDALONE="$REPO_ROOT/ops/macprovider-watchdog/watchdog.sh"
INSTALLER="$REPO_ROOT/phase3-binary/dist/install.sh"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

extract_inline_watchdog() {
  awk '
    /cat <<.WATCHDOG_EOF. > "\$WATCHDOG_PATH"/ { inside=1; next }
    inside && /^WATCHDOG_EOF$/ { exit }
    inside { print }
  ' "$INSTALLER"
}

INLINE="$TMP/watchdog-inline.sh"
extract_inline_watchdog > "$INLINE"
[ -s "$INLINE" ] || { echo "failed to extract installer watchdog" >&2; exit 1; }
chmod +x "$INLINE"

make_fixture() {
  root="$1"
  mkdir -p "$root/home/.local/share/macprovider/autoupdate" "$root/bin" "$root/logs"
  printf "new-binary" > "$root/bin/macprovider-cli"
  printf "old-binary" > "$root/bin/.macprovider-cli.rollback-123e4567-e89b-42d3-a456-426614174000"
  chmod 755 "$root/bin/macprovider-cli" "$root/bin/.macprovider-cli.rollback-123e4567-e89b-42d3-a456-426614174000"
  hash="$(shasum -a 256 "$root/bin/.macprovider-cli.rollback-123e4567-e89b-42d3-a456-426614174000" | awk '{print $1}')"
  cat > "$root/home/.local/share/macprovider/autoupdate/pending.json" <<EOF
{"update_id":"123e4567-e89b-42d3-a456-426614174000","target_version":"1.8.10","target_path":"$root/bin/macprovider-cli","backup_path":"$root/bin/.macprovider-cli.rollback-123e4567-e89b-42d3-a456-426614174000","size":10,"mode":493,"sha256":"$hash","marker_deadline":"2000-01-01T00:00:00Z"}
EOF
  : > "$root/launchctl.log"
  cat > "$root/bin/launchctl" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$MACPROVIDER_FAKE_LAUNCHCTL_LOG"
if [ "${1:-}" = "print" ]; then
  printf 'pid = 123\nlast exit status = 0\n'
fi
EOF
  chmod +x "$root/bin/launchctl"
}

run_reconcile() {
  script="$1"
  root="$2"
  HOME="$root/home" \
  MACPROVIDER_BINARY_PATH="$root/bin/macprovider-cli" \
  MACPROVIDER_LOG_DIR="$root/logs" \
  MACPROVIDER_FAKE_LAUNCHCTL_LOG="$root/launchctl.log" \
  PATH="$root/bin:$PATH" \
  bash "$script" --reconcile-autoupdate
  cmp -s "$root/bin/macprovider-cli" <(printf "old-binary")
  [ ! -e "$root/home/.local/share/macprovider/autoupdate/pending.json" ]
  grep -F "bootstrap gui/" "$root/launchctl.log" >/dev/null
  grep -F "kickstart -k gui/" "$root/launchctl.log" >/dev/null
}

make_fixture "$TMP/standalone"
run_reconcile "$STANDALONE" "$TMP/standalone"

make_fixture "$TMP/inline"
run_reconcile "$INLINE" "$TMP/inline"

echo "watchdog rollback paths ok"
