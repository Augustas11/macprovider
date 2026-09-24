#!/usr/bin/env bash
# Hermetic tests for scripts/lib/autotune-activate.sh (#1688 C1). No Pearl, no
# root, no real flock(1): a fake ssh runs remote commands locally with the Pearl
# lock/state paths rewritten into a temp root, and a Python flock shim gives
# flock(1) semantics on macOS and Linux.
#
#   A. Executed bytes: renew's aa_publish / aa_rollback send exactly the golden
#      remote scripts and argv renew sent before the lib existed.
#   B. Lease: aa_lease_acquire holds deploy's lock set; while held, renew's
#      remote publish and rollback refuse before mutating and a second lease is
#      refused; lease-mode publish and rollback run THROUGH the lease runner
#      (inheriting its locked descriptors) and refuse when started any other
#      way. After release the reverse holds.
#   D. Channel loss: a runner killed after a successful command makes the next
#      command (and a rollback) refuse with the lease latched lost; a runner
#      killed while its child mutates cannot free the locks for a competing
#      holder until that child exits.
#   C. Lease watchdog: past AA_LEASE_MAX_SECONDS the controller is TERMed and
#      its EXIT trap releases the locks.
#   E. Lease deadline: a command still running at MAX + ROLLBACK seconds is
#      killed (process group, TERM then KILL) by the remote runner, the
#      controller ends lease-lost, and both locks free within a bounded grace.
#   F. #1693 L0: renewal's publish and rollback refuse under the locks while a
#      pricing transaction journal exists.
#   G. #1693 E2 V8: a coordinator that is still booting (no SIGHUP handler yet,
#      /healthz not answering) is never signalled: publish aborts pre-mutation,
#      rollback restores without the SIGHUP; a stopped one is not waited for.
set -euo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"
lib="$root/scripts/lib/autotune-activate.sh"
golden_publish="$root/scripts/tests/fixtures/renew-remote-publish.golden.sh"
golden_rollback="$root/scripts/tests/fixtures/renew-remote-rollback.golden.sh"

T="$(mktemp -d)"
T="$(cd "$T" && pwd -P)"
trap 'kill "$(cat "$T/coordinator.pid" 2>/dev/null)" 2>/dev/null; pkill -f "$T/" >/dev/null 2>&1 || true; rm -rf "$T"' EXIT
fail() { printf '[test-autotune-activate] FAIL: %s\n' "$*" >&2; exit 1; }

mkdir -p "$T/bin" "$T/fake/run/lock" "$T/fake/var/lib" "$T/rbwin"
cat >"$T/bin/ssh" <<'SSH'
#!/usr/bin/env bash
set -u
while [ $# -gt 0 ]; do
  case "$1" in -o|-i|-p) shift 2 ;; -*) shift ;; *) break ;; esac
done
shift
cmd="$*"
if [ "${AA_FAKE_SSH_MODE:-}" = record ]; then
  n=$(( $(ls "$AA_FAKE_ROOT"/record.argv.* 2>/dev/null | wc -l) + 1 ))
  printf '%s' "$cmd" >"$AA_FAKE_ROOT/record.argv.$n"
  cat >"$AA_FAKE_ROOT/record.stdin.$n"
  exit 0
fi
cmd="$(printf '%s\n' "$cmd" | pearl-rw)"
case "$cmd" in
  "bash -s"*) pearl-rw | bash -c "$cmd" ;;
  *) exec bash -c "$cmd" ;;
esac
SSH
# Pearl paths -> the temp root, for commands, scripts and (via the lease
# runner's decode step) every script sent through the lease channel.
cat >"$T/bin/pearl-rw" <<'RW'
#!/usr/bin/env bash
exec sed -e "s#/opt/macprovider/#$AA_FAKE_ROOT/opt/macprovider/#g" \
    -e "s#\"/opt\"#\"$AA_FAKE_ROOT/opt\"#g" \
    -e "s#/run/lock/#$AA_FAKE_ROOT/run/lock/#g" \
    -e "s#/tmp/macprovider-activation-lease\.#$AA_FAKE_ROOT/tmp/macprovider-activation-lease.#g" \
    -e "s#base64 -d >\"\\\$work/cmd\"#base64 -d | pearl-rw >\"\\\$work/cmd\"#g" \
    -e "s#| base64 -d)\"; fi#| base64 -d | pearl-rw)\"; fi#g" \
    -e "s#/var/lib/macprovider-pearl-updater/#$AA_FAKE_ROOT/var/lib/macprovider-pearl-updater/#g" \
    -e "s#mv -Tf#$AA_MV_TF#g" \
    -e "s#st_uid != 0#st_uid != $AA_FAKE_UID#g" \
    -e "s#st_gid != 0#st_gid != $AA_FAKE_GID#g"
