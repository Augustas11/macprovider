"""openai==2.44.0 client-oracle harness for Malibu coding-agent wire shape.

Exit criteria 1–3 (CI, stubbed):
  1. echo hello via bash reconstructs to one JSON object containing echo hello, never {}.
  2. After a tool result, next turn is tool_calls or streamed text — never printed <tool_call>.
  3. Terminal errors keep coordinator code (malformed_tool_call), not stream_malformed.

OpenRouter differential (4) is the same reconstruction; prefix counts may differ.
Live Pearl/OpenRouter runs only when MALIBU_API_KEY / OPENROUTER_API_KEY are set.
"""

from __future__ import annotations

import json
import os
import threading
import unittest
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from typing import Any

from openai import OpenAI
from openai import APIError

BASH_TOOL = {
    "type": "function",
    "function": {
        "name": "bash",
        "description": "Run a bash command",
        "parameters": {
            "type": "object",
            "properties": {"command": {"type": "string"}},
            "required": ["command"],
        },
    },
}

ECHO_HELLO_OBJECT = {"command": "echo hello"}


def _sse(payload: str) -> str:
    return f"data: {payload}\n\n"


def malibu_echo_hello_sse() -> str:
    """Slice-3 Malibu shape: name-open, then one complete non-empty object."""
    return "".join(
        [
            _sse(
                '{"id":"chatcmpl-malibu","object":"chat.completion.chunk","created":1,"model":"qwen","choices":[{"index":0,"delta":{"role":"assistant","content":""},"finish_reason":null}]}'
            ),
            _sse(
                '{"id":"chatcmpl-malibu","choices":[{"index":0,"delta":{"tool_calls":[{"index":0,"id":"call_0123456789abcdef","type":"function","function":{"name":"bash","arguments":""}}]},"finish_reason":null}]}'
            ),
            _sse(
                '{"id":"chatcmpl-malibu","choices":[{"index":0,"delta":{"tool_calls":[{"index":0,"function":{"arguments":"{\\"command\\":\\"echo hello\\"}"}}]},"finish_reason":null}]}'
            ),
            _sse(
                '{"id":"chatcmpl-malibu","choices":[{"index":0,"delta":{},"finish_reason":"tool_calls"}]}'
            ),
            "data: [DONE]\n\n",
        ]
    )


def openrouter_echo_hello_sse() -> str:
    """OpenRouter-like concat-safe prefixes of the same object."""
    prefixes = ["{", '"command":"', 'echo hello"}']
    frames = [
        _sse(
            '{"id":"chatcmpl-or","object":"chat.completion.chunk","created":1,"model":"qwen","choices":[{"index":0,"delta":{"role":"assistant","content":""},"finish_reason":null}]}'
        ),
        _sse(
            '{"id":"chatcmpl-or","choices":[{"index":0,"delta":{"tool_calls":[{"index":0,"id":"call_0123456789abcdef","type":"function","function":{"name":"bash","arguments":""}}]},"finish_reason":null}]}'
        ),
    ]
    for prefix in prefixes:
        frames.append(
            _sse(
                json.dumps(
                    {
                        "id": "chatcmpl-or",
                        "choices": [
                            {
                                "index": 0,
                                "delta": {
                                    "tool_calls": [
                                        {
                                            "index": 0,
                                            "function": {"arguments": prefix},
                                        }
                                    ]
                                },
                                "finish_reason": None,
                            }
                        ],
                    }
                )
            )
        )
    frames.append(
        _sse(
            '{"id":"chatcmpl-or","choices":[{"index":0,"delta":{},"finish_reason":"tool_calls"}]}'
        )
    )
    frames.append("data: [DONE]\n\n")
    return "".join(frames)


def followup_text_sse() -> str:
    return "".join(
        [
            _sse(
                '{"id":"chatcmpl-follow","object":"chat.completion.chunk","created":1,"model":"qwen","choices":[{"index":0,"delta":{"role":"assistant","content":""},"finish_reason":null}]}'
            ),
            _sse(
                '{"id":"chatcmpl-follow","choices":[{"index":0,"delta":{"content":"The "},"finish_reason":null}]}'
            ),
            _sse(
                '{"id":"chatcmpl-follow","choices":[{"index":0,"delta":{"content":"command printed hello."},"finish_reason":null}]}'
            ),
            _sse(
                '{"id":"chatcmpl-follow","choices":[{"index":0,"delta":{},"finish_reason":"stop"}]}'
            ),
            "data: [DONE]\n\n",
        ]
    )


def malformed_tool_call_sse() -> str:
    return (
        _sse(
            '{"error":{"message":"tool call failed final-close","type":"upstream_provider_error","param":null,"code":"malformed_tool_call","retryable":false,"request_id":"req-downstream","inference_ran":true,"settlement_ran":true}}'
        )
        + "data: [DONE]\n\n"
    )


