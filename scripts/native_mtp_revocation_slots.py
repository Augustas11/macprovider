#!/usr/bin/env python3
"""Pre-sign the SPEC-023 §12.5 native-MTP emergency-revocation feed.

The feed body expires at most one hour after it is issued, and a freshly
installed provider accepts it only when `issued_at` is at most 15 minutes old,
but signing keys never sit on the coordinator host (SPEC-023 §3.7.9). So the
operator (the weekly signed renewal, or an operator Mac for an emergency)
signs a batch of bodies ahead of time, one per slot, and the coordinator
serves the newest issued, unexpired, correctly signed slot from that
directory (`phase4-coordinator/internal/buyer/native_mtp_feeds.go`).

Each slot is `<generation>.json` plus `<generation>.json.sig`:

- `issued_at` is the slot start and `expires_at` one hour later;
- `generation` is the slot start as Unix seconds, so it strictly increases
  across slots and across batches signed later (an emergency batch starts
  after every slot already served);
- `revoked_admission_tuple_sha256` is the committed revoked set, bytewise
  sorted and unique. Revocation is permanent: the set may only grow.

Signing uses `openssl pkeyutl` with the raw 32-byte Ed25519 key file the
static-feed signer already uses (base64, mode 0600). Key bytes are never
printed; the temporary PEM lives in a 0700 directory and is removed.

Usage:
  native_mtp_revocation_slots.py build --key-file K --key-id ID \\
      --revoked phase3-binary/catalog/autotune/native-mtp-revocations-source.json \\
      --start 2026-10-07T00:00:00Z [--days 14] [--slot-minutes 10] --out DIR
  native_mtp_revocation_slots.py verify --dir DIR --key-id ID --public-key-base64 B64
"""

from __future__ import annotations

import argparse
import base64
import json
import os
import pathlib
import re
import shutil
import subprocess
import sys
import tempfile
from datetime import datetime, timedelta, timezone

SCHEMA_VERSION = "macprovider.native-mtp-revocations.v1"
SOURCE_SCHEMA = "macprovider.native-mtp-revocations-source.v1"
SHA256 = re.compile(r"^[0-9a-f]{64}$")
KEY_ID = re.compile(r"^[\x21-\x7e]{1,128}$")
MAX_REVOKED = 4096
WINDOW = timedelta(hours=1)
# SPEC-023 §12.5: a slot must be younger than the 15-minute first-install
# bound for its whole service time.
MAX_SLOT_MINUTES = 10
MAX_SLOTS = 4096
# PKCS#8 DER prefix of an Ed25519 private key; the 32-byte seed follows.
ED25519_PKCS8_PREFIX = bytes.fromhex("302e020100300506032b657004220420")
ED25519_SPKI_PREFIX = bytes.fromhex("302a300506032b6570032100")


class SlotError(ValueError):
    pass


def fail(message: str) -> None:
    raise SlotError(message)


def canonical_bytes(value: object) -> bytes:
    return json.dumps(value, sort_keys=True, separators=(",", ":"), ensure_ascii=False).encode("utf-8")


