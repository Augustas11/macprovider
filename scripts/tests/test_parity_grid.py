"""Offline checks for the parity-grid measurement check (scripts/lab/parity-grid)."""
import contextlib
import importlib.util
import io
import json
import os
import shutil
import tempfile
import threading
import unittest
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path

HARNESS = Path(__file__).resolve().parents[1] / "lab" / "parity-grid"


def module(name):
    spec = importlib.util.spec_from_file_location(f"parity_grid_{name}", HARNESS / f"{name}.py")
    result = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(result)
    return result


compare = module("compare")
prompts = module("prompts")
client = module("provider_client")
margin = module("margin")
cb_margin = module("cb_margin")
reference_mlxlm = module("reference_mlxlm")
JOB_QWEN4_CB = Path(__file__).resolve().parents[1] / "lab" / "ablit-perf" / "job-qwen4-cb.sh"

MODEL = "m"
TEXT = "The keeper lit the lamp."


def ref_line(ctx, out, tps, trial=0, row=0, text=TEXT, tokens=None, prompt_tokens=244):
    return {"side": "reference", "kind": "row", "model": MODEL, "ctx_target": ctx, "max_tokens": out,
            "rows": 1, "row": row, "trial": trial, "decode_tps": tps, "request_tps": tps, "text": text,
            "completion_tokens": out if tokens is None else tokens, "prompt_tokens": prompt_tokens,
            "finish": "length"}


def our_lines(ctx, out, rows, trial_tps, texts=None, tokens=None, prompt_tokens=244, row_tps=None):
    """One trial per entry of trial_tps; each trial has `rows` row lines and one aggregate line.

    Every row starts together and finishes at the same time with request_tps = tps / rows,
    so a trial's aggregate tok/s (total tokens / wall time) is its entry of trial_tps.
    """
    lines = []
    for trial, agg in enumerate(trial_tps):
        base = {"side": "provider", "model": MODEL, "ctx_target": ctx, "max_tokens": out, "rows": rows,
                "trial": trial, "cell": prompts.cell_key(MODEL, ctx, out, rows)}
        for r in range(rows):
            lines.append({**base, "kind": "row", "row": r,
                          "decode_tps": row_tps if row_tps is not None else agg / rows,
                          "request_tps": agg / rows,
                          "text": (texts or {}).get(r, TEXT),
                          "completion_tokens": out if tokens is None else tokens,
                          "prompt_tokens": prompt_tokens, "error": None})
        lines.append({**base, "kind": "aggregate", "aggregate_tps": agg})
    return lines


def by_cell(summary):
    return {(c["ctx"], c["out"], c["rows"]): c for c in summary["cells"]}


class CompareTests(unittest.TestCase):
    def test_pass(self):
        ref = [ref_line(200, 128, t, i) for i, t in enumerate([126.0, 126.4, 125.8])]
        ours = our_lines(200, 128, 1, [127.0, 126.5, 127.2])
        s = compare.evaluate(ref, ours)
        self.assertTrue(s["pass"], s["failing"])
        cell = s["cells"][0]
        self.assertEqual(cell["text_gate"], "byte_identical")
        self.assertTrue(cell["ratio_ok"] and cell["tokens_ok"] and cell["slope_ok"])

    def test_within_noise_passes_but_beyond_fails(self):
        ref = [ref_line(200, 128, t, i) for i, t in enumerate([100.0, 100.0, 100.0])]
        self.assertTrue(compare.evaluate(ref, our_lines(200, 128, 1, [97.5, 97.6, 97.4]))["pass"])
        s = compare.evaluate(ref, our_lines(200, 128, 1, [96.0, 96.1, 95.9]))
        self.assertFalse(s["pass"])
        self.assertIn("slow", s["failing"][0]["reasons"][0])

    def test_noisy_trials_widen_band(self):
        ref = [ref_line(200, 128, t, i) for i, t in enumerate([100.0, 100.0, 100.0])]
        # ours spread (100-90)/95 = 10.5% widens the band past the 3% floor.
        s = compare.evaluate(ref, our_lines(200, 128, 1, [90.0, 95.0, 100.0]))
        self.assertTrue(s["pass"], s["failing"])

    def test_slow_cell(self):
        ref = [ref_line(200, 512, t, i) for i, t in enumerate([126.0, 126.2, 125.9])]
        s = compare.evaluate(ref, our_lines(200, 512, 1, [57.0, 56.8, 56.9]))
        cell = by_cell(s)[(200, 512, 1)]
        self.assertFalse(cell["ratio_ok"])
        self.assertFalse(s["pass"])
        self.assertAlmostEqual(cell["ratio"], 56.9 / 126.0, places=3)

    def test_fewer_tokens_fails(self):
        ref = [ref_line(200, 128, 126.0, i) for i in range(3)]
        s = compare.evaluate(ref, our_lines(200, 128, 1, [127.0] * 3, tokens=120))
        cell = s["cells"][0]
        self.assertFalse(cell["tokens_ok"])
        self.assertTrue(any("fewer tokens" in r for r in cell["reasons"]))

    def test_byte_mismatch_fails_with_offset(self):
        ref = [ref_line(200, 128, 126.0, i) for i in range(3)]
        bad = "The keeper lit the lantern."
        s = compare.evaluate(ref, our_lines(200, 128, 1, [127.0] * 3, texts={0: bad}))
        cell = s["cells"][0]
        self.assertFalse(s["pass"])
        self.assertEqual(cell["text_gate"], "fail")
        self.assertEqual(cell["first_text_diff"]["byte_offset"], len("The keeper lit the la"))

    def test_byte_mismatch_falls_back_to_token_count_with_reason(self):
        ref = [ref_line(200, 128, 126.0, i) for i in range(3)]
        ours = our_lines(200, 128, 1, [127.0] * 3, texts={0: "The keeper lit the lantern."})
        s = compare.evaluate(ref, ours, text_fallback_reason="kernel order differs")
        cell = s["cells"][0]
        self.assertTrue(s["pass"], s["failing"])
        self.assertEqual(cell["text_gate"], "fallback_token_count")
        self.assertTrue(any("kernel order differs" in n for n in cell["notes"]))
        # Token gate still applies under the fallback.
        ours = our_lines(200, 128, 1, [127.0] * 3, texts={0: "x"}, tokens=100)
        self.assertFalse(compare.evaluate(ref, ours, text_fallback_reason="r")["pass"])

    def test_first_diff_is_utf8_byte_offset(self):
        self.assertEqual(compare.first_diff("é-a", "é-b"), 3)
        self.assertIsNone(compare.first_diff("same", "same"))
        self.assertEqual(compare.first_diff("abc", "abcd"), 3)

    def test_prompt_tokens_mismatch_fails(self):
        ref = [ref_line(200, 128, 126.0, i) for i in range(3)]
        s = compare.evaluate(ref, our_lines(200, 128, 1, [127.0] * 3, prompt_tokens=250))
        self.assertFalse(s["pass"])

    def test_multi_row(self):
        ref = [ref_line(200, 128, 126.0, i) for i in range(3)]
        ref += [ref_line(200, 128, 125.0, 0, row=r, text=f"row {r} text") for r in (1, 2, 3)]
        texts = {0: TEXT, 1: "row 1 text", 2: "row 2 text", 3: "row 3 text"}
        ours = our_lines(200, 128, 1, [127.0] * 3) + our_lines(200, 128, 4, [300.0, 302.0, 301.0], texts=texts)
        s = compare.evaluate(ref, ours)
        self.assertTrue(s["pass"], s["failing"])
        cell = by_cell(s)[(200, 128, 4)]
        self.assertEqual(cell["ours_tps"], 301.0)
        self.assertEqual(set(cell["per_row_ratio"]), {"0", "1", "2", "3"})
        self.assertAlmostEqual(cell["per_row_ratio"]["1"], 75.25 / 125.0, places=3)

        # A row whose text drifts from its own single-row reference fails the cell.
        bad = {**texts, 2: "row 2 TEXT"}
        ours = our_lines(200, 128, 1, [127.0] * 3) + our_lines(200, 128, 4, [301.0] * 3, texts=bad)
        cell = by_cell(compare.evaluate(ref, ours))[(200, 128, 4)]
        self.assertFalse(cell["pass"])
        self.assertEqual(cell["first_text_diff"]["row"], 2)

        # Aggregate below single-row reference throughput fails the ratio check.
        ours = our_lines(200, 128, 1, [127.0] * 3) + our_lines(200, 128, 4, [100.0] * 3, texts=texts)
        self.assertFalse(by_cell(compare.evaluate(ref, ours))[(200, 128, 4)]["ratio_ok"])

    def test_multi_row_missing_row_reference_fails(self):
        ref = [ref_line(200, 128, 126.0, i) for i in range(3)]
        ours = our_lines(200, 128, 2, [200.0] * 3)
        cell = by_cell(compare.evaluate(ref, ours))[(200, 128, 2)]
        self.assertTrue(any("missing single-row reference" in r for r in cell["reasons"]))

    def test_missing_provider_cell_is_not_run_not_failure(self):
        ref = [ref_line(200, 128, 126.0, i) for i in range(3)] + [ref_line(200, 512, 126.0, i) for i in range(3)]
        s = compare.evaluate(ref, our_lines(200, 128, 1, [127.0] * 3))
        self.assertTrue(s["pass"], s["failing"])
        self.assertEqual([(n["ctx"], n["out"]) for n in s["not_run"]], [(200, 512)])
        self.assertNotIn((200, 512, 1), by_cell(s))
        self.assertIn("Not run (1, excluded from pass/fail): ctx200/out512", compare.markdown(s))

    def test_provider_cell_without_reference_fails(self):
        ref = [ref_line(200, 128, 126.0, i) for i in range(3)]
        s = compare.evaluate(ref, our_lines(200, 128, 1, [127.0] * 3) + our_lines(200, 512, 1, [127.0] * 3))
        self.assertFalse(s["pass"])
        self.assertIn("missing reference for prompt row 0", by_cell(s)[(200, 512, 1)]["reasons"])

    # Tie-aware text gate.
    BAD = "The keeper lit the lantern."  # first differing byte: len("The keeper lit the la")

    def _rec(self, steps, prefix=len("The keeper lit the la"), ctx=200, span=3, index=5):
        return {"ctx_target": ctx, "max_tokens": 128, "token_index": index, "margin": 0.0156,
                "margin_steps": steps, "common_prefix_bytes": prefix, "diff_span_bytes": span}

    def _tie_inputs(self, tokens=None, text_row0=None):
        ref = [ref_line(200, 128, 126.0, i) for i in range(3)]
        return ref, our_lines(200, 128, 1, [127.0] * 3, texts={0: text_row0 or self.BAD}, tokens=tokens)

    def test_tie_does_not_fail(self):
        ref, ours = self._tie_inputs()
        s = compare.evaluate(ref, ours, margins=[self._rec(1.0)])
        self.assertTrue(s["pass"], s["failing"])
        cell = s["cells"][0]
        self.assertEqual(cell["text_gate"], "tie")
        self.assertEqual(cell["tie_margin_steps"], 1.0)
        self.assertEqual(s["ties"], [{"cell": cell["cell"], "margin_steps": 1.0}])
        md = compare.markdown(s)
        self.assertIn("tie (margin 1 steps)", md)

    def test_tie_boundary_and_wide_margin(self):
        ref, ours = self._tie_inputs()
        self.assertTrue(compare.evaluate(ref, ours, margins=[self._rec(2.0)])["pass"])
        s = compare.evaluate(ref, ours, margins=[self._rec(2.5)])
        self.assertFalse(s["pass"])
        self.assertEqual(s["cells"][0]["text_gate"], "fail")
        self.assertTrue(compare.evaluate(ref, ours, margins=[self._rec(2.5)], tie_steps=3)["pass"])

    def test_no_margins_or_no_record_stays_fail(self):
        ref, ours = self._tie_inputs()
        self.assertFalse(compare.evaluate(ref, ours)["pass"])
        self.assertFalse(compare.evaluate(ref, ours, margins=[self._rec(0.0, ctx=4000)])["pass"])
        # Offset outside the record's window: a different divergence.
        self.assertFalse(compare.evaluate(ref, ours, margins=[self._rec(0.0, prefix=5)])["pass"])

    def test_tie_covers_token_count_difference(self):
        ref, ours = self._tie_inputs(tokens=100)
        s = compare.evaluate(ref, ours, margins=[self._rec(0.0)])
        cell = s["cells"][0]
        self.assertTrue(s["pass"], s["failing"])
        self.assertTrue(cell["tokens_ok"])
        self.assertTrue(any("not gated" in n for n in cell["notes"]))
        # Without a covering tie the same count difference fails.
        self.assertFalse(compare.evaluate(ref, ours)["cells"][0]["tokens_ok"])
        # Identical text with a short count still fails the token gate.
        ours = our_lines(200, 128, 1, [127.0] * 3, tokens=100)
        self.assertFalse(compare.evaluate(ref, ours, margins=[self._rec(0.0)])["cells"][0]["tokens_ok"])

    def test_one_record_covers_longer_cells_with_same_prefix(self):
        ref, ours = [], []
        for out in (128, 512):
            ref += [ref_line(200, out, 126.0, i) for i in range(3)]
            ours += our_lines(200, out, 1, [127.0] * 3, texts={0: self.BAD})
        s = compare.evaluate(ref, ours, margins=[self._rec(1.0)])
        self.assertTrue(s["pass"], s["failing"])
        self.assertEqual([c["text_gate"] for c in s["cells"]], ["tie", "tie"])

    def test_tie_does_not_cover_other_rows(self):
        ref = [ref_line(200, 128, 126.0, i) for i in range(3)]
        ref += [ref_line(200, 128, 125.0, 0, row=1, text="row 1 text")]
        ours = our_lines(200, 128, 2, [250.0] * 3, texts={0: TEXT, 1: "row 1 TEXT"})
        s = compare.evaluate(ref, ours, margins=[self._rec(0.0, prefix=len("row 1 "))])
        self.assertFalse(s["pass"])

    def test_margins_cli_flags(self):
        import contextlib
        import io
        import tempfile
        ref, ours = self._tie_inputs()
        with tempfile.TemporaryDirectory() as d:
            refp, oursp, mp, js = (Path(d, n) for n in ("r.jsonl", "o.jsonl", "m.json", "s.json"))
            refp.write_text("".join(json.dumps(x) + "\n" for x in ref))
            oursp.write_text("".join(json.dumps(x) + "\n" for x in ours))
            mp.write_text(json.dumps({"records": [self._rec(1.5)]}))
            base = ["--ref", str(refp), "--ours", str(oursp), "--json", str(js)]
            with contextlib.redirect_stdout(io.StringIO()):
                self.assertEqual(compare.main(base), 1)
                self.assertEqual(compare.main(base + ["--margins", str(mp)]), 0)
                self.assertEqual(compare.main(base + ["--margins", str(mp), "--tie-steps", "1"]), 1)
            with contextlib.redirect_stdout(io.StringIO()):
                compare.main(base + ["--margins", str(mp)])
            self.assertEqual(json.loads(js.read_text())["ties"][0]["margin_steps"], 1.5)

    # Reasoning-only streams.
    def test_reasoning_only_text_not_comparable(self):
        ref = [ref_line(200, 128, 126.0, i) for i in range(3)]
        ours = our_lines(200, 128, 1, [127.0] * 3, texts={0: ""})
        for r in ours:
            if r["kind"] == "row":
                r["reasoning_text"] = "thinking..."
        s = compare.evaluate(ref, ours)
        cell = s["cells"][0]
        self.assertTrue(s["pass"], s["failing"])
        self.assertEqual(cell["text_gate"], "not_comparable")
        self.assertIn("reasoning_content", cell["text_reason"])
        self.assertTrue(cell["ratio_ok"])
        # Empty text without reasoning is still a mismatch.
        self.assertFalse(compare.evaluate(ref, our_lines(200, 128, 1, [127.0] * 3, texts={0: ""}))["pass"])

    def test_falling_slope(self):
        ref = []
        ours = []
        for out, tps in ((128, 130.0), (512, 120.0), (2048, 100.0)):
            ref += [ref_line(200, out, 126.0, i) for i in range(3)]
            ours += our_lines(200, out, 1, [tps] * 3)
        s = compare.evaluate(ref, ours, floor=0.03)
        cells = by_cell(s)
        self.assertTrue(cells[(200, 128, 1)]["slope_ok"])
        self.assertFalse(cells[(200, 512, 1)]["slope_ok"])
        self.assertFalse(cells[(200, 2048, 1)]["slope_ok"])

    def test_slope_follows_reference_falloff(self):
        # Reference itself falls 10% with length; ours falling the same is not a slope failure.
        ref, ours = [], []
        for out, rt in ((128, 126.0), (4096, 113.4)):
            ref += [ref_line(200, out, rt, i) for i in range(3)]
            ours += our_lines(200, out, 1, [rt + 1.0] * 3)
        s = compare.evaluate(ref, ours)
        self.assertTrue(s["pass"], s["failing"])

    def _past_bug(self, shape):
        ref, ours = [], []
        flat = {128: [126.1, 125.8, 126.3], 512: [126.0, 125.6, 126.2], 1024: [125.9, 125.7, 126.1]}
        for out, tps in zip((128, 512, 1024), shape):
            ref += [ref_line(200, out, t, i) for i, t in enumerate(flat[out])]
            ours += our_lines(200, out, 1, [tps - 0.2, tps, tps + 0.2])
        return compare.evaluate(ref, ours, floor=0.03)

    def test_past_bug_shape_fails_slope(self):
        s = self._past_bug((83.4, 58.1, 37.7))
        cells = by_cell(s)
        self.assertFalse(s["pass"])
        self.assertFalse(cells[(200, 512, 1)]["slope_ok"])
        self.assertFalse(cells[(200, 1024, 1)]["slope_ok"])
        self.assertTrue(any(not x["ok"] for x in s["slopes"]))

    def test_fixed_shape_passes_slope_but_fails_ratio(self):
        s = self._past_bug((83.6, 82.2, 81.2))
        self.assertTrue(all(x["ok"] for x in s["slopes"]), s["slopes"])
        for cell in s["cells"]:
            self.assertTrue(cell["slope_ok"])
            self.assertFalse(cell["ratio_ok"])
        self.assertFalse(s["pass"])

    def test_cli_exit_codes_and_markdown(self):
        import contextlib
        import io
        import tempfile
        with tempfile.TemporaryDirectory() as d:
            refp, oursp, js = Path(d, "ref.jsonl"), Path(d, "ours.jsonl"), Path(d, "s.json")
            refp.write_text("".join(json.dumps(ref_line(200, 128, 126.0, i)) + "\n" for i in range(3)))
            oursp.write_text("".join(json.dumps(x) + "\n" for x in our_lines(200, 128, 1, [127.0] * 3)))
            buf = io.StringIO()
            with contextlib.redirect_stdout(buf):
                rc = compare.main(["--ref", str(refp), "--ours", str(oursp), "--json", str(js)])
            self.assertEqual(rc, 0)
            self.assertIn("| m | 200 | 128 | 1 |", buf.getvalue())
            self.assertTrue(json.loads(js.read_text())["pass"])
            oursp.write_text("".join(json.dumps(x) + "\n" for x in our_lines(200, 128, 1, [60.0] * 3)))
            with contextlib.redirect_stdout(io.StringIO()):
                rc = compare.main(["--ref", str(refp), "--ours", str(oursp), "--json", str(js)])
            self.assertEqual(rc, 1)