RW
cat >"$T/bin/flock" <<'FLOCK'
#!/usr/bin/env python3
import fcntl, os, subprocess, sys
args = sys.argv[1:]
mode = fcntl.LOCK_EX
while args and args[0].startswith("-"):
    flag = args.pop(0)
    if flag in ("-n", "--nonblock"):
        mode |= fcntl.LOCK_NB
    elif flag in ("-s", "--shared"):
        mode = (mode & fcntl.LOCK_NB) | fcntl.LOCK_SH
target, cmd = args[0], args[1:]
fd = int(target) if target.isdigit() and not cmd else os.open(target, os.O_RDONLY | os.O_CREAT, 0o600)
try:
    fcntl.flock(fd, mode)
except BlockingIOError:
    sys.exit(1)
sys.exit(subprocess.call(cmd) if cmd else 0)
FLOCK
# The "coordinator": a process that ignores the SIGHUPs publish/rollback send.
(python3 -c 'import signal, time; signal.signal(signal.SIGHUP, signal.SIG_IGN); time.sleep(600)' </dev/null >/dev/null 2>&1 &
  echo "$!" >"$T/coordinator.pid")
# systemctl: the coordinator's MainPID, and its ActiveState (coord-stopped).
cat >"$T/bin/systemctl" <<SYSTEMCTL
#!/bin/sh
case "\$*" in
  *ActiveState*) if [ -e "$T/fake/coord-stopped" ]; then echo inactive; else echo active; fi ;;
  *) cat "$T/coordinator.pid" ;;
esac
SYSTEMCTL
# curl: the coordinator's /healthz answers unless it is still booting.
cat >"$T/bin/curl" <<CURL
#!/bin/sh
case "\$*" in
  *127.0.0.1:8444/healthz*) [ ! -e "$T/fake/coord-booting" ] ;;
  *) exec "$(command -v curl)" "\$@" ;;
esac
CURL
chmod 0755 "$T/bin/ssh" "$T/bin/pearl-rw" "$T/bin/flock" "$T/bin/systemctl" "$T/bin/curl"
mkdir -p "$T/fake/tmp"
printf 'import sys\nsys.exit(0)\n' >"$T/lock-validate-ok.py"
printf 'import sys\nsys.exit(0)\n' >"$T/rbwin/autotune_window.py"
printf 'import sys\nsys.exit(1)\n' >"$T/verifier-fails.py"

export PATH="$T/bin:$PATH"
export AA_FAKE_ROOT="$T/fake"
# GNU mv has -T (no-target-directory); BSD/macOS mv lacks it, where -h
# (do not follow a symlinked target) is the equivalent for the swap.
if mv --version >/dev/null 2>&1; then export AA_MV_TF="mv -Tf"; else export AA_MV_TF="mv -hf"; fi
export AA_FAKE_UID; AA_FAKE_UID="$(id -u)"
export AA_FAKE_GID; AA_FAKE_GID="$(python3 -c 'import os,sys;print(os.stat(sys.argv[1]).st_gid)' "$T/fake")"

# Controller preamble: what a caller (renew / the content lane) defines.
preamble() {
  cat <<'PRE'
set -euo pipefail
log()   { printf '[test] %s\n' "$*" >&2; }
fatal() { printf '[test] ERROR: %s\n' "$*" >&2; exit 1; }
PEARL_SSH=pearl
SSH_OPTS=(-o ConnectTimeout=15 -o BatchMode=yes)
SSH() { ssh "${SSH_OPTS[@]}" "$PEARL_SSH" "$@"; }
. "$AA_LIB"
PRE
}
export AA_LIB="$lib"

