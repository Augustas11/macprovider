#!/bin/bash
# Runs ON THE STUDIO from ~/lab-ablit-perf/job/ablit-perf/, started by studio-ablit-perf.sh
# (JOB_SCRIPT=job-qwen-mtp-cap.sh). Issue #2429: Qwen native MTP at proposal depth 1 against
# native MTP off, one row, above the signed 4096-token prompt cap. Per model, one
# native-mtp-bench process per cell (SPEC-048 R015 bench, paired native/ordinary blocks,
# greedy-token parity on every pair) under an exploratory policy: slots [1], prompts
# QMTP_PROMPTS (default 8192,16384,32768), outputs QMTP_OUTPUTS (default 512), QMTP_BLOCKS
# (default 5) blocks, the current SPEC-048 gate set, then the R015 analyzer.
#
# Steps: build (job.sh's .build-lab-harness path, -DMACPROVIDER_LAB_HARNESS) with the release
# metallib beside it; per model a fixture under ~/lab-ablit-perf/models/<key>-mtp-cap-fixture
# (target/ and mtp/ are APFS clones, symlinks followed, of the read-only store or Hugging Face
# cache snapshots); the policy (artifact identities from the model table below, this machine's
# environment, fixed by the bench validator's `observed=` value as in job.sh mtp_prepare);
# --validate-policy-only; the cells; analysis.json / analysis.md.
#
# Models (QMTP_MODELS, default "qwen36-35b qwen36-27b qwen38-27b"): the three signed Qwen
# native-MTP tuples. QMTP_PROBE=1: the first model only, one cell (first prompt, first output),
# 2 blocks: the preflight probe through the exact path. QMTP_SHAPE (default tools_history_reasoning):
# the bench request_shape. With plain_text the synthetic long prompts make Qwen stop after ~29 tokens
# at 16K and 32K (run 20261119T144620Z), so decode is not measured; the reasoning shape (a tool
# history turn, reasoning_effort high) decodes to the output budget.
# QMTP_FORMAL=1 QMTP_CAP=<C>: the formal SPEC-048 R015 admission matrix at signed cap C instead
# (the full-matrix path for a cap raise when no cap extension applies): schema
# macprovider.native-mtp-r015-policy.v1, prompts 1536/4096/C, outputs 128/512, 10 blocks, the gated
# cells s2 and s<qualified_slots> at p1536-o512, then the 1800 s sustained window on
# s<qualified_slots>-p1536-o512, plain_text, the current gate set; the analyzer gives the verdict.
# QMTP_FORMAL_BLOCKS (default 10, 10..20): the formal matrix's preregistered block count.
# QMTP_EXCLUSION (default none): the policy's preregistered SPEC-048 MTP-15 exclusion_rules, none
# or single_token_identical_pair (a block whose two paths each emit the same single token feeds
# the hard gates, not the decode statistics; the cell still needs ten measurable blocks). The
# Qwen3.8-27B s1-p32768-o128 block 9 prompt stops after one identical token on both paths (run
# 20261119T164215Z); prompts do not depend on the seed, so its formal rerun freezes the rule and
# 11 blocks.
# Results: ~/lab-ablit-perf/results/<run>/qwen-mtp-cap/<model>/{policy.json,bench.jsonl,
# analysis.json,analysis.md,identity.sha256,<cell>.log}. Every failure prints `BLOCKER:`; the job
# ends with JOB_PASS or JOB_FAIL. A slower native path is a finding, not a failure.
set -u
export PATH=/usr/sbin:/opt/homebrew/bin:/usr/bin:/bin
LAB=$HOME/lab-ablit-perf
JOB=$LAB/job
SRC=$LAB/src/phase3-binary
STORE="$HOME/Library/Application Support/macprovider/models"
HF="$HOME/.cache/huggingface/hub"
RUN_ID=${RUN_ID:-$(date -u +%Y%m%dT%H%M%SZ)}
RES=$LAB/results/$RUN_ID/qwen-mtp-cap
QMTP_MODELS=${QMTP_MODELS:-qwen36-35b qwen36-27b qwen38-27b}
QMTP_PROMPTS=${QMTP_PROMPTS:-8192,16384,32768}
QMTP_OUTPUTS=${QMTP_OUTPUTS:-512}
QMTP_BLOCKS=${QMTP_BLOCKS:-5}
QMTP_PROBE=${QMTP_PROBE:-0}
QMTP_SHAPE=${QMTP_SHAPE:-tools_history_reasoning}
QMTP_FORMAL=${QMTP_FORMAL:-0}
QMTP_CAP=${QMTP_CAP:-}
QMTP_FORMAL_BLOCKS=${QMTP_FORMAL_BLOCKS:-10}
QMTP_EXCLUSION=${QMTP_EXCLUSION:-none}
METALLIB=${METALLIB:-/Applications/Malibu.app/Contents/MacOS/mlx.metallib}
BUILD=.build-lab-harness
BIN=$SRC/$BUILD/release
FAILED=0
log() { echo "$(date '+%H:%M:%S') $*"; }
blocker() { log "BLOCKER: $*"; FAILED=1; }
die() { log "BLOCKER: $*"; log "JOB_FAIL"; exit "${2:-1}"; }

