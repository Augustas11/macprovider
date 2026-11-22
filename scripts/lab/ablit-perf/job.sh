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
#  3. per model, scripts/lab/parity-grid/run-grid.sh: our provider first, then the reference,
#     on the production route (`stock` in window.sh: no autotune flag, batching auto). A
#     reference that fails (REFERENCE_FAIL line, grid rc 8) leaves the provider cells, the
#     route check and the later passes intact and fails the job. The snapshot is served under
#     its catalog id when it has one, else by path. Every serve first waits, idle, for the
#     continuous-batching self-check verdict (run-grid.sh batching warm-up: a --no-join serve
#     never loads the signed CB policy, so that verdict is what turns batching on, as on a
#     live provider after its provisional grant) and prints one ROUTE line at the grid start
#     and one at its end (batching=active|serial, served slots, reason).
#     A model with <K>_CB_FROM_POLICY=1 has a signed CB policy entry, so production batches
#     it: the serve config carries the entry's tuple (cached-turns grant) and its
#     max_served_slots as continuous_batch_queue_limit, which bounds the self-check ladder
#     as the signed ceiling does on a live provider, and a serial ROUTE is a ROUTE_FAIL
#     (cells still measured, job fails at the end). Other models run 1 trial of their
#     4-row cells by default (<K>_TRIALS_BY_ROWS, default 4=1);
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
# (mlx-lm|mlx-vlm|omlx), <K>_REF_PY, <K>_REF_PATH, <K>_REF_ARGS, <K>_OMLX_DIR (REF=omlx: the
# oMLX install dir holding omlx-venv/ and omlx-src/; the server's state goes under
# ~/lab-ablit-perf/omlx-state), <K>_ROWS, <K>_TRIALS_BY_ROWS,
# <K>_CB_FROM_POLICY, <K>_CONFIG_EXTRA, <K>_BASE_PATH/_BASE_ID/_BASE_SHA256/_BASE_REFERENCE and the
# staging fields: <K>_CLONE_FROM (PATH = APFS clone of it, verified against SHA256),
# <K>_BASE_CLONE_FROM (the same for BASE_PATH), <K>_HF_REPO/_HF_REVISION/_HF_SUBFOLDER
# (download one subfolder into PATH), <K>_STAGE_REPO/_STAGE_REVISION (PATH = APFS clone
# of BASE_PATH plus the published repo's non-shard files, verified against SHA256) and
# <K>_MTP_BENCH/_MTP_TEMPLATE. Built-in defaults exist for qwen27, glm, minimax and dsv4abl
# (the abliterated DeepSeek V4-Flash that job-dsv4-abliterated.sh splices; not in MODELS by default).
# Grid: OUTPUTS (128,512,2048), CONTEXTS (short,4k,16k), TRIALS (3), BASE_TRIALS (1).
# REUSE_REFERENCE=<run id>: a provider-only rerun. Per model, the reference rows of that run
# (results/<run id>/<name>/main/reference.jsonl, same weights and reference) are copied in
# and the reference is not run again; compare scores the new provider cells against them.
# The noise pass needs 1-row cells in the main pass and is skipped without them (<K>_ROWS=4).
#
# Serve knobs (each applies to every serve of that model, or to one pass, see PASSES):
#  <K>_NATIVE_MTP=auto: serve with native MTP. A `--no-join` serve gets the signed native-MTP
#    admission set only with native_mtp_mode auto, model_catalog_* provenance (written from the
#    committed autotune-candidates.json row of <K>_ID, which must equal the model's catalog key)
#    and the model at its durable store path (the catalog's model_id/revision/sha256 under
#    ~/Library/Application Support/macprovider/models, the same snapshot <K>_CLONE_FROM reads,
#    served in place), so the serve runs from that path instead of <K>_PATH. run-grid.sh
#    --expect-native-mtp on then fails the grid with exit 11 (NATIVE_MTP_FAIL) when /v1/status shows
#    native_mtp disabled or off, or no proposed token after the grid, and each aggregate line of
#    provider.jsonl carries the native_mtp counter change of its trial (proposed/accepted tokens,
#    acceptance). Admission caps native MTP at one active row: use rows 1.
#  <K>_SERVED_SLOTS=N: owner-pin the served slots (config max_concurrency_override N with
#    max_concurrency_source owner; AutoServedSlots.plan keeps the pin, the self-check only lowers
#    it to the verified width: served = min(pin, verified_slots, ceiling)). The grid fails the pass
#    (BLOCKER) when the ROUTE line shows other slots.
# SEED_SELF_CHECK_RUN=<run id>: every serve starts with that run's results/<run>/<name>/main/serve/
#   cb-self-check.json (run-grid.sh --seed-self-check), so a stored verdict of the same binary pins,
#   Metal library, OS build and hardware applies at startup and the ~5 min idle self-check is skipped;
#   a verdict whose key does not match is ignored and the self-check runs as usual.
# <K>_PASSES="NAME key=val ...; NAME key=val ...": instead of the main/base/noise/MTP-bench steps (no
#   baseline.md either), one
#   grid pass per entry, each its own serve and output directory results/<run>/<name>/NAME, scored
#   against the REUSE_REFERENCE rows (required, no reference runs). Keys: rows (default 1,4),
#   native_mtp, slots (the two knobs above for this pass only), contexts, outputs, trials (default
#   CONTEXTS, OUTPUTS, TRIALS), turn2_header (0|1|cache_only, TURN2_HEADER for this pass only; 0
#   sends no conversation header on either turn, the keyless cold control), small_m_route
#   (row_invariant: the kernel every request of a native-MTP process runs, for an ordinary control
#   that differs from the native pass only in the mode). Example, the abliterated GLM native-MTP and 4-slot passes:
#   GLM_PASSES='mtp rows=1 native_mtp=auto; slots4 rows=4 slots=4'.
#   native_mtp=off writes the same catalog provenance and durable store path as auto with
#   native_mtp_mode off (the kill switch): the ordinary-decode control of a native pass, the same
#   build, weights and config but the mode. Without REUSE_REFERENCE a pass runs no reference and
#   no compare (run-grid.sh --skip-reference --skip-compare): provider-only cells.
# TURNS=2: every grid sends the two-turn cell (run-grid.sh --turns 2); TURN2_HEADER, TURN2_HISTORY
#   and TURN2_FOLLOWUP pass to run-grid.sh through the environment (its header). TURN2_HEADER=1 sends
#   the sticky conversation key (native MTP then decodes turn 2 ordinarily); TURN2_HEADER=cache_only
#   sends it cache-only, the live cached-turn path (needs this lab-harness build).
# MTP_T2_COMPARE="NATIVE ORDINARY" (two pass names): after a model's passes, mtp_turn2_compare.py
#   scores pass NATIVE against pass ORDINARY on the turn-2 rows (text, reasoning and token parity,
#   decode tok/s and TTFT medians, cached tokens, native-MTP proposals on turn 2) into
#   RES/<name>/mtp-turn2.{md,json}, `T2_*` lines in the log. A parity or cache failure is a finding
#   (T2_VERDICT FAIL); unusable input (rc 2) is a BLOCKER. One name alone checks that pass only. A
#   third name COLD (a keyless pass, turn2_header=0) also requires every turn-1 and turn-2 pair of
#   ORDINARY (keyed, cache-only) to equal COLD: the keyed snapshot path keeps cold output.
# #2459 (native MTP vs ordinary decode on the cached-prefix turn-2 path at ~30K prompt tokens): model
#   keys qwen38-27b and qwen36-27b serve the signed catalog rows qwen/qwen3.8-27b and qwen/qwen3.6-27b
#   from their durable store snapshots (the job-qwen-mtp-cap.sh target identities); the launcher
#   command is in studio-ablit-perf.sh's usage.
#
# REFERENCE_ONLY=<run id>: add a reference to an already measured provider grid. No build, no
# provider serve, no CB check, base pass, noise pass or MTP bench: per model, staging (the
# snapshot clone is verified against the catalog hash as usual), then
# results/<run id>/<name>/main/{provider.jsonl,grid.json} are copied into this run's
# <name>/main, run-grid.sh --reference-only runs the reference over the same cells and
# compares, and baseline.md is written with that run's noise/ and mtp/ results and build
# identity. A reference whose output is degenerate prints REFERENCE_SUSPECT (grid rc 9) and
# fails the job like REFERENCE_FAIL.
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
REFERENCE_ONLY=${REFERENCE_ONLY:-}
REUSE_REFERENCE=${REUSE_REFERENCE:-}
SRC_RES=${REFERENCE_ONLY:+$LAB/results/$REFERENCE_ONLY}
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
: "${QWEN38_27B_NAME:=qwen3.8-27b}"
: "${QWEN38_27B_ID:=qwen/qwen3.8-27b}"
: "${QWEN38_27B_SHA256:=8a8786e902127e9175f5be0d7c8bcf4dd32323a0521e4d9a20761608a07a6d05}"
: "${QWEN38_27B_PATH:=$(store_dir mlx-community--Qwen3.8-27B-4bit "$QWEN38_27B_SHA256")}"
: "${QWEN38_27B_REF:=mlx-lm}"
: "${QWEN38_27B_REF_PY:=/usr/bin/python3}"  # its passes run no reference: no venv
: "${QWEN36_27B_NAME:=qwen3.6-27b}"
: "${QWEN36_27B_ID:=qwen/qwen3.6-27b}"
: "${QWEN36_27B_SHA256:=518ef47c298783d8547b50406e84548e5bf7705b82355a38f9eaef1368817931}"
: "${QWEN36_27B_PATH:=$(store_dir mlx-community--Qwen3.6-27B-4bit "$QWEN36_27B_SHA256")}"
: "${QWEN36_27B_REF:=mlx-lm}"
: "${QWEN36_27B_REF_PY:=/usr/bin/python3}"
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

