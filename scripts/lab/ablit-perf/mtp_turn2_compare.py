#!/usr/bin/env python3
"""Native MTP against ordinary decode on the cached-prefix turn-2 path (#2459).

usage: mtp_turn2_compare.py --native DIR [--ordinary DIR] [--cap 32768] [--json OUT]

DIR is one job.sh pass directory (provider.jsonl from run-grid.sh --turns 2, serve/status.json).
Rows pair by (ctx_target, max_tokens, rows, trial, row). Per cell (context, output, rows):

- parity: with --ordinary, every turn-1 and turn-2 pair has identical text, reasoning text and
  completion token count (greedy). Turn 1 counts because its text is the turn-2 history.
- cache: every turn-2 row reports cached_prompt_tokens > 0 on both sides, and every trial whose
  turn-2 rows carry conversation_cache_turn2 (provider_client.py --native-mtp-counters) shows at
  least one conversation-cache hit over its turn-2 requests.
- key: a native turn 2 sent with a sticky conversation key (conversation_key_sent and not
  conversation_cache_only, TURN2_HEADER=1) fails: SPEC-048-R009 decodes it ordinarily, so the
  pass measured nothing. TURN2_HEADER=cache_only sends the live cached-turn key.
- admission: every native turn-2 prompt is at most --cap tokens (above it native MTP is not
  admitted and the row decodes ordinarily) and the native pass proposed tokens on turn 2
  (native_mtp_turn2, provider_client.py --native-mtp-counters).
- control: the ordinary pass's serve/status.json shows native MTP off.
- speed: medians of decode tok/s and TTFT per turn and side, and the native/ordinary decode ratio.

Prints one `T2_CELL ...` line per cell, a markdown table, then `T2_VERDICT PASS|FAIL`. Exit 0 when
every check passes, 1 when one fails (a finding), 2 on unusable input. Without --ordinary only the
native-side checks run (the preflight probe).
"""
import argparse
import json
import os
import statistics
import sys


def load_rows(d):
    path = os.path.join(d, "provider.jsonl")
    rows = []
    with open(path) as f:
        for line in f:
            line = line.strip()
            if line:
                r = json.loads(line)
                if r.get("kind", "row") == "row":
                    rows.append(r)
    return rows


def native_off(d):
    """True when the pass's serve ran without native MTP, None when its status is unreadable."""
    try:
        with open(os.path.join(d, "serve", "status.json")) as f:
            nm = json.load(f).get("native_mtp")
    except (OSError, ValueError):
        return None
    if not isinstance(nm, dict):
        return True
    return not (nm.get("enabled") is True and nm.get("mode") not in (None, "off"))


def key(r):
    return (r["ctx_target"], r["max_tokens"], r["rows"], r["trial"], r["row"])


def by_cell(rows):
    out = {}
    for r in rows:
        out.setdefault((r["ctx_target"], r["max_tokens"], r["rows"]), {}).setdefault(r.get("turn", 1), {})[key(r)] = r
    return out


def med(values):
    values = [v for v in values if v is not None]
    return round(statistics.median(values), 3) if values else None


def same(a, b):
    return ((a.get("text") or "") == (b.get("text") or "")
            and (a.get("reasoning_text") or "") == (b.get("reasoning_text") or "")
            and a.get("completion_tokens") == b.get("completion_tokens"))


def first_diff(a, b):
    x = (a.get("reasoning_text") or "") + "\x00" + (a.get("text") or "")
    y = (b.get("reasoning_text") or "") + "\x00" + (b.get("text") or "")
    n = next((i for i, (p, q) in enumerate(zip(x, y)) if p != q), min(len(x), len(y)))
    return n


