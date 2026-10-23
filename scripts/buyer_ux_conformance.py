#!/usr/bin/env python3
"""Buyer-UX conformance suite for catalog intake (#2107, SPEC-023 §16.11).

One entry point checks a served model through the Malibu gateway the way
agentic coding clients use it, records the result per catalog key, and gates
promotion to `recommendable`:

  run    probe a model through the gateway and write its record
  check  verify a key's record passes for every capability it advertises
  show   print a record

Each check is a pure function of recorded HTTP responses, so the suite is
unit-tested against recorded responses (scripts/tests/test_buyer_ux_conformance.py)
and run live only after a release. The record's `capabilities` are what the
coordinator may publish on /v1/models for the model: a failed check removes its
capability (phase4-coordinator internal/buyer conformance masking).
"""
from __future__ import annotations

import argparse
import datetime as _dt
import json
import pathlib
import sys
import urllib.error
import urllib.request
from typing import Callable

ROOT = pathlib.Path(__file__).resolve().parents[1]
RECORD_PATH = ROOT / "phase3-binary" / "catalog" / "autotune" / "buyer-ux-conformance.json"
SCHEMA = "macprovider.buyer-ux-conformance.v1"
MAX_BODY_BYTES = 4 * 1024 * 1024

PASS, FAIL, UNSUPPORTED = "pass", "fail", "unsupported"

# Capability -> the checks that must pass for the model to advertise it.
CAPABILITY_CHECKS: dict[str, tuple[str, ...]] = {
    "base": ("stop_sequences", "context_limit_error", "finish_reason"),
    "tools": ("tools_auto", "stream_tool_deltas", "tool_round_trip"),
    "tool_choice_required": ("tools_required",),
    "tool_choice_named": ("tools_named",),
    "reasoning": ("no_reasoning_leak",),
    "response_format": ("json_object",),
    "messages": ("messages_beta_thinking",),
    "responses": ("responses_function_tool",),
}
ALL_CHECKS = tuple(c for checks in CAPABILITY_CHECKS.values() for c in checks)


class ConformanceError(Exception):
    pass


class Response:
    def __init__(self, status: int, body: bytes, headers: dict | None = None):
        self.status = status
        self.body = body
        self.headers = headers or {}

    def json(self) -> dict:
        value = json.loads(self.body.decode("utf-8"))
        if not isinstance(value, dict):
            raise ValueError("response is not a JSON object")
        return value

    def sse(self) -> list[dict]:
        events = []
        for line in self.body.decode("utf-8").splitlines():
            if line.startswith("data:"):
                data = line[5:].strip()
                if data and data != "[DONE]":
                    events.append(json.loads(data))
        return events


# A transport performs one request: (method, path, headers, body) -> Response.
Transport = Callable[[str, str, dict, dict | None], Response]

TOOL = {
    "type": "function",
    "function": {
        "name": "read_file",
        "description": "Read a file from disk",
        "parameters": {"type": "object", "properties": {"path": {"type": "string"}}, "required": ["path"]},
    },
}
TOOL_PROMPT = "Read the file /etc/hosts using the read_file tool."
TWO_TOOL_PROMPT = "Read both /etc/hosts and /etc/passwd with the read_file tool, one call per file."


def _chat(model: str, **fields) -> dict:
    body = {"model": model, "max_tokens": fields.pop("max_tokens", 1024)}
    body.update(fields)
    return body


def _choice(resp: Response) -> dict:
    choices = resp.json().get("choices") or []
    if len(choices) != 1 or not isinstance(choices[0], dict):
        raise ValueError("expected exactly one choice")
    return choices[0]


def _tool_calls_ok(choice: dict, name: str = "read_file") -> str | None:
    if choice.get("finish_reason") != "tool_calls":
        return f"finish_reason={choice.get('finish_reason')!r} want tool_calls"
    calls = (choice.get("message") or {}).get("tool_calls") or []
    if not calls:
        return "no tool_calls"
    ids = set()
    for call in calls:
        # A client answers each call by its id, so an absent or repeated id
        # leaves the call unusable.
        call_id = call.get("id")
        if not isinstance(call_id, str) or not call_id:
            return "tool call without an id"
        if call_id in ids:
            return "duplicate tool call ids"
        ids.add(call_id)
        if call.get("type") != "function":
            return f"tool call type {call.get('type')!r} want function"
        fn = call.get("function") or {}
        if fn.get("name") != name:
            return f"tool name {fn.get('name')!r}"
        try:
            if not isinstance(json.loads(fn.get("arguments") or ""), dict):
                return "arguments are not a JSON object"
        except ValueError:
            return "arguments are not JSON"
    return None