# ---------------------------------------------------------------------------
# A. Executed bytes are renew's golden bytes.
# ---------------------------------------------------------------------------
mkdir -p "$T/work"
AA_FAKE_SSH_MODE=record bash -c "$(preamble)"'
REMOTE_AUTOTUNE_DIR=/opt/macprovider/autotune
COORDINATOR_UNIT=macprovider-coordinator
RELEASE_DIRNAME=published-2026-09-30-inband-provenance-v1-0123456789abcdef
REMOTE_TMP=".incoming-$RELEASE_DIRNAME.777"
CURRENT_TARGET=releases/published-2026-09-23-inband-provenance-v1-fedcba9876543210
ORIG_PREVIOUS_TARGET="releases/a
releases/b"
LOCK_HELPER=/tmp/macprovider-autotune-lock.X/pearl_autotune_deploy_lock.py
WINDOW_HELPER=/tmp/macprovider-autotune-lock.X/autotune_window.py
CONTINUITY_VERIFIER=/tmp/macprovider-autotune-lock.X/scripts/catalog-release.py
AA_WORK_DIR="$1"
AA_GATE_SNIPPET="$AA_GATE_CONTINUITY_CHECK"
AA_COVERAGE_POLICY=warn
AA_LOCK_MODE=flock
aa_publish
aa_rollback
' _ "$T/work" 2>/dev/null
cmp -s "$T/fake/record.stdin.1" "$golden_publish" || fail "renew publish stdin is not the golden remote script"
cmp -s "$T/fake/record.stdin.2" "$golden_rollback" || fail "renew rollback stdin is not the golden remote script"
want_pub="bash -s -- /opt/macprovider/autotune .incoming-published-2026-09-30-inband-provenance-v1-0123456789abcdef.777 published-2026-09-30-inband-provenance-v1-0123456789abcdef releases/published-2026-09-23-inband-provenance-v1-fedcba9876543210 macprovider-coordinator /tmp/macprovider-autotune-lock.X/pearl_autotune_deploy_lock.py /tmp/macprovider-autotune-lock.X/autotune_window.py /tmp/macprovider-autotune-lock.X/scripts/catalog-release.py"
[ "$(cat "$T/fake/record.argv.1")" = "$want_pub" ] || fail "renew publish argv changed: $(cat "$T/fake/record.argv.1")"
# Exact .previous-target bytes (one entry per line, newline-terminated).
prev_b64="$(printf 'releases/a\nreleases/b\n' | base64 | tr -d '\n')"
want_rb="bash -s -- /opt/macprovider/autotune releases/published-2026-09-23-inband-provenance-v1-fedcba9876543210 $prev_b64 macprovider-coordinator /tmp/macprovider-autotune-lock.X/pearl_autotune_deploy_lock.py releases/published-2026-09-30-inband-provenance-v1-0123456789abcdef /tmp/macprovider-autotune-lock.X/autotune_window.py"
[ "$(cat "$T/fake/record.argv.2")" = "$want_rb" ] || fail "renew rollback argv changed: $(cat "$T/fake/record.argv.2")"
rm -f "$T"/fake/record.*

# The refuse coverage policy appends the override flag and aborts before the
# window/current mutation; the lease lock block never takes the locks.
bash -c "$(preamble)"'
AA_GATE_SNIPPET="$AA_GATE_CONTINUITY_CHECK"
AA_COVERAGE_POLICY=refuse
AA_LOCK_MODE=lease
aa_render_publish_script
' >"$T/refuse-lease.sh"
python3 - "$T/refuse-lease.sh" <<'PY' || fail "refuse/lease rendering is wrong"
import sys
s = open(sys.argv[1]).read()
refuse = s.index('if [ "$cov_rc" -ne 0 ] && [ "${9:-0}" != 1 ]; then')
assert refuse < s.index("mutated=1") < s.index('"$window" apply')
# Lease mode never (re)opens or takes the locks: it holds the runner's.
assert "exec 8<" not in s and "exec 9<" not in s and "flock -n 8 ||" not in s
assert s.index('lease_why="$(lease_fds_held)" || abort_pre_mutation') < s.index("continuity-check")
# Coverage is the live coordinator's admitted set, never the Python mirror.
assert 'coverage --admitted-json "$check/admitted.json" --poolz-json "$poolz"' in s and "coverage --root" not in s
assert s.index('if [ "$cov_rc" -ne 0 ] && [ -n "${10:-}" ]; then') < s.index("mutated=1")
PY

