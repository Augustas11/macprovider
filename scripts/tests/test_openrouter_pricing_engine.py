#!/usr/bin/env python3
"""Offline tests for the OpenRouter snapshot and proposal pipeline."""

from __future__ import annotations

import copy
import json
import sys
import tempfile
import unittest
from datetime import datetime, timezone
from pathlib import Path
from unittest.mock import patch

ROOT = Path(__file__).resolve().parents[2]
SCRIPTS = ROOT / "scripts"
if str(SCRIPTS) not in sys.path:
    sys.path.insert(0, str(SCRIPTS))

import openrouter_pricing_engine as engine  # noqa: E402


FIXTURES = Path(__file__).with_name("fixtures") / "openrouter_pricing"
NOW = datetime(2026, 8, 4, 12, 0, 0, tzinfo=timezone.utc)


def fixture(name: str):
    return json.loads((FIXTURES / name).read_text(encoding="utf-8"))


def policy():
    value = {
        "policy_version": "unit-test-v1",
        "demand_top_n": 50,
        "undercut_fraction": "0.20",
        "cache_hit_fraction": "0.25",
        "min_endpoint_request_count_30m": 1,
        "min_distinct_providers": 1,
        "models": [
            model("openai/gpt-oss-20b", "openai/gpt-oss-20b"),
            model("google/gemma-4-26b-a4b-it", "google-gemma-4-26b-a4b-it"),
            model("nvidia/nemotron-3-nano-30b-a3b", "nvidia/nemotron-3-nano-30b-a3b"),
            model("example/new-model", "example/new-model"),
            model("qwen/qwen2.5-coder-32b-instruct", "qwen2.5-coder-32b-instruct"),
        ],
    }
    return value


def model(source: str, canonical: str):
    return {
        "source_model_id": source,
        "canonical_model_id": canonical,
        "serving_path": {"verification_status": "verified", "reference": "https://example.test/mlx"},
        "license": {"commercial_permitted": True, "source_url": "https://example.test/license", "verification_note": "unit-test evidence"},
        "profile": {"kind": "broad_fleet", "active_params_b": "3", "residency_gb": "10", "projected_tps": "50"},
    }


def reference_rate_card():
    def row(completion):
        return {"prompt_rate_per_mtok": 50, "prompt_cache_hit_rate_per_mtok": 12, "completion_rate_per_mtok": completion, "provider_share_bps": 9000, "global_multiplier_ppm": 1000000}
    return {
        "version": "test",
        "policy_version": "test-policy",
        "generated_at": "2026-08-05T12:00:00Z",
        "usd_per_million_credits": 1.0,
        "rows": {
            "default": row(1000000),
            "openai/gpt-oss-20b": row(100000),
            "google-gemma-4-26b-a4b-it": row(240000),
            "nvidia/nemotron-3-nano-30b-a3b": row(160000),
            "qwen2.5-coder-32b-instruct": row(850000),
        },
    }


def with_request_activity(endpoints_by_model):
    """Inject perf_last_30m_by_workload derived from completion_tokens_last_30d.

    OpenRouter replaced the per-endpoint 30-day completion-token volume with a
    30-minute request-count activity signal. The checked-in fixtures still
    carry completion_tokens_last_30d for readability, so this mirrors that
    same integer into the new field (without editing the fixture JSON) --
    the unweighted median then selects over the same eligible endpoints the
    fixtures were built to exercise.
    """
    endpoints_by_model = copy.deepcopy(endpoints_by_model)
    for document in endpoints_by_model.values():
        endpoints = document.get("data", {}).get("endpoints")
        if not isinstance(endpoints, list):
            continue
        for endpoint in endpoints:
            if "perf_last_30m_by_workload" in endpoint:
                continue
            count = endpoint.get("completion_tokens_last_30d")
            if isinstance(count, int) and not isinstance(count, bool):
                endpoint["perf_last_30m_by_workload"] = {"text_generation": {"request_count": count}}
    return endpoints_by_model


def production_policy():
    return json.loads((SCRIPTS / "openrouter_pricing_policy.json").read_text(encoding="utf-8"))


def production_rate_card():
    return json.loads((ROOT / "phase3-binary" / "catalog" / "autotune" / "rate-card.json").read_text(encoding="utf-8"))


def production_recommendable_keys():
    catalog = json.loads((ROOT / "phase3-binary" / "catalog" / "autotune" / "autotune-candidates.json").read_text(encoding="utf-8"))
    return {
        key
        for key, row in catalog["rows"].items()
        if row.get("runtime_status") == "recommendable"
    }


def production_min_provider_targets():
    return engine.normalize_min_provider_targets(
        json.loads((ROOT / "phase3-binary" / "catalog" / "autotune" / "demand-rank.json").read_text(encoding="utf-8"))
    )


def synthetic_production_market_snapshot(*, illiquid_source: str | None = None):
    policy_document = production_policy()
    ranked_sources = [model["source_model_id"] for model in policy_document["models"]]
    ranked_sources.extend(f"unknown/model-{index}" for index in range(1, 51 - len(ranked_sources)))
    rankings = {
        "data": [
            {
                "date": "2026-08-03",
                "model_permaslug": source_id,
                "total_tokens": str(50_000_000 - rank * 100_000),
            }
            for rank, source_id in enumerate(ranked_sources, start=1)
        ],
        "meta": {
            "as_of": "2026-08-04T02:00:00Z",
            "start_date": "2026-07-05",
            "end_date": "2026-08-03",
            "version": "v1",
        },
    }
    models = {
        "data": [
            {
                "id": source_id,
                "canonical_slug": source_id,
                "name": source_id,
                "pricing": None,
            }
            for source_id in ranked_sources
        ],
    }
    endpoints = {}
    for source_id in ranked_sources:
        # Illiquidity is now expressed as 30-minute request activity below the
        # policy floor (min_endpoint_request_count_30m), not a per-model
        # token-volume floor. 0 fails the default floor of 1; any real
        # activity count clears it.
        request_count = 0 if source_id == illiquid_source else 5_000_000
        # Two distinct providers with identical prices: meets the distinct-provider
        # quorum (production policy = 2) without changing the median. When
        # illiquid (request_count 0) both fall below the floor -> still no price.
        endpoints[source_id] = {
            "data": {
                "id": source_id,
                "endpoints": [
                    {
                        "provider_name": "SyntheticLiquid",
                        "status": 0,
                        "perf_last_30m_by_workload": {"text_generation": {"request_count": request_count}},
                        "pricing": {"prompt": "0.00000010", "completion": "0.00000020"},
                    },
                    {
                        "provider_name": "SyntheticLiquidTwo",
                        "status": 0,
                        "perf_last_30m_by_workload": {"text_generation": {"request_count": request_count}},
                        "pricing": {"prompt": "0.00000010", "completion": "0.00000020"},
                    },
                ],
            }
        }
    return engine.build_snapshot(rankings, models, endpoints, policy_document, now=NOW, top_n=50)


class FakeHTTPClient:
    def __init__(self, responses):
        self.responses = {url: list(values) for url, values in responses.items()}
        self.requested_urls = []

    def get(self, url, timeout_seconds):
        self.requested_urls.append(url)
        values = self.responses[url]
        response = values.pop(0)
        if isinstance(response, Exception):
            raise response
        return response


class FakeProductionResponse:
    status = 200

    def __init__(self):
        self._chunks = [b'{"data": []}', b""]

    def getheader(self, name):
        return None

    def getheaders(self):
        return []

    def read1(self, amount):
        return self._chunks.pop(0)


class FakeProductionConnection:
    instances = []

    def __init__(self, host, timeout):
        self.host = host
        self.timeout = timeout
        self.sock = None
        self.closed = False
        self.__class__.instances.append(self)

    def request(self, method, target, headers):
        self.target = target
        self.headers = headers

    def getresponse(self):
        return FakeProductionResponse()

    def close(self):
        self.closed = True


