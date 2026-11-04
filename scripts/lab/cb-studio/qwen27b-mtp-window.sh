#!/bin/zsh
# Qwen 27B dense rows, native MTP versus ordinary decode (#2199). Lab only:
# isolated runs (no coordinator, no network join, no live port) on APFS clones
# of the staged artifacts, one model resident at a time.
#
#   qwen27b-mtp-window.sh step1 qwen36|qwen38
#        The four exploratory single-row cells (s1 x p1536/p4096 x
#        o128/o512) at depth 1 on BASE_HARNESS, the lab-harness build of main
#        BASE_COMMIT, under qwen27b-mtp/<model>-step1-d1.json.
#   qwen27b-mtp-window.sh prepare qwen36|qwen38
#        Model-free, runs beside the live provider: writes the frozen R005
#        acceptance corpus (tokenizer only), the acceptance policy and the
#        formal R015 policy for HEAD_COMMIT under $FORMAL, then checks all
#        three with the harness's model-free validators.
#   qwen27b-mtp-window.sh qualify qwen36|qwen38 [leg...]
#        The formal qualification on HARNESS, the lab-harness build of
#        HEAD_COMMIT. Legs, in order (default all):
#          cb    isolated no-join lab serve, CB canary under a manual tuple:
#                paged attach, row isolation, FR-CB10 self-check, then the
#                warm-vs-cold keyed driver at rows 1 and 4;
#          msb   msb-throughput, paged engine, rows 1/2/4 at block 256, and
#                the SPEC-039 FR-PKV12 leftovers scenario at rows 4;
#          r005  the 200-case SPEC-048-R005 acceptance corpus
#                (native-mtp-journey-e2e --acceptance-corpus);
#          r015  the formal SPEC-048-R015 matrix (one native-mtp-bench process
#                per cell) and the 1800 s sustained window, then the analyzer;
#          bank  native-mtp-journey-e2e --selftest-only, one step per
#                candidate challenge text; the bank takes the first candidate
#                whose checks all pass at speedup >= BANK_MIN_SPEEDUP.
#   qwen27b-mtp-window.sh validate
#        `--validate-policy-only` of both step-1 policies (no MLX use).
#
# Depth 2 and 3 measured slower than depth 1 (11-03 window), so the
# campaign serves depth 1 only and the window carries no depth leg.
#
# Every leg but prepare/validate needs the GPU: run it only inside an
# announced Studio window with the buyer runner's Studio target dropped, the
# live provider paused, drained to 0 in flight and booted out. The script
# refuses to start, and each step refuses to start, while anything listens on
# :8080, the live serve process runs, or the live LaunchAgent is loaded; one
# window runs at a time (a lock directory). Pausing and restoring the live
# provider is the window owner's job.
#
# Env: LAB (~/macprovider-lab-2222), SRC ($LAB/src, the HEAD_COMMIT tree),
# HARNESS, HEAD_COMMIT, BASE_HARNESS, OUT, FORMAL ($LAB/formal),
# STEP_TIMEOUT_S (0: no per-step limit; the window watchdog is stall-only),
# FROM (1, resume a cell list at a later cell),
# BANK_MIN_SPEEDUP (1.20), LAB_PORT (18096).
set -euo pipefail
export PATH=/usr/sbin:/opt/homebrew/bin:/usr/bin:/bin
# The policies name Xcode 17F113; the bench records `xcodebuild -version`.
export DEVELOPER_DIR=$HOME/Applications/Xcode.app/Contents/Developer
LAB=${LAB:-$HOME/macprovider-lab-2222}
POLICIES=${POLICIES:-$LAB/policies}
FORMAL=${FORMAL:-$LAB/formal}
SRC=${SRC:-$LAB/src}
BASE_HARNESS=${BASE_HARNESS:-$LAB/src-base/phase3-binary/.build/arm64-apple-macosx/release}
HARNESS=${HARNESS:-$SRC/phase3-binary/.build/arm64-apple-macosx/release}
OUT=${OUT:-$LAB/window-$(date -u +%Y%m%dT%H%M%SZ)}
LAB_PORT=${LAB_PORT:-18096}
LIVE_PORT=8080
LIVE_LABEL=live.malibu.provider
LIVE_BINARY=$HOME/macprovider/macprovider-cli
LOCK=$HOME/.qwen27b-mtp-window.lock
RELEASE_METALLIB_SHA256=3d9b4a747758128cc5418e62c5ad8e282a11b0d436423537137e013beaa1261b
# main after #2221 (2ee4b84a8): mlx-swift-lm 3.32.3-macprovider.21 (ae6aa78).
BASE_COMMIT=f5a8bac81a1a43637b5ae17c46ad2b14402f4e21
QUALIFIED_SLOTS=4
HARDWARE_CLASS="apple-silicon:Apple M3 Ultra:ram-256gb"
KERNEL_IDENTIFIER=macprovider_paged_kv_gather_v1
# Candidate challenge texts, in preference order (the GLM bank's list).
CANDIDATES=(
  "native_mtp_selftest_v1 synthetic challenge: count upward by one. 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12,"
  "native_mtp_selftest_v1 synthetic challenge: continue the sequence alpha beta gamma delta"
  "native_mtp_selftest_v1 synthetic challenge: repeat the line exactly. the quick brown fox jumps over the lazy dog. the quick brown fox jumps over the lazy dog. the quick brown fox jumps over the lazy dog."
)

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

