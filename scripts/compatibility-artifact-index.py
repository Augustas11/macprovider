#!/usr/bin/env python3
"""Build and validate the signed release-set artifact index."""

from __future__ import annotations

import argparse
import hashlib
import json
import os
import pathlib
import re
import stat
import tempfile


SCHEMA_VERSION = "macprovider.compatibility-artifact-index.v1"
REQUIRED_ROLES = (
    "catalog_candidates",
    "catalog_candidates_signature",
    "catalog_demand",
    "catalog_demand_signature",
    "catalog_manifest",
    "catalog_trusted_keys",
    "compatibility_manifest",
    "coordinator",
    "coordinator_cli",
    "gateway",
    "malibu_app",
    "pearl_metadata",
    "pearl_metadata_signature",
    "provider_cli",
)
HEX40 = re.compile(r"[0-9a-f]{40}")
HEX64 = re.compile(r"[0-9a-f]{64}")
TAG = re.compile(r"v[0-9]+\.[0-9]+\.[0-9]+")
REPOSITORY = re.compile(r"[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+")
ASSET_NAME = re.compile(r"[A-Za-z0-9][A-Za-z0-9._+-]{0,255}")
MAX_JSON_BYTES = 1_048_576


class IndexError(RuntimeError):
    pass


def fail(message: str) -> None:
    raise IndexError(message)


def canonical_bytes(value: object) -> bytes:
    return (json.dumps(value, sort_keys=True, separators=(",", ":")) + "\n").encode()


def strict_json(path: pathlib.Path, label: str) -> dict:
    data = read_regular(path, label, maximum_bytes=MAX_JSON_BYTES)

    def reject_pairs(pairs: list[tuple[str, object]]) -> dict:
        result: dict = {}
        for key, value in pairs:
            if key in result:
                fail(f"{label}: duplicate object key {key!r}")
            result[key] = value
        return result

    try:
        text = data.decode("utf-8")
        value = json.loads(
            text,
            object_pairs_hook=reject_pairs,
            parse_constant=lambda value: fail(f"{label}: invalid number {value}"),
            parse_float=lambda value: fail(f"{label}: floating-point values are forbidden"),
        )
    except (UnicodeDecodeError, json.JSONDecodeError) as exc:
        fail(f"{label}: invalid JSON: {exc}")
    if not isinstance(value, dict):
        fail(f"{label}: top level must be an object")
    if data != canonical_bytes(value):
        fail(f"{label}: must use canonical sorted compact JSON with one trailing newline")
    return value


def read_regular(path: pathlib.Path, label: str, maximum_bytes: int | None = None) -> bytes:
    try:
        info = path.lstat()
    except OSError as exc:
        fail(f"{label}: cannot stat {path}: {exc}")
    if stat.S_ISLNK(info.st_mode) or not stat.S_ISREG(info.st_mode) or info.st_nlink != 1:
        fail(f"{label}: must be a regular non-symlink single-link file: {path}")
    if maximum_bytes is not None and not 0 < info.st_size <= maximum_bytes:
        fail(f"{label}: invalid size")
    try:
        return path.read_bytes()
    except OSError as exc:
        fail(f"{label}: cannot read {path}: {exc}")


