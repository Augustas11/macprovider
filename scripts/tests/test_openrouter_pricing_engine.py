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
NOW = datetime(2026, 8, 5, 12, 0, 0, tzinfo=timezone.utc)


def fixture(name: str):
    return json.loads((FIXTURES / name).read_text(encoding="utf-8"))


def policy():
    value = {
        "policy_version": "unit-test-v1",
        "demand_top_n": 100,
        "broad_fleet_undercut_fraction": "0.20",
        "coding_minimum_undercut_fraction": "0.10",
        "coding_premium_fraction": "0.10",
        "models": [
            model("openai/gpt-oss-20b", "openai/gpt-oss-20b"),
            model("google/gemma-4-26b-a4b-it", "google-gemma-4-26b-a4b-it"),
            model("nvidia/nemotron-3-nano-30b-a3b", "nemotron-3-nano-30b-a3b"),
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
            "nemotron-3-nano-30b-a3b": row(160000),
            "qwen2.5-coder-32b-instruct": row(850000),
        },
    }


class FakeHTTPClient:
    def __init__(self, responses):
        self.responses = {url: list(values) for url, values in responses.items()}

    def get(self, url, timeout_seconds):
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
    def __init__(self, host, timeout):
        self.host = host
        self.timeout = timeout
        self.sock = None
        self.closed = False

    def request(self, method, target, headers):
        self.target = target

    def getresponse(self):
        return FakeProductionResponse()

    def close(self):
        self.closed = True


