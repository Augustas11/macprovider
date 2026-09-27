#!/usr/bin/env python3
"""Classify one public release-listing page the way the CLI walks it.

Mirrors SelfUpdate.releaseDiscoveryTransports (SPEC-020-R001): pages of
PAGE_SIZE releases, at most MAX_PAGES, each at most MAX_PAGE_BYTES, stopping
at the first page that holds a well-formed release-discovery-v1-<n> tag.

Prints exactly one word:
  transport  the page holds a transport; select from this page
  end        a short page without a transport; the listing ended
  next       a full page without a transport; fetch the next page
Exit 1 (nothing printed) on an oversized or malformed page.
`--max-pages` prints the page bound for the caller's walk.
`--highest-transport-tag PAGE_JSON` prints the highest client-visible tag.
"""

from __future__ import annotations

import json
import pathlib
import re
import sys

PAGE_SIZE = 100
MAX_PAGES = 10
MAX_PAGE_BYTES = 16 * 1024 * 1024
TRANSPORT_TAG = re.compile(r"release-discovery-v1-[1-9][0-9]*")
UINT64_MAX = 2**64 - 1


def transport_sequence(release: object) -> int | None:
    # Same grammar and UInt64 bound as SignedReleaseDiscoveryHead.transportSequence.
    if not isinstance(release, dict):
        return None
    tag = str(release.get("tag_name", ""))
    if not TRANSPORT_TAG.fullmatch(tag):
        return None
    sequence = int(tag.rsplit("-", 1)[1])
    return sequence if sequence <= UINT64_MAX else None


def load_releases(path: pathlib.Path) -> list[object]:
    if path.stat().st_size > MAX_PAGE_BYTES:
        raise ValueError("public discovery listing page is oversized")
    try:
        releases = json.loads(path.read_text(encoding="utf-8"))
    except (UnicodeDecodeError, json.JSONDecodeError) as error:
        raise ValueError("public discovery listing page is not JSON") from error
    if not isinstance(releases, list):
        raise ValueError("public discovery listing page is not an array")
    return releases


def main(argv: list[str]) -> int:
    if argv == ["--max-pages"]:
        print(MAX_PAGES)
        return 0
    highest_tag = len(argv) == 2 and argv[0] == "--highest-transport-tag"
    if len(argv) != 1 and not highest_tag:
        print(
            "usage: discovery_listing_page_state.py "
            "[--max-pages | --highest-transport-tag PAGE_JSON | PAGE_JSON]",
            file=sys.stderr,
        )
        return 1
    path = pathlib.Path(argv[1] if highest_tag else argv[0])
    try:
        releases = load_releases(path)
    except (OSError, ValueError) as error:
        print(error, file=sys.stderr)
        return 1
    candidates = [
        (sequence, str(release["tag_name"]))
        for release in releases
        if (sequence := transport_sequence(release)) is not None
    ]
    if highest_tag:
        if not candidates:
            print("public discovery listing page has no transport", file=sys.stderr)
            return 1
        print(max(candidates)[1])
    elif candidates:
        print("transport")
    elif len(releases) < PAGE_SIZE:
        print("end")
    else:
        print("next")
    return 0


if __name__ == "__main__":
    raise SystemExit(main(sys.argv[1:]))
