#!/usr/bin/env python3
"""Explain a text mismatch from the parity grid.

For each cell where our text differs from the stock mlx-lm reference, find the
first differing token and print the reference model's top logits at that
position: a near-tie means the two runtimes agree up to float rounding and pick
different sides of it; a wide margin means one side decoded a different
distribution. Where our text is a strict prefix that stopped early, the same
print shows how close the stop token was.

usage: margin.py --model-path DIR --ref reference.jsonl --ours provider.jsonl
Run under an interpreter that has mlx_lm.
"""
import argparse
import json
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


def main(argv=None):
    ap = argparse.ArgumentParser()
    ap.add_argument("--model-path", required=True)
    ap.add_argument("--ref", required=True)
    ap.add_argument("--ours", required=True)
    args = ap.parse_args(argv)

    import mlx.core as mx
    from mlx_lm import load

    model, tok = load(args.model_path)
    template = getattr(tok, "chat_template", None) or ""
    kw = {"enable_thinking": False} if "enable_thinking" in str(template) else {}
    ref, ours = rows(args.ref), rows(args.ours)
    seen = set()
    for key in sorted(ref):
        if key not in ours:
            continue
        a, b = ref[key]["text"], ours[key]["text"]
        if a == b:
            continue
        ta = tok.encode(a, add_special_tokens=False)
        tb = tok.encode(b, add_special_tokens=False)
        i = next((j for j in range(min(len(ta), len(tb))) if ta[j] != tb[j]), min(len(ta), len(tb)))
        if (key[0], i) in seen:
            continue
        seen.add((key[0], i))
        prompt = tok.apply_chat_template(
            prompts.build_messages(key[0], 0), add_generation_prompt=True, **kw)
        ids = mx.array(list(prompt) + ta[:i])[None]
        logits = model(ids)[0, -1].astype(mx.float32)
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


if __name__ == "__main__":
    main()
