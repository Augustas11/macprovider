#!/usr/bin/env python3
"""Golden fixtures for the Swift DeepSeek-V4 prompt encoder and DSML parser.

Runs the model's own reference, `encoding/encoding_dsv4.py` from
`deepseek-ai/DeepSeek-V4-Flash-0731` (sha256 abc0d261...dde6, identical in the
TensorFold MXFP4 artifact), and writes the expected outputs:

  python3 -I scripts/lab/dsv4/make_encoding_fixtures.py <encoding-dir> <out.json> [tokenizer.json]

<encoding-dir> holds `encoding_dsv4.py` and its `tests/` directory. The output
is `scripts/tests/fixtures/dsv4-encoding/cases.json`. With the optional pinned
`tokenizer.json`, also writes sibling `token-ids.json` using Rust `tokenizers`
(no model load). Both files are read by
`DeepseekV4EncodingTests` (phase3-binary). Three sections:

- `reference`: the reference's four test cases (inputs and golden prompts).
- `requests`: OpenAI request bodies the provider receives, with the prompt the
  reference renders for them under the provider's mapping: tools ride on the
  first system message (an empty one is inserted when there is none), schema
  and argument keys are sorted (the provider holds JSON objects unordered),
  tool functions keep the OpenAI order (name, description, parameters), and
  `reasoning_effort` maps none -> chat mode, high/xhigh -> high, max -> max,
  anything else (or omitted) -> low.
- `completions`: model completion texts with the reference's
  `parse_message_from_completion_text` result.
"""
from __future__ import annotations

import hashlib
import json
import pathlib
import sys

REFERENCE_SHA256 = "abc0d26120250dda0ae077dc64aa28836026e61e970854aaeb792445e6a0dde6"


def sorted_json(value):
    return json.loads(json.dumps(value, sort_keys=True))


def reference_messages(body: dict) -> tuple[list, str, str | None]:
    """The provider's mapping of an OpenAI request to reference messages."""
    messages = []
    names = {}
    for message in body["messages"]:
        role = message["role"]
        out = {"role": role, "content": message.get("content") or ""}
        if role == "assistant" and message.get("tool_calls"):
            calls = []
            for call in message["tool_calls"]:
                names[call["id"]] = call["function"]["name"]
                calls.append({
                    "id": call["id"],
                    "type": "function",
                    "function": {
                        "name": call["function"]["name"],
                        "arguments": json.dumps(sorted_json(json.loads(call["function"]["arguments"])), ensure_ascii=False),
                    },
                })
            out["tool_calls"] = calls
        if role == "tool":
            out["tool_call_id"] = message["tool_call_id"]
        messages.append(out)
    tools = body.get("tools")
    if tools:
        rendered = []
        for tool in tools:
            fn = tool["function"]
            function = {"name": fn["name"]}
            if fn.get("description") is not None:
                function["description"] = fn["description"]
            function["parameters"] = sorted_json(fn["parameters"])
            rendered.append({"type": "function", "function": function})
        if messages and messages[0]["role"] == "system":
            messages[0]["tools"] = rendered
        else:
            messages.insert(0, {"role": "system", "content": "", "tools": rendered})
    effort = body.get("reasoning_effort")
    if effort is None and tools:
        effort = "low"  # ChatCompletionRequest.templateReasoningEffort
    if effort == "none":
        return messages, "chat", None
    return messages, "thinking", {"high": "high", "xhigh": "high", "max": "max"}.get(effort, "low")


TOOLS = [
    {"type": "function", "function": {
        "name": "read_file",
        "description": "Read a file from disk",
        "parameters": {"type": "object", "properties": {"path": {"type": "string"}}, "required": ["path"]},
    }},
    {"type": "function", "function": {
        "name": "search",
        "description": "Search the web — résumé, naïve, 東京\ttab",
        "parameters": {
            "type": "object",
            "properties": {
                "query": {"type": "string", "description": "Query \"quoted\" \\ back"},
                "limit": {"type": "integer", "default": 10, "minimum": 1},
                "score": {"type": "number", "default": 0.5, "exclusiveMaximum": 1e-05},
                "mode": {"enum": [None, "fast", "deep"]},
                "filters": {"type": "object", "properties": {"site": {"type": "string"}}},
                "tags": {"type": "array", "items": {"type": "string"}},
            },
            "required": ["query"],
        },
    }},
    {"type": "function", "function": {
        "name": "no_description",
        "parameters": {"type": "object", "properties": {}},
    }},
]

