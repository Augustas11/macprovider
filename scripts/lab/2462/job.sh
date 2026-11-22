#!/bin/bash
# Runs ON THE STUDIO, started detached by the #2462 window wrapper, which has already paused
# live, the runner's Studio target and the FLOP miner and holds the Studio GPU lock. This job
# never pauses, restores or restarts any of them; it refuses to start when anything still runs.
#
# #2462 measures the FR-CB9 `mixed` small-row route (SPEC-038 v0.3.61/v0.3.62, SPEC-048 0.1.120
# R003) on Qwen3.8-27B (catalog row qwen/qwen3.8-27b, durable store snapshot 8a8786e9, native MTP
# admitted by the signed baked feed) against today's process-wide `row_invariant`:
#  1. preflight: nothing on :8080/:8000/:$PORT, no live agent, no serve, no FLOP agent, no VM
#     process; free disk >= MIN_FREE_GB (the native-MTP admission capture byte-copies the whole
#     model per start, #2468); the metallib is the one the signed native-MTP entry names;
#  2. builds in $SRC/phase3-binary (a git-archive checkout of the pushed campaign commit):
#     `swift build --build-tests` (debug) and
#     `swift build -c release --product macprovider-cli -Xswiftc -DMACPROVIDER_LAB_HARNESS`;
#  3. filtered tests only, on Metal (the metallib is copied into the test bundle, so a Metal test
#     that skips is a failure): SmallMRouteScopeTests|SmallMRouteTests|
#     PagedKVPerRouteDecodeSessionTests|PagedKVDecodeSessionFinishTests, which must include a
#     passed testAttachIsolationProbeInAMixedProcessRunsOnTheProcessRoute; then the mlx-swift
#     fork's MLXTests SmallMRouteTests from a copy of the package's own checkout
#     (.build/checkouts/mlx-swift), FORK_TESTS_UNAVAILABLE when that copy cannot build;
#  4. serves in SERVES order (default "A1:A B:B A2:A", control-candidate-control), one at a time,
#     each a production `serve --no-join` on loopback :$PORT (no autotune flag, batching auto, the
#     signed native-MTP admission via native_mtp_mode auto + model_catalog_* provenance):
#       A = config `small_m_route: row_invariant` (operatorForcesRowInvariant: today's
#           process-wide row_invariant, reason operator_row_invariant),
#       B = no override: FR-CB9 decides `mixed` (reason native_mtp_per_request).
#     Each serve: ready, idle CB self-check verdict (route_status.py gate), the cached-turns probe
#     decided, startup event and /v1/status route checked, batching active, native MTP on, then
#     mixed_load.py (cells ord1, nat1, mix; its header says how rows become native or ordinary).
#     A later serve of the same mode starts with the earlier one's stored self-check verdict;
#  5. verdict.py: gates, medians, `T2462_VERDICT PASS|FAIL ...`.
# Knobs: TRIALS (6) CTX (1000) ORD_ROWS (2) ORD_OUT (512) NAT_OUT (1024) SERVES MIN_FREE_GB (60)
#        SKIP_BUILD SKIP_TESTS SKIP_FORK_TESTS PORT (18462) SERVE_ENV ("K=V ...").
# Watchdogs are stall detectors only (STALL_S without progress), never wall-clock cuts.
# Every failure prints a `BLOCKER:` line; the job ends with JOB_PASS (every step ran; the
# verdict is in T2462_VERDICT) or JOB_FAIL.
set -u
export PATH=/usr/sbin:/opt/homebrew/bin:/usr/bin:/bin
LAB=$HOME/lab-2462
RUN_ID=${RUN_ID:?RUN_ID unset}
SRC=${SRC:?SRC unset}
COMMIT=${COMMIT:-unknown}
PKG=$SRC/phase3-binary
HERE=$SRC/scripts/lab/2462
GRID=$SRC/scripts/lab/parity-grid
RES=$LAB/results/$RUN_ID
STORE="$HOME/Library/Application Support/macprovider/models"
METALLIB=${METALLIB:-/Applications/Malibu.app/Contents/MacOS/mlx.metallib}
MODEL_KEY=qwen/qwen3.8-27b
MODEL_SHA=8a8786e902127e9175f5be0d7c8bcf4dd32323a0521e4d9a20761608a07a6d05
PORT=${PORT:-18462}
TRIALS=${TRIALS:-6}
CTX=${CTX:-1000}
ORD_ROWS=${ORD_ROWS:-2}
ORD_OUT=${ORD_OUT:-512}
NAT_OUT=${NAT_OUT:-1024}
SERVES=${SERVES:-A1:A B:B A2:A}
MIN_FREE_GB=${MIN_FREE_GB:-60}
STALL_S=${STALL_S:-1800}
TEST_FILTER='SmallMRouteScopeTests|SmallMRouteTests|PagedKVPerRouteDecodeSessionTests|PagedKVDecodeSessionFinishTests'
REQUIRED_TEST=testAttachIsolationProbeInAMixedProcessRunsOnTheProcessRoute
XCODE_DEV=$HOME/Applications/Xcode.app/Contents/Developer
# The full Xcode only for the mlx-swift checkout copy (as job-qwen4-exactness.sh); the provider
# builds use the default toolchain, as every earlier lab build did.
FORK_DEV=${DEVELOPER_DIR:-}
[ -n "$FORK_DEV" ] || [ ! -d "$XCODE_DEV" ] || FORK_DEV=$XCODE_DEV
# The route must come from the serve's own decision: no inherited lab override or MLX value.
unset MACPROVIDER_LAB_SMALL_M_ROUTE MLX_METAL_SMALL_M_ROW_INVARIANT MLX_METAL_QMV_MMA_WK
FAILED=0
SERVE_PID=""
log() { echo "$(date '+%H:%M:%S') $*"; }
blocker() { log "BLOCKER: $*"; FAILED=1; }
die() { log "BLOCKER: $*"; log "JOB_FAIL"; exit "${2:-1}"; }
free_gb() { df -g "$HOME" | awk 'NR==2 {print $4}'; }
listening() { lsof -nP -iTCP:"$1" -sTCP:LISTEN -t >/dev/null 2>&1; }
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
mkdir -p "$RES"
log "JOB_START run=$RUN_ID commit=$COMMIT src=$SRC serves=\"$SERVES\" trials=$TRIALS ctx=$CTX ord_rows=$ORD_ROWS ord_out=$ORD_OUT nat_out=$NAT_OUT port=$PORT"

