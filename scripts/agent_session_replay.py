#!/usr/bin/env python3
"""Replay a recorded Codex coding-agent session against an OpenAI-compatible
endpoint and gate it on long-session latency and cache-reuse SLOs.

Short tool/turn tests miss defects that only appear in long sessions: a gateway
idle cut when another session's prefill stalls decode, and a provider
conversation cache that stops capturing past a context size. This harness
rebuilds the exact per-request input sequence a Codex rollout recorded and
replays it with streaming, optionally as several staggered concurrent copies
and with a concurrent long-prompt aggressor per turn.

Input: a Codex rollout JSONL (CODEX_HOME/sessions/**/rollout-*.jsonl).
Output: one JSONL record per request plus summary.json; exit 1 on any SLO
breach, 2 on usage or input errors. Stdlib only, noninteractive.

Runbook: docs/runbooks/long-agent-session-gate.md
"""

from __future__ import annotations

import argparse
import copy
import json
import random
import statistics
import sys
import threading
import time
import urllib.error
import urllib.request
from pathlib import Path
from typing import Any

OUTPUT_ITEM_TYPES = {"reasoning", "function_call", "custom_tool_call", "local_shell_call"}
INPUT_ITEM_TYPES = {"function_call_output", "custom_tool_call_output", "local_shell_call_output"}
# Rollout bookkeeping keys Codex never sends on the wire.
INTERNAL_ITEM_KEYS = {"internal_chat_message_metadata_passthrough"}
CONTEXT_BUCKETS = (("32k", 32_768), ("64k", 65_536), ("100k", 102_400), ("128k", 131_072))
TOKEN_DELTA_EVENTS = {
    "response.output_text.delta",
    "response.reasoning_text.delta",
    "response.reasoning_summary_text.delta",
    "response.function_call_arguments.delta",
    "response.custom_tool_call_input.delta",
}

# Used only when the rollout carries no tool definitions (most exec rollouts do
# not). Shapes follow Codex's public exec_command / write_stdin tools; pass
# --tools-file with a captured tools array for byte-exact prefixes.
DEFAULT_TOOL_SCHEMAS: dict[str, dict[str, Any]] = {
    "exec_command": {
        "type": "function",
        "name": "exec_command",
        "description": "Runs a command in a PTY, returning output or a session ID for ongoing interaction.",
        "strict": False,
        "parameters": {
            "type": "object",
            "properties": {
                "cmd": {"type": "string", "description": "Shell command to execute."},
                "workdir": {"type": "string", "description": "Optional working directory."},
                "shell": {"type": "string", "description": "Shell binary to launch."},
                "login": {"type": "boolean", "description": "Whether to run the shell with -l/-i semantics."},
                "tty": {"type": "boolean", "description": "Whether to allocate a TTY."},
                "yield_time_ms": {"type": "number", "description": "How long to wait for output before yielding."},
                "max_output_tokens": {"type": "number", "description": "Maximum number of tokens to return."},
            },
            "required": ["cmd"],
            "additionalProperties": False,
        },
    },
    "write_stdin": {
        "type": "function",
        "name": "write_stdin",
        "description": "Writes characters to an existing unified exec session and returns recent output.",
        "strict": False,
        "parameters": {
            "type": "object",
            "properties": {
                "session_id": {"type": "number", "description": "Identifier of the running unified exec session."},
                "chars": {"type": "string", "description": "Bytes to write to stdin."},
                "yield_time_ms": {"type": "number", "description": "How long to wait for output before yielding."},
                "max_output_tokens": {"type": "number", "description": "Maximum number of tokens to return."},
            },
            "required": ["session_id"],
            "additionalProperties": False,
        },
    },
}


class RolloutError(ValueError):
    pass


# ---------------------------------------------------------------- rollout parse


def _clean_item(item: dict[str, Any]) -> dict[str, Any]:
    out = {k: v for k, v in item.items() if k not in INTERNAL_ITEM_KEYS}
    if out.get("type") == "reasoning" and out.get("encrypted_content") is None:
        out.pop("encrypted_content", None)
    return out


def _is_output_item(item: dict[str, Any]) -> bool:
    kind = item.get("type")
    if kind in OUTPUT_ITEM_TYPES:
        return True
    return kind == "message" and item.get("role") == "assistant"


