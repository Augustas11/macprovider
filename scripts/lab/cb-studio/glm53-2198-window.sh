#!/bin/zsh
# Issue #2198 Studio window for GLM-5.3-Flash on the M3 Ultra, lab only:
# isolated in-process runs (no coordinator, no network, no serve port), one
# process per cell so one 186 GB target is resident at a time.
#
#   glm53-2198-window.sh all     every leg below, back to back, in this order
#   glm53-2198-window.sh tests   fork GLM5NextTests (FORK checkout, built
#        beforehand with `swift build --build-tests --build-system native`)
#   glm53-2198-window.sh base    BASE_BENCH (GLMBench on fork e06521b9, the
#        provider pin): 1K/8K/32K/64K with the provider's 512-token prefill
#        chunk, tokens and top logits dumped; 1K decode kernel profile
#   glm53-2198-window.sh camp    CAMP_BENCH (GLMBench on the campaign fork,
#        prefill + split-HC) on the same cells and profile; tokens and top logits
#        compared bitwise with base (needs base's logs in OUT)
#   glm53-2198-window.sh msb     4-row paged CB aggregate at 1K, provider lab
#        harness on the pinned fork (HARNESS_PIN) then on the campaign fork
#        (HARNESS_HC: prefill + split-HC)
#   glm53-2198-window.sh r015    SPEC-048 R015 single-row cells, native MTP
#        against ordinary, s1 x prompt 1536/4096/32768 x output 128/512, on
#        HARNESS_PIN under the lab-only exploratory policy POLICY
#        (maximum_prompt_tokens 32768; never a signed entry or verdict)
#   glm53-2198-window.sh validate   policy, layout and identity checks of
#        the r015 leg without MLX use; runs beside the live provider
#   glm53-2198-window.sh omlx    oMLX comparison (not part of `all`)
#
# Every leg needs the GPU except `validate`. The window owner pauses, drains
# and boots out the live provider first and restores it after; this script
# never touches it. Each leg refuses to start, and a running cell is stopped,
# while anything listens on :8080, the live serve process runs, or the
# live.malibu.provider LaunchAgent is loaded. One window at a time (a lock
# directory). No wall-clock ceilings: a cell runs until it ends.
#
# Each leg appends to OUT/legs.log and writes OUT/<leg>.json (rc, times,
# per-cell results); `all` also writes OUT/all.json and touches OUT/DONE.
#
# Env: LAB (~/macprovider-lab-2198), W (~/work-2198), MODEL, FORK,
#      BASE_BENCH, CAMP_BENCH, HARNESS_PIN, HARNESS_HC, POLICY, FIXTURE, OUT.
set -uo pipefail
export PATH=/usr/sbin:/opt/homebrew/bin:/usr/bin:/bin
# The policy names Xcode 17F113; the bench records `xcodebuild -version`.
export DEVELOPER_DIR=$HOME/Applications/Xcode.app/Contents/Developer
LAB=${LAB:-$HOME/macprovider-lab-2198}
W=${W:-$HOME/work-2198}
MODEL=${MODEL:-"$HOME/Library/Application Support/macprovider/models/Jundot--GLM-5.3-Flash-oQ4e-mtp/36defc5042d92a992a7948e83d6f110b8df69329/7299b6a71a38490e378e9eb6524c426392aa96e3fd561007e0540134bbef48f9"}
FORK=${FORK:-$W/mlx-swift-lm}
BASE_BENCH=${BASE_BENCH:-$W/bench-base19/.build/release/GLMBench}
CAMP_BENCH=${CAMP_BENCH:-$W/bench-hc/.build/release/GLMBench}
HARNESS_PIN=${HARNESS_PIN:-$W/src-pin/phase3-binary/.build/arm64-apple-macosx/release}
HARNESS_HC=${HARNESS_HC:-$W/src-hc/phase3-binary/.build/arm64-apple-macosx/release}
POLICY=${POLICY:-$LAB/policies/r015-cap32k-exploratory.json}
FIXTURE=${FIXTURE:-$LAB/fixtures/glm53}
OMLX=${OMLX:-$LAB/venv-omlx/bin}
SWEEP=${SWEEP:-$LAB/poc/scripts/lab/cb-studio/depth_sweep.py}
ANALYZE=${ANALYZE:-$LAB/native_mtp_r015_analyze.py}
OUT=${OUT:-$LAB/window-$(date -u +%Y%m%dT%H%M%SZ)}
MODEL_ID=zai-org/glm-5.3-flash
PROVIDER_COMMIT=3240ca12714207c4411c44f0403ff66d76d3bc2e
RELEASE_METALLIB_SHA256=3d9b4a747758128cc5418e62c5ad8e282a11b0d436423537137e013beaa1261b
LIVE_PORT=8080
LIVE_LABEL=live.malibu.provider
LIVE_BINARY=$HOME/macprovider/macprovider-cli
LOCK=$HOME/.glm53-2198-window.lock
PORT=18095
R015_CELLS=(s1-p1536-o128 s1-p1536-o512 s1-p4096-o128 s1-p4096-o512 s1-p32768-o128 s1-p32768-o512)
mkdir -p $OUT
log() { echo "$(date -u +%FT%TZ) $*" | tee -a $OUT/summary.txt; }

