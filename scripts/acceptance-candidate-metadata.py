#!/usr/bin/env python3
"""Build and verify the private, expiring acceptance-candidate trust envelope."""

from __future__ import annotations

import argparse
import base64
import datetime as dt
import hashlib
import json
import os
import pathlib
import re
import stat
import subprocess
import tarfile
import tempfile


UNSIGNED_SCHEMA = "macprovider.acceptance-unsigned-inputs.v1"
ACCEPTANCE_SCHEMA = "macprovider.acceptance-candidate.v1"
ACCEPTANCE_CHANNEL = "acceptance"
SIGNATURE_ALGORITHM = "ecdsa-p256-sha256"
KEY_ID = "macprovider-acceptance-p256-v1"
SIGNING_DOMAIN = b"macprovider.acceptance-candidate.v1\n"
HEX40 = re.compile(r"^[0-9a-f]{40}$")
HEX64 = re.compile(r"^[0-9a-f]{64}$")
TAG = re.compile(r"^v[0-9]+\.[0-9]+\.[0-9]+$")
SEMVER = re.compile(r"^[0-9]+\.[0-9]+\.[0-9]+$")
REPOSITORY = re.compile(r"^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$")
BRANCH_REF = re.compile(r"^refs/heads/[A-Za-z0-9](?:[A-Za-z0-9._/-]{0,252}[A-Za-z0-9._-])?$")
ASSET_NAME = re.compile(r"^[A-Za-z0-9][A-Za-z0-9._+-]{0,255}$")
RUN_ID = re.compile(r"^[1-9][0-9]*$")
MAX_JSON_BYTES = 1024 * 1024
MAX_VALIDITY = dt.timedelta(hours=24)
MIN_VALIDITY = dt.timedelta(minutes=5)
REQUIRED_UNSIGNED_NAMES = {
    "Malibu.app.tar.gz",
    "coordinator-cli-linux-amd64",
    "coordinator-linux-amd64",
    "gateway-linux-amd64",
    "release-toolchain.json",
}
CATALOG_NAMES = (
    "release.json",
    "trusted-keys.json",
    "tier2-catalog.json",
    "autotune-candidates.json",
    "autotune-candidates.json.sig",
    "demand-rank.json",
    "demand-rank.json.sig",
    "rate-card.json",
    "rate-card.json.sig",
)
LOCAL_COMPATIBILITY_NAMES = {
    "install.sh",
    "provider-launch-agent.plist.template",
    "updater-rollback.json",
    "watchdog-launch-agent.plist.template",
    "watchdog.sh",
}
OPTIONAL_BUNDLE_NAMES = {"mlx-swift_Cmlx.bundle", "swift-nio_NIOPosix.bundle"}


class MetadataError(RuntimeError):
    pass


def fail(message: str) -> None:
    raise MetadataError(message)


def exact_keys(value: dict, expected: set[str], label: str) -> None:
    if set(value) != expected:
        fail(f"{label}: fields differ from the supported contract")


def canonical_bytes(value: object) -> bytes:
    return (json.dumps(value, sort_keys=True, separators=(",", ":")) + "\n").encode("utf-8")


def read_regular(path: pathlib.Path, label: str, maximum: int | None = None) -> bytes:
    try:
        info = path.lstat()
    except OSError as exc:
        fail(f"{label}: cannot stat {path}: {exc}")
    if stat.S_ISLNK(info.st_mode) or not stat.S_ISREG(info.st_mode) or info.st_nlink != 1:
        fail(f"{label}: must be a regular non-symlink single-link file: {path}")
    if maximum is not None and not 0 < info.st_size <= maximum:
        fail(f"{label}: invalid size")
    try:
        return path.read_bytes()
    except OSError as exc:
        fail(f"{label}: cannot read {path}: {exc}")


