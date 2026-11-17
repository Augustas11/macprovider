#!/usr/bin/env python3
"""Issue #2417 load driver: streamed chat requests at fixed concurrency levels.

Sends the fixed prompts in prompts.json (greedy, fixed max_tokens) to a local
OpenAI-compatible server, `concurrency` requests at once, `rounds` times per
level, and writes JSON and a markdown table. Standard library only.

  python3 -I drive.py --url http://127.0.0.1:18190 --prompts prompts.json \
      --levels 1,4,8 --max-tokens 128 --rounds 2 --label shard --out DIR
"""
import argparse
import http.client
import json
import statistics
import sys
import threading
import time
import urllib.parse


def model_id(url):
    u = urllib.parse.urlparse(url)
    conn = http.client.HTTPConnection(u.hostname, u.port, timeout=30)
    conn.request("GET", "/v1/models")
    body = json.loads(conn.getresponse().read())
    return body["data"][0]["id"]


def one_request(url, model, prompt, max_tokens, result):
    u = urllib.parse.urlparse(url)
    payload = json.dumps({
        "model": model, "stream": True, "max_tokens": max_tokens, "temperature": 0,
        "stream_options": {"include_usage": True},
        "messages": [{"role": "user", "content": prompt}],
    })
    start = time.monotonic()
    result.update(start=start, first=None, end=None, tokens=0, chunks=0, error=None)
    try:
        conn = http.client.HTTPConnection(u.hostname, u.port, timeout=300)
        conn.request("POST", "/v1/chat/completions", body=payload, headers={"Content-Type": "application/json"})
        resp = conn.getresponse()
        if resp.status != 200:
            result["error"] = "HTTP %d: %s" % (resp.status, resp.read()[:300].decode("utf-8", "replace"))
            return
        for raw in resp:
            line = raw.decode("utf-8", "replace").strip()
            if not line.startswith("data:"):
                continue
            data = line[5:].strip()
            if data == "[DONE]":
                break
            chunk = json.loads(data)
            if chunk.get("error"):
                result["error"] = json.dumps(chunk["error"])[:300]
                break
            for choice in chunk.get("choices") or []:
                if (choice.get("delta") or {}).get("content"):
                    result["chunks"] += 1
                    if result["first"] is None:
                        result["first"] = time.monotonic()
            usage = chunk.get("usage")
            if usage:
                result["tokens"] = usage.get("completion_tokens", 0)
        if not result["tokens"]:
            result["tokens"] = result["chunks"]
    except Exception as exc:  # recorded, the run goes on
        result["error"] = "%s: %s" % (type(exc).__name__, exc)
    finally:
        result["end"] = time.monotonic()


def run_wave(url, model, prompts, concurrency, max_tokens, offset):
    results = [dict() for _ in range(concurrency)]
    threads = [
        threading.Thread(target=one_request, args=(url, model, prompts[(offset + i) % len(prompts)], max_tokens, results[i]))
        for i in range(concurrency)
    ]
    for t in threads:
        t.start()
    for t in threads:
        t.join()
    ok = [r for r in results if not r["error"]]
    wall = max(r["end"] for r in results) - min(r["start"] for r in results)
    per_request = [r["tokens"] / (r["end"] - r["start"]) for r in ok if r["end"] > r["start"]]
    decode = [(r["tokens"] - 1) / (r["end"] - r["first"]) for r in ok if r["first"] and r["end"] > r["first"] and r["tokens"] > 1]
    ttft = [(r["first"] - r["start"]) * 1000 for r in ok if r["first"]]
    return {
        "concurrency": concurrency,
        "wall_s": round(wall, 3),
        "completion_tokens": sum(r["tokens"] for r in ok),
        "total_tok_s": round(sum(r["tokens"] for r in ok) / wall, 2) if wall > 0 else 0,
        "per_request_tok_s": [round(x, 2) for x in per_request],
        "decode_tok_s": [round(x, 2) for x in decode],
        "ttft_ms": [round(x, 1) for x in ttft],
        "errors": [r["error"] for r in results if r["error"]],
    }


def median(xs):
    return round(statistics.median(xs), 2) if xs else None


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--url", required=True)
    ap.add_argument("--prompts", required=True)
    ap.add_argument("--levels", default="1,4,8")
    ap.add_argument("--max-tokens", type=int, default=128)
    ap.add_argument("--rounds", type=int, default=2)
    ap.add_argument("--label", default="run")
    ap.add_argument("--out", required=True)
    ap.add_argument("--extra", default="{}", help="JSON object merged into the result (link round trip, versions)")
    args = ap.parse_args()

    prompts = json.load(open(args.prompts))
    model = model_id(args.url)
    # Warm-up request, not counted.
    warm = run_wave(args.url, model, prompts, 1, 16, 0)
    if warm["errors"]:
        sys.exit("warm-up request failed: %s" % warm["errors"][0])

    levels = []
    for c in [int(x) for x in args.levels.split(",")]:
        waves = [run_wave(args.url, model, prompts, c, args.max_tokens, r * c) for r in range(args.rounds)]
        per_request = [x for w in waves for x in w["per_request_tok_s"]]
        decode = [x for w in waves for x in w["decode_tok_s"]]
        ttft = [x for w in waves for x in w["ttft_ms"]]
        levels.append({
            "concurrency": c,
            "total_tok_s_median": median([w["total_tok_s"] for w in waves]),
            "per_request_tok_s_median": median(per_request),
            "decode_tok_s_median": median(decode),
            "ttft_ms_median": median(ttft),
            "ttft_ms_max": round(max(ttft), 1) if ttft else None,
            "errors": sum(len(w["errors"]) for w in waves),
            "waves": waves,
        })
        print("concurrency %d: total %s tok/s, per request %s tok/s, TTFT %s ms, errors %d" % (
            c, levels[-1]["total_tok_s_median"], levels[-1]["per_request_tok_s_median"],
            levels[-1]["ttft_ms_median"], levels[-1]["errors"]), flush=True)

    result = {
        "schema": "shard-poc-2417.result.v1",
        "label": args.label,
        "model": model,
        "max_tokens": args.max_tokens,
        "rounds": args.rounds,
        "temperature": 0,
        "levels": levels,
    }
    result.update(json.loads(args.extra))
    with open(args.out + "/results.json", "w") as f:
        json.dump(result, f, indent=2)

    rtt = result.get("link_round_trip") or {}
    lines = [
        "| run | in flight | total tok/s | per-request tok/s | decode tok/s | TTFT p50 ms | TTFT max ms | errors |",
        "|---|---|---|---|---|---|---|---|",
    ]
    for lv in levels:
        lines.append("| %s | %d | %s | %s | %s | %s | %s | %d |" % (
            args.label, lv["concurrency"], lv["total_tok_s_median"], lv["per_request_tok_s_median"],
            lv["decode_tok_s_median"], lv["ttft_ms_median"], lv["ttft_ms_max"], lv["errors"]))
    lines.append("")
    lines.append("Medians over %d rounds, %d output tokens per request, greedy." % (args.rounds, args.max_tokens))
    if rtt:
        lines.append("Link round trip (%s): %s" % (rtt.get("source", "?"), rtt.get("summary", "not measured")))
    with open(args.out + "/results.md", "w") as f:
        f.write("\n".join(lines) + "\n")
    print("\n".join(lines))


if __name__ == "__main__":
    main()
