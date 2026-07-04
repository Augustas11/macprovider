#!/usr/bin/env bash
# check_pearl_tcp_test.sh — offline validation for the Pearl TCP sysctl
# artifact and deploy-pearl-vps.sh step 3b/9.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DIST_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
SYSCTL_FILE="$DIST_DIR/sysctl.d/99-macprovider-tcp.conf"
MODULES_LOAD_FILE="$DIST_DIR/modules-load.d/tcp_bbr.conf"
DEPLOY_SH="$DIST_DIR/deploy-pearl-vps.sh"

fail() {
  echo "FAIL: $*" >&2
  exit 1
}

[ -f "$SYSCTL_FILE" ] || fail "missing sysctl file: $SYSCTL_FILE"
[ -f "$MODULES_LOAD_FILE" ] || fail "missing modules-load file: $MODULES_LOAD_FILE"
[ -f "$DEPLOY_SH" ] || fail "missing deploy script: $DEPLOY_SH"

EXPECTED="$(mktemp -t pearl-tcp-expected.XXXXXX)"
trap 'rm -f "$EXPECTED"' EXIT
cat > "$EXPECTED" <<'EOF'
# 99-macprovider-tcp.conf — Pearl VPS TCP tuning for streaming SSE.
# Managed by phase4-coordinator/dist/deploy-pearl-vps.sh; do not
# edit by hand.
#
# Applies to all outbound sockets on this host: nginx → buyer,
# gateway → coord, coord → provider WSS. See PR #<PR> and the
# 2026-07-04 inter-token latency bisection for the measurement
# that motivated each knob.

# BBR handles jitter / bufferbloat better than cubic. Requires the
# tcp_bbr kernel module; deploy-pearl-vps.sh verifies availability.
net.ipv4.tcp_congestion_control=bbr

# Do NOT reset the congestion window after an idle period. WSS
# provider tunnels spend tens of seconds idle between token bursts;
# without this each burst restarts slow-start and eats several RTTs.
net.ipv4.tcp_slow_start_after_idle=0

# Raise socket send/receive buffer ceilings from the Ubuntu default
# (~416 KB) to 16 MB. Removes a soft cap on streaming responses on
# high-BDP paths. Actual per-socket allocation grows only under load.
net.core.rmem_max=16777216
net.core.wmem_max=16777216
EOF

if ! cmp -s "$EXPECTED" "$SYSCTL_FILE"; then
  diff -u "$EXPECTED" "$SYSCTL_FILE" >&2 || true
  fail "sysctl file does not match expected contents byte-for-byte"
fi

for line in \
  "net.ipv4.tcp_congestion_control=bbr" \
  "net.ipv4.tcp_slow_start_after_idle=0" \
  "net.core.rmem_max=16777216" \
  "net.core.wmem_max=16777216"; do
  grep -qxF "$line" "$SYSCTL_FILE" || fail "missing expected sysctl: $line"
done

key_count="$(grep -Ec '^[a-z0-9_.]+=' "$SYSCTL_FILE")"
[ "$key_count" = "4" ] || fail "expected exactly 4 sysctl keys, found $key_count"
while IFS= read -r line; do
  case "$line" in
    net.ipv4.tcp_congestion_control=bbr|\
    net.ipv4.tcp_slow_start_after_idle=0|\
    net.core.rmem_max=16777216|\
    net.core.wmem_max=16777216)
      ;;
    *)
      fail "unexpected sysctl key line: $line"
      ;;
  esac
done < <(grep -E '^[a-z0-9_.]+=' "$SYSCTL_FILE")

if LC_ALL=C grep -q $'\r' "$SYSCTL_FILE"; then
  fail "sysctl file contains CRLF line endings"
fi
if awk '/[^[:space:]]/ && /[[:blank:]]$/ { print; bad=1 } END { exit bad }' "$SYSCTL_FILE" >&2; then
  :
else
  fail "sysctl file contains trailing whitespace on non-blank lines"
fi
last_byte="$(tail -c 1 "$SYSCTL_FILE" | od -An -t x1 | tr -d ' \n')"
[ "$last_byte" = "0a" ] || fail "sysctl file does not end with a newline"
if [ "$(tail -c 2 "$SYSCTL_FILE" | od -An -t x1 | tr -s ' ' | sed 's/^ //;s/ $//')" = "0a 0a" ]; then
  fail "sysctl file ends with more than one newline"
fi

modules_non_comment="$(sed -E '/^[[:space:]]*($|#)/d; s/^[[:space:]]+|[[:space:]]+$//g' "$MODULES_LOAD_FILE")"
[ "$modules_non_comment" = "tcp_bbr" ] ||
  fail "modules-load file must contain exactly tcp_bbr as non-comment content"
if LC_ALL=C grep -q $'\r' "$MODULES_LOAD_FILE"; then
  fail "modules-load file contains CRLF line endings"
fi
if awk '/[^[:space:]]/ && /[[:blank:]]$/ { print; bad=1 } END { exit bad }' "$MODULES_LOAD_FILE" >&2; then
  :
else
  fail "modules-load file contains trailing whitespace on non-blank lines"
fi
modules_last_byte="$(tail -c 1 "$MODULES_LOAD_FILE" | od -An -t x1 | tr -d ' \n')"
[ "$modules_last_byte" = "0a" ] || fail "modules-load file does not end with a newline"

grep -qF "log \"step 3b/9: install TCP sysctl overrides\"" "$DEPLOY_SH" ||
  fail "deploy script missing step 3b/9 log line"
grep -qF "SKIP_TCP_TUNING" "$DEPLOY_SH" ||
  fail "deploy script missing SKIP_TCP_TUNING escape hatch"
