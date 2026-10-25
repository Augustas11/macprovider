#!/bin/zsh
# GLM-5.3-Flash conversation prefix-cache reuse on CB rows (issue #2143,
# SPEC-024-R005). Lab only. Two legs on the campaign's lab-harness release
# build, each one bounded:
#
#   glm53-cb-prefix-cache-window.sh parity   isolated loopback lab serve on
#        127.0.0.1:$LAB_PORT (--no-join --autotune-candidate), CB canary with
#        the signed CB policy loaded plus a manual accepted tuple that records
#        cached_turns_accepted, continuous_batching_cached_turns on. Drives
#        glm53_cb_prefix_cache.py at 1 and 4 rows: warm (same key) vs cold
#        (fresh key) greedy parity per turn, warm turns >= 2 cached. Then
#        fails unless the serve log shows snapshot hits, batched admissions,
#        no serial_routed line and no batched forward or install failure.
#   glm53-cb-prefix-cache-window.sh mtp      `native-mtp-journey-e2e
#        --cached-prefix-turns` (step 13 only) at 1, 2 and 4 native rows:
#        native rows resumed from a snapshot stay native and match ordinary CB
#        token for token; per-turn output tok/s, wall time and acceptance for
#        native and ordinary at the same row count.
#
# The manual accepted tuple is the signed CB policy's GLM entry
# (phase3-binary/catalog/autotune/continuous-batching-policy.json, tuple
# 3ef2a2a0...) with cached_turns_accepted: true. The parity leg first checks
# that the lab serve's own `[paged-kv] runtime-identity` line names the same
# model, hardware, metallib and kernel, so the tuple matches what it measures.
#
# Both legs need the GPU and all of unified memory: run them only inside an
# announced Studio window with the buyer runner stopped, the live provider
# paused, drained to 0 in flight and booted out, and an independent watchdog
# armed. The script refuses while anything listens on :8080, a live
# `macprovider-cli serve` process runs, or the live LaunchAgent is loaded;
# one window runs at a time (a lock directory). Pausing and restoring the
# live provider is the window owner's job.
#
# Env: HARNESS (dir holding the lab-harness macprovider-cli and the signed
# release mlx.metallib), MODEL (served GLM artifact dir), OUT, LAB_PORT (18093),
# PARITY_TURNS (4), MTP_TURNS (4), LEG_TIMEOUT_S (3600).
set -euo pipefail
export PATH=/usr/sbin:/opt/homebrew/bin:/usr/bin:/bin
HARNESS=${HARNESS:-$HOME/lab-glm-cb-cache/src/phase3-binary/.build-lab-harness/release}
MODEL=${MODEL:-"$HOME/Library/Application Support/macprovider/models/Jundot--GLM-5.3-Flash-oQ4e-mtp/36defc5042d92a992a7948e83d6f110b8df69329/7299b6a71a38490e378e9eb6524c426392aa96e3fd561007e0540134bbef48f9"}
OUT=${OUT:-$HOME/lab-glm-cb-cache/window-$(date -u +%Y%m%dT%H%M%SZ)}
LAB_PORT=${LAB_PORT:-18093}
LIVE_PORT=8080
LIVE_LABEL=live.malibu.provider
LIVE_BINARY=$HOME/macprovider/macprovider-cli
LOCK=$HOME/.glm53-cb-prefix-cache-window.lock
MODEL_ID=zai-org/glm-5.3-flash
RELEASE_METALLIB_SHA256=3d9b4a747758128cc5418e62c5ad8e282a11b0d436423537137e013beaa1261b
SRC=${0:A:h}

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
SERVE_PID=
cleanup() {
  [[ -n $SERVE_PID ]] && { kill -TERM $SERVE_PID 2>/dev/null; sleep 5; kill -KILL $SERVE_PID 2>/dev/null || true; }
  (( LOCKED )) && rmdir "$LOCK" 2>/dev/null || true
}
trap cleanup EXIT

# The Studio check NativeMTPHardwareE2ERunner.requireStudioHost() makes,
# before anything loads the model or touches the GPU.
require_studio_host() {
  local model arch chip
  model=$(sysctl -n hw.model 2>/dev/null) || model=
  arch=$(uname -m 2>/dev/null) || arch=
  chip=$(sysctl -n machdep.cpu.brand_string 2>/dev/null) || chip=
  [[ $arch == arm64 && $model == Mac15,* && $chip == "Apple M3 Ultra" ]] ||
    { echo "refusing: expected a Mac Studio M3 Ultra host, got model=$model arch=$arch chip=$chip" >&2; exit 3; }
}

