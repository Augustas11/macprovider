#!/usr/bin/env python3
"""Explain concurrent-request text differences from cb_cells.py.

For every row of every width cell (and the join case) whose text differs from
that prompt's lone text, find the first differing token and run the model once
on the templated prompt plus the common token prefix. A near-tie (margin_steps
0 to 2, see margin.spacing) means the batched and lone runs agree up to float
rounding; a wide margin means the batched run decoded a different distribution.

usage: cb_margin.py --model-path DIR --cells cells.json [--ctx 200] [--json OUT]
Run under an interpreter that has mlx_lm. Needs a cells.json that stores full
texts (cb_cells.py output with "text" per row and per lone run).

--json OUT writes {"records": [...]}, one per differing row. Model runs are
shared by rows with the same (row, first differing token index, common prefix
tokens).
"""
import argparse
import json
import os
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import margin  # noqa: E402
import prompts  # noqa: E402


class MissingTexts(Exception):
    pass


def select_divergences(cells):
    """Rows whose batched text differs from the lone text of the same row.

    Returns dicts with width ("join" for the join case), trial, row, lone_text
    and text. Rows with an error, or whose lone run had an error, are skipped.
    Raises MissingTexts for a cells dict without full texts.
    """
    lone = {}
    for entry in cells.get("lone") or []:
        if "text" not in entry:
            raise MissingTexts("cells.json has no full lone texts; rerun cb_cells.py (full texts are required)")
        lone[entry["row"]] = entry
    if not lone:
        raise MissingTexts("cells.json has no lone runs; full texts are required")
    groups = [(c.get("width"), c.get("trial"), c.get("rows") or []) for c in cells.get("widths") or []]
    if cells.get("join"):
        groups.append(("join", None, cells["join"].get("rows") or []))
    out = []
    for width, trial, rows in groups:
        for r in rows:
            if "text" not in r:
                raise MissingTexts("cells.json rows have no full texts; rerun cb_cells.py (full texts are required)")
            base = lone.get(r["row"])
            if base is None or r.get("error") or base.get("error"):
                continue
            if r["text"] != base["text"]:
                out.append({"width": width, "trial": trial, "row": r["row"],
                            "lone_text": base["text"], "text": r["text"]})
    return out


def dedup_key(row, index, prefix_tokens):
    return (row, index, tuple(prefix_tokens))


def build_record(div, ctx, index, lone_tok, batched_tok, top_ids, top_logits, dtype):
    """One record: the top-2 logits at the first differing token of a divergence."""
    gap = top_logits[0] - top_logits[1]
    dtype = str(dtype).split(".")[-1]
    in2 = [lone_tok in top_ids[:2], batched_tok in top_ids[:2]]
    return {
        "width": div["width"], "trial": div["trial"], "row": div["row"], "ctx": ctx,
        "token_index": index, "lone_token": lone_tok, "batched_token": batched_tok,
        "top_ids": list(top_ids[:2]), "top_logits": list(top_logits[:2]),
        "margin": gap, "dtype": dtype,
        "margin_steps": gap / margin.spacing(top_logits[0], dtype),
        "lone_in_top2": in2[0], "batched_in_top2": in2[1], "both_in_top2": all(in2),
    }


def summarize(distinct_records, differing_rows):
    steps = [r["margin_steps"] for r in distinct_records]
    return {"differing_rows": differing_rows, "distinct_points": len(distinct_records),
            "within_2_steps": sum(1 for s in steps if s <= 2),
            "max_margin_steps": max(steps) if steps else None}


def main(argv=None):
    ap = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    ap.add_argument("--model-path", required=True)
    ap.add_argument("--cells", required=True)
    ap.add_argument("--ctx", type=int, help="prompt context size; default: the value in cells.json, else 200")
    ap.add_argument("--json", help="write {\"records\": [...]}")
    args = ap.parse_args(argv)

    with open(args.cells) as f:
        cells = json.load(f)
    ctx = args.ctx or cells.get("ctx") or 200
    try:
        divs = select_divergences(cells)
    except MissingTexts as e:
        sys.exit(f"cb_margin: {e}")

    import mlx.core as mx
    from mlx_lm import load

    model, tok = load(args.model_path)
    template = getattr(tok, "chat_template", None) or ""
    kw = {"enable_thinking": False} if "enable_thinking" in str(template) else {}
    runs = {}
    records, keys = [], []

    def show(t):
        return "<none>" if t is None else repr(tok.decode([t]))

    for div in divs:
        tl = tok.encode(div["lone_text"], add_special_tokens=False)
        tb = tok.encode(div["text"], add_special_tokens=False)
        i = margin.first_token_diff(tl, tb)
        lone_tok = tl[i] if i < len(tl) else None
        batched_tok = tb[i] if i < len(tb) else None
        key = dedup_key(div["row"], i, tl[:i])
        if key not in runs:
            prompt = tok.apply_chat_template(
                prompts.build_messages(ctx, div["row"]), add_generation_prompt=True, **kw)
            raw = model(mx.array(list(prompt) + tl[:i])[None])[0, -1]
            dtype = str(raw.dtype).split(".")[-1]
            logits = raw.astype(mx.float32)
            order = mx.argsort(-logits)[:2].tolist()
            runs[key] = (order, [float(logits[t]) for t in order], dtype)
        order, vals, dtype = runs[key]
        rec = build_record(div, ctx, i, lone_tok, batched_tok, order, vals, dtype)
        records.append(rec)
        keys.append(key)
        print(f"width={div['width']} trial={div['trial']} row={div['row']} token={i} "
              f"lone={show(lone_tok)} batched={show(batched_tok)} "
              f"margin={rec['margin']:.4f} steps={rec['margin_steps']:.2f}")
    # One record per dedup key represents a point; duplicates differ only in
    # which token the batched run chose.
    distinct, seen = [], set()
    for key, rec in zip(keys, records):
        if key not in seen:
            seen.add(key)
            distinct.append(rec)
    s = summarize(distinct, len(divs))
    print(f"differing rows {s['differing_rows']}, distinct divergence points {s['distinct_points']}, "
          f"within 2 steps {s['within_2_steps']}, max margin_steps {s['max_margin_steps']}")
    if args.json:
        with open(args.json, "w") as f:
            json.dump({"records": records}, f, indent=2)
            f.write("\n")


if __name__ == "__main__":
    main()
