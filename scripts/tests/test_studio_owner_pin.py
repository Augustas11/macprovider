import contextlib
import fcntl
import importlib.util
import io
import json
import os
import plistlib
import subprocess
import sys
import tempfile
import time
import unittest
from pathlib import Path
from unittest import mock


ROOT = Path(__file__).resolve().parents[2]
CONFIG_HELPER = ROOT / "scripts" / "ops" / "lib" / "studio-owner-pin-config.py"
PROBE_HELPER = ROOT / "scripts" / "ops" / "lib" / "studio-owner-pin-probe.py"


def load_script(path: Path, name: str):
    spec = importlib.util.spec_from_file_location(name, path)
    if spec is None or spec.loader is None:
        raise RuntimeError(f"cannot load {path}")
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


def valid_probe_journal(
    config: Path,
    backup: Path,
    phase: str = "prepared",
    executable_path: Path | None = None,
):
    executable = executable_path or config.parent / "install" / "macprovider-cli"
    value = {
        "schema_version": "macprovider.studio_owner_pin.v1",
        "phase": phase,
        "config_path": str(config),
        "backup_path": str(backup),
        "baseline_sha256": "4" * 64,
        "baseline_unowned_sha256": "5" * 64,
        "baseline_owned": {
            "max_concurrency_override": "4",
            "max_concurrency_source": "owner",
        },
        "intended_owned": {
            "max_concurrency_override": None,
            "max_concurrency_source": None,
        },
        "version": "3.0.2",
        "provider_id_sha256": "1" * 64,
        "model": "fixture-model",
        "policy_sha256": "2" * 64,
        "policy_release_id": "fixture-release",
        "policy_tuple_sha256": "3" * 64,
        "binary_sha256": "6" * 64,
        "team_id": "TEAMID",
        "signing_identifier": "tech.malibu.macprovider",
        "cdhash": "abcdef",
        "executable_path": str(executable),
    }
    if phase == "accepted":
        value.update({
            "accepted_pid": 4242,
            "accepted_process_start_us": 1_800_000_123_456_789,
            "accepted_executable_path": str(executable),
        })
    return value


class OwnerPinConfigTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.root = Path(self.temporary.name).resolve()
        self.config = self.root / "provider.yaml"
        self.journal = self.root / "owner-pin.journal.json"
        self.backup = self.root / "provider.yaml.bak-owner-pin-fixture"
        self.executable = self.root / "install" / "macprovider-cli"
        self.executable.parent.mkdir()
        self.executable.write_bytes(b"signed-fixture")
        self.baseline = (
            b"# retain comments and exact unrelated bytes\n"
            b"api_key: secret-that-must-not-enter-journal\n"
            b"continuous_batch_queue_limit: 9  # unusual spacing stays\n"
            b"max_concurrency_override: 4\n"
            b"draft_model: none\n"
            b"max_concurrency_source: owner\n"
            b"nested:\n  max_concurrency_override: untouched\n"
        )
        self.config.write_bytes(self.baseline)
        self.config.chmod(0o600)

    def tearDown(self):
        self.temporary.cleanup()

    def command(self, action, *extra, check=False):
        args = [sys.executable, str(CONFIG_HELPER), action]
        if action == "prepare":
            args.extend(
                [
                    "--config",
                    str(self.config),
                    "--journal",
                    str(self.journal),
                    "--backup",
                    str(self.backup),
                    "--version",
                    "3.0.2",
                    "--provider-id-sha256",
                    "1" * 64,
                    "--model",
                    "mlx-community/GLM-4.7-Flash-4bit",
                    "--policy-sha256",
                    "2" * 64,
                    "--policy-release-id",
                    "fixture-release",
                    "--policy-tuple-sha256",
                    "3" * 64,
                    "--binary-sha256",
                    "6" * 64,
                    "--team-id",
                    "TEAMID",
                    "--signing-identifier",
                    "tech.malibu.macprovider",
                    "--cdhash",
                    "abcdef",
                    "--executable-path",
                    str(self.executable),
                ]
            )
        elif action in {"apply", "restore", "accept", "finish"}:
            args.extend(["--config", str(self.config), "--journal", str(self.journal)])
        elif action == "inspect":
            args.extend(["--journal", str(self.journal)])
        args.extend(extra)
        return subprocess.run(
            args,
            cwd=ROOT,
            env={**os.environ, "PYTHONDONTWRITEBYTECODE": "1"},
            text=True,
            capture_output=True,
            check=check,
        )

    def prepare(self):
        result = self.command("prepare")
        self.assertEqual(result.returncode, 0, result.stderr)
        return result

    def apply(self):
        result = self.command("apply")
        self.assertEqual(result.returncode, 0, result.stderr)
        return result

    def accept(self, *extra):
        result = self.command(
            "accept",
            "--pid",
            "4242",
            "--process-start-us",
            "1800000123456789",
            "--executable-path",
            str(self.executable),
            *extra,
        )
        self.assertEqual(result.returncode, 0, result.stderr)
        return result

    def assert_refused(self, result):
        self.assertEqual(result.returncode, 3, (result.stdout, result.stderr))
        self.assertIn("REFUSED:", result.stderr)

    def test_prepare_apply_finish_exact_pin_and_private_artifacts(self):
        self.prepare()
        self.assertEqual(self.backup.read_bytes(), self.baseline)
        self.assertEqual(self.backup.stat().st_mode & 0o777, 0o600)
        self.assertEqual(self.journal.stat().st_mode & 0o777, 0o600)

        journal_bytes = self.journal.read_bytes()
        journal = json.loads(journal_bytes)
        self.assertNotIn(b"secret-that-must-not-enter-journal", journal_bytes)
        self.assertEqual(journal["phase"], "prepared")
        self.assertEqual(
            journal["baseline_owned"],
            {"max_concurrency_override": "4", "max_concurrency_source": "owner"},
        )
        self.assertNotIn("baseline_bytes", journal)
        self.assertEqual(journal["binary_sha256"], "6" * 64)
        self.assertEqual(journal["team_id"], "TEAMID")
        self.assertEqual(journal["signing_identifier"], "tech.malibu.macprovider")
        self.assertEqual(journal["cdhash"], "abcdef")
        self.assertEqual(journal["executable_path"], str(self.executable))

        self.apply()
        wanted = self.baseline.replace(b"max_concurrency_override: 4\n", b"").replace(
            b"max_concurrency_source: owner\n", b""
        )
        self.assertEqual(self.config.read_bytes(), wanted)
        self.assertEqual(json.loads(self.journal.read_text())["phase"], "applied")

        self.accept()
        accepted = json.loads(self.journal.read_text())
        self.assertEqual(accepted["phase"], "accepted")
        self.assertEqual(accepted["accepted_pid"], 4242)
        self.assertEqual(accepted["accepted_process_start_us"], 1800000123456789)
        self.assertEqual(accepted["accepted_executable_path"], str(self.executable))

        inspected = self.command("inspect")
        self.assertEqual(inspected.returncode, 0, inspected.stderr)
        self.assertEqual(json.loads(inspected.stdout)["owned"], {
            "max_concurrency_override": None,
            "max_concurrency_source": None,
        })
        finished = self.command("finish")
        self.assertEqual(finished.returncode, 0, finished.stderr)
        self.assertFalse(self.journal.exists())
        self.assertFalse(self.backup.exists())

    def test_apply_cas_refuses_any_change_after_prepare(self):
        self.prepare()
        changed = self.baseline + b"operator_note: foreign\n"
        self.config.write_bytes(changed)
        result = self.command("apply")
        self.assert_refused(result)
        self.assertEqual(self.config.read_bytes(), changed)
        self.assertEqual(json.loads(self.journal.read_text())["phase"], "prepared")

    def test_signed_identity_metadata_remains_required_after_prepare(self):
        self.prepare()
        journal = json.loads(self.journal.read_text())
        journal["binary_sha256"] = ""
        self.journal.write_text(json.dumps(journal))

        self.assert_refused(self.command("apply"))
        self.assertEqual(self.config.read_bytes(), self.baseline)
        self.assertTrue(self.backup.exists())
        self.assertTrue(self.journal.exists())

    def test_accept_requires_applied_unpinned_exact_process_identity(self):
        self.prepare()
        refused = self.command(
            "accept",
            "--pid", "4242",
            "--process-start-us", "1800000123456789",
            "--executable-path", str(self.executable),
        )
        self.assert_refused(refused)
        self.assertTrue(self.backup.exists())
        self.assertTrue(self.journal.exists())

        self.apply()
        for name, arguments in {
            "zero pid": ("--pid", "0", "--process-start-us", "1800000123456789", "--executable-path", str(self.executable)),
            "zero start": ("--pid", "4242", "--process-start-us", "0", "--executable-path", str(self.executable)),
            "nonnumeric pid": ("--pid", "not-a-pid", "--process-start-us", "1800000123456789", "--executable-path", str(self.executable)),
            "different executable": ("--pid", "4242", "--process-start-us", "1800000123456789", "--executable-path", str(self.root / "other")),
        }.items():
            with self.subTest(name=name):
                result = self.command("accept", *arguments)
                self.assert_refused(result)
                self.assertEqual(json.loads(self.journal.read_text())["phase"], "applied")

        self.accept()
        self.assert_refused(self.command(
            "accept",
            "--pid", "4243",
            "--process-start-us", "1800000123456790",
            "--executable-path", str(self.executable),
        ))
        accepted = json.loads(self.journal.read_text())
        self.assertEqual(accepted["accepted_pid"], 4242)
        self.assertEqual(accepted["accepted_process_start_us"], 1800000123456789)

    def test_finish_refusals_retain_recovery_artifacts_and_unrelated_file(self):
        self.prepare()
        self.apply()
        unrelated = self.root / "unrelated-private-file"
        unrelated.write_bytes(b"do-not-delete")
        unrelated.chmod(0o600)

        self.assert_refused(self.command("finish"))
        self.assertTrue(self.backup.exists())
        self.assertTrue(self.journal.exists())
        self.assertEqual(unrelated.read_bytes(), b"do-not-delete")

        self.accept()
        self.backup.chmod(0o640)
        self.assert_refused(self.command("finish"))
        self.assertTrue(self.backup.exists())
        self.assertTrue(self.journal.exists())
        self.assertEqual(unrelated.read_bytes(), b"do-not-delete")

        self.backup.chmod(0o600)
        finished = self.command("finish")
        self.assertEqual(finished.returncode, 0, finished.stderr)
        self.assertFalse(self.backup.exists())
        self.assertFalse(self.journal.exists())
        self.assertEqual(unrelated.read_bytes(), b"do-not-delete")

    def test_finish_refuses_symlinked_backup_without_deleting_target(self):
        self.prepare()
        self.apply()
        self.accept()
        target = self.root / "unrelated-target"
        target.write_bytes(b"preserve")
        self.backup.unlink()
        self.backup.symlink_to(target)

        self.assert_refused(self.command("finish"))
        self.assertTrue(self.journal.exists())
        self.assertTrue(self.backup.is_symlink())
        self.assertEqual(target.read_bytes(), b"preserve")

    def test_finish_refuses_hardlinked_backup_without_deleting_target(self):
        self.prepare()
        self.apply()
        self.accept()
        target = self.root / "unrelated-target"
        target.write_bytes(b"preserve")
        target.chmod(0o600)
        self.backup.unlink()
        os.link(target, self.backup)

        self.assert_refused(self.command("finish"))
        self.assertTrue(self.journal.exists())
        self.assertEqual(self.backup.read_bytes(), b"preserve")
        self.assertEqual(target.read_bytes(), b"preserve")

    def test_finish_refuses_replaced_backup_bytes_and_retains_recovery_state(self):
        self.prepare()
        self.apply()
        self.accept()
        replaced = b"different private config bytes\n"
        self.backup.write_bytes(replaced)
        self.backup.chmod(0o600)

        self.assert_refused(self.command("finish"))
        self.assertEqual(self.backup.read_bytes(), replaced)
        self.assertTrue(self.journal.exists())
        self.assertEqual(json.loads(self.journal.read_text())["phase"], "accepted")

    def test_finish_retries_when_owned_backup_is_already_absent(self):
        self.prepare()
        self.apply()
        self.accept()
        self.backup.unlink()
        finished = self.command("finish")
        self.assertEqual(finished.returncode, 0, finished.stderr)
        self.assertFalse(self.journal.exists())

    def test_restore_preserves_concurrent_unowned_bytes_and_finish(self):
        self.prepare()
        self.apply()
        applied = self.config.read_bytes()
        concurrent = applied.replace(
            b"continuous_batch_queue_limit: 9  # unusual spacing stays\n",
            b"continuous_batch_queue_limit: 17 # operator edit\n",
        ) + b"operator_note: keep-exactly\n"
        self.config.write_bytes(concurrent)

        restored = self.command("restore")
        self.assertEqual(restored.returncode, 0, restored.stderr)
        self.assertEqual(
            self.config.read_bytes(),
            concurrent
            + b"max_concurrency_override: 4\nmax_concurrency_source: owner\n",
        )
        self.assertEqual(json.loads(self.journal.read_text())["phase"], "config_restored")

        finished = self.command("finish", "--restored")
        self.assertEqual(finished.returncode, 0, finished.stderr)
        self.assertFalse(self.backup.exists())
        self.assertFalse(self.journal.exists())
        self.assertFalse(self.journal.exists())
        self.assertFalse(self.backup.exists())

    def test_restore_refuses_foreign_owned_edit_without_overwrite(self):
        self.prepare()
        self.apply()
        foreign = self.config.read_bytes() + (
            b"max_concurrency_override: 8\nmax_concurrency_source: autotune\n"
        )
        self.config.write_bytes(foreign)
        result = self.command("restore")
        self.assert_refused(result)
        self.assertEqual(self.config.read_bytes(), foreign)
        self.assertEqual(json.loads(self.journal.read_text())["phase"], "applied")

    def test_shared_config_lock_serializes_apply(self):
        self.prepare()
        lock_path = self.config.parent / f".{self.config.name}.lock"
        lock_fd = os.open(lock_path, os.O_CREAT | os.O_RDWR, 0o600)
        self.addCleanup(os.close, lock_fd)
        fcntl.flock(lock_fd, fcntl.LOCK_EX)
        process = subprocess.Popen(
            [
                sys.executable,
                str(CONFIG_HELPER),
                "apply",
                "--config",
                str(self.config),
                "--journal",
                str(self.journal),
            ],
            cwd=ROOT,
            env={**os.environ, "PYTHONDONTWRITEBYTECODE": "1"},
            text=True,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
        )
        self.addCleanup(lambda: process.poll() is None and process.kill())
        time.sleep(0.15)
        self.assertIsNone(process.poll(), "apply did not wait for the shared config lock")
        fcntl.flock(lock_fd, fcntl.LOCK_UN)
        stdout, stderr = process.communicate(timeout=3)
        self.assertEqual(process.returncode, 0, (stdout, stderr))

    def test_recovery_after_prepare_and_after_restored_phase(self):
        self.prepare()
        recovered = self.command("restore")
        self.assertEqual(recovered.returncode, 0, recovered.stderr)
        self.assertEqual(self.config.read_bytes(), self.baseline)
        self.assertEqual(json.loads(self.journal.read_text())["phase"], "config_restored")

        repeated = self.command("restore")
        self.assertEqual(repeated.returncode, 0, repeated.stderr)
        self.assertEqual(self.config.read_bytes(), self.baseline)
        finished = self.command("finish", "--restored")
        self.assertEqual(finished.returncode, 0, finished.stderr)

    def test_recovery_after_apply_refuses_reapply_then_restores(self):
        self.prepare()
        self.apply()
        applied = self.config.read_bytes()
        self.assert_refused(self.command("apply"))
        self.assertEqual(self.config.read_bytes(), applied)
        restored = self.command("restore")
        self.assertEqual(restored.returncode, 0, restored.stderr)
        self.assertEqual(
            self.config.read_bytes(),
            applied + b"max_concurrency_override: 4\nmax_concurrency_source: owner\n",
        )

    def test_prepare_requires_exact_unquoted_four_owner_pin(self):
        cases = {
            "wrong override": b"max_concurrency_override: 8\nmax_concurrency_source: owner\n",
            "wrong source": b"max_concurrency_override: 4\nmax_concurrency_source: autotune\n",
            "missing source": b"max_concurrency_override: 4\n",
            "duplicate": (
                b"max_concurrency_override: 4\nmax_concurrency_override: 4\n"
                b"max_concurrency_source: owner\n"
            ),
            "quoted values": (
                b'max_concurrency_override: "4"\nmax_concurrency_source: \'owner\'\n'
            ),
            "quoted key": b'"max_concurrency_override": 4\nmax_concurrency_source: owner\n',
            "flow mapping": (
                b"{max_concurrency_override: 4, max_concurrency_source: owner}\n"
            ),
            "block scalar": b"max_concurrency_override: >\n  4\nmax_concurrency_source: owner\n",
        }
        for name, data in cases.items():
            with self.subTest(name=name):
                with tempfile.TemporaryDirectory() as directory:
                    root = Path(directory).resolve()
                    config = root / "config.yaml"
                    config.write_bytes(data)
                    result = subprocess.run(
                        [
                            sys.executable,
                            str(CONFIG_HELPER),
                            "prepare",
                            "--config",
                            str(config),
                            "--journal",
                            str(root / "journal.json"),
                            "--backup",
                            str(root / "backup"),
                            "--version",
                            "fixture",
                            "--provider-id-sha256",
                            "1" * 64,
                            "--model",
                            "fixture",
                            "--policy-sha256",
                            "2" * 64,
                            "--policy-release-id",
                            "fixture",
                            "--policy-tuple-sha256",
                            "3" * 64,
                            "--binary-sha256",
                            "6" * 64,
                            "--team-id",
                            "TEAMID",
                            "--signing-identifier",
                            "tech.malibu.macprovider",
                            "--cdhash",
                            "abcdef",
                            "--executable-path",
                            str(root / "macprovider-cli"),
                        ],
                        cwd=ROOT,
                        text=True,
                        capture_output=True,
                    )
                    self.assert_refused(result)
                    self.assertFalse((root / "journal.json").exists())
                    self.assertFalse((root / "backup").exists())

    def test_unsafe_paths_fail_closed(self):
        with self.subTest("relative config"):
            result = subprocess.run(
                [
                    sys.executable,
                    str(CONFIG_HELPER),
                    "prepare",
                    "--config",
                    "relative.yaml",
                    "--journal",
                    str(self.journal),
                    "--backup",
                    str(self.backup),
                    "--version",
                    "fixture",
                    "--provider-id-sha256",
                    "1" * 64,
                    "--model",
                    "fixture",
                    "--policy-sha256",
                    "2" * 64,
                    "--policy-release-id",
                    "fixture",
                    "--policy-tuple-sha256",
                    "3" * 64,
                    "--binary-sha256",
                    "6" * 64,
                    "--team-id",
                    "TEAMID",
                    "--signing-identifier",
                    "tech.malibu.macprovider",
                    "--cdhash",
                    "abcdef",
                    "--executable-path",
                    str(self.executable),
                ],
                cwd=self.root,
                text=True,
                capture_output=True,
            )
            self.assert_refused(result)

        for name, make_unsafe in {
            "symlink config": lambda path: path.symlink_to(self.config),
            "hardlink config": lambda path: os.link(self.config, path),
        }.items():
            with self.subTest(name=name):
                unsafe = self.root / name.replace(" ", "-")
                make_unsafe(unsafe)
                original = self.config
                self.config = unsafe
                try:
                    self.assert_refused(self.command("prepare"))
                finally:
                    self.config = original

        with self.subTest("backup outside config directory"):
            other = self.root / "other"
            other.mkdir()
            original = self.backup
            self.backup = other / "backup"
            try:
                self.assert_refused(self.command("prepare"))
            finally:
                self.backup = original


class OwnerPinProbeTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.probe = load_script(PROBE_HELPER, "studio_owner_pin_probe_for_test")

    def test_config_and_journal_views_are_secret_free_and_fail_on_duplicates(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            config = root / "config.yaml"
            config.write_text(
                "api_key: do-not-print\n"
                "max_concurrency_override: 4\n"
                "max_concurrency_source: owner\n"
                "continuous_batch_queue_limit: 8\n"
            )
            self.assertEqual(
                self.probe.config_fields(config),
                {
                    "max_concurrency_override": "4",
                    "max_concurrency_source": "owner",
                    "continuous_batch_queue_limit": "8",
                    "draft_model": None,
                },
            )
            journal = root / "journal.json"
            journal_payload = valid_probe_journal(
                config, root / "backup", phase="applied"
            )
            journal_payload["secret"] = "must-not-print"
            journal.write_text(json.dumps(journal_payload))
            visible = self.probe.journal_fields(journal, config)
            self.assertNotIn("secret", visible)
            self.assertEqual(visible["phase"], "applied")
            self.assertEqual(visible["binary_sha256"], "6" * 64)
            self.assertEqual(visible["executable_path"], str(root / "install" / "macprovider-cli"))
            with self.assertRaisesRegex(RuntimeError, "another config"):
                self.probe.journal_fields(journal, root / "other.yaml")
            incomplete = dict(journal_payload)
            incomplete["signing_identifier"] = ""
            journal.write_text(json.dumps(incomplete))
            with self.assertRaisesRegex(RuntimeError, "metadata is incomplete"):
                self.probe.journal_fields(journal, config)

            config.write_text(
                "max_concurrency_override: 4\nmax_concurrency_override: 4\n"
            )
            with self.assertRaisesRegex(RuntimeError, "duplicate"):
                self.probe.config_fields(config)

            accepted = valid_probe_journal(
                config, root / "backup", phase="accepted"
            )
            journal.write_text(json.dumps(accepted))
            accepted_view = self.probe.journal_fields(journal, config)
            self.assertEqual(accepted_view["accepted_pid"], 4242)
            self.assertEqual(
                accepted_view["accepted_process_start_us"], 1800000123456789
            )
            for key, invalid in {
                "accepted_pid": 0,
                "accepted_process_start_us": False,
                "accepted_executable_path": str(root / "other"),
            }.items():
                with self.subTest(invalid_accepted_field=key):
                    broken = dict(accepted)
                    broken[key] = invalid
                    journal.write_text(json.dumps(broken))
                    with self.assertRaisesRegex(RuntimeError, "accepted process"):
                        self.probe.journal_fields(journal, config)

    def test_probe_main_isolated_output_omits_raw_provider_and_config_secrets(self):
        home = Path.home().resolve()
        with tempfile.TemporaryDirectory(dir=home) as directory:
            root = Path(directory).resolve()
            install = root / "install"
            install.mkdir()
            binary = install / "macprovider-cli"
            binary.write_bytes(b"fixture-binary")
            self.assertFalse((install / "catalog-release").exists())
            config = root / "config.yaml"
            config.write_text(
                "api_key: config-secret\nmax_concurrency_override: 4\n"
                "max_concurrency_source: owner\ncontinuous_batch_queue_limit: 8\n"
            )
            journal = root / "journal.json"
            journal_payload = valid_probe_journal(
                config, root / "backup", executable_path=binary
            )
            journal_payload["secret"] = "journal-secret"
            journal.write_text(json.dumps(journal_payload))
            raw_provider = "provider-secret-identity"
            status = json.dumps({
                "provider_id": raw_provider,
                "binary_version": "3.0.2",
                "model": "fixture-model",
                "service_instance": {"pid": 4242},
            }).encode()

            commands = []

            def fake_run(args, **_kwargs):
                commands.append(args)
                if args[0] == "codesign":
                    if "--verify" in args:
                        return subprocess.CompletedProcess(args, 0, stdout="", stderr="")
                    return subprocess.CompletedProcess(
                        args,
                        0,
                        stdout=(
                            "Identifier=tech.malibu.macprovider\n"
                            "TeamIdentifier=TEAMID\nCDHash=ABCDEF\n"
                        ),
                    )
                if args[0] == "curl":
                    return subprocess.CompletedProcess(args, 0, stdout=status, stderr=b"")
                if args[0] == "sysctl":
                    return subprocess.CompletedProcess(args, 0, stdout="Mac15,14\n", stderr="")
                return subprocess.CompletedProcess(args, 0, stdout="3.0.2\n", stderr="")

            argv = [
                str(PROBE_HELPER),
                "--install-dir",
                str(install),
                "--config",
                str(config),
                "--journal",
                str(journal),
                "--port",
                "18055",
                "--label",
                "tech.malibu.fixture",
            ]
            output = io.StringIO()
            launch_mock = mock.Mock(return_value={
                "pid": 4242,
                "process_start_us": 1800000123456789,
                "executable_path": str(binary),
            })
            with mock.patch.object(sys, "argv", argv), mock.patch.object(
                self.probe.subprocess, "run", side_effect=fake_run
            ), mock.patch.object(
                self.probe,
                "launch_identity",
                launch_mock,
            ), contextlib.redirect_stdout(output):
                self.assertEqual(self.probe.main(), 0)
            launch_mock.assert_called_once_with(
                binary, config, "tech.malibu.fixture", 4242
            )

            encoded = output.getvalue()
            result = json.loads(encoded)
            self.assertNotIn("config-secret", encoded)
            self.assertNotIn("journal-secret", encoded)
            self.assertNotIn(raw_provider, encoded)
            self.assertEqual(result["status"]["provider_id_sha256"], self.probe.digest(raw_provider.encode()))
            self.assertEqual(result["installed"]["cdhash"], "abcdef")
            self.assertEqual(result["launch"], {
                "pid": 4242,
                "process_start_us": 1800000123456789,
                "executable_path": str(binary),
            })
            codesign = [command for command in commands if command[0] == "codesign"]
            self.assertEqual(
                codesign[0],
                ["codesign", "--verify", "--strict", "--verbose=2", str(binary)],
            )
            self.assertEqual(
                codesign[1],
                ["codesign", "-d", "--arch", "arm64", "-vvv", str(binary)],
            )

            journal_only_argv = [
                str(PROBE_HELPER),
                "--journal",
                str(journal),
                "--journal-only",
                "--expected-config",
                str(config),
            ]
            journal_only_output = io.StringIO()
            with mock.patch.object(sys, "argv", journal_only_argv), mock.patch.object(
                self.probe.subprocess, "run", side_effect=fake_run
            ), contextlib.redirect_stdout(journal_only_output):
                self.assertEqual(self.probe.main(), 0)
            recovery = json.loads(journal_only_output.getvalue())
            self.assertEqual(recovery["journal"]["phase"], "prepared")
            self.assertEqual(recovery["hardware_model"], "Mac15,14")

    def test_launch_identity_binds_plist_launchctl_pid_and_process(self):
        with tempfile.TemporaryDirectory() as directory:
            home = Path(directory).resolve()
            binary = home / "install" / "macprovider-cli"
            binary.parent.mkdir()
            binary.write_bytes(b"fixture")
            config = home / "provider.yaml"
            config.write_text("max_concurrency_override: 4\n")
            label = "tech.malibu.fixture"
            plist = home / "Library" / "LaunchAgents" / f"{label}.plist"
            plist.parent.mkdir(parents=True)

            def write_plist(arguments, program=str(binary)):
                document = {"Label": label, "ProgramArguments": arguments}
                if program is not None:
                    document["Program"] = program
                with plist.open("wb") as handle:
                    plistlib.dump(document, handle)

            write_plist([str(binary), "serve", "--config", str(config)])

            process = {
                "pid": 4242,
                "process_start_us": 1800000123456789,
                "uid": os.getuid(),
                "ruid": os.getuid(),
                "executable_path": str(binary),
            }

            def launchctl(pid):
                return subprocess.CompletedProcess(
                    ["launchctl"], 0, stdout=f"pid = {pid}\n", stderr=""
                )

            with mock.patch.object(Path, "home", return_value=home), mock.patch.object(
                self.probe.subprocess, "run", return_value=launchctl(4242)
            ), mock.patch.object(
                self.probe, "process_identity", return_value=process
            ):
                identity = self.probe.launch_identity(binary, config, label, 4242)
            self.assertEqual(identity, process)

            with mock.patch.object(Path, "home", return_value=home), mock.patch.object(
                self.probe.subprocess, "run", return_value=launchctl(4243)
            ):
                with self.assertRaisesRegex(RuntimeError, "launchd and status"):
                    self.probe.launch_identity(binary, config, label, 4242)

            wrong_process = {**process, "executable_path": str(home / "other")}
            with mock.patch.object(Path, "home", return_value=home), mock.patch.object(
                self.probe.subprocess, "run", return_value=launchctl(4242)
            ), mock.patch.object(
                self.probe, "process_identity", return_value=wrong_process
            ):
                with self.assertRaisesRegex(RuntimeError, "running provider"):
                    self.probe.launch_identity(binary, config, label, 4242)

            write_plist([str(binary), "serve", "--config", str(config)])
            with mock.patch.object(Path, "home", return_value=home):
                with self.assertRaisesRegex(RuntimeError, "executable/config mismatch"):
                    self.probe.launch_identity(
                        binary, home / "other.yaml", label, 4242
                    )

            for name, arguments in {
                "duplicate config": [
                    str(binary), "serve", "--config", str(config),
                    "--config", str(config),
                ],
                "relative config": [str(binary), "serve", "--config", "provider.yaml"],
                "alternate config": [
                    str(binary), "serve", "--config", str(home / "other.yaml")
                ],
            }.items():
                with self.subTest(name=name):
                    write_plist(arguments)
                    with mock.patch.object(Path, "home", return_value=home):
                        with self.assertRaisesRegex(
                            RuntimeError, "executable/config mismatch|no executable argument"
                        ):
                            self.probe.launch_identity(binary, config, label, 4242)

    def test_probe_refuses_unsafe_regular_files_and_outside_home_paths(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            target = root / "target"
            target.write_text("fixture")
            link = root / "link"
            link.symlink_to(target)
            with self.assertRaisesRegex(RuntimeError, "unsafe file"):
                self.probe.regular(link)

        result = subprocess.run(
            [
                sys.executable,
                str(PROBE_HELPER),
                "--install-dir",
                "/tmp/outside-home",
                "--config",
                "/tmp/outside-home/config.yaml",
                "--journal",
                "/tmp/outside-home/journal.json",
                "--port",
                "18055",
                "--label",
                "tech.malibu.fixture",
            ],
            cwd=ROOT,
            text=True,
            capture_output=True,
        )
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("under HOME", result.stderr)


if __name__ == "__main__":
    unittest.main()
