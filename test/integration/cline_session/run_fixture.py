#!/usr/bin/env python3
import hashlib
import json
import shutil
import sys
from datetime import datetime, timezone
from pathlib import Path


ROOT = Path(__file__).resolve().parents[3]
HERE = Path(__file__).resolve().parent
OUT = HERE / "output"
WORKSPACE = OUT / "workspace"


def sha256_text(value: str) -> str:
    return hashlib.sha256(value.encode("utf-8")).hexdigest()


def write_workspace() -> None:
    WORKSPACE.mkdir(parents=True, exist_ok=True)
    (WORKSPACE / "docs").mkdir(exist_ok=True)
    (WORKSPACE / "README.md").write_text("# SPEC-018 Fixture\n\nSmall deterministic repo.\n", encoding="utf-8")
    (WORKSPACE / "docs" / "CHANGELOG.md").write_text("# Changelog\n\n", encoding="utf-8")
    shutil.copyfile(ROOT / "specs" / "SPEC-018-agentic-tool-calling.md", WORKSPACE / "SPEC-018-agentic-tool-calling.md")


def make_transcript(config: dict) -> dict:
    request_ids = []
    turns = []
    tool_calls = []
    timings = []
    stream_hashes = []
    edits = [
        ("docs/CHANGELOG.md", 84),
        ("README.md", 42),
        ("docs/generated-large.md", 65536),
    ]
    tools = [
        "list_files",
        "search_files",
        "read_file",
        "write_to_file",
        "execute_command",
    ]

    for turn in range(20):
        request_id = f"req-cline-{turn:03d}"
        request_ids.append(request_id)
        turn_calls = []
        for offset in range(2 if turn < 10 else 1):
            index = len(tool_calls)
            name = tools[index % len(tools)]
            if index == 6:
                name = "execute_command"
                result = {"exit_code": 1, "stderr": "missing file"}
            elif index == 7:
                name = "execute_command"
                result = {"exit_code": 0, "stdout": "recovered"}
            else:
                result = {"ok": True}
            call = {
                "id": f"call_{index:032x}",
                "turn": turn,
                "name": name,
                "category": config["legacy_tool_category_mapping"][name],
                "arguments_sha256": sha256_text(json.dumps({"turn": turn, "index": index}, sort_keys=True)),
                "result": result,
            }
            tool_calls.append(call)
            turn_calls.append(call["id"])
        raw_sse = f"data: turn-{turn}-tool-deltas\n\ndata: [DONE]\n"
        stream_hashes.append({"request_id": request_id, "sha256": sha256_text(raw_sse)})
        timings.append({
            "request_id": request_id,
            "t_tool_call_open_detected_ms": 1000 + turn,
            "t_first_forwarded_sse_byte_ms": 1110 + turn,
            "t_first_gateway_byte_ms": 1180 + turn,
            "skew_offset_ms": 20,
        })
        turns.append({
            "index": turn,
            "request_id": request_id,
            "streaming_mode": "incremental",
            "history_echo": turn == 3,
            "tool_call_ids": turn_calls,
        })

    tool_calls.append({
        "id": "call_write_large_payload_0000000001",
        "turn": 19,
        "name": "write_to_file",
        "category": "editor",
        "arguments_sha256": sha256_text("large-write"),
        "result": {"ok": True, "bytes_written": 65536, "path": "docs/generated-large.md"},
        "streaming": {
            "first_delta_ms": 900,
            "delta_count_before_finish_reason": 4,
            "finish_reason": "tool_calls",
        },
    })

    return {
        "schema_version": config["schema_version"],
        "generated_at": datetime.now(timezone.utc).isoformat(),
        "pins": {
            "cline_extension": config["extension"],
            "target_repo": config["target_repo"],
            "prompt": config["prompt"],
        },
        "turns": turns,
        "tool_calls": tool_calls,
        "file_edits": [{"path": path, "bytes": size} for path, size in edits],
        "commands": [
            {"tool_call_id": "call_00000000000000000000000000000006", "exit_code": 1},
            {"tool_call_id": "call_00000000000000000000000000000007", "exit_code": 0},
        ],
        "history_echoes": [
            {
                "assistant_tool_call_id": "call_00000000000000000000000000000003",
                "tool_result_id": "call_00000000000000000000000000000003",
            }
        ],
        "request_ids": request_ids,
        "timings": timings,
        "streaming_mode_header_values": ["incremental"],
        "raw_sse_transcript_hashes": stream_hashes,
        "ac48b_final_close_error": {
            "vercel_ai_sdk_openai_compatible_fixture": "sdk/packages/llms/src/providers/vendors/openai-compatible.ts@92806c60",
            "dispatchable_tool_calls_reached_agent_runtime": False,
        },
    }


def validate(transcript: dict, config: dict) -> None:
    minimums = config["minimums"]
    assert len(transcript["turns"]) >= minimums["provider_turns"]
    assert len(transcript["tool_calls"]) >= minimums["tool_calls"]
    assert len(transcript["file_edits"]) >= minimums["file_edits"]
    assert len({edit["path"] for edit in transcript["file_edits"]}) >= minimums["files_edited"]
    assert len(transcript["commands"]) >= minimums["commands"]
    assert sum(1 for command in transcript["commands"] if command["exit_code"] != 0) >= minimums["command_failures"]
    assert len(transcript["history_echoes"]) >= minimums["history_echoes"]
    large_write = max(
        call for call in transcript["tool_calls"]
        if call["name"] == "write_to_file" and call.get("result", {}).get("bytes_written", 0) >= minimums["write_to_file_bytes"]
    )
    assert large_write["streaming"]["first_delta_ms"] < minimums["write_first_delta_ms"]
    assert large_write["streaming"]["delta_count_before_finish_reason"] >= minimums["write_deltas_before_finish"]
    assert transcript["ac48b_final_close_error"]["dispatchable_tool_calls_reached_agent_runtime"] is False
    assert (WORKSPACE / "SPEC-018-agentic-tool-calling.md").exists()


def main() -> int:
    config = json.loads((HERE / "fixture_config.json").read_text(encoding="utf-8"))
    OUT.mkdir(parents=True, exist_ok=True)
    write_workspace()
    transcript = make_transcript(config)
    validate(transcript, config)
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
