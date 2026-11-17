#!/bin/bash
# Runs ON THE STUDIO, started detached by studio-ablit-perf.sh. The baseline check of the
# abliterated-perf swarm run: for each model, the Python reference and our provider on the
# same parity-grid prompts in one window, then a noise pass, then baseline.md.
#
# Steps:
#  1. lab-harness release build of the rsynced campaign tree (~/lab-ablit-perf/src), the
#     release metallib copied beside the binary;
#  2. stage every model before any GPU work, so a missing input fails in minutes: APFS
#     clones (`cp -c`, the source is only read) into ~/lab-ablit-perf/models verified
#     against the catalog snapshot-manifest hash, Hugging Face downloads checked per file,
#     the reference venvs, and for <K>_MTP_BENCH=1 the native-mtp-bench policy, validated
#     without MLX use;
#  3. per model, the reference first (its first cell is the cheapest: short context,
#     128 tokens), then scripts/lab/parity-grid/run-grid.sh on the production route
#     (`stock` in window.sh: no autotune flag, batching auto), the snapshot served under
#     its catalog id when it has one, else by path. A model with <K>_CB_FROM_POLICY=1 gets
#     its signed CB policy tuple as the --no-join serve's accepted tuple and must show
#     batched admissions; every other model is served serially, so its 4-row cells only
#     queue and run 1 trial (<K>_TRIALS_BY_ROWS, default 4=1);
#  4. <K>_BASE_PATH set: one 1-row pass of the unmodified base in our runtime. With
#     <K>_BASE_REFERENCE=1 (default for qwen27) the same reference kind, venv and flags
#     also run on the BASE weights over those 1-row cells (BASE_TRIALS trials), and the base
#     pass is compared with that reference (baseline.md: "base model: our provider vs
#     reference on the same base weights"); without it the base pass reuses the main
#     model's reference. Extra time for a 27B at ~30 tok/s: 3 contexts x (128+512+2048)
#     = 8064 tokens, ~4.5 min decode, plus prefill and a model load: ~10 min;
#  5. <K>_MTP_BENCH=1: native-mtp-bench on the lab harness, native MTP against ordinary,
#     s1 x prompt 1536/4096 x output 128/512, one process per cell, under an exploratory
#     policy with 5 paired blocks (below the R015 gate: baseline only);
#  6. at the end, per model: the short-context 1-row cells again on a fresh serve, compared
#     with compare.py --baseline (run-to-run spread and identity);
#  7. baseline_md.py writes RES/<name>/baseline.md.
#
# Models: MODELS="qwen27 glm minimax" (default). A model key K reads <K>_NAME, <K>_PATH,
# <K>_ID, <K>_SHA256 (ID optional; without it the snapshot is served by path), <K>_REF
# (mlx-lm|mlx-vlm), <K>_REF_PY, <K>_REF_PATH, <K>_REF_ARGS, <K>_ROWS, <K>_TRIALS_BY_ROWS,
# <K>_CB_FROM_POLICY, <K>_CONFIG_EXTRA, <K>_BASE_PATH/_BASE_ID/_BASE_SHA256/_BASE_REFERENCE and the
# staging fields: <K>_CLONE_FROM (PATH = APFS clone of it, verified against SHA256),
# <K>_BASE_CLONE_FROM (the same for BASE_PATH), <K>_HF_REPO/_HF_REVISION/_HF_SUBFOLDER
# (download one subfolder into PATH), <K>_STAGE_REPO/_STAGE_REVISION (PATH = APFS clone
# of BASE_PATH plus the published repo's non-shard files, verified against SHA256) and
# <K>_MTP_BENCH/_MTP_TEMPLATE. Built-in defaults exist for qwen27, glm, minimax and dsv4abl
# (the abliterated DeepSeek V4-Flash that job-dsv4-abliterated.sh splices; not in MODELS by default).
# Grid: OUTPUTS (128,512,2048), CONTEXTS (short,4k,16k), TRIALS (3), BASE_TRIALS (1).
#
# Every failure prints a `BLOCKER:` line; the job ends with JOB_PASS (exit 0) or JOB_FAIL
# (nonzero). Speed slower than the reference is a finding, not a failure.
set -u
export PATH=/usr/sbin:/opt/homebrew/bin:/usr/bin:/bin
LAB=$HOME/lab-ablit-perf
JOB=$LAB/job
GRID=$JOB/parity-grid
SRC=$LAB/src/phase3-binary
STORE="$HOME/Library/Application Support/macprovider/models"
RUN_ID=${RUN_ID:-$(date -u +%Y%m%dT%H%M%SZ)}
RES=$LAB/results/$RUN_ID
MODELS=${MODELS:-qwen27 glm minimax}
OUTPUTS=${OUTPUTS:-128,512,2048}
CONTEXTS=${CONTEXTS:-short,4k,16k}
TRIALS=${TRIALS:-3}
BASE_TRIALS=${BASE_TRIALS:-1}
METALLIB=${METALLIB:-/Applications/Malibu.app/Contents/MacOS/mlx.metallib}
BIN=$SRC/.build-lab-harness/release
MTP_CELLS="s1-p1536-o128 s1-p1536-o512 s1-p4096-o128 s1-p4096-o512"
FAILED=0
log() { echo "$(date '+%H:%M:%S') $*"; }
blocker() { log "BLOCKER: $*"; FAILED=1; }
die() { log "BLOCKER: $*"; log "JOB_FAIL"; exit "${2:-1}"; }
mkdir -p "$RES"

