#!/usr/bin/env python3
import json
import threading
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

from openai import APIError, OpenAI


SSE_EVENTS = [
    {
        "id": "chatcmpl-ac48a",
        "object": "chat.completion.chunk",
        "choices": [
            {
                "index": 0,
                "delta": {
                    "tool_calls": [
                        {
                            "index": 0,
                            "id": "call_0123456789abcdef",
                            "type": "function",
                            "function": {"name": "write_file", "arguments": "{\"path\":\"README.md\","},
                        }
                    ]
                },
            }
        ],
    },
    {
        "id": "chatcmpl-ac48a",
        "object": "chat.completion.chunk",
        "choices": [
            {
                "index": 0,
                "delta": {
                    "tool_calls": [
                        {
                            "index": 0,
                            "function": {"arguments": "\"content\":\"partial"},
                        }
                    ]
                },
            }
        ],
    },
    {
        "error": {
            "message": "Provider closed before tool-call stream completed",
            "type": "server_error",
            "code": "tool_call_final_close_failed",
            "param": None,
        }
    },
]


class Handler(BaseHTTPRequestHandler):
    def log_message(self, *_args):
        return

    def do_POST(self):
        if self.path != "/v1/chat/completions":
            self.send_error(404)
            return
        _ = self.rfile.read(int(self.headers.get("content-length", "0")))
        self.send_response(200)
        self.send_header("Content-Type", "text/event-stream; charset=utf-8")
        self.send_header("Cache-Control", "no-cache")
        self.end_headers()
        for event in SSE_EVENTS:
            self.wfile.write(b"data: ")
            self.wfile.write(json.dumps(event, separators=(",", ":")).encode("utf-8"))
            self.wfile.write(b"\n\n")
            self.wfile.flush()
        self.wfile.write(b"data: [DONE]\n\n")
        self.wfile.flush()


def main() -> int:
    server = ThreadingHTTPServer(("127.0.0.1", 0), Handler)
    thread = threading.Thread(target=server.serve_forever, daemon=True)
    thread.start()
    client = OpenAI(api_key="test", base_url=f"http://127.0.0.1:{server.server_port}/v1")
    saw_exception = False
    saw_successful_tool_finish = False
    accumulated = ""
    try:
        stream = client.chat.completions.create(
            model="fixture-model",
            messages=[{"role": "user", "content": "write a file"}],
            stream=True,
        )
        for chunk in stream:
            for choice in chunk.choices:
                if choice.finish_reason == "tool_calls":
                    saw_successful_tool_finish = True
                for call in choice.delta.tool_calls or []:
                    if call.function and call.function.arguments:
                        accumulated += call.function.arguments
    except APIError:
        saw_exception = True
    finally:
        server.shutdown()

    if saw_successful_tool_finish:
        raise AssertionError("openai-python yielded finish_reason=tool_calls after terminal error")
    if not saw_exception and accumulated.endswith("}"):
        raise AssertionError("openai-python accumulated a complete dispatchable tool call without raising")
    print(json.dumps({"ac": "AC-48a", "passed": True, "sdk_exception": saw_exception, "accumulated_bytes": len(accumulated)}))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