REQUESTS = [
    ("system_user_default_effort", {"messages": [
        {"role": "system", "content": "You are a helpful assistant."},
        {"role": "user", "content": "What is 2+2?"}]}),
    ("user_only", {"messages": [{"role": "user", "content": "Hello"}]}),
    ("effort_high", {"reasoning_effort": "high", "messages": [{"role": "user", "content": "Prove it."}]}),
    ("effort_xhigh_maps_high", {"reasoning_effort": "xhigh", "messages": [{"role": "user", "content": "Prove it."}]}),
    ("effort_max", {"reasoning_effort": "max", "messages": [
        {"role": "system", "content": "Be exact."}, {"role": "user", "content": "Prove it."}]}),
    ("effort_medium_maps_low", {"reasoning_effort": "medium", "messages": [{"role": "user", "content": "Prove it."}]}),
    ("effort_none_chat_mode", {"reasoning_effort": "none", "messages": [
        {"role": "system", "content": "Be brief."}, {"role": "user", "content": "Hi"}]}),
    ("tools_with_system", {"tools": TOOLS, "messages": [
        {"role": "system", "content": "You are a coding agent."},
        {"role": "user", "content": "Read /etc/hosts."}]}),
    ("tools_without_system", {"tools": TOOLS[:1], "messages": [{"role": "user", "content": "Read /etc/hosts."}]}),
    ("tools_effort_max", {"tools": TOOLS[:1], "reasoning_effort": "max", "messages": [
        {"role": "user", "content": "Read /etc/hosts."}]}),
    ("tool_round_trip_parallel_results_sorted", {"tools": TOOLS, "messages": [
        {"role": "system", "content": "You are a coding agent."},
        {"role": "user", "content": "Read both files."},
        {"role": "assistant", "content": None, "tool_calls": [
            {"id": "call_aaaaaaaaaaaaaaaa", "type": "function", "function": {"name": "read_file", "arguments": "{\"path\": \"/etc/hosts\"}"}},
            {"id": "call_bbbbbbbbbbbbbbbb", "type": "function", "function": {"name": "read_file", "arguments": "{\"path\": \"/etc/passwd\"}"}}]},
        {"role": "tool", "tool_call_id": "call_bbbbbbbbbbbbbbbb", "content": "root:x:0:0"},
        {"role": "tool", "tool_call_id": "call_aaaaaaaaaaaaaaaa", "content": "127.0.0.1 localhost"}]}),
    ("tool_history_typed_arguments_then_user", {"tools": TOOLS, "messages": [
        {"role": "user", "content": "Search."},
        {"role": "assistant", "content": "Searching now.", "tool_calls": [
            {"id": "call_ssssssssssssssss", "type": "function", "function": {"name": "search", "arguments": json.dumps({
                "query": "naïve \"x\"\nline", "limit": 3, "score": 0.25, "mode": None,
                "filters": {"site": "a.b", "deep": [1, 2.5, True]}, "tags": []})}}]},
        {"role": "tool", "tool_call_id": "call_ssssssssssssssss", "content": "no results"},
        {"role": "assistant", "content": "Nothing found."},
        {"role": "user", "content": "Try again."}]}),
    ("multi_turn_drops_earlier_thinking", {"messages": [
        {"role": "system", "content": "You are a helpful assistant."},
        {"role": "user", "content": "Hello"},
        {"role": "assistant", "content": "Hi there!"},
        {"role": "user", "content": "What is the capital of France?"}]}),
    ("multi_turn_chat_mode", {"reasoning_effort": "none", "messages": [
        {"role": "user", "content": "Hello"},
        {"role": "assistant", "content": "Hi there!"},
        {"role": "user", "content": "Bye"}]}),
]

D = "｜DSML｜"
COMPLETIONS = [
    ("thinking_answer", "thinking", "The user asks 2+2. That is 4.</think>4<｜end▁of▁sentence｜>"),
    ("thinking_single_call", "thinking",
     "I should read the file.</think>\n\n<" + D + "tool_calls>\n<" + D + "invoke name=\"read_file\">\n<" + D
     + "parameter name=\"path\" string=\"true\">/etc/hosts</" + D + "parameter>\n</" + D + "invoke>\n</" + D
     + "tool_calls><｜end▁of▁sentence｜>"),
    ("thinking_parallel_calls", "thinking",
     "Two files.</think>\n\n<" + D + "tool_calls>\n<" + D + "invoke name=\"read_file\">\n<" + D
     + "parameter name=\"path\" string=\"true\">/etc/hosts</" + D + "parameter>\n</" + D + "invoke>\n<" + D
     + "invoke name=\"read_file\">\n<" + D + "parameter name=\"path\" string=\"true\">/etc/passwd</" + D
     + "parameter>\n</" + D + "invoke>\n</" + D + "tool_calls><｜end▁of▁sentence｜>"),
    ("thinking_typed_parameters", "thinking",
     "Search with options.</think>\n\n<" + D + "tool_calls>\n<" + D + "invoke name=\"search\">\n<" + D
     + "parameter name=\"query\" string=\"true\">naïve 東京 a<b \"q\"\nsecond line</" + D + "parameter>\n<" + D
     + "parameter name=\"limit\" string=\"false\">3</" + D + "parameter>\n<" + D
     + "parameter name=\"score\" string=\"false\">0.25</" + D + "parameter>\n<" + D
     + "parameter name=\"mode\" string=\"false\">null</" + D + "parameter>\n<" + D
     + "parameter name=\"filters\" string=\"false\">{\"site\": \"a.b\", \"deep\": [1, 2.5, true]}</" + D + "parameter>\n<" + D
     + "parameter name=\"tags\" string=\"false\">[\"x\", \"y\"]</" + D + "parameter>\n</" + D + "invoke>\n</" + D
     + "tool_calls><｜end▁of▁sentence｜>"),
    ("thinking_prose_then_call", "thinking",
     "Plan.</think>Let me check that file.\n\n<" + D + "tool_calls>\n<" + D + "invoke name=\"read_file\">\n<" + D
     + "parameter name=\"path\" string=\"true\">a.txt</" + D + "parameter>\n</" + D + "invoke>\n</" + D
     + "tool_calls><｜end▁of▁sentence｜>"),
    ("chat_mode_call", "chat",
     "\n\n<" + D + "tool_calls>\n<" + D + "invoke name=\"no_description\">\n</" + D + "invoke>\n</" + D
     + "tool_calls><｜end▁of▁sentence｜>"),
    ("chat_mode_answer", "chat", "Paris is the capital of France.<｜end▁of▁sentence｜>"),
]