# store_dir REPO_DIR SHA: the provider-store snapshot directory of that artifact (read only).
store_dir() {
  local d
  for d in "$STORE/$1"/*/"$2"; do [ -d "$d" ] && { echo "$d"; return; }; done
  echo "$STORE/$1/<revision>/$2"
}

# Built-in model defaults (catalog rows of autotune-candidates.json).
: "${QWEN27_NAME:=qwen3.8-27b-uncensored}"
: "${QWEN27_PATH:=$LAB/models/Qwen3.8-27B-Uncensored-MLX-4bit}"
: "${QWEN27_HF_REPO:=orcarouter/Qwen3.8-27B-Uncensored-MLX}"
: "${QWEN27_HF_REVISION:=a92a9d3492320048ca96924262d158f75ab5ce8b}"
: "${QWEN27_HF_SUBFOLDER:=4-bit}"
: "${QWEN27_REF:=mlx-lm}"
: "${QWEN27_BASE_ID:=qwen/qwen3.8-27b}"
: "${QWEN27_BASE_SHA256:=8a8786e902127e9175f5be0d7c8bcf4dd32323a0521e4d9a20761608a07a6d05}"
: "${QWEN27_BASE_PATH:=$LAB/models/Qwen3.8-27B-4bit}"
: "${QWEN27_BASE_REFERENCE:=1}"
: "${QWEN27_BASE_CLONE_FROM:=$(store_dir mlx-community--Qwen3.8-27B-4bit "$QWEN27_BASE_SHA256")}"
: "${GLM_NAME:=glm53-flash-uncensored}"
: "${GLM_ID:=zai-org/glm-5.3-flash-uncensored}"
: "${GLM_SHA256:=242f8fcfd34d4ecfd62180c1767f910bda925216948772126dc98c673d1c8919}"
: "${GLM_PATH:=$LAB/models/GLM-5.3-Flash-UNCENSORED-mlx-oQ4e-DFlash2}"
: "${GLM_CLONE_FROM:=$(store_dir Solstice-AI--GLM-5.3-Flash-UNCENSORED-mlx-oQ4e-DFlash2 "$GLM_SHA256")}"
: "${GLM_REF:=mlx-vlm}"
: "${GLM_CB_FROM_POLICY:=1}"
: "${GLM_MTP_BENCH:=1}"
: "${MINIMAX_NAME:=minimax-m3.1-flash-abliterated}"
: "${MINIMAX_ID:=minimaxai/minimax-m3.1-flash-abliterated}"
: "${MINIMAX_SHA256:=795d9cf46799deb2cf61822acfbf8586aa946fcaa880686e86be3ca77280368a}"
: "${MINIMAX_PATH:=$LAB/models/MiniMax-M3.1-Flash-oQ3e-mtp-abliterated}"
: "${MINIMAX_STAGE_REPO:=aug11/MiniMax-M3.1-Flash-oQ3e-mtp-abliterated}"
: "${MINIMAX_STAGE_REVISION:=e45ff82cab94d9ecb46a86b12b891eeba3d1e198}"
: "${MINIMAX_BASE_PATH:=$HOME/lab-2189/models/mlx-community--MiniMax-M3.1-Flash-oQ3e-mtp}"
: "${MINIMAX_BASE_ID:=minimaxai/minimax-m3.1-flash}"
: "${MINIMAX_BASE_SHA256:=21188ee28f031b9444e8a250e16aea57ee37a0c2f8d1a24c2ad44686ad744f03}"
: "${MINIMAX_REF:=mlx-vlm}"
: "${MINIMAX_REF_PATH:=$MINIMAX_BASE_PATH}"
: "${MINIMAX_REF_ARGS:=--refusal-ablation $MINIMAX_PATH}"
: "${DSV4ABL_NAME:=deepseek-v4-flash-abliterated}"
: "${DSV4ABL_PATH:=$LAB/models/DeepSeek-V4-Flash-0731-abliterated-MXFP4-MLX}"  # made by job-dsv4-abliterated.sh
: "${DSV4ABL_REF:=mlx-vlm}"
: "${DSV4ABL_BASE_ID:=deepseek/deepseek-v4-flash}"
: "${DSV4ABL_BASE_SHA256:=58ee40d4c0bc436695d1d8d6a6cdfdb0326ec37f25e13ec98ea1d5c0878e732c}"
: "${DSV4ABL_BASE_PATH:=$LAB/models/DeepSeek-V4-Flash-0731-MXFP4-MLX}"
: "${DSV4ABL_BASE_CLONE_FROM:=$(store_dir TensorFold--DeepSeek-V4-Flash-0731-MXFP4-MLX "$DSV4ABL_BASE_SHA256")}"

# v K FIELD: the value of <K>_FIELD (empty when unset); setv K FIELD VALUE sets it.
kname() { echo "$(echo "$1" | tr 'a-z-' 'A-Z_')_$2"; }
v() { local n; n=$(kname "$1" "$2"); echo "${!n:-}"; }
setv() { printf -v "$(kname "$1" "$2")" '%s' "$3"; }
under_models() { case $1 in "$LAB"/models/?*) return 0 ;; *) return 1 ;; esac; }

log "JOB_START run=$RUN_ID commit=${COMMIT:-unknown} models=\"$MODELS\" outputs=$OUTPUTS contexts=$CONTEXTS trials=$TRIALS"
if lsof -nP -iTCP:8080 -sTCP:LISTEN -t >/dev/null 2>&1; then die "a server listens on :8080; the Studio is not paused" 3; fi
launchctl print "gui/$(id -u)/live.malibu.provider" >/dev/null 2>&1 && die "live.malibu.provider is loaded" 3
pgrep -f "[m]acprovider-cli serve" >/dev/null 2>&1 && die "a macprovider-cli serve process runs" 3

# Preflight every model before the build, so a missing input fails in seconds.
for k in $MODELS; do
  for f in NAME REF; do [ -n "$(v "$k" $f)" ] || die "model $k: <K>_$f unset" 64; done
  [ -z "$(v "$k" ID)" ] || [ -n "$(v "$k" SHA256)" ] || die "model $k: ID needs SHA256" 64
  case "$(v "$k" REF)" in mlx-lm|mlx-vlm) ;; *) die "model $k: REF must be mlx-lm|mlx-vlm" 64 ;; esac
  if [ -n "$(v "$k" CLONE_FROM)" ]; then
    [ -f "$(v "$k" CLONE_FROM)/config.json" ] || die "model $k: no snapshot to clone at $(v "$k" CLONE_FROM)" 11
    [ -n "$(v "$k" SHA256)" ] || die "model $k: CLONE_FROM needs SHA256" 64
    under_models "$(v "$k" PATH)" || die "model $k: a cloned PATH must lie under $LAB/models" 64
  elif [ -n "$(v "$k" STAGE_REPO)" ]; then
    [ -f "$(v "$k" BASE_PATH)/config.json" ] || die "model $k: no base snapshot at $(v "$k" BASE_PATH)" 11
    [ -n "$(v "$k" STAGE_REVISION)" ] || die "model $k: STAGE_REPO needs STAGE_REVISION" 64
    under_models "$(v "$k" PATH)" || die "model $k: a staged PATH must lie under $LAB/models" 64
  elif [ -n "$(v "$k" HF_REPO)" ]; then
    [ -n "$(v "$k" HF_REVISION)" ] || die "model $k: HF_REPO needs HF_REVISION" 64
    under_models "$(v "$k" PATH)" || die "model $k: a downloaded PATH must lie under $LAB/models" 64
  else
    [ -f "$(v "$k" PATH)/config.json" ] || die "model $k: no snapshot at $(v "$k" PATH)" 11
  fi
  if [ -n "$(v "$k" BASE_CLONE_FROM)" ]; then
    [ -f "$(v "$k" BASE_CLONE_FROM)/config.json" ] || die "model $k: no base snapshot to clone at $(v "$k" BASE_CLONE_FROM)" 11
    under_models "$(v "$k" BASE_PATH)" || die "model $k: a cloned BASE_PATH must lie under $LAB/models" 64
  fi
  rp=$(v "$k" REF_PATH); [ -z "$rp" ] || [ -f "$rp/config.json" ] || die "model $k: no reference snapshot at $rp" 11
  [ -z "$(v "$k" BASE_PATH)" ] || { [ -n "$(v "$k" BASE_SHA256)" ] && [ -n "$(v "$k" BASE_ID)" ]; } \
    || die "model $k: BASE_PATH needs BASE_ID and BASE_SHA256" 64
  if [ "$(v "$k" MTP_BENCH)" = 1 ]; then
    [ -n "$(v "$k" ID)" ] || die "model $k: MTP_BENCH needs ID" 64
    [ -n "$(v "$k" MTP_TEMPLATE)" ] || setv "$k" MTP_TEMPLATE "$JOB/mtp/r015-p32k-window.json"
    [ -f "$(v "$k" MTP_TEMPLATE)" ] || die "model $k: no native-mtp-bench policy template at $(v "$k" MTP_TEMPLATE)" 11
    echo "${COMMIT:-}" | grep -Eq '^[0-9a-f]{40}$' || die "model $k: MTP_BENCH needs COMMIT (40-hex provider commit)" 64
  fi
  [ -n "$(v "$k" TRIALS_BY_ROWS)" ] || [ "$(v "$k" CB_FROM_POLICY)" = 1 ] || setv "$k" TRIALS_BY_ROWS "4=1"
done

ref_python() {  # ref_python KIND: a pinned venv per reference kind, created once
  local kind=$1 venv pkgs
  case $kind in
    mlx-vlm) venv=$LAB/venv-vlm; pkgs="mlx-vlm==0.7.11 mlx==0.32.4" ;;
    mlx-lm) venv=$LAB/venv-lm; pkgs="mlx-lm==0.32.2 mlx==0.32.4" ;;
  esac
  local mod=${kind//-/_}
  if ! "$venv/bin/python" -c "import $mod" >/dev/null 2>&1; then
    local py; py=$(command -v python3.12 || echo /opt/homebrew/bin/python3.12)
    [ -x "$py" ] || { echo "python3.12 not found" >&2; return 1; }
    "$py" -m venv "$venv" && "$venv/bin/pip" install -q $pkgs > "$RES/venv-$kind.log" 2>&1 || return 1
  fi
  echo "$venv/bin/python"
}

# 1. Build.
if [ "${SKIP_BUILD:-0}" != 1 ]; then
  log "BUILD_START"
  (cd "$SRC" && nice -n 10 swift build -c release --product macprovider-cli --build-path .build-lab-harness \
    -Xswiftc -DMACPROVIDER_LAB_HARNESS) > "$RES/build.log" 2>&1 || die "swift build failed: $(tail -n 3 "$RES/build.log" | tr '\n' ' ')" 14
fi
[ -x "$BIN/macprovider-cli" ] || die "no lab-harness binary at $BIN" 14
[ -f "$METALLIB" ] || die "no metallib at $METALLIB" 14
cp "$METALLIB" "$BIN/mlx.metallib" || die "metallib copy failed" 14
METALLIB_SHA=$(shasum -a 256 "$BIN/mlx.metallib" | cut -d' ' -f1)
shasum -a 256 "$BIN/macprovider-cli" "$BIN/mlx.metallib" > "$RES/identity.sha256"
log "BUILD_DONE $("$BIN/macprovider-cli" --version 2>&1 | head -n 1) cli_sha256=$(cut -c1-16 "$RES/identity.sha256" | head -n 1) metallib_sha256=$METALLIB_SHA"

manifest() {  # macprovider.snapshot-manifest.v1 of DIR, the catalog's model_sha256
  /usr/bin/python3 -I -c 'import sys,pathlib; sys.path.insert(0, sys.argv[1])
from publish_abliterated import snapshot_manifest_sha256 as m; print(m(pathlib.Path(sys.argv[2])))' "$JOB/minimax" "$1"
}

# clone_verify FROM DEST SHA LABEL: DEST = APFS clone of FROM (no extra disk; FROM is only
# read), verified against the catalog snapshot-manifest hash SHA.
clone_verify() {
  local from=$1 dest=$2 want=$3 label=$4 got
  under_models "$dest" || { blocker "$label: $dest is not under $LAB/models"; return 1; }
  if [ -d "$dest" ] && [ "$(manifest "$dest" 2>/dev/null)" = "$want" ]; then
    log "CLONE_OK $label manifest=$want (existing)"
    return 0
  fi
  log "CLONE_START $label from $from"
  rm -rf -- "$dest" && mkdir -p "$(dirname "$dest")" && /bin/cp -c -R "$from" "$dest" \
    || { blocker "$label: APFS clone of $from failed"; return 1; }
  got=$(manifest "$dest") || { blocker "$label: manifest of $dest failed"; return 1; }
  [ "$got" = "$want" ] || { blocker "$label: clone manifest $got is not the catalog artifact $want"; return 1; }
  log "CLONE_OK $label manifest=$got"
}

# materialize K: <K>_PATH = APFS clone of the base + the published repo's non-shard files.
materialize() {
  local k=$1 stage base repo rev want got
  stage=$(v "$k" PATH); base=$(v "$k" BASE_PATH); repo=$(v "$k" STAGE_REPO); rev=$(v "$k" STAGE_REVISION); want=$(v "$k" SHA256)
  if [ -d "$stage" ] && [ "$(manifest "$stage" 2>/dev/null)" = "$want" ]; then
    log "STAGE_OK $k manifest=$want (existing)"
    return 0
  fi
  log "STAGE_BUILD $k from $base + $repo@$rev"
  rm -rf -- "$stage" && mkdir -p "$(dirname "$stage")" && /bin/cp -c -R "$base" "$stage" || { blocker "model $k: clone failed"; return 1; }
  rm -rf -- "$stage/.cache"
  /usr/bin/python3 -I - "$repo" "$rev" "$stage" <<'PY' || { blocker "model $k: published files fetch failed"; return 1; }
import json, os, re, sys, urllib.request
repo, rev, stage = sys.argv[1:4]
api = f"https://huggingface.co/api/models/{repo}/revision/{rev}"
names = [s["rfilename"] for s in json.load(urllib.request.urlopen(api, timeout=60))["siblings"]]
shard = re.compile(r"^model-\d{5}-of-\d{5}\.safetensors$")
for name in names:
    if shard.match(name) or name.startswith(".") or name == ".gitattributes":
        continue
    dest = os.path.join(stage, name)
    os.makedirs(os.path.dirname(dest), exist_ok=True)
    if os.path.lexists(dest):
        os.unlink(dest)  # break the clone before writing
    with urllib.request.urlopen(f"https://huggingface.co/{repo}/resolve/{rev}/{name}", timeout=600) as r, open(dest, "wb") as f:
        while chunk := r.read(8 << 20):
            f.write(chunk)
    print("fetched", name, os.path.getsize(dest))
for root, _, files in os.walk(stage):
    for fn in files:
        rel = os.path.relpath(os.path.join(root, fn), stage)
        if rel not in names:
            os.unlink(os.path.join(stage, rel))  # our clone only: the published repo lacks it
            print("removed file not in the published repo:", rel)
PY
  got=$(manifest "$stage") || { blocker "model $k: manifest of $stage failed"; return 1; }
  [ "$got" = "$want" ] || { blocker "model $k: stage manifest $got is not the catalog artifact $want"; return 1; }
  log "STAGE_OK $k manifest=$got"
}

# hf_fetch K: <K>_PATH = <K>_HF_SUBFOLDER of <K>_HF_REPO at <K>_HF_REVISION, every file
# checked (LFS sha256, else git blob sha1); files already present and correct are kept.
hf_fetch() {
  local k=$1 dest name
  dest=$(v "$k" PATH); name=$(v "$k" NAME)
  log "DOWNLOAD_START $k $(v "$k" HF_REPO)@$(v "$k" HF_REVISION)/$(v "$k" HF_SUBFOLDER)"
  mkdir -p "$RES/$name"
  /usr/bin/python3 -I - "$(v "$k" HF_REPO)" "$(v "$k" HF_REVISION)" "$(v "$k" HF_SUBFOLDER)" "$dest" \
    > "$RES/$name/download.log" 2>&1 <<'PY' || { blocker "model $k: download failed: $(tail -n 2 "$RES/$name/download.log" | tr '\n' ' ')"; return 1; }
import hashlib, json, os, sys, urllib.parse, urllib.request
repo, rev, sub, dest = sys.argv[1:5]
meta = json.load(urllib.request.urlopen(f"https://huggingface.co/api/models/{repo}/revision/{rev}?blobs=true", timeout=60))
sha = meta["sha"]
if not sha.startswith(rev):
    sys.exit(f"revision {rev} resolved to {sha}")
prefix = sub.strip("/") + "/" if sub else ""
files = [s for s in meta["siblings"] if s["rfilename"].startswith(prefix) and not s["rfilename"].endswith(".gitattributes")]
if not files:
    sys.exit(f"no files under {prefix!r} in {repo}@{sha}")

def ok(path, s):
    if s.get("lfs"):
        h, want = hashlib.sha256(), s["lfs"]["sha256"]
    elif s.get("blobId"):
        h, want = hashlib.sha1(b"blob %d\0" % os.path.getsize(path)), s["blobId"]
    else:
        sys.exit(f"{s['rfilename']}: the API gives no checksum")
    with open(path, "rb") as f:
        while chunk := f.read(16 << 20):
            h.update(chunk)
    return h.hexdigest() == want

os.makedirs(dest, exist_ok=True)
for s in files:
    rel = s["rfilename"][len(prefix):]
    out = os.path.join(dest, rel)
    if os.path.exists(out) and ok(out, s):
        print("present", rel)
        continue
    os.makedirs(os.path.dirname(out), exist_ok=True)
    part = out + ".part"
    url = f"https://huggingface.co/{repo}/resolve/{sha}/{urllib.parse.quote(s['rfilename'])}"
    with urllib.request.urlopen(url, timeout=600) as r, open(part, "wb") as f:
        while chunk := r.read(8 << 20):
            f.write(chunk)
    if not ok(part, s):
        sys.exit(f"{rel}: checksum mismatch after download")
    os.replace(part, out)
    print("fetched", rel, os.path.getsize(out))
print("resolved", sha, len(files), "files")
PY
  log "DOWNLOAD_OK $k $(tail -n 1 "$RES/$name/download.log") manifest=$(manifest "$dest" 2>/dev/null)"
}

# mtp_bench K ARGS...: native-mtp-bench on the lab harness against <K>'s fixture and policy.
mtp_bench() {
  local k=$1; shift
  (cd "$BIN" && env MACPROVIDER_NATIVE_MTP_E2E=1 ./macprovider-cli native-mtp-bench --root "$(v "$k" MTP_FIXTURE)" \
    --model-id "$(v "$k" ID)" --policy "$RES/$(v "$k" NAME)/mtp/policy.json" --provider-commit "$COMMIT" "$@")
}

# mtp_prepare K: fixture (FIXTURE/target = APFS clone of <K>_PATH), the exploratory policy
# (the committed template with 5 blocks, this row's identities and this machine), and a
# --validate-policy-only run. An environment mismatch the validator names (machine, OS,
# toolchain, fork pin) is taken from its `observed=` value; artifact identities are not.
mtp_prepare() {
  local k=$1 name dir fixture xcode swift fork i err
  name=$(v "$k" NAME); dir=$RES/$name/mtp; fixture=$LAB/models/$name-mtp-fixture
  mkdir -p "$dir"
  rm -rf -- "$fixture" && mkdir -p "$fixture" && /bin/cp -c -R "$(v "$k" PATH)" "$fixture/target" \
    || { blocker "model $k: MTP fixture clone failed"; return 1; }
  setv "$k" MTP_FIXTURE "$fixture"
  xcode=$(/usr/bin/xcodebuild -version 2>/dev/null | sed -n 's/^Build version //p' | head -n 1)
  swift=$(/usr/bin/xcrun swift --version 2>/dev/null | head -n 1)
  fork=$(sed -n 's/.*static let mlxSwiftLMRevision = "\([0-9a-f]*\)".*/\1/p' "$SRC/Sources/macprovider-cli/KVConversationColdTierAdapter.swift")
  /usr/bin/python3 -I - "$(v "$k" MTP_TEMPLATE)" "$dir/policy.json" "$(v "$k" ID)" "$(v "$k" SHA256)" \
    "$(shasum -a 256 "$fixture/target/tokenizer.json" | cut -d' ' -f1)" "$(sysctl -n hw.model)" "$(sysctl -n kern.osversion)" \
    "${xcode:-unknown}" "${swift:-unknown}" "$COMMIT" "$fork" <<'PY' || { blocker "model $k: MTP policy generation failed"; return 1; }
import json, sys
src, out, model_id, sha, tok, hw, osb, xcode, swift, commit, fork = sys.argv[1:12]
p = json.load(open(src))
if p["schema"] != "macprovider.native-mtp-exploratory-policy.v1":
    sys.exit(f"{src} is not an exploratory policy")
if len(fork) != 40:
    sys.exit("mlxSwiftLMRevision not found in the source tree")
p.update({"blocks": 5, "slots": [1], "prompt_tokens": [1536, 4096], "max_tokens": [128, 512],
          "sustained_cell_id": "s1-p1536-o512", "sustained_seconds": 0, "model_id": model_id,
          "target_sha256": sha, "mtp_sha256": sha, "tokenizer_sha256": tok, "hw_model": hw, "os_build": osb,
          "xcode_build_version": xcode, "swift_version": swift, "provider_commit": commit,
          "mlx_fork_revision": fork})
json.dump(p, open(out, "w"), indent=2, sort_keys=True)
PY
  for i in 1 2 3 4 5 6 7 8; do
    mtp_bench "$k" --out "$dir/validate.jsonl" --validate-policy-only --identity-cache "$LAB/mtp-identity-cache.json" \
      > "$dir/validate.out" 2> "$dir/validate.err" && { log "MTP_VALIDATED $name policy_sha256=$(shasum -a 256 "$dir/policy.json" | cut -c1-16)"; return 0; }
    err=$(cat "$dir/validate.out" "$dir/validate.err")
    /usr/bin/python3 -I - "$dir/policy.json" "$err" <<'PY' || { blocker "model $k: native-mtp-bench refuses the policy: $(echo "$err" | tr '\n' ' ' | cut -c1-400)"; return 1; }
import json, re, sys
path, err = sys.argv[1:3]
m = re.search(r"\b(hw_model|chip|ram_gb|os_build|xcode_build_version|swift_version|mlx_fork_revision) mismatch: "
              r"frozen=(.*) observed=(.*)$", err, re.M)
if not m:
    sys.exit(1)
key, observed = m.group(1), m.group(3).strip()
p = json.load(open(path))
p[key] = int(observed) if key == "ram_gb" else observed
json.dump(p, open(path, "w"), indent=2, sort_keys=True)
print(f"policy {key} set to the observed {observed!r}")
PY
  done
  blocker "model $k: native-mtp-bench policy still refused after 8 environment fixes"; return 1
}