# 1. Preflight.
listening 8080 && die "a server listens on :8080; the Studio is not paused" 3
listening 8000 && die "a server listens on :8000; the FLOP miner backend is not paused" 3
listening "$PORT" && die "port $PORT is busy" 3
launchctl print "gui/$(id -u)/live.malibu.provider" >/dev/null 2>&1 && die "live.malibu.provider is loaded" 3
pgrep -f "[m]acprovider-cli serve" >/dev/null 2>&1 && die "a macprovider-cli serve process runs" 3
launchctl list 2>/dev/null | grep -q 'com\.flop\.' && die "a com.flop LaunchAgent is loaded (miner not paused)" 3
pgrep -f "[c]om.apple.Virtualization.VirtualMachine|[l]imactl|[m]lx_service" >/dev/null 2>&1 && die "a miner VM or backend process runs" 3
fg=$(free_gb)
log "DISK free_gb=$fg min=$MIN_FREE_GB"
[ "${fg:-0}" -ge "$MIN_FREE_GB" ] || die "only ${fg} GB free on the data volume; need $MIN_FREE_GB (build, plus one whole-model native-MTP capture per start, #2468)" 13
[ -f "$PKG/Package.swift" ] && [ -f "$HERE/mixed_load.py" ] && [ -f "$GRID/route_status.py" ] || die "source tree incomplete at $SRC" 11
[ -f "$METALLIB" ] || die "no metallib at $METALLIB" 14
METALLIB_SHA=$(shasum -a 256 "$METALLIB" | cut -d' ' -f1)
SIGNED_METALLIB=$(/usr/bin/python3 -I -c 'import json,sys
e=[e for e in json.load(open(sys.argv[1]))["entries"] if e.get("model_key")==sys.argv[2] and e.get("artifact_hash")==sys.argv[3]]
print(e[0]["metallib_sha256"] if len(e)==1 else "")' "$PKG/catalog/autotune/native-mtp-admission.json" "$MODEL_KEY" "$MODEL_SHA")
log "METALLIB sha256=$METALLIB_SHA signed_native_mtp_entry=$SIGNED_METALLIB"
[ "$METALLIB_SHA" = "$SIGNED_METALLIB" ] || die "metallib $METALLIB_SHA is not the signed native-MTP entry's $SIGNED_METALLIB" 14
DURABLE=$(/usr/bin/python3 -I - "$PKG/catalog/autotune/autotune-candidates.json" "$MODEL_KEY" "$MODEL_SHA" "$STORE" <<'PY'
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
) || die "model: $DURABLE" 11
MODEL_GB=$(du -sg "$DURABLE" | cut -f1)
log "MODEL $MODEL_KEY sha=$MODEL_SHA path=$DURABLE size_gb=$MODEL_GB"

# 2. Builds.
BIN=$PKG/.build/release
if [ "${SKIP_BUILD:-0}" != 1 ]; then
  log "BUILD_START debug tests"
  (cd "$PKG" && nice -n 10 swift build --build-tests) > "$RES/build-tests.log" 2>&1 \
    || die "debug test build failed: $(grep -m3 'error:' "$RES/build-tests.log" | tr '\n' ' ' | cut -c1-400)" 14
  log "BUILD_DONE debug tests"
  log "BUILD_START release"
  (cd "$PKG" && nice -n 10 swift build -c release --product macprovider-cli -Xswiftc -DMACPROVIDER_LAB_HARNESS) \
    > "$RES/build-release.log" 2>&1 \
    || die "release build failed: $(grep -m3 'error:' "$RES/build-release.log" | tr '\n' ' ' | cut -c1-400)" 14
fi
[ -x "$BIN/macprovider-cli" ] || die "no release binary at $BIN" 14
cp "$METALLIB" "$BIN/mlx.metallib" || die "metallib copy failed" 14
shasum -a 256 "$BIN/macprovider-cli" "$BIN/mlx.metallib" > "$RES/identity.sha256"
log "BUILD_DONE release $("$BIN/macprovider-cli" --version 2>&1 | head -n 1) cli_sha256=$(cut -c1-16 "$RES/identity.sha256" | head -n 1)"

# count_cases LOG CLASSES_REGEX: prints "passed failed skipped" of XCTest cases in LOG.
count_cases() {
  local p f s
  p=$(grep -cE "Test Case '-\[[^ ]*($2) test[A-Za-z0-9_]+\]' passed" "$1")
  f=$(grep -cE "Test Case '-\[[^ ]*($2) test[A-Za-z0-9_]+\]' failed" "$1")
  s=$(grep -cE "Test Case '-\[[^ ]*($2) test[A-Za-z0-9_]+\]' skipped" "$1")
  echo "$p $f $s"
}

# 3. Filtered tests on Metal.
TESTS_OK=1
if [ "${SKIP_TESTS:-0}" != 1 ]; then
  bundle=$(ls -d "$PKG"/.build/debug/*PackageTests.xctest "$PKG"/.build/debug/macprovider-cliTests.xctest 2>/dev/null | head -n 1)
  [ -n "$bundle" ] || die "no test bundle under $PKG/.build/debug" 14
  cp "$METALLIB" "$bundle/Contents/MacOS/mlx.metallib" && cp "$METALLIB" "$PKG/.build/debug/mlx.metallib" \
    || die "metallib copy into the test bundle failed" 14
  log "TESTS_START filter=$TEST_FILTER"
  (cd "$PKG" && swift test --skip-build --filter "$TEST_FILTER") > "$RES/tests.log" 2>&1
  rc=$?
  read -r p f s <<< "$(count_cases "$RES/tests.log" "$TEST_FILTER")"
  req=$(grep -cE "Test Case '-\[[^ ]* $REQUIRED_TEST\]' passed" "$RES/tests.log")
  log "TESTS_DONE rc=$rc passed=$p failed=$f skipped=$s $REQUIRED_TEST=$([ "$req" -ge 1 ] && echo passed || echo not_passed)"
  grep -E "Test Case '-\[.*\]' (failed|skipped)" "$RES/tests.log" | head -n 20 | sed 's/^/TESTS_CASE /'
  if [ "$rc" != 0 ] || [ "$f" != 0 ] || [ "$s" != 0 ] || [ "$p" = 0 ] || [ "$req" -lt 1 ]; then
    TESTS_OK=0; blocker "filtered tests did not all pass on Metal (rc=$rc passed=$p failed=$f skipped=$s required=$req)"
  fi
  FORK_SRC=$PKG/.build/checkouts/mlx-swift
  FORK=$LAB/fork-mlx-swift
  if [ "${SKIP_FORK_TESTS:-0}" = 1 ]; then
    log "FORK_TESTS_SKIPPED (SKIP_FORK_TESTS=1)"
  elif [ ! -f "$FORK_SRC/Tests/MLXTests/SmallMRouteTests.swift" ]; then
    log "FORK_TESTS_UNAVAILABLE no Tests/MLXTests/SmallMRouteTests.swift in $FORK_SRC"
  else
    log "FORK_TESTS_START mlx-swift $(git -C "$FORK_SRC" rev-parse HEAD 2>/dev/null)"
    rsync -a --delete --exclude '.build' --exclude '.swiftpm' "$FORK_SRC/" "$FORK/" > "$RES/fork-copy.log" 2>&1
    if (cd "$FORK" && env ${FORK_DEV:+DEVELOPER_DIR=$FORK_DEV} nice -n 10 swift build --build-tests --scratch-path "$LAB/fork-mlx-swift-build") > "$RES/fork-tests-build.log" 2>&1; then
      fbundle=$(ls -d "$LAB"/fork-mlx-swift-build/debug/*PackageTests.xctest "$LAB"/fork-mlx-swift-build/debug/MLXTests.xctest 2>/dev/null | head -n 1)
      if [ -n "$fbundle" ] && cp "$METALLIB" "$fbundle/Contents/MacOS/mlx.metallib"; then
        (cd "$FORK" && env ${FORK_DEV:+DEVELOPER_DIR=$FORK_DEV} swift test --skip-build --scratch-path "$LAB/fork-mlx-swift-build" --filter 'MLXTests.SmallMRouteTests') \
          > "$RES/fork-tests.log" 2>&1
        rc=$?
        read -r p f s <<< "$(count_cases "$RES/fork-tests.log" SmallMRouteTests)"
        log "FORK_TESTS_DONE rc=$rc passed=$p failed=$f skipped=$s"
        if [ "$rc" != 0 ] || [ "$f" != 0 ] || [ "$s" != 0 ] || [ "$p" = 0 ]; then
          TESTS_OK=0; blocker "mlx-swift SmallMRouteTests did not all pass (rc=$rc passed=$p failed=$f skipped=$s)"
        fi
      else
        log "FORK_TESTS_UNAVAILABLE no test bundle under $LAB/fork-mlx-swift-build/debug"
      fi
    else
      log "FORK_TESTS_UNAVAILABLE the checkout copy does not build: $(grep -m2 'error:' "$RES/fork-tests-build.log" | tr '\n' ' ' | cut -c1-300)"
    fi
  fi
else
  log "TESTS_SKIPPED (SKIP_TESTS=1)"
fi

# 4. Serves.
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
# cached_turns_settled DIR: the startup cached-turns probe (SPEC-038 AC-26 leg (a)) has decided
# (serve.err), or a stored record already carries its result, or no stored record granted
# batching (then no probe runs). The probe runs only while the serve is idle, so the cells wait.
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
  local label=$1 mode=$2 seed=$3
  local d=$RES/$label s want_mode want_reason ev rc
  s=$d/serve
  mkdir -p "$s"
  local fg; fg=$(free_gb)
  log "SERVE_START $label mode=$mode free_gb=$fg seed=${seed:-none}"
  [ "${fg:-0}" -ge $((2 * MODEL_GB + 10)) ] || { blocker "$label: ${fg} GB free; a native-MTP start needs >= $((2 * MODEL_GB + 10)) (whole-model capture, #2468)"; return 1; }
  /usr/bin/python3 -I - "$PKG/catalog/autotune/autotune-candidates.json" "$MODEL_KEY" "$MODEL_SHA" "$DURABLE" "$PORT" "$s" "$mode" \
    > "$s/config.yaml" <<'PY' || { blocker "$label: config generation failed"; return 1; }
import hashlib, json, sys
cand, key, sha, path, port, sdir, mode = sys.argv[1:8]
raw = open(cand, "rb").read()
doc = json.loads(raw)
row = doc["rows"][key]
q = json.dumps
lines = [f"model: {q(key)}", f"model_artifact_path: {q(path)}", f"model_artifact_sha256: {sha}",
         f"port: {port}", f"ctl_socket_path: {q(sdir + '/ctl.sock')}", "credential_store: protected_file",
         "native_mtp_mode: auto", f"model_catalog_key: {q(key)}", f"model_catalog_model_id: {q(row['model_id'])}",
         f"model_catalog_revision: {q(row['model_revision'])}", f"model_catalog_sha256: {q(sha)}",
         f"model_catalog_version: {q(doc['version'])}", f"model_catalog_hash: {q(hashlib.sha256(raw).hexdigest())}"]
if mode == "A":
    # SPEC-038 FR-CB9 operator override: today's process-wide row_invariant for a native-MTP process.
    lines.append("small_m_route: row_invariant")
print("\n".join(lines))
PY
  if [ -n "$seed" ]; then cp "$seed" "$s/cb-self-check.json" && chmod 600 "$s/cb-self-check.json"; fi
  echo '{}' > "$d/grid.json"
  read -r -a envs <<< "${SERVE_ENV:-LAB_2462=1}"
  (cd "$BIN" && exec env "${envs[@]}" ./macprovider-cli serve --config "$s/config.yaml" --no-join \
     > "$s/serve.out" 2> "$s/serve.err" < /dev/null) &
  SERVE_PID=$!
  wait_until "$SERVE_PID" "$s/serve.err" model_loaded; rc=$?
  [ $rc = 0 ] || { blocker "$label: serve not ready (rc=$rc: 5 exited, 4 stalled): $(tail -n 3 "$s/serve.err" | tr '\n' ' ' | cut -c1-300)"; stop_serve; return 1; }
  curl -s "http://127.0.0.1:$PORT/v1/status" > "$s/status-ready.json"
  log "SERVE_READY $label $(grep -m1 'event=small_m_route mode=' "$s/serve.err" | cut -c1-300)"
  /usr/bin/python3 -I "$GRID/route_status.py" gate --port "$PORT" --serve-err "$s/serve.err" --pid "$SERVE_PID" \
    --stall-s "$STALL_S" --poll-s 10 > "$s/warmup.log" 2>&1; rc=$?
  log "CB_WARMUP $label rc=$rc $(grep -E '^CB_WARMUP' "$s/warmup.log" | tail -n 1)"
  [ $rc != 5 ] || { blocker "$label: serve exited during the CB warm-up"; stop_serve; return 1; }
  # Stall clock on the self-check store: the probe rewrites it when it decides.
  wait_until "$SERVE_PID" "$s/cb-self-check.json" cached_turns_settled "$s"; rc=$?
  log "CACHED_TURNS $label rc=$rc $(grep 'action=cached_turns_decided' "$s/serve.err" | tail -n 1 | cut -c1-200)"
  [ $rc != 5 ] || { blocker "$label: serve exited before the cached-turns probe settled"; stop_serve; return 1; }
  if [ "$mode" = A ]; then want_mode=row_invariant want_reason=operator_row_invariant
  else want_mode=mixed want_reason=native_mtp_per_request; fi
  ev=$(grep -m1 'event=small_m_route mode=' "$s/serve.err")
  case "$ev" in *"mode=$want_mode reason=$want_reason"*) ;; *)
    blocker "$label: startup route is not mode=$want_mode reason=$want_reason: ${ev:-no event=small_m_route line}"; stop_serve; return 1 ;;
  esac
  curl -s "http://127.0.0.1:$PORT/v1/status" > "$s/status.json"
  local route_ok=1
  labelled "$label" /usr/bin/python3 -I "$GRID/route_status.py" record --status "$s/status.json" --serve-err "$s/serve.err" \
    --grid "$d/grid.json" --phase start --expect batched || route_ok=0
  labelled "$label" /usr/bin/python3 -I "$GRID/route_status.py" native-mtp --status "$s/status.json" --grid "$d/grid.json" \
    --phase start --expect on || route_ok=0
  st_route=$(/usr/bin/python3 -I -c 'import json,sys; print((json.load(open(sys.argv[1])).get("continuous_batching") or {}).get("small_m_route"))' "$s/status.json")
  [ "$st_route" = "$want_mode" ] || route_ok=0
  log "ROUTE_CHECK $label status_small_m_route=$st_route want=$want_mode ok=$route_ok"
  [ $route_ok = 1 ] || { blocker "$label: route not batched, native MTP not on, or status route $st_route != $want_mode; no cells"; stop_serve; return 1; }
  log "CELLS_START $label"
  /usr/bin/python3 -I "$HERE/mixed_load.py" --port "$PORT" --model "$MODEL_KEY" --label "$label" --out "$d/rows.jsonl" \
    --trials "$TRIALS" --ctx "$CTX" --ord-rows "$ORD_ROWS" --ord-out "$ORD_OUT" --nat-out "$NAT_OUT" \
    > "$d/cells.log" 2>&1; rc=$?
  grep '^TRIAL ' "$d/cells.log" | sed 's/^/CELL /'
  log "CELLS_DONE $label rc=$rc"
  [ $rc = 0 ] || blocker "$label: a request failed: $(grep -v '^TRIAL ' "$d/cells.log" | tail -n 3 | tr '\n' ' ' | cut -c1-300)"
  curl -s --max-time 10 "http://127.0.0.1:$PORT/v1/status" > "$s/status-end.json"
  labelled "$label" /usr/bin/python3 -I "$GRID/route_status.py" record --status "$s/status-end.json" --serve-err "$s/serve.err" \
    --grid "$d/grid.json" --phase end --expect batched || blocker "$label: route not batched at the end"
  labelled "$label" /usr/bin/python3 -I "$GRID/route_status.py" native-mtp --status "$s/status-end.json" --grid "$d/grid.json" \
    --phase end --expect on || blocker "$label: native MTP not on at the end"
  stop_serve
  for _ in $(seq 1 60); do listening "$PORT" || break; sleep 1; done
  log "SERVE_END $label free_gb=$(free_gb) captures=$(ls -d "$(dirname "$DURABLE")"/.native-mtp-admission-capture-* 2>/dev/null | wc -l | tr -d ' ')"
  return $rc
}

declare -a SEEN_LABELS=()
for spec in $SERVES; do
  label=${spec%%:*}; mode=${spec#*:}
  case "$mode" in A|B) ;; *) die "SERVES entry $spec: mode must be A or B" 64 ;; esac
  seed=""
  for prev in "${SEEN_LABELS[@]+"${SEEN_LABELS[@]}"}"; do
    [ "${prev#*:}" = "$mode" ] && [ -s "$RES/${prev%%:*}/serve/cb-self-check.json" ] && seed=$RES/${prev%%:*}/serve/cb-self-check.json
  done
  run_serve "$label" "$mode" "$seed" || FAILED=1
  SEEN_LABELS+=("$spec")
done

# 5. Verdict.
/usr/bin/python3 -I "$HERE/verdict.py" --res "$RES" --serves "$(echo $SERVES | tr ' ' ',')" --ord-rows "$ORD_ROWS" \
  --tests-ok "$TESTS_OK" --json "$RES/verdict.json" > "$RES/verdict.md" 2>&1
vrc=$?
cat "$RES/verdict.md"
[ "$vrc" -le 1 ] || blocker "verdict.py rc=$vrc (unusable input)"
[ "$FAILED" = 0 ] || { log "JOB_FAIL"; exit 1; }
log "JOB_PASS"