# serve_knob_check K NATIVE_MTP SLOTS: sets KNOB_ERR and fails on a value the serve cannot take.
serve_knob_check() {
  local k=$1 nm=$2 sl=$3
  case "$nm" in ""|auto|off) ;; *) KNOB_ERR="NATIVE_MTP must be auto or off"; return 1 ;; esac
  case "$sl" in ""|[1-9]|[1-2][0-9]|3[0-2]) ;; *) KNOB_ERR="SERVED_SLOTS must be 1..32"; return 1 ;; esac
  if [ -n "$nm" ]; then
    [ -n "$(v "$k" ID)" ] || { KNOB_ERR="NATIVE_MTP needs ID (the catalog key)"; return 1; }
    [ -f "$JOB/catalog/autotune-candidates.json" ] || { KNOB_ERR="NATIVE_MTP: no $JOB/catalog/autotune-candidates.json"; return 1; }
  fi
  return 0
}

# parse_pass K "NAME key=val ...": sets P_NAME P_ROWS P_NM P_SL P_CTX P_OUTS P_TRIALS P_T2H (PASSES header).
parse_pass() {
  local k=$1 w key val
  set -- $2
  P_NAME=${1:-}; shift
  P_ROWS=1,4 P_NM="" P_SL="" P_SMR="" P_CTX=$CONTEXTS P_OUTS=$OUTPUTS P_TRIALS=$TRIALS P_T2H=""
  case "$P_NAME" in ""|*[!a-z0-9_-]*) KNOB_ERR="pass name must be [a-z0-9_-]+"; return 1 ;; esac
  for w in "$@"; do
    key=${w%%=*}; val=${w#*=}
    [ "$key" != "$w" ] && [ -n "$val" ] || { KNOB_ERR="bad word $w (key=value)"; return 1; }
    case $key in
      rows) P_ROWS=$val ;; native_mtp) P_NM=$val ;; slots) P_SL=$val ;;
      contexts) P_CTX=$val ;; outputs) P_OUTS=$val ;; trials) P_TRIALS=$val ;; turn2_header) P_T2H=$val ;;
      small_m_route) P_SMR=$val ;;
      *) KNOB_ERR="unknown key $key"; return 1 ;;
    esac
  done
  case "$P_ROWS" in *[!0-9,]*) KNOB_ERR="rows must be a comma list of numbers"; return 1 ;; esac
  case "$P_TRIALS" in ""|*[!0-9]*) KNOB_ERR="trials must be a number"; return 1 ;; esac
  case "$P_T2H" in ""|0|1|cache_only) ;; *) KNOB_ERR="turn2_header must be 0|1|cache_only"; return 1 ;; esac
  case "$P_SMR" in ""|row_invariant) ;; *) KNOB_ERR="small_m_route must be row_invariant"; return 1 ;; esac
  serve_knob_check "$k" "$P_NM" "$P_SL"
}

