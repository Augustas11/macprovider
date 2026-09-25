#!/usr/bin/env python3
"""Recompute each signed catalog row's canonical artifact hash from Hugging Face.

Issue #1735 step 5. For every row of the signed first-party candidate feed
(`phase3-binary/dist/static/autotune-candidates.json`), rebuild the
`macprovider.snapshot-manifest.v1` hash of `model_id@model_revision` from the
Hugging Face API alone and compare it with the row's signed `model_sha256`.

Algorithm (mirrors `ModelArtifactVerifier.inspectCanonicalArtifact` in
`phase3-binary/Sources/macprovider-cli/AutotuneRecommend.swift`): SHA-256 over
the concatenation of `"<path>\\n<size>\\n<sha256>\\n"` for every regular file,
sorted by relative path.

File set (mirrors `HuggingFaceSnapshotDownloader.downloadSnapshot`): every
`siblings[].rfilename` of `/api/models/<repo>/revision/<rev>`, `.gitattributes`
included. The manifest path is what `inspectCanonicalArtifact` reads back
after `downloadSnapshot` on case-insensitive APFS. Each component uses the
`URL.appendingPathComponent` form (Unicode NFD, except scalars Foundation
does not decompose). `createDirectory` keeps the first spelling of a
directory. `removeItem` then `moveItem` replaces the leaf, so the last
sibling's leaf spelling and bytes win. Names collide when their NFD casefold
is equal.
Per-file size and SHA-256 come from the recursive tree API at the pinned
revision: the LFS `oid` for LFS/Xet files, and a download-and-hash of the
resolved bytes for plain git files (cross-checked against the git blob SHA-1
the tree reports). Downloads use the raw Hub filename. The sibling set and
the tree's file set must match.

Read-only: no catalog write, no signing, no key material. Exit 0 when every row
matches, 1 on any mismatch, 3 when any row could not be recomputed (2 stays
argparse's usage error). 3 wins over 1: an incomplete sweep is never "clean
except for mismatches", so read the per-row status.
"""

from __future__ import annotations

import argparse
import hashlib
import json
import os
import re
import sys
import unicodedata
import urllib.error
import urllib.parse
import urllib.request
from dataclasses import dataclass, field
from pathlib import Path
from typing import Callable

REPO = Path(__file__).resolve().parents[1]
SIGNED_FEED = REPO / "phase3-binary" / "dist" / "static" / "autotune-candidates.json"
ARTIFACT_SOURCE = REPO / "phase3-binary" / "catalog" / "autotune" / "autotune-artifacts-source.json"
HF = "https://huggingface.co"
HEX40 = re.compile(r"^[0-9a-f]{40}$")
HEX64 = re.compile(r"^[0-9a-f]{64}$")
# Plain (non-LFS) git files are small; refuse anything that looks like a
# mis-tagged weight file instead of pulling gigabytes through this path.
MAX_PLAIN_FILE_BYTES = 64 * 1024 * 1024
MAX_RESPONSE_BYTES = MAX_PLAIN_FILE_BYTES
EXIT_MISMATCH = 1
EXIT_INCOMPLETE = 3

# (url, headers) -> (status, body, response headers with lower-case keys)
Fetch = Callable[[str, dict], "tuple[int, bytes, dict]"]


class SweepError(Exception):
    pass


@dataclass
class FileEntry:
    path: str
    size: int
    sha256: str


@dataclass
class RowResult:
    key: str
    repo_id: str
    revision: str
    signed_sha256: str
    source_sha256: str | None
    recomputed_sha256: str | None = None
    without_gitattributes_sha256: str | None = None
    file_count: int | None = None
    error: str | None = None
    notes: list[str] = field(default_factory=list)

    @property
    def status(self) -> str:
        if self.error is not None:
            return "ERROR"
        return "MATCH" if self.recomputed_sha256 == self.signed_sha256 else "MISMATCH"

    def to_json(self) -> dict:
        return {
            "key": self.key,
            "repo_id": self.repo_id,
            "revision": self.revision,
            "signed_sha256": self.signed_sha256,
            "source_sha256": self.source_sha256,
            "recomputed_sha256": self.recomputed_sha256,
            "without_gitattributes_sha256": self.without_gitattributes_sha256,
            "file_count": self.file_count,
            "status": self.status,
            "error": self.error,
            "notes": self.notes,
        }


