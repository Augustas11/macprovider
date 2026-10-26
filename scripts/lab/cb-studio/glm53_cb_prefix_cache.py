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

`--first-logits-log SERVE_LOG PARITY_JSON...` instead reads the lab serve's
`[lab-first-logits]` lines (MACPROVIDER_LAB_FIRST_TOKEN_LOGITS=1) and pairs
each warm request with its cold twin: equal float32 logit digests mean the
resumed prompt state was bit-identical to the cold prefill; otherwise the top-5
logits and the top-1/top-2 margins show how far apart they were and how
contested the greedy choice was. Every warm/cold request of the given parity
results must log exactly one line each. Exits 1 unless every expected pair is
present and identical.
"""

from __future__ import annotations

import argparse
import concurrent.futures
import json
import re
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


FIRST_LOGITS = re.compile(
    r"\[lab-first-logits\] request_id=(?P<run>\S+)-(?P<mode>warm|cold)-(?P<row>\d+)-(?P<turn>\d+) "
    r"prompt_tokens=(?P<prompt>\d+) sha256=(?P<sha>[0-9a-f]{64}) top5=(?P<top>\S+)")


def first_logits_report(path: str, parity_paths: list[str]) -> int:
    expected = set()
    for parity_path in parity_paths:
        with open(parity_path, encoding="utf-8") as handle:
            document = json.load(handle)
        for turn in document["turns"]:
            for row in range(document["rows"]):
                expected.add((document["run_id"], row, turn["turn"]))
    rows: dict[tuple[str, int, int], dict[str, dict]] = {key: {} for key in expected}
    duplicates = 0
    with open(path, encoding="utf-8", errors="replace") as log:
        for line in log:
            match = FIRST_LOGITS.search(line)
            if not match:
                continue
            top = [(int(i), float(v)) for i, v in (pair.split(":") for pair in match["top"].split(","))]
            key = (match["run"], int(match["row"]), int(match["turn"]))
            duplicates += match["mode"] in rows.setdefault(key, {})
            rows[key][match["mode"]] = {
                "prompt_tokens": int(match["prompt"]), "sha256": match["sha"], "top5": top,
                "margin": top[0][1] - top[1][1] if len(top) > 1 else None,
            }
    pairs = []
    for (run, row, turn), modes in sorted(rows.items()):
        warm, cold = modes.get("warm"), modes.get("cold")
        if not warm or not cold:
            pairs.append({"run": run, "row": row, "turn": turn, "complete": False})
            continue
        cold_top = dict(cold["top5"])
        shared = [i for i, _ in warm["top5"] if i in cold_top]
        pairs.append({
            "run": run, "row": row, "turn": turn, "complete": True,
            "prompt_tokens": [warm["prompt_tokens"], cold["prompt_tokens"]],
            "identical": warm["sha256"] == cold["sha256"],
            "top1_equal": warm["top5"][0][0] == cold["top5"][0][0],
            "margin_warm": warm["margin"], "margin_cold": cold["margin"],
            "max_abs_diff_shared_top5": max((abs(dict(warm["top5"])[i] - cold_top[i]) for i in shared), default=None),
            "top5_warm": warm["top5"], "top5_cold": cold["top5"],
        })
    complete = [pair for pair in pairs if pair["complete"]]
    identical = sum(pair["identical"] for pair in complete)
    passed = bool(expected) and set(rows) == expected and duplicates == 0 and identical == len(pairs)
    json.dump({
        "schema": "macprovider.glm53-cb-prefix-cache-first-logits.v1",
        "expected_pairs": len(expected), "unexpected_pairs": len(set(rows) - expected),
        "duplicate_lines": duplicates,
        "pairs": len(pairs), "complete_pairs": len(complete), "identical_pairs": identical,
        "passed": passed, "details": pairs,
    }, sys.stdout, indent=1, sort_keys=True)
    sys.stdout.write("\n")
    return 0 if passed else 1


def main() -> int:
    if len(sys.argv) >= 4 and sys.argv[1] == "--first-logits-log":
        return first_logits_report(sys.argv[2], sys.argv[3:])
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
