#!/usr/bin/env bash
# #1971 / PR #1980 lab binaries for studio-selfcheck-validation.sh. Lab only;
# never shipped. Runs on the Mac under test, with nothing paused.
#
# Why the version pin: serve (not an autotune child) loads the installed
# provider's signed compatibility set and refuses to start when its
# provider_cli version differs from the running binary's `binaryVersion`.
# When main stages a CLI version ahead of the live install, a lab build of the
# PR head carries the staged version, no signed set for it exists yet, and the
# lab serve exits during load. The lab binaries are therefore built with
# `binaryVersion` pinned to the live install's provider_cli version. Nothing
# else changes: the FR-CB10 self-check key (MLX pins, row-isolation bounds,
# probe version), the decode path and the probe do not read the CLI version.
# The source edit is made in the lab clone only, reverted after each build,
# and recorded in lab-build-provenance.txt beside the binaries.
#
# The live install is only read: its compatibility-set.json (version) and
# mlx.metallib (copied beside each lab binary, same MLX pin required).
#
# Usage:
#   LAB_CLONE=/path/to/lab-clone            # git checkout of the PR head
#   LIVE_INSTALL_DIR=/path/to/live/install  # holds macprovider-cli,
#                                           # compatibility-set.json, mlx.metallib
#   HARNESS_BUILD_FLAGS='-Xswiftc -D<lab harness define>'  # see the PR body
#   bash build-lab-binaries.sh   # builds .build-lab, and .build-lab-harness
#                                # when HARNESS_BUILD_FLAGS is set
set -euo pipefail
export PATH=/usr/sbin:/opt/homebrew/bin:/usr/bin:/bin

: "${LAB_CLONE:?}" "${LIVE_INSTALL_DIR:?}"
PKG="$LAB_CLONE/phase3-binary"
SRC="$PKG/Sources/macprovider-cli/CoordinatorClient.swift"
[[ -f "$SRC" ]] || { echo "build-lab-binaries: no $SRC" >&2; exit 2; }
[[ -z "$(git -C "$LAB_CLONE" status --porcelain -- "$SRC")" ]] || {
  echo "build-lab-binaries: $SRC has local edits; refusing" >&2; exit 2; }

live_version="$(python3 - "$LIVE_INSTALL_DIR/compatibility-set.json" <<'PY'
import json, sys
print(json.load(open(sys.argv[1]))["signed"]["components"]["provider_cli"]["version"])
PY
)"
[[ "$live_version" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || { echo "build-lab-binaries: live version unreadable" >&2; exit 2; }
head_version="$(sed -n 's/^ *static let binaryVersion = "\([0-9.]*\)".*/\1/p' "$SRC")"
[[ -n "$head_version" ]] || { echo "build-lab-binaries: binaryVersion line not found" >&2; exit 2; }
echo "build-lab-binaries: PR head binaryVersion=$head_version, live provider_cli=$live_version" >&2

restore() { git -C "$LAB_CLONE" checkout -q -- "$SRC"; }
trap restore EXIT

build() {
  local path="$1"; shift
  sed -i '' "s/static let binaryVersion = \"$head_version\"/static let binaryVersion = \"$live_version\"/" "$SRC"
  grep -q "static let binaryVersion = \"$live_version\"" "$SRC" || { echo "build-lab-binaries: pin failed" >&2; exit 3; }
  (cd "$PKG" && nice -n 10 swift build -c release --product macprovider-cli --build-path "$path" "$@")
  restore
  local out="$PKG/$path/release"
  cp "$LIVE_INSTALL_DIR/mlx.metallib" "$out/mlx.metallib"
  local reported
  reported="$("$out/macprovider-cli" --version)"
  [[ "$reported" == "$live_version" ]] || { echo "build-lab-binaries: $out reports $reported" >&2; exit 3; }
  {
    echo "lab_clone_head $(git -C "$LAB_CLONE" rev-parse HEAD)"
    echo "pr_head_binary_version $head_version"
    echo "lab_pinned_binary_version $live_version"
    echo "lab_only_source_edit $SRC binaryVersion $head_version -> $live_version (reverted after build)"
    echo "extra_build_flags ${*:-none}"
    echo "binary_sha256 $(shasum -a 256 "$out/macprovider-cli" | cut -d' ' -f1)"
    echo "metallib_sha256 $(shasum -a 256 "$out/mlx.metallib" | cut -d' ' -f1)"
  } > "$out/lab-build-provenance.txt"
  echo "build-lab-binaries: $out/macprovider-cli version=$reported" >&2
}

build .build-lab
if [[ -n "${HARNESS_BUILD_FLAGS:-}" ]]; then
  # shellcheck disable=SC2086 # word-split the operator-supplied flags
  build .build-lab-harness $HARNESS_BUILD_FLAGS
fi
