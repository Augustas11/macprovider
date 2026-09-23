#!/usr/bin/env bash
# Hermetic tests for scripts/lib/autotune-activate.sh (#1688 C1). No Pearl, no
# root, no real flock(1): a fake ssh runs remote commands locally with the Pearl
# lock/state paths rewritten into a temp root, and a Python flock shim gives
# flock(1) semantics on macOS and Linux.
#
#   A. Executed bytes: renew's aa_publish / aa_rollback send exactly the golden
#      remote scripts and argv renew sent before the lib existed.
#   B. Lease: aa_lease_acquire holds deploy's lock set; while held, renew's
#      remote publish and rollback refuse before mutating, a second lease is
#      refused, and lease-mode scripts proceed only with THIS lease's token.
#      After release the reverse holds. A lease whose holder died while a
#      competing holder took the locks refuses lease-mode mutation.
#   C. Lease watchdog: past AA_LEASE_MAX_SECONDS the controller is TERMed and
#      its EXIT trap releases the locks.
set -euo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"
lib="$root/scripts/lib/autotune-activate.sh"
golden_publish="$root/scripts/tests/fixtures/renew-remote-publish.golden.sh"
golden_rollback="$root/scripts/tests/fixtures/renew-remote-rollback.golden.sh"

T="$(mktemp -d)"
T="$(cd "$T" && pwd -P)"
trap 'pkill -f "$T/" >/dev/null 2>&1 || true; rm -rf "$T"' EXIT
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
rw() {
  sed -e "s#/opt/macprovider/#$AA_FAKE_ROOT/opt/macprovider/#g" \
      -e "s#\"/opt\"#\"$AA_FAKE_ROOT/opt\"#g" \
      -e "s#/run/lock/#$AA_FAKE_ROOT/run/lock/#g" \
      -e "s#/var/lib/macprovider-pearl-updater/#$AA_FAKE_ROOT/var/lib/macprovider-pearl-updater/#g" \
      -e "s#st_uid != 0#st_uid != $AA_FAKE_UID#g" \
      -e "s#st_gid != 0#st_gid != $AA_FAKE_GID#g"
}
cmd="$(printf '%s\n' "$cmd" | rw)"
case "$cmd" in
  "bash -s"*) rw | bash -c "$cmd" ;;
  *) exec bash -c "$cmd" ;;
esac
SSH
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
printf '#!/bin/sh\necho 4242\n' >"$T/bin/systemctl"
chmod 0755 "$T/bin/ssh" "$T/bin/flock" "$T/bin/systemctl"
printf 'import sys\nsys.exit(0)\n' >"$T/lock-validate-ok.py"
printf 'import sys\nsys.exit(1)\n' >"$T/verifier-fails.py"

export PATH="$T/bin:$PATH"
export AA_FAKE_ROOT="$T/fake"
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
assert "flock -n 8 ||" not in s and "flock -n 9 ||" not in s
assert s.index('lease_why="$(lease_owned)" || abort_pre_mutation') < s.index("continuity-check")
assert s.index('lease_token="${10:-}"') < s.index("lease_owned()")
assert s.index('if [ "$cov_rc" -ne 0 ] && [ -n "${11:-}" ]; then') < s.index("mutated=1")
PY

