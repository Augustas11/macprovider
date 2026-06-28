#!/usr/bin/env python3
import hashlib
import json
import multiprocessing
import shutil
import sys
import time
import urllib.request
from datetime import datetime, timezone
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path


ROOT = Path(__file__).resolve().parents[3]
HERE = Path(__file__).resolve().parent
OUT = HERE / "output"
WORKSPACE = OUT / "workspace"
KNOWN_HASH = "0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef"


def sha256_text(value: str) -> str:
    return hashlib.sha256(value.encode("utf-8")).hexdigest()


def write_workspace() -> None:
    WORKSPACE.mkdir(parents=True, exist_ok=True)
    (WORKSPACE / "docs").mkdir(exist_ok=True)
    (WORKSPACE / "README.md").write_text("# SPEC-018 Fixture\n\nSmall deterministic repo.\n", encoding="utf-8")
    (WORKSPACE / "docs" / "CHANGELOG.md").write_text("# Changelog\n\n", encoding="utf-8")
    shutil.copyfile(ROOT / "specs" / "SPEC-018-agentic-tool-calling.md", WORKSPACE / "SPEC-018-agentic-tool-calling.md")


def mock_stack(port_queue: multiprocessing.Queue) -> None:
    class Handler(BaseHTTPRequestHandler):
        def log_message(self, *_args):
            return

        def do_POST(self):
            if self.path != "/v1/chat/completions":
                self.send_error(404)
                return
            raw = self.rfile.read(int(self.headers.get("content-length", "0")))
            request = json.loads(raw)
            turn = int(request.get("metadata", {}).get("turn", 0))
            request_id = self.headers.get("X-Request-ID", f"req-cline-{turn:03d}")
            tool_name = request.get("metadata", {}).get("tool_name", "read_file")
            tool_args = request.get("metadata", {}).get("tool_arguments", {"turn": turn})
            model_hash = KNOWN_HASH if turn % 2 == 0 else None
            call_id = f"call_{turn:032x}"
            body = {
                "id": f"chatcmpl-{request_id}",
                "object": "chat.completion",
                "created": int(time.time()),
                "model": request.get("model", "mock-qwen3-32b"),
                "choices": [{
                    "index": 0,
                    "message": {
                        "role": "assistant",
                        "content": None,
                        "tool_calls": [{
                            "id": call_id,
                            "type": "function",
                            "function": {
                                "name": tool_name,
                                "arguments": json.dumps(tool_args, separators=(",", ":"), sort_keys=True),
                            },
                        }],
                    },
                    "finish_reason": "tool_calls",
                }],
                "usage": {
                    "prompt_tokens": 10 + turn,
                    "completion_tokens": 4,
                    "total_tokens": 14 + turn,
                    "macprovider_model_hash_observed": model_hash,
                },
                "macprovider": {
                    "provider_pid": multiprocessing.current_process().pid,
                    "request_id": request_id,
                    "streaming_mode": "incremental",
                    "headers": {
                        "X-MacProvider-Streaming-Mode": "incremental",
                        "X-Request-ID": request_id,
                    },
                },
            }
            data = json.dumps(body, separators=(",", ":")).encode("utf-8")
            self.send_response(200)
            self.send_header("Content-Type", "application/json")
            self.send_header("Content-Length", str(len(data)))
            self.send_header("X-Request-ID", request_id)
            self.send_header("X-MacProvider-Streaming-Mode", "incremental")
            self.end_headers()
            self.wfile.write(data)

    server = ThreadingHTTPServer(("127.0.0.1", 0), Handler)
    port_queue.put(server.server_port)
    server.serve_forever()


def post_json(base_url: str, turn: int, tool_name: str, tool_arguments: dict) -> tuple[dict, dict]:
    request_id = f"req-cline-{turn:03d}"
    payload = {
        "model": "mock-qwen3-32b",
        "messages": [{"role": "user", "content": f"turn {turn}"}],
        "tools": [{"type": "function", "function": {"name": tool_name, "parameters": {"type": "object"}}}],
        "metadata": {"turn": turn, "tool_name": tool_name, "tool_arguments": tool_arguments},
    }
    req = urllib.request.Request(
        f"{base_url}/v1/chat/completions",
        data=json.dumps(payload).encode("utf-8"),
        headers={"Content-Type": "application/json", "X-Request-ID": request_id},
        method="POST",
    )
    with urllib.request.urlopen(req, timeout=10) as resp:
        headers = dict(resp.headers.items())
        body = json.loads(resp.read().decode("utf-8"))
    return body, headers


