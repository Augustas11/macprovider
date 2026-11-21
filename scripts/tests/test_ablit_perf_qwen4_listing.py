"""scripts/lab/ablit-perf: the #2452 Qwen3.8-Flash-Next pre-listing job (static shape and knobs), its memory
report (min_ram_gb rule), the loopback buyer-UX driver and the launcher wiring."""

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
JOB = LAB / "job-qwen4-listing.sh"
LAUNCHER = LAB / "studio-ablit-perf.sh"


def load(name, path):
    spec = importlib.util.spec_from_file_location(name, path)
    mod = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(mod)
    return mod


mem = load("listing_memory", LAB / "listing_memory.py")
bux = load("buyer_ux_local", LAB / "buyer_ux_local.py")
suite = bux.load_suite(ROOT / "scripts")


class JobShapeTests(unittest.TestCase):
    def run_job(self, **env):
        home = tempfile.mkdtemp()
        e = {"PATH": os.environ["PATH"], "HOME": home, "LISTING_JOB_CHECK": "1", "RUN_ID": "20261120T000000Z", **env}
        r = subprocess.run(["bash", str(JOB)], env=e, capture_output=True, text=True, timeout=30)
        return r, home

    def lines(self, out, tag):
        return [l[len(tag) + 1:] for l in out.splitlines() if l.startswith(tag + " ")]

    def test_bash_syntax(self):
        self.assertEqual(subprocess.run(["bash", "-n", str(JOB)]).returncode, 0)

    def test_defaults_serve_the_catalog_id_on_the_production_route(self):
        r, home = self.run_job()
        self.assertEqual(r.returncode, 0, r.stdout + r.stderr)
        cfg = self.lines(r.stdout, "SERVE_CONFIG")[0]
        self.assertIn('model: "qwen/qwen3.8-flash-next-abliterated"', cfg)
        self.assertIn("model_artifact_sha256: f0dfdf5261527e3a64356f95f10c9e906a387f87d85a0d10703692da083043cd", cfg)
        self.assertIn("Qwen3.8-Flash-Next-heretic-2-oQ4e-mtp", cfg)
        self.assertIn("port: 18341", cfg)
        serve = self.lines(r.stdout, "SERVE_ARGS")[0].split()
        self.assertEqual(serve[0], "serve")
        self.assertIn("--no-join", serve)
        # Production route: no lab autotune child, no forced batching mode, no CB tuple.
        self.assertNotIn("--autotune-candidate", serve)
        self.assertFalse(any(a.startswith("--continuous-batching") for a in serve))
        self.assertNotIn("continuous_batching", cfg)
        clients = self.lines(r.stdout, "CLIENT_ARGS")
        self.assertEqual(len(clients), 2)
        self.assertIn("grid-4000.json --trials 1 --rows 1 output=256", clients[0])
        self.assertIn("grid-32000.json --trials 1 --rows 1 output=256", clients[1])
        b = self.lines(r.stdout, "BUX_ARGS")[0]
        self.assertIn("--base http://127.0.0.1:18341/v1 --model qwen/qwen3.8-flash-next-abliterated", b)
        self.assertIn("--served-model latent-variable/Qwen3.8-Flash-Next-heretic-2-oQ4e-mtp", b)
        self.assertIn("--samples 3", b)
        p = self.lines(r.stdout, "PROFILE_ARGS")[0]
        self.assertIn("prefill-profile", p)
        self.assertIn("--prompt-tokens 4000,32000 --step-sizes 512 --runs 1 --generate-tokens 256 --served-only", p)
        self.assertEqual(self.lines(r.stdout, "BUILD_FLAGS")[0],
                         "-D" + "MACPROVIDER_" + "LAB_HARNESS build_path=.build-lab-harness")
        self.assertFalse((Path(home) / "lab-ablit-perf").exists())  # check mode touches nothing

    def test_knobs_reach_the_argv(self):
        r, _ = self.run_job(MEM_CONTEXTS="4096", MEM_OUTPUT="64", BUX_SAMPLES="1", QWEN4_ID="a/b",
                            QWEN4_SHA256="a" * 64, QWEN4_PATH="/m/q")
        self.assertEqual(r.returncode, 0, r.stdout)
        self.assertIn("model_artifact_path: \"/m/q\"", r.stdout)
        self.assertIn("model_artifact_sha256: " + "a" * 64, r.stdout)
        self.assertEqual(len(self.lines(r.stdout, "CLIENT_ARGS")), 1)
        self.assertIn("--samples 1", r.stdout)
        self.assertIn("--prompt-tokens 4096 --step-sizes 512 --runs 1 --generate-tokens 64", r.stdout)

    def test_default_has_no_extra_models(self):
        r, _ = self.run_job()
        self.assertNotIn("EXTRA_", r.stdout)

    def test_extra_models_serve_the_live_row_by_id_and_sha_with_the_same_suite(self):
        r, _ = self.run_job(BUX_EXTRA_MODELS="qwen38-27b,qwen36-27b", BUX_SAMPLES="2")
        self.assertEqual(r.returncode, 0, r.stdout)
        cfgs = self.lines(r.stdout, "EXTRA_SERVE_CONFIG")
        self.assertEqual(len(cfgs), 2)
        self.assertIn('model: "qwen/qwen3.8-27b"', cfgs[0])
        self.assertIn("model_artifact_sha256: 8a8786e902127e9175f5be0d7c8bcf4dd32323a0521e4d9a20761608a07a6d05", cfgs[0])
        self.assertIn("lab-ablit-perf/models/Qwen3.8-27B-4bit", cfgs[0])
        self.assertIn('model: "qwen/qwen3.6-27b"', cfgs[1])
        self.assertIn("model_artifact_sha256: 518ef47c298783d8547b50406e84548e5bf7705b82355a38f9eaef1368817931", cfgs[1])
        for line in self.lines(r.stdout, "EXTRA_SERVE_ARGS"):
            self.assertIn("serve --config", line)
            self.assertTrue(line.endswith("--no-join"))
            self.assertNotIn("continuous", line)
        bux_lines = self.lines(r.stdout, "EXTRA_BUX_ARGS")
        self.assertEqual(len(bux_lines), 2)
        self.assertIn("--catalog-key qwen/qwen3.8-27b --out", bux_lines[0])
        self.assertIn("--served-model mlx-community/Qwen3.8-27B-4bit", bux_lines[0])
        for line in bux_lines:
            self.assertIn("--samples 2", line)
            self.assertIn("--capture", line)
            self.assertIn("--max-context-tokens", line)
        self.assertEqual(len(self.lines(r.stdout, "CLIENT_ARGS")), 2)  # memory cells stay Flash-Next only

    def test_unknown_extra_model_is_refused(self):
        r, _ = self.run_job(BUX_EXTRA_MODELS="qwen38-27b-uncensored")
        self.assertEqual(r.returncode, 64, r.stdout)
        self.assertIn("BLOCKER:", r.stdout)

    def test_bad_knobs_are_refused(self):
        for env in ({"MEM_CONTEXTS": "4k"}, {"MEM_CONTEXTS": "100"}, {"MEM_CONTEXTS": "4000,,8000"},
                    {"MEM_CONTEXTS": "200000"}, {"MEM_OUTPUT": "8"}, {"MEM_OUTPUT": "x"}, {"BUX_SAMPLES": "0"},
                    {"BUX_SAMPLES": "10"}, {"QWEN4_SHA256": "ABC"}, {"QWEN4_ID": "Qwen/X"}):
            r, _ = self.run_job(**env)
            self.assertEqual(r.returncode, 64, (env, r.stdout))
            self.assertIn("BLOCKER:", r.stdout)
            self.assertIn("JOB_FAIL", r.stdout)

    def test_static_shape(self):
        text = JOB.read_text()
        for want in ("JOB_PASS", "JOB_FAIL", "route_status.py\" gate", "--expect any",
                     "'^ROUTE batching=serial '", "listing_memory.py\" sample", "listing_memory.py\" report",
                     "buyer_ux_local.py", "IDENTITY_STATUS", "family=qwen4_exp", "LISTING_MIN_RAM_GB",
                     "snapshot_manifest_sha256", "= 21 ]", "live.malibu.provider"):
            self.assertIn(want, text, want)
        # Never pauses or restarts live, never sets a wall-clock deadline.
        for banned in ("launchctl bootout", "launchctl kickstart", "runner-reserve", "timeout "):
            self.assertNotIn(banned, text, banned)


