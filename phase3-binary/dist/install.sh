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
INSTALL_DIR="${MACPROVIDER_INSTALL_DIR:-$HOME/macprovider}"
BIN_DIR="$HOME/.local/bin"
BINARY_PATH="$BIN_DIR/macprovider-cli"
CONFIG_DIR="$HOME/.config/macprovider"
CONFIG_PATH="$CONFIG_DIR/config.yaml"
PROVIDER_ID_PATH="$CONFIG_DIR/provider_id"
PLIST_PATH="$HOME/Library/LaunchAgents/live.streamvc.macprovider.plist"
LOG_DIR="$HOME/Library/Logs/macprovider"
# Issue #191: ship the macprovider-watchdog LaunchAgent alongside
# the main provider so every operator gets the silent-disconnect
# safety net. Source lives in ops/macprovider-watchdog/; we inline
# the scripts here so the public installer remains a single curl-able
# artifact.
WATCHDOG_DIR="$HOME/.local/share/macprovider-watchdog"
WATCHDOG_PATH="$WATCHDOG_DIR/watchdog.sh"
WATCHDOG_PLIST_PATH="$HOME/Library/LaunchAgents/live.streamvc.macprovider-watchdog.plist"
WATCHDOG_LABEL="live.streamvc.macprovider-watchdog"
NO_WATCHDOG="${MACPROVIDER_NO_WATCHDOG:-0}"
DRY_RUN=0
NO_PROMPT="${MACPROVIDER_NO_PROMPT:-0}"
NO_LAUNCHD="${MACPROVIDER_NO_LAUNCHD:-0}"
TMPDIR_PATH=""
LAUNCHD_INSTALLED=0
MANUAL_PID=""
SKIP_PROVIDER_START=0

log() { printf "[macprovider-install] %s\n" "$*"; }
die() {
  code="$1"
  shift
  printf "[macprovider-install] ERROR: %s\n" "$*" >&2
  exit "$code"
}

# Retry macprovider-cli up to two additional times if the first
# post-install invocation is SIGKILL'd by the kernel with a CODESIGNING
# "Invalid Page" / "Taskgated Invalid Signature" verdict. Two failure
# flavors have been observed:
#
#   FLAVOR 1 — Transient AMFI race. Observed 2026-07-03 on Apple M5
#     macOS 26.5 with a freshly-installed v1.7.9 pkg: `autotune
#     --recommend --freshness-check` was reported "Killed: 9" (bash
#     exit 137) on the FIRST invocation right after `installer -pkg`,
#     and the immediately-repeated invocation of the SAME command by
#     the SAME shell succeeded. This is a race between the pkg
#     installer's post-install AMFI signature revalidation and our
#     first execve; the 2s sleep is sufficient to let AMFI settle.
#
#   FLAVOR 2 — AMFI cache pinned to the pkg-installer inode. Observed
#     2026-07-03 on the same M5 during the v1.7.10 install: BOTH the
#     first invocation AND the 2s-later retry were SIGKILL'd, but the
#     binary's `codesign --verify --deep --strict` passed cleanly and
#     the SAME binary content ran fine when copied to a different
#     path. The AMFI kernel cache had a stuck rejection tied to the
#     specific inode that `installer -pkg` created. The fix is to
#     `rm` the file (releasing the inode) and `cp` the binary back
#     in from a tempfile, which gives it a new inode and forces AMFI
#     to re-evaluate. See PR #339 for the reproduction and root cause.
#
# The helper's escalation ladder for bash rc 137:
#   attempt 1: run
#     └── 137 → log + sleep 2 + attempt 2 (FLAVOR 1 fix)
#         └── 137 → log + inode-refresh via cp/rm/cp + attempt 3
#             │           (FLAVOR 2 fix)
#             └── 137 → log "genuine signature failure" + return 137
# Any non-137 rc anywhere in the ladder returns immediately.
#
# Only SIGKILL / bash rc 137 is retried — other non-zero exits
# (including autotune's exit-10 "stale recommendation" signal, and
# other signal-terminated codes such as 134 SIGABRT / 138 SIGBUS /
# 139 SIGSEGV) pass through unchanged so we do not mask real crashes.
#
# This helper MUST be called from `if run_..._retry ...; then` or
# `run_..._retry ... || ...` so that `set -e` (enabled at the top of
# this script) does not fire on the pass-through non-zero return.
#
# Diagnostic lines are written to stderr so they remain visible even
# when callers redirect the helper's stdout to `/dev/null` (as the
# freshness-check call site does).
run_macprovider_cli_with_amfi_retry() {
  local rc=0
  "$INSTALL_DIR/macprovider-cli" "$@" || rc=$?
  if [ "$rc" -ne 137 ]; then
    return "$rc"
  fi
  log "macprovider-cli was SIGKILL'd on first invocation (rc=$rc); likely a transient AMFI code-signature race after pkg install. Retrying once after 2s." >&2
  sleep 2
  rc=0
  "$INSTALL_DIR/macprovider-cli" "$@" || rc=$?
  if [ "$rc" -ne 137 ]; then
    return "$rc"
  fi
  log "macprovider-cli was SIGKILL'd again on the 2s retry; the AMFI cache may be pinned to the pkg-installer inode. Refreshing the binary inode via cp/rm/cp and retrying once more." >&2
  local tmp
  tmp="$(mktemp -t macprovider-cli-inode-refresh 2>/dev/null || mktemp)"
  if [ -z "$tmp" ]; then
    log "inode refresh: mktemp failed; leaving the original binary in place." >&2
    return "$rc"
  fi
  if ! cp "$INSTALL_DIR/macprovider-cli" "$tmp" 2>/dev/null; then
    log "inode refresh: cp to $tmp failed; leaving the original binary in place." >&2
    rm -f "$tmp"
    return "$rc"
  fi
  if ! rm -f "$INSTALL_DIR/macprovider-cli"; then
    log "inode refresh: rm of $INSTALL_DIR/macprovider-cli failed; the binary is still there but the inode was not refreshed." >&2
    rm -f "$tmp"
    return "$rc"
  fi
  if ! cp "$tmp" "$INSTALL_DIR/macprovider-cli"; then
    log "inode refresh: cp-back of $tmp -> $INSTALL_DIR/macprovider-cli failed; the binary at $INSTALL_DIR/macprovider-cli is now missing. Restore from $tmp: cp \"$tmp\" \"$INSTALL_DIR/macprovider-cli\" && chmod +x \"$INSTALL_DIR/macprovider-cli\"." >&2
    return "$rc"
  fi
  if ! chmod +x "$INSTALL_DIR/macprovider-cli"; then
    log "inode refresh: chmod +x on $INSTALL_DIR/macprovider-cli failed; the binary is present but may not be executable. Run: chmod +x \"$INSTALL_DIR/macprovider-cli\"." >&2
    return "$rc"
  fi
  rm -f "$tmp"
  rc=0
  "$INSTALL_DIR/macprovider-cli" "$@" || rc=$?
  if [ "$rc" -eq 137 ]; then
    log "macprovider-cli was SIGKILL'd after the inode refresh; this is likely a genuine signature failure rather than the AMFI cache." >&2
  fi
  return "$rc"
}

detect_existing_port() {
  if [ -f "$CONFIG_PATH" ]; then
    awk -F: '/^port:/ {gsub(/ /, "", $2); print $2; exit}' "$CONFIG_PATH" 2>/dev/null
  fi
}

# F-603-V7-1: upgrade-in-place must preserve the prior configured port
# unless the operator explicitly overrides it. Otherwise existing installs
# on 18080 regress to the default 8080 and collide with unrelated services.
if [ -n "${MACPROVIDER_PORT:-}" ]; then
  PORT="$MACPROVIDER_PORT"
elif EXISTING_PORT="$(detect_existing_port)" && [ -n "$EXISTING_PORT" ]; then
  PORT="$EXISTING_PORT"
  log "Detected existing config port: $PORT (override with MACPROVIDER_PORT=N)"
else
  PORT="8080"
fi

usage() {
  cat <<'USAGE'
Usage: bash install.sh [--dry-run]

Environment overrides:
  MACPROVIDER_GITHUB_REPO        owner/repo for GitHub Releases
  MACPROVIDER_MODEL              model id to install
  MACPROVIDER_COORDINATOR_URL    coordinator WebSocket URL
  MACPROVIDER_PORT               local HTTP port
  MACPROVIDER_INSTALL_DIR        support dir for binary + bundles
  MACPROVIDER_RELEASE_FORMAT     auto, pkg, or tar (default: auto)
  MACPROVIDER_NO_PROMPT=1        use defaults without interactive prompts
  MACPROVIDER_NO_LAUNCHD=1       expert/debug only: skip BOTH the provider
                                 launchd service and its companion watchdog
  MACPROVIDER_NO_WATCHDOG=1      expert/debug only: install the provider
                                 launchd service but skip the watchdog
  MACPROVIDER_SKIP_HF_CHECK=1    skip HuggingFace lookup on custom model id
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
# proceeds, launchd loads, the binary crashes on bind, and the timeout
# path hides the real cause. Surface the collision early with a clear fix.
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

  # F-603-V7-2: an existing macprovider-cli on this port is the normal
  # upgrade-in-place case. Stop that service and continue; only foreign
  # holders should block the install.
  if pgrep -lf 'macprovider-cli.*--port' 2>/dev/null | awk -v pids="$holding_pids" '
    BEGIN { n = split(pids, pid_list, "\n"); for (i = 1; i <= n; i++) wanted[pid_list[i]] = 1 }
    wanted[$1] { found = 1 }
    END { exit found ? 0 : 1 }
  '; then
    log "Existing macprovider-cli holding port $PORT; stopping it for upgrade-in-place."
    launchctl bootout "gui/$UID" "$PLIST_PATH" 2>/dev/null || true
    sleep 2
    if lsof -nP -iTCP:"$PORT" -sTCP:LISTEN -t 2>/dev/null | grep -q .; then
      log "Port $PORT still held after launchctl bootout; trying pkill of own-service PID."
      kill -TERM $holding_pids 2>/dev/null || true
      sleep 2
    fi
    if lsof -nP -iTCP:"$PORT" -sTCP:LISTEN -t 2>/dev/null | grep -q .; then
      die 6 "could not stop existing macprovider-cli on port $PORT; please stop manually and retry"
    fi
    log "Port $PORT freed; proceeding with upgrade."
    return
  fi

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
  elif [ "$ram_gb" -lt 16 ]; then
    printf "mlx-community/Qwen3-4B-Instruct-2507-4bit"
  elif [ "$ram_gb" -lt 24 ]; then
    printf "mlx-community/Qwen2.5-7B-Instruct-4bit"
  elif [ "$ram_gb" -lt 32 ]; then
    printf "mlx-community/Qwen2.5-14B-Instruct-4bit"
  elif [ "$ram_gb" -lt 48 ]; then
    printf "mlx-community/Qwen3-32B-4bit"
  elif [ "$ram_gb" -lt 64 ]; then
    printf "mlx-community/Llama-3.3-70B-Instruct-4bit"
  else
    printf "mlx-community/Qwen3-Next-80B-A3B-Instruct-4bit"
  fi
}

