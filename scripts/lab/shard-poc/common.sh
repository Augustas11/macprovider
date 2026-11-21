# Shared helpers for member.sh and head.sh (issue #2417 shard proof of concept).
# shellcheck shell=bash
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

# --- models -------------------------------------------------------------------
# select_model big|small sets the MODEL_* values below. Both Macs must use the
# same model.
#
# big (default): mlx-community/Llama-3.3-70B-Instruct-4bit, 80 layers, hidden
# size 8192, 8 KV heads of 128, 39.7 GB of files (37.0 GiB of tensors). It is
# not in the signed catalog. It is pinned instead by its HuggingFace revision
# and the SHA-256 of every file (LFS metadata from the HuggingFace API for the
# weights and tokenizer.json, computed from the pinned bytes for the small
# files). MODEL_HASH is the SHA-256 of the macprovider.snapshot-manifest.v1
# manifest built from those entries, the value the CLI checks stage files
# against (ShardStageArtifact.verify). Each Mac downloads only the safetensors
# files its layers need plus the small files (SPEC-051-R008).
#
# small: the signed catalog artifact for meta-llama/llama-3.2-3b-instruct
# (phase3-binary/catalog/autotune/tier2-identity-binding.json), 1.8 GB, 28
# layers. Any Mac can run it alone, so it is only a quick link check; it does
# not test serving a model too large for one Mac.
select_model() {
  MODEL_KIND="$1"
  case "$1" in
    big)
      MODEL_REPO="mlx-community/Llama-3.3-70B-Instruct-4bit"
      MODEL_REV="de2dfaf56839b7d0e834157d2401dee02726874d"
      MODEL_HASH="7abad071088b776f93802a05851b7795b0db8d3fb1d5804455c9bb3852f952be"
      MODEL_LAYERS=80
      MODEL_STAGE_ONLY=1
      MODEL_VERIFICATION="HuggingFace revision $MODEL_REV and per-file SHA-256 from the HuggingFace API (not in the signed catalog)"
      # Tensor bytes from the safetensors headers at this revision: one decoder
      # layer, the embedding (first stage), lm_head plus model.norm (last stage),
      # and all tensors together.
      MODEL_LAYER_BYTES=481329152
      MODEL_FIRST_EXTRA_BYTES=591003648
      MODEL_LAST_EXTRA_BYTES=591020032
      MODEL_TENSOR_BYTES=39688355840
      # KV bytes per token of one sequence over all layers: 80 x 8 x 128 x 2 x 2
      # (AutotuneModelContextCap.kvCacheBytesPerToken).
      MODEL_KV_PER_TOKEN=327680
      # name size sha256
      MODEL_FILES="
.gitattributes 1570 34448b82c17d60fec9b65b1f093c115ddbaadc04beb1b0140b6bfed2e012a930
README.md 16485 337b188122c71e59563f3bfcac4df7b4057bc427fff5318ada006f315731716a
config.json 1123 3027455f6ce315c983f1955f20d39617c839d417972252a29cdc89c57f6f1106
model-00001-of-00008.safetensors 5272167770 461b51eb0c4fa9053c61ff5deadbf279c188d2310cb7286f1b32e272a285de73
model-00002-of-00008.safetensors 5294649694 c459978d4249ae7f06ad8671c96c76e905603390e2ff0452f358e8517d271209
model-00003-of-00008.safetensors 5294649717 81e6d2342c9b5c67fb84d4f25aef1662a002c93441e6098d42dcb6ee53c8c7e7
model-00004-of-00008.safetensors 5294649733 aa51acddaba5e72932832bf41bd3f5deeae06695de89fbbe3a769e2f46bd8e75
model-00005-of-00008.safetensors 5294649717 c4d93817d2dc082a3fa0ef89c099a4c2e9620101876838ecf18ff795e41ebf00
model-00006-of-00008.safetensors 5294649733 cb4a7aeb63148ae9a0dff6b948809985199b5a3a6839be0e7f165146bf986add
model-00007-of-00008.safetensors 5294649739 e8dc0a788d02146246ac39b00ed8d929be3eccb5c7c981e785d617ed482bc346
model-00008-of-00008.safetensors 2648501502 56044b182a10d0a458f48402e45bb0136348f3f97574c82cf2a49dbbd51d5dcc
model.safetensors.index.json 158327 dc2f0759c76502dc77a74a06fc9c85a976d16ac12842cfad1d37776c377ea887
special_tokens_map.json 454 94e708c3f5e64acf85bbe5ad01467a1248faadb73e83b41793087ecced586e8f
tokenizer.json 17209920 6b9e4e7fb171f92fd137b777cc2714bf87d11576700a1dcd7a399e7bbe39537b
tokenizer_config.json 55425 5c756ad6048c884974a331963ae3c3e1624b548a11174dadda02a69041c87352
"
      # Layers (first last, inclusive) in each weight file, from
      # model.safetensors.index.json at this revision. The embedding is in file 1,
      # lm_head and model.norm in file 8. The CLI derives the same set from the
      # index and refuses a stage that lacks a file it needs.
      MODEL_WEIGHT_LAYERS="