def sha256(path: pathlib.Path, label: str) -> str:
    read_regular(path, label)
    digest = hashlib.sha256()
    with path.open("rb") as source:
        for chunk in iter(lambda: source.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


def exact_keys(value: dict, expected: set[str], label: str) -> None:
    if set(value) != expected:
        fail(f"{label}: fields differ from the supported contract")


def require_string(value: object, pattern: re.Pattern[str], label: str) -> str:
    if not isinstance(value, str) or not pattern.fullmatch(value):
        fail(f"{label}: invalid value")
    return value


def compatibility_identity(path: pathlib.Path) -> tuple[str, str, str, str, str]:
    envelope = strict_json(path, "compatibility manifest")
    exact_keys(envelope, {"schema_version", "signatures", "signed"}, "compatibility manifest")
    if envelope["schema_version"] != "macprovider.compatibility-set-envelope.v1":
        fail("compatibility manifest: unsupported envelope schema")
    signed = envelope.get("signed")
    if not isinstance(signed, dict):
        fail("compatibility manifest: signed payload is missing")
    release = signed.get("release")
    if not isinstance(release, dict):
        fail("compatibility manifest: release identity is missing")
    exact_keys(release, {"commit", "repository", "tag", "version"}, "compatibility release")
    repository = require_string(release.get("repository"), REPOSITORY, "compatibility repository")
    tag = require_string(release.get("tag"), TAG, "compatibility tag")
    commit = require_string(release.get("commit"), HEX40, "compatibility commit")
    compatibility_set_id = signed.get("compatibility_set_id")
    if compatibility_set_id != f"{repository}:{tag}@{commit}":
        fail("compatibility manifest: set id differs from release identity")
    return repository, tag, commit, compatibility_set_id, sha256(path, "compatibility manifest")


def parse_artifacts(values: list[str]) -> dict[str, pathlib.Path]:
    result: dict[str, pathlib.Path] = {}
    for value in values:
        role, separator, name = value.partition("=")
        if not separator or role not in REQUIRED_ROLES or role in result or not name:
            fail(f"invalid or duplicate artifact mapping: {value!r}")
        result[role] = pathlib.Path(name)
    if set(result) != set(REQUIRED_ROLES):
        fail("artifact mappings do not contain the exact required roles")
    names = [path.name for path in result.values()]
    if len(names) != len(set(names)):
        fail("artifact mappings contain duplicate asset names")
    if any(not ASSET_NAME.fullmatch(path.name) for path in result.values()):
        fail("artifact mappings must use safe release asset basenames")
    return result


def validate_index(
    value: dict,
    manifest_path: pathlib.Path,
    artifacts: dict[str, pathlib.Path],
    expected_repository: str | None,
    expected_tag: str | None,
    expected_commit: str | None,
) -> None:
    exact_keys(
        value,
        {
            "artifacts",
            "commit",
            "compatibility_manifest_sha256",
            "compatibility_set_id",
            "repository",
            "schema_version",
            "tag",
        },
        "artifact index",
    )
    if value["schema_version"] != SCHEMA_VERSION:
        fail("artifact index: unsupported schema")
    repository = require_string(value.get("repository"), REPOSITORY, "artifact index repository")
    tag = require_string(value.get("tag"), TAG, "artifact index tag")
    commit = require_string(value.get("commit"), HEX40, "artifact index commit")
    if expected_repository is not None and repository != expected_repository:
        fail("artifact index: repository differs from expected release")
    if expected_tag is not None and tag != expected_tag:
        fail("artifact index: tag differs from expected release")
    if expected_commit is not None and commit != expected_commit:
        fail("artifact index: commit differs from expected release")

    manifest_repository, manifest_tag, manifest_commit, set_id, manifest_sha = compatibility_identity(manifest_path)
    if (repository, tag, commit) != (manifest_repository, manifest_tag, manifest_commit):
        fail("artifact index: release identity differs from compatibility manifest")
    if value.get("compatibility_set_id") != set_id:
        fail("artifact index: compatibility set id differs from manifest")
    if value.get("compatibility_manifest_sha256") != manifest_sha:
        fail("artifact index: compatibility manifest digest differs")

    rows = value.get("artifacts")
    if not isinstance(rows, dict) or set(rows) != set(REQUIRED_ROLES):
        fail("artifact index: artifact roles differ from the supported contract")
    seen_names: set[str] = set()
    for role in REQUIRED_ROLES:
        row = rows.get(role)
        if not isinstance(row, dict):
            fail(f"artifact index: invalid {role} row")
        exact_keys(row, {"name", "sha256"}, f"artifact index {role}")
        name = require_string(row.get("name"), ASSET_NAME, f"artifact index {role} name")
        digest = require_string(row.get("sha256"), HEX64, f"artifact index {role} digest")
        if name in seen_names:
            fail("artifact index: duplicate asset name")
        seen_names.add(name)
        path = artifacts[role]
        if name != path.name or digest != sha256(path, f"artifact {role}"):
            fail(f"artifact index: {role} differs from supplied release asset")
    compatibility_row = rows["compatibility_manifest"]
    if compatibility_row != {"name": manifest_path.name, "sha256": manifest_sha}:
        fail("artifact index: compatibility manifest role is inconsistent")


def atomic_write(path: pathlib.Path, data: bytes) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    if path.exists() and path.is_symlink():
        fail(f"output must not be a symlink: {path}")
    descriptor, temporary_name = tempfile.mkstemp(prefix=f".{path.name}.", dir=path.parent)
    temporary = pathlib.Path(temporary_name)
    try:
        with os.fdopen(descriptor, "wb") as output:
            output.write(data)
            output.flush()
            os.fsync(output.fileno())
        os.chmod(temporary, 0o644)
        os.replace(temporary, path)
    finally:
        temporary.unlink(missing_ok=True)


def main() -> int:
    parser = argparse.ArgumentParser()
    subparsers = parser.add_subparsers(dest="command", required=True)
    for command in ("build", "validate"):
        sub = subparsers.add_parser(command)
        sub.add_argument("--compatibility-manifest", required=True, type=pathlib.Path)
        sub.add_argument("--artifact", action="append", default=[], dest="artifacts")
        sub.add_argument("--repository")
        sub.add_argument("--tag")
        sub.add_argument("--commit")
        if command == "build":
            sub.add_argument("--output", required=True, type=pathlib.Path)
        else:
            sub.add_argument("--input", required=True, type=pathlib.Path)
    args = parser.parse_args()

    try:
        artifacts = parse_artifacts(args.artifacts)
        if args.command == "build":
            repository, tag, commit, set_id, manifest_sha = compatibility_identity(args.compatibility_manifest)
            if args.repository is not None and args.repository != repository:
                fail("requested repository differs from compatibility manifest")
            if args.tag is not None and args.tag != tag:
                fail("requested tag differs from compatibility manifest")
            if args.commit is not None and args.commit != commit:
                fail("requested commit differs from compatibility manifest")
            value = {
                "artifacts": {
                    role: {"name": path.name, "sha256": sha256(path, f"artifact {role}")}
                    for role, path in artifacts.items()
                },
                "commit": commit,
                "compatibility_manifest_sha256": manifest_sha,
                "compatibility_set_id": set_id,
                "repository": repository,
                "schema_version": SCHEMA_VERSION,
                "tag": tag,
            }
            validate_index(value, args.compatibility_manifest, artifacts, repository, tag, commit)
            atomic_write(args.output, canonical_bytes(value))
        else:
            value = strict_json(args.input, "artifact index")
            validate_index(
                value,
                args.compatibility_manifest,
                artifacts,
                args.repository,
                args.tag,
                args.commit,
            )
    except IndexError as exc:
        parser.error(str(exc))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