def validate_relative_path(path: str) -> None:
    """Same rule as `ModelArtifactRelativePathPolicy.validate`."""
    if (
        not path
        or path.startswith("/")
        or ".." in path.split("/")
        or any(ord(ch) < 0x20 or ord(ch) == 0x7F for ch in path)
    ):
        raise SweepError(f"unsafe path {path!r}")


# Scalars whose `URL.appendingPathComponent` form is not Unicode NFD.
# Measured on Foundation, macOS 2026-09-25, by prefixing an ASCII base and
# comparing scalars. Combining marks are not in this set: a lone mark does
# not round-trip through a path, but `e` + U+0340 becomes `e` + U+0300.
# Inclusive ranges. Re-measure if Foundation's path normalization changes.
_APPLE_KEEP_RANGES: tuple[tuple[int, int], ...] = (
    (0x2000, 0x2001),
    (0x2126, 0x2126),
    (0x212A, 0x212B),
    (0x219A, 0x219B),
    (0x21AE, 0x21AE),
    (0x21CD, 0x21CF),
    (0x2204, 0x2204),
    (0x2209, 0x2209),
    (0x220C, 0x220C),
    (0x2224, 0x2224),
    (0x2226, 0x2226),
    (0x2241, 0x2241),
    (0x2244, 0x2244),
    (0x2247, 0x2247),
    (0x2249, 0x2249),
    (0x2260, 0x2260),
    (0x2262, 0x2262),
    (0x226D, 0x2271),
    (0x2274, 0x2275),
    (0x2278, 0x2279),
    (0x2280, 0x2281),
    (0x2284, 0x2285),
    (0x2288, 0x2289),
    (0x22AC, 0x22AF),
    (0x22E0, 0x22E3),
    (0x22EA, 0x22ED),
    (0x2329, 0x232A),
    (0x2ADC, 0x2ADC),
    (0xF900, 0xFA0D),
    (0xFA10, 0xFA10),
    (0xFA12, 0xFA12),
    (0xFA15, 0xFA1E),
    (0xFA20, 0xFA20),
    (0xFA22, 0xFA22),
    (0xFA25, 0xFA26),
    (0xFA2A, 0xFA6D),
    (0xFA70, 0xFAD9),
    (0x105C9, 0x105C9),
    (0x105E4, 0x105E4),
    (0x2F800, 0x2FA1D),
)


def _apple_keeps(code: int) -> bool:
    lo, hi = 0, len(_APPLE_KEEP_RANGES) - 1
    while lo <= hi:
        mid = (lo + hi) // 2
        start, end = _APPLE_KEEP_RANGES[mid]
        if code < start:
            hi = mid - 1
        elif code > end:
            lo = mid + 1
        else:
            return True
    return False


def _canonical_reorder(text: str) -> str:
    """Unicode canonical combining-class order. Starters stay put."""
    chars = list(text)
    out: list[str] = []
    index = 0
    count = len(chars)
    while index < count:
        if unicodedata.combining(chars[index]) == 0:
            out.append(chars[index])
            index += 1
            if index >= count:
                break
        end = index
        while end < count and unicodedata.combining(chars[end]) != 0:
            end += 1
        marks = chars[index:end]
        marks.sort(key=unicodedata.combining)
        out.extend(marks)
        index = end
    return "".join(out)


def _apple_nfd(component: str) -> str:
    parts: list[str] = []
    for char in component:
        if _apple_keeps(ord(char)):
            parts.append(char)
        else:
            parts.append(unicodedata.normalize("NFD", char))
    return _canonical_reorder("".join(parts))


def apple_relative_path(path: str) -> str:
    """One `appendingPathComponent` call: NFD each component, slashes stay.

    This is the URL form, not the path a later enumerator reads back when a
    parent directory was created under a different equivalent spelling.
    """
    return "/".join(_apple_nfd(part) for part in path.split("/"))


def _collision_key(component: str) -> str:
    """Identity of one APFS directory entry on a case-insensitive volume."""
    return unicodedata.normalize("NFD", component).casefold()


