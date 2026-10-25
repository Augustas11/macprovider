import importlib.util
import tempfile
import unittest
import xml.etree.ElementTree as ET
from pathlib import Path
from types import SimpleNamespace
from unittest.mock import patch


PATH = Path(__file__).resolve().parents[1] / "ci-swift-test-shard.py"
SPEC = importlib.util.spec_from_file_location("ci_swift_test_shard", PATH)
M = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(M)


def write_xunit(path, tests, failing=()):
    root = ET.Element("testsuites")
    suite = ET.SubElement(root, "testsuite", name="selected")
    for identifier in tests:
        classname, name = identifier.split("/", 1)
        case = ET.SubElement(suite, "testcase", classname=classname, name=name)
        if identifier in failing:
            ET.SubElement(case, "failure", message="fixture failure")
    ET.ElementTree(root).write(path, encoding="utf-8", xml_declaration=True)


class SwiftTestShardTests(unittest.TestCase):
    receipt = "macprovider_cliTests.ReceiptPerfTests/testReceiptConstructionP95IsUnderFiveMillisecondsFor1024TokenPayload"
    alpha = "macprovider_cliTests.AlphaTests/testAlpha"

    def test_receipt_perf_is_run_serially_and_merged_once(self):
        with tempfile.TemporaryDirectory() as directory:
            output = str(Path(directory) / "shard.xml")
            commands = []

            def fake_run(command):
                commands.append(command)
                path = command[command.index("--xunit-output") + 1]
                if "ReceiptPerfTests" not in command[command.index("--filter") + 1]:
                    self.assertIn("--parallel", command)
                    self.assertNotIn("--num-workers", command)
                    self.assertNotIn("ReceiptPerfTests", command[command.index("--filter") + 1])
                    write_xunit(path, [self.alpha])
                else:
                    self.assertIn("--parallel", command)
                    self.assertEqual(command[command.index("--num-workers") + 1], "1")
                    self.assertIn("ReceiptPerfTests", command[command.index("--filter") + 1])
                    write_xunit(path, [self.receipt])
                return SimpleNamespace(returncode=0)

            with patch.object(M.subprocess, "run", side_effect=fake_run):
                self.assertEqual(M.run_shard([self.alpha, self.receipt], 1, 1, output), 0)

            self.assertEqual(len(commands), 2)
            self.assertIn("--parallel", commands[0])
            self.assertIn("--parallel", commands[1])
            self.assertNotIn("--num-workers", commands[0])
            self.assertEqual(commands[1][commands[1].index("--num-workers") + 1], "1")
            self.assertEqual(sorted(M.ran_tests(output)), sorted([self.alpha, self.receipt]))

    def test_non_owner_shard_never_runs_the_serial_class(self):
        tests = [self.alpha, self.receipt]
        _, shards = M.partition(tests, 2)
        receipt_owner = next(index + 1 for index, shard in enumerate(shards)
                             if "macprovider_cliTests.ReceiptPerfTests" in shard)
        other_shard = 1 if receipt_owner == 2 else 2

        with tempfile.TemporaryDirectory() as directory:
            output = str(Path(directory) / "shard.xml")

            def fake_run(command):
                self.assertIn("--parallel", command)
                self.assertNotIn("--num-workers", command)
                self.assertNotIn("ReceiptPerfTests", command[command.index("--filter") + 1])
                write_xunit(command[command.index("--xunit-output") + 1], [self.alpha])
                return SimpleNamespace(returncode=0)

            with patch.object(M.subprocess, "run", side_effect=fake_run) as run:
                self.assertEqual(M.run_shard(tests, other_shard, 2, output), 0)

            self.assertEqual(run.call_count, 1)
            self.assertEqual(M.ran_tests(output), [self.alpha])

    def test_missing_serial_case_is_rejected_by_exact_accounting(self):
        with tempfile.TemporaryDirectory() as directory:
            output = str(Path(directory) / "shard.xml")

            def fake_run(command):
                path = command[command.index("--xunit-output") + 1]
                is_receipt = "ReceiptPerfTests" in command[command.index("--filter") + 1]
                write_xunit(path, [] if is_receipt else [self.alpha])
                return SimpleNamespace(returncode=0)

            with patch.object(M.subprocess, "run", side_effect=fake_run):
                with self.assertRaises(SystemExit):
                    M.run_shard([self.alpha, self.receipt], 1, 1, output)

    def test_duplicate_serial_class_is_rejected_by_exact_accounting(self):
        with tempfile.TemporaryDirectory() as directory:
            output = str(Path(directory) / "shard.xml")

            def fake_run(command):
                path = command[command.index("--xunit-output") + 1]
                is_receipt = "ReceiptPerfTests" in command[command.index("--filter") + 1]
                tests = [self.receipt] if is_receipt else [self.alpha, self.receipt]
                write_xunit(path, tests)
                return SimpleNamespace(returncode=0)

            with patch.object(M.subprocess, "run", side_effect=fake_run):
                with self.assertRaises(SystemExit):
                    M.run_shard([self.alpha, self.receipt], 1, 1, output)

    def test_serial_failure_keeps_failure_case_in_merged_report(self):
        with tempfile.TemporaryDirectory() as directory:
            output = str(Path(directory) / "shard.xml")

            def fake_run(command):
                path = command[command.index("--xunit-output") + 1]
                if "ReceiptPerfTests" not in command[command.index("--filter") + 1]:
                    write_xunit(path, [self.alpha])
                    return SimpleNamespace(returncode=0)
                write_xunit(path, [self.receipt], failing=[self.receipt])
                return SimpleNamespace(returncode=17)

            with patch.object(M.subprocess, "run", side_effect=fake_run):
                self.assertEqual(M.run_shard([self.alpha, self.receipt], 1, 1, output), 17)

            self.assertEqual(sorted(M.ran_tests(output)), sorted([self.alpha, self.receipt]))
            receipt_case = next(case for case in ET.parse(output).getroot().iter("testcase")
                                if case.get("classname") == self.receipt.split("/", 1)[0])
            self.assertIsNotNone(receipt_case.find("failure"))

    def test_merged_report_preserves_every_case_for_exact_accounting(self):
        with tempfile.TemporaryDirectory() as directory:
            directory = Path(directory)
            parallel = directory / "parallel.xml"
            serial = directory / "serial.xml"
            merged = directory / "merged.xml"
            write_xunit(parallel, [self.alpha])
            write_xunit(serial, [self.receipt])

            M.merge_xunit([str(parallel), str(serial)], str(merged))

            self.assertEqual(sorted(M.ran_tests(merged)), sorted([self.alpha, self.receipt]))


if __name__ == "__main__":
    unittest.main()
