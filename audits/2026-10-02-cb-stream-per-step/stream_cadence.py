#!/usr/bin/env python3
"""Buyer-observed stream cadence + throughput on the batched (CB) route.
usage: stream_cadence.py PORT MODEL CONCURRENCY[,..] MAX_TOKENS REPS"""
import http.client, json, sys, threading, time, uuid, statistics
PORT = int(sys.argv[1]); MODEL = sys.argv[2]
CONCS = [int(x) for x in sys.argv[3].split(",")]; MAXT = int(sys.argv[4]); REPS = int(sys.argv[5])
TOPICS = ["rivers", "volcanoes", "bridges", "orchards", "glaciers", "harbors", "deserts", "libraries",
          "lighthouses", "railways", "forests", "observatories"]

def one(i, out):
    p = (f"[{uuid.uuid4().hex}] Write a long, detailed essay about {TOPICS[i % len(TOPICS)]}. "
         "Use many paragraphs and do not stop early.")
    h = {"Content-Type": "application/json", "X-Request-ID": "cad-" + uuid.uuid4().hex[:16]}
    c = http.client.HTTPConnection("127.0.0.1", PORT, timeout=3600)
    t0 = time.monotonic()
    c.request("POST", "/v1/chat/completions", json.dumps({
        "model": MODEL, "messages": [{"role": "user", "content": p}], "max_tokens": MAXT,
        "temperature": 0, "stream": True, "stream_options": {"include_usage": True}}), h)
    r = c.getresponse(); arrivals = []; usage = {}; status = r.status; finish = None
    while True:
        line = r.readline()
        if not line: break
        if not line.startswith(b"data:"): continue
        d = line[5:].strip()
        if d == b"[DONE]": break
        j = json.loads(d)
        if j.get("usage"): usage = j["usage"]
        for ch in j.get("choices") or []:
            if ch.get("finish_reason"): finish = ch["finish_reason"]
            if (ch.get("delta") or {}).get("content"):
                arrivals.append(time.monotonic())
    out[i] = {"status": status, "t0": t0, "end": time.monotonic(), "arrivals": arrivals,
              "completion_tokens": usage.get("completion_tokens", 0), "finish": finish}

def pct(xs, q):
    xs = sorted(xs); return xs[min(len(xs) - 1, int(q * (len(xs) - 1) + 0.5))] if xs else None

for conc in CONCS:
    for rep in range(REPS):
        out = [None] * conc
        ts = [threading.Thread(target=one, args=(i, out)) for i in range(conc)]
        for t in ts: t.start()
        for t in ts: t.join()
        gaps = []; decode_rates = []
        for o in out:
            a = o["arrivals"]
            gaps += [(a[k + 1] - a[k]) * 1000 for k in range(len(a) - 1)]
            if len(a) > 1 and o["completion_tokens"] > 1:
                decode_rates.append((o["completion_tokens"] - 1) / (a[-1] - a[0]))
        wall = max(o["end"] for o in out) - min(o["t0"] for o in out)
        toks = sum(o["completion_tokens"] for o in out)
        print(json.dumps({"conc": conc, "rep": rep, "statuses": sorted({o["status"] for o in out}),
            "finish": sorted({str(o["finish"]) for o in out}), "completion_tokens": toks,
            "wall_s": round(wall, 2), "agg_tok_s": round(toks / wall, 1),
            "decode_tok_s_per_row_mean": round(statistics.mean(decode_rates), 1) if decode_rates else None,
            "decode_tok_s_sum": round(sum(decode_rates), 1),
            "chunks": sum(len(o["arrivals"]) for o in out),
            "gap_ms_p50": round(pct(gaps, .5), 1), "gap_ms_p90": round(pct(gaps, .9), 1),
            "gap_ms_p99": round(pct(gaps, .99), 1), "gap_ms_max": round(max(gaps), 1),
            "gaps_over_50ms_frac": round(sum(g > 50 for g in gaps) / len(gaps), 3)}), flush=True)
