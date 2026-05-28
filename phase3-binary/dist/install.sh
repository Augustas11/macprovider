#!/usr/bin/env bash
# Public Mac Provider installer for https://get.streamvc.live/install.sh.
#
# Launchd template substitutions performed by this script:
#   __USER_HOME__       -> absolute installing user's HOME
#   __BINARY_PATH__     -> absolute ~/.local/bin/macprovider-cli path
#   __PROVIDER_ID__     -> sanitized provider handle
#   __COORDINATOR_URL__ -> WSS coordinator URL
#   __LOG_DIR__         -> absolute ~/Library/Logs/macprovider path
#   __MODEL_ID__        -> selected MLX model id

set -euo pipefail

GITHUB_REPO="${MACPROVIDER_GITHUB_REPO:-Augustas11/macprovider}"
COORDINATOR_URL_DEFAULT="wss://coordinator.streamvc.live/ws/provider"
COORDINATOR_BASE_DEFAULT="https://coordinator.streamvc.live"
INSTALL_DIR="$HOME/macprovider"
BIN_DIR="$HOME/.local/bin"
BINARY_PATH="$BIN_DIR/macprovider-cli"
CONFIG_DIR="$HOME/.config/macprovider"
CONFIG_PATH="$CONFIG_DIR/config.yaml"
PROVIDER_ID_PATH="$CONFIG_DIR/provider_id"
PLIST_PATH="$HOME/Library/LaunchAgents/live.streamvc.macprovider.plist"
LOG_DIR="$HOME/Library/Logs/macprovider"
PORT="${MACPROVIDER_PORT:-8080}"
DRY_RUN=0
NO_PROMPT="${MACPROVIDER_NO_PROMPT:-0}"
NO_LAUNCHD="${MACPROVIDER_NO_LAUNCHD:-0}"
TMPDIR_PATH=""
LAUNCHD_INSTALLED=0
MANUAL_PID=""

log() { printf "[macprovider-install] %s\n" "$*"; }
die() {
  code="$1"
  shift
  printf "[macprovider-install] ERROR: %s\n" "$*" >&2
  exit "$code"
}

usage() {
  cat <<'USAGE'
Usage: bash install.sh [--dry-run]

Environment overrides:
  MACPROVIDER_GITHUB_REPO        owner/repo for GitHub Releases
  MACPROVIDER_MODEL              model id to install
  MACPROVIDER_COORDINATOR_URL    coordinator WebSocket URL
  MACPROVIDER_NO_PROMPT=1        use defaults without interactive prompts
  MACPROVIDER_NO_LAUNCHD=1       skip launchd service install
USAGE
}

for arg in "$@"; do
  case "$arg" in
    --dry-run) DRY_RUN=1 ;;
    -h|--help) usage; exit 0 ;;
    *) die 7 "unknown argument: $arg" ;;
  esac
done

cleanup() {
  if [ -n "$TMPDIR_PATH" ] && [ -d "$TMPDIR_PATH" ]; then
    rm -rf "$TMPDIR_PATH"
  fi
}
trap cleanup EXIT

run() {
  if [ "$DRY_RUN" -eq 1 ]; then
    printf "[dry-run] "
    printf "%q " "$@"
    printf "\n"
  else
    "$@"
  fi
}

require_tool() {
  command -v "$1" >/dev/null 2>&1 || die 2 "missing required tool: $1"
}

read_line() {
  REPLY=""
  # In curl-pipe-bash invocations, /dev/tty often exists as a character
  # device but `read < /dev/tty` fails with "Device not configured" and
  # prints noise to stderr. Suppress that noise + fall through to empty
  # REPLY (callers use defaults via $NO_PROMPT or prompt_yes_no's default
  # arg). v1.2.1 install.sh's `[ -r /dev/tty ]` check passed when the
  # device existed but the read still failed; v1.2.2 silences the
  # failure path.
  # Try to open /dev/tty via fd 4; the { exec ...; } 2>/dev/null pattern
  # is necessary because bash's input-redirection failure on `< /dev/tty`
  # prints to stderr BEFORE the `2>/dev/null` on the read line takes
  # effect. By opening explicitly here and silencing stderr on the exec,
  # we cleanly detect "is /dev/tty actually usable" without noise.
  if [ -c /dev/tty ] && { exec 4</dev/tty; } 2>/dev/null; then
    IFS= read -r REPLY <&4 2>/dev/null || REPLY=""
    exec 4<&-
  else
    IFS= read -r REPLY 2>/dev/null || REPLY=""
  fi
}

