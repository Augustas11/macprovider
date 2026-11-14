#!/bin/zsh
# Gemma 4 12B, native MTP (gemma4_mtp_v1, embedded assistant) versus ordinary
# decode at one row (#2154). Lab only: isolated runs (no coordinator, no
# network join, no live port) on an APFS clone of the staged artifact.
#
# Python reference for the same artifact (mlx-vlm 0.7.11, assistant at
# depth 3): code 45.95 -> 87.81 tok/s (1.91x, 71.6% acceptance), prose 1.46x,
# list 1.61x. These cells measure the provider's packed path, which
# proposes depth 1.
#
#   gemma4-12b-mtp-window.sh stamp
#        Model-free. Writes $POLICIES/gemma4-step1-d1.json from the committed
#        template with TARGET_SHA256 (the fixture target's snapshot identity;
#        the assistant is embedded, so mtp_sha256 is the same digest), the
#        fixture's tokenizer.json SHA-256 and HEAD_COMMIT.
#   gemma4-12b-mtp-window.sh step1
#        The four exploratory single-row R015 cells (s1 x p1536/p4096 x
#        o128/o512) at depth 1 on HARNESS, the lab-harness build of
#        HEAD_COMMIT: native MTP and ordinary decode per cell, tokens/s,
#        acceptance, TTFT and TPOT.
#   gemma4-12b-mtp-window.sh prepare
#        Model-free: the frozen R005 acceptance corpus (tokenizer only), the
#        acceptance policy and the formal R015 policy under $FORMAL, then the
#        harness's model-free validators.
#   gemma4-12b-mtp-window.sh qualify [r005] [r015]
#        r005  the 200-case SPEC-048-R005 acceptance corpus: exact native
#              versus ordinary token parity per case;
#        r015  the formal SPEC-048-R015 matrix at one native row (s1 cells,
#              the s2 gated cell at qualified_slots 2) and the 1800 s
#              sustained window, then the analyzer.
#   gemma4-12b-mtp-window.sh validate
#        `--validate-policy-only` of the step-1 policy (no MLX use).
#
# Exact token parity of the native path against serial greedy decode at depth
# 1, 2 and 3 is the fork's unit gate (Gemma4MTPPackedDrafterTests); R005 is
# the hardware parity gate against ordinary decode.
#
# Every leg but stamp/prepare/validate needs the GPU: run it only inside an
# announced Studio window with the buyer runner's Studio target dropped and
# the live provider paused, drained to 0 in flight and booted out. Each step
# refuses to start while anything listens on :8080, the live serve process
# runs, or the live LaunchAgent is loaded; one window runs at a time.
#
# Env: LAB (~/macprovider-lab-2154), ROOT ($LAB/fixtures/gemma4, holds target/),
# SRC ($LAB/src, the HEAD_COMMIT tree),
# HARNESS, HEAD_COMMIT, TARGET_SHA256 (stamp), OUT, FORMAL ($LAB/formal),
# STEP_TIMEOUT_S (0: no per-step limit), FROM (1, resume a cell list).
set -euo pipefail
export PATH=/usr/sbin:/opt/homebrew/bin:/usr/bin:/bin
export DEVELOPER_DIR=$HOME/Applications/Xcode.app/Contents/Developer
LAB=${LAB:-$HOME/macprovider-lab-2154}
POLICIES=${POLICIES:-$LAB/policies}
FORMAL=${FORMAL:-$LAB/formal}
SRC=${SRC:-$LAB/src}
HARNESS=${HARNESS:-$SRC/phase3-binary/.build/arm64-apple-macosx/release}
OUT=${OUT:-$LAB/window-$(date -u +%Y%m%dT%H%M%SZ)}
LIVE_PORT=8080
LIVE_LABEL=live.malibu.provider
LIVE_BINARY=$HOME/macprovider/macprovider-cli
LOCK=$HOME/.gemma4-mtp-window.lock
RELEASE_METALLIB_SHA256=41863424710154758311c118db69a23231eadb0cc542abded55ac5859b51e3b2
MODEL_ID=google/gemma-4-12b-it
ROOT=${ROOT:-$LAB/fixtures/gemma4}
# SPEC-048 sidecar floor; the gemma4_mtp_v1 native row ceiling is 1.
QUALIFIED_SLOTS=2
TEMPLATE=$SRC/scripts/lab/cb-studio/gemma4-12b-mtp/gemma4-step1-d1.json

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

