#!/usr/bin/env python3
"""#1816 e2e: from the unit journal timeline of an updater apply and the
probe-loop records, report the restart order the updater used and what a
buyer got in the window between the new coordinator starting and the new
gateway starting. Exit 0 when the gateway was stopped before the new
coordinator started and no 200 was served across that mixed window.
Usage: apply-window.py <unit-timeline.txt> <probe.load.jsonl>"""
import datetime, json, re, sys

ev = []
for line in open(sys.argv[1]):
    m = re.match(r"(\S+) \S+ systemd\[1\]: (Stopping|Stopped|Starting|Started) (macprovider-(?:coordinator|gateway))", line)
    if m:
        ev.append((datetime.datetime.fromisoformat(m.group(1)).timestamp(), m.group(2), m.group(3)))
print("unit order:", " -> ".join("%s %s" % (e[1], e[2].split("-")[1]) for e in ev))


def last(action, unit):
    xs = [e[0] for e in ev if e[1] == action and e[2] == "macprovider-" + unit]
    return xs[-1] if xs else None


c_start, g_start, g_stop = last("Started", "coordinator"), last("Started", "gateway"), last("Stopping", "gateway")
reqs = [json.loads(l) for l in open(sys.argv[2])]
win = [r for r in reqs if c_start and g_start and c_start <= r["t0"] <= g_start]
print("window new-coordinator-up .. new-gateway-up: %.1fs, buyer outcomes in it: %s"
      % ((g_start - c_start) if c_start and g_start else -1, sorted({str(r.get("status", r.get("error", "?")))[:40] for r in win})))
outcomes = {}
for r in reqs:
    k = str(r.get("status", "error"))
    outcomes[k] = outcomes.get(k, 0) + 1
print("all probe outcomes:", outcomes)
ok = g_stop is not None and c_start is not None and g_stop < c_start and all(r.get("status") != 200 for r in win)
print("gateway stopped before the new coordinator started and no 200 across the mixed window:", ok)
sys.exit(0 if ok else 1)
