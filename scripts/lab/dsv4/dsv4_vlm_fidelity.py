"""mlx-vlm 0.7.10's DeepSeek V4 target with three of the port fixes (#2111).

mlx-vlm 0.7.10 diverges from DeepSeek's `inference/model.py` in ways that move
the target's tokens (PR #2151, fork 3.32.3-macprovider.10.9). `apply(model)`
corrects the three that change what the target computes, not only how
precisely:

1. Ratio-4 overlap carry (model.py:309-310, 336-338, 353-360). A ratio-4
   compressor window pools the first half of the previous window's kv/gate
   with the second half of its own. mlx-vlm restarts that chain at every call
   (`_overlap_compress_kv` pads window 0 of each call with zeros / -inf), so
   every decode-produced pool entry, and the first entry of every prefill
   chunk, loses its previous-window half. Here each pooling cache keeps the
   raw kv/gate of its recent windows per row, keyed by pool index, and the
   first window of a call borrows from window `start - 1`. Keying by pool
   index makes speculative commit/abort exact without hooking them: a lookup
   is always for a committed window, and a window is only ever rewritten by
   a later production of the same index.
2. Exact indexer top-k (model.py:426-433). mlx-vlm defaults to HISA
   (`index_block 64`, `index_keep 16`), an approximate block filter that is
   active from 1024 pooled entries (4096 tokens) on. `index_block = 0` takes
   the exact top-k path.
3. Router logits in float32 (model.py:570). mlx-vlm computes `x @ W.T` in
   bf16 and widens afterwards. The gate weight is widened once and the input
   is cast, so the logits are float32 from a float32 product.

The float32 precision fixes (attention/sinks, compressor arithmetic, expert
SwiGLU, head) are not applied: they move near-ties, not the computation.

`verify_sources()` refuses unless the installed mlx-vlm files are the exact
bytes these patches were written against. `python3 -I dsv4_vlm_fidelity.py
--selftest` runs the carry check on a tiny random compressor (no model).
"""

import hashlib
import pathlib

import mlx.core as mx

PINNED_SOURCES = {
    "models/deepseek_v4/language.py": "dac17de2bc0056794b67b07617852f7514b7cef5e249defb8b925fdfb876205f",
    "models/cache.py": "4c7526c6b17b97827cc810ea0e66bb3a364b4100d6aedf4878a1e15703a95031",
    "speculative/dflash.py": "39244ec611b38caacd706474722b2997e50954fe48219e26baf9017ade881ad0",
    "speculative/common.py": "e3d3c0294a6d6fc915a32e96460370bfe57baef19539c5a290d4254525717cf1",
    "speculative/drafters/deepseek_v4_dspark/deepseek_v4_dspark.py":
        "36b78a47d87b3b37cba3b60534cc6513b9887963ad93fdd8e3e4a94fea849b37",
    "generate/ar.py": "315787385813c879db31e7856b69b92123f8c7e7be06070d24587d3834f86b80",
}
# Windows kept per row. A speculative round rolls back at most 7 tokens, i.e.
# 2 ratio-4 windows; 16 leaves room.
HISTORY = 16
CARRY = "_dsv4_overlap_carry"
original_compressor_call = None


def verify_sources():
    import mlx_vlm

    root = pathlib.Path(mlx_vlm.__file__).parent
    bad = {}
    for rel, want in PINNED_SOURCES.items():
        got = hashlib.sha256((root / rel).read_bytes()).hexdigest()
        if got != want:
            bad[rel] = got
    if bad:
        raise RuntimeError(f"mlx-vlm sources differ from the pinned 0.7.10 bytes: {bad}")
    return {"mlx_vlm_root": str(root), "pinned_sources": PINNED_SOURCES}


@mx.compile
def _overlap_with_carry(kv, gate, ape, prev_kv, prev_gate):
    # Same arithmetic as mlx-vlm's _overlap_compress_kv, with window 0's
    # first half taken from the previous window instead of zeros / -inf.
    _, _, _, D = kv.shape
    h = D // 2
    gate = gate + ape.astype(gate.dtype)
    prev_gate = prev_gate + ape.astype(gate.dtype)
    kv_a = mx.concatenate([prev_kv[:, None, :, :h], kv[:, :-1, :, :h]], axis=1)
    gate_a = mx.concatenate([prev_gate[:, None, :, :h], gate[:, :-1, :, :h]], axis=1)
    kv = mx.concatenate([kv_a, kv[..., h:]], axis=2)
    gate = mx.concatenate([gate_a, gate[..., h:]], axis=2)
    weights = mx.softmax(gate, axis=-2, precise=True)
    return (kv * weights).sum(axis=-2)


