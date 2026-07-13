#!/usr/bin/env bash
# ADV-H1 + M1(adv): the recovery-capture snapshot must never (1) preserve a
# manual provider that received its bearer on an inherited `--token-fd` (a
# rollback replay with stdin=DEVNULL would feed it an empty bearer), nor
# (2) serialize a secret env var — including one whose key uses non-ASCII
# confusable characters that bypass the ASCII secret-substring filter.
#
# Exact process-argv/env capture uses Darwin's KERN_PROCARGS2 contract, so this
# is a macOS-only lane (matching install_upgrade_evidence_rollback.test.sh).
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/../../.." && pwd)"
INSTALL_SH="$REPO_ROOT/phase3-binary/dist/install.sh"

if [ "$(uname -s)" != "Darwin" ]; then
  echo "skipping Darwin-only manual recovery token-fd/env capture test"
  exit 0
fi

TMP="$(mktemp -d)"
FIXTURE_PID=""
cleanup() {
  [ -z "$FIXTURE_PID" ] || kill "$FIXTURE_PID" >/dev/null 2>&1 || true
  rm -rf "$TMP"
}
trap cleanup EXIT

# Extract capture_manual_provider_for_recovery from the installer verbatim.
python3 - "$INSTALL_SH" > "$TMP/functions.sh" <<'PY'
import sys
names = {"capture_manual_provider_for_recovery"}
lines = open(sys.argv[1], encoding="utf-8").read().splitlines()
i = 0
while i < len(lines):
    name = lines[i].split("()", 1)[0] if "()" in lines[i] else ""
    if name not in names:
        i += 1
        continue
    depth = 0
    while i < len(lines):
        line = lines[i]
        print(line)
        depth += line.count("{") - line.count("}")
        i += 1
        if depth == 0:
            break
PY
[ -s "$TMP/functions.sh" ] || { echo "failed to extract capture function" >&2; exit 1; }

INSTALL_DIR="$TMP/install"
mkdir -p "$INSTALL_DIR" "$TMP/cwd"
BINARY_PATH="$INSTALL_DIR/macprovider-cli"

cat > "$TMP/fixture.c" <<'EOF'
#include <arpa/inet.h>
#include <netinet/in.h>
#include <stdlib.h>
#include <string.h>
#include <sys/socket.h>
#include <unistd.h>
int main(int argc, char **argv) {
  int port = 0;
  for (int i = 1; i + 1 < argc; i++)
    if (strcmp(argv[i], "--port") == 0) port = atoi(argv[i + 1]);
  if (port <= 0) return 2;
  int fd = socket(AF_INET, SOCK_STREAM, 0);
  int yes = 1;
  setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &yes, sizeof(yes));
  struct sockaddr_in addr = {0};
  addr.sin_family = AF_INET;
  addr.sin_addr.s_addr = htonl(INADDR_LOOPBACK);
  addr.sin_port = htons((unsigned short)port);
  if (bind(fd, (struct sockaddr *)&addr, sizeof(addr)) != 0 || listen(fd, 4) != 0) return 3;
  for (;;) pause();
}
EOF
cc -O2 -o "$BINARY_PATH" "$TMP/fixture.c"

PORT="$(python3 -c 'import socket
s = socket.socket()
s.bind(("127.0.0.1", 0))
print(s.getsockname()[1])
s.close()')"

start_fixture() {
  # start_fixture <output-var-unused> [env args...] -- [fixture args...]
  local env_args=() cli_args=() seen_sep=0 arg
  shift # drop the unused output-var placeholder
  for arg in "$@"; do
    if [ "$arg" = "--" ]; then seen_sep=1; continue; fi
    if [ "$seen_sep" -eq 0 ]; then env_args+=("$arg"); else cli_args+=("$arg"); fi
  done
  (
    cd "$TMP/cwd"
    exec env ${env_args[@]+"${env_args[@]}"} "$BINARY_PATH" --port "$PORT" ${cli_args[@]+"${cli_args[@]}"}
  ) &
  FIXTURE_PID=$!
  local i
  for i in $(seq 1 40); do
    if lsof -nP -iTCP:"$PORT" -sTCP:LISTEN -t 2>/dev/null | grep -Fxq "$FIXTURE_PID"; then
      return 0
    fi
    sleep 0.1
  done
  echo "fixture did not bind port $PORT" >&2
  return 1
}

run_capture() {
  local json_out="$1"
  ( set -euo pipefail
    INSTALL_TX_ACTIVE=1
    INSTALL_TX_SERVICE_WAS_ACTIVE=0
    INSTALL_DIR="$INSTALL_DIR"
    BINARY_PATH="$BINARY_PATH"
    PORT="$PORT"
    INSTALL_TX_BACKUP="$(dirname "$json_out")"
    die() { echo "die $*" >&2; exit "${1:-1}"; }
    log() { :; }
    source "$TMP/functions.sh"
    capture_manual_provider_for_recovery "$FIXTURE_PID"
  )
}

stop_fixture() {
  [ -z "$FIXTURE_PID" ] || kill "$FIXTURE_PID" >/dev/null 2>&1 || true
  wait "$FIXTURE_PID" 2>/dev/null || true
  FIXTURE_PID=""
}

# --- Case 1: a --token-fd provider is NOT captured (would replay empty bearer) ---
start_fixture x -- --token-fd 0
mkdir -p "$TMP/tx1"
run_capture "$TMP/tx1/manual-provider.json"
if [ -e "$TMP/tx1/manual-provider.json" ]; then
  echo "FAIL: a --token-fd manual provider was captured for blind relaunch" >&2
  exit 1
fi
stop_fixture
echo "ok: token-fd manual provider skipped from recovery capture"

# --- Case 2: secret env vars (ASCII and non-ASCII confusable) are not serialized ---
# Fullwidth 'B' (U+FF22 = EF BC A2) + EARER bypasses the ASCII secret filter.
NONASCII_KEY=$'\xef\xbc\xa2EARER'
start_fixture x \
  "MACPROVIDER_PROVIDER_TOKEN=ascii-bearer-secret" \
  "${NONASCII_KEY}=confusable-bearer-secret" \
  "SAFEVAR=keep-me" \
  --
mkdir -p "$TMP/tx2"
run_capture "$TMP/tx2/manual-provider.json"
[ -s "$TMP/tx2/manual-provider.json" ] || { echo "FAIL: expected a recovery snapshot" >&2; exit 1; }
python3 - "$TMP/tx2/manual-provider.json" <<'PY'
import base64
import json
import sys

with open(sys.argv[1], "r", encoding="utf-8") as handle:
    record = json.load(handle)
keys = [base64.b64decode(entry).split(b"=", 1)[0] for entry in record["environment_b64"]]
# The ASCII bearer must be dropped.
if any(key == b"MACPROVIDER_PROVIDER_TOKEN" for key in keys):
    raise SystemExit("FAIL: ASCII provider bearer was serialized")
# Every serialized key must be ASCII (non-ASCII confusables are dropped wholesale).
for key in keys:
    try:
        key.decode("ascii")
    except UnicodeDecodeError:
        raise SystemExit(f"FAIL: non-ASCII env key was serialized: {key!r}")
# A benign ASCII var is still preserved so capture is not vacuous.
if not any(key == b"SAFEVAR" for key in keys):
    raise SystemExit("FAIL: benign env var SAFEVAR was not preserved")
PY
stop_fixture
echo "ok: ASCII and non-ASCII confusable secrets dropped from recovery capture"

echo "manual recovery token-fd + env capture ok"
