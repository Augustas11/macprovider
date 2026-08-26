#!/usr/bin/env python3
"""Sign a PoolPromotionTransitionV1 payload with the registered production-release key.

Fails closed when the committed keyring is empty. The private key is read from
an environment variable and must match the registered public key. This tool
never consumes the promotion ledger and never mutates CONFORMANCE.
"""

from __future__ import annotations

import argparse
import json
import os
import subprocess
import sys
import tempfile
from datetime import datetime, timezone
from pathlib import Path
from typing import Any

SCRIPTS = Path(__file__).resolve().parent
if str(SCRIPTS) not in sys.path:
    sys.path.insert(0, str(SCRIPTS))

from check_spec_governance import ValidationResult, resolve_trusted_openssl
from pool_promotion_transition import (
    PRODUCTION_RELEASE_KEY_ID,
    PUBLIC_KEY_PATH,
    load_json_object,
    preflight_production_release_keyring,
    public_key_reuses_acceptance_candidate,
    public_keys_match,
    sign_pool_promotion_transition,
)


def die(message: str) -> None:
    print(f"sign-pool-promotion-transition: {message}", file=sys.stderr)
    raise SystemExit(1)


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


def derived_public_pem(private_key_pem: str, openssl_bin: str) -> str:
    with tempfile.TemporaryDirectory(prefix="spec043-sign-derive.") as directory:
        work = Path(directory)
        private_path = work / "private.pem"
        public_path = work / "public.pem"
        private_path.write_text(private_key_pem, encoding="utf-8")
        private_path.chmod(0o600)
        completed = subprocess.run(
            [openssl_bin, "pkey", "-in", str(private_path), "-pubout", "-out", str(public_path)],
            capture_output=True,
            check=False,
            env={"PATH": "/usr/bin:/bin"},
        )
        if completed.returncode != 0:
            detail = completed.stderr.decode("utf-8", errors="replace").strip()
            die(detail or "could not derive the public key from the private signing key")
        return public_path.read_text(encoding="utf-8")


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--root", default=".", help="repository root")
    parser.add_argument("--input", required=True, help="unsigned PoolPromotionTransitionV1 payload JSON")
    parser.add_argument("--output", required=True, help="signed envelope output path")
    parser.add_argument(
        "--private-key-env",
        default="MACPROVIDER_SPEC043_PRODUCTION_RELEASE_SIGNING_KEY_PEM",
    )
    parser.add_argument("--openssl-bin", default=None, help="absolute path to trusted OpenSSL")
    parser.add_argument("--verified-at", default=None, help="UTC timestamp, default: now")
    parser.add_argument("--verifier", default="scripts/sign-pool-promotion-transition.py")
    parser.add_argument("--force", action="store_true")
    args = parser.parse_args(argv)

    root = Path(args.root).resolve()
    input_path = Path(args.input)
    if not input_path.is_absolute():
        input_path = root / input_path
    output_path = safe_evidence_output_path(root, args.output)
    if output_path.exists() and not args.force:
        die(f"output already exists: {output_path}")

    preflight = preflight_production_release_keyring(root, openssl_bin=args.openssl_bin)
    if preflight.errors:
        for error in preflight.errors:
            print(f"error: {error}", file=sys.stderr)
        return 1

    load_result = ValidationResult()
    signed = load_json_object(input_path, "pool-promotion-transition payload", load_result)
    if signed is None:
        for error in load_result.errors:
            print(f"error: {error}", file=sys.stderr)
        return 1

    verified_at = args.verified_at or datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")
    try:
        openssl_bin = resolve_trusted_openssl(args.openssl_bin)
    except ValueError as exc:
        die(str(exc))
    private_key_pem = read_private_key(args.private_key_env)
    public_key_path = root / PUBLIC_KEY_PATH
    registered_public = public_key_path.read_text(encoding="utf-8")
    derived_public = derived_public_pem(private_key_pem, openssl_bin)
    reuse = ValidationResult()
    if public_key_reuses_acceptance_candidate(root, registered_public, str(PUBLIC_KEY_PATH), reuse):
        die("registered production-release public key must not reuse the acceptance candidate signing key")
    if public_key_reuses_acceptance_candidate(root, derived_public, args.private_key_env, reuse):
        die("private signing key must not reuse the acceptance candidate signing key")
    if not public_keys_match(derived_public, registered_public):
        die("private signing key does not match the registered production-release public key")
    envelope = sign_pool_promotion_transition(
        signed,
        private_key_pem=private_key_pem,
        public_key_pem=registered_public,
        key_id=PRODUCTION_RELEASE_KEY_ID,
        openssl_bin=openssl_bin,
        verified_at=verified_at,
        verifier=args.verifier,
    )
    write_json_atomically(output_path, envelope)
    print(f"sign-pool-promotion-transition: signed {output_path.relative_to(root)}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
