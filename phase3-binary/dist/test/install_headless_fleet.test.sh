#!/usr/bin/env bash
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/../../.." && pwd)"
INSTALL_SH="$REPO_ROOT/phase3-binary/dist/install.sh"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

python3 - "$INSTALL_SH" > "$TMP/functions.sh" <<'PY'
import sys

names = [
    "xml_escape",
    "json_escape",
    "write_atomic_install_file",
    "launchctl_service",
    "validate_headless_launchdaemon_plist",
    "snapshot_headless_launchdaemon_plist",
    "publish_root_file_from_base64",
    "verify_published_launchd_payload",
    "run_macprovider_cli_with_amfi_retry",
    "validate_provider_token_environment",
    "validate_launchd_mode",
    "version_at_least",
    "validate_macprovider_version_tag",
    "validate_headless_release_tag",
    "validate_headless_acceptance_source",
    "path_owner_uid",
    "launchd_print_loaded",
    "require_launchd_service_absent",
    "publish_launchd_plist",
    "publish_headless_recovery_trust",
    "verify_headless_recovery_trust",
    "retire_headless_recovery_trust",
    "validate_headless_install_topology",
    "reclaim_launchd_service",
    "reclaim_legacy_launchd_service",
    "semantic_merge_config",
    "read_config_model",
    "enforce_headless_config_overrides",
    "write_config",
    "read_config_provider_token_line",
    "scrub_config_provider_token",
    "render_plist",
    "render_watchdog_plist",
    "install_plist",
    "install_watchdog",
    "write_install_manifest",
    "arm_install_recovery_agent",
    "recover_orphaned_install_transactions",
    "validate_recovery_launchdaemon_plist",
]
lines = open(sys.argv[1], encoding="utf-8").read().splitlines()
for name in names:
    for index, line in enumerate(lines):
        if line not in {f"{name}() {{", f"{name}() ("}:
            continue
        depth = 0
        terminator = ")" if line.endswith("(") else "}"
        while index < len(lines):
            current = lines[index]
            print(current)
            if terminator == "}":
                depth += current.count("{") - current.count("}")
            else:
                depth += current.count("(") - current.count(")")
            index += 1
            if depth == 0:
                break
        break
    else:
        raise SystemExit(f"could not extract {name}")
PY

python3 - "$INSTALL_SH" <<'PY'
import sys

text = open(sys.argv[1], encoding="utf-8").read()
marker = "write_atomic_install_file \"$WATCHDOG_PATH\" 0755 <<'WATCHDOG_EOF'"
start = text.index(marker) + len(marker)
end = text.index("\nWATCHDOG_EOF", start)
watchdog = text[start:end]
allowed = {
    'LAUNCHD_DOMAIN="${MACPROVIDER_LAUNCHD_DOMAIN:-gui/$(id -u)}"',
    'launchd_domain = os.environ.get("MACPROVIDER_LAUNCHD_DOMAIN") or f"gui/{uid}"',
}
bad = [line for line in watchdog.splitlines() if "gui/" in line and line.strip() not in allowed]
if bad:
    raise SystemExit("hardcoded GUI launchd reference in watchdog script:\n" + "\n".join(bad))
PY

mkdir -p "$TMP/bin" "$TMP/home/.config/macprovider/launchd" "$TMP/system" "$TMP/users/other/Library/LaunchAgents"

cat > "$TMP/bin/sudo" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
[ "${1:-}" != "-n" ] || shift
[ "${1:-}" != "true" ] || exit 0
exec "$@"
EOF

cat > "$TMP/bin/install" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
while [ "$#" -gt 2 ]; do shift; done
cp "$1" "$2"
chmod 0644 "$2"
EOF

cat > "$TMP/bin/launchctl" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
case " $* " in
  *' print gui/'*) ;;
  *' gui/'*) echo "GUI launchd target used in headless mode: $*" >&2; exit 91 ;;
