#!/bin/bash
# #2111 add-on for PR #2151's Window 2 (w-dsv4-fidelity.sh, JOBS=d): with the
# live provider already paused, drained and booted out by that controller, and
# after its job d (12 coding prompts) has stopped its loopback serve, run
#   (1) the DeepSeek CB gate on the #2151 build: msb-throughput aggregate decode
#       tok/s at 1, 2, 4, 8 rows vs serial, gate >= 2.0x same-window serial at 4 rows, and exact
#       token parity at 1, 2, 4, 8 rows;
#   (2) the DSpark reference lane on the corrected mlx-vlm target;
#   (3) native frozen-request integrity probes and separate R015 benches.
# It never touches the live provider: the controller owns pause and restore.
#
# Called by the controller as job "x" (no controller edit; bash exports the
# function into the controller's shell, which expands its own globals):
#   job_x(){ PAUSE_T=$PAUSE_T CEILING_S=$CEILING_S LAB=$LAB NEWBIN=$NEWBIN \
#            bash $LAB/addon-2111-cbds/dsv4_cb_dspark_addon.sh "$OUT"; }
#   export -f job_x
#   JOBS=dx CEILING_S=11400 W1_OUT=<window 1 dir> nohup bash w-dsv4-fidelity.sh > w2.out 2>&1 &
#
# Required private inputs are listed in README.md; no host layout is assumed.
# The DSpark lane is reference evidence; native runtime proof is separate.
#   bash dsv4_cb_dspark_addon.sh --plan <OUT>    prints every command, runs nothing
#
# Stops on explicit controller abort/ceiling markers, controller exit or a stall.
# The authorized campaign has no wall-clock deadline or cell-skipping budget.
set -uo pipefail
export PATH=/usr/sbin:/opt/homebrew/bin:/usr/bin:/bin
PLAN=0; [ "${1:-}" = --plan ] && { PLAN=1; shift; }
OUT=${1:?usage: dsv4_cb_dspark_addon.sh [--plan] <window OUT dir>}
ADDON=$(cd "$(dirname "$0")" && pwd)
LAB=${LAB:?set LAB to the prepared window workspace}
NEWBIN=${NEWBIN:?set NEWBIN to the Window 1 candidate binary}
POLICY=$ADDON/dsv4-cb-dspark-policy.json
M=${DSV4_MODEL_DIR:?set DSV4_MODEL_DIR to the verified artifact directory}
PY=${PY:?set PY to the pinned reference environment Python}
ORACLES=${ORACLES:?set ORACLES to the existing oracle directory}
W1_OUT=${W1_OUT:-}
SERVE_PATTERN=${SERVE_PATTERN:-macprovider-cli serve}
LIVE_URL=${LIVE_URL:?set LIVE_URL to the local provider status endpoint}
DSV4_NATIVE_BENCH_ROOT=${DSV4_NATIVE_BENCH_ROOT:?set DSV4_NATIVE_BENCH_ROOT to the native fixture root}
DSV4_NATIVE_POLICY_DIR=${DSV4_NATIVE_POLICY_DIR:?set DSV4_NATIVE_POLICY_DIR to the frozen depth policy directory}
DSV4_NATIVE_LONG_TOKEN_IDS=${DSV4_NATIVE_LONG_TOKEN_IDS:?set DSV4_NATIVE_LONG_TOKEN_IDS to the existing long-prompt token JSON}
DSV4_PROVIDER_COMMIT=${DSV4_PROVIDER_COMMIT:?set DSV4_PROVIDER_COMMIT to the candidate source commit}
[[ "$DSV4_PROVIDER_COMMIT" =~ ^[0-9a-f]{40}$ ]] || { echo "DSV4_PROVIDER_COMMIT must be lowercase 40-hex" >&2; exit 2; }
DSV4_R015_ANALYZER=${DSV4_R015_ANALYZER:-$ADDON/../../native_mtp_r015_analyze.py}
REQUESTS_SHA256=01bb9294714fcc95c7dc8540b460c309f8c5ff782214d24b3e95d4e4297b9383
D=$OUT/x
CONTROLLER=$PPID
T0=$(date +%s)
REF=""; [ -n "$W1_OUT" ] && [ -s "$W1_OUT/b/oracles/oracle_32768.npz" ] && REF=$W1_OUT/b/oracles

