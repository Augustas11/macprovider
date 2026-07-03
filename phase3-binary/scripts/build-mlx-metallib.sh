#!/usr/bin/env bash
# Build MLX's Metal kernel library for SwiftPM/CLI artifacts.

set -euo pipefail

PHASE3_DIR="$(cd "$(dirname "$0")/.." && pwd)"
OUTPUT_DIR="${1:-$PHASE3_DIR/.build/arm64-apple-macosx/debug}"
MLX_SWIFT_CHECKOUT="${MLX_SWIFT_CHECKOUT:-$PHASE3_DIR/.build/checkouts/mlx-swift}"

KERNEL_ROOT="$MLX_SWIFT_CHECKOUT/Source/Cmlx/mlx/mlx/backend/metal/kernels"
MLX_ROOT="$MLX_SWIFT_CHECKOUT/Source/Cmlx/mlx"

die() {
  printf 'build-mlx-metallib: ERROR: %s\n' "$*" >&2
  exit 1
}

version_ge() {
  [ "$(printf '%s\n%s\n' "$2" "$1" | sort -V | head -n 1)" = "$2" ]
}

metal_version() {
  printf '%s\n' '__METAL_VERSION__' \
    | xcrun -sdk macosx metal -E -x metal -P - 2>/dev/null \
    | tail -n 1 \
    | tr -d '[:space:]'
}

[ -d "$KERNEL_ROOT" ] || die "missing MLX kernels at $KERNEL_ROOT"
command -v xcrun >/dev/null 2>&1 || die "missing xcrun"

METAL_VERSION="$(metal_version)"
case "$METAL_VERSION" in
  ''|*[!0-9]*) die "Metal toolchain unavailable; run: xcodebuild -downloadComponent MetalToolchain" ;;
esac

SDK_VERSION="$(xcrun -sdk macosx --show-sdk-version)"

kernels=(
  arg_reduce
  conv
  gemv
  layer_norm
  random
  rms_norm
  rope
  scaled_dot_product_attention
  arange
  binary
  binary_two
  copy
  fft
  reduce
  quantized
  fp_quantized
  scan
  softmax
  logsumexp
  sort
  ternary
  unary
  steel/conv/kernels/steel_conv
  steel/conv/kernels/steel_conv_3d
  steel/conv/kernels/steel_conv_general
  steel/gemm/kernels/steel_gemm_fused
  steel/gemm/kernels/steel_gemm_gather
  steel/gemm/kernels/steel_gemm_masked
  steel/gemm/kernels/steel_gemm_splitk
  steel/gemm/kernels/steel_gemm_segmented
  gemv_masked
  steel/attn/kernels/steel_attention
)

if [ "$METAL_VERSION" -ge 320 ]; then
  kernels+=(fence)
fi

if [ "$METAL_VERSION" -ge 400 ] && version_ge "$SDK_VERSION" "26.2"; then
  kernels+=(
    steel/gemm/kernels/steel_gemm_fused_nax
    steel/gemm/kernels/steel_gemm_gather_nax
    steel/gemm/kernels/steel_gemm_splitk_nax
    quantized_nax
    fp_quantized_nax
    steel/attn/kernels/steel_attention_nax
  )
fi

WORKDIR="$(mktemp -d "${TMPDIR:-/tmp}/mlx-metallib.XXXXXX")"
cleanup() {
  case "$WORKDIR" in
    "${TMPDIR:-/tmp}"/mlx-metallib.*) rm -rf "$WORKDIR" ;;
  esac
}
trap cleanup EXIT

metal_flags=(
  -x metal
  -Wall
  -Wextra
  -fno-fast-math
  -Wno-c++17-extensions
  -Wno-c++20-extensions
)

if [ -n "${MACOSX_DEPLOYMENT_TARGET:-}" ]; then
  metal_flags+=("-mmacosx-version-min=$MACOSX_DEPLOYMENT_TARGET")
fi

air_files=()
for kernel in "${kernels[@]}"; do
  src="$KERNEL_ROOT/$kernel.metal"
  [ -f "$src" ] || die "missing kernel source: $src"
  air="$WORKDIR/${kernel//\//_}.air"
  xcrun -sdk macosx metal "${metal_flags[@]}" -c "$src" -I"$MLX_ROOT" -o "$air"
  air_files+=("$air")
done

mkdir -p "$OUTPUT_DIR"
xcrun -sdk macosx metallib "${air_files[@]}" -o "$OUTPUT_DIR/mlx.metallib"
printf 'build-mlx-metallib: wrote %s/mlx.metallib\n' "$OUTPUT_DIR"
