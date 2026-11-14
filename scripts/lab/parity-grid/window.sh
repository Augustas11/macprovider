#!/usr/bin/env bash
# One lab window of the parity grid over several models. For each model: the
# stock mlx-lm reference once, then our provider on each requested route with
# that same reference. Noninteractive; one model loaded at a time.
#
# usage: window.sh --bin-dir DIR --python PY --out-dir DIR MODEL...
#   MODEL is name=path[:routes[:rows]]
#     routes  comma list of default, serial, cb   (default "default,serial")
#       default  serve as the lab starts it (autotune flag, no batching flag):
#                the row-invariant small-row route
#       serial   batching off, native MTP off, no autotune flag: the
#                serial-only small-row route
#       cb       batching on (only for a model the build admits to batching)
#     rows    comma list for the cb route (default "1,4"); other routes run 1
# Each route's result is OUT/<name>/<route>/summary.md; a failed reference is
# reported and the model skipped. Exit code 0 means every grid ran, not that
# every cell passed: read the summaries.
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
BIN="" PY="" OUT="" TRIALS=2 SAMPLE=0
MODELS=()
while [ $# -gt 0 ]; do
  case "$1" in
    --bin-dir) BIN="$2"; shift 2 ;;
    --python) PY="$2"; shift 2 ;;
    --out-dir) OUT="$2"; shift 2 ;;
    --trials) TRIALS="$2"; shift 2 ;;
    --sample-seconds) SAMPLE="$2"; shift 2 ;;
    --*) echo "unknown argument: $1" >&2; exit 64 ;;
    *) MODELS+=("$1"); shift ;;
  esac
done
[ -n "$BIN" ] && [ -n "$PY" ] && [ -n "$OUT" ] && [ ${#MODELS[@]} -gt 0 ] || {
  echo "usage: window.sh --bin-dir DIR --python PY --out-dir DIR name=path[:routes[:rows]]..." >&2; exit 64; }
mkdir -p "$OUT"
failed=0
for spec in "${MODELS[@]}"; do
  name="${spec%%=*}"; rest="${spec#*=}"
  IFS=: read -r path routes rows <<< "$rest"
  routes="${routes:-default,serial}"; rows="${rows:-1,4}"
  M="$OUT/$name"; mkdir -p "$M/ref"
  echo "#### $name reference $(date +%T)"
  # bash 3.2 cannot parse a case statement inside $( ).
  ref_rows=1
  if [[ ",$routes," == *,cb,* ]]; then ref_rows="$rows"; fi
  if ! "$PY" "$HERE/reference_mlxlm.py" --model-path "$path" --model-name "$name" \
      --out "$M/ref/reference.jsonl" --grid "$HERE/grid.json" --trials "$TRIALS" \
      --rows "$ref_rows" \
      > "$M/ref/reference.log" 2>&1; then
    echo "REF_FAILED $name"; tail -5 "$M/ref/reference.log"; failed=1; continue
  fi
  IFS=, read -r -a route_list <<< "$routes"
  for route in "${route_list[@]}"; do
    R="$M/$route"; rm -rf "$R"; mkdir -p "$R"; cp "$M/ref/reference.jsonl" "$R/"
    args=(--model-path "$path" --model-name "$name" --bin-dir "$BIN" --out-dir "$R"
          --trials "$TRIALS" --skip-reference --sample-seconds "$SAMPLE")
    case "$route" in
      default) args+=(--cb auto --rows 1) ;;
      serial)  args+=(--cb off --rows 1 --no-autotune-candidate --serve-arg --native-mtp --serve-arg off) ;;
      cb)      args+=(--cb on --rows "$rows") ;;
      *) echo "unknown route $route" >&2; failed=1; continue ;;
    esac
    echo "#### $name $route $(date +%T)"
    bash "$HERE/run-grid.sh" "${args[@]}" > "$R/run.log" 2>&1
    echo "grid rc=$? $name $route"
    /usr/bin/python3 -I -c 'import json,sys
try: print("small_m_route:", (json.load(open(sys.argv[1])).get("continuous_batching") or {}).get("small_m_route"))
except Exception as e: print("small_m_route: unknown", e)' "$R/serve/status.json"
    sed -n '/^| model/,/^$/p' "$R/summary.md" 2>/dev/null || { echo "NO_SUMMARY $name $route"; tail -8 "$R/run.log"; failed=1; }
  done
done
echo "WINDOW_DONE $(date +%T) failed=$failed"
exit "$failed"
