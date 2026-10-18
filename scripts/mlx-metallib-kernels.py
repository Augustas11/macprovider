#!/usr/bin/env python3
"""Prove which Metal kernels a shipped MLX metallib contains.

The MLX core loads some kernels by name from the library next to the binary
(`mlx.metallib`) or from the SwiftPM bundle (`default.metallib`). A library
that lacks one of them crash-loops the provider with
`[metal::Device] Unable to load kernel <name>` the first time a model reaches
that path (CLI 1.8.254 candidate: `gather_mm_offsets`, MoE matmuls).

Subcommands:

  list METALLIB
      Parse the metallib function list (the MTLB container's NAME tags) and
      print every function name. No Metal device or toolchain needed.

  derive --mlx-swift-checkout DIR [--output FILE] [--expect FILE]
      Derive the required kernels from the pinned mlx-swift checkout: every
      kernel source the MLX core's kernels/CMakeLists.txt builds outside the
      `if(NOT MLX_METAL_JIT)` block (mlx-swift builds the core in JIT mode, so
      these are exactly the kernels it never JIT-compiles and must find in the
      library). Each unit is compiled with the Metal toolchain and its function
      names are read back from the compiled library. With --expect, fail unless
      the derived manifest equals FILE.

  check --manifest FILE METALLIB [METALLIB...]
      Fail unless every metallib contains every function the manifest names.
"""

from __future__ import annotations

import argparse
import concurrent.futures
import json
import os
import re
import struct
import subprocess
import sys
import tempfile
from pathlib import Path

SCHEMA = "macprovider.mlx-metallib-required-kernels.v1"
KERNELS_REL = "Source/Cmlx/mlx/mlx/backend/metal/kernels"
MLX_ROOT_REL = "Source/Cmlx/mlx"
METAL_FLAGS = [
    "-x",
    "metal",
    "-Wall",
    "-Wextra",
    "-fno-fast-math",
    "-Wno-c++17-extensions",
    "-Wno-c++20-extensions",
]


class MetallibError(Exception):
    pass


def metallib_function_names(path: Path) -> list[str]:
    data = path.read_bytes()
    if len(data) < 0x28 or data[:4] != b"MTLB":
        raise MetallibError(f"{path}: not a metallib (missing MTLB header)")
    list_offset, list_size = struct.unpack_from("<QQ", data, 0x18)
    # The size field counts the entries after the leading u32 count.
    end = list_offset + 4 + list_size
    if list_offset < 0x28 or end > len(data):
        raise MetallibError(f"{path}: function list out of bounds")
    (count,) = struct.unpack_from("<I", data, list_offset)
    pos = list_offset + 4
    names: list[str] = []
    for index in range(count):
        if pos + 4 > end:
            raise MetallibError(f"{path}: function {index} header out of bounds")
        (entry_size,) = struct.unpack_from("<I", data, pos)
        entry_end = pos + entry_size
        if entry_size < 8 or entry_end > end:
            raise MetallibError(f"{path}: function {index} size out of bounds")
        tag_pos = pos + 4
        name = None
        while True:
            if tag_pos + 4 > entry_end:
                raise MetallibError(f"{path}: function {index} has no ENDT tag")
            tag = data[tag_pos : tag_pos + 4]
            if tag == b"ENDT":
                break
            if tag_pos + 6 > entry_end:
                raise MetallibError(f"{path}: function {index} tag out of bounds")
            (tag_len,) = struct.unpack_from("<H", data, tag_pos + 4)
            value = data[tag_pos + 6 : tag_pos + 6 + tag_len]
            if tag_pos + 6 + tag_len > entry_end:
                raise MetallibError(f"{path}: function {index} tag value out of bounds")
            if tag == b"NAME":
                name = value.split(b"\0", 1)[0].decode("utf-8")
            tag_pos += 6 + tag_len
        if not name:
            raise MetallibError(f"{path}: function {index} has no NAME tag")
        names.append(name)
        pos = entry_end
    if not names:
        raise MetallibError(f"{path}: metallib lists no functions")
    return names


def required_units(checkout: Path) -> list[str]:
    cmake = checkout / KERNELS_REL / "CMakeLists.txt"
    if not cmake.is_file():
        raise MetallibError(f"missing MLX kernel CMakeLists: {cmake}")
    text = cmake.read_text(encoding="utf-8")
    marker = text.find("if(NOT MLX_METAL_JIT)")
    if marker < 0:
        raise MetallibError(f"{cmake}: no `if(NOT MLX_METAL_JIT)` block; derivation rule no longer matches")
    units = re.findall(r"^\s*build_kernel\(\s*([A-Za-z0-9_/]+)", text[:marker], re.MULTILINE)
    if not units:
        raise MetallibError(f"{cmake}: no JIT-mode build_kernel units found")
    return sorted(set(units))


def git_head(path: Path) -> str:
    try:
        return subprocess.run(
            ["git", "-C", str(path), "rev-parse", "HEAD"],
            check=True,
            capture_output=True,
            text=True,
        ).stdout.strip()
    except (OSError, subprocess.CalledProcessError):
        return "unknown"


