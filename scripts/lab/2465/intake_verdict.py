"""Verdict for a catalog-intake window: one candidate against the incumbent row, same window.

usage: intake_verdict.py --issue N --res RES --incumbent LABEL --candidate LABEL [--json OUT]

Reads RES/<cell>/<label>... as the #2465 / #2466 jobs write them:
  decode/<label>-<ctx>.json       decode-bench (samples[].decodeTPS, prefillTPS, ttftSeconds)
  aggregate/<label>-*.json        msb-throughput throughput / msb03 (only #2466)
  parity/<label>.json             msb-throughput --scenario parity (leftovers.parity.pass, oneRowMatch)
  ref/<label>/glm-parity.json     glm-parity against the reference oracles
  mtp/<label>/{bench.jsonl,analysis.json}   native-mtp-bench + scripts/native_mtp_r015_analyze.py
  quality/<label>-score.json      quality.py score

Gates (the issue's plan; no other gate is invented here):
  parity   the candidate's batched-vs-serial parity passes, and at every reference context the
           candidate keeps top-1 on all logged steps (free run, or teacher-forced once it left the
           oracle) wherever the incumbent does: a context the incumbent also misses is reported,
           not held against the candidate;
  mtp      the analyzer's overall_status for the candidate is PASS (formal R015 for #2465,
           exploratory s1 cells for #2466); acceptance (accepted / proposed native tokens over
           the measured matrix records) is reported for both models on their common cells;
  quality  the candidate passes at least as many rubric cases as the incumbent, and the pair is
           not 0 / 0 (a subset that distinguishes nothing is INCONCLUSIVE: retain the incumbent).
A missing input fails its gate. Exit 0 PASS, 1 FAIL, 2 unusable arguments.
"""
import argparse
import glob
import json
import os
import statistics
import sys


def load(path):
    try:
        with open(path) as f:
            return json.load(f)
    except Exception:
        return None


def g(d, *names):
    """First present key among camelCase / snake_case spellings."""
    for n in names:
        if isinstance(d, dict) and n in d:
            return d[n]
    return None


def decode_cells(res, label):
    out = {}
    for p in sorted(glob.glob(os.path.join(res, "decode", f"{label}-*.json"))):
        doc = load(p)
        ctx = os.path.basename(p)[len(label) + 1:-5]
        s = (g(doc, "samples") or []) if doc else []
        tps = [g(x, "decodeTPS", "decode_tps") for x in s if g(x, "decodeTPS", "decode_tps") is not None]
        pre = [g(x, "prefillTPS", "prefill_tps") for x in s if g(x, "prefillTPS", "prefill_tps") is not None]
        ttft = [g(x, "ttftSeconds", "ttft_seconds") for x in s if g(x, "ttftSeconds", "ttft_seconds") is not None]
        toks = [g(x, "decodeTokensActual", "decode_tokens_actual") for x in s]
        out[ctx] = {"decode_tps_p50": statistics.median(tps) if tps else None,
                    "decode_tps_min": min(tps) if tps else None, "decode_tps_max": max(tps) if tps else None,
                    "prefill_tps_p50": statistics.median(pre) if pre else None,
                    "ttft_p50_s": statistics.median(ttft) if ttft else None, "decode_tokens_actual": toks}
    return out


def aggregate_cells(res, label):
    out = {}
    for p in sorted(glob.glob(os.path.join(res, "aggregate", f"{label}-*.json"))):
        doc = load(p) or {}
        out[os.path.basename(p)[len(label) + 1:-5]] = {
            k: g(doc, k) for k in ("aggregateTPSp50", "aggregateVsProductionSerial", "perRowTPSp50",
                                   "makespanAggregateTokensPerSecond", "makespanVsSerial")}
    return out


