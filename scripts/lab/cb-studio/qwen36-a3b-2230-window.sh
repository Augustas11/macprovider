#!/bin/zsh
# #2230 fork sync: the Studio cells for Qwen3.6-35B-A3B. Lab only: isolated
# no-join loopback serves on APFS clones of the staged artifacts, one model
# resident at a time, never the live port.
#
# What changed for the live tuples (HARD RULE 2): the first #2230 candidate
# (3.32.3-macprovider.41) routed unmasked gated delta prefill blocks longer
# than 8 steps to MLXFast.gatedDeltaUpdate (upstream #740), which touches every
# A3B prefill chunk over 8 tokens. These cells caught it breaking paged-KV
# serial-versus-batched parity, so 3.32.3-macprovider.43 leaves #740 out and
# no Qwen3.6 line changes; the cells confirm that. GLM-5.3-Flash (CB, native
# MTP) runs no changed line (GLM5Next uses gatedDeltaUpdateVectorized and its
# own latent-cache masks), so it gets no cell.
#
#   qwen36-a3b-2230-window.sh isolation on|off
#        HEAD CB canary serve with MLX_LM_QWEN35_FUSED_MOE=1|0: startup
#        batched-isolation (established/proven, crossRowDivergences=0,
#        paged attach), the FR-CB10 self-check, then the grouped-prefill
#        driver (short prompts alone, equal 256-token prompts grouped) behind
#        a decoding row.
#   qwen36-a3b-2230-window.sh ttft base|head
#        Serial greedy prefill time at about 1536 and
#        4096 prompt tokens on BASE (#2265's .37/.38 build: same Qwen code)
#        or HEAD (.43), CB canary,
#        native MTP off.
#   qwen36-a3b-2230-window.sh compare
#        HEAD vs BASE prefill p50 and greedy-output parity (model-free).
#   qwen36-a3b-2230-window.sh bank
#        Re-record the A3B native-MTP self-test bank entry on HEAD
#        (native-mtp-journey-e2e --selftest-only, challenge
#        native-mtp-selftest-journey-0002). The 17-token challenge prompt now
#        prefills through MLXFast, so the committed-state hash of
#        native-mtp-selftest-journey-0001 is not expected to hold.
#   qwen36-a3b-2230-window.sh all
#        isolation on, isolation off, ttft base, ttft head, compare, bank.
#
# Every leg but compare needs the GPU: run it only inside an announced Studio
# window with the buyer runner's Studio target dropped and the live provider
# paused, drained and booted out. Each leg refuses to start while anything
# listens on :8080, the live serve process runs, or the live LaunchAgent is
# loaded. Pausing and restoring the live provider is the window owner's job.
#
# Env: LAB (~/macprovider-lab-2230), SRC ($LAB/src, the HEAD tree),
# HEAD_HARNESS ($SRC release build), BASE_HARNESS ($LAB/src-base release
# build on the #2265 core), OUT, LAB_PORT (18097). Fixtures: $LAB/fixtures/a3b/
# target and mtp (APFS clones of the staged A3B artifacts). Each harness dir
# holds macprovider-cli and the mlx.metallib built from its own mlx-swift
# checkout (the #2265 core changes the library, so no signed release
# metallib matches it); the CB tuple names that metallib's hash.
set -euo pipefail
export PATH=/usr/sbin:/opt/homebrew/bin:/usr/bin:/bin
export DEVELOPER_DIR=$HOME/Applications/Xcode.app/Contents/Developer
LAB=${LAB:-$HOME/macprovider-lab-2230}
SRC=${SRC:-$LAB/src}
HEAD_HARNESS=${HEAD_HARNESS:-$SRC/phase3-binary/.build/arm64-apple-macosx/release}
BASE_HARNESS=${BASE_HARNESS:-$LAB/src-base/phase3-binary/.build/arm64-apple-macosx/release}
OUT=${OUT:-$LAB/window-$(date -u +%Y%m%dT%H%M%SZ)}
LAB_PORT=${LAB_PORT:-18097}
LIVE_PORT=8080
LIVE_LABEL=live.malibu.provider
LIVE_BINARY=$HOME/macprovider/macprovider-cli
LOCK=$HOME/.qwen36-a3b-2230-window.lock
MODEL_ID=qwen/qwen3.6-35b-a3b
FIXTURE=$LAB/fixtures/a3b
DRIVER=$SRC/scripts/lab/cb-studio/qwen36_2230_cells.py
HARDWARE_CLASS="apple-silicon:Apple M3 Ultra:ram-256gb"
# The signed A3B CB tuple (continuous-batching-policy.json).
MODEL_SHA256=3fed776d41b6883888541d19f71a3866acc3bc6e628402066b67e5ac0a676ff1
TOKENIZER_SHA256=eec97aac7c5f9ba9159d4784222300eccf5ff2e6b4aeb193c8c939c912633510
CHAT_TEMPLATE_SHA256=9cf4f46deaa06769f3240ada331ac0f348694db48ec2e8b51068935f77bb18f9

