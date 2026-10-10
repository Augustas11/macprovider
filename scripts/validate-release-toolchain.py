#!/usr/bin/env python3
import json
import pathlib
import sys


# Two reviewed profiles. "build" compiles the phase3-binary Swift package and
# Malibu.app (mlx-swift 0.32.3 declares swift-tools-version 6.3). "signer" is
# the protected macos-15-intel signer: it only codesigns/notarizes/staples and
# must stay on macOS 15 for the sealed OpenSSL sequoia bottle, which no Swift
# 6.3 Xcode ships for. It never compiles the package.
PROFILES = {
    "build": {
        "developer_dir": "/Applications/Xcode_26.6.app/Contents/Developer",
        "xcode_version": "26.6",
        "xcode_build": "17F113",
        "swift": "Apple Swift version 6.3.3 (swiftlang-6.3.3.1.3 clang-2100.1.1.101)",
        "swift_driver": "swift-driver version: 1.148.6",
        "sdk_version": "26.5",
    },
    "signer": {
        "developer_dir": "/Applications/Xcode_16.4.app/Contents/Developer",
        "xcode_version": "16.4",
        "xcode_build": "16F6",
        "swift": "Apple Swift version 6.1.2 (swiftlang-6.1.2.1.2 clang-1700.0.13.5)",
        "swift_driver": "swift-driver version: 1.120.5",
        "sdk_version": "15.5",
    },
}


def fail(message: str) -> None:
    raise SystemExit(f"validate-release-toolchain: {message}")


args = sys.argv[1:]
profile_name = "build"
if args[:1] == ["--signer"]:
    profile_name = "signer"
    args = args[1:]
if len(args) != 7:
    fail(
        "usage: [--signer] DEVELOPER_DIR XCODE_VERSION SWIFT_DRIVER_VERSION "
        "SWIFTC_VERSION SDK_VERSION SDK_PATH OUTPUT"
    )
profile = PROFILES[profile_name]
EXPECTED_DEVELOPER_DIR = profile["developer_dir"]
EXPECTED_XCODE = f"Xcode {profile['xcode_version']}\nBuild version {profile['xcode_build']}"
EXPECTED_SWIFT = profile["swift"]
EXPECTED_SWIFT_DRIVER = profile["swift_driver"]
EXPECTED_SDK_VERSION = profile["sdk_version"]
EXPECTED_SDK_PATH = (
    f"{EXPECTED_DEVELOPER_DIR}/Platforms/MacOSX.platform/Developer/SDKs/"
    f"MacOSX{EXPECTED_SDK_VERSION}.sdk"
)

(
    developer_dir,
    xcode_file,
    swift_driver_file,
    swiftc_file,
    sdk_version_file,
    sdk_path_file,
    output,
) = args
if developer_dir != EXPECTED_DEVELOPER_DIR:
    fail(f"Xcode developer directory drifted: {developer_dir}")

xcode = pathlib.Path(xcode_file).read_text(encoding="utf-8").strip()
if xcode != EXPECTED_XCODE:
    fail(f"Xcode version/build drifted: {xcode!r}")

swift_driver = pathlib.Path(swift_driver_file).read_text(encoding="utf-8").strip()
if swift_driver != EXPECTED_SWIFT_DRIVER:
    fail(f"Swift driver drifted: {swift_driver!r}")

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
        "driver_version": EXPECTED_SWIFT_DRIVER.removeprefix("swift-driver version: "),
        "version": EXPECTED_SWIFT,
    },
    "xcode": {
        "build": profile["xcode_build"],
        "developer_dir": developer_dir,
        "version": profile["xcode_version"],
    },
}
pathlib.Path(output).write_text(
    json.dumps(payload, sort_keys=True, separators=(",", ":")) + "\n",
    encoding="utf-8",
)