class OpenRouterPricingEngineTests(unittest.TestCase):
    def setUp(self):
        self.rankings = fixture("rankings.json")
        self.models = fixture("models.json")
        self.endpoints = fixture("endpoints.json")

    def expanded_inputs(self):
        rankings = copy.deepcopy(self.rankings)
        models = copy.deepcopy(self.models)
        endpoints = copy.deepcopy(self.endpoints)
        template_endpoint = copy.deepcopy(endpoints["example/new-model"])
        for index in range(5, 101):
            model_id = f"unknown/model-{index}"
            rankings["data"].append({"date": "2026-08-03 00:00:00", "model_permaslug": model_id, "variant": "standard", "total_completion_tokens": 700 - index})
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
            top_n=100,
        )

    def test_normalization_emits_stable_digest_and_cheapest_active_pricing(self):
        first = self.snapshot()
        rankings, models, endpoints = self.expanded_inputs()
        second = engine.build_snapshot(rankings, models, endpoints, policy(), now=NOW.replace(hour=13), top_n=100)
        self.assertEqual(first["content_digest"], second["content_digest"])
        self.assertEqual(first["rows"][0]["demand"]["completion_volume"], "1025")
        self.assertEqual(first["rows"][0]["pricing"]["benchmark_provider"], "CoreWeave")
        self.assertEqual(first["rows"][0]["pricing"]["completion_per_mtok"], "0.13")
        self.assertEqual(first["rows"][2]["canonical_model_id"], "nemotron-3-nano-30b-a3b")
        engine.validate_snapshot(first)

    def test_recorded_openrouter_rankings_excerpt_fixture_is_normalizable_offline(self):
        recorded = fixture("recorded-rankings-response-excerpt.json")
        self.assertEqual(recorded["recording"]["source_url"], engine.RANKINGS_URL)
        self.assertTrue(recorded["recording"]["full_response_sha256"].startswith("sha256:"))
        normalized = engine.normalize_rankings(recorded["response"], top_n=1)
        self.assertEqual(normalized[0]["source_model_id"], "deepseek/deepseek-v4-flash-20260731")

    def test_catalog_alias_resolution_preserves_ranking_provenance_and_ignores_zero_completion_nonmodels(self):
        rankings = {"data": [
            {"date": "2026-08-03 00:00:00", "model_permaslug": "example/old-model-20260101", "total_completion_tokens": 5},
            {"date": "2026-08-03 00:00:00", "model_permaslug": "embedding-only", "total_completion_tokens": 0},
        ]}
        catalog = {"data": [{"id": "example/current-model", "canonical_slug": "example/old-model-20260101", "pricing": None}]}
        endpoints = {"example/current-model": {"data": {"id": "example/current-model", "endpoints": [{"provider_name": "Provider", "status": 0, "pricing": {"prompt": "0.1", "completion": "0.2"}}]}}}
        policy_document = policy()
        policy_document["models"] = []
        snapshot = engine.build_snapshot(rankings, catalog, endpoints, policy_document, now=NOW, top_n=1)
        self.assertEqual(snapshot["rows"][0]["source_model_id"], "example/current-model")
        self.assertEqual(snapshot["rows"][0]["source_metadata"]["ranking_model_permaslug"], "example/old-model-20260101")

    def test_catalog_alias_resolution_prefers_only_paid_variant_over_explicit_free_variant(self):
        rankings = [{"source_model_id": "google/gemma-4-31b-it-20260402", "rank": 1, "completion_volume": "10", "ranking_date": "2026-08-04 00:00:00"}]
        catalog = {
            "google/gemma-4-31b-it": {"canonical_slug": "google/gemma-4-31b-it-20260402"},
            "google/gemma-4-31b-it:free": {"canonical_slug": "google/gemma-4-31b-it-20260402"},
        }
        resolved = engine.resolve_rankings_to_catalog(rankings, catalog)
        self.assertEqual(resolved[0]["source_model_id"], "google/gemma-4-31b-it")
        self.assertEqual(resolved[0]["ranking_model_permaslug"], "google/gemma-4-31b-it-20260402")

    def test_catalog_missing_dated_ranking_uses_endpoint_confirmed_alias(self):
        rankings = {"data": [{"date": "2026-08-04 00:00:00", "model_permaslug": "bytedance-seed/seedream-4.5-20251203", "total_completion_tokens": 10}]}
        catalog = {"data": [{"id": "example/other", "canonical_slug": "example/other", "pricing": None}]}
        endpoints = {
            "bytedance-seed/seedream-4.5-20251203": {
                "data": {
                    "id": "bytedance-seed/seedream-4.5",
                    "endpoints": [{"provider_name": "Provider", "status": 0, "pricing": {"prompt": "0.1", "completion": "0.2"}}],
                }
            }
        }
        policy_document = policy()
        policy_document["models"] = []
        snapshot = engine.build_snapshot(rankings, catalog, endpoints, policy_document, now=NOW, top_n=1)
        self.assertEqual(snapshot["rows"][0]["source_model_id"], "bytedance-seed/seedream-4.5")
        self.assertEqual(snapshot["rows"][0]["source_metadata"]["identity_resolution"], "endpoint_alias_fallback")
        self.assertIsNone(snapshot["rows"][0]["source_metadata"]["catalog_name"])

    def test_no_active_priced_endpoint_is_snapshotted_and_blocked_not_dropped(self):
        rankings, models, endpoints = self.expanded_inputs()
        endpoints["openai/gpt-oss-20b"]["data"]["endpoints"][0]["status"] = -2
        snapshot = engine.build_snapshot(rankings, models, endpoints, policy(), now=NOW, top_n=100)
        row = next(item for item in snapshot["rows"] if item["source_model_id"] == "openai/gpt-oss-20b")
        self.assertEqual(row["pricing_status"], "no_active_priced_endpoint")
        self.assertIsNone(row["pricing"])
        proposal = engine.build_proposal(snapshot, policy(), reference_rate_card(), now=NOW)
        blocked = next(item for item in proposal["blocked"] if item["model_id"] == "openai/gpt-oss-20b")
        self.assertIn("no active priced OpenRouter endpoint is available", blocked["reasons"])

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
        self.assertEqual(engine.retry_after_seconds({"Retry-After": "Wed, 05 Aug 2026 12:02:00 GMT"}, now=NOW), 120.0)
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
        with patch.object(engine.http.client, "HTTPSConnection", FakeProductionConnection):
            client = engine.UrllibHTTPClient(resolver=lambda timeout: ["127.0.0.1", "127.0.0.2"])
            response = client.get("https://openrouter.ai/api/v1/models", 1)
            second_response = client.get("https://openrouter.ai/api/v1/models", 1)
        self.assertEqual(response.status, 200)
        self.assertEqual(response.body, b'{"data": []}')
        self.assertEqual(second_response.status, 200)
        self.assertEqual(client._next_address_index, 2)

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
        empty_pricing = copy.deepcopy(self.endpoints)
        empty_pricing["openai/gpt-oss-20b"]["data"]["endpoints"] = []
        with self.assertRaises(engine.SchemaError):
            engine.build_snapshot(self.rankings, self.models, empty_pricing, policy(), now=NOW, top_n=4)
        invalid = copy.deepcopy(self.endpoints)
        invalid["openai/gpt-oss-20b"]["data"]["endpoints"][0]["pricing"]["completion"] = "-1"
        with self.assertRaises(engine.SchemaError):
            engine.build_snapshot(self.rankings, self.models, invalid, policy(), now=NOW, top_n=4)
        malformed_date = copy.deepcopy(self.rankings)
        malformed_date["data"][0]["date"] = "zzzz"
        with self.assertRaises(engine.SchemaError):
            engine.build_snapshot(malformed_date, self.models, self.endpoints, policy(), now=NOW, top_n=4)
        invalid_status = copy.deepcopy(self.endpoints)
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

    def test_proposal_contains_added_changed_dropped_unchanged_and_blocked(self):
        proposal_policy = policy()
        proposal_policy["models"][2]["license"]["commercial_permitted"] = False
        snapshot = self.snapshot(proposal_policy)
        proposal = engine.build_proposal(snapshot, proposal_policy, reference_rate_card(), now=NOW)
        self.assertEqual([row["model_id"] for row in proposal["changed"]], ["openai/gpt-oss-20b"])
        self.assertEqual([row["model_id"] for row in proposal["unchanged"]], ["google-gemma-4-26b-a4b-it"])
        self.assertEqual([row["model_id"] for row in proposal["added"]], ["example/new-model"])
        self.assertEqual({row["model_id"] for row in proposal["dropped"]}, {"qwen2.5-coder-32b-instruct"})
        self.assertEqual(len(proposal["blocked"]), 97)
        nemotron = next(row for row in proposal["blocked"] if row["model_id"] == "nemotron-3-nano-30b-a3b")
        self.assertTrue(nemotron["policy_evidence"]["available"])
        self.assertEqual(proposal["changed"][0]["proposed_completion_rate"]["rate_card_completion_rate_per_mtok"], 104000)

    def test_fixed_snapshot_policy_and_rate_card_emit_the_expected_complete_proposal(self):
        first = engine.build_proposal(self.snapshot(), policy(), reference_rate_card(), now=NOW)
        second = engine.build_proposal(self.snapshot(), policy(), reference_rate_card(), now=NOW)
        self.assertEqual(first, second)
        self.assertEqual(
            engine.sha256_prefixed(first),
            "sha256:f2bf173cb25013aa799bc25e04065a168156cbebc4a9425604760ff83bcd8039",
        )

    def test_unresolved_nemotron_license_is_blocked_when_not_a_current_row(self):
        proposal_policy = policy()
        proposal_policy["models"][2]["license"]["commercial_permitted"] = False
        card = reference_rate_card()
        del card["rows"]["nemotron-3-nano-30b-a3b"]
        proposal = engine.build_proposal(self.snapshot(proposal_policy), proposal_policy, card, now=NOW)
        self.assertIn("nemotron-3-nano-30b-a3b", {row["model_id"] for row in proposal["blocked"]})

    def test_snapshot_tampering_and_invalid_policy_are_rejected(self):
        snapshot = self.snapshot()
        snapshot["rows"][0]["pricing"]["completion_per_mtok"] = "999"
        with self.assertRaises(engine.SchemaError):
            engine.build_proposal(snapshot, policy(), reference_rate_card(), now=NOW)
        invalid_policy = policy()
        invalid_policy["broad_fleet_undercut_fraction"] = "0.50"
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

    def test_unverified_serving_path_is_a_per_model_block_not_a_global_policy_error(self):
        proposal_policy = policy()
        proposal_policy["models"][0]["serving_path"]["verification_status"] = "unverified"
        card = reference_rate_card()
        del card["rows"]["openai/gpt-oss-20b"]
        proposal = engine.build_proposal(self.snapshot(proposal_policy), proposal_policy, card, now=NOW)
        blocked = next(row for row in proposal["blocked"] if row["model_id"] == "openai/gpt-oss-20b")
        self.assertIn("MLX/GGUF serving path is not verified", blocked["reasons"])

    def test_rate_card_conversion_and_provider_share_control_internal_rate_and_coding_floor(self):
        card = reference_rate_card()
        card["usd_per_million_credits"] = 2.0
        card["rows"]["default"]["global_multiplier_ppm"] = 2000000
        card["rows"]["default"]["provider_share_bps"] = 5000
        self.assertEqual(engine.completion_rate_to_internal(engine.Decimal("0.20"), card, "not-present"), 50000)
        coding = model("example/new-model", "example/new-model")
        coding.update({"coding_specialist": True, "general_purpose_baseline_per_mtok": "0.220"})
        coding["profile"] = {"kind": "coding_dense", "active_params_b": "32", "residency_gb": "17", "projected_tps": "200"}
        with self.assertRaises(engine.SchemaError):
            engine.proposed_completion_price(coding, engine.Decimal("0.25"), policy(), card, "example/new-model")

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

    def test_orchestration_failure_writes_no_final_snapshot(self):
        with tempfile.TemporaryDirectory() as temporary:
            client = FakeHTTPClient({engine.RANKINGS_URL: [engine.HTTPResponse(200, b"{", {})]})
            with self.assertRaises(engine.SchemaError):
                engine.fetch_live_snapshot(policy(), output_dir=Path(temporary), top_n=4, retries=0, timeout_seconds=1, client=client, now=lambda: NOW, sleeper=lambda _: None)
            self.assertEqual(list(Path(temporary).iterdir()), [])

    def test_current_rate_card_row_without_policy_mapping_is_explicitly_blocked(self):
        card = reference_rate_card()
        card["rows"]["unassessed-model"] = {"prompt_rate_per_mtok": 50, "prompt_cache_hit_rate_per_mtok": 12, "completion_rate_per_mtok": 123, "provider_share_bps": 9000, "global_multiplier_ppm": 1000000}
        proposal = engine.build_proposal(self.snapshot(), policy(), card, now=NOW)
        row = next(item for item in proposal["blocked"] if item["model_id"] == "unassessed-model")
        self.assertEqual(row["current_completion_rate"]["rate_card_completion_rate_per_mtok"], 123)

    def test_rate_card_reference_is_not_mutated(self):
        card = reference_rate_card()
        original = json.dumps(card, sort_keys=True)
        engine.build_proposal(self.snapshot(), policy(), card, now=NOW)
        self.assertEqual(json.dumps(card, sort_keys=True), original)


if __name__ == "__main__":
    unittest.main()
