#!/usr/bin/env python3
"""Fail-closed verification for promoting an exact private acceptance set."""

from __future__ import annotations

import argparse
import hashlib
import json
import pathlib
import re
import stat
import subprocess


HEX40 = re.compile(r"^[0-9a-f]{40}$")
HEX64 = re.compile(r"^[0-9a-f]{64}$")
TAG = re.compile(r"^v[0-9]+\.[0-9]+\.[0-9]+$")
SAFE_NAME = re.compile(r"^[A-Za-z0-9][A-Za-z0-9._+-]{0,255}$")
WORKFLOW_PATH = ".github/workflows/acceptance-candidate.yml"
CONTROL_NAMES = {
    "acceptance-candidate.json",
    "acceptance-candidate.json.sig",
    "checksums.txt",
    "release-assets.txt",
}


def fail(message: str) -> None:
    raise SystemExit(f"verify-acceptance-promotion: {message}")


def load_json(path: pathlib.Path, label: str) -> dict:
    try:
        value = json.loads(path.read_text(encoding="utf-8"))
    except (OSError, UnicodeDecodeError, json.JSONDecodeError) as exc:
        fail(f"{label} is invalid: {exc}")
    if not isinstance(value, dict):
        fail(f"{label} must be an object")
    return value


def regular(path: pathlib.Path, label: str) -> None:
    try:
        info = path.lstat()
    except OSError as exc:
        fail(f"{label} cannot be inspected: {exc}")
    if stat.S_ISLNK(info.st_mode) or not stat.S_ISREG(info.st_mode) or info.st_nlink != 1:
        fail(f"{label} must be a regular non-symlink single-link file")


