#!/usr/bin/env python3
"""#2462 verdict: control-candidate-control serves of mixed_load.py, gates and medians (stdlib only).

usage: verdict.py --res RES_DIR --serves A1:A,B:B,A2:A [--ord-rows 2] [--min-samples 6]
                  [--cost-pct 3] [--tests-ok 1] [--json verdict.json]

RES_DIR/<label>/rows.jsonl per serve; mode A = process-wide row_invariant (config
small_m_route: row_invariant), mode B = mixed. The B serve must sit between two A serves.

Path checks (a failure means the cells did not measure what they claim):
  every request returned usage and no error; per trial the native_mtp admissions are 0 in ord1
  and 1 in nat1, mix, conv2, conv_flip, conv_flip_long and conv_spread, with no pre-output fallback or post-output failure and counters not
  reset; every A trial reports small_m_route row_invariant and every B trial mixed; a mix trial
  peaks at 1 + ord_rows active decode rows, and on B at row_invariant=1+ord_rows / stock_order=0
  in-flight route requests (SPEC-038 v0.3.63: the ordinary rows join row_invariant); on B the
  small_m_route_admissions change (SPEC-038 v0.3.64: a stored entry decides first, every
  row_invariant request is joinable; v0.3.65 cost rule, SmallMRoute.splitStepPrefillTokens = 8)
  is idle=ord_rows in ord1, native_admitted=1 in nat1, native_admitted=1 /
  native_active=ord_rows in mix, native_admitted=1 / native_active=1 / conversation_cache=1 in
  conv2 (turn 1 beside the native row, turn 2 idle on its entry's route), idle=1 /
  native_admitted=1 / conversation_cache=1 in conv_flip (turn 1 alone on stock_order; turn 2
  keeps its stock_order entry beside the native row: about 1384 cached > min(64, native
  remaining) x 8 = 512, split), idle=1 / native_admitted=1 / conversation_cache_join=1 in
  conv_flip_long (turn 2 at 1024 tokens: 1384 <= min(1024, native remaining ~1000) x 8, join
  and re-prefill), and native_admitted=1 / native_active=2 / conversation_cache=1 in
  conv_spread (turn 1 beside the native row, turn 2 on its row_invariant entry, the unkeyed
  row joins it); conversation_cache_join=0 everywhere else; native proposals > 0 in every
  cell with a native row.
  mix_late (INFO cell) is checked for errors, counter resets and the route mode, and fails the
  path when any trial admits its late request native (the cell assumes it runs ordinary).
Gates:
  native_identity  every native row (nat1, mix and conv2) of B has the same output (content + reasoning)
                   and token count as the native row of the same cell and trial on each A serve;
  ordinary_route_identity  on B each mix ordinary row (row_invariant by v0.3.63) equals the mix
                   row of the same prompt and trial on each A serve (output and token count):
                   same route, row-invariant kernels, so the same bits;
  conv2_cache_reuse  every B conv2 turn-2 row reports cached_prompt_tokens > 0: the keyed turn
                   after a turn beside a native row reuses its KV (v0.3.63 conversation_cache);
  conv_identity    every conv1 and conv2 row of B in conv2 and conv_spread, and the conv_spread
                   unkeyed row (row_invariant on both serves), equals the same row on each A serve
                   (output and token count);
  conv_spread_joins  in every B conv_spread trial the unkeyed row is admitted row_invariant
                   (native_active) beside the conversation_cache row_invariant turn (admissions
                   idle=0 / native_active=2, phase-2 peak route requests row_invariant=2 /
                   stock_order=0), and the unkeyed row's turn2_overlap_share is > 0 (the two rows
                   decoded together, one forward);
  conv_flip_split  in every B conv_flip trial turn 2 decodes beside the native row
                   (native_overlap_share > 0) on its own route: phase-2 peak route requests
                   row_invariant=1 / stock_order=1;
  conv_flip_long_joins  in every B conv_flip_long trial turn 2 decodes beside the native row
                   (native_overlap_share > 0) on row_invariant: phase-2 peak route requests
                   row_invariant=2 / stock_order=0;
  token_counts     every pair compared for speed has equal token counts: native rows across
                   serves, and ordinary rows of the same cell, prompt and trial across serves
                   (ord1 and mix).
  INFO ordinary_serial: on B, mix ordinary rows (row_invariant) against the ord1 rows (stock
  order); a lone stock order row MAY differ in low bits from a row-invariant one.
Speed (AGENTS.md Swarm Runs step 3), medians per serve:
  goal: ordinary decode tok/s in ord1 (rows admitted from idle, so stock order on B); B must
  beat both neighbouring A serves;
  cost: ordinary decode tok/s in mix, native decode tok/s (nat1, mix), native acceptance (nat1,
  mix), mix aggregate output tok/s, conv_spread phase-2 aggregate output tok/s, conv_flip_long
  turn-2 decode tok/s: B >= (1 - cost) x each A; conv_flip_long re-prefill bound: B's phase-2
  wall exceeds each A's by at most the turn-2 TTFT difference plus cost x A's wall (the join
  re-prefills its stock_order entry by design, so the only loss allowed is that one prefill); TTFT medians (ord1 ordinary, nat1 native, mix native,
  conv2 turn 2, conv_flip turn 2, a hit on B): B <= (1 + cost) x each A + 0.05 s. Every gated
  speed median (goal, cost and TTFT) needs at least --min-samples samples per serve.
  INFO: the mix_late cell (2 ordinary rows, then the late request after --late-after chunks):
  aggregate, ordinary and late-row decode tok/s, late-row TTFT and its native admissions. With
  the signed max_native_active_rows = 1 the late request runs ordinary, so the cell measures
  three ordinary rows, not a transient route split. conv2: turn-1 decode tok/s and turn-2
  cached prompt tokens. conv_flip: turn-2 cached prompt tokens and the phase-2 aggregate output
  tok/s of the native row and turn 2 (on B a split: turn 2 hits its stock_order entry and
  decodes in its own forward beside the row_invariant native row). conv_flip_long: turn-2 TTFT,
  cached prompt tokens, phase-2 aggregate tok/s and wall (on B it re-prefills by design).
  Every goal median needs at least --min-samples samples per serve.
Prints T2462_* lines and one `T2462_VERDICT PASS|FAIL ...` line. Exit 0 PASS, 1 FAIL, 2 unusable input.
"""
import argparse
import collections
import json
import os
import statistics
import sys


