"""scripts/lab/ablit-perf/glm_gather_qmm_bitwise.py (#2451): the parts that run without MLX (pin, cases,
tile statistics, bit comparison), its job wrapper's static shape and the launcher wiring."""

import importlib.util
import os
import subprocess
import sys
import tempfile
import types
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
LAB = ROOT / "scripts" / "lab" / "ablit-perf"
JOB = LAB / "job-glm-gather-qmm-bitwise.sh"
LAUNCHER = LAB / "studio-ablit-perf.sh"

spec = importlib.util.spec_from_file_location("glm_gather_qmm_bitwise", LAB / "glm_gather_qmm_bitwise.py")
g = importlib.util.module_from_spec(spec)
spec.loader.exec_module(g)
sys.path.insert(0, str(ROOT / "scripts"))
import read_swiftpm_pins as pins  # noqa: E402


class PinTests(unittest.TestCase):
    def test_wheel_version_from_the_core_tag(self):
        self.assertEqual(g.core_wheel_version("v0.32.4-macprovider.15"), "0.32.4")
        self.assertEqual(g.core_wheel_version("0.31.0"), "0.31.0")
        for bad in ("", "main", "v0.32", "v0.32.4-rc1"):
            with self.assertRaises(ValueError):
                g.core_wheel_version(bad)

    def test_the_repo_pin_resolves_to_the_reviewed_core(self):
        tag, version, rev = g.pinned_core(pins, ROOT / "phase3-binary" / "Package.resolved")
        self.assertEqual(tag, pins.SPEC048_MLX_CORE_TAG)
        self.assertEqual(rev, pins.SPEC048_MLX_CORE_REVISION)
        self.assertEqual(version, g.core_wheel_version(pins.SPEC048_MLX_CORE_TAG))

    def test_a_resolved_file_on_another_mlx_swift_revision_is_refused(self):
        fake = types.SimpleNamespace(read_production_pins=lambda p: {"mlx_swift": "0" * 40},
                                     SPEC048_MLX_SWIFT_REVISION="1" * 40, SPEC048_MLX_CORE_TAG="v0.32.4-macprovider.15",
                                     SPEC048_MLX_CORE_REVISION="2" * 40)
        with self.assertRaises(ValueError):
            g.pinned_core(fake, "Package.resolved")

    def test_pin_cli(self):
        r = subprocess.run([sys.executable, str(LAB / "glm_gather_qmm_bitwise.py"), "pin", "--pins-dir",
                            str(ROOT / "scripts"), "--resolved", str(ROOT / "phase3-binary" / "Package.resolved")],
                           capture_output=True, text=True, env={**os.environ, "PYTHONDONTWRITEBYTECODE": "1"})
        self.assertEqual(r.returncode, 0, r.stdout + r.stderr)
        self.assertRegex(r.stdout, r"^GQMM_PIN core_tag=v\S+ core_revision=[0-9a-f]{40} wheel=\d+\.\d+\.\d+$")


class CaseTests(unittest.TestCase):
    def setUp(self):
        self.cases = {c["name"]: c for c in g.default_cases(2451, 32)}

    def test_targets_keep_their_experts_and_neighbours_follow_the_mode(self):
        ref = self.cases["ref-512-uniform"]
        want = [ref["indices"][p] for p in ref["target_pos"]]
        target_experts = {e for row in want for e in row}
        for c in self.cases.values():
            self.assertEqual([c["indices"][p] for p in c["target_pos"]], want, c["name"])
            self.assertEqual(len(c["indices"]), c["rows"])
            self.assertTrue(all(len(set(r)) == g.TOP_K for r in c["indices"]))
            others = [r for i, r in enumerate(c["indices"]) if i not in set(c["target_pos"])]
            if c["mode"] == "crowd":
                self.assertTrue(all(set(r) <= target_experts for r in others))
            if c["mode"] == "avoid":
                self.assertTrue(all(not set(r) & target_experts for r in others))
        self.assertEqual(self.cases["512-uniform-last"]["target_pos"], list(range(480, 512)))
        self.assertEqual(self.cases["4096-crowd-middle"]["target_pos"][0], 2032)
        self.assertEqual(self.cases["targets-alone"]["rows"], 32)

    def test_cases_are_reproducible(self):
        again = {c["name"]: c for c in g.default_cases(2451, 32)}
        self.assertEqual(again["2048-uniform"]["indices"], self.cases["2048-uniform"]["indices"])
        other = {c["name"]: c for c in g.default_cases(7, 32)}
        self.assertNotEqual(other["2048-uniform"]["indices"], self.cases["2048-uniform"]["indices"])

    def test_routes_and_tile_composition(self):
        self.assertEqual(g.predicted_route(512 * 8), "gather_qmm_rhs")  # 14.2 rows per expert
        self.assertEqual(g.predicted_route(89 * 8), "gather_qmv/qmm")  # the 89-token tail of 3673
        self.assertEqual(g.predicted_route(32), "unsorted")
        s = g.tile_stats(self.cases["4096-crowd-middle"])
        self.assertEqual(s["route"], "gather_qmm_rhs")
        self.assertEqual(s["target_rows_in_mixed_tiles"], "0/256")  # every target tile holds one expert
        self.assertEqual(g.tile_stats(self.cases["2048-avoid"])["target_rows_in_mixed_tiles"], "256/256")
        self.assertEqual(g.tile_stats(self.cases["targets-alone"])["route"], "gather_qmv/qmm")
        self.assertGreater(g.tile_stats(self.cases["4096-uniform"])["rows_per_target_expert"], 100)

    def test_bad_case_is_refused(self):
        with self.assertRaises(ValueError):
            g.build_case("x", 16, "uniform", "first", 32, 1)