TURNS=${TURNS:-1}
case "$TURNS" in 1|2) ;; *) die "TURNS must be 1 or 2" 64 ;; esac
log "JOB_START run=$RUN_ID commit=${COMMIT:-unknown} models=\"$MODELS\" outputs=$OUTPUTS contexts=$CONTEXTS trials=$TRIALS${REFERENCE_ONLY:+ reference_only=$REFERENCE_ONLY}"
if [ -n "$REFERENCE_ONLY" ]; then
  echo "$REFERENCE_ONLY" | grep -Eq '^[0-9]{8}T[0-9]{6}Z$' || die "REFERENCE_ONLY=$REFERENCE_ONLY is not a run id" 64
  [ -d "$SRC_RES" ] || die "REFERENCE_ONLY: no provider run at $SRC_RES" 11
fi
if [ -n "$REUSE_REFERENCE" ]; then
  [ -z "$REFERENCE_ONLY" ] || die "REUSE_REFERENCE and REFERENCE_ONLY exclude each other" 64
  echo "$REUSE_REFERENCE" | grep -Eq '^[0-9]{8}T[0-9]{6}Z$' || die "REUSE_REFERENCE=$REUSE_REFERENCE is not a run id" 64
fi
if lsof -nP -iTCP:8080 -sTCP:LISTEN -t >/dev/null 2>&1; then die "a server listens on :8080; the Studio is not paused" 3; fi
launchctl print "gui/$(id -u)/live.malibu.provider" >/dev/null 2>&1 && die "live.malibu.provider is loaded" 3
pgrep -f "[m]acprovider-cli serve" >/dev/null 2>&1 && die "a macprovider-cli serve process runs" 3

# Preflight every model before the build, so a missing input fails in seconds.
for k in $MODELS; do
  for f in NAME REF; do [ -n "$(v "$k" $f)" ] || die "model $k: <K>_$f unset" 64; done
  [ -z "$(v "$k" ID)" ] || [ -n "$(v "$k" SHA256)" ] || die "model $k: ID needs SHA256" 64
  case "$(v "$k" REF)" in mlx-lm|mlx-vlm|omlx) ;; *) die "model $k: REF must be mlx-lm|mlx-vlm|omlx" 64 ;; esac
  if [ "$(v "$k" REF)" = omlx ]; then
    od=$(v "$k" OMLX_DIR)
    [ -n "$od" ] || die "model $k: REF=omlx needs <K>_OMLX_DIR (the oMLX install dir)" 64
    [ -x "$od/omlx-venv/bin/omlx" ] && [ -x "$od/omlx-venv/bin/python" ] \
      || die "model $k: no oMLX venv at $od/omlx-venv (bin/omlx, bin/python)" 11
    case "$od" in *[[:space:]]*) die "model $k: OMLX_DIR must not contain whitespace" 64 ;; esac
  fi
  if [ -n "$REFERENCE_ONLY" ]; then
    [ -s "$SRC_RES/$(v "$k" NAME)/main/provider.jsonl" ] \
      || die "model $k: REFERENCE_ONLY: no provider.jsonl at $SRC_RES/$(v "$k" NAME)/main" 11
  fi
  if [ -n "$REUSE_REFERENCE" ]; then
    [ -s "$LAB/results/$REUSE_REFERENCE/$(v "$k" NAME)/main/reference.jsonl" ] \
      || die "model $k: REUSE_REFERENCE: no reference.jsonl at $LAB/results/$REUSE_REFERENCE/$(v "$k" NAME)/main" 11
  fi
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
  serve_knob_check "$k" "$(v "$k" NATIVE_MTP)" "$(v "$k" SERVED_SLOTS)" || die "model $k: $KNOB_ERR" 64
  if [ -n "$(v "$k" PASSES)" ]; then
    [ -z "$REFERENCE_ONLY" ] || die "model $k: PASSES and REFERENCE_ONLY exclude each other" 64
    setv "$k" MTP_BENCH 0  # passes replace the baseline steps, the MTP bench included
    IFS=';' read -r -a PASS_SPECS <<< "$(v "$k" PASSES)"
    for spec in "${PASS_SPECS[@]}"; do
      parse_pass "$k" "$spec" || die "model $k: PASSES entry \"$spec\": $KNOB_ERR" 64
    done
    for p in ${MTP_T2_COMPARE:-}; do
      case ";$(v "$k" PASSES);" in *";$p "*|*"; $p "*|*";$p;"*|*"; $p;"*) ;;
        *) die "model $k: MTP_T2_COMPARE names $p, which is not a pass of <K>_PASSES" 64 ;; esac
    done
  fi
  if [ -n "${SEED_SELF_CHECK_RUN:-}" ]; then
    [ -s "$LAB/results/$SEED_SELF_CHECK_RUN/$(v "$k" NAME)/main/serve/cb-self-check.json" ] \
      || die "model $k: SEED_SELF_CHECK_RUN: no cb-self-check.json at $LAB/results/$SEED_SELF_CHECK_RUN/$(v "$k" NAME)/main/serve" 11
  fi
