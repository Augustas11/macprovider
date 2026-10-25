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
    def test_metal_step_uses_xcode_developer_dir(self):
        grouped = __import__("inspect").getsource(M.grouped)
        self.assertIn("env=lab_env(kind)", grouped)
        self.assertEqual(M.lab_env("metal")["DEVELOPER_DIR"], str(M.XCODE_DEVELOPER_DIR))
        self.assertNotIn("DEVELOPER_DIR", M.lab_env("build"))
        self.assertTrue(str(M.XCODE_DEVELOPER_DIR).endswith("Applications/Xcode.app/Contents/Developer"))

    def test_fork_cohort_tests_use_fixed_xcode_command_inside_window(self):
        command = M.fixed_command({"source": "/campaign", "dir": "/window"}, "fork-tests")
        self.assertEqual(command[:3], ["/usr/bin/xcrun", "xcodebuild", "test"])
        self.assertIn("-only-testing:MLXLMTests/GLM5NextTests/testPackedVerifyDepthOneCohortsMatchSerialRows", command)
        self.assertIn("-only-testing:MLXLMTests/GLM5NextTests/testPackedVerifyRank512FallbackMatchesSerialRows", command)
        self.assertIn("-only-testing:MLXLMTests/GLM5NextTests/testMTPDrafterRollbackAndPackedAdvanceMatchSerialCommit", command)
        self.assertIn("-only-testing:MLXLMTests/GLM5NextTests/testPackedVerifyDepthThreeMatchesSerialRows", command)
        self.assertEqual(command[command.index("-jobs") + 1], "2")
        self.assertEqual(command[command.index("-derivedDataPath") + 1],
                         "/campaign/.lab-window/glm-cohort-tests/DerivedData")
        self.assertEqual(command[command.index("-clonedSourcePackagesDirPath") + 1],
                         "/campaign/.lab-window/glm-cohort-tests/SourcePackages")
        self.assertEqual(command[command.index("-resultBundlePath") + 1],
                         "/window/glm-cohort-parity.xcresult")
        self.assertEqual(M.lab_env("fork-tests")["DEVELOPER_DIR"], str(M.XCODE_DEVELOPER_DIR))
        self.assertEqual(M.FORK_TESTS, 600)

    def test_missing_metal_compiler_refused_before_downtime(self):
        failed = Mock(returncode=1)
        with patch.object(M, "run", return_value=b"Mac15,14\n"), patch.object(M, "source_ok"), \
                patch("subprocess.run", return_value=failed) as xcrun:
            with self.assertRaises(M.Refusal):
                M.inspect_remote({"source": "/campaign", "commit": "a" * 40})
        self.assertEqual(xcrun.call_args.kwargs["env"]["DEVELOPER_DIR"], str(M.XCODE_DEVELOPER_DIR))

    def test_release_metal_library_uses_existing_build_entry_point(self):
        command = M.fixed_command({"source": "/campaign", "dir": "/window"}, "metal")
        self.assertEqual(command, ["/bin/bash", "/campaign/phase3-binary/scripts/build-mlx-metallib.sh",
                                   "/campaign/phase3-binary/.build/arm64-apple-macosx/release"])
        worker = __import__("inspect").getsource(M.worker)
        self.assertLess(worker.index('grouped(m, "metal", BUILD)'), worker.index('grouped(m, "metalcheck", 120)'))
        self.assertLess(worker.index('grouped(m, "metalcheck", 120)'), worker.index('grouped(m, "cell", CELL)'))

    def policy(self):
        return dict(schema="macprovider.native-mtp-exploratory-policy.v1",
                    model_id=M.MODEL, provider_commit="a" * 40, hw_model="Mac15,14",
                    slots=[1, 2, 4], prompt_tokens=[512], max_tokens=[128],
                    warmup_runs=0, blocks=2, sustained_seconds=0,
                    temperature=1, top_p=.95, request_shape="tools_history_reasoning")

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
                    patch.object(M, "build_validator"), patch.object(M, "upload_validator", return_value="c" * 64), \
                    patch.object(M, "dispatch_worker", side_effect=dispatch), patch.object(M, "pearl", side_effect=pearl), \
                    patch("builtins.print"), self.assertRaises(M.Refusal):
                M.controller(argparse.Namespace(source_commit="a" * 40, policy=policy, cell="s2-p512-o128", run=True))
            released = any("release" in c.args[0] for c in run.call_args_list)
            self.assertEqual(released, not retire_fail)
            self.assertEqual((Path(tmp) / "studio-mtp-measurement.json").exists(), retire_fail)

    def test_matrix_has_twelve_bounded_cells_and_four_profiles(self):
        with tempfile.TemporaryDirectory() as tmp:
            d = Path(tmp)
            m = {"dir": tmp, "source": "/source", "commit": "a" * 40, "cell": "matrix"}
            M.put(d / "manifest.json", m)
            M.put(d / "policy.json", self.policy())
            with patch("sys.argv", ["entry", "_matrix", str(d / "manifest.json")]), \
                    patch.object(M.subprocess, "run", return_value=Mock(returncode=0)) as run, \
                    patch.object(M.time, "sleep"), patch("builtins.print"):
                M.main()
            self.assertEqual(len(run.call_args_list), 1)
            self.assertEqual(run.call_args.kwargs["timeout"], M.CELL - 10)
            self.assertIn("--policy-list", run.call_args.args[0])
            self.assertNotIn("--only-cell", run.call_args.args[0])
            profiles = [json.loads(p.read_text()) for p in d.glob("*-policy.json")]
            self.assertEqual({(p["request_shape"], p["temperature"], p["top_p"]) for p in profiles},
                             {(s, t, 1 if t == 0 else .95) for s in ("plain_text", "tools_history_reasoning") for t in (0, 1)})

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
        for failure in (None, "build", "fork-tests"):
            with self.subTest(failure=failure), tempfile.TemporaryDirectory() as tmp:
                d = Path(tmp)
                M.put(d / "watchdog-ready.json", {})
                events = []
                manifest = {"dir": tmp, "source": "/source", "commit": "a" * 40,
                            "baseline": {"launch": {"pid": 321}}, "cell": "s2-p512-o128",
                            "policy_sha256": "b" * 64, "socket": "/exact/socket"}
                def grouped(m, kind, timeout):
                    events.append(("command", M.fixed_command(m, kind), timeout))
                    if kind == failure:
                        raise M.Refusal("fixed command failed")
                with patch.object(M, "socket_owner"), patch.object(M, "birth", return_value=""), patch.object(M.subprocess, "Popen"), \
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
                    self.assertIn("build-mlx-metallib.sh", events[4][1][1])
                    self.assertEqual(events[5][1][2], "_metalcheck")
                    self.assertEqual(events[6][1][:3], ["/usr/bin/xcrun", "xcodebuild", "test"])
                    self.assertEqual(events[6][2], 600)
                    bench = events[7][1]
                    self.assertEqual(bench[1], "native-mtp-bench")
                    self.assertEqual(bench[bench.index("--only-cell") + 1], manifest["cell"])
                elif failure == "fork-tests":
                    self.assertFalse(any(event[0] == "command" and "native-mtp-bench" in event[1]
                                         for event in events))

    BENCH_FIELDS = ("hw_model", "chip", "ram_gb", "os_build", "xcode_build_version", "swift_version",
                    "provider_commit", "mlx_fork_revision", "model_id", "target_sha256", "mtp_sha256",
                    "tokenizer_sha256")

    def preflight_case(self, tmp, validate, cell="matrix", validator=b"validator-bytes", uploaded=None):
        """Runs preflight_remote with the validate child faked."""
        policy = json.dumps(self.policy()).encode()
        digest = M.sha(validator)
        root = Path(tmp) / ".config/macprovider/studio-mtp-measurement"
        root.mkdir(parents=True)
        (root / ("validator-" + digest[:16])).write_bytes(validator if uploaded is None else uploaded)
        m = {"source": "/source", "commit": "a" * 40, "cell": cell, "nonce": "n1",
             "policy_sha256": M.sha(policy), "policy_code": M.base64.b64encode(policy).decode(),
             "validator_sha256": digest}
        calls = []
        def fake(argv, **kwargs):
            calls.append((argv, kwargs))
            return validate
        with patch.object(M.Path, "home", return_value=Path(tmp)), patch.object(M, "source_ok"), \
                patch.object(M, "pins_ok"), patch.object(M.subprocess, "run", side_effect=fake):
            try:
                return M.preflight_remote(m), calls
            except M.Refusal as exc:
                return exc, calls

    def test_preflight_refuses_and_names_every_bench_field(self):
        for field in self.BENCH_FIELDS:
            with self.subTest(field=field), tempfile.TemporaryDirectory() as tmp:
                stderr = f"native-mtp-e2e: x\nError: invalid policy: {field} mismatch: frozen=1 observed=2\n"
                result, calls = self.preflight_case(tmp, Mock(returncode=1, stdout="", stderr=stderr))
                self.assertIsInstance(result, M.Refusal)
                self.assertIn(f"{field} mismatch: frozen=1 observed=2", str(result))

    def test_preflight_refuses_a_request_the_production_parser_rejects(self):
        with tempfile.TemporaryDirectory() as tmp:
            stderr = 'Error: APIError(status: 400, message: "Invalid tool_call id", code: "invalid_tool_call_id")\n'
            result, _ = self.preflight_case(tmp, Mock(returncode=1, stdout="", stderr=stderr), cell="matrix-tools")
            self.assertIn("invalid_tool_call_id", str(result))

    def test_preflight_runs_only_the_validator_on_the_window_policies(self):
        for cell in M.MATRICES:
            with self.subTest(cell=cell), tempfile.TemporaryDirectory() as tmp:
                ok = "\n".join(json.dumps({"validate_only": "pass"}) for _ in M.MATRICES[cell])
                result, calls = self.preflight_case(tmp, Mock(returncode=0, stdout=ok, stderr=""), cell=cell)
                self.assertEqual(result["preflight"], "pass")
                # One child only: no build, metallib or other Studio work outside the window.
                self.assertEqual(len(calls), 1)
                validate, kwargs = calls[0]
                self.assertEqual(validate[:2], ["/usr/sbin/taskpolicy", "-b"])
                self.assertTrue(Path(validate[2]).name.startswith("validator-"))
                self.assertEqual(kwargs["env"]["MACPROVIDER_NATIVE_MTP_E2E"], "1")
                self.assertNotIn("DEVELOPER_DIR", kwargs["env"])
                self.assertIn("--identity-cache", validate)
                # The exact argv and policy bytes the window's matrix step runs.
                pre = Path(tmp) / ".config/macprovider/studio-mtp-measurement/preflight-n1"
                window = Path(tmp) / "window"
                window.mkdir()
                (window / "policy.json").write_bytes((pre / "policy.json").read_bytes())
                m = {"source": "/source", "commit": "a" * 40, "cell": cell}
                expected = [a.replace(str(window), str(pre)) for a in M.bench_command(m, window)]
                self.assertEqual(validate[3:-3], expected[1:])
                names = sorted(p.name for p in pre.glob("*-policy.json"))
                self.assertEqual(len(names), len(M.MATRICES[cell]))
                for name in names:
                    self.assertEqual((pre / name).read_bytes(), (window / name).read_bytes())

    def test_tools_matrix_is_the_six_tools_cells(self):
        self.assertEqual(M.MATRICES["matrix-tools"], (("tools_history_reasoning", 0), ("tools_history_reasoning", 1)))
        M.policy_ok(json.dumps(self.policy()), "a" * 40, "matrix-tools")

    def test_two_row_matrix_keeps_all_profiles_and_selects_only_two_rows(self):
        with tempfile.TemporaryDirectory() as tmp:
            d = Path(tmp)
            policy = dict(self.policy(), proposal_depth=2, max_native_active_rows=2)
            M.put(d / "policy.json", policy)
            M.policy_ok(json.dumps(policy), "a" * 40, "matrix-s2")
            command = M.bench_command({"source": "/source", "commit": "a" * 40,
                                       "cell": "matrix-s2"}, d)
            self.assertEqual(command[-2:], ["--only-cell", "s2-p512-o128"])
            paths = command[command.index("--policy-list") + 1:command.index("--out")]
            self.assertEqual(len(paths), 4)
            profiles = [json.loads(Path(p).read_text()) for p in paths]
            self.assertEqual({(p["request_shape"], p["temperature"]) for p in profiles},
                             set(M.MATRICES["matrix"]))
            self.assertTrue(all(p["proposal_depth"] == 2 and p["max_native_active_rows"] == 2
                                for p in profiles))

    def test_preflight_counts_one_summary_per_policy(self):
        with tempfile.TemporaryDirectory() as tmp:
            one = json.dumps({"validate_only": "pass"})
            result, _ = self.preflight_case(tmp, Mock(returncode=0, stdout=one, stderr=""))
            self.assertIsInstance(result, M.Refusal)

    def test_preflight_refuses_validator_bytes_that_differ_from_the_upload(self):
        with tempfile.TemporaryDirectory() as tmp:
            result, calls = self.preflight_case(tmp, Mock(returncode=0, stdout="", stderr=""), uploaded=b"other")
            self.assertIsInstance(result, M.Refusal)
            self.assertEqual(calls, [])

    def test_validator_is_built_locally_with_command_line_tools(self):
        with patch.object(M, "source_ok"), patch.object(M, "run", return_value=b"") as run:
            path = M.build_validator("a" * 40)
        argv, kwargs = run.call_args.args[0], run.call_args.kwargs
        self.assertEqual(kwargs["env"]["DEVELOPER_DIR"], M.CLT_DEVELOPER_DIR)
        self.assertIn("-DMACPROVIDER_LAB_HARNESS", argv)
        self.assertIn(str(M.ROOT / "phase3-binary"), argv)
        self.assertEqual(path, M.VALIDATOR_SCRATCH / "release/macprovider-cli")

    def test_package_resolved_pin_mismatch_names_dependency(self):
        with tempfile.TemporaryDirectory() as tmp:
            package = Path(tmp)
            (package / "Package.resolved").write_text(json.dumps({"pins": [
                {"identity": "mlx-swift-lm", "location": "https://github.com/x/mlx-swift-lm.git",
                 "state": {"revision": "c" * 40}}]}))
            with patch.object(M, "run", return_value=b"d" * 40 + b"\n") as run, self.assertRaises(M.Refusal) as caught:
                M.pins_ok(package)
            self.assertIn(f"mlx-swift-lm pinned={'c' * 40} checkout={'d' * 40}", str(caught.exception))
            self.assertIn(str(package / ".build/checkouts/mlx-swift-lm"), run.call_args.args[0])

    def test_preflight_refusal_stops_before_lock_and_runner(self):
        with tempfile.TemporaryDirectory() as tmp:
            policy = Path(tmp) / "policy.json"
            policy.write_text(json.dumps(self.policy()))
            env = {"STUDIO_MTP_SOURCE_DIR": "/source", "STUDIO_MTP_CONFIG": "/config", "STUDIO_STATUS_PORT": "8080",
                   "STUDIO_SSH": "studio", "PEARL_SSH": "pearl", "MACPROVIDER_OPS_OWNER": "test",
                   "MACPROVIDER_OPS_STATE_DIR": tmp}
            remote = {"dir": "/remote/run", "nonce": "123", "commit": "a" * 40, "policy_sha256": "b" * 64}
            refusal = M.Refusal("remote: bench policy validation refused: swift_version mismatch")
            with patch.dict(M.os.environ, env), patch.object(M, "source_ok"), patch.object(M, "published"), \
                    patch.object(M, "run") as run, patch.object(M, "ssh", side_effect=[remote, refusal]), \
                    patch.object(M, "build_validator"), patch.object(M, "upload_validator", return_value="c" * 64), \
                    patch.object(M, "pearl") as pearl, patch("builtins.print"), self.assertRaises(M.Refusal) as caught:
                M.controller(argparse.Namespace(source_commit="a" * 40, policy=policy, cell="matrix", run=True))
            self.assertIn("swift_version mismatch", str(caught.exception))
            run.assert_not_called()
            pearl.assert_not_called()

    def test_ssh_surfaces_the_remote_refusal_line(self):
        error = subprocess.CalledProcessError(1, ["ssh"], stderr=(
            b"noise\nstudio-mtp-measurement: blocked: bench policy validation refused: Error: invalid policy: "
            b"os_build mismatch: frozen=26A434 observed=26A500; journals/lock retained if armed\n"))
        with patch.object(M, "run", side_effect=error), self.assertRaises(M.Refusal) as caught:
            M.ssh("studio", "pass", {})
        self.assertEqual(str(caught.exception), "remote: bench policy validation refused: Error: invalid policy: "
                         "os_build mismatch: frozen=26A434 observed=26A500")

    def test_window_hard_ceiling_is_sixty_minutes(self):
        self.assertEqual(M.TOTAL, 3600)
        captured = []
        with patch.object(M, "ssh", side_effect=lambda h, c, p: captured.append(p) or {}):
            M.pearl("pearl", "unit", True)
        self.assertEqual(captured[0]["seconds"], M.TOTAL)


