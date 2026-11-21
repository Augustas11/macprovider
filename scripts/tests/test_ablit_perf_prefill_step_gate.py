"""scripts/lab/ablit-perf: the #2409 GLM serial prefill-step gate job, its gate script and the launcher allowlist."""

import importlib.util
import json
import os
import subprocess
import tempfile
import unittest
from pathlib import Path

LAB = Path(__file__).resolve().parents[1] / "lab" / "ablit-perf"
JOB = LAB / "job-glm-prefill-step-gate.sh"
LAUNCHER = LAB / "studio-ablit-perf.sh"


def load(name, path):
    spec = importlib.util.spec_from_file_location(name, path)
    mod = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(mod)
    return mod


gate = load("prefill_step_gate", LAB / "prefill_step_gate.py")


def profile(tokens_by_step=None, n=4, default=2048):
    tokens_by_step = tokens_by_step or {512: [[1, 2, 3, 4]] * 3, 2048: [[1, 2, 3, 4]] * 3}
    served = [{"step": step, "mlx_peak_bytes": 190e9 + step * 1e6,
               "runs": [{"ttft_ms": 1000.0 - step / 10 + i, "decode_ms": 500.0, "tokens": t}
                        for i, t in enumerate(runs)]}
              for step, runs in tokens_by_step.items()]
    return {"generate_tokens": n, "serve_default_step": default,
            "prompts": [{"tokens": 3673, "served": served}, {"tokens": 14126, "served": served}]}


class GateTests(unittest.TestCase):
    def test_identical_tokens_and_default_pass(self):
        r = gate.evaluate(profile(), 2048)
        self.assertTrue(r["pass"], r["failures"])
        row = r["prompts"][0]["steps"][1]
        self.assertTrue(row["matches_first_step"])
        self.assertEqual(row["ttft_median_ms"], 796.2)
        md = gate.markdown(r)
        self.assertIn("| 3673 | 2048 | 3 | 796.2 (795.2-797.2) | -16.2% | 500.0 | 192.0 | yes | yes |", md)
        self.assertIn("Gate: PASS", md)

    def test_a_later_token_difference_fails_at_its_position(self):
        r = gate.evaluate(profile({512: [[1, 2, 3, 4]] * 3, 2048: [[1, 2, 9, 4]] * 3}), 2048)
        self.assertFalse(r["pass"])
        self.assertEqual(r["prompts"][0]["steps"][1]["first_difference"], 2)
        self.assertIn("step 2048 leaves step 512 at token 2 (3 vs 9)", r["failures"][0])

    def test_run_disagreement_short_runs_and_default_fail(self):
        r = gate.evaluate(profile({512: [[1, 2, 3, 4], [1, 2, 3, 5], [1, 2, 3, 4]], 2048: [[1, 2, 3, 4]] * 3}), 2048)
        self.assertIn("prompt 3673 step 512: runs decoded different tokens", r["failures"])
        r = gate.evaluate(profile({512: [[1, 2, 3]] * 3, 2048: [[1, 2, 3, 4]] * 3}), 2048)
        self.assertIn("prompt 3673 step 512: decoded [3, 3, 3] tokens, expected 4", r["failures"])
        r = gate.evaluate(profile(default=512), 2048)
        self.assertIn("serve_default_step=512, expected 2048", r["failures"])
        r = gate.evaluate(profile(n=1), 2048)
        self.assertFalse(r["pass"])

    def test_cli_exit_codes(self):
        with tempfile.TemporaryDirectory() as d:
            ok, bad = Path(d) / "ok.json", Path(d) / "bad.json"
            ok.write_text(json.dumps(profile()))
            bad.write_text(json.dumps(profile({512: [[1, 2, 3, 4]] * 3, 2048: [[1, 2, 3, 5]] * 3})))
            args = lambda p: ["--profile", str(p), "--expect-default-step", "2048",
                              "--out-md", f"{d}/g.md", "--out-json", f"{d}/g.json"]
            self.assertEqual(gate.main(args(ok)), 0)
            self.assertTrue(json.loads(Path(f"{d}/g.json").read_text())["pass"])
            self.assertEqual(gate.main(args(bad)), 1)
            (Path(d) / "x.json").write_text("{")
            self.assertEqual(gate.main(args(Path(d) / "x.json")), 2)


class JobTests(unittest.TestCase):
    def run_job(self, **env):
        with tempfile.TemporaryDirectory() as home:
            e = {"HOME": home, "PATH": "/usr/bin:/bin", "PREFILL_JOB_CHECK": "1", "RUN_ID": "20261119T000000Z", **env}
            return subprocess.run(["bash", str(JOB)], env=e, capture_output=True, text=True), home

    def test_check_mode_prints_the_profile_and_gate_argv(self):
        r, home = self.run_job()
        self.assertEqual(r.returncode, 0, r.stdout + r.stderr)
        lines = dict(line.split(" ", 1) for line in r.stdout.splitlines())
        self.assertIn("--prompt-tokens 3673,14126 --step-sizes 512,2048 --runs 3 --generate-tokens 512 --served-only",
                      lines["PROFILE_ARGS"])
        self.assertIn("--expect-default-step 2048", lines["GATE_ARGS"])
        self.assertEqual(lines["BUILD_FLAGS"], "-D" + "MACPROVIDER_" + "LAB_HARNESS build_path=.build-lab-harness")
        self.assertFalse((Path(home) / "lab-ablit-perf").exists())  # check mode touches nothing

    def test_knobs_are_validated(self):
        for env in ({"PROMPT_TOKENS": "4k"}, {"PROFILE_RUNS": "0"}, {"PROMPT_TOKENS": "8"},
                    {"GENERATE_TOKENS": "1"}, {"GENERATE_TOKENS": "x"}, {"GENERATE_TOKENS": "5000"}):
            r, _ = self.run_job(**env)
            self.assertEqual(r.returncode, 64, (env, r.stdout))
            self.assertIn("BLOCKER:", r.stdout)

    def test_overrides_reach_the_argv(self):
        r, _ = self.run_job(PROMPT_TOKENS="4096", PROFILE_RUNS="2", GENERATE_TOKENS="64", GLM_PATH="/m/glm")
        self.assertIn("--model-dir /m/glm", r.stdout)
        self.assertIn("--prompt-tokens 4096 --step-sizes 512,2048 --runs 2 --generate-tokens 64", r.stdout)


class LauncherTests(unittest.TestCase):
    def test_launcher_admits_the_job_and_its_knob(self):
        text = LAUNCHER.read_text()
        self.assertIn("|job-glm-prefill-step-gate.sh|job-qwen-mtp-cap.sh|", text)
        self.assertIn("|PROFILE_RUNS|GENERATE_TOKENS|", text)
        self.assertIn("PARITY_|", text)

    def test_launcher_refuses_an_unknown_job_before_ssh(self):
        r = subprocess.run(["bash", str(LAUNCHER)], env={**os.environ, "JOB_SCRIPT": "job-nope.sh"},
                           capture_output=True, text=True)
        self.assertEqual(r.returncode, 2)
        self.assertIn("job-glm-prefill-step-gate.sh", r.stderr)


if __name__ == "__main__":
    unittest.main()
