#!/usr/bin/env python3
"""Derive or emit the signed provider CLI code identity (issue #1842).

Default mode reads the final shipped provider tarball, extracts the
`macprovider-cli` member, and derives its code identity from
`codesign -d --arch <arch> -vvv` key=value lines (never from designated
requirement display text). It fails closed unless the binary is exact arm64,
signed with Identifier live.malibu.provider.cli, and carries the expected
release TeamIdentifier. The JSON it prints is the `provider_code_identity`
object that release producers place in signed pearl-release.json.

--emit-approved-identity verifies a signed pearl-release.json against the
release signing public key and prints ready-to-paste SPEC-049
`privacy_class.approved_code_identities` YAML entries.
"""

from __future__ import annotations

import argparse
import datetime as dt
import hashlib
import json
import os
import pathlib
import re
import subprocess
import sys
import tarfile
import tempfile


SIGNING_IDENTIFIER = "live.malibu.provider.cli"
MEMBER = "macprovider-cli"
EXPECTED_ARCHES = ("arm64",)
IDENTITY_KEYS = {
    "asset",
    "member",
    "binary_version",
    "binary_sha256",
    "team_id",
    "signing_identifier",
    "slices",
}
SLICE_KEYS = {"arch", "code_cdhash"}
ASSET = re.compile(r"^macprovider-cli-v[0-9]+\.[0-9]+\.[0-9]+-darwin-arm64\.tar\.gz$")
SEMVER = re.compile(r"^[0-9]+\.[0-9]+\.[0-9]+$")
HEX40 = re.compile(r"^[0-9a-f]{40}$")
HEX64 = re.compile(r"^[0-9a-f]{64}$")
TEAM_ID = re.compile(r"^[A-Z0-9]{10}$")
RFC3339 = re.compile(r"^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}(\.[0-9]+)?(Z|[+-][0-9]{2}:[0-9]{2})$")
CODESIGN_KEYS = ("CDHash", "TeamIdentifier", "Identifier")
MAX_MEMBER_BYTES = 1024 * 1024 * 1024
CHUNK_BYTES = 1024 * 1024
# Last provider CLI version released before #1842; later releases MUST carry
# provider_code_identity (SPEC-025 §6.2.1).
LEGACY_OPTIONAL_THROUGH = (1, 8, 213)
REPO_ROOT = pathlib.Path(__file__).resolve().parents[1]
DEFAULT_PUBLIC_KEY = REPO_ROOT / "ops" / "pearl-updater" / "release-signing-public.pem"


class IdentityError(RuntimeError):
    pass


def fail(message: str) -> None:
    raise IdentityError(message)


def validate_identity(value: object, *, tag: str | None = None, binary_version: str | None = None) -> dict:
    """Validate a provider_code_identity object; optionally bind tag and version."""
    if not isinstance(value, dict) or set(value) != IDENTITY_KEYS:
        fail("provider_code_identity fields differ from the supported contract")
    asset = value["asset"]
    if not isinstance(asset, str) or not ASSET.fullmatch(asset):
        fail("provider_code_identity asset is invalid")
    if tag is not None and asset != f"macprovider-cli-{tag}-darwin-arm64.tar.gz":
        fail("provider_code_identity asset does not match the release tag")
    if value["member"] != MEMBER:
        fail("provider_code_identity member must be macprovider-cli")
    version = value["binary_version"]
    if not isinstance(version, str) or not SEMVER.fullmatch(version):
        fail("provider_code_identity binary_version is invalid")
    if binary_version is not None and version != binary_version:
        fail("provider_code_identity binary_version does not match the provider version")
    digest = value["binary_sha256"]
    if not isinstance(digest, str) or not HEX64.fullmatch(digest):
        fail("provider_code_identity binary_sha256 is invalid")
    team = value["team_id"]
    if not isinstance(team, str) or not TEAM_ID.fullmatch(team):
        fail("provider_code_identity team_id is invalid")
    if value["signing_identifier"] != SIGNING_IDENTIFIER:
        fail("provider_code_identity signing_identifier is not live.malibu.provider.cli")
    slices = value["slices"]
    if not isinstance(slices, list) or len(slices) != len(EXPECTED_ARCHES):
        fail("provider_code_identity slices must be exactly arm64")
    for expected_arch, row in zip(EXPECTED_ARCHES, slices):
        if not isinstance(row, dict) or set(row) != SLICE_KEYS or row["arch"] != expected_arch:
            fail("provider_code_identity slices must be exactly arm64")
        cdhash = row["code_cdhash"]
        if not isinstance(cdhash, str) or not HEX40.fullmatch(cdhash):
            fail("provider_code_identity code_cdhash must be 40 lowercase hex")
    return value