def apfs_manifest_names(siblings: list[str]) -> list[tuple[str, str]]:
    """Return `(stored path, winning raw name)` in first-seen file order.

    Directory components keep the spelling of the sibling that created them.
    The leaf keeps the last sibling's URL form. Collision is NFD plus
    casefold, measured against `removeItem` + `moveItem` on this Mac.
    """
    dir_spelling: dict[tuple[str, ...], str] = {}
    files: dict[tuple[str, ...], tuple[str, str]] = {}
    order: list[tuple[str, ...]] = []
    for raw in siblings:
        stored = apple_relative_path(raw)
        validate_relative_path(stored)
        parts = stored.split("/")
        if any(part in ("", ".") for part in parts):
            raise SweepError(f"path {raw!r} is not a git tree path")
        keys: list[str] = []
        built: list[str] = []
        for component in parts[:-1]:
            keys.append(_collision_key(component))
            prefix = tuple(keys)
            spelling = dir_spelling.get(prefix)
            if spelling is None:
                dir_spelling[prefix] = component
                spelling = component
            built.append(spelling)
        leaf_key = tuple(keys + [_collision_key(parts[-1])])
        full = "/".join(built + [parts[-1]])
        validate_relative_path(full)
        if leaf_key not in files:
            order.append(leaf_key)
        files[leaf_key] = (full, raw)
    return [files[key] for key in order]


def canonical_manifest_hash(entries: list[FileEntry]) -> str:
    seen: set[str] = set()
    for entry in entries:
        validate_relative_path(entry.path)
        if entry.path in seen:
            raise SweepError(f"duplicate path {entry.path!r}")
        seen.add(entry.path)
        if entry.size < 0 or not HEX64.fullmatch(entry.sha256):
            raise SweepError(f"bad size/sha256 for {entry.path!r}")
    # Code-point order of the stored paths. ASCII matches Swift `String.<`.
    # Swift's `<` follows the process locale for some diacritics (en_LT puts
    # A+diaeresis after README); the signed catalog rows are ASCII.
    manifest = "".join(
        f"{e.path}\n{e.size}\n{e.sha256}\n" for e in sorted(entries, key=lambda e: e.path)
    )
    return hashlib.sha256(manifest.encode("utf-8")).hexdigest()


def git_blob_sha1(data: bytes) -> str:
    return hashlib.sha1(b"blob %d\0" % len(data) + data).hexdigest()


def _read_bounded(response) -> bytes:
    body = response.read(MAX_RESPONSE_BYTES + 1)
    if len(body) > MAX_RESPONSE_BYTES:
        raise SweepError(f"response exceeds {MAX_RESPONSE_BYTES} bytes")
    return body


def default_fetch(url: str, headers: dict) -> tuple[int, bytes, dict]:
    headers = dict(headers)
    authorization = headers.pop("Authorization", None)
    request = urllib.request.Request(url, headers=headers)
    if authorization:
        # Unredirected: urllib would otherwise copy the token to whatever host
        # a redirect names (resolve redirects to the LFS/Xet CDN).
        request.add_unredirected_header("Authorization", authorization)
    try:
        with urllib.request.urlopen(request, timeout=60) as response:
            body = _read_bounded(response)
            return response.status, body, {k.lower(): v for k, v in response.headers.items()}
    except urllib.error.HTTPError as exc:
        return exc.code, b"", {k.lower(): v for k, v in exc.headers.items()}


def next_link(headers: dict) -> str | None:
    for part in headers.get("link", "").split(","):
        match = re.match(r'\s*<([^>]+)>\s*;\s*rel="?next"?', part)
        if match:
            return match.group(1)
    return None


