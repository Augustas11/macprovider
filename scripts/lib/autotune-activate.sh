# shellcheck shell=bash
# Shared operator-side activation of a signed autotune release on Pearl (#1688).
#
# scripts/renew-autotune-static-feed.sh (weekly freshness restamp) and the
# catalog-content lane activate a release with THIS machinery, not copies:
# ship + sha-verify the lock validator, the .previous-target window writer and
# the catalog-verifier bundle; stage the release under an immutable name; under
# the Pearl deploy locks run a caller gate, apply the retained window, swap
# `current` atomically and SIGHUP; verify evidence; roll back exactly.
#
# Sourced, never executed. bash 3.2. The caller must define log/fatal and SSH
# (plus SSH_OPTS/RSYNC_RSH/PEARL_SSH), and set SCRIPT_DIR, REPO_ROOT,
# REMOTE_AUTOTUNE_DIR, COORDINATOR_UNIT, RELEASE_DIRNAME (its release id
# source) and AA_WORK_DIR (a private local scratch dir).
#
# Caller parameters (only what differs between callers):
#   AA_GATE_SNIPPET     remote shell run under the lock after the current
#                       re-read and before any mutation; it may use $verifier,
#                       $incoming_path, $root and abort_pre_mutation.
#                       Renew: "$AA_GATE_CONTINUITY_CHECK".
#   AA_COVERAGE_POLICY  warn   (renew): report RENEW_COVERAGE_* and publish.
#                       refuse (content lane): abort before mutation on any
#                       uncovered or unknown coverage unless AA_COVERAGE_OVERRIDE=1.
#   AA_LOCK_MODE        flock  (renew): the remote publish/rollback take
#                       `flock -n` on the updater + coordinator-deploy locks.
#                       lease  (content lane): aa_lease_acquire holds those
#                       SAME locks for the whole run in a remote runner, and
#                       every lease-mode Pearl mutation (publish, rollback,
#                       aa_lease_sh) is executed BY that runner as its child,
#                       inheriting the locked descriptors (see aa_lease_run).
#                       Losing the channel is losing the lease: the state is
#                       unknown and nothing is rolled back from another session.
#   evidence hook       aa_post_activation_evidence <fn>; fn returns non-zero
#                       and sets AA_EVIDENCE_FAILURE to roll back.
#   AA_ROLLBACK_WINDOW  optional: the .previous-target a rollback restores
#                       instead of the exact prior window (content lane: keep a
#                       failed release that live providers already adopted).
#                       The caller validates it; empty = exact prior window.
#   AA_ROLLBACK_POST_HOOK optional fn run after the remote rollback returns;
#                       it reads AA_ROLLBACK_RC and AA_ROLLBACK_OUT.
#   AA_COVERAGE_EXPECT  optional (refuse policy + override): sha256 of the
#                       canonical `uncovered` list the operator's override
#                       record describes; the publish aborts pre-mutation when
#                       its own under-lock coverage differs.
#   AA_PRICING_TXN      0 (default) or 1 (lease mode only; #1693 SPEC-023-R018):
#                       the release also replaces the live base coordinator.yaml
#                       rate_card block. The gate snippet must leave the spliced
#                       candidate at $pricing_candidate (macprovider-readable) and
#                       the L2 verdict at $pricing_dir/verdict.json; the publish
#                       journals through /opt/macprovider/coordinator-pricing-recover
#                       before its first mutation, installs the yaml durably,
#                       swaps window + current, re-checks S == candidate, then
#                       HUPs; the rollback restores yaml, current, window from
#                       the journal (compare-and-swap) and re-HUPs.
#
# Interface globals written here: CURRENT_TARGET, ORIG_PREVIOUS_TARGET (the
# window's entries), ORIG_PREVIOUS_TARGET_B64 (the exact .previous-target
# bytes), LOCK_HELPER_DIR, LOCK_HELPER, WINDOW_HELPER, CONTINUITY_VERIFIER,
# REMOTE_TMP, PUBLISH_OUT_FILE, PUBLISH_OUT, AA_LEASE_*.

AA_GATE_SNIPPET="${AA_GATE_SNIPPET:-}"
AA_COVERAGE_POLICY="${AA_COVERAGE_POLICY:-warn}"
AA_COVERAGE_OVERRIDE="${AA_COVERAGE_OVERRIDE:-0}"
AA_LOCK_MODE="${AA_LOCK_MODE:-flock}"
AA_LEASE_MAX_SECONDS="${AA_LEASE_MAX_SECONDS:-1800}"
# Past AA_LEASE_MAX_SECONDS the watchdog TERMs the controller, which may still
# roll back under the lease for AA_LEASE_ROLLBACK_SECONDS. At MAX + ROLLBACK the
# remote runner itself kills any command still running and exits, releasing
# the locks; a controller still waiting AA_LEASE_KILL_GRACE_SECONDS later
# treats the lease as lost.
AA_LEASE_ROLLBACK_SECONDS="${AA_LEASE_ROLLBACK_SECONDS:-300}"
AA_LEASE_KILL_GRACE_SECONDS="${AA_LEASE_KILL_GRACE_SECONDS:-30}"
AA_LEASE_DEADLINE=""
AA_LEASE_HELD=0
AA_LEASE_PID=""
AA_LEASE_WATCHDOG_PID=""
AA_LEASE_DIR=""
AA_LEASE_HOLDER_PID=""
AA_LEASE_SEQ=0
AA_LEASE_LOST=0
AA_COVERAGE_EXPECT=""
AA_EVIDENCE_FAILURE=""
AA_ROLLBACK_WINDOW="${AA_ROLLBACK_WINDOW:-}"
AA_ROLLBACK_POST_HOOK="${AA_ROLLBACK_POST_HOOK:-}"
AA_PRICING_TXN="${AA_PRICING_TXN:-0}"
# #1693 L0: the shared one-writer guard, embedded verbatim into the remote
# publish/rollback so the pricing-journal refusal runs UNDER the locks.
_AA_CONFIG_GUARD_LIB="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)/coordinator-config-guard.sh"
AA_ROLLBACK_RC=""
AA_ROLLBACK_OUT=""

# The freshness gate: the SAME shipped, sha-verified catalog-release.py
# continuity-check as renew's pre-lock guard, re-run under the lock.
# (read -r, not $(cat <<'X'): bash 3.2 folds backslash-newline in a quoted
# heredoc inside command substitution, which would change the remote bytes.)
IFS= read -r -d '' AA_GATE_CONTINUITY_CHECK <<'GATE' || true
# Re-check dates-only continuity under the lock so a coordinator catalog deploy
# that landed after the pre-lock read cannot be overwritten by this restamp.
# Same rules as the pre-lock guard: the shipped, sha-verified continuity-check.
python3 -I "$verifier" continuity-check --incoming "$incoming_path" --live "$root/current" \
  || abort_pre_mutation "content drift under lock; not mutating"
GATE
AA_GATE_CONTINUITY_CHECK="${AA_GATE_CONTINUITY_CHECK%$'\n'}"

# The lease deploy-pearl-vps.sh holds (its "Acquire the Pearl lease" block):
# validate/create the lock files exactly as deploy does, then one remote
# holder keeps flock on the updater lock AND the coordinator-deploy lock until
# the controller closes its FIFO. Renewal, the Pearl updater and a coordinator
# deploy all take these same two locks, so none can mutate while it is held.
IFS= read -r -d '' AA_LEASE_REMOTE_COMMAND <<'LEASE' || true
command -v flock >/dev/null 2>&1 || { echo 'Pearl is missing flock' >&2; exit 127; }
python3 -c '
import os, stat

