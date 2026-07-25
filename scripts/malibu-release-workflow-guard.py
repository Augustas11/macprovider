#!/usr/bin/env python3
"""Fail-closed guards for the protected, app-only Malibu release workflow."""

from __future__ import annotations

import argparse
import hashlib
import json
import pathlib
import re
import sys


PROVIDER_TAG = "v1.8.40"
PROVIDER_COMMIT = "18638472fe3e885f3534eeac29ab89b4c7ffdd7a"
PROVIDER_RELEASE_ID = 354899176
PROVIDER_ASSETS = {
    "macprovider-cli-v1.8.40-darwin-arm64.tar.gz": (
        478848746,
        "1eee4900109f958c95c66830f17295bfba4dfe93e0a72aa720f0ed20a9b2b918",
    ),
    "compatibility-set.json": (
        478848772,
        "fe17e7a3cca392edea185c304970ef6d6fb9f06ff65aa6cffed6c7d9325a161c",
    ),
    "checksums.txt": (
        478848792,
        "48c6c736a460d7f31e21c4ea0e779ce6cf1cf8542dd877c1df8ccaa14e33eaf1",
    ),
    "checksums.txt.sig": (
        478848796,
        "73719f4ccc28c3baf2a91f94461ce35f36ea27b79bbf68d32d0bf8bae901f207",
    ),
}
APP_TAG = re.compile(r"malibu-v[0-9]+\.[0-9]+\.[0-9]+")
COMMIT = re.compile(r"[0-9a-f]{40}")
HEX64 = re.compile(r"[0-9a-f]{64}")


def fail(message: str) -> None:
    raise SystemExit(f"malibu-release-workflow-guard: {message}")


def load_json(path: pathlib.Path, label: str) -> dict:
    if not path.is_file() or path.is_symlink():
        fail(f"{label} is not a regular file")
    try:
        value = json.loads(path.read_text(encoding="utf-8"))
    except (OSError, UnicodeDecodeError, json.JSONDecodeError) as error:
        fail(f"invalid {label}: {error}")
    if not isinstance(value, dict):
        fail(f"{label} must be an object")
    return value


def digest(path: pathlib.Path) -> str:
    if not path.is_file() or path.is_symlink():
        fail(f"asset is not a regular file: {path}")
    return hashlib.sha256(path.read_bytes()).hexdigest()


def api_assets(release: dict) -> dict[str, dict]:
    result: dict[str, dict] = {}
    rows = release.get("assets")
    if not isinstance(rows, list):
        fail("release assets are absent")
    for row in rows:
        if not isinstance(row, dict) or not isinstance(row.get("name"), str):
            fail("release contains an invalid asset row")
        name = row["name"]
        if name in result:
            fail(f"release contains duplicate asset {name}")
        result[name] = row
    return result


def require_release_identity(
    release: dict,
    *,
    tag: str,
    commit: str,
    draft: bool,
    release_id: int | None = None,
) -> int:
    if release.get("tag_name") != tag:
        fail("release tag differs from the reviewed tag")
    if release.get("target_commitish") != commit:
        fail("release target differs from the reviewed commit")
    if release.get("draft") is not draft:
        fail("release draft state differs from the expected state")
    if release.get("prerelease") is not False:
        fail("Malibu stable release unexpectedly reports prerelease")
    numeric_id = release.get("id")
    if type(numeric_id) is not int or numeric_id <= 0:
        fail("release numeric ID is invalid")
    if release_id is not None and numeric_id != release_id:
        fail("release numeric ID changed")
    if not draft and release.get("immutable") is not True:
        fail("published Malibu release is not immutable")
    if draft and release.get("immutable") is True:
        fail("draft Malibu release unexpectedly reports immutable")
    return numeric_id


def verify_latest(path: pathlib.Path) -> None:
    release = load_json(path, "generic latest release")
    require_release_identity(
        release,
        tag=PROVIDER_TAG,
        commit=PROVIDER_COMMIT,
        draft=False,
        release_id=PROVIDER_RELEASE_ID,
    )