def side_stats(turns):
    t1, t2 = list(turns.get(1, {}).values()), list(turns.get(2, {}).values())
    trials, cache = {}, {}
    for r in t2:
        nm = r.get("native_mtp_turn2")
        if isinstance(nm, dict):
            trials[r["trial"]] = nm  # one counter change per trial, repeated on its rows
        cc = r.get("conversation_cache_turn2")
        if isinstance(cc, dict) and cc.get("valid"):
            cache[r["trial"]] = cc
    sticky = sum(1 for r in t2 if r.get("conversation_key_sent") and r.get("conversation_cache_only") is False)
    proposed = sum((nm.get("proposed_tokens") or 0) for nm in trials.values() if nm.get("acceptance_valid"))
    accepted = sum((nm.get("accepted_tokens") or 0) for nm in trials.values() if nm.get("acceptance_valid"))
    return {
        "t1_ttft_s": med(r.get("ttft_s") for r in t1), "t1_decode_tps": med(r.get("decode_tps") for r in t1),
        "t2_ttft_s": med(r.get("ttft_s") for r in t2), "t2_decode_tps": med(r.get("decode_tps") for r in t2),
        "t1_prompt_tokens_max": max((r.get("prompt_tokens") or 0 for r in t1), default=None),
        "t2_prompt_tokens_max": max((r.get("prompt_tokens") or 0 for r in t2), default=None),
        "t2_cached_min": min((r.get("cached_prompt_tokens") or 0 for r in t2), default=None),
        "t2_completion_tokens": sorted({r.get("completion_tokens") for r in t2}, key=lambda x: (x is None, x)),
        "errors": sum(1 for r in t1 + t2 if r.get("error")),
        "t2_rows": len(t2),
        "t2_counter_trials": len(trials),
        "t2_proposed": proposed if trials else None,
        "t2_accepted": accepted if trials else None,
        "t2_acceptance": round(accepted / proposed, 4) if trials and proposed else None,
        "t2_last_reasons": sorted({str(nm.get("last_reason")) for nm in trials.values()}),
        "t2_sticky_key_rows": sticky,
        "t2_cache_only_rows": sum(1 for r in t2 if r.get("conversation_cache_only")),
        "t2_cache_trials": len(cache),
        "t2_cache_hits": sum(cc.get("hits") or 0 for cc in cache.values()) if cache else None,
        "t2_cache_miss_trials": sum(1 for cc in cache.values() if not cc.get("hits")),
    }


def score(native_rows, ordinary_rows, cap, ordinary_off):
    nat = by_cell(native_rows)
    ordc = by_cell(ordinary_rows) if ordinary_rows is not None else None
    cells = []
    for cell in sorted(nat):
        n = side_stats(nat[cell])
        c = {"ctx_target": cell[0], "max_tokens": cell[1], "rows": cell[2], "native": n, "failures": []}
        f = c["failures"]
        if n["t2_rows"] == 0:
            f.append("native: no turn-2 rows")
        if n["errors"]:
            f.append(f"native: {n['errors']} request errors")
        if n["t2_rows"] and not n["t2_cached_min"]:
            f.append("native: a turn-2 row reports 0 cached tokens")
        if n["t2_cache_miss_trials"]:
            f.append(f"native: {n['t2_cache_miss_trials']} trial(s) show no conversation-cache hit on turn 2")
        if n["t2_sticky_key_rows"]:
            f.append(f"native: {n['t2_sticky_key_rows']} turn-2 row(s) sent a sticky conversation key "
                     "(SPEC-048-R009 decodes them ordinarily; use TURN2_HEADER=cache_only)")
        if n["t2_prompt_tokens_max"] and n["t2_prompt_tokens_max"] > cap:
            f.append(f"native: turn-2 prompt {n['t2_prompt_tokens_max']} tokens is above the cap {cap}")
        if n["t2_counter_trials"] == 0:
            f.append("native: no turn-2 native_mtp counters (run without --native-mtp-counters?)")
        elif not n["t2_proposed"]:
            f.append("native: no token proposed on turn 2 (native MTP did not run on the cached turn)")
        if ordc is not None:
            o_turns = ordc.get(cell, {})
            o = side_stats(o_turns)
            c["ordinary"] = o
            if o["t2_rows"] == 0:
                f.append("ordinary: no turn-2 rows")
            if o["errors"]:
                f.append(f"ordinary: {o['errors']} request errors")
            if o["t2_rows"] and not o["t2_cached_min"]:
                f.append("ordinary: a turn-2 row reports 0 cached tokens")
            if o["t2_cache_miss_trials"]:
                f.append(f"ordinary: {o['t2_cache_miss_trials']} trial(s) show no conversation-cache hit on turn 2")
            if ordinary_off is not True:
                f.append("ordinary: serve status does not show native MTP off"
                         if ordinary_off is False else "ordinary: serve/status.json unreadable")
            for turn in (1, 2):
                a, b = nat[cell].get(turn, {}), o_turns.get(turn, {})
                keys = sorted(set(a) | set(b))
                bad = [k for k in keys if k not in a or k not in b or not same(a[k], b[k])]
                c[f"t{turn}_pairs"] = len(keys)
                c[f"t{turn}_parity"] = not bad and bool(keys)
                if bad:
                    k = bad[0]
                    where = (f"first difference at char {first_diff(a[k], b[k])}" if k in a and k in b
                             else "unpaired row")
                    f.append(f"turn {turn}: {len(bad)}/{len(keys)} pairs differ (trial {k[3]} row {k[4]}: {where})")
                elif not keys:
                    f.append(f"turn {turn}: no pairs")
            nd, od = n["t2_decode_tps"], o["t2_decode_tps"]
            c["t2_decode_ratio"] = round(nd / od, 4) if nd and od else None
        c["verdict"] = "FAIL" if f else "PASS"
        cells.append(c)
    return cells


