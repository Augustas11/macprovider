#!/usr/bin/env python3
"""Unit tests for the `propose` mode (best-in-class servable catalog proposal).

These cover the pure gating/tiering/ranking core and its helpers; the network
stage (OpenRouter endpoints + HF servability) is exercised via injected records,
so no live calls are made.
"""

import sys
import unittest
from datetime import datetime, timezone
from decimal import Decimal
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
SCRIPTS = ROOT / "scripts"
if str(SCRIPTS) not in sys.path:
    sys.path.insert(0, str(SCRIPTS))

import openrouter_pricing_engine as engine  # noqa: E402

NOW = datetime(2026, 9, 18, 12, 0, 0, tzinfo=timezone.utc)


def policy(undercut="0.20"):
    return {"policy_version": "unit-test-v1", "undercut_fraction": undercut}


def pricing(completion, prompt="0.10", provider="Prov"):
    return {
        "input_per_token": "0",
        "completion_per_token": "0",
        "input_per_mtok": prompt,
        "completion_per_mtok": completion,
        "currency": "USD",
        "benchmark_provider": provider,
        "liquidity_filter": {},
    }


def servable(required_gb, repo="mlx-community/Repo-4bit", quant="4bit"):
    return {"verdict": "review", "required_gb": str(required_gb), "mlx_repo": repo, "quant": quant,
            "reasons": ["mlx-community text-generation build fits the fleet residency band"]}


def record(model_id, *, pricing_dict, servability, demand=10_000, endpoints=3):
    return {"model_id": model_id, "pricing": pricing_dict, "servability": servability,
            "demand_request_count_30m": demand, "endpoint_count": endpoints}


def propose(records, *, yield_floor="0.30", demand_floor=500, undercut="0.20"):
    return engine.build_catalog_proposal(
        records, policy(undercut), now=NOW,
        yield_floor_completion_per_mtok=Decimal(yield_floor),
        demand_floor_request_count_30m=demand_floor,
    )


class AssignRamTierTests(unittest.TestCase):
    def test_smallest_tier_leaving_safety_margin(self):
        # 32GB tier usable = 32 - 4 = 28GB.
        self.assertEqual(engine.assign_ram_tier(Decimal("22.3")), 32)
        self.assertEqual(engine.assign_ram_tier(Decimal("28.0")), 32)
        self.assertEqual(engine.assign_ram_tier(Decimal("28.1")), 48)  # 48-4=44
        self.assertEqual(engine.assign_ram_tier(Decimal("85.5")), 96)  # 64-4=60 no, 96-4=92 yes
        self.assertEqual(engine.assign_ram_tier(Decimal("60.0")), 64)

    def test_exceeds_largest_tier_returns_none(self):
        self.assertIsNone(engine.assign_ram_tier(Decimal("253")))  # 256-4=252


class ModelDemandActivityTests(unittest.TestCase):
    def test_sums_request_count_across_endpoints_and_workloads(self):
        doc = {"data": {"endpoints": [
            {"perf_last_30m_by_workload": {"text_generation": {"request_count": 100}, "tool_use": {"request_count": 5}}},
            {"perf_last_30m_by_workload": {"text_generation": {"request_count": 20}}},
        ]}}
        self.assertEqual(engine.model_demand_activity(doc), 125)

    def test_lenient_on_missing_or_malformed_telemetry(self):
        doc = {"data": {"endpoints": [
            {"perf_last_30m_by_workload": {"text_generation": {"request_count": 7}}},
            {"perf_last_30m_by_workload": {"text_generation": {"request_count": None}}},
            {"perf_last_30m_by_workload": "bad"},
            {"no_perf": True},
            "not-an-endpoint",
        ]}}
        self.assertEqual(engine.model_demand_activity(doc), 7)

    def test_no_endpoints_is_zero(self):
        self.assertEqual(engine.model_demand_activity({"data": {}}), 0)
        self.assertEqual(engine.model_demand_activity({}), 0)


