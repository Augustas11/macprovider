#!/usr/bin/env python3
"""Concurrent-row cells against a running provider that batches.

For one context size and output length: each prompt alone, then the first k
prompts started together for each requested width, then a join case (two rows
start, a third joins after a delay). Prints one JSON object with aggregate
tok/s per width and, for every row, whether its text equals that prompt's lone
run and the first differing character if not. While a width runs it polls
/v1/status and records the largest `scheduler.active_decode_rows` it saw.

The prompts are the parity grid's (prompts.build_messages), one per row index,
so a row has the same prompt at every width. Needs only the standard library.
"""
import argparse
import http.client
import json
import os
import sys
import threading
import time

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import prompts  # noqa: E402
import provider_client  # noqa: E402


def one(port, model, ctx, row, max_tokens, out, key, delay=0.0):
    if delay:
        time.sleep(delay)
    t0 = time.perf_counter()
    res = provider_client.run_request(port, model, prompts.build_messages(ctx, row), max_tokens)
    usage = res.get("usage") or {}
    tokens = usage.get("macprovider_generated_completion_tokens") or usage.get("completion_tokens") or 0
    out[key] = {"row": row, "text": res.get("text") or "", "tokens": tokens, "finish": res.get("finish"),
                "error": res.get("error"), "t0": t0, "t1": time.perf_counter()}


def status(port):
    try:
        conn = http.client.HTTPConnection("127.0.0.1", port, timeout=3)
        conn.request("GET", "/v1/status")
        return json.loads(conn.getresponse().read())
    except Exception:
        return {}


def burst(port, model, ctx, rows, max_tokens, delays=None):
    out, threads = {}, []
    stop, seen = threading.Event(), {"max_rows": 0}

    def watch():
        while not stop.is_set():
            sched = ((status(port).get("continuous_batching") or {}).get("scheduler") or {})
            seen["max_rows"] = max(seen["max_rows"], sched.get("active_decode_rows") or 0)
            time.sleep(0.2)

    w = threading.Thread(target=watch, daemon=True)
    w.start()
    for i, row in enumerate(rows):
        t = threading.Thread(target=one, args=(port, model, ctx, row, max_tokens, out, row,
                                               (delays or {}).get(row, 0.0)))
        t.start()
        threads.append(t)
    for t in threads:
        t.join()
    stop.set()
    w.join(timeout=2)
    recs = [out[r] for r in rows]
    span = max(r["t1"] for r in recs) - min(r["t0"] for r in recs)
    return recs, {"aggregate_tps": round(sum(r["tokens"] for r in recs) / span, 3) if span > 0 else None,
                  "wall_s": round(span, 3), "max_active_decode_rows": seen["max_rows"],
                  "errors": [r["error"] for r in recs if r["error"]]}


def compare(rec, lone):
    a, b = lone["text"], rec["text"]
    if a == b:
        return {"row": rec["row"], "equal_lone": True, "tokens": rec["tokens"]}
    i = next((j for j in range(min(len(a), len(b))) if a[j] != b[j]), min(len(a), len(b)))
    return {"row": rec["row"], "equal_lone": False, "first_diff_char": i, "tokens": rec["tokens"],
            "lone_tokens": lone["tokens"], "lone_at": a[max(0, i - 20):i + 20], "ours_at": b[max(0, i - 20):i + 20]}


def main(argv=None):
    ap = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    ap.add_argument("--port", type=int, required=True)
    ap.add_argument("--model", required=True)
    ap.add_argument("--ctx", type=int, default=200)
    ap.add_argument("--max-tokens", type=int, default=256)
    ap.add_argument("--widths", default="2,3,4,8")
    ap.add_argument("--trials", type=int, default=2)
    ap.add_argument("--join-delay", type=float, default=1.0)
    args = ap.parse_args(argv)
    widths = [int(x) for x in args.widths.split(",")]
    top = max(widths + [3])

    before = (status(args.port).get("continuous_batching") or {})
    lone, lone_tps = {}, []
    for row in range(top):
        recs, agg = burst(args.port, args.model, args.ctx, [row], args.max_tokens)
        lone[row] = recs[0]
        lone_tps.append(agg["aggregate_tps"])
    # A second lone run of row 0 shows whether a lone request repeats itself.
    again, _ = burst(args.port, args.model, args.ctx, [0], args.max_tokens)
    result = {"model": args.model, "ctx": args.ctx, "max_tokens": args.max_tokens,
              "route": before.get("small_m_route"), "route_reason": before.get("small_m_route_reason"),
              "cb_active": before.get("active"), "self_check": before.get("self_check"),
              "lone_tps": lone_tps, "lone_repeat_equal": again[0]["text"] == lone[0]["text"], "widths": []}
    for k in widths:
        for trial in range(args.trials):
            recs, agg = burst(args.port, args.model, args.ctx, list(range(k)), args.max_tokens)
            agg.update({"width": k, "trial": trial, "rows": [compare(r, lone[r["row"]]) for r in recs]})
            result["widths"].append(agg)
    recs, agg = burst(args.port, args.model, args.ctx, [0, 1, 2], args.max_tokens, delays={2: args.join_delay})
    agg.update({"case": "join", "join_delay_s": args.join_delay,
                "rows": [compare(r, lone[r["row"]]) for r in recs]})
    result["join"] = agg
    after = (status(args.port).get("continuous_batching") or {})
    result["scheduler_after"] = after.get("scheduler")
    print(json.dumps(result, indent=1))


if __name__ == "__main__":
    main()
