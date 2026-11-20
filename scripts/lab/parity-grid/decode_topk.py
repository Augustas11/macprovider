#!/usr/bin/env python3
"""Top-k logits at one decode index from both decode paths, on the same token ids.

Issue #2443. margin.py reads mlx-lm's logits from one uncached forward over the
reference text re-tokenized. This tool compares the two decode paths instead:

- ours: the record a lab-harness serve wrote with
  MACPROVIDER_LAB_DECODE_TOPK=FILE and MACPROVIDER_LAB_DECODE_TOPK_INDICES=N
  (LabDecodeTopK.swift). It carries the exact prompt ids and the generated ids
  before index N on our serial route, and the top-k logits our sampler saw.
- mlx-lm cached decode: mlx_lm.generate.generate_step (the loop stream_generate
  and the parity reference run: chunked prefill of the prompt, then one-token
  decode steps) on our prompt ids, forced through our generated ids, with the
  logits captured at step N.
- mlx-lm uncached forward over prompt + generated[:N], as margin.py reads it.

The record used is the one at --index whose prompt ids equal the mlx-lm chat
template ids of the cell (ctx, row 0), so warm-up and self-check requests that
also passed through the hook are ignored. A mismatch fails loudly.

usage: decode_topk.py --model-path DIR --ours-topk FILE --ctx 4000 --index 15
                      [--ref reference.jsonl --max-tokens 128] [--k 5] [--json OUT]
Run under an interpreter that has mlx_lm.

Output: per path, the top-k (id, token, logit) and, for the two candidate ids
(the reference's pick and ours, or the top two of our record), each path's gap
in float steps of the logits dtype at the larger logit (margin.spacing).
"""
import argparse
import json
import os
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import margin  # noqa: E402
import prompts  # noqa: E402

SCHEMA = "macprovider.lab-decode-topk.v1"


def load_records(path):
    out = []
    with open(path) as f:
        for line in f:
            line = line.strip()
            if line:
                r = json.loads(line)
                if r.get("schema") == SCHEMA:
                    out.append(r)
    return out


def select_record(records, prompt_ids, index):
    """The last record at `index` whose prompt ids equal `prompt_ids`.

    Raises ValueError naming what was found when none matches."""
    at_index = [r for r in records if r["decode_index"] == index]
    match = [r for r in at_index if r["prompt_token_ids"] == list(prompt_ids)]
    if not match:
        lengths = sorted({len(r["prompt_token_ids"]) for r in at_index})
        raise ValueError(f"no record at decode index {index} has the cell's {len(prompt_ids)} prompt ids "
                         f"({len(records)} records, {len(at_index)} at that index, prompt lengths {lengths})")
    rec = match[-1]
    if len(rec["generated_token_ids"]) != index:
        raise ValueError(f"record at index {index} carries {len(rec['generated_token_ids'])} generated ids")
    if len(rec["top_ids"]) != len(rec["top_logits"]) or len(rec["top_ids"]) < 2:
        raise ValueError("record top-k is malformed")
    return rec


class ForcedDecode:
    """Sampler and logits processor for generate_step: step k samples
    forced[k] (argmax past the end) and keeps the logits of step `capture`."""

    def __init__(self, mx, forced, capture):
        self.mx, self.forced, self.capture = mx, list(forced), capture
        self.sample_calls = 0
        self.process_calls = 0
        self.captured = None

    def processor(self, tokens, logits):
        if self.process_calls == self.capture:
            self.captured = logits
        self.process_calls += 1
        return logits

    def sampler(self, logprobs):
        k = self.sample_calls
        self.sample_calls += 1
        if k < len(self.forced):
            return self.mx.array([self.forced[k]], dtype=self.mx.uint32)
        return self.mx.argmax(logprobs, axis=-1)


def topk(mx, row, k):
    """(ids, float32 values, dtype name) of the k largest entries of a [vocab] row."""
    dtype = str(row.dtype).split(".")[-1]
    values = row.astype(mx.float32)
    order = mx.argsort(-values)[:k]
    mx.eval(order, values)
    ids = order.tolist()
    return ids, [float(values[i]) for i in ids], dtype, values


def gap_steps(logit_a, logit_b, dtype):
    """logit_a - logit_b in float steps of `dtype` at the larger of the two."""
    return (logit_a - logit_b) / margin.spacing(max(logit_a, logit_b), dtype)


def path_summary(name, ids, vals, dtype, full, pair):
    a, b = pair
    la, lb = (vals[ids.index(t)] if t in ids else float(full[t]) for t in (a, b))
    return {"path": name, "dtype": dtype, "top_ids": ids, "top_logits": vals,
            "pair": [a, b], "pair_logits": [la, lb], "gap": la - lb, "gap_steps": gap_steps(la, lb, dtype)}


