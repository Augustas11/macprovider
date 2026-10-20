#!/usr/bin/env bash
# Offline controller and manifest regressions for studio-lab-window.sh.
# shellcheck disable=SC2030,SC2031,SC2034,SC2329
set -euo pipefail

OPS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REAL_LOCK_SOURCE="$OPS_DIR/live-lock.sh"
TMP_ROOT="$(mktemp -d -t studio-lab-window-controller.XXXXXX)"
TMP_ROOT="$(cd "$TMP_ROOT" && pwd -P)"
trap 'rm -rf "$TMP_ROOT"' EXIT

fail() { printf 'not ok - %s\n' "$*" >&2; exit 1; }
pass() { printf 'ok - %s\n' "$*"; }

make_harness() {
  local root="$1"
  mkdir -p "$root/scripts/ops/lib" "$root/scripts/lab/2080-native-rows" "$root/state"
  sed '$d' "$OPS_DIR/studio-lab-window.sh" > "$root/scripts/ops/studio-lab-window.sh"
  cp "$OPS_DIR/lib/common.sh" "$root/scripts/ops/lib/common.sh"
  cp "$OPS_DIR/lib/runbook-commands.sh" "$root/scripts/ops/lib/runbook-commands.sh"
  cp "$OPS_DIR/lib/published-provider-identity.sh" "$root/scripts/ops/lib/published-provider-identity.sh"
  cp "$OPS_DIR/lib/studio-lab-window-remote.py" "$root/scripts/ops/lib/studio-lab-window-remote.py"
  cp "$OPS_DIR/lib/studio-lab-window-manifest.py" "$root/scripts/ops/lib/studio-lab-window-manifest.py"
  cp "$OPS_DIR/lib/studio-owner-pin-probe.py" "$root/scripts/ops/lib/studio-owner-pin-probe.py"
  printf '#!/bin/sh\nexit 0\n' > "$root/scripts/lab/2080-native-rows/run-window-diagnostic.sh"
  chmod 700 "$root/scripts/lab/2080-native-rows/run-window-diagnostic.sh"
  cat > "$root/scripts/ops/live-lock.sh" <<'SH'
#!/bin/sh
printf '%s\n' "$*" >> "$TEST_EVENTS"
SH
  chmod 700 "$root/scripts/ops/live-lock.sh"
}

HARNESS="$TMP_ROOT/harness"
make_harness "$HARNESS"
export TEST_EVENTS="$TMP_ROOT/events"
export MACPROVIDER_OPS_ENV="$TMP_ROOT/no-env"
export MACPROVIDER_OPS_STATE_DIR="$HARNESS/state"
export MACPROVIDER_OPS_OWNER=test-owner
export STUDIO_SSH=test-studio
export STUDIO_LAB_WINDOW_DIR=/private/lab-window
export STUDIO_LAB_GIT_HEAD=aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa

# shellcheck source=/dev/null
. "$HARNESS/scripts/ops/studio-lab-window.sh"
trap 'cleanup_ops; rm -rf "$TMP_ROOT"' EXIT

set +e
(
  start_window() { fail "unguarded internal dispatch reached mutation"; }
  unset MACPROVIDER_OPS_ENTRYPOINT
  internal _apply run
) >/dev/null 2>&1
rc=$?
set -e
[ "$rc" -eq 3 ] || fail "direct internal action was not refused"
pass "internal actions require the guarded common entrypoint"

remote_state() { printf '%s\n' '{"phase":"stopped","revision":4,"nonce":"n","action":"recover"}'; }
require_fresh_settings() { fail "fresh preflight ran before journal recovery"; }
reset_state
gather
[ "$NEXT_ID:$NEXT_KIND" = recovery:mutate ] || fail "journal recovery was not prioritized"
pass "journal recovery precedes fresh source and release preflight"

remote_state() { printf '%s\n' '{"state":"partial"}'; }
reset_state
gather
[ "$NEXT_ID:$NEXT_KIND" = staging:mutate ] || fail "pre-dispatch staging did not select guarded abort"
[[ "$NEXT_CMD" == *'_apply abort-stage' ]] || fail "pre-dispatch cleanup was not routed through the guarded controller"
pass "abandoned pre-dispatch staging has a bounded guarded cleanup"

