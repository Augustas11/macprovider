"""#2467: the tie-aware uncensored parity gate, on synthetic safetensors oracles and reports."""

from __future__ import annotations

import importlib.util
import json
import struct
import tempfile
import unittest
from array import array
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
SPEC = importlib.util.spec_from_file_location(
    "parity_tie_gate", ROOT / "scripts" / "lab" / "2467" / "parity_tie_gate.py")
gate_mod = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(gate_mod)

STEPS, VOCAB, LENGTH = 6, 10, 1024
GREEDY = [1, 2, 3, 4, 5, 6]


def write_oracle(path: Path, margins: dict[int, float]) -> None:
    """Greedy token g at step i has logit 5.0; every other token 0.0 except token 9, which
    sits `margins[i]` below the top (so port token 9 at step i has that margin)."""
    rows = array("f")
    for i, g in enumerate(GREEDY):
        row = [0.0] * VOCAB
        row[g] = 5.0
        row[9] = 5.0 - margins.get(i, 3.0)
        rows.extend(row)
    greedy = array("i", GREEDY)
    header = {
        "greedy": {"dtype": "I32", "shape": [STEPS], "data_offsets": [0, greedy.itemsize * STEPS]},
        "logits": {"dtype": "F32", "shape": [STEPS, VOCAB],
                   "data_offsets": [greedy.itemsize * STEPS, greedy.itemsize * STEPS + 4 * STEPS * VOCAB]},
    }
    blob = json.dumps(header).encode()
    path.write_bytes(struct.pack("<Q", len(blob)) + blob + greedy.tobytes() + rows.tobytes())


def row(matching: int, mean_kl: float, **kw):
    return {"length": LENGTH, "steps": STEPS, "matchingTokens": matching, "meanKL": mean_kl,
            "path": "compiled", "layout": "oq", **kw}


def log_for(port: list[int]) -> str:
    fmt = lambda t: "[" + ", ".join(map(str, t)) + "]"
    return (f'/x/Inkling2ParityTests.swift:392: error: -[T test] : XCTAssertEqual failed: ("{fmt(port)}") '
            f'is not equal to ("{fmt(GREEDY)}") - greedy tokens at prompt length {LENGTH}\n')


class TieGateTests(unittest.TestCase):
    def run_gate(self, report, base, port=None, margins=None, extra_log=""):
        with tempfile.TemporaryDirectory() as d:
            d = Path(d)
            write_oracle(d / f"oracle-{LENGTH}.safetensors", margins or {})
            streams = gate_mod.log_streams((log_for(port) if port else "") + extra_log)
            return gate_mod.gate(report, base, streams, d, gate_mod.other_errors(extra_log))

    def test_exact_row_passes(self):
        [(line, ok)] = self.run_gate([row(6, 0.001)], [row(6, 0.001)])
        self.assertTrue(ok)
        self.assertIn(f"PARITY_GATE row={LENGTH} mismatches=0 worst_margin=0.0000 kl_ratio=1.000 PASS", line)

    def test_near_tie_mismatch_passes(self):
        port = [1, 2, 3, 9, 5, 6]
        [(line, ok)] = self.run_gate([row(5, 0.0009)], [row(6, 0.001)], port=port, margins={3: 0.033})
        self.assertTrue(ok, line)
        self.assertIn("mismatches=1 worst_margin=0.0330 kl_ratio=0.900 PASS", line)

    def test_margin_above_tie_fails(self):
        port = [1, 2, 3, 9, 5, 6]
        [(line, ok)] = self.run_gate([row(5, 0.001)], [row(6, 0.001)], port=port, margins={3: 0.5})
        self.assertFalse(ok)
        self.assertIn("worst_margin 0.5000 > 0.25", line)

    def test_third_mismatch_fails(self):
        port = [9, 9, 9, 4, 5, 6]
        [(line, ok)] = self.run_gate([row(3, 0.001)], [row(6, 0.001)], port=port,
                                     margins={0: 0.01, 1: 0.01, 2: 0.01})
        self.assertFalse(ok)
        self.assertIn("3 mismatches > 2", line)

    def test_two_mismatches_pass(self):
        port = [9, 2, 9, 4, 5, 6]
        [(line, ok)] = self.run_gate([row(4, 0.001)], [row(6, 0.001)], port=port, margins={0: 0.1, 2: 0.2})
        self.assertTrue(ok, line)

    def test_kl_ratio_above_limit_fails(self):
        [(line, ok)] = self.run_gate([row(6, 0.00126)], [row(6, 0.001)])
        self.assertFalse(ok)
        self.assertIn("kl_ratio 1.260 > 1.25", line)

    def test_kl_ratio_at_limit_passes(self):
        [(_, ok)] = self.run_gate([row(6, 0.00125)], [row(6, 0.001)])
        self.assertTrue(ok)

    def test_base_control_must_be_exact(self):
        [(line, ok)] = self.run_gate([row(6, 0.001)], [row(5, 0.001)])
        self.assertFalse(ok)
        self.assertIn("base control not exact 5/6", line)

    def test_mismatch_without_port_stream_fails(self):
        [(line, ok)] = self.run_gate([row(5, 0.001)], [row(6, 0.001)], port=None)
        self.assertFalse(ok)
        self.assertIn("margin unverifiable", line)

    def test_stream_disagreeing_with_report_fails(self):
        [(line, ok)] = self.run_gate([row(5, 0.001)], [row(6, 0.001)], port=[9, 9, 3, 4, 5, 6])
        self.assertFalse(ok)
        self.assertIn("margin unverifiable", line)

    def test_other_test_error_fails(self):
        extra = "/x/Other.swift:9: error: -[T testLevers] : XCTAssertTrue failed\n"
        [(line, ok)] = self.run_gate([row(6, 0.001)], [row(6, 0.001)], extra_log=extra)
        self.assertFalse(ok)
        self.assertIn("test errors", line)

    def test_wrong_path_fails(self):
        [(_, ok)] = self.run_gate([row(6, 0.001, path="eager")], [row(6, 0.001)])
        self.assertFalse(ok)

    def test_cli_exit_codes(self):
        with tempfile.TemporaryDirectory() as d:
            d = Path(d)
            write_oracle(d / f"oracle-{LENGTH}.safetensors", {3: 0.033})
            (d / "u.json").write_text(json.dumps([row(5, 0.0009)]))
            (d / "b.json").write_text(json.dumps([row(6, 0.001)]))
            (d / "u.log").write_text(log_for([1, 2, 3, 9, 5, 6]))
            args = ["--report", str(d / "u.json"), "--log", str(d / "u.log"), "--base-report", str(d / "b.json"),
                    "--oracle-dir", str(d), "--lengths", str(LENGTH)]
            self.assertEqual(gate_mod.main(args), 0)
            self.assertEqual(gate_mod.main(args[:-1] + ["8192"]), 1)


if __name__ == "__main__":
    unittest.main()
