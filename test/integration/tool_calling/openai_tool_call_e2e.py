#!/usr/bin/env python3
import json
import os
import sys
import time
import urllib.error
import urllib.request
from pathlib import Path
from typing import Any

from openai import OpenAI


MODEL = os.getenv("MACPROVIDER_TOOL_E2E_MODEL", "mlx-community/Qwen2.5-7B-Instruct-4bit")
BASE_URL = os.getenv("MACPROVIDER_TOOL_E2E_BASE_URL", "").rstrip("/")
API_KEY = os.getenv("MACPROVIDER_TOOL_E2E_API_KEY", "local-dev")
PIN_PROVIDER = os.getenv("MACPROVIDER_TOOL_E2E_PIN_PROVIDER")
OUTPUT = os.getenv("MACPROVIDER_TOOL_E2E_OUTPUT")

RAW_DELIMITERS = ("<tool_call>", "</tool_call>", "<|python_tag|>", "<|eom_id|>")

TOOL = {
    "type": "function",
    "function": {
        "name": "find_definition",
        "description": "Find where a code symbol is defined",
        "parameters": {
            "type": "object",
            "properties": {"symbol": {"type": "string"}},
            "required": ["symbol"],
        },
    },
}

MESSAGES = [
    {
        "role": "user",
        "content": (
            "Use the find_definition tool to answer. Call find_definition with "
            "symbol ToolCallParser and do not answer directly."
        ),
    }
]


def normalize_base_url(raw: str) -> str:
    if not raw:
        raise AssertionError("MACPROVIDER_TOOL_E2E_BASE_URL is required")
    return raw if raw.endswith("/v1") else raw + "/v1"


def headers() -> dict[str, str]:
    out = {
        "Authorization": f"Bearer {API_KEY}",
        "Content-Type": "application/json",
    }
    if PIN_PROVIDER:
        out["X-MacProvider-Pin-Provider"] = PIN_PROVIDER
    return out


def default_headers() -> dict[str, str] | None:
    if PIN_PROVIDER:
        return {"X-MacProvider-Pin-Provider": PIN_PROVIDER}
    return None


def has_raw_delimiter(value: Any) -> bool:
    return any(delimiter in json.dumps(value, sort_keys=True) for delimiter in RAW_DELIMITERS)


def model_dump(value: Any) -> dict[str, Any]:
    if hasattr(value, "model_dump"):
        return value.model_dump()
    raise AssertionError(f"object is not pydantic-dumpable: {type(value)!r}")


def assert_tool_call(call: Any) -> dict[str, Any]:
    if call.function.name != "find_definition":
        raise AssertionError(f"unexpected function name: {call.function.name!r}")
    arguments = json.loads(call.function.arguments)
    symbol = str(arguments.get("symbol", ""))
    if symbol != "ToolCallParser":
        raise AssertionError(f"expected symbol ToolCallParser, got arguments {arguments!r}")
    return arguments


def post_json(path: str, body: dict[str, Any]) -> tuple[int, dict[str, Any]]:
    data = json.dumps(body, separators=(",", ":")).encode("utf-8")
    request = urllib.request.Request(
        normalize_base_url(BASE_URL) + path,
        data=data,
        headers=headers(),
        method="POST",
    )
    try:
        with urllib.request.urlopen(request, timeout=60) as response:
            return response.status, json.loads(response.read().decode("utf-8"))
    except urllib.error.HTTPError as error:
        raw = error.read().decode("utf-8")
        try:
            parsed = json.loads(raw)
        except json.JSONDecodeError:
            parsed = {"raw": raw}
        return error.code, parsed


def get_json(path: str) -> tuple[int, dict[str, Any]]:
    request = urllib.request.Request(
        normalize_base_url(BASE_URL) + path,
        headers=headers(),
        method="GET",
    )
    with urllib.request.urlopen(request, timeout=60) as response:
        return response.status, json.loads(response.read().decode("utf-8"))


def error_code(payload: dict[str, Any]) -> str | None:
    error = payload.get("error")
    if isinstance(error, dict):
        code = error.get("code")
        return str(code) if code is not None else None
    return None


def expect_400(label: str, body: dict[str, Any], expected_code: str) -> dict[str, Any]:
    status, payload = post_json("/chat/completions", body)
    actual_code = error_code(payload)
    if status != 400 or actual_code != expected_code:
        raise AssertionError(
            f"{label}: expected 400/{expected_code}, got {status}/{actual_code}: {payload}"
        )
    return {"label": label, "status": status, "code": actual_code, "body": payload}


