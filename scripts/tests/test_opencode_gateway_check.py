import contextlib
import importlib.util
import io
import json
import os
import pathlib
import sys
import tempfile
import unittest


SCRIPT = pathlib.Path(__file__).parents[1] / "ops" / "lib" / "opencode-gateway-check.py"
SPEC = importlib.util.spec_from_file_location("opencode_gateway_check", SCRIPT)
MODULE = importlib.util.module_from_spec(SPEC)
assert SPEC.loader is not None
sys.modules[SPEC.name] = MODULE
SPEC.loader.exec_module(MODULE)


MODEL = MODULE.MODELS[0]
ARTIFACT = MODULE.MODEL_BINDINGS[MODEL]
MARKER_PATH = "/fixture/workspace/marker.txt"
MARKER = "malibu-0123456789abcdef"


def frame(value):
    return "data: " + json.dumps(value, separators=(",", ":")) + "\n\n"


def tool_stream(arguments_first='{"filePath":"/fixture/work', arguments_second='space/marker.txt"}'):
    return (frame({"id": "chatcmpl-tool", "choices": [{"index": 0, "delta": {"tool_calls": [{
        "index": 0, "id": "call-read", "type": "function",
        "function": {"name": "re", "arguments": arguments_first}}]}}]})
            + frame({"id": "chatcmpl-tool", "choices": [{"index": 0, "delta": {"tool_calls": [{
                "index": 0, "function": {"name": "ad", "arguments": arguments_second}}]}}]})
            + frame({"id": "chatcmpl-tool", "choices": [{"index": 0, "delta": {},
                                                            "finish_reason": "tool_calls"}],
                     "usage": {"prompt_tokens": 4, "completion_tokens": 5, "total_tokens": 9}})
            + "data: [DONE]\n\n").encode()


def request(messages=None, **updates):
    value = {"model": MODEL, "stream": True, "tool_choice": "auto", "max_tokens": 1024,
             "messages": messages or [{"role": "user", "content": "private prompt"}],
             "tools": [{"type": "function", "function": {"name": "read"}}]}
    value.update(updates)
    return json.dumps(value, separators=(",", ":")).encode()


class ToolStreamTests(unittest.TestCase):
    def test_fragmented_safe_read_is_accepted(self):
        metadata = MODULE.validate_tool_stream(tool_stream(), MARKER_PATH)
        self.assertEqual(metadata.stream_id, "chatcmpl-tool")
        self.assertEqual(metadata.tool_calls, [{"name": "read", "call_id": "call-read",
                                                "marker_path_match": True}])
        self.assertEqual(metadata.usage["total_tokens"], 9)

    def test_malformed_and_unsafe_arguments_are_rejected(self):
        cases = [
            ("{bad", ""),
            ('{"filePath":"/private/secret"}', ""),
            ('{"filePath":"/fixture/workspace/marker.txt","extra":true}', ""),
            ('{"filePath":"/fixture/workspace/marker.txt","filePath":"/private"}', ""),
        ]
        for first, second in cases:
            with self.subTest(first=first):
                with self.assertRaises(MODULE.CheckError):
                    MODULE.validate_tool_stream(tool_stream(first, second), MARKER_PATH)

    def test_response_budget_is_enforced(self):
        with self.assertRaisesRegex(MODULE.CheckError, "response_too_large"):
            MODULE.validate_tool_stream(b"x" * (MODULE.MAX_RESPONSE_BYTES + 1), MARKER_PATH)

    def test_response_model_mismatch_and_oversized_call_id_are_rejected(self):
        wrong_model = tool_stream().replace(b'"id":"chatcmpl-tool"',
                                            b'"id":"chatcmpl-tool","model":"other"', 1)
        with self.assertRaisesRegex(MODULE.CheckError, "response_model_mismatch"):
            MODULE.validate_tool_stream(wrong_model, MARKER_PATH, expected_model=MODEL)
        long_id = tool_stream().replace(b'call-read', b'x' * 129)
        with self.assertRaisesRegex(MODULE.CheckError, "invalid_tool_call_id"):
            MODULE.validate_tool_stream(long_id, MARKER_PATH)


