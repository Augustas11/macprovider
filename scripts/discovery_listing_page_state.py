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


def main(argv: list[str]) -> int:
    if len(argv) != 1:
        print("usage: discovery_listing_page_state.py PAGE_JSON", file=sys.stderr)
        return 1
    path = pathlib.Path(argv[0])
    if path.stat().st_size > MAX_PAGE_BYTES:
        print("public discovery listing page is oversized", file=sys.stderr)
        return 1
    try:
        releases = json.loads(path.read_text(encoding="utf-8"))
    except (UnicodeDecodeError, json.JSONDecodeError):
        print("public discovery listing page is not JSON", file=sys.stderr)
        return 1
    if not isinstance(releases, list):
        print("public discovery listing page is not an array", file=sys.stderr)
        return 1
    if any(
        isinstance(release, dict)
        and TRANSPORT_TAG.fullmatch(str(release.get("tag_name", "")))
        for release in releases
    ):
        print("transport")
    elif len(releases) < PAGE_SIZE:
        print("end")
    else:
        print("next")
    return 0


if __name__ == "__main__":
    raise SystemExit(main(sys.argv[1:]))