def run_tool(arguments: list[str], label: str) -> str:
    try:
        result = subprocess.run(
            arguments,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            check=False,
            timeout=60,
        )
    except (OSError, subprocess.TimeoutExpired) as exc:
        fail(f"{label} could not run: {exc}")
    if result.returncode != 0:
        fail(f"{label} failed with exit status {result.returncode}")
    return (result.stdout + result.stderr).decode("utf-8", errors="replace")


def require_checksum_row(checksums_path: pathlib.Path, asset: str, path: pathlib.Path) -> str:
    """Bind `path` to exactly one well-formed `checksums.txt` row for `asset`.

    Fails unless checksums.txt has exactly one `<64 hex>  <asset>` row (an
    optional binary-mode `*` prefix on the name is accepted), the asset file is
    a regular non-symlink file, and its streamed sha256 equals that row.
    Returns the digest.
    """
    try:
        lines = checksums_path.read_text(encoding="utf-8").splitlines()
    except (OSError, UnicodeDecodeError) as exc:
        fail(f"checksums.txt is unreadable: {exc}")
    digests = []
    for line in lines:
        fields = line.split()
        if len(fields) == 2 and fields[1].removeprefix("*") == asset:
            digests.append(fields[0])
    if not digests:
        fail(f"checksums.txt has no row for {asset}")
    if len(digests) != 1:
        fail(f"checksums.txt has duplicate rows for {asset}")
    if not HEX64.fullmatch(digests[0]):
        fail(f"checksums.txt row for {asset} is not a lowercase sha256")
    if path.is_symlink() or not path.is_file():
        fail(f"missing asset bound by checksums.txt: {asset}")
    digest = hashlib.sha256()
    with path.open("rb") as source:
        for chunk in iter(lambda: source.read(CHUNK_BYTES), b""):
            digest.update(chunk)
    if digest.hexdigest() != digests[0]:
        fail(f"checksums.txt digest mismatch for {asset}")
    return digests[0]


def member_sha256(tarball: pathlib.Path, member_name: str = MEMBER, destination: pathlib.Path | None = None) -> str:
    """Stream the single regular member's bytes, enforcing the size cap while reading.

    Returns its sha256 and, when `destination` is given, writes the bytes there.
    """
    digest = hashlib.sha256()
    handle = None
    try:
        with tarfile.open(tarball, "r:gz") as archive:
            matches = []
            for member in archive.getmembers():
                parts = tuple(p for p in pathlib.PurePosixPath(member.name).parts if p not in ("", "."))
                if parts == (member_name,):
                    matches.append(member)
            if len(matches) != 1:
                fail(f"tarball must contain exactly one {member_name} member")
            member = matches[0]
            if not member.isfile() or member.size <= 0 or member.size > MAX_MEMBER_BYTES:
                fail(f"tarball {member_name} member must be a regular non-empty file")
            source = archive.extractfile(member)
            if source is None:
                fail(f"tarball {member_name} member is unreadable")
            if destination is not None:
                handle = os.fdopen(os.open(destination, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o700), "wb")
            total = 0
            for chunk in iter(lambda: source.read(CHUNK_BYTES), b""):
                total += len(chunk)
                if total > MAX_MEMBER_BYTES:
                    fail(f"tarball {member_name} member exceeds the size cap")
                digest.update(chunk)
                if handle is not None:
                    handle.write(chunk)
    except (OSError, tarfile.TarError) as exc:
        fail(f"tarball is not a readable gzip tar: {exc}")
    finally:
        if handle is not None:
            handle.close()
    return digest.hexdigest()


