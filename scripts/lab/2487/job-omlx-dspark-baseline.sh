#!/bin/bash
# #2487 window 1 (AGENTS.md rule 12: the goal metric before any code). Runs ON the Studio.
#
# Measures what the bundled DSpark draft is worth on our served artifact
# (mlx-community/Inkling-2-Mini-oQ4e-mtp @ 3eea0427) on this machine, with existing tools only:
# oMLX v0.8.3 (jundot/omlx, Apache-2.0) serving the artifact with DSpark drafting on and off,
# timed by megakernel-zoo's Mac baseline harness (dangxingyu/megakernel-zoo, Apache-2.0,
# baselines/mac/bench.sh: eval/client.py steady over HTTP, greedy, one sequence, token-based
# decode rate, TTFT). Workloads: synth (64-token synthetic prompts, 1,024 tokens), natural
# (prose / Python / GSM8K, 1,024 tokens), chat (GSM8K through the chat template, to EOS).
# ROUNDS server starts per system in turns, 1 warm-up + REPEATS repeats each.
#
# Nothing is built or published; the artifact is read in place from ~/lab-2467/models.
# Output: ~/lab-2487/results/<run>/bench/{results.txt,*.json,logs/} and one line per cell:
#   GOAL_CELL workload=W plain_tok_s=X ds_tok_s=Y gain=Y/X ttft_plain_s ttft_ds_s
# Exit 0 with JOB_PASS when every cell measured; every failure prints a BLOCKER: line.
#
# Usage: job-omlx-dspark-baseline.sh [--dry-run]
# Settings: ROUNDS (2) REPEATS (3) CHAT_PAUSE (2) WORKLOADS ("synth natural chat") MIN_FREE_GB (40)
set -u
export PATH=/usr/sbin:/opt/homebrew/bin:/usr/bin:/bin
export PYTHONDONTWRITEBYTECODE=1 HF_HUB_DISABLE_TELEMETRY=1 TOKENIZERS_PARALLELISM=false
DRY=0; [ "${1:-}" = --dry-run ] && DRY=1
LAB=$HOME/lab-2487
RUN_ID=${RUN_ID:-$(date -u +%Y%m%dT%H%M%SZ)}
RES=$LAB/results/$RUN_ID
OQ_REV=3eea042751cd296b7266628a8342c1749242e1fe
OQ=${OQ_DIR:-$HOME/lab-2467/models/Inkling-2-Mini-oQ4e-mtp@${OQ_REV:0:8}}
MKZ_REV=95e315c808a7d935c10ef924a8fc0d901bfc3b89     # megakernel-zoo main, 2026-11-23
OMLX_REV=e72868dac12df4be4ced2dc8355f031686283974    # jundot/omlx tag v0.8.3
MKZ=$LAB/src/megakernel-zoo@${MKZ_REV:0:8}
OMLX=$LAB/src/omlx@${OMLX_REV:0:8}
MODELS=$LAB/models-bench
PY312=/opt/homebrew/opt/python@3.12/bin/python3.12
ROUNDS=${ROUNDS:-2}; REPEATS=${REPEATS:-3}; CHAT_PAUSE=${CHAT_PAUSE:-2}
WORKLOADS=${WORKLOADS:-synth natural chat}; MIN_FREE_GB=${MIN_FREE_GB:-40}
log() { echo "$(date '+%H:%M:%S') $*"; }
die() { log "BLOCKER: $1"; log "JOB_FAIL rc=${2:-1}"; exit "${2:-1}"; }

log "JOB_START 2487-omlx-dspark-baseline run=$RUN_ID dry_run=$DRY rounds=$ROUNDS repeats=$REPEATS workloads=\"$WORKLOADS\""
if [ "$DRY" = 1 ]; then
  for s in "artifact: $OQ (config.json, mtp.safetensors, tokenizer.json)" \
    "src: git clone megakernel-zoo @ ${MKZ_REV:0:8} -> $MKZ; jundot/omlx @ v0.8.3 ${OMLX_REV:0:8} -> $OMLX" \
    "venv: $PY312 -m venv $OMLX/.venv; pip install -e $OMLX aiohttp tokenizers; $MKZ/.venv-mac -> $OMLX/.venv" \
    "models: $MODELS/{mlx-oq4e-mtp,Inkling-2-Mini} -> $OQ" \
    "bench: MODELS=$MODELS OUT=$RES/bench ROUNDS=$ROUNDS REPEATS=$REPEATS CHAT_PAUSE=$CHAT_PAUSE bash $MKZ/baselines/mac/bench.sh omlx-oq4e-ds omlx-oq4e"; do
    log "DRY_PLAN $s"
  done
  log "DRY_RUN_PASS"; exit 0
fi

mkdir -p "$RES" "$LAB/src" "$MODELS"
# 0. Preflight: the window owner has paused live, runner and miner; nothing else serves.
busy=$( { lsof -nP -iTCP:8080 -sTCP:LISTEN -t; lsof -nP -iTCP:18600 -sTCP:LISTEN -t;
  pgrep -f "macprovider-cli serve"; launchctl list | grep com.flop;
  launchctl print "gui/$(id -u)/live.malibu.provider" >/dev/null 2>&1 && echo live.malibu.provider; } 2>/dev/null)
