#!/bin/bash
# Runs ON THE STUDIO inside a paused Studio window, started detached by studio-2467-uncensored.sh
# (which holds the Studio GPU lock and refuses to start unless live, the runner's Studio target
# and the FLOP miner are paused). This job never pauses, restores or restarts any of them; it
# refuses to start when anything still runs. #2467: the uncensored Inkling-2-Mini row in the
# layout the catalog serves (mlx-community/Inkling-2-Mini-oQ4e-mtp @ 3eea0427), by splice, then
# its checks. Modeled on scripts/lab/ablit-perf/job-dsv4-abliterated.sh.
#
# Why a splice: OpenUncensored/Inkling-2-Mini-Uncensored @ 4e5f06d7 keeps the original
# thinkingmachines/Inkling-2-Mini @ b85c3cfa checkpoint format and, per its card, changed only
# the 20 attention output projections. So: the oQ4e base with those projections re-quantized in
# the base's own format for them, every other file byte-identical. The source's edit.pt (a
# PyTorch pickle) is never downloaded, opened or unpickled; tensors are read only through
# safetensors headers and byte ranges.
#
# Steps (every failure prints `BLOCKER:` and the job ends JOB_FAIL, nonzero):
#  0. preflight: nothing on :8080/:8000, no serve, no FLOP agent, no VM process; free disk
#     >= MIN_FREE_GB; python3.12, the metallib and the full Xcode exist;
#  1. the fork's release test build (Inkling2RealParityTests), in the background while 2-5 run
#     (SKIP_BUILD=1 reuses $FORK/.build-tests-release when its marker names FORK_COMMIT);
#  2. reference venv (mlx 0.32.4, mlx-vlm @ f1618d6d), reused when its marker matches;
#  3. the base: the oQ4e-mtp download of the earlier #2467 windows (downloaded when absent),
#     APFS-cloned, `.cache` and download markers dropped, verified against the catalog snapshot
#     manifest 75509c7f;
#  4. fetch (inkling2_uncensored_splice.py): pinned API listings; the source listing must equal
#     the committed source manifest 050f1cec; downloads only the source's weight shard, index
#     and config (~19.5 GB), and whatever the original's directory lacks of the same files;
#  4b. recipe: every base attn.o_proj against the oQ quantizer (ported from oMLX) of the original attn.wo_ud of its
#     layer, in the base's format; refuses unless the base is a plain quantization of that
#     tensor (absolute error bound) and our recipe errs no more than ERROR_RATIO x the base's;
#  5. diff: tensor by tensor against the original; refuses unless exactly EXPECT_CHANGED (20)
#     tensors differ and all are attention output projections (attn.wo_ud.weight), and unless
#     every other source file equals the original's (edit.pt the only extra);
#  6. splice into an APFS clone of the base: each changed projection re-quantized with
#     the oQ quantizer in the base's format for that module (read from its config quantization map),
#     the recipe re-checked on the original projections, the numeric gate (spliced error vs
#     uncensored BF16 within ERROR_RATIO of the base's own error vs original BF16, per layer),
#     written in place, every other tensor and file verified byte-identical to the base;
#  7. mlx-vlm greedy oracle on the spliced artifact (fork tools/inkling2_parity/dump_real_oracle.py,
#     oQ layout, 1024 and 8192 tokens, 64 steps, GPU), the reference the #2467 slice-3/4 parity
#     used;
#  8. Swift parity: Inkling2RealParityTests (compiled path, exact mode) on the spliced artifact
#     against that oracle; gate: every greedy token equal at 1024 and 8192. On a gate failure the
#     same check runs on the base against its own oracle ($LAB/oracle-real-oq, from the earlier
#     window, dumped when absent) to tell a splice effect from a port gap;
#  9. refusal probe: REFUSAL_N harmful + REFUSAL_N harmless prompts, base vs uncensored, both
#     through mlx-vlm on the oQ tensors (inkling2_refusal_probe.py), greedy; gate: the
#     uncensored build answers at least one harmful prompt the base refuses (REFUSAL_FLIP);
# 10. provenance.json (catalog-row inputs), artifact unchanged after every reader;
# 11. only with PUBLISH=1 (default off: it uploads), after JOB_PASS:
#     publish_inkling2_uncensored.py stages the artifact with a model card and uploads it to
#     aug11/Inkling-2-Mini-oQ4e-mtp-uncensored with the Studio's HF token, --expect-stage =
#     provenance model_sha256, then checks every remote file and prints PUBLISH_DONE with the
#     revision and the stage manifest. A failure prints BLOCKER and PUBLISH_FAIL and exits 20.
# Knobs: MIN_FREE_GB (60) EXPECT_CHANGED (20, or `any`) ERROR_RATIO (1.25) MAX_ERROR_RATIO (2.0)
#   REFUSAL_N (8) REFUSAL_MAX_TOKENS (160) REFUSAL_DATA (~/lab-2376/job/data, else the HF
#   datasets server) SKIP_BUILD KEEP_SOURCE (1 keeps the ~19.5 GB source after a pass) PUBLISH
#   PUBLISH_ARGS (e.g. --dry-run or --private) METALLIB.
# `job-inkling2-uncensored.sh --dry-run` (or DRY_RUN=1) runs anywhere: checks the job files,
# parses every helper, runs `fetch --plan-only` (API listings only, no download) and prints the
# plan; it builds, loads, downloads and uploads nothing.
set -u
export PATH=/usr/sbin:/opt/homebrew/bin:/usr/bin:/bin
# The oracle and probe import the fork's tools; bytecode written beside a model would change
# its manifest after it was recorded. -I ignores PYTHONDONTWRITEBYTECODE, so calls pass -B too.
export PYTHONDONTWRITEBYTECODE=1 HF_HUB_DISABLE_TELEMETRY=1 TOKENIZERS_PARALLELISM=false
DRY=${DRY_RUN:-0}
[ "${1:-}" = --dry-run ] && DRY=1
HERE="$(cd "$(dirname "$0")" && pwd)"
JOB=$(dirname "$HERE")   # job/: 2467, dsv4, minimax, evidence side by side
LAB=$HOME/lab-2467
RUN_ID=${RUN_ID:-$(date -u +%Y%m%dT%H%M%SZ)}
SRC=${SRC:-$(dirname "$JOB")}
FORK=${FORK:-$SRC/fork}
FORK_COMMIT=${FORK_COMMIT:-unknown}
RES=$LAB/results/$RUN_ID/uncensored
MODELS=$LAB/models
ORIG_REV=b85c3cfa615fc413cc9af3379f491b963f3b586a
OQ_REPO=mlx-community/Inkling-2-Mini-oQ4e-mtp
OQ_REV=3eea042751cd296b7266628a8342c1749242e1fe
OQ_SHA256=75509c7fcd864d109d542676ed14763a2c5c570c731f3c1d1180d0207b6b9b34
SRC_REV=4e5f06d72b5a70c9dcd5e8046aea576eb3ee8487
ORIG=$MODELS/Inkling-2-Mini@${ORIG_REV:0:8}
OQ_DL=$MODELS/Inkling-2-Mini-oQ4e-mtp@${OQ_REV:0:8}
BASE=$MODELS/Inkling-2-Mini-oQ4e-mtp-base
SOURCE=$MODELS/Inkling-2-Mini-Uncensored-source@${SRC_REV:0:8}
UNC=$MODELS/Inkling-2-Mini-oQ4e-mtp-uncensored
BASE_ORACLE=$LAB/oracle-real-oq
METALLIB=${METALLIB:-/Applications/Malibu.app/Contents/MacOS/mlx.metallib}
PY312=/opt/homebrew/opt/python@3.12/bin/python3.12
VLM_REV=f1618d6d52be4ef25d3fe65270f7528a59c55df3
VENV=$LAB/venv-vlm-${VLM_REV:0:7}
PY=$VENV/bin/python
TEST_DEV=${DEVELOPER_DIR:-$HOME/Applications/Xcode.app/Contents/Developer}
RB=$FORK/.build-tests-release
TOOLS=$FORK/tools/inkling2_parity
SPLICE=$HERE/inkling2_uncensored_splice.py
PROBE=$HERE/inkling2_refusal_probe.py
PUBLISH_PY=$HERE/publish_inkling2_uncensored.py
REFCHECK=$JOB/dsv4/dsv4_refusal_check.py
MANIFEST_LIB=$JOB/minimax/publish_abliterated.py
SOURCE_MANIFEST=$JOB/evidence/openuncensored-source-050f1cec.manifest
# In a checkout (dry run) the manifest sits in the intake evidence, not in job/evidence.
[ -f "$SOURCE_MANIFEST" ] || SOURCE_MANIFEST=$HERE/../../../docs/evidence/inkling-2-mini-intake-2026-11-24/openuncensored-source-050f1cec.manifest
MIN_FREE_GB=${MIN_FREE_GB:-60}
EXPECT_CHANGED=${EXPECT_CHANGED:-20}
ERROR_RATIO=${ERROR_RATIO:-1.25}
MAX_ERROR_RATIO=${MAX_ERROR_RATIO:-2.0}
REFUSAL_N=${REFUSAL_N:-8}
REFUSAL_MAX_TOKENS=${REFUSAL_MAX_TOKENS:-160}
REFUSAL_DATA=${REFUSAL_DATA:-$HOME/lab-2376/job/data}
CTXS=1024,8192
BUILD_PID=""
log() { echo "$(date '+%H:%M:%S') $*"; }
die() { log "BLOCKER: $1"; log "JOB_FAIL rc=${2:-1}"; exit "${2:-1}"; }
xc() { env DEVELOPER_DIR="$TEST_DEV" "$@"; }
# The build stays in the job's process group, so the memory guard's group kill reaches it too.
trap '[ -n "$BUILD_PID" ] && { pkill -TERM -P "$BUILD_PID"; kill "$BUILD_PID"; } 2>/dev/null; true' EXIT

