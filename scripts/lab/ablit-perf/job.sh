#!/bin/bash
# Runs ON THE STUDIO, started detached by studio-ablit-perf.sh. The baseline check of the
# abliterated-perf swarm run: for each model, the Python reference and our provider on the
# same parity-grid prompts in one window, then a noise pass, then baseline.md.
#
# Steps:
#  1. lab-harness release build of the rsynced campaign tree (~/lab-ablit-perf/src), the
#     release metallib copied beside the binary;
#  2. per model: scripts/lab/parity-grid/run-grid.sh on the production route (`stock` in
#     window.sh: no autotune flag, batching auto), the snapshot served under its catalog id;
#     a model with <K>_CB_FROM_POLICY=1 gets its signed CB policy tuple as the --no-join
#     serve's accepted tuple and must show batched admissions;
#  3. <K>_BASE_PATH set: one 1-row pass of the unmodified base in our runtime (prices the
#     MiniMax refusal-direction projection);
#  4. at the end, per model: the short-context 1-row cells again on a fresh serve, compared
#     with compare.py --baseline (run-to-run spread and identity);
#  5. baseline_md.py writes RES/<name>/baseline.md.
#
# Models: MODELS="glm minimax" (default). A model key K reads <K>_NAME, <K>_PATH, <K>_ID,
# <K>_SHA256, <K>_REF (mlx-lm|mlx-vlm), <K>_REF_PY, <K>_REF_PATH, <K>_REF_ARGS, <K>_ROWS,
# <K>_CB_FROM_POLICY, <K>_CONFIG_EXTRA, <K>_BASE_PATH/_BASE_ID/_BASE_SHA256 and
# <K>_STAGE_REPO/_STAGE_REVISION (materialize <K>_PATH as an APFS clone of <K>_BASE_PATH plus
# the published repo's non-shard files, verified against <K>_SHA256). Built-in defaults exist
# for glm and minimax; any other key must set at least NAME, PATH, ID, SHA256 and REF.
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
RUN_ID=${RUN_ID:-$(date -u +%Y%m%dT%H%M%SZ)}
RES=$LAB/results/$RUN_ID
MODELS=${MODELS:-glm minimax}
OUTPUTS=${OUTPUTS:-128,512,2048}
CONTEXTS=${CONTEXTS:-short,4k,16k}
TRIALS=${TRIALS:-3}
BASE_TRIALS=${BASE_TRIALS:-1}
METALLIB=${METALLIB:-/Applications/Malibu.app/Contents/MacOS/mlx.metallib}
BIN=$SRC/.build-lab-harness/release
FAILED=0
log() { echo "$(date '+%H:%M:%S') $*"; }
blocker() { log "BLOCKER: $*"; FAILED=1; }
die() { log "BLOCKER: $*"; log "JOB_FAIL"; exit "${2:-1}"; }
mkdir -p "$RES"

# Built-in model defaults (catalog rows of autotune-candidates.json).
: "${GLM_NAME:=glm53-flash-uncensored}"
: "${GLM_ID:=zai-org/glm-5.3-flash-uncensored}"
: "${GLM_SHA256:=242f8fcfd34d4ecfd62180c1767f910bda925216948772126dc98c673d1c8919}"
: "${GLM_PATH:=$HOME/Library/Application Support/macprovider/models/Solstice-AI--GLM-5.3-Flash-UNCENSORED-mlx-oQ4e-DFlash2/bff40d24efb689d33e094083ce4a5d6835601730/$GLM_SHA256}"
: "${GLM_REF:=mlx-vlm}"
: "${GLM_CB_FROM_POLICY:=1}"
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

# v K FIELD: the value of <K>_FIELD (empty when unset).
v() { local n; n="$(echo "$1" | tr 'a-z-' 'A-Z_')_$2"; echo "${!n:-}"; }

log "JOB_START run=$RUN_ID commit=${COMMIT:-unknown} models=\"$MODELS\" outputs=$OUTPUTS contexts=$CONTEXTS trials=$TRIALS"
if lsof -nP -iTCP:8080 -sTCP:LISTEN -t >/dev/null 2>&1; then die "a server listens on :8080; the Studio is not paused" 3; fi
launchctl print "gui/$(id -u)/live.malibu.provider" >/dev/null 2>&1 && die "live.malibu.provider is loaded" 3
pgrep -f "[m]acprovider-cli serve" >/dev/null 2>&1 && die "a macprovider-cli serve process runs" 3