LOCKED=0
lock() {
  live_absent || exit 3
  mkdir "$LOCK" 2> /dev/null || { echo "refusing: another window holds $LOCK" >&2; exit 3; }
  LOCKED=1
  mkdir -p "$OUT"
}
unlock() {
  (( LOCKED )) || return 0
  rmdir "$LOCK" 2> /dev/null && LOCKED=0 || echo "window lock not removed: $LOCK" >&2
}
trap 'set +e; unlock' EXIT

harness_ok() {
  [[ -x $HARNESS/macprovider-cli && -f $HARNESS/mlx.metallib ]] || { echo "no harness at $HARNESS" >&2; exit 3; }
  [[ $(shasum -a 256 "$HARNESS/mlx.metallib" | cut -d' ' -f1) == $RELEASE_METALLIB_SHA256 ]] ||
    { echo "refusing: $HARNESS/mlx.metallib is not the signed release metallib" >&2; exit 3; }
  shasum -a 256 "$HARNESS/macprovider-cli" "$HARNESS/mlx.metallib" | tee -a "$OUT/identity.sha256"
}

head_ok() {
  [[ ${HEAD_COMMIT:-} =~ '^[0-9a-f]{40}$' ]] || { echo "HEAD_COMMIT must be the 40-hex commit HARNESS was built from" >&2; exit 2; }
}

log() { echo "$(date -u +%FT%TZ) $*" | tee -a $OUT/summary.txt; }

run_bounded() {
  local limit=$1 label=$2 out=$3 err=$4; shift 4
  "$@" > "$out" 2> "$err" < /dev/null &
  local pid=$! t0=$(date +%s)
  while kill -0 $pid 2>/dev/null; do
    if ! live_absent 2>> "$OUT/summary.txt"; then
      echo "$label stopped: the live provider appeared" | tee -a "$OUT/summary.txt"
      kill -TERM $pid 2>/dev/null; sleep 5; kill -KILL $pid 2>/dev/null || true
      wait $pid 2>/dev/null || true
      return 125
    fi
    if (( limit > 0 && $(date +%s) - t0 >= limit )); then
      echo "$label TIMEOUT after ${limit}s" | tee -a $OUT/summary.txt
      kill -TERM $pid 2>/dev/null; sleep 5; kill -KILL $pid 2>/dev/null || true
      wait $pid 2>/dev/null || true
      return 124
    fi
    sleep 5
  done
  wait $pid
}

# cells <policy> <dir> <label> <cell ids...>
cells() {
  local policy=$1 dir=$2 label=$3; shift 3
  local rc=0 from=${FROM:-1}
  local bench=(env MACPROVIDER_NATIVE_MTP_E2E=1 $HARNESS/macprovider-cli native-mtp-bench --root $ROOT
    --model-id $MODEL_ID --policy $policy --out $dir/$label.jsonl --provider-commit $HEAD_COMMIT)
  for cell in "${(@)argv[$from,-1]}"; do
    live_absent || { rc=3; break; }
    log "$label $cell start"
    if [[ $cell == sustained ]]; then
      run_bounded ${STEP_TIMEOUT_S:-0} $label-$cell $dir/$label-$cell.stdout $dir/$label-$cell.log \
        $bench --phase sustained || rc=$?
    else
      run_bounded ${STEP_TIMEOUT_S:-0} $label-$cell $dir/$label-$cell.stdout $dir/$label-$cell.log \
        $bench --only-cell $cell --phase matrix || rc=$?
    fi
    log "$label $cell rc=$rc lines=$(wc -l < $dir/$label.jsonl)"
    (( rc == 0 )) || break
  done
  shasum -a 256 $dir/$label.jsonl | tee -a $OUT/summary.txt || true
  return $rc
}