def main(argv=None):
    ap = argparse.ArgumentParser()
    ap.add_argument("--model-path", required=True)
    ap.add_argument("--ours-topk", required=True, help="JSONL written through MACPROVIDER_LAB_DECODE_TOPK")
    ap.add_argument("--ctx", type=int, required=True, help="cell ctx_target, e.g. 4000")
    ap.add_argument("--index", type=int, required=True, help="decode index (0 = first generated token)")
    ap.add_argument("--ref", help="reference.jsonl: take the reference's token at the index from its text")
    ap.add_argument("--max-tokens", type=int, default=128, help="reference cell output length (with --ref)")
    ap.add_argument("--k", type=int, default=5)
    ap.add_argument("--json", help="write the summary here")
    args = ap.parse_args(argv)

    import mlx.core as mx
    from mlx_lm import load
    from mlx_lm.generate import generate_step

    model, tok = load(args.model_path)
    template = getattr(tok, "chat_template", None) or ""
    kw = {"enable_thinking": False} if "enable_thinking" in str(template) else {}
    prompt_ids = list(tok.apply_chat_template(prompts.build_messages(args.ctx, 0), add_generation_prompt=True, **kw))
    rec = select_record(load_records(args.ours_topk), prompt_ids, args.index)
    generated = rec["generated_token_ids"]
    our_tok = rec["top_ids"][0]

    ref_tok = None
    if args.ref:
        refs = margin.rows(args.ref)
        ta = tok.encode(refs[(args.ctx, args.max_tokens)]["text"], add_special_tokens=False)
        if ta[:args.index] != generated:
            print(f"warning: the reference text re-tokenized differs from our ids before index {args.index}",
                  file=sys.stderr)
        ref_tok = ta[args.index] if args.index < len(ta) else None
    pair = (ref_tok, our_tok) if ref_tok is not None and ref_tok != our_tok else tuple(rec["top_ids"][:2])
    our_dtype = rec["dtype"].split(".")[-1]
    our_full = {t: v for t, v in zip(rec["top_ids"], rec["top_logits"])}
    missing = [t for t in pair if t not in our_full]
    if missing:
        raise SystemExit(f"candidate ids {missing} are outside our recorded top-{len(rec['top_ids'])}; "
                         "rerun the serve with a larger MACPROVIDER_LAB_DECODE_TOPK_K")

    # mlx-lm cached decode, exactly the generate_step loop the reference ran.
    forced = ForcedDecode(mx, generated, args.index)
    for n, _ in enumerate(generate_step(mx.array(prompt_ids), model, max_tokens=args.index + 1,
                                        sampler=forced.sampler, logits_processors=[forced.processor])):
        if n == args.index:
            break
    if forced.captured is None:
        raise SystemExit(f"generate_step never reached decode index {args.index}")
    cached = topk(mx, forced.captured[0], args.k)

    # mlx-lm uncached forward over the same ids (margin.py's reading).
    raw = model(mx.array(prompt_ids + generated)[None])[0, -1]
    uncached = topk(mx, raw, args.k)

    paths = [
        path_summary("ours_serial", rec["top_ids"], rec["top_logits"], our_dtype, our_full, pair),
        path_summary("mlxlm_cached_decode", cached[0], cached[1], cached[2], cached[3].tolist(), pair),
        path_summary("mlxlm_uncached_forward", uncached[0], uncached[1], uncached[2], uncached[3].tolist(), pair),
    ]
    print(f"ctx={args.ctx} decode index {args.index}, {len(prompt_ids)} prompt ids + {len(generated)} generated")
    print(f"  pair: {pair[0]} {tok.decode([pair[0]])!r} vs {pair[1]} {tok.decode([pair[1]])!r}"
          + (" (reference pick vs ours)" if ref_tok is not None and ref_tok != our_tok else " (our top two)"))
    for p in paths:
        print(f"  {p['path']:<24} {p['dtype']:<9} pair logits {p['pair_logits'][0]:.4f} / {p['pair_logits'][1]:.4f}"
              f"  gap {p['gap']:+.4f} = {p['gap_steps']:+.2f} steps")
        for t, v in zip(p["top_ids"], p["top_logits"]):
            print(f"      {v:9.4f}  {t:7d}  {tok.decode([t])!r}")
    ours_vs_cached = paths[0]["gap_steps"] - paths[1]["gap_steps"]
    print(f"  ours minus mlx-lm cached decode: {ours_vs_cached:+.2f} steps on the pair gap")
    summary = {"ctx_target": args.ctx, "decode_index": args.index, "prompt_tokens": len(prompt_ids),
               "ref_token": ref_tok, "our_token": our_tok, "pair": list(pair), "paths": paths,
               "ours_minus_cached_steps": ours_vs_cached}
    if args.json:
        with open(args.json, "w") as f:
            json.dump(summary, f, indent=2)
            f.write("\n")


if __name__ == "__main__":
    main()
