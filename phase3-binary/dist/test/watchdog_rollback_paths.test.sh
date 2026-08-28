#!/usr/bin/env bash
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/../../.." && pwd)"
STANDALONE="$REPO_ROOT/ops/macprovider-watchdog/watchdog.sh"
INSTALLER="$REPO_ROOT/phase3-binary/dist/install.sh"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

extract_inline_watchdog() {
  awk '
    /write_atomic_install_file "\$WATCHDOG_PATH" 0755 <<.WATCHDOG_EOF./ { inside=1; next }
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
  printf "new-binary" > "$root/bin/malibu-cli"
  printf "old-binary" > "$root/bin/.malibu-cli.rollback-123e4567-e89b-42d3-a456-426614174000"
  chmod 755 "$root/bin/malibu-cli" "$root/bin/.malibu-cli.rollback-123e4567-e89b-42d3-a456-426614174000"
  hash="$(shasum -a 256 "$root/bin/.malibu-cli.rollback-123e4567-e89b-42d3-a456-426614174000" | awk '{print $1}')"
  cat > "$root/home/.local/share/macprovider/autoupdate/pending.json" <<EOF
{"update_id":"123e4567-e89b-42d3-a456-426614174000","target_version":"1.8.10","target_path":"$root/bin/malibu-cli","backup_path":"$root/bin/.malibu-cli.rollback-123e4567-e89b-42d3-a456-426614174000","size":10,"mode":493,"sha256":"$hash","marker_deadline":"2000-01-01T00:00:00Z"}
EOF
  : > "$root/launchctl.log"
  cat > "$root/bin/launchctl" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$MACPROVIDER_FAKE_LAUNCHCTL_LOG"
case "${1:-}" in
  list)
    printf -- '-\t0\tlive.malibu.provider-compatibility-reload\n'
    ;;
  print)
    printf 'pid = 123\nlast exit status = 0\n'
    ;;
  bootstrap|kickstart|bootout)
    exit 99
    ;;
esac
EOF
  chmod +x "$root/bin/launchctl"
}

add_full_release_fixture() {
  root="$1"
  mkdir -p \
    "$root/bin/.malibu-cli.release-rollback-123e4567-e89b-42d3-a456-426614174000/Runtime.bundle" \
    "$root/bin/.malibu-cli.release-rollback-123e4567-e89b-42d3-a456-426614174000/catalog-release" \
    "$root/bin/Runtime.bundle" \
    "$root/bin/NewOnly.bundle" \
    "$root/bin/catalog-release"
  printf "old-metal" > "$root/bin/.malibu-cli.release-rollback-123e4567-e89b-42d3-a456-426614174000/mlx.metallib"
  printf "old-bundle" > "$root/bin/.malibu-cli.release-rollback-123e4567-e89b-42d3-a456-426614174000/Runtime.bundle/resource"
  printf "old-catalog" > "$root/bin/.malibu-cli.release-rollback-123e4567-e89b-42d3-a456-426614174000/catalog-release/release.json"
  printf "new-metal" > "$root/bin/mlx.metallib"
  printf "new-bundle" > "$root/bin/Runtime.bundle/resource"
  printf "new-only" > "$root/bin/NewOnly.bundle/resource"
  printf "new-catalog" > "$root/bin/catalog-release/release.json"
}

invoke_reconcile() {
  script="$1"
  root="$2"
  HOME="$root/home" \
  MACPROVIDER_BINARY_PATH="$root/bin/malibu-cli" \
  MACPROVIDER_LOG_DIR="$root/logs" \
  MACPROVIDER_FAKE_LAUNCHCTL_LOG="$root/launchctl.log" \
  PATH="$root/bin:/usr/bin:/bin:/usr/sbin:/sbin" \
  bash "$script" --reconcile-autoupdate
}

assert_watchdog_does_not_own_rollback() {
  script="$1"
  root="$2"
  invoke_reconcile "$script" "$root"
  cmp -s "$root/bin/malibu-cli" <(printf "new-binary")
  cmp -s "$root/bin/.malibu-cli.rollback-123e4567-e89b-42d3-a456-426614174000" <(printf "old-binary")
  [ -e "$root/home/.local/share/macprovider/autoupdate/pending.json" ]
  grep -F "autoupdate recovery deferred: pending marker exists; transaction owner must resolve update/rollback state" \
    "$root/logs/watchdog.log" >/dev/null
  if grep -E '(^| )((list|bootout|bootstrap|kickstart)( |$))' "$root/launchctl.log" >/dev/null; then
    echo "watchdog rollback compatibility command must not touch launchctl" >&2
    exit 1
  fi
}

assert_watchdog_does_not_restore_release_payload() {
  script="$1"
  root="$2"
  invoke_reconcile "$script" "$root"
  cmp -s "$root/bin/malibu-cli" <(printf "new-binary")
  cmp -s "$root/bin/mlx.metallib" <(printf "new-metal")
  cmp -s "$root/bin/Runtime.bundle/resource" <(printf "new-bundle")
  cmp -s "$root/bin/NewOnly.bundle/resource" <(printf "new-only")
  cmp -s "$root/bin/catalog-release/release.json" <(printf "new-catalog")
  cmp -s "$root/bin/.malibu-cli.release-rollback-123e4567-e89b-42d3-a456-426614174000/mlx.metallib" <(printf "old-metal")
  [ -e "$root/home/.local/share/macprovider/autoupdate/pending.json" ]
}

assert_watchdog_does_not_quarantine_malformed_marker() {
  script="$1"
  root="$2"
  mkdir -p "$root/home/.local/share/macprovider/autoupdate" "$root/bin" "$root/logs"
  printf "repaired-binary" > "$root/bin/malibu-cli"
  printf '{"operation_id":"malformed-repair-marker"}\n' > "$root/home/.local/share/macprovider/autoupdate/pending.json"
  : > "$root/launchctl.log"
  invoke_reconcile "$script" "$root"
  cmp -s "$root/bin/malibu-cli" <(printf "repaired-binary")
  [ -e "$root/home/.local/share/macprovider/autoupdate/pending.json" ]
  [ "$(find "$root/home/.local/share/macprovider/autoupdate" -name 'pending-quarantined-*.json' | wc -l | tr -d ' ')" = "0" ]
}

for script_name in standalone inline; do
  if [ "$script_name" = standalone ]; then
    script="$STANDALONE"
  else
    script="$INLINE"
  fi

  make_fixture "$TMP/no-rollback-$script_name"
  assert_watchdog_does_not_own_rollback "$script" "$TMP/no-rollback-$script_name"

  make_fixture "$TMP/release-no-rollback-$script_name"
  add_full_release_fixture "$TMP/release-no-rollback-$script_name"
  assert_watchdog_does_not_restore_release_payload "$script" "$TMP/release-no-rollback-$script_name"

  assert_watchdog_does_not_quarantine_malformed_marker "$script" "$TMP/malformed-$script_name"
done

echo "watchdog rollback paths ok"
