#!/usr/bin/env bash
# #1690 M9 review: re-run only the disconnect cases on the external engines,
# gateway pin on: `disconnect` (short prompt, idle engine) and
# `disconnect_busy` (a ~3000-token prompt while three other long-prompt
# streams keep the engine busy), REPEAT times each. Lab only (rig.sh).
#   disconnect_rerun.sh RUN [ENGINES]
set -euo pipefail
export LAB="${LAB:-/Users/a1/lab-1690-m6/m9}"
HERE="$(cd "$(dirname "$0")" && pwd)"
RIG="$HERE/../1690-m6/rig.sh"
. "$HERE/env.sh"
export E2E_PENDING_DEADLINE_S="${E2E_PENDING_DEADLINE_S:-90}" E2E_REOFFER=1
RUN=$1
ENGINES=${2:-"llamacpp mlxlm ollama lmstudio omlx"}
pool_of() { case "$1" in llamacpp) echo A ;; mlxlm) echo M ;; ollama) echo O ;; lmstudio) echo L ;; omlx) echo X ;; *) exit 2 ;; esac; }
mkdir -p "$LAB/e2e/logs"
exec > >(tee -a "$LAB/e2e/logs/$RUN.log") 2>&1
lsof -nP -iTCP:8080 -sTCP:LISTEN | tail -1 | sed 's/^/live provider :8080 before: /'
for e in $ENGINES; do
  echo "=== $(date -u +%FT%TZ) run=$RUN engine=$e HEAD=$(git -C "$HERE" rev-parse --short HEAD)"
  "$RIG" down >/dev/null 2>&1 || true
  ENGINE=$e E2E_GATEWAY_PIN=1 "$RIG" up >/dev/null
  sleep "${E2E_SETTLE_JOIN_S:-15}"
  python3 "$HERE/matrix.py" send --label "$RUN-$e" --engine "$e" --route "pool:$(pool_of "$e")" --behaviours disconnect,disconnect_busy --repeat "${REPEAT:-2}"
  python3 "$HERE/matrix.py" settle --label "$RUN-$e" --timeout 300 || true
done
"$RIG" down >/dev/null 2>&1 || true
lsof -nP -iTCP:8080 -sTCP:LISTEN | tail -1 | sed 's/^/live provider :8080 after: /'
echo "=== $RUN done $(date -u +%FT%TZ)"