def run() -> dict[str, Any]:
    base_url = normalize_base_url(BASE_URL)
    client = OpenAI(
        base_url=base_url,
        api_key=API_KEY,
        default_headers=default_headers(),
        timeout=120.0,
    )

    models_status, models_payload = get_json("/models")

    non_streaming = client.chat.completions.create(
        model=MODEL,
        messages=MESSAGES,
        tools=[TOOL],
    )
    if non_streaming.model != MODEL:
        raise AssertionError(f"response model mismatch: {non_streaming.model!r}")
    choice = non_streaming.choices[0]
    if choice.finish_reason != "tool_calls":
        raise AssertionError(f"expected finish_reason tool_calls, got {choice.finish_reason!r}")
    if choice.message.content is not None:
        raise AssertionError(f"expected null content for tool call, got {choice.message.content!r}")
    tool_calls = choice.message.tool_calls or []
    if not tool_calls:
        raise AssertionError("expected non-streaming tool_calls")
    arguments = assert_tool_call(tool_calls[0])
    non_streaming_dump = model_dump(non_streaming)
    if has_raw_delimiter(non_streaming_dump):
        raise AssertionError("non-streaming response leaked raw tool-call delimiters")

    stream_chunks: list[dict[str, Any]] = []
    saw_delta_tool_call = False
    saw_tool_finish = False
    stream = client.chat.completions.create(
        model=MODEL,
        messages=MESSAGES,
        tools=[TOOL],
        stream=True,
    )
    for chunk in stream:
        dumped = model_dump(chunk)
        stream_chunks.append(dumped)
        if not chunk.choices:
            continue
        delta = chunk.choices[0].delta
        if delta.tool_calls:
            saw_delta_tool_call = True
            assert_tool_call(delta.tool_calls[0])
        if chunk.choices[0].finish_reason == "tool_calls":
            saw_tool_finish = True

    if not saw_delta_tool_call:
        raise AssertionError("streaming response did not emit delta.tool_calls[]")
    if not saw_tool_finish:
        raise AssertionError("streaming response did not finish with tool_calls")
    if has_raw_delimiter(stream_chunks):
        raise AssertionError("streaming response leaked raw tool-call delimiters")

    common_body = {
        "model": MODEL,
        "messages": MESSAGES,
        "tools": [TOOL],
    }
    negative = [
        expect_400(
            "non_auto_tool_choice",
            {**common_body, "tool_choice": "none"},
            "unsupported_tool_choice",
        ),
        expect_400(
            "assistant_tool_calls_input",
            {
                "model": MODEL,
                "messages": [
                    *MESSAGES,
                    {
                        "role": "assistant",
                        "content": None,
                        "tool_calls": [
                            {
                                "id": "call_test",
                                "type": "function",
                                "function": {
                                    "name": "find_definition",
                                    "arguments": "{\"symbol\":\"ToolCallParser\"}",
                                },
                            }
                        ],
                    },
                ],
            },
            "unsupported_tool_messages",
        ),
        expect_400(
            "tool_role_input",
            {
                "model": MODEL,
                "messages": [
                    *MESSAGES,
                    {
                        "role": "tool",
                        "tool_call_id": "call_test",
                        "content": "{\"temperature_c\":21}",
                    },
                ],
            },
            "unsupported_tool_messages",
        ),
    ]

    return {
        "ok": True,
        "timestamp_unix": int(time.time()),
        "base_url": base_url,
        "model": MODEL,
        "pin_provider": PIN_PROVIDER,
        "models_status": models_status,
        "models": models_payload,
        "non_streaming": {
            "finish_reason": choice.finish_reason,
            "tool_calls": [model_dump(call) for call in tool_calls],
            "arguments": arguments,
            "raw": non_streaming_dump,
        },
        "streaming": {
            "saw_delta_tool_calls": saw_delta_tool_call,
            "saw_finish_reason_tool_calls": saw_tool_finish,
            "chunks": stream_chunks,
        },
        "negative_paths": negative,
    }


def main() -> int:
    artifact = run()
    output_path = Path(OUTPUT) if OUTPUT else Path("artifacts") / (
        "tool-calling-e2e-" + time.strftime("%Y%m%dT%H%M%SZ", time.gmtime()) + ".json"
    )
    output_path.parent.mkdir(parents=True, exist_ok=True)
    output_path.write_text(json.dumps(artifact, indent=2, sort_keys=True) + "\n", encoding="utf-8")
    print(f"wrote {output_path}")
    print(json.dumps({
        "ok": True,
        "base_url": artifact["base_url"],
        "model": artifact["model"],
        "pin_provider": artifact["pin_provider"],
        "artifact": str(output_path),
    }, indent=2, sort_keys=True))
    return 0


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except Exception as exc:
        print(f"tool-calling e2e failed: {exc}", file=sys.stderr)
        raise
