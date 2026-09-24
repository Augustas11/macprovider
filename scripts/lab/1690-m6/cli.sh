#!/usr/bin/env bash
# Run the lab macprovider-cli with every home-, config-, credential-, and
# temp-derived path redirected under $LAB, so nothing touches the live
# provider's ~/.config/macprovider, lifecycle, locks, or control socket.
set -euo pipefail
LAB="${LAB:-/Users/a1/lab-1690-m6}"
export CFFIXED_USER_HOME="$LAB/home"
export TMPDIR="$LAB/tmp/"
export MACPROVIDER_CONFIG="$LAB/provider/config.yaml"
export MACPROVIDER_LIFECYCLE_ROOT="$LAB/home/lifecycle"
export MACPROVIDER_CTL_SOCKET_PATH="$LAB/tmp/ctl.sock"
export MACPROVIDER_SWITCH_STATE_PATH="$LAB/tmp/last-switch.ts"
export MACPROVIDER_WATCHDOG_STATE_DIR="$LAB/home/watchdog"
export MACPROVIDER_LLAMACPP_MODEL_PATH="$LAB/models/qwen2.5-0.5b-instruct-q4_k_m.gguf"
export MACPROVIDER_BYOM_ALLOW_INSECURE_LOOPBACK_COORDINATOR=1
export MACPROVIDER_AUTO_UPDATE_ENABLED=false
export MACPROVIDER_MAX_CONCURRENCY_OVERRIDE="${MACPROVIDER_MAX_CONCURRENCY_OVERRIDE:-4}"
case "$(grep -E '^coordinator_url:' "$MACPROVIDER_CONFIG")" in
  *"ws://127.0.0.1:191"*) ;;
  *) echo "refusing: lab config must point at a 191xx loopback coordinator" >&2; exit 2 ;;
esac
exec "${LAB_CLI:-$LAB/bin/macprovider-cli-lab}" "$@"
