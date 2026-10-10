#!/usr/bin/env python3
"""Grouped-prefill route probe on an isolated lab serve (loopback only).

Greedy short prompts (32-127 prompt tokens) run alone and then concurrently in
equal-length pairs and quads behind a decoding anchor row, so the scheduler
admits them in one pass with one cursor and one chunk length. Outputs are
compared exactly (reasoning + content). First-delta times show whether the
rows prefilled in one forward (same instant) or one after another.
usage: prefill_group_probe.py <port> <model> <out.json>
"""
import json, os, sys, time, threading, urllib.request, uuid

PORT, MODEL, OUT = int(sys.argv[1]), sys.argv[2], sys.argv[3]
# PGP_KEYED=1: every non-anchor request carries its own fresh conversation key, so a
# hybrid model checkpoints at the last <|im_start|> and prefills the generation
# prompt (about 5 tokens) as its own final chunk; equal-length rows share that cursor.
KEYED = os.environ.get("PGP_KEYED") == "1"
DECODE8 = os.environ.get("PGP_DECODE8", "1") == "1"
WORDS = ["river", "copper", "lantern", "orchard", "glacier", "harbor", "violet", "meadow",
         "falcon", "pepper", "marble", "canyon", "willow", "ember", "saddle", "thistle"]

def stream(body, rid):
    req = urllib.request.Request(f"http://127.0.0.1:{PORT}/v1/chat/completions",
                                 data=json.dumps(dict(body, stream=True)).encode(), method="POST")
    req.add_header("Content-Type", "application/json"); req.add_header("X-Request-ID", rid)
    if KEYED and not rid.startswith("lab-anchor"):
        req.add_header("X-MacProvider-Provider-Conversation", f"conv:lab-{uuid.uuid4()}")
    t0 = time.time(); first = None; reasoning = []; content = []; usage = None; finish = None
    with urllib.request.urlopen(req, timeout=900) as r:
        for raw in r:
            line = raw.decode().strip()
            if not line.startswith("data:"): continue
            data = line[5:].strip()
            if data == "[DONE]": break
            ev = json.loads(data)
            if ev.get("usage"): usage = ev["usage"]
            for ch in ev.get("choices", []):
                d = ch.get("delta", {})
                r_, c_ = d.get("reasoning_content") or "", d.get("content") or ""
                if r_ or c_:
                    if first is None: first = time.time()
                    reasoning.append(r_); content.append(c_)
                finish = ch.get("finish_reason") or finish
    return {"text": "".join(reasoning) + "\x01" + "".join(content), "first": first, "t0": t0, "usage": usage, "finish": finish}

def body(content, max_tokens):
    return {"model": MODEL, "temperature": 0, "max_tokens": max_tokens,
            "stream_options": {"include_usage": True},
            "messages": [{"role": "user", "content": content}]}

def prompt(i, filler_words):
    w = WORDS[i % len(WORDS)]
    filler = " ".join(WORDS[(i + j) % len(WORDS)] for j in range(filler_words))
    return f"Note {w}. Words: {filler}. Write one short sentence about {w}."

def main():
    res = {"alone": {}, "groups": []}
    # Calibrate lengths: identical filler size per bucket, one varying word.
    buckets = {}
    FILLERS = [int(x) for x in os.environ.get("PGP_FILLERS", "12,40,80").split(",")]
    LO, HI = int(os.environ.get("PGP_MIN", "32")), int(os.environ.get("PGP_MAX", "127"))
    for fw in FILLERS:
        for i in range(16):
            r = stream(body(prompt(i, fw), 1), f"lab-cal-{fw}-{i}-{uuid.uuid4()}")
            n = r["usage"]["prompt_tokens"]
            buckets.setdefault((fw, n), []).append(i)
    plan = []
    for (fw, n), ids in sorted(buckets.items()):
        if LO <= n <= HI and len(ids) >= 4:
            plan.append((fw, n, ids[:4]))
    res["plan"] = [{"filler": fw, "prompt_tokens": n, "ids": ids} for fw, n, ids in plan]
    print("plan", res["plan"], flush=True)
    MAXT = 48
    for fw, n, ids in plan:
        for i in ids:
            key = f"{fw}:{i}"
            res["alone"][key] = stream(body(prompt(i, fw), MAXT), f"lab-alone-{fw}-{i}-{uuid.uuid4()}")
    anchor_body = body("Count slowly from one to two hundred, one number per line.", 600)
    for fw, n, ids in plan:
        for size in (2, 4):
            for trial in range(3):
                members = ids[:size]
                out = {}
                stop = threading.Event()
                anchor = threading.Thread(target=lambda: stream(anchor_body, f"lab-anchor-{uuid.uuid4()}"))
                anchor.start(); time.sleep(2.0)
                barrier = threading.Barrier(size)
                def run(i):
                    barrier.wait()
                    out[i] = stream(body(prompt(i, fw), MAXT), f"lab-grp-{fw}-{i}-{uuid.uuid4()}")
                th = [threading.Thread(target=run, args=(i,)) for i in members]
                [t.start() for t in th]; [t.join() for t in th]
                anchor.join()
                firsts = [out[i]["first"] for i in members]
                row = {"filler": fw, "prompt_tokens": n, "size": size, "trial": trial,
                       "first_delta_spread_ms": round((max(firsts) - min(firsts)) * 1000, 1),
                       "match": {str(i): out[i]["text"] == res["alone"][f"{fw}:{i}"]["text"] for i in members},
                       "completion_tokens_match": {str(i): out[i]["usage"]["completion_tokens"] == res["alone"][f"{fw}:{i}"]["usage"]["completion_tokens"] for i in members},
                       "texts": {str(i): out[i]["text"] for i in members}}
                res["groups"].append(row)
                print(json.dumps({k: v for k, v in row.items() if k != "texts"}), flush=True)
    # Eight decode rows (anchor + 7 mixed-length rows): 64 expert selections
    # per decode step, the SwitchGLU sort / direct-reduction bound.
    keys = list(res["alone"])[:7]
    for trial in range(2 if DECODE8 else 0):
        out = {}
        anchor = threading.Thread(target=lambda: stream(anchor_body, f"lab-anchor-{uuid.uuid4()}"))
        anchor.start(); time.sleep(2.0)
        barrier = threading.Barrier(len(keys))
        def run8(key):
            fw, i = map(int, key.split(":"))
            barrier.wait()
            out[key] = stream(body(prompt(i, fw), MAXT), f"lab-d8-{fw}-{i}-{uuid.uuid4()}")
        th = [threading.Thread(target=run8, args=(k,)) for k in keys]
        [t.start() for t in th]; [t.join() for t in th]; anchor.join()
        row = {"decode8_trial": trial, "match": {k: out[k]["text"] == res["alone"][k]["text"] for k in keys},
               "texts": {k: out[k]["text"] for k in keys}}
        res.setdefault("decode8", []).append(row)
        print(json.dumps({k: v for k, v in row.items() if k != "texts"}), flush=True)
    res["summary"] = {"decode8_mismatches": sum(1 for g in res.get("decode8", []) for v in g["match"].values() if not v),
                      "group_runs": len(res["groups"]),
                      "row_mismatches": sum(1 for g in res["groups"] for v in g["match"].values() if not v)}
    print("summary", res["summary"], flush=True)
    json.dump(res, open(OUT, "w"), indent=1)

main()
