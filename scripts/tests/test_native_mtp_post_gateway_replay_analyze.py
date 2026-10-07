import contextlib
import hashlib
import io
import json
import tempfile
import unittest
from pathlib import Path

import scripts.native_mtp_post_gateway_replay_analyze as analyzer
from scripts.native_mtp_post_gateway_replay_analyze import analyze, main


class NativeMTPPostGatewayReplayAnalyzeTests(unittest.TestCase):
    _DELETE = object()

    @classmethod
    def setUpClass(cls):
        cls._frozen_draws = analyzer.FROZEN_BOOTSTRAP_DRAWS
        analyzer.FROZEN_BOOTSTRAP_DRAWS = 200

    @classmethod
    def tearDownClass(cls):
        analyzer.FROZEN_BOOTSTRAP_DRAWS = cls._frozen_draws

    def test_pass(self):
        result = self._run_case()
        self.assertEqual(result["overall_status"], "PASS")
        self.assertEqual(result["paired_blocks"], 10)
        self.assertGreaterEqual(result["eligibility"]["eligible_request_fraction"], 0.10)
        self.assertFalse(result["reported_evidence"]["end_to_end_aggregate_throughput_change"]["gated"])

    def test_eligible_request_floor_failure(self):
        result = self._run_case(eligible_blocks=0)
        self.assertEqual(result["overall_status"], "FAIL")
        self.assertIn("eligible_request_fraction_below_floor", result["hard_failures"])

    def test_eligible_completion_token_floor_failure(self):
        result = self._run_case(eligible_tokens=1, ineligible_tokens=100)
        self.assertEqual(result["overall_status"], "FAIL")
        self.assertIn("eligible_completion_token_fraction_below_floor", result["hard_failures"])

    def test_closed_schema_and_duplicate_keys(self):
        result = self._run_case(policy_overrides={"unexpected": 1})
        self.assertEqual(result["reason"], "policy_invalid")
        self.assertIn("policy_unknown_fields:unexpected", result["hard_failures"])
        with tempfile.TemporaryDirectory() as tmp:
            jsonl, policy = self._write_case(Path(tmp))
            text = policy.read_text("utf-8")
            policy.write_text(text.replace('"seed": 48015', '"seed": 48015, "seed": 48015', 1), "utf-8")
            out = io.StringIO()
            with contextlib.redirect_stdout(out):
                code = main([str(jsonl), str(policy)])
            self.assertEqual(code, 1)
            self.assertEqual(json.loads(out.getvalue())["reason"], "bad_input")

    def test_raw_key_prompt_and_private_path_rejection(self):
        result = self._run_case(shape_overrides={"conversation_key": "raw-key-bytes"})
        self.assertEqual(result["reason"], "block_invalid")
        self.assertTrue(any("raw_conversation_key_field" in f for f in result["block_failures"][0]["failures"]))
        result = self._run_case(shape_overrides={"prompt": "hello from a user"})
        self.assertTrue(any("raw_text_field" in f for f in result["block_failures"][0]["failures"]))
        result = self._run_case(shape_overrides={"shape_id": "/Users/augstar/private/prompt.txt"})
        self.assertTrue(any("private_path_value" in f for f in result["block_failures"][0]["failures"]))

    def test_policy_digest_mismatch(self):
        result = self._run_case(header_policy_sha="0" * 64)
        self.assertEqual(result["reason"], "header_invalid")
        self.assertIn("policy_digest_mismatch", result["hard_failures"])
        result = self._run_case(block_policy_sha="0" * 64)
        self.assertEqual(result["reason"], "result_policy_digest_mismatch")

    def test_missing_and_duplicate_pair_failures(self):
        missing = self._run_case(drop_mixed_block=4)
        self.assertEqual(missing["overall_status"], "FAIL")
        self.assertTrue(any("missing_pair:block 4" in f for f in missing["hard_failures"]))
        duplicate = self._run_case(duplicate_block=True)
        self.assertTrue(any("duplicate_pair:block 0 path observed_mixed" in f for f in duplicate["hard_failures"]))

    def test_block_count_failure(self):
        result = self._run_case(blocks=9, policy_overrides={"min_paired_blocks": 10})
        self.assertEqual(result["overall_status"], "FAIL")
        self.assertIn("paired_blocks_below_minimum:9/10", result["hard_failures"])

    def test_exact_conversation_key_semantics(self):
        result = self._run_case(shape_overrides={"conversation_key_present": True})
        self.assertEqual(result["reason"], "block_invalid")
        self.assertTrue(any("field_missing:conversation_key_cache_only" in f for f in result["block_failures"][0]["failures"]))
        result = self._run_case(eligible_blocks=0, ineligible_shape_overrides={"pre_capacity_selector_reason": "sampling"})
        self.assertIn("eligible_request_fraction_below_floor", result["hard_failures"])
        result = self._run_case(eligible_blocks=0, ineligible_shape_overrides={"conversation_key_present": False})
        self.assertTrue(any("conversation_key_reason_without_key" in f for f in result["block_failures"][0]["failures"]))

    def test_cache_only_conversation_key_miss_can_be_eligible(self):
        result = self._run_case(shape_overrides={
            "conversation_key_present": True,
            "conversation_key_cache_only": True,
            "conversation_cache_lease": "miss",
            "conversation_cache_cached_prompt_tokens": 0,
            "conversation_cache_retained_handoff": False,
        })
        self.assertEqual(result["overall_status"], "PASS")
        self.assertGreaterEqual(result["eligibility"]["eligible_request_fraction"], 0.10)

    def test_cache_only_conversation_key_unsafe_native_rejections(self):
        cases = [
            (
                {
                    "conversation_key_present": True,
                    "conversation_key_cache_only": False,
                },
                "eligible_with_sticky_conversation_key",
            ),
            (
                {
                    "conversation_key_present": True,
                    "conversation_key_cache_only": True,
                },
                "eligible_without_cache_only_miss_proof",
            ),
            (
                {
                    "conversation_key_present": True,
                    "conversation_key_cache_only": True,
                    "conversation_cache_lease": "missing",
                    "conversation_cache_cached_prompt_tokens": 0,
                    "conversation_cache_retained_handoff": False,
                },
                "eligible_without_cache_lease",
            ),
            (
                {
                    "conversation_key_present": True,
                    "conversation_key_cache_only": True,
                    "conversation_cache_lease": "hit",
                    "conversation_cache_cached_prompt_tokens": 12,
                    "conversation_cache_retained_handoff": False,
                },
                "eligible_with_cache_hit",
            ),
            (
                {
                    "conversation_key_present": True,
                    "conversation_key_cache_only": True,
                    "conversation_cache_lease": "miss",
                    "conversation_cache_cached_prompt_tokens": 0,
                    "conversation_cache_retained_handoff": True,
                },
                "eligible_with_retained_handoff",
            ),
        ]
        for overrides, expected in cases:
            with self.subTest(expected=expected):
                result = self._run_case(shape_overrides=overrides)
                self.assertEqual(result["reason"], "block_invalid")
                self.assertTrue(any(expected in f for f in result["block_failures"][0]["failures"]))

    def test_cache_only_conversation_key_hit_remains_ordinary(self):
        result = self._run_case(eligible_blocks=0, ineligible_shape_overrides={
            "conversation_key_present": True,
            "conversation_key_cache_only": True,
            "conversation_cache_lease": "hit",
            "conversation_cache_cached_prompt_tokens": 16,
            "conversation_cache_retained_handoff": False,
        })
        self.assertEqual(result["overall_status"], "FAIL")
        self.assertIn("eligible_request_fraction_below_floor", result["hard_failures"])

    def test_conversation_cache_token_proof_is_strictly_typed_and_consistent(self):
        cases = [
            (
                {"conversation_cache_cached_prompt_tokens": False},
                "sticky_key_with_cached_prompt_tokens",
                False,
            ),
            (
                {
                    "conversation_key_present": False,
                    "conversation_cache_cached_prompt_tokens": False,
                    "pre_capacity_selector_reason": "sampling",
                },
                "field_invalid:conversation_cache_cached_prompt_tokens",
                False,
            ),
            (
                {
                    "conversation_key_present": True,
                    "conversation_key_cache_only": True,
                    "conversation_cache_lease": "miss",
                    "conversation_cache_cached_prompt_tokens": 1,
                    "conversation_cache_retained_handoff": False,
                },
                "conversation_cache_miss_with_cached_prompt_tokens",
                True,
            ),
            (
                {
                    "conversation_key_present": True,
                    "conversation_key_cache_only": True,
                    "conversation_cache_lease": "missing",
                    "conversation_cache_cached_prompt_tokens": 1,
                    "conversation_cache_retained_handoff": False,
                },
                "conversation_cache_missing_with_cached_prompt_tokens",
                True,
            ),
            (
                {
                    "conversation_key_present": True,
                    "conversation_key_cache_only": True,
                    "conversation_cache_lease": "hit",
                    "conversation_cache_cached_prompt_tokens": 0,
                    "conversation_cache_retained_handoff": False,
                },
                "conversation_cache_hit_without_cached_prompt_tokens",
                True,
            ),
        ]
        for overrides, expected, eligible_shape in cases:
            with self.subTest(expected=expected):
                result = self._run_case(
                    shape_overrides=overrides if eligible_shape else None,
                    eligible_blocks=2 if eligible_shape else 0,
                    ineligible_shape_overrides=None if eligible_shape else overrides,
                )
                self.assertEqual(result["reason"], "block_invalid")
                self.assertTrue(any(expected in f for f in result["block_failures"][0]["failures"]))

    def test_keyed_requests_can_reject_for_earlier_selector_reasons(self):
        result = self._run_case(eligible_blocks=0, ineligible_shape_overrides={
            "conversation_key_present": True,
            "conversation_key_cache_only": False,
            "pre_capacity_selector_reason": "sampling",
        })
        self.assertIn("eligible_request_fraction_below_floor", result["hard_failures"])

    def test_conversation_key_proof_must_match_paired_blocks(self):
        result = self._run_case(
            shape_overrides={
                "conversation_key_present": True,
                "conversation_key_cache_only": True,
                "conversation_cache_lease": "miss",
                "conversation_cache_cached_prompt_tokens": 0,
                "conversation_cache_retained_handoff": False,
            },
            disabled_shape_overrides={
                "conversation_key_present": False,
                "conversation_key_cache_only": self._DELETE,
                "conversation_cache_lease": self._DELETE,
                "conversation_cache_cached_prompt_tokens": self._DELETE,
                "conversation_cache_retained_handoff": self._DELETE,
            },
        )
        self.assertEqual(result["overall_status"], "FAIL")
        self.assertTrue(any("shape_sample_mismatch:block 0" in f for f in result["hard_failures"]))

    def test_selector_inconsistency(self):
        result = self._run_case(shape_overrides={"pre_capacity_eligible": True, "pre_capacity_selector_reason": "sampling"})
        self.assertEqual(result["reason"], "block_invalid")
        self.assertTrue(any("selector_reason_inconsistent" in f for f in result["block_failures"][0]["failures"]))
        result = self._run_case(shape_overrides={"pre_capacity_eligible": False, "pre_capacity_selector_reason": "eligible"})
        self.assertTrue(any("selector_reason_inconsistent" in f for f in result["block_failures"][0]["failures"]))

    def test_invented_reason_rejection(self):
        result = self._run_case(shape_overrides={"pre_capacity_selector_reason": "auto_prefix_ineligible"})
        self.assertEqual(result["reason"], "block_invalid")
        self.assertTrue(any("field_invalid:pre_capacity_selector_reason" in f for f in result["block_failures"][0]["failures"]))

    def test_capacity_reason_rejection_in_pre_capacity_field(self):
        for reason in ("insufficient_verification_capacity", "capacity_above_native_bound"):
            with self.subTest(reason=reason):
                result = self._run_case(eligible_blocks=0, ineligible_shape_overrides={
                    "conversation_key_present": False,
                    "pre_capacity_selector_reason": reason,
                })
                self.assertEqual(result["reason"], "block_invalid")
                self.assertTrue(any("pre_capacity_selector_reason_runtime_only" in f for f in result["block_failures"][0]["failures"]))

    def test_threshold_and_methodology_relaxation_rejection(self):
        relaxed = self._run_case(policy_overrides={"bootstrap_draws": 199})
        self.assertEqual(relaxed["reason"], "policy_invalid")
        self.assertIn("field_not_frozen:bootstrap_draws", relaxed["hard_failures"])
        relaxed = self._run_case(policy_overrides={"alpha": 0.10})
        self.assertIn("field_not_frozen:alpha", relaxed["hard_failures"])
        relaxed = self._run_case(policy_overrides={"min_paired_blocks": 9})
        self.assertIn("field_not_frozen:min_paired_blocks", relaxed["hard_failures"])
        relaxed = self._run_case(policy_overrides={"confidence_method": "uncorrected_percentile_bootstrap"})
        self.assertIn("methodology_not_frozen:confidence_method", relaxed["hard_failures"])
        relaxed = self._run_case(policy_overrides={"thresholds": {
            "min_eligible_request_fraction": 0.09,
            "min_eligible_completion_token_fraction": 0.10,
            "ordinary_row_ttft_p95_regression_upper_bound": 0.05,
            "ordinary_row_itl_p95_regression_upper_bound": 0.05,
            "ordinary_row_throughput_change_lower_bound": -0.05,
        }})
        self.assertIn("threshold_not_frozen:min_eligible_request_fraction", relaxed["hard_failures"])

    def test_ttft_gate_failure(self):
        result = self._run_case(mixed_ttft=0.110)
        self.assertEqual(result["overall_status"], "FAIL")
        self.assertIn("ttft", result["metric_failures"])

    def test_itl_gate_failure(self):
        result = self._run_case(mixed_itl=0.011)
        self.assertEqual(result["overall_status"], "FAIL")
        self.assertIn("itl", result["metric_failures"])

    def test_ordinary_throughput_gate_failure(self):
        result = self._run_case(mixed_ordinary_tps=94.0)
        self.assertEqual(result["overall_status"], "FAIL")
        self.assertIn("ordinary_throughput", result["metric_failures"])

    def test_nonfinite_metric_fails_bad_input(self):
        with tempfile.TemporaryDirectory() as tmp:
            jsonl, policy = self._write_case(Path(tmp), mixed_ttft=float("nan"))
            out = io.StringIO()
            with contextlib.redirect_stdout(out):
                code = main([str(jsonl), str(policy)])
            self.assertEqual(code, 1)
            self.assertEqual(json.loads(out.getvalue())["reason"], "bad_input")

    def test_missing_privacy_review_and_preregistration_digest(self):
        result = self._run_case(policy_overrides={"privacy_review_id": "", "preregistration_digest_sha256": "bad"})
        self.assertEqual(result["reason"], "policy_invalid")
        self.assertIn("field_invalid:privacy_review_id", result["hard_failures"])
        self.assertIn("field_invalid:preregistration_digest_sha256", result["hard_failures"])

    def test_cli_json_and_markdown(self):
        with tempfile.TemporaryDirectory() as tmp:
            jsonl, policy = self._write_case(Path(tmp))
            out = io.StringIO()
            with contextlib.redirect_stdout(out):
                code = main([str(jsonl), str(policy)])
            self.assertEqual(code, 0)
            self.assertEqual(json.loads(out.getvalue())["overall_status"], "PASS")
            out = io.StringIO()
            with contextlib.redirect_stdout(out):
                code = main([str(jsonl), str(policy), "--format", "markdown"])
            self.assertEqual(code, 0)
            self.assertTrue(out.getvalue().startswith("| Status | Paired Blocks |"))

    def _run_case(self, **kwargs):
        with tempfile.TemporaryDirectory() as tmp:
            jsonl, policy = self._write_case(Path(tmp), **kwargs)
            return analyze(jsonl, policy)

    def _write_case(
        self,
        root: Path,
        *,
        blocks=10,
        eligible_blocks=2,
        eligible_tokens=50,
        ineligible_tokens=50,
        disabled_ttft=0.100,
        mixed_ttft=0.102,
        disabled_itl=0.010,
        mixed_itl=0.0102,
        disabled_ordinary_tps=100.0,
        mixed_ordinary_tps=99.0,
        disabled_e2e_tps=100.0,
        mixed_e2e_tps=101.0,
        policy_overrides=None,
        header_policy_sha=None,
        block_policy_sha=None,
        shape_overrides=None,
        disabled_shape_overrides=None,
        ineligible_shape_overrides=None,
        drop_mixed_block=None,
        duplicate_block=False,
    ):
        policy_path = root / "policy.json"
        jsonl_path = root / "replay.jsonl"
        policy = {
            "schema": "macprovider.native-mtp-post-gateway-replay-policy.v1",
            "issue": "SPEC-048-R015-post-gateway-replay",
            "confidence_method": "paired_block_bootstrap_holm_v1",
            "preregistration_digest_sha256": "a" * 64,
            "privacy_review_id": "privacy-1770-r015",
            "privacy_reviewed_at": "2026-10-02T00:00:00Z",
            "sample_digest_sha256": "b" * 64,
            "seed": 48015,
            "bootstrap_draws": analyzer.FROZEN_BOOTSTRAP_DRAWS,
            "alpha": 0.05,
            "min_paired_blocks": 10,
            "thresholds": {
                "min_eligible_request_fraction": 0.10,
                "min_eligible_completion_token_fraction": 0.10,
                "ordinary_row_ttft_p95_regression_upper_bound": 0.05,
                "ordinary_row_itl_p95_regression_upper_bound": 0.05,
                "ordinary_row_throughput_change_lower_bound": -0.05,
            },
        }
        policy.update(policy_overrides or {})
        for key, value in list(policy.items()):
            if value is self._DELETE:
                del policy[key]
        policy_path.write_text(json.dumps(policy, sort_keys=True), "utf-8")
        policy_sha = hashlib.sha256(policy_path.read_bytes()).hexdigest()
        records = [
            {
                "schema": "macprovider.native-mtp-post-gateway-replay.v1",
                "record_type": "header",
                "policy_sha256": header_policy_sha or policy_sha,
                "sample_digest_sha256": policy.get("sample_digest_sha256"),
                "preregistration_digest_sha256": policy.get("preregistration_digest_sha256"),
                "privacy_review_id": policy.get("privacy_review_id"),
            }
        ]
        for block in range(blocks):
            shapes = [
                self._shape(
                    f"shape-{block}-eligible",
                    False,
                    eligible_tokens,
                    True,
                    "eligible",
                    "native_mtp",
                    shape_overrides if block == 0 else None,
                )
                if block < eligible_blocks
                else self._shape(
                    f"shape-{block}-ineligible",
                    True,
                    ineligible_tokens,
                    False,
                    "conversation_key",
                    "ordinary",
                    ineligible_shape_overrides if block == 0 else None,
                )
            ]
            disabled_shapes = [dict(shape, effective_path="ordinary") for shape in shapes]
            if block == 0 and disabled_shape_overrides:
                disabled_shapes = [dict(shape, **disabled_shape_overrides) for shape in disabled_shapes]
                for shape in disabled_shapes:
                    for key, value in list(shape.items()):
                        if value is self._DELETE:
                            del shape[key]
            records.append(self._block(block, "mtp_disabled", disabled_shapes, disabled_ttft, disabled_itl, disabled_ordinary_tps, disabled_e2e_tps, block_policy_sha or policy_sha))
            if block != drop_mixed_block:
                records.append(self._block(block, "observed_mixed", shapes, mixed_ttft, mixed_itl, mixed_ordinary_tps, mixed_e2e_tps, block_policy_sha or policy_sha))
                if duplicate_block and block == 0:
                    records.append(self._block(block, "observed_mixed", shapes, mixed_ttft, mixed_itl, mixed_ordinary_tps, mixed_e2e_tps, block_policy_sha or policy_sha))
        jsonl_path.write_text("\n".join(json.dumps(record, sort_keys=True) for record in records) + "\n", "utf-8")
        return jsonl_path, policy_path

    @staticmethod
    def _shape(shape_id, key_present, tokens, eligible, reason, effective_path, overrides=None):
        shape = {
            "shape_id": shape_id,
            "conversation_key_present": key_present,
            "completion_tokens": tokens,
            "pre_capacity_selector_reason": reason,
            "pre_capacity_eligible": eligible,
            "effective_path": effective_path,
        }
        if key_present:
            shape["conversation_key_cache_only"] = False
        shape.update(overrides or {})
        for key, value in list(shape.items()):
            if value is NativeMTPPostGatewayReplayAnalyzeTests._DELETE:
                del shape[key]
        return shape

    @staticmethod
    def _block(block, path, shapes, ttft, itl, ordinary_tps, e2e_tps, policy_sha):
        return {
            "schema": "macprovider.native-mtp-post-gateway-replay.v1",
            "record_type": "block",
            "policy_sha256": policy_sha,
            "block_index": block,
            "path": path,
            "request_shapes": shapes,
            "ordinary_row_p95_ttft_seconds": ttft,
            "ordinary_row_p95_itl_seconds": itl,
            "ordinary_row_throughput_tps": ordinary_tps,
            "end_to_end_aggregate_throughput_tps": e2e_tps,
        }


if __name__ == "__main__":
    unittest.main()