# mtp_run K: the four cells, one process each (one 186 GB target resident at a time).
mtp_run() {
  local k=$1 name dir cell rc ok=1
  name=$(v "$k" NAME); dir=$RES/$name/mtp
  shasum -a 256 "$BIN/macprovider-cli" "$BIN/mlx.metallib" "$dir/policy.json" > "$dir/identity.sha256"
  for cell in $MTP_CELLS; do
    log "MTP_CELL_START $name $cell"
    mtp_bench "$k" --out "$dir/bench.jsonl" --only-cell "$cell" --phase matrix > "$dir/$cell.out" 2> "$dir/$cell.log"
    rc=$?
    log "MTP_CELL_DONE $name $cell rc=$rc records=$(wc -l < "$dir/bench.jsonl" 2>/dev/null | tr -d ' ')"
    [ $rc = 0 ] || { blocker "model $k: native-mtp-bench $cell rc=$rc: $(tail -n 2 "$dir/$cell.log" | tr '\n' ' ' | cut -c1-300)"; ok=0; }
  done
  /usr/bin/python3 -I "$JOB/mtp/native_mtp_r015_analyze.py" "$dir/bench.jsonl" "$dir/policy.json" > "$dir/analysis.json" 2> "$dir/analysis.err"
  /usr/bin/python3 -I "$JOB/mtp/native_mtp_r015_analyze.py" "$dir/bench.jsonl" "$dir/policy.json" --format markdown > "$dir/analysis.md" 2>> "$dir/analysis.err"
  # An exploratory policy ends EXPLORATORY_NO_VERDICT (rc 1): the JSON must parse, the rc is not a gate.
  /usr/bin/python3 -I -c 'import json,sys; print(json.load(open(sys.argv[1])).get("overall_status"))' "$dir/analysis.json" \
    > "$dir/analysis.status" 2>/dev/null || { blocker "model $k: the R015 analyzer output is unreadable: $(head -c 300 "$dir/analysis.err")"; ok=0; }
  log "MTP_DONE $name analyzer=$(cat "$dir/analysis.status" 2>/dev/null) (exploratory, 5 blocks: below the R015 gate, baseline only)"
  [ $ok = 1 ]
}

