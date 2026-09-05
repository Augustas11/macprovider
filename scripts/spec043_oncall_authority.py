"""SPEC-043 on-call readiness operations-authority Ed25519 keyring helpers.

This module never generates a key and never writes private key material. An
empty committed keyring stays fail-closed: no on-call readiness record can be
signed or accepted until an operator registers a public key from an offline (or
GitHub-environment-held) Ed25519 key they already control.

The coordinator allowlists the operations authority by SHA-256 of the raw
32-byte Ed25519 public key (see trustpool.OnCallAuthorityKeySHA256). This module
derives that digest with the system OpenSSL so it needs no third-party Python
dependency and stays byte-identical to the Go verifier.
"""

from __future__ import annotations

import datetime
import hashlib
import json
import subprocess
from dataclasses import dataclass, field
from pathlib import Path

KEYRING_PATH = Path("security/spec-043-oncall-authority-ed25519-keyring.json")
PUBLIC_KEY_PATH = Path("security/spec-043-oncall-authority-ed25519-v1.pem")
KEY_ID = "macprovider-spec043-oncall-authority-ed25519-v1"
KEYRING_SCHEMA_VERSION = "spec-043-launch-keyring-v1"
KEYRING_PURPOSE = "oncall-readiness-operations-authority"

# Ed25519 SubjectPublicKeyInfo DER is a fixed 44 bytes: a 12-byte header
# carrying the Ed25519 algorithm OID (1.3.101.112) followed by the raw 32-byte
# public key. The coordinator hashes those raw 32 bytes, so the allowlist digest
# is sha256(DER[-32:]). The fixed header also distinguishes Ed25519 from X25519
# (1.3.101.110), which shares the 44-byte length.
_ED25519_SPKI_DER_LEN = 44
_ED25519_RAW_PUBKEY_LEN = 32
_ED25519_SPKI_HEADER = bytes.fromhex("302a300506032b6570032100")


@dataclass
class Outcome:
    digest: str = ""
    errors: list[str] = field(default_factory=list)

    def error(self, message: str) -> None:
        self.errors.append(message)


def _safe_repo_file(root: Path, rel: Path) -> Path | None:
    path = (root / rel).resolve()
    try:
        path.relative_to(root.resolve())
    except ValueError:
        return None
    if path.is_symlink():
        return None
    return path


def _openssl(openssl_bin: str | None) -> str:
    return openssl_bin or "openssl"


def authority_key_sha256(public_pem: str, openssl_bin: str | None = None) -> tuple[str, list[str]]:
    """Return (hex_digest, errors) for an Ed25519 public key PEM."""
    errors: list[str] = []
    try:
        der = subprocess.run(
            [_openssl(openssl_bin), "pkey", "-pubin", "-outform", "DER"],
            input=public_pem.encode("utf-8"),
            capture_output=True,
            check=True,
        ).stdout
    except (OSError, subprocess.CalledProcessError) as exc:
        errors.append(f"openssl could not parse the public key: {exc}")
        return "", errors
    if len(der) != _ED25519_SPKI_DER_LEN:
        errors.append(
            f"public key is not a raw Ed25519 SubjectPublicKeyInfo "
            f"(got {len(der)} DER bytes, want {_ED25519_SPKI_DER_LEN})"
        )
        return "", errors
    if der[: len(_ED25519_SPKI_HEADER)] != _ED25519_SPKI_HEADER:
        errors.append("public key is not Ed25519 (algorithm OID mismatch; X25519 and others are rejected)")
        return "", errors
    raw = der[-_ED25519_RAW_PUBKEY_LEN:]
    return hashlib.sha256(raw).hexdigest(), errors


def _require_public_only_pem(public_pem: str) -> list[str]:
    """Reject anything but exactly one PUBLIC KEY block so private material can
    never be written into the committed public key file."""
    if "PRIVATE KEY" in public_pem:
        return ["public key input must not contain private key material"]
    begins = public_pem.count("-----BEGIN PUBLIC KEY-----")
    ends = public_pem.count("-----END PUBLIC KEY-----")
    if begins != 1 or ends != 1:
        return ["public key input must contain exactly one PUBLIC KEY block"]
    return []


