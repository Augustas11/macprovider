"""Offline checks for the parity-grid measurement check (scripts/lab/parity-grid)."""
import contextlib
import importlib.util
import io
import json
import os
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

MODEL = "m"
TEXT = "The keeper lit the lamp."


def ref_line(ctx, out, tps, trial=0, row=0, text=TEXT, tokens=None, prompt_tokens=244):
    return {"side": "reference", "kind": "row", "model": MODEL, "ctx_target": ctx, "max_tokens": out,
            "rows": 1, "row": row, "trial": trial, "decode_tps": tps, "text": text,
            "completion_tokens": out if tokens is None else tokens, "prompt_tokens": prompt_tokens,
            "finish": "length"}


def our_lines(ctx, out, rows, trial_tps, texts=None, tokens=None, prompt_tokens=244, row_tps=None):
    """One trial per entry of trial_tps; each trial has `rows` row lines and one aggregate line."""
    lines = []
    for trial, agg in enumerate(trial_tps):
        base = {"side": "provider", "model": MODEL, "ctx_target": ctx, "max_tokens": out, "rows": rows,
                "trial": trial, "cell": prompts.cell_key(MODEL, ctx, out, rows)}
        for r in range(rows):
            lines.append({**base, "kind": "row", "row": r,
                          "decode_tps": row_tps if row_tps is not None else agg / rows,
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

    def test_multi_row_request_metric_sums_rows(self):
        ours = self.with_request(our_lines(200, 128, 4, [200.0] * 3), 30.0)
        cell = compare.evaluate([ref_line(200, 128, 126.0)], ours)["cells"][0]
        self.assertEqual(cell["ours_request_tps"], 120.0)
        for x in ours:
            if x["kind"] == "aggregate":
                x["request_tps_sum"] = 111.0
        self.assertEqual(compare.evaluate([ref_line(200, 128, 126.0)], ours)["cells"][0]["ours_request_tps"], 111.0)

    def test_client_request_tps(self):
        res = {"text": "ab", "t_first": 2.0, "t_last": 4.0, "t0": 0.0, "t_end": 5.0,
               "usage": {"completion_tokens": 8}}
        rec = client.row_record(res, {})
        self.assertEqual(rec["request_tps"], 2.0)
        self.assertEqual(rec["ttft_s"], 2.0)
        agg = client.aggregate_record([dict(rec, _t_first=2.0, _t_last=4.0)] * 2, {})
        self.assertEqual(agg["request_tps_sum"], 4.0)

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


if __name__ == "__main__":
    unittest.main()
