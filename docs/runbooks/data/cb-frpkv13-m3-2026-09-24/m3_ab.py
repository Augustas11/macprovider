#!/usr/bin/env python3
"""M3 A/B: baseline (eager record) vs lazy record, interleaved per (n, rep) so
both builds see the same background load. Samples the live provider's CPU
during every measurement; a run with mean live CPU above the threshold is
flagged contaminated. Numbers only, no content."""
import json, statistics, subprocess, sys, threading, time
sys.path.insert(0, "/Users/a1/lab-ac25-m2")
import importlib.util
spec = importlib.util.spec_from_file_location("bench", "/Users/a1/lab-ac25-m2/m3_bench_lib.py")
bench = importlib.util.module_from_spec(spec); spec.loader.exec_module(bench)

LIVE_PID = sys.argv[1]
PORTS = {"baseline_6634a1d1": 18081, "lazy_505a5766": 18080}
CONTAMINATED_CPU = 25.0
REPEATS = 3


def live_cpu_during(fn):
    samples, stop = [], threading.Event()

    def sampler():
        while not stop.is_set():
            out = subprocess.run(["ps", "-o", "%cpu=", "-p", LIVE_PID], capture_output=True, text=True).stdout.strip()
            try:
                samples.append(float(out))
            except ValueError:
                pass
            time.sleep(0.5)
    t = threading.Thread(target=sampler); t.start()
    try:
        result = fn()
    finally:
        stop.set(); t.join()
    return result, (round(statistics.mean(samples), 1) if samples else None)


rows = []
for n in (1, 2, 4, 8):
    for rep in range(REPEATS):
        for build, port in PORTS.items():
            for batched in (False, True):
                bench.PORT = port
                r, cpu = live_cpu_during(lambda: bench.run(n, batched))
                row = {"build": build, "n": n, "rep": rep, "batched": batched, "agg_tps": r["agg_tps"],
                       "ok": r["ok"], "errors": len(r["errors"]), "live_cpu_mean": cpu,
                       "contaminated": cpu is not None and cpu > CONTAMINATED_CPU}
                rows.append(row)
                print(json.dumps(row), flush=True)

summary = {}
for build in PORTS:
    for n in (1, 2, 4, 8):
        for batched in (False, True):
            clean = [r["agg_tps"] for r in rows if r["build"] == build and r["n"] == n
                     and r["batched"] == batched and not r["contaminated"] and r["agg_tps"]]
            summary[f"{build}|n={n}|{'batched' if batched else 'serial'}"] = {
                "median_clean_tps": statistics.median(clean) if clean else None, "clean_runs": len(clean)}
print(json.dumps({"summary": summary}))