# v1.2.2: pre-flight port collision detection. Without this, install
# proceeds, launchd loads, the binary crashes on bind, and the only
# evidence is "Local self-test failed" 60s later. Surface the real
# problem early with a clear fix path.
ensure_port_free() {
  if [ "$DRY_RUN" -eq 1 ]; then
    return
  fi
  if ! command -v lsof >/dev/null 2>&1; then
    log "lsof not found; skipping port-collision check (rare on macOS)."
    return
  fi
  holding_pids="$(lsof -nP -iTCP:"$PORT" -sTCP:LISTEN -t 2>/dev/null || true)"
  if [ -z "$holding_pids" ]; then
    return
  fi
  holding_cmd="$(lsof -nP -iTCP:"$PORT" -sTCP:LISTEN 2>/dev/null | awk 'NR==2 {print $1 " (pid " $2 ")"}')"
  log "ERROR: port $PORT is already in use by ${holding_cmd:-another process}."
  log "Either stop that process, or set MACPROVIDER_PORT to a free port and re-run."
  log "Note: env var must be on the bash side of the pipe, not the curl side:"
  log "  curl -fsSL https://get.streamvc.live/install.sh | MACPROVIDER_PORT=18080 bash"
  die 6 "port $PORT busy; macprovider-cli cannot bind"
}

prompt_yes_no() {
  prompt="$1"
  default="$2"
  if [ "$NO_PROMPT" = "1" ]; then
    log "$prompt $default (non-interactive default)"
    [ "$default" = "Y" ]
    return
  fi

  printf "%s " "$prompt"
  read_line
  answer="$REPLY"
  answer="${answer:-$default}"
  case "$answer" in
    y|Y|yes|YES) return 0 ;;
    n|N|no|NO) return 1 ;;
    *) return 1 ;;
  esac
}

sanitize_handle() {
  printf "%s" "$1" \
    | tr '[:upper:]' '[:lower:]' \
    | sed -E 's/[^a-z0-9-]+/-/g; s/^-+//; s/-+$//; s/-+/-/g' \
    | cut -c 1-48
}

reject_newlines() {
  name="$1"
  value="$2"
  case "$value" in
    *$'\n'*|*$'\r'*) die 7 "$name must not contain newlines" ;;
  esac
}

xml_escape() {
  printf "%s" "$1" | sed \
    -e 's/&/\&amp;/g' \
    -e 's/</\&lt;/g' \
    -e 's/>/\&gt;/g' \
    -e 's/"/\&quot;/g' \
    -e "s/'/\&apos;/g"
}

yaml_escape() {
  printf "%s" "$1" | sed \
    -e 's/\\/\\\\/g' \
    -e 's/"/\\"/g'
}

urlencode() {
  local input="$1"
  local output=""
  local i char hex
  for ((i = 0; i < ${#input}; i++)); do
    char="${input:i:1}"
    case "$char" in
      [a-zA-Z0-9.~_-]) output="${output}${char}" ;;
      *) printf -v hex '%%%02X' "'$char"; output="${output}${hex}" ;;
    esac
  done
  printf "%s" "$output"
}

coordinator_http_base() {
  coordinator_url="$1"
  case "$coordinator_url" in
    wss://coordinator.streamvc.live/ws/provider) printf "%s" "$COORDINATOR_BASE_DEFAULT" ;;
    wss://*) printf "https://%s" "${coordinator_url#wss://}" | sed -E 's#/ws/provider/?$##' ;;
    *) die 7 "coordinator URL must start with wss://" ;;
  esac
}