known_min_ram_gb_for_model() {
  case "$1" in
    mlx-community/Llama-3.2-3B-Instruct-4bit) printf "8" ;;
    mlx-community/Qwen3-4B-Instruct-2507-4bit) printf "12" ;;
    mlx-community/Qwen2.5-7B-Instruct-4bit) printf "16" ;;
    mlx-community/DeepSeek-R1-0528-Qwen3-8B-4bit) printf "16" ;;
    mlx-community/Qwen2.5-14B-Instruct-4bit) printf "24" ;;
    mlx-community/Qwen3-32B-4bit) printf "32" ;;
    mlx-community/Qwen2.5-Coder-32B-Instruct-4bit) printf "32" ;;
    mlx-community/Llama-3.3-70B-Instruct-4bit) printf "48" ;;
    mlx-community/Qwen3-Next-80B-A3B-Instruct-4bit) printf "64" ;;
  esac
}

known_weight_gb_for_model() {
  case "$1" in
    mlx-community/Llama-3.2-3B-Instruct-4bit) printf "2" ;;
    mlx-community/Qwen3-4B-Instruct-2507-4bit) printf "2" ;;
    mlx-community/Qwen2.5-7B-Instruct-4bit) printf "4" ;;
    mlx-community/DeepSeek-R1-0528-Qwen3-8B-4bit) printf "4" ;;
    mlx-community/Qwen2.5-14B-Instruct-4bit) printf "8" ;;
    mlx-community/Qwen3-32B-4bit) printf "18" ;;
    mlx-community/Qwen2.5-Coder-32B-Instruct-4bit) printf "17" ;;
    mlx-community/Llama-3.3-70B-Instruct-4bit) printf "35" ;;
    mlx-community/Qwen3-Next-80B-A3B-Instruct-4bit) printf "40" ;;
  esac
}

# SPEC-003 v0.9 FR-D2: enforce safe HuggingFace repo id format.
# Path-component charset (A-Za-z0-9._-) plus a single "/" separator. Any
# deviation from "org/name" is rejected — this id is interpolated into a URL
# and a YAML field, so traversal/newlines/whitespace must not slip through.
validate_hf_id() {
  id="$1"
  reject_newlines "model id" "$id"
  case "$id" in
    */*/*|*/) die 7 "model id must be in the form org/name (got: $id)" ;;
    */*) ;;
    *) die 7 "model id must be in the form org/name (got: $id)" ;;
  esac
  case "$id" in
    *[!A-Za-z0-9._/-]*) die 7 "model id contains invalid characters; allowed: A-Z a-z 0-9 . _ - /" ;;
  esac
  case "$id" in
    /*|*/) die 7 "model id must be in the form org/name (got: $id)" ;;
  esac
  # Round-2 hardening (codex code/security MAJOR): reject "." / ".." path
  # components even though the charset filter allows them. Otherwise an id
  # like "org/.." or "../name" passes the format check and could be
  # path-normalized into the HF URL or later treated as a relative local
  # model path by the binary.
  hf_org="${id%/*}"
  hf_name="${id##*/}"
  case "$hf_org" in
    .|..) die 7 "model id org segment cannot be \".\" or \"..\"" ;;
  esac
  case "$hf_name" in
    .|..) die 7 "model id name segment cannot be \".\" or \"..\"" ;;
  esac
}

# SPEC-003 v0.9 FR-D2: estimate weight size in GB from HF repo name.
# Parses N params from "...3B...", "...7B...", "...1.7B..." patterns and a
# quantization hint (4bit/8bit/bf16/fp16/q4/q8). Returns an integer GB to
# stdout or empty if the name can't be parsed — callers treat empty as
# "skip fit check, warn user".
estimate_weights_gb_from_name() {
  id="$1"
  # Round-2 (codex code MAJOR): match "NxMB" Mixture-of-Experts shape FIRST
  # (e.g. "Mixtral-8x7B" — 8 experts of 7B each, total ~56B params). The
  # single-N pattern below would otherwise capture only the "7B" half and
  # under-count memory by ~N×, letting the fit check pass a model that
  # would OOM the host.
  moe_match="$(printf "%s" "$id" | grep -oE '[0-9]+x[0-9]+(\.[0-9]+)?[Bb]' | head -n1)"
  if [ -n "$moe_match" ]; then
    experts="${moe_match%%x*}"
    per_rest="${moe_match#*x}"
    per_b="${per_rest%[Bb]}"
    params_b="$(awk -v e="$experts" -v p="$per_b" 'BEGIN { printf "%g", e * p }')"
  else
    params_b="$(printf "%s" "$id" | grep -oE '[0-9]+(\.[0-9]+)?[Bb]' | head -n1 | tr -d 'Bb')"
  fi
  [ -n "$params_b" ] || return 0
  quant_lc="$(printf "%s" "$id" | tr '[:upper:]' '[:lower:]')"
  case "$quant_lc" in
    *4bit*|*-q4*|*_q4*) bytes_per_param=0.5 ;;
    *8bit*|*-q8*|*_q8*) bytes_per_param=1.0 ;;
    *bf16*|*fp16*|*-f16*) bytes_per_param=2.0 ;;
    *) bytes_per_param=2.0 ;;
  esac
  awk -v p="$params_b" -v b="$bytes_per_param" \
    'BEGIN { gb = p * b; if (gb < 1) gb = 1; printf "%d", gb + 0.5 }'
}

hf_safetensors_gb_from_api_body() {
  body="$1"
  printf "%s" "$body" | tr '\n\r' '  ' | awk '
    {
      data = $0
      while (match(data, /"rfilename"[[:space:]]*:[[:space:]]*"[^"]*\.safetensors"/)) {
        data = substr(data, RSTART + RLENGTH)
        window = substr(data, 1, 700)
        if (match(window, /"size"[[:space:]]*:[[:space:]]*[0-9]+/)) {
          value = substr(window, RSTART, RLENGTH)
          gsub(/[^0-9]/, "", value)
          total += value + 0
        }
      }
    }
    END {
      if (total > 0) {
        printf "%d", int((total + 1073741824 - 1) / 1073741824)
      }
    }
  '
}

ram_floor_for_weight_gb() {
  weight_gb="$1"
  awk -v w="$weight_gb" '
    BEGIN {
      if (w <= 2) print 8;
      else if (w <= 3) print 12;
      else if (w <= 5) print 16;
      else if (w <= 9) print 24;
      else if (w <= 20) print 32;
      else if (w <= 38) print 48;
      else print 64;
    }
  '
}

confirm_model_fit_override() {
  reason="$1"
  if [ "$NO_PROMPT" = "1" ]; then
    die 7 "$reason; refusing non-interactive install"
  fi
  log "WARNING: $reason"
  prompt_yes_no "Proceed anyway? [y/N]" "N" || die 7 "aborted by user"
}

enforce_model_min_ram_floor() {
  id="$1"
  ram_gb="$2"
  min_ram_gb="$3"
  source="$4"
  if [ "$ram_gb" -lt "$min_ram_gb" ]; then
    confirm_model_fit_override "$source requires ${min_ram_gb} GB RAM for $id, but this Mac has ${ram_gb} GB"
  else
    log "Model fits: $id requires ${min_ram_gb} GB RAM by $source; this Mac has ${ram_gb} GB."
  fi
}

enforce_model_ram_fit_from_weight_gb() {
  id="$1"
  ram_gb="$2"
  weight_gb="$3"
  source="$4"
  min_ram_gb="$(ram_floor_for_weight_gb "$weight_gb")"
  if [ "$ram_gb" -lt "$min_ram_gb" ]; then
    confirm_model_fit_override "$source reports ~${weight_gb} GB safetensors; recommended RAM floor is ${min_ram_gb} GB for $id, but this Mac has ${ram_gb} GB"
  else
    log "Model fits: $source reports ~${weight_gb} GB safetensors; recommended RAM floor is ${min_ram_gb} GB and this Mac has ${ram_gb} GB."
  fi
}

enforce_model_ram_fit() {
  id="$1"
  ram_gb="$2"
  min_ram_gb="$(known_min_ram_gb_for_model "$id")"
  if [ -n "$min_ram_gb" ]; then
    enforce_model_min_ram_floor "$id" "$ram_gb" "$min_ram_gb" "model table"
    return 0
  fi

  est_gb="$(estimate_weights_gb_from_name "$id")"
  if [ -z "$est_gb" ]; then
    log "WARNING: could not estimate weight size from model name; skipping fit check."
    return 0
  fi
  # Headroom: ~6 GB for macOS (3-4 GB) + Metal + mlx runtime + binary +
  # KV cache. This matches the existing RAM-tier policy where the 7B (~4 GB)
  # default targets 16 GB Macs, not 8 GB Macs.
  comfortable_gb=$((est_gb + 6))
  if [ "$ram_gb" -ge "$comfortable_gb" ]; then
    log "Model fits: ~${est_gb} GB weights on ${ram_gb} GB Mac (working set ~${comfortable_gb} GB)."
    return 0
  fi
  if [ "$ram_gb" -ge "$((est_gb + 2))" ]; then
    confirm_model_fit_override "tight fit — ~${est_gb} GB weights on ${ram_gb} GB Mac; may swap or OOM under load"
    return 0
  fi
  confirm_model_fit_override "~${est_gb} GB weights will not fit on ${ram_gb} GB Mac"
}

