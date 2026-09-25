#!/usr/bin/env bash
# #1690 post-fix re-run on bench head (fresh LAB e2e-post).
set -uo pipefail
cd /Users/a1/macprovider-1690-e2e/scripts/lab/1690-e2e
export LAB=/Users/a1/lab-1690-m6/e2e-post
. ./env.sh
export E2E_PENDING_DEADLINE_S=90 E2E_REOFFER=1 E2E_NATIVE_CLEAR_ADMISSION=1 E2E_SKIP_SELECTION=1
RIG=../1690-m6/rig.sh
# Never load a lab model while the F3 agent's lab (/Users/a1/lab-1690-f9)
# has one loaded: wait until none of its serve / engine processes run.
f9_busy() { ps -ax -o command= | grep -F "lab-1690-f9" | grep -v grep | grep -Eq "serve|llama-server|mlx_lm|ollama"; }
wait_f9() {
  local n=0
  while f9_busy; do
    [[ $n == 0 ]] && echo "F9-GUARD $(date -u +%T) lab-1690-f9 has a model loaded; waiting"
    n=$((n + 1)); sleep 30
    if (( n > 240 )); then echo "F9-GUARD gave up after 2h"; return 1; fi
  done
  [[ $n -gt 0 ]] && echo "F9-GUARD $(date -u +%T) lab-1690-f9 idle; continuing"
  vm_stat | awk '/Pages free/ {printf "vm_stat free pages %s\n", $3}'
  return 0
}
live() { lsof -nP -iTCP:8080 -sTCP:LISTEN | tail -1 | sed "s/^/live provider :8080 $1: /"; }
echo "=== postfix start $(date -u +%FT%TZ) HEAD=$(git rev-parse --short HEAD)"
live before
for r in R1 R2; do wait_f9 && ./run_matrix.sh $r native "0 1"; done
wait_f9 && { $RIG down >/dev/null 2>&1; ENGINE=llamacpp $RIG up >/dev/null; sleep 15; ./faults.sh PF rotate; }
# observe: coordinator observe, native on NO (native-only observe pool) + global
wait_f9 && {
  export E2E_SETTLEMENT_MODE=observe
  $RIG down >/dev/null 2>&1; ENGINE=llamacpp $RIG up >/dev/null
  [[ -f "$LAB/pools/NO/pool_id" ]] || { rm -rf "$LAB/pools/NO"; python3 ../1690-m6/pool_setup.py create NO --encoding 2 --settlement-mode observe >/dev/null; }
  E2E_POOL=NO ./run_matrix.sh R1-observe native "0 1"
  unset E2E_SETTLEMENT_MODE
}
for e in llamacpp mlxlm ollama; do wait_f9 && ./run_matrix.sh R1 $e "1"; done
$RIG down >/dev/null 2>&1
# Mix A: new coordinator + origin/main gateway, llama.cpp pool (F10)
L=$(MIX_LAB=/Users/a1/lab-1690-m6/e2e-post-mixA SRC_LAB=$LAB ./mix_setup.sh A | tail -1)
wait_f9 && LAB=$L E2E_BEHAVIOURS=normal,early_close ./run_matrix.sh MIXA llamacpp "0"
LAB=$L $RIG down >/dev/null 2>&1
# Mix B: origin/main coordinator + new gateway on the UNSTRIPPED #1690 feed (F11)
L=$(MIX_LAB=/Users/a1/lab-1690-m6/e2e-post-mixB SRC_LAB=$LAB ./mix_setup.sh B | tail -1)
wait_f9 && LAB=$L E2E_SKIP_POOL=1 E2E_BEHAVIOURS=normal,early_close ./run_matrix.sh MIXB native "0"
LAB=$L $RIG down >/dev/null 2>&1
live after
echo "=== postfix done $(date -u +%FT%TZ)"