# ---------------------------------------------------------------------------
# B. Lease vs renewal.
# ---------------------------------------------------------------------------
A="$T/fake/opt/macprovider/autotune"
mkdir -p "$A/releases/old" "$A/releases/.incoming-new.1"
ln -s releases/old "$A/current"
# Remote paths are the real Pearl paths; the fake ssh maps them into $T/fake.
publish_args=(/opt/macprovider/autotune .incoming-new.1 new releases/old macprovider-coordinator "$T/lock-validate-ok.py" /nonexistent-window "$T/verifier-fails.py")
run_publish() { # $1 lock mode, sent as a plain SSH session; remote rc + stderr in $T/pub.err
  mkdir -p "$A/releases/.incoming-new.1"
  local extra=()
  [ "$1" = flock ] || extra=(0 "" "")
  bash -c "$(preamble)"'
AA_GATE_SNIPPET="$AA_GATE_CONTINUITY_CHECK"
AA_COVERAGE_POLICY=warn
AA_LOCK_MODE="$1"
shift
aa_render_publish_script | SSH bash -s -- "$@"
' _ "$1" "${publish_args[@]}" ${extra[@]+"${extra[@]}"} >/dev/null 2>"$T/pub.err"
}
run_rollback() {
  bash -c "$(preamble)"'
aa_render_rollback_script flock | SSH bash -s -- "$1" releases/old __EMPTY__ macprovider-coordinator "$2" releases/new "$3"
' _ /opt/macprovider/autotune "$T/lock-validate-ok.py" "$T/rbwin/autotune_window.py" >/dev/null 2>"$T/rb.err"
}
free_locks() { # both Pearl locks acquirable right now
  flock -n "$T/fake/run/lock/macprovider-pearl-updater.lock" true &&
    flock -n "$T/fake/opt/macprovider/.coordinator-deploy.lock" true
}

# The lease controller: acquire, then publish and roll back THROUGH the lease
# runner, then hold the lease until told to release it.
mkdir -p "$T/lw" "$A/releases/new"
bash -c "$(preamble)"'
trap "exit 71" HUP INT TERM
trap aa_lease_release EXIT
AA_WORK_DIR="$1"
aa_lease_acquire
AA_GATE_SNIPPET="$AA_GATE_CONTINUITY_CHECK"; AA_COVERAGE_POLICY=warn; AA_LOCK_MODE=lease
aa_render_publish_script >"$AA_WORK_DIR/publish.sh"
rc=0
aa_lease_run "$AA_WORK_DIR/publish.sh" "$AA_WORK_DIR/publish.out" "$AA_WORK_DIR/publish.err" \
  /opt/macprovider/autotune .incoming-new.1 new releases/old macprovider-coordinator "$2" /nonexistent-window "$3" 0 "" "" || rc=$?
echo "$rc" >"$AA_WORK_DIR/publish.rc"
ln -sfn releases/new "$5/current"
aa_render_rollback_script lease >"$AA_WORK_DIR/rollback.sh"
rc=0
aa_lease_run "$AA_WORK_DIR/rollback.sh" "$AA_WORK_DIR/rollback.out" "$AA_WORK_DIR/rollback.err" \
  /opt/macprovider/autotune releases/old __EMPTY__ macprovider-coordinator "$2" releases/new "$6" || rc=$?
echo "$rc" >"$AA_WORK_DIR/rollback.rc"
echo ready >"$AA_WORK_DIR/state"
until [ -e "$4" ]; do sleep 0.1; done
' _ "$T/lw" "$T/lock-validate-ok.py" "$T/verifier-fails.py" "$T/lease.ctl" "$A" "$T/rbwin/autotune_window.py" 2>"$T/lease.err" &
lease_pid=$!
for _ in $(seq 1 150); do [ -s "$T/lw/state" ] && break; kill -0 "$lease_pid" 2>/dev/null || break; sleep 0.1; done
[ -s "$T/lw/state" ] || { cat "$T/lease.err" "$T/lw/"*.err >&2 2>/dev/null; fail "the lease controller did not take deploy's lock set and run its commands"; }
[ "$(cat "$T/lw/publish.rc")" = 2 ] && grep -q "content drift under lock" "$T/lw/publish.err" \
  || fail "lease-mode publish through the runner must pass the lock proof and reach the gate (rc=$(cat "$T/lw/publish.rc")): $(cat "$T/lw/publish.err")"
