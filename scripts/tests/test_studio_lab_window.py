from __future__ import annotations

import argparse
import importlib.util
import json
import os
import signal
import stat
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path
from unittest import mock


ROOT = Path(__file__).resolve().parents[2]
HELPER = ROOT / "scripts/ops/lib/studio-lab-window-remote.py"
SPEC = importlib.util.spec_from_file_location("studio_lab_window_remote", HELPER)
assert SPEC and SPEC.loader
remote = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(remote)


class Fixture:
    def __init__(self, root: Path):
        self.root = root
        self.stage = root / "stage"
        self.source = root / "source"
        self.install = root / "install"
        for directory in (self.stage, self.source, self.install):
            directory.mkdir(mode=0o700)
        self.config = root / "config.yaml"
        self.provider_plist = root / "provider.plist"
        self.watchdog_plist = root / "watchdog.plist"
        self.compatibility = self.install / "compatibility-set.json"
        self.binary = self.install / "macprovider-cli"
        self.probe = self.stage / "studio-owner-pin-probe.py"
        self.script = self.stage / "run-window-diagnostic.sh"
        files = {
            self.config: b"config\n", self.provider_plist: b"provider\n",
            self.watchdog_plist: b"watchdog\n", self.compatibility: b"compat\n",
            self.binary: b"signed-binary\n", self.probe: b"#!/usr/bin/python3\n",
            self.script: b"#!/bin/sh\nexit 0\n",
        }
        for path, data in files.items():
            path.write_bytes(data)
            path.chmod(0o700 if path in (self.probe, self.script, self.binary) else 0o600)
        artifact_paths = {
            "diagnostic_cli": self.source / "phase3-binary/.build/release/macprovider-cli",
            "glmbench": self.source / "scripts/lab/cb-studio/glm53-bench/.build/release/GLMBench",
            "diagnostic_metallib": self.source / "phase3-binary/.build/release/mlx.metallib",
            "glmbench_metallib": self.source / "scripts/lab/cb-studio/glm53-bench/.build/release/mlx.metallib",
            "fixture_config": self.source / ".lab-window/fixture/target/config.json",
            "fixture_index": self.source / ".lab-window/fixture/target/model.safetensors.index.json",
        }
        for index, path in enumerate(artifact_paths.values()):
            path.parent.mkdir(mode=0o700, parents=True, exist_ok=True)
            path.write_bytes(f"artifact-{index}\n".encode())
            path.chmod(0o700 if path.name in {"macprovider-cli", "GLMBench"} else 0o600)
        hashes = {
            "binary_sha256": remote.file_sha(self.binary, private=False),
            "config_sha256": remote.file_sha(self.config, private=False),
            "provider_plist_sha256": remote.file_sha(self.provider_plist, private=False),
            "watchdog_plist_sha256": remote.file_sha(self.watchdog_plist, private=False),
            "compatibility_set_sha256": remote.file_sha(self.compatibility, private=False),
            "probe_sha256": remote.file_sha(self.probe, private=False),
            "lab_script_sha256": remote.file_sha(self.script, private=False),
        }
        self.snapshot = {
            "config_sha256": hashes["config_sha256"],
            "provider_plist_sha256": hashes["provider_plist_sha256"],
            "watchdog_plist_sha256": hashes["watchdog_plist_sha256"],
            "compatibility_set_sha256": hashes["compatibility_set_sha256"],
            "provider_id_sha256": "1" * 64,
            "coordinator_origin": "https://coordinator.invalid",
            "compatibility_set_id": "fixture-set", "binary_version": "fixture-version",
            "model": "fixture-model", "model_loaded": True,
            "network_state": "buyer_serving", "requests_in_flight": 0,
            "coordinator_connected": True, "operator_paused": False,
            "pid": 4242, "process_start_us": 1800000123456789,
            "executable_path": str(self.binary),
        }
        self.document = {
            "schema_version": remote.MANIFEST_SCHEMA,
            "nonce": "fixture-nonce", "install_dir": str(self.install),
            "config_path": str(self.config), "provider_plist": str(self.provider_plist),
            "watchdog_plist": str(self.watchdog_plist),
            "compatibility_path": str(self.compatibility),
            "ctl_socket": str(root / "ctl.sock"), "provider_label": "fixture.provider",
            "watchdog_label": "fixture.provider-watchdog", "status_port": 18055,
            "probe_path": str(self.probe), "owner_pin_journal": str(root / "owner.json"),
            "lab_source_dir": str(self.source), "lab_script_path": str(self.script),
            "lab_git_head": "a" * 40, "log_path": str(self.stage / "supervisor.log"),
            "drain_timeout_s": 10, "lab_timeout_s": 20, "ready_timeout_s": 180,
            "poll_s": 1, "baseline": {**hashes, "snapshot": self.snapshot},
            "artifacts": {
                key: {"path": str(path), "sha256": remote.file_sha(path, private=False)}
                for key, path in artifact_paths.items()
            },
        }
        self.manifest = self.stage / "manifest.json"
        self.write_manifest()
        self.journal = self.stage / "journal.json"

    def write_manifest(self) -> None:
        self.manifest.write_text(json.dumps(self.document))
        self.manifest.chmod(0o600)

    def journal_record(self, phase: str = "prepared", revision: int = 1) -> dict:
        _, manifest_sha = remote.load_manifest(self.manifest)
        return {
            "schema_version": remote.JOURNAL_SCHEMA, "phase": phase,
            "revision": revision, "nonce": self.document["nonce"],
            "manifest_sha256": manifest_sha, "created_unix": 1, "updated_unix": 1,
            "lab_process_group_gone": False, "watchdog_restored": False,
        }

    def write_journal(self, phase: str = "prepared", revision: int = 1, **extra: object) -> dict:
        value = {**self.journal_record(phase, revision), **extra}
        remote.atomic_json(self.journal, value)
        return value


class StudioLabWindowTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(dir=Path.home())
        self.fixture = Fixture(Path(self.temp.name).resolve())

    def tearDown(self):
        self.temp.cleanup()

    def test_manifest_accepts_exact_private_contract_and_artifacts(self):
        manifest, manifest_sha = remote.load_manifest(self.fixture.manifest)
        self.assertEqual(manifest["nonce"], "fixture-nonce")
        self.assertEqual(len(manifest_sha), 64)
        self.assertEqual(set(manifest["artifacts"]), set(remote.ARTIFACT_KEYS))
        remote.validate_live_hashes(manifest)
        with mock.patch.object(remote, "validate_source"):
            remote.validate_lab_artifacts(manifest)

    def test_manifest_rejects_public_hardlinked_and_symlinked_files(self):
        with self.subTest("public"):
            self.fixture.manifest.chmod(0o644)
            with self.assertRaisesRegex(remote.Refusal, "not private"):
                remote.load_manifest(self.fixture.manifest)
            self.fixture.manifest.chmod(0o600)
        with self.subTest("hardlink"):
            link = self.fixture.stage / "manifest-link.json"
            os.link(self.fixture.manifest, link)
            with self.assertRaisesRegex(remote.Refusal, "unsafe file"):
                remote.load_manifest(self.fixture.manifest)
            link.unlink()
        with self.subTest("symlink"):
            link = self.fixture.stage / "manifest-symlink.json"
            link.symlink_to(self.fixture.manifest)
            with self.assertRaisesRegex(remote.Refusal, "unsafe file|symlink|not an absolute canonical path"):
                remote.load_manifest(link)

    def test_manifest_rejects_bad_baseline_and_noncanonical_artifact_path(self):
        self.fixture.document["baseline"]["snapshot"]["operator_paused"] = True
        self.fixture.write_manifest()
        with self.assertRaisesRegex(remote.Refusal, "not buyer-serving"):
            remote.load_manifest(self.fixture.manifest)
        self.fixture.document["baseline"]["snapshot"]["operator_paused"] = False
        self.fixture.document["artifacts"]["diagnostic_cli"]["path"] = str(self.fixture.binary)
        self.fixture.write_manifest()
        with self.assertRaisesRegex(remote.Refusal, "fixed path"):
            remote.load_manifest(self.fixture.manifest)

    def test_hash_validation_refuses_any_guarded_drift(self):
        manifest, _ = remote.load_manifest(self.fixture.manifest)
        self.fixture.provider_plist.write_bytes(b"changed\n")
        with self.assertRaisesRegex(remote.Refusal, "provider_plist_sha256"):
            remote.validate_live_hashes(manifest)

    def test_probe_hash_is_verified_before_staged_python_executes(self):
        manifest, _ = remote.load_manifest(self.fixture.manifest)
        self.fixture.probe.write_bytes(b"changed probe\n")
        self.fixture.probe.chmod(0o700)
        with mock.patch.object(remote.subprocess, "run") as run:
            with self.assertRaisesRegex(remote.Refusal, "probe bytes drifted"):
                remote.run_probe(manifest)
        run.assert_not_called()

    def test_source_validation_requires_fixed_staged_script_and_clean_bound_head(self):
        manifest, _ = remote.load_manifest(self.fixture.manifest)
        completed = [
            mock.Mock(stdout="a" * 40 + "\n"), mock.Mock(stdout=""),
        ]
        with mock.patch.object(remote.subprocess, "run", side_effect=completed):
            remote.validate_source(manifest)
        misplaced = self.fixture.source / "run-window-diagnostic.sh"
        misplaced.write_bytes(self.fixture.script.read_bytes())
        misplaced.chmod(0o700)
        manifest["lab_script_path"] = str(misplaced)
        with self.assertRaisesRegex(remote.Refusal, "protected manifest directory"):
            remote.validate_source(manifest)

    def test_artifact_hash_allows_fixed_lexical_symlink_to_safe_bound_target(self):
        logical = Path(self.fixture.document["artifacts"]["fixture_config"]["path"])
        target = self.fixture.root / "fixture-config-target.json"
        target.write_bytes(logical.read_bytes())
        target.chmod(0o600)
        logical.unlink()
        logical.symlink_to(target)
        manifest, _ = remote.load_manifest(self.fixture.manifest)
        with mock.patch.object(remote, "validate_source"):
            remote.validate_lab_artifacts(manifest)
        target.chmod(0o620)
        with mock.patch.object(remote, "validate_source"):
            with self.assertRaisesRegex(remote.Refusal, "writable by group"):
                remote.validate_lab_artifacts(manifest)

    def test_stable_snapshot_holds_one_process_identity_for_full_interval(self):
        manifest, _ = remote.load_manifest(self.fixture.manifest)
        clock = [0.0]
        probes = mock.Mock(return_value={"snapshot": dict(self.fixture.snapshot)})

        def advance(seconds):
            clock[0] += seconds

        with mock.patch.object(remote, "run_probe", probes), mock.patch.object(
            remote.time, "monotonic", side_effect=lambda: clock[0]
        ), mock.patch.object(remote.time, "sleep", side_effect=advance):
            result = remote.stable_serving(manifest, hold_s=3, deadline_s=4)
        self.assertEqual(result["pid"], self.fixture.snapshot["pid"])
        self.assertGreaterEqual(clock[0], 3)
        self.assertGreaterEqual(probes.call_count, 4)

    def test_status_selects_wait_recover_and_finish_from_bound_supervisor(self):
        args = argparse.Namespace(manifest=str(self.fixture.manifest), journal=str(self.fixture.journal))
        self.fixture.write_journal(supervisor_pid=55, supervisor_process_start_us=66)
        with mock.patch.object(remote, "same_process", return_value=True), mock.patch.object(
            remote, "JournalLock", side_effect=AssertionError("status took journal lock")
        ):
            waiting = remote.command_status(args)
        self.assertEqual((waiting["supervisor_active"], waiting["action"]), (True, "wait"))
        with mock.patch.object(remote, "same_process", return_value=False):
            recover = remote.command_status(args)
        self.assertEqual(recover["action"], "recover")
        self.fixture.write_journal(
            phase="restored", revision=7, restored_process={
                key: self.fixture.snapshot[key] for key in ("pid", "process_start_us", "executable_path")
            },
        )
        with mock.patch.object(remote, "same_process", return_value=False):
            finished = remote.command_status(args)
        self.assertEqual(finished["action"], "finish")
        self.assertIn("restored_process", finished)

    def test_recover_rejects_nonce_and_revision_mismatch_before_mutation(self):
        self.fixture.write_journal(revision=4)
        args = argparse.Namespace(
            manifest=str(self.fixture.manifest), journal=str(self.fixture.journal),
            nonce="wrong", revision=4,
        )
        with mock.patch.object(remote, "restore_locked") as restore:
            with self.assertRaisesRegex(remote.Refusal, "CAS mismatch"):
                remote.command_recover(args)
        restore.assert_not_called()

    def test_recover_refuses_to_fight_matching_active_supervisor(self):
        record = self.fixture.write_journal(
            revision=4, supervisor_pid=55, supervisor_process_start_us=66,
        )
        args = argparse.Namespace(
            manifest=str(self.fixture.manifest), journal=str(self.fixture.journal),
            nonce=record["nonce"], revision=4,
        )
        with mock.patch.object(remote, "same_process", return_value=True), mock.patch.object(
            remote, "restore_locked"
        ) as restore:
            with self.assertRaisesRegex(remote.Refusal, "supervisor is still active"):
                remote.command_recover(args)
        restore.assert_not_called()

    def test_prepare_recovers_existing_journal_before_fresh_preconditions(self):
        manifest, manifest_sha = remote.load_manifest(self.fixture.manifest)
        existing = self.fixture.write_journal()
        with mock.patch.object(remote, "restore_locked", return_value={**existing, "phase": "restored"}) as restore, mock.patch.object(
            remote, "validate_source", side_effect=AssertionError("fresh preflight ran")
        ):
            with self.assertRaisesRegex(remote.Refusal, "finish it"):
                remote.prepare_run(manifest, manifest_sha, self.fixture.journal)
        restore.assert_called_once()

    def test_restore_orders_group_stop_provider_readiness_then_watchdog(self):
        manifest, _ = remote.load_manifest(self.fixture.manifest)
        record = self.fixture.write_journal(phase="lab_running", revision=4)
        events: list[str] = []

        def transition(_path, value, phase, **changes):
            events.append(phase)
            return {**value, **changes, "phase": phase, "revision": value["revision"] + 1}

        def boot(label, _plist):
            events.append("boot:" + label)

        with mock.patch.object(remote, "stop_lab", side_effect=lambda *_: events.append("stop_lab")), mock.patch.object(
            remote, "validate_live_hashes", side_effect=lambda *_: events.append("hashes")
        ), mock.patch.object(remote, "write_transition", side_effect=transition), mock.patch.object(
            remote, "bootstrap", side_effect=boot
        ), mock.patch.object(remote, "control", side_effect=lambda *_: events.append("resume")), mock.patch.object(
            remote, "stable_serving", return_value=self.fixture.snapshot
        ):
            restored = remote.restore_locked(manifest, self.fixture.journal, record)
        self.assertEqual(restored["phase"], "restored")
        self.assertLess(events.index("boot:fixture.provider"), events.index("provider_ready"))
        self.assertLess(events.index("provider_ready"), events.index("boot:fixture.provider-watchdog"))

    def test_lost_lab_artifacts_do_not_block_status_or_provider_restore(self):
        missing = Path(self.fixture.document["artifacts"]["diagnostic_cli"]["path"])
        missing.unlink()
        manifest, _ = remote.load_manifest(self.fixture.manifest)
        record = self.fixture.write_journal(phase="stopped", revision=4)
        args = argparse.Namespace(manifest=str(self.fixture.manifest), journal=str(self.fixture.journal))
        with mock.patch.object(remote, "same_process", return_value=False):
            self.assertEqual(remote.command_status(args)["action"], "recover")
        with mock.patch.object(remote, "validate_source"):
            with self.assertRaisesRegex(remote.Refusal, "missing file"):
                remote.validate_lab_artifacts(manifest)
        with mock.patch.object(remote, "stop_lab"), mock.patch.object(
            remote, "validate_live_hashes"
        ), mock.patch.object(remote, "bootstrap"), mock.patch.object(
            remote, "control"
        ), mock.patch.object(remote, "stable_serving", return_value=self.fixture.snapshot):
            restored = remote.restore_locked(manifest, self.fixture.journal, record)
        self.assertEqual(restored["phase"], "restored")

    def test_finish_retains_journal_on_refusal_and_unlinks_only_after_confirmation(self):
        restored_process = {
            key: self.fixture.snapshot[key] for key in ("pid", "process_start_us", "executable_path")
        }
        record = self.fixture.write_journal(phase="restored", revision=8, restored_process=restored_process)
        base = dict(
            manifest=str(self.fixture.manifest), journal=str(self.fixture.journal),
            nonce=record["nonce"], revision=8,
        )
        with self.assertRaisesRegex(remote.Refusal, "confirmation"):
            remote.command_finish(argparse.Namespace(**base, controller_confirmed=False))
        self.assertTrue(self.fixture.journal.exists())
        with mock.patch.object(remote, "validate_live_hashes"), mock.patch.object(
            remote, "run_probe", return_value={"snapshot": self.fixture.snapshot}
        ), mock.patch.object(remote, "loaded", return_value=True):
            result = remote.command_finish(argparse.Namespace(**base, controller_confirmed=True))
        self.assertEqual(result["state"], "finished")
        self.assertFalse(self.fixture.journal.exists())

    def test_orphaned_group_refuses_recovery_instead_of_signaling_reused_pgid(self):
        manifest, _ = remote.load_manifest(self.fixture.manifest)
        record = {"lab_pid": 40, "lab_pgid": 40, "lab_process_start_us": 50}
        with mock.patch.object(remote, "same_process", return_value=False), mock.patch.object(
            remote, "process_group_alive", return_value=True
        ), mock.patch.object(remote.os, "killpg") as kill:
            with self.assertRaisesRegex(remote.Refusal, "leader identity changed"):
                remote.stop_lab(record, manifest)
        kill.assert_not_called()

    def test_same_process_checks_start_identity_for_valid_pid(self):
        with mock.patch.object(remote.os, "kill") as kill, mock.patch.object(
            remote, "process_start_us", return_value=456
        ):
            self.assertTrue(remote.same_process(123, 456))
            self.assertFalse(remote.same_process(123, 789))
        self.assertEqual(kill.call_count, 2)

    def test_provider_exit_wait_is_bounded_and_requires_exact_identity_to_end(self):
        clock = [0.0]

        def advance(seconds):
            clock[0] += seconds

        with mock.patch.object(remote, "same_process", return_value=True), mock.patch.object(
            remote.time, "monotonic", side_effect=lambda: clock[0]
        ), mock.patch.object(remote.time, "sleep", side_effect=advance):
            with self.assertRaisesRegex(remote.Refusal, "provider process remained alive"):
                remote.wait_process_exit(10, 20, timeout_s=3, poll_s=1)
        with mock.patch.object(remote, "same_process", side_effect=[True, False, False]):
            with mock.patch.object(remote.time, "sleep"):
                remote.wait_process_exit(10, 20, timeout_s=3, poll_s=1)

    def test_start_gate_refuses_eof_and_accepts_single_release_byte(self):
        compile(remote.GATED_EXEC, "<gated-exec>", "exec")
        read_fd, write_fd = os.pipe()
        os.close(write_fd)
        with self.assertRaisesRegex(remote.Refusal, "gate closed"):
            remote.await_start_gate(read_fd)
        read_fd, write_fd = os.pipe()
        os.write(write_fd, b"1")
        os.close(write_fd)
        remote.await_start_gate(read_fd)

    def test_actual_held_child_exits_on_gate_eof_without_running_work(self):
        marker = self.fixture.root / "must-not-run"
        script = self.fixture.root / "gated-work.py"
        script.write_text(
            "#!/usr/bin/env python3\nfrom pathlib import Path\n"
            f"Path({str(marker)!r}).write_text('ran')\n"
        )
        script.chmod(0o700)
        gate_read, gate_write = os.pipe()
        child = subprocess.Popen(
            [sys.executable, "-c", remote.GATED_EXEC, str(gate_read), str(script),
             str(Path.home()), "/usr/bin:/bin", "/tmp"],
            pass_fds=(gate_read,), close_fds=True, start_new_session=True,
        )
        os.close(gate_read)
        try:
            os.close(gate_write)
            self.assertEqual(child.wait(timeout=5), 125)
            self.assertFalse(marker.exists())
        finally:
            if child.poll() is None:
                os.killpg(child.pid, signal.SIGKILL)
                child.wait(timeout=5)
            if child.stdout is not None:
                child.stdout.close()

    def test_actual_timeout_group_ignoring_term_is_killed_and_reaped(self):
        child = subprocess.Popen(
            [sys.executable, "-c", "import signal,time; signal.signal(signal.SIGTERM, signal.SIG_IGN); print('ready', flush=True); time.sleep(60)"],
            stdout=subprocess.PIPE, text=True, start_new_session=True, close_fds=True,
        )
        try:
            self.assertEqual(child.stdout.readline().strip(), "ready")
            started = remote.process_start_us(child.pid)
            record = {"lab_pid": child.pid, "lab_pgid": child.pid, "lab_process_start_us": started}
            remote.stop_lab(record, {"poll_s": 1}, child=child)
            self.assertEqual(child.wait(timeout=5), -signal.SIGKILL)
            self.assertFalse(remote.process_group_alive(child.pid))
        finally:
            if child.poll() is None:
                os.killpg(child.pid, signal.SIGKILL)
                child.wait(timeout=5)
            if child.stdout is not None:
                child.stdout.close()

    def test_actual_reaped_leader_still_owns_and_cleans_remaining_group(self):
        descendant_code = (
            "import signal,time; signal.signal(signal.SIGTERM, signal.SIG_IGN); time.sleep(60)"
        )
        leader_code = (
            "import subprocess,sys; p=subprocess.Popen([sys.executable,'-c',sys.argv[1]]); "
            "print(p.pid,flush=True)"
        )
        leader = subprocess.Popen(
            [sys.executable, "-c", leader_code, descendant_code], stdout=subprocess.PIPE,
            text=True, start_new_session=True, close_fds=True,
        )
        started = remote.process_start_us(leader.pid)
        descendant = int(leader.stdout.readline().strip())
        try:
            self.assertEqual(leader.wait(timeout=5), 0)
            self.assertTrue(remote.process_group_alive(leader.pid))
            record = {
                "lab_pid": leader.pid, "lab_pgid": leader.pid,
                "lab_process_start_us": started,
            }
            remote.stop_lab(record, {"poll_s": 1}, child=leader)
            self.assertFalse(remote.process_group_alive(leader.pid))
        finally:
            if remote.process_group_alive(leader.pid):
                os.killpg(leader.pid, signal.SIGKILL)
            try:
                os.kill(descendant, 0)
            except ProcessLookupError:
                pass
            if leader.poll() is None:
                leader.wait(timeout=5)
            if leader.stdout is not None:
                leader.stdout.close()

    def test_detached_supervisor_is_journal_bound_before_gate_release(self):
        manifest, manifest_sha = remote.load_manifest(self.fixture.manifest)
        record = self.fixture.journal_record()
        events: list[str] = []
        fake_child = mock.Mock(pid=777)

        def transition(_path, value, phase, **changes):
            events.append("persist")
            return {**value, **changes, "phase": phase, "revision": value["revision"] + 1}

        def release(fd):
            events.append("release")
            os.close(fd)

        args = argparse.Namespace(manifest=str(self.fixture.manifest), journal=str(self.fixture.journal))
        with mock.patch.object(remote, "load_manifest", return_value=(manifest, manifest_sha)), mock.patch.object(
            remote, "prepare_run", return_value=record
        ), mock.patch.object(remote.subprocess, "Popen", return_value=fake_child) as popen, mock.patch.object(
            remote, "process_start_us", return_value=888
        ), mock.patch.object(remote, "write_transition", side_effect=transition), mock.patch.object(
            remote, "release_start_gate", side_effect=release
        ):
            result = remote.command_run(args)
        self.assertEqual(events, ["persist", "release"])
        self.assertEqual(result["supervisor_pid"], 777)
        invocation = popen.call_args.args[0]
        self.assertIn("--start-gate-fd", invocation)
        self.assertEqual(len(popen.call_args.kwargs["pass_fds"]), 1)


if __name__ == "__main__":
    unittest.main()
