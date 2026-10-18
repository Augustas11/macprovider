#!/usr/bin/env bash
# shellcheck disable=SC2016  # the greps match literal shell text in package.sh
# Hermetic checks for scripts/mlx-metallib-kernels.py and its release wiring.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
TOOL="$REPO_ROOT/scripts/mlx-metallib-kernels.py"
MANIFEST="$REPO_ROOT/phase3-binary/mlx-metallib-required-kernels.json"

die() { printf '[mlx-metallib-kernels-test] ERROR: %s\n' "$*" >&2; exit 1; }
log() { printf '[mlx-metallib-kernels-test] %s\n' "$*" >&2; }

TMP_BASE="${TMPDIR:-/tmp}"
WORKDIR="$(mktemp -d "$TMP_BASE/mlx-metallib-kernels-test.XXXXXX")"
cleanup() {
  case "$WORKDIR" in
    "$TMP_BASE"/mlx-metallib-kernels-test.*) rm -rf "$WORKDIR" ;;
  esac
}
trap cleanup EXIT

# write_metallib OUT NAME...: the MTLB layout the Metal toolchain emits (header,
# u64 function-list offset/size at 0x18, u32 count, per-function tag lists).
write_metallib() {
  python3 - "$@" <<'PY'
import struct, sys
out, names = sys.argv[1], sys.argv[2:]
entries = b""
for name in names:
    raw = name.encode() + b"\0"
    tags = b"NAME" + struct.pack("<H", len(raw)) + raw
    tags += b"TYPE" + struct.pack("<H", 1) + b"\x02"
    tags += b"ENDT"
    entries += struct.pack("<I", 4 + len(tags)) + tags
header = bytearray(0x58)
header[:4] = b"MTLB"
struct.pack_into("<QQ", header, 0x18, 0x58, len(entries))
body = struct.pack("<I", len(names)) + entries + b"ENDT"
struct.pack_into("<Q", header, 0x10, len(header) + len(body))
open(out, "wb").write(bytes(header) + body)
PY
}

all_names=()
while IFS= read -r name; do
  all_names+=("$name")