nofollow = getattr(os, "O_NOFOLLOW", 0)
directory_flags = os.O_RDONLY | os.O_DIRECTORY | nofollow
opt_fd = os.open("/opt", directory_flags)
root_fd = None
global_lock_fd = None
try:
    opt_info = os.fstat(opt_fd)
    if opt_info.st_uid != 0 or opt_info.st_mode & (stat.S_IWGRP | stat.S_IWOTH):
        raise SystemExit("unsafe /opt ownership or permissions")
    try:
        os.mkdir("macprovider", 0o700, dir_fd=opt_fd)
    except FileExistsError:
        pass
    root_fd = os.open("macprovider", directory_flags, dir_fd=opt_fd)
    root_info = os.fstat(root_fd)
    if root_info.st_uid != 0 or root_info.st_mode & (stat.S_IWGRP | stat.S_IWOTH):
        raise SystemExit("unsafe /opt/macprovider ownership or permissions")
    for name in (".coordinator-deploy.lock", ".coordinator-deploy-operation.lock"):
        try:
            fd = os.open(name, os.O_RDWR | os.O_CREAT | os.O_EXCL | nofollow, 0o600, dir_fd=root_fd)
        except FileExistsError:
            fd = os.open(name, os.O_RDWR | nofollow, dir_fd=root_fd)
        try:
            info = os.fstat(fd)
            if (
                not stat.S_ISREG(info.st_mode)
                or info.st_uid != 0
                or info.st_gid != 0
                or stat.S_IMODE(info.st_mode) != 0o600
                or info.st_nlink != 1
            ):
                raise SystemExit("unsafe coordinator deploy lock: " + name)
        finally:
            os.close(fd)
    global_lock_fd = os.open(
        "/run/lock/macprovider-pearl-updater.lock",
        os.O_RDWR | os.O_CREAT | nofollow,
        0o600,
    )
    global_info = os.fstat(global_lock_fd)
    if (
        not stat.S_ISREG(global_info.st_mode)
        or global_info.st_uid != 0
        or global_info.st_gid != 0
        or stat.S_IMODE(global_info.st_mode) != 0o600
        or global_info.st_nlink != 1
    ):
        raise SystemExit("unsafe global Pearl deployment lock")
finally:
    if global_lock_fd is not None:
        os.close(global_lock_fd)
    if root_fd is not None:
        os.close(root_fd)
    os.close(opt_fd)
' || exit $?
# The runner takes both locks on its OWN descriptors 8 (updater lock) and 9
# (coordinator-deploy lock) and executes every lease-mode command as its child,
# so each command inherits the locked descriptors. A flock(2) lock belongs to
# the open file description and stays held while ANY process holding it lives:
# the locks outlive a dead runner until its last running command exits, so no
# deploy, renewal or update can take them while a mutation is in flight.
# Frames on stdin, one per line: RUN <seq> <b64 script> <b64 arg, or - for "">...
# Replies on stdout: RESULT <seq> <rc> <b64 stdout or -> <b64 stderr or -> END.
# A started command runs to completion even if the controller disconnects
# (HUP ignored), but never past the lease deadline (@AA_LEASE_HARD_SECONDS@ s
# after acquisition, on this host's clock): each command runs in its own
# process group, and at the deadline that group is TERMed, then KILLed, and
# reaped; the runner replies LEASE-EXPIRED <seq> then RESULT <seq> 124 and
# exits. EOF on stdin ends the runner and releases the locks.
exec 8</run/lock/macprovider-pearl-updater.lock || exit 1
flock -n 8 || { echo 'Pearl updater lock held' >&2; exit 1; }
exec 9</opt/macprovider/.coordinator-deploy.lock || exit 1
flock -n 9 || { echo 'coordinator deploy lock held' >&2; exit 1; }
work="$(mktemp -d /tmp/macprovider-activation-lease.XXXXXXXX)" || exit 1
trap 'rm -rf "$work"' EXIT
trap '' HUP
set -f
enc() { if [ -s "$1" ]; then base64 < "$1" | tr -d '\n'; else printf -; fi; }
# argv: <deadline epoch> <expired marker> <command...>. The command inherits
# the locked descriptors 8 and 9 in a new session (its own process group).
run_py='import os, signal, subprocess, sys, time
deadline, marker, cmd = int(sys.argv[1]), sys.argv[2], sys.argv[3:]
def expire(p):
    open(marker, "w").close()
    for sig, grace in ((signal.SIGTERM, 5), (signal.SIGKILL, 10)):
        if p is None:
            break
        try:
            os.killpg(p.pid, sig)
        except ProcessLookupError:
            break
        end = time.time() + grace
        while time.time() < end:
            p.poll()
            try:
                os.killpg(p.pid, 0)
            except ProcessLookupError:
                sys.exit(124)
            time.sleep(0.1)
    sys.exit(124)
if time.time() >= deadline:
    expire(None)
p = subprocess.Popen(cmd, start_new_session=True, pass_fds=(8, 9))
try:
    rc = p.wait(timeout=max(0.0, deadline - time.time()))
except subprocess.TimeoutExpired:
    expire(p)
sys.exit(128 - rc if rc < 0 else rc)'
deadline=$(( $(date +%s) + @AA_LEASE_HARD_SECONDS@ ))
printf 'LOCKED %s\n' "$$"
while IFS=' ' read -r verb seq script args; do
  case "$verb" in RUN) ;; *) echo "malformed lease frame" >&2; exit 1 ;; esac
  case "$seq" in ""|*[!0-9]*) echo "malformed lease frame" >&2; exit 1 ;; esac
  set --
  for a in $args; do
    if [ "$a" = - ]; then set -- "$@" ""; else set -- "$@" "$(printf '%s' "$a" | base64 -d)"; fi
  done
  printf '%s' "$script" | base64 -d >"$work/cmd"
  rc=0
  rm -f "$work/expired"
  python3 -I -c "$run_py" "$deadline" "$work/expired" bash "$work/cmd" "$@" </dev/null >"$work/out" 2>"$work/err" || rc=$?
  if [ -e "$work/expired" ]; then
    printf 'lease-expired: command %s stopped at the lease deadline; Pearl state unknown\n' "$seq" >>"$work/err"
    printf 'LEASE-EXPIRED %s\n' "$seq"
    printf 'RESULT %s 124 %s %s END\n' "$seq" "$(enc "$work/out")" "$(enc "$work/err")"
    exit 1
  fi
  printf 'RESULT %s %s %s %s END\n' "$seq" "$rc" "$(enc "$work/out")" "$(enc "$work/err")"
done
LEASE
AA_LEASE_REMOTE_COMMAND="${AA_LEASE_REMOTE_COMMAND%$'\n'}"

aa_check_params() {
  case "$AA_LOCK_MODE" in flock|lease) ;; *) fatal "AA_LOCK_MODE must be flock or lease (got $AA_LOCK_MODE)" ;; esac
  case "$AA_COVERAGE_POLICY" in warn|refuse) ;; *) fatal "AA_COVERAGE_POLICY must be warn or refuse (got $AA_COVERAGE_POLICY)" ;; esac
  case "$AA_COVERAGE_OVERRIDE" in 0|1) ;; *) fatal "AA_COVERAGE_OVERRIDE must be 0 or 1 (got $AA_COVERAGE_OVERRIDE)" ;; esac
  case "$AA_PRICING_TXN" in 0) ;; 1) [ "$AA_LOCK_MODE" = lease ] || fatal "AA_PRICING_TXN=1 requires AA_LOCK_MODE=lease" ;; *) fatal "AA_PRICING_TXN must be 0 or 1 (got $AA_PRICING_TXN)" ;; esac
  [ -n "$AA_GATE_SNIPPET" ] || fatal "AA_GATE_SNIPPET (the under-lock pre-mutation gate) is required"
  [ -n "${AA_WORK_DIR:-}" ] && [ -d "$AA_WORK_DIR" ] || fatal "AA_WORK_DIR must name an existing local directory"
}

