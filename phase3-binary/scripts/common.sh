#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PHASE3_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
REPO_ROOT="$(cd "$PHASE3_DIR/.." && pwd)"

MODEL="${MACPROVIDER_MODEL:-mlx-community/Llama-3.2-3B-Instruct-4bit}"
BUILD_DESTINATION="${MACPROVIDER_BUILD_DESTINATION:-platform=macOS,arch=arm64}"

PRODUCTS_DIR=""
BINARY=""
PROVIDER_PID=""

build_binary() {
  (cd "$PHASE3_DIR" && xcodebuild -scheme malibu-cli -configuration Debug -destination "$BUILD_DESTINATION" build >/dev/null)
  local binary_path
  binary_path="$(find "$HOME/Library/Developer/Xcode/DerivedData" -path "*/Build/Products/Debug/malibu-cli" -type f -print 2>/dev/null | head -1)"
  PRODUCTS_DIR="$(dirname "$binary_path")"
  BINARY="$PRODUCTS_DIR/malibu-cli"
  if [[ ! -x "$BINARY" ]]; then
    echo "missing built binary: $BINARY" >&2
    exit 1
  fi
}

provider_env() {
  env DYLD_FRAMEWORK_PATH="$PRODUCTS_DIR/PackageFrameworks:$PRODUCTS_DIR" "$@"
}

start_provider() {
  local port="$1"
  local coordinator="${2:-}"
  local log_file="${3:-/private/tmp/macprovider-$port.log}"
  build_binary
  local args=("$BINARY" --port "$port" --model "$MODEL")
  if [[ -n "$coordinator" ]]; then
    args+=(--coordinator "$coordinator")
  fi
  provider_env "${args[@]}" >"$log_file" 2>&1 &
  PROVIDER_PID="$!"
}

stop_provider() {
  if [[ -n "${PROVIDER_PID:-}" ]] && kill -0 "$PROVIDER_PID" 2>/dev/null; then
    kill -TERM "$PROVIDER_PID" 2>/dev/null || true
    wait "$PROVIDER_PID" 2>/dev/null || true
  fi
}

wait_http() {
  local port="$1"
  local path="${2:-/v1/health}"
  local tries="${3:-120}"
  for _ in $(seq 1 "$tries"); do
    if curl -fsS "http://127.0.0.1:$port$path" >/dev/null 2>&1; then
      return 0
    fi
    sleep 1
  done
  return 1
}

write_python_yaml_shim() {
  local dir="/private/tmp/phase3-binary-python"
  mkdir -p "$dir"
  cat >"$dir/yaml.py" <<'PY'
import json

def safe_load(stream):
    data = stream.read() if hasattr(stream, "read") else stream
    return json.loads(data)
PY
  echo "$dir"
}

write_harness_config() {
  local port="$1"
  local profile="${2:-cooperative}"
  local config="/private/tmp/phase3-binary-harness-$profile-$port.json"
  cat >"$config" <<JSON
{
  "tunnel_url": "http://127.0.0.1:$port",
  "model": "$MODEL",
  "timeout_s": ${MACPROVIDER_HARNESS_TIMEOUT:-180},
  "batch": ["short_chat", "medium_with_system", "long_context", "code_completion", "agent_style", "streaming_check"],
  "batch_adversarial": ["retry_storm", "concurrent_burst_8way", "midstream_disconnect", "malformed_tool_call", "long_context_oom_probe"],
  "db_path": "/private/tmp/phase3-binary-runs.sqlite",
  "reports_dir": "/private/tmp/phase3-binary-reports"
}
JSON
  echo "$config"
}

run_harness() {
  local config="$1"
  shift
  local shim
  shim="$(write_python_yaml_shim)"
  (cd "$REPO_ROOT/beta" && PYTHONPATH="$shim${PYTHONPATH:+:$PYTHONPATH}" python3 harness.py --config "$config" "$@")
}
