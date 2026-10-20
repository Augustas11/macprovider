#!/usr/bin/env bash
# Offline controller and manifest regressions for studio-lab-window.sh.
# shellcheck disable=SC2034,SC2329
set -euo pipefail

OPS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
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

remote_state() { printf '%s\n' '{"state":"absent"}'; }
require_fresh_settings() { :; }
completion_mark() { printf complete-test; }
mkdir -p "$(dirname "$(marker_path "$OPS_SCOPE" complete-test)")"
mark_done "$OPS_SCOPE" complete-test "done" '{"lab_exit_code":0}'
reset_state
gather
[ "$NEXT_ID:$NEXT_KIND" = done:done ] || fail "successful per-head completion was not terminal"
pass "matching successful completion is terminal only without a journal"

# Completion is committed locally before remote finish; a finish refusal keeps
# the active ownership marker and remote journal recoverable.
STUDIO_LAB_GIT_HEAD=bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb
window_paths
: > "$TEST_EVENTS"
write_active_marker dispatched finish-refusal
studio_ssh() { printf 'finish\n' >> "$TEST_EVENTS"; return 1; }
cleanup_remote_stage() { printf 'cleanup\n' >> "$TEST_EVENTS"; }
state='{"phase":"restored","revision":9,"nonce":"finish-refusal","action":"finish","lab_exit_code":0,"restored_process":{"pid":99,"process_start_us":123456,"executable_path":"/private/install/macprovider-cli"}}'
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
before("verify-helper", "remote-run")
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

printf '1..8\n'