class MemoryTests(unittest.TestCase):
    def test_rule_reproduces_the_precedent_rows(self):
        self.assertEqual(mem.proposed_min_ram_gb(int(199.5 * 2**30), 256 * 2**30)[0], 230)  # MiniMax M3.1-Flash
        self.assertEqual(mem.proposed_min_ram_gb(int(70.0 * 2**30), 96 * 2**30)[0], 84)  # Nemotron 3.5 Bolt
        self.assertEqual(mem.proposed_min_ram_gb(100 * 2**30, 256 * 2**30), (130, 100.0, 25.6))

    def test_report_takes_the_serve_lifetime_peak_and_mlx_peaks(self):
        samples = [
            {"label": "serve loaded", "phys_footprint": 110 * 2**30, "lifetime_max_phys_footprint": 112 * 2**30,
             "resident_size": 2**30},
            {"label": "serve after ctx=32000", "phys_footprint": 115 * 2**30,
             "lifetime_max_phys_footprint": 130 * 2**30, "resident_size": 2**30},
            {"label": "prefill-profile", "phys_footprint": 150 * 2**30, "lifetime_max_phys_footprint": 150 * 2**30,
             "resident_size": 2**30},
        ]
        profile = {"model_family": "qwen4_exp", "serve_default_step": 512,
                   "prompts": [{"tokens": 4000, "served": [{"step": 512, "mlx_peak_bytes": 120e9}]},
                               {"tokens": 32000, "served": [{"step": 512, "mlx_peak_bytes": 128.04e9}]}]}
        r = mem.build_report(samples, profile, 256 * 2**30)
        self.assertEqual(r["serve_lifetime_peak_gib"], 130.0)
        self.assertEqual(r["proposed_min_ram_gb"], 160)  # ceil(130 + 25.6 + 4); the profile process is not the serve
        self.assertEqual([m["mlx_peak_gb"] for m in r["mlx_peak"]], [120.0, 128.0])
        self.assertEqual(r["profile_family"], "qwen4_exp")
        md = mem.markdown(r)
        self.assertIn("| serve after ctx=32000 | 115.0 | 130.0 | 1.0 |", md)
        self.assertIn("| 32000 | 512 | 128.0 |", md)
        self.assertIn("= 160", md)
        with self.assertRaises(ValueError):
            mem.build_report(samples[2:], profile, 256 * 2**30)

    @unittest.skipUnless(sys.platform == "darwin", "proc_pid_rusage is macOS only")
    def test_rusage_reads_this_process(self):
        r = mem.rusage(os.getpid())
        self.assertGreater(r["phys_footprint"], 1 << 20)
        self.assertGreaterEqual(r["lifetime_max_phys_footprint"], r["phys_footprint"])
        self.assertGreater(r["resident_size"], 1 << 20)


