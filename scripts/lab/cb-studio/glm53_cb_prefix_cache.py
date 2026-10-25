#!/usr/bin/env python3
"""SPEC-024-R005 lab driver (issue #2143): GLM-5.3-Flash multi-turn keyed
conversations against an isolated loopback lab serve.

Each conversation runs TURNS turns. Every turn is sent twice, at ROWS
conversations in flight:
  warm  the conversation's own key, so turn t >= 2 resumes the snapshot the
        previous turn's CB row published;
  cold  a fresh key per turn, so nothing is reused.
Warm and cold must return the same greedy text (content and reasoning) and
completion tokens; warm turns t >= 2 must report cached_prompt_tokens > 0,
cold turns 0. The next turn's history carries the warm reply.

Writes one JSON document to stdout and exits 1 on any failed check. Stdlib
only; run with `python3 -I`.
"""

from __future__ import annotations

import argparse
import concurrent.futures
import json
import sys
import time
import urllib.request

QUESTIONS = [
    "Describe how a lighthouse keeper prepares the lamp for the night.",
    "List what the keeper checks after a storm, and why.",
    "Explain how the tide tables change the keeper's schedule.",
    "Summarize the keeper's week in a short paragraph.",
    "Write the log entry for a quiet night.",
    "Describe the supply boat's arrival.",
]
SYSTEM = (
    "You are a careful assistant for a harbor log. Answer in plain prose. "
    + "Harbor notes: tide tables list the morning low at 06:12 and the evening high at 18:47. " * 40
)


def post(port: int, body: dict, key: str, request_id: str, timeout: float) -> dict:
    request = urllib.request.Request(
        f"http://127.0.0.1:{port}/v1/chat/completions",
        data=json.dumps(body).encode(),
        headers={
            "Content-Type": "application/json",
            "X-Request-ID": request_id,
            "X-MacProvider-Provider-Conversation": key,
        },
        method="POST",
    )
    started = time.monotonic()
    with urllib.request.urlopen(request, timeout=timeout) as response:
        document = json.load(response)
    document["_wall_s"] = time.monotonic() - started
    return document


def summary(document: dict) -> dict:
    message = document["choices"][0]["message"]
    usage = document.get("usage", {})
    return {
        "content": message.get("content"),
        "reasoning": message.get("reasoning_content"),
        "finish_reason": document["choices"][0].get("finish_reason"),
        "prompt_tokens": usage.get("prompt_tokens"),
        "cached_prompt_tokens": usage.get("cached_prompt_tokens"),
        "completion_tokens": usage.get("completion_tokens"),
        "wall_s": document["_wall_s"],
    }


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--port", type=int, required=True)
    parser.add_argument("--model", default="zai-org/glm-5.3-flash")
    parser.add_argument("--rows", type=int, default=4)
    parser.add_argument("--turns", type=int, default=4)
    parser.add_argument("--max-tokens", type=int, default=128)
    parser.add_argument("--run-id", required=True)
    parser.add_argument("--timeout", type=float, default=900)
    args = parser.parse_args()

    histories = [[{"role": "system", "content": SYSTEM}] for _ in range(args.rows)]
    checks: dict[str, bool] = {}
    turns = []
    for turn in range(args.turns):
        for row in range(args.rows):
            question = QUESTIONS[(row + turn) % len(QUESTIONS)]
            histories[row].append({"role": "user", "content": f"{question} (conversation {row}, turn {turn})"})

        def send(row: int, mode: str) -> dict:
            key = (f"conv:{args.run_id}-warm-{row}" if mode == "warm"
                   else f"conv:{args.run_id}-cold-{row}-{turn}")
            body = {
                "model": args.model,
                "messages": histories[row],
                "max_tokens": args.max_tokens,
                "temperature": 0,
                "stream": False,
            }
            return summary(post(args.port, body, key, f"{args.run_id}-{mode}-{row}-{turn}", args.timeout))

        results = {}
        for mode in ("warm", "cold"):
            with concurrent.futures.ThreadPoolExecutor(max_workers=args.rows) as pool:
                started = time.monotonic()
                results[mode] = list(pool.map(lambda row: send(row, mode), range(args.rows)))
                results[f"{mode}_wall_s"] = time.monotonic() - started
        for row in range(args.rows):
            warm, cold = results["warm"][row], results["cold"][row]
            label = f"row{row}.turn{turn}"
            checks[f"{label}.warm_equals_cold"] = all(
                warm[field] == cold[field]
                for field in ("content", "reasoning", "finish_reason", "prompt_tokens", "completion_tokens")
            )
            checks[f"{label}.cold_reused_nothing"] = cold["cached_prompt_tokens"] == 0
            if turn > 0:
                checks[f"{label}.warm_reused_prefix"] = (warm["cached_prompt_tokens"] or 0) > 0
            histories[row].append({"role": "assistant", "content": warm["content"] or ""})
        turns.append({"turn": turn, **results})
    passed = bool(checks) and all(checks.values())
    json.dump({
        "schema": "macprovider.glm53-cb-prefix-cache-lab.v1",
        "run_id": args.run_id,
        "rows": args.rows,
        "turns": turns,
        "checks": checks,
        "failed_checks": sorted(name for name, ok in checks.items() if not ok),
        "passed": passed,
    }, sys.stdout, indent=1, sort_keys=True)
    sys.stdout.write("\n")
    return 0 if passed else 1


if __name__ == "__main__":
    sys.exit(main())