def _parse_utc(value: str) -> datetime.datetime | None:
    try:
        parsed = datetime.datetime.fromisoformat(value.replace("Z", "+00:00"))
    except ValueError:
        return None
    if parsed.tzinfo is None:
        return None
    return parsed.astimezone(datetime.timezone.utc)


def _load_keyring(root: Path) -> tuple[dict | None, Outcome]:
    outcome = Outcome()
    path = _safe_repo_file(root, KEYRING_PATH)
    if path is None or not path.is_file():
        outcome.error(f"{KEYRING_PATH}: keyring is absent or unsafe")
        return None, outcome
    try:
        data = json.loads(path.read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError) as exc:
        outcome.error(f"{KEYRING_PATH}: cannot read keyring: {exc}")
        return None, outcome
    if not isinstance(data, dict):
        outcome.error(f"{KEYRING_PATH}: must be a JSON object")
        return None, outcome
    if data.get("schema_version") != KEYRING_SCHEMA_VERSION:
        outcome.error(f"{KEYRING_PATH}: schema_version must equal {KEYRING_SCHEMA_VERSION!r}")
        return None, outcome
    if data.get("purpose") != KEYRING_PURPOSE:
        outcome.error(f"{KEYRING_PATH}: purpose must equal {KEYRING_PURPOSE!r}")
        return None, outcome
    if not isinstance(data.get("keys"), list):
        outcome.error(f"{KEYRING_PATH}.keys: must be an array")
        return None, outcome
    return data, outcome


def preflight_keyring(root: Path, openssl_bin: str | None = None) -> Outcome:
    """Fail closed unless the committed keyring entry authoritatively matches
    the committed public key PEM.

    The committed keyring, not the sidecar PEM, is the reviewed allowlist
    authority: this validates the single entry's purpose, environment class, and
    recorded digest, reads the PEM the entry names, and only returns the digest
    when the derived digest equals the entry's recorded public_key_sha256. That
    prevents a stale or mismatched keyring entry from silently signing/verifying
    against a swapped PEM.
    """
    data, outcome = _load_keyring(root)
    if data is None:
        return outcome
    keys = data["keys"]
    if len(keys) != 1:
        outcome.error(
            f"{KEYRING_PATH}: is fail-closed: exactly one on-call authority key must be registered"
        )
        return outcome
    entry = keys[0]
    if not isinstance(entry, dict):
        outcome.error(f"{KEYRING_PATH}.keys[0]: must be an object")
        return outcome
    if entry.get("purpose") != KEYRING_PURPOSE:
        outcome.error(f"{KEYRING_PATH}.keys[0].purpose: must equal {KEYRING_PURPOSE!r}")
        return outcome
    if entry.get("key_id") != KEY_ID:
        outcome.error(f"{KEYRING_PATH}.keys[0].key_id: must equal {KEY_ID!r}")
        return outcome
    allowed = entry.get("allowed_environment_classes")
    if not isinstance(allowed, list) or "production" not in allowed:
        outcome.error(f"{KEYRING_PATH}.keys[0].allowed_environment_classes: must include 'production'")
        return outcome
    if not isinstance(entry.get("issuer"), str) or not entry["issuer"].strip():
        outcome.error(f"{KEYRING_PATH}.keys[0].issuer: must be a non-empty string")
        return outcome
    window_from = _parse_utc(entry["valid_from"]) if isinstance(entry.get("valid_from"), str) else None
    window_until = _parse_utc(entry["valid_until"]) if isinstance(entry.get("valid_until"), str) else None
    if window_from is None or window_until is None:
        outcome.error(f"{KEYRING_PATH}.keys[0]: valid_from/valid_until must be UTC ISO-8601 timestamps")
        return outcome
    if window_until <= window_from:
        outcome.error(f"{KEYRING_PATH}.keys[0]: valid_until must be after valid_from")
        return outcome
    now = datetime.datetime.now(datetime.timezone.utc)
    if now < window_from:
        outcome.error(f"{KEYRING_PATH}.keys[0]: key is not yet valid")
        return outcome
    if now >= window_until:
        outcome.error(f"{KEYRING_PATH}.keys[0]: key validity window has expired")
        return outcome
    recorded = entry.get("public_key_sha256")
    if not isinstance(recorded, str) or len(recorded) != 64 or any(c not in "0123456789abcdef" for c in recorded):
        outcome.error(f"{KEYRING_PATH}.keys[0].public_key_sha256: must be lowercase hex sha256")
        return outcome
    if entry.get("public_key_path") != str(PUBLIC_KEY_PATH):
        outcome.error(f"{KEYRING_PATH}.keys[0].public_key_path: must equal {str(PUBLIC_KEY_PATH)!r}")
        return outcome
    pem_path = _safe_repo_file(root, PUBLIC_KEY_PATH)
    if pem_path is None or not pem_path.is_file():
        outcome.error(f"{PUBLIC_KEY_PATH}: public key is absent or unsafe")
        return outcome
    try:
        pem = pem_path.read_text(encoding="utf-8")
    except OSError as exc:
        outcome.error(f"{PUBLIC_KEY_PATH}: cannot read: {exc}")
        return outcome
    digest, errors = authority_key_sha256(pem, openssl_bin=openssl_bin)
    if errors:
        for message in errors:
            outcome.error(message)
        return outcome
    if digest != recorded:
        outcome.error(
            f"{KEYRING_PATH}: registered public_key_sha256 does not match the committed public key digest"
        )
        return outcome
    outcome.digest = digest
    return outcome


