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
source = source.replace(needle, 'LOCK_DIR="${CANARY_TEST_LOCK_DIR:?}"')
source = source.replace('sleep 2\n', 'sleep "${CANARY_TEST_RETRY_SLEEP:-2}"\n')
start = source.index("verify_job_process() {")
end = source.index("\n}\n\nstop_jobs()", start) + 3
fixture_identity = '''verify_job_process() {
  local expected_pid="$1"
  verify_launch_plist || return 1
  [ "$(job_pid)" = "$expected_pid" ] || return 1
  printf '%s\\n' "$((expected_pid * 1000000 + 7))"
}
'''
open(sys.argv[2], "w").write(source[:start] + fixture_identity + source[end:])
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
    else [ ! -f "$FAKE_STATE/watchdog-fail" ] || exit 1; touch "$FAKE_STATE/watchdog"; fi ;;
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
inflight=0; [ ! -f "$FAKE_STATE/inflight" ] || inflight=1
cat <<JSON
{"binary_version":"1.8.260","provider_id":"provider-test","model":"zai-org/glm-5.3-flash","model_loaded":true,"network_state":"$state","requests_in_flight":$inflight,"service_instance":{"pid":$pid},"capacity":{"max_concurrency":4},"continuous_batching":{"active":true,"policy":{"load_status":"live_verified","authorized":true,"policy_sha256":"policy-sha","release_id":"policy-release","tuple_sha256":"tuple-sha"},"self_check":{"served_slots":4},"scheduler":{"slots_total":4}},"coordinator":{"connected":true},"lifecycle":{"operator_paused":false}}
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
cat >"$T/bin/codesign" <<'SH'
#!/bin/bash
set -eu
case " $* " in
  *" --verify "*) [ ! -f "$FAKE_STATE/codesign-fail" ] ;;
  *)
    printf 'Identifier=live.malibu.provider.cli\nTeamIdentifier=TEAMTEST\nCDHash=cdhash-test\n' >&2
    ;;
esac
SH
chmod 755 "$T/bin/launchctl" "$T/bin/curl" "$T/bin/ssh" "$T/bin/sysctl" "$T/bin/codesign"

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
  python3 - "$LA/$FAKE_LABEL.plist" "$INSTALL/macprovider-cli" "$CONFIG" "$FAKE_LABEL" <<'PY'
import plistlib, sys
path, binary, config, label = sys.argv[1:]
with open(path, "wb") as handle:
    plistlib.dump({"Label": label, "ProgramArguments": [binary, "serve", "--config", config]}, handle)
PY
  touch "$LA/$FAKE_LABEL-watchdog.plist"
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
  CANARY_REMOTE_PATH_PREFIX="$T/bin" CANARY_LAUNCH_AGENTS_DIR="$LA" CANARY_TEST_LOCK_DIR="$FAKE_STATE/canary.lock" CANARY_TEST_RETRY_SLEEP=0 \
    bash "$REMOTE_TEST" "$mode" 1.8.260 "$INSTALL" "$FAKE_LABEL" "$SOCKET" 9999 1 2 2 0 1 "$result" \
      "$CONFIG" "$JOURNAL" "$HELPER" "$BINARY_SHA" \
      "$(printf provider-test | shasum -a 256 | awk '{print $1}')" zai-org/glm-5.3-flash \
      policy-sha policy-release tuple-sha TEAMTEST live.malibu.provider.cli cdhash-test
}

setup_case success
expect_rc 0 "remote removal reaches ready state with journal armed" run_remote remove-owner-pin
if ! grep -q '^max_concurrency_' "$CONFIG" && [ -f "$JOURNAL" ]; then ok "removal changes only the owned pin and retains recovery journal"; else bad "removal/journal postcondition"; fi
printf 'concurrent_foreign: preserved\n' >>"$CONFIG"
printf '# changed signed bytes after mutation\n' >>"$INSTALL/macprovider-cli"
expect_rc 6 "restore refuses to execute changed installed bytes" run_remote restore-owner-pin
if grep -q '^max_concurrency_override: 4$' "$CONFIG" && grep -q '^concurrent_foreign: preserved$' "$CONFIG" && [ -f "$JOURNAL" ] && [ ! -e "$FAKE_STATE/pid" ]; then ok "rollback restores only pin, preserves foreign edit, and leaves changed provider stopped"; else bad "scoped changed-binary rollback postcondition"; fi

