#!/usr/bin/env python3
"""Ragged grouped-prefill probe on an isolated lab serve (loopback only).

Rows of different prompt lengths arrive together or staggered behind a
decoding anchor row, so the continuous-batching scheduler sees prompt rows at
different offsets and chunk lengths at once (SPEC-038 FR-CB2 ragged shared
prefill). Every row's greedy output (reasoning + content) is compared exactly
with the same request sent alone. Run the serve with MACPROVIDER_CB_TRACE=1 and
count `prefill_shared ... ragged=true` lines to see which groups formed.

Sets:
  short    four prompts of 30-130 tokens with different lengths, sent together;
           with PGP_KEYED=1 each carries a fresh `conv:` key, so a hybrid model
           prefills each prompt up to its last <|im_start|> and then a short
           tail chunk at a row-specific offset.
  long     four prompts of 400-700 tokens with different lengths, sent
           STAGGER_MS apart, so later rows start while earlier rows are
           mid-prompt (512-token chunk limit; default delays 0/150/400/800 ms).
  same     four copies of one ~1300-token prompt, sent STAGGER_MS apart: the
           rows share one balanced chunk length at different offsets, so they
           can form ragged groups above every grouping bound.
usage: ragged_prefill_probe.py <port> <model> <out.json>
"""
import json, os, sys, time, threading, urllib.request, uuid

PORT, MODEL, OUT = int(sys.argv[1]), sys.argv[2], sys.argv[3]
KEYED = os.environ.get("PGP_KEYED") == "1"
SETS = os.environ.get("RPP_SETS", "short,long,same").split(",")
TRIALS = int(os.environ.get("RPP_TRIALS", "3"))
STAGGER_MS = [int(x) for x in os.environ.get("RPP_STAGGER_MS", "0,150,400,800").split(",")]
MAXT = int(os.environ.get("RPP_MAX_TOKENS", "48"))
WORDS = ["river", "copper", "lantern", "orchard", "glacier", "harbor", "violet", "meadow",
         "falcon", "pepper", "marble", "canyon", "willow", "ember", "saddle", "thistle"]
FILLERS = {"short": [14, 30, 52, 80], "long": [300, 380, 450, 520], "same": [1000, 1000, 1000, 1000]}


def stream(body, rid):
    req = urllib.request.Request(f"http://127.0.0.1:{PORT}/v1/chat/completions",
                                 data=json.dumps(dict(body, stream=True)).encode(), method="POST")
    req.add_header("Content-Type", "application/json")
    req.add_header("X-Request-ID", rid)
    if KEYED and not rid.startswith("lab-anchor"):
        req.add_header("X-MacProvider-Provider-Conversation", f"conv:lab-{uuid.uuid4()}")
    t0 = time.time(); first = None; reasoning = []; content = []; usage = None
    with urllib.request.urlopen(req, timeout=900) as r:
        for raw in r:
            line = raw.decode().strip()
            if not line.startswith("data:"):
                continue
            data = line[5:].strip()
            if data == "[DONE]":
                break
            ev = json.loads(data)
            if ev.get("usage"):
                usage = ev["usage"]
            for ch in ev.get("choices", []):
                d = ch.get("delta", {})
                r_, c_ = d.get("reasoning_content") or "", d.get("content") or ""
                if r_ or c_:
                    if first is None:
                        first = time.time()
                    reasoning.append(r_); content.append(c_)
    return {"text": "".join(reasoning) + "\x01" + "".join(content), "first": first, "t0": t0, "usage": usage}


def body(content, max_tokens):
    return {"model": MODEL, "temperature": 0, "max_tokens": max_tokens,
            "stream_options": {"include_usage": True},
            "messages": [{"role": "user", "content": content}]}


def prompt(i, filler_words):
    w = WORDS[i % len(WORDS)]
    filler = " ".join(WORDS[(i + j) % len(WORDS)] for j in range(filler_words))
    return f"Note {w}. Words: {filler}. Write one short sentence about {w}."


def main():
    res = {"keyed": KEYED, "alone": {}, "groups": []}
    members = {s: [(0 if s == "same" else i, fw) for i, fw in enumerate(FILLERS[s])] for s in SETS}
    for s in SETS:
        for i, fw in members[s]:
            key = f"{fw}:{i}"
            if key in res["alone"]:
                continue
            res["alone"][key] = stream(body(prompt(i, fw), MAXT), f"lab-alone-{fw}-{i}-{uuid.uuid4()}")
            res["alone"][key]["prompt_tokens"] = res["alone"][key]["usage"]["prompt_tokens"]
    print("alone", {k: v["prompt_tokens"] for k, v in res["alone"].items()}, flush=True)
    anchor_body = body("Count slowly from one to two hundred, one number per line.", 600)
    for s in SETS:
        stagger = [0] * len(members[s]) if s == "short" else STAGGER_MS
        for trial in range(TRIALS):
            out = {}
            anchor = threading.Thread(target=lambda: stream(anchor_body, f"lab-anchor-{uuid.uuid4()}"))
            anchor.start(); time.sleep(2.0)
            barrier = threading.Barrier(len(members[s]))

            def run(k, i, fw):
                barrier.wait()
                time.sleep(stagger[k] / 1000.0)
                out[k] = stream(body(prompt(i, fw), MAXT), f"lab-rg-{fw}-{i}-{uuid.uuid4()}")

            th = [threading.Thread(target=run, args=(k, i, fw)) for k, (i, fw) in enumerate(members[s])]
            [t.start() for t in th]; [t.join() for t in th]
            anchor.join()
            # Row label: member slot and its alone key ("slot/filler:prompt").
            alone = {f"{k}/{fw}:{i}": f"{fw}:{i}" for k, (i, fw) in enumerate(members[s])}
            slot = {label: int(label.split("/")[0]) for label in alone}
            row = {"set": s, "trial": trial,
                   "prompt_tokens": {l: res["alone"][a]["prompt_tokens"] for l, a in alone.items()},
                   "match": {l: out[slot[l]]["text"] == res["alone"][a]["text"] for l, a in alone.items()},
                   "texts": {l: out[slot[l]]["text"] for l in alone}}
            res["groups"].append(row)
            print(json.dumps({k: v for k, v in row.items() if k != "texts"}), flush=True)
    res["summary"] = {
        "group_runs": len(res["groups"]),
        "rows": sum(len(g["match"]) for g in res["groups"]),
        "row_mismatches": sum(1 for g in res["groups"] for v in g["match"].values() if not v),
        "by_set": {s: sum(1 for g in res["groups"] if g["set"] == s for v in g["match"].values() if not v)
                   for s in SETS},
    }
    print("summary", res["summary"], flush=True)
    json.dump(res, open(OUT, "w"), indent=1)


main()
