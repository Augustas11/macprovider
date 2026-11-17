# Shared helpers for member.sh and head.sh (issue #2417 shard proof of concept).
# shellcheck disable=SC2034 # constants used by member.sh and head.sh
# Sourced, never run. bash 3.2 compatible. Needs only tools a stock Mac has:
# curl, shasum, /usr/bin/openssl, tar, ifconfig, sysctl, vm_stat, lsof.

SHARD_POC_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SHARD_POC_DIR/../../.." && pwd)"

# Pinned public CLI release. Any release is verified the same way the public
# installer verifies it: checksums.txt.sig under the key embedded in install.sh.
CLI_VERSION_DEFAULT="v1.8.289"
RELEASE_BASE="https://github.com/Augustas11/macprovider/releases/download"
INSTALL_SH="$REPO_ROOT/phase3-binary/dist/install.sh"

# Pinned model: the signed catalog artifact for meta-llama/llama-3.2-3b-instruct
# (phase3-binary/catalog/autotune/tier2-identity-binding.json): revision and
# macprovider.snapshot-manifest.v1 hash. 28 layers.
MODEL_REPO="mlx-community/Llama-3.2-3B-Instruct-4bit"
MODEL_REV="7f0dc925e0d0afb0322d96f9255cfddf2ba5636e"
MODEL_HASH="e7e5bff4248768b4db7a53afb3b514ba5867b800f63d1abd0330eaf08e54aa90"
MODEL_LAYERS=28
# name size lfs-sha256 ("-" when the file is not LFS; the manifest hash covers it)
MODEL_FILES="
.gitattributes 1570 -
README.md 16295 -
config.json 1122 -
model.safetensors 1807496278 d75e1ee0ea653cc5b76191ec934c7c0d568e94d4e47846619f1f4bc715b7b265
model.safetensors.index.json 45720 -
special_tokens_map.json 296 -
tokenizer.json 17209920 6b9e4e7fb171f92fd137b777cc2714bf87d11576700a1dcd7a399e7bbe39537b
tokenizer_config.json 54558 -
"

# Default ports: away from 8080 and the installed provider's ports.
HEAD_HTTP_PORT_DEFAULT=18190
MEMBER_HTTP_PORT_DEFAULT=18191
BASELINE_HTTP_PORT_DEFAULT=18192
STAGE_PORT_DEFAULT=47101

# Supervision for a link across the internet (SPEC-051 section 4 values; the
# allowed ranges are in ShardGroupConfig.swift ShardSupervisionConfig.validate).
# Defaults on a cable are 100 ms x 3 misses and a 500 ms decode hop. A dead link
# is declared after interval x misses of silence; 250 ms x 8 = 2 s rides out
# Wi-Fi and internet jitter spikes. The decode-hop budget per request is
# (hops + decodes in flight) x deadline, so 1500 ms gives >= 3 s.
HEARTBEAT_MS_DEFAULT=250
HEARTBEAT_MISSES_DEFAULT=8
DECODE_HOP_MS_DEFAULT=1500
PREFILL_CHUNK_MS_DEFAULT=4000
REPLAY_MS_DEFAULT=10000
PREFILL_CHUNK_TOKENS_DEFAULT=128
MAX_SEQUENCES_DEFAULT=8
MAX_CONTEXT_DEFAULT=4096
SPLIT_LAYER_DEFAULT=14

# Folders the CLI may create on first use. If one does not exist before our
# first run, we note that, and --cleanup removes it again.
CLI_SIDE_DIRS="
$HOME/Library/Application Support/macprovider
$HOME/Library/Application Support/macprovider-cli
$HOME/.config/macprovider
$HOME/Library/Logs/macprovider
"

log() { printf '[shard-poc %s] %s\n' "$(date +%H:%M:%S)" "$*"; }
warn() { printf '[shard-poc %s] WARNING: %s\n' "$(date +%H:%M:%S)" "$*"; }
die() { printf '[shard-poc %s] STOP: %s\n' "$(date +%H:%M:%S)" "$*"; exit 1; }

