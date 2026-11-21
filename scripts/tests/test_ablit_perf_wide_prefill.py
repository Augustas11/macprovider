"""scripts/lab/ablit-perf: the #2451 GLM wide-prefill job, its gate script and the launcher wiring."""

import importlib.util
import json
import os
import subprocess
import tempfile
import unittest
from pathlib import Path

LAB = Path(__file__).resolve().parents[1] / "lab" / "ablit-perf"
JOB = LAB / "job-glm-wide-prefill.sh"
LAUNCHER = LAB / "studio-ablit-perf.sh"


def load(name, path):
    spec = importlib.util.spec_from_file_location(name, path)
    mod = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(mod)
    return mod


gate = load("wide_prefill_gate", LAB / "wide_prefill_gate.py")


def run(ttft, text="ok", cells=((4000, 128), (4000, 512)), trials=3, **override):
    rows = []
    for ctx, out in cells:
        for t in range(trials):
            r = {"kind": "row", "ctx_target": ctx, "max_tokens": out, "rows": 1, "row": 0, "trial": t,
                 "text": text, "reasoning_text": "", "completion_tokens": out, "prompt_tokens": ctx,
                 "ttft_s": ttft + t * 0.01}
            r.update(override)
            rows.append(r)
    rows.append({"kind": "row", "turn": 2, "ctx_target": 4000, "max_tokens": 128, "rows": 1, "row": 0,
                 "trial": 0, "text": "turn two differs", "completion_tokens": 1, "prompt_tokens": 1})
    return rows


def ref(ttft, cells=((4000, 128), (4000, 512))):
    return [{"kind": "row", "ctx_target": c, "max_tokens": o, "row": 0, "trial": 0, "ttft_s": ttft} for c, o in cells]


class GateTests(unittest.TestCase):
    def test_identical_and_faster_keeps(self):
        r = gate.evaluate(run(2.0), run(1.8), run(2.1), reference=ref(1.5))
        self.assertTrue(r["pass"], r["failures"])
        self.assertEqual(r["verdict"], "KEEP")
        cell = r["cells"][0]
        self.assertEqual(cell["candidate_ttft_s"], 1.81)
        self.assertEqual(cell["change_vs_a"], round(1.81 / 2.01 - 1, 4))
        self.assertEqual(cell["omlx_ttft_s"], 1.5)
        md = gate.markdown(r)
        self.assertIn("Gate: PASS. Verdict: KEEP.", md)
        self.assertIn("| 4000 | 512 |", md)

    def test_slower_than_one_control_reverts_but_passes(self):
        r = gate.evaluate(run(2.0), run(1.9), run(1.8))
        self.assertTrue(r["pass"])
        self.assertEqual(r["verdict"], "REVERT")
        self.assertIsNone(r["cells"][0]["omlx_ttft_s"])

    def test_a_token_difference_fails(self):
        r = gate.evaluate(run(2.0), run(1.8, text="other"), run(2.1))
        self.assertFalse(r["pass"])
        self.assertTrue(any("candidate trial 0 row 0: text differs" in f for f in r["failures"]))
        r = gate.evaluate(run(2.0), run(1.8, completion_tokens=7), run(2.1))
        self.assertTrue(any("completion_tokens differs from control A (7 vs 128)" in f for f in r["failures"]))
        r = gate.evaluate(run(2.0), run(1.8), run(2.1, text="drift"))
        self.assertTrue(any("control B trial 0 row 0: text differs" in f for f in r["failures"]))

    def test_errors_missing_cells_and_no_512_fail(self):
        r = gate.evaluate(run(2.0), run(1.8, error="boom"), run(2.1))
        self.assertTrue(any("error boom" in f for f in r["failures"]))
        r = gate.evaluate(run(2.0), run(1.8, cells=((4000, 128),)), run(2.1))
        self.assertIn("ctx4000|out512|rows1: missing from candidate", r["failures"])
        small = ((4000, 128),)
        r = gate.evaluate(run(2.0, cells=small), run(1.8, cells=small), run(2.1, cells=small))
        self.assertIn("no 512-output cell", r["failures"])

    def test_cli_exit_codes(self):
        with tempfile.TemporaryDirectory() as d:
            def write(name, rows):
                p = Path(d) / name
                p.write_text("".join(json.dumps(r) + "\n" for r in rows))
                return str(p)
            a, b = write("a.jsonl", run(2.0)), write("b.jsonl", run(2.1))
            good, bad = write("c.jsonl", run(1.8)), write("x.jsonl", run(1.8, text="other"))
            args = lambda c: ["--control-a", a, "--candidate", c, "--control-b", b,
                              "--out-md", f"{d}/g.md", "--out-json", f"{d}/g.json"]
            self.assertEqual(gate.main(args(good)), 0)
            self.assertEqual(json.loads(Path(f"{d}/g.json").read_text())["verdict"], "KEEP")
            self.assertEqual(gate.main(args(bad)), 1)
            self.assertEqual(gate.main(args(write("e.jsonl", []))), 2)
            self.assertEqual(gate.main(args(str(Path(d) / "absent.jsonl"))), 2)


