#!/usr/bin/env python3

import importlib.util
import sys
import unittest
import urllib.parse
from decimal import Decimal
from pathlib import Path

REPO = Path(__file__).resolve().parents[2]
SCRIPT = REPO / "scripts" / "openrouter_mlx_candidates.py"
sys.path.insert(0, str(REPO / "scripts"))
SPEC = importlib.util.spec_from_file_location("openrouter_mlx_candidates", SCRIPT)
mlx = importlib.util.module_from_spec(SPEC)
assert SPEC.loader is not None
SPEC.loader.exec_module(mlx)

GB = 10 ** 9


def detail(size_gb, pipeline_tag=None, architectures=None, drop_size=False):
    sibling = {"rfilename": "model.safetensors"}
    if not drop_size:
        sibling["size"] = int(size_gb * GB)
    out = {"siblings": [sibling, {"rfilename": "config.json"}], "pipeline_tag": pipeline_tag}
    if architectures is not None:
        out["config"] = {"architectures": architectures}
    return out


class FakeHF:
    """Deterministic offline stand-in for the HuggingFace models API."""

    def __init__(self, searches, details, raise_on=frozenset()):
        self.searches = searches
        self.details = details
        self.raise_on = raise_on
        self.calls = []

    def __call__(self, url):
        self.calls.append(url)
        parsed = urllib.parse.urlparse(url)
        if any(token in url for token in self.raise_on):
            raise mlx.ResolveError("simulated HuggingFace failure")
        if parsed.path == "/api/models":  # search
            stem = urllib.parse.parse_qs(parsed.query).get("search", [""])[0]
            return self.searches.get(stem, [])
        repo = parsed.path.split("/api/models/", 1)[-1]  # detail
        if repo not in self.details:
            raise mlx.ResolveError(f"no detail fixture for {repo}")
        return self.details[repo]


def row(source_model_id, rank, completion):
    pricing = None if completion is None else {"completion_per_mtok": completion}
    return {"source_model_id": source_model_id, "demand": {"rank": rank, "total_token_volume": 1}, "pricing": pricing}


POLICY = {"policy_version": "test-v1", "models": [{"source_model_id": "openai/gpt-oss-20b"}]}


def build(rows, searches, details, raise_on=frozenset(), band="45"):
    snapshot = {"content_digest": "sha256:test", "rows": rows}
    client = FakeHF(searches, details, raise_on)
    result = mlx.build_candidates(snapshot, POLICY, Decimal(band), client)
    by_id = {c["source_model_id"]: c for c in result["candidates"]}
    return result, by_id, client