: > "$TEST_EVENTS"
mkdir -p "$(dirname "$(active_marker_path)")"
printf '{}\n' > "$(active_marker_path)"
OPS_LOCK_OWNER=test-owner
release_live_lock
[ ! -s "$TEST_EVENTS" ] || fail "active detached window released its live lock"
[ -z "$OPS_LOCK_OWNER" ] || fail "retained lock owner was not cleared from EXIT cleanup"
rm -f "$(active_marker_path)"
OPS_LOCK_OWNER=test-owner
release_live_lock
grep -qx 'release test-owner' "$TEST_EVENTS" || fail "ordinary cleanup did not release its lock"
pass "durable active marker retains the non-PID live lock"

# common.sh must not rewrite an existing detached-window lock as PID-bound
# before its second gather or when the recovery child fails.
: > "$TEST_EVENTS"
printf '{}\n' > "$(active_marker_path)"
set +e
(
  trap - EXIT INT TERM HUP
  require_clean_origin_main() { :; }
  gather() { set_next recovery mutate "fixture recovery" "false"; }
  NEXT_ID=recovery
  NEXT_KIND=mutate
  NEXT_TITLE="fixture recovery"
  NEXT_CMD=false
  run_next
)
rc=$?
set -e
[ "$rc" -eq 1 ] || fail "fixture recovery did not exercise a failing child"
grep -qx 'acquire test-owner --purpose studio-lab-window:recovery' "$TEST_EVENTS" || fail "recovery lock was not durable before second gather"
! grep -q -- '--bind-pid' "$TEST_EVENTS" || fail "recovery rewrote the durable lock as PID-bound"
rm -f "$(active_marker_path)"
pass "recovery preserves the durable lock before second gather and child failure"

mkdir -p "$TMP_ROOT/real-lock"
cp "$REAL_LOCK_SOURCE" "$TMP_ROOT/real-lock/live-lock.sh"
printf '{}\n' > "$(active_marker_path)"
set +e
(
  trap - EXIT INT TERM HUP
  OPS_DIR="$TMP_ROOT/real-lock"
  export MACPROVIDER_LIVE_LOCK="$TMP_ROOT/real-lock/reservation.json"
  "$OPS_DIR/live-lock.sh" acquire test-owner --purpose detached-window >/dev/null 2>&1
  require_clean_origin_main() { :; }
  gather() { set_next recovery mutate "fixture recovery" "false"; }
  NEXT_ID=recovery
  NEXT_KIND=mutate
  NEXT_TITLE="fixture recovery"
  NEXT_CMD=false
  run_next
) >/dev/null 2>&1
rc=$?
set -e
[ "$rc" -eq 1 ] || fail "real-lock recovery did not exercise controller failure"
python3 - "$TMP_ROOT/real-lock/reservation.json" <<'PY'
import json, sys
record = json.load(open(sys.argv[1]))
assert record["owner"] == "test-owner" and record["pid_bound"] is False
PY
if MACPROVIDER_LIVE_LOCK="$TMP_ROOT/real-lock/reservation.json" \
  "$TMP_ROOT/real-lock/live-lock.sh" acquire different-owner >/dev/null 2>&1; then
  fail "another owner took the durable lock after the recovery controller exited"
fi
MACPROVIDER_LIVE_LOCK="$TMP_ROOT/real-lock/reservation.json" \
  "$TMP_ROOT/real-lock/live-lock.sh" release test-owner >/dev/null 2>&1
rm -f "$(active_marker_path)"
pass "real lock remains unavailable to another owner after recovery controller failure"

