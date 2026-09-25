#!/usr/bin/env python3
"""Per-invariant pass/total per label (#1690 e2e results)."""
import json, pathlib, sys
INV = ["no_hold", "debit_eq_settled", "credit_has_evidence", "credit_implies_debit", "no_undelivered_bill",
       "delivered_not_free", "buyer_usage_eq_debit", "stream_complete"]
print("| Label | " + " | ".join(INV) + " |")
print("|---|" + "---|" * len(INV))
for lab in sys.argv[1:]:
    for f in sorted(pathlib.Path(lab, "e2e", "results").glob("*.json")):
        d = json.loads(f.read_text())
        cnt = {i: [0, 0] for i in INV}
        for r in d["results"]:
            for c in r["checks"]:
                k = c["check"].split("[")[0].replace("(info)", "")
                if k in cnt:
                    cnt[k][1] += 1
                    cnt[k][0] += bool(c["ok"])
        print(f"| {d['label']} | " + " | ".join((f"{p}/{t}" if t else "-") for p, t in cnt.values()) + " |")
