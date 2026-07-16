#!/usr/bin/env python3
"""Prepare or verify Malibu's one-time Sparkle trust-continuity anchor."""

from __future__ import annotations

import argparse
import base64
import binascii
import os
import pathlib
import plistlib
import re
import stat
import tempfile


BRIDGE_TAG = "v1.8.39"
BRIDGE_VERSION = "1.8.39"
BRIDGE_BUILD = "39"
EXPECTED_PUBLIC_KEY = "JkTDWnRJfOI3YIlpfJKvasWkxb0O1j/7ObGYiIA7big="
TAG_PATTERN = re.compile(r"^v[0-9]+\.[0-9]+\.[0-9]+$")


def fail(message: str) -> "NoReturn":
    raise SystemExit(f"malibu bootstrap trust anchor: {message}")


def require_regular_file(path: pathlib.Path, label: str) -> os.stat_result:
    try:
        metadata = path.lstat()
    except FileNotFoundError:
        fail(f"{label} is missing: {path}")
    if stat.S_ISLNK(metadata.st_mode) or not stat.S_ISREG(metadata.st_mode):
        fail(f"{label} must be a regular non-symlink file: {path}")
    return metadata


def require_directory(path: pathlib.Path, label: str) -> None:
    try:
        metadata = path.lstat()
    except FileNotFoundError:
        fail(f"{label} is missing: {path}")
    if stat.S_ISLNK(metadata.st_mode) or not stat.S_ISDIR(metadata.st_mode):
        fail(f"{label} must be a non-symlink directory: {path}")


def require_app(path: pathlib.Path) -> pathlib.Path:
    try:
        metadata = path.lstat()
    except FileNotFoundError:
        fail(f"Malibu.app is missing: {path}")
    if stat.S_ISLNK(metadata.st_mode) or not stat.S_ISDIR(metadata.st_mode):
        fail(f"Malibu.app must be a non-symlink directory: {path}")

    contents = path / "Contents"
    require_directory(contents, "Malibu.app Contents")
    require_directory(contents / "MacOS", "Malibu.app Contents/MacOS")
    require_directory(contents / "Resources", "Malibu.app Contents/Resources")

    sparkle_paths: list[str] = []
    symlink_paths: list[str] = []
    for root, directories, files in os.walk(contents, followlinks=False):
        for name in directories + files:
            candidate = pathlib.Path(root, name)
            relative = str(candidate.relative_to(path))
            if candidate.is_symlink():
                symlink_paths.append(relative)
            if "sparkle" in name.casefold():
                sparkle_paths.append(relative)
    if symlink_paths:
        fail("Malibu.app contains symlink paths: " + ", ".join(sorted(symlink_paths)))
    if sparkle_paths:
        fail("Malibu.app contains Sparkle runtime paths: " + ", ".join(sorted(sparkle_paths)))

    return contents


def load_frozen_key(path: pathlib.Path) -> str:
    require_regular_file(path, "frozen Sparkle public key")
    try:
        text = path.read_text(encoding="ascii")
    except (OSError, UnicodeError) as exc:
        fail(f"cannot read frozen Sparkle public key: {exc}")

    values = [
        line.strip()
        for line in text.splitlines()
        if line.strip() and not line.lstrip().startswith("#")
    ]
    if len(values) != 1:
        fail("frozen Sparkle public key must contain exactly one non-comment value")
    value = values[0]
    try:
        decoded = base64.b64decode(value, validate=True)
    except (binascii.Error, ValueError) as exc:
        fail(f"frozen Sparkle public key is not canonical base64: {exc}")
    if len(decoded) != 32 or base64.b64encode(decoded).decode("ascii") != value:
        fail("frozen Sparkle public key must be canonical base64 for exactly 32 bytes")
    if value != EXPECTED_PUBLIC_KEY:
        fail("frozen Sparkle public key differs from the Malibu v1.8.32 trust anchor")
    return value


def load_plist(path: pathlib.Path) -> tuple[dict[str, object], plistlib.PlistFormat, int]:
    metadata = require_regular_file(path, "Malibu Info.plist")
    try:
        raw = path.read_bytes()
        document = plistlib.loads(raw)
    except (OSError, plistlib.InvalidFileException, ValueError) as exc:
        fail(f"cannot parse Malibu Info.plist: {exc}")
    if not isinstance(document, dict):
        fail("Malibu Info.plist root must be a dictionary")
    plist_format = plistlib.FMT_BINARY if raw.startswith(b"bplist00") else plistlib.FMT_XML
    return document, plist_format, stat.S_IMODE(metadata.st_mode)


