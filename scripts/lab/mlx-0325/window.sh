#!/usr/bin/env bash
# mlx v0.32.5 fork-sync window: GLM-5.3-Flash native-MTP verify and CB throughput at 4, 8 and 16
# rows, the merged core (fork stack + upstream v0.32.5) against the current pin, on an isolated
# loopback. Noninteractive; one model loaded at a time. Adapted from scripts/lab/engine-333/window.sh
# (same tuple/provenance helpers and gate.py).
#
# usage: window.sh --base-bin DIR --new-bin DIR --out DIR [--trials N] name=path@catalog_key
#   --base-bin  release build of origin/main (the current pin) with its mlx.metallib
#   --new-bin   release build of this campaign branch with its mlx.metallib
# env: ROWS (default 4,8,16), OUTPUTS (default 256), CONTEXTS (default short,4k),
#      QUEUE_LIMIT (default 16: the lab serve admits up to 16 rows; live GLM is capped at
#      max_served_slots 4, so 8 and 16 are lab cells), PASSES (default "cb mtp").
# Each pass runs base1, new, base2 (candidate between two controls), and the mtp pass adds ref
# (new binary, native MTP off, small_m_route row_invariant) for SPEC-048 R015 token parity.
# compare.py scores new against base1 and against base2; gate.py (engine-333) gates text identity
# and speed bands per pass. Exit 0 = every grid ran and every gate passed.
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
PG="$HERE/../parity-grid"; G333="$HERE/../engine-333"
CAT="$HERE/../../../phase3-binary/catalog/autotune"
BASE="" NEW="" OUT="" TRIALS=6
MODELS=()
while [ $# -gt 0 ]; do
  case "$1" in
    --base-bin) BASE="$2"; shift 2 ;;
    --new-bin) NEW="$2"; shift 2 ;;
    --out) OUT="$2"; shift 2 ;;
    --trials) TRIALS="$2"; shift 2 ;;
    --*) echo "unknown argument: $1" >&2; exit 64 ;;
    *) MODELS+=("$1"); shift ;;
  esac