# cb_extra K FILE: the signed CB policy entry of <K>_ID as a --no-join accepted tuple.
cb_extra() {
  /usr/bin/python3 -I - "$JOB/catalog/continuous-batching-policy.json" "$(v "$1" ID)" "$METALLIB_SHA" > "$2" <<'PY'
import json, sys
policy, model_id, metallib = sys.argv[1:4]
entries = [e for e in json.load(open(policy))["entries"] if e["model_id"] == model_id]
if len(entries) != 1:
    sys.exit(f"{len(entries)} signed CB entries for {model_id}")
e = entries[0]
if e["metallib_sha256"] != metallib:
    sys.exit(f"metallib {metallib} is not the tuple's {e['metallib_sha256']}: the CB tuple cannot match")
keys = ("model_id", "model_sha256", "tokenizer_sha256", "chat_template_sha256", "cache_class", "kv_dtype",
        "requires_moe", "hardware_class", "metallib_sha256", "kernel_identifier", "cached_turns_accepted")
print("continuous_batching: canary")
print("continuous_batching_cached_turns: true")
print(f"max_concurrency_override: {e.get('max_served_slots', 4)}")
print("continuous_batching_accepted_tuples:")
print("  - {" + ", ".join(f"{k}: {json.dumps(e[k])}" for k in keys) + "}")
PY
}

