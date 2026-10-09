#!/usr/bin/env python3
"""Small offline regression coverage for the streamed policy helper."""
import contextlib
import hashlib
import importlib.util
import io
import json
import os
import tempfile
import unittest
from unittest import mock

ROOT = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
HELPER = os.path.join(ROOT, "ops", "lib", "compatibility-policy.py")
spec = importlib.util.spec_from_file_location("compatibility_policy", HELPER)
policy = importlib.util.module_from_spec(spec)
spec.loader.exec_module(policy)

TARGET = "test/repo:v1.8.223@aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
CANDIDATE = "test/repo:v1.8.224@bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"
ROLLBACK = "test/repo:v1.8.222@cccccccccccccccccccccccccccccccccccccccc"

class CompatibilityPolicyTest(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.base = os.path.join(self.tmp.name, "base.yaml")
        self.overlay = os.path.join(self.tmp.name, "overlay.yaml")
        self.state = os.path.join(self.tmp.name, "applied.json")
        with open(self.base, "w") as f:
            f.write("coordinator:\n  compatibility_set:\n    target_id: %s\n    accepted_ids:\n      - %s\n      - %s\n" % (TARGET, TARGET, ROLLBACK))
        with open(self.overlay, "w") as f:
            f.write("routing:\n  default_objective: balanced\n")
        self.write_state()
        policy.STATE = self.state

    def tearDown(self):
        self.tmp.cleanup()

    def write_state(self):
        def sha(path):
            with open(path, "rb") as f: return hashlib.sha256(f.read()).hexdigest()
        with open(self.state, "w") as f:
            json.dump({"schema": "macprovider.coordinator-applied-config.v1", "config_path": self.base, "config_sha256": sha(self.base), "overlay_path": self.overlay, "overlay_sha256": sha(self.overlay), "source": "boot"}, f)

    def test_exact_legacy_candidate_requires_active_allowlist_membership(self):
        out = io.StringIO()
        with contextlib.redirect_stdout(out):
            policy.report(TARGET)
        self.assertTrue(json.loads(out.getvalue())["candidate_admitted"])
        out = io.StringIO()
        with contextlib.redirect_stdout(out):
            policy.report(CANDIDATE)
        self.assertFalse(json.loads(out.getvalue())["candidate_admitted"])

    def test_disk_drift_is_not_active_policy_evidence(self):
        with open(self.overlay, "a") as f:
            f.write("# drift\n")
        with self.assertRaisesRegex(RuntimeError, "drifted"):
            policy.report(TARGET)

    def test_boot_binding_uses_microsecond_utc_process_start(self):
        record = {"config_path": self.base, "overlay_path": self.overlay,
                  "loaded_at": "2026-10-09T20:00:00.123457Z"}
        argv = ("coordinator\0--config\0%s\0--config-overlay\0%s\0" %
                (self.base, self.overlay)).encode()
        with mock.patch.object(policy, "running_main_pid", return_value=42), \
             mock.patch("builtins.open", mock.mock_open(read_data=argv)), \
             mock.patch.object(policy.subprocess, "check_output",
                               return_value="Fri 2026-10-09 20:00:00.123456 UTC\n") as show:
            self.assertTrue(policy.boot_record_binds_running_process(record))
            self.assertIn("--timestamp=us+utc", show.call_args.args[0])
            record["loaded_at"] = "2026-10-09T20:00:00.123455Z"
            self.assertFalse(policy.boot_record_binds_running_process(record))
            record["loaded_at"] = "2026-10-09T20:00:00.123457Z"
            record["config_path"] = "/different/config.yaml"
            self.assertFalse(policy.boot_record_binds_running_process(record))

    def test_mode_less_legacy_rejects_a_stale_process_binding(self):
        original = policy.boot_record_binds_running_process
        policy.boot_record_binds_running_process = lambda record: False
        try:
            with self.assertRaisesRegex(RuntimeError, "stale or not bound"):
                policy.report(TARGET, require_boot=True)
        finally:
            policy.boot_record_binds_running_process = original

if __name__ == "__main__":
    unittest.main()
