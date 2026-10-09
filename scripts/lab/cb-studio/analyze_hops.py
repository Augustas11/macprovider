#!/usr/bin/env python3
"""Split CB serve wall time into decode, prefill and gaps from cbtrace hop lines.

usage: analyze_hops.py <serve.log> [skip_seconds]
"""
import collections
import re
import sys

path = sys.argv[1]
skip = float(sys.argv[2]) if len(sys.argv) > 2 else 60.0
pat = re.compile(r"cbtrace t=(\d+) rid=\S+ ev=hop_(decode|prefill) (.*)")
hops = []
for line in open(path, errors="replace"):
    m = pat.match(line)
    if not m:
        continue
    kv = dict(x.split("=", 1) for x in m.group(3).split())
    end = int(m.group(1))
    hops.append((end - int(kv["ms"]), end, m.group(2), kv))
if not hops:
    sys.exit("no hop lines")
t0 = hops[0][0] + skip * 1000
hops = [h for h in hops if h[0] >= t0]
wall = hops[-1][1] - hops[0][0]
busy = collections.Counter()
gap = 0
prev_end = None
steps_hist = collections.Counter()
decode_steps = 0
per_step = collections.defaultdict(list)
for start, end, kind, kv in hops:
    busy[kind] += end - start
    if prev_end is not None and start > prev_end:
        gap += start - prev_end
    prev_end = end
    if kind == "decode":
        steps = int(kv["steps"])
        steps_hist[steps] += 1
        decode_steps += steps
        per_step[int(kv["rows"])].append((end - start) / steps)
print(f"window {wall/1000:.1f}s hops={len(hops)}")
for kind in ("decode", "prefill"):
    print(f"{kind:8} {busy[kind]/1000:7.1f}s {100*busy[kind]/wall:5.1f}%")
print(f"gaps     {gap/1000:7.1f}s {100*gap/wall:5.1f}%")
print("decode window steps:", dict(sorted(steps_hist.items())))
for rows, v in sorted(per_step.items()):
    v.sort()
    print(f"rows={rows:2} windows={len(v):4} ms/step p50={v[len(v)//2]:.1f}")