log "JOB_START inkling2-uncensored run=$RUN_ID fork=$FORK_COMMIT commit=${COMMIT:-unknown} dry_run=$DRY"
for f in "$SPLICE" "$PROBE" "$PUBLISH_PY" "$REFCHECK" "$MANIFEST_LIB" "$SOURCE_MANIFEST"; do
  [ -f "$f" ] || die "missing job file $f" 11
done
[ "$(shasum -a 256 "$SOURCE_MANIFEST" | cut -d' ' -f1)" = 050f1cec9aa9a78bb4b365bebf5cb4758e531713943bd2e8208d43ffd5c869e2 ] \
  || die "$SOURCE_MANIFEST is not the committed source manifest 050f1cec" 11

if [ "$DRY" = 1 ]; then
  # Parse only: no import runs the helpers' module code.
  for f in "$SPLICE" "$PROBE" "$PUBLISH_PY" "$REFCHECK" "$MANIFEST_LIB"; do
    /usr/bin/python3 -I -c 'import ast, sys; ast.parse(open(sys.argv[1]).read(), sys.argv[1])' "$f" || die "$f does not parse" 11
  done
  DRYRES=${TMPDIR:-/tmp}/inkling2-uncensored-dry-$RUN_ID
  mkdir -p "$DRYRES"
  /usr/bin/python3 -B -I "$SPLICE" fetch --plan-only --source "$DRYRES/source" --original "$DRYRES/original" \
    --source-manifest "$SOURCE_MANIFEST" --out "$DRYRES/fetch.json" || die "fetch --plan-only failed" 13
  rm -rf -- "$DRYRES"
  for step in "build: (cd $FORK && swift build -c release -Xswiftc -enable-testing --build-tests --build-system native --scratch-path $RB)" \
    "base: cp -c -R $OQ_DL $BASE; manifest must be $OQ_SHA256" \
    "fetch: $SPLICE fetch --source $SOURCE --original $ORIG" \
    "recipe: $SPLICE recipe --base $BASE --original $ORIG --error-ratio $ERROR_RATIO" \
    "diff: $SPLICE diff --expect-changed $EXPECT_CHANGED" \
    "splice: cp -c -R $BASE $UNC; $SPLICE splice --error-ratio $ERROR_RATIO --max-error-ratio $MAX_ERROR_RATIO" \
    "oracle: $TOOLS/dump_real_oracle.py --model $UNC --layout oq --contexts $CTXS --steps 64" \
    "parity: swift test --filter Inkling2RealParityTests INKLING2_REAL_MODEL=$UNC INKLING2_REAL_LAYOUT=oq INKLING2_COMPILED=1" \
    "refusal: $PROBE run base/uncensored, $REFUSAL_N + $REFUSAL_N prompts, compare" \
    "publish: only with PUBLISH=1 after JOB_PASS -> aug11/Inkling-2-Mini-oQ4e-mtp-uncensored"; do
    log "DRY_PLAN $step"
  done
  log "DRY_RUN_PASS (nothing built, loaded, downloaded or uploaded)"
  exit 0
