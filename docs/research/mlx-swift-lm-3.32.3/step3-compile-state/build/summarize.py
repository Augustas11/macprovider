# Lab-only: per-run native/ordinary parity, acceptance and stale-hit summary.
import json, sys, gzip, re, os
from collections import defaultdict
for run in sys.argv[1:]:
    p = os.path.join(run, 'out.jsonl')
    rows = [json.loads(l) for l in open(p) if l.strip()]
    runs = [r for r in rows if r.get('record_type') == 'run']
    by = defaultdict(dict)
    for r in runs:
        by[(r['cell_id'], r['block_index'])][r['path']] = r
    n = 0; bad = []; acc_all = []
    for (cell, b), d in sorted(by.items(), key=lambda x: (x[0][1] // 1000 if x[0][1] >= 0 else (-x[0][1]) // 1000, x[0][0], x[0][1])):
        if 'native_mtp' not in d or 'ordinary' not in d: continue
        nat, ordy = d['native_mtp'], d['ordinary']
        if not nat['mtp_proposed_tokens']: continue
        n += 1
        acc = nat['mtp_accepted_tokens'] / nat['mtp_proposed_tokens']; acc_all.append(acc)
        hn = nat['request_metrics'][0]['content_sha256'][:12]; ho = ordy['request_metrics'][0]['content_sha256'][:12]
        if hn != ho or acc < 0.6:
            bad.append((cell, b, round(acc, 3), f"{nat['mtp_accepted_tokens']}/{nat['mtp_proposed_tokens']}", hn, ho))
    log = open(os.path.join(run, 'bench.log'), errors='replace').read()
    hits = re.findall(r'\[lab-stale\] STALE_HIT (EQUAL|MISMATCH) (.*)', log)
    cells = len(re.findall(r'\[lab-cell\]', log))
    eq = sum(1 for h in hits if h[0] == 'EQUAL'); mm = len(hits) - eq
    print(f"{run}: cell_loads={cells} native_runs={n} anomalies={len(bad)} acc_min={min(acc_all) if acc_all else None:.3} acc_median={sorted(acc_all)[len(acc_all)//2] if acc_all else None:.3} stale_hits={len(hits)} equal={eq} mismatch={mm}")
    shapes = defaultdict(lambda: [0, 0])
    for kind, rest in hits:
        m = re.search(r'args=(\d+) arg0=(\[[^\]]*\]) state=(\d+)', rest)
        k = m.groups() if m else rest[:40]
        shapes[k][0 if kind == 'EQUAL' else 1] += 1
    for k, v in sorted(shapes.items(), key=lambda x: -sum(x[1])):
        print(f"   hit args={k[0]} arg0={k[1]} state={k[2]}: equal={v[0]} mismatch={v[1]}")
    for x in bad: print("   ANOMALY", x)
