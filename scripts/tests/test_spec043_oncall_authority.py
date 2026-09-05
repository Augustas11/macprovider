from __future__ import annotations

import hashlib
import json
import shutil
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parents[2]
SCRIPTS = REPO_ROOT / "scripts"
if str(SCRIPTS) not in sys.path:
    sys.path.insert(0, str(SCRIPTS))

import spec043_oncall_authority as oncall  # noqa: E402


def _gen_ed25519_public_pem(tmp: Path) -> str:
    priv = tmp / "priv.pem"
    pub = tmp / "pub.pem"
    subprocess.run(["openssl", "genpkey", "-algorithm", "ED25519", "-out", str(priv)], check=True)
    subprocess.run(["openssl", "pkey", "-in", str(priv), "-pubout", "-out", str(pub)], check=True)
    return pub.read_text(encoding="utf-8")


def _empty_keyring(root: Path) -> None:
    (root / "security").mkdir(parents=True, exist_ok=True)
    (root / oncall.KEYRING_PATH).write_text(
        json.dumps(
            {
                "schema_version": oncall.KEYRING_SCHEMA_VERSION,
                "purpose": oncall.KEYRING_PURPOSE,
                "allowed_environment_classes": ["production"],
                "keys": [],
            }
        )
        + "\n",
        encoding="utf-8",
    )


