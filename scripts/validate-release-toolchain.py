#!/usr/bin/env python3
import json
import pathlib
import sys


EXPECTED_DEVELOPER_DIR = "/Applications/Xcode_16.4.app/Contents/Developer"
EXPECTED_XCODE = "Xcode 16.4\nBuild version 16F6"
EXPECTED_SWIFT = (
    "swift-driver version: 1.120.5 Apple Swift version 6.1.2 "
    "(swiftlang-6.1.2.1.2 clang-1700.0.13.5)"
)
EXPECTED_SDK_VERSION = "15.5"
EXPECTED_SDK_PATH = (
    f"{EXPECTED_DEVELOPER_DIR}/Platforms/MacOSX.platform/Developer/SDKs/MacOSX15.5.sdk"
)


def fail(message: str) -> None:
    raise SystemExit(f"validate-release-toolchain: {message}")


if len(sys.argv) != 7:
    fail("usage: DEVELOPER_DIR XCODE_VERSION SWIFTC_VERSION SDK_VERSION SDK_PATH OUTPUT")

developer_dir, xcode_file, swiftc_file, sdk_version_file, sdk_path_file, output = sys.argv[1:]
if developer_dir != EXPECTED_DEVELOPER_DIR:
    fail(f"Xcode developer directory drifted: {developer_dir}")

xcode = pathlib.Path(xcode_file).read_text(encoding="utf-8").strip()
if xcode != EXPECTED_XCODE:
    fail(f"Xcode version/build drifted: {xcode!r}")

swiftc_lines = pathlib.Path(swiftc_file).read_text(encoding="utf-8").splitlines()
if not swiftc_lines or swiftc_lines[0] != EXPECTED_SWIFT:
    fail(f"Swift compiler drifted: {swiftc_lines[:1]!r}")

sdk_version = pathlib.Path(sdk_version_file).read_text(encoding="utf-8").strip()
if sdk_version != EXPECTED_SDK_VERSION:
    fail(f"macOS SDK version drifted: {sdk_version!r}")
sdk_path = pathlib.Path(sdk_path_file).read_text(encoding="utf-8").strip()
if sdk_path != EXPECTED_SDK_PATH:
    fail(f"macOS SDK path drifted: {sdk_path!r}")

payload = {
    "macos_sdk": {"path": sdk_path, "version": sdk_version},
    "swift": {
        "driver_version": "1.120.5",
        "version": EXPECTED_SWIFT.removeprefix("swift-driver version: 1.120.5 "),
    },
    "xcode": {
        "build": "16F6",
        "developer_dir": developer_dir,
        "version": "16.4",
    },
}
pathlib.Path(output).write_text(
    json.dumps(payload, sort_keys=True, separators=(",", ":")) + "\n",
    encoding="utf-8",
)