def parse_rollout(path: str | Path) -> dict[str, Any]:
    """Rebuild every model request a Codex rollout recorded.

    A request's input is the conversation history (minus the instructions,
    which travel separately) immediately before its first output item. Output
    items (reasoning, assistant message, tool calls) join the history; the
    token_usage_record that follows closes the request with its source usage.
    A `compacted` record replaces the history with its replacement_history.
    """
    meta: dict[str, Any] = {
        "session_id": None,
        "model": None,
        "effort": None,
        "instructions": "",
        "tools": None,
        "tool_names": [],
        "compactions": 0,
    }
    history: list[dict[str, Any]] = []
    requests: list[dict[str, Any]] = []
    in_output = False
    after_compaction = False
    tool_names: list[str] = []
    try:
        lines = Path(path).read_text(encoding="utf-8").splitlines()
    except OSError as exc:
        raise RolloutError(f"cannot read rollout: {exc}") from exc
    for lineno, line in enumerate(lines, 1):
        if not line.strip():
            continue
        try:
            record = json.loads(line)
        except json.JSONDecodeError as exc:
            raise RolloutError(f"line {lineno}: invalid JSON: {exc}") from exc
        kind = record.get("type")
        payload = record.get("payload") or {}
        if kind == "session_meta":
            meta["session_id"] = payload.get("session_id") or payload.get("id")
            base = payload.get("base_instructions")
            if isinstance(base, dict):
                base = base.get("text")
            if isinstance(base, str):
                meta["instructions"] = base
        elif kind == "turn_context":
            meta["model"] = payload.get("model") or meta["model"]
            settings = (payload.get("collaboration_mode") or {}).get("settings") or {}
            meta["effort"] = payload.get("effort") or settings.get("reasoning_effort") or meta["effort"]
        elif kind == "compacted":
            replacement = payload.get("replacement_history")
            if isinstance(replacement, list):
                history = [_clean_item(i) for i in replacement if isinstance(i, dict) and i.get("type") != "additional_tools"]
                meta["compactions"] += 1
                after_compaction = True
                in_output = False
        elif kind == "token_usage_record":
            usage = payload.get("usage") or {}
            for req in reversed(requests):
                if req["source_usage"] is None:
                    req["source_usage"] = {
                        "input_tokens": usage.get("input_tokens"),
                        "cached_input_tokens": usage.get("cached_input_tokens"),
                        "output_tokens": usage.get("output_tokens"),
                    }
                    break
            in_output = False
        elif kind == "response_item":
            if payload.get("type") == "additional_tools":
                if isinstance(payload.get("tools"), list):
                    meta["tools"] = payload["tools"]
                continue
            item = _clean_item(payload)
            if _is_output_item(item):
                if not in_output:
                    requests.append(
                        {
                            "index": len(requests),
                            "input": list(history),
                            "post_compaction": after_compaction,
                            "source_usage": None,
                        }
                    )
                    after_compaction = False
                    in_output = True
                if item.get("type") in ("function_call", "custom_tool_call"):
                    name = item.get("name")
                    if isinstance(name, str) and name not in tool_names:
                        tool_names.append(name)
            else:
                in_output = False
            history.append(item)
    if not requests:
        raise RolloutError("rollout contains no model requests (no assistant/reasoning/tool-call items)")
    meta["tool_names"] = tool_names
    if meta["tools"] is None:
        meta["tools"] = [
            DEFAULT_TOOL_SCHEMAS.get(
                name,
                {"type": "function", "name": name, "description": "", "parameters": {"type": "object", "additionalProperties": True}},
            )
            for name in tool_names
        ]
        meta["tools_source"] = "synthesized"
    else:
        meta["tools_source"] = "rollout"
    meta["requests"] = requests
    return meta