preflight() {
  require_studio_host
  live_absent || exit 3
  mkdir "$LOCK" 2> /dev/null || { echo "refusing: another window holds $LOCK" >&2; exit 3; }
  LOCKED=1
  [[ -x $HARNESS/macprovider-cli && -f $HARNESS/mlx.metallib ]] || { echo "no harness at $HARNESS" >&2; exit 3; }
  [[ $(shasum -a 256 "$HARNESS/mlx.metallib" | cut -d' ' -f1) == $RELEASE_METALLIB_SHA256 ]] ||
    { echo "refusing: $HARNESS/mlx.metallib is not the signed release metallib" >&2; exit 3; }
  [[ -f $MODEL/config.json ]] || { echo "no model at $MODEL" >&2; exit 3; }
  mkdir -p "$OUT"
  shasum -a 256 "$HARNESS/macprovider-cli" "$HARNESS/mlx.metallib" | tee "$OUT/identity.sha256"
}

# write_config <path> [tuple line]: the lab serve config. Without a tuple the
# serve runs only to print its runtime identity.
write_config() {
  local tuple=${2:-}
  {
    print -r -- "model: $MODEL_ID"
    print -r -- "model_artifact_path: \"$MODEL\""
    print -r -- "model_artifact_sha256: $MODEL_SHA256"
    print -r -- "port: $LAB_PORT"
    print -r -- "ctl_socket_path: \"$OUT/ctl.sock\""
    print -r -- "credential_store: protected_file"
    print -r -- "continuous_batching: canary"
    print -r -- "continuous_batching_cached_turns: true"
    print -r -- "native_mtp_mode: auto"
    print -r -- "max_concurrency_override: 4"
    if [[ -n $tuple ]]; then
      print -r -- "continuous_batching_accepted_tuples:"
      print -r -- "$tuple"
    fi
  } > "$1"
}

# start_serve <config> <log stem>: waits for the lab serve's listener.
start_serve() {
  MACPROVIDER_CONV_CACHE_MAX_CONVERSATIONS=16 \
    "$HARNESS/macprovider-cli" serve --config "$1" --no-join --autotune-candidate \
    > "$2.out" 2> "$2.err" < /dev/null &
  SERVE_PID=$!
  local i
  for i in $(seq 1 240); do
    live_absent 2> /dev/null || { echo "live provider appeared; stopping" >&2; exit 4; }
    kill -0 $SERVE_PID 2>/dev/null || { echo "lab serve exited; see $2.err" >&2; exit 5; }
    if lsof -nP -t -iTCP:$LAB_PORT -sTCP:LISTEN 2>/dev/null | grep -qx $SERVE_PID &&
       curl -s --max-time 3 http://127.0.0.1:$LAB_PORT/v1/status |
         /usr/bin/python3 -I -c 'import json,sys; sys.exit(0 if json.load(sys.stdin).get("model_loaded") is True else 1)' 2>/dev/null; then
      # The running executable must be the harness, not a canonical re-exec.
      [[ $(ps -o comm= -p $SERVE_PID) == $HARNESS/macprovider-cli ]] ||
        { echo "refusing: serve pid $SERVE_PID is not $HARNESS/macprovider-cli" >&2; exit 5; }
      return 0
    fi
    sleep 5
  done
  echo "lab serve not ready after 1200 s" >&2; exit 5
}

stop_serve() {
  [[ -n $SERVE_PID ]] || return 0
  kill -TERM $SERVE_PID 2>/dev/null || true
  local i; for i in $(seq 1 24); do kill -0 $SERVE_PID 2>/dev/null || break; sleep 5; done
  kill -KILL $SERVE_PID 2>/dev/null || true
  SERVE_PID=
}

MODEL_SHA256=7299b6a71a38490e378e9eb6524c426392aa96e3fd561007e0540134bbef48f9
HARDWARE_CLASS="apple-silicon:Apple M3 Ultra:ram-256gb"
KERNEL=macprovider_paged_kv_gather_v1
TUPLE="  - {model_id: $MODEL_ID, model_sha256: $MODEL_SHA256, tokenizer_sha256: 1e9d4f69cfe47ae2d32262646881c81e4a79e58ebb3ac1c8c41477372c1b714d, chat_template_sha256: 6138d780f0ca0e16e3b174cb9b4d782525e32a2f63255d66e707b4c491a7ac6d, cache_class: mixed, kv_dtype: fp16, requires_moe: true, hardware_class: \"$HARDWARE_CLASS\", metallib_sha256: $RELEASE_METALLIB_SHA256, kernel_identifier: $KERNEL, cached_turns_accepted: true}"

