"""Offline acceptance regressions; no provider or model is contacted."""

import contextlib
import copy
import importlib.util
import io
import json
import tempfile
import unittest
from pathlib import Path
from types import SimpleNamespace
from unittest.mock import patch


SCRIPT = Path(__file__).resolve().parents[1] / "lab/cb-studio/glm53_coldmiss_sweep.py"
SPEC = importlib.util.spec_from_file_location("glm53_coldmiss_sweep", SCRIPT)
tool = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(tool)


class AfterAcceptanceTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        self.records = []
        for length, turns, rows in (
            (8192, 30, "1"), (8192, 0, "4"), (8192, 30, "4"),
            (32768, 30, "1"), (32768, 30, "4"), (32768, 30, "4j"),
        ):
            for mode in ("split", "warm", "plain"):
                for row in range(4 if rows == "4" else 1):
                    self.records.append({
                        "L": length, "T": turns, "rows": rows, "rep": 0,
                        "mode": mode, "row": row,
                        "request_id": f"L{length}-T{turns}-R{rows}-{mode}-{row}",
                        "usage": {"prompt_tokens": length,
                                  "cached_prompt_tokens": length - 100 if mode == "warm" else 0},
                        "error": None, "finish_reason": "length",
                        "ttft_s": 1.0, "wall_s": 1.5,
                    })

    def analyze(self, records, traces=True):
        runs, log = self.root / "runs.jsonl", self.root / "serve.log"
        runs.write_text("".join(json.dumps(r) + "\n" for r in records))
        log.write_text("".join(
            f"cbtrace t=0 rid={r['request_id']} ev=sch_submit\n"
            f"cbtrace t=1000 rid={r['request_id']} ev=sch_active\n"
            for r in records) if traces else "")
        output = io.StringIO()
        with contextlib.redirect_stdout(output):
            code = tool.cmd_analyze(SimpleNamespace(runs=runs, serve_log=log, leg="after"))
        return code, json.loads(output.getvalue())

    def test_complete_after_matrix_passes(self):
        code, report = self.analyze(self.records)
        self.assertEqual(code, 0)
        self.assertTrue(report["passed"])
        self.assertEqual(len(report["cells"]), 6)

    def test_partial_matrix_and_duplicate_rows_fail(self):
        cases = {
            "missing_cell": [r for r in self.records if r["rows"] != "4j"],
            "missing_mode": [r for r in self.records if r["mode"] != "plain"],
            "missing_row": self.records[:-2] + self.records[-1:],
            "duplicate_row": self.records + [copy.deepcopy(self.records[0])],
            "warm_only": [r for r in self.records if r["mode"] == "warm"][:1],
        }
        for label, records in cases.items():
            with self.subTest(label=label):
                code, report = self.analyze(records)
                self.assertNotEqual(code, 0)
                self.assertFalse(report["passed"])

    def test_failed_or_unmeasured_request_fails(self):
        for field, value in (("error", "stream failed"), ("ttft_s", None),
                             ("ttft_s", float("nan")), ("finish_reason", None)):
            with self.subTest(field=field, value=value):
                records = copy.deepcopy(self.records)
                warm = next(r for r in records if r["mode"] == "warm")
                warm[field] = value
                code, report = self.analyze(records)
                self.assertNotEqual(code, 0)
                self.assertFalse(report["passed"])

    def test_missing_server_timing_fails(self):
        code, report = self.analyze(self.records, traces=False)
        self.assertNotEqual(code, 0)
        self.assertFalse(report["passed"])

    def test_deadline_skipping_part_of_leg_is_not_success(self):
        calibration = self.root / "calibration.json"
        calibration.write_text('{"passed": true}')
        args = SimpleNamespace(calibration=calibration, out=self.root / "out.jsonl",
                               leg="after", deadline_unix=1000, prefill_rate=270)
        with patch.object(tool, "run_cell") as run, \
                patch.object(tool.time, "time", side_effect=[0, 0, 0, 1000, 1000, 1000, 1000, 1000]), \
                contextlib.redirect_stdout(io.StringIO()), contextlib.redirect_stderr(io.StringIO()):
            code = tool.cmd_run(args)
        self.assertEqual(run.call_count, 1)
        self.assertNotEqual(code, 0)

    def test_runner_rejects_failed_cell_and_accepts_complete_leg(self):
        calibration = self.root / "calibration.json"
        calibration.write_text('{"passed": true}')
        args = SimpleNamespace(calibration=calibration, out=self.root / "out.jsonl",
                               leg="after", deadline_unix=1e12, prefill_rate=270)
        for result, expected in ((True, 0), (False, 1)):
            with self.subTest(result=result), patch.object(tool, "run_cell", return_value=result), \
                    contextlib.redirect_stdout(io.StringIO()), contextlib.redirect_stderr(io.StringIO()):
                self.assertEqual(tool.cmd_run(args), expected)


if __name__ == "__main__":
    unittest.main()
