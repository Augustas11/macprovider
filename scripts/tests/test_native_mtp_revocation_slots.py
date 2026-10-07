"""Pre-signed native-MTP revocation slots (SPEC-023 §12.5, G5)."""

from __future__ import annotations

import base64
import importlib.util
import json
import os
import pathlib
import subprocess
import tempfile
import unittest
from datetime import datetime, timezone

ROOT = pathlib.Path(__file__).resolve().parents[2]
_spec = importlib.util.spec_from_file_location("native_mtp_revocation_slots", ROOT / "scripts" / "native_mtp_revocation_slots.py")
slots = importlib.util.module_from_spec(_spec)
_spec.loader.exec_module(slots)


class RevocationSlotsTest(unittest.TestCase):
    KEY_ID = "streamvc-autotune-static-test"

    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.dir = pathlib.Path(self.tmp.name)
        tool = slots.openssl()
        pem = self.dir / "key.pem"
        subprocess.run([tool, "genpkey", "-algorithm", "ed25519", "-out", str(pem)], check=True, capture_output=True)
        der = subprocess.run([tool, "pkey", "-in", str(pem), "-outform", "DER"], check=True, capture_output=True).stdout
        pub = subprocess.run([tool, "pkey", "-in", str(pem), "-pubout", "-outform", "DER"], check=True, capture_output=True).stdout
        self.key_file = self.dir / "key.base64"
        self.key_file.write_text(base64.b64encode(der[-32:]).decode("ascii"))
        os.chmod(self.key_file, 0o600)
        self.public_key = base64.b64encode(pub[-32:]).decode("ascii")
        self.revoked = self.dir / "revoked.json"
        self.write_revoked(["a" * 64])

    def tearDown(self):
        self.tmp.cleanup()

    def write_revoked(self, items):
        self.revoked.write_text(json.dumps({
            "schema_version": slots.SOURCE_SCHEMA,
            "revoked_admission_tuple_sha256": items,
        }))

    def build(self, out: pathlib.Path, start="2026-10-07T00:00:00Z", days=1, minutes=10) -> int:
        return slots.main([
            "build", "--key-file", str(self.key_file), "--key-id", self.KEY_ID,
            "--revoked", str(self.revoked), "--start", start, "--days", str(days),
            "--slot-minutes", str(minutes), "--out", str(out),
        ])

    def write_admission_and_trusted_keys(self):
        admission = self.dir / "native-mtp-admission.json"
        admission.write_text(json.dumps({"revocation_signer_key_id": self.KEY_ID}))
        trusted = self.dir / "trusted-keys.json"
        trusted.write_text(json.dumps({
            "schema_version": "macprovider.autotune-keys.v1",
            "keys": {
                self.KEY_ID: {
                    "public_key_base64": self.public_key,
                    "status": "active",
                },
            },
        }))
        return admission, trusted

    def verify_current(self, directory: pathlib.Path, now: str) -> int:
        admission, trusted = self.write_admission_and_trusted_keys()
        return slots.main([
            "verify-current", "--dir", str(directory), "--admission", str(admission),
            "--trusted-keys", str(trusted), "--now", now,
        ])

    def test_build_signs_one_canonical_body_per_slot_and_verifies(self):
        out = self.dir / "slots"
        self.assertEqual(self.build(out), 0)
        bodies = sorted(out.glob("*.json"))
        self.assertEqual(len(bodies), 24 * 6)
        first = json.loads(bodies[0].read_bytes())
        start = int(datetime(2026, 10, 7, tzinfo=timezone.utc).timestamp())
        self.assertEqual(first["generation"], start)
        self.assertEqual(first["issued_at"], "2026-10-07T00:00:00Z")
        self.assertEqual(first["expires_at"], "2026-10-07T01:00:00Z")
        self.assertEqual(first["revoked_admission_tuple_sha256"], ["a" * 64])
        self.assertEqual(bodies[0].read_bytes(), slots.canonical_bytes(first))
        generations = [json.loads(path.read_bytes())["generation"] for path in bodies]
        self.assertEqual(generations, sorted(set(generations)))
        self.assertEqual(slots.verify_slots(out, self.KEY_ID, self.public_key), 24 * 6)

    def test_verify_rejects_tampered_bodies_and_shrinking_revocation(self):
        out = self.dir / "slots"
        self.build(out, days=1, minutes=10)
        victim = sorted(out.glob("*.json"))[3]
        value = json.loads(victim.read_bytes())
        value["revoked_admission_tuple_sha256"] = []
        victim.write_bytes(slots.canonical_bytes(value))
        with self.assertRaises(slots.SlotError):
            slots.verify_slots(out, self.KEY_ID, self.public_key)

    def test_inputs_fail_closed(self):
        self.write_revoked(["b" * 64, "a" * 64])
        self.assertEqual(self.build(self.dir / "unsorted"), 1)
        self.write_revoked(["a" * 64])
        self.assertEqual(self.build(self.dir / "long-slots", minutes=11), 1)
        os.chmod(self.key_file, 0o644)
        self.assertEqual(self.build(self.dir / "loose-key"), 1)
        os.chmod(self.key_file, 0o600)
        occupied = self.dir / "occupied"
        occupied.mkdir()
        (occupied / "stray").write_text("x")
        self.assertEqual(self.build(occupied), 1)

    def test_emergency_batch_generations_exceed_the_served_slot(self):
        routine = self.dir / "routine"
        self.build(routine, start="2026-10-07T00:00:00Z")
        self.write_revoked(["a" * 64, "c" * 64])
        emergency = self.dir / "emergency"
        self.build(emergency, start="2026-10-07T05:03:17Z")
        served = max(
            json.loads(path.read_bytes())["generation"]
            for path in routine.glob("*.json")
            if json.loads(path.read_bytes())["issued_at"] <= "2026-10-07T05:03:17Z"
        )
        first = min(json.loads(path.read_bytes())["generation"] for path in emergency.glob("*.json"))
        self.assertGreater(first, served)

    def test_verify_current_requires_readable_current_signed_slot(self):
        valid = self.dir / "valid"
        self.build(valid, start="2026-10-07T00:00:00Z")
        self.assertEqual(self.verify_current(valid, "2026-10-07T00:05:00Z"), 0)

        missing = self.dir / "missing"
        missing.mkdir()
        self.assertEqual(self.verify_current(missing, "2026-10-07T00:05:00Z"), 1)
        self.assertEqual(self.verify_current(valid, "2026-10-08T01:00:00Z"), 1)

        tampered = self.dir / "tampered"
        self.build(tampered, start="2026-10-07T00:00:00Z")
        current = tampered / f"{int(datetime(2026, 10, 7, tzinfo=timezone.utc).timestamp())}.json"
        value = json.loads(current.read_bytes())
        value["revoked_admission_tuple_sha256"] = []
        current.write_bytes(slots.canonical_bytes(value))
        self.assertEqual(self.verify_current(tampered, "2026-10-07T00:05:00Z"), 1)

    def test_verify_current_rejects_retired_or_missing_revocation_signer(self):
        out = self.dir / "slots"
        self.build(out, start="2026-10-07T00:00:00Z")
        admission, trusted = self.write_admission_and_trusted_keys()
        keyring = json.loads(trusted.read_text())
        keyring["keys"][self.KEY_ID]["status"] = "retired"
        trusted.write_text(json.dumps(keyring))
        self.assertEqual(slots.main([
            "verify-current", "--dir", str(out), "--admission", str(admission),
            "--trusted-keys", str(trusted), "--now", "2026-10-07T00:05:00Z",
        ]), 1)


if __name__ == "__main__":
    unittest.main()