# Preflight every model before the build, so a missing input fails in seconds.
for k in $MODELS; do
  for f in NAME ID SHA256 REF; do [ -n "$(v "$k" $f)" ] || die "model $k: <K>_$f unset" 64; done
  case "$(v "$k" REF)" in mlx-lm|mlx-vlm) ;; *) die "model $k: REF must be mlx-lm|mlx-vlm" 64 ;; esac
  if [ -n "$(v "$k" STAGE_REPO)" ]; then
    [ -f "$(v "$k" BASE_PATH)/config.json" ] || die "model $k: no base snapshot at $(v "$k" BASE_PATH)" 11
  else
    [ -f "$(v "$k" PATH)/config.json" ] || die "model $k: no snapshot at $(v "$k" PATH)" 11
  fi
  rp=$(v "$k" REF_PATH); [ -z "$rp" ] || [ -f "$rp/config.json" ] || die "model $k: no reference snapshot at $rp" 11
  [ -z "$(v "$k" BASE_PATH)" ] || [ -n "$(v "$k" BASE_SHA256)" ] || die "model $k: BASE_PATH needs BASE_SHA256" 64
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

# materialize K: <K>_PATH = APFS clone of the base + the published repo's non-shard files.
manifest() {  # macprovider.snapshot-manifest.v1 of DIR, the catalog's model_sha256
  /usr/bin/python3 -I -c 'import sys,pathlib; sys.path.insert(0, sys.argv[1])
from publish_abliterated import snapshot_manifest_sha256 as m; print(m(pathlib.Path(sys.argv[2])))' "$JOB/minimax" "$1"
}
materialize() {
  local k=$1 stage base repo rev want got
  stage=$(v "$k" PATH); base=$(v "$k" BASE_PATH); repo=$(v "$k" STAGE_REPO); rev=$(v "$k" STAGE_REVISION); want=$(v "$k" SHA256)
  [ -n "$rev" ] || { blocker "model $k: STAGE_REPO needs STAGE_REVISION"; return 1; }
  case $stage in "$LAB"/models/?*) ;; *) blocker "model $k: a staged PATH must lie under $LAB/models"; return 1 ;; esac
  if [ -d "$stage" ] && [ "$(manifest "$stage" 2>/dev/null)" = "$want" ]; then
    log "STAGE_OK $k manifest=$want (existing)"
    return 0
  fi
  log "STAGE_BUILD $k from $base + $repo@$rev"
  # APFS clone: no extra disk; the base keeps its single-link regular files.
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

