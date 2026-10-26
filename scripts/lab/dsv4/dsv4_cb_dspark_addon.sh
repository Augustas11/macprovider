#!/bin/bash
# #2111 add-on for PR #2151's Window 2 (w-dsv4-fidelity.sh, JOBS=d): with the
# live provider already paused, drained and booted out by that controller, and
# after its job d (12 coding prompts) has stopped its loopback serve, run
#   (1) the DeepSeek CB gate on the #2151 build: msb-throughput aggregate decode
#       tok/s at 1, 2, 4, 8 rows vs serial, gate >= 67.4 at 4 rows, and exact
#       token parity at 1, 2, 4, 8 rows;
#   (2) the DSpark lane (dsv4_dspark_bench.py) on the corrected mlx-vlm target.
# It never touches the live provider: the controller owns pause and restore.
#
# Called by the controller as job "x" (no controller edit; bash exports the
# function into the controller's shell, which expands its own globals):
#   job_x(){ PAUSE_T=$PAUSE_T CEILING_S=$CEILING_S LAB=$LAB NEWBIN=$NEWBIN \
#            bash $LAB/addon-2111-cbds/dsv4_cb_dspark_addon.sh "$OUT"; }
#   export -f job_x
#   JOBS=dx CEILING_S=11400 W1_OUT=<window 1 dir> nohup bash w-dsv4-fidelity.sh > w2.out 2>&1 &
#
# Required private inputs: LAB, NEWBIN, DSV4_MODEL_DIR, PY, ORACLES, LIVE_URL.
# The DSpark lane is reference evidence; native runtime proof is separate.
#   bash dsv4_cb_dspark_addon.sh --plan <OUT>    prints every command, runs nothing
#
# Stops on $OUT/CEILING, $OUT/ABORT, its own deadline (ADDON_BUDGET_S, and the
# controller ceiling minus 5 min), or the controller's exit. Every CB cell and
# the DSpark lane is skipped, not cut, when its estimate does not fit.
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
D=$OUT/x
CONTROLLER=$PPID
T0=$(date +%s)
DEADLINE=$(( T0 + ${ADDON_BUDGET_S:-6000} ))
if [ -n "${PAUSE_T:-}" ] && [ -n "${CEILING_S:-}" ]; then
  c=$(( PAUSE_T + CEILING_S - 300 )); [ $c -lt $DEADLINE ] && DEADLINE=$c
fi
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
)
dspark_cmd(){
  printf 'exec '
  printf '%q ' nice -n 5 "$PY" -I "$ADDON/dsv4_dspark_bench.py" "$M" "$D/dspark" --policy "$POLICY" --requests "$ADDON/dsv4-dspark-requests.json" --long-prompts "$ORACLES"
  [ -z "$REF" ] || printf '%q ' --reference-oracles "$REF"
  printf '%q ' --deadline-epoch "$DEADLINE" --stop-file "$OUT/CEILING" --stop-file "$OUT/ABORT"
  echo
}

if [ $PLAN = 1 ]; then
  echo "# deadline epoch $DEADLINE ($(( DEADLINE - T0 )) s); W1_OUT=${W1_OUT:-none}; reference oracles ${REF:-none}"
  echo "(cd $ADDON && shasum -a 256 -c dsv4-cbds-manifest.sha256)"
  for c in "${CELLS[@]}"; do IFS='|' read -r name est args <<< "$c"
    if [ "$name" = DSPARK ]; then echo "# dspark (est ${est}s)"; dspark_cmd
    else echo "# $name (est ${est}s; throughput cells reuse \$W1_OUT/c/new-rN.json when valid)"; msb $args; fi
  done
  echo "$PY -I $ADDON/dsv4_cb_dspark_summary.py $D $POLICY > $D/summary.json"
  exit 0
fi