# Unset every MACPROVIDER_* variable so an installed provider's environment
# never reaches the CLI we start.
clean_env() {
  local v
  for v in $(env | sed -n 's/^\(MACPROVIDER_[A-Za-z0-9_]*\)=.*/\1/p'); do
    unset "$v"
  done
}

# --- host checks -------------------------------------------------------------
ram_gb() { echo $(( $(sysctl -n hw.memsize) / 1073741824 )); }

available_mem_gb() {
  vm_stat | awk '
    /page size of/ { for (i = 1; i <= NF; i++) if ($i ~ /^[0-9]+$/) ps = $i }
    /Pages free/ { f = $3 } /Pages inactive/ { n = $3 } /Pages speculative/ { s = $3 } /Pages purgeable/ { p = $3 }
    END { gsub(/\./, "", f); gsub(/\./, "", n); gsub(/\./, "", s); gsub(/\./, "", p)
          printf "%d\n", (f + n + s + p) * ps / 1073741824 }'
}

free_disk_gb() { df -g "$1" | awk 'NR == 2 { print $4 }'; }

# check_host <workdir> <min available GB>
check_host() {
  local root="$1" min_avail="$2"
  [ "$(uname -s)" = Darwin ] || die "this needs macOS"
  [ "$(sysctl -n hw.optional.arm64 2>/dev/null || echo 0)" = 1 ] || die "this needs an Apple Silicon Mac (M1 or later)"
  local os major
  os="$(sw_vers -productVersion)"; major="${os%%.*}"
  [ "$major" -ge 14 ] 2>/dev/null || die "this needs macOS 14 or later (found $os)"
  local ram avail disk
  ram="$(ram_gb)"; avail="$(available_mem_gb)"
  mkdir -p "$root"; disk="$(free_disk_gb "$root")"
  log "Mac: $(sysctl -n machdep.cpu.brand_string), ${ram} GB memory, macOS $os"
  log "available memory about ${avail} GB, free disk ${disk} GB"
  [ "$ram" -ge 8 ] || die "this needs at least 8 GB of memory"
  [ "$avail" -ge "$min_avail" ] || die "about ${avail} GB of memory is available; this needs ${min_avail} GB. Quit large apps and try again"
  [ "$disk" -ge 5 ] || die "this needs 5 GB of free disk (found ${disk} GB)"
}

# Report, never touch, an existing MacProvider or Malibu install.
report_existing_install() {
  local found=""
  [ -d "$HOME/macprovider" ] && found="$found ~/macprovider"
  [ -d /Applications/Malibu.app ] && found="$found /Applications/Malibu.app"
  [ -f "$HOME/.config/macprovider/config.yaml" ] && found="$found ~/.config/macprovider/config.yaml"
  case "$(launchctl list 2>/dev/null | grep -i macprovider || true)" in
    "") ;; *) found="$found (a launchd job)" ;;
  esac
  if [ -n "$found" ]; then
    log "an existing MacProvider install was found:$found"
    log "it is left alone: this test uses its own folder, its own config and its own ports"
  fi
}

port_free() { ! lsof -nP -iTCP:"$1" -sTCP:LISTEN >/dev/null 2>&1; }

record_cli_side_dirs() {
  local root="$1" d
  [ -f "$root/.cli-side-dirs-recorded" ] && return 0
  : >"$root/.cli-side-dirs-created"
  while IFS= read -r d; do
    [ -n "$d" ] || continue
    [ -e "$d" ] || printf '%s\n' "$d" >>"$root/.cli-side-dirs-created"
  done <<EOF
$CLI_SIDE_DIRS
EOF
  : >"$root/.cli-side-dirs-recorded"
}

# --- Tailscale ---------------------------------------------------------------
# 100.64.0.0/10: 100.64.0.0 - 100.127.255.255
is_tailscale_addr() {
  local a="$1" o1 o2 o3 o4
  case "$a" in *[!0-9.]*|"") return 1 ;; esac
  IFS=. read -r o1 o2 o3 o4 <<EOF