esac
printf '%s\n' "$*" >> "$LAUNCHD_LOG"
if [ "${1:-}" = "print" ]; then
  exit "${LAUNCHD_PRINT_STATUS:-1}"
fi
exit 0
EOF

cat > "$TMP/bin/plutil" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
[ "${1:-}" = "-lint" ] && [ -f "${2:-}" ]
EOF

cat > "$TMP/bin/macprovider-cli" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
command="${1:-}"
subcommand="${2:-}"
shift 2
config=""
while [ "$#" -gt 0 ]; do
  case "$1" in
    --config)
      config="$2"
      shift 2
      ;;
    *)
      shift
      ;;
  esac
done
[ "$command" = "credentials" ] || exit 64
[ -n "$config" ] || exit 64
case "$subcommand" in
  config-token-status)
    python3 - "$config" <<'PY'
import re
import sys

path = sys.argv[1]
patterns = [
    re.compile(r"^provider_token[ \t]*:"),
    re.compile(r"^'provider_token'[ \t]*:"),
    re.compile(r'^"provider_token"[ \t]*:'),
    re.compile(r'^"provider\\u005ftoken"[ \t]*:'),
]
try:
    with open(path, encoding="utf-8") as handle:
        for line in handle:
            if any(pattern.match(line) for pattern in patterns):
                raise SystemExit(0)
except FileNotFoundError:
    pass
raise SystemExit(3)
PY
    ;;
  scrub-config-token)
    python3 - "$config" <<'PY'
import os
import re
import sys
import tempfile

path = sys.argv[1]
patterns = [
    re.compile(r"^provider_token[ \t]*:(?P<rest>.*)$"),
    re.compile(r"^'provider_token'[ \t]*:(?P<rest>.*)$"),
    re.compile(r'^"provider_token"[ \t]*:(?P<rest>.*)$'),
    re.compile(r'^"provider\\u005ftoken"[ \t]*:(?P<rest>.*)$'),
]
with open(path, encoding="utf-8") as handle:
    lines = handle.read().splitlines()
scrubbed = []
index = 0
while index < len(lines):
    line = lines[index]
    match = next((pattern.match(line) for pattern in patterns if pattern.match(line)), None)
    if not match:
        scrubbed.append(line)
        index += 1
        continue
    rest = match.group("rest").strip()
    index += 1
    if rest.startswith("|") or rest.startswith(">"):
        while index < len(lines):
            candidate = lines[index]
            if candidate.strip() == "":
                index += 1
                continue
            if not candidate.startswith((" ", "\t")):
                break
            index += 1
directory = os.path.dirname(path)
fd, temporary = tempfile.mkstemp(prefix=".config-tokenless-", dir=directory)
try:
    with os.fdopen(fd, "w", encoding="utf-8") as output:
        output.write("\n".join(scrubbed))
        output.write("\n")
    os.chmod(temporary, 0o600)
    os.replace(temporary, path)
finally:
    try:
        os.unlink(temporary)
    except FileNotFoundError:
        pass
PY
    ;;
  *)
    exit 64
    ;;
esac
EOF
chmod 0755 "$TMP/bin/"*