# ---------------------------------------------------------------------------
# B. Lease vs renewal.
# ---------------------------------------------------------------------------
A="$T/fake/opt/macprovider/autotune"
mkdir -p "$A/releases/old" "$A/releases/.incoming-new.1"
ln -s releases/old "$A/current"
# Remote paths are the real Pearl paths; the fake ssh maps them into $T/fake.
publish_args=(/opt/macprovider/autotune .incoming-new.1 new releases/old macprovider-coordinator "$T/lock-validate-ok.py" /nonexistent-window "$T/verifier-fails.py")
run_publish() { # $1 lock mode [$2 lease token]; remote rc + stderr in $T/pub.err
  mkdir -p "$A/releases/.incoming-new.1"
  local extra=()
  [ "$1" = flock ] || extra=(0 "${2:-}" "")
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

mkfifo "$T/lease.ctl"
bash -c "$(preamble)"'
trap "exit 71" HUP INT TERM
trap aa_lease_release EXIT
aa_lease_acquire
echo "$AA_LEASE_TOKEN" >"$1"
read -r _ <"$2"
' _ "$T/lease.state" "$T/lease.ctl" 2>"$T/lease.err" &
lease_pid=$!
for _ in $(seq 1 100); do [ -s "$T/lease.state" ] && break; kill -0 "$lease_pid" 2>/dev/null || break; sleep 0.1; done
[ -s "$T/lease.state" ] || { cat "$T/lease.err" >&2; fail "aa_lease_acquire did not take deploy's lock set"; }

rc=0; run_publish flock || rc=$?
[ "$rc" -eq 2 ] || fail "renewal publish while the lease is held must abort pre-mutation (rc=$rc)"
grep -q "Pearl updater lock held; not mutating" "$T/pub.err" || fail "renewal did not refuse on the held lease: $(cat "$T/pub.err")"
[ "$(readlink "$A/current")" = releases/old ] || fail "renewal mutated current while the lease was held"
[ ! -e "$A/releases/.incoming-new.1" ] || fail "refused renewal left its incoming dir"
[ ! -e "$A/releases/new" ] || fail "refused renewal staged a release"

rc=0; run_rollback || rc=$?
[ "$rc" -eq 1 ] && grep -q "rollback: Pearl updater lock held; not mutating" "$T/rb.err" \
  || fail "renew rollback must refuse while the lease is held (rc=$rc): $(cat "$T/rb.err")"

rc=0; bash -c "$(preamble)"$'\n''aa_lease_acquire' 2>"$T/lease2.err" || rc=$?
[ "$rc" -ne 0 ] && grep -q "holds the Pearl lock" "$T/lease2.err" || fail "a second lease must be refused (rc=$rc): $(cat "$T/lease2.err")"

lease_token="$(cat "$T/lease.state")"
case "$lease_token" in *[!0-9a-f]*|"") fail "lease token is not hex: $lease_token" ;; esac
[ "${#lease_token}" -eq 32 ] || fail "lease token must be 32 hex characters"
rc=0; run_publish lease "$lease_token" || rc=$?
[ "$rc" -eq 2 ] && grep -q "content drift under lock" "$T/pub.err" \
  || fail "lease-mode publish must pass the lock check under the lease and reach the gate (rc=$rc): $(cat "$T/pub.err")"
rc=0; run_publish lease 0123456789abcdef0123456789abcdef || rc=$?
[ "$rc" -eq 2 ] && grep -q "activation lease not held by this session (lease record belongs to another session)" "$T/pub.err" \
  || fail "lease-mode publish with another session's token must refuse (rc=$rc): $(cat "$T/pub.err")"
rc=0; run_publish lease "" || rc=$?
[ "$rc" -eq 2 ] && grep -q "activation lease not held by this session (no lease token presented)" "$T/pub.err" \
  || fail "lease-mode publish without a token must refuse (rc=$rc): $(cat "$T/pub.err")"
rc=0
bash -c "$(preamble)"'
aa_render_rollback_script lease | SSH bash -s -- "$1" releases/old __EMPTY__ macprovider-coordinator "$2" releases/new "$3" 0123456789abcdef0123456789abcdef
' _ /opt/macprovider/autotune "$T/lock-validate-ok.py" "$T/rbwin/autotune_window.py" >/dev/null 2>"$T/rb.err" || rc=$?
[ "$rc" -eq 1 ] && grep -q "rollback: activation lease not held by this session (lease record belongs to another session)" "$T/rb.err" \
  || fail "lease-mode rollback with another session's token must refuse (rc=$rc): $(cat "$T/rb.err")"
