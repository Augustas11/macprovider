#!/usr/bin/env python3
"""Register or preflight the SPEC-043 on-call readiness operations-authority key.

This tool never generates a key and never writes private key material. An empty
committed keyring stays fail-closed until an operator supplies an Ed25519 public
key PEM from a key they already control. Provision the private half into the
GitHub production-release environment secret the same way
scripts/provision-spec043-production-release-key.sh handles the production-release
key; this tool only registers the public half.

On success it prints the SHA-256 allowlist digest to set as
MACPROVIDER_SPEC043_ONCALL_AUTHORITY_KEY_SHA256 in the coordinator environment.
"""

from __future__ import annotations

import argparse
import sys
from pathlib import Path

SCRIPTS = Path(__file__).resolve().parent
if str(SCRIPTS) not in sys.path:
    sys.path.insert(0, str(SCRIPTS))

from spec043_oncall_authority import (  # noqa: E402
    KEYRING_PATH,
    PUBLIC_KEY_PATH,
    preflight_keyring,
    register_public_key,
)


def die(message: str) -> None:
    print(f"register-spec043-oncall-authority-key: {message}", file=sys.stderr)
    raise SystemExit(1)


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--root", default=".", help="repository root")
    parser.add_argument(
        "--check",
        action="store_true",
        help="fail closed unless an on-call authority key is registered",
    )
    parser.add_argument("--public-key", default=None, help="operator-supplied Ed25519 public key PEM")
    parser.add_argument("--issuer", default="macprovider-ops")
    parser.add_argument("--valid-from", default=None, help="UTC timestamp like 2026-09-05T00:00:00Z")
    parser.add_argument("--valid-until", default=None, help="UTC timestamp like 2027-09-05T00:00:00Z")
    parser.add_argument("--openssl-bin", default=None, help="absolute path to trusted OpenSSL")
    args = parser.parse_args(argv)

    root = Path(args.root).resolve()
    if args.check:
        if args.public_key or args.valid_from or args.valid_until:
            die("--check cannot be combined with registration flags")
        outcome = preflight_keyring(root, openssl_bin=args.openssl_bin)
        if outcome.errors:
            for error in outcome.errors:
                print(f"error: {error}", file=sys.stderr)
            return 1
        print(f"register-spec043-oncall-authority-key: registered key present in {KEYRING_PATH.as_posix()}")
        print(f"MACPROVIDER_SPEC043_ONCALL_AUTHORITY_KEY_SHA256={outcome.digest}")
        return 0

    if not args.public_key or not args.valid_from or not args.valid_until:
        die("--public-key, --valid-from, and --valid-until are required unless --check")
    public_path = Path(args.public_key)
    if not public_path.is_absolute():
        public_path = Path.cwd() / public_path
    if public_path.is_symlink() or not public_path.is_file():
        die(f"public key is absent or unsafe: {public_path}")
    try:
        pem = public_path.read_text(encoding="utf-8")
    except OSError as exc:
        die(f"cannot read public key: {exc}")
    outcome = register_public_key(
        root,
        pem,
        issuer=args.issuer,
        valid_from=args.valid_from,
        valid_until=args.valid_until,
        openssl_bin=args.openssl_bin,
    )
    if outcome.errors:
        for error in outcome.errors:
            print(f"error: {error}", file=sys.stderr)
        return 1
    print(
        "register-spec043-oncall-authority-key: "
        f"wrote {PUBLIC_KEY_PATH.as_posix()} and updated {KEYRING_PATH.as_posix()}"
    )
    print(f"MACPROVIDER_SPEC043_ONCALL_AUTHORITY_KEY_SHA256={outcome.digest}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