class CompareTests(unittest.TestCase):
    def test_equal_and_diff_counts_with_ulp(self):
        ref = [[0x3F80, 0x4000], [0xBF80, 0x0000]]
        self.assertEqual(g.compare_rows(ref, [list(r) for r in ref]), (0, 2, 0, 4, 0))
        got = [[0x3F81, 0x4000], [0xBF80, 0x8000]]  # +1 ULP; +0 vs -0 is a 1-step bit difference
        self.assertEqual(g.compare_rows(ref, got), (2, 2, 2, 4, 1))
        self.assertEqual(g.compare_rows([[0xBF80]], [[0xBF82]])[4], 2)
        with self.assertRaises(ValueError):
            g.compare_rows(ref, ref[:1])

    def test_verdict_lines(self):
        stats = {"route": "gather_qmm_rhs", "index_rows": 4096, "rows_per_target_expert": 14.7,
                 "target_rows_in_mixed_tiles": "244/256"}
        self.assertTrue(g.verdict_line("c", "up", (0, 256, 0, 524288, 0), stats).startswith(
            "BITWISE_EQUAL case=c stage=up rows=256 elems=524288 route=gather_qmm_rhs"))
        self.assertIn("BITWISE_DIFF case=c stage=down rows_diff=3/256 elems_diff=9/1048576 max_ulp=2",
                      g.verdict_line("c", "down", (3, 256, 9, 1048576, 2), stats))

    def test_plan_cli_needs_no_mlx(self):
        r = subprocess.run([sys.executable, "-I", str(LAB / "glm_gather_qmm_bitwise.py"), "plan"],
                           capture_output=True, text=True)
        self.assertEqual(r.returncode, 0, r.stderr)
        self.assertEqual(len([l for l in r.stdout.splitlines() if l.startswith("GQMM_CASE ")]), 13)
        self.assertNotIn("mlx", sys.modules)


class JobTests(unittest.TestCase):
    def run_job(self, **env):
        home = tempfile.mkdtemp()
        e = {"PATH": os.environ["PATH"], "HOME": home, "GQMM_JOB_CHECK": "1", "RUN_ID": "20261120T000000Z", **env}
        return subprocess.run(["bash", str(JOB)], env=e, capture_output=True, text=True, timeout=30), home

    def test_check_mode_prints_the_argv_and_touches_nothing(self):
        self.assertEqual(subprocess.run(["bash", "-n", str(JOB)]).returncode, 0)
        r, home = self.run_job(GQMM_SEED="7", GQMM_TARGETS="16")
        self.assertEqual(r.returncode, 0, r.stdout)
        self.assertIn("PIN_ARGS pin --pins-dir", r.stdout)
        self.assertIn("/src/phase3-binary/Package.resolved", r.stdout)
        self.assertIn("RUN_ARGS run --seed 7 --targets 16 --expect-mlx", r.stdout)
        self.assertFalse((Path(home) / "lab-ablit-perf").exists())

    def test_bad_knobs_are_refused(self):
        for env in ({"GQMM_SEED": "x"}, {"GQMM_TARGETS": "0"}, {"GQMM_TARGETS": "300"}):
            r, _ = self.run_job(**env)
            self.assertEqual(r.returncode, 64, (env, r.stdout))
            self.assertIn("BLOCKER:", r.stdout)

    def test_static_shape(self):
        text = JOB.read_text()
        for want in ('"mlx==$WHEEL"', "JOB_PASS", "JOB_FAIL", "live.malibu.provider", "--expect-mlx"):
            self.assertIn(want, text)
        self.assertNotIn("swift build", text)


class LauncherTests(unittest.TestCase):
    def test_launcher_admits_the_job_its_knobs_and_the_pin_reader(self):
        text = LAUNCHER.read_text()
        self.assertIn("|job-glm-gather-qmm-bitwise.sh|", text)
        self.assertIn("|GQMM_SEED|GQMM_TARGETS|", text)
        self.assertIn('rsync -a "$REPO/scripts/read_swiftpm_pins.py" macstudio:lab-ablit-perf/job/pins/', text)
        self.assertIn("|GQMM_|BITWISE_|", text)


if __name__ == "__main__":
    unittest.main()