setup_case validator
touch "$FAKE_STATE/context-fail"
expect_rc 5 "released-CLI validation failure automatically rolls back" run_remote remove-owner-pin
if grep -q '^max_concurrency_source: owner$' "$CONFIG" && [ ! -e "$JOURNAL" ]; then ok "validator failure leaves exact pin serving and journal closed"; else bad "validator rollback postcondition"; fi

setup_case readiness
printf '101\n' >"$FAKE_STATE/fail-after"
expect_rc 6 "failed readiness plus failed recovery remains journaled" run_remote remove-owner-pin
if grep -q '^max_concurrency_override: 4$' "$CONFIG" && [ -f "$JOURNAL" ]; then ok "failed recovery restores config first and retains journal"; else bad "failed recovery durability"; fi

setup_case wrongconfig
python3 - "$LA/$FAKE_LABEL.plist" "$INSTALL/macprovider-cli" "$CONFIG.other" "$FAKE_LABEL" <<'PY'
import plistlib, sys
path, binary, config, label = sys.argv[1:]
with open(path, "wb") as handle:
    plistlib.dump({"Label": label, "ProgramArguments": [binary, "serve", "--config", config]}, handle)
PY
expect_rc 4 "LaunchAgent pointing at another config is refused before journaling" run_remote remove-owner-pin
if [ ! -e "$JOURNAL" ] && grep -q '^max_concurrency_source: owner$' "$CONFIG"; then ok "wrong-config refusal leaves pin and journal untouched"; else bad "wrong-config refusal state"; fi

setup_case badsignature
touch "$FAKE_STATE/codesign-fail"
expect_rc 4 "strict code-signature failure is refused before journaling" run_remote remove-owner-pin
if [ ! -e "$JOURNAL" ] && grep -q '^max_concurrency_source: owner$' "$CONFIG"; then ok "signature refusal leaves pin and journal untouched"; else bad "signature refusal state"; fi

setup_case watchdog
rm -f "$FAKE_STATE/watchdog"; touch "$FAKE_STATE/watchdog-fail"
expect_rc 6 "watchdog bootstrap failure cannot commit owner-pin removal" run_remote remove-owner-pin
if [ -f "$JOURNAL" ] && grep -q '^max_concurrency_override: 4$' "$CONFIG"; then ok "watchdog failure retains recoverable restored-pin journal"; else bad "watchdog removal failure state"; fi
expect_rc 6 "watchdog failure also blocks explicit recovery finalization" run_remote restore-owner-pin
if [ -f "$JOURNAL" ] && grep -q '^max_concurrency_source: owner$' "$CONFIG"; then ok "watchdog recovery failure retains journal"; else bad "watchdog recovery failure state"; fi
rm -f "$FAKE_STATE/watchdog-fail"
expect_rc 0 "recovery finalizes after watchdog is verifiably loaded" run_remote restore-owner-pin
if [ ! -e "$JOURNAL" ] && ! compgen -G "$CONFIG.bak-owner-pin-*" >/dev/null; then ok "successful recovery removes journal and credential backup"; else bad "successful recovery secret cleanup"; fi

setup_case pausecrash
touch "$FAKE_STATE/inflight"
run_remote remove-owner-pin >"$T/pausecrash.out" 2>"$T/pausecrash.err" & PAUSE_RUN_PID=$!
for _ in $(seq 1 100); do [ -f "$JOURNAL" ] && [ -f "$FAKE_STATE/canary.lock/pid" ] && break; sleep .02; done
if [ -f "$JOURNAL" ]; then ok "journal is durable before pause/drain can be interrupted"; else bad "journal missing during pause/drain"; fi
REMOTE_PID="$(cat "$FAKE_STATE/canary.lock/pid" 2>/dev/null || true)"
case "$REMOTE_PID" in ''|*[!0-9]*) bad "pause/drain fixture exposed no remote pid" ;; *) kill -9 "$REMOTE_PID" 2>/dev/null || true ;; esac
wait "$PAUSE_RUN_PID" 2>/dev/null || true
rm -f "$FAKE_STATE/inflight"
expect_rc 0 "next recovery repairs a hard interruption during drain" run_remote restore-owner-pin
if [ ! -e "$JOURNAL" ] && grep -q '^max_concurrency_override: 4$' "$CONFIG" && [ -f "$FAKE_STATE/watchdog" ]; then ok "interrupted drain recovers pin, provider, and watchdog"; else bad "interrupted drain recovery state"; fi