# ---------------------------------------------------------------------------
# Lease: hold deploy's Pearl lock set for the whole activation + evidence
# window. Mirrors deploy-pearl-vps.sh: a FIFO-fed remote holder, a 10 s
# acquisition deadline, and a holder watchdog that TERMs this controller if the
# lease is lost before release. AA_LEASE_MAX_SECONDS bounds the lease: past it
# the controller is TERMed too. The caller must `trap 'exit 71' HUP INT TERM`
# and roll back (still under the lease) from its EXIT trap before
# aa_lease_release. Uses local fd 7.
# ---------------------------------------------------------------------------
aa_lease_acquire() {
  [ "$AA_LEASE_HELD" = 0 ] || fatal "activation lease already held"
  case "$AA_LEASE_MAX_SECONDS" in ""|*[!0-9]*) fatal "AA_LEASE_MAX_SECONDS must be a whole number of seconds" ;; esac
  AA_LEASE_DIR="$(umask 077 && mktemp -d -t macprovider-activate-lease.XXXXXXXX)"
  local fifo="$AA_LEASE_DIR/stdin" status="$AA_LEASE_DIR/status" sentinel="$AA_LEASE_DIR/release-requested"
  local controller=$$ lease_wait=0 hard
  case "$AA_LEASE_ROLLBACK_SECONDS$AA_LEASE_KILL_GRACE_SECONDS" in ""|*[!0-9]*) fatal "AA_LEASE_ROLLBACK_SECONDS and AA_LEASE_KILL_GRACE_SECONDS must be whole numbers of seconds" ;; esac
  hard=$((AA_LEASE_MAX_SECONDS + AA_LEASE_ROLLBACK_SECONDS))
  mkfifo -m 600 "$fifo"
  (
    set +e
    SSH "${AA_LEASE_REMOTE_COMMAND//@AA_LEASE_HARD_SECONDS@/$hard}"
    holder_rc=$?
    # Lost after acquisition: stop the controller. A failed acquisition is
    # reported by the wait loop below instead.
    if [ ! -f "$sentinel" ] && grep -Eqx 'LOCKED [0-9]+' "$status" 2>/dev/null; then
      kill -TERM "$controller" 2>/dev/null || true
    fi
    exit "$holder_rc"
  ) <"$fifo" >"$status" 2>&1 &
  AA_LEASE_PID=$!
  exec 7>"$fifo"
  AA_LEASE_HELD=1
  while ! grep -Eqx 'LOCKED [0-9]+' "$status" 2>/dev/null; do
    if ! kill -0 "$AA_LEASE_PID" 2>/dev/null; then
      cat "$status" >&2 || true
      fatal "another coordinator deploy, renewal or Pearl update holds the Pearl lock"
    fi
    lease_wait=$((lease_wait + 1))
    [ "$lease_wait" -lt 100 ] || fatal "timed out acquiring the Pearl deploy lock"
    sleep 0.1
  done
  AA_LEASE_HOLDER_PID="$(sed -n 's/^LOCKED \([0-9][0-9]*\)$/\1/p' "$status" | head -n 1)"
  # Local bound (bash SECONDS) on waiting for any result: the runner's own
  # deadline, which started no earlier than now, plus its kill grace.
  AA_LEASE_DEADLINE=$((SECONDS + hard + AA_LEASE_KILL_GRACE_SECONDS))
  aa_lease_assert_held || fatal "Pearl deploy lock was lost after acquisition"
  if SSH 'test -e /var/lib/macprovider-pearl-updater/tier2-enforcement-transaction.json'; then
    fatal "a Tier-2 enforcement transaction is active"
  fi
  (
    elapsed=0
    while [ -d "$AA_LEASE_DIR" ] && [ ! -f "$sentinel" ]; do
      if [ "$elapsed" -ge "$AA_LEASE_MAX_SECONDS" ]; then
        echo "activation lease watchdog: held past ${AA_LEASE_MAX_SECONDS}s; terminating the controller" >&2
        kill -TERM "$controller" 2>/dev/null || true
        exit 0
      fi
      sleep 1
      elapsed=$((elapsed + 1))
    done
  ) &
  AA_LEASE_WATCHDOG_PID=$!
  log "holding the Pearl deploy lease (updater + coordinator-deploy locks)"
}

aa_lease_assert_held() {
  [ "$AA_LEASE_HELD" = 1 ] && [ "$AA_LEASE_LOST" = 0 ] && [ -n "$AA_LEASE_PID" ] && kill -0 "$AA_LEASE_PID" 2>/dev/null &&
    grep -Eqx 'LOCKED [0-9]+' "$AA_LEASE_DIR/status" 2>/dev/null
}

# True (and latched in AA_LEASE_LOST) once this run's acquired lease runner is
# gone: Pearl state is then unknown to this controller.
aa_lease_lost() {
  [ "$AA_LOCK_MODE" = lease ] || return 1
  [ "$AA_LEASE_LOST" = 1 ] && return 0
  if [ "$AA_LEASE_HELD" = 1 ] && ! aa_lease_assert_held; then
    AA_LEASE_LOST=1
    return 0
  fi
  return 1
}

_aa_lease_result() { # <seq>: that command's complete RESULT frame, if any
  grep -E "^RESULT $1 [0-9]+ [A-Za-z0-9+/=-]+ [A-Za-z0-9+/=-]+ END\$" "$AA_LEASE_DIR/status" 2>/dev/null | head -n 1
}

# aa_lease_run <script> <stdout-file> <stderr-file> [args...]: execute the
# script on Pearl as a child of the lease runner (inheriting the locked
# descriptors) and return its exit status. If the channel is lost before the
# result arrives, the runner stopped the command at the lease deadline, or no
# result arrives by the local lease deadline, AA_LEASE_LOST=1 and it returns 1:
# whether the command ran, and how far, is unknown.
aa_lease_run() {
  local script="$1" out="$2" err="$3" frame a seq result
  shift 3
  : >"$out"
  : >"$err"
  if ! aa_lease_assert_held; then
    AA_LEASE_LOST=1
    echo "activation lease lost; command not sent" >"$err"
    return 1
  fi
  AA_LEASE_SEQ=$((AA_LEASE_SEQ + 1))
  seq="$AA_LEASE_SEQ"
  frame="RUN $seq $(base64 <"$script" | tr -d '\n')"
  for a in "$@"; do
    if [ -z "$a" ]; then frame="$frame -"; else frame="$frame $(printf '%s' "$a" | base64 | tr -d '\n')"; fi
  done
  # A subshell: a closed channel's SIGPIPE must not kill the controller.
  if ! ( printf '%s\n' "$frame" >&7 ) 2>/dev/null; then
    AA_LEASE_LOST=1
    echo "activation lease channel closed; command $seq not delivered" >"$err"
    return 1
  fi
  while :; do
    result="$(_aa_lease_result "$seq")"
    [ -z "$result" ] || break
    if ! kill -0 "$AA_LEASE_PID" 2>/dev/null; then
      result="$(_aa_lease_result "$seq")"
      [ -z "$result" ] || break
      AA_LEASE_LOST=1
      echo "activation lease lost before command $seq returned; Pearl state unknown" >"$err"
      return 1
    fi
    if [ "$SECONDS" -ge "$AA_LEASE_DEADLINE" ]; then
      AA_LEASE_LOST=1
      echo "activation lease deadline passed before command $seq returned; Pearl state unknown" >"$err"
      return 1
    fi
    sleep 0.1
  done
  # shellcheck disable=SC2086
  set -- $result
  python3 -c 'import base64, sys
for value, path in ((sys.argv[1], sys.argv[2]), (sys.argv[3], sys.argv[4])):
    open(path, "wb").write(b"" if value == "-" else base64.b64decode(value, validate=True))' "$4" "$out" "$5" "$err" \
    || { echo "malformed lease result for command $seq" >"$err"; return 1; }
  if grep -qx "LEASE-EXPIRED $seq" "$AA_LEASE_DIR/status" 2>/dev/null; then
    AA_LEASE_LOST=1
    return 1
  fi
  return "$3"
}

# aa_lease_sh <shell text>: run one Pearl shell command through the lease;
# its stdout/stderr are replayed locally.
aa_lease_sh() {
  local rc=0 base="$AA_WORK_DIR/lease-sh.$((AA_LEASE_SEQ + 1))"
  printf '%s\n' "$1" >"$base.sh"
  aa_lease_run "$base.sh" "$base.out" "$base.err" || rc=$?
  cat "$base.out"
  cat "$base.err" >&2
  return "$rc"
}

