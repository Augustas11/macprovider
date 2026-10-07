import contextlib
import io
import json
import tempfile
import unittest
from pathlib import Path

from scripts import native_mtp_request_shape_replay as replay


class NativeMTPRequestShapeReplayTests(unittest.TestCase):
    def test_project_selector_ordering_and_pending_replay_contract(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            capture = self._write_capture(root, [
                self._shape("cache-miss", key=True, cache_only=True, lease="miss", cached=0),
                self._shape("sticky-unknown", key=True, cache_only=False, unknown_top_level=True),
                self._shape("cache-hit", key=True, cache_only=True, lease="hit", cached=9),
                self._shape("unknown", unknown_top_level=True),
                self._shape("reasoning", reasoning=True),
                self._shape("ordinary"),
            ])
            bounds = self._write_bounds(root)
            policy, plan = self._project(capture, bounds)
        reasons = {shape["shape_id"]: shape["pre_capacity_selector_reason"] for shape in plan["blocks"][0]["request_shape_templates"]}
        self.assertEqual(reasons["cache-miss"], "eligible")
        self.assertEqual(reasons["sticky-unknown"], "unknown_request_field")
        self.assertEqual(reasons["cache-hit"], "conversation_key")
        self.assertEqual(reasons["reasoning"], "reasoning_or_template")
        self.assertEqual(plan["qualification_status"], "PENDING_REAL_LAB_REPLAY")
        self.assertEqual(plan["replay_requirements"]["status"], "PENDING")
        emitted = plan["blocks"][0]["request_shape_templates"][0]
        self.assertNotIn("prompt_tokens", emitted)
        self.assertNotIn("served_model_hash_sha256", emitted)
        self.assertNotIn("build_cdhash", json.dumps(plan["blocks"]))
        self.assertEqual(policy["sample_digest_sha256"], plan["sample_digest_sha256"])
        self.assertEqual(plan["sample_report"]["captured_request_count"], 6)
        self.assertIn("no population representativeness", plan["sample_report"]["representativeness_claim"])

    def test_selector_order_keeps_unknown_before_sticky_and_tools(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            capture = self._write_capture(root, [
                self._shape("sticky-tool", key=True, cache_only=False, tools=True),
                self._shape("unknown-tool", tools=True, unknown_top_level=True),
                self._shape("logprobs-logit", logprobs=True, logit_bias=True),
                self._shape("tools-logit-bias", tools=True, logit_bias=True),
                self._shape("sticky-presence", key=True, cache_only=False, presence_penalty=True),
            ])
            bounds = self._write_bounds(root)
            _, plan = self._project(capture, bounds)
        reasons = {shape["shape_id"]: shape["pre_capacity_selector_reason"] for shape in plan["blocks"][0]["request_shape_templates"]}
        self.assertEqual(reasons["sticky-tool"], "conversation_key")
        self.assertEqual(reasons["unknown-tool"], "unknown_request_field")
        self.assertEqual(reasons["logprobs-logit"], "logprobs")
        self.assertEqual(reasons["tools-logit-bias"], "tools")
        self.assertEqual(reasons["sticky-presence"], "logit_controls")

    def test_tuple_bounds_drive_capability_and_sampling_reasons(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            capture = self._write_capture(root, [
                self._shape("too-long", prompt_tokens=2048),
                self._shape("max-too-high", max_completion_tokens=513),
                self._shape("sampled", temperature=0.5),
                self._shape("bad-top-p", top_p=1.5),
            ])
            bounds = self._write_bounds(root, maximum_prompt_tokens=1024, request_feature_profile="native_mtp_greedy_text_v1")
            _, plan = self._project(capture, bounds)
        reasons = {shape["shape_id"]: shape["pre_capacity_selector_reason"] for shape in plan["blocks"][0]["request_shape_templates"]}
        self.assertEqual(reasons["too-long"], "capability_mismatch")
        self.assertEqual(reasons["max-too-high"], "capability_mismatch")
        self.assertEqual(reasons["sampled"], "sampling")
        self.assertEqual(reasons["bad-top-p"], "sampling")


    def test_sampler_support_allows_high_finite_temperature_on_sampled_tuple(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            capture = self._write_capture(root, [
                self._shape("hot-sampled", temperature=99),
                self._shape("negative-temp", temperature=-0.1),
            ])
            bounds = self._write_bounds(root, request_feature_profile="native_mtp_sampled_text_v1")
            _, plan = self._project(capture, bounds)
        reasons = {shape["shape_id"]: shape["pre_capacity_selector_reason"] for shape in plan["blocks"][0]["request_shape_templates"]}
        self.assertEqual(reasons["hot-sampled"], "eligible")
        self.assertEqual(reasons["negative-temp"], "sampling")

    def test_runtime_request_shape_uses_exact_sanitized_capture_fields(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            runtime_shape = self._shape(
                "runtime-sampled",
                temperature=0.7,
                top_p=0.9,
                top_logprobs=True,
                unknown_stream_options=True,
                response_format="json_object",
            )
            capture = root / "runtime.jsonl"
            capture.write_text(json.dumps(self._header()) + "\n" + json.dumps(runtime_shape) + "\n", "utf-8")
            _, shapes = replay.load_capture(capture)
        shape = shapes[0]
        self.assertEqual(shape.requested_temperature, 0.7)
        self.assertEqual(shape.requested_top_p, 0.9)
        self.assertEqual(shape.top_logprobs_requested, True)
        self.assertEqual(shape.unknown_stream_option_keys_present, True)
        self.assertEqual(shape.response_format_kind, "json_object")
        self.assertNotIn("prompt", runtime_shape)
        self.assertNotIn("model", runtime_shape)

    def test_runtime_request_shape_rejects_missing_selector_proof_fields(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            runtime_shape = self._shape("runtime-missing")
            runtime_shape.pop("requested_temperature")
            capture = root / "runtime-missing.jsonl"
            capture.write_text(json.dumps(self._header()) + "\n" + json.dumps(runtime_shape) + "\n", "utf-8")
            with self.assertRaisesRegex(ValueError, "requested_temperature:field_invalid"):
                replay.load_capture(capture)

    def test_privacy_rejects_raw_prompt_key_and_duplicate_json(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            capture = root / "capture.jsonl"
            bad = self._shape("bad")
            bad["prompt"] = "raw buyer prompt"
            capture.write_text(json.dumps(self._header()) + "\n" + json.dumps(bad) + "\n", "utf-8")
            with self.assertRaisesRegex(ValueError, "raw_text_field"):
                replay.load_capture(capture)
            duplicate = root / "duplicate.jsonl"
            duplicate.write_text('{"schema":"x","schema":"y"}\n', "utf-8")
            with self.assertRaisesRegex(ValueError, "duplicate JSON key"):
                replay.load_capture(duplicate)

    def test_projection_tool_refuses_to_claim_real_replay(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            plan = root / "plan.json"
            plan.write_text(json.dumps({"schema": replay.PLAN_SCHEMA, "blocks": []}), "utf-8")
            with contextlib.redirect_stdout(io.StringIO()) as stdout:
                code = replay.main(["run", "--plan", str(plan)])
            self.assertEqual(code, 2)
            self.assertIn("replay runner disabled", stdout.getvalue())

    def _project(self, capture, bounds):
        return replay.project_capture(
            capture,
            bounds,
            blocks=10,
            privacy_review_id="privacy-1770-r015",
            privacy_reviewed_at="2026-10-07T00:00:00Z",
            preregistration_digest="a" * 64,
            seed=48015,
            sampling_plan_id="r015-bounded-prospective-sample",
            sample_period_start="2026-10-07T00:00:00Z",
            sample_period_end="2026-10-07T01:00:00Z",
        )

    def _header(self):
        return {
            "schema": replay.CAPTURE_SCHEMA,
            "record_type": "header",
            "captured_at": "2026-10-07T00:00:00Z",
            "native_mtp_mode": "off",
            "capture_requires_native_mtp_off": True,
            "served_identity": "per_record_sha256",
            "build_source_commit": "deadbeef",
            "build_cdhash": "cdhashfixture",
            "cli_version": "fixture",
            "max_records": 100,
            "max_bytes": 100000,
        }

    def _shape(
        self,
        shape_id,
        *,
        prompt_tokens=256,
        completion_tokens=64,
        max_completion_tokens=96,
        key=False,
        cache_only=False,
        lease="not_applicable",
        cached=0,
        retained=False,
        stream=True,
        stop_sequences=0,
        temperature=0,
        top_p=1,
        requested_n=1,
        top_k=False,
        min_p=False,
        frequency_penalty=False,
        presence_penalty=False,
        repetition_penalty=False,
        logit_bias=False,
        tools=False,
        tool_choice=False,
        tool_turn=False,
        response_format="text",
        logprobs=False,
        top_logprobs=False,
        logit_controls=False,
        reasoning=False,
        multimodal=False,
        unknown_top_level=False,
        unknown_stream_options=False,
        pre_reason="mode_off",
        pre_eligible=False,
    ):
        if key and cache_only and lease == "not_applicable":
            lease = "miss"
        reason = pre_reason
        eligible = pre_eligible
        return {
            "schema": replay.CAPTURE_SCHEMA,
            "record_type": "request_shape",
            "sequence": 1,
            "shape_id": shape_id,
            "captured_at": "2026-10-07T00:00:01Z",
            "served_model_hash_sha256": "a" * 64,
            "served_weights_manifest_sha256": "b" * 64,
            "native_mtp_tuple_sha256": "none",
            "native_mtp_served_snapshot_id_sha256": "none",
            "native_mtp_target_generation": 0,
            "stream": stream,
            "stop_sequences": stop_sequences,
            "requested_temperature": temperature,
            "requested_top_p": top_p,
            "requested_n": requested_n,
            "requested_max_completion_tokens": max_completion_tokens,
            "resolved_max_completion_tokens": max_completion_tokens,
            "sampling_requested": temperature != 0 or top_p != 1,
            "multiple_completions_requested": requested_n != 1,
            "top_k_present": top_k,
            "min_p_nonzero": min_p,
            "frequency_penalty_nonzero": frequency_penalty,
            "presence_penalty_nonzero": presence_penalty,
            "repetition_penalty_nondefault": repetition_penalty,
            "logit_bias_present": logit_bias,
            "tools_present": tools or tool_choice or tool_turn,
            "tool_choice_present": tool_choice,
            "tool_turn_state_present": tool_turn,
            "structured_output_requested": response_format != "text",
            "response_format_kind": response_format,
            "logprobs_requested": logprobs or top_logprobs,
            "top_logprobs_requested": top_logprobs,
            "logit_controls_requested": presence_penalty or frequency_penalty or min_p or repetition_penalty or logit_bias,
            "reasoning_or_template_model": reasoning,
            "multimodal_requested": multimodal,
            "unknown_request_fields_present": unknown_top_level or unknown_stream_options,
            "unknown_top_level_keys_present": unknown_top_level,
            "unknown_stream_option_keys_present": unknown_stream_options,
            "conversation_key_present": key,
            "conversation_key_cache_only": cache_only,
            "conversation_cache_lease": lease,
            "conversation_cache_cached_prompt_tokens": cached,
            "conversation_cache_retained_handoff": retained,
            "prompt_tokens": prompt_tokens,
            "completion_tokens": completion_tokens,
            "generated_completion_tokens": completion_tokens,
            "max_completion_tokens_requested": max_completion_tokens,
            "pre_capacity_selector_reason": reason,
            "pre_capacity_eligible": eligible,
            "effective_path": "ordinary",
        }

    def _write_capture(self, root, shapes):
        capture = root / "capture.jsonl"
        capture.write_text(
            "\n".join(json.dumps(record, sort_keys=True) for record in [self._header(), *shapes]) + "\n",
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