remote_state() { printf '%s\n' '{"state":"absent"}'; }
require_fresh_settings() { :; }
completion_mark() { printf complete-test; }
mkdir -p "$(dirname "$(marker_path "$OPS_SCOPE" complete-test)")"
mark_done "$OPS_SCOPE" complete-test "done" '{"lab_exit_code":0}'
reset_state
gather
[ "$NEXT_ID:$NEXT_KIND" = done:done ] || fail "successful per-head completion was not terminal"
pass "matching successful completion is terminal only without a journal"
completion_mark() { printf 'complete-%s' "$STUDIO_LAB_GIT_HEAD"; }

# Completion is committed locally before remote finish; a finish refusal keeps
# the active ownership marker and remote journal recoverable.
STUDIO_LAB_GIT_HEAD=bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb
window_paths
: > "$TEST_EVENTS"
finish_nonce=ffffffffffffffffffffffffffffffff
manifest_sha="$(printf 'd%.0s' {1..64})"
write_active_marker dispatched "$finish_nonce" "" "$manifest_sha"
studio_ssh() { printf 'finish\n' >> "$TEST_EVENTS"; return 1; }
cleanup_remote_stage() { printf 'cleanup\n' >> "$TEST_EVENTS"; }
state="{\"phase\":\"restored\",\"revision\":9,\"nonce\":\"$finish_nonce\",\"action\":\"finish\",\"lab_exit_code\":0,\"restored_process\":{\"pid\":99,\"process_start_us\":123456,\"executable_path\":\"/private/install/macprovider-cli\"}}"
set +e
record_outcome "$state"
rc=$?
set -e
[ "$rc" -eq 6 ] || fail "remote finish refusal did not return recovery status"
[ -f "$(active_marker_path)" ] || fail "finish refusal cleared active ownership"
[ "$(json_field "$(active_marker_path)" 'd.get("phase")')" = outcome_recorded ] || fail "local outcome was not durable before finish"
[ -f "$(marker_path "$OPS_SCOPE" "$(completion_mark)")" ] || fail "completion marker was not durable before finish"
grep -qx finish "$TEST_EVENTS" || fail "remote finish was not attempted"
! grep -q cleanup "$TEST_EVENTS" || fail "finish refusal cleaned protected staging"
pass "finish refusal preserves journal ownership after durable local outcome"

: > "$TEST_EVENTS"
remote_state() { printf '%s\n' '{"state":"absent"}'; }
reconcile_window
[ ! -f "$(active_marker_path)" ] || fail "terminal absent-stage reconciliation retained active ownership"
grep -qx cleanup "$TEST_EVENTS" || fail "terminal reconciliation did not run scoped cleanup"
grep -qx 'release test-owner' "$TEST_EVENTS" || fail "terminal reconciliation did not release the durable lock"
pass "terminal reconciliation is idempotent after journal and stage cleanup"

: > "$TEST_EVENTS"
write_active_marker outcome_recorded "$finish_nonce" "$(completion_mark)" "$manifest_sha"
remote_state() { printf '{"state":"idle","nonce":"%s","manifest_sha256":"%s"}\n' "eeeeeeeeeeeeeeeeeeeeeeeeeeeeeeee" "$manifest_sha"; }
reset_state
gather
[ "$NEXT_ID:$NEXT_KIND" = recovery:blocked ] || fail "unrelated idle manifest was accepted for terminal cleanup"
[ -f "$(active_marker_path)" ] || fail "unrelated idle manifest cleared active ownership"
[ ! -s "$TEST_EVENTS" ] || fail "unrelated idle manifest mutated lock or staging"
rm -f "$(active_marker_path)"
pass "terminal idle cleanup requires the exact manifest identity"

: > "$TEST_EVENTS"
wrong_nonce=eeeeeeeeeeeeeeeeeeeeeeeeeeeeeeee
write_active_marker outcome_recorded "$wrong_nonce" "$(completion_mark)" "$manifest_sha"
remote_state() { printf '%s\n' '{"state":"absent"}'; }
reset_state
gather
[ "$NEXT_ID:$NEXT_KIND" = recovery:blocked ] || fail "mismatched terminal outcome was accepted"
[ -f "$(active_marker_path)" ] || fail "mismatched terminal outcome cleared active ownership"
[ ! -s "$TEST_EVENTS" ] || fail "mismatched terminal outcome mutated lock or staging"
rm -f "$(active_marker_path)"
pass "malformed or mismatched terminal outcome remains locked"