def load(path):
    rows, trials = [], []
    with open(path) as f:
        for line in f:
            r = json.loads(line)
            (rows if r.get("kind") == "row" else trials).append(r)
    return rows, trials


def med(xs):
    xs = [x for x in xs if x is not None]
    return (round(statistics.median(xs), 4), len(xs)) if xs else (None, 0)


def acceptance(trials, cell):
    prop = acc = 0
    for t in trials:
        nm = t.get("native_mtp") or {}
        if t["cell"] == cell and nm.get("acceptance_valid"):
            prop += nm.get("proposed_tokens") or 0
            acc += nm.get("accepted_tokens") or 0
    return (round(acc / prop, 4), prop) if prop else (None, 0)


def metrics(rows, trials):
    def sel(cell, role, key):
        return [r.get(key) for r in rows if r["cell"] == cell and r["role"] == role]
    m = {
        "ord1_ordinary_decode_tps": med(sel("ord1", "ordinary", "decode_tps")),
        "mix_ordinary_decode_tps": med(sel("mix", "ordinary", "decode_tps")),
        "nat1_native_decode_tps": med(sel("nat1", "native", "decode_tps")),
        "mix_native_decode_tps": med(sel("mix", "native", "decode_tps")),
        "mix_aggregate_tps": med([t.get("aggregate_tps") for t in trials if t["cell"] == "mix"]),
        "ord1_ordinary_ttft_s": med(sel("ord1", "ordinary", "ttft_s")),
        "nat1_native_ttft_s": med(sel("nat1", "native", "ttft_s")),
        "mix_native_ttft_s": med(sel("mix", "native", "ttft_s")),
        "mix_ordinary_ttft_s": med(sel("mix", "ordinary", "ttft_s")),
        "mix_native_overlap_share": med(sel("mix", "ordinary", "native_overlap_share")),
        "nat1_acceptance": acceptance(trials, "nat1"),
        "mix_acceptance": acceptance(trials, "mix"),
        "conv2_turn2_ttft_s": med(sel("conv2", "conv2", "ttft_s")),
        "conv2_turn2_cached_prompt_tokens": med(sel("conv2", "conv2", "cached_prompt_tokens")),
        "conv2_turn1_decode_tps": med(sel("conv2", "conv1", "decode_tps")),
        "conv_flip_turn2_ttft_s": med(sel("conv_flip", "conv2", "ttft_s")),
        "conv_flip_turn2_cached_prompt_tokens": med(sel("conv_flip", "conv2", "cached_prompt_tokens")),
        "conv_flip_aggregate_tps": med([t.get("aggregate_tps") for t in trials if t["cell"] == "conv_flip"]),
        "conv_flip_long_aggregate_tps": med([t.get("aggregate_tps") for t in trials if t["cell"] == "conv_flip_long"]),
        "conv_flip_long_turn2_ttft_s": med(sel("conv_flip_long", "conv2", "ttft_s")),
        "conv_flip_long_turn2_decode_tps": med(sel("conv_flip_long", "conv2", "decode_tps")),
        "conv_flip_long_phase2_s": med(phase2_wall(trials, rows, "conv_flip_long")),
        "conv_flip_long_turn2_cached_prompt_tokens": med(sel("conv_flip_long", "conv2", "cached_prompt_tokens")),
        "conv_spread_aggregate_tps": med([t.get("aggregate_tps") for t in trials if t["cell"] == "conv_spread"]),
        "mix_late_aggregate_tps": med([t.get("aggregate_tps") for t in trials if t["cell"] == "mix_late"]),
        "mix_late_ordinary_decode_tps": med(sel("mix_late", "ordinary", "decode_tps")),
        "mix_late_late_decode_tps": med(sel("mix_late", "late", "decode_tps")),
        "mix_late_late_ttft_s": med(sel("mix_late", "late", "ttft_s")),
        "mix_late_late_overlap_share": med(sel("mix_late", "ordinary", "late_overlap_share")),
        "mix_late_native_admissions": med([(t.get("native_mtp") or {}).get("requests_since_reset")
                                           for t in trials if t["cell"] == "mix_late"]),
    }
    return m


