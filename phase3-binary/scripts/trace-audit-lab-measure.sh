#!/bin/bash
# Trace audit lab measurement (campaign #2419, SPEC-036 §5B pilot).
#
# Run only inside a booked exclusive slot: the live provider paused, no other
# build, test or bench on the Mac. The script does not pause anything itself.
#
#   phase3-binary/scripts/trace-audit-lab-measure.sh OUT.json --model MODEL_DIR [--bin CLI] [--build]
#
# MODEL_DIR is a local mlx-community checkpoint directory (config.json +
# safetensors), e.g. Qwen2.5-7B-Instruct-4bit. --build makes the lab-harness
# release build first. The CLI must be a MACPROVIDER_LAB_HARNESS build.
#
# Steps:
#  1. macprovider-cli trace-audit-lab measure: capture off vs on through the
#     real CB scheduler at concurrency 1, 4 and 8 (prefill and decode tok/s,
#     modes alternating off/on, on/off per round), bytes per position, time
#     from response to root, openings at p = 100 / 1000 / 4000, 10 FR-29
#     challenges (50 points), the prompt-cache-hit case.
#  2. trace-audit-lab-verify.py over the challenge openings (MLX float16).
#  3. Writes OUT.json = {host, measure, verify}. Residual files and openings
#     are deleted on exit (KEEP_TRACE_AUDIT_LAB=1 keeps them for debugging).
set -euo pipefail

usage() { sed -n 4,9p "$0" >&2; exit 2; }
[ $# -ge 1 ] || usage
OUT=$1; shift
MODEL="" BIN="" BUILD=0
while [ $# -gt 0 ]; do
  case "$1" in
    --model) MODEL=$2; shift 2 ;;
    --bin) BIN=$2; shift 2 ;;
    --build) BUILD=1; shift ;;
    *) usage ;;
  esac
done
[ -n "$MODEL" ] && [ -f "$MODEL/config.json" ] || { echo "--model must be a local checkpoint directory" >&2; exit 2; }

HERE=$(cd "$(dirname "$0")" && pwd)
PKG=$(cd "$HERE/.." && pwd)
if [ "$BUILD" = 1 ]; then
  (cd "$PKG" && swift build -c release --product macprovider-cli -Xswiftc -DMACPROVIDER_LAB_HARNESS)
fi
BIN=${BIN:-$PKG/.build/release/macprovider-cli}
[ -x "$BIN" ] || { echo "no CLI at $BIN (use --build or --bin)" >&2; exit 2; }

WORK=$(mktemp -d "${TMPDIR:-/tmp}/trace-audit-lab.XXXXXX")
chmod 700 "$WORK"
cleanup() { [ "${KEEP_TRACE_AUDIT_LAB:-0}" = 1 ] || rm -rf "$WORK"; }
trap cleanup EXIT

LOAD_START=$(sysctl -n vm.loadavg)
MACPROVIDER_TRACE_AUDIT_LAB=1 \
MACPROVIDER_TRACE_AUDIT_LAB_DIR="$WORK/store" \
  "$BIN" trace-audit-lab measure \
    --model "$MODEL" \
    --out "$WORK/measure.json" \
    --openings-dir "$WORK/openings" \
    --concurrency 1,4,8 --rounds 4 \
    --prompt-tokens 1024 --decode-tokens 128 \
    --long-prompt-tokens 4090 --points 50 \
    2> "$WORK/measure.log" || { tail -n 20 "$WORK/measure.log" >&2; exit 1; }

set +e
python3 "$HERE/trace-audit-lab-verify.py" --model "$MODEL" \
  --manifest "$WORK/openings/manifest.json" --out "$WORK/verify.json"
VERIFY_RC=$?
set -e
[ -f "$WORK/verify.json" ] || { echo "verifier wrote no result (rc=$VERIFY_RC)" >&2; exit 1; }

python3 - "$WORK" "$OUT" "$MODEL" "$LOAD_START" "$VERIFY_RC" "$(git -C "$PKG" rev-parse HEAD 2>/dev/null || echo unknown)" <<'PY'
import json, platform, subprocess, sys
work, out, model, load, rc, sha = sys.argv[1:]
host = {
    "chip": subprocess.check_output(["sysctl", "-n", "machdep.cpu.brand_string"], text=True).strip(),
    "memory_bytes": int(subprocess.check_output(["sysctl", "-n", "hw.memsize"], text=True)),
    "macos": platform.mac_ver()[0], "load_average_at_start": load.strip(), "source_commit": sha,
}
doc = {"schema": "macprovider.trace-audit-lab.result.v1", "host": host, "model": model,
       "measure": json.load(open(f"{work}/measure.json")),
       "verify": json.load(open(f"{work}/verify.json")), "verify_exit_code": int(rc)}
json.dump(doc, open(out, "w"), indent=1, sort_keys=True)
print(json.dumps({"out": out, "verify": doc["verify"]["summary"]}))
PY