[ "$(cat "$T/lw/rollback.rc")" = 0 ] && grep -q "rolled back to releases/old" "$T/lw/rollback.out" \
  || fail "lease-mode rollback through the runner must roll back (rc=$(cat "$T/lw/rollback.rc")): $(cat "$T/lw/rollback.out" "$T/lw/rollback.err")"
[ "$(readlink "$A/current")" = releases/old ] || fail "lease-mode rollback did not restore current"

rc=0; run_publish flock || rc=$?
[ "$rc" -eq 2 ] || fail "renewal publish while the lease is held must abort pre-mutation (rc=$rc)"
grep -q "Pearl updater lock held; not mutating" "$T/pub.err" || fail "renewal did not refuse on the held lease: $(cat "$T/pub.err")"
[ "$(readlink "$A/current")" = releases/old ] || fail "renewal mutated current while the lease was held"
[ ! -e "$A/releases/.incoming-new.1" ] || fail "refused renewal left its incoming dir"
[ ! -e "$A/releases/new/release.json" ] || fail "refused renewal staged a release"

rc=0; run_rollback || rc=$?
[ "$rc" -eq 1 ] && grep -q "rollback: Pearl updater lock held; not mutating" "$T/rb.err" \
  || fail "renew rollback must refuse while the lease is held (rc=$rc): $(cat "$T/rb.err")"

rc=0; bash -c "$(preamble)"$'\n''aa_lease_acquire' 2>"$T/lease2.err" || rc=$?
[ "$rc" -ne 0 ] && grep -q "holds the Pearl lock" "$T/lease2.err" || fail "a second lease must be refused (rc=$rc): $(cat "$T/lease2.err")"

# A lease-mode script started any other way than by the runner holds no lock.
rc=0; run_publish lease || rc=$?
[ "$rc" -eq 2 ] && grep -q "activation lease locks not inherited" "$T/pub.err" \
  || fail "lease-mode publish outside the lease runner must refuse (rc=$rc): $(cat "$T/pub.err")"
rc=0
bash -c "$(preamble)"'
aa_render_rollback_script lease | SSH bash -s -- "$1" releases/old __EMPTY__ macprovider-coordinator "$2" releases/new "$3"
' _ /opt/macprovider/autotune "$T/lock-validate-ok.py" "$T/rbwin/autotune_window.py" >/dev/null 2>"$T/rb.err" || rc=$?
[ "$rc" -eq 1 ] && grep -q "rollback: activation lease locks not inherited" "$T/rb.err" \
  || fail "lease-mode rollback outside the lease runner must refuse (rc=$rc): $(cat "$T/rb.err")"

kill -0 "$lease_pid" 2>/dev/null || fail "the lease controller died while holding the lease: $(cat "$T/lease.err")"
touch "$T/lease.ctl"
wait "$lease_pid" || fail "lease controller failed: $(cat "$T/lease.err")"

rc=0; run_publish flock || rc=$?
[ "$rc" -eq 2 ] && grep -q "content drift under lock" "$T/pub.err" \
  || fail "after release, renewal must take the locks and reach its gate (rc=$rc): $(cat "$T/pub.err")"
rc=0; run_publish lease || rc=$?
[ "$rc" -eq 2 ] && grep -q "activation lease locks not inherited" "$T/pub.err" \
  || fail "lease-mode publish after the lease was released must refuse (rc=$rc): $(cat "$T/pub.err")"