mkdir -p "$D" && chmod 700 "$D"
say(){ echo "[$(date -u +%T)] x: $*" | tee -a "$OUT/timeline.txt" >> "$D/addon.log"; }
halted(){ [ -e "$OUT/CEILING" ] || [ -e "$OUT/ABORT" ] || [ $(date +%s) -ge $DEADLINE ] || ! kill -0 $CONTROLLER 2>/dev/null; }
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
    if halted; then say "$name: halt (ceiling/abort/deadline/controller)"; cleanup; break; fi
    if [ $(( $(date +%s) % 60 )) -lt 5 ]; then
      key="$(wc -c < "$log" | tr -d ' ')|$(ps -o time= -p $CHILD 2>/dev/null)"
      if [ "$key" = "$last" ]; then same=$((same+1)); else same=0; last=$key; fi
      echo "[$(date -u +%T)] $name: $key $(tail -1 "$log" | cut -c1-160)" >> "$D/monitor.txt"
      [ $same -ge 10 ] && { say "$name: no progress 10 min; kill"; cleanup; break; }
    fi
  done
  wait $CHILD; rc=$?; CHILD=""; say "$name: rc=$rc"; return $rc
}

say "start; deadline epoch $DEADLINE; W1_OUT=${W1_OUT:-none}"
(cd "$ADDON" && shasum -a 256 -c dsv4-cbds-manifest.sha256 > "$D/manifest-check.txt" 2>&1) || { say "add-on files differ from dsv4-cbds-manifest.sha256; stop"; exit 2; }
[ -x "$NEWBIN" ] && [ -s "$(dirname "$NEWBIN")/mlx.metallib" ] || { say "missing $NEWBIN or its mlx.metallib; stop"; exit 2; }
shasum -a 256 "$NEWBIN" "$(dirname "$NEWBIN")/mlx.metallib" > "$D/identity.sha256"
if [ -n "$W1_OUT" ] && [ -s "$W1_OUT/0/identity.sha256" ]; then
  want=$(grep " $NEWBIN\$" "$W1_OUT/0/identity.sha256" | cut -d' ' -f1)
  have=$(head -1 "$D/identity.sha256" | cut -d' ' -f1)
  [ "$want" = "$have" ] || { say "NEWBIN sha $have != window 1 build $want; stop"; exit 2; }
  grep '^decode_path_digest ' "$W1_OUT/0/identity.sha256" >> "$D/identity.sha256"
fi
# Nothing else may hold a model: the live provider is booted out and job d's
# loopback serve is gone.
for i in $(seq 1 24); do
  pgrep -f "$SERVE_PATTERN" >/dev/null || break; sleep 5; done
pgrep -fl "$SERVE_PATTERN" && { say "a serve process still runs; stop"; exit 3; }
curl -fsS --max-time 2 "$LIVE_URL" >/dev/null 2>&1 && { say "live provider answers; stop"; exit 3; }

reuse(){ local n=$1 src="$W1_OUT/c/new-r$1.json"
  [ -n "$W1_OUT" ] && [ -s "$src" ] || return 1
  "$PY" -I - "$src" "$n" <<'PY' || return 1
import json, sys
d = json.load(open(sys.argv[1])); n = int(sys.argv[2])
ok = (d.get("rows") == n and d.get("runs") == 3 and d.get("scenario") == "throughput" and d.get("engine") == "scheduler"
      and d.get("promptTokensPerRow") == 1024 and d.get("decodeTokensPerRow") == 256 and d.get("compiled") is False
      and len(d.get("aggregateTPSRuns") or []) == 3)
sys.exit(0 if ok else 1)
PY
  cp "$src" "$D/throughput-r$n.json" && echo "$src" > "$D/throughput-r$n.reused-from"
}

for c in "${CELLS[@]}"; do IFS='|' read -r name est args <<< "$c"
  halted && { say "halted before $name"; break; }
  case $name in throughput-r*) reuse "${name#throughput-r}" && { say "$name: reused from window 1"; continue; } ;; esac
  if [ $(( $(date +%s) + est )) -gt $DEADLINE ]; then say "$name: skipped (est ${est}s past deadline)"; continue; fi
  if [ "$name" = DSPARK ]; then
    supervise dspark "$D/dspark.log" bash -c "$(dspark_cmd)"
  else
    supervise "$name" "$D/$name.log" bash -c "$(msb $args)"
  fi
done
"$PY" -I "$ADDON/dsv4_cb_dspark_summary.py" "$D" "$POLICY" > "$D/summary.json" 2> "$D/summary.err"
say "summary: $("$PY" -I -c "import json,sys; s=json.load(open(sys.argv[1])); print('CB', s['cb_gate']['decision'], s['cb_gate']['gate_tps'], '| DSpark', s['dspark']['decision'], s['dspark']['best_block_size'])" "$D/summary.json" 2>&1)"
say "done $(( $(date +%s) - T0 ))s"