def pi_first_complete_json(fragments: list[str]) -> Any:
    buf = ""
    decoder = json.JSONDecoder()
    for fragment in fragments:
        buf += fragment
        try:
            value, _end = decoder.raw_decode(buf)
        except json.JSONDecodeError:
            continue
        return value
    return None


class _StubHandler(BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"

    def log_message(self, fmt: str, *args: Any) -> None:
        return

    def do_POST(self) -> None:
        length = int(self.headers.get("Content-Length") or "0")
        raw = self.rfile.read(length)
        try:
            body = json.loads(raw.decode("utf-8"))
        except json.JSONDecodeError:
            self.send_error(400, "invalid json")
            return
        messages = body.get("messages") or []
        last = messages[-1] if messages else {}
        content = last.get("content") or ""
        if last.get("role") == "tool" or last.get("role") == "user" and "tool result" in str(content).lower():
            payload = followup_text_sse()
        elif "force_malformed_tool_call" in str(content):
            payload = malformed_tool_call_sse()
        elif body.get("vendor") == "openrouter" or "openrouter" in str(body.get("model") or "").lower():
            payload = openrouter_echo_hello_sse()
        else:
            payload = malibu_echo_hello_sse()
        data = payload.encode("utf-8")
        self.send_response(200)
        self.send_header("Content-Type", "text/event-stream; charset=utf-8")
        self.send_header("Cache-Control", "no-cache")
        self.send_header("Content-Length", str(len(data)))
        self.end_headers()
        self.wfile.write(data)


class _StubServer:
    def __init__(self) -> None:
        self._httpd = ThreadingHTTPServer(("127.0.0.1", 0), _StubHandler)
        self.port = self._httpd.server_address[1]
        self._thread = threading.Thread(target=self._httpd.serve_forever, daemon=True)

    def start(self) -> None:
        self._thread.start()

    def stop(self) -> None:
        self._httpd.shutdown()
        self._httpd.server_close()
        self._thread.join(timeout=2)


def _client(port: int) -> OpenAI:
    return OpenAI(
        base_url=f"http://127.0.0.1:{port}/v1",
        api_key="sk-test",
        max_retries=0,
    )


def _reconstruct(client: OpenAI, *, model: str, messages: list[dict[str, Any]]) -> dict[str, Any]:
    kwargs: dict[str, Any] = {}
    if "openrouter" in model:
        kwargs["extra_body"] = {"vendor": "openrouter"}
    stream = client.chat.completions.create(
        model=model,
        messages=messages,
        tools=[BASH_TOOL],
        stream=True,
        **kwargs,
    )
    args_fragments: list[str] = []
    content_parts: list[str] = []
    tool_name = None
    finish = None
    for chunk in stream:
        if not chunk.choices:
            continue
        choice = chunk.choices[0]
        finish = choice.finish_reason or finish
        delta = choice.delta
        if delta.content:
            content_parts.append(delta.content)
        for call in delta.tool_calls or []:
            if call.function and call.function.name:
                tool_name = call.function.name
            if call.function and call.function.arguments:
                args_fragments.append(call.function.arguments)
    return {
        "name": tool_name,
        "arguments_concat": "".join(args_fragments),
        "arguments_fragments": args_fragments,
        "content": "".join(content_parts),
        "finish_reason": finish,
    }


class OpenAIWireHarnessTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls) -> None:
        cls.server = _StubServer()
        cls.server.start()
        cls.client = _client(cls.server.port)

    @classmethod
    def tearDownClass(cls) -> None:
        cls.server.stop()

    def test_echo_hello_one_object_never_empty(self) -> None:
        got = _reconstruct(
            self.client,
            model="qwen3-coder-30b-a3b-instruct",
            messages=[{"role": "user", "content": "run echo hello via bash"}],
        )
        self.assertEqual(got["name"], "bash")
        parsed = json.loads(got["arguments_concat"])
        self.assertEqual(parsed, ECHO_HELLO_OBJECT)
        self.assertIn("echo hello", parsed["command"])
        self.assertNotEqual(parsed, {})
        pi = pi_first_complete_json(got["arguments_fragments"])
        self.assertEqual(pi, ECHO_HELLO_OBJECT)
        self.assertNotEqual(pi, {})

    def test_followup_after_tool_result_never_prints_tool_call_markup(self) -> None:
        got = _reconstruct(
            self.client,
            model="qwen3-coder-30b-a3b-instruct",
            messages=[
                {"role": "user", "content": "run echo hello via bash"},
                {
                    "role": "assistant",
                    "content": None,
                    "tool_calls": [
                        {
                            "id": "call_0123456789abcdef",
                            "type": "function",
                            "function": {
                                "name": "bash",
                                "arguments": '{"command":"echo hello"}',
                            },
                        }
                    ],
                },
                {
                    "role": "tool",
                    "tool_call_id": "call_0123456789abcdef",
                    "content": "hello\n",
                },
            ],
        )
        self.assertNotIn("<tool_call>", got["content"])
        self.assertTrue(got["content"] or got["name"])
        if got["name"]:
            self.assertNotEqual(json.loads(got["arguments_concat"] or "{}"), {})
        else:
            self.assertIn("hello", got["content"].lower())
            self.assertGreaterEqual(len([p for p in [got["content"]] if p]), 1)

    def test_terminal_error_keeps_malformed_tool_call(self) -> None:
        try:
            stream = self.client.chat.completions.create(
                model="qwen3-coder-30b-a3b-instruct",
                messages=[{"role": "user", "content": "force_malformed_tool_call"}],
                tools=[BASH_TOOL],
                stream=True,
            )
            for _chunk in stream:
                pass
            self.fail("expected APIError for malformed_tool_call")
        except APIError as exc:
            blob = " ".join(
                str(part)
                for part in (exc.code, getattr(exc, "body", None), str(exc))
                if part is not None
            )
            self.assertIn("malformed_tool_call", blob)
            self.assertNotIn("stream_malformed", blob)

    def test_openrouter_differential_same_reconstruction(self) -> None:
        malibu = _reconstruct(
            self.client,
            model="qwen3-coder-30b-a3b-instruct",
            messages=[{"role": "user", "content": "run echo hello via bash"}],
        )
        openrouter = _reconstruct(
            self.client,
            model="openrouter/qwen3-coder",
            messages=[{"role": "user", "content": "run echo hello via bash"}],
        )
        self.assertEqual(json.loads(malibu["arguments_concat"]), ECHO_HELLO_OBJECT)
        self.assertEqual(json.loads(openrouter["arguments_concat"]), ECHO_HELLO_OBJECT)
        self.assertEqual(
            pi_first_complete_json(malibu["arguments_fragments"]),
            pi_first_complete_json(openrouter["arguments_fragments"]),
        )
        # Prefix counts may lag on Malibu; reconstruction must still match.
        self.assertGreaterEqual(len(openrouter["arguments_fragments"]), 1)