prepared_nonce=11111111111111111111111111111111
prepared_sha="$(printf '2%.0s' {1..64})"
write_active_marker dispatching "$prepared_nonce" "" "$prepared_sha"
remote_state() { printf '{"state":"idle","nonce":"%s","manifest_sha256":"%s"}\n' "$prepared_nonce" "$prepared_sha"; }
: > "$TEST_EVENTS"
studio_ssh() {
  case "$*" in
    *' abort --manifest '*)
      printf 'abort\n' >> "$TEST_EVENTS"
      printf '{"state":"aborted","nonce":"%s","manifest_sha256":"%s"}\n' "$prepared_nonce" "$prepared_sha"
      ;;
    *' finish-abort --manifest '*)
      printf 'finish:%s\n' "$(json_field "$(active_marker_path)" 'd.get("phase")')" >> "$TEST_EVENTS"
      printf '{"state":"abort-finished","nonce":"%s"}\n' "$prepared_nonce"
      ;;
    *) fail "unexpected Studio fixture command: $*" ;;
  esac
}
cleanup_remote_stage() { printf 'cleanup\n' >> "$TEST_EVENTS"; }
abort_prepared_window
[ ! -f "$(active_marker_path)" ] || fail "authenticated prepared abort retained active ownership"
grep -qx abort "$TEST_EVENTS" || fail "prepared abort did not use the journal-serialized remote command"
grep -qx 'finish:abort_confirmed' "$TEST_EVENTS" || fail "abort receipt was removed before local confirmation"
grep -qx cleanup "$TEST_EVENTS" || fail "prepared abort did not remove exact staged files"
grep -qx 'release test-owner' "$TEST_EVENTS" || fail "prepared abort did not release the durable lock"
python3 - "$TEST_EVENTS" <<'PY'
import sys
lines = open(sys.argv[1]).read().splitlines()
assert lines.index("abort") < lines.index("finish:abort_confirmed") < lines.index("cleanup") < lines.index("release test-owner"), lines
PY
pass "authenticated no-journal intent aborts under the remote journal lock"

write_active_marker aborting_prepared "$prepared_nonce" "" "$prepared_sha"
remote_state() { printf '{"state":"aborted","nonce":"%s","manifest_sha256":"%s"}\n' "$prepared_nonce" "$prepared_sha"; }
: > "$TEST_EVENTS"
abort_prepared_window
[ ! -f "$(active_marker_path)" ] || fail "receipt-before-local-confirmation recovery retained active ownership"
! grep -qx abort "$TEST_EVENTS" || fail "receipt recovery tried to repeat initial manifest abort"
grep -qx 'finish:abort_confirmed' "$TEST_EVENTS" || fail "receipt recovery did not durably confirm before finish"
grep -qx cleanup "$TEST_EVENTS" || fail "receipt recovery did not clean staged files"
pass "authenticated remote receipt resumes before local abort confirmation"

write_active_marker abort_confirmed "$prepared_nonce" "" "$prepared_sha"
remote_state() { printf '%s\n' '{"state":"absent"}'; }
: > "$TEST_EVENTS"
abort_prepared_window
[ ! -f "$(active_marker_path)" ] || fail "finished-receipt recovery retained active ownership"
! grep -q '^finish:' "$TEST_EVENTS" || fail "already-finished receipt was finished again"
grep -qx cleanup "$TEST_EVENTS" || fail "finished-receipt recovery did not clean staged files"
grep -qx 'release test-owner' "$TEST_EVENTS" || fail "finished-receipt recovery did not release the lock"
pass "local abort confirmation resumes after remote receipt removal"