def strict_json(path: pathlib.Path, label: str, *, catalog_release: bool = False) -> dict:
    data = read_regular(path, label, MAX_JSON_BYTES)

    def reject_pairs(pairs: list[tuple[str, object]]) -> dict:
        result: dict = {}
        for key, value in pairs:
            if key in result:
                fail(f"{label}: duplicate key {key!r}")
            result[key] = value
        return result

    try:
        value = json.loads(
            data.decode("utf-8"),
            object_pairs_hook=reject_pairs,
            parse_constant=lambda raw: fail(f"{label}: invalid number {raw}"),
            parse_float=lambda raw: fail(f"{label}: floating point is forbidden ({raw})"),
        )
    except (UnicodeDecodeError, json.JSONDecodeError) as exc:
        fail(f"{label}: invalid JSON: {exc}")
    if not isinstance(value, dict):
        fail(f"{label}: top level must be an object")
    expected = (
        json.dumps(value, indent=2, sort_keys=True).encode("utf-8") + b"\n"
        if catalog_release
        else canonical_bytes(value)
    )
    if data != expected:
        json_style = "indented" if catalog_release else "compact"
        fail(f"{label}: must be canonical sorted {json_style} JSON with one trailing newline")
    return value


def atomic_write(path: pathlib.Path, data: bytes, mode: int = 0o644) -> None:
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
        os.chmod(temporary, mode)
        os.replace(temporary, path)
    finally:
        temporary.unlink(missing_ok=True)


def require_string(value: object, pattern: re.Pattern[str], label: str) -> str:
    if not isinstance(value, str) or not pattern.fullmatch(value):
        fail(f"{label}: invalid value")
    return value


def require_integer(value: object, label: str) -> int:
    if not isinstance(value, int) or isinstance(value, bool) or value <= 0:
        fail(f"{label}: must be a positive integer")
    return value


def require_run_id(value: object, label: str) -> str:
    if not isinstance(value, str) or not RUN_ID.fullmatch(value):
        fail(f"{label}: must be a positive decimal string")
    return value


def require_branch_ref(value: object, label: str) -> str:
    ref = require_string(value, BRANCH_REF, label)
    branch = ref.removeprefix("refs/heads/")
    forbidden = ("..", "@{", "//")
    if (
        branch == "@"
        or any(token in branch for token in forbidden)
        or any(character in branch for character in " ~^:?*[\\")
        or branch.endswith(("/", "."))
        or any(not component or component.startswith(".") or component.endswith(".lock") for component in branch.split("/"))
    ):
        fail(f"{label}: invalid git branch ref")
    return ref


