#!/usr/bin/env bash
# #1690 Pearl-shaped lab e2e: one entry point that builds a ref, brings the
# isolated rig up with Pearl's production config shape and a 220 ms RTT
# provider path, runs the pearl_shaped.py matrix on llama.cpp and Ollama, writes
# a summary table, and tears down by recorded PID.
#
#   pearl_shaped.sh run --ref <commit> [--engines "llamacpp ollama"] [--samples 24]
#   pearl_shaped.sh summary --ref <commit>
#   pearl_shaped.sh down --ref <commit>
#
# The ref's coordinator, gateway, labtool and provider CLI are built (rig.sh
# build with LAB_BUILD_REF); the harness itself runs from this worktree, which
# must be clean. LAB defaults to /Users/a1/lab-1690-m6/pearl-<ref9>; an
# existing LAB is moved aside to <LAB>.prev-<utc>, never deleted. Lab inputs
# are cloned (cp -c) from ASSETS: the pinned Qwen2.5-0.5B GGUF (llama-server
# --jinja), the Ollama binary and its qwen2.5:0.5b store.
#
# Safety: lab ports 19101-19131 only (+19103 latency proxy); never 8080/8443/
# 8444; never ~/.config/macprovider, /Users/a1/macprovider or
# /Users/a1/malibu-m1-pool (read once for the Ollama binary and metallib copy);
# no production host; processes are signalled only through pidguard.sh.
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
WT="$(cd "$HERE/../../.." && pwd)"
RIG="$HERE/../1690-m6/rig.sh"
ASSETS="${ASSETS:-/Users/a1/lab-1690-m6/assets}"
CMD="${1:-}"; shift || true
REF="" ENGINES="llamacpp ollama" SAMPLES=24
while [[ $# -gt 0 ]]; do
  case "$1" in
    --ref) REF=$2; shift 2 ;;
    --engines) ENGINES=$2; shift 2 ;;
    --samples) SAMPLES=$2; shift 2 ;;
    *) echo "unknown argument $1" >&2; exit 2 ;;
  esac
