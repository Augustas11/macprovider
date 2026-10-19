#!/usr/bin/env python3
"""Bounded correctness probe for an isolated --no-join provider on the Studio.

The caller owns provider launch/provenance and must use a separate port. This
probe never starts, replaces, or joins a provider. It records no prompt/output
text and makes eight small inference requests, not a performance benchmark.
"""

import argparse
import hashlib
import json
import pathlib
import subprocess
import sys
import urllib.parse
import urllib.request


PROFILES = {
    "mlx-community/Qwen3-Coder-30B-A3B-Instruct-4bit": (
        "6e302ea604ad9ab206367e2c501d1571023e7b6d",
        "672e747c77e990320152343b0a4951222e40de5645297905d89afba05586d827",
    ),
    "mlx-community/Qwen3-30B-A3B-Instruct-2507-4bit": (
        "e9675aa3ca5f900ccef55267914466d55ab325fa",
        "40c21f34cf67d8c760ef72f8ad3ae5afad514299d4b06e91dd9a8d705af7b541",
    ),
}
MAX_RESPONSE_BYTES = 262_144


class NoRedirect(urllib.request.HTTPRedirectHandler):
    def redirect_request(self, *_args, **_kwargs):
        raise ValueError("redirect refused")


def fetch(opener, base, path, body=None):
    request = urllib.request.Request(
        base + path,
        data=None if body is None else json.dumps(body).encode(),
        headers={"Content-Type": "application/json"},
    )
    with opener.open(request, timeout=120) as response:
        data = response.read(MAX_RESPONSE_BYTES + 1)
        if len(data) > MAX_RESPONSE_BYTES:
            raise ValueError("response exceeded bound")
        return data.decode("utf-8")


def tool(name):
    return {"type": "function", "function": {
        "name": name, "description": "Look up information for a city.",
        "parameters": {"type": "object", "properties": {
            "city": {"type": "string", "enum": ["Paris"]}},
            "required": ["city"], "additionalProperties": False},
    }}


def read_completion(raw, stream):
    if not stream:
        choice = json.loads(raw)["choices"][0]
        return choice["message"], choice["finish_reason"]
    calls = {}
    content = ""
    finish = None
    done = False
    for line in raw.splitlines():
        if not line.startswith("data:"):
            continue
        data = line[5:].strip()
        if data == "[DONE]":
            done = True
            continue
        event = json.loads(data)
        if "error" in event:
            raise ValueError("stream returned error")
        for choice in event.get("choices", []):
            delta = choice.get("delta", {})
            content += delta.get("content") or ""
            for call in delta.get("tool_calls", []):
                target = calls.setdefault(call["index"], {"id": "", "type": "function", "function": {"name": "", "arguments": ""}})
                target["id"] += call.get("id", "")
                for key in ("name", "arguments"):
                    target["function"][key] += call.get("function", {}).get(key, "")
            if choice.get("finish_reason"):
                finish = choice["finish_reason"]
    if not done:
        raise ValueError("stream omitted DONE")
    return {"content": content, "tool_calls": list(calls.values())}, finish


def validate_completion(raw, stream, named):
    message, finish = read_completion(raw, stream)
    if finish != "tool_calls" or message.get("content") not in (None, ""):
        raise ValueError("response leaked content or did not finish with a call")
    calls = message.get("tool_calls", [])
    if len(calls) != 1 or not calls[0].get("id") or calls[0].get("type") != "function":
        raise ValueError("invalid call cardinality or envelope")
    function = calls[0]["function"]
    allowed = ["get_time"] if named else ["get_weather", "get_time"]
    if function["name"] not in allowed or json.loads(function["arguments"]) != {"city": "Paris"}:
        raise ValueError("name or arguments failed strict validation")
    return message


