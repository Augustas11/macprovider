import contextlib
import importlib.util
import io
import json
import os
import plistlib
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path
from unittest import mock


ROOT = Path(__file__).resolve().parents[2]
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
            compatibility = install / "compatibility-set.json"
            compatibility.write_text('{"schema_version":"fixture"}\n')
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
                "compatibility_set_id": "test/repo:v3.0.2@" + "a" * 40,
                "coordinator_origin": "wss://coordinator.example.test",
                "model": "fixture-model",
                "model_loaded": True,
                "network_state": "buyer_serving",
                "requests_in_flight": 0,
                "coordinator": {"connected": True},
                "lifecycle": {"operator_paused": False},
                "service_instance": {"pid": 4242},
            }).encode()
            launch_agents = root / "Library" / "LaunchAgents"
            launch_agents.mkdir(parents=True)
            watchdog = launch_agents / "tech.malibu.fixture-watchdog.plist"
            watchdog.write_bytes(b"fixture-watchdog-plist")

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
                "provider_plist_sha256": "a" * 64,
            })
            with mock.patch.object(sys, "argv", argv), mock.patch.object(
                self.probe.subprocess, "run", side_effect=fake_run
            ), mock.patch.object(
                self.probe,
                "launch_identity",
                launch_mock,
            ), mock.patch.object(
                self.probe.Path, "home", return_value=root
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
            self.assertEqual(result["snapshot"], {
                "binary_version": "3.0.2",
                "compatibility_set_id": "test/repo:v3.0.2@" + "a" * 40,
                "compatibility_set_sha256": self.probe.digest(compatibility.read_bytes()),
                "config_sha256": self.probe.digest(config.read_bytes()),
                "coordinator_connected": True,
                "coordinator_origin": "wss://coordinator.example.test",
                "executable_path": str(binary),
                "model": "fixture-model",
                "model_loaded": True,
                "network_state": "buyer_serving",
                "operator_paused": False,
                "pid": 4242,
                "process_start_us": 1800000123456789,
                "provider_id_sha256": self.probe.digest(raw_provider.encode()),
                "provider_plist_sha256": "a" * 64,
                "requests_in_flight": 0,
                "watchdog_plist_sha256": self.probe.digest(watchdog.read_bytes()),
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
            self.assertEqual(identity, {
                **process,
                "provider_plist_sha256": self.probe.digest(plist.read_bytes()),
            })

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
