#!/usr/bin/env python3
"""Build and optionally serve a measured Build 1 Lane A lab artifact feed.

This is an operator-local staging helper. It materializes the same
`/v1/catalog-artifacts` bytes consumed by `macprovider-cli models prepare`, but
only into a loopback directory/server. It never edits the committed catalog,
cuts a release, deploys Pearl, enables payouts, or activates production.
"""

from __future__ import annotations

import argparse
import copy
import hashlib
import importlib.util
import json
import os
import pathlib
import shutil
import stat
import subprocess
import sys
from http.server import SimpleHTTPRequestHandler, ThreadingHTTPServer
from typing import Any


ROOT = pathlib.Path(__file__).resolve().parents[1]
CATALOG_DIR = ROOT / "phase3-binary" / "catalog" / "autotune"
CANDIDATE_PATH = CATALOG_DIR / "autotune-candidates.json"
SOURCE_PATH = CATALOG_DIR / "autotune-artifacts-source.json"
TRUSTED_KEYS_PATH = CATALOG_DIR / "trusted-keys.json"
CATALOG_RELEASE_PATH = ROOT / "scripts" / "catalog-release.py"

BUILD1_CATALOG_KEY = "meta-llama/llama-3.2-3b-instruct"
DEFAULT_KEY_ID = "streamvc-autotune-static-v4"


class LabFeedError(RuntimeError):
    pass


def _load_catalog_release():
    spec = importlib.util.spec_from_file_location("catalog_release_for_build1_lab", CATALOG_RELEASE_PATH)
    if spec is None or spec.loader is None:
        raise LabFeedError(f"cannot load {CATALOG_RELEASE_PATH}")
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


catalog_release = _load_catalog_release()


def load_json(path: pathlib.Path) -> dict[str, Any]:
    try:
        value = json.loads(path.read_text(encoding="utf-8"))
    except OSError as exc:
        raise LabFeedError(f"read {path}: {exc}") from exc
    except json.JSONDecodeError as exc:
        raise LabFeedError(f"parse {path}: {exc}") from exc
    if not isinstance(value, dict):
        raise LabFeedError(f"{path} must contain a JSON object")
    return value


def write_json(path: pathlib.Path, value: dict[str, Any]) -> None:
    path.parent.mkdir(parents=True, mode=0o700, exist_ok=True)
    temporary = path.with_name("." + path.name + ".tmp")
    temporary.write_text(json.dumps(value, indent=2, sort_keys=True) + "\n", encoding="utf-8")
    os.replace(temporary, path)