model-00001-of-00008.safetensors 0 9
model-00002-of-00008.safetensors 9 20
model-00003-of-00008.safetensors 20 31
model-00004-of-00008.safetensors 31 42
model-00005-of-00008.safetensors 42 53
model-00006-of-00008.safetensors 53 64
model-00007-of-00008.safetensors 64 75
model-00008-of-00008.safetensors 75 79
"
      ;;
    small)
      MODEL_REPO="mlx-community/Llama-3.2-3B-Instruct-4bit"
      MODEL_REV="7f0dc925e0d0afb0322d96f9255cfddf2ba5636e"
      MODEL_HASH="e7e5bff4248768b4db7a53afb3b514ba5867b800f63d1abd0330eaf08e54aa90"
      MODEL_LAYERS=28
      MODEL_STAGE_ONLY=0
      MODEL_VERIFICATION="signed catalog snapshot hash $MODEL_HASH"
      # Tied embedding: the last stage holds the embedding again for its head.
      MODEL_LAYER_BYTES=56635392
      MODEL_FIRST_EXTRA_BYTES=221626368
      MODEL_LAST_EXTRA_BYTES=221632512
      MODEL_TENSOR_BYTES=1807423488
      MODEL_KV_PER_TOKEN=114688
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
      MODEL_WEIGHT_LAYERS="
model.safetensors 0 27
"
      ;;
    *) die "--model must be big or small" ;;
  esac
  MODEL_BASE_REL="models/${MODEL_REPO%%/*}--${MODEL_REPO#*/}/$MODEL_REV"
}

gib() { awk -v b="$1" 'BEGIN { printf "%.1f", b / 1073741824 }'; }
gb() { awk -v b="$1" 'BEGIN { printf "%.1f", b / 1000000000 }'; }

# --- memory fit (the CLI's own rules) ------------------------------------------
# Memory size as the CLI counts it: whole GiB, rounded up (ModelFit.detectRAMGB).
hw_gb() { echo $(( ($(sysctl -n hw.memsize) + 1073741823) / 1073741824 )); }

# stage_fit <memory GB> <layer start> <layer end> <sequences> <context>
# prints "weights kv_demand kv_budget fits" in bytes. The rule serve applies
# before it loads a stage (ShardStageArtifact.fit, SPEC-051-R006): KV demand
# is per-token KV x context x sequences x the stage's share of the layers;
# the KV budget is 3/4 of (memory - stage weights - 4 GiB safety margin)
# (AutotuneModelContextCap.shardStageKVBudgetBytes). Layers 0:N is the whole
# model on one Mac, which plain serve sizes the same way.
stage_fit() {
  awk -v gbm="$1" -v a="$2" -v b="$3" -v s="$4" -v c="$5" -v n="$MODEL_LAYERS" \
      -v L="$MODEL_LAYER_BYTES" -v F="$MODEL_FIRST_EXTRA_BYTES" -v H="$MODEL_LAST_EXTRA_BYTES" \
      -v T="$MODEL_TENSOR_BYTES" -v K="$MODEL_KV_PER_TOKEN" 'BEGIN {
    G = 1073741824
    if (a == 0 && b == n) w = T
    else w = (b - a) * L + (a == 0 ? F : 0) + (b == n ? H : 0)
    d = K * c * s * (b - a) / n
    spare = gbm * G - w - 4 * G
    bud = spare > 0 ? int(spare * 3 / 4) : 0
    printf "%.0f %.0f %.0f %s\n", w, d, bud, (d <= bud ? "yes" : "no")
  }'
}