# Controller recovery discovery is deliberately independent of status, GitHub,
# codesign, buyer credentials and the released binary.
setup_case controller
cat >"$JOURNAL" <<JSON
{"schema_version":"macprovider.studio_owner_pin.v1","phase":"applied","config_path":"$CONFIG","backup_path":"$CONFIG.bak-owner-pin-fixture","baseline_sha256":"x","baseline_unowned_sha256":"y","baseline_owned":{"max_concurrency_override":"4","max_concurrency_source":"owner"},"intended_owned":{"max_concurrency_override":null,"max_concurrency_source":null},"version":"1.8.260","provider_id_sha256":"p","model":"zai-org/glm-5.3-flash","policy_sha256":"s","policy_release_id":"r","policy_tuple_sha256":"t","binary_sha256":"b","team_id":"TEAMTEST","signing_identifier":"live.malibu.provider.cli","cdhash":"cdhash-test","executable_path":"$INSTALL/macprovider-cli"}
JSON
PATH="$T/bin:/usr/bin:/bin:/usr/sbin:/sbin" python3 "$ROOT/scripts/ops/lib/studio-owner-pin-probe.py" --journal-only --journal "$JOURNAL" --expected-config "$CONFIG" >"$T/journal-probe.json"
if [ "$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["journal"]["state"])' "$T/journal-probe.json")" = present ]; then ok "journal-only probe validates durable recovery metadata"; else bad "journal-only probe metadata"; fi
expect_rc 0 "controller exposes recovery before live/published prerequisites" env PATH="$T/bin:/usr/bin:/bin:/usr/sbin:/sbin" MACPROVIDER_OPS_ENV=/dev/null STUDIO_SSH=fake STUDIO_STATUS_PORT=9999 STUDIO_OWNER_PIN_INSTALL_DIR="$INSTALL" STUDIO_OWNER_PIN_CONFIG="$CONFIG" STUDIO_OWNER_PIN_JOURNAL="$JOURNAL" CANARY_RUNNER_STOP_CMD=none CANARY_RUNNER_START_CMD=none "$CONTROLLER" next
if grep -q '_apply restore' "$T/out"; then ok "controller next action is scoped restore"; else bad "controller recovery dispatch ($(tr '\n' ' ' <"$T/out"))"; fi

POLICY_FIXTURE="$T/reviewed-policy.json"
policy_check() {
  local mode="$1"
  python3 - "$POLICY_FIXTURE" "$mode" <<'PY'
import json, sys
path, mode = sys.argv[1:]
entries = [{"model_key": "zai-org/glm-5.3-flash", "max_served_slots": 4, "tuple_sha256": "tuple-reviewed"}]
if mode == "duplicate":
    entries.append(dict(entries[0]))
if mode == "wrong-ceiling":
    entries[0]["max_served_slots"] = 8
with open(path, "w") as target:
    json.dump({"release_id": "release-reviewed", "entries": entries}, target)
PY
  # shellcheck disable=SC2016 # Variables intentionally expand in the nested fixture shell.
  env MACPROVIDER_OPS_ENV=/dev/null CONTROLLER_UNIT="$CONTROLLER_UNIT" POLICY_FIXTURE="$POLICY_FIXTURE" MODE="$mode" \
    EXPECTED_POLICY_SHA="$(shasum -a 256 "$POLICY_FIXTURE" | awk '{print $1}')" bash -c '
    source "$CONTROLLER_UNIT"
    REVIEWED_POLICY="$POLICY_FIXTURE"
    if [ "$MODE" = valid ]; then
      load_reviewed_policy && [ "$POLICY_RELEASE" = release-reviewed ] && [ "$POLICY_TUPLE" = tuple-reviewed ] &&
        [ "$POLICY_SHA" = "$EXPECTED_POLICY_SHA" ]
    else
      ! load_reviewed_policy
    fi
  '
}
expect_rc 0 "controller derives exact reviewed four-slot policy metadata" policy_check valid
expect_rc 0 "controller refuses a duplicate reviewed GLM policy tuple" policy_check duplicate
expect_rc 0 "controller refuses a reviewed GLM policy ceiling other than four" policy_check wrong-ceiling

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

