import json, sys
# Per run: cell, path, block, parity, errors, peak footprint, min available, and
# per-request inter-chunk gaps above 30 ms with the chunk index they follow.
for f in sys.argv[1:]:
    tag = f.split('/')[-1].split('.')[0]
    for line in open(f):
        r = json.loads(line)
        if r.get('record_type') != 'run':
            continue
        big = []
        for q, gaps in enumerate(r['raw_inter_token_gaps_seconds']):
            big.append([(i, round(g * 1000, 1)) for i, g in enumerate(gaps) if g > 0.03])
        print(tag, r['cell_id'], r['path'], 'block', r['block_index'], 'warmup', r['warmup'],
              'tokens', r['committed_completion_tokens'], 'parity_mismatch', r['parity_mismatch'],
              'errors', r['errors'], 'fallbacks', r['fallbacks'],
              'peak_footprint_GB %.3f' % (r['peak_phys_footprint_bytes'] / 1e9),
              'min_avail %.3f' % r['min_available_memory_fraction'],
              'decode_tps %.1f' % r['aggregate_decode_tps'],
              'gaps>30ms', big)
