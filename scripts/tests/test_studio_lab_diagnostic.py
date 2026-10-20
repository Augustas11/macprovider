"""Small offline fixtures for the fixed diagnostic command (no MLX or SSH)."""

from pathlib import Path
import subprocess
import tempfile
import unittest


SCRIPT = Path(__file__).resolve().parents[1] / "lab/2080-native-rows/run-window-diagnostic.sh"


class DiagnosticTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.root = Path(self.tmp.name).resolve()
        self.bin = self.root / "bin"
        self.bin.mkdir()
        self.cli = self.root / "phase3-binary/.build/release/macprovider-cli"
        self.bench = self.root / "scripts/lab/cb-studio/glm53-bench/.build/release/GLMBench"
        for path in (self.cli, self.bench):
            path.parent.mkdir(parents=True)
        (self.root / ".lab-window/fixture/target").mkdir(parents=True)
        self.executable(self.bin / "uname", "printf 'Darwin\\n'\n")
        self.executable(self.bin / "sysctl", "printf 'Mac15,14\\n'\n")
        self.executable(self.cli, "printf '%s\\n' \"$@\"\n")
        self.executable(self.bench, "printf '%s\\n' \"$@\"\n")
        self.env = {"PATH": f"{self.bin}:/usr/bin:/bin", "HOME": str(self.root)}

    @staticmethod
    def executable(path, body):
        path.write_text("#!/bin/bash\nset -eu\n" + body)
        path.chmod(0o700)

    def run_script(self, *args):
        return subprocess.run(
            ["/bin/bash", str(SCRIPT), *args], cwd=self.root,
            env=self.env, text=True, capture_output=True, timeout=10,
        )

    def results(self):
        return list((self.root / ".lab-window").glob("result-*"))

    def test_refuses_missing_or_extra_arguments(self):
        for args in ((), ("--offline", "serve"), ("--command", "serve")):
            with self.subTest(args=args):
                self.assertEqual(self.run_script(*args).returncode, 2)
        self.assertEqual(self.results(), [])

    def test_wrong_hardware_does_not_run_either_binary(self):
        self.executable(self.bin / "sysctl", "printf 'Mac17,3\\n'\n")
        self.assertEqual(self.run_script("--offline").returncode, 3)
        self.assertEqual(self.results(), [])

    def test_missing_fixture_does_not_start_a_model(self):
        (self.root / ".lab-window/fixture/target").rmdir()
        self.assertEqual(self.run_script("--offline").returncode, 3)
        self.assertEqual(self.results(), [])

    def test_fixed_offline_commands_and_private_outputs(self):
        result = self.run_script("--offline")
        self.assertEqual(result.returncode, 0, result.stderr)
        outputs = self.results()
        self.assertEqual(len(outputs), 1)
        output = outputs[0]
        self.assertEqual(output.stat().st_mode & 0o777, 0o700)
        self.assertEqual((output / "journey.json").stat().st_mode & 0o777, 0o600)
        self.assertEqual((output / "journey.json").read_text().splitlines(), [
            "native-mtp-journey-e2e", "--root", str(self.root / ".lab-window/fixture"),
            "--model-id", "zai-org/glm-5.3-flash", "--qualified-slots", "4",
            "--max-native-active-rows", "4", "--max-prompt-tokens", "4096",
        ])
        self.assertEqual((output / "component-profile.log").read_text().splitlines(), [
            str(self.root / ".lab-window/fixture/target"),
            "--mtp-multirow-profile", "--mtp-multirow-reps", "1",
        ])
        self.assertIn("qualification=false", result.stdout)

    def test_failed_journey_prevents_component_profile(self):
        self.executable(self.cli, "exit 7\n")
        result = self.run_script("--offline")
        self.assertEqual(result.returncode, 7)
        self.assertFalse((self.results()[0] / "component-profile.log").exists())
        self.assertNotIn("diagnostic_completed", result.stdout)

    def test_failed_component_profile_is_not_completion(self):
        self.executable(self.bench, "exit 9\n")
        result = self.run_script("--offline")
        self.assertEqual(result.returncode, 9)
        self.assertNotIn("diagnostic_completed", result.stdout)


if __name__ == "__main__":
    unittest.main()