done
[[ -n "$REF" ]] || { echo "usage: pearl_shaped.sh run|summary|down --ref <commit> [--engines E] [--samples N]" >&2; exit 2; }
REF=$(git -C "$WT" rev-parse --verify "$REF^{commit}")
export LAB="${LAB:-/Users/a1/lab-1690-m6/pearl-${REF:0:9}}"
case "$LAB" in /Users/a1/lab-1690-m6/*) ;; *) echo "refusing: LAB must be under /Users/a1/lab-1690-m6" >&2; exit 2 ;; esac
export LAB_BUILD_REF=$REF
export LLAMA_DIR="${LLAMA_DIR:-/Users/a1/lab-1816-final/tools/llama-b11149}"
export METALLIB="${METALLIB:-$ASSETS/mlx.metallib}"
# shellcheck source=env.sh
. "$HERE/env.sh"
# Pearl config shape (write_configs.py), gateway settlement pin, lab-short
# pending deadline, a re-offer on every engine switch, and the provider WS
# through latency_proxy.py at 110 ms each way.
export E2E_PEARL_SHAPED=1 E2E_GATEWAY_PIN=1 E2E_PENDING_DEADLINE_S="${E2E_PENDING_DEADLINE_S:-90}" E2E_REOFFER=1
export E2E_LATENCY_MS="${E2E_LATENCY_MS:-110}"
pool_of() { case "$1" in llamacpp) echo A ;; ollama) echo O ;; *) echo "unsupported engine $1" >&2; exit 2 ;; esac; }

live_ports() { # production listeners that must stay up; reported, never touched
  for p in 8080 18120 18122 18130 11435; do
    printf ':%s=%s ' "$p" "$(lsof -nP -iTCP:"$p" -sTCP:LISTEN -t 2>/dev/null | head -1 || true)"
  done
  echo
}

setup() {
  if [[ -e "$LAB" ]]; then
    "$RIG" down >/dev/null 2>&1 || true
    mv "$LAB" "$LAB.prev-$(date -u +%Y%m%dT%H%M%SZ)"
  fi
  mkdir -p "$LAB"/{bin,logs,models,keys,db,run,static,pools,home,tmp,provider,pearl}
  chmod 700 "$LAB/keys" "$LAB/home"
  cp -c "$ASSETS/models/qwen2.5-0.5b-instruct-q4_k_m.gguf" "$LAB/models/"
  cp -cR "$ASSETS/ollama" "$LAB/ollama"
  cp -cR "$ASSETS/ollama-models" "$LAB/ollama-models"
  for p in $(seq 19101 19131); do
    if lsof -nP -iTCP:"$p" -sTCP:LISTEN -t >/dev/null 2>&1; then echo "refusing: lab port $p is in use" >&2; exit 1; fi
  done
}

run() {
  git -C "$WT" diff --quiet HEAD -- scripts/lab || { echo "refusing: harness worktree has uncommitted changes" >&2; exit 1; }
  setup
  python3 - "$LAB/pearl/run-meta.json" "$REF" "$(git -C "$WT" rev-parse HEAD)" "$E2E_LATENCY_MS" <<'EOF'
import json, sys, time
open(sys.argv[1], "w").write(json.dumps({"ref": sys.argv[2], "harness": sys.argv[3], "one_way_ms": int(sys.argv[4]),
                                         "started": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime())}))
EOF
  exec > >(tee -a "$LAB/pearl/run.log") 2>&1
  echo "=== $(date -u +%FT%TZ) pearl-shaped ref=$REF harness=$(git -C "$WT" rev-parse --short HEAD) LAB=$LAB"
  echo "live listeners before: $(live_ports)"
  trap '"$RIG" down >/dev/null 2>&1 || true; echo "live listeners after: $(live_ports)"' EXIT
  "$RIG" model
  echo "--- build $REF (log: $LAB/logs/build.log)"
  "$RIG" build >"$LAB/logs/build.log" 2>&1 || { tail -40 "$LAB/logs/build.log"; echo "HARNESS ERROR: build failed"; exit 1; }
  for e in $ENGINES; do
    pool_of "$e" >/dev/null
    echo "--- $(date -u +%FT%TZ) engine=$e"
    "$RIG" down >/dev/null 2>&1 || true
    if ! ENGINE=$e "$RIG" up >"$LAB/logs/up-$e.log" 2>&1; then
      tail -30 "$LAB/logs/up-$e.log"
      echo "HARNESS ERROR: rig up failed for $e"
      python3 - "$LAB/pearl/$e.json" "$e" <<'EOF'
import json, sys
json.dump([{"engine": sys.argv[2], "case": "rig_up", "expected": "rig up", "status": "ERROR", "actual": "",
            "request_ids": [], "rows": [], "error": "rig up failed (logs/up-*.log)"}], open(sys.argv[1], "w"))
EOF
      continue
    fi
    # Join, the #1863 startup throughput probe, and the pool refresh.
    sleep "${E2E_SETTLE_JOIN_S:-25}"
    "$RIG" status || true
    python3 "$HERE/pearl_shaped.py" cases --engine "$e" --samples "$SAMPLES" || echo "HARNESS ERROR: cases exited $? for $e"
  done
  "$RIG" down >/dev/null 2>&1 || true
  python3 "$HERE/pearl_shaped.py" summary | tee "$LAB/pearl/summary.md"
  echo "=== done $(date -u +%FT%TZ) summary: $LAB/pearl/summary.md"
}

case "$CMD" in
  run) run ;;
  summary) python3 "$HERE/pearl_shaped.py" summary ;;
  down) "$RIG" down ;;
  *) echo "usage: pearl_shaped.sh run|summary|down --ref <commit>" >&2; exit 2 ;;
esac
