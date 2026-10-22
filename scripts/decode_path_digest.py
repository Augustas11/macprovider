#!/usr/bin/env python3
"""SPEC-048-R013 (0.1.51) decode-path digest.

The digest names the code that decides which tokens a native-MTP or
continuous-batching row emits: the decode-path source files listed in
`phase3-binary/decode-path-manifest.json` plus the pinned mlx-swift and
mlx-swift-lm revisions (the MLX core, the model families' forward passes and
the fork's drafters). A signed admission entry that carries
`decode_path_digest` is valid for every signed CLI release that embeds the same
digest; a CLI cut that leaves the decode path alone needs no admission step.

The digest is SHA-256 over the UTF-8 bytes

    macprovider.decode-path-digest.v1\\n
    file <path> <sha256 of the file bytes>\\n        (manifest order: bytewise sorted)
    dependency <identity> <Package.resolved revision>\\n   (sorted)

and is compiled into the CLI as `DecodePathIdentity.embeddedMarker`
(`phase3-binary/Sources/macprovider-cli/DecodePathIdentity.generated.swift`),
so the signed binary carries it.

Usage:
  python3 scripts/decode_path_digest.py              print the digest
  python3 scripts/decode_path_digest.py --write      regenerate the Swift constant
  python3 scripts/decode_path_digest.py --check      exit 1 if a listed file is
                                                     missing or the constant is stale (CI)
  python3 scripts/decode_path_digest.py --binary PATH
                                                     print the digest embedded in a built
                                                     macprovider-cli (or "none")
  python3 scripts/decode_path_digest.py --admission-status SIDECAR
                                                     compare a native-MTP admission sidecar's
                                                     entries with this tree's digest:
                                                     match | legacy | mismatch
"""

from __future__ import annotations

import argparse
import hashlib
import json
import re
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
PACKAGE = ROOT / "phase3-binary"
MANIFEST = PACKAGE / "decode-path-manifest.json"
RESOLVED = PACKAGE / "Package.resolved"
GENERATED = PACKAGE / "Sources" / "macprovider-cli" / "DecodePathIdentity.generated.swift"
MANIFEST_SCHEMA = "macprovider.decode-path-manifest.v1"
DOMAIN = "macprovider.decode-path-digest.v1"
MARKER_PREFIX = DOMAIN + ":"
MARKER = re.compile(rb"macprovider\.decode-path-digest\.v1:([0-9a-f]{64})")
REVISION = re.compile(r"^[0-9a-f]{40}$")
SOURCE_PATH = re.compile(r"^Sources/[A-Za-z0-9_./-]+\.swift$")
MAX_FILES = 256


class DecodePathError(ValueError):
    pass


def _reject_duplicate_keys(pairs: list[tuple[str, object]]) -> dict:
    keys = [key for key, _ in pairs]
    if len(set(keys)) != len(keys):
        raise DecodePathError("duplicate JSON key")
    return dict(pairs)


def load_manifest(package: Path = PACKAGE) -> tuple[list[str], list[str]]:
    path = package / MANIFEST.name
    try:
        value = json.loads(path.read_text("utf-8"), object_pairs_hook=_reject_duplicate_keys)
    except (OSError, json.JSONDecodeError) as error:
        raise DecodePathError(f"{path}: {error}") from error
    if not isinstance(value, dict) or set(value) != {"schema_version", "files", "dependencies"}:
        raise DecodePathError(f"{path}: must be exactly {{schema_version, files, dependencies}}")
    if value["schema_version"] != MANIFEST_SCHEMA:
        raise DecodePathError(f"{path}: schema_version must be {MANIFEST_SCHEMA}")
    files, dependencies = value["files"], value["dependencies"]
    for name, items in (("files", files), ("dependencies", dependencies)):
        if not isinstance(items, list) or not items or not all(isinstance(item, str) and item for item in items):
            raise DecodePathError(f"{path}: {name} must be a non-empty array of strings")
        encoded = [item.encode("utf-8") for item in items]
        if encoded != sorted(encoded) or len(set(items)) != len(items):
            raise DecodePathError(f"{path}: {name} must be bytewise sorted and unique")
    if len(files) > MAX_FILES:
        raise DecodePathError(f"{path}: at most {MAX_FILES} files")
    generated = GENERATED.relative_to(PACKAGE).as_posix()
    for item in files:
        if not SOURCE_PATH.match(item) or ".." in item.split("/"):
            raise DecodePathError(f"{path}: file {item!r} must be a relative Sources/**/*.swift path")
        if item == generated:
            raise DecodePathError(f"{path}: the generated digest file cannot be part of its own digest")
    return files, dependencies