def phase2_wall(trials, rows, cell):
    """Per trial: phase-2 output tokens (native row and turn 2) over the trial's phase-2 aggregate tok/s."""
    out = []
    for t in trials:
        if t["cell"] != cell or not t.get("aggregate_tps"):
            continue
        toks = sum(r.get("completion_tokens") or 0 for r in rows
                   if r.get("cell") == cell and r.get("trial") == t["trial"] and r.get("role") in ("native", "conv2"))
        if toks:
            out.append(toks / t["aggregate_tps"])
    return out


GOAL = ("ord1_ordinary_decode_tps",)
HIGHER = ("mix_ordinary_decode_tps", "nat1_native_decode_tps", "mix_native_decode_tps", "nat1_acceptance",
          "mix_acceptance", "mix_aggregate_tps", "conv_spread_aggregate_tps", "conv_flip_long_turn2_decode_tps")
LOWER = ("ord1_ordinary_ttft_s", "nat1_native_ttft_s", "mix_native_ttft_s", "conv2_turn2_ttft_s",
         "conv_flip_turn2_ttft_s")
INFO = ("mix_ordinary_ttft_s", "mix_native_overlap_share", "mix_late_aggregate_tps", "mix_late_ordinary_decode_tps",
        "mix_late_late_decode_tps", "mix_late_late_ttft_s", "mix_late_late_overlap_share",
        "mix_late_native_admissions", "conv2_turn2_cached_prompt_tokens",
        "conv2_turn1_decode_tps", "conv_flip_turn2_cached_prompt_tokens", "conv_flip_aggregate_tps",
        "conv_flip_long_turn2_ttft_s", "conv_flip_long_turn2_cached_prompt_tokens", "conv_flip_long_aggregate_tps",
        "conv_flip_long_phase2_s")
