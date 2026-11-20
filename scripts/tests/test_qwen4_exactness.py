"""scripts/lab/ablit-perf: the Flash-Next exactness window (#2448 fenced CB determinism, #2449
served-prompt parity verdicts and close-call gate). No MLX: pure helpers and dry-run knobs."""

import importlib.util
import json
import os
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
LAB = ROOT / "scripts" / "lab" / "ablit-perf"
GRID = ROOT / "scripts" / "lab" / "parity-grid"


def load(name, path):
    spec = importlib.util.spec_from_file_location(name, path)
    mod = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(mod)
    return mod


det = load("cb_determinism", LAB / "cb_determinism.py")
div = load("qwen4_divergence", LAB / "qwen4_divergence.py")
served = load("qwen4_served_oracle", LAB / "qwen4_served_oracle.py")
sys.path.insert(0, str(GRID))
client = load("provider_client", GRID / "provider_client.py")


def row(rows, r, trial, text, tokens=5, ctx=200, out=512, fence="labfence-t-{rows}-{r}", error=None):
    rec = {"kind": "row", "side": "provider", "rows": rows, "row": r, "trial": trial, "ctx_target": ctx,
           "max_tokens": out, "text": text, "completion_tokens": tokens, "error": error, "finish": "length"}
    if fence:
        rec["lab_fence"] = fence.format(rows=rows, r=r).replace("-t-", f"-t{trial}x{ctx}-")
    return rec


def serve_err(records, installed=True):
    fences = sorted({r["lab_fence"] for r in records if r.get("row") == 0 and r.get("lab_fence")})
    return "".join(f"event=lab_request_fence installed={'true' if installed else 'false'} rows=1 fence={f}\n"
                   for f in fences)


def cell(rows, trials=2, text=lambda r, t: f"row {r}"):
    return [row(rows, r, t, text(r, t)) for t in range(trials) for r in range(rows)]


class FenceIdTests(unittest.TestCase):
    def test_client_ids_match_the_swift_grammar(self):
        ids = client.lab_fence_ids(3, token="abc123")
        self.assertEqual(ids, ["labfence-abc123-3-0", "labfence-abc123-3-1", "labfence-abc123-3-2"])
        fresh = client.lab_fence_ids(2)
        self.assertRegex(fresh[0], r"^labfence-[0-9a-f]{16}-2-0$")
        self.assertNotEqual(fresh[0].split("-")[1], client.lab_fence_ids(2)[0].split("-")[1])

    def test_headers_carry_the_fence_id(self):
        self.assertEqual(client.conversation_headers(None, 1, ["a", "b"]), {"X-Request-ID": "b"})
        self.assertEqual(client.conversation_headers(["c0", "c1"], 0, None), {client.CONVERSATION_HEADER: "c0"})
        self.assertIsNone(client.conversation_headers(None, 0, None))