def sha256_file(path: pathlib.Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as handle:
        for chunk in iter(lambda: handle.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


def parse_artifact_paths(values: list[str]) -> dict[str, pathlib.Path]:
    paths: dict[str, pathlib.Path] = {}
    for value in values:
        if "=" not in value:
            raise LabFeedError("--artifact-path must be CATALOG_KEY=PATH")
        key, raw_path = value.split("=", 1)
        key = key.strip()
        if not key:
            raise LabFeedError("--artifact-path contains an empty catalog key")
        path = pathlib.Path(raw_path).expanduser()
        if not path.is_absolute():
            path = pathlib.Path.cwd() / path
        paths[key] = path.resolve()
    return paths


def hf_snapshot_path(
    repo_id: str,
    revision: str,
    hf_home: pathlib.Path | None = None,
    *,
    use_default_cache: bool = True,
) -> pathlib.Path | None:
    homes: list[pathlib.Path] = []
    if hf_home is not None:
        homes.append(hf_home.expanduser())
    if use_default_cache:
        env_home = os.environ.get("HF_HOME")
        if env_home:
            homes.append(pathlib.Path(env_home).expanduser())
        homes.append(pathlib.Path.home() / ".cache" / "huggingface")

    owner, repo = repo_id.split("/", 1)
    cache_leaf = f"models--{owner}--{repo}"
    for home in homes:
        candidate = home / "hub" / cache_leaf / "snapshots" / revision
        if candidate.is_dir():
            return candidate.resolve()
    return None


def snapshot_download(repo_id: str, revision: str) -> pathlib.Path:
    code = (
        "from huggingface_hub import snapshot_download\n"
        "import sys\n"
        "print(snapshot_download(repo_id=sys.argv[1], revision=sys.argv[2]))\n"
    )
    completed = subprocess.run(
        [sys.executable, "-c", code, repo_id, revision],
        capture_output=True,
        text=True,
        check=False,
    )
    if completed.returncode != 0:
        detail = (completed.stderr or completed.stdout).strip()
        raise LabFeedError(f"huggingface snapshot_download failed for {repo_id}@{revision}: {detail}")
    path = pathlib.Path(completed.stdout.strip()).expanduser()
    if not path.is_dir():
        raise LabFeedError(f"huggingface snapshot_download returned a non-directory path for {repo_id}@{revision}")
    return path.resolve()


def logical_regular_file_bytes(root: pathlib.Path) -> int:
    def measured_file_size(path: pathlib.Path) -> int:
        try:
            st = path.lstat()
        except OSError as exc:
            raise LabFeedError(f"inspect {path}: {exc}") from exc
        if stat.S_ISLNK(st.st_mode):
            try:
                target = path.resolve(strict=True)
                target_st = target.stat()
            except OSError as exc:
                raise LabFeedError(f"artifact symlink target cannot be inspected: {path}: {exc}") from exc
            if not stat.S_ISREG(target_st.st_mode):
                raise LabFeedError(f"artifact symlink target must be a regular file: {path}")
            return target_st.st_size
        if not stat.S_ISREG(st.st_mode):
            raise LabFeedError(f"artifact tree contains a non-regular file: {path}")
        return st.st_size

    try:
        metadata = root.lstat()
    except OSError as exc:
        raise LabFeedError(f"inspect {root}: {exc}") from exc
    if stat.S_ISLNK(metadata.st_mode):
        return measured_file_size(root)
    if stat.S_ISREG(metadata.st_mode):
        return metadata.st_size
    if not stat.S_ISDIR(metadata.st_mode):
        raise LabFeedError(f"artifact path must be a regular file or directory: {root}")

    total = 0
    root_device = metadata.st_dev
    for current, dirs, files in os.walk(root, followlinks=False):
        current_path = pathlib.Path(current)
        kept_dirs: list[str] = []
        for name in dirs:
            path = current_path / name
            st = path.lstat()
            if stat.S_ISLNK(st.st_mode):
                raise LabFeedError(f"artifact tree must not contain symlink directories: {path}")
            if st.st_dev != root_device:
                raise LabFeedError(f"artifact tree must not cross filesystems: {path}")
            kept_dirs.append(name)
        dirs[:] = kept_dirs
        for name in files:
            path = current_path / name
            total += measured_file_size(path)
    if total <= 0:
        raise LabFeedError(f"artifact path measured zero bytes: {root}")
    return total


def primary_source_ref(source: dict[str, Any], key: str) -> tuple[str, str]:
    model = source["models"][key]
    artifact = model["artifacts"][model["primary_artifact_id"]]
    ref = artifact["source_ref"]
    return str(ref["repo_id"]), str(ref["revision"])


def measure_source(
    source: dict[str, Any],
    artifact_paths: dict[str, pathlib.Path],
    *,
    hf_home: pathlib.Path | None = None,
    download_missing: bool = False,
    use_default_cache: bool = True,
) -> tuple[dict[str, int], dict[str, str]]:
    measurements: dict[str, int] = {}
    roots: dict[str, str] = {}
    missing: list[str] = []
    for key in sorted(source["models"]):
        repo_id, revision = primary_source_ref(source, key)
        path = artifact_paths.get(key) or hf_snapshot_path(
            repo_id,
            revision,
            hf_home=hf_home,
            use_default_cache=use_default_cache,
        )
        if path is None and download_missing:
            path = snapshot_download(repo_id, revision)
        if path is None:
            missing.append(f"{key} ({repo_id}@{revision})")
            continue
        measurements[key] = logical_regular_file_bytes(path)
        roots[key] = str(path)
    if missing:
        raise LabFeedError(
            "measured artifact bytes are required for every published primary artifact; missing: "
            + "; ".join(missing)
        )
    return measurements, roots


def source_with_measurements(source: dict[str, Any], measurements: dict[str, int]) -> dict[str, Any]:
    measured = copy.deepcopy(source)
    missing = sorted(set(measured["models"]) - set(measurements))
    if missing:
        raise LabFeedError("missing measurements for: " + ", ".join(missing))
    for key, size in measurements.items():
        if not isinstance(size, int) or size <= 0:
            raise LabFeedError(f"measurement for {key} must be a positive integer")
        model = measured["models"][key]
        artifact = model["artifacts"][model["primary_artifact_id"]]
        artifact["size_bytes"] = size
    return measured


def measurement_manifest(
    source: dict[str, Any],
    source_path: pathlib.Path,
    candidate_path: pathlib.Path,
    measurements: dict[str, int],
    roots: dict[str, str],
) -> dict[str, Any]:
    return {
        "schema_version": "macprovider.build1-lane-a-lab-feed-measurements.v1",
        "production_activation": False,
        "source_sha256": sha256_file(source_path),
        "candidate_sha256": sha256_file(candidate_path),
        "measured_artifacts": {
            key: {
                "size_bytes": measurements[key],
                "source_path": roots[key],
                "source_ref": {
                    "repo_id": primary_source_ref(source, key)[0],
                    "revision": primary_source_ref(source, key)[1],
                },
            }
            for key in sorted(measurements)
        },
    }


def measurements_from_manifest(path: pathlib.Path, source: dict[str, Any], source_path: pathlib.Path, candidate_path: pathlib.Path) -> tuple[dict[str, int], dict[str, str]]:
    manifest = load_json(path)
    if manifest.get("schema_version") != "macprovider.build1-lane-a-lab-feed-measurements.v1":
        raise LabFeedError("measurement manifest has the wrong schema_version")
    if manifest.get("source_sha256") != sha256_file(source_path):
        raise LabFeedError("measurement manifest source_sha256 does not match the artifact source")
    if manifest.get("candidate_sha256") != sha256_file(candidate_path):
        raise LabFeedError("measurement manifest candidate_sha256 does not match the candidate catalog")
    measured = manifest.get("measured_artifacts")
    if not isinstance(measured, dict):
        raise LabFeedError("measurement manifest measured_artifacts must be an object")
    measurements: dict[str, int] = {}
    roots: dict[str, str] = {}
    for key in sorted(source["models"]):
        row = measured.get(key)
        if not isinstance(row, dict):
            raise LabFeedError(f"measurement manifest is missing {key}")
        repo_id, revision = primary_source_ref(source, key)
        ref = row.get("source_ref")
        if not isinstance(ref, dict) or ref.get("repo_id") != repo_id or ref.get("revision") != revision:
            raise LabFeedError(f"measurement manifest source_ref mismatch for {key}")
        size = row.get("size_bytes")
        if not isinstance(size, int) or isinstance(size, bool) or size <= 0:
            raise LabFeedError(f"measurement manifest size_bytes for {key} must be a positive integer")
        source_path_value = row.get("source_path")
        if not isinstance(source_path_value, str) or not source_path_value:
            raise LabFeedError(f"measurement manifest source_path for {key} must be a non-empty string")
        measurements[key] = size
        roots[key] = source_path_value
    return measurements, roots


def build_feed(candidate_path: pathlib.Path, source_path: pathlib.Path, measurements: dict[str, int]) -> bytes:
    candidate_bytes = candidate_path.read_bytes()
    candidate_obj = catalog_release.validate_candidate(candidate_bytes)
    source = catalog_release.validate_artifact_source(source_path.read_bytes(), candidate_obj=None)
    measured_source = source_with_measurements(source, measurements)
    return catalog_release.build_artifact_feed(measured_source, candidate_bytes, candidate_obj)


def trusted_public_key_base64(key_id: str, trusted_keys_path: pathlib.Path) -> str:
    trusted = load_json(trusted_keys_path)
    row = trusted.get("keys", {}).get(key_id)
    if not isinstance(row, dict) or row.get("status") not in {"active", "bridge"}:
        raise LabFeedError(f"trusted key {key_id} is not active or bridge")
    public_key = row.get("public_key_base64")
    if not isinstance(public_key, str) or not public_key:
        raise LabFeedError(f"trusted key {key_id} is malformed")
    return public_key


def swift_eval(source: str, env: dict[str, str]) -> str:
    merged = os.environ.copy()
    merged.update(env)
    completed = subprocess.run(
        ["swift", "-e", source],
        capture_output=True,
        text=True,
        env=merged,
        check=False,
    )
    if completed.returncode != 0:
        raise LabFeedError((completed.stderr or completed.stdout or "swift signer failed").strip())
    return completed.stdout.strip()


def sign_sidecar(feed_path: pathlib.Path, key_path: pathlib.Path, key_id: str, trusted_keys_path: pathlib.Path) -> dict[str, str]:
    if not key_path.is_file():
        raise LabFeedError(f"private signing key not found: {key_path}")
    mode = stat.S_IMODE(key_path.stat().st_mode)
    if mode not in (0o400, 0o600):
        raise LabFeedError(f"private signing key must be mode 0400 or 0600: {key_path}")
    public_b64 = trusted_public_key_base64(key_id, trusted_keys_path)
    derived = swift_eval(
        """
import CryptoKit
import Foundation
let env = ProcessInfo.processInfo.environment
guard let path = env["KEY_FILE"],
      let text = try? String(contentsOfFile: path, encoding: .utf8),
      let raw = Data(base64Encoded: text.trimmingCharacters(in: .whitespacesAndNewlines)),
      let key = try? Curve25519.Signing.PrivateKey(rawRepresentation: raw) else { exit(1) }
print(key.publicKey.rawRepresentation.base64EncodedString())
""",
        {"KEY_FILE": str(key_path)},
    )
    if derived != public_b64:
        raise LabFeedError(f"private signing key does not derive trusted public key {key_id}")
    signature = swift_eval(
        """
import CryptoKit
import Foundation
let env = ProcessInfo.processInfo.environment
guard let keyPath = env["KEY_FILE"],
      let inputPath = env["INPUT_PATH"],
      let keyText = try? String(contentsOfFile: keyPath, encoding: .utf8),
      let raw = Data(base64Encoded: keyText.trimmingCharacters(in: .whitespacesAndNewlines)),
      let key = try? Curve25519.Signing.PrivateKey(rawRepresentation: raw),
      let bytes = try? Data(contentsOf: URL(fileURLWithPath: inputPath)),
      let sig = try? key.signature(for: bytes) else { exit(1) }
print(sig.base64EncodedString())
""",
        {"KEY_FILE": str(key_path), "INPUT_PATH": str(feed_path)},
    )
    return {"key_id": key_id, "alg": "ed25519", "signature": signature}


def materialize(args: argparse.Namespace) -> None:
    artifact_paths = parse_artifact_paths(args.artifact_path or [])
    source = catalog_release.validate_artifact_source(args.source.read_bytes(), candidate_obj=None)
    if args.measurement_manifest is not None:
        measurements, roots = measurements_from_manifest(args.measurement_manifest, source, args.source, args.candidate)
    else:
        measurements, roots = measure_source(
            source,
            artifact_paths,
            hf_home=args.hf_home,
            download_missing=args.download_missing,
        )
    feed_bytes = build_feed(args.candidate, args.source, measurements)

    output = args.output.resolve()
    output.mkdir(parents=True, mode=0o700, exist_ok=True)
    endpoint_dir = output / "v1"
    endpoint_dir.mkdir(parents=True, mode=0o700, exist_ok=True)
    feed_path = endpoint_dir / "catalog-artifacts"
    feed_path.write_bytes(feed_bytes)
    os.chmod(feed_path, 0o644)
    shutil.copyfile(feed_path, output / "autotune-artifacts.json")
    sidecar = sign_sidecar(feed_path, args.private_key, args.signer_key_id, args.trusted_keys)
    endpoint_sidecar = endpoint_dir / "catalog-artifacts.sig"
    write_json(endpoint_sidecar, sidecar)
    shutil.copyfile(endpoint_sidecar, output / "autotune-artifacts.json.sig")

    manifest = {
        "schema_version": "macprovider.build1-lane-a-lab-feed.v1",
        "production_activation": False,
        "serving_endpoint": f"http://127.0.0.1:{args.port}/v1/catalog-artifacts",
        "feed_sha256": hashlib.sha256(feed_bytes).hexdigest(),
        "signer_key_id": args.signer_key_id,
        "release_id": json.loads(feed_bytes)["release_id"],
        "lane_a_size_bytes": measurements[BUILD1_CATALOG_KEY],
        "measured_artifacts": {
            key: {"size_bytes": measurements[key], "source_path": roots[key]}
            for key in sorted(measurements)
        },
        "boundaries": {
            "loopback_only": True,
            "release_published": False,
            "rewards_or_payouts": False,
            "production_endpoints_touched": False,
        },
    }
    write_json(output / "build1-lane-a-lab-feed-manifest.json", manifest)
    print(json.dumps(manifest, sort_keys=True))


def measure(args: argparse.Namespace) -> None:
    artifact_paths = parse_artifact_paths(args.artifact_path or [])
    source = catalog_release.validate_artifact_source(args.source.read_bytes(), candidate_obj=None)
    measurements, roots = measure_source(
        source,
        artifact_paths,
        hf_home=args.hf_home,
        download_missing=args.download_missing,
    )
    manifest = measurement_manifest(source, args.source, args.candidate, measurements, roots)
    if args.output is not None:
        write_json(args.output, manifest)
    print(json.dumps(manifest, sort_keys=True))


def serve(args: argparse.Namespace) -> None:
    directory = args.directory.resolve()
    if not (directory / "v1" / "catalog-artifacts").is_file() or not (directory / "v1" / "catalog-artifacts.sig").is_file():
        raise LabFeedError("feed directory must contain v1/catalog-artifacts and v1/catalog-artifacts.sig")

    class Handler(SimpleHTTPRequestHandler):
        def __init__(self, *handler_args: Any, **handler_kwargs: Any) -> None:
            super().__init__(*handler_args, directory=str(directory), **handler_kwargs)

        def log_message(self, format: str, *message_args: Any) -> None:
            sys.stderr.write("[build1-lab-feed] " + (format % message_args) + "\n")

    server = ThreadingHTTPServer((args.host, args.port), Handler)
    print(f"serving Build 1 lab feed at http://{args.host}:{args.port}/v1/catalog-artifacts", flush=True)
    try:
        server.serve_forever()
    finally:
        server.server_close()


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    sub = parser.add_subparsers(dest="command", required=True)

    build = sub.add_parser("build", help="measure, materialize, and sign a loopback artifact feed")
    build.add_argument("--output", type=pathlib.Path, required=True)
    build.add_argument("--candidate", type=pathlib.Path, default=CANDIDATE_PATH)
    build.add_argument("--source", type=pathlib.Path, default=SOURCE_PATH)
    build.add_argument("--trusted-keys", type=pathlib.Path, default=TRUSTED_KEYS_PATH)
    build.add_argument("--signer-key-id", default=DEFAULT_KEY_ID)
    default_key = pathlib.Path.home() / ".config" / "macprovider" / "keys" / "autotune-static-v4.private.base64"
    build.add_argument("--private-key", type=pathlib.Path, default=default_key)
    build.add_argument("--artifact-path", action="append", default=[], help="CATALOG_KEY=PATH for a measured artifact tree")
    build.add_argument("--measurement-manifest", type=pathlib.Path, help="source-hash-bound output from the measure subcommand")
    build.add_argument("--hf-home", type=pathlib.Path)
    build.add_argument("--download-missing", action="store_true", help="use huggingface_hub.snapshot_download for uncached snapshots")
    build.add_argument("--port", type=int, default=18082)
    build.set_defaults(func=materialize)

    measure_cmd = sub.add_parser("measure", help="measure all artifact source rows without signing")
    measure_cmd.add_argument("--output", type=pathlib.Path)
    measure_cmd.add_argument("--candidate", type=pathlib.Path, default=CANDIDATE_PATH)
    measure_cmd.add_argument("--source", type=pathlib.Path, default=SOURCE_PATH)
    measure_cmd.add_argument("--artifact-path", action="append", default=[], help="CATALOG_KEY=PATH for a measured artifact tree")
    measure_cmd.add_argument("--hf-home", type=pathlib.Path)
    measure_cmd.add_argument("--download-missing", action="store_true", help="use huggingface_hub.snapshot_download for uncached snapshots")
    measure_cmd.set_defaults(func=measure)

    serve_cmd = sub.add_parser("serve", help="serve a materialized feed directory on loopback")
    serve_cmd.add_argument("--directory", type=pathlib.Path, required=True)
    serve_cmd.add_argument("--host", default="127.0.0.1")
    serve_cmd.add_argument("--port", type=int, default=18082)
    serve_cmd.set_defaults(func=serve)

    args = parser.parse_args(argv)
    try:
        args.func(args)
    except LabFeedError as exc:
        print(f"build1-lane-a-lab-feed: {exc}", file=sys.stderr)
        return 2
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