def _leaks_reasoning(text: str) -> bool:
    return "<think>" in text or "</think>" in text


# ---- checks: each returns (status, detail) from the responses it requests --

def check_tools(transport: Transport, model: str, choice: object, name: str) -> tuple[str, str]:
    resp = transport("POST", "/chat/completions", {}, _chat(model, messages=[{"role": "user", "content": TOOL_PROMPT}],
                                                            tools=[TOOL], tool_choice=choice))
    if resp.status == 400 and _error_code(resp) == "unsupported_tool_choice":
        return UNSUPPORTED, "tool_choice not supported for this model"
    if resp.status != 200:
        return FAIL, f"HTTP {resp.status} {_error_code(resp)}"
    problem = _tool_calls_ok(_choice(resp))
    return (FAIL, problem) if problem else (PASS, name)


def check_stream_tool_deltas(transport: Transport, model: str) -> tuple[str, str]:
    resp = transport("POST", "/chat/completions", {}, _chat(model, messages=[{"role": "user", "content": TWO_TOOL_PROMPT}],
                                                            tools=[TOOL], stream=True, stream_options={"include_usage": True}))
    if resp.status != 200:
        return FAIL, f"HTTP {resp.status}"
    calls: dict[int, dict] = {}
    finish = None
    usage = False
    # Markup split across deltas is only visible in the assembled content.
    content = ""
    for event in resp.sse():
        if "error" in event:
            return FAIL, f"stream error {event['error'].get('code')!r}"
        usage = usage or bool(event.get("usage"))
        for choice in event.get("choices") or []:
            finish = choice.get("finish_reason") or finish
            delta = choice.get("delta") or {}
            content += delta.get("content") or ""
            if _leaks_reasoning(content):
                return FAIL, "reasoning markup in streamed content"
            for tc in delta.get("tool_calls") or []:
                index = tc.get("index")
                if not isinstance(index, int) or index < 0:
                    return FAIL, "tool delta without an integer index"
                call = calls.setdefault(index, {"id": None, "name": "", "args": ""})
                if index not in calls or call["id"] is None:
                    if not tc.get("id"):
                        return FAIL, f"first delta of call {index} has no id"
                    call["id"] = tc["id"]
                fn = tc.get("function") or {}
                call["name"] += fn.get("name") or ""
                call["args"] += fn.get("arguments") or ""
    if finish != "tool_calls":
        return FAIL, f"finish_reason={finish!r} want tool_calls"
    if not calls or sorted(calls) != list(range(len(calls))):
        return FAIL, f"tool call indexes {sorted(calls)} are not 0..n-1"
    if len({c["id"] for c in calls.values()}) != len(calls):
        return FAIL, "duplicate tool call ids"
    for index, call in calls.items():
        if call["name"] != "read_file":
            return FAIL, f"call {index} name {call['name']!r}"
        try:
            json.loads(call["args"])
        except ValueError:
            return FAIL, f"call {index} arguments do not concatenate to JSON"
    if not usage:
        return FAIL, "no usage chunk"
    return PASS, f"{len(calls)} indexed call(s)"


def check_tool_round_trip(transport: Transport, model: str) -> tuple[str, str]:
    messages = [
        {"role": "user", "content": TOOL_PROMPT},
        {"role": "assistant", "content": None, "tool_calls": [{
            "id": "call_0123456789abcdef", "type": "function",
            "function": {"name": "read_file", "arguments": json.dumps({"path": "/etc/hosts"})},
        }]},
        {"role": "tool", "tool_call_id": "call_0123456789abcdef", "content": "127.0.0.1 localhost"},
    ]
    resp = transport("POST", "/chat/completions", {}, _chat(model, messages=messages, tools=[TOOL]))
    if resp.status != 200:
        return FAIL, f"HTTP {resp.status} {_error_code(resp)}"
    choice = _choice(resp)
    content = (choice.get("message") or {}).get("content") or ""
    if choice.get("finish_reason") != "stop" or not content.strip():
        return FAIL, f"finish_reason={choice.get('finish_reason')!r}, content empty={not content.strip()}"
    if _leaks_reasoning(content):
        return FAIL, "reasoning markup in content"
    return PASS, "answered from the tool result"