done

ref_python() {  # ref_python KIND: a pinned venv per reference kind, created once
  local kind=$1 venv pkgs
  case $kind in
    mlx-vlm) venv=$LAB/venv-vlm; pkgs="mlx-vlm==0.7.11 mlx==0.32.4" ;;
    mlx-lm) venv=$LAB/venv-lm; pkgs="mlx-lm==0.32.2 mlx==0.32.4" ;;
    omlx) echo /usr/bin/python3; return 0 ;;  # the client is stdlib; oMLX runs from <K>_OMLX_DIR
  esac
  local mod=${kind//-/_}
  if ! "$venv/bin/python" -c "import $mod" >/dev/null 2>&1; then
    local py; py=$(command -v python3.12 || echo /opt/homebrew/bin/python3.12)
    [ -x "$py" ] || { echo "python3.12 not found" >&2; return 1; }
    "$py" -m venv "$venv" && "$venv/bin/pip" install -q $pkgs > "$RES/venv-$kind.log" 2>&1 || return 1
  fi
  echo "$venv/bin/python"
}

# 1. Build (a reference-only run reuses the provider run's build identity).
if [ -n "$REFERENCE_ONLY" ]; then
  cp "$SRC_RES/identity.sha256" "$RES/identity.sha256" 2>/dev/null || echo "unknown (provider run $REFERENCE_ONLY)" > "$RES/identity.sha256"
  PROVIDER_COMMIT=$(sed -n 's/.*JOB_START run=[^ ]* commit=\([^ ]*\).*/\1/p' "$LAB/logs/job-$REFERENCE_ONLY.log" "$SRC_RES/job-$REFERENCE_ONLY.log" 2>/dev/null | head -n 1)
  log "BUILD_SKIPPED reference-only: provider run $REFERENCE_ONLY build $(cut -c1-16 "$RES/identity.sha256" | head -n 1) commit=${PROVIDER_COMMIT:-unknown}"
else
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
fi

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

# cb_extra K FILE: the serve config lines that put a --no-join serve on <K>'s production CB
# route: the signed entry's tuple as an accepted tuple (its cached-turns grant) and the
# entry's max_served_slots as the queue limit, which bounds the self-check ladder as the
# signed ceiling does on a live provider. Batching itself still waits for the self-check.
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
print(f"continuous_batch_queue_limit: {e.get('max_served_slots', 4)}")
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
  if [ -n "$REFERENCE_ONLY" ]; then log "STAGED $k (reference-only: no CB tuple, no MTP policy)"; return 0; fi
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

# grid K OUT [run-grid args...]: one run-grid.sh invocation on the production route. Prints
# the batching warm-up outcome and both ROUTE lines.
grid() {
  local k=$1 out=$2; shift 2
  local args=(--model-name "$(v "$k" NAME)" --bin-dir "$BIN" --out-dir "$out" --cb auto
              --no-autotune-candidate --outputs "$OUTPUTS" --trials "$TRIALS" --turns "$TURNS" "$@")
  mkdir -p "$out"
  bash "$GRID/run-grid.sh" "${args[@]}" > "$out/run.log" 2>&1
  local rc=$?
  grep -E '^(CB_WARMUP_DONE|CB_WARMUP_STALL|CB_WARMUP_FAIL|ROUTE|ROUTE_FAIL|NATIVE_MTP|NATIVE_MTP_FAIL) ' "$out/run.log" \
    | sed "s/^/GRID_$(basename "$out" | tr 'a-z' 'A-Z') $(v "$k" NAME) /"
  /usr/bin/python3 -I -c 'import json,sys
try: s=json.load(open(sys.argv[1]))
except Exception as e: print("status: unreadable", e); sys.exit()
print("native_mtp:", {k: v for k, v in s.items() if "native_mtp" in k})' \
    "$out/serve/status.json" 2>/dev/null | sed "s/^/GRID_STATUS $(v "$k" NAME) /"
  return $rc
}

# expect_route K: run-grid's --expect-route for <K>: batched when production batches it.
expect_route() { if [ "$(v "$1" CB_FROM_POLICY)" = 1 ]; then echo batched; else echo any; fi; }

# route_failed DIR: the grid in DIR printed a ROUTE_FAIL line.
route_failed() { grep -q '^ROUTE_FAIL ' "$1/run.log" 2>/dev/null; }

