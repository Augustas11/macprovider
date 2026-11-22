#!/bin/bash
# Runs ON THE STUDIO, started detached by the #2469/#2470 window wrapper, which has already paused
# live, the runner's Studio target and the FLOP miner and holds the Studio GPU lock. This job
# never pauses, restores or restarts any of them; it refuses to start when anything still runs.
#
# Measure-first step (AGENTS.md rule 12) of #2469 and #2470: the time split of one native-MTP
# verify step, from a production `serve --no-join` on loopback built with the lab section timer.
#  #2469 Qwen3.8-27B (qwen/qwen3.8-27b, snapshot 8a8786e9): 1 row, a ~29.5K-token prompt
#        (QWEN_CTX 34000, the #2459 R015 cell), depth-1 verify window (2 columns): the share of
#        the step in the full-attention SDPA (keys below the window) and the SDPA kernel it takes;
#        then one ordinary row at the same context (QWEN_ORD_OUT tokens), whose 1-column decode SDPA
#        is the floor a shared K/V read across the window's columns could reach.
#  #2470 GLM-5.3-Flash (zai-org/glm-5.3-flash, snapshot 7299b6a7): 1 native row (the served verify
#        window, 2 tokens), plus GLM_ORD_ROWS ordinary rows at once (one decode call of that many
#        tokens through the same fused MoE kernels): routed vs shared expert time, distinct routed
#        experts per pick.
# One model at a time, Qwen first:
#  1. preflight: nothing on :8080/:8000/:$PORT, no live agent, no serve, no FLOP agent, no VM
#     process; the shipped trees are complete; the metallib is the one both signed native-MTP
#     entries name;
#  2. build in $SRC/phase3-binary (git-archive of the pushed campaign commit) with mlx-swift-lm
#     replaced by $FORK (git-archive of the pushed fork commit, LabSectionTimer + the #2469
#     sections): `swift package edit`, then
#     `swift build -c release --product macprovider-cli -Xswiftc -DMACPROVIDER_LAB_HARNESS
#      -Xswiftc -DMACPROVIDER_SECTION_TIMING`;
#  3. per model: free disk >= model size + MIN_FREE_MARGIN_GB (the native-MTP admission capture
#     copies the whole model per start, #2468); serve with MLX_LM_SECTION_TIMING=1, native_mtp_mode
#     auto + model_catalog_* provenance (the signed admission), no route override; ready, idle CB
#     self-check gate (route_status.py), cached-turns probe settled, native MTP on (required),
#     route recorded; then load.py cells; stop the serve;
#  4. verdict.py: T2469_SHARE / T2470_SHARE / T2470_T4 / T2470_CEILING, T2469_2470_VERDICT.
# Knobs: MODELS ("qwen glm") QWEN_CTX (34000) QWEN_OUT (256) QWEN_TRIALS (2) QWEN_ORD_OUT (64) GLM_CTX (4000)
#        GLM_OUT (256) GLM_TRIALS (2) GLM_ORD_ROWS (4) GLM_ORD_CTX (1000) GLM_ORD_OUT (128)
#        WARMUP_CTX (512) MIN_FREE_MARGIN_GB (20) SKIP_BUILD PORT (18469) SERVE_ENV ("K=V ...",
#        MLX_LM_SECTION_TIMING=1 is always added) STALL_S (1800).
# JOB_CHECK=1 validates the knobs and prints the plan, then exits 0 before touching anything.
# Watchdogs are stall detectors only (STALL_S without progress), never wall-clock cuts.
# Every failure prints a `BLOCKER:` line; the job ends with JOB_PASS (every step ran; the
# numbers are in the verdict lines) or JOB_FAIL.
set -u
export PATH=/usr/sbin:/opt/homebrew/bin:/usr/bin:/bin
LAB=$HOME/lab-2469
RUN_ID=${RUN_ID:?RUN_ID unset}
SRC=${SRC:?SRC unset}
FORK=${FORK:?FORK unset}
COMMIT=${COMMIT:-unknown}
FORK_COMMIT=${FORK_COMMIT:-unknown}
PKG=$SRC/phase3-binary
HERE=$SRC/scripts/lab/2469
GRID=$SRC/scripts/lab/parity-grid
RES=$LAB/results/$RUN_ID
STORE="$HOME/Library/Application Support/macprovider/models"
METALLIB=${METALLIB:-/Applications/Malibu.app/Contents/MacOS/mlx.metallib}
BUILD=.build-lab-2469
BIN=$PKG/$BUILD/release
MODELS=${MODELS:-qwen glm}
PORT=${PORT:-18469}
QWEN_CTX=${QWEN_CTX:-34000}
QWEN_OUT=${QWEN_OUT:-256}
QWEN_TRIALS=${QWEN_TRIALS:-2}
QWEN_ORD_OUT=${QWEN_ORD_OUT:-64}
GLM_CTX=${GLM_CTX:-4000}
GLM_OUT=${GLM_OUT:-256}
GLM_TRIALS=${GLM_TRIALS:-2}
GLM_ORD_ROWS=${GLM_ORD_ROWS:-4}
GLM_ORD_CTX=${GLM_ORD_CTX:-1000}
GLM_ORD_OUT=${GLM_ORD_OUT:-128}
WARMUP_CTX=${WARMUP_CTX:-512}
MIN_FREE_MARGIN_GB=${MIN_FREE_MARGIN_GB:-20}
STALL_S=${STALL_S:-1800}
FAILED=0
SERVE_PID=""
log() { echo "$(date '+%H:%M:%S') $*"; }
blocker() { log "BLOCKER: $*"; FAILED=1; }
die() { log "BLOCKER: $*"; log "JOB_FAIL"; exit "${2:-1}"; }
free_gb() { df -g "$HOME" | awk 'NR==2 {print $4}'; }
listening() { lsof -nP -iTCP:"$1" -sTCP:LISTEN -t >/dev/null 2>&1; }
# model_key NAME / model_sha NAME: the catalog row and snapshot each model label serves.
model_key() { case "$1" in qwen) echo qwen/qwen3.8-27b ;; glm) echo zai-org/glm-5.3-flash ;; esac; }
model_sha() {
  case "$1" in
    qwen) echo 8a8786e902127e9175f5be0d7c8bcf4dd32323a0521e4d9a20761608a07a6d05 ;;
    glm) echo 7299b6a71a38490e378e9eb6524c426392aa96e3fd561007e0540134bbef48f9 ;;
  esac
}
# labelled LABEL CMD...: CMD's output with LABEL prefixed to each line; returns CMD's status.
labelled() {
  local l=$1 out r; shift
  out=$("$@" 2>&1); r=$?
  [ -z "$out" ] || printf '%s\n' "$out" | sed "s/^/$l /"
  return $r
}
stop_serve() {
  [ -n "$SERVE_PID" ] || return 0
  if kill -0 "$SERVE_PID" 2>/dev/null; then
    kill -TERM "$SERVE_PID" 2>/dev/null
    for _ in $(seq 1 40); do kill -0 "$SERVE_PID" 2>/dev/null || break; sleep 0.5; done
    kill -KILL "$SERVE_PID" 2>/dev/null
  fi
  wait "$SERVE_PID" 2>/dev/null
  SERVE_PID=""
}
trap stop_serve EXIT

