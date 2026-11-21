#!/usr/bin/env python3
"""Peak memory of a one-row lab serve and the catalog `min_ram_gb` it implies (#2452 step 3; stdlib only).

usage: listing_memory.py sample --pid PID [--label NAME]
       listing_memory.py report --samples FILE.jsonl --profile prefill-profile.json --ram-bytes N
                                --out-md FILE --out-json FILE

sample: one JSON line for a running process from proc_pid_rusage(RUSAGE_INFO_V4), the call
`msbLifetimePeakPhysFootprintMB` (MSBLoopbackCommand.swift) makes: phys_footprint (Metal
included), lifetime_max_phys_footprint (the process high-water mark), resident_size (misses
Metal allocations), in bytes. The job takes one sample after each context cell, so the line
after the largest cell holds the serve's lifetime peak.

report: the serve's lifetime peak physical footprint (the sizing measure, docs/runbooks/
model-family-performance-intake.md "Peak memory": "For sizing a row, use lifetime peak
physical footprint"), the MLX peak per prompt length from `macprovider-cli prefill-profile`
(the serve's serial path in its own process, `mlx_peak_bytes` per step) and the proposed
`min_ram_gb`, derived the way the existing large rows were:

    min_ram_gb = ceil(peak_GB + 10% of the measuring Mac's RAM + 4)

- `min_ram_gb` is the resident-fit floor (SPEC-023 §5: `model.min_ram_gb <= mac.ram_gb -
  safety_margin_gb`, safety_margin_gb = 4; §3.7 per-artifact `min_ram_gb`);
- 10% of RAM is the SPEC-048-R012 free-memory floor the provider keeps outside MLX's limit
  (MLXMemoryBudget.physicalFreeFloorDivisor = 10);
- the precedent rows in autotune-candidates.json: minimaxai/minimax-m3.1-flash "min_ram_gb=230
  (199.5 GB measured peak at 32K + 26 GB free-memory floor + 4 GB margin)" on the 256 GB Studio
  and nvidia/nemotron-3.5-bolt-74b-a9b "min_ram_gb=84 (70.0 GiB measured process peak + 10%
  free-memory floor on 96 GB + 4 GB margin)".
Peak is in GiB (bytes / 2**30), as the Nemotron row states its peak, and RAM is the nominal size
(hw.memsize in GiB: 256 on the Studio), so the floor is 25.6 there; this reproduces both precedent
values (199.5 + 25.6 + 4 -> 230; 70.0 + 9.6 + 4 -> 84). The report also gives the peak in GB (1e9).
"""
import argparse
import ctypes
import json
import math
import os
import sys
import time

RUSAGE_INFO_V4 = 4
# rusage_info_v4 after the 16-byte uuid, as uint64 fields: index 6 resident_size,
# 7 phys_footprint, 28 lifetime_max_phys_footprint (<sys/resource.h>).
_RESIDENT, _FOOTPRINT, _LIFETIME_MAX = 6, 7, 28
FREE_FLOOR_FRACTION = 0.10
MARGIN_GB = 4


def rusage(pid):
    """{resident_size, phys_footprint, lifetime_max_phys_footprint} in bytes, or raise OSError."""
    libc = ctypes.CDLL("/usr/lib/libSystem.B.dylib", use_errno=True)
    buf = (ctypes.c_uint64 * 64)()  # rusage_info_v4 is 16 + 37 * 8 bytes; room to spare
    if libc.proc_pid_rusage(ctypes.c_int(pid), ctypes.c_int(RUSAGE_INFO_V4), ctypes.byref(buf)) != 0:
        raise OSError(ctypes.get_errno(), f"proc_pid_rusage({pid}) failed")
    fields = buf[2:]  # skip the uuid (two uint64 words)
    return {"resident_size": fields[_RESIDENT], "phys_footprint": fields[_FOOTPRINT],
            "lifetime_max_phys_footprint": fields[_LIFETIME_MAX]}


def nominal_ram_gb(ram_bytes):
    """256 for a 256 GB Mac (hw.memsize is a whole number of GiB)."""
    return round(ram_bytes / 2**30)


def proposed_min_ram_gb(peak_bytes, ram_bytes):
    peak_gb = peak_bytes / 2**30
    floor_gb = FREE_FLOOR_FRACTION * nominal_ram_gb(ram_bytes)
    return math.ceil(peak_gb + floor_gb + MARGIN_GB - 1e-9), round(peak_gb, 1), round(floor_gb, 1)


