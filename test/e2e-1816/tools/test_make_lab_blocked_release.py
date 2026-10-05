#!/usr/bin/env python3
import base64
import hashlib
import json
import pathlib
import subprocess
import tempfile
import unittest


ROOT = pathlib.Path(__file__).resolve().parents[3]
SCRIPT = pathlib.Path(__file__).with_name("make-lab-blocked-release.py")
FEEDS = ROOT / "phase3-binary" / "dist" / "static"


class MakeLabBlockedReleaseTest(unittest.TestCase):
    def test_rebinds_and_resigns_continuous_batching_policy(self):
        with tempfile.TemporaryDirectory() as td:
            tmp = pathlib.Path(td)
            key = tmp / "lab.pem"
            out = tmp / "out"
            subprocess.run(
                ["openssl", "genpkey", "-algorithm", "ED25519", "-out", key],
                check=True,
                capture_output=True,
            )

            subprocess.run(
                [
                    "python3",
                    SCRIPT,
                    "--feeds",
                    FEEDS,
                    "--key",
                    key,
                    "--key-id",
                    "e2e-lab-catalog-v1",
                    "--blocked-hash",
                    "ab" * 32,
                    "--out",
                    out,
                ],
                check=True,
                capture_output=True,
                text=True,
            )

            candidate = (out / "autotune-candidates.json").read_bytes()
            policy = json.loads((out / "continuous-batching-policy.json").read_text())
            self.assertEqual(policy["signer_key_id"], "e2e-lab-catalog-v1")
            self.assertEqual(
                policy["candidate_catalog_sha256"], hashlib.sha256(candidate).hexdigest()
            )

            sidecar = json.loads(
                (out / "continuous-batching-policy.json.sig").read_text()
            )
            self.assertEqual(sidecar["key_id"], "e2e-lab-catalog-v1")
            pub = tmp / "lab.pub.pem"
            subprocess.run(
                ["openssl", "pkey", "-in", key, "-pubout", "-out", pub],
                check=True,
                capture_output=True,
            )
            signature = tmp / "policy.sig"
            signature.write_bytes(base64.b64decode(sidecar["signature"]))
            subprocess.run(
                [
                    "openssl",
                    "pkeyutl",
                    "-verify",
                    "-rawin",
                    "-pubin",
                    "-inkey",
                    pub,
                    "-in",
                    out / "continuous-batching-policy.json",
                    "-sigfile",
                    signature,
                ],
                check=True,
                capture_output=True,
            )


if __name__ == "__main__":
    unittest.main()