def fake_transport(content="{\"color\": \"blue\"}", leak=False):
    """A loopback serve that passes every check (or leaks <think> markup into content)."""
    tool_call = {"id": "call_1", "type": "function", "function": {"name": "read_file", "arguments": "{\"path\": \"/etc/hosts\"}"}}

    def resp(body, status=200):
        return suite.Response(status, json.dumps(body).encode())

    def send(method, path, headers, body):
        if path == "/models":
            return resp({"data": [{"id": "qwen/q", "max_context_tokens": 1000}]})
        if path == "/messages":
            return resp({"type": "message", "content": [{"type": "text", "text": "4"}]})
        if path == "/responses":
            return resp({"output": [{"type": "function_call", "name": "read_file", "call_id": "c1"}]})
        msgs = body["messages"]
        text = msgs[-1]["content"]
        if body.get("max_tokens") == 16:
            return resp({"error": {"code": "context_length_exceeded", "message": "too long"}}, 400)
        if body.get("stream"):
            events = [{"choices": [{"index": 0, "delta": {"tool_calls": [{**tool_call, "index": i, "id": f"c{i}"}]}}]}
                      for i in range(2)]
            events.append({"choices": [{"index": 0, "delta": {}, "finish_reason": "tool_calls"}],
                           "usage": {"completion_tokens": 5}})
            data = "".join(f"data: {json.dumps(e)}\n\n" for e in events) + "data: [DONE]\n\n"
            return suite.Response(200, data.encode())
        if any(m["role"] == "tool" for m in msgs):
            message = {"role": "assistant", "content": "The hosts file maps localhost."}
            return resp({"choices": [{"message": message, "finish_reason": "stop"}]})
        if body.get("tools"):
            return resp({"choices": [{"message": {"role": "assistant", "tool_calls": [tool_call]}, "finish_reason": "tool_calls"}]})
        if body.get("response_format"):
            return resp({"choices": [{"message": {"content": content}, "finish_reason": "stop"}]})
        if body.get("stop"):
            return resp({"choices": [{"message": {"content": "1, 2, 3, 4, 5, 6, "}, "finish_reason": "stop"}]})
        if body.get("max_tokens") == 8:
            return resp({"choices": [{"message": {"content": "Once"}, "finish_reason": "length"}]})
        answer = "<think>x</think>4" if leak else "4"
        return resp({"choices": [{"message": {"content": answer}, "finish_reason": "stop"}],
                     "usage": {"completion_tokens_details": {"reasoning_tokens": 0}}})
    return send