# 2. Stage every model: inputs, reference venvs and the MTP policy, before any GPU work.
STAGED=""
stage_model() {
  local k=$1 py
  if [ -n "$(v "$k" BASE_CLONE_FROM)" ]; then
    clone_verify "$(v "$k" BASE_CLONE_FROM)" "$(v "$k" BASE_PATH)" "$(v "$k" BASE_SHA256)" "$k base" || return 1
  fi
  if [ -n "$(v "$k" CLONE_FROM)" ]; then
    clone_verify "$(v "$k" CLONE_FROM)" "$(v "$k" PATH)" "$(v "$k" SHA256)" "$k" || return 1
  elif [ -n "$(v "$k" STAGE_REPO)" ]; then
    materialize "$k" || return 1
  elif [ -n "$(v "$k" HF_REPO)" ]; then
    hf_fetch "$k" || return 1
  fi
  if [ -z "$(v "$k" REF_PY)" ]; then
    py=$(ref_python "$(v "$k" REF)") || { blocker "model $k: reference venv failed"; return 1; }
    setv "$k" REF_PY "$py"
  fi
  if [ "$(v "$k" CB_FROM_POLICY)" = 1 ]; then
    mkdir -p "$RES/$(v "$k" NAME)"
    cb_extra "$k" "$RES/$(v "$k" NAME)/cb-tuple.yaml" 2> "$RES/$(v "$k" NAME)/cb-tuple.err" \
      || { blocker "model $k: $(cat "$RES/$(v "$k" NAME)/cb-tuple.err")"; return 1; }
  fi
  if [ "$(v "$k" MTP_BENCH)" = 1 ]; then mtp_prepare "$k" || return 1; fi
  log "STAGED $k"
}
for k in $MODELS; do
  if stage_model "$k"; then STAGED="$STAGED $k"; else blocker "model $k: not staged; its grid is not run"; fi
