"""Unit tests for the version_floor paths of scripts/ops/lib/pearl-cli-config.py."""
import argparse
import datetime
import importlib.util
import pathlib
import sqlite3
import tempfile
import unittest

SCRIPT = pathlib.Path(__file__).resolve().parents[1] / "ops" / "lib" / "pearl-cli-config.py"
spec = importlib.util.spec_from_file_location("pearl_cli_config_under_test", SCRIPT)
pcc = importlib.util.module_from_spec(spec)
spec.loader.exec_module(pcc)

SHA = "ab" * 20
TARGET = "test/repo:v1.8.232@%s" % SHA
LEGACY = """coordinator:
  compatibility_set:
    target_id: %s
    accepted_ids:
    - test/repo:v1.8.207@%s
    - %s
  require_gateway_context: true
coordinator_advertised_version:
  latest_binary_version: "1.8.232"
""" % (TARGET, SHA, TARGET)
NOW = datetime.datetime(2026, 10, 10, tzinfo=datetime.timezone.utc)


class FloorTest(unittest.TestCase):
    def setUp(self):
        self.db = pathlib.Path(tempfile.mkdtemp()) / "events.db"
        with sqlite3.connect(self.db) as db:
            db.execute("CREATE TABLE provider_connection_events (id INTEGER PRIMARY KEY, provider_id TEXT, "
                       "binary_version TEXT, occurred_at_utc TEXT)")
            db.executemany("INSERT INTO provider_connection_events (provider_id, binary_version, occurred_at_utc) "
                           "VALUES (?, ?, ?)", [
                               ("p1", "1.8.200", "2026-10-09T00:00:00Z"), ("p1", "1.8.224", "2026-10-09T12:00:00Z"),
                               ("p2", "1.8.230", "2026-10-09T00:00:00Z"),
                               ("p3", "1.8.100", "2026-09-01T00:00:00Z")])  # outside 14 days

    def args(self, **kw):
        base = dict(accepted_id=None, recommend=None, privacy_setup=None, migrate_floor=None, events_db=str(self.db))
        base.update(kw)
        return argparse.Namespace(**base)

    def test_migration_replaces_the_allowlist_with_the_floor(self):
        new, summary = pcc.plan(LEGACY, self.args(migrate_floor="1.8.224"), NOW)
        self.assertIn('    minimum_version: "1.8.224"\n', new)
        self.assertNotIn("accepted_ids", new)
        self.assertEqual(summary["minimum_version"], "1.8.224")

    def test_floor_above_a_providers_latest_version_is_refused(self):
        with self.assertRaisesRegex(pcc.Refused, "1 provider"):
            pcc.plan(LEGACY, self.args(migrate_floor="1.8.225"), NOW)

    def test_noncanonical_or_above_target_floor_is_refused(self):
        for floor in ("1.8.0224", "v1.8.224", "1.8.233"):
            with self.assertRaises(pcc.Refused):
                pcc.plan(LEGACY, self.args(migrate_floor=floor), NOW)

    def test_version_floor_never_edits_accepted_ids(self):
        floor_cfg, _ = pcc.plan(LEGACY, self.args(migrate_floor="1.8.224"), NOW)
        with self.assertRaisesRegex(pcc.Refused, "accepted_ids is not edited"):
            pcc.plan(floor_cfg, self.args(accepted_id="test/repo:v1.8.240@%s" % SHA), NOW)
        new_target = "test/repo:v1.8.240@%s" % SHA
        new, summary = pcc.plan(floor_cfg, self.args(recommend=("1.8.240", new_target)), NOW)
        self.assertIn("target_id: %s" % new_target, new)
        self.assertIn('minimum_version: "1.8.224"', new)
        self.assertNotIn("accepted_ids", new)
        with self.assertRaisesRegex(pcc.Refused, "below_minimum"):
            pcc.plan(floor_cfg, self.args(recommend=("1.8.200", "test/repo:v1.8.200@%s" % SHA)), NOW)

    def test_same_floor_is_a_no_op_and_a_different_floor_is_refused(self):
        floor_cfg, _ = pcc.plan(LEGACY, self.args(migrate_floor="1.8.224"), NOW)
        self.assertEqual(pcc.plan(floor_cfg, self.args(migrate_floor="1.8.224"), NOW)[0], floor_cfg)
        with self.assertRaisesRegex(pcc.Refused, "does not move a live floor"):
            pcc.plan(floor_cfg, self.args(migrate_floor="1.8.200"), NOW)


if __name__ == "__main__":
    unittest.main()