# Knob checks (also the JOB_CHECK=1 dry run).
for m in $MODELS; do case "$m" in qwen|glm) ;; *) die "MODELS entry $m: qwen or glm" 64 ;; esac; done
for n in QWEN_CTX QWEN_OUT QWEN_TRIALS QWEN_ORD_OUT GLM_CTX GLM_OUT GLM_TRIALS GLM_ORD_ROWS GLM_ORD_CTX GLM_ORD_OUT WARMUP_CTX \
         MIN_FREE_MARGIN_GB PORT STALL_S; do
  case "${!n}" in ''|*[!0-9]*) die "$n=${!n} must be a non-negative integer" 64 ;; esac
done
[ "$QWEN_CTX" -le 34000 ] || die "QWEN_CTX=$QWEN_CTX: the signed Qwen tuple admits prompts up to 32768 tokens (34000 is ~29.5K)" 64
[ "$GLM_ORD_ROWS" -ge 2 ] && [ "$GLM_ORD_ROWS" -le 8 ] || die "GLM_ORD_ROWS=$GLM_ORD_ROWS: 2..8 (the glm5_next forward carries at most 8 tokens)" 64
read -r -a SERVE_ENVS <<< "${SERVE_ENV:-} MLX_LM_SECTION_TIMING=1"
if [ "${JOB_CHECK:-0}" = 1 ]; then
  log "JOB_CHECK models=\"$MODELS\" qwen=$QWEN_CTX/$QWEN_OUT x$QWEN_TRIALS glm=$GLM_CTX/$GLM_OUT x$GLM_TRIALS ord=${GLM_ORD_ROWS}x$GLM_ORD_CTX/$GLM_ORD_OUT warmup=$WARMUP_CTX port=$PORT serve_env=\"${SERVE_ENVS[*]}\""
  exit 0