def resolved_revisions(package: Path = PACKAGE) -> dict[str, str]:
    path = package / RESOLVED.name
    try:
        value = json.loads(path.read_text("utf-8"))
    except (OSError, json.JSONDecodeError) as error:
        raise DecodePathError(f"{path}: {error}") from error
    revisions: dict[str, str] = {}
    for pin in value.get("pins") or []:
        identity = pin.get("identity")
        revision = (pin.get("state") or {}).get("revision")
        if isinstance(identity, str) and isinstance(revision, str):
            revisions[identity] = revision
    return revisions


def compute(package: Path = PACKAGE) -> str:
    files, dependencies = load_manifest(package)
    revisions = resolved_revisions(package)
    lines = [DOMAIN]
    for item in files:
        path = package / item
        if not path.is_file() or path.is_symlink():
            raise DecodePathError(f"decode-path manifest lists {item}, which is not a regular file")
        lines.append(f"file {item} {hashlib.sha256(path.read_bytes()).hexdigest()}")
    for identity in dependencies:
        revision = revisions.get(identity)
        if revision is None or not REVISION.match(revision):
            raise DecodePathError(f"Package.resolved has no 40-hex revision for {identity}")
        lines.append(f"dependency {identity} {revision}")
    return hashlib.sha256(("\n".join(lines) + "\n").encode("utf-8")).hexdigest()


def render(digest: str) -> str:
    return f"""// GENERATED by scripts/decode_path_digest.py --write. Do not edit.
// SPEC-048-R013 (0.1.51): the decode-path digest over
// phase3-binary/decode-path-manifest.json. CI (`decode_path_digest.py --check`
// and DecodePathIdentityTests) fails when a listed file changes without
// regenerating this constant.

enum DecodePathIdentity {{
    static let domain = "{DOMAIN}"
    /// Kept as one literal so the signed binary carries a findable marker.
    static let embeddedMarker = "{MARKER_PREFIX}{digest}"
    static var digest: String {{ String(embeddedMarker.dropFirst(domain.count + 1)) }}
}}
"""


def embedded_in_binary(path: Path) -> str | None:
    found = set(MARKER.findall(path.read_bytes()))
    if len(found) > 1:
        raise DecodePathError(f"{path}: more than one embedded decode-path digest")
    return found.pop().decode("ascii") if found else None


def admission_status(sidecar: Path, digest: str) -> str:
    value = json.loads(sidecar.read_text("utf-8"), object_pairs_hook=_reject_duplicate_keys)
    entries = value.get("entries") if isinstance(value, dict) else None
    if not isinstance(entries, list) or not entries:
        raise DecodePathError(f"{sidecar}: no entries")
    digests = [entry.get("decode_path_digest") for entry in entries if isinstance(entry, dict)]
    if any(item is None for item in digests):
        return "legacy"
    return "match" if all(item == digest for item in digests) else "mismatch"


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    mode = parser.add_mutually_exclusive_group()
    mode.add_argument("--write", action="store_true")
    mode.add_argument("--check", action="store_true")
    mode.add_argument("--binary", type=Path)
    mode.add_argument("--admission-status", type=Path)
    args = parser.parse_args(argv)
    try:
        if args.binary is not None:
            print(embedded_in_binary(args.binary) or "none")
            return 0
        digest = compute()
        if args.admission_status is not None:
            print(admission_status(args.admission_status, digest))
        elif args.write:
            GENERATED.write_text(render(digest), "utf-8")
            print(digest)
        elif args.check:
            current = GENERATED.read_text("utf-8") if GENERATED.exists() else ""
            if current != render(digest):
                print(
                    f"decode_path_digest: {GENERATED.relative_to(ROOT)} is stale (decode path digest {digest}); "
                    "run python3 scripts/decode_path_digest.py --write and review the decode-path change "
                    "(AGENTS.md rule 2: a changed decode path needs requalification evidence)",
                    file=sys.stderr,
                )
                return 1
            print(digest)
        else:
            print(digest)
    except (DecodePathError, OSError, json.JSONDecodeError) as error:
        print(f"decode_path_digest: {error}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