detect_platform() {
  os="$(uname -s)"
  arch="$(uname -m)"
  [ "$os" = "Darwin" ] || die 1 "macOS is required; found $os"
  [ "$arch" = "arm64" ] || die 1 "Apple Silicon arm64 is required; found $arch"
  require_tool sw_vers
  macos_version="$(sw_vers -productVersion)"
  macos_major="${macos_version%%.*}"
  case "$macos_major" in
    ''|*[!0-9]*) die 1 "could not determine macOS version from '$macos_version'" ;;
  esac
  [ "$macos_major" -ge 14 ] || die 1 "macOS 14 Sonoma or newer is required; found $macos_version"
}

detect_ram_gb() {
  bytes="$(sysctl -n hw.memsize 2>/dev/null || true)"
  if [ -z "$bytes" ]; then
    printf "[macprovider-install] Could not read hw.memsize; defaulting to 8 GB model tier.\n" >&2
    bytes=8589934592
  fi
  awk "BEGIN { printf \"%d\", ($bytes + 1073741823) / 1073741824 }"
}

model_default_for_ram() {
  ram_gb="$1"
  if [ "$ram_gb" -lt 12 ]; then
    printf "mlx-community/Llama-3.2-3B-Instruct-4bit"
  elif [ "$ram_gb" -lt 24 ]; then
    printf "mlx-community/Qwen2.5-7B-Instruct-4bit"
  else
    printf "mlx-community/Qwen2.5-14B-Instruct-4bit"
  fi
}

choose_model() {
  ram_gb="$1"
  if [ -n "${MACPROVIDER_MODEL:-}" ]; then
    printf "%s" "$MACPROVIDER_MODEL"
    return
  fi

  default_model="$(model_default_for_ram "$ram_gb")"
  if [ "$NO_PROMPT" = "1" ]; then
    printf "%s" "$default_model"
    return
  fi

  printf "[macprovider-install] Detected approximately %s GB RAM.\n" "$ram_gb" >&2
  printf "Choose a model:\n" >&2
  printf "  1) mlx-community/Llama-3.2-3B-Instruct-4bit      ~2 GB, 8 GB Macs\n" >&2
  printf "  2) mlx-community/Qwen2.5-7B-Instruct-4bit        ~4 GB, 16 GB Macs\n" >&2
  printf "  3) mlx-community/Qwen2.5-14B-Instruct-4bit       ~8 GB, 24 GB+ Macs\n" >&2
  printf "Selection [default: %s]: " "$default_model" >&2
  read_line
  selection="$REPLY"
  case "$selection" in
    1) printf "mlx-community/Llama-3.2-3B-Instruct-4bit" ;;
    2) printf "mlx-community/Qwen2.5-7B-Instruct-4bit" ;;
    3) printf "mlx-community/Qwen2.5-14B-Instruct-4bit" ;;
    "") printf "%s" "$default_model" ;;
    *) die 7 "invalid model selection" ;;
  esac
}

choose_provider_id() {
  if [ -f "$PROVIDER_ID_PATH" ]; then
    saved="$(cat "$PROVIDER_ID_PATH")"
    if [ -n "$saved" ]; then
      printf "%s" "$saved"
      return
    fi
  fi

  default_handle="$(sanitize_handle "$(hostname -s 2>/dev/null || hostname)")"
  [ -n "$default_handle" ] || default_handle="macprovider"
  if [ "$NO_PROMPT" = "1" ]; then
    printf "%s" "$default_handle"
    return
  fi

  printf "Choose a provider handle [default: %s]: " "$default_handle" >&2
  read_line
  handle="$REPLY"
  handle="${handle:-$default_handle}"
  sanitized="$(sanitize_handle "$handle")"
  [ -n "$sanitized" ] || die 7 "provider handle must contain a letter or number"
  printf "%s" "$sanitized"
}

choose_coordinator_url() {
  if [ -n "${MACPROVIDER_COORDINATOR_URL:-}" ]; then
    printf "%s" "$MACPROVIDER_COORDINATOR_URL"
    return
  fi
  if [ "$NO_PROMPT" = "1" ]; then
    printf "%s" "$COORDINATOR_URL_DEFAULT"
    return
  fi

  printf "Coordinator URL [default: %s]: " "$COORDINATOR_URL_DEFAULT" >&2
  read_line
  value="$REPLY"
  printf "%s" "${value:-$COORDINATOR_URL_DEFAULT}"
}

