#!/usr/bin/env bash
# Engine-333 Studio window: the engine fork sync (mlx-swift-lm 3.33.0 merge,
# mlx-swift 0.33.0, mlx core + #4883/#4881/#4930) against the current pin
# (.85 build), on an isolated loopback. Noninteractive; one model loaded at a time.
#
# usage: window.sh --base-bin DIR --new-bin DIR --out DIR [--lm-dir DIR] [--trials N] MODEL...
#   --base-bin  release build of the current pin (the live install copy, with its mlx.metallib)
#   --new-bin   release build of this campaign branch, with the mlx.metallib built from its
#               mlx-swift checkout (phase3-binary/scripts/build-mlx-metallib.sh)
#   --lm-dir    mlx-swift-lm checkout at the campaign commit: runs the heavy suites
#               the 32 GB M5 cannot (real checkpoints, large bitwise grids). Needs Xcode's
#               XCTest/Testing: DEVELOPER_DIR (default ~/Applications/Xcode.app).
#   MODEL       name=path@catalog_key[:mtp]
#
# Each model runs the production route of its catalog key, served under that key:
#  - cb pass: rows 1 and 4, short and 4k context, 128/512 output tokens. A model with a signed
#    continuous-batching entry (phase3-binary/catalog/autotune/continuous-batching-policy.json,
#    this hardware class) gets that entry's tuple as an accepted tuple, with the metallib
#    sha256 of the binary under test (the tuple names the metallib it was signed for; a new
#    engine ships a new one), and its ROUTE must be batched.
#  - mtp pass (":mtp", the key has a native-MTP admission entry): rows 1, native_mtp_mode auto
#    with the catalog provenance lines; run-grid --expect-native-mtp on fails a serve that does
#    not propose tokens.
# Every pass runs base, new, base. compare.py --baseline gates identical text and token counts
# (new vs the first base run) and reports decode tok/s, aggregate tok/s and TTFT; the second
# base run is the noise control. Exit 0 = every grid ran and every identity gate passed.
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
PG="$HERE/../parity-grid"
CAT="$HERE/../../../phase3-binary/catalog/autotune"
BASE="" NEW="" OUT="" LM="" TRIALS=3
MODELS=()
while [ $# -gt 0 ]; do
  case "$1" in
    --base-bin) BASE="$2"; shift 2 ;;
    --new-bin) NEW="$2"; shift 2 ;;
    --out) OUT="$2"; shift 2 ;;
    --lm-dir) LM="$2"; shift 2 ;;
    --trials) TRIALS="$2"; shift 2 ;;
    --*) echo "unknown argument: $1" >&2; exit 64 ;;
    *) MODELS+=("$1"); shift ;;
  esac