fi

mkdir -p "$RES" "$MODELS"
# 0. Preflight.
busy=$( { lsof -nP -iTCP:8080 -sTCP:LISTEN -t; lsof -nP -iTCP:8000 -sTCP:LISTEN -t;
  pgrep -f "macprovider-cli serve"; pgrep -f "com.apple.Virtualization.VirtualMachine|limactl|mlx_service";
  launchctl list | grep com.flop; launchctl print "gui/$(id -u)/live.malibu.provider" >/dev/null 2>&1 && echo live.malibu.provider; } 2>/dev/null)
[ -z "$busy" ] || die "something still runs: $(echo "$busy" | tr '\n' ' ' | cut -c1-200)" 10
free_gb=$(df -g "$HOME" | awk 'NR==2 {print $4}')
[ "${free_gb:-0}" -ge "$MIN_FREE_GB" ] || die "free disk ${free_gb}G < ${MIN_FREE_GB}G" 10
log "DISK free=${free_gb}G"
[ -x "$PY312" ] || die "no python3.12 at $PY312" 10
[ -f "$METALLIB" ] || die "no metallib at $METALLIB" 10
[ -d "$TEST_DEV" ] || die "no Xcode developer dir at $TEST_DEV (XCTest needs the full Xcode)" 10
[ -f "$TOOLS/dump_real_oracle.py" ] && [ -f "$TOOLS/oq_adapter.py" ] || die "the fork at $FORK has no tools/inkling2_parity" 11
[ -f "$FORK/Tests/MLXLMTests/Inkling2ParityTests.swift" ] || die "the fork at $FORK has no Inkling2ParityTests" 11

