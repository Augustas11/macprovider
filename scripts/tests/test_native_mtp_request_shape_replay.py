import json
import contextlib
import io
import tempfile
import unittest
from pathlib import Path

from scripts import native_mtp_request_shape_replay as replay


class NativeMTPRequestShapeReplayTests(unittest.TestCase):
    def test_project_selector_ordering_and_analyzer_strip(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            capture = self._write_capture(root, [
                self._shape("cache-miss", key=True, cache_only=True, lease="miss", cached=0, observed_count=2),
                self._shape("sticky-unknown", key=True, cache_only=False, features={"unknown_top_level_keys": True}),
                self._shape("cache-hit", key=True, cache_only=True, lease="hit", cached=9),
                self._shape("unknown", features={"unknown_top_level_keys": True}),
                self._shape("reasoning", features={"reasoning_or_template": True}),
                self._shape("state", features={"unsupported_state_cache": True}),
            ])
            bounds = self._write_bounds(root)
            policy, plan = replay.project_capture(
                capture,
                bounds,
                blocks=10,
                privacy_review_id="privacy-1770-r015",
                privacy_reviewed_at="2026-10-07T00:00:00Z",
                preregistration_digest="a" * 64,
                seed=48015,
            )
        reasons = {shape["shape_id"]: shape["pre_capacity_selector_reason"] for shape in plan["blocks"][0]["request_shapes"]}
        self.assertEqual(reasons["cache-miss:1"], "eligible")
        self.assertEqual(reasons["cache-miss:2"], "eligible")
        self.assertEqual(reasons["sticky-unknown"], "unknown_request_field")
        self.assertEqual(reasons["cache-hit"], "conversation_key")
        self.assertEqual(reasons["unknown"], "unknown_request_field")
        self.assertEqual(reasons["reasoning"], "reasoning_or_template")
        self.assertEqual(reasons["state"], "unsupported_state_cache")
        emitted = plan["blocks"][0]["request_shapes"][0]
        self.assertNotIn("features", emitted)
        self.assertNotIn("prompt_tokens", emitted)
        self.assertNotIn("cache_group", emitted)
        self.assertEqual(policy["sample_digest_sha256"], plan["sample_digest_sha256"])
        self.assertEqual(plan["sample_report"]["captured_request_count"], 7)
        self.assertEqual(plan["sample_report"]["projected_request_count_per_block"], 7)
        self.assertIn("no population representativeness", plan["sample_report"]["representativeness_claim"])
        notice = plan["blocks"][0]["replay_requests"][0]["synthetic_content_notice"]
        self.assertIn("synthetic prompt content", notice)

    def test_privacy_rejects_raw_prompt_key_and_duplicate_json(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            capture = root / "capture.jsonl"
            header = self._header(request_count=1, completion_tokens=64)
            bad = self._shape("bad")
            bad["prompt"] = "raw buyer prompt"
            capture.write_text(json.dumps(header) + "\n" + json.dumps(bad) + "\n", "utf-8")
            with self.assertRaisesRegex(ValueError, "raw_text_field"):
                replay.load_capture(capture)
            duplicate = root / "duplicate.jsonl"
            duplicate.write_text('{"schema":"x","schema":"y"}\n', "utf-8")
            with self.assertRaisesRegex(ValueError, "duplicate JSON key"):
                replay.load_capture(duplicate)

    def test_tuple_bounds_drive_capability_and_sampling_reasons(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            capture = self._write_capture(root, [
                self._shape("too-long", prompt_tokens=2048),
                self._shape("sampled", features={"temperature": 0.5}),
            ])
            bounds = self._write_bounds(root, maximum_prompt_tokens=1024, request_feature_profile="native_mtp_greedy_text_v1")
            _, plan = replay.project_capture(
                capture,
                bounds,
                blocks=10,
                privacy_review_id="privacy-1770-r015",
                privacy_reviewed_at="2026-10-07T00:00:00Z",
                preregistration_digest="b" * 64,
                seed=1,
            )
        reasons = {shape["shape_id"]: shape["pre_capacity_selector_reason"] for shape in plan["blocks"][0]["request_shapes"]}
        self.assertEqual(reasons["too-long"], "capability_mismatch")
        self.assertEqual(reasons["sampled"], "sampling")


    def test_capture_counts_must_match_observed_shapes(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            shape = self._shape("two", observed_count=2, completion_tokens=10)
            capture = root / "capture.jsonl"
            header = self._header(request_count=1, completion_tokens=20)
            capture.write_text(json.dumps(header) + "\n" + json.dumps(shape) + "\n", "utf-8")
            with self.assertRaisesRegex(ValueError, "captured_request_count_mismatch"):
                replay.load_capture(capture)

    def test_selector_order_keeps_sticky_before_later_tool_reason(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            capture = self._write_capture(root, [
                self._shape("sticky-tool", key=True, cache_only=False, features={"tools": True}),
                self._shape("logprobs-logit", features={"logprobs": True, "logit_bias_present": True}),
            ])
            bounds = self._write_bounds(root)
            _, plan = replay.project_capture(
                capture,
                bounds,
                blocks=10,
                privacy_review_id="privacy-1770-r015",
                privacy_reviewed_at="2026-10-07T00:00:00Z",
                preregistration_digest="c" * 64,
                seed=1,
            )
        reasons = {shape["shape_id"]: shape["pre_capacity_selector_reason"] for shape in plan["blocks"][0]["request_shapes"]}
        self.assertEqual(reasons["sticky-tool"], "conversation_key")
        self.assertEqual(reasons["logprobs-logit"], "logprobs")

    def test_sse_metrics_use_observed_timestamps(self):
        observations = [
            replay.observation_from_sse(10.0, [
                (10.2, b'data: {"choices":[{"delta":{"content":"a"}}]}\n\n'),
                (10.5, b'data: {"choices":[{"delta":{"content":"b"}}]}\n\n'),
                (10.7, b'data: [DONE]\n\n'),
            ]),
            replay.observation_from_sse(20.0, [
                (20.1, b'data: {"choices":[{"delta":{"content":"a"}}]}\n\n'),
                (20.4, b'data: {"choices":[{"delta":{"content":"b"}}]}\n\n'),
                (20.6, b'data: {"choices":[{"delta":{"content":"c"}}]}\n\n'),
                (20.8, b'data: [DONE]\n\n'),
            ]),
        ]
        metrics = replay.metrics_from_observations(observations)
        self.assertGreater(metrics["ordinary_row_p95_ttft_seconds"], 0)
        self.assertGreater(metrics["ordinary_row_p95_itl_seconds"], 0)
        self.assertGreater(metrics["ordinary_row_throughput_tps"], 0)
        self.assertGreater(metrics["end_to_end_aggregate_throughput_tps"], 0)

    def test_run_requires_local_no_join_signed_candidate(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            plan = root / "plan.json"
            policy = root / "policy.json"
            out = root / "out.jsonl"
            plan.write_text(json.dumps({"schema": replay.PLAN_SCHEMA, "blocks": []}), "utf-8")
            policy.write_text(json.dumps({"preregistration_digest_sha256": "a" * 64, "privacy_review_id": "p", "sample_digest_sha256": "b" * 64}), "utf-8")
            with contextlib.redirect_stdout(io.StringIO()):
                code = replay.main(["run", "--plan", str(plan), "--policy", str(policy), "--output", str(out), "--endpoint", "https://coordinator.malibu.tech/v1/chat/completions"])
            self.assertEqual(code, 1)

    def _header(self, *, request_count=1, completion_tokens=64):
        return {
            "schema": replay.CAPTURE_SCHEMA,
            "record_type": "header",
            "captured_at": "2026-10-07T00:00:00Z",
            "native_mtp_mode": "off",
            "capture_requires_native_mtp_off": True,
            "served_identity": "local-no-join",
            "build_source_commit": "deadbeef",
            "build_cdhash": "cdhashfixture",
            "cli_version": "fixture",
            "max_records": 100,
            "max_bytes": 100000,
            "privacy_review_id": "privacy-1770-r015",
            "privacy_reviewed_at": "2026-10-07T00:00:00Z",
            "capture_stage": "post_gateway_provider_bound",
            "capture_mode": "mtp_off",
            "sampling_plan_id": "r015-last7d-bounded",
            "sample_period_start": "2026-09-30T00:00:00Z",
            "sample_period_end": "2026-10-07T00:00:00Z",
            "captured_request_count": request_count,
            "captured_completion_tokens": completion_tokens,
        }

    def _shape(
        self,
        shape_id,
        *,
        prompt_tokens=256,
        completion_tokens=64,
        key=False,
        cache_only=None,
        lease=None,
        cached=None,
        retained=None,
        features=None,
        observed_count=1,
    ):
        shape = {
            "schema": replay.CAPTURE_SCHEMA,
            "record_type": "shape",
            "shape_id": shape_id,
            "observed_count": observed_count,
            "prompt_tokens": prompt_tokens,
            "completion_tokens": completion_tokens,
            "conversation_key_present": key,
            "features": features or {},
        }
        if key:
            shape["conversation_key_cache_only"] = bool(cache_only)
            if cache_only:
                shape["conversation_cache_lease"] = lease
                shape["conversation_cache_cached_prompt_tokens"] = cached
                shape["conversation_cache_retained_handoff"] = False if retained is None else retained
                shape["cache_group"] = "group-" + shape_id
        return shape

    def _write_capture(self, root, shapes):
        capture = root / "capture.jsonl"
        request_count = sum(shape.get("observed_count", 1) for shape in shapes)
        completion_tokens = sum(shape.get("observed_count", 1) * shape["completion_tokens"] for shape in shapes)
        capture.write_text(
            "\n".join(
                json.dumps(record, sort_keys=True)
                for record in [self._header(request_count=request_count, completion_tokens=completion_tokens), *shapes]
            )
            + "\n",
            "utf-8",
        )
        return capture

    def _write_bounds(self, root, **overrides):
        bounds = {
            "maximum_prompt_tokens": 4096,
            "maximum_completion_tokens": 512,
            "request_feature_profile": "native_mtp_sampled_text_v1",
            "supports_stop_sequences": True,
            "supports_streaming": True,
            "supports_non_streaming": True,
            "has_qualified_row_mapped_transactions": True,
            "maximum_proposal_depth": 3,
            "supports_current_processor": True,
            "supports_current_state_cache": True,
            "tuple_admitted": True,
            "tuple_revoked": False,
            "revocation_state_available": True,
        }
        bounds.update(overrides)
        path = root / "bounds.json"
        path.write_text(json.dumps(bounds, sort_keys=True), "utf-8")
        return path


if __name__ == "__main__":
    unittest.main()