done

# grid K OUT [run-grid args...]: one run-grid.sh invocation on the production route.
grid() {
  local k=$1 out=$2; shift 2
  local args=(--model-name "$(v "$k" NAME)" --bin-dir "$BIN" --out-dir "$out" --cb auto
              --no-autotune-candidate --outputs "$OUTPUTS" --trials "$TRIALS" "$@")
  mkdir -p "$out"
  bash "$GRID/run-grid.sh" "${args[@]}" > "$out/run.log" 2>&1
  local rc=$?
  /usr/bin/python3 -I -c 'import json,sys
try: s=json.load(open(sys.argv[1]))
except Exception as e: print("status: unreadable", e); sys.exit()
cb=s.get("continuous_batching") or {}
print("small_m_route:", cb.get("small_m_route"), "| native_mtp:", {k: v for k, v in s.items() if "native_mtp" in k})' \
    "$out/serve/status.json" 2>/dev/null | sed "s/^/GRID_STATUS $(v "$k" NAME) /"
  return $rc
}

# serve_args K: the snapshot under its catalog id when it has one, else by path.
serve_args() {
  local k=$1
  SERVE=(--model-path "$(v "$k" PATH)")
  [ -z "$(v "$k" ID)" ] || SERVE+=(--model-id "$(v "$k" ID)" --model-sha256 "$(v "$k" SHA256)")
  if [ -f "$RES/$(v "$k" NAME)/cb-tuple.yaml" ]; then SERVE+=(--config-extra "$RES/$(v "$k" NAME)/cb-tuple.yaml")
  elif [ -n "$(v "$k" CONFIG_EXTRA)" ]; then SERVE+=(--config-extra "$(v "$k" CONFIG_EXTRA)"); fi
}

