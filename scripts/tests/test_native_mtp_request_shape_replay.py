import contextlib
import io
import json
import tempfile
import unittest
from pathlib import Path

from scripts import native_mtp_post_gateway_replay_analyze as analyzer
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
                self._shape("max-too-high", requested_max_completion_tokens=513, effective_max_output_tokens=513),
                self._shape("sampled", temperature=0.5),
                self._shape("bad-top-p", top_p=1.5),
                self._shape("omitted-max-too-high", requested_max_completion_tokens=None, effective_max_output_tokens=513),
                self._shape("unknown-requested-max-too-high", requested_max_completion_tokens=513, effective_max_output_tokens=513, unknown_top_level=True),
            ])
            bounds = self._write_bounds(root, maximum_prompt_tokens=1024, request_feature_profile="native_mtp_greedy_text_v1")
            _, plan = self._project(capture, bounds)
        reasons = {shape["shape_id"]: shape["pre_capacity_selector_reason"] for shape in plan["blocks"][0]["request_shape_templates"]}
        self.assertEqual(reasons["too-long"], "capability_mismatch")
        self.assertEqual(reasons["max-too-high"], "capability_mismatch")
        self.assertEqual(reasons["sampled"], "sampling")
        self.assertEqual(reasons["bad-top-p"], "sampling")
        self.assertEqual(reasons["omitted-max-too-high"], "capability_mismatch")
        self.assertEqual(reasons["unknown-requested-max-too-high"], "capability_mismatch")

    def test_feature_and_cache_reasons_precede_actual_bound_checks(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            capture = self._write_capture(root, [
                self._shape("unknown-over-prompt", prompt_tokens=2048, unknown_top_level=True),
                self._shape("tools-over-effective", tools=True, requested_max_completion_tokens=None, effective_max_output_tokens=513),
                self._shape("sticky-over-effective", key=True, cache_only=False, requested_max_completion_tokens=None, effective_max_output_tokens=513),
                self._shape("cache-miss-over-effective", key=True, cache_only=True, lease="miss", cached=0, requested_max_completion_tokens=None, effective_max_output_tokens=513),
            ])
            bounds = self._write_bounds(root, maximum_prompt_tokens=1024, maximum_completion_tokens=512)
            _, plan = self._project(capture, bounds)
        reasons = {shape["shape_id"]: shape["pre_capacity_selector_reason"] for shape in plan["blocks"][0]["request_shape_templates"]}
        self.assertEqual(reasons["unknown-over-prompt"], "unknown_request_field")
        self.assertEqual(reasons["tools-over-effective"], "tools")
        self.assertEqual(reasons["sticky-over-effective"], "conversation_key")
        self.assertEqual(reasons["cache-miss-over-effective"], "capability_mismatch")

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
        self.assertEqual(shape.requested_max_completion_tokens, 96)
        self.assertEqual(shape.effective_max_output_tokens, 96)
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
            runtime_shape = self._shape("runtime-missing-effective")
            runtime_shape.pop("effective_max_output_tokens")
            capture.write_text(json.dumps(self._header()) + "\n" + json.dumps(runtime_shape) + "\n", "utf-8")
            with self.assertRaisesRegex(ValueError, "effective_max_output_tokens:field_invalid"):
                replay.load_capture(capture)
            runtime_shape = self._shape("runtime-zero-requested", requested_max_completion_tokens=0)
            capture.write_text(json.dumps(self._header()) + "\n" + json.dumps(runtime_shape) + "\n", "utf-8")
            with self.assertRaisesRegex(ValueError, "requested_max_completion_tokens:field_invalid"):
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

    def test_convert_real_replay_output_to_analyzer_jsonl(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            policy = self._write_policy(root)
            replay_jsonl = self._write_replay_result(root, policy)
            out = root / "analyzer.jsonl"
            code = replay.main(["convert", "--replay", str(replay_jsonl), "--policy", str(policy), "--out", str(out)])
            self.assertEqual(code, 0)
            header, blocks = analyzer._load_jsonl(out)
            self.assertEqual(header["sample_digest_sha256"], "b" * 64)
            self.assertEqual(len(blocks), 2)
            disabled = next(block for block in blocks if block["path"] == "mtp_disabled")
            mixed = next(block for block in blocks if block["path"] == "observed_mixed")
            self.assertEqual([shape["shape_id"] for shape in mixed["request_shapes"]], ["eligible", "tool"])
            self.assertEqual(mixed["request_shapes"][0]["completion_tokens"], 11)
            self.assertEqual(mixed["request_shapes"][0]["pre_capacity_selector_reason"], "eligible")
            self.assertEqual(mixed["request_shapes"][0]["effective_path"], "native_mtp")
            self.assertEqual(mixed["request_shapes"][1]["pre_capacity_selector_reason"], "tools")
            self.assertEqual(mixed["request_shapes"][1]["effective_path"], "ordinary")
            self.assertTrue(all(shape["effective_path"] == "ordinary" for shape in disabled["request_shapes"]))
            self.assertGreater(disabled["ordinary_row_p95_ttft_seconds"], 0)
            self.assertGreater(mixed["ordinary_row_throughput_tps"], 0)
            self.assertFalse(analyzer._header_violations(header, analyzer._load_policy(policy), replay._sha256_file(policy)))
            self.assertFalse(analyzer._block_violations(disabled))
            self.assertFalse(analyzer._block_violations(mixed))

            success_replay = self._write_replay_result(root, policy, blocks=10)
            success_out = root / "analyzer-success.jsonl"
            replay.write_replay_analyzer_jsonl(replay.convert_replay_to_analyzer_jsonl(success_replay, policy), success_out)
            analysis = analyzer.analyze(success_out, policy)
            self.assertEqual(analysis["overall_status"], "PASS")
            self.assertEqual(analysis["paired_blocks"], 10)

    def test_convert_rejects_pending_projection_and_unsafe_actual_replay(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            policy = self._write_policy(root)
            projection = root / "projection.jsonl"
            projection.write_text(json.dumps({"schema": replay.PLAN_SCHEMA, "projection_stage": "offline_sanitized_shape_projection_only"}) + "\n", "utf-8")
            with self.assertRaisesRegex(ValueError, "projection-only"):
                replay.convert_replay_to_analyzer_jsonl(projection, policy)

            pending = self._write_replay_result(root, policy, pending=True)
            with self.assertRaisesRegex(ValueError, "pending_replay_result"):
                replay.convert_replay_to_analyzer_jsonl(pending, policy)

            mismatch = self._write_replay_result(root, policy, mutate=lambda record: record.update({"matches": False}) if record.get("shape_id") == "eligible" and record.get("actual_effective_path") == "native_mtp" else None)
            with self.assertRaisesRegex(ValueError, "actual_admission_mismatch"):
                replay.convert_replay_to_analyzer_jsonl(mismatch, policy)

            incomplete = self._write_replay_result(root, policy, mutate_completion=lambda record: record.update({"committed_timing_events": 0}) if record["request_id"] == "native_mtp-b0-r1-tool" else None)
            with self.assertRaisesRegex(ValueError, "committed_timing_events_mismatch"):
                replay.convert_replay_to_analyzer_jsonl(incomplete, policy)

            pending_row = self._write_replay_result(root, policy, mutate=lambda record: record.update({"pending_reason": "cache_warmup_missing"}) if record.get("shape_id") == "tool" and record.get("actual_effective_path") == "ordinary" else None)
            with self.assertRaisesRegex(ValueError, "row_pending"):
                replay.convert_replay_to_analyzer_jsonl(pending_row, policy)

            unreproduced = self._write_replay_result(root, policy, mutate=lambda record: record.update({"reproduced": False}) if record.get("shape_id") == "eligible" and record.get("actual_effective_path") == "native_mtp" else None)
            with self.assertRaisesRegex(ValueError, "row_unreproduced"):
                replay.convert_replay_to_analyzer_jsonl(unreproduced, policy)

    def test_convert_rejects_synthetic_claims_and_sample_token_mismatch(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            policy = self._write_policy(root)
            synthetic = self._write_replay_result(root, policy, mutate_shape=lambda shape: shape.update({"synthetic_content": True}) if shape["shape_id"] == "eligible" else None)
            with self.assertRaisesRegex(ValueError, "request_shape_unknown_fields:synthetic_content"):
                replay.convert_replay_to_analyzer_jsonl(synthetic, policy)

            token_mismatch = self._write_replay_result(root, policy, mutate=lambda record: record.update({"target_completion_tokens": 99}) if record.get("shape_id") == "tool" and record.get("actual_effective_path") == "ordinary" else None)
            with self.assertRaisesRegex(ValueError, "sample_completion_token_mismatch"):
                replay.convert_replay_to_analyzer_jsonl(token_mismatch, policy)

            pending_run = self._write_replay_result(root, policy, mutate_run=lambda record: record.update({"qualification_status": "pending"}) if record.get("path") == "native_mtp" else None)
            with self.assertRaisesRegex(ValueError, "qualification_status_not_qualified"):
                replay.convert_replay_to_analyzer_jsonl(pending_run, policy)

            target_unmatched = self._write_replay_result(root, policy, mutate_completion=lambda record: record.update({"target_completion_matched": False}) if record["request_id"] == "native_mtp-b0-r1-tool" else None)
            with self.assertRaisesRegex(ValueError, "target_completion_mismatch"):
                replay.convert_replay_to_analyzer_jsonl(target_unmatched, policy)

            throughput_mismatch = self._write_replay_result(root, policy, mutate_run=lambda record: record.update({"ordinary_observed_throughput_tps": 1}) if record.get("path") == "native_mtp" else None)
            with self.assertRaisesRegex(ValueError, "ordinary_observed_throughput_tps_mismatch"):
                replay.convert_replay_to_analyzer_jsonl(throughput_mismatch, policy)

            missing_identity = self._write_replay_result(root, policy, mutate_shape=lambda shape: shape.pop("served_model_hash_sha256") if shape["shape_id"] == "tool" else None)
            with self.assertRaisesRegex(ValueError, "served_model_hash_sha256_invalid"):
                replay.convert_replay_to_analyzer_jsonl(missing_identity, policy)

            wrong_identity = self._write_replay_result(root, policy, mutate_shape=lambda shape: shape.update({"served_model_hash_sha256": "9" * 64}) if shape["shape_id"] == "tool" else None)
            with self.assertRaisesRegex(ValueError, "served_model_hash_sha256_not_target"):
                replay.convert_replay_to_analyzer_jsonl(wrong_identity, policy)

            bad_filter = self._write_replay_result(root, policy, mutate_run=None, mutate_shape=None)
            data = [json.loads(line) for line in bad_filter.read_text("utf-8").splitlines()]
            data[0]["sample_filter_included_count"] = 1
            bad_filter.write_text("".join(json.dumps(record, sort_keys=True) + "\n" for record in data), "utf-8")
            with self.assertRaisesRegex(ValueError, "header_sample_filter_included_count_invalid"):
                replay.convert_replay_to_analyzer_jsonl(bad_filter, policy)

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
            "sample_method": "preregistered_digest_filter",
            "sample_window_started_at": "2026-10-07T00:00:00Z",
            "served_identity": "per_record_sha256",
            "build_source_commit": "deadbeef",
            "build_cdhash": "cdhashfixture",
            "build_identity_complete": True,
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
        requested_max_completion_tokens=96,
        effective_max_output_tokens=None,
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
            "stop_sequence_utf8_length_buckets": [],
            "requested_temperature": temperature,
            "requested_top_p": top_p,
            "requested_top_k": None,
            "requested_min_p": None,
            "requested_presence_penalty": 1 if presence_penalty else 0,
            "requested_frequency_penalty": 1 if frequency_penalty else 0,
            "requested_repetition_penalty": 1.1 if repetition_penalty else 1,
            "requested_n": requested_n,
            "requested_max_completion_tokens": requested_max_completion_tokens,
            "effective_max_output_tokens": effective_max_output_tokens if effective_max_output_tokens is not None else (requested_max_completion_tokens if requested_max_completion_tokens is not None else 96),
            "sampling_requested": temperature != 0 or top_p != 1,
            "multiple_completions_requested": requested_n != 1,
            "top_k_present": top_k,
            "min_p_nonzero": min_p,
            "frequency_penalty_nonzero": frequency_penalty,
            "presence_penalty_nonzero": presence_penalty,
            "repetition_penalty_nondefault": repetition_penalty,
            "logit_bias_present": logit_bias,
            "logit_bias_geometry": {"present": logit_bias},
            "tools_present": tools or tool_choice or tool_turn,
            "tool_count": 1 if tools else 0,
            "tool_choice_present": tool_choice,
            "tool_choice_kind": "auto" if tool_choice else "none",
            "tool_turn_state_present": tool_turn,
            "tool_message_count": 1 if tool_turn else 0,
            "assistant_tool_call_count": 1 if tool_turn else 0,
            "structured_output_requested": response_format != "text",
            "response_format_kind": response_format,
            "response_schema_geometry": {"kind": response_format},
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
            "anonymous_cache_group_sha256": None,
            "prompt_tokens": prompt_tokens,
            "completion_tokens": completion_tokens,
            "generated_completion_tokens": completion_tokens,
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

    def _write_policy(self, root):
        policy = replay.build_policy(
            privacy_review_id="privacy-1770-r015",
            privacy_reviewed_at="2026-10-07T00:00:00Z",
            preregistration_digest="a" * 64,
            sample_digest="b" * 64,
            seed=48015,
        )
        path = root / "policy.json"
        replay._write_json(path, policy)
        return path

    def _write_replay_result(self, root, policy, *, blocks=1, pending=False, mutate=None, mutate_completion=None, mutate_shape=None, mutate_run=None):
        policy_sha = replay._sha256_file(policy)
        capture_sha = "c" * 64
        bench_policy_sha = "1" * 64
        target_sha = "d" * 64
        shapes = [
            self._replay_shape("eligible", 11, target_sha),
            self._replay_shape("tool", 7, target_sha),
        ]
        if mutate_shape:
            for shape in shapes:
                mutate_shape(shape)
        records = [{
            "schema": replay.REPLAY_RESULT_SCHEMA,
            "record_type": "header",
            "provider_commit": "deadbeef",
            "model_id": "fixture-model",
            "target_sha256": target_sha,
            "mtp_sha256": "e" * 64,
            "tokenizer_sha256": "f" * 64,
            "policy_sha256": policy_sha,
            "bench_policy_sha256": bench_policy_sha,
            "sample_digest_sha256": "b" * 64,
            "preregistration_digest_sha256": "a" * 64,
            "privacy_review_id": "privacy-1770-r015",
            "capture_sha256": capture_sha,
            "capture_schema": replay.CAPTURE_SCHEMA,
            "capture_requires_native_mtp_off": True,
            "run_order": "paired_random_counterbalanced",
            "mixed_rows": 2,
            "max_native_active_rows": 1,
            "cache_key_scope": "paired_block_and_path_isolated",
            "exports_raw_prompt_text": False,
            "exports_recoverable_cache_groups": False,
            "completion_length_binding": replay.EXPECTED_COMPLETION_LENGTH_BINDING,
            "target_stop_control": replay.EXPECTED_TARGET_STOP_CONTROL,
            "synthetic_stand_ins": {"tools": {"tool_count": 1}},
            "run_metrics_version": 1,
            "sample_filter_included_count": len(shapes),
            "sample_filter_excluded_count": 0,
            "request_shapes": shapes,
        }]
        if pending:
            records.append({
                "schema": replay.REPLAY_RESULT_SCHEMA,
                "record_type": "pending",
                "status": "pending",
                "policy_sha256": policy_sha,
                "bench_policy_sha256": bench_policy_sha,
                "capture_sha256": capture_sha,
            })
        else:
            for block_index in range(blocks):
                records.extend([
                    self._replay_run(block_index, "ordinary", policy_sha, bench_policy_sha, capture_sha, [
                        ("eligible", 11, "mode_off", "ordinary"),
                        ("tool", 7, "mode_off", "ordinary"),
                    ], mutate=mutate, mutate_completion=mutate_completion, mutate_run=mutate_run),
                    self._replay_run(block_index, "native_mtp", policy_sha, bench_policy_sha, capture_sha, [
                        ("eligible", 11, "eligible", "native_mtp"),
                        ("tool", 7, "tools", "ordinary"),
                    ], mutate=mutate, mutate_completion=mutate_completion, mutate_run=mutate_run),
                ])
        path = root / f"replay-{len(list(root.glob('replay-*.jsonl')))}.jsonl"
        path.write_text("".join(json.dumps(record, sort_keys=True) + "\n" for record in records), "utf-8")
        return path

    def _replay_shape(self, shape_id, target_tokens, target_sha):
        return {
            "shape_id": shape_id,
            "stream": True,
            "requested_temperature": 0,
            "requested_top_p": 1,
            "requested_max_completion_tokens": 96,
            "effective_max_output_tokens": 96,
            "prompt_tokens": 256,
            "target_completion_tokens": target_tokens,
            "completion_tokens": target_tokens,
            "generated_completion_tokens": target_tokens,
            "pre_capacity_selector_reason": "mode_off",
            "pre_capacity_eligible": False,
            "effective_path": "ordinary",
            "conversation_key_present": False,
            "conversation_key_cache_only": False,
            "conversation_cache_lease": "not_applicable",
            "conversation_cache_cached_prompt_tokens": 0,
            "conversation_cache_retained_handoff": False,
            "anonymous_cache_group_sha256": None,
            "served_model_hash_sha256": target_sha,
            "served_weights_manifest_sha256": "2" * 64,
        }

    def _replay_run(self, block_index, path, policy_sha, bench_policy_sha, capture_sha, rows, *, mutate=None, mutate_completion=None, mutate_run=None):
        admissions = []
        completions = []
        total = 0
        for offset, (shape_id, target_tokens, reason, effective_path) in enumerate(rows):
            request_id = f"{path}-b{block_index}-r{offset}-{shape_id}"
            total += target_tokens
            expected_reason = "mode_off" if path == "ordinary" else reason
            expected_path = "ordinary" if path == "ordinary" else effective_path
            admission = {
                "request_id": request_id,
                "shape_id": shape_id,
                "target_completion_tokens": target_tokens,
                "effective_max_output_tokens": 96,
                "expected_selector_reason": expected_reason,
                "actual_selector_reason": reason,
                "expected_effective_path": expected_path,
                "actual_effective_path": effective_path,
                "matches": expected_reason == reason and expected_path == effective_path,
                "reproduced": True,
                "pending_reason": None,
            }
            if mutate:
                mutate(admission)
            admissions.append(admission)
            completion = {
                "request_id": request_id,
                "target_completion_tokens": target_tokens,
                "completion_tokens": target_tokens,
                "target_completion_matched": True,
                "target_stop_triggered": False,
                "generated_completion_tokens": target_tokens,
                "committed_timing_events": target_tokens,
                "ttft_seconds": 0.01 + offset / 100,
                "inter_token_gaps": [0.002 + offset / 1000] * (target_tokens - 1),
            }
            if mutate_completion:
                mutate_completion(completion)
            completions.append(completion)
        result = {
            "schema": replay.REPLAY_RESULT_SCHEMA,
            "record_type": "run",
            "policy_sha256": policy_sha,
            "bench_policy_sha256": bench_policy_sha,
            "capture_sha256": capture_sha,
            "block_index": block_index,
            "path": path,
            "order_position": 0 if path == "ordinary" else 1,
            "requests": len(rows),
            "wall_seconds": 0.5,
            "ordinary_observed_requests": sum(1 for _, _, _, effective_path in rows if effective_path == "ordinary"),
            "ordinary_observed_completion_tokens": sum(tokens for _, tokens, _, effective_path in rows if effective_path == "ordinary"),
            "ordinary_observed_interval_seconds": sum(tokens for _, tokens, _, effective_path in rows if effective_path == "ordinary") / 100,
            "ordinary_observed_throughput_tps": 100,
            "aggregate_completion_tokens": total,
            "aggregate_throughput_tps": total / 0.5,
            "qualification_status": "qualified",
            "sample_coverage_complete": True,
            "admission_observation_complete": True,
            "missing_admission_request_ids": [],
            "target_completion_observation_complete": True,
            "target_completion_mismatch_request_ids": [],
            "committed_timing_observation_complete": True,
            "completion_tokens_by_request": completions,
            "effective_paths": [
                {"request_id": item["request_id"], "effective_path": item["actual_effective_path"], "selector_reason": item["actual_selector_reason"], "other_active_rows": 0}
                for item in admissions
            ],
            "admission_projection": admissions,
        }
        if mutate_run:
            mutate_run(result)
        return result


if __name__ == "__main__":
    unittest.main()
