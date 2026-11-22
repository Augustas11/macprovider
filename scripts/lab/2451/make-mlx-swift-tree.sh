#!/bin/bash
# Builds, on this Mac, the mlx-swift source tree the #2451 Studio job compiles against: mlx-swift
# at the provider's pin with Source/Cmlx/mlx replaced by the fork commit of the tile hook
# (macprovider/2451-tile-variants) and Source/Cmlx/mlx-c at the pin's own gitlink. Reads git
# objects only (git archive); never checks out or edits a worktree.
#
# usage: make-mlx-swift-tree.sh OUT_DIR CORE_COMMIT
#   OUT_DIR      gets OUT_DIR/mlx-swift (SwiftPM names a path dependency after its directory)
#   CORE_COMMIT  the fork commit to place at Source/Cmlx/mlx
# Env: MLX_SWIFT_GIT (git dir holding mlx-swift MLX_SWIFT_REV), MLX_C_GIT (mlx-c), MLX_GIT (mlx
#   fork), MLX_SWIFT_REV (default 12d26ef6c6d65ba3a265a2b65c3c9380d9c22bd7, SPEC048_MLX_SWIFT_REVISION).
# Writes OUT_DIR/mlx-swift/Source/Cmlx/LAB_2451_CORE (the three revisions). Exit 2 on a missing
# object or a core without the hook.
set -euo pipefail
OUT=${1:?usage: make-mlx-swift-tree.sh OUT_DIR CORE_COMMIT}
CORE=${2:?usage: make-mlx-swift-tree.sh OUT_DIR CORE_COMMIT}
MLX_SWIFT_GIT=${MLX_SWIFT_GIT:-/Users/augstar/mlx-swift-2462/.git}
MLX_C_GIT=${MLX_C_GIT:-/Users/augstar/mlx-swift-2462/.git/modules/submodules/mlx-c}
MLX_GIT=${MLX_GIT:-/Users/augstar/mlx-upstream-753/.git}
MLX_SWIFT_REV=${MLX_SWIFT_REV:-12d26ef6c6d65ba3a265a2b65c3c9380d9c22bd7}
die() { echo "BLOCKER: make-mlx-swift-tree: $*" >&2; exit 2; }

git --git-dir="$MLX_SWIFT_GIT" cat-file -e "$MLX_SWIFT_REV^{commit}" 2>/dev/null \
  || die "no mlx-swift $MLX_SWIFT_REV in $MLX_SWIFT_GIT (set MLX_SWIFT_GIT)"
MLX_C_REV=$(git --git-dir="$MLX_SWIFT_GIT" ls-tree "$MLX_SWIFT_REV" Source/Cmlx/mlx-c | awk '{print $3}')
PIN_CORE=$(git --git-dir="$MLX_SWIFT_GIT" ls-tree "$MLX_SWIFT_REV" Source/Cmlx/mlx | awk '{print $3}')
[ -n "$MLX_C_REV" ] && [ -n "$PIN_CORE" ] || die "mlx-swift $MLX_SWIFT_REV has no Cmlx gitlinks"
git --git-dir="$MLX_C_GIT" cat-file -e "$MLX_C_REV^{commit}" 2>/dev/null || die "no mlx-c $MLX_C_REV in $MLX_C_GIT (set MLX_C_GIT)"
git --git-dir="$MLX_GIT" cat-file -e "$CORE^{commit}" 2>/dev/null || die "no core $CORE in $MLX_GIT (set MLX_GIT)"
git --git-dir="$MLX_GIT" merge-base --is-ancestor "$PIN_CORE" "$CORE" 2>/dev/null \
  || die "core $CORE does not descend from the pin's core $PIN_CORE"
# grep -c reads all input: grep -q would close the pipe early and fail the pipeline (pipefail).
[ "$(git --git-dir="$MLX_GIT" show "$CORE:mlx/backend/metal/quantized.cpp" | grep -c MLX_LAB_2451_QMM_TILE)" -gt 0 ] \
  || die "core $CORE has no MLX_LAB_2451 tile hook"

T=$OUT/mlx-swift
rm -rf "$T"
mkdir -p "$T/Source/Cmlx/mlx" "$T/Source/Cmlx/mlx-c"
git --git-dir="$MLX_SWIFT_GIT" archive --format=tar "$MLX_SWIFT_REV" | tar -x -C "$T"
git --git-dir="$MLX_GIT" archive --format=tar "$CORE" | tar -x -C "$T/Source/Cmlx/mlx"
git --git-dir="$MLX_C_GIT" archive --format=tar "$MLX_C_REV" | tar -x -C "$T/Source/Cmlx/mlx-c"
printf 'mlx_swift=%s\nmlx_c=%s\ncore=%s\npin_core=%s\n' "$MLX_SWIFT_REV" "$MLX_C_REV" \
  "$(git --git-dir="$MLX_GIT" rev-parse "$CORE^{commit}")" "$PIN_CORE" > "$T/Source/Cmlx/LAB_2451_CORE"
echo "MLX_SWIFT_TREE $T mlx_swift=${MLX_SWIFT_REV:0:12} mlx_c=${MLX_C_REV:0:12} core=$(git --git-dir="$MLX_GIT" rev-parse --short=12 "$CORE^{commit}")"