manifest() {  # macprovider.snapshot-manifest.v1 of DIR, the catalog's model_sha256
  /usr/bin/python3 -B -I -c 'import sys,pathlib; sys.path.insert(0, sys.argv[1])
from publish_abliterated import snapshot_manifest_sha256 as m; print(m(pathlib.Path(sys.argv[2])))' "$(dirname "$MANIFEST_LIB")" "$1"
}

# 1. Fork release test build, in the background.
if [ "${SKIP_BUILD:-0}" = 1 ] && [ "$(cat "$RB/.built-commit" 2>/dev/null)" = "$FORK_COMMIT" ]; then
  log "BUILD_REUSED $RB ($FORK_COMMIT)"
else
  log "BUILD_START mlx-swift-lm $FORK_COMMIT release tests"
  ( cd "$FORK" && xc nice -n 10 swift build -c release -Xswiftc -enable-testing --build-tests --build-system native \
      --scratch-path "$RB" && echo "$FORK_COMMIT" > "$RB/.built-commit" ) > "$RES/fork-build-release-tests.log" 2>&1 &
  BUILD_PID=$!
fi

# 2. Reference venv.
if [ "$(cat "$VENV/.ok" 2>/dev/null)" != "$VLM_REV mlx==0.32.4" ]; then
  log "VENV_START $VENV"
  rm -rf "$VENV"
  { "$PY312" -m venv "$VENV" \
    && "$PY" -m pip install -q --upgrade pip \
    && "$PY" -m pip install -q "mlx==0.32.4" "mlx-vlm @ git+https://github.com/Blaizzy/mlx-vlm@$VLM_REV" huggingface_hub numpy; } \
    > "$RES/venv.log" 2>&1 || die "venv setup failed: $(tail -n 3 "$RES/venv.log" | tr '\n' ' ' | cut -c1-300)" 12
  echo "$VLM_REV mlx==0.32.4" > "$VENV/.ok"