def identity_required(provider_version: object) -> bool:
    """SPEC-025 §6.2.1 cutoff: provider CLI releases after 1.8.213 MUST carry the field.

    Verifiers pass the provider version already bound by signed metadata (the
    release tag or the signed compatibility manifest). Anything that is not a
    plain X.Y.Z fails closed as "required".
    """
    if not isinstance(provider_version, str) or not SEMVER.fullmatch(provider_version):
        return True
    return tuple(int(part) for part in provider_version.split(".")) > LEGACY_OPTIONAL_THROUGH


def codesign_fields(binary: pathlib.Path, arch: str) -> dict[str, str]:
    output = run_tool(["codesign", "-d", "--arch", arch, "-vvv", str(binary)], f"codesign -d --arch {arch}")
    values: dict[str, list[str]] = {key: [] for key in CODESIGN_KEYS}
    for line in output.splitlines():
        key, separator, value = line.partition("=")
        if separator and key in values:
            values[key].append(value.strip())
    fields = {}
    for key, found in values.items():
        if len(found) != 1:
            fail(f"codesign --arch {arch} must report exactly one {key}= line")
        fields[key] = found[0]
    return fields


def derive(args: argparse.Namespace) -> dict:
    tarball = args.tarball
    if tarball is None or not tarball.is_file() or tarball.is_symlink():
        fail("--tarball must be an existing regular file")
    if not ASSET.fullmatch(tarball.name):
        fail("--tarball name must be macprovider-cli-vX.Y.Z-darwin-arm64.tar.gz")
    if args.binary_version is None or not SEMVER.fullmatch(args.binary_version):
        fail("--binary-version must be X.Y.Z")
    expected_team = args.expected_team_id or os.environ.get("APPLE_NOTARY_TEAM_ID", "")
    if not TEAM_ID.fullmatch(expected_team):
        fail("expected Team ID (--expected-team-id or APPLE_NOTARY_TEAM_ID) must match ^[A-Z0-9]{10}$")
    if args.expect_sha256 is not None and not HEX64.fullmatch(args.expect_sha256):
        fail("--expect-sha256 must be 64 lowercase hex")
    with tempfile.TemporaryDirectory(prefix="provider-code-identity.") as work:
        binary = pathlib.Path(work) / MEMBER
        binary_sha256 = member_sha256(tarball, args.member, binary)
        if args.expect_sha256 is not None and binary_sha256 != args.expect_sha256:
            fail("extracted macprovider-cli sha256 differs from --expect-sha256")
        arches = tuple(run_tool(["lipo", "-archs", str(binary)], "lipo -archs").split())
        if arches != EXPECTED_ARCHES:
            fail("signed provider binary is not exact arm64")
        slices = []
        team_id = None
        for arch in arches:
            fields = codesign_fields(binary, arch)
            if fields["Identifier"] != SIGNING_IDENTIFIER:
                fail("codesign Identifier is not live.malibu.provider.cli")
            if fields["TeamIdentifier"] != expected_team:
                fail("codesign TeamIdentifier does not match the expected release team")
            cdhash = fields["CDHash"]
            if not HEX40.fullmatch(cdhash):
                fail("codesign CDHash is not 40 lowercase hex")
            team_id = fields["TeamIdentifier"]
            slices.append({"arch": arch, "code_cdhash": cdhash})
    identity = {
        "asset": tarball.name,
        "member": MEMBER,
        "binary_version": args.binary_version,
        "binary_sha256": binary_sha256,
        "team_id": team_id,
        "signing_identifier": SIGNING_IDENTIFIER,
        "slices": slices,
    }
    return validate_identity(identity)


def parse_expiry(value: str | None) -> str | None:
    # No expiry unless the operator asks for one (AGENTS.md rule 10).
    if value is None:
        return None
    if not RFC3339.fullmatch(value):
        fail("--expires-at must be an RFC3339 timestamp")
    try:
        parsed = dt.datetime.fromisoformat(value.replace("Z", "+00:00"))
    except ValueError:
        fail("--expires-at must be an RFC3339 timestamp")
    if parsed <= dt.datetime.now(dt.timezone.utc):
        fail("--expires-at must be in the future")
    return value


