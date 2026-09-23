#!/usr/bin/env bash
# Hermetic tests for scripts/catalog-content-release.sh (#1688 C4-C7).
#
# No Pearl, no canary Mac, no root. A throwaway git repo holds the reviewed
# tooling + committed release; a fake ssh runs Pearl commands locally with the
# Pearl paths rewritten into a temp root (like test-autotune-activate.sh); a
# Python coordinator stub serves the loopback buyer/provider/canary-status HTTP
# surfaces, reloads on SIGHUP and writes a fake journal; fake journalctl,
# systemctl, systemd-run, launchctl and lsof close the loop. catalog-release.py
# is a stub here (signed fixtures cannot be mutated); its real content-gate is
# covered by scripts/tests/test_catalog_content_gate.py.
#
# Cases: preflight GO; NO_GO for wrong lane, closure miss, dry-load failure,
# coverage loss (and GO with a logged override), yaml drift, working tree vs
# commit mismatch, new buyer-serving Tier-2 pin (e), missing canary evidence;
# deploy happy path (row hash changed -> autotune --apply first); rollback on
# evidence (a), (b), (c) (+ retention of an adopted release), (d); rollback
# re-HUP rejected -> controlled restart; restart failure -> runbook exit 5;
# a held renewal/deploy lock -> refusal.
set -euo pipefail

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
fail() { printf '[test-catalog-content-release] FAIL: %s\n' "$*" >&2; exit 1; }
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
rw() {
  sed -E \
      -e "s#/opt/macprovider/#$CCR_FAKE/opt/macprovider/#g" \
      -e "s#/etc/macprovider/#$CCR_FAKE/etc/macprovider/#g" \
      -e "s#\"/opt\"#\"$CCR_FAKE/opt\"#g" \
      -e "s#/run/lock/#$CCR_FAKE/run/lock/#g" \
      -e "s#/var/lib/macprovider-pearl-updater/#$CCR_FAKE/var/lib/macprovider-pearl-updater/#g" \
      -e "s#install -d -o macprovider -g macprovider -m 0750 /var/lib/macprovider#mkdir -p $CCR_FAKE/var/lib/macprovider#g" \
      -e "s#/var/lib/macprovider/#$CCR_FAKE/var/lib/macprovider/#g" \
      -e "s#os\\.fchown\\(fd, 0, 0\\)#pass#g" \
      -e "s#/tmp/macprovider-content-#$CCR_RTMP/macprovider-content-#g" \
      -e "s#/proc/\\\$pid/environ#$CCR_FAKE/proc-environ#g" \
      -e "s#127\\.0\\.0\\.1:8443#127.0.0.1:$BUYER_PORT#g" \
      -e "s#127\\.0\\.0\\.1:8444#127.0.0.1:$PROVIDER_PORT#g" \
      -e "s#\"\\\$window\" (plan|apply|restore|coverage) #\"\$window\" \\1 --required-uid $CCR_UID --group $CCR_GID #g" \
      -e "s#chown (-R )?root:[a-z]+#:#g" \
      -e "s#mv -Tf#mv -hf#g" \
      -e "s#st_uid != 0#st_uid != $CCR_UID#g" \
      -e "s#st_gid != 0#st_gid != $CCR_GID#g"
}
cmd="$(printf '%s\n' "$cmd" | rw)"
case "$cmd" in
  "bash -s"*) rw | bash -c "$cmd" ;;
  # The lock validator's Pearl paths live in its body (not sha-pinned).
  "cat >"*pearl_autotune_deploy_lock.py*) rw | bash -c "$cmd" ;;
  *) exec bash -c "$cmd" ;;
esac
SSH
cat >"$T/bin/rsync" <<'RSYNC'
#!/usr/bin/env bash
set -eu
args=("$@"); n=${#args[@]}
src="${args[$((n-2))]}"; dst="${args[$((n-1))]}"; dst="${dst#*:}"
dst="$(printf '%s' "$dst" | sed "s#/opt/macprovider/#$CCR_FAKE/opt/macprovider/#")"
mkdir -p "$dst"; cp -R "$src"/. "$dst"
RSYNC
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
  *"-p MainPID"*) cat "$CCR_FAKE/coordinator.pid" ;;
  *ExecMainStartTimestamp*) printf '@%s\n' "$(cat "$CCR_FAKE/start")" ;;
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
state = {"hups": 0}
lock = threading.Lock()

def c(name):
    return os.path.exists(os.path.join(ctl, name))