# Lease mode, after an interrupted publish: read through the lease (queued
# behind any in-flight command, so it sees the publish's final effect) whether
# this run mutated current or .previous-target.
# 0 = mutated (roll back), 1 = untouched, 2 = unknown.
aa_lease_probe_activation() {
  local probe="$AA_WORK_DIR/probe.remote.sh" cur win
  # shellcheck disable=SC2016
  printf '%s\n' 'set -eu' 'readlink "$1/current"' \
    'if [ -e "$1/.previous-target" ]; then base64 < "$1/.previous-target" | tr -d "\n"; fi' 'echo' \
    'if [ -e /opt/macprovider/.pricing-txn ] || [ -L /opt/macprovider/.pricing-txn ]; then echo PRICING-TXN; fi' >"$probe"
  aa_lease_run "$probe" "$AA_WORK_DIR/probe.out" "$AA_WORK_DIR/probe.err" "$REMOTE_AUTOTUNE_DIR" || return 2
  cur="$(sed -n 1p "$AA_WORK_DIR/probe.out")"
  win="$(sed -n 2p "$AA_WORK_DIR/probe.out")"
  # #1693: a pricing journal means the publish reached its first mutation
  # boundary; the journal-driven rollback restores exactly what changed.
  [ "$AA_PRICING_TXN" != 1 ] || ! grep -qx PRICING-TXN "$AA_WORK_DIR/probe.out" || return 0
  [ "${cur#./}" = "$CURRENT_TARGET" ] && [ "$win" = "${ORIG_PREVIOUS_TARGET_B64:-}" ] && return 1
  return 0
}

aa_lease_release() {
  [ "$AA_LEASE_HELD" = 1 ] || return 0
  touch "$AA_LEASE_DIR/release-requested"
  [ -n "$AA_LEASE_WATCHDOG_PID" ] && kill "$AA_LEASE_WATCHDOG_PID" 2>/dev/null || true
  exec 7>&-
  wait "$AA_LEASE_PID" 2>/dev/null || true
  AA_LEASE_HELD=0
  AA_LEASE_HOLDER_PID=""
  rm -rf "$AA_LEASE_DIR"
}

# ---------------------------------------------------------------------------
# Live state and helper shipping.
# ---------------------------------------------------------------------------