class RequestMetricAndBaselineTests(unittest.TestCase):
    @staticmethod
    def with_request(lines, req, ttft=1.0):
        for x in lines:
            if x["kind"] == "row":
                x["request_tps"], x["ttft_s"] = req, ttft
        return lines

    def test_request_metric_reported_not_gated(self):
        ref = [dict(ref_line(200, 128, 126.0, i), request_tps=100.0, ttft_s=0.3) for i in range(3)]
        ours = self.with_request(our_lines(200, 128, 1, [127.0] * 3), 50.0)
        s = compare.evaluate(ref, ours)
        cell = s["cells"][0]
        self.assertTrue(s["pass"], s["failing"])
        self.assertEqual((cell["ref_request_tps"], cell["ours_request_tps"], cell["request_ratio"]), (100.0, 50.0, 0.5))
        self.assertEqual((cell["ref_ttft_s"], cell["ours_ttft_s"]), (0.3, 1.0))
        self.assertEqual((cell["prompt_tokens"], cell["completion_tokens"]), (244, 128))
        self.assertIn("| 100.00 | 50.00 | 0.500 |", compare.markdown(s))

    def test_multi_row_goal_is_aggregate_not_a_sum(self):
        # Four rows that start together and all finish at 128 / 30 s: 4 * 128 tokens over that wall.
        ours = self.with_request(our_lines(200, 128, 4, [200.0] * 3), 30.0)
        cell = compare.evaluate([ref_line(200, 128, 126.0)], ours)["cells"][0]
        self.assertEqual(cell["tps_metric"], "aggregate_tps")
        self.assertEqual(cell["ours_goal_tps"], 120.0)
        self.assertEqual(cell["ours_tps"], 120.0)
        self.assertEqual(cell["ours_request_tps"], 30.0)  # per request, a secondary column
        self.assertEqual(cell["ref_tps"], 126.0)          # the reference's request tok/s
        # An aggregate line's old fields never feed the score.
        for x in ours:
            if x["kind"] == "aggregate":
                x["request_tps_sum"], x["aggregate_tps"] = 999.0, 999.0
        self.assertEqual(compare.evaluate([ref_line(200, 128, 126.0)], ours)["cells"][0]["ours_tps"], 120.0)

    def test_client_request_tps(self):
        res = {"text": "ab", "t_first": 2.0, "t_last": 4.0, "t0": 0.0, "t_end": 5.0,
               "usage": {"completion_tokens": 8, "macprovider_queue_ms": 1500}}
        rec = client.row_record(res, {}, cell_t0=0.0)
        self.assertEqual(rec["request_tps"], 2.0)
        self.assertEqual(rec["ttft_s"], 2.0)
        self.assertEqual((rec["start_offset_s"], rec["t_last_offset_s"], rec["queue_ms"]), (0.0, 4.0, 1500))
        later = dict(rec, start_offset_s=0.0, ttft_s=4.5, t_last_offset_s=6.5, request_tps=round(8 / 6.5, 3))
        agg = client.aggregate_record([dict(rec, _t_first=2.0, _t_last=4.0), dict(later, _t_first=4.5, _t_last=6.5)], {})
        # 16 tokens over 6.5 s from the common start; the second row decoded after the first.
        self.assertEqual(agg["aggregate_tps"], round(16 / 6.5, 3))
        self.assertEqual((agg["decode_overlap_rows"], agg["serial_service"]), (1, True))
        self.assertEqual(agg["queue_s_max"], 1.5)
        self.assertNotIn("request_tps_sum", agg)

    def test_baseline_identical_passes_and_reports_delta(self):
        base = self.with_request(our_lines(200, 128, 1, [100.0, 101.0, 99.0]), 50.0)
        cand = self.with_request(our_lines(200, 128, 1, [110.0] * 3), 55.0)
        s = compare.evaluate_baseline(base, cand)
        c = s["cells"][0]
        self.assertTrue(s["pass"], s["failing"])
        self.assertTrue(c["identical"])
        self.assertEqual(c["request_delta"], 0.1)
        self.assertAlmostEqual(c["base_noise"], 0.0)
        self.assertIn("+0.100", compare.markdown_baseline(s))

    def test_baseline_any_difference_fails(self):
        base = our_lines(200, 128, 1, [100.0] * 3)
        self.assertFalse(compare.evaluate_baseline(base, our_lines(200, 128, 1, [100.0] * 3, texts={0: "x"}))["pass"])
        self.assertFalse(compare.evaluate_baseline(base, our_lines(200, 128, 1, [100.0] * 3, tokens=127))["pass"])
        cand = our_lines(200, 128, 1, [100.0] * 3)
        cand[0]["reasoning_text"] = "hm"
        self.assertFalse(compare.evaluate_baseline(base, cand)["pass"])

    def test_baseline_missing_cells(self):
        base = our_lines(200, 128, 1, [100.0] * 3) + our_lines(200, 512, 1, [100.0] * 3)
        cand = our_lines(200, 128, 1, [100.0] * 3)
        self.assertFalse(compare.evaluate_baseline(base, cand)["pass"])
        s = compare.evaluate_baseline(base, cand, subset=True)
        self.assertTrue(s["pass"], s["failing"])
        self.assertEqual(s["not_run"], [{"ctx": 200, "out": 512, "rows": 1}])
        self.assertFalse(compare.evaluate_baseline(cand, base, subset=True)["pass"])

    def test_baseline_cli_exit_codes(self):
        import contextlib
        import io
        import tempfile
        with tempfile.TemporaryDirectory() as d:
            bp, cp = Path(d, "b.jsonl"), Path(d, "c.jsonl")
            bp.write_text("".join(json.dumps(x) + "\n" for x in our_lines(200, 128, 1, [100.0] * 3)))
            cp.write_text("".join(json.dumps(x) + "\n" for x in our_lines(200, 128, 1, [90.0] * 3)))
            with contextlib.redirect_stdout(io.StringIO()):
                self.assertEqual(compare.main(["--baseline", str(bp), "--ours", str(cp)]), 0)
            cp.write_text("".join(json.dumps(x) + "\n" for x in our_lines(200, 128, 1, [90.0] * 3, texts={0: "y"})))
            with contextlib.redirect_stdout(io.StringIO()):
                self.assertEqual(compare.main(["--baseline", str(bp), "--ours", str(cp)]), 1)


class MarginTests(unittest.TestCase):
    def test_spacing_by_binade(self):
        self.assertEqual(margin.spacing(20.0, "float16"), 0.015625)
        self.assertEqual(margin.spacing(31.99, "mlx.core.float16"), 0.015625)
        self.assertEqual(margin.spacing(32.0, "float16"), 0.03125)
        self.assertEqual(margin.spacing(-20.0, "float16"), 0.015625)
        self.assertEqual(margin.spacing(20.0, "bfloat16"), 0.125)
        self.assertEqual(margin.spacing(1.0, "bfloat16"), 2.0 ** -7)
        self.assertEqual(margin.spacing(20.0, "float32"), 2.0 ** -19)
        self.assertEqual(margin.spacing(0.0, "float16"), 2.0 ** -24)
        self.assertEqual(margin.spacing(1e-9, "float16"), 2.0 ** -24)
        with self.assertRaises(ValueError):
            margin.spacing(1.0, "int8")

    def test_first_token_diff(self):
        self.assertEqual(margin.first_token_diff([1, 2, 3], [1, 2, 4]), 2)
        self.assertEqual(margin.first_token_diff([1, 2, 3], [1, 2]), 2)

    def test_build_record(self):
        rec = margin.build_record(4000, 512, 7, 11, None, [11, 12, 13, 14, 15],
                                  [20.0, 19.96875, 18.0, 17.0, 16.0], "mlx.core.float16",
                                  common_prefix_bytes=30, diff_span_bytes=4)
        self.assertEqual(rec["dtype"], "float16")
        self.assertAlmostEqual(rec["margin"], 0.03125)
        self.assertAlmostEqual(rec["margin_steps"], 2.0)
        self.assertIsNone(rec["our_token"])
        self.assertEqual((rec["ctx_target"], rec["max_tokens"], rec["token_index"]), (4000, 512, 7))
        json.dumps(rec)
        bf = margin.build_record(200, 128, 1, 1, 2, [1, 2], [20.0, 19.875], "bfloat16")
        self.assertAlmostEqual(bf["margin_steps"], 1.0)