fi

mkdir -p "$RES"
log "JOB_START run=$RUN_ID commit=$COMMIT fork=$FORK_COMMIT src=$SRC models=\"$MODELS\" port=$PORT serve_env=\"${SERVE_ENVS[*]}\""

# 1. Preflight.
listening 8080 && die "a server listens on :8080; the Studio is not paused" 3
listening 8000 && die "a server listens on :8000; the FLOP miner backend is not paused" 3
listening "$PORT" && die "port $PORT is busy" 3
launchctl print "gui/$(id -u)/live.malibu.provider" >/dev/null 2>&1 && die "live.malibu.provider is loaded" 3
pgrep -f "[m]acprovider-cli serve" >/dev/null 2>&1 && die "a macprovider-cli serve process runs" 3
launchctl list 2>/dev/null | grep -q 'com\.flop\.' && die "a com.flop LaunchAgent is loaded (miner not paused)" 3
pgrep -f "[c]om.apple.Virtualization.VirtualMachine|[l]imactl|[m]lx_service" >/dev/null 2>&1 && die "a miner VM or backend process runs" 3
[ -f "$PKG/Package.swift" ] && [ -f "$HERE/load.py" ] && [ -f "$HERE/verdict.py" ] && [ -f "$GRID/route_status.py" ] \
  || die "source tree incomplete at $SRC" 11
[ -f "$FORK/Package.swift" ] && [ -f "$FORK/Libraries/MLXLMCommon/LabSectionTimer.swift" ] \
  && grep -q qwen35LabTraceAttentionShape "$FORK/Libraries/MLXLLM/Models/Qwen35.swift" \
  && grep -q GLM5NextLabRouteCounter "$FORK/Libraries/MLXLLM/Models/GLM5Next.swift" \
  || die "fork tree at $FORK lacks the #2469 lab sections" 11
