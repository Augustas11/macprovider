#!/usr/bin/env python3
"""join-thermal.py — correlate the soak's buyer-side streaming TPS with the
provider-side thermal log, for RESEARCH_235 (scenario 15, issue #584).

Answers #584's open question: does the streaming-TPS decay (B10) coincide
with rising thermal pressure / a falling CPU speed-limit? It does NOT run the
soak — it post-processes two files produced by a completed lab run:

  1. per_request.jsonl  — the harness buyer-side log (one JSON obj/request,
     with start_utc, ttft_ms, completion_tokens_received, last_byte_utc,
     stream). Streaming TPS is derived the same way benchmark.go does:
     tokens / (last_byte_utc - (start_utc + ttft_ms)).
  2. thermal.ndjson     — thermal-collector.sh output (pmset + powermetrics
     records tagged with "ts").

Output (stdout, NDJSON): one record per time bin with the bin's median
streaming TPS and the nearest thermal sample's cpu_speed_limit_pct /
cpu_power_mw / gpu_power_mw / cpu_die_temp_c, so the pair can be plotted or
eyeballed for a throttle correlation.

Usage:
  ./join-thermal.py per_request.jsonl thermal.ndjson [--bin-seconds 60] > overlay.ndjson

Pure stdlib — no third-party deps, so it runs anywhere python3 does.
"""
import argparse
import json
import statistics
import sys
from datetime import datetime, timezone


def parse_ts(s):
    """Parse an RFC3339/ISO-8601 UTC timestamp to an aware datetime."""
    if s is None:
        return None
    s = s.strip()
    if s.endswith("Z"):
        s = s[:-1] + "+00:00"
    try:
        dt = datetime.fromisoformat(s)
    except ValueError:
        return None
    if dt.tzinfo is None:
        dt = dt.replace(tzinfo=timezone.utc)
    return dt.astimezone(timezone.utc)


def streaming_tps(rec):
    """Derive per-request streaming decode TPS, mirroring benchmark.go's B2/B10
    basis: tokens / (last_byte - (start + ttft)). Returns (start_dt, tps) or
    None if the record is not a usable streaming success."""
    if not rec.get("stream"):
        return None
    tokens = rec.get("completion_tokens_received") or 0
    ttft_ms = rec.get("ttft_ms") or 0
    if tokens <= 0 or ttft_ms <= 0:
        return None
    start = parse_ts(rec.get("start_utc"))
    last = parse_ts(rec.get("last_byte_utc"))
    if start is None or last is None:
        return None
    first_byte = start.timestamp() + ttft_ms / 1000.0
    dur = last.timestamp() - first_byte
    if dur <= 0:
        return None
    return start, tokens / dur


def load_thermal(path):
    """Load thermal samples as a time-sorted list of (epoch, dict)."""
    out = []
    with open(path) as f:
        for line in f:
            line = line.strip()
            if not line:
                continue
            try:
                rec = json.loads(line)
            except json.JSONDecodeError:
                continue
            ts = parse_ts(rec.get("ts"))
            if ts is None:
                continue
            out.append((ts.timestamp(), rec))
    out.sort(key=lambda x: x[0])
    return out


def nearest_thermal(thermal, epoch):
    """Nearest thermal sample to `epoch` by absolute time distance."""
    if not thermal:
        return {}
    best = min(thermal, key=lambda x: abs(x[0] - epoch))
    return best[1]


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("per_request")
    ap.add_argument("thermal")
    ap.add_argument("--bin-seconds", type=int, default=60)
    args = ap.parse_args()

    thermal = load_thermal(args.thermal)

    samples = []  # (epoch, tps)
    with open(args.per_request) as f:
        for line in f:
            line = line.strip()
            if not line:
                continue
            try:
                rec = json.loads(line)
            except json.JSONDecodeError:
                continue
            r = streaming_tps(rec)
            if r is None:
                continue
            start, tps = r
            samples.append((start.timestamp(), tps))

    if not samples:
        print("join-thermal: no usable streaming samples", file=sys.stderr)
        return 1

    samples.sort(key=lambda x: x[0])
    t0 = samples[0][0]
    bins = {}
    for epoch, tps in samples:
        b = int((epoch - t0) // args.bin_seconds)
        bins.setdefault(b, []).append((epoch, tps))

    for b in sorted(bins):
        pts = bins[b]
        tpss = [t for _, t in pts]
        mid_epoch = statistics.median([e for e, _ in pts])
        th = nearest_thermal(thermal, mid_epoch)
        out = {
            "bin": b,
            "bin_start_offset_s": b * args.bin_seconds,
            "n": len(tpss),
            "tps_p50": round(statistics.median(tpss), 2),
            "tps_min": round(min(tpss), 2),
            "tps_max": round(max(tpss), 2),
            "cpu_speed_limit_pct": th.get("cpu_speed_limit_pct"),
            "cpu_power_mw": th.get("cpu_power_mw"),
            "gpu_power_mw": th.get("gpu_power_mw"),
            "cpu_die_temp_c": th.get("cpu_die_temp_c"),
        }
        print(json.dumps(out))
    return 0


if __name__ == "__main__":
    sys.exit(main())
