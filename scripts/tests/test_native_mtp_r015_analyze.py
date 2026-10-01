import contextlib
import hashlib
import io
import json
import tempfile
import unittest
from pathlib import Path

from scripts.native_mtp_r015_analyze import _holm_adjusted, analyze, main


class NativeMTPR015AnalyzeTests(unittest.TestCase):
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
        result = self._run_case(legacy=True)
        cell = result["cells"][0]
        self.assertEqual(cell["decode_tps_sources"], ["derived_legacy"])
        ordinary = cell["reported_metrics"]["ordinary"]["aggregate_decode_tps"]["median"]
        self.assertAlmostEqual(ordinary, 128.0)
        self.assertEqual(result["overall_status"], "PASS")

    def test_legacy_multi_request_uses_arrival_offsets(self):
        # r0: 0s start, TTFT 0.5, wall 2.0; r1: 1s start, TTFT 0.5, wall 2.0.
        # Decode window 0.5 -> 3.0 = 2.5s for 2 * 200 decode tokens.
        result = self._run_case(legacy=True, legacy_multi=True, arrival_interval_ms=1000)
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

    def test_ttft_fail(self):
        result = self._run_case(native_ttft=0.13)
        self.assertEqual(result["overall_status"], "FAIL")
        self.assertIn("ttft", result["cells"][0]["metric_failures"])

    def test_parity_fail(self):
        result = self._run_case(parity_mismatch=True)
        self.assertEqual(result["overall_status"], "FAIL")
        self.assertIn("parity_mismatch", result["cells"][0]["hard_failures"])

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
            "itl_p95_upper_bound_max": 0.0,
            "rejection_increase_max_pp": 1.0,
            "min_available_memory_fraction": 0.10,
            "bootstrap_draws": 1000,
            "alpha": 0.05,
        }})
        self.assertEqual(result["reason"], "gated_thresholds_missing")

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

    def test_matrix_without_one_slot_cell_fails_closed(self):
        result = self._run_case(policy_overrides={"slots": [2], "sustained_cell_id": "s2-p1536-o128"})
        self.assertEqual(result["overall_status"], "FAIL")
        self.assertEqual(result["reason"], "policy_matrix_incomplete")
        self.assertIn("slots_missing:1", result["matrix_violations"])

    def test_matrix_missing_prompt_or_output_stratum_fails_closed(self):
        result = self._run_case(policy_overrides={"prompt_tokens": [1536, 4096], "max_tokens": [128]})
        self.assertEqual(result["overall_status"], "FAIL")
        self.assertEqual(result["reason"], "policy_matrix_incomplete")
        self.assertIn("prompt_tokens_missing:8192", result["matrix_violations"])
        self.assertIn("max_tokens_missing:512", result["matrix_violations"])

    def test_matrix_requires_qualified_slots_and_bound(self):
        missing_qualified = self._run_case(policy_overrides={"qualified_slots": self._DELETE})
        self.assertEqual(missing_qualified["reason"], "policy_matrix_incomplete")
        bound_above = self._run_case(policy_overrides={"max_native_active_rows": 3})
        self.assertEqual(bound_above["reason"], "policy_matrix_incomplete")
        self.assertIn("max_native_active_rows_missing_or_out_of_range", bound_above["matrix_violations"])

    def test_exploratory_policy_may_use_reduced_matrix(self):
        result = self._run_case(
            exploratory_policy=True,
            policy_overrides={"slots": [2], "qualified_slots": self._DELETE, "sustained_cell_id": "s2-p1536-o128"},
        )
        self.assertEqual(result["overall_status"], "EXPLORATORY_NO_VERDICT")

    def test_memory_margin_fail(self):
        result = self._run_case(peak_phys_footprint_bytes=256 * 1_073_741_824)
        self.assertEqual(result["overall_status"], "FAIL")
        self.assertIn("peak_plus_margin_exceeds_ram", result["cells"][0]["memory_failures"])

    def test_sustained_min_available_memory_fail(self):
        result = self._run_case(sustained_min_available_memory_fraction=0.05)
        self.assertEqual(result["overall_status"], "FAIL")
        self.assertIn("sustained_min_available_memory_fraction", result["cells"][0]["memory_failures"])

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
        self.assertTrue(any(item.startswith("sustained_incomplete:") for item in result["cells"][0]["hard_failures"]))

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
        for field, value in (
            ("ttft_p95_seconds", "0.1"),
            ("inter_token_gap_p95_seconds", float("nan")),
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
    SLOTS = (1, 2)
    # s1 cells are native-eligible; s2 cells are gated (SPEC-048-R015).
    BOUND = 1
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
    PROMPTS = (1536, 4096, 8192)
    OUTPUTS = (128, 512)

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
            "prompt_tokens": list(self.PROMPTS),
            "max_tokens": list(self.OUTPUTS),
            "warmup_runs": 0,
            "blocks": 10,
            "seed": 1234,
            "sustained_seconds": 1800,
            "sustained_cell_id": "s1-p1536-o128",
            "memory_safety_margin_bytes": 1024,
            "hw_model": "Mac15,14",
            "chip": "Apple M3 Ultra",
            "ram_gb": 256,
            "os_build": "25A1",
            "xcode_build_version": "17A1",
            "swift_version": "Apple Swift version 6.2",
            "provider_commit": "a" * 40,
            "mlx_fork_revision": "b" * 40,
            "thresholds": {
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
        ]
        for cell_id in cell_ids:
            for block in range(blocks_written):
                ordinary = self._run_record("ordinary", block, 100.0, 0.100, 0.010, False, policy_sha=run_policy_sha or policy_sha, peak_phys_footprint_bytes=peak_phys_footprint_bytes, min_available_memory_fraction=matrix_min_available_memory_fraction, cell_id=cell_id, **record_options)
                records.append(ordinary)
                if duplicate_matrix_path and block == 0:
                    records.append(dict(ordinary))
                native_record = self._run_record("native_mtp", block, native_tps, native_ttft, native_itl, parity_mismatch, policy_sha=run_policy_sha or policy_sha, native_admissions=native_admissions, peak_phys_footprint_bytes=peak_phys_footprint_bytes, decode_tps=native_decode_tps, cell_id=cell_id, **record_options)
                overrides = dict(native_overrides or {})
                if int(cell_id.split("-")[0][1:]) > self.BOUND:
                    overrides = {**self.GATED_BASE, **overrides, **(gated_native_overrides or {})}
                for field, value in overrides.items():
                    if value is self._DELETE:
                        native_record.pop(field, None)
                    else:
                        native_record[field] = value
                records.append(native_record)
            if blocks_written >= 10 and cell_id == policy.get("sustained_cell_id"):
                records.append(self._run_record("ordinary", 100, 100.0, 0.100, 0.010, False, sustained=True, policy_sha=run_policy_sha or policy_sha, peak_phys_footprint_bytes=peak_phys_footprint_bytes, min_available_memory_fraction=sustained_min_available_memory_fraction, wall_seconds=sustained_wall_seconds, cell_id=cell_id, **record_options))
                records.append(self._run_record("native_mtp", 100, native_tps, native_ttft, native_itl, parity_mismatch, sustained=True, policy_sha=run_policy_sha or policy_sha, native_admissions=native_admissions, peak_phys_footprint_bytes=peak_phys_footprint_bytes, min_available_memory_fraction=sustained_min_available_memory_fraction, wall_seconds=sustained_wall_seconds, decode_tps=native_decode_tps, cell_id=cell_id, **record_options))
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