class DeterminismTests(unittest.TestCase):
    def test_fence_check_counts_installed_trials(self):
        recs = cell(4)
        self.assertEqual(det.fence_check(recs, serve_err(recs)), (2, 2, []))
        fenced, total, problems = det.fence_check(recs, serve_err(recs, installed=False))
        self.assertEqual((fenced, total), (0, 2))
        self.assertTrue(problems)
        unfenced = [dict(r, lab_fence=None) for r in recs]
        self.assertIn("without a fence id", det.fence_check(unfenced, "")[2][0])

    def test_identical_passes_pass(self):
        recs = cell(4) + cell(1)
        passes = {"a": (recs, []), "b": (recs, [])}
        cells, problems = det.check(passes, [1, 4])
        self.assertEqual(problems, [])
        self.assertEqual([c["rows_identical"] for c in cells], [1, 4])
        self.assertEqual(cells[1]["outputs_per_row"], [4])

    def test_a_differing_row_or_token_count_fails(self):
        a = cell(4)
        b = cell(4, text=lambda r, t: "row 2 drifted" if (r, t) == (2, 1) else f"row {r}")
        cells, problems = det.check({"a": (a, []), "b": (b, [])}, [4])
        self.assertEqual(len(problems), 1)
        diff = cells[0]["diffs"][0]
        self.assertEqual((diff["row"], diff["reason"], diff["first_char_diff"]), (2, "differs", 5))
        c = [dict(r, completion_tokens=6) if r["row"] == 0 and r["trial"] == 0 else r for r in cell(4)]
        self.assertTrue(det.check({"a": (cell(4), []), "b": (c, [])}, [4])[1])

    def test_errors_missing_rows_and_fence_problems_fail(self):
        a = cell(4)
        b = [dict(r, error="http 500") if r["row"] == 3 else r for r in cell(4)]
        self.assertTrue(det.check({"a": (a, []), "b": (b, [])}, [4])[1])
        self.assertIn("no cells at rows [8]", det.check({"a": (a, []), "b": (a, [])}, [4, 8])[1][0])
        self.assertTrue(det.check({"a": (a, ["x: not fenced"]), "b": (a, [])}, [4])[1])

    def test_cli_check_and_fences(self):
        with tempfile.TemporaryDirectory() as d:
            for name in ("a", "b"):
                p = Path(d) / name
                (p / "serve").mkdir(parents=True)
                recs = cell(4) + cell(8)
                (p / "provider.jsonl").write_text("".join(json.dumps(r) + "\n" for r in recs))
                (p / "serve" / "serve.err").write_text(serve_err(recs))
            args = ["check", "--pass", f"a={d}/a", "--pass", f"b={d}/b", "--rows", "4,8",
                    "--out-json", f"{d}/o.json", "--out-md", f"{d}/o.md"]
            self.assertEqual(det.main(args), 0)
            self.assertEqual(json.loads(Path(d, "o.json").read_text())["problems"], [])
            self.assertIn("DETERMINISM PASS", Path(d, "o.md").read_text())
            self.assertEqual(det.main(["fences", "--provider", f"{d}/a/provider.jsonl",
                                       "--serve-err", f"{d}/a/serve/serve.err"]), 0)
            Path(d, "b", "serve", "serve.err").write_text("")
            self.assertEqual(det.main(args), 1)
            self.assertEqual(det.main(["check", "--pass", f"a={d}/a", "--rows", "4"]), 2)


def oracle(greedy, gaps, source="oracle_served_200.npz", prompt_len=186):
    """Top-16 ids: greedy token first, then greedy + 1, ...; logits 20, 20 - gap, then lower."""
    return {"source": source, "prompt": list(range(prompt_len)), "greedy": greedy,
            "top_idx": [[t + k for k in range(16)] for t in greedy],
            "top_logit": [[20.0, 20.0 - g] + [10.0 - k for k in range(14)] for g in gaps]}


def comparison(o, tokens, diffs, shift=0.0):
    """A glm-parity comparison on the oracle's history: our logits = reference + shift at index 1."""
    gathered = []
    for i, ref in enumerate(o["top_logit"]):
        ours = list(ref)
        ours[1] += shift if tokens[i] != o["greedy"][i] else 0.0
        gathered.append(ours)
    match = sum(1 for a, b in zip(tokens, o["greedy"]) if a == b)
    first = next((i for i, (a, b) in enumerate(zip(tokens, o["greedy"])) if a != b), None)
    return {"compared_tokens": len(tokens), "first_divergence": first, "matching_tokens": match,
            "top1_compared": min(16, len(tokens)), "top1_agreement": min(16, len(tokens)) - (1 if first is not None and first < 16 else 0),
            "tokens": tokens, "gathered_logits": gathered, "max_abs_logit_diff_per_step": diffs}


def measurement(o, tokens, diffs, shift=0.0, free_tokens=None):
    tf = comparison(o, tokens, diffs, shift)
    fr = comparison(o, free_tokens or tokens, diffs, shift)
    return {"free_running": fr, "teacher_forced": tf if fr["first_divergence"] is not None else None}


