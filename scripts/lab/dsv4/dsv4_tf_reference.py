"""DeepSeek V4-Flash against a port of DeepSeek's reference (#2111).

The reference is the MLX port of DeepSeek's `inference/model.py` + `kernel.py`
that ships in the V4-Flash-0731 MXFP4 artifact (`<model_dir>/deepseek_v4.py`).
It is loaded with four corrections:

- `Block.hc_post` mixes the hyper-connection streams as DeepSeek does,
  `y[j] = post[j] * x + sum_i comb[i, j] * residual[i]` in float32 (the port
  indexes `residual[:, :, None]`, which mixes `residual[j]` instead, and
  expands in bf16);
- the QAT simulations (fp8/fp4 activation quant-dequant, the indexer's
  Hadamard rotation) are off unless `--qat` is given, because the Swift port
  leaves them out;
- `sparse_attn` and the prefill indexer run in query tiles, and the MoE
  groups tokens by expert with numpy, so 32k-token prompts fit in memory
  and time; the arithmetic is unchanged.

Subcommands (Python with mlx >= 0.32 and numpy; the full model needs ~170 GB):

  oracle  <model_dir> <out_dir> --prompts <dir with oracle_<ctx>.npz>
          Greedy oracles in the `dsv4_reference_bench.py` format (prompt,
          greedy, top_idx and top_logprob for the first 16 steps), reusing
          the prompts of the existing oracles. Convert each with
          `scripts/lab/cb-studio/glm53_oracle_json.py` for `dsv4-parity`.
  tokens  <model_dir> <result.json> <out.json> [--max-tokens 8192]
          The teacher-forced sequence of one coding-compare result (prompt
          plus the model's reasoning and answer, DSML-encoded) and the dump
          positions: every 64 tokens and 2040-2055, 4088-4103.
  dump    <model_dir> <tokens.json> <out.safetensors>
          The reference's per-layer state at those positions, in the layout
          of the fork's `DeepseekV4TeacherForcedDumpTests`.
  compare <ours.safetensors> <reference.safetensors> [--json out.json]
          Layer-by-layer differences.
"""

import argparse
import importlib.util
import json
import sys
from pathlib import Path

import numpy as np

TOPK = 16
ORACLE_STEPS = 16
QUERY_TILE = 1024