HOME="$TMP/home" PATH="$TMP/bin:$PATH" MOCK_BIN="$TMP/bin" LAUNCHD_LOG="$TMP/launchctl.log" \
FUNCTION_PATH="$TMP/functions.sh" SYSTEM_DIR="$TMP/system" USERS_DIR="$TMP/users" bash -c '
  set -euo pipefail
  log() { :; }
  run() { "$@"; }
  die() { exit "$1"; }
  assert_install_lock_ownership() { :; }
  fsync_directory_path() { :; }
  write_install_tx_marker() { :; }
  write_watchdog_script() { printf "#!/usr/bin/env bash\n" > "$WATCHDOG_PATH"; chmod 0755 "$WATCHDOG_PATH"; }
  source "$FUNCTION_PATH"

  MACPROVIDER_MIN_SUPPORTED_VERSION=v1.7.11
  MACPROVIDER_MIN_HEADLESS_VERSION=v1.8.108
  HEADLESS=1
  if (validate_headless_release_tag v1.8.105); then
    echo "headless mode unexpectedly accepted a pre-headless release tag" >&2
    exit 1
  fi
  validate_headless_release_tag v1.8.108
  if (validate_headless_acceptance_source); then
    echo "headless mode unexpectedly accepted missing acceptance provenance" >&2
    exit 1
  fi
  if (BUNDLED_APP=/Applications/Malibu.app MACPROVIDER_ACCEPTANCE_ASSET_DIR=/tmp/a MACPROVIDER_VERSION=v1.8.108 MACPROVIDER_ACCEPTANCE_COMMIT=0123456789012345678901234567890123456789 MACPROVIDER_ACCEPTANCE_CONTROL_COMMIT=abcdefabcdefabcdefabcdefabcdefabcdefabcd MACPROVIDER_ACCEPTANCE_RUN_ID=1 MACPROVIDER_ACCEPTANCE_RUN_ATTEMPT=1 validate_headless_acceptance_source); then
    echo "headless mode unexpectedly accepted MACPROVIDER_BUNDLED_APP" >&2
    exit 1
  fi
  MACPROVIDER_ACCEPTANCE_ASSET_DIR=/tmp/a MACPROVIDER_VERSION=v1.8.108 MACPROVIDER_ACCEPTANCE_COMMIT=0123456789012345678901234567890123456789 MACPROVIDER_ACCEPTANCE_CONTROL_COMMIT=abcdefabcdefabcdefabcdefabcdefabcdefabcd MACPROVIDER_ACCEPTANCE_RUN_ID=1 MACPROVIDER_ACCEPTANCE_RUN_ATTEMPT=1 validate_headless_acceptance_source
  HEADLESS=0
  validate_headless_release_tag v1.8.105

  SUDO_BIN="$MOCK_BIN/sudo"
  ROOT_PYTHON3_BIN="$(command -v python3)"
  LAUNCHCTL_BIN="$MOCK_BIN/launchctl"
  MACPROVIDER_CLI_EXECUTABLE="$MOCK_BIN/macprovider-cli"
  HEADLESS=1
  HEADLESS_USER="$(id -un)"
  HEADLESS_RECOVERY_TRUST_PATH="$SYSTEM_DIR/install-recovery.sha256"
  LAUNCHD_DOMAIN=system
  LAUNCHD_BOOTSTRAP_DIR="$SYSTEM_DIR"
  SYSTEM_LAUNCHD_DIR="$SYSTEM_DIR"
  LOCAL_USER_HOME_ROOT="$USERS_DIR"
  CONFIG_DIR="$HOME/.config/macprovider"
  CONFIG_PATH="$CONFIG_DIR/config.yaml"
  PROVIDER_ID_PATH="$CONFIG_DIR/provider_id"
  MANIFEST_DIR="$CONFIG_DIR"
  MANIFEST_PATH="$CONFIG_DIR/install_manifest.json"
  LIFECYCLE_LEASE_PATH="$MANIFEST_DIR/lifecycle/lease.json"
  INSTALL_DIR="$HOME/macprovider"
  BINARY_PATH="$HOME/.local/bin/macprovider-cli"
  LOG_DIR="$HOME/Library/Logs/macprovider"
  WATCHDOG_DIR="$HOME/.local/share/macprovider-watchdog"
  WATCHDOG_PATH="$WATCHDOG_DIR/macprovider-health-monitor"
  WATCHDOG_BOOTSTRAP_PATH="$SYSTEM_DIR/Application Support/macprovider/macprovider-health-monitor"
  HEADLESS_WATCHDOG_LOG_DIR="$SYSTEM_DIR/Logs/macprovider"
  HEADLESS_WATCHDOG_STATE_DIR="$SYSTEM_DIR/Application Support/macprovider/watchdog-state"
  PLIST_PATH="$CONFIG_DIR/launchd/live.malibu.provider.plist"
  PLIST_BOOTSTRAP_PATH="$SYSTEM_DIR/live.malibu.provider.plist"
  LEGACY_PLIST_PATH="$CONFIG_DIR/launchd/live.streamvc.macprovider.plist"
  LEGACY_PLIST_BOOTSTRAP_PATH="$SYSTEM_DIR/live.streamvc.macprovider.plist"
  WATCHDOG_PLIST_PATH="$CONFIG_DIR/launchd/live.malibu.provider-watchdog.plist"
  WATCHDOG_PLIST_BOOTSTRAP_PATH="$SYSTEM_DIR/live.malibu.provider-watchdog.plist"
  LEGACY_WATCHDOG_PLIST_PATH="$CONFIG_DIR/launchd/live.streamvc.macprovider-watchdog.plist"
  LEGACY_WATCHDOG_PLIST_BOOTSTRAP_PATH="$SYSTEM_DIR/live.streamvc.macprovider-watchdog.plist"
  PROVIDER_LABEL=live.malibu.provider
  LEGACY_PROVIDER_LABEL=live.streamvc.macprovider
  WATCHDOG_LABEL=live.malibu.provider-watchdog
  LEGACY_WATCHDOG_LABEL=live.streamvc.macprovider-watchdog
  DRY_RUN=0 NO_LAUNCHD=0 NO_WATCHDOG=0
  INSTALL_TX_ACTIVE=1 INSTALL_TX_BACKUP="$CONFIG_DIR/install-recovery-fixture"
  INSTALL_TX_HAD_PLIST=0 INSTALL_TX_HAD_WATCHDOG_PLIST=0
  LAUNCHD_INSTALLED=0 WATCHDOG_INSTALLED=0

  validate_launchd_mode
  if (NO_LAUNCHD=1 validate_launchd_mode); then
    echo "headless mode unexpectedly accepted MACPROVIDER_NO_LAUNCHD=1" >&2
    exit 1
  fi
  if (NO_WATCHDOG=1 validate_launchd_mode); then
    echo "headless mode unexpectedly accepted MACPROVIDER_NO_WATCHDOG=1" >&2
    exit 1
  fi

  mkdir -p "$INSTALL_TX_BACKUP"
  printf "state=fixture\n" > "$INSTALL_TX_BACKUP/state.sh"
  printf "#!/usr/bin/env bash\nexit 0\n" > "$INSTALL_TX_BACKUP/recover.sh"
  printf "#!/usr/bin/env bash\nexit 0\n" > "$INSTALL_TX_BACKUP/observe.sh"
  chmod 0700 "$INSTALL_TX_BACKUP/recover.sh" "$INSTALL_TX_BACKUP/observe.sh"
  PORT=7777
  if (MACPROVIDER_PROVIDER_TOKEN=secret-token validate_provider_token_environment); then
    echo "installer unexpectedly accepted MACPROVIDER_PROVIDER_TOKEN from the environment" >&2
    exit 1
  fi
  validate_provider_token_environment
  write_config "model" "provider" "wss://coordinator.example/ws/provider"
  [ -O "$CONFIG_DIR" ] && [ -O "$CONFIG_PATH" ]
  grep -Fxq "credential_store: protected_file" "$CONFIG_PATH"
  grep -Fxq "auto_update_enabled: false" "$CONFIG_PATH"
  sed -i.bak -e "s/auto_update_enabled: false/auto_update_enabled: true/" "$CONFIG_PATH"
  rm -f "$CONFIG_PATH.bak"
  enforce_headless_config_overrides
  grep -Fxq "credential_store: protected_file" "$CONFIG_PATH"
  grep -Fxq "auto_update_enabled: false" "$CONFIG_PATH"
  printf "provider_token: secret-token\n" >> "$CONFIG_PATH"
  scrub_config_provider_token
  [ -z "$(read_config_provider_token_line || true)" ]
  grep -Fxq "credential_store: protected_file" "$CONFIG_PATH"
  printf '"provider_token": "quoted-secret"\n' >> "$CONFIG_PATH"
  [ -n "$(read_config_provider_token_line || true)" ]
  scrub_config_provider_token
  [ -z "$(read_config_provider_token_line || true)" ]
  ! grep -Fq "quoted-secret" "$CONFIG_PATH"
  printf "%s\n" '"provider\u005ftoken": "escaped-secret"' >> "$CONFIG_PATH"
  [ -n "$(read_config_provider_token_line || true)" ]
  scrub_config_provider_token
  [ -z "$(read_config_provider_token_line || true)" ]
  ! grep -Fq "escaped-secret" "$CONFIG_PATH"
  printf "provider_token: |-\n  block-secret\nmodel: model\n" >> "$CONFIG_PATH"
  scrub_config_provider_token
  [ -z "$(read_config_provider_token_line || true)" ]
  ! grep -Fq "block-secret" "$CONFIG_PATH"
  grep -Fxq "model: model" "$CONFIG_PATH"

  arm_install_recovery_agent
  [ ! -s "$LAUNCHD_LOG" ]

  install_plist "model" "provider" "wss://coordinator.example/ws/provider"
  install_watchdog "wss://coordinator.example/ws/provider"
  [ "$LAUNCHD_INSTALLED" -eq 1 ] && [ "$WATCHDOG_INSTALLED" -eq 1 ]
  [ -O "$WATCHDOG_DIR" ] && [ -O "$WATCHDOG_PATH" ]
  [ -f "$WATCHDOG_BOOTSTRAP_PATH" ]
  [ -d "$HEADLESS_WATCHDOG_LOG_DIR" ]
  [ -d "$HEADLESS_WATCHDOG_STATE_DIR" ]
  cmp -s "$WATCHDOG_PATH" "$WATCHDOG_BOOTSTRAP_PATH"
  [ -O "$PLIST_PATH" ] && [ -O "$WATCHDOG_PLIST_PATH" ]
  cmp -s "$PLIST_PATH" "$PLIST_BOOTSTRAP_PATH"
  cmp -s "$WATCHDOG_PLIST_PATH" "$WATCHDOG_PLIST_BOOTSTRAP_PATH"

  for plist in "$PLIST_PATH" "$WATCHDOG_PLIST_PATH"; do
    grep -Fq "<key>MACPROVIDER_HEADLESS</key>" "$plist"
    grep -Fq "<string>1</string>" "$plist"
    grep -Fq "<key>MACPROVIDER_CREDENTIAL_STORE</key>" "$plist"
    grep -Fq "<string>protected_file</string>" "$plist"
    grep -Fq "<key>MACPROVIDER_PROTECTED_CREDENTIAL_ROOT</key>" "$plist"
    grep -Fq "<string>$CONFIG_DIR/protected-credentials</string>" "$plist"
    grep -Fq "<key>MACPROVIDER_LAUNCHD_DOMAIN</key>" "$plist"
    grep -Fq "<string>system</string>" "$plist"
  done
  grep -Fq "<key>UserName</key>" "$PLIST_PATH"
  grep -Fq "<string>$HEADLESS_USER</string>" "$PLIST_PATH"
  ! grep -Fq "<key>UserName</key>" "$WATCHDOG_PLIST_PATH"
  grep -Fxq "enable system/live.malibu.provider" "$LAUNCHD_LOG"
  grep -Fxq "bootstrap system $PLIST_BOOTSTRAP_PATH" "$LAUNCHD_LOG"
  grep -Fxq "enable system/live.malibu.provider-watchdog" "$LAUNCHD_LOG"
  grep -Fxq "bootstrap system $WATCHDOG_PLIST_BOOTSTRAP_PATH" "$LAUNCHD_LOG"
  grep -Fq "<key>MACPROVIDER_LAUNCHCTL</key>" "$WATCHDOG_PLIST_PATH"
  grep -Fq "<string>/bin/launchctl</string>" "$WATCHDOG_PLIST_PATH"
  grep -Fq "<key>PATH</key>" "$WATCHDOG_PLIST_PATH"
  grep -Fq "<string>/usr/bin:/bin:/usr/sbin:/sbin</string>" "$WATCHDOG_PLIST_PATH"
  ! grep -Fq "/opt/homebrew/bin" "$WATCHDOG_PLIST_PATH"
  ! grep -Fq "/usr/local/bin" "$WATCHDOG_PLIST_PATH"
  grep -Fq "<string>$WATCHDOG_BOOTSTRAP_PATH</string>" "$WATCHDOG_PLIST_PATH"
  grep -Fq "<key>MACPROVIDER_LOG_DIR</key>" "$WATCHDOG_PLIST_PATH"
  grep -Fq "<string>$HEADLESS_WATCHDOG_LOG_DIR</string>" "$WATCHDOG_PLIST_PATH"
  grep -Fq "<key>MACPROVIDER_WATCHDOG_STATE_DIR</key>" "$WATCHDOG_PLIST_PATH"
  grep -Fq "<string>$HEADLESS_WATCHDOG_STATE_DIR</string>" "$WATCHDOG_PLIST_PATH"
  grep -Fq "<key>MACPROVIDER_LIFECYCLE_LEASE_PATH</key>" "$WATCHDOG_PLIST_PATH"
  grep -Fq "<string>$LIFECYCLE_LEASE_PATH</string>" "$WATCHDOG_PLIST_PATH"
  grep -Fq "<key>MACPROVIDER_LIFECYCLE_LEASE_OWNER_UID</key>" "$WATCHDOG_PLIST_PATH"
  grep -Fq "<string>$(id -u)</string>" "$WATCHDOG_PLIST_PATH"
  grep -Fq "valid_lifecycle_lease_record startup" "$WATCHDOG_PATH"
  ! grep -Fq "lifecycle-lease status --expected-kind" "$WATCHDOG_PATH"
  ! grep -Fq "/usr/bin/sudo -n" "$WATCHDOG_PATH"
  REC_HEADLESS_USER="$HEADLESS_USER"
  REC_INSTALL_DIR="$INSTALL_DIR"
  REC_WATCHDOG_DIR="$WATCHDOG_DIR"
  REC_CONFIG_PATH="$CONFIG_PATH"
  validate_recovery_launchdaemon_plist \
    "$PLIST_PATH" "/Library/LaunchDaemons/live.malibu.provider.plist"
  recovery_watchdog_plist="$CONFIG_DIR/launchd/recovery-watchdog.plist"
  python3 - "$recovery_watchdog_plist" "$CONFIG_PATH" "$CONFIG_DIR/protected-credentials" <<PY
