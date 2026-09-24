#!/usr/bin/env bash
# Hermetic tests for scripts/catalog-content-release.sh (#1688 C4-C7).
#
# No Pearl, no canary Mac, no root. A throwaway git repo holds the reviewed
# tooling + committed release; a fake ssh runs Pearl commands locally with the
# Pearl paths rewritten into a temp root (like test-autotune-activate.sh); a
# Python coordinator stub serves the loopback buyer/provider/canary-status HTTP
# surfaces, reloads on SIGHUP and writes a fake journal; fake journalctl,
# systemctl, systemd-run, launchctl and lsof close the loop. catalog-release.py
# is a stub here (signed fixtures cannot be mutated) that asserts every
# argument/path the lane hands content-gate and delegates buyer-serving-set to
# the real script; its real content-gate is covered by
# scripts/tests/test_catalog_content_gate.py.
#
# Cases: preflight GO; NO_GO for wrong lane, closure miss (content-gate), dry-load failure,
# coverage loss (and GO with a logged override), config content drift (bytes,
# mtime-preserved bytes, missing applied-config record), working tree vs commit
# mismatch, evidence (e) buyer-serving set (new Tier-2 pin, listed ->
# recommendable, serving hash changed; a dropped exclusion of a pinned model is
# GO; live release with no
# reviewed commit), missing canary evidence; deploy happy path (row hash changed
# -> autotune --apply first); refusal under the lease when the live-binary
# dry-load flips to failure or the staged bytes differ from the commit;
# rollback on evidence (a), (b) (+ no applied-config record from this HUP), (c)
# (+ retention of an adopted release), (d) (a rejection of a catalog admissible
# before the HUP fails even at an unchanged rate; a chronically inadmissible
# catalog passes); rollback re-HUP rejected -> controlled restart; restart
# failure -> runbook exit 5; an interrupt while the publish is in flight still
# rolls back (state read through the lease); a lease runner lost after
# activation -> exit 6, no rollback; a held renewal/deploy lock -> refusal.
#
# #1693 pricing releases (the stub coordinator checks real parity of the live
# yaml rate_card against the served card on every boot/HUP, counts billing
# snapshots and writes rate_table_sha256 / signed_rate_card_sha256 /
# autotune_release_id / billing_snapshot_id): preflight GO with the pricing
# verdict and price table; commit block mismatch, dry-load parity mismatch,
# foreign recovery state, installed-writer hash mismatch, pricing keys in the
# overlay, a pre-#1693 coordinator record, an unacknowledged move seen only in
# the request log and a present journal -> NO_GO with nothing changed; deploy
# without / with a wrong ack -> refused; happy path (yaml spliced 0640, record
# digests, journal finalized, gateway converged; not converged -> alert only);
# yaml moved under the lock -> refused pre-mutation; HUP rejected, billing txn
# failure (half-applied HUP) and evidence (a) failure -> yaml + current +
# window rolled back together with a prior record; interrupt during the
# publish -> journal-driven rollback; lease lost -> no rollback, journal kept,
# --recover-pricing-txn restores; a name pinned by --preflight-verdict keeps
# the ack valid when a new name appears.
# Every lease-mode Pearl mutation runs through the lease runner (the fake ssh
# rewrites the scripts the runner decodes, like any other remote command).
set -euo pipefail
# GNU mv has -T (no-target-directory); BSD/macOS mv lacks it, where -h
# (do not follow a symlinked target) is the equivalent for the swap.
if mv --version >/dev/null 2>&1; then export AA_MV_TF="mv -Tf"; else export AA_MV_TF="mv -hf"; fi

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"
T="$(mktemp -d)"
T="$(cd "$T" && pwd -P)"
STUB_PID=""
LOCK_PID=""
cleanup() {
  [ -z "$STUB_PID" ] || { kill "$STUB_PID" 2>/dev/null; wait "$STUB_PID" 2>/dev/null; } || true
  [ -z "$LOCK_PID" ] || { kill "$LOCK_PID" 2>/dev/null; wait "$LOCK_PID" 2>/dev/null; } || true
  pkill -f "$T/" >/dev/null 2>&1 || true
  rm -rf "$T"
}
trap cleanup EXIT
fail() {
  printf '[test-catalog-content-release] FAIL: %s\n' "$*" >&2
  [ ! -s "${CCR_TEST_CTL:-/nonexistent}/dryload.stderr" ] || { echo "--- dry-load stub stderr:" >&2; tail -n 20 "$CCR_TEST_CTL/dryload.stderr" >&2; }
  exit 1
}

# #1705: the dry-load validation root carries the live row-continuity list.
grep -qF 'install -m 0640 "$root/.row-continuity-target" "$scratch/check/.row-continuity-target"' "$(dirname "$0")/catalog-content-release.sh" ||
  fail "dry-load must carry the live .row-continuity-target into the validation root"
note() { printf '[test-catalog-content-release] %s\n' "$*"; }

export CCR_UID; CCR_UID="$(id -u)"
free_port() { python3 -c 'import socket;s=socket.socket();s.bind(("127.0.0.1",0));print(s.getsockname()[1]);s.close()'; }
export BUYER_PORT PROVIDER_PORT CANARY_PORT
BUYER_PORT="$(free_port)"; PROVIDER_PORT="$(free_port)"; CANARY_PORT="$(free_port)"
OPKEY="op-key-0123456789abcdefghijklmnopqrstuvwxyz"
CANARY_ID="canary-provider-1"

# ---------------------------------------------------------------------------
# Fake tools.
# ---------------------------------------------------------------------------
mkdir -p "$T/bin"
cat >"$T/bin/ssh" <<'SSH'
#!/usr/bin/env bash
set -u
while [ $# -gt 0 ]; do
  case "$1" in -o|-i|-p) shift 2 ;; -*) shift ;; *) break ;; esac
done
host="$1"; shift
cmd="$*"
if [ "$host" = canary.test ]; then
  export HOME="$CCR_CANARY_HOME"
  case "$cmd" in
    "python3 -"*) sed -e "s#/usr/sbin/lsof#lsof#g" | bash -c "$cmd" ;;
    *) exec bash -c "$cmd" ;;
  esac
  exit $?
fi
cmd="$(printf '%s\n' "$cmd" | pearl-rw)"
# The pricing helper reads its Pearl paths from the environment.
export MACPROVIDER_ROOT="$CCR_FAKE/opt/macprovider" MACPROVIDER_ETC_ROOT="$CCR_FAKE/etc/macprovider" \
  MACPROVIDER_RUN_ROOT="$CCR_FAKE/run/macprovider" MACPROVIDER_UPDATER_STATE_ROOT="$CCR_FAKE/var/lib/macprovider-pearl-updater" \
  MACPROVIDER_GLOBAL_DEPLOY_LOCK_FILE="$CCR_FAKE/run/lock/macprovider-pearl-updater.lock" \
  MACPROVIDER_DEPLOY_LOCK_FILE="$CCR_FAKE/opt/macprovider/.coordinator-deploy.lock" \
  MACPROVIDER_COORDINATOR_URL="http://127.0.0.1:$BUYER_PORT" MACPROVIDER_REQUIRED_UID="$CCR_UID" \
  MACPROVIDER_BOOT_ID_FILE="$CCR_FAKE/boot_id"
case "$cmd" in
  "bash -s"*) pearl-rw | bash -c "$cmd" ;;
  # The lock validator's Pearl paths live in its body (not sha-pinned).
  "cat >"*pearl_autotune_deploy_lock.py*) pearl-rw | bash -c "$cmd" ;;
  *) exec bash -c "$cmd" ;;
esac
SSH
# Pearl paths -> the temp root, for commands, scripts, and (via the lease
# runner's decode steps) every script and argument sent through the lease.
cat >"$T/bin/pearl-rw" <<'RW'
#!/usr/bin/env bash
exec sed -E \
      -e "s#/opt/macprovider/#$CCR_FAKE/opt/macprovider/#g" \
      -e "s#/etc/macprovider/#$CCR_FAKE/etc/macprovider/#g" \
      -e "s#/etc/systemd/system/#$CCR_FAKE/etc/systemd/system/#g" \
      -e "s#/usr/local/#$CCR_FAKE/usr/local/#g" \
      -e "s#\"/opt\"#\"$CCR_FAKE/opt\"#g" \
      -e "s#/run/lock/#$CCR_FAKE/run/lock/#g" \
      -e "s#/var/lib/macprovider-pearl-updater/#$CCR_FAKE/var/lib/macprovider-pearl-updater/#g" \
      -e "s#install -d -o macprovider -g macprovider -m 0750 /var/lib/macprovider#mkdir -p $CCR_FAKE/var/lib/macprovider#g" \
      -e "s#/var/lib/macprovider/#$CCR_FAKE/var/lib/macprovider/#g" \
      -e "s#/run/macprovider/#$CCR_FAKE/run/macprovider/#g" \
      -e "s#os\\.fchown\\(fd, 0, 0\\)#pass#g" \
      -e "s#/tmp/macprovider-content-#$CCR_RTMP/macprovider-content-#g" \
      -e "s#/proc/\\\$pid/environ#$CCR_FAKE/proc-environ#g" \
      -e "s#127\\.0\\.0\\.1:8443#127.0.0.1:$BUYER_PORT#g" \
      -e "s#127\\.0\\.0\\.1:8444#127.0.0.1:$PROVIDER_PORT#g" \
      -e "s#\"\\\$window\" (plan|apply|restore|coverage) #\"\$window\" \\1 --required-uid $CCR_UID --group $CCR_GID #g" \
      -e "s#chown (-R )?root:[a-z]+#:#g" \
      -e "s#mv -Tf#$AA_MV_TF#g" \
      -e "s#/tmp/macprovider-activation-lease\\.#$CCR_FAKE/tmp/macprovider-activation-lease.#g" \
      -e "s#base64 -d >\"\\\$work/cmd\"#base64 -d | pearl-rw >\"\\\$work/cmd\"#g" \
      -e "s#\\| base64 -d\\)\"; fi#| base64 -d | pearl-rw)\"; fi#g" \
      -e "s#st_uid != 0#st_uid != $CCR_UID#g" \
      -e "s#st_gid != 0#st_gid != $CCR_GID#g"
RW
cat >"$T/bin/rsync" <<'RSYNC'
#!/usr/bin/env bash
set -eu
args=("$@"); n=${#args[@]}
src="${args[$((n-2))]}"; dst="${args[$((n-1))]}"; dst="${dst#*:}"
dst="$(printf '%s' "$dst" | sed "s#/opt/macprovider/#$CCR_FAKE/opt/macprovider/#")"
mkdir -p "$dst"; cp -R "$src"/. "$dst"
# Simulate the staged bytes changing after preflight (not the reviewed commit's).
if [ -e "$CCR_TEST_CTL/tamper-upload" ]; then printf ' ' >>"$dst/demand-rank.json"; fi
RSYNC
# `date +%s` is how the lane reads Pearl's clock (T_HUP is its first call):
# journal-before-hup plants one catalog_incompatible event just before it.
cat >"$T/bin/date" <<'DATE'
#!/usr/bin/env bash
if [ "${1:-}" = "+%s" ] && [ -e "${CCR_TEST_CTL:-/nonexistent}/journal-before-hup" ]; then
  rm -f "$CCR_TEST_CTL/journal-before-hup"
  # Answer the clock read ourselves so the planted event is provably before T_HUP.
  exec python3 - <<'PY'
import json, os, time
t = int(time.time())
ctl = os.environ["CCR_TEST_CTL"]
rid, sha = open(os.path.join(ctl, "incompat-key")).read().split() if os.path.exists(os.path.join(ctl, "incompat-key")) else ("chronic-release", "cd" * 32)
line = {"level": "warn", "catalog_release_id": rid, "catalog_candidate_sha256": sha,
        "message": "provider catalog release is incompatible with coordinator"}
with open(os.path.join(os.environ["CCR_FAKE"], "journal.log"), "a") as fh:
    fh.write("%.6f pearl coordinator[1]: %s\n" % (t - 0.5, json.dumps(line, sort_keys=True)))
print(t)
PY
fi
exec /bin/date "$@"
DATE
cat >"$T/bin/flock" <<'FLOCK'
#!/usr/bin/env python3
import fcntl, os, subprocess, sys
args = sys.argv[1:]
mode = fcntl.LOCK_EX
while args and args[0].startswith("-"):
    flag = args.pop(0)
    if flag in ("-n", "--nonblock"):
        mode |= fcntl.LOCK_NB
target, cmd = args[0], args[1:]
fd = int(target) if target.isdigit() and not cmd else os.open(target, os.O_RDONLY | os.O_CREAT, 0o600)
try:
    fcntl.flock(fd, mode)
except BlockingIOError:
    sys.exit(1)
sys.exit(subprocess.call(cmd) if cmd else 0)
FLOCK
cat >"$T/bin/sha256sum" <<'SHA'
#!/bin/sh
exec shasum -a 256 "$@"
SHA
printf '#!/bin/sh\nexit 0\n' >"$T/bin/logger"
cat >"$T/bin/systemctl" <<'SYSTEMCTL'
#!/usr/bin/env bash
case "$*" in
  *"-p MainPID"*)
    # The publish is the only caller with a staged .incoming-* release.
    if [ -e "$CCR_TEST_CTL/publish-slow" ] && ls -d "$CCR_FAKE"/opt/macprovider/autotune/releases/.incoming-* >/dev/null 2>&1; then
      rm -f "$CCR_TEST_CTL/publish-slow"; touch "$CCR_TEST_CTL/publish-started"; sleep 3
    fi
    cat "$CCR_FAKE/coordinator.pid" ;;
  *ExecMainStartTimestamp*) printf '@%s\n' "$(cat "$CCR_FAKE/start")" ;;
  *"-p Requires"*) echo "system.slice macprovider-coordinator-deploy-recovery.service" ;;
  *"-p Wants"*) [ -e "$CCR_TEST_CTL/no-closer-want" ] || echo "network-online.target macprovider-coordinator-pricing-close.service" ;;
  *"-p LoadState"*) echo loaded ;;
  restart*)
    [ ! -e "$CCR_TEST_CTL/restart-fails" ] || exit 1
    kill -USR1 "$(cat "$CCR_FAKE/coordinator.pid")"; sleep 1 ;;
  is-active*) exit 0 ;;
  *) echo "fake systemctl: unsupported $*" >&2; exit 1 ;;
