#!/usr/bin/env bash
set -euo pipefail

unit=macprovider-pearl-gate-test.service
unit_path=/run/systemd/system/$unit
gate="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/macprovider-pearl-update-gate"

if [ "$(uname -s)" != Linux ] || [ "$(id -u)" -ne 0 ] || ! command -v systemctl >/dev/null 2>&1; then
  echo "SKIP: transaction-gate systemd integration requires Linux root"
  exit 0
fi
if ! systemctl show-environment >/dev/null 2>&1; then
  echo "SKIP: transaction-gate systemd integration requires a running systemd manager"
  exit 0
fi

exec 8>/run/lock/macprovider-pearl-gate-systemd-test.lock
flock -x 8
if [ -e "$unit_path" ] || systemctl cat "$unit" >/dev/null 2>&1; then
  echo "refusing to replace existing $unit" >&2
  exit 1
fi

work="$(mktemp -d /var/tmp/macprovider-pearl-gate-systemd.XXXXXX)"
journal="$work/active-transaction.json"
gate_root="$work/gate-runtime"
boot_id="$work/boot-id"
lock="$work/updater.lock"

cleanup() {
  systemctl stop "$unit" >/dev/null 2>&1 || true
  systemctl reset-failed "$unit" >/dev/null 2>&1 || true
  rm -f "$unit_path"
  systemctl daemon-reload >/dev/null 2>&1 || true
  rm -rf "$work"
}
trap cleanup EXIT

chmod 0700 "$work"
install -d -o root -g root -m 0700 "$gate_root" "$gate_root/permits"
install -o root -g root -m 0600 /dev/null "$boot_id"
cat /proc/sys/kernel/random/boot_id >"$boot_id"
install -o root -g root -m 0600 /dev/null "$lock"

cat >"$unit_path" <<EOF
[Unit]
Description=Pearl transaction gate credential integration test

[Service]
Type=oneshot
DynamicUser=yes
NoNewPrivileges=yes
Environment=MACPROVIDER_UPDATER_GATE_TESTING=1
Environment=PEARL_UPDATER_GATE_JOURNAL=$journal
Environment=PEARL_UPDATER_GATE_ROOT=$gate_root
Environment=PEARL_UPDATER_GATE_BOOT_ID=$boot_id
Environment=PEARL_UPDATER_GATE_LOCK=$lock
ExecStartPre=+$gate %n
ExecStart=/bin/sh -c 'test "\$\$(id -u)" -ne 0'
RemainAfterExit=yes
EOF
chmod 0644 "$unit_path"
systemctl daemon-reload

# With no journal, a root gate can inspect the absent file through the 0700
# parent while the DynamicUser service body still proves it runs unprivileged.
systemctl start "$unit"
systemctl stop "$unit"

transaction_id="$(printf 'a%.0s' {1..64})"
nonce="$(printf 'b%.0s' {1..64})"
boot_value="$(tr -d '\n' <"$boot_id")"
expires_at="$(( $(date +%s) + 300 ))"
cat >"$journal" <<EOF
{"schema_version":1,"transaction_id":"$transaction_id","boot_id":"$boot_value"}
EOF
chmod 0600 "$journal"
permit="$gate_root/permits/$unit.json"
cat >"$permit" <<EOF
{"schema_version":1,"unit":"$unit","transaction_id":"$transaction_id","boot_id":"$boot_value","expires_at":$expires_at,"nonce":"$nonce"}
EOF
chmod 0600 "$permit"

exec 9<>"$lock"
flock -x 9
systemctl start "$unit"
test ! -e "$permit"
systemctl stop "$unit"
if systemctl start "$unit" >/dev/null 2>&1; then
  echo "transaction gate reused a consumed permit" >&2
  exit 1
fi

echo "PASS: privileged transaction gate protects DynamicUser services and consumes one permit"