run_model() {
  local k=$1 name rows ref_path ref_args=() tbr
  name=$(v "$k" NAME)
  local M=$RES/$name
  mkdir -p "$M"
  "$(v "$k" REF_PY)" -c 'import importlib.metadata as m
for p in ("mlx", "mlx-vlm", "mlx-lm", "transformers"):
    try: print("REF_VERSION", p, m.version(p))
    except m.PackageNotFoundError: pass'
  rows=$(v "$k" ROWS); rows=${rows:-1,4}
  ref_path=$(v "$k" REF_PATH)
  tbr=$(v "$k" TRIALS_BY_ROWS)
  [ -z "$(v "$k" REF_ARGS)" ] || for a in $(v "$k" REF_ARGS); do ref_args+=(--ref-arg "$a"); done
  serve_args "$k"
  log "GRID_START $name rows=$rows reference=$(v "$k" REF) served_as=$(v "$k" ID)${tbr:+ trials_by_rows=$tbr}"
  # The reference runs first; its first cell is the cheapest (short context, 128 tokens).
  grid "$k" "$M/main" "${SERVE[@]}" --rows "$rows" --contexts "$CONTEXTS" --python "$(v "$k" REF_PY)" \
    --reference "$(v "$k" REF)" ${ref_path:+--ref-model-path "$ref_path"} ${ref_args[@]+"${ref_args[@]}"} \
    ${tbr:+--trials-by-rows "$tbr"}
  local rc=$? ok=0
  log "GRID_DONE $name rc=$rc (0 all cells pass, 1 a cell fails the ratio/text gates: a finding)"
  case $rc in 0|1) sed -n '/^| model/,/^$/p' "$M/main/summary.md" ;;
    *) blocker "model $k: grid rc=$rc: $(tail -n 3 "$M/main/run.log" | tr '\n' ' ')"; ok=1 ;; esac
  if [ $ok = 0 ] && [ "$(v "$k" CB_FROM_POLICY)" = 1 ]; then
    local admitted
    admitted=$(grep -c 'event=batching_admitted' "$M/main/serve/serve.err" 2>/dev/null || true)
    log "CB_CHECK $name batching_admitted=$admitted $(grep -m1 'runtime-identity model=' "$M/main/serve/serve.err" | cut -c1-300)"
    [ "${admitted:-0}" -gt 0 ] || { blocker "model $k: continuous batching never admitted a row; the grid is not the production route"; ok=1; }
  fi
  if [ $ok = 0 ] && [ -n "$(v "$k" BASE_PATH)" ]; then
    log "BASE_START $name base=$(v "$k" BASE_ID)"
    mkdir -p "$M/base"
    local base_ref=() base_rcs="0"
    if [ "$(v "$k" BASE_REFERENCE)" = 1 ]; then
      base_ref=(--python "$(v "$k" REF_PY)" --reference "$(v "$k" REF)" --ref-model-path "$(v "$k" BASE_PATH)"
                ${ref_args[@]+"${ref_args[@]}"})
      base_rcs="0 1"
    else
      cp "$M/main/reference.jsonl" "$M/base/" && base_ref=(--skip-reference --skip-compare)
    fi
    TRIALS=$BASE_TRIALS grid "$k" "$M/base" --model-path "$(v "$k" BASE_PATH)" --model-id "$(v "$k" BASE_ID)" \
      --model-sha256 "$(v "$k" BASE_SHA256)" --rows 1 --contexts "$CONTEXTS" "${base_ref[@]}"
    local brc=$?
    # rc 1 = a cell fails the ratio/text gates against the base reference: a finding, not a failure.
    if case " $base_rcs " in *" $brc "*) true ;; *) false ;; esac; then
      /usr/bin/python3 -I "$GRID/compare.py" --baseline "$M/main/provider.jsonl" --ours "$M/base/provider.jsonl" \
        --subset --json "$M/base/vs-main.json" > "$M/base/vs-main.md"
      [ ! -f "$M/base/summary.md" ] || sed -n '/^| model/,/^$/p' "$M/base/summary.md"
      log "BASE_DONE $name"
    else
      blocker "model $k: base pass failed rc=$brc: $(tail -n 3 "$M/base/run.log" | tr '\n' ' ')"; ok=1
    fi
  fi
  if [ "$(v "$k" MTP_BENCH)" = 1 ]; then mtp_run "$k" || ok=1; fi
  return $ok
}

