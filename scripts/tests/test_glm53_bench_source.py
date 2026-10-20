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

    def test_wall_only_mode_never_installs_dispatch_census(self):
        source = BENCH_SOURCE.read_text()
        install = source.index("DispatchCensus.install()")
        profile = source.index("if mtpMultirowProfileRequested {")

        self.assertLess(install, profile)
        self.assertIn(
            "mtpMultirowProfileRequested && mtpMultirowProfileMode == .census",
            source[:profile],
        )
        self.assertNotIn(
            '"--mtp-multirow-profile"',
            source[source.index("let censusModes"):install],
        )
        self.assertIn("if mtpMultirowProfileMode == .wallOnly", source[:install])

    def test_wall_only_arguments_are_closed_and_require_repeated_samples(self):
        source = BENCH_SOURCE.read_text()

        self.assertIn(
            'let mtpMultirowModeOption = "--mtp-multirow-measurement-mode"',
            source,
        )
        self.assertIn(
            'argumentError("\\(mtpMultirowModeOption) must be census or wall-only")',
            source,
        )
        self.assertIn(
            'case mtpMultirowModeOption, "--mtp-multirow-reps", "--prompt":',
            source,
        )
        self.assertIn(
            'argumentError("wall-only measurement is incompatible with \\(argument)")',
            source,
        )
        self.assertIn("guard (5 ... 10).contains(reps)", source)
        self.assertIn(
            'argumentError("wall-only --mtp-multirow-reps must be between 5 and 10")',
            source,
        )

    def test_wall_only_reports_full_facade_without_candidate_guess(self):
        source = BENCH_SOURCE.read_text()
        wall_branch = source.index(
            "if mtpMultirowProfileMode == .wallOnly {", source.index("func timed")
        )
        census = source.index("DispatchCensus.reset()", wall_branch)
        body = source[wall_branch:census]

        self.assertIn("full_synchronous_facade", body)
        self.assertIn("shared_candidate_active=unobserved", body)
        self.assertNotIn("candidateActive", body)
        self.assertIn("return", body)

    def test_census_reports_all_command_buffer_busy_and_partial_kernel_time(self):
        source = BENCH_SOURCE.read_text()

        self.assertIn("DispatchCensus.busyPerStep(steps: censusReps)", source)
        self.assertIn("attribution=all_command_buffer_intervals", source)
        self.assertIn(
            "per_kernel_attribution=single_kernel_command_buffers_only", source
        )
        self.assertIn("shared_candidate_dispatches=", source)

    def test_default_multirow_mode_remains_census_compatible(self):
        source = BENCH_SOURCE.read_text()

        self.assertIn(
            "guard let raw = mtpMultirowModeRaw else { return .census }", source
        )
        self.assertIn(
            "mtp-multirow diagnostic instrumentation=dispatch_census", source
        )
        self.assertIn("mtp-multirow wall_instrumented", source)


if __name__ == "__main__":
    unittest.main()