class CbMarginTests(unittest.TestCase):
    @staticmethod
    def cells():
        def row(i, text, error=None):
            return {"row": i, "text": text, "error": error, "equal_lone": False}
        return {
            "ctx": 200,
            "lone": [{"row": 0, "text": "aaa"}, {"row": 1, "text": "bbb"}, {"row": 2, "text": "ccc"}],
            "widths": [{"width": 2, "trial": 0, "rows": [row(0, "aaa"), row(1, "bbx")]},
                       {"width": 3, "trial": 1, "rows": [row(0, "aXa"), row(1, "bbb"), row(2, "", "boom")]}],
            "join": {"case": "join", "rows": [row(0, "aaa"), row(2, "ccd")]},
        }

    def test_selects_only_differing_rows_without_error(self):
        got = cb_margin.select_divergences(self.cells())
        self.assertEqual([(d["width"], d["trial"], d["row"]) for d in got],
                         [(2, 0, 1), (3, 1, 0), ("join", None, 2)])
        self.assertEqual((got[0]["lone_text"], got[0]["text"]), ("bbb", "bbx"))

    def test_lone_error_skips_row(self):
        c = self.cells()
        c["lone"][1]["error"] = "x"
        self.assertEqual([d["row"] for d in cb_margin.select_divergences(c)], [0, 2])

    def test_old_shape_without_texts_is_refused(self):
        old = {"lone": [{"row": 0, "tokens": 3}], "widths": []}
        with self.assertRaises(cb_margin.MissingTexts):
            cb_margin.select_divergences(old)
        c = self.cells()
        del c["widths"][0]["rows"][0]["text"]
        with self.assertRaises(cb_margin.MissingTexts):
            cb_margin.select_divergences(c)

    def test_dedup_key(self):
        self.assertEqual(cb_margin.dedup_key(1, 3, [5, 6, 7]), cb_margin.dedup_key(1, 3, (5, 6, 7)))
        self.assertNotEqual(cb_margin.dedup_key(1, 3, [5, 6, 7]), cb_margin.dedup_key(2, 3, [5, 6, 7]))
        self.assertNotEqual(cb_margin.dedup_key(1, 3, [5, 6, 7]), cb_margin.dedup_key(1, 3, [5, 6, 8]))
        hash(cb_margin.dedup_key(1, 3, [5, 6, 7]))

    def test_record_and_summary(self):
        div = {"width": 4, "trial": 0, "row": 1}
        rec = cb_margin.build_record(div, 200, 5, 11, 12, [11, 12], [20.0, 19.96875], "mlx.core.float16")
        self.assertAlmostEqual(rec["margin_steps"], 2.0)
        self.assertTrue(rec["both_in_top2"])
        far = cb_margin.build_record(div, 200, 5, 11, 99, [11, 12], [20.0, 19.0], "float16")
        self.assertFalse(far["both_in_top2"])
        json.dumps(far)
        s = cb_margin.summarize([rec, far], 3)
        self.assertEqual((s["differing_rows"], s["distinct_points"], s["within_2_steps"]), (3, 2, 1))
        self.assertAlmostEqual(s["max_margin_steps"], 64.0)


class PromptTests(unittest.TestCase):
    def test_deterministic(self):
        self.assertEqual(prompts.build_messages(4000, 3), prompts.build_messages(4000, 3))
        self.assertEqual(json.dumps(prompts.build_messages(200, 0)), json.dumps(prompts.build_messages(200, 0)))

    def test_distinct_rows_diverge_early(self):
        a = prompts.build_messages(4000, 0)[0]["content"]
        b = prompts.build_messages(4000, 1)[0]["content"]
        self.assertNotEqual(a, b)
        prefix = 0
        while a[prefix] == b[prefix]:
            prefix += 1
        self.assertLess(prefix, 16)

    def test_size_and_long_output_request(self):
        for ctx in (200, 4000, 16000):
            content = prompts.build_messages(ctx, 0)[0]["content"]
            self.assertEqual(len(content), int(ctx * prompts.CHARS_PER_TOKEN))
            self.assertIn("do not stop", content)

    def test_expand_cells_respects_max_context(self):
        grid = json.loads((HARNESS / "grid.json").read_text())
        cells = prompts.expand_cells(grid)
        self.assertEqual(len(cells), 3 * 4 * 2)
        small = prompts.expand_cells(grid, max_context=8000)
        self.assertNotIn(16000, {c[0] for c in small})
        self.assertNotIn((4000, 4096, 1), small)
        self.assertIn((4000, 2048, 1), small)


def batched_ref_lines(ctx, out, rows, trial_aggs, texts=None, tokens=None, prompt_tokens=244):
    """What reference_mlxlm.py --batched writes: per trial `rows` row lines and one aggregate line."""
    lines = []
    for trial, agg in enumerate(trial_aggs):
        base = {"side": "reference", "reference": "mlx-lm", "model": MODEL, "ctx_target": ctx, "max_tokens": out,
                "rows": rows, "trial": trial, "batched": True}
        for r in range(rows):
            lines.append({**base, "kind": "row", "row": r, "decode_tps": agg / rows, "request_tps": agg / rows,
                          "text": (texts or {}).get(r, TEXT), "completion_tokens": out if tokens is None else tokens,
                          "prompt_tokens": prompt_tokens, "finish": "length"})
        lines.append({**base, "kind": "aggregate", "aggregate_tps": agg})
    return lines


class BatchedReferenceTests(unittest.TestCase):
    def test_summarize_batch_aggregate_is_total_tokens_over_wall(self):
        rows = [
            {"prompt_tokens": 200, "tokens": 100, "t_first": 10.5, "t_last": 12.0, "finish": "length", "text": "a"},
            {"prompt_tokens": 201, "tokens": 50, "t_first": 11.0, "t_last": 14.0, "finish": "stop", "text": "b"},
        ]
        recs, agg = reference_mlxlm.summarize_batch(rows, 10.0)
        # (100 + 50) tokens over the 4 s from the common start to the last response.
        self.assertEqual(agg["aggregate_tps"], 37.5)
        self.assertEqual(agg["wall_s"], 4.0)
        self.assertEqual(agg["completion_tokens_sum"], 150)
        self.assertEqual(recs[0]["ttft_s"], 0.5)
        self.assertEqual(recs[1]["ttft_s"], 1.0)
        self.assertEqual(recs[0]["decode_tps"], round(99 / 1.5, 3))
        self.assertEqual(recs[0]["request_tps"], 50.0)
        self.assertEqual(recs[1]["t_last_offset_s"], 4.0)
        self.assertEqual(agg["ttft_s_max"], 1.0)

    def test_run_batch_drives_the_generator_and_drops_stop_tokens(self):
        import sys
        import types
        from dataclasses import dataclass

        @dataclass
        class Resp:
            uid: int
            token: int
            finish_reason: object = None

        steps = [[Resp(0, 1), Resp(1, 7)], [Resp(0, 2, "length"), Resp(1, 99, "stop")], []]
        made = {}

        class FakeGen:
            def __init__(self, model, **kwargs):
                made.update(kwargs)

            def insert(self, prompts, max_tokens):
                made["inserted"] = (prompts, max_tokens)
                return [10, 11]

            def next_generated(self):
                r = steps.pop(0)
                return [type(x)(x.uid + 10, x.token, x.finish_reason) for x in r]

            def close(self):
                made["closed"] = True

        class Tok:
            eos_token_ids = {99}

            def decode(self, ids):
                return "|".join(map(str, ids))

        fake = types.ModuleType("mlx_lm.generate")
        fake.BatchGenerator = FakeGen
        saved = {k: sys.modules.get(k) for k in ("mlx_lm", "mlx_lm.generate")}
        sys.modules["mlx_lm"], sys.modules["mlx_lm.generate"] = types.ModuleType("mlx_lm"), fake
        try:
            recs, agg = reference_mlxlm.run_batch(object(), Tok(), [[1, 2, 3], [4, 5]], 2, "greedy", 4)
        finally:
            for k, v in saved.items():
                if v is None:
                    sys.modules.pop(k, None)
                else:
                    sys.modules[k] = v
        self.assertEqual(made["completion_batch_size"], 2)
        self.assertEqual(made["prefill_batch_size"], 4)
        self.assertEqual(made["stop_tokens"], [[99]])
        self.assertEqual(made["inserted"], ([[1, 2, 3], [4, 5]], [2, 2]))
        self.assertTrue(made["closed"])
        self.assertEqual([r["text"] for r in recs], ["1|2", "7"])
        self.assertEqual([r["completion_tokens"] for r in recs], [2, 1])
        self.assertEqual([r["finish"] for r in recs], ["length", "stop"])
        self.assertEqual([r["prompt_tokens"] for r in recs], [3, 2])
        self.assertEqual(agg["completion_tokens_sum"], 3)

    def test_summarize_batch_is_the_providers_definition(self):
        # The same trial through compare.trial_metrics (the provider side) gives the same aggregate.
        rows = [{"prompt_tokens": 9, "tokens": n, "t_first": 1.0, "t_last": last, "finish": "length", "text": "x"}
                for n, last in ((64, 5.0), (64, 9.0), (32, 6.0))]
        recs, agg = reference_mlxlm.summarize_batch(rows, 0.0)
        trial = [{**r, "trial": 0, "row": i, "completion_tokens": r["completion_tokens"]} for i, r in enumerate(recs)]
        self.assertEqual(compare.trial_metrics(trial)["aggregate_tps"], agg["aggregate_tps"])

    def test_summarize_batch_empty_row_has_no_rates(self):
        rows = [{"prompt_tokens": 9, "tokens": 0, "t_first": None, "t_last": 2.0, "finish": "stop", "text": ""}]
        recs, agg = reference_mlxlm.summarize_batch(rows, 1.0)
        self.assertIsNone(recs[0]["ttft_s"])
        self.assertIsNone(recs[0]["request_tps"])
        self.assertIsNone(agg["aggregate_tps"])

    def test_batched_jobs_are_the_multi_row_cells_only(self):
        cells = [(200, 512, 1), (200, 512, 4), (4000, 512, 4), (4000, 512, 16), (200, 512, 16)]
        self.assertEqual(reference_mlxlm.batched_jobs(cells, 3),
                         [((200, 512, 4), 3), ((200, 512, 16), 3), ((4000, 512, 4), 3), ((4000, 512, 16), 3)])
        self.assertEqual(reference_mlxlm.batched_jobs([(200, 512, 1)], 3), [])

    def test_single_row_reference_ignores_batched_lines(self):
        ref = [ref_line(200, 128, 126.0, i) for i in range(3)] + batched_ref_lines(200, 128, 4, [300.0])
        self.assertEqual(sorted(k[3] for k in compare.index_reference(ref)), [0])
        rows, aggs = compare.index_batched_reference(ref)
        self.assertEqual(len(rows), 4)
        self.assertEqual(aggs[(MODEL, 200, 128, 4)][0]["aggregate_tps"], 300.0)

    def test_multi_row_cell_is_scored_against_the_batched_reference(self):
        texts = {0: TEXT, 1: "row 1 text", 2: "row 2 text", 3: "row 3 text"}
        ref = [ref_line(200, 128, 126.0, i) for i in range(3)]
        ref += batched_ref_lines(200, 128, 4, [310.0, 300.0, 305.0], texts=texts)
        ours = our_lines(200, 128, 1, [127.0] * 3) + our_lines(200, 128, 4, [330.0, 332.0, 331.0], texts=texts)
        s = compare.evaluate(ref, ours)
        self.assertTrue(s["pass"], s["failing"])
        cell = by_cell(s)[(200, 128, 4)]
        self.assertEqual(cell["reference"], "mlx-lm batched")
        self.assertEqual(cell["ref_tps"], 305.0)
        self.assertEqual(cell["ours_tps"], 331.0)
        self.assertAlmostEqual(cell["goal_ratio"], 331.0 / 305.0, places=3)
        self.assertEqual(by_cell(s)[(200, 128, 1)]["reference"], "single-row")
        # Slower than the batched reference's aggregate fails, though above the single-row reference.
        ours = our_lines(200, 128, 1, [127.0] * 3) + our_lines(200, 128, 4, [200.0] * 3, texts=texts)
        cell = by_cell(compare.evaluate(ref, ours))[(200, 128, 4)]
        self.assertFalse(cell["ratio_ok"])
        # Row texts and token counts come from the batched rows (no single-row reference for rows 1..3 here).
        ours = our_lines(200, 128, 4, [330.0] * 3, texts={**texts, 2: "row 2 TEXT"})
        cell = by_cell(compare.evaluate(ref, ours))[(200, 128, 4)]
        self.assertEqual(cell["first_text_diff"]["row"], 2)
        ours = our_lines(200, 128, 4, [330.0] * 3, texts=texts, tokens=100)
        self.assertFalse(by_cell(compare.evaluate(ref, ours))[(200, 128, 4)]["tokens_ok"])

    def test_markdown_labels_a_batched_cell(self):
        ref = batched_ref_lines(200, 128, 4, [300.0] * 3) + [ref_line(200, 128, 126.0, i) for i in range(3)]
        md = compare.markdown(compare.evaluate(ref, our_lines(200, 128, 4, [310.0] * 3)))
        self.assertIn("aggregate vs batched ref", md)