# ---------------------------------------------------------------------------
# D. Channel loss.
# ---------------------------------------------------------------------------
# D1: the runner dies after a successful command and before the next one.
mkdir -p "$T/d1"
rc=0
bash -c "$(preamble)"'
trap "" TERM
trap aa_lease_release EXIT
AA_WORK_DIR="$1"; AA_LOCK_MODE=lease
REMOTE_AUTOTUNE_DIR=/opt/macprovider/autotune COORDINATOR_UNIT=macprovider-coordinator RELEASE_DIRNAME=new
CURRENT_TARGET=releases/old ORIG_PREVIOUS_TARGET="" LOCK_HELPER="$5" WINDOW_HELPER="$6"
aa_lease_acquire
printf "touch %q\n" "$2" >"$AA_WORK_DIR/c1.sh"
printf "touch %q\n" "$3" >"$AA_WORK_DIR/c2.sh"
c1=0; aa_lease_run "$AA_WORK_DIR/c1.sh" "$AA_WORK_DIR/o1" "$AA_WORK_DIR/e1" || c1=$?
echo "$c1 $AA_LEASE_HOLDER_PID" >"$AA_WORK_DIR/c1"
until [ -e "$4" ]; do sleep 0.1; done
c2=0; aa_lease_run "$AA_WORK_DIR/c2.sh" "$AA_WORK_DIR/o2" "$AA_WORK_DIR/e2" || c2=$?
echo "$c2 $AA_LEASE_LOST" >"$AA_WORK_DIR/c2"
rb=0; aa_rollback || rb=$?
echo "$rb" >"$AA_WORK_DIR/rb"
if aa_lease_lost; then exit 6; fi
exit 0
' _ "$T/d1" "$T/d1.marker1" "$T/d1.marker2" "$T/d1.ctl" "$T/lock-validate-ok.py" "$T/rbwin/autotune_window.py" 2>"$T/d1.err" &
d1_pid=$!
for _ in $(seq 1 100); do [ -s "$T/d1/c1" ] && break; kill -0 "$d1_pid" 2>/dev/null || break; sleep 0.1; done
[ -s "$T/d1/c1" ] || { cat "$T/d1.err" >&2; fail "D1: first command did not return"; }
read -r d1_rc d1_holder <"$T/d1/c1"
[ "$d1_rc" = 0 ] && [ -e "$T/d1.marker1" ] || fail "D1: the first command must run through the lease (rc=$d1_rc)"
kill -9 "$d1_holder"
for _ in $(seq 1 50); do free_locks && break; sleep 0.1; done
kill -0 "$d1_pid" 2>/dev/null || fail "D1: the controller died early: $(cat "$T/d1.err")"
touch "$T/d1.ctl"
rc=0; wait "$d1_pid" || rc=$?
[ "$rc" -eq 6 ] || fail "D1: the controller must end lease-lost (rc=$rc): $(cat "$T/d1.err")"
[ "$(cat "$T/d1/c2")" = "1 1" ] || fail "D1: the command after holder loss must refuse with the lease lost: $(cat "$T/d1/c2")"
[ ! -e "$T/d1.marker2" ] || fail "D1: a command ran after the lease runner died"
[ "$(cat "$T/d1/rb")" = 1 ] && grep -q "ROLLBACK REFUSED: the activation lease is lost" "$T/d1.err" \
  || fail "D1: a lease-mode rollback after holder loss must refuse, not roll back from another session: $(cat "$T/d1.err")"
free_locks || fail "D1: the locks must be free once the runner is gone"

# D2: the runner dies while its child is mid-mutation; the child's inherited
# descriptors keep both locks until it exits.
mkdir -p "$T/d2"
bash -c "$(preamble)"'
trap "" TERM
trap aa_lease_release EXIT
AA_WORK_DIR="$1"; AA_LOCK_MODE=lease
aa_lease_acquire
printf "touch %q; sleep 3; touch %q\n" "$2" "$3" >"$AA_WORK_DIR/c.sh"
echo "$AA_LEASE_HOLDER_PID" >"$AA_WORK_DIR/holder"
c=0; aa_lease_run "$AA_WORK_DIR/c.sh" "$AA_WORK_DIR/o" "$AA_WORK_DIR/e" || c=$?
echo "$c $AA_LEASE_LOST" >"$AA_WORK_DIR/result"
' _ "$T/d2" "$T/d2.started" "$T/d2.finished" 2>"$T/d2.err" &
d2_pid=$!
for _ in $(seq 1 100); do [ -e "$T/d2.started" ] && break; kill -0 "$d2_pid" 2>/dev/null || break; sleep 0.1; done
[ -e "$T/d2.started" ] && [ -s "$T/d2/holder" ] || { cat "$T/d2.err" >&2; fail "D2: the mutation did not start"; }
kill -9 "$(cat "$T/d2/holder")"
sleep 0.5
[ ! -e "$T/d2.finished" ] || fail "D2: the mutation finished too early for the test"
! flock -n "$T/fake/run/lock/macprovider-pearl-updater.lock" true \
  || fail "D2: a competing holder took the updater lock while the runner's child was mutating"