class DivergenceTests(unittest.TestCase):
    def setUp(self):
        self.greedy = [100, 200, 300, 400, 500, 600]
        self.o = oracle(self.greedy, [5.0, 4.0, 6.0, 0.25, 7.0, 3.0])

    def test_close_call_verdict_and_our_margin(self):
        tokens = list(self.greedy)
        tokens[3] = 401  # our argmax is the reference's second choice at a 0.25 gap
        cmp_ = comparison(self.o, tokens, [0.1, 0.1, 0.1, 0.2, 0.1, 0.1], shift=0.5)
        v = div.step_view(self.o, cmp_, 3)
        self.assertEqual(v["verdict"], "CLOSE_CALL")  # 0.25 < 2 x 0.2
        self.assertAlmostEqual(v["ref_gap"], 0.25)
        self.assertAlmostEqual(v["our_margin"], 0.25)  # ours: 20 vs 19.75 + 0.5
        self.assertEqual(div.step_view(self.o, cmp_, 2)["verdict"], "REAL_DIVERGENCE")
        self.assertIsNone(div.step_view(self.o, cmp_, 99))

    def test_report_names_a_near_tie_at_the_served_step(self):
        tokens = list(self.greedy)
        tokens[3] = 401
        m = measurement(self.o, tokens, [0.1, 0.1, 0.1, 0.2, 0.1, 0.1], shift=0.5)
        meta = {"source": self.o["source"], "ctx": 200,
                "served": {"text_equal": False, "token_index": 3, "served_token": 401, "prompt_tokens": 186}}
        rec = div.prompt_report(self.o["source"], self.o, meta, m, m)
        self.assertEqual((rec["verdict"], rec["cause"]), ("CLOSE_CALL", "near_tie"))
        self.assertEqual([v["step"] for v in rec["steps"]["served"]], [0, 1, 2, 3])
        self.assertEqual(rec["engine_first_divergence"], {"prefill_2048": 3, "prefill_512": 3})

    def test_causes_for_a_real_divergence(self):
        diffs = [0.1] * 6
        # The port picks the served token on the reference's history by more than rounding.
        tokens = list(self.greedy)
        tokens[2] = 301
        port = measurement(self.o, tokens, diffs, shift=2.0)
        meta = {"source": self.o["source"], "ctx": 200,
                "served": {"text_equal": False, "token_index": 2, "served_token": 301, "prompt_tokens": 186}}
        rec = div.prompt_report(self.o["source"], self.o, meta, port, port)
        self.assertEqual((rec["verdict"], rec["cause"]), ("REAL_DIVERGENCE", "port_or_shim"))
        # The port follows the reference: the served path differs (or its prompt ids do).
        follows = measurement(self.o, list(self.greedy), diffs)
        self.assertEqual(div.prompt_report(self.o["source"], self.o, meta, follows, follows)["cause"], "serve_path")
        meta_ids = json.loads(json.dumps(meta))
        meta_ids["served"]["prompt_tokens"] = 190
        self.assertEqual(div.prompt_report(self.o["source"], self.o, meta_ids, follows, follows)["cause"], "prompt_ids")
        # Only the prefill-512 free run leaves the reference there, with the served token.
        p512 = measurement(self.o, list(self.greedy), diffs, free_tokens=[100, 200, 301, 400, 500, 600])
        self.assertEqual(div.prompt_report(self.o["source"], self.o, meta, follows, p512)["cause"], "prefill_step")
        # No divergence in the served text.
        same = {"source": self.o["source"], "ctx": 200, "served": {"text_equal": True}}
        self.assertEqual(div.prompt_report(self.o["source"], self.o, same, follows, follows)["verdict"],
                         "NO_SERVED_DIVERGENCE")

    def test_gate(self):
        diffs = [0.1, 0.1, 0.1, 0.2, 0.1, 0.1]
        code = oracle(list(range(10, 26)), [8.0] * 16, source="oracle_1024.npz")
        code_m = measurement(code, list(range(10, 26)), [1.0] * 16)
        flip = list(self.greedy)
        flip[3] = 401
        ok = {"oracle_1024.npz": code_m, self.o["source"]: measurement(self.o, flip, diffs, shift=0.5)}
        oracles = {"oracle_1024.npz": code, self.o["source"]: self.o}
        lines, passed = div.gate(oracles, ok, 256)
        self.assertTrue(passed, lines)
        self.assertIn("close_call_flips=[3]", lines[1])
        self.assertTrue(lines[-1].startswith("PARITY_GATES PASS"))
        real = list(self.greedy)
        real[2] = 301
        bad = dict(ok, **{self.o["source"]: measurement(self.o, real, diffs, shift=2.0)})
        lines, passed = div.gate(oracles, bad, 256)
        self.assertFalse(passed)
        self.assertIn("REAL_DIVERGENCE at teacher-forced steps [2]", lines[-1])
        # High-margin prompts only: no close call in the set fails the gate.
        lines, passed = div.gate({"oracle_1024.npz": code}, {"oracle_1024.npz": code_m}, 256)
        self.assertFalse(passed)
        self.assertIn("no close-call step", lines[-1])
        # A missing parity run fails.
        self.assertFalse(div.gate(oracles, {"oracle_1024.npz": code_m}, 256)[1])

    def test_report_cli(self):
        tokens = list(self.greedy)
        tokens[3] = 401
        m = measurement(self.o, tokens, [0.1, 0.1, 0.1, 0.2, 0.1, 0.1], shift=0.5)
        with tempfile.TemporaryDirectory() as d:
            Path(d, "oracle_served_200.json").write_text(json.dumps(self.o))
            Path(d, "served_200.json").write_text(json.dumps(
                {"source": self.o["source"], "ctx": 200,
                 "served": {"text_equal": False, "token_index": 3, "served_token": 401, "prompt_tokens": 186}}))
            Path(d, "p.json").write_text(json.dumps({"runs": [{"oracle_source": self.o["source"], "measurement": m}]}))
            args = ["report", "--oracle-dir", d, "--parity", f"{d}/p.json", "--parity-512", f"{d}/p.json",
                    "--out-json", f"{d}/r.json", "--out-md", f"{d}/r.md"]
            self.assertEqual(div.main(args), 0)
            rec = json.loads(Path(d, "r.json").read_text())["records"][0]
            self.assertEqual((rec["verdict"], rec["cause"]), ("CLOSE_CALL", "near_tie"))
            self.assertIn("| served | 3 | 400 | 401 |", Path(d, "r.md").read_text())