# model K: sets ID TARGET MTP QSLOTS TSHA MSHA TOK (identities: the tuple's signed R015 policy,
# docs/evidence/qwen27b-native-mtp-2026-11-04/*/r015-policy.json and
# docs/research/spec048-r015/qwen36-35b-r015-2026-10-21/qualification-policy.json).
# store_snap REPO_DIR SHA [FALLBACK]: the provider-store snapshot of that artifact, else FALLBACK (read only).
store_snap() {
  local d
  for d in "$STORE/$1"/*/"$2"; do [ -f "$d/config.json" ] && { echo "$d"; return; }; done
  echo "${3:-$STORE/$1/<revision>/$2}"
}
model() {
  case $1 in
    qwen36-35b) ID=qwen/qwen3.6-35b-a3b; QSLOTS=8
      TSHA=3fed776d41b6883888541d19f71a3866acc3bc6e628402066b67e5ac0a676ff1
      MSHA=fa01beecb6c1e76845e9880623c3b5a009baa602c52e9e9b5d12edc489a23fd2
      TOK=87a7830d63fcf43bf241c3c5242e96e62dd3fdc29224ca26fed8ea333db72de4
      TARGET=$(store_snap mlx-community--Qwen3.6-35B-A3B-4bit "$TSHA")
      MTP=$(store_snap mlx-community--Qwen3.6-35B-A3B-MTP-4bit "$MSHA") ;;
    qwen36-27b) ID=qwen/qwen3.6-27b; QSLOTS=4
      TSHA=518ef47c298783d8547b50406e84548e5bf7705b82355a38f9eaef1368817931
      MSHA=88b6d3e0026e3f2255e857073aaba2df2f619debc46956daf996e37c4a92d556
      TOK=87a7830d63fcf43bf241c3c5242e96e62dd3fdc29224ca26fed8ea333db72de4
      TARGET=$(store_snap mlx-community--Qwen3.6-27B-4bit "$TSHA" "$HF/models--mlx-community--Qwen3.6-27B-4bit/snapshots/c000ac2c2057d94be3fa931000c31723aac53282")
      MTP=$HF/models--mlx-community--Qwen3.6-27B-MTP-4bit/snapshots/83795d546e9d328160e593fb0bf10b2bf2fe637e ;;
    qwen38-27b) ID=qwen/qwen3.8-27b; QSLOTS=4
      TSHA=8a8786e902127e9175f5be0d7c8bcf4dd32323a0521e4d9a20761608a07a6d05
      MSHA=25d2e7e3846c6a95201b13a0299eb65527b8146541af3b1eb626eaac95fefb30
      TOK=06b9509352d2af50381ab2247e083b80d32d5c0aba91c272ca9ff729b6a0e523
      TARGET=$(store_snap mlx-community--Qwen3.8-27B-4bit "$TSHA")
      MTP=$HF/models--mlx-community--Qwen3.8-27B-MTP-4bit/snapshots/b643c01b6d3b094e325edb6ebd832e16c486c575 ;;
    *) return 1 ;;
  esac
}

case "$QMTP_PROMPTS" in ""|*[!0-9,]*|,*|*,|*,,*) die "QMTP_PROMPTS must be a comma list" 64 ;; esac
case "$QMTP_OUTPUTS" in ""|*[!0-9,]*|,*|*,|*,,*) die "QMTP_OUTPUTS must be a comma list" 64 ;; esac
case "$QMTP_SHAPE" in plain_text|tools_history_reasoning) ;; *) die "QMTP_SHAPE must be plain_text or tools_history_reasoning" 64 ;; esac
case "$QMTP_BLOCKS" in [2-9]|10) ;; *) die "QMTP_BLOCKS must be 2..10" 64 ;; esac
case "$QMTP_FORMAL_BLOCKS" in 1[0-9]|20) ;; *) die "QMTP_FORMAL_BLOCKS must be 10..20" 64 ;; esac
case "$QMTP_EXCLUSION" in none|single_token_identical_pair) ;; *) die "QMTP_EXCLUSION must be none or single_token_identical_pair" 64 ;; esac
echo "${COMMIT:-}" | grep -Eq '^[0-9a-f]{40}$' || die "COMMIT (40-hex provider commit) is unset" 64
if [ "$QMTP_FORMAL" = 1 ]; then
  case "$QMTP_CAP" in ""|*[!0-9]*) die "QMTP_FORMAL needs QMTP_CAP (the signed prompt cap to qualify)" 64 ;; esac
  [ "$QMTP_CAP" -gt 4096 ] || die "QMTP_CAP must exceed 4096" 64
  [ "$QMTP_PROBE" = 1 ] && die "QMTP_FORMAL and QMTP_PROBE exclude each other" 64
  QMTP_PROMPTS=1536,4096,$QMTP_CAP; QMTP_OUTPUTS=128,512; QMTP_BLOCKS=$QMTP_FORMAL_BLOCKS; QMTP_SHAPE=plain_text
fi
if [ "$QMTP_PROBE" = 1 ]; then
  QMTP_MODELS=${QMTP_MODELS%% *}; QMTP_PROMPTS=${QMTP_PROMPTS%%,*}; QMTP_OUTPUTS=${QMTP_OUTPUTS%%,*}; QMTP_BLOCKS=2
fi
for k in $QMTP_MODELS; do
  model "$k" || die "unknown model $k" 64
  [ -f "$TARGET/config.json" ] || die "model $k: no target snapshot at $TARGET" 11
  [ -f "$MTP/config.json" ] || die "model $k: no drafter snapshot at $MTP" 11
done

mkdir -p "$RES"
log "JOB_START qwen-mtp-cap run=$RUN_ID commit=$COMMIT models=\"$QMTP_MODELS\" prompts=$QMTP_PROMPTS outputs=$QMTP_OUTPUTS blocks=$QMTP_BLOCKS shape=$QMTP_SHAPE probe=$QMTP_PROBE formal=$QMTP_FORMAL${QMTP_CAP:+ cap=$QMTP_CAP} exclusion=$QMTP_EXCLUSION"
if lsof -nP -iTCP:8080 -sTCP:LISTEN -t >/dev/null 2>&1; then die "a server listens on :8080; the Studio is not paused" 3; fi
launchctl print "gui/$(id -u)/live.malibu.provider" >/dev/null 2>&1 && die "live.malibu.provider is loaded" 3
pgrep -f "[m]acprovider-cli serve" >/dev/null 2>&1 && die "a macprovider-cli serve process runs" 3

# 1. Build (job.sh's lab-harness build path).
if [ "${SKIP_BUILD:-0}" != 1 ]; then
  log "BUILD start"
  (cd "$SRC" && nice -n 10 swift build -c release --product macprovider-cli --build-path "$BUILD" \
    -Xswiftc -DMACPROVIDER_LAB_HARNESS) > "$RES/build.log" 2>&1 \
    || die "swift build failed: $(tail -n 3 "$RES/build.log" | tr '\n' ' ')" 14
fi
[ -x "$BIN/macprovider-cli" ] || die "no lab-harness binary at $BIN" 14
cp "$METALLIB" "$BIN/mlx.metallib" || die "metallib copy failed" 14
log "BUILD done cli_sha256=$(shasum -a 256 "$BIN/macprovider-cli" | cut -c1-16) metallib_sha256=$(shasum -a 256 "$BIN/mlx.metallib" | cut -c1-16)"

bench() {  # bench K ARGS...
  (cd "$BIN" && env MACPROVIDER_NATIVE_MTP_E2E=1 ./macprovider-cli native-mtp-bench --root "$FIXTURE" \
    --model-id "$ID" --policy "$DIR/policy.json" --provider-commit "$COMMIT" "$@")
}

run_model() {
  local k=$1 i err cell p o rc ok=1 xcode swift fork
  model "$k"
  DIR=$RES/$k; FIXTURE=$LAB/models/$k-mtp-cap-fixture
  mkdir -p "$DIR"
  rm -rf -- "$FIXTURE" && mkdir -p "$FIXTURE" \
    && /bin/cp -c -R -L "$TARGET" "$FIXTURE/target" && /bin/cp -c -R -L "$MTP" "$FIXTURE/mtp" \
    || { blocker "model $k: fixture clone failed"; return 1; }
  xcode=$(/usr/bin/xcodebuild -version 2>/dev/null | sed -n 's/^Build version //p' | head -n 1)
  swift=$(/usr/bin/xcrun swift --version 2>/dev/null | head -n 1)
  fork=$(sed -n 's/.*static let mlxSwiftLMRevision = "\([0-9a-f]*\)".*/\1/p' "$SRC/Sources/macprovider-cli/KVConversationColdTierAdapter.swift")
  /usr/bin/python3 -I - "$DIR/policy.json" "$ID" "$TSHA" "$MSHA" "$TOK" "$QSLOTS" "$QMTP_PROMPTS" "$QMTP_OUTPUTS" \
    "$QMTP_BLOCKS" "$(sysctl -n hw.model)" "$(sysctl -n kern.osversion)" "${xcode:-unknown}" "${swift:-unknown}" \
    "$COMMIT" "$fork" "$QMTP_SHAPE" "$QMTP_FORMAL" "$QMTP_EXCLUSION" <<'PY' || { blocker "model $k: policy generation failed"; return 1; }
import json, sys
out, mid, tsha, msha, tok, qs, prompts, outputs, blocks, hw, osb, xcode, swift, commit, fork, shape, formal, exclusion = sys.argv[1:19]
if len(fork) != 40:
    sys.exit("mlxSwiftLMRevision not found in the source tree")
prompts = [int(x) for x in prompts.split(",")]
outputs = [int(x) for x in outputs.split(",")]
p = {
    "schema": "macprovider.native-mtp-exploratory-policy.v1", "model_id": mid, "target_sha256": tsha,
    "mtp_sha256": msha, "tokenizer_sha256": tok, "hw_model": hw, "chip": "Apple M3 Ultra", "ram_gb": 256,
    "os_build": osb, "xcode_build_version": xcode, "swift_version": swift, "provider_commit": commit,
    "mlx_fork_revision": fork, "quantization": "4bit", "cache_mode": "paged_kv_mixed", "proposal_depth": 1,
    "run_order": "seeded_random_counterbalanced", "prompt_corpus": "deterministic_synthetic_unique_v2",
    "exclusion_rules": exclusion, "confidence_method": "paired_block_bootstrap_holm_v1",
    "qualified_slots": int(qs), "max_native_active_rows": 1, "arrival_interval_ms": 250, "slots": [1],
    "maximum_prompt_tokens": max(prompts), "prompt_tokens": prompts, "max_tokens": outputs,
    "gated_cells": [], "request_shape": shape, "warmup_runs": 1, "blocks": int(blocks), "seed": 20261119, "sustained_seconds": 0,
    "sustained_cell_id": f"s1-p{max(prompts)}-o{max(outputs)}", "memory_safety_margin_bytes": 8589934592,
    # SPEC-048 0.1.71 gate set (FROZEN_THRESHOLDS in scripts/native_mtp_r015_analyze.py).
    "thresholds": {"throughput_lower_bound_min": 0.0, "ttft_p95_upper_bound_max": 0.1,
        "tpot_p95_upper_bound_max": 0.0, "chunk_gap_p99_upper_bound_max": 1.0,
        "rejection_increase_max_pp": 1.0, "min_available_memory_fraction": 0.1, "bootstrap_draws": 10000,
        "alpha": 0.05, "gated_throughput_lower_bound_min": -0.05, "gated_ttft_p95_upper_bound_max": 0.05,
        "gated_tpot_p95_upper_bound_max": 0.05},
}
if formal == "1":
    # SPEC-048-R015 mandatory matrix at cap max(prompts): gated cells at bound + 1 and
    # qualified_slots, the 1800 s sustained window at qualified_slots (p1536-o512).
    qsn = int(qs)
    p.update({"schema": "macprovider.native-mtp-r015-policy.v1", "gated_cells": [f"s{n}-p1536-o512" for n in sorted({2, qsn})],
              "sustained_seconds": 1800, "sustained_cell_id": f"s{qsn}-p1536-o512"})
json.dump(p, open(out, "w"), indent=2, sort_keys=True)
PY
  for i in 1 2 3 4 5 6 7 8; do
    bench --out "$DIR/validate.jsonl" --validate-policy-only --identity-cache "$LAB/mtp-identity-cache.json" \
      > "$DIR/validate.out" 2> "$DIR/validate.err" && break
    err=$(cat "$DIR/validate.out" "$DIR/validate.err")
    /usr/bin/python3 -I - "$DIR/policy.json" "$err" <<'PY' || { blocker "model $k: native-mtp-bench refuses the policy: $(echo "$err" | tr '\n' ' ' | cut -c1-400)"; return 1; }
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
    [ "$i" = 8 ] && { blocker "model $k: policy still refused after 8 environment fixes"; return 1; }
  done
  log "MTP_VALIDATED $k policy_sha256=$(shasum -a 256 "$DIR/policy.json" | cut -c1-16)"
  shasum -a 256 "$BIN/macprovider-cli" "$BIN/mlx.metallib" "$DIR/policy.json" > "$DIR/identity.sha256"
  rm -f "$DIR/bench.jsonl"
  for p in ${QMTP_PROMPTS//,/ }; do
    for o in ${QMTP_OUTPUTS//,/ }; do
      cell=s1-p$p-o$o
      log "MTP_CELL_START $k $cell"
      bench --out "$DIR/bench.jsonl" --only-cell "$cell" --phase matrix > "$DIR/$cell.out" 2> "$DIR/$cell.log"
      rc=$?
      log "MTP_CELL_DONE $k $cell rc=$rc records=$(wc -l < "$DIR/bench.jsonl" 2>/dev/null | tr -d ' ')"
      [ $rc = 0 ] || { blocker "model $k: $cell rc=$rc: $(tail -n 2 "$DIR/$cell.log" | tr '\n' ' ' | cut -c1-300)"; ok=0; }
    done
  done
  if [ "$QMTP_FORMAL" = 1 ] && [ $ok = 1 ]; then
    for cell in $(/usr/bin/python3 -I -c 'import json,sys; print(" ".join(json.load(open(sys.argv[1]))["gated_cells"]))' "$DIR/policy.json"); do
      log "MTP_CELL_START $k $cell"
      bench --out "$DIR/bench.jsonl" --only-cell "$cell" --phase matrix > "$DIR/$cell.out" 2> "$DIR/$cell.log"
      rc=$?
      log "MTP_CELL_DONE $k $cell rc=$rc records=$(wc -l < "$DIR/bench.jsonl" 2>/dev/null | tr -d ' ')"
      [ $rc = 0 ] || { blocker "model $k: $cell rc=$rc: $(tail -n 2 "$DIR/$cell.log" | tr '\n' ' ' | cut -c1-300)"; ok=0; break; }
    done
    if [ $ok = 1 ]; then
      log "MTP_CELL_START $k sustained"
      bench --out "$DIR/bench.jsonl" --phase sustained > "$DIR/sustained.out" 2> "$DIR/sustained.log"
      rc=$?
      log "MTP_CELL_DONE $k sustained rc=$rc records=$(wc -l < "$DIR/bench.jsonl" 2>/dev/null | tr -d ' ')"
      [ $rc = 0 ] || { blocker "model $k: sustained rc=$rc: $(tail -n 2 "$DIR/sustained.log" | tr '\n' ' ' | cut -c1-300)"; ok=0; }
    fi
  fi
  /usr/bin/python3 -I "$JOB/mtp/native_mtp_r015_analyze.py" "$DIR/bench.jsonl" "$DIR/policy.json" > "$DIR/analysis.json" 2> "$DIR/analysis.err"
  /usr/bin/python3 -I "$JOB/mtp/native_mtp_r015_analyze.py" "$DIR/bench.jsonl" "$DIR/policy.json" --format markdown > "$DIR/analysis.md" 2>> "$DIR/analysis.err"
  log "MTP_DONE $k analyzer=$(/usr/bin/python3 -I -c 'import json,sys; print(json.load(open(sys.argv[1])).get("overall_status"))' "$DIR/analysis.json" 2>/dev/null)"
  sed 's/^/MTP_TABLE /' "$DIR/analysis.md" 2>/dev/null
  rm -rf -- "$FIXTURE"
  [ $ok = 1 ]
}

for k in $QMTP_MODELS; do run_model "$k" || FAILED=1; done
[ $FAILED = 0 ] && log "JOB_PASS" || { log "JOB_FAIL"; exit 1; }