fi
"$PY" -I -m pip freeze > "$RES/pip-freeze.txt" 2>/dev/null
grep -q '^mlx==0.32.4$' "$RES/pip-freeze.txt" && grep -q "mlx-vlm @ git+https://github.com/Blaizzy/mlx-vlm@$VLM_REV" "$RES/pip-freeze.txt" \
  || die "reference venv is not mlx 0.32.4 / mlx-vlm @ ${VLM_REV:0:8}" 12
log "VENV_DONE $(grep -E '^(mlx|mlx-metal|mlx-vlm|transformers|numpy)[ =@]' "$RES/pip-freeze.txt" | tr '\n' ' ' | cut -c1-300)"

# 3. The base (the download is only read; the clone is what every step uses).
if [ -d "$BASE" ] && [ "$(manifest "$BASE" 2>/dev/null)" = "$OQ_SHA256" ]; then
  log "CLONE_OK base manifest=$OQ_SHA256 (existing)"
else
  if [ ! -f "$OQ_DL/.complete-$OQ_REV" ]; then
    log "DOWNLOAD_START $OQ_REPO@${OQ_REV:0:8}"
    "$VENV/bin/hf" download "$OQ_REPO" --revision "$OQ_REV" --local-dir "$OQ_DL" > "$RES/download-oq.log" 2>&1 \
      && touch "$OQ_DL/.complete-$OQ_REV" || die "oQ4e-mtp download failed: $(tail -n 2 "$RES/download-oq.log" | tr '\n' ' ')" 13
  fi
  log "CLONE_START base from $OQ_DL"
  rm -rf -- "$BASE" && /bin/cp -c -R "$OQ_DL" "$BASE" || die "APFS clone of the base failed" 13
  rm -rf -- "$BASE/.cache" && rm -f -- "$BASE"/.complete-*
  got=$(manifest "$BASE") || die "manifest of $BASE failed" 13
  [ "$got" = "$OQ_SHA256" ] || die "base clone manifest $got is not the catalog artifact $OQ_SHA256" 13
  log "CLONE_OK base manifest=$got"
fi

# 4. Fetch: the source's weights, index and config only; the original's missing files.
log "FETCH_START"
"$PY" -B -I "$SPLICE" fetch --source "$SOURCE" --original "$ORIG" --source-manifest "$SOURCE_MANIFEST" \
  --out "$RES/fetch.json" 2>&1 | tee "$RES/fetch.log" | grep -E 'FETCH_PLAN|FETCH_OK|FETCH_PRESENT|FETCH_DONE|BLOCKER'
[ "${PIPESTATUS[0]}" = 0 ] || die "fetch failed: $(grep BLOCKER "$RES/fetch.log" | tail -n 1)" 13

# 4b. Recipe: the base's projections against our quantization of the original's, before any splice.
log "RECIPE_START"
"$PY" -B -I "$SPLICE" recipe --base "$BASE" --original "$ORIG" --out "$RES/recipe.json" --error-ratio "$ERROR_RATIO" \
  --max-error-ratio "$MAX_ERROR_RATIO" 2>&1 | tee "$RES/recipe.log" | grep -E 'RECIPE_GATE|BLOCKER'
[ "${PIPESTATUS[0]}" = 0 ] || die "recipe check failed: $(grep BLOCKER "$RES/recipe.log" | tail -n 1)" 15

# 5. Diff against the original.
log "DIFF_START expect_changed=$EXPECT_CHANGED"
"$PY" -B -I "$SPLICE" diff --source "$SOURCE" --original "$ORIG" --fetch "$RES/fetch.json" --out "$RES/diff.json" \
  --expect-changed "$EXPECT_CHANGED" 2>&1 | tee "$RES/diff.log" | grep -E 'DIFF_COMPARED|DIFF_DONE|BLOCKER'
[ "${PIPESTATUS[0]}" = 0 ] || die "diff failed: $(grep BLOCKER "$RES/diff.log" | tail -n 1)" 15