noise_pass() {
  local k=$1 name
  name=$(v "$k" NAME)
  local M=$RES/$name
  [ -f "$M/main/provider.jsonl" ] || return 0
  serve_args "$k"
  log "NOISE_START $name"
  mkdir -p "$M/noise" && cp "$M/main/reference.jsonl" "$M/noise/"
  grid "$k" "$M/noise" "${SERVE[@]}" --rows 1 --contexts short --skip-reference --skip-compare \
    || { blocker "model $k: noise pass rc=$?: $(tail -n 3 "$M/noise/run.log" | tr '\n' ' ')"; return 1; }
  /usr/bin/python3 -I "$GRID/compare.py" --baseline "$M/main/provider.jsonl" --ours "$M/noise/provider.jsonl" \
    --subset --json "$M/noise/vs-main.json" > "$M/noise/vs-main.md"
  local rc=$?
  cat "$M/noise/vs-main.md"
  [ $rc = 0 ] || { blocker "model $k: the noise pass differs from the main pass in text or tokens (run-to-run nondeterminism)"; return 1; }
  log "NOISE_DONE $name"
}

for k in $STAGED; do run_model "$k" || FAILED=1; done
for k in $STAGED; do noise_pass "$k" || FAILED=1; done
for k in $STAGED; do
  name=$(v "$k" NAME)
  [ -f "$RES/$name/main/summary.json" ] || continue
  /usr/bin/python3 -I "$JOB/ablit-perf/baseline_md.py" "$RES/$name" --model "$name" \
    --build "$(cut -c1-16 "$RES/identity.sha256" | head -n 1)" --commit "${COMMIT:-unknown}" \
    || blocker "model $k: baseline.md failed"
  log "BASELINE_MD $RES/$name/baseline.md"
done
[ "$FAILED" = 0 ] || { log "JOB_FAIL"; exit 1; }
log "JOB_PASS"
