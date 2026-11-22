"""scripts/lab/ablit-perf: #2459 native MTP vs ordinary decode on the cached turn-2 path
(mtp_turn2_compare.py, job.sh native_mtp=off passes, launcher allowlist)."""

import contextlib
import importlib.util
import io
import json
import subprocess
import tempfile
import unittest
from pathlib import Path

LAB = Path(__file__).resolve().parents[1] / "lab" / "ablit-perf"
JOB = LAB / "job.sh"
LAUNCHER = LAB / "studio-ablit-perf.sh"

spec = importlib.util.spec_from_file_location("mtp_turn2_compare", LAB / "mtp_turn2_compare.py")
cmp = importlib.util.module_from_spec(spec)
spec.loader.exec_module(cmp)


def row(turn, trial, text="once upon", reasoning="", tokens=512, cached=None, prompt=29700, tps=30.0,
        ttft=1.0, proposed=None, out=512):
    r = {"kind": "row", "ctx_target": 34000, "max_tokens": out, "rows": 1, "row": 0, "trial": trial,
         "turn": turn, "text": text, "reasoning_text": reasoning, "completion_tokens": tokens,
         "prompt_tokens": prompt if turn == 1 else prompt + tokens + 40, "decode_tps": tps, "ttft_s": ttft,
         "cached_prompt_tokens": (prompt if cached is None else cached) if turn == 2 else 0, "error": None}
    if turn == 2 and proposed is not None:
        r["native_mtp_turn2"] = {"acceptance_valid": True, "proposed_tokens": proposed,
                                 "accepted_tokens": proposed // 2}
    return r


def write_pass(d, rows, native=None):
    (d / "serve").mkdir(parents=True, exist_ok=True)
    with open(d / "provider.jsonl", "w") as f:
        for r in rows:
            f.write(json.dumps(r) + "\n")
        f.write(json.dumps({"kind": "aggregate", "ctx_target": 34000}) + "\n")
    status = {"model_loaded": True}
    if native is not None:
        status["native_mtp"] = {"enabled": native, "mode": "eligible" if native else "off"}
    (d / "serve" / "status.json").write_text(json.dumps(status))


class CompareTests(unittest.TestCase):
    def setUp(self):
        self.tmp = Path(tempfile.mkdtemp())
        self.addCleanup(lambda: __import__("shutil").rmtree(self.tmp, ignore_errors=True))

    def run_cmp(self, native_rows, ordinary_rows=None, ordinary_native=False, cold_rows=None, cold_native=False):
        write_pass(self.tmp / "mtp", native_rows, native=True)
        args = ["--native", str(self.tmp / "mtp"), "--json", str(self.tmp / "out.json")]
        if ordinary_rows is not None:
            write_pass(self.tmp / "off", ordinary_rows, native=ordinary_native)
            args += ["--ordinary", str(self.tmp / "off")]
        if cold_rows is not None:
            write_pass(self.tmp / "cold", cold_rows, native=cold_native)
            args += ["--cold", str(self.tmp / "cold")]
        buf = io.StringIO()
        with contextlib.redirect_stdout(buf):
            rc = cmp.main(args)
        return rc, buf.getvalue()

    def pair(self, **native_t2):
        native = [row(1, t, tps=40.0, ttft=110.0) for t in range(3)] + \
                 [row(2, t, tps=40.0, ttft=4.0, **{"proposed": 600, **native_t2}) for t in range(3)]
        ordinary = [row(1, t, ttft=111.0) for t in range(3)] + [row(2, t, ttft=5.0) for t in range(3)]
        return native, ordinary

    def test_identical_pairs_pass_with_speed_ratio(self):
        rc, out = self.run_cmp(*self.pair())
        self.assertEqual(rc, 0, out)
        self.assertIn("T2_VERDICT PASS", out)
        cell = json.loads((self.tmp / "out.json").read_text())["cells"][0]
        self.assertTrue(cell["t1_parity"] and cell["t2_parity"])
        self.assertEqual(cell["t2_decode_ratio"], round(40 / 30, 4))
        self.assertEqual((cell["native"]["t2_ttft_s"], cell["ordinary"]["t2_ttft_s"]), (4.0, 5.0))
        self.assertEqual(cell["native"]["t2_proposed"], 1800)
        self.assertEqual(cell["native"]["t2_acceptance"], 0.5)

    def test_turn2_text_or_token_difference_fails(self):
        for change in ({"text": "once upon a"}, {"tokens": 511}, {"reasoning": "hm"}):
            native, ordinary = self.pair()
            native[4] = row(2, 1, proposed=600, **change)
            rc, out = self.run_cmp(native, ordinary)
            self.assertEqual(rc, 1, change)
            self.assertIn("turn 2: 1/3 pairs differ (trial 1 row 0", out)
            self.assertIn("T2_VERDICT FAIL", out)

    def test_turn1_difference_fails_and_unpaired_rows_fail(self):
        native, ordinary = self.pair()
        native[0] = row(1, 0, text="other")
        rc, out = self.run_cmp(native, ordinary)
        self.assertEqual(rc, 1)
        self.assertIn("turn 1: 1/3 pairs differ", out)
        native, ordinary = self.pair()
        rc, out = self.run_cmp(native, ordinary[:-1])
        self.assertEqual(rc, 1)
        self.assertIn("unpaired row", out)

    def test_cache_cap_counters_and_control_checks(self):
        native, ordinary = self.pair(cached=0)
        self.assertIn("native: a turn-2 row reports 0 cached tokens", self.run_cmp(native, ordinary)[1])
        native, ordinary = self.pair(prompt=32300)
        self.assertIn("above the cap 32768", self.run_cmp(native, ordinary)[1])
        native, ordinary = self.pair(proposed=0)
        self.assertIn("no token proposed on turn 2", self.run_cmp(native, ordinary)[1])
        native, ordinary = self.pair()
        for r in native:
            r.pop("native_mtp_turn2", None)
        self.assertIn("no turn-2 native_mtp counters", self.run_cmp(native, ordinary)[1])
        native, ordinary = self.pair()
        rc, out = self.run_cmp(native, ordinary, ordinary_native=True)
        self.assertEqual(rc, 1)
        self.assertIn("ordinary: serve status does not show native MTP off", out)

    def test_cache_only_key_and_conversation_cache_hits(self):
        native, ordinary = self.pair()
        for r in native + ordinary:
            if r["turn"] == 2:
                r.update(conversation_key_sent=True, conversation_cache_only=True,
                         conversation_cache_turn2={"valid": True, "lookups": 1, "hits": 1,
                                                   "cached_prompt_tokens": 29700})
                r["native_mtp_turn2"] = {**r.get("native_mtp_turn2", {}), "last_reason": "active"}
        rc, out = self.run_cmp(native, ordinary)
        self.assertEqual(rc, 0, out)
        self.assertIn("cache_hits_t2=3/3 cache_only_rows_t2=3 mtp_last_reason_t2=active", out)
        # A trial without a conversation-cache hit on turn 2 fails, on either side.
        native[3]["conversation_cache_turn2"] = {"valid": True, "lookups": 1, "hits": 0, "cached_prompt_tokens": 0}
        ordinary[5]["conversation_cache_turn2"] = {"valid": True, "lookups": 1, "hits": 0, "cached_prompt_tokens": 0}
        rc, out = self.run_cmp(native, ordinary)
        self.assertEqual(rc, 1)
        self.assertIn("native: 1 trial(s) show no conversation-cache hit on turn 2", out)
        self.assertIn("ordinary: 1 trial(s) show no conversation-cache hit on turn 2", out)
        # A sticky key (TURN2_HEADER=1) on the native side fails loudly.
        native, ordinary = self.pair()
        for r in native:
            if r["turn"] == 2:
                r.update(conversation_key_sent=True, conversation_cache_only=False)
        rc, out = self.run_cmp(native, ordinary)
        self.assertEqual(rc, 1)
        self.assertIn("3 turn-2 row(s) sent a sticky conversation key", out)

    def test_keyed_ordinary_must_equal_keyless_cold(self):
        native, ordinary = self.pair()
        cold = [row(1, t) for t in range(3)] + [row(2, t, cached=0) for t in range(3)]
        rc, out = self.run_cmp(native, ordinary, cold_rows=cold)
        self.assertEqual(rc, 0, out)
        self.assertIn("cold_parity_t1=True cold_parity_t2=True", out)
        # Default (no --cold) output is unchanged apart from the empty cold fields.
        rc, out = self.run_cmp(native, ordinary)
        self.assertEqual(rc, 0, out)
        self.assertIn("cold_parity_t1=- cold_parity_t2=-", out)
        # A keyed turn-2 token difference from the cold run fails even when mtp == off.
        bad = list(cold)
        bad[4] = row(2, 1, cached=0, tokens=511)
        rc, out = self.run_cmp(native, ordinary, cold_rows=bad)
        self.assertEqual(rc, 1)
        self.assertIn("keyed vs cold: turn 2: 1/3 pairs differ (trial 1 row 0", out)
        self.assertIn("cold_parity_t2=False", out)
        # A cold pass that sent a key, or ran native MTP, is not the control.
        keyed = [dict(r, conversation_key_sent=True) for r in cold]
        rc, out = self.run_cmp(native, ordinary, cold_rows=keyed)
        self.assertEqual(rc, 1)
        self.assertIn("cold: 6 row(s) sent a conversation key", out)
        rc, out = self.run_cmp(native, ordinary, cold_rows=cold, cold_native=True)
        self.assertEqual(rc, 1)
        self.assertIn("cold: serve status does not show native MTP off", out)
        with self.assertRaises(SystemExit):
            with contextlib.redirect_stderr(io.StringIO()):
                cmp.main(["--native", str(self.tmp / "mtp"), "--cold", str(self.tmp / "cold")])

    def test_native_only_probe_and_unusable_input(self):
        native, _ = self.pair()
        rc, out = self.run_cmp(native)
        self.assertEqual(rc, 0, out)
        self.assertIn("parity_t2=- ", out)
        rc, out = self.run_cmp([row(1, 0)])
        self.assertEqual(rc, 2)
        self.assertIn("no turn-2 rows", out)


def extract(names):
    """The bodies of the named job.sh functions (name() { ... } up to the first column-0 `}`)."""
    lines, out, keep = JOB.read_text().splitlines(), [], False
    for line in lines:
        start = any(line.startswith(f"{n}() {{") for n in names)
        keep = keep or start
        if keep:
            out.append(line)
            if line == "}" or (start and line.rstrip().endswith("}")):  # one-line functions end there
                keep = False
    return "\n".join(out)


class JobPassTests(unittest.TestCase):
    def bash(self, script, extra_funcs=(), **env):
        d = tempfile.mkdtemp()
        self.addCleanup(lambda: __import__("shutil").rmtree(d, ignore_errors=True))
        if True:
            harness = Path(d) / "h.sh"
            harness.write_text("set -u\n" + extract(["kname", "v", "setv", "serve_knob_check", "parse_pass",
                                                     "native_mtp_extra", *extra_funcs])
                               + f"\nJOB={d}/job\nSTORE={d}/store\nCONTEXTS=short\nOUTPUTS=512\nTRIALS=3\n" + script)
            job = Path(d) / "job" / "catalog"
            job.mkdir(parents=True)
            (job / "autotune-candidates.json").write_text(json.dumps({"version": "v9", "rows": {
                "qwen/qwen3.8-27b": {"model_id": "mlx-community/Qwen3.8-27B-4bit", "model_revision": "rev",
                                     "model_sha256": "s" * 64}}}))
            art = Path(d) / "store" / "mlx-community--Qwen3.8-27B-4bit" / "rev" / ("s" * 64)
            art.mkdir(parents=True)
            (art / "config.json").write_text("{}")
            return subprocess.run(["bash", str(harness)], capture_output=True, text=True, timeout=30,
                                  env={"PATH": "/usr/bin:/bin", "HOME": d, "QWEN38_27B_ID": "qwen/qwen3.8-27b",
                                       "QWEN38_27B_SHA256": "s" * 64, **env}), d

    def test_native_mtp_off_pass_writes_the_same_catalog_lines_with_mode_off(self):
        p, d = self.bash('parse_pass qwen38-27b "off rows=1 native_mtp=off" || { echo "ERR $KNOB_ERR"; exit 1; }\n'
                         'echo "P $P_NAME $P_NM $P_ROWS"\n'
                         'for m in off auto; do setv qwen38-27b NATIVE_MTP $m\n'
                         '  native_mtp_extra qwen38-27b "$JOB/$m.yaml"; done\n'
                         'parse_pass qwen38-27b "x native_mtp=on" || echo "ERR $KNOB_ERR"\n')
        self.assertEqual(p.returncode, 0, p.stderr)
        self.assertIn("P off off 1", p.stdout)
        self.assertIn("ERR NATIVE_MTP must be auto or off", p.stdout)
        p2, _ = self.bash('parse_pass qwen38-27b "cold rows=1 native_mtp=off turn2_header=0" || exit 1\n'
                          'echo "T [$P_T2H]"\n'
                          'parse_pass qwen38-27b "mtp rows=1" || exit 1\necho "D [$P_T2H]"\n'
                          'parse_pass qwen38-27b "x turn2_header=sticky" || echo "ERR $KNOB_ERR"\n')
        self.assertEqual(p2.returncode, 0, p2.stderr)
        self.assertIn("T [0]", p2.stdout)
        self.assertIn("D []", p2.stdout)
        self.assertIn("ERR turn2_header must be 0|1|cache_only", p2.stdout)
        durable = f"{d}/store/mlx-community--Qwen3.8-27B-4bit/rev/{'s' * 64}"
        self.assertEqual(p.stdout.count(durable), 2)
        off = (Path(d) / "job" / "off.yaml").read_text().splitlines()
        auto = (Path(d) / "job" / "auto.yaml").read_text().splitlines()
        self.assertEqual(off[0], "native_mtp_mode: off")
        self.assertEqual(auto[0], "native_mtp_mode: auto")
        self.assertEqual(off[1:], auto[1:])

    def test_small_m_route_pass_writes_the_row_invariant_route_into_the_serve_extra(self):
        p, d = self.bash('parse_pass qwen38-27b "rowinv rows=1 native_mtp=off small_m_route=row_invariant" '
                         '|| { echo "ERR $KNOB_ERR"; exit 1; }\n'
                         'echo "P $P_NAME $P_NM [$P_SMR]"\n'
                         'parse_pass qwen38-27b "mtp rows=1" || exit 1\necho "D [$P_SMR]"\n'
                         'parse_pass qwen38-27b "x small_m_route=stock" || echo "ERR $KNOB_ERR"\n'
                         'RES=$JOB/res; QWEN38_27B_NAME=qwen3.8-27b; QWEN38_27B_PATH=/m\n'
                         'setv qwen38-27b SMALL_M_ROUTE row_invariant\n'
                         'SERVE_TAG=rowinv serve_args qwen38-27b || exit 1\necho "S ${SERVE[*]}"\n'
                         'cat "$RES/qwen3.8-27b/serve-extra-rowinv.yaml"\n',
                         extra_funcs=["serve_args"])
        self.assertEqual(p.returncode, 0, p.stderr)
        self.assertIn("P rowinv off [row_invariant]", p.stdout)
        self.assertIn("D []", p.stdout)
        self.assertIn("ERR small_m_route must be row_invariant", p.stdout)
        self.assertIn(f"--config-extra {d}/job/res/qwen3.8-27b/serve-extra-rowinv.yaml", p.stdout)
        self.assertTrue(p.stdout.rstrip().endswith("small_m_route: row_invariant"), p.stdout)

    def test_job_wires_turns_compare_and_qwen_keys(self):
        text = JOB.read_text()
        self.assertIn('--trials "$TRIALS" --turns "$TURNS" "$@")', text)
        self.assertIn('[ "$P_NM" != auto ] || extra+=(--expect-native-mtp on)', text)
        self.assertIn("extra+=(--skip-compare)", text)
        self.assertIn("mtp_turn2_compare.py", text)
        self.assertIn('TURN2_HEADER=${P_T2H:-${TURN2_HEADER:-0}} grid "$k"', text)
        self.assertIn('[ -z "${3:-}" ] || dirs+=(--cold "$RES/$name/$3")', text)
        for k in ("QWEN38_27B", "QWEN36_27B"):
            self.assertIn(f': "${{{k}_ID:=qwen/qwen3.', text)
        self.assertNotIn("PASSES needs REUSE_REFERENCE", text)

    def test_launcher_passes_the_turn_knobs(self):
        text = LAUNCHER.read_text()
        for name in ("TURNS", "TURN2_HEADER", "TURN2_HISTORY", "TURN2_FOLLOWUP", "MTP_T2_COMPARE"):
            self.assertIn(f"|{name}|", text)
        # The #2459 probe and full commands send the live cached-turn key, not the sticky one.
        self.assertEqual(text.count("TURN2_HEADER=cache_only TURN2_FOLLOWUP=continue"), 2)
        self.assertNotIn("TURN2_HEADER=1 TURN2_FOLLOWUP=continue", text)
        # The full command adds the keyless cold control; the probe runs the native pass only.
        self.assertIn("cold rows=1 native_mtp=off turn2_header=0' \\\n#          MTP_T2_COMPARE='mtp off cold'", text)
        self.assertIn("QWEN38_27B_PASSES='mtp rows=1 native_mtp=auto' MTP_T2_COMPARE=mtp studio-ablit-perf.sh", text)

    def test_serve_env_reaches_the_serve(self):
        launcher, job = LAUNCHER.read_text(), JOB.read_text()
        grid = (LAB.parent / "parity-grid" / "run-grid.sh").read_text()
        self.assertIn("|SERVE_ENV|", launcher)
        self.assertIn('[ -z "${SERVE_ENV:-}" ] || SERVE+=(--serve-env "$SERVE_ENV")', job)
        self.assertIn('--serve-env) SERVE_ENV="$2"; shift 2 ;;', grid)
        self.assertIn('exec env "${ENV_ARGS[@]}" "$BIN_DIR/macprovider-cli" serve', grid)

    def test_launcher_streams_every_serve_err_live_and_stops_with_the_job(self):
        text = LAUNCHER.read_text()
        self.assertIn('"${SSH[@]}" "bash -s $PID $RUN_ID" > "$RES/$RUN_ID/serve-err.live.log"', text)
        self.assertIn('[ -z "$STREAM_PID" ] || kill "$STREAM_PID"', text)
        # The stream starts after the job pid is known and before the progress loop.
        self.assertLess(text.index('say "remote job pid=$PID"'), text.index("STREAM_PID=$!"))
        self.assertLess(text.index("STREAM_PID=$!"), text.index("seen=0; stalled=0"))
        remote = text.split("<<'STREAM' &\n", 1)[1].split("\nSTREAM\n", 1)[0]
        with tempfile.TemporaryDirectory() as d:
            serve = Path(d) / "lab-ablit-perf" / "results" / "R1" / "m"
            (serve / "main" / "serve").mkdir(parents=True)
            # Detached like the remote job (no zombie for kill -0 to see after it exits).
            job = int(subprocess.run(["bash", "-c", "sleep 5 >/dev/null 2>&1 & echo $!"],
                                     capture_output=True, text=True, check=True).stdout)
            writer = subprocess.Popen(["bash", "-c",
                                       f"sleep 1; echo one > {serve}/main/serve/serve.err; sleep 1; "
                                       f"echo two >> {serve}/main/serve/serve.err; mkdir -p {serve}/b/serve; "
                                       f"echo three > {serve}/b/serve/serve.err"])
            p = subprocess.run(["bash", "-s", str(job), "R1"], input=remote, capture_output=True,
                               text=True, timeout=30, env={"HOME": d, "PATH": "/usr/bin:/bin"})
            writer.wait()
        self.assertEqual(p.returncode, 0, p.stderr)
        self.assertEqual(p.stdout.splitlines(), ["R1/m/main/serve/serve.err: one",
                                                 "R1/m/main/serve/serve.err: two",
                                                 "R1/m/b/serve/serve.err: three"])


if __name__ == "__main__":
    unittest.main()