class HuggingFaceClient:
    def __init__(self, fetch: Fetch = default_fetch, token: str | None = None) -> None:
        self.fetch = fetch
        self.headers = {"User-Agent": "macprovider-catalog-hash-sweep/1"}
        if token:
            self.headers["Authorization"] = f"Bearer {token}"

    def _get(self, url: str) -> tuple[bytes, dict]:
        status, body, headers = self.fetch(url, dict(self.headers))
        if not 200 <= status < 300:
            raise SweepError(f"HTTP {status} for {url}")
        return body, headers

    def _json(self, url: str, expected: type):
        body, headers = self._get(url)
        try:
            value = json.loads(body)
        except json.JSONDecodeError as exc:
            raise SweepError(f"invalid JSON from {url}: {exc}") from exc
        if not isinstance(value, expected):
            raise SweepError(f"unexpected JSON shape from {url}")
        return value, headers

    def siblings(self, repo_id: str, revision: str) -> list[str]:
        repo = urllib.parse.quote(repo_id, safe="/")
        info, _ = self._json(f"{HF}/api/models/{repo}/revision/{revision}?blobs=true", dict)
        if info.get("sha") != revision:
            raise SweepError(f"revision API resolved {info.get('sha')!r} not {revision}")
        siblings = info.get("siblings")
        if not isinstance(siblings, list) or not all(
            isinstance(s, dict) and isinstance(s.get("rfilename"), str) for s in siblings
        ):
            raise SweepError("revision API siblings are malformed")
        names = [s["rfilename"] for s in siblings]
        if not names:
            raise SweepError(f"empty snapshot {repo_id}@{revision}")
        return names

    def tree(self, repo_id: str, revision: str) -> list[dict]:
        repo = urllib.parse.quote(repo_id, safe="/")
        url: str | None = f"{HF}/api/models/{repo}/tree/{revision}?recursive=true"
        items: list[dict] = []
        pages = 0
        while url:
            pages += 1
            if pages > 100:
                raise SweepError("tree pagination did not terminate")
            page, headers = self._json(url, list)
            if not all(isinstance(item, dict) for item in page):
                raise SweepError("tree API entries are malformed")
            items.extend(page)
            url = next_link(headers)
            if url and urllib.parse.urlsplit(url)[:2] != ("https", "huggingface.co"):
                raise SweepError(f"tree pagination left huggingface.co: {url}")
        files = [item for item in items if item.get("type") == "file"]
        if not all(isinstance(item.get("path"), str) for item in files):
            raise SweepError("tree entry without a path")
        seen: set[str] = set()
        for item in files:
            path = item["path"]
            if path in seen:
                raise SweepError(f"duplicate tree path {path!r}")
            seen.add(path)
        return files

    def resolve(self, repo_id: str, revision: str, path: str) -> bytes:
        repo = urllib.parse.quote(repo_id, safe="/")
        body, _ = self._get(f"{HF}/{repo}/resolve/{revision}/{urllib.parse.quote(path)}")
        return body


def _file_entry(
    client: HuggingFaceClient,
    repo_id: str,
    revision: str,
    stored: str,
    raw: str,
    item: dict,
    notes: list[str],
) -> FileEntry:
    """One manifest line. `stored` is the enumerated path; `raw` is the Hub name."""
    size = item.get("size")
    # bool is an int subclass; f"{True}" is "True", not the byte count Swift prints.
    if type(size) is not int:
        raise SweepError(f"tree entry {raw!r} has no size")
    lfs = item.get("lfs")
    if lfs:
        if not isinstance(lfs, dict):
            raise SweepError(f"tree entry {raw!r} has a malformed LFS object")
        oid, lfs_size = lfs.get("oid"), lfs.get("size")
        if not isinstance(oid, str) or not HEX64.fullmatch(oid):
            raise SweepError(f"tree entry {raw!r} has no LFS sha256")
        if type(lfs_size) is not int or lfs_size != size:
            raise SweepError(f"tree entry {raw!r} size {size} != LFS size {lfs_size}")
        return FileEntry(stored, size, oid)
    if size > MAX_PLAIN_FILE_BYTES:
        raise SweepError(f"plain git file {raw!r} is {size} bytes; refusing download")
    data = client.resolve(repo_id, revision, raw)
    if len(data) != size:
        raise SweepError(f"{raw!r}: downloaded {len(data)} bytes, tree says {size}")
    blob_oid = item.get("oid")
    if isinstance(blob_oid, str) and HEX40.fullmatch(blob_oid):
        if git_blob_sha1(data) != blob_oid:
            raise SweepError(f"{raw!r}: git blob SHA-1 mismatch")
    else:
        notes.append(f"{raw}: no git blob oid to cross-check")
    return FileEntry(stored, size, hashlib.sha256(data).hexdigest())


def recompute(client: HuggingFaceClient, repo_id: str, revision: str) -> tuple[list[FileEntry], list[str]]:
    """Return the downloader's file set as manifest entries, plus notes."""
    notes: list[str] = []
    siblings = client.siblings(repo_id, revision)
    for name in siblings:
        validate_relative_path(name)
    tree = {item["path"]: item for item in client.tree(repo_id, revision)}
    sibling_set, tree_set = set(siblings), set(tree)
    if len(sibling_set) != len(siblings):
        raise SweepError("duplicate sibling filenames")
    if sibling_set != tree_set:
        raise SweepError(
            "sibling/tree file sets differ: only-siblings="
            f"{sorted(sibling_set - tree_set)} only-tree={sorted(tree_set - sibling_set)}"
        )
    entries: list[FileEntry] = []
    for stored, raw in apfs_manifest_names(siblings):
        entries.append(_file_entry(client, repo_id, revision, stored, raw, tree[raw], notes))
    return entries, notes