class RequestTests(unittest.TestCase):
    def test_automatic_selection_and_output_budget_are_required(self):
        metadata = MODULE.validate_client_request(request(), MODEL, MARKER)
        self.assertEqual(metadata["output_budget"], 1024)
        omitted = json.loads(request())
        del omitted["tool_choice"]
        self.assertTrue(MODULE.validate_client_request(
            json.dumps(omitted).encode(), MODEL, MARKER
        )["tool_choice_auto"])
        for updates in ({"tool_choice": "required"}, {"tool_choice": {"type": "function"}},
                        {"max_tokens": 1025}, {"max_tokens": 0}, {"model": MODULE.MODELS[1]}):
            with self.subTest(updates=updates):
                with self.assertRaises(MODULE.CheckError):
                    MODULE.validate_client_request(request(**updates), MODEL, MARKER)

    def test_matching_tool_result_and_call_id_are_required(self):
        base = [{"role": "assistant", "tool_calls": [{"id": "call-read", "type": "function",
                 "function": {"name": "read", "arguments": json.dumps({"filePath": MARKER_PATH})}}]}]
        matched = base + [{"role": "tool", "tool_call_id": "call-read", "content": "00001| " + MARKER}]
        self.assertTrue(MODULE.validate_client_request(
            request(matched), MODEL, MARKER, MARKER_PATH
        )["tool_results"][0]["marker_match"])
        for tool in ({"role": "tool", "tool_call_id": "call-other", "content": MARKER},
                     {"role": "tool", "tool_call_id": "call-read", "content": "guessed"}):
            with self.assertRaises(MODULE.CheckError):
                MODULE.validate_client_request(request(base + [tool]), MODEL, MARKER, MARKER_PATH)

    def test_request_budget_and_credential_redaction(self):
        with self.assertRaisesRegex(MODULE.CheckError, "request_too_large") as caught:
            MODULE.validate_client_request(b"secret-key" * MODULE.MAX_BODY_BYTES, MODEL, MARKER)
        self.assertNotIn("secret-key", str(caught.exception))
        failure = {"schema_version": "macprovider.opencode_gateway_check.v1", "status": "fail",
                   "error_code": caught.exception.code, "receipt_validation": {"status": "pending"}}
        self.assertNotIn("secret", json.dumps(failure))
        secret = "sk-synthetic-never-print"
        private_request = request([{"role": "user", "content": secret}])
        metadata = MODULE.validate_client_request(private_request, MODEL, MARKER)
        self.assertNotIn(secret, json.dumps(metadata))
        state = MODULE.RecorderState(MODEL, MARKER_PATH, MARKER, secret, "proxy-token")
        self.assertEqual([state.claim_request() for _ in range(MODULE.MAX_REQUESTS + 1)],
                         [True] * MODULE.MAX_REQUESTS + [False])

    def test_sanitized_main_failure_does_not_print_exception_cause(self):
        original = MODULE._run
        secret = "sk-synthetic-never-print"

        def fail(_args):
            try:
                raise ValueError(secret)
            except ValueError as cause:
                raise MODULE.CheckError("invalid_json") from cause

        MODULE._run = fail
        output = io.StringIO()
        try:
            with contextlib.redirect_stdout(output):
                status = MODULE.main(["--opencode", "/bin/true", "--model", MODEL,
                                      "--key-file", "/private/unread"])
        finally:
            MODULE._run = original
        self.assertEqual(status, 1)
        self.assertNotIn(secret, output.getvalue())
        self.assertEqual(json.loads(output.getvalue())["error_code"], "invalid_json")


class OpenCodeEventTests(unittest.TestCase):
    def events(self, include_tool=True, result=MARKER, final=MARKER):
        rows = []
        if include_tool:
            rows.append({"type": "tool_use", "part": {"tool": "read", "callID": "call-read",
                         "state": {"status": "completed", "input": {"filePath": MARKER_PATH},
                                   "output": "00001| " + result}}})
        rows.append({"type": "text", "part": {"text": final}})
        return ("\n".join(json.dumps(row) for row in rows) + "\n").encode()

    def test_completed_tool_and_exact_final_are_accepted(self):
        result = MODULE.parse_opencode_events(self.events(), MARKER_PATH, MARKER)
        self.assertTrue(result["final_marker_match"])

    def test_guessed_final_without_completed_call_is_rejected(self):
        with self.assertRaisesRegex(MODULE.CheckError, "completed_tool_event_missing"):
            MODULE.parse_opencode_events(self.events(include_tool=False), MARKER_PATH, MARKER)

    def test_mismatched_result_or_nonexact_final_is_rejected(self):
        with self.assertRaisesRegex(MODULE.CheckError, "completed_tool_event_missing"):
            MODULE.parse_opencode_events(self.events(result="wrong"), MARKER_PATH, MARKER)
        with self.assertRaisesRegex(MODULE.CheckError, "final_marker_mismatch"):
            MODULE.parse_opencode_events(self.events(final="prefix " + MARKER), MARKER_PATH, MARKER)


