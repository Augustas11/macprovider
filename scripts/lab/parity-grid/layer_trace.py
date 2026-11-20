#!/usr/bin/env python3
"""Per-layer hidden state at one decode index: our serial route vs mlx-lm.

Issue #2443. decode_topk.py showed our serial route's logits at one decode
index sit several bf16 steps away from mlx-lm's cached decode, while mlx-lm's
own cached decode and uncached forward agree within about one step. This tool
finds the first layer where our hidden state leaves that spread.

- ours: a record from a lab-harness serve run with MACPROVIDER_LAB_DECODE_TOPK=FILE,
  MACPROVIDER_LAB_DECODE_TOPK_INDICES=N and MACPROVIDER_LAB_DECODE_TOPK_LAYERS=1.
  Its "layers" list holds the last-position input to every
  `layers.K.input_layernorm` (the output of layer K-1; K=0 is the scaled
  embedding) and to the final `model.norm` (the last layer's output), from
  the forward that produced the logits at index N.
- mlx-lm cached decode: generate_step on our prompt ids, forced through our
  generated ids (decode_topk.ForcedDecode), with the same norms wrapped to
  record their inputs during the step-N forward.
- mlx-lm uncached forward over prompt + generated[:N], same taps.

For each tap it prints the distance ours-to-cached and cached-to-forward
(max |diff|, relative L2, elements that differ) and names the first tap where
ours-to-cached exceeds cached-to-forward on relative L2.

usage: layer_trace.py --model-path DIR --ours-topk FILE --ctx 4000 --index 15 [--json OUT]
Run under an interpreter that has mlx_lm.
"""
import argparse
import json
import math
import os
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import decode_topk  # noqa: E402
import prompts  # noqa: E402


def layer_label(tap):
    """What a tap's input is: 'embeddings', 'layer K output' or 'last layer output'."""
    parts = tap.split(".")
    if parts[-1] == "input_layernorm" and len(parts) >= 3 and parts[-3] == "layers":
        k = int(parts[-2])
        return "embeddings" if k == 0 else f"layer {k - 1} output"
    return "last layer output"


def distance(a, b):
    """max |a-b|, ||a-b|| / ||b||, and the count of unequal elements."""
    if len(a) != len(b):
        raise ValueError(f"vector lengths differ: {len(a)} vs {len(b)}")
    diffs = [x - y for x, y in zip(a, b)]
    norm_b = math.sqrt(sum(y * y for y in b))
    l2 = math.sqrt(sum(d * d for d in diffs))
    return {"max_abs": max((abs(d) for d in diffs), default=0.0),
            "rel_l2": l2 / norm_b if norm_b else (0.0 if l2 == 0 else math.inf),
            "n_diff": sum(1 for d in diffs if d != 0)}


def compare(names, ours, cached, forward):
    """Per-tap rows and the index of the first tap beyond the mlx-lm spread."""
    rows, first = [], None
    for i, name in enumerate(names):
        oc, cf, of = distance(ours[i], cached[i]), distance(cached[i], forward[i]), distance(ours[i], forward[i])
        beyond = oc["rel_l2"] > cf["rel_l2"]
        rows.append({"tap": name, "what": layer_label(name), "ours_vs_cached": oc,
                     "cached_vs_forward": cf, "ours_vs_forward": of, "beyond_spread": beyond})
        if beyond and first is None:
            first = i
    return rows, first


class TapSink:
    def __init__(self, names):
        self.names = list(names)
        self.latest = {}

    def snapshot(self):
        missing = [n for n in self.names if n not in self.latest]
        if missing:
            raise RuntimeError(f"taps that did not fire: {missing[:3]}{'...' if len(missing) > 3 else ''}")
        return [self.latest[n] for n in self.names]


def tap_paths(named_modules):
    """Ordered tap paths from (path, module) pairs: layers.K.input_layernorm by K, then model.norm."""
    layers, finals = [], []
    for path, _ in named_modules:
        parts = path.split(".")
        if len(parts) >= 3 and parts[-1] == "input_layernorm" and parts[-3] == "layers" and parts[-2].isdigit():
            layers.append((int(parts[-2]), path))
        elif len(parts) >= 2 and parts[-1] == "norm" and parts[-2] == "model":
            finals.append(path)
    layers.sort()
    if not layers or [k for k, _ in layers] != list(range(len(layers))) or len(finals) != 1:
        raise ValueError(f"need layers.K.input_layernorm 0..K and one model.norm; "
                         f"found {len(layers)} layer norms, {len(finals)} final norms")
    return [p for _, p in layers] + finals