# bounded <seconds> <stdout> <stderr> cmd...: killed at the limit, or as soon
# as the live provider could share the GPU.
bounded() {
  local limit=$1 out=$2 err=$3; shift 3
  "$@" > "$out" 2> "$err" &
  local pid=$! t0=$(date +%s)
  while kill -0 $pid 2>/dev/null; do
    if ! live_absent 2>> "$OUT/summary.txt" || (( $(date +%s) - t0 >= limit )); then
      echo "stopping pid $pid: limit or live provider" | tee -a "$OUT/summary.txt"
      kill -TERM $pid 2>/dev/null; sleep 5; kill -KILL $pid 2>/dev/null || true
      wait $pid 2>/dev/null || true
      return 124
    fi
    sleep 5
  done
  wait $pid
}

parity() {
  preflight
  write_config "$OUT/config.yaml" "$TUPLE"
  start_serve "$OUT/config.yaml" "$OUT/serve"
  local identity
  identity=$(grep -m1 'runtime-identity model=' "$OUT/serve.err") || { echo "no runtime-identity line" >&2; exit 6; }
  [[ $identity == *"model_sha256=$MODEL_SHA256 hardware_class=$HARDWARE_CLASS metallib_sha256=$RELEASE_METALLIB_SHA256 kernel_identifier=$KERNEL"* ]] ||
    { echo "refusing: runtime identity differs from the signed GLM tuple: $identity" >&2; exit 6; }
  curl -s http://127.0.0.1:$LAB_PORT/v1/status > "$OUT/status-start.json"
  local rc=0 rows
  for rows in 1 4; do
    bounded ${LEG_TIMEOUT_S:-3600} "$OUT/parity-rows$rows.json" "$OUT/parity-rows$rows.err" \
      /usr/bin/python3 -I "$SRC/glm53_cb_prefix_cache.py" --port $LAB_PORT \
      --rows $rows --turns ${PARITY_TURNS:-4} --run-id "parity-r$rows-$(date -u +%H%M%S)" || rc=$?
    echo "parity rows=$rows rc=$rc" | tee -a "$OUT/summary.txt"
  done
  curl -s http://127.0.0.1:$LAB_PORT/v1/status > "$OUT/status-end.json"
  stop_serve
  local log=$OUT/serve.err hits admitted serial failures
  # The isolated --no-join serve takes only this driver's requests, so the
  # whole serve log is this leg's traffic.
  hits=$(grep -c 'action=hit .*prompt_snapshot=true' $log || true)
  admitted=$(grep -c 'event=batching_admitted' $log || true)
  serial=$(grep -c 'serial_routed' $log || true)
  failures=$(grep -cE 'batching_forward_failed|batching_prefill_failed|prompt_snapshot_install_unavailable' $log || true)
  {
    echo "snapshot_hits=$hits"
    echo "snapshot_drafter_misses=$(grep -c 'reason=prompt_snapshot_drafter_unavailable' $log || true)"
    echo "batching_admitted=$admitted"
    echo "serial_routed=$serial"
    echo "forward_failures=$failures"
    grep -o 'serial_routed reason=[a-z_]*' $log | sort | uniq -c || true
  } | tee -a "$OUT/summary.txt"
  # PASS needs the snapshot resumed on CB rows: hits and batched admissions,
  # no serial route and no failed forward or install.
  if (( hits == 0 || admitted == 0 || serial > 0 || failures > 0 )); then
    echo "parity verdict=FAIL (routing: CB snapshot resume not exercised cleanly)" | tee -a "$OUT/summary.txt"
    (( rc != 0 )) || rc=7
  else
    echo "parity routing verdict=PASS" | tee -a "$OUT/summary.txt"
  fi
  return $rc
}

mtp() {
  preflight
  local root=$OUT/journey-fixture rc=0 rows
  mkdir -p "$root"
  [[ -d $root/target ]] || cp -cR "$MODEL" "$root/target"
  for rows in 1 2 4; do
    bounded ${LEG_TIMEOUT_S:-3600} "$OUT/mtp-rows$rows.json" "$OUT/mtp-rows$rows.log" \
      env MACPROVIDER_NATIVE_MTP_E2E=1 \
      "$HARNESS/macprovider-cli" native-mtp-journey-e2e --root "$root" --model-id $MODEL_ID \
      --qualified-slots 4 --max-native-active-rows $rows --max-prompt-tokens 4096 \
      --cached-prefix-turns ${MTP_TURNS:-4} || rc=$?
    echo "mtp rows=$rows rc=$rc" | tee -a "$OUT/summary.txt"
  done
  return $rc
}

case ${1:-} in
  parity) parity ;;
  mtp) mtp ;;
  *) echo "usage: $0 parity|mtp" >&2; exit 2 ;;
esac
