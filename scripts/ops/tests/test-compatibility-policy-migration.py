#!/usr/bin/env python3
"""Exercise migration and rollback without a service or live configuration."""
import contextlib
import hashlib
import importlib.util
import io
import json
import os
from pathlib import Path
import subprocess
import tempfile
from types import SimpleNamespace
import unittest
from unittest.mock import patch

REAL_SUBPROCESS_RUN = subprocess.run
HELPER = Path(__file__).resolve().parents[1] / "lib/compatibility-policy.py"
spec = importlib.util.spec_from_file_location("migration_policy", HELPER)
policy = importlib.util.module_from_spec(spec)
spec.loader.exec_module(policy)
TARGET = "test/repo:v1.8.223@" + "a" * 40
ROLLBACK = "test/repo:v1.8.222@" + "b" * 40


class MigrationTest(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.base = Path(self.tmp.name) / "base.yaml"
        self.overlay = Path(self.tmp.name) / "overlay.yaml"
        self.state = Path(self.tmp.name) / "applied.json"
        self.base.write_text("coordinator:\n  compatibility_set:\n    target_id: %s\n    accepted_ids: [%s, %s]\n" % (TARGET, TARGET, ROLLBACK))
        self.original = b"routing:\n  default_objective: balanced\nunrelated_setting: keep-value\n"
        self.overlay.write_bytes(self.original)
        self.overlay.chmod(0o640)
        self.metadata = self.overlay.stat()
        self.record = {"schema": "macprovider.coordinator-applied-config.v1", "source": "boot", "config_path": str(self.base), "config_sha256": self.sha(self.base), "overlay_path": str(self.overlay), "overlay_sha256": self.sha(self.overlay)}
        self.state.write_text(json.dumps(self.record))
        self.addCleanup(patch.stopall)
        patch.object(policy, "STATE", str(self.state)).start()
        patch.object(policy, "service_environment", return_value={"OPERATOR_KEY": "test-token", "TEST_SERVICE_VALUE": "preserved"}).start()
        patch.object(policy.time, "sleep").start()
        patch.object(policy.subprocess, "check_output", return_value="12345\n").start()
        self.validate = patch.object(policy.subprocess, "run", return_value=SimpleNamespace(returncode=0)).start()
        self.signal_count = 0
        self.health = {"compatibility_policy_mode": "legacy_allowlist", "compatibility_policy_target_id": TARGET}

    @staticmethod
    def sha(path):
        return hashlib.sha256(path.read_bytes()).hexdigest()

    def acknowledge_signal(self, pid, sig):
        self.signal_count += 1
        current = policy.yaml.safe_load(self.overlay.read_bytes())
        floor = current.get("coordinator", {}).get("compatibility_set", {}).get("minimum_version", "")
        applied = dict(self.record, source="sighup", overlay_sha256=self.sha(self.overlay))
        self.state.write_text(json.dumps(applied))
        self.health = {"compatibility_policy_mode": "version_floor" if floor else "legacy_allowlist", "compatibility_policy_target_id": TARGET, "compatibility_policy_minimum_version": floor, "compatibility_policy_revoked_ids": []}

    def health_response(self, *args, **kwargs):
        return io.BytesIO(json.dumps(self.health).encode())

    def mock_migration(self, signal=None):
        patch.object(policy, "connected_fleet_allows").start()
        patch.object(policy.os, "kill", side_effect=signal or self.acknowledge_signal).start()
        patch.object(policy.urllib.request, "urlopen", side_effect=self.health_response).start()

    def assert_original(self):
        self.assertEqual(self.overlay.read_bytes(), self.original)
        after = self.overlay.stat()
        self.assertEqual((after.st_mode, after.st_uid, after.st_gid), (self.metadata.st_mode, self.metadata.st_uid, self.metadata.st_gid))

    def test_success_preserves_unrelated_fields_metadata_and_service_environment(self):
        self.mock_migration()
        output = io.StringIO()
        with contextlib.redirect_stdout(output):
            policy.migrate("1.8.222")
        value = policy.yaml.safe_load(self.overlay.read_bytes())
        self.assertEqual(value["routing"], {"default_objective": "balanced"})
        self.assertEqual(value["unrelated_setting"], "keep-value")
        self.assertEqual(value["coordinator"]["compatibility_set"]["accepted_ids"], [])
        self.assertEqual(json.loads(output.getvalue())["minimum_version"], "1.8.222")
        after = self.overlay.stat()
        self.assertEqual((after.st_mode, after.st_uid, after.st_gid), (self.metadata.st_mode, self.metadata.st_uid, self.metadata.st_gid))
        self.assertEqual(self.validate.call_args.kwargs["env"]["TEST_SERVICE_VALUE"], "preserved")
        self.assertNotIn("test-token", output.getvalue())
        self.assertEqual(self.signal_count, 1)

    def test_noncanonical_and_overflow_floor_fail_before_mutation(self):
        for floor in ["1.08.222", "1.8.0222", "9223372036854775808.8.222"]:
            with self.subTest(floor=floor), patch.object(policy, "atomic_write") as write, patch.object(policy, "connected_fleet_allows") as fleet:
                with self.assertRaises(RuntimeError):
                    policy.migrate(floor)
                write.assert_not_called()
                fleet.assert_not_called()
        self.assert_original()

    def test_inventory_rejection_happens_before_any_write_or_signal(self):
        with patch.object(policy, "connected_fleet_allows", side_effect=RuntimeError("floor above connected provider")), patch.object(policy, "atomic_write") as write, patch.object(policy.os, "kill") as signal:
            with self.assertRaisesRegex(RuntimeError, "above connected"):
                policy.migrate("1.8.999")
            write.assert_not_called()
            signal.assert_not_called()
        self.assert_original()

    def test_validator_failure_restores_bytes_and_proves_rollback(self):
        self.mock_migration()
        self.validate.return_value.returncode = 1
        with self.assertRaisesRegex(RuntimeError, "validation rejected"):
            policy.migrate("1.8.222")
        self.assert_original()
        self.assertEqual(self.signal_count, 1)
        self.assertEqual(json.loads(self.state.read_text())["overlay_sha256"], self.record["overlay_sha256"])

    def test_postflight_failure_restores_and_verifies_old_policy(self):
        def signal(pid, sig):
            if self.signal_count == 0:
                self.signal_count += 1  # simulate rejected reload
            else:
                self.acknowledge_signal(pid, sig)
        self.mock_migration(signal)
        with self.assertRaisesRegex(RuntimeError, "did not prove the migrated"):
            policy.migrate("1.8.222")
        self.assert_original()
        self.assertEqual(self.signal_count, 2)
        self.assertEqual(self.health["compatibility_policy_mode"], "legacy_allowlist")

    def test_unproved_rollback_is_reported_as_failure(self):
        def signal(pid, sig):
            self.signal_count += 1
        self.mock_migration(signal)
        with self.assertRaisesRegex(RuntimeError, "rollback SIGHUP did not prove"):
            policy.migrate("1.8.222")
        self.assert_original()
        self.assertEqual(self.signal_count, 2)

    def inventory(self, versions, count=None):
        return {"summary": {"connected": len(versions) if count is None else count}, "providers": [{"provider_id": "p%d" % i, "presence": "connected", "binary_version": v, "compatibility_set_id": "test/repo:v%s@%s" % (v, "a" * 40)} for i, v in enumerate(versions)]}

    def test_floor_above_any_connected_provider_is_refused(self):
        with patch.object(policy.urllib.request, "urlopen", return_value=io.BytesIO(json.dumps(self.inventory(["1.8.222", "1.8.223"])).encode())):
            with self.assertRaisesRegex(RuntimeError, "above a connected provider"):
                policy.connected_fleet_allows("1.8.223")

    def test_incomplete_and_unknown_connected_inventory_fail_closed(self):
        incomplete = self.inventory(["1.8.223"], count=2)
        unknown = self.inventory(["1.8.223"])
        unknown["providers"][0].pop("compatibility_set_id")
        for doc in [incomplete, unknown]:
            with self.subTest(doc=doc), patch.object(policy.urllib.request, "urlopen", return_value=io.BytesIO(json.dumps(doc).encode())):
                with self.assertRaises(RuntimeError):
                    policy.connected_fleet_allows("1.8.222")

    def test_internal_apply_cannot_bypass_ops_entrypoint(self):
        empty_env = Path(self.tmp.name) / "ops.env"
        empty_env.write_text("")
        env = dict(os.environ, MACPROVIDER_OPS_ENV=str(empty_env))
        env.pop("MACPROVIDER_OPS_ENTRYPOINT", None)
        result = REAL_SUBPROCESS_RUN(["bash", str(HELPER.parents[1] / "compatibility-policy-migrate.sh"), "_apply", "1.8.222"], env=env, capture_output=True, text=True)
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("internal", result.stderr)


if __name__ == "__main__":
    unittest.main()