catalog_min_ram_from_body() {
  catalog_body="$1"
  model_id="$2"
  printf "%s" "$catalog_body" | tr '\n\r' '  ' | awk -v id="$model_id" '
    BEGIN { RS = "}"; }
    index($0, "\"model_id\"") && index($0, "\"" id "\"") {
      if (match($0, /"min_ram_gb"[[:space:]]*:[[:space:]]*[1-9][0-9]*/)) {
        value = substr($0, RSTART, RLENGTH)
        gsub(/[^0-9]/, "", value)
        print value
      }
      exit
    }
  '
}

check_catalog_ram_metadata() {
  coordinator_base="$1"
  model_id="$2"
  ram_gb="$3"
  if [ "${MACPROVIDER_SKIP_CATALOG_CHECK:-0}" = "1" ]; then
    return 1
  fi
  if ! command -v curl >/dev/null 2>&1; then
    log "WARNING: curl not found; using built-in model RAM estimates."
    return 1
  fi

  catalog_url="$coordinator_base/catalog/current"
  body_and_code="$(curl -sSL -m 5 -o - -w '\n__HTTP_STATUS__%{http_code}' "$catalog_url" 2>/dev/null || printf '\n__HTTP_STATUS__network_error')"
  http_code="${body_and_code##*__HTTP_STATUS__}"
  catalog_body="${body_and_code%__HTTP_STATUS__*}"
  if [ "$http_code" != "200" ]; then
    log "WARNING: could not read signed catalog $catalog_url (status $http_code); using built-in model RAM estimates."
    return 1
  fi

  catalog_id="$(printf "%s" "$catalog_body" | sed -n 's/.*"catalog_id"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' | head -1)"
  if [ -z "$catalog_id" ]; then
    log "WARNING: signed catalog did not include catalog_id; using built-in model RAM estimates."
    return 1
  fi

  min_ram_gb="$(catalog_min_ram_from_body "$catalog_body" "$model_id")"
  if [ -n "$min_ram_gb" ]; then
    if [ "$ram_gb" -lt "$min_ram_gb" ]; then
      confirm_model_fit_override "catalog $catalog_id requires ${min_ram_gb} GB RAM for $model_id, but this Mac has ${ram_gb} GB"
    else
      log "Catalog fit: $model_id requires ${min_ram_gb} GB RAM; this Mac has ${ram_gb} GB."
    fi
    return 0
  fi
  log "WARNING: catalog $catalog_id has no min_ram_gb metadata; using built-in model RAM estimates."
  return 1
}

# SPEC-003 v0.9 FR-D2: pre-install validation of a user-supplied HuggingFace
# model id. Hard-blocks on inaccessible (401/403/404 — HF returns 401 for both
# gated and nonexistent repos) and on non-MLX repos. Warns and prompts on
# tight/over-RAM fit; user may override. Network errors downgrade to a
# "skipped" warning so a flaky HF doesn't brick installs, but the local
# name-based RAM-fit guard still runs. All output goes to stderr — caller's
# stdout is reserved for the chosen id.
hf_check_model() {
  id="$1"
  ram_gb="$2"
  if [ "$DRY_RUN" -eq 1 ]; then
    log "Dry run: would check model $id on HuggingFace."
    enforce_model_ram_fit "$id" "$ram_gb"
    return 0
  fi
  if [ "${MACPROVIDER_SKIP_HF_CHECK:-0}" = "1" ]; then
    log "Skipping HuggingFace check (MACPROVIDER_SKIP_HF_CHECK=1)."
    enforce_model_ram_fit "$id" "$ram_gb"
    return 0
  fi
  if ! command -v curl >/dev/null 2>&1; then
    log "curl not found; skipping HuggingFace check."
    enforce_model_ram_fit "$id" "$ram_gb"
    return 0
  fi
  log "Checking model $id on HuggingFace…"
  api_url="https://huggingface.co/api/models/$id?blobs=true"
  # -f omitted so 4xx bodies still reach us; status is routed explicitly below.
  body_and_code="$(curl -sSL -m 10 -o - -w '\n__HTTP_STATUS__%{http_code}' "$api_url" 2>/dev/null || printf '\n__HTTP_STATUS__network_error')"
  http_code="${body_and_code##*__HTTP_STATUS__}"
  body="${body_and_code%__HTTP_STATUS__*}"
  case "$http_code" in
    200) ;;
    401|403|404)
      die 7 "model $id is not accessible on HuggingFace (private, gated, or doesn't exist). For a gated repo, use 'macprovider-cli models switch' post-install with HF_TOKEN set."
      ;;
    network_error)
      log "WARNING: could not reach HuggingFace API; using local RAM-fit estimate only."
      enforce_model_ram_fit "$id" "$ram_gb"
      return 0
      ;;
    *)
      log "WARNING: unexpected HuggingFace API status $http_code; using local RAM-fit estimate only."
      enforce_model_ram_fit "$id" "$ram_gb"
      return 0
      ;;
  esac

  # MLX detection: mlx-community/* repos are mlx by convention, plus any repo
  # that declares mlx as library_name or carries an "mlx" tag.
  is_mlx=0
  case "$id" in
    mlx-community/*) is_mlx=1 ;;
  esac
  if [ "$is_mlx" -eq 0 ]; then
    # Round-2 (codex code MINOR): flatten the body to one line before the
    # tags regex. HF currently returns minified JSON, but a future format
    # change to pretty-printed bodies would defeat the bracketed-class
    # match because grep -E reads line-by-line.
    flat_body="$(printf "%s" "$body" | tr -d '\n\r')"
    if printf "%s" "$flat_body" | grep -qE '"library_name"[[:space:]]*:[[:space:]]*"mlx"|"tags"[[:space:]]*:[[:space:]]*\[[^]]*"mlx"'; then
      is_mlx=1
    fi
  fi
  if [ "$is_mlx" -eq 0 ]; then
    die 7 "model $id is not an MLX repo. macprovider runs MLX-format models only. Pick an mlx-community/* variant or convert with mlx_lm.convert."
  fi

  hf_weight_gb="$(hf_safetensors_gb_from_api_body "$body")"
  if [ -n "$hf_weight_gb" ]; then
    enforce_model_ram_fit_from_weight_gb "$id" "$ram_gb" "$hf_weight_gb" "HuggingFace"
  else
    enforce_model_ram_fit "$id" "$ram_gb"
  fi
}

choose_model() {
  ram_gb="$1"
  if [ -n "${MACPROVIDER_MODEL:-}" ]; then
    # Env-var override is an explicit power-user path, but it must still pass
    # the local RAM-fit guard. Keep the previous reachability behavior for
    # private/gated repos; NO_PROMPT oversized models fail loud with exit 7
    # instead of silently downloading multi-GB weights that cannot fit.
    validate_hf_id "$MACPROVIDER_MODEL"
    enforce_model_ram_fit "$MACPROVIDER_MODEL" "$ram_gb" >&2
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
  printf "  2) mlx-community/Qwen3-4B-Instruct-2507-4bit     ~2 GB, 12 GB+ Macs\n" >&2
  printf "  3) mlx-community/Qwen2.5-7B-Instruct-4bit        ~4 GB, 16 GB Macs\n" >&2
  printf "  4) mlx-community/DeepSeek-R1-0528-Qwen3-8B-4bit  ~4 GB, 16 GB+ Macs\n" >&2
  printf "  5) mlx-community/Qwen2.5-14B-Instruct-4bit       ~8 GB, 24 GB+ Macs\n" >&2
  printf "  6) mlx-community/Qwen3-32B-4bit                  ~18 GB, 32 GB+ Macs\n" >&2
  printf "  7) mlx-community/Qwen2.5-Coder-32B-Instruct-4bit ~17 GB, 32 GB+ Macs\n" >&2
  printf "  8) mlx-community/Llama-3.3-70B-Instruct-4bit     ~35 GB, 48 GB+ Macs\n" >&2
  printf "  9) mlx-community/Qwen3-Next-80B-A3B-Instruct-4bit ~40 GB, 64 GB+ Macs\n" >&2
  printf "  c) custom HuggingFace MLX model id\n" >&2
  printf "Selection [default: %s]: " "$default_model" >&2
  read_line
  selection="$REPLY"
  case "$selection" in
    1) printf "mlx-community/Llama-3.2-3B-Instruct-4bit" ;;
    2) printf "mlx-community/Qwen3-4B-Instruct-2507-4bit" ;;
    3) printf "mlx-community/Qwen2.5-7B-Instruct-4bit" ;;
    4) printf "mlx-community/DeepSeek-R1-0528-Qwen3-8B-4bit" ;;
    5) printf "mlx-community/Qwen2.5-14B-Instruct-4bit" ;;
    6) printf "mlx-community/Qwen3-32B-4bit" ;;
    7) printf "mlx-community/Qwen2.5-Coder-32B-Instruct-4bit" ;;
    8) printf "mlx-community/Llama-3.3-70B-Instruct-4bit" ;;
    9) printf "mlx-community/Qwen3-Next-80B-A3B-Instruct-4bit" ;;
    c|C)
      printf "HuggingFace model id (org/name): " >&2
      read_line
      custom_id="$REPLY"
      [ -n "$custom_id" ] || die 7 "custom model id cannot be empty"
      validate_hf_id "$custom_id"
      hf_check_model "$custom_id" "$ram_gb" >&2
      printf "%s" "$custom_id"
      ;;
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
  # Scan the recent release list and pick the newest tag that names a
  # macprovider-cli release (tag matches ^v[0-9], e.g. v1.3.1). The
  # /releases/latest endpoint can't be trusted on its own: it returns
  # whichever release is flagged "Latest" repo-wide, so any unrelated
  # release published under the same repo (e.g. macprovider-verify
  # under tag verify-vX.Y.Z) silently hijacks the installer.
  api_url="https://api.github.com/repos/${GITHUB_REPO}/releases?per_page=30"
  json="$(curl -fsSL "$api_url")" || die 3 "failed to query GitHub Releases API: $api_url"
  tag="$(printf "%s" "$json" \
    | sed -n 's/.*"tag_name"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' \
    | grep -E '^v[0-9]' \
    | head -1)"
  [ -n "$tag" ] || die 3 "no macprovider-cli release (tag ^v[0-9]) found in recent GitHub Releases"
  printf "%s" "$tag"
}

download_release() {
  tag="$1"
  tarball_asset="macprovider-cli-${tag}-darwin-arm64.tar.gz"
  pkg_asset="macprovider-cli-${tag}-darwin-arm64.pkg"
  base="https://github.com/${GITHUB_REPO}/releases/download/${tag}"
  TMPDIR_PATH="$(mktemp -d)"
  tarball_path="$TMPDIR_PATH/$tarball_asset"
  pkg_path="$TMPDIR_PATH/$pkg_asset"
  checksums_path="$TMPDIR_PATH/checksums.txt"
  checksums_sig_path="$TMPDIR_PATH/checksums.txt.sig"
  asset_path=""
  asset_kind=""

  curl -fL "$base/checksums.txt" -o "$checksums_path" || die 3 "failed to download checksums.txt"
  curl -fL "$base/checksums.txt.sig" -o "$checksums_sig_path" || die 3 "failed to download checksums.txt.sig"
  verify_checksum_signature

  release_format="${MACPROVIDER_RELEASE_FORMAT:-auto}"
  case "$release_format" in
    auto|pkg|tar) ;;
    *) die 7 "MACPROVIDER_RELEASE_FORMAT must be auto, pkg, or tar" ;;
  esac

  if [ "$release_format" != "tar" ]; then
    pkg_expected="$(checksum_for_asset "$pkg_asset")"
    if [ -n "$pkg_expected" ]; then
      log "Downloading signed package $pkg_asset from GitHub Releases."
      curl -fL "$base/$pkg_asset" -o "$pkg_path" || die 3 "failed to download release package"
      asset_path="$pkg_path"
      asset_kind="pkg"
      log "Using signed package release asset: $pkg_asset"
      return
    fi
    [ "$release_format" = "auto" ] || die 3 "checksums.txt has no entry for $pkg_asset"
    log "Signed release manifest has no package for $tag; falling back to tarball."
  fi

  log "Downloading $tarball_asset from GitHub Releases."
  curl -fL "$base/$tarball_asset" -o "$tarball_path" || die 3 "failed to download release tarball"
  asset_path="$tarball_path"
  asset_kind="tar"
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

checksum_for_asset() {
  asset_name="$1"
  awk -v asset="$asset_name" '$2 == asset { print $1; exit }' "$checksums_path"
}

verify_sha256() {
  asset_name="$(basename "$asset_path")"
  expected="$(checksum_for_asset "$asset_name")"
  [ -n "$expected" ] || die 4 "checksums.txt has no entry for $asset_name"
  actual="$(shasum -a 256 "$asset_path" | awk '{print $1}')"
  [ "$actual" = "$expected" ] || die 4 "checksum mismatch for $asset_name"
  log "SHA256 verified."
}

validate_tarball() {
  entries="$(tar tzf "$asset_path")" || die 5 "failed to list release tarball"
  [ -n "$entries" ] || die 5 "release tarball is empty"

  validate_staged_entries "$entries" "tarball"
  if tar tvzf "$asset_path" | awk '{print substr($1,1,1), $0}' | grep -E '^[lhbcp]' >/dev/null; then
    die 5 "release tarball contains unsafe link or device members"
  fi
}

validate_staged_entries() {
  entries="$1"
  label="$2"
  has_binary=0
  while IFS= read -r entry; do
    normalized_entry="$entry"
    while :; do
      case "$normalized_entry" in
        ./*) normalized_entry="${normalized_entry#./}" ;;
        *) break ;;
      esac
    done
    case "$normalized_entry" in
      ""|.) continue ;;
    esac
    case "$normalized_entry" in
      /*|*"/../"*|../*|*/..|..)
        die 5 "unsafe tarball path: $entry"
        ;;
      macprovider-cli)
        has_binary=1
        ;;
      THIRD-PARTY-NOTICES.txt)
        ;;
      *.bundle|*.bundle/*)
        ;;
      *)
        die 5 "unexpected $label member: $entry"
        ;;
    esac
  done <<EOF
$entries
EOF

  [ "$has_binary" -eq 1 ] || die 5 "$label does not contain macprovider-cli"
}

validate_package() {
  require_tool pkgutil
  if command -v spctl >/dev/null 2>&1; then
    spctl -a -vv -t install "$asset_path" || die 4 "package failed Gatekeeper assessment"
    log "Package Gatekeeper assessment passed."
  else
    log "spctl not found; package checksum was verified but Gatekeeper assessment was skipped."
  fi
  if command -v xcrun >/dev/null 2>&1 && xcrun --find stapler >/dev/null 2>&1; then
    xcrun stapler validate "$asset_path" || die 4 "package stapler validation failed"
    log "Package stapler validation passed."
  else
    log "stapler not found; local package stapler validation skipped."
  fi
}

validate_release_payload() {
  case "$asset_kind" in
    tar) validate_tarball ;;
    pkg) validate_package ;;
    *) die 5 "release asset was not selected" ;;
  esac
}

stage_release_payload() {
  staging_dir="$TMPDIR_PATH/staging"
  rm -rf "$staging_dir"
  mkdir -p "$staging_dir"

  case "$asset_kind" in
    tar)
      tar xzf "$asset_path" -C "$staging_dir" || die 5 "failed to extract release tarball"
      ;;
    pkg)
      expanded_dir="$TMPDIR_PATH/pkg-expanded"
      rm -rf "$expanded_dir"
      pkgutil --expand-full "$asset_path" "$expanded_dir" || die 5 "failed to expand release package"
      [ -d "$expanded_dir/Payload" ] || die 5 "expanded package does not contain Payload"
      payload_entries="$(cd "$expanded_dir/Payload" && find . -mindepth 1 -print)" \
        || die 5 "failed to list expanded package payload"
      validate_staged_entries "$payload_entries" "package payload"
      if find "$expanded_dir/Payload" \( -type l -o -type b -o -type c -o -type p \) -print -quit | grep -q .; then
        die 5 "package payload contains unsafe link or device members"
      fi
      cp -R "$expanded_dir/Payload/." "$staging_dir"/
      ;;
    *)
      die 5 "release asset was not selected"
      ;;
  esac
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
  chmod 600 "$CONFIG_PATH" "$PROVIDER_ID_PATH" 2>/dev/null || true
}

read_config_model() {
  [ -f "$CONFIG_PATH" ] || return 1
  awk -F: '
    /^model:/ {
      value=$0
      sub(/^model:[[:space:]]*/, "", value)
      gsub(/^"|"$/, "", value)
      print value
      exit
    }
  ' "$CONFIG_PATH"
}

