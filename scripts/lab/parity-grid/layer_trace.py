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

With --sublayer N (serve run with MACPROVIDER_LAB_DECODE_TOPK_SUBLAYER=N), it
also compares the other norms inside layer N that ran on both sides: for
Gemma 4, `pre_feedforward_layernorm` (the post-attention residual state),
`post_feedforward_layernorm_1` (the dense MLP output) and
`post_feedforward_layernorm_2` (the weighted expert sum). When layer N has a
MoE router, it feeds each path's post-attention state through mlx-lm's router
and prints the top-k experts, their weights and the score margin between the
k-th and the next expert, plus the ranking around the k-th slot. It then
replays mlx-lm's experts on each path's state with the k-1 shared experts and
each near-tie candidate in the k-th slot, and prints how far each replay is
from that path's recorded MoE output: the candidate that reproduces our
recorded output is the expert our route used.

usage: layer_trace.py --model-path DIR --ours-topk FILE --ctx 4000 --index 15 [--sublayer 18] [--json OUT]
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
    def __init__(self, names, extra_names=()):
        self.names = list(names)
        self.extra_names = list(extra_names)
        self.latest = {}

    def extras(self):
        """{name: vector} for the sub-layer taps that fired."""
        return {n: self.latest[n] for n in self.extra_names if n in self.latest}

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


def sublayer_paths(named_modules, layer_input, is_norm):
    """Every other norm under layer_input's layer, sorted by path."""
    prefix = layer_input[: -len("input_layernorm")]
    return sorted(p for p, m in named_modules if is_norm(m) and p.startswith(prefix) and p != layer_input)


def last_position(x):
    """The last position of x ([B, L, ...]) flattened; [.., H] keeps the last row."""
    if getattr(x, "ndim", 2) >= 3:
        return x[-1, -1].flatten()
    return x.reshape(-1, x.shape[-1])[-1]


def install_taps(model, nn, mx, sublayer=None):
    """Wrap each tap norm so it records its last-position input; returns the sink."""
    pairs = model.named_modules()
    names = tap_paths(pairs)
    extra = []
    if sublayer is not None:
        if not 0 <= sublayer < len(names) - 1:
            raise ValueError(f"sub-layer {sublayer} is outside 0..{len(names) - 2}")
        extra = sublayer_paths(pairs, names[sublayer], lambda m: isinstance(m, nn.RMSNorm))
    sink = TapSink(names, extra)

    class Tap(nn.Module):
        def __init__(self, inner, name):
            super().__init__()
            self.inner = inner
            self._tap_name = name

        def __call__(self, x):
            sink.latest[self._tap_name] = last_position(x)
            return self.inner(x)

    for name in names + extra:
        parts = name.split(".")
        parent = model
        for p in parts[:-1]:
            parent = parent[int(p)] if p.isdigit() else getattr(parent, p)
        setattr(parent, parts[-1], Tap(getattr(parent, parts[-1]), name))
    return sink


def compare_sublayer(ours, cached, forward):
    """Rows for the sub-layer taps present on all three paths, in path order."""
    rows = []
    for name in sorted(set(ours) & set(cached) & set(forward)):
        rows.append({"tap": name, "ours_vs_cached": distance(ours[name], cached[name]),
                     "cached_vs_forward": distance(cached[name], forward[name]),
                     "ours_vs_forward": distance(ours[name], forward[name])})
    return rows


def router_picks(mx, router, h, top_k):
    """mlx-lm's router on one bf16 hidden vector: top-k ids (by score), weights, margin."""
    x = mx.array(h, dtype=mx.bfloat16)[None, None]
    scores = router.proj(mx.fast.rms_norm(x, router.scale * router._root_size, router.eps))[0, 0]
    ids, weights = router(x)
    order = mx.argsort(-scores.astype(mx.float32))
    mx.eval(scores, ids, weights, order)
    ranked = order.tolist()
    s = scores.astype(mx.float32).tolist()
    picked = sorted(zip(ids[0, 0].tolist(), weights[0, 0].astype(mx.float32).tolist()), key=lambda t: -s[t[0]])
    return {"ids": [i for i, _ in picked], "weights": [w for _, w in picked],
            "kth_score": s[ranked[top_k - 1]], "next_id": ranked[top_k], "next_score": s[ranked[top_k]],
            "margin": s[ranked[top_k - 1]] - s[ranked[top_k]]}


