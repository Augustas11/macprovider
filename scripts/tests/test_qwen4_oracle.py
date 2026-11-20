"""scripts/lab/ablit-perf/qwen4_oracle.py: the loader parts.

The pure parts run anywhere. The load tests build a tiny mlx-lm qwen4_exp model
on the CPU and need mlx and mlx-lm (the job's pinned commit); they are skipped
without them.
"""
import importlib.util
import unittest
from pathlib import Path

ORACLE = Path(__file__).resolve().parents[1] / "lab" / "ablit-perf" / "qwen4_oracle.py"
spec = importlib.util.spec_from_file_location("qwen4_oracle", ORACLE)
oracle = importlib.util.module_from_spec(spec)
spec.loader.exec_module(oracle)

try:
    import mlx.core as mx
    import mlx.nn as nn
    from mlx_lm.models import qwen4_exp
    HAVE_MLX = True
except Exception:  # absent, or a broken install that fails on import
    HAVE_MLX = False


def hc_shapes(prefix, down_bits, inject_bits, down_group=64, inject_group=64, in_dims=10240, lowrank=320, hc=4):
    out = {}
    for name, rows, bits, group in (("input_mix_weight_down", lowrank, down_bits, down_group),
                                    ("block_inject_weight", hc, inject_bits, inject_group)):
        k = prefix + name
        out[k + ".weight"] = (rows, in_dims * bits // 32)
        out[k + ".scales"] = out[k + ".biases"] = (rows, in_dims // group)
    return out


class PureTests(unittest.TestCase):
    def test_mixed_merges_from_checkpoint_shapes(self):
        # Layer 16 of Qwen3.8-Flash-Next-heretic-2-oQ4e-mtp: down 4-bit (unlisted), inject 5-bit.
        L = "language_model.model.layers."
        shapes = {}
        shapes.update(hc_shapes(L + "16.attn_hyper_connection.", 4, 5))
        shapes.update(hc_shapes(L + "16.mlp_hyper_connection.", 4, 5))
        shapes.update(hc_shapes(L + "0.attn_hyper_connection.", 5, 5))
        shapes.update(hc_shapes(L + "1.attn_hyper_connection.", 4, 4, inject_group=32))  # group size only
        shapes.update(hc_shapes("mtp.layers.0.attn_hyper_connection.", 4, 8))  # dropped by sanitize
        self.assertEqual(oracle.mixed_merges(shapes), [L + "1.attn_hyper_connection.",
                                                       L + "16.attn_hyper_connection.",
                                                       L + "16.mlp_hyper_connection."])
        # The failing pair of the 2026-11-17 run: (320, 1280) and (4, 1600).
        self.assertEqual(shapes[L + "16.attn_hyper_connection.input_mix_weight_down.weight"], (320, 1280))
        self.assertEqual(shapes[L + "16.attn_hyper_connection.block_inject_weight.weight"], (4, 1600))

    def test_quant_key(self):
        k = oracle.quant_key
        self.assertEqual(k("lm_head"), "language_model.lm_head")
        self.assertEqual(k("model.layers.3.self_attn.q_proj"), "language_model.model.layers.3.self_attn.q_proj")
        self.assertEqual(k("model.layers.16.attn_hyper_connection.input_mix_weight_down.inject"),
                         "language_model.model.layers.16.attn_hyper_connection.block_inject_weight")
        self.assertEqual(k("model.layers.16.attn_hyper_connection.input_mix_weight_down.down"),
                         "language_model.model.layers.16.attn_hyper_connection.input_mix_weight_down")
        self.assertEqual(k("model.layers.1.ple.ple_embedding.ngram_embedding.7"),
                         "language_model.model.layers.1.ple.ple_embedding.ngram_embedding.shards.0")

    def test_quant_mismatches(self):
        q = {"bits": 4, "group_size": 64,
             "language_model.lm_head": {"bits": 8, "group_size": 64, "mode": "affine"}}
        self.assertEqual(oracle.quant_mismatches({"lm_head": (8, 64), "model.norm_free": (4, 64)}, q), [])
        self.assertEqual(oracle.quant_mismatches({"lm_head": (4, 64), "model.x": (5, 64)}, q),
                         [("lm_head", (4, 64), (8, 64)), ("model.x", (5, 64), (4, 64))])


TINY = {
    "model_type": "qwen4_exp_text", "vocab_size": 64, "hidden_size": 32,
    "num_hidden_layers": 4, "num_attention_heads": 2, "num_key_value_heads": 1,
    "head_dim": 16, "rms_norm_eps": 1e-6, "eos_token_id": 1,
    "rope_parameters": {"rope_theta": 10000, "partial_rotary_factor": 0.5, "type": "default"},
    "num_experts": 4, "num_experts_per_tok": 2, "moe_intermediate_size": 32,
    "shared_expert_intermediate_size": 32,
    "linear_num_key_heads": 2, "linear_num_value_heads": 2,
    "linear_key_head_dim": 32, "linear_value_head_dim": 16, "linear_conv_kernel_dim": 4,
    "hc_count": 2, "hc_lowrank": 8,
    "indexer_n_heads": 2, "indexer_kv_heads": 1, "indexer_head_dim": 16,
    "indexer_budget": 8, "indexer_compress_ratio": 2,
    "ngram_size": 3, "heads_per_ngram": 2, "ngram_vocab_size_base": 100,
    "ple_embed_dim": 8, "ple_layer_ids": [2],
    "layer_types": ["linear_attention", "linear_attention", "linear_attention", "full_attention"],
    "output_gate_type": "sigmoid", "hidden_act": "silu", "tie_word_embeddings": False,
}
GROUP = 32


@unittest.skipUnless(HAVE_MLX, "needs mlx and mlx-lm")
class LoadTests(unittest.TestCase):
    """A tiny qwen4_exp checkpoint in mlx-vlm layout (`language_model.*`, the block
    inject stored apart), quantized like the oQ build: every Linear whose input
    is a multiple of 32 at 4 bits, except the block injects of layer 2 at 8 bits
    and layer 3's mlp inject at group 64 (same 4 bits)."""

    def setUp(self):
        mx.set_default_device(mx.cpu)
        self.args = qwen4_exp.ModelArgs.from_dict({"model_type": "qwen4_exp", "text_config": TINY})
        float_model = qwen4_exp.Model(self.args)
        mx.random.seed(3)
        params = {}
        for k, v in nn.utils.tree_flatten(float_model.parameters()):
            params[k] = 1 + 0.1 * mx.random.normal(v.shape) if k.endswith("norm.weight") else 0.2 * mx.random.normal(v.shape)
        self.ckpt, self.ref, lowrank = {}, {}, self.args.text.hc_lowrank
        special = {"model.layers.2.attn_hyper_connection.": (8, GROUP), "model.layers.2.mlp_hyper_connection.": (8, GROUP),
                   "model.layers.3.mlp_hyper_connection.": (4, 64)}
        for k, v in params.items():
            mod, name = k.rsplit(".", 1)
            if name != "weight" or not isinstance(self._module(float_model, mod), nn.Linear) or v.shape[-1] % GROUP:
                self._store(k, v, v)
                continue
            if mod.endswith("input_mix_weight_down") and v.shape[0] > lowrank:
                p = mod[: -len("input_mix_weight_down")]
                inject_bits, inject_group = special.get(p, (4, GROUP))
                down = self._quant(p + "input_mix_weight_down", v[:lowrank], 4, GROUP)
                inject = self._quant(p + "block_inject_weight", v[lowrank:], inject_bits, inject_group)
                self.ref[k] = mx.concatenate([down, inject])
                continue
            self.ref[k] = self._quant(mod, v, 4, GROUP)
        self.float_model = float_model
        float_model.load_weights(list(self.ref.items()), strict=True)
        self.quantization = {"bits": 4, "group_size": GROUP, **{
            "language_model." + p + "block_inject_weight": {"bits": b, "group_size": g, "mode": "affine"}
            for p, (b, g) in special.items()}}

    @staticmethod
    def _module(model, path):
        m = model
        for part in path.split("."):
            m = m[int(part)] if part.isdigit() else getattr(m, part)
        return m

    def _store(self, key, ckpt_value, ref_value):
        self.ckpt["language_model." + key] = ckpt_value
        self.ref[key] = ref_value

    def _quant(self, mod, w, bits, group):
        wq, s, b = mx.quantize(w, group_size=group, bits=bits)
        for name, t in (("weight", wq), ("scales", s), ("biases", b)):
            self.ckpt[f"language_model.{mod}.{name}"] = t
        return mx.dequantize(wq, s, b, group_size=group, bits=bits)

    def fresh(self):
        return qwen4_exp.Model(self.args)

    def test_stock_sanitize_cannot_merge_mixed_parts(self):
        with self.assertRaisesRegex(ValueError, "concatenate"):
            self.fresh().sanitize(dict(self.ckpt))

    def test_split_load_matches_the_dequantized_float_model(self):
        model, info = oracle.prepare(self.fresh(), dict(self.ckpt), self.quantization)
        self.assertEqual(len(info["split"]), 3, info["split"])
        self.assertTrue(info["split"][0].startswith("layer 2 attn_hyper_connection: input_mix_weight_down (8, 8)"))
        hc = model.model.layers[2].attn_hyper_connection.input_mix_weight_down
        self.assertEqual((hc.down.bits, hc.inject.bits), (4, 8))
        self.assertEqual((model.model.layers[3].mlp_hyper_connection.input_mix_weight_down.inject.group_size), 64)
        # Same-width pairs stay merged as stock: one quantized matmul of lowrank + hc rows.
        merged = model.model.layers[0].attn_hyper_connection.input_mix_weight_down
        self.assertIsInstance(merged, nn.QuantizedLinear)
        self.assertEqual(merged.weight.shape[0], self.args.text.hc_lowrank + self.args.text.hc_count)

        ids = mx.array([[5, 63, 1, 7, 7, 12, 1, 1, 40, 3, 9, 22]])
        got, want = model(ids), self.float_model(ids)
        err = mx.abs(got - want).max().item()
        self.assertLess(err, 1e-3, err)

    def test_split_part_is_the_merged_rows(self):
        # The split layer's output equals the merged layer's rows when both parts share bits.
        x = mx.random.normal((3, 64))
        w = mx.random.normal((10, 64))
        merged = nn.QuantizedLinear.from_linear(self._linear(w), group_size=GROUP, bits=4)
        down = nn.QuantizedLinear.from_linear(self._linear(w[:8]), group_size=GROUP, bits=4)
        inject = nn.QuantizedLinear.from_linear(self._linear(w[8:]), group_size=GROUP, bits=4)
        self.assertTrue(mx.array_equal(merged(x), mx.concatenate([down(x), inject(x)], axis=-1)).item())

    @staticmethod
    def _linear(w):
        lin = nn.Linear(w.shape[1], w.shape[0], bias=False)
        lin.weight = w
        return lin

    def test_sanity_rows_feed_the_parity_grid_rule(self):
        import sys
        sys.path.insert(0, str(ORACLE.parents[1] / "parity-grid"))
        import sanity

        class Tok:  # no chat template; every token decodes to a letter and a newline
            def apply_chat_template(self, *a, **k):
                raise ValueError("no template")

            def encode(self, text, add_special_tokens=False):
                return [ord(c) % 64 for c in text]

            def decode(self, ids, skip_special_tokens=True):
                return "".join(chr(97 + t % 26) + "\n" for t in ids)

        model, _ = oracle.prepare(self.fresh(), dict(self.ckpt), self.quantization)
        rows = oracle.sanity_rows(model, Tok(), stop=set())
        self.assertEqual([r["completion_tokens"] for r in rows], [oracle.SANITY_MAX_TOKENS] * len(oracle.SANITY_PROMPTS))
        verdict = sanity.check_reference(rows)
        self.assertTrue(verdict["suspect"], verdict)
        self.assertIn("ctxsanity: 3/3 rows degenerate", verdict["reason"])
        # A stop token ends a row early; under 32 tokens it is not checkable, which is suspect too.
        first = oracle.greedy(model, Tok().encode(oracle.SANITY_PROMPTS[0]), 4)
        self.assertEqual(oracle.greedy(model, Tok().encode(oracle.SANITY_PROMPTS[0]), 4, stop={first[1]}), first[:1])

    def test_quantization_block_disagreement_fails_the_load(self):
        q = dict(self.quantization)
        q["language_model.model.layers.2.attn_hyper_connection.block_inject_weight"] = {"bits": 5, "group_size": GROUP}
        with self.assertRaisesRegex(ValueError, "disagree with the checkpoint quantization"):
            oracle.prepare(self.fresh(), dict(self.ckpt), q)


if __name__ == "__main__":
    unittest.main()