def parity_cell(res, label):
    doc = load(os.path.join(res, "parity", f"{label}.json"))
    if doc is None:
        return None
    # msb-throughput --scenario parity nests the verdict under leftovers.parity.
    doc = g(g(doc, "leftovers"), "parity") or doc
    return {"pass": g(doc, "pass"), "oneRowMatch": g(doc, "oneRowMatch", "one_row_match"),
            "firstDivergenceIndex": g(doc, "firstDivergenceIndex", "first_divergence_index")}


def ref_cells(res, label):
    doc = load(os.path.join(res, "ref", label, "glm-parity.json"))
    if doc is None:
        return None
    out = {}
    for run in g(doc, "runs") or []:
        m = g(run, "measurement") or {}
        free = g(m, "freeRunning", "free_running") or {}
        forced = g(m, "teacherForced", "teacher_forced")
        judged = forced or free
        ctx = str(g(m, "promptTokens", "prompt_tokens"))
        out[ctx] = {"first_divergence": g(free, "firstDivergence", "first_divergence"),
                    "matching": g(free, "matchingTokens", "matching_tokens"),
                    "compared": g(free, "comparedTokens", "compared_tokens"),
                    "forced_matching": g(forced, "matchingTokens", "matching_tokens") if forced else None,
                    "top1": g(judged, "top1Agreement", "top1_agreement"),
                    "top1_compared": g(judged, "top1Compared", "top1_compared"),
                    "max_abs_logit_diff": g(judged, "maxAbsLogitDiff", "max_abs_logit_diff"),
                    "decode_tps": g(m, "decodeTokensPerSecond", "decode_tokens_per_second")}
        c = out[ctx]
        c["top1_ok"] = c["top1"] is not None and c["top1"] == c["top1_compared"] and c["top1_compared"] > 0
    return out