# Fails closed: any probe output or error other than "none" refuses.
live_absent() {
  local listeners probe
  listeners=$(lsof -nP -t -iTCP:$LIVE_PORT -sTCP:LISTEN 2>&1) || true
  if [[ -n $listeners ]] || ! command -v lsof > /dev/null; then
    echo "refusing: :$LIVE_PORT has a listener or cannot be probed" >&2; return 3
  fi
  probe=0; pgrep -f "^$LIVE_BINARY serve" > /dev/null 2>&1 || probe=$?
  if (( probe != 1 )); then
    echo "refusing: the live $LIVE_BINARY serve process runs or cannot be probed" >&2; return 3
  fi
  probe=0; launchctl print gui/$(id -u)/$LIVE_LABEL > /dev/null 2>&1 || probe=$?
  if (( probe != 113 )); then
    echo "refusing: $LIVE_LABEL is loaded or cannot be probed" >&2; return 3
  fi
}

LOCKED=
trap '[[ -n $LOCKED ]] && rmdir $LOCK 2> /dev/null' EXIT
lock() {
  live_absent 2>> $OUT/summary.txt || { log "refusing: live provider present"; exit 3; }
  mkdir "$LOCK" 2> /dev/null || { log "refusing: another window holds $LOCK"; exit 3; }
  LOCKED=1
}

# watched <label> <stdout> <stderr> cmd...: runs cmd, stopping it (rc 125) as
# soon as the live provider could share the GPU. No time limit.
watched() {
  local label=$1 out=$2 err=$3; shift 3
  "$@" > "$out" 2> "$err" &
  local pid=$!
  while kill -0 $pid 2> /dev/null; do
    if ! live_absent 2>> $OUT/summary.txt; then
      log "$label stopped: the live provider appeared"
      kill -TERM $pid 2> /dev/null; sleep 5; kill -KILL $pid 2> /dev/null || true
      wait $pid 2> /dev/null || true
      return 125
    fi
    sleep 5
  done
  wait $pid
}

# leg_begin <leg> / leg_end <leg> <rc>: legs.log lines and OUT/<leg>.json
# from the leg's cell lines (OUT/<leg>.cells, one JSON object per line).
leg_begin() {
  : > $OUT/$1.cells
  LEG_T0=$(date -u +%FT%TZ)
  echo "$LEG_T0 leg $1 begin" >> $OUT/legs.log
  log "leg $1 begin"
}
leg_end() {
  local t1=$(date -u +%FT%TZ)
  python3 -I - $1 $2 $LEG_T0 $t1 $OUT/$1.cells $OUT/$1.json <<'PY'
import json, sys
leg, rc, t0, t1, cells, out = sys.argv[1:]
rows = [json.loads(l) for l in open(cells) if l.strip()]
json.dump({"leg": leg, "rc": int(rc), "start": t0, "end": t1, "cells": rows},
          open(out, "w"), indent=2, sort_keys=True)
PY
  echo "$t1 leg $1 rc=$2 json=$OUT/$1.json" >> $OUT/legs.log
  log "leg $1 rc=$2"
  return $2
}
# cell_json <leg> <name> <rc> <log>: one cell line from a GLMBench/msb log.
cell_json() {
  python3 -I - "$@" >> $OUT/$1.cells <<'PY'
import json, re, sys
leg, name, rc, path = sys.argv[1:5]
row = {"cell": name, "rc": int(rc), "log": path}
try:
    text = open(path, errors="replace").read()
except OSError:
    text = ""
for key in ("prefill_tps", "prefill_s", "decode_tps", "peak_gb", "wall_ms", "gpu_busy_ms", "dispatches/step"):
    m = re.search(r"(?:^|\s)" + re.escape(key) + r"=([0-9.]+)", text)
    if m:
        row[key] = float(m.group(1))
fam = re.findall(r"^family:\s+([0-9.]+) us\s+([0-9.]+)%\s+n=\s*([0-9.]+).*?\s(\S+)$", text, re.M)
if fam:
    row["families_us"] = {f[3]: float(f[0]) for f in fam}
print(json.dumps(row, sort_keys=True))
PY
}

