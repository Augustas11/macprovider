#!/usr/bin/env bash
# Engine-333 Studio window: the engine fork sync (mlx-swift-lm 3.33.0 merge,
# mlx-swift 0.33.0, mlx core + #4883/#4881/#4930) against the current pin
# (.85 build), on an isolated loopback. Noninteractive; one model loaded at a time.
#
# usage: window.sh --base-bin DIR --new-bin DIR --out DIR [--lm-dir DIR] MODEL...
#   --base-bin  release build of the current pin (mlx-swift-lm 3.32.3-macprovider.85)
#   --new-bin   release build of this campaign branch
#   --lm-dir    mlx-swift-lm checkout at the campaign commit: runs the heavy suites
#               the 32 GB M5 cannot (real checkpoints, large bitwise grids)
#   MODEL       name=path[:mtp]   mtp = "on" makes run-grid fail unless native MTP serves
#
# Per model, the production route (batching auto, no autotune flag), rows 1 and 4,
# short and 4k context, 128/512 output tokens: base, new, base. compare.py --baseline gates
# identical text and token counts (new vs the first base run) and reports decode
# tok/s, aggregate tok/s and TTFT; the second base run is the noise control.
# Exit 0 = every grid ran and every identity gate passed.
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
PG="$HERE/../parity-grid"
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
  echo "usage: window.sh --base-bin DIR --new-bin DIR --out DIR [--lm-dir DIR] name=path[:mtp]..." >&2; exit 64; }
for b in "$BASE" "$NEW"; do [ -x "$b/macprovider-cli" ] || { echo "no macprovider-cli in $b" >&2; exit 64; }; done
if lsof -nP -iTCP:8080 -sTCP:LISTEN >/dev/null 2>&1; then echo "8080 is listening: live provider not paused" >&2; exit 65; fi
mkdir -p "$OUT"
shasum -a 256 "$BASE/macprovider-cli" "$NEW/macprovider-cli" | tee "$OUT/binaries.sha256"
failed=0

if [ -n "$LM" ]; then
  echo "#### heavy mlx-swift-lm suites $(date +%T)"
  ( cd "$LM" && git rev-parse HEAD && swift build --build-tests && swift test --skip-build \
      --filter 'DeepseekV4|GLM5Next|GatherQMM|ReferencePrefill|ParoQuant|MatmulPrecision|Bitwise|LayerDump|TeacherForced|MiniMaxM3Parity|Gemma4MTPPackedDrafter' ) \
    > "$OUT/heavy-suites.log" 2>&1
  rc=$?; echo "heavy suites rc=$rc"; [ $rc -eq 0 ] || { failed=1; grep -E "error:|failed" "$OUT/heavy-suites.log" | head -20; }
fi

for spec in "${MODELS[@]}"; do
  name="${spec%%=*}"; rest="${spec#*=}"
  IFS=: read -r path mtp <<< "$rest"
  M="$OUT/$name"; mkdir -p "$M"
  for run in base1:"$BASE" new:"$NEW" base2:"$BASE"; do
    tag="${run%%:*}"; bin="${run#*:}"; R="$M/$tag"; rm -rf "$R"; mkdir -p "$R"
    args=(--model-path "$path" --model-name "$name" --bin-dir "$bin" --out-dir "$R"
          --trials "$TRIALS" --skip-reference --skip-compare --cb auto --no-autotune-candidate
          --rows 1,4 --outputs 128,512 --contexts short,4k)
    [ "$mtp" = on ] && args+=(--expect-native-mtp on)
    echo "#### $name $tag $(date +%T)"
    bash "$PG/run-grid.sh" "${args[@]}" > "$R/run.log" 2>&1
    rc=$?; echo "grid rc=$rc $name $tag"; [ $rc -eq 0 ] || { failed=1; tail -8 "$R/run.log"; }
    grep -h "^ROUTE\|NATIVE_MTP\|CB_WARMUP_DONE" "$R/run.log" | tail -4
  done
  for cand in new base2; do
    /usr/bin/python3 -I "$PG/compare.py" --baseline "$M/base1/provider.jsonl" --ours "$M/$cand/provider.jsonl" \
      --json "$M/compare-$cand.json" > "$M/compare-$cand.md" 2>&1
    rc=$?; echo "compare $name $cand vs base1 rc=$rc"; cat "$M/compare-$cand.md"
    [ "$cand" = base2 ] || [ $rc -eq 0 ] || failed=1
  done
done
echo "== window done $(date +%T) failed=$failed"
exit $failed