@unittest.skipUnless(shutil.which("openssl"), "openssl required")
class OnCallAuthorityKeyringTest(unittest.TestCase):
    def test_digest_matches_sha256_of_raw_pubkey(self) -> None:
        with tempfile.TemporaryDirectory() as raw:
            tmp = Path(raw)
            pem = _gen_ed25519_public_pem(tmp)
            der = subprocess.run(
                ["openssl", "pkey", "-pubin", "-outform", "DER"],
                input=pem.encode(),
                capture_output=True,
                check=True,
            ).stdout
            self.assertEqual(len(der), 44)
            expected = hashlib.sha256(der[-32:]).hexdigest()
            digest, errors = oncall.authority_key_sha256(pem)
            self.assertEqual(errors, [])
            self.assertEqual(digest, expected)

    def test_preflight_is_fail_closed_on_empty_keyring(self) -> None:
        with tempfile.TemporaryDirectory() as raw:
            root = Path(raw)
            _empty_keyring(root)
            outcome = oncall.preflight_keyring(root)
            self.assertTrue(outcome.errors)
            self.assertIn("fail-closed", " ".join(outcome.errors))

    def test_register_then_preflight_passes_and_digests_match(self) -> None:
        with tempfile.TemporaryDirectory() as raw:
            root = Path(raw)
            _empty_keyring(root)
            with tempfile.TemporaryDirectory() as keydir:
                pem = _gen_ed25519_public_pem(Path(keydir))
            reg = oncall.register_public_key(
                root,
                pem,
                issuer="macprovider-ops",
                valid_from="2026-09-05T00:00:00Z",
                valid_until="2027-09-05T00:00:00Z",
            )
            self.assertEqual(reg.errors, [])
            self.assertTrue((root / oncall.PUBLIC_KEY_PATH).is_file())
            data = json.loads((root / oncall.KEYRING_PATH).read_text())
            self.assertEqual(len(data["keys"]), 1)
            self.assertEqual(data["keys"][0]["public_key_sha256"], reg.digest)
            pre = oncall.preflight_keyring(root)
            self.assertEqual(pre.errors, [])
            self.assertEqual(pre.digest, reg.digest)

    def test_register_refuses_to_overwrite_existing_key(self) -> None:
        with tempfile.TemporaryDirectory() as raw:
            root = Path(raw)
            _empty_keyring(root)
            with tempfile.TemporaryDirectory() as keydir:
                pem = _gen_ed25519_public_pem(Path(keydir))
            first = oncall.register_public_key(
                root, pem, issuer="macprovider-ops",
                valid_from="2026-09-05T00:00:00Z", valid_until="2027-09-05T00:00:00Z",
            )
            self.assertEqual(first.errors, [])
            with tempfile.TemporaryDirectory() as keydir2:
                pem2 = _gen_ed25519_public_pem(Path(keydir2))
            second = oncall.register_public_key(
                root, pem2, issuer="macprovider-ops",
                valid_from="2026-09-05T00:00:00Z", valid_until="2027-09-05T00:00:00Z",
            )
            self.assertTrue(second.errors)

    def test_preflight_rejects_digest_drift(self) -> None:
        # The committed keyring is the authority: if the recorded digest does not
        # match the committed PEM, preflight must fail closed rather than trust
        # the PEM.
        with tempfile.TemporaryDirectory() as raw:
            root = Path(raw)
            _empty_keyring(root)
            with tempfile.TemporaryDirectory() as keydir:
                pem = _gen_ed25519_public_pem(Path(keydir))
            reg = oncall.register_public_key(
                root, pem, issuer="macprovider-ops",
                valid_from="2026-09-05T00:00:00Z", valid_until="2027-09-05T00:00:00Z",
            )
            self.assertEqual(reg.errors, [])
            # Tamper the recorded digest to simulate a stale/mismatched entry.
            data = json.loads((root / oncall.KEYRING_PATH).read_text())
            data["keys"][0]["public_key_sha256"] = "0" * 64
            (root / oncall.KEYRING_PATH).write_text(json.dumps(data) + "\n", encoding="utf-8")
            outcome = oncall.preflight_keyring(root)
            self.assertTrue(outcome.errors)
            self.assertIn("does not match", " ".join(outcome.errors))

    def test_register_rejects_private_key_material(self) -> None:
        with tempfile.TemporaryDirectory() as raw:
            root = Path(raw)
            _empty_keyring(root)
            with tempfile.TemporaryDirectory() as keydir:
                priv = Path(keydir) / "priv.pem"
                subprocess.run(["openssl", "genpkey", "-algorithm", "ED25519", "-out", str(priv)], check=True)
                pub = _gen_ed25519_public_pem(Path(keydir))
                # Concatenate public + private material.
                poisoned = pub + priv.read_text(encoding="utf-8")
            outcome = oncall.register_public_key(
                root, poisoned, issuer="macprovider-ops",
                valid_from="2026-09-05T00:00:00Z", valid_until="2027-09-05T00:00:00Z",
            )
            self.assertTrue(outcome.errors)
            self.assertFalse((root / oncall.PUBLIC_KEY_PATH).exists())

    def test_register_rejects_non_ed25519_key(self) -> None:
        with tempfile.TemporaryDirectory() as raw:
            root = Path(raw)
            _empty_keyring(root)
            with tempfile.TemporaryDirectory() as keydir:
                priv = Path(keydir) / "x.pem"
                pub = Path(keydir) / "x_pub.pem"
                subprocess.run(["openssl", "genpkey", "-algorithm", "X25519", "-out", str(priv)], check=True)
                subprocess.run(["openssl", "pkey", "-in", str(priv), "-pubout", "-out", str(pub)], check=True)
                x25519_pem = pub.read_text(encoding="utf-8")
            outcome = oncall.register_public_key(
                root, x25519_pem, issuer="macprovider-ops",
                valid_from="2026-09-05T00:00:00Z", valid_until="2027-09-05T00:00:00Z",
            )
            self.assertTrue(outcome.errors)

    def test_preflight_rejects_expired_validity_window(self) -> None:
        with tempfile.TemporaryDirectory() as raw:
            root = Path(raw)
            _empty_keyring(root)
            with tempfile.TemporaryDirectory() as keydir:
                pem = _gen_ed25519_public_pem(Path(keydir))
            oncall.register_public_key(
                root, pem, issuer="macprovider-ops",
                valid_from="2020-01-01T00:00:00Z", valid_until="2020-01-02T00:00:00Z",
            )
            outcome = oncall.preflight_keyring(root)
            self.assertTrue(outcome.errors)
            self.assertIn("expired", " ".join(outcome.errors))

    def test_preflight_rejects_wrong_purpose(self) -> None:
        with tempfile.TemporaryDirectory() as raw:
            root = Path(raw)
            _empty_keyring(root)
            with tempfile.TemporaryDirectory() as keydir:
                pem = _gen_ed25519_public_pem(Path(keydir))
            oncall.register_public_key(
                root, pem, issuer="macprovider-ops",
                valid_from="2026-09-05T00:00:00Z", valid_until="2027-09-05T00:00:00Z",
            )
            data = json.loads((root / oncall.KEYRING_PATH).read_text())
            data["keys"][0]["purpose"] = "not-the-oncall-purpose"
            (root / oncall.KEYRING_PATH).write_text(json.dumps(data) + "\n", encoding="utf-8")
            outcome = oncall.preflight_keyring(root)
            self.assertTrue(outcome.errors)


if __name__ == "__main__":
    unittest.main()