class ServedOracleTests(unittest.TestCase):
    def test_generate_step_partition(self):
        self.assertEqual(served.generate_step_chunks(186), [(0, 185), (185, 186)])
        self.assertEqual(served.generate_step_chunks(3514), [(0, 2048), (2048, 3513), (3513, 3514)])
        self.assertEqual(served.generate_step_chunks(4097, 2048), [(0, 2048), (2048, 4096), (4096, 4097)])
        self.assertEqual(served.generate_step_chunks(1), [(0, 1)])
        with self.assertRaises(ValueError):
            served.generate_step_chunks(0)

    def test_first_diff_and_token_at_byte(self):
        self.assertIsNone(served.first_diff([1, 2], [1, 2]))
        self.assertEqual(served.first_diff([1, 2], [1, 3]), 1)
        self.assertEqual(served.first_diff([1, 2], [1, 2, 3]), 2)
        self.assertEqual(served.token_at_byte([b"ab", b"c", b"de"], 2), 1)
        self.assertEqual(served.token_at_byte([b"ab", b"c", b"de"], 3), 2)
        self.assertEqual(served.token_at_byte([b"ab"], 5), 1)

    def test_served_comparison_finds_the_token(self):
        vocab = {1: "It is ", 2: "not", 3: " noise", 4: "no", 5: " longer"}
        inverse = {v: k for k, v in vocab.items()}

        def encode(text):  # greedy longest-match over the toy vocabulary
            out, i = [], 0
            while i < len(text):
                piece = max((v for v in inverse if text.startswith(v, i)), key=len)
                out.append(inverse[piece])
                i += len(piece)
            return out

        greedy = [1, 4, 5, 3]  # "It is no longer noise"
        rec = {"text": "It is not noise", "prompt_tokens": 186, "completion_tokens": 3}
        out = served.served_comparison(rec, greedy, lambda t: vocab[t], encode)
        self.assertFalse(out["text_equal"])
        self.assertEqual(out["common_prefix_bytes"], 8)
        self.assertEqual(out["token_index"], 1)
        self.assertEqual((out["oracle_token"], out["served_token"]), (4, 2))
        same = served.served_comparison({"text": "It is no longer noise"}, greedy, lambda t: vocab[t], encode)
        self.assertTrue(same["text_equal"])
        self.assertIsNone(served.served_comparison(None, greedy, None, None))

    def test_served_row_picks_row0_trial0_of_the_1row_cell(self):
        with tempfile.TemporaryDirectory() as d:
            p = Path(d, "provider.jsonl")
            recs = [row(4, 0, 0, "batched"), row(1, 0, 1, "trial 1"), row(1, 0, 0, "the one"),
                    row(1, 0, 0, "other ctx", ctx=4000), {"kind": "aggregate", "rows": 1}]
            p.write_text("".join(json.dumps(r) + "\n" for r in recs))
            self.assertEqual(served.served_row([str(p)], 200)["text"], "the one")
            self.assertEqual(served.served_row(["/nonexistent", str(p)], "4000")["text"], "other ctx")
            self.assertIsNone(served.served_row([str(p)], 999))


