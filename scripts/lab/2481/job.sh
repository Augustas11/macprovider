#!/bin/bash
# Runs ON THE STUDIO, started detached by the #2481 window wrapper, which has already paused live,
# the runner's Studio target and the FLOP miner and holds the Studio GPU lock. This job never
# pauses, restores or restarts any of them; it refuses to start while anything still runs.
#
# #2481: Qwen3.6-35B-A3B's native-MTP self-check passed at 1.11 on the 64-token challenge while
# one-row native MTP served 2-8% below ordinary decode in the engine-333 parity grid. The branch
# self-check (SPEC-048 0.1.125) adds the grid's ctx200/out128 and ctx4000/out256 probe points,
# times ordinary decode on the route an ordinary request takes with native MTP off, and admits
# native MTP only above 1.03x at every point. This job checks that verdict against the grid.
#
# Steps:
#  1. preflight: nothing on :8080/:8000/:$PORT, no live agent, serve, FLOP agent or VM process;
#     free disk >= MIN_FREE_GB (each native-MTP start byte-copies the model, #2468); $SRC at $COMMIT;
#  2. two release builds, each with the mlx.metallib built from its own mlx-swift checkout (as
#     engine-333/studio-run.sh): `branch` = $SRC at $COMMIT, `base` = BASE_COMMIT (default: the
#     merge-base of $COMMIT and origin/main; the same decode path with the old self-check, which
#     admits native MTP, so its native cells are the native side of the grid);
#  3. three parity-grid runs (run-grid.sh), rows 1, outputs 128,512, contexts short (200) and 4k
#     (4000), TRIALS trials, the production route (--cb auto, no autotune flag), the signed CB tuple
#     of this hardware class as an accepted tuple:
#       ordinary = branch, native MTP off (the "ordinary req tok/s" column of #2481);
#       native   = base, native_mtp_mode auto + catalog provenance, --expect-native-mtp on;
#       served   = branch, native_mtp_mode auto + catalog provenance, --expect-native-mtp any:
#                  its serve logs the new self-check (`event=native_mtp_self_check_point` per point,
#                  `event=native_mtp_self_check result=`), and its cells are what the branch serves.
#     A native-MTP serve that is refused with small_m_route_stock_order before the small-M verdict
#     exists is started once more (the verdict is recorded by the first start, as in #2465);
#  4. SELFCHECK_EVENT lines from both native-MTP serves, compare.py --subset tables
#     (native vs ordinary, served vs ordinary), then verdict.py: T2481_CELL per cell,
#     T2481_SELFCHECK, T2481_VERDICT. JOB_PASS when the branch self-check agrees with the grid
#     (admitted only if native beats ordinary in every cell; refused only if some cell is below the
#     1.03 margin), else JOB_FAIL.
# Knobs: TRIALS (3) MIN_FREE_GB (100) SKIP_BUILD PORT (18481) BASE_COMMIT MODEL_DIR STALL_S (1800).
# JOB_CHECK=1 validates the inputs and prints the plan, then exits 0 before touching anything.
# Watchdogs are stall detectors only (run-grid's warm-up stall bound), never wall-clock cuts.
# Every failure prints `BLOCKER:`; the job ends with JOB_PASS or JOB_FAIL.
set -u
export PATH=/usr/sbin:/opt/homebrew/bin:/usr/bin:/bin
LAB=$HOME/lab-2481
RUN_ID=${RUN_ID:?RUN_ID unset}
SRC=${SRC:?SRC unset}
COMMIT=${COMMIT:?COMMIT unset}
PKG=$SRC/phase3-binary
HERE=$SRC/scripts/lab/2481
PG=$SRC/scripts/lab/parity-grid
CAT=$PKG/catalog/autotune
RES=$LAB/results/$RUN_ID
STORE="$HOME/Library/Application Support/macprovider/models"
MODEL_KEY=qwen/qwen3.6-35b-a3b
MODEL_DIR=${MODEL_DIR:-$(ls -d "$STORE"/mlx-community--Qwen3.6-35B-A3B-4bit/*/* 2>/dev/null | head -n 1)}
BUILD=.build-lab-2481
BASE_SRC=$LAB/base-src
PORT=${PORT:-18481}
TRIALS=${TRIALS:-3}
MIN_FREE_GB=${MIN_FREE_GB:-100}
STALL_S=${STALL_S:-1800}
export DEVELOPER_DIR="${DEVELOPER_DIR:-$HOME/Applications/Xcode.app/Contents/Developer}"
log() { echo "$(date '+%H:%M:%S') $*"; }
die() { log "BLOCKER: $*"; log "JOB_FAIL"; exit "${2:-1}"; }
free_gb() { df -g "$HOME" | awk 'NR==2 {print $4}'; }
listening() { lsof -nP -iTCP:"$1" -sTCP:LISTEN -t >/dev/null 2>&1; }
echo "$COMMIT" | grep -Eq '^[0-9a-f]{40}$' || die "COMMIT must be the 40-hex campaign commit" 64
[ "$(git -C "$SRC" rev-parse HEAD 2>/dev/null)" = "$COMMIT" ] || die "$SRC is not at $COMMIT" 64
BASE_COMMIT=${BASE_COMMIT:-$(git -C "$SRC" merge-base "$COMMIT" origin/main 2>/dev/null)}
echo "$BASE_COMMIT" | grep -Eq '^[0-9a-f]{40}$' || die "no base commit (fetch origin in $SRC or set BASE_COMMIT)" 64
[ "$BASE_COMMIT" != "$COMMIT" ] || die "BASE_COMMIT is the campaign commit" 64
[ -n "$MODEL_DIR" ] && [ -f "$MODEL_DIR/config.json" ] || die "no Qwen3.6-35B-A3B snapshot in the store (MODEL_DIR)" 11
MODEL_SHA=$(basename "$MODEL_DIR")
for f in "$PKG/Package.swift" "$PG/run-grid.sh" "$PG/compare.py" "$HERE/verdict.py" \
         "$CAT/autotune-candidates.json" "$CAT/continuous-batching-policy.json"; do
  [ -f "$f" ] || die "source tree incomplete: no $f" 11
done
HW="apple-silicon:$(sysctl -n machdep.cpu.brand_string):ram-$(( $(sysctl -n hw.memsize) / 1073741824 ))gb"
PLAN="run=$RUN_ID commit=$COMMIT base=$BASE_COMMIT model=$MODEL_DIR trials=$TRIALS port=$PORT hw=$HW"
if [ "${JOB_CHECK:-0}" = 1 ]; then
  log "JOB_CHECK $PLAN"
  log "JOB_CHECK runs: ordinary(branch) native(base) served(branch); rows 1; out 128,512; ctx short,4k"
  exit 0
fi
mkdir -p "$RES"
log "JOB_START $PLAN"

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
[ "${fg:-0}" -ge "$MIN_FREE_GB" ] || die "only ${fg} GB free; need $MIN_FREE_GB (two builds, native-MTP whole-model capture per start)" 13

# 2. Builds: build TREE NAME -> $TREE/phase3-binary/$BUILD/release with its own metallib.
build() {
  local pkg=$1/phase3-binary name=$2 bin=$1/phase3-binary/$BUILD/release
  if [ "${SKIP_BUILD:-0}" != 1 ]; then
    log "BUILD_START $name"
    (cd "$pkg" && nice -n 10 swift build -c release --product macprovider-cli --build-path "$BUILD") \
      > "$RES/build-$name.log" 2>&1 || die "$name release build failed: $(grep -m3 'error:' "$RES/build-$name.log" | tr '\n' ' ' | cut -c1-400)" 14
    MLX_SWIFT_CHECKOUT=$pkg/$BUILD/checkouts/mlx-swift bash "$pkg/scripts/build-mlx-metallib.sh" "$bin" \
      > "$RES/metallib-$name.log" 2>&1 || die "$name metallib build failed: $(tail -n 2 "$RES/metallib-$name.log" | tr '\n' ' ')" 14
  fi
  [ -x "$bin/macprovider-cli" ] && [ -s "$bin/mlx.metallib" ] || die "no $name binary and metallib in $bin" 14
  shasum -a 256 "$bin/macprovider-cli" "$bin/mlx.metallib" > "$RES/identity-$name.sha256"
  log "BUILD_DONE $name $("$bin/macprovider-cli" --version 2>&1 | head -n 1)"
}
if [ "${SKIP_BUILD:-0}" != 1 ]; then
  rm -rf -- "$BASE_SRC" && mkdir -p "$BASE_SRC" || die "base tree setup failed" 11
  git -C "$SRC" archive "$BASE_COMMIT" | tar -x -C "$BASE_SRC" || die "git archive of $BASE_COMMIT failed" 11
fi
build "$SRC" branch
build "$BASE_SRC" base
BRANCH_BIN=$PKG/$BUILD/release
BASE_BIN=$BASE_SRC/phase3-binary/$BUILD/release

# 3. Grid runs.
# cb_extra METALLIB_SHA FILE: the signed CB entry of the model on this hardware class as an accepted
# tuple (with the binary's own metallib); exits 3 when there is none.
cb_extra() {
  /usr/bin/python3 -I - "$CAT/continuous-batching-policy.json" "$MODEL_KEY" "$HW" "$1" "$2" <<'PY'
import json, sys
policy, key, hw, metallib, out = sys.argv[1:6]
es = [e for e in json.load(open(policy))["entries"] if e["model_id"] == key and e["hardware_class"] == hw]
if not es:
    sys.exit(3)
e = dict(es[-1]); e["metallib_sha256"] = metallib
keys = ("model_id", "model_sha256", "tokenizer_sha256", "chat_template_sha256", "cache_class", "kv_dtype",
        "requires_moe", "hardware_class", "metallib_sha256", "kernel_identifier", "cached_turns_accepted")
open(out, "w").write("\n".join([
    "continuous_batching: canary", "continuous_batching_cached_turns: true",
    f"continuous_batch_queue_limit: {e.get('max_served_slots') or 4}",
    "continuous_batching_accepted_tuples:",
    "  - {" + ", ".join(f"{k}: {json.dumps(e[k])}" for k in keys if k in e) + "}"]) + "\n")
PY
}
# mtp_extra FILE: native_mtp_mode auto and the model_catalog_* provenance (the signed admission set).
mtp_extra() {
  /usr/bin/python3 -I - "$CAT/autotune-candidates.json" "$MODEL_KEY" "$MODEL_SHA" "$1" <<'PY'
import hashlib, json, sys
cand, key, sha, out = sys.argv[1:5]
raw = open(cand, "rb").read(); doc = json.loads(raw); row = doc["rows"].get(key)
if row is None: sys.exit(f"no candidates row {key}")
if row["model_sha256"] != sha: sys.exit(f"candidates row {key} has sha {row['model_sha256']}, not {sha}")
q = json.dumps
open(out, "a").write("\n".join([
    "native_mtp_mode: auto", f"model_catalog_key: {q(key)}", f"model_catalog_model_id: {q(row['model_id'])}",
    f"model_catalog_revision: {q(row['model_revision'])}", f"model_catalog_sha256: {q(sha)}",
    f"model_catalog_version: {q(doc['version'])}", f"model_catalog_hash: {q(hashlib.sha256(raw).hexdigest())}"]) + "\n")
PY
}
# grid TAG BIN MTP(on|any|off): one run-grid.sh run into $RES/TAG.
grid() {
  local tag=$1 bin=$2 mtp=$3 R=$RES/$1 route=any msha crc rc attempt
  for attempt in 1 2; do
    rm -rf -- "$R"; mkdir -p "$R"
    msha=$(shasum -a 256 "$bin/mlx.metallib" | cut -d' ' -f1)
    : > "$R/serve-extra.yaml"
    cb_extra "$msha" "$R/serve-extra.yaml"; crc=$?
    if [ $crc -eq 0 ]; then
      [ "$mtp" = off ] && route=batched
    elif [ $crc -ne 3 ]; then
      die "CB tuple for $MODEL_KEY failed" 11
    fi
    if [ "$mtp" != off ]; then mtp_extra "$R/serve-extra.yaml" || die "native-MTP provenance for $MODEL_KEY failed" 11; fi
    local args=(--model-path "$MODEL_DIR" --model-id "$MODEL_KEY" --model-sha256 "$MODEL_SHA" --model-name qwen36-35b-a3b
                --bin-dir "$bin" --out-dir "$R" --port "$PORT" --trials "$TRIALS" --skip-reference --skip-compare
                --cb auto --no-autotune-candidate --rows 1 --outputs 128,512 --contexts short,4k
                --expect-route "$route" --config-extra "$R/serve-extra.yaml" --warmup-stall-s "$STALL_S")
    [ "$mtp" = off ] || args+=(--expect-native-mtp "$mtp")
    log "GRID_START $tag attempt=$attempt"
    bash "$PG/run-grid.sh" "${args[@]}" > "$R/run.log" 2>&1
    rc=$?
    grep -h "^ROUTE\|NATIVE_MTP\|CB_WARMUP_DONE" "$R/run.log" | tail -n 4 | sed "s/^/GRID_$tag /"
    log "GRID_DONE $tag rc=$rc"
    # The first native-MTP start of a fresh small-M verdict store is refused (stock order route)
    # and records the verdict; the second start runs mixed and admits native MTP (#2465).
    if [ "$mtp" != off ] && [ "$attempt" = 1 ] \
       && ! grep -q 'event=native_mtp_self_check result=' "$R/serve/serve.err" 2>/dev/null \
       && grep -q 'small_m_route_stock_order' "$R/serve/serve.err" 2>/dev/null; then
      log "GRID_RESTART $tag native MTP refused before the small-M verdict existed"
      continue
    fi
    break
  done
  [ -s "$R/provider.jsonl" ] || die "grid $tag produced no provider.jsonl (rc=$rc): $(tail -n 3 "$R/run.log" | tr '\n' ' ' | cut -c1-400)" 15
  [ $rc -eq 0 ] || [ $rc -eq 1 ] || die "grid $tag failed rc=$rc: $(tail -n 3 "$R/run.log" | tr '\n' ' ' | cut -c1-400)" 15
}
grid ordinary "$BRANCH_BIN" off
grid native "$BASE_BIN" on
grid served "$BRANCH_BIN" any

# 4. Evidence and verdict.
for tag in native served; do
  grep -E 'event=(native_mtp_self_check[a-z_]*|small_m_route)' "$RES/$tag/serve/serve.err" | cut -c1-400 | sed "s/^/SELFCHECK_EVENT $tag /"
done
for tag in native served; do
  /usr/bin/python3 -I "$PG/compare.py" --subset --baseline "$RES/ordinary/provider.jsonl" --ours "$RES/$tag/provider.jsonl" \
    --json "$RES/compare-$tag-vs-ordinary.json" > "$RES/compare-$tag-vs-ordinary.md" 2>&1
  log "COMPARE $tag vs ordinary rc=$?"; cat "$RES/compare-$tag-vs-ordinary.md"
done
/usr/bin/python3 -I "$HERE/verdict.py" --ordinary "$RES/ordinary/provider.jsonl" --native "$RES/native/provider.jsonl" \
  --served "$RES/served/provider.jsonl" --selfcheck-log "$RES/served/serve/serve.err" \
  --base-selfcheck-log "$RES/native/serve/serve.err" --json "$RES/verdict.json"
vrc=$?
[ $vrc -eq 0 ] || { log "JOB_FAIL verdict rc=$vrc ($RES/verdict.json)"; exit 1; }
log "JOB_PASS $RES/verdict.json"