def register_public_key(
    root: Path,
    public_pem: str,
    *,
    issuer: str,
    valid_from: str,
    valid_until: str,
    openssl_bin: str | None = None,
) -> Outcome:
    """Write PUBLIC_KEY_PATH and add a single key entry to the empty keyring."""
    outcome = Outcome()
    if not issuer.strip():
        outcome.error("issuer must be a non-empty string")
        return outcome
    pem_errors = _require_public_only_pem(public_pem)
    if pem_errors:
        for message in pem_errors:
            outcome.error(message)
        return outcome
    window_from = _parse_utc(valid_from)
    window_until = _parse_utc(valid_until)
    if window_from is None or window_until is None:
        outcome.error("valid_from and valid_until must be UTC ISO-8601 timestamps")
        return outcome
    if window_until <= window_from:
        outcome.error("valid_until must be after valid_from")
        return outcome
    digest, errors = authority_key_sha256(public_pem, openssl_bin=openssl_bin)
    outcome.digest = digest
    if errors:
        for message in errors:
            outcome.error(message)
        return outcome
    data, load = _load_keyring(root)
    if data is None:
        outcome.errors.extend(load.errors)
        return outcome
    if data["keys"]:
        outcome.error(f"{KEYRING_PATH}: already has a registered key; refusing to overwrite")
        return outcome
    pem_path = _safe_repo_file(root, PUBLIC_KEY_PATH)
    if pem_path is None:
        outcome.error(f"{PUBLIC_KEY_PATH}: unsafe path")
        return outcome
    if pem_path.exists():
        outcome.error(f"{PUBLIC_KEY_PATH}: already exists; refusing to overwrite")
        return outcome
    pem_path.write_text(public_pem if public_pem.endswith("\n") else public_pem + "\n", encoding="utf-8")
    data["keys"] = [
        {
            "key_id": KEY_ID,
            "purpose": KEYRING_PURPOSE,
            "issuer": issuer,
            "valid_from": valid_from,
            "valid_until": valid_until,
            "allowed_environment_classes": ["production"],
            "public_key_sha256": digest,
            "public_key_path": str(PUBLIC_KEY_PATH),
        }
    ]
    keyring_path = _safe_repo_file(root, KEYRING_PATH)
    assert keyring_path is not None
    keyring_path.write_text(json.dumps(data, indent=2) + "\n", encoding="utf-8")
    return outcome
