#!/usr/bin/env bash
# Build 1 private-Qwen physical staging wrapper.
#
# This wrapper deliberately reuses the reviewed #1690 isolated coordinator /
# gateway rig while replacing only its lab model authority. It never uses live
# ports, live credentials, or the public candidate catalog.
set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
export WT="${WT:-$(cd "$HERE/../../.." && pwd)}"
BASE_RIG="$WT/scripts/lab/1690-m6/rig.sh"

export LAB="${LAB:-/Users/a1/lab-build1-private-staging}"
export ENGINE=native
export LAB_ROW_KEY=orcarouter/qwen3.8-27b-uncensored
export LAB_MLX_ID=orcarouter/Qwen3.8-27B-Uncensored-MLX
export LAB_MLX_REV=38d0ad4e02031658fadd3828634a0174e0b8a282
export LAB_MLX_SHA=8794a87d2041dce5e915809d9e6c16da709d1763e25c4289f279d929aea88dcd
export MLX_SHA="$LAB_MLX_SHA"
export LAB_STATIC_RELEASE=build1-private-staging-2026-09-27-v1
export E2E_NATIVE_CLEAR_ADMISSION=1

: "${BUILD1_PRIVATE_SNAPSHOT:?set BUILD1_PRIVATE_SNAPSHOT to the verified durable snapshot root}"
case "$BUILD1_PRIVATE_SNAPSHOT" in
  /*) ;;
  *) printf 'refusing: BUILD1_PRIVATE_SNAPSHOT must be absolute\n' >&2; exit 2 ;;
esac
[[ -d "$BUILD1_PRIVATE_SNAPSHOT/4-bit" ]] || {
  printf 'refusing: Build 1 private snapshot has no 4-bit runtime member\n' >&2
  exit 2
}
export MLXLM_SNAPSHOT="$BUILD1_PRIVATE_SNAPSHOT"
export BUILD1_PRIVATE_HF_CACHE="${BUILD1_PRIVATE_HF_CACHE:-/Users/a1/Library/Application Support/MacProvider-Campaigns/build1-1642/hf}"
[[ -d "$BUILD1_PRIVATE_HF_CACHE/hub/models--orcarouter--Qwen3.8-27B-Uncensored-MLX/snapshots/$LAB_MLX_REV" ]] || {
  printf 'refusing: Build 1 private Hugging Face snapshot is unavailable for admission discovery\n' >&2
  exit 2
}

case "$LAB" in
  /Users/a1/lab-build1-private-staging|/Users/a1/lab-build1-private-staging/*) ;;
  *) printf 'refusing: LAB must stay under /Users/a1/lab-build1-private-staging\n' >&2; exit 2 ;;
esac

case "${1:-}" in
  prepare)
    "$BASE_RIG" build
    "$BASE_RIG" build-native
    ;;
  request)
    python3 "$WT/scripts/lab/1690-m6/buyer.py" --n 1 --concurrency 1 --max-tokens 16
    ;;
  admit)
    python3 "$HERE/admit.py"
    ;;
  evidence)
    python3 "$WT/scripts/lab/1690-m6/evidence.py" --last 1
    ;;
  up|down|status|configs)
    exec "$BASE_RIG" "$1"
    ;;
  *)
    printf 'usage: rig.sh prepare|up|admit|request|evidence|status|down|configs\n' >&2
    exit 2
    ;;
esac