$a
EOF
  [ -n "${o4:-}" ] || return 1
  [ "$o1" = 100 ] && [ "$o2" -ge 64 ] && [ "$o2" -le 127 ] && [ "$o3" -le 255 ] && [ "$o4" -le 255 ]
}

local_tailscale_addr() {
  local a
  for a in $(ifconfig | awk '$1 == "inet" { print $2 }'); do
    if is_tailscale_addr "$a"; then echo "$a"; return 0; fi
  done
  return 1
}

is_local_addr() {
  local a
  for a in $(ifconfig | awk '$1 == "inet" { print $2 }'); do [ "$a" = "$1" ] && return 0; done
  return 1
}

tailscale_cli() {
  if command -v tailscale >/dev/null 2>&1; then command -v tailscale
  elif [ -x /Applications/Tailscale.app/Contents/MacOS/Tailscale ]; then echo /Applications/Tailscale.app/Contents/MacOS/Tailscale
  fi
}

# --- CLI download and verification -------------------------------------------
release_public_key() {
  # The key the public installer embeds (write_checksum_public_key in install.sh).
  [ -f "$INSTALL_SH" ] || die "missing $INSTALL_SH; run this from a clone of the repository"
  awk '/^write_checksum_public_key\(\) \{/ { f = 1 }
       f && /-----BEGIN PUBLIC KEY-----/ { p = 1 }
       p { print }
       p && /-----END PUBLIC KEY-----/ { exit }' "$INSTALL_SH"
}

# fetch_cli <root> <tag>; sets CLI to the verified binary.
fetch_cli() {
  local root="$1" tag="$2"
  local dest="$root/cli/$tag" asset="macprovider-cli-${tag}-darwin-arm64.tar.gz"
  CLI="$dest/macprovider-cli"
  if [ -x "$CLI" ] && [ -f "$dest/.verified" ] && [ "$("$CLI" --version 2>/dev/null)" = "${tag#v}" ]; then
    log "CLI $tag already downloaded and verified: $dest"
    return 0
  fi
  local stage="$root/cli/.staging-$tag"
  rm -rf "$stage" "$dest"; mkdir -p "$stage/unpacked"
  log "downloading the public CLI release $tag from GitHub"
  curl -fsSL --retry 3 -o "$stage/checksums.txt" "$RELEASE_BASE/$tag/checksums.txt" || die "could not download checksums.txt for $tag"
  curl -fsSL --retry 3 -o "$stage/checksums.txt.sig" "$RELEASE_BASE/$tag/checksums.txt.sig" || die "could not download checksums.txt.sig for $tag"
  release_public_key >"$stage/release-signing-public.pem"
  grep -q "BEGIN PUBLIC KEY" "$stage/release-signing-public.pem" || die "could not read the release signing key from install.sh"
  /usr/bin/openssl dgst -sha256 -verify "$stage/release-signing-public.pem" -signature "$stage/checksums.txt.sig" \
    "$stage/checksums.txt" >/dev/null || die "checksums.txt signature verification failed"
  log "checksums.txt signature verified (release key from install.sh)"
  local expected actual
  expected="$(awk -v a="$asset" '$2 == a { print $1; exit }' "$stage/checksums.txt")"
  [ -n "$expected" ] || die "checksums.txt has no entry for $asset"
  curl -fL --retry 3 --progress-bar -o "$stage/$asset" "$RELEASE_BASE/$tag/$asset" || die "could not download $asset"
  actual="$(shasum -a 256 "$stage/$asset" | awk '{ print $1 }')"
  [ "$actual" = "$expected" ] || die "checksum mismatch for $asset"
  log "SHA-256 of $asset verified"
  # Same tarball rules as install.sh validate_tarball: no absolute or parent
  # paths, no link or device members.
  local entries modes
  entries="$(tar tzf "$stage/$asset")" || die "could not list the release tarball"
  case "$(printf '%s\n' "$entries" | grep -E '^/|(^|/)\.\.(/|$)' || true)" in
    "") ;; *) die "release tarball has an unsafe path" ;;
  esac
  modes="$(tar tvzf "$stage/$asset" | cut -c1)" || die "could not list the release tarball"
  case "$(printf '%s\n' "$modes" | grep -E '^[lhbcp]' || true)" in
    "") ;; *) die "release tarball has link or device members" ;;
  esac
  tar xzf "$stage/$asset" -C "$stage/unpacked"
  [ -x "$stage/unpacked/macprovider-cli" ] || die "release tarball has no macprovider-cli"
  [ "$("$stage/unpacked/macprovider-cli" --version)" = "${tag#v}" ] || die "the downloaded CLI does not report version ${tag#v}"
  mv "$stage/unpacked" "$dest"
  : >"$dest/.verified"
  rm -rf "$stage"
  log "CLI $tag ready: $CLI"
}