# MED-1 (regression fix): CURRENT_TARGET and ORIG_PREVIOUS_TARGET are read from
# the remote host and later passed through `ssh ... bash -s -- ...`, where the
# remote shell re-parses argv. Validate their shape to exactly
# `releases/<single-segment>` (the coordinator parser's shape) so a crafted
# `current` symlink or `.previous-target` cannot inject remote shell. Empty is
# allowed ONLY for the previous-target.
validate_release_ref() {
  local value="$1" label="$2" allow_empty="$3"
  if [ -z "$value" ]; then
    [ "$allow_empty" = "empty_ok" ] && return 0
    fatal "empty $label"
  fi
  case "$value" in
    releases/*) ;;
    *) fatal "unexpected $label shape (want releases/<id>): $value" ;;
  esac
  local seg="${value#releases/}"
  case "$seg" in
    ""|*[!A-Za-z0-9._-]*) fatal "unsafe $label (single safe segment required): $value" ;;
  esac
}
# Same line rules as scripts/autotune_window.py parse_entries: surrounding
# whitespace stripped, blank and '#' lines skipped, at most 3 entries.
validate_previous_target_window() {
  local value="$1"
  [ -z "$value" ] && return 0
  local n=0 line
  while IFS= read -r line || [ -n "$line" ]; do
    line="${line#"${line%%[![:space:]]*}"}"
    line="${line%"${line##*[![:space:]]}"}"
    case "$line" in ""|'#'*) continue ;; esac
    n=$((n + 1))
    if [ "$n" -gt 3 ]; then
      fatal "previous-target has more than 3 releases"
    fi
    validate_release_ref "$line" "previous-target line" "no_empty"
  done <<EOF
$value
EOF
}

# Capture BOTH the outgoing current target and the existing previous-target, so a
# rollback can restore the exact prior state (MED-2).
aa_read_live_targets() {
  CURRENT_TARGET="$(SSH "readlink '$REMOTE_AUTOTUNE_DIR/current'")" || fatal "cannot read current symlink on $PEARL_SSH"
  CURRENT_TARGET="${CURRENT_TARGET#./}"
  [ -n "$CURRENT_TARGET" ] || fatal "empty current target"
  # Raw bytes (base64) so a rollback restores the file exactly; empty = absent.
  ORIG_PREVIOUS_TARGET_B64="$(SSH "f='$REMOTE_AUTOTUNE_DIR/.previous-target'; if [ -e \"\$f\" ]; then base64 < \"\$f\" | tr -d '\n'; fi")" \
    || fatal "cannot read .previous-target on $PEARL_SSH"
  case "$ORIG_PREVIOUS_TARGET_B64" in *[!A-Za-z0-9+/=]*) fatal "malformed .previous-target encoding from $PEARL_SSH" ;; esac
  ORIG_PREVIOUS_TARGET="$(python3 -c 'import base64,sys;sys.stdout.write(base64.b64decode(sys.argv[1],validate=True).decode("ascii"))' "$ORIG_PREVIOUS_TARGET_B64")" \
    || fatal ".previous-target on $PEARL_SSH is not ASCII"
  ORIG_PREVIOUS_TARGET="${ORIG_PREVIOUS_TARGET%"${ORIG_PREVIOUS_TARGET##*[![:space:]]}"}"
  validate_release_ref "$CURRENT_TARGET" "current target" "no_empty"
  validate_previous_target_window "$ORIG_PREVIOUS_TARGET"
  # Entries only (blank/# lines dropped); the exact bytes stay in _B64.
  ORIG_PREVIOUS_TARGET="$(printf '%s\n' "$ORIG_PREVIOUS_TARGET" | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//' -e '/^#/d' -e '/^$/d')"
}

# Refuse to publish a release id that already exists (idempotency / no clobber).
aa_refuse_existing_release() {
  if SSH "test -e '$REMOTE_AUTOTUNE_DIR/releases/$RELEASE_DIRNAME'"; then
    fatal "release $RELEASE_DIRNAME already exists on $PEARL_SSH; nothing to do (already renewed with this content+timestamp)"
  fi
}

aa_install_helpers() {
  LOCK_HELPER_DIR="$(SSH 'umask 077 && mktemp -d /tmp/macprovider-autotune-lock.XXXXXXXX')" \
    || fatal "cannot create remote lock-helper directory"
  LOCK_HELPER_DIR="${LOCK_HELPER_DIR//$'\n'/}"
  case "$LOCK_HELPER_DIR" in
    /tmp/macprovider-autotune-lock.[A-Za-z0-9]*) ;;
    *) fatal "unsafe LOCK_HELPER_DIR: $LOCK_HELPER_DIR" ;;
  esac
  case "$LOCK_HELPER_DIR" in *[!A-Za-z0-9._/-]*) fatal "unsafe LOCK_HELPER_DIR: $LOCK_HELPER_DIR" ;; esac
  LOCK_HELPER="$LOCK_HELPER_DIR/pearl_autotune_deploy_lock.py"
  log "installing Pearl lock validator"
  SSH "cat >'$LOCK_HELPER' && chown root:root '$LOCK_HELPER' && chmod 0700 '$LOCK_HELPER'" \
    < "$SCRIPT_DIR/pearl_autotune_deploy_lock.py" \
    || fatal "cannot install pearl_autotune_deploy_lock.py on $PEARL_SSH"
  # #1688: scripts/autotune_window.py is the single .previous-target writer.
  WINDOW_HELPER="$LOCK_HELPER_DIR/autotune_window.py"
  log "installing Pearl previous-target window writer"
  SSH "cat >'$WINDOW_HELPER' && chown root:root '$WINDOW_HELPER' && chmod 0700 '$WINDOW_HELPER'" \
    < "$SCRIPT_DIR/autotune_window.py" \
    || fatal "cannot install autotune_window.py on $PEARL_SSH"
  local window_helper_sha remote_window_helper_sha bundle_path remote_bundle_file bundle_sha remote_bundle_sha
  window_helper_sha="$(python3 -c 'import hashlib,sys;print(hashlib.sha256(open(sys.argv[1],"rb").read()).hexdigest())' "$SCRIPT_DIR/autotune_window.py")"
  remote_window_helper_sha="$(SSH "sha256sum '$WINDOW_HELPER'")" || fatal "cannot hash autotune_window.py on $PEARL_SSH"
  [ "${remote_window_helper_sha%% *}" = "$window_helper_sha" ] \
    || fatal "autotune_window.py on $PEARL_SSH does not match the reviewed copy"
  # #1688: the under-lock gate runs the SAME catalog-release.py as the local
  # pre-lock checks, from the dependency-closed verifier bundle, so there is
  # no inline mirror on Pearl to drift out of step.
  log "installing Pearl catalog continuity verifier bundle"
  SSH "mkdir -m 0700 '$LOCK_HELPER_DIR/scripts'" || fatal "cannot create remote verifier bundle directory"
  # Read the manifest on fd 3: ssh reads stdin even when the remote command
  # does not, and would swallow the rest of a manifest fed on stdin.
  while IFS= read -r bundle_path <&3 || [ -n "$bundle_path" ]; do
    case "$bundle_path" in '#'*|'') continue ;; esac
    case "$bundle_path" in
      scripts/.|scripts/..) fatal "invalid catalog verifier bundle entry: $bundle_path" ;;
      scripts/*) ;;
      *) fatal "invalid catalog verifier bundle entry: $bundle_path" ;;
    esac
    case "${bundle_path#scripts/}" in ""|*[!A-Za-z0-9._-]*) fatal "invalid catalog verifier bundle entry: $bundle_path" ;; esac
    remote_bundle_file="$LOCK_HELPER_DIR/$bundle_path"
    SSH "cat >'$remote_bundle_file' && chown root:root '$remote_bundle_file' && chmod 0600 '$remote_bundle_file'" \
      < "$REPO_ROOT/$bundle_path" \
      || fatal "cannot install $bundle_path on $PEARL_SSH"
    bundle_sha="$(python3 -c 'import hashlib,sys;print(hashlib.sha256(open(sys.argv[1],"rb").read()).hexdigest())' "$REPO_ROOT/$bundle_path")"
    remote_bundle_sha="$(SSH "sha256sum '$remote_bundle_file'" </dev/null)" || fatal "cannot hash $bundle_path on $PEARL_SSH"
    [ "${remote_bundle_sha%% *}" = "$bundle_sha" ] \
      || fatal "$bundle_path on $PEARL_SSH does not match the reviewed copy"
  done 3< "$SCRIPT_DIR/catalog-verifier-bundle.txt"
  CONTINUITY_VERIFIER="$LOCK_HELPER_DIR/scripts/catalog-release.py"
  SSH "test -f '$CONTINUITY_VERIFIER'" || fatal "catalog verifier bundle must list scripts/catalog-release.py"
}

aa_cleanup_remote_helpers() {
  if [ -n "${LOCK_HELPER_DIR:-}" ]; then
    SSH "rm -rf '$LOCK_HELPER_DIR'" >/dev/null 2>&1 || true
  elif [ -n "${LOCK_HELPER:-}" ]; then
    SSH "rm -f '$LOCK_HELPER'" >/dev/null 2>&1 || true
  fi
}

# Push the new release dir under a staging name first; the remote publish moves
# it into place (immutable releases/<RELEASE_DIRNAME>) under the lock.
aa_upload_release() {
  local stage="$1"
  REMOTE_TMP=".incoming-$RELEASE_DIRNAME.$$"
  log "uploading signed release bytes"
  rsync -e "$RSYNC_RSH" -a --delete \
    "$stage/" "$PEARL_SSH:$REMOTE_AUTOTUNE_DIR/releases/$REMOTE_TMP/" \
    || fatal "rsync failed"
}

# Lease-mode lock proof, rendered into the publish and rollback scripts. They
# run as children of the lease runner and must hold ITS locked descriptors 8
# and 9 (inherited, never reopened): where /proc exists each must be the lock
# file and carry the flock; flock -n on the inherited descriptor fails when it
# is not open, i.e. when the script was not started by the runner.
IFS= read -r -d '' _AA_LEASE_FDS_FN <<'FDS' || true
lease_fds_held() {
  local spec fd path
  for spec in "8:/run/lock/macprovider-pearl-updater.lock" "9:/opt/macprovider/.coordinator-deploy.lock"; do
    fd="${spec%%:*}"; path="${spec#*:}"
    if [ -e "/proc/$$/fdinfo/$fd" ]; then
      [ "$(readlink "/proc/$$/fd/$fd")" = "$path" ] || { echo "descriptor $fd is not $path"; return 1; }
      grep -Eq '^lock:.*FLOCK +ADVISORY +WRITE' "/proc/$$/fdinfo/$fd" || { echo "descriptor $fd holds no flock on $path"; return 1; }
    fi
    flock -n "$fd" 2>/dev/null || { echo "descriptor $fd is not an inherited lease lock on $path"; return 1; }
  done
}
FDS
_AA_LEASE_FDS_FN="${_AA_LEASE_FDS_FN%$'\n'}"

# ---------------------------------------------------------------------------
# Remote scripts. Rendered from fixed pieces; the flock/warn rendering is the
# exact script renew has always sent (golden:
# scripts/tests/fixtures/renew-remote-{publish,rollback}.golden.sh).
# ---------------------------------------------------------------------------
# ccg_refuse_if_pricing_txn verbatim from the shared guard library (its exit
# constants through the end of that function), for the remote script to call
# once it holds the locks. Only the refusal: the remote scripts already hold
# the lock set, so the library's lock-taking function is not embedded.
_aa_config_guard_fns() {
  local fn
  [ -r "$_AA_CONFIG_GUARD_LIB" ] || fatal "missing $_AA_CONFIG_GUARD_LIB"
  # shellcheck disable=SC2016 # awk program, not shell
  fn="$(awk '/^CCG_EX_REFUSED=/{p=1} p{print} p&&/^}$/{exit}' "$_AA_CONFIG_GUARD_LIB")"
  case "$fn" in *"ccg_refuse_if_pricing_txn() {"*) ;; *) fatal "cannot extract ccg_refuse_if_pricing_txn from $_AA_CONFIG_GUARD_LIB" ;; esac
  printf '%s\n' '# ---- from scripts/lib/coordinator-config-guard.sh ----' "$fn" '# ---- end ----'
}

_aa_publish_lock_block() {
  if [ "$AA_LOCK_MODE" = flock ]; then
    cat <<'LOCK'
python3 "$helper" validate || abort_pre_mutation "Pearl deploy lock files failed validation; not mutating"
exec 8</run/lock/macprovider-pearl-updater.lock || abort_pre_mutation "cannot open /run/lock/macprovider-pearl-updater.lock; not mutating"
flock -n 8 || abort_pre_mutation "Pearl updater lock held; not mutating"
exec 9</opt/macprovider/.coordinator-deploy.lock || abort_pre_mutation "cannot open /opt/macprovider/.coordinator-deploy.lock; not mutating"
flock -n 9 || abort_pre_mutation "coordinator deploy lock held; not mutating"
LOCK
  else
    cat <<'LOCK'
python3 "$helper" validate || abort_pre_mutation "Pearl deploy lock files failed validation; not mutating"
# Lease mode: this script runs as a child of the lease runner, which holds both
# locks for the whole activation; it must hold the runner's descriptors.
LOCK
    printf '%s\n' "$_AA_LEASE_FDS_FN"
    cat <<'LOCK'
lease_why="$(lease_fds_held)" || abort_pre_mutation "activation lease locks not inherited ($lease_why); not mutating"
LOCK
  fi
  _aa_config_guard_fns
  cat <<'LOCK'
# #1693 L0: under the locks, refuse while a pricing transaction journal exists
# (a pricing publish creates its own journal only after this point).
ccg_refuse_if_pricing_txn /opt/macprovider/ || abort_pre_mutation "pricing transaction journal present; not mutating"
LOCK
}

_aa_publish_stage_body() {
  cat <<'BODY'
cd "$root/releases"
chown -R root:macprovider "$incoming"
chmod 0750 "$incoming"; chmod 0640 "$incoming"/*
mv "$incoming" "$final"
# #1688 B2: a freshness renewal mints a NEW release_id (SPEC-023 §3.7.8: a
# release_id bound to two feed digest sets is permanently rejected, so a restamp
# cannot keep the live id), and each one takes a retained-window slot. Report
# which advertised releases fall out of the window; never block the renewal.
# The operator key is read from the running coordinator's own environment and
# rides curl --config stdin; it is never echoed, written, or put in argv.
renewal_coverage() {
  local key_env key status poolz check overlay rc=0
  umask 077
  key_env="$(sed -n 's/^[[:space:]]\{1,\}operator_key:[[:space:]]*env:\([A-Za-z_][A-Za-z0-9_]*\)[[:space:]]*\(#.*\)\{0,1\}$/\1/p' /opt/macprovider/coordinator.yaml | head -n 1)"
  [ -n "$key_env" ] || { echo "renewal coverage: auth.operator_key is not an env: reference" >&2; return 10; }
  key="$(tr '\0' '\n' < "/proc/$pid/environ" | sed -n "s/^${key_env}=//p" | head -n 1)"
  [ -n "$key" ] || { echo "renewal coverage: the coordinator process has no $key_env" >&2; return 10; }
  poolz="$(mktemp /tmp/macprovider-renew-poolz.XXXXXXXX)" || return 10
  status="$(printf 'header = "Authorization: Bearer %s"\n' "$key" | curl --config - -sS --noproxy '*' --max-time 10 --max-filesize 16777216 -o "$poolz" -w '%{http_code}' http://127.0.0.1:8444/poolz)" \
    || { key=""; rm -f "$poolz"; echo "renewal coverage: coordinator /poolz is unreachable on Pearl loopback" >&2; return 10; }
  key=""
  [ "$status" = 200 ] || { rm -f "$poolz"; echo "renewal coverage: coordinator /poolz answered HTTP $status" >&2; return 10; }
  # Coverage judges /poolz against exactly what the LIVE coordinator binary
  # admits after this reload: its --validate-autotune-release verdict for the
  # final release with the planned window (retained + restamps via releases/).
  check="$(mktemp -d /tmp/macprovider-renew-window-check.XXXXXXXX)" || { rm -f "$poolz"; return 10; }
  python3 -I "$window" plan --root "$root" --incoming "releases/$final" > "$check/plan.json" \
    && python3 -I -c 'import json, sys; w = json.load(open(sys.argv[1]))["window_after"]; open(sys.argv[2], "w").write("".join(e + "\n" for e in w))' "$check/plan.json" "$check/.previous-target" \
    && ln -s "$root/releases" "$check/releases" \
    && { [ ! -e "$root/.row-continuity-target" ] || install -m 0640 "$root/.row-continuity-target" "$check/.row-continuity-target"; } \
    && chown -R root:macprovider "$check" && chmod 0750 "$check" && chmod 0640 "$check/.previous-target" \
    || { rm -rf "$check"; rm -f "$poolz"; echo "renewal coverage: cannot stage the planned window" >&2; return 10; }
  overlay=""; [ ! -e /etc/macprovider/coordinator.pearl-overlays.yaml ] || overlay="--config-overlay /etc/macprovider/coordinator.pearl-overlays.yaml"
  # shellcheck disable=SC2086
  systemd-run --quiet --wait --pipe --collect -p RuntimeMaxSec=300 -p EnvironmentFile=-/etc/macprovider/coordinator.env -p User=macprovider -p Group=macprovider \
    /opt/macprovider/coordinator --config /opt/macprovider/coordinator.yaml $overlay --validate-autotune-release "$root/releases/$final" \
    --previous-target "$check/.previous-target" </dev/null >"$check/admitted.json" 2>"$check/validate.err" \
    || { tail -n 1 "$check/admitted.json" | head -c 4096 >&2; rm -rf "$check"; rm -f "$poolz"; echo "renewal coverage: live coordinator --validate-autotune-release rejected the release (coverage unknown)" >&2; return 11; }
  python3 -I "$window" coverage --admitted-json "$check/admitted.json" --poolz-json "$poolz" || rc=$?
  rm -rf "$check"; rm -f "$poolz"
  return "$rc"
}
cov_rc=0
cov_json="$(renewal_coverage)" || cov_rc=$?
echo "RENEW_COVERAGE_RC=$cov_rc"
echo "RENEW_COVERAGE_JSON=$cov_json"
BODY
}

aa_render_publish_script() {
  cat <<'HEAD'
set -euo pipefail
root="$1"; incoming="$2"; final="$3"; prev="$4"; unit="$5"; helper="$6"; window="$7"; verifier="$8"
incoming_path="$root/releases/$incoming"
mutated=0
abort_pre_mutation() {
  echo "$1" >&2
  rm -rf "$incoming_path" >/dev/null 2>&1 || true
  exit 2
}
trap 'if [ "$mutated" -eq 1 ]; then exit 1; else rm -rf "$incoming_path" >/dev/null 2>&1 || true; exit 2; fi' ERR
# Resolve the reload target BEFORE mutating anything, so a dead daemon aborts clean.
pid="$(systemctl show -p MainPID --value "$unit")"
[ -n "$pid" ] && [ "$pid" != "0" ] || abort_pre_mutation "coordinator MainPID unavailable; not mutating"
HEAD
  _aa_publish_lock_block
  cat <<'LIVE'
live_current="$(readlink "$root/current")" || abort_pre_mutation "cannot read current under lock"
live_current="${live_current#./}"
[ "$live_current" = "$prev" ] || abort_pre_mutation "current moved under lock ($live_current != $prev); not mutating"
LIVE
  printf '%s\n' "$AA_GATE_SNIPPET"
  if [ "$AA_PRICING_TXN" = 1 ]; then
    # #1693: the coverage dry-load must validate the release against the
    # spliced candidate yaml (the live yaml still has the prior rows) and prove
    # it base-equivalent to the live yaml.
    local stage old new
    stage="$(_aa_publish_stage_body)"
    # shellcheck disable=SC2016 # literal remote shell text
    old='/opt/macprovider/coordinator --config /opt/macprovider/coordinator.yaml $overlay --validate-autotune-release "$root/releases/$final"'
    # shellcheck disable=SC2016 # literal remote shell text
    new='/opt/macprovider/coordinator --config "$pricing_candidate" $overlay --expect-base-equivalent /opt/macprovider/coordinator.yaml --validate-autotune-release "$root/releases/$final"'
    [ "${stage//"$old"/$new}" != "$stage" ] || fatal "cannot render the pricing coverage dry-load"
    printf '%s\n' "${stage//"$old"/$new}"
  else
    _aa_publish_stage_body
  fi
  if [ "$AA_COVERAGE_POLICY" = refuse ]; then
    cat <<'COVERAGE'
# Coverage policy refuse: a release that would strand an advertised catalog
# release, or whose coverage is unknown, aborts before any mutation unless the
# operator logged an override ($9).
if [ "$cov_rc" -ne 0 ] && [ "${9:-0}" != 1 ]; then
  rm -rf "$root/releases/$final" >/dev/null 2>&1 || true
  abort_pre_mutation "window coverage rc=$cov_rc (uncovered or unknown) without a logged override; not mutating"
fi
# An override is bound to the coverage it logged (${10}: sha256 of the canonical
# uncovered list); coverage that moved since the record was written aborts.
if [ "$cov_rc" -ne 0 ] && [ -n "${10:-}" ]; then
  cov_digest="$(printf '%s' "$cov_json" | python3 -c 'import hashlib,json,sys; u=json.load(sys.stdin)["uncovered"]; print(hashlib.sha256(json.dumps(sorted(u, key=lambda x: json.dumps(x, sort_keys=True)), sort_keys=True).encode()).hexdigest())')" || cov_digest=unknown
  if [ "$cov_digest" != "${10}" ]; then
    rm -rf "$root/releases/$final" >/dev/null 2>&1 || true
    abort_pre_mutation "under-lock window coverage differs from the logged override record; not mutating"
  fi
fi
COVERAGE
  fi
  if [ "$AA_PRICING_TXN" = 1 ]; then
    _aa_pricing_publish_body
    return 0
  fi
  cat <<'BODY'
# Persistent autotune metadata starts here. Set mutated before the first write so
# a failure after .previous-target (and before current swap) still rollbacks.
mutated=1
# Prepend the outgoing current onto the retained window (max 3 unique
# releases/). A single-hop overwrite kicks every serve process still
# advertising the hop before last. See docs/reports/2026-09-19-catalog-one-hop-admission-outage.md
python3 -I "$window" plan --root "$root" --incoming "releases/$final"
python3 -I "$window" apply --root "$root" --incoming "releases/$final" --expect-current "$prev"
# Atomic symlink swap: create the new link beside `current`, then rename over.
ln -sfn "releases/$final" "$root/.current.next"
mv -Tf "$root/.current.next" "$root/current"
echo "retargeted current -> releases/$final (previous-target=$prev)"
# SIGHUP the running coordinator: in-process config reload (#1268), NOT a restart.
kill -HUP "$pid"
echo "sent SIGHUP to $unit (pid $pid)"
BODY
}

# #1693 L4/L5: the pricing publish tail. The journal is committed before the
# first mutation; every later step records its phase before it runs.
_aa_pricing_publish_body() {
  cat <<'BODY'
# #1693 SPEC-023-R018 L4/L5. The spliced candidate yaml, the window and the
# release move together; the journal is committed (atomic rename + fsync)
# before the first mutation, each phase is written before its step, and the
# ERR trap (mutated=1) sends the controller to the journal-driven rollback.
ptx=/opt/macprovider/coordinator-pricing-recover
python3 -I "$window" plan --root "$root" --incoming "releases/$final" > "$pricing_dir/plan.json" \
  || { rm -rf "$root/releases/$final"; abort_pre_mutation "cannot plan the retained window; not mutating"; }
python3 -I -c 'import json, sys; w = json.load(open(sys.argv[1]))["window_after"]; open(sys.argv[2], "w").write("".join(e + "\n" for e in w))' \
  "$pricing_dir/plan.json" "$pricing_dir/candidate-window" \
  || { rm -rf "$root/releases/$final"; abort_pre_mutation "cannot render the planned window; not mutating"; }
# Durability: the release bytes and its directory entry before the journal names it.
python3 -I -c 'import os, sys
d = sys.argv[1]
for n in os.listdir(d):
    fd = os.open(os.path.join(d, n), os.O_RDONLY | os.O_NOFOLLOW)
    os.fsync(fd); os.close(fd)
for p in (d, os.path.dirname(d)):
    fd = os.open(p, os.O_RDONLY); os.fsync(fd); os.close(fd)' "$root/releases/$final" \
  || { rm -rf "$root/releases/$final"; abort_pre_mutation "cannot fsync the staged release; not mutating"; }
python3 -I "$ptx" begin --candidate-yaml "$pricing_candidate" --new-current "releases/$final" --prior-current "$prev" \
  --candidate-window "$pricing_dir/candidate-window" --verdict "$pricing_dir/verdict.json" \
  || { rm -rf "$root/releases/$final"; abort_pre_mutation "pricing transaction journal refused; not mutating"; }
mutated=1
python3 -I "$ptx" phase mutating
python3 -I "$ptx" install-candidate
python3 -I "$window" apply --root "$root" --incoming "releases/$final" --expect-current "$prev"
ln -sfn "releases/$final" "$root/.current.next"
mv -Tf "$root/.current.next" "$root/current"
python3 -I -c 'import os, sys; fd = os.open(sys.argv[1], os.O_RDONLY); os.fsync(fd); os.close(fd)' "$root"
echo "retargeted current -> releases/$final (previous-target=$prev)"
# Final pre-signal compare-and-swap: S must be exactly the journal's candidate.
python3 -I "$ptx" check-state candidate
python3 -I "$ptx" phase hup-intent
kill -HUP "$pid"
echo "sent SIGHUP to $unit (pid $pid)"
python3 -I "$ptx" phase verifying
BODY
}

# $1 = flock|lease: how the rollback session relates to the Pearl locks.
aa_render_rollback_script() {
  cat <<'HEAD'
set -euo pipefail
root="$1"; cur="$2"; prev_b64="$3"; unit="$4"; helper="$5"; expected="$6"; window="$7"
# The exact prior .previous-target bytes (base64); restore writes them
# unchanged, and an empty file makes it remove .previous-target.
prior_window="$(dirname "$window")/prior-window"
if [ "$prev_b64" = "__EMPTY__" ]; then : > "$prior_window"; else printf '%s' "$prev_b64" | base64 -d > "$prior_window"; fi
HEAD
  if [ "$1" = flock ]; then
    cat <<'LOCK'
python3 "$helper" validate || { echo "rollback: lock validation failed; not mutating" >&2; exit 1; }
exec 8</run/lock/macprovider-pearl-updater.lock || { echo "rollback: cannot open updater lock; not mutating" >&2; exit 1; }
flock -n 8 || { echo "rollback: Pearl updater lock held; not mutating" >&2; exit 1; }
exec 9</opt/macprovider/.coordinator-deploy.lock || { echo "rollback: cannot open coordinator lock; not mutating" >&2; exit 1; }
flock -n 9 || { echo "rollback: coordinator deploy lock held; not mutating" >&2; exit 1; }
LOCK
    _aa_config_guard_fns
    cat <<'LOCK'
# #1693 L0: a renewal rollback never writes under a pricing transaction journal.
ccg_refuse_if_pricing_txn /opt/macprovider/ || { echo "rollback: pricing transaction journal present; not mutating" >&2; exit 1; }
LOCK
  else
    cat <<'LOCK'
python3 "$helper" validate || { echo "rollback: lock validation failed; not mutating" >&2; exit 1; }
# Lease mode: run by the lease runner; hold its inherited lock descriptors.
LOCK
    printf '%s\n' "$_AA_LEASE_FDS_FN"
    cat <<'LOCK'
lease_why="$(lease_fds_held)" || { echo "rollback: activation lease locks not inherited ($lease_why); not mutating" >&2; exit 1; }
LOCK
  fi
  if [ "$AA_PRICING_TXN" = 1 ]; then
    cat <<'PRICING'
# #1693 L7: restore from the journal (yaml, then current, then window, each by
# compare-and-swap), prove S == prior, then one re-HUP. The controller proves
# the prior pair live before it finalizes the journal.
ptx=/opt/macprovider/coordinator-pricing-recover
# A durable `verified` is terminal: a verified price is never rolled back.
# Validate the on-disk pair against the journal's candidate and finalize it.
ptx_phase="$(python3 -I "$ptx" status | python3 -I -c 'import json,sys; v=json.load(sys.stdin); print(v["phase"] if v else "")')" \
  || { echo "rollback: cannot read the pricing journal phase; not mutating" >&2; exit 1; }
if [ "$ptx_phase" = verified ]; then
  python3 -I "$ptx" finalize candidate \
    || { echo "rollback: pricing journal verified but the candidate did not validate/finalize; journal kept, not rolled back" >&2; exit 1; }
  echo "rollback: pricing journal verified; candidate finalized, not rolled back"
  exit 0
fi
python3 -I "$ptx" phase rolling-back || { echo "rollback: no pricing journal to roll back from; not mutating" >&2; exit 1; }
python3 -I "$ptx" restore-disk || { echo "rollback: pricing restore refused (state differs from the journal); journal kept" >&2; exit 1; }
pid="$(systemctl show -p MainPID --value "$unit")"
[ -n "$pid" ] && [ "$pid" != "0" ] && kill -HUP "$pid" || true
echo "rolled back to $cur"
PRICING
    return 0
  fi
  cat <<'TAIL'
live="$(readlink "$root/current")" || { echo "rollback: cannot read current; not mutating" >&2; exit 1; }
live="${live#./}"
if [ "$live" = "$expected" ]; then
  ln -sfn "$cur" "$root/.current.rollback"
  mv -Tf "$root/.current.rollback" "$root/current"
  window_rc=0
  python3 -I "$window" restore --root "$root" --from-file "$prior_window" --expect-current "$cur" || window_rc=$?
  pid="$(systemctl show -p MainPID --value "$unit")"
  [ -n "$pid" ] && [ "$pid" != "0" ] && kill -HUP "$pid" || true
  [ "$window_rc" -eq 0 ] || { echo "rollback: rolled back current to $cur but .previous-target restore failed" >&2; exit 1; }
  echo "rolled back to $cur"
elif [ "$live" = "$cur" ]; then
  python3 -I "$window" restore --root "$root" --from-file "$prior_window" --expect-current "$cur"
  echo "rollback: restored .previous-target only (current still $cur)"
else
  echo "rollback: current is $live, not $expected; not mutating"
  exit 0
fi
TAIL
}

# Rollback restores the EXACT prior state — current AND .previous-target — then
# re-HUPs. Only call this after this run has swapped `current` (remote exit 1).
# Pre-mutation failures (remote exit 2) must not rollback: that would be the
# first mutation and can clobber an in-flight coordinator deploy. Flock mode
# takes the same Pearl deploy locks; if they are held, skip mutation. Lease
# mode rolls back THROUGH the lease runner; with the lease lost it refuses
# (returns 1, AA_LEASE_LOST=1): the state is unknown and another deploy may
# hold the locks, so no rollback is attempted from a separate session.
aa_rollback() {
  local window="$ORIG_PREVIOUS_TARGET"
  [ -n "$AA_ROLLBACK_WINDOW" ] && window="$AA_ROLLBACK_WINDOW"
  log "ROLLBACK: restoring current -> $CURRENT_TARGET, .previous-target -> ${window:-<none>}, re-HUPing"
  local prev_arg="__EMPTY__" rb_mode=flock rb_script="$AA_WORK_DIR/rollback.remote.sh"
  local rb_args
  if [ -n "$AA_ROLLBACK_WINDOW" ]; then
    prev_arg="$(printf '%s\n' "$AA_ROLLBACK_WINDOW" | base64 | tr -d '\n')"
  elif [ -n "${ORIG_PREVIOUS_TARGET_B64+set}" ]; then
    # The exact bytes aa_read_live_targets captured.
    [ -z "$ORIG_PREVIOUS_TARGET_B64" ] || prev_arg="$ORIG_PREVIOUS_TARGET_B64"
  elif [ -n "$window" ]; then
    prev_arg="$(printf '%s\n' "$window" | base64 | tr -d '\n')"
  fi
  if [ "$AA_LOCK_MODE" = lease ]; then
    if ! aa_lease_assert_held; then
      AA_LEASE_LOST=1
      log "ROLLBACK REFUSED: the activation lease is lost; Pearl state is unknown and is not rolled back from a separate session"
      return 1
    fi
    rb_mode=lease
  fi
  rb_args=("$REMOTE_AUTOTUNE_DIR" "$CURRENT_TARGET" "$prev_arg" "$COORDINATOR_UNIT" "$LOCK_HELPER" "releases/$RELEASE_DIRNAME" "$WINDOW_HELPER")
  AA_ROLLBACK_RC=0
  AA_ROLLBACK_OUT=""
  if aa_render_rollback_script "$rb_mode" > "$rb_script"; then
    if [ "$rb_mode" = lease ]; then
      aa_lease_run "$rb_script" "$AA_WORK_DIR/rollback.out" "$AA_WORK_DIR/rollback.err" "${rb_args[@]}" || AA_ROLLBACK_RC=$?
      AA_ROLLBACK_OUT="$(cat "$AA_WORK_DIR/rollback.out" "$AA_WORK_DIR/rollback.err" 2>/dev/null)"
      [ -z "$AA_ROLLBACK_OUT" ] || printf '%s\n' "$AA_ROLLBACK_OUT"
      if [ "$AA_LEASE_LOST" = 1 ]; then
        log "ROLLBACK OUTCOME UNKNOWN: the activation lease was lost during the rollback"
        return 1
      fi
    else
      AA_ROLLBACK_OUT="$(SSH bash -s -- "${rb_args[@]}" < "$rb_script" 2>&1)" || AA_ROLLBACK_RC=$?
      [ -z "$AA_ROLLBACK_OUT" ] || printf '%s\n' "$AA_ROLLBACK_OUT"
    fi
  else
    AA_ROLLBACK_RC=1
    log "rollback: cannot render the remote rollback"
  fi
  if [ -n "$AA_ROLLBACK_POST_HOOK" ]; then
    "$AA_ROLLBACK_POST_HOOK" || true
  fi
  return 0
}

# Remote publish. Exit 2 = aborted before swapping current (do not rollback).
# Exit 1 = swapped current then failed (rollback under locks).
# The coordinator PID is resolved FIRST so a missing daemon aborts BEFORE any
# mutation (HIGH-2). CURRENT_TARGET already carries the `releases/<id>` prefix,
# so it must NOT be re-prefixed (HIGH-1).
# Hold deploy-pearl-vps.sh locks for the swap window so a coordinator deploy
# cannot clobber `current`. Validate existing lock files; do not create them
# (a 0644 create would fail the coordinator deploy's 0600 root:root check).
# Remote stdout is captured for the RENEW_COVERAGE_* report lines (#1688 B2).
aa_publish() {
  aa_check_params
  local publish_script="$AA_WORK_DIR/publish.remote.sh" publish_rc
  local publish_args=("$REMOTE_AUTOTUNE_DIR" "$REMOTE_TMP" "$RELEASE_DIRNAME" "$CURRENT_TARGET" "$COORDINATOR_UNIT" "$LOCK_HELPER" "$WINDOW_HELPER" "$CONTINUITY_VERIFIER")
  if [ "$AA_LOCK_MODE" = lease ]; then
    aa_lease_assert_held || fatal "activation lease is not held; not publishing"
    # $9 override flag, $10 expected-coverage digest.
    publish_args+=("$AA_COVERAGE_OVERRIDE" "$AA_COVERAGE_EXPECT")
  elif [ "$AA_COVERAGE_POLICY" = refuse ]; then
    publish_args+=("$AA_COVERAGE_OVERRIDE")
  fi
  aa_render_publish_script > "$publish_script" || fatal "cannot render the remote publish"
  PUBLISH_OUT_FILE="$AA_WORK_DIR/publish.out"
  if [ "$AA_LOCK_MODE" = lease ]; then
    publish_rc=0
    aa_lease_run "$publish_script" "$PUBLISH_OUT_FILE" "$AA_WORK_DIR/publish.err" "${publish_args[@]}" || publish_rc=$?
    cat "$AA_WORK_DIR/publish.err" >&2
    [ "$AA_LEASE_LOST" = 0 ] || fatal "activation lease lost while publishing; Pearl state unknown"
  else
    set +e
    SSH bash -s -- "${publish_args[@]}" < "$publish_script" >"$PUBLISH_OUT_FILE"
    publish_rc=$?
    set -e
  fi
  PUBLISH_OUT="$(cat "$PUBLISH_OUT_FILE" 2>/dev/null || true)"
  printf '%s\n' "$PUBLISH_OUT" | grep -v '^RENEW_COVERAGE_' || true
  if [ "$publish_rc" -eq 0 ]; then
    :
  elif [ "$publish_rc" -eq 1 ]; then
    aa_rollback || true
    fatal "remote publish failed after mutating current"
  else
    fatal "remote publish aborted before mutating current (rc=$publish_rc)"
  fi
}

# Post-activation evidence: the caller's hook proves THIS release is live.
# Any failure rolls back exactly, then fails with the hook's message.
aa_post_activation_evidence() {
  local hook="$1"
  AA_EVIDENCE_FAILURE=""
  if ! "$hook"; then
    aa_rollback || true
    fatal "${AA_EVIDENCE_FAILURE:-post-activation evidence failed}"
  fi
}