run_model() {
  local k=$1 name ref_py extra="" rows ref_path ref_args=()
  name=$(v "$k" NAME)
  local M=$RES/$name
  mkdir -p "$M"
  if [ -n "$(v "$k" STAGE_REPO)" ]; then materialize "$k" || return 1; fi
  ref_py=$(v "$k" REF_PY); [ -n "$ref_py" ] || ref_py=$(ref_python "$(v "$k" REF)") || { blocker "model $k: reference venv failed"; return 1; }
  "$ref_py" -c 'import importlib.metadata as m
for p in ("mlx", "mlx-vlm", "mlx-lm", "transformers"):
    try: print("REF_VERSION", p, m.version(p))
    except m.PackageNotFoundError: pass'
  if [ "$(v "$k" CB_FROM_POLICY)" = 1 ]; then
    extra=$M/cb-tuple.yaml
    cb_extra "$k" "$extra" 2> "$M/cb-tuple.err" || { blocker "model $k: $(cat "$M/cb-tuple.err")"; return 1; }
  elif [ -n "$(v "$k" CONFIG_EXTRA)" ]; then
    extra=$(v "$k" CONFIG_EXTRA)
  fi
  rows=$(v "$k" ROWS); rows=${rows:-1,4}
  ref_path=$(v "$k" REF_PATH)
  [ -z "$(v "$k" REF_ARGS)" ] || for a in $(v "$k" REF_ARGS); do ref_args+=(--ref-arg "$a"); done
  local common=(--model-path "$(v "$k" PATH)" --model-id "$(v "$k" ID)" --model-sha256 "$(v "$k" SHA256)")
  [ -z "$extra" ] || common+=(--config-extra "$extra")
  log "GRID_START $name rows=$rows reference=$(v "$k" REF)"
  grid "$k" "$M/main" "${common[@]}" --rows "$rows" --contexts "$CONTEXTS" --python "$ref_py" \
    --reference "$(v "$k" REF)" ${ref_path:+--ref-model-path "$ref_path"} ${ref_args[@]+"${ref_args[@]}"}
  local rc=$?
  log "GRID_DONE $name rc=$rc (0 all cells pass, 1 a cell fails the ratio/text gates: a finding)"
  case $rc in 0|1) ;; *) blocker "model $k: grid rc=$rc: $(tail -n 3 "$M/main/run.log" | tr '\n' ' ')"; return 1 ;; esac
  sed -n '/^| model/,/^$/p' "$M/main/summary.md"
  if [ -n "$extra" ] && [ "$(v "$k" CB_FROM_POLICY)" = 1 ]; then
    local admitted
    admitted=$(grep -c 'event=batching_admitted' "$M/main/serve/serve.err" 2>/dev/null || true)
    log "CB_CHECK $name batching_admitted=$admitted $(grep -m1 'runtime-identity model=' "$M/main/serve/serve.err" | cut -c1-300)"
    [ "${admitted:-0}" -gt 0 ] || { blocker "model $k: continuous batching never admitted a row; the grid is not the production route"; return 1; }
  fi
  if [ -n "$(v "$k" BASE_PATH)" ]; then
    log "BASE_START $name base=$(v "$k" BASE_ID)"
    mkdir -p "$M/base" && cp "$M/main/reference.jsonl" "$M/base/"
    TRIALS=$BASE_TRIALS grid "$k" "$M/base" --model-path "$(v "$k" BASE_PATH)" --model-id "$(v "$k" BASE_ID)" \
      --model-sha256 "$(v "$k" BASE_SHA256)" --rows 1 --contexts "$CONTEXTS" --skip-reference --skip-compare \
      || { blocker "model $k: base pass rc=$?: $(tail -n 3 "$M/base/run.log" | tr '\n' ' ')"; return 1; }
    # Text differs by design (the projection changes the output): the rc is not a gate.
    /usr/bin/python3 -I "$GRID/compare.py" --baseline "$M/main/provider.jsonl" --ours "$M/base/provider.jsonl" \
      --subset --json "$M/base/vs-main.json" > "$M/base/vs-main.md"
    log "BASE_DONE $name"
  fi
  return 0
}

noise_pass() {
  local k=$1 name extra=""
  name=$(v "$k" NAME)
  local M=$RES/$name
  [ -f "$M/main/provider.jsonl" ] || return 0
  [ ! -f "$M/cb-tuple.yaml" ] || extra=$M/cb-tuple.yaml
  [ -n "$extra" ] || [ -z "$(v "$k" CONFIG_EXTRA)" ] || extra=$(v "$k" CONFIG_EXTRA)
  log "NOISE_START $name"
  mkdir -p "$M/noise" && cp "$M/main/reference.jsonl" "$M/noise/"
  grid "$k" "$M/noise" --model-path "$(v "$k" PATH)" --model-id "$(v "$k" ID)" --model-sha256 "$(v "$k" SHA256)" \
    ${extra:+--config-extra "$extra"} --rows 1 --contexts short --skip-reference --skip-compare \
    || { blocker "model $k: noise pass rc=$?: $(tail -n 3 "$M/noise/run.log" | tr '\n' ' ')"; return 1; }
  /usr/bin/python3 -I "$GRID/compare.py" --baseline "$M/main/provider.jsonl" --ours "$M/noise/provider.jsonl" \
    --subset --json "$M/noise/vs-main.json" > "$M/noise/vs-main.md"
  local rc=$?
  cat "$M/noise/vs-main.md"
  [ $rc = 0 ] || { blocker "model $k: the noise pass differs from the main pass in text or tokens (run-to-run nondeterminism)"; return 1; }
  log "NOISE_DONE $name"
}

for k in $MODELS; do run_model "$k" || FAILED=1; done
for k in $MODELS; do noise_pass "$k" || FAILED=1; done
for k in $MODELS; do
  name=$(v "$k" NAME)
  [ -f "$RES/$name/main/summary.json" ] || continue
  /usr/bin/python3 -I "$JOB/ablit-perf/baseline_md.py" "$RES/$name" --model "$name" \
    --build "$(cut -c1-16 "$RES/identity.sha256" | head -n 1)" --commit "${COMMIT:-unknown}" \
    || blocker "model $k: baseline.md failed"
  log "BASELINE_MD $RES/$name/baseline.md"
done
[ "$FAILED" = 0 ] || { log "JOB_FAIL"; exit 1; }
log "JOB_PASS"