# --- model download and verification -----------------------------------------
# snapshot-manifest.v1 (ModelArtifactVerifier.inspectCanonicalArtifact): for
# every regular file sorted by relative path, "path\nsize\nsha256\n", hashed.
manifest_hash() {
  local dir="$1" f
  (cd "$dir" && find . -type f | sed 's|^\./||' | LC_ALL=C sort | while IFS= read -r f; do
    printf '%s\n%s\n%s\n' "$f" "$(stat -f %z "$f")" "$(shasum -a 256 "$f" | awk '{ print $1 }')"
  done) | shasum -a 256 | awk '{ print $1 }'
}

# fetch_model <root>; sets MODEL_DIR to the verified snapshot.
fetch_model() {
  local root="$1"
  if [ -f "$REPO_ROOT/phase3-binary/catalog/autotune/tier2-identity-binding.json" ]; then
    grep -q "$MODEL_HASH" "$REPO_ROOT/phase3-binary/catalog/autotune/tier2-identity-binding.json" \
      || die "the pinned model hash is not in this checkout's catalog binding; update common.sh"
  fi
  local base="$root/models/${MODEL_REPO%%/*}--${MODEL_REPO#*/}/$MODEL_REV"
  MODEL_DIR="$base/$MODEL_HASH"
  if [ -d "$MODEL_DIR" ]; then
    log "checking the model already on disk (about 10 s)"
    [ "$(manifest_hash "$MODEL_DIR")" = "$MODEL_HASH" ] && { log "model verified: $MODEL_REPO@$MODEL_REV"; return 0; }
    warn "the model on disk does not match; downloading it again"
    rm -rf "$MODEL_DIR"
  fi
  local stage="$base/.staging" name size lfs got
  mkdir -p "$stage"
  log "downloading $MODEL_REPO (1.8 GB) from HuggingFace"
  while read -r name size lfs; do
    [ -n "$name" ] || continue
    if [ -f "$stage/$name" ] && [ "$(stat -f %z "$stage/$name")" = "$size" ]; then continue; fi
    curl -fL --retry 5 -C - --progress-bar -o "$stage/$name" \
      "https://huggingface.co/$MODEL_REPO/resolve/$MODEL_REV/$name" || die "could not download $name"
    got="$(stat -f %z "$stage/$name")"
    [ "$got" = "$size" ] || die "$name has $got bytes, expected $size"
  done <<EOF
$MODEL_FILES
EOF
  while read -r name size lfs; do
    [ -n "$name" ] && [ "$lfs" != "-" ] || continue
    [ "$(shasum -a 256 "$stage/$name" | awk '{ print $1 }')" = "$lfs" ] || { rm -f "$stage/$name"; die "$name failed its SHA-256 check; run again"; }
  done <<EOF
$MODEL_FILES
EOF
  got="$(manifest_hash "$stage")"
  [ "$got" = "$MODEL_HASH" ] || die "model snapshot hash $got is not the catalog hash $MODEL_HASH"
  mv "$stage" "$MODEL_DIR"
  log "model verified against the signed catalog hash: $MODEL_DIR"
}