@unittest.skipUnless(os.environ.get("MALIBU_API_KEY"), "MALIBU_API_KEY not set")
class LivePearlHarnessTests(unittest.TestCase):
    def test_live_malibu_echo_hello_or_skip_capacity(self) -> None:
        client = OpenAI(
            base_url=os.environ.get("MALIBU_BASE_URL", "https://api.malibu.tech/v1"),
            api_key=os.environ["MALIBU_API_KEY"],
            max_retries=0,
        )
        model = os.environ.get(
            "MALIBU_MODEL",
            "mlx-community/Qwen3-Coder-30B-A3B-Instruct-4bit",
        )
        try:
            got = _reconstruct(
                client,
                model=model,
                messages=[{"role": "user", "content": "Use bash to run exactly: echo hello"}],
            )
        except APIError as exc:
            blob = str(exc)
            if "no_provider_available" in blob or "503" in blob:
                self.skipTest(f"live capacity: {blob[:200]}")
            raise
        if got["name"] != "bash":
            self.fail(f"live Malibu did not emit bash tool_calls: {got}")
        parsed = json.loads(got["arguments_concat"] or "{}")
        self.assertIn("echo hello", parsed.get("command", ""))
        self.assertNotEqual(parsed, {})
        pi = pi_first_complete_json(got["arguments_fragments"] or [got["arguments_concat"]])
        self.assertNotEqual(pi, {})
        self.assertNotIn("<tool_call>", got["content"])


@unittest.skipUnless(os.environ.get("OPENROUTER_API_KEY"), "OPENROUTER_API_KEY not set")
class LiveOpenRouterHarnessTests(unittest.TestCase):
    def test_live_openrouter_echo_hello_reconstructs(self) -> None:
        client = OpenAI(
            base_url=os.environ.get("OPENROUTER_BASE_URL", "https://openrouter.ai/api/v1"),
            api_key=os.environ["OPENROUTER_API_KEY"],
            max_retries=0,
        )
        model = os.environ.get("OPENROUTER_MODEL", "qwen/qwen3-coder")
        got = _reconstruct(
            client,
            model=model,
            messages=[{"role": "user", "content": "Use bash to run exactly: echo hello"}],
        )
        self.assertEqual(got["name"], "bash")
        parsed = json.loads(got["arguments_concat"])
        self.assertIn("echo hello", parsed.get("command", ""))
        self.assertNotEqual(parsed, {})


if __name__ == "__main__":
    unittest.main()