class MLXCandidateTests(unittest.TestCase):
    def test_vision_language_base_is_unresolved_and_picks_canonical_build(self):
        # gemma-4-31b: the canonical build is a VLM (image-text-to-text). It picks
        # the plain build (not the OptiQ recipe) but a vision pipeline is NOT
        # positive text evidence, so it is unresolved, not a review candidate.
        searches = {"gemma-4-31b-it": [
            {"modelId": "mlx-community/gemma-4-31b-it-4bit", "pipeline_tag": "image-text-to-text"},
            {"modelId": "mlx-community/gemma-4-31B-it-OptiQ-4bit", "pipeline_tag": "text-generation"},
        ]}
        details = {"mlx-community/gemma-4-31b-it-4bit": detail(18.4, "image-text-to-text")}
        _, by_id, _ = build([row("google/gemma-4-31b-it", 30, 0.34)], searches, details)
        c = by_id["google/gemma-4-31b-it"]
        self.assertEqual(c["verdict"], "unresolved")
        self.assertEqual(c["mlx_repo"], "mlx-community/gemma-4-31b-it-4bit")

    def test_adapter_config_repository_is_unresolved(self):
        # A repo carrying adapter_config.json is a PEFT/LoRA adapter, not a base model.
        searches = {"foo": [{"modelId": "mlx-community/foo-4bit", "pipeline_tag": "text-generation"}]}
        adapter = {"siblings": [
            {"rfilename": "model.safetensors", "size": int(0.2 * GB)},
            {"rfilename": "adapter_config.json"},
        ], "pipeline_tag": "text-generation"}
        _, by_id, _ = build([row("vendor/foo", 5, 1.0)], searches, {"mlx-community/foo-4bit": adapter})
        self.assertEqual(by_id["vendor/foo"]["verdict"], "unresolved")

    def test_vl_causal_arch_is_unresolved_under_text_pipeline(self):
        # Qwen2VLForCausalLM ends in ForCausalLM and has no name marker, but the
        # 'vlfor' compound pattern marks it multimodal -> unresolved even with a
        # text-generation pipeline tag.
        searches = {"qwen2-vl-7b": [{"modelId": "mlx-community/qwen2-vl-7b-4bit", "pipeline_tag": "text-generation"}]}
        details = {"mlx-community/qwen2-vl-7b-4bit": detail(5.0, "text-generation", ["Qwen2VLForCausalLM"])}
        _, by_id, _ = build([row("qwen/qwen2-vl-7b", 20, 1.0)], searches, details)
        self.assertEqual(by_id["qwen/qwen2-vl-7b"]["verdict"], "unresolved")

    def test_null_pipeline_causal_lm_is_review_not_servable(self):
        # A null-pipeline build confirmed only by a causal-LM config architecture
        # is downgraded to review -- heuristic metadata never yields clean servable.
        searches = {"mistral-nemo": [
            {"modelId": "mlx-community/Mistral-Nemo-Instruct-2407-4bit", "pipeline_tag": None},
            {"modelId": "mlx-community/Mistral-Nemo-Base-2407-4bit", "pipeline_tag": None},
            {"modelId": "mlx-community/Dolphin-2.9.3-Mistral-Nemo-12b-4bit", "pipeline_tag": None},
        ]}
        details = {"mlx-community/Mistral-Nemo-Instruct-2407-4bit": detail(7.0, None, ["MistralForCausalLM"])}
        _, by_id, _ = build([row("mistralai/mistral-nemo", 43, 0.03)], searches, details)
        c = by_id["mistralai/mistral-nemo"]
        self.assertEqual(c["verdict"], "review")
        # canonical: Instruct beats Base/Dolphin (Base penalised, Dolphin disqualified).
        self.assertEqual(c["mlx_repo"], "mlx-community/Mistral-Nemo-Instruct-2407-4bit")

    def test_multimodal_causal_lm_arch_is_unresolved(self):
        # LlavaLlamaForCausalLM ends in ForCausalLM but is a VLM: must not pass.
        searches = {"llava-next": [{"modelId": "mlx-community/llava-next-4bit", "pipeline_tag": None}]}
        details = {"mlx-community/llava-next-4bit": detail(8.0, None, ["LlavaLlamaForCausalLM"])}
        _, by_id, _ = build([row("vendor/llava-next", 20, 1.0)], searches, details)
        self.assertEqual(by_id["vendor/llava-next"]["verdict"], "unresolved")

    def test_boundary_collision_is_not_a_match(self):
        # stem 'foo-7b' must not match 'notfoo-7b-4bit'.
        searches = {"foo-7b": [{"modelId": "mlx-community/notfoo-7b-4bit", "pipeline_tag": "text-generation"}]}
        details = {"mlx-community/notfoo-7b-4bit": detail(4.0, "text-generation")}
        _, by_id, _ = build([row("vendor/foo-7b", 15, 1.0)], searches, details)
        self.assertEqual(by_id["vendor/foo-7b"]["verdict"], "not_servable")

    def test_wrong_namespace_is_not_selected(self):
        searches = {"foo-7b": [{"modelId": "attacker/foo-7b-4bit", "pipeline_tag": "text-generation"}]}
        details = {"attacker/foo-7b-4bit": detail(4.0, "text-generation")}
        _, by_id, _ = build([row("vendor/foo-7b", 15, 1.0)], searches, details)
        self.assertEqual(by_id["vendor/foo-7b"]["verdict"], "not_servable")

    def test_adapter_and_modified_only_repos_are_unresolved(self):
        # Only a LoRA/abliterated repo matches -> disqualified -> unresolved, not servable.
        searches = {"qwen3-8b": [{"modelId": "mlx-community/qwen3-8b-abliterated-lora-4bit", "pipeline_tag": "text-generation"}]}
        _, by_id, _ = build([row("vendor/qwen3-8b", 12, 1.0)], searches, {})
        self.assertEqual(by_id["vendor/qwen3-8b"]["verdict"], "unresolved")

    def test_adapter_only_checkpoint_fails_closed(self):
        searches = {"foo": [{"modelId": "mlx-community/foo-4bit", "pipeline_tag": "text-generation"}]}
        adapter_detail = {"siblings": [{"rfilename": "adapter_model.safetensors", "size": int(0.2 * GB)}], "pipeline_tag": "text-generation"}
        _, by_id, _ = build([row("vendor/foo", 5, 1.0)], searches, {"mlx-community/foo-4bit": adapter_detail})
        self.assertEqual(by_id["vendor/foo"]["verdict"], "unresolved")

    def test_list_valued_pipeline_tag_fails_closed(self):
        searches = {"foo": [{"modelId": "mlx-community/foo-4bit", "pipeline_tag": "4bit"}]}
        bad = {"siblings": [{"rfilename": "model.safetensors", "size": int(4 * GB)}], "pipeline_tag": ["text-generation"]}
        _, by_id, _ = build([row("vendor/foo", 5, 1.0)], searches, {"mlx-community/foo-4bit": bad})
        self.assertEqual(by_id["vendor/foo"]["verdict"], "unresolved")

    def test_residency_headroom_rejects_near_threshold_model(self):
        # 40 GB of weights x 1.3 headroom = 52 GB > 45 GB band -> not_servable.
        searches = {"big": [{"modelId": "mlx-community/big-4bit", "pipeline_tag": "text-generation"}]}
        details = {"mlx-community/big-4bit": detail(40.0, "text-generation")}
        _, by_id, _ = build([row("vendor/big", 6, 1.0)], searches, details)
        self.assertEqual(by_id["vendor/big"]["verdict"], "not_servable")

    def test_speech_model_is_not_servable(self):
        searches = {"mimo-v2.5": [{"modelId": "mlx-community/MiMo-V2.5-ASR-MLX-4bit", "pipeline_tag": "automatic-speech-recognition"}]}
        details = {"mlx-community/MiMo-V2.5-ASR-MLX-4bit": detail(5.0, "automatic-speech-recognition")}
        _, by_id, _ = build([row("xiaomi/mimo-v2.5", 1, 0.28)], searches, details)
        self.assertEqual(by_id["xiaomi/mimo-v2.5"]["verdict"], "not_servable")
        self.assertIn("not a text-generation serving path", by_id["xiaomi/mimo-v2.5"]["reasons"][0])

    def test_oversized_build_is_not_servable(self):
        searches = {"deepseek-v4-flash": [{"modelId": "mlx-community/DeepSeek-V4-Flash-4bit", "pipeline_tag": "text-generation"}]}
        details = {"mlx-community/DeepSeek-V4-Flash-4bit": detail(92.8, "text-generation", ["DeepseekV4ForCausalLM"])}
        _, by_id, _ = build([row("deepseek/deepseek-v4-flash", 2, 0.168)], searches, details)
        c = by_id["deepseek/deepseek-v4-flash"]
        self.assertEqual(c["verdict"], "not_servable")
        self.assertIn("exceeds", c["reasons"][0])

    def test_plain_text_build_within_band_is_review_candidate(self):
        searches = {"qwen3-8b": [{"modelId": "mlx-community/Qwen3-8B-4bit", "pipeline_tag": "text-generation"}]}
        details = {"mlx-community/Qwen3-8B-4bit": detail(4.5, "text-generation", ["Qwen3ForCausalLM"])}
        _, by_id, _ = build([row("qwen/qwen3-8b", 12, 0.2)], searches, details)
        self.assertEqual(by_id["qwen/qwen3-8b"]["verdict"], "review")

    def test_no_servable_verdict_or_bucket_exists(self):
        # The tool never certifies servability; there is no servable verdict/bucket.
        searches = {"qwen3-8b": [{"modelId": "mlx-community/Qwen3-8B-4bit", "pipeline_tag": "text-generation"}]}
        details = {"mlx-community/Qwen3-8B-4bit": detail(4.5, "text-generation", ["Qwen3ForCausalLM"])}
        result, _, _ = build([row("qwen/qwen3-8b", 12, 0.2)], searches, details)
        self.assertNotIn("servable", result)
        self.assertNotIn("servable", result["summary"])
        self.assertNotIn("servable", {c["verdict"] for c in result["candidates"]})

    def test_version_suffix_is_not_aliased(self):
        # 'glm-5' must not match 'glm-5.2-4bit' (a different version).
        searches = {"glm-5": [{"modelId": "mlx-community/glm-5.2-4bit", "pipeline_tag": "text-generation"}]}
        details = {"mlx-community/glm-5.2-4bit": detail(4.0, "text-generation")}
        _, by_id, _ = build([row("z-ai/glm-5", 5, 1.0)], searches, details)
        self.assertEqual(by_id["z-ai/glm-5"]["verdict"], "not_servable")

    def test_text_pipeline_non_causal_arch_is_unresolved(self):
        # text-generation tag but a seq2seq/conditional-generation arch -> cannot
        # positively confirm a causal-LM text-only path.
        searches = {"some-t5": [{"modelId": "mlx-community/some-t5-4bit", "pipeline_tag": "text-generation"}]}
        details = {"mlx-community/some-t5-4bit": detail(4.0, "text-generation", ["T5ForConditionalGeneration"])}
        _, by_id, _ = build([row("vendor/some-t5", 8, 1.0)], searches, details)
        self.assertEqual(by_id["vendor/some-t5"]["verdict"], "unresolved")

    def test_unknown_suffix_derivative_is_review(self):
        # 'foo-7b-math-4bit': 'math' is not recognised packaging -> variant -> review.
        searches = {"foo-7b": [{"modelId": "mlx-community/foo-7b-math-4bit", "pipeline_tag": "text-generation"}]}
        details = {"mlx-community/foo-7b-math-4bit": detail(4.0, "text-generation")}
        _, by_id, _ = build([row("vendor/foo-7b", 5, 1.0)], searches, details)
        self.assertEqual(by_id["vendor/foo-7b"]["verdict"], "review")
        self.assertIn("variant", by_id["vendor/foo-7b"]["reasons"][0])

    def test_no_mlx_build_is_not_servable(self):
        _, by_id, _ = build([row("openai/gpt-5.6-sol", 26, 15.0)], {}, {})
        c = by_id["openai/gpt-5.6-sol"]
        self.assertEqual(c["verdict"], "not_servable")
        self.assertIn("no mlx-community build", c["reasons"][0])

    def test_closed_vendor_is_not_servable_without_network(self):
        _, by_id, client = build([row("anthropic/claude-opus-5", 22, 25.0)], {}, {})
        self.assertEqual(by_id["anthropic/claude-opus-5"]["verdict"], "not_servable")
        self.assertEqual(client.calls, [])  # no HF probe for a closed house

    def test_build_without_recognised_quant_is_unresolved(self):
        searches = {"kimi-k3": [{"modelId": "mlx-community/Kimi-K3-bf16-DWQ", "pipeline_tag": None}]}
        _, by_id, _ = build([row("moonshotai/kimi-k3", 13, 14.0)], searches, {})
        self.assertEqual(by_id["moonshotai/kimi-k3"]["verdict"], "unresolved")
        self.assertIn("unrecognised-quant", by_id["moonshotai/kimi-k3"]["reasons"][0])

    def test_non_causal_config_without_pipeline_is_unresolved(self):
        searches = {"some-t5": [{"modelId": "mlx-community/some-t5-4bit", "pipeline_tag": None}]}
        details = {"mlx-community/some-t5-4bit": detail(5.0, None, ["T5ForConditionalGeneration"])}
        _, by_id, _ = build([row("vendor/some-t5", 40, 0.5)], searches, details)
        self.assertEqual(by_id["vendor/some-t5"]["verdict"], "unresolved")

    def test_network_failure_fails_closed_to_unresolved(self):
        searches = {"boom-model": [{"modelId": "mlx-community/boom-model-4bit", "pipeline_tag": "text-generation"}]}
        _, by_id, _ = build([row("vendor/boom-model", 5, 1.0)], searches, {}, raise_on={"boom-model"})
        self.assertEqual(by_id["vendor/boom-model"]["verdict"], "unresolved")
        self.assertIn("simulated HuggingFace failure", by_id["vendor/boom-model"]["reasons"][0])

    def test_missing_safetensors_size_fails_closed(self):
        searches = {"nosize": [{"modelId": "mlx-community/nosize-4bit", "pipeline_tag": "text-generation"}]}
        details = {"mlx-community/nosize-4bit": detail(0, "text-generation", ["LlamaForCausalLM"], drop_size=True)}
        _, by_id, _ = build([row("vendor/nosize", 8, 2.0)], searches, details)
        self.assertEqual(by_id["vendor/nosize"]["verdict"], "unresolved")
        self.assertIn("safetensors size", by_id["vendor/nosize"]["reasons"][0])

    def test_free_row_is_skipped_without_network(self):
        _, by_id, client = build([row("tencent/hy3", 4, None)], {}, {})
        self.assertEqual(by_id["tencent/hy3"]["verdict"], "skipped")
        self.assertEqual(client.calls, [])

    def test_policy_mapped_rows_are_excluded(self):
        result, by_id, _ = build([row("openai/gpt-oss-20b", 9, 0.1), row("vendor/x", 10, None)], {}, {})
        self.assertNotIn("openai/gpt-oss-20b", by_id)
        self.assertEqual(result["summary"]["probed"], 1)

    def test_review_candidates_ranked_by_payout_and_demand(self):
        searches = {
            "a-model": [{"modelId": "mlx-community/a-model-4bit", "pipeline_tag": "text-generation"}],
            "b-model": [{"modelId": "mlx-community/b-model-4bit", "pipeline_tag": "text-generation"}],
        }
        details = {
            "mlx-community/a-model-4bit": detail(5.0, "text-generation"),
            "mlx-community/b-model-4bit": detail(5.0, "text-generation"),
        }
        result, _, _ = build([row("v/a-model", 40, 0.10), row("v/b-model", 5, 1.00)], searches, details)
        self.assertEqual([c["source_model_id"] for c in result["review"]], ["v/b-model", "v/a-model"])

    def test_prefixed_different_model_is_not_matched(self):
        # 'glm-5' must not match 'other-glm-5-4bit' (a different, prefixed model).
        searches = {"glm-5": [{"modelId": "mlx-community/other-glm-5-4bit", "pipeline_tag": "text-generation"}]}
        details = {"mlx-community/other-glm-5-4bit": detail(4.0, "text-generation")}
        _, by_id, _ = build([row("z-ai/glm-5", 5, 1.0)], searches, details)
        self.assertEqual(by_id["z-ai/glm-5"]["verdict"], "not_servable")

    def test_suffix_boundary_prevents_wrong_size_match(self):
        # 'glm-5' must not match 'glm-50b-4bit'.
        searches = {"glm-5": [{"modelId": "mlx-community/glm-50b-4bit", "pipeline_tag": "text-generation"}]}
        details = {"mlx-community/glm-50b-4bit": detail(4.0, "text-generation")}
        _, by_id, _ = build([row("z-ai/glm-5", 5, 1.0)], searches, details)
        self.assertEqual(by_id["z-ai/glm-5"]["verdict"], "not_servable")

    def test_text_pipeline_with_multimodal_arch_is_unresolved(self):
        # A text-generation tag must not override a multimodal architecture.
        searches = {"foo": [{"modelId": "mlx-community/foo-4bit", "pipeline_tag": "text-generation"}]}
        details = {"mlx-community/foo-4bit": detail(4.0, "text-generation", ["LlavaLlamaForCausalLM"])}
        _, by_id, _ = build([row("vendor/foo", 5, 1.0)], searches, details)
        self.assertEqual(by_id["vendor/foo"]["verdict"], "unresolved")

    def test_variant_only_build_is_review_not_servable(self):
        # If the only anchored build is a coder/distilled/base derivative, it is a
        # different model -> review, never a clean canonical servable.
        searches = {"foo-7b": [{"modelId": "mlx-community/foo-7b-coder-4bit", "pipeline_tag": "text-generation"}]}
        details = {"mlx-community/foo-7b-coder-4bit": detail(4.0, "text-generation")}
        _, by_id, _ = build([row("vendor/foo-7b", 5, 1.0)], searches, details)
        self.assertEqual(by_id["vendor/foo-7b"]["verdict"], "review")

    def test_plain_build_preferred_over_variant(self):
        searches = {"foo-7b": [
            {"modelId": "mlx-community/foo-7b-coder-4bit", "pipeline_tag": "text-generation"},
            {"modelId": "mlx-community/foo-7b-4bit", "pipeline_tag": "text-generation"},
        ]}
        details = {
            "mlx-community/foo-7b-coder-4bit": detail(4.0, "text-generation"),
            "mlx-community/foo-7b-4bit": detail(4.0, "text-generation"),
        }
        _, by_id, _ = build([row("vendor/foo-7b", 5, 1.0)], searches, details)
        c = by_id["vendor/foo-7b"]
        self.assertEqual(c["verdict"], "review")
        self.assertEqual(c["mlx_repo"], "mlx-community/foo-7b-4bit")
        # the plain build's reason does not carry the variant caveat
        self.assertNotIn("variant", c["reasons"][0])

    def test_quant_tag_matches_only_whole_tokens(self):
        # 'foo-14bit' / 'foo-4bitten' are not '4bit' builds -> no usable build.
        searches = {"foo": [
            {"modelId": "mlx-community/foo-14bit", "pipeline_tag": "text-generation"},
            {"modelId": "mlx-community/foo-4bitten", "pipeline_tag": "text-generation"},
        ]}
        _, by_id, _ = build([row("vendor/foo", 5, 1.0)], searches, {})
        self.assertEqual(by_id["vendor/foo"]["verdict"], "unresolved")

    def test_validated_residency_rejects_non_finite_and_non_positive(self):
        for bad in ("Infinity", "-Infinity", "NaN", "0", "-5", "not-a-number"):
            with self.assertRaises(SystemExit):
                mlx.validated_residency(bad)
        self.assertEqual(mlx.validated_residency("45"), Decimal("45"))

    def test_output_guard_rejects_rate_card_variants(self):
        from pathlib import Path
        for name in ("rate-card.json", "Rate-Card.json", "rate_card.json"):
            self.assertTrue(mlx.is_protected_component(Path("/tmp") / name))
        self.assertTrue(mlx.is_protected_component(Path("/repo/rate-card/out.json")))
        self.assertFalse(mlx.is_protected_component(Path("/tmp/candidates.json")))

    def test_render_is_stable_and_lists_buckets(self):
        searches = {"z": [{"modelId": "mlx-community/z-4bit", "pipeline_tag": "text-generation"}]}
        details = {"mlx-community/z-4bit": detail(5.0, "text-generation")}
        result, _, _ = build([row("v/z", 3, 1.0), row("anthropic/claude-x", 1, 9.0)], searches, details)
        text = mlx.render(result)
        self.assertEqual(text, mlx.render(result))  # deterministic
        self.assertIn("REVIEW", text)
        self.assertIn("audit trail", text)


if __name__ == "__main__":
    unittest.main()