class SelectOpenWeightCandidatesTests(unittest.TestCase):
    def test_keeps_open_weight_excludes_closed_and_free_and_variants(self):
        ids = [
            "qwen/qwen3-30b-a3b-instruct-2507",
            "z-ai/glm-4.5-air",
            "anthropic/claude-opus-5",       # closed vendor
            "google/gemini-3-flash",         # closed marker
            "openai/gpt-5.6-luna",           # openai non-gpt-oss
            "openai/gpt-oss-120b",           # openai gpt-oss kept
            "qwen/qwen3.8-27b:free",         # free variant
            "qwen/qwen3.5-9b:batch",         # non-free variant suffix
            "x-ai/grok-4.6",                 # closed marker
            "randomvendor/foo",              # unknown vendor
        ]
        kept = engine.select_open_weight_candidates(ids)
        self.assertEqual(kept, ["openai/gpt-oss-120b", "qwen/qwen3-30b-a3b-instruct-2507", "z-ai/glm-4.5-air"])


class BuildCatalogProposalTests(unittest.TestCase):
    def test_selected_row_has_undercut_price_and_tier(self):
        rec = record("z-ai/glm-4.5-air", pricing_dict=pricing("0.85", "0.15"), servability=servable("78.2"), demand=2874)
        out = propose([rec])
        self.assertEqual(out["proposal_type"], "openrouter-catalog-proposal")
        self.assertEqual(len(out["selected"]), 1)
        row = out["selected"][0]
        self.assertEqual(row["min_ram_gb_tier"], 96)
        self.assertEqual(row["market_completion_per_mtok"], "0.85")
        self.assertEqual(row["proposed_completion_per_mtok"], "0.68")   # 0.85 * 0.80
        self.assertEqual(row["proposed_input_per_mtok"], "0.12")        # 0.15 * 0.80
        self.assertEqual(row["demand_request_count_30m"], 2874)
        self.assertEqual(out["selection"]["liquidity_signal"], "openrouter_request_count_last_30m")

    def test_below_yield_floor_is_excluded(self):
        rec = record("openai/gpt-oss-20b", pricing_dict=pricing("0.13"), servability=servable("11.0"))
        out = propose([rec], yield_floor="0.30")
        self.assertEqual(out["selected"], [])
        self.assertEqual(len(out["excluded"]), 1)
        self.assertIn("below floor", out["excluded"][0]["reason"])

    def test_below_demand_floor_is_excluded(self):
        rec = record("z-ai/glm-4.5-air", pricing_dict=pricing("0.85"), servability=servable("78.2"), demand=10)
        out = propose([rec], demand_floor=500)
        self.assertEqual(out["selected"], [])
        self.assertIn("below floor", out["excluded"][0]["reason"])

    def test_vision_language_model_is_included_as_text_serving(self):
        # Qwen3-VL / Gemma-3 families are tagged image-text-to-text but are served
        # for text and are top-yield earners -- they must NOT be dropped.
        rec = record("qwen/qwen3.6-35b-a3b", pricing_dict=pricing("1.00"),
                     servability={"verdict": "unresolved", "pipeline_tag": "image-text-to-text",
                                  "required_gb": "20.0", "mlx_repo": "mlx-community/Qwen3.6-35B-A3B-4bit",
                                  "quant": "4bit", "reasons": ["pipeline_tag 'image-text-to-text' is a vision-language pipeline"]})
        out = propose([rec])
        self.assertEqual(len(out["selected"]), 1)
        row = out["selected"][0]
        self.assertEqual(row["serving_path"], "vision_language_text")
        self.assertEqual(row["min_ram_gb_tier"], 32)
        self.assertIn("served for text via mlx-vlm", row["servability_note"])

    def test_conditional_generation_multimodal_text_is_included(self):
        # Mistral3ForConditionalGeneration (Mistral-Small VL family) has no
        # pipeline_tag; the resolver marks it serving_class=multimodal_text. It is
        # a top-demand model served for text and must be included, not dropped.
        rec = record("mistralai/mistral-small-2603", pricing_dict=pricing("0.60"),
                     servability={"verdict": "unresolved", "pipeline_tag": None,
                                  "serving_class": "multimodal_text", "required_gb": "88.1",
                                  "mlx_repo": "mlx-community/Mistral-Small-4-119B-2603-4bit", "quant": "4bit",
                                  "reasons": ["conditional-generation multimodal LLM served for text"]},
                     demand=22307)
        out = propose([rec])
        self.assertEqual(len(out["selected"]), 1)
        self.assertEqual(out["selected"][0]["serving_path"], "vision_language_text")
        self.assertEqual(out["selected"][0]["min_ram_gb_tier"], 96)

    def test_non_vision_unresolved_is_still_excluded(self):
        # An unresolved verdict for a non-vision reason (no confirmed text path)
        # stays excluded -- only vision-language pipelines are included as text.
        rec = record("some/model", pricing_dict=pricing("1.00"),
                     servability={"verdict": "unresolved", "pipeline_tag": None, "required_gb": "20.0",
                                  "reasons": ["no pipeline_tag and no causal-LM architecture in config"]})
        out = propose([rec])
        self.assertEqual(out["selected"], [])
        self.assertIn("not servable (unresolved)", out["excluded"][0]["reason"])

    def test_text_verdict_has_text_serving_path(self):
        rec = record("z-ai/glm-4.5-air", pricing_dict=pricing("0.85"), servability=servable("78.2"))
        out = propose([rec])
        self.assertEqual(out["selected"][0]["serving_path"], "text")

    def test_residency_exceeding_largest_tier_is_excluded(self):
        rec = record("huge/model", pricing_dict=pricing("1.00"), servability=servable("300"))
        out = propose([rec])
        self.assertEqual(out["selected"], [])
        self.assertIn("exceeds largest tier", out["excluded"][0]["reason"])

    def test_missing_pricing_is_excluded(self):
        rec = record("no/price", pricing_dict=None, servability=servable("20"))
        out = propose([rec])
        self.assertEqual(out["selected"], [])
        self.assertIn("no active priced", out["excluded"][0]["reason"])

    def test_ranked_by_tier_then_yield_desc(self):
        recs = [
            record("a/big-lowyield", pricing_dict=pricing("0.40"), servability=servable("78")),   # 96G
            record("b/small-hi", pricing_dict=pricing("2.20"), servability=servable("20")),        # 32G
            record("c/small-lo", pricing_dict=pricing("0.50"), servability=servable("22")),        # 32G
        ]
        out = propose(recs)
        order = [r["model_id"] for r in out["selected"]]
        # 32G tier first (higher yield within tier first), then 96G
        self.assertEqual(order, ["b/small-hi", "c/small-lo", "a/big-lowyield"])