def _rows(cache, batch):
    rows = getattr(cache, CARRY, None)
    if rows is None or len(rows) != batch:
        if rows and any(rows):
            raise RuntimeError(f"overlap carry has {len(rows)} rows, cache has {batch}")
        rows = [{} for _ in range(batch)]
        setattr(cache, CARRY, rows)
    return rows


def _install():
    from mlx_vlm.models import cache as C
    from mlx_vlm.models.deepseek_v4 import language as L

    if getattr(L.Compressor, "_dsv4_fidelity", False):
        return L, C
    global original_compressor_call
    original_call = original_compressor_call = L.Compressor.__call__

    def compressor_call(self, x, pool_cache, offset):
        if not self.overlap or pool_cache is None:
            return original_call(self, x, pool_cache, offset)
        B = x.shape[0]
        batch = isinstance(pool_cache, C.BatchPoolingCache)
        starts = list(pool_cache._pool_lengths) if batch else [pool_cache.offset] * B
        kv = self.wkv(x)
        gate = self.wgate(x)
        ready_kv, ready_gate, pool_base = pool_cache.accumulate_windows(kv, gate, offset)
        if ready_kv.size == 0:
            new_pooled = mx.zeros((B, 0, self.head_dim), dtype=x.dtype)
        else:
            R = self.compress_ratio
            kvw = mx.unflatten(ready_kv, 1, (-1, R))
            gw = mx.unflatten(ready_gate, 1, (-1, R))
            if batch:
                counts = [
                    (p - r) // R - n
                    for p, r, n in zip(pool_cache._processed, pool_cache.remainder, pool_cache._pool_lengths)
                ]
            else:
                counts = [kvw.shape[1]] * B
            rows = _rows(pool_cache, B)
            zero_kv = mx.zeros(kvw.shape[2:], dtype=kvw.dtype)
            none_gate = mx.full(gw.shape[2:], -mx.inf, dtype=gw.dtype)
            prev_kv, prev_gate = [], []
            for i in range(B):
                if starts[i] == 0 or counts[i] == 0:
                    prev_kv.append(zero_kv)
                    prev_gate.append(none_gate)
                    continue
                entry = rows[i].get(starts[i] - 1)
                if entry is None:
                    raise RuntimeError(f"overlap carry: row {i} lacks window {starts[i] - 1}")
                prev_kv.append(entry[0])
                prev_gate.append(entry[1])
            new_pooled = _overlap_with_carry(kvw, gw, self.ape, mx.stack(prev_kv), mx.stack(prev_gate))
            for i in range(B):
                last = starts[i] + counts[i]
                for j in range(max(0, counts[i] - HISTORY), counts[i]):
                    rows[i][starts[i] + j] = (mx.contiguous(kvw[i, j]), mx.contiguous(gw[i, j]))
                for key in [k for k in rows[i] if k < last - HISTORY]:
                    del rows[i][key]
            new_pooled = self.norm(new_pooled)
            new_pooled = self.rope(new_pooled[:, None], offset=pool_base).squeeze(1)
        return pool_cache.update_and_fetch(new_pooled)

    L.Compressor.__call__ = compressor_call

    # Row bookkeeping follows the batch cache's own row operations.
    original_filter = C.BatchPoolingCache.filter
    original_extend = C.BatchPoolingCache.extend
    original_extract = C.BatchPoolingCache.extract
    original_merge = C.BatchPoolingCache.merge.__func__

    def carry_of(cache, n):
        rows = getattr(cache, CARRY, None)
        return [dict(r) for r in rows] if rows is not None and len(rows) == n else [{} for _ in range(n)]

    def filter_rows(self, batch_indices):
        keep = batch_indices.tolist() if isinstance(batch_indices, mx.array) else list(batch_indices)
        rows = carry_of(self, len(self.remainder))
        original_filter(self, batch_indices)
        setattr(self, CARRY, [rows[i] for i in keep])

    def extend_rows(self, other):
        rows = carry_of(self, len(self.remainder)) + carry_of(other, len(other.remainder))
        original_extend(self, other)
        setattr(self, CARRY, rows)

    def extract_row(self, idx):
        row = carry_of(self, len(self.remainder))[idx]
        cache = original_extract(self, idx)
        setattr(cache, CARRY, [row])
        return cache

    def merge_rows(cls, caches, prefix_lens=None):
        merged = original_merge(cls, caches, prefix_lens)
        setattr(merged, CARRY, [carry_of(c, 1)[0] for c in caches])
        return merged

    C.BatchPoolingCache.filter = filter_rows
    C.BatchPoolingCache.extend = extend_rows
    C.BatchPoolingCache.extract = extract_row
    C.BatchPoolingCache.merge = classmethod(merge_rows)

    original_gate = L.MoEGate.__call__

    def gate_call(self, x, input_ids=None):
        if self.weight.dtype == mx.float32 and x.dtype != mx.float32:
            x = x.astype(mx.float32)
        return original_gate(self, x, input_ids)

    L.MoEGate.__call__ = gate_call
    L.Compressor._dsv4_fidelity = True
    return L, C


