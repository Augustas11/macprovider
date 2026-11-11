#!/usr/bin/env python3
"""#2230 lab driver for Qwen3.6-35B-A3B on an isolated loopback lab serve.

  ttft     --port P --model M --out F [--runs 10]
           Serial greedy prefill time. For each prompt size (about 1536 and
           4096 tokens) one warmup, then RUNS timed one-token completions,
           each behind a distinct leading nonce so no run reuses another's
           prefix, then one 64-token completion of the first timed prompt for
           token parity. The nonces depend only on the run index, so two
           builds see the same prompts.
  compare  BASE.json HEAD.json
           Prefill p50 per prompt size and greedy-output parity, HEAD vs BASE.
  grouped  --port P --model M --out F
           Grouped prefill isolation. Lone greedy runs first, then the same
           prompts concurrently in pairs and quads behind a long decoding
           row. Short prompts (32-127 tokens) prefill alone under the CB
           grouping rule; equal-length 256-token prompts group (A3B groups
           chunks of 128+ tokens), so they cover a batched MLXFast gated
           delta prefill. PASS when every concurrent output equals its lone
           output.
"""

from __future__ import annotations

import argparse
import concurrent.futures
import json
import statistics
import sys
import time
import urllib.request

FILLER = "Harbor note: the tide table lists the morning low at 06:12 and the evening high at 18:47. "


def post(port: int, body: dict, request_id: str, timeout: float = 1800) -> dict:
    request = urllib.request.Request(
        f"http://127.0.0.1:{port}/v1/chat/completions",
        data=json.dumps(body).encode(),
        headers={"Content-Type": "application/json", "X-Request-ID": request_id},
        method="POST",
    )
    started = time.monotonic()
    with urllib.request.urlopen(request, timeout=timeout) as response:
        document = json.load(response)
    message = document["choices"][0]["message"]
    usage = document.get("usage", {})
    return {
        "content": message.get("content"),
        "reasoning": message.get("reasoning_content"),
        "finish_reason": document["choices"][0].get("finish_reason"),
        "prompt_tokens": usage.get("prompt_tokens"),
        "cached_prompt_tokens": usage.get("cached_prompt_tokens"),
        "completion_tokens": usage.get("completion_tokens"),
        "wall_s": time.monotonic() - started,
    }


def body(model: str, text: str, max_tokens: int) -> dict:
    return {
        "model": model,
        "messages": [{"role": "user", "content": text}],
        "max_tokens": max_tokens,
        "temperature": 0,
        "stream": False,
    }


