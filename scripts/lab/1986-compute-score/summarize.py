import json, statistics, sys
# usage: summarize.py report.json [...] -> per-class rows against the cold prior and hard floors
P = dict(pg_t1=0.85, pg_lp=-1.0, ps_lp=-4.0, hg_t1=0.50, hg_lp=-3.0, hs_lp=-6.0)
def cls_of(i):
    return "greedy" if i["id"].endswith("greedy") else ("hot" if i["id"].endswith("t1.0") else "sampled")
for f in sys.argv[1:]:
    d = json.load(open(f))
    for cls in ("greedy", "sampled", "hot"):
        it = [i for i in d["items"] if cls_of(i) == cls and i.get("mean_logprob") is not None and i["scored_tokens"] >= 16]
        if not it:
            continue
        lp = sorted(i["mean_logprob"] for i in it); t1 = sorted(i["top1_rate"] for i in it)
        if cls == "greedy":
            prior = sum(i["top1_rate"] >= P["pg_t1"] and i["mean_logprob"] >= P["pg_lp"] for i in it)
            hard = sum(i["top1_rate"] >= P["hg_t1"] and i["mean_logprob"] >= P["hg_lp"] for i in it)
        elif cls == "sampled":
            prior = sum(i["mean_logprob"] >= P["ps_lp"] for i in it); hard = sum(i["mean_logprob"] >= P["hs_lp"] for i in it)
        else:
            prior = hard = sum(i["mean_logprob"] >= P["hs_lp"] for i in it)
        print(f"{f}\t{d['chip']}\t{d['generator_chip']}\t{cls}\tn={len(it)}\tprior={prior}/{len(it)}\thard={hard}/{len(it)}\tlp_min={lp[0]:.3f}\tlp_p50={statistics.median(lp):.3f}\tt1_min={t1[0]:.3f}\tt1_p50={statistics.median(t1):.3f}")
    ul = d.get("under_load")
    if ul:
        print(f"{f}\tunder_load\t{json.dumps(ul)}")