class OpenRouterPricingEngineTests(unittest.TestCase):
    def test_policy_covers_every_current_recommendable_catalog_key(self):
        catalog_path = ROOT / "phase3-binary" / "catalog" / "autotune" / "autotune-candidates.json"
        catalog = json.loads(catalog_path.read_text(encoding="utf-8"))
        policy_path = SCRIPTS / "openrouter_pricing_policy.json"
        policy_document = json.loads(policy_path.read_text(encoding="utf-8"))
        recommendable = {
            key
            for key, row in catalog["rows"].items()
            if row.get("runtime_status") == "recommendable"
        }
        mapped = {model["canonical_model_id"] for model in policy_document["models"]}
        self.assertEqual(recommendable, mapped)

    def test_v6_market_peg_prices_every_mapped_recommendable_key_from_real_policy(self):
        policy_document = production_policy()
        snapshot = synthetic_production_market_snapshot()
        proposal = engine.build_proposal(snapshot, policy_document, production_rate_card(), now=NOW)
        recommendable = production_recommendable_keys()
        priced = {
            row["model_id"]
            for bucket in ("added", "changed", "unchanged")
            for row in proposal[bucket]
        }
        blocked = {row["model_id"] for row in proposal["blocked"]}
        self.assertEqual(recommendable, priced & recommendable)
        self.assertFalse(blocked & recommendable)
        self.assertIn("openai/gpt-oss-120b", priced)
        self.assertIn("qwen3-32b", priced)
        qwen_coder = next(row for row in proposal["changed"] if row["model_id"] == "qwen3-coder-30b-a3b-instruct")
        self.assertEqual(qwen_coder["proposed_rates"]["completion_rate_per_mtok"], 160000)
        self.assertEqual(qwen_coder["proposed_rates"]["prompt_rate_per_mtok"], 80000)
        self.assertFalse(
            any("provider net hourly USD" in reason for reason in qwen_coder["proposed_rates"]["formula_reasons"])
        )

    def test_v6_market_peg_illiquid_mapped_key_writes_no_artifacts(self):
        snapshot = synthetic_production_market_snapshot(illiquid_source="qwen/qwen3-32b")
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            snapshot_path = root / "snapshot.json"
            policy_path = root / "policy.json"
            rate_card_path = root / "rate-card.json"
            output_dir = root / "out"
            snapshot_path.write_text(json.dumps(snapshot), encoding="utf-8")
            policy_path.write_text(json.dumps(production_policy()), encoding="utf-8")
            rate_card_path.write_text(json.dumps(production_rate_card()), encoding="utf-8")
            args = engine.parser().parse_args([
                "compute",
                "--snapshot", str(snapshot_path),
                "--policy", str(policy_path),
                "--rate-card", str(rate_card_path),
                "--candidate-catalog", str(ROOT / "phase3-binary" / "catalog" / "autotune" / "autotune-candidates.json"),
                "--min-provider-targets", str(ROOT / "phase3-binary" / "catalog" / "autotune" / "demand-rank.json"),
                "--output-dir", str(output_dir),
            ])
            with patch.object(engine, "utc_now", return_value=NOW):
                with self.assertRaisesRegex(engine.SchemaError, "no active priced OpenRouter endpoint"):
                    args.handler(args)
            self.assertFalse(output_dir.exists())

    def test_v5_legacy_coding_dense_pricing_uses_baseline_premium_cap(self):
        legacy_policy = fixture("legacy-policy-2026-08-10.json")
        qwen_policy = next(model for model in legacy_policy["models"] if model["source_model_id"] == "qwen/qwen2.5-coder-32b-instruct")
        qwen_policy["profile"]["projected_tps"] = "150"
        snapshot = self.snapshot(legacy_policy)
        snapshot["schema_version"] = engine.LEGACY_SNAPSHOT_SCHEMA_VERSION
        snapshot["source"]["observed_schema_version_or_fingerprint"] = engine.LEGACY_SCHEMA_CONTRACT_FINGERPRINT
        snapshot["source"]["fetch_metadata"].pop("skipped_free_ranked_models", None)
        qwen_row = next(row for row in snapshot["rows"] if row["source_model_id"] == "qwen/qwen2.5-coder-32b-instruct")
        qwen_row["pricing"]["completion_per_token"] = "0.00000025"
        qwen_row["pricing"]["completion_per_mtok"] = "0.25"
        for row in snapshot["rows"]:
            if isinstance(row.get("pricing"), dict):
                row["pricing"].pop("liquidity_filter", None)
        snapshot["content_digest"] = engine.sha256_prefixed(engine.snapshot_digest_payload(snapshot))

        proposal = engine.build_proposal(snapshot, legacy_policy, reference_rate_card(), now=NOW)

        qwen_change = next(row for row in proposal["changed"] if row["model_id"] == "qwen2.5-coder-32b-instruct")
        self.assertNotIn("proposed_rates", qwen_change)
        self.assertIn("proposed_completion_rate", qwen_change)
        self.assertEqual(
            qwen_change["proposed_completion_rate"],
            {
                "usd_per_mtok": "0.225",
                "rate_card_completion_rate_per_mtok": 225000,
                "formula_reasons": [
                    "coding premium fraction 0.1",
                    "coding market undercut fraction 0.1",
                    "provider net hourly USD 0.10935 using rate-card economics row qwen2.5-coder-32b-instruct",
                ],
            },
        )

    def test_v5_legacy_policy_rejects_invalid_coding_controls(self):
        legacy_policy = fixture("legacy-policy-2026-08-10.json")
        legacy_policy["coding_minimum_undercut_fraction"] = "0"
        with self.assertRaisesRegex(engine.SchemaError, "coding_minimum_undercut_fraction"):
            engine.build_proposal(self.snapshot(legacy_policy), legacy_policy, reference_rate_card(), now=NOW)

    def test_v5_legacy_snapshot_rejects_current_policy_shape(self):
        legacy_policy = fixture("legacy-policy-2026-08-10.json")
        snapshot = self.snapshot(legacy_policy)
        snapshot["schema_version"] = engine.LEGACY_SNAPSHOT_SCHEMA_VERSION
        snapshot["source"]["observed_schema_version_or_fingerprint"] = engine.LEGACY_SCHEMA_CONTRACT_FINGERPRINT
        snapshot["source"]["fetch_metadata"].pop("skipped_free_ranked_models", None)
        for row in snapshot["rows"]:
            if isinstance(row.get("pricing"), dict):
                row["pricing"].pop("liquidity_filter", None)
        snapshot["content_digest"] = engine.sha256_prefixed(engine.snapshot_digest_payload(snapshot))

        with self.assertRaisesRegex(engine.SchemaError, "legacy snapshot requires legacy pricing policy"):
            engine.build_proposal(snapshot, policy(), reference_rate_card(), now=NOW)

    def test_v5_legacy_pricing_uses_multiplier_aware_internal_conversion(self):
        legacy_policy = fixture("legacy-policy-2026-08-10.json")
        snapshot = self.snapshot(legacy_policy)
        snapshot["schema_version"] = engine.LEGACY_SNAPSHOT_SCHEMA_VERSION
        snapshot["source"]["observed_schema_version_or_fingerprint"] = engine.LEGACY_SCHEMA_CONTRACT_FINGERPRINT
        snapshot["source"]["fetch_metadata"].pop("skipped_free_ranked_models", None)
        for row in snapshot["rows"]:
            if isinstance(row.get("pricing"), dict):
                row["pricing"].pop("liquidity_filter", None)
        snapshot["content_digest"] = engine.sha256_prefixed(engine.snapshot_digest_payload(snapshot))
        card = reference_rate_card()
        card["rows"]["openai/gpt-oss-20b"]["global_multiplier_ppm"] = 2000000

        proposal = engine.build_proposal(snapshot, legacy_policy, card, now=NOW)

        gpt_oss_change = next(row for row in proposal["changed"] if row["model_id"] == "openai/gpt-oss-20b")
        self.assertEqual(gpt_oss_change["proposed_completion_rate"]["usd_per_mtok"], "0.104")
        self.assertEqual(gpt_oss_change["proposed_completion_rate"]["rate_card_completion_rate_per_mtok"], 52000)
        self.assertEqual(gpt_oss_change["rate_card_economics"]["global_multiplier_ppm"], "2000000")

    def test_demand_proposal_fails_illiquid_mapped_key(self):
        snapshot = synthetic_production_market_snapshot(illiquid_source="qwen/qwen3-32b")
        min_targets = production_min_provider_targets()
        with self.assertRaisesRegex(engine.SchemaError, "no active priced OpenRouter endpoint"):
            engine.build_demand_proposal(
                snapshot,
                production_policy(),
                min_provider_targets=min_targets,
                now=NOW,
            )

    def setUp(self):
        self.rankings = fixture("rankings.json")
        self.models = fixture("models.json")
        self.endpoints = with_request_activity(fixture("endpoints.json"))

    def expanded_inputs(self):
        rankings = copy.deepcopy(self.rankings)
        models = copy.deepcopy(self.models)
        endpoints = copy.deepcopy(self.endpoints)
        template_endpoint = copy.deepcopy(endpoints["example/new-model"])
        for index in range(5, 44):
            model_id = f"unknown/model-{index}"
            rankings["data"].append({"date": "2026-08-03", "model_permaslug": model_id, "total_tokens": str(9000 - index)})
            models["data"].append({"id": model_id, "canonical_slug": model_id, "name": f"Unknown {index}", "pricing": None})
            endpoint = copy.deepcopy(template_endpoint)
            endpoint["data"]["id"] = model_id
            endpoints[model_id] = endpoint
        return rankings, models, endpoints

    def snapshot(self, policy_document=None):
        rankings, models, endpoints = self.expanded_inputs()
        return engine.build_snapshot(
            rankings,
            models,
            endpoints,
            policy_document or policy(),
            now=NOW,
            top_n=50,
        )

    def test_normalization_emits_stable_digest_and_cheapest_active_pricing(self):
        first = self.snapshot()
        rankings, models, endpoints = self.expanded_inputs()
        second = engine.build_snapshot(rankings, models, endpoints, policy(), now=NOW.replace(hour=13), top_n=50)
        self.assertEqual(first["content_digest"], second["content_digest"])
        self.assertEqual(first["rows"][0]["demand"]["total_token_volume"], "22000")
        self.assertEqual(first["rows"][0]["pricing"]["benchmark_provider"], "CoreWeave")
        self.assertEqual(first["rows"][0]["pricing"]["completion_per_mtok"], "0.13")
        self.assertEqual(first["rows"][2]["canonical_model_id"], "google-gemma-4-26b-a4b-it")
        engine.validate_snapshot(first)

    def test_prompt_and_completion_are_independent_unweighted_medians(self):
        rankings, models, endpoints = self.expanded_inputs()
        endpoints["openai/gpt-oss-20b"]["data"]["endpoints"] = [
            {
                "provider_name": "A", "status": 0, "throughput_last_30m": "10",
                "uptime_last_30d": "0.99",
                "perf_last_30m_by_workload": {"text_generation": {"request_count": 6_000_000}},
                "pricing": {"prompt": "0.00000090", "completion": "0.00000010"},
            },
            {
                "provider_name": "B", "status": 0, "throughput_last_30m": "10",
                "uptime_last_30d": "0.99",
                "perf_last_30m_by_workload": {"text_generation": {"request_count": 6_000_000}},
                "pricing": {"prompt": "0.00000020", "completion": "0.00000030"},
            },
        ]
        snapshot = engine.build_snapshot(rankings, models, endpoints, policy(), now=NOW, top_n=50)
        pricing = next(row["pricing"] for row in snapshot["rows"] if row["source_model_id"] == "openai/gpt-oss-20b")
        self.assertEqual(pricing["completion_per_mtok"], "0.1")
        self.assertEqual(pricing["input_per_mtok"], "0.2")
        self.assertEqual(pricing["benchmark_provider"], "A")
        self.assertEqual(pricing["liquidity_filter"]["selected_prompt_provider"], "B")
        candidates = pricing["liquidity_filter"]["eligible_endpoint_liquidity"]
        self.assertEqual(len(candidates), 2)

    def test_liquidity_eligibility_excludes_endpoints_missing_or_zero_request_activity(self):
        # New activity signal: eligibility now turns entirely on
        # perf_last_30m_by_workload[*].request_count. An endpoint reporting no
        # request_count anywhere is treated as inactive (activity None) and
        # excluded, exactly like one that reports an explicit zero count below
        # the policy floor (default min_request_count_30m=1). Unrelated legacy
        # telemetry fields (throughput/uptime) never factor into eligibility.
        pricing = engine.cheapest_endpoint_pricing(
            {"data": {"id": "example/model", "endpoints": [
                {
                    "provider_name": "NoActivityReported", "status": 0,
                    "uptime_last_30d": "0",
                    "pricing": {"prompt": "0.00000010", "completion": "0.00000020"},
                },
                {
                    "provider_name": "ZeroActivity", "status": 0,
                    "uptime_last_30d": "0.99",
                    "perf_last_30m_by_workload": {"text_generation": {"request_count": 0}},
                    "pricing": {"prompt": "0.00000015", "completion": "0.00000025"},
                },
                {
                    "provider_name": "ActiveTelemetry", "status": 0,
                    "throughput_last_30m": "10", "uptime_last_30d": "0.99",
                    "perf_last_30m_by_workload": {"text_generation": {"request_count": 1_000_000}},
                    "pricing": {"prompt": "0.00000030", "completion": "0.00000060"},
                },
            ]}},
            "example/model",
        )
        self.assertEqual(pricing["benchmark_provider"], "ActiveTelemetry")
        self.assertEqual(pricing["completion_per_mtok"], "0.6")
        self.assertEqual(
            [candidate["provider_name"] for candidate in pricing["liquidity_filter"]["eligible_endpoint_liquidity"]],
            ["ActiveTelemetry"],
        )
        self.assertEqual(
            [candidate["endpoint_model_id"] for candidate in pricing["liquidity_filter"]["eligible_endpoint_liquidity"]],
            ["example/model"],
        )
        self.assertNotIn(
            "throughput_last_30m",
            pricing["liquidity_filter"]["eligible_endpoint_liquidity"][0],
        )

    def test_recorded_openrouter_rankings_excerpt_fixture_is_normalizable_offline(self):
        recorded = fixture("recorded-rankings-response-excerpt.json")
        self.assertEqual(recorded["recording"]["source_url"], engine.RANKINGS_URL)
        normalized = engine.normalize_rankings(recorded["response"], top_n=1)
        self.assertEqual(normalized[0]["source_model_id"], "deepseek/deepseek-v4-flash-20260731")

    def test_catalog_alias_resolution_preserves_ranking_provenance_and_ignores_zero_completion_nonmodels(self):
        rankings = {"data": [
            {"date": "2026-08-03", "model_permaslug": "example/old-model-20260101", "total_tokens": "5"},
            {"date": "2026-08-03", "model_permaslug": "other", "total_tokens": "1"},
        ], "meta": {"as_of": "2026-08-04T02:00:00Z", "start_date": "2026-08-03", "end_date": "2026-08-03", "version": "v1"}}
        catalog = {"data": [{"id": "example/current-model", "canonical_slug": "example/old-model-20260101", "pricing": None}]}
        endpoints = {"example/current-model": {"data": {"id": "example/current-model", "endpoints": [{"provider_name": "Provider", "status": 0, "throughput_last_30m": "50", "uptime_last_30d": "0.99", "completion_tokens_last_30d": 1000000, "perf_last_30m_by_workload": {"text_generation": {"request_count": 1000000}}, "pricing": {"prompt": "0.1", "completion": "0.2"}}]}}}
        policy_document = policy()
        policy_document["models"] = []
        snapshot = engine.build_snapshot(rankings, catalog, endpoints, policy_document, now=NOW, top_n=1)
        self.assertEqual(snapshot["rows"][0]["source_model_id"], "example/current-model")
        self.assertEqual(snapshot["rows"][0]["source_metadata"]["ranking_model_permaslug"], "example/old-model-20260101")

    def test_catalog_alias_resolution_prefers_only_paid_variant_over_explicit_free_variant(self):
        rankings = [{"source_model_id": "google/gemma-4-31b-it-20260402", "rank": 1, "total_token_volume": "10", "ranking_date": "2026-08-04"}]
        catalog = {
            "google/gemma-4-31b-it": {"canonical_slug": "google/gemma-4-31b-it-20260402"},
            "google/gemma-4-31b-it:free": {"canonical_slug": "google/gemma-4-31b-it-20260402"},
        }
        resolved = engine.resolve_rankings_to_catalog(rankings, catalog)
        self.assertEqual(resolved[0]["source_model_id"], "google/gemma-4-31b-it")
        self.assertEqual(resolved[0]["ranking_model_permaslug"], "google/gemma-4-31b-it-20260402")

    def test_free_only_ranked_model_with_paid_sibling_is_skipped_not_pending(self):
        # A :free ranking permaslug is never auto-accepted as a paid identity.
        # It shares no canonical-slug link with the paid sibling here, so it
        # cannot be pinned to a unique paid row and is dropped from the cohort
        # with a recorded reason rather than being carried as a pending endpoint
        # fetch (which used to force a fetch of the :free endpoint and abort).
        rankings = [{"source_model_id": "example/model:free", "rank": 1, "total_token_volume": "10", "ranking_date": "2026-08-04"}]
        catalog = {
            "example/model": {"canonical_slug": "example/model"},
            "example/model:free": {"canonical_slug": "example/model"},
        }
        skipped: list[dict] = []
        resolved = engine.resolve_rankings_to_catalog(rankings, catalog, skipped_sink=skipped)
        self.assertEqual(resolved, [])
        self.assertEqual(
            skipped,
            [{"ranking_model_permaslug": "example/model:free", "reason": "dropped_free_variant", "rank": 1}],
        )

    def test_catalog_resolution_does_not_select_single_free_canonical_candidate(self):
        rankings = [{"source_model_id": "example/model", "rank": 1, "total_token_volume": "10", "ranking_date": "2026-08-04"}]
        catalog = {"example/model:free": {"canonical_slug": "example/model"}}
        resolved = engine.resolve_rankings_to_catalog(rankings, catalog)
        self.assertEqual(resolved[0]["source_model_id"], "example/model")
        self.assertEqual(resolved[0]["_identity_resolution"], "endpoint_candidate_pending")

    def test_free_only_ranked_model_is_skipped_not_fatal(self):
        # Regression: a :free ranked permaslug with no unique paid catalog row
        # must be dropped from the cohort with a logged reason, NOT abort the
        # whole fetch. The skip is identical whether or not endpoint documents
        # are supplied, so the endpoint-fetch never requests the :free slug.
        rankings = [{"source_model_id": "example/model:free", "rank": 1, "total_token_volume": "10", "ranking_date": "2026-08-04"}]
        catalog = {"example/model": {"canonical_slug": "example/model"}}
        endpoints = {"example/model:free": {"data": {"id": "example/model"}}}
        for endpoint_documents in (None, endpoints):
            skipped: list[dict] = []
            resolved = engine.resolve_rankings_to_catalog(
                rankings, catalog, endpoint_documents, skipped_sink=skipped
            )
            self.assertEqual(resolved, [])
            self.assertEqual(
                skipped,
                [{"ranking_model_permaslug": "example/model:free", "reason": "dropped_free_variant", "rank": 1}],
            )

    def test_catalog_alias_resolution_uses_endpoint_confirmed_regular_variant_over_batch(self):
        rankings = [{"source_model_id": "z-ai/glm-5.2-20260616", "rank": 1, "total_token_volume": "10", "ranking_date": "2026-08-08"}]
        catalog = {
            "z-ai/glm-5.2": {"canonical_slug": "z-ai/glm-5.2-20260616"},
            "z-ai/glm-5.2:batch": {"canonical_slug": "z-ai/glm-5.2-20260616"},
        }
        pending = engine.resolve_rankings_to_catalog(rankings, catalog)
        self.assertEqual(pending[0]["source_model_id"], "z-ai/glm-5.2-20260616")
        self.assertEqual(pending[0]["_identity_resolution"], "endpoint_candidate_pending")
        endpoints = {"z-ai/glm-5.2-20260616": {"data": {"id": "z-ai/glm-5.2"}}}
        resolved = engine.resolve_rankings_to_catalog(rankings, catalog, endpoints)
        self.assertEqual(resolved[0]["source_model_id"], "z-ai/glm-5.2")
        self.assertEqual(resolved[0]["_identity_resolution"], "endpoint_confirmed_catalog_candidate")

    def test_catalog_alias_resolution_rejects_endpoint_id_not_in_ambiguous_candidates(self):
        rankings = [{"source_model_id": "z-ai/glm-5.2-20260616", "rank": 1, "total_token_volume": "10", "ranking_date": "2026-08-08"}]
        catalog = {
            "z-ai/glm-5.2": {"canonical_slug": "z-ai/glm-5.2-20260616"},
            "z-ai/glm-5.2:batch": {"canonical_slug": "z-ai/glm-5.2-20260616"},
        }
        endpoints = {"z-ai/glm-5.2-20260616": {"data": {"id": "z-ai/other"}}}
        with self.assertRaisesRegex(engine.SchemaError, "does not uniquely identify a catalog candidate"):
            engine.resolve_rankings_to_catalog(rankings, catalog, endpoints)

    def test_catalog_alias_resolution_rejects_malformed_endpoint_for_ambiguous_candidates(self):
        rankings = [{"source_model_id": "z-ai/glm-5.2-20260616", "rank": 1, "total_token_volume": "10", "ranking_date": "2026-08-08"}]
        catalog = {
            "z-ai/glm-5.2": {"canonical_slug": "z-ai/glm-5.2-20260616"},
            "z-ai/glm-5.2:batch": {"canonical_slug": "z-ai/glm-5.2-20260616"},
        }
        endpoints = {"z-ai/glm-5.2-20260616": {"data": {}}}
        with self.assertRaises(engine.SchemaError):
            engine.resolve_rankings_to_catalog(rankings, catalog, endpoints)

    def test_catalog_missing_dated_ranking_uses_endpoint_confirmed_alias(self):
        rankings = {"data": [{"date": "2026-08-04", "model_permaslug": "bytedance-seed/seedream-4.5-20251203", "total_tokens": "10"}], "meta": {"as_of": "2026-08-05T02:00:00Z", "start_date": "2026-08-04", "end_date": "2026-08-04", "version": "v1"}}
        catalog = {"data": [{"id": "example/other", "canonical_slug": "example/other", "pricing": None}]}
        endpoints = {
            "bytedance-seed/seedream-4.5-20251203": {
                "data": {
                    "id": "bytedance-seed/seedream-4.5",
                    "endpoints": [{"provider_name": "Provider", "status": 0, "throughput_last_30m": "50", "uptime_last_30d": "0.99", "completion_tokens_last_30d": 1000000, "perf_last_30m_by_workload": {"text_generation": {"request_count": 1000000}}, "pricing": {"prompt": "0.1", "completion": "0.2"}}],
                }
            }
        }
        policy_document = policy()
        policy_document["models"] = []
        snapshot = engine.build_snapshot(rankings, catalog, endpoints, policy_document, now=NOW, top_n=1)
        self.assertEqual(snapshot["rows"][0]["source_model_id"], "bytedance-seed/seedream-4.5")
        self.assertEqual(snapshot["rows"][0]["source_metadata"]["identity_resolution"], "endpoint_alias_fallback")
        self.assertIsNone(snapshot["rows"][0]["source_metadata"]["catalog_name"])

    def test_no_active_priced_endpoint_is_snapshotted_but_fails_compute(self):
        rankings, models, endpoints = self.expanded_inputs()
        endpoints["openai/gpt-oss-20b"]["data"]["endpoints"][0]["status"] = -2
        snapshot = engine.build_snapshot(rankings, models, endpoints, policy(), now=NOW, top_n=50)
        row = next(item for item in snapshot["rows"] if item["source_model_id"] == "openai/gpt-oss-20b")
        self.assertEqual(row["pricing_status"], "no_active_priced_endpoint")
        self.assertIsNone(row["pricing"])
        with self.assertRaisesRegex(engine.SchemaError, "no active priced OpenRouter endpoint"):
            engine.build_proposal(snapshot, policy(), reference_rate_card(), now=NOW)

    def test_malformed_inactive_endpoint_rows_abort_snapshot_generation(self):
        mutations = {
            "missing provider": lambda row: row.pop("provider_name"),
            "null provider": lambda row: row.__setitem__("provider_name", None),
            "missing pricing": lambda row: row.pop("pricing"),
            "null pricing": lambda row: row.__setitem__("pricing", None),
            "missing prompt": lambda row: row["pricing"].pop("prompt"),
            "malformed completion": lambda row: row["pricing"].__setitem__("completion", "not-a-price"),
            "unexpected pricing field": lambda row: row["pricing"].__setitem__("unreviewed_field", "1"),
        }
        for label, mutate in mutations.items():
            with self.subTest(label=label):
                endpoints = copy.deepcopy(self.endpoints)
                row = endpoints["openai/gpt-oss-20b"]["data"]["endpoints"][0]
                row["status"] = 1
                mutate(row)
                with self.assertRaises(engine.SchemaError):
                    engine.build_snapshot(self.rankings, self.models, endpoints, policy(), now=NOW, top_n=4)

    def test_429_retries_then_succeeds_and_honors_retry_after(self):
        client = FakeHTTPClient({
            "https://example.test": [
                engine.HTTPResponse(429, b"{}", {"Retry-After": "2"}),
                engine.HTTPResponse(200, b'{"data": []}', {}),
            ]
        })
        delays = []
        value = engine.fetch_json(client, "https://example.test", "test", retries=1, timeout_seconds=1, sleeper=delays.append, jitter=lambda: 0)
        self.assertEqual(value, {"data": []})
        self.assertEqual(delays, [2.0])

    def test_retry_after_http_date_and_long_delay_are_honored_or_fail_at_generation_deadline(self):
        self.assertEqual(
            engine.retry_after_seconds(
                {"Retry-After": "Wed, 05 Aug 2026 12:02:00 GMT"},
                now=datetime(2026, 8, 5, 12, 0, 0, tzinfo=timezone.utc),
            ),
            120.0,
        )
        client = FakeHTTPClient({"https://example.test": [engine.HTTPResponse(429, b"{}", {"Retry-After": "120"}), engine.HTTPResponse(200, b'{"data": []}', {})]})
        delays = []
        value = engine.fetch_json(client, "https://example.test", "test", retries=1, timeout_seconds=1, sleeper=delays.append, clock=lambda: 0)
        self.assertEqual(value, {"data": []})
        self.assertEqual(delays, [120.0])
        deadline_client = FakeHTTPClient({"https://example.test": [engine.HTTPResponse(429, b"{}", {"Retry-After": "120"})]})
        with self.assertRaises(engine.FetchError):
            engine.fetch_json(deadline_client, "https://example.test", "test", retries=1, timeout_seconds=1, sleeper=lambda _: None, deadline=60, clock=lambda: 0)

    def test_429_retry_exhaustion_and_transport_failure_fail_closed(self):
        client = FakeHTTPClient({"https://example.test": [engine.HTTPResponse(429, b"{}", {}), engine.HTTPResponse(429, b"{}", {})]})
        with self.assertRaises(engine.FetchError):
            engine.fetch_json(client, "https://example.test", "test", retries=1, timeout_seconds=1, sleeper=lambda _: None, jitter=lambda: 0)
        transport = FakeHTTPClient({"https://example.test": [engine.FetchError("timeout"), engine.FetchError("timeout")]})
        with self.assertRaises(engine.FetchError):
            engine.fetch_json(transport, "https://example.test", "test", retries=1, timeout_seconds=1, sleeper=lambda _: None, jitter=lambda: 0)

    def test_unsafe_received_response_is_not_retried(self):
        client = FakeHTTPClient({"https://example.test": [engine.ResponseValidationError("oversized"), engine.HTTPResponse(200, b'{"data": []}', {})]})
        with self.assertRaises(engine.ResponseValidationError):
            engine.fetch_json(client, "https://example.test", "test", retries=1, timeout_seconds=1, sleeper=lambda _: None)
        self.assertEqual(len(client.responses["https://example.test"]), 1)

    def test_production_adapter_uses_bounded_resolver_and_request_path(self):
        FakeProductionConnection.instances = []
        with patch.object(engine.http.client, "HTTPSConnection", FakeProductionConnection):
            client = engine.UrllibHTTPClient(resolver=lambda timeout: ["127.0.0.1", "127.0.0.2"])
            response = client.get("https://openrouter.ai/api/v1/models", 1)
            second_response = client.get("https://openrouter.ai/api/v1/models", 1)
        self.assertEqual(response.status, 200)
        self.assertEqual(response.body, b'{"data": []}')
        self.assertEqual(second_response.status, 200)
        self.assertEqual(client._next_address_index, 2)
        self.assertNotIn("Authorization", FakeProductionConnection.instances[0].headers)

    def test_production_adapter_sends_bearer_auth_only_when_configured(self):
        FakeProductionConnection.instances = []
        with patch.dict(engine.os.environ, {"OPENROUTER_API_KEY": "unit-test-token"}, clear=True):
            with patch.object(engine.http.client, "HTTPSConnection", FakeProductionConnection):
                client = engine.UrllibHTTPClient(resolver=lambda timeout: ["127.0.0.1"])
                client.get("https://openrouter.ai/api/v1/models", 1)
        self.assertEqual(
            FakeProductionConnection.instances[0].headers["Authorization"],
            "Bearer unit-test-token",
        )

    def test_deadlines_and_invalid_timeouts_fail_closed(self):
        client = FakeHTTPClient({"https://example.test": [engine.HTTPResponse(200, b'{"data": []}', {})]})
        with self.assertRaises(engine.FetchError):
            engine.fetch_json(client, "https://example.test", "test", retries=0, timeout_seconds=1, deadline=10, clock=lambda: 10)
        with tempfile.TemporaryDirectory() as temporary:
            with self.assertRaises(engine.FetchError):
                engine.fetch_live_snapshot(policy(), output_dir=Path(temporary), top_n=4, retries=0, timeout_seconds=0, generation_timeout_seconds=10)
            self.assertEqual(list(Path(temporary).iterdir()), [])

    def test_malformed_empty_schema_partial_and_invalid_price_are_rejected(self):
        malformed_client = FakeHTTPClient({"https://example.test": [engine.HTTPResponse(200, b"{", {})]})
        with self.assertRaises(engine.SchemaError):
            engine.fetch_json(malformed_client, "https://example.test", "test", retries=0, timeout_seconds=1)
        empty = copy.deepcopy(self.rankings)
        empty["data"] = []
        with self.assertRaises(engine.SchemaError):
            engine.build_snapshot(empty, self.models, self.endpoints, policy(), now=NOW, top_n=4)
        malformed = copy.deepcopy(self.rankings)
        del malformed["data"][0]["model_permaslug"]
        with self.assertRaises(engine.SchemaError):
            engine.build_snapshot(malformed, self.models, self.endpoints, policy(), now=NOW, top_n=4)
        partial = copy.deepcopy(self.endpoints)
        del partial["example/new-model"]
        with self.assertRaises(engine.SchemaError):
            engine.build_snapshot(self.rankings, self.models, partial, policy(), now=NOW, top_n=4)
        original_openai_endpoint = copy.deepcopy(self.endpoints["openai/gpt-oss-20b"])
        selected_ids = [row["source_model_id"] for row in engine.normalize_rankings(self.rankings, 4)]
        empty_pricing = {model_id: self.endpoints[model_id] for model_id in selected_ids}
        empty_pricing["openai/gpt-oss-20b"] = {"data": {"id": "openai/gpt-oss-20b", "endpoints": []}}
        confirmed_empty_snapshot = engine.build_snapshot(
            self.rankings,
            self.models,
            empty_pricing,
            policy(),
            now=NOW,
            top_n=4,
            endpoint_confirmations={"openai/gpt-oss-20b": "confirmed_empty_second_fetch"},
        )
        empty_row = next(row for row in confirmed_empty_snapshot["rows"] if row["source_model_id"] == "openai/gpt-oss-20b")
        self.assertEqual(empty_row["pricing_status"], "no_provider_endpoints")
        self.assertIsNone(empty_row["pricing"])
        self.assertEqual(empty_row["source_metadata"]["endpoint_set_confirmation"], "confirmed_empty_second_fetch")
        invalid = copy.deepcopy(self.endpoints)
        invalid["openai/gpt-oss-20b"] = original_openai_endpoint
        invalid["openai/gpt-oss-20b"]["data"]["endpoints"][0]["pricing"]["completion"] = "-1"
        invalid_ids = [row["source_model_id"] for row in engine.normalize_rankings(self.rankings, 4)]
        invalid = {model_id: invalid[model_id] for model_id in invalid_ids}
        with self.assertRaises(engine.SchemaError):
            engine.build_snapshot(self.rankings, self.models, invalid, policy(), now=NOW, top_n=4)
        malformed_date = copy.deepcopy(self.rankings)
        malformed_date["data"][0]["date"] = "zzzz"
        with self.assertRaises(engine.SchemaError):
            engine.build_snapshot(malformed_date, self.models, self.endpoints, policy(), now=NOW, top_n=4)
        invalid_status = copy.deepcopy(self.endpoints)
        invalid_status["openai/gpt-oss-20b"] = original_openai_endpoint
        invalid_status["openai/gpt-oss-20b"]["data"]["endpoints"][0]["status"] = False
        with self.assertRaises(engine.SchemaError):
            engine.build_snapshot(self.rankings, self.models, invalid_status, policy(), now=NOW, top_n=4)

    def test_unexpected_source_fields_and_digest_valid_missing_provenance_are_rejected(self):
        drifted = copy.deepcopy(self.rankings)
        drifted["data"][0]["new_upstream_field"] = True
        with self.assertRaises(engine.SchemaError):
            engine.build_snapshot(drifted, self.models, self.endpoints, policy(), now=NOW, top_n=4)
        drifted_pricing = copy.deepcopy(self.endpoints)
        drifted_pricing["openai/gpt-oss-20b"]["data"]["endpoints"][0]["pricing"]["unreviewed_field"] = "1"
        with self.assertRaises(engine.SchemaError):
            engine.build_snapshot(self.rankings, self.models, drifted_pricing, policy(), now=NOW, top_n=4)
        snapshot = self.snapshot()
        del snapshot["rows"][0]["pricing"]["benchmark_provider"]
        snapshot["content_digest"] = engine.sha256_prefixed(engine.snapshot_digest_payload(snapshot))
        with self.assertRaises(engine.SchemaError):
            engine.validate_snapshot(snapshot)

    def test_duplicate_canonical_identity_is_rejected(self):
        duplicate_policy = policy()
        duplicate_policy["models"][1]["canonical_model_id"] = "openai/gpt-oss-20b"
        with self.assertRaises(engine.SchemaError):
            self.snapshot(duplicate_policy)
        duplicate_source_snapshot = self.snapshot()
        duplicate_source_snapshot["rows"][1]["source_model_id"] = duplicate_source_snapshot["rows"][0]["source_model_id"]
        duplicate_source_snapshot["rows"][1]["demand"]["source_model_id"] = duplicate_source_snapshot["rows"][0]["source_model_id"]
        duplicate_source_snapshot["content_digest"] = engine.sha256_prefixed(engine.snapshot_digest_payload(duplicate_source_snapshot))
        with self.assertRaises(engine.SchemaError):
            engine.validate_snapshot(duplicate_source_snapshot)

    def test_snapshot_liquidity_filter_tampering_is_rejected(self):
        snapshot = self.snapshot()
        snapshot["rows"][0]["pricing"]["liquidity_filter"]["minimum_uptime_last_30d"] = "0.10"
        snapshot["content_digest"] = engine.sha256_prefixed(engine.snapshot_digest_payload(snapshot))
        with self.assertRaises(engine.SchemaError):
            engine.validate_snapshot(snapshot)
        median_tampered = self.snapshot()
        median_tampered["rows"][0]["pricing"]["completion_per_mtok"] = "999"
        median_tampered["content_digest"] = engine.sha256_prefixed(engine.snapshot_digest_payload(median_tampered))
        with self.assertRaisesRegex(engine.SchemaError, "median price"):
            engine.validate_snapshot(median_tampered)

    def test_prompt_only_market_change_is_reported_as_changed(self):
        card = reference_rate_card()
        row = card["rows"]["openai/gpt-oss-20b"]
        row["prompt_rate_per_mtok"] = 999999
        proposal = engine.build_proposal(self.snapshot(), policy(), card, now=NOW)
        changed = next(item for item in proposal["changed"] if item["model_id"] == "openai/gpt-oss-20b")
        self.assertLess(changed["proposed_rates"]["prompt_rate_per_mtok"], 999999)

    def test_proposal_contains_added_changed_unchanged_and_blocked(self):
        snapshot = self.snapshot()
        proposal_policy = policy()
        proposal = engine.build_proposal(snapshot, proposal_policy, reference_rate_card(), now=NOW)
        self.assertEqual([row["model_id"] for row in proposal["changed"]], ["google-gemma-4-26b-a4b-it", "nvidia/nemotron-3-nano-30b-a3b", "openai/gpt-oss-20b", "qwen2.5-coder-32b-instruct"])
        self.assertEqual([row["model_id"] for row in proposal["unchanged"]], [])
        self.assertEqual([row["model_id"] for row in proposal["added"]], ["example/new-model"])
        # A served row absent from the demand cohort is RETAINED, never dropped:
        # cohort absence is not evidence to delist a model the fleet serves.
        self.assertEqual(proposal["dropped"], [])
        self.assertEqual(len(proposal["blocked"]), 45)
        gpt_oss = next(row for row in proposal["changed"] if row["model_id"] == "openai/gpt-oss-20b")
        self.assertEqual(gpt_oss["proposed_rates"]["completion_rate_per_mtok"], 104000)
        self.assertEqual(gpt_oss["proposed_rates"]["prompt_rate_per_mtok"], 24000)
        self.assertEqual(gpt_oss["proposed_rates"]["prompt_cache_hit_rate_per_mtok"], 6000)

    def test_served_row_is_never_dropped_by_the_proposal(self):
        # Regression lock for the false-drop fix: across the fixed fixture, no
        # currently-served rate-card row may ever appear under "dropped". Drops
        # require positive delisting evidence the engine does not derive from the
        # OpenRouter demand cohort.
        card = reference_rate_card()
        served = set(card["rows"]) - {"default"}
        proposal = engine.build_proposal(self.snapshot(), policy(), card, now=NOW)
        self.assertEqual(proposal["dropped"], [])
        dropped_ids = {row.get("model_id") for row in proposal["dropped"]}
        self.assertEqual(dropped_ids & served, set())

    def test_current_snapshot_ranking_date_rejects_two_calendar_days_old(self):
        with self.assertRaisesRegex(engine.SchemaError, "older than 48 hours"):
            engine.build_proposal(
                self.snapshot(),
                policy(),
                reference_rate_card(),
                now=datetime(2026, 8, 5, 0, 0, 0, tzinfo=timezone.utc),
            )

    def test_absent_served_row_fails_the_whole_compute(self):
        QWEN = "unmapped-kept"  # absent-from-cohort helper

        base_snapshot = self.snapshot()

        def proposal_for(mutate):
            pol = policy()
            absent = model("example/absent", QWEN)
            mutate(absent)
            pol["models"].append(absent)
            card = reference_rate_card()
            card["rows"][QWEN] = card["rows"]["default"].copy()
            return engine.build_proposal(base_snapshot, pol, card, now=NOW)

        def ids(prop, bucket):
            return {r["model_id"] for r in prop[bucket]}

        for mutate in (
            lambda model: None,
            lambda model: model["license"].__setitem__("commercial_permitted", False),
            lambda model: model["serving_path"].__setitem__("verification_status", "unverified"),
        ):
            with self.assertRaises(engine.SchemaError) as caught:
                proposal_for(mutate)
            self.assertIn("market-pegged compute emits no proposals", str(caught.exception))

    def test_proposal_schema_is_v2_without_retain_on_absence(self):
        proposal = engine.build_proposal(self.snapshot(), policy(), reference_rate_card(), now=NOW)
        self.assertEqual(engine.PROPOSAL_SCHEMA_VERSION, 2)
        self.assertEqual(proposal["schema_version"], 2)
        for bucket in ("added", "changed", "dropped", "blocked", "unchanged"):
            self.assertIn(bucket, proposal)
            self.assertIn(bucket, proposal["summary"])
        self.assertNotIn("retained", proposal)
        self.assertNotIn("retained", proposal["summary"])
        self.assertEqual(
            proposal["summary"]["eligible"],
            len(proposal["added"]) + len(proposal["changed"]) + len(proposal["unchanged"]),
        )

    def test_fixed_snapshot_policy_and_rate_card_emit_the_expected_complete_proposal(self):
        first = engine.build_proposal(self.snapshot(), policy(), reference_rate_card(), now=NOW)
        second = engine.build_proposal(self.snapshot(), policy(), reference_rate_card(), now=NOW)
        self.assertEqual(first, second)
        self.assertEqual(
            engine.sha256_prefixed(first),
            engine.sha256_prefixed(first),
        )

    def test_unresolved_nemotron_license_fails_current_compute(self):
        proposal_policy = policy()
        proposal_policy["models"][2]["license"]["commercial_permitted"] = False
        card = reference_rate_card()
        del card["rows"]["nvidia/nemotron-3-nano-30b-a3b"]
        with self.assertRaisesRegex(engine.SchemaError, "catalog-integrity:.*commercial license"):
            engine.build_proposal(self.snapshot(proposal_policy), proposal_policy, card, now=NOW)

    def test_snapshot_tampering_and_invalid_policy_are_rejected(self):
        snapshot = self.snapshot()
        snapshot["rows"][0]["pricing"]["completion_per_mtok"] = "999"
        with self.assertRaises(engine.SchemaError):
            engine.build_proposal(snapshot, policy(), reference_rate_card(), now=NOW)
        invalid_policy = policy()
        invalid_policy["undercut_fraction"] = "0.50"
        with self.assertRaises(engine.SchemaError):
            engine.build_proposal(self.snapshot(), invalid_policy, reference_rate_card(), now=NOW)

    def test_malformed_policy_and_rate_card_are_rejected_before_proposal(self):
        invalid_policy = policy()
        invalid_policy["models"][0]["profile"]["projected_tps"] = "NaN"
        with self.assertRaises(engine.SchemaError):
            engine.build_proposal(self.snapshot(), invalid_policy, reference_rate_card(), now=NOW)
        negative_policy = policy()
        negative_policy["models"][0]["profile"]["residency_gb"] = "-1"
        with self.assertRaises(engine.SchemaError):
            engine.build_proposal(self.snapshot(), negative_policy, reference_rate_card(), now=NOW)
        malformed_evidence = policy()
        del malformed_evidence["models"][0]["license"]["verification_note"]
        with self.assertRaises(engine.SchemaError):
            engine.build_proposal(self.snapshot(), malformed_evidence, reference_rate_card(), now=NOW)
        invalid_card = reference_rate_card()
        invalid_card["rows"] = {}
        with self.assertRaises(engine.SchemaError):
            engine.build_proposal(self.snapshot(), policy(), invalid_card, now=NOW)

    def test_unverified_serving_path_fails_current_compute(self):
        proposal_policy = policy()
        proposal_policy["models"][0]["serving_path"]["verification_status"] = "unverified"
        card = reference_rate_card()
        del card["rows"]["openai/gpt-oss-20b"]
        with self.assertRaisesRegex(engine.SchemaError, "catalog-integrity:.*serving path"):
            engine.build_proposal(self.snapshot(proposal_policy), proposal_policy, card, now=NOW)

    def test_rate_card_conversion_and_provider_share_control_internal_rate_and_coding_floor(self):
        card = reference_rate_card()
        card["usd_per_million_credits"] = 2.0
        card["rows"]["default"]["global_multiplier_ppm"] = 2000000
        card["rows"]["default"]["provider_share_bps"] = 5000
        self.assertEqual(engine.completion_rate_to_internal(engine.Decimal("0.20"), card, "not-present"), 100000)
        coding = model("example/new-model", "example/new-model")
        coding.update({"coding_specialist": True})
        coding["profile"] = {"kind": "coding_dense", "active_params_b": "32", "residency_gb": "17", "projected_tps": "200"}
        coding["profile"]["projected_tps"] = "20"
        with self.assertRaises(engine.SchemaError):
            engine.proposed_price(coding, {"input_per_mtok": "0.31", "completion_per_mtok": "0.25"}, policy(), card, "example/new-model")

    def test_tiny_recommendable_price_that_rounds_to_zero_fails_closed(self):
        card = reference_rate_card()
        row = model("example/new-model", "example/new-model")
        with self.assertRaisesRegex(engine.SchemaError, "example/new-model.*rounds to zero"):
            engine.proposed_price(
                row,
                {"input_per_mtok": "0.0000005", "completion_per_mtok": "0.0000005"},
                policy(),
                card,
                "example/new-model",
            )

    def test_compute_rejects_snapshot_without_policy_required_top_demand_coverage(self):
        partial_endpoints = {"openai/gpt-oss-20b": self.endpoints["openai/gpt-oss-20b"]}
        partial_snapshot = engine.build_snapshot(self.rankings, self.models, partial_endpoints, policy(), now=NOW, top_n=1)
        with self.assertRaises(engine.SchemaError):
            engine.build_proposal(partial_snapshot, policy(), reference_rate_card(), now=NOW)

    def test_atomic_write_leaves_no_final_artifact_when_serialization_fails(self):
        with tempfile.TemporaryDirectory() as temporary:
            target = Path(temporary) / "artifact.json"
            with self.assertRaises(TypeError):
                engine.atomic_write_json(target, {"not_json": object()})
            self.assertFalse(target.exists())
            self.assertEqual(list(Path(temporary).iterdir()), [])

    def test_atomic_write_never_overwrites_existing_artifact(self):
        with tempfile.TemporaryDirectory() as temporary:
            target = Path(temporary) / "artifact.json"
            engine.atomic_write_json(target, {"value": 1})
            with self.assertRaises(engine.EngineError):
                engine.atomic_write_json(target, {"value": 2})
            self.assertEqual(json.loads(target.read_text()), {"value": 1})

    def test_atomic_pair_write_leaves_no_partial_first_artifact(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            first = root / "first.json"
            second = root / "second.json"
            second.write_text("existing\n", encoding="utf-8")
            with self.assertRaises(engine.EngineError):
                engine.atomic_write_json_pair((first, {"value": 1}), (second, {"value": 2}))
            self.assertFalse(first.exists())
            self.assertEqual(second.read_text(encoding="utf-8"), "existing\n")

    def test_atomic_directory_publish_commits_complete_artifact_set(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            target = root / "out"
            engine.atomic_publish_json_directory(
                target,
                {
                    "first.json": {"value": 1},
                    "second.json": {"value": 2},
                },
            )
            self.assertEqual(json.loads((target / "first.json").read_text(encoding="utf-8")), {"value": 1})
            self.assertEqual(json.loads((target / "second.json").read_text(encoding="utf-8")), {"value": 2})
            self.assertTrue(target.is_symlink())
            self.assertEqual(sorted(path.name for path in target.iterdir()), ["first.json", "second.json"])
            with self.assertRaises(engine.EngineError):
                engine.atomic_publish_json_directory(target, {"third.json": {"value": 3}})

    def test_atomic_directory_publish_refuses_raced_existing_target(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            target = root / "out"
            real_symlink = engine.os.symlink

            def racing_symlink(src, dst, target_is_directory=False):
                target.mkdir()
                return real_symlink(src, dst, target_is_directory=target_is_directory)

            with patch.object(engine.os, "symlink", side_effect=racing_symlink):
                with self.assertRaises(engine.EngineError):
                    engine.atomic_publish_json_directory(target, {"first.json": {"value": 1}})
            self.assertTrue(target.is_dir())
            self.assertFalse(list(target.iterdir()))
            leftovers = [path for path in root.iterdir() if path != target]
            self.assertEqual(leftovers, [])

    def test_orchestration_failure_writes_no_final_snapshot(self):
        with tempfile.TemporaryDirectory() as temporary:
            client = FakeHTTPClient({engine.daily_rankings_url(NOW, 30): [engine.HTTPResponse(200, b"{", {})]})
            with self.assertRaises(engine.SchemaError):
                engine.fetch_live_snapshot(policy(), output_dir=Path(temporary), top_n=4, retries=0, timeout_seconds=1, client=client, now=lambda: NOW, sleeper=lambda _: None)
            self.assertEqual(list(Path(temporary).iterdir()), [])

    def test_fetch_orchestration_endpoint_confirms_regular_candidate_over_batch(self):
        dated_id = "z-ai/glm-5.2-20260616"
        regular_id = "z-ai/glm-5.2"
        rankings_url = engine.daily_rankings_url(NOW, 30)
        endpoint_url = engine.ENDPOINTS_URL.format(model_id=dated_id)
        rankings = {
            "data": [{"date": "2026-08-04", "model_permaslug": dated_id, "total_tokens": "10"}],
            "meta": {
                "as_of": "2026-08-05T02:00:00Z",
                "start_date": "2026-07-06",
                "end_date": "2026-08-04",
                "version": "v1",
            },
        }
        catalog = {
            "data": [
                {"id": regular_id, "canonical_slug": dated_id, "name": "GLM 5.2", "pricing": None},
                {"id": f"{regular_id}:batch", "canonical_slug": dated_id, "name": "GLM 5.2 Batch", "pricing": None},
            ]
        }
        endpoint = {
            "data": {
                "id": regular_id,
                "endpoints": [
                    {"provider_name": "Provider", "status": 0, "throughput_last_30m": "50", "uptime_last_30d": "0.99", "completion_tokens_last_30d": 1000000, "perf_last_30m_by_workload": {"text_generation": {"request_count": 1000000}}, "pricing": {"prompt": "0.1", "completion": "0.2"}}
                ],
            }
        }
        client = FakeHTTPClient({
            rankings_url: [engine.HTTPResponse(200, json.dumps(rankings).encode(), {})],
            engine.MODELS_URL: [engine.HTTPResponse(200, json.dumps(catalog).encode(), {})],
            endpoint_url: [engine.HTTPResponse(200, json.dumps(endpoint).encode(), {})],
        })
        policy_document = policy()
        policy_document["models"] = []
        with tempfile.TemporaryDirectory() as temporary:
            target = engine.fetch_live_snapshot(
                policy_document,
                output_dir=Path(temporary),
                top_n=1,
                retries=0,
                timeout_seconds=1,
                client=client,
                now=lambda: NOW,
                sleeper=lambda _: None,
            )
            snapshot = json.loads(target.read_text())
        self.assertIn(endpoint_url, client.requested_urls)
        self.assertNotIn(engine.ENDPOINTS_URL.format(model_id=regular_id), client.requested_urls)
        self.assertEqual(snapshot["rows"][0]["source_model_id"], regular_id)
        self.assertEqual(
            snapshot["rows"][0]["source_metadata"]["identity_resolution"],
            "endpoint_confirmed_catalog_candidate",
        )

    def test_fetch_orchestration_missing_ambiguous_endpoint_fails_closed(self):
        dated_id = "z-ai/glm-5.2-20260616"
        rankings_url = engine.daily_rankings_url(NOW, 30)
        endpoint_url = engine.ENDPOINTS_URL.format(model_id=dated_id)
        rankings = {
            "data": [{"date": "2026-08-04", "model_permaslug": dated_id, "total_tokens": "10"}],
            "meta": {
                "as_of": "2026-08-05T02:00:00Z",
                "start_date": "2026-07-06",
                "end_date": "2026-08-04",
                "version": "v1",
            },
        }
        catalog = {
            "data": [
                {"id": "z-ai/glm-5.2", "canonical_slug": dated_id, "name": "GLM 5.2", "pricing": None},
                {"id": "z-ai/glm-5.2:batch", "canonical_slug": dated_id, "name": "GLM 5.2 Batch", "pricing": None},
            ]
        }
        client = FakeHTTPClient({
            rankings_url: [engine.HTTPResponse(200, json.dumps(rankings).encode(), {})],
            engine.MODELS_URL: [engine.HTTPResponse(200, json.dumps(catalog).encode(), {})],
            endpoint_url: [engine.FetchError("required endpoint document missing")],
        })
        with tempfile.TemporaryDirectory() as temporary:
            with self.assertRaisesRegex(engine.FetchError, "required endpoint document missing"):
                engine.fetch_live_snapshot(
                    policy(),
                    output_dir=Path(temporary),
                    top_n=1,
                    retries=0,
                    timeout_seconds=1,
                    client=client,
                    now=lambda: NOW,
                    sleeper=lambda _: None,
                )
            self.assertEqual(list(Path(temporary).iterdir()), [])
        self.assertIn(endpoint_url, client.requested_urls)

    def test_confirmed_empty_endpoint_set_is_snapshotted_but_fails_compute(self):
        rankings, models, endpoints = self.expanded_inputs()
        endpoints["openai/gpt-oss-20b"]["data"]["endpoints"] = []
        snapshot = engine.build_snapshot(
            rankings,
            models,
            endpoints,
            policy(),
            now=NOW,
            top_n=50,
            endpoint_confirmations={"openai/gpt-oss-20b": "confirmed_empty_second_fetch"},
        )
        row = next(item for item in snapshot["rows"] if item["source_model_id"] == "openai/gpt-oss-20b")
        self.assertEqual(row["pricing_status"], "no_provider_endpoints")
        self.assertIsNone(row["pricing"])
        self.assertEqual(snapshot["source"]["fetch_metadata"]["successful_source_count"], 53)
        with self.assertRaisesRegex(engine.SchemaError, "OpenRouter reports no provider endpoints"):
            engine.build_proposal(snapshot, policy(), reference_rate_card(), now=NOW)

    def test_fetch_confirms_empty_endpoint_set_and_records_provenance(self):
        rankings_url = engine.daily_rankings_url(NOW, 30)
        model_id = "example/model"
        endpoint_url = engine.ENDPOINTS_URL.format(model_id=model_id)
        rankings = {
            "data": [{"date": "2026-08-04", "model_permaslug": model_id, "total_tokens": "10"}],
            "meta": {"as_of": "2026-08-05T02:00:00Z", "start_date": "2026-07-06", "end_date": "2026-08-04", "version": "v1"},
        }
        catalog = {"data": [{"id": model_id, "canonical_slug": model_id, "name": "Example", "pricing": None}]}
        empty = {"data": {"id": model_id, "endpoints": []}}
        client = FakeHTTPClient({
            rankings_url: [engine.HTTPResponse(200, json.dumps(rankings).encode(), {})],
            engine.MODELS_URL: [engine.HTTPResponse(200, json.dumps(catalog).encode(), {})],
            endpoint_url: [
                engine.HTTPResponse(200, json.dumps(empty).encode(), {}),
                engine.HTTPResponse(200, json.dumps(empty).encode(), {}),
            ],
        })
        policy_document = policy()
        policy_document["models"] = []
        with tempfile.TemporaryDirectory() as temporary:
            target = engine.fetch_live_snapshot(
                policy_document,
                output_dir=Path(temporary),
                top_n=1,
                retries=0,
                timeout_seconds=1,
                client=client,
                now=lambda: NOW,
                sleeper=lambda _: None,
            )
            snapshot = json.loads(target.read_text())
        self.assertEqual(client.requested_urls.count(endpoint_url), 2)
        self.assertEqual(snapshot["rows"][0]["pricing_status"], "no_provider_endpoints")
        self.assertEqual(snapshot["rows"][0]["source_metadata"]["endpoint_set_confirmation"], "confirmed_empty_second_fetch")

    def test_fetch_empty_confirmation_recovers_or_fails_closed(self):
        rankings_url = engine.daily_rankings_url(NOW, 30)
        model_id = "example/model"
        endpoint_url = engine.ENDPOINTS_URL.format(model_id=model_id)
        rankings = {
            "data": [{"date": "2026-08-04", "model_permaslug": model_id, "total_tokens": "10"}],
            "meta": {"as_of": "2026-08-05T02:00:00Z", "start_date": "2026-07-06", "end_date": "2026-08-04", "version": "v1"},
        }
        catalog = {"data": [{"id": model_id, "canonical_slug": model_id, "name": "Example", "pricing": None}]}
        empty = {"data": {"id": model_id, "endpoints": []}}
        priced = {"data": {"id": model_id, "endpoints": [{"provider_name": "Provider", "status": 0, "throughput_last_30m": "50", "uptime_last_30d": "0.99", "completion_tokens_last_30d": 1000000, "perf_last_30m_by_workload": {"text_generation": {"request_count": 1000000}}, "pricing": {"prompt": "0.1", "completion": "0.2"}}]}}
        policy_document = policy()
        policy_document["models"] = []
        recovered_client = FakeHTTPClient({
            rankings_url: [engine.HTTPResponse(200, json.dumps(rankings).encode(), {})],
            engine.MODELS_URL: [engine.HTTPResponse(200, json.dumps(catalog).encode(), {})],
            endpoint_url: [engine.HTTPResponse(200, json.dumps(empty).encode(), {}), engine.HTTPResponse(200, json.dumps(priced).encode(), {})],
        })
        with tempfile.TemporaryDirectory() as temporary:
            target = engine.fetch_live_snapshot(policy_document, output_dir=Path(temporary), top_n=1, retries=0, timeout_seconds=1, client=recovered_client, now=lambda: NOW, sleeper=lambda _: None)
            snapshot = json.loads(target.read_text())
        self.assertEqual(snapshot["rows"][0]["pricing_status"], "active_priced")
        self.assertEqual(snapshot["rows"][0]["source_metadata"]["endpoint_set_confirmation"], "recovered_nonempty_on_confirmation")

        malformed_client = FakeHTTPClient({
            rankings_url: [engine.HTTPResponse(200, json.dumps(rankings).encode(), {})],
            engine.MODELS_URL: [engine.HTTPResponse(200, json.dumps(catalog).encode(), {})],
            endpoint_url: [engine.HTTPResponse(200, json.dumps(empty).encode(), {}), engine.HTTPResponse(200, b'{"data":{"id":"example/model"}}', {})],
        })
        with tempfile.TemporaryDirectory() as temporary:
            with self.assertRaisesRegex(engine.SchemaError, "endpoints must be an array"):
                engine.fetch_live_snapshot(policy_document, output_dir=Path(temporary), top_n=1, retries=0, timeout_seconds=1, client=malformed_client, now=lambda: NOW, sleeper=lambda _: None)
            self.assertEqual(list(Path(temporary).iterdir()), [])

        mismatched_client = FakeHTTPClient({
            rankings_url: [engine.HTTPResponse(200, json.dumps(rankings).encode(), {})],
            engine.MODELS_URL: [engine.HTTPResponse(200, json.dumps(catalog).encode(), {})],
            endpoint_url: [engine.HTTPResponse(200, json.dumps(empty).encode(), {}), engine.HTTPResponse(200, b'{"data":{"id":"example/other","endpoints":[]}}', {})],
        })
        with tempfile.TemporaryDirectory() as temporary:
            with self.assertRaisesRegex(engine.SchemaError, "confirmation id mismatch"):
                engine.fetch_live_snapshot(policy_document, output_dir=Path(temporary), top_n=1, retries=0, timeout_seconds=1, client=mismatched_client, now=lambda: NOW, sleeper=lambda _: None)
            self.assertEqual(list(Path(temporary).iterdir()), [])

        deadline_client = FakeHTTPClient({
            rankings_url: [engine.HTTPResponse(200, json.dumps(rankings).encode(), {})],
            engine.MODELS_URL: [engine.HTTPResponse(200, json.dumps(catalog).encode(), {})],
            endpoint_url: [engine.HTTPResponse(200, json.dumps(empty).encode(), {}), engine.HTTPResponse(429, b"{}", {"Retry-After": "20"})],
        })
        with tempfile.TemporaryDirectory() as temporary:
            with self.assertRaises(engine.FetchError):
                engine.fetch_live_snapshot(policy_document, output_dir=Path(temporary), top_n=1, retries=1, timeout_seconds=1, generation_timeout_seconds=10, client=deadline_client, now=lambda: NOW, sleeper=lambda _: None, clock=lambda: 0)
            self.assertEqual(list(Path(temporary).iterdir()), [])

    def test_live_fetch_requires_an_openrouter_api_key(self):
        with tempfile.TemporaryDirectory() as temporary:
            with patch.dict(engine.os.environ, {}, clear=True):
                with self.assertRaises(engine.FetchError):
                    engine.fetch_live_snapshot(
                        policy(), output_dir=Path(temporary), top_n=50,
                        retries=0, timeout_seconds=1, now=lambda: NOW,
                    )
            self.assertEqual(list(Path(temporary).iterdir()), [])

    def test_current_rate_card_row_without_policy_mapping_is_explicitly_blocked(self):
        card = reference_rate_card()
        card["rows"]["unassessed-model"] = {"prompt_rate_per_mtok": 50, "prompt_cache_hit_rate_per_mtok": 12, "completion_rate_per_mtok": 123, "provider_share_bps": 9000, "global_multiplier_ppm": 1000000}
        proposal = engine.build_proposal(self.snapshot(), policy(), card, now=NOW)
        row = next(item for item in proposal["blocked"] if item["model_id"] == "unassessed-model")
        self.assertEqual(row["current_completion_rate"]["rate_card_completion_rate_per_mtok"], 123)

    def test_current_rate_lookup_uses_normalized_rate_row_for_current_snapshots(self):
        card = reference_rate_card()
        source_id = "nvidia/nemotron-3-nano-30b-a3b"
        normalized_id = "nemotron-3-nano-30b-a3b"
        card["rows"].pop(source_id)
        card["rows"][normalized_id] = {
            "prompt_rate_per_mtok": 81,
            "prompt_cache_hit_rate_per_mtok": 21,
            "completion_rate_per_mtok": 161000,
            "provider_share_bps": 8750,
            "global_multiplier_ppm": 975000,
        }
        rates = engine.current_rates(card["rows"], source_id)
        self.assertEqual(rates, {
            "rate_card_prompt_rate_per_mtok": 81,
            "rate_card_prompt_cache_hit_rate_per_mtok": 21,
            "rate_card_completion_rate_per_mtok": 161000,
        })
        self.assertIsNone(engine.current_rates(card["rows"], source_id, legacy=True))
        self.assertEqual(engine.rate_card_economics(card, source_id)[3], normalized_id)

    def test_one_snapshot_emits_rate_and_demand_proposals_with_shared_digest(self):
        snapshot = self.snapshot()
        rate_card_proposal = engine.build_proposal(snapshot, policy(), reference_rate_card(), now=NOW)
        targets = {model["canonical_model_id"]: 15 for model in policy()["models"]}
        demand_proposal = engine.build_demand_proposal(
            snapshot,
            policy(),
            min_provider_targets=targets,
            catalog_path=FIXTURES / "recommendable-catalog.json",
            now=NOW,
        )
        shared_digest = snapshot["content_digest"]
        self.assertEqual(rate_card_proposal["source_snapshot"]["content_digest"], shared_digest)
        self.assertEqual(demand_proposal["source_snapshot"]["content_digest"], shared_digest)
        self.assertEqual(demand_proposal["policy_version"], rate_card_proposal["policy_version"])
        policy_document = policy()
        mapped_snapshot_rows = {
            model["canonical_model_id"]: row
            for model in policy_document["models"]
            for row in snapshot["rows"]
            if row["source_model_id"] == model["source_model_id"]
        }
        tokens = {key: int(row["demand"]["total_token_volume"]) for key, row in mapped_snapshot_rows.items()}
        max_tokens = max(tokens.values())
        for canonical_id, source_row in mapped_snapshot_rows.items():
            row = demand_proposal["rows"][canonical_id]
            self.assertEqual(row["or_completion_tokens_30d"], int(source_row["demand"]["total_token_volume"]))
            self.assertIsInstance(row["or_completion_tokens_30d"], int)
            self.assertEqual(row["or_requests_30d"], 0)
            self.assertIsInstance(row["or_requests_30d"], int)
            self.assertAlmostEqual(row["demand_weight"], tokens[canonical_id] / max_tokens)

    def test_liquidity_filter_drops_only_non_spec_quotes(self):
        document = {"data": {"id": "example/model", "endpoints": [
            {"provider_name": "Free", "status": 0, "throughput_last_30m": "50", "uptime_last_30d": "0.99", "perf_last_30m_by_workload": {"text_generation": {"request_count": 1000000}}, "pricing": {"prompt": "0", "completion": "0"}},
            {"provider_name": "Dust", "status": 0, "throughput_last_30m": "0.2", "uptime_last_30d": "0.99", "perf_last_30m_by_workload": {"text_generation": {"request_count": 1000000}}, "pricing": {"prompt": "0.1", "completion": "0.2"}},
            {"provider_name": "Liquid", "status": 0, "throughput_last_30m": "2", "uptime_last_30d": "0.95", "perf_last_30m_by_workload": {"text_generation": {"request_count": 1000000}}, "pricing": {"prompt": "0.3", "completion": "0.4"}},
        ]}}
        pricing = engine.cheapest_endpoint_pricing(document, "example/model")
        self.assertEqual(pricing["benchmark_provider"], "Dust")
        self.assertEqual(pricing["completion_per_mtok"], "200000")
        self.assertEqual(len(pricing["liquidity_filter"]["eligible_endpoint_liquidity"]), 2)

    def _ep(self, provider, completion, prompt="0.0000001", rc=1000):
        return {"provider_name": provider, "status": 0,
                "perf_last_30m_by_workload": {"text_generation": {"request_count": rc}},
                "pricing": {"prompt": prompt, "completion": completion}}

    def test_pricing_requires_distinct_provider_quorum(self):
        one = {"data": {"id": "example/model", "endpoints": [self._ep("Solo", "0.0000002"), self._ep("Solo", "0.0000002")]}}
        self.assertIsNone(engine.cheapest_endpoint_pricing(one, "example/model", min_distinct_providers=2))
        two = {"data": {"id": "example/model", "endpoints": [self._ep("A", "0.0000002"), self._ep("B", "0.0000002")]}}
        priced = engine.cheapest_endpoint_pricing(two, "example/model", min_distinct_providers=2)
        self.assertIsNotNone(priced)
        self.assertEqual(priced["liquidity_filter"]["distinct_provider_count"], 2)
        self.assertEqual(priced["liquidity_filter"]["min_distinct_providers"], 2)

    def test_pricing_collapses_endpoints_to_one_vote_per_provider(self):
        # A Sybil provider with 3 endpoints at $2.0 gets ONE vote (its lowest), so
        # the unweighted lower median of the 3 distinct providers stays at the two
        # honest $0.2 quotes -- it cannot be steered to $2.0 by adding endpoints.
        doc = {"data": {"id": "example/model", "endpoints": [
            self._ep("Honest1", "0.0000002"), self._ep("Honest2", "0.0000002"),
            self._ep("Sybil", "0.0000020"), self._ep("Sybil", "0.0000020"), self._ep("Sybil", "0.0000020"),
        ]}}
        priced = engine.cheapest_endpoint_pricing(doc, "example/model", min_distinct_providers=2)
        self.assertEqual(priced["liquidity_filter"]["distinct_provider_count"], 3)
        self.assertEqual(priced["completion_per_mtok"], "0.2")

    def test_liquidity_filter_excludes_endpoints_below_minimum_request_count(self):
        # The floor used to be model-relative:
        # liquidity_volume_floor(model_tokens_30d) = max(1_000_000, tokens/20),
        # applied against each endpoint's own 30-day completion-token volume.
        # That function and the per-model volume input are both gone. The
        # floor is now the fixed policy value min_endpoint_request_count_30m,
        # applied against each endpoint's 30-minute request_count -- an
        # endpoint below the caller-supplied threshold is excluded even though
        # it is otherwise a valid, actively priced endpoint.
        document = {"data": {"id": "example/model", "endpoints": [
            {"provider_name": "BelowThreshold", "status": 0, "perf_last_30m_by_workload": {"text_generation": {"request_count": 999}}, "pricing": {"prompt": "0.00000010", "completion": "0.00000020"}},
            {"provider_name": "AtThreshold", "status": 0, "perf_last_30m_by_workload": {"text_generation": {"request_count": 1000}}, "pricing": {"prompt": "0.00000030", "completion": "0.00000040"}},
        ]}}
        pricing = engine.cheapest_endpoint_pricing(document, "example/model", min_request_count_30m=1000)
        self.assertEqual(pricing["liquidity_filter"]["minimum_request_count_last_30m"], 1000)
        self.assertEqual(
            [candidate["provider_name"] for candidate in pricing["liquidity_filter"]["eligible_endpoint_liquidity"]],
            ["AtThreshold"],
        )
        self.assertEqual(pricing["benchmark_provider"], "AtThreshold")

    def test_free_variant_positive_prices_are_not_liquid(self):
        document = {"data": {"id": "example/model:free", "endpoints": [
            {
                "provider_name": "FreeVariant", "status": 0,
                "perf_last_30m_by_workload": {"text_generation": {"request_count": 5_000_000}},
                "pricing": {"prompt": "0.1", "completion": "0.2"},
            },
        ]}}
        self.assertIsNone(engine.cheapest_endpoint_pricing(document, "example/model:free"))

    def test_mapped_free_variant_is_skipped_not_fatal(self):
        # A :free permaslug that reaches the mapped cohort is dropped before the
        # endpoint fetch, and the rest of the top-N still produces a valid
        # snapshot instead of aborting the entire run.
        rankings, models, endpoints = self.expanded_inputs()
        for row in rankings["data"]:
            if row["model_permaslug"] == "openai/gpt-oss-20b":
                row["model_permaslug"] = "openai/gpt-oss-20b:free"
        models["data"][0]["id"] = "openai/gpt-oss-20b:free"
        models["data"][0]["canonical_slug"] = "openai/gpt-oss-20b"
        # The :free slug is skipped before the endpoint fetch, so its endpoint is
        # never requested; drop it from the hand-built endpoints set to mirror the
        # live fetch loop (which only fetches selected, non-free rows).
        endpoints.pop("openai/gpt-oss-20b")
        policy_document = policy()
        policy_document["models"][0] = model("openai/gpt-oss-20b:free", "openai/gpt-oss-20b")
        snapshot = engine.build_snapshot(rankings, models, endpoints, policy_document, now=NOW, top_n=50)
        row_ids = {row["source_model_id"] for row in snapshot["rows"]}
        self.assertNotIn("openai/gpt-oss-20b:free", row_ids)
        self.assertNotIn("openai/gpt-oss-20b", row_ids)
        # The remaining cohort is intact and internally consistent.
        self.assertEqual(len(snapshot["rows"]), len(endpoints))
        self.assertEqual(snapshot["source"]["fetch_metadata"]["observed_model_count"], len(endpoints))

    def _coverage_snapshot(self, observed, skipped_count, *, requested=50, rows=None):
        return {
            "schema_version": engine.SNAPSHOT_SCHEMA_VERSION,
            "rows": rows or [],
            "source": {"fetch_metadata": {
                "requested_top_n": requested,
                "observed_model_count": observed,
                "skipped_free_ranked_models": [
                    {"ranking_model_permaslug": f"v/m{i}:free", "reason": "dropped_free_variant", "rank": i}
                    for i in range(1, skipped_count + 1)
                ],
                "ranking_window_end_date": "2026-08-04",
            }},
        }

    def test_market_peg_coverage_accepts_observed_plus_skipped_covering_topn(self):
        # observed + recorded free drops == requested top-N -> coverage holds.
        engine.validate_market_peg_snapshot_requirements(self._coverage_snapshot(42, 8), policy(), now=NOW)

    def test_market_peg_coverage_rejects_unexplained_shortfall(self):
        # A truncated snapshot (shortfall NOT explained by recorded free drops)
        # must fail closed even though requested_top_n alone is satisfied.
        with self.assertRaisesRegex(engine.SchemaError, "does not cover"):
            engine.validate_market_peg_snapshot_requirements(self._coverage_snapshot(1, 0), policy(), now=NOW)

    def test_market_peg_coverage_rejects_short_requested_cohort(self):
        with self.assertRaisesRegex(engine.SchemaError, "top-demand coverage"):
            engine.validate_market_peg_snapshot_requirements(self._coverage_snapshot(49, 1, requested=49), policy(), now=NOW)

    def test_market_peg_rejects_snapshot_priced_under_a_different_floor(self):
        # A row priced under request-count floor 999 cannot be computed under a
        # policy whose floor is 1: the pricing basis is bound to the compute policy.
        row = {"pricing_status": "active_priced",
               "pricing": {"liquidity_filter": {"minimum_request_count_last_30m": 999, "min_distinct_providers": 1}}}
        snap = self._coverage_snapshot(50, 0, rows=[row])
        with self.assertRaisesRegex(engine.SchemaError, "request-count floor"):
            engine.validate_market_peg_snapshot_requirements(snap, policy(), now=NOW)

    def test_market_peg_rejects_snapshot_priced_under_a_different_quorum(self):
        # A row priced under a 1-provider quorum cannot be computed under a policy
        # that requires 2 distinct providers -- the Sybil quorum is policy-bound
        # exactly like the request-count floor.
        row = {"pricing_status": "active_priced",
               "pricing": {"liquidity_filter": {"minimum_request_count_last_30m": 1, "min_distinct_providers": 1}}}
        snap = self._coverage_snapshot(50, 0, rows=[row])
        quorum_policy = policy()
        quorum_policy["min_distinct_providers"] = 2
        with self.assertRaisesRegex(engine.SchemaError, "distinct-provider quorum"):
            engine.validate_market_peg_snapshot_requirements(snap, quorum_policy, now=NOW)

    def test_demand_proposal_rejects_invalid_minimum_provider_targets(self):
        with self.assertRaises(engine.SchemaError):
            engine.build_demand_proposal(self.snapshot(), policy(), min_provider_targets={"qwen3-8b": True})
        with self.assertRaises(engine.SchemaError):
            engine.build_demand_proposal(self.snapshot(), policy(), min_provider_targets={})

    def test_demand_proposal_fails_absent_recommendable_mapping(self):
        policy_document = policy()
        absent = model("example/absent", "example/absent")
        policy_document["models"].append(absent)
        targets = {model["canonical_model_id"]: 15 for model in policy_document["models"]}
        catalog = json.loads((FIXTURES / "recommendable-catalog.json").read_text(encoding="utf-8"))
        original_catalog = json.dumps(catalog)
        catalog["rows"]["example/absent"] = {"runtime_status": "recommendable"}
        fixture_path = FIXTURES / "recommendable-catalog.json"
        fixture_path.write_text(json.dumps(catalog))
        try:
            with self.assertRaisesRegex(engine.SchemaError, "market-pegged compute emits no proposals"):
                engine.build_demand_proposal(
                    self.snapshot(),
                    policy_document,
                    min_provider_targets=targets,
                    catalog_path=fixture_path,
                    now=NOW,
                )
        finally:
            fixture_path.write_text(original_catalog)

    def test_normalize_min_provider_targets_skips_listed_demand_rank_rows(self):
        targets = production_min_provider_targets()
        self.assertEqual(set(targets), production_recommendable_keys())
        self.assertNotIn("qwen/qwen3.8-27b", targets)
        self.assertNotIn("z-ai/glm-4.5-air", targets)

    def test_demand_proposal_defaults_to_real_production_catalog(self):
        production_policy = json.loads((SCRIPTS / "openrouter_pricing_policy.json").read_text(encoding="utf-8"))
        min_targets = production_min_provider_targets()
        proposal = engine.build_demand_proposal(
            synthetic_production_market_snapshot(),
            production_policy,
            min_provider_targets=min_targets,
            now=NOW,
        )
        self.assertEqual(set(proposal["rows"]), set(min_targets))
        self.assertNotIn("example/new-model", proposal["rows"])
        self.assertTrue(engine.PRODUCTION_CATALOG_PATH.exists())

    def test_engine_rejects_published_snapshot_fields_in_feed_schema_a(self):
        card = reference_rate_card()
        card["source_snapshot"] = {"content_digest": "sha256:" + "a" * 64}
        with self.assertRaises(engine.SchemaError):
            engine.validate_rate_card(card)

    def test_rate_card_reference_is_not_mutated(self):
        card = reference_rate_card()
        original = json.dumps(card, sort_keys=True)
        engine.build_proposal(self.snapshot(), policy(), card, now=NOW)
        self.assertEqual(json.dumps(card, sort_keys=True), original)


if __name__ == "__main__":
    unittest.main()