[ -f "$METALLIB" ] || die "no metallib at $METALLIB" 14
METALLIB_SHA=$(shasum -a 256 "$METALLIB" | cut -d' ' -f1)
log "DISK free_gb=$(free_gb) METALLIB sha256=$METALLIB_SHA"
# Per-model values live in DURABLE_<m> / MODEL_GB_<m> (the Studio's /bin/bash is 3.2: no associative arrays).
for m in $MODELS; do
  key=$(model_key "$m") sha=$(model_sha "$m")
  signed=$(/usr/bin/python3 -I -c 'import json,sys
e=[e for e in json.load(open(sys.argv[1]))["entries"] if e.get("model_key")==sys.argv[2] and e.get("artifact_hash")==sys.argv[3]]
print(e[0]["metallib_sha256"] if len(e)==1 else "")' "$PKG/catalog/autotune/native-mtp-admission.json" "$key" "$sha")
  [ "$METALLIB_SHA" = "$signed" ] || die "$m: metallib $METALLIB_SHA is not the signed native-MTP entry's ${signed:-none}" 14
  path=$(/usr/bin/python3 -I - "$PKG/catalog/autotune/autotune-candidates.json" "$key" "$sha" "$STORE" <<'PY'
import json, os, sys
cand, key, sha, store = sys.argv[1:5]
row = json.load(open(cand))["rows"].get(key)
if row is None or row["model_sha256"] != sha:
    sys.exit(f"candidates row {key} missing or not {sha}")
path = os.path.join(store, row["model_id"].replace("/", "--"), row["model_revision"], sha)
if not os.path.isfile(os.path.join(path, "config.json")):
    sys.exit(f"no durable artifact at {path}")
print(path)
PY
  ) || die "$m model: $path" 11
  printf -v "DURABLE_$m" '%s' "$path"
  printf -v "MODEL_GB_$m" '%s' "$(du -sg "$path" | cut -f1)"
  gbvar=MODEL_GB_$m
  log "MODEL $m key=$key sha=$sha path=$path size_gb=${!gbvar}"
done

# 2. Build against the fork.
if [ "${SKIP_BUILD:-0}" != 1 ]; then
  log "BUILD_START fork=$FORK_COMMIT flags=-DMACPROVIDER_LAB_HARNESS,-DMACPROVIDER_SECTION_TIMING"
  (cd "$PKG" && { swift package --build-path "$BUILD" unedit mlx-swift-lm > /dev/null 2>&1; true; } \
     && swift package --build-path "$BUILD" edit mlx-swift-lm --path "$FORK" \
     && nice -n 10 swift build -c release --product macprovider-cli --build-path "$BUILD" \
          -Xswiftc -DMACPROVIDER_LAB_HARNESS -Xswiftc -DMACPROVIDER_SECTION_TIMING) \
    > "$RES/build.log" 2>&1 \
    || die "release build failed: $(grep -m3 'error:' "$RES/build.log" | tr '\n' ' ' | cut -c1-400)" 14
fi
[ -x "$BIN/macprovider-cli" ] || die "no release binary at $BIN" 14
cp "$METALLIB" "$BIN/mlx.metallib" || die "metallib copy failed" 14
shasum -a 256 "$BIN/macprovider-cli" "$BIN/mlx.metallib" > "$RES/identity.sha256"
log "BUILD_DONE $("$BIN/macprovider-cli" --version 2>&1 | head -n 1) cli_sha256=$(cut -c1-16 "$RES/identity.sha256" | head -n 1)"

# 3. Serves.
# wait_until PID FILE CMD...: waits until CMD succeeds; returns 5 when PID exits, 4 when FILE has
# not changed for STALL_S seconds (a stall, never a wall-clock bound).
wait_until() {
  local pid=$1 file=$2; shift 2
  local last="" since now cur
  since=$(date +%s)
  until "$@"; do
    kill -0 "$pid" 2>/dev/null || return 5
    cur=$(stat -f '%m %z' "$file" 2>/dev/null)
    now=$(date +%s)
    if [ "$cur" != "$last" ]; then last=$cur; since=$now; fi
    [ $((now - since)) -lt "$STALL_S" ] || return 4
    sleep 5
  done
}
model_loaded() {
  curl -s --max-time 3 "http://127.0.0.1:$PORT/v1/status" | /usr/bin/python3 -I -c \
    'import json,sys; sys.exit(0 if json.load(sys.stdin).get("model_loaded") is True else 1)' 2>/dev/null
}
# cached_turns_settled DIR: the startup cached-turns probe has decided (serve.err), or a stored
# record carries its result, or no stored record granted batching (then no probe runs).
cached_turns_settled() {
  grep -q "action=cached_turns_decided" "$1/serve.err" 2>/dev/null && return 0
  /usr/bin/python3 -I - "$1/cb-self-check.json" <<'PY'
import json, sys
try:
    doc = json.load(open(sys.argv[1]))
except Exception:
    sys.exit(1)
records = []
def walk(o):
    if isinstance(o, dict):
        if "decision" in o and "key" in o:
            records.append(o)
        for v in o.values():
            walk(v)
    elif isinstance(o, list):
        for v in o:
            walk(v)
walk(doc)
if any(isinstance(r.get("cached_turns_parity"), bool) for r in records):
    sys.exit(0)
granted = [r for r in records if isinstance(r.get("decision"), dict) and r["decision"].get("reason") == "granted"]
sys.exit(1 if granted or not records else 0)
PY
}

run_serve() {
  local m=$1 key sha d s fg need rc durable gbvar=MODEL_GB_$1 pathvar=DURABLE_$1
  durable=${!pathvar}
  key=$(model_key "$m") sha=$(model_sha "$m")
  d=$RES/$m
  s=$d/serve
  mkdir -p "$s"
  fg=$(free_gb) need=$((${!gbvar} + MIN_FREE_MARGIN_GB))
  log "SERVE_START $m key=$key free_gb=$fg need_gb=$need"
  [ "${fg:-0}" -ge "$need" ] || { blocker "$m: ${fg} GB free; a native-MTP start needs >= $need (whole-model admission capture, #2468)"; return 1; }
  /usr/bin/python3 -I - "$PKG/catalog/autotune/autotune-candidates.json" "$key" "$sha" "$durable" "$PORT" "$s" \
    > "$s/config.yaml" <<'PY' || { blocker "$m: config generation failed"; return 1; }
import hashlib, json, sys
cand, key, sha, path, port, sdir = sys.argv[1:7]
raw = open(cand, "rb").read()
doc = json.loads(raw)
row = doc["rows"][key]
q = json.dumps
print("\n".join([f"model: {q(key)}", f"model_artifact_path: {q(path)}", f"model_artifact_sha256: {sha}",
                 f"port: {port}", f"ctl_socket_path: {q(sdir + '/ctl.sock')}", "credential_store: protected_file",
                 "native_mtp_mode: auto", f"model_catalog_key: {q(key)}", f"model_catalog_model_id: {q(row['model_id'])}",
                 f"model_catalog_revision: {q(row['model_revision'])}", f"model_catalog_sha256: {q(sha)}",
                 f"model_catalog_version: {q(doc['version'])}", f"model_catalog_hash: {q(hashlib.sha256(raw).hexdigest())}"]))
PY
  echo '{}' > "$d/grid.json"
  (cd "$BIN" && exec env "${SERVE_ENVS[@]}" ./macprovider-cli serve --config "$s/config.yaml" --no-join \
     > "$s/serve.out" 2> "$s/serve.err" < /dev/null) &
  SERVE_PID=$!
  wait_until "$SERVE_PID" "$s/serve.err" model_loaded; rc=$?
  [ $rc = 0 ] || { blocker "$m: serve not ready (rc=$rc: 5 exited, 4 stalled): $(tail -n 3 "$s/serve.err" | tr '\n' ' ' | cut -c1-300)"; stop_serve; return 1; }
  curl -s "http://127.0.0.1:$PORT/v1/status" > "$s/status-ready.json"
  log "SERVE_READY $m"
  /usr/bin/python3 -I "$GRID/route_status.py" gate --port "$PORT" --serve-err "$s/serve.err" --pid "$SERVE_PID" \
    --stall-s "$STALL_S" --poll-s 10 > "$s/warmup.log" 2>&1; rc=$?
  log "CB_WARMUP $m rc=$rc $(grep -E '^CB_WARMUP' "$s/warmup.log" | tail -n 1)"
  [ $rc != 5 ] || { blocker "$m: serve exited during the CB warm-up"; stop_serve; return 1; }
  wait_until "$SERVE_PID" "$s/cb-self-check.json" cached_turns_settled "$s"; rc=$?
  log "CACHED_TURNS $m rc=$rc $(grep 'action=cached_turns_decided' "$s/serve.err" | tail -n 1 | cut -c1-200)"
  [ $rc != 5 ] || { blocker "$m: serve exited before the cached-turns probe settled"; stop_serve; return 1; }
  curl -s "http://127.0.0.1:$PORT/v1/status" > "$s/status.json"
  labelled "$m" /usr/bin/python3 -I "$GRID/route_status.py" record --status "$s/status.json" --serve-err "$s/serve.err" \
    --grid "$d/grid.json" --phase start --expect any
  labelled "$m" /usr/bin/python3 -I "$GRID/route_status.py" native-mtp --status "$s/status.json" --grid "$d/grid.json" \
    --phase start --expect on \
    || { blocker "$m: native MTP is not on; no cells"; stop_serve; return 1; }
  grep -m1 'decode_path=provenance_differs' "$s/serve.err" | sed "s/^/$m ADMISSION /"
  log "CELLS_START $m"
  if [ "$m" = qwen ]; then
    /usr/bin/python3 -I "$HERE/load.py" --port "$PORT" --model "$key" --label qwen --out "$d/rows.jsonl" \
      --serve-err "$s/serve.err" --cell nat1 --ctx "$QWEN_CTX" --max-tokens "$QWEN_OUT" --trials "$QWEN_TRIALS" \
      --warmup-ctx "$WARMUP_CTX" > "$d/cells.log" 2>&1; rc=$?
    /usr/bin/python3 -I "$HERE/load.py" --port "$PORT" --model "$key" --label qwen --out "$d/rows.jsonl" \
      --serve-err "$s/serve.err" --cell ord1 --rows 1 --ctx "$QWEN_CTX" --max-tokens "$QWEN_ORD_OUT" --trials 1 \
      >> "$d/cells.log" 2>&1 || rc=1
  else
    /usr/bin/python3 -I "$HERE/load.py" --port "$PORT" --model "$key" --label glm --out "$d/rows.jsonl" \
      --serve-err "$s/serve.err" --cell nat1 --ctx "$GLM_CTX" --max-tokens "$GLM_OUT" --trials "$GLM_TRIALS" \
      --warmup-ctx "$WARMUP_CTX" > "$d/cells.log" 2>&1; rc=$?
    /usr/bin/python3 -I "$HERE/load.py" --port "$PORT" --model "$key" --label glm --out "$d/rows.jsonl" \
      --serve-err "$s/serve.err" --cell "ord$GLM_ORD_ROWS" --rows "$GLM_ORD_ROWS" --ctx "$GLM_ORD_CTX" \
      --max-tokens "$GLM_ORD_OUT" --trials 1 >> "$d/cells.log" 2>&1 || rc=1
  fi
  grep -E '^(ROW|TRIAL) ' "$d/cells.log" | sed 's/^/CELL /'
  log "CELLS_DONE $m rc=$rc"
  [ $rc = 0 ] || blocker "$m: a request failed: $(grep -vE '^(ROW|TRIAL) ' "$d/cells.log" | tail -n 3 | tr '\n' ' ' | cut -c1-300)"
  curl -s --max-time 10 "http://127.0.0.1:$PORT/v1/status" > "$s/status-end.json"
  labelled "$m" /usr/bin/python3 -I "$GRID/route_status.py" native-mtp --status "$s/status-end.json" --grid "$d/grid.json" \
    --phase end --expect on || blocker "$m: native MTP not on at the end"
  log "SECTION_LINES $m $(grep -c '^section_timing ' "$s/serve.err") route_lines=$(grep -c 'event=lab_sdpa_route' "$s/serve.err")"
  grep -E 'event=lab_sdpa_route|^lab_fa_shape' "$s/serve.err" | head -n 8 | sed "s/^/$m TRACE /"
  stop_serve
  for _ in $(seq 1 60); do listening "$PORT" || break; sleep 1; done
  log "SERVE_END $m free_gb=$(free_gb) captures=$(ls -d "$(dirname "$durable")"/.native-mtp-admission-capture-* 2>/dev/null | wc -l | tr -d ' ')"
  return $rc
}

DONE_MODELS=""
for m in $MODELS; do
  run_serve "$m" || FAILED=1
  DONE_MODELS="$DONE_MODELS,$m"
done

# 4. Verdict.
/usr/bin/python3 -I "$HERE/verdict.py" --res "$RES" --models "${DONE_MODELS#,}" --json "$RES/verdict.json" \
  > "$RES/verdict.md" 2>&1
vrc=$?
cat "$RES/verdict.md"
[ "$vrc" -le 1 ] || blocker "verdict.py rc=$vrc (unusable input)"
[ "$vrc" = 0 ] || blocker "verdict incomplete (see verdict.md)"
[ "$FAILED" = 0 ] || { log "JOB_FAIL"; exit 1; }
log "JOB_PASS"