live_absent() {
  local listeners probe
  listeners=$(lsof -nP -t -iTCP:$LIVE_PORT -sTCP:LISTEN 2>&1) || true
  if [[ -n $listeners ]] || ! command -v lsof > /dev/null; then
    echo "refusing: :$LIVE_PORT has a listener or cannot be probed" >&2; return 3
  fi
  probe=0; pgrep -f "^$LIVE_BINARY serve" > /dev/null 2>&1 || probe=$?
  (( probe == 1 )) || { echo "refusing: the live serve process runs or cannot be probed" >&2; return 3; }
  probe=0; launchctl print gui/$(id -u)/$LIVE_LABEL > /dev/null 2>&1 || probe=$?
  (( probe == 113 )) || { echo "refusing: $LIVE_LABEL is loaded or cannot be probed" >&2; return 3; }
}

log() { echo "$(date -u +%FT%TZ) $*" | tee -a $OUT/summary.txt; }

harness_ok() {
  [[ -x $1/macprovider-cli && -f $1/mlx.metallib ]] || { echo "no harness at $1" >&2; exit 3; }
  shasum -a 256 "$1/macprovider-cli" "$1/mlx.metallib" | tee -a "$OUT/identity.sha256"
}

SERVE_PID=
stop_serve() {
  [[ -n $SERVE_PID ]] || return 0
  kill -TERM $SERVE_PID 2>/dev/null
  for i in {1..24}; do kill -0 $SERVE_PID 2>/dev/null || break; sleep 5; done
  kill -KILL $SERVE_PID 2>/dev/null; SERVE_PID=
}

# serve <harness> <dir> <fused 0|1>: isolated no-join CB canary serve, native
# MTP off, under the signed A3B tuple. Returns once the model is loaded and
# the served-slots plan is applied.
serve() {
  local harness=$1 d=$2 fused=$3 metallib_sha
  metallib_sha=$(shasum -a 256 "$harness/mlx.metallib" | cut -d' ' -f1)
  mkdir -p $d/home $d/tmp
  {
    print -r -- "model: $MODEL_ID"
    print -r -- "model_artifact_path: \"$FIXTURE/target\""
    print -r -- "model_artifact_sha256: $MODEL_SHA256"
    print -r -- "port: $LAB_PORT"
    print -r -- "ctl_socket_path: \"$d/tmp/ctl.sock\""
    print -r -- "credential_store: protected_file"
    print -r -- "continuous_batching: canary"
    print -r -- "continuous_batch_queue_limit: 16"
    print -r -- "native_mtp_mode: off"
    print -r -- "paged_kv:"
    print -r -- "  enabled: true"
    print -r -- "continuous_batching_accepted_tuples:"
    print -r -- "  - {model_id: $MODEL_ID, model_sha256: $MODEL_SHA256, tokenizer_sha256: $TOKENIZER_SHA256, chat_template_sha256: $CHAT_TEMPLATE_SHA256, cache_class: mixed, kv_dtype: fp16, requires_moe: true, hardware_class: \"$HARDWARE_CLASS\", metallib_sha256: $metallib_sha, kernel_identifier: macprovider_paged_kv_gather_v1, cached_turns_accepted: false}"
  } > $d/serve.yaml
  ( export CFFIXED_USER_HOME=$d/home TMPDIR=$d/tmp/ MACPROVIDER_LIFECYCLE_ROOT=$d/home/lifecycle \
      MACPROVIDER_CTL_SOCKET_PATH=$d/tmp/ctl.sock MACPROVIDER_SWITCH_STATE_PATH=$d/tmp/last-switch.ts \
      MACPROVIDER_WATCHDOG_STATE_DIR=$d/home/watchdog MACPROVIDER_AUTO_UPDATE_ENABLED=false \
      MLX_LM_QWEN35_FUSED_MOE=$fused
    exec $harness/macprovider-cli serve --config $d/serve.yaml --no-join > $d/serve.out 2> $d/serve.err < /dev/null ) &
  SERVE_PID=$!
  for i in {1..720}; do
    live_absent || { stop_serve; return 4; }
    kill -0 $SERVE_PID 2>/dev/null || { log "serve exited: $(tail -5 $d/serve.err | tr '\n' ' ' | cut -c1-400)"; SERVE_PID=; return 5; }
    if grep -q 'event=served_slots action=applied' $d/serve.err 2>/dev/null &&
       curl -s --max-time 3 http://127.0.0.1:$LAB_PORT/v1/status | /usr/bin/python3 -I -c 'import json,sys; sys.exit(0 if json.load(sys.stdin).get("model_loaded") is True else 1)' 2>/dev/null; then
      ps -o command= -p $SERVE_PID | cut -c1-200 >> $d/serve-process.txt
      curl -s http://127.0.0.1:$LAB_PORT/v1/status > $d/status-start.json
      return 0
    fi
    sleep 5
  done
  log "serve not ready"; stop_serve; return 6
}