def sha256(path: pathlib.Path, label: str) -> str:
    read_regular(path, label)
    digest = hashlib.sha256()
    with path.open("rb") as source:
        for chunk in iter(lambda: source.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


def parse_timestamp(value: object, label: str) -> dt.datetime:
    if not isinstance(value, str) or not re.fullmatch(r"\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}Z", value):
        fail(f"{label}: must be an RFC3339 UTC timestamp at second precision")
    try:
        return dt.datetime.strptime(value, "%Y-%m-%dT%H:%M:%SZ").replace(tzinfo=dt.timezone.utc)
    except ValueError as exc:
        fail(f"{label}: invalid timestamp: {exc}")


def parse_assets(values: list[str], label: str) -> dict[str, pathlib.Path]:
    result: dict[str, pathlib.Path] = {}
    for value in values:
        name, separator, raw_path = value.partition("=")
        if not separator or not ASSET_NAME.fullmatch(name) or name in result or not raw_path:
            fail(f"{label}: invalid or duplicate asset mapping {value!r}")
        path = pathlib.Path(raw_path)
        if path.name != name:
            fail(f"{label}: asset path basename must equal {name!r}")
        result[name] = path
    return result


def validate_unsigned(value: dict, assets: dict[str, pathlib.Path]) -> None:
    exact_keys(
        value,
        {
            "assets",
            "candidate_commit",
            "candidate_ref",
            "control_commit",
            "provider_admission_policy",
            "repository",
            "schema_version",
            "tag",
        },
        "unsigned manifest",
    )
    if value["schema_version"] != UNSIGNED_SCHEMA:
        fail("unsigned manifest: unsupported schema")
    require_string(value["repository"], REPOSITORY, "unsigned repository")
    require_string(value["tag"], TAG, "unsigned tag")
    require_branch_ref(value["candidate_ref"], "unsigned candidate ref")
    require_string(value["candidate_commit"], HEX40, "unsigned candidate commit")
    require_string(value["control_commit"], HEX40, "unsigned control commit")
    if value["provider_admission_policy"] not in {"bridge_required", "strict_post_migration"}:
        fail("unsigned manifest: unsupported provider admission policy")
    expected_names = REQUIRED_UNSIGNED_NAMES | {f"phase3-binary-m4-{value['tag']}.tar.gz"}
    if set(assets) != expected_names:
        fail("unsigned manifest: supplied assets differ from the exact build boundary")
    rows = value["assets"]
    if not isinstance(rows, dict) or set(rows) != expected_names:
        fail("unsigned manifest: recorded assets differ from the exact build boundary")
    for name, path in assets.items():
        if rows[name] != sha256(path, f"unsigned asset {name}"):
            fail(f"unsigned manifest: digest mismatch for {name}")


def command_build_unsigned(args: argparse.Namespace) -> None:
    assets = parse_assets(args.asset, "unsigned assets")
    value = {
        "assets": {name: sha256(path, f"unsigned asset {name}") for name, path in sorted(assets.items())},
        "candidate_commit": require_string(args.candidate_commit, HEX40, "candidate commit"),
        "candidate_ref": require_branch_ref(args.candidate_ref, "candidate ref"),
        "control_commit": require_string(args.control_commit, HEX40, "control commit"),
        "provider_admission_policy": args.provider_admission_policy,
        "repository": require_string(args.repository, REPOSITORY, "repository"),
        "schema_version": UNSIGNED_SCHEMA,
        "tag": require_string(args.tag, TAG, "tag"),
    }
    validate_unsigned(value, assets)
    atomic_write(args.output, canonical_bytes(value))


def command_verify_unsigned(args: argparse.Namespace) -> None:
    assets = parse_assets(args.asset, "unsigned assets")
    value = strict_json(args.input, "unsigned manifest")
    validate_unsigned(value, assets)
    checks = (
        (args.repository, value["repository"], "repository"),
        (args.tag, value["tag"], "tag"),
        (args.candidate_ref, value["candidate_ref"], "candidate ref"),
        (args.candidate_commit, value["candidate_commit"], "candidate commit"),
        (args.control_commit, value["control_commit"], "control commit"),
        (args.provider_admission_policy, value["provider_admission_policy"], "provider admission policy"),
    )
    for expected, actual, label in checks:
        if expected != actual:
            fail(f"unsigned manifest: {label} mismatch")


def validated_compatibility_manifest(path: pathlib.Path) -> tuple[dict, str]:
    value = strict_json(path, "compatibility manifest")
    exact_keys(value, {"schema_version", "signatures", "signed"}, "compatibility manifest")
    if value["schema_version"] != "macprovider.compatibility-set-envelope.v1":
        fail("compatibility manifest: unsupported schema")
    signed = value["signed"]
    if not isinstance(signed, dict):
        fail("compatibility manifest: missing signed payload")
    release = signed.get("release")
    if not isinstance(release, dict):
        fail("compatibility manifest: missing release identity")
    exact_keys(release, {"commit", "repository", "tag", "version"}, "compatibility release")
    repository = require_string(release["repository"], REPOSITORY, "compatibility repository")
    tag = require_string(release["tag"], TAG, "compatibility tag")
    commit = require_string(release["commit"], HEX40, "compatibility commit")
    identity = f"{repository}:{tag}@{commit}"
    if signed.get("compatibility_set_id") != identity:
        fail("compatibility manifest: compatibility set id mismatch")
    return signed, identity


def compatibility_identity(path: pathlib.Path) -> str:
    _, identity = validated_compatibility_manifest(path)
    return identity


def command_compatibility_id(args: argparse.Namespace) -> None:
    print(compatibility_identity(args.input))


def compatibility_provider_cli_version(path: pathlib.Path, expected_identity: str) -> str:
    signed, identity = validated_compatibility_manifest(path)
    if identity != expected_identity:
        fail("compatibility manifest: release identity mismatch")
    components = signed.get("components")
    if not isinstance(components, dict):
        fail("compatibility manifest: missing components")
    provider_cli = components.get("provider_cli")
    if not isinstance(provider_cli, dict):
        fail("compatibility manifest: missing provider CLI component")
    return require_string(
        provider_cli.get("version"),
        SEMVER,
        "compatibility provider CLI version",
    )


def build_pearl(args: argparse.Namespace) -> dict:
    repository = require_string(args.repository, REPOSITORY, "repository")
    tag = require_string(args.tag, TAG, "tag")
    commit = require_string(args.commit, HEX40, "commit")
    compatibility_set_id = f"{repository}:{tag}@{commit}"
    if args.runtime_only and args.catalog_directory is not None:
        fail("Pearl runtime metadata: --runtime-only cannot bind --catalog-directory")
    if not args.runtime_only and args.catalog_directory is None:
        fail("Pearl runtime metadata: --catalog-directory is required unless --runtime-only is set")
    if not args.runtime_only and args.compatibility_manifest is None:
        fail("Pearl runtime metadata: --compatibility-manifest is required for catalog-bound releases")
    if not args.runtime_only and args.provider_advertised_version is not None:
        fail("Pearl runtime metadata: catalog-bound releases derive provider version from --compatibility-manifest")
    if args.runtime_only and args.compatibility_manifest is not None:
        fail("Pearl runtime metadata: --runtime-only cannot bind --compatibility-manifest")
    if args.runtime_only and args.provider_advertised_version is not None:
        fail("Pearl runtime metadata: --runtime-only cannot bind --provider-advertised-version")
    if args.runtime_only and args.provider_admission_policy != "strict_post_migration":
        fail("Pearl runtime metadata: --runtime-only cannot bind provider admission bridge policy")
    provider_cli_version = None
    if not args.runtime_only:
        provider_cli_version = compatibility_provider_cli_version(
            args.compatibility_manifest,
            compatibility_set_id,
        )
    catalog_metadata = None
    release_lane = "pearl_runtime"
    if args.catalog_directory is not None:
        catalog = args.catalog_directory
        files = {name: sha256(catalog / name, f"catalog {name}") for name in CATALOG_NAMES}
        release = strict_json(catalog / "release.json", "catalog release", catalog_release=True)
        release_id = release.get("release_id")
        policy_version = release.get("policy_version")
        if not isinstance(release_id, str) or not release_id or not isinstance(policy_version, str) or not policy_version:
            fail("catalog release: release_id and policy_version are required")
        catalog_metadata = {"files": files, "policy_version": policy_version, "release_id": release_id}
        release_lane = "pearl_runtime_catalog"
    rollout = {
        "bridge_required": {"bridge_duration_s": 86400, "enforce_provider_admission": False, "mode": "bridge_required"},
        "strict_post_migration": {"bridge_duration_s": 0, "enforce_provider_admission": True, "mode": "strict_post_migration"},
    }[args.provider_admission_policy]
    metadata = {
        "architecture": "linux-amd64",
        "catalog": catalog_metadata,
        "channel": args.channel,
        "commit": commit,
        "components": {
            "coordinator": {
                "asset": args.coordinator.name,
                "embedded_version": tag,
                "sha256": sha256(args.coordinator, "coordinator"),
            },
            "gateway": {
                "asset": args.gateway.name,
                "embedded_version": tag,
                "sha256": sha256(args.gateway, "gateway"),
            },
        },
        "operator_artifacts": {
            "coordinator_cli": {
                "asset": args.coordinator_cli.name,
                "sha256": sha256(args.coordinator_cli, "coordinator CLI"),
            }
        },
        "provider_admission_rollout": rollout,
        "release_lane": release_lane,
        "release_version": tag.removeprefix("v"),
        "repository": repository,
        "schema_version": 1,
        "tag": tag,
    }
    if provider_cli_version is not None:
        metadata["provider_advertised_version"] = provider_cli_version
    return metadata


def command_build_pearl(args: argparse.Namespace) -> None:
    atomic_write(args.output, canonical_bytes(build_pearl(args)))


def command_build_checksums(args: argparse.Namespace) -> None:
    assets = parse_assets(args.asset, "checksum assets")
    if not assets:
        fail("checksum assets: at least one asset is required")
    rows = [f"{sha256(path, f'checksum asset {name}')}  {name}\n" for name, path in sorted(assets.items())]
    atomic_write(args.output, "".join(rows).encode("ascii"))


def command_validate_archive(args: argparse.Namespace) -> None:
    read_regular(args.input, "archive")
    seen: set[str] = set()
    total_size = 0
    try:
        with tarfile.open(args.input, "r:gz") as archive:
            members = archive.getmembers()
    except (OSError, tarfile.TarError) as exc:
        fail(f"archive: invalid gzip tar: {exc}")
    if not members or len(members) > 50_000:
        fail("archive: invalid member count")
    for member in members:
        raw = member.name
        path = pathlib.PurePosixPath(raw)
        normalized_parts = tuple(part for part in path.parts if part not in ("", "."))
        if path.is_absolute() or not normalized_parts or ".." in normalized_parts:
            fail(f"archive: unsafe member path {raw!r}")
        normalized = "/".join(normalized_parts)
        if normalized in seen:
            fail(f"archive: duplicate member {normalized!r}")
        seen.add(normalized)
        if member.isdir():
            continue
        if member.isfile():
            if member.size < 0:
                fail(f"archive: invalid size for {normalized!r}")
            total_size += member.size
            if total_size > 4 * 1024 * 1024 * 1024:
                fail("archive: expanded contents exceed 4 GiB")
            continue
        if member.issym() or member.islnk():
            if args.forbid_links:
                fail(f"archive: links are forbidden: {normalized!r}")
            target = pathlib.PurePosixPath(member.linkname)
            if target.is_absolute():
                fail(f"archive: absolute link target for {normalized!r}")
            base = pathlib.PurePosixPath(normalized).parent if member.issym() else pathlib.PurePosixPath()
            depth = 0
            for part in (base / target).parts:
                if part in ("", "."):
                    continue
                if part == "..":
                    depth -= 1
                else:
                    depth += 1
                if depth < 0:
                    fail(f"archive: escaping link target for {normalized!r}")
            continue
        fail(f"archive: unsupported member type for {normalized!r}")


def command_validate_provider_payload(args: argparse.Namespace) -> None:
    root = args.directory
    if not root.is_dir() or root.is_symlink():
        fail("provider payload: directory is absent or unsafe")
    required_files = {
        "THIRD-PARTY-NOTICES.txt",
        "compatibility-set.json",
        "macprovider-cli",
        "mlx.metallib",
    }
    expected_directories = {"catalog-release", "compatibility-set-local"}
    top_entries = {path.name: path for path in root.iterdir()}
    allowed_top = required_files | expected_directories | OPTIONAL_BUNDLE_NAMES
    unknown = set(top_entries) - allowed_top
    if unknown:
        fail(f"provider payload: unexpected top-level members {sorted(unknown)}")
    for name in required_files:
        read_regular(root / name, f"provider payload {name}")
    for name in expected_directories:
        path = root / name
        if not path.is_dir() or path.is_symlink():
            fail(f"provider payload: required directory is absent or unsafe: {name}")
    catalog_entries = {path.name for path in (root / "catalog-release").iterdir()}
    if catalog_entries != set(CATALOG_NAMES):
        fail("provider payload: catalog-release members differ from the exact compatibility set")
    for name in CATALOG_NAMES:
        read_regular(root / "catalog-release" / name, f"provider catalog {name}")
    local_entries = {path.name for path in (root / "compatibility-set-local").iterdir()}
    if local_entries != LOCAL_COMPATIBILITY_NAMES:
        fail("provider payload: local compatibility members differ from the exact compatibility set")
    for name in LOCAL_COMPATIBILITY_NAMES:
        read_regular(root / "compatibility-set-local" / name, f"provider local compatibility {name}")
    for name in OPTIONAL_BUNDLE_NAMES:
        path = root / name
        if path.exists() and (not path.is_dir() or path.is_symlink()):
            fail(f"provider payload: optional bundle is unsafe: {name}")
    for path in root.rglob("*"):
        info = path.lstat()
        if stat.S_ISLNK(info.st_mode) or not (stat.S_ISREG(info.st_mode) or stat.S_ISDIR(info.st_mode)):
            fail(f"provider payload: unsupported member type: {path.relative_to(root)}")


def validate_acceptance(value: dict, checksums_path: pathlib.Path, now: dt.datetime) -> None:
    exact_keys(
        value,
        {
            "candidate_commit",
            "candidate_ref",
            "channel",
            "checksums",
            "compatibility_set_id",
            "control_commit",
            "expires_at",
            "issued_at",
            "repository",
            "run_id",
            "run_attempt",
            "schema_version",
            "signing",
            "tag",
        },
        "acceptance metadata",
    )
    if value["schema_version"] != ACCEPTANCE_SCHEMA or value["channel"] != ACCEPTANCE_CHANNEL:
        fail("acceptance metadata: channel or schema mismatch")
    repository = require_string(value["repository"], REPOSITORY, "acceptance repository")
    tag = require_string(value["tag"], TAG, "acceptance tag")
    require_branch_ref(value["candidate_ref"], "acceptance candidate ref")
    commit = require_string(value["candidate_commit"], HEX40, "acceptance candidate commit")
    require_string(value["control_commit"], HEX40, "acceptance control commit")
    if value["compatibility_set_id"] != f"{repository}:{tag}@{commit}":
        fail("acceptance metadata: compatibility set id mismatch")
    require_run_id(value["run_id"], "acceptance run id")
    require_integer(value["run_attempt"], "acceptance run attempt")
    signing = value["signing"]
    if signing != {"algorithm": SIGNATURE_ALGORITHM, "key_id": KEY_ID}:
        fail("acceptance metadata: signing contract mismatch")
    checksums = value["checksums"]
    if not isinstance(checksums, dict):
        fail("acceptance metadata: checksums must be an object")
    exact_keys(checksums, {"name", "sha256"}, "acceptance checksums")
    if checksums["name"] != "checksums.txt":
        fail("acceptance metadata: unsupported checksums filename")
    require_string(checksums["sha256"], HEX64, "acceptance checksums digest")
    if checksums["sha256"] != sha256(checksums_path, "acceptance checksums"):
        fail("acceptance metadata: checksums digest mismatch")
    issued = parse_timestamp(value["issued_at"], "acceptance issued_at")
    expires = parse_timestamp(value["expires_at"], "acceptance expires_at")
    if not MIN_VALIDITY <= expires - issued <= MAX_VALIDITY:
        fail("acceptance metadata: validity must be between 5 minutes and 24 hours")
    if now < issued - dt.timedelta(minutes=5):
        fail("acceptance metadata: issued_at is unreasonably in the future")
    if now > expires:
        fail("acceptance metadata: candidate has expired")


def openssl(arguments: list[str], label: str) -> bytes:
    try:
        result = subprocess.run(arguments, stdout=subprocess.PIPE, stderr=subprocess.PIPE, timeout=20, check=False)
    except subprocess.TimeoutExpired:
        fail(f"{label}: openssl timed out")
    if result.returncode != 0:
        fail(f"{label}: openssl failed: {result.stderr.decode('utf-8', errors='replace').strip()}")
    return result.stdout


def signed_message(value: dict) -> bytes:
    return SIGNING_DOMAIN + canonical_bytes(value)


def command_sign_acceptance(args: argparse.Namespace) -> None:
    compatibility_set_id = compatibility_identity(args.compatibility_manifest)
    value = {
        "candidate_commit": require_string(args.candidate_commit, HEX40, "candidate commit"),
        "candidate_ref": require_branch_ref(args.candidate_ref, "candidate ref"),
        "channel": ACCEPTANCE_CHANNEL,
        "checksums": {
            "name": "checksums.txt",
            "sha256": sha256(args.checksums, "acceptance checksums"),
        },
        "compatibility_set_id": compatibility_set_id,
        "control_commit": require_string(args.control_commit, HEX40, "control commit"),
        "expires_at": args.expires_at,
        "issued_at": args.issued_at,
        "repository": require_string(args.repository, REPOSITORY, "repository"),
        "run_id": require_run_id(args.run_id, "run id"),
        "run_attempt": require_integer(args.run_attempt, "run attempt"),
        "schema_version": ACCEPTANCE_SCHEMA,
        "signing": {"algorithm": SIGNATURE_ALGORITHM, "key_id": KEY_ID},
        "tag": require_string(args.tag, TAG, "tag"),
    }
    now = parse_timestamp(args.issued_at, "issued_at")
    validate_acceptance(value, args.checksums, now)
    private_key = read_regular(args.private_key, "acceptance private key", 64 * 1024)
    with tempfile.TemporaryDirectory(prefix="acceptance-sign.") as directory:
        root = pathlib.Path(directory)
        key = root / "private.pem"
        message = root / "message"
        signature = root / "signature.der"
        key.write_bytes(private_key)
        os.chmod(key, 0o600)
        message.write_bytes(signed_message(value))
        openssl([args.openssl, "dgst", "-sha256", "-sign", str(key), "-out", str(signature), str(message)], "acceptance signing")
        encoded = base64.b64encode(read_regular(signature, "acceptance signature", 256)) + b"\n"
    atomic_write(args.output, canonical_bytes(value))
    atomic_write(args.signature, encoded)


def command_verify_acceptance(args: argparse.Namespace) -> None:
    value = strict_json(args.input, "acceptance metadata")
    now = parse_timestamp(args.now, "verification time") if args.now else dt.datetime.now(dt.timezone.utc).replace(microsecond=0)
    validate_acceptance(value, args.checksums, now)
    encoded = read_regular(args.signature, "acceptance signature", 1024).strip()
    try:
        signature = base64.b64decode(encoded, validate=True)
    except ValueError as exc:
        fail(f"acceptance signature: invalid base64: {exc}")
    if base64.b64encode(signature) != encoded or not 64 <= len(signature) <= 80:
        fail("acceptance signature: invalid P-256 DER encoding")
    public_key = read_regular(args.public_key, "acceptance public key", 64 * 1024)
    with tempfile.TemporaryDirectory(prefix="acceptance-verify.") as directory:
        root = pathlib.Path(directory)
        key = root / "public.pem"
        message = root / "message"
        signature_path = root / "signature.der"
        key.write_bytes(public_key)
        message.write_bytes(signed_message(value))
        signature_path.write_bytes(signature)
        openssl(
            [args.openssl, "dgst", "-sha256", "-verify", str(key), "-signature", str(signature_path), str(message)],
            "acceptance verification",
        )
    expected = (
        (args.repository, value["repository"], "repository"),
        (args.tag, value["tag"], "tag"),
        (args.candidate_ref, value["candidate_ref"], "candidate ref"),
        (args.candidate_commit, value["candidate_commit"], "candidate commit"),
        (args.control_commit, value["control_commit"], "control commit"),
        (args.run_id, value["run_id"], "run id"),
        (args.run_attempt, value["run_attempt"], "run attempt"),
    )
    for wanted, actual, label in expected:
        if wanted is not None and wanted != actual:
            fail(f"acceptance metadata: {label} differs from expected value")


def add_identity(parser: argparse.ArgumentParser) -> None:
    parser.add_argument("--repository", required=True)
    parser.add_argument("--tag", required=True)
    parser.add_argument("--candidate-ref", required=True)
    parser.add_argument("--candidate-commit", required=True)
    parser.add_argument("--control-commit", required=True)
    parser.add_argument("--provider-admission-policy", choices=("bridge_required", "strict_post_migration"), required=True)


def parser() -> argparse.ArgumentParser:
    root = argparse.ArgumentParser(description=__doc__)
    commands = root.add_subparsers(dest="command", required=True)

    build_unsigned = commands.add_parser("build-unsigned")
    add_identity(build_unsigned)
    build_unsigned.add_argument("--asset", action="append", default=[])
    build_unsigned.add_argument("--output", required=True, type=pathlib.Path)
    build_unsigned.set_defaults(handler=command_build_unsigned)

    verify_unsigned = commands.add_parser("verify-unsigned")
    add_identity(verify_unsigned)
    verify_unsigned.add_argument("--asset", action="append", default=[])
    verify_unsigned.add_argument("--input", required=True, type=pathlib.Path)
    verify_unsigned.set_defaults(handler=command_verify_unsigned)

    compatibility = commands.add_parser("compatibility-id")
    compatibility.add_argument("--input", required=True, type=pathlib.Path)
    compatibility.set_defaults(handler=command_compatibility_id)

    pearl = commands.add_parser("build-pearl")
    pearl.add_argument("--repository", required=True)
    pearl.add_argument("--tag", required=True)
    pearl.add_argument("--commit", required=True)
    pearl.add_argument("--compatibility-manifest", type=pathlib.Path)
    pearl.add_argument("--provider-advertised-version")
    pearl.add_argument("--provider-admission-policy", choices=("bridge_required", "strict_post_migration"), required=True)
    pearl.add_argument("--channel", choices=("private_acceptance", "production"), default="private_acceptance")
    pearl.add_argument("--catalog-directory", type=pathlib.Path)
    pearl.add_argument("--runtime-only", action="store_true")
    pearl.add_argument("--coordinator", required=True, type=pathlib.Path)
    pearl.add_argument("--coordinator-cli", required=True, type=pathlib.Path)
    pearl.add_argument("--gateway", required=True, type=pathlib.Path)
    pearl.add_argument("--output", required=True, type=pathlib.Path)
    pearl.set_defaults(handler=command_build_pearl)

    checksums = commands.add_parser("build-checksums")
    checksums.add_argument("--asset", action="append", default=[])
    checksums.add_argument("--output", required=True, type=pathlib.Path)
    checksums.set_defaults(handler=command_build_checksums)

    archive = commands.add_parser("validate-archive")
    archive.add_argument("--input", required=True, type=pathlib.Path)
    archive.add_argument("--forbid-links", action="store_true")
    archive.set_defaults(handler=command_validate_archive)

    provider_payload = commands.add_parser("validate-provider-payload")
    provider_payload.add_argument("--directory", required=True, type=pathlib.Path)
    provider_payload.set_defaults(handler=command_validate_provider_payload)

    sign = commands.add_parser("sign")
    sign.add_argument("--repository", required=True)
    sign.add_argument("--tag", required=True)
    sign.add_argument("--candidate-ref", required=True)
    sign.add_argument("--candidate-commit", required=True)
    sign.add_argument("--control-commit", required=True)
    sign.add_argument("--run-id", required=True)
    sign.add_argument("--run-attempt", required=True, type=int)
    sign.add_argument("--compatibility-manifest", required=True, type=pathlib.Path)
    sign.add_argument("--checksums", required=True, type=pathlib.Path)
    sign.add_argument("--issued-at", required=True)
    sign.add_argument("--expires-at", required=True)
    sign.add_argument("--private-key", required=True, type=pathlib.Path)
    sign.add_argument("--openssl", default="openssl")
    sign.add_argument("--output", required=True, type=pathlib.Path)
    sign.add_argument("--signature", required=True, type=pathlib.Path)
    sign.set_defaults(handler=command_sign_acceptance)

    verify = commands.add_parser("verify")
    verify.add_argument("--input", required=True, type=pathlib.Path)
    verify.add_argument("--signature", required=True, type=pathlib.Path)
    verify.add_argument("--public-key", required=True, type=pathlib.Path)
    verify.add_argument("--checksums", required=True, type=pathlib.Path)
    verify.add_argument("--repository")
    verify.add_argument("--tag")
    verify.add_argument("--candidate-ref")
    verify.add_argument("--candidate-commit")
    verify.add_argument("--control-commit")
    verify.add_argument("--run-id")
    verify.add_argument("--run-attempt", type=int)
    verify.add_argument("--now")
    verify.add_argument("--openssl", default="openssl")
    verify.set_defaults(handler=command_verify_acceptance)

    return root


def main() -> None:
    args = parser().parse_args()
    try:
        args.handler(args)
    except (KeyError, MetadataError) as exc:
        raise SystemExit(f"acceptance-candidate-metadata: {exc}") from exc


if __name__ == "__main__":
    main()
