#!/bin/bash
# Runs ON THE STUDIO, started detached by scratchpad/windows/window-2465-selfcheck.sh, which has
# already paused live, the runner's Studio target and the FLOP miner and holds the Studio GPU lock.
# This job never pauses, restores or restarts any of them; it refuses to start while anything runs.
#
# #2465 SPEC-048 MTP-16 self-check record for the DaisyRose-27B native-MTP variant
# (radixark/daisyrose-27b, donor qwen/qwen3.8-27b). The signed bank carries the donor's expected
# output for the variant's challenge until the variant's own record is bound
# (`catalog-release.py bind-native-mtp-self-check-record`). This job captures that record: it
# serves DaisyRose with native MTP from this branch's signed static release and waits for the
# on-device self-check at load, which logs `event=native_mtp_self_check_record` when it passes.
#
# Steps:
#  1. preflight: nothing on :8080/:8000/:$PORT/:$FEED_PORT, no live agent, serve, FLOP agent or VM
#     process; free disk >= MIN_FREE_GB; inputs present;
#  2. lab-harness release build (-DMACPROVIDER_LAB_HARNESS) in $SRC/phase3-binary/.build-lab-2465
#     (the lab static-feed origin override exists only in a lab build); the metallib is the one the
#     branch's signed native-MTP entry for the variant names;
#  3. an isolated model store (MACPROVIDER_MODEL_ARTIFACT_ROOT) with APFS clones of DaisyRose and the
#     Qwen3.8-27B MTP head at the signed projection paths, each checked against its signed hash;
#  4. a loopback static-feed origin serving this branch's signed feeds (phase3-binary/dist/static,
#     signed by streamvc-autotune-static-v4; the provider verifies them against that key); a feed the
#     branch does not carry (the native-MTP revocation feed) is passed through read only from the
#     production origin;
#  5. `serve --no-join` (native_mtp_mode auto, isolated home, lifecycle and control socket, as the
#     job.sh quality serve) until the `event=native_mtp_self_check result=` line;
#  6. `T2465_SELFCHECK_RECORD <json>` ({"challenge_id","record"}, also results/<run>/selfcheck-record.json)
#     and JOB_PASS when the self-check passed and logged the variant's record, else JOB_FAIL.
# Knobs: MIN_FREE_GB (60) SKIP_BUILD PORT (18465) FEED_PORT (18466) STALL_S (1800) DAISY_DIR.
# Every failure prints `BLOCKER:`. Watchdogs are stall detectors only, never wall-clock cuts.
set -u
export PATH=/usr/sbin:/opt/homebrew/bin:/usr/bin:/bin
LAB=$HOME/lab-2465
RUN_ID=${RUN_ID:?RUN_ID unset}
SRC=${SRC:?SRC unset}
COMMIT=${COMMIT:?COMMIT unset}
PKG=$SRC/phase3-binary
HERE=$SRC/scripts/lab/2465
CAT=$PKG/catalog/autotune
FEEDS=$PKG/dist/static
RES=$LAB/results/$RUN_ID
WORK=$LAB/selfcheck-$RUN_ID
STORE="$HOME/Library/Application Support/macprovider/models"
HF="$HOME/.cache/huggingface/hub"
METALLIB=${METALLIB:-/Applications/Malibu.app/Contents/MacOS/mlx.metallib}
BUILD=.build-lab-2465
BIN=$PKG/$BUILD/release
PORT=${PORT:-18465}
FEED_PORT=${FEED_PORT:-18466}
MIN_FREE_GB=${MIN_FREE_GB:-60}
STALL_S=${STALL_S:-1800}
DAISY_DIR=${DAISY_DIR:-$LAB/models/DaisyRose-27B-4bit}
DAISY_KEY=radixark/daisyrose-27b
STATIC_KEY_ID=streamvc-autotune-static-v4
FAILED=0
SERVE_PID="" FEED_PID=""
log() { echo "$(date '+%H:%M:%S') $*"; }
die() { log "BLOCKER: $*"; log "JOB_FAIL"; exit "${2:-1}"; }
free_gb() { df -g "$HOME" | awk 'NR==2 {print $4}'; }
listening() { lsof -nP -iTCP:"$1" -sTCP:LISTEN -t >/dev/null 2>&1; }
echo "$COMMIT" | grep -Eq '^[0-9a-f]{40}$' || die "COMMIT must be the 40-hex campaign commit" 64