# native_mtp_extra K FILE: writes the serve config lines of <K>'s native-MTP admission (native_mtp_mode
# <K>_NATIVE_MTP, auto or off, and model_catalog_* from the committed autotune-candidates.json row whose key is <K>_ID) to FILE
# and prints the model's durable store path, which the catalog preflight requires as the artifact path.
native_mtp_extra() {
  /usr/bin/python3 -I - "$JOB/catalog/autotune-candidates.json" "$(v "$1" ID)" "$(v "$1" SHA256)" "$STORE" "$2" \
    "$(v "$1" NATIVE_MTP)" <<'PY'
import hashlib, json, os, sys
cand, key, sha, store, out, mode = sys.argv[1:7]
raw = open(cand, "rb").read()
doc = json.loads(raw)
row = doc["rows"].get(key)
if row is None:
    sys.exit(f"no candidates row {key}")
if row["model_sha256"] != sha:
    sys.exit(f"candidates row {key} has model_sha256 {row['model_sha256']}, not {sha}")
path = os.path.join(store, row["model_id"].replace("/", "--"), row["model_revision"], sha)
if not os.path.isfile(os.path.join(path, "config.json")):
    sys.exit(f"no durable artifact at {path}")
q = json.dumps
open(out, "w").write("\n".join([
    f"native_mtp_mode: {mode}", f"model_catalog_key: {q(key)}", f"model_catalog_model_id: {q(row['model_id'])}",
    f"model_catalog_revision: {q(row['model_revision'])}", f"model_catalog_sha256: {q(sha)}",
    f"model_catalog_version: {q(doc['version'])}", f"model_catalog_hash: {q(hashlib.sha256(raw).hexdigest())}"]) + "\n")
print(path)
PY
}

# serve_args K: the snapshot under its catalog id when it has one, else by path. With <K>_NATIVE_MTP /
# <K>_SERVED_SLOTS the config extra also carries those knobs (file $RES/<name>/serve-extra-${SERVE_TAG:-main}.yaml);
# native MTP serves the durable store path of the catalog artifact.
serve_args() {
  local k=$1 name extra="" f durable
  name=$(v "$k" NAME)
  SERVE=(--model-path "$(v "$k" PATH)")
  [ -z "$(v "$k" ID)" ] || SERVE+=(--model-id "$(v "$k" ID)" --model-sha256 "$(v "$k" SHA256)")
  if [ -f "$RES/$name/cb-tuple.yaml" ]; then extra=$RES/$name/cb-tuple.yaml
  elif [ -n "$(v "$k" CONFIG_EXTRA)" ]; then extra=$(v "$k" CONFIG_EXTRA); fi
  if [ -n "$(v "$k" NATIVE_MTP)$(v "$k" SERVED_SLOTS)$(v "$k" SMALL_M_ROUTE)" ]; then
    f=$RES/$name/serve-extra-${SERVE_TAG:-main}.yaml
    mkdir -p "$RES/$name"
    { [ -z "$extra" ] || cat "$extra"; } > "$f"
    if [ -n "$(v "$k" NATIVE_MTP)" ]; then
      durable=$(native_mtp_extra "$k" "$f.mtp" 2> "$f.err") || { blocker "model $k: native MTP config: $(cat "$f.err")"; return 1; }
      cat "$f.mtp" >> "$f"
      SERVE[1]=$durable
    fi
    if [ -n "$(v "$k" SERVED_SLOTS)" ]; then
      printf 'max_concurrency_override: %s\nmax_concurrency_source: owner\n' "$(v "$k" SERVED_SLOTS)" >> "$f"
    fi
    # small_m_route=row_invariant: the kernel a native-MTP process forces on every request, so an
    # ordinary-decode control on it isolates native MTP from the stock-order kernel.
    [ -z "$(v "$k" SMALL_M_ROUTE)" ] || printf 'small_m_route: %s\n' "$(v "$k" SMALL_M_ROUTE)" >> "$f"
    extra=$f
  fi
  [ -z "$extra" ] || SERVE+=(--config-extra "$extra")
  # SERVE_ENV="K=V ...": extra serve environment, e.g. MACPROVIDER_CB_TRACE=1 for prefill-group timings.
  [ -z "${SERVE_ENV:-}" ] || SERVE+=(--serve-env "$SERVE_ENV")
  # SEED_SELF_CHECK_RUN: the stored verdict of that run applies at startup.
  [ -z "${SEED_SELF_CHECK_RUN:-}" ] || SERVE+=(--seed-self-check "$LAB/results/$SEED_SELF_CHECK_RUN/$name/main/serve/cb-self-check.json")
}

# reference_failed K DIR: the grid in DIR measured the provider but its reference failed.
reference_failed() {
  local line
  line=$(grep -m1 -E '^REFERENCE_(FAIL|SUSPECT) ' "$2/run.log" 2>/dev/null)
  log "${line:-REFERENCE_FAIL $(v "$1" NAME) (no marker in $2/run.log)}"
  blocker "model $1: the reference in $2 failed or is suspect; provider cells are measured, reference columns are empty"
}