class BuyerUXLocalTests(unittest.TestCase):
    def run_driver(self, transport):
        with tempfile.TemporaryDirectory() as d:
            out = Path(d) / "rec.json"
            rc, lines = bux.run(suite, transport, "qwen/q", "latent-variable/Qwen3.8-Flash-Next-heretic-2-oQ4e-mtp",
                                "qwen/q", "http://127.0.0.1:18341/v1", out, 1)
            doc = json.loads(out.read_text()) if out.exists() else None
        return rc, lines, doc

    def test_a_conforming_serve_writes_a_valid_record_and_passes_the_gate(self):
        rc, lines, doc = self.run_driver(fake_transport())
        self.assertEqual(rc, 0, lines)
        self.assertEqual(lines[-1], "BUX_GATE pass")
        rec = doc["records"]["qwen/q"]
        self.assertEqual(rec["model"], "latent-variable/Qwen3.8-Flash-Next-heretic-2-oQ4e-mtp")
        self.assertIn("loopback", rec["gateway"])
        self.assertEqual(doc["schema_version"], suite.SCHEMA)
        self.assertTrue(rec["capabilities"]["tools"])
        self.assertEqual(len([l for l in lines if l.startswith("BUX_CHECK ")]), len(suite.ALL_CHECKS))

    def test_a_reasoning_leak_fails_the_gate(self):
        rc, lines, _ = self.run_driver(fake_transport(leak=True))
        self.assertEqual(rc, 1)
        self.assertTrue(lines[-1].startswith("BUX_GATE fail"), lines[-1])
        self.assertIn("BUX_CHECK no_reasoning_leak fail", "\n".join(lines))

    def test_cli_refuses_a_non_loopback_base(self):
        self.assertEqual(bux.main(["--suite-dir", str(ROOT / "scripts"), "--base", "https://api.malibu.tech/v1",
                                   "--model", "a/b", "--served-model", "a/b", "--catalog-key", "a/b",
                                   "--out", "/dev/null"]), 2)


