#!/usr/bin/env python3
"""Select the highest public append-only discovery transport from a GitHub listing.

Exit 0: the expected transport is the immutable public head.
Exit 2: the listing has not yet caught up; the caller should retry.
Exit 1: the listing shows a different or invalid head; fail closed.
"""

from __future__ import annotations

import json
import pathlib
import re
import sys


RETRY = 2
FAIL = 1


def fail(message: str, code: int = FAIL) -> int:
    print(message, file=sys.stderr)
    return code


def main(argv: list[str]) -> int:
    if len(argv) != 6:
        return fail(
            "usage: select_public_discovery_transport.py "
            "RELEASES_JSON EXPECTED_TRANSPORT COMMIT REPOSITORY RELEASE_OUT ASSETS_OUT"
        )
    releases_path, expected_transport, commit, repository, release_output, assets_output = argv
    expected_match = re.fullmatch(r"release-discovery-v1-([1-9][0-9]*)", expected_transport)
    if expected_match is None:
        return fail("invalid expected discovery transport tag")
    expected_sequence = int(expected_match.group(1))
    releases = json.loads(pathlib.Path(releases_path).read_text(encoding="utf-8"))
    if not isinstance(releases, list):
        return fail("public discovery listing is not an array")
    candidates = []
    expected_release = None
    for release in releases:
        if not isinstance(release, dict):
            continue
        tag_name = str(release.get("tag_name", ""))
        match = re.fullmatch(r"release-discovery-v1-([1-9][0-9]*)", tag_name)
        if match is None:
            continue
        sequence = int(match.group(1))
        candidates.append((sequence, release))
        if tag_name == expected_transport:
            expected_release = release
    if not candidates:
        return fail("public discovery listing has no append-only transport", RETRY)
    head_sequence, head = max(candidates, key=lambda item: item[0])
    if expected_release is None:
        if head_sequence < expected_sequence:
            return fail("highest public discovery transport is not the promoted target", RETRY)
        return fail("highest public discovery transport is not the promoted target")
    if head.get("tag_name") != expected_transport:
        return fail("highest public discovery transport is not the promoted target")
    if expected_release.get("draft") is not False:
        return fail("public discovery transport is not an immutable prerelease", RETRY)
    if (
        expected_release.get("target_commitish") != commit
        or expected_release.get("prerelease") is not True
        or expected_release.get("immutable") is not True
    ):
        return fail("public discovery transport is not an immutable prerelease")
    required = {
        "compatibility-artifact-index.json",
        "macprovider-release-discovery.json",
        "macprovider-release-discovery.json.sig",
    }
    rows = []
    for name in sorted(required):
        matches = [asset for asset in expected_release.get("assets", []) if asset.get("name") == name]
        if len(matches) != 1:
            return fail(f"public release does not contain exactly one {name}")
        url = matches[0].get("browser_download_url")
        expected_url = f"https://github.com/{repository}/releases/download/{expected_transport}/{name}"
        if url != expected_url:
            return fail(f"noncanonical public asset URL for {name}")
        rows.append(f"{name}\t{url}\n")
    pathlib.Path(release_output).write_text(json.dumps(expected_release), encoding="utf-8")
    pathlib.Path(assets_output).write_text("".join(rows), encoding="ascii")
    return 0


if __name__ == "__main__":
    raise SystemExit(main(sys.argv[1:]))