lock() {
  live_absent || exit 3
  mkdir "$LOCK" 2> /dev/null || { echo "refusing: another window holds $LOCK" >&2; exit 3; }
  LOCKED=1
  mkdir -p "$OUT"
}

# harness_ok <dir>: the binary exists and carries the signed release metallib.
harness_ok() {
  [[ -x $1/macprovider-cli && -f $1/mlx.metallib ]] || { echo "no harness at $1" >&2; exit 3; }
  [[ $(shasum -a 256 "$1/mlx.metallib" | cut -d' ' -f1) == $RELEASE_METALLIB_SHA256 ]] ||
    { echo "refusing: $1/mlx.metallib is not the signed release metallib" >&2; exit 3; }
  shasum -a 256 "$1/macprovider-cli" "$1/mlx.metallib" | tee -a "$OUT/identity.sha256"
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
      echo "$label TIMEOUT after ${limit}s; sampling pid $pid" | tee -a $OUT/summary.txt
      /usr/bin/sample $pid 5 -file $OUT/$label-sample.txt > /dev/null 2>&1 || true
      kill -TERM $pid 2>/dev/null; sleep 5; kill -KILL $pid 2>/dev/null || true
      wait $pid 2>/dev/null || true
      return 124
    fi
    sleep 5
  done
  wait $pid
}

model_id() {
  case $1 in
    qwen36) echo qwen/qwen3.6-27b ;;
    qwen38) echo qwen/qwen3.8-27b ;;
    *) echo "unknown model $1" >&2; exit 2 ;;
  esac
}

head_ok() {
  [[ ${HEAD_COMMIT:-} =~ '^[0-9a-f]{40}$' ]] || { echo "HEAD_COMMIT must be the 40-hex commit HARNESS was built from" >&2; exit 2; }
}