def reference(model_dir, qat):
    import mlx.core as mx

    spec = importlib.util.spec_from_file_location("dsv4_reference", Path(model_dir) / "deepseek_v4.py")
    ref = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(ref)
    if not qat:
        ref.act_quant_sim = lambda x, block_size=128: x
        ref.fp4_act_quant_sim = lambda x, block_size=32: x
        ref.rotate_activation = lambda x: x

    def hc_post(self, x, residual, post, comb):
        y = post[..., None] * x[:, :, None, :].astype(mx.float32) + (
            comb[..., None] * residual[:, :, :, None, :].astype(mx.float32)
        ).sum(axis=2)
        return y.astype(x.dtype)

    ref.Block.hc_post = hc_post

    dense_sparse_attn = ref.sparse_attn

    def sparse_attn(q, kv, attn_sink, topk_idxs, softmax_scale):
        s = q.shape[1]
        if s <= QUERY_TILE:
            return dense_sparse_attn(q, kv, attn_sink, topk_idxs, softmax_scale)
        tiles = []
        for start in range(0, s, QUERY_TILE):
            tile = dense_sparse_attn(
                q[:, start:start + QUERY_TILE], kv, attn_sink,
                topk_idxs[:, start:start + QUERY_TILE], softmax_scale)
            mx.eval(tile)
            tiles.append(tile)
        return mx.concatenate(tiles, axis=1)

    ref.sparse_attn = sparse_attn

    def indexer_call(self, x, qr, start_pos, offset):
        # Indexer.__call__ with the prefill scores in query tiles.
        bsz, seqlen, _ = x.shape
        rd, ratio = self.rope_head_dim, self.compress_ratio
        q = self.wq_b(qr).reshape(bsz, seqlen, self.n_heads, self.head_dim)
        q = mx.concatenate([q[..., :-rd], self.rope(q[..., -rd:], start_pos)], axis=-1)
        q = ref.fp4_act_quant_sim(ref.rotate_activation(q), 32)
        self.compressor(x, start_pos)
        weights = self.weights_proj(x) * (self.softmax_scale * self.n_heads ** -0.5)
        t = self.compressor.n
        if t == 0:
            return mx.zeros((bsz, seqlen, 0), mx.int32)
        kvc = self.compressor.cache[:, :t].astype(mx.float32)
        k = min(self.index_topk, t)
        parts = []
        for start in range(0, seqlen, QUERY_TILE):
            end = min(start + QUERY_TILE, seqlen)
            scores = mx.einsum("bshd,btd->bsht", q[:, start:end].astype(mx.float32), kvc)
            scores = (mx.maximum(scores, 0.0) * weights[:, start:end].astype(mx.float32)[..., None]).sum(axis=2)
            if start_pos == 0:
                limit = np.arange(start + 1, end + 1)[:, None] // ratio
                scores = scores + mx.array(np.where(np.arange(t)[None, :] >= limit, -np.inf, 0.0), mx.float32)
            top = mx.argpartition(-scores, kth=k - 1, axis=-1)[..., :k].astype(mx.int32)
            if start_pos == 0:
                invalid = top >= mx.array(np.arange(start + 1, end + 1)[:, None] // ratio)
                top = mx.where(invalid, -1, top + offset)
            else:
                top = top + offset
            mx.eval(top)
            parts.append(top)
        return mx.concatenate(parts, axis=1)

    ref.Indexer.__call__ = indexer_call

    def moe_call(self, x, input_ids):
        shape = x.shape
        x = x.reshape(-1, shape[-1])
        weights, indices = self.gate(x, input_ids.reshape(-1))
        inds = np.array(indices)
        wts = np.array(weights.astype(mx.float32))
        y = mx.zeros((x.shape[0], shape[-1]), mx.float32)
        for i in range(self.n_routed_experts):
            rows, cols = np.nonzero(inds == i)
            if rows.size == 0:
                continue
            r = mx.array(rows.astype(np.int32))
            w = mx.array(wts[rows, cols][:, None])
            y = y.at[r].add(self.experts[i](x[r], w).astype(mx.float32))
        y = y + self.shared_experts(x).astype(mx.float32)
        return y.astype(x.dtype).reshape(shape)

    ref.MoE.__call__ = moe_call
    return ref


def load(ref, model_dir):
    import mlx.core as mx

    args = ref.ModelArgs.from_json(Path(model_dir) / "config.json")
    model = ref.Transformer(args)
    loaded, _ = ref.load_weights(model, model_dir, include=lambda n: not n.startswith("mtp."))
    expected = {k for k in ref.expected_param_shapes(model) if not k.startswith("mtp.")}
    missing = expected - loaded
    if missing:
        sys.exit(f"artifact lacks reference tensors: {sorted(missing)[:8]}")
    mx.eval(model.parameters())
    return model


def cmd_oracle(a):
    import mlx.core as mx

    ref = reference(a.model_dir, a.qat)
    out = Path(a.out_dir)
    out.mkdir(parents=True, exist_ok=False)
    for ctx in [int(c) for c in a.contexts.split(",")]:
        prompt = np.load(Path(a.prompts) / f"oracle_{ctx}.npz")["prompt"].astype(np.int32)
        model = load(ref, a.model_dir)  # the reference keeps its caches on the modules
        logits = model(mx.array(prompt[None]), start_pos=0)
        greedy, top_idx, top_lp = [], [], []
        pos = len(prompt)
        for step in range(a.decode):
            row = logits[0, -1].astype(mx.float32)
            lp = row - mx.logsumexp(row, axis=-1, keepdims=True)
            token = int(mx.argmax(lp))
            greedy.append(token)
            if step < ORACLE_STEPS:
                idx = mx.argsort(-lp)[:TOPK]
                top_idx.append(np.array(idx, dtype=np.int32))
                top_lp.append(np.array(lp[idx], dtype=np.float32))
            logits = model(mx.array([[token]]), start_pos=pos)
            pos += 1
        np.savez(out / f"oracle_{ctx}.npz", prompt=prompt, greedy=np.array(greedy, np.int32),
                 top_idx=np.stack(top_idx), top_logprob=np.stack(top_lp))
        print(json.dumps({"ctx": ctx, "greedy_head": greedy[:16], "qat": a.qat}), flush=True)
        del model
        mx.clear_cache()


def cmd_tokens(a):
    from transformers import AutoTokenizer

    spec = importlib.util.spec_from_file_location(
        "encoding_dsv4", Path(a.model_dir) / "encoding" / "encoding_dsv4.py")
    enc = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(enc)
    result = json.load(open(a.result))
    messages = [
        {"role": "user", "content": result["prompt"]},
        {"role": "assistant", "reasoning_content": result.get("reasoning_content") or "",
         "content": result.get("content") or ""},
    ]
    text = enc.encode_messages(messages, thinking_mode="thinking", drop_thinking=False)
    tokenizer = AutoTokenizer.from_pretrained(a.model_dir)
    tokens = tokenizer.encode(text, add_special_tokens=False)[: a.max_tokens]
    marks = set(range(0, len(tokens), 64)) | set(range(2040, 2056)) | set(range(4088, 4104))
    positions = sorted(p for p in marks if p < len(tokens))
    json.dump({"source": Path(a.result).name, "tokens": tokens, "positions": positions}, open(a.out, "w"))
    print(f"{a.out}: {len(tokens)} tokens, {len(positions)} positions")


def cmd_dump(a):
    import mlx.core as mx

    ref = reference(a.model_dir, a.qat)
    model = load(ref, a.model_dir)
    request = json.load(open(a.tokens))
    tokens, positions = request["tokens"], request["positions"]
    ids = mx.array([tokens])
    at = mx.array(np.array(positions, dtype=np.int32))
    out = {"positions": at}
    h = model.embed(ids)
    h = mx.broadcast_to(h[:, :, None, :], (*h.shape[:-1], model.hc_mult, h.shape[-1]))
    for l, layer in enumerate(model.layers):
        residual = h
        x, post, comb = layer.hc_pre(h, layer.hc_attn_fn, layer.hc_attn_scale, layer.hc_attn_base)
        x = layer.attn_norm(x)
        out[f"attn_in.{l}"] = x[0][at].astype(mx.float32)
        h = layer.hc_post(layer.attn(x, 0), residual, post, comb)
        residual = h
        x, post, comb = layer.hc_pre(h, layer.hc_ffn_fn, layer.hc_ffn_scale, layer.hc_ffn_base)
        x = layer.ffn_norm(x)
        out[f"ffn_in.{l}"] = x[0][at].astype(mx.float32)
        _, experts = layer.ffn.gate(x.reshape(-1, x.shape[-1]), ids.reshape(-1))
        out[f"experts.{l}"] = mx.sort(experts[at].astype(mx.int32), axis=-1)
        h = layer.hc_post(layer.ffn(x, ids), residual, post, comb)
        out[f"h.{l}"] = h[0][at].astype(mx.float32)
        mx.eval(h, *out.values())
        attn = layer.attn
        if attn.compress_ratio:
            out[f"pool.{l}"] = attn.compressor.cache[0, :attn.compressor.n].astype(mx.float32)
        if attn.compress_ratio == 4:
            ix = attn.indexer
            pool = ix.compressor.cache[0, :ix.compressor.n]
            out[f"index_pool.{l}"] = pool.astype(mx.float32)
            rows = []
            for i, p in enumerate(positions):
                visible = (p + 1) // 4
                k = min(ix.index_topk, visible)
                if k == 0:
                    rows.append(mx.full((ix.index_topk,), -1, mx.int32))
                    continue
                xi = out[f"attn_in.{l}"][i].astype(x.dtype)[None, None]
                qr = attn.q_norm(attn.wq_a(xi))
                q = ix.wq_b(qr).reshape(1, 1, ix.n_heads, ix.head_dim)
                q = mx.concatenate([q[..., :-attn.rope_head_dim], attn.rope(q[..., -attn.rope_head_dim:], p)], axis=-1)
                q = ref.fp4_act_quant_sim(ref.rotate_activation(q), 32)
                w = ix.weights_proj(xi) * (ix.softmax_scale * ix.n_heads ** -0.5)
                s = mx.einsum("hd,td->ht", q[0, 0].astype(mx.float32), pool[:visible].astype(mx.float32))
                s = (mx.maximum(s, 0.0) * w[0, 0].astype(mx.float32)[:, None]).sum(axis=0)
                top = mx.sort(mx.argsort(-s)[:k].astype(mx.int32))
                rows.append(top if k == ix.index_topk else mx.concatenate([top, mx.full((ix.index_topk - k,), -1, mx.int32)]))
            out[f"topk.{l}"] = mx.stack(rows)
            mx.eval(out[f"topk.{l}"])
        print(f"layer {l} done", flush=True)
    last = out[f"h.{len(model.layers) - 1}"].astype(h.dtype)[None]
    reduced = ref.hc_head_reduce(last, model.hc_head_fn, model.hc_head_scale, model.hc_head_base,
                                 model.args.norm_eps, model.args.hc_eps)
    out["logits"] = model.head(model.norm(reduced))[0]
    mx.save_safetensors(a.out, out)
    print(f"{a.out}: {len(positions)} positions, {len(model.layers)} layers")


def cmd_compare(a):
    import mlx.core as mx

    def widened(path):
        return {k: v.astype(mx.float32) if v.dtype == mx.bfloat16 else v for k, v in mx.load(path).items()}

    ours, theirs = widened(a.ours), widened(a.reference)
    if not mx.array_equal(ours["positions"], theirs["positions"]):
        sys.exit("dumps cover different positions")
    positions = np.array(ours["positions"])

    def rel(key):
        x, y = np.array(ours[key], np.float64), np.array(theirs[key], np.float64)
        return float(np.linalg.norm(x - y) / max(np.linalg.norm(y), 1e-30))

    report = {"layers": []}
    layers = sorted({int(k.split(".")[1]) for k in ours if k.startswith("h.")})
    for l in layers:
        row = {"layer": l}
        for key in ("attn_in", "ffn_in", "h"):
            row[f"{key}_rel_l2"] = rel(f"{key}.{l}")
        e1, e2 = np.array(ours[f"experts.{l}"]), np.array(theirs[f"experts.{l}"])
        row["experts_same_set"] = float(np.mean([set(a_) == set(b_) for a_, b_ in zip(e1, e2)]))
        if f"pool.{l}" in ours and f"pool.{l}" in theirs:
            n = min(ours[f"pool.{l}"].shape[0], theirs[f"pool.{l}"].shape[0])
            row["pool_entries"] = [int(ours[f"pool.{l}"].shape[0]), int(theirs[f"pool.{l}"].shape[0])]
            x, y = np.array(ours[f"pool.{l}"][:n], np.float64), np.array(theirs[f"pool.{l}"][:n], np.float64)
            row["pool_rel_l2"] = float(np.linalg.norm(x - y) / max(np.linalg.norm(y), 1e-30))
        if f"topk.{l}" in ours and f"topk.{l}" in theirs:
            jac = []
            for a_, b_ in zip(np.array(ours[f"topk.{l}"]), np.array(theirs[f"topk.{l}"])):
                sa, sb = set(a_[a_ >= 0]), set(b_[b_ >= 0])
                jac.append(len(sa & sb) / max(len(sa | sb), 1))
            row["topk_jaccard_mean"] = float(np.mean(jac))
            row["topk_jaccard_min"] = float(np.min(jac))
        report["layers"].append(row)
    lo, lt = np.array(ours["logits"], np.float64), np.array(theirs["logits"], np.float64)
    lpo = lo - np.log(np.exp(lo - lo.max(-1, keepdims=True)).sum(-1, keepdims=True)) - lo.max(-1, keepdims=True)
    lpt = lt - np.log(np.exp(lt - lt.max(-1, keepdims=True)).sum(-1, keepdims=True)) - lt.max(-1, keepdims=True)
    report["logits"] = {
        "top1_agreement": float(np.mean(lo.argmax(-1) == lt.argmax(-1))),
        "max_abs_dlogprob_at_reference_top1": float(np.max(np.abs(
            np.take_along_axis(lpo - lpt, lt.argmax(-1)[:, None], -1)))),
        "first_top1_disagreement_position": next(
            (int(p) for p, x, y in zip(positions, lo.argmax(-1), lt.argmax(-1)) if x != y), None),
    }
    for row in report["layers"]:
        print(json.dumps(row))
    print(json.dumps(report["logits"]))
    if a.json:
        json.dump(report, open(a.json, "w"), indent=1)


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    sub = ap.add_subparsers(dest="cmd", required=True)
    p = sub.add_parser("oracle")
    p.add_argument("model_dir")
    p.add_argument("out_dir")
    p.add_argument("--prompts", required=True)
    p.add_argument("--contexts", default="1024,8192,32768")
    p.add_argument("--decode", type=int, default=256)
    p.add_argument("--qat", action="store_true")
    p = sub.add_parser("tokens")
    p.add_argument("model_dir")
    p.add_argument("result")
    p.add_argument("out")
    p.add_argument("--max-tokens", type=int, default=8192)
    p = sub.add_parser("dump")
    p.add_argument("model_dir")
    p.add_argument("tokens")
    p.add_argument("out")
    p.add_argument("--qat", action="store_true")
    p = sub.add_parser("compare")
    p.add_argument("ours")
    p.add_argument("reference")
    p.add_argument("--json")
    a = ap.parse_args()
    {"oracle": cmd_oracle, "tokens": cmd_tokens, "dump": cmd_dump, "compare": cmd_compare}[a.cmd](a)


if __name__ == "__main__":
    main()