run_model() {
  local k=$1 name rows ref_path ref_args=() tbr vpy
  name=$(v "$k" NAME)
  local M=$RES/$name
  mkdir -p "$M"
  vpy=$(v "$k" REF_PY)
  [ "$(v "$k" REF)" != omlx ] || vpy="$(v "$k" OMLX_DIR)/omlx-venv/bin/python"
  "$vpy" -c 'import importlib.metadata as m
for p in ("omlx", "mlx", "mlx-vlm", "mlx-lm", "transformers"):
    try: print("REF_VERSION", p, m.version(p))
    except m.PackageNotFoundError: pass'
  rows=$(v "$k" ROWS); rows=${rows:-1,4}
  ref_path=$(v "$k" REF_PATH)
  tbr=$(v "$k" TRIALS_BY_ROWS)
  [ -z "$(v "$k" REF_ARGS)" ] || for a in $(v "$k" REF_ARGS); do ref_args+=(--ref-arg "$a"); done
  if [ "$(v "$k" REF)" = omlx ]; then
    ref_args+=(--ref-arg --omlx-dir --ref-arg "$(v "$k" OMLX_DIR)" --ref-arg --state-root --ref-arg "$LAB/omlx-state")
  fi
  if [ -n "$REFERENCE_ONLY" ]; then
    reference_only "$k" "$M" "$rows" "$ref_path" ${ref_args[@]+"${ref_args[@]}"}
    return
  fi
  serve_args "$k" || return 1
  local reuse=()
  if [ -n "$REUSE_REFERENCE" ]; then
    mkdir -p "$M/main"
    cp "$LAB/results/$REUSE_REFERENCE/$name/main/reference.jsonl" "$M/main/" \
      || { blocker "model $k: reference copy from run $REUSE_REFERENCE failed"; return 1; }
    reuse=(--skip-reference)
    log "REFERENCE_REUSED $name from run $REUSE_REFERENCE ($(grep -c '"kind": "row"' "$M/main/reference.jsonl") rows)"
  fi
  log "GRID_START $name rows=$rows reference=$(v "$k" REF)${REUSE_REFERENCE:+ (reused from $REUSE_REFERENCE)} served_as=$(v "$k" ID) expect_route=$(expect_route "$k")${tbr:+ trials_by_rows=$tbr}"
  grid "$k" "$M/main" "${SERVE[@]}" --rows "$rows" --contexts "$CONTEXTS" --python "$(v "$k" REF_PY)" \
    --reference "$(v "$k" REF)" ${ref_path:+--ref-model-path "$ref_path"} ${ref_args[@]+"${ref_args[@]}"} \
    ${tbr:+--trials-by-rows "$tbr"} --expect-route "$(expect_route "$k")" ${reuse[@]+"${reuse[@]}"}
  local rc=$? ok=0
  log "GRID_DONE $name rc=$rc (0 all cells pass, 1 a cell fails the ratio/text gates: a finding, 8 the reference failed, 9 it was suspect, 10 the route was serial where production batches)"
  grep -E '^(REFERENCE_SANE|REFERENCE_SUSPECT|REFERENCE_FAIL) ' "$M/main/run.log" | sed 's/^/GRID_SANITY /'
  case $rc in 0|1|8|9|10) sed -n '/^| model/,/^$/p' "$M/main/summary.md" ;;
    *) blocker "model $k: grid rc=$rc: $(tail -n 3 "$M/main/run.log" | tr '\n' ' ')"; ok=1 ;; esac
  # The provider side ran: report the reference loudly, keep going, fail the job at the end.
  case $rc in 8|9) reference_failed "$k" "$M/main" ;; esac
  # A serial route where production batches: the cells are kept, the job fails at the end.
  route_failed "$M/main" && blocker "model $k: ROUTE_FAIL: the serve was serial but production batches this model; its multi-row cells are not the production route ($(grep -m1 '^ROUTE_FAIL ' "$M/main/run.log" | cut -c1-300))"
  if [ $ok = 0 ] && [ -n "$(v "$k" BASE_PATH)" ]; then
    log "BASE_START $name base=$(v "$k" BASE_ID)"
    mkdir -p "$M/base"
    local base_ref=() base_rcs="0"
    if [ "$(v "$k" BASE_REFERENCE)" = 1 ]; then
      base_ref=(--python "$(v "$k" REF_PY)" --reference "$(v "$k" REF)" --ref-model-path "$(v "$k" BASE_PATH)"
                ${ref_args[@]+"${ref_args[@]}"})
      base_rcs="0 1 8 9"
    else
      cp "$M/main/reference.jsonl" "$M/base/" 2>/dev/null
      base_ref=(--skip-reference --skip-compare)
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
      case $brc in 8|9) reference_failed "$k" "$M/base" ;; esac
    else
      blocker "model $k: base pass failed rc=$brc: $(tail -n 3 "$M/base/run.log" | tr '\n' ' ')"; ok=1
    fi
  fi
  if [ "$(v "$k" MTP_BENCH)" = 1 ]; then mtp_run "$k" || ok=1; fi
  return $ok
}

# mtp_summary DIR: the native_mtp counter change of every trial in DIR/provider.jsonl, summed per cell.
mtp_summary() {
  /usr/bin/python3 -I - "$1/provider.jsonl" <<'PY'
import collections, json, sys
tot = collections.defaultdict(lambda: [0, 0, 0, 0])
for line in open(sys.argv[1]):
    r = json.loads(line)
    nm = r.get("native_mtp")
    if r.get("kind") != "aggregate" or not nm:
        continue
    t = tot[(r["ctx_target"], r["max_tokens"], r["rows"])]
    t[0] += 1
    if nm.get("acceptance_valid"):
        t[1] += nm.get("proposed_tokens") or 0
        t[2] += nm.get("accepted_tokens") or 0
    else:
        t[3] += 1
for (ctx, out, rows), (n, prop, acc, bad) in sorted(tot.items()):
    print(f"MTP_CELL ctx={ctx} out={out} rows={rows} trials={n} proposed={prop} accepted={acc} "
          f"acceptance={round(acc / prop, 4) if prop else None} invalid_trials={bad}")
PY
}

