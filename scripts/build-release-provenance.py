#!/usr/bin/env python3
import hashlib
import json
import pathlib
import re
import sys


def fail(message: str) -> None:
    raise SystemExit(f"build-release-provenance: {message}")


if len(sys.argv) < 8:
    fail("usage: TAG COMMIT OWNER/REPO PRERELEASE TOOLCHAIN_JSON OUTPUT ASSET...")

tag, commit, repository, prerelease_raw, toolchain_name, output, *asset_names = sys.argv[1:]
if not re.fullmatch(r"v\d+\.\d+\.\d+", tag):
    fail("invalid tag")
if not re.fullmatch(r"[0-9a-f]{40}", commit):
    fail("invalid commit")
if not re.fullmatch(r"[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+", repository):
    fail("invalid repository")
if prerelease_raw not in {"true", "false"}:
    fail("invalid prerelease state")
if len(asset_names) != len(set(asset_names)):
    fail("duplicate asset path")

toolchain_path = pathlib.Path(toolchain_name)
if not toolchain_path.is_file() or toolchain_path.is_symlink():
    fail("toolchain record is not a regular file")
toolchain = json.loads(toolchain_path.read_text(encoding="utf-8"))
expected_toolchain = {
    "macos_sdk": {
        "path": "/Applications/Xcode_16.4.app/Contents/Developer/Platforms/MacOSX.platform/Developer/SDKs/MacOSX15.5.sdk",
        "version": "15.5",
    },
    "swift": {
        "driver_version": "1.120.5",
        "version": "Apple Swift version 6.1.2 (swiftlang-6.1.2.1.2 clang-1700.0.13.5)",
    },
    "xcode": {
        "build": "16F6",
        "developer_dir": "/Applications/Xcode_16.4.app/Contents/Developer",
        "version": "16.4",
    },
}
if toolchain != expected_toolchain:
    fail("toolchain record differs from the reviewed release toolchain")

assets: dict[str, str] = {}
for value in asset_names:
    path = pathlib.Path(value)
    if not path.is_file() or path.is_symlink():
        fail(f"asset is not a regular file: {path}")
    if path.name in assets:
        fail(f"duplicate asset name: {path.name}")
    assets[path.name] = hashlib.sha256(path.read_bytes()).hexdigest()

payload = {
    "schema_version": 1,
    "repository": repository,
    "tag": tag,
    "commit": commit,
    "prerelease": prerelease_raw == "true",
    "toolchain": toolchain,
    "assets": dict(sorted(assets.items())),
}
pathlib.Path(output).write_text(
    json.dumps(payload, sort_keys=True, separators=(",", ":")) + "\n",
    encoding="utf-8",
)