done
[ -n "$BASE" ] && [ -n "$NEW" ] && [ -n "$OUT" ] && [ ${#MODELS[@]} -gt 0 ] || {
  echo "usage: window.sh --base-bin DIR --new-bin DIR --out DIR [--lm-dir DIR] name=path@key[:mtp]..." >&2; exit 64; }
for b in "$BASE" "$NEW"; do
  [ -x "$b/macprovider-cli" ] || { echo "no macprovider-cli in $b" >&2; exit 64; }
  [ -s "$b/mlx.metallib" ] || { echo "no mlx.metallib in $b" >&2; exit 64; }
done
if lsof -nP -iTCP:8080 -sTCP:LISTEN >/dev/null 2>&1; then echo "8080 is listening: live provider not paused" >&2; exit 65; fi
mkdir -p "$OUT"
shasum -a 256 "$BASE/macprovider-cli" "$NEW/macprovider-cli" "$BASE/mlx.metallib" "$NEW/mlx.metallib" | tee "$OUT/binaries.sha256"
HW="apple-silicon:$(sysctl -n machdep.cpu.brand_string):ram-$(( $(sysctl -n hw.memsize) / 1073741824 ))gb"
echo "hardware_class $HW"
failed=0

if [ -n "$LM" ]; then
  echo "#### heavy mlx-swift-lm suites $(date +%T)"
  ( export DEVELOPER_DIR="${DEVELOPER_DIR:-$HOME/Applications/Xcode.app/Contents/Developer}"
    cd "$LM" && git rev-parse HEAD && swift build --build-tests && swift test --skip-build \
      --filter 'GLM5Next|GatherQMM|ReferencePrefill|ParoQuant|MatmulPrecision|Bitwise|LayerDump|TeacherForced|Gemma4MTPPackedDrafter' --skip DeepseekV4 --skip MiniMax ) \
    > "$OUT/heavy-suites.log" 2>&1
  rc=$?; echo "heavy suites rc=$rc"; [ $rc -eq 0 ] || { failed=1; grep -E "error:|failed" "$OUT/heavy-suites.log" | head -20; }
  grep -E "Test run with|Executed .* tests" "$OUT/heavy-suites.log" | tail -3
fi

# cb_extra KEY METALLIB_SHA FILE: the signed CB entry of KEY on this hardware class as an
# accepted tuple (with METALLIB_SHA); writes nothing and exits 3 when KEY has no entry.
cb_extra() {
  /usr/bin/python3 -I - "$CAT/continuous-batching-policy.json" "$1" "$HW" "$2" "$3" <<'PY'
import json, sys
policy, key, hw, metallib, out = sys.argv[1:6]
es = [e for e in json.load(open(policy))["entries"] if e["model_id"] == key and e["hardware_class"] == hw]
if not es:
    sys.exit(3)
e = dict(es[-1]); e["metallib_sha256"] = metallib
keys = ("model_id", "model_sha256", "tokenizer_sha256", "chat_template_sha256", "cache_class", "kv_dtype",
        "requires_moe", "hardware_class", "metallib_sha256", "kernel_identifier", "cached_turns_accepted")
open(out, "w").write("\n".join([
    "continuous_batching: canary", "continuous_batching_cached_turns: true",
    f"continuous_batch_queue_limit: {e.get('max_served_slots') or 4}",
    "continuous_batching_accepted_tuples:",
    "  - {" + ", ".join(f"{k}: {json.dumps(e[k])}" for k in keys if k in e) + "}"]) + "\n")
PY
}

# mtp_extra KEY SHA FILE: native_mtp_mode auto and the model_catalog_* provenance of KEY.
mtp_extra() {
  /usr/bin/python3 -I - "$CAT/autotune-candidates.json" "$1" "$2" "$3" <<'PY'
import hashlib, json, sys
cand, key, sha, out = sys.argv[1:5]
raw = open(cand, "rb").read(); doc = json.loads(raw); row = doc["rows"].get(key)
if row is None: sys.exit(f"no candidates row {key}")
if row["model_sha256"] != sha: sys.exit(f"candidates row {key} has sha {row['model_sha256']}, not {sha}")
q = json.dumps
open(out, "a").write("\n".join([
    "native_mtp_mode: auto", f"model_catalog_key: {q(key)}", f"model_catalog_model_id: {q(row['model_id'])}",
    f"model_catalog_revision: {q(row['model_revision'])}", f"model_catalog_sha256: {q(sha)}",
    f"model_catalog_version: {q(doc['version'])}", f"model_catalog_hash: {q(hashlib.sha256(raw).hexdigest())}"]) + "\n")
PY
}

for spec in "${MODELS[@]}"; do
  name="${spec%%=*}"; rest="${spec#*=}"
  pathkey="${rest%%:*}"; mtp=""; [ "$rest" = "$pathkey" ] || mtp="${rest#*:}"
  path="${pathkey%@*}"; key="${pathkey##*@}"; sha="$(basename "$path")"
  passes="cb"; [ "$mtp" = mtp ] && passes="cb mtp"
  for pass in $passes; do
    M="$OUT/$name/$pass"; mkdir -p "$M"
    for run in base1:"$BASE" new:"$NEW" base2:"$BASE"; do
      tag="${run%%:*}"; bin="${run#*:}"; R="$M/$tag"; rm -rf "$R"; mkdir -p "$R"
      msha=$(shasum -a 256 "$bin/mlx.metallib" | cut -d' ' -f1)
      extra="$R/serve-extra.yaml"; : > "$extra"; route=any
      cb_extra "$key" "$msha" "$extra"; crc=$?
      if [ $crc -eq 0 ]; then route=batched; elif [ $crc -ne 3 ]; then echo "cb tuple failed for $key"; failed=1; continue; fi
      rows=1,4
      if [ "$pass" = mtp ]; then
        mtp_extra "$key" "$sha" "$extra" || { echo "mtp provenance failed for $key"; failed=1; continue; }
        rows=1; route=any
      fi
      args=(--model-path "$path" --model-id "$key" --model-sha256 "$sha" --model-name "$name" --bin-dir "$bin"
            --out-dir "$R" --trials "$TRIALS" --skip-reference --skip-compare --cb auto --no-autotune-candidate
            --rows "$rows" --outputs 128,512 --contexts short,4k --expect-route "$route" --config-extra "$extra")
      [ "$pass" = mtp ] && args+=(--expect-native-mtp on)
      echo "#### $name $pass $tag $(date +%T)"
      bash "$PG/run-grid.sh" "${args[@]}" > "$R/run.log" 2>&1
      rc=$?; echo "grid rc=$rc $name $pass $tag"; [ $rc -eq 0 ] || { failed=1; tail -8 "$R/run.log"; }
      grep -h "^ROUTE\|NATIVE_MTP\|CB_WARMUP_DONE" "$R/run.log" | tail -4
    done
    for cand in new base2; do
      [ -f "$M/base1/provider.jsonl" ] && [ -f "$M/$cand/provider.jsonl" ] || { echo "compare $name $pass $cand: missing provider.jsonl"; failed=1; continue; }
      /usr/bin/python3 -I "$PG/compare.py" --baseline "$M/base1/provider.jsonl" --ours "$M/$cand/provider.jsonl" \
        --json "$M/compare-$cand.json" > "$M/compare-$cand.md" 2>&1
      rc=$?; echo "compare $name $pass $cand vs base1 rc=$rc"; cat "$M/compare-$cand.md"
      [ "$cand" = base2 ] || [ $rc -eq 0 ] || failed=1
    done
  done
done
echo "== window done $(date +%T) failed=$failed"
exit $failed