leg_isolation() {
  local fused=$([[ $1 == on ]] && echo 1 || echo 0) d=$OUT/isolation-$1 rc=0
  harness_ok $HEAD_HARNESS
  log "isolation fused=$1 start"
  serve $HEAD_HARNESS $d $fused || return $?
  grep -E 'batched-isolation model=|paged_kv_decision|event=cb_self_check|continuous_batch_decode_row_bound|continuous_batch_prefill_grouping' \
    $d/serve.err | cut -c1-400 | tee $d/isolation-lines.txt | tee -a $OUT/summary.txt
  grep -qE 'batched-isolation model=.* proven=true .*crossRowDivergences=0( |$)' $d/isolation-lines.txt ||
    { log "isolation fused=$1 FAIL: batched-isolation not proven with zero divergences"; rc=7; }
  /usr/bin/python3 -I -c 'import json,sys; s=json.load(open(sys.argv[1])); cb=s.get("continuous_batching") or {}; sys.exit(0 if cb.get("paged_kv_decision")=="attached" else 1)' \
    $d/status-start.json || { log "isolation fused=$1 FAIL: paged KV not attached"; rc=7; }
  /usr/bin/python3 -I $DRIVER grouped --port $LAB_PORT --model $MODEL_ID --out $d/grouped.json \
    2> $d/grouped.err || { log "isolation fused=$1 FAIL: grouped prefill $(tail -1 $d/grouped.err)"; rc=8; }
  tail -1 $d/grouped.err | tee -a $OUT/summary.txt
  curl -s http://127.0.0.1:$LAB_PORT/v1/status > $d/status-end.json
  find $d/home -name 'cb-self-check*.json' -exec cp {} $d/ \; 2>/dev/null || true
  stop_serve
  log "isolation fused=$1 rc=$rc"
  return $rc
}

leg_ttft() {
  local which=$1 harness d=$OUT/ttft-$1 rc=0
  harness=$([[ $which == base ]] && echo $BASE_HARNESS || echo $HEAD_HARNESS)
  harness_ok $harness
  log "ttft $which start"
  serve $harness $d 1 || return $?
  /usr/bin/python3 -I $DRIVER ttft --port $LAB_PORT --model $MODEL_ID --label $which --out $OUT/ttft-$which.json \
    2> $d/ttft.err || rc=$?
  tee -a $OUT/summary.txt < $d/ttft.err
  stop_serve
  log "ttft $which rc=$rc"
  return $rc
}

leg_compare() {
  /usr/bin/python3 -I $DRIVER compare $OUT/ttft-base.json $OUT/ttft-head.json | tee $OUT/ttft-compare.txt | tee -a $OUT/summary.txt
}

leg_bank() {
  local d=$OUT/bank rc=0
  harness_ok $HEAD_HARNESS
  mkdir -p $d
  log "bank start"
  env MACPROVIDER_NATIVE_MTP_E2E=1 $HEAD_HARNESS/macprovider-cli native-mtp-journey-e2e --root $FIXTURE \
    --model-id $MODEL_ID --qualified-slots 8 --max-native-active-rows 1 --max-prompt-tokens 4096 \
    --selftest-only --selftest-challenge-id native-mtp-selftest-journey-0002 \
    > $d/bank-journey.json 2> $d/bank-journey.log < /dev/null || rc=$?
  log "bank rc=$rc $(grep -o '"challenge_bank_entry"' $d/bank-journey.json | head -1)"
  return $rc
}

mkdir -p $OUT
leg=${1:-}
if [[ $leg != compare ]]; then
  live_absent || exit 3
  mkdir "$LOCK" 2> /dev/null || { echo "refusing: another window holds $LOCK" >&2; exit 3; }
  trap 'set +e; stop_serve || true; rmdir "$LOCK" 2>/dev/null' EXIT
fi
set +e
case $leg in
  isolation) leg_isolation ${2:?on|off} ;;
  ttft) leg_ttft ${2:?base|head} ;;
  compare) leg_compare ;;
  bank) leg_bank ;;
  all)
    failed=()
    for step in "isolation on" "isolation off" "ttft base" "ttft head" compare bank; do
      live_absent || { log "live appeared; abort"; exit 4; }
      leg_${=step} || failed+=("$step")
    done
    log "all done; failed: ${failed:-none}"
    (( ${#failed} == 0 )) ;;
  *) echo "usage: $0 isolation on|off | ttft base|head | compare | bank | all" >&2; exit 2 ;;
esac