def estimate_tokens(obj: Any) -> int:
    text = obj if isinstance(obj, str) else json.dumps(obj, ensure_ascii=False)
    return max(1, len(text) // 4)


def request_context_tokens(req: dict[str, Any], instructions: str) -> int:
    usage = req.get("source_usage") or {}
    if isinstance(usage.get("input_tokens"), int) and usage["input_tokens"] > 0:
        return usage["input_tokens"]
    return estimate_tokens(instructions) + estimate_tokens(req["input"])


def parse_token_count(text: str) -> int:
    raw = text.strip().lower()
    mult = 1
    if raw.endswith("k"):
        mult, raw = 1024, raw[:-1]
    try:
        value = int(float(raw) * mult)
    except ValueError as exc:
        raise argparse.ArgumentTypeError(f"invalid token count: {text}") from exc
    if value <= 0:
        raise argparse.ArgumentTypeError(f"token count must be positive: {text}")
    return value


# ------------------------------------------------------------- body builders


def _with_nonce(items: list[dict[str, Any]], nonce: str) -> list[dict[str, Any]]:
    """Tag the first user message so copies (and reruns) are distinct
    conversations: only the static prefix before it may be shared, as with
    real independent sessions."""
    items = copy.deepcopy(items)
    for item in items:
        if item.get("type") == "message" and item.get("role") == "user":
            content = item.get("content")
            tag = f"\n<replay_session nonce=\"{nonce}\"/>"
            if isinstance(content, str):
                item["content"] = content + tag
            elif isinstance(content, list) and content:
                last = content[-1]
                if isinstance(last, dict) and isinstance(last.get("text"), str):
                    last["text"] += tag
                else:
                    content.append({"type": "input_text", "text": tag})
            break
    return items


def build_responses_body(meta: dict[str, Any], items: list[dict[str, Any]], model: str, cache_key: str) -> dict[str, Any]:
    body: dict[str, Any] = {
        "model": model,
        "instructions": meta["instructions"],
        "input": items,
        "tools": meta["tools"],
        "tool_choice": "auto",
        "parallel_tool_calls": False,
        "store": False,
        "stream": True,
        "prompt_cache_key": cache_key,
    }
    if meta.get("effort"):
        body["reasoning"] = {"effort": meta["effort"]}
    if not body["tools"]:
        body.pop("tools")
        body.pop("tool_choice")
        body.pop("parallel_tool_calls")
    return body


def _content_text(content: Any) -> str:
    if isinstance(content, str):
        return content
    if isinstance(content, list):
        return "".join(p.get("text", "") for p in content if isinstance(p, dict))
    return ""


def _chat_tools(tools: list[dict[str, Any]]) -> list[dict[str, Any]]:
    out: list[dict[str, Any]] = []

    def add(tool: dict[str, Any]) -> None:
        if tool.get("type") == "custom":
            params = {"type": "object", "properties": {"input": {"type": "string"}}, "required": ["input"]}
        else:
            params = tool.get("parameters") or {"type": "object"}
        out.append(
            {"type": "function", "function": {"name": tool.get("name"), "description": tool.get("description", ""), "parameters": params}}
        )

    for tool in tools:
        if tool.get("type") == "namespace":
            for nested in tool.get("tools") or []:
                if nested.get("type") in ("function", "custom"):
                    add(nested)
        elif tool.get("type") in ("function", "custom"):
            add(tool)
    return out


def items_to_chat_messages(instructions: str, items: list[dict[str, Any]]) -> list[dict[str, Any]]:
    messages: list[dict[str, Any]] = []
    if instructions:
        messages.append({"role": "system", "content": instructions})
    reasoning: list[str] = []
    assistant: dict[str, Any] | None = None

    def flush() -> None:
        nonlocal assistant
        if assistant is not None:
            messages.append(assistant)
            assistant = None

    def open_assistant() -> dict[str, Any]:
        nonlocal assistant, reasoning
        if assistant is None:
            assistant = {"role": "assistant", "content": None}
            if reasoning:
                assistant["reasoning_content"] = "\n".join(reasoning)
                reasoning = []
        return assistant

    for item in items:
        kind = item.get("type")
        if kind == "reasoning":
            flush()
            text = "".join(_content_text([c]) for c in item.get("content") or [] if isinstance(c, dict))
            if not text:
                text = "".join(_content_text([c]) for c in item.get("summary") or [] if isinstance(c, dict))
            if text:
                reasoning.append(text)
        elif kind == "message" and item.get("role") == "assistant":
            msg = open_assistant()
            msg["content"] = (msg["content"] or "") + _content_text(item.get("content"))
        elif kind in ("function_call", "custom_tool_call"):
            msg = open_assistant()
            args = item.get("arguments") if kind == "function_call" else json.dumps({"input": item.get("input", "")})
            msg.setdefault("tool_calls", []).append(
                {"id": item.get("call_id") or item.get("id"), "type": "function", "function": {"name": item.get("name"), "arguments": args or ""}}
            )
        elif kind in INPUT_ITEM_TYPES:
            flush()
            messages.append({"role": "tool", "tool_call_id": item.get("call_id") or item.get("id"), "content": _content_text(item.get("output"))})
        elif kind == "message":
            flush()
            role = item.get("role")
            messages.append({"role": "system" if role == "developer" else role, "content": _content_text(item.get("content"))})
    flush()
    return messages


def build_chat_body(meta: dict[str, Any], items: list[dict[str, Any]], model: str, cache_key: str) -> dict[str, Any]:
    body: dict[str, Any] = {
        "model": model,
        "messages": items_to_chat_messages(meta["instructions"], items),
        "stream": True,
        "stream_options": {"include_usage": True},
        "prompt_cache_key": cache_key,
    }
    tools = _chat_tools(meta["tools"] or [])
    if tools:
        body["tools"] = tools
        body["tool_choice"] = "auto"
        body["parallel_tool_calls"] = False
    if meta.get("effort"):
        body["reasoning_effort"] = meta["effort"]
    return body


def aggressor_text(tokens: int, rng: random.Random) -> str:
    # ~4 chars per token; random words defeat every prefix cache.
    words = []
    total = 0
    while total < tokens * 4:
        word = "".join(rng.choice("abcdefghijklmnopqrstuvwxyz") for _ in range(rng.randint(3, 9)))
        words.append(word)
        total += len(word) + 1
    return " ".join(words)


# --------------------------------------------------------------- streaming


def stream_request(url: str, body: dict[str, Any], api_key: str | None, timeout: float, api: str, on_first_token=None) -> dict[str, Any]:
    """POST one streaming request and measure it. Never raises for HTTP or
    stream failures; they are recorded on the result."""
    data = json.dumps(body).encode("utf-8")
    headers = {"Content-Type": "application/json", "Accept": "text/event-stream"}
    if api_key:
        headers["Authorization"] = f"Bearer {api_key}"
    req = urllib.request.Request(url, data=data, headers=headers, method="POST")
    result: dict[str, Any] = {
        "http_status": None,
        "ttft_s": None,
        "max_gap_s": None,
        "decode_tps": None,
        "prompt_tokens": None,
        "cached_tokens": None,
        "output_tokens": None,
        "token_events": 0,
        "completed": False,
        "cut": False,
        "error": None,
    }
    start = time.monotonic()
    first = last = None
    max_gap = 0.0
    try:
        resp = urllib.request.urlopen(req, timeout=timeout)
    except urllib.error.HTTPError as exc:
        result["http_status"] = exc.code
        try:
            result["error"] = exc.read(400).decode("utf-8", "replace")
        except Exception:  # noqa: BLE001 - body is diagnostic only
            result["error"] = str(exc)
        finally:
            exc.close()
        return result
    except (urllib.error.URLError, OSError) as exc:
        result["error"] = f"connect: {exc}"
        result["cut"] = True
        return result
    result["http_status"] = resp.status
    try:
        with resp:
            for raw in resp:
                line = raw.decode("utf-8", "replace").strip()
                if not line.startswith("data:"):
                    continue
                payload = line[5:].strip()
                if payload == "[DONE]":
                    if api == "chat" and result["error"] is None:
                        result["completed"] = True
                    break
                try:
                    event = json.loads(payload)
                except json.JSONDecodeError:
                    continue
                now = time.monotonic()
                is_token = False
                usage = None
                if api == "responses":
                    etype = event.get("type")
                    if etype in TOKEN_DELTA_EVENTS:
                        is_token = True
                    elif etype == "response.completed":
                        result["completed"] = True
                        usage = (event.get("response") or {}).get("usage")
                    elif etype in ("response.failed", "response.incomplete", "error"):
                        err = (event.get("response") or {}).get("error") or event.get("error") or event
                        result["error"] = json.dumps(err)[:400]
                    elif "error" in event and isinstance(event["error"], dict):
                        result["error"] = json.dumps(event["error"])[:400]
                    if usage:
                        result["prompt_tokens"] = usage.get("input_tokens")
                        result["cached_tokens"] = (usage.get("input_tokens_details") or {}).get("cached_tokens")
                        result["output_tokens"] = usage.get("output_tokens")
                else:
                    if isinstance(event.get("error"), dict):
                        result["error"] = json.dumps(event["error"])[:400]
                    for choice in event.get("choices") or []:
                        delta = choice.get("delta") or {}
                        if delta.get("content") or delta.get("reasoning_content") or delta.get("reasoning") or delta.get("tool_calls"):
                            is_token = True
                    usage = event.get("usage")
                    if usage:
                        result["prompt_tokens"] = usage.get("prompt_tokens")
                        result["cached_tokens"] = (usage.get("prompt_tokens_details") or {}).get("cached_tokens")
                        result["output_tokens"] = usage.get("completion_tokens")
                if is_token:
                    result["token_events"] += 1
                    if first is None:
                        first = now
                        result["ttft_s"] = round(now - start, 3)
                        if on_first_token:
                            on_first_token()
                    else:
                        max_gap = max(max_gap, now - last)
                    last = now
    except (OSError, ValueError) as exc:
        result["error"] = f"stream: {exc}"
    if result["error"] is not None or not result["completed"]:
        result["completed"] = False
        result["cut"] = True
    if first is not None:
        result["max_gap_s"] = round(max_gap, 3)
        span = last - first
        produced = result["output_tokens"] or result["token_events"]
        if span > 0 and produced:
            result["decode_tps"] = round(produced / span, 2)
    result["wall_s"] = round(time.monotonic() - start, 3)
    return result


# -------------------------------------------------------------------- SLOs


def is_failure(attempt: dict[str, Any]) -> bool:
    status = attempt.get("http_status")
    return bool(attempt.get("cut")) or status is None or status >= 400


def evaluate_turn(rec: dict[str, Any], args: argparse.Namespace) -> list[str]:
    breaches: list[str] = []
    for att in rec["attempts"]:
        status = att.get("http_status")
        if status == 429:
            breaches.append("http_429")
        elif status is not None and status >= 500:
            breaches.append("http_5xx")
        elif status is not None and status >= 400:
            breaches.append(f"http_{status}")
        elif att.get("cut"):
            breaches.append("stream_cut")
    if rec["role"] != "session":
        return breaches
    final = rec["attempts"][-1]
    if is_failure(final):
        return breaches
    gap = final.get("max_gap_s")
    if gap is not None and gap >= args.idle_limit_seconds:
        breaches.append("token_gap")
    prompt, cached = final.get("prompt_tokens"), final.get("cached_tokens")
    if not isinstance(prompt, int) or prompt <= 0:
        breaches.append("usage_missing")
        return breaches
    cached = cached if isinstance(cached, int) else 0
    if rec["turn"] > 0 and not rec["post_compaction"] and cached / prompt < args.min_cache_ratio:
        breaches.append("cache_ratio")
    ttft = final.get("ttft_s")
    bound = args.ttft_base_seconds + max(0, prompt - cached) / args.prefill_tokens_per_second
    rec["ttft_bound_s"] = round(bound, 3)
    if ttft is None or ttft > bound:
        breaches.append("ttft")
    return breaches


def context_bucket(tokens: int | None) -> str:
    if not isinstance(tokens, int):
        return "unknown"
    for name, limit in CONTEXT_BUCKETS:
        if tokens <= limit:
            return name
    return ">128k"


def summarize(records: list[dict[str, Any]], args: argparse.Namespace, meta: dict[str, Any]) -> dict[str, Any]:
    counts = {"stream_cut": 0, "http_429": 0, "http_5xx": 0, "retries": 0}
    buckets: dict[str, dict[str, Any]] = {}
    breaches = []
    for rec in records:
        for att in rec["attempts"]:
            status = att.get("http_status")
            if status == 429:
                counts["http_429"] += 1
            elif status is not None and status >= 500:
                counts["http_5xx"] += 1
            elif att.get("cut"):
                counts["stream_cut"] += 1
        counts["retries"] += len(rec["attempts"]) - 1
        for kind in rec["breaches"]:
            breaches.append({"role": rec["role"], "session": rec["session"], "turn": rec["turn"], "breach": kind})
        if rec["role"] != "session":
            continue
        final = rec["attempts"][-1]
        b = buckets.setdefault(context_bucket(final.get("prompt_tokens") or rec["source_context_tokens"]), {"turns": 0, "cache_ratios": [], "max_gap_s": 0.0, "ttft_s": [], "decode_tps": []})
        b["turns"] += 1
        if rec.get("cache_ratio") is not None and rec["turn"] > 0 and not rec["post_compaction"]:
            b["cache_ratios"].append(rec["cache_ratio"])
        if final.get("max_gap_s") is not None:
            b["max_gap_s"] = max(b["max_gap_s"], final["max_gap_s"])
        if final.get("ttft_s") is not None:
            b["ttft_s"].append(final["ttft_s"])
        if final.get("decode_tps") is not None:
            b["decode_tps"].append(final["decode_tps"])
    by_context = {}
    for name, b in buckets.items():
        by_context[name] = {
            "turns": b["turns"],
            "min_cache_ratio": round(min(b["cache_ratios"]), 4) if b["cache_ratios"] else None,
            "max_gap_s": round(b["max_gap_s"], 3),
            "ttft_p50_s": round(statistics.median(b["ttft_s"]), 3) if b["ttft_s"] else None,
            "ttft_max_s": round(max(b["ttft_s"]), 3) if b["ttft_s"] else None,
            "decode_tps_p50": round(statistics.median(b["decode_tps"]), 2) if b["decode_tps"] else None,
        }
    breach_counts: dict[str, int] = {}
    for b in breaches:
        breach_counts[b["breach"]] = breach_counts.get(b["breach"], 0) + 1
    return {
        "pass": not breaches,
        "source_session_id": meta.get("session_id"),
        "model": args.model or meta.get("model"),
        "api": args.api,
        "sessions": args.sessions,
        "aggressor_prefill_tokens": args.aggressor_prefill_tokens,
        "max_context": args.max_context,
        "requests_replayed": sum(1 for r in records if r["role"] == "session"),
        "aggressor_requests": sum(1 for r in records if r["role"] == "aggressor"),
        "slo": {
            "min_cache_ratio": args.min_cache_ratio,
            "idle_limit_seconds": args.idle_limit_seconds,
            "ttft_base_seconds": args.ttft_base_seconds,
            "prefill_tokens_per_second": args.prefill_tokens_per_second,
        },
        "counts": counts,
        "breach_counts": breach_counts,
        "breaches": breaches[:100],
        "by_context": by_context,
    }


# ------------------------------------------------------------------ runner


class Replay:
    def __init__(self, meta: dict[str, Any], requests: list[dict[str, Any]], args: argparse.Namespace, api_key: str | None):
        self.meta = meta
        self.requests = requests
        self.args = args
        self.api_key = api_key
        self.lock = threading.Lock()
        self.records: list[dict[str, Any]] = []
        self.run_id = f"{int(time.time())}-{random.randrange(1 << 30):08x}"
        self.url = args.base_url.rstrip("/") + ("/responses" if args.api == "responses" else "/chat/completions")
        self.model = args.model or meta.get("model")
        self.agg_threads: list[threading.Thread] = []
        self.out_handle = None

    def _body(self, items: list[dict[str, Any]], cache_key: str) -> dict[str, Any]:
        if self.args.api == "responses":
            return build_responses_body(self.meta, items, self.model, cache_key)
        return build_chat_body(self.meta, items, self.model, cache_key)

    def _send(self, body: dict[str, Any], on_first_token=None) -> list[dict[str, Any]]:
        attempts = []
        for attempt in range(self.args.max_retries + 1):
            res = stream_request(self.url, body, self.api_key, self.args.request_timeout, self.args.api, on_first_token if attempt == 0 else None)
            attempts.append(res)
            if not is_failure(res):
                break
            if attempt < self.args.max_retries:
                time.sleep(self.args.retry_backoff_seconds * (attempt + 1))
        return attempts

    def _record(self, rec: dict[str, Any]) -> None:
        final = rec["attempts"][-1]
        prompt, cached = final.get("prompt_tokens"), final.get("cached_tokens")
        rec["cache_ratio"] = round(cached / prompt, 4) if isinstance(prompt, int) and prompt > 0 and isinstance(cached, int) else None
        rec["breaches"] = evaluate_turn(rec, self.args)
        with self.lock:
            self.records.append(rec)
            if self.out_handle:
                self.out_handle.write(json.dumps(rec) + "\n")
                self.out_handle.flush()

    def _aggressor(self, session: int, turn: int) -> None:
        rng = random.Random(f"{self.run_id}-{session}-{turn}")
        text = aggressor_text(self.args.aggressor_prefill_tokens, rng)
        items = [{"type": "message", "role": "user", "content": [{"type": "input_text", "text": text + "\nReply with one word."}]}]
        meta = dict(self.meta, tools=[], instructions="")
        body = (build_responses_body if self.args.api == "responses" else build_chat_body)(meta, items, self.model, f"replay-aggr-{self.run_id}-{session}-{turn}")
        body.pop("reasoning", None)
        body.pop("reasoning_effort", None)
        body["max_output_tokens" if self.args.api == "responses" else "max_tokens"] = 16
        attempts = [stream_request(self.url, body, self.api_key, self.args.request_timeout, self.args.api)]
        self._record({"role": "aggressor", "session": session, "turn": turn, "post_compaction": False, "source_context_tokens": self.args.aggressor_prefill_tokens, "attempts": attempts})

    def _session(self, session: int) -> None:
        time.sleep(session * self.args.stagger_seconds)
        nonce = f"{self.run_id}-s{session}"
        cache_key = f"replay-{self.meta.get('session_id') or 'session'}-{nonce}"
        for turn, req in enumerate(self.requests):
            items = _with_nonce(req["input"], nonce)
            body = self._body(items, cache_key)
            on_first = None
            if self.args.aggressor_prefill_tokens and session == 0:
                fired = threading.Event()

                def on_first(fired=fired, turn=turn) -> None:
                    if not fired.is_set():
                        fired.set()
                        t = threading.Thread(target=self._aggressor, args=(session, turn), daemon=True)
                        with self.lock:
                            self.agg_threads.append(t)
                        t.start()

            attempts = self._send(body, on_first)
            src = req.get("source_usage") or {}
            self._record(
                {
                    "role": "session",
                    "session": session,
                    "turn": turn,
                    "source_request_index": req["index"],
                    "post_compaction": req["post_compaction"],
                    "source_context_tokens": request_context_tokens(req, self.meta["instructions"]),
                    "source_cached_tokens": src.get("cached_input_tokens"),
                    "attempts": attempts,
                }
            )
            if self.args.turn_gap_seconds:
                time.sleep(self.args.turn_gap_seconds)

    def run(self, out_dir: Path) -> dict[str, Any]:
        out_dir.mkdir(parents=True, exist_ok=True)
        with open(out_dir / "turns.jsonl", "w", encoding="utf-8") as handle:
            self.out_handle = handle
            threads = [threading.Thread(target=self._session, args=(i,), daemon=True) for i in range(self.args.sessions)]
            for t in threads:
                t.start()
            for t in threads:
                t.join()
            while True:
                with self.lock:
                    pending = [t for t in self.agg_threads if t.is_alive()]
                if not pending:
                    break
                for t in pending:
                    t.join()
            self.out_handle = None
        summary = summarize(self.records, self.args, self.meta)
        (out_dir / "summary.json").write_text(json.dumps(summary, indent=2) + "\n", encoding="utf-8")
        return summary


def select_requests(meta: dict[str, Any], max_context: int | None) -> list[dict[str, Any]]:
    selected = []
    for req in meta["requests"]:
        if max_context and request_context_tokens(req, meta["instructions"]) > max_context:
            break
        selected.append(req)
    return selected


def build_parser() -> argparse.ArgumentParser:
    p = argparse.ArgumentParser(description=__doc__.split("\n\n")[0])
    p.add_argument("rollout", help="Codex rollout JSONL (CODEX_HOME/sessions/**/rollout-*.jsonl)")
    p.add_argument("--base-url", help="OpenAI-compatible base URL ending in /v1")
    p.add_argument("--api-key-file", help="file holding the bearer key (never pass a literal key)")
    p.add_argument("--api", choices=("responses", "chat"), default="responses", help="wire API; Codex lanes use responses")
    p.add_argument("--model", help="override the rollout's model id")
    p.add_argument("--tools-file", help="JSON tools array to send instead of the rollout/synthesized tools")
    p.add_argument("--sessions", type=int, default=1, help="concurrent staggered copies of the session")
    p.add_argument("--stagger-seconds", type=float, default=15.0, help="start delay between copies")
    p.add_argument("--aggressor-prefill-tokens", type=parse_token_count, default=0, help="per turn of copy 0, one concurrent uncached prompt of about K tokens, fired at that turn's first token")
    p.add_argument("--max-context", type=parse_token_count, help="stop before the first request whose source context exceeds this (e.g. 32k, 64k, 100k, 128k)")
    p.add_argument("--turn-gap-seconds", type=float, default=0.0, help="pause between turns (tool time)")
    p.add_argument("--max-retries", type=int, default=2, help="retries per failed request; every failed attempt still breaches")
    p.add_argument("--retry-backoff-seconds", type=float, default=2.0)
    p.add_argument("--request-timeout", type=float, default=900.0, help="socket timeout per request, seconds")
    p.add_argument("--min-cache-ratio", type=float, default=0.90, help="SLO: cached/prompt tokens after turn 1")
    p.add_argument("--idle-limit-seconds", type=float, default=10.0, help="SLO: largest gap between tokens must stay below the gateway idle limit")
    p.add_argument("--ttft-base-seconds", type=float, default=10.0, help="SLO: TTFT bound = base + uncached tokens / prefill rate")
    p.add_argument("--prefill-tokens-per-second", type=float, default=300.0, help="SLO: minimum prefill rate for the TTFT bound")
    p.add_argument("--out-dir", default="agent-session-replay-out", help="writes turns.jsonl and summary.json here")
    p.add_argument("--plan", action="store_true", help="parse the rollout and print the request plan; no network")
    return p


def main(argv: list[str] | None = None) -> int:
    args = build_parser().parse_args(argv)
    if args.sessions < 1 or args.max_retries < 0 or args.prefill_tokens_per_second <= 0:
        print("error: --sessions >= 1, --max-retries >= 0, --prefill-tokens-per-second > 0", file=sys.stderr)
        return 2
    try:
        meta = parse_rollout(args.rollout)
    except RolloutError as exc:
        print(f"error: {exc}", file=sys.stderr)
        return 2
    if args.tools_file:
        try:
            meta["tools"] = json.loads(Path(args.tools_file).read_text(encoding="utf-8"))
            meta["tools_source"] = "tools_file"
        except (OSError, json.JSONDecodeError) as exc:
            print(f"error: --tools-file: {exc}", file=sys.stderr)
            return 2
    requests = select_requests(meta, args.max_context)
    if not requests:
        print("error: no requests fit --max-context", file=sys.stderr)
        return 2
    if args.plan:
        plan = {
            "source_session_id": meta["session_id"],
            "model": meta["model"],
            "effort": meta["effort"],
            "tools_source": meta["tools_source"],
            "tool_names": [t.get("name") for t in meta["tools"]],
            "compactions": meta["compactions"],
            "requests_total": len(meta["requests"]),
            "requests_selected": len(requests),
            "requests": [
                {
                    "index": r["index"],
                    "input_items": len(r["input"]),
                    "context_tokens": request_context_tokens(r, meta["instructions"]),
                    "source_cached_tokens": (r.get("source_usage") or {}).get("cached_input_tokens"),
                    "post_compaction": r["post_compaction"],
                }
                for r in requests
            ],
        }
        print(json.dumps(plan, indent=2))
        return 0
    if not args.base_url:
        print("error: --base-url is required unless --plan", file=sys.stderr)
        return 2
    api_key = None
    if args.api_key_file:
        try:
            api_key = Path(args.api_key_file).read_text(encoding="utf-8").strip()
        except OSError as exc:
            print(f"error: cannot read --api-key-file: {exc.strerror}", file=sys.stderr)
            return 2
    summary = Replay(meta, requests, args, api_key).run(Path(args.out_dir))
    print(json.dumps({k: summary[k] for k in ("pass", "requests_replayed", "aggressor_requests", "counts", "breach_counts", "by_context")}, indent=2))
    return 0 if summary["pass"] else 1


if __name__ == "__main__":
    sys.exit(main())
