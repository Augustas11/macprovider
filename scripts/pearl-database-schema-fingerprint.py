#!/usr/bin/env python3
"""Print the Pearl database schema fingerprint of one git commit.

The Pearl release updater skips its pre-cutover SQLite snapshot only when the
candidate's signed `database_schema_fingerprint` equals the one recorded for
the installed release. The coordinator has no single schema version: dozens of
packages run idempotent DDL and backfills at startup, and what the services
persist also depends on code that never mentions SQL. So the fingerprint is a
deliberate over-approximation: a sha256 over every tracked non-test file under
phase4-coordinator/ and phase5-gateway/ (Go source, embedded assets, .sql files,
go.mod, go.sum). Equal fingerprints mean the server, stats sidecar, and CLI
source are byte-identical, so the candidate cannot persist anything the
installed release would not. Any server source change makes the updater
snapshot as before. See ops/runbooks/pearl-release-updater.md (Database
snapshots).
"""

from __future__ import annotations

import argparse
import hashlib
import subprocess
import sys
from pathlib import PurePosixPath

FORMAT = b"macprovider.pearl-database-schema-fingerprint.v2\n"
MODULES = ("phase4-coordinator", "phase5-gateway")
MODULE_FILES = tuple(f"{module}/{name}" for module in MODULES for name in ("go.mod", "go.sum"))


def git(repo: str, *args: str, data: bytes | None = None) -> bytes:
    result = subprocess.run(
        ["git", "-C", repo, *args],
        input=data,
        capture_output=True,
        check=False,
    )
    if result.returncode != 0:
        raise SystemExit(f"git {' '.join(args)} failed: {result.stderr.decode(errors='replace').strip()}")
    return result.stdout


def tracked_blobs(repo: str, commit: str) -> dict[str, bytes]:
    listing = git(repo, "ls-tree", "-r", "-z", "--full-tree", commit, "--", *MODULES)
    entries: list[tuple[str, str]] = []
    for record in listing.split(b"\0"):
        if not record:
            continue
        meta, path = record.split(b"\t", 1)
        _mode, kind, oid = meta.split(b" ")
        if kind != b"blob":
            continue
        entries.append((path.decode("utf-8"), oid.decode("ascii")))
    if not entries:
        raise SystemExit(f"no tracked files under {', '.join(MODULES)} at {commit}")
    batch = git(repo, "cat-file", "--batch", data="".join(oid + "\n" for _, oid in entries).encode("ascii"))
    contents: dict[str, bytes] = {}
    offset = 0
    for path, oid in entries:
        newline = batch.index(b"\n", offset)
        header = batch[offset:newline].split(b" ")
        if len(header) != 3 or header[0].decode("ascii") != oid or header[1] != b"blob":
            raise SystemExit(f"unexpected git cat-file output for {path}")
        size = int(header[2])
        start = newline + 1
        contents[path] = batch[start : start + size]
        offset = start + size + 1
    return contents


def is_test_path(path: str) -> bool:
    return path.endswith("_test.go") or "testdata" in PurePosixPath(path).parts


def fingerprint_inputs(contents: dict[str, bytes]) -> list[str]:
    for required in MODULE_FILES:
        if required not in contents:
            raise SystemExit(f"required module file is missing: {required}")
    return sorted(path for path in contents if not is_test_path(path))


def fingerprint(contents: dict[str, bytes], paths: list[str]) -> str:
    digest = hashlib.sha256(FORMAT)
    for path in paths:
        digest.update(path.encode("utf-8") + b"\0" + hashlib.sha256(contents[path]).hexdigest().encode("ascii") + b"\n")
    return digest.hexdigest()


def main(argv: list[str]) -> int:
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("--repo", default=".", help="git checkout to read (default: .)")
    parser.add_argument("--commit", default="HEAD", help="commit to fingerprint (default: HEAD)")
    parser.add_argument("--explain", action="store_true", help="list the fingerprinted paths on stderr")
    args = parser.parse_args(argv)
    commit = git(args.repo, "rev-parse", "--verify", f"{args.commit}^{{commit}}").decode("ascii").strip()
    contents = tracked_blobs(args.repo, commit)
    paths = fingerprint_inputs(contents)
    if args.explain:
        for path in paths:
            print(path, file=sys.stderr)
    print(fingerprint(contents, paths))
    return 0


if __name__ == "__main__":
    raise SystemExit(main(sys.argv[1:]))
