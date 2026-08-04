#!/usr/bin/env python3
"""Sign a captured journey-result payload with the acceptance signing key."""

from __future__ import annotations

import argparse
import base64
import json
import os
import subprocess
import sys
import tempfile
from datetime import datetime, timezone
from pathlib import Path
from typing import Any

from check_spec_governance import (
    JOURNEY_RESULT_ENVELOPE_SCHEMA,
    JOURNEY_RESULT_PAYLOAD_SCHEMA,
    JOURNEY_RESULT_PUBLIC_KEY_PATH,
    JOURNEY_RESULT_SIGNING_ALGORITHM,
    JOURNEY_RESULT_SIGNING_DOMAIN,
    JOURNEY_RESULT_SIGNING_KEY_ID,
    ValidationResult,
    _canonical_json_bytes,
    _canonical_json_sha256,
    _load_json,
    resolve_trusted_openssl,
)


def die(message: str) -> None:
    print(f"sign-journey-result: {message}", file=sys.stderr)
    raise SystemExit(1)


def load_object(path: Path, label: str) -> dict[str, Any]:
    result = ValidationResult()
    value = _load_json(path, result)
    if result.errors:
        for error in result.errors:
            print(f"error: {error}", file=sys.stderr)
        die(f"{label} rejected")
    if not isinstance(value, dict):
        die(f"{label} must be a JSON object")
    return value


def run_openssl(openssl_bin: str, args: list[str], *, input_bytes: bytes | None = None) -> bytes:
    try:
        completed = subprocess.run(
            [openssl_bin, *args],
            input=input_bytes,
            capture_output=True,
            check=False,
            env={"PATH": "/usr/bin:/bin"},
        )
    except FileNotFoundError:
        die("openssl is required")
    if completed.returncode != 0:
        detail = completed.stderr.decode("utf-8", errors="replace").strip()
        die(detail or "openssl command failed")
    return completed.stdout


def read_private_key(env_name: str) -> str:
    value = os.environ.get(env_name)
    if not value:
        die(f"protected signing key env var is required: {env_name}")
    return value.rstrip("\n") + "\n"


def safe_evidence_output_path(root: Path, output: str) -> Path:
    requested = Path(output)
    if not requested.is_absolute():
        requested = root / requested
    try:
        evidence_root = (root / "journeys" / "evidence").resolve(strict=True)
    except OSError as exc:
        die(f"journey evidence directory is absent or unsafe: {exc}")
    resolved = requested.resolve(strict=False)
    try:
        resolved.relative_to(evidence_root)
    except ValueError:
        die("output must be under journeys/evidence/")
    if requested.exists() and requested.is_symlink():
        die(f"output must not be a symlink: {requested}")
    return resolved


def write_json_atomically(path: Path, value: dict[str, Any]) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    if path.parent.is_symlink():
        die(f"output parent must not be a symlink: {path.parent}")
    payload = json.dumps(value, indent=2, sort_keys=False) + "\n"
    with tempfile.NamedTemporaryFile("w", encoding="utf-8", dir=path.parent, prefix=f".{path.name}.", delete=False) as handle:
        temporary = Path(handle.name)
        handle.write(payload)
    try:
        if path.exists() and path.is_symlink():
            die(f"output must not be a symlink: {path}")
        os.replace(temporary, path)
    finally:
        if temporary.exists():
            temporary.unlink()


def sign_payload(root: Path, signed: dict[str, Any], private_key_pem: str, verified_at: str, verifier: str, openssl_bin: str) -> dict[str, Any]:
    if signed.get("schema_version") != JOURNEY_RESULT_PAYLOAD_SCHEMA:
        die(f"signed.schema_version must equal {JOURNEY_RESULT_PAYLOAD_SCHEMA!r}")

    public_key = root / JOURNEY_RESULT_PUBLIC_KEY_PATH
    if not public_key.is_file() or public_key.is_symlink():
        die(f"trusted public key is absent or unsafe: {JOURNEY_RESULT_PUBLIC_KEY_PATH}")

    with tempfile.TemporaryDirectory(prefix="journey-result-signer.") as directory:
        work = Path(directory)
        private_path = work / "private.pem"
        derived_public = work / "public.pem"
        message = work / "message"
        signature = work / "signature.der"

        private_path.write_text(private_key_pem, encoding="utf-8")
        private_path.chmod(0o600)
        run_openssl(openssl_bin, ["pkey", "-in", str(private_path), "-pubout", "-out", str(derived_public)])
        if derived_public.read_bytes() != public_key.read_bytes():
            die("private signing key does not match the trusted journey-result public key")

        message.write_bytes(JOURNEY_RESULT_SIGNING_DOMAIN + _canonical_json_bytes(signed))
        run_openssl(openssl_bin, ["dgst", "-sha256", "-sign", str(private_path), "-out", str(signature), str(message)])
        run_openssl(openssl_bin, ["dgst", "-sha256", "-verify", str(public_key), "-signature", str(signature), str(message)])
        signature_b64 = base64.b64encode(signature.read_bytes()).decode("ascii")

    return {
        "schema_version": JOURNEY_RESULT_ENVELOPE_SCHEMA,
        "signatures": [
            {
                "algorithm": JOURNEY_RESULT_SIGNING_ALGORITHM,
                "key_id": JOURNEY_RESULT_SIGNING_KEY_ID,
                "signature": signature_b64,
                "signed_sha256": _canonical_json_sha256(signed),
                "verified_at": verified_at,
                "verifier": verifier,
            }
        ],
        "signed": signed,
    }


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--root", default=".", help="repository root")
    parser.add_argument("--input", required=True, help="captured signed payload JSON")
    parser.add_argument("--output", required=True, help="signed envelope output path")
    parser.add_argument("--private-key-env", default="MACPROVIDER_ACCEPTANCE_SIGNING_KEY_PEM")
    parser.add_argument("--openssl-bin", default=None, help="absolute path to trusted OpenSSL")
    parser.add_argument("--verified-at", default=None, help="UTC timestamp, default: now")
    parser.add_argument("--verifier", default="scripts/sign-journey-result.py")
    parser.add_argument("--force", action="store_true", help="overwrite an existing output file")
    args = parser.parse_args(argv)

    root = Path(args.root).resolve()
    input_path = Path(args.input)
    if not input_path.is_absolute():
        input_path = root / input_path
    output_path = safe_evidence_output_path(root, args.output)
    if output_path.exists() and not args.force:
        die(f"output already exists: {output_path}")

    verified_at = args.verified_at or datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")
    try:
        openssl_bin = resolve_trusted_openssl(args.openssl_bin)
    except ValueError as exc:
        die(str(exc))
    envelope = sign_payload(root, load_object(input_path, "journey-result payload"), read_private_key(args.private_key_env), verified_at, args.verifier, openssl_bin)
    write_json_atomically(output_path, envelope)
    print(f"sign-journey-result: signed {output_path.relative_to(root)}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