import plistlib
import sys

path, config_path, credential_root = sys.argv[1:]
payload = {
    "Label": "live.malibu.provider-watchdog",
    "ProgramArguments": ["/Library/Application Support/macprovider/macprovider-health-monitor"],
    "EnvironmentVariables": {
        "MACPROVIDER_CONFIG_PATH": config_path,
        "MACPROVIDER_HEADLESS": "1",
        "MACPROVIDER_HEADLESS_USER": "$(id -un)",
        "MACPROVIDER_LAUNCHD_DOMAIN": "system",
        "MACPROVIDER_PROTECTED_CREDENTIAL_ROOT": credential_root,
    },
}
with open(path, "wb") as handle:
    plistlib.dump(payload, handle)
PY
  validate_recovery_launchdaemon_plist \
    "$recovery_watchdog_plist" "/Library/LaunchDaemons/live.malibu.provider-watchdog.plist"
  snapshot_recovery_launchdaemon_plist \
    "$recovery_watchdog_plist" "/Library/LaunchDaemons/live.malibu.provider-watchdog.plist" >/dev/null
  python3 - "$recovery_watchdog_plist" "$HEADLESS_USER" <<PY
import plistlib
import sys

path, user = sys.argv[1:]
with open(path, "rb") as handle:
    payload = plistlib.load(handle)