# 6. Splice into an APFS clone of the base.
log "SPLICE_START"
rm -rf -- "$UNC" && /bin/cp -c -R "$BASE" "$UNC" || die "APFS clone for the splice failed" 15
"$PY" -B -I "$SPLICE" splice --base "$BASE" --source "$SOURCE" --original "$ORIG" --fetch "$RES/fetch.json" \
  --diff "$RES/diff.json" --out "$UNC" --manifest "$RES/splice.json" --error-ratio "$ERROR_RATIO" \
  --max-error-ratio "$MAX_ERROR_RATIO" 2>&1 | tee "$RES/splice.log" | grep -E 'NUMERIC|SPLICE_WRITTEN|SPLICE_VERIFIED|SPLICE_DONE|BLOCKER'
[ "${PIPESTATUS[0]}" = 0 ] || { rm -rf -- "$UNC"; die "splice failed: $(grep BLOCKER "$RES/splice.log" | tail -n 1)" 15; }
UNC_SHA256=$(manifest "$UNC") || die "manifest of $UNC failed" 15
[ "$UNC_SHA256" != "$OQ_SHA256" ] || die "the spliced artifact equals the base" 15
[ "$(manifest "$BASE")" = "$OQ_SHA256" ] || die "the base clone changed during the splice" 15
log "SPLICE_ARTIFACT $UNC manifest=$UNC_SHA256 splice_sha256=$(shasum -a 256 "$RES/splice.json" | cut -d' ' -f1)"

# 7. mlx-vlm oracle on the spliced artifact (one model resident at a time).
oracle() {  # NAME MODEL OUT
  log "ORACLE_START $1 contexts=$CTXS"
  (cd "$FORK" && "$PY" -B -I tools/inkling2_parity/dump_real_oracle.py --model "$2" --layout oq --out "$3" \
    --contexts "$CTXS" --steps 64) > "$RES/oracle-$1.log" 2>&1 \
    || { log "BLOCKER: oracle $1 failed: $(tail -n 3 "$RES/oracle-$1.log" | tr '\n' ' ' | cut -c1-300)"; return 1; }
  log "ORACLE_DONE $1 $(tr -d ' \n' < "$3/oracle.json" | grep -o '"layout":"[a-z]*"')"
}
rm -rf -- "$RES/oracle-uncensored"
oracle uncensored "$UNC" "$RES/oracle-uncensored" || die "the mlx-vlm oracle on the spliced artifact failed" 16

# 8. Swift parity.
if [ -n "$BUILD_PID" ]; then
  log "BUILD_WAIT"
  wait "$BUILD_PID"; rc=$?; BUILD_PID=""
  [ "$rc" = 0 ] || die "fork release test build failed: $(grep -m5 'error:' "$RES/fork-build-release-tests.log" | tr '\n' ' ' | cut -c1-500)" 14
  log "BUILD_DONE"