validate_inputs() {
  model="$1"
  provider_id="$2"
  coordinator_url="$3"
  reject_newlines "model" "$model"
  reject_newlines "provider_id" "$provider_id"
  reject_newlines "coordinator_url" "$coordinator_url"
  case "$model" in
    ''|*[!A-Za-z0-9._/:+-]*) die 7 "model contains unsupported characters" ;;
  esac
  case "$provider_id" in
    ''|*[!a-z0-9-]*) die 7 "provider_id contains unsupported characters" ;;
  esac
  case "$coordinator_url" in
    wss://*) ;;
    *) die 7 "coordinator URL must start with wss://" ;;
  esac
}

latest_release_tag() {
  api_url="https://api.github.com/repos/${GITHUB_REPO}/releases/latest"
  json="$(curl -fsSL "$api_url")" || die 3 "failed to query GitHub Releases API: $api_url"
  tag="$(printf "%s" "$json" | sed -n 's/.*"tag_name"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' | head -1)"
  [ -n "$tag" ] || die 3 "GitHub Releases API response did not include tag_name"
  printf "%s" "$tag"
}

download_release() {
  tag="$1"
  asset="macprovider-cli-${tag}-darwin-arm64.tar.gz"
  base="https://github.com/${GITHUB_REPO}/releases/download/${tag}"
  TMPDIR_PATH="$(mktemp -d)"
  tarball_path="$TMPDIR_PATH/$asset"
  checksums_path="$TMPDIR_PATH/checksums.txt"
  checksums_sig_path="$TMPDIR_PATH/checksums.txt.sig"

  log "Downloading $asset from GitHub Releases."
  curl -fL "$base/$asset" -o "$tarball_path" || die 3 "failed to download release tarball"
  curl -fL "$base/checksums.txt" -o "$checksums_path" || die 3 "failed to download checksums.txt"
  curl -fL "$base/checksums.txt.sig" -o "$checksums_sig_path" || die 3 "failed to download checksums.txt.sig"
}

write_checksum_public_key() {
  if [ -n "${MACPROVIDER_CHECKSUM_PUBLIC_KEY_PEM:-}" ]; then
    printf "%s\n" "$MACPROVIDER_CHECKSUM_PUBLIC_KEY_PEM"
    return
  fi
  cat <<'EOF'
-----BEGIN PUBLIC KEY-----
MFkwEwYHKoZIzj0CAQYIKoZIzj0DAQcDQgAEwwd0Vzj35OP8DlZU+0lUa8vI9gHK
09J48LDizWScsH6rutnZLkKnGQ4X5Q8lT9L5mglF8Ba0DDoUXKrFfSAX4Q==
-----END PUBLIC KEY-----
EOF
}

verify_checksum_signature() {
  public_key_path="$TMPDIR_PATH/release-signing-public.pem"
  write_checksum_public_key > "$public_key_path"
  if grep -q "REPLACE_WITH_MACPROVIDER" "$public_key_path"; then
    die 3 "release signing public key is not configured in install.sh"
  fi
  openssl dgst -sha256 \
    -verify "$public_key_path" \
    -signature "$checksums_sig_path" \
    "$checksums_path" >/dev/null || die 4 "checksums.txt signature verification failed"
  log "checksums.txt signature verified."
}

verify_sha256() {
  expected="$(grep "  $(basename "$tarball_path")$" "$checksums_path" | awk '{print $1}' | head -1)"
  [ -n "$expected" ] || die 4 "checksums.txt has no entry for $(basename "$tarball_path")"
  actual="$(shasum -a 256 "$tarball_path" | awk '{print $1}')"
  [ "$actual" = "$expected" ] || die 4 "checksum mismatch for $(basename "$tarball_path")"
  log "SHA256 verified."
}