supervision_json() {
  printf '{"heartbeat_interval_ms":%d,"heartbeat_miss_limit":%d,"decode_hop_deadline_ms":%d,"prefill_chunk_deadline_ms":%d,"replay_deadline_ms":%d}' \
    "$HEARTBEAT_MS" "$HEARTBEAT_MISSES" "$DECODE_HOP_MS" "$PREFILL_CHUNK_MS" "$REPLAY_MS"
}

check_supervision() {
  in_range() { [ "$2" -ge "$3" ] 2>/dev/null && [ "$2" -le "$4" ] || die "$1 $2 is outside $3..$4"; }
  in_range --heartbeat-ms "$HEARTBEAT_MS" 20 1000
  in_range --heartbeat-misses "$HEARTBEAT_MISSES" 2 10
  in_range --decode-hop-ms "$DECODE_HOP_MS" 50 2000
  in_range --prefill-chunk-ms "$PREFILL_CHUNK_MS" 500 4000
  in_range --replay-ms "$REPLAY_MS" 1000 30000
}

# A minimal provider config of our own: no provider id, no token, no
# coordinator; protected_file keeps credentials next to it, never in Keychain.
write_serve_config() {
  local dir="$1"
  mkdir -p "$dir"; chmod 700 "$dir"
  (umask 077; printf 'credential_store: protected_file\nenable_receipts: false\n' >"$dir/config.yaml")
}

# Flags every serve we start gets: local HTTP only (--no-join), isolated lab
# lifecycle (protected_file + --no-join keeps launchd, lease and lock files in a
# private temporary root, MacProviderCLI.swift isolatesNoJoinLabServe), no
# receipts, no disk KV cache, no idle prewarm.
SERVE_COMMON_FLAGS="--no-join --credential-store protected_file --no-enable-receipts --no-kv-disk-cache-enabled --no-idle-prewarm --log-level info"

# stop_pid <pid> <name>: SIGTERM (what launchd sends; background children of a
# script ignore SIGINT), up to 20 s, then SIGKILL.
stop_pid() {
  local pid="$1" name="$2" i=0
  [ -n "$pid" ] && kill -0 "$pid" 2>/dev/null || return 0
  log "stopping $name"
  kill -TERM "$pid" 2>/dev/null || true
  while [ "$i" -lt 20 ]; do kill -0 "$pid" 2>/dev/null || return 0; sleep 1; i=$((i + 1)); done
  kill -KILL "$pid" 2>/dev/null || true
}

# Redacted copy of a log for posting on a public issue: Tailscale addresses
# and the home folder path are replaced.
share_copy() {
  local src="$1"
  [ -f "$src" ] || return 0
  sed -E -e 's/100\.[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}/100.x.x.x/g' -e "s|$HOME|~|g" "$src" >"${src%.log}.share.log"
}

# cleanup_root <root>: remove the working folder and any CLI-side folder our
# first run created. Refuses while a CLI from this folder still runs.
cleanup_root() {
  local root="$1" d
  [ -f "$root/.shard-poc-root" ] || die "$root is not a shard-poc working folder (no .shard-poc-root marker); nothing removed"
  if pgrep -f "$root/cli/" >/dev/null 2>&1; then die "a CLI from $root is still running; stop it with Ctrl-C first"; fi
  local installed=0
  { [ -d "$HOME/macprovider" ] || [ -d /Applications/Malibu.app ] || [ -f "$HOME/.config/macprovider/config.yaml" ]; } && installed=1
  if [ -f "$root/.cli-side-dirs-created" ]; then
    while IFS= read -r d; do
      [ -n "$d" ] && [ -e "$d" ] || continue
      if [ -d "$d" ] && [ "$installed" = 1 ]; then
        warn "MacProvider is installed now, so $d is kept"
        continue
      fi
      rm -rf "$d" && log "removed $d (created by this test)"
    done <"$root/.cli-side-dirs-created"
  fi
  rm -rf "$root"
  log "removed $root"
}

init_root() {
  local root="$1"
  mkdir -p "$root"; chmod 700 "$root"
  : >"$root/.shard-poc-root"
  record_cli_side_dirs "$root"
}
