"""Buyer-UX conformance checker against recorded gateway responses (#2107)."""
from __future__ import annotations

import importlib.util
import json
import pathlib
import tempfile
import unittest

ROOT = pathlib.Path(__file__).resolve().parents[2]
_spec = importlib.util.spec_from_file_location("buyer_ux_conformance", ROOT / "scripts" / "buyer_ux_conformance.py")
bux = importlib.util.module_from_spec(_spec)
_spec.loader.exec_module(bux)

MODEL = "Jundot/GLM-5.3-Flash-oQ4e-mtp"


def ok(body: dict) -> "bux.Response":
    return bux.Response(200, json.dumps(body).encode())


def sse(*events: dict) -> "bux.Response":
    text = "".join("data: " + json.dumps(e) + "\n\n" for e in events) + "data: [DONE]\n\n"
    return bux.Response(200, text.encode())


def chat(message: dict, finish: str, usage: dict | None = None) -> "bux.Response":
    return ok({"choices": [{"index": 0, "message": dict(role="assistant", **message), "finish_reason": finish}],
               "usage": usage or {"prompt_tokens": 1, "completion_tokens": 1}})


CALL = {"id": "call_0123456789abcdef", "type": "function", "function": {"name": "read_file", "arguments": "{\"path\":\"/etc/hosts\"}"}}

# Recorded post-#2107 responses for a GLM-5.3 provider.
GOOD = {
    "models": ok({"data": [{"id": MODEL, "max_context_tokens": 65536, "capabilities": {
        "tools": True, "tool_choice": ["auto", "none"], "reasoning": True, "response_format": True, "vision": False, "context_length": 65536}}]}),
    "tool_auto": chat({"content": None, "tool_calls": [CALL], "reasoning_content": "Read it."}, "tool_calls"),
    "tool_choice_unsupported": bux.Response(400, json.dumps({"error": {"code": "unsupported_tool_choice", "message": "No compatible provider"}}).encode()),
    "stream": sse(
        {"choices": [{"index": 0, "delta": {"role": "assistant", "content": ""}, "finish_reason": None}]},
        {"choices": [{"index": 0, "delta": {"reasoning_content": "Two files."}, "finish_reason": None}]},
        {"choices": [{"index": 0, "delta": {"tool_calls": [{"index": 0, "id": "call_a", "type": "function", "function": {"name": "read_file", "arguments": ""}}]}, "finish_reason": None}]},
        {"choices": [{"index": 0, "delta": {"tool_calls": [{"index": 0, "function": {"arguments": "{\"path\":\"/etc/hosts\"}"}}]}, "finish_reason": None}]},
        {"choices": [{"index": 0, "delta": {"tool_calls": [{"index": 1, "id": "call_b", "type": "function", "function": {"name": "read_file", "arguments": "{\"path\":\"/etc/passwd\"}"}}]}, "finish_reason": None}]},
        {"choices": [{"index": 0, "delta": {}, "finish_reason": "tool_calls"}]},
        {"choices": [], "usage": {"prompt_tokens": 9, "completion_tokens": 30}},
    ),
    "round_trip": chat({"content": "The hosts file maps localhost to 127.0.0.1."}, "stop"),
    "plain": chat({"content": "4", "reasoning_content": "2+2 is 4."}, "stop",
                  {"prompt_tokens": 9, "completion_tokens": 9, "completion_tokens_details": {"reasoning_tokens": 6}}),
    "json": chat({"content": "{\"color\":\"blue\"}", "reasoning_content": "JSON."}, "stop"),
    "stop": chat({"content": "1, 2, 3, 4, 5, 6, ", "reasoning_content": "Count 1 to 10: 7 is past the stop."}, "stop"),
    "messages": ok({"type": "message", "role": "assistant", "content": [
        {"type": "thinking", "thinking": "2+2.", "signature": ""}, {"type": "text", "text": "4"}]}),
    "responses": ok({"status": "completed", "output": [{"type": "function_call", "call_id": "call_x", "name": "read_file", "arguments": "{}"}]}),
    "context": bux.Response(400, json.dumps({"error": {"code": "context_exceeds_capacity", "message": "The prompt exceeds the model's context window."}}).encode()),
    "length": chat({"content": "Once upon a"}, "length"),
}


def transport(responses: dict):
    def send(method, path, headers, body):
        if path == "/models":
            return responses["models"]
        if path == "/messages":
            assert headers.get("anthropic-beta") and body.get("thinking")
            return responses["messages"]
        if path == "/responses":
            return responses["responses"]
        content = body["messages"][0].get("content") or ""
        if body.get("stream"):
            return responses["stream"]
        if body.get("tools") and len(body["messages"]) == 3:
            return responses["round_trip"]
        if body.get("tools"):
            choice = body.get("tool_choice")
            return responses["tool_auto"] if choice == "auto" else responses["tool_choice_unsupported"]
        if body.get("response_format"):
            return responses["json"]
        if body.get("stop"):
            return responses["stop"]
        if body.get("max_tokens") == 8:
            return responses["length"]
        if len(content) > 10_000:
            return responses["context"]
        return responses["plain"]
    return send