def mlx_peaks(profile):
    """[(prompt_tokens, step, mlx_peak_bytes)] from a prefill-profile report."""
    out = []
    for p in profile.get("prompts") or []:
        for s in p.get("served") or []:
            out.append((p.get("tokens"), s.get("step"), s.get("mlx_peak_bytes")))
    return out


def build_report(samples, profile, ram_bytes):
    serve = [s for s in samples if s.get("label", "").startswith("serve")]
    if not serve:
        raise ValueError("no serve samples")
    peak = max(s["lifetime_max_phys_footprint"] for s in serve)
    min_ram, peak_gb, floor_gb = proposed_min_ram_gb(peak, ram_bytes)
    peaks = mlx_peaks(profile or {})
    return {
        "ram_gb": nominal_ram_gb(ram_bytes),
        "samples": samples,
        "serve_lifetime_peak_phys_footprint_bytes": peak,
        "serve_lifetime_peak_gib": peak_gb,
        "serve_lifetime_peak_gb_1e9": round(peak / 1e9, 1),
        "free_floor_gb": floor_gb,
        "margin_gb": MARGIN_GB,
        "proposed_min_ram_gb": min_ram,
        "rule": "ceil(serve lifetime peak phys_footprint GiB + 10% of nominal RAM (SPEC-048-R012 floor) + 4)",
        "mlx_peak": [{"prompt_tokens": t, "step": st, "mlx_peak_bytes": b,
                      "mlx_peak_gb": round(b / 1e9, 1) if isinstance(b, (int, float)) else None}
                     for t, st, b in peaks],
        "profile_family": (profile or {}).get("model_family"),
        "serve_default_step": (profile or {}).get("serve_default_step"),
    }


def markdown(r):
    gb = lambda b: f"{b / 2**30:.1f}"
    lines = [f"Peak memory, one row (RAM {r['ram_gb']} GB)", "",
             "| sample | phys_footprint GiB | lifetime peak GiB | resident GiB |", "|---|---:|---:|---:|"]
    for s in r["samples"]:
        lines.append(f"| {s['label']} | {gb(s['phys_footprint'])} | {gb(s['lifetime_max_phys_footprint'])} "
                     f"| {gb(s['resident_size'])} |")
    if r["mlx_peak"]:
        lines += ["", "| prompt tokens | step | MLX peak GB (prefill-profile) |", "|---:|---:|---:|"]
        lines += [f"| {m['prompt_tokens']} | {m['step']} | {m['mlx_peak_gb']} |" for m in r["mlx_peak"]]
    lines += ["", f"Proposed min_ram_gb = ceil({r['serve_lifetime_peak_gib']} + {r['free_floor_gb']} + "
              f"{r['margin_gb']}) = {r['proposed_min_ram_gb']} ({r['rule']})", ""]
    return "\n".join(lines)


def main(argv=None):
    ap = argparse.ArgumentParser(description=__doc__.split("\n\n")[0])
    sub = ap.add_subparsers(dest="cmd", required=True)
    s = sub.add_parser("sample")
    s.add_argument("--pid", type=int, required=True)
    s.add_argument("--label", default="serve")
    r = sub.add_parser("report")
    r.add_argument("--samples", required=True)
    r.add_argument("--profile")
    r.add_argument("--ram-bytes", type=int, required=True)
    r.add_argument("--out-md", required=True)
    r.add_argument("--out-json", required=True)
    args = ap.parse_args(argv)
    if args.cmd == "sample":
        try:
            rec = rusage(args.pid)
        except OSError as e:
            print(f"sample: {e}", file=sys.stderr)
            return 1
        print(json.dumps({"label": args.label, "pid": args.pid, "t": round(time.time(), 3), **rec}))
        return 0
    samples = [json.loads(l) for l in open(args.samples) if l.strip()]
    profile = json.load(open(args.profile)) if args.profile and os.path.exists(args.profile) else None
    try:
        rep = build_report(samples, profile, args.ram_bytes)
    except (ValueError, KeyError) as e:
        print(f"report: {e}", file=sys.stderr)
        return 2
    json.dump(rep, open(args.out_json, "w"), indent=2, sort_keys=True)
    md = markdown(rep)
    open(args.out_md, "w").write(md)
    print(md)
    return 0


if __name__ == "__main__":
    sys.exit(main())
