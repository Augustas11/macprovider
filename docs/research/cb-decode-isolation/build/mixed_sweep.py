#!/usr/bin/env python3
"""Continuous-batching depth sweep on an isolated lab serve (issue #1906).

For each depth N, N closed-loop workers send cache-free requests back to back
for a fixed window: every request carries a unique salt at the start of its
prompt, so prefix reuse never inflates throughput. Requests use a fresh
X-Request-ID so they route through the batch scheduler.

Per depth it reports:
  agg_tok_s       completion tokens finished inside the window / window
  ttft p50/p95    request start to first generated (content or reasoning) token,
                  for requests started inside the window
  itl p50/p95     per-stream gaps between streamed chunks inside the window
  decode p50      per-request (completion - 1) / (end - first token)
  errors          by HTTP status / error code

usage: depth_sweep.py --port 18090 --model qwen/qwen3.6-35b-a3b \
         --depths 4,8,12,16,24,32 --prompt-tokens 1536 --max-tokens 256 \
         --window 120 --warmup 20 --label fused --out sweep.jsonl
"""
import argparse
import collections
import http.client
import json
import statistics
import threading
import time
import uuid
import os
import random

FILLER = ("The quick brown fox jumps over the lazy dog while the orchestra tunes its "
          "instruments and the river keeps flowing past the old stone bridge. ")