[ "$(readlink "$A/current")" = releases/old ] || fail "refused lease-mode rollback mutated current"

printf 'release\n' >"$T/lease.ctl"
wait "$lease_pid" || fail "lease controller failed: $(cat "$T/lease.err")"

rc=0; run_publish flock || rc=$?
[ "$rc" -eq 2 ] && grep -q "content drift under lock" "$T/pub.err" \
  || fail "after release, renewal must take the locks and reach its gate (rc=$rc): $(cat "$T/pub.err")"
rc=0; run_publish lease "$lease_token" || rc=$?
[ "$rc" -eq 2 ] && grep -q "activation lease not held by this session (lease record missing)" "$T/pub.err" \
  || fail "lease-mode publish after the lease was released must refuse (rc=$rc): $(cat "$T/pub.err")"

# Holder loss: this run's lease holder dies (SIGKILL: its record survives) and a
# competing deploy takes both locks. The locks are busy, the token matches the
# stale record, but the recorded holder PIDs are gone: lease-mode must refuse.
bash -c "$(preamble)"'
trap "exit 71" HUP INT TERM
trap aa_lease_release EXIT
aa_lease_acquire
echo "$AA_LEASE_TOKEN" >"$1"
sleep 30
' _ "$T/lease2.state" 2>"$T/lease3.err" &
lease2_pid=$!
for _ in $(seq 1 100); do [ -s "$T/lease2.state" ] && break; kill -0 "$lease2_pid" 2>/dev/null || break; sleep 0.1; done
[ -s "$T/lease2.state" ] || { cat "$T/lease3.err" >&2; fail "second lease did not start"; }
lease2_token="$(cat "$T/lease2.state")"
cp -p "$T/fake/opt/macprovider/.activation-lease" "$T/stale-lease-record"
pkill -9 -f "flock -n $T/fake/run/lock/macprovider-pearl-updater.lock" || true
pkill -9 -f "flock -n $T/fake/opt/macprovider/.coordinator-deploy.lock" || true
wait "$lease2_pid" 2>/dev/null || true
flock -n "$T/fake/run/lock/macprovider-pearl-updater.lock" flock -n "$T/fake/opt/macprovider/.coordinator-deploy.lock" sleep 30 &
competitor_pid=$!
sleep 0.5
cp -p "$T/stale-lease-record" "$T/fake/opt/macprovider/.activation-lease"
rc=0; run_publish lease "$lease2_token" || rc=$?
[ "$rc" -eq 2 ] && grep -Eq "activation lease not held by this session \(lease holder [0-9]+ is gone\)" "$T/pub.err" \
  || fail "a dead lease holder with a competing lock owner must refuse lease-mode publish (rc=$rc): $(cat "$T/pub.err")"
[ "$(readlink "$A/current")" = releases/old ] || fail "dead-holder refusal mutated current"
rc=0
bash -c "$(preamble)"'
aa_render_rollback_script lease | SSH bash -s -- "$1" releases/old __EMPTY__ macprovider-coordinator "$2" releases/new "$3" "$4"
' _ /opt/macprovider/autotune "$T/lock-validate-ok.py" "$T/rbwin/autotune_window.py" "$lease2_token" >/dev/null 2>"$T/rb.err" || rc=$?
[ "$rc" -eq 1 ] && grep -Eq "rollback: activation lease not held by this session \(lease holder [0-9]+ is gone\)" "$T/rb.err" \
  || fail "a dead lease holder must refuse lease-mode rollback (rc=$rc): $(cat "$T/rb.err")"
kill "$competitor_pid" 2>/dev/null || true
{ wait "$competitor_pid"; } 2>/dev/null || true
pkill -f "flock -n $T/fake/" 2>/dev/null || true
rm -f "$T/fake/opt/macprovider/.activation-lease"
sleep 0.3

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

printf '[test-autotune-activate] ok: shared activation keeps renew bytes and honours the deploy lease\n'