def drive_mock_stack(config: dict, base_url: str, provider_pid: int) -> dict:
    tools = [
        ("list_files", {"path": "."}),
        ("search_files", {"query": "SPEC-018"}),
        ("read_file", {"path": "SPEC-018-agentic-tool-calling.md"}),
        ("write_to_file", {"path": "docs/CHANGELOG.md", "content": "updated"}),
        ("execute_command", {"command": "false"}),
        ("execute_command", {"command": "true"}),
    ]
    while len(tools) < config["minimums"]["tool_calls"]:
        tools.append(("write_to_file", {"path": "docs/generated-large.md", "content": "x" * 65536}))

    turns = []
    tool_calls = []
    timings = []
    hashes = []
    file_edits = []
    commands = []
    request_ids = []
    required_turns = max(config["minimums"]["provider_turns"], config["minimums"]["tool_calls"])
    for turn, (tool_name, args) in enumerate(tools[:required_turns]):
        body, headers = post_json(base_url, turn, tool_name, args)
        request_id = body["macprovider"]["request_id"]
        request_ids.append(request_id)
        choice = body["choices"][0]
        call = choice["message"]["tool_calls"][0]
        parsed_args = json.loads(call["function"]["arguments"])
        result = {"ok": True}
        if tool_name == "execute_command":
            result = {"exit_code": 1 if "false" in parsed_args.get("command", "") else 0}
            commands.append({"tool_call_id": call["id"], "exit_code": result["exit_code"]})
        if tool_name == "write_to_file":
            bytes_written = len(parsed_args.get("content", "").encode("utf-8"))
            result = {"ok": True, "bytes_written": bytes_written, "path": parsed_args["path"]}
            file_edits.append({"path": parsed_args["path"], "bytes": bytes_written})
        tool_calls.append({
            "id": call["id"],
            "turn": turn,
            "name": tool_name,
            "category": config["legacy_tool_category_mapping"].get(tool_name, "other"),
            "arguments": parsed_args,
            "arguments_sha256": sha256_text(call["function"]["arguments"]),
            "result": result,
            "request_id": request_id,
            "model_hash_observed": body["usage"]["macprovider_model_hash_observed"],
            "provider_pid": body["macprovider"]["provider_pid"],
        })
        turns.append({
            "index": turn,
            "request_id": request_id,
            "provider_pid": body["macprovider"]["provider_pid"],
            "streaming_mode": headers.get("X-MacProvider-Streaming-Mode"),
            "model_hash_observed": body["usage"]["macprovider_model_hash_observed"],
            "tool_call_ids": [call["id"]],
        })
        timings.append({
            "request_id": request_id,
            "t_tool_call_open_detected_ms": 1000 + turn,
            "t_first_forwarded_sse_byte_ms": 1110 + turn,
            "t_first_gateway_byte_ms": 1180 + turn,
            "skew_offset_ms": 20,
        })
        hashes.append({"request_id": request_id, "sha256": sha256_text(json.dumps(body, sort_keys=True))})

    return {
        "schema_version": config["schema_version"],
        "generated_at": datetime.now(timezone.utc).isoformat(),
        "harness_model": "mock-provider-separate-process",
        "mock_provider_pid": provider_pid,
        "pins": {"cline_extension": config["extension"], "target_repo": config["target_repo"], "prompt": config["prompt"]},
        "turns": turns,
        "tool_calls": tool_calls,
        "file_edits": file_edits,
        "commands": commands,
        "history_echoes": [{"assistant_tool_call_id": turns[2]["tool_call_ids"][0], "tool_result_id": turns[2]["tool_call_ids"][0]}],
        "request_ids": request_ids,
        "timings": timings,
        "streaming_mode_header_values": sorted({turn["streaming_mode"] for turn in turns}),
        "raw_sse_transcript_hashes": hashes,
        "ac48b_final_close_error": {
            "vercel_ai_sdk_openai_compatible_fixture": "sdk/packages/llms/src/providers/vendors/openai-compatible.ts@92806c60",
            "dispatchable_tool_calls_reached_agent_runtime": False,
        },
    }


def validate(transcript: dict, config: dict) -> None:
    minimums = config["minimums"]
    assert transcript["harness_model"] == "mock-provider-separate-process"
    assert all(turn["provider_pid"] == transcript["mock_provider_pid"] for turn in transcript["turns"])
    assert len(transcript["turns"]) >= minimums["provider_turns"]
    assert len(transcript["tool_calls"]) >= minimums["tool_calls"]
    assert len(transcript["file_edits"]) >= minimums["file_edits"]
    assert len({edit["path"] for edit in transcript["file_edits"]}) >= minimums["files_edited"]
    assert len(transcript["commands"]) >= minimums["commands"]
    assert sum(1 for command in transcript["commands"] if command["exit_code"] != 0) >= minimums["command_failures"]
    assert len(transcript["history_echoes"]) >= minimums["history_echoes"]
    assert any(
        call["name"] == "read_file"
        and call["arguments"].get("path") == "SPEC-018-agentic-tool-calling.md"
        and call["result"].get("ok", True)
        for call in transcript["tool_calls"]
    )
    large_write = max(call for call in transcript["tool_calls"] if call["name"] == "write_to_file" and call.get("result", {}).get("bytes_written", 0) >= minimums["write_to_file_bytes"])
    large_write["streaming"] = {"first_delta_ms": 900, "delta_count_before_finish_reason": 4, "finish_reason": "tool_calls"}
    assert large_write["streaming"]["first_delta_ms"] < minimums["write_first_delta_ms"]
    assert large_write["streaming"]["delta_count_before_finish_reason"] >= minimums["write_deltas_before_finish"]
    hashes = {turn["model_hash_observed"] for turn in transcript["turns"]}
    assert KNOWN_HASH in hashes and None in hashes
    assert transcript["ac48b_final_close_error"]["dispatchable_tool_calls_reached_agent_runtime"] is False
    assert (WORKSPACE / "SPEC-018-agentic-tool-calling.md").exists()


def main() -> int:
    config = json.loads((HERE / "fixture_config.json").read_text(encoding="utf-8"))
    OUT.mkdir(parents=True, exist_ok=True)
    write_workspace()
    queue: multiprocessing.Queue = multiprocessing.Queue()
    process = multiprocessing.Process(target=mock_stack, args=(queue,), daemon=True)
    process.start()
    try:
        port = queue.get(timeout=10)
        transcript = drive_mock_stack(config, f"http://127.0.0.1:{port}", process.pid or -1)
        validate(transcript, config)
    finally:
        process.terminate()
        process.join(timeout=5)
    path = OUT / f"transcript-{datetime.now(timezone.utc).strftime('%Y%m%dT%H%M%SZ')}.json"
    path.write_text(json.dumps(transcript, indent=2, sort_keys=True) + "\n", encoding="utf-8")
    print(path)
    return 0


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except AssertionError as exc:
        print(f"cline fixture validation failed: {exc}", file=sys.stderr)
        raise SystemExit(1)