class BuyerUXConformanceTests(unittest.TestCase):
    def run_with(self, **overrides) -> dict:
        return bux.run_checks(transport(dict(GOOD, **overrides)), MODEL)

    def test_recorded_post_fix_glm_passes_and_advertises_what_it_serves(self):
        result = self.run_with()
        failed = {k: v for k, v in result["checks"].items() if v["status"] == bux.FAIL}
        self.assertEqual(failed, {})
        self.assertEqual(result["checks"]["tools_required"]["status"], bux.UNSUPPORTED)
        caps = result["capabilities"]
        self.assertTrue(caps["tools"] and caps["reasoning"] and caps["response_format"] and caps["messages"] and caps["responses"])
        self.assertEqual(caps["tool_choice"], ["auto", "none"])

    def test_pre_fix_glm_raw_text_tool_call_fails_tools(self):
        # The #2107 live probe: the call came back as text with finish_reason stop.
        raw = chat({"content": "The user wants me to read the file.</think><tool_call>read_file<arg_key>path</arg_key><arg_value>/etc/hosts</arg_value></tool_call>"}, "stop")
        result = self.run_with(tool_auto=raw)
        self.assertEqual(result["checks"]["tools_auto"]["status"], bux.FAIL)
        self.assertFalse(result["capabilities"]["tools"])
        self.assertEqual(result["capabilities"]["tool_choice"], [])

    def test_non_stream_tool_calls_need_unique_ids_and_function_type(self):
        """Re-audit r1: a call a client cannot answer by id fails tools_auto."""
        second = dict(CALL, function={"name": "read_file", "arguments": "{\"path\":\"/etc/passwd\"}"})
        for calls, detail in (
            ([{k: v for k, v in CALL.items() if k != "id"}], "without an id"),
            ([dict(CALL, id="")], "without an id"),
            ([CALL, second], "duplicate tool call ids"),
            ([dict(CALL, type="tool")], "type"),
            ([{k: v for k, v in CALL.items() if k != "type"}], "type"),
        ):
            result = self.run_with(tool_auto=chat({"content": None, "tool_calls": calls}, "tool_calls"))
            self.assertEqual(result["checks"]["tools_auto"]["status"], bux.FAIL, calls)
            self.assertIn(detail, result["checks"]["tools_auto"]["detail"])
            self.assertFalse(result["capabilities"]["tools"])
        two = chat({"content": None, "tool_calls": [CALL, dict(second, id="call_fedcba9876543210")]}, "tool_calls")
        self.assertEqual(self.run_with(tool_auto=two)["checks"]["tools_auto"]["status"], bux.PASS)

    def test_reasoning_leak_and_missing_reasoning_fail(self):
        leak = chat({"content": "2+2 is 4.</think>4"}, "stop")
        self.assertEqual(self.run_with(plain=leak)["checks"]["no_reasoning_leak"]["status"], bux.FAIL)
        unsplit = chat({"content": "4"}, "stop")
        result = self.run_with(plain=unsplit)
        self.assertEqual(result["checks"]["no_reasoning_leak"]["status"], bux.FAIL)
        self.assertFalse(result["capabilities"]["reasoning"])

    def test_reasoning_requirement_comes_from_the_model_contract_not_models(self):
        """Re-audit r1: a masked or absent /models reasoning flag does not waive
        reasoning_content and reasoning_tokens for a GLM-5 model."""
        no_reasoning_fields = chat({"content": "4"}, "stop")
        no_thinking_block = ok({"type": "message", "role": "assistant", "content": [{"type": "text", "text": "4"}]})
        for caps in ({"tools": True, "tool_choice": ["auto", "none"], "reasoning": False}, {"tools": True, "tool_choice": ["auto", "none"]}):
            models = ok({"data": [{"id": MODEL, "max_context_tokens": 65536, "capabilities": caps}]})
            result = self.run_with(models=models, plain=no_reasoning_fields, messages=no_thinking_block)
            self.assertEqual(result["checks"]["no_reasoning_leak"]["status"], bux.FAIL, caps)
            self.assertEqual(result["checks"]["messages_beta_thinking"]["status"], bux.FAIL, caps)
            self.assertFalse(result["capabilities"]["reasoning"])
        # A model outside the reasoning families needs only clean content.
        qwen = "mlx-community/Qwen3-8B-4bit"
        models = ok({"data": [{"id": qwen, "max_context_tokens": 32768, "capabilities": {"reasoning": True}}]})
        result = bux.run_checks(transport(dict(GOOD, models=models, plain=no_reasoning_fields)), qwen)
        self.assertEqual(result["checks"]["no_reasoning_leak"]["status"], bux.PASS)

    def test_stream_index_and_error_failures(self):
        all_zero = sse(
            {"choices": [{"index": 0, "delta": {"tool_calls": [{"index": 0, "id": "call_a", "function": {"name": "read_file", "arguments": "{}"}}]}}]},
            {"choices": [{"index": 0, "delta": {"tool_calls": [{"index": 0, "id": "call_b", "function": {"name": "read_file", "arguments": "{}"}}]}}]},
            {"choices": [{"index": 0, "delta": {}, "finish_reason": "tool_calls"}]},
            {"choices": [], "usage": {"prompt_tokens": 1}},
        )
        self.assertEqual(self.run_with(stream=all_zero)["checks"]["stream_tool_deltas"]["status"], bux.FAIL)
        # The #2107 D5 Qwen3-8B stream: role chunk then an upstream error.
        errored = sse({"choices": [{"index": 0, "delta": {"role": "assistant", "content": ""}}]},
                      {"error": {"code": "upstream_provider_error", "message": "Upstream provider error"}})
        result = self.run_with(stream=errored)
        self.assertIn("upstream_provider_error", result["checks"]["stream_tool_deltas"]["detail"])
        self.assertFalse(result["capabilities"]["tools"])

    def test_reasoning_markup_split_across_stream_deltas_fails(self):
        """Re-audit r1: a delimiter spanning deltas is caught in the assembled content."""
        events = list(GOOD["stream"].sse())
        split = [{"choices": [{"index": 0, "delta": {"content": part}, "finish_reason": None}]} for part in ("Two files.</th", "ink>")]
        result = self.run_with(stream=sse(*(events[:1] + split + events[1:])))
        self.assertEqual(result["checks"]["stream_tool_deltas"]["status"], bux.FAIL)
        self.assertIn("reasoning markup", result["checks"]["stream_tool_deltas"]["detail"])
        self.assertFalse(result["capabilities"]["tools"])

    def test_json_mode_stop_messages_responses_and_finish_failures(self):
        bad_json = bux.Response(502, json.dumps({"error": {"code": "malformed_json_response", "message": "x"}}).encode())
        self.assertFalse(self.run_with(json=bad_json)["capabilities"]["response_format"])
        past_stop = chat({"content": "1, 2, 3, 4, 5, 6, 7, 8"}, "stop")
        self.assertFalse(self.run_with(stop=past_stop)["capabilities"]["base"])
        beta_rejected = bux.Response(400, json.dumps({"type": "error", "error": {"code": "unsupported_content_shape", "message": "Anthropic beta features are not supported"}}).encode())
        self.assertFalse(self.run_with(messages=beta_rejected)["capabilities"]["messages"])
        no_call = ok({"status": "completed", "output": [{"type": "message", "content": []}]})
        self.assertFalse(self.run_with(responses=no_call)["capabilities"]["responses"])
        self.assertFalse(self.run_with(length=chat({"content": "x"}, "stop"))["capabilities"]["base"])
        unreadable = bux.Response(500, b"Traceback (most recent call last)")
        self.assertFalse(self.run_with(context=unreadable)["capabilities"]["base"])

    def test_record_gate(self):
        with tempfile.TemporaryDirectory() as tmp:
            path = pathlib.Path(tmp) / "records.json"
            result = self.run_with()
            record = {"model": MODEL, "gateway": "https://api.malibu.tech/v1", "checked_at": "2026-10-22T00:00:00Z",
                      "checks": result["checks"], "capabilities": result["capabilities"]}
            path.write_text(json.dumps({"schema_version": bux.SCHEMA, "records": {"zai-org/glm-5.3-flash": record}}))
            advertised = bux.advertised_capabilities(MODEL)
            self.assertEqual(advertised["tool_choice"], ["auto", "none"])
            bux.require_promotable("zai-org/glm-5.3-flash", MODEL, advertised, path)
            # The coordinator indexes records case-insensitively by model id.
            bux.require_promotable("zai-org/glm-5.3-flash", MODEL.lower(), advertised, path)
            with self.assertRaisesRegex(bux.ConformanceError, "no record"):
                bux.require_promotable("other", MODEL, advertised, path)
            # Re-audit r1: a passing record for another served model never
            # qualifies the key's current model.
            with self.assertRaisesRegex(bux.ConformanceError, "not the served model"):
                bux.require_promotable("zai-org/glm-5.3-flash", "zai-org/GLM-5.3-Flash-other", advertised, path)
            # Advertising a mode the record did not pass is refused.
            with self.assertRaisesRegex(bux.ConformanceError, "tool_choice"):
                bux.require_promotable("zai-org/glm-5.3-flash", MODEL, dict(advertised, tool_choice=["auto", "none", "required"]), path)
            # A record whose capabilities do not follow its checks is invalid.
            record["capabilities"]["tools"] = False
            path.write_text(json.dumps({"schema_version": bux.SCHEMA, "records": {"k": record}}))
            with self.assertRaisesRegex(bux.ConformanceError, "derived from its checks"):
                bux.load_records(path)

    def test_owed_entries_and_status(self):
        """SPEC-023 §16.11 rule 4: an owed entry stands in for a first
        promotion's record until it lands; a record always decides."""
        with tempfile.TemporaryDirectory() as tmp:
            path = pathlib.Path(tmp) / "records.json"
            key = "zai-org/glm-5.3-flash"
            owed = {key: {"model": MODEL, "release_id": "published-test-v1"}}
            path.write_text(json.dumps({"schema_version": bux.SCHEMA, "records": {}, "owed": owed}))
            advertised = bux.advertised_capabilities(MODEL)
            self.assertIsNone(bux.require_promotable(key, MODEL, advertised, path, conformance_owed=True,
                                                     release_id="published-test-v1"))
            # The owed entry is bound to the promoting release.
            with self.assertRaisesRegex(bux.ConformanceError, "not the promoting release"):
                bux.require_promotable(key, MODEL, advertised, path, conformance_owed=True, release_id="other-release")
            with self.assertRaisesRegex(bux.ConformanceError, "no record"):
                bux.require_promotable(key, MODEL, advertised, path)
            with self.assertRaisesRegex(bux.ConformanceError, "not the served model"):
                bux.require_promotable(key, "other/model", advertised, path, conformance_owed=True)
            with self.assertRaisesRegex(bux.ConformanceError, "no owed entry"):
                bux.require_promotable("other", MODEL, advertised, path, conformance_owed=True)
            self.assertEqual([(e["catalog_key"], e["state"]) for e in bux.owed_status(path)], [(key, "owed")])
            self.assertEqual(bux.capped_model_counts(path), (1, 1))
            # A failing record lands: it decides, so the promotion is blocked
            # and the owed key is not settled.
            failing = self.run_with(stream=sse({"choices": [{"index": 0, "delta": {}, "finish_reason": "stop"}]}))
            record = {"model": MODEL, "gateway": "https://api.malibu.tech/v1", "checked_at": "2026-10-22T00:00:00Z",
                      "checks": failing["checks"], "capabilities": failing["capabilities"]}
            path.write_text(json.dumps({"schema_version": bux.SCHEMA, "records": {key: record}, "owed": owed}))
            with self.assertRaisesRegex(bux.ConformanceError, "advertises tools"):
                bux.require_promotable(key, MODEL, advertised, path, conformance_owed=True)
            self.assertEqual(bux.owed_status(path)[0]["state"], "failing")
            # A passing record settles it.
            passing = self.run_with()
            record.update(checks=passing["checks"], capabilities=passing["capabilities"])
            path.write_text(json.dumps({"schema_version": bux.SCHEMA, "records": {key: record}, "owed": owed}))
            self.assertEqual(bux.owed_status(path)[0]["state"], "settled")
            # The record for the owed model lifts the mask (counted once).
            self.assertEqual(bux.capped_model_counts(path), (1, 0))
            # Malformed owed entries and unknown top-level keys are refused.
            for doc, fragment in (
                ({"owed": []}, "owed must be an object"),
                ({"owed": {key: {"model": MODEL}}}, "exactly model and release_id"),
                ({"owed": {key: {"model": " ", "release_id": "r"}}}, "non-empty unpadded"),
                ({"extra": {}}, "unknown top-level"),
            ):
                path.write_text(json.dumps(dict({"schema_version": bux.SCHEMA, "records": {}}, **doc)))
                with self.assertRaisesRegex(bux.ConformanceError, fragment):
                    bux.load_records(path)

    def test_checked_in_record_file_is_valid(self):
        bux.load_records(bux.RECORD_PATH)

    def test_advertised_capabilities_mirror_the_coordinator_families(self):
        self.assertFalse(bux.advertised_capabilities("mlx-community/Qwen2-VL-2B-Instruct-4bit")["tools"])
        self.assertTrue(bux.advertised_capabilities("mlx-community/Meta-Llama-3.1-8B-Instruct-4bit")["tools"])
        self.assertEqual(bux.advertised_capabilities("mlx-community/Qwen3.6-35B-A3B-4bit")["tool_choice"], ["auto", "none", "required", "named"])
        self.assertTrue(bux.advertised_capabilities("openai/gpt-oss-20b")["reasoning"])
        deepseek = bux.advertised_capabilities("deepseek/deepseek-v4-flash")
        self.assertEqual((deepseek["tools"], deepseek["tool_choice"], deepseek["reasoning"]), (True, ["auto", "none"], True))


if __name__ == "__main__":
    unittest.main()