# cells <harness> <commit> <model> <policy> <dir> <label> <cell ids...>
cells() {
  local harness=$1 commit=$2 model=$3 policy=$4 dir=$5 label=$6; shift 6
  local root=$LAB/fixtures/$model rc=0
  local bench=(env MACPROVIDER_NATIVE_MTP_E2E=1 $harness/macprovider-cli native-mtp-bench --root $root
    --model-id $(model_id $model) --policy $policy --out $dir/$label.jsonl --provider-commit $commit)
  local from=${FROM:-1}
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

# prepare <model>: corpus, acceptance policy and formal R015 policy for
# HEAD_COMMIT, then the model-free validators. No MLX use.
prepare() {
  local m=$1 mid=$(model_id $1) root=$LAB/fixtures/$1
  head_ok; mkdir -p $FORMAL
  local corpus=$FORMAL/$m-acceptance-corpus.json
  [[ -f $corpus ]] || $HARNESS/macprovider-cli native-mtp-journey-e2e --root $root --model-id $mid \
    --qualified-slots $QUALIFIED_SLOTS --max-native-active-rows 1 --max-prompt-tokens 4096 \
    --prepare-acceptance-corpus $corpus
  /usr/bin/python3 -I - $POLICIES/$m-step1-d1.json $corpus $HEAD_COMMIT \
    $SRC/phase3-binary/Package.resolved $FORMAL/$m-acceptance-policy.json $FORMAL/$m-r015-policy.json <<'PY'
import hashlib, json, sys
step1, corpus, commit, resolved, acceptance_out, r015_out = sys.argv[1:]
base = json.load(open(step1))
fork = [p for p in json.load(open(resolved))["pins"] if p["identity"] == "mlx-swift-lm"][0]["state"]["revision"]
environment = {k: base[k] for k in ("model_id", "target_sha256", "mtp_sha256", "tokenizer_sha256", "hw_model",
    "chip", "ram_gb", "os_build", "xcode_build_version", "swift_version", "quantization", "cache_mode")}
environment.update(provider_commit=commit, mlx_fork_revision=fork)
acceptance = dict(environment, schema="macprovider.native-mtp-acceptance-policy.v1",
    corpus_sha256=hashlib.sha256(open(corpus, "rb").read()).hexdigest())
# The approved Qwen R015 contract (qwen36-35b-r015-2026-10-21), at four
# qualified slots: gated s2 and s4, sustained on s4-p1536-o512.
r015 = dict(environment, schema="macprovider.native-mtp-r015-policy.v1", proposal_depth=1,
    run_order="seeded_random_counterbalanced", prompt_corpus="deterministic_synthetic_unique_v2",
    exclusion_rules="none", confidence_method="paired_block_bootstrap_holm_v1",
    qualified_slots=4, max_native_active_rows=1, arrival_interval_ms=250, slots=[1],
    maximum_prompt_tokens=4096, prompt_tokens=[1536, 4096], max_tokens=[128, 512],
    gated_cells=["s2-p1536-o512", "s4-p1536-o512"], warmup_runs=1, blocks=10, seed=20261104,
    sustained_seconds=1800, sustained_cell_id="s4-p1536-o512", memory_safety_margin_bytes=8589934592,
    thresholds={"throughput_lower_bound_min": 0.15, "ttft_p95_upper_bound_max": 0.1,
        "tpot_p95_upper_bound_max": 0.0, "chunk_gap_p99_upper_bound_max": 1.0,
        "rejection_increase_max_pp": 1.0, "min_available_memory_fraction": 0.1,
        "bootstrap_draws": 10000, "alpha": 0.05, "gated_throughput_lower_bound_min": -0.05,
        "gated_ttft_p95_upper_bound_max": 0.05, "gated_tpot_p95_upper_bound_max": 0.05})
for path, doc in ((acceptance_out, acceptance), (r015_out, r015)):
    with open(path, "w") as fh:
        json.dump(doc, fh, sort_keys=True, separators=(", ", ": "))
    print(path, hashlib.sha256(open(path, "rb").read()).hexdigest())
PY
  $HARNESS/macprovider-cli native-mtp-journey-e2e --root $root --model-id $mid \
    --qualified-slots $QUALIFIED_SLOTS --max-native-active-rows 1 --max-prompt-tokens 4096 \
    --acceptance-corpus $corpus --acceptance-policy $FORMAL/$m-acceptance-policy.json \
    --provider-commit $HEAD_COMMIT --validate-acceptance-only --identity-cache $LAB/identity-cache.json
  env MACPROVIDER_NATIVE_MTP_E2E=1 $HARNESS/macprovider-cli native-mtp-bench --root $root --model-id $mid \
    --policy $FORMAL/$m-r015-policy.json --out $FORMAL/validate-$m-r015.jsonl \
    --provider-commit $HEAD_COMMIT --validate-policy-only --identity-cache $LAB/identity-cache.json
}

tokenizer_identity() {
  /usr/bin/python3 -I - $1 <<'PY'
import hashlib, json, os, sys
d = sys.argv[1]
h = hashlib.sha256()
for n in ("tokenizer_config.json", "tokenizer.json"):
    p = os.path.join(d, n)
    if os.path.exists(p):
        h.update(n.encode() + b"\0" + open(p, "rb").read())
t = None
for n in ("chat_template.jinja", "chat_template.json", "chat_template.txt"):
    p = os.path.join(d, n)
    if os.path.exists(p):
        t = hashlib.sha256(n.encode() + b"\0" + open(p, "rb").read()).hexdigest()
        break
if t is None:
    c = json.load(open(os.path.join(d, "tokenizer_config.json"))).get("chat_template")
    t = hashlib.sha256(("chat_template\0" + c).encode()).hexdigest()
print(h.hexdigest(), t)
PY
}

status_line() { curl -s --max-time 5 http://127.0.0.1:$LAB_PORT/v1/status | /usr/bin/python3 -I -c '
import json,sys; d=json.load(sys.stdin); cb=d.get("continuous_batching") or {}; p=cb.get("policy") or {}
print("cb_active=%s mode=%s load_status=%s authorized=%s decision=%s local_proof=%s paged=%s slots_total=%s binary=%s digest=%s" % (cb.get("active"), cb.get("mode"), p.get("load_status"), p.get("authorized"), p.get("decision_reason"), p.get("local_proof_result"), cb.get("paged_kv_decision"), d.get("slots_total"), d.get("binary_version"), (d.get("build_identity") or {}).get("decode_path_digest")))'; }

SERVE_PID=
stop_serve() {
  [[ -n $SERVE_PID ]] || return 0
  kill -TERM $SERVE_PID 2>/dev/null
  for i in {1..24}; do kill -0 $SERVE_PID 2>/dev/null || break; sleep 5; done
  kill -KILL $SERVE_PID 2>/dev/null; SERVE_PID=
}

leg_cb() {
  local m=$1 mid=$2 d=$3 target=$LAB/fixtures/$1/target
  local sha=$(/usr/bin/python3 -I -c 'import json,sys; print(json.load(open(sys.argv[1]))["target_sha256"])' $FORMAL/$m-r015-policy.json)
  local ident=($(tokenizer_identity $target))
  mkdir -p $d/home $d/tmp
  {
    print -r -- "model: $mid"
    print -r -- "model_artifact_path: \"$target\""
    print -r -- "model_artifact_sha256: $sha"
    print -r -- "port: $LAB_PORT"
    print -r -- "ctl_socket_path: \"$d/tmp/ctl.sock\""
    print -r -- "credential_store: protected_file"
    print -r -- "continuous_batching: canary"
    print -r -- "continuous_batch_queue_limit: 16"
    print -r -- "continuous_batching_cached_turns: true"
    print -r -- "native_mtp_mode: off"
    print -r -- "max_concurrency_override: $QUALIFIED_SLOTS"
    print -r -- "paged_kv:"
    print -r -- "  enabled: true"
    print -r -- "continuous_batching_accepted_tuples:"
    print -r -- "  - {model_id: $mid, model_sha256: $sha, tokenizer_sha256: ${ident[1]}, chat_template_sha256: ${ident[2]}, cache_class: mixed, kv_dtype: fp16, requires_moe: false, hardware_class: \"$HARDWARE_CLASS\", metallib_sha256: $RELEASE_METALLIB_SHA256, kernel_identifier: $KERNEL_IDENTIFIER, cached_turns_accepted: true}"
  } > $d/cb.yaml
  log "$m cb: serve start"
  ( export CFFIXED_USER_HOME=$d/home TMPDIR=$d/tmp/ MACPROVIDER_LIFECYCLE_ROOT=$d/home/lifecycle \
      MACPROVIDER_CTL_SOCKET_PATH=$d/tmp/ctl.sock MACPROVIDER_SWITCH_STATE_PATH=$d/tmp/last-switch.ts \
      MACPROVIDER_WATCHDOG_STATE_DIR=$d/home/watchdog MACPROVIDER_AUTO_UPDATE_ENABLED=false
    exec $HARNESS/macprovider-cli serve --config $d/cb.yaml --no-join > $d/cb-serve.out 2> $d/cb-serve.err < /dev/null ) &
  SERVE_PID=$!
  local ready=0
  for i in {1..720}; do
    live_absent || { log "live appeared; abort"; stop_serve; return 4; }
    kill -0 $SERVE_PID 2>/dev/null || { log "$m cb serve exited: $(tail -5 $d/cb-serve.err | tr '\n' ' ' | cut -c1-400)"; SERVE_PID=; return 5; }
    if grep -q 'event=served_slots action=applied' $d/cb-serve.err 2>/dev/null &&
       curl -s --max-time 3 http://127.0.0.1:$LAB_PORT/v1/status | /usr/bin/python3 -I -c 'import json,sys; sys.exit(0 if json.load(sys.stdin).get("model_loaded") is True else 1)' 2>/dev/null; then
      ready=1; break
    fi
    sleep 5
  done
  (( ready )) || { log "$m cb serve not ready"; stop_serve; return 6; }
  ps -o command= -p $SERVE_PID | cut -c1-200 >> $d/serve-process.txt
  log "$m cb ready $(status_line)"
  grep -m1 'runtime-identity model=' $d/cb-serve.err | cut -c1-400 | tee -a $OUT/summary.txt
  grep -E 'event=batching_cached_turns|event=continuous_batching_policy|continuous_batching_manual_tuple|event=served_slots|isolation|\[paged-kv\] parity|self_check' $d/cb-serve.err | cut -c1-400 | tee -a $OUT/summary.txt
  curl -s http://127.0.0.1:$LAB_PORT/v1/status > $d/cb-status-start.json
  local base=$(wc -l < $d/cb-serve.err | tr -d ' ') rc=0 prc
  for rows in 1 4; do
    prc=0
    /usr/bin/python3 -I $SRC/scripts/lab/cb-studio/glm53_cb_prefix_cache.py --port $LAB_PORT --model $mid \
      --rows $rows --turns 4 --run-id $m-parity-r$rows > $d/parity-rows$rows.json 2> $d/parity-rows$rows.err || prc=$?
    log "$m cb parity rows=$rows rc=$prc"
    (( prc == 0 )) || rc=7
  done
  curl -s http://127.0.0.1:$LAB_PORT/v1/status > $d/cb-status-end.json
  find $d/home -name 'cb-self-check*.json' -exec cp {} $d/ \; 2>/dev/null || true
  stop_serve
  tail -n +$(( base + 1 )) $d/cb-serve.err > $d/cb-driver.err
  local L=$d/cb-driver.err
  log "$m cb routing: snapshot_hits=$(grep -c 'action=hit .*prompt_snapshot=true' $L || true) batching_admitted=$(grep -c 'event=batching_admitted' $L || true) serial_routed=$(grep -c 'serial_routed' $L || true) forward_failures=$(grep -cE 'batching_forward_failed|batching_prefill_failed|prompt_snapshot_install_unavailable' $L || true)"
  grep -o 'serial_routed reason=[a-z_]*' $L | sort | uniq -c | tee -a $OUT/summary.txt || true
  return $rc
}

leg_msb() {
  local m=$1 d=$3 target=$LAB/fixtures/$1/target rc=0 r
  for rows in 1 2 4; do
    live_absent || return 3
    log "$m msb paged rows=$rows start"; r=0
    run_bounded ${STEP_TIMEOUT_S:-0} $m-msb-rows$rows $d/msb-rows$rows.out $d/msb-rows$rows.err \
      $HARNESS/macprovider-cli msb-throughput --model $target --engine paged --rows $rows --prompt-tokens 1024 \
      --decode-tokens 128 --runs 3 --block-size-tokens 256 --mlx-cache-limit-mb 2048 --output $d/msb-rows$rows.json || r=$?
    log "$m msb rows=$rows rc=$r $(tail -2 $d/msb-rows$rows.err | tr '\n' ' ' | cut -c1-300)"
    (( r == 0 )) || rc=$r
  done
  live_absent || return 3
  log "$m msb leftovers start"; r=0
  run_bounded ${STEP_TIMEOUT_S:-0} $m-leftovers $d/leftovers.json $d/leftovers.log \
    $HARNESS/macprovider-cli msb-throughput --model $target --engine scheduler --scenario leftovers --rows 4 \
    --prompt-tokens 1024 --parity-tokens 48 --mlx-cache-limit-mb 2048 --stdout-only || r=$?
  log "$m leftovers rc=$r $(grep -o '"pass" *: *[a-z]*' $d/leftovers.json | tr '\n' ' ')"
  (( r == 0 )) || rc=$r
  return $rc
}

leg_r005() {
  local m=$1 mid=$2 d=$3 rc=0
  log "$m r005 start"
  run_bounded ${STEP_TIMEOUT_S:-0} $m-r005 $d/acceptance.json $d/acceptance.err \
    env MACPROVIDER_NATIVE_MTP_E2E=1 $HARNESS/macprovider-cli native-mtp-journey-e2e --root $LAB/fixtures/$m \
    --model-id $mid --qualified-slots $QUALIFIED_SLOTS --max-native-active-rows 1 --max-prompt-tokens 4096 \
    --acceptance-corpus $FORMAL/$m-acceptance-corpus.json --acceptance-policy $FORMAL/$m-acceptance-policy.json \
    --provider-commit $HEAD_COMMIT --acceptance-checkpoint $d/acceptance-checkpoint.json || rc=$?
  log "$m r005 rc=$rc $(/usr/bin/python3 -I -c 'import json,sys; a=json.loads(open(sys.argv[1]).read()); print(a.get("status"), "accepted", a.get("accepted"), "rejected", a.get("rejected"), "positions", a.get("native_compared_positions"), "near_tied", a.get("near_tied_positions"), "failed_checks", [k for k,v in a.get("checks",{}).items() if not v])' $d/acceptance.json 2>&1 | cut -c1-300)"
  return $rc
}

leg_r015() {
  local m=$1 d=$3 rc=0 arc=0 status=MISSING
  cells $HARNESS $HEAD_COMMIT $m $FORMAL/$m-r015-policy.json $d r015 \
    s1-p1536-o128 s1-p1536-o512 s1-p4096-o128 s1-p4096-o512 s2-p1536-o512 s4-p1536-o512 sustained || rc=$?
  # The analyzer is the formal verdict. A bench that exits 0 can still fail
  # the policy, and swallowing that exit left the leg green.
  /usr/bin/python3 -I $SRC/scripts/native_mtp_r015_analyze.py $d/r015.jsonl $FORMAL/$m-r015-policy.json \
    > $d/r015-analysis.json 2> $d/r015-analysis.err || arc=$?
  /usr/bin/python3 -I $SRC/scripts/native_mtp_r015_analyze.py --format markdown $d/r015.jsonl $FORMAL/$m-r015-policy.json \
    > $d/r015-analysis.md 2>&1 || true
  status=$(/usr/bin/python3 -I -c 'import json,sys; print(json.load(open(sys.argv[1])).get("overall_status","MISSING"))' $d/r015-analysis.json 2>/dev/null || echo MISSING)
  log "$m r015 bench=$rc analyzer=$arc overall_status=$status"
  [[ $rc -eq 0 && $arc -eq 0 && $status == PASS ]]
}

leg_bank() {
  local m=$1 mid=$2 d=$3 rc=0 verdict=0 args=()
  for text in "${CANDIDATES[@]}"; do args+=(--selftest-prompt "$text"); done
  log "$m bank start"
  run_bounded ${STEP_TIMEOUT_S:-0} $m-bank $d/bank-journey.json $d/bank-journey.log \
    env MACPROVIDER_NATIVE_MTP_E2E=1 $HARNESS/macprovider-cli native-mtp-journey-e2e --root $LAB/fixtures/$m \
    --model-id $mid --qualified-slots $QUALIFIED_SLOTS --max-native-active-rows 1 --max-prompt-tokens 4096 \
    --selftest-only --selftest-challenge-id native-mtp-selftest-$m-27b-0001 "${args[@]}" || rc=$?
  /usr/bin/python3 -I - $d/bank-journey.json ${BANK_MIN_SPEEDUP:-1.20} $d/bank-entry.json > $d/bank-verdict.txt 2>&1 <<'PY' || verdict=$?
import json, sys
text = open(sys.argv[1]).read()
if "{" not in text:
    sys.exit("bank: no result document (see bank-journey.log)")
doc, floor, chosen = json.loads(text[text.index("{"):]), float(sys.argv[2]), None
for step in doc["steps"]:
    d = step["details"]; est = d.get("on_device_selfcheck_estimate", {})
    ok = all(v is True for v in step["checks"].values()) and "challenge_bank_entry" in d
    c = d.get("challenge_bank_entry", {}).get("expected_counters", {})
    print(f"bank candidate={d.get('selftest_prompt_index')} checks_ok={ok} speedup={est.get('speedup', 0):.3f} "
          f"accepted={c.get('accepted')} rejected={c.get('rejected')}")
    if chosen is None and ok and est.get("speedup", 0) >= floor:
        chosen = d
if chosen is None:
    sys.exit(f"bank FAIL: no candidate passes its checks at speedup >= {floor}")
json.dump(chosen["challenge_bank_entry"], open(sys.argv[3], "w"), sort_keys=True, separators=(",", ":"))
print(f"bank PASS: candidate {chosen['selftest_prompt_index']} -> {sys.argv[3]}")
PY
  tee -a $OUT/summary.txt < $d/bank-verdict.txt
  log "$m bank rc=$rc verdict=$verdict"
  (( rc == 0 && verdict == 0 ))
}

# qualify <model> [legs...]: every leg runs even when an earlier one fails,
# so one failed gate does not hide the others' numbers.
qualify() {
  local m=$1 mid=$(model_id $1); shift
  head_ok
  local legs=("$@"); (( ${#legs} )) || legs=(cb msb r005 r015 bank)
  local d=$OUT/$m failed=()
  mkdir -p $d
  for f in $FORMAL/$m-acceptance-corpus.json $FORMAL/$m-acceptance-policy.json $FORMAL/$m-r015-policy.json; do
    [[ -f $f ]] || { echo "run '$0 prepare $m' first ($f)" >&2; exit 3; }
    shasum -a 256 $f | tee -a $OUT/identity.sha256
  done
  for leg in $legs; do
    live_absent || { log "live appeared; abort"; exit 4; }
    local rc=0
    leg_$leg $m $mid $d || rc=$?
    log "$m leg $leg rc=$rc"
    (( rc == 0 )) || failed+=($leg)
  done
  log "$m qualify done; failed legs: ${failed:-none}"
  (( ${#failed} == 0 ))
}

# validate: every step-1 policy against its harness and fixture, without MLX use.
validate() {
  local m
  for m in qwen36 qwen38; do
    env MACPROVIDER_NATIVE_MTP_E2E=1 $BASE_HARNESS/macprovider-cli native-mtp-bench --root $LAB/fixtures/$m \
      --model-id $(model_id $m) --policy $POLICIES/$m-step1-d1.json --out $LAB/validate-$m-d1.jsonl \
      --provider-commit $BASE_COMMIT --validate-policy-only --identity-cache $LAB/identity-cache.json
  done
}

LOCKED=
# zsh 5.9 does not run an EXIT trap when set -e aborts inside a function, so a
# failed qualify used to leave the lock directory and the next model refused.
# The qualify arm turns set -e off around that call and exits explicitly.
unlock() {
  [[ ${LOCKED:-0} == 1 ]] || return 0
  if rmdir "$LOCK" 2> /dev/null; then
    LOCKED=0
  else
    echo "window lock not removed: $LOCK" >&2
  fi
}
trap 'set +e; stop_serve || true; unlock' EXIT

case ${1:-} in
  step1)
    lock; harness_ok $BASE_HARNESS
    # Same zsh 5.9 rule as qualify: a failing command inside cells skips the
    # EXIT trap and leaves the window lock held.
    set +e
    cells $BASE_HARNESS $BASE_COMMIT ${2:?model} $POLICIES/$2-step1-d1.json $OUT ${2}-step1-d1 \
      s1-p1536-o128 s1-p1536-o512 s1-p4096-o128 s1-p4096-o512
    rc=$?
    set -e
    exit $rc ;;
  prepare) prepare ${2:?model} ;;
  qualify)
    lock; harness_ok $HARNESS
    set +e
    qualify ${2:?model} "${@:3}"
    rc=$?
    set -e
    exit $rc ;;
  validate) validate ;;
  *) echo "usage: $0 step1|prepare|qualify qwen36|qwen38 [leg...] | validate" >&2; exit 2 ;;
esac