def check_no_reasoning_leak(transport: Transport, model: str, reasoning_model: bool) -> tuple[str, str]:
    resp = transport("POST", "/chat/completions", {}, _chat(model, messages=[{"role": "user", "content": "What is 2+2? Answer briefly."}]))
    if resp.status != 200:
        return FAIL, f"HTTP {resp.status}"
    choice = _choice(resp)
    message = choice.get("message") or {}
    content = message.get("content") or ""
    if _leaks_reasoning(content):
        return FAIL, "reasoning markup in content"
    if not content.strip():
        return FAIL, "empty content"
    if reasoning_model:
        if not (message.get("reasoning_content") or "").strip():
            return FAIL, "reasoning model returned no reasoning_content"
        details = (resp.json().get("usage") or {}).get("completion_tokens_details") or {}
        if not isinstance(details.get("reasoning_tokens"), int):
            return FAIL, "no usage.completion_tokens_details.reasoning_tokens"
    return PASS, "content separated from reasoning"


def check_json_object(transport: Transport, model: str) -> tuple[str, str]:
    resp = transport("POST", "/chat/completions", {}, _chat(model, response_format={"type": "json_object"}, messages=[
        {"role": "system", "content": "Reply only with JSON."},
        {"role": "user", "content": "Give a JSON object with key color set to blue."}]))
    if resp.status != 200:
        return FAIL, f"HTTP {resp.status} {_error_code(resp)}"
    content = (_choice(resp).get("message") or {}).get("content") or ""
    try:
        if not isinstance(json.loads(content), dict):
            return FAIL, "content is not a JSON object"
    except ValueError:
        return FAIL, "content is not JSON"
    return PASS, "valid JSON object"


def check_stop_sequences(transport: Transport, model: str) -> tuple[str, str]:
    resp = transport("POST", "/chat/completions", {}, _chat(model, stop=["7"], messages=[
        {"role": "user", "content": "Count from 1 to 10 separated by commas and nothing else."}]))
    if resp.status != 200:
        return FAIL, f"HTTP {resp.status}"
    choice = _choice(resp)
    content = (choice.get("message") or {}).get("content") or ""
    if "7" in content or "8" in content:
        return FAIL, "text continued past the stop sequence"
    if "6" not in content:
        return FAIL, "stop matched before the answer (inside reasoning?)"
    if choice.get("finish_reason") != "stop":
        return FAIL, f"finish_reason={choice.get('finish_reason')!r}"
    return PASS, "stopped at the stop sequence"


def check_messages(transport: Transport, model: str, reasoning_model: bool) -> tuple[str, str]:
    headers = {"anthropic-version": "2023-06-01", "anthropic-beta": "interleaved-thinking-2025-05-14"}
    resp = transport("POST", "/messages", headers, {
        "model": model, "max_tokens": 2048, "thinking": {"type": "enabled", "budget_tokens": 1024},
        "messages": [{"role": "user", "content": "What is 2+2? Answer briefly."}],
    })
    if resp.status != 200:
        return FAIL, f"HTTP {resp.status} {_error_code(resp)}"
    body = resp.json()
    blocks = body.get("content") or []
    kinds = [b.get("type") for b in blocks]
    if "text" not in kinds or body.get("type") != "message":
        return FAIL, f"content blocks {kinds}"
    if any(_leaks_reasoning(b.get("text") or "") for b in blocks):
        return FAIL, "reasoning markup in a text block"
    if reasoning_model and kinds[0] != "thinking":
        return FAIL, "reasoning model returned no leading thinking block"
    return PASS, f"blocks {kinds}"


def check_responses(transport: Transport, model: str) -> tuple[str, str]:
    tool = dict(TOOL["function"], type="function")
    resp = transport("POST", "/responses", {}, {"model": model, "input": TOOL_PROMPT, "tools": [tool],
                                                "max_output_tokens": 1024, "store": False})
    if resp.status != 200:
        return FAIL, f"HTTP {resp.status} {_error_code(resp)}"
    output = resp.json().get("output") or []
    calls = [item for item in output if item.get("type") == "function_call" and item.get("name") == "read_file"]
    if not calls or not calls[0].get("call_id"):
        return FAIL, f"no function_call item in {[i.get('type') for i in output]}"
    return PASS, "function_call item"


