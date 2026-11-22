#!/usr/bin/env python3
"""#2469/#2470 verify-step time split from one window's serves (stdlib only).

usage: verdict.py --res RESULTS_DIR [--models qwen,glm] [--json verdict.json]

Reads RESULTS_DIR/<model>/{rows.jsonl,serve/serve.err}. The serve ran with the lab section
timer (MLX_LM_SECTION_TIMING=1, fork campaign/2469-2470-verify-profile), which prints per model
forward

  section_timing tag=rows=<B>,L=<L>[,v=<0|1>] wall_ms=<ms> <section>=<exclusive ms>/<calls> ...

Every section evaluates its inputs and outputs at its edges, so the times are shares of a
synchronized forward, not the latency of the pipelined one. A verify step is a forward tagged
v=1 (an MTP verification: mtpCacheCheckpointIndexKey set). Only forwards inside a trial's
serve.err byte range (load.py) count; the warm-up (trial -1) is dropped. Per section: the median
over forwards of its exclusive ms; the denominator is the median of (wall_ms minus the lab
replay sections), so a share is of the real step's work.

#2469 (qwen): attn_below_window = fa.attn / step. fa.attn is the full-attention SDPA call of the
16 full-attention layers (the cache write is fa.cache_update, RoPE fa.rope; both apart). At a
~30K prompt and a 2-column window, almost all of its keys lie below the window. kernel = the
`event=lab_sdpa_route` line (PagedKVVectorAttentionRoute, the ported MLX core dispatch) for the
verify width's query columns; `lab_fa_shape` (the engine's own shape line) is the cross-check.
The ordinary 1-row decode forwards (cell ord1, same context) give fa.attn at one query column:
lever_ceiling = (verify fa.attn - decode fa.attn) / verify step, the most a kernel that reads
each K/V tile once for all window columns could save (TensorFold #3661's claim).

#2470 (glm): the fused MoE decode (GLM5NextMoE.fusedDecodeStep) is moe.router + moe.experts.
moe.replay.shared runs the shared expert alone over the same tokens with kernels that read each
of its weight tiles once per window; routed = moe.experts - moe.replay.shared. reads names how
the routed weights are read by the pinned kernels (code, not measured): glm5NextMoEExperts runs
one threadgroup per (token, routed slot) (mlx-swift-lm 8aa564db GLM5NextDecodeKernels.swift
2713-2755, grid z = T * (topK + 1); downAddShared grid z = T), so each pick reads its expert;
the shared expert's gate/up run in one threadgroup for every token (SHARED_ALL, "token 0's
threadgroup computes them all") and its down rows once for all tokens (glm5NextQMVBatch). The
lever's ceiling is routed x (1 - unique/picks): the reads a once-per-unique-expert kernel saves.

Prints T2469_SHARE (and T2469_LEVER_CEILING) / T2470_SHARE (and T2470_T4 for the 4-token ordinary decode call, T2470_CEILING)
then T2469_2470_VERDICT DONE|INCOMPLETE. Exit 0 when every requested model produced its line,
1 when one could not, 2 on unusable input.
"""
from __future__ import annotations

import argparse
import json
import re
import statistics
import sys
from pathlib import Path

LINE = re.compile(r"section_timing tag=(\S+) wall_ms=([0-9.]+)(.*)$")
FIELD = re.compile(r"(\S+)=([0-9.]+)/(\d+)")
ROUTES = re.compile(r"glm5next_moe_routes tag=(\S+) calls=(\d+) tokens=(\d+) picks=(\d+) unique=(\d+)")
SDPA = re.compile(r"event=lab_sdpa_route (.*)$", re.M)
SHAPE = re.compile(r"^lab_fa_shape (.*)$", re.M)
REPLAY_PREFIX = "moe.replay."
GLM_ROUTED_READS = "once_per_pick"
GLM_SHARED_READS = "once_per_window"


