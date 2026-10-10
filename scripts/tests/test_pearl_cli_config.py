"""Unit tests for scripts/ops/lib/pearl-cli-config.py plan() (SPEC-002-R004)."""
import argparse
import datetime
import importlib.util
import pathlib
import subprocess
import sys
import unittest

SCRIPT = pathlib.Path(__file__).resolve().parents[1] / "ops" / "lib" / "pearl-cli-config.py"
spec = importlib.util.spec_from_file_location("pearl_cli_config_under_test", SCRIPT)
pcc = importlib.util.module_from_spec(spec)
spec.loader.exec_module(pcc)

SHA = "ab" * 20
TARGET = "test/repo:v1.8.232@%s" % SHA
NEW = "test/repo:v1.8.240@%s" % SHA
CONFIG = """coordinator:
  compatibility_set:
    target_id: %s
    accepted_ids:
    - %s
    revoked_ids:
    - test/repo:v1.8.235@%s
  require_gateway_context: true
coordinator_advertised_version:
  latest_binary_version: "1.8.232"
""" % (TARGET, TARGET, SHA)
NOW = datetime.datetime(2026, 10, 10, tzinfo=datetime.timezone.utc)


def args(**kw):
    base = dict(recommend=None, privacy_setup=None, revoke=None)
    base.update(kw)
    return argparse.Namespace(**base)


class RecommendTest(unittest.TestCase):
    def test_recommend_moves_only_target_and_latest(self):
        new, summary = pcc.plan(CONFIG, args(recommend=("1.8.240", NEW)), NOW)
        self.assertEqual(summary, {"target_id": NEW, "latest_binary_version": "1.8.240"})
        self.assertIn("target_id: %s" % NEW, new)
        self.assertIn("    - %s\n" % TARGET, new)  # deprecated accepted_ids untouched

    def test_recommend_refuses_foreign_revoked_and_malformed_targets(self):
        for target, why in (("other/repo:v1.8.240@%s" % SHA, "repository"),
                            ("test/repo:v1.8.235@%s" % SHA, "revoked_ids"),
                            ("test/repo:v1.8.0240@%s" % SHA, "malformed"),
                            ("test/repo:v9223372036854775808.0.0@%s" % SHA, "malformed"),
                            (NEW + "\n", "malformed")):
            with self.assertRaisesRegex(pcc.Refused, why):
                pcc.plan(CONFIG, args(recommend=("1.8.240", target)), NOW)



class RevokeTest(unittest.TestCase):
    OLD1 = "test/repo:v1.8.100@%s" % SHA
    OLD2 = "test/repo:v1.8.101@%s" % SHA

    def test_revoke_appends_exact_ids_once(self):
        new, summary = pcc.plan(CONFIG, args(revoke=[self.OLD1, self.OLD2, self.OLD1, "test/repo:v1.8.235@%s" % SHA]), NOW)
        self.assertEqual(summary["revoked_added"], [self.OLD1, self.OLD2])
        self.assertIn("    - test/repo:v1.8.235@%s\n    - %s\n    - %s\n" % (SHA, self.OLD1, self.OLD2), new)

    def test_revoke_creates_the_list_after_target(self):
        bare = CONFIG.replace("    revoked_ids:\n    - test/repo:v1.8.235@%s\n" % SHA, "")
        new, _ = pcc.plan(bare, args(revoke=[self.OLD1]), NOW)
        self.assertIn("    target_id: %s\n    revoked_ids:\n    - %s\n" % (TARGET, self.OLD1), new)

    def test_revoke_refuses_target_and_foreign_ids(self):
        for item in (TARGET, "other/repo:v1.8.100@%s" % SHA, "test/repo:v1.8.0100@%s" % SHA):
            with self.assertRaises(pcc.Refused):
                pcc.plan(CONFIG, args(revoke=[item]), NOW)

    def test_rollback_recommends_older_and_revokes_the_current_target(self):
        # SPEC-020-R007: one edit moves the target back and revokes the release
        # it moves off; the new target itself stays unrevocable.
        bad = "test/repo:v1.8.233@%s" % ("cd" * 20)
        config = CONFIG.replace(TARGET, bad, 1).replace('"1.8.232"', '"1.8.233"')
        new, summary = pcc.plan(config, args(recommend=("1.8.232", TARGET), revoke=[bad]), NOW)
        self.assertEqual(summary, {"target_id": TARGET, "latest_binary_version": "1.8.232", "revoked_added": [bad]})
        self.assertIn("    target_id: %s\n" % TARGET, new)
        self.assertIn("    - %s\n" % bad, new)
        with self.assertRaisesRegex(pcc.Refused, "refusing to revoke the target"):
            pcc.plan(config, args(recommend=("1.8.232", TARGET), revoke=[bad, TARGET]), NOW)
        with self.assertRaisesRegex(pcc.Refused, "refusing to revoke the target"):
            pcc.plan(config, args(revoke=[bad]), NOW)

    def test_checked_in_seed_is_consistent(self):
        script = pathlib.Path(__file__).resolve().parents[1] / "legacy-compatibility-revocations.py"
        out = subprocess.run([sys.executable, str(script), "check"], capture_output=True, text=True)
        self.assertEqual(out.returncode, 0, out.stderr)


if __name__ == "__main__":
    unittest.main()
