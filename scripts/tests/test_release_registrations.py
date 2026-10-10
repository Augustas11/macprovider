"""Unit tests for scripts/ops/lib/release-registrations.py decisions."""
import base64
import importlib.util
import json
import pathlib
import subprocess
import sys
import tempfile
import time
import unittest

SCRIPT = pathlib.Path(__file__).resolve().parents[1] / "ops" / "lib" / "release-registrations.py"
spec = importlib.util.spec_from_file_location("release_registrations_under_test", SCRIPT)
rr = importlib.util.module_from_spec(spec)
spec.loader.exec_module(rr)

VERSION = "1.8.240"
CDHASH = "cd" * 20
COMPAT = "test/repo:v%s@%s" % (VERSION, "ab" * 20)
TARGET = "test/repo:v1.8.230@%s" % ("cd" * 20)


class ExpiryTest(unittest.TestCase):
    NOW = 1_800_000_000.0  # 2027-01-15T08:00:00Z

    def test_offsets_are_instants(self):
        # 10:00+03:00 is 07:00Z (past); 06:00-03:00 is 09:00Z (future).
        self.assertTrue(rr.expired("2027-01-15T10:00:00+03:00", self.NOW))
        self.assertFalse(rr.expired("2027-01-15T06:00:00-03:00", self.NOW))
        self.assertTrue(rr.expired("2027-01-15T07:59:59Z", self.NOW))
        self.assertFalse(rr.expired("2027-01-15T08:00:00.5Z", self.NOW))
        self.assertFalse(rr.expired("2027-01-15 09:00:00+00:00", self.NOW))  # YAML datetime str()
        self.assertFalse(rr.expired("", self.NOW))
        self.assertTrue(rr.expired("not a time", self.NOW))

    def test_tie_is_expired(self):
        self.assertTrue(rr.expired("2027-01-15T08:00:00Z", self.NOW))