def verify_provider(args: argparse.Namespace) -> None:
    release = load_json(args.release_json, "provider release")
    require_release_identity(
        release,
        tag=PROVIDER_TAG,
        commit=PROVIDER_COMMIT,
        draft=False,
        release_id=PROVIDER_RELEASE_ID,
    )
    assets = api_assets(release)
    captured: dict[str, dict[str, object]] = {}
    for name, (expected_id, expected_digest) in PROVIDER_ASSETS.items():
        row = assets.get(name)
        if row is None:
            fail(f"immutable provider release lacks {name}")
        if row.get("id") != expected_id:
            fail(f"immutable provider asset ID changed: {name}")
        if row.get("digest") != f"sha256:{expected_digest}":
            fail(f"immutable provider asset digest changed: {name}")
        local_digest = digest(args.assets_dir / name)
        if local_digest != expected_digest:
            fail(f"downloaded provider asset digest mismatch: {name}")
        captured[name] = {"id": expected_id, "sha256": expected_digest}
    output = {
        "schema_version": 1,
        "repository": "Augustas11/macprovider",
        "provider": {
            "commit": PROVIDER_COMMIT,
            "release_id": PROVIDER_RELEASE_ID,
            "tag": PROVIDER_TAG,
        },
        "assets": captured,
    }
    args.output.write_text(
        json.dumps(output, sort_keys=True, separators=(",", ":")) + "\n",
        encoding="utf-8",
    )


def verify_app(args: argparse.Namespace) -> None:
    if APP_TAG.fullmatch(args.tag) is None or COMMIT.fullmatch(args.commit) is None:
        fail("invalid app tag or commit")
    release = load_json(args.release_json, "Malibu release")
    release_id = require_release_identity(
        release,
        tag=args.tag,
        commit=args.commit,
        draft=args.draft,
        release_id=args.release_id,
    )
    expected_names = {
        line.strip()
        for line in args.asset_names.read_text(encoding="utf-8").splitlines()
        if line.strip()
    }
    if not expected_names:
        fail("expected Malibu asset list is empty")
    assets = api_assets(release)
    if set(assets) != expected_names:
        fail("numeric Malibu release asset set differs from local release set")
    captured: dict[str, dict[str, object]] = {}
    for name in sorted(expected_names):
        row = assets[name]
        asset_id = row.get("id")
        if type(asset_id) is not int or asset_id <= 0:
            fail(f"invalid numeric asset ID: {name}")
        local_digest = digest(args.assets_dir / name)
        if HEX64.fullmatch(local_digest) is None or row.get("digest") != f"sha256:{local_digest}":
            fail(f"GitHub asset digest mismatch: {name}")
        captured[name] = {"id": asset_id, "sha256": local_digest}
    provider = load_json(args.provider_provenance, "provider provenance")
    output = {
        "schema_version": 1,
        "repository": "Augustas11/macprovider",
        "malibu": {
            "commit": args.commit,
            "draft": args.draft,
            "release_id": release_id,
            "tag": args.tag,
        },
        "provider_provenance_sha256": hashlib.sha256(
            args.provider_provenance.read_bytes()
        ).hexdigest(),
        "provider": provider.get("provider"),
        "assets": captured,
    }
    args.output.write_text(
        json.dumps(output, sort_keys=True, separators=(",", ":")) + "\n",
        encoding="utf-8",
    )


def main() -> int:
    parser = argparse.ArgumentParser()
    commands = parser.add_subparsers(dest="command", required=True)

    latest = commands.add_parser("verify-latest")
    latest.add_argument("--release-json", required=True, type=pathlib.Path)

    provider = commands.add_parser("verify-provider")
    provider.add_argument("--release-json", required=True, type=pathlib.Path)
    provider.add_argument("--assets-dir", required=True, type=pathlib.Path)
    provider.add_argument("--output", required=True, type=pathlib.Path)

    app = commands.add_parser("verify-app-release")
    app.add_argument("--release-json", required=True, type=pathlib.Path)
    app.add_argument("--assets-dir", required=True, type=pathlib.Path)
    app.add_argument("--asset-names", required=True, type=pathlib.Path)
    app.add_argument("--provider-provenance", required=True, type=pathlib.Path)
    app.add_argument("--tag", required=True)
    app.add_argument("--commit", required=True)
    app.add_argument("--draft", action="store_true")
    app.add_argument("--release-id", type=int)
    app.add_argument("--output", required=True, type=pathlib.Path)

    args = parser.parse_args()
    if args.command == "verify-latest":
        verify_latest(args.release_json)
    elif args.command == "verify-provider":
        verify_provider(args)
    else:
        verify_app(args)
    return 0


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except BrokenPipeError:
        sys.exit(1)
