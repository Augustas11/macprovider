import json, statistics, sys
# usage: warmband.py train1.json,train2.json,... test.json ...  (greedy and sampled; hot uses the hard floor only)
def cls_of(i):
    return "greedy" if i["id"].endswith("greedy") else ("hot" if i["id"].endswith("t1.0") else "sampled")
def ok(i): return i.get("mean_logprob") is not None and i["scored_tokens"] >= 16
train = [i for f in sys.argv[1].split(",") for i in json.load(open(f))["items"] if ok(i)]
def floor(v, m):
    med = statistics.median(v); mad = statistics.median(abs(x - med) for x in v)
    return med - max(6 * mad, m)
for cls in ("greedy", "sampled", "hot"):
    rows = [i for i in train if cls_of(i) == cls]
    if cls == "hot":
        lp, t1 = -6.0, None
    else:
        lp = max(floor([i["mean_logprob"] for i in rows], 0.25), {"greedy": -3.0, "sampled": -6.0}[cls])
        t1 = max(floor([i["top1_rate"] for i in rows], 0.05), 0.50) if cls == "greedy" else None
    print(f"{cls}: train n={len(rows)} logprob_floor={lp:.3f}" + (f" top1_floor={t1:.3f}" if t1 is not None else ""))
    for f in sys.argv[2:]:
        test = [i for i in json.load(open(f))["items"] if cls_of(i) == cls and ok(i)]
        inside = [i for i in test if i["mean_logprob"] >= lp and (t1 is None or i["top1_rate"] >= t1)]
        print(f"   {f}: in_band {len(inside)}/{len(test)} ({100*len(inside)/max(1,len(test)):.1f}%)")