# fits_alone <memory GB> <sequences> <context>: yes or no.
fits_alone() { stage_fit "$1" 0 "$MODEL_LAYERS" "$2" "$3" | awk '{ print $4 }'; }

# plan_split <head GB> <member GB> <sequences> <context>: the head's last
# layer. The CLI's placement rule for two members (ShardPlacementPlanner
# proportionalCounts): layers in proportion to each Mac's usable memory
# (memory minus the 4 GiB safety margin), the LM head charged to the last
# stage, each layer costed as its weights plus its KV. Then the repair step:
# while a stage fails stage_fit, move the boundary one layer toward the other
# Mac. Prints nothing when no split fits. Both scripts call it with the same
# inputs, so they agree without talking to each other.
plan_split() {
  local s tries=0 hf mf
  s="$(awk -v uh="$1" -v um="$2" -v n="$MODEL_LAYERS" -v L="$MODEL_LAYER_BYTES" -v H="$MODEL_LAST_EXTRA_BYTES" \
          -v K="$MODEL_KV_PER_TOKEN" -v sq="$3" -v c="$4" 'BEGIN {
    uh -= 4; um -= 4; if (uh < 1) uh = 1; if (um < 1) um = 1
    cost = L + K * c * sq / n
    s = int((n * cost + H) * uh / (uh + um) / cost + 0.5)
    if (s < 1) s = 1; if (s > n - 1) s = n - 1
    print s }')"
  while [ "$tries" -lt "$MODEL_LAYERS" ]; do
    hf="$(stage_fit "$1" 0 "$s" "$3" "$4" | awk '{ print $4 }')"
    mf="$(stage_fit "$2" "$s" "$MODEL_LAYERS" "$3" "$4" | awk '{ print $4 }')"
    if [ "$hf" = yes ] && [ "$mf" = yes ]; then echo "$s"; return 0; fi
    [ "$hf" = no ] && [ "$mf" = no ] && return 0
    if [ "$hf" = no ]; then s=$((s - 1)); else s=$((s + 1)); fi
    { [ "$s" -ge 1 ] && [ "$s" -le $((MODEL_LAYERS - 1)) ]; } || return 0
    tries=$((tries + 1))
  done
}

# report_stage <label> <memory GB> <start> <end> <sequences> <context>
report_stage() {
  local w d bud ok
  read -r w d bud ok <<EOF
$(stage_fit "$2" "$3" "$4" "$5" "$6")
EOF
  log "$1 layers $3:$4 on ${2} GB: stage weights $(gib "$w") GiB, KV demand $(gib "$d") GiB, KV budget $(gib "$bud") GiB, fits by the CLI's rule: $ok"
}

# Weight files a stage of layers a:b needs (any file holding one of its layers;
# the embedding and the head travel with the first and last layer's files).
stage_weight_files() {
  local a="$1" b="$2" name first last
  while read -r name first last; do
    [ -n "$name" ] || continue
    [ "$last" -ge "$a" ] && [ "$first" -lt "$b" ] && echo "$name"
  done <<EOF
$MODEL_WEIGHT_LAYERS
EOF
}

# stage_files <a> <b>: "name size sha256" of every file the stage holds: the
# non-weight files and its weight files.
stage_files() {
  local want name size sha
  want=" $(stage_weight_files "$1" "$2" | tr '\n' ' ') "
  while read -r name size sha; do
    [ -n "$name" ] || continue
    case "$name" in
      *.safetensors) case "$want" in *" $name "*) ;; *) continue ;; esac ;;
    esac
    echo "$name $size $sha"
  done <<EOF
$MODEL_FILES
EOF
}

stage_download_bytes() { stage_files "$1" "$2" | awk '{ t += $2 } END { printf "%.0f\n", t }'; }

# check_memory_for <need bytes> <what>: stop unless this Mac has that much
# memory available now. Swap is never counted on.
check_memory_for() {
  local need="$1" what="$2" avail
  avail="$(available_mem_gb)"
  log "$what needs about $(gib "$need") GiB of memory; about ${avail} GiB is available now"
  awk -v a="$avail" -v n="$need" 'BEGIN { exit !(a * 1073741824 >= n) }' \
    || die "not enough free memory for $what: it needs about $(gib "$need") GiB and about ${avail} GiB is available. Another model or app holds the rest (on a provider Mac, its live model). Free memory and run again; this script never relies on swap and never stops another process"
}

