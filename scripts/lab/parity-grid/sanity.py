#!/usr/bin/env python3
"""Sanity gate for a parity-grid reference: is its output text, or garbage? (stdlib only)

usage: sanity.py --ref reference.jsonl --model-name NAME [--json sanity.json]

A reference that loads but decodes garbage must not be reported as a reference.
Every reference row without an error, with completion_tokens >= MIN_TOKENS, is
checked on its full output (reasoning_text + text: a model may stream all of
it as reasoning) with three signals:

  whitespace  = whitespace characters / all characters          > WS_MAX
  chars/token = characters / completion_tokens                  < CPT_MIN
  words       = characters in runs of >= 2 letters (any script)
                / non-whitespace characters                     < WORD_MIN

A row is degenerate when at least two of the three signals fire (one alone
can be legitimate: CJK text has few characters per token, code is light on
words). The reference is SUSPECT when, in any context, more than half of its
checked rows are degenerate, or when no row could be checked.

Calibration (2026-11-17 Studio runs): stock mlx-vlm 0.7.11 on the GLM-5.3-Flash
DFlash2 build (garbage): whitespace 0.59-0.86 at the short context, chars/token
1.47-1.98 everywhere, words 0.01-0.29 at 4k/16k; every row fires two signals.
Our provider on that build (reasoning text) and stock mlx-lm on
Qwen3.8-27B-Uncensored: whitespace <= 0.20, chars/token >= 3.5, words >= 0.87;
no row fires any signal.

Prints `REFERENCE_SUSPECT <model> <reason>` and exits 3 when suspect, else
`REFERENCE_SANE <model> ...` and exits 0; exit 2 on unreadable input.
"""
import argparse
import json
import re
import sys
from collections import defaultdict

WS_MAX = 0.40
CPT_MIN = 2.5
WORD_MIN = 0.50
MIN_TOKENS = 32
WORD = re.compile(r"[^\W\d_]{2,}")


def row_signals(text, completion_tokens):
    """(whitespace fraction, chars per token, word fraction, fired signal names)."""
    n = len(text)
    ws = sum(c.isspace() for c in text)
    nonws = n - ws
    ws_frac = ws / n if n else 1.0
    cpt = n / completion_tokens if completion_tokens else 0.0
    words = sum(len(m) for m in WORD.findall(text)) / nonws if nonws else 0.0
    fired = []
    if ws_frac > WS_MAX:
        fired.append(f"whitespace {ws_frac:.2f} > {WS_MAX}")
    if cpt < CPT_MIN:
        fired.append(f"chars/token {cpt:.2f} < {CPT_MIN}")
    if words < WORD_MIN:
        fired.append(f"words {words:.2f} < {WORD_MIN}")
    return ws_frac, cpt, words, fired


def check_reference(lines):
    """{'suspect': bool, 'reason': str, 'contexts': {...}, 'rows': [...]} over reference row lines."""
    rows = []
    by_ctx = defaultdict(list)
    for r in lines:
        if r.get("kind", "row") != "row" or r.get("error"):
            continue
        ct = r.get("completion_tokens") or 0
        if ct < MIN_TOKENS:
            continue
        text = (r.get("reasoning_text") or "") + (r.get("text") or "")
        ws, cpt, words, fired = row_signals(text, ct)
        rec = {"ctx": r.get("ctx_target"), "out": r.get("max_tokens"), "row": r.get("row"),
               "trial": r.get("trial"), "whitespace": round(ws, 3), "chars_per_token": round(cpt, 3),
               "words": round(words, 3), "signals": fired, "degenerate": len(fired) >= 2}
        rows.append(rec)
        by_ctx[rec["ctx"]].append(rec)
    contexts = {}
    reasons = []
    for ctx in sorted(by_ctx, key=lambda c: (c is None, c)):
        recs = by_ctx[ctx]
        bad = [x for x in recs if x["degenerate"]]
        contexts[str(ctx)] = {"checked": len(recs), "degenerate": len(bad)}
        if len(bad) * 2 > len(recs):
            ex = bad[0]
            reasons.append(f"ctx{ctx}: {len(bad)}/{len(recs)} rows degenerate "
                           f"(e.g. out {ex['out']} row {ex['row']}: {', '.join(ex['signals'])})")
    if not rows:
        reasons.append(f"no reference row with >= {MIN_TOKENS} completion tokens to check")
    return {"suspect": bool(reasons), "reason": "; ".join(reasons), "contexts": contexts, "rows": rows,
            "thresholds": {"ws_max": WS_MAX, "cpt_min": CPT_MIN, "word_min": WORD_MIN,
                           "min_tokens": MIN_TOKENS, "signals_for_degenerate": 2}}


def main(argv=None):
    ap = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    ap.add_argument("--ref", required=True)
    ap.add_argument("--model-name", required=True)
    ap.add_argument("--json")
    a = ap.parse_args(argv)
    try:
        with open(a.ref) as f:
            lines = [json.loads(x) for x in f if x.strip()]
    except (OSError, ValueError) as exc:
        print(f"sanity: cannot read {a.ref}: {exc}", file=sys.stderr)
        return 2
    result = check_reference(lines)
    if a.json:
        with open(a.json, "w") as f:
            f.write(json.dumps(result, indent=2, sort_keys=True) + "\n")
    if result["suspect"]:
        print(f"REFERENCE_SUSPECT {a.model_name} {result['reason']}")
        return 3
    print(f"REFERENCE_SANE {a.model_name} " + " ".join(
        f"ctx{c}={v['degenerate']}/{v['checked']}" for c, v in result["contexts"].items()))
    return 0


if __name__ == "__main__":
    sys.exit(main())
