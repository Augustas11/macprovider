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
  MACPROVIDER_BOOT_ID_FILE="$T/boot_id" MACPROVIDER_REQUIRED_UID="$(id -u)" CTL="$T/ctl" \
  MACPROVIDER_DEPLOY_LOCK_REQUIRED_UID="$(id -u)" \
  MACPROVIDER_DEPLOY_LOCK_REQUIRED_GID="$(python3 -c 'import os,sys;print(os.stat(sys.argv[1]).st_gid)' "$T")"
R="$MACPROVIDER_ROOT"; A="$R/autotune"

mkdir -p "$T/bin" "$CTL"
# systemctl: MainPID and ActiveEnterTimestampMonotonic of the stub coordinator.
cat >"$T/bin/systemctl" <<'SH'
#!/bin/sh
case "$*" in
  *"-p MainPID"*) if [ -e "$CTL/stopped" ]; then echo 0; else cat "$CTL/pid"; fi ;;
  *"-p ActiveEnterTimestampMonotonic"*) cat "$CTL/active-enter" ;;
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
apply("boot")
signal.signal(signal.SIGHUP, lambda *_: apply("sighup"))
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
           "overlay_sha256": ""}, open(sys.argv[4], "w"))
PY
}
begin() {
  h begin --candidate-yaml "$T/stage/candidate.yaml" --new-current releases/new --prior-current releases/old \
    --candidate-window "$T/stage/window" --verdict "$T/stage/verdict.json" >/dev/null
}
swap_window() { cp "$T/stage/window" "$A/.pw.tmp"; mv "$A/.pw.tmp" "$A/.previous-target"; }
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
rc=0; h --close-restored --wait-seconds 2 2>"$T/err" || rc=$?
[ "$rc" = 5 ] && grep -q 'has not started since the restore' "$T/err" || fail "closer must refuse a coordinator started before the restore (rc=$rc): $(cat "$T/err")"
[ -e "$R/.pricing-txn" ] || fail "a refused close must keep the journal"
echo boot-3 >"$T/boot_id"; start_coordinator
rc=0; h --close-restored --wait-seconds 2 2>"$T/err" || rc=$?
[ "$rc" = 5 ] && grep -q 'not made in this boot' "$T/err" || fail "closer must refuse a restore from another boot (rc=$rc)"
note "closer binds to boot_id + the coordinator's monotonic start, never wall clock alone"

# A coordinator that boots but rejects the restored pair: the closer fails (alert).
setup; forward_until 5; stop_coordinator; h --pre-start
touch "$CTL/reject"; start_coordinator
rc=0; h --close-restored --wait-seconds 2 2>"$T/err" || rc=$?
[ "$rc" = 5 ] || fail "closer without a matching boot record must fail for the alert (rc=$rc)"
[ "$(phase)" = restored-unverified ] || fail "failed close must keep restored-unverified"
note "closer failure (no matching boot record) exits non-zero for OnFailure alerting"

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
setup; forward_until 3; stop_coordinator; h --pre-start
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