def apply(model):
    """Patch the classes once and fix this target's modules; returns counts."""
    L, _ = _install()
    lm = getattr(model, "language_model", model)
    gates = overlap = indexers = 0
    for _, module in lm.named_modules():
        if isinstance(module, L.MoEGate):
            if module.weight.dtype not in (mx.bfloat16, mx.float16, mx.float32):
                raise RuntimeError(f"router weight dtype {module.weight.dtype} is not a float")
            module.weight = module.weight.astype(mx.float32)
            gates += 1
        elif isinstance(module, L.Compressor) and module.overlap:
            overlap += 1
        elif isinstance(module, L.Indexer):
            module.index_block = 0
            module.index_keep = 0
            indexers += 1
    mx.eval(lm.parameters())
    return {"router_gates_float32": gates, "overlap_compressors_carried": overlap, "indexers_exact_topk": indexers}


def _selftest():
    """Chunking invariance of the carried overlap on a tiny compressor."""
    from types import SimpleNamespace

    L, C = _install()
    mx.random.seed(0)
    cfg = SimpleNamespace(qk_rope_head_dim=8, compress_rope_theta=160000.0, rope_scaling=None,
                          max_position_embeddings=4096, hidden_size=32, rms_norm_eps=1e-6)
    comp = L.Compressor(cfg, 4, 16)
    comp.update(__import__("mlx.utils", fromlist=["tree_map"]).tree_map(
        lambda p: mx.random.normal(p.shape).astype(mx.float32) * 0.2, comp.parameters()))
    x = mx.random.normal((1, 43, 32))

    def run(plan):
        cache, pos = C.PoolingCache(4), 0
        for n in plan:
            out = comp(x[:, pos:pos + n], cache, pos)
            pos += n
        return out

    # 1-token projections round differently from 43-token ones (~2e-4 here);
    # a lost overlap half is O(1).
    tol = 2e-3
    whole = run([43])
    for plan in ([16, 16, 11], [1] * 43, [5, 7, 1, 1, 13, 16]):
        other = run(plan)
        assert other.shape == whole.shape and mx.allclose(other, whole, atol=tol).item(), plan
    patched = L.Compressor.__call__
    L.Compressor.__call__ = original_compressor_call
    try:
        unpatched = run([1] * 43)
    finally:
        L.Compressor.__call__ = patched
    assert not mx.allclose(unpatched, whole, atol=tol).item(), "the contrast run did not show the lost overlap"

    # Batch cache, ragged rows, then a speculative round that keeps 2 of 5.
    xs = mx.random.normal((2, 40, 32))

    def batch_run(spec_keep=None):
        cache = C.BatchPoolingCache(4, [0, 0])
        comp(xs[:, :30], cache, 0)
        if spec_keep is None:
            for t in range(30, 40):
                out = comp(xs[:, t:t + 1], cache, t)
            return out, cache
        gen = cache.start_speculation(5)
        for t in range(30, 35):
            comp(xs[:, t:t + 1], cache, t)
        cache.commit_speculation([spec_keep, spec_keep], gen)
        for t in range(30 + spec_keep, 40):
            out = comp(xs[:, t:t + 1], cache, t)
        return out, cache

    ref, ref_cache = batch_run()
    for keep in (0, 1, 2, 5):
        out, cache = batch_run(keep)
        assert cache._pool_lengths == ref_cache._pool_lengths, keep
        assert mx.allclose(out, ref, atol=tol).item(), keep
    single = []
    for i in range(2):
        c1, pos = C.PoolingCache(4), 0
        for n in (30, 10):
            o = comp(xs[i:i + 1, pos:pos + n], c1, pos)
            pos += n
        single.append(o)
    assert mx.allclose(mx.concatenate(single, axis=0), ref, atol=tol).item()
    print("dsv4_vlm_fidelity selftest: carried overlap is chunking- and speculation-invariant")


if __name__ == "__main__":
    import sys

    if sys.argv[1:] == ["--selftest"]:
        _selftest()
    elif sys.argv[1:] == ["--verify-sources"]:
        import json

        print(json.dumps(verify_sources()))
    else:
        sys.exit(__doc__)