def main(argv: list[str]) -> int:
    if len(argv) not in (3, 4):
        print(__doc__, file=sys.stderr)
        return 2
    encoding_dir = pathlib.Path(argv[1]).resolve()
    source = encoding_dir / "encoding_dsv4.py"
    digest = hashlib.sha256(source.read_bytes()).hexdigest()
    if digest != REFERENCE_SHA256:
        print(f"{source}: sha256 {digest} is not the pinned reference {REFERENCE_SHA256}", file=sys.stderr)
        return 1
    sys.path.insert(0, str(encoding_dir))
    import encoding_dsv4 as enc  # noqa: E402

    tests = encoding_dir / "tests"
    reference = []
    for number, mode in ((1, "thinking"), (2, "thinking"), (3, "thinking"), (4, "chat")):
        data = json.loads((tests / f"test_input_{number}.json").read_text(encoding="utf-8"))
        if isinstance(data, dict):
            messages = data["messages"]
            messages[0]["tools"] = data["tools"]
        else:
            messages = data
        gold = (tests / f"test_output_{number}.txt").read_text(encoding="utf-8")
        assert enc.encode_messages(json.loads(json.dumps(messages)), thinking_mode=mode) == gold
        reference.append({"name": f"reference_case_{number}", "thinking_mode": mode, "messages": messages, "prompt": gold})

    requests = []
    for name, body in REQUESTS:
        body = {"model": "deepseek/deepseek-v4-flash", **body}
        messages, mode, effort = reference_messages(json.loads(json.dumps(body)))
        prompt = enc.encode_messages(messages, thinking_mode=mode, reasoning_effort=effort)
        requests.append({"name": name, "request": body, "prompt": prompt})

    completions = []
    for name, mode, text in COMPLETIONS:
        parsed = enc.parse_message_from_completion_text(text, thinking_mode=mode)
        completions.append({
            "name": name,
            "thinking_mode": mode,
            "text": text,
            "content": parsed["content"],
            "reasoning_content": parsed["reasoning_content"],
            "tool_calls": [{"name": c["function"]["name"], "arguments": json.loads(c["function"]["arguments"])}
                           for c in parsed["tool_calls"]],
        })

    out = {
        "schema": "macprovider.dsv4-encoding-fixtures.v1",
        "reference_sha256": REFERENCE_SHA256,
        "reference": reference,
        "requests": requests,
        "completions": completions,
    }
    pathlib.Path(argv[2]).write_text(json.dumps(out, ensure_ascii=False, indent=1) + "\n", encoding="utf-8")
    if len(argv) == 4:
        # Optional CPU-only token IDs; use the pinned TensorFold artifact.
        from tokenizers import Tokenizer

        tokenizer_path = pathlib.Path(argv[3])
        tokenizer_digest = hashlib.sha256(tokenizer_path.read_bytes()).hexdigest()
        if tokenizer_digest != "8f9f37ca37fdc4f5fd36d5cf4d3b0e8392edb4e894fd10cc0d70b4957c8633cf":
            raise ValueError("tokenizer.json is not the pinned DeepSeek-V4 artifact")
        tokenizer = Tokenizer.from_file(str(tokenizer_path))
        ids = {
            "artifact": "TensorFold/DeepSeek-V4-Flash-0731-MXFP4-MLX@d6be051a",
            "tokenizer_sha256": tokenizer_digest,
            **{section: {item["name"]: tokenizer.encode(item["prompt"], add_special_tokens=False).ids
                         for item in out[section]} for section in ("reference", "requests")},
        }
        pathlib.Path(argv[2]).with_name("token-ids.json").write_text(
            json.dumps(ids, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
