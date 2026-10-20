#!/usr/bin/env bash
# Focused offline tests for the Studio owner-pin lifecycle/controller. No SSH,
# provider, hardware, buyer request, or live config is touched.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
REMOTE="$ROOT/scripts/ops/lib/canary-swap-remote.sh"
HELPER="$ROOT/scripts/ops/lib/studio-owner-pin-config.py"
CONTROLLER="$ROOT/scripts/ops/studio-owner-pin.sh"
TEST_PARENT="${XDG_CACHE_HOME:-$HOME/.cache}/macprovider-tests"
mkdir -p "$TEST_PARENT"
T="$(mktemp -d "$TEST_PARENT/studio-owner-pin.XXXXXX")"
T="$(cd "$T" && pwd -P)"
trap 'kill "${SOCKET_PID:-}" 2>/dev/null || true; wait "${SOCKET_PID:-}" 2>/dev/null || true; rm -f /tmp/mp-pin-"$$"-*.sock; rm -rf "$T"' EXIT

# Keep production's global per-user lock contract unchanged while confining
# this test copy's lock to the exact fixture directory.
REMOTE_TEST="$T/canary-swap-remote.sh"
python3 - "$REMOTE" "$REMOTE_TEST" <<'PY'
import sys
source = open(sys.argv[1]).read()
needle = 'LOCK_DIR="$HOME/.macprovider-canary-swap.lock"'
assert source.count(needle) == 1
open(sys.argv[2], "w").write(source.replace(needle, 'LOCK_DIR="${CANARY_TEST_LOCK_DIR:?}"'))
PY
CONTROLLER_UNIT="$T/studio-owner-pin-unit.sh"
python3 - "$CONTROLLER" "$CONTROLLER_UNIT" "$ROOT/scripts/ops" <<'PY'
import sys
source = open(sys.argv[1]).read()
source = source.replace(
    'OPS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"',
    'OPS_DIR=' + repr(sys.argv[3]),
    1,
)
assert source.endswith('ops_main "$@"\n')
open(sys.argv[2], "w").write(source[:-len('ops_main "$@"\n')] + ': # sourced by focused test\n')
PY

pass=0
fail=0
ok() { printf 'ok - %s\n' "$1"; pass=$((pass + 1)); }
bad() { printf 'not ok - %s\n' "$1"; fail=$((fail + 1)); }
expect_rc() {
  local want="$1" name="$2"; shift 2
  local got=0
  "$@" >"$T/out" 2>"$T/err" || got=$?
  if [ "$got" = "$want" ]; then ok "$name"; else bad "$name (rc=$got, want=$want; $(tr '\n' ' ' <"$T/err"))"; fi
}

mkdir -p "$T/bin"
cat >"$T/bin/launchctl" <<'SH'
#!/bin/bash
set -eu
cmd="$1"; shift
case "$cmd" in
  print)
    name="${1##*/}"
    if [ "$name" = "$FAKE_LABEL" ] && [ -f "$FAKE_STATE/pid" ]; then printf 'pid = %s\n' "$(cat "$FAKE_STATE/pid")"; exit 0; fi
    [ "$name" = "$FAKE_LABEL-watchdog" ] && [ -f "$FAKE_STATE/watchdog" ] && exit 0
    exit 1 ;;
  bootout)
    name="${1##*/}"; [ "$name" != "$FAKE_LABEL" ] || rm -f "$FAKE_STATE/pid"
    [ "$name" != "$FAKE_LABEL-watchdog" ] || rm -f "$FAKE_STATE/watchdog" ;;
  bootstrap)
    name="$(basename "$2" .plist)"
    if [ "$name" = "$FAKE_LABEL" ]; then
      n=$(cat "$FAKE_STATE/next-pid"); printf '%s\n' "$n" >"$FAKE_STATE/pid"; printf '%s\n' "$((n + 1))" >"$FAKE_STATE/next-pid"
    else touch "$FAKE_STATE/watchdog"; fi ;;
  *) exit 1 ;;