esac
SYSTEMCTL
cat >"$T/bin/systemd-run" <<'RUN'
#!/usr/bin/env bash
while [ $# -gt 0 ]; do
  case "$1" in -p) shift 2 ;; -*) shift ;; *) break ;; esac
done
exec "$@"
RUN
cat >"$T/bin/journalctl" <<'JOURNAL'
#!/usr/bin/env python3
import sys
args = sys.argv[1:]
since, until, fmt = 0.0, float("inf"), "short"
for i, a in enumerate(args):
    if a == "--since":
        since = float(args[i + 1].lstrip("@"))
    if a == "--until":
        until = float(args[i + 1].lstrip("@"))
    if a == "-o":
        fmt = args[i + 1]
import os
for line in open(os.path.join(os.environ["CCR_FAKE"], "journal.log"), encoding="utf-8"):
    epoch = float(line.split(" ", 1)[0])
    if epoch < since or epoch > until:
        continue
    sys.stdout.write(line.split(": ", 1)[1] if fmt == "cat" else line)
JOURNAL
cat >"$T/bin/launchctl" <<'LAUNCHCTL'
#!/usr/bin/env python3
import json, os, sys
ctl, fake = os.environ["CCR_TEST_CTL"], os.environ["CCR_FAKE"]
args = sys.argv[1:]
if args[0] == "print":
    print("pid = %s" % open(os.path.join(fake, "coordinator.pid")).read().strip())
elif args[0] == "kickstart":
    with open(os.path.join(ctl, "canary-restarts.log"), "a") as fh:
        fh.write("kickstart\n")
    if not os.path.exists(os.path.join(ctl, "canary-stuck")):
        state_path = os.path.join(ctl, "canary-state.json")
        state = json.load(open(state_path))
        served = json.load(open(os.path.join(fake, "served.json")))
        state.update(served, session=state["session"] + 1)
        json.dump(state, open(state_path, "w"))
sys.exit(0)
LAUNCHCTL
cat >"$T/bin/lsof" <<'LSOF'
#!/usr/bin/env python3
import os, sys
args = sys.argv[1:]
pid = args[args.index("-p") + 1]
if "txt" in args:
    path = os.path.join(os.environ["CCR_CANARY_HOME"], "macprovider", "macprovider-cli")
    info = os.stat(path)
    print("ftxt\nD%s\ni%d\nn%s" % (hex(info.st_dev), info.st_ino, path))
else:
    print(pid)