write_active_marker prepared "$prepared_nonce" "" "$prepared_sha"
remote_state() { printf '{"state":"idle","nonce":"%s","manifest_sha256":"%s"}\n' "33333333333333333333333333333333" "$prepared_sha"; }
: > "$TEST_EVENTS"
reset_state
gather
[ "$NEXT_ID:$NEXT_KIND" = recovery:blocked ] || fail "mismatched prepared manifest was accepted"
[ ! -s "$TEST_EVENTS" ] || fail "mismatched prepared manifest attempted cleanup"
rm -f "$(active_marker_path)"
pass "prepared cleanup refuses a mismatched manifest identity"

write_active_marker aborting_prepared "$prepared_nonce" "" "$prepared_sha"
remote_state() { printf '{"state":"aborted","nonce":"%s","manifest_sha256":"%s"}\n' "$prepared_nonce" "$(printf '4%.0s' {1..64})"; }
: > "$TEST_EVENTS"
reset_state
gather
[ "$NEXT_ID:$NEXT_KIND" = recovery:blocked ] || fail "mismatched abort receipt was accepted"
[ -f "$(active_marker_path)" ] || fail "mismatched abort receipt cleared active ownership"
[ ! -s "$TEST_EVENTS" ] || fail "mismatched abort receipt attempted cleanup"
rm -f "$(active_marker_path)"
pass "prepared abort refuses a mismatched durable receipt"

# A fresh dispatch converts the already-held PID lock before arming the local
# marker and verifies the protected remote helper before it can run.
: > "$TEST_EVENTS"
STUDIO_LAB_GIT_HEAD=cccccccccccccccccccccccccccccccccccccccc
STUDIO_OWNER_PIN_INSTALL_DIR=/private/install
STUDIO_OWNER_PIN_CONFIG=/private/config.yaml
STUDIO_OWNER_PIN_JOURNAL=/private/owner-pin.json
STUDIO_LAB_SOURCE_DIR=/private/source
CANARY_CTL_SOCKET=/private/provider.sock
STUDIO_STATUS_PORT=8080
DRAIN_TIMEOUT_S=10
LAB_TIMEOUT_S=20
READY_TIMEOUT_S=120
POLL_S=1
require_fresh_settings() { :; }
remote_probe() { printf '%s\n' '{"hardware_model":"Mac15,14","journal":{"state":"absent"},"installed":{"binary_version":"1.2.3"}}'; }
published_provider_identity_ok() { printf 'published\n' >> "$TEST_EVENTS"; }
source_snapshot() { printf '%s\n' '{}'; }
build_manifest() { printf '{}\n' > "$3"; }
prepare_window_dir() { printf 'directory\n' >> "$TEST_EVENTS"; }
stage_file() { printf 'stage:%s\n' "$(basename "$2")" >> "$TEST_EVENTS"; }
write_active_marker() { printf 'marker:%s\n' "$1" >> "$TEST_EVENTS"; mark_done "$OPS_SCOPE" active active "{\"phase\":\"$1\",\"nonce\":\"$2\",\"lab_git_head\":\"$STUDIO_LAB_GIT_HEAD\"}"; }
verify_staged_lifecycle() { printf 'verify-helper\n' >> "$TEST_EVENTS"; }
studio_ssh() {
  printf 'remote-run\n' >> "$TEST_EVENTS"
  printf '{"state":"running","nonce":"%s"}\n' "$(json_field "$(active_marker_path)" 'd.get("nonce")')"
}
reconcile_window() { printf 'reconcile\n' >> "$TEST_EVENTS"; }
start_window
python3 - "$TEST_EVENTS" <<'PY'
import sys
lines = open(sys.argv[1]).read().splitlines()
def before(a, b):
    assert lines.index(a) < lines.index(b), (a, b, lines)
before("acquire test-owner --purpose studio-lab-window:active-window", "marker:prepared")
before("marker:prepared", "verify-helper")
before("verify-helper", "marker:dispatching")
before("marker:dispatching", "remote-run")
before("remote-run", "marker:dispatched")
before("marker:dispatched", "reconcile")
PY
pass "dispatch arms a durable lock and marker before verified remote execution"

