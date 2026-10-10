"""Unit tests for scripts/ops/lib/pearl-cli-config.py plan() (SPEC-002-R004)."""
import argparse
import datetime
import importlib.util
import pathlib
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
    base = dict(recommend=None, privacy_setup=None)
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
                            ("test/repo:v9223372036854775808.0.0@%s" % SHA, "malformed")):
            with self.assertRaisesRegex(pcc.Refused, why):
                pcc.plan(CONFIG, args(recommend=("1.8.240", target)), NOW)


if __name__ == "__main__":
    unittest.main()