class JobTests(unittest.TestCase):
    def run_job(self, **env):
        with tempfile.TemporaryDirectory() as home:
            e = {"HOME": home, "PATH": "/usr/bin:/bin", "WIDE_JOB_CHECK": "1", "RUN_ID": "20261120T000000Z",
                 "GLM_OMLX_DIR": "/s/omlx", **env}
            return subprocess.run(["bash", str(JOB)], env=e, capture_output=True, text=True), home

    def test_check_mode_prints_control_candidate_control(self):
        r, home = self.run_job()
        self.assertEqual(r.returncode, 0, r.stdout + r.stderr)
        lines = dict(line.split(" ", 1) for line in r.stdout.splitlines())
        common = ("--cb auto --no-autotune-candidate --rows 1 --contexts 4k,16k --outputs 128,512 --trials 3 "
                  "--config-extra")
        for p in ("main-a", "wide", "main-b"):
            argv = lines[f"GRID_ARGS_{p}"]
            self.assertIn(common, argv)
            self.assertIn("--expect-route batched", argv)
            self.assertIn("--model-id zai-org/glm-5.3-flash-uncensored --model-sha256 242f8fcf", argv)
            self.assertIn(f"/glm-wide-prefill/{p} ", argv)
        self.assertIn("/.build-lab-main/release", lines["GRID_ARGS_main-a"])
        self.assertIn("/.build-lab-wide/release", lines["GRID_ARGS_wide"])
        self.assertIn("--reference omlx --ref-arg --omlx-dir --ref-arg /s/omlx", lines["GRID_ARGS_wide"])
        for p in ("main-a", "main-b"):
            self.assertIn("--skip-reference --skip-compare", lines[f"GRID_ARGS_{p}"])
            self.assertNotIn("omlx", lines[f"GRID_ARGS_{p}"])
        self.assertEqual(lines["FORK_TEST_FILTER"], "GLM5NextTests/testWidePrefill")
        self.assertFalse((Path(home) / "lab-ablit-perf").exists())  # check mode touches nothing

    def test_knobs_are_validated(self):
        for env in ({"OUTPUTS": "128"}, {"OUTPUTS": "x"}, {"TRIALS": "0"}, {"CONTEXTS": "4k;rm"},
                    {"SKIP_REFERENCE": "2"}, {"SKIP_FORK_TESTS": "yes"}, {"GLM_OMLX_DIR": ""},
                    {"SEED_SELF_CHECK_RUN": "last"}, {"SERVE_ENV": "A=1;B"}):
            r, _ = self.run_job(**env)
            self.assertEqual(r.returncode, 64, (env, r.stdout))
            self.assertIn("BLOCKER:", r.stdout)

    def test_overrides_reach_the_argv(self):
        r, _ = self.run_job(SKIP_REFERENCE="1", GLM_OMLX_DIR="", CONTEXTS="16k", TRIALS="2", GLM_PATH="/m/glm",
                            SEED_SELF_CHECK_RUN="20261119T000000Z", SERVE_ENV="A=1")
        self.assertEqual(r.returncode, 0, r.stdout)
        wide = dict(line.split(" ", 1) for line in r.stdout.splitlines())["GRID_ARGS_wide"]
        self.assertIn("--model-path /m/glm", wide)
        self.assertIn("--contexts 16k --outputs 128,512 --trials 2", wide)
        self.assertIn("--skip-reference --skip-compare", wide)
        self.assertIn("--serve-env A=1", wide)
        self.assertIn("/20261119T000000Z/glm-wide-prefill/main-a/serve/cb-self-check.json", wide)


class LauncherTests(unittest.TestCase):
    def test_launcher_admits_the_job_and_its_knobs(self):
        text = LAUNCHER.read_text()
        self.assertIn("|job-glm-wide-prefill.sh) ;;", text)
        self.assertIn("job-glm-wide-prefill.sh) FORK_FILE=Libraries/MLXLLM/Models/GLM5Next.swift ;;", text)
        self.assertIn("grep -q glm5NextPrefillSlicesKey HEAD", text)
        self.assertIn("|SKIP_FORK_TESTS|", text)
        self.assertIn("|WIDE_|FORK_TEST)'", text)
        self.assertIn("macstudio:lab-ablit-perf/src-main/phase3-binary/", text)
        self.assertIn("--include='main-a/serve/cb-self-check.json'", text)

    def test_launcher_refuses_an_unknown_job_before_ssh(self):
        r = subprocess.run(["bash", str(LAUNCHER)], env={**os.environ, "JOB_SCRIPT": "job-nope.sh"},
                           capture_output=True, text=True)
        self.assertEqual(r.returncode, 2)
        self.assertIn("job-glm-wide-prefill.sh", r.stderr)


if __name__ == "__main__":
    unittest.main()