stop_pid() {  # stop_pid PID
  [ -n "$1" ] || return 0
  if kill -0 "$1" 2>/dev/null; then
    kill -TERM "$1" 2>/dev/null
    for _ in $(seq 1 60); do kill -0 "$1" 2>/dev/null || break; sleep 0.5; done
    kill -KILL "$1" 2>/dev/null
  fi
  wait "$1" 2>/dev/null
}
cleanup() {
  stop_pid "$SERVE_PID"; SERVE_PID=""
  stop_pid "$FEED_PID"; FEED_PID=""
  rm -rf -- "$WORK"
}
trap cleanup EXIT
mkdir -p "$RES"
log "JOB_START selfcheck run=$RUN_ID commit=$COMMIT port=$PORT feed_port=$FEED_PORT"

# 1. Preflight.
listening 8080 && die "a server listens on :8080; the Studio is not paused" 3
listening 8000 && die "a server listens on :8000; the FLOP miner backend is not paused" 3
listening "$PORT" && die "port $PORT is busy" 3
listening "$FEED_PORT" && die "port $FEED_PORT is busy" 3
launchctl print "gui/$(id -u)/live.malibu.provider" >/dev/null 2>&1 && die "live.malibu.provider is loaded" 3
pgrep -f "[m]acprovider-cli serve" >/dev/null 2>&1 && die "a macprovider-cli serve process runs" 3
launchctl list 2>/dev/null | grep -q 'com\.flop\.' && die "a com.flop LaunchAgent is loaded (miner not paused)" 3
pgrep -f "[c]om.apple.Virtualization.VirtualMachine|[l]imactl|[m]lx_service" >/dev/null 2>&1 && die "a miner VM or backend process runs" 3
fg=$(free_gb)
log "DISK free_gb=$fg min=$MIN_FREE_GB"
[ "${fg:-0}" -ge "$MIN_FREE_GB" ] || die "only ${fg} GB free; need $MIN_FREE_GB (build, native-MTP whole-model capture)" 13
for f in "$PKG/Package.swift" "$HERE/snapshot_id.py" "$CAT/autotune-candidates.json" "$CAT/trusted-keys.json" \
         "$FEEDS/native-mtp-admission.json" "$FEEDS/native-mtp-admission.json.sig" "$FEEDS/native-mtp-artifact-manifest.json" \
         "$FEEDS/native-mtp-selftest-bank.json" "$FEEDS/native-mtp-selftest-bank.json.sig"; do
  [ -f "$f" ] || die "source tree incomplete: no $f" 11
done
[ -f "$DAISY_DIR/config.json" ] || die "no DaisyRose snapshot at $DAISY_DIR" 11
[ -f "$METALLIB" ] || die "no metallib at $METALLIB" 14