payload["UserName"] = user
with open(path, "wb") as handle:
    plistlib.dump(payload, handle)
PY
  if (validate_recovery_launchdaemon_plist "$recovery_watchdog_plist" "/Library/LaunchDaemons/live.malibu.provider-watchdog.plist"); then
    echo "headless recovery unexpectedly accepted a non-root watchdog LaunchDaemon" >&2
    exit 1
  fi
  if (snapshot_recovery_launchdaemon_plist "$recovery_watchdog_plist" "/Library/LaunchDaemons/live.malibu.provider-watchdog.plist" >/dev/null); then
    echo "headless recovery snapshot unexpectedly accepted a non-root watchdog LaunchDaemon" >&2
    exit 1
  fi
  write_install_manifest "1.2.3"
  grep -Fq "\"install_profile\": \"headless_fleet\"" "$MANIFEST_PATH"
  grep -Fq "\"launchd_domain\": \"system\"" "$MANIFEST_PATH"
  grep -Fq "\"provider_config_root\": \"$CONFIG_DIR\"" "$MANIFEST_PATH"

  mkdir -p "$HOME/Library/LaunchAgents"
  consumer_plist="$HOME/Library/LaunchAgents/live.malibu.provider.plist"
  : > "$consumer_plist"
  if (validate_headless_install_topology); then
    echo "headless mode unexpectedly accepted a consumer LaunchAgent install" >&2
    exit 1
  fi
  rm -f "$consumer_plist"
  other_consumer_plist="$USERS_DIR/other/Library/LaunchAgents/live.malibu.provider.plist"
  : > "$other_consumer_plist"
  if (validate_headless_install_topology); then
    echo "headless mode unexpectedly accepted another user consumer LaunchAgent install" >&2
    exit 1
  fi
  rm -f "$other_consumer_plist"
  validate_headless_install_topology
  LAUNCHD_PRINT_STATUS=125 validate_headless_install_topology
  if (LAUNCHD_PRINT_STATUS=64 validate_headless_install_topology); then
    echo "headless topology unexpectedly accepted an indeterminate launchctl print result" >&2
    exit 1
  fi

  system_plist="$SYSTEM_DIR/live.malibu.provider.plist"
  : > "$system_plist"
  if (HEADLESS=0; validate_headless_install_topology); then
    echo "consumer mode unexpectedly accepted a headless LaunchDaemon install" >&2
    exit 1
  fi
  rm -f "$system_plist"
  if (HEADLESS=0 LAUNCHD_PRINT_STATUS=125 validate_headless_install_topology); then
    echo "consumer mode unexpectedly accepted indeterminate system launchctl print status 125" >&2
    exit 1
  fi

  rm -rf "$INSTALL_TX_BACKUP"
  orphan="$CONFIG_DIR/install-recovery-interrupted"
  mkdir -p "$orphan"
  printf "state=fixture\n" > "$orphan/state.sh"
  cat > "$orphan/recover.sh" <<EOF_RECOVERY
#!/usr/bin/env bash
sudo -n launchctl print system/live.malibu.provider >/dev/null 2>&1 || true
exit 0
EOF_RECOVERY
  chmod 0700 "$orphan/recover.sh"
  publish_headless_recovery_trust "$orphan"
  printf "# tampered\n" >> "$orphan/recover.sh"
  if verify_headless_recovery_trust "$orphan"; then
    echo "tampered headless recovery unexpectedly matched root-owned trust receipt" >&2
    exit 1
  fi
  sed -i.bak -e "\$d" "$orphan/recover.sh"
  rm -f "$orphan/recover.sh.bak"
  publish_headless_recovery_trust "$orphan"
  INSTALL_LOCK_PATH="$CONFIG_DIR/install.lock"
  recover_orphaned_install_transactions
  [ ! -e "$orphan" ]
'

printf '[install-headless-fleet-test] system-domain bootstrap and deferred recovery ok\n'