def kv(text):
    return dict(p.split("=", 1) for p in text.split() if "=" in p)


def parse_tag(tag):
    out = {}
    for part in tag.split(","):
        k, _, v = part.partition("=")
        if v.isdigit():
            out[k] = int(v)
    return out


def load_rows(path):
    rows, trials = [], []
    for line in Path(path).read_text().splitlines():
        if not line.strip():
            continue
        rec = json.loads(line)
        (trials if rec.get("kind") == "trial" else rows).append(rec)
    return rows, trials


def forwards(err_bytes, ranges):
    """section_timing records (and the moe route line printed after each) inside the byte ranges."""
    out = []
    for cell, start, end in ranges:
        text = err_bytes[start:end].decode("utf-8", "replace")
        for line in text.splitlines():
            m = LINE.search(line)
            if m:
                rec = {"cell": cell, "tag": m.group(1), "t": parse_tag(m.group(1)), "wall": float(m.group(2)),
                       "sections": {k: float(v) for k, v, _ in FIELD.findall(m.group(3))}, "routes": None}
                out.append(rec)
                continue
            r = ROUTES.search(line)
            if r and out and out[-1]["tag"] == r.group(1) and out[-1]["routes"] is None:
                out[-1]["routes"] = {"calls": int(r.group(2)), "tokens": int(r.group(3)),
                                     "picks": int(r.group(4)), "unique": int(r.group(5))}
    return out


def split(recs):
    """Median ms per section, median step (wall minus replays), shares of the step."""
    names = sorted({k for r in recs for k in r["sections"]})
    med = {k: statistics.median([r["sections"].get(k, 0.0) for r in recs]) for k in names}
    step = statistics.median([r["wall"] - sum(v for k, v in r["sections"].items() if k.startswith(REPLAY_PREFIX))
                              for r in recs])
    share = {k: (100.0 * v / step if step > 0 else 0.0) for k, v in med.items()}
    return {"forwards": len(recs), "step_ms": round(step, 3), "ms": {k: round(v, 3) for k, v in med.items()},
            "pct": {k: round(v, 2) for k, v in share.items()}}


def client_summary(rows):
    out = []
    for r in rows:
        if r.get("trial", -1) < 0:
            continue
        out.append({k: r.get(k) for k in ("cell", "trial", "row", "prompt_tokens", "completion_tokens", "ttft_s",
                                          "decode_tps", "finish", "error")})
    return out


def model_dir(res, name):
    d = Path(res) / name
    err = d / "serve" / "serve.err"
    rows = d / "rows.jsonl"
    if not err.is_file() or not rows.is_file():
        return None
    return d, err.read_bytes(), load_rows(rows)


def qwen(res):
    got = model_dir(res, "qwen")
    if got is None:
        return None, "no qwen/rows.jsonl or qwen/serve/serve.err"
    d, err, (rows, trials) = got
    ranges = [(t["cell"], t["serve_err_start"], t["serve_err_end"]) for t in trials if t["trial"] >= 0]
    recs = [r for r in forwards(err, ranges) if r["t"].get("v") == 1 and r["t"].get("L", 0) >= 2]
    if not recs:
        return None, "no v=1 verify forward inside a qwen trial (section timer off, or native MTP not on)"
    width = statistics.mode([r["t"]["L"] for r in recs])
    recs = [r for r in recs if r["t"]["L"] == width]
    s = split(recs)
    text = err.decode("utf-8", "replace")
    routes = [kv(m.group(1)) for m in SDPA.finditer(text)]
    shapes = [kv(m.group(1)) for m in SHAPE.finditer(text)]
    verify_routes = [r for r in routes if r.get("q_tokens") == str(width)]
    kernel = verify_routes[0]["kernel"] if verify_routes else "unobserved"
    kernels = sorted({r["kernel"] for r in verify_routes})
    if len(kernels) > 1:
        kernel = "+".join(kernels)
    attn = s["pct"].get("fa.attn")
    ord_ranges = [(t["cell"], t["serve_err_start"], t["serve_err_end"]) for t in trials
                  if t["trial"] >= 0 and t["cell"] != "nat1"]
    drecs = [r for r in forwards(err, ord_ranges) if r["t"].get("L") == 1 and r["t"].get("rows") == 1
             and "fa.attn" in r["sections"]]
    decode = split(drecs) if drecs else None
    ceiling = None
    if decode and attn is not None and s["step_ms"] > 0:
        ceiling = round(100.0 * (s["ms"]["fa.attn"] - decode["ms"]["fa.attn"]) / s["step_ms"], 2)
    out = {"decode": decode, "lever_ceiling_pct": ceiling, "verify_width": width, "split": s, "kernel": kernel, "sdpa_routes": routes, "fa_shapes": shapes,
           "trials": [t for t in trials if t["trial"] >= 0], "client": client_summary(rows),
           "attn_below_window_pct": attn}
    if attn is None:
        return out, "no fa.attn section in the qwen verify forwards"
    return out, None