def sha256(path: pathlib.Path) -> str:
    regular(path, str(path))
    digest = hashlib.sha256()
    with path.open("rb") as source:
        for chunk in iter(lambda: source.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


def verify_run(args: argparse.Namespace) -> None:
    run = load_json(args.run_json, "workflow run")
    artifacts = load_json(args.artifacts_json, "workflow artifacts")
    if run.get("id") != args.run_id:
        fail("workflow run id differs from the requested run")
    if run.get("event") != "workflow_dispatch" or run.get("status") != "completed" or run.get("conclusion") != "success":
        fail("workflow run is not a successful completed manual dispatch")
    if run.get("path") != WORKFLOW_PATH:
        fail("workflow run path is not the reviewed acceptance workflow")
    if run.get("head_branch") != "main" or run.get("head_sha") != args.control_sha:
        fail("workflow control source differs from the reviewed main commit")
    if run.get("run_attempt") != args.run_attempt or type(args.run_attempt) is not int or args.run_attempt <= 0:
        fail("workflow run attempt differs from the signed acceptance envelope")
    repository = run.get("repository")
    if not isinstance(repository, dict) or repository.get("full_name") != args.repository:
        fail("workflow repository differs from the requested repository")
    rows = artifacts.get("artifacts")
    if type(artifacts.get("total_count")) is not int or not isinstance(rows, list):
        fail("workflow artifact response is malformed")
    expected_name = f"acceptance-candidate-{args.candidate_sha}"
    matches = [row for row in rows if isinstance(row, dict) and row.get("name") == expected_name]
    if len(matches) != 1:
        fail("workflow must expose exactly one matching acceptance artifact")
    row = matches[0]
    if (
        not isinstance(row, dict)
        or row.get("name") != expected_name
        or row.get("expired") is not False
        or row.get("workflow_run", {}).get("id") != args.run_id
    ):
        fail("workflow artifact identity is absent, expired, or ambiguous")


def read_asset_names(path: pathlib.Path) -> list[str]:
    regular(path, "release asset selector")
    try:
        raw = path.read_text(encoding="ascii")
    except (OSError, UnicodeDecodeError) as exc:
        fail(f"release asset selector is invalid: {exc}")
    names = raw.splitlines()
    if not names or raw != "".join(f"{name}\n" for name in names):
        fail("release asset selector must contain newline-terminated names")
    if names != sorted(names) or len(names) != len(set(names)):
        fail("release asset selector must be sorted and unique")
    if not all(SAFE_NAME.fullmatch(name) for name in names):
        fail("release asset selector contains an unsafe name")
    if any(name in CONTROL_NAMES or name == "checksums.txt.sig" for name in names):
        fail("release asset selector crosses the acceptance control boundary")
    return names


def verify_directory(args: argparse.Namespace) -> None:
    root = args.directory
    if not root.is_dir() or root.is_symlink():
        fail("candidate directory is absent or unsafe")
    entries = list(root.iterdir())
    if any(not path.is_file() for path in entries):
        fail("candidate directory contains a nested or non-file entry")
    names = [path.name for path in entries]
    if len(names) != len(set(names)) or any(not SAFE_NAME.fullmatch(name) for name in names):
        fail("candidate directory has duplicate or unsafe basenames")
    release_names = read_asset_names(root / "release-assets.txt")
    required_release_names = {
        f"macprovider-cli-{args.tag}-darwin-arm64.tar.gz",
        f"Malibu-{args.tag}.dmg",
        "release-toolchain.json",
        "coordinator-linux-amd64",
        "coordinator-cli-linux-amd64",
        "gateway-linux-amd64",
        "compatibility-set.json",
        "release.json",
        "trusted-keys.json",
        "autotune-candidates.json",
        "autotune-candidates.json.sig",
        "demand-rank.json",
        "demand-rank.json.sig",
        "pearl-release.json",
        "pearl-release.json.sig",
        "compatibility-artifact-index.json",
        "release-provenance.json",
    }
    if set(release_names) != required_release_names:
        fail("release asset selector differs from the production compatibility inventory")
    expected = set(release_names) | CONTROL_NAMES
    if set(names) != expected:
        fail("candidate inventory has extra or missing files")
    for path in entries:
        regular(path, f"candidate asset {path.name}")
    checksums_digest = sha256(root / "checksums.txt")
    if checksums_digest != args.expected_checksums_sha256:
        fail("checksums.txt differs from the physically accepted digest")

    acceptance = load_json(root / "acceptance-candidate.json", "acceptance envelope")
    expected_values = {
        "repository": args.repository,
        "tag": args.tag,
        "candidate_commit": args.candidate_sha,
        "control_commit": args.control_sha,
        "run_id": str(args.run_id),
        "run_attempt": args.run_attempt,
        "channel": "acceptance",
    }
    for key, expected_value in expected_values.items():
        if acceptance.get(key) != expected_value:
            fail(f"acceptance envelope {key} differs from the promotion request")

    provenance = load_json(root / "release-provenance.json", "release provenance")
    if (
        provenance.get("repository") != args.repository
        or provenance.get("tag") != args.tag
        or provenance.get("commit") != args.candidate_sha
        or provenance.get("prerelease") is not False
    ):
        fail("release provenance is not bound to a stable production target")

    pearl = load_json(root / "pearl-release.json", "Pearl metadata")
    compatibility = load_json(root / "compatibility-set.json", "compatibility manifest")
    try:
        signed = compatibility["signed"]
        rollout = signed["components"]["coordinator_admission"]["rollout"]
        compatibility_release = signed["release"]
        provider_cli_version = signed["components"]["provider_cli"]["version"]
    except (KeyError, TypeError):
        fail("compatibility manifest lacks production release identity")
    if compatibility_release != {
        "commit": args.candidate_sha,
        "repository": args.repository,
        "tag": args.tag,
        "version": args.tag.removeprefix("v"),
    }:
        fail("compatibility manifest release identity differs from the promotion request")
    if pearl.get("channel") != "production":
        fail("Pearl metadata is not on the production updater channel")
    expected_pearl_identity = {
        "architecture": "linux-amd64",
        "commit": args.candidate_sha,
        "release_version": args.tag.removeprefix("v"),
        "repository": args.repository,
        "schema_version": 1,
        "tag": args.tag,
    }
    for key, expected_value in expected_pearl_identity.items():
        if pearl.get(key) != expected_value:
            fail(f"Pearl metadata {key} differs from the promotion request")
    if pearl.get("provider_advertised_version") != provider_cli_version:
        fail("Pearl metadata does not advertise the signed provider CLI version")
    if provider_cli_version != args.tag.removeprefix("v"):
        fail("production provider CLI version differs from the stable release version")
    if pearl.get("provider_admission_rollout") != rollout:
        fail("Pearl and compatibility admission policies differ")
    if rollout not in (
        {"bridge_duration_s": 86400, "enforce_provider_admission": False, "mode": "bridge_required"},
        {"bridge_duration_s": 0, "enforce_provider_admission": True, "mode": "strict_post_migration"},
    ):
        fail("provider admission policy is unsupported")
    expected_components = {
        "coordinator": ("coordinator-linux-amd64", args.tag),
        "gateway": ("gateway-linux-amd64", args.tag),
    }
    components = pearl.get("components")
    if not isinstance(components, dict) or set(components) != set(expected_components):
        fail("Pearl component inventory differs from the production release")
    for name, (asset_name, embedded_version) in expected_components.items():
        row = components.get(name)
        if row != {
            "asset": asset_name,
            "embedded_version": embedded_version,
            "sha256": sha256(root / asset_name),
        }:
            fail(f"Pearl {name} binding differs from the accepted asset")
    if pearl.get("operator_artifacts") != {
        "coordinator_cli": {
            "asset": "coordinator-cli-linux-amd64",
            "sha256": sha256(root / "coordinator-cli-linux-amd64"),
        }
    }:
        fail("Pearl operator artifact binding differs from the accepted asset")
    catalog_names = {
        "release.json",
        "trusted-keys.json",
        "autotune-candidates.json",
        "autotune-candidates.json.sig",
        "demand-rank.json",
        "demand-rank.json.sig",
    }
    catalog = pearl.get("catalog")
    if (
        not isinstance(catalog, dict)
        or set(catalog) != {"files", "policy_version", "release_id"}
        or not isinstance(catalog.get("policy_version"), str)
        or not catalog["policy_version"]
        or not isinstance(catalog.get("release_id"), str)
        or not catalog["release_id"]
        or catalog.get("files") != {name: sha256(root / name) for name in catalog_names}
    ):
        fail("Pearl catalog binding differs from the accepted assets")

    signature = root / "pearl-release.json.sig"
    regular(signature, "Pearl production signature")
    result = subprocess.run(
        [
            args.openssl,
            "dgst",
            "-sha256",
            "-verify",
            str(args.release_public_key),
            "-signature",
            str(signature),
            str(root / "pearl-release.json"),
        ],
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        check=False,
        timeout=20,
    )
    if result.returncode:
        fail("Pearl metadata signature is not valid for the production updater key")


def parser() -> argparse.ArgumentParser:
    root = argparse.ArgumentParser(description=__doc__)
    commands = root.add_subparsers(dest="command", required=True)
    run = commands.add_parser("verify-run")
    run.add_argument("--run-json", required=True, type=pathlib.Path)
    run.add_argument("--artifacts-json", required=True, type=pathlib.Path)
    run.add_argument("--repository", required=True)
    run.add_argument("--run-id", required=True, type=int)
    run.add_argument("--run-attempt", required=True, type=int)
    run.add_argument("--candidate-sha", required=True)
    run.add_argument("--control-sha", required=True)
    run.set_defaults(handler=verify_run)

    directory = commands.add_parser("verify-directory")
    directory.add_argument("--directory", required=True, type=pathlib.Path)
    directory.add_argument("--repository", required=True)
    directory.add_argument("--run-id", required=True, type=int)
    directory.add_argument("--run-attempt", required=True, type=int)
    directory.add_argument("--tag", required=True)
    directory.add_argument("--candidate-sha", required=True)
    directory.add_argument("--control-sha", required=True)
    directory.add_argument("--expected-checksums-sha256", required=True)
    directory.add_argument("--release-public-key", required=True, type=pathlib.Path)
    directory.add_argument("--openssl", default="openssl")
    directory.set_defaults(handler=verify_directory)
    return root


def main() -> None:
    args = parser().parse_args()
    if not TAG.fullmatch(getattr(args, "tag", "v0.0.0")):
        fail("invalid tag")
    for name in ("candidate_sha", "control_sha"):
        if not HEX40.fullmatch(getattr(args, name)):
            fail(f"invalid {name.replace('_', ' ')}")
    if hasattr(args, "expected_checksums_sha256") and not HEX64.fullmatch(args.expected_checksums_sha256):
        fail("invalid expected checksums digest")
    if not re.fullmatch(r"[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+", args.repository):
        fail("invalid repository")
    args.handler(args)


if __name__ == "__main__":
    main()
