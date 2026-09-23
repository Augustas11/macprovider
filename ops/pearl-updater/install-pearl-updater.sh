#!/usr/bin/env bash
set -euo pipefail

TESTING="${MACPROVIDER_UPDATER_TESTING:-0}"
INSTALL_PREFIX="${MACPROVIDER_UPDATER_INSTALL_ROOT:-}"
INSTALL_OWNER="${MACPROVIDER_UPDATER_INSTALL_OWNER:-root}"
INSTALL_ROOT_GROUP="${MACPROVIDER_UPDATER_INSTALL_ROOT_GROUP:-root}"
INSTALL_GROUP="${MACPROVIDER_UPDATER_INSTALL_GROUP:-macprovider}"
SKIP_SYSTEMD="${MACPROVIDER_UPDATER_SKIP_SYSTEMD:-0}"

if [ "$TESTING" != "1" ] && { [ -n "$INSTALL_PREFIX" ] || [ "$INSTALL_OWNER" != root ] || [ "$INSTALL_ROOT_GROUP" != root ] || [ "$INSTALL_GROUP" != macprovider ] || [ "$SKIP_SYSTEMD" != 0 ]; }; then
  echo "installer path/identity overrides are test-only" >&2
  exit 1
fi
if [ -n "$INSTALL_PREFIX" ] && [[ "$INSTALL_PREFIX" != /* ]]; then
  echo "test install root must be absolute" >&2
  exit 1
fi
if [ "$(id -u)" -ne 0 ] && [ "$TESTING" != "1" ]; then
  echo "install-pearl-updater.sh must run as root" >&2
  exit 1
fi

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

if [ "$TESTING" != "1" ]; then
  for required_command in python3 openssl sqlite3 ssh systemctl setpriv unshare chroot getent groupadd useradd; do
    if ! command -v "$required_command" >/dev/null 2>&1; then
      echo "required command is missing: $required_command" >&2
      exit 1
    fi
  done
fi
python3 -c 'import sys; raise SystemExit(0 if sys.version_info >= (3, 10) else 1)' || {
  echo "Python 3.10 or newer is required" >&2
  exit 1
}
if [ "$TESTING" != "1" ]; then
  id macprovider >/dev/null 2>&1 || {
  echo "macprovider service account is missing" >&2
  exit 1
  }
  if ! getent group macprovider-updater-validate >/dev/null; then
    groupadd --system macprovider-updater-validate
  fi
  if ! id macprovider-updater-validate >/dev/null 2>&1; then
    useradd --system --gid macprovider-updater-validate --home-dir /nonexistent \
      --shell /usr/sbin/nologin --no-create-home macprovider-updater-validate
  fi
  VALIDATOR_UID="$(id -u macprovider-updater-validate)"
  VALIDATOR_GID="$(id -g macprovider-updater-validate)"
  if [ "$VALIDATOR_UID" -eq 0 ] || [ "$VALIDATOR_GID" -eq 0 ]; then
    echo "macprovider-updater-validate must not use the root uid or gid" >&2
    exit 1
  fi
fi
openssl pkey -pubin -in "$HERE/release-signing-public.pem" -noout >/dev/null

install -d -o "$INSTALL_OWNER" -g "$INSTALL_ROOT_GROUP" -m 0755 "$INSTALL_PREFIX/usr/local/share/macprovider"
install -d -o "$INSTALL_OWNER" -g "$INSTALL_ROOT_GROUP" -m 0755 "$INSTALL_PREFIX/usr/local/share/macprovider/scripts"
install -d -o "$INSTALL_OWNER" -g "$INSTALL_GROUP" -m 0750 "$INSTALL_PREFIX/etc/macprovider"
install -d -o "$INSTALL_OWNER" -g "$INSTALL_ROOT_GROUP" -m 0700 "$INSTALL_PREFIX/var/lib/macprovider-pearl-updater"
install -d -o "$INSTALL_OWNER" -g "$INSTALL_ROOT_GROUP" -m 0755 "$INSTALL_PREFIX/usr/local/sbin" "$INSTALL_PREFIX/etc/systemd/system"
install -o "$INSTALL_OWNER" -g "$INSTALL_ROOT_GROUP" -m 0755 "$HERE/macprovider-pearl-update" "$INSTALL_PREFIX/usr/local/sbin/macprovider-pearl-update"
install -o "$INSTALL_OWNER" -g "$INSTALL_ROOT_GROUP" -m 0755 "$HERE/macprovider-tier2-enforcement-watchdog" "$INSTALL_PREFIX/usr/local/sbin/macprovider-tier2-enforcement-watchdog"
install -o "$INSTALL_OWNER" -g "$INSTALL_ROOT_GROUP" -m 0755 "$HERE/macprovider-pearl-update-gate" "$INSTALL_PREFIX/usr/local/sbin/macprovider-pearl-update-gate"
install -o "$INSTALL_OWNER" -g "$INSTALL_ROOT_GROUP" -m 0755 "$HERE/macprovider-pearl-updater-alert" "$INSTALL_PREFIX/usr/local/sbin/macprovider-pearl-updater-alert"
install -o "$INSTALL_OWNER" -g "$INSTALL_ROOT_GROUP" -m 0644 "$HERE/release-signing-public.pem" "$INSTALL_PREFIX/usr/local/share/macprovider/release-signing-public.pem"
# #1688: ship exactly the catalog verifier bundle deploy-pearl-vps.sh ships.
bundle_seen=" "
while IFS= read -r bundle_path || [ -n "$bundle_path" ]; do
  case "$bundle_path" in '#'*) continue ;; esac
  if ! printf '%s\n' "$bundle_path" | grep -Eq '^scripts/[A-Za-z0-9._-]+$' ||
    [ "$bundle_path" = "scripts/." ] || [ "$bundle_path" = "scripts/.." ]; then
    echo "invalid catalog verifier bundle entry: '$bundle_path'" >&2
    exit 1
  fi
  case "$bundle_seen" in
    *" $bundle_path "*)
      echo "duplicate catalog verifier bundle entry: $bundle_path" >&2
      exit 1
      ;;
  esac
  bundle_seen="$bundle_seen$bundle_path "
  install -o "$INSTALL_OWNER" -g "$INSTALL_ROOT_GROUP" -m 0644 "$HERE/../../$bundle_path" "$INSTALL_PREFIX/usr/local/share/macprovider/$bundle_path"
done < "$HERE/../../scripts/catalog-verifier-bundle.txt"
case "$bundle_seen" in
  *" scripts/catalog-release.py "*) ;;
  *)
    echo "catalog verifier bundle must list scripts/catalog-release.py" >&2
    exit 1
    ;;
esac
# #1693 L0: the updater and the Tier-2 enforcement watchdog load the shared
# one-writer guard from here and fail closed without it.
install -o "$INSTALL_OWNER" -g "$INSTALL_ROOT_GROUP" -m 0644 "$HERE/../../scripts/lib/coordinator_config_guard.py" "$INSTALL_PREFIX/usr/local/share/macprovider/scripts/coordinator_config_guard.py"
install -o "$INSTALL_OWNER" -g "$INSTALL_ROOT_GROUP" -m 0644 "$HERE/catalog-canary-proof.py" "$INSTALL_PREFIX/usr/local/share/macprovider/catalog-canary-proof.py"
install -o "$INSTALL_OWNER" -g "$INSTALL_ROOT_GROUP" -m 0644 "$HERE/macprovider-pearl-updater.service" "$INSTALL_PREFIX/etc/systemd/system/macprovider-pearl-updater.service"
install -o "$INSTALL_OWNER" -g "$INSTALL_ROOT_GROUP" -m 0644 "$HERE/macprovider-pearl-updater.timer" "$INSTALL_PREFIX/etc/systemd/system/macprovider-pearl-updater.timer"
install -o "$INSTALL_OWNER" -g "$INSTALL_ROOT_GROUP" -m 0644 "$HERE/macprovider-pearl-updater-alert@.service" "$INSTALL_PREFIX/etc/systemd/system/macprovider-pearl-updater-alert@.service"
install -o "$INSTALL_OWNER" -g "$INSTALL_ROOT_GROUP" -m 0644 "$HERE/macprovider-pearl-updater-reconcile.service" "$INSTALL_PREFIX/etc/systemd/system/macprovider-pearl-updater-reconcile.service"
install -o "$INSTALL_OWNER" -g "$INSTALL_ROOT_GROUP" -m 0644 "$HERE/macprovider-tier2-enforcement-reconcile.service" "$INSTALL_PREFIX/etc/systemd/system/macprovider-tier2-enforcement-reconcile.service"

for gated_unit in \
  macprovider-coordinator.service \
  macprovider-gateway.service \
  canary-buyer.service \
  macprovider-archive-rotate.service \
  stats-billing-mirror.service; do
  install -d -o "$INSTALL_OWNER" -g "$INSTALL_ROOT_GROUP" -m 0755 \
    "$INSTALL_PREFIX/etc/systemd/system/${gated_unit}.d"
  install -o "$INSTALL_OWNER" -g "$INSTALL_ROOT_GROUP" -m 0644 \
    "$HERE/macprovider-pearl-updater-transaction-gate.conf" \
    "$INSTALL_PREFIX/etc/systemd/system/${gated_unit}.d/50-pearl-updater-transaction-gate.conf"
done

if [ ! -e "$INSTALL_PREFIX/etc/macprovider/pearl-updater.conf" ]; then
  install -o "$INSTALL_OWNER" -g "$INSTALL_ROOT_GROUP" -m 0600 "$HERE/pearl-updater.conf.example" "$INSTALL_PREFIX/etc/macprovider/pearl-updater.conf"
fi
if [ ! -e "$INSTALL_PREFIX/etc/macprovider/pearl-updater.revoked" ]; then
  install -o "$INSTALL_OWNER" -g "$INSTALL_ROOT_GROUP" -m 0600 "$HERE/pearl-updater.revoked.example" "$INSTALL_PREFIX/etc/macprovider/pearl-updater.revoked"
fi

if [ "$SKIP_SYSTEMD" != "1" ]; then
  systemctl daemon-reload
  systemctl enable macprovider-tier2-enforcement-reconcile.service
  systemctl enable macprovider-pearl-updater-reconcile.service
fi
echo "installed disabled-by-default Pearl updater"
echo "configure the #584 canary authority plus Better Stack heartbeat ID/API token before planning"
echo "plan:  /usr/local/sbin/macprovider-pearl-update --plan"
echo "enable apply in /etc/macprovider/pearl-updater.conf; keep the timer disabled until manual success, failed-rollout rollback, and interrupted committed-success reconciliation drills all pass"