[ -z "$busy" ] || die "something still runs: $(echo "$busy" | tr '\n' ' ' | cut -c1-200)" 10
free_gb=$(df -g "$HOME" | awk 'NR==2 {print $4}')
[ "${free_gb:-0}" -ge "$MIN_FREE_GB" ] || die "free disk ${free_gb}G < ${MIN_FREE_GB}G" 10
[ -x "$PY312" ] || die "no python3.12 at $PY312" 10
for f in config.json mtp.safetensors tokenizer.json; do
  [ -f "$OQ/$f" ] || die "artifact $OQ lacks $f" 10
done
log "PREFLIGHT ok disk=${free_gb}G artifact=$OQ"

# 1. Sources at pinned commits.
fetch() {  # URL REV DIR
  if [ "$(git -C "$3" rev-parse HEAD 2>/dev/null)" = "$2" ]; then return 0; fi
  rm -rf -- "$3"; git init -q "$3" && git -C "$3" fetch -q --depth 1 "$1" "$2" && git -C "$3" checkout -q FETCH_HEAD
}
fetch https://github.com/dangxingyu/megakernel-zoo.git "$MKZ_REV" "$MKZ" || die "megakernel-zoo fetch failed" 11
fetch https://github.com/jundot/omlx.git "$OMLX_REV" "$OMLX" || die "omlx fetch failed" 11
log "SRC mkz=$(git -C "$MKZ" rev-parse HEAD) omlx=$(git -C "$OMLX" rev-parse HEAD)"

# 2. One venv: oMLX (serve.sh runs $OMLX/.venv/bin/omlx) and the bench client (bench.sh runs $MKZ/.venv-mac/bin/python).
if [ "$(cat "$OMLX/.venv/.ok" 2>/dev/null)" != "$OMLX_REV" ]; then
  { "$PY312" -m venv "$OMLX/.venv" && "$OMLX/.venv/bin/python" -m pip install -q --upgrade pip \
    && "$OMLX/.venv/bin/python" -m pip install -q -e "$OMLX" aiohttp tokenizers; } > "$RES/venv.log" 2>&1 \
    || die "venv setup failed: $(tail -n 3 "$RES/venv.log" | tr '\n' ' ' | cut -c1-300)" 12
  echo "$OMLX_REV" > "$OMLX/.venv/.ok"
fi
[ -x "$OMLX/.venv/bin/omlx" ] || die "no omlx entry point in $OMLX/.venv" 12
ln -sfn "$OMLX/.venv" "$MKZ/.venv-mac"
"$OMLX/.venv/bin/python" -m pip freeze > "$RES/pip-freeze.txt" 2>/dev/null
log "VENV $(grep -E '^(mlx|mlx-metal|mlx-lm|mlx-vlm|omlx|transformers)[ =@]' "$RES/pip-freeze.txt" | tr '\n' ' ' | cut -c1-300)"

# 3. Model folders as bench.sh / serve.sh expect them (links, no copies).
ln -sfn "$OQ" "$MODELS/mlx-oq4e-mtp"
ln -sfn "$OQ" "$MODELS/Inkling-2-Mini"     # bench.sh reads the tokenizer from here

# 4. Bench: DSpark on and off, in turns.
log "BENCH_START"
MODELS=$MODELS OUT=$RES/bench ROUNDS=$ROUNDS REPEATS=$REPEATS CHAT_PAUSE=$CHAT_PAUSE WORKLOADS="$WORKLOADS" \
  OMLX=$OMLX bash "$MKZ/baselines/mac/bench.sh" omlx-oq4e-ds omlx-oq4e > "$RES/bench.out" 2>&1
grep MK_RESULT "$RES/bench.out" | sed 's/^/  /'
grep -q 'ok=false' "$RES/bench.out" && die "a bench cell failed; see $RES/bench.out and $RES/bench/logs" 13
cp "$RES/bench/logs/"*.log "$RES/" 2>/dev/null

# 5. Goal cells: median over rounds of each system's per-round medians.
/usr/bin/python3 -B -I - "$RES/bench.out" "$WORKLOADS" <<'EOF' | tee "$RES/goal.txt"
import re, statistics as st, sys
rows = [dict(re.findall(r"(\w+)=(\S+)", l)) for l in open(sys.argv[1]) if l.startswith("MK_RESULT")]
ok = True
for w in sys.argv[2].split():
    def med(sysname, key):
        v = [float(r[key]) for r in rows if r.get("system") == sysname and r.get("workload") == w and key in r]
        return st.median(v) if v else float("nan")
    p, d = med("omlx-oq4e", "tok_s"), med("omlx-oq4e-ds", "tok_s")
    tp, td = med("omlx-oq4e", "ttft_s"), med("omlx-oq4e-ds", "ttft_s")
    ok &= p == p and d == d
    print(f"GOAL_CELL workload={w} plain_tok_s={p:.1f} ds_tok_s={d:.1f} gain={d / p:.3f} ttft_plain_s={tp:.3f} ttft_ds_s={td:.3f}")
print("GOAL_OK" if ok else "GOAL_MISSING")
EOF
grep -q GOAL_OK "$RES/goal.txt" || die "a goal cell has no number" 14
# oMLX's own speculation counters, where its log prints them (acceptance, draft depth).
grep -ihE 'accept|dspark|mtp|draft' "$RES/bench/logs/omlx-oq4e-ds-r1.log" 2>/dev/null | tail -n 20 > "$RES/omlx-ds-spec-lines.txt"
log "JOB_PASS results=$RES"