# The signed identities this job serves, all read from the branch's feeds.
IDS=$(/usr/bin/python3 -I - "$FEEDS" "$CAT" "$DAISY_KEY" "$STATIC_KEY_ID" <<'PY'
import json, sys
feeds, cat, key, key_id = sys.argv[1:5]
entries = [e for e in json.load(open(f"{feeds}/native-mtp-admission.json"))["entries"] if e.get("model_key") == key]
models = json.load(open(f"{feeds}/native-mtp-artifact-manifest.json"))["models"]
bank = [c for c in json.load(open(f"{feeds}/native-mtp-selftest-bank.json"))["entries"] if c.get("model_id") == key]
pub = json.load(open(f"{cat}/trusted-keys.json"))["keys"][key_id]["public_key_base64"]
if len(entries) != 1 or key not in models or len(bank) != 1:
    sys.exit(f"branch feeds carry {len(entries)} admission entries, {int(key in models)} projections, {len(bank)} challenges for {key}")
p = models[key]
print(entries[0]["artifact_hash"], entries[0]["metallib_sha256"], p["target"]["path"], p["target"]["sha256"],
      p["mtp"]["path"], p["mtp"]["sha256"], bank[0]["challenge_id"], pub)
PY
) || die "branch feeds: $IDS" 11
read -r DAISY_SHA SIGNED_METALLIB TARGET_REL TARGET_SHA MTP_REL MTP_SHA CHALLENGE STATIC_PUB <<< "$IDS"
[ "$DAISY_SHA" = "$TARGET_SHA" ] || die "admission artifact_hash $DAISY_SHA is not the projection target $TARGET_SHA" 11
log "INPUTS daisy=$DAISY_DIR artifact=$DAISY_SHA mtp=$MTP_SHA challenge=$CHALLENGE signed_metallib=$SIGNED_METALLIB"

# 2. Build.
if [ "${SKIP_BUILD:-0}" != 1 ]; then
  log "BUILD_START lab-harness release"
  (cd "$PKG" && nice -n 10 swift build -c release --product macprovider-cli --build-path "$BUILD" -Xswiftc -DMACPROVIDER_LAB_HARNESS) \
    > "$RES/build.log" 2>&1 || die "release build failed: $(grep -m3 'error:' "$RES/build.log" | tr '\n' ' ' | cut -c1-400)" 14
fi
[ -x "$BIN/macprovider-cli" ] || die "no lab-harness binary at $BIN" 14
METALLIB_SHA=$(shasum -a 256 "$METALLIB" | cut -d' ' -f1)
[ "$METALLIB_SHA" = "$SIGNED_METALLIB" ] || die "metallib $METALLIB_SHA is not the signed variant entry's $SIGNED_METALLIB" 14
cp "$METALLIB" "$BIN/mlx.metallib" || die "metallib copy failed" 14
shasum -a 256 "$BIN/macprovider-cli" "$BIN/mlx.metallib" > "$RES/identity.sha256"
log "BUILD_DONE $("$BIN/macprovider-cli" --version 2>&1 | head -n 1) cli_sha256=$(cut -c1-16 "$RES/identity.sha256" | head -n 1)"

