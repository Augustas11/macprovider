#!/usr/bin/env python3
"""Qwen3.8-Flash-Next (qwen4_exp) token-parity verdicts at close calls (#2449). Stdlib only.

usage: qwen4_divergence.py report --oracle-dir DIR --parity glm-parity.json
                                  [--parity-512 glm-parity-512.json] --out-json F --out-md F
       qwen4_divergence.py gate --oracle-dir DIR --parity glm-parity.json --steps N

Inputs: the oracle JSONs (glm53_oracle_json.py of qwen4_oracle.py / qwen4_served_oracle.py
.npz files, top-16 reference logits per logged step), the served-prompt metadata
`served_<ctx>.json` (qwen4_served_oracle.py: the served text's first differing token
against the reference), and `macprovider-cli glm-parity` reports (the Swift port on the
same prompt ids; its teacher-forced pass feeds the reference's tokens, so at every step
both sides saw the same history).

Per step on the reference's history:
  ref_gap   reference top-1 minus top-2 logit;
  max_diff  largest |our logit - reference logit| over the reference's top-16 ids
            (glm-parity max_abs_logit_diff_per_step, teacher-forced);
  our_token our argmax; our_margin: our logit of our token minus our logit of the
            reference's token when they differ, else our top-1 minus our best other
            reference top-16 id.
  verdict   CLOSE_CALL when ref_gap < 2 * max_diff: the measured logit error at that
            step is large enough to flip the reference's choice, so rounding can explain
            a different token; else REAL_DIVERGENCE when our argmax differs from the
            reference's token, and CLEAR_MARGIN when it agrees.

report: for each served prompt, the first token where the served text leaves the reference
(and where the port's free run leaves it, per prefill step), that step and the three
before, a verdict and a cause:
  near_tie       the step is a CLOSE_CALL;
  prefill_step   the port's free run at prefill step 512 (the serve's) leaves the reference
                 at that step with the served token and the 2048 run does not;
  port_or_shim   on the reference's history the port picks the served token by more than
                 rounding: port and shimmed reference compute different distributions
                 (this cannot tell the port, its kernels and the qwen4_oracle shim apart);
  serve_path     the port follows the reference at that step by more than rounding, so the
                 served path (paged KV cache, stock_order kernel, served prompt ids) differs;
  prompt_ids     as serve_path, and the served prompt token count differs from the
                 reference's (only counts are known, not ids);
  unexplained    none of the above.
Lines: DIVERGENCE_STEP, DIVERGENCE_VERDICT; exit 0.

gate: the parity gate over every oracle prompt. Code prompts (`oracle_<N>`) keep the old
rules (first 16 top-1 exact, teacher-forced >= 15/16 of the steps); every prompt fails on
a REAL_DIVERGENCE teacher-forced step (our argmax differs from the reference's greedy
token by more than rounding); and the prompt set must contain at least one close-call
step (ref_gap < 2 * max_diff) so a pass covers close choices, not only high-margin ones.
Lines: PARITY_CELL, PARITY_CLOSE_CALLS, PARITY_GATES PASS|FAIL; exit 0 on PASS, 1 on FAIL.
"""
import argparse
import json
import pathlib
import sys

CONTEXT_STEPS = 3


def load_oracles(oracle_dir):
    """{source name (the .npz file name): oracle JSON} of every oracle_*.json in oracle_dir."""
    out = {}
    for path in sorted(pathlib.Path(oracle_dir).glob("oracle_*.json")):
        doc = json.loads(path.read_text())
        out[doc["source"]] = doc
    return out


def load_served_meta(oracle_dir):
    """{source name: served_<ctx>.json} for the served prompts."""
    out = {}
    for path in sorted(pathlib.Path(oracle_dir).glob("served_*.json")):
        doc = json.loads(path.read_text())
        out[doc["source"]] = doc
    return out


def runs_by_source(report):
    return {r["oracle_source"]: r["measurement"] for r in (report or {}).get("runs", [])}


def on_reference_history(measurement):
    """The comparison whose every step saw the reference's history: the teacher-forced pass,
    or the free run when it never left the reference (glm-parity then skips teacher forcing)."""
    return measurement.get("teacher_forced") or measurement["free_running"]


def is_close_call(ref_gap, max_diff):
    return ref_gap < 2 * max_diff


def step_view(oracle, comparison, step):
    """The reference and our side at one logged step on the reference's history, or None
    when the step was not logged."""
    if step is None or step >= len(oracle["top_idx"]) or step >= len(comparison.get("gathered_logits") or []):
        return None
    ids, ref = oracle["top_idx"][step], oracle["top_logit"][step]
    ours = comparison["gathered_logits"][step]
    max_diff = comparison["max_abs_logit_diff_per_step"][step]
    our_token = comparison["tokens"][step] if step < len(comparison["tokens"]) else None
    ref_gap = ref[0] - ref[1]
    if our_token in ids:
        j = ids.index(our_token)
        our_margin = ours[j] - ours[0] if j else ours[0] - max(ours[1:])
    else:
        our_margin = None
    return {
        "step": step, "ref_token": oracle["greedy"][step], "ref_top2": ids[:2], "ref_logits_top2": ref[:2],
        "ref_gap": ref_gap, "our_token": our_token, "our_logits_at_ref_top2": ours[:2],
        "our_margin": our_margin, "max_diff": max_diff,
        "verdict": ("CLOSE_CALL" if is_close_call(ref_gap, max_diff)
                    else "REAL_DIVERGENCE" if our_token != oracle["greedy"][step] else "CLEAR_MARGIN"),
    }