msb(){ printf 'cd %q && exec ' "$(dirname "$NEWBIN")"; printf '%q ' nice -n 5 "$NEWBIN" msb-throughput --model "$M" --engine scheduler --no-compile "$@" --output "$D/$name.json"; echo; }
CELLS=(
  "throughput-r4|660|--scenario throughput --rows 4 --prompt-tokens 1024 --decode-tokens 256 --runs 3"
  "parity-r1|240|--scenario parity --rows 1 --prompt-tokens 1024 --decode-tokens 256 --parity-tokens 256 --runs 1"
  "parity-r2|300|--scenario parity --rows 2 --prompt-tokens 1024 --decode-tokens 256 --parity-tokens 256 --runs 1"
  "parity-r4|420|--scenario parity --rows 4 --prompt-tokens 1024 --decode-tokens 256 --parity-tokens 256 --runs 1"
  "parity-r8|660|--scenario parity --rows 8 --prompt-tokens 1024 --decode-tokens 256 --parity-tokens 256 --runs 1"
  "DSPARK|900|"
  "throughput-r1|420|--scenario throughput --rows 1 --prompt-tokens 1024 --decode-tokens 256 --runs 3"
  "throughput-r2|480|--scenario throughput --rows 2 --prompt-tokens 1024 --decode-tokens 256 --runs 3"
  "throughput-r8|900|--scenario throughput --rows 8 --prompt-tokens 1024 --decode-tokens 256 --runs 3"
  "native-d1|1800|1"
  "native-d2|1800|2"
  "native-d3|1800|3"
  "native-d5|1800|5"
  "r015-d1|3600|1"
  "r015-d2|3600|2"
  "r015-d3|3600|3"
  "r015-d5|3600|5"
)
dspark_cmd(){
  printf 'exec '
  printf '%q ' nice -n 5 "$PY" -I "$ADDON/dsv4_dspark_bench.py" "$M" "$D/dspark" --policy "$POLICY" --requests "$ADDON/dsv4-dspark-requests.json" --long-prompts "$ORACLES"
  [ -z "$REF" ] || printf '%q ' --reference-oracles "$REF"
  printf '%q ' --stop-file "$OUT/CEILING" --stop-file "$OUT/ABORT"
  echo
}

native_cmd(){
  local depth=$1 mode=$2
  local result="$D/native/d$depth.jsonl"
  [ "$mode" = integrity ] || result="$D/native/r015-d$depth.jsonl"
  printf 'cd %q && exec ' "$(dirname "$NEWBIN")"
  printf '%q ' env MACPROVIDER_NATIVE_MTP_E2E=1 nice -n 5 "$NEWBIN" native-mtp-bench \
    --root "$DSV4_NATIVE_BENCH_ROOT" --model-id deepseek/deepseek-v4-flash \
    --policy "$DSV4_NATIVE_POLICY_DIR/depth-$depth.json" --out "$result" --provider-commit "$DSV4_PROVIDER_COMMIT"
  if [ "$mode" = integrity ]; then
    printf '%q ' --requests "$ADDON/dsv4-dspark-requests.json" --requests-sha256 "$REQUESTS_SHA256" --long-token-ids "$DSV4_NATIVE_LONG_TOKEN_IDS"
  fi
  echo
}

