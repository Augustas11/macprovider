"""Offline checks only: never contact Studio/Pearl or build/load a model."""
import importlib.util
import json
import io
import argparse
from pathlib import Path
import subprocess
import tempfile
import unittest
from unittest.mock import patch, Mock

PATH = Path(__file__).resolve().parents[1] / "ops/studio-mtp-measurement.py"
SPEC = importlib.util.spec_from_file_location("studio_mtp", PATH)
M = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(M)


class MeasurementTests(unittest.TestCase):
    def policy(self):
        return dict(schema="macprovider.native-mtp-exploratory-policy.v1",
                    model_id=M.MODEL, provider_commit="a" * 40, hw_model="Mac15,14",
                    slots=[1, 2, 4], prompt_tokens=[512], max_tokens=[128],
                    warmup_runs=0, blocks=2, sustained_seconds=0,
                    temperature=1, top_p=.95, request_shape="tools")

    def test_fixed_policy(self):
        M.policy_ok(json.dumps(self.policy()), "a" * 40, "s4-p512-o128")
        for key, bad in (("blocks", 10), ("slots", [8]), ("temperature", True),
                         ("sustained_seconds", 1800), ("top_p", .9), ("request_shape", "shell")):
            with self.subTest(key=key), self.assertRaises(M.Refusal):
                M.policy_ok(json.dumps(dict(self.policy(), **{key: bad})), "a" * 40, "s4-p512-o128")

    def test_tracked_source_change_refused(self):
        with patch.object(M, "run", side_effect=[b"a" * 40 + b"\n", b" M source.swift\n"]):
            with self.assertRaises(M.Refusal):
                M.source_ok("/source", "a" * 40)

    def test_drift_refuses_restore_before_launch(self):
        with tempfile.TemporaryDirectory() as tmp:
            d = Path(tmp)
            M.put(d / "journal.json", {"restored": False})
            with patch.object(M, "kill_group"), patch.object(M, "live_hashes", return_value={"changed": "x"}), \
                    patch.object(M, "launch") as launch:
                with self.assertRaises(M.Refusal):
                    M.restore({"dir": tmp, "live_hashes": {}})
                launch.assert_not_called()

    def test_unknown_group_is_never_signalled(self):
        with patch.object(M, "alive", return_value=False), patch.object(M, "group_live", return_value=True), \
                patch.object(M.os, "killpg") as kill:
            with self.assertRaises(M.Refusal):
                M.kill_group({"group": [123, "original birth"]})
            kill.assert_not_called()

    def test_dead_leader_descendants_keep_bound_session(self):
        rows = f"456 123 {M.os.getuid()} S\n".encode()
        with patch.object(M, "alive", return_value=False), \
                patch.object(M, "group_live", side_effect=[True, False]), \
                patch.object(M, "birth", return_value=""), patch.object(M, "run", return_value=rows), \
                patch.object(M.os, "getsid", return_value=123), patch.object(M.os, "killpg") as kill:
            M.kill_group({"group": [123, "original birth"], "session_bound": True})
            kill.assert_called_once_with(123, M.signal.SIGKILL)

    def test_watchdog_restores_on_worker_loss(self):
        with tempfile.TemporaryDirectory() as tmp:
            M.put(Path(tmp) / "journal.json", {"restored": False})
            with patch.object(M, "lease_alive", return_value=True), patch.object(M, "alive", return_value=False), patch.object(M, "restore") as restore:
                manifest = {"dir": tmp, "deadline": M.time.time() + 900, "worker": [123, "birth"]}
                M.watchdog(manifest)
                restore.assert_called_once_with(manifest)

    def test_watchdog_kills_exact_worker_at_deadline(self):
        with tempfile.TemporaryDirectory() as tmp:
            M.put(Path(tmp) / "journal.json", {"restored": False})
            with patch.object(M, "lease_alive", return_value=True), patch.object(M, "alive", return_value=True), patch.object(M.os, "kill") as kill, \
                    patch.object(M, "restore") as restore:
                manifest = {"dir": tmp, "deadline": 0, "worker": [123, "birth"]}
                M.watchdog(manifest)
                kill.assert_called_once_with(123, M.signal.SIGKILL)
                restore.assert_called_once()

    def test_pearl_timer_precedes_stop_and_restart_checks_active(self):
        captures = []
        def fake_ssh(host, code, payload):
            commands = []
            def fake_run(argv, **kwargs):
                commands.append(argv)
                return Mock(stdout=b"active\n")
            with patch.object(subprocess, "run", side_effect=fake_run), \
                    patch("sys.stdin", __import__("io").StringIO(json.dumps(payload))), patch("builtins.print"):
                exec(code, {})
            captures.append(commands)
        with patch.object(M, "ssh", side_effect=fake_ssh):
            M.pearl("pearl", "fixed-unit", True)
            M.pearl("pearl", "fixed-unit")
        armed, restored = captures
        self.assertEqual(armed[1][0], "systemd-run")
        self.assertEqual(armed[2], ["systemctl", "is-active", "fixed-unit.timer"])
        self.assertEqual(armed[3], ["systemctl", "stop", M.RUNNER])
        self.assertEqual(restored, [["systemctl", "start", M.RUNNER], ["systemctl", "is-active", M.RUNNER]])

    def test_lease_eof_revokes_and_stale_lease_kills_worker(self):
        with tempfile.TemporaryDirectory() as tmp:
            path = Path(tmp) / "controller-lease.json"
            M.put(path, {"connected": True, "updated": M.time.time()})
            M.lease_reader(tmp, io.StringIO(""))
            self.assertFalse(M.lease_alive({"dir": tmp}))
            M.put(path, {"connected": True, "updated": M.time.time() - 11})
            M.put(Path(tmp) / "journal.json", {"restored": False})
            manifest = {"dir": tmp, "deadline": M.time.time() + 900, "worker": [123, "birth"]}
            with patch.object(M, "alive", return_value=True), patch.object(M.os, "kill") as kill, \
                    patch.object(M, "restore") as restore:
                M.watchdog(manifest)
            kill.assert_called_once_with(123, M.signal.SIGKILL)
            restore.assert_called_once_with(manifest)

    def test_yaml_socket_and_explicit_default_socket(self):
        probe = (PATH.parent / "lib/studio-owner-pin-probe.py").read_bytes()
        self.assertEqual(M.config_socket("secret: private\nctl_socket_path: /tmp/exact.sock\n", None, probe), "/tmp/exact.sock")
        self.assertEqual(M.config_socket("secret: private\n", "/tmp/default.sock", probe), "/tmp/default.sock")
        for text in ("ctl_socket_path: /tmp/a\nctl_socket_path: /tmp/b\n", "ctl_socket_path: '/tmp/a'\n",
                     "ctl_socket_path: /tmp/a # comment\n", "ctl_socket_path: /tmp/a\n"):
            with self.subTest(text=text), self.assertRaises((M.Refusal, RuntimeError)):
                M.config_socket(text, "/tmp/other", probe)
        with patch.object(M, "run", return_value=b"p123\nn/tmp/other\n"), self.assertRaises(M.Refusal):
            M.socket_owner("/tmp/exact", 123)

    def test_group_esrch_confirmed_gone_is_success(self):
        with patch.object(M, "alive", return_value=True), patch.object(M.os, "killpg", side_effect=ProcessLookupError), \
                patch.object(M, "group_live", return_value=False):
            M.kill_group({"group": [123, "birth"]})

    def test_disappearing_session_member_rescans(self):
        rows = f"456 123 {M.os.getuid()} S\n".encode()
        with patch.object(M, "alive", return_value=False), patch.object(M, "birth", return_value=""), \
                patch.object(M, "group_live", side_effect=[True, False]), \
                patch.object(M, "run", side_effect=[rows, b""]), \
                patch.object(M.os, "getsid", side_effect=ProcessLookupError), patch.object(M.os, "killpg") as kill:
            M.kill_group({"group": [123, "birth"], "session_bound": True})
        kill.assert_not_called()

    def test_timer_recovery_persists_verified_active_receipt(self):
        with tempfile.TemporaryDirectory() as tmp:
            original = Path
            with patch("pathlib.Path", side_effect=lambda p: original(tmp)), \
                    patch.object(subprocess, "run", return_value=Mock(returncode=0, stdout=b"active\n")), \
                    patch("sys.argv", ["recovery", "fixed-unit"]):
                with self.assertRaises(SystemExit) as exit_status:
                    exec(M.TIMER_RECOVERY_CODE, {})
            self.assertEqual(exit_status.exception.code, 0)
            self.assertEqual(json.loads((Path(tmp) / "fixed-unit.json").read_text())["runner_active"], True)

    def test_timer_retirement_requires_active_runner_then_unloaded_timer(self):
        commands = []
        def fake_ssh(host, code, payload):
            def fake_run(argv, **kwargs):
                commands.append(argv)
                return Mock(stdout=b"not-found\n" if "show" in argv else b"active\n")
            with patch.object(subprocess, "run", side_effect=fake_run), \
                    patch("sys.stdin", io.StringIO(json.dumps(payload))), patch("builtins.print"):
                exec(code, {})
        with patch.object(M, "ssh", side_effect=fake_ssh):
            M.pearl("pearl", "fixed-unit", retire=True)
        self.assertEqual(commands[0], ["systemctl", "is-active", M.RUNNER])
        self.assertEqual(commands[1], ["systemctl", "stop", "fixed-unit.timer", "fixed-unit.service"])
        self.assertIn("show", commands[-1])

    def test_failed_cell_exits_after_restore_and_timer_retirement(self):
        self.controller_case(retire_fail=False)

    def test_failed_timer_retirement_retains_lock_and_journal(self):
        self.controller_case(retire_fail=True)

    def controller_case(self, retire_fail):
        with tempfile.TemporaryDirectory() as tmp:
            policy = Path(tmp) / "policy.json"
            policy.write_text(json.dumps(self.policy()))
            env = {"STUDIO_MTP_SOURCE_DIR": "/source", "STUDIO_MTP_CONFIG": "/config", "STUDIO_STATUS_PORT": "8080",
                   "STUDIO_SSH": "studio", "PEARL_SSH": "pearl", "MACPROVIDER_OPS_OWNER": "test",
                   "MACPROVIDER_OPS_STATE_DIR": tmp}
            remote = {"dir": "/remote/run", "nonce": "123", "commit": "a" * 40, "policy_sha256": "b" * 64}
            def dispatch(host, code, payload, callback):
                callback()
                return {"restored": True, "lab_passed": False}
            def pearl(host, unit, arm=False, retire=False):
                if retire and retire_fail:
                    raise M.Refusal("timer retirement failed")
                return {"runner_active": True, "timer_retired": retire}
            with patch.dict(M.os.environ, env), patch.object(M, "source_ok"), patch.object(M, "published"), \
                    patch.object(M, "run", return_value=b"a" * 40) as run, patch.object(M, "ssh", return_value=remote), \
                    patch.object(M, "dispatch_worker", side_effect=dispatch), patch.object(M, "pearl", side_effect=pearl), \
                    patch("builtins.print"), self.assertRaises(M.Refusal):
                M.controller(argparse.Namespace(source_commit="a" * 40, policy=policy, cell="s2-p512-o128", run=True))
            released = any("release" in c.args[0] for c in run.call_args_list)
            self.assertEqual(released, not retire_fail)
            self.assertEqual((Path(tmp) / "studio-mtp-measurement.json").exists(), retire_fail)

    def test_control_skips_unrelated_frames(self):
        conn = Mock()
        conn.recv.side_effect = [b'{"type":"status_response"}\n', b'{"type":"pause_ack","accepted":true}\n']
        manager = Mock()
        manager.__enter__ = Mock(return_value=conn)
        manager.__exit__ = Mock(return_value=False)
        with patch.object(M.socket, "socket", return_value=manager):
            M.control({"socket": "/exact/socket"}, "pause_request")
        conn.connect.assert_called_once_with("/exact/socket")

    def test_fixed_build_then_one_cell_and_restore_on_build_failure(self):
        for failure in (False, True):
            with self.subTest(failure=failure), tempfile.TemporaryDirectory() as tmp:
                d = Path(tmp)
                M.put(d / "watchdog-ready.json", {})
                events = []
                manifest = {"dir": tmp, "source": "/source", "commit": "a" * 40,
                            "baseline": {"launch": {"pid": 321}}, "cell": "s2-p512-o128",
                            "policy_sha256": "b" * 64, "socket": "/exact/socket"}
                def grouped(m, kind, timeout):
                    events.append(("command", M.fixed_command(m, kind), timeout))
                    if failure:
                        raise M.Refusal("build failed")
                with patch.object(M, "socket_owner"), patch.object(M, "birth", return_value="born"), patch.object(M.subprocess, "Popen"), \
                        patch.object(M, "check_live"), patch.object(M, "source_ok"), \
                        patch.object(M, "probe", return_value=manifest["baseline"]), patch.object(M, "serving", return_value=True), \
                        patch.object(M, "control", side_effect=lambda m, k: events.append((k,))), \
                        patch.object(M, "status", return_value={"requests_in_flight": 0, "lifecycle": {"operator_paused": True}}), \
                        patch.object(M, "launch", side_effect=lambda label: events.append(("stop", label))), \
                        patch.object(M, "alive", return_value=False), patch.object(M, "grouped", side_effect=grouped), \
                        patch.object(M, "restore", side_effect=lambda m: events.append(("restore",))), \
                        patch("builtins.print", side_effect=lambda *a, **k: events.append(("window_ended",))):
                    result = M.worker(manifest)
                self.assertEqual(events[0], ("pause_request",))
                self.assertEqual(events[1:3], [("stop", M.LABEL + "-watchdog"), ("stop", M.LABEL)])
                build = events[3][1]
                self.assertIn("--disable-automatic-resolution", build)
                self.assertEqual(build[build.index("-j") + 1], "2")
                self.assertEqual(events[-2:], [("window_ended",), ("restore",)])
                self.assertEqual(result["lab_passed"], not failure)
                if not failure:
                    bench = events[4][1]
                    self.assertEqual(bench[1], "native-mtp-bench")
                    self.assertEqual(bench[bench.index("--only-cell") + 1], manifest["cell"])


if __name__ == "__main__":
    unittest.main()
