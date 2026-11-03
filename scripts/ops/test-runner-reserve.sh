#!/usr/bin/env bash
# Offline checks for lib/runner-reserve.sh and the reservation commands of
# lib/buyer-runner-target.py: the ssh stub runs the Pearl command here, and
# tests/fake_pearl_systemctl.py is the buyer-runner unit. Nothing leaves this Mac.
set -euo pipefail

OPS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
RESERVE="$OPS_DIR/lib/runner-reserve.sh"

die() { printf '[test-runner-reserve] FAIL: %s\n' "$*" >&2; exit 1; }
log() { printf '[test-runner-reserve] %s\n' "$*" >&2; }

# The helper refuses symlinked or shared-writable ancestors (/var -> /private/var,
# a 1777 /tmp on Linux CI), so prefer the job temp dir.
T="$(mktemp -d "${RUNNER_TEMP:-${TMPDIR:-/tmp}}/runner-reserve-test.XXXXXX")"
T="$(cd "$T" && pwd -P)"
CHILD=""
cleanup() {
  [ -z "$CHILD" ] || kill "$CHILD" 2>/dev/null || true
  rm -rf "$T"
}
trap cleanup EXIT

mkdir -p "$T/bin" "$T/svc" "$T/runner"
# shellcheck disable=SC2016  # the stub's own "$@" must stay literal
printf '#!/usr/bin/env bash\nexec bash -c "${@: -1}"\n' > "$T/bin/ssh"
printf '#!/usr/bin/env bash\nexec python3 %q "$@"\n' "$OPS_DIR/tests/fake_pearl_systemctl.py" > "$T/bin/systemctl"
chmod +x "$T/bin/ssh" "$T/bin/systemctl"
export PATH="$T/bin:$PATH" FAKE_PEARL="$T"
export MACPROVIDER_OPS_ENV=/dev/null MACPROVIDER_OPS_STATE_DIR="$T/ops-state"
export PEARL_SSH=fake-pearl
export PEARL_RUNNER_TARGETS="$T/runner/targets.json" PEARL_RUNNER_RESERVE_DIR="$T/reserve"
export RUNNER_STUDIO_PROVIDER_PREFIX=mp-studio01
export MACPROVIDER_OPS_OWNER=owner-a
printf '%s\n' "$PEARL_RUNNER_TARGETS" > "$T/svc/runner_targets_path"

