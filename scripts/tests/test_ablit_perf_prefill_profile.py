"""scripts/lab/ablit-perf: the #2409 GLM prefill profile job, its report and the launcher allowlist."""

import importlib.util
import json
import os
import subprocess
import tempfile
import unittest
from pathlib import Path

LAB = Path(__file__).resolve().parents[1] / "lab" / "ablit-perf"
JOB = LAB / "job-glm-prefill-profile.sh"
LAUNCHER = LAB / "studio-ablit-perf.sh"


def load(name, path):
    spec = importlib.util.spec_from_file_location(name, path)
    mod = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(mod)
    return mod


report = load("prefill_profile_report", LAB / "prefill_profile_report.py")

CONFIG = {
    "text_config": {
        "num_attention_heads": 4, "kv_lora_rank": 8, "index_topk": 32, "index_n_heads": 2,
        "index_head_dim": 4, "index_kpool": 4, "num_experts_per_tok": 2,
        "linear_attn_config": {"num_heads": 2, "head_dim": 4},
    }
}
INVENTORY = [
    {"path": "language_model.model.embed_tokens.weight", "kind": "embedding", "shape": [100, 16]},
    # layer 0: KDA (no kv_a_proj), dense MLP
    {"path": "language_model.model.layers.0.self_attn.q_proj.weight", "kind": "linear", "shape": [16, 16]},
    {"path": "language_model.model.layers.0.mlp.up_proj.weight", "kind": "linear", "shape": [32, 16]},
    # layer 1: MLA with an indexer, routed experts (4-bit packed: 16 inputs -> 2 uint32)
    {"path": "language_model.model.layers.1.self_attn.kv_a_proj_with_mqa.weight", "kind": "linear", "shape": [8, 16]},
    {"path": "language_model.model.layers.1.self_attn.indexer.wk.weight", "kind": "linear", "shape": [4, 16]},
    {"path": "language_model.model.layers.1.mlp.switch_mlp.up_proj.weight", "kind": "switch",
     "shape": [8, 32, 2], "bits": 4},
    {"path": "language_model.model.layers.1.attn_hc.fn", "kind": "raw", "shape": [4, 16]},
    {"path": "language_model.mtp.0.eh_proj.weight", "kind": "linear", "shape": [16, 32]},
    {"path": "language_model.lm_head.weight", "kind": "linear", "shape": [100, 16]},
]


def chunk(offset, tokens, fwd, clear, sections=None):
    c = {"offset": offset, "tokens": tokens, "forward_ms": fwd, "clear_ms": clear}
    if sections is not None:
        c["sections"] = sections
    return c


def profile():
    sec = {"mla.attn_dense": {"calls": 1, "ms": 30.0}, "indexer.pools": {"calls": 1, "ms": 10.0},
           "moe": {"calls": 1, "ms": 40.0}, "kda": {"calls": 1, "ms": 15.0}, "forward": {"calls": 1, "ms": 5.0}}
    served = [{"step": s, "runs": [{"ttft_ms": t, "chunks": 2, "remainder_tokens": 24 if s == 8 else 40,
                                    "first_token": 7} for t in ts]}
              for s, ts in ((8, [100.0, 110.0, 105.0]), (16, [90.0, 95.0, 92.0]))]
    served[1]["runs"] = [{**r, "chunks": 0, "remainder_tokens": 40} for r in served[1]["runs"]]
    return {"inventory": INVENTORY, "prompts": [{
        "tokens": 40, "served": served,
        "synced": {"step": 8, "chunks": [chunk(0, 8, 20.0, 1.0), chunk(8, 8, 22.0, 1.0), chunk(16, 8, 24.0, 1.0),
                                         chunk(24, 8, 26.0, 1.0)],
                   "first_forward": {"tokens": 8, "forward_ms": 30.0, "first_token": 7}, "total_ms": 126.0},
        "synced_no_clear": {"chunks": [], "first_forward": {"first_token": 7}, "total_ms": 120.0},
        "sections": {"section_timing": True, "total_ms": 150.0, "chunks": [{"sections": sec}],
                     "first_forward": {"sections": {"moe": {"calls": 1, "ms": 0.0}}, "first_token": 7}},
    }]}