POST_JSON='{"installed":{"binary_version":"1.8.260","binary_sha256":"binary-sha","team_id":"TEAMTEST","identifier":"live.malibu.provider.cli","cdhash":"cdhash-test"},"launch":{"pid":101,"process_start_us":101000007,"executable_path":"/fixture/macprovider-cli"},"status":{"binary_version":"1.8.260","provider_id_sha256":"provider-sha","model":"zai-org/glm-5.3-flash","model_loaded":true,"network_state":"buyer_serving","service_instance.pid":101,"capacity.max_concurrency":4,"continuous_batching.active":true,"continuous_batching.policy.load_status":"live_verified","continuous_batching.policy.authorized":true,"continuous_batching.policy.policy_sha256":"policy-sha","continuous_batching.policy.release_id":"policy-release","continuous_batching.policy.tuple_sha256":"tuple-sha","continuous_batching.self_check.served_slots":4,"continuous_batching.scheduler.slots_total":4,"coordinator.connected":true,"lifecycle.operator_paused":false}}'
identity_check() {
  # shellcheck disable=SC2016 # Variables intentionally expand in the nested fixture shell.
  env MACPROVIDER_OPS_ENV=/dev/null CONTROLLER_UNIT="$CONTROLLER_UNIT" SNAPSHOT="$1" bash -c '
    source "$CONTROLLER_UNIT"
    VERSION=1.8.260; MODEL=zai-org/glm-5.3-flash; BINARY_SHA=binary-sha
    TEAM_ID=TEAMTEST; SIGNING_IDENTIFIER=live.malibu.provider.cli; CDHASH=cdhash-test
    EXECUTABLE_PATH=/fixture/macprovider-cli; PROVIDER_SHA=provider-sha
    POLICY_SHA=policy-sha; POLICY_RELEASE=policy-release; POLICY_TUPLE=tuple-sha
    PRE_PID=100; ACCEPTED_PID=101; ACCEPTED_START_US=101000007
    accepted_identity_ok "$SNAPSHOT"
  '
}
drift_recovery_check() {
  # shellcheck disable=SC2016 # Variables intentionally expand in the nested fixture shell.
  env MACPROVIDER_OPS_ENV=/dev/null CONTROLLER_UNIT="$CONTROLLER_UNIT" SNAPSHOT="$1" JOURNAL_FILE="$T/final-proof-journal" COMPLETION_FILE="$T/final-proof-completion" bash -c '
    source "$CONTROLLER_UNIT"
    printf "armed\n" >"$JOURNAL_FILE"
    VERSION=1.8.260; MODEL=zai-org/glm-5.3-flash; BINARY_SHA=binary-sha
    TEAM_ID=TEAMTEST; SIGNING_IDENTIFIER=live.malibu.provider.cli; CDHASH=cdhash-test
    EXECUTABLE_PATH=/fixture/macprovider-cli; PROVIDER_SHA=provider-sha
    POLICY_SHA=policy-sha; POLICY_RELEASE=policy-release; POLICY_TUPLE=tuple-sha
    PRE_PID=100; ACCEPTED_PID=101; ACCEPTED_START_US=101000007; TX_ARMED=1
    commit_completion() { printf "unexpected\n" >"$COMPLETION_FILE"; TX_ARMED=0; }
    run_remote() { [ "$1" = restore-owner-pin ] || return 1; mv "$JOURNAL_FILE" "$JOURNAL_FILE.restored"; }
    if finalize_after_proof "$SNAPSHOT" proof; then exit 1; fi
    recover_if_armed
    [ "$TX_ARMED" = 0 ] && [ -f "$JOURNAL_FILE.restored" ] && [ ! -e "$COMPLETION_FILE" ]
  '
}
expect_rc 0 "controller accepts only the exact remote-accepted final identity" identity_check "$POST_JSON"
for drift in pid start provider binary; do
  changed="$(printf '%s' "$POST_JSON" | python3 -c '
import json,sys
d=json.load(sys.stdin); k=sys.argv[1]
if k=="pid": d["status"]["service_instance.pid"]=102; d["launch"]["pid"]=102
elif k=="start": d["launch"]["process_start_us"]+=1
elif k=="provider": d["status"]["provider_id_sha256"]="other"
else: d["installed"]["binary_sha256"]="other"
print(json.dumps(d,separators=(",",":")))' "$drift")"
  expect_rc 1 "controller refuses post-proof $drift identity drift" identity_check "$changed"
  expect_rc 0 "controller restores instead of finalizing after post-proof $drift drift" drift_recovery_check "$changed"
done

