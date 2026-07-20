#!/usr/bin/env python3
"""Build and sign the SPEC-020 release discovery head."""

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
COMPATIBILITY_SCHEMA = "macprovider.compatibility-set-envelope.v1"
HEX64 = re.compile(r"[0-9a-f]{64}")
SEMVER = re.compile(r"v?[0-9]+\.[0-9]+\.[0-9]+")
SET_ID = re.compile(r"[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+:v[0-9]+\.[0-9]+\.[0-9]+@[0-9a-f]{40}")
SEQUENCE_ATTEMPT_BITS = 16
SEQUENCE_ATTEMPT_MAX = (1 << SEQUENCE_ATTEMPT_BITS) - 1
UINT64_MAX = (1 << 64) - 1


def fail(message: str) -> None:
    raise SystemExit(f"[build-release-discovery-head] ERROR: {message}")


def canonical_bytes(value: object) -> bytes:
    return (json.dumps(value, sort_keys=True, separators=(",", ":")) + "\n").encode("utf-8")


def load_canonical(path: pathlib.Path, label: str) -> dict:
    data = path.read_bytes()
    try:
        value = json.loads(
            data.decode("utf-8"),
            object_pairs_hook=_reject_duplicate_keys(label),
            parse_constant=lambda value: fail(f"{label}: invalid number {value}"),
        )
    except json.JSONDecodeError as exc:
        fail(f"{label}: invalid JSON: {exc}")
    if not isinstance(value, dict):
        fail(f"{label}: top level must be an object")
    if data != canonical_bytes(value):
        fail(f"{label}: must be canonical sorted compact JSON with one trailing newline")
    return value


def _reject_duplicate_keys(label: str):
    def hook(pairs: list[tuple[str, object]]) -> dict:
        result: dict = {}
        for key, value in pairs:
            if key in result:
                fail(f"{label}: duplicate key {key!r}")
            result[key] = value
        return result

    return hook


def compatibility_set_id(path: pathlib.Path) -> str:
    envelope = load_canonical(path, "compatibility manifest")
    if set(envelope) != {"schema_version", "signatures", "signed"}:
        fail("compatibility manifest: unsupported envelope fields")
    if envelope["schema_version"] != COMPATIBILITY_SCHEMA:
        fail("compatibility manifest: unsupported schema")
    signed = envelope["signed"]
    if not isinstance(signed, dict):
        fail("compatibility manifest: missing signed payload")
    set_id = signed.get("compatibility_set_id")
    if not isinstance(set_id, str) or not SET_ID.fullmatch(set_id):
        fail("compatibility manifest: invalid compatibility_set_id")
    return set_id


def parse_time(value: str, label: str) -> dt.datetime:
    if not value.endswith("Z"):
        fail(f"{label}: must be UTC Z time")
    try:
        parsed = dt.datetime.strptime(value, "%Y-%m-%dT%H:%M:%SZ").replace(tzinfo=dt.timezone.utc)
    except ValueError as exc:
        fail(f"{label}: invalid RFC3339 second-precision time: {exc}")
    return parsed


def format_time(value: dt.datetime) -> str:
    return value.astimezone(dt.timezone.utc).replace(microsecond=0).strftime("%Y-%m-%dT%H:%M:%SZ")


def normalize_semver(value: str, label: str) -> str:
    if not SEMVER.fullmatch(value):
        fail(f"{label}: invalid semver")
    return value[1:] if value.startswith("v") else value


def sign_payload(
    payload: bytes,
    private_key: pathlib.Path,
    public_key: pathlib.Path,
    signature: pathlib.Path,
    openssl: str,
) -> None:
    with tempfile.NamedTemporaryFile(prefix="release-discovery-signed.", suffix=".json") as handle:
        handle.write(payload)
        handle.flush()
        subprocess.run(
            [openssl, "dgst", "-sha256", "-sign", str(private_key), "-out", str(signature), handle.name],
            check=True,
        )
        subprocess.run(
            [
                openssl,
                "dgst",
                "-sha256",
                "-verify",
                str(public_key),
                "-signature",
                str(signature),
                handle.name,
            ],
            check=True,
            stdout=subprocess.DEVNULL,
        )


def release_sequence(run_id: int, run_attempt: int) -> int:
    if run_id <= 0:
        fail("release run id must be positive")
    if run_attempt <= 0 or run_attempt > SEQUENCE_ATTEMPT_MAX:
        fail(f"release run attempt must be between 1 and {SEQUENCE_ATTEMPT_MAX}")
    if run_id > (UINT64_MAX - run_attempt) >> SEQUENCE_ATTEMPT_BITS:
        fail("release run id is too large for the composite sequence")
    return (run_id << SEQUENCE_ATTEMPT_BITS) | run_attempt


def build(args: argparse.Namespace) -> None:
    sequence = release_sequence(args.sequence, args.attempt)
    set_id = compatibility_set_id(args.compatibility_manifest)
    artifact_index_sha = hashlib.sha256(args.target_artifact_index.read_bytes()).hexdigest()
    if not HEX64.fullmatch(artifact_index_sha):
        fail("artifact index digest invalid")
    now = dt.datetime.now(dt.timezone.utc).replace(microsecond=0)
    issued = parse_time(args.issued_at, "issued_at") if args.issued_at else now
    expires = parse_time(args.expires_at, "expires_at") if args.expires_at else issued + dt.timedelta(hours=24)
    if expires <= issued or expires - issued > dt.timedelta(days=7):
        fail("expires_at must be after issued_at and no more than seven days later")
    minimum = None if args.signed_policy_minimum is None else normalize_semver(args.signed_policy_minimum, "signed policy minimum")
    revoked = sorted({normalize_semver(value, "signed policy revoked") for value in args.signed_policy_revoked})
    signed = {
        "expires_at": format_time(expires),
        "issued_at": format_time(issued),
        "release_sequence": sequence,
        "schema_version": PAYLOAD_SCHEMA,
        "signed_policy_minimum": minimum,
        "signed_policy_revoked": revoked,
        "target_artifact_index_sha256": artifact_index_sha,
        "target_compatibility_set_id": set_id,
    }
    envelope = {
        "schema_version": ENVELOPE_SCHEMA,
        "signed": signed,
    }
    signed_bytes = canonical_bytes(signed)
    args.output.write_bytes(canonical_bytes(envelope))
    sign_payload(signed_bytes, args.private_key, args.public_key, args.signature, args.openssl)


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--sequence", type=int, required=True)
    parser.add_argument("--attempt", type=int, required=True)
    parser.add_argument("--compatibility-manifest", type=pathlib.Path, required=True)
    parser.add_argument("--target-artifact-index", type=pathlib.Path, required=True)
    parser.add_argument("--signed-policy-minimum")
    parser.add_argument("--signed-policy-revoked", action="append", default=[])
    parser.add_argument("--issued-at")
    parser.add_argument("--expires-at")
    parser.add_argument("--private-key", type=pathlib.Path, required=True)
    parser.add_argument("--public-key", type=pathlib.Path, required=True)
    parser.add_argument("--openssl", default="openssl")
    parser.add_argument("--output", type=pathlib.Path, required=True)
    parser.add_argument("--signature", type=pathlib.Path, required=True)
    build(parser.parse_args())


if __name__ == "__main__":
    main()
