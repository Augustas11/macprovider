import contextlib
import importlib.util
import io
import json
import os
import pathlib
import re
import shutil
import subprocess
import sys
import tempfile
import time
import unittest
import uuid
from unittest import mock


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
BINDING = {"expected_provider_key_fingerprint": "a" * 64,
           "expected_model_hash": "sha256:" + "b" * 64,
           "expected_catalog_id": "catalog-fixture-v1"}
BINDING_ARGS = [argument for key, value in BINDING.items()
                for argument in ("--" + key.replace("_", "-"), value)]


def verified_attempt(**updates):
    value = {"attempt_n": 2, "closed": True, "receipt_result": "valid",
             "settlement_outcome": "verified", "model_id": ARTIFACT,
             "provider_receipt_key_fingerprint": BINDING["expected_provider_key_fingerprint"],
             "model_hash": BINDING["expected_model_hash"],
             "catalog_id": BINDING["expected_catalog_id"]}
    value.update(updates)
    return value


def frame(value):
    return "data: " + json.dumps(value, separators=(",", ":")) + "\n\n"


def tool_stream(arguments_first='{"filePath":"/fixture/work', arguments_second='space/marker.txt"}',
                model=None):
    model_field = {"model": model} if model is not None else {}
    return (frame({"id": "chatcmpl-tool", **model_field,
                   "choices": [{"index": 0, "delta": {"tool_calls": [{
        "index": 0, "id": "call-read", "type": "function",
        "function": {"name": "re", "arguments": arguments_first}}]}}]})
            + frame({"id": "chatcmpl-tool", **model_field,
                     "choices": [{"index": 0, "delta": {"tool_calls": [{
                "index": 0, "function": {"name": "ad", "arguments": arguments_second}}]}}]})
            + frame({"id": "chatcmpl-tool", **model_field,
                     "choices": [{"index": 0, "delta": {}, "finish_reason": "tool_calls"}],
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
        self.assertEqual(
            MODULE.validate_tool_stream(tool_stream(model=ARTIFACT), MARKER_PATH,
                                        expected_model=ARTIFACT).stream_id,
            "chatcmpl-tool",
        )
        wrong_model = tool_stream(model="other")
        with self.assertRaisesRegex(MODULE.CheckError, "response_model_mismatch"):
            MODULE.validate_tool_stream(wrong_model, MARKER_PATH, expected_model=ARTIFACT)
        alias_model = tool_stream(model=MODEL)
        with self.assertRaisesRegex(MODULE.CheckError, "response_model_mismatch"):
            MODULE.validate_tool_stream(alias_model, MARKER_PATH, expected_model=ARTIFACT)
        with self.assertRaisesRegex(MODULE.CheckError, "response_model_mismatch"):
            MODULE.validate_tool_stream(tool_stream(), MARKER_PATH, expected_model=ARTIFACT)
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

    def test_stock_tool_inventory_is_allowed_but_read_is_required(self):
        stock_tools = [
            {"type": "function", "function": {"name": "read"}},
            {"type": "function", "function": {"name": "bash"}},
            {"type": "function", "function": {"name": "edit"}},
        ]
        metadata = MODULE.validate_client_request(
            request(tools=stock_tools), MODEL, MARKER
        )
        self.assertTrue(metadata["tool_choice_auto"])
        with self.assertRaisesRegex(MODULE.CheckError, "read_tool_missing"):
            MODULE.validate_client_request(request(tools=stock_tools[1:]), MODEL, MARKER)

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
                                      "--key-file", "/private/unread"] + BINDING_ARGS)
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
        self.assertIsNone(MODULE.validate_receipt(b"", 404, "req-1", ARTIFACT, **BINDING))
        self.assertIsNone(MODULE.validate_receipt(self.receipt(), 200, "req-1", ARTIFACT, **BINDING))
        pending = [{"attempt_n": 1, "closed": False, "receipt_result": "pending",
                    "settlement_outcome": "pending"}]
        self.assertIsNone(MODULE.validate_receipt(
            self.receipt(attempts=pending), 200, "req-1", ARTIFACT, **BINDING))

    def test_valid_terminal_receipt_is_minimized(self):
        attempt = verified_attempt(reason="not retained")
        self.assertEqual(MODULE.validate_receipt(
            self.receipt(attempts=[attempt]), 200, "req-1", ARTIFACT, **BINDING
        ),
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
                    MODULE.validate_receipt(body, 200, "req-1", ARTIFACT, **BINDING)
        wrong_model = [verified_attempt(model_id=MODEL)]
        with self.assertRaisesRegex(MODULE.CheckError, "receipt_model_mismatch"):
            MODULE.validate_receipt(
                self.receipt(attempts=wrong_model), 200, "req-1", ARTIFACT, **BINDING)

    def test_every_verified_attempt_requires_exact_identity_fields(self):
        for field, code in (("provider_receipt_key_fingerprint", "receipt_provider_mismatch"),
                            ("model_hash", "receipt_model_hash_mismatch"),
                            ("catalog_id", "receipt_catalog_mismatch")):
            for value in (None, "", "different", 1):
                for after_match in (False, True):
                    with self.subTest(field=field, value=value, after_match=after_match):
                        attempt = verified_attempt(**{field: value})
                        if value is None:
                            del attempt[field]
                        attempts = ([verified_attempt(attempt_n=1)] if after_match else []) + [attempt]
                        with self.assertRaisesRegex(MODULE.CheckError, code):
                            MODULE.validate_receipt(self.receipt(attempts=attempts), 200,
                                                    "req-1", ARTIFACT, **BINDING)

    def test_poll_rejects_identity_mismatch(self):
        body = self.receipt(attempts=[verified_attempt(catalog_id="other")])
        with mock.patch.object(MODULE, "_bounded_https_get", return_value=(200, body)):
            with self.assertRaisesRegex(MODULE.CheckError, "receipt_catalog_mismatch"):
                MODULE.poll_receipt("req-1", "key", MODEL, **BINDING)

    def test_failure_evidence_rejects_receipt_identity_mismatch(self):
        state = MODULE.RecorderState(MODEL, MARKER_PATH, MARKER, "key", "proxy-token")
        state.record_response("req-1", 200)
        body = self.receipt(attempts=[verified_attempt(model_hash="other")])
        with mock.patch.object(MODULE, "_bounded_https_get", return_value=(200, body)):
            evidence = MODULE._failure_evidence(state, "key", MODEL, **BINDING)
        self.assertEqual(evidence["receipt_validation"], {
            "status": "failed", "receipts": [{"request_id": "req-1", "status": "not_verified"}]})

    def test_poll_network_call_is_capped_by_remaining_deadline(self):
        get = mock.Mock(side_effect=MODULE.CheckError("upstream_transport"))
        with mock.patch.object(MODULE, "_bounded_https_get", get), \
                mock.patch.object(MODULE.time, "monotonic", side_effect=[10.0, 10.0, 12.0]):
            with self.assertRaisesRegex(MODULE.CheckError, "receipt_pending_timeout"):
                MODULE.poll_receipt("req-1", "key", MODEL, timeout_seconds=2.0, **BINDING)
        self.assertEqual(get.call_args.kwargs["timeout_seconds"], 2.0)
        self.assertEqual(get.call_args.kwargs["deadline"], 12.0)

    def test_slow_drip_cannot_extend_total_https_deadline(self):
        stopped = MODULE.threading.Event()

        class FakeSocket:
            def settimeout(self, _timeout):
                pass

            def shutdown(self, _how):
                stopped.set()

        class SlowResponse:
            status = 200

            @staticmethod
            def read1(_limit):
                if stopped.wait(0.02):
                    raise OSError("watchdog closed slow response")
                return b"x"

        class SlowConnection:
            def __init__(self, *_args, **_kwargs):
                self.sock = FakeSocket()

            def request(self, *_args, **_kwargs):
                pass

            def getresponse(self):
                return SlowResponse()

            def close(self):
                stopped.set()

        started = time.monotonic()
        with mock.patch.object(MODULE.http.client, "HTTPSConnection", SlowConnection):
            with self.assertRaisesRegex(MODULE.CheckError, "upstream_transport"):
                MODULE._bounded_https_get("/v1/receipts/req-1", "key", timeout_seconds=0.07)
        elapsed = time.monotonic() - started
        self.assertTrue(stopped.is_set())
        self.assertLess(elapsed, 0.3)

    def test_early_response_metadata_is_retained_for_failure_receipts(self):
        request_id = str(uuid.uuid4())
        state = MODULE.RecorderState(MODEL, MARKER_PATH, MARKER, "key", "proxy-token")
        record = state.record_response(request_id, 200)
        self.assertEqual(record, {"id": request_id, "status": 200})
        receipt = {"request_id": request_id, "attempt_n": 1, "status": "verified"}
        with mock.patch.object(MODULE, "poll_receipt", return_value=receipt) as poll:
            evidence = MODULE._failure_evidence(state, "key", MODEL, **BINDING)
        poll.assert_called_once_with(request_id, "key", MODEL, timeout_seconds=5.0, **BINDING)
        self.assertEqual(evidence["requests"], [{"id": request_id, "status": 200}])
        self.assertEqual(evidence["receipt_validation"],
                         {"status": "verified", "receipts": [receipt]})


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
        data = json.loads(MODULE._config(MODEL, 16384, "http://127.0.0.1:1/v1"))
        self.assertEqual(data["model"], "malibu/" + MODEL)
        self.assertEqual(data["small_model"], "malibu/" + MODEL)
        self.assertEqual(data["provider"]["malibu"]["options"]["apiKey"], "{env:MALIBU_PROXY_TOKEN}")
        self.assertNotIn("tools", data)
        self.assertNotIn("permission", data)

    def test_config_uses_exact_model_sampling_wire_fields_without_agent_override(self):
        for model in (*MODULE.MODEL_BINDINGS, *MODULE.MODEL_BINDINGS.values()):
            with self.subTest(model=model):
                data = json.loads(MODULE._config(model, 16384, "http://127.0.0.1:1/v1"))
                provider = data["provider"]["malibu"]
                self.assertEqual(set(provider["models"]), {model})
                self.assertEqual(provider["models"][model], {
                    "name": model, "temperature": True,
                    "options": {"temperature": 0.7, "top_p": 0.8},
                    "limit": {"context": 16384, "output": MODULE.MAX_OUTPUT_TOKENS},
                })
                self.assertEqual(provider["options"]["apiKey"], "{env:MALIBU_PROXY_TOKEN}")
                self.assertNotIn("temperature", provider["options"])
                self.assertNotIn("top_p", provider["options"])
                for key in ("agent", "tools", "permission", "tool_choice"):
                    self.assertNotIn(key, data)

    def test_config_does_not_apply_sampling_to_near_or_unrelated_model_names(self):
        for model in (
            "other/model", "qwen3-32b", "qwen/qwen3-30b-a3b-instruct-2507",
            "qwen3-coder-30b-a3b-instruct-extra", "QWEN3-CODER-30B-A3B-INSTRUCT",
            "qwen3-30b-a3b-instruct-2507-extra",
            "mlx-community/Qwen3-Coder-30B-A3B-Instruct-8bit",
            "mlx-community/Qwen3-30B-A3B-Instruct-2507-4bit-extra",
        ):
            with self.subTest(model=model):
                data = json.loads(MODULE._config(model, 16384, "http://127.0.0.1:1/v1"))
                self.assertEqual(data["provider"]["malibu"]["models"][model], {
                    "name": model, "limit": {"context": 16384, "output": MODULE.MAX_OUTPUT_TOKENS},
                })
                self.assertNotIn("agent", data)

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


class KeyInputTests(unittest.TestCase):
    def test_stdin_key_is_bounded_and_validated(self):
        class TrackingStream(io.BytesIO):
            calls = []

            def read(self, size=-1):
                self.calls.append(size)
                return super().read(size)

        stream = TrackingStream(b"synthetic-owner-key\n")
        self.assertEqual(MODULE._read_key_stdin(stream), "synthetic-owner-key")
        self.assertEqual(stream.calls, [8192, 1])
        for raw, code in ((b"x" * 8193, "key_file_too_large"),
                          (b"key with space", "key_file_value"),
                          (b"\xff", "key_file_encoding")):
            with self.subTest(code=code), self.assertRaisesRegex(MODULE.CheckError, code):
                MODULE._read_key_stdin(io.BytesIO(raw))

    def test_cli_requires_exactly_one_key_source(self):
        base = ["--opencode", "/bin/true", "--model", MODEL] + BINDING_ARGS
        with contextlib.redirect_stderr(io.StringIO()):
            with self.assertRaises(SystemExit):
                MODULE.build_parser().parse_args(base)
            with self.assertRaises(SystemExit):
                MODULE.build_parser().parse_args(base + ["--key-file", "/private/key", "--key-stdin"])
        args = MODULE.build_parser().parse_args(base + ["--key-stdin"])
        self.assertTrue(args.key_stdin)
        self.assertIsNone(args.key_file)

    def test_cli_requires_each_receipt_identity_binding(self):
        base = ["--opencode", "/bin/true", "--model", MODEL, "--key-stdin"]
        for index in range(0, len(BINDING_ARGS), 2):
            with self.subTest(missing=BINDING_ARGS[index]), \
                    contextlib.redirect_stderr(io.StringIO()), self.assertRaises(SystemExit):
                MODULE.build_parser().parse_args(base + BINDING_ARGS[:index] + BINDING_ARGS[index + 2:])


class ProcessTests(unittest.TestCase):
    def test_combined_client_output_cap_kills_process_group(self):
        with tempfile.TemporaryDirectory() as directory:
            command = [sys.executable, "-c", "import sys;sys.stdout.write('x'*1100000)"]
            with self.assertRaisesRegex(MODULE.CheckError, "client_output_too_large"):
                MODULE._bounded_client_process(command, pathlib.Path(directory), dict(os.environ))


class ProxyFailureEvidenceTests(unittest.TestCase):
    def test_request_id_is_retained_before_malformed_sse_rejection(self):
        state, status, request_id = self.proxy_response(b"data: not-json\n\ndata: [DONE]\n\n")
        self.assertEqual(status, 502)
        self.assertEqual(state.error_code, "invalid_json")
        self.assertEqual(state.requests, [{"id": request_id, "status": 200}])

    def test_credential_tool_ids_are_rejected_before_retention_and_failure_output(self):
        for credential in ("synthetic-buyer-key", "synthetic-proxy-token"):
            with self.subTest(credential=credential):
                body = tool_stream(model=ARTIFACT).replace(b"call-read", credential.encode())
                state, status, request_id = self.proxy_response(body)
                self.assertEqual(status, 502)
                self.assertEqual(state.error_code, "credential_echo")
                self.assertEqual(state.requests, [{"id": request_id, "status": 200}])
                with mock.patch.object(MODULE, "poll_receipt", return_value={
                    "request_id": request_id, "status": "verified", "attempt_n": 1,
                }):
                    evidence = MODULE._failure_evidence(state, state.key, MODEL, **BINDING)
                error = MODULE.CheckError(state.error_code)
                error.evidence = evidence
                output = io.StringIO()
                with mock.patch.object(MODULE, "_run", side_effect=error), \
                        contextlib.redirect_stdout(output):
                    status = MODULE.main(["--opencode", "/bin/true", "--model", MODEL,
                                          "--key-stdin"] + BINDING_ARGS)
                self.assertEqual(status, 1)
                self.assertNotIn(credential, output.getvalue())
                self.assertEqual(json.loads(output.getvalue())["error_code"], "credential_echo")

    def test_failure_output_guard_discards_preexisting_contaminated_metadata(self):
        for credential in ("synthetic-buyer-key", "synthetic-proxy-token"):
            with self.subTest(credential=credential):
                state = MODULE.RecorderState(MODEL, MARKER_PATH, MARKER,
                                             "synthetic-buyer-key", "synthetic-proxy-token")
                state.record_response(str(uuid.uuid4()), 502)["tool_calls"] = [{"call_id": credential}]
                evidence = MODULE._failure_evidence(state, state.key, MODEL, **BINDING)
                self.assertNotIn(credential, json.dumps(evidence))
                self.assertNotIn("requests", evidence)
                self.assertFalse(evidence["accepted"])

    def proxy_response(self, response_body):
        request_id = str(uuid.uuid4())

        class FakeResponse:
            status = 200

            @staticmethod
            def read(_limit):
                return response_body

            @staticmethod
            def getheaders():
                return [("Content-Type", "text/event-stream")]

            @staticmethod
            def getheader(name, default=None):
                return request_id if name.lower() == "x-request-id" else default

        class FakeHTTPSConnection:
            def __init__(self, *_args, **_kwargs):
                pass

            def request(self, *_args, **_kwargs):
                pass

            def getresponse(self):
                return FakeResponse()

            def close(self):
                pass

        state = MODULE.RecorderState(MODEL, MARKER_PATH, MARKER,
                                     "synthetic-buyer-key", "synthetic-proxy-token")
        proxy = MODULE.GatewayProxy(state)
        thread = MODULE.threading.Thread(target=proxy.serve_forever, daemon=True)
        thread.start()
        client = MODULE.http.client.HTTPConnection(*proxy.server_address, timeout=5)
        try:
            body = request()
            with mock.patch.object(MODULE.http.client, "HTTPSConnection", FakeHTTPSConnection):
                client.request("POST", "/v1/chat/completions", body=body, headers={
                    "Authorization": "Bearer " + state.proxy_token,
                    "Content-Type": "application/json",
                    "Content-Length": str(len(body)),
                })
                response = client.getresponse()
                response.read()
            return state, response.status, request_id
        finally:
            client.close()
            proxy.shutdown()
            proxy.server_close()
            thread.join(timeout=5)


@unittest.skipUnless(
    os.environ.get("MACPROVIDER_RUN_OPENCODE_LOCAL_FIXTURE") == "1",
    "set MACPROVIDER_RUN_OPENCODE_LOCAL_FIXTURE=1 for the real-client loopback fixture",
)
class RealOpenCodeLoopbackFixture(unittest.TestCase):
    """Exercise the real OpenCode protocol against an in-process fake upstream."""

    def test_run_completes_real_read_tool_round_trip(self):
        binary = shutil.which("opencode")
        if binary is None:
            self.skipTest("opencode is not installed")
        version = subprocess.run(
            [binary, "--version"], capture_output=True, text=True, timeout=10, check=False
        )
        if version.returncode != 0 or version.stdout.strip() != MODULE.CLIENT_VERSION:
            self.skipTest("installed opencode is not the pinned version")

        class FakeResponse:
            def __init__(self, body):
                self.status = 200
                self.body = body
                self.request_id = str(uuid.uuid4())

            def read(self, _limit):
                return self.body

            def getheaders(self):
                return [("Content-Type", "text/event-stream")]

            def getheader(self, name, default=None):
                return self.request_id if name.lower() == "x-request-id" else default

        class FakeHTTPSConnection:
            def __init__(self, host, port, timeout):
                self.response = None

            def request(self, method, path, body=None, headers=None):
                self.assert_request(method, path, headers)
                payload = json.loads(body)
                if payload.get("temperature") != 0.7 or payload.get("top_p") != 0.8:
                    raise AssertionError("OpenCode did not send the model-scoped sampling fields")
                tool_names = {
                    tool.get("function", {}).get("name") for tool in payload.get("tools", [])
                    if isinstance(tool, dict)
                }
                if not {"read", "bash"}.issubset(tool_names):
                    raise AssertionError("OpenCode stock tool inventory was not exposed")
                encoded = json.dumps(payload)
                paths = re.findall(r"/[^\"\\\\\s]*marker\.txt", encoded)
                markers = re.findall(r"malibu-[0-9a-f]{32}", encoded)
                if markers:
                    response_body = self.final_stream(markers[-1])
                else:
                    if not paths:
                        raise AssertionError("marker path absent from OpenCode request")
                    response_body = self.read_stream(paths[-1])
                self.response = FakeResponse(response_body)

            @staticmethod
            def assert_request(method, path, headers):
                if method != "POST" or path != "/v1/chat/completions":
                    raise AssertionError("unexpected fake-upstream request")
                if headers.get("Authorization") != "Bearer synthetic-owner-key":
                    raise AssertionError("owner key was not injected upstream")

            @staticmethod
            def read_stream(marker_path):
                chunks = [
                    {"id": "local-tool", "model": ARTIFACT, "choices": [{"index": 0, "delta": {
                        "role": "assistant", "tool_calls": [{"index": 0, "id": "call-local-read",
                        "type": "function", "function": {"name": "read", "arguments":
                        json.dumps({"filePath": marker_path})}}]}, "finish_reason": None}]},
                    {"id": "local-tool", "model": ARTIFACT, "choices": [{"index": 0, "delta": {},
                        "finish_reason": "tool_calls"}], "usage": {"prompt_tokens": 10,
                        "completion_tokens": 5, "total_tokens": 15}},
                ]
                return ("".join(frame(chunk) for chunk in chunks) + "data: [DONE]\n\n").encode()

            @staticmethod
            def final_stream(marker):
                chunks = [
                    {"id": "local-final", "model": ARTIFACT, "choices": [{"index": 0,
                        "delta": {"role": "assistant", "content": marker}, "finish_reason": None}]},
                    {"id": "local-final", "model": ARTIFACT, "choices": [{"index": 0, "delta": {},
                        "finish_reason": "stop"}], "usage": {"prompt_tokens": 20,
                        "completion_tokens": 10, "total_tokens": 30}},
                ]
                return ("".join(frame(chunk) for chunk in chunks) + "data: [DONE]\n\n").encode()

            def getresponse(self):
                if self.response is None:
                    raise AssertionError("request must precede response")
                return self.response

            def close(self):
                return None

        def fake_get(path, key, timeout_seconds=MODULE.HTTP_TIMEOUT_SECONDS, deadline=None):
            self.assertEqual(key, "synthetic-owner-key")
            self.assertGreater(timeout_seconds, 0)
            if deadline is not None:
                self.assertGreater(deadline, time.monotonic())
            if path == "/v1/models":
                return 200, json.dumps({"data": [{"id": MODEL,
                    "max_context_tokens": MODULE.MIN_CONTEXT_TOKENS}]}).encode()
            request_id = path.removeprefix("/v1/receipts/")
            return 200, json.dumps({
                "schema_version": "macprovider.buyer-receipt-view.v1",
                "request_id": request_id,
                "surface": "metadata",
                "pending_quarantined_visible": True,
                "attempts": [verified_attempt(attempt_n=1)],
            }).encode()

        run_client = MODULE._bounded_client_process

        def inspect_client_secret_boundary(command, cwd, env):
            self.assertNotIn("synthetic-owner-key", json.dumps(env, sort_keys=True))
            config = pathlib.Path(env["OPENCODE_CONFIG"]).read_text(encoding="utf-8")
            self.assertNotIn("synthetic-owner-key", config)
            return run_client(command, cwd, env)

        with tempfile.TemporaryDirectory() as directory:
            key_path = pathlib.Path(directory) / "buyer.key"
            key_path.write_text("synthetic-owner-key\n", encoding="utf-8")
            key_path.chmod(0o600)
            args = MODULE.build_parser().parse_args(
                ["--opencode", binary, "--model", MODEL, "--key-file", str(key_path)] + BINDING_ARGS
            )
            with mock.patch.object(MODULE, "_bounded_https_get", side_effect=fake_get), \
                    mock.patch.object(MODULE.http.client, "HTTPSConnection", FakeHTTPSConnection), \
                    mock.patch.object(MODULE, "_bounded_client_process",
                                      side_effect=inspect_client_secret_boundary):
                result = MODULE._run(args)

        self.assertTrue(result["accepted"])
        self.assertEqual(result["status"], "pass")
        self.assertGreaterEqual(len(result["requests"]), 2)
        self.assertTrue(result["opencode"]["final_marker_match"])
        self.assertEqual(result["receipt_validation"]["status"], "verified")
        self.assertNotIn("synthetic-owner-key", json.dumps(result, sort_keys=True))


if __name__ == "__main__":
    unittest.main()