ORIGINAL='{"targets": [{"provider_id": "mp-other0001", "model": "m/other", "slots": 2}, {"provider_id": "mp-studio01abcdef", "model": "org/old-model", "slots": 8}], "private": 7}'
reset() {
  rm -rf "$T/reserve" "$T/runner"/* "$T/svc"/runner-actions "$T/svc"/runner_loaded.json "$T/svc"/runner_restart_fail
  printf '%s\n' "$ORIGINAL" > "$PEARL_RUNNER_TARGETS"
  chmod 644 "$PEARL_RUNNER_TARGETS"
}
original_sha() { printf '%s\n' "$ORIGINAL" | shasum -a 256 | awk '{print $1}'; }
targets_sha() { shasum -a 256 "$PEARL_RUNNER_TARGETS" | awk '{print $1}'; }
restarts() { cat "$T/svc/runner-actions" 2>/dev/null | grep -c '^restart$' || true; }
has_studio() { grep -q mp-studio01 "$1"; }

run_rc() { # WANT LABEL CMD...
  local want="$1" label="$2" rc=0
  shift 2
  "$@" >"$T/out" 2>"$T/err" || rc=$?
  [ "$rc" = "$want" ] || { cat "$T/err" >&2; die "$label: exit $rc, want $want"; }
  log "ok: $label"
}

# 1. pause removes only the Studio row, keeps a timestamped backup of the exact
#    bytes, restarts the runner once; the restarted runner loaded the other rows.
reset
run_rc 0 "pause-studio" "$RESERVE" pause-studio
! has_studio "$PEARL_RUNNER_TARGETS" || die "Studio row still in targets.json"
grep -q mp-other0001 "$PEARL_RUNNER_TARGETS" || die "pause dropped another target"
grep -q '"private": 7' "$PEARL_RUNNER_TARGETS" || die "pause dropped other settings"
backup="$(ls "$T/runner"/targets.json.bak-runner-reserve-*)"
[ "$(shasum -a 256 "$backup" | awk '{print $1}')" = "$(original_sha)" ] || die "backup is not the original bytes"
[ "$(restarts)" = 1 ] || die "pause restarted the runner $(restarts) times"
! has_studio "$T/svc/runner_loaded.json" || die "restarted runner still loaded the Studio row"
! grep -q '^stop$' "$T/svc/runner-actions" || die "pause stopped the whole service"
grep -q mp-studio01 "$T/err" && die "Studio provider id printed" || true

# 2. same owner: pause again is a no-op; another owner's pause and restore are refused.
run_rc 0 "second pause by the same owner is idempotent" "$RESERVE" pause-studio
[ "$(restarts)" = 1 ] || die "idempotent pause restarted the runner"
run_rc 3 "another owner's pause is refused" env MACPROVIDER_OPS_OWNER=owner-b "$RESERVE" pause-studio
grep -q "already held by owner owner-a" "$T/err" || die "foreign reservation not named"
run_rc 3 "another owner's restore is refused" env MACPROVIDER_OPS_OWNER=owner-b "$RESERVE" restore
! has_studio "$PEARL_RUNNER_TARGETS" || die "foreign restore changed the targets"
run_rc 0 "status reports the holder" "$RESERVE" status
grep -q '"owner": "owner-a"' "$T/out" || die "status lacks the owner"

# 3. restore writes the backup bytes back and restarts; a second restore is a no-op.
run_rc 0 "restore" "$RESERVE" restore
[ "$(targets_sha)" = "$(original_sha)" ] || die "restore did not put the exact bytes back"
[ "$(restarts)" = 2 ] || die "restore did not restart the runner once"
has_studio "$T/svc/runner_loaded.json" || die "restarted runner did not load the Studio row"
[ ! -e "$T/reserve/runner-reserve.json" ] || die "reservation state left behind"
run_rc 0 "restore without a reservation is idempotent" "$RESERVE" restore
grep -q '"phase": "absent"' "$T/err" || die "idempotent restore not reported absent"
[ "$(restarts)" = 2 ] || die "idempotent restore restarted the runner"

# 4. with-studio-paused: CMD sees the paused targets; its failure is propagated
#    and the target is restored.
reset
run_rc 7 "with-studio-paused propagates CMD failure and restores" "$RESERVE" with-studio-paused -- \
  bash -c "grep -q mp-studio01 '$PEARL_RUNNER_TARGETS' && exit 9; exit 7"
[ "$(targets_sha)" = "$(original_sha)" ] || die "failed CMD left the Studio target paused"
[ ! -e "$T/reserve/runner-reserve.json" ] || die "failed CMD left a reservation"
run_rc 0 "with-studio-paused success restores" "$RESERVE" with-studio-paused -- true
[ "$(targets_sha)" = "$(original_sha)" ] || die "successful CMD left the Studio target paused"

# 5. TERM to the wrapper while CMD runs: CMD is stopped and the target restored.
reset
"$RESERVE" with-studio-paused -- bash -c 'echo $$ > "$1"; exec sleep 60' _ "$T/cmd.pid" >"$T/out" 2>"$T/err" &
CHILD=$!
for _ in $(seq 1 100); do [ -s "$T/cmd.pid" ] && break; sleep 0.2; done
[ -s "$T/cmd.pid" ] || die "wrapper never started CMD"
grep -q '"phase": "paused"' "$T/reserve/runner-reserve.json" || die "CMD started without a paused runner"
kill -TERM "$CHILD"
rc=0; wait "$CHILD" || rc=$?
CHILD=""
[ "$rc" = 143 ] || { cat "$T/err" >&2; die "TERM exit $rc, want 143"; }
[ "$(targets_sha)" = "$(original_sha)" ] || die "TERM left the Studio target paused"
[ ! -e "$T/reserve/runner-reserve.json" ] || die "TERM left a reservation"
sleep 0.5
! kill -0 "$(cat "$T/cmd.pid")" 2>/dev/null || die "CMD outlived the wrapper"
log "ok: TERM restores the Studio target"

# 6. an outstanding reservation of another owner: refused before CMD, untouched.
reset
run_rc 0 "owner-a pauses" "$RESERVE" pause-studio
run_rc 3 "owner-b wrapper refused on a foreign reservation" env MACPROVIDER_OPS_OWNER=owner-b \
  "$RESERVE" with-studio-paused -- touch "$T/ran"
[ ! -e "$T/ran" ] || die "CMD ran under a foreign reservation"
! has_studio "$PEARL_RUNNER_TARGETS" || die "foreign wrapper restored owner-a's reservation"
grep -q "NOT restored" "$T/err" && die "refused wrapper claimed an unrestored reservation" || true
run_rc 0 "owner-a restores" "$RESERVE" restore

# 7. a runner that fails to restart on pause is put back on the original bytes.
reset
touch "$T/svc/runner_restart_fail_once"
run_rc 1 "pause with a failing runner restart" "$RESERVE" with-studio-paused -- touch "$T/ran2"
[ ! -e "$T/ran2" ] || die "CMD ran without a paused runner"
[ "$(targets_sha)" = "$(original_sha)" ] || die "failed pause left the Studio target removed"
[ ! -e "$T/reserve/runner-reserve.json" ] || die "failed pause left a reservation"
# A restore whose restart also fails keeps the reservation for another restore.
run_rc 0 "owner-a pauses again" "$RESERVE" pause-studio
touch "$T/svc/runner_restart_fail"
run_rc 1 "restore with a failing runner restart" "$RESERVE" restore
grep -q "NOT restored" "$T/err" || die "unrestored runner not reported"
[ -e "$T/reserve/runner-reserve.json" ] || die "failed restore dropped the reservation"
rm -f "$T/svc/runner_restart_fail"
run_rc 0 "restore retried" "$RESERVE" restore
[ "$(targets_sha)" = "$(original_sha)" ] && [ ! -e "$T/reserve/runner-reserve.json" ] || die "retried restore incomplete"

# 8. refusals: no Studio row, two Studio rows, no runner reservation configured.
reset
printf '{"targets": [{"provider_id": "mp-other0001", "model": "m", "slots": 2}]}\n' > "$PEARL_RUNNER_TARGETS"
run_rc 3 "pause refuses without a Studio row" "$RESERVE" pause-studio
printf '{"targets": [{"provider_id": "mp-studio01a"}, {"provider_id": "mp-studio01b"}]}\n' > "$PEARL_RUNNER_TARGETS"
run_rc 3 "pause refuses two Studio rows" "$RESERVE" pause-studio
[ ! -e "$T/reserve/runner-reserve.json" ] || die "refused pause left a reservation"
run_rc 3 "pause refuses without a configured prefix" env -u RUNNER_STUDIO_PROVIDER_PREFIX "$RESERVE" pause-studio
reset
run_rc 0 "prefix none runs CMD without touching the runner" env RUNNER_STUDIO_PROVIDER_PREFIX=none \
  "$RESERVE" with-studio-paused -- touch "$T/ran3"
[ -e "$T/ran3" ] && [ "$(restarts)" = 0 ] || die "prefix none touched the runner or skipped CMD"
touch "$T/svc/runner_inactive"
run_rc 3 "pause refuses an inactive runner" "$RESERVE" pause-studio
rm -f "$T/svc/runner_inactive"

# 9. set-target-model retargets only the Studio row; refused during a reservation.
reset
# shellcheck source=lib/common.sh
retarget() { bash -c '. "$1/lib/common.sh"; . "$1/lib/runner-reserve.sh"; runner_set_studio_model "$2"' _ "$OPS_DIR" "$1"; }
run_rc 0 "set-target-model" retarget grant-ai/New-Model-4bit
python3 - "$PEARL_RUNNER_TARGETS" <<'PY' || die "set-target-model changed more than the Studio model"
import json, sys
d = json.load(open(sys.argv[1]))
assert d["targets"][0] == {"provider_id": "mp-other0001", "model": "m/other", "slots": 2}
assert d["targets"][1] == {"provider_id": "mp-studio01abcdef", "model": "grant-ai/New-Model-4bit", "slots": 8}
assert d["private"] == 7
PY
ls "$T/runner"/targets.json.bak-runner-model-* >/dev/null || die "set-target-model kept no backup"
[ "$(restarts)" = 1 ] || die "set-target-model did not restart once"
run_rc 0 "set-target-model to the same model is a no-op" retarget grant-ai/New-Model-4bit
[ "$(restarts)" = 1 ] || die "unchanged model restarted the runner"
run_rc 0 "pause before retarget" "$RESERVE" pause-studio
run_rc 3 "set-target-model refused during a reservation" retarget other/model
run_rc 0 "restore after retarget refusal" "$RESERVE" restore
grep -q '"grant-ai/New-Model-4bit"' "$PEARL_RUNNER_TARGETS" || die "restore lost the retargeted model"
# A retarget whose restart fails rolls the targets back; when the rollback
# restart fails too, the runner is started again and the failure is named.
before_sha="$(targets_sha)"
touch "$T/svc/runner_restart_fail"
run_rc 1 "set-target-model with failing restarts" retarget other/model
[ "$(targets_sha)" = "$before_sha" ] || die "failed retarget did not roll the targets back"
grep -q "did not come back stable" "$T/err" || die "unstable rollback not named"
rm -f "$T/svc/runner_restart_fail"

# 10. catalog-activate: the ordinary gateway_proof step is blocked without a
#     prefix and, with one, is a mutate step that runs the probe under the
#     reservation and states the runner pause as its downtime.
CAT="$OPS_DIR/catalog-activate.sh"
gather_proof="$(sed -n '/local proof_downtime=""/,/next_meta gateway_proof/p' "$CAT")"
for want in 'elif [ -z "${RUNNER_STUDIO_PROVIDER_PREFIX:-}" ]; then' \
            'set_next gateway_proof blocked' \
            'elif runner_reserve_enabled; then' \
            '"scripts/ops/catalog-activate.sh _gateway-proof --reserve-runner"' \
            'proof_downtime="Pearl buyer runner: its Studio target is paused for the probe' \
            'next_meta gateway_proof "AGENTS.md#hard-rules--activation-evidence-and-campaign-discipline" "$proof_downtime"'; do
  printf '%s' "$gather_proof" | grep -qF -- "$want" || die "catalog-activate gateway_proof step lacks: $want"
done
grep -qF 'runner_with_studio_paused gateway_proof_on_idle_canary' "$CAT" || die "reserved proof does not run under the reservation"
log "ok: catalog-activate gateway_proof runs under the runner reservation"

log PASS
