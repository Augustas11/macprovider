#!/usr/bin/env python3
"""#2462 verdict: control-candidate-control serves of mixed_load.py, gates and medians (stdlib only).

usage: verdict.py --res RES_DIR --serves A1:A,B:B,A2:A [--ord-rows 2] [--min-samples 6]
                  [--cost-pct 3] [--tests-ok 1] [--json verdict.json]

RES_DIR/<label>/rows.jsonl per serve; mode A = process-wide row_invariant (config
small_m_route: row_invariant), mode B = mixed. The B serve must sit between two A serves.

Path checks (a failure means the cells did not measure what they claim):
  every request returned usage and no error; per trial the native_mtp admissions are 0 in ord1
  and 1 in nat1 and mix, with no pre-output fallback or post-output failure and counters not
  reset; every A trial reports small_m_route row_invariant and every B trial mixed; a mix trial
  peaks at 1 + ord_rows active decode rows, and on B at row_invariant=1 / stock_order=ord_rows
  in-flight route requests; native proposals > 0 in nat1 and mix.
Gates:
  native_identity  every native row (nat1 and mix) of B has the same output (content + reasoning)
                   and token count as the native row of the same cell and trial on each A serve;
  ordinary_serial  on B, each mix ordinary row equals the ord1 row of the same prompt and trial
                   (output and token count): SPEC-038 FR-CB9 stock order, a lone row equals the
                   same row of a 1- or 2-row forward. Gated only for ord_rows <= 2 (3+ rows MAY
                   differ in low bits); reported otherwise;
  token_counts     every pair compared for speed has equal token counts: native rows across
                   serves, and ordinary rows of the same cell, prompt and trial across serves.
Speed (AGENTS.md Swarm Runs step 3), medians per serve:
  goal: ordinary decode tok/s in ord1 and in mix; B must beat both neighbouring A serves;
  cost: native decode tok/s (nat1, mix), native acceptance (nat1, mix), mix aggregate output
  tok/s: B >= (1 - cost) x each A; TTFT medians (ord1 ordinary, nat1 native, mix native):
  B <= (1 + cost) x each A + 0.05 s.
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
    }
    return m


GOAL = ("ord1_ordinary_decode_tps", "mix_ordinary_decode_tps")
HIGHER = ("nat1_native_decode_tps", "mix_native_decode_tps", "nat1_acceptance", "mix_acceptance", "mix_aggregate_tps")
LOWER = ("ord1_ordinary_ttft_s", "nat1_native_ttft_s", "mix_native_ttft_s")
INFO = ("mix_ordinary_ttft_s", "mix_native_overlap_share")


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
                if pk.get("row_invariant") != 1 or pk.get("stock_order") != ord_rows:
                    bad.append(f"{label} mix t{t['trial']}: peak route requests {pk} != row_invariant=1 stock_order={ord_rows}")
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
        if k[2] != "native":
            continue
        for ctl in (a1, a2):
            ra = by[ctl].get(k)
            if ra is None or ra["output_sha256"] != rb["output_sha256"]:
                nat_mismatch += 1
                print(f"T2462_NATIVE_DIFF {ctl} vs {b} cell={k[0]} trial={k[1]}")
            if ra is None or ra.get("completion_tokens") != rb.get("completion_tokens"):
                tok_mismatch += 1
    # Gate: B mix ordinary rows equal the B ord1 serial reference.
    ser_mismatch = 0
    for k, rb in by[b].items():
        if k[0] != "mix" or k[2] != "ordinary":
            continue
        ref = by[b].get(("ord1", k[1], "ordinary", k[3]))
        if ref is None or ref["output_sha256"] != rb["output_sha256"] or ref.get("completion_tokens") != rb.get("completion_tokens"):
            ser_mismatch += 1
            print(f"T2462_ORDINARY_SERIAL_DIFF {b} trial={k[1]} prompt_row={k[3]} "
                  f"tokens={rb.get('completion_tokens')}/{ref.get('completion_tokens') if ref else None}")
    # Token counts of ordinary rows across serves (equal work for the speed comparison).
    ord_text_diff = 0
    for k, rb in by[b].items():
        if k[2] != "ordinary":
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
    print(f"T2462_INFO a_mix_vs_ord1_diffs={a_ser} ordinary_a_vs_b_text_diffs={ord_text_diff} finish={dict(finish)}")

    gates = {
        "native_identity": nat_mismatch == 0,
        "ordinary_serial": ser_mismatch == 0 if a.ord_rows <= 2 else None,
        "token_counts": tok_mismatch == 0,
    }
    for g, ok in gates.items():
        print(f"T2462_GATE {g} {'PASS' if ok else ('INFO' if ok is None else 'FAIL')}"
              + (f" mismatches={ser_mismatch} (ord_rows={a.ord_rows} > 2: not gated)" if ok is None else ""))
        if ok is False:
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
            ok = vb is not None and all(va is not None and vb >= (1 - cost) * va for va in (va1, va2))
        elif name in LOWER:
            ok = vb is not None and all(va is not None and vb <= (1 + cost) * va + 0.05 for va in (va1, va2))
        else:
            ok = None
        speed[name] = {"A1": va1, "B": vb, "A2": va2, "n": [na1, nb, na2], "B_over_A": ratios, "ok": ok}
        print(f"T2462_METRIC {name} {a1}={va1} {b}={vb} {a2}={va2} n={na1}/{nb}/{na2} "
              f"B/A1={ratios[0]} B/A2={ratios[1]} {'PASS' if ok else ('INFO' if ok is None else 'FAIL')}")
        if ok is False:
            failures.append(name)

    def gain(name):
        r = speed[name]["B_over_A"]
        return "/".join("n/a" if x is None else f"{(x - 1) * 100:+.1f}%" for x in r)

    verdict = "PASS" if not failures else "FAIL"
    s = speed
    line = (f"T2462_VERDICT {verdict} ord1_ordinary_tps A1/B/A2={s['ord1_ordinary_decode_tps']['A1']}/"
            f"{s['ord1_ordinary_decode_tps']['B']}/{s['ord1_ordinary_decode_tps']['A2']} ({gain('ord1_ordinary_decode_tps')}) "
            f"mix_ordinary_tps={s['mix_ordinary_decode_tps']['A1']}/{s['mix_ordinary_decode_tps']['B']}/"
            f"{s['mix_ordinary_decode_tps']['A2']} ({gain('mix_ordinary_decode_tps')}) "
            f"mix_native_tps={s['mix_native_decode_tps']['A1']}/{s['mix_native_decode_tps']['B']}/"
            f"{s['mix_native_decode_tps']['A2']} ({gain('mix_native_decode_tps')}) "
            f"nat1_native_tps ({gain('nat1_native_decode_tps')}) "
            f"acceptance nat1={s['nat1_acceptance']['B']} mix={s['mix_acceptance']['B']} "
            f"mix_aggregate_tps={s['mix_aggregate_tps']['A1']}/{s['mix_aggregate_tps']['B']}/{s['mix_aggregate_tps']['A2']} "
            f"({gain('mix_aggregate_tps')}) ttft_ord1={s['ord1_ordinary_ttft_s']['B']}s ttft_native={s['nat1_native_ttft_s']['B']}s "
            f"gates native_identity={gates['native_identity']} ordinary_serial={gates['ordinary_serial']} "
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
