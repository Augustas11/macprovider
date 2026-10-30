import contextlib
import io
import json
import tempfile
import threading
import time
import unittest
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path

from scripts import agent_session_replay as replay


def _rec(kind, payload):
    return {"timestamp": "2026-01-01T00:00:00Z", "type": kind, "payload": payload}


def _item(payload):
    return _rec("response_item", dict(payload, internal_chat_message_metadata_passthrough={"turn_id": "t1"}))


def _usage(inp, cached, out=20):
    return _rec("token_usage_record", {"usage": {"input_tokens": inp, "cached_input_tokens": cached, "output_tokens": out}})


def synthetic_rollout(compaction=False, extra_tools=None):
    """A small, made-up Codex exec rollout: three tool-call turns and a final answer."""
    records = [
        _rec("session_meta", {"session_id": "sess-synthetic", "base_instructions": {"text": "You are a test coding agent."}}),
        _rec("turn_context", {"model": "test/model-a", "effort": "high"}),
    ]
    if extra_tools is not None:
        records.append(_rec("response_item", {"type": "additional_tools", "role": "developer", "tools": extra_tools}))
    records += [
        _item({"type": "message", "role": "developer", "content": [{"type": "input_text", "text": "sandbox: read-only"}]}),
        _item({"type": "message", "role": "user", "content": [{"type": "input_text", "text": "List the files and summarize."}]}),
    ]
    ctx = 2000
    for n in range(3):
        records += [
            _item({"type": "reasoning", "summary": [], "content": [{"type": "reasoning_text", "text": f"think {n}"}], "encrypted_content": None}),
            _item({"type": "function_call", "name": "exec_command", "arguments": json.dumps({"cmd": f"ls dir{n}"}), "call_id": f"call_{n}"}),
            _usage(ctx, 0 if n == 0 else ctx - 300),
            _item({"type": "function_call_output", "call_id": f"call_{n}", "output": "file.txt\n" * 20}),
        ]
        ctx += 1000
    if compaction:
        records.append(
            _rec(
                "compacted",
                {
                    "message": "summary",
                    "replacement_history": [
                        {"type": "message", "role": "user", "content": [{"type": "input_text", "text": "List the files and summarize."}]},
                        {"type": "message", "role": "user", "content": [{"type": "input_text", "text": "Summary so far: three dirs listed."}]},
                    ],
                },
            )
        )
    records += [
        _item({"type": "reasoning", "summary": [], "content": [{"type": "reasoning_text", "text": "done"}], "encrypted_content": None}),
        _item({"type": "message", "role": "assistant", "content": [{"type": "output_text", "text": "Three dirs, one file each."}]}),
        _usage(ctx, ctx - 200),
    ]
    return "\n".join(json.dumps(r) for r in records) + "\n"