class ReceiptTests(unittest.TestCase):
    def receipt(self, **updates):
        value = {"schema_version": "macprovider.buyer-receipt-view.v1", "request_id": "req-1",
                 "surface": "metadata", "pending_quarantined_visible": True, "attempts": []}
        value.update(updates)
        return json.dumps(value).encode()

    def test_pending_receipt_is_not_accepted(self):
        self.assertIsNone(MODULE.validate_receipt(b"", 404, "req-1"))
        self.assertIsNone(MODULE.validate_receipt(self.receipt(), 200, "req-1"))
        pending = [{"attempt_n": 1, "closed": False, "receipt_result": "pending",
                    "settlement_outcome": "pending"}]
        self.assertIsNone(MODULE.validate_receipt(self.receipt(attempts=pending), 200, "req-1"))

    def test_valid_terminal_receipt_is_minimized(self):
        attempt = {"attempt_n": 2, "closed": True, "receipt_result": "valid",
                   "settlement_outcome": "verified", "model_id": MODEL,
                   "reason": "not retained"}
        self.assertEqual(MODULE.validate_receipt(self.receipt(attempts=[attempt]), 200, "req-1", MODEL),
                         {"request_id": "req-1", "attempt_n": 2, "status": "verified"})

    def test_false_visibility_quarantine_and_wrong_request_are_rejected(self):
        quarantined = [{"attempt_n": 1, "closed": True, "receipt_result": "invalid",
                        "settlement_outcome": "quarantined"}]
        cases = [(self.receipt(pending_quarantined_visible=False), "receipt_visibility"),
                 (self.receipt(request_id="req-other"), "receipt_request_mismatch"),
                 (self.receipt(attempts=quarantined), "receipt_not_verified")]
        for body, code in cases:
            with self.subTest(code=code):
                with self.assertRaisesRegex(MODULE.CheckError, code):
                    MODULE.validate_receipt(body, 200, "req-1")
        wrong_model = [{"attempt_n": 1, "closed": True, "receipt_result": "valid",
                        "settlement_outcome": "verified", "model_id": "other"}]
        with self.assertRaisesRegex(MODULE.CheckError, "receipt_model_mismatch"):
            MODULE.validate_receipt(self.receipt(attempts=wrong_model), 200, "req-1", MODEL)


class ModelTests(unittest.TestCase):
    def test_exact_model_and_real_context_are_required(self):
        body = json.dumps({"data": [{"id": MODEL, "max_context_tokens": 16384}]}).encode()
        self.assertEqual(MODULE.validate_models(body, 200, MODEL), 16384)
        for value in (8192, None):
            row = {"id": MODEL}
            if value is not None:
                row["max_context_tokens"] = value
            with self.assertRaises(MODULE.CheckError):
                MODULE.validate_models(json.dumps({"data": [row]}).encode(), 200, MODEL)

    def test_config_pins_primary_and_small_model_without_buyer_key(self):
        data = json.loads(MODULE._config(MODEL, 16384, "http://127.0.0.1:1/v1", MARKER_PATH))
        self.assertEqual(data["model"], "malibu/" + MODEL)
        self.assertEqual(data["small_model"], "malibu/" + MODEL)
        self.assertEqual(data["provider"]["malibu"]["options"]["apiKey"], "{env:MALIBU_PROXY_TOKEN}")
        self.assertEqual(data["permission"]["read"][MARKER_PATH], "allow")

    def test_gateway_aliases_have_closed_qualified_artifact_bindings(self):
        self.assertEqual(MODULE.MODEL_BINDINGS, {
            "qwen3-coder-30b-a3b-instruct":
                "mlx-community/Qwen3-Coder-30B-A3B-Instruct-4bit",
            "qwen3-30b-a3b-instruct-2507":
                "mlx-community/Qwen3-30B-A3B-Instruct-2507-4bit",
        })
        self.assertEqual(ARTIFACT, "mlx-community/Qwen3-Coder-30B-A3B-Instruct-4bit")
        self.assertNotIn(ARTIFACT, MODULE.MODELS)
        with contextlib.redirect_stderr(io.StringIO()), self.assertRaises(SystemExit):
            MODULE.build_parser().parse_args(
                ["--opencode", "/bin/true", "--model", ARTIFACT, "--key-file", "/private/key"]
            )


class ProcessTests(unittest.TestCase):
    def test_combined_client_output_cap_kills_process_group(self):
        with tempfile.TemporaryDirectory() as directory:
            command = [sys.executable, "-c", "import sys;sys.stdout.write('x'*1100000)"]
            with self.assertRaisesRegex(MODULE.CheckError, "client_output_too_large"):
                MODULE._bounded_client_process(command, pathlib.Path(directory), dict(os.environ))


if __name__ == "__main__":
    unittest.main()
