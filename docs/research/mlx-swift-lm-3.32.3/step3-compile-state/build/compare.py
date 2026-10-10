# Lab-only: compare content hashes per (cell, block, path) between a run and a reference run.
import json, sys
def load(run):
    out = {}
    for l in open(run + '/out.jsonl'):
        r = json.loads(l)
        if r.get('record_type') != 'run': continue
        out[(r['cell_id'], r['block_index'], r['path'])] = (
            r['request_metrics'][0]['content_sha256'][:12],
            (r['mtp_accepted_tokens'], r['mtp_proposed_tokens']) if r['path'] == 'native_mtp' else None)
    return out
a, ref = load(sys.argv[1]), load(sys.argv[2])
same = diff = 0
for k in sorted(set(a) & set(ref)):
    if a[k][0] == ref[k][0]: same += 1
    else:
        diff += 1
        print('  DIFF', k, 'run', a[k], 'ref', ref[k])
print(f"{sys.argv[1]} vs {sys.argv[2]}: compared={same+diff} identical={same} different={diff}")