def fmt(x):
    return "-" if x is None else str(x)


def report(cells, out=None):
    out = out or sys.stdout
    for c in cells:
        n, o = c["native"], c.get("ordinary") or {}
        print(f"T2_CELL ctx={c['ctx_target']} out={c['max_tokens']} rows={c['rows']} "
              f"parity_t1={fmt(c.get('t1_parity'))} parity_t2={fmt(c.get('t2_parity'))} "
              f"pairs_t2={fmt(c.get('t2_pairs'))} native_t2_decode={fmt(n['t2_decode_tps'])} "
              f"ordinary_t2_decode={fmt(o.get('t2_decode_tps'))} ratio={fmt(c.get('t2_decode_ratio'))} "
              f"native_t2_ttft={fmt(n['t2_ttft_s'])} ordinary_t2_ttft={fmt(o.get('t2_ttft_s'))} "
              f"native_t1_ttft={fmt(n['t1_ttft_s'])} cached_min={fmt(n['t2_cached_min'])}/{fmt(o.get('t2_cached_min'))} "
              f"t1_prompt={fmt(n['t1_prompt_tokens_max'])} t2_prompt_max={fmt(n['t2_prompt_tokens_max'])} "
              f"t2_tokens={n['t2_completion_tokens']} proposed_t2={fmt(n['t2_proposed'])} "
              f"acceptance_t2={fmt(n['t2_acceptance'])} cache_hits_t2={fmt(n['t2_cache_hits'])}/"
              f"{fmt(o.get('t2_cache_hits'))} cache_only_rows_t2={n['t2_cache_only_rows']} "
              f"mtp_last_reason_t2={','.join(n['t2_last_reasons']) or '-'} verdict={c['verdict']}", file=out)
        for msg in c["failures"]:
            print(f"T2_FAIL ctx={c['ctx_target']} out={c['max_tokens']} rows={c['rows']} {msg}", file=out)
    print("", file=out)
    print("| ctx | out | turn | native decode tok/s | ordinary decode tok/s | native TTFT s | ordinary TTFT s | parity |",
          file=out)
    print("|---|---|---|---|---|---|---|---|", file=out)
    for c in cells:
        n, o = c["native"], c.get("ordinary") or {}
        for t in (1, 2):
            print(f"| {c['ctx_target']} | {c['max_tokens']} | {t} | {fmt(n[f't{t}_decode_tps'])} | "
                  f"{fmt(o.get(f't{t}_decode_tps'))} | {fmt(n[f't{t}_ttft_s'])} | {fmt(o.get(f't{t}_ttft_s'))} | "
                  f"{fmt(c.get(f't{t}_parity'))} |", file=out)
    print("", file=out)
    verdict = "PASS" if cells and all(c["verdict"] == "PASS" for c in cells) else "FAIL"
    print(f"T2_VERDICT {verdict} cells={len(cells)}", file=out)
    return verdict


def main(argv=None):
    ap = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    ap.add_argument("--native", required=True)
    ap.add_argument("--ordinary")
    ap.add_argument("--cap", type=int, default=32768, help="native-MTP prompt-token cap (signed: 32768)")
    ap.add_argument("--json")
    args = ap.parse_args(argv)
    try:
        native_rows = load_rows(args.native)
        ordinary_rows = load_rows(args.ordinary) if args.ordinary else None
    except (OSError, ValueError, KeyError) as exc:
        print(f"unusable input: {exc}")
        return 2
    if not any(r.get("turn") == 2 for r in native_rows):
        print("unusable input: no turn-2 rows in the native pass (run with TURNS=2)")
        return 2
    try:
        cells = score(native_rows, ordinary_rows, args.cap, native_off(args.ordinary) if args.ordinary else None)
    except KeyError as exc:
        print(f"unusable input: row without {exc}")
        return 2
    verdict = report(cells)
    if args.json:
        with open(args.json, "w") as f:
            json.dump({"cap": args.cap, "verdict": verdict, "cells": cells}, f, indent=2)
    return 0 if verdict == "PASS" else 1


if __name__ == "__main__":
    sys.exit(main())
