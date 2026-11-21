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

    def run_cmp(self, native_rows, ordinary_rows=None, ordinary_native=False):
        write_pass(self.tmp / "mtp", native_rows, native=True)
        args = ["--native", str(self.tmp / "mtp"), "--json", str(self.tmp / "out.json")]
        if ordinary_rows is not None:
            write_pass(self.tmp / "off", ordinary_rows, native=ordinary_native)
            args += ["--ordinary", str(self.tmp / "off")]
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
    def bash(self, script, **env):
        d = tempfile.mkdtemp()
        self.addCleanup(lambda: __import__("shutil").rmtree(d, ignore_errors=True))
        if True:
            harness = Path(d) / "h.sh"
            harness.write_text("set -u\n" + extract(["kname", "v", "setv", "serve_knob_check", "parse_pass",
                                                     "native_mtp_extra"])
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
        durable = f"{d}/store/mlx-community--Qwen3.8-27B-4bit/rev/{'s' * 64}"
        self.assertEqual(p.stdout.count(durable), 2)
        off = (Path(d) / "job" / "off.yaml").read_text().splitlines()
        auto = (Path(d) / "job" / "auto.yaml").read_text().splitlines()
        self.assertEqual(off[0], "native_mtp_mode: off")
        self.assertEqual(auto[0], "native_mtp_mode: auto")
        self.assertEqual(off[1:], auto[1:])

    def test_job_wires_turns_compare_and_qwen_keys(self):
        text = JOB.read_text()
        self.assertIn('--trials "$TRIALS" --turns "$TURNS" "$@")', text)
        self.assertIn('[ "$P_NM" != auto ] || extra+=(--expect-native-mtp on)', text)
        self.assertIn("extra+=(--skip-compare)", text)
        self.assertIn("mtp_turn2_compare.py", text)
        for k in ("QWEN38_27B", "QWEN36_27B"):
            self.assertIn(f': "${{{k}_ID:=qwen/qwen3.', text)
        self.assertNotIn("PASSES needs REUSE_REFERENCE", text)

    def test_launcher_passes_the_turn_knobs(self):
        text = LAUNCHER.read_text()
        for name in ("TURNS", "TURN2_HEADER", "TURN2_HISTORY", "TURN2_FOLLOWUP", "MTP_T2_COMPARE"):
            self.assertIn(f"|{name}|", text)


if __name__ == "__main__":
    unittest.main()