GATED_CELLS = ("ord1", "nat1", "mix", "conv2", "conv_flip", "conv_flip_long", "conv_spread")
CONV_IDENTITY_CELLS = ("conv2", "conv_spread")


def path_checks(label, mode, rows, trials, ord_rows):
    bad = []
    want_route = "mixed" if mode == "B" else "row_invariant"
    for r in rows:
        if r.get("error") or not r.get("completion_tokens"):
            bad.append(f"{label} {r['cell']} t{r['trial']} row{r['prompt_row']}: {r.get('error') or 'no tokens'}")
    for t in trials:
        nm = t.get("native_mtp") or {}
        want = 0 if t["cell"] == "ord1" else 1
        if not nm.get("acceptance_valid"):
            bad.append(f"{label} {t['cell']} t{t['trial']}: native_mtp counters unreadable or reset")
            continue
        if t["cell"] not in GATED_CELLS:
            if t.get("small_m_route") != want_route:
                bad.append(f"{label} {t['cell']} t{t['trial']}: small_m_route {t.get('small_m_route')} != {want_route}")
            if t["cell"] == "mix_late" and (nm.get("requests_since_reset") or 0) > 0:
                bad.append(f"{label} mix_late t{t['trial']}: late request admitted native "
                           f"({nm.get('requests_since_reset')}); the cell assumes it runs ordinary")
            continue
        if nm.get("requests_since_reset") != want:
            bad.append(f"{label} {t['cell']} t{t['trial']}: native admissions {nm.get('requests_since_reset')} != {want}")
        if nm.get("preoutput_fallbacks") or nm.get("postoutput_failures"):
            bad.append(f"{label} {t['cell']} t{t['trial']}: native fallback/failure {nm.get('preoutput_fallbacks')}/{nm.get('postoutput_failures')}")
        if want and not nm.get("proposed_tokens"):
            bad.append(f"{label} {t['cell']} t{t['trial']}: no native proposal")
        if t.get("small_m_route") != want_route:
            bad.append(f"{label} {t['cell']} t{t['trial']}: small_m_route {t.get('small_m_route')} != {want_route}")
        if t["cell"] == "mix":
            if t.get("peak_active_decode_rows") != 1 + ord_rows:
                bad.append(f"{label} mix t{t['trial']}: peak active decode rows {t.get('peak_active_decode_rows')} != {1 + ord_rows}")
            if mode == "B":
                pk = t.get("peak_small_m_route_requests") or {}
                if pk.get("row_invariant") != 1 + ord_rows or pk.get("stock_order"):
                    bad.append(f"{label} mix t{t['trial']}: peak route requests {pk} != row_invariant={1 + ord_rows} stock_order=0")
        if mode == "B":
            want_adm = {
                "ord1": {"idle": ord_rows, "native_active": 0, "native_admitted": 0, "conversation_cache": 0},
                "nat1": {"idle": 0, "native_active": 0, "native_admitted": 1, "conversation_cache": 0},
                "mix": {"idle": 0, "native_active": ord_rows, "native_admitted": 1, "conversation_cache": 0},
                "conv2": {"idle": 0, "native_active": 1, "native_admitted": 1, "conversation_cache": 1},
                "conv_flip": {"idle": 1, "native_active": 0, "native_admitted": 1, "conversation_cache": 1},
                "conv_flip_long": {"idle": 1, "native_active": 0, "native_admitted": 1, "conversation_cache": 0,
                                   "conversation_cache_join": 1},
                "conv_spread": {"idle": 0, "native_active": 2, "native_admitted": 1, "conversation_cache": 1},
            }[t["cell"]]
            want_adm.setdefault("conversation_cache_join", 0)
            adm = t.get("small_m_route_admissions")
            if adm is None or any(adm.get(k) != v for k, v in want_adm.items()):
                bad.append(f"{label} {t['cell']} t{t['trial']}: route admissions {adm} != {want_adm}")
    return bad