MARKER_ROOT="$T/marker-state"; mkdir -p "$MARKER_ROOT/studio-owner-pin"
printf '{}\n' >"$MARKER_ROOT/studio-owner-pin/complete.json"
ln "$MARKER_ROOT/studio-owner-pin/complete.json" "$MARKER_ROOT/studio-owner-pin/complete.link"
# shellcheck disable=SC2016 # Variables intentionally expand in the nested fixture shell.
expect_rc 1 "completion durability refuses an unsafe hard-linked marker" env MACPROVIDER_OPS_ENV=/dev/null MACPROVIDER_OPS_STATE_DIR="$MARKER_ROOT" CONTROLLER_UNIT="$CONTROLLER_UNIT" bash -c 'source "$CONTROLLER_UNIT"; durable_completion_marker'
completion_case() {
  # shellcheck disable=SC2016 # Variables intentionally expand in the nested fixture shell.
  env MACPROVIDER_OPS_ENV=/dev/null CONTROLLER_UNIT="$CONTROLLER_UNIT" CASE_MODE="$1" ORDER_FILE="$T/completion-order" JOURNAL_FILE="$T/mock-remote-journal" bash -c '
    source "$CONTROLLER_UNIT"
    : >"$ORDER_FILE"; printf "armed\n" >"$JOURNAL_FILE"; TX_ARMED=1; RUNNER_TOUCHED=1; VERSION=1.8.260; REMOTE_STAGE=/fixture/stage
    STUDIO_OWNER_PIN_CONFIG=/fixture/config; STUDIO_OWNER_PIN_JOURNAL=/fixture/journal
    mark_done() { printf "marker\n" >>"$ORDER_FILE"; [ "$CASE_MODE" != marker-fail ]; }
    durable_completion_marker() { printf "fsync\n" >>"$ORDER_FILE"; [ "$CASE_MODE" != fsync-fail ]; }
    restore_runner() { printf "runner\n" >>"$ORDER_FILE"; [ "$CASE_MODE" != runner-fail ] || return 1; RUNNER_TOUCHED=0; }
    studio_ssh() { printf "finish\n" >>"$ORDER_FILE"; mv "$JOURNAL_FILE" "$JOURNAL_FILE.finished"; }
    if commit_completion "{}"; then rc=0; else rc=$?; fi
    case "$CASE_MODE" in
      marker-fail) [ "$rc" = 1 ] && [ "$TX_ARMED" = 1 ] && [ -f "$JOURNAL_FILE" ] && [ "$(tr "\n" "," <"$ORDER_FILE")" = "marker," ] ;;
      fsync-fail) [ "$rc" = 1 ] && [ "$TX_ARMED" = 1 ] && [ -f "$JOURNAL_FILE" ] && [ "$(tr "\n" "," <"$ORDER_FILE")" = "marker,fsync," ] ;;
      runner-fail) [ "$rc" = 1 ] && [ "$TX_ARMED" = 1 ] && [ "$RUNNER_TOUCHED" = 1 ] && [ -f "$JOURNAL_FILE" ] && [ "$(tr "\n" "," <"$ORDER_FILE")" = "marker,fsync,runner," ] ;;
      success) [ "$rc" = 0 ] && [ "$TX_ARMED" = 0 ] && [ "$RUNNER_TOUCHED" = 0 ] && [ -f "$JOURNAL_FILE.finished" ] && [ "$(tr "\n" "," <"$ORDER_FILE")" = "marker,fsync,runner,finish," ] ;;
    esac
  '
}
expect_rc 0 "marker write failure leaves remote journal armed and unfinalized" completion_case marker-fail
expect_rc 0 "marker fsync failure leaves remote journal armed and unfinalized" completion_case fsync-fail
expect_rc 0 "runner restart failure leaves remote journal armed and unfinalized" completion_case runner-fail
expect_rc 0 "successful completion restores runner before journal finish" completion_case success
expect_rc 0 "completion is durably recorded before remote journal finalization" python3 - "$CONTROLLER" <<'PY'
import sys
source=open(sys.argv[1]).read()
a=source.index('mark_done "$OPS_SCOPE" complete', source.index('commit_completion()'))
b=source.index('durable_completion_marker', a)
c=source.index('restore_runner', b)
d=source.index(' finish --config ', c)
e=source.index('TX_ARMED=0', d)
raise SystemExit(0 if a < b < c < d < e else 1)
PY

printf '1..%s\n' "$((pass + fail))"
[ "$fail" -eq 0 ]