# warn_gpu_limit <memory GB> <stage bytes>: the CLI caps MLX at 90% of the GPU
# working set macOS reports (MLXMemoryBudget.limitBytes). That set is a part of
# memory, not all of it, so a part that takes most of a Mac's memory may sit
# near the cap. Not measured for this model yet, so say so.
warn_gpu_limit() {
  awk -v g="$1" -v b="$2" 'BEGIN { exit !(b > g * 1073741824 * 0.6) }' || return 0
  warn "this part needs about $(gib "$2") GiB, more than 60% of this Mac's ${1} GB. The CLI limits MLX to 90% of the GPU memory macOS allows, which is below total memory. Whether this part loads and runs at full speed under that limit is not measured yet; if loading fails or is very slow, that limit is the first suspect"
}

# Margin on top of stage weights and KV for activations and the runtime, used
# only for the free-memory check above (the CLI's own fit rule has its 4 GiB).
RUNTIME_MARGIN_BYTES=2147483648

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
# 4 sequences of 4096 tokens: 5.0 GiB of KV for the whole 70B model, about
# 2.5 GiB per half, which leaves room on a 32 GB + 32 GB pair.
MAX_SEQUENCES_DEFAULT=4
MAX_CONTEXT_DEFAULT=4096
MODEL_DEFAULT=big
HEAD_MEMORY_GB_DEFAULT=32

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