# Manifest helper accepts fixed lexical symlink paths, binds canonical bytes,
# records the staged probe hash, and does not require an idle runner snapshot.
SOURCE="$TMP_ROOT/source"
TARGET="$TMP_ROOT/targets"
mkdir -p "$SOURCE" "$TARGET"
chmod 700 "$SOURCE" "$TARGET"
git -C "$SOURCE" init -q
git -C "$SOURCE" -c user.name=test -c user.email=test@example.invalid commit --allow-empty -qm base
head="$(git -C "$SOURCE" rev-parse HEAD)"
paths=(
  phase3-binary/.build/release/macprovider-cli
  scripts/lab/cb-studio/glm53-bench/.build/release/GLMBench
  phase3-binary/.build/release/mlx.metallib
  scripts/lab/cb-studio/glm53-bench/.build/release/mlx.metallib
  .lab-window/fixture/target/config.json
  .lab-window/fixture/target/model.safetensors.index.json
)
for index in "${!paths[@]}"; do
  target="$TARGET/artifact-$index"
  printf 'artifact-%s\n' "$index" > "$target"
  chmod 700 "$target"
  mkdir -p "$SOURCE/$(dirname "${paths[$index]}")"
  ln -s "$target" "$SOURCE/${paths[$index]}"
done
snapshot="$TMP_ROOT/source.json"
python3 "$OPS_DIR/lib/studio-lab-window-manifest.py" source-snapshot \
  --source-dir "$SOURCE" --git-head "$head" --provider-label live.test > "$snapshot"
probe="$TMP_ROOT/probe.json"
python3 - "$probe" "$TMP_ROOT/install/macprovider-cli" <<'PY'
import json, sys
snapshot = {
  "config_sha256":"1"*64,"provider_plist_sha256":"2"*64,
  "watchdog_plist_sha256":"3"*64,"compatibility_set_sha256":"4"*64,
  "provider_id_sha256":"5"*64,"coordinator_origin":"https://example.invalid",
  "compatibility_set_id":"set","binary_version":"1.2.3","model":"model",
  "model_loaded":True,"network_state":"buyer_serving","requests_in_flight":4,
  "coordinator_connected":True,"operator_paused":False,"pid":42,
  "process_start_us":123456,"executable_path":sys.argv[2],
}
json.dump({"hardware_model":"Mac15,14","snapshot":snapshot,"installed":{"binary_sha256":"6"*64}}, open(sys.argv[1],"w"))
PY
mkdir -p "$TMP_ROOT/install"
manifest="$TMP_ROOT/manifest.json"
python3 "$OPS_DIR/lib/studio-lab-window-manifest.py" build \
  --nonce fixed-nonce --git-head "$head" --probe-json "$probe" \
  --source-snapshot-json "$snapshot" --probe-sha256 "7$(printf '7%.0s' {1..63})" \
  --lab-script-sha256 "8$(printf '8%.0s' {1..63})" --install-dir "$TMP_ROOT/install" \
  --config-path "$TMP_ROOT/config" --ctl-socket "$TMP_ROOT/control.sock" \
  --provider-label live.test --status-port 8080 --probe-path "$TMP_ROOT/probe.py" \
  --owner-pin-journal "$TMP_ROOT/owner.json" --lab-source-dir "$SOURCE" \
  --lab-script-path "$TMP_ROOT/run-window-diagnostic.sh" --log-path "$TMP_ROOT/supervisor.log" \
  --drain-timeout-s 10 --lab-timeout-s 3600 --ready-timeout-s 1200 --poll-s 2 > "$manifest"
python3 - "$snapshot" "$manifest" "$SOURCE" <<'PY'
import json, os, sys
source_snapshot, manifest, source = map(str, sys.argv[1:])
s = json.load(open(source_snapshot)); m = json.load(open(manifest))
assert m["baseline"]["probe_sha256"] == "7" * 64
assert m["baseline"]["snapshot"]["requests_in_flight"] == 4
path = s["artifacts"]["diagnostic_cli"]["path"]
assert path == source + "/phase3-binary/.build/release/macprovider-cli"
assert os.path.islink(path)
PY
pass "manifest binds canonical symlink targets and permits active-runner baseline"

printf '1..18\n'
