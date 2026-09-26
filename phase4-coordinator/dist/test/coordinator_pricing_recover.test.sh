#!/usr/bin/env bash
# Hermetic tests for phase4-coordinator/dist/coordinator-pricing-recover
# (#1693 L4/L4b/L7): the pricing transaction journal, compare-and-swap
# restore, pre-start recovery at every crash point of the forward sequence,
# the post-start closer's boot binding, operator recovery (including a lost
# applied-config record write), and deploy-recover's pre-start guard.
# No root: every path is redirected into a temp root through the helper's
# MACPROVIDER_* environment, and a stub coordinator writes the applied-config
# record and serves the rate card on loopback.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd -P)"
HELPER="$SCRIPT_DIR/../coordinator-pricing-recover"
DEPLOY_RECOVER="$SCRIPT_DIR/../coordinator-deploy-recover.sh"
REPO_ROOT="$(cd "$SCRIPT_DIR/../../.." && pwd -P)"
T="$(mktemp -d)"
T="$(cd "$T" && pwd -P)"
STUB_PID=""
cleanup() {
  [ -z "$STUB_PID" ] || { kill "$STUB_PID" 2>/dev/null; wait "$STUB_PID" 2>/dev/null; } || true
  rm -rf "$T"
}
trap cleanup EXIT
fail() { printf '[coordinator-pricing-recover test] FAIL: %s\n' "$*" >&2; exit 1; }
note() { printf '[coordinator-pricing-recover test] ok: %s\n' "$*"; }

PORT="$(python3 -c 'import socket;s=socket.socket();s.bind(("127.0.0.1",0));print(s.getsockname()[1]);s.close()')"
export MACPROVIDER_ROOT="$T/opt/macprovider" MACPROVIDER_ETC_ROOT="$T/etc/macprovider" \
  MACPROVIDER_RUN_ROOT="$T/run/macprovider" MACPROVIDER_UPDATER_STATE_ROOT="$T/var/lib/macprovider-pearl-updater" \
  MACPROVIDER_GLOBAL_DEPLOY_LOCK_FILE="$T/run/lock/macprovider-pearl-updater.lock" \
  MACPROVIDER_DEPLOY_LOCK_FILE="$T/opt/macprovider/.coordinator-deploy.lock" \
  MACPROVIDER_SYSTEMCTL="$T/bin/systemctl" MACPROVIDER_COORDINATOR_URL="http://127.0.0.1:$PORT" \
  MACPROVIDER_COORDINATOR_HEALTHZ_URL="http://127.0.0.1:$PORT/healthz" \
  MACPROVIDER_BOOT_ID_FILE="$T/boot_id" MACPROVIDER_REQUIRED_UID="$(id -u)" CTL="$T/ctl" \
  MACPROVIDER_DEPLOY_LOCK_REQUIRED_UID="$(id -u)" \
  MACPROVIDER_DEPLOY_LOCK_REQUIRED_GID="$(python3 -c 'import os,sys;print(os.stat(sys.argv[1]).st_gid)' "$T")"
R="$MACPROVIDER_ROOT"; A="$R/autotune"

mkdir -p "$T/bin" "$CTL"
# systemctl: MainPID, ActiveState and ActiveEnterTimestampMonotonic of the stub
# coordinator; what coordinator-deploy-recover --recover-under-global calls
# (sidecars not installed, daemon-reload, nginx reload). Any start/restart is
# recorded in $CTL/started (the conflict resolution must never start anything).
cat >"$T/bin/systemctl" <<'SH'
#!/bin/sh
case "$*" in
  *"-p MainPID"*) if [ -e "$CTL/main-pid" ]; then cat "$CTL/main-pid"; elif [ -e "$CTL/stopped" ]; then echo 0; else cat "$CTL/pid"; fi ;;
  *"-p ActiveEnterTimestampMonotonic"*) cat "$CTL/active-enter" ;;
  *"-p ActiveState --value macprovider-coordinator") if [ -e "$CTL/active-state" ]; then cat "$CTL/active-state"; elif [ -e "$CTL/stopped" ]; then echo inactive; else echo active; fi ;;
  *"-p LoadState"*) echo not-found ;;
  daemon-reload|"try-reload-or-restart nginx") ;;
  "start --no-block macprovider-pearl-updater-alert@"*) printf '%s\n' "$*" >>"$CTL/alerts" ;;
  start*|restart*) printf '%s\n' "$*" >>"$CTL/started"; exit 1 ;;
  *) exit 1 ;;
esac
SH
chmod 0755 "$T/bin/systemctl"

# Stub coordinator: on start and SIGHUP it "applies" whatever is on disk:
# parity = the yaml's rate row line equals the current release's rate-card
# row; success writes the applied-config record (rate_table_sha256 = sha of
# the yaml row line, signed card = sha of current/rate-card.json) and bumps
# the snapshot counter; a parity reject writes nothing.
cat >"$T/stub.py" <<'PY'
import hashlib, http.server, json, os, signal, socketserver, sys, threading, time
from datetime import datetime, timezone
R, ctl = os.environ["MACPROVIDER_ROOT"], os.environ["CTL"]
run = os.environ["MACPROVIDER_RUN_ROOT"]
state = {"snap": int(open(os.path.join(ctl, "snap")).read()) if os.path.exists(os.path.join(ctl, "snap")) else 1}
def sha(p):
    return hashlib.sha256(open(p, "rb").read()).hexdigest()
def row(text):
    return next(l for l in text.splitlines() if l.startswith("  rate_card: "))
def apply(source):
    y = open(os.path.join(R, "coordinator.yaml")).read()
    card = os.path.join(R, "autotune/current/rate-card.json")
    if row(y)[len("  rate_card: "):] != json.load(open(card))["row"] or os.path.exists(os.path.join(ctl, "reject")):
        return
    state["snap"] += 1
    open(os.path.join(ctl, "snap"), "w").write(str(state["snap"]))
    if os.path.exists(os.path.join(ctl, "no-record")):
        return
    rec = {"schema": "macprovider.coordinator-applied-config.v1", "config_path": "/opt/macprovider/coordinator.yaml",
           "config_sha256": sha(os.path.join(R, "coordinator.yaml")), "overlay_path": "", "overlay_sha256": "",
           "loaded_at": datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%S.%fZ"), "source": source,
           "version": "stub", "rate_table_sha256": hashlib.sha256(row(y).encode()).hexdigest(),
           "signed_rate_card_sha256": sha(card), "autotune_release_id": "x", "billing_snapshot_id": state["snap"]}
    os.makedirs(run, exist_ok=True)
    open(os.path.join(run, ".r"), "w").write(json.dumps(rec) + "\n")
    os.replace(os.path.join(run, ".r"), os.path.join(run, "coordinator-applied-config.json"))
    state["served"] = {n: open(os.path.join(R, "autotune/current", n), "rb").read() for n in ("rate-card.json", "rate-card.json.sig")}
class H(http.server.BaseHTTPRequestHandler):
    def log_message(self, *a): pass
    def do_GET(self):
        if self.path == "/healthz":  # the real coordinator answers only once its SIGHUP handler is installed
            self.send_response(200 if state.get("ready") else 503); self.end_headers(); return
        name = {"/v1/rate-card": "rate-card.json", "/v1/rate-card.sig": "rate-card.json.sig"}.get(self.path)
        body = state.get("served", {}).get(name)
        if body is None:
            self.send_response(404); self.end_headers(); return
        self.send_response(200); self.send_header("Content-Length", str(len(body))); self.end_headers(); self.wfile.write(body)
class S(socketserver.ThreadingMixIn, http.server.HTTPServer):
    daemon_threads = True
    allow_reuse_address = True
threading.Thread(target=S(("127.0.0.1", int(sys.argv[1])), H).serve_forever, daemon=True).start()
open(os.path.join(ctl, "active-enter"), "w").write(str(int(time.clock_gettime(time.CLOCK_MONOTONIC) * 1e6)))
delay = os.path.join(ctl, "boot-delay")
if os.path.exists(delay):
    # A slow boot: MainPID exists, /healthz does not answer, and (like a
    # coordinator before its handler is installed) a SIGHUP kills the process.
    open(os.path.join(ctl, "pid"), "w").write(str(os.getpid()))
    time.sleep(float(open(delay).read()))
apply("boot")
signal.signal(signal.SIGHUP, lambda *_: apply("sighup"))
state["ready"] = True
open(os.path.join(ctl, "pid"), "w").write(str(os.getpid()))
while True:
    time.sleep(0.2)
PY

start_coordinator() { # boot: a fresh process applies the on-disk pair
  [ -z "$STUB_PID" ] || { kill "$STUB_PID" 2>/dev/null; wait "$STUB_PID" 2>/dev/null || true; STUB_PID=""; }
  rm -f "$CTL/pid" "$CTL/stopped"
  python3 "$T/stub.py" "$PORT" >"$T/stub.log" 2>&1 &
  STUB_PID=$!
  for _ in $(seq 1 100); do [ -s "$CTL/pid" ] && break; sleep 0.05; done
  [ -s "$CTL/pid" ] || fail "stub coordinator did not start: $(cat "$T/stub.log")"
  sleep 0.1
}
stop_coordinator() {
  [ -z "$STUB_PID" ] || { kill "$STUB_PID" 2>/dev/null; wait "$STUB_PID" 2>/dev/null || true; STUB_PID=""; }
  touch "$CTL/stopped"
}

h() { python3 -I "$HELPER" "$@"; }
sha() { shasum -a 256 "$1" | cut -d' ' -f1; }