def compile_unit(checkout: Path, unit: str, workdir: Path) -> list[str]:
    src = checkout / KERNELS_REL / f"{unit}.metal"
    if not src.is_file():
        raise MetallibError(f"missing kernel source: {src}")
    stem = unit.replace("/", "_")
    air = workdir / f"{stem}.air"
    lib = workdir / f"{stem}.metallib"
    flags = list(METAL_FLAGS)
    target = os.environ.get("MACOSX_DEPLOYMENT_TARGET")
    if target:
        flags.append(f"-mmacosx-version-min={target}")
    subprocess.run(
        ["xcrun", "-sdk", "macosx", "metal", *flags, "-c", str(src), f"-I{checkout / MLX_ROOT_REL}", "-o", str(air)],
        check=True,
    )
    subprocess.run(["xcrun", "-sdk", "macosx", "metallib", str(air), "-o", str(lib)], check=True)
    return sorted(set(metallib_function_names(lib)))


def derive(checkout: Path) -> dict:
    units = required_units(checkout)
    with tempfile.TemporaryDirectory(prefix="mlx-required-kernels.") as tmp:
        workdir = Path(tmp)
        with concurrent.futures.ThreadPoolExecutor(max_workers=os.cpu_count() or 4) as pool:
            futures = {unit: pool.submit(compile_unit, checkout, unit, workdir) for unit in units}
            names = {unit: futures[unit].result() for unit in units}
    return {
        "schema": SCHEMA,
        "mlx_swift_revision": git_head(checkout),
        "mlx_core_commit": git_head(checkout / MLX_ROOT_REL),
        "units": names,
    }


def load_manifest(path: Path) -> dict:
    manifest = json.loads(path.read_text(encoding="utf-8"))
    if manifest.get("schema") != SCHEMA:
        raise MetallibError(f"{path}: unexpected schema {manifest.get('schema')!r}")
    units = manifest.get("units")
    if not isinstance(units, dict) or not units:
        raise MetallibError(f"{path}: manifest names no kernel units")
    for unit, names in units.items():
        if not isinstance(names, list) or not names or not all(isinstance(n, str) and n for n in names):
            raise MetallibError(f"{path}: unit {unit!r} lists no function names")
    return manifest


def check(manifest_path: Path, metallibs: list[Path]) -> int:
    manifest = load_manifest(manifest_path)
    failed = False
    for lib in metallibs:
        present = set(metallib_function_names(lib))
        missing = {
            unit: [n for n in names if n not in present]
            for unit, names in sorted(manifest["units"].items())
        }
        missing = {unit: names for unit, names in missing.items() if names}
        if missing:
            failed = True
            for unit, names in missing.items():
                shown = ", ".join(names[:5]) + (f" (+{len(names) - 5} more)" if len(names) > 5 else "")
                print(f"mlx-metallib-kernels: {lib}: missing {len(names)} kernel(s) from {unit}.metal: {shown}", file=sys.stderr)
        else:
            total = sum(len(v) for v in manifest["units"].values())
            print(
                f"mlx-metallib-kernels: {lib}: all {total} required kernels from "
                f"{len(manifest['units'])} units present (mlx core {manifest.get('mlx_core_commit', 'unknown')})"
            )
    return 1 if failed else 0


def main(argv: list[str]) -> int:
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    sub = parser.add_subparsers(dest="command", required=True)
    p_list = sub.add_parser("list")
    p_list.add_argument("metallib", type=Path)
    p_derive = sub.add_parser("derive")
    p_derive.add_argument("--mlx-swift-checkout", type=Path, required=True)
    p_derive.add_argument("--output", type=Path)
    p_derive.add_argument("--expect", type=Path)
    p_check = sub.add_parser("check")
    p_check.add_argument("--manifest", type=Path, required=True)
    p_check.add_argument("metallibs", type=Path, nargs="+")
    args = parser.parse_args(argv)
    try:
        if args.command == "list":
            for name in metallib_function_names(args.metallib):
                print(name)
            return 0
        if args.command == "derive":
            manifest = derive(args.mlx_swift_checkout)
            rendered = json.dumps(manifest, indent=2, sort_keys=True) + "\n"
            if args.output:
                args.output.write_text(rendered, encoding="utf-8")
            elif not args.expect:
                sys.stdout.write(rendered)
            if args.expect:
                expected = load_manifest(args.expect)
                if expected != manifest:
                    print(
                        f"mlx-metallib-kernels: {args.expect} does not match the kernels derived from "
                        f"{args.mlx_swift_checkout} (mlx-swift {manifest['mlx_swift_revision']}, "
                        f"mlx core {manifest['mlx_core_commit']}); regenerate it with "
                        "`python3 scripts/mlx-metallib-kernels.py derive --mlx-swift-checkout <checkout> --output "
                        f"{args.expect}`",
                        file=sys.stderr,
                    )
                    return 1
                print(f"mlx-metallib-kernels: {args.expect} matches the pinned checkout")
            return 0
        return check(args.manifest, args.metallibs)
    except (MetallibError, OSError, ValueError, subprocess.CalledProcessError) as exc:
        print(f"mlx-metallib-kernels: ERROR: {exc}", file=sys.stderr)
        return 1


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