validate_tarball() {
  entries="$(tar tzf "$tarball_path")" || die 5 "failed to list release tarball"
  [ -n "$entries" ] || die 5 "release tarball is empty"

  has_binary=0
  while IFS= read -r entry; do
    case "$entry" in
      ""|/*|*"/../"*|../*|*/..|..)
        die 5 "unsafe tarball path: $entry"
        ;;
      macprovider-cli)
        has_binary=1
        ;;
      *.bundle|*.bundle/*)
        ;;
      *)
        die 5 "unexpected tarball member: $entry"
        ;;
    esac
  done <<EOF
$entries
EOF

  [ "$has_binary" -eq 1 ] || die 5 "release tarball does not contain macprovider-cli"
  if tar tvzf "$tarball_path" | awk '{print substr($1,1,1), $0}' | grep -E '^[lhbcp]' >/dev/null; then
    die 5 "release tarball contains unsafe link or device members"
  fi
}

write_config() {
  model="$1"
  provider_id="$2"
  coordinator_url="$3"
  run mkdir -p "$CONFIG_DIR"
  if [ "$DRY_RUN" -eq 1 ]; then
    log "Would write provider_id to $PROVIDER_ID_PATH and config to $CONFIG_PATH"
    return
  fi
  printf "%s\n" "$provider_id" > "$PROVIDER_ID_PATH"
  cat > "$CONFIG_PATH" <<EOF
model: "$(yaml_escape "$model")"
coordinator_url: "$(yaml_escape "$coordinator_url")"
provider_id: "$(yaml_escape "$provider_id")"
port: $PORT
EOF
}

install_binary() {
  run mkdir -p "$BIN_DIR" "$INSTALL_DIR"
  if [ "$DRY_RUN" -eq 1 ]; then
    log "Would install macprovider-cli to $BINARY_PATH"
    log "Would keep release support files in $INSTALL_DIR"
    return
  fi
  staging_dir="$TMPDIR_PATH/staging"
  rm -rf "$staging_dir"
  mkdir -p "$staging_dir"
  tar xzf "$tarball_path" -C "$staging_dir" || die 5 "failed to extract release tarball"

  # CRITICAL: mlx-swift loads Metal kernels from .bundle directories
  # adjacent to the binary. We install the REAL binary into $INSTALL_DIR
  # alongside the bundles, then place a symlink at $BINARY_PATH so PATH
  # users + the launchd plist still find it via the canonical
  # SPEC-003 FR-C2 location (~/.local/bin/macprovider-cli).
  # Prior v1.2.1 install separated them and Metal failed with
  # "library not found" at runtime.
  real_binary="$INSTALL_DIR/macprovider-cli"
  cp "$staging_dir/macprovider-cli" "$real_binary"
  chmod +x "$real_binary" 2>/dev/null || true

  # Bundles live alongside the real binary (where mlx-swift looks).
  find "$INSTALL_DIR" -mindepth 1 -maxdepth 1 -name '*.bundle' -exec rm -rf {} +
  find "$staging_dir" -mindepth 1 -maxdepth 1 -name '*.bundle' -exec cp -R {} "$INSTALL_DIR"/ \;

  # Atomic symlink swap at the canonical path.
  rm -f "$BINARY_PATH"
  ln -s "$real_binary" "$BINARY_PATH"

  [ -x "$real_binary" ] || die 5 "macprovider-cli was not installed at $real_binary"
  [ -L "$BINARY_PATH" ] || die 5 "symlink not created at $BINARY_PATH"
}

check_path_hint() {
  case ":$PATH:" in
    *":$BIN_DIR:"*) ;;
    *) log "$BIN_DIR is not in PATH; use $BINARY_PATH directly or add ~/.local/bin to PATH." ;;
  esac
}

clear_quarantine() {
  if ! command -v xattr >/dev/null 2>&1; then
    log "xattr not found; skipping quarantine cleanup."
    return
  fi
  log "The current release is unsigned. Clearing com.apple.quarantine lets macOS run it."
  if prompt_yes_no "Clear quarantine attribute on $BINARY_PATH and $INSTALL_DIR? [Y/n]" "Y"; then
    run xattr -dr com.apple.quarantine "$BINARY_PATH"
    run xattr -dr com.apple.quarantine "$INSTALL_DIR"
  else
    die 7 "user declined quarantine cleanup"
  fi
}

install_plist() {
  model="$1"
  provider_id="$2"
  coordinator_url="$3"
  [ "$NO_LAUNCHD" = "1" ] && { log "Skipping launchd service install."; return; }
  if ! prompt_yes_no "Install as a background service? [Y/n]" "Y"; then
    log "Skipping launchd service install."
    return
  fi

  run mkdir -p "$(dirname "$PLIST_PATH")" "$LOG_DIR"
  if [ "$DRY_RUN" -eq 1 ]; then
    log "Would render launchd plist to $PLIST_PATH"
    log "Would bootstrap with: launchctl bootstrap gui/$UID $PLIST_PATH"
    return
  fi

  render_plist "$model" "$provider_id" "$coordinator_url" > "$PLIST_PATH"

  plutil -lint "$PLIST_PATH" >/dev/null || die 5 "rendered launchd plist is invalid"
  launchctl bootout "gui/$UID" "$PLIST_PATH" >/dev/null 2>&1 || true
  launchctl bootstrap "gui/$UID" "$PLIST_PATH" || die 5 "failed to load launchd service"
  LAUNCHD_INSTALLED=1
}

render_plist() {
  model="$(xml_escape "$1")"
  provider_id="$(xml_escape "$2")"
  coordinator_url="$(xml_escape "$3")"
  user_home="$(xml_escape "$HOME")"
  binary_path="$(xml_escape "$BINARY_PATH")"
  log_dir="$(xml_escape "$LOG_DIR")"
  cat <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN"
  "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key>
  <string>live.streamvc.macprovider</string>
  <key>ProgramArguments</key>
  <array>
    <string>$binary_path</string>
    <string>--port</string>
    <string>$PORT</string>
    <string>--model</string>
    <string>$model</string>
    <string>--provider-id</string>
    <string>$provider_id</string>
    <string>--coordinator</string>
    <string>$coordinator_url</string>
  </array>
  <key>RunAtLoad</key>
  <true/>
  <key>KeepAlive</key>
  <dict>
    <key>SuccessfulExit</key>
    <false/>
  </dict>
  <key>StandardOutPath</key>
  <string>$log_dir/macprovider.out.log</string>
  <key>StandardErrorPath</key>
  <string>$log_dir/macprovider.err.log</string>
  <key>WorkingDirectory</key>
  <string>$user_home/macprovider</string>
  <key>EnvironmentVariables</key>
  <dict>
    <key>HOME</key>
    <string>$user_home</string>
    <key>PATH</key>
    <string>/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:$user_home/.local/bin</string>
  </dict>
  <key>ThrottleInterval</key>
  <integer>10</integer>
  <key>ProcessType</key>
  <string>Adaptive</string>
</dict>
</plist>
EOF
}

start_manual_service() {
  model="$1"
  provider_id="$2"
  coordinator_url="$3"
  [ "$LAUNCHD_INSTALLED" -eq 1 ] && return
  log "Starting macprovider-cli directly for non-launchd self-test."
  mkdir -p "$LOG_DIR"
  (
    cd "$INSTALL_DIR"
    nohup "$BINARY_PATH" \
      --port "$PORT" \
      --model "$model" \
      --provider-id "$provider_id" \
      --coordinator "$coordinator_url" \
      > "$LOG_DIR/macprovider.out.log" \
      2> "$LOG_DIR/macprovider.err.log" &
    echo "$!"
  ) > "$TMPDIR_PATH/manual.pid"
  MANUAL_PID="$(cat "$TMPDIR_PATH/manual.pid")"
}

wait_for_local_model() {
  model="$1"
  # First install can take several minutes if MLX has to download the model
  # (~2 GB) from Hugging Face. Cached installs still pay 30-60s for Metal
  # kernel JIT + model weight load on first run. 300s covers both cases on
  # typical residential bandwidth; we log progress every 30s so the user
  # knows the script is alive.
  start_ts="$(date +%s)"
  deadline=$(( start_ts + 300 ))
  next_progress=$(( start_ts + 30 ))
  port_seen=0
  while [ "$(date +%s)" -lt "$deadline" ]; do
    models_json="$(curl -sS --max-time 3 "http://127.0.0.1:${PORT}/v1/models" 2>/dev/null || true)"
    if [ -n "$models_json" ] && [ "$port_seen" -eq 0 ]; then
      port_seen=1
      elapsed=$(( $(date +%s) - start_ts ))
      log "Port ${PORT} is listening (after ${elapsed}s). Waiting for model load..."
    fi
    if printf "%s" "$models_json" | grep -q '"owned_by"[[:space:]]*:[[:space:]]*"macprovider"' &&
       printf "%s" "$models_json" | grep -Fq "$model"; then
      return 0
    fi
    now="$(date +%s)"
    if [ "$now" -ge "$next_progress" ]; then
      elapsed=$(( now - start_ts ))
      if [ "$port_seen" -eq 0 ]; then
        log "Still waiting for macprovider-cli to bind port ${PORT} (${elapsed}s elapsed)..."
      else
        log "Model still loading (${elapsed}s elapsed; first run may download ~2 GB from Hugging Face)..."
      fi
      next_progress=$(( now + 30 ))
    fi
    sleep 2
  done
  return 1
}

wait_for_coordinator() {
  provider_id="$1"
  coordinator_base="$2"
  deadline=$(( $(date +%s) + 30 ))
  while [ "$(date +%s)" -lt "$deadline" ]; do
    response="$(curl -fsS --max-time 5 "$coordinator_base/v1/pool/check?provider_id=$(urlencode "$provider_id")" 2>/dev/null || true)"
    if printf "%s" "$response" | grep -q '"state"[[:space:]]*:[[:space:]]*"ready"'; then
      return 0
    fi
    sleep 2
  done
  return 1
}

print_pid() {
  if [ -n "$MANUAL_PID" ]; then
    printf "%s\n" "$MANUAL_PID"
    return
  fi
  launchctl list 2>/dev/null | awk '/live.streamvc.macprovider/ {print $1; exit}'
}

main() {
  detect_platform
  for tool in curl tar shasum grep sed awk date hostname mktemp openssl find; do
    require_tool "$tool"
  done

  ram_gb="$(detect_ram_gb)"
  model="$(choose_model "$ram_gb")"
  provider_id="$(choose_provider_id)"
  coordinator_url="$(choose_coordinator_url)"
  coordinator_base="$(coordinator_http_base "$coordinator_url")"
  validate_inputs "$model" "$provider_id" "$coordinator_url"
  log "Target model: $model"
  log "Provider ID: $provider_id"
  log "Coordinator: $coordinator_url"
  log "Binary path: $BINARY_PATH"
  log "Support dir: $INSTALL_DIR"

  if [ "$DRY_RUN" -eq 1 ]; then
    log "Dry run: would query latest release for $GITHUB_REPO, download, verify, install, and self-test."
    write_config "$model" "$provider_id" "$coordinator_url"
    install_binary
    install_plist "$model" "$provider_id" "$coordinator_url"
    check_path_hint
    exit 0
  fi

  tag="$(latest_release_tag)"
  log "Latest release: $tag"
  download_release "$tag"
  verify_checksum_signature
  verify_sha256
  validate_tarball
  install_binary
  check_path_hint
  clear_quarantine
  ensure_port_free
  write_config "$model" "$provider_id" "$coordinator_url"
  install_plist "$model" "$provider_id" "$coordinator_url"
  start_manual_service "$model" "$provider_id" "$coordinator_url"

  log "Waiting up to 60s for local /v1/models."
  if ! wait_for_local_model "$model"; then
    log "Local self-test failed. Check logs: tail -f $LOG_DIR/macprovider.err.log"
    exit 6
  fi

  log "Waiting up to 30s for coordinator pool visibility."
  if ! wait_for_coordinator "$provider_id" "$coordinator_base"; then
    log "Installed locally. Coordinator connection failed; provider will join the pool when connectivity and provisional admission are available."
    log "This is AC-1a degraded mode, not AC-1 build-complete success."
    exit 6
  fi

  pid="$(print_pid || true)"
  log "Ready to serve."
  log "PID: ${pid:-unknown}"
  log "Logs: tail -f $LOG_DIR/macprovider.out.log $LOG_DIR/macprovider.err.log"
  log "Coordinator pool check: $coordinator_base/v1/pool/check?provider_id=$(urlencode "$provider_id")"
  log "Uninstall: bash <(curl -fsSL https://get.streamvc.live/uninstall.sh)"
}

main "$@"