# slots_check DIR WANT: the ROUTE slots at the grid start and end in DIR/grid.json equal WANT.
slots_check() {
  /usr/bin/python3 -I -c 'import json,sys
r=json.load(open(sys.argv[1])).get("route",{}); want=int(sys.argv[2])
got={p:(r.get(p) or {}).get("slots") for p in ("start","end")}
print("PASS_SLOTS want=%d start=%s end=%s verified_k=%s" % (want, got["start"], got["end"], (r.get("start") or {}).get("verified_k")))
sys.exit(0 if all(v==want for v in got.values()) else 1)' "$1/grid.json" "$2"
}

# run_pass K SPEC: one PASSES entry (job.sh header): its own serve and grid in $RES/<name>/<pass>,
# scored against the REUSE_REFERENCE rows.
run_pass() {
  local k=$1 name pdir rc ok=0 old_nm old_sl extra=()
  name=$(v "$k" NAME)
  parse_pass "$k" "$2" || { blocker "model $k: PASSES entry \"$2\": $KNOB_ERR"; return 1; }
  pdir=$RES/$name/$P_NAME
  mkdir -p "$pdir"
  if [ -n "$REUSE_REFERENCE" ]; then
    cp "$LAB/results/$REUSE_REFERENCE/$name/main/reference.jsonl" "$pdir/" \
      || { blocker "model $k: reference copy from run $REUSE_REFERENCE failed"; return 1; }
  else
    extra+=(--skip-compare)
  fi
  old_nm=$(v "$k" NATIVE_MTP); old_sl=$(v "$k" SERVED_SLOTS); old_smr=$(v "$k" SMALL_M_ROUTE)
  setv "$k" NATIVE_MTP "$P_NM"; setv "$k" SERVED_SLOTS "$P_SL"; setv "$k" SMALL_M_ROUTE "$P_SMR"
  SERVE_TAG=$P_NAME serve_args "$k"; rc=$?
  setv "$k" NATIVE_MTP "$old_nm"; setv "$k" SERVED_SLOTS "$old_sl"; setv "$k" SMALL_M_ROUTE "$old_smr"
  [ $rc = 0 ] || return 1
  [ "$P_NM" != auto ] || extra+=(--expect-native-mtp on)
  log "PASS_START $name $P_NAME rows=$P_ROWS native_mtp=${P_NM:-unset} served_slots=${P_SL:-auto} small_m_route=${P_SMR:-auto} contexts=$P_CTX outputs=$P_OUTS trials=$P_TRIALS turns=$TURNS turn2_header=${P_T2H:-${TURN2_HEADER:-0}} reference=${REUSE_REFERENCE:+reused from }${REUSE_REFERENCE:-none, no compare} seed=${SEED_SELF_CHECK_RUN:-none}"
  OUTPUTS=$P_OUTS TRIALS=$P_TRIALS TURN2_HEADER=${P_T2H:-${TURN2_HEADER:-0}} grid "$k" "$pdir" "${SERVE[@]}" --rows "$P_ROWS" --contexts "$P_CTX" \
    --skip-reference --expect-route "$(expect_route "$k")" ${extra[@]+"${extra[@]}"}
  rc=$?
  log "PASS_DONE $name $P_NAME rc=$rc (0 all cells pass, 1 a cell fails the ratio/text gates: a finding, 10 the route was serial where production batches, 11 native MTP was not on)"
  case $rc in
    0|1) [ ! -f "$pdir/summary.md" ] || sed -n '/^| model/,/^$/p' "$pdir/summary.md" ;;
    *) blocker "model $k: pass $P_NAME rc=$rc: $(tail -n 3 "$pdir/run.log" | tr '\n' ' ')"; ok=1 ;;
  esac
  [ "$P_NM" != auto ] || [ ! -f "$pdir/provider.jsonl" ] || mtp_summary "$pdir" | sed "s/^/PASS_MTP $name $P_NAME /"
  if [ -n "$P_SL" ] && [ -f "$pdir/grid.json" ]; then
    slots_check "$pdir" "$P_SL" | sed "s/^/$name $P_NAME /" | tee -a "$pdir/slots.txt"
    [ "${PIPESTATUS[0]}" = 0 ] || { blocker "model $k: pass $P_NAME served other slots than the pin $P_SL (verified_k above is the width the self-check verified)"; ok=1; }
  fi
  route_failed "$pdir" && { blocker "model $k: pass $P_NAME ROUTE_FAIL: the serve was serial but production batches this model"; ok=1; }
  return $ok
}

# run_passes K: every <K>_PASSES entry in order; a failed pass does not stop the next one. Then
# MTP_T2_COMPARE (header), which scores whatever the passes wrote.
run_passes() {
  local k=$1 spec ok=0 specs name rc dirs=()
  IFS=';' read -r -a specs <<< "$(v "$k" PASSES)"
  for spec in "${specs[@]}"; do run_pass "$k" "$spec" || ok=1; done
  [ -n "${MTP_T2_COMPARE:-}" ] || return $ok
  name=$(v "$k" NAME)
  set -- $MTP_T2_COMPARE
  dirs=(--native "$RES/$name/$1"); [ -z "${2:-}" ] || dirs+=(--ordinary "$RES/$name/$2")
  [ -z "${3:-}" ] || dirs+=(--cold "$RES/$name/$3")
  /usr/bin/python3 -I "$JOB/ablit-perf/mtp_turn2_compare.py" "${dirs[@]}" --json "$RES/$name/mtp-turn2.json" \
    > "$RES/$name/mtp-turn2.md"
  rc=$?
  sed "s/^/$name /" "$RES/$name/mtp-turn2.md" | grep -E "^$name T2_"
  case $rc in 0) ;; 1) log "T2_FINDING $name: parity, cache or native-MTP check failed (mtp-turn2.md)" ;;
    *) blocker "model $k: mtp_turn2_compare.py rc=$rc: $(tail -n 2 "$RES/$name/mtp-turn2.md" | tr '\n' ' ')"; ok=1 ;; esac
  return $ok
}