grep -qF '[ -f "$TCP_SYSCTL" ] || { echo "missing required file: $TCP_SYSCTL" >&2; exit 1; }' "$DEPLOY_SH" ||
  fail "deploy script must require TCP sysctl artifact only inside the non-skip branch"
grep -qF '[ -f "$TCP_BBR_MODULES_LOAD" ] || { echo "missing required file: $TCP_BBR_MODULES_LOAD" >&2; exit 1; }' "$DEPLOY_SH" ||
  fail "deploy script must require TCP BBR modules-load artifact only inside the non-skip branch"
grep -qF "mktemp -d -t macprovider-tcp.XXXXXXXX" "$DEPLOY_SH" ||
  fail "deploy script missing private remote staging directory for TCP sysctl file"
grep -qF '$SCP "$TCP_SYSCTL" "$VPS_USER@$VPS_HOST:$TCP_SYSCTL_TMP/macprovider-tcp.conf"' "$DEPLOY_SH" ||
  fail "deploy script missing scp of TCP sysctl file to private staging path"
grep -qF '$SCP "$TCP_BBR_MODULES_LOAD" "$VPS_USER@$VPS_HOST:$TCP_SYSCTL_TMP/tcp_bbr.conf"' "$DEPLOY_SH" ||
  fail "deploy script missing scp of TCP BBR modules-load file to private staging path"
grep -qF "modprobe -n -v tcp_bbr" "$DEPLOY_SH" ||
  fail "deploy script missing tcp_bbr dry-run presence check"
grep -qF "modprobe tcp_bbr" "$DEPLOY_SH" ||
  fail "deploy script missing tcp_bbr load step"
grep -qF 'kernel="$(uname -r)"' "$DEPLOY_SH" ||
  fail "deploy script missing uname -r capture for tcp_bbr failure message"
grep -qF 'linux-modules-extra-$kernel' "$DEPLOY_SH" ||
  fail "deploy script missing targeted linux-modules-extra remediation message"
grep -qF 'dst="/etc/sysctl.d/99-macprovider-tcp.conf"' "$DEPLOY_SH" ||
  fail "deploy script missing sysctl destination path"
grep -qF 'modules_load_dst="/etc/modules-load.d/tcp_bbr.conf"' "$DEPLOY_SH" ||
  fail "deploy script missing tcp_bbr modules-load destination path"
grep -qF 'install -m 0644 -o root -g root "$tmp_conf" "$dst"' "$DEPLOY_SH" ||
  fail "deploy script missing root:root 0644 sysctl install"
grep -qF 'install -m 0644 -o root -g root "$tmp_modules_load" "$modules_load_dst"' "$DEPLOY_SH" ||
  fail "deploy script missing root:root 0644 modules-load install"
grep -qF 'sysctl -p "$dst"' "$DEPLOY_SH" ||
  fail "deploy script missing file-scoped sysctl apply"
grep -qF "expect_sysctl net.ipv4.tcp_congestion_control bbr" "$DEPLOY_SH" ||
  fail "deploy script missing post-apply BBR active congestion-control verification"
grep -qF 'cmp -s "$tmp_conf" /etc/sysctl.d/99-macprovider-tcp.conf' "$DEPLOY_SH" ||
  fail "deploy script missing idempotency cmp against installed sysctl file"
grep -qF 'cmp -s "$tmp_modules_load" /etc/modules-load.d/tcp_bbr.conf' "$DEPLOY_SH" ||
  fail "deploy script missing idempotency cmp against installed modules-load file"
grep -qF 'echo "already"' "$DEPLOY_SH" ||
  fail "deploy script missing already-applied idempotency result"
grep -qF 'while IFS='\''='\'' read -r key expected' "$DEPLOY_SH" ||
  fail "deploy script must parse expected sysctl keys from the staged conf"
if grep -qF "expect_sysctl net.ipv4.tcp_slow_start_after_idle 0" "$DEPLOY_SH" ||
   grep -qF "expect_sysctl net.core.rmem_max 16777216" "$DEPLOY_SH" ||
   grep -qF "expect_sysctl net.core.wmem_max 16777216" "$DEPLOY_SH"; then
  fail "deploy script hardcodes non-BBR sysctl verification keys instead of parsing the conf"
fi
grep -qF 'log "  WARN: found unexpected macprovider sysctl artifacts on Pearl:"' "$DEPLOY_SH" ||
  fail "deploy script missing unexpected macprovider sysctl artifact warning"
grep -qF 'These are not managed by this deploy; consider removing after verifying they are stale.' "$DEPLOY_SH" ||
  fail "deploy script missing unexpected macprovider sysctl cleanup guidance"
grep -qF 'step 3b/9 failure — kernel TCP state may be partially mutated.' "$DEPLOY_SH" ||
  fail "deploy script missing partial-apply rollback warning"
grep -qF 'Rollback: sudo rm /etc/sysctl.d/99-macprovider-tcp.conf /etc/modules-load.d/tcp_bbr.conf && sudo sysctl --system' "$DEPLOY_SH" ||
  fail "deploy script missing rollback command"
if grep -qF "/tmp/macprovider-tcp.conf" "$DEPLOY_SH"; then
  fail "deploy script uses predictable /tmp TCP sysctl staging path"
fi
if grep -qE 'sysctl[[:space:]]+-w|/etc/sysctl\.conf' "$DEPLOY_SH"; then
  fail "deploy script uses a prohibited sysctl apply path"
fi

echo "PASS: Pearl TCP sysctl artifact and deploy hook validated"
