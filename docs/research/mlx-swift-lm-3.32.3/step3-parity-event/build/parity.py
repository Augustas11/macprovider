import json, sys, gzip
from collections import defaultdict
def load(p):
    op = gzip.open if p.endswith('.gz') else open
    with op(p, 'rt') as f:
        return [json.loads(l) for l in f if l.strip()]
tot_nat = 0; bad = []
for p in sys.argv[1:]:
    rows = [r for r in load(p) if r.get('record_type') == 'run']
    by = defaultdict(dict)
    for r in rows:
        by[(r['cell_id'], r['block_index'])][r['path']] = r
    n = 0
    for (cell, b), d in sorted(by.items()):
        if 'native_mtp' not in d or 'ordinary' not in d: continue
        nat, ordy = d['native_mtp'], d['ordinary']
        if not nat['mtp_proposed_tokens']: continue
        n += 1
        acc = nat['mtp_accepted_tokens'] / nat['mtp_proposed_tokens']
        hn = nat['request_metrics'][0]['content_sha256'][:12]; ho = ordy['request_metrics'][0]['content_sha256'][:12]
        if hn != ho or nat['parity_mismatch'] or acc < 0.6:
            bad.append((p, cell, b, nat['order_position'], round(acc, 3), hn, ho, nat['parity_mismatch']))
    tot_nat += n
    print(f"{p}: native runs with verify rounds={n}")
print("total", tot_nat, "anomalies", len(bad))
for x in bad: print("  ANOMALY", x)
