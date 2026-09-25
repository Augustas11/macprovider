#!/usr/bin/env bash
# #1690 e2e fault cases on the llama.cpp pool member (pool A):
#   proxy   the gateway reaches the coordinator through trailer_proxy.py; for
#           every mode and both pin settings send a non-streaming and a
#           streaming request and settle (holds allowed: the reconciler must
#           end every one at the coordinator's finality)
#   rotate  receipt-key rotation (cli.sh rotate-key) on a native serve while a
#           slowly read stream is in flight, then fresh requests on the new key
#   kill    the engine process (llama-server) stopped mid-stream
#
#   faults.sh RUN [proxy] [rotate] [kill]
# Assumes the rig is up on ENGINE=llamacpp. Lab only.
set -euo pipefail
export LAB="${LAB:-/Users/a1/lab-1690-m6/e2e}"
HERE="$(cd "$(dirname "$0")" && pwd)"
RIG="$HERE/../1690-m6/rig.sh"
CLI="$HERE/../1690-m6/cli.sh"
. "$HERE/env.sh"
export E2E_PENDING_DEADLINE_S="${E2E_PENDING_DEADLINE_S:-90}" E2E_REOFFER=1
RUN=$1; shift
M() { python3 "$HERE/matrix.py" "$@"; }
mkdir -p "$LAB/e2e/logs"
exec > >(tee -a "$LAB/e2e/logs/$RUN-faults.log") 2>&1
echo "=== $(date -u +%FT%TZ) faults run=$RUN HEAD=$(git -C "$HERE" rev-parse --short HEAD)"

proxy_cases() {
  export E2E_PROXY_PORT=19105
  "$RIG" proxy-start
  for pin in 0 1; do
    E2E_GATEWAY_PIN=$pin "$RIG" configs
    "$RIG" gateway-restart
    for mode in pass strip_capability strip_trailers strip_decl strip_mac tamper_mac tamper_outcome; do
      echo "$mode" >"$LAB/run/proxy-mode"
      label="$RUN-proxy-pin$pin-$mode"
      glines=$(wc -l <"$LAB/logs/gateway.log")
      M send --label "$label" --engine llamacpp --route pool:A --behaviours normal --shapes plain
      echo pass >"$LAB/run/proxy-mode"
      M settle --label "$label" --timeout 240 || true
      held=$(tail -n +"$((glines + 1))" "$LAB/logs/gateway.log" | grep -c "coordinator finality missing or not authenticated" || true)
      echo "HOLDS [$label] missing_settlement_finality_trailer=$held"
    done
  done
  unset E2E_PROXY_PORT
  E2E_GATEWAY_PIN=0 "$RIG" configs
  "$RIG" gateway-restart
  "$RIG" proxy-stop
}

rotate_case() {
  # Receipt-key rotation needs the serve control socket, which only a native
  # (MLX ModelRuntime) serve exposes, so this case runs on native: a slowly
  # read long stream is in flight while the key rotates, then fresh requests
  # sign with the new key.
  label="$RUN-rotate"
  "$RIG" down >/dev/null 2>&1 || true
  E2E_NATIVE_CLEAR_ADMISSION=1 ENGINE=native "$RIG" up >/dev/null
  sleep 15
  M send --label "$label" --engine native --route global --behaviours normal --shapes plain
  python3 "$HERE/matrix.py" send --label "$label" --engine native --route global --behaviours slow --shapes long &
  bg=$!
  sleep 2
  # An --isolate-lifecycle serve binds its own per-process socket,
  # /private/tmp/macprovider-autotune-<uuid>/control.sock. Resolve it only
  # from the lab serve PID that pidguard re-verifies, and only that pattern;
  # the live provider's socket is never a candidate.
  . "$HERE/../1690-m6/pidguard.sh"
  sock=""
  if spid=$(pg_verify "$LAB/run/serve.pid"); then
    sock=$(lsof -nP -a -p "$spid" -U 2>/dev/null | awk '{print $NF}' | grep -E '^/private/tmp/macprovider-autotune-[0-9a-f-]+/control\.sock$' | head -1)
  fi
  echo "control socket: ${sock:-none (serve pid ${spid:-unverified})}"
  if [[ -n "$sock" ]]; then
    echo "rotate-key: $("$CLI" rotate-key --config "$LAB/provider/config.yaml" --ctl-socket-path "$sock" 2>&1 | tail -1)"
  fi
  wait "$bg" || true
  sleep 10
  M send --label "$label" --engine native --route global --behaviours normal --shapes plain
  M send --label "$label" --engine native --route pool:A --behaviours normal --shapes plain
  M settle --label "$label" --timeout 240 || true
  "$RIG" down >/dev/null 2>&1 || true
  ENGINE=llamacpp "$RIG" up >/dev/null
  sleep 15
}

kill_case() {
  label="$RUN-enginekill"
  touch "$LAB/run/slow-stream"
  python3 "$HERE/matrix.py" send --label "$label" --engine llamacpp --route pool:A --behaviours normal --shapes long --stream-only &
  bg=$!
  sleep 4
  ENGINE=llamacpp "$RIG" server-stop
  wait "$bg" || true
  rm -f "$LAB/run/slow-stream"
  ENGINE=llamacpp "$RIG" server-start
  sleep 10
  M send --label "$label-after" --engine llamacpp --route pool:A --behaviours normal --shapes plain
  M settle --label "$label" --timeout 240 || true
  M settle --label "$label-after" --timeout 240 || true
}

for c in "${@:-proxy rotate kill}"; do
  for x in $c; do
    case "$x" in proxy) proxy_cases ;; rotate) rotate_case ;; kill) kill_case ;; esac
  done
done
echo "=== done $(date -u +%FT%TZ)"
