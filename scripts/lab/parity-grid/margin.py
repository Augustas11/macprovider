#!/usr/bin/env python3
"""Explain a text mismatch from the parity grid.

For each cell where our text differs from the stock mlx-lm reference, find the
first differing token and print the reference model's top logits at that
position: a near-tie means the two runtimes agree up to float rounding and pick
different sides of it; a wide margin means one side decoded a different
distribution. Where our text is a strict prefix that stopped early, the same
print shows how close the stop token was.

usage: margin.py --model-path DIR --ref reference.jsonl --ours provider.jsonl [--json OUT]
Run under an interpreter that has mlx_lm.

--json OUT writes {"records": [...]}, one record per examined cell, for
compare.py --margins. margin_steps is the margin in units of the float spacing
of the logits dtype at the top logit (see spacing()); 0 to 2 steps is a rounding
tie, not a decoding bug. Cells are examined once per (ctx, first differing
token index), so longer outputs sharing a prefix share one record; compare.py
maps a mismatch to its record by ctx and byte offset (common_prefix_bytes).
"""
import argparse
import json
import math
import os
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import prompts  # noqa: E402


def rows(path):
    out = {}
    with open(path) as f:
        for line in f:
            r = json.loads(line)
            if r.get("kind") == "row" and r.get("trial") == 0 and r.get("row") == 0:
                out[(r["ctx_target"], r["max_tokens"])] = r
    return out


# Logit dtypes: mantissa bits and smallest normal binade exponent.
_MANTISSA = {"float16": 10, "bfloat16": 7, "float32": 23}
_MIN_EXP = {"float16": -14, "bfloat16": -126, "float32": -126}


def spacing(value, dtype):
    """Distance between adjacent representable numbers of `dtype` at |value|.

    For |v| in the binade [2^e, 2^(e+1)) the spacing is 2^(e - mantissa_bits);
    below the smallest normal binade it is that binade's spacing (subnormals).
    e = frexp(|v|)[1] - 1. Examples: float16 at 16..32 -> 2^-6 = 0.015625;
    bfloat16 at 16..32 -> 2^-3 = 0.125.
    """
    name = str(dtype).split(".")[-1]
    if name not in _MANTISSA:
        raise ValueError(f"unsupported logits dtype {dtype!r}")
    exp = _MIN_EXP[name] if value == 0 else max(math.frexp(abs(value))[1] - 1, _MIN_EXP[name])
    return math.ldexp(1.0, exp - _MANTISSA[name])


def first_token_diff(ta, tb):
    """Index of the first differing token (the shorter length if one is a prefix)."""
    n = min(len(ta), len(tb))
    return next((j for j in range(n) if ta[j] != tb[j]), n)


def build_record(ctx, out, index, ref_tok, our_tok, top_ids, top_logits, dtype,
                 common_prefix_bytes=None, diff_span_bytes=None):
    """One margins record. Logits are float32 copies of the model's dtype values."""
    margin = top_logits[0] - top_logits[1]
    dtype = str(dtype).split(".")[-1]
    return {
        "ctx_target": ctx, "max_tokens": out, "token_index": index,
        "ref_token": ref_tok, "our_token": our_tok,
        "top_ids": list(top_ids), "top_logits": list(top_logits),
        "margin": margin, "dtype": dtype,
        "margin_steps": margin / spacing(top_logits[0], dtype),
        "common_prefix_bytes": common_prefix_bytes, "diff_span_bytes": diff_span_bytes,
    }


def main(argv=None):
    ap = argparse.ArgumentParser()
    ap.add_argument("--model-path", required=True)
    ap.add_argument("--ref", required=True)
    ap.add_argument("--ours", required=True)
    ap.add_argument("--json", help="write margin records for compare.py --margins")
    args = ap.parse_args(argv)

    import mlx.core as mx
    from mlx_lm import load

    model, tok = load(args.model_path)
    template = getattr(tok, "chat_template", None) or ""
    kw = {"enable_thinking": False} if "enable_thinking" in str(template) else {}
    ref, ours = rows(args.ref), rows(args.ours)
    seen = set()
    records = []
    for key in sorted(ref):
        if key not in ours:
            continue
        a, b = ref[key]["text"], ours[key]["text"]
        if a == b:
            continue
        ta = tok.encode(a, add_special_tokens=False)
        tb = tok.encode(b, add_special_tokens=False)
        i = first_token_diff(ta, tb)
        if (key[0], i) in seen:
            continue
        seen.add((key[0], i))
        prompt = tok.apply_chat_template(
            prompts.build_messages(key[0], 0), add_generation_prompt=True, **kw)
        ids = mx.array(list(prompt) + ta[:i])[None]
        raw = model(ids)[0, -1]
        dtype = str(raw.dtype).split(".")[-1]
        logits = raw.astype(mx.float32)
        order = mx.argsort(-logits)[:5].tolist()
        vals = [float(logits[t]) for t in order]
        ref_tok = ta[i] if i < len(ta) else None
        our_tok = tb[i] if i < len(tb) else None
        print(f"ctx={key[0]} out={key[1]} first differing token index {i} "
              f"(ref {len(ta)} tokens, ours {len(tb)}, ours finish={ours[key].get('finish')})")
        print(f"  ref token {ref_tok} {tok.decode([ref_tok]) if ref_tok is not None else None!r}; "
              f"our token {our_tok} {tok.decode([our_tok]) if our_tok is not None else '<none: ours ended>'!r}")
        for t, v in zip(order, vals):
            print(f"    {v:9.4f}  {t:7d}  {tok.decode([t])!r}")
        print(f"  top1-top2 margin {vals[0] - vals[1]:.4f}")
        rec = build_record(
            key[0], key[1], i, ref_tok, our_tok, order, vals, dtype,
            common_prefix_bytes=len(tok.decode(ta[:i]).encode()),
            diff_span_bytes=max(len(tok.decode([t]).encode()) for t in (ref_tok, our_tok) if t is not None)
            if (ref_tok, our_tok) != (None, None) else 0)
        print(f"  logits dtype {dtype}, margin {rec['margin_steps']:.2f} float steps")
        records.append(rec)
    if args.json:
        with open(args.json, "w") as f:
            json.dump({"records": records}, f, indent=2)
            f.write("\n")


if __name__ == "__main__":
    main()