class Qwen4CbJobTests(unittest.TestCase):
    """job-qwen4-cb.sh with CB_JOB_CHECK=1: knob validation and the run-grid argv, nothing touched."""

    def run_job(self, **env):
        import subprocess
        e = {"PATH": os.environ["PATH"], "HOME": tempfile.gettempdir(), "CB_JOB_CHECK": "1", "RUN_ID": "20261118T000000Z", **env}
        r = subprocess.run(["bash", str(JOB_QWEN4_CB)], env=e, capture_output=True, text=True, timeout=30)
        return r.returncode, r.stdout

    def test_defaults_are_the_requested_grid(self):
        rc, out = self.run_job()
        self.assertEqual(rc, 0, out)
        argv = next(l for l in out.splitlines() if l.startswith("GRID_ARGS")).split()
        for want in (["--rows", "1,4,8,16"], ["--contexts", "200,4000"], ["--outputs", "512"], ["--trials", "3"],
                     ["--expect-route", "batched"], ["--cb", "auto"], ["--reference", "mlx-lm"],
                     ["--ref-arg", "--loader", "--ref-arg", "qwen4", "--ref-arg", "--batched"]):
            self.assertIn(" ".join(want), " ".join(argv))
        self.assertIn("--no-autotune-candidate", argv)
        self.assertNotIn("--prefill-batch-size", argv)
        self.assertNotIn("--seed-self-check", argv)
        self.assertIn("max_concurrency_override=16 max_concurrency_source=owner", out)
        # CB needs the allowlisted id and a verified model hash (else no requested tuple, no self-check).
        self.assertIn("--model-id latent-variable/qwen3.8-flash-next-heretic-2-oq4e-mtp", " ".join(argv))
        self.assertIn("--model-sha256", argv)
        self.assertIn("continuous_batching=canary accepted_tuple=computed", out)

    def test_model_sha_knob_reaches_the_argv(self):
        rc, out = self.run_job(QWEN4_SHA256="a" * 64)
        self.assertEqual(rc, 0, out)
        self.assertIn("--model-sha256 " + "a" * 64, out)

    def test_knobs_reach_the_argv(self):
        rc, out = self.run_job(CB_ROWS="1,2", CB_SLOTS="4", CONTEXTS="200", OUTPUTS="128,512", TRIALS="1",
                               REF_PREFILL_BATCH_SIZE="4", SEED_SELF_CHECK_RUN="20261117T010203Z")
        self.assertEqual(rc, 0, out)
        argv = " ".join(next(l for l in out.splitlines() if l.startswith("GRID_ARGS")).split())
        for want in ("--rows 1,2", "--outputs 128,512", "--trials 1", "--ref-arg --prefill-batch-size --ref-arg 4",
                     "--seed-self-check", "20261117T010203Z/qwen4-flash-next-cb/main/serve/cb-self-check.json"):
            self.assertIn(want, argv)
        self.assertIn("continuous_batch_queue_limit=4", out)

    def test_bad_knobs_are_refused_before_anything_runs(self):
        for env in ({"CB_ROWS": "1,,4"}, {"CB_ROWS": "0"}, {"CB_ROWS": "1,40"}, {"CB_ROWS": "a"},
                    {"CB_SLOTS": "8"}, {"CB_SLOTS": "0"}, {"CB_SLOTS": "33"}, {"TRIALS": "0"}, {"OUTPUTS": "x"},
                    {"CONTEXTS": "a/b"}, {"REF_PREFILL_BATCH_SIZE": "0"}, {"SEED_SELF_CHECK_RUN": "latest"},
                    {"QWEN4_SHA256": "ABC"}, {"QWEN4_SHA256": "A" * 64}, {"QWEN4_ID": "Latent/Qwen"}):
            rc, out = self.run_job(**env)
            self.assertEqual(rc, 64, (env, out))
            self.assertIn("BLOCKER:", out)
            self.assertIn("JOB_FAIL", out)


class Qwen4CbTupleTests(unittest.TestCase):
    """qwen4_cb_tuple.py: the provider's tuple fields for a snapshot with no signed CB entry."""

    def setUp(self):
        import importlib.util
        spec = importlib.util.spec_from_file_location("qwen4_cb_tuple", JOB_QWEN4_CB.parent / "qwen4_cb_tuple.py")
        self.m = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(self.m)
        self.dir = Path(tempfile.mkdtemp())
        self.addCleanup(shutil.rmtree, self.dir)

    def snapshot(self, tokenizer_config, template_file=None):
        (self.dir / "config.json").write_text(json.dumps({
            "model_type": "qwen4_exp", "architectures": ["Qwen4ExpForConditionalGeneration"],
            "text_config": {"num_experts": 512, "num_experts_per_tok": 10}}))
        (self.dir / "tokenizer_config.json").write_text(json.dumps(tokenizer_config))
        (self.dir / "tokenizer.json").write_text("{}")
        if template_file:
            (self.dir / template_file[0]).write_text(template_file[1])
        (self.dir / "mlx.metallib").write_bytes(b"lib")
        return self.m.build(self.dir, "latent-variable/x", "b" * 64, self.dir / "mlx.metallib", "apple-silicon:Apple M3 Ultra:ram-256gb")

    def test_fields_follow_the_provider_formulas(self):
        import hashlib
        cfg = {"chat_template": "{{ x }}"}
        t = self.snapshot(cfg)
        tok = (b"tokenizer_config.json\0" + json.dumps(cfg).encode() + b"tokenizer.json\0{}")
        self.assertEqual(t["tokenizer_sha256"], hashlib.sha256(tok).hexdigest())
        self.assertEqual(t["chat_template_sha256"], hashlib.sha256(b"chat_template\0{{ x }}").hexdigest())
        self.assertEqual(t["metallib_sha256"], hashlib.sha256(b"lib").hexdigest())
        self.assertTrue(t["requires_moe"])
        self.assertEqual((t["cache_class"], t["kv_dtype"], t["kernel_identifier"]),
                         ("mixed", "fp16", "macprovider_paged_kv_gather_v1"))
        self.assertTrue(t["cached_turns_accepted"])
        # A template file wins over the tokenizer_config string.
        t = self.snapshot(cfg, ("chat_template.jinja", "J"))
        self.assertEqual(t["chat_template_sha256"], hashlib.sha256(b"chat_template.jinja\0J").hexdigest())
        yaml = self.m.yaml_lines(t)
        self.assertTrue(yaml.startswith("continuous_batching: canary\ncontinuous_batching_accepted_tuples:\n  - {model_id: "))
        self.assertIn('hardware_class: "apple-silicon:Apple M3 Ultra:ram-256gb"', yaml)

    def test_moe_rule(self):
        self.assertFalse(self.m.requires_moe({"model_type": "llama", "num_experts": 1}))
        self.assertTrue(self.m.requires_moe({"model_type": "x_moe"}))
        self.assertFalse(self.m.requires_moe({"text_config": {"num_experts": True}}))

    def test_check_compares_the_runtime_identity_line(self):
        t = self.snapshot({})
        line = ("[paged-kv] runtime-identity model=latent-variable/x model_sha256=%s hardware_class=%s "
                "metallib_sha256=%s kernel_identifier=macprovider_paged_kv_gather_v1"
                % (t["model_sha256"], t["hardware_class"], t["metallib_sha256"]))
        self.assertEqual(self.m.check(t, "noise\n" + line + "\n"), [])
        self.assertIsNone(self.m.check(t, "no identity here\n"))
        diff = self.m.check(t, line.replace("ram-256gb", "ram-192gb"))
        self.assertEqual([d[0] for d in diff], ["hardware_class"])


class _FakeServer(BaseHTTPRequestHandler):
    tokens = ["The", " keeper", " lit", " the", " lamp", "."]
    requests = []

    def log_message(self, *args):
        pass

    def do_POST(self):
        body = json.loads(self.rfile.read(int(self.headers["Content-Length"])))
        type(self).requests.append(body)
        self.send_response(200)
        self.send_header("Content-Type", "text/event-stream")
        self.end_headers()
        n = min(body["max_tokens"], len(self.tokens))

        def send(obj):
            data = obj if isinstance(obj, str) else json.dumps(obj)
            self.wfile.write(f"data: {data}\n\n".encode())
            self.wfile.flush()

        self.wfile.write(b": keep-alive\n\n")
        send({"choices": [{"index": 0, "delta": {"role": "assistant"}, "finish_reason": None}]})
        for tok in self.tokens[:n]:
            send({"choices": [{"index": 0, "delta": {"content": tok}, "finish_reason": None}]})
        send({"choices": [{"index": 0, "delta": {}, "finish_reason": "length"}]})
        send({"choices": [], "usage": {"prompt_tokens": 244, "completion_tokens": n, "cached_prompt_tokens": 0,
                                       "macprovider_generated_completion_tokens": n,
                                       "macprovider_generation_ms": 10}})
        send("[DONE]")


class ClientTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.server = ThreadingHTTPServer(("127.0.0.1", 0), _FakeServer)
        cls.port = cls.server.server_address[1]
        cls.thread = threading.Thread(target=cls.server.serve_forever, daemon=True)
        cls.thread.start()

    @classmethod
    def tearDownClass(cls):
        cls.server.shutdown()
        cls.server.server_close()

    def setUp(self):
        _FakeServer.requests.clear()

    def test_sse_parsing_unit(self):
        ticks = iter(range(100))
        lines = [b": ping\n", b"\n", b'data: {"choices":[{"delta":{"content":"a"}}]}\n',
                 b'data:{"choices":[{"delta":{"content":"b"},"finish_reason":"stop"}]}\n',
                 b'data: {"choices":[],"usage":{"completion_tokens":2}}\n', b"data: [DONE]\n",
                 b'data: {"choices":[{"delta":{"content":"after done"}}]}\n']
        res = client.consume_stream(lines, clock=lambda: next(ticks))
        self.assertEqual(res["text"], "ab")
        self.assertEqual(res["finish"], "stop")
        self.assertEqual(res["usage"], {"completion_tokens": 2})
        self.assertEqual((res["t_first"], res["t_last"]), (0, 1))

    def test_reasoning_deltas_are_timed_and_counted(self):
        ticks = iter(range(100))
        lines = [b'data: {"choices":[{"delta":{"reasoning_content":"a"}}]}\n',
                 b'data: {"choices":[{"delta":{"reasoning_content":"b"}}]}\n',
                 b'data: {"choices":[{"delta":{"content":"c"}}]}\n',
                 b'data: {"choices":[],"usage":{"prompt_tokens":5,"completion_tokens":9,'
                 b'"macprovider_generated_completion_tokens":3}}\n', b"data: [DONE]\n"]
        res = client.consume_stream(lines, clock=lambda: next(ticks))
        self.assertEqual((res["text"], res["reasoning_text"]), ("c", "ab"))
        self.assertEqual((res["t_first"], res["t_last"], res["chunks"]), (0, 2, 3))
        res["t0"], res["t_end"] = -1, 10
        rec = client.row_record(res, {})
        self.assertEqual(rec["completion_tokens"], 3)
        self.assertEqual(rec["decode_tps"], 1.0)
        self.assertEqual(rec["reasoning_text"], "ab")

    def test_reasoning_only_stream_records_speed(self):
        ticks = iter(range(100))
        lines = [b'data: {"choices":[{"delta":{"reasoning_content":"x"}}]}\n',
                 b'data: {"choices":[{"delta":{"reasoning_content":"y"}}]}\n',
                 b'data: {"choices":[],"usage":{"completion_tokens":2}}\n']
        res = client.consume_stream(lines, clock=lambda: next(ticks))
        res["t0"], res["t_end"] = -1, 5
        rec = client.row_record(res, {})
        self.assertEqual(rec["text"], "")
        self.assertEqual(rec["completion_tokens"], 2)
        self.assertEqual(rec["decode_tps"], 1.0)
        self.assertEqual(rec["ttft_s"], 1.0)

    def test_request_against_fake_server(self):
        msgs = prompts.build_messages(200, 0)
        res = client.run_request(self.port, "model-x", msgs, 6)
        self.assertIsNone(res["error"])
        self.assertEqual(res["text"], "The keeper lit the lamp.")
        self.assertEqual(res["usage"]["completion_tokens"], 6)
        body = _FakeServer.requests[0]
        self.assertEqual(body["messages"], msgs)
        self.assertEqual(body["temperature"], 0)
        self.assertTrue(body["stream"])
        self.assertEqual(body["stream_options"], {"include_usage": True})
        rec = client.row_record(res, {"kind": "row"})
        self.assertEqual(rec["completion_tokens"], 6)
        self.assertEqual(rec["prompt_tokens"], 244)
        self.assertIsNotNone(rec["decode_tps"])

    def test_concurrent_rows_use_distinct_prompts(self):
        records, agg = client.run_cell(self.port, "model-x", MODEL, 200, 4, 3, 0, True, "t")
        self.assertEqual([r["row"] for r in records], [0, 1, 2])
        contents = {b["messages"][0]["content"] for b in _FakeServer.requests}
        self.assertEqual(len(contents), 3)
        self.assertEqual(agg["kind"], "aggregate")
        self.assertEqual(agg["completion_tokens_sum"], 12)
        self.assertEqual(agg["errors"], [])
        self.assertTrue(all(r["text"] == "The keeper lit the" for r in records))
        self.assertEqual(records[0]["cell"], prompts.cell_key(MODEL, 200, 4, 3))

    def test_trials_by_rows_overrides_trials_for_that_row_count(self):
        with tempfile.TemporaryDirectory() as d:
            grid = os.path.join(d, "grid.json")
            with open(grid, "w") as f:
                json.dump({"outputs": [4], "contexts": [{"name": "short", "tokens": 200}], "rows": [1, 4],
                           "trials": 3, "warmup_tokens": 2}, f)
            out = os.path.join(d, "ours.jsonl")
            with contextlib.redirect_stderr(io.StringIO()):
                rc = client.main(["--port", str(self.port), "--model", "model-x", "--model-name", MODEL,
                                  "--out", out, "--grid", grid, "--trials-by-rows", "4=1"])
            self.assertEqual(rc, 0)
            with open(out) as f:
                aggs = [r for r in map(json.loads, f) if r["kind"] == "aggregate"]
        self.assertEqual(sorted((a["rows"], a["trial"]) for a in aggs),
                         [(1, 0), (1, 1), (1, 2), (4, 0)])

    def test_http_error_recorded(self):
        res = client.run_request(1, "model-x", prompts.build_messages(200, 0), 4, timeout=2)
        self.assertIn("error", res)
        self.assertIsNotNone(client.row_record(res, {})["error"])