def install_taps(model, nn, mx):
    """Wrap each tap norm so it records its last-position input; returns the sink."""
    names = tap_paths(model.named_modules())
    sink = TapSink(names)

    class Tap(nn.Module):
        def __init__(self, inner, name):
            super().__init__()
            self.inner = inner
            self._tap_name = name

        def __call__(self, x):
            last = x.reshape(-1, x.shape[-1])[-1]
            sink.latest[self._tap_name] = last
            return self.inner(x)

    for name in names:
        parts = name.split(".")
        parent = model
        for p in parts[:-1]:
            parent = parent[int(p)] if p.isdigit() else getattr(parent, p)
        setattr(parent, parts[-1], Tap(getattr(parent, parts[-1]), name))
    return sink


def to_lists(mx, arrays):
    values = [a.astype(mx.float32) for a in arrays]
    mx.eval(*values)
    return [v.tolist() for v in values]


def main(argv=None):
    ap = argparse.ArgumentParser()
    ap.add_argument("--model-path", required=True)
    ap.add_argument("--ours-topk", required=True, help="JSONL from a serve with MACPROVIDER_LAB_DECODE_TOPK_LAYERS=1")
    ap.add_argument("--ctx", type=int, required=True)
    ap.add_argument("--index", type=int, required=True)
    ap.add_argument("--json", help="write the per-tap table here")
    args = ap.parse_args(argv)

    import mlx.core as mx
    import mlx.nn as nn
    from mlx_lm import load
    from mlx_lm.generate import generate_step

    model, tok = load(args.model_path)
    template = getattr(tok, "chat_template", None) or ""
    kw = {"enable_thinking": False} if "enable_thinking" in str(template) else {}
    prompt_ids = list(tok.apply_chat_template(prompts.build_messages(args.ctx, 0), add_generation_prompt=True, **kw))
    rec = decode_topk.select_record(decode_topk.load_records(args.ours_topk), prompt_ids, args.index)
    if "layers" not in rec:
        raise SystemExit(f"record has no layers ({rec.get('layers_error', 'serve ran without MACPROVIDER_LAB_DECODE_TOPK_LAYERS=1')})")
    generated = rec["generated_token_ids"]

    sink = install_taps(model, nn, mx)
    our_names = [e["tap"] for e in rec["layers"]]
    if our_names != sink.names:
        raise SystemExit(f"tap names differ: ours {our_names[:2]}... vs mlx-lm {sink.names[:2]}...")
    ours = [e["values"] for e in rec["layers"]]

    # mlx-lm cached decode: snapshot the taps inside the step-N processor call,
    # right after the forward that produced step N's logits.
    forced = decode_topk.ForcedDecode(mx, generated, args.index)
    cached_arrays = []
    base = forced.processor

    def processor(tokens, logits):
        if forced.process_calls == args.index:
            cached_arrays.extend(sink.snapshot())
        return base(tokens, logits)

    sink.latest.clear()
    for n, _ in enumerate(generate_step(mx.array(prompt_ids), model, max_tokens=args.index + 1,
                                        sampler=forced.sampler, logits_processors=[processor])):
        if n == args.index:
            break
    if not cached_arrays:
        raise SystemExit(f"generate_step never reached decode index {args.index}")
    cached = to_lists(mx, cached_arrays)

    sink.latest.clear()
    mx.eval(model(mx.array(prompt_ids + generated)[None]))
    forward = to_lists(mx, sink.snapshot())

    rows, first = compare(sink.names, ours, cached, forward)
    print(f"ctx={args.ctx} decode index {args.index}: {len(prompt_ids)} prompt ids + {len(generated)} generated, "
          f"{len(rows)} taps, hidden {len(ours[0])}")
    print(f"  {'tap input':<20} {'ours-cached rel_l2':>18} {'max_abs':>9} {'n_diff':>7}"
          f"   {'cached-fwd rel_l2':>17} {'max_abs':>9} {'n_diff':>7}")
    for r in rows:
        oc, cf = r["ours_vs_cached"], r["cached_vs_forward"]
        print(f"  {r['what']:<20} {oc['rel_l2']:18.3e} {oc['max_abs']:9.4f} {oc['n_diff']:7d}"
              f"   {cf['rel_l2']:17.3e} {cf['max_abs']:9.4f} {cf['n_diff']:7d}{'  <' if r['beyond_spread'] else ''}")
    if first is None:
        print("  no tap is beyond mlx-lm's own cached-vs-forward spread")
    else:
        print(f"  first beyond spread: {rows[first]['what']} ({rows[first]['tap']})")
    if args.json:
        with open(args.json, "w") as f:
            json.dump({"ctx_target": args.ctx, "decode_index": args.index, "prompt_tokens": len(prompt_ids),
                       "first_beyond_spread": None if first is None else rows[first]["tap"], "rows": rows}, f, indent=2)
            f.write("\n")


if __name__ == "__main__":
    main()