class ContextLimitTests(unittest.TestCase):
    """20261120T123728Z: the loopback /models row had no max_context_tokens, so the suite's
    over-limit prompt (2 x its 32768 default) fit the 200000-token serve and got HTTP 200."""

    def serve(self, limit, rows=None):
        seen = []

        def send(method, path, headers, body):
            if path == "/models":
                return suite.Response(200, json.dumps({"data": rows or [{"id": "qwen/q"}]}).encode())
            words = body["messages"][-1]["content"].count("lorem ipsum")
            seen.append(words)
            if words * 2 > limit:  # about two tokens per repetition
                return suite.Response(413, json.dumps({"error": {"code": "context_length_exceeded",
                                                                 "message": "Request body too large"}}).encode())
            return suite.Response(200, json.dumps({"choices": [{"message": {"content": "x"},
                                                                "finish_reason": "length"}]}).encode())
        return send, seen

    def test_without_the_limit_the_suite_prompt_fits_a_large_serve(self):
        send, seen = self.serve(200000)
        status, _ = suite.check_context_limit_error(send, "qwen/q", int(suite.model_entry(send, "qwen/q").get(
            "max_context_tokens") or 32768))
        self.assertEqual(status, suite.FAIL)
        self.assertEqual(seen, [65536])

    def test_the_serve_limit_on_the_models_row_puts_the_prompt_past_it(self):
        send, seen = self.serve(200000)
        wrapped = bux.with_context_limit(suite, send, "qwen/q", 200000)
        entry = suite.model_entry(wrapped, "qwen/q")
        self.assertEqual(entry["max_context_tokens"], 200000)
        self.assertEqual(suite.check_context_limit_error(wrapped, "qwen/q", entry["max_context_tokens"]),
                         (suite.PASS, "context_length_exceeded"))
        self.assertEqual(seen, [400000])

    def test_a_row_that_already_carries_a_limit_and_other_rows_are_untouched(self):
        rows = [{"id": "qwen/q", "max_context_tokens": 1000}, {"id": "other"}]
        send, _ = self.serve(200000, rows)
        data = bux.with_context_limit(suite, send, "qwen/q", 200000)("GET", "/models", {}, None).json()["data"]
        self.assertEqual(data, rows)

    def test_the_job_passes_the_serve_limit_to_the_driver(self):
        text = JOB.read_text()
        self.assertIn('BUX_ARGS+=(--max-context-tokens "$SERVE_MAX_CTX" --capture "$RES/buyer-ux-responses.jsonl")', text)
        self.assertLess(text.index("SERVE_MAX_CTX=$("), text.index('BUX_ARGS+=(--max-context-tokens'))

    def test_capture_records_each_post_answer(self):
        send, _ = self.serve(200000)
        with tempfile.TemporaryDirectory() as d:
            path = Path(d) / "responses.jsonl"
            wrapped = bux.capturing(send, path)
            wrapped("GET", "/models", {}, None)
            wrapped("POST", "/chat/completions", {}, {"messages": [{"role": "user", "content": "hi"}],
                                                      "tool_choice": "required"})
            lines = [json.loads(l) for l in path.read_text().splitlines()]
        self.assertEqual(len(lines), 1)
        self.assertEqual((lines[0]["path"], lines[0]["tool_choice"], lines[0]["status"]),
                         ("/chat/completions", "required", 200))
        self.assertIn("finish_reason", lines[0]["body"])

    def test_cli_refuses_a_negative_limit(self):
        self.assertEqual(bux.main(["--suite-dir", str(ROOT / "scripts"), "--base", "http://127.0.0.1:1/v1",
                                   "--model", "a/b", "--served-model", "a/b", "--catalog-key", "a/b",
                                   "--out", "/dev/null", "--max-context-tokens", "-1"]), 2)


class LauncherTests(unittest.TestCase):
    def test_launcher_admits_the_job_its_knobs_and_the_suite(self):
        text = LAUNCHER.read_text()
        self.assertIn("|job-qwen4-cb.sh|job-qwen4-listing.sh|", text)
        self.assertIn("|MEM_CONTEXTS|MEM_OUTPUT|BUX_SAMPLES|", text)
        self.assertIn('rsync -a "$REPO/scripts/buyer_ux_conformance.py" macstudio:lab-ablit-perf/job/bux/', text)
        self.assertIn("scripts/buyer_ux_conformance.py)", text)  # in the uncommitted-changes check
        self.assertIn("|LISTING_|IDENTITY|MEM_|BUX_|", text)

    def test_launcher_refuses_an_unknown_job_before_ssh(self):
        r = subprocess.run(["bash", str(LAUNCHER)], env={**os.environ, "JOB_SCRIPT": "job-nope.sh"},
                           capture_output=True, text=True)
        self.assertEqual(r.returncode, 2)
        self.assertIn("job-qwen4-listing.sh", r.stderr)


class BuyerUxInterpreterTest(unittest.TestCase):
    def test_buyer_ux_driver_runs_on_python_312_not_system_python(self):
        text = JOB.read_text()
        self.assertNotIn('/usr/bin/python3 -I "$JOB/ablit-perf/buyer_ux_local.py"', text)
        self.assertIn('"$PY_BUX" -B -I "$JOB/ablit-perf/buyer_ux_local.py"', text)

if __name__ == "__main__":
    unittest.main()