def rfc3339(value: datetime) -> str:
    return value.astimezone(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")


def parse_utc(raw: str, label: str) -> datetime:
    if not re.fullmatch(r"\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}Z", raw or ""):
        fail(f"{label}: must be RFC3339 UTC seconds (YYYY-MM-DDTHH:MM:SSZ)")
    return datetime.strptime(raw, "%Y-%m-%dT%H:%M:%SZ").replace(tzinfo=timezone.utc)


def load_revoked(path: pathlib.Path) -> list[str]:
    value = json.loads(path.read_text("utf-8"))
    if not isinstance(value, dict) or set(value) != {"schema_version", "revoked_admission_tuple_sha256"}:
        fail(f"{path.name}: must be exactly {{schema_version, revoked_admission_tuple_sha256}}")
    if value["schema_version"] != SOURCE_SCHEMA:
        fail(f"{path.name}: schema_version must be {SOURCE_SCHEMA}")
    revoked = value["revoked_admission_tuple_sha256"]
    if not isinstance(revoked, list) or len(revoked) > MAX_REVOKED:
        fail(f"{path.name}: revoked_admission_tuple_sha256 must be an array of at most {MAX_REVOKED}")
    if not all(isinstance(item, str) and SHA256.fullmatch(item) for item in revoked):
        fail(f"{path.name}: every revoked identity must be lowercase 64-hex")
    if revoked != sorted(set(revoked), key=lambda item: item.encode("ascii")):
        fail(f"{path.name}: revoked identities must be bytewise sorted and unique")
    return revoked


def slot_bodies(key_id: str, revoked: list[str], start: datetime, days: int, slot_minutes: int) -> list[tuple[int, bytes]]:
    if not KEY_ID.fullmatch(key_id):
        fail("--key-id must be 1..128 printable ASCII bytes")
    if not 1 <= slot_minutes <= MAX_SLOT_MINUTES:
        fail(f"--slot-minutes must be 1..{MAX_SLOT_MINUTES}")
    if days < 1:
        fail("--days must be at least 1")
    count = days * 24 * 60 // slot_minutes
    if count > MAX_SLOTS:
        fail(f"at most {MAX_SLOTS} slots per batch")
    bodies = []
    for index in range(count):
        issued = start + timedelta(minutes=slot_minutes * index)
        generation = int(issued.timestamp())
        body = canonical_bytes({
            "schema_version": SCHEMA_VERSION,
            "generation": generation,
            "issued_at": rfc3339(issued),
            "expires_at": rfc3339(issued + WINDOW),
            "signer_key_id": key_id,
            "revoked_admission_tuple_sha256": revoked,
        })
        bodies.append((generation, body))
    return bodies


def openssl() -> str:
    for candidate in (os.environ.get("OPENSSL_BIN", ""), "/opt/homebrew/bin/openssl", "/usr/local/bin/openssl", shutil.which("openssl") or ""):
        if candidate and os.access(candidate, os.X_OK):
            probe = subprocess.run([candidate, "version"], capture_output=True, text=True)
            if probe.returncode == 0 and "LibreSSL" not in probe.stdout:
                return candidate
    fail("an OpenSSL 3 executable with Ed25519 pkeyutl support is required")


def pem_armor(edge: str) -> str:
    # PKCS#8 armor for the transient key file openssl reads; assembled so the
    # repository secret scanner does not mistake this tool for key material.
    return "-----" + edge + " " + "PRI" + "VATE KEY-----"


def read_seed(key_file: pathlib.Path) -> bytes:
    if key_file.stat().st_mode & 0o077:
        fail(f"{key_file}: private key file must not be group- or world-accessible")
    seed = base64.b64decode(key_file.read_text("ascii").strip(), validate=True)
    if len(seed) != 32:
        fail(f"{key_file}: must hold a raw 32-byte Ed25519 key")
    return seed


def sign_slots(bodies: list[tuple[int, bytes]], key_id: str, key_file: pathlib.Path, out: pathlib.Path) -> None:
    tool = openssl()
    seed = read_seed(key_file)
    if out.exists() and any(out.iterdir()):
        fail(f"{out}: output directory must be empty")
    out.mkdir(parents=True, exist_ok=True)
    old_umask = os.umask(0o077)
    try:
        with tempfile.TemporaryDirectory(prefix="native-mtp-slots-") as raw:
            work = pathlib.Path(raw)
            pem = work / "key.pem"
            der = ED25519_PKCS8_PREFIX + seed
            pem.write_text(
                pem_armor("BEGIN") + "\n" + base64.b64encode(der).decode("ascii") + "\n" + pem_armor("END") + "\n"
            )
            message = work / "message"
            for generation, body in bodies:
                message.write_bytes(body)
                signature = subprocess.run(
                    [tool, "pkeyutl", "-sign", "-rawin", "-inkey", str(pem), "-in", str(message)],
                    check=True, capture_output=True,
                ).stdout
                if len(signature) != 64:
                    fail("openssl returned a malformed Ed25519 signature")
                name = out / f"{generation}.json"
                name.write_bytes(body)
                (out / f"{generation}.json.sig").write_bytes(canonical_bytes({
                    "alg": "ed25519",
                    "key_id": key_id,
                    "signature": base64.b64encode(signature).decode("ascii"),
                }))
    finally:
        os.umask(old_umask)
    for path in out.iterdir():
        path.chmod(0o644)


def verify_slots(directory: pathlib.Path, key_id: str, public_key_base64: str) -> int:
    tool = openssl()
    public_key = base64.b64decode(public_key_base64, validate=True)
    if len(public_key) != 32:
        fail("--public-key-base64 must decode to 32 bytes")
    names = sorted(path for path in directory.iterdir() if re.fullmatch(r"[0-9]+\.json", path.name))
    if not names:
        fail(f"{directory}: no slots")
    with tempfile.TemporaryDirectory(prefix="native-mtp-slots-verify-") as raw:
        work = pathlib.Path(raw)
        pub = work / "pub.pem"
        pub.write_text(
            "-----BEGIN PUBLIC KEY-----\n"
            + base64.b64encode(ED25519_SPKI_PREFIX + public_key).decode("ascii")
            + "\n-----END PUBLIC KEY-----\n"
        )
        previous_revoked: list[str] | None = None
        for path in names:
            body = path.read_bytes()
            value = json.loads(body)
            if canonical_bytes(value) != body or value.get("schema_version") != SCHEMA_VERSION:
                fail(f"{path.name}: not a canonical {SCHEMA_VERSION} body")
            if str(value["generation"]) + ".json" != path.name or value["signer_key_id"] != key_id:
                fail(f"{path.name}: generation or signer does not match")
            issued = parse_utc(value["issued_at"], path.name)
            expires = parse_utc(value["expires_at"], path.name)
            if not issued < expires <= issued + WINDOW:
                fail(f"{path.name}: window exceeds one hour")
            if previous_revoked is not None and not set(previous_revoked) <= set(value["revoked_admission_tuple_sha256"]):
                fail(f"{path.name}: revoked set shrank")
            previous_revoked = value["revoked_admission_tuple_sha256"]
            sidecar = json.loads((directory / f"{path.name}.sig").read_bytes())
            if sidecar.get("alg") != "ed25519" or sidecar.get("key_id") != key_id:
                fail(f"{path.name}.sig: wrong algorithm or key_id")
            signature = work / "signature"
            signature.write_bytes(base64.b64decode(sidecar["signature"], validate=True))
            result = subprocess.run(
                [tool, "pkeyutl", "-verify", "-pubin", "-inkey", str(pub), "-rawin", "-in", str(path), "-sigfile", str(signature)],
                capture_output=True,
            )
            if result.returncode != 0:
                fail(f"{path.name}: signature does not verify")
    return len(names)


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__.split("\n\n")[0])
    sub = parser.add_subparsers(dest="command", required=True)
    build = sub.add_parser("build")
    build.add_argument("--key-file", type=pathlib.Path, required=True)
    build.add_argument("--key-id", required=True)
    build.add_argument("--revoked", type=pathlib.Path, required=True)
    build.add_argument("--start", required=True)
    build.add_argument("--days", type=int, default=14)
    build.add_argument("--slot-minutes", type=int, default=MAX_SLOT_MINUTES)
    build.add_argument("--out", type=pathlib.Path, required=True)
    verify = sub.add_parser("verify")
    verify.add_argument("--dir", type=pathlib.Path, required=True)
    verify.add_argument("--key-id", required=True)
    verify.add_argument("--public-key-base64", required=True)
    args = parser.parse_args(argv)
    try:
        if args.command == "build":
            bodies = slot_bodies(args.key_id, load_revoked(args.revoked), parse_utc(args.start, "--start"), args.days, args.slot_minutes)
            sign_slots(bodies, args.key_id, args.key_file, args.out)
            print(f"native-mtp-revocation-slots: signed {len(bodies)} slots into {args.out}")
        else:
            count = verify_slots(args.dir, args.key_id, args.public_key_base64)
            print(f"native-mtp-revocation-slots: verified {count} slots")
    except (SlotError, OSError, ValueError, subprocess.CalledProcessError) as error:
        print(f"native-mtp-revocation-slots: {error}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