stamp() {
  head_ok
  [[ ${TARGET_SHA256:-} =~ '^[0-9a-f]{64}$' ]] || { echo "TARGET_SHA256 must be the fixture target's 64-hex snapshot identity" >&2; exit 2; }
  mkdir -p $POLICIES
  /usr/bin/python3 -I - $TEMPLATE $ROOT/target/tokenizer.json $TARGET_SHA256 $HEAD_COMMIT \
    $SRC/phase3-binary/Package.resolved $POLICIES/gemma4-step1-d1.json <<'PY'
import hashlib, json, sys
template, tokenizer, target, commit, resolved, out = sys.argv[1:]
policy = json.load(open(template))
fork = [p for p in json.load(open(resolved))["pins"] if p["identity"] == "mlx-swift-lm"][0]["state"]["revision"]
if fork != policy["mlx_fork_revision"]:
    sys.exit(f"refusing: Package.resolved pins mlx-swift-lm {fork}, the template names {policy['mlx_fork_revision']}")
policy.update(target_sha256=target, mtp_sha256=target, provider_commit=commit,
              tokenizer_sha256=hashlib.sha256(open(tokenizer, "rb").read()).hexdigest())
with open(out, "w") as fh:
    json.dump(policy, fh, indent=2, sort_keys=True)
print(out, hashlib.sha256(open(out, "rb").read()).hexdigest())
PY
}

prepare() {
  head_ok; mkdir -p $FORMAL
  local corpus=$FORMAL/gemma4-acceptance-corpus.json
  [[ -f $POLICIES/gemma4-step1-d1.json ]] || { echo "run '$0 stamp' first" >&2; exit 3; }
  [[ -f $corpus ]] || $HARNESS/macprovider-cli native-mtp-journey-e2e --root $ROOT --model-id $MODEL_ID \
    --qualified-slots $QUALIFIED_SLOTS --max-native-active-rows 1 --max-prompt-tokens 4096 \
    --prepare-acceptance-corpus $corpus
  /usr/bin/python3 -I - $POLICIES/gemma4-step1-d1.json $corpus \
    $FORMAL/gemma4-acceptance-policy.json $FORMAL/gemma4-r015-policy.json <<'PY'
import hashlib, json, sys
step1, corpus, acceptance_out, r015_out = sys.argv[1:]
base = json.load(open(step1))
environment = {k: base[k] for k in ("model_id", "target_sha256", "mtp_sha256", "tokenizer_sha256", "hw_model",
    "chip", "ram_gb", "os_build", "xcode_build_version", "swift_version", "quantization", "cache_mode",
    "provider_commit", "mlx_fork_revision")}
acceptance = dict(environment, schema="macprovider.native-mtp-acceptance-policy.v1",
    corpus_sha256=hashlib.sha256(open(corpus, "rb").read()).hexdigest())
# The approved Qwen R015 contract at one native row and the sidecar's
# two-slot floor: s1 cells, gated s2, sustained on the gated cell.
r015 = dict(environment, schema="macprovider.native-mtp-r015-policy.v1", proposal_depth=1,
    run_order="seeded_random_counterbalanced", prompt_corpus="deterministic_synthetic_unique_v2",
    exclusion_rules="none", confidence_method="paired_block_bootstrap_holm_v1",
    qualified_slots=2, max_native_active_rows=1, arrival_interval_ms=250, slots=[1],
    maximum_prompt_tokens=4096, prompt_tokens=[1536, 4096], max_tokens=[128, 512],
    gated_cells=["s2-p1536-o512"], warmup_runs=1, blocks=10, seed=20261107,
    sustained_seconds=1800, sustained_cell_id="s2-p1536-o512", memory_safety_margin_bytes=8589934592,
    thresholds=base["thresholds"])
for path, doc in ((acceptance_out, acceptance), (r015_out, r015)):
    with open(path, "w") as fh:
        json.dump(doc, fh, sort_keys=True, separators=(", ", ": "))
    print(path, hashlib.sha256(open(path, "rb").read()).hexdigest())
PY
  $HARNESS/macprovider-cli native-mtp-journey-e2e --root $ROOT --model-id $MODEL_ID \
    --qualified-slots $QUALIFIED_SLOTS --max-native-active-rows 1 --max-prompt-tokens 4096 \
    --acceptance-corpus $corpus --acceptance-policy $FORMAL/gemma4-acceptance-policy.json \
    --provider-commit $HEAD_COMMIT --validate-acceptance-only --identity-cache $LAB/identity-cache.json
  env MACPROVIDER_NATIVE_MTP_E2E=1 $HARNESS/macprovider-cli native-mtp-bench --root $ROOT --model-id $MODEL_ID \
    --policy $FORMAL/gemma4-r015-policy.json --out $FORMAL/validate-gemma4-r015.jsonl \
    --provider-commit $HEAD_COMMIT --validate-policy-only --identity-cache $LAB/identity-cache.json
}