def validate_history(raw, stream):
    message, finish = read_completion(raw, stream)
    content = message.get("content") or ""
    if (finish != "stop" or message.get("tool_calls") or "PROFILE_HISTORY_OK" not in content
            or any(marker in content for marker in ("<tool_call>", "<function=", "<tool_response"))):
        raise ValueError("tool history did not produce the requested final answer")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--base-url", required=True, help="isolated loopback URL, e.g. http://127.0.0.1:18054")
    parser.add_argument("--model", required=True, choices=PROFILES)
    parser.add_argument("--snapshot-dir", required=True, type=pathlib.Path, help="pinned HF snapshots/<revision> directory loaded by the provider")
    args = parser.parse_args()
    host = subprocess.check_output(["scutil", "--get", "LocalHostName"], text=True).strip()
    hardware = subprocess.check_output(["sysctl", "-n", "hw.model"], text=True).strip()
    if host != "1deMac-Studio" or hardware != "Mac15,14":
        raise ValueError("designated Studio identity required")
    url = urllib.parse.urlsplit(args.base_url)
    if (url.scheme != "http" or url.hostname != "127.0.0.1" or url.port in (None, 80, 8080)
            or url.username or url.password or url.query or url.fragment or url.path not in ("", "/")):
        raise ValueError("isolated loopback port required; live/default ports refused")
    revision, template_hash = PROFILES[args.model]
    snapshot = args.snapshot_dir.resolve(strict=True)
    if snapshot.name != revision:
        raise ValueError("snapshot revision does not match catalog")
    config = json.loads((snapshot / "tokenizer_config.json").read_text())
    template = config.get("chat_template")
    if template is None:
        template = (snapshot / "chat_template.jinja").read_text()
    if not isinstance(template, str) or hashlib.sha256(template.encode()).hexdigest() != template_hash:
        raise ValueError("pinned upstream template hash mismatch")
    opener = urllib.request.build_opener(urllib.request.ProxyHandler({}), NoRedirect())
    base = args.base_url.rstrip("/")
    health = json.loads(fetch(opener, base, "/v1/health"))
    if health.get("model") != args.model or health.get("model_loaded") is not True:
        raise ValueError("provider must report the exact loaded model")
    results = []
    for stream in (False, True):
        for named in (False, True):
            print(json.dumps({"stage": "call", "mode": "named" if named else "required", "stream": stream}), file=sys.stderr, flush=True)
            body = {"model": args.model, "messages": [{"role": "user", "content": "Call get_weather for Paris."}],
                    "max_tokens": 256, "temperature": 0, "stream": stream, "parallel_tool_calls": False,
                    "tools": [tool("get_weather"), tool("get_time")],
                    "tool_choice": {"type": "function", "function": {"name": "get_time"}} if named else "required"}
            raw = fetch(opener, base, "/v1/chat/completions", body)
            message = validate_completion(raw, stream, named)
            print(json.dumps({"stage": "history", "mode": "named" if named else "required", "stream": stream}), file=sys.stderr, flush=True)
            followup = dict(body)
            followup["tool_choice"] = "auto"
            followup["max_tokens"] = 128
            followup["messages"] = body["messages"] + [
                {"role": "assistant", "content": "", "tool_calls": message["tool_calls"]},
                {"role": "tool", "tool_call_id": message["tool_calls"][0]["id"],
                 "content": '{"city":"Paris","result":"PROFILE_HISTORY_OK"}'},
                {"role": "user", "content": "Return the exact result value from the tool response above as your final answer. Do not call another tool."},
            ]
            validate_history(fetch(opener, base, "/v1/chat/completions", followup), stream)
            results.append({"mode": "named" if named else "required", "stream": stream,
                            "passed": True, "multi_turn_final_answer": True})
    print(json.dumps({"model": args.model, "revision": revision, "template_sha256": template_hash,
                      "results": results, "scope": "isolated local correctness; not live gateway qualification"}, indent=2))


if __name__ == "__main__":
    try:
        main()
    except Exception as error:
        # Avoid serializing HTTP bodies, prompts, filesystem paths or config.
        failure = {"passed": False, "error_type": type(error).__name__}
        if type(error) is ValueError:
            failure["reason"] = str(error)
        print(json.dumps(failure), file=sys.stderr)
        sys.exit(1)
