import hashlib
import json
import tempfile
import unittest
from pathlib import Path

from scripts.native_mtp_r015_analyze import _holm_adjusted, analyze


class NativeMTPR015AnalyzeTests(unittest.TestCase):
    def test_pass(self):
        result = self._run_case()
        self.assertEqual(result["overall_status"], "PASS")

    def test_throughput_bound_fail(self):
        result = self._run_case(native_tps=112.0)
        self.assertEqual(result["overall_status"], "FAIL")
        self.assertIn("throughput", result["cells"][0]["metric_failures"])

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

    def test_load_gate_downgraded_run_needs_no_proposals(self):
        result = self._run_case(
            native_overrides={
                "load_gate_downgrades": 1,
                "native_admissions": 0,
                "mtp_proposed_tokens": 0,
                "mtp_accepted_tokens": 0,
                "target_forwards": 0,
            }
        )
        cell = result["cells"][0]
        self.assertNotIn("native_mtp_proposals_missing", cell["hard_failures"])
        self.assertNotIn("native_mtp_target_forwards_missing", cell["hard_failures"])
        self.assertNotIn("missing_native_admissions", cell["hard_failures"])
        self.assertEqual(cell["load_gate_downgrades"], 10)

    def test_ungated_run_without_proposals_still_fails(self):
        result = self._run_case(native_overrides={"mtp_proposed_tokens": 0})
        self.assertEqual(result["overall_status"], "FAIL")
        self.assertIn("native_mtp_proposals_missing", result["cells"][0]["hard_failures"])

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

    def _run_case(
        self,
        *,
        native_overrides=None,
        native_tps=130.0,
        native_ttft=0.105,
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
    ):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            policy_path = root / "policy.json"
            jsonl_path = root / "runs.jsonl"
            policy = {
                "schema": "macprovider.native-mtp-exploratory-policy.v1"
                if exploratory_policy
                else "macprovider.native-mtp-r015-policy.v1",
                "slots": [1],
                "prompt_tokens": [1536],
                "max_tokens": [128],
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
                },
            }
            if exploratory_policy:
                policy["blocks"] = 3
                policy["sustained_seconds"] = 0
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
                }
            ]
            for block in range(blocks_written):
                ordinary = self._run_record("ordinary", block, 100.0, 0.100, 0.010, False, policy_sha=run_policy_sha or policy_sha, peak_phys_footprint_bytes=peak_phys_footprint_bytes, min_available_memory_fraction=matrix_min_available_memory_fraction)
                records.append(ordinary)
                if duplicate_matrix_path and block == 0:
                    records.append(dict(ordinary))
                native_record = self._run_record("native_mtp", block, native_tps, native_ttft, native_itl, parity_mismatch, policy_sha=run_policy_sha or policy_sha, native_admissions=native_admissions, peak_phys_footprint_bytes=peak_phys_footprint_bytes)
                for field, value in (native_overrides or {}).items():
                    if value is self._DELETE:
                        native_record.pop(field, None)
                    else:
                        native_record[field] = value
                records.append(native_record)
            if blocks_written >= 10:
                records.append(self._run_record("ordinary", 100, 100.0, 0.100, 0.010, False, sustained=True, policy_sha=run_policy_sha or policy_sha, peak_phys_footprint_bytes=peak_phys_footprint_bytes, min_available_memory_fraction=sustained_min_available_memory_fraction, wall_seconds=sustained_wall_seconds))
                records.append(self._run_record("native_mtp", 100, native_tps, native_ttft, native_itl, parity_mismatch, sustained=True, policy_sha=run_policy_sha or policy_sha, native_admissions=native_admissions, peak_phys_footprint_bytes=peak_phys_footprint_bytes, min_available_memory_fraction=sustained_min_available_memory_fraction, wall_seconds=sustained_wall_seconds))
            jsonl_path.write_text("\n".join(json.dumps(r, sort_keys=True) for r in records) + "\n", encoding="utf-8")
            return analyze(jsonl_path, policy_path)

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
        native_admissions=1,
        peak_phys_footprint_bytes=1000,
        min_available_memory_fraction=0.5,
        wall_seconds=1.0,
    ):
        return {
            "schema": "macprovider.native-mtp-r015-run.v1",
            "record_type": "run",
            "policy_sha256": policy_sha,
            "cell_id": "s1-p1536-o128",
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


if __name__ == "__main__":
    unittest.main()