class JobKnobTests(unittest.TestCase):
    def job(self, script, **env):
        e = {"PATH": os.environ["PATH"], "HOME": tempfile.gettempdir(), "RUN_ID": "20261120T000000Z", **env}
        r = subprocess.run(["bash", str(LAB / script)], env=e, capture_output=True, text=True, timeout=30)
        return r.returncode, r.stdout

    def test_exactness_plan(self):
        rc, out = self.job("job-qwen4-exactness.sh", EXACT_JOB_CHECK="1")
        self.assertEqual(rc, 0, out)
        plan = [l for l in out.splitlines() if l.startswith("PLAN ")]
        self.assertEqual([l.split()[1] for l in plan],
                         ["engine-tests", "fence-a", "fence-b", "determinism", "served-4000", "parity"])
        # #2448: the fork's Qwen4ExpTests, join and leave included, before any model pass.
        self.assertIn("filter=Qwen4ExpTests", plan[0])
        self.assertIn("required=testRowJoiningADecodingBatchMatchesSerial,testRowLeavingADecodingBatchMatchesSerial",
                      plan[0])
        self.assertIn("FORK=" + tempfile.gettempdir() + "/lab-ablit-perf/mlx-swift-lm-2409 ", plan[0])
        self.assertIn("CB_ROWS=1,4,8,11 CONTEXTS=200 OUTPUTS=512 TRIALS=3 LAB_FENCE=1", plan[1])
        self.assertIn("seed=fresh", plan[1])
        self.assertIn("SKIP_BUILD=1 seed=fence-a", plan[2])
        self.assertIn("CB_ROWS=1 CONTEXTS=4000", plan[4])
        # Without 1-row determinism cells both served contexts need their own pass.
        rc, out = self.job("job-qwen4-exactness.sh", EXACT_JOB_CHECK="1", DET_ROWS="4,8,11")
        self.assertIn("PLAN served-200 ", out)
        rc, out = self.job("job-qwen4-exactness.sh", EXACT_JOB_CHECK="1", RUN_DETERMINISM="0")
        self.assertEqual([l.split()[1] for l in out.splitlines() if l.startswith("PLAN ")],
                         ["engine-tests", "served-200", "served-4000", "parity"])

    def test_exactness_engine_tests_gate_the_job(self):
        text = (LAB / "job-qwen4-exactness.sh").read_text()
        engine = text.index("swift test --skip-build")
        self.assertLess(engine, text.index("step fence-a"))
        self.assertIn("--filter Qwen4ExpTests", text)
        self.assertIn('die "engine tests failed', text)
        self.assertIn("FORK_DIR=$HOME/mlx-swift-lm-2448 JOB_SCRIPT=job-qwen4-exactness.sh",
                      (LAB / "studio-ablit-perf.sh").read_text())

    def test_exactness_bad_knobs(self):
        for env in ({"DET_ROWS": "4,,8"}, {"TRIALS": "1"}, {"SERVED_CONTEXTS": "4k"},
                    {"RUN_DETERMINISM": "0", "RUN_PARITY": "0"}, {"RUN_PARITY": "yes"},
                    {"SEED_SELF_CHECK_RUN": "latest"}):
            rc, out = self.job("job-qwen4-exactness.sh", EXACT_JOB_CHECK="1", **env)
            self.assertEqual(rc, 64, (env, out))
            self.assertIn("BLOCKER:", out)
            self.assertIn("JOB_FAIL", out)

    def test_cb_job_fence_pass_and_seed_file(self):
        rc, out = self.job("job-qwen4-cb.sh", CB_JOB_CHECK="1", LAB_FENCE="1", CB_PASS="fence-b",
                           SEED_SELF_CHECK_FILE="/x/cb-self-check.json", SEED_SELF_CHECK_RUN="20261117T010203Z")
        self.assertEqual(rc, 0, out)
        argv = next(l for l in out.splitlines() if l.startswith("GRID_ARGS"))
        self.assertIn("--lab-fence", argv)
        self.assertIn("--seed-self-check /x/cb-self-check.json", argv)
        self.assertIn("/qwen4-flash-next-cb/fence-b", argv)
        rc, out = self.job("job-qwen4-cb.sh", CB_JOB_CHECK="1")
        self.assertNotIn("--lab-fence", out)
        for env in ({"LAB_FENCE": "yes"}, {"CB_PASS": "Fence A"}):
            rc, out = self.job("job-qwen4-cb.sh", CB_JOB_CHECK="1", **env)
            self.assertEqual(rc, 64, (env, out))

    def test_parity_job_served_knobs_are_validated(self):
        for env in ({"SERVED_CONTEXTS": "4k"}, {"SERVED_STEPS": "0"}):
            rc, out = self.job("job-qwen4-parity.sh", **env)
            self.assertEqual(rc, 64, (env, out))
            self.assertIn("BLOCKER:", out)

    def test_launcher_allowlists_the_job_and_its_knobs(self):
        text = (LAB / "studio-ablit-perf.sh").read_text()
        self.assertIn("|job-qwen4-exactness.sh|", text)
        self.assertIn("job-qwen4-parity.sh|job-qwen4-cb.sh|job-qwen4-exactness.sh) FORK_FILE=", text)
        for name in ("LAB_FENCE", "DET_ROWS", "DET_CONTEXTS", "SERVED_CONTEXTS", "SERVED_STEPS", "STEPS",
                     "RUN_DETERMINISM", "RUN_PARITY"):
            self.assertIn(f"|{name}|", text)
        self.assertIn("|DETERMINISM|DIVERGENCE_VERDICT|", text)
        grid = (GRID / "run-grid.sh").read_text()
        self.assertIn("--lab-fence) LAB_FENCE=1", grid)


if __name__ == "__main__":
    unittest.main()