if [ $PLAN = 1 ]; then
  echo "# no wall-clock deadline; W1_OUT=${W1_OUT:-none}; reference oracles ${REF:-none}"
  echo "(cd $ADDON && shasum -a 256 -c dsv4-cbds-manifest.sha256)"
  for c in "${CELLS[@]}"; do IFS='|' read -r name est args <<< "$c"
    case $name in
      DSPARK) echo "# reference dspark (est ${est}s; never native proof)"; dspark_cmd ;;
      native-d*) echo "# $name integrity only (est ${est}s; qualifies_r015=false)"; native_cmd "$args" integrity ;;
      r015-d*) echo "# $name qualification (est ${est}s; no frozen requests)"; native_cmd "$args" r015 ;;
      *) echo "# $name (est ${est}s; throughput cells reuse \$W1_OUT/c/new-rN.json when valid)"; msb $args ;;
    esac
  done
  printf '%q ' "$PY" -I "$ADDON/dsv4_cb_dspark_summary.py" "$D" "$POLICY" --native-policy-dir "$DSV4_NATIVE_POLICY_DIR" --r015-analyzer "$DSV4_R015_ANALYZER"; printf ' > %q\n' "$D/summary.json"
  exit 0
fi

mkdir -p "$D" && chmod 700 "$D"
say(){ echo "[$(date -u +%T)] x: $*" | tee -a "$OUT/timeline.txt" >> "$D/addon.log"; }
halted(){ [ -e "$OUT/CEILING" ] || [ -e "$OUT/ABORT" ] || ! kill -0 $CONTROLLER 2>/dev/null; }
CHILD=""
# The child execs down to the measured process; the pattern catches anything
# that still names this add-on's output directory.
cleanup(){ [ -n "$CHILD" ] && kill $CHILD 2>/dev/null; pkill -f -- "--output $D/" 2>/dev/null; pkill -f -- "dsv4_dspark_bench.py .* $D/dspark" 2>/dev/null
  sleep 5; [ -n "$CHILD" ] && kill -9 $CHILD 2>/dev/null; pkill -9 -f -- "--output $D/" 2>/dev/null; pkill -9 -f -- "dsv4_dspark_bench.py .* $D/dspark" 2>/dev/null; true; }
trap 'cleanup; say "add-on exit"' EXIT
trap 'exit 4' TERM INT

# Supervised child: killed on a halt condition; 10 minutes without log growth
# or CPU time is a hang.
supervise(){ local name=$1 log=$2; shift 2
  ( exec "$@" ) > "$log" 2>&1 &
  CHILD=$!; local last="" same=0 rc
  say "$name: pid=$CHILD"
  while kill -0 $CHILD 2>/dev/null; do sleep 5
    if halted; then say "$name: halt (ceiling/abort/controller)"; cleanup; break; fi
    if [ $(( $(date +%s) % 60 )) -lt 5 ]; then
      key="$(wc -c < "$log" | tr -d ' ')|$(ps -o time= -p $CHILD 2>/dev/null)"
      if [ "$key" = "$last" ]; then same=$((same+1)); else same=0; last=$key; fi
      echo "[$(date -u +%T)] $name: $key $(tail -1 "$log" | cut -c1-160)" >> "$D/monitor.txt"
      [ $same -ge 10 ] && { say "$name: no progress 10 min; kill"; cleanup; break; }
    fi
  done
  wait $CHILD; rc=$?; CHILD=""; say "$name: rc=$rc"; return $rc
}

say "start; no wall-clock deadline; W1_OUT=${W1_OUT:-none}"
(cd "$ADDON" && shasum -a 256 -c dsv4-cbds-manifest.sha256 > "$D/manifest-check.txt" 2>&1) || { say "add-on files differ from dsv4-cbds-manifest.sha256; stop"; exit 2; }
[ -x "$NEWBIN" ] && [ -s "$(dirname "$NEWBIN")/mlx.metallib" ] || { say "missing $NEWBIN or its mlx.metallib; stop"; exit 2; }
shasum -a 256 "$NEWBIN" "$(dirname "$NEWBIN")/mlx.metallib" > "$D/identity.sha256"
IDENTITY_BOUND=0
if [ -n "$W1_OUT" ] && [ -s "$W1_OUT/0/identity.sha256" ]; then
  want=$(grep " $NEWBIN\$" "$W1_OUT/0/identity.sha256" | cut -d' ' -f1)
  have=$(head -1 "$D/identity.sha256" | cut -d' ' -f1)
  [ "$want" = "$have" ] || { say "NEWBIN sha $have != window 1 build $want; stop"; exit 2; }
  grep '^decode_path_digest ' "$W1_OUT/0/identity.sha256" >> "$D/identity.sha256" || exit 2
  IDENTITY_BOUND=1