class EvaluateTest(unittest.TestCase):
    def setUp(self):
        self.dir = pathlib.Path(tempfile.mkdtemp())
        key = self.dir / "k.pem"
        subprocess.run(["openssl", "ecparam", "-name", "prime256v1", "-genkey", "-noout", "-out", str(key)], check=True)
        pub = subprocess.run(["openssl", "ec", "-in", str(key), "-pubout"], check=True, capture_output=True).stdout
        self.prj = self.dir / "pearl-release.json"
        self.prj.write_text(json.dumps({"provider_code_identity": {
            "binary_version": VERSION, "team_id": "ABCDE12345", "signing_identifier": "live.malibu.provider.cli",
            "slices": [{"arch": "arm64", "code_cdhash": CDHASH}]}}))
        subprocess.run(["openssl", "dgst", "-sha256", "-sign", str(key), "-out", str(self.prj) + ".sig", str(self.prj)], check=True)
        digests = {"config_sha256": "a" * 64, "overlay_sha256": "b" * 64}
        self.facts = {
            "target_id": TARGET, "accepted_ids": [], "revoked_ids": [], "privacy_class_enabled": True,
            "approved_code_identities": [], "denied_code_cdhashes": [],
            "metadata_dir": "/m", "public_key_path": "/k.pem", "public_key_pem": pub.decode(),
            "disk_digests": dict(digests), "boot_digests": dict(digests), "loaded_versions": [VERSION],
            "metadata": {"json_b64": base64.b64encode(self.prj.read_bytes()).decode(),
                         "sig_b64": base64.b64encode(pathlib.Path(str(self.prj) + ".sig").read_bytes()).decode()},
            "metadata_error": "",
        }

    def verdict(self, compat=COMPAT, health=None, **changes):
        facts = dict(self.facts, **changes)
        path = self.dir / "facts.json"
        path.write_text(json.dumps(facts))
        if health is None:
            health = {"compatibility_policy_mode": "repository", "compatibility_policy_target_id": facts["target_id"],
                      "compatibility_policy_revoked_ids": facts["revoked_ids"]}
        hpath = self.dir / "healthz.json"
        hpath.write_text(json.dumps(health))
        out = subprocess.run([sys.executable, str(SCRIPT), "evaluate", str(path), VERSION, compat,
                              str(self.prj), str(self.prj) + ".sig", str(hpath)], check=True, capture_output=True, text=True)
        return json.loads(out.stdout)

    def test_admission_is_by_policy_not_by_listing(self):
        v = self.verdict()
        self.assertTrue(v["compat_accepted"])
        self.assertEqual(v["compat_rejection"], "")

    def test_exact_revocation_refuses(self):
        v = self.verdict(revoked_ids=[COMPAT])
        self.assertFalse(v["compat_accepted"])
        self.assertEqual(v["compat_rejection"], "provider_release_revoked")

    def test_live_policy_must_equal_the_applied_config(self):
        # The running coordinator holds a stricter policy than the disk config.
        stale = {"compatibility_policy_mode": "repository", "compatibility_policy_target_id": TARGET,
                 "compatibility_policy_revoked_ids": [COMPAT]}
        v = self.verdict(health=stale)
        self.assertFalse(v["compat_accepted"])
        self.assertIn("revoked_ids differ", v["policy_mismatch"])
        moved = dict(stale, compatibility_policy_revoked_ids=[], compatibility_policy_target_id=COMPAT)
        self.assertIn("target", self.verdict(health=moved)["policy_mismatch"])
        self.assertIn("not repository", self.verdict(health={"compatibility_policy_mode": "unconfigured"})["policy_mismatch"])
        self.assertIn("unreadable", self.verdict(health=[])["policy_mismatch"])

    def test_runtime_without_a_mode_admits_only_its_exact_list(self):
        v = self.verdict(health={"status": "ok"})
        self.assertEqual((v["compat_mode"], v["compat_rejection"]), ("legacy_exact", "compatibility_set_unaccepted"))
        self.assertIn("pearl-runtime.sh", " ".join(v["missing"]))
        self.assertTrue(self.verdict(health={"status": "ok"}, accepted_ids=[COMPAT])["compat_accepted"])

    def test_live_release_approval(self):
        v = self.verdict()
        self.assertEqual(v["missing"], [])
        self.assertEqual(v["approved_by"], "release_metadata")
        self.assertEqual(v["metadata_state"], "staged")

    def test_release_file_not_loaded_by_running_coordinator(self):
        for loaded in (None, ["1.0.0"]):
            v = self.verdict(loaded_versions=loaded)
            self.assertIn("does not report v%s as loaded" % VERSION, " ".join(v["missing"]))

    def test_config_must_equal_the_boot_config(self):
        v = self.verdict(boot_digests=None)
        self.assertIn("booted with", " ".join(v["missing"]))
        v = self.verdict(disk_digests={"config_sha256": "c" * 64, "overlay_sha256": "b" * 64})
        self.assertIn("booted with", " ".join(v["missing"]))

    def test_config_entry_needs_applied_config_and_offset_expiry(self):
        entry = {"team_id": "ABCDE12345", "signing_identifier": "live.malibu.provider.cli",
                 "code_cdhash": CDHASH, "binary_version": VERSION}
        later = time.strftime("%Y-%m-%dT%H:%M:%S", time.gmtime(time.time() + 3600))
        ok = self.verdict(loaded_versions=None, approved_code_identities=[dict(entry, expires_at=later + "-00:00")])
        self.assertEqual((ok["missing"], ok["approved_by"]), ([], "approved_code_identities"))
        # Two hours of UTC+03:00 offset turns "an hour ahead" into the past.
        gone = self.verdict(approved_code_identities=[dict(entry, expires_at=later + "+03:00")])
        self.assertIn("expired", " ".join(gone["missing"]))
        unapplied = self.verdict(loaded_versions=None, approved_code_identities=[entry], boot_digests=None)
        self.assertEqual(unapplied["approved_by"], "")

    def test_unknown_compatibility_id_fails_closed(self):
        v = self.verdict(compat="")
        self.assertFalse(v["compat_accepted"])
        self.assertIn("compatibility_set_id is unknown", " ".join(v["missing"]))

    def test_target_applied_needs_target_and_applied_config(self):
        self.assertFalse(self.verdict()["target_applied"])
        self.assertTrue(self.verdict(target_id=COMPAT)["target_applied"])
        self.assertFalse(self.verdict(target_id=COMPAT, boot_digests=None)["target_applied"])

    def test_privacy_class_disabled_fails(self):
        self.assertIn("privacy_class.enabled", " ".join(self.verdict(privacy_class_enabled=False)["missing"]))


class CompatVerdictTest(unittest.TestCase):
    def test_parity_with_the_coordinator(self):
        target = TARGET
        self.assertEqual(rr.compat_verdict(target, [], "test/repo:v1.0.0@%s" % ("ab" * 20)), "")
        self.assertEqual(rr.compat_verdict(target, [], "other/repo:v1.8.240@%s" % ("ab" * 20)),
                         "compatibility_set_repository_mismatch")
        for bad in ("test/repo:v1.8.0240@%s" % ("ab" * 20), "test/repo:v9223372036854775808.0.0@%s" % ("ab" * 20),
                    "test/repo:v1.8.240@%s" % ("AB" * 20), ""):
            self.assertIn(rr.compat_verdict(target, [], bad), ("compatibility_set_invalid", "compatibility_set_required"))
        self.assertEqual(rr.compat_verdict(target, [], "test/repo:v9223372036854775807.0.0@%s" % ("ab" * 20)), "")


if __name__ == "__main__":
    unittest.main()
