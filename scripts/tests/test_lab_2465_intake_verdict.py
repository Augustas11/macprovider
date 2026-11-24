import importlib.util
import json
import pathlib
import tempfile
import unittest

ROOT = pathlib.Path(__file__).resolve().parents[2]
FIXTURE = ROOT / "scripts" / "tests" / "fixtures" / "lab-2465-parity"
spec = importlib.util.spec_from_file_location("intake_verdict", ROOT / "scripts" / "lab" / "2465" / "intake_verdict.py")
iv = importlib.util.module_from_spec(spec)
spec.loader.exec_module(iv)


class ParityCellTests(unittest.TestCase):
    def test_reads_nested_leftovers_parity_from_msb_throughput(self):
        # Real msb-throughput --scenario parity output from the 20261123T032428Z Studio window.
        for label in ("daisy", "qwen38"):
            cell = iv.parity_cell(str(FIXTURE), label)
            self.assertIs(cell["pass"], True, label)
            self.assertIs(cell["oneRowMatch"], True, label)

    def test_nested_failure_is_read_as_failure(self):
        doc = json.loads((FIXTURE / "parity" / "daisy.json").read_text())
        doc["leftovers"]["parity"]["pass"] = False
        with tempfile.TemporaryDirectory() as d:
            (pathlib.Path(d) / "parity").mkdir()
            (pathlib.Path(d) / "parity" / "daisy.json").write_text(json.dumps(doc))
            self.assertIs(iv.parity_cell(d, "daisy")["pass"], False)

    def test_missing_file_fails_the_gate(self):
        with tempfile.TemporaryDirectory() as d:
            self.assertIsNone(iv.parity_cell(d, "daisy"))


if __name__ == "__main__":
    unittest.main()
