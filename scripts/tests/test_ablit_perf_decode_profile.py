"""scripts/lab/ablit-perf: the #2409 Qwen3.8-Flash-Next per-row decode profile (section timing report,
job-qwen4-cb.sh SERVE_ENV/SKIP_REFERENCE knobs, launcher allowlist)."""

import importlib.util
import json
import os
import subprocess
import tempfile
import unittest
from pathlib import Path

LAB = Path(__file__).resolve().parents[1] / "lab" / "ablit-perf"
JOB = LAB / "job-qwen4-cb.sh"
LAUNCHER = LAB / "studio-ablit-perf.sh"

spec = importlib.util.spec_from_file_location("section_timing_report", LAB / "section_timing_report.py")
report = importlib.util.module_from_spec(spec)
spec.loader.exec_module(report)


def line(rows, length=1, wall=None, **sections):
    # A section passed as name=(ms, calls); dots in names are written with "__".
    fields = " ".join(f"{k.replace('__', '.')}={ms:.3f}/{calls}" for k, (ms, calls) in sorted(sections.items()))
    total = sum(ms for ms, _ in sections.values())
    return f"section_timing tag=rows={rows},L={length} wall_ms={wall if wall is not None else total + 1:.3f} {fields}"


def synthetic(rows_list=(1, 4, 8, 11), n=6):
    """attn.row.sdpa: 0.5 ms/row; moe.experts: 10 ms + 0.1 ms/row; embed: flat 0.2 ms."""
    out = ["unrelated serve log line", line(4, length=200, moe__experts=(99.0, 40))]  # prefill: ignored
    for b in rows_list:
        for i in range(n):
            out.append(line(b, attn__row__sdpa=(0.5 * b, 10 * b), moe__experts=(10 + 0.1 * b, 40),
                            embed=(0.2 + (0.01 if i == 0 else 0), 1)))
    return out


class ReportTests(unittest.TestCase):
    def test_parse_keeps_decode_forwards_only(self):
        f = report.parse(synthetic())
        self.assertEqual(sorted(f), [1, 4, 8, 11])
        self.assertEqual(len(f[4]), 6)
        self.assertEqual(f[8][0]["sections"]["attn.row.sdpa"], (4.0, 80))

    def test_slopes_kinds_and_scaling(self):
        s = report.summarize(report.parse(synthetic()), [1, 4, 8, 11], 5.9, 5)
        by = {r["section"]: r for r in s["sections"]}
        self.assertAlmostEqual(by["attn.row.sdpa"]["ms_per_row"], 0.5)
        self.assertEqual(by["attn.row.sdpa"]["kind"], "per-row")
        self.assertTrue(by["attn.row.sdpa"]["scales"])
        self.assertEqual(by["attn.row.sdpa"]["calls_at_max_rows"], 110)
        self.assertAlmostEqual(by["moe.experts"]["ms_per_row"], 0.1)
        self.assertEqual(by["moe.experts"]["kind"], "batched")
        self.assertFalse(by["moe.experts"]["scales"])  # 1.0 ms of 11.1 ms at 11 rows
        self.assertAlmostEqual(by["embed"]["ms_per_row"], 0.0)
        self.assertFalse(by["embed"]["scales"])
        self.assertAlmostEqual(s["sections_ms_per_row"], 0.6)
        self.assertAlmostEqual(by["attn.row.sdpa"]["goal_ms_per_row"], 5.9 * 0.5 / 0.6)
        self.assertAlmostEqual(s["kinds"]["per-row"]["slope_share"], 0.5 / 0.6)
        self.assertAlmostEqual(s["wall_ms_per_row"], 0.6)
        self.assertEqual(s["sections"][0]["section"], "attn.row.sdpa")

    def test_rows_filter_min_forwards_and_kind_names(self):
        f = report.parse(synthetic(rows_list=(1, 4, 8, 11, 16)))
        self.assertEqual(report.summarize(f, [1, 8], 5.9, 5)["rows"], [1, 8])
        self.assertEqual(report.summarize(f, None, 5.9, 5)["rows"], [1, 4, 8, 11, 16])
        with self.assertRaises(ValueError):
            report.summarize(f, [1], 5.9, 5)
        with self.assertRaises(ValueError):
            report.summarize(f, None, 5.9, 7)
        for name, kind in (("attn.rows", "per-row"), ("attn.row.norm_rope", "per-row"),
                           ("fp_linear.2048x64", "per-row"), ("attn.proj", "batched"), ("attn.rowsx", "batched")):
            self.assertEqual(report.kind(name), kind, name)

    def test_cli_writes_tables_and_fails_without_forwards(self):
        with tempfile.TemporaryDirectory() as d:
            d = Path(d)
            (d / "serve.err").write_text("\n".join(synthetic()) + "\n")
            args = ["--serve-err", str(d / "serve.err"), "--out-md", str(d / "o.md"), "--out-json", str(d / "o.json"),
                    "--rows", "1,4,8,11"]
            self.assertEqual(report.main(args), 0)
            md = (d / "o.md").read_text()
            self.assertIn("| section | kind | ms @1 | ms @4 | ms @8 | ms @11 | calls @11 |", md)
            self.assertIn("| attn.row.sdpa | per-row | 0.500 | 2.000 | 4.000 | 5.500 | 110 | 0.500 |", md)
            self.assertEqual(json.loads((d / "o.json").read_text())["rows"], [1, 4, 8, 11])
            (d / "serve.err").write_text("no timing here\n")
            self.assertEqual(report.main(args), 2)


