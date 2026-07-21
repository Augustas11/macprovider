#!/usr/bin/env python3
"""Verify one signed release-discovery head and its immutable release binding."""

from __future__ import annotations

import argparse
import datetime as dt
import hashlib
import json
import pathlib
import re
import subprocess
import tempfile


ENVELOPE_SCHEMA = "macprovider.release-discovery-envelope.v1"
PAYLOAD_SCHEMA = "macprovider.release-discovery.v1"
ARTIFACT_INDEX_SCHEMA = "macprovider.compatibility-artifact-index.v1"
HEX40 = re.compile(r"^[0-9a-f]{40}$")
HEX64 = re.compile(r"^[0-9a-f]{64}$")
REPOSITORY = re.compile(r"^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$")
TAG = re.compile(r"^v[0-9]+\.[0-9]+\.[0-9]+$")
TRANSPORT_TAG = re.compile(r"^release-discovery-v1-([1-9][0-9]*)$")
ASSET_NAMES = (
    "compatibility-artifact-index.json",
    "macprovider-release-discovery.json",
    "macprovider-release-discovery.json.sig",
)


def fail(message: str) -> None:
    raise SystemExit(f"verify-release-discovery-transport: {message}")


def canonical(value: object) -> bytes:
    return (json.dumps(value, sort_keys=True, separators=(",", ":")) + "\n").encode()


def load_json(path: pathlib.Path, label: str, *, canonical_required: bool = False) -> dict:
    data = path.read_bytes()
    try:
        value = json.loads(
            data.decode("utf-8"),
            object_pairs_hook=reject_duplicates(label),
            parse_constant=lambda item: fail(f"{label} contains invalid number {item}"),
        )
    except (OSError, UnicodeDecodeError, json.JSONDecodeError) as exc:
        fail(f"{label} is invalid: {exc}")
    if not isinstance(value, dict):
        fail(f"{label} must be an object")
    if canonical_required and data != canonical(value):
        fail(f"{label} is not canonical JSON")
    return value


def reject_duplicates(label: str):
    def hook(pairs: list[tuple[str, object]]) -> dict:
        result: dict = {}
        for key, value in pairs:
            if key in result:
                fail(f"{label} contains duplicate key {key!r}")
            result[key] = value
        return result

    return hook


def sha256(path: pathlib.Path) -> str:
    return hashlib.sha256(path.read_bytes()).hexdigest()


def parse_time(value: object, label: str) -> dt.datetime:
    if not isinstance(value, str) or not value.endswith("Z"):
        fail(f"{label} must be a UTC RFC3339 timestamp")
    try:
        return dt.datetime.strptime(value, "%Y-%m-%dT%H:%M:%SZ").replace(tzinfo=dt.timezone.utc)
    except ValueError as exc:
        fail(f"{label} is invalid: {exc}")


def verify_release(args: argparse.Namespace, sequence: int) -> None:
    expected_transport_tag = f"release-discovery-v1-{sequence}"
    if args.transport_tag != expected_transport_tag:
        fail("transport tag sequence differs from the signed head")
    if args.release_json is None:
        return
    release = load_json(args.release_json, "release metadata")
    if release.get("tag_name") != args.transport_tag or release.get("target_commitish") != args.target_commit:
        fail("release metadata is not bound to the expected transport and target commit")
    if release.get("draft") is not False or release.get("prerelease") is not True:
        fail("release transport is not a public discovery prerelease")
    if args.require_immutable and release.get("immutable") is not True:
        fail("release transport is not immutable")
    assets = release.get("assets")
    if not isinstance(assets, list):
        fail("release asset inventory is invalid")
    if len(assets) != len(ASSET_NAMES) or {
        row.get("name") for row in assets if isinstance(row, dict)
    } != set(ASSET_NAMES):
        fail("release transport must contain exactly the three discovery assets")
    expected_paths = {
        "compatibility-artifact-index.json": args.artifact_index,
        "macprovider-release-discovery.json": args.head,
        "macprovider-release-discovery.json.sig": args.signature,
    }
    for name, path in expected_paths.items():
        matches = [row for row in assets if isinstance(row, dict) and row.get("name") == name]
        if len(matches) != 1:
            fail(f"release must contain exactly one {name}")
        row = matches[0]
        expected_url = f"https://github.com/{args.repository}/releases/download/{args.transport_tag}/{name}"
        if row.get("browser_download_url") != expected_url:
            fail(f"release asset URL is not canonical for {name}")
        if row.get("digest") != f"sha256:{sha256(path)}":
            fail(f"release asset digest differs for {name}")


def verify_artifact_index(args: argparse.Namespace) -> None:
    value = load_json(args.artifact_index, "artifact index", canonical_required=True)
    expected_fields = {
        "artifacts",
        "commit",
        "compatibility_manifest_sha256",
        "compatibility_set_id",
        "repository",
        "schema_version",
        "tag",
    }
    if set(value) != expected_fields or value.get("schema_version") != ARTIFACT_INDEX_SCHEMA:
        fail("artifact index schema or fields are invalid")
    expected_set = f"{args.repository}:{args.target_tag}@{args.target_commit}"
    if (
        value.get("repository") != args.repository
        or value.get("tag") != args.target_tag
        or value.get("commit") != args.target_commit
        or value.get("compatibility_set_id") != expected_set
    ):
        fail("artifact index identity differs from the versioned release")
    manifest_digest = value.get("compatibility_manifest_sha256")
    if not isinstance(manifest_digest, str) or not HEX64.fullmatch(manifest_digest):
        fail("artifact index compatibility-manifest digest is invalid")
    if not isinstance(value.get("artifacts"), dict):
        fail("artifact index artifact inventory is invalid")