def validate_identity(document: dict[str, object], expected_tag: str | None) -> tuple[str, str]:
    identifier = document.get("CFBundleIdentifier")
    executable = document.get("CFBundleExecutable")
    version = document.get("CFBundleShortVersionString")
    build = document.get("CFBundleVersion")
    if identifier != "tech.malibu.app" or executable != "Malibu":
        fail("bundle identity is not the reviewed Malibu application")
    if not isinstance(version, str) or not re.fullmatch(r"[0-9]+\.[0-9]+\.[0-9]+", version):
        fail("CFBundleShortVersionString is not a semantic version")
    if not isinstance(build, str) or not re.fullmatch(r"[1-9][0-9]*", build):
        fail("CFBundleVersion is not a positive decimal build")
    if expected_tag is not None and expected_tag != f"v{version}":
        fail(f"bundle version {version} does not match release tag {expected_tag}")
    return version, build


def legacy_update_keys(document: dict[str, object]) -> list[str]:
    return sorted(key for key in document if isinstance(key, str) and key.startswith("SU"))


def atomic_write_plist(
    path: pathlib.Path,
    document: dict[str, object],
    plist_format: plistlib.PlistFormat,
    mode: int,
) -> None:
    descriptor, temporary_name = tempfile.mkstemp(prefix=".Info.plist.", dir=path.parent)
    temporary_path = pathlib.Path(temporary_name)
    try:
        os.fchmod(descriptor, mode)
        with os.fdopen(descriptor, "wb") as output:
            plistlib.dump(document, output, fmt=plist_format, sort_keys=False)
            output.flush()
            os.fsync(output.fileno())
        os.replace(temporary_path, path)
    except BaseException:
        try:
            os.close(descriptor)
        except OSError:
            pass
        temporary_path.unlink(missing_ok=True)
        raise


def prepare(tag: str, app: pathlib.Path, key_path: pathlib.Path) -> None:
    if TAG_PATTERN.fullmatch(tag) is None:
        fail("release tag must be vX.Y.Z")
    contents = require_app(app)
    key = load_frozen_key(key_path)
    info = contents / "Info.plist"
    document, plist_format, mode = load_plist(info)
    version, build = validate_identity(document, tag)
    found = legacy_update_keys(document)
    if found:
        fail("source Malibu app unexpectedly contains legacy update keys: " + ", ".join(found))

    if tag != BRIDGE_TAG:
        print(f"Malibu {tag} remains free of legacy app-update authority")
        return
    if version != BRIDGE_VERSION or build != BRIDGE_BUILD:
        fail(
            f"{BRIDGE_TAG} trust anchor requires bundle version/build "
            f"{BRIDGE_VERSION}/{BRIDGE_BUILD}, got {version}/{build}"
        )

    document["SUPublicEDKey"] = key
    atomic_write_plist(info, document, plist_format, mode)
    verify(app, key_path)
    print(f"injected frozen Malibu v1.8.32 trust anchor into {BRIDGE_TAG}")


def verify(app: pathlib.Path, key_path: pathlib.Path) -> None:
    contents = require_app(app)
    key = load_frozen_key(key_path)
    document, _, _ = load_plist(contents / "Info.plist")
    version, build = validate_identity(document, None)
    found = legacy_update_keys(document)

    if version == BRIDGE_VERSION:
        if build != BRIDGE_BUILD:
            fail(
                f"bundle version {BRIDGE_VERSION} must use bridge build {BRIDGE_BUILD}, "
                f"got {build}"
            )
        if found != ["SUPublicEDKey"] or document.get("SUPublicEDKey") != key:
            fail(
                f"Malibu {BRIDGE_VERSION} must contain only the exact frozen "
                "SUPublicEDKey trust anchor"
            )
        print(f"verified one-time Malibu {BRIDGE_VERSION} trust anchor")
        return

    if found:
        fail(
            f"Malibu {version} must not retain legacy app-update keys: "
            + ", ".join(found)
        )
    print(f"verified Malibu {version} has no legacy app-update keys")


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser()
    subparsers = parser.add_subparsers(dest="command", required=True)

    prepare_parser = subparsers.add_parser("prepare")
    prepare_parser.add_argument("tag")
    prepare_parser.add_argument("app", type=pathlib.Path)
    prepare_parser.add_argument("public_key", type=pathlib.Path)

    verify_parser = subparsers.add_parser("verify")
    verify_parser.add_argument("app", type=pathlib.Path)
    verify_parser.add_argument("public_key", type=pathlib.Path)
    return parser.parse_args()


def main() -> None:
    arguments = parse_args()
    if arguments.command == "prepare":
        prepare(arguments.tag, arguments.app, arguments.public_key)
    else:
        verify(arguments.app, arguments.public_key)


if __name__ == "__main__":
    main()