def sized_prompt(nonce: str, approx_tokens: int) -> str:
    # About 22 tokens per filler sentence on the Qwen tokenizer.
    repeats = max(1, approx_tokens // 22)
    return f"Log {nonce}. " + FILLER * repeats + "Summarize the harbor notes in one sentence."


def ttft(args: argparse.Namespace) -> int:
    result = {"schema": "macprovider.qwen36-2230-ttft.v1", "label": args.label, "sizes": {}}
    for size in (1536, 4096):
        post(args.port, body(args.model, sized_prompt(f"warmup-{size}", size), 1), f"warm-{size}")
        walls, prompt_tokens = [], set()
        for run in range(args.runs):
            r = post(args.port, body(args.model, sized_prompt(f"run-{size}-{run}", size), 1), f"t-{size}-{run}")
            if r["cached_prompt_tokens"]:
                print(f"warning: run {run} at {size} reused {r['cached_prompt_tokens']} cached tokens", file=sys.stderr)
            walls.append(r["wall_s"])
            prompt_tokens.add(r["prompt_tokens"])
        parity = post(args.port, body(args.model, sized_prompt(f"run-{size}-0", size), 64), f"p-{size}")
        result["sizes"][str(size)] = {
            "prompt_tokens": sorted(t for t in prompt_tokens if t is not None),
            "prefill_wall_s": walls,
            "prefill_wall_p50_s": statistics.median(walls),
            "prefill_wall_min_s": min(walls),
            "parity_output": {k: parity[k] for k in ("content", "reasoning", "finish_reason", "completion_tokens")},
        }
        print(f"{args.label} p{size}: p50={statistics.median(walls):.3f}s min={min(walls):.3f}s "
              f"prompt_tokens={sorted(prompt_tokens)}", file=sys.stderr)
    with open(args.out, "w") as fh:
        json.dump(result, fh, indent=1, sort_keys=True)
    return 0


def compare(args: argparse.Namespace) -> int:
    base, head = json.load(open(args.base)), json.load(open(args.head))
    rows, same = [], True
    for size, b in base["sizes"].items():
        h = head["sizes"][size]
        delta = (h["prefill_wall_p50_s"] - b["prefill_wall_p50_s"]) / b["prefill_wall_p50_s"]
        parity = b["parity_output"] == h["parity_output"]
        same &= parity
        rows.append({"size": size, "base_p50_s": b["prefill_wall_p50_s"], "head_p50_s": h["prefill_wall_p50_s"],
                     "delta": delta, "greedy_output_equal": parity})
        print(f"p{size}: base {b['prefill_wall_p50_s']:.3f}s head {h['prefill_wall_p50_s']:.3f}s "
              f"delta {delta:+.1%} greedy_output_equal={parity}")
    json.dump({"schema": "macprovider.qwen36-2230-ttft-compare.v1", "rows": rows}, sys.stdout, indent=1)
    print()
    return 0


def grouped(args: argparse.Namespace) -> int:
    short = [sized_prompt(f"short-{i}", n) for i, n in enumerate((32, 48, 64, 80, 96, 112, 120, 127))]
    # Equal text length and one-digit nonces, so the four prompts tokenize to
    # the same length (checked below from usage.prompt_tokens).
    long = [sized_prompt(f"group-{i}", 256) for i in range(4)]
    blocker = sized_prompt("decoder", 1024)
    fields = ("content", "reasoning", "finish_reason", "completion_tokens")

    def run(text: str, rid: str) -> dict:
        return post(args.port, body(args.model, text, args.max_tokens), rid)

    lone = {text: run(text, f"lone-{i}") for i, text in enumerate(short + long)}
    long_lengths = sorted({lone[t]["prompt_tokens"] for t in long})
    checks: dict[str, bool] = {"long_prompts_equal_length": len(long_lengths) == 1}
    with concurrent.futures.ThreadPoolExecutor(max_workers=5) as pool:
        for width in (2, 4):
            for name, prompts in (("short", short), ("long", long)):
                for start in range(0, len(prompts) - width + 1, width):
                    group = prompts[start:start + width]
                    decoding = pool.submit(post, args.port, body(args.model, blocker, 512), f"blocker-{name}-{width}-{start}")
                    time.sleep(args.blocker_lead_s)
                    futures = [pool.submit(run, text, f"{name}-w{width}-{start}-{j}") for j, text in enumerate(group)]
                    for j, (text, future) in enumerate(zip(group, futures)):
                        got = future.result()
                        checks[f"{name}.w{width}.g{start}.r{j}"] = all(got[k] == lone[text][k] for k in fields)
                    decoding.result()
    failed = sorted(k for k, ok in checks.items() if not ok)
    doc = {"schema": "macprovider.qwen36-2230-grouped.v1", "long_prompt_tokens": long_lengths,
           "checks": checks, "failed_checks": failed, "passed": not failed}
    with open(args.out, "w") as fh:
        json.dump(doc, fh, indent=1, sort_keys=True)
    print(f"grouped: {'PASS' if not failed else 'FAIL'} checks={len(checks)} failed={failed}", file=sys.stderr)
    return 0 if not failed else 1


def main() -> int:
    parser = argparse.ArgumentParser()
    sub = parser.add_subparsers(dest="command", required=True)
    p = sub.add_parser("ttft")
    p.add_argument("--port", type=int, required=True)
    p.add_argument("--model", default="qwen/qwen3.6-35b-a3b")
    p.add_argument("--label", required=True)
    p.add_argument("--runs", type=int, default=10)
    p.add_argument("--out", required=True)
    p = sub.add_parser("compare")
    p.add_argument("base")
    p.add_argument("head")
    p = sub.add_parser("grouped")
    p.add_argument("--port", type=int, required=True)
    p.add_argument("--model", default="qwen/qwen3.6-35b-a3b")
    p.add_argument("--max-tokens", type=int, default=48)
    p.add_argument("--blocker-lead-s", type=float, default=2.0)
    p.add_argument("--out", required=True)
    args = parser.parse_args()
    return {"ttft": ttft, "compare": compare, "grouped": grouped}[args.command](args)


if __name__ == "__main__":
    sys.exit(main())