class AcceptanceMeasurementTests(unittest.TestCase):
    def test_acceptance_main_tests_are_targeted_and_inside_paused_window(self):
        manifest = {"source": "/campaign", "dir": "/window", "cell": "acceptance"}
        command = M.fixed_command(manifest, "acceptance-tests")
        self.assertEqual(command[:2], ["/Library/Developer/CommandLineTools/usr/bin/swift", "test"])
        self.assertEqual(command[command.index("--package-path") + 1], "/campaign/phase3-binary")
        self.assertEqual(command[command.index("--filter") + 1],
                         "NativeMTPAcceptance.*Tests|NativeMTPLabNumericalOracleTests|NativeMTPBackendSafetyTests")
        self.assertEqual(command[command.index("-c") + 1], "debug")
        self.assertEqual(M.lab_env("acceptance-tests")["DEVELOPER_DIR"], M.CLT_DEVELOPER_DIR)
        self.assertEqual(M.ACCEPTANCE_TESTS, 600)
        self.assertEqual(M.TOTAL, 3600)
        worker = __import__("inspect").getsource(M.worker)
        self.assertLess(worker.index('grouped(m, "fork-tests", FORK_TESTS)'),
                        worker.index('grouped(m, "acceptance-tests", ACCEPTANCE_TESTS)'))
        self.assertLess(worker.index('grouped(m, "acceptance-tests", ACCEPTANCE_TESTS)'),
                        worker.index('grouped(m, "cell", CELL)'))
        with self.assertRaises(M.Refusal):
            M.fixed_command(dict(manifest, cell="matrix"), "acceptance-tests")

    def test_acceptance_restores_normal_build_flags_with_shared_build_budget(self):
        with tempfile.TemporaryDirectory() as tmp:
            d = Path(tmp)
            M.put(d / "watchdog-ready.json", {})
            manifest = {"dir": tmp, "source": "/campaign", "commit": "a" * 40,
                        "baseline": {"launch": {"pid": 321}}, "cell": "acceptance",
                        "policy_sha256": "b" * 64, "socket": "/exact/socket"}
            events = []
            with patch.object(M, "birth", return_value=""), patch.object(M.subprocess, "Popen"), \
                    patch.object(M, "check_live"), patch.object(M, "source_ok"), patch.object(M, "socket_owner"), \
                    patch.object(M, "probe", return_value=manifest["baseline"]), patch.object(M, "serving", return_value=True), \
                    patch.object(M, "control"), patch.object(M, "status", return_value={
                        "requests_in_flight": 0, "lifecycle": {"operator_paused": True}}), \
                    patch.object(M, "launch"), patch.object(M, "restore"), \
                    patch.object(M.time, "monotonic", side_effect=[0, 0, 100, 300]), \
                    patch.object(M, "grouped", side_effect=lambda m, kind, timeout: events.append((kind, timeout))), \
                    patch("builtins.print"):
                result = M.worker(manifest)
            self.assertTrue(result["lab_passed"])
            self.assertEqual(events, [("build", 900), ("metal", 900), ("metalcheck", 120),
                                      ("fork-tests", 600), ("acceptance-tests", 600),
                                      ("build", 700), ("metalcheck", 120), ("cell", 3000)])
            self.assertTrue(result["result"].endswith("acceptance-result.json"))

    def inputs(self):
        cases = []
        for stratum in ("short", "1.5k", "4k", "8k", "near_boundary"):
            for index in range(40):
                cases.append({"id": f"{stratum}-{index}", "stratum": stratum,
                              "expected_native": stratum != "8k", "request": {
                                  "model": M.MODEL, "stream": False, "max_tokens": 40,
                                  "messages": [{"role": "user", "content": "Synthetic acceptance fixture"}]}})
        corpus = {"schema": "macprovider.native-mtp-acceptance-corpus.v1", "model_id": M.MODEL,
                  "max_prompt_tokens": 4096, "qualified_slots": 4, "max_native_active_rows": 1,
                  "proposal_depth": 1, "minimum_compared_positions": 6400, "cases": cases}
        data = json.dumps(corpus).encode()
        policy = {"schema": "macprovider.native-mtp-acceptance-policy.v1", "model_id": M.MODEL,
                  "target_sha256": "1" * 64, "mtp_sha256": "1" * 64, "tokenizer_sha256": "2" * 64,
                  "hw_model": "Mac15,14", "chip": "Apple M3 Ultra", "ram_gb": 256,
                  "os_build": "test-os", "xcode_build_version": "unknown", "swift_version": "test-swift",
                  "provider_commit": "a" * 40, "mlx_fork_revision": "b" * 40,
                  "quantization": "4bit", "cache_mode": "paged_kv_mixed", "corpus_sha256": M.sha(data)}
        return policy, corpus, data

    def summary(self, policy, corpus, data):
        summary = {"validate_only": "pass", "policy_sha256": M.sha(json.dumps(policy).encode()),
                   "cases": len(corpus["cases"]), "observed_environment": {}}
        for key, value in policy.items():
            if key != "schema":
                summary[key] = value
        for key in ("qualified_slots", "max_native_active_rows", "max_prompt_tokens", "proposal_depth",
                    "minimum_compared_positions"):
            summary[key] = corpus[key]
        return summary

    def test_acceptance_inputs_freeze_real_workload_without_performance_policy(self):
        policy, corpus, data = self.inputs()
        p, c = M.acceptance_inputs(json.dumps(policy), data, "a" * 40)
        self.assertEqual(p, policy)
        self.assertEqual(c, corpus)
        self.assertNotIn("thresholds", p)
        self.assertNotIn("prompt_tokens", p)
        self.assertEqual(M.policy_ok(json.dumps(policy), "a" * 40, "acceptance", data), p)

    def test_acceptance_policy_rejects_unknown_duplicate_and_invalid_fields(self):
        policy, _, data = self.inputs()
        for key, value in (("unexpected", 1), ("ram_gb", True), ("ram_gb", 256.0),
                           ("provider_commit", "c" * 40), ("hw_model", "other"),
                           ("mlx_fork_revision", "short"), ("corpus_sha256", "0" * 64)):
            with self.subTest(key=key, value=value), self.assertRaises(M.Refusal):
                M.acceptance_inputs(json.dumps(dict(policy, **{key: value})), data, "a" * 40)
        duplicate = json.dumps(policy)[:-1] + ',"schema":"macprovider.native-mtp-acceptance-policy.v1"}'
        with self.assertRaises(M.Refusal):
            M.acceptance_inputs(duplicate, data, "a" * 40)

    def test_acceptance_corpus_rejects_missing_strata_unsafe_bounds_and_last_case(self):
        for change in ("duplicate_id", "missing_stratum", "native_8k", "last_request", "position_budget"):
            with self.subTest(change=change):
                policy, corpus, _ = self.inputs()
                if change == "duplicate_id":
                    corpus["cases"][-1]["id"] = corpus["cases"][0]["id"]
                elif change == "missing_stratum":
                    for case in corpus["cases"]:
                        if case["stratum"] == "near_boundary": case["stratum"] = "short"
                elif change == "native_8k":
                    corpus["cases"][120]["expected_native"] = True
                elif change == "last_request":
                    corpus["cases"][-1]["request"]["max_tokens"] = 257
                else:
                    corpus["minimum_compared_positions"] = 6401
                data = json.dumps(corpus).encode()
                policy["corpus_sha256"] = M.sha(data)
                with self.assertRaises(M.Refusal):
                    M.acceptance_inputs(json.dumps(policy), data, "a" * 40)

    def test_acceptance_validator_summary_compares_every_frozen_field(self):
        policy, corpus, data = self.inputs()
        summary = self.summary(policy, corpus, data)
        M.acceptance_summary_ok(summary, json.dumps(policy).encode(), data, "a" * 40)
        for key in policy.keys() - {"schema"}:
            with self.subTest(key=key), self.assertRaises(M.Refusal):
                M.acceptance_summary_ok(dict(summary, **{key: "wrong"}), json.dumps(policy).encode(), data, "a" * 40)
        for key in ("cases", "minimum_compared_positions", "qualified_slots", "proposal_depth"):
            with self.subTest(key=key), self.assertRaises(M.Refusal):
                M.acceptance_summary_ok(dict(summary, **{key: True}), json.dumps(policy).encode(), data, "a" * 40)
        inconsistent = dict(summary, observed_environment={"ram_gb": 128})
        with self.assertRaises(M.Refusal):
            M.acceptance_summary_ok(inconsistent, json.dumps(policy).encode(), data, "a" * 40)

    def test_acceptance_preflight_production_parser_precedes_downtime(self):
        policy, corpus, data = self.inputs()
        frozen = json.dumps(policy).encode()
        for fail in (False, True):
            with self.subTest(fail=fail), tempfile.TemporaryDirectory() as tmp:
                root = Path(tmp) / ".config/macprovider/studio-mtp-measurement"
                root.mkdir(parents=True)
                binary = b"operator-built-validator"
                digest = M.sha(binary)
                (root / ("validator-" + digest[:16])).write_bytes(binary)
                manifest = {"source": "/campaign", "commit": "a" * 40, "cell": "acceptance", "nonce": "n1",
                            "policy_code": M.base64.b64encode(frozen).decode(), "policy_sha256": M.sha(frozen),
                            "corpus_code": M.base64.b64encode(data).decode(), "corpus_sha256": M.sha(data),
                            "validator_sha256": digest}
                result = Mock(returncode=1 if fail else 0,
                              stdout="" if fail else json.dumps(self.summary(policy, corpus, data)) + "\n",
                              stderr="Error: final request rejected by production parser\n" if fail else "")
                with patch.object(M.Path, "home", return_value=Path(tmp)), patch.object(M, "source_ok"), \
                        patch.object(M, "pins_ok"), patch.object(M.subprocess, "run", return_value=result) as child:
                    if fail:
                        with self.assertRaisesRegex(M.Refusal, "final request rejected"):
                            M.preflight_remote(manifest)
                    else:
                        self.assertEqual(M.preflight_remote(manifest)["preflight"], "pass")
                argv = child.call_args.args[0]
                self.assertIn("native-mtp-journey-e2e", argv)
                self.assertIn("--validate-acceptance-only", argv)
                self.assertNotIn("--validate-policy-only", argv)
                self.assertEqual(child.call_count, 1)
                self.assertEqual((root / "preflight-n1/acceptance-corpus.json").read_bytes(), data)

    def test_acceptance_arguments_refused_before_any_remote_access(self):
        policy, _, data = self.inputs()
        with tempfile.TemporaryDirectory() as tmp:
            path = Path(tmp) / "policy.json"
            path.write_text(json.dumps(policy))
            env = {"STUDIO_MTP_SOURCE_DIR": "/source", "STUDIO_MTP_CONFIG": "/config"}
            with patch.dict(M.os.environ, env), patch.object(M, "ssh") as ssh, self.assertRaises(M.Refusal):
                M.controller(argparse.Namespace(source_commit="a" * 40, policy=path, cell="acceptance", run=True))
            ssh.assert_not_called()

    def test_acceptance_failed_result_retained_and_no_retry(self):
        policy, _, data = self.inputs()
        with tempfile.TemporaryDirectory() as tmp:
            d = Path(tmp)
            frozen = json.dumps(policy).encode()
            (d / "policy.json").write_bytes(frozen)
            (d / "acceptance-corpus.json").write_bytes(data)
            manifest = {"dir": tmp, "source": "/campaign", "commit": "a" * 40, "cell": "acceptance",
                        "policy_sha256": M.sha(frozen), "corpus_sha256": M.sha(data)}
            def failed(argv, **kwargs):
                kwargs["stdout"].write(b'{"status":"fail","first_failure":"token_mismatch"}\n')
                return Mock(returncode=1)
            with patch.object(M.subprocess, "run", side_effect=failed) as child, self.assertRaises(M.Refusal):
                M.run_acceptance(manifest)
            self.assertEqual(child.call_count, 1)
            self.assertEqual(json.loads((d / "acceptance-result.json").read_text())["first_failure"], "token_mismatch")
            self.assertEqual(M.fixed_command(manifest, "cell")[2], "_acceptance")

    def test_acceptance_success_requires_complete_bound_results(self):
        for fault in (None, "policy", "positions", "cases", "case_identity", "check", "journey"):
            with self.subTest(fault=fault), tempfile.TemporaryDirectory() as tmp:
                policy, corpus, data = self.inputs()
                d = Path(tmp)
                frozen = json.dumps(policy).encode()
                (d / "policy.json").write_bytes(frozen)
                (d / "acceptance-corpus.json").write_bytes(data)
                manifest = {"dir": tmp, "source": "/campaign", "commit": "a" * 40, "cell": "acceptance",
                            "policy_sha256": M.sha(frozen), "corpus_sha256": M.sha(data)}
                value = {"schema": "macprovider.native-mtp-acceptance-result.v1", "status": "pass",
                         "journey_complete": False, "policy_sha256": M.sha(frozen), "corpus_sha256": M.sha(data),
                         "native_compared_positions": 6400, "checks": {"all_cases_passed": True},
                         "cases": [{"id": case["id"], "stratum": case["stratum"],
                                    "expected_native": case["expected_native"], "passed": True} for case in corpus["cases"]]}
                if fault == "policy": value["policy_sha256"] = "f" * 64
                elif fault == "positions": value["native_compared_positions"] = 6399
                elif fault == "cases": value["cases"].pop()
                elif fault == "case_identity": value["cases"][-1]["id"] = "another"
                elif fault == "check": value["checks"]["all_cases_passed"] = False
                elif fault == "journey": value["journey_complete"] = True
                def completed(argv, **kwargs):
                    kwargs["stdout"].write(json.dumps(value).encode())
                    return Mock(returncode=0)
                with patch.object(M.subprocess, "run", side_effect=completed) as child:
                    if fault is None:
                        M.run_acceptance(manifest)
                    else:
                        with self.assertRaises(M.Refusal): M.run_acceptance(manifest)
                    self.assertEqual(child.call_count, 1)

    def test_acceptance_transport_drift_stops_before_worker_or_lease(self):
        policy, _, data = self.inputs()
        with tempfile.TemporaryDirectory() as tmp:
            frozen = json.dumps(policy).encode()
            manifest = {"dir": str(Path(tmp) / "window"), "commit": "a" * 40, "cell": "acceptance",
                        "policy_sha256": M.sha(frozen), "corpus_sha256": M.sha(data),
                        "entry_code": M.base64.b64encode(b"entry").decode(),
                        "probe_code": M.base64.b64encode(b"probe").decode(),
                        "policy_code": M.base64.b64encode(frozen).decode(),
                        "corpus_code": M.base64.b64encode(data + b" ").decode()}
            with patch.object(M.sys, "argv", ["entry.py", "_prepare"]), \
                    patch.object(M.sys, "stdin", io.StringIO(json.dumps(manifest) + "\n")), \
                    patch.object(M, "worker") as worker, patch.object(M, "lease_reader") as lease, \
                    self.assertRaises(M.Refusal):
                M.main()
            worker.assert_not_called()
            lease.assert_not_called()


if __name__ == "__main__":
    unittest.main()