def journal(obj):
    obj.setdefault("time", datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%S.%fZ"))
    with open(os.path.join(fake, "journal.log"), "a") as fh:
        fh.write("%.6f pearl coordinator[%d]: %s\n" % (time.time(), os.getpid(), json.dumps(obj, sort_keys=True)))

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
    state["hups"] += 1
    load(keep_rate_card=c("serve-stale") and state["hups"] == 1)
    t2sha = "00" * 32 if c("tier2-wrong") else state["t2sha"]
    journal({"level": "info", "event": "autotune_feed_sighup_reload", "autotune_catalog_version": state["version"],
             "tier2_catalog_id": state["t2id"], "tier2_sha256": t2sha,
             "message": "autotune signed feed reloaded without restart"})
    if c("incompatible-after-hup") and state["hups"] == 1:
        journal({"level": "warn", "catalog_release_id": "stale-release", "catalog_candidate_sha256": "cd" * 32,
                 "message": "provider catalog release is incompatible with coordinator"})
    journal({"level": "info", "message": "tier2/proof_of_weights config reloaded"})

def on_restart(*_):
    load()
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
   "$root/scripts/lib/catalog-window-override.sh" "$R/scripts/lib/"
cp "$root/ops/pearl-updater/catalog-canary-proof.py" "$R/ops/pearl-updater/"
cat >"$R/scripts/catalog-release.py" <<'CR'
#!/usr/bin/env python3
"""Test stub for catalog-release.py: verdicts are driven by $CCR_TEST_CTL files."""
import json, os, pathlib, sys
ctl = pathlib.Path(os.environ["CCR_TEST_CTL"])
cmd, args = sys.argv[1], sys.argv[2:]
def arg(name):
    return args[args.index(name) + 1]
if cmd == "verify-directory":
    sys.exit(1 if (ctl / "verify-fail").exists() else 0)
if cmd == "check-tier2-binding":
    if (ctl / "closure-fail").exists():
        print("catalog-release: ERROR: serving closure: 1 recommendable rate-carded model(s) have no matching Tier-2", file=sys.stderr)
        sys.exit(1)
    sys.exit(0)
if cmd == "content-gate":
    lane = (ctl / "lane").read_text().strip() if (ctl / "lane").exists() else "catalog-content"
    rel = json.loads((pathlib.Path(arg("--release")) / "release.json").read_text())
    live = json.loads((pathlib.Path(arg("--live")) / "release.json").read_text())
    ok = lane == "catalog-content"
    print(json.dumps({"ok": ok, "lane": lane, "reasons": [] if ok else ["stub: lane " + lane],
                      "release_id": rel["release_id"], "live_release_id": live["release_id"], "changed": {}}))
    sys.exit(0 if ok else 3)
sys.exit(0)
CR
cp "$root/phase3-binary/catalog/autotune/"{release.json,trusted-keys.json,tier2-catalog.json,release-ledger.json,not-buyer-serving.json} "$R/phase3-binary/catalog/autotune/"
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
retarget "$R/phase3-binary/catalog/autotune" test-new-v1 row-hash
git -C "$R" init -q
git -C "$R" add -A
git -C "$R" -c user.name=t -c user.email=t@example.invalid commit -qm "reviewed catalog content"
COMMIT="$(git -C "$R" rev-parse HEAD)"
git -C "$R" update-ref refs/remotes/origin/main "$COMMIT"
NEW_CAND="$(python3 -c 'import json,sys;print(json.load(open(sys.argv[1]))["feeds"]["autotune-candidates.json"]["sha256"])' "$R/phase3-binary/catalog/autotune/release.json")"

# ---------------------------------------------------------------------------
# One fresh fake Pearl + canary per case.
# ---------------------------------------------------------------------------
setup_env() {
  [ -z "$STUB_PID" ] || { kill "$STUB_PID" 2>/dev/null || true; wait "$STUB_PID" 2>/dev/null || true; STUB_PID=""; }
  local E="$T/env"
  rm -rf "$E"; mkdir -p "$E"
  export CCR_FAKE="$E/fake" CCR_TEST_CTL="$E/ctl" CCR_RTMP="$E/rtmp" CCR_CANARY_HOME="$E/canary"
  mkdir -p "$CCR_FAKE/run/lock" "$CCR_FAKE/var/lib" "$CCR_FAKE/etc/macprovider" "$CCR_TEST_CTL" "$CCR_RTMP"
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
  printf 'auth:\n  operator_key: env:COORD_OPERATOR_KEY\n' >"$CCR_FAKE/opt/macprovider/coordinator.yaml"
  touch -t 202001010000 "$CCR_FAKE/opt/macprovider/coordinator.yaml"
  printf 'PATH=/usr/bin\0COORD_OPERATOR_KEY=%s\0' "$OPKEY" >"$CCR_FAKE/proc-environ"
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
bad = os.path.exists(os.path.join(os.environ["CCR_TEST_CTL"], "dryload-fail"))
print(json.dumps({"ok": not bad, "release_id": m["release_id"], "candidates_sha256": m["feeds"]["autotune-candidates.json"]["sha256"],
                  "tier2_catalog_id": json.loads(t2)["catalog_id"], "tier2_sha256": hashlib.sha256(t2).hexdigest(),
                  "previous_loaded": [{"release_id": p} for p in prev], "errors": ["tier2: stub reject"] if bad else [], "notes": []}))
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
        "rollback_preconditions", "content_gate", "serving_closure", "buyer_serving_e2e", "coordinator_dry_load",
        "window_coverage", "config_applied", "canary_token_operator_key", "canary_reachable"}
assert v["go"] is True and want <= set(names), (v["go"], sorted(want - set(names)))
assert all(c["ok"] for c in v["checks"])
PY
grep -qF "$OPKEY" "$T/out" "$T/err" && fail "preflight printed the operator bearer"
[ -z "$(ls "$CCR_RTMP")" ] || fail "preflight left its Pearl scratch dir"
note "ok: preflight GO"

setup_env; printf 'pricing\n' >"$CCR_TEST_CTL/lane"; expect_no_go "wrong lane" content_gate
setup_env; touch "$CCR_TEST_CTL/closure-fail"; expect_no_go "closure miss" serving_closure
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
override_mode="$(stat -f '%Lp' "$OVERRIDE_LOG" 2>/dev/null || stat -c '%a' "$OVERRIDE_LOG")"
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

setup_env; touch "$CCR_FAKE/opt/macprovider/coordinator.yaml"; expect_no_go "yaml drift" config_applied
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
rollback_case "served bytes stale" serve-stale a
rollback_case "tier2 digest mismatch in journal" tier2-wrong b
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
rollback_case "new catalog_incompatible" incompatible-after-hup d
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

printf '[test-catalog-content-release] ok: preflight, deploy, evidence rollback (a-d), HUP-rejected restart, lease refusal\n'