LSOF
chmod 0755 "$T"/bin/*
export PATH="$T/bin:$PATH"

# Coordinator daemon stub: loopback HTTP + SIGHUP reload + fake journal.
cat >"$T/coordinator-stub.py" <<'STUB'
import hashlib, http.server, json, os, signal, socketserver, sys, threading, time
from datetime import datetime, timezone
fake, ctl = os.environ["CCR_FAKE"], os.environ["CCR_TEST_CTL"]
opkey = os.environ["CCR_OPKEY"]
current = os.path.join(fake, "opt/macprovider/autotune/current")
FEEDS = {"/v1/autotune-candidates": "autotune-candidates.json", "/v1/demand-rank": "demand-rank.json",
         "/v1/rate-card": "rate-card.json", "/v1/catalog-artifacts": "autotune-artifacts.json"}
state = {"hups": 0, "snap": 1}
lock = threading.Lock()
sys.path.insert(0, os.environ["CCR_T"])
import stubparity  # noqa: E402  real yaml<->card parity, shared with the dry-load stub
CONFIG = os.path.join(fake, "opt/macprovider/coordinator.yaml")

def c(name):
    return os.path.exists(os.path.join(ctl, name))

def journal(obj):
    obj.setdefault("time", datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%S.%fZ"))
    with open(os.path.join(fake, "journal.log"), "a") as fh:
        fh.write("%.6f pearl coordinator[%d]: %s\n" % (time.time(), os.getpid(), json.dumps(obj, sort_keys=True)))

def sha(path):
    return hashlib.sha256(open(path, "rb").read()).hexdigest() if os.path.exists(path) else ""

def parity_ok():  # buyer.ValidateRuntimeRateCardParity: live yaml rows == current card rows
    try:
        return stubparity.yaml_rows(CONFIG) == stubparity.card_rows(os.path.join(current, "rate-card.json"))
    except Exception:
        return False

def applied(source):  # the coordinator's applied-config record (applied_config.go)
    config = os.path.join(fake, "opt/macprovider/coordinator.yaml")
    overlay = os.path.join(fake, "etc/macprovider/coordinator.pearl-overlays.yaml")
    rec = {"schema": "macprovider.coordinator-applied-config.v1", "config_path": "/opt/macprovider/coordinator.yaml",
           "config_sha256": sha(config), "overlay_path": "/etc/macprovider/coordinator.pearl-overlays.yaml",
           "overlay_sha256": sha(overlay), "loaded_at": datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%S.%f000Z"),
           "source": source, "version": "stub"}
    if not c("record-legacy"):  # #1693 C3 fields (a pre-#1693 coordinator lacks them)
        rec.update(rate_table_sha256=stubparity.rate_table_sha(stubparity.yaml_rows(config)),
                   signed_rate_card_sha256=hashlib.sha256(state["files"]["rate-card.json"]).hexdigest(),
                   autotune_release_id=state["version"], billing_snapshot_id=state["snap"])
    os.makedirs(os.path.join(fake, "run/macprovider"), exist_ok=True)
    tmp = os.path.join(fake, "run/macprovider/.applied.tmp")
    open(tmp, "w").write(json.dumps(rec) + "\n")
    os.replace(tmp, os.path.join(fake, "run/macprovider/coordinator-applied-config.json"))

def load(keep_rate_card=False):  # keeps the prior candidate bytes (stale serve)
    m = json.load(open(os.path.join(current, "release.json")))
    files = {}
    for name in os.listdir(current):
        files[name] = open(os.path.join(current, name), "rb").read()
    t2 = files["tier2-catalog.json"]
    with lock:
        if keep_rate_card and "files" in state:
            for n in ("autotune-candidates.json", "autotune-candidates.json.sig"):
                files[n] = state["files"][n]
        state.update(version=m["release_id"], policy=m["policy_version"],
                     cand=m["feeds"]["autotune-candidates.json"]["sha256"],
                     signer=m["feeds"]["autotune-candidates.json"]["signer_key_id"],
                     t2id=json.loads(t2)["catalog_id"], t2sha=hashlib.sha256(t2).hexdigest(), files=files)
        served = {k: state[k] for k in ("version", "policy", "cand", "signer")}
    json.dump({"release_id": served["version"], "policy": served["policy"], "digest": served["cand"],
               "signer": served["signer"]}, open(os.path.join(fake, "served.json"), "w"))

def on_hup(*_):
    target = json.load(open(os.path.join(current, "release.json")))["release_id"]
    reject = open(os.path.join(ctl, "reject-version")).read().strip() if c("reject-version") else ""
    if reject == target:
        journal({"level": "error", "message": "autotune feed reload rejected; keeping prior catalog and served feeds"})
        return
    if not parity_ok():
        journal({"level": "error", "message": "autotune runtime economics reload rejected: rate-card parity"})
        return
    if c("billing-fail-once"):
        os.remove(os.path.join(ctl, "billing-fail-once"))
        journal({"level": "error", "message": "billing config reload rejected; keeping prior billing config"})
        return
    state["snap"] += 1
    state["hups"] += 1
    load(keep_rate_card=c("serve-stale") and state["hups"] == 1)
    t2sha = "00" * 32 if c("tier2-wrong") else state["t2sha"]
    journal({"level": "info", "event": "autotune_feed_sighup_reload", "autotune_catalog_version": state["version"],
             "tier2_catalog_id": state["t2id"], "tier2_sha256": t2sha,
             "message": "autotune signed feed reloaded without restart"})
    rid, sha = open(os.path.join(ctl, "incompat-key")).read().split() if c("incompat-key") else ("chronic-release", "cd" * 32)
    if c("incompat-after-count") and state["hups"] == 1:
        for _ in range(int(open(os.path.join(ctl, "incompat-after-count")).read())):
            journal({"level": "warn", "catalog_release_id": rid, "catalog_candidate_sha256": sha,
                     "message": "provider catalog release is incompatible with coordinator"})
            journal({"level": "warn", "provider_id": "p", "message": "closing provider connection: catalog_incompatible"})
    if not c("applied-record-stale"):
        applied("sighup")
    journal({"level": "info", "message": "tier2/proof_of_weights config reloaded"})

def on_restart(*_):
    if not parity_ok():
        journal({"level": "error", "message": "coordinator boot refused: rate-card parity"})
        return
    state["snap"] += 1
    load()
    applied("boot")
    journal({"level": "info", "message": "coordinator started"})

def canary():
    return json.load(open(os.path.join(ctl, "canary-state.json")))

def pool():
    cs = canary()
    entries = [{"provider_id": os.environ["CCR_CANARY_ID"], "catalog_release_id": cs["release_id"],
                "catalog_candidate_sha256": cs["digest"], "hash_status": "hash_verified", "routing_eligible": True}]
    if c("poolz-extra.json"):
        entries += json.load(open(os.path.join(ctl, "poolz-extra.json")))
    if c("poolz-unavailable-after-hup") and state["hups"] >= 1:
        entries.append({"provider_id": "p2", "catalog_release_id": state["version"], "catalog_candidate_sha256": state["cand"],
                        "hash_status": "catalog_unavailable"})
    return {"pool": entries}

class H(http.server.BaseHTTPRequestHandler):
    def log_message(self, *a):
        pass
    def send(self, code, body, ctype="application/json"):
        self.send_response(code); self.send_header("Content-Type", ctype)
        self.send_header("Content-Length", str(len(body))); self.end_headers(); self.wfile.write(body)
    def authed(self):
        return self.headers.get("Authorization") == "Bearer " + opkey
    def do_GET(self):
        port = self.server.server_address[1]
        path, _, query = self.path.partition("?")
        if port == int(os.environ["CANARY_PORT"]):
            cs = canary()
            body = {"provider_id": os.environ["CCR_CANARY_ID"], "network_state": "buyer_serving", "model_loaded": True,
                    "model": os.environ["CCR_CANARY_KEY"],
                    "coordinator": {"connected": True, "session": "sess-%d" % cs["session"]},
                    "catalog": {"state": "live_verified", "release_id": cs["release_id"], "digest": cs["digest"],
                                "signer_key_id": cs["signer"], "policy_version": cs["policy"], "row_identity": "ab" * 32,
                                "source": "baked" if c("canary-baked") else "coordinator",
                                "catalog_key": os.environ["CCR_CANARY_KEY"], "model_id": "org/model"}}
            return self.send(200, json.dumps(body).encode())
        if port == int(os.environ["PROVIDER_PORT"]) and path == "/poolz":
            if not self.authed():
                return self.send(401, b"{}")
            return self.send(200, json.dumps(pool()).encode())
        with lock:
            files = dict(state["files"]); version = state["version"]
        if path == "/gateway/v1/rate-card":  # the gateway's (cached) public card
            body = state.get("boot_card") if c("gateway-stale") else files.get("rate-card.json")
            return self.send(200, body or b"{}", "application/json")
        if path == "/v1/autotune-release":
            return self.send(200, json.dumps({"status": "live_verified", "release_id": version}).encode())
        if path == "/v1/pool/check":
            if not self.authed():
                return self.send(401, b"{}")
            cs = canary()
            return self.send(200, json.dumps({
                "provider_id": os.environ["CCR_CANARY_ID"], "assigned_id": "sess-%d" % cs["session"], "buyer_serving": True,
                "catalog_evidence_source": "provider_reported", "catalog_admission_mode": "current",
                "catalog_release_id": cs["release_id"], "catalog_policy_version": cs["policy"],
                "catalog_candidate_sha256": cs["digest"], "catalog_signer_key_id": cs["signer"],
                "catalog_row_identity": "ab" * 32}).encode())
        base, sig = (path[:-4], ".sig") if path.endswith(".sig") else (path, "")
        name = FEEDS.get(base)
        if name and name + sig in files:
            return self.send(200, files[name + sig], "application/octet-stream")
        self.send(404, b"{}")

class S(socketserver.ThreadingMixIn, http.server.HTTPServer):
    daemon_threads = True
    allow_reuse_address = True

load()
state["boot_card"] = state["files"]["rate-card.json"]
applied("boot")
for p in (os.environ["BUYER_PORT"], os.environ["PROVIDER_PORT"], os.environ["CANARY_PORT"]):
    threading.Thread(target=S(("127.0.0.1", int(p)), H).serve_forever, daemon=True).start()
signal.signal(signal.SIGHUP, on_hup)
signal.signal(signal.SIGUSR1, on_restart)
open(os.path.join(fake, "coordinator.pid"), "w").write(str(os.getpid()))
while True:
    time.sleep(0.2)
STUB

# ---------------------------------------------------------------------------
# The reviewed repository (tooling + committed release) at one commit.
# ---------------------------------------------------------------------------
R="$T/repo"
mkdir -p "$R/scripts/lib" "$R/ops/pearl-updater" "$R/phase3-binary/catalog/autotune" "$R/phase3-binary/dist/static"
cp "$root/scripts/catalog-content-release.sh" "$root/scripts/pearl_autotune_deploy_lock.py" \
   "$root/scripts/catalog-verifier-bundle.txt" "$root/scripts/autotune_window.py" \
   "$root/scripts/openrouter_pricing_engine.py" "$root/scripts/sign-catalog.go" "$R/scripts/"
cp "$root/scripts/lib/autotune-activate.sh" "$root/scripts/lib/catalog-canary-token.sh" \
   "$root/scripts/lib/catalog-window-override.sh" "$root/scripts/lib/coordinator-config-guard.sh" "$R/scripts/lib/"
cp "$root/ops/pearl-updater/catalog-canary-proof.py" "$R/ops/pearl-updater/"
mkdir -p "$R/phase4-coordinator/dist/systemd"
cp "$root/phase4-coordinator/dist/coordinator-pricing-recover" "$R/phase4-coordinator/dist/"
cat >"$R/scripts/catalog-release.py" <<'CR'
#!/usr/bin/env python3
"""Test stub for catalog-release.py: verdicts are driven by $CCR_TEST_CTL files.

content-gate asserts every argument/path the lane passes (the preflight call
and the under-lock call) and logs which one it validated; buyer-serving-set is
the real script's."""
import collections, hashlib, json, os, pathlib, runpy, subprocess, sys

# The pricing-lane pieces the lane (and its on-host stage) call by name.
_REAL = runpy.run_path(os.environ["CCR_REAL_CR"])
for _name in ("PRICING_RESOLVABLE_NAME", "release_model_names", "names_sha256"):
    globals()[_name] = _REAL[_name]

def main():
    ctl = pathlib.Path(os.environ["CCR_TEST_CTL"])
    cmd, args = sys.argv[1], sys.argv[2:]
    def arg(name):
        return args[args.index(name) + 1] if name in args else None
    def refuse(why):
        print("stub content-gate: " + why, file=sys.stderr)
        sys.exit(1)
    def sha(path):
        return hashlib.sha256(open(path, "rb").read()).hexdigest()
    if cmd == "verify-directory":
        sys.exit(1 if (ctl / "verify-fail").exists() else 0)
    if cmd == "check-tier2-binding":
        if (ctl / "closure-fail").exists():
            print("catalog-release: ERROR: serving closure: 1 recommendable rate-carded model(s) have no matching Tier-2", file=sys.stderr)
            sys.exit(1)
        sys.exit(0)
    if cmd in ("buyer-serving-set", "splice-coordinator-rate-card", "extract-coordinator-rate-card-block", "pricing-effective-diff"):
        sys.argv[0] = os.environ["CCR_REAL_CR"]
        runpy.run_path(os.environ["CCR_REAL_CR"], run_name="__main__")
    def check_index(path, want_path, stage):
        # The Tier-2 content index must be the one tier2-content-index built
        # from the reviewed commit, at the expected location for each phase.
        if path is None or os.path.normpath(path) != os.path.normpath(want_path):
            refuse("%s --tier2-content-index must be %r, got %r" % (stage, want_path, path))
        if not (ctl / "t2index.sha").exists() or sha(path) != (ctl / "t2index.sha").read_text():
            refuse("%s Tier-2 content index bytes are not the reviewed commit's" % stage)
        with open(ctl / "t2index-calls.log", "a") as fh:
            fh.write(stage + "\n")
    if cmd == "tier2-content-index":
        if arg("--rev") != os.environ["CCR_EXPECT_COMMIT"] or not arg("--repo") or not arg("--ledger"):
            refuse("tier2-content-index must walk the reviewed commit: %r" % args)
        if sha(arg("--ledger")) != os.environ["CCR_EXPECT_LEDGER_SHA"]:
            refuse("tier2-content-index --ledger is not the commit's ledger")
        body = json.dumps({"stub-index": arg("--rev")}, sort_keys=True)
        (ctl / "t2index.sha").write_text(hashlib.sha256(body.encode()).hexdigest())
        sys.stdout.write(body)
        sys.exit(0)
    if cmd == "compare-live":
        check_index(arg("--tier2-content-index"),
                    os.path.join(os.path.dirname(arg("--ledger") or "."), "tier2-content-index.json"), "compare-live")
        live = json.loads((pathlib.Path(arg("--live")) / "release.json").read_text())
        rel = json.loads((pathlib.Path(arg("--incoming")) / "release.json").read_text())
        if (ctl / "compare-regression").exists():
            print(json.dumps({"verdict": "regression", "reasons": ["stub"], "live_release_id": live["release_id"],
                              "incoming_release_id": rel["release_id"]}))
            sys.exit(3)
        print(json.dumps({"verdict": "descends", "reasons": ["stub"], "matched_ledger_release": live["release_id"],
                          "live_release_id": live["release_id"], "incoming_release_id": rel["release_id"]}))
        sys.exit(0)
    if cmd == "content-gate":
        release, live_dir, ledger, commit = arg("--release"), arg("--live"), arg("--ledger"), arg("--commit")
        if not release or not live_dir:
            refuse("--release and --live are required")
        rel = json.loads((pathlib.Path(release) / "release.json").read_text())
        live = json.loads((pathlib.Path(live_dir) / "release.json").read_text())
        if rel["release_id"] != os.environ["CCR_EXPECT_REL_ID"]:
            refuse("--release is %s, not the reviewed release" % rel["release_id"])
        if live["release_id"] != os.environ["CCR_EXPECT_LIVE_ID"]:
            refuse("--live is %s, not the live release" % live["release_id"])
        if commit is not None:
            if ledger is not None or commit != os.environ["CCR_EXPECT_COMMIT"]:
                refuse("preflight call must pass exactly the reviewed --commit")
            if os.path.basename(release) != "release" or os.path.basename(live_dir) != "live":
                refuse("preflight call must judge the assembled release against the fetched live release")
            stage = "preflight"
            check_index(arg("--tier2-content-index"), os.path.join(os.path.dirname(release), "gate", "tier2-content-index.json"), stage)
        else:
            here = os.path.dirname(os.path.abspath(__file__))
            catalog = os.path.normpath(os.path.join(here, "..", "phase3-binary", "catalog", "autotune"))
            want_live = os.path.join(os.environ["CCR_FAKE"], "opt/macprovider/autotune/current")
            releases = os.path.join(os.environ["CCR_FAKE"], "opt/macprovider/autotune/releases")
            if ledger is None or os.path.normpath(ledger) != os.path.join(catalog, "release-ledger.json"):
                refuse("under-lock --ledger must be the shipped commit ledger, got %r" % ledger)
            if sha(ledger) != os.environ["CCR_EXPECT_LEDGER_SHA"]:
                refuse("under-lock ledger bytes are not the commit's")
            exclusions = os.path.join(catalog, "not-buyer-serving.json")
            if not os.path.isfile(exclusions) or sha(exclusions) != os.environ["CCR_EXPECT_EXCL_SHA"]:
                refuse("under-lock exclusions beside the verifier are not the commit's")
            if live_dir != want_live:
                refuse("under-lock --live must be the live current, got %r" % live_dir)
            if os.path.dirname(release) != releases or not os.path.basename(release).startswith(".incoming-"):
                refuse("under-lock --release must be the staged incoming dir, got %r" % release)
            stage = "under-lock"
            check_index(arg("--tier2-content-index"), os.path.join(here, "..", "tier2-content-index.json"), stage)
        with open(ctl / "gate-calls.log", "a") as fh:
            fh.write(stage + " ok\n")
        lane = (ctl / "lane").read_text().strip() if (ctl / "lane").exists() else "catalog-content"
        ok = lane == "catalog-content" and not (ctl / "closure-fail").exists()
        reasons = [] if ok else ["stub: lane " + lane] if lane != "catalog-content" else ["serving closure: 1 recommendable rate-carded model(s) have no matching Tier-2 pin"]
        # #1693: the REAL pricing scope and commit-block binding.
        by_lane = collections.defaultdict(list)
        repo = pathlib.Path(__file__).resolve().parents[1]
        if commit is not None:
            ack = subprocess.run(["git", "-C", str(repo), "show", commit + ":phase3-binary/catalog/autotune/acknowledged-pricing-moves.json"],
                                 capture_output=True).stdout or None
        else:
            ack = open(arg("--acknowledged-moves"), "rb").read() if arg("--acknowledged-moves") else None
        diff = open(arg("--pricing-diff"), "rb").read() if arg("--pricing-diff") else None
        pricing = _REAL["_content_gate_pricing"](pathlib.Path(release), pathlib.Path(live_dir), by_lane, ack, diff, arg("--pricing-diff-sha256"))
        block = None
        if any(pricing.values()):
            if stage == "under-lock" and (ack is None or diff is None):
                refuse("under-lock pricing gate must bind --acknowledged-moves and --pricing-diff")
            if commit is not None:
                block, why = _REAL["content_gate_commit_block"](pathlib.Path(release), commit, repo)
                by_lane["unverified-commit"].extend(why)
        for name in ("unverified-commit", "invalid-release", "pricing-globals", "pricing-unacked-move"):
            if by_lane[name] and ok:
                ok, lane, reasons = False, name, list(by_lane[name])
        print(json.dumps({"ok": ok, "lane": lane, "reasons": reasons,
                          "release_id": rel["release_id"], "live_release_id": live["release_id"], "changed": {},
                          "pricing": pricing, "commit_block_sha256": block,
                          "pricing_diff_sha256": arg("--pricing-diff-sha256") if diff is not None else None}))
        sys.exit(0 if ok else 3)
    sys.exit(0)

if __name__ == "__main__":
    main()
CR
cp "$root/phase3-binary/catalog/autotune/"{release.json,trusted-keys.json,tier2-catalog.json,release-ledger.json,not-buyer-serving.json,acknowledged-pricing-moves.json} "$R/phase3-binary/catalog/autotune/"
# #1693: the tracked coordinator yaml (its rate_card block is what a pricing
# release installs), the pricing helper/units and the guard-bearing writers
# the L2 preflight hashes against their Pearl-installed copies.
cp "$root/phase4-coordinator/dist/coordinator.yaml" "$root/phase4-coordinator/dist/coordinator-deploy-recover.sh" "$R/phase4-coordinator/dist/"
cp "$root/phase4-coordinator/dist/systemd/macprovider-coordinator-deploy-recovery.service" \
   "$root/phase4-coordinator/dist/systemd/macprovider-coordinator-deploy-guard.conf" \
   "$root/phase4-coordinator/dist/systemd/macprovider-coordinator-pricing-close.service" "$R/phase4-coordinator/dist/systemd/"
cp "$root/scripts/pricing-lane-installed-writers.txt" "$R/scripts/"
cp "$root/scripts/lib/coordinator_config_guard.py" "$R/scripts/lib/"
cp "$root/ops/pearl-updater/macprovider-pearl-update" "$root/ops/pearl-updater/macprovider-tier2-enforcement-watchdog" "$R/ops/pearl-updater/"
cp "$root/phase3-binary/dist/static/"*.json "$root/phase3-binary/dist/static/"*.sig "$R/phase3-binary/dist/static/"

# The canary serves the first recommendable row; fixtures edit around it.
CANARY_KEY="$(python3 -c 'import json,sys;r=json.load(open(sys.argv[1]))["rows"];print(next(k for k,v in r.items() if v["runtime_status"]=="recommendable"))' "$R/phase3-binary/dist/static/autotune-candidates.json")"
export CCR_CANARY_KEY="$CANARY_KEY" CCR_CANARY_ID="$CANARY_ID" CCR_OPKEY="$OPKEY"

# retarget <dir> <release_id> <candidate-mutation>: new release id + candidate
# bytes, with release.json bound to the new candidate digest.
retarget() {
  python3 - "$1" "$2" "$3" "$CANARY_KEY" <<'PY'
import hashlib, json, pathlib, sys
d, rid, mutation, key = pathlib.Path(sys.argv[1]), sys.argv[2], sys.argv[3], sys.argv[4]
cand_path = d / "autotune-candidates.json" if (d / "autotune-candidates.json").exists() else d / "../../dist/static/autotune-candidates.json"
cand = json.loads(cand_path.read_bytes())
cand["version"] = rid
if mutation == "row-hash":
    cand["rows"][key]["model_sha256"] = "ef" * 32
raw = (json.dumps(cand, indent=2, sort_keys=True) + "\n").encode()
cand_path.write_bytes(raw)
m = json.loads((d / "release.json").read_bytes())
m["release_id"] = rid
m["feeds"]["autotune-candidates.json"]["sha256"] = hashlib.sha256(raw).hexdigest()
(d / "release.json").write_text(json.dumps(m, indent=2, sort_keys=True) + "\n")
PY
}
# History: the reviewed commit that produced the LIVE release (its
# not-buyer-serving.json is what evidence (e) judges live with), then the new one.
export GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@example.invalid GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@example.invalid
retarget "$R/phase3-binary/catalog/autotune" test-live-v1 none
git -C "$R" init -q
git -C "$R" add -A
git -C "$R" commit -qm "live catalog content"
LIVE_COMMIT="$(git -C "$R" rev-parse HEAD)"
retarget "$R/phase3-binary/catalog/autotune" test-new-v1 row-hash
git -C "$R" add -A
git -C "$R" commit -qm "reviewed catalog content"
COMMIT="$(git -C "$R" rev-parse HEAD)"
git -C "$R" update-ref refs/remotes/origin/main "$COMMIT"
export CCR_REAL_CR="$root/scripts/catalog-release.py" CCR_EXPECT_COMMIT="$COMMIT" \
  CCR_EXPECT_REL_ID=test-new-v1 CCR_EXPECT_LIVE_ID=test-live-v1
CCR_EXPECT_LEDGER_SHA="$(shasum -a 256 "$R/phase3-binary/catalog/autotune/release-ledger.json" | cut -d' ' -f1)"
CCR_EXPECT_EXCL_SHA="$(shasum -a 256 "$R/phase3-binary/catalog/autotune/not-buyer-serving.json" | cut -d' ' -f1)"
export CCR_EXPECT_LEDGER_SHA CCR_EXPECT_EXCL_SHA
# A later origin/main commit that re-commits the live release with the given
# not-buyer-serving.json (the newest such commit is what (e) must use).
recommit_live_exclusions() { # <not-buyer-serving.json>
  local idx="$T/live-index" blob_rel blob_ex tree c
  rm -f "$idx"
  GIT_INDEX_FILE="$idx" git -C "$R" read-tree refs/remotes/origin/main
  blob_rel="$(git -C "$R" show "$LIVE_COMMIT:phase3-binary/catalog/autotune/release.json" | git -C "$R" hash-object -w --stdin)"
  blob_ex="$(git -C "$R" hash-object -w "$1")"
  GIT_INDEX_FILE="$idx" git -C "$R" update-index --cacheinfo "100644,$blob_rel,phase3-binary/catalog/autotune/release.json"
  GIT_INDEX_FILE="$idx" git -C "$R" update-index --cacheinfo "100644,$blob_ex,phase3-binary/catalog/autotune/not-buyer-serving.json"
  tree="$(GIT_INDEX_FILE="$idx" git -C "$R" write-tree)"
  c="$(git -C "$R" commit-tree "$tree" -p refs/remotes/origin/main -m "live catalog re-committed")"
  git -C "$R" update-ref refs/remotes/origin/main "$c"
}
NEW_CAND="$(python3 -c 'import json,sys;print(json.load(open(sys.argv[1]))["feeds"]["autotune-candidates.json"]["sha256"])' "$R/phase3-binary/catalog/autotune/release.json")"

# #1693: yaml <-> card parity shared by the coordinator stub and the dry-load stub.
export CCR_T="$T"
cat >"$T/stubparity.py" <<'PY'
import hashlib, json, os, runpy
_cr = runpy.run_path(os.environ["CCR_REAL_CR"])
rate_row_for = _cr["rate_row_for"]
block_span = _cr["coordinator_rate_card_block_span"]
def yaml_rows(path):
    return _cr["coordinator_credit_rows"](open(path, encoding="utf-8").read())
def card_rows(path):
    return _cr["pricing_credit_rows"](json.load(open(path))["rows"])
def rate_table_sha(rows):
    return hashlib.sha256(json.dumps(rows, sort_keys=True).encode()).hexdigest()
PY
# Pricing commits on top of COMMIT (same release id, rate-card rows changed):
#   PRICE_COMMIT   qwen3-32b completion 220000 -> 230000 (card + tracked yaml)
#   BADBLOCK_COMMIT the card changes but the tracked yaml block does not
#   MOVE_COMMIT    adds row foo-model (acknowledged for the key itself only)
price_commit() { # <label> <mode>
  python3 - "$R" "$2" <<'PY'
import hashlib, json, pathlib, sys
r, mode = pathlib.Path(sys.argv[1]), sys.argv[2]
card_p = r / "phase3-binary/dist/static/rate-card.json"
yaml_p = r / "phase4-coordinator/dist/coordinator.yaml"
card = json.loads(card_p.read_bytes())
yaml = yaml_p.read_text()
if mode in ("price", "badblock"):
    card["rows"]["qwen3-32b"]["completion_rate_per_mtok"] = 230000
    if mode == "price":
        head, _, tail = yaml.partition("    qwen3-32b:\n")
        assert tail and "completion_credits_per_mtok: 220000" in tail
        yaml = head + "    qwen3-32b:\n" + tail.replace("completion_credits_per_mtok: 220000", "completion_credits_per_mtok: 230000", 1)
elif mode == "move":
    row = dict(card["rows"]["default"], prompt_rate_per_mtok=70000, prompt_cache_hit_rate_per_mtok=17500, completion_rate_per_mtok=140000)
    card["rows"]["foo-model"] = row
    yaml = yaml.replace("    default:\n", "    foo-model:\n      prompt_credits_per_mtok: 70000\n"
                        "      prompt_cache_hit_credits_per_mtok: 17500\n      completion_credits_per_mtok: 140000\n    default:\n", 1)
    ack_p = r / "phase3-binary/catalog/autotune/acknowledged-pricing-moves.json"
    ack = json.loads(ack_p.read_bytes())
    ack["moves"] = [{"model": "foo-model", "from_row": "default", "to_row": "foo-model"}]
    ack_p.write_text(json.dumps(ack, indent=2) + "\n")
import os, runpy
card["version"] = runpy.run_path(os.environ["CCR_REAL_CR"])["rate_card_projection_hash"](card)
raw = (json.dumps(card, indent=2, sort_keys=True) + "\n").encode()
card_p.write_bytes(raw)
yaml_p.write_text(yaml)
m_p = r / "phase3-binary/catalog/autotune/release.json"
m = json.loads(m_p.read_bytes())
if "rate-card.json" in m.get("feeds", {}):
    m["feeds"]["rate-card.json"]["sha256"] = hashlib.sha256(raw).hexdigest()
    m_p.write_text(json.dumps(m, indent=2, sort_keys=True) + "\n")
PY
  git -C "$R" add -A
  git -C "$R" commit -qm "$1"
  git -C "$R" rev-parse HEAD
}
PRICE_COMMIT="$(price_commit "pricing correction" price)"
git -C "$R" reset -q --hard "$COMMIT"
BADBLOCK_COMMIT="$(price_commit "card without the yaml block" badblock)"
git -C "$R" reset -q --hard "$COMMIT"
MOVE_COMMIT="$(price_commit "added row" move)"
git -C "$R" reset -q --hard "$COMMIT"

# ---------------------------------------------------------------------------
# One fresh fake Pearl + canary per case.
# ---------------------------------------------------------------------------
setup_env() {
  [ -z "$STUB_PID" ] || { kill "$STUB_PID" 2>/dev/null || true; wait "$STUB_PID" 2>/dev/null || true; STUB_PID=""; }
  local E="$T/env"
  rm -rf "$E"; mkdir -p "$E"
  export CCR_FAKE="$E/fake" CCR_TEST_CTL="$E/ctl" CCR_RTMP="$E/rtmp" CCR_CANARY_HOME="$E/canary"
  mkdir -p "$CCR_FAKE/run/lock" "$CCR_FAKE/var/lib" "$CCR_FAKE/etc/macprovider" "$CCR_FAKE/tmp" "$CCR_TEST_CTL" "$CCR_RTMP"
  chmod 0755 "$CCR_RTMP"
  export CCR_GID; CCR_GID="$(python3 -c 'import os,sys;print(os.stat(sys.argv[1]).st_gid)' "$CCR_FAKE")"
  local A="$CCR_FAKE/opt/macprovider/autotune" rel
  mkdir -p "$A/releases"
  chmod 0755 "$CCR_FAKE/opt" "$CCR_FAKE/opt/macprovider"
  for rel in test-prev-v1 test-live-v1; do
    mkdir -p "$A/releases/$rel-0000000000000000"
    cp "$root/phase3-binary/catalog/autotune/"{release.json,trusted-keys.json,tier2-catalog.json} "$A/releases/$rel-0000000000000000/"
    cp "$root/phase3-binary/dist/static/"*.json "$root/phase3-binary/dist/static/"*.sig "$A/releases/$rel-0000000000000000/"
    retarget "$A/releases/$rel-0000000000000000" "$rel" none
  done
  ln -s releases/test-live-v1-0000000000000000 "$A/current"
  printf 'releases/test-prev-v1-0000000000000000\n' >"$A/.previous-target"
  # The live base yaml is the tracked yaml the live release was cut with: its
  # rate_card is in parity with the live card (the stub checks it on every HUP).
  git -C "$R" show "$LIVE_COMMIT:phase4-coordinator/dist/coordinator.yaml" >"$CCR_FAKE/opt/macprovider/coordinator.yaml"
  chmod 0640 "$CCR_FAKE/opt/macprovider/coordinator.yaml"
  touch -t 202001010000 "$CCR_FAKE/opt/macprovider/coordinator.yaml"
  printf 'PATH=/usr/bin\0OPERATOR_KEY=%s\0' "$OPKEY" >"$CCR_FAKE/proc-environ"
  echo boot-1 >"$CCR_FAKE/boot_id"
  # #1693: the Pearl-installed pricing helper/units and guard-bearing writers
  # (the commit's bytes), and a request log with served model names.
  local line installed repo_path
  while IFS= read -r line; do
    installed="${line%%=*}"; repo_path="${line#*=}"
    mkdir -p "$CCR_FAKE$(dirname "$installed")"; cp "$R/$repo_path" "$CCR_FAKE$installed"
  done <<LIST
/opt/macprovider/coordinator-pricing-recover=phase4-coordinator/dist/coordinator-pricing-recover
/etc/systemd/system/macprovider-coordinator-deploy-recovery.service=phase4-coordinator/dist/systemd/macprovider-coordinator-deploy-recovery.service
/etc/systemd/system/macprovider-coordinator.service.d/10-deploy-transaction-guard.conf=phase4-coordinator/dist/systemd/macprovider-coordinator-deploy-guard.conf
/etc/systemd/system/macprovider-coordinator-pricing-close.service=phase4-coordinator/dist/systemd/macprovider-coordinator-pricing-close.service
LIST
  while read -r installed repo_path; do
    case "$installed" in ''|'#'*) continue ;; esac
    mkdir -p "$CCR_FAKE$(dirname "$installed")"; cp "$R/$repo_path" "$CCR_FAKE$installed"
  done <"$R/scripts/pricing-lane-installed-writers.txt"
  chmod 0755 "$CCR_FAKE/opt/macprovider"
  mkdir -p "$CCR_FAKE/var/lib/macprovider" "$CCR_FAKE/var/lib/macprovider-pearl-updater"
  python3 - "$CCR_FAKE/var/lib/macprovider/request-log.sqlite" <<'PY'
import datetime, sqlite3, sys
con = sqlite3.connect(sys.argv[1])
con.execute("CREATE TABLE request_log (id INTEGER PRIMARY KEY, ts_utc TEXT NOT NULL, model TEXT NOT NULL)")
now = datetime.datetime.now(datetime.timezone.utc)
recent = (now - datetime.timedelta(days=2)).strftime("%Y-%m-%dT%H:%M:%S.%fZ")
old = (now - datetime.timedelta(days=45)).strftime("%Y-%m-%dT%H:%M:%S.%fZ")
for ts, model in ((recent, "qwen3-32b"), (recent, "mlx-community/Qwen3-32B-4bit"), (recent, "weird name\x01with control"),
                  (old, "ancient-model")):
    con.execute("INSERT INTO request_log (ts_utc, model) VALUES (?, ?)", (ts, model))
con.commit()
PY
  printf '%s\n' "$(( $(date +%s) - 100 ))" >"$CCR_FAKE/start"
  : >"$CCR_FAKE/journal.log"
  # Offline dry-load: the live binary's --validate-autotune-release verdict.
  cat >"$CCR_FAKE/opt/macprovider/coordinator" <<'COORD'
#!/usr/bin/env python3
import hashlib, json, os, sys
args = sys.argv[1:]
d = args[args.index("--validate-autotune-release") + 1]
prev = open(args[args.index("--previous-target") + 1]).read().split()
m = json.load(open(os.path.join(d, "release.json")))
t2 = open(os.path.join(d, "tier2-catalog.json"), "rb").read()
ctl = os.environ["CCR_TEST_CTL"]
sys.stderr = open(os.path.join(ctl, "dryload.stderr"), "a")  # surfaced by fail()
with open(os.path.join(ctl, "dryload-calls"), "a") as fh:
    fh.write("call\n")
calls = len(open(os.path.join(ctl, "dryload-calls")).read().split())
fail_from = os.path.join(ctl, "dryload-fail-from")
bad = os.path.exists(os.path.join(ctl, "dryload-fail")) or (os.path.exists(fail_from) and calls >= int(open(fail_from).read()))
def sha(p):
    return hashlib.sha256(open(p, "rb").read()).hexdigest()
config_sha = sha(args[args.index("--config") + 1])
overlay_sha = sha(args[args.index("--config-overlay") + 1]) if "--config-overlay" in args else ""
# #1693 C2: parity of the decoded config's rate_card against the release card,
# --expect-base-equivalent and --resolve-model-names, and the verdict digests.
sys.path.insert(0, os.environ["CCR_T"])
import stubparity
errors = []
config_path = args[args.index("--config") + 1]
cand_rows = stubparity.yaml_rows(config_path)
card_rows = stubparity.card_rows(os.path.join(d, "rate-card.json"))
if os.path.exists(os.path.join(ctl, "dryload-parity-skew")):
    card_rows = dict(card_rows, default=dict(card_rows["default"], completion_rate_per_mtok=1))
if cand_rows != card_rows:
    errors.append("runtime economics: rate-card parity mismatch")
resolutions = []
if "--expect-base-equivalent" in args:
    live_path = args[args.index("--expect-base-equivalent") + 1]
    lb, cb = open(live_path, "rb").read(), open(config_path, "rb").read()
    (ls_, le), (cs, ce) = stubparity.block_span(lb, "live"), stubparity.block_span(cb, "cand")
    if lb[:ls_] + lb[le:] != cb[:cs] + cb[ce:]:
        errors.append("base_not_equivalent: (outside rewards.rate_card)")
    if "--resolve-model-names" in args:
        live_rows = stubparity.yaml_rows(live_path)
        for n in json.load(open(args[args.index("--resolve-model-names") + 1])):
            o, nw = stubparity.rate_row_for(live_rows, n), stubparity.rate_row_for(cand_rows, n)
            resolutions.append({"name": n, "old": {"row_key": o}, "new": {"row_key": nw}})
bad = bad or bool(errors)
# admitted: current + every retained entry, as the ws admission map keeps them.
sroot = os.path.dirname(args[args.index("--previous-target") + 1])
def ident(rel_dir):
    r = json.load(open(os.path.join(rel_dir, "release.json")))
    return r["release_id"], r["feeds"]["autotune-candidates.json"]["sha256"].lower()
admitted = [dict(zip(("release_id", "candidates_sha256"), ident(d)), source="current")]
for p in prev:
    rid, sha = ident(os.path.join(sroot, p))
    if all(a["candidates_sha256"] != sha for a in admitted):
        admitted.append({"release_id": rid, "candidates_sha256": sha, "source": "retained"})
print(json.dumps({"ok": not bad, "release_id": m["release_id"], "candidates_sha256": m["feeds"]["autotune-candidates.json"]["sha256"],
                  "tier2_catalog_id": json.loads(t2)["catalog_id"], "tier2_sha256": hashlib.sha256(t2).hexdigest(),
                  "config_sha256": config_sha, "overlay_sha256": overlay_sha,
                  "previous_loaded": [{"release_id": p} for p in prev], "admitted": [] if bad else admitted,
                  "rate_table_sha256": stubparity.rate_table_sha(cand_rows), "signed_rate_card_sha256": hashlib.sha256(open(os.path.join(d, "rate-card.json"), "rb").read()).hexdigest(),
                  "model_resolutions": resolutions,
                  "errors": (errors or ["tier2: stub reject"]) if bad else [], "notes": []}))
sys.exit(1 if bad else 0)
COORD
  chmod 0755 "$CCR_FAKE/opt/macprovider/coordinator"
  # Canary Mac home.
  local H="$CCR_CANARY_HOME"
  mkdir -p "$H/.config/macprovider" "$H/Library/LaunchAgents" "$H/macprovider/catalog-release"
  printf '%s\n' "$CANARY_ID" >"$H/.config/macprovider/provider_id"
  printf 'port: %s\n' "$CANARY_PORT" >"$H/.config/macprovider/config.yaml"
  printf '#!/bin/sh\necho "$*" >> "$CCR_TEST_CTL/canary-cli.log"\n' >"$H/macprovider/macprovider-cli"
  chmod 0755 "$H/macprovider/macprovider-cli"
  for f in release.json trusted-keys.json tier2-catalog.json rate-card.json rate-card.json.sig autotune-candidates.json autotune-candidates.json.sig demand-rank.json demand-rank.json.sig; do
    printf 'x\n' >"$H/macprovider/catalog-release/$f"
  done
  python3 - "$H" <<'PY'
import os, plistlib, sys
h = sys.argv[1]
plistlib.dump({"Label": "live.malibu.provider", "ProgramArguments": [os.path.join(h, "macprovider/macprovider-cli"), "serve", "--config", os.path.join(h, ".config/macprovider/config.yaml")]},
              open(os.path.join(h, "Library/LaunchAgents/live.malibu.provider.plist"), "wb"))
PY
  mkdir -p "$E/keys"; printf 'k\n' >"$E/keys/canary"; chmod 0600 "$E/keys/canary"
  python3 "$T/coordinator-stub.py" >"$E/stub.log" 2>&1 &
  STUB_PID=$!
  for _ in $(seq 1 100); do [ -s "$CCR_FAKE/coordinator.pid" ] && [ -s "$CCR_FAKE/served.json" ] && break; sleep 0.1; done
  python3 -c 'import json,sys;s=json.load(open(sys.argv[1]));s["session"]=1;json.dump(s,open(sys.argv[2],"w"))' "$CCR_FAKE/served.json" "$CCR_TEST_CTL/canary-state.json"
  export PEARL_SSH=pearl CATALOG_CANARY_PROVIDER_ID="$CANARY_ID" CATALOG_CANARY_SSH_TARGET=canary.test \
    CATALOG_CANARY_SSH_KEY="$E/keys/canary" CATALOG_CANARY_AUTH_TOKEN="$OPKEY" \
    CATALOG_CANARY_AUTH_TOKEN_KEYCHAIN_SERVICE="" \
    CATALOG_EVIDENCE_WATCH_SECONDS=2 CATALOG_EVIDENCE_POLL_SECONDS=1 CATALOG_CANARY_RECOVERY_SECONDS=3 \
    CATALOG_EVIDENCE_SETTLE_SECONDS=3
  unset CATALOG_WINDOW_OVERRIDE_REASON
  A_ROOT="$A"
}

run() { # <mode>; rc in RC, stdout in $T/out, stderr in $T/err
  RC=0
  (cd "$R" && bash scripts/catalog-content-release.sh "--$1" --commit "$COMMIT") >"$T/out" 2>"$T/err" || RC=$?
}
verdict_check() { # <check> -> prints true/false for its ok
  python3 -c 'import json,sys;v=json.loads(open(sys.argv[1]).readline());print(str(next(c["ok"] for c in v["checks"] if c["name"]==sys.argv[2])).lower())' "$T/out" "$1"
}
expect_no_go() { # <label> <check>
  run preflight
  [ "$RC" -eq 3 ] || fail "$1: preflight must be NO_GO (rc=$RC): $(tail -n 5 "$T/err")"
  [ "$(verdict_check "$2")" = false ] || fail "$1: check $2 must fail: $(cat "$T/out")"
  [ "$(readlink "$A_ROOT/current")" = releases/test-live-v1-0000000000000000 ] || fail "$1: preflight mutated current"
  note "ok: NO_GO $1 ($2)"
}
live_unchanged() { # <label>
  [ "$(readlink "$A_ROOT/current")" = releases/test-live-v1-0000000000000000 ] || fail "$1: current not restored: $(readlink "$A_ROOT/current")"
}
window_is() { # <label> <expected, space-separated>
  local got; got="$(tr '\n' ' ' <"$A_ROOT/.previous-target" | sed 's/ $//')"
  [ "$got" = "$2" ] || fail "$1: window is '$got', expected '$2'"
}
NEW_DIR_GLOB="test-new-v1-"

# ---------------------------------------------------------------------------
# Preflight.
# ---------------------------------------------------------------------------
setup_env
run preflight
[ "$RC" -eq 0 ] || fail "preflight GO expected (rc=$RC): $(cat "$T/out") $(tail -n 20 "$T/err")"
[ "$(wc -l <"$T/out" | tr -d ' ')" = 1 ] || fail "preflight must print exactly one JSON line"
python3 - "$T/out" <<'PY' || fail "preflight GO verdict shape: $(cat "$T/out")"
import json, sys
v = json.loads(open(sys.argv[1]).read())
names = [c["name"] for c in v["checks"]]
want = {"commit", "tooling_matches_commit", "release_assembled", "canary_config", "pearl_reachable", "pearl_locks_free",
        "rollback_preconditions", "content_gate", "buyer_serving_e2e", "coordinator_dry_load",
        "window_coverage", "config_applied", "canary_token_operator_key", "canary_reachable"}
assert v["go"] is True and want <= set(names), (v["go"], sorted(want - set(names)))
assert all(c["ok"] for c in v["checks"])
assert "serving_closure" not in names  # content-gate owns the closure check
PY
grep -qF "$OPKEY" "$T/out" "$T/err" && fail "preflight printed the operator bearer"
[ -z "$(ls "$CCR_RTMP")" ] || fail "preflight left its Pearl scratch dir"
note "ok: preflight GO"

setup_env; printf 'pricing\n' >"$CCR_TEST_CTL/lane"; expect_no_go "wrong lane" content_gate
setup_env; touch "$CCR_TEST_CTL/closure-fail"; expect_no_go "closure miss" content_gate
grep -q 'serving closure' "$T/out" || fail "a closure miss must be reported by content_gate: $(cat "$T/out")"
setup_env; touch "$CCR_TEST_CTL/dryload-fail"; expect_no_go "dry-load failure" coordinator_dry_load
setup_env
printf '[{"provider_id":"p9","catalog_release_id":"ghost-release","catalog_candidate_sha256":"%s","hash_status":"hash_verified"}]\n' \
  "$(printf 'ee%.0s' $(seq 1 32))" >"$CCR_TEST_CTL/poolz-extra.json"
expect_no_go "coverage loss" window_coverage
export CATALOG_WINDOW_OVERRIDE_REASON="ghost provider retired per ops ticket"
run preflight
[ "$RC" -eq 0 ] && [ "$(verdict_check window_coverage)" = true ] || fail "coverage override must turn coverage GO (rc=$RC): $(cat "$T/out")"
note "ok: coverage loss GO with a logged override"

# #1688: a deploy that activates under a window coverage override must append
# one durable JSON audit line to Pearl's catalog-window-overrides.jsonl,
# through the same shared scripts/lib/catalog-window-override.sh contract
# deploy-pearl-vps.sh and renew-autotune-static-feed.sh use.
run deploy
[ "$RC" -eq 0 ] || fail "deploy with a logged coverage override must succeed (rc=$RC): $(tail -n 30 "$T/out") $(tail -n 20 "$T/err")"
OVERRIDE_LOG="$CCR_FAKE/var/lib/macprovider/catalog-window-overrides.jsonl"
[ -f "$OVERRIDE_LOG" ] || fail "deploy with override must append to catalog-window-overrides.jsonl"
[ "$(wc -l <"$OVERRIDE_LOG" | tr -d ' ')" = 1 ] || fail "override log must be exactly one line: $(cat "$OVERRIDE_LOG")"
override_mode="$(stat -c '%a' "$OVERRIDE_LOG" 2>/dev/null || stat -f '%Lp' "$OVERRIDE_LOG")"
[ "$override_mode" = 600 ] || fail "override log must be 0600, got $override_mode"
python3 - "$OVERRIDE_LOG" <<'PY' || fail "override record shape: $(cat "$OVERRIDE_LOG")"
import json, sys
rec = json.loads(open(sys.argv[1]).readline())
assert set(rec) == {"kind", "reason", "uncovered", "incoming", "live", "commit", "ts"}, sorted(rec)
assert rec["kind"] == "content_lane_window_coverage", rec
assert rec["reason"] == "ghost provider retired per ops ticket", rec
assert isinstance(rec["uncovered"], list) and rec["uncovered"], rec
assert rec["incoming"].startswith("releases/test-new-v1-"), rec
assert set(rec["live"]) == {"target", "release_id"} and rec["live"]["release_id"] == "test-live-v1", rec
assert rec["commit"], rec
PY
note "ok: deploy with override appends catalog-window-overrides.jsonl"

setup_env; printf '# pending edit\n' >>"$CCR_FAKE/opt/macprovider/coordinator.yaml"; expect_no_go "yaml content drift" config_applied
setup_env
printf '# pending edit, old mtime kept\n' >>"$CCR_FAKE/opt/macprovider/coordinator.yaml"
touch -t 202001010000 "$CCR_FAKE/opt/macprovider/coordinator.yaml"
expect_no_go "yaml drift with a preserved mtime" config_applied
setup_env; printf 'tier2: {}\n' >"$CCR_FAKE/etc/macprovider/coordinator.pearl-overlays.yaml"; expect_no_go "overlay appeared after the last apply" config_applied
setup_env; rm -f "$CCR_FAKE/run/macprovider/coordinator-applied-config.json"; expect_no_go "applied-config record missing" config_applied
grep -q 'applied identity unknown' "$T/out" || fail "a missing applied-config record must say the applied identity is unknown"
setup_env
printf '# local edit\n' >>"$R/scripts/lib/catalog-canary-token.sh"
expect_no_go "working tree vs commit" tooling_matches_commit
git -C "$R" checkout -q -- scripts/lib/catalog-canary-token.sh
setup_env
python3 - "$A_ROOT/releases/test-live-v1-0000000000000000/tier2-catalog.json" "$R/phase3-binary/dist/static/autotune-candidates.json" <<'PY'
import json, sys
t2 = json.load(open(sys.argv[1]))
rows = json.load(open(sys.argv[2]))["rows"]
serving = {(r["model_id"].lower(), str(r.get("model_sha256", "")).lower()) for r in rows.values() if r["runtime_status"] == "recommendable"}
drop = next(m for m in t2["models"] if (m["model_id"].lower(), m["sha256"].lower()) in serving)
t2["models"].remove(drop)
json.dump(t2, open(sys.argv[1], "w"), indent=2)
PY
expect_no_go "new buyer-serving Tier-2 pin (e)" buyer_serving_e2e
# A serving model other than the canary's row (the canary row's hash changes).
read -r SERVING_KEY SERVING_MODEL <<EOF_SERVING
$(python3 - "$R/phase3-binary/dist/static/autotune-candidates.json" "$R/phase3-binary/catalog/autotune/tier2-catalog.json" "$CANARY_KEY" <<'PY'
import json, sys
rows = json.load(open(sys.argv[1]))["rows"]
pins = {m["model_id"].lower(): m["sha256"] for m in json.load(open(sys.argv[2]))["models"]}
k = next(k for k, v in sorted(rows.items()) if k != sys.argv[3] and v["runtime_status"] == "recommendable"
         and pins.get(v["model_id"].lower()) == v.get("model_sha256"))
print(k, rows[k]["model_id"])
PY
)
EOF_SERVING
LIVE_REL_DIR() { printf '%s' "$A_ROOT/releases/test-live-v1-0000000000000000"; }
setup_env
python3 - "$(LIVE_REL_DIR)/autotune-candidates.json" "$SERVING_KEY" <<'PY'
import json, sys
c = json.load(open(sys.argv[1])); c["rows"][sys.argv[2]]["runtime_status"] = "listed"
open(sys.argv[1], "w").write(json.dumps(c, indent=2, sort_keys=True) + "\n")
PY
expect_no_go "listed -> recommendable (e)" buyer_serving_e2e
grep -q "$SERVING_MODEL (added)" "$T/out" || fail "listed -> recommendable must name the added model: $(cat "$T/out")"
setup_env
python3 - "$(LIVE_REL_DIR)" "$SERVING_KEY" "$SERVING_MODEL" <<'PY'
import json, sys
d, key, model = sys.argv[1:]
c = json.load(open(d + "/autotune-candidates.json")); c["rows"][key]["model_sha256"] = "aa" * 32
open(d + "/autotune-candidates.json", "w").write(json.dumps(c, indent=2, sort_keys=True) + "\n")
t2 = json.load(open(d + "/tier2-catalog.json"))
for m in t2["models"]:
    if m["model_id"].lower() == model.lower():
        m["sha256"] = "aa" * 32
json.dump(t2, open(d + "/tier2-catalog.json", "w"), indent=2)
PY
expect_no_go "serving model hash changed (e)" buyer_serving_e2e
grep -q "$SERVING_MODEL (sha changed)" "$T/out" || fail "a re-hashed serving model must be named: $(cat "$T/out")"
setup_env
python3 - "$SERVING_MODEL" >"$T/live-exclusions.json" <<'PY'
import json, sys
print(json.dumps({"schema_version": "macprovider.not-buyer-serving.v1", "models": [{"model_id": sys.argv[1], "reason": "test"}]}))
PY
recommit_live_exclusions "$T/live-exclusions.json"
# Exclusions add no routing predicate (catalog-release.py buyer_serving_set):
# a model the live release pins was serving despite its exclusion, so dropping
# the exclusion makes nothing newly buyer-serving.
run preflight
[ "$RC" -eq 0 ] && [ "$(verdict_check buyer_serving_e2e)" = true ] ||
  fail "a dropped exclusion of a pinned model must not count as newly buyer-serving (rc=$RC): $(cat "$T/out")"
note "ok: GO when a live exclusion of a pinned model is dropped (e)"
git -C "$R" update-ref refs/remotes/origin/main "$COMMIT"
setup_env; touch "$CCR_TEST_CTL/compare-regression"; expect_no_go "live release matches no reviewed commit (e)" buyer_serving_e2e

# ---------------------------------------------------------------------------
# Deploy.
# ---------------------------------------------------------------------------
setup_env
unset CATALOG_CANARY_PROVIDER_ID
run deploy
[ "$RC" -eq 3 ] || fail "deploy without canary evidence must refuse with NO_GO (rc=$RC)"
live_unchanged "no canary"
[ -z "$(ls "$A_ROOT/releases" | grep "$NEW_DIR_GLOB" || true)" ] || fail "no-canary refusal staged a release"
note "ok: deploy refused without canary evidence"

setup_env
run deploy
[ "$RC" -eq 0 ] || fail "deploy happy path (rc=$RC): $(tail -n 30 "$T/out") $(tail -n 20 "$T/err")"
new_target="$(readlink "$A_ROOT/current")"
case "$new_target" in releases/test-new-v1-[0-9a-f]*) ;; *) fail "current not activated: $new_target" ;; esac
window_is "happy path" "releases/test-live-v1-0000000000000000 releases/test-prev-v1-0000000000000000"
grep -q '"autotune_catalog_version": "test-new-v1"' "$CCR_FAKE/journal.log" || fail "coordinator never reloaded test-new-v1"
grep -q 'autotune --recommend --apply --drain' "$CCR_TEST_CTL/canary-cli.log" || fail "changed canary row must run autotune --recommend --apply first"
grep -q "\"release_id\": \"test-new-v1\"" "$CCR_TEST_CTL/canary-state.json" || fail "canary not restarted onto test-new-v1"
grep -qF "$OPKEY" "$T/out" "$T/err" && fail "deploy printed the operator bearer"
grep -q '^\[catalog-content\] DONE' "$T/out" || fail "deploy did not report DONE"
[ "$(sort -u "$CCR_TEST_CTL/gate-calls.log" | tr '\n' ' ')" = "preflight ok under-lock ok " ] ||
  fail "content-gate must be called (and validated) in preflight and under the lock: $(cat "$CCR_TEST_CTL/gate-calls.log" 2>/dev/null)"
[ "$(sort -u "$CCR_TEST_CTL/t2index-calls.log" | tr '\n' ' ')" = "compare-live preflight under-lock " ] ||
  fail "the Tier-2 content index must reach compare-live, preflight and under-lock content-gate: $(cat "$CCR_TEST_CTL/t2index-calls.log" 2>/dev/null)"
[ "$(wc -l <"$CCR_TEST_CTL/dryload-calls" | tr -d ' ')" = 3 ] ||
  fail "the live-binary validator must run in preflight, under the lease, and in the publish's under-lock coverage: $(wc -l <"$CCR_TEST_CTL/dryload-calls")"
[ -z "$(ls "$CCR_FAKE/tmp")" ] || fail "the lease runner must remove its work dir when the lease is released"
[ ! -e "$CCR_FAKE/run/lock/macprovider-pearl-updater.lock" ] || python3 - "$CCR_FAKE/run/lock/macprovider-pearl-updater.lock" <<'PY' || fail "deploy did not release the lease"
import fcntl, os, sys
fd = os.open(sys.argv[1], os.O_RDONLY)
fcntl.flock(fd, fcntl.LOCK_EX | fcntl.LOCK_NB)
PY
note "ok: deploy happy path (row hash changed -> --apply, canary on new release)"

rollback_case() { # <label> <ctl file> <expected step> [<expected window>]
  setup_env
  touch "$CCR_TEST_CTL/$2"
  run deploy
  [ "$RC" -eq 4 ] || fail "$1: expected rollback exit 4 (rc=$RC): $(tail -n 30 "$T/out") $(tail -n 10 "$T/err")"
  live_unchanged "$1"
  grep -q "EVIDENCE ($3) FAILED" "$T/out" || fail "$1: evidence ($3) did not fail: $(tail -n 20 "$T/out")"
  window_is "$1" "${4:-releases/test-prev-v1-0000000000000000}"
  grep -q '"autotune_catalog_version": "test-live-v1"' "$CCR_FAKE/journal.log" || fail "$1: rollback re-HUP did not reload the live release"
  note "ok: rollback on evidence ($3) $1"
}
# Under the lease, before any mutation: a dry-load that flips to failure, and
# staged bytes that are not the reviewed commit's, both refuse.
setup_env
printf '2\n' >"$CCR_TEST_CTL/dryload-fail-from"
run deploy
[ "$RC" -eq 1 ] || fail "dry-load failing under the lease must refuse (rc=$RC): $(tail -n 20 "$T/out") $(tail -n 5 "$T/err")"
grep -q 'coordinator dry-load under the lease refused' "$T/err" || fail "under-lease dry-load refusal must say why: $(tail -n 5 "$T/err")"
live_unchanged "under-lease dry-load failure"
[ -z "$(ls -a "$A_ROOT/releases" | grep -e "$NEW_DIR_GLOB" -e '^\.incoming-' || true)" ] || fail "under-lease dry-load refusal staged a release"
note "ok: deploy refuses when the live-binary dry-load fails under the lease"
setup_env
touch "$CCR_TEST_CTL/tamper-upload"
run deploy
[ "$RC" -eq 1 ] || fail "staged bytes differing from the commit must refuse (rc=$RC): $(tail -n 20 "$T/out")"
grep -q 'staged release bytes differ from the reviewed commit' "$T/err" || fail "byte-proof refusal must say why: $(tail -n 5 "$T/err")"
live_unchanged "tampered upload"
[ -z "$(ls "$A_ROOT/releases" | grep "$NEW_DIR_GLOB" || true)" ] || fail "tampered upload was published"
note "ok: deploy refuses staged bytes that are not the reviewed commit's"

rollback_case "served bytes stale" serve-stale a
rollback_case "tier2 digest mismatch in journal" tier2-wrong b
rollback_case "no applied-config record from this HUP" applied-record-stale b
# (c) canary failure: the canary itself adopted the release, so the failed
# release stays retained; the canary is restarted onto the prior release.
setup_env
touch "$CCR_TEST_CTL/canary-baked"
run deploy
[ "$RC" -eq 4 ] || fail "canary: expected rollback exit 4 (rc=$RC): $(tail -n 30 "$T/out")"
live_unchanged "canary"
grep -q "EVIDENCE (c) FAILED" "$T/out" || fail "canary: evidence (c) did not fail"
retained="$(ls "$A_ROOT/releases" | grep "^$NEW_DIR_GLOB" | head -n 1)"
window_is "canary rollback retains the adopted release" "releases/$retained releases/test-prev-v1-0000000000000000"
grep -q 'keeping releases/test-new-v1' "$T/out" || fail "canary: adopted release not retained"
grep -q '"release_id": "test-live-v1"' "$CCR_TEST_CTL/canary-state.json" || fail "canary not restarted onto the prior release"
note "ok: rollback on evidence (c) retains the adopted release and restarts the canary onto the prior release"
# (d): a catalog that was admissible before the HUP (the live release, in the
# validated admitted set) rejected after it fails, even at the same rate as
# before; a chronically inadmissible catalog is logged and passes.
live_key() { python3 -c 'import json,sys;m=json.load(open(sys.argv[1]));print(m["release_id"], m["feeds"]["autotune-candidates.json"]["sha256"])' "$A_ROOT/releases/test-live-v1-0000000000000000/release.json"; }
setup_env
live_key >"$CCR_TEST_CTL/incompat-key"; printf '1\n' >"$CCR_TEST_CTL/incompat-after-count"
run deploy
[ "$RC" -eq 4 ] && grep -q "EVIDENCE (d) FAILED" "$T/out" && grep -q 'catalog_incompatible after the HUP for catalog(s) admissible before it: test-live-v1/' "$T/out" ||
  fail "a rejection of an admissible catalog must fail (d) (rc=$RC): $(tail -n 20 "$T/out")"
live_unchanged "admissible key rejected"
window_is "admissible key rejected" "releases/test-prev-v1-0000000000000000"
note "ok: rollback on evidence (d) for a rejection of a catalog admissible before the HUP"
setup_env
live_key >"$CCR_TEST_CTL/incompat-key"; touch "$CCR_TEST_CTL/journal-before-hup"; printf '1\n' >"$CCR_TEST_CTL/incompat-after-count"
run deploy
[ "$RC" -eq 4 ] && grep -q "EVIDENCE (d) FAILED" "$T/out" && grep -q 'admissible before it: test-live-v1/' "$T/out" ||
  fail "one rejection of an admissible catalog before and one after the HUP must fail (d) (rc=$RC): $(tail -n 20 "$T/out")"
live_unchanged "admissible key same rate"
note "ok: rollback on evidence (d) for an admissible catalog rejected at an unchanged rate"
setup_env
touch "$CCR_TEST_CTL/journal-before-hup"; printf '1\n' >"$CCR_TEST_CTL/incompat-after-count"
run deploy
[ "$RC" -eq 0 ] || fail "a chronically inadmissible catalog must not fail (d) (rc=$RC): $(tail -n 20 "$T/out")"
grep -q 'diagnostic only, not a failure: catalog_incompatible chronic (already inadmissible before the HUP): chronic-release/' "$T/out" ||
  fail "a chronic rejection must be logged for diagnostics: $(tail -n 20 "$T/out")"
note "ok: a chronically inadmissible catalog passes (d) and is logged"
rollback_case "catalog-unavailable increase" poolz-unavailable-after-hup d

# Rollback re-HUP rejected -> alert + controlled restart.
setup_env
touch "$CCR_TEST_CTL/serve-stale"; printf 'test-live-v1\n' >"$CCR_TEST_CTL/reject-version"
run deploy
[ "$RC" -eq 4 ] || fail "rollback-HUP-rejected: expected 4 after a successful controlled restart (rc=$RC): $(tail -n 30 "$T/out")"
grep -q 'ALERT: the rollback re-HUP was rejected' "$T/out" || fail "rollback-HUP-rejected: no alert"
grep -q 'coordinator started' "$CCR_FAKE/journal.log" || fail "rollback-HUP-rejected: coordinator not restarted"
live_unchanged "rollback-HUP-rejected"
note "ok: rollback re-HUP rejected -> controlled coordinator restart"

setup_env
touch "$CCR_TEST_CTL/serve-stale" "$CCR_TEST_CTL/restart-fails"; printf 'test-live-v1\n' >"$CCR_TEST_CTL/reject-version"
run deploy
[ "$RC" -eq 5 ] || fail "restart failure must exit 5 (rc=$RC): $(tail -n 20 "$T/out")"
grep -qF 'catalog-release-decision-tree.md §rollback-failed' "$T/out" || fail "restart failure must name the runbook procedure"
note "ok: failed controlled restart -> exit 5 with the named runbook procedure"

# Interrupted (TERM) while the publish is in flight on Pearl, i.e. before the
# controller marks the release activated: the state is read through the lease
# once the publish finishes, and the activation is rolled back.
setup_env
touch "$CCR_TEST_CTL/publish-slow"
(cd "$R" && exec bash scripts/catalog-content-release.sh --deploy --commit "$COMMIT") >"$T/out" 2>"$T/err" &
deploy_pid=$!
for _ in $(seq 1 300); do [ -e "$CCR_TEST_CTL/publish-started" ] && break; kill -0 "$deploy_pid" 2>/dev/null || break; sleep 0.1; done
[ -e "$CCR_TEST_CTL/publish-started" ] || fail "interrupt: the publish never started: $(tail -n 20 "$T/out") $(tail -n 5 "$T/err")"
kill -TERM "$deploy_pid"
RC=0; wait "$deploy_pid" || RC=$?
[ "$RC" -eq 71 ] || fail "interrupt during the publish must exit 71 after rolling back (rc=$RC): $(tail -n 30 "$T/out") $(tail -n 5 "$T/err")"
grep -q 'reading Pearl state through the lease' "$T/out" || fail "interrupt: Pearl state was not read through the lease: $(tail -n 20 "$T/out")"
grep -q 'rolled back to releases/test-live-v1-0000000000000000' "$T/out" || fail "interrupt: the in-flight activation was not rolled back: $(tail -n 20 "$T/out")"
live_unchanged "interrupt during publish"
window_is "interrupt during publish" "releases/test-prev-v1-0000000000000000"
note "ok: an interrupt while the publish is in flight reads Pearl state through the lease and rolls back"

# The lease runner dies after activation (during evidence (c)): state unknown;
# no rollback from a separate session; exit 6 naming the runbook procedure.
setup_env
touch "$CCR_TEST_CTL/canary-stuck"
(cd "$R" && exec bash scripts/catalog-content-release.sh --deploy --commit "$COMMIT") >"$T/out" 2>"$T/err" &
deploy_pid=$!
for _ in $(seq 1 300); do [ -e "$CCR_TEST_CTL/canary-restarts.log" ] && break; kill -0 "$deploy_pid" 2>/dev/null || break; sleep 0.1; done
[ -e "$CCR_TEST_CTL/canary-restarts.log" ] || fail "lease-lost: evidence (c) never started: $(tail -n 20 "$T/out")"
pkill -9 -f "$CCR_FAKE/tmp/macprovider-activation-lease" || fail "lease-lost: no lease runner to kill"
RC=0; wait "$deploy_pid" || RC=$?
[ "$RC" -eq 6 ] || fail "a lost lease after activation must exit 6 (rc=$RC): $(tail -n 30 "$T/out") $(tail -n 5 "$T/err")"
grep -qF 'catalog-release-decision-tree.md §lease-lost' "$T/out" || fail "lease-lost must name the runbook procedure: $(tail -n 10 "$T/out")"
grep -q 'ROLLBACK' "$T/out" && fail "lease-lost must not roll back from a separate session: $(tail -n 20 "$T/out")"
case "$(readlink "$A_ROOT/current")" in releases/test-new-v1-*) ;; *) fail "lease-lost: current must be left as found: $(readlink "$A_ROOT/current")" ;; esac
note "ok: lease lost after activation -> exit 6 with the runbook procedure, no rollback"

# A renewal (or coordinator deploy / Pearl update) holding the Pearl lock.
setup_env
flock "$CCR_FAKE/run/lock/macprovider-pearl-updater.lock" sleep 30 &
LOCK_PID=$!
sleep 0.5
run deploy
[ "$RC" -eq 3 ] && grep -q 'pearl_locks_free' "$T/out" || fail "a held renewal lock must refuse the deploy (rc=$RC): $(cat "$T/out")"
live_unchanged "held lock"
kill "$LOCK_PID" 2>/dev/null || true; wait "$LOCK_PID" 2>/dev/null || true; LOCK_PID=""
note "ok: deploy refused while a renewal/deploy holds the Pearl lock"

# ---------------------------------------------------------------------------
# #1693 pricing releases.
# ---------------------------------------------------------------------------
YAML="$T/env/fake/opt/macprovider/coordinator.yaml"
PRIOR_YAML_SHA="$(git -C "$R" show "$LIVE_COMMIT:phase4-coordinator/dist/coordinator.yaml" | shasum -a 256 | cut -d' ' -f1)"
runc() { # <commit> <lane args...>; rc in RC
  local c="$1"; shift
  git -C "$R" update-ref refs/remotes/origin/main "$c"
  RC=0
  (cd "$R" && CCR_EXPECT_COMMIT="$c" bash scripts/catalog-content-release.sh "$@" --commit "$c") >"$T/out" 2>"$T/err" || RC=$?
}
pricing_field() { # <field>: from the preflight verdict line in $T/out
  python3 -c 'import json,sys;v=json.loads([l for l in open(sys.argv[1]) if l.startswith("{")][-1]);print((v.get("pricing") or {}).get(sys.argv[2], ""))' "$T/out" "$1"
}
prior_pair() { # <label>: yaml, current, window are exactly the prior pair; no journal
  [ "$(shasum -a 256 "$YAML" | cut -d' ' -f1)" = "$PRIOR_YAML_SHA" ] || fail "$1: coordinator.yaml is not the prior bytes"
  live_unchanged "$1"
  window_is "$1" "releases/test-prev-v1-0000000000000000"
  [ ! -e "$CCR_FAKE/opt/macprovider/.pricing-txn" ] || fail "$1: the pricing journal was left behind"
}
record_is() { # <label> <yaml sha> <card file>: the applied-config record's digests
  python3 - "$CCR_FAKE/run/macprovider/coordinator-applied-config.json" "$2" "$3" <<'PY' || fail "$1: applied-config record digests: $(cat "$CCR_FAKE/run/macprovider/coordinator-applied-config.json")"
import hashlib, json, sys
r = json.load(open(sys.argv[1]))
assert r["config_sha256"] == sys.argv[2], r["config_sha256"]
assert r["signed_rate_card_sha256"] == hashlib.sha256(open(sys.argv[3], "rb").read()).hexdigest()
PY
}
LIVE_CARD() { printf '%s' "$A_ROOT/releases/test-live-v1-0000000000000000/rate-card.json"; }
export CATALOG_GATEWAY_CONVERGENCE_SECONDS=3

# Preflight GO: pricing verdict, price table, pinned names, nothing changed.
setup_env
export CATALOG_GATEWAY_RATE_CARD_URL="http://127.0.0.1:$BUYER_PORT/gateway/v1/rate-card"
runc "$PRICE_COMMIT" --preflight
[ "$RC" -eq 0 ] || fail "pricing preflight GO expected (rc=$RC): $(cat "$T/out") $(tail -n 20 "$T/err")"
[ "$(wc -l <"$T/out" | tr -d ' ')" = 1 ] || fail "pricing preflight must print exactly one JSON line"
python3 - "$T/out" <<'PY' || fail "pricing preflight verdict shape: $(cat "$T/out")"
import json, re, sys
v = json.loads(open(sys.argv[1]).read())
names = {c["name"] for c in v["checks"]}
assert {"pricing_txn_absent", "pricing_release", "pricing_host_state", "pricing_effective_diff", "pricing_gate"} <= names, names
p = v["pricing"]
for k in ("pricing_diff_sha256", "candidate_config_sha256", "commit_block_sha256", "expected_rate_table_sha256",
          "expected_signed_rate_card_sha256", "prior_rate_table_sha256", "prior_signed_rate_card_sha256", "pinned_names_sha256"):
    assert re.fullmatch(r"[0-9a-f]{64}", p[k] or ""), k
assert isinstance(p["prior_billing_snapshot_id"], int) and p["prior_billing_snapshot_id"] > 0
assert "ancient-model" not in p["pinned_names"] and "qwen3-32b" in p["pinned_names"], p["pinned_names"]
moved = {m["model"] for m in p["models"]}
assert "qwen3-32b" in moved and "mlx-community/Qwen3-32B-4bit" in moved, moved
assert "weird name\\x01with control" in p["unresolved_names"], p["unresolved_names"]
assert all(r["old"]["row_key"] == r["new"]["row_key"] for r in p["model_resolutions"])
PY
grep -q 'acknowledge with --pricing-diff-sha256' "$T/err" || fail "pricing preflight must show the price table: $(tail -n 20 "$T/err")"
grep -q 'qwen3-32b: 110000 / 27500 / 220000 -> 110000 / 27500 / 230000' "$T/err" || fail "price table must show the qwen3-32b change"
PDIFF="$(pricing_field pricing_diff_sha256)"
cp "$T/out" "$T/pricing-verdict.json"
prior_pair "pricing preflight"
[ -z "$(ls "$CCR_RTMP")" ] || fail "pricing preflight left its Pearl scratch dir"
note "ok: pricing preflight GO (verdict digests, pinned names, price table, nothing changed)"

# Deploy without the acknowledgement / with a wrong one: refused, nothing changed.
runc "$PRICE_COMMIT" --deploy
[ "$RC" -eq 3 ] && grep -q "re-run with --pricing-diff-sha256 $PDIFF" "$T/out" || fail "a pricing deploy without the ack must refuse (rc=$RC): $(tail -n 5 "$T/out")"
runc "$PRICE_COMMIT" --deploy --pricing-diff-sha256 "$(printf 'ab%.0s' $(seq 1 32))"
[ "$RC" -eq 3 ] && grep -q 'does not match this preflight' "$T/out" || fail "a wrong ack must refuse (rc=$RC)"
prior_pair "missing/mismatched ack"
note "ok: pricing deploy refuses without the acknowledged diff digest"

# Happy path.
setup_env
runc "$PRICE_COMMIT" --deploy --pricing-diff-sha256 "$PDIFF"
[ "$RC" -eq 0 ] || fail "pricing deploy (rc=$RC): $(tail -n 40 "$T/out") $(tail -n 20 "$T/err")"
CAND_SHA="$(git -C "$R" show "$PRICE_COMMIT:phase4-coordinator/dist/coordinator.yaml" | shasum -a 256 | cut -d' ' -f1)"
[ "$(shasum -a 256 "$YAML" | cut -d' ' -f1)" = "$CAND_SHA" ] || fail "the live yaml must be the prior yaml with the commit's rate_card block"
[ "$(stat -c '%a' "$YAML" 2>/dev/null || stat -f '%Lp' "$YAML")" = 640 ] || fail "the installed yaml must keep 0640"
case "$(readlink "$A_ROOT/current")" in releases/test-new-v1-*) ;; *) fail "pricing deploy did not activate the release" ;; esac
record_is "pricing happy path" "$CAND_SHA" "$A_ROOT/$(readlink "$A_ROOT/current")/rate-card.json"
[ ! -e "$CCR_FAKE/opt/macprovider/.pricing-txn" ] || fail "a verified pricing journal must be finalized"
grep -q 'gateway convergence: .* serves the release rate card' "$T/out" || fail "gateway convergence must be checked: $(tail -n 5 "$T/out")"
grep -q 'journal phase verified' "$T/out" || fail "the journal must pass through verified: $(grep -c journal "$T/out")"
note "ok: pricing deploy splices the yaml 0640, verifies record digests, finalizes the journal"

# Gateway not converged: alert only, still exit 0.
setup_env
touch "$CCR_TEST_CTL/gateway-stale"
runc "$PRICE_COMMIT" --deploy --pricing-diff-sha256 "$PDIFF"
[ "$RC" -eq 0 ] && grep -q 'ALERT (informational, not rolled back)' "$T/out" || fail "an unconverged gateway must alert only (rc=$RC): $(tail -n 10 "$T/out")"
case "$(readlink "$A_ROOT/current")" in releases/test-new-v1-*) ;; *) fail "gateway alert must not roll back" ;; esac
note "ok: gateway not converged -> alert only"

# NO_GO before any mutation.
pricing_no_go() { # <label> <check> <commit>
  runc "${3:-$PRICE_COMMIT}" --preflight
  [ "$RC" -eq 3 ] || fail "$1: pricing preflight must be NO_GO (rc=$RC): $(tail -n 5 "$T/err")"
  [ "$(verdict_check "$2")" = false ] || fail "$1: check $2 must fail: $(cat "$T/out")"
  prior_pair "$1"
  note "ok: pricing NO_GO $1 ($2)"
}
setup_env; mkdir -p "$CCR_FAKE/opt/macprovider/.coordinator-deploy-rollback"; pricing_no_go "foreign deploy recovery state" pricing_host_state
grep -q 'coordinator deploy rollback snapshot present' "$T/out" || fail "foreign state must be named"
setup_env; printf '#!/bin/sh\n# pre-guard copy\n' >"$CCR_FAKE/usr/local/sbin/macprovider-pearl-update"; pricing_no_go "installed writer hash mismatch" pricing_host_state
grep -q 'macprovider-pearl-update is sha' "$T/out" || fail "a pre-guard installed writer must be named"
setup_env; rm -f "$CCR_FAKE/opt/macprovider/coordinator-pricing-recover"; pricing_no_go "recovery helper not installed" pricing_host_state
setup_env; touch "$CCR_TEST_CTL/no-closer-want"; pricing_no_go "closer not wanted by the coordinator" pricing_host_state
setup_env; printf 'rewards:\n  global_multiplier: 1.0\n' >"$CCR_FAKE/etc/macprovider/coordinator.pearl-overlays.yaml"
kill -USR1 "$(cat "$CCR_FAKE/coordinator.pid")"; sleep 1
pricing_no_go "pricing keys in the overlay" pricing_host_state
setup_env; touch "$CCR_TEST_CTL/record-legacy"; kill -USR1 "$(cat "$CCR_FAKE/coordinator.pid")"; sleep 1
pricing_no_go "pre-#1693 coordinator record" pricing_host_state
grep -q 'pricing needs a coordinator' "$T/out" || fail "a legacy record must name the enabling release"
setup_env; pricing_no_go "commit block does not bind the card" content_gate "$BADBLOCK_COMMIT"
setup_env; touch "$CCR_TEST_CTL/dryload-parity-skew"; pricing_no_go "dry-load parity mismatch" coordinator_dry_load
# An added row acknowledged for its own key is GO; the same move seen only
# through a request_log name that normalizes onto it is not acknowledged.
setup_env
runc "$MOVE_COMMIT" --preflight
[ "$RC" -eq 0 ] || fail "an acknowledged added row must be GO (rc=$RC): $(cat "$T/out")"
python3 - "$CCR_FAKE/var/lib/macprovider/request-log.sqlite" <<'PY'
import datetime, sqlite3, sys
con = sqlite3.connect(sys.argv[1])
con.execute("INSERT INTO request_log (ts_utc, model) VALUES (?, ?)",
            (datetime.datetime.now(datetime.timezone.utc).strftime("%Y-%m-%dT%H:%M:%S.%fZ"), "mlx-community/Foo-Model-4bit"))
con.commit()
PY
pricing_no_go "unacknowledged move seen only in the request log" pricing_effective_diff "$MOVE_COMMIT"
grep -q 'mlx-community/Foo-Model-4bit' "$T/out" || fail "the unacknowledged request-log name must be named"

# Yaml moved under the lock (after the lease checks, before the publish).
setup_env
cat >>"$T/bin/rsync" <<'RSYNC'
if [ -e "$CCR_TEST_CTL/tamper-yaml" ]; then printf '# edited under the lock\n' >>"$CCR_FAKE/opt/macprovider/coordinator.yaml"; fi
RSYNC
touch "$CCR_TEST_CTL/tamper-yaml"
runc "$PRICE_COMMIT" --deploy --pricing-diff-sha256 "$PDIFF"
[ "$RC" -eq 1 ] && grep -q 'coordinator config changed since the lease dry-load; not mutating' "$T/err" || fail "a yaml moved under the lock must refuse (rc=$RC): $(tail -n 10 "$T/err")"
live_unchanged "yaml moved under lock"
[ ! -e "$CCR_FAKE/opt/macprovider/.pricing-txn" ] || fail "a refused publish must not leave a journal"
grep -q '# edited under the lock' "$YAML" || fail "the refused publish must not rewrite the yaml"
note "ok: yaml moved under the lock -> refused before any mutation"

# Rollbacks restore yaml + current + window together; the record is the prior.
pricing_rollback_case() { # <label> <ctl file> <expected evidence step>
  setup_env
  [ -z "$2" ] || { case "$2" in *=*) printf '%s\n' "${2#*=}" >"$CCR_TEST_CTL/${2%%=*}" ;; *) touch "$CCR_TEST_CTL/$2" ;; esac; }
  runc "$PRICE_COMMIT" --deploy --pricing-diff-sha256 "$PDIFF"
  [ "$RC" -eq 4 ] || fail "$1: expected rollback exit 4 (rc=$RC): $(tail -n 30 "$T/out") $(tail -n 10 "$T/err")"
  grep -q "EVIDENCE ($3) FAILED" "$T/out" || fail "$1: evidence ($3) did not fail: $(tail -n 20 "$T/out")"
  prior_pair "$1"
  record_is "$1" "$PRIOR_YAML_SHA" "$(LIVE_CARD)"
  grep -q 'pricing journal rolled back and finalized' "$T/out" || fail "$1: the journal must be rolled back and finalized"
  note "ok: pricing rollback on $1"
}
pricing_rollback_case "HUP rejected" reject-version=test-new-v1 a
pricing_rollback_case "billing txn failure (half-applied HUP)" billing-fail-once a
pricing_rollback_case "served bytes stale (a)" serve-stale a

# Interrupt while the publish is in flight: journal-driven rollback.
setup_env
touch "$CCR_TEST_CTL/publish-slow"
git -C "$R" update-ref refs/remotes/origin/main "$PRICE_COMMIT"
(cd "$R" && CCR_EXPECT_COMMIT="$PRICE_COMMIT" exec bash scripts/catalog-content-release.sh --deploy --commit "$PRICE_COMMIT" --pricing-diff-sha256 "$PDIFF") >"$T/out" 2>"$T/err" &
deploy_pid=$!
for _ in $(seq 1 600); do [ -e "$CCR_TEST_CTL/publish-started" ] && break; kill -0 "$deploy_pid" 2>/dev/null || break; sleep 0.1; done
[ -e "$CCR_TEST_CTL/publish-started" ] || fail "pricing interrupt: the publish never started: $(tail -n 20 "$T/out")"
kill -TERM "$deploy_pid"
RC=0; wait "$deploy_pid" || RC=$?
[ "$RC" -eq 71 ] || fail "pricing interrupt must exit 71 after rolling back (rc=$RC): $(tail -n 30 "$T/out") $(tail -n 5 "$T/err")"
prior_pair "pricing interrupt during publish"
note "ok: an interrupt during a pricing publish rolls yaml, current and window back from the journal"

# Lease lost after activation: no rollback, journal kept; every writer (this
# lane included) refuses; --recover-pricing-txn restores and finalizes.
setup_env
touch "$CCR_TEST_CTL/canary-stuck"
git -C "$R" update-ref refs/remotes/origin/main "$PRICE_COMMIT"
(cd "$R" && CCR_EXPECT_COMMIT="$PRICE_COMMIT" exec bash scripts/catalog-content-release.sh --deploy --commit "$PRICE_COMMIT" --pricing-diff-sha256 "$PDIFF") >"$T/out" 2>"$T/err" &
deploy_pid=$!
for _ in $(seq 1 600); do [ -e "$CCR_TEST_CTL/canary-restarts.log" ] && break; kill -0 "$deploy_pid" 2>/dev/null || break; sleep 0.1; done
[ -e "$CCR_TEST_CTL/canary-restarts.log" ] || fail "pricing lease-lost: evidence (c) never started: $(tail -n 20 "$T/out")"
pkill -9 -f "$CCR_FAKE/tmp/macprovider-activation-lease" || fail "pricing lease-lost: no lease runner to kill"
RC=0; wait "$deploy_pid" || RC=$?
[ "$RC" -eq 6 ] || fail "pricing lease lost must exit 6 (rc=$RC): $(tail -n 20 "$T/out")"
grep -q 'ROLLBACK' "$T/out" && fail "pricing lease-lost must not roll back from a separate session"
grep -q -- '--recover-pricing-txn' "$T/out" || fail "pricing lease-lost must name --recover-pricing-txn"
[ -d "$CCR_FAKE/opt/macprovider/.pricing-txn" ] || fail "pricing lease-lost must keep the journal"
rm -f "$CCR_TEST_CTL/canary-stuck"
run preflight
[ "$RC" -eq 3 ] && [ "$(verdict_check pricing_txn_absent)" = false ] || fail "any release must be NO_GO while a pricing journal exists (rc=$RC)"
RC=0; (cd "$R" && bash scripts/catalog-content-release.sh --recover-pricing-txn) >"$T/out" 2>"$T/err" || RC=$?
[ "$RC" -eq 0 ] || fail "--recover-pricing-txn must restore and finalize (rc=$RC): $(tail -n 20 "$T/out") $(tail -n 10 "$T/err")"
prior_pair "recover after lease loss"
record_is "recover after lease loss" "$PRIOR_YAML_SHA" "$(LIVE_CARD)"
RC=0; (cd "$R" && bash scripts/catalog-content-release.sh --recover-pricing-txn) >"$T/out" 2>"$T/err" || RC=$?
[ "$RC" -eq 0 ] && grep -q 'no pricing transaction journal' "$T/out" || fail "--recover-pricing-txn with no journal must be a no-op (rc=$RC)"
note "ok: lease lost -> journal kept, every writer refuses, --recover-pricing-txn restores the prior pair"

# A name pinned by the saved preflight verdict: a new request-log name after
# preflight does not invalidate the acknowledgement (no new move).
setup_env
python3 - "$CCR_FAKE/var/lib/macprovider/request-log.sqlite" <<'PY'
import datetime, sqlite3, sys
con = sqlite3.connect(sys.argv[1])
con.execute("INSERT INTO request_log (ts_utc, model) VALUES (?, ?)",
            (datetime.datetime.now(datetime.timezone.utc).strftime("%Y-%m-%dT%H:%M:%S.%fZ"), "brand-new-model"))
con.commit()
PY
runc "$PRICE_COMMIT" --deploy --pricing-diff-sha256 "$PDIFF"
[ "$RC" -eq 3 ] || fail "without the saved verdict a newly seen name re-pins and changes the digest (rc=$RC)"
runc "$PRICE_COMMIT" --deploy --pricing-diff-sha256 "$PDIFF" --preflight-verdict "$T/pricing-verdict.json"
[ "$RC" -eq 0 ] || fail "the saved verdict's pinned names must keep the ack valid (rc=$RC): $(tail -n 30 "$T/out")"
grep -q 'reusing the .* model names pinned by the saved preflight verdict' "$T/out" || fail "the pinned names must be reused"
note "ok: --preflight-verdict pins the name set; a new name without a move keeps the ack valid"
git -C "$R" update-ref refs/remotes/origin/main "$COMMIT"

printf '[test-catalog-content-release] ok: preflight, deploy, evidence rollback (a-d), HUP-rejected restart, interrupt/lease-lost, lease refusal, pricing lane (#1693)\n'