read_config_artifact_sha() {
  [ -f "$CONFIG_PATH" ] || return 1
  awk -F: '
    /^model_artifact_sha256:/ {
      value=$0
      sub(/^model_artifact_sha256:[[:space:]]*/, "", value)
      gsub(/^"|"$/, "", value)
      print value
      exit
    }
  ' "$CONFIG_PATH"
}

read_config_artifact_path() {
  [ -f "$CONFIG_PATH" ] || return 1
  awk -F: '
    /^model_artifact_path:/ {
      value=$0
      sub(/^model_artifact_path:[[:space:]]*/, "", value)
      gsub(/^"|"$/, "", value)
      print value
      exit
    }
  ' "$CONFIG_PATH"
}

read_config_donor_mode() {
  [ -f "$CONFIG_PATH" ] || return 1
  awk -F: '
    /^donor_mode:/ {
      value=$0
      sub(/^donor_mode:[[:space:]]*/, "", value)
      gsub(/^"|"$/, "", value)
      print value
      exit
    }
  ' "$CONFIG_PATH"
}

run_autotune_recommend_apply() {
  if [ "$DRY_RUN" -eq 1 ]; then
    log "Would run paid-yield recommendation before service start."
    return 0
  fi
  if [ ! -x "$INSTALL_DIR/macprovider-cli" ]; then
    die 5 "installed macprovider-cli missing before autotune recommendation"
  fi
  log "Running paid-yield recommendation before service start."
  if run_macprovider_cli_with_amfi_retry autotune --recommend --apply --config "$CONFIG_PATH"; then
    recommended_model="$(read_config_model || true)"
    artifact_path="$(read_config_artifact_path || true)"
    artifact_sha="$(read_config_artifact_sha || true)"
    if [ -n "$recommended_model" ] && [ -n "$artifact_path" ] && [ -n "$artifact_sha" ]; then
      case "$artifact_path" in
        /*)
          if prompt_yes_no "Start provider with $recommended_model? [Y/n]" "Y"; then
            model="$recommended_model"
            log "Recommendation selected verified model: $model (artifact: $artifact_path)"
            return 0
          fi
          SKIP_PROVIDER_START=1
          log "Provider start declined. macprovider-cli is installed, but the provider service will not be started."
          return 0
          ;;
      esac
    fi
    log "No paid model currently clears the minimum net-yield threshold on this Mac."
    if prompt_yes_no "Enable donor mode? [y/N]" "N"; then
      log "Applying donor-mode configuration."
      run_macprovider_cli_with_amfi_retry autotune --recommend --apply --donor-mode --config "$CONFIG_PATH" \
        || die 6 "donor-mode recommendation failed before service start"
      recommended_model="$(read_config_model || true)"
      artifact_path="$(read_config_artifact_path || true)"
      artifact_sha="$(read_config_artifact_sha || true)"
      if [ -n "$recommended_model" ] && [ -n "$artifact_path" ] && [ -n "$artifact_sha" ]; then
        case "$artifact_path" in
          /*)
            model="$recommended_model"
            log "Donor mode selected verified model: $model (artifact: $artifact_path)"
            SKIP_PROVIDER_START=1
            log "Donor-mode configuration applied. Provider service will not be started automatically."
            return 0
            ;;
        esac
      fi
      die 6 "donor mode did not apply a verified local model artifact before service start"
    fi
    SKIP_PROVIDER_START=1
    log "Donor mode declined. macprovider-cli is installed, but the provider service will not be started."
    return 0
  fi
  die 6 "autotune recommendation failed before service start"
}

use_fresh_recommendation_if_available() {
  if [ "$DRY_RUN" -eq 1 ]; then
    return 1
  fi
  if [ ! -x "$INSTALL_DIR/macprovider-cli" ] || [ ! -f "$CONFIG_PATH" ]; then
    return 1
  fi

  if run_macprovider_cli_with_amfi_retry autotune --recommend --freshness-check --config "$CONFIG_PATH" >/dev/null; then
    recommended_model="$(read_config_model || true)"
    artifact_path="$(read_config_artifact_path || true)"
    artifact_sha="$(read_config_artifact_sha || true)"
    donor_mode="$(read_config_donor_mode || true)"
    if [ "$donor_mode" = "true" ]; then
      SKIP_PROVIDER_START=1
      log "Stored donor-mode recommendation is fresh; provider service will not be started automatically."
      return 0
    fi
    if [ -n "$recommended_model" ] && [ -n "$artifact_path" ] && [ -n "$artifact_sha" ]; then
      case "$artifact_path" in
        /*)
          model="$recommended_model"
          log "Stored paid-yield recommendation is fresh; skipping re-tune."
          log "Using verified model from existing config: $model (artifact: $artifact_path)"
          return 0
          ;;
      esac
    fi
    log "Stored recommendation is fresh but config lacks a verified local model; re-running recommendation."
    return 1
  else
    rc=$?
    if [ "$rc" -eq 10 ]; then
      log "Stored recommendation is stale or missing; running recommendation."
      return 1
    fi
    die 6 "recommendation freshness check failed before service start"
  fi
}

install_binary() {
  run mkdir -p "$BIN_DIR" "$INSTALL_DIR"
  if [ "$DRY_RUN" -eq 1 ]; then
    log "Would install macprovider-cli to $BINARY_PATH"
    log "Would keep release support files in $INSTALL_DIR"
    return
  fi
  stage_release_payload

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

check_install_dir_clean() {
  if [ ! -d "$INSTALL_DIR" ]; then
    return 0
  fi
  local entries
  # F-603-V7-7: warn on mixed-state directories such as leftover Python
  # virtualenvs, but do not block an otherwise valid partner upgrade.
  entries=$(ls -A "$INSTALL_DIR" 2>/dev/null | grep -vE '^(macprovider-cli(\.v[0-9.]+\.bak)?|.*\.bundle)$' | head -20 || true)
  if [ -n "$entries" ]; then
    log "WARNING: $INSTALL_DIR contains non-macprovider entries:"
    while IFS= read -r entry; do
      log "  - $entry"
    done <<EOF
$entries
EOF
    log "These will not be modified by install.sh, but you may want"
    log "to clean up the directory after the upgrade. Continuing..."
  fi
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
  if [ "${asset_kind:-}" = "pkg" ]; then
    log "Package release passed Gatekeeper assessment; quarantine cleanup is not required."
    return
  fi
  log "Tarball release may carry a quarantine attribute. Clearing it lets macOS run the CLI."
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
  if [ "$NO_LAUNCHD" = "1" ]; then
    log "Skipping launchd service install (MACPROVIDER_NO_LAUNCHD=1 expert/debug override)."
    return
  fi
  log "Installing as a background launchd service."

  run mkdir -p "$(dirname "$PLIST_PATH")" "$LOG_DIR"
  if [ "$DRY_RUN" -eq 1 ]; then
    log "Would render launchd plist to $PLIST_PATH"
    log "Would enable launchd service: launchctl enable gui/$UID/live.streamvc.macprovider"
    log "Would bootstrap with: launchctl bootstrap gui/$UID $PLIST_PATH"
    return
  fi

  render_plist "$model" "$provider_id" "$coordinator_url" > "$PLIST_PATH"

  plutil -lint "$PLIST_PATH" >/dev/null || die 5 "rendered launchd plist is invalid"
  launchctl bootout "gui/$UID" "$PLIST_PATH" >/dev/null 2>&1 || true
  launchctl enable "gui/$UID/live.streamvc.macprovider" || die 5 "failed to enable launchd service"
  launchctl bootstrap "gui/$UID" "$PLIST_PATH" || die 5 "failed to load launchd service"
  LAUNCHD_INSTALLED=1
}

render_plist() {
  model="$(xml_escape "$1")"
  provider_id="$(xml_escape "$2")"
  coordinator_url="$(xml_escape "$3")"
  user_home="$(xml_escape "$HOME")"
  # F-603-V7-4: launchd must invoke the real binary path, not the
  # ~/.local/bin symlink, so Swift Bundle resolution finds adjacent bundles.
  binary_path="$(xml_escape "$INSTALL_DIR/macprovider-cli")"
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

# Issue #191: write the inlined watchdog.sh to disk.
#
# IMPORTANT: the body below must stay byte-identical (after comment
# / blank-line normalization) with `ops/macprovider-watchdog/watchdog.sh`.
# `scripts/test-watchdog-inline-drift.sh` enforces this in CI.
write_watchdog_script() {
  cat <<'WATCHDOG_EOF' > "$WATCHDOG_PATH"
#!/usr/bin/env bash
# macprovider-watchdog: operator-visibility insurance against silent WS
# disconnection of the local provider, the symptom described in
# GitHub issue #189.
#
# Failure mode it catches: process up, listening on its local
# inference port, but the outbound TCP socket to the coordinator
# has gone half-open and the Swift reconnect loop never re-establishes.
# We detect this via `netstat -an` (BSD form on macOS) — if no
# ESTABLISHED outbound connection exists to coordinator.streamvc.live
# on tcp/443 for `provider_id`'s service, kick the launchd job so
# launchctl restarts the binary.
#
# Companion to the in-process bounded-send + watchdog landed in
# #189 (PR #204). That fix prevents the wedge from happening; this
# script catches it if it happens anyway, until every operator is on
# a binary that includes the Swift fix.

set -euo pipefail

LABEL="${MACPROVIDER_WATCHDOG_LABEL:-live.streamvc.macprovider}"
CONFIG_PATH="${MACPROVIDER_CONFIG_PATH:-$HOME/.config/macprovider/config.yaml}"
COORDINATOR_HOST="${MACPROVIDER_COORDINATOR_HOST:-coordinator.streamvc.live}"
COORDINATOR_PORT="${MACPROVIDER_COORDINATOR_PORT:-443}"
LOG_DIR="${MACPROVIDER_LOG_DIR:-$HOME/Library/Logs/macprovider}"
LOG_PATH="$LOG_DIR/watchdog.log"
# Issue #191 R1 architect HIGH: arming + grace state. Without
# these, a first-time install can spin in a restart loop — the
# Swift CLI loads the model BEFORE connecting to the coordinator
# (cold-cache model load is 10-20 minutes), and a watchdog that
# kicks on "no ESTABLISHED connection" would Darwin.exit the
# process every 60s before it ever opens its socket.
#
# Arming rule: the watchdog stays disarmed (no kicks) until it
# observes at least ONE successful ESTABLISHED connection IN THE
# CURRENT BOOT. The armed marker stores the boot id (kern.boottime
# sec) so a reboot — which restarts the provider into a fresh
# cold-cache model load — re-disarms the watchdog and prevents the
# stale-arming restart loop the R1 fix did not cover (R2 ARCH HIGH).
#
# Grace rule: after we DO kick, we wait at least KICK_GRACE_SECONDS
# before kicking again. This covers the post-kick model-reload
# window without re-triggering on the gap between launchd respawn
# and re-establishing the coordinator socket.
STATE_DIR="${MACPROVIDER_WATCHDOG_STATE_DIR:-$HOME/.local/share/macprovider-watchdog/state}"
ARMED_FILE="$STATE_DIR/armed"
LAST_KICK_FILE="$STATE_DIR/last_kick"
KICK_GRACE_SECONDS="${MACPROVIDER_WATCHDOG_KICK_GRACE_SECONDS:-300}"

mkdir -p "$LOG_DIR" "$STATE_DIR"

# Boot id: per-boot identifier sourced from kern.bootsessionuuid.
# Apple-provided UUID is immutable for the lifetime of a single
# boot (verified against XNU sysctl: read-only). Unlike
# kern.boottime, this value is NOT affected by NTP / manual
# wall-clock time correction (R3 architect MEDIUM #1), so a
# clock-set event during a wedge cannot silently re-disarm the
# watchdog and let the wedge persist.
current_boot_id() {
  sysctl -n kern.bootsessionuuid 2>/dev/null
}

# Acceptable formats in config.yaml are: `provider_id: ID` (yaml
# key) or `provider-id: ID` (alternate hyphenated form some operator
# tools have written historically). Either matches and surfaces the
# value with surrounding whitespace stripped.
read_provider_id() {
  if [ ! -f "$CONFIG_PATH" ]; then
    return 1
  fi
  awk '
    /^[[:space:]]*provider[_-]id[[:space:]]*:/ {
      sub(/^[^:]*:[[:space:]]*/, "")
      sub(/[[:space:]]*#.*$/, "")
      sub(/[[:space:]]+$/, "")
      gsub(/^["'\'']|["'\'']$/, "")
      print
      exit
    }
  ' "$CONFIG_PATH"
}