class ValidateCatalogProposalTests(unittest.TestCase):
    def test_build_output_passes_the_validator(self):
        recs = [
            record("z-ai/glm-4.5-air", pricing_dict=pricing("0.85"), servability=servable("78.2")),
            record("qwen/qwen3.6-35b-a3b", pricing_dict=pricing("1.00"),
                   servability={"verdict": "unresolved", "pipeline_tag": "image-text-to-text",
                                "required_gb": "20.0", "mlx_repo": "mlx-community/Qwen3.6-35B-A3B-4bit",
                                "quant": "4bit", "reasons": ["vision-language"]}),
        ]
        out = propose(recs)
        engine.validate_catalog_proposal(out)  # must not raise

    def test_validator_rejects_unknown_top_level_field(self):
        out = propose([record("z-ai/glm-4.5-air", pricing_dict=pricing("0.85"), servability=servable("78.2"))])
        out["surprise"] = 1
        with self.assertRaisesRegex(engine.SchemaError, "top-level fields"):
            engine.validate_catalog_proposal(out)

    def test_validator_rejects_non_proposal_status(self):
        out = propose([record("z-ai/glm-4.5-air", pricing_dict=pricing("0.85"), servability=servable("78.2"))])
        out["status"] = "applied"
        with self.assertRaisesRegex(engine.SchemaError, "proposal_only_never_applied"):
            engine.validate_catalog_proposal(out)

    def test_validator_requires_manual_verification_flag_for_vl_rows(self):
        out = propose([record("qwen/qwen3.6-35b-a3b", pricing_dict=pricing("1.00"),
                              servability={"verdict": "unresolved", "pipeline_tag": "image-text-to-text",
                                           "required_gb": "20.0", "mlx_repo": "r", "quant": "4bit", "reasons": ["vl"]})])
        out["selected"][0]["manual_serving_verification_required"] = False
        with self.assertRaisesRegex(engine.SchemaError, "manual serving verification"):
            engine.validate_catalog_proposal(out)


if __name__ == "__main__":
    unittest.main()