def load_rows(feed_path: Path, source_path: Path | None) -> list[RowResult]:
    feed = json.loads(feed_path.read_text())
    source_models = {}
    if source_path is not None and source_path.exists():
        source_models = json.loads(source_path.read_text()).get("models", {})
    rows = []
    for key, row in sorted(feed["rows"].items()):
        try:
            if not isinstance(row, dict):
                raise TypeError(f"row {key!r} is not an object")
            source_hash = None
            model = source_models.get(key)
            if model:
                source_hash = model["artifacts"][model["primary_artifact_id"]].get("hash")
            rows.append(
                RowResult(
                    key=key,
                    repo_id=row["model_id"],
                    revision=row["model_revision"],
                    signed_sha256=row["model_sha256"],
                    source_sha256=source_hash,
                )
            )
        except (KeyError, TypeError, IndexError) as exc:
            rows.append(
                RowResult(
                    key=str(key),
                    repo_id=row.get("model_id", "") if isinstance(row, dict) else "",
                    revision=row.get("model_revision", "") if isinstance(row, dict) else "",
                    signed_sha256=row.get("model_sha256", "") if isinstance(row, dict) else "",
                    source_sha256=None,
                    error=f"{type(exc).__name__}: {exc}",
                )
            )
    return rows


def sweep(rows: list[RowResult], client: HuggingFaceClient) -> list[RowResult]:
    for row in rows:
        if row.error is not None:
            continue
        try:
            if not HEX40.fullmatch(row.revision):
                raise SweepError(f"revision {row.revision!r} is not a pinned commit")
            entries, notes = recompute(client, row.repo_id, row.revision)
            row.notes.extend(notes)
            row.file_count = len(entries)
            row.recomputed_sha256 = canonical_manifest_hash(entries)
            without = [e for e in entries if e.path != ".gitattributes"]
            if len(without) != len(entries):
                row.without_gitattributes_sha256 = canonical_manifest_hash(without)
        except Exception as exc:  # noqa: BLE001 - one bad row must not hide the rest
            row.error = f"{type(exc).__name__}: {exc}"
    return rows


def short(value: str | None) -> str:
    return f"`{value[:12]}…`" if value else "—"


def render_markdown(rows: list[RowResult]) -> str:
    lines = [
        "| Row | Repo @ revision | Signed | Recomputed | Without `.gitattributes` | Files | Status |",
        "|---|---|---|---|---|---|---|",
    ]
    for r in rows:
        status = r.status if r.error is None else f"ERROR: {r.error}"
        lines.append(
            f"| `{r.key}` | `{r.repo_id}@{r.revision[:10]}` | {short(r.signed_sha256)} | "
            f"{short(r.recomputed_sha256)} | {short(r.without_gitattributes_sha256)} | "
            f"{r.file_count if r.file_count is not None else '—'} | {status} |"
        )
    return "\n".join(lines) + "\n"


def main(argv: list[str] | None = None, fetch: Fetch = default_fetch) -> int:
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("--feed", type=Path, default=SIGNED_FEED)
    parser.add_argument("--artifact-source", type=Path, default=ARTIFACT_SOURCE)
    parser.add_argument("--row", action="append", default=[], help="limit to this row key (repeatable)")
    parser.add_argument("--json-out", type=Path, help="write full per-row results as JSON")
    parser.add_argument("--markdown", action="store_true", help="print a markdown table")
    args = parser.parse_args(argv)

    rows = load_rows(args.feed, args.artifact_source)
    if args.row:
        unknown = set(args.row) - {r.key for r in rows}
        if unknown:
            parser.error(f"unknown row(s): {sorted(unknown)}")
        rows = [r for r in rows if r.key in set(args.row)]
    client = HuggingFaceClient(fetch=fetch, token=os.environ.get("HF_TOKEN") or None)
    sweep(rows, client)

    if args.json_out:
        args.json_out.write_text(json.dumps([r.to_json() for r in rows], indent=2, sort_keys=True) + "\n")
    if args.markdown:
        sys.stdout.write(render_markdown(rows))
    for r in rows:
        detail = r.error or f"signed={r.signed_sha256} recomputed={r.recomputed_sha256}"
        print(f"[catalog-hash-sweep] {r.status} {r.key} {r.repo_id}@{r.revision} {detail}", file=sys.stderr)
    if any(r.status == "ERROR" for r in rows):
        return EXIT_INCOMPLETE
    if any(r.status == "MISMATCH" for r in rows):
        return EXIT_MISMATCH
    return 0


if __name__ == "__main__":
    sys.exit(main())