ts() { date -u +"%Y-%m-%dT%H:%M:%SZ"; }
log() { printf "[%s] %s\n" "$(ts)" "$*" >> "$LOG_PATH"; }

resolve_coordinator_ip() {
  # First try dscacheutil (no network call if already cached);
  # fall back to host(1) which most macs have via bind-utils.
  ip="$(dscacheutil -q host -a name "$COORDINATOR_HOST" 2>/dev/null \
        | awk '/^ip_address:/ { print $2; exit }')"
  if [ -z "$ip" ] && command -v host >/dev/null 2>&1; then
    ip="$(host -t A "$COORDINATOR_HOST" 2>/dev/null \
          | awk '/has address/ { print $4; exit }')"
  fi
  printf "%s" "${ip:-}"
}

has_established_conn() {
  ip="$1"
  if [ -z "$ip" ]; then
    return 1
  fi
  # BSD netstat on macOS: print ESTABLISHED TCP rows; awk matches
  # the foreign-address column against our coordinator IP:port.
  # Format: Proto Recv-Q Send-Q Local-Address Foreign-Address (state)
  netstat -an -p tcp 2>/dev/null \
    | awk -v target="${ip}.${COORDINATOR_PORT}" '
        $0 ~ /ESTABLISHED/ && $5 == target { found = 1; exit }
        END { exit found ? 0 : 1 }
      '
}

kick_provider() {
  log "kicking $LABEL via launchctl kickstart -k gui/$UID/$LABEL"
  launchctl kickstart -k "gui/$UID/$LABEL" >> "$LOG_PATH" 2>&1 || \
    log "launchctl kickstart returned non-zero (likely benign — process may already be restarting)"
}

now_epoch() { date -u +%s; }