esac
SH
cat >"$T/bin/curl" <<'SH'
#!/bin/bash
set -eu
pid="$(cat "$FAKE_STATE/pid" 2>/dev/null || true)"
[ -n "$pid" ] || exit 22
state=buyer_serving
if [ -f "$FAKE_STATE/fail-after" ] && [ "$pid" -ge "$(cat "$FAKE_STATE/fail-after")" ]; then state=ready; fi
cat <<JSON
{"binary_version":"1.8.260","provider_id":"provider-test","model":"zai-org/glm-5.3-flash","model_loaded":true,"network_state":"$state","requests_in_flight":0,"capacity":{"max_concurrency":4},"continuous_batching":{"active":true,"policy":{"load_status":"live_verified","authorized":true,"policy_sha256":"policy-sha","release_id":"policy-release","tuple_sha256":"tuple-sha"},"self_check":{"served_slots":4},"scheduler":{"slots_total":4}},"coordinator":{"connected":true},"lifecycle":{"operator_paused":false}}
JSON
SH
cat >"$T/bin/ssh" <<'SH'
#!/bin/bash
set -eu
cmd="${!#}"
bash -c "$cmd"
SH
cat >"$T/bin/sysctl" <<'SH'
#!/bin/bash
printf 'Mac15,14\n'
SH
chmod 755 "$T/bin/launchctl" "$T/bin/curl" "$T/bin/ssh" "$T/bin/sysctl"

socket_server() {
  python3 - "$1" <<'PY' &
import json, os, socket, sys
p=sys.argv[1]
try: os.unlink(p)
except FileNotFoundError: pass
s=socket.socket(socket.AF_UNIX); s.bind(p); s.listen()
while True:
    c,_=s.accept(); c.recv(4096); c.sendall((json.dumps({"accepted": True})+"\n").encode()); c.close()
PY
  SOCKET_PID=$!
  for _ in $(seq 1 50); do [ -S "$1" ] && return; sleep .02; done
  return 1
}

setup_case() {
  CASE="$T/$1"; export FAKE_STATE="$CASE/state" FAKE_LABEL=live.test.provider
  INSTALL="$CASE/home/macprovider"; CONFIG="$CASE/home/.config/macprovider/config.yaml"; JOURNAL="$CASE/home/.config/macprovider/owner-pin.json"
  LA="$CASE/home/Library/LaunchAgents"; SOCKET="/tmp/mp-pin-$$-$1.sock"
  mkdir -p "$INSTALL" "$(dirname "$CONFIG")" "$LA" "$FAKE_STATE"
  printf '100\n' >"$FAKE_STATE/pid"; printf '101\n' >"$FAKE_STATE/next-pid"; touch "$FAKE_STATE/watchdog"
  touch "$LA/$FAKE_LABEL.plist" "$LA/$FAKE_LABEL-watchdog.plist"
  cat >"$INSTALL/macprovider-cli" <<'SH'
#!/bin/bash
if [ "${1:-}" = --version ]; then echo 1.8.260; exit; fi
[ ! -f "$FAKE_STATE/context-fail" ]
SH
  chmod 755 "$INSTALL/macprovider-cli"
  printf 'provider_token: secret-never-printed\nforeign: keep\nmax_concurrency_override: 4\nmax_concurrency_source: owner\n' >"$CONFIG"
  BINARY_SHA="$(shasum -a 256 "$INSTALL/macprovider-cli" | awk '{print $1}')"
  if [ -n "${SOCKET_PID:-}" ]; then kill "$SOCKET_PID" 2>/dev/null || true; wait "$SOCKET_PID" 2>/dev/null || true; fi
  socket_server "$SOCKET"
}

run_remote() {
  local mode="$1" result="$CASE/result"
  rm -f "$result"
  CANARY_REMOTE_PATH_PREFIX="$T/bin" CANARY_LAUNCH_AGENTS_DIR="$LA" CANARY_TEST_LOCK_DIR="$FAKE_STATE/canary.lock" \
    bash "$REMOTE_TEST" "$mode" 1.8.260 "$INSTALL" "$FAKE_LABEL" "$SOCKET" 9999 1 2 2 0 1 "$result" \
      "$CONFIG" "$JOURNAL" "$HELPER" "$BINARY_SHA" \
      "$(printf provider-test | shasum -a 256 | awk '{print $1}')" zai-org/glm-5.3-flash \
      policy-sha policy-release tuple-sha
}

setup_case success
expect_rc 0 "remote removal reaches ready state with journal armed" run_remote remove-owner-pin
if ! grep -q '^max_concurrency_' "$CONFIG" && [ -f "$JOURNAL" ]; then ok "removal changes only the owned pin and retains recovery journal"; else bad "removal/journal postcondition"; fi
printf 'concurrent_foreign: preserved\n' >>"$CONFIG"
printf '# changed signed bytes after mutation\n' >>"$INSTALL/macprovider-cli"
expect_rc 0 "restore prioritizes config even when installed bytes changed" run_remote restore-owner-pin
if grep -q '^max_concurrency_override: 4$' "$CONFIG" && grep -q '^concurrent_foreign: preserved$' "$CONFIG" && [ ! -e "$JOURNAL" ]; then ok "rollback restores only pin and preserves foreign edit"; else bad "scoped rollback postcondition"; fi