class FakeGateway:
    """Streaming OpenAI-compatible server with injectable faults. Request
    numbers are 1-based in arrival order across all sessions."""

    def __init__(self):
        self.cache_ratio = 0.95
        self.gap = {}  # request_no -> seconds slept between two deltas
        self.status = {}  # request_no -> HTTP status returned instead of a stream
        self.cut = set()  # request_nos whose stream ends before completion
        self.first_token_delay = {}  # request_no -> seconds
        self.bodies = []
        self.headers = []
        self.lock = threading.Lock()
        self.seen_keys = set()
        gateway = self

        class Handler(BaseHTTPRequestHandler):
            protocol_version = "HTTP/1.1"

            def log_message(self, *args):
                pass

            def do_POST(self):
                body = json.loads(self.rfile.read(int(self.headers["Content-Length"])))
                with gateway.lock:
                    gateway.bodies.append(body)
                    gateway.headers.append(dict(self.headers))
                    no = len(gateway.bodies)
                    key = body.get("prompt_cache_key")
                    first_for_key = key not in gateway.seen_keys
                    gateway.seen_keys.add(key)
                chat = self.path.endswith("/chat/completions")
                if no in gateway.status:
                    payload = json.dumps({"error": {"code": "no_provider_available", "message": "busy"}}).encode()
                    self.send_response(gateway.status[no])
                    self.send_header("Content-Type", "application/json")
                    self.send_header("Content-Length", str(len(payload)))
                    self.end_headers()
                    self.wfile.write(payload)
                    return
                prompt = len(json.dumps(body.get("messages") or body.get("input"))) // 4 + len(body.get("instructions", "")) // 4
                cached = 0 if first_for_key else int(prompt * gateway.cache_ratio)
                self.send_response(200)
                self.send_header("Content-Type", "text/event-stream")
                self.send_header("Connection", "close")
                self.end_headers()

                def send(obj):
                    self.wfile.write(b"data: " + (obj if isinstance(obj, bytes) else json.dumps(obj).encode()) + b"\n\n")
                    self.wfile.flush()

                def delta(text):
                    if chat:
                        send({"choices": [{"index": 0, "delta": {"content": text}}]})
                    else:
                        send({"type": "response.output_text.delta", "delta": text})

                time.sleep(gateway.first_token_delay.get(no, 0))
                delta("hel")
                if no in gateway.cut:
                    self.close_connection = True
                    return
                time.sleep(gateway.gap.get(no, 0.01))
                delta("lo")
                delta("!")
                if chat:
                    send({"choices": [], "usage": {"prompt_tokens": prompt, "completion_tokens": 3, "prompt_tokens_details": {"cached_tokens": cached}}})
                    send(b"[DONE]")
                else:
                    send(
                        {
                            "type": "response.completed",
                            "response": {"usage": {"input_tokens": prompt, "output_tokens": 3, "input_tokens_details": {"cached_tokens": cached}}},
                        }
                    )
                self.close_connection = True

        self.server = ThreadingHTTPServer(("127.0.0.1", 0), Handler)
        self.server.daemon_threads = True
        self.thread = threading.Thread(target=self.server.serve_forever, daemon=True)
        self.thread.start()
        self.base_url = f"http://127.0.0.1:{self.server.server_address[1]}/v1"

    def close(self):
        self.server.shutdown()
        self.server.server_close()


