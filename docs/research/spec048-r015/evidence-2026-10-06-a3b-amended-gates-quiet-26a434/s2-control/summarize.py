import json,sys,statistics as st
def pct(v,q):
    v=sorted(v); 
    if not v: return None
    p=(len(v)-1)*q; lo=int(p); hi=min(lo+1,len(v)-1); return v[lo]+(v[hi]-v[lo])*(p-lo)
rows={}
for f in sys.argv[1:]:
    tag=f.split('/')[-1].split('.')[0]
    for line in open(f):
        r=json.loads(line)
        if r.get('record_type')!='run' or r.get('warmup'): continue
        rows.setdefault((tag[:3],r['cell_id'],r['path']),[]).append((tag,r))
for key in sorted(rows):
    rs=[r for _,r in rows[key]]
    dec=[r['aggregate_decode_tps'] for r in rs]
    tpot=[pct([1/x for x in r['per_request_decode_tps']],.95)*1000 for r in rs]
    gaps=[g for r in rs for l in r['raw_inter_token_gaps_seconds'] for g in l]
    big=sum(1 for g in gaps if g>0.03)
    print(key, 'n',len(rs),'decode med %.1f'%st.median(dec),'tpot95 med %.2f'%st.median(tpot),'gap p50 %.2f p95 %.2f p99 %.2f max %.1f'%tuple(x*1000 for x in (pct(gaps,.5),pct(gaps,.95),pct(gaps,.99),max(gaps))),'gaps>30ms',big,'/',len(gaps))
# paired ratios
for tagset in ('old','new'):
  for cell in sorted({k[1] for k in rows}):
    o={(t,r['block_index']):r for t,r in rows.get((tagset,cell,'ordinary'),[])}
    n={(t,r['block_index']):r for t,r in rows.get((tagset,cell,'native_mtp'),[])}
    rat=[n[k]['aggregate_decode_tps']/o[k]['aggregate_decode_tps'] for k in o if k in n]
    tr=[pct([1/x for x in n[k]['per_request_decode_tps']],.95)/pct([1/x for x in o[k]['per_request_decode_tps']],.95) for k in o if k in n]
    if rat: print(tagset,cell,'decode ratio median %.4f mean %.4f min %.3f max %.3f'%(st.median(rat),st.mean(rat),min(rat),max(rat)),'tpot ratio med %.4f'%st.median(tr), 'n',len(rat))