def verify_head(args: argparse.Namespace) -> int:
    envelope = load_json(args.head, "discovery envelope", canonical_required=True)
    if set(envelope) != {"schema_version", "signed"} or envelope.get("schema_version") != ENVELOPE_SCHEMA:
        fail("discovery envelope schema or fields are invalid")
    signed = envelope.get("signed")
    expected_fields = {
        "expires_at",
        "issued_at",
        "release_sequence",
        "schema_version",
        "signed_policy_minimum",
        "signed_policy_revoked",
        "target_artifact_index_sha256",
        "target_compatibility_set_id",
    }
    if not isinstance(signed, dict) or set(signed) != expected_fields:
        fail("signed discovery fields are invalid")
    if signed.get("schema_version") != PAYLOAD_SCHEMA:
        fail("signed discovery schema is invalid")
    sequence = signed.get("release_sequence")
    if type(sequence) is not int or sequence <= 0 or sequence > (1 << 64) - 1:
        fail("release sequence is invalid")
    if sequence <= args.minimum_sequence:
        fail("release sequence did not advance")
    expected_set = f"{args.repository}:{args.target_tag}@{args.target_commit}"
    if signed.get("target_compatibility_set_id") != expected_set:
        fail("signed discovery target differs from the versioned release")
    index_digest = signed.get("target_artifact_index_sha256")
    if not isinstance(index_digest, str) or not HEX64.fullmatch(index_digest):
        fail("signed artifact-index digest is invalid")
    if index_digest != sha256(args.artifact_index):
        fail("signed artifact-index digest differs from the release asset")
    minimum = signed.get("signed_policy_minimum")
    revoked = signed.get("signed_policy_revoked")
    if minimum is not None and (not isinstance(minimum, str) or not re.fullmatch(r"[0-9]+\.[0-9]+\.[0-9]+", minimum)):
        fail("signed policy minimum is invalid")
    if not isinstance(revoked, list) or any(
        not isinstance(item, str) or not re.fullmatch(r"[0-9]+\.[0-9]+\.[0-9]+", item)
        for item in revoked
    ):
        fail("signed policy revocations are invalid")
    issued = parse_time(signed.get("issued_at"), "issued_at")
    expires = parse_time(signed.get("expires_at"), "expires_at")
    if expires <= issued or expires - issued > dt.timedelta(days=7):
        fail("signed discovery validity interval is invalid")
    now = dt.datetime.now(dt.timezone.utc)
    if not args.allow_expired and (issued > now + dt.timedelta(seconds=5) or expires <= now):
        fail("signed discovery head is not currently valid")

    with tempfile.NamedTemporaryFile(prefix="release-discovery-signed.", suffix=".json") as payload:
        payload.write(canonical(signed))
        payload.flush()
        result = subprocess.run(
            [
                args.openssl,
                "dgst",
                "-sha256",
                "-verify",
                str(args.public_key),
                "-signature",
                str(args.signature),
                payload.name,
            ],
            stdout=subprocess.DEVNULL,
            stderr=subprocess.DEVNULL,
            check=False,
            timeout=20,
        )
    if result.returncode:
        fail("signed discovery signature is invalid")
    return sequence


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--release-json", type=pathlib.Path)
    parser.add_argument("--head", required=True, type=pathlib.Path)
    parser.add_argument("--signature", required=True, type=pathlib.Path)
    parser.add_argument("--artifact-index", required=True, type=pathlib.Path)
    parser.add_argument("--public-key", required=True, type=pathlib.Path)
    parser.add_argument("--repository", required=True)
    parser.add_argument("--transport-tag", required=True)
    parser.add_argument("--target-tag", required=True)
    parser.add_argument("--target-commit", required=True)
    parser.add_argument("--minimum-sequence", type=int, default=0)
    parser.add_argument("--allow-expired", action="store_true")
    parser.add_argument("--require-immutable", action="store_true")
    parser.add_argument("--openssl", default="openssl")
    args = parser.parse_args()
    if not REPOSITORY.fullmatch(args.repository):
        fail("repository is invalid")
    if not TRANSPORT_TAG.fullmatch(args.transport_tag):
        fail("transport tag is invalid")
    if not TAG.fullmatch(args.target_tag):
        fail("target tag is invalid")
    if not HEX40.fullmatch(args.target_commit):
        fail("target commit is invalid")
    for path in (args.head, args.signature, args.artifact_index, args.public_key):
        if not path.is_file() or path.is_symlink():
            fail(f"input is absent or unsafe: {path}")
    verify_artifact_index(args)
    sequence = verify_head(args)
    verify_release(args, sequence)
    print(sequence)


if __name__ == "__main__":
    main()