class ReportTests(unittest.TestCase):
    def test_weight_macs_groups_and_exclusions(self):
        macs = report.weight_macs(INVENTORY, CONFIG)
        self.assertEqual(macs["routed_experts"], 16 * 32 * 2)  # 4-bit packed 2 -> 16 inputs, top-2 of 8
        self.assertEqual(macs["lm_head"], 1600)
        self.assertEqual(macs["attention_projections"], 16 * 16 + 8 * 16)
        self.assertEqual(macs["indexer"], 4 * 16)
        self.assertEqual(macs["hyper_connections_and_other"], 64)
        self.assertNotIn("embedding", macs)
        self.assertEqual(sum(macs.values()), 512 + 1024 + 1600 + 384 + 64 + 64)  # no MTP

    def test_layer_counts(self):
        self.assertEqual(report.layer_counts(INVENTORY), {"mla": 1, "indexer": 1, "kda": 1})

    def test_attention_flops_match_brute_force(self):
        counts = {"mla": 2, "indexer": 1, "kda": 3}
        for n in (5, 32, 33, 100):
            got = report.attention_flops_per_token(CONFIG, counts, n)
            mla = sum(min(t + 1, 32) for t in range(n)) * 2 * 4 * 4 * 8 / n
            idx = sum((t + 1) // 4 for t in range(n)) * 2 * 2 * 4 / n
            self.assertAlmostEqual(got["mla"], mla)
            self.assertAlmostEqual(got["indexer"], idx)
            self.assertEqual(got["kda"], 3 * 4 * 2 * 4 * 4)

    def test_summary_split_sections_and_ceiling(self):
        s = report.summarize(profile(), {"bf16_tflops": 10.0, "q4_tflops": 5.0}, CONFIG,
                             {40: 0.05}, {40: 0.1})
        p = s["prompts"][0]
        self.assertEqual(p["served"][0]["ttft_ms_median"], 105.0)
        self.assertEqual(p["served"][1]["chunks"], 0)
        self.assertEqual(p["split"]["chunk_forward_ms"], 92.0)
        self.assertEqual(p["split"]["clear_ms"], 4.0)
        self.assertEqual(p["split"]["pipelining_ms"], 21.0)
        self.assertAlmostEqual(p["per_chunk"]["growth_ms_per_1k_offset"], 250.0)  # 2 ms per 8 tokens
        g = p["sections"]["groups"]
        self.assertAlmostEqual(g["attention"]["share"], 0.4)
        self.assertAlmostEqual(g["moe_mlp"]["share"], 0.4)
        self.assertAlmostEqual(g["cache_writes"]["share"], 0.1)
        self.assertAlmostEqual(g["other"]["served_ms_est"], 5.25)
        flops = p["flops_per_token"]
        self.assertAlmostEqual(flops, 2 * (512 + 384 + 64 + 64 + 1024) + sum(p["attention_flops_per_token"].values()))
        c = p["ceilings"]["bf16_tflops"]
        self.assertAlmostEqual(c["ceiling_tps"], 0.5 * 10e12 / flops)
        self.assertAlmostEqual(c["ours_share"], (40 / 0.105) / c["ceiling_tps"])
        self.assertAlmostEqual(c["reference_share"], (40 / 0.05) / c["ceiling_tps"])
        self.assertTrue(p["first_tokens_agree"])

    def test_cli_writes_tables_and_flags_disagreement(self):
        with tempfile.TemporaryDirectory() as d:
            d = Path(d)
            prof = profile()
            prof["prompts"][0]["synced_no_clear"]["first_forward"]["first_token"] = 8
            (d / "p.json").write_text(json.dumps(prof))
            (d / "peak.json").write_text(json.dumps({"bf16_tflops": 10.0, "q4_tflops": 5.0}))
            (d / "c.json").write_text(json.dumps(CONFIG))
            rc = report.main(["--profile", str(d / "p.json"), "--peak", str(d / "peak.json"), "--config", str(d / "c.json"),
                              "--out-md", str(d / "o.md"), "--out-json", str(d / "o.json"),
                              "--reference-ttft", "40=0.05", "--reference-chunk", "mlx-lm 2048"])
            self.assertEqual(rc, 0)
            md = (d / "o.md").read_text()
            for heading in ("## 1. TTFT by chunk size", "## 2. Where the served TTFT goes", "## 3. Per-chunk forward",
                            "## 4. Section shares", "## 5. Prefill ceiling"):
                self.assertIn(heading, md)
            self.assertIn("| 40 | 8 | 2 x 8 + 24 |", md)
            self.assertIn("Reference prefill chunk: mlx-lm 2048", md)
            self.assertIn("First tokens agree across passes at 40: NO", md)
            self.assertIn("ceilings", json.loads((d / "o.json").read_text())["prompts"][0])

    def test_unavailable_sections_and_bad_input(self):
        prof = profile()
        prof["prompts"][0]["sections"] = {"step": 8, "section_timing": "unavailable"}
        s = report.summarize(prof, {"bf16_tflops": 1.0, "q4_tflops": 1.0}, CONFIG, {}, {})
        self.assertIsNone(s["prompts"][0]["sections"])
        self.assertIn("section timing unavailable", report.markdown(s, ""))
        with tempfile.TemporaryDirectory() as d:
            (Path(d) / "bad.json").write_text("{")
            self.assertEqual(report.main(["--profile", f"{d}/bad.json", "--peak", f"{d}/bad.json", "--config",
                                          f"{d}/bad.json", "--out-md", f"{d}/o.md", "--out-json", f"{d}/o.json"]), 2)


class JobTests(unittest.TestCase):
    def run_job(self, **env):
        with tempfile.TemporaryDirectory() as home:
            e = {"HOME": home, "PATH": "/usr/bin:/bin", "PREFILL_JOB_CHECK": "1", "RUN_ID": "20261119T000000Z", **env}
            return subprocess.run(["bash", str(JOB)], env=e, capture_output=True, text=True), home

    def test_check_mode_prints_the_profile_and_report_argv(self):
        r, home = self.run_job()
        self.assertEqual(r.returncode, 0, r.stdout + r.stderr)
        lines = dict(line.split(" ", 1) for line in r.stdout.splitlines())
        self.assertIn("prefill-profile --model-dir", lines["PROFILE_ARGS"])
        self.assertIn("--prompt-tokens 3673,14126 --step-sizes 512,2048 --runs 3", lines["PROFILE_ARGS"])
        self.assertIn("--reference-ttft 3673=8.00,14126=32.76", lines["REPORT_ARGS"])
        self.assertIn("-DMACPROVIDER_SECTION_TIMING", lines["BUILD_FLAGS"])
        self.assertFalse((Path(home) / "lab-ablit-perf").exists())  # check mode touches nothing

    def test_knobs_are_validated(self):
        for env in ({"PROMPT_TOKENS": "4k"}, {"STEP_SIZES": "512,"}, {"PROFILE_RUNS": "0"},
                    {"PROMPT_TOKENS": "8"}, {"REFERENCE_TTFT": "3673:8"}):
            r, _ = self.run_job(**env)
            self.assertEqual(r.returncode, 64, (env, r.stdout))
            self.assertIn("BLOCKER:", r.stdout)

    def test_overrides_reach_the_argv(self):
        r, _ = self.run_job(PROMPT_TOKENS="4096", STEP_SIZES="2048", PROFILE_RUNS="2", GLM_PATH="/m/glm")
        self.assertIn("--model-dir /m/glm", r.stdout)
        self.assertIn("--prompt-tokens 4096 --step-sizes 2048 --runs 2", r.stdout)


class LauncherTests(unittest.TestCase):
    def test_launcher_admits_the_job_its_fork_file_and_knobs(self):
        text = LAUNCHER.read_text()
        self.assertIn("job-glm-prefill-profile.sh) FORK_FILE=Libraries/MLXLMCommon/LabSectionTimer.swift", text)
        self.assertIn("|job-glm-prefill-profile.sh) ;;", text)
        self.assertIn("PROMPT_TOKENS|STEP_SIZES|PROFILE_RUNS|", text)
        self.assertIn("PEAK |PROFILE_)", text)

    def test_launcher_refuses_an_unknown_job_before_ssh(self):
        r = subprocess.run(["bash", str(LAUNCHER)], env={**os.environ, "JOB_SCRIPT": "job-nope.sh"},
                           capture_output=True, text=True)
        self.assertEqual(r.returncode, 2)
        self.assertIn("job-glm-prefill-profile.sh", r.stderr)


if __name__ == "__main__":
    unittest.main()