def prompt(target_tokens, salt):
    # ~24 tokens per filler sentence for the Qwen tokenizer.
    n = max(0, target_tokens // 24 - 2)
    return f"[{salt}] " + FILLER * n + "Now count from 1 to 2000 separated by commas."


def one(args):
    body = json.dumps({
        "model": args.model,
        "messages": [{"role": "user", "content": prompt(random.randint(int(os.environ.get("MIX_MIN","300")), int(os.environ.get("MIX_MAX","2500"))), uuid.uuid4().hex)}],
        "max_tokens": args.max_tokens, "temperature": 0, "stream": not args.no_stream,
        **({} if args.no_stream else {"stream_options": {"include_usage": True}}),
    })
    headers = {"Content-Type": "application/json", "X-Request-ID": "sweep-" + uuid.uuid4().hex[:16]}
    t0 = time.monotonic()
    stamps = []
    usage = None
    try:
        c = http.client.HTTPConnection("127.0.0.1", args.port, timeout=1800)
        c.request("POST", "/v1/chat/completions", body, headers)
        r = c.getresponse()
        if r.status != 200:
            raw = r.read()[:400]
            code = str(r.status)
            try:
                code += ":" + str(json.loads(raw).get("error", {}).get("code"))
            except Exception:
                pass
            return {"ok": False, "code": code, "t0": t0, "end": time.monotonic()}
        if args.no_stream:
            u = json.loads(r.read()).get("usage") or {}
            return {"ok": True, "t0": t0, "end": time.monotonic(), "stamps": [],
                    "prompt": u.get("prompt_tokens", 0), "completion": u.get("completion_tokens", 0)}
        while True:
            line = r.readline()
            if not line:
                break
            line = line.strip()
            if not line.startswith(b"data:"):
                continue
            data = line[5:].strip()
            if data == b"[DONE]":
                break
            j = json.loads(data)
            if j.get("usage"):
                usage = j["usage"]
            # Thinking models stream reasoning before content; both are
            # generated tokens the buyer pays for.
            if any((ch.get("delta") or {}).get(k) for ch in j.get("choices", [])
                   for k in ("content", "reasoning_content", "reasoning")):
                stamps.append(time.monotonic())
    except Exception as e:  # noqa: BLE001 - lab harness records every failure
        return {"ok": False, "code": type(e).__name__, "t0": t0, "end": time.monotonic()}
    end = time.monotonic()
    u = usage or {}
    return {"ok": True, "t0": t0, "end": end, "stamps": stamps,
            "prompt": u.get("prompt_tokens", 0), "completion": u.get("completion_tokens", 0)}


def pct(values, q):
    if not values:
        return None
    if len(values) == 1:
        return round(values[0], 3)
    return round(statistics.quantiles(values, n=100)[q - 1], 3)


def run_depth(args, depth):
    results = []
    lock = threading.Lock()
    start = time.monotonic()
    measure_from = start + args.warmup
    stop_at = measure_from + args.window

    def worker():
        while time.monotonic() < stop_at:
            res = one(args)
            with lock:
                results.append(res)

    threads = [threading.Thread(target=worker) for _ in range(depth)]
    for t in threads:
        t.start()
        time.sleep(args.stagger)
    for t in threads:
        t.join()

    # Throughput counts only tokens emitted inside the measured window, so the
    # tail drain after stop_at and the warmup ramp do not dilute or inflate it.
    window_tokens = 0
    ttft, itl, decode = [], [], []
    errors = collections.Counter()
    finished = 0
    for r in results:
        if not r["ok"]:
            if measure_from <= r["end"] <= stop_at:
                errors[r["code"]] += 1
            continue
        s = r["stamps"]
        if args.no_stream:
            # No per-token timestamps: prorate the request's tokens over the
            # part of its lifetime that overlaps the window.
            span = r["end"] - r["t0"]
            overlap = max(0.0, min(r["end"], stop_at) - max(r["t0"], measure_from))
            window_tokens += r["completion"] * (overlap / span) if span > 0 else 0
        else:
            chunk_tokens = (r["completion"] / len(s)) if s else 0
            window_tokens += sum(chunk_tokens for x in s if measure_from <= x <= stop_at)
        # Long outputs outlive the window, so TTFT and ITL use every request
        # that started (or streamed) inside it, not only those that finished.
        if s and r["t0"] >= measure_from and s[0] <= stop_at:
            ttft.append(s[0] - r["t0"])
        in_window = [x for x in s if measure_from <= x <= stop_at]
        itl.extend(b - a for a, b in zip(in_window, in_window[1:]))
        if r["t0"] >= measure_from and r["end"] <= stop_at:
            finished += 1
            if s and r["completion"] > 1 and r["end"] > s[0]:
                decode.append((r["completion"] - 1) / (r["end"] - s[0]))
    row = {
        "label": args.label, "depth": depth, "prompt_tokens_target": args.prompt_tokens,
        "max_tokens": args.max_tokens, "window_s": args.window,
        "agg_tok_s": round(window_tokens / args.window, 1),
        "finished_in_window": finished, "errors": dict(errors),
        "ttft_p50_s": pct(ttft, 50), "ttft_p95_s": pct(ttft, 95),
        "itl_p50_ms": pct([x * 1000 for x in itl], 50), "itl_p95_ms": pct([x * 1000 for x in itl], 95),
        "decode_tok_s_p50": round(statistics.median(decode), 1) if decode else None,
    }
    return row


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--port", type=int, required=True)
    ap.add_argument("--model", required=True)
    ap.add_argument("--depths", default="4,8,12,16,24,32")
    ap.add_argument("--prompt-tokens", type=int, default=1536)
    ap.add_argument("--max-tokens", type=int, default=256)
    ap.add_argument("--window", type=float, default=120)
    ap.add_argument("--warmup", type=float, default=20)
    ap.add_argument("--stagger", type=float, default=0.25)
    ap.add_argument("--label", default="")
    ap.add_argument("--no-stream", action="store_true",
                    help="non-streaming requests; throughput is prorated over request lifetimes")
    ap.add_argument("--out", required=True)
    args = ap.parse_args()
    with open(args.out, "a") as f:
        for depth in [int(x) for x in args.depths.split(",")]:
            row = run_depth(args, depth)
            print(json.dumps(row), flush=True)
            f.write(json.dumps(row) + "\n")
            f.flush()


if __name__ == "__main__":
    main()