autoupdate_recovery_tick() {
  AUTUPDATE_STATE_ROOT="${MACPROVIDER_AUTOUPDATE_STATE_ROOT:-$HOME/.local/share/macprovider/autoupdate}" \
  MACPROVIDER_LABEL="$LABEL" \
  LOG_PATH="$LOG_PATH" \
  python3 <<'PY'
import datetime
import fcntl
import hashlib
import json
import os
import pwd
import re
import shutil
import stat
import subprocess
import sys
import time

root = os.environ["AUTUPDATE_STATE_ROOT"]
label = os.environ["MACPROVIDER_LABEL"]
log_path = os.environ["LOG_PATH"]
pending = os.path.join(root, "pending.json")
lock_path = os.path.join(root, "update.lock")
uid = os.getuid()
provider_user = pwd.getpwuid(uid).pw_name

def ts():
    return datetime.datetime.now(datetime.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")

def log(message):
    with open(log_path, "a", encoding="utf-8") as fh:
        fh.write(f"[{ts()}] autoupdate {message}\n")

def event(outcome, phase, failure_class, reason, marker=None):
    payload = {
        "event": "provider_autoupdate_watchdog",
        "source": "coordinator",
        "outcome": outcome,
        "phase": phase,
        "reason": reason,
        "timestamp": ts(),
    }
    if failure_class:
        payload["failure_class"] = failure_class
    if marker:
        payload["update_id"] = marker.get("update_id", "")
        payload["target_version"] = marker.get("target_version", "")
    log(json.dumps(payload, sort_keys=True, separators=(",", ":")))

def reject_path(path, must_exist=True):
    try:
        st = os.lstat(path)
    except FileNotFoundError:
        if must_exist:
            raise
        return None
    if stat.S_ISLNK(st.st_mode):
        raise RuntimeError(f"symlink_rejected:{path}")
    if st.st_uid != uid:
        raise RuntimeError(f"owner_rejected:{path}")
    if st.st_nlink != 1 and not stat.S_ISDIR(st.st_mode):
        raise RuntimeError(f"hardlink_rejected:{path}")
    if st.st_mode & (stat.S_IWGRP | stat.S_IWOTH):
        raise RuntimeError(f"writable_rejected:{path}")
    try:
        acl = subprocess.run(["/bin/ls", "-le", path], check=False, stdout=subprocess.PIPE, stderr=subprocess.DEVNULL, text=True)
        for line in acl.stdout.splitlines():
            stripped = line.strip().lower()
            if not re.match(r"^[0-9]+:", stripped):
                continue
            if ("write" in stripped or "append" in stripped or "add_file" in stripped) and f"user:{provider_user.lower()}" not in stripped:
                raise RuntimeError(f"acl_write_rejected:{path}")
    except FileNotFoundError:
        pass
    return st

def verify_root():
    current = root
    parts = []
    while True:
        parts.append(current)
        parent = os.path.dirname(current)
        if parent == current or current == os.path.expanduser("~"):
            break
        current = parent
    for path in reversed(parts):
        if os.path.exists(path):
            st = reject_path(path)
            if not stat.S_ISDIR(st.st_mode):
                raise RuntimeError(f"not_directory:{path}")

def read_marker():
    fd = os.open(pending, os.O_RDONLY | getattr(os, "O_NOFOLLOW", 0))
    try:
        raw = os.read(fd, 65536)
    finally:
        os.close(fd)
    marker = json.loads(raw.decode("utf-8"))
    validate_marker_strict(marker)
    return marker

def validate_marker_strict(marker):
    required = {"update_id", "target_version", "target_path", "backup_path", "size", "mode", "sha256", "marker_deadline"}
    if not required.issubset(marker.keys()):
        raise RuntimeError("marker_missing_required_fields")
    if not re.match(r"^[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$", str(marker["update_id"])):
        raise RuntimeError("marker_update_id_invalid")
    if not re.match(r"^[0-9]+\.[0-9]+\.[0-9]+$", str(marker["target_version"])):
        raise RuntimeError("marker_target_version_invalid")
    for key in ("target_path", "backup_path"):
        value = str(marker[key])
        if not os.path.isabs(value) or value.endswith("/") or "/../" in value or "/./" in value:
            raise RuntimeError(f"marker_{key}_invalid")
    size = int(marker["size"])
    mode = int(marker["mode"])
    if size < 0 or size > 1024 * 1024 * 1024:
        raise RuntimeError("marker_size_invalid")
    if mode < 0 or mode > 0o7777:
        raise RuntimeError("marker_mode_invalid")
    if not re.match(r"^[0-9a-f]{64}$", str(marker["sha256"])):
        raise RuntimeError("marker_sha256_invalid")
    raw_deadline = str(marker["marker_deadline"])
    if not raw_deadline.endswith("Z"):
        raise RuntimeError("marker_deadline_invalid")
    try:
        deadline = datetime.datetime.strptime(raw_deadline, "%Y-%m-%dT%H:%M:%SZ").replace(tzinfo=datetime.timezone.utc)
    except ValueError:
        raise RuntimeError("marker_deadline_invalid")
    now = datetime.datetime.now(datetime.timezone.utc)
    post_start_window = 60
    future_tolerance = post_start_window + 30 * 60
    if deadline < now - datetime.timedelta(seconds=300) or deadline > now + datetime.timedelta(seconds=future_tolerance):
        raise RuntimeError("marker_deadline_out_of_bounds")

def current_binary_version(path):
    try:
        result = subprocess.run([path, "--version"], check=False, stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True, timeout=5)
    except Exception:
        return ""
    output = f"{result.stdout}\n{result.stderr}"
    match = re.search(r"([0-9]+(?:\.[0-9]+){2}(?:[-+][0-9A-Za-z.-]+)?)", output)
    return match.group(1) if match else ""

def read_success_sentinel(path):
    reject_path(path)
    fd = os.open(path, os.O_RDONLY | getattr(os, "O_NOFOLLOW", 0))
    try:
        payload = json.loads(os.read(fd, 65536).decode("utf-8"))
    finally:
        os.close(fd)
    update_id = str(payload.get("update_id", ""))
    if not re.match(r"^[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$", update_id):
        raise RuntimeError("sentinel_update_id_invalid")
    return {
        "update_id": update_id,
        "binary_version": str(payload.get("binary_version", "")),
    }

def process_success_sentinel(marker):
    binary_dir = os.path.dirname(marker["target_path"])
    for name in os.listdir(binary_dir):
        if not name.startswith(".macprovider-cli.success-"):
            continue
        sentinel = os.path.join(binary_dir, name)
        try:
            payload = read_success_sentinel(sentinel)
            sentinel_version = payload["binary_version"]
            current_version = current_binary_version(marker["target_path"])
            if not sentinel_version or sentinel_version != current_version:
                event("failure", "post_start", "orphaned_success_sentinel", "binary_version_mismatch", {"update_id": payload["update_id"], "target_version": sentinel_version})
                os.unlink(sentinel)
                continue
            if payload["update_id"] != str(marker["update_id"]):
                event("failure", "post_start", "orphaned_success_sentinel", "update_id_mismatch", {"update_id": payload["update_id"], "target_version": sentinel_version})
                os.unlink(sentinel)
                continue
            try:
                os.unlink(pending)
            except FileNotFoundError:
                pass
            try:
                os.unlink(marker["backup_path"])
            except FileNotFoundError:
                pass
            try:
                os.unlink(lock_path)
            except FileNotFoundError:
                pass
            os.unlink(sentinel)
            event("success", "post_start", None, "success_sentinel_cleanup_completed", marker)
            return True
        except Exception as exc:
            event("failure", "post_start", "orphaned_success_sentinel", str(exc), marker)
            try:
                os.unlink(sentinel)
            except FileNotFoundError:
                pass
    return False

def sha256(path):
    h = hashlib.sha256()
    fd = os.open(path, os.O_RDONLY | getattr(os, "O_NOFOLLOW", 0))
    try:
        while True:
            chunk = os.read(fd, 1024 * 1024)
            if not chunk:
                break
            h.update(chunk)
    finally:
        os.close(fd)
    return h.hexdigest()

def binary_path_without_pending():
    candidate = os.environ.get("MACPROVIDER_BINARY_PATH", "")
    if candidate:
        return candidate
    return shutil.which("macprovider-cli") or ""

def known_binary_dir():
    configured = os.environ.get("MACPROVIDER_BINARY_DIR", "")
    if configured:
        return os.path.realpath(configured)
    plist_path = os.path.expanduser("~/Library/LaunchAgents/live.streamvc.macprovider.plist")
    try:
        result = subprocess.run(
            ["/usr/libexec/PlistBuddy", "-c", "Print ProgramArguments:0", plist_path],
            check=False,
            stdout=subprocess.PIPE,
            stderr=subprocess.DEVNULL,
            text=True,
            timeout=5,
        )
        if result.returncode == 0 and result.stdout.strip():
            return os.path.realpath(os.path.dirname(result.stdout.strip()))
    except Exception:
        pass
    binary = binary_path_without_pending()
    if binary:
        return os.path.realpath(os.path.dirname(binary))
    return ""

def scan_without_pending():
    binary = binary_path_without_pending()
    if not binary:
        return
    binary_dir = os.path.dirname(binary)
    for name in os.listdir(binary_dir):
        path = os.path.join(binary_dir, name)
        if name.startswith(".macprovider-cli.success-"):
            try:
                payload = read_success_sentinel(path)
                sentinel_version = payload["binary_version"]
                current_version = current_binary_version(binary)
                if sentinel_version and sentinel_version == current_version:
                    os.unlink(path)
                    event("failure", "post_start", "orphaned_success_sentinel", "no_matching_pending", {"update_id": payload["update_id"], "target_version": current_version})
                else:
                    os.unlink(path)
                    event("failure", "post_start", "orphaned_success_sentinel", "binary_version_mismatch", {"update_id": payload["update_id"], "target_version": sentinel_version})
            except Exception as exc:
                log(f"success_sentinel_scan_error={exc}")
        elif name.startswith(".macprovider-cli.rollback-"):
            try:
                os.unlink(path)
                log(f"deleted_stale_backup={path}")
            except FileNotFoundError:
                pass

def quarantine(reason, marker=None):
    stamp = datetime.datetime.now(datetime.timezone.utc).strftime("%Y%m%dT%H%M%SZ")
    dest = os.path.join(root, f"pending-quarantined-{stamp}.json")
    try:
        os.replace(pending, dest)
        log(f"pending_marker_quarantined={dest} reason={reason}")
    except FileNotFoundError:
        pass

def marker_deadline_expired(marker):
    raw_deadline = str(marker["marker_deadline"])
    deadline = datetime.datetime.strptime(raw_deadline, "%Y-%m-%dT%H:%M:%SZ").replace(tzinfo=datetime.timezone.utc)
    return datetime.datetime.now(datetime.timezone.utc) >= deadline

def lock_is_held_by_other_process():
    os.makedirs(root, mode=0o700, exist_ok=True)
    fd = os.open(lock_path, os.O_CREAT | os.O_RDWR | getattr(os, "O_NOFOLLOW", 0), 0o600)
    try:
        try:
            fcntl.flock(fd, fcntl.LOCK_EX | fcntl.LOCK_NB)
        except BlockingIOError:
            return True
        return False
    finally:
        try:
            fcntl.flock(fd, fcntl.LOCK_UN)
        except OSError:
            pass
        os.close(fd)

def restore(marker):
    backup = marker["backup_path"]
    target = marker["target_path"]
    update_id = marker["update_id"]
    expected_backup = os.path.join(os.path.dirname(target), f".macprovider-cli.rollback-{update_id}")
    if backup != expected_backup:
        raise RuntimeError("backup_path_derivation_mismatch")
    trusted_dir = known_binary_dir()
    if not trusted_dir:
        raise RuntimeError("unsupported_install_topology:binary_dir_unknown")
    target_parent = os.path.realpath(os.path.dirname(target))
    backup_parent = os.path.realpath(os.path.dirname(backup))
    if target_parent != trusted_dir or backup_parent != trusted_dir:
        raise RuntimeError("unsupported_install_topology:path_outside_binary_dir")
    for checked in (target, backup):
        cursor = checked
        while os.path.realpath(os.path.dirname(cursor)) == trusted_dir and cursor != trusted_dir:
            reject_path(cursor, must_exist=os.path.exists(cursor))
            break
    backup_st = reject_path(backup)
    reject_path(os.path.dirname(target))
    if not os.path.isabs(target) or target.endswith("/"):
        raise RuntimeError("target_path_invalid")
    if backup_st.st_size != int(marker["size"]):
        raise RuntimeError("backup_size_mismatch")
    if sha256(backup) != str(marker["sha256"]):
        raise RuntimeError("backup_sha256_mismatch")
    os.chmod(backup, int(marker["mode"]))
    os.replace(backup, target)
    dir_fd = os.open(os.path.dirname(target), os.O_RDONLY)
    try:
        os.fsync(dir_fd)
    finally:
        os.close(dir_fd)
    try:
        subprocess.run(["launchctl", "bootstrap", f"gui/{uid}", os.path.expanduser("~/Library/LaunchAgents/live.streamvc.macprovider.plist")], check=False, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        subprocess.run(["launchctl", "kickstart", "-k", f"gui/{uid}/{label}"], check=False, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    except Exception as exc:
        log(f"launchctl_restore_warning={exc}")
    try:
        os.unlink(pending)
    except FileNotFoundError:
        pass
    try:
        os.unlink(lock_path)
    except FileNotFoundError:
        pass
    event("failure", "rollback", classify_post_start_failure(marker), "restored_prior_binary", marker)

def classify_post_start_failure(marker):
    try:
        printed = subprocess.run(["launchctl", "print", f"gui/{uid}/{label}"], check=False, stdout=subprocess.PIPE, stderr=subprocess.DEVNULL, text=True, timeout=5).stdout.lower()
        if "last exit status" in printed and not re.search(r"last exit status\s*=\s*0", printed):
            return "post_start_crash"
        if "pid =" not in printed:
            return "post_start_crash"
    except Exception:
        return "post_start_crash"
    health_url = os.environ.get("MACPROVIDER_HEALTHCHECK_URL", "")
    if health_url:
        try:
            curl = os.environ.get("MACPROVIDER_CURL", "/usr/bin/curl")
            probe = subprocess.run([curl, "-fsS", "--max-time", "2", health_url], check=False, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
            if probe.returncode != 0:
                return "post_start_health_failed"
        except Exception:
            return "post_start_health_failed"
    current_version = current_binary_version(marker["target_path"])
    if current_version and current_version != str(marker["target_version"]):
        return "post_start_rejoin_timeout"
    return "post_start_rejoin_timeout"

try:
    if not os.path.exists(pending):
        scan_without_pending()
        sys.exit(0)
    verify_root()
    reject_path(pending)
    if lock_is_held_by_other_process():
        sys.exit(0)
    try:
        marker = read_marker()
    except Exception as exc:
        event("failure", "rollback", "orphaned_pending_marker", "marker_invalid", None)
        quarantine(f"marker_invalid:{exc}", None)
        try:
            os.unlink(lock_path)
        except FileNotFoundError:
            pass
        sys.exit(0)
    if process_success_sentinel(marker):
        sys.exit(0)
    if not marker_deadline_expired(marker):
        log("pending_marker_still_inside_post_start_window")
        sys.exit(0)
    try:
        restore(marker)
    except Exception as exc:
        unsupported_topology = str(exc).startswith("unsupported_install_topology")
        failure_class = "other" if unsupported_topology else "rollback_backup_corrupt"
        reason = "unsupported_install_topology" if unsupported_topology else str(exc)
        event("failure", "rollback", failure_class, reason, marker)
        quarantine(str(exc), marker)
except Exception as exc:
    log(f"recovery_error={exc}")
PY
}

main() {
  autoupdate_recovery_tick
  pid="$(read_provider_id || true)"
  if [ -z "$pid" ]; then
    # Provider not yet installed / configured. Stay silent; if the
    # operator installs later we'll start working on the next tick.
    exit 0
  fi
  coord_ip="$(resolve_coordinator_ip)"
  if [ -z "$coord_ip" ]; then
    log "DNS resolution for $COORDINATOR_HOST failed; skipping this tick"
    exit 0
  fi
  boot_id="$(current_boot_id)"
  if has_established_conn "$coord_ip"; then
    # First time in THIS BOOT we see a healthy ESTABLISHED
    # connection, arm the watchdog. Subsequent absences will then
    # trigger a kick.
    armed_boot=""
    if [ -f "$ARMED_FILE" ]; then
      armed_boot="$(cat "$ARMED_FILE" 2>/dev/null || true)"
    fi
    if [ "$armed_boot" != "$boot_id" ]; then
      log "arming watchdog (boot=${boot_id}): first observed ESTABLISHED TCP to ${coord_ip}:${COORDINATOR_PORT} for provider_id=${pid}"
      printf "%s" "$boot_id" > "$ARMED_FILE"
    fi
    # Healthy. Stay silent so the log file does not bloat.
    exit 0
  fi
  # No ESTABLISHED connection. If we have not armed THIS BOOT (first
  # install / post-reboot still loading model / provider never
  # configured / provider never connected), stay silent — kicking
  # would break the cold-start flow.
  armed_boot=""
  if [ -f "$ARMED_FILE" ]; then
    armed_boot="$(cat "$ARMED_FILE" 2>/dev/null || true)"
  fi
  if [ "$armed_boot" != "$boot_id" ]; then
    exit 0
  fi
  # Post-kick grace: do not kick again until KICK_GRACE_SECONDS has
  # passed. Covers the launchd-respawn + model-reload + reconnect
  # window after our prior kick.
  if [ -f "$LAST_KICK_FILE" ]; then
    last_kick="$(cat "$LAST_KICK_FILE" 2>/dev/null || printf 0)"
    elapsed=$(( $(now_epoch) - last_kick ))
    if [ "$elapsed" -lt "$KICK_GRACE_SECONDS" ]; then
      # Inside the grace window; silent — operator can spot this in
      # the previous kick log line if they want.
      exit 0
    fi
  fi
  log "no ESTABLISHED TCP to ${coord_ip}:${COORDINATOR_PORT} for provider_id=${pid}; kicking $LABEL"
  now_epoch > "$LAST_KICK_FILE"
  kick_provider
}

main "$@"

WATCHDOG_EOF
  chmod 0755 "$WATCHDOG_PATH"
}

render_watchdog_plist() {
  watchdog_path="$(xml_escape "$WATCHDOG_PATH")"
  user_home="$(xml_escape "$HOME")"
  log_dir="$(xml_escape "$LOG_DIR")"
  config_path="$(xml_escape "$CONFIG_PATH")"
  coord_host="$(xml_escape "$(printf "%s" "$1" | sed -E 's#^wss?://##; s#/.*##')")"
  cat <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN"
  "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key>
  <string>$WATCHDOG_LABEL</string>
  <key>ProgramArguments</key>
  <array>
    <string>$watchdog_path</string>
  </array>
  <key>StartInterval</key>
  <integer>60</integer>
  <key>RunAtLoad</key>
  <true/>
  <key>StandardOutPath</key>
  <string>$log_dir/watchdog.out.log</string>
  <key>StandardErrorPath</key>
  <string>$log_dir/watchdog.err.log</string>
  <key>EnvironmentVariables</key>
  <dict>
    <key>HOME</key>
    <string>$user_home</string>
    <key>PATH</key>
    <!-- Issue #191 R4 architect HIGH: include /usr/sbin and /sbin
         so the watchdog finds sysctl + netstat under launchd's
         minimal PATH. -->
    <string>/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin</string>
    <key>MACPROVIDER_WATCHDOG_LABEL</key>
    <string>live.streamvc.macprovider</string>
    <key>MACPROVIDER_CONFIG_PATH</key>
    <string>$config_path</string>
    <key>MACPROVIDER_COORDINATOR_HOST</key>
    <string>$coord_host</string>
    <key>MACPROVIDER_LOG_DIR</key>
    <string>$log_dir</string>
  </dict>
  <key>ProcessType</key>
  <string>Background</string>
</dict>
</plist>
EOF
}

# Issue #191: install the LaunchAgent watchdog. Idempotent (same
# bootout-before-bootstrap pattern as install_plist).
install_watchdog() {
  coordinator_url="$1"
  if [ "$NO_WATCHDOG" = "1" ]; then
    log "Skipping watchdog install (MACPROVIDER_NO_WATCHDOG=1)."
    return
  fi
  if [ "$NO_LAUNCHD" = "1" ]; then
    log "Skipping watchdog install (MACPROVIDER_NO_LAUNCHD=1)."
    return
  fi
  if [ "$DRY_RUN" -eq 1 ]; then
    log "Would write watchdog to $WATCHDOG_PATH and bootstrap $WATCHDOG_LABEL"
    return
  fi
  log "Installing watchdog LaunchAgent (operator-visibility safety net for iss-189-class wedges)."
  mkdir -p "$WATCHDOG_DIR" "$LOG_DIR" "$(dirname "$WATCHDOG_PLIST_PATH")"
  write_watchdog_script
  render_watchdog_plist "$coordinator_url" > "$WATCHDOG_PLIST_PATH"
  plutil -lint "$WATCHDOG_PLIST_PATH" >/dev/null \
    || die 5 "rendered watchdog plist is invalid"
  launchctl bootout "gui/$UID" "$WATCHDOG_PLIST_PATH" >/dev/null 2>&1 || true
  launchctl enable "gui/$UID/$WATCHDOG_LABEL" \
    || die 5 "failed to enable watchdog launchd service"
  launchctl bootstrap "gui/$UID" "$WATCHDOG_PLIST_PATH" \
    || die 5 "failed to load watchdog launchd service"
  log "Watchdog installed. Logs at $LOG_DIR/watchdog.log."
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
    # F-603-V7-4: direct background self-test also invokes the real binary
    # so Bundle resolution sees the adjacent .bundle directories.
    nohup "$INSTALL_DIR/macprovider-cli" \
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

cache_size_kb() {
  path="$1"
  if [ -d "$path" ]; then
    du -sk "$path" 2>/dev/null | awk '{ print $1 }'
  else
    printf "0"
  fi
}

format_kb_gib() {
  kb="$1"
  awk -v kb="$kb" 'BEGIN { printf "%.1f", kb / 1048576 }'
}

progress_bar() {
  percent="$1"
  width=20
  filled=$(( percent * width / 100 ))
  bar=""
  i=0
  while [ "$i" -lt "$width" ]; do
    if [ "$i" -lt "$filled" ]; then
      bar="${bar}#"
    else
      bar="${bar}."
    fi
    i=$((i + 1))
  done
  printf "[%s]" "$bar"
}

model_download_estimate_gb() {
  model="$1"
  estimate="$(known_weight_gb_for_model "$model")"
  if [ -z "$estimate" ]; then
    estimate="$(estimate_weights_gb_from_name "$model")"
  fi
  printf "%s" "${estimate:-0}"
}

model_cache_is_warm() {
  current_kb="$1"
  estimate_gb="$2"
  if [ "$estimate_gb" -le 0 ]; then
    return 0
  fi
  estimate_kb=$(( estimate_gb * 1048576 ))
  warm_threshold_kb=$(( estimate_kb * 80 / 100 ))
  [ "$current_kb" -ge "$warm_threshold_kb" ]
}

print_model_download_progress() {
  cache_path="$1"
  estimate_gb="$2"
  elapsed="$3"
  previous_kb="$4"
  current_kb="$(cache_size_kb "$cache_path")"
  delta_kb=$(( current_kb - previous_kb ))
  [ "$delta_kb" -lt 0 ] && delta_kb=0

  if [ "$estimate_gb" -gt 0 ] && [ "$current_kb" -gt 0 ]; then
    estimate_kb=$(( estimate_gb * 1048576 ))
    percent=$(( current_kb * 100 / estimate_kb ))
    [ "$percent" -gt 99 ] && percent=99
    bar="$(progress_bar "$percent")"
    current_gib="$(format_kb_gib "$current_kb")"
    delta_gib="$(format_kb_gib "$delta_kb")"
    log "Model download ${bar} ${current_gib}/${estimate_gb} GiB (${percent}%, +${delta_gib} GiB; ${elapsed}s elapsed)."
  elif [ "$current_kb" -gt 0 ]; then
    current_gib="$(format_kb_gib "$current_kb")"
    delta_gib="$(format_kb_gib "$delta_kb")"
    log "Model download cache: ${current_gib} GiB (+${delta_gib} GiB; ${elapsed}s elapsed)."
  else
    log "Waiting for model download to start (${elapsed}s elapsed)."
  fi
  MODEL_PROGRESS_CACHE_KB="$current_kb"
}

wait_for_local_model() {
  model="$1"
  # F-603-V7-5: first install can take much longer if MLX has to download a
  # multi-GB model. Keep warm-cache installs at 5 minutes; allow cold-cache
  # installs 20 minutes with visible progress.
  local cache_check="$HOME/.cache/huggingface/hub/models--${model//\//--}"
  start_ts="$(date +%s)"
  estimate_gb="$(model_download_estimate_gb "$model")"
  previous_cache_kb="$(cache_size_kb "$cache_check")"
  if [ -d "$cache_check" ] && model_cache_is_warm "$previous_cache_kb" "$estimate_gb"; then
    deadline=$(( start_ts + 300 ))
    next_progress=$(( start_ts + 15 ))
    if [ "$estimate_gb" -gt 0 ]; then
      log "Waiting up to 5 min for local /v1/models (model cache detected; expected weights ~${estimate_gb} GiB)."
    else
      log "Waiting up to 5 min for local /v1/models (model cache detected)."
    fi
  elif [ -d "$cache_check" ]; then
    deadline=$(( start_ts + 1200 ))
    next_progress=$(( start_ts + 15 ))
    cache_gib="$(format_kb_gib "$previous_cache_kb")"
    if [ "$estimate_gb" -gt 0 ]; then
      log "Waiting up to 20 min for local /v1/models (partial model cache detected: ${cache_gib}/${estimate_gb} GiB; continuing download for ${model})."
    else
      log "Waiting up to 20 min for local /v1/models (model cache detected but may still be downloading ${model})."
    fi
  else
    deadline=$(( start_ts + 1200 ))
    next_progress=$(( start_ts + 15 ))
    if [ "$estimate_gb" -gt 0 ]; then
      log "Waiting up to 20 min for local /v1/models (first-time install; downloading ${model} ~${estimate_gb} GiB)."
    else
      log "Waiting up to 20 min for local /v1/models (first-time install; downloading ${model})."
    fi
  fi
  port_seen=0
  while [ "$(date +%s)" -lt "$deadline" ]; do
    raw_models_json="$(curl -sS --max-time 3 "http://127.0.0.1:${PORT}/v1/models" 2>/dev/null || true)"
    # The Swift JSON encoder emits forward-slashes as \/ (legal per RFC 8259
    # but cosmetically ugly). Normalize so grep -Fq "$model" matches whether
    # the encoder emits / or \/.
    models_json="$(printf "%s" "$raw_models_json" | sed 's|\\/|/|g')"
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
        print_model_download_progress "$cache_check" "$estimate_gb" "$elapsed" "$previous_cache_kb"
        previous_cache_kb="$MODEL_PROGRESS_CACHE_KB"
      else
        log "Model still loading (${elapsed}s elapsed; first run may still be downloading from Hugging Face)..."
        print_model_download_progress "$cache_check" "$estimate_gb" "$elapsed" "$previous_cache_kb"
        previous_cache_kb="$MODEL_PROGRESS_CACHE_KB"
      fi
      next_progress=$(( now + 15 ))
    fi
    sleep 2
  done
  return 1
}

print_local_self_test_diagnostics() {
  # F-603-V7-6: distinguish a timeout from a proven binary failure and leave
  # the user with concrete checks for process, download, and stderr state.
  log ""
  log "==========================================================="
  log "Self-test timeout reached. THIS DOES NOT NECESSARILY MEAN"
  log "THE BINARY FAILED. macprovider-cli is likely still loading"
  log "the model in the background."
  log ""
  log "To check if the binary is alive:"
  log "  ps aux | grep macprovider-cli | grep -v grep"
  log ""
  log "To check if the model is still downloading:"
  log "  du -sh ~/.cache/huggingface/hub/"
  log "  (run twice 30s apart; growing = downloading)"
  log ""
  log "To check for errors:"
  log "  tail -30 $LOG_DIR/macprovider.err.log"
  log ""
  log "Once the binary fully loads, it joins the pool. You can"
  log "verify from the coordinator side via /v1/pool/check (see docs)."
  log "==========================================================="
  log ""

  raw_response="$(curl -sS --max-time 3 "http://127.0.0.1:${PORT}/v1/models" 2>/dev/null || true)"
  if [ -n "$raw_response" ]; then
    log "Raw /v1/models response (first 200 bytes):"
    printf "  %.200s\n" "$raw_response"
    return
  fi

  log "/v1/models did not respond. Binary may not have bound port ${PORT}."
  log "stderr log path: $LOG_DIR/macprovider.err.log"
  if [ -s "$LOG_DIR/macprovider.err.log" ]; then
    log "Last 200 bytes of macprovider.err.log:"
    tail -c 200 "$LOG_DIR/macprovider.err.log" | sed 's/^/  /'
  fi
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

print_autotune_handoff() {
  provider_id="$1"
  printf "To tune throughput / latency parameters for your specific Mac, run:\n"
  printf "  macprovider-cli autotune --provider-id %s\n" "$provider_id"
  printf "To refresh the paid-model recommendation after install or update, run:\n"
  printf "  macprovider-cli autotune --recommend --apply\n"
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
    install_watchdog "$coordinator_url"
    check_path_hint
    exit 0
  fi

  check_catalog_ram_metadata "$coordinator_base" "$model" "$ram_gb" || true

  tag="$(latest_release_tag)"
  log "Latest release: $tag"
  download_release "$tag"
  verify_sha256
  validate_release_payload
  check_install_dir_clean
  install_binary
  check_path_hint
  clear_quarantine
  ensure_port_free
  if ! use_fresh_recommendation_if_available; then
    write_config "$model" "$provider_id" "$coordinator_url"
    run_autotune_recommend_apply
  fi
  if [ "$SKIP_PROVIDER_START" -eq 1 ]; then
    log "Install complete without starting a provider service."
    log "To re-check paid-yield recommendation later, run:"
    log "  macprovider-cli autotune --recommend --apply"
    log "To opt into local donor-mode testing, run:"
    log "  macprovider-cli autotune --recommend --apply --donor-mode"
    exit 0
  fi
  install_plist "$model" "$provider_id" "$coordinator_url"
  install_watchdog "$coordinator_url"
  start_manual_service "$model" "$provider_id" "$coordinator_url"

  if ! wait_for_local_model "$model"; then
    print_local_self_test_diagnostics
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
  print_autotune_handoff "$provider_id"
  log "Uninstall: bash <(curl -fsSL https://get.streamvc.live/uninstall.sh)"
}

main "$@"