class ReferenceFailedTests(unittest.TestCase):
    REASON = "ValueError: [concatenate] shapes (8192,768), (8192,1024) (rc=1)"

    def test_no_reference_rows_reports_every_provider_cell(self):
        ours = our_lines(200, 128, 1, [127.0] * 3) + our_lines(200, 128, 2, [200.0] * 3)
        s = compare.evaluate([], ours, reference_failed=self.REASON)
        self.assertEqual(s["reference_failed"], self.REASON)
        self.assertFalse(s["pass"])
        cells = by_cell(s)
        self.assertEqual(set(cells), {(200, 128, 1), (200, 128, 2)})
        for c in cells.values():
            self.assertEqual(c["text_gate"], "no_reference")
            self.assertIsNone(c["ref_tps"])
            self.assertIsNotNone(c["ours_tps"])
        md = compare.markdown(s)
        self.assertTrue(md.startswith("REFERENCE FAILED: " + self.REASON))
        self.assertIn("| m | 200 | 128 | 1 | - | decode | - | 127.00 |", md)

    def test_partial_reference_still_compares_what_it_wrote(self):
        ref = [ref_line(200, 128, 126.0, i) for i in range(3)]
        ours = our_lines(200, 128, 1, [127.0] * 3) + our_lines(200, 512, 1, [127.0] * 3)
        cells = by_cell(compare.evaluate(ref, ours, reference_failed=self.REASON))
        self.assertTrue(cells[(200, 128, 1)]["pass"])
        self.assertEqual(cells[(200, 128, 1)]["text_gate"], "byte_identical")
        self.assertEqual(cells[(200, 512, 1)]["text_gate"], "no_reference")

    def test_passing_case_unchanged(self):
        s = compare.evaluate([ref_line(200, 128, 126.0, i) for i in range(3)], our_lines(200, 128, 1, [127.0] * 3))
        self.assertIsNone(s["reference_failed"])
        self.assertFalse(compare.markdown(s).startswith("REFERENCE FAILED"))

    def test_cli_missing_reference_file(self):
        with tempfile.TemporaryDirectory() as d:
            refp, oursp, js = Path(d, "absent.jsonl"), Path(d, "ours.jsonl"), Path(d, "s.json")
            oursp.write_text("".join(json.dumps(x) + "\n" for x in our_lines(200, 128, 1, [127.0] * 3)))
            buf = io.StringIO()
            with contextlib.redirect_stdout(buf):
                rc = compare.main(["--ref", str(refp), "--ours", str(oursp), "--json", str(js),
                                   "--reference-failed", self.REASON])
            self.assertEqual(rc, 1)
            self.assertEqual(json.loads(js.read_text())["reference_failed"], self.REASON)
            self.assertIn("REFERENCE FAILED", buf.getvalue())
            # Without the flag an empty reference is still unusable input.
            refp.write_text("")
            with contextlib.redirect_stdout(io.StringIO()), contextlib.redirect_stderr(io.StringIO()):
                self.assertEqual(compare.main(["--ref", str(refp), "--ours", str(oursp)]), 2)

    def test_baseline_md_with_failed_reference(self):
        spec = importlib.util.spec_from_file_location(
            "ablit_baseline_md", HARNESS.parent / "ablit-perf" / "baseline_md.py")
        baseline_md = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(baseline_md)
        s = compare.evaluate([], our_lines(200, 128, 1, [127.0] * 3), reference_failed=self.REASON)
        with tempfile.TemporaryDirectory() as d:
            os.makedirs(os.path.join(d, "main"))
            with open(os.path.join(d, "main", "summary.json"), "w") as f:
                json.dump(s, f)
            with contextlib.redirect_stdout(io.StringIO()):
                self.assertEqual(baseline_md.main([d, "--model", "m"]), 0)
            md = Path(d, "baseline.md").read_text()
        self.assertIn("**Main reference FAILED**: `" + self.REASON + "`", md)
        self.assertIn("| ctx200/out128/rows1 | - | 244 | 128 | - | 127.00 | - | 127.00 | - | 127.00 | - |", md)
        self.assertIn("n/a (no reference)", md)


_FAKE_SERVE = r'''
import json, re, sys
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
cfg = open(sys.argv[sys.argv.index("--config") + 1]).read()
port = int(re.search(r"^port: (\d+)", cfg, re.M).group(1))
class H(BaseHTTPRequestHandler):
    def log_message(self, *a): pass
    def do_GET(self):
        self.send_response(200); self.end_headers(); self.wfile.write(b'{"model_loaded": true}')
    def do_POST(self):
        body = json.loads(self.rfile.read(int(self.headers["Content-Length"])))
        self.send_response(200); self.send_header("Content-Type", "text/event-stream"); self.end_headers()
        n = min(body["max_tokens"], 3)
        for obj in ([{"choices": [{"index": 0, "delta": {"content": "ab"}, "finish_reason": None}]}] * n
                    + [{"choices": [], "usage": {"prompt_tokens": 9, "completion_tokens": n}}]):
            self.wfile.write(("data: " + json.dumps(obj) + "\n\n").encode())
        self.wfile.write(b"data: [DONE]\n\n")
ThreadingHTTPServer(("127.0.0.1", port), H).serve_forever()
'''


class RunGridReferenceFailTests(unittest.TestCase):
    """run-grid.sh with a fake serve and a reference that dies at load."""

    def test_provider_cells_survive_a_failed_reference(self):
        import subprocess
        import socket
        with socket.socket() as s:
            s.bind(("127.0.0.1", 0))
            port = s.getsockname()[1]
        with tempfile.TemporaryDirectory() as d:
            d = Path(d)
            (d / "bin").mkdir()
            (d / "fake").mkdir()
            (d / "serve.py").write_text(_FAKE_SERVE)
            cli = d / "bin" / "macprovider-cli"
            cli.write_text(f'#!/bin/bash\nexec /usr/bin/python3 -I {d / "serve.py"} "$@"\n')
            # Nothing else may listen on 8080 on a lab Mac; the test must not depend on it.
            lsof = d / "fake" / "lsof"
            lsof.write_text("#!/bin/bash\nexit 1\n")
            ref_py = d / "fake" / "refpy"
            ref_py.write_text('#!/bin/bash\necho "Traceback (most recent call last):" >&2\n'
                              'echo "  File \\"x.py\\", line 1" >&2\n'
                              'echo "ValueError: [concatenate] shapes differ" >&2\nexit 1\n')
            for p in (cli, lsof, ref_py):
                p.chmod(0o755)
            out = d / "out"
            env = dict(os.environ, PATH=f"{d / 'fake'}:/usr/bin:/bin:/usr/sbin")
            proc = subprocess.run(
                ["bash", str(HARNESS / "run-grid.sh"), "--model-path", str(d), "--model-name", MODEL,
                 "--bin-dir", str(d / "bin"), "--out-dir", str(out), "--python", str(ref_py),
                 "--port", str(port), "--outputs", "4", "--contexts", "short", "--rows", "1", "--trials", "1"],
                env=env, capture_output=True, text=True, timeout=120)
            log = proc.stdout + proc.stderr
            self.assertEqual(proc.returncode, 8, log)
            self.assertIn(f"REFERENCE_FAIL {MODEL} ValueError: [concatenate] shapes differ (rc=1)", proc.stdout)
            self.assertLess(log.index("== provider"), log.index("== reference"))
            rows = [json.loads(x) for x in (out / "provider.jsonl").read_text().splitlines()]
            self.assertTrue(any(r["kind"] == "row" and r["completion_tokens"] == 3 for r in rows), rows)
            summary = json.loads((out / "summary.json").read_text())
            self.assertEqual(summary["reference_failed"],
                             "ValueError: [concatenate] shapes differ (rc=1)")
            self.assertEqual([c["text_gate"] for c in summary["cells"]], ["no_reference"])
            self.assertIn("REFERENCE FAILED", (out / "summary.md").read_text())