leg_r005() {
  local d=$1 rc=0
  log "r005 start"
  run_bounded ${STEP_TIMEOUT_S:-0} gemma4-r005 $d/acceptance.json $d/acceptance.err \
    env MACPROVIDER_NATIVE_MTP_E2E=1 $HARNESS/macprovider-cli native-mtp-journey-e2e --root $ROOT \
    --model-id $MODEL_ID --qualified-slots $QUALIFIED_SLOTS --max-native-active-rows 1 --max-prompt-tokens 4096 \
    --acceptance-corpus $FORMAL/gemma4-acceptance-corpus.json --acceptance-policy $FORMAL/gemma4-acceptance-policy.json \
    --provider-commit $HEAD_COMMIT --acceptance-checkpoint $d/acceptance-checkpoint.json || rc=$?
  log "r005 rc=$rc $(/usr/bin/python3 -I -c 'import json,sys; a=json.loads(open(sys.argv[1]).read()); print(a.get("status"), "accepted", a.get("accepted"), "rejected", a.get("rejected"), "positions", a.get("native_compared_positions"), "failed_checks", [k for k,v in a.get("checks",{}).items() if not v])' $d/acceptance.json 2>&1 | cut -c1-300)"
  return $rc
}

leg_r015() {
  local d=$1 rc=0 arc=0 status=MISSING
  cells $FORMAL/gemma4-r015-policy.json $d r015 \
    s1-p1536-o128 s1-p1536-o512 s1-p4096-o128 s1-p4096-o512 s2-p1536-o512 sustained || rc=$?
  /usr/bin/python3 -I $SRC/scripts/native_mtp_r015_analyze.py $d/r015.jsonl $FORMAL/gemma4-r015-policy.json \
    > $d/r015-analysis.json 2> $d/r015-analysis.err || arc=$?
  /usr/bin/python3 -I $SRC/scripts/native_mtp_r015_analyze.py --format markdown $d/r015.jsonl $FORMAL/gemma4-r015-policy.json \
    > $d/r015-analysis.md 2>&1 || true
  status=$(/usr/bin/python3 -I -c 'import json,sys; print(json.load(open(sys.argv[1])).get("overall_status","MISSING"))' $d/r015-analysis.json 2>/dev/null || echo MISSING)
  log "r015 bench=$rc analyzer=$arc overall_status=$status"
  [[ $rc -eq 0 && $arc -eq 0 && $status == PASS ]]
}

qualify() {
  head_ok
  local legs=("$@"); (( ${#legs} )) || legs=(r005 r015)
  local d=$OUT/gemma4 failed=()
  mkdir -p $d
  for f in $FORMAL/gemma4-acceptance-corpus.json $FORMAL/gemma4-acceptance-policy.json $FORMAL/gemma4-r015-policy.json; do
    [[ -f $f ]] || { echo "run '$0 prepare' first ($f)" >&2; exit 3; }
    shasum -a 256 $f | tee -a $OUT/identity.sha256
  done
  for leg in $legs; do
    live_absent || { log "live appeared; abort"; exit 4; }
    local rc=0
    leg_$leg $d || rc=$?
    log "leg $leg rc=$rc"
    (( rc == 0 )) || failed+=($leg)
  done
  log "qualify done; failed legs: ${failed:-none}"
  (( ${#failed} == 0 ))
}

case ${1:-} in
  stamp) stamp ;;
  step1)
    head_ok; lock; harness_ok
    # zsh 5.9 skips the EXIT trap when set -e aborts inside a function.
    set +e
    cells $POLICIES/gemma4-step1-d1.json $OUT gemma4-step1-d1 \
      s1-p1536-o128 s1-p1536-o512 s1-p4096-o128 s1-p4096-o512
    rc=$?
    set -e
    exit $rc ;;
  prepare) prepare ;;
  qualify)
    lock; harness_ok
    set +e
    qualify "${@:2}"
    rc=$?
    set -e
    exit $rc ;;
  validate)
    head_ok
    env MACPROVIDER_NATIVE_MTP_E2E=1 $HARNESS/macprovider-cli native-mtp-bench --root $ROOT --model-id $MODEL_ID \
      --policy $POLICIES/gemma4-step1-d1.json --out $LAB/validate-gemma4-d1.jsonl \
      --provider-commit $HEAD_COMMIT --validate-policy-only --identity-cache $LAB/identity-cache.json ;;
  *) echo "usage: $0 stamp|step1|prepare|qualify [r005] [r015]|validate" >&2; exit 2 ;;
esac