# check_host <workdir> <min free disk GB>. Free memory is checked against the
# stage's need with check_memory_for once the split is known.
check_host() {
  local root="$1" min_disk="$2"
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
  [ "$disk" -ge "$min_disk" ] || die "this needs ${min_disk} GB of free disk in $root for its part of the model (found ${disk} GB)"
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

# fetch_model <root> <layer start> <layer end>; sets MODEL_DIR to the verified
# files this stage loads, and MANIFEST_PATH to the snapshot manifest (empty for
# a whole snapshot, which the CLI hashes whole).
fetch_model() {
  if [ "$MODEL_STAGE_ONLY" = 1 ]; then fetch_model_stage "$@"; else MANIFEST_PATH=""; fetch_model_whole "$1"; fi
}

# The serve flags that name the model. A stage-only folder is checked by the
# CLI file by file against the manifest whose SHA-256 is MODEL_HASH
# (MacProviderCLI.swift shardStagePreflight); that needs the hash on the
# command line. A whole snapshot is hashed whole by the CLI.
model_serve_flags() {
  if [ -n "$MANIFEST_PATH" ]; then
    printf '%s\n' --model "$MODEL_DIR" --model-artifact-path "$MODEL_DIR" --model-artifact-sha256 "$MODEL_HASH"
  else
    printf '%s\n' --model "$MODEL_DIR"
  fi
}

# ,"snapshot_manifest":"..." for a shard config, or nothing.
snapshot_manifest_json() { [ -z "$MANIFEST_PATH" ] || printf ',"snapshot_manifest":"%s"' "$MANIFEST_PATH"; }

# fetch_model_stage <root> <a> <b>: download only the files layers a:b need
# into their own folder, check every size and SHA-256 against the pinned list,
# and write the full snapshot manifest beside the folder. The folder must hold
# nothing else: the CLI refuses any file that is not a manifest entry.
fetch_model_stage() {
  local root="$1" a="$2" b="$3"
  local base="$root/$MODEL_BASE_REL" name size sha got bytes
  mkdir -p "$base"
  MANIFEST_PATH="$base/snapshot-manifest.txt"
  # macprovider.snapshot-manifest.v1: "path\nsize\nsha256\n" for every file of
  # the snapshot, sorted by path (the pinned list is sorted).
  while read -r name size sha; do
    [ -n "$name" ] && printf '%s\n%s\n%s\n' "$name" "$size" "$sha"
  done >"$MANIFEST_PATH.tmp" <<EOF
$MODEL_FILES
EOF
  [ "$(shasum -a 256 "$MANIFEST_PATH.tmp" | awk '{ print $1 }')" = "$MODEL_HASH" ] \
    || { rm -f "$MANIFEST_PATH.tmp"; die "the pinned file list does not hash to $MODEL_HASH; common.sh is inconsistent"; }
  mv "$MANIFEST_PATH.tmp" "$MANIFEST_PATH"
  MODEL_DIR="$base/stage-$a-$b"
  bytes="$(stage_download_bytes "$a" "$b")"
  if [ -d "$MODEL_DIR" ] && [ -f "$MODEL_DIR.verified" ]; then
    # Sizes here; the CLI checks every SHA-256 again before it loads.
    local ok=1
    while read -r name size sha; do
      [ -n "$name" ] || continue
      [ "$(stat -f %z "$MODEL_DIR/$name" 2>/dev/null)" = "$size" ] || ok=0
    done <<EOF
$(stage_files "$a" "$b")
EOF
    if [ "$ok" = 1 ]; then log "layers $a:$b of $MODEL_REPO already downloaded ($(gb "$bytes") GB): $MODEL_DIR"; return 0; fi
    warn "the files on disk for layers $a:$b are incomplete; downloading them again"
    rm -rf "$MODEL_DIR" "$MODEL_DIR.verified"
  fi
  local stage="$base/.staging-$a-$b"
  mkdir -p "$stage"
  log "downloading layers $a:$b of $MODEL_REPO from HuggingFace: $(gb "$bytes") GB of $(gb "$(stage_download_bytes 0 "$MODEL_LAYERS")") GB"
  log "files: $(stage_weight_files "$a" "$b" | tr '\n' ' ')plus config and tokenizer files"
  log "at 100 Mbit/s this takes about $(awk -v b="$bytes" 'BEGIN { printf "%d", b * 8 / 100e6 / 60 + 1 }') minutes, at 1 Gbit/s about $(awk -v b="$bytes" 'BEGIN { printf "%d", b * 8 / 1e9 / 60 + 1 }'); an interrupted download resumes on the next run"
  while read -r name size sha; do
    [ -n "$name" ] || continue
    if [ -f "$stage/$name" ] && [ "$(stat -f %z "$stage/$name")" = "$size" ]; then continue; fi
    curl -fL --retry 5 -C - --progress-bar -o "$stage/$name" \
      "https://huggingface.co/$MODEL_REPO/resolve/$MODEL_REV/$name" || die "could not download $name"
    got="$(stat -f %z "$stage/$name")"
    [ "$got" = "$size" ] || die "$name has $got bytes, expected $size"
  done <<EOF
$(stage_files "$a" "$b")
EOF
  log "checking the SHA-256 of every file (about a minute per 10 GB)"
  while read -r name size sha; do
    [ "$(shasum -a 256 "$stage/$name" | awk '{ print $1 }')" = "$sha" ] || { rm -f "$stage/$name"; die "$name failed its SHA-256 check; run again"; }
  done <<EOF
$(stage_files "$a" "$b")
EOF
  mv "$stage" "$MODEL_DIR"
  : >"$MODEL_DIR.verified"
  log "layers $a:$b verified against $MODEL_VERIFICATION: $MODEL_DIR"
}

# fetch_model_whole <root>; sets MODEL_DIR to the verified snapshot.
fetch_model_whole() {
  local root="$1"
  if [ -f "$REPO_ROOT/phase3-binary/catalog/autotune/tier2-identity-binding.json" ]; then
    grep -q "$MODEL_HASH" "$REPO_ROOT/phase3-binary/catalog/autotune/tier2-identity-binding.json" \
      || die "the pinned model hash is not in this checkout's catalog binding; update common.sh"
  fi
  local base="$root/$MODEL_BASE_REL"
  MODEL_DIR="$base/$MODEL_HASH"
  if [ -d "$MODEL_DIR" ]; then
    log "checking the model already on disk (about 10 s)"
    [ "$(manifest_hash "$MODEL_DIR")" = "$MODEL_HASH" ] && { log "model verified: $MODEL_REPO@$MODEL_REV"; return 0; }
    warn "the model on disk does not match; downloading it again"
    rm -rf "$MODEL_DIR"
  fi
  local stage="$base/.staging" name size lfs got
  mkdir -p "$stage"
  log "downloading $MODEL_REPO ($(gb "$(stage_download_bytes 0 "$MODEL_LAYERS")") GB) from HuggingFace"
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