def check_context_limit_error(transport: Transport, model: str, context_tokens: int) -> tuple[str, str]:
    filler = "lorem ipsum " * max(1, (context_tokens * 2))
    resp = transport("POST", "/chat/completions", {}, _chat(model, max_tokens=16, messages=[{"role": "user", "content": filler}]))
    if not 400 <= resp.status < 500:
        return FAIL, f"HTTP {resp.status} want a 4xx"
    code = _error_code(resp)
    message = ((resp.json().get("error") or {}).get("message") or "") if resp.body else ""
    if not code or not message or "Traceback" in message or len(message) > 1024:
        return FAIL, f"unreadable error code={code!r}"
    return PASS, code


def check_finish_reason(transport: Transport, model: str) -> tuple[str, str]:
    resp = transport("POST", "/chat/completions", {}, _chat(model, max_tokens=8, messages=[
        {"role": "user", "content": "Write a long story about the sea."}]))
    if resp.status != 200:
        return FAIL, f"HTTP {resp.status}"
    if _choice(resp).get("finish_reason") != "length":
        return FAIL, f"finish_reason={_choice(resp).get('finish_reason')!r} want length at max_tokens"
    return PASS, "length at max_tokens"


def _error_code(resp: Response) -> str:
    try:
        error = resp.json().get("error") or {}
        return error.get("code") or "" if isinstance(error, dict) else ""
    except ValueError:
        return ""


def model_entry(transport: Transport, model: str) -> dict:
    resp = transport("GET", "/models", {}, None)
    if resp.status != 200:
        raise ConformanceError(f"/models returned HTTP {resp.status}")
    for row in resp.json().get("data") or []:
        if row.get("id") == model:
            return row
    raise ConformanceError(f"model {model!r} is not served by the gateway")


def run_checks(transport: Transport, model: str) -> dict:
    entry = model_entry(transport, model)
    advertised = entry.get("capabilities") or {}
    # Whether reasoning fields must be proven comes from the canonical model
    # contract, never from /models: a masked or absent flag there must not
    # waive the proof of the capability the record grants.
    reasoning_model = advertised_capabilities(model)["reasoning"]
    context = int(entry.get("max_context_tokens") or advertised.get("context_length") or 32768)
    steps: dict[str, Callable[[], tuple[str, str]]] = {
        "tools_auto": lambda: check_tools(transport, model, "auto", "auto"),
        "tools_required": lambda: check_tools(transport, model, "required", "required"),
        "tools_named": lambda: check_tools(transport, model, {"type": "function", "function": {"name": "read_file"}}, "named"),
        "stream_tool_deltas": lambda: check_stream_tool_deltas(transport, model),
        "tool_round_trip": lambda: check_tool_round_trip(transport, model),
        "no_reasoning_leak": lambda: check_no_reasoning_leak(transport, model, reasoning_model),
        "json_object": lambda: check_json_object(transport, model),
        "stop_sequences": lambda: check_stop_sequences(transport, model),
        "messages_beta_thinking": lambda: check_messages(transport, model, reasoning_model),
        "responses_function_tool": lambda: check_responses(transport, model),
        "context_limit_error": lambda: check_context_limit_error(transport, model, context),
        "finish_reason": lambda: check_finish_reason(transport, model),
    }
    checks = {}
    for name, step in steps.items():
        try:
            status, detail = step()
        except (ValueError, KeyError, TypeError, ConformanceError) as exc:
            status, detail = FAIL, f"malformed response: {type(exc).__name__}"
        checks[name] = {"status": status, "detail": detail[:200]}
    return {"model": model, "checks": checks, "capabilities": capabilities_from_checks(checks)}


def capabilities_from_checks(checks: dict) -> dict:
    """What the model may advertise: a capability whose checks all passed."""
    def passed(capability: str) -> bool:
        return all((checks.get(c) or {}).get("status") == PASS for c in CAPABILITY_CHECKS[capability])
    tools = passed("tools")
    modes = ["auto", "none"] if tools else []
    if tools and passed("tool_choice_required"):
        modes.append("required")
    if tools and passed("tool_choice_named"):
        modes.append("named")
    return {
        "base": passed("base"),
        "tools": tools,
        "tool_choice": modes,
        "reasoning": passed("reasoning"),
        "response_format": passed("response_format"),
        "messages": passed("messages"),
        "responses": passed("responses"),
    }