def glm(res):
    got = model_dir(res, "glm")
    if got is None:
        return None, "no glm/rows.jsonl or glm/serve/serve.err"
    d, err, (rows, trials) = got
    nat = [(t["cell"], t["serve_err_start"], t["serve_err_end"]) for t in trials if t["trial"] >= 0 and t["cell"] == "nat1"]
    ords = [(t["cell"], t["serve_err_start"], t["serve_err_end"]) for t in trials if t["trial"] >= 0 and t["cell"] != "nat1"]
    out = {"trials": [t for t in trials if t["trial"] >= 0], "client": client_summary(rows)}

    def moe(recs):
        s = split(recs)
        experts = s["ms"].get("moe.experts", 0.0)
        shared = min(s["ms"].get("moe.replay.shared", 0.0), experts)
        step = s["step_ms"]
        picks = sum(r["routes"]["picks"] for r in recs if r["routes"])
        unique = sum(r["routes"]["unique"] for r in recs if r["routes"])
        tokens = statistics.mode([r["t"].get("rows", 1) * r["t"].get("L", 1) for r in recs])
        routed_pct = 100.0 * (experts - shared) / step if step > 0 else 0.0
        shared_pct = 100.0 * shared / step if step > 0 else 0.0
        ratio = unique / picks if picks else None
        return {"split": s, "tokens": tokens, "routed_pct": round(routed_pct, 2), "shared_pct": round(shared_pct, 2),
                "router_pct": s["pct"].get("moe.router"), "picks": picks, "unique": unique,
                "unique_per_pick": round(ratio, 4) if ratio is not None else None,
                "ceiling_pct": round(routed_pct * (1 - ratio), 2) if ratio is not None else None}

    nrecs = [r for r in forwards(err, nat) if r["t"].get("v") == 1 and r["t"].get("L", 0) >= 2
             and "moe.experts" in r["sections"]]
    if not nrecs:
        return out, "no v=1 verify forward with a moe.experts section inside a glm nat1 trial"
    out["verify"] = moe(nrecs)
    orecs = [r for r in forwards(err, ords) if r["t"].get("L") == 1 and r["t"].get("rows", 1) > 1
             and "moe.experts" in r["sections"]]
    if orecs:
        top = max(r["t"]["rows"] for r in orecs)
        out["ordinary"] = moe([r for r in orecs if r["t"]["rows"] == top])
    return out, None