! flock -n "$T/fake/opt/macprovider/.coordinator-deploy.lock" true \
  || fail "D2: a competing holder took the coordinator deploy lock while the runner's child was mutating"
wait "$d2_pid" || fail "D2: controller failed: $(cat "$T/d2.err")"
[ "$(cat "$T/d2/result")" = "1 1" ] || fail "D2: losing the runner mid-command must report the lease lost: $(cat "$T/d2/result")"
for _ in $(seq 1 50); do [ -e "$T/d2.finished" ] && free_locks && break; sleep 0.1; done
[ -e "$T/d2.finished" ] || fail "D2: the started mutation must run to completion"
free_locks || fail "D2: the locks must be free once the mutating child exits"
rm -rf "$T/fake/tmp/"macprovider-activation-lease.*

# ---------------------------------------------------------------------------
# E. Lease deadline bounds a running command. The command (and its child)
# ignore TERM, so the runner must escalate to KILL.
# ---------------------------------------------------------------------------
mkdir -p "$T/e"
e_start=$SECONDS
rc=0
AA_LEASE_MAX_SECONDS=1 AA_LEASE_ROLLBACK_SECONDS=2 AA_LEASE_KILL_GRACE_SECONDS=20 bash -c "$(preamble)"'
trap "" TERM
trap aa_lease_release EXIT
AA_WORK_DIR="$1"; AA_LOCK_MODE=lease
aa_lease_acquire
printf "echo quick\n" >"$AA_WORK_DIR/ok.sh"
ok=0; aa_lease_run "$AA_WORK_DIR/ok.sh" "$AA_WORK_DIR/ok.out" "$AA_WORK_DIR/ok.err" || ok=$?
echo "$ok $(cat "$AA_WORK_DIR/ok.out")" >"$AA_WORK_DIR/ok"
printf "trap \"\" TERM; touch %q; sleep 59 & wait; touch %q\n" "$2" "$3" >"$AA_WORK_DIR/hang.sh"
c=0; aa_lease_run "$AA_WORK_DIR/hang.sh" "$AA_WORK_DIR/o" "$AA_WORK_DIR/e" || c=$?
echo "$c $AA_LEASE_LOST" >"$AA_WORK_DIR/result"
if aa_lease_lost; then exit 6; fi
' _ "$T/e" "$T/e.started" "$T/e.finished" 2>"$T/e.err" || rc=$?
e_elapsed=$((SECONDS - e_start))
[ "$(cat "$T/e/ok")" = "0 quick" ] || fail "E: a normal command must run normally under the deadline: $(cat "$T/e/ok")"
[ -e "$T/e.started" ] || fail "E: the hanging command never started: $(cat "$T/e.err")"
[ "$rc" -eq 6 ] && [ "$(cat "$T/e/result")" = "1 1" ] \
  || fail "E: a command killed at the lease deadline must end the controller lease-lost (rc=$rc result=$(cat "$T/e/result" 2>/dev/null)): $(cat "$T/e.err")"
grep -q "lease-expired: command 2 stopped at the lease deadline" "$T/e/e" || fail "E: the runner must report lease-expired: $(cat "$T/e/e")"
[ "$e_elapsed" -le 20 ] || fail "E: the lease deadline (3s + 5s TERM grace) took ${e_elapsed}s"
for _ in $(seq 1 50); do free_locks && break; sleep 0.1; done
free_locks || fail "E: both locks must be acquirable once the deadline kill completes"
[ ! -e "$T/e.finished" ] || fail "E: the command ran past the lease deadline"
! pgrep -xf "sleep 59" >/dev/null 2>&1 || fail "E: the command's child survived the deadline kill"
rm -rf "$T/fake/tmp/"macprovider-activation-lease.*

# ---------------------------------------------------------------------------
# C. Lease watchdog.
# ---------------------------------------------------------------------------
rc=0
AA_LEASE_MAX_SECONDS=1 bash -c "$(preamble)"'
trap "exit 71" HUP INT TERM
trap aa_lease_release EXIT
aa_lease_acquire
for _ in 1 2 3 4 5 6 7 8 9 10; do sleep 1; done
exit 0
' 2>"$T/wd.err" || rc=$?
[ "$rc" -eq 71 ] && grep -q "activation lease watchdog: held past 1s" "$T/wd.err" \
  || fail "lease watchdog must TERM the controller past AA_LEASE_MAX_SECONDS (rc=$rc): $(cat "$T/wd.err")"