class ReplayTestCase(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.dir = Path(self.tmp.name)
        self.rollout = self.dir / "rollout-synthetic.jsonl"
        self.rollout.write_text(synthetic_rollout(), encoding="utf-8")
        self.gw = FakeGateway()

    def tearDown(self):
        self.gw.close()
        self.tmp.cleanup()

    def run_replay(self, *extra):
        out = self.dir / "out"
        argv = [
            str(self.rollout),
            "--base-url", self.gw.base_url,
            "--out-dir", str(out),
            "--stagger-seconds", "0",
            "--retry-backoff-seconds", "0",
            "--max-retries", "0",
            "--idle-limit-seconds", "0.25",
            "--ttft-base-seconds", "0.5",
            "--prefill-tokens-per-second", "1000000",
            "--request-timeout", "10",
            *extra,
        ]
        buf = io.StringIO()
        with contextlib.redirect_stdout(buf):
            code = replay.main(argv)
        summary = json.loads((out / "summary.json").read_text())
        turns = [json.loads(line) for line in (out / "turns.jsonl").read_text().splitlines()]
        return code, summary, turns, buf.getvalue()


class ParseRolloutTest(unittest.TestCase):
    def write(self, text):
        tmp = tempfile.NamedTemporaryFile("w", suffix=".jsonl", delete=False)
        tmp.write(text)
        tmp.close()
        self.addCleanup(Path(tmp.name).unlink)
        return tmp.name

    def test_rebuilds_growing_request_sequence(self):
        meta = replay.parse_rollout(self.write(synthetic_rollout()))
        self.assertEqual(meta["model"], "test/model-a")
        self.assertEqual(meta["effort"], "high")
        self.assertEqual(meta["instructions"], "You are a test coding agent.")
        self.assertEqual(meta["tools_source"], "synthesized")
        self.assertEqual([t["name"] for t in meta["tools"]], ["exec_command"])
        reqs = meta["requests"]
        self.assertEqual(len(reqs), 4)
        self.assertEqual([len(r["input"]) for r in reqs], [2, 5, 8, 11])
        # each request's input is a strict prefix-extension of the previous one
        for prev, cur in zip(reqs, reqs[1:]):
            self.assertEqual(cur["input"][: len(prev["input"])], prev["input"])
        second = reqs[1]["input"]
        self.assertEqual([i["type"] for i in second[2:]], ["reasoning", "function_call", "function_call_output"])
        self.assertNotIn("internal_chat_message_metadata_passthrough", second[2])
        self.assertNotIn("encrypted_content", second[2])
        self.assertEqual(reqs[0]["source_usage"]["input_tokens"], 2000)
        self.assertEqual(reqs[3]["source_usage"]["cached_input_tokens"], 4800)

    def test_compaction_replaces_history(self):
        meta = replay.parse_rollout(self.write(synthetic_rollout(compaction=True)))
        last = meta["requests"][-1]
        self.assertTrue(last["post_compaction"])
        self.assertEqual(len(last["input"]), 2)
        self.assertEqual(meta["compactions"], 1)

    def test_additional_tools_used_verbatim(self):
        tools = [{"type": "namespace", "name": "functions", "tools": [{"type": "function", "name": "exec_command", "parameters": {"type": "object"}}]}]
        meta = replay.parse_rollout(self.write(synthetic_rollout(extra_tools=tools)))
        self.assertEqual(meta["tools_source"], "rollout")
        self.assertEqual(meta["tools"], tools)
        self.assertTrue(all(i.get("type") != "additional_tools" for r in meta["requests"] for i in r["input"]))

    def test_empty_rollout_is_an_input_error(self):
        path = self.write(json.dumps(_rec("session_meta", {"session_id": "x"})) + "\n")
        with contextlib.redirect_stderr(io.StringIO()) as err:
            self.assertEqual(replay.main([path, "--plan"]), 2)
        self.assertIn("no model requests", err.getvalue())

    def test_max_context_cuts_replay(self):
        meta = replay.parse_rollout(self.write(synthetic_rollout()))
        self.assertEqual(len(replay.select_requests(meta, 3500)), 2)
        self.assertEqual(replay.parse_token_count("32k"), 32768)

    def test_chat_conversion_keeps_tool_pairs_and_reasoning(self):
        meta = replay.parse_rollout(self.write(synthetic_rollout()))
        msgs = replay.items_to_chat_messages(meta["instructions"], meta["requests"][1]["input"])
        self.assertEqual([m["role"] for m in msgs], ["system", "system", "user", "assistant", "tool"])
        self.assertEqual(msgs[3]["reasoning_content"], "think 0")
        self.assertEqual(msgs[3]["tool_calls"][0]["id"], msgs[4]["tool_call_id"])


class ReplaySLOTest(ReplayTestCase):
    def test_clean_run_passes(self):
        code, summary, turns, _ = self.run_replay()
        self.assertEqual(code, 0, summary["breaches"])
        self.assertTrue(summary["pass"])
        self.assertEqual(summary["requests_replayed"], 4)
        self.assertEqual(len(turns), 4)
        for t in turns[1:]:
            self.assertGreaterEqual(t["cache_ratio"], 0.9)
            self.assertIsNotNone(t["attempts"][0]["ttft_s"])
            self.assertIsNotNone(t["attempts"][0]["decode_tps"])
        body = self.gw.bodies[1]
        self.assertTrue(body["stream"])
        self.assertEqual(body["reasoning"], {"effort": "high"})
        self.assertEqual(body["tools"][0]["name"], "exec_command")
        self.assertEqual(body["instructions"], "You are a test coding agent.")
        self.assertIn("replay_session nonce=", json.dumps(body["input"]))
        self.assertEqual(len({b["prompt_cache_key"] for b in self.gw.bodies}), 1)

    def test_long_token_gap_breaches(self):
        self.gw.gap[3] = 0.5
        code, summary, turns, _ = self.run_replay()
        self.assertEqual(code, 1)
        self.assertEqual(summary["breach_counts"], {"token_gap": 1})
        self.assertGreaterEqual(turns[2]["attempts"][0]["max_gap_s"], 0.5)

    def test_429_breaches_even_when_retry_succeeds(self):
        self.gw.status[2] = 429
        code, summary, turns, _ = self.run_replay("--max-retries", "1")
        self.assertEqual(code, 1)
        self.assertEqual(summary["counts"]["http_429"], 1)
        self.assertEqual(summary["counts"]["retries"], 1)
        self.assertEqual(summary["breach_counts"], {"http_429": 1})
        self.assertEqual([a["http_status"] for a in turns[1]["attempts"]], [429, 200])

    def test_5xx_breaches(self):
        self.gw.status[4] = 503
        code, summary, _, _ = self.run_replay()
        self.assertEqual(code, 1)
        self.assertEqual(summary["counts"]["http_5xx"], 1)

    def test_low_cached_tokens_breach(self):
        self.gw.cache_ratio = 0.3
        code, summary, turns, _ = self.run_replay()
        self.assertEqual(code, 1)
        # turn 1 is exempt; the three later turns breach
        self.assertEqual(summary["breach_counts"], {"cache_ratio": 3})
        self.assertNotIn("cache_ratio", turns[0]["breaches"])

    def test_cut_stream_breaches(self):
        self.gw.cut.add(2)
        code, summary, turns, _ = self.run_replay()
        self.assertEqual(code, 1)
        self.assertEqual(summary["counts"]["stream_cut"], 1)
        self.assertIn("stream_cut", turns[1]["breaches"])

    def test_slow_ttft_breaches(self):
        self.gw.first_token_delay[2] = 0.8
        code, summary, _, _ = self.run_replay()
        self.assertEqual(code, 1)
        self.assertEqual(summary["breach_counts"], {"ttft": 1})

    def test_concurrent_sessions_with_aggressor(self):
        code, summary, turns, _ = self.run_replay("--sessions", "2", "--aggressor-prefill-tokens", "500")
        self.assertEqual(code, 0, summary["breaches"])
        self.assertEqual(summary["requests_replayed"], 8)
        self.assertEqual(summary["aggressor_requests"], 4)
        session_keys = {b["prompt_cache_key"] for b in self.gw.bodies if not b["prompt_cache_key"].startswith("replay-aggr-")}
        self.assertEqual(len(session_keys), 2)
        aggr = [b for b in self.gw.bodies if b["prompt_cache_key"].startswith("replay-aggr-")]
        self.assertTrue(all("tools" not in b and b["max_output_tokens"] == 16 for b in aggr))
        self.assertEqual({t["role"] for t in turns}, {"session", "aggressor"})

    def test_chat_api_clean_run_passes(self):
        code, summary, _, _ = self.run_replay("--api", "chat")
        self.assertEqual(code, 0, summary["breaches"])
        body = self.gw.bodies[0]
        self.assertEqual(body["stream_options"], {"include_usage": True})
        self.assertEqual(body["reasoning_effort"], "high")
        self.assertEqual(body["tools"][0]["function"]["name"], "exec_command")

    def test_api_key_is_sent_but_never_printed(self):
        key_file = self.dir / "key"
        key_file.write_text("sk-test-not-real-123\n")
        code, summary, _, stdout = self.run_replay("--api-key-file", str(key_file))
        self.assertEqual(code, 0)
        self.assertEqual(self.gw.headers[0]["Authorization"], "Bearer sk-test-not-real-123")
        self.assertNotIn("sk-test-not-real-123", stdout)
        out = self.dir / "out"
        self.assertNotIn("sk-test-not-real-123", (out / "turns.jsonl").read_text() + (out / "summary.json").read_text())


if __name__ == "__main__":
    unittest.main()