def load_records(path: pathlib.Path = RECORD_PATH) -> dict:
    if not path.exists():
        return {"schema_version": SCHEMA, "records": {}}
    value = json.loads(path.read_text(encoding="utf-8"))
    if not isinstance(value, dict) or value.get("schema_version") != SCHEMA or not isinstance(value.get("records"), dict):
        raise ConformanceError(f"{path.name}: schema_version must be {SCHEMA} with a records object")
    for key, record in value["records"].items():
        validate_record(record, f"{path.name} records[{key!r}]")
    return value


def validate_record(record: object, label: str) -> None:
    if not isinstance(record, dict):
        raise ConformanceError(f"{label} must be an object")
    for field in ("model", "gateway", "checked_at", "checks", "capabilities"):
        if field not in record:
            raise ConformanceError(f"{label}.{field} is required")
    checks = record["checks"]
    if not isinstance(checks, dict) or set(checks) != set(ALL_CHECKS):
        raise ConformanceError(f"{label}.checks must hold exactly {sorted(ALL_CHECKS)}")
    for name, result in checks.items():
        if not isinstance(result, dict) or result.get("status") not in (PASS, FAIL, UNSUPPORTED):
            raise ConformanceError(f"{label}.checks[{name!r}].status must be pass, fail or unsupported")
    if record["capabilities"] != capabilities_from_checks(checks):
        raise ConformanceError(f"{label}.capabilities must be derived from its checks")


# Mirrors toolGrammarFamily / reasoningFamily (phase4-coordinator
# internal/buyer) and ToolSelectionPolicy.guaranteedCallProfiles (Swift).
GUARANTEED_SELECTION_MODELS = {
    "mlx-community/qwen3.6-35b-a3b-4bit",
    "mlx-community/qwen3-coder-30b-a3b-instruct-4bit",
    "mlx-community/qwen3-30b-a3b-instruct-2507-4bit",
}


def tool_grammar_family(model: str) -> str:
    m = model.lower()
    if "qwen2-vl" in m or "qwen2vl" in m:
        return ""
    if "qwen2.5" in m or "qwen3" in m:
        return "qwen"
    if "gpt-oss" in m:
        return "harmony"
    if any(f in m for f in ("glm-4.5", "glm-4.6", "glm-4.7", "glm-5")):
        return "glm"
    if any(f in m for f in ("llama-3.1", "llama-3.2", "llama-3.3", "llama3.1", "llama3.2", "llama3.3")):
        return "llama3"
    if "gemma-4" in m or "gemma4" in m:
        return "gemma4"
    if "nemotron-3" in m or "nemotron3" in m:
        return "qwen"
    if "deepseek-v4" in m or "deepseek_v4" in m:
        return "dsml"
    return ""


def advertised_capabilities(model_id: str) -> dict:
    """The capabilities /v1/models derives for a served model id."""
    tools = tool_grammar_family(model_id) != ""
    modes = ["auto", "none"] if tools else []
    if tools and model_id.lower() in GUARANTEED_SELECTION_MODELS:
        modes += ["required", "named"]
    m = model_id.lower()
    return {
        "tools": tools,
        "tool_choice": modes,
        "reasoning": "glm-5" in m or "gpt-oss" in m or "deepseek-v4" in m,
        "response_format": True,
        "messages": True,
        "responses": True,
    }


def require_promotable(key: str, model_id: str, advertised: dict, path: pathlib.Path = RECORD_PATH) -> dict:
    """SPEC-023 §16.11: a key is promotable only when its record exists, was
    taken against the served model being promoted, its base checks pass, and
    every capability the model advertises passes."""
    records = load_records(path)["records"]
    record = records.get(key)
    if record is None:
        raise ConformanceError(f"buyer-UX conformance: no record for {key!r}; run scripts/buyer_ux_conformance.py run")
    # The coordinator indexes the record by its model id, case-insensitively
    # (LoadBuyerUXConformance), so the gate binds the same identity.
    if str(record["model"]).lower() != model_id.lower():
        raise ConformanceError(f"buyer-UX conformance: {key!r} record is for {record['model']!r}, not the served model {model_id!r}")
    caps = record["capabilities"]
    if not caps["base"]:
        raise ConformanceError(f"buyer-UX conformance: {key!r} fails the base checks")
    for capability in ("tools", "reasoning", "response_format", "messages", "responses"):
        if advertised.get(capability) and not caps[capability]:
            raise ConformanceError(f"buyer-UX conformance: {key!r} advertises {capability} but its checks failed")
    missing = set(advertised.get("tool_choice") or []) - set(caps["tool_choice"])
    if missing:
        raise ConformanceError(f"buyer-UX conformance: {key!r} advertises tool_choice {sorted(missing)} that failed")
    return record