def emit_approved_identity(args: argparse.Namespace) -> str:
    expires_at = parse_expiry(args.expires_at)
    metadata_path = args.pearl_release_json
    if metadata_path is None or not metadata_path.is_file():
        fail("--pearl-release-json must be an existing file")
    signature = args.signature or metadata_path.with_name(metadata_path.name + ".sig")
    if not signature.is_file():
        fail("pearl-release.json signature is missing")
    if not args.public_key.is_file():
        fail("release signing public key is missing")
    run_tool(
        [
            args.openssl,
            "dgst",
            "-sha256",
            "-verify",
            str(args.public_key),
            "-signature",
            str(signature),
            str(metadata_path),
        ],
        "pearl-release.json signature verification",
    )
    try:
        metadata = json.loads(metadata_path.read_text(encoding="utf-8"))
    except (OSError, UnicodeDecodeError, json.JSONDecodeError) as exc:
        fail(f"pearl-release.json is invalid: {exc}")
    if not isinstance(metadata, dict) or metadata.get("schema_version") != 1:
        fail("pearl-release.json has unsupported schema")
    tag = metadata.get("tag")
    if not isinstance(tag, str) or not re.fullmatch(r"v[0-9]+\.[0-9]+\.[0-9]+", tag):
        fail("pearl-release.json tag is invalid")
    if "provider_code_identity" not in metadata:
        fail("pearl-release.json does not carry provider_code_identity")
    identity = validate_identity(
        metadata["provider_code_identity"],
        tag=tag,
        binary_version=metadata.get("provider_advertised_version"),
    )
    lines = [f"# provider_code_identity from signed pearl-release.json {tag} ({identity['asset']})"]
    for row in identity["slices"]:
        lines += [
            f"- team_id: {identity['team_id']}",
            f"  signing_identifier: {identity['signing_identifier']}",
            f"  code_cdhash: {row['code_cdhash']}",
            f"  binary_version: \"{identity['binary_version']}\"",
        ]
        if expires_at is not None:
            lines.append(f"  expires_at: \"{expires_at}\"")
    return "\n".join(lines) + "\n"


def parser() -> argparse.ArgumentParser:
    root = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    root.add_argument("--tarball", type=pathlib.Path, help="final shipped macprovider-cli-<tag>-darwin-arm64.tar.gz")
    root.add_argument("--member", default=MEMBER, help="tar member holding the CLI (default: macprovider-cli)")
    root.add_argument("--binary-version", help="provider binaryVersion X.Y.Z")
    root.add_argument("--expected-team-id", help="release Team ID; defaults to $APPLE_NOTARY_TEAM_ID")
    root.add_argument("--expect-sha256", help="required sha256 of the extracted CLI")
    root.add_argument("--output", type=pathlib.Path, help="write JSON here instead of stdout")
    root.add_argument("--emit-approved-identity", action="store_true")
    root.add_argument("--pearl-release-json", type=pathlib.Path)
    root.add_argument("--signature", type=pathlib.Path, help="default: <pearl-release.json>.sig")
    root.add_argument("--public-key", type=pathlib.Path, default=DEFAULT_PUBLIC_KEY)
    root.add_argument("--openssl", default="openssl")
    root.add_argument("--expires-at", help="optional RFC3339 expiry; omitted, the entry has none")
    return root


def main() -> None:
    args = parser().parse_args()
    try:
        if args.emit_approved_identity:
            sys.stdout.write(emit_approved_identity(args))
            return
        if args.member != MEMBER:
            fail("--member must be macprovider-cli")
        payload = json.dumps(derive(args), sort_keys=True, separators=(",", ":")) + "\n"
        if args.output is None:
            sys.stdout.write(payload)
            return
        descriptor = os.open(args.output, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o644)
        with os.fdopen(descriptor, "w", encoding="utf-8") as handle:
            handle.write(payload)
    except IdentityError as exc:
        raise SystemExit(f"provider-code-identity: {exc}") from exc


if __name__ == "__main__":
    main()