bench_cell() {  # bench_cell <leg> [ops0] <binary> <name> [args...]
  local leg=$1; shift
  local ops=()
  [[ $1 == ops0 ]] && { ops=(env MLX_MAX_OPS_PER_BUFFER=0); shift; }
  local b=$1 name=$2; shift 2
  live_absent 2>> $OUT/summary.txt || { log "$name refused: live provider present"; return 3; }
  log "$name start"
  local rc=0
  watched $name $OUT/$name.log $OUT/$name.err $ops $b $MODEL "$@" || rc=$?
  cat $OUT/$name.err >> $OUT/$name.log 2> /dev/null
  log "$name rc=$rc $(grep -E '^(prefill_tps|decode_tps|gpu-profile|prefill-profile)' $OUT/$name.log | tr '\n' ' ' | cut -c1-300)"
  cell_json $leg $name $rc $OUT/$name.log
  return $rc
}

bench_cells() {  # bench_cells <leg> <binary> <prefix>
  local leg=$1 b=$2 p=$3 rc=0
  [[ -x $b && -f ${b:h}/mlx.metallib ]] || { log "no bench at $b"; return 3; }
  shasum -a 256 $b ${b:h}/mlx.metallib >> $OUT/identity.txt
  for ctx in 1024 8192 32768 65536; do
    bench_cell $leg $b $p-ctx$ctx --prompt $ctx --prefill-chunk 512 --wired --steps 128 --dump-logits --all-tokens || rc=$?
    (( rc == 3 || rc == 125 )) && return $rc
  done
  bench_cell $leg ops0 $b $p-kernels-1k --prompt 1024 --wired --gpu-profile --profile-steps 20 || rc=$?
  return $rc
}

leg_tests() {
  leg_begin tests
  local rc=0
  if ! live_absent 2>> $OUT/summary.txt; then rc=3
  else
    log "fork tests start $(git -C $FORK rev-parse HEAD)"
    (cd $FORK && watched tests $OUT/fork-tests.log $OUT/fork-tests.err swift test --build-system native \
      --skip-build --filter GLM5NextTests -Xswiftc -Xfrontend -Xswiftc -solver-expression-time-threshold=600) || rc=$?
    cat $OUT/fork-tests.err >> $OUT/fork-tests.log 2> /dev/null
    log "fork tests rc=$rc $(grep -E 'Executed .* tests' $OUT/fork-tests.log | tail -1)"
    python3 -I - $rc $OUT/fork-tests.log $(git -C $FORK rev-parse HEAD) >> $OUT/tests.cells <<'PY'
import json, re, sys
rc, path, head = sys.argv[1:]
text = open(path, errors="replace").read()
ex = re.findall(r"Executed (\d+) tests?, with (\d+) tests? skipped and (\d+) failures?", text)
failed = sorted(set(re.findall(r"-\[\S+ (test\w+)\]' failed", text)))
row = {"cell": "GLM5NextTests", "rc": int(rc), "fork_head": head, "failed": failed, "log": path}
if ex:
    row.update(executed=int(ex[-1][0]), skipped=int(ex[-1][1]), failures=int(ex[-1][2]))
print(json.dumps(row, sort_keys=True))
PY
  fi
  leg_end tests $rc
}

leg_base() {
  leg_begin base
  local rc=0
  bench_cells base $BASE_BENCH base || rc=$?
  leg_end base $rc
}