def http_transport(gateway: str, key: str, timeout: float = 240.0) -> Transport:
    base = gateway.rstrip("/")

    def send(method: str, path: str, headers: dict, body: dict | None) -> Response:
        data = None if body is None else json.dumps(body).encode()
        request = urllib.request.Request(base + path, data=data, method=method)
        request.add_header("Authorization", "Bearer " + key)
        request.add_header("Content-Type", "application/json")
        for name, value in headers.items():
            request.add_header(name, value)
        try:
            with urllib.request.urlopen(request, timeout=timeout) as resp:  # noqa: S310 (fixed HTTPS gateway)
                return Response(resp.status, resp.read(MAX_BODY_BYTES), dict(resp.headers))
        except urllib.error.HTTPError as err:
            return Response(err.code, err.read(MAX_BODY_BYTES), dict(err.headers or {}))
    return send


def cmd_run(args: argparse.Namespace) -> int:
    if not args.gateway.startswith("https://"):
        print("--gateway must be an https URL", file=sys.stderr)
        return 2
    key = pathlib.Path(args.key_file).expanduser().read_text(encoding="utf-8").strip()
    result = run_checks(http_transport(args.gateway, key), args.model)
    record = {
        "model": args.model,
        "gateway": args.gateway,
        "checked_at": _dt.datetime.now(_dt.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ"),
        "checks": result["checks"],
        "capabilities": result["capabilities"],
    }
    path = pathlib.Path(args.record)
    doc = load_records(path)
    doc["records"][args.catalog_key] = record
    path.write_text(json.dumps(doc, indent=2, sort_keys=True) + "\n", encoding="utf-8")
    failed = [name for name, check in result["checks"].items() if check["status"] == FAIL]
    print(json.dumps({"catalog_key": args.catalog_key, "capabilities": result["capabilities"], "failed": failed}, sort_keys=True))
    return 0 if not failed else 1


def cmd_check(args: argparse.Namespace) -> int:
    model_id = args.model_id or args.catalog_key
    advertised = json.loads(args.advertised) if args.advertised else advertised_capabilities(model_id)
    try:
        require_promotable(args.catalog_key, model_id, advertised, pathlib.Path(args.record))
    except ConformanceError as err:
        print(str(err), file=sys.stderr)
        return 1
    print(f"{args.catalog_key}: buyer-UX conformance passes")
    return 0


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__.split("\n\n")[0])
    sub = parser.add_subparsers(dest="command", required=True)
    run = sub.add_parser("run", help="probe a served model through the gateway and record the result")
    run.add_argument("--gateway", default="https://api.malibu.tech/v1")
    run.add_argument("--key-file", required=True)
    run.add_argument("--model", required=True, help="the model id as /v1/models lists it")
    run.add_argument("--catalog-key", required=True)
    run.add_argument("--record", default=str(RECORD_PATH))
    check = sub.add_parser("check", help="gate: the key's record passes for every advertised capability")
    check.add_argument("--catalog-key", required=True)
    check.add_argument("--model-id", help="served model id; the advertised capabilities are derived from it")
    check.add_argument("--advertised", help="JSON capability object overriding the derived one")
    check.add_argument("--record", default=str(RECORD_PATH))
    show = sub.add_parser("show")
    show.add_argument("--catalog-key", required=True)
    show.add_argument("--record", default=str(RECORD_PATH))
    args = parser.parse_args(argv)
    if args.command == "run":
        return cmd_run(args)
    if args.command == "check":
        return cmd_check(args)
    print(json.dumps(load_records(pathlib.Path(args.record))["records"].get(args.catalog_key), indent=2, sort_keys=True))
    return 0


if __name__ == "__main__":
    sys.exit(main())