def router_ranking(mx, router, h, n):
    """mlx-lm's router scores on one bf16 hidden vector: the n best as [id, score], best first."""
    x = mx.array(h, dtype=mx.bfloat16)[None, None]
    s = router.proj(mx.fast.rms_norm(x, router.scale * router._root_size, router.eps))[0, 0].astype(mx.float32)
    order = mx.argsort(-s)
    mx.eval(s, order)
    s = s.tolist()
    return [[i, s[i]] for i in order.tolist()[:n]]


def expert_replay(mx, router, experts, norm, h, base_ids, candidates):
    """mlx-lm's weighted expert sum on h with experts base_ids + [c], for each candidate c.

    Mirrors the MoE branch of mlx-lm's Gemma 4 decoder layer: the expert input is
    norm(h), the weights are the softmax of the router scores over the chosen ids
    times per_expert_scale, in the model's dtype. Returns {c: vector}.
    """
    x = mx.array(h, dtype=mx.bfloat16)[None, None]
    scores = router.proj(mx.fast.rms_norm(x, router.scale * router._root_size, router.eps))
    xe = norm(x)
    out = {}
    for c in candidates:
        ids = mx.array([[list(base_ids) + [c]]])
        w = mx.softmax(mx.take_along_axis(scores, ids, axis=-1), axis=-1) * router.per_expert_scale[ids]
        out[c] = experts(xe, ids, w)[0, 0].astype(mx.float32)
    mx.eval(*out.values())
    return {c: v.tolist() for c, v in out.items()}


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
    ap.add_argument("--sublayer", type=int, help="also compare the norms inside this layer (serve needs SUBLAYER=N)")
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

    sink = install_taps(model, nn, mx, args.sublayer)
    ours_extra = {e["tap"]: e["values"] for e in rec.get("sublayer", [])}
    if args.sublayer is not None and not ours_extra:
        raise SystemExit("record has no sublayer taps (serve ran without MACPROVIDER_LAB_DECODE_TOPK_SUBLAYER)")
    unknown = sorted(set(ours_extra) - set(sink.extra_names))
    if unknown:
        raise SystemExit(f"sub-layer taps differ: ours has {unknown}")
    our_names = [e["tap"] for e in rec["layers"]]
    if our_names != sink.names:
        raise SystemExit(f"tap names differ: ours {our_names[:2]}... vs mlx-lm {sink.names[:2]}...")
    ours = [e["values"] for e in rec["layers"]]

    # mlx-lm cached decode: snapshot the taps inside the step-N processor call,
    # right after the forward that produced step N's logits.
    forced = decode_topk.ForcedDecode(mx, generated, args.index)
    cached_arrays = []
    cached_extra = {}
    base = forced.processor

    def processor(tokens, logits):
        if forced.process_calls == args.index:
            cached_arrays.extend(sink.snapshot())
            cached_extra.update(sink.extras())
        return base(tokens, logits)

    sink.latest.clear()
    for n, _ in enumerate(generate_step(mx.array(prompt_ids), model, max_tokens=args.index + 1,
                                        sampler=forced.sampler, logits_processors=[processor])):
        if n == args.index:
            break
    if not cached_arrays:
        raise SystemExit(f"generate_step never reached decode index {args.index}")
    cached = to_lists(mx, cached_arrays)
    cached_extra = dict(zip(cached_extra, to_lists(mx, list(cached_extra.values()))))

    sink.latest.clear()
    mx.eval(model(mx.array(prompt_ids + generated)[None]))
    forward = to_lists(mx, sink.snapshot())
    forward_extra = sink.extras()
    forward_extra = dict(zip(forward_extra, to_lists(mx, list(forward_extra.values()))))

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
    sub_rows, routing = [], None
    if args.sublayer is not None:
        sub_rows = compare_sublayer(ours_extra, cached_extra, forward_extra)
        layer_in = sink.names[args.sublayer]
        print(f"\n  inside layer {args.sublayer} (input: {layer_in}); ours / cached / forward ran: "
              f"{len(ours_extra)} / {len(cached_extra)} / {len(forward_extra)} of {len(sink.extra_names)} norms")
        rows_in = [("layer input", rows[args.sublayer]), ("layer output", rows[args.sublayer + 1])]
        for label, r in rows_in[:1] + [(x["tap"][len(layer_in) - len("input_layernorm"):], x) for x in sub_rows] + rows_in[1:]:
            oc, cf = r["ours_vs_cached"], r["cached_vs_forward"]
            print(f"  {label:<36} {oc['rel_l2']:11.3e} {oc['max_abs']:9.4f} {oc['n_diff']:6d}"
                  f"   {cf['rel_l2']:11.3e} {cf['max_abs']:9.4f} {cf['n_diff']:6d}"
                  f"{'  <' if oc['rel_l2'] > cf['rel_l2'] else ''}")
        parent = model
        for p in layer_in.split(".")[:-1]:
            parent = parent[int(p)] if p.isdigit() else getattr(parent, p)
        router = getattr(parent, "router", None)
        h_name = layer_in[: -len("input_layernorm")] + "pre_feedforward_layernorm"
        if router is not None and all(h_name in d for d in (ours_extra, cached_extra, forward_extra)):
            top_k = router.config.top_k_experts
            routing = {name: router_picks(mx, router, d[h_name], top_k)
                       for name, d in (("ours", ours_extra), ("cached", cached_extra), ("forward", forward_extra))}
            print(f"  router (mlx-lm's) on each path's post-attention state, top-{top_k}:")
            for name, r in routing.items():
                print(f"    {name:<8} ids {r['ids']}  weights {[round(w, 4) for w in r['weights']]}"
                      f"  k-th vs next ({r['next_id']}) margin {r['margin']:+.4f}")
            same = len({tuple(sorted(r["ids"])) for r in routing.values()}) == 1
            print(f"  expert set {'identical' if same else 'DIFFERS'} across paths")
            paths = (("ours", ours_extra), ("cached", cached_extra), ("forward", forward_extra))
            for name, d in paths:
                routing[name]["ranking"] = router_ranking(mx, router, d[h_name], top_k + 8)
            print(f"  router ranking, ranks {top_k - 1}..{top_k + 8} (id:score):")
            for name, _ in paths:
                print(f"    {name:<8} " + "  ".join(f"{i}:{sc:.6g}" for i, sc in routing[name]["ranking"][top_k - 2:]))
            moe_name = layer_in[: -len("input_layernorm")] + "post_feedforward_layernorm_2"
            bases = {tuple(sorted(i for i, _ in routing[n]["ranking"][: top_k - 1])) for n, _ in paths}
            experts = getattr(parent, "experts", None)
            norm2 = getattr(parent, "pre_feedforward_layernorm_2", None)
            if experts is not None and norm2 is not None and len(bases) == 1 \
                    and all(moe_name in d for _, d in paths):
                base = [i for i, _ in routing["ours"]["ranking"][: top_k - 1]]
                cands = []
                for n, _ in paths:
                    for i, _ in routing[n]["ranking"][top_k - 1: top_k + 4]:
                        if i not in cands:
                            cands.append(i)
                norm2 = getattr(norm2, "inner", norm2)
                replay = {"base_ids": base, "candidates": cands, "rows": []}
                per_path = {n: expert_replay(mx, router, experts, norm2, d[h_name], base, cands) for n, d in paths}
                print(f"  expert replay: mlx-lm's experts on each path's state, the {top_k - 1} shared experts "
                      f"plus one candidate in slot {top_k};")
                print(f"  rel_l2 of the replayed MoE output from that path's recorded MoE output ({moe_name}):")
                print(f"    {'slot ' + str(top_k):<10} {'ours':>11} {'cached':>11} {'forward':>11}")
                for c in cands:
                    dist = {n: distance(d[moe_name], per_path[n][c]) for n, d in paths}
                    replay["rows"].append({"candidate": c, **dist})
                    print(f"    {c:<10} " + " ".join(f"{dist[n]['rel_l2']:11.3e}" for n, _ in paths))
                routing["expert_replay"] = replay
            else:
                print(f"  expert replay skipped: base sets {len(bases)}, experts {experts is not None}, "
                      f"MoE output on all paths {all(moe_name in d for _, d in paths)}")
    if args.json:
        with open(args.json, "w") as f:
            json.dump({"ctx_target": args.ctx, "decode_index": args.index, "prompt_tokens": len(prompt_ids),
                       "first_beyond_spread": None if first is None else rows[first]["tap"], "rows": rows,
                       "sublayer": args.sublayer, "sublayer_rows": sub_rows, "routing": routing}, f, indent=2)
            f.write("\n")


if __name__ == "__main__":
    main()