leg_camp() {
  leg_begin camp
  local rc=0
  bench_cells camp $CAMP_BENCH camp || rc=$?
  # Greedy tokens must match base bitwise at every context. Split-HC is bitwise
  # but the prefill Sinkhorn and sparse-head GEMM kernels reorder sums, so the
  # top logits are compared by their largest absolute difference. Prefill time
  # at 32K and 64K (512-token chunks), camp against base.
  python3 -I - $OUT >> $OUT/camp.cells <<'PY'
import json, re, sys
out = sys.argv[1]
def text(side, ctx):
    try:
        return open(f"{out}/{side}-ctx{ctx}.log", errors="replace").read()
    except OSError:
        return ""
def line(t, key):
    m = re.search(r"^" + key + r"=(\[.*\])$", t, re.M)
    return json.loads(m.group(1)) if m else None
def value(t, key):
    m = re.search(r"(?:^|\s)" + key + r"=([0-9.]+)", t)
    return float(m.group(1)) if m else None
bad = False
for ctx in (1024, 8192, 32768, 65536):
    a, b = text("base", ctx), text("camp", ctx)
    ta, tb = line(a, "tokens"), line(b, "tokens")
    la, lb = line(a, "top_logits"), line(b, "top_logits")
    row = {"cell": f"parity-ctx{ctx}"}
    if ta is None or tb is None:
        row["tokens"] = "missing"
    else:
        row["tokens"] = "identical" if ta == tb else "differs"
        if ta != tb:
            row["first_token_mismatch"] = next((i for i, (x, y) in enumerate(zip(ta, tb)) if x != y), min(len(ta), len(tb)))
    if la is not None and lb is not None and len(la) == len(lb):
        row["top_logits_bitwise"] = la == lb
        row["top_logits_max_abs_diff"] = max((abs(x - y) for x, y in zip(la, lb)), default=0.0)
    bad |= row["tokens"] != "identical"
    print(json.dumps(row, sort_keys=True))
    if ctx >= 32768:
        p = {"cell": f"prefill-ctx{ctx}"}
        for side, t in (("base", a), ("camp", b)):
            p[f"{side}_prefill_s"] = value(t, "prefill_s")
            p[f"{side}_decode_tps"] = value(t, "decode_tps")
        if p["base_prefill_s"] and p["camp_prefill_s"]:
            p["prefill_speedup_pct"] = round(100 * (p["base_prefill_s"] / p["camp_prefill_s"] - 1), 2)
            p["prefill_time_cut_pct"] = round(100 * (1 - p["camp_prefill_s"] / p["base_prefill_s"]), 2)
        print(json.dumps(p, sort_keys=True))
sys.exit(1 if bad else 0)
PY
  (( $? == 0 )) || { (( rc == 0 )) && rc=1; }
  grep -E '"(parity|prefill)-ctx' $OUT/camp.cells | while read -r l; do log "$l"; done
  leg_end camp $rc
}

msb_cell() {  # msb_cell <harness dir> <name>
  local h=$1 name=$2 rc=0
  [[ -x $h/macprovider-cli && -f $h/mlx.metallib ]] || { log "no harness at $h"; return 3; }
  shasum -a 256 $h/macprovider-cli $h/mlx.metallib >> $OUT/identity.txt
  live_absent 2>> $OUT/summary.txt || { log "$name refused: live provider present"; return 3; }
  log "$name start"
  watched $name $OUT/$name.out $OUT/$name.err $h/macprovider-cli msb-throughput --model "$MODEL" \
    --engine paged --rows 4 --prompt-tokens 1024 --decode-tokens 128 --runs 3 --block-size-tokens 256 \
    --mlx-cache-limit-mb 2048 --output $OUT/$name.json < /dev/null || rc=$?
  log "$name rc=$rc $(tail -2 $OUT/$name.err | tr '\n' ' ' | cut -c1-300)"
  echo "{\"cell\": \"$name\", \"rc\": $rc, \"json\": \"$OUT/$name.json\"}" >> $OUT/msb.cells
  return $rc
}

leg_msb() {
  leg_begin msb
  local rc=0
  msb_cell $HARNESS_PIN msb-rows4-base || rc=$?
  (( rc == 3 || rc == 125 )) || msb_cell $HARNESS_HC msb-rows4-camp || rc=$?
  leg_end msb $rc
}

r015_bench() {  # r015_bench args...: the R015 bench on HARNESS_PIN
  env MACPROVIDER_NATIVE_MTP_E2E=1 $HARNESS_PIN/macprovider-cli native-mtp-bench --root $FIXTURE \
    --model-id $MODEL_ID --policy $POLICY --provider-commit $PROVIDER_COMMIT "$@"
}

r015_ready() {
  [[ -x $HARNESS_PIN/macprovider-cli && -f $HARNESS_PIN/mlx.metallib ]] || { log "no harness at $HARNESS_PIN"; return 3; }
  [[ $(shasum -a 256 $HARNESS_PIN/mlx.metallib | cut -d' ' -f1) == $RELEASE_METALLIB_SHA256 ]] ||
    { log "refusing: $HARNESS_PIN/mlx.metallib is not the signed release metallib"; return 3; }
  [[ -f $POLICY && -d $FIXTURE/target ]] || { log "missing $POLICY or $FIXTURE/target"; return 3; }
  python3 -I -c 'import json,sys; p=json.load(open(sys.argv[1])); sys.exit(0 if p["schema"].endswith("exploratory-policy.v1") else 1)' $POLICY ||
    { log "refusing: $POLICY is not an exploratory policy"; return 3; }
}