class JobTests(unittest.TestCase):
    def run_job(self, **env):
        e = {"PATH": os.environ["PATH"], "HOME": tempfile.gettempdir(), "CB_JOB_CHECK": "1",
             "RUN_ID": "20261119T000000Z", **env}
        r = subprocess.run(["bash", str(JOB)], env=e, capture_output=True, text=True, timeout=30)
        return r.returncode, r.stdout

    def test_decode_profile_argv(self):
        rc, out = self.run_job(CB_ROWS="1,4,8,11", CONTEXTS="200", OUTPUTS="256", TRIALS="1", SKIP_REFERENCE="1",
                               SERVE_ENV="MLX_LM_SECTION_TIMING=1")
        self.assertEqual(rc, 0, out)
        argv = next(l for l in out.splitlines() if l.startswith("GRID_ARGS"))
        self.assertIn("--rows 1,4,8,11 --contexts 200 --outputs 256 --trials 1", argv)
        self.assertIn("--skip-reference --skip-compare", argv)
        self.assertIn("--serve-env MLX_LM_SECTION_TIMING=1", argv)
        self.assertNotIn("--reference", argv.replace("--skip-reference", ""))
        self.assertNotIn("--python", argv)

    def test_defaults_keep_the_reference_and_no_serve_env(self):
        rc, out = self.run_job()
        self.assertEqual(rc, 0, out)
        argv = next(l for l in out.splitlines() if l.startswith("GRID_ARGS"))
        self.assertIn("--reference mlx-lm", argv)
        self.assertNotIn("--skip-reference", argv)
        self.assertNotIn("--serve-env", argv)

    def test_knobs_are_validated(self):
        for env in ({"SKIP_REFERENCE": "yes"}, {"SERVE_ENV": "not a pair"}, {"SERVE_ENV": "1A=1"}):
            rc, out = self.run_job(**env)
            self.assertEqual(rc, 64, (env, out))
            self.assertIn("BLOCKER:", out)


class LauncherTests(unittest.TestCase):
    def test_launcher_passes_the_knobs_and_checks_the_timer_file(self):
        text = LAUNCHER.read_text()
        self.assertIn("SERVE_ENV|SKIP_REFERENCE|", text)
        self.assertIn("HEAD:Libraries/MLXLMCommon/LabSectionTimer.swift", text)
        self.assertIn("INFERENCE_ERROR|DECODE_PROFILE)", text)


if __name__ == "__main__":
    unittest.main()
