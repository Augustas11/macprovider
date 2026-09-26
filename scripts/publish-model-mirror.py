#!/usr/bin/env python3
"""Lay out one signed catalog snapshot for a content-addressed weight mirror.

Issue #1737, SPEC-023-R019. Provider Macs that cannot reach huggingface.co
fetch catalog bytes from `https://models.malibu.tech` (or an operator mirror)
in this layout:

    <out>/<model_sha256>/manifest            exact snapshot-manifest.v1 bytes
    <out>/<model_sha256>/files/<rel path>    each snapshot file

The manifest is the concatenation of "<path>\\n<size>\\n<sha256>\\n" for every
regular file, sorted by relative path; its SHA-256 is the signed row's
`model_sha256` (`ModelArtifactVerifier.inspectCanonicalArtifact`). This script
refuses to write anything unless the snapshot reproduces that signed hash, so
a mirror can only ever hold bytes the catalog already signed.

Input is a snapshot directory, for example `hf download <repo> --revision
<rev> --local-dir <dir>` or a Hugging Face cache `snapshots/<rev>` directory.
Symlinks are followed; `.DS_Store`, `._*`, and a `hf download` `.cache/`
directory are skipped. Upload `<out>/<model_sha256>/` as-is.

Exit 0 on success, 1 when the snapshot does not match the signed hash, 2 on
usage or input errors.
"""

from __future__ import annotations

import argparse
import hashlib
import json
import os
import shutil
import sys
import tempfile
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parents[1]
DEFAULT_CATALOG = REPO_ROOT / "phase3-binary/dist/static/autotune-candidates.json"
CHUNK = 4 * 1024 * 1024


def is_platform_metadata(name: str) -> bool:
    return name == ".DS_Store" or name.startswith("._")


def find_row(catalog: dict, key: str) -> tuple[str, dict]:
    rows = catalog.get("rows") or {}
    lowered = key.lower()
    for catalog_key, row in rows.items():
        if catalog_key.lower() == lowered or str(row.get("model_id", "")).lower() == lowered:
            return catalog_key, row
    raise KeyError(key)


def file_digest(path: Path) -> tuple[int, str]:
    digest = hashlib.sha256()
    size = 0
    with path.open("rb") as handle:
        while True:
            chunk = handle.read(CHUNK)
            if not chunk:
                break
            digest.update(chunk)
            size += len(chunk)
    return size, digest.hexdigest()


def snapshot_entries(snapshot: Path) -> list[tuple[str, int, str, Path]]:
    entries = []
    for current, dirs, files in os.walk(snapshot, followlinks=False):
        base = Path(current)
        rel_dir = base.relative_to(snapshot)
        dirs[:] = sorted(
            d for d in dirs
            if not is_platform_metadata(d) and not (rel_dir == Path(".") and d == ".cache")
        )
        for directory in dirs:
            if (base / directory).is_symlink():
                raise ValueError(f"directory symlink {(rel_dir / directory).as_posix()}")
        for name in files:
            if is_platform_metadata(name):
                continue
            source = base / name
            rel = (rel_dir / name).as_posix()
            if any(ord(ch) < 0x20 or ord(ch) == 0x7F for ch in rel) or ".." in rel.split("/"):
                raise ValueError(f"unsafe path {rel!r}")
            if not source.resolve().is_file():
                raise ValueError(f"not a regular file {rel}")
            size, sha = file_digest(source)
            entries.append((rel, size, sha, source))
    # Swift String `<` and Python str ordering agree for these paths; the
    # hash check below proves it for every published snapshot.
    entries.sort(key=lambda entry: entry[0])
    return entries


def manifest_bytes(entries: list[tuple[str, int, str, Path]]) -> bytes:
    return "".join(f"{rel}\n{size}\n{sha}\n" for rel, size, sha, _ in entries).encode("utf-8")


def publish(snapshot: Path, expected_sha256: str, out: Path) -> Path:
    entries = snapshot_entries(snapshot)
    if not entries:
        raise ValueError("snapshot has no files")
    manifest = manifest_bytes(entries)
    actual = hashlib.sha256(manifest).hexdigest()
    if actual != expected_sha256:
        raise MismatchError(expected_sha256, actual)
    out.mkdir(parents=True, exist_ok=True)
    final = out / expected_sha256
    staging = Path(tempfile.mkdtemp(prefix=f".{expected_sha256}.", dir=out))
    try:
        for rel, _, sha, source in entries:
            destination = staging / "files" / rel
            destination.parent.mkdir(parents=True, exist_ok=True)
            shutil.copyfile(source, destination)
            if file_digest(destination)[1] != sha:
                raise ValueError(f"file changed while copying {rel}")
        (staging / "manifest").write_bytes(manifest)
        if final.exists():
            shutil.rmtree(final)
        staging.rename(final)
    except BaseException:
        shutil.rmtree(staging, ignore_errors=True)
        raise
    return final


class MismatchError(Exception):
    def __init__(self, expected: str, actual: str) -> None:
        super().__init__(f"snapshot does not match the signed hash expected={expected} actual={actual}")
        self.expected = expected
        self.actual = actual


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--model", required=True, help="catalog key or model id, e.g. qwen3-8b")
    parser.add_argument("--snapshot", required=True, type=Path, help="snapshot directory")
    parser.add_argument("--out", required=True, type=Path, help="mirror root to write into")
    parser.add_argument("--catalog", type=Path, default=DEFAULT_CATALOG, help="signed candidate catalog JSON")
    args = parser.parse_args(argv)

    try:
        catalog = json.loads(args.catalog.read_text())
        catalog_key, row = find_row(catalog, args.model)
    except KeyError:
        print(f"publish-model-mirror: {args.model} is not a row of {args.catalog}", file=sys.stderr)
        return 2
    except (OSError, ValueError) as error:
        print(f"publish-model-mirror: cannot read catalog: {error}", file=sys.stderr)
        return 2
    expected = row.get("model_sha256")
    if not isinstance(expected, str) or len(expected) != 64:
        print(f"publish-model-mirror: {catalog_key} has no signed model_sha256", file=sys.stderr)
        return 2
    if not args.snapshot.is_dir():
        print(f"publish-model-mirror: {args.snapshot} is not a directory", file=sys.stderr)
        return 2
    try:
        final = publish(args.snapshot.resolve(), expected, args.out)
    except MismatchError as error:
        print(f"publish-model-mirror: {catalog_key}: {error}", file=sys.stderr)
        return 1
    except (OSError, ValueError) as error:
        print(f"publish-model-mirror: {error}", file=sys.stderr)
        return 2
    print(
        f"{catalog_key} {row.get('model_id')}@{row.get('model_revision')} "
        f"model_sha256={expected} -> {final}"
    )
    return 0


if __name__ == "__main__":
    sys.exit(main())