def mtp_cell(res, label):
    d = os.path.join(res, "mtp", label)
    analysis = load(os.path.join(d, "analysis.json"))
    per = {}
    try:
        with open(os.path.join(d, "bench.jsonl")) as f:
            for line in f:
                r = json.loads(line)
                if r.get("record_type") != "run" or r.get("warmup") or r.get("sustained") or r.get("path") != "native_mtp":
                    continue
                c = per.setdefault(r["cell_id"], [0, 0])
                c[0] += r.get("mtp_proposed_tokens") or 0
                c[1] += r.get("mtp_accepted_tokens") or 0
    except OSError:
        pass
    cells = {}
    for cid, (p, a) in sorted(per.items()):
        cells[cid] = {"proposed": p, "accepted": a, "acceptance": a / p if p else None}
    for c in (analysis or {}).get("cells", []):
        e = cells.setdefault(c["cell_id"], {})
        e["status"] = c.get("status")
        e["throughput_median"] = ((c.get("metrics") or {}).get("throughput") or {}).get("median")
    return {"overall_status": (analysis or {}).get("overall_status", "MISSING"), "cells": cells}


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--issue", required=True)
    ap.add_argument("--res", required=True)
    ap.add_argument("--incumbent", required=True)
    ap.add_argument("--candidate", required=True)
    ap.add_argument("--json")
    a = ap.parse_args()
    if not os.path.isdir(a.res):
        print(f"no results dir {a.res}", file=sys.stderr)
        return 2
    inc, cand = a.incumbent, a.candidate
    rep = {"issue": a.issue, "incumbent": inc, "candidate": cand, "models": {}}
    for m in (inc, cand):
        rep["models"][m] = {"decode": decode_cells(a.res, m), "aggregate": aggregate_cells(a.res, m), "parity": parity_cell(a.res, m), "ref": ref_cells(a.res, m),
                            "mtp": mtp_cell(a.res, m), "quality": load(os.path.join(a.res, "quality", f"{m}-score.json"))}
    I, C = rep["models"][inc], rep["models"][cand]
    reasons = []

    # parity
    p_ok = bool(C["parity"] and C["parity"]["pass"] is True)
    if not p_ok:
        reasons.append("candidate batched-vs-serial parity not PASS")
    ref_notes = []
    if not C["ref"]:
        p_ok = False
        reasons.append("candidate reference parity missing")
    else:
        for ctx, c in sorted(C["ref"].items(), key=lambda kv: int(kv[0]) if kv[0].isdigit() else 0):
            i = (I["ref"] or {}).get(ctx)
            if not c["top1_ok"]:
                if i and not i["top1_ok"]:
                    ref_notes.append(f"{ctx}: both miss top-1 ({c['top1']}/{c['top1_compared']} vs {i['top1']}/{i['top1_compared']})")
                else:
                    p_ok = False
                    reasons.append(f"reference parity at {ctx}: top-1 {c['top1']}/{c['top1_compared']}")
    # mtp
    m_ok = C["mtp"]["overall_status"] == "PASS"
    if not m_ok:
        reasons.append(f"candidate native MTP analyzer {C['mtp']['overall_status']}")
    common = sorted(set(I["mtp"]["cells"]) & set(C["mtp"]["cells"]))
    acc = {}
    for cid in common:
        ic, cc = I["mtp"]["cells"][cid], C["mtp"]["cells"][cid]
        if ic.get("acceptance") is not None and cc.get("acceptance") is not None:
            acc[cid] = (ic["acceptance"], cc["acceptance"])

    def pooled(cells):
        p = sum(cells[c].get("proposed") or 0 for c in common)
        n = sum(cells[c].get("accepted") or 0 for c in common)
        return (n / p if p else None), p, n
    inc_acc, inc_p, inc_a = pooled(I["mtp"]["cells"])
    cand_acc, cand_p, cand_a = pooled(C["mtp"]["cells"])
    # quality
    iq, cq = I["quality"], C["quality"]
    if not iq or not cq:
        q_state = "MISSING"
    elif iq["passed"] == 0 and cq["passed"] == 0:
        q_state = "INCONCLUSIVE"
    elif cq["passed"] >= iq["passed"]:
        q_state = "PASS"
    else:
        q_state = "FAIL"
    if q_state != "PASS":
        reasons.append(f"quality {q_state}")
    verdict = "PASS" if (p_ok and m_ok and q_state == "PASS") else "FAIL"

    def f(x, nd=3):
        return "na" if x is None else (f"{x:.{nd}f}" if isinstance(x, float) else str(x))
    ref_str = ",".join(f"{ctx}:{c['top1']}/{c['top1_compared']}m{c['matching']}" for ctx, c in sorted((C["ref"] or {}).items()))
    line = (f"T{a.issue}_VERDICT {verdict} parity={'PASS' if p_ok else 'FAIL'}"
            f" msb_parity={f((C['parity'] or {}).get('pass'))} ref_top1[{ref_str}]"
            f" mtp={C['mtp']['overall_status']} acceptance={f(cand_acc)}({cand_a}/{cand_p}) vs {inc}={f(inc_acc)}({inc_a}/{inc_p})"
            f" quality={q_state} {cand}={f((cq or {}).get('passed'))}/{f((cq or {}).get('cases'))}"
            f" {inc}={f((iq or {}).get('passed'))}/{f((iq or {}).get('cases'))}"
            + (f" reasons=\"{'; '.join(reasons)}\"" if reasons else ""))
    rep.update(verdict=verdict, reasons=reasons, ref_notes=ref_notes, acceptance_common_cells=acc,
               acceptance_pooled={inc: inc_acc, cand: cand_acc}, quality_state=q_state, line=line)

    print(f"# #{a.issue} intake: {cand} against {inc} (same window)\n")
    print("| Cell | " + inc + " | " + cand + " |\n|---|---:|---:|")
    for ctx in sorted(set(I["decode"]) | set(C["decode"]), key=lambda x: int(x) if x.isdigit() else 0):
        i, c = I["decode"].get(ctx, {}), C["decode"].get(ctx, {})
        print(f"| decode-bench {ctx} decode tok/s p50 (min-max) | {f(i.get('decode_tps_p50'), 2)} ({f(i.get('decode_tps_min'), 2)}-{f(i.get('decode_tps_max'), 2)})"
              f" | {f(c.get('decode_tps_p50'), 2)} ({f(c.get('decode_tps_min'), 2)}-{f(c.get('decode_tps_max'), 2)}) |")
        print(f"| decode-bench {ctx} TTFT p50 s | {f(i.get('ttft_p50_s'), 2)} | {f(c.get('ttft_p50_s'), 2)} |")
    for k in sorted(set(I["aggregate"]) | set(C["aggregate"])):
        i, c = I["aggregate"].get(k, {}), C["aggregate"].get(k, {})
        if k == "msb03":
            print(f"| msb03 makespan tok/s (vs serial) | {f(i.get('makespanAggregateTokensPerSecond'), 2)} ({f(i.get('makespanVsSerial'))})"
                  f" | {f(c.get('makespanAggregateTokensPerSecond'), 2)} ({f(c.get('makespanVsSerial'))}) |")
        else:
            print(f"| 4-row scheduler {k} aggregate tok/s p50 (vs serial) | {f(i.get('aggregateTPSp50'), 2)} ({f(i.get('aggregateVsProductionSerial'))})"
                  f" | {f(c.get('aggregateTPSp50'), 2)} ({f(c.get('aggregateVsProductionSerial'))}) |")
    print(f"| msb parity pass / first divergence | {f((I['parity'] or {}).get('pass'))} / {f((I['parity'] or {}).get('firstDivergenceIndex'))}"
          f" | {f((C['parity'] or {}).get('pass'))} / {f((C['parity'] or {}).get('firstDivergenceIndex'))} |")
    for ctx in sorted(set(I["ref"] or {}) | set(C["ref"] or {}), key=lambda x: int(x) if x.isdigit() else 0):
        i, c = (I["ref"] or {}).get(ctx, {}), (C["ref"] or {}).get(ctx, {})
        print(f"| reference {ctx}: top-1, matching/compared, max logit diff | {f(i.get('top1'))}/{f(i.get('top1_compared'))}, "
              f"{f(i.get('matching'))}/{f(i.get('compared'))}, {f(i.get('max_abs_logit_diff'))} | {f(c.get('top1'))}/{f(c.get('top1_compared'))}, "
              f"{f(c.get('matching'))}/{f(c.get('compared'))}, {f(c.get('max_abs_logit_diff'))} |")
    for cid in sorted(set(I["mtp"]["cells"]) | set(C["mtp"]["cells"])):
        i, c = I["mtp"]["cells"].get(cid, {}), C["mtp"]["cells"].get(cid, {})
        print(f"| MTP {cid}: accepted/proposed (rate), status, throughput median | {f(i.get('accepted'))}/{f(i.get('proposed'))} ({f(i.get('acceptance'))}), "
              f"{f(i.get('status'))}, {f(i.get('throughput_median'))} | {f(c.get('accepted'))}/{f(c.get('proposed'))} ({f(c.get('acceptance'))}), "
              f"{f(c.get('status'))}, {f(c.get('throughput_median'))} |")
    print(f"| MTP analyzer overall | {I['mtp']['overall_status']} | {C['mtp']['overall_status']} |")
    print(f"| quality rubric passed ({(cq or iq or {}).get('path')}) | {f((iq or {}).get('passed'))}/{f((iq or {}).get('cases'))} | {f((cq or {}).get('passed'))}/{f((cq or {}).get('cases'))} |")
    for n in ref_notes:
        print(f"\nnote: {n}")
    print("\n" + line)
    if a.json:
        json.dump(rep, open(a.json, "w"), indent=2, default=str)
    return 0 if verdict == "PASS" else 1


if __name__ == "__main__":
    sys.exit(main())