def key(r):
    return (r["cell"], r["trial"], r["role"], r["prompt_row"])


def main(argv=None):
    p = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    p.add_argument("--res", required=True)
    p.add_argument("--serves", default="A1:A,B:B,A2:A")
    p.add_argument("--ord-rows", type=int, default=2)
    p.add_argument("--min-samples", type=int, default=6)
    p.add_argument("--cost-pct", type=float, default=3.0)
    p.add_argument("--tests-ok", type=int, default=1, help="0 when the job's filtered or fork tests failed")
    p.add_argument("--json")
    a = p.parse_args(argv)
    serves = [tuple(s.split(":")) for s in a.serves.split(",")]
    labels = [l for l, _ in serves]
    modes = dict(serves)
    if [m for _, m in serves] != ["A", "B", "A"]:
        print("T2462_ERROR --serves must be control:A,candidate:B,control:A", flush=True)
        return 2
    data = {}
    for label, _ in serves:
        path = os.path.join(a.res, label, "rows.jsonl")
        if not os.path.isfile(path):
            print(f"T2462_ERROR no rows at {path}")
            return 2
        data[label] = load(path)
    a1, b, a2 = labels
    cost = a.cost_pct / 100.0
    failures = [] if a.tests_ok else ["tests"]
    if not a.tests_ok:
        print("T2462_GATE tests FAIL (filtered Metal tests or mlx-swift SmallMRouteTests; job log TESTS_DONE / FORK_TESTS_DONE)")

    # Path checks.
    for label in labels:
        for msg in path_checks(label, modes[label], *data[label], a.ord_rows):
            print(f"T2462_PATH_FAIL {msg}")
            failures.append("path")
    by = {label: {key(r): r for r in data[label][0]} for label in labels}

    # Gate: native identity A vs B, and token counts.
    nat_mismatch = tok_mismatch = 0
    for k, rb in by[b].items():
        if k[2] != "native" or k[0] not in GATED_CELLS:
            continue
        for ctl in (a1, a2):
            ra = by[ctl].get(k)
            if ra is None or ra["output_sha256"] != rb["output_sha256"]:
                nat_mismatch += 1
                print(f"T2462_NATIVE_DIFF {ctl} vs {b} cell={k[0]} trial={k[1]}")
            if ra is None or ra.get("completion_tokens") != rb.get("completion_tokens"):
                tok_mismatch += 1
    # Gate: B mix ordinary rows (row_invariant, v0.3.63) equal the A mix rows.
    route_mismatch = 0
    for k, rb in by[b].items():
        if k[0] != "mix" or k[2] != "ordinary":
            continue
        for ctl in (a1, a2):
            ra = by[ctl].get(k)
            if ra is None or ra["output_sha256"] != rb["output_sha256"] or ra.get("completion_tokens") != rb.get("completion_tokens"):
                route_mismatch += 1
                print(f"T2462_ORDINARY_ROUTE_DIFF {ctl} vs {b} trial={k[1]} prompt_row={k[3]} "
                      f"tokens={rb.get('completion_tokens')}/{ra.get('completion_tokens') if ra else None}")
    # INFO: B mix ordinary rows (row_invariant) against the B ord1 rows (stock order).
    ser_diff = 0
    for k, rb in by[b].items():
        if k[0] != "mix" or k[2] != "ordinary":
            continue
        ref = by[b].get(("ord1", k[1], "ordinary", k[3]))
        if ref is None or ref["output_sha256"] != rb["output_sha256"] or ref.get("completion_tokens") != rb.get("completion_tokens"):
            ser_diff += 1
    # Token counts of ordinary rows across serves (equal work for the speed comparison).
    ord_text_diff = 0
    for k, rb in by[b].items():
        if k[2] != "ordinary" or k[0] not in GATED_CELLS:
            continue
        for ctl in (a1, a2):
            ra = by[ctl].get(k)
            if ra is None or ra.get("completion_tokens") != rb.get("completion_tokens"):
                tok_mismatch += 1
                print(f"T2462_TOKEN_COUNT_DIFF {ctl} vs {b} cell={k[0]} trial={k[1]} prompt_row={k[3]}")
            elif ra["output_sha256"] != rb["output_sha256"]:
                ord_text_diff += 1
    # INFO: on A (row-invariant), mix ordinary rows equal their ord1 rows too.
    a_ser = sum(1 for ctl in (a1, a2) for k, ra in by[ctl].items()
                if k[0] == "mix" and k[2] == "ordinary"
                and (by[ctl].get(("ord1", k[1], "ordinary", k[3])) or {}).get("output_sha256") != ra["output_sha256"])
    finish = collections.Counter(r.get("finish") for label in labels for r in data[label][0])
    print(f"T2462_INFO a_mix_vs_ord1_diffs={a_ser} b_mix_vs_ord1_diffs={ser_diff} "
          f"ordinary_a_vs_b_text_diffs={ord_text_diff} finish={dict(finish)}")

    # Gate: the keyed turn 2 on B reuses turn 1's KV.
    conv_turn2 = [r for r in data[b][0] if r["cell"] == "conv2" and r["role"] == "conv2"]
    conv_misses = [r["trial"] for r in conv_turn2 if not (r.get("cached_prompt_tokens") or 0) > 0]
    for trial in conv_misses:
        print(f"T2462_CONV2_CACHE_MISS {b} trial={trial}")
    # Gate: keyed turns on row_invariant on both serves have the same output.
    conv_mismatch = 0
    conv_keys = [k for k in by[b] if k[0] in CONV_IDENTITY_CELLS
                 and (k[2] in ("conv1", "conv2") or (k[0] == "conv_spread" and k[2] == "unkeyed"))]
    for k in conv_keys:
        rb = by[b][k]
        for ctl in (a1, a2):
            ra = by[ctl].get(k)
            if ra is None or ra["output_sha256"] != rb["output_sha256"] or ra.get("completion_tokens") != rb.get("completion_tokens"):
                conv_mismatch += 1
                print(f"T2462_CONV_DIFF {ctl} vs {b} cell={k[0]} trial={k[1]} role={k[2]}")
    # Gate: the unkeyed row joins the conversation_cache row_invariant turn (v0.3.64).
    spread_trials = [t for t in data[b][1] if t["cell"] == "conv_spread"]
    spread_bad = []
    for t in spread_trials:
        adm = t.get("small_m_route_admissions") or {}
        pk = t.get("peak_small_m_route_requests") or {}
        unkeyed = by[b].get(("conv_spread", t["trial"], "unkeyed", a.ord_rows + 4)) or {}
        overlap = unkeyed.get("turn2_overlap_share")
        if (adm.get("idle") != 0 or adm.get("native_active") != 2 or pk.get("stock_order")
                or pk.get("row_invariant") != 2 or not (overlap or 0) > 0):
            spread_bad.append(t["trial"])
            print(f"T2462_CONV_SPREAD_NO_JOIN {b} trial={t['trial']} admissions={adm} phase2_peak_routes={pk} "
                  f"unkeyed_turn2_overlap_share={overlap}")
    # Gates: conv_flip splits beside the native row; conv_flip_long joins it (v0.3.65 cost rule).
    flip_bad = {"conv_flip": [], "conv_flip_long": []}
    flip_trials = {c: [t for t in data[b][1] if t["cell"] == c] for c in flip_bad}
    want_peak = {"conv_flip": {"row_invariant": 1, "stock_order": 1},
                 "conv_flip_long": {"row_invariant": 2, "stock_order": 0}}
    for cell, trials_c in flip_trials.items():
        for t in trials_c:
            pk = t.get("peak_small_m_route_requests") or {}
            turn2 = by[b].get((cell, t["trial"], "conv2", a.ord_rows + {"conv_flip": 2, "conv_flip_long": 5}[cell])) or {}
            overlap = turn2.get("native_overlap_share")
            if (any((pk.get(k) or 0) != v for k, v in want_peak[cell].items()) or not (overlap or 0) > 0):
                flip_bad[cell].append(t["trial"])
                print(f"T2462_CONV_FLIP_PATH {b} cell={cell} trial={t['trial']} phase2_peak_routes={pk} "
                      f"turn2_native_overlap_share={overlap} want={want_peak[cell]}")
    gates = {
        "native_identity": nat_mismatch == 0,
        "ordinary_route_identity": route_mismatch == 0,
        "conv2_cache_reuse": bool(conv_turn2) and not conv_misses,
        "conv_identity": bool(conv_keys) and conv_mismatch == 0,
        "conv_spread_joins": bool(spread_trials) and not spread_bad,
        "conv_flip_split": bool(flip_trials["conv_flip"]) and not flip_bad["conv_flip"],
        "conv_flip_long_joins": bool(flip_trials["conv_flip_long"]) and not flip_bad["conv_flip_long"],
        "token_counts": tok_mismatch == 0,
    }
    for g, ok in gates.items():
        print(f"T2462_GATE {g} {'PASS' if ok else 'FAIL'}")
        if not ok:
            failures.append(g)

    # Speed.
    m = {label: metrics(*data[label]) for label in labels}
    speed = {}
    for name in GOAL + HIGHER + LOWER + INFO:
        vb, nb = m[b][name]
        va1, na1 = m[a1][name]
        va2, na2 = m[a2][name]
        ratios = [round(vb / va, 4) if vb is not None and va else None for va in (va1, va2)]
        if name in GOAL:
            ok = (vb is not None and all(va is not None and vb > va for va in (va1, va2))
                  and min(nb, na1, na2) >= a.min_samples)
        elif name in HIGHER:
            ok = (vb is not None and all(va is not None and vb >= (1 - cost) * va for va in (va1, va2))
                  and min(nb, na1, na2) >= a.min_samples)
        elif name in LOWER:
            ok = (vb is not None and all(va is not None and vb <= (1 + cost) * va + 0.05 for va in (va1, va2))
                  and min(nb, na1, na2) >= a.min_samples)
        else:
            ok = None
        speed[name] = {"A1": va1, "B": vb, "A2": va2, "n": [na1, nb, na2], "B_over_A": ratios, "ok": ok}
        print(f"T2462_METRIC {name} {a1}={va1} {b}={vb} {a2}={va2} n={na1}/{nb}/{na2} "
              f"B/A1={ratios[0]} B/A2={ratios[1]} {'PASS' if ok else ('INFO' if ok is None else 'FAIL')}")
        if ok is False:
            failures.append(name)

    # conv_flip_long joins and re-prefills its stock_order entry by design (v0.3.65 cost rule), so
    # its phase-2 aggregate is INFO. Gate instead: B's phase-2 wall exceeds each A's by at most the
    # turn-2 TTFT difference plus `cost` x A's wall, i.e. the only loss is the one re-prefill, and
    # turn-2 decode tok/s (HIGHER) holds.
    wb = speed["conv_flip_long_phase2_s"]["B"]; tb = speed["conv_flip_long_turn2_ttft_s"]["B"]
    bound_ok = wb is not None and tb is not None
    for al in ("A1", "A2"):
        wa = speed["conv_flip_long_phase2_s"][al]; ta = speed["conv_flip_long_turn2_ttft_s"][al]
        bound_ok = bound_ok and wa is not None and ta is not None and wb - wa <= (tb - ta) + cost * wa
    gates["conv_flip_long_reprefill_bound"] = bool(bound_ok)
    print(f"T2462_GATE conv_flip_long_reprefill_bound {'PASS' if bound_ok else 'FAIL'}")
    if not bound_ok:
        failures.append("conv_flip_long_reprefill_bound")

    def gain(name):
        r = speed[name]["B_over_A"]
        return "/".join("n/a" if x is None else f"{(x - 1) * 100:+.1f}%" for x in r)

    verdict = "PASS" if not failures else "FAIL"
    s = speed
    line = (f"T2462_VERDICT {verdict} ord1_ordinary_tps(admitted from idle) A1/B/A2={s['ord1_ordinary_decode_tps']['A1']}/"
            f"{s['ord1_ordinary_decode_tps']['B']}/{s['ord1_ordinary_decode_tps']['A2']} ({gain('ord1_ordinary_decode_tps')}) "
            f"mix_ordinary_tps={s['mix_ordinary_decode_tps']['A1']}/{s['mix_ordinary_decode_tps']['B']}/"
            f"{s['mix_ordinary_decode_tps']['A2']} ({gain('mix_ordinary_decode_tps')}) "
            f"mix_native_tps={s['mix_native_decode_tps']['A1']}/{s['mix_native_decode_tps']['B']}/"
            f"{s['mix_native_decode_tps']['A2']} ({gain('mix_native_decode_tps')}) "
            f"nat1_native_tps ({gain('nat1_native_decode_tps')}) "
            f"acceptance nat1={s['nat1_acceptance']['B']} mix={s['mix_acceptance']['B']} "
            f"mix_aggregate_tps={s['mix_aggregate_tps']['A1']}/{s['mix_aggregate_tps']['B']}/{s['mix_aggregate_tps']['A2']} "
            f"({gain('mix_aggregate_tps')}) ttft_ord1={s['ord1_ordinary_ttft_s']['B']}s ttft_native={s['nat1_native_ttft_s']['B']}s "
            f"mix_late_aggregate_tps={s['mix_late_aggregate_tps']['A1']}/{s['mix_late_aggregate_tps']['B']}/"
            f"{s['mix_late_aggregate_tps']['A2']} ({gain('mix_late_aggregate_tps')}, INFO) "
            f"conv2_turn2_ttft={s['conv2_turn2_ttft_s']['A1']}/{s['conv2_turn2_ttft_s']['B']}/{s['conv2_turn2_ttft_s']['A2']}s "
            f"conv2_turn2_cached={s['conv2_turn2_cached_prompt_tokens']['B']} "
            f"gates native_identity={gates['native_identity']} ordinary_route_identity={gates['ordinary_route_identity']} "
            f"conv2_cache_reuse={gates['conv2_cache_reuse']} conv_identity={gates['conv_identity']} "
            f"conv_spread_joins={gates['conv_spread_joins']} "
            f"conv_spread_aggregate_tps={s['conv_spread_aggregate_tps']['A1']}/{s['conv_spread_aggregate_tps']['B']}/"
            f"{s['conv_spread_aggregate_tps']['A2']} ({gain('conv_spread_aggregate_tps')}) "
            f"conv_flip_turn2_ttft={s['conv_flip_turn2_ttft_s']['A1']}/{s['conv_flip_turn2_ttft_s']['B']}/"
            f"{s['conv_flip_turn2_ttft_s']['A2']}s ({gain('conv_flip_turn2_ttft_s')}) "
            f"conv_flip_aggregate_tps={s['conv_flip_aggregate_tps']['B']} ({gain('conv_flip_aggregate_tps')}, INFO) "
            f"conv_flip_split={gates['conv_flip_split']} conv_flip_long_joins={gates['conv_flip_long_joins']} "
            f"conv_flip_long_aggregate_tps={s['conv_flip_long_aggregate_tps']['A1']}/"
            f"{s['conv_flip_long_aggregate_tps']['B']}/{s['conv_flip_long_aggregate_tps']['A2']} "
            f"({gain('conv_flip_long_aggregate_tps')}) "
            f"conv_flip_long_turn2_ttft={s['conv_flip_long_turn2_ttft_s']['B']}s "
            f"({gain('conv_flip_long_turn2_ttft_s')}, INFO) "
            f"token_counts={gates['token_counts']}"
            + (f" failed={','.join(sorted(set(failures)))}" if failures else ""))
    print(line, flush=True)
    if a.json:
        with open(a.json, "w") as f:
            json.dump({"verdict": verdict, "failures": sorted(set(failures)), "gates": gates, "metrics": speed,
                       "serves": serves, "ord_rows": a.ord_rows, "line": line}, f, indent=2)
    return 0 if verdict == "PASS" else 1


if __name__ == "__main__":
    sys.exit(main())