leg_r015() {
  leg_begin r015
  local rc=0
  r015_ready || rc=$?
  if (( rc == 0 )); then
    shasum -a 256 $HARNESS_PIN/macprovider-cli $HARNESS_PIN/mlx.metallib $POLICY >> $OUT/identity.txt
    for cell in $R015_CELLS; do
      live_absent 2>> $OUT/summary.txt || { log "r015 $cell refused: live provider present"; rc=3; break; }
      log "r015 $cell start"
      local crc=0
      watched r015-$cell $OUT/r015-$cell.stdout $OUT/r015-$cell.log \
        r015_bench --out $OUT/r015-glm53.jsonl --only-cell $cell --phase matrix || crc=$?
      log "r015 $cell rc=$crc lines=$(wc -l < $OUT/r015-glm53.jsonl 2> /dev/null)"
      echo "{\"cell\": \"$cell\", \"rc\": $crc, \"log\": \"$OUT/r015-$cell.log\"}" >> $OUT/r015.cells
      (( crc == 0 )) || { rc=$crc; (( crc == 3 || crc == 125 )) && break; }
    done
    if [[ -s $OUT/r015-glm53.jsonl && -f $ANALYZE ]]; then
      python3 -I $ANALYZE $OUT/r015-glm53.jsonl $POLICY > $OUT/r015-analysis.json 2> $OUT/r015-analysis.err
      log "r015 analysis rc=$? -> $OUT/r015-analysis.json (exploratory: no verdict)"
      python3 -I $ANALYZE $OUT/r015-glm53.jsonl $POLICY --format markdown > $OUT/r015-analysis.md 2>> $OUT/r015-analysis.err
    fi
  fi
  leg_end r015 $rc
}

# validate: the r015 leg's layout, identities and policy without MLX use.
validate() {
  r015_ready || exit 3
  r015_bench --out $LAB/validate-r015.jsonl --validate-policy-only --identity-cache $LAB/identity-cache.json
}

leg_omlx() {
  leg_begin omlx
  local dir=$LAB/omlx-models name=GLM-5.3-Flash-oQ4e-mtp sp= rc=0
  live_absent 2>> $OUT/summary.txt || { leg_end omlx 3; return 3; }
  mkdir -p $dir
  [[ -e $dir/$name ]] || cp -c -R "$MODEL" $dir/$name
  $OMLX/omlx serve --model-dir $dir --port $PORT --max-concurrent-requests 8 --no-cache > $OUT/omlx-serve.log 2>&1 &
  sp=$!
  local ready=0
  while kill -0 $sp 2> /dev/null; do
    curl -sf http://127.0.0.1:$PORT/v1/models > $OUT/omlx-models.json 2> /dev/null && { ready=1; break; }
    sleep 2
  done
  if (( ready )); then
    for ctx in 1024 8192 32768; do
      python3 -I $SWEEP --port $PORT --model $name --depths 1 --prompt-tokens $ctx --max-tokens 256 --window 240 \
        --warmup 0 --label omlx-ctx$ctx --out $OUT/omlx-sweep.jsonl > $OUT/omlx-$ctx.log 2>&1 || rc=$?
    done
    cp $OUT/omlx-sweep.jsonl $OUT/omlx.cells 2> /dev/null
  else
    log "omlx not ready: $(tail -5 $OUT/omlx-serve.log | tr '\n' ' ')"; rc=5
  fi
  kill -TERM $sp 2> /dev/null; wait $sp 2> /dev/null
  leg_end omlx $rc
}

case ${1:-} in
  all)
    lock
    {
      print -r -- "model=$MODEL fork=$(git -C $FORK rev-parse HEAD 2> /dev/null)"
      sysctl iogpu.wired_limit_mb hw.memsize
    } >> $OUT/identity.txt 2>&1
    rcs=()
    for leg in tests base camp msb r015; do
      live_absent 2>> $OUT/summary.txt || { log "live provider appeared; stopping before $leg"; rcs+=("$leg=3"); break; }
      leg_$leg; rcs+=("$leg=$?")
    done
    python3 -I -c 'import json,sys; json.dump({"legs": dict(a.split("=") for a in sys.argv[2:])}, open(sys.argv[1], "w"), indent=2)' \
      $OUT/all.json $rcs
    log "window done: $rcs"
    touch $OUT/DONE ;;
  tests|base|camp|msb|r015|omlx) lock; leg_$1 ;;
  validate) validate ;;
  *) echo "usage: $0 all | tests | base | camp | msb | r015 | validate | omlx" >&2; exit 2 ;;
esac
