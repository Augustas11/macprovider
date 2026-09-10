import importlib.util
import json
import tempfile
import unittest
from pathlib import Path

SCRIPT = Path(__file__).resolve().parents[1] / "validate-relay-blind-local-test-log.py"
SPEC = importlib.util.spec_from_file_location("relay_blind_log", SCRIPT)
MODULE = importlib.util.module_from_spec(SPEC)
assert SPEC.loader is not None
SPEC.loader.exec_module(MODULE)


class RelayBlindLocalJourneyLogTests(unittest.TestCase):
    def write_events(self, actions):
        directory = tempfile.TemporaryDirectory()
        path = Path(directory.name) / "test.jsonl"
        path.write_text("".join(json.dumps({"Test": name, "Action": action}) + "\n" for name, action in actions.items()))
        self.addCleanup(directory.cleanup)
        return path

    def test_accepts_only_complete_pass_set(self):
        path = self.write_events({name: "pass" for name in MODULE.REQUIRED_TESTS})
        self.assertEqual(MODULE.nonpassing_tests(path), {})

    def test_rejects_skipped_required_test(self):
        actions = {name: "pass" for name in MODULE.REQUIRED_TESTS}
        skipped = "TestRelayBlindSwiftProviderStreamEndToEnd"
        actions[skipped] = "skip"
        self.assertEqual(MODULE.nonpassing_tests(self.write_events(actions))[skipped], "skip")

    def test_rejects_missing_required_test(self):
        missing = "TestRelayBlindSwiftProviderNonstreamEndToEnd"
        actions = {name: "pass" for name in MODULE.REQUIRED_TESTS if name != missing}
        self.assertEqual(MODULE.nonpassing_tests(self.write_events(actions))[missing], "missing")


if __name__ == "__main__":
    unittest.main()