setup_case validator
touch "$FAKE_STATE/context-fail"
expect_rc 5 "released-CLI validation failure automatically rolls back" run_remote remove-owner-pin
if grep -q '^max_concurrency_source: owner$' "$CONFIG" && [ ! -e "$JOURNAL" ]; then ok "validator failure leaves exact pin serving and journal closed"; else bad "validator rollback postcondition"; fi

setup_case readiness
printf '101\n' >"$FAKE_STATE/fail-after"
expect_rc 6 "failed readiness plus failed recovery remains journaled" run_remote remove-owner-pin
if grep -q '^max_concurrency_override: 4$' "$CONFIG" && [ -f "$JOURNAL" ]; then ok "failed recovery restores config first and retains journal"; else bad "failed recovery durability"; fi

# Controller recovery discovery is deliberately independent of status, GitHub,
# codesign, buyer credentials and the released binary.
setup_case controller
cat >"$JOURNAL" <<JSON
{"schema_version":"macprovider.studio_owner_pin.v1","phase":"applied","config_path":"$CONFIG","backup_path":"$CONFIG.bak","baseline_sha256":"x","baseline_unowned_sha256":"y","baseline_owned":{"max_concurrency_override":"4","max_concurrency_source":"owner"},"intended_owned":{"max_concurrency_override":null,"max_concurrency_source":null},"version":"1.8.260","provider_id_sha256":"p","model":"zai-org/glm-5.3-flash","policy_sha256":"s","policy_release_id":"r","policy_tuple_sha256":"t"}
JSON
PATH="$T/bin:/usr/bin:/bin:/usr/sbin:/sbin" python3 "$ROOT/scripts/ops/lib/studio-owner-pin-probe.py" --journal-only --journal "$JOURNAL" --expected-config "$CONFIG" >"$T/journal-probe.json"
if [ "$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["journal"]["state"])' "$T/journal-probe.json")" = present ]; then ok "journal-only probe validates durable recovery metadata"; else bad "journal-only probe metadata"; fi
expect_rc 0 "controller exposes recovery before live/published prerequisites" env PATH="$T/bin:/usr/bin:/bin:/usr/sbin:/sbin" MACPROVIDER_OPS_ENV=/dev/null STUDIO_SSH=fake STUDIO_STATUS_PORT=9999 STUDIO_OWNER_PIN_INSTALL_DIR="$INSTALL" STUDIO_OWNER_PIN_CONFIG="$CONFIG" STUDIO_OWNER_PIN_JOURNAL="$JOURNAL" CANARY_RUNNER_STOP_CMD=none CANARY_RUNNER_START_CMD=none "$CONTROLLER" next
if grep -q '_apply restore' "$T/out"; then ok "controller next action is scoped restore"; else bad "controller recovery dispatch ($(tr '\n' ' ' <"$T/out"))"; fi

mkdir -p "$T/quiesce/run-fixture"
sleep 30 & VICTIM_PID=$!
printf '%s\n' "$VICTIM_PID" >"$T/quiesce/run-fixture/remote.pid"
# shellcheck disable=SC2016 # Variables are intentionally expanded by the nested test shell.
expect_rc 1 "quiesce refuses a reused/unrelated PID identity" env MACPROVIDER_OPS_ENV=/dev/null CONTROLLER_UNIT="$CONTROLLER_UNIT" STAGE="$T/quiesce/run-fixture" bash -c '
  source "$CONTROLLER_UNIT"
  REMOTE_ACTIVE=1; REMOTE_STAGE="$STAGE"; READY_TIMEOUT_S=1; POLL_S=1
  studio_ssh() { bash -c "$*"; }
  quiesce_remote
'
if kill -0 "$VICTIM_PID" 2>/dev/null; then ok "PID identity refusal does not signal unrelated process"; else bad "unrelated process was signaled"; fi
kill "$VICTIM_PID" 2>/dev/null || true
wait "$VICTIM_PID" 2>/dev/null || true

printf '1..%s\n' "$((pass + fail))"
[ "$fail" -eq 0 ]