done < <(python3 -c '
import json, sys
for names in json.load(open(sys.argv[1]))["units"].values():
    for name in names:
        print(name)
' "$MANIFEST")
[ "${#all_names[@]}" -gt 0 ] || die "manifest lists no kernels"

# 1. list parses names exactly.
write_metallib "$WORKDIR/small.metallib" gather_mm_offsets rbits rbitsc
[ "$(python3 "$TOOL" list "$WORKDIR/small.metallib" | tr '\n' ' ')" = "gather_mm_offsets rbits rbitsc " ] ||
  die "list did not return the three fixture names"

# 2. a complete library passes; one missing gather_mm_offsets fails and names it.
write_metallib "$WORKDIR/complete.metallib" "${all_names[@]}" extra_kernel
python3 "$TOOL" check --manifest "$MANIFEST" "$WORKDIR/complete.metallib" >/dev/null ||
  die "complete library failed the check"
partial=()
for name in "${all_names[@]}"; do
  [ "$name" = gather_mm_offsets ] || partial+=("$name")
done
write_metallib "$WORKDIR/partial.metallib" "${partial[@]}"
if python3 "$TOOL" check --manifest "$MANIFEST" "$WORKDIR/complete.metallib" "$WORKDIR/partial.metallib" \
  2>"$WORKDIR/partial.err"; then
  die "library missing gather_mm_offsets passed the check"
fi
grep -q "partial.metallib: missing 1 kernel(s) from gather_mm_offsets.metal: gather_mm_offsets" "$WORKDIR/partial.err" ||
  die "check did not name the missing kernel"

# 3. malformed inputs fail closed.
printf 'fixture metal library\n' >"$WORKDIR/text.metallib"
if python3 "$TOOL" list "$WORKDIR/text.metallib" 2>/dev/null; then
  die "non-metallib input parsed"
fi
head -c 120 "$WORKDIR/complete.metallib" >"$WORKDIR/truncated.metallib"
if python3 "$TOOL" list "$WORKDIR/truncated.metallib" 2>/dev/null; then
  die "truncated metallib parsed"
fi

# 4. the derivation rule: JIT-mode units are build_kernel calls before
#    `if(NOT MLX_METAL_JIT)`.
fake="$WORKDIR/mlx-swift"
mkdir -p "$fake/Source/Cmlx/mlx/mlx/backend/metal/kernels"
cat >"$fake/Source/Cmlx/mlx/mlx/backend/metal/kernels/CMakeLists.txt" <<'CMAKE'
function(build_kernel KERNEL)
endfunction(build_kernel)
build_kernel(arg_reduce)
build_kernel(gather_mm_offsets)
build_kernel(scaled_dot_product_attention sdpa_vector.h)
if(MLX_METAL_VERSION GREATER_EQUAL 320)
  build_kernel(fence)
endif()
if(NOT MLX_METAL_JIT)
  build_kernel(binary binary.h)
endif()
CMAKE
units="$(python3 -c '
import importlib.util, sys
spec = importlib.util.spec_from_file_location("k", sys.argv[1])
k = importlib.util.module_from_spec(spec); spec.loader.exec_module(k)
from pathlib import Path
print(" ".join(k.required_units(Path(sys.argv[2]), int(sys.argv[3]))))
' "$TOOL" "$fake" 320)"
[ "$units" = "arg_reduce fence gather_mm_offsets scaled_dot_product_attention" ] ||
  die "unexpected JIT-mode units at Metal 3.2: $units"
units="$(python3 -c '
import importlib.util, sys
spec = importlib.util.spec_from_file_location("k", sys.argv[1])
k = importlib.util.module_from_spec(spec); spec.loader.exec_module(k)
from pathlib import Path
print(" ".join(k.required_units(Path(sys.argv[2]), int(sys.argv[3]))))
' "$TOOL" "$fake" 310)"
[ "$units" = "arg_reduce gather_mm_offsets scaled_dot_product_attention" ] ||
  die "a Metal 3.2 guard was not honored for a Metal 3.1 target: $units"

# 5. the committed manifest is derived from the pinned mlx-swift revision.
pinned="$(python3 -c '
import json, sys
pins = json.load(open(sys.argv[1]))["pins"]
print(next(p["state"]["revision"] for p in pins if p["identity"] == "mlx-swift"))
' "$REPO_ROOT/phase3-binary/Package.resolved")"
manifest_rev="$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["mlx_swift_revision"])' "$MANIFEST")"
[ "$pinned" = "$manifest_rev" ] ||
  die "mlx-metallib-required-kernels.json was derived from mlx-swift $manifest_rev but Package.resolved pins $pinned; regenerate it with scripts/mlx-metallib-kernels.py derive"
python3 -c 'import json,sys; sys.exit(0 if "gather_mm_offsets" in json.load(open(sys.argv[1]))["units"].get("gather_mm_offsets", []) else 1)' "$MANIFEST" ||
  die "manifest lacks the gather_mm_offsets unit"

# 6. release wiring: package.sh compiles the full library and gates both copies;
#    it never ships the SwiftPM default.metallib as mlx.metallib again.
PACKAGE="$REPO_ROOT/phase3-binary/dist/package.sh"
if grep -q 'cp "$PRODUCTS/mlx-swift_Cmlx.bundle/Contents/Resources/default.metallib" "$PRODUCTS/mlx.metallib"' "$PACKAGE"; then
  die "package.sh still copies the SwiftPM default.metallib into mlx.metallib"
fi
grep -q 'MLX_SWIFT_CHECKOUT="$MLX_SWIFT_RESOLVED_CHECKOUT"' "$PACKAGE" || die "package.sh does not build from the resolved checkout"
grep -q 'cp "$PRODUCTS/mlx.metallib" "$MLX_BUNDLE_METALLIB"' "$PACKAGE" || die "package.sh does not complete the bundle default.metallib"
grep -q 'mlx-metallib-kernels.py" derive' "$PACKAGE" || die "package.sh does not re-derive the required kernels"
grep -q 'mlx-metallib-kernels.py" check' "$PACKAGE" || die "package.sh does not gate the shipped metallibs"
VERIFY="$REPO_ROOT/scripts/verify-tier2-provider-release.sh"
for label in '"provider tarball"' '"provider package payload"' '"Malibu.app"'; do
  grep -q "verify_mlx_kernels $label" "$VERIFY" || die "verify-tier2-provider-release.sh does not gate the $label metallibs"
done
# The builder compiles every unit the manifest requires (it lists sources by hand).
BUILDER="$REPO_ROOT/phase3-binary/scripts/build-mlx-metallib.sh"
for unit in $(python3 -c 'import json,sys; print(" ".join(json.load(open(sys.argv[1]))["units"]))' "$MANIFEST"); do
  grep -qx -e "  $unit" -e "  kernels+=($unit)" "$BUILDER" || die "build-mlx-metallib.sh does not compile required unit $unit"
done
grep -q 'export MACOSX_DEPLOYMENT_TARGET="${MACOSX_DEPLOYMENT_TARGET:-14.0}"' "$PACKAGE" ||
  die "package.sh does not build the kernels for the package's minimum macOS"
grep -q '^        .macOS(.v14)$' "$REPO_ROOT/phase3-binary/Package.swift" ||
  die "Package.swift minimum macOS changed; update package.sh MACOSX_DEPLOYMENT_TARGET and regenerate the manifest"

# 7. header size, section bounds, and an unparsed build_kernel call fail closed.
cp "$WORKDIR/small.metallib" "$WORKDIR/padded.metallib"
printf 'x' >>"$WORKDIR/padded.metallib"
if python3 "$TOOL" list "$WORKDIR/padded.metallib" 2>/dev/null; then
  die "metallib with a wrong header size parsed"
fi
printf 'build_kernel(arg_reduce)\nbuild_kernel(${UNIT_FROM_A_VARIABLE})\nif(NOT MLX_METAL_JIT)\nendif()\n' >"$fake/Source/Cmlx/mlx/mlx/backend/metal/kernels/CMakeLists.txt"
if python3 -c '
import importlib.util, sys
from pathlib import Path
spec = importlib.util.spec_from_file_location("k", sys.argv[1])
k = importlib.util.module_from_spec(spec); spec.loader.exec_module(k)
k.required_units(Path(sys.argv[2]), 400)
' "$TOOL" "$fake" 2>/dev/null; then
  die "an unparsed build_kernel call did not fail the derivation"
fi

log "PASS"
