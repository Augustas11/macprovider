#!/usr/bin/env bash
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/../../.." && pwd)"
INSTALL_SH="$REPO_ROOT/phase3-binary/dist/install.sh"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

awk '/^validate_port_value\(\)/ { inside=1 } inside { print } inside && /^}/ { exit }' "$INSTALL_SH" > "$TMP/validate_port.sh"
python3 - "$INSTALL_SH" > "$TMP/ensure_port.sh" <<'PY'
import sys
lines = open(sys.argv[1], encoding="utf-8").read().splitlines()
inside = False
depth = 0
for line in lines:
    if line.startswith("ensure_port_free()"):
        inside = True
    if not inside:
        continue
    print(line)
    depth += line.count("{") - line.count("}")
    if inside and depth == 0:
        break
PY
cat > "$TMP/harness.sh" <<'HARNESS'
set -euo pipefail
die() { printf "ERR:%s\n" "$*" >&2; exit "$1"; }
log() { printf "LOG:%s\n" "$*" >&2; }
DRY_RUN=0
PORT=18080
INSTALL_DIR="$HOME/macprovider"
PLIST_PATH="/tmp/provider.plist"
HARNESS
cat "$TMP/validate_port.sh" >> "$TMP/harness.sh"
cat "$TMP/ensure_port.sh" >> "$TMP/harness.sh"

assert_rejects() {
  value="$1"
  if bash -c "source '$TMP/harness.sh'; validate_port_value '$value'" >/tmp/install-port.out 2>/tmp/install-port.err; then
    echo "expected port '$value' to reject" >&2
    exit 1
  fi
  grep -Eq 'port must be (numeric|in)' /tmp/install-port.err
}

assert_accepts() {
  value="$1"
  bash -c "source '$TMP/harness.sh'; validate_port_value '$value'"
}

assert_rejects 0
assert_rejects 1023
assert_rejects 65536
assert_rejects 'abc'
assert_rejects '; rm -rf ~/'
assert_accepts 1024
assert_accepts 65535

mkdir -p "$TMP/no-lsof" "$TMP/foreign/bin"
cat > "$TMP/foreign/bin/lsof" <<'EOF'
#!/usr/bin/env bash
case "$*" in
  *-t*) echo 7777 ;;
  *) printf "COMMAND PID\nother 7777\n" ;;
esac
EOF
cat > "$TMP/foreign/bin/pgrep" <<'EOF'
#!/usr/bin/env bash
exit 1
EOF
chmod +x "$TMP/foreign/bin/"*

if PATH="$TMP/no-lsof" /bin/bash -c "source '$TMP/harness.sh'; ensure_port_free" >/tmp/install-port.out 2>/tmp/install-port.err; then
  echo "expected missing lsof to reject" >&2
  exit 1
fi
grep -F 'missing required tool: lsof' /tmp/install-port.err >/dev/null

if PATH="$TMP/foreign/bin:/usr/bin:/bin" bash -c "source '$TMP/harness.sh'; ensure_port_free" >/tmp/install-port.out 2>/tmp/install-port.err; then
  echo "expected foreign in-use port to reject" >&2
  exit 1
fi
grep -F 'port 18080 is already in use' /tmp/install-port.err >/dev/null

mkdir -p "$TMP/own/bin"
cat > "$TMP/own/bin/lsof" <<'EOF'
#!/usr/bin/env bash
case "$*" in
  *"-d txt"*) printf 'p4242\nn%s/macprovider/malibu-cli\n' "$HOME" ;;
  *-t*) echo 4242 ;;
  *) printf "COMMAND PID\nmalibu-cli 4242\n" ;;
esac
EOF
cat > "$TMP/own/bin/pgrep" <<'EOF'
#!/usr/bin/env bash
echo "4242 malibu-cli --port 18080"
EOF
chmod +x "$TMP/own/bin/"*
PATH="$TMP/own/bin:/usr/bin:/bin" bash -c "source '$TMP/harness.sh'; ensure_port_free 0" >/tmp/install-port.out 2>/tmp/install-port.err
grep -F 'will stop it after release verification' /tmp/install-port.err >/dev/null

echo "install port validation ok"