fi
# Nothing else may hold a model: the live provider is booted out and job d's
# loopback serve is gone.
for i in $(seq 1 24); do
  pgrep -f "$SERVE_PATTERN" >/dev/null || break; sleep 5; done
pgrep -fl "$SERVE_PATTERN" && { say "a serve process still runs; stop"; exit 3; }
curl -fsS --max-time 2 "$LIVE_URL" >/dev/null 2>&1 && { say "live provider answers; stop"; exit 3; }

reuse(){ local n=$1 src="$W1_OUT/c/new-r$1.json"
  [ -n "$W1_OUT" ] && [ -s "$src" ] || return 1
  "$PY" -I - "$src" "$n" "$POLICY" <<'PY' || return 1
import json, math, sys
d = json.load(open(sys.argv[1])); n = int(sys.argv[2])
pin = "mlxlm-" + json.load(open(sys.argv[3]))["runtime_under_test"]["fork_commit"][:12]
def positive(v):
    return type(v) in (int, float) and math.isfinite(v) and v > 0
ok = (d.get("rows") == n and d.get("runs") == 3 and d.get("scenario") == "throughput" and d.get("engine") == "scheduler"
      and d.get("promptTokensPerRow") == 1024 and d.get("decodeTokensPerRow") == 256 and d.get("compiled") is False
      and d.get("mlxSwiftLMPin") == pin
      and all(isinstance(d.get(k), list) and len(d[k]) == 3 and all(positive(v) for v in d[k])
              for k in ("aggregateTPSRuns", "productionSerialTPSRuns"))
      and all(positive(d.get(k)) for k in ("aggregateTPSp50", "productionSerialTPSp50")))
sys.exit(0 if ok else 1)
PY
  cp "$src" "$D/throughput-r$n.json" && echo "$src" > "$D/throughput-r$n.reused-from"
}

for c in "${CELLS[@]}"; do IFS='|' read -r name est args <<< "$c"
  halted && { say "halted before $name"; break; }
  case $name in throughput-r*) reuse "${name#throughput-r}" && { say "$name: reused from window 1"; continue; } ;; esac
  case $name in
    DSPARK) supervise dspark "$D/dspark.log" bash -c "$(dspark_cmd)" ;;
    native-d*|r015-d*)
      if [ "$IDENTITY_BOUND" != 1 ] || [ ! -s "$DSV4_NATIVE_POLICY_DIR/depth-$args.json" ]; then
        say "$name: skipped (missing Window 1 candidate identity or frozen depth policy)"; continue
      fi
      if [ "$name" = "native-d$args" ] && [ ! -s "$DSV4_NATIVE_LONG_TOKEN_IDS" ]; then
        say "$name: skipped (missing long-prompt token IDs)"; continue
      fi
      mkdir -p "$D/native" && chmod 700 "$D/native"
      mode=r015; [ "$name" != "native-d$args" ] || mode=integrity
      supervise "$name" "$D/$name.log" bash -c "$(native_cmd "$args" "$mode")"
      ;;
    *) supervise "$name" "$D/$name.log" bash -c "$(msb $args)" ;;
  esac
done
"$PY" -I "$ADDON/dsv4_cb_dspark_summary.py" "$D" "$POLICY" --native-policy-dir "$DSV4_NATIVE_POLICY_DIR" --r015-analyzer "$DSV4_R015_ANALYZER" > "$D/summary.json" 2> "$D/summary.err"
say "summary: $("$PY" -I -c "import json,sys; s=json.load(open(sys.argv[1])); print('CB', s['cb_gate']['decision'], s['cb_gate']['gate_tps'], '| DSpark', s['dspark']['decision'], s['dspark']['best_block_size'])" "$D/summary.json" 2>&1)"
say "done $(( $(date +%s) - T0 ))s"
