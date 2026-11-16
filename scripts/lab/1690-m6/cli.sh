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
# LAB_LLAMACPP_MODEL_PATH overrides the served GGUF (e.g. the Q8_0 #1816 pool entry).
export MACPROVIDER_LLAMACPP_MODEL_PATH="${LAB_LLAMACPP_MODEL_PATH:-$LAB/models/qwen2.5-0.5b-instruct-q4_k_m.gguf}"
if [[ -n "${LAB_MODEL_ARTIFACT_ROOT:-}" ]]; then
  export MACPROVIDER_MODEL_ARTIFACT_ROOT="$LAB_MODEL_ARTIFACT_ROOT"
fi
# #1690 M8: the mlx_lm.server snapshot and origin, and the lab Ollama store.
export MACPROVIDER_MLXLM_MODEL_PATH="${MLXLM_SNAPSHOT:-$LAB/models/mlx/$(basename "${LAB_MLX_ID:-mlx-community/Qwen2.5-0.5B-Instruct-4bit}")}"
export MACPROVIDER_MLXLM_ORIGIN=http://127.0.0.1:19131
export OLLAMA_MODELS="$LAB/ollama-models"
# #1690 M9: the LM Studio models root (the lab llmster home) and the oMLX
# snapshot and origin.
export MACPROVIDER_LMSTUDIO_MODELS_ROOT="$LAB/lmshome/.lmstudio/models"
export MACPROVIDER_OMLX_MODEL_PATH="$LAB/omlx-models/Qwen2.5-0.5B-Instruct-4bit"
export MACPROVIDER_OMLX_ORIGIN=http://127.0.0.1:19131
export MACPROVIDER_BYOM_ALLOW_INSECURE_LOOPBACK_COORDINATOR=1
export MACPROVIDER_AUTO_UPDATE_ENABLED=false
export MACPROVIDER_MAX_CONCURRENCY_OVERRIDE="${MACPROVIDER_MAX_CONCURRENCY_OVERRIDE:-4}"
# Signed static feeds (lab builds only, StaticFeedOrigin.labOverride): a
# closed lab loopback port, so the fetch fails fast and the baked lab release
# is used; the lab static key is trusted instead of production's. Refuse when
# the lab release is missing: without the override the CLI would use the
# production origin.
for f in "$LAB/static/static-public-key.base64" "$LAB/static/autotune-candidates.json.sig"; do
  [[ -s "$f" ]] || { echo "refusing: missing lab static release file $f (rig.sh build)" >&2; exit 2; }
done
export MACPROVIDER_LAB_STATIC_FEED_ORIGIN=http://127.0.0.1:19108
MACPROVIDER_LAB_STATIC_FEED_KEY_ID="$(python3 -c 'import json,sys;print(json.load(open(sys.argv[1]))["key_id"])' "$LAB/static/autotune-candidates.json.sig")"
MACPROVIDER_LAB_STATIC_FEED_PUBLIC_KEY="$(tr -d '[:space:]' <"$LAB/static/static-public-key.base64")"
export MACPROVIDER_LAB_STATIC_FEED_KEY_ID MACPROVIDER_LAB_STATIC_FEED_PUBLIC_KEY
case "$(grep -E '^coordinator_url:' "$MACPROVIDER_CONFIG")" in
  *"ws://127.0.0.1:191"*) ;;
  *) echo "refusing: lab config must point at a 191xx loopback coordinator" >&2; exit 2 ;;
esac
exec "${LAB_CLI:-$LAB/bin/macprovider-cli-lab}" "$@"
