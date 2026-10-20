import contextlib
import fcntl
import importlib.util
import io
import json
import os
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


def valid_probe_journal(config: Path, backup: Path, phase: str = "prepared"):
    return {
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
    }


class OwnerPinConfigTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.root = Path(self.temporary.name).resolve()
        self.config = self.root / "provider.yaml"
        self.journal = self.root / "owner-pin.journal.json"
        self.backup = self.root / "provider.yaml.owner-pin-backup"
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
                ]
            )
        elif action in {"apply", "restore", "finish"}:
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

        self.apply()
        wanted = self.baseline.replace(b"max_concurrency_override: 4\n", b"").replace(
            b"max_concurrency_source: owner\n", b""
        )
        self.assertEqual(self.config.read_bytes(), wanted)
        self.assertEqual(json.loads(self.journal.read_text())["phase"], "applied")

        inspected = self.command("inspect")
        self.assertEqual(inspected.returncode, 0, inspected.stderr)
        self.assertEqual(json.loads(inspected.stdout)["owned"], {
            "max_concurrency_override": None,
            "max_concurrency_source": None,
        })
        finished = self.command("finish")
        self.assertEqual(finished.returncode, 0, finished.stderr)
        self.assertFalse(self.journal.exists())
        self.assertEqual(self.backup.read_bytes(), self.baseline)

    def test_apply_cas_refuses_any_change_after_prepare(self):
        self.prepare()
        changed = self.baseline + b"operator_note: foreign\n"
        self.config.write_bytes(changed)
        result = self.command("apply")
        self.assert_refused(result)
        self.assertEqual(self.config.read_bytes(), changed)
        self.assertEqual(json.loads(self.journal.read_text())["phase"], "prepared")

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
        self.assertFalse(self.journal.exists())

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
            with self.assertRaisesRegex(RuntimeError, "another config"):
                self.probe.journal_fields(journal, root / "other.yaml")

            config.write_text(
                "max_concurrency_override: 4\nmax_concurrency_override: 4\n"
            )
            with self.assertRaisesRegex(RuntimeError, "duplicate"):
                self.probe.config_fields(config)

    def test_probe_main_isolated_output_omits_raw_provider_and_config_secrets(self):
        home = Path.home().resolve()
        with tempfile.TemporaryDirectory(dir=home) as directory:
            root = Path(directory).resolve()
            install = root / "install"
            release = install / "catalog-release"
            release.mkdir(parents=True)
            binary = install / "macprovider-cli"
            binary.write_bytes(b"fixture-binary")
            policy = {
                "release_id": "release-fixture",
                "entries": [{
                    "model_key": "fixture-model",
                    "tuple_sha256": "a" * 64,
                    "max_served_slots": 8,
                }],
            }
            (release / "continuous-batching-policy.json").write_text(json.dumps(policy))
            config = root / "config.yaml"
            config.write_text(
                "api_key: config-secret\nmax_concurrency_override: 4\n"
                "max_concurrency_source: owner\ncontinuous_batch_queue_limit: 8\n"
            )
            journal = root / "journal.json"
            journal_payload = valid_probe_journal(config, root / "backup")
            journal_payload["secret"] = "journal-secret"
            journal.write_text(json.dumps(journal_payload))
            raw_provider = "provider-secret-identity"
            status = json.dumps({
                "provider_id": raw_provider,
                "binary_version": "3.0.2",
                "model": "fixture-model",
            }).encode()

            def fake_run(args, **_kwargs):
                if args[0] == "codesign":
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
                "--model",
                "fixture-model",
            ]
            output = io.StringIO()
            with mock.patch.object(sys, "argv", argv), mock.patch.object(
                self.probe.subprocess, "run", side_effect=fake_run
            ), contextlib.redirect_stdout(output):
                self.assertEqual(self.probe.main(), 0)

            encoded = output.getvalue()
            result = json.loads(encoded)
            self.assertNotIn("config-secret", encoded)
            self.assertNotIn("journal-secret", encoded)
            self.assertNotIn(raw_provider, encoded)
            self.assertEqual(result["status"]["provider_id_sha256"], self.probe.digest(raw_provider.encode()))
            self.assertEqual(result["installed"]["cdhash"], "abcdef")

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
                "--model",
                "fixture-model",
            ],
            cwd=ROOT,
            text=True,
            capture_output=True,
        )
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("under HOME", result.stderr)


if __name__ == "__main__":
    unittest.main()