done
[ -n "$BASE" ] && [ -n "$NEW" ] && [ -n "$OUT" ] && [ ${#MODELS[@]} -gt 0 ] || {
  echo "usage: window.sh --base-bin DIR --new-bin DIR --out DIR name=path@key..." >&2; exit 64; }
for b in "$BASE" "$NEW"; do
  [ -x "$b/macprovider-cli" ] || { echo "no macprovider-cli in $b" >&2; exit 64; }
  [ -s "$b/mlx.metallib" ] || { echo "no mlx.metallib in $b" >&2; exit 64; }
done
if lsof -nP -iTCP:8080 -sTCP:LISTEN >/dev/null 2>&1; then echo "8080 is listening: live provider not paused" >&2; exit 65; fi
mkdir -p "$OUT"
shasum -a 256 "$BASE/macprovider-cli" "$NEW/macprovider-cli" "$BASE/mlx.metallib" "$NEW/mlx.metallib" | tee "$OUT/binaries.sha256"
HW="apple-silicon:$(sysctl -n machdep.cpu.brand_string):ram-$(( $(sysctl -n hw.memsize) / 1073741824 ))gb"
echo "hardware_class $HW"
ROWS="${ROWS:-4,8,16}" OUTPUTS="${OUTPUTS:-256}" CONTEXTS="${CONTEXTS:-short,4k}" QL="${QUEUE_LIMIT:-16}"
failed=0

cb_extra() {  # KEY METALLIB_SHA FILE: the signed CB entry of KEY as an accepted tuple (exit 3: none)
  /usr/bin/python3 -I - "$CAT/continuous-batching-policy.json" "$1" "$HW" "$2" "$3" "$QL" <<'PY'
import json, sys
policy, key, hw, metallib, out, ql = sys.argv[1:7]
es = [e for e in json.load(open(policy))["entries"] if e["model_id"] == key and e["hardware_class"] == hw]
if not es:
    sys.exit(3)
e = dict(es[-1]); e["metallib_sha256"] = metallib
keys = ("model_id", "model_sha256", "tokenizer_sha256", "chat_template_sha256", "cache_class", "kv_dtype",
        "requires_moe", "hardware_class", "metallib_sha256", "kernel_identifier", "cached_turns_accepted")
open(out, "w").write("\n".join([
    "continuous_batching: canary", "continuous_batching_cached_turns: true",
    f"continuous_batch_queue_limit: {ql}",
    "continuous_batching_accepted_tuples:",
    "  - {" + ", ".join(f"{k}: {json.dumps(e[k])}" for k in keys if k in e) + "}"]) + "\n")
PY
}

mtp_extra() {  # KEY SHA FILE: native_mtp_mode auto and the model_catalog_* provenance of KEY
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

cmp() {  # BASELINE_TAG CANDIDATE_TAG PASS_DIR [--subset]
  local M="$3"
  [ -f "$M/$1/provider.jsonl" ] && [ -f "$M/$2/provider.jsonl" ] || { echo "compare $2 vs $1: missing provider.jsonl"; return; }
  /usr/bin/python3 -I "$PG/compare.py" ${4:-} --baseline "$M/$1/provider.jsonl" --ours "$M/$2/provider.jsonl" \
    --json "$M/compare-$2-vs-$1.json" > "$M/compare-$2-vs-$1.md" 2>&1
  echo "compare $2 vs $1 rc=$?"; cat "$M/compare-$2-vs-$1.md"
}

for spec in "${MODELS[@]}"; do
  name="${spec%%=*}"; pathkey="${spec#*=}"
  path="${pathkey%@*}"; key="${pathkey##*@}"; sha="$(basename "$path")"
  for pass in ${PASSES:-cb mtp}; do
    M="$OUT/$name/$pass"; mkdir -p "$M"
    runs=(base1:"$BASE" new:"$NEW" base2:"$BASE")
    [ "$pass" = mtp ] && runs+=(ref:"$NEW")
    for run in "${runs[@]}"; do
      tag="${run%%:*}"; bin="${run#*:}"
      R="$M/$tag"; rm -rf "$R"; mkdir -p "$R"
      msha=$(shasum -a 256 "$bin/mlx.metallib" | cut -d' ' -f1)
      extra="$R/serve-extra.yaml"; : > "$extra"; route=any
      cb_extra "$key" "$msha" "$extra"; crc=$?
      if [ $crc -eq 0 ]; then route=batched; elif [ $crc -ne 3 ]; then echo "cb tuple failed for $key"; failed=1; continue; fi
      if [ "$pass" = mtp ] && [ "$tag" = ref ]; then
        echo "small_m_route: row_invariant" >> "$extra"
      elif [ "$pass" = mtp ]; then
        mtp_extra "$key" "$sha" "$extra" || { echo "mtp provenance failed for $key"; failed=1; continue; }
      fi
      args=(--model-path "$path" --model-id "$key" --model-sha256 "$sha" --model-name "$name" --bin-dir "$bin"
            --out-dir "$R" --trials "$TRIALS" --skip-reference --skip-compare --cb auto --no-autotune-candidate
            --rows "$ROWS" --outputs "$OUTPUTS" --contexts "$CONTEXTS" --expect-route "$route" --config-extra "$extra" --lab-fence)
      [ "$pass" = mtp ] && [ "$tag" != ref ] && args+=(--expect-native-mtp on)
      echo "#### $name $pass $tag $(date +%T)"
      bash "$PG/run-grid.sh" "${args[@]}" > "$R/run.log" 2>&1
      rc=$?; echo "grid rc=$rc $name $pass $tag"
      if [ $rc -ne 0 ]; then tail -8 "$R/run.log"; failed=1; fi
      grep -h "^ROUTE\|NATIVE_MTP\|CB_WARMUP_DONE\|served_slots" "$R/run.log" | tail -5
    done
    cmp base1 new "$M"; cmp base2 new "$M"; cmp base1 base2 "$M"
    # gate.py reads compare-new.json / compare-base2.json (both against base1)
    cp -f "$M/compare-new-vs-base1.json" "$M/compare-new.json" 2>/dev/null
    cp -f "$M/compare-base2-vs-base1.json" "$M/compare-base2.json" 2>/dev/null
    if [ "$pass" = mtp ]; then
      cmp ref new "$M" --subset; cp -f "$M/compare-new-vs-ref.json" "$M/compare-new-mtp-vs-ref.json" 2>/dev/null
      if [ -f "$OUT/$name/cb/new/provider.jsonl" ]; then
        /usr/bin/python3 -I "$PG/compare.py" --subset --baseline "$OUT/$name/cb/new/provider.jsonl" \
          --ours "$M/new/provider.jsonl" --json "$M/compare-new-mtp-vs-new-ordinary.json" > "$M/compare-new-mtp-vs-new-ordinary.md" 2>&1
        echo "compare new native MTP vs new ordinary rc=$?"; cat "$M/compare-new-mtp-vs-new-ordinary.md"
      fi
    fi
    /usr/bin/python3 -I "$G333/gate.py" --pass "$pass" "$M" | tee "$M/gate.txt"
    [ "${PIPESTATUS[0]}" -eq 0 ] || failed=1
  done
done
echo "== window done $(date +%T) failed=$failed"
exit $failed
