#!/usr/bin/env python3
"""Select the freshness-only renewal base, ceiling, and next sequence.

Inputs:
  RELEASES_JSON  a `gh api --paginate --slurp releases?per_page=100` array of
                 pages (list of lists of release objects).
  TAGS_FILE      `git ls-remote --tags origin 'release-discovery-v1-*'` output,
                 one "<sha>\trefs/tags/<name>" line per ref (may be empty).

Prints "<ceiling> <base_tag> <renewal_sequence>" where:
  - base_tag is the highest PUBLIC IMMUTABLE prerelease transport (carrying the
    three discovery assets) to renew FROM;
  - ceiling is the highest release-discovery-v1-<n> sequence across BOTH
    published releases (public OR leftover draft) AND git tag refs (which can
    exist without a release after an interrupted publish);
  - renewal_sequence is ceiling + 1, bounded by uint64.

Fails closed (exit 1) unless the ceiling equals the public head. A higher
ceiling means a higher-sequence draft, orphan tag, or in-flight rollout is
pending; minting the older base above it could dominate a newer target's
transport in the client's greatest-sequence selection, so the operator (backed
by the freshness alarm) must resolve it before a renewal proceeds.
"""

from __future__ import annotations

import json
import pathlib
import re
import sys


UINT64_MAX = (1 << 64) - 1
TRANSPORT_RE = re.compile(r"release-discovery-v1-([1-9][0-9]*)")
TAG_REF_RE = re.compile(r"refs/tags/release-discovery-v1-([1-9][0-9]*)(?:\^\{\})?")
DISCOVERY_ASSETS = {
    "compatibility-artifact-index.json",
    "macprovider-release-discovery.json",
    "macprovider-release-discovery.json.sig",
}


def fail(message: str) -> "NoReturn":  # type: ignore[name-defined]
    print(f"select-discovery-renewal-base: {message}", file=sys.stderr)
    raise SystemExit(1)


def main(argv: list[str]) -> int:
    if len(argv) != 2:
        fail("usage: select-discovery-renewal-base.py RELEASES_JSON TAGS_FILE")
    releases_path, tags_path = argv
    try:
        pages = json.loads(pathlib.Path(releases_path).read_bytes().decode("utf-8"))
    except (OSError, UnicodeDecodeError, json.JSONDecodeError) as exc:
        fail(f"release listing is invalid: {exc}")
    if not isinstance(pages, list):
        fail("release listing must be an array of pages")

    all_sequences: list[int] = []
    public: list[tuple[int, str]] = []
    for page in pages:
        if not isinstance(page, list):
            continue
        for release in page:
            if not isinstance(release, dict):
                continue
            match = TRANSPORT_RE.fullmatch(str(release.get("tag_name", "")))
            if not match:
                continue
            sequence = int(match.group(1))
            all_sequences.append(sequence)
            names = {
                asset.get("name")
                for asset in release.get("assets", [])
                if isinstance(asset, dict)
            }
            if (
                release.get("draft") is False
                and release.get("prerelease") is True
                and release.get("immutable") is True
                and DISCOVERY_ASSETS <= names
            ):
                public.append((sequence, release.get("tag_name")))

    tags_file = pathlib.Path(tags_path)
    if tags_file.exists():
        for line in tags_file.read_text(encoding="utf-8").splitlines():
            fields = line.split()
            if len(fields) != 2:
                continue
            ref = TAG_REF_RE.fullmatch(fields[1])
            if ref:
                all_sequences.append(int(ref.group(1)))

    if not all_sequences:
        fail("no append-only discovery transport exists to renew from")
    if not public:
        fail("no public immutable discovery transport to renew from")

    ceiling = max(all_sequences)
    base_sequence, base_tag = max(public, key=lambda item: item[0])
    if ceiling != base_sequence:
        fail(
            "a higher-sequence discovery signal exists above the current public head "
            f"(ceiling={ceiling}, public_head={base_sequence}); resolve the pending "
            "rollout, leftover draft, or orphan tag before renewing so the renewal "
            "cannot dominate a newer target"
        )
    renewal_sequence = ceiling + 1
    if renewal_sequence > UINT64_MAX:
        fail("append-only discovery sequence space is exhausted")
    print(ceiling, base_tag, renewal_sequence)
    return 0


if __name__ == "__main__":
    raise SystemExit(main(sys.argv[1:]))