rc=0; run_publish flock || rc=$?
grep -q "content drift under lock" "$T/pub.err" || fail "watchdog exit must release the lease: $(cat "$T/pub.err")"

# ---------------------------------------------------------------------------
# F. #1693 L0: under the locks, renewal's publish and rollback refuse while a
# pricing transaction journal exists (the lane owns /opt/macprovider/.pricing-txn).
# ---------------------------------------------------------------------------
mkdir -m 0700 "$T/fake/opt/macprovider/.pricing-txn"
rc=0; run_publish flock || rc=$?
[ "$rc" -eq 2 ] && grep -q "pricing transaction journal present; not mutating" "$T/pub.err" \
  || fail "F: renewal publish must refuse under the lock while a pricing journal exists (rc=$rc): $(cat "$T/pub.err")"
[ "$(readlink "$A/current")" = releases/old ] || fail "F: refused renewal mutated current"
rc=0; run_rollback || rc=$?
[ "$rc" -eq 1 ] && grep -q "rollback: pricing transaction journal present; not mutating" "$T/rb.err" \
  || fail "F: renewal rollback must refuse under the lock while a pricing journal exists (rc=$rc): $(cat "$T/rb.err")"
rmdir "$T/fake/opt/macprovider/.pricing-txn"
rc=0; run_publish flock || rc=$?
grep -q "content drift under lock" "$T/pub.err" || fail "F: without a journal renewal must reach its gate: $(cat "$T/pub.err")"

# ---------------------------------------------------------------------------
# G. #1693 E2 V8: never SIGHUP a booting coordinator. This "coordinator" has
# the default SIGHUP disposition, like a real one before its handler exists.
# ---------------------------------------------------------------------------
(python3 -c 'import time; time.sleep(600)' </dev/null >/dev/null 2>&1 & echo "$!" >"$T/booting.pid")
cp "$T/coordinator.pid" "$T/ready.pid"; cp "$T/booting.pid" "$T/coordinator.pid"
touch "$T/fake/coord-booting"
ln -sfn releases/new "$A/current"
rc=0; AA_COORDINATOR_READY_SECONDS=2 run_rollback || rc=$?
kill -0 "$(cat "$T/booting.pid")" 2>/dev/null || fail "G: the rollback SIGHUPed a booting coordinator and killed it"
[ "$rc" -eq 0 ] && grep -q "rollback: coordinator not ready; SIGHUP not sent" "$T/rb.err" \
  || fail "G: the rollback must restore without signalling a booting coordinator (rc=$rc): $(cat "$T/rb.err")"
[ "$(readlink "$A/current")" = releases/old ] || fail "G: the rollback must still restore current"
rc=0; AA_COORDINATOR_READY_SECONDS=2 run_publish flock || rc=$?
kill -0 "$(cat "$T/booting.pid")" 2>/dev/null || fail "G: the publish SIGHUPed a booting coordinator"
[ "$rc" -eq 2 ] && grep -q "still booting" "$T/pub.err" && grep -q "coordinator is not running and ready" "$T/pub.err" \
  || fail "G: publish against a booting coordinator must abort pre-mutation (rc=$rc): $(cat "$T/pub.err")"
touch "$T/fake/coord-stopped"
g_start=$SECONDS; rc=0; AA_COORDINATOR_READY_SECONDS=60 run_publish flock || rc=$?
[ "$rc" -eq 2 ] && grep -q "is not running (ActiveState=inactive)" "$T/pub.err" && [ $((SECONDS - g_start)) -lt 20 ] \
  || fail "G: a stopped coordinator is reported at once, not waited for (rc=$rc): $(cat "$T/pub.err")"
rm -f "$T/fake/coord-booting" "$T/fake/coord-stopped"
kill "$(cat "$T/booting.pid")" 2>/dev/null || true
cp "$T/ready.pid" "$T/coordinator.pid"
rc=0; run_publish flock || rc=$?
grep -q "content drift under lock" "$T/pub.err" || fail "G: a ready coordinator lets renewal reach its gate: $(cat "$T/pub.err")"

printf '[test-autotune-activate] ok: shared activation keeps renew bytes, mutates only through the lease runner, and treats channel loss as lease loss\n'