class Glm5NextShimTests(unittest.TestCase):
    """Pure parts of reference_mlxvlm's glm5_next loader shim (no mlx needed)."""

    @classmethod
    def setUpClass(cls):
        cls.ref = module("reference_mlxvlm")

    def test_quant_aliases(self):
        a = self.ref.glm5_quant_aliases
        L = "language_model.model.layers.20."
        H = "model.language_model.layers.20."
        self.assertEqual(a(L + "self_attn.o_proj"), (H + "self_attn.o_proj",))
        self.assertEqual(a(L + "self_attn.qkv_proj"), (H + "self_attn.q_proj",))
        self.assertEqual(a(L + "self_attn.qkv_proj.k_proj"), (H + "self_attn.k_proj",))
        self.assertEqual(a(L + "self_attn.fbg_a_proj"), (H + "self_attn.f_a_proj",))
        self.assertEqual(a(L + "self_attn.qkv_a_proj"), (H + "self_attn.q_a_proj",))
        self.assertEqual(a(L + "self_attn.embed_q"), (H + "self_attn.kv_b_proj",))
        self.assertEqual(a(L + "mlp.shared_experts.gate_up_proj"), (H + "mlp.shared_experts.gate_proj",))
        self.assertEqual(a(L + "mlp.switch_mlp.gate_proj"), (H + "mlp.switch_mlp.gate_proj",))
        self.assertEqual(a("language_model.model.embed_tokens"), ("model.language_model.embed_tokens",))
        self.assertEqual(a("language_model.lm_head"), ())
        self.assertEqual(a("vision_tower.blocks.0.attn.qkv"), ())

    def test_mixed_fusions_from_checkpoint_shapes(self):
        # Layer 20 of GLM-5.3-Flash-UNCENSORED-mlx-oQ4e-DFlash2: q/v 6-bit, k 8-bit (hidden 4096, group 64).
        shapes = {}
        for i, bits in ((19, (8, 8, 8)), (20, (6, 8, 6))):
            for p, b in zip(("q_proj", "k_proj", "v_proj"), bits):
                k = f"language_model.model.layers.{i}.self_attn.{p}"
                shapes[k + ".weight"], shapes[k + ".scales"], shapes[k + ".biases"] = \
                    (8192, 4096 * b // 32), (8192, 64), (8192, 64)
        # Same width, different mode: an mxfp8 part has no affine biases.
        for p in ("gate_proj", "up_proj"):
            k = f"language_model.model.layers.1.mlp.{p}"
            shapes[k + ".weight"], shapes[k + ".scales"] = (12288, 1024), (12288, 128)
        shapes["language_model.model.layers.1.mlp.gate_proj.biases"] = (12288, 128)
        got = self.ref.glm5_mixed_fusions(shapes, 45)
        self.assertEqual(got, [(1, "mlp", "gate_up_proj", ("gate_proj", "up_proj")),
                               (20, "self_attn", "qkv_proj", ("q_proj", "k_proj", "v_proj"))])


sanity = module("sanity")
omlx = module("reference_omlx")

PROSE = ("The keeper climbed the tower stairs before dawn, trimmed the wick and wrote the weather "
         "into the log while the supply boat rounded the northern point. ")
# Shapes of the garbage stock mlx-vlm 0.7.11 decoded on GLM-5.3-Flash DFlash2 (2026-11-17 window).
GARBAGE_SHORT = "y\n\n,\n\n\n\nw\n\n#, a\n\nworktexty1y4\n\nn\n\ntext\n\n\n\n\n\nh\n\n\n\ntext\n\n\n\n"
GARBAGE_LONG = ", ````##k the````0 `,`,`````,`` `, ##`,```,``,```m`,`,`, ```,`, ```, ```,`````,`"
CJK = "灯塔守护者在黎明前爬上楼梯，修剪灯芯，并把天气写进日志。"


def sane_row(ctx, text, cpt, row=0, out=128, reasoning=False, error=None):
    n = max(1, round(len(text) / cpt))
    return {"kind": "row", "model": MODEL, "ctx_target": ctx, "max_tokens": out, "row": row, "trial": 0,
            "completion_tokens": n, "text": "" if reasoning else text,
            "reasoning_text": text if reasoning else "", "error": error}


class SanityTests(unittest.TestCase):
    def test_signals_on_real_shapes(self):
        good = sanity.row_signals(PROSE * 4, round(len(PROSE * 4) / 4.3))
        self.assertEqual(good[3], [])
        short = sanity.row_signals(GARBAGE_SHORT * 6, round(len(GARBAGE_SHORT * 6) / 1.8))
        self.assertEqual(len(short[3]), 2, short)  # whitespace + chars/token
        long = sanity.row_signals(GARBAGE_LONG * 6, round(len(GARBAGE_LONG * 6) / 1.7))
        self.assertEqual(len(long[3]), 2, long)  # chars/token + words

    def test_one_signal_is_not_degenerate(self):
        # CJK prose has few characters per token but is words, not whitespace.
        r = sanity.check_reference([sane_row(200, CJK * 8, 1.2, row=i) for i in range(4)])
        self.assertFalse(r["suspect"], r)
        self.assertEqual(r["rows"][0]["signals"], ["chars/token 1.20 < 2.5"])

    def test_garbage_reference_is_suspect_and_good_ones_pass(self):
        bad = ([sane_row(200, GARBAGE_SHORT * 6, 1.8, row=i) for i in range(4)]
               + [sane_row(4000, GARBAGE_LONG * 6, 1.7, row=i) for i in range(4)])
        r = sanity.check_reference(bad)
        self.assertTrue(r["suspect"])
        self.assertIn("ctx200: 4/4 rows degenerate", r["reason"])
        self.assertIn("ctx4000: 4/4 rows degenerate", r["reason"])
        good = [sane_row(c, PROSE * 4, 4.3, row=i) for c in (200, 4000) for i in range(4)]
        self.assertFalse(sanity.check_reference(good)["suspect"])
        # Our GLM provider streams everything as reasoning_text with empty text.
        self.assertFalse(sanity.check_reference(
            [sane_row(200, PROSE * 4, 3.8, row=i, reasoning=True) for i in range(4)])["suspect"])

    def test_majority_rule_per_context_and_skips(self):
        rows = ([sane_row(200, GARBAGE_SHORT * 6, 1.8, row=0)]
                + [sane_row(200, PROSE * 4, 4.3, row=i) for i in (1, 2)]
                + [sane_row(200, GARBAGE_SHORT * 6, 1.8, row=3, error="http 500")]
                + [sane_row(200, "y\n\n", 1.0, row=4)])  # under MIN_TOKENS: not checked
        r = sanity.check_reference(rows)
        self.assertFalse(r["suspect"], r)
        self.assertEqual(r["contexts"], {"200": {"checked": 3, "degenerate": 1}})
        self.assertTrue(sanity.check_reference(rows[:1] + rows[3:])["suspect"])
        self.assertIn("no reference row", sanity.check_reference([{"kind": "meta"}])["reason"])

    def test_cli(self):
        with tempfile.TemporaryDirectory() as d:
            ref = Path(d, "ref.jsonl")
            ref.write_text("".join(json.dumps(x) + "\n" for x in
                                   [{"kind": "meta"}] + [sane_row(200, GARBAGE_SHORT * 6, 1.8, row=i) for i in range(2)]))
            buf = io.StringIO()
            with contextlib.redirect_stdout(buf):
                self.assertEqual(sanity.main(["--ref", str(ref), "--model-name", "glm", "--json", str(Path(d, "s.json"))]), 3)
            self.assertTrue(buf.getvalue().startswith("REFERENCE_SUSPECT glm ctx200: 2/2 rows degenerate"))
            self.assertTrue(json.loads(Path(d, "s.json").read_text())["suspect"])
            ref.write_text(json.dumps(sane_row(200, PROSE * 4, 4.3)) + "\n")
            with contextlib.redirect_stdout(io.StringIO()):
                self.assertEqual(sanity.main(["--ref", str(ref), "--model-name", "glm"]), 0)


class OmlxRecordTests(unittest.TestCase):
    def result(self):
        ticks = iter([0.0, 2.0, 2.5, 3.0, 3.05])
        lines = [b'data: {"choices":[{"delta":{"role":"assistant"}}]}\n',
                 b'data: {"choices":[{"delta":{"reasoning_content":"The"}}]}\n',
                 b'data: {"choices":[{"delta":{"reasoning_content":" user wants a"}}]}\n',
                 b'data: {"choices":[{"delta":{"reasoning_content":" story"},"finish_reason":"length"}]}\n',
                 b'data: {"choices":[],"usage":{"prompt_tokens":718,"completion_tokens":11,'
                 b'"prompt_tokens_details":{"cached_tokens":0},"completion_tokens_details":{"reasoning_tokens":11},'
                 b'"time_to_first_token":1.8,"time_to_first_visible_token":1.8,'
                 b'"generation_tokens_per_second":44.2}}\n', b"data: [DONE]\n"]
        res = client.consume_stream(lines, clock=lambda: next(ticks))
        res["t0"], res["t_end"] = 0.0, 3.1
        return res

    def test_mapping_uses_usage_not_chunk_counts(self):
        rec = omlx.omlx_record(self.result(), {"side": "reference", "reference": "omlx", "kind": "row"})
        self.assertEqual((rec["completion_tokens"], rec["prompt_tokens"], rec["chunks"]), (11, 718, 3))
        self.assertEqual(rec["decode_tps"], 10.0)        # (11 - 1) / (3.0 - 2.0)
        self.assertEqual(rec["ttft_s"], 2.0)
        self.assertEqual(rec["request_tps"], round(11 / 3.0, 3))
        self.assertEqual((rec["text"], rec["reasoning_text"]), ("", "The user wants a story"))
        self.assertEqual(rec["finish"], "length")
        self.assertEqual((rec["cached_prompt_tokens"], rec["reasoning_tokens"]), (0, 11))
        self.assertEqual((rec["omlx_server_ttft_s"], rec["omlx_server_visible_ttft_s"], rec["omlx_generation_tps"]),
                         (1.8, 1.8, 44.2))
        self.assertEqual(rec["tokens_per_chunk"], 3.67)
        for gone in ("generated_completion_tokens", "provider_generation_ms", "_t_first", "_t_last"):
            self.assertNotIn(gone, rec)
        self.assertIsNone(rec["error"])
        self.assertEqual(omlx.omlx_record(self.result(), {}, first_chunk_tokens=3)["decode_tps"], 8.0)

    def test_settings_helpers(self):
        doc = omlx.model_settings_doc("glm")
        self.assertEqual(omlx.settings_violations(doc, "glm"), [])
        doc["models"]["glm"]["mtp_enabled"] = True
        self.assertEqual(omlx.settings_violations(doc, "glm"), ["mtp_enabled=True"])
        self.assertEqual(omlx.settings_violations({"models": {}}, "glm"), ["model glm missing from model_settings.json"])
        self.assertEqual(omlx.model_id_of("glm53-flash-uncensored"), "glm53-flash-uncensored")
        self.assertEqual(omlx.model_id_of("zai-org/glm 5"), "zai-org-glm-5")
        self.assertEqual(omlx.missing_flags(" ".join(omlx.SERVE_FLAGS)), [])
        self.assertEqual(omlx.missing_flags("--port --host"), [f for f in omlx.SERVE_FLAGS if f not in ("--port", "--host")])
        self.assertEqual(omlx.health_state({"status": "healthy", "engine_pool": {"model_count": 1, "loaded_count": 0}}),
                         ("healthy", 1, 0))


_FAKE_OMLX = r"""
import json, os, sys, time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
here = os.path.dirname(os.path.abspath(__file__))
mode = open(os.path.join(here, "mode")).read().strip()
args = sys.argv[1:]
FLAGS = "--base-path --model-dir --host --port --headless --no-cache --no-hf-cache --memory-guard " \
        "--max-concurrent-requests --sse-keepalive-mode --log-level"
if args[:1] != ["serve"]:
    sys.exit(2)
if "--help" in args:
    print(FLAGS); sys.exit(0)
opt = lambda n: args[args.index(n) + 1]
port, models, base = int(opt("--port")), opt("--model-dir"), opt("--base-path")
if mode == "die":
    print("Traceback (most recent call last):\nRuntimeError: glm5_next weights do not load", flush=True)
    sys.exit(1)
if mode == "mtp":
    p = os.path.join(base, "model_settings.json"); d = json.load(open(p))
    for m in d["models"].values(): m["mtp_enabled"] = True
    json.dump(d, open(p, "w"))
ids = sorted(os.listdir(models))
class H(BaseHTTPRequestHandler):
    def log_message(self, *a): pass
    def reply(self, obj):
        b = json.dumps(obj).encode(); self.send_response(200); self.send_header("Content-Length", str(len(b)))
        self.end_headers(); self.wfile.write(b)
    def do_GET(self):
        if self.path == "/health":
            self.reply({"status": "healthy", "engine_pool": {"model_count": len(ids), "loaded_count": len(ids)}})
        elif self.path == "/v1/models":
            self.reply({"object": "list", "data": [{"id": i} for i in ids]})
        else:
            self.reply({"models": []})
    def do_POST(self):
        body = json.loads(self.rfile.read(int(self.headers["Content-Length"])))
        with open(os.path.join(here, "requests.jsonl"), "a") as f:
            f.write(json.dumps(body) + "\n")
        self.send_response(200); self.send_header("Content-Type", "text/event-stream"); self.end_headers()
        n = body["max_tokens"]
        def send(o):
            self.wfile.write(("data: " + (o if isinstance(o, str) else json.dumps(o)) + "\n\n").encode()); self.wfile.flush()
        send({"choices": [{"index": 0, "delta": {"role": "assistant"}}]})
        send({"choices": [{"index": 0, "delta": {"reasoning_content": "Lamp"}}]})  # first chunk: one token
        left = n - 1
        while left > 0:  # later chunks: bursts of three tokens
            k = min(3, left); left -= k; time.sleep(0.02)
            send({"choices": [{"index": 0, "delta": {"reasoning_content": " keeper" * k}}]})
        send({"choices": [{"index": 0, "delta": {}, "finish_reason": "length"}]})
        send({"choices": [], "usage": {"prompt_tokens": 50, "completion_tokens": n,
              "prompt_tokens_details": {"cached_tokens": 0}, "completion_tokens_details": {"reasoning_tokens": n},
              "time_to_first_token": 0.01, "time_to_first_visible_token": 0.01, "generation_tokens_per_second": 99.0}})
        send("[DONE]")
ThreadingHTTPServer(("127.0.0.1", port), H).serve_forever()
"""


def free_port():
    import socket
    with socket.socket() as s:
        s.bind(("127.0.0.1", 0))
        return s.getsockname()[1]


class OmlxServerLifecycleTests(unittest.TestCase):
    """reference_omlx.py against a fake oMLX install: start, ready, drive, stop, port closed."""
    SHA = "c74f1b18558842e6b10fcfa6e2e901bb382129d4"

    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        d = self.d = Path(self.tmp.name)
        venv = d / "omlx" / "omlx-venv" / "bin"
        venv.mkdir(parents=True)
        (d / "omlx" / "omlx-src").mkdir()
        (d / "omlx" / "omlx-src" / "OMLX_COMMIT").write_text(self.SHA + "\n")
        (venv / "fake_omlx.py").write_text(_FAKE_OMLX)
        (venv / "omlx").write_text(f'#!/bin/bash\nexec /usr/bin/python3 -I {venv / "fake_omlx.py"} "$@"\n')
        (venv / "python").write_text('#!/bin/bash\necho \'{"python": "3.12", "omlx": "0.8.0rc1", "mlx": "0.32.4", '
                                     '"mlx-lm": "0.32.3.dev8", "mlx-vlm": "0.7.11", "transformers": null, '
                                     '"lightning_mtp_supported": true}\'\n')
        for f in ("omlx", "python"):
            (venv / f).chmod(0o755)
        self.venv = venv
        (d / "model").mkdir()
        (d / "model" / "config.json").write_text('{"model_type": "glm5_next", "max_position_embeddings": 4096}')
        self.grid = d / "grid.json"
        self.grid.write_text(json.dumps({"outputs": [8], "contexts": [{"name": "short", "tokens": 200}],
                                         "rows": [1, 2], "trials": 2, "warmup_tokens": 2}))
        self.port = free_port()

    def tearDown(self):
        self.tmp.cleanup()

    def run_ref(self, mode):
        (self.venv / "mode").write_text(mode)
        out = self.d / "res" / "reference.jsonl"
        out.parent.mkdir(exist_ok=True)
        err = io.StringIO()
        with contextlib.redirect_stderr(err):
            rc = omlx.main(["--omlx-dir", str(self.d / "omlx"), "--model-path", str(self.d / "model"),
                            "--model-name", "glm53-flash-uncensored", "--out", str(out), "--grid", str(self.grid),
                            "--port", str(self.port), "--live-port", str(free_port()), "--load-timeout", "30",
                            "--poll-seconds", "0.2", "--state-root", str(self.d / "state"),
                            "--expect-commit", self.SHA])
        self.assertFalse(omlx.listening(self.port), "the oMLX port must be closed after the run")
        return rc, out, err.getvalue()

    def test_clean_run(self):
        rc, out, err = self.run_ref("ok")
        self.assertEqual(rc, 0, err)
        lines = [json.loads(x) for x in out.read_text().splitlines()]
        meta, rows = lines[0], lines[1:]
        self.assertEqual((meta["kind"], meta["reference"], meta["omlx_commit"], meta["omlx_version"]),
                         ("meta", "omlx", self.SHA, "0.8.0rc1"))
        self.assertFalse(meta["model_settings"]["mtp_enabled"])
        self.assertIn("(usage.completion_tokens - 1) / (t_last - t_first)", meta["decode_formula"])
        self.assertIn("--max-concurrent-requests", meta["serve_command"])
        # Prompt row 0 twice (trials), row 1 once (the 2-row cell), all single-row.
        self.assertEqual(sorted((r["row"], r["trial"]) for r in rows), [(0, 0), (0, 1), (1, 0)])
        for r in rows:
            self.assertEqual((r["side"], r["kind"], r["rows"], r["completion_tokens"], r["prompt_tokens"]),
                             ("reference", "row", 1, 8, 50))
            self.assertEqual(r["chunks"], 4)  # 1 + ceil(7 / 3)
            self.assertIsNone(r["error"])
            self.assertEqual(r["text"], "")
            self.assertTrue(r["reasoning_text"].startswith("Lamp keeper"))
            self.assertGreater(r["decode_tps"], 0)
        bodies = [json.loads(x) for x in (self.venv / "requests.jsonl").read_text().splitlines()]
        self.assertEqual(len(bodies), 4)  # warmup + 3
        for b in bodies:
            self.assertEqual(b["model"], "glm53-flash-uncensored")
            self.assertEqual((b["temperature"], b["top_p"], b["top_k"], b["repetition_penalty"]), (0, 1.0, 0, 1.0))
            self.assertNotIn("chat_template_kwargs", b)
        self.assertEqual(bodies[1]["messages"], prompts.build_messages(200, 0))
        self.assertEqual(list((self.d / "state").iterdir()), [], "a clean run removes its state dir")
        self.assertTrue((out.parent / "omlx-server.log").exists())
        eff = json.loads((out.parent / "omlx-effective" / "model_settings.after-load.json").read_text())
        self.assertFalse(eff["models"]["glm53-flash-uncensored"]["dflash_enabled"])

    def test_server_that_dies_fails_loudly(self):
        rc, out, err = self.run_ref("die")
        self.assertEqual(rc, 1)
        last = err.strip().splitlines()[-1]
        self.assertTrue(last.startswith("OmlxReferenceError: oMLX server exited during load (rc=1)"), err)
        self.assertIn("RuntimeError: glm5_next weights do not load", err)  # the log tail
        self.assertFalse(out.exists())

    def test_speculative_setting_turned_on_fails(self):
        rc, out, err = self.run_ref("mtp")
        self.assertEqual(rc, 1)
        self.assertIn("OmlxReferenceError: oMLX turned on what the reference needs off: mtp_enabled=True", err)

    def test_refuses_live_port(self):
        (self.venv / "mode").write_text("ok")
        with contextlib.redirect_stderr(io.StringIO()) as err:
            rc = omlx.main(["--omlx-dir", str(self.d / "omlx"), "--model-path", str(self.d / "model"),
                            "--model-name", "m", "--out", str(self.d / "r.jsonl"), "--port", "8080"])
        self.assertEqual(rc, 1)
        self.assertIn("8080", err.getvalue())


_FAKE_REF = r"""#!/bin/bash
# Stands in for "$PY reference_x.py --out FILE ...": writes reference rows of the kind in ./kind.
while [ $# -gt 0 ]; do [ "$1" = --out ] && out=$2; shift; done
exec /usr/bin/python3 -I - "$out" "$(cat "$(dirname "$0")/kind")" <<'PY'
import json, sys
out, kind = sys.argv[1:3]
prose = ("The keeper climbed the tower stairs before dawn, trimmed the wick and wrote the weather "
         "into the log while the supply boat rounded the northern point. ")
garbage = "y\n\n,\n\n\n\nw\n\n#, a\n\nworktexty1y4\n\nn\n\ntext\n\n\n\n\n\nh\n\n\n\ntext\n\n\n\n" * 2
text = prose if kind == "good" else garbage
with open(out, "a") as f:
    f.write(json.dumps({"side": "reference", "kind": "meta", "reference": "fake"}) + "\n")
    for t in range(3):
        f.write(json.dumps({"side": "reference", "kind": "row", "model": "m", "ctx_target": 200, "max_tokens": 64,
                            "rows": 1, "row": 0, "trial": t, "decode_tps": 50.0, "text": text,
                            "completion_tokens": 64, "prompt_tokens": 244, "finish": "length"}) + "\n")
PY
"""


route_status = module("route_status")


def timed_rows(ctx, out, rows, spans, trial=0, queue_ms=None):
    """Row lines from (start_offset_s, ttft_s, t_last_offset_s) per row, no texts."""
    lines = []
    for r, (start, ttft, last) in enumerate(spans):
        lines.append({"side": "provider", "model": MODEL, "ctx_target": ctx, "max_tokens": out, "rows": rows,
                      "trial": trial, "cell": prompts.cell_key(MODEL, ctx, out, rows), "kind": "row", "row": r,
                      "completion_tokens": out, "prompt_tokens": 244, "text": TEXT, "error": None,
                      "start_offset_s": start, "ttft_s": ttft, "t_last_offset_s": last,
                      "request_tps": round(out / (last - start), 3), "decode_tps": round((out - 1) / (last - start - ttft), 3),
                      "queue_ms": (queue_ms or [None] * len(spans))[r]})
    return lines


# One trial of a measured 4-row cell served one request at a time (GLM, ctx 200, out 512,
# the earlier lab serve): per row completion_tokens, request_tps, ttft_s and
# usage.macprovider_queue_ms, all rows released together. Its single-row request tok/s
# median was 39.231. Only these timing numbers are kept.
QUEUED_GLM_ROWS = [(512, 13.058, 27.3425, 26156), (512, 39.196, 1.1941, 7),
                   (512, 9.793, 40.4215, 39223), (512, 19.582, 14.2744, 13072)]


class AggregateMetricTests(unittest.TestCase):
    def queued_rows(self):
        return [{"side": "provider", "model": MODEL, "ctx_target": 200, "max_tokens": 512, "rows": 4,
                 "trial": 0, "cell": prompts.cell_key(MODEL, 200, 512, 4), "kind": "row", "row": r,
                 "completion_tokens": ct, "request_tps": req, "ttft_s": ttft, "error": None, "text": TEXT,
                 "prompt_tokens": 244, "decode_tps": 40.0, "usage": {"macprovider_queue_ms": q}}
                for r, (ct, req, ttft, q) in enumerate(QUEUED_GLM_ROWS)]

    def test_queued_rows_aggregate_to_one_row_and_are_serial(self):
        m = compare.trial_metrics(self.queued_rows())
        # The summed request tok/s of these rows reads ~2.1x one row; the aggregate does not.
        self.assertAlmostEqual(sum(r[1] for r in QUEUED_GLM_ROWS) / 39.231, 2.08, places=2)
        self.assertGreaterEqual(m["aggregate_tps"] / 39.231, 0.90)
        self.assertLessEqual(m["aggregate_tps"] / 39.231, 1.02)
        self.assertEqual((m["decode_overlap_rows"], m["serial_service"]), (1, True))
        self.assertEqual(m["queue_s_max"], 39.223)
        self.assertAlmostEqual(statistics_median(m["ttft_excl_queue_s"]), 1.19, places=1)

    def test_serial_cell_is_labelled(self):
        ref = [ref_line(200, 512, 40.0, 0, row=r, text=TEXT) for r in range(4)]
        s = compare.evaluate(ref, self.queued_rows())
        c = s["cells"][0]
        self.assertEqual(c["service"], "serial")
        self.assertTrue(any("serial service" in n for n in c["notes"]))
        self.assertIn("| SERIAL (queued) | aggregate vs ref request |", compare.markdown(s))

    def test_batched_rows(self):
        # Four rows decoding together after a staggered prefill: overlap 4, aggregate over the wall.
        lines = timed_rows(200, 128, 4, [(0.0, 1.0, 5.0), (0.0, 1.5, 5.2), (0.0, 2.0, 5.4), (0.0, 2.5, 5.6)])
        m = compare.trial_metrics(lines)
        self.assertEqual((m["decode_overlap_rows"], m["serial_service"]), (4, False))
        self.assertEqual(m["aggregate_tps"], round(4 * 128 / 5.6, 3))
        cell = compare.evaluate([ref_line(200, 128, 40.0, 0, row=r) for r in range(4)], lines)["cells"][0]
        self.assertEqual(cell["service"], "batched")
        self.assertEqual(compare.service_label(cell), "batched (4)")

    def test_start_offsets_count_from_the_first_request(self):
        lines = timed_rows(200, 128, 2, [(0.5, 1.0, 4.0), (0.0, 1.0, 3.0)])
        self.assertEqual(compare.trial_metrics(lines)["wall_s"], 4.0)

    def test_error_row_gives_no_aggregate(self):
        lines = timed_rows(200, 128, 2, [(0.0, 1.0, 4.0), (0.0, 1.0, 3.0)])
        lines[1]["error"] = "http 500"
        self.assertIsNone(compare.trial_metrics(lines)["aggregate_tps"])

    def test_one_row_queue_wait_is_visible(self):
        lines = our_lines(200, 128, 1, [127.0] * 3)
        lines[0]["queue_ms"], lines[0]["ttft_s"] = 30000, 31.0
        cell = compare.evaluate([ref_line(200, 128, 126.0, i) for i in range(3)], lines)["cells"][0]
        self.assertEqual(cell["ours_queue_s_max"], 30.0)
        self.assertEqual(cell["ours_ttft_excl_queue_s"], 1.0)
        self.assertEqual(cell["service"], None)

    def test_baseline_mode_uses_aggregate_for_multi_row(self):
        a = self.queued_rows()
        s = compare.evaluate_baseline(a, a)
        self.assertEqual(s["cells"][0]["base_request_tps"], compare.trial_metrics(a)["aggregate_tps"])


def statistics_median(xs):
    import statistics
    return statistics.median(xs)


def cb_status(decision=None, slots=1, active=False, served=None, route="stock_order", loaded=True):
    sc = None if decision is None else {"decision": decision, "served_slots": served if served is not None else slots,
                                       "verified_k": 4}
    return {"model_loaded": loaded, "capacity": {"max_concurrency": slots},
            "continuous_batching": {"mode": "canary" if active else "off", "active": active, "self_check": sc,
                                    "small_m_route": route, "scheduler": {"max_observed_batch_depth": 0},
                                    "policy": {"decision_reason": "absent_empty_off_fallback"}}}


PLANNED = "event=served_slots action=planned rows=22 served=1 reason=self_check_pending configured=4 source=autotune\n"
APPLIED = "event=served_slots action=applied slots=1 rows=22 reason=self_check_pending\n"


class RouteStatusTests(unittest.TestCase):
    def test_states(self):
        st = route_status.self_check_state
        self.assertEqual(st(cb_status(), PLANNED + APPLIED), ("pending", "self_check_pending"))
        self.assertEqual(st(cb_status("deferred"), PLANNED + APPLIED)[0], "pending")
        self.assertEqual(st(cb_status("prior_grant_pending_recheck", 3), PLANNED)[0], "pending")
        self.assertEqual(st(cb_status("granted", 3, True), PLANNED), ("decided", "granted"))
        self.assertEqual(st(cb_status("granted", 1, False, served=3), PLANNED)[0], "applying")
        self.assertEqual(st(cb_status("no_net_gain", 1), PLANNED), ("decided", "no_net_gain"))
        unavailable = PLANNED + "event=served_slots action=applied slots=1 rows=8 reason=cb_unavailable_for_loaded_tuple\n"
        self.assertEqual(st(cb_status(), unavailable), ("none", "cb_unavailable_for_loaded_tuple"))
        self.assertEqual(st(cb_status(route="serial_only"), PLANNED), ("none", "small_m_route_serial_only"))
        self.assertEqual(st(cb_status(), ""), ("none", "no_served_slots_plan"))

    def test_route_and_line(self):
        r = route_status.route(cb_status("granted", 3, True), PLANNED)
        self.assertEqual((r["batching"], r["slots"], r["reason"]), ("active", 3, "self_check_granted"))
        self.assertTrue(route_status.route_line(r, "start").startswith(
            "ROUTE batching=active slots=3 reason=self_check_granted phase=start"))
        r = route_status.route(cb_status(), PLANNED + APPLIED)
        self.assertEqual((r["batching"], r["reason"]), ("serial", "absent_empty_off_fallback"))
        unavailable = PLANNED + "event=served_slots action=applied slots=1 rows=8 reason=cb_unavailable_for_loaded_tuple\n"
        self.assertEqual(route_status.route(cb_status(), unavailable)["reason"], "cb_unavailable_for_loaded_tuple")

    def test_record_writes_grid_and_fails_a_serial_expected_batched_route(self):
        with tempfile.TemporaryDirectory() as d:
            st, err, grid = Path(d, "s.json"), Path(d, "serve.err"), Path(d, "grid.json")
            grid.write_text(json.dumps({"rows": [1, 4]}))
            err.write_text(PLANNED)
            st.write_text(json.dumps(cb_status("granted", 3, True)))
            out = []
            self.assertEqual(route_status.record(st, err, grid, "start", "batched", out=out.append), 0)
            st.write_text(json.dumps(cb_status("no_net_gain", 1)))
            self.assertEqual(route_status.record(st, err, grid, "end", "batched", out=out.append), 10)
            self.assertTrue(out[-1].startswith("ROUTE_FAIL phase=end"))
            g = json.loads(grid.read_text())
            self.assertEqual((g["rows"], g["route"]["start"]["batching"], g["route"]["end"]["batching"]),
                             ([1, 4], "active", "serial"))
            self.assertEqual(route_status.record(st, err, grid, "end", "any", out=out.append), 0)

    def gate(self, statuses, err=PLANNED + APPLIED, stall_s=60.0):
        now = [0.0]
        seq = iter(statuses)
        last = [None]

        def fetch(_port):
            last[0] = next(seq, last[0])
            return last[0]
        out = []
        with tempfile.TemporaryDirectory() as d:
            p = Path(d, "serve.err")
            p.write_text(err)
            rc = route_status.gate(1, str(p), None, stall_s, 10.0, fetch=fetch, clock=lambda: now[0],
                                   sleep=lambda s: now.__setitem__(0, now[0] + s), out=out.append)
        return rc, out, now[0]

    def test_gate_waits_for_the_verdict(self):
        rc, out, t = self.gate([cb_status()] * 3 + [cb_status("pending")] * 2 + [cb_status("granted", 3, True)])
        self.assertEqual(rc, 0)
        self.assertTrue(out[-1].startswith("CB_WARMUP_DONE state=decided reason=granted waited_s=50"), out)
        self.assertEqual(len([x for x in out if x.startswith("CB_WARMUP ")]), 2)  # one line per change

    def test_gate_stall_is_the_only_bound(self):
        rc, out, t = self.gate([cb_status("pending")], stall_s=60.0)
        self.assertEqual(rc, 4)
        self.assertTrue(out[-1].startswith("CB_WARMUP_STALL"), out)
        self.assertEqual(t, 60.0)

    def test_gate_ends_at_once_when_no_check_can_run(self):
        err = PLANNED + "event=served_slots action=applied slots=1 rows=8 reason=cb_unavailable_for_loaded_tuple\n"
        rc, out, t = self.gate([cb_status()], err=err)
        self.assertEqual((rc, t), (0, 0.0))
        self.assertIn("state=none reason=cb_unavailable_for_loaded_tuple", out[-1])

    def test_gate_applying_grace(self):
        rc, out, t = self.gate([cb_status("granted", 1, False, served=3)], stall_s=10000.0)
        self.assertEqual(rc, 0)
        self.assertEqual(t, route_status.APPLY_GRACE_S)


_FAKE_CB_SERVE = r"""
import json, os, re, sys, time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
cfg = open(sys.argv[sys.argv.index("--config") + 1]).read()
port = int(re.search(r"^port: (\d+)", cfg, re.M).group(1))
decision = os.environ["FAKE_DECISION"]
t0 = time.time()
sys.stderr.write("event=served_slots action=planned rows=22 served=1 reason=self_check_pending configured=4\n")
sys.stderr.write("event=served_slots action=applied slots=1 rows=22 reason=self_check_pending\n")
sys.stderr.flush()
COUNT = [0]
def decided():
    return time.time() - t0 > 1.5
class H(BaseHTTPRequestHandler):
    def log_message(self, *a): pass
    def do_GET(self):
        granted = decided() and decision == "granted"
        sc = {"decision": decision if decided() else "pending", "served_slots": 3 if granted else 1, "verified_k": 4}
        body = {"model_loaded": True, "capacity": {"max_concurrency": 3 if granted else 1},
                "continuous_batching": {"mode": "canary" if granted else "off", "active": granted,
                                        "self_check": sc, "small_m_route": "stock_order"}}
        if os.environ.get("FAKE_MTP"):
            on = os.environ["FAKE_MTP"] == "on"
            body["native_mtp"] = {"enabled": on, "mode": "eligible" if on else "off", "family": "f",
                                  "proposal_depth": 3, "proposed_tokens": COUNT[0] * 6,
                                  "accepted_tokens": COUNT[0] * 4, "mtp_forwards": COUNT[0] * 2,
                                  "reset_generation": 1, "last_reason": "active"}
        self.send_response(200); self.end_headers(); self.wfile.write(json.dumps(body).encode())
    def do_POST(self):
        COUNT[0] += 1
        body = json.loads(self.rfile.read(int(self.headers["Content-Length"])))
        if not decided():
            self.send_response(500); self.end_headers(); self.wfile.write(b"request before the verdict"); return
        self.send_response(200); self.send_header("Content-Type", "text/event-stream"); self.end_headers()
        n = min(body["max_tokens"], 3)
        for obj in ([{"choices": [{"index": 0, "delta": {"content": "ab"}, "finish_reason": None}]}] * n
                    + [{"choices": [], "usage": {"prompt_tokens": 9, "completion_tokens": n, "macprovider_queue_ms": 4}}]):
            self.wfile.write(("data: " + json.dumps(obj) + "\n\n").encode())
        self.wfile.write(b"data: [DONE]\n\n")
ThreadingHTTPServer(("127.0.0.1", port), H).serve_forever()
"""


class RunGridWarmupTests(unittest.TestCase):
    """run-grid.sh waits, idle, for the self-check verdict, then records the route."""

    def run_grid(self, decision, expect):
        import socket
        import subprocess
        with socket.socket() as s:
            s.bind(("127.0.0.1", 0))
            port = s.getsockname()[1]
        d = Path(tempfile.mkdtemp())
        self.addCleanup(lambda: __import__("shutil").rmtree(d, ignore_errors=True))
        (d / "bin").mkdir()
        (d / "fake").mkdir()
        (d / "serve.py").write_text(_FAKE_CB_SERVE)
        cli = d / "bin" / "macprovider-cli"
        cli.write_text(f'#!/bin/bash\nexec /usr/bin/python3 -I {d / "serve.py"} "$@"\n')
        lsof = d / "fake" / "lsof"
        lsof.write_text("#!/bin/bash\nexit 1\n")
        for p in (cli, lsof):
            p.chmod(0o755)
        out = d / "out"
        env = dict(os.environ, PATH=f"{d / 'fake'}:/usr/bin:/bin:/usr/sbin", FAKE_DECISION=decision)
        proc = subprocess.run(
            ["bash", str(HARNESS / "run-grid.sh"), "--model-path", str(d), "--model-name", MODEL,
             "--bin-dir", str(d / "bin"), "--out-dir", str(out), "--skip-reference", "--skip-compare",
             "--port", str(port), "--outputs", "4", "--contexts", "short", "--rows", "1", "--trials", "1",
             "--warmup-poll-s", "0.5", "--expect-route", expect],
            env=env, capture_output=True, text=True, timeout=120)
        return proc, out

    def test_granted_route_is_active_and_recorded(self):
        proc, out = self.run_grid("granted", "batched")
        log = proc.stdout + proc.stderr
        self.assertEqual(proc.returncode, 0, log)
        self.assertIn("CB_WARMUP_DONE state=decided reason=granted", proc.stdout)
        self.assertIn("ROUTE batching=active slots=3 reason=self_check_granted phase=start", proc.stdout)
        self.assertIn("ROUTE batching=active slots=3 reason=self_check_granted phase=end", proc.stdout)
        grid = json.loads((out / "grid.json").read_text())
        self.assertEqual((grid["route"]["start"]["batching"], grid["route"]["end"]["slots"]), ("active", 3))
        for name in ("status-ready.json", "status.json", "status-end.json"):
            self.assertTrue((out / "serve" / name).is_file(), name)
        rows = [json.loads(x) for x in (out / "provider.jsonl").read_text().splitlines()]
        self.assertTrue(all(not r.get("errors") for r in rows if r["kind"] == "aggregate"), rows)

    def test_serial_route_where_batching_is_expected_fails_loudly(self):
        proc, out = self.run_grid("no_net_gain", "batched")
        log = proc.stdout + proc.stderr
        self.assertEqual(proc.returncode, 10, log)
        self.assertIn("ROUTE_FAIL phase=start", proc.stdout)
        self.assertIn("ROUTE_FAIL phase=end", proc.stdout)
        self.assertTrue((out / "provider.jsonl").read_text())  # the cells were still measured


class RunGridNativeMtpTests(unittest.TestCase):
    """run-grid.sh --expect-native-mtp on: the serve's native_mtp status gates and is recorded."""

    def run_grid(self, mtp):
        import socket
        import subprocess
        with socket.socket() as s:
            s.bind(("127.0.0.1", 0))
            port = s.getsockname()[1]
        d = Path(tempfile.mkdtemp())
        self.addCleanup(lambda: __import__("shutil").rmtree(d, ignore_errors=True))
        (d / "bin").mkdir()
        (d / "fake").mkdir()
        (d / "serve.py").write_text(_FAKE_CB_SERVE)
        cli = d / "bin" / "macprovider-cli"
        cli.write_text(f'#!/bin/bash\nexec /usr/bin/python3 -I {d / "serve.py"} "$@"\n')
        lsof = d / "fake" / "lsof"
        lsof.write_text("#!/bin/bash\nexit 1\n")
        for p in (cli, lsof):
            p.chmod(0o755)
        out = d / "out"
        env = dict(os.environ, PATH=f"{d / 'fake'}:/usr/bin:/bin:/usr/sbin", FAKE_DECISION="granted", FAKE_MTP=mtp)
        proc = subprocess.run(
            ["bash", str(HARNESS / "run-grid.sh"), "--model-path", str(d), "--model-name", MODEL,
             "--bin-dir", str(d / "bin"), "--out-dir", str(out), "--skip-reference", "--skip-compare",
             "--port", str(port), "--outputs", "4", "--contexts", "short", "--rows", "1", "--trials", "2",
             "--warmup-poll-s", "0.5", "--expect-native-mtp", "on"],
            env=env, capture_output=True, text=True, timeout=120)
        return proc, out

    def test_native_mtp_on_records_acceptance_per_trial(self):
        proc, out = self.run_grid("on")
        self.assertEqual(proc.returncode, 0, proc.stdout + proc.stderr)
        self.assertIn("NATIVE_MTP phase=start enabled=True mode=eligible", proc.stdout)
        self.assertIn("NATIVE_MTP phase=end", proc.stdout)
        aggs = [json.loads(x) for x in (out / "provider.jsonl").read_text().splitlines()]
        aggs = [r for r in aggs if r["kind"] == "aggregate"]
        self.assertEqual(len(aggs), 2)
        for r in aggs:
            nm = r["native_mtp"]
            self.assertEqual((nm["proposed_tokens"], nm["accepted_tokens"], nm["acceptance"]), (6, 4, 0.6667))
        self.assertTrue(json.loads((out / "grid.json").read_text())["native_mtp"]["end"]["enabled"])

    def test_native_mtp_off_fails_with_11_before_any_cell(self):
        proc, out = self.run_grid("off")
        self.assertEqual(proc.returncode, 11, proc.stdout + proc.stderr)
        self.assertIn("NATIVE_MTP_FAIL phase=start", proc.stdout)
        self.assertFalse((out / "provider.jsonl").exists())


class RunGridReferenceOnlyTests(unittest.TestCase):
    """run-grid.sh --reference-only over a stored provider run, with the sanity gate."""

    def run_grid(self, kind):
        import subprocess
        tmp = tempfile.TemporaryDirectory()
        self.addCleanup(tmp.cleanup)
        d = Path(tmp.name)
        (d / "fake").mkdir()
        (d / "fake" / "lsof").write_text("#!/bin/bash\nexit 1\n")
        (d / "fake" / "refpy").write_text(_FAKE_REF)
        (d / "fake" / "kind").write_text(kind)
        for f in ("lsof", "refpy"):
            (d / "fake" / f).chmod(0o755)
        out = d / "out"
        out.mkdir()
        (out / "provider.jsonl").write_text("".join(
            json.dumps(x) + "\n" for x in our_lines(200, 64, 1, [52.0] * 3, texts={0: PROSE})))
        (out / "grid.json").write_text(json.dumps({"outputs": [64], "contexts": [{"name": "short", "tokens": 200}],
                                                   "rows": [1], "trials": 3, "warmup_tokens": 2}))
        env = dict(os.environ, PATH=f"{d / 'fake'}:/usr/bin:/bin:/usr/sbin")
        proc = subprocess.run(
            ["bash", str(HARNESS / "run-grid.sh"), "--reference-only", "--model-path", str(d), "--model-name", MODEL,
             "--out-dir", str(out), "--python", str(d / "fake" / "refpy"), "--rows", "1", "--trials", "3"],
            env=env, capture_output=True, text=True, timeout=120)
        return proc, out

    def test_suspect_reference_is_handled_as_failed(self):
        proc, out = self.run_grid("garbage")
        log = proc.stdout + proc.stderr
        self.assertEqual(proc.returncode, 9, log)
        self.assertIn("== provider skipped (--reference-only)", proc.stdout)
        self.assertIn(f"REFERENCE_SUSPECT {MODEL} ctx200: 3/3 rows degenerate", proc.stdout)
        self.assertFalse((out / "reference.jsonl").exists())
        self.assertTrue((out / "reference.suspect.jsonl").exists())
        summary = json.loads((out / "summary.json").read_text())
        self.assertTrue(summary["reference_failed"].startswith(f"REFERENCE_SUSPECT {MODEL} ctx200"))
        self.assertEqual([c["text_gate"] for c in summary["cells"]], ["no_reference"])
        self.assertIsNotNone(summary["cells"][0]["ours_tps"])
        self.assertIn("REFERENCE FAILED: REFERENCE_SUSPECT", (out / "summary.md").read_text())

    def test_sane_reference_compares_stored_provider_cells(self):
        proc, out = self.run_grid("good")
        log = proc.stdout + proc.stderr
        self.assertEqual(proc.returncode, 0, log)
        self.assertIn(f"REFERENCE_SANE {MODEL} ctx200=0/3", proc.stdout)
        summary = json.loads((out / "summary.json").read_text())
        self.assertIsNone(summary["reference_failed"])
        self.assertEqual(summary["cells"][0]["ref_tps"], 50.0)
        self.assertEqual(summary["cells"][0]["text_gate"], "byte_identical")

    def test_reference_only_refuses_without_provider_run(self):
        import subprocess
        with tempfile.TemporaryDirectory() as d:
            proc = subprocess.run(["bash", str(HARNESS / "run-grid.sh"), "--reference-only", "--model-path", d,
                                   "--model-name", MODEL, "--out-dir", d, "--python", "/usr/bin/true"],
                                  capture_output=True, text=True, timeout=60)
        self.assertEqual(proc.returncode, 64)
        self.assertIn("needs a provider run", proc.stderr)


class BaselineMdReferenceNoteTests(unittest.TestCase):
    def test_omlx_meta_names_reference_and_formula(self):
        spec = importlib.util.spec_from_file_location(
            "ablit_baseline_md2", HARNESS.parent / "ablit-perf" / "baseline_md.py")
        baseline_md = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(baseline_md)
        s = compare.evaluate([ref_line(200, 128, 30.0, i) for i in range(3)], our_lines(200, 128, 1, [42.0] * 3))
        with tempfile.TemporaryDirectory() as d:
            os.makedirs(os.path.join(d, "main"))
            Path(d, "main", "summary.json").write_text(json.dumps(s))
            Path(d, "main", "reference.jsonl").write_text(json.dumps({
                "kind": "meta", "reference": "omlx", "omlx_version": "0.8.0rc1", "omlx_commit": "c74f1b1",
                "versions": {"mlx": "0.32.4", "mlx-vlm": "0.7.11"}, "table_note": omlx.table_note(1)}) + "\n")
            with contextlib.redirect_stdout(io.StringIO()):
                self.assertEqual(baseline_md.main([d, "--model", "m"]), 0)
            md = Path(d, "baseline.md").read_text()
        self.assertIn("Reference: oMLX 0.8.0rc1 commit `c74f1b1` (mlx 0.32.4, mlx-vlm 0.7.11).", md)
        self.assertIn("our provider's = (completion_tokens - 1) / (last token - first token)", md)


class NativeMtpRecordTests(unittest.TestCase):
    NM = {"enabled": True, "mode": "eligible", "family": "glm5_next", "proposal_depth": 3, "proposed_tokens": 30,
          "accepted_tokens": 20, "last_reason": "active", "reset_generation": 1}

    def record(self, nm, phase, expect="on"):
        with tempfile.TemporaryDirectory() as d:
            st, grid = os.path.join(d, "s.json"), os.path.join(d, "g.json")
            Path(st).write_text(json.dumps({"native_mtp": nm} if nm is not None else {}))
            Path(grid).write_text("{}")
            out = []
            rc = route_status.record_native_mtp(st, grid, phase, expect, out=out.append)
            return rc, out, json.loads(Path(grid).read_text())

    def test_on_passes_and_is_stored_in_the_grid(self):
        rc, out, grid = self.record(self.NM, "start")
        self.assertEqual(rc, 0)
        self.assertEqual(grid["native_mtp"]["start"]["accepted_tokens"], 20)
        self.assertTrue(out[0].startswith("NATIVE_MTP phase=start enabled=True mode=eligible"))

    def test_off_disabled_or_missing_fails_with_11(self):
        for nm in (dict(self.NM, enabled=False, mode="off"), dict(self.NM, mode="off"), dict(self.NM, enabled=False), None):
            rc, out, _ = self.record(nm, "start")
            self.assertEqual(rc, 11)
            self.assertTrue(any(x.startswith("NATIVE_MTP_FAIL phase=start") for x in out))

    def test_end_needs_proposed_tokens_and_any_never_fails(self):
        self.assertEqual(self.record(dict(self.NM, proposed_tokens=0), "end")[0], 11)
        self.assertEqual(self.record(dict(self.NM, proposed_tokens=0), "start")[0], 0)
        self.assertEqual(self.record(None, "end", "any")[0], 0)

    def test_client_delta_is_per_trial_and_invalid_after_a_reset(self):
        before = dict(self.NM, mtp_forwards=5)
        after = dict(self.NM, proposed_tokens=90, accepted_tokens=50, mtp_forwards=35)
        d = client.native_mtp_delta(before, after)
        self.assertEqual((d["proposed_tokens"], d["accepted_tokens"], d["acceptance"]), (60, 30, 0.5))
        self.assertEqual(d["mean_accepted_length"], 1.0)
        self.assertFalse(client.native_mtp_delta(before, dict(after, reset_generation=2))["acceptance_valid"])
        self.assertFalse(client.native_mtp_delta(None, after)["acceptance_valid"])


if __name__ == "__main__":
    unittest.main()
