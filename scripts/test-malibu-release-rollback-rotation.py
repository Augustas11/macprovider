#!/usr/bin/env python3
from __future__ import annotations

import datetime as dt
import hashlib
import importlib.util
import json
import pathlib
import subprocess
import sys
import tempfile
import unittest


ROOT = pathlib.Path(__file__).resolve().parents[1]
SPEC = importlib.util.spec_from_file_location("malibu_release_envelope", ROOT / "scripts/malibu-release-envelope.py")
assert SPEC and SPEC.loader
contract = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(contract)


NOW = dt.datetime(2027, 1, 15, 8, 0, 0, tzinfo=dt.timezone.utc)


def stamp(value: dt.datetime) -> str:
    return value.strftime("%Y-%m-%dT%H:%M:%SZ")


class RollbackRotationContractTests(unittest.TestCase):
    def setUp(self) -> None:
        self.temporary = tempfile.TemporaryDirectory()
        self.root = pathlib.Path(self.temporary.name)
        self.private_key = self.root / "key.pem"
        self.public_key = self.root / "key.pub.pem"
        self.successor_private_key = self.root / "successor.pem"
        self.successor_public_key = self.root / "successor.pub.pem"
        subprocess.run(["openssl", "ecparam", "-name", "prime256v1", "-genkey", "-noout", "-out", self.private_key], check=True, capture_output=True)
        subprocess.run(["openssl", "pkey", "-in", self.private_key, "-pubout", "-out", self.public_key], check=True, capture_output=True)
        subprocess.run(["openssl", "ecparam", "-name", "prime256v1", "-genkey", "-noout", "-out", self.successor_private_key], check=True, capture_output=True)
        subprocess.run(["openssl", "pkey", "-in", self.successor_private_key, "-pubout", "-out", self.successor_public_key], check=True, capture_output=True)

    def tearDown(self) -> None:
        self.temporary.cleanup()

    @staticmethod
    def state(index: int, build: int, generation: int, digest: str) -> dict:
        return {"build": build, "envelope_generation": generation, "envelope_sha256": digest, "index_generation": index}

    def rollback_payload(self) -> tuple[dict, dict, dict]:
        current = self.state(9, 50, 50, "a" * 64)
        target = self.state(7, 48, 48, "b" * 64)
        payload = {
            "current": current,
            "expires_at": stamp(NOW + dt.timedelta(minutes=30)),
            "incident": "INC-585",
            "issued_at": stamp(NOW),
            "issuer": "release-security@example.test",
            "nonce": "c" * 64,
            "target": target,
        }
        return payload, current, target

    def test_signed_rollback_is_context_separated_and_nonce_is_one_use(self) -> None:
        payload, current, target = self.rollback_payload()
        document = contract.sign_document(
            {"schema_version": contract.ROLLBACK_SCHEMA, "signed": payload},
            contract.ROLLBACK_SCHEMA,
            contract.ROLLBACK_CONTEXT,
            self.private_key,
            "test-key",
        )
        contract.verify_document(document, contract.ROLLBACK_SCHEMA, contract.ROLLBACK_CONTEXT, self.public_key)
        with self.assertRaises(contract.ContractError):
            contract.verify_document(document, contract.ROLLBACK_SCHEMA, contract.ENVELOPE_CONTEXT, self.public_key)
        nonce = contract.validate_rollback_payload(document["signed"], now=NOW, current_state=current, target_state=target)
        receipts = self.root / "receipts"
        contract.consume_authorization_receipt(receipts, kind="rollback", nonce=nonce, details={"incident": "INC-585"})
        with self.assertRaisesRegex(contract.ContractError, "already consumed"):
            contract.consume_authorization_receipt(receipts, kind="rollback", nonce=nonce, details={})
        self.assertEqual((next(receipts.iterdir()).stat().st_mode & 0o777), 0o600)

    def test_rollback_rejects_future_expired_wrong_binding_and_nonrollback_target(self) -> None:
        payload, current, target = self.rollback_payload()
        cases = []
        future = dict(payload, issued_at=stamp(NOW + dt.timedelta(seconds=301)))
        cases.append((future, current, target, "future-dated"))
        expired = dict(payload, expires_at=stamp(NOW))
        cases.append((expired, current, target, "expired"))
        cases.append((payload, self.state(10, 50, 50, "a" * 64), target, "binding differs"))
        newer = self.state(10, 51, 51, "d" * 64)
        newer_payload = dict(payload, target=newer)
        cases.append((newer_payload, current, newer, "strictly older"))
        digest_swap = self.state(9, 50, 50, "e" * 64)
        cases.append((dict(payload, target=digest_swap), current, digest_swap, "strictly older"))
        for candidate, bound_current, bound_target, message in cases:
            with self.subTest(message=message), self.assertRaisesRegex(contract.ContractError, message):
                contract.validate_rollback_payload(candidate, now=NOW, current_state=bound_current, target_state=bound_target)

    def test_rotation_requires_higher_generation_exact_overlap_and_audit(self) -> None:
        current = (1, "1" * 64, 1, "2" * 64)
        successor = (2, "3" * 64, 2, "4" * 64)
        overlap = b"canonical overlap release index"
        payload = {
            "audit": {"report_sha256": "5" * 64, "reviewer": "security-reviewer@example.test"},
            "current_trust": {
                "keyring_generation": 1,
                "keyring_sha256": "1" * 64,
                "retiring_key_id": "old-key",
                "revocations_generation": 1,
                "revocations_sha256": "2" * 64,
            },
            "expires_at": stamp(NOW + dt.timedelta(hours=1)),
            "incident": "ROT-585",
            "issued_at": stamp(NOW),
            "issuer": "release-security@example.test",
            "overlap_index": {"index_generation": 11, "sha256": contract.hashlib.sha256(overlap).hexdigest()},
            "rotation_id": "6" * 64,
            "successor_trust": {
                "keyring_generation": 2,
                "keyring_sha256": "3" * 64,
                "revocations_generation": 2,
                "revocations_sha256": "4" * 64,
                "successor_key_id": "new-key",
            },
        }
        rotation_id = contract.validate_rotation_payload(
            payload,
            now=NOW,
            current=current,
            successor=successor,
            retiring_key_id="old-key",
            successor_key_id="new-key",
            overlap_index_sha256=contract.hashlib.sha256(overlap).hexdigest(),
            minimum_index_generation=10,
        )
        self.assertEqual(rotation_id, "6" * 64)
        retiring_signature = contract.sign_payload(payload, contract.ROTATION_RETIRING_CONTEXT, self.private_key, "old-key")
        successor_signature = contract.sign_payload(payload, contract.ROTATION_SUCCESSOR_CONTEXT, self.successor_private_key, "new-key")
        contract.verify_signature(retiring_signature, payload, contract.ROTATION_RETIRING_CONTEXT, self.public_key)
        contract.verify_signature(successor_signature, payload, contract.ROTATION_SUCCESSOR_CONTEXT, self.successor_public_key)
        with self.assertRaises(contract.ContractError):
            contract.verify_signature(successor_signature, payload, contract.ROTATION_RETIRING_CONTEXT, self.successor_public_key)
        receipts = self.root / "rotation-receipts"
        receipt_details = {
            "current_keyring_sha256": current[1],
            "successor_keyring_sha256": successor[1],
            "retiring_key_id": "old-key",
            "successor_key_id": "new-key",
        }
        contract.consume_authorization_receipt(receipts, kind="rotation-overlap", nonce=rotation_id, details=receipt_details)
        contract.validate_authorization_receipt(
            receipts,
            kind="rotation-overlap",
            nonce=rotation_id,
            expected_details={"successor_keyring_sha256": successor[1], "retiring_key_id": "old-key", "successor_key_id": "new-key"},
        )
        with self.assertRaises(contract.ContractError):
            contract.validate_authorization_receipt(
                receipts,
                kind="rotation-overlap",
                nonce=rotation_id,
                expected_details={"successor_keyring_sha256": "f" * 64},
            )
        with self.assertRaisesRegex(contract.ContractError, "trust binding differs|generation must advance"):
            contract.validate_rotation_payload(
                payload,
                now=NOW,
                current=current,
                successor=current,
                retiring_key_id="old-key",
                successor_key_id="new-key",
                overlap_index_sha256=contract.hashlib.sha256(overlap).hexdigest(),
                minimum_index_generation=10,
            )
        with self.assertRaisesRegex(contract.ContractError, "digest"):
            contract.validate_rotation_payload(
                payload,
                now=NOW,
                current=current,
                successor=successor,
                retiring_key_id="old-key",
                successor_key_id="new-key",
                overlap_index_sha256="f" * 64,
                minimum_index_generation=10,
            )

    def test_initial_key_pin_rejects_self_authored_keyrings_in_all_paths(self) -> None:
        canonical = lambda value: json.dumps(value, sort_keys=True, separators=(",", ":")).encode()
        attacker_der = subprocess.run(
            ["openssl", "pkey", "-pubin", "-in", self.public_key, "-outform", "DER"],
            check=True,
            capture_output=True,
        ).stdout
        attacker_digest = hashlib.sha256(attacker_der).hexdigest()
        attacker_public = self.root / "release-signing-public.pem"
        attacker_public.write_bytes(self.public_key.read_bytes())
        keyring = {
            "generation": 1,
            "keys": [{
                "algorithm": contract.SIGNATURE_ALGORITHM,
                "key_id": contract.INITIAL_KEY_ID,
                "public_key_path": attacker_public.name,
                "public_key_spki_sha256": attacker_digest,
                "status": "active",
            }],
            "schema_version": contract.KEYRING_SCHEMA,
        }
        revocations = {
            "generation": 1,
            "issued_at": stamp(NOW),
            "keyring_generation": 1,
            "revoked_key_ids": [],
            "revoked_keyring_generations": [],
            "schema_version": contract.REVOCATIONS_SCHEMA,
        }
        keyring_path = self.root / "attacker-keyring.json"
        revocations_path = self.root / "attacker-revocations.json"
        keyring_path.write_bytes(canonical(keyring))
        revocations_path.write_bytes(canonical(revocations))

        with self.assertRaisesRegex(contract.ContractError, "initial release key digest"):
            contract.load_trusted_key(
                keyring_path,
                revocations_path,
                expected_key_id=contract.INITIAL_KEY_ID,
                minimum_keyring_generation=1,
            )

        # The overlap-rotation command must fail at the same centralized pin,
        # before it can trust attacker-authored successor policy or signatures.
        command = subprocess.run(
            [
                sys.executable,
                str(ROOT / "scripts/malibu-release-envelope.py"),
                "validate-rotation",
                "--input", str(self.root / "attacker-rotation.json"),
                "--current-keyring", str(keyring_path),
                "--current-revocations", str(revocations_path),
                "--successor-keyring", str(keyring_path),
                "--successor-revocations", str(revocations_path),
                "--retiring-key-id", contract.INITIAL_KEY_ID,
                "--successor-key-id", "attacker-successor",
                "--overlap-index", str(self.root / "attacker-index.json"),
                "--minimum-index-generation", "1",
                "--receipt-directory", str(self.root / "receipts"),
                "--now", stamp(NOW),
            ],
            text=True,
            capture_output=True,
            check=False,
        )
        self.assertNotEqual(command.returncode, 0)
        self.assertIn("initial release key digest", command.stderr)

        # Even the genuine pinned bytes may not be redirected through a
        # keyring-selected filename; the bootstrap filename is fixed too.
        genuine_public = ROOT / "phase3-binary/app/release-trust/release-signing-public.pem"
        redirected = self.root / "attacker-selected-name.pem"
        redirected.write_bytes(genuine_public.read_bytes())
        keyring["keys"][0]["public_key_spki_sha256"] = contract.INITIAL_PUBLIC_KEY_SHA256
        keyring["keys"][0]["public_key_path"] = redirected.name
        keyring_path.write_bytes(canonical(keyring))
        with self.assertRaisesRegex(contract.ContractError, "initial release key path"):
            contract.load_trusted_key(
                keyring_path,
                revocations_path,
                expected_key_id=contract.INITIAL_KEY_ID,
                minimum_keyring_generation=1,
            )


if __name__ == "__main__":
    unittest.main()