fi
rbundle=$(ls -d "$RB"/release/*PackageTests.xctest 2>/dev/null | head -n 1)
[ -n "$rbundle" ] || die "no release test bundle under $RB/release" 14
cp "$METALLIB" "$rbundle/Contents/MacOS/mlx.metallib" && cp "$METALLIB" "$RB/release/mlx.metallib" || die "metallib copy failed" 14
parity() {  # NAME MODEL ORACLE
  local rc
  log "PARITY_START $1"
  (cd "$FORK" && INKLING2_COMPILED=1 INKLING2_REAL_MODE=exact INKLING2_REAL_MODEL="$2" INKLING2_REAL_ORACLE="$3" \
    INKLING2_REAL_LAYOUT=oq INKLING2_REAL_REPORT="$RES/parity-$1.json" \
    xc swift test -c release -Xswiftc -enable-testing --build-system native --skip-build --scratch-path "$RB" \
      --filter Inkling2RealParityTests) > "$RES/parity-$1.log" 2>&1
  rc=$?
  grep -E "^inkling2 real parity layout=[a-z]+ path=[a-z]+ length=" "$RES/parity-$1.log" | sed -E 's/ stepMaxDiffs=.*//' \
    | cut -c1-600 | sed "s/^/PARITY_ROW $1 /"
  grep -E "^inkling2 lever exactness " "$RES/parity-$1.log" | cut -c1-300 | sed "s/^/PARITY_LEVERS $1 /"
  /usr/bin/python3 -I - "$RES/parity-$1.json" "$rc" "$CTXS" > "$RES/parity-$1.verdict.json" <<'PYEOF'
import json, sys
path, rc, ctxs = sys.argv[1], int(sys.argv[2]), [int(c) for c in sys.argv[3].split(",")]
try:
    rows = json.load(open(path))
except (OSError, ValueError) as exc:
    rows, err = [], f"no report: {exc}"
else:
    err = None
out = [{"length": r["length"], "matching": r["matchingTokens"], "steps": r["steps"], "path": r["path"],
        "layout": r["layout"], "mean_kl": r["meanKL"], "decode_tps": r["decodeTokensPerSecond"]} for r in rows]
bad = [err] if err else []
if rc != 0:
    bad.append(f"swift test exit {rc}")
if sorted(r["length"] for r in out) != sorted(ctxs):
    bad.append(f"lengths {sorted(r['length'] for r in out)} are not {ctxs}")
bad += [f"{r['length']}: {r['matching']}/{r['steps']}" for r in out if r["matching"] != r["steps"] or r["steps"] <= 0]
bad += [f"{r['length']}: path {r['path']} layout {r['layout']}" for r in out if (r["path"], r["layout"]) != ("compiled", "oq")]
print(json.dumps({"pass": not bad, "failures": bad, "rows": out}, indent=2))
PYEOF
  local v
  v=$(/usr/bin/python3 -I -c 'import json,sys; d=json.load(open(sys.argv[1])); print("PASS" if d["pass"] else "FAIL " + "; ".join(d["failures"]))' "$RES/parity-$1.verdict.json")
  log "PARITY_GATE $1 $v"
  case "$v" in PASS) return 0 ;; *) return 1 ;; esac
}
if ! parity uncensored "$UNC" "$RES/oracle-uncensored"; then
  log "PARITY_CONTROL the gate failed; the same check on the base tells a splice effect from a port gap"
  if [ -f "$BASE_ORACLE/oracle.json" ] || oracle base "$BASE" "$BASE_ORACLE"; then
    parity base "$BASE" "$BASE_ORACLE" | sed 's/^/BASE_/'
  fi
  die "Swift parity on the spliced artifact failed (see PARITY_ROW lines and the BASE_ control)" 17
fi

# 9. Refusal probe, base vs uncensored, both oQ builds through mlx-vlm.
"$PY" -B -I "$REFCHECK" prompts "$RES/refusal-prompts.json" --data "$REFUSAL_DATA" --n "$REFUSAL_N" \
  || die "refusal prompts unavailable" 18
for side in base uncensored; do
  [ $side = base ] && dir=$BASE || dir=$UNC
  "$PY" -B -I "$PROBE" check "$dir" 2>&1 | tee -a "$RES/refusal-check.log" | grep -E '^REFUSAL_(CHECK|TEMPLATE)'
  [ "${PIPESTATUS[0]}" = 0 ] || die "chat template check ($side) failed: $(tail -n 2 "$RES/refusal-check.log" | tr '\n' ' ')" 18
  log "REFUSAL_START $side"
  "$PY" -B -I "$PROBE" run "$dir" "$RES/refusal-prompts.json" "$RES/refusal-$side.jsonl" --label $side --tools "$TOOLS" \
    --max-tokens "$REFUSAL_MAX_TOKENS" > "$RES/refusal-$side.log" 2>&1 \
    || die "refusal run ($side) failed: $(tail -n 2 "$RES/refusal-$side.log" | tr '\n' ' ' | cut -c1-300)" 18
done
"$PY" -B -I "$PROBE" compare "$RES/refusal-base.jsonl" "$RES/refusal-uncensored.jsonl" --n "$REFUSAL_N" \
  --json "$RES/refusal.json" || die "refusal gate failed" 18

