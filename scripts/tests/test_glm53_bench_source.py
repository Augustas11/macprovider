"""Offline source-contract checks for the GLM component profiler."""

from pathlib import Path
import unittest


BENCH_SOURCE = (
    Path(__file__).resolve().parents[1]
    / "lab/cb-studio/glm53-bench/Sources/GLMBench/main.swift"
)


class GLMBenchSourceTests(unittest.TestCase):
    def test_real_model_exactness_gate_precedes_timing(self):
        source = BENCH_SOURCE.read_text()
        exact_gate = source.index("guard exactArrays, exactMetadata else")
        timing = source.index("func timed(_ label: String")

        self.assertLess(exact_gate, timing)
        self.assertIn("fflush(stdout)", source[exact_gate:timing])

    def test_profiler_has_no_handwritten_route_mirror(self):
        source = BENCH_SOURCE.read_text()

        self.assertNotIn("func routeProbe", source)
        self.assertNotIn("route_probe_logits_exact", source)


if __name__ == "__main__":
    unittest.main()
