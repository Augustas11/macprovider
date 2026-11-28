#!/usr/bin/env python3
"""Verdict table for one mlx-0325 window (window.sh OUT dir).

usage: summary.py OUT
Per pass and cell: base1, new and base2 throughput (aggregate tok/s for several rows, decode tok/s
for one), new's delta against each control, the cell's noise band, TTFT, text identity against
base1, and for the mtp pass the native-MTP acceptance of each run and new's text against ref
(R015). A cell is KEEP when new beats BOTH neighbouring controls by more than the band, LOSS when
it is slower than both beyond the band, else FLAT. Prints MLX0325_ROW lines and one MLX0325_VERDICT.
"""
import json, os, sys

def load(p):
    try:
        return json.load(open(p))
    except (OSError, ValueError):
        return None

def cells(doc):
    return {(c["ctx"], c["out"], c["rows"]): c for c in (doc or {}).get("cells", []) if "ours_tps" in c}

def acceptance(jsonl):
    prop = acc = 0
    try:
        for line in open(jsonl):
            try:
                m = json.loads(line).get("native_mtp") or {}
            except ValueError:
                continue
            prop += int(m.get("proposed_tokens") or 0); acc += int(m.get("accepted_tokens") or 0)
    except OSError:
        return None
    return round(acc / prop, 3) if prop else None

def main():
    out = sys.argv[1]
    verdicts = []
    for model in sorted(os.listdir(out)):
        for pss in ("cb", "mtp"):
            M = os.path.join(out, model, pss)
            if not os.path.isdir(M):
                continue
            a = cells(load(os.path.join(M, "compare-new-vs-base1.json")))
            b = cells(load(os.path.join(M, "compare-new-vs-base2.json")))
            ref = cells(load(os.path.join(M, "compare-new-vs-ref.json")))
            accs = {t: acceptance(os.path.join(M, t, "provider.jsonl")) for t in ("base1", "new", "base2")}
            if pss == "mtp":
                print(f"MLX0325_ACCEPT {model} mtp base1={accs['base1']} new={accs['new']} base2={accs['base2']}")
            for key in sorted(a):
                c1, c2 = a[key], b.get(key)
                if not c2:
                    continue
                n, b1, b2 = c1["ours_tps"], c1["ref_tps"], c2["ref_tps"]
                band = max(c1.get("band") or 0.03, c2.get("band") or 0.03)
                d1, d2 = n / b1 - 1, n / b2 - 1
                v = "KEEP" if min(d1, d2) > band else "LOSS" if max(d1, d2) < -band else "FLAT"
                verdicts.append(v)
                r015 = ""
                if pss == "mtp":
                    rc = ref.get(key)
                    r015 = f" r015_text={'identical' if rc and rc.get('identical') else 'DIFFERS' if rc else 'n/a'}"
                print(f"MLX0325_ROW {model} {pss} ctx{key[0]} out{key[1]} rows{key[2]} "
                      f"base1={b1:.2f} new={n:.2f} base2={b2:.2f} d1={d1:+.1%} d2={d2:+.1%} band={band:.1%} "
                      f"ttft_new={c1.get('ours_ttft_s')} ttft_base1={c1.get('ref_ttft_s')} "
                      f"text_vs_base1={'identical' if c1.get('identical') else 'differs'}{r015} {v}")
    keep, loss = verdicts.count("KEEP"), verdicts.count("LOSS")
    overall = "KEEP" if keep and not loss else "LOSS" if loss and not keep else "MIXED" if keep else "FLAT"
    print(f"MLX0325_VERDICT {overall} keep={keep} flat={verdicts.count('FLAT')} loss={loss} cells={len(verdicts)}")

if __name__ == "__main__":
    main()