# 10. Provenance for the catalog row.
/usr/bin/python3 -I - "$RES" "$UNC_SHA256" "$OQ_SHA256" "$FORK_COMMIT" "${COMMIT:-unknown}" > "$RES/provenance.json" <<'PYEOF' || die "provenance failed" 19
import hashlib, json, pathlib, sys
res, unc_sha, base_sha, fork, commit = pathlib.Path(sys.argv[1]), *sys.argv[2:6]
sp = json.loads((res / "splice.json").read_text())
diff = json.loads((res / "diff.json").read_text())
print(json.dumps({
    "schema": "macprovider.inkling2-uncensored-provenance.v1",
    "license": "apache-2.0",
    "model_sha256": unc_sha,
    "base_catalog_row": {"catalog_key": "thinkingmachines/inkling-2-mini", "model_sha256": base_sha,
                         "repo": sp["served_base"]["repo"], "revision": sp["served_base"]["revision"]},
    "source": sp["source"],
    "original": sp["original"],
    "method": "attention output projections (attn.wo_ud) edited by OpenUncensored; re-quantized into the oQ4e base's attn.o_proj format",
    "diff_sha256": hashlib.sha256((res / "diff.json").read_bytes()).hexdigest(),
    "splice_sha256": hashlib.sha256((res / "splice.json").read_bytes()).hexdigest(),
    "changed_tensors": len(diff["changed_tensors"]),
    "changed_layers": sorted(c["layer"] for c in diff["changed_tensors"]),
    "recipe_reproduced": sp["recipe_reproduced"],
    "worst_rel_fro_ratio": sp["worst_rel_fro_ratio"],
    "touched_shards": sp["touched_shards"],
    "parity": json.loads((res / "parity-uncensored.verdict.json").read_text()),
    "refusal": json.loads((res / "refusal.json").read_text()),
    "fork_commit": fork,
    "commit": commit,
}, indent=2, sort_keys=True))
PYEOF
log "PROVENANCE $RES/provenance.json model_sha256=$UNC_SHA256"
if [ "${KEEP_SOURCE:-0}" != 1 ]; then
  rm -rf -- "$SOURCE" && log "SOURCE_REMOVED $SOURCE (diff.json records it)"
fi
find "$UNC" "$BASE" -name __pycache__ -type d -prune -exec rm -rf {} + 2>/dev/null
[ "$(manifest "$UNC")" = "$UNC_SHA256" ] || die "the artifact changed after its manifest was recorded" 15
log "ARTIFACT_UNCHANGED manifest=$UNC_SHA256"
log "JOB_PASS"

# 11. Optional publish, after the pass (PUBLISH=1).
if [ "${PUBLISH:-0}" = 1 ]; then
  pfail() { log "BLOCKER: $*"; log "PUBLISH_FAIL"; exit 20; }
  EXPECT=$(/usr/bin/python3 -I -c 'import json,sys; print(json.load(open(sys.argv[1]))["model_sha256"])' "$RES/provenance.json") \
    || pfail "no model_sha256 in $RES/provenance.json"
  [ "$EXPECT" = "$UNC_SHA256" ] || pfail "provenance model_sha256 $EXPECT is not this run's artifact $UNC_SHA256"
  case " ${PUBLISH_ARGS:-} " in *" --dry-run "*) ;; *)
    "$PY" -c 'import huggingface_hub, hf_xet' 2>/dev/null || "$PY" -m pip install -q "hf_xet==1.8.0" > "$RES/publish-pip.log" 2>&1 \
      || pfail "hf_xet install failed"
    [ -x "$VENV/bin/hf" ] || pfail "no hf CLI in $VENV/bin" ;;
  esac
  read -r -a PARGS <<< "${PUBLISH_ARGS:-}"
  log "PUBLISH_START expect_stage=$EXPECT args=${PUBLISH_ARGS:-}"
  "$PY" -B -I "$PUBLISH_PY" "$UNC" "$RES" "$LAB/publish/Inkling-2-Mini-oQ4e-mtp-uncensored" \
    --expect-stage "$EXPECT" ${PARGS[@]+"${PARGS[@]}"} 2>&1 | tee "$RES/publish.log"
  [ "${PIPESTATUS[0]}" = 0 ] || pfail "publish_inkling2_uncensored.py failed: $(grep BLOCKER "$RES/publish.log" | tail -n 1)"
  log "PUBLISH_PASS $(grep -E '^PUBLISH_(DONE|DRY_RUN)' "$RES/publish.log" | tail -n 1)"
fi