# 3. Isolated store at the signed projection paths (APFS clones; sources stay read only).
HEAD_DIR=""
for d in "$STORE"/mlx-community--Qwen3.8-27B-MTP-4bit/*/"$MTP_SHA" "$HF"/models--mlx-community--Qwen3.8-27B-MTP-4bit/snapshots/b643c01b6d3b094e325edb6ebd832e16c486c575; do
  [ -z "$HEAD_DIR" ] && [ -f "$d/config.json" ] && HEAD_DIR=$d
done
[ -n "$HEAD_DIR" ] || die "no Qwen3.8-27B-MTP-4bit head ($MTP_SHA) in the store or the HF cache" 11
ROOT=$WORK/store
mkdir -p "$ROOT/$(dirname "$TARGET_REL")" "$ROOT/$(dirname "$MTP_REL")" || die "store setup failed" 11
/bin/cp -c -R -L "$DAISY_DIR" "$ROOT/$TARGET_REL" && /bin/cp -c -R -L "$HEAD_DIR" "$ROOT/$MTP_REL" \
  && rm -rf -- "$ROOT/$TARGET_REL/.cache" "$ROOT/$MTP_REL/.cache" || die "store clone failed" 11
got=$(/usr/bin/python3 -I "$HERE/snapshot_id.py" "$ROOT/$TARGET_REL" | cut -d' ' -f1)
[ "$got" = "$TARGET_SHA" ] || die "DaisyRose clone identity $got is not the signed $TARGET_SHA" 11
got=$(/usr/bin/python3 -I "$HERE/snapshot_id.py" "$ROOT/$MTP_REL" | cut -d' ' -f1)
[ "$got" = "$MTP_SHA" ] || die "head clone identity $got is not the signed $MTP_SHA" 11
log "STORE $ROOT target=$TARGET_REL mtp=$MTP_REL free_gb=$(free_gb)"

# 4. Loopback static-feed origin: /v1/<name> from the branch's signed feeds.
/usr/bin/python3 -I - "$FEEDS" "$FEED_PORT" > "$RES/feeds.log" 2>&1 <<'PY' &
import http.server, os, sys, urllib.request
feeds, port = sys.argv[1], int(sys.argv[2])
PRODUCTION = "https://coordinator.malibu.tech/v1/"
class Handler(http.server.BaseHTTPRequestHandler):
    def do_GET(self):
        name = self.path.split("?", 1)[0]
        if not name.startswith("/v1/") or "/" in name[4:] or name[4:] in ("", ".", ".."):
            return self.send_error(404)
        name = name[4:]
        candidates = [name, name + ".json"]
        if name.endswith(".sig"):
            candidates.append(name[:-4] + ".json.sig")
        for c in candidates:
            path = os.path.join(feeds, c)
            if os.path.isfile(path):
                body, origin = open(path, "rb").read(), "branch"
                break
        else:
            try:
                with urllib.request.urlopen(PRODUCTION + name, timeout=20) as r:
                    body, origin = r.read(), "production"
            except Exception as e:
                print(f"FEED {name} unavailable {e}", flush=True)
                return self.send_error(404)
        print(f"FEED {name} {origin} {len(body)}", flush=True)
        self.send_response(200)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)
    def log_message(self, *args):
        pass
http.server.ThreadingHTTPServer(("127.0.0.1", port), Handler).serve_forever()
PY
FEED_PID=$!
for _ in $(seq 1 40); do listening "$FEED_PORT" && break; sleep 0.25; done
listening "$FEED_PORT" || die "the loopback feed origin did not start: $(tail -n 2 "$RES/feeds.log" | tr '\n' ' ')" 11
log "FEEDS origin=http://127.0.0.1:$FEED_PORT key_id=$STATIC_KEY_ID"

# 5. Serve with native MTP until the self-check decides.
S=$WORK/serve
mkdir -p "$S/home" "$S/tmp"
/usr/bin/python3 -I - "$CAT/autotune-candidates.json" "$DAISY_KEY" "$DAISY_SHA" "$ROOT/$TARGET_REL" "$PORT" "$S" \
  > "$S/config.yaml" <<'PY' || die "config generation failed" 11
import hashlib, json, sys
cand, key, sha, path, port, sdir = sys.argv[1:7]
raw = open(cand, "rb").read()
doc = json.loads(raw)
row = doc["rows"][key]
q = json.dumps
print("\n".join([f"model: {q(key)}", f"model_artifact_path: {q(path)}", f"model_artifact_sha256: {sha}",
                 f"port: {port}", f"ctl_socket_path: {q(sdir + '/tmp/ctl.sock')}", "credential_store: protected_file",
                 "native_mtp_mode: auto", f"model_catalog_key: {q(key)}", f"model_catalog_model_id: {q(row['model_id'])}",
                 f"model_catalog_revision: {q(row['model_revision'])}", f"model_catalog_sha256: {q(sha)}",
                 f"model_catalog_version: {q(doc['version'])}", f"model_catalog_hash: {q(hashlib.sha256(raw).hexdigest())}"]))
PY
cp "$S/config.yaml" "$RES/serve-config.yaml"
log "SELFCHECK_SERVE_START model=$DAISY_KEY"
( export CFFIXED_USER_HOME=$S/home TMPDIR=$S/tmp/ MACPROVIDER_LIFECYCLE_ROOT=$S/home/lifecycle \
    MACPROVIDER_CTL_SOCKET_PATH=$S/tmp/ctl.sock MACPROVIDER_SWITCH_STATE_PATH=$S/tmp/last-switch.ts \
    MACPROVIDER_WATCHDOG_STATE_DIR=$S/home/watchdog MACPROVIDER_AUTO_UPDATE_ENABLED=false \
    MACPROVIDER_MODEL_ARTIFACT_ROOT=$ROOT \
    MACPROVIDER_LAB_STATIC_FEED_ORIGIN=http://127.0.0.1:$FEED_PORT \
    MACPROVIDER_LAB_STATIC_FEED_KEY_ID=$STATIC_KEY_ID MACPROVIDER_LAB_STATIC_FEED_PUBLIC_KEY=$STATIC_PUB
  cd "$BIN" && exec ./macprovider-cli serve --config "$S/config.yaml" --no-join > "$RES/serve.out" 2> "$RES/serve.err" < /dev/null ) &
SERVE_PID=$!
last="" since=$(date +%s)
until grep -q 'event=native_mtp_self_check result=' "$RES/serve.err" 2>/dev/null; do
  kill -0 "$SERVE_PID" 2>/dev/null || { FAILED=1; log "BLOCKER: serve exited before the self-check: $(tail -n 3 "$RES/serve.err" | tr '\n' ' ' | cut -c1-400)"; break; }
  cur=$(stat -f '%m %z' "$RES/serve.err" 2>/dev/null); now=$(date +%s)
  if [ "$cur" != "$last" ]; then last=$cur; since=$now; fi
  [ $((now - since)) -lt "$STALL_S" ] || { FAILED=1; log "BLOCKER: serve log stalled ${STALL_S}s before the self-check: $(grep -E 'native_mtp|lab_static_feed' "$RES/serve.err" | tail -n 3 | tr '\n' ' ' | cut -c1-400)"; break; }
  sleep 5
done
grep -E 'event=(native_mtp[a-z_]*|lab_static_feed_override)' "$RES/serve.err" | cut -c1-300 | sed 's/^/SELFCHECK_EVENT /'
log "SELFCHECK_DONE $(grep -m1 'event=native_mtp_self_check result=' "$RES/serve.err" | cut -c1-200)"

# 6. Record.
if [ "$FAILED" = 0 ]; then
  /usr/bin/python3 -I - "$RES/serve.err" "$CHALLENGE" "$RES/selfcheck-record.json" <<'PY' || FAILED=1
import json, re, sys
log, challenge, out = sys.argv[1:4]
text = open(log, encoding="utf-8", errors="replace").read()
verdicts = re.findall(r"event=native_mtp_self_check result=(\S+)", text)
if verdicts[:1] != ["passed"]:
    sys.exit(print(f"BLOCKER: the self-check did not pass: {verdicts[:1]}") or 1)
pattern = re.compile(r"event=native_mtp_self_check_record challenge_id=(\S+) record=(\{.*\})\s*$")
found = [(m.group(1), json.loads(m.group(2))) for m in map(pattern.search, text.splitlines()) if m]
found = [f for f in found if f[0] == challenge]
if len(found) != 1:
    sys.exit(print(f"BLOCKER: {len(found)} self-check records for challenge {challenge}") or 1)
body = json.dumps({"challenge_id": challenge, "record": found[0][1]}, sort_keys=True, separators=(",", ":"))
open(out, "w").write(body + "\n")
print("T2465_SELFCHECK_RECORD " + body)
PY
fi
stop_pid "$SERVE_PID"; SERVE_PID=""
[ "$FAILED" = 0 ] || { log "JOB_FAIL"; exit 1; }
log "JOB_PASS record=$RES/selfcheck-record.json"