def first_divergence(measurement):
    return measurement["free_running"].get("first_divergence")


def free_token(measurement, step):
    tokens = measurement["free_running"]["tokens"]
    return tokens[step] if step is not None and step < len(tokens) else None


def cause(view, served_token, served_step, prompt_counts_equal, m2048, m512):
    """The cause name (module docstring) of a served divergence at `served_step`."""
    if view is None:
        return "unexplained"
    if view["verdict"] == "CLOSE_CALL":
        return "near_tie"
    if (m512 is not None and first_divergence(m512) == served_step and free_token(m512, served_step) == served_token
            and (m2048 is None or first_divergence(m2048) != served_step)):
        return "prefill_step"
    if served_token is not None and view["our_token"] == served_token:
        return "port_or_shim"
    if view["our_token"] == view["ref_token"]:
        return "serve_path" if prompt_counts_equal else "prompt_ids"
    return "unexplained"


def prompt_report(source, oracle, meta, m2048, m512):
    """One served prompt's divergence record."""
    primary = m512 if m512 is not None else m2048
    comparison = on_reference_history(primary) if primary is not None else None
    served = meta.get("served") or {}
    served_step = served.get("token_index") if not served.get("text_equal") else None
    rec = {
        "source": source, "ctx_target": meta.get("ctx"), "prompt_tokens": len(oracle["prompt"]),
        "served_available": bool(served), "served_prompt_tokens": served.get("prompt_tokens"),
        "served_text_equal": served.get("text_equal"), "served_step": served_step,
        "served_token": served.get("served_token"), "served_common_prefix_bytes": served.get("common_prefix_bytes"),
        "stream_generate_first_diff": meta.get("stream_generate_first_diff"),
        "engine_first_divergence": {"prefill_2048": first_divergence(m2048) if m2048 else None,
                                    "prefill_512": first_divergence(m512) if m512 else None},
        "steps": {}, "verdict": None, "cause": None,
    }
    if comparison is None:
        rec["verdict"], rec["cause"] = "NO_PARITY_RUN", "unexplained"
        return rec
    marks = {"served": served_step, "engine_512": rec["engine_first_divergence"]["prefill_512"],
             "engine_2048": rec["engine_first_divergence"]["prefill_2048"]}
    for name, step in marks.items():
        if step is None:
            continue
        rec["steps"][name] = [v for v in (step_view(oracle, comparison, s)
                                          for s in range(max(0, step - CONTEXT_STEPS), step + 1)) if v]
        if m2048 is not None and m512 is not None:
            other = step_view(oracle, on_reference_history(m2048), step)
            rec["steps"][name + "_max_diff_prefill_2048"] = other["max_diff"] if other else None
    if served_step is None:
        rec["verdict"] = "NO_SERVED_DIVERGENCE" if served else "NO_SERVED_TEXT"
        rec["cause"] = None
        return rec
    view = step_view(oracle, comparison, served_step)
    rec["verdict"] = view["verdict"] if view else "STEP_NOT_LOGGED"
    rec["cause"] = cause(view, served.get("served_token"), served_step,
                         served.get("prompt_tokens") in (None, len(oracle["prompt"])), m2048, m512)
    return rec


def fmt(x, nd=3):
    return "-" if x is None else (f"{x:.{nd}f}" if isinstance(x, float) else str(x))


def report_markdown(records):
    lines = ["| prompt | ctx | served step | verdict | cause | engine first divergence 2048 / 512 |", "|---|---:|---:|---|---|---|"]
    for r in records:
        e = r["engine_first_divergence"]
        lines.append(f"| {r['source']} | {r['ctx_target']} | {fmt(r['served_step'])} | {r['verdict']} | {fmt(r['cause'])} "
                     f"| {fmt(e['prefill_2048'])} / {fmt(e['prefill_512'])} |")
    lines += ["", "| prompt | mark | step | ref token | our token | ref gap | our margin | max logit diff | verdict |",
              "|---|---|---:|---:|---:|---:|---:|---:|---|"]
    for r in records:
        for mark, views in r["steps"].items():
            if not isinstance(views, list):
                continue
            for v in views:
                lines.append(f"| {r['source']} | {mark} | {v['step']} | {v['ref_token']} | {v['our_token']} "
                             f"| {fmt(v['ref_gap'])} | {fmt(v['our_margin'])} | {fmt(v['max_diff'])} | {v['verdict']} |")
    return "\n".join(lines) + "\n"