# reference_only K M ROWS REF_PATH [--ref-arg ARG]...: the reference over the stored provider
# cells of run $REFERENCE_ONLY, then compare (REFERENCE_ONLY header).
reference_only() {
  local k=$1 M=$2 rows=$3 ref_path=$4; shift 4
  local S=$SRC_RES/$(v "$k" NAME) name rc
  name=$(v "$k" NAME)
  mkdir -p "$M/main"
  cp "$S/main/provider.jsonl" "$M/main/" || { blocker "model $k: provider.jsonl copy failed"; return 1; }
  [ ! -f "$S/main/grid.json" ] || cp "$S/main/grid.json" "$M/main/"
  [ ! -f "$S/main/serve/status.json" ] || { mkdir -p "$M/main/serve" && cp "$S/main/serve/status.json" "$M/main/serve/"; }
  # The provider run's noise table and MTP bench (provider-only) for baseline.md.
  [ ! -f "$S/noise/vs-main.json" ] || { mkdir -p "$M/noise" && cp "$S/noise"/vs-main.* "$M/noise/"; }
  [ ! -d "$S/mtp" ] || cp -R "$S/mtp" "$M/"
  log "GRID_START $name reference-only provider_run=$REFERENCE_ONLY rows=$rows reference=$(v "$k" REF)"
  bash "$GRID/run-grid.sh" --reference-only --model-name "$name" --model-path "$(v "$k" PATH)" \
    --out-dir "$M/main" --rows "$rows" --trials "$TRIALS" --python "$(v "$k" REF_PY)" --reference "$(v "$k" REF)" \
    ${ref_path:+--ref-model-path "$ref_path"} "$@" > "$M/main/run.log" 2>&1
  rc=$?
  log "GRID_DONE $name rc=$rc (reference-only: 0/1 compare, 8 the reference failed, 9 it was suspect)"
  grep -E '^(REFERENCE_SANE|REFERENCE_SUSPECT|REFERENCE_FAIL) ' "$M/main/run.log" | sed 's/^/GRID_SANITY /'
  case $rc in
    0|1) sed -n '/^| model/,/^$/p' "$M/main/summary.md" ;;
    8|9) sed -n '/^| model/,/^$/p' "$M/main/summary.md"; reference_failed "$k" "$M/main"; return 1 ;;
    *) blocker "model $k: reference-only grid rc=$rc: $(tail -n 3 "$M/main/run.log" | tr '\n' ' ')"; return 1 ;;
  esac
}

noise_pass() {
  local k=$1 name seed=()
  [ -z "$REFERENCE_ONLY" ] || return 0  # the provider run's noise/ was copied
  name=$(v "$k" NAME)
  local M=$RES/$name
  [ -f "$M/main/provider.jsonl" ] || return 0
  if ! grep -q '"rows": 1,' "$M/main/provider.jsonl"; then
    log "NOISE_SKIPPED $name: the main pass has no 1-row cells"; return 0
  fi
  serve_args "$k" || return 1
  # The main serve's stored self-check verdict applies at startup, as after a restart.
  [ ! -f "$M/main/serve/cb-self-check.json" ] || seed=(--seed-self-check "$M/main/serve/cb-self-check.json")
  log "NOISE_START $name"
  mkdir -p "$M/noise" && { cp "$M/main/reference.jsonl" "$M/noise/" 2>/dev/null || true; }
  grid "$k" "$M/noise" "${SERVE[@]}" --rows 1 --contexts short --skip-reference --skip-compare \
    --expect-route "$(expect_route "$k")" ${seed[@]+"${seed[@]}"} \
    || { blocker "model $k: noise pass rc=$?: $(tail -n 3 "$M/noise/run.log" | tr '\n' ' ')"; return 1; }
  /usr/bin/python3 -I "$GRID/compare.py" --baseline "$M/main/provider.jsonl" --ours "$M/noise/provider.jsonl" \
    --subset --json "$M/noise/vs-main.json" > "$M/noise/vs-main.md"
  local rc=$?
  cat "$M/noise/vs-main.md"
  [ $rc = 0 ] || { blocker "model $k: the noise pass differs from the main pass in text or tokens (run-to-run nondeterminism)"; return 1; }
  log "NOISE_DONE $name"
}

for k in $STAGED; do
  if [ -n "$(v "$k" PASSES)" ]; then run_passes "$k" || FAILED=1; else run_model "$k" || FAILED=1; fi
done
for k in $STAGED; do noise_pass "$k" || FAILED=1; done
for k in $STAGED; do
  name=$(v "$k" NAME)
  [ -f "$RES/$name/main/summary.json" ] || continue
  /usr/bin/python3 -I "$JOB/ablit-perf/baseline_md.py" "$RES/$name" --model "$name" \
    --build "$(cut -c1-16 "$RES/identity.sha256" | head -n 1)" \
    --commit "${REFERENCE_ONLY:+${PROVIDER_COMMIT:-unknown}; provider run $REFERENCE_ONLY, reference pass $RUN_ID at }${COMMIT:-unknown}" \
    || blocker "model $k: baseline.md failed"
  log "BASELINE_MD $RES/$name/baseline.md"
done
[ "$FAILED" = 0 ] || { log "JOB_FAIL"; exit 1; }
log "JOB_PASS"
