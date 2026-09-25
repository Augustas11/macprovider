#!/usr/bin/env python3
"""Compare the per-kind outcome shape of two oracle reports (baseline vs a
pairing): for each request kind the multiset of (reservation status, debit>0,
payable>0). Prints both and exits 1 on any difference."""
import json, sys
def shape(p):
    d = json.load(open(p)); out = {}
    for r in d["rows"]:
        out.setdefault(r["kind"], []).append("%s/debit=%s/payable=%s" % (r["res_status"], r["debit_tokens"] > 0, r["payable_tokens"] > 0))
    return {k: sorted(v) for k, v in out.items()}
a, b = shape(sys.argv[1]), shape(sys.argv[2])
out = sys.argv[2].replace(".oracle.json", ".shape.txt")
with open(out, "w") as f:
    for k in sorted(set(a) | set(b)):
        f.write("%-6s base=%s\n       this=%s %s\n" % (k, a.get(k), b.get(k), "" if a.get(k) == b.get(k) else "  <-- DIFF"))
print(open(out).read())
sys.exit(0 if a == b else 1)