def main(argv=None):
    ap = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    ap.add_argument("--res", required=True)
    ap.add_argument("--models", default="qwen,glm")
    ap.add_argument("--json")
    a = ap.parse_args(argv)
    if not Path(a.res).is_dir():
        print(f"BLOCKER: no results dir {a.res}")
        return 2
    want = [m for m in a.models.split(",") if m]
    if not want or any(m not in ("qwen", "glm") for m in want):
        print(f"BLOCKER: --models {a.models}: qwen and/or glm")
        return 2
    report, missing = {}, []
    if "qwen" in want:
        q, why = qwen(a.res)
        report["qwen"] = q
        if why:
            missing.append(f"qwen: {why}")
        else:
            s = q["split"]
            print(f"# Qwen3.8-27B verify step (rows=1, L={q['verify_width']}, {s['forwards']} forwards, "
                  f"synchronized step median {s['step_ms']} ms)")
            for k in sorted(s["ms"], key=lambda k: -s["ms"][k]):
                print(f"  {k:<18} {s['ms'][k]:9.3f} ms  {s['pct'][k]:6.2f}%")
            for r in q["sdpa_routes"]:
                print(f"  sdpa_route {' '.join(f'{k}={v}' for k, v in r.items())}")
            for c in q["client"]:
                print(f"  client {json.dumps(c, sort_keys=True)}")
            d = q["decode"]
            if d:
                print(f"  decode (rows=1, L=1, {d['forwards']} forwards): step {d['step_ms']} ms, "
                      f"fa.attn {d['ms'].get('fa.attn')} ms ({d['pct'].get('fa.attn')}%)")
            print(f"T2469_SHARE attn_below_window={q['attn_below_window_pct']:.2f} kernel={q['kernel']}")
            if d:
                print(f"T2469_LEVER_CEILING pct_of_step={q['lever_ceiling_pct']} verify_fa_attn_ms={s['ms']['fa.attn']} "
                      f"decode_fa_attn_ms={d['ms'].get('fa.attn')}")
            else:
                missing.append("qwen: no 1-row ordinary decode forward with fa.attn (T2469_LEVER_CEILING)")
            if q["kernel"] == "unobserved":
                missing.append("qwen: no event=lab_sdpa_route line for the verify width")
    if "glm" in want:
        g, why = glm(a.res)
        report["glm"] = g
        if why:
            missing.append(f"glm: {why}")
        else:
            v = g["verify"]
            s = v["split"]
            print(f"# GLM-5.3-Flash verify step (rows=1, {v['tokens']} tokens, {s['forwards']} forwards, "
                  f"synchronized step median {s['step_ms']} ms)")
            for k in sorted(s["ms"], key=lambda k: -s["ms"][k]):
                print(f"  {k:<20} {s['ms'][k]:9.3f} ms  {s['pct'][k]:6.2f}%")
            for c in g["client"]:
                print(f"  client {json.dumps(c, sort_keys=True)}")
            print(f"T2470_SHARE routed={v['routed_pct']:.2f} shared={v['shared_pct']:.2f} reads={GLM_ROUTED_READS} "
                  f"shared_reads={GLM_SHARED_READS} tokens={v['tokens']} unique_per_pick={v['unique_per_pick']}")
            o = g.get("ordinary")
            if o:
                print(f"T2470_T4 routed={o['routed_pct']:.2f} shared={o['shared_pct']:.2f} tokens={o['tokens']} "
                      f"unique_per_pick={o['unique_per_pick']} step_ms={o['split']['step_ms']}")
            else:
                missing.append("glm: no multi-row ordinary decode forward with moe.experts (T2470_T4)")
            best = max([x for x in (v, o) if x], key=lambda x: x["tokens"])
            print(f"T2470_CEILING pct_of_step={best['ceiling_pct']} tokens={best['tokens']} "
                  f"(routed share x (1 - unique/picks): reads a once-per-unique-expert kernel saves)")
    if a.json:
        Path(a.json).write_text(json.dumps({"report": report, "missing": missing}, indent=2, sort_keys=True) + "\n")
    for m in missing:
        print(f"BLOCKER: {m}")
    print(f"T2469_2470_VERDICT {'DONE' if not missing else 'INCOMPLETE'}")
    return 0 if not missing else 1


if __name__ == "__main__":
    sys.exit(main())
