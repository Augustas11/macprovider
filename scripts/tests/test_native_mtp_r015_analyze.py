import contextlib
import hashlib
import io
import json
import tempfile
import unittest
from pathlib import Path

import scripts.native_mtp_r015_analyze as analyzer
from scripts.native_mtp_r015_analyze import (
    _holm_adjusted,
    _native_first_order,
    analyze,
    main,
    mandatory_gated_cells,
    mandatory_prompt_tokens,
)


class NativeMTPR015AnalyzeTests(unittest.TestCase):
    # The frozen policy uses 10,000 bootstrap draws; tests freeze 1,000 so the
    # suite stays fast. Every other frozen threshold is the production value.
    @classmethod
    def setUpClass(cls):
        cls._frozen_draws = analyzer.FROZEN_THRESHOLDS["bootstrap_draws"]
        analyzer.FROZEN_THRESHOLDS["bootstrap_draws"] = 1000

    @classmethod
    def tearDownClass(cls):
        analyzer.FROZEN_THRESHOLDS["bootstrap_draws"] = cls._frozen_draws

    def test_pass(self):
        result = self._run_case()
        self.assertEqual(result["overall_status"], "PASS")

    def test_throughput_bound_fail(self):
        result = self._run_case(native_tps=112.0)
        self.assertEqual(result["overall_status"], "FAIL")
        self.assertIn("throughput", result["cells"][0]["metric_failures"])

    def test_throughput_gate_uses_decode_not_end_to_end(self):
        # Prefill dilutes end-to-end speedup; the gate reads decode only.
        result = self._run_case(native_tps=105.0, native_decode_tps=135.0)
        cell = result["cells"][0]
        self.assertEqual(result["overall_status"], "PASS")
        self.assertAlmostEqual(cell["metrics"]["throughput"]["median"], 0.35)
        info = cell["informational_metrics"]["end_to_end_throughput"]
        self.assertAlmostEqual(info["median"], 0.05)
        self.assertFalse(info["gated"])
        self.assertEqual(cell["decode_tps_sources"], ["recorded"])
        result = self._run_case(native_tps=135.0, native_decode_tps=105.0)
        self.assertIn("throughput", result["cells"][0]["metric_failures"])

    def test_missing_decode_on_versioned_schema_fails_closed(self):
        for field in ("aggregate_decode_tps", "per_request_decode_tps"):
            with self.subTest(field=field):
                result = self._run_case(native_overrides={field: self._DELETE})
                self.assertEqual(result["overall_status"], "FAIL")
                self.assertTrue(any(
                    item.startswith("invalid_run_record:native_mtp:") and field in item
                    for item in result["cells"][0]["hard_failures"]
                ), result["cells"][0]["hard_failures"])
        for value in (None, 0.0):
            with self.subTest(value=value):
                result = self._run_case(native_overrides={"aggregate_decode_tps": value})
                self.assertEqual(result["overall_status"], "FAIL")

    def test_legacy_records_derive_decode_throughput(self):
        # 129 tokens at 100 tok/s end-to-end = 1.29s wall; 0.29s TTFT leaves
        # 128 decode tokens over 1.0s.
        result = self._run_case(legacy=True, legacy_gates=True)
        cell = result["cells"][0]
        self.assertEqual(cell["decode_tps_sources"], ["derived_legacy"])
        ordinary = cell["reported_metrics"]["ordinary"]["aggregate_decode_tps"]["median"]
        self.assertAlmostEqual(ordinary, 128.0)
        self.assertEqual(result["overall_status"], "PASS")

    def test_legacy_multi_request_uses_arrival_offsets(self):
        # r0: 0s start, TTFT 0.5, wall 2.0; r1: 1s start, TTFT 0.5, wall 2.0.
        # Decode window 0.5 -> 3.0 = 2.5s for 2 * 200 decode tokens.
        result = self._run_case(legacy=True, legacy_multi=True, arrival_interval_ms=1000, legacy_gates=True)
        ordinary = result["cells"][0]["reported_metrics"]["ordinary"]["aggregate_decode_tps"]["median"]
        self.assertAlmostEqual(ordinary, 160.0)

    def test_legacy_records_without_ttft_fail_closed(self):
        result = self._run_case(legacy=True, native_overrides={"per_request_ttft_seconds": [None]})
        self.assertEqual(result["overall_status"], "FAIL")
        self.assertTrue(any(
            "aggregate_decode_tps" in item for item in result["cells"][0]["hard_failures"]
        ))

    def test_json_output_is_a_single_document(self):
        with tempfile.TemporaryDirectory() as tmp:
            jsonl_path, policy_path = self._write_case(Path(tmp))
            out = io.StringIO()
            with contextlib.redirect_stdout(out):
                code = main([str(jsonl_path), str(policy_path)])
            self.assertEqual(code, 0)
            self.assertEqual(json.loads(out.getvalue())["overall_status"], "PASS")
            out = io.StringIO()
            with contextlib.redirect_stdout(out):
                main([str(jsonl_path), str(policy_path), "--format", "markdown"])
            self.assertTrue(out.getvalue().startswith("| Cell | Status |"))
            self.assertIn("Decode LB", out.getvalue())

    def test_amended_gates_replace_inter_chunk_itl(self):
        # Native carries ~1.9 tokens per chunk: its inter-chunk p95 is above
        # ordinary's while per-token latency is lower. The legacy gate fails
        # on that; the amended TPOT and worst-gap gates pass it.
        amended = self._run_case(native_itl=0.016)
        self.assertEqual(amended["overall_status"], "PASS")
        self.assertEqual(amended["gate_set"], analyzer.GATE_SET_AMENDED)
        cell = amended["cells"][0]
        self.assertNotIn("itl", cell["metrics"])
        self.assertEqual(cell["metrics"]["tpot"]["threshold"], 0.0)
        self.assertEqual(cell["metrics"]["chunk_gap_p99"]["threshold"], 1.0)
        self.assertAlmostEqual(cell["metrics"]["tpot"]["median"], 100.0 / 130.0 - 1.0)
        legacy = self._run_case(native_itl=0.016, legacy_gates=True)
        self.assertEqual(legacy["gate_set"], analyzer.GATE_SET_LEGACY)
        self.assertIn("itl", legacy["cells"][0]["metric_failures"])
        self.assertNotIn("tpot", legacy["cells"][0]["metrics"])

    def test_tpot_gate_fails_on_slower_per_token_latency(self):
        # Aggregate decode passes, but the request's own per-token latency is
        # worse than ordinary's.
        result = self._run_case(native_overrides={"per_request_decode_tps": [95.0]})
        cell = result["cells"][0]
        self.assertEqual(result["overall_status"], "FAIL")
        self.assertIn("tpot", cell["metric_failures"])
        self.assertNotIn("throughput", cell["metric_failures"])

    def test_gated_tpot_uses_the_non_inferiority_margin(self):
        within = self._run_case(gated_native_overrides={"per_request_decode_tps": [97.0]})
        for cell in within["cells"]:
            if cell["cell_class"] == "gated":
                self.assertEqual(cell["metrics"]["tpot"]["threshold"], 0.05)
                self.assertNotIn("tpot", cell["metric_failures"])
        beyond = self._run_case(gated_native_overrides={"per_request_decode_tps": [90.0]})
        self.assertTrue(any(
            "tpot" in cell["metric_failures"] for cell in beyond["cells"] if cell["cell_class"] == "gated"
        ))

    def test_worst_gap_bound_catches_a_stall_the_average_hides(self):
        # Two 0.5s stalls in 100 chunks barely move TPOT but put the native
        # p99 gap far above 2x ordinary's.
        stalled = [[0.009] * 98 + [0.5, 0.5]]
        result = self._run_case(native_overrides={"raw_inter_token_gaps_seconds": stalled})
        cell = result["cells"][0]
        self.assertEqual(result["overall_status"], "FAIL")
        self.assertIn("chunk_gap_p99", cell["metric_failures"])
        self.assertNotIn("tpot", cell["metric_failures"])
        # Just under twice ordinary's p99 gap passes; twice it does not.
        under = self._run_case(native_overrides={"raw_inter_token_gaps_seconds": [[0.019] * 100]})
        self.assertNotIn("chunk_gap_p99", under["cells"][0]["metric_failures"])
        at = self._run_case(native_overrides={"raw_inter_token_gaps_seconds": [[0.020] * 100]})
        self.assertIn("chunk_gap_p99", at["cells"][0]["metric_failures"])

    def test_missing_chunk_gaps_fail_closed_under_amended_gates_only(self):
        for value in (self._DELETE, [], [[]], [[0.01, None]], [[0.01, -1.0]]):
            with self.subTest(value=value):
                result = self._run_case(native_overrides={"raw_inter_token_gaps_seconds": value})
                self.assertEqual(result["overall_status"], "FAIL")
                self.assertTrue(any(
                    "raw_inter_token_gaps_seconds" in item for item in result["cells"][0]["hard_failures"]
                ), result["cells"][0]["hard_failures"])
        legacy = self._run_case(native_overrides={"raw_inter_token_gaps_seconds": self._DELETE}, legacy_gates=True)
        self.assertEqual(legacy["overall_status"], "PASS")

    def test_amended_per_request_series_must_cover_every_request(self):
        # Two requests declared, one entry per series: the missing request
        # cannot drop out of the TPOT p95 or the gap p99.
        short = self._run_case(native_overrides={"requests": 2})
        self.assertEqual(short["overall_status"], "FAIL")
        self.assertTrue(any(
            "per_request_decode_tps" in item and "raw_inter_token_gaps_seconds" in item and "request_metrics" in item
            for item in short["cells"][0]["hard_failures"]
        ), short["cells"][0]["hard_failures"])
        cases = {
            # Top-level gaps disagree with the request's own gaps.
            "raw_inter_token_gaps_seconds": [{
                "request_id": "c-b0-r0", "completion_tokens": 129, "decode_tps": 130.0,
                "inter_token_gaps_seconds": [0.009] * 99,
            }],
            # Top-level decode throughput disagrees with the request's own.
            "per_request_decode_tps": [{
                "request_id": "c-b0-r0", "completion_tokens": 129, "decode_tps": 1000.0,
                "inter_token_gaps_seconds": [0.009] * 100,
            }],
            # More gaps than the request's tokens can produce.
            "request_metrics": [{
                "request_id": "c-b0-r0", "completion_tokens": 50, "decode_tps": 130.0,
                "inter_token_gaps_seconds": [0.009] * 100,
            }],
        }
        for field, metrics in cases.items():
            with self.subTest(field=field):
                result = self._run_case(native_overrides={"request_metrics": metrics})
                self.assertEqual(result["overall_status"], "FAIL")
                self.assertTrue(any(
                    field in item for item in result["cells"][0]["hard_failures"]
                ), result["cells"][0]["hard_failures"])
        # The legacy gate set never read these series; its verdicts stand.
        legacy = self._run_case(native_overrides={"request_metrics": self._DELETE}, legacy_gates=True)
        self.assertEqual(legacy["overall_status"], "PASS")

    def test_non_finite_policy_constants_and_non_object_records_are_rejected(self):
        for token in ("NaN", "Infinity", "-Infinity"):
            with self.subTest(token=token), tempfile.TemporaryDirectory() as tmp:
                jsonl_path, policy_path = self._write_case(Path(tmp))
                text = policy_path.read_text("utf-8")
                self.assertIn('"alpha": 0.05', text)
                policy_path.write_text(text.replace('"alpha": 0.05', f'"alpha": {token}'), "utf-8")
                with self.assertRaises(ValueError):
                    analyze(jsonl_path, policy_path)
        # A literal that overflows to infinity parses; the frozen-value check
        # still refuses it.
        with tempfile.TemporaryDirectory() as tmp:
            jsonl_path, policy_path = self._write_case(Path(tmp))
            text = policy_path.read_text("utf-8").replace('"alpha": 0.05', '"alpha": 1e999')
            policy_path.write_text(text, "utf-8")
            result = analyze(jsonl_path, policy_path)
            self.assertEqual(result["overall_status"], "FAIL")
            self.assertIn("threshold_not_frozen:alpha", result["matrix_violations"])
        with tempfile.TemporaryDirectory() as tmp:
            jsonl_path, policy_path = self._write_case(Path(tmp))
            jsonl_path.write_text(jsonl_path.read_text("utf-8") + "[]\n", "utf-8")
            with self.assertRaises(ValueError):
                analyze(jsonl_path, policy_path)

    def test_exploratory_amended_reanalysis_never_yields_a_verdict(self):
        with tempfile.TemporaryDirectory() as tmp:
            jsonl_path, policy_path = self._write_case(Path(tmp), native_itl=0.016, legacy_gates=True)
            self.assertEqual(analyze(jsonl_path, policy_path)["overall_status"], "FAIL")
            result = analyze(jsonl_path, policy_path, exploratory_amended_gates=True)
            self.assertEqual(result["overall_status"], "EXPLORATORY_NO_VERDICT")
            self.assertEqual(result["gate_set"], analyzer.GATE_SET_AMENDED)
            self.assertEqual(result["exploratory_reanalysis_of_gate_set"], analyzer.GATE_SET_LEGACY)
            self.assertTrue(all(cell["status"] == "PASS" for cell in result["cells"]))
            out = io.StringIO()
            with contextlib.redirect_stdout(out):
                code = main([str(jsonl_path), str(policy_path), "--exploratory-amended-gates", "--format", "markdown"])
            self.assertEqual(code, 1)
            self.assertIn("TPOT p95 UB | Gap p99 UB", out.getvalue())
        with tempfile.TemporaryDirectory() as tmp:
            jsonl_path, policy_path = self._write_case(Path(tmp))
            refused = analyze(jsonl_path, policy_path, exploratory_amended_gates=True)
            self.assertEqual(refused["reason"], "exploratory_reanalysis_needs_legacy_policy")

    def test_ttft_fail(self):
        result = self._run_case(native_ttft=0.13)
        self.assertEqual(result["overall_status"], "FAIL")
        self.assertIn("ttft", result["cells"][0]["metric_failures"])

    def test_parity_fail(self):
        result = self._run_case(parity_mismatch=True)
        self.assertEqual(result["overall_status"], "FAIL")
        self.assertIn("parity_mismatch", result["cells"][0]["hard_failures"])

    def test_preregistered_order_matches_bench_golden_vectors(self):
        # Same vectors as NativeMTPBenchPolicyTests (Swift bench).
        self.assertEqual(_native_first_order(48015, 8, 4096, 512, 10), [True, False, False, False, True, False, True, True, True, False])
        self.assertEqual(_native_first_order(1234, 1, 1536, 128, 10), [False, True, True, False, True, False, True, False, False, True])
        self.assertEqual(_native_first_order(0, 2, 8192, 128, 11), [False, False, True, False, True, True, True, True, False, False, True])

    def test_correct_counterbalanced_order_passes(self):
        result = self._run_case()
        self.assertEqual(result["overall_status"], "PASS")
        self.assertTrue(all(cell["paired_blocks"] == 10 for cell in result["cells"]))

    def test_blocks_below_ten_fails_closed(self):
        result = self._run_case(policy_overrides={"blocks": 9}, blocks_written=9)
        self.assertEqual(result["reason"], "policy_matrix_incomplete")
        self.assertIn("blocks_below_ten", result["matrix_violations"])

    def test_ordinary_always_first_fails(self):
        result = self._run_case(order_override=[False] * 10)
        self.assertEqual(result["overall_status"], "FAIL")
        failures = result["cells"][0]["hard_failures"]
        self.assertTrue(any("differs from the preregistered order" in f for f in failures), failures)
        self.assertIn("run order not counterbalanced", failures)

    def test_order_that_is_counterbalanced_but_not_preregistered_fails(self):
        result = self._run_case(order_override=[index % 2 == 0 for index in range(10)])
        failures = [f for cell in result["cells"] for f in cell["hard_failures"]]
        self.assertTrue(any("differs from the preregistered order" in f for f in failures), failures)

    def test_bad_order_positions_fail(self):
        result = self._run_case(native_overrides={"order_position": 2})
        failures = result["cells"][0]["hard_failures"]
        self.assertTrue(any("order_position not exactly one of each" in f for f in failures), failures)
        result = self._run_case(native_overrides={"order_position": None})
        failures = result["cells"][0]["hard_failures"]
        self.assertTrue(any("order_position not exactly one of each" in f for f in failures), failures)

    def test_duplicate_or_missing_pair_fails(self):
        duplicate = self._run_case(duplicate_matrix_path=True)
        self.assertEqual(duplicate["overall_status"], "FAIL")
        self.assertEqual(duplicate["reason"], "duplicate_run_record")
        missing = self._run_case(native_overrides={"path": "other"})
        self.assertTrue(any("missing paired path" in f for f in missing["cells"][0]["hard_failures"]))
        self.assertEqual(missing["overall_status"], "FAIL")

    def test_incomplete_cell(self):
        result = self._run_case(blocks_written=3)
        self.assertEqual(result["overall_status"], "FAIL")
        self.assertIn("incomplete: 3/10 paired blocks", result["cells"][0]["hard_failures"])

    def test_policy_digest_mismatch(self):
        result = self._run_case(header_policy_sha="0" * 64)
        self.assertEqual(result["overall_status"], "FAIL")
        self.assertEqual(result["reason"], "policy_digest_mismatch")

    def test_run_policy_digest_mismatch(self):
        result = self._run_case(run_policy_sha="0" * 64)
        self.assertEqual(result["overall_status"], "FAIL")
        self.assertEqual(result["reason"], "run_policy_digest_mismatch")

    def test_missing_native_admission_fail(self):
        result = self._run_case(native_admissions=0)
        self.assertEqual(result["overall_status"], "FAIL")
        self.assertIn("missing_native_admissions", result["cells"][0]["hard_failures"])

    def test_gated_cell_passes_with_zero_native_work_when_non_inferior(self):
        result = self._run_case(
            gated_native_overrides={
                "mtp_proposed_tokens": 0,
                "mtp_accepted_tokens": 0,
                "mtp_accepted_by_position": [0],
                "target_forwards": 0,
                "target_forwards_per_committed_token": 0.0,
                "gated_depth_restorations": 0,
                "gated_held_finishes_clean": 1,
                "aggregate_decode_tps": 99.0,
                "per_request_decode_tps": [99.0],
            }
        )
        gated = [cell for cell in result["cells"] if cell["cell_class"] == "gated"]
        self.assertTrue(gated)
        for cell in gated:
            self.assertEqual(cell["hard_failures"], [], cell["cell_id"])
            self.assertEqual(cell["status"], "PASS", cell["cell_id"])
            self.assertEqual(cell["metrics"]["throughput"]["threshold"], -0.05)
        self.assertEqual(result["overall_status"], "PASS")

    def test_fully_downgraded_gated_cell_fails_without_a_native_admission(self):
        result = self._run_case(
            gated_native_overrides={
                "native_admissions": 0,
                "load_gate_downgrades": 2,
                "mtp_proposed_tokens": 0,
                "mtp_accepted_tokens": 0,
                "target_forwards": 0,
                "effective_paths": [dict(self.DOWNGRADE, request_id="r0"), self.DOWNGRADE],
                "gated_depth_zero_rounds": 0,
                "gated_hold_episodes": 0,
                "gated_depth_restorations": 0,
            }
        )
        self.assertEqual(result["overall_status"], "FAIL")
        for cell in result["cells"]:
            if cell["cell_class"] == "gated":
                self.assertIn("gated_cell_missing_native_admission", cell["hard_failures"])
                self.assertIn("gated_depth_zero_hold_missing", cell["hard_failures"])
                self.assertNotIn("native_mtp_proposals_missing", cell["hard_failures"])

    def test_gated_cell_without_a_downgrade_or_hold_fails(self):
        result = self._run_case(
            gated_native_overrides={
                "native_admissions": 2,
                "load_gate_downgrades": 0,
                "effective_paths": [self.HELD, dict(self.HELD, request_id="r1", other_active_rows=1)],
                "gated_depth_zero_rounds": 0,
                "gated_hold_episodes": 0,
                "gated_depth_restorations": 0,
            }
        )
        failures = {f for c in result["cells"] if c["cell_class"] == "gated" for f in c["hard_failures"]}
        self.assertIn("gated_cell_missing_load_gate_downgrade", failures)
        self.assertIn("gated_depth_zero_hold_missing", failures)
        # r1 was admitted native while r0 was in flight: over the bound.
        self.assertIn("native_admission_above_bound", failures)

    def test_gated_hold_must_end_restored_or_cleanly(self):
        unresolved = self._run_case(gated_native_overrides={"gated_depth_restorations": 0, "gated_held_unresolved": 1})
        self.assertIn("gated_hold_unresolved", [f for c in unresolved["cells"] for f in c["hard_failures"]])
        unaccounted = self._run_case(gated_native_overrides={"gated_hold_episodes": 2})
        self.assertIn("gated_hold_unresolved", [f for c in unaccounted["cells"] for f in c["hard_failures"]])
        missing = self._run_case(gated_native_overrides={"gated_depth_zero_rounds": self._DELETE})
        self.assertIn("gated_load_gate_evidence_missing", [f for c in missing["cells"] for f in c["hard_failures"]])

    def test_gated_cells_require_staggered_arrivals(self):
        result = self._run_case(policy_overrides={"arrival_interval_ms": 0})
        self.assertEqual(result["reason"], "policy_matrix_incomplete")
        self.assertIn("arrival_interval_ms_required_for_gated_cells", result["matrix_violations"])

    def test_gated_cell_fails_on_regression_against_ordinary(self):
        result = self._run_case(
            gated_native_overrides={"aggregate_decode_tps": 90.0, "per_request_decode_tps": [90.0]}
        )
        self.assertEqual(result["overall_status"], "FAIL")
        for cell in result["cells"]:
            if cell["cell_class"] == "gated":
                self.assertIn("throughput", cell["metric_failures"])
            else:
                self.assertEqual(cell["status"], "PASS")

    def test_eligible_cell_still_needs_the_native_improvement(self):
        # A 1% loss is non-inferior in a gated cell but fails an eligible one.
        result = self._run_case(native_decode_tps=99.0)
        for cell in result["cells"]:
            if cell["cell_class"] == "gated":
                self.assertNotIn("throughput", cell["metric_failures"])
            else:
                self.assertIn("throughput", cell["metric_failures"])

    def test_gated_native_admission_above_bound_fails(self):
        result = self._run_case(
            gated_native_overrides={"effective_paths": [dict(self.HELD, other_active_rows=1), self.DOWNGRADE]}
        )
        self.assertEqual(result["overall_status"], "FAIL")
        gated = [cell for cell in result["cells"] if cell["cell_class"] == "gated"]
        self.assertTrue(all("native_admission_above_bound" in cell["hard_failures"] for cell in gated))

    def test_gated_downgrade_below_bound_or_missing_rows_fails(self):
        below = self._run_case(
            gated_native_overrides={"effective_paths": [self.HELD, dict(self.DOWNGRADE, other_active_rows=0)]}
        )
        self.assertIn("load_gate_downgrade_below_bound", [f for c in below["cells"] for f in c["hard_failures"]])
        missing = self._run_case(gated_native_overrides={"effective_paths": [self.HELD, {"request_id": "r1", "effective_path": "ordinary"}]})
        self.assertIn("admission_active_rows_missing", [f for c in missing["cells"] for f in c["hard_failures"]])

    def test_load_gate_downgrade_in_eligible_cell_fails(self):
        result = self._run_case(
            native_overrides={"native_requests": 2, "native_admissions": 1, "load_gate_downgrades": 1}
        )
        eligible = [cell for cell in result["cells"] if cell["cell_class"] == "native_eligible"]
        self.assertTrue(all("load_gate_downgrade_in_native_eligible_cell" in cell["hard_failures"] for cell in eligible))

    def test_gated_cells_need_frozen_non_inferiority_margins(self):
        result = self._run_case(policy_overrides={"thresholds": {
            "throughput_lower_bound_min": 0.15,
            "ttft_p95_upper_bound_max": 0.10,
            "tpot_p95_upper_bound_max": 0.0,
            "chunk_gap_p99_upper_bound_max": 1.0,
            "rejection_increase_max_pp": 1.0,
            "min_available_memory_fraction": 0.10,
            "bootstrap_draws": 1000,
            "alpha": 0.05,
        }})
        self.assertEqual(result["reason"], "policy_matrix_incomplete")
        self.assertIn("thresholds_key_set_not_frozen", result["matrix_violations"])

    def test_downgrades_beyond_requests_fail_accounting(self):
        result = self._run_case(
            native_overrides={"native_requests": 1, "native_admissions": 1, "load_gate_downgrades": 1}
        )
        self.assertEqual(result["overall_status"], "FAIL")
        self.assertIn("native_admission_accounting_inconsistent", result["cells"][0]["hard_failures"])

    def test_ungated_run_without_proposals_still_fails(self):
        result = self._run_case(native_overrides={"mtp_proposed_tokens": 0})
        self.assertEqual(result["overall_status"], "FAIL")
        self.assertIn("native_mtp_proposals_missing", result["cells"][0]["hard_failures"])

    def test_matrix_native_eligible_slots_must_be_one_to_bound(self):
        result = self._run_case(policy_overrides={"slots": [2]})
        self.assertEqual(result["overall_status"], "FAIL")
        self.assertEqual(result["reason"], "policy_matrix_incomplete")
        self.assertIn("slots_not_exactly_1_to_bound:2", result["matrix_violations"])
        result = self._run_case(policy_overrides={"slots": [1, 2]})
        self.assertIn("slots_not_exactly_1_to_bound:1,2", result["matrix_violations"])

    def test_matrix_prompt_strata_are_capped_and_exact(self):
        result = self._run_case(policy_overrides={"prompt_tokens": [1536], "max_tokens": [128]})
        self.assertEqual(result["overall_status"], "FAIL")
        self.assertEqual(result["reason"], "policy_matrix_incomplete")
        self.assertIn("prompt_tokens_not_exactly:1536,4096", result["matrix_violations"])
        self.assertIn("max_tokens_not_exactly:128,512", result["matrix_violations"])
        above_cap = self._run_case(policy_overrides={"prompt_tokens": [1536, 4096, 8192]})
        self.assertIn("prompt_tokens_not_exactly:1536,4096", above_cap["matrix_violations"])
        cap_8192 = self._run_case(policy_overrides={"maximum_prompt_tokens": 8192})
        self.assertIn("prompt_tokens_not_exactly:1536,4096,8192", cap_8192["matrix_violations"])
        no_cap = self._run_case(policy_overrides={"maximum_prompt_tokens": self._DELETE})
        self.assertIn("maximum_prompt_tokens_missing_or_out_of_range", no_cap["matrix_violations"])
        huge_cap = self._run_case(policy_overrides={"maximum_prompt_tokens": 1_048_577})
        self.assertIn("maximum_prompt_tokens_missing_or_out_of_range", huge_cap["matrix_violations"])

    def test_mandatory_strata_helpers(self):
        self.assertEqual(mandatory_prompt_tokens(4096), [1536, 4096])
        self.assertEqual(mandatory_prompt_tokens(2048), [1536, 2048])
        self.assertEqual(mandatory_prompt_tokens(32768), [1536, 4096, 32768])
        self.assertEqual(mandatory_gated_cells(1, 8), ["s2-p1536-o512", "s8-p1536-o512"])
        self.assertEqual(mandatory_gated_cells(7, 8), ["s8-p1536-o512"])
        self.assertEqual(mandatory_gated_cells(8, 8), [])

    def test_matrix_gated_and_sustained_cells_are_exact(self):
        missing = self._run_case(policy_overrides={"gated_cells": []})
        self.assertIn("gated_cells_not_exactly:s2-p1536-o512", missing["matrix_violations"])
        substituted = self._run_case(policy_overrides={"gated_cells": ["s2-p4096-o512"]})
        self.assertIn("gated_cells_not_exactly:s2-p1536-o512", substituted["matrix_violations"])
        malformed = self._run_case(policy_overrides={"gated_cells": ["s2-p1536"]})
        self.assertIn("gated_cells_malformed", malformed["matrix_violations"])
        sustained = self._run_case(policy_overrides={"sustained_cell_id": "s1-p1536-o512"})
        self.assertIn("sustained_cell_not:s2-p1536-o512", sustained["matrix_violations"])
        short = self._run_case(policy_overrides={"sustained_seconds": 1799})
        self.assertIn("sustained_seconds_below_1800", short["matrix_violations"])

    def test_admission_policy_contract_is_closed_and_frozen(self):
        relaxed = self._run_case(policy_overrides={"thresholds": {
            "throughput_lower_bound_min": 0.10,
            "ttft_p95_upper_bound_max": 0.10,
            "tpot_p95_upper_bound_max": 0.0,
            "chunk_gap_p99_upper_bound_max": 1.0,
            "rejection_increase_max_pp": 1.0,
            "min_available_memory_fraction": 0.10,
            "bootstrap_draws": 10000,
            "alpha": 0.05,
            "gated_throughput_lower_bound_min": -0.05,
            "gated_ttft_p95_upper_bound_max": 0.05,
            "gated_tpot_p95_upper_bound_max": 0.05,
        }})
        self.assertIn("threshold_not_frozen:throughput_lower_bound_min", relaxed["matrix_violations"])
        loose_gap = self._run_case(policy_overrides={"thresholds": {
            **analyzer.FROZEN_THRESHOLDS, "chunk_gap_p99_upper_bound_max": 1.5,
        }})
        self.assertIn("threshold_not_frozen:chunk_gap_p99_upper_bound_max", loose_gap["matrix_violations"])
        # A mix of the two gate sets is neither frozen set.
        mixed = self._run_case(policy_overrides={"thresholds": {
            **analyzer.FROZEN_THRESHOLDS, "itl_p95_upper_bound_max": 0.0,
        }})
        self.assertIn("thresholds_key_set_not_frozen", mixed["matrix_violations"])
        method = self._run_case(policy_overrides={"prompt_corpus": "deterministic_synthetic_unique_v1"})
        self.assertIn("methodology_not_frozen:prompt_corpus", method["matrix_violations"])
        unknown = self._run_case(policy_overrides={"extra": 1})
        self.assertIn("policy_unknown_keys:extra", unknown["matrix_violations"])

    def test_policy_field_domains_mirror_the_bench(self):
        negative_margin = self._run_case(policy_overrides={"memory_safety_margin_bytes": -1})
        self.assertIn("field_invalid:memory_safety_margin_bytes", negative_margin["matrix_violations"])
        bad_commit = self._run_case(policy_overrides={"provider_commit": "A" * 40})
        self.assertIn("field_invalid:provider_commit", bad_commit["matrix_violations"])
        hot = self._run_case(policy_overrides={"temperature": 3})
        self.assertIn("field_invalid:temperature", hot["matrix_violations"])

    def test_v5_sustained_window_must_be_one_run(self):
        with tempfile.TemporaryDirectory() as tmp:
            jsonl_path, policy_path = self._write_case(Path(tmp))
            lines = jsonl_path.read_text("utf-8").splitlines()
            header = json.loads(lines[0])
            header["run_metrics_version"] = 5
            out = [json.dumps(header, sort_keys=True)]
            for line in lines[1:]:
                record = json.loads(line)
                if record.get("sustained") is True:
                    record["sustained_window_id"] = "w-" + record["path"]
                out.append(json.dumps(record, sort_keys=True))
            jsonl_path.write_text("\n".join(out) + "\n", "utf-8")
            cell = self._cell(analyze(jsonl_path, policy_path), "s2-p1536-o512")
            self.assertIn("sustained_window_not_one_continuous_run", cell["hard_failures"])

    def test_duplicate_json_keys_are_rejected(self):
        with tempfile.TemporaryDirectory() as tmp:
            jsonl_path, policy_path = self._write_case(Path(tmp))
            text = policy_path.read_text("utf-8")
            policy_path.write_text(text.replace('"blocks": 10', '"blocks": 10, "blocks": 10', 1), "utf-8")
            with self.assertRaisesRegex(ValueError, "duplicate JSON key"):
                analyze(jsonl_path, policy_path)

    def test_sustained_blocks_must_be_contiguous(self):
        with tempfile.TemporaryDirectory() as tmp:
            jsonl_path, policy_path = self._write_case(Path(tmp))
            lines = jsonl_path.read_text("utf-8").splitlines()
            shifted = [line.replace('"block_index": 0', '"block_index": 2') if '"sustained": true' in line else line for line in lines]
            jsonl_path.write_text("\n".join(shifted) + "\n", "utf-8")
            result = analyze(jsonl_path, policy_path)
            cell = self._cell(result, "s2-p1536-o512")
            self.assertIn("sustained blocks not contiguous from 0", cell["hard_failures"])

    def test_matrix_only_cell_is_not_failed_for_an_unrun_sustained_window(self):
        # An exploratory matrix-only policy (sustained_seconds 0) analyzes the
        # sustained cell without its window; the window is judged from its
        # own run, so the matrix analysis must not fail the cell for it.
        result = self._run_case(
            exploratory_policy=True,
            write_sustained=False,
            sustained_min_available_memory_fraction=0.0,
            policy_overrides={"blocks": 10},
        )
        cell = self._cell(result, "s2-p1536-o512")
        self.assertEqual(cell["sustained_runs"], 0)
        self.assertEqual(cell["memory_failures"], [])
        self.assertEqual(cell["hard_failures"], [])
        self.assertEqual(cell["status"], "PASS")

    def test_sustained_phase_reuses_the_cells_matrix_records(self):
        result = self._run_case()
        cell = self._cell(result, "s2-p1536-o512")
        self.assertEqual(cell["paired_blocks"], 10)
        self.assertEqual(cell["sustained_runs"], 2)
        self.assertEqual(cell["status"], "PASS")
        missing = self._run_case(write_sustained=False)
        self.assertIn("sustained_missing", self._cell(missing, "s2-p1536-o512")["hard_failures"])

    def test_matrix_requires_qualified_slots_and_bound(self):
        missing_qualified = self._run_case(policy_overrides={"qualified_slots": self._DELETE})
        self.assertEqual(missing_qualified["reason"], "policy_matrix_incomplete")
        bound_above = self._run_case(policy_overrides={"max_native_active_rows": 3})
        self.assertEqual(bound_above["reason"], "policy_matrix_incomplete")
        self.assertIn("max_native_active_rows_missing_or_out_of_range", bound_above["matrix_violations"])

    def test_exploratory_policy_may_use_reduced_matrix(self):
        result = self._run_case(
            exploratory_policy=True,
            policy_overrides={
                "slots": [2],
                "qualified_slots": self._DELETE,
                "gated_cells": [],
                "sustained_cell_id": "s2-p1536-o128",
            },
        )
        self.assertEqual(result["overall_status"], "EXPLORATORY_NO_VERDICT")
        duplicate = self._run_case(
            exploratory_policy=True,
            policy_overrides={"slots": [2], "qualified_slots": self._DELETE, "sustained_cell_id": "s2-p1536-o128"},
        )
        self.assertEqual(duplicate["reason"], "policy_matrix_incomplete")
        self.assertEqual(duplicate["matrix_violations"], ["duplicate_cells"])

    def test_memory_margin_fail(self):
        result = self._run_case(peak_phys_footprint_bytes=256 * 1_073_741_824)
        self.assertEqual(result["overall_status"], "FAIL")
        self.assertIn("peak_plus_margin_exceeds_ram", result["cells"][0]["memory_failures"])

    def test_sustained_min_available_memory_fail(self):
        result = self._run_case(sustained_min_available_memory_fraction=0.05)
        self.assertEqual(result["overall_status"], "FAIL")
        self.assertIn("sustained_min_available_memory_fraction", self._cell(result, "s2-p1536-o512")["memory_failures"])

    def test_matrix_min_available_memory_fail(self):
        result = self._run_case(matrix_min_available_memory_fraction=0.05)
        self.assertEqual(result["overall_status"], "FAIL")
        self.assertIn("min_available_memory_fraction", result["cells"][0]["memory_failures"])

    def test_duplicate_matrix_path_fail(self):
        result = self._run_case(duplicate_matrix_path=True)
        self.assertEqual(result["overall_status"], "FAIL")
        self.assertEqual(result["reason"], "duplicate_run_record")

    def test_header_environment_mismatch(self):
        result = self._run_case(header_ram_gb=512)
        self.assertEqual(result["overall_status"], "FAIL")
        self.assertEqual(result["reason"], "environment_mismatch")

    def test_sustained_duration_fail(self):
        result = self._run_case(sustained_wall_seconds=100.0)
        self.assertEqual(result["overall_status"], "FAIL")
        self.assertTrue(any(item.startswith("sustained_incomplete:") for item in self._cell(result, "s2-p1536-o512")["hard_failures"]))

    def test_exploratory_never_yields_pass(self):
        # Pilot data is reported but never becomes an admission verdict.
        result = self._run_case(exploratory_policy=True, blocks_written=3)
        self.assertEqual(result["overall_status"], "EXPLORATORY_NO_VERDICT")
        self.assertEqual(result["cells"][0]["paired_blocks"], 3)
        self.assertNotIn("sustained_missing", result["cells"][0]["hard_failures"])

    def test_exploratory_label_mismatch_fails(self):
        result = self._run_case(header_exploratory=True)
        self.assertEqual(result["overall_status"], "FAIL")
        result = self._run_case(exploratory_policy=True, blocks_written=3, header_exploratory=False)
        self.assertEqual(result["overall_status"], "FAIL")

    def test_missing_native_p95_ttft_fails_closed(self):
        # A missing native p95 TTFT must never read as a 0s (perfect) TTFT.
        result = self._run_case(native_overrides={"ttft_p95_seconds": None})
        self.assertEqual(result["overall_status"], "FAIL")
        self.assertTrue(any(
            item.startswith("invalid_run_record:native_mtp:") and "ttft_p95_seconds" in item
            for item in result["cells"][0]["hard_failures"]
        ))

    def test_missing_required_fields_fail_closed(self):
        for field in (
            "inter_token_gap_p95_seconds",
            "aggregate_committed_tps",
            "requests",
            "capacity_rejections",
            "fallbacks",
            "errors",
            "native_requests",
            "parity_mismatch",
            "peak_phys_footprint_bytes",
            "min_available_memory_fraction",
            "per_request_tps",
            "thermal_state_end",
        ):
            with self.subTest(field=field):
                result = self._run_case(native_overrides={field: self._DELETE})
                self.assertEqual(result["overall_status"], "FAIL")
                self.assertTrue(any(
                    item.startswith("invalid_run_record:native_mtp:") and field in item
                    for item in result["cells"][0]["hard_failures"]
                ), result["cells"][0]["hard_failures"])

    def test_wrong_typed_or_non_finite_fields_fail_closed(self):
        # A NaN or Infinity constant is refused when the JSONL is read.
        for value in (float("nan"), float("inf")):
            with self.subTest(value=value), self.assertRaises(ValueError):
                self._run_case(native_overrides={"inter_token_gap_p95_seconds": value})
        for field, value in (
            ("ttft_p95_seconds", "0.1"),
            ("inter_token_gap_p95_seconds", -1.0),
            ("aggregate_committed_tps", -1.0),
            ("requests", 0),
            ("errors", 1.5),
            ("parity_mismatch", 0),
            ("min_available_memory_fraction", 1.5),
        ):
            with self.subTest(field=field):
                result = self._run_case(native_overrides={field: value})
                self.assertEqual(result["overall_status"], "FAIL")
                self.assertTrue(any(
                    field in item for item in result["cells"][0]["hard_failures"]
                ))

    def test_holm_is_step_down(self):
        # Sorted p: 0.01 -> 0.03, 0.03 -> 0.06, 0.04 -> max(0.06, 0.04).
        adjusted = _holm_adjusted([0.01, 0.04, 0.03])
        self.assertAlmostEqual(adjusted[0], 0.03)
        self.assertAlmostEqual(adjusted[1], 0.06)
        self.assertAlmostEqual(adjusted[2], 0.06)
        # An independent per-rank rule would pass 0.04 at alpha/1 = 0.05;
        # step-down fails it because the preceding rank already failed.
        self.assertGreater(adjusted[1], 0.05)

    def test_failing_early_rank_fails_later_hypotheses(self):
        # TTFT regresses past its gate in every block; Holm then must not let
        # any hypothesis with a larger p-value pass on its own bound.
        result = self._run_case(native_ttft=0.13)
        metrics = result["cells"][0]["metrics"]
        self.assertEqual(metrics["ttft"]["status"], "FAIL")
        for name, metric in metrics.items():
            if metric["holm_rank"] > metrics["ttft"]["holm_rank"]:
                self.assertEqual(metric["status"], "FAIL", name)
            self.assertEqual(metric["status"] == "PASS", metric["holm_adjusted_p_value"] <= 0.05, name)

    def test_reports_every_r015_metric_with_corrected_interval(self):
        result = self._run_case()
        reported = result["cells"][0]["reported_metrics"]
        for path in ("ordinary", "native_mtp"):
            for name in (
                "aggregate_committed_tps",
                "per_request_tps",
                "aggregate_decode_tps",
                "per_request_decode_tps",
                "ttft_p50_seconds",
                "ttft_p95_seconds",
                "inter_token_gap_p50_seconds",
                "inter_token_gap_p95_seconds",
                "tpot_p95_seconds",
                "chunk_gap_p99_seconds",
                "peak_phys_footprint_bytes",
                "capacity_rejection_rate",
                "fallback_error_rate",
            ):
                entry = reported[path][name]
                self.assertLessEqual(entry["ci_lower"], entry["median"])
                self.assertGreaterEqual(entry["ci_upper"], entry["median"])
                self.assertGreater(entry["confidence_level"], 0.95)
        for name in ("mtp_acceptance_rate", "target_forwards_per_committed_token", "mtp_proposed_tokens"):
            self.assertIn(name, reported["native_mtp"])

    _DELETE = object()

    @staticmethod
    def _sync_request_metrics(record):
        """request_metrics that agree with the record's per-request series,
        as the bench writes them (one entry per series element)."""
        gaps = record.get("raw_inter_token_gaps_seconds")
        decode = record.get("per_request_decode_tps")
        if not isinstance(gaps, list) or not isinstance(decode, list):
            record["request_metrics"] = []
            return
        record["request_metrics"] = [
            {
                "request_id": f"c-b{record.get('block_index', 0)}-r{index}",
                "completion_tokens": 129,
                "decode_tps": decode[index] if index < len(decode) else None,
                "inter_token_gaps_seconds": item,
            }
            for index, item in enumerate(gaps)
        ]
    SLOTS = (1,)
    # s1 cells are native-eligible; s2 cells are gated (SPEC-048-R015).
    BOUND = 1
    GATED_CELLS = ("s2-p1536-o512",)
    HELD = {"request_id": "r0", "effective_path": "native_mtp", "selector_reason": "", "other_active_rows": 0}
    DOWNGRADE = {"request_id": "r1", "effective_path": "ordinary", "selector_reason": "capacity_above_native_bound", "other_active_rows": 1}
    # A healthy gated run: r0 admitted native, r1 downgraded, r0 held at
    # depth zero for 12 rounds and restored once the gate released.
    GATED_BASE = {
        "native_requests": 2,
        "native_admissions": 1,
        "load_gate_downgrades": 1,
        "effective_paths": [HELD, DOWNGRADE],
        "gated_depth_zero_rounds": 12,
        "gated_hold_episodes": 1,
        "gated_depth_restorations": 1,
        "gated_held_finishes_clean": 0,
        "gated_held_unresolved": 0,
    }
    PROMPTS = (1536, 4096)
    OUTPUTS = (128, 512)
    # SPEC-048 0.1.24-and-earlier gates (inter-chunk p95 ITL).
    LEGACY_THRESHOLDS = {
        "throughput_lower_bound_min": 0.15,
        "ttft_p95_upper_bound_max": 0.10,
        "itl_p95_upper_bound_max": 0.0,
        "rejection_increase_max_pp": 1.0,
        "min_available_memory_fraction": 0.10,
        "bootstrap_draws": 1000,
        "alpha": 0.05,
        "gated_throughput_lower_bound_min": -0.05,
        "gated_ttft_p95_upper_bound_max": 0.05,
        "gated_itl_p95_upper_bound_max": 0.05,
    }

    @staticmethod
    def _cell(result, cell_id):
        return next(cell for cell in result["cells"] if cell["cell_id"] == cell_id)

    def _run_case(self, **kwargs):
        with tempfile.TemporaryDirectory() as tmp:
            jsonl_path, policy_path = self._write_case(Path(tmp), **kwargs)
            return analyze(jsonl_path, policy_path)

    def _write_case(
        self,
        root,
        *,
        native_overrides=None,
        native_tps=130.0,
        native_decode_tps=None,
        legacy=False,
        legacy_multi=False,
        arrival_interval_ms=0,
        native_ttft=0.102,
        native_itl=0.009,
        parity_mismatch=False,
        blocks_written=10,
        header_policy_sha=None,
        run_policy_sha=None,
        native_admissions=1,
        peak_phys_footprint_bytes=1000,
        sustained_min_available_memory_fraction=0.5,
        sustained_wall_seconds=900.0,
        matrix_min_available_memory_fraction=0.5,
        duplicate_matrix_path=False,
        header_ram_gb=256,
        exploratory_policy=False,
        header_exploratory=None,
        policy_overrides=None,
        gated_native_overrides=None,
        order_override=None,
        write_sustained=True,
        legacy_gates=False,
    ):
        policy_path = root / "policy.json"
        jsonl_path = root / "runs.jsonl"
        policy = {
            "schema": "macprovider.native-mtp-exploratory-policy.v1"
            if exploratory_policy
            else "macprovider.native-mtp-r015-policy.v1",
            "qualified_slots": 2,
            "max_native_active_rows": self.BOUND,
            "arrival_interval_ms": 250,
            "slots": list(self.SLOTS),
            "maximum_prompt_tokens": 4096,
            "prompt_tokens": list(self.PROMPTS),
            "max_tokens": list(self.OUTPUTS),
            "gated_cells": list(self.GATED_CELLS),
            "warmup_runs": 0,
            "blocks": 10,
            "seed": 1234,
            "sustained_seconds": 1800,
            "sustained_cell_id": "s2-p1536-o512",
            "memory_safety_margin_bytes": 1024,
            "hw_model": "Mac15,14",
            "chip": "Apple M3 Ultra",
            "ram_gb": 256,
            "os_build": "25A1",
            "xcode_build_version": "17A1",
            "swift_version": "Apple Swift version 6.2",
            "provider_commit": "a" * 40,
            "mlx_fork_revision": "b" * 40,
            "quantization": "4bit",
            "cache_mode": "paged_kv_mixed",
            "proposal_depth": 1,
            "run_order": "seeded_random_counterbalanced",
            "prompt_corpus": "deterministic_synthetic_unique_v2",
            "exclusion_rules": "none",
            "confidence_method": "paired_block_bootstrap_holm_v1",
            "model_id": "m",
            "target_sha256": "1" * 64,
            "mtp_sha256": "2" * 64,
            "tokenizer_sha256": "3" * 64,
            "thresholds": self.LEGACY_THRESHOLDS if legacy_gates else {
                "throughput_lower_bound_min": 0.15,
                "ttft_p95_upper_bound_max": 0.10,
                "tpot_p95_upper_bound_max": 0.0,
                "chunk_gap_p99_upper_bound_max": 1.0,
                "rejection_increase_max_pp": 1.0,
                "min_available_memory_fraction": 0.10,
                "bootstrap_draws": 1000,
                "alpha": 0.05,
                "gated_throughput_lower_bound_min": -0.05,
                "gated_ttft_p95_upper_bound_max": 0.05,
                "gated_tpot_p95_upper_bound_max": 0.05,
            },
        }
        if exploratory_policy:
            policy["blocks"] = 3
            policy["sustained_seconds"] = 0
        policy.update(policy_overrides or {})
        for key, value in list(policy.items()):
            if value is self._DELETE:
                del policy[key]
        policy_path.write_text(json.dumps(policy, sort_keys=True), encoding="utf-8")
        policy_sha = hashlib.sha256(policy_path.read_bytes()).hexdigest()
        records = [
            {
                "schema": "macprovider.native-mtp-r015-run.v1",
                "record_type": "header",
                "policy_sha256": header_policy_sha or policy_sha,
                "provider_commit": "a" * 40,
                "machine": {
                    "hw_model": "Mac15,14",
                    "chip": "Apple M3 Ultra",
                    "ram_gb": header_ram_gb,
                    "os_build": "25A1",
                },
                "xcode_build_version": "17A1",
                "swift_version": "Apple Swift version 6.2",
                "unavailable_metrics": [],
                "mlx_fork_revision": "b" * 40,
                "exploratory": exploratory_policy if header_exploratory is None else header_exploratory,
                "arrival_interval_ms": arrival_interval_ms,
            }
        ]
        if not legacy:
            records[0]["run_metrics_version"] = 2
        record_options = {"legacy": legacy, "legacy_multi": legacy_multi}
        cell_ids = [
            f"s{slots}-p{prompt}-o{output}"
            for slots in policy.get("slots", [])
            for prompt in policy.get("prompt_tokens", [])
            for output in policy.get("max_tokens", [])
        ] + [cell for cell in policy.get("gated_cells", []) if isinstance(cell, str) and cell.count("-") == 2]
        for cell_id in cell_ids:
            slots, prompt, output = (int(part[1:]) for part in cell_id.split("-"))
            native_first = order_override or _native_first_order(policy["seed"], slots, prompt, output, max(blocks_written, policy["blocks"]))
            overrides = dict(native_overrides or {})
            if int(cell_id.split("-")[0][1:]) > self.BOUND:
                overrides = {**self.GATED_BASE, **overrides, **(gated_native_overrides or {})}

            def apply(native_record):
                for field, value in overrides.items():
                    if value is self._DELETE:
                        native_record.pop(field, None)
                    else:
                        native_record[field] = value
                if not legacy and "request_metrics" not in overrides:
                    self._sync_request_metrics(native_record)

            for block in range(blocks_written):
                ordinary = self._run_record("ordinary", block, 100.0, 0.100, 0.010, False, policy_sha=run_policy_sha or policy_sha, peak_phys_footprint_bytes=peak_phys_footprint_bytes, min_available_memory_fraction=matrix_min_available_memory_fraction, cell_id=cell_id, **record_options)
                ordinary["order_position"] = 1 if native_first[block] else 0
                records.append(ordinary)
                if duplicate_matrix_path and block == 0:
                    records.append(dict(ordinary))
                native_record = self._run_record("native_mtp", block, native_tps, native_ttft, native_itl, parity_mismatch, policy_sha=run_policy_sha or policy_sha, native_admissions=native_admissions, peak_phys_footprint_bytes=peak_phys_footprint_bytes, decode_tps=native_decode_tps, cell_id=cell_id, **record_options)
                apply(native_record)
                native_record.setdefault("order_position", 0 if native_first[block] else 1)
                records.append(native_record)
            if write_sustained and blocks_written >= 10 and cell_id == policy.get("sustained_cell_id"):
                # Sustained block 0 is even: native runs first.
                records.append(self._run_record("ordinary", 0, 100.0, 0.100, 0.010, False, sustained=True, order_position=1, policy_sha=run_policy_sha or policy_sha, peak_phys_footprint_bytes=peak_phys_footprint_bytes, min_available_memory_fraction=sustained_min_available_memory_fraction, wall_seconds=sustained_wall_seconds, cell_id=cell_id, **record_options))
                sustained_native = self._run_record("native_mtp", 0, native_tps, native_ttft, native_itl, parity_mismatch, sustained=True, order_position=0, policy_sha=run_policy_sha or policy_sha, native_admissions=native_admissions, peak_phys_footprint_bytes=peak_phys_footprint_bytes, min_available_memory_fraction=sustained_min_available_memory_fraction, wall_seconds=sustained_wall_seconds, decode_tps=native_decode_tps, cell_id=cell_id, **record_options)
                apply(sustained_native)
                sustained_native["order_position"] = 0
                records.append(sustained_native)
        jsonl_path.write_text("\n".join(json.dumps(r, sort_keys=True) for r in records) + "\n", encoding="utf-8")
        return jsonl_path, policy_path

    def _run_record(
        self,
        path,
        block,
        tps,
        ttft,
        itl,
        parity_mismatch,
        sustained=False,
        *,
        policy_sha,
        cell_id="s1-p1536-o128",
        order_position=None,
        native_admissions=1,
        peak_phys_footprint_bytes=1000,
        min_available_memory_fraction=0.5,
        wall_seconds=1.0,
        decode_tps=None,
        legacy=False,
        legacy_multi=False,
    ):
        record = {
            "schema": "macprovider.native-mtp-r015-run.v1",
            "record_type": "run",
            "policy_sha256": policy_sha,
            "cell_id": cell_id,
            "block_index": block,
            **({} if order_position is None else {"order_position": order_position}),
            "path": path,
            "sustained": sustained,
            "wall_seconds": wall_seconds,
            "requests": 1,
            "aggregate_committed_tps": tps,
            "per_request_tps": [tps],
            "ttft_p50_seconds": ttft * 0.9,
            "ttft_p95_seconds": ttft,
            "inter_token_gap_p50_seconds": itl * 0.9,
            "inter_token_gap_p95_seconds": itl,
            "raw_inter_token_gaps_seconds": [[itl] * 100],
            "capacity_rejections": 0,
            "fallbacks": 0,
            "errors": 0,
            "parity_mismatch": parity_mismatch,
            "non_native_admissions": 0,
            "native_admissions": native_admissions if path == "native_mtp" else 0,
            "native_requests": 1 if path == "native_mtp" else 0,
            "effective_paths": [
                {"request_id": "r0", "effective_path": "native_mtp", "selector_reason": "", "other_active_rows": 0}
            ]
            if path == "native_mtp"
            else [],
            "mtp_accepted_tokens": 100 if path == "native_mtp" else 0,
            "mtp_proposed_tokens": 100 if path == "native_mtp" else 0,
            "mtp_accepted_by_position": [100] if path == "native_mtp" else [],
            "target_forwards": 100,
            "target_forwards_per_committed_token": 1.0 if path == "native_mtp" else None,
            "committed_completion_tokens": 100,
            "peak_phys_footprint_bytes": peak_phys_footprint_bytes,
            "min_available_memory_fraction": min_available_memory_fraction,
            "thermal_state_start": "nominal",
            "thermal_state_end": "nominal",
        }
        if not legacy:
            decode = tps if decode_tps is None else decode_tps
            record["aggregate_decode_tps"] = decode
            record["per_request_decode_tps"] = [decode]
            self._sync_request_metrics(record)
        elif legacy_multi:
            # Two requests, 201 tokens each, 2.0s wall, 0.5s TTFT.
            record["requests"] = 2
            record["per_request_tps"] = [100.5, 100.5]
            record["per_request_ttft_seconds"] = [0.5, 0.5]
            record["request_metrics"] = [
                {"request_id": "c-b0-r0", "completion_tokens": 201},
                {"request_id": "c-b0-r1", "completion_tokens": 201},
            ]
        else:
            # 129 tokens; wall = 129 / tps; TTFT = 29 / tps, so decode runs
            # 128 tokens over 100 / tps seconds (128 tok/s at tps=100).
            record["per_request_ttft_seconds"] = [29.0 / tps]
            record["request_metrics"] = [{"request_id": "c-b0-r0", "completion_tokens": 129}]
        return record


if __name__ == "__main__":
    unittest.main()
