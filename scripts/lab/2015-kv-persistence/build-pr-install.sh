#!/usr/bin/env bash
# #2015 re-run: assemble a lab "install" directory from a PR-head build so
# studio-kv-acceptance.sh can run against it (SRC_INSTALL=<this dir>). Lab
# only; never shipped. Runs on the Studio with nothing paused: it compiles
# (nice'd) and copies files, and loads no model.
#
# The binary comes from scripts/lab/1971-selfcheck/build-lab-binaries.sh in the
# PR lab clone, which pins binaryVersion to the live install's provider_cli
# version (serve refuses a version without a signed compatibility set) and
# reverts that edit after the build. The live install is only read: its
# compatibility-set.json, mlx.metallib and resource bundles are copied beside
# the lab binary. The MLX pin must be unchanged by the PR (checked below), so
# the release metallib and the CB accepted tuples in the lab template still
# apply.
#
# Usage on the Studio:
#   LAB_CLONE=~/macprovider-2015-fix-lab bash build-pr-install.sh
#   # then, inside the paused window:
#   SRC_INSTALL=~/lab-2015/pr-install bash run-in-gui-domain.sh
# Optional: LIVE_INSTALL_DIR (~/macprovider) OUT_DIR (~/lab-2015/pr-install)
set -euo pipefail
export PATH=/usr/sbin:/opt/homebrew/bin:/usr/bin:/bin

: "${LAB_CLONE:?set LAB_CLONE to the PR-head git clone}"
LIVE_INSTALL_DIR="${LIVE_INSTALL_DIR:-$HOME/macprovider}"
OUT_DIR="${OUT_DIR:-$HOME/lab-2015/pr-install}"
BUILDER="$LAB_CLONE/scripts/lab/1971-selfcheck/build-lab-binaries.sh"
[[ -f "$BUILDER" ]] || { echo "build-pr-install: missing $BUILDER" >&2; exit 2; }
[[ -z "$(git -C "$LAB_CLONE" status --porcelain)" ]] || { echo "build-pr-install: $LAB_CLONE is dirty" >&2; exit 2; }
[[ -x "$LIVE_INSTALL_DIR/macprovider-cli" && -f "$LIVE_INSTALL_DIR/mlx.metallib" ]] || {
  echo "build-pr-install: no released install at $LIVE_INSTALL_DIR" >&2; exit 2; }

# The release metallib and CB tuples are only valid for the same MLX pins as
# the live release: compare the PR's Package.resolved with the release tag's.
live_version="$("$LIVE_INSTALL_DIR/macprovider-cli" --version)"
git -C "$LAB_CLONE" fetch -q origin "refs/tags/v$live_version:refs/tags/v$live_version"
pins() { python3 -c 'import json,sys
d=json.load(sys.stdin)
print(" ".join(p["identity"]+"@"+p["state"]["revision"] for p in d["pins"] if p["identity"] in ("mlx-swift","mlx-swift-lm")))'; }
release_pins="$(git -C "$LAB_CLONE" show "v$live_version:phase3-binary/Package.resolved" | pins)"
pr_pins="$(pins < "$LAB_CLONE/phase3-binary/Package.resolved")"
[[ -n "$pr_pins" && "$pr_pins" == "$release_pins" ]] || {
  echo "build-pr-install: MLX pins differ from v$live_version ($pr_pins vs $release_pins)" >&2; exit 2; }
echo "build-pr-install: MLX pins match v$live_version: $pr_pins" >&2

LAB_CLONE="$LAB_CLONE" LIVE_INSTALL_DIR="$LIVE_INSTALL_DIR" bash "$BUILDER"
built="$LAB_CLONE/phase3-binary/.build-lab/release"
[[ -x "$built/macprovider-cli" ]] || { echo "build-pr-install: no binary at $built" >&2; exit 3; }

rm -rf "$OUT_DIR"
mkdir -p "$OUT_DIR"
chmod 700 "$OUT_DIR"
ditto "$built/macprovider-cli" "$OUT_DIR/macprovider-cli"
ditto "$built/lab-build-provenance.txt" "$OUT_DIR/lab-build-provenance.txt"
for f in mlx.metallib compatibility-set.json mlx-swift_Cmlx.bundle swift-nio_NIOPosix.bundle; do
  [[ -e "$LIVE_INSTALL_DIR/$f" ]] && ditto "$LIVE_INSTALL_DIR/$f" "$OUT_DIR/$f"
done
codesign --verify --strict "$OUT_DIR/macprovider-cli" || { echo "build-pr-install: lab binary fails codesign --verify" >&2; exit 3; }
[[ "$(shasum -a 256 "$OUT_DIR/mlx.metallib" | cut -d' ' -f1)" == "$(shasum -a 256 "$LIVE_INSTALL_DIR/mlx.metallib" | cut -d' ' -f1)" ]]
{
  echo "mlx_pins $pr_pins (same as v$live_version)"
  echo "assembled_at $(date -u +%Y-%m-%dT%H:%M:%SZ)"
} >> "$OUT_DIR/lab-build-provenance.txt"
echo "build-pr-install: $OUT_DIR ready; version=$("$OUT_DIR/macprovider-cli" --version)" >&2
cat "$OUT_DIR/lab-build-provenance.txt" >&2
