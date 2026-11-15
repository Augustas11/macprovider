import importlib.util
import json
from pathlib import Path
import subprocess
import unittest
from unittest.mock import patch, Mock

SPEC = importlib.util.spec_from_file_location("runner_target", Path(__file__).resolve().parents[1] / "ops/lib/buyer-runner-target.py")
runner = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(runner)


class RunnerTargetTests(unittest.TestCase):
    def test_committed_status_requires_exact_target_and_current_bytes(self):
        raw = b'{"targets":[{"provider_id":"mp-air","model":"qwen3-8b","slots":4}]}'
        state = {"phase": "committed", "after_sha256": runner.digest(raw)}
        self.assertTrue(runner.enrollment_matches(raw, state, "mp-air", "qwen3-8b", 4))
        self.assertFalse(runner.enrollment_matches(raw + b" ", state, "mp-air", "qwen3-8b", 4))
        self.assertFalse(runner.enrollment_matches(raw, state, "mp-other", "qwen3-8b", 4))
        self.assertFalse(runner.enrollment_matches(raw, state, "mp-air", "qwen3-8b", 2))
        self.assertFalse(runner.enrollment_matches(raw, {**state, "phase": "prepared"}, "mp-air", "qwen3-8b", 4))

    def test_append_preserves_other_inventory_and_settings(self):
        baseline = {"targets": [{"provider_id": "other", "model": "other-model", "slots": 2}], "exclude": ["excluded"], "private_setting": 7}
        result = json.loads(runner.candidate(json.dumps(baseline), "mp-air", "qwen3-8b", 4))
        self.assertEqual(result["targets"][:-1], baseline["targets"])
        self.assertEqual(result["exclude"], baseline["exclude"])
        self.assertEqual(result["private_setting"], 7)
        self.assertEqual(result["targets"][-1], {"provider_id": "mp-air", "model": "qwen3-8b", "slots": 4})

    def test_existing_exact_target_is_idempotent(self):
        raw = '{"targets":[{"provider_id":"mp-air","model":"qwen3-8b","slots":4,"label":"keep"}]}'
        once = runner.candidate(raw, "mp-air", "qwen3-8b", 4)
        self.assertEqual(runner.candidate(once, "mp-air", "qwen3-8b", 4), once)
        self.assertEqual(json.loads(once)["targets"][0]["label"], "keep")

    def test_never_overrides_exclusion_or_existing_model_or_slots(self):
        for raw in (
            '{"targets":[],"exclude":["mp-air"]}',
            '{"targets":[{"provider_id":"mp-air","model":"other","slots":4}]}',
            '{"targets":[{"provider_id":"mp-air","model":"qwen3-8b","slots":2}]}',
            '{"targets":[{"provider_id":"mp-air"},{"provider_id":"mp-air"}]}',
        ):
            with self.subTest(raw=raw), self.assertRaises(ValueError):
                runner.candidate(raw, "mp-air", "qwen3-8b", 4)

    def test_recovery_refuses_concurrent_edit(self):
        path = Mock()
        path.read_bytes.return_value = b"unrelated edit"
        state = {"before_sha256": runner.digest(b"old"), "after_sha256": runner.digest(b"new")}
        with patch.object(runner, "secure_path", return_value=path), patch.object(runner, "atomic") as write:
            with self.assertRaises(ValueError):
                runner.recover(path, Mock(), state)
            write.assert_not_called()

    def test_failed_enrollment_recovery_restores_and_restarts(self):
        path, journal = Mock(), Mock()
        path.read_bytes.return_value = b"new"
        state = {"phase": "prepared", "before": "old", "before_sha256": runner.digest(b"old"), "after_sha256": runner.digest(b"new"), "mode": 0o644}
        with patch.object(runner, "secure_path", return_value=path), patch.object(runner, "validate"), patch.object(runner, "atomic") as write, patch.object(runner, "main_pid", return_value="123"), patch.object(runner, "service", return_value=True) as service, patch.object(runner, "stable", return_value=True) as stable, patch.object(runner, "save") as save:
            runner.recover(path, journal, state)
            write.assert_called_once_with(path, b"old", 0o644)
            service.assert_called_once_with("restart")
            stable.assert_called_once_with("123")
            self.assertEqual(state["phase"], "restored")
            save.assert_called_once()

    def test_failed_recovery_attempts_start_and_keeps_journal(self):
        path = Mock()
        path.read_bytes.return_value = b"new"
        state = {"phase": "prepared", "before": "old", "before_sha256": runner.digest(b"old"), "after_sha256": runner.digest(b"new"), "mode": 0o644}
        with patch.object(runner, "secure_path", return_value=path), patch.object(runner, "validate"), patch.object(runner, "atomic"), patch.object(runner, "main_pid", return_value="123"), patch.object(runner, "service", return_value=False) as service, patch.object(runner, "stable", return_value=False), patch.object(runner, "save") as save:
            with self.assertRaises(RuntimeError):
                runner.recover(path, Mock(), state)
            self.assertEqual([c.args[0] for c in service.call_args_list], ["restart", "start"])
            save.assert_not_called()
            self.assertEqual(state["phase"], "prepared")

    def _reservation(self, tmp, before, current):
        path, backup, state_path = Path(tmp, "targets.json"), Path(tmp, "backup"), Path(tmp, "state.json")
        path.write_bytes(current)
        backup.write_bytes(before)
        state = {"phase": "paused", "backup": str(backup), "provider_prefix": "mp-studio", "mode": 0o644,
                 "before_sha256": runner.digest(before), "after_sha256": runner.digest(b"paused")}
        state_path.write_text(json.dumps(state))
        return path, state_path, state

    def _no_system(self):
        return [patch.object(runner, "secure_path", side_effect=lambda p, **_: Path(p)),
                patch.object(runner, "main_pid", return_value="1"),
                patch.object(runner, "restart_runner", return_value=True),
                patch.object(runner, "validate_if_installed")]

    def test_row_restore_refuses_two_reserved_rows_in_backup(self):
        import tempfile
        before = b'{"targets":[{"provider_id":"mp-studio-a"},{"provider_id":"mp-studio-b"},{"provider_id":"x"}]}'
        with tempfile.TemporaryDirectory() as tmp:
            path, state_path, state = self._reservation(tmp, before, b'{"targets":[]}')
            patches = self._no_system()
            for p in patches:
                p.start()
            try:
                with self.assertRaises(runner.Refusal):
                    runner.restore_reservation(0, path, state_path, state)
            finally:
                for p in patches:
                    p.stop()
            self.assertEqual(path.read_bytes(), b'{"targets":[]}')
            self.assertTrue(state_path.exists())

    def test_crash_after_row_write_converges_on_next_restore(self):
        import tempfile
        before = b'{"targets":[{"provider_id":"a"},{"provider_id":"mp-studio-1","slots":8},{"provider_id":"b"}],"k":1}'
        with tempfile.TemporaryDirectory() as tmp:
            path, state_path, state = self._reservation(tmp, before, b'{"targets":[{"provider_id":"b"}],"k":1}')
            patches = self._no_system()
            for p in patches:
                p.start()
            try:
                with patch.object(runner, "drop_state", side_effect=InterruptedError):
                    with self.assertRaises(InterruptedError):
                        runner.restore_reservation(0, path, state_path, state)
                written = path.read_bytes()
                state = json.loads(state_path.read_text())
                self.assertEqual(state["phase"], "restoring")
                with patch.object(runner, "restart_runner", return_value=True) as restart:
                    self.assertEqual(runner.restore_reservation(0, path, state_path, state), "row")
                    restart.assert_called_once()
            finally:
                for p in patches:
                    p.stop()
            self.assertEqual(path.read_bytes(), written)
            self.assertEqual(json.loads(written), {"targets": [{"provider_id": "mp-studio-1", "slots": 8}, {"provider_id": "b"}], "k": 1})
            self.assertFalse(state_path.exists())

    def test_systemctl_timeout_does_not_skip_recovery(self):
        with patch.object(runner.subprocess, "run", side_effect=subprocess.TimeoutExpired("systemctl", 45)):
            self.assertFalse(runner.service("restart"))

    def test_old_process_cannot_prove_restarted_membership(self):
        with patch.object(runner.subprocess, "check_output", return_value=b"MainPID=123\nActiveState=active\n"), patch.object(runner.time, "monotonic", side_effect=[0, 0, 31]), patch.object(runner.time, "sleep"):
            self.assertFalse(runner.stable("123"))


if __name__ == "__main__":
    unittest.main()
