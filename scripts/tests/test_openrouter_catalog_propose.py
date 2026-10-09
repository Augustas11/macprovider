#!/usr/bin/env python3
"""Unit tests for the `propose` mode (best-in-class servable catalog proposal).

These cover the pure gating/tiering/ranking core and its helpers; the network
stage (OpenRouter endpoints + HF servability) is exercised via injected records,
so no live calls are made.
"""

import contextlib
import io
import json
import sys
import tempfile
import unittest
from datetime import datetime, timezone
from decimal import Decimal
from pathlib import Path
from unittest.mock import patch

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
    def test_sums_text_generation_request_count_only(self):
        # Non-text workloads (tool_use) must NOT count toward the text demand
        # gauge: 100 + 20 text requests = 120, ignoring the 5 tool_use requests.
        doc = {"data": {"endpoints": [
            {"perf_last_30m_by_workload": {"text_generation": {"request_count": 100}, "tool_use": {"request_count": 5}}},
            {"perf_last_30m_by_workload": {"text_generation": {"request_count": 20}}},
        ]}}
        self.assertEqual(engine.model_demand_activity(doc), 120)

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


class CatalogFetchHealthTests(unittest.TestCase):
    model = "z-ai/glm-4.5-air"

    def endpoint(self, provider, count=300):
        row = {"provider_name": provider, "status": 0,
               "pricing": {"prompt": "0.00000015", "completion": "0.00000085"},
               "native_tools": {}, "supports_image_reference": False,
               "supports_multiple_audio_references": False}
        if count is not None:
            row["perf_last_30m_by_workload"] = {"text_generation": {"request_count": count}}
        return row

    def fetch(self, endpoints=None, status=200, clock=None):
        document = {"data": {"id": self.model, "endpoints": endpoints or []}}

        class Client:
            def get(self, url, timeout_seconds):
                return engine.HTTPResponse(status, json.dumps(document).encode(), {})

        kwargs = {"clock": clock} if clock else {}
        return engine.fetch_catalog_records(
            [self.model], {**policy(), "min_endpoint_request_count_30m": 30, "min_distinct_providers": 2},
            or_client=Client(), servability_resolver=lambda *args: servable("78.2"),
            retries=0, **kwargs,
        )

    def test_documented_metadata_allows_paid_liquid_model_to_be_selected(self):
        records = self.fetch([self.endpoint("A"), self.endpoint("B")])
        self.assertEqual(len(propose(records)["selected"]), 1)
        self.assertNotIn("probe_error", records[0])

    def test_schema_and_http_errors_survive_into_exclusion(self):
        row = self.endpoint("A")
        row["unknown_future_field"] = True
        for records, expected in [(self.fetch([row]), "unexpected fields"),
                                  (self.fetch(status=401), "HTTP 401")]:
            self.assertIn(expected, propose(records)["excluded"][0]["reason"])
            self.assertIn("probe_error", records[0])

    def test_absent_and_null_text_telemetry_are_probe_failures(self):
        for null_perf in [False, True]:
            rows = [self.endpoint("A", None), self.endpoint("B", None)]
            if null_perf:
                for row in rows:
                    row["perf_last_30m_by_workload"] = None
            records = self.fetch(rows)
            reason = propose(records)["excluded"][0]["reason"]
            self.assertIn("telemetry unavailable for 2/2", reason)
            self.assertNotIn("no active priced", reason)

    def test_empty_zero_activity_and_quorum_have_distinct_reasons(self):
        for rows, expected in [([], "no provider endpoints"),
                               ([self.endpoint("A", 0), self.endpoint("B", 0)], "text activity floor"),
                               ([self.endpoint("A")], "provider quorum 1 below required 2")]:
            records = self.fetch(rows)
            self.assertIn(expected, propose(records)["excluded"][0]["reason"])
            self.assertNotIn("probe_error", records[0])

    def test_missing_activity_cannot_replace_provider_quorum(self):
        records = self.fetch([self.endpoint("A"), self.endpoint("B", None)])
        self.assertIn("telemetry unavailable for 1/2", records[0]["probe_error"])

    def test_scan_budget_error_is_preserved(self):
        ticks = iter([0, 1801])
        records = self.fetch(clock=lambda: next(ticks))
        self.assertIn("scan budget exhausted", propose(records)["excluded"][0]["reason"])

    def test_command_retains_diagnostics_and_fails_empty_or_partial_scans(self):
        good = record(self.model, pricing_dict=pricing("0.85"), servability=servable("78.2"))
        bad = record("qwen/qwen3-32b", pricing_dict=None, servability={})
        bad["probe_error"] = "OpenRouter endpoint pricing failed: HTTP 401"
        legitimate_exclusion = record(self.model, pricing_dict=pricing("0.10"), servability=servable("78.2"))
        for records, expected in [([good], 0), ([bad], 1), ([good, bad], 1), ([legitimate_exclusion], 1)]:
            with self.subTest(expected=expected, records=len(records)), tempfile.TemporaryDirectory() as tmp:
                output = Path(tmp) / "out"
                args = engine.parser().parse_args(["propose", "--output-dir", str(output)])
                stderr = io.StringIO()
                with patch.dict("os.environ", {"OPENROUTER_API_KEY": "test-key"}), \
                     patch.object(engine, "fetch_json", return_value={"data": [{"id": self.model}]}), \
                     patch.object(engine, "fetch_catalog_records", return_value=records), \
                     contextlib.redirect_stdout(io.StringIO()), contextlib.redirect_stderr(stderr):
                    self.assertEqual(engine.command_propose(args), expected)
                artifacts = list(output.glob("openrouter-catalog-proposal-*.json"))
                self.assertEqual(len(artifacts), 1)
                artifact = json.loads(artifacts[0].read_text())
                engine.validate_catalog_proposal(artifact)
                if expected:
                    self.assertIn("catalog proposal unhealthy", stderr.getvalue())
                if any(r.get("probe_error") for r in records):
                    self.assertIn("HTTP 401", stderr.getvalue())


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
                     servability={"verdict": "unresolved", "pipeline_tag": "image-text-to-text", "serving_class": "multimodal_text",
                                  "required_gb": "20.0", "mlx_repo": "mlx-community/Qwen3.6-35B-A3B-4bit",
                                  "quant": "4bit", "reasons": ["multimodal LLM (pipeline_tag 'image-text-to-text') served for text via mlx-vlm; confirm the mlx-vlm text path before pricing"]})
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
                   servability={"verdict": "unresolved", "pipeline_tag": "image-text-to-text", "serving_class": "multimodal_text",
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

    def test_validator_rejects_non_finite_or_negative_values(self):
        out = propose([record("z-ai/glm-4.5-air", pricing_dict=pricing("0.85"), servability=servable("78.2"))])
        for field, bad in (("required_residency_gb", "NaN"), ("proposed_input_per_mtok", "Infinity"),
                           ("market_completion_per_mtok", "-1")):
            proposal = dict(out)
            row = dict(out["selected"][0])
            row[field] = bad
            proposal["selected"] = [row]
            with self.assertRaises(engine.SchemaError):
                engine.validate_catalog_proposal(proposal)

    def test_validator_rejects_negative_counts(self):
        out = propose([record("z-ai/glm-4.5-air", pricing_dict=pricing("0.85"), servability=servable("78.2"))])
        row = dict(out["selected"][0]); row["demand_request_count_30m"] = -1
        out["selected"] = [row]
        with self.assertRaises(engine.SchemaError):
            engine.validate_catalog_proposal(out)

    def test_validator_requires_manual_verification_flag_for_vl_rows(self):
        out = propose([record("qwen/qwen3.6-35b-a3b", pricing_dict=pricing("1.00"),
                              servability={"verdict": "unresolved", "pipeline_tag": "image-text-to-text", "serving_class": "multimodal_text",
                                           "required_gb": "20.0", "mlx_repo": "r", "quant": "4bit", "reasons": ["vl"]})])
        out["selected"][0]["manual_serving_verification_required"] = False
        with self.assertRaisesRegex(engine.SchemaError, "manual serving verification"):
            engine.validate_catalog_proposal(out)


if __name__ == "__main__":
    unittest.main()
