#!/usr/bin/env python3
"""Register or preflight a SPEC-043 production-release approver public key.

This tool never generates a key and never writes private key material. An empty
committed keyring stays fail-closed until an operator supplies a P-256 public
key PEM from an offline key they already control.
"""

from __future__ import annotations

import argparse
import sys
from pathlib import Path

SCRIPTS = Path(__file__).resolve().parent
if str(SCRIPTS) not in sys.path:
    sys.path.insert(0, str(SCRIPTS))

from pool_promotion_transition import (
    KEYRING_PATH,
    PUBLIC_KEY_PATH,
    preflight_production_release_keyring,
    register_production_release_public_key,
)


def die(message: str) -> None:
    print(f"register-spec043-production-release-key: {message}", file=sys.stderr)
    raise SystemExit(1)


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--root", default=".", help="repository root")
    parser.add_argument("--check", action="store_true", help="fail closed unless a production-release key is registered")
    parser.add_argument("--public-key", default=None, help="operator-supplied P-256 public key PEM")
    parser.add_argument("--issuer", default="macprovider-ops")
    parser.add_argument("--valid-from", default=None, help="UTC timestamp like 2026-08-26T00:00:00Z")
    parser.add_argument("--valid-until", default=None, help="UTC timestamp like 2027-08-26T00:00:00Z")
    parser.add_argument("--openssl-bin", default=None, help="absolute path to trusted OpenSSL")
    args = parser.parse_args(argv)

    root = Path(args.root).resolve()
    if args.check:
        if args.public_key or args.valid_from or args.valid_until:
            die("--check cannot be combined with registration flags")
        outcome = preflight_production_release_keyring(root, openssl_bin=args.openssl_bin)
        if outcome.errors:
            for error in outcome.errors:
                print(f"error: {error}", file=sys.stderr)
            return 1
        print(f"register-spec043-production-release-key: registered key present in {KEYRING_PATH.as_posix()}")
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
    outcome = register_production_release_public_key(
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
        "register-spec043-production-release-key: "
        f"wrote {PUBLIC_KEY_PATH.as_posix()} and updated {KEYRING_PATH.as_posix()}"
    )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