def cmd_report(args):
    oracles, metas = load_oracles(args.oracle_dir), load_served_meta(args.oracle_dir)
    p2048 = runs_by_source(json.loads(pathlib.Path(args.parity).read_text()))
    p512 = runs_by_source(json.loads(pathlib.Path(args.parity_512).read_text())) if args.parity_512 else {}
    records = []
    for source, meta in sorted(metas.items()):
        if source not in oracles:
            print(f"DIVERGENCE_VERDICT {source} MISSING_ORACLE")
            continue
        rec = prompt_report(source, oracles[source], meta, p2048.get(source), p512.get(source))
        records.append(rec)
        for mark, views in rec["steps"].items():
            if isinstance(views, list):
                for v in views:
                    print("DIVERGENCE_STEP " + json.dumps({"source": source, "mark": mark, **v}, sort_keys=True))
        print(f"DIVERGENCE_VERDICT {source} ctx={rec['ctx_target']} prompt_tokens={rec['prompt_tokens']} "
              f"served_prompt_tokens={rec['served_prompt_tokens']} served_step={rec['served_step']} "
              f"verdict={rec['verdict']} cause={rec['cause']} engine_first_divergence={json.dumps(rec['engine_first_divergence'])}")
    pathlib.Path(args.out_json).write_text(json.dumps({"records": records}, indent=2) + "\n")
    pathlib.Path(args.out_md).write_text(report_markdown(records))
    return 0


def gate(oracles, runs, steps):
    """(lines, passed) of the parity gate (module docstring)."""
    lines, bad, close_total = [], [], 0
    if not runs:
        bad.append("no parity runs")
    for source in sorted(set(oracles) - set(runs)):
        bad.append(f"{source}: no parity run")
    for source, m in sorted(runs.items()):
        oracle = oracles.get(source)
        if oracle is None:
            bad.append(f"{source}: no oracle")
            continue
        fr, tf = m["free_running"], on_reference_history(m)
        compared = tf["compared_tokens"]
        logged = min(len(oracle["top_idx"]), len(tf.get("gathered_logits") or []))
        views = [step_view(oracle, tf, s) for s in range(logged)]
        close = [v["step"] for v in views if v and v["verdict"] == "CLOSE_CALL"]
        real = [v["step"] for v in views if v and v["our_token"] != v["ref_token"] and v["verdict"] == "REAL_DIVERGENCE"]
        flips = [v["step"] for v in views if v and v["our_token"] != v["ref_token"] and v["verdict"] == "CLOSE_CALL"]
        close_total += len(close)
        code = not source.startswith("oracle_served_")
        need = (min(steps, compared) if code else compared) * 15 // 16
        lines.append(f"PARITY_CELL {source} first16 {fr['top1_agreement']}/{fr['top1_compared']} teacher-forced "
                     f"{tf['matching_tokens']}/{compared} logged_steps={logged} close_call_steps={len(close)} "
                     f"close_call_flips={flips} real_divergence_steps={real}")
        if code and (fr["top1_compared"] <= 0 or fr["top1_agreement"] != fr["top1_compared"]):
            bad.append(f"{source}: first-16 top-1 {fr['top1_agreement']}/{fr['top1_compared']}")
        if compared <= 0 or tf["matching_tokens"] < need:
            bad.append(f"{source}: teacher-forced {tf['matching_tokens']}/{compared} < {need}")
        if real:
            bad.append(f"{source}: REAL_DIVERGENCE at teacher-forced steps {real[:8]}")
    lines.append(f"PARITY_CLOSE_CALLS {close_total} logged steps with ref_gap < 2 x max logit diff")
    if close_total == 0:
        bad.append("no close-call step in the prompt set: a pass would cover only high-margin choices")
    lines.append("PARITY_GATES " + ("FAIL " + "; ".join(bad) if bad else "PASS"))
    return lines, not bad


def cmd_gate(args):
    oracles = load_oracles(args.oracle_dir)
    runs = runs_by_source(json.loads(pathlib.Path(args.parity).read_text()))
    lines, passed = gate(oracles, runs, args.steps)
    print("\n".join(lines))
    return 0 if passed else 1


def main(argv=None):
    ap = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    sub = ap.add_subparsers(dest="cmd", required=True)
    r = sub.add_parser("report")
    r.add_argument("--oracle-dir", required=True)
    r.add_argument("--parity", required=True)
    r.add_argument("--parity-512")
    r.add_argument("--out-json", required=True)
    r.add_argument("--out-md", required=True)
    g = sub.add_parser("gate")
    g.add_argument("--oracle-dir", required=True)
    g.add_argument("--parity", required=True)
    g.add_argument("--steps", type=int, required=True)
    args = ap.parse_args(argv)
    return cmd_report(args) if args.cmd == "report" else cmd_gate(args)


if __name__ == "__main__":
    sys.exit(main())