# One Pearl: prior pair (yaml row A + release old), a staged candidate
# release new (row B) and the candidate yaml (row B), window prev.
setup() {
  stop_coordinator
  rm -rf "$T/opt" "$T/etc" "$T/run" "$T/var" "$T/stage" "$CTL"/*
  mkdir -p "$A/releases/old" "$A/releases/new" "$A/releases/prev" "$MACPROVIDER_ETC_ROOT" \
    "$T/run/lock" "$MACPROVIDER_UPDATER_STATE_ROOT" "$T/stage"
  chmod 0755 "$T/opt" "$R" "$A" "$A/releases"
  for rel in old new prev; do
    row=A; [ "$rel" = new ] && row=B
    printf '{"row": "%s", "release": "%s"}\n' "$row" "$rel" >"$A/releases/$rel/rate-card.json"
    printf 'sig-%s\n' "$rel" >"$A/releases/$rel/rate-card.json.sig"
    printf '{"release_id": "%s"}\n' "$rel" >"$A/releases/$rel/release.json"
    chmod 0750 "$A/releases/$rel"
  done
  printf 'auth:\n  operator_key: env:OPERATOR_KEY\n# keep me\nrewards:\n  rate_card: A\n' >"$R/coordinator.yaml"
  chmod 0640 "$R/coordinator.yaml"
  sed 's/rate_card: A/rate_card: B/' "$R/coordinator.yaml" >"$T/stage/candidate.yaml"
  ln -s releases/old "$A/current"
  printf 'releases/prev\n' >"$A/.previous-target"; chmod 0640 "$A/.previous-target"
  printf 'releases/old\nreleases/prev\n' >"$T/stage/window"
  cp "$REPO_ROOT/phase4-coordinator/dist/coordinator.yaml" "$T/stage/trust-root.yaml"
  echo boot-1 >"$T/boot_id"
  start_coordinator
  PRIOR_YAML="$(sha "$R/coordinator.yaml")"; PRIOR_WINDOW="$(sha "$A/.previous-target")"
  local rec="$MACPROVIDER_RUN_ROOT/coordinator-applied-config.json"
  python3 - "$rec" "$T/stage/candidate.yaml" "$A/releases/new/rate-card.json" "$T/stage/verdict.json" "$PRIOR_YAML" <<'PY'
import hashlib, json, sys
rec = json.load(open(sys.argv[1]))
cand = open(sys.argv[2], "rb").read()
row = next(l for l in cand.decode().splitlines() if l.startswith("  rate_card: "))
json.dump({"pricing_diff_sha256": "1" * 64, "candidate_config_sha256": hashlib.sha256(cand).hexdigest(),
           "commit_block_sha256": "2" * 64, "expected_rate_table_sha256": hashlib.sha256(row.encode()).hexdigest(),
           "expected_signed_rate_card_sha256": hashlib.sha256(open(sys.argv[3], "rb").read()).hexdigest(),
           "prior_rate_table_sha256": rec["rate_table_sha256"], "prior_signed_rate_card_sha256": rec["signed_rate_card_sha256"],
           "prior_config_sha256": sys.argv[5], "prior_billing_snapshot_id": rec["billing_snapshot_id"],
           "overlay_sha256": "", "runtime_floor_commit": "c" * 40}, open(sys.argv[4], "w"))
PY
}
begin() {
  h begin --candidate-yaml "$T/stage/candidate.yaml" --new-current releases/new --prior-current releases/old \
    --candidate-window "$T/stage/window" --verdict "$T/stage/verdict.json" --tier2-trust-root "$T/stage/trust-root.yaml" >/dev/null
}
# The window helper (scripts/autotune_window.py) installs the window 0640.
swap_window() { cp "$T/stage/window" "$A/.pw.tmp"; chmod 0640 "$A/.pw.tmp"; mv "$A/.pw.tmp" "$A/.previous-target"; }
swap_current() { ln -s releases/new "$A/.c.tmp"; if mv --version >/dev/null 2>&1; then mv -Tf "$A/.c.tmp" "$A/current"; else mv -hf "$A/.c.tmp" "$A/current"; fi; }
prior_on_disk() { # <label>
  [ "$(sha "$R/coordinator.yaml")" = "$PRIOR_YAML" ] || fail "$1: yaml not prior"
  [ "$(readlink "$A/current")" = releases/old ] || fail "$1: current not prior ($(readlink "$A/current"))"
  [ "$(sha "$A/.previous-target")" = "$PRIOR_WINDOW" ] || fail "$1: window not prior"
  grep -q '# keep me' "$R/coordinator.yaml" || fail "$1: yaml bytes not restored exactly"
}
mode_of() { stat -c '%a' "$1" 2>/dev/null || stat -f '%Lp' "$1"; }
phase() { python3 -c 'import json,sys;print(json.load(open(sys.argv[1]))["phase"])' "$R/.pricing-txn/txn.json"; }

# ---------------------------------------------------------------------------
# Forward sequence + terminal finalize.
# ---------------------------------------------------------------------------
setup
begin
[ -d "$R/.pricing-txn" ] && [ "$(mode_of "$R/.pricing-txn")" = 700 ] || fail "journal must be a 0700 directory"
[ "$(phase)" = prepared ] || fail "new journal must be prepared"
for f in prior-coordinator.yaml candidate-coordinator.yaml prior-window candidate-window txn.json; do
  [ -f "$R/.pricing-txn/$f" ] || fail "journal lacks $f"
done
rc=0; begin 2>"$T/err" || rc=$?
[ "$rc" = 1 ] && grep -q 'journal present' "$T/err" || fail "a second begin must refuse while a journal exists (rc=$rc)"
h phase mutating
h install-candidate
[ "$(sha "$R/coordinator.yaml")" = "$(sha "$T/stage/candidate.yaml")" ] || fail "candidate yaml not installed"
[ "$(mode_of "$R/coordinator.yaml")" = 640 ] || fail "installed yaml must keep the prior mode 0640 (got $(mode_of "$R/coordinator.yaml"))"
swap_window; swap_current
h check-state candidate || fail "S must equal the candidate after the forward publish"
h phase hup-intent
since="$(python3 -c 'import time;print(time.time())')"
kill -HUP "$(cat "$CTL/pid")"
h phase verifying
h verify-live candidate --since "$since" --source sighup --wait-seconds 5 || fail "candidate must be proven live"
h phase verified
h finalize candidate
[ ! -e "$R/.pricing-txn" ] || fail "finalize must remove the journal"
[ -z "$(ls -a "$R" | grep '^\.pricing-txn' || true)" ] || fail "finalize left journal leftovers"
note "forward sequence journals, installs 0640 yaml durably, verifies and finalizes"

# ---------------------------------------------------------------------------
# Reboot at every point of the forward sequence: pre-start restores the exact
# prior pair (or finds nothing to do), the coordinator boots on it, and the
# closer finalizes from the boot record.
# ---------------------------------------------------------------------------
forward_until() { # <n>: run the first n steps
  local i=0
  for step in begin "h phase mutating" "h install-candidate" swap_window swap_current "h phase hup-intent" hup "h phase verifying"; do
    [ "$i" -lt "$1" ] || return 0
    case "$step" in
      begin) begin ;;
      swap_window) swap_window ;;
      swap_current) swap_current ;;
      hup) kill -HUP "$(cat "$CTL/pid")"; sleep 0.3 ;;
      *) $step ;;
    esac
    i=$((i + 1))
  done
}
for n in 1 2 3 4 5 6 7 8; do
  setup
  forward_until "$n"
  stop_coordinator
  echo boot-2 >"$T/boot_id"
  h --pre-start || fail "pre-start after step $n must succeed"
  prior_on_disk "reboot after step $n"
  [ "$(phase)" = restored-unverified ] || fail "reboot after step $n: phase must be restored-unverified, got $(phase)"
  start_coordinator
  h --close-restored --wait-seconds 5 || fail "closer must finalize from the boot record after step $n"
  [ ! -e "$R/.pricing-txn" ] || fail "closer left the journal after step $n"
done
note "reboot at every forward step: pre-start restores the prior pair, closer finalizes from the boot record"

# A crash while the journal is still being built: the temp dir of a dead
# process is removed and nothing was mutated.
setup
mkdir -m 0700 "$R/.pricing-txn.tmp.999999.12345"
printf 'partial' >"$R/.pricing-txn.tmp.999999.12345/prior-coordinator.yaml"
h --pre-start
[ -e "$R/.pricing-txn.tmp.999999.12345" ] || note "(no journal: pre-start leaves cleanup to the lane)"
h cleanup-tmp
[ ! -e "$R/.pricing-txn.tmp.999999.12345" ] || fail "a dead process's journal temp dir must be removed"
prior_on_disk "crash while building the journal"
h foreign-state >/dev/null || fail "a cleaned Pearl has no foreign pricing state"
note "crash while building the journal: nothing mutated, stale temp dir removed"

# Restart while restored-unverified (the closer never ran): idempotent restore.
setup; forward_until 5; stop_coordinator
h --pre-start
h --pre-start || fail "a second pre-start while restored-unverified must succeed"
[ "$(phase)" = restored-unverified ] || fail "restart while restored-unverified must keep the phase"
prior_on_disk "restart while restored-unverified"
start_coordinator
h --close-restored --wait-seconds 5 || fail "closer after a repeated pre-start"
note "restart while restored-unverified keeps the phase and re-restores idempotently"

# The closer accepts only a coordinator started after the restore in this boot.
setup; forward_until 5
h --pre-start   # coordinator still running from BEFORE the restore
rc=0; h --close-restored --wait-seconds 2 --windows 1 2>"$T/err" || rc=$?
[ "$rc" = 5 ] && grep -q 'has not started since the restore' "$T/err" || fail "closer must refuse a coordinator started before the restore (rc=$rc): $(cat "$T/err")"
[ -e "$R/.pricing-txn" ] || fail "a refused close must keep the journal"
echo boot-3 >"$T/boot_id"; start_coordinator
rc=0; h --close-restored --wait-seconds 2 2>"$T/err" || rc=$?
[ "$rc" = 5 ] && grep -q 'not made in this boot' "$T/err" || fail "closer must refuse a restore from another boot (rc=$rc)"
note "closer binds to boot_id + the coordinator's monotonic start, never wall clock alone"

# A coordinator that boots but rejects the restored pair: the closer fails (alert).
setup; forward_until 5; stop_coordinator; h --pre-start
touch "$CTL/reject"; start_coordinator
rc=0; h --close-restored --wait-seconds 1 --windows 2 2>"$T/err" || rc=$?
[ "$rc" = 5 ] || fail "closer without a matching boot record must fail for the alert (rc=$rc)"
[ "$(wc -l <"$CTL/alerts" | tr -d ' ')" = 1 ] || fail "closer must raise the alert after each unproven window but the last (OnFailure covers it)"
[ "$(phase)" = restored-unverified ] || fail "failed close must keep restored-unverified"
note "closer failure (no matching boot record) exits non-zero for OnFailure alerting"

# #1693 E2 V5: a coordinator whose boot takes longer than one wait window (WAL
# recovery after power loss). The closer alerts per window and keeps waiting,
# without holding the lock set, then closes the journal itself.
setup; forward_until 5; stop_coordinator; echo boot-2 >"$T/boot_id"; h --pre-start
printf '3\n' >"$CTL/boot-delay"; rm -f "$CTL/alerts"
start_coordinator
python3 -c 'import fcntl,os,sys,time;fd=os.open(sys.argv[1],os.O_RDWR|os.O_CREAT,0o600);os.chmod(sys.argv[1],0o600)' "$MACPROVIDER_GLOBAL_DEPLOY_LOCK_FILE"
h --close-restored --wait-seconds 1 --windows 10 2>"$T/err" || fail "a slow boot must be waited out and closed: $(cat "$T/err")"
[ ! -e "$R/.pricing-txn" ] || fail "the closer must finalize once the slow boot proves the prior pair"
[ -s "$CTL/alerts" ] || fail "each window that ends unproven must raise the alert"
grep -q 'window 1/10' "$T/err" || fail "the closer must say it keeps waiting: $(cat "$T/err")"
rm -f "$CTL/boot-delay"
note "slow boot: the closer alerts per window, keeps waiting unlocked, and closes the journal itself"

# Terminal phases at pre-start: bytes-only check, then finalize.
setup; forward_until 5; h phase hup-intent; kill -HUP "$(cat "$CTL/pid")"; h phase verifying; h phase verified
stop_coordinator; h --pre-start
[ ! -e "$R/.pricing-txn" ] || fail "pre-start must finalize a verified journal whose disk is the candidate"
[ "$(readlink "$A/current")" = releases/new ] || fail "pre-start must not roll back a verified transaction"
note "pre-start finalizes a verified journal by bytes only"

# Terminal phases are monotonic: out of `verified` (and `rolled-back`) only
# finalize is allowed; `phase rolling-back` and `restore-disk` are refused and
# recovery finalizes the candidate without rolling back.
setup; forward_until 5; h phase hup-intent; kill -HUP "$(cat "$CTL/pid")"; h phase verifying; h phase verified
for step in "phase rolling-back" "phase verifying" "phase rolled-back" "restore-disk"; do
  rc=0; h $step 2>"$T/err" || rc=$?
  [ "$rc" = 1 ] && grep -q 'terminal' "$T/err" || fail "$step after verified must be refused (rc=$rc): $(cat "$T/err")"
  [ "$(phase)" = verified ] || fail "$step after verified must not change the phase"
done
h phase verified || fail "re-marking verified must be an idempotent no-op"
[ "$(sha "$R/coordinator.yaml")" = "$(sha "$T/stage/candidate.yaml")" ] || fail "a refused transition must not restore the yaml"
h recover --wait-seconds 2 || fail "recovery of a verified journal must finalize the candidate"
[ ! -e "$R/.pricing-txn" ] && [ "$(readlink "$A/current")" = releases/new ] || fail "recovery must finalize, never roll back, a verified journal"
setup; forward_until 5; h phase rolling-back; h restore-disk; h phase rolled-back
rc=0; h phase rolling-back 2>"$T/err" || rc=$?
[ "$rc" = 1 ] && [ "$(phase)" = rolled-back ] || fail "phase rolling-back after rolled-back must be refused (rc=$rc)"
note "terminal phases are monotonic: only finalize leaves verified / rolled-back"

# CAS refusal: a third-party yaml edit during the transaction blocks start.
setup; forward_until 3; printf '# foreign edit\n' >>"$R/coordinator.yaml"; stop_coordinator
rc=0; h --pre-start 2>"$T/err" || rc=$?
[ "$rc" = 3 ] && grep -q 'neither the journal' "$T/err" || fail "pre-start must refuse a yaml that is neither prior nor candidate (rc=$rc)"
[ -e "$R/.pricing-txn" ] || fail "CAS refusal must keep the journal"
note "pre-start CAS failure blocks start with the journal kept"

# A held lane lock set means a live holder: pre-start leaves the journal alone.
setup; forward_until 3; stop_coordinator
python3 -c 'import fcntl,os,sys,time;fd=os.open(sys.argv[1],os.O_RDWR|os.O_CREAT,0o600);fcntl.flock(fd,fcntl.LOCK_EX);open(sys.argv[2],"w").close();time.sleep(30)' \
  "$MACPROVIDER_GLOBAL_DEPLOY_LOCK_FILE" "$T/locked" & LOCKER=$!
for _ in $(seq 1 50); do [ -e "$T/locked" ] && break; sleep 0.1; done
h --pre-start
[ "$(phase)" = mutating ] || fail "pre-start must not touch a journal whose lock set is held"
kill "$LOCKER"; wait "$LOCKER" 2>/dev/null || true; rm -f "$T/locked"
note "pre-start skips while a live holder has the lock set"

# An UNSAFE lock (wrong owner, wrong mode, symlink, hard link) fails closed:
# pre-start and the closer exit non-zero (start blocked), journal untouched.
unsafe_lock_case() { # <label> <setup command...>
  local label="$1"; shift
  setup; forward_until 3; stop_coordinator
  rm -f "$MACPROVIDER_GLOBAL_DEPLOY_LOCK_FILE"
  "$@"
  local rc=0
  h --pre-start 2>"$T/err" || rc=$?
  [ "$rc" -ne 0 ] && grep -q 'unsafe coordinator config lock' "$T/err" || fail "pre-start with a $label lock must fail closed (rc=$rc): $(cat "$T/err")"
  [ "$(phase)" = mutating ] || fail "pre-start with a $label lock must not touch the journal"
  [ "$(sha "$R/coordinator.yaml")" = "$(sha "$T/stage/candidate.yaml")" ] || fail "pre-start with a $label lock must not restore"
}
lock_wrong_mode() { touch "$MACPROVIDER_GLOBAL_DEPLOY_LOCK_FILE"; chmod 0644 "$MACPROVIDER_GLOBAL_DEPLOY_LOCK_FILE"; }
lock_symlink() { touch "$T/run/lock/target"; chmod 0600 "$T/run/lock/target"; ln -s "$T/run/lock/target" "$MACPROVIDER_GLOBAL_DEPLOY_LOCK_FILE"; }
lock_hardlink() { touch "$MACPROVIDER_GLOBAL_DEPLOY_LOCK_FILE"; chmod 0600 "$MACPROVIDER_GLOBAL_DEPLOY_LOCK_FILE"; ln "$MACPROVIDER_GLOBAL_DEPLOY_LOCK_FILE" "$T/run/lock/second-link"; }
lock_wrong_owner() { touch "$MACPROVIDER_GLOBAL_DEPLOY_LOCK_FILE"; chmod 0600 "$MACPROVIDER_GLOBAL_DEPLOY_LOCK_FILE"; }
unsafe_lock_case "mode 0644" lock_wrong_mode
unsafe_lock_case "symlinked" lock_symlink
unsafe_lock_case "hard-linked" lock_hardlink
MACPROVIDER_DEPLOY_LOCK_REQUIRED_UID="$(( $(id -u) + 1 ))" unsafe_lock_case "wrong-owner" lock_wrong_owner
# The coordinator-deploy lock is validated too.
setup; forward_until 3; stop_coordinator
touch "$MACPROVIDER_DEPLOY_LOCK_FILE"; chmod 0640 "$MACPROVIDER_DEPLOY_LOCK_FILE"
rc=0; h --pre-start 2>"$T/err" || rc=$?
[ "$rc" -ne 0 ] && grep -q "unsafe coordinator config lock $MACPROVIDER_DEPLOY_LOCK_FILE" "$T/err" || fail "an unsafe deploy lock must fail closed (rc=$rc)"
[ "$(phase)" = mutating ] || fail "an unsafe deploy lock must not touch the journal"
# The closer of a restored-unverified journal fails closed on an unsafe lock.
setup; forward_until 3; stop_coordinator; h --pre-start; start_coordinator
chmod 0644 "$MACPROVIDER_DEPLOY_LOCK_FILE"
rc=0; h --close-restored --lock-wait-seconds 1 --wait-seconds 1 2>"$T/err" || rc=$?
[ "$rc" -ne 0 ] && grep -q 'unsafe coordinator config lock' "$T/err" || fail "the closer with an unsafe lock must fail closed (rc=$rc)"
[ "$(phase)" = restored-unverified ] || fail "the closer with an unsafe lock must not touch the journal"
note "unsafe lock (wrong owner, mode, symlink, hard link; either lock) fails pre-start and the closer closed"

# Parity: the helper's replicated lock validation accepts and rejects exactly
# what the shared guard's acquire_lock does.
python3 - "$HELPER" "$REPO_ROOT/scripts/lib/coordinator_config_guard.py" "$T/parity" <<'PY' || fail "helper lock validation diverges from the shared guard"
import importlib.machinery, importlib.util, os, sys
helper_path, guard_path, d = sys.argv[1:]
def load(name, path):
    loader = importlib.machinery.SourceFileLoader(name, path)
    spec = importlib.util.spec_from_loader(name, loader)
    mod = importlib.util.module_from_spec(spec)
    loader.exec_module(mod)
    return mod
guard = load("guard", guard_path)
os.makedirs(d, exist_ok=True)
gid = os.stat(d).st_gid
def fresh(name):
    p = os.path.join(d, name)
    open(p, "w").close(); os.chmod(p, 0o600)
    return p
cases = {}
cases["ok"] = (fresh("ok"), os.getuid())
cases["absent"] = (os.path.join(d, "absent"), os.getuid())
p = fresh("mode"); os.chmod(p, 0o644); cases["mode"] = (p, os.getuid())
p = fresh("owner"); cases["owner"] = (p, os.getuid() + 1)
t = fresh("target"); os.symlink(t, os.path.join(d, "symlink")); cases["symlink"] = (os.path.join(d, "symlink"), os.getuid())
p = fresh("hard"); os.link(p, os.path.join(d, "hard2")); cases["hardlink"] = (p, os.getuid())
os.mkdir(os.path.join(d, "dir")); cases["directory"] = (os.path.join(d, "dir"), os.getuid())
for name, (path, uid) in cases.items():
    os.environ["MACPROVIDER_DEPLOY_LOCK_REQUIRED_UID"] = str(uid)
    os.environ["MACPROVIDER_DEPLOY_LOCK_REQUIRED_GID"] = str(gid)
    helper = load("helper_" + name, helper_path)
    try:
        os.close(helper.open_lock(path)); h_ok = True
    except helper.Refused:
        h_ok = False
    if name == "absent":
        os.unlink(path)
    try:
        os.close(guard.acquire_lock(path, required_uid=uid, required_gid=gid)); g_ok = True
    except guard.GuardLockError:
        g_ok = False
    assert h_ok == g_ok == (name in ("ok", "absent")), (name, h_ok, g_ok)
PY
note "helper lock validation matches the shared guard (ok, absent, mode, owner, symlink, hard link, directory)"

# ---------------------------------------------------------------------------
# Operator recovery.
# ---------------------------------------------------------------------------
# Lease lost mid-transaction (after the HUP): recover restores, re-HUPs,
# verifies the prior pair live and finalizes.
setup; forward_until 7
h recover --wait-seconds 5 || fail "operator recovery must roll back and finalize"
prior_on_disk "operator recovery"
[ ! -e "$R/.pricing-txn" ] || fail "operator recovery must finalize"
note "operator recovery after a lost lease: restore, re-HUP, prove prior live, finalize"

# The applied-config record write fails after a successful publication:
# recovery still re-HUPs and verifies the served bytes (never trusts it).
setup; forward_until 7; touch "$CTL/no-record"
rc=0; h recover --wait-seconds 2 2>"$T/err" || rc=$?
[ "$rc" = 5 ] && grep -q 'not proven live' "$T/err" || fail "recovery without a fresh record must stop, not finalize (rc=$rc)"
prior_on_disk "recovery with a lost record write"
rm -f "$CTL/no-record"
h recover --wait-seconds 5 || fail "recovery must finalize once the re-HUP writes the record"
[ ! -e "$R/.pricing-txn" ] || fail "recovery did not finalize after the record reappeared"
note "record write failure: recovery re-HUPs and verifies served bytes before finalizing"

# Recovery with the coordinator down: disk restored, restored-unverified,
# the boot + closer finish it.
setup; forward_until 5; stop_coordinator
rc=0; h recover 2>/dev/null || rc=$?
[ "$rc" = 5 ] && [ "$(phase)" = restored-unverified ] || fail "recovery with no coordinator must leave restored-unverified (rc=$rc)"
prior_on_disk "recovery with the coordinator down"
start_coordinator
h recover --wait-seconds 5 || fail "operator recovery must accept the boot record of restored-unverified"
[ ! -e "$R/.pricing-txn" ] || fail "restored-unverified must finalize on a matching boot record"
note "restored-unverified finalized only on a matching boot record"

# #1693 E2 V8: recovery while the coordinator is still booting. A SIGHUP before
# its handler is installed kills it (systemd treats that as a clean exit), so
# the helper must wait for /healthz, never signal a booting coordinator.
setup; forward_until 7
printf '4\n' >"$CTL/boot-delay"; start_coordinator
rc=0; h recover --wait-seconds 2 --ready-seconds 1 2>"$T/err" || rc=$?
[ "$rc" = 4 ] && grep -q 'still booting' "$T/err" && grep -q 'not a foreign write' "$T/err" ||
  fail "recovery against a booting coordinator must stop as not-ready (exit 4), not signal it (rc=$rc): $(cat "$T/err")"
kill -0 "$STUB_PID" 2>/dev/null || fail "the booting coordinator must not have been signalled"
[ -e "$R/.pricing-txn" ] || fail "a not-ready stop keeps the journal"
rc=0; h verify-live prior --since 0 --source sighup --wait-seconds 1 2>"$T/err" || rc=$?
[ "$rc" = 4 ] && ! grep -q 'state mismatch' "$T/err" || fail "verify-live against a booting coordinator is not-ready, never a state mismatch (rc=$rc): $(cat "$T/err")"
h recover --wait-seconds 5 --ready-seconds 20 2>"$T/err" || fail "recovery must wait for readiness, then re-HUP and finalize: $(cat "$T/err")"
kill -0 "$STUB_PID" 2>/dev/null || fail "the coordinator died: it was signalled before it was ready"
[ ! -e "$R/.pricing-txn" ] || fail "recovery after readiness must finalize"
prior_on_disk "recovery after waiting for a booting coordinator"
rm -f "$CTL/boot-delay"
note "recovery never SIGHUPs a booting coordinator: not-ready (exit 4) or waits for /healthz, then re-HUPs"

# #1693 E2 V8 run3: the lane's rollback restored the prior pair, the re-HUP
# found the coordinator stopped, and its controlled restart booted longer than
# the lane's readiness budget (the startup ledger scan grows with the day's
# traffic): the lane gave up and the journal stayed `rolling-back`, which no
# closer finishes. hand-to-closer stamps the restore before the restart, so the
# restart's closer finalizes it from the boot record once the coordinator is up.
setup; forward_until 8
h phase rolling-back; h restore-disk; stop_coordinator
rc=0; h hand-to-closer 2>/dev/null || rc=$?
[ "$rc" = 0 ] && [ "$(phase)" = restored-unverified ] || fail "hand-to-closer must stamp restored-unverified (rc=$rc)"
python3 -c 'import json,sys;r=json.load(open(sys.argv[1]))["restore"];assert r["boot_id"]=="boot-1" and r["nonce"] and r["monotonic_us"]>0' \
  "$R/.pricing-txn/txn.json" || fail "hand-to-closer must record the restore stamp (boot_id, nonce, monotonic)"
printf '3\n' >"$CTL/boot-delay"; start_coordinator
h --close-restored --wait-seconds 1 --windows 10 2>"$T/err" || fail "the closer must finalize the handed-over journal after a slow boot: $(cat "$T/err")"
grep -q 'window 1/10' "$T/err" || fail "the slow boot must outlast at least one closer window"
[ ! -e "$R/.pricing-txn" ] || fail "the closer must finalize the handed-over journal"
prior_on_disk "hand-to-closer + slow boot"
rm -f "$CTL/boot-delay"
# Only out of rolling-back, and only with the exact prior pair on disk.
setup; forward_until 8
rc=0; h hand-to-closer 2>"$T/err" || rc=$?
[ "$rc" = 1 ] && [ "$(phase)" = verifying ] || fail "hand-to-closer must refuse a journal that is not rolling-back (rc=$rc)"
h phase rolling-back
rc=0; h hand-to-closer 2>"$T/err" || rc=$?
[ "$rc" = 3 ] && [ "$(phase)" = rolling-back ] || fail "hand-to-closer must refuse while the candidate pair is on disk (rc=$rc): $(cat "$T/err")"
# The lane finalized the handed-over journal itself while still holding its
# lease: the closer has nothing left to close (no spurious OnFailure alert).
setup; forward_until 8; h phase rolling-back; h restore-disk; h hand-to-closer 2>/dev/null
stop_coordinator; start_coordinator
[ -e "$MACPROVIDER_GLOBAL_DEPLOY_LOCK_FILE" ] || { : >"$MACPROVIDER_GLOBAL_DEPLOY_LOCK_FILE"; chmod 0600 "$MACPROVIDER_GLOBAL_DEPLOY_LOCK_FILE"; }
exec 8<"$MACPROVIDER_GLOBAL_DEPLOY_LOCK_FILE"; python3 -c 'import fcntl;fcntl.flock(8,fcntl.LOCK_EX)'
( sleep 1; h phase rolled-back; h finalize prior ) 2>/dev/null &
lane_pid=$!
rc=0; h --close-restored --wait-seconds 5 --lock-wait-seconds 3 2>"$T/err" || rc=$?
wait "$lane_pid"
exec 8<&-
[ "$rc" = 0 ] || fail "the closer must exit 0 when the lane already finalized the journal (rc=$rc): $(cat "$T/err")"
[ ! -e "$R/.pricing-txn" ] || fail "the lane's finalize must have removed the journal"
note "hand-to-closer: a controlled restart that outlasts the lane's budget is finalized by the closer"

# ---------------------------------------------------------------------------
# deploy-recover --pre-start and the shared guard.
# ---------------------------------------------------------------------------
GUARD_LIB="$REPO_ROOT/scripts/lib/coordinator-config-guard.sh"
if [ ! -f "$GUARD_LIB" ]; then
  # scripts/lib/coordinator-config-guard.sh (S4) is not in this tree yet; a
  # contract-conforming stand-in keeps this case runnable.
  GUARD_LIB="$T/coordinator-config-guard.sh"
  cat >"$GUARD_LIB" <<'SH'
ccg_refuse_if_pricing_txn() {
  [ -e "$1/.pricing-txn" ] || return 0
  [ "${2:-}" = --pre-start ] && return 76
  echo "refusing: pricing transaction journal present at $1/.pricing-txn; run scripts/catalog-content-release.sh --recover-pricing-txn" >&2
  return 75
}
SH
fi
cat >"$T/bin/flock-free" <<'SH'
#!/bin/sh
exit 0
SH
chmod 0755 "$T/bin/flock-free"
run_deploy_recover() {
  MACPROVIDER_PRICING_GUARD_LIB="$GUARD_LIB" MACPROVIDER_SYSTEMD_ROOT="$T/systemd" \
  MACPROVIDER_FLOCK="$T/bin/flock-free" MACPROVIDER_DEPLOY_OPERATION_LOCK_FILE="$T/op.lock" \
  MACPROVIDER_DEPLOY_LOCK_REQUIRED_UID="$(id -u)" MACPROVIDER_DEPLOY_LOCK_REQUIRED_GID="$(id -g)" \
    sh "$DEPLOY_RECOVER" "$1"
}
setup; forward_until 3; stop_coordinator
touch "$MACPROVIDER_GLOBAL_DEPLOY_LOCK_FILE"; chmod 0600 "$MACPROVIDER_GLOBAL_DEPLOY_LOCK_FILE"
run_deploy_recover --pre-start || fail "deploy-recover --pre-start with only a pricing journal must be a no-op (exit 0)"
[ -e "$R/.pricing-txn" ] || fail "deploy-recover must not touch the pricing journal"
mkdir -p "$R/.coordinator-deploy-rollback"; touch "$R/.coordinator-deploy-rollback/complete"
rc=0; run_deploy_recover --pre-start 2>"$T/err" || rc=$?
[ "$rc" -ne 0 ] && grep -q 'pricing transaction journal' "$T/err" || fail "a deploy marker AND a pricing journal must block start (rc=$rc): $(cat "$T/err")"
[ -d "$R/.coordinator-deploy-rollback" ] || fail "the conflicting deploy snapshot must be preserved"
[ "$(sha "$R/coordinator.yaml")" = "$(sha "$T/stage/candidate.yaml")" ] || fail "deploy-recover conflict must not write coordinator.yaml"
note "deploy-recover --pre-start: pricing journal alone -> no-op; with a deploy marker -> blocked (runbook)"

# ---------------------------------------------------------------------------
# restore_disk preflights the COMPLETE tuple and payloads (CODE-1693-R2-2): a
# foreign member anywhere refuses with every member unchanged.
# ---------------------------------------------------------------------------
tuple_digest() { # yaml sha, current target, window sha (or absent)
  printf '%s %s %s\n' "$(sha "$R/coordinator.yaml")" "$(readlink "$A/current")" \
    "$( [ -e "$A/.previous-target" ] && sha "$A/.previous-target" || echo absent)"
}
foreign_release() {
  mkdir -p "$A/releases/foreign"; printf '{"row": "Z"}\n' >"$A/releases/foreign/rate-card.json"; chmod 0750 "$A/releases/foreign"
  ln -s releases/foreign "$A/.c.tmp"; if mv --version >/dev/null 2>&1; then mv -Tf "$A/.c.tmp" "$A/current"; else mv -hf "$A/.c.tmp" "$A/current"; fi
}
# candidate yaml + foreign current
setup; forward_until 3; foreign_release; before="$(tuple_digest)"
rc=0; h restore-disk 2>"$T/err" || rc=$?
[ "$rc" = 3 ] && grep -q 'nothing changed' "$T/err" || fail "candidate yaml + foreign current must refuse with exit 3 (rc=$rc): $(cat "$T/err")"
[ "$(tuple_digest)" = "$before" ] || fail "candidate yaml + foreign current: a member changed ($before -> $(tuple_digest))"
[ "$(sha "$R/coordinator.yaml")" = "$(sha "$T/stage/candidate.yaml")" ] || fail "the candidate yaml must stay installed"
# candidate yaml + candidate current + foreign window
setup; forward_until 5; printf 'releases/prev\nreleases/foreign\n' >"$A/.previous-target"; before="$(tuple_digest)"
rc=0; h restore-disk 2>"$T/err" || rc=$?
[ "$rc" = 3 ] || fail "candidate yaml/current + foreign window must refuse with exit 3 (rc=$rc): $(cat "$T/err")"
[ "$(tuple_digest)" = "$before" ] || fail "candidate yaml/current + foreign window: a member changed"
[ "$(readlink "$A/current")" = releases/new ] || fail "current must stay the candidate"
# a corrupt prior payload refuses before the first write as well
setup; forward_until 5; before="$(tuple_digest)"; printf 'x' >>"$R/.pricing-txn/prior-window"
rc=0; h restore-disk 2>"$T/err" || rc=$?
[ "$rc" = 5 ] && [ "$(tuple_digest)" = "$before" ] || fail "a corrupt prior-window must stop with every member unchanged (rc=$rc)"
note "restore-disk: foreign current / foreign window / corrupt payload refuse with every member unchanged"

# ---------------------------------------------------------------------------
# Owner/mode are part of S (#1693 E2 finding 3): prior bytes at the wrong mode
# are reinstalled with the journal's owner/mode, never skipped as "prior".
# ---------------------------------------------------------------------------
setup; forward_until 2; chmod 0600 "$R/coordinator.yaml"
rc=0; h check-state prior 2>"$T/err" || rc=$?
[ "$rc" = 3 ] && grep -q 'yaml_meta' "$T/err" || fail "prior bytes at 0600 must not pass as the prior pair (rc=$rc): $(cat "$T/err")"
stop_coordinator; echo boot-2 >"$T/boot_id"
h --pre-start || fail "pre-start must restore a prior yaml at the wrong mode"
[ "$(mode_of "$R/coordinator.yaml")" = 640 ] || fail "pre-start must restore the journal's 0640 (got $(mode_of "$R/coordinator.yaml"))"
prior_on_disk "prior yaml at 0600 -> pre-start"
[ "$(phase)" = restored-unverified ] || fail "pre-start must leave restored-unverified"
start_coordinator; h --close-restored --wait-seconds 5 || fail "the closer must finalize the mode-restored pair"
setup; forward_until 2; chmod 0600 "$A/.previous-target"
h phase rolling-back; h restore-disk || fail "restore-disk must restore a prior window at the wrong mode"
[ "$(mode_of "$A/.previous-target")" = 640 ] && [ "$(sha "$A/.previous-target")" = "$PRIOR_WINDOW" ] ||
  fail "restore-disk must reinstall the prior window with the journal's 0640 (got $(mode_of "$A/.previous-target"))"
h check-state prior || fail "after the restore S must be the prior pair including owner/mode"
setup; forward_until 5; chmod 0644 "$A/.previous-target"
rc=0; h check-state candidate 2>"$T/err" || rc=$?
[ "$rc" = 3 ] && grep -q 'window owner/mode' "$T/err" || fail "a candidate window that is not the window helper's 0640 must fail check-state (rc=$rc)"
setup; forward_until 5; chmod 0600 "$A/releases/old/rate-card.json"; before="$(tuple_digest)"
rc=0; h restore-disk 2>"$T/err" || rc=$?
[ "$rc" = 3 ] && grep -q 'release owner/mode' "$T/err" && [ "$(tuple_digest)" = "$before" ] ||
  fail "a prior release file at another mode must refuse before any write (rc=$rc): $(cat "$T/err")"
note "owner/mode: prior bytes at 0600 are restored to the journal's mode; candidate window and release modes are checked"

# ---------------------------------------------------------------------------
# #1693 E2 V4: finalizing a verified journal runs the REAL verify-directory
# from a shipped verifier bundle (no coordinator.yaml beside it) with the
# journal's pinned Tier-2 trust root, never the verifier's default path.
# ---------------------------------------------------------------------------
BUNDLE="$T/bundle"; rm -rf "$BUNDLE"; mkdir -p "$BUNDLE/scripts"
grep -v '^#' "$REPO_ROOT/scripts/catalog-verifier-bundle.txt" | grep -v '^$' | while read -r f; do cp "$REPO_ROOT/$f" "$BUNDLE/scripts/"; done
[ ! -e "$BUNDLE/phase4-coordinator" ] || fail "the bundle must not carry a coordinator.yaml"
real_release() { # the repo's committed release, assembled as the lane does, as releases/new
  rm -rf "$A/releases/new"; mkdir -p "$A/releases/new"
  for n in release.json trusted-keys.json tier2-catalog.json; do cp "$REPO_ROOT/phase3-binary/catalog/autotune/$n" "$A/releases/new/"; done
  for n in autotune-candidates.json autotune-candidates.json.sig demand-rank.json demand-rank.json.sig rate-card.json rate-card.json.sig; do
    cp "$REPO_ROOT/phase3-binary/dist/static/$n" "$A/releases/new/"
  done
  if grep -q '"autotune-artifacts.json"' "$A/releases/new/release.json"; then
    cp "$REPO_ROOT/phase3-binary/dist/static/autotune-artifacts.json" "$REPO_ROOT/phase3-binary/dist/static/autotune-artifacts.json.sig" "$A/releases/new/"
  fi
  chmod 0750 "$A/releases/new"
}
verified_real() { setup; real_release; forward_until 5; h phase hup-intent; h phase verifying; h phase verified; }
verified_real
rc=0; python3 -I "$BUNDLE/scripts/catalog-release.py" verify-directory --allow-expired-tier2 --directory "$A/releases/new" 2>"$T/err" || rc=$?
[ "$rc" != 0 ] && grep -q 'phase4-coordinator/dist/coordinator.yaml' "$T/err" || fail "the bundle's default trust root must be absent (the E2 condition; rc=$rc): $(cat "$T/err")"
h recover --verifier "$BUNDLE/scripts/catalog-release.py" --wait-seconds 2 2>"$T/err" || fail "recover must finalize a verified journal from a bundle without coordinator.yaml: $(cat "$T/err")"
[ ! -e "$R/.pricing-txn" ] && [ "$(readlink "$A/current")" = releases/new ] || fail "the verified candidate must be finalized, not rolled back"
# A journal whose pinned trust root was altered stops (journal kept).
verified_real; printf '# x\n' >>"$R/.pricing-txn/tier2-trust-root.yaml"
rc=0; h recover --verifier "$BUNDLE/scripts/catalog-release.py" 2>"$T/err" || rc=$?
[ "$rc" = 5 ] && grep -q 'not its pinned sha256' "$T/err" && [ "$(phase)" = verified ] || fail "a tampered journal trust root must stop (rc=$rc): $(cat "$T/err")"
# A journal begun without a trust root: never the default path; the operator's
# sha-pinned copy is used, a wrong sha stops.
verified_real
python3 - "$R/.pricing-txn/txn.json" <<'PY2'
import json, sys
t = json.load(open(sys.argv[1])); del t["tier2_trust_root_sha256"]; json.dump(t, open(sys.argv[1], "w"))
PY2
rm -f "$R/.pricing-txn/tier2-trust-root.yaml"
rc=0; h recover --verifier "$BUNDLE/scripts/catalog-release.py" 2>"$T/err" || rc=$?
[ "$rc" = 5 ] && grep -q 'pins no Tier-2 trust root' "$T/err" && [ "$(phase)" = verified ] || fail "no trust root anywhere must stop (rc=$rc): $(cat "$T/err")"
rc=0; h recover --verifier "$BUNDLE/scripts/catalog-release.py" --tier2-trust-root "$T/stage/trust-root.yaml" --tier2-trust-root-sha256 "$(printf '0%.0s' $(seq 64))" 2>"$T/err" || rc=$?
[ "$rc" = 5 ] && [ "$(phase)" = verified ] || fail "a supplied trust root with the wrong sha must stop (rc=$rc): $(cat "$T/err")"
h recover --verifier "$BUNDLE/scripts/catalog-release.py" --tier2-trust-root "$T/stage/trust-root.yaml" \
  --tier2-trust-root-sha256 "$(sha "$T/stage/trust-root.yaml")" --wait-seconds 2 2>"$T/err" || fail "the supplied sha-pinned trust root must finalize: $(cat "$T/err")"
[ ! -e "$R/.pricing-txn" ] || fail "the verified journal must be finalized"
note "verified journal: the real verify-directory from a bundle without coordinator.yaml uses the journal's pinned trust root"

# ---------------------------------------------------------------------------
# Pricing runtime floor: begin writes it once, durably, and never rewrites it.
# ---------------------------------------------------------------------------
setup; rm -f "$R/.pricing-runtime-floor"; begin
[ -f "$R/.pricing-runtime-floor" ] && grep -qx "commit=$(printf 'c%.0s' $(seq 1 40))" "$R/.pricing-runtime-floor" \
  || fail "begin must write the pricing runtime floor naming the verdict commit"
[ "$(mode_of "$R/.pricing-runtime-floor")" = 644 ] || fail "the floor marker must be 0644"
floor_before="$(cat "$R/.pricing-runtime-floor")"
h phase rolling-back; h restore-disk; h phase rolled-back; h finalize prior
sleep 1; begin
[ "$(cat "$R/.pricing-runtime-floor")" = "$floor_before" ] || fail "a later begin must keep the first floor marker"
h phase rolling-back; h restore-disk; h phase rolled-back; h finalize prior
[ -f "$R/.pricing-runtime-floor" ] || fail "finalize must never remove the floor marker"
python3 - "$T/stage/verdict.json" <<'PY'
import json, sys
v = json.load(open(sys.argv[1])); v["runtime_floor_commit"] = "not-a-commit"; json.dump(v, open(sys.argv[1], "w"))
PY
rc=0; begin 2>"$T/err" || rc=$?
[ "$rc" = 1 ] && grep -q 'runtime_floor_commit' "$T/err" && [ ! -e "$R/.pricing-txn" ] || fail "begin must refuse a verdict without a floor commit (rc=$rc)"
note "begin writes the pricing runtime floor once (0644, commit), before the journal; never removed"

# ---------------------------------------------------------------------------
# Deploy-and-pricing conflict: --resolve-deploy-conflict (CODE-1693-R2-1,
# SEC-M4, ARCH-002).
# ---------------------------------------------------------------------------
SYSD="$T/systemd"
DIST="$SCRIPT_DIR/.."
cat >"$T/bin/coordinator-new" <<'SH'
#!/bin/sh
case "$*" in *--expect-base-equivalent*) echo '{"ok":false,"model_resolutions":[],"errors":["config: probe"]}'; exit 1 ;; esac
exit 0
SH
cat >"$T/bin/coordinator-old" <<'SH'
#!/bin/sh
case "$*" in *--expect-base-equivalent*) echo 'flag provided but not defined: -expect-base-equivalent' >&2; exit 2 ;; esac
exit 0
SH
# nginx -t: probe that the helper's lock set is held while deploy recovery runs
# (flock -n on each lock must fail), optionally hang or fail.
cat >"$T/bin/nginx" <<'SH'
#!/bin/sh
[ "${1:-}" = -t ] || exit 0
python3 -c '
import fcntl, os, sys
out = []
for p in sys.argv[1:]:
    fd = os.open(p, os.O_RDWR)
    try:
        fcntl.flock(fd, fcntl.LOCK_EX | fcntl.LOCK_NB); out.append("free")
    except BlockingIOError:
        out.append("held")
    os.close(fd)
print(" ".join(out))' "$MACPROVIDER_GLOBAL_DEPLOY_LOCK_FILE" "$MACPROVIDER_DEPLOY_LOCK_FILE" >"$CTL/lockprobe"
if [ -e "$CTL/nginx-hang" ]; then touch "$CTL/nginx-waiting"; while :; do sleep 0.1; done; fi
[ ! -e "$CTL/nginx-fail" ]
SH
# setfacl --restore: like GNU setfacl, every "# file:" entry must exist.
cat >"$T/bin/setfacl" <<'SH'
#!/bin/sh
case "$1" in
  --restore=*)
    sed -n 's/^# file: //p' "${1#--restore=}" | while IFS= read -r f; do
      [ -e "$f" ] || { echo "setfacl: $f: No such file or directory" >&2; exit 1; }
    done ;;
esac
SH
chmod 0755 "$T/bin/coordinator-new" "$T/bin/coordinator-old" "$T/bin/nginx" "$T/bin/setfacl"

resolve_env() {
  MACPROVIDER_SYSTEMD_ROOT="$SYSD" MACPROVIDER_NGINX_ROOT="$T/etc/nginx" MACPROVIDER_STATS_ROOT="$T/opt/macprovider-stats" \
    MACPROVIDER_NGINX="$T/bin/nginx" MACPROVIDER_SETFACL="$T/bin/setfacl" MACPROVIDER_PYTHON=python3 \
    MACPROVIDER_DEPLOY_OPERATION_LOCK_FILE="$T/op.lock" "$@"
}
resolve() { resolve_env python3 -I "$HELPER" --resolve-deploy-conflict; }

# One conflict: a journal (forward steps <n>), the coordinator stopped, the
# #1693 pricing machinery installed, and a complete deploy rollback snapshot
# whose (yaml, current, window) are <yaml> <current> <window> (prior|candidate
# each), binary <new|old>.
conflict_setup() { # <n> <yaml> <current> <window> [old]
  setup; forward_until "$1"; stop_coordinator
  rm -rf "$SYSD"; mkdir -p "$SYSD/macprovider-coordinator.service.d"
  cp "$HELPER" "$R/coordinator-pricing-recover"
  cp "$REPO_ROOT/scripts/lib/coordinator-config-guard.sh" "$R/coordinator-config-guard.sh"
  cp "$DIST/systemd/macprovider-coordinator-pricing-close.service" "$DIST/systemd/macprovider-coordinator-deploy-recovery.service" "$SYSD/"
  cp "$DIST/systemd/macprovider-coordinator-deploy-guard.conf" "$SYSD/macprovider-coordinator.service.d/10-deploy-transaction-guard.conf"
  cp "$DEPLOY_RECOVER" "$R/coordinator-deploy-recover"; chmod 0755 "$R/coordinator-deploy-recover"
  cp "$T/bin/coordinator-new" "$R/coordinator"
  local S="$R/.coordinator-deploy-rollback"
  mkdir -p "$S"; chmod 0700 "$S"
  case "$2" in prior) cp "$R/.pricing-txn/prior-coordinator.yaml" "$S/coordinator.yaml" ;; *) cp "$T/stage/candidate.yaml" "$S/coordinator.yaml" ;; esac
  case "$3" in prior) printf 'releases/old' ;; candidate) printf 'releases/new' ;; *) printf 'releases/prev' ;; esac >"$S/catalog-current-target"
  case "$4" in prior) cp "$R/.pricing-txn/prior-window" "$S/catalog-previous-target" ;; *) cp "$T/stage/window" "$S/catalog-previous-target" ;; esac
  # The deploy snapshots the live files with cp -p: their live 0640 modes.
  chmod 0640 "$S/coordinator.yaml" "$S/catalog-previous-target"
  printf 'coordinator.yaml.bak-20260924T000000Z' >"$S/config-backup-name"
  cp "$T/bin/coordinator-${5:-new}" "$S/coordinator"
  cp "$R/coordinator-pricing-recover" "$S/coordinator-pricing-recover"
  cp "$R/coordinator-config-guard.sh" "$S/coordinator-config-guard.sh"
  cp "$SYSD/macprovider-coordinator-pricing-close.service" "$SYSD/macprovider-coordinator-deploy-recovery.service" "$S/"
  cp "$SYSD/macprovider-coordinator.service.d/10-deploy-transaction-guard.conf" "$S/10-deploy-transaction-guard.conf"
  cp "$R/coordinator-deploy-recover" "$S/coordinator-deploy-recover"
  for m in complete had-config had-previous-target had-coordinator had-pricing-recover-helper had-config-guard-lib \
    had-pricing-close-unit had-recovery-unit had-guard-dropin had-recovery-helper stats-billing-timer-was-active; do
    touch "$S/$m"
  done
}
state_digest() { # everything the resolution may change: disk tuple, journal, snapshot, machinery
  { tuple_digest; ls -a "$R" | grep '^\.pricing-txn' || true
    [ -d "$R/.pricing-txn" ] && cat "$R/.pricing-txn/txn.json"
    [ -d "$R/.coordinator-deploy-rollback" ] && (cd "$R/.coordinator-deploy-rollback" && ls && cat coordinator.yaml catalog-current-target)
    shasum -a 256 "$R/coordinator" "$R/coordinator-pricing-recover" "$SYSD"/*.service; } 2>/dev/null | shasum -a 256
}
no_held() { [ -z "$(ls -a "$R" | grep '^\.pricing-txn\.conflict-held\.' || true)" ] || fail "$1: a set-aside journal was left behind"; }
refused_unchanged() { # <label> <expected message>
  local before rc=0; before="$(state_digest)"
  resolve >"$T/out" 2>"$T/err" || rc=$?
  [ "$rc" = 1 ] && grep -q "$2" "$T/err" || fail "$1: must refuse with exit 1 (rc=$rc): $(cat "$T/err")"
  [ "$(state_digest)" = "$before" ] || fail "$1: a refusal changed state"
  [ -d "$R/.pricing-txn" ] && [ -d "$R/.coordinator-deploy-rollback" ] || fail "$1: journal and snapshot must both be kept"
  [ ! -e "$CTL/started" ] || fail "$1: something was started: $(cat "$CTL/started")"
  no_held "$1"
}

# Coherent PRIOR pair (the disk carries the candidate): deploy recovery runs
# under the helper's lock set (no self-deadlock), restores the prior pair, the
# journal comes back for pricing recovery, nothing is started.
conflict_setup 5 prior prior prior
rc=0; resolve >"$T/out" 2>"$T/err" || rc=$?
[ "$rc" = 0 ] || fail "a coherent prior snapshot must resolve (rc=$rc): $(cat "$T/err")"
[ "$(cat "$CTL/lockprobe")" = "held held" ] || fail "deploy recovery must run while the helper holds both locks (got $(cat "$CTL/lockprobe"))"
[ -d "$R/.pricing-txn" ] && [ ! -e "$R/.coordinator-deploy-rollback" ] || fail "prior: journal must be visible and the snapshot consumed"
no_held "prior"; prior_on_disk "resolve prior"
[ ! -e "$CTL/started" ] || fail "the resolution must never start a unit: $(cat "$CTL/started")"
grep -q '"resolved": "prior"' "$T/out" && grep -q 'stats-billing-mirror.timer' "$T/out" || fail "must report the side and the stopped sidecar timers: $(cat "$T/out")"
h --pre-start; [ "$(phase)" = restored-unverified ] || fail "prior: pre-start must take the journal on"
start_coordinator; h --close-restored --wait-seconds 5 || fail "prior: the closer must finalize"
[ ! -e "$R/.pricing-txn" ] || fail "prior: the journal must finalize through normal pricing recovery"
note "conflict: coherent prior pair resolves under the held lock set (no self-deadlock); pricing recovery finalizes"

# Coherent CANDIDATE pair (the disk carries only the candidate yaml).
conflict_setup 3 candidate candidate candidate
rc=0; resolve >"$T/out" 2>"$T/err" || rc=$?
[ "$rc" = 0 ] && grep -q '"resolved": "candidate"' "$T/out" || fail "a coherent candidate snapshot must resolve (rc=$rc): $(cat "$T/err")"
[ "$(readlink "$A/current")" = releases/new ] && [ "$(sha "$R/coordinator.yaml")" = "$(sha "$T/stage/candidate.yaml")" ] || fail "candidate: the candidate pair must be on disk"
no_held "candidate"
h --pre-start; prior_on_disk "candidate then pre-start"
start_coordinator; h --close-restored --wait-seconds 5 || fail "candidate: the closer must finalize the rollback"
note "conflict: coherent candidate pair resolves; pre-start then rolls the journal back to prior"

# Mixed or foreign snapshots are refused with nothing changed.
for combo in "candidate prior prior" "prior candidate prior" "prior prior candidate" "candidate candidate prior" \
  "prior candidate candidate" "candidate prior candidate" "prior foreign prior"; do
  set -- $combo
  conflict_setup 5 "$1" "$2" "$3"
  refused_unchanged "mixed snapshot ($combo)" 'not one coherent journal pair'
done
conflict_setup 5 prior prior prior; printf 'x' >>"$R/.coordinator-deploy-rollback/coordinator.yaml"
refused_unchanged "foreign snapshot yaml" 'not one coherent journal pair'
conflict_setup 5 prior prior prior; touch "$R/.coordinator-deploy-rollback/had-overlay"; printf 'o: 1\n' >"$R/.coordinator-deploy-rollback/coordinator.pearl-overlays.yaml"
refused_unchanged "snapshot overlay differs" "overlay is not the journal's overlay"
note "conflict: every mixed prior/candidate combination and a foreign yaml/current/overlay are refused, nothing changed"
conflict_setup 5 prior prior prior; chmod 0600 "$R/.coordinator-deploy-rollback/coordinator.yaml"
refused_unchanged "prior snapshot with a 0600 yaml" "coordinator.yaml owner/mode"
conflict_setup 3 candidate candidate candidate; chmod 0644 "$R/.coordinator-deploy-rollback/catalog-previous-target"
refused_unchanged "candidate snapshot with a 0644 window" "previous-target owner/mode"
conflict_setup 5 prior prior prior; chmod 0600 "$R/.coordinator-deploy-rollback/catalog-previous-target"
refused_unchanged "prior snapshot with a 0600 window" "previous-target owner/mode"
note "conflict: a snapshot whose yaml or window owner/mode is not the journal's is refused, nothing changed"

# A verified (terminal) journal accepts only its candidate pair.
conflict_setup 5 prior prior prior; h phase hup-intent; h phase verifying; h phase verified
refused_unchanged "verified journal + prior snapshot" 'not one coherent journal pair'
note "conflict: a verified journal never takes a prior snapshot"

# The coordinator is active: refused, nothing changed, nothing started.
conflict_setup 5 prior prior prior; start_coordinator
refused_unchanged "coordinator active" 'coordinator must be stopped'
stop_coordinator
# E2 V9 r1: only a definitively stopped unit (inactive|failed, MainPID 0) is
# stopped. A Restart= wait (activating/auto-restart, MainPID 0), a drain
# (deactivating), a reload, a stale MainPID or an unreadable state all refuse.
for st in "activating 0" "deactivating 4242" "deactivating 0" "reloading 4242" "failed 4242" "inactive 4242" " 0"; do
  set -- $st
  conflict_setup 5 prior prior prior
  if [ "$#" = 2 ]; then printf '%s\n' "$1" >"$CTL/active-state"; printf '%s\n' "$2" >"$CTL/main-pid"
  else : >"$CTL/active-state"; printf '%s\n' "$1" >"$CTL/main-pid"; fi
  refused_unchanged "coordinator ActiveState=[${st% *}] MainPID=${st##* }" 'coordinator must be stopped'
  rm -f "$CTL/active-state" "$CTL/main-pid"
done
note "conflict: activating/deactivating/reloading, a stale MainPID or an unknown state -> refused, nothing changed"
# Someone else holds the lock set: refused.
conflict_setup 5 prior prior prior
python3 -c 'import fcntl,os,sys,time;fd=os.open(sys.argv[1],os.O_RDWR|os.O_CREAT,0o600);fcntl.flock(fd,fcntl.LOCK_EX);open(sys.argv[2],"w").close();time.sleep(30)' \
  "$MACPROVIDER_DEPLOY_LOCK_FILE" "$T/locked" & LOCKER=$!
for _ in $(seq 1 50); do [ -e "$T/locked" ] && break; sleep 0.1; done
refused_unchanged "lock set held" 'lock set .* is held'
kill "$LOCKER"; wait "$LOCKER" 2>/dev/null || true; rm -f "$T/locked"
# The snapshot's coordinator binary is pre-#1693: refused before any change.
conflict_setup 5 prior prior prior old
refused_unchanged "pre-#1693 snapshot binary" 'lacks per-generation wholesale pricing'
note "conflict: coordinator active, lock set held, or a pre-#1693 snapshot binary -> refused, nothing changed"

# Deploy recovery fails: the journal is restored, the snapshot kept.
conflict_setup 5 prior prior prior; touch "$CTL/nginx-fail"
rc=0; resolve >"$T/out" 2>"$T/err" || rc=$?
[ "$rc" = 5 ] && grep -q 'failed (rc=' "$T/err" || fail "a failed deploy recovery must stop (rc=$rc): $(cat "$T/err")"
[ -d "$R/.pricing-txn" ] && [ -d "$R/.coordinator-deploy-rollback" ] || fail "failure: journal restored and snapshot kept"
no_held "failure"; rm -f "$CTL/nginx-fail"
# ...and a rerun completes.
rc=0; resolve >"$T/out" 2>"$T/err" || rc=$?
[ "$rc" = 0 ] || fail "a rerun after a failed deploy recovery must resolve (rc=$rc): $(cat "$T/err")"
note "conflict: deploy recovery failure restores the journal and keeps the snapshot; a rerun resolves"

# E2 V9 r1: the deploy snapshot dumped the request-log -wal/-shm ACLs while the
# coordinator ran; its clean stop deleted both before the resolution. Deploy
# recovery skips exactly those absent sidecars and the resolution completes.
conflict_setup 5 prior prior prior
S="$R/.coordinator-deploy-rollback"; DB="$T/var/lib/macprovider"
mkdir -p "$DB"; : >"$DB/request-log.sqlite"; rm -f "$DB/request-log.sqlite-wal" "$DB/request-log.sqlite-shm"
printf '# file: %s\nuser::rw-\n' "$DB/request-log.sqlite" >"$S/request-log-db.acl"
printf '# file: %s\nuser::rw-\n' "$DB/request-log.sqlite-wal" >"$S/request-log-wal.acl"
printf '# file: %s\nuser::rw-\n' "$DB/request-log.sqlite-shm" >"$S/request-log-shm.acl"
touch "$S/had-request-log-db-acl" "$S/had-request-log-wal-acl" "$S/had-request-log-shm-acl"
rc=0; resolve >"$T/out" 2>"$T/err" || rc=$?
[ "$rc" = 0 ] && grep -q '"resolved": "prior"' "$T/out" || fail "absent -wal/-shm must not abort the resolution (rc=$rc): $(cat "$T/err")"
grep -q 'skipping ACL restore for absent SQLite sidecar' "$T/err" || fail "the absent sidecar skip must be logged: $(cat "$T/err")"
[ -d "$R/.pricing-txn" ] && [ ! -e "$S" ] || fail "absent sidecars: journal visible, snapshot consumed"
no_held "absent sidecars"
# ...but an absent database still fails closed: journal restored, snapshot kept.
conflict_setup 5 prior prior prior
mkdir -p "$DB"; rm -f "$DB/request-log.sqlite"
printf '# file: %s\nuser::rw-\n' "$DB/request-log.sqlite" >"$S/request-log-db.acl"; touch "$S/had-request-log-db-acl"
rc=0; resolve >"$T/out" 2>"$T/err" || rc=$?
[ "$rc" = 5 ] && grep -q 'failed (rc=' "$T/err" || fail "an absent database ACL target must stop (rc=$rc): $(cat "$T/err")"
[ -d "$R/.pricing-txn" ] && [ -d "$S" ] || fail "absent database: journal restored and snapshot kept"
no_held "absent database"
note "conflict: absent SQLite -wal/-shm ACL targets are skipped; an absent database still stops, fail-closed"

# Interrupted (SIGTERM) during deploy recovery: its process group is stopped,
# the journal restored, the snapshot kept.
conflict_setup 5 prior prior prior; touch "$CTL/nginx-hang"
resolve_env exec python3 -I "$HELPER" --resolve-deploy-conflict >"$T/out" 2>"$T/err" & HP=$!
for _ in $(seq 1 100); do [ -e "$CTL/nginx-waiting" ] && break; sleep 0.1; done
[ -e "$CTL/nginx-waiting" ] || fail "interrupt: deploy recovery did not reach nginx -t: $(cat "$T/err")"
[ -n "$(ls -a "$R" | grep '^\.pricing-txn\.conflict-held\.' || true)" ] && [ ! -e "$R/.pricing-txn" ] || fail "the journal must be set aside only inside the critical section"
kill -TERM "$HP"; rc=0; wait "$HP" || rc=$?
[ "$rc" = 5 ] && grep -q 'interrupted (SIGTERM)' "$T/err" || fail "interrupt must stop with exit 5 (rc=$rc): $(cat "$T/err")"
[ -d "$R/.pricing-txn" ] && [ -d "$R/.coordinator-deploy-rollback" ] || fail "interrupt: journal restored and snapshot kept"
no_held "interrupt"; rm -f "$CTL/nginx-hang" "$CTL/nginx-waiting"
sleep 0.3; ! pgrep -f "$T/bin/nginx" >/dev/null || fail "interrupt: deploy recovery's process group must be stopped"
note "conflict: SIGTERM during deploy recovery stops it, restores the journal, keeps the snapshot"

# An orphaned set-aside journal (the resolver was SIGKILLed) is refused by the
# writers' Python guard and put back by the next pricing pre-start.
setup; forward_until 3; stop_coordinator
mv "$R/.pricing-txn" "$R/.pricing-txn.conflict-held.999999.1"
rc=0; h foreign-state >"$T/out" || rc=$?
[ "$rc" = 3 ] && grep -q 'set aside' "$T/out" || fail "foreign-state must report a set-aside journal (rc=$rc)"
python3 - "$REPO_ROOT/scripts/lib/coordinator_config_guard.py" "$R" <<'PY' || fail "the Python writer guard must refuse a set-aside journal"
import importlib.machinery, importlib.util, sys
loader = importlib.machinery.SourceFileLoader("g", sys.argv[1]); spec = importlib.util.spec_from_loader("g", loader)
g = importlib.util.module_from_spec(spec); loader.exec_module(g)
try:
    g.refuse_if_pricing_txn(sys.argv[2])
except g.PricingTransactionActive as exc:
    assert ".pricing-txn.conflict-held." in str(exc), exc
else:
    raise SystemExit("not refused")
PY
h --pre-start
[ -d "$R/.pricing-txn" ] && [ "$(phase)" = restored-unverified ] || fail "pre-start must restore an orphaned set-aside journal and recover it"
no_held "orphan"
note "orphaned set-aside journal: writers refuse it, the next pre-start puts it back"

# Deploy recovery removes the pricing machinery (a pre-#1693 snapshot has no
# had-pricing-* markers): stop with the journal visible.
conflict_setup 5 prior prior prior
rm -f "$R/.coordinator-deploy-rollback/had-pricing-recover-helper"
rc=0; resolve >"$T/out" 2>"$T/err" || rc=$?
[ "$rc" = 5 ] && grep -q 'changed pricing recovery files' "$T/err" || fail "removed pricing machinery must stop (rc=$rc): $(cat "$T/err")"
[ -d "$R/.pricing-txn" ] || fail "machinery stop: journal must stay visible"; no_held "machinery stop"
# The binary after deploy recovery is pre-#1693 (a deploy recovery that
# installs one): stop with the journal visible and a named runbook step.
conflict_setup 5 prior prior prior
cat >"$T/bin/deploy-recover-old-binary" <<SH
#!/bin/sh
sh "$R/coordinator-deploy-recover" "\$@" || exit \$?
cp "$T/bin/coordinator-old" "$R/coordinator"
SH
chmod 0755 "$T/bin/deploy-recover-old-binary"
rc=0; MACPROVIDER_DEPLOY_RECOVER="$T/bin/deploy-recover-old-binary" resolve >"$T/out" 2>"$T/err" || rc=$?
[ "$rc" = 5 ] && grep -q 'lacks per-generation wholesale pricing; do not start it' "$T/err" && grep -q 'Deploy-and-pricing conflict, step 4' "$T/err" \
  || fail "a pre-#1693 binary after deploy recovery must stop (rc=$rc): $(cat "$T/err")"
[ -d "$R/.pricing-txn" ] || fail "old binary stop: journal must stay visible"; no_held "old binary stop"
[ ! -e "$CTL/started" ] || fail "old binary stop: nothing may be started"
note "conflict: pricing machinery removed or a pre-#1693 binary after deploy recovery -> stop, journal visible"

# ---------------------------------------------------------------------------
# Unit wiring (v20 L4b) and the deploy install, by unit properties / text.
# ---------------------------------------------------------------------------
UNITS="$SCRIPT_DIR/../systemd"
DEPLOY_SH="$SCRIPT_DIR/../deploy-pearl-vps.sh"
python3 - "$UNITS" "$DEPLOY_SH" <<'PY' || fail "pricing unit wiring / deploy install is wrong"
import configparser, re, sys
units, deploy = sys.argv[1:]
def props(path):
    out = {}
    section = None
    for line in open(path):
        line = line.strip()
        if not line or line.startswith("#"):
            continue
        if line.startswith("["):
            section = line.strip("[]"); continue
        k, _, v = line.partition("=")
        out.setdefault((section, k), []).append(v)
    return out
guard = props(units + "/macprovider-coordinator-deploy-guard.conf")
assert guard[("Unit", "Wants")] == ["macprovider-coordinator-pricing-close.service"], guard
# The drop-in carries ONLY Wants= for the closer: no ordering or hard dependency on it.
assert all("pricing-close" not in v for k, vals in guard.items() if k[1] != "Wants" for v in vals), guard
close = props(units + "/macprovider-coordinator-pricing-close.service")
assert close[("Unit", "After")] == ["macprovider-coordinator.service"], close
assert close[("Service", "Type")] == ["oneshot"], close
assert close[("Unit", "OnFailure")] == ["macprovider-pearl-updater-alert@%n.service"], close
assert close[("Service", "ExecStart")] == ["/usr/bin/python3 -I /opt/macprovider/coordinator-pricing-recover --close-restored"], close
# 8 windows x 900 s + the 300 s lock wait must fit the start timeout.
assert int(close[("Service", "TimeoutStartSec")][0]) >= 8 * 900 + 300, close
svc = props(units + "/../macprovider-coordinator.service")
# #1693 E2 V8: a SIGHUP death restarts the coordinator; a deliberate stop does not.
assert svc[("Service", "Restart")] == ["on-failure"], svc
assert svc[("Service", "RestartForceExitStatus")] == ["SIGHUP"], svc
assert svc[("Service", "KillSignal")] == ["SIGTERM"], svc
rec = props(units + "/macprovider-coordinator-deploy-recovery.service")
assert rec[("Service", "ExecStart")] == ["/usr/bin/python3 -I /opt/macprovider/coordinator-pricing-recover --pre-start",
                                        "/opt/macprovider/coordinator-deploy-recover --pre-start"], rec
d = open(deploy).read()
# L0: the journal check sits right after the lease (tier2 check) and before step 0a/0b/0.
j = d.index("test -e /opt/macprovider/.pricing-txn")
assert d.index("a Tier-2 enforcement transaction is active") < j < d.index('log "step 0a/9') < d.index('log "step 0/9'), "L0 placement"
# Install: digests in the recovery-inputs block, helpers before units.
for name in ("coordinator-pricing-recover", "macprovider-coordinator-pricing-close.service", "coordinator-config-guard.sh"):
    assert re.search(r'awk .\{ print \$1 "  %s" \}' % re.escape(name), d), name
block = d[d.index("_pricing_next=/opt/macprovider/coordinator-pricing-recover.next"):d.index("systemctl daemon-reload", d.index("_pricing_next="))]
assert block.index("mv -Tf \\\"\\$_pricing_next\\\"") < block.index("mv -Tf \\\"\\$_close_next\\\"") < block.index("mv -Tf \\\"\\$_unit_next\\\"") < block.index("mv -Tf \\\"\\$_guard_next\\\""), "helpers must install before units"
assert block.index("mv -Tf \\\"\\$_config_guard_next\\\"") < block.index("mv -Tf \\\"\\$_helper_next\\\""), "guard lib before deploy-recover"
for marker in ("had-pricing-recover-helper", "had-config-guard-lib", "had-pricing-close-unit"):
    assert marker in d, marker
rec_sh = open(deploy.replace("deploy-pearl-vps.sh", "coordinator-deploy-recover.sh")).read()
for marker in ("had-pricing-recover-helper", "had-config-guard-lib", "had-pricing-close-unit"):
    assert marker in rec_sh, marker
PY
note "unit wiring (drop-in Wants only; closer After/oneshot/OnFailure; pre-start order) and deploy install/snapshot"

printf '[coordinator-pricing-recover test] PASS\n'
