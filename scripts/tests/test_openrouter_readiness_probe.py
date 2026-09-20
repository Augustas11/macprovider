#!/usr/bin/env python3
"""Offline tests for the OpenRouter readiness probe."""

from __future__ import annotations

import copy
import json
import os
import sys
import tempfile
import threading
import unittest
import uuid
from unittest import mock
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
SCRIPTS = ROOT / "scripts"
if str(SCRIPTS) not in sys.path:
    sys.path.insert(0, str(SCRIPTS))

import openrouter_readiness_probe as probe  # noqa: E402


class FakeHTTPResponse:
    def __init__(self, body: bytes, status: int = 200, content_type: str = "application/json"):
        self._body = body
        self.status = status
        self.headers = {"Content-Type": content_type}

    def __enter__(self):
        return self

    def __exit__(self, exc_type, exc, tb):
        return False

    def read(self):
        return self._body

    def __iter__(self):
        return iter(self._body.splitlines(keepends=True))


def sse_response(lines: list[str]) -> FakeHTTPResponse:
    return FakeHTTPResponse("".join(lines).encode("utf-8"), content_type="text/event-stream")


class BlockingStreamResponse:
    status = 200

    def __init__(self):
        self.closed = False
        self._closed = threading.Event()

    def __iter__(self):
        return self

    def __next__(self):
        if self._closed.wait(timeout=5):
            raise StopIteration
        raise TimeoutError("blocking stream was not closed")

    def close(self):
        self.closed = True
        self._closed.set()


def valid_doc():
    return {
        "data": [
            {
                "schema_version": "2.4",
                "id": "mlx-community/Llama-3.2-3B-Instruct-4bit",
                "name": "Llama 3.2 3B Instruct (4-bit)",
                "created": 1729728000,
                "quantization": "int4",
                "tokenizer": "Llama3",
                "hugging_face_id": "mlx-community/Llama-3.2-3B-Instruct-4bit",
                "input_modalities": [
                    {
                        "type": "text",
                        "supported_inputs": {"max_context_length": {"value": 50000, "unit": "token"}},
                        "pricing": [{"type": "prompt", "unit": "token", "cost_usd": "0.0000000135"}],
                        "capacity": [{"type": "prompt", "unit": "token", "per": "minute", "value": 24576}],
                    }
                ],
                "output_modalities": [
                    {
                        "type": "text",
                        "max_length": {"value": 4096, "unit": "token"},
                        "streaming": True,
                        "supported_parameters": {
                            "max_tokens": {"type": "integer", "min": 1, "max": 4096, "unit": "token"},
                            "temperature": {"type": "range", "min": 0, "max": 2},
                            "top_p": {"type": "range", "min": 0, "max": 1},
                            "stop": {"type": "array", "max_items": 4},
                            "stream": {"type": "boolean"},
                        },
                        "pricing": [{"type": "completion", "unit": "token", "cost_usd": "0.000000027"}],
                        "capacity": [{"type": "completion", "unit": "token", "per": "minute", "value": 24576}],
                    }
                ],
                "capacity": [
                    {"type": "request", "unit": "request", "per": "minute", "value": 6},
                    {"type": "concurrency", "unit": "request", "value": 1},
                ],
                "deployment_region": "global-volunteer-fleet",
                "compliance": {"zdr": False},
                "is_ready": True,
                "is_free": False,
                "openrouter": {"slug": "meta-llama/llama-3.2-3b-instruct"},
            }
        ]
    }


def wholesale_line(
    model: str = "paid-model",
    *,
    is_free: bool = False,
    request_count: int = 1,
    prompt_tokens: int = 2,
    completion_tokens: int = 3,
    gross_credits: int = 10,
    usd_micro: int = 10,
) -> dict:
    return {
        "model": model,
        "is_free": is_free,
        "request_count": request_count,
        "prompt_tokens": prompt_tokens,
        "completion_tokens": completion_tokens,
        "gross_credits": gross_credits,
        "usd_micro": usd_micro,
        "usd": probe.usd_micro_string(usd_micro),
    }


def wholesale_statement(line_items: list[dict]) -> dict:
    total_usd_micro = sum(item["usd_micro"] for item in line_items)
    return {
        "wholesale_statement_id": "stmt_1",
        "account_id": "acct_openrouter",
        "period": "2026-09",
        "request_count": sum(item["request_count"] for item in line_items),
        "prompt_tokens": sum(item["prompt_tokens"] for item in line_items),
        "completion_tokens": sum(item["completion_tokens"] for item in line_items),
        "gross_credits": sum(item["gross_credits"] for item in line_items),
        "usd_micro": total_usd_micro,
        "usd": probe.usd_micro_string(total_usd_micro),
        "line_items": line_items,
    }


def ready_pool(slots: int = 4) -> dict:
    return {
        "classification": "model_pool_ready",
        "matching_slots_total": slots,
        "matching_slots_free": slots,
    }


def valid_filing_doc():
    doc = valid_doc()
    free = copy.deepcopy(doc["data"][0])
    free["id"] += "-free"
    free["is_free"] = True
    free["is_ready"] = True
    free["openrouter"]["slug"] += ":free"
    free["input_modalities"][0]["pricing"][0]["cost_usd"] = "0"
    free["output_modalities"][0]["pricing"][0]["cost_usd"] = "0"
    doc["data"].append(free)
    return doc


class OpenRouterReadinessProbeTests(unittest.TestCase):
    def test_valid_schema_24_native_document_passes(self):
        got = probe.check_models_document(valid_doc(), "mlx-community/Llama-3.2-3B-Instruct-4bit")
        self.assertEqual(got["rows"], 1)
        self.assertEqual(got["ids"], ["mlx-community/Llama-3.2-3B-Instruct-4bit"])
        self.assertEqual(got["catalog_paid_rows"], 17)
        self.assertEqual(got["catalog_listed_ids"], ["mlx-community/Llama-3.2-3B-Instruct-4bit"])
        self.assertEqual(len(got["catalog_unlisted_ids"]), 16)

    def test_expected_openrouter_slugs_cover_current_catalog(self):
        catalog = json.loads(probe.DEFAULT_CATALOG_PATH.read_text())
        self.assertEqual(catalog["version"], "published-2026-09-19-openrouter-priced-v1")
        recommendable = {
            row["model_id"]
            for row in catalog["rows"].values()
            if row.get("runtime_status") == "recommendable"
        }
        self.assertEqual(len(recommendable), 17)
        self.assertEqual(set(probe.catalog_paid_model_ids()), recommendable)
        for catalog_key, row in catalog["rows"].items():
            self.assertEqual(probe.CATALOG_KEY_TO_MODEL_ID[catalog_key], row["model_id"])
            self.assertIn(row["model_id"], probe.EXPECTED_OPENROUTER_SLUGS)
            slug = probe.EXPECTED_OPENROUTER_SLUGS[row["model_id"]]
            self.assertTrue("/" in slug, msg=f"{row['model_id']} slug {slug!r} must be org-prefixed")
            self.assertNotEqual(slug, row["model_id"])

    def test_resolve_probe_model_accepts_catalog_keys_and_studio_rows(self):
        self.assertEqual(
            probe.resolve_probe_model("qwen3-coder-30b-a3b-instruct"),
            "mlx-community/Qwen3-Coder-30B-A3B-Instruct-4bit",
        )
        self.assertEqual(
            probe.resolve_probe_model("z-ai/glm-4.5-air"),
            "mlx-community/GLM-4.5-Air-4bit",
        )
        self.assertEqual(
            probe.resolve_probe_model("openai/gpt-oss-120b"),
            "mlx-community/gpt-oss-120b-4bit",
        )
        self.assertEqual(
            probe.EXPECTED_OPENROUTER_SLUGS["mlx-community/Qwen3.5-27B-4bit"],
            "qwen/qwen3.5-27b",
        )
        self.assertTrue(
            probe.models_equivalent("qwen3-coder-30b-a3b-instruct", "mlx-community/Qwen3-Coder-30B-A3B-Instruct-4bit")
        )

    def test_check_models_document_resolves_catalog_key(self):
        got = probe.check_models_document(valid_doc(), "meta-llama/llama-3.2-3b-instruct")
        self.assertEqual(got["ids"], ["mlx-community/Llama-3.2-3B-Instruct-4bit"])

    def test_catalog_chat_treats_unserved_models_as_coverage_not_failure(self):
        def fake_chat(_base, _token, model, **_kwargs):
            if model == "mlx-community/Llama-3.2-3B-Instruct-4bit":
                return {"status": 200, "ok": True, "latency_ms": 10, "error_code": ""}
            return {"status": 503, "ok": False, "latency_ms": 5, "error_code": "no_provider_available"}

        with mock.patch.object(probe, "chat_once", side_effect=fake_chat):
            got = probe.check_catalog_chat("https://api.example.test", "token", 16)
        self.assertTrue(got["ok"])
        self.assertEqual(got["catalog_paid_rows"], 17)
        self.assertEqual(got["passed"], ["mlx-community/Llama-3.2-3B-Instruct-4bit"])
        self.assertEqual(len(got["not_served"]), 16)
        self.assertEqual(got["failed"], [])

    def test_catalog_chat_fails_closed_on_non_capacity_errors(self):
        def fake_chat(_base, _token, model, **_kwargs):
            if model == "mlx-community/Llama-3.2-3B-Instruct-4bit":
                return {"status": 200, "ok": True, "latency_ms": 10, "error_code": ""}
            if model == "mlx-community/GLM-4.5-Air-4bit":
                return {"status": 502, "ok": False, "latency_ms": 5, "error_code": "upstream_provider_error"}
            return {"status": 503, "ok": False, "latency_ms": 5, "error_code": "no_provider_available"}

        with mock.patch.object(probe, "chat_once", side_effect=fake_chat):
            with self.assertRaisesRegex(probe.EvidenceProbeError, "catalog chat failed"):
                probe.check_catalog_chat("https://api.example.test", "token", 16)

    def test_catalog_chat_fails_closed_on_502_capacity_error_code(self):
        def fake_chat(_base, _token, model, **_kwargs):
            if model == "mlx-community/Llama-3.2-3B-Instruct-4bit":
                return {"status": 200, "ok": True, "latency_ms": 10, "error_code": ""}
            if model == "mlx-community/GLM-4.5-Air-4bit":
                return {"status": 502, "ok": False, "latency_ms": 5, "error_code": "no_provider_available"}
            return {"status": 404, "ok": False, "latency_ms": 5, "error_code": "model_not_found"}

        with mock.patch.object(probe, "chat_once", side_effect=fake_chat):
            with self.assertRaisesRegex(probe.EvidenceProbeError, "catalog chat failed"):
                probe.check_catalog_chat("https://api.example.test", "token", 16)

    def test_models_document_rejects_duplicate_model_ids(self):
        doc = valid_doc()
        doc["data"].append(copy.deepcopy(doc["data"][0]))
        with self.assertRaisesRegex(probe.ProbeError, "duplicate model id"):
            probe.check_models_document(doc)

    def test_models_document_rejects_boolean_capacity_and_context_values(self):
        doc = valid_doc()
        doc["data"][0]["capacity"][0]["value"] = True
        with self.assertRaisesRegex(probe.ProbeError, "positive integer"):
            probe.check_models_document(doc)
        doc = valid_doc()
        doc["data"][0]["capacity"][0]["type"] = "nonsense"
        with self.assertRaisesRegex(probe.ProbeError, "type"):
            probe.check_models_document(doc)
        doc = valid_doc()
        doc["data"][0]["capacity"] = [doc["data"][0]["capacity"][0]]
        with self.assertRaisesRegex(probe.ProbeError, "capacity types"):
            probe.check_models_document(doc)
        doc = valid_doc()
        doc["data"][0]["input_modalities"][0]["supported_inputs"]["max_context_length"]["value"] = True
        with self.assertRaisesRegex(probe.ProbeError, "max_context_length"):
            probe.check_models_document(doc)
        doc = valid_doc()
        del doc["data"][0]["output_modalities"][0]["max_length"]
        with self.assertRaisesRegex(probe.ProbeError, "max_length"):
            probe.check_models_document(doc)
        doc = valid_doc()
        doc["data"][0]["output_modalities"][0]["max_length"]["value"] = True
        with self.assertRaisesRegex(probe.ProbeError, "max_length"):
            probe.check_models_document(doc)
        doc = valid_doc()
        doc["data"][0]["input_modalities"][0]["pricing"][0]["type"] = "completion"
        with self.assertRaisesRegex(probe.ProbeError, "pricing type"):
            probe.check_models_document(doc)
        doc = valid_doc()
        doc["data"][0]["input_modalities"][0]["pricing"][0]["unit"] = "character"
        with self.assertRaisesRegex(probe.ProbeError, "pricing unit"):
            probe.check_models_document(doc)
        doc = valid_doc()
        doc["data"][0]["output_modalities"][0]["streaming"] = False
        with self.assertRaisesRegex(probe.ProbeError, "streaming"):
            probe.check_models_document(doc)
        doc = valid_doc()
        doc["data"][0]["output_modalities"][0]["supported_parameters"]["max_tokens"] = "yes"
        with self.assertRaisesRegex(probe.ProbeError, "max_tokens"):
            probe.check_models_document(doc)
        doc = valid_doc()
        doc["data"][0]["id"] = True
        with self.assertRaisesRegex(probe.ProbeError, "string id"):
            probe.check_models_document(doc)

    def test_models_document_must_include_requested_paid_model(self):
        doc = valid_doc()
        doc["data"][0]["id"] = "other-model"
        with self.assertRaisesRegex(probe.ProbeError, "missing requested model"):
            probe.check_models_document(doc, "mlx-community/Llama-3.2-3B-Instruct-4bit")

    def test_legacy_model_document_fails(self):
        doc = valid_doc()
        row = doc["data"][0]
        row["architecture"] = {"input_modalities": ["text"], "output_modalities": ["text"]}
        row["cost_usd"] = {"prompt": "0.1", "completion": "0.1"}
        with self.assertRaisesRegex(probe.ProbeError, "forbidden root keys"):
            probe.check_models_document(doc)

    def test_missing_capacity_fails(self):
        doc = valid_doc()
        del doc["data"][0]["capacity"]
        with self.assertRaisesRegex(probe.ProbeError, "capacity"):
            probe.check_models_document(doc)

    def test_capacity_rejects_duplicates_and_windowed_concurrency(self):
        doc = valid_doc()
        doc["data"][0]["capacity"].append({"type": "request", "unit": "request", "per": "minute", "value": 1})
        with self.assertRaisesRegex(probe.ProbeError, "duplicate capacity type"):
            probe.check_models_document(doc)
        doc = valid_doc()
        for entry in doc["data"][0]["capacity"]:
            if entry["type"] == "concurrency":
                entry["per"] = "minute"
        with self.assertRaisesRegex(probe.ProbeError, "concurrency entries must not declare a per window"):
            probe.check_models_document(doc)

    def test_filing_capacity_must_match_live_pool_slots(self):
        models = probe.check_models_document(
            valid_filing_doc(),
            "mlx-community/Llama-3.2-3B-Instruct-4bit",
            True,
        )
        got = probe.check_model_capacity_against_pool(
            models,
            ready_pool(4),
            "mlx-community/Llama-3.2-3B-Instruct-4bit",
        )
        self.assertEqual(got["classification"], "model_capacity_consistent")
        fantasy = valid_filing_doc()
        for row in fantasy["data"]:
            for entry in row["capacity"]:
                entry["value"] = 10**18
            for entry in row["input_modalities"][0]["capacity"]:
                entry["value"] = 10**18
            for entry in row["output_modalities"][0]["capacity"]:
                entry["value"] = 10**18
        models = probe.check_models_document(
            fantasy,
            "mlx-community/Llama-3.2-3B-Instruct-4bit",
            True,
        )
        with self.assertRaisesRegex(probe.EvidenceProbeError, "exceeds"):
            probe.check_model_capacity_against_pool(
                models,
                ready_pool(4),
                "mlx-community/Llama-3.2-3B-Instruct-4bit",
            )

    def test_price_strings_must_be_finite_decimals(self):
        for bad in ("", "-0.1", "NaN", "Infinity", "-Infinity"):
            with self.subTest(bad=bad):
                with self.assertRaises(probe.ProbeError):
                    probe.check_decimal(bad, "cost")

    def test_stream_usage_validator_requires_all_token_counts(self):
        self.assertTrue(probe.usage_is_valid({"prompt_tokens": 1, "completion_tokens": 2, "total_tokens": 3}))
        self.assertFalse(probe.usage_is_valid({"prompt_tokens": 1, "completion_tokens": 2}))
        self.assertFalse(probe.usage_is_valid({"prompt_tokens": 1, "completion_tokens": 2, "total_tokens": 4}))
        self.assertFalse(probe.usage_is_valid({"prompt_tokens": 1, "completion_tokens": True, "total_tokens": 2}))
        self.assertFalse(probe.usage_is_valid({"prompt_tokens": 0, "completion_tokens": 0, "total_tokens": 0}))

    def test_free_row_zero_pricing_is_valid(self):
        doc = valid_doc()
        free = copy.deepcopy(doc["data"][0])
        free["id"] += "-free"
        free["is_free"] = True
        free["openrouter"]["slug"] += ":free"
        free["input_modalities"][0]["pricing"][0]["cost_usd"] = "0"
        free["output_modalities"][0]["pricing"][0]["cost_usd"] = "0"
        doc["data"].append(free)
        got = probe.check_models_document(doc)
        self.assertEqual(got["rows"], 2)

    def test_filing_mode_requires_ready_zero_priced_free_alias(self):
        doc = valid_doc()
        with self.assertRaisesRegex(probe.ProbeError, "missing free alias"):
            probe.check_models_document(doc, "mlx-community/Llama-3.2-3B-Instruct-4bit", True)
        free = copy.deepcopy(doc["data"][0])
        free["id"] += "-free"
        free["is_free"] = True
        free["is_ready"] = True
        free["openrouter"]["slug"] += ":free"
        free["input_modalities"][0]["pricing"][0]["cost_usd"] = "0"
        free["output_modalities"][0]["pricing"][0]["cost_usd"] = "0"
        doc["data"].append(free)
        got = probe.check_models_document(doc, "mlx-community/Llama-3.2-3B-Instruct-4bit", True)
        self.assertEqual(got["rows"], 2)
        zero_paid = copy.deepcopy(doc)
        zero_paid["data"][0]["input_modalities"][0]["pricing"][0]["cost_usd"] = "0"
        zero_paid["data"][0]["output_modalities"][0]["pricing"][0]["cost_usd"] = "0"
        with self.assertRaisesRegex(probe.ProbeError, "paid model pricing"):
            probe.check_models_document(zero_paid, "mlx-community/Llama-3.2-3B-Instruct-4bit", True)
        missing_paid_flag = copy.deepcopy(zero_paid)
        missing_paid_flag["data"][0].pop("is_free")
        with self.assertRaisesRegex(probe.ProbeError, "is_free"):
            probe.check_models_document(missing_paid_flag, "mlx-community/Llama-3.2-3B-Instruct-4bit", True)
        free["is_ready"] = False
        with self.assertRaisesRegex(probe.ProbeError, "is_ready"):
            probe.check_models_document(doc, "mlx-community/Llama-3.2-3B-Instruct-4bit", True)

    def test_deployment_region_must_be_the_honest_volunteer_fleet_descriptor(self):
        doc = valid_doc()
        doc["data"][0]["deployment_region"] = "us-east-1"
        with self.assertRaisesRegex(probe.ProbeError, "global-volunteer-fleet"):
            probe.check_models_document(doc)

    def test_datacenters_are_rejected_until_geography_provenance_exists(self):
        doc = valid_doc()
        doc["data"][0]["datacenters"] = [{"country_code": "US"}]
        with self.assertRaisesRegex(probe.ProbeError, "omit datacenters"):
            probe.check_models_document(doc)

    def test_forbidden_provider_identity_keys_fail_recursively(self):
        doc = valid_doc()
        doc["data"][0]["openrouter"]["provider_id"] = "provider-123"
        with self.assertRaisesRegex(probe.ProbeError, "provider_id"):
            probe.check_models_document(doc)

    def test_known_openrouter_slug_must_not_echo_pool_id(self):
        doc = valid_doc()
        doc["data"][0]["openrouter"]["slug"] = doc["data"][0]["id"]
        with self.assertRaisesRegex(probe.ProbeError, "openrouter.slug"):
            probe.check_models_document(doc)

    def test_http_request_refuses_external_plaintext_bearer(self):
        with self.assertRaisesRegex(probe.ProbeError, "non-HTTPS"):
            probe.http_request("GET", "http://example.com/v1/models", token="secret")

    def test_http_request_refuses_authenticated_redirects(self):
        req = probe.urllib.request.Request("https://api.example.test/v1/chat/completions")
        with self.assertRaisesRegex(probe.ProbeError, "refusing redirect"):
            probe.NoRedirectHandler().redirect_request(req, None, 302, "Found", {}, "https://evil.example.test/")

    def test_http_request_refuses_redirects_for_unauthenticated_requests(self):
        with mock.patch.object(probe.NO_REDIRECT_OPENER, "open", return_value=FakeHTTPResponse(b"{}")) as mocked:
            got = probe.http_request("GET", "https://api.example.test/v1/openrouter/models")
        self.assertIsInstance(got, FakeHTTPResponse)
        self.assertEqual(mocked.call_count, 1)

    def test_http_request_applies_request_id_header(self):
        with mock.patch.object(probe.NO_REDIRECT_OPENER, "open", return_value=FakeHTTPResponse(b"{}")) as mocked:
            probe.http_request("GET", "https://api.example.test/v1/models", request_id="req-test")
        req = mocked.call_args.args[0]
        self.assertEqual(req.get_header("X-request-id"), "req-test")

    def test_healthz_reports_version_and_can_enforce_expected_version(self):
        with mock.patch.object(
            probe,
            "read_json",
            return_value=({"status": "ok", "version": "v1.8.124-9-g14e0159f"}, 200),
        ):
            got = probe.check_healthz("https://api.example.test", "v1.8.124-9-g14e0159f")
        self.assertEqual(got["version"], "v1.8.124-9-g14e0159f")
        self.assertEqual(got["expected_version"], "v1.8.124-9-g14e0159f")

    def test_healthz_expected_version_mismatch_fails(self):
        with mock.patch.object(
            probe,
            "read_json",
            return_value=({"status": "ok", "version": "v1.8.124"}, 200),
        ):
            with self.assertRaisesRegex(probe.ProbeError, "version"):
                probe.check_healthz("https://api.example.test", "v1.8.124-9-g14e0159f")

    def test_read_json_sanitizes_non_2xx_response_bodies(self):
        with mock.patch.object(probe, "http_request", return_value=FakeHTTPResponse(b'{"secret":"do-not-print"}', status=500)):
            with self.assertRaisesRegex(probe.ProbeError, "returned HTTP 500") as caught:
                probe.read_json("POST", "https://admin.example.test/admin/ledger", token="operator")
        self.assertNotIn("do-not-print", str(caught.exception))

    def test_long_stream_without_keepalive_fails_chat_check(self):
        with mock.patch.object(
            probe,
            "chat_once",
            side_effect=[
                {"status": 200, "ok": True, "usage_ok": True, "content_ok": True, "latency_ms": 10, "output_tokens": 1},
                {
                    "status": 200,
                    "ok": True,
                    "usage_ok": True,
                    "content_ok": True,
                    "latency_ms": probe.GATEWAY_KEEPALIVE_TICK_SECONDS * 1000,
                    "keepalive_evidence": "missing",
                },
            ],
        ):
            with self.assertRaisesRegex(probe.ProbeError, "keepalive"):
                probe.check_chat("https://api.example.test", "secret", "model", 16)

    def test_stream_chat_requires_done_sentinel(self):
        stream = sse_response(
            [
                'data: {"choices":[{"delta":{"content":"OK"}}]}\n\n',
                'data: {"usage":{"prompt_tokens":1,"completion_tokens":1,"total_tokens":2},"choices":[]}\n\n',
            ]
        )
        with mock.patch.object(probe, "http_request", return_value=stream):
            got = probe.chat_once("https://api.example.test", "secret", "model", stream=True, max_tokens=16)
        self.assertFalse(got["ok"])
        self.assertFalse(got["done_ok"])

    def test_stream_chat_rejects_error_frames_even_with_content_usage_and_done(self):
        stream = sse_response(
            [
                'data: {"choices":[{"delta":{"content":"OK"}}]}\n\n',
                'data: {"usage":{"prompt_tokens":1,"completion_tokens":1,"total_tokens":2},"choices":[]}\n\n',
                'data: {"error":{"code":"provider_timeout","message":"late provider timeout"}}\n\n',
                "data: [DONE]\n\n",
            ]
        )
        with mock.patch.object(probe, "http_request", return_value=stream):
            got = probe.chat_once("https://api.example.test", "secret", "model", stream=True, max_tokens=16)
        self.assertFalse(got["ok"])
        self.assertFalse(got["stream_error_ok"])
        self.assertEqual(got["error_code"], "provider_timeout")

    def test_chat_rejects_string_error_frames_after_content_and_after_done(self):
        before_done = sse_response(
            [
                'data: {"choices":[{"delta":{"content":"OK"}}]}\n\n',
                'data: {"usage":{"prompt_tokens":1,"completion_tokens":1,"total_tokens":2},"choices":[]}\n\n',
                'data: {"error":"provider timeout"}\n\n',
                "data: [DONE]\n\n",
            ]
        )
        with mock.patch.object(probe, "http_request", return_value=before_done):
            got = probe.chat_once("https://api.example.test", "secret", "model", stream=True, max_tokens=16)
        self.assertFalse(got["ok"])
        self.assertEqual(got["error_code"], "provider timeout")

        after_done = sse_response(
            [
                'data: {"choices":[{"delta":{"content":"OK"}}]}\n\n',
                'data: {"usage":{"prompt_tokens":1,"completion_tokens":1,"total_tokens":2},"choices":[]}\n\n',
                "data: [DONE]\n\n",
                'data: {"error":{"code":"late_error"}}\n\n',
            ]
        )
        with mock.patch.object(probe, "http_request", return_value=after_done):
            got = probe.chat_once("https://api.example.test", "secret", "model", stream=True, max_tokens=16)
        self.assertFalse(got["ok"])
        self.assertEqual(got["error_code"], "data_after_done")

    def test_non_stream_chat_rejects_top_level_error_object(self):
        payload = {
            "choices": [{"message": {"content": "OK"}}],
            "usage": {"prompt_tokens": 1, "completion_tokens": 1, "total_tokens": 2},
            "error": {"code": "provider_timeout"},
        }
        with mock.patch.object(probe, "http_request", return_value=FakeHTTPResponse(json.dumps(payload).encode())):
            got = probe.chat_once("https://api.example.test", "secret", "model", stream=False, max_tokens=16)
        self.assertFalse(got["ok"])
        self.assertFalse(got["response_error_ok"])
        self.assertEqual(got["error_code"], "provider_timeout")

    def test_chat_content_must_be_text(self):
        payload = {
            "choices": [{"message": {"content": True}}],
            "usage": {"prompt_tokens": 1, "completion_tokens": 1, "total_tokens": 2},
        }
        with mock.patch.object(probe, "http_request", return_value=FakeHTTPResponse(json.dumps(payload).encode())):
            got = probe.chat_once("https://api.example.test", "secret", "model", stream=False, max_tokens=16)
        self.assertFalse(got["ok"])
        self.assertFalse(got["content_ok"])

        whitespace_payload = {
            "choices": [{"message": {"content": "   "}}],
            "usage": {"prompt_tokens": 0, "completion_tokens": 0, "total_tokens": 0},
        }
        with mock.patch.object(probe, "http_request", return_value=FakeHTTPResponse(json.dumps(whitespace_payload).encode())):
            got = probe.chat_once("https://api.example.test", "secret", "model", stream=False, max_tokens=16)
        self.assertFalse(got["ok"])
        self.assertFalse(got["content_ok"])
        self.assertFalse(got["usage_ok"])

        with mock.patch.object(
            probe,
            "http_request",
            return_value=FakeHTTPResponse(json.dumps(payload).encode(), content_type="text/plain"),
        ):
            got = probe.chat_once("https://api.example.test", "secret", "model", stream=False, max_tokens=16)
        self.assertFalse(got["ok"])
        self.assertFalse(got["content_type_ok"])

        stream = sse_response(
            [
                'data: {"choices":[{"delta":{"content":true}}]}\n\n',
                'data: {"usage":{"prompt_tokens":1,"completion_tokens":1,"total_tokens":2},"choices":[]}\n\n',
                "data: [DONE]\n\n",
            ]
        )
        with mock.patch.object(probe, "http_request", return_value=stream):
            got = probe.chat_once("https://api.example.test", "secret", "model", stream=True, max_tokens=16)
        self.assertFalse(got["ok"])
        self.assertFalse(got["content_ok"])

        whitespace_stream = sse_response(
            [
                'data: {"choices":[{"delta":{"content":"   "}}]}\n\n',
                'data: {"usage":{"prompt_tokens":0,"completion_tokens":0,"total_tokens":0},"choices":[]}\n\n',
                "data: [DONE]\n\n",
            ]
        )
        with mock.patch.object(probe, "http_request", return_value=whitespace_stream):
            got = probe.chat_once("https://api.example.test", "secret", "model", stream=True, max_tokens=16)
        self.assertFalse(got["ok"])
        self.assertFalse(got["content_ok"])
        self.assertFalse(got["usage_ok"])

        wrong_type_stream = FakeHTTPResponse(
            (
                'data: {"choices":[{"delta":{"content":"OK"}}]}\n\n'
                'data: {"usage":{"prompt_tokens":1,"completion_tokens":1,"total_tokens":2},"choices":[]}\n\n'
                "data: [DONE]\n\n"
            ).encode(),
            content_type="application/json",
        )
        with mock.patch.object(probe, "http_request", return_value=wrong_type_stream):
            got = probe.chat_once("https://api.example.test", "secret", "model", stream=True, max_tokens=16)
        self.assertFalse(got["ok"])
        self.assertFalse(got["content_type_ok"])

    def test_stream_usage_must_be_final_before_done(self):
        usage_before_content = sse_response(
            [
                'data: {"usage":{"prompt_tokens":1,"completion_tokens":1,"total_tokens":2},"choices":[]}\n\n',
                'data: {"choices":[{"delta":{"content":"OK"}}]}\n\n',
                "data: [DONE]\n\n",
            ]
        )
        with mock.patch.object(probe, "http_request", return_value=usage_before_content):
            got = probe.chat_once("https://api.example.test", "secret", "model", stream=True, max_tokens=16)
        self.assertFalse(got["ok"])
        self.assertEqual(got["error_code"], "data_after_usage")

        invalid_usage_after_valid = sse_response(
            [
                'data: {"choices":[{"delta":{"content":"OK"}}]}\n\n',
                'data: {"usage":{"prompt_tokens":1,"completion_tokens":1,"total_tokens":2},"choices":[]}\n\n',
                'data: {"usage":{"prompt_tokens":1,"completion_tokens":true,"total_tokens":2},"choices":[]}\n\n',
                "data: [DONE]\n\n",
            ]
        )
        with mock.patch.object(probe, "http_request", return_value=invalid_usage_after_valid):
            got = probe.chat_once("https://api.example.test", "secret", "model", stream=True, max_tokens=16)
        self.assertFalse(got["ok"])
        self.assertEqual(got["error_code"], "data_after_usage")

    def test_privacy_requires_no_training_and_rejects_zdr_contradictions(self):
        good = (
            "Prompts are plaintext. There is no zero-data-retention guarantee. "
            "## Zero data retention. This heading documents the absence of ZDR. "
            "The OpenRouter ingest document sets compliance.zdr to false. "
            "Request metadata is retained for 90 days. "
            "Mac Provider does not train foundation models on buyer prompts. "
            "Prompt and completion bodies are not stored as a training corpus."
        )
        with mock.patch.object(probe, "http_request", return_value=FakeHTTPResponse(good.encode())):
            got = probe.check_privacy("https://api.example.test")
        self.assertTrue(got["training_corpus_denied"])
        negated_training = good + " Buyer prompts are never used to train models."
        with mock.patch.object(probe, "http_request", return_value=FakeHTTPResponse(negated_training.encode())):
            got = probe.check_privacy("https://api.example.test")
        self.assertTrue(got["training_corpus_denied"])
        negated_records = good + " Prompt records are never used as training material."
        with mock.patch.object(probe, "http_request", return_value=FakeHTTPResponse(negated_records.encode())):
            got = probe.check_privacy("https://api.example.test")
        self.assertTrue(got["training_corpus_denied"])
        bad = good + " compliance.zdr: true"
        with mock.patch.object(probe, "http_request", return_value=FakeHTTPResponse(bad.encode())):
            with self.assertRaisesRegex(probe.ProbeError, "forbidden claim"):
                probe.check_privacy("https://api.example.test")
        contradictions = [
            "Buyer prompts may be used to fine-tune derivative models.",
            "Buyer prompts are eligible for fine-tuning.",
            "We fine-tune derivative models with buyer prompts.",
            "We fine-tune derivative models using buyer prompts.",
            "Buyer prompts sometimes train adapters.",
            "We train adapters on buyer prompts.",
            "Buyer prompts train adapters.",
            "Buyer prompts are retained. We train adapters on that data.",
            "Buyer prompts are retained. We use those records to train our adapters.",
            "Buyer prompts are retained. They become training data for derivative models.",
            "Our current policy enables compliance.zdr for all requests.",
            "Buyer prompts are retained. Those records are used as training data for adapters.",
            "Buyer prompts are retained. Those records become examples for adapter optimization.",
            "Buyers may opt in to zero data retention. The service then enables that mode for their requests.",
            "Prompt records are retained. Those records are used as adapter/training data.",
            "Prompt records are retained. Those records are used as training material for adapters.",
            "Prompt records are retained. Those records are used as training material.",
            "Prompt records are used as training material, but those records are not sold.",
            "Prompt records are not sold and are used as training material.",
            "We train models on prompt records.",
            "Buyers may opt-in to zero-data-retention.",
            "ZDR is offered as an opt-in feature.",
            "Buyers can request ZDR support.",
            "We provide zero-data-retention to buyers.",
            "Prompt data is incorporated into fine-tuning datasets.",
        ]
        for phrase in contradictions:
            with self.subTest(phrase=phrase):
                contradictory = good + " " + phrase
                with mock.patch.object(probe, "http_request", return_value=FakeHTTPResponse(contradictory.encode())):
                    with self.assertRaisesRegex(
                        probe.ProbeError,
                        "fine-tune|fine-tuning|training|adapters|datasets|zdr|zero data retention|zero-data-retention",
                    ):
                        probe.check_privacy("https://api.example.test")

    def test_saturation_accepts_all_capacity_shed_batch(self):
        with mock.patch.object(
            probe,
            "chat_once",
            side_effect=[{"status": 429, "ok": False, "error_code": "no_provider_available", "latency_ms": 1} for _ in range(3)],
        ):
            got = probe.run_benchmark("https://api.example.test", "secret", "model", 3, 2, 16, 0.0, 5000, 0.0, True)
        self.assertEqual(got["ok"], 0)
        self.assertEqual(got["shed_429"], 2)
        self.assertIsNone(got["ttft_ms_p95"])

    def test_benchmark_still_fails_when_everything_sheds(self):
        with mock.patch.object(
            probe,
            "chat_once",
            side_effect=[{"status": 429, "ok": False, "error_code": "no_provider_available", "latency_ms": 1} for _ in range(3)],
        ):
            with self.assertRaisesRegex(probe.ProbeError, "success ratio"):
                probe.run_benchmark("https://api.example.test", "secret", "model", 3, 2, 16, 1.0, 5000, 0.0, False)

    def test_plain_benchmark_min_success_zero_does_not_accept_all_shed(self):
        with mock.patch.object(
            probe,
            "chat_once",
            side_effect=[{"status": 429, "ok": False, "error_code": "no_provider_available", "latency_ms": 1} for _ in range(3)],
        ):
            with self.assertRaisesRegex(probe.ProbeError, "successful TTFT"):
                probe.run_benchmark("https://api.example.test", "secret", "model", 3, 2, 16, 0.0, 5000, 0.0, False)

    def test_saturation_does_not_count_account_limit_429_as_capacity_shed(self):
        account_limit = {"status": 429, "ok": False, "error_code": "account_rate_limited", "latency_ms": 1}
        with mock.patch.object(probe, "chat_once", side_effect=[account_limit]):
            with self.assertRaisesRegex(probe.ProbeError, "non-capacity-shed"):
                probe.run_benchmark("https://api.example.test", "secret", "model", 1, 1, 16, 0.0, 5000, 0.0, True)

    def test_benchmark_non_capacity_failure_reports_aggregate_evidence(self):
        upstream_error = {"status": 502, "ok": False, "error_code": "upstream_provider_error", "latency_ms": 1}
        shed = {"status": 429, "ok": False, "error_code": "no_provider_available", "latency_ms": 1}
        with mock.patch.object(probe, "chat_once", side_effect=[upstream_error, shed]):
            with self.assertRaises(probe.ProbeError) as raised:
                probe.run_benchmark("https://api.example.test", "secret", "model", 2, 2, 16, 0.0, 5000, 0.0, True)
        message = str(raised.exception)
        self.assertIn("'requests_sent': 2", message)
        self.assertIn("'shed_429': 1", message)
        self.assertIn("'non_capacity_failures': 1", message)
        self.assertIn("'classification': 'upstream_provider_error'", message)
        self.assertIn("upstream_provider_error", message)

    def test_benchmark_worker_exception_reports_aggregate_evidence(self):
        with mock.patch.object(probe, "chat_once", side_effect=probe.ProbeError("request timed out")):
            with self.assertRaises(probe.ProbeError) as raised:
                probe.run_benchmark("https://api.example.test", "secret", "model", 1, 1, 16, 0.0, 5000, 0.0, True)
        message = str(raised.exception)
        self.assertIn("'status': 'exception'", message)
        self.assertIn("'error_code': 'ProbeError'", message)
        self.assertIn("request timed out", message)

    def test_benchmark_batch_timeout_reports_pending_requests(self):
        with mock.patch.object(probe, "chat_once", return_value={"status": 200, "ok": True}), mock.patch.object(
            probe, "as_completed", side_effect=probe.FuturesTimeout
        ):
            with self.assertRaises(probe.ProbeError) as raised:
                probe.run_benchmark("https://api.example.test", "secret", "model", 2, 2, 16, 0.0, 5000, 0.0, True)
        message = str(raised.exception)
        self.assertIn("'requests_sent': 2", message)
        self.assertIn("'error_code': 'benchmark_timeout'", message)
        self.assertIn("'classification': 'benchmark_timeout'", message)

    def test_benchmark_batch_timeout_closes_active_stream_response(self):
        response = BlockingStreamResponse()
        with mock.patch.object(probe, "http_request", return_value=response), mock.patch.object(
            probe, "BENCHMARK_BATCH_TIMEOUT_SECONDS", 0.05
        ):
            with self.assertRaises(probe.ProbeError) as raised:
                probe.run_benchmark("https://api.example.test", "secret", "model", 1, 1, 16, 0.0, 5000, 0.0, True)
        self.assertTrue(response.closed)
        self.assertIn("benchmark_timeout", str(raised.exception))

    def test_benchmark_requires_429_when_saturation_is_requested(self):
        result = {
            "status": 200,
            "ok": True,
            "ttft_ms": 20,
            "latency_ms": 60,
            "generation_ms": 40,
            "output_tokens": 4,
        }
        with mock.patch.object(probe, "chat_once", side_effect=[result, result]):
            with self.assertRaisesRegex(probe.ProbeError, "did not observe"):
                probe.run_benchmark("https://api.example.test", "secret", "model", 2, 2, 16, 0.0, 5000, 0.0, True)

    def test_saturation_stops_after_first_capacity_shed_batch(self):
        ok = {
            "status": 200,
            "ok": True,
            "ttft_ms": 20,
            "latency_ms": 60,
            "generation_ms": 40,
            "output_tokens": 4,
        }
        shed = {"status": 429, "ok": False, "error_code": "no_provider_available", "latency_ms": 1}
        with mock.patch.object(probe, "chat_once", side_effect=[ok, shed, ok, ok]) as mocked:
            got = probe.run_benchmark("https://api.example.test", "secret", "model", 4, 2, 16, 0.0, 5000, 0.0, True)
        self.assertEqual(mocked.call_count, 2)
        self.assertEqual(got["requests_sent"], 2)
        self.assertEqual(got["shed_429"], 1)

    def test_saturation_does_not_fail_queued_ttft_after_clean_429(self):
        slow_ok = {
            "status": 200,
            "ok": True,
            "ttft_ms": 8000,
            "latency_ms": 8500,
            "generation_ms": 500,
            "output_tokens": 8,
        }
        shed = {"status": 429, "ok": False, "error_code": "no_provider_available", "latency_ms": 1}
        with mock.patch.object(probe, "chat_once", side_effect=[slow_ok, shed]):
            got = probe.run_benchmark("https://api.example.test", "secret", "model", 2, 2, 16, 0.0, 5000, 0.0, True)
        self.assertEqual(got["shed_429"], 1)
        self.assertEqual(got["ok"], 1)
        self.assertEqual(got["ttft_ms_p95"], 8000)

    def test_benchmark_stamps_unique_request_ids(self):
        result = {
            "status": 200,
            "ok": True,
            "ttft_ms": 20,
            "latency_ms": 60,
            "generation_ms": 40,
            "output_tokens": 4,
        }
        with mock.patch.object(probe, "chat_once", side_effect=[result, result, result, result]) as mocked:
            got = probe.run_benchmark("https://api.example.test", "secret", "model", 4, 2, 16, 1.0, 5000, 1.0)
        request_ids = [call.kwargs.get("request_id", "") for call in mocked.call_args_list]
        self.assertEqual(got["requests_sent"], 4)
        self.assertEqual(len(set(request_ids)), 4)
        for request_id in request_ids:
            uuid.UUID(request_id)

    def test_load_ladder_classifies_first_blocker(self):
        ok = {
            "status": 200,
            "ok": True,
            "ttft_ms": 20,
            "latency_ms": 60,
            "generation_ms": 40,
            "output_tokens": 4,
        }
        upstream_error = {"status": 502, "ok": False, "error_code": "upstream_provider_error", "latency_ms": 1}
        with mock.patch.object(probe, "chat_once", side_effect=[ok, upstream_error]):
            with self.assertRaises(probe.EvidenceProbeError) as raised:
                probe.run_load_ladder("https://api.example.test", "secret", "model", [1, 1], 16, 1, 5000)
        self.assertEqual(raised.exception.evidence["max_clean_concurrency"], 1)
        self.assertEqual(raised.exception.evidence["first_blocker"], "upstream_provider_error")

    def test_load_ladder_does_not_count_capacity_shed_as_clean_concurrency(self):
        ok = {
            "status": 200,
            "ok": True,
            "ttft_ms": 20,
            "latency_ms": 60,
            "generation_ms": 40,
            "output_tokens": 4,
        }
        shed = {"status": 429, "ok": False, "error_code": "no_provider_available", "latency_ms": 1}
        with mock.patch.object(probe, "chat_once", side_effect=[ok, ok, shed, shed]):
            got = probe.run_load_ladder("https://api.example.test", "secret", "model", [1, 2], 16, 2, 5000)
        self.assertEqual(got["max_clean_concurrency"], 1)
        self.assertEqual(got["steps"][1]["classification"], "clean_capacity_shed")

    def test_load_ladder_overflow_step_ignores_queued_ttft(self):
        ok = {
            "status": 200,
            "ok": True,
            "ttft_ms": 20,
            "latency_ms": 60,
            "generation_ms": 40,
            "output_tokens": 4,
        }
        slow = {
            "status": 200,
            "ok": True,
            "ttft_ms": 8000,
            "latency_ms": 8500,
            "generation_ms": 500,
            "output_tokens": 8,
        }
        shed = {"status": 429, "ok": False, "error_code": "no_provider_available", "latency_ms": 1}
        with mock.patch.object(probe, "chat_once", side_effect=[ok, slow, shed]):
            got = probe.run_load_ladder("https://api.example.test", "secret", "model", [1, 2], 16, 1, 5000)
        self.assertEqual(got["first_blocker"], "")
        self.assertEqual(got["max_clean_concurrency"], 1)
        self.assertEqual(got["steps"][1]["classification"], "clean_capacity_shed")

    def test_load_ladder_fails_when_every_step_capacity_sheds(self):
        shed = {"status": 429, "ok": False, "error_code": "no_provider_available", "latency_ms": 1}
        with mock.patch.object(probe, "chat_once", side_effect=[shed, shed, shed]):
            with self.assertRaises(probe.EvidenceProbeError) as raised:
                probe.run_load_ladder("https://api.example.test", "secret", "model", [1, 2], 16, 1, 5000)
        self.assertEqual(raised.exception.evidence["max_clean_concurrency"], 0)
        self.assertEqual(raised.exception.evidence["first_blocker"], "no_clean_capacity")

    def test_pool_topology_summarizes_expected_model_capacity(self):
        payload = {
            "pool": [
                {
                    "provider_id": "mp-secret",
                    "hostname": "private-host",
                    "model_id": "llama",
                    "state": "ready",
                    "routing_eligible": True,
                    "slots_total": 1,
                    "slots_free": 1,
                    "throughput_tps_estimate": 2.5,
                },
                {
                    "provider_id": "mp-secret-2",
                    "hostname": "private-host-2",
                    "model_id": "qwen",
                    "state": "ready",
                    "routing_eligible": True,
                    "slots_total": 4,
                    "slots_free": 4,
                    "throughput_tps_estimate": 9.0,
                },
            ]
        }
        with mock.patch.object(probe, "read_json", return_value=(payload, 200)):
            with self.assertRaises(probe.EvidenceProbeError) as raised:
                probe.check_pool_topology("https://admin.example.test", "operator", "llama", 4)
        got = raised.exception.evidence
        self.assertEqual(got["matching_ready_providers"], 1)
        self.assertEqual(got["matching_slots_total"], 1)
        self.assertFalse(got["benchmark_has_slot_slack"])
        self.assertEqual(got["classification"], "insufficient_model_available_capacity")
        self.assertNotIn("mp-secret", json.dumps(got))
        self.assertNotIn("private-host", json.dumps(got))

    def test_pool_topology_classifies_absent_model_before_capacity(self):
        payload = {
            "pool": [
                {
                    "model_id": "qwen",
                    "state": "ready",
                    "routing_eligible": True,
                    "slots_total": 4,
                    "slots_free": 4,
                }
            ]
        }
        with mock.patch.object(probe, "read_json", return_value=(payload, 200)):
            with self.assertRaises(probe.EvidenceProbeError) as raised:
                probe.check_pool_topology("https://admin.example.test", "operator", "llama", 4)
        self.assertEqual(raised.exception.evidence["classification"], "expected_model_not_ready")

    def test_pool_topology_excludes_non_routable_ready_rows(self):
        payload = {
            "pool": [
                {
                    "model_id": "llama",
                    "state": "ready",
                    "slots_total": 1,
                    "slots_free": 1,
                    "auth_state": "self_minted",
                    "routing_eligible": False,
                },
                {
                    "model_id": "llama",
                    "state": "ready",
                    "slots_total": 2,
                    "slots_free": 2,
                    "auth_state": "bearer_validated",
                    "routing_eligible": True,
                },
                {
                    "model_id": "llama",
                    "state": "ready",
                    "slots_total": 10,
                    "slots_free": 10,
                    "auth_state": "bearer_validated",
                    "routing_eligible": False,
                },
            ]
        }
        with mock.patch.object(probe, "read_json", return_value=(payload, 200)):
            got = probe.check_pool_topology("https://admin.example.test", "operator", "llama", 2)
        self.assertEqual(got["providers"], 3)
        self.assertEqual(got["routable_providers"], 1)
        self.assertEqual(got["matching_slots_total"], 2)

    def test_pool_topology_rejects_missing_routing_eligible_and_non_object_rows(self):
        with mock.patch.object(probe, "read_json", return_value=({"pool": [{"model_id": "llama", "state": "ready"}]}, 200)):
            with self.assertRaisesRegex(probe.ProbeError, "routing_eligible"):
                probe.check_pool_topology("https://admin.example.test", "operator", "llama", 1)
        with mock.patch.object(probe, "read_json", return_value=({"pool": [{"routing_eligible": True}, "bad-row"]}, 200)):
            with self.assertRaisesRegex(probe.ProbeError, "entries must be objects"):
                probe.check_pool_topology("https://admin.example.test", "operator", "llama", 1)

    def test_pool_topology_uses_free_slots_for_benchmark_slack(self):
        payload = {
            "pool": [
                {
                    "model_id": "llama",
                    "state": "ready",
                    "routing_eligible": True,
                    "slots_total": 4,
                    "slots_free": 1,
                }
            ]
        }
        with mock.patch.object(probe, "read_json", return_value=(payload, 200)):
            with self.assertRaises(probe.EvidenceProbeError) as raised:
                probe.check_pool_topology("https://admin.example.test", "operator", "llama", 4)
        self.assertFalse(raised.exception.evidence["benchmark_has_slot_slack"])

    def test_pool_topology_rejects_malformed_slot_counts(self):
        payload = {
            "pool": [
                {
                    "model_id": "llama",
                    "state": "ready",
                    "routing_eligible": True,
                    "slots_total": 1,
                    "slots_free": 4,
                }
            ]
        }
        with mock.patch.object(probe, "read_json", return_value=(payload, 200)):
            with self.assertRaisesRegex(probe.ProbeError, "slots_free"):
                probe.check_pool_topology("https://admin.example.test", "operator", "llama", 4)

    def test_benchmark_enforces_ttft_and_generated_token_throughput(self):
        slow_ttft = {
            "status": 200,
            "ok": True,
            "ttft_ms": 6000,
            "latency_ms": 7000,
            "generation_ms": 1000,
            "output_tokens": 10,
        }
        with mock.patch.object(probe, "chat_once", side_effect=[slow_ttft]):
            with self.assertRaisesRegex(probe.BenchmarkProbeError, "TTFT p95") as raised:
                probe.run_benchmark("https://api.example.test", "secret", "model", 1, 1, 16, 1.0, 5000, 1.0)
        self.assertEqual(raised.exception.evidence["classification"], "ttft_p95_above_threshold")
        self.assertEqual(raised.exception.evidence["statuses"], {"200": 1})
        self.assertEqual(raised.exception.evidence["ttft_p95_ms"], 6000)
        self.assertEqual(raised.exception.evidence["max_ttft_p95_ms"], 5000)
        low_throughput = {
            "status": 200,
            "ok": True,
            "ttft_ms": 20,
            "latency_ms": 10020,
            "generation_ms": 10000,
            "output_tokens": 1,
        }
        with mock.patch.object(probe, "chat_once", side_effect=[low_throughput]):
            with self.assertRaisesRegex(probe.BenchmarkProbeError, "throughput") as raised:
                probe.run_benchmark("https://api.example.test", "secret", "model", 1, 1, 16, 1.0, 5000, 1.0)
        self.assertEqual(raised.exception.evidence["classification"], "throughput_below_threshold")
        self.assertEqual(raised.exception.evidence["statuses"], {"200": 1})
        self.assertEqual(raised.exception.evidence["output_tokens_per_second"], 0.1)
        self.assertEqual(raised.exception.evidence["min_output_tokens_per_second"], 1.0)

    def test_benchmark_uses_throughput_prompt(self):
        captured = {}

        def fake_chat_once(*_args, **kwargs):
            captured["prompt"] = kwargs.get("prompt")
            return {
                "status": 200,
                "ok": True,
                "ttft_ms": 20,
                "latency_ms": 120,
                "generation_ms": 100,
                "output_tokens": 16,
            }

        with mock.patch.object(probe, "chat_once", side_effect=fake_chat_once):
            got = probe.run_benchmark("https://api.example.test", "secret", "model", 1, 1, 16, 1.0, 5000, 1.0)
        self.assertEqual(captured["prompt"], probe.BENCHMARK_PROMPT)
        self.assertGreaterEqual(got["output_tokens_per_second"], 10.0)

    def test_benchmark_rejects_unbounded_stress_inputs(self):
        with self.assertRaisesRegex(probe.ProbeError, "requests"):
            probe.run_benchmark(
                "https://api.example.test",
                "secret",
                "model",
                probe.MAX_BENCHMARK_REQUESTS + 1,
                1,
                16,
                1.0,
                5000,
                1.0,
            )

    def test_wholesale_statement_requires_line_items_and_requests(self):
        with mock.patch.object(
            probe,
            "read_json",
            return_value=(
                {
                    "wholesale_statement_id": "stmt_1",
                    "account_id": "acct_openrouter",
                    "period": "2026-09",
                    "request_count": 0,
                    "prompt_tokens": 0,
                    "completion_tokens": 0,
                    "gross_credits": 0,
                    "usd_micro": 0,
                    "usd": "0",
                    "line_items": [],
                },
                200,
            ),
        ):
            with self.assertRaisesRegex(probe.ProbeError, "non-empty"):
                probe.check_wholesale_statement("https://admin.example.test", "operator", "acct_openrouter", "2026-09")

    def test_wholesale_statement_retries_for_settlement_evidence(self):
        good = {
            "wholesale_statement_id": "stmt_1",
            "account_id": "acct_openrouter",
            "period": "2026-09",
            "usd_micro": 10,
            "line_items": [{"model": "paid-model", "is_free": False, "usd_micro": 10, "request_count": 1, "gross_credits": 10}],
        }
        csv_body = (
            "wholesale_statement_id,account_id,period,model,is_free,request_count,prompt_tokens,completion_tokens,gross_credits,usd_micro,usd\n"
            "stmt_1,acct_openrouter,2026-09,paid-model,false,1,2,3,10,10,0.000010\n"
        )
        with mock.patch.object(
            probe,
            "check_wholesale_statement_once",
            side_effect=[probe.SettlementLagError("wholesale statement line_items must be a non-empty array"), {"attempts": 99, **good, "csv_ok": True}],
        ) as mocked, mock.patch.object(probe, "time") as fake_time:
            got = probe.check_wholesale_statement(
                "https://admin.example.test",
                "operator",
                "acct_openrouter",
                "2026-09",
                attempts=2,
                wait_seconds=0.01,
            )
        self.assertEqual(mocked.call_count, 2)
        fake_time.sleep.assert_called_once_with(0.01)
        self.assertEqual(got["attempts"], 2)
        self.assertTrue(got["csv_ok"])

    def test_wholesale_statement_does_not_retry_contract_violations(self):
        with mock.patch.object(
            probe,
            "check_wholesale_statement_once",
            side_effect=probe.ProbeError("statement CSV leaked forbidden invoice naming"),
        ) as mocked:
            with self.assertRaisesRegex(probe.ProbeError, "invoice"):
                probe.check_wholesale_statement(
                    "https://admin.example.test",
                    "operator",
                    "acct_openrouter",
                    "2026-09",
                    attempts=3,
                    wait_seconds=0.01,
                )
        self.assertEqual(mocked.call_count, 1)

    def test_wholesale_statement_non_list_line_items_is_contract_failure(self):
        malformed = {
            "wholesale_statement_id": "stmt_1",
            "account_id": "acct_openrouter",
            "period": "2026-09",
            "request_count": 0,
            "prompt_tokens": 0,
            "completion_tokens": 0,
            "gross_credits": 0,
            "usd_micro": 0,
            "usd": "0",
            "line_items": {},
        }
        with mock.patch.object(probe, "read_json", return_value=(malformed, 200)) as mocked:
            with self.assertRaisesRegex(probe.ProbeError, "line_items must be an array"):
                probe.check_wholesale_statement(
                    "https://admin.example.test",
                    "operator",
                    "acct_openrouter",
                    "2026-09",
                    attempts=2,
                    wait_seconds=0.01,
                )
        self.assertEqual(mocked.call_count, 1)

    def test_filing_mode_requires_free_sku_statement_line(self):
        class FakeCSV:
            status = 200

            def __enter__(self):
                return self

            def __exit__(self, exc_type, exc, tb):
                return False

            def read(self):
                return b"wholesale_statement_id,account_id\nstmt_1,acct_openrouter\n"

        statement = wholesale_statement([wholesale_line()])
        with mock.patch.object(probe, "read_json", return_value=(statement, 200)), mock.patch.object(probe, "http_request", return_value=FakeCSV()):
            with self.assertRaisesRegex(probe.ProbeError, "free SKU"):
                probe.check_wholesale_statement("https://admin.example.test", "operator", "acct_openrouter", "2026-09", True)

    def test_wholesale_statement_matches_csv_rows_and_free_credit(self):
        statement = wholesale_statement(
            [
                wholesale_line("paid-model", is_free=False, usd_micro=10, gross_credits=10),
                wholesale_line("free-model-free", is_free=True, usd_micro=0, gross_credits=5),
            ]
        )
        csv_body = (
            "wholesale_statement_id,account_id,period,model,is_free,request_count,prompt_tokens,completion_tokens,gross_credits,usd_micro,usd\n"
            "stmt_1,acct_openrouter,2026-09,paid-model,false,1,2,3,10,10,0.000010\n"
            "stmt_1,acct_openrouter,2026-09,free-model-free,true,1,2,3,5,0,0\n"
        )
        with mock.patch.object(probe, "read_json", return_value=(statement, 200)), mock.patch.object(
            probe, "http_request", return_value=FakeHTTPResponse(csv_body.encode())
        ):
            got = probe.check_wholesale_statement("https://admin.example.test", "operator", "acct_openrouter", "2026-09", True)
        self.assertEqual(got["request_count"], 2)
        self.assertTrue(got["positive_free_credit"])

    def test_filing_statement_requires_expected_paid_and_free_skus(self):
        expected_model = "mlx-community/Llama-3.2-3B-Instruct-4bit"
        expected_free = expected_model + "-free"
        good_statement = wholesale_statement(
            [
                wholesale_line(expected_model, is_free=False, usd_micro=10, gross_credits=10),
                wholesale_line(expected_free, is_free=True, usd_micro=0, gross_credits=5),
            ]
        )
        good_csv = (
            "wholesale_statement_id,account_id,period,model,is_free,request_count,prompt_tokens,completion_tokens,gross_credits,usd_micro,usd\n"
            f"stmt_1,acct_openrouter,2026-09,{expected_model},false,1,2,3,10,10,0.000010\n"
            f"stmt_1,acct_openrouter,2026-09,{expected_free},true,1,2,3,5,0,0\n"
        )
        with mock.patch.object(probe, "read_json", return_value=(good_statement, 200)), mock.patch.object(
            probe, "http_request", return_value=FakeHTTPResponse(good_csv.encode())
        ):
            got = probe.check_wholesale_statement(
                "https://admin.example.test",
                "operator",
                "acct_openrouter",
                "2026-09",
                True,
                expected_model,
            )
        self.assertEqual(got["request_count"], 2)

        unrelated_free = wholesale_statement([wholesale_line("other-free", is_free=True, usd_micro=0, gross_credits=5)])
        unrelated_csv = (
            "wholesale_statement_id,account_id,period,model,is_free,request_count,prompt_tokens,completion_tokens,gross_credits,usd_micro,usd\n"
            "stmt_1,acct_openrouter,2026-09,other-free,true,1,2,3,5,0,0\n"
        )
        with mock.patch.object(probe, "read_json", return_value=(unrelated_free, 200)), mock.patch.object(
            probe, "http_request", return_value=FakeHTTPResponse(unrelated_csv.encode())
        ):
            with self.assertRaisesRegex(probe.ProbeError, "paid SKU"):
                probe.check_wholesale_statement(
                    "https://admin.example.test",
                    "operator",
                    "acct_openrouter",
                    "2026-09",
                    True,
                    expected_model,
                )

        zero_paid = wholesale_statement(
            [
                wholesale_line(expected_model, is_free=False, usd_micro=0, gross_credits=10),
                wholesale_line(expected_free, is_free=True, usd_micro=0, gross_credits=5),
            ]
        )
        zero_paid_csv = good_csv.replace(",10,10,0.000010", ",10,0,0", 1)
        with mock.patch.object(probe, "read_json", return_value=(zero_paid, 200)), mock.patch.object(
            probe, "http_request", return_value=FakeHTTPResponse(zero_paid_csv.encode())
        ):
            with self.assertRaisesRegex(probe.ProbeError, "billable usage"):
                probe.check_wholesale_statement(
                    "https://admin.example.test",
                    "operator",
                    "acct_openrouter",
                    "2026-09",
                    True,
                    expected_model,
                )

    def test_wholesale_statement_rejects_duplicate_csv_model_rows(self):
        statement = wholesale_statement(
            [
                wholesale_line("paid-model", is_free=False, usd_micro=10, gross_credits=10),
                wholesale_line("free-model-free", is_free=True, usd_micro=0, gross_credits=5),
            ]
        )
        csv_body = (
            "wholesale_statement_id,account_id,period,model,is_free,request_count,prompt_tokens,completion_tokens,gross_credits,usd_micro,usd\n"
            "stmt_1,acct_openrouter,2026-09,paid-model,false,1,2,3,10,10,0.000010\n"
            "stmt_1,acct_openrouter,2026-09,paid-model,false,1,2,3,10,10,0.000010\n"
        )
        with mock.patch.object(probe, "read_json", return_value=(statement, 200)), mock.patch.object(
            probe, "http_request", return_value=FakeHTTPResponse(csv_body.encode())
        ):
            with self.assertRaisesRegex(probe.ProbeError, "duplicate model"):
                probe.check_wholesale_statement("https://admin.example.test", "operator", "acct_openrouter", "2026-09", True)

    def test_wholesale_statement_rejects_csv_mismatches(self):
        statement = wholesale_statement([wholesale_line()])
        csv_body = (
            "wholesale_statement_id,account_id,period,model,is_free,request_count,prompt_tokens,completion_tokens,gross_credits,usd_micro,usd\n"
            "stmt_1,acct_openrouter,2026-09,paid-model,false,1,2,3,10,9,0.000009\n"
        )
        with mock.patch.object(probe, "read_json", return_value=(statement, 200)), mock.patch.object(
            probe, "http_request", return_value=FakeHTTPResponse(csv_body.encode())
        ):
            with self.assertRaisesRegex(probe.ProbeError, "usd_micro mismatch"):
                probe.check_wholesale_statement("https://admin.example.test", "operator", "acct_openrouter", "2026-09")

    def test_wholesale_statement_reconciles_json_totals_tokens_and_usd_text(self):
        statement = wholesale_statement([wholesale_line()])
        bad_total = copy.deepcopy(statement)
        bad_total["prompt_tokens"] += 1
        csv_body = (
            "wholesale_statement_id,account_id,period,model,is_free,request_count,prompt_tokens,completion_tokens,gross_credits,usd_micro,usd\n"
            "stmt_1,acct_openrouter,2026-09,paid-model,false,1,2,3,10,10,0.000010\n"
        )
        with mock.patch.object(probe, "read_json", return_value=(bad_total, 200)), mock.patch.object(
            probe, "http_request", return_value=FakeHTTPResponse(csv_body.encode())
        ):
            with self.assertRaisesRegex(probe.ProbeError, "prompt_tokens total mismatch"):
                probe.check_wholesale_statement("https://admin.example.test", "operator", "acct_openrouter", "2026-09")

        bad_csv = (
            "wholesale_statement_id,account_id,period,model,is_free,request_count,prompt_tokens,completion_tokens,gross_credits,usd_micro,usd\n"
            "stmt_1,acct_openrouter,2026-09,paid-model,false,1,999,3,10,10,0.000010\n"
        )
        with mock.patch.object(probe, "read_json", return_value=(statement, 200)), mock.patch.object(
            probe, "http_request", return_value=FakeHTTPResponse(bad_csv.encode())
        ):
            with self.assertRaisesRegex(probe.ProbeError, "prompt_tokens mismatch"):
                probe.check_wholesale_statement("https://admin.example.test", "operator", "acct_openrouter", "2026-09")

        bad_usd = copy.deepcopy(statement)
        bad_usd["line_items"][0]["usd"] = "0.000009"
        with mock.patch.object(probe, "read_json", return_value=(bad_usd, 200)), mock.patch.object(
            probe, "http_request", return_value=FakeHTTPResponse(csv_body.encode())
        ):
            with self.assertRaisesRegex(probe.ProbeError, "usd text mismatch"):
                probe.check_wholesale_statement("https://admin.example.test", "operator", "acct_openrouter", "2026-09")

    def test_wholesale_statement_rejects_boolean_integer_fields(self):
        csv_body = (
            "wholesale_statement_id,account_id,period,model,is_free,request_count,prompt_tokens,completion_tokens,gross_credits,usd_micro,usd\n"
            "stmt_1,acct_openrouter,2026-09,paid-model,false,1,2,3,10,10,0.000010\n"
        )
        statement = wholesale_statement([wholesale_line()])
        statement["request_count"] = True
        with mock.patch.object(probe, "read_json", return_value=(statement, 200)), mock.patch.object(
            probe, "http_request", return_value=FakeHTTPResponse(csv_body.encode())
        ):
            with self.assertRaisesRegex(probe.ProbeError, "request_count"):
                probe.check_wholesale_statement("https://admin.example.test", "operator", "acct_openrouter", "2026-09")
        statement = wholesale_statement([wholesale_line(prompt_tokens=True)])
        with mock.patch.object(probe, "read_json", return_value=(statement, 200)), mock.patch.object(
            probe, "http_request", return_value=FakeHTTPResponse(csv_body.encode())
        ):
            with self.assertRaisesRegex(probe.ProbeError, "prompt_tokens"):
                probe.check_wholesale_statement("https://admin.example.test", "operator", "acct_openrouter", "2026-09")

    def test_wholesale_statement_requires_boolean_is_free(self):
        csv_body = (
            "wholesale_statement_id,account_id,period,model,is_free,request_count,prompt_tokens,completion_tokens,gross_credits,usd_micro,usd\n"
            "stmt_1,acct_openrouter,2026-09,paid-model,false,1,2,3,10,10,0.000010\n"
        )
        statement = wholesale_statement([wholesale_line()])
        statement["line_items"][0]["is_free"] = "false"
        with mock.patch.object(probe, "read_json", return_value=(statement, 200)), mock.patch.object(
            probe, "http_request", return_value=FakeHTTPResponse(csv_body.encode())
        ):
            with self.assertRaisesRegex(probe.ProbeError, "is_free"):
                probe.check_wholesale_statement("https://admin.example.test", "operator", "acct_openrouter", "2026-09")
        statement = wholesale_statement([wholesale_line()])
        bad_csv = csv_body.replace(",false,", ",no,")
        with mock.patch.object(probe, "read_json", return_value=(statement, 200)), mock.patch.object(
            probe, "http_request", return_value=FakeHTTPResponse(bad_csv.encode())
        ):
            with self.assertRaisesRegex(probe.ProbeError, "is_free must be boolean"):
                probe.check_wholesale_statement("https://admin.example.test", "operator", "acct_openrouter", "2026-09")

    def test_filing_mode_reports_missing_operator_key_file_without_traceback(self):
        with tempfile.TemporaryDirectory() as tmp:
            output = Path(tmp) / "report.json"
            missing_operator_key = Path(tmp) / "missing-operator-key"
            argv = [
                "--base-url",
                probe.PRODUCTION_BASE_URL,
                "--expected-healthz-version",
                "v1.8.153",
                "--api-key-env",
                "MACPROVIDER_TEST_API_KEY",
                "--admin-url",
                probe.PRODUCTION_ADMIN_URL,
                "--operator-key-env",
                "MACPROVIDER_TEST_OPERATOR_KEY",
                "--operator-key-file",
                str(missing_operator_key),
                "--statement-account-id",
                "acct_openrouter",
                "--statement-period",
                "2026-09",
                "--filing-mode",
                "--continue-on-error",
                "--benchmark-requests",
                "100",
                "--saturation-requests",
                "8",
                "--output",
                str(output),
            ]
            bench = {"requests_sent": 8, "statuses": {"200": 8}, "ok": 8, "shed_429": 0}
            with mock.patch.dict(os.environ, {"MACPROVIDER_TEST_API_KEY": "buyer-secret"}, clear=False), mock.patch.object(
                probe, "read_json", return_value=(valid_doc(), 200)
            ), mock.patch.object(probe, "check_privacy", return_value={"http_status": 200}), mock.patch.object(
                probe, "check_healthz", return_value={"http_status": 200, "status": "ok", "version": "v1.8.153"}
            ), mock.patch.object(
                probe, "check_chat", return_value={"ok": True}
            ), mock.patch.object(probe, "run_benchmark", return_value=bench):
                code = probe.main(argv)
            self.assertEqual(code, 1)
            report = json.loads(output.read_text(encoding="utf-8"))
            self.assertFalse(report["ok"])
            self.assertIn("operator key file is not readable", report["checks"]["wholesale_statement"]["error"])
            self.assertIn("admin_healthz", report["checks"])
            self.assertIn("operator key file is not readable", report["checks"]["pool_topology"]["error"])
            self.assertTrue(any("wholesale_statement" in error for error in report["errors"]))

    def test_filing_mode_requires_expected_healthz_version(self):
        argv = [
            "--base-url",
            probe.PRODUCTION_BASE_URL,
            "--admin-url",
            probe.PRODUCTION_ADMIN_URL,
            "--statement-account-id",
            "acct_openrouter",
            "--statement-period",
            "2026-09",
            "--filing-mode",
            "--benchmark-requests",
            "100",
            "--saturation-requests",
            "8",
        ]
        with self.assertRaisesRegex(SystemExit, "expected-healthz-version"):
            probe.main(argv)

    def test_filing_mode_rejects_disabled_benchmark_thresholds(self):
        base = [
            "--base-url",
            probe.PRODUCTION_BASE_URL,
            "--admin-url",
            probe.PRODUCTION_ADMIN_URL,
            "--statement-account-id",
            "acct_openrouter",
            "--statement-period",
            "2026-09",
            "--expected-healthz-version",
            "v1.8.153",
            "--filing-mode",
            "--benchmark-requests",
            "100",
            "--saturation-requests",
            "8",
        ]
        with self.assertRaisesRegex(SystemExit, "min-success-ratio"):
            probe.main(base + ["--min-success-ratio", "0"])
        with self.assertRaisesRegex(SystemExit, "max-ttft-p95-ms"):
            probe.main(base + ["--max-ttft-p95-ms", "0"])
        with self.assertRaisesRegex(SystemExit, "min-output-tokens-per-second"):
            probe.main(base + ["--min-output-tokens-per-second", "0"])
        with self.assertRaisesRegex(SystemExit, "min-success-ratio"):
            probe.main(base + ["--min-success-ratio", "nan"])
        with self.assertRaisesRegex(SystemExit, "min-output-tokens-per-second"):
            probe.main(base + ["--min-output-tokens-per-second", "nan"])
        with self.assertRaisesRegex(SystemExit, "benchmark-concurrency"):
            probe.main(base + ["--benchmark-concurrency", "1"])
        with self.assertRaisesRegex(SystemExit, "saturation-concurrency"):
            probe.main(base + ["--saturation-concurrency", "1"])
        with self.assertRaisesRegex(SystemExit, "saturation-requests"):
            probe.main(base + ["--saturation-requests", "1"])
        with self.assertRaisesRegex(SystemExit, "max-tokens"):
            probe.main(base + ["--max-tokens", "1"])
        with self.assertRaisesRegex(SystemExit, "load-ladder"):
            probe.main(base + ["--load-ladder", "1"])
        bad_version = list(base)
        bad_version[9] = "arbitrary-local-build"
        with self.assertRaisesRegex(SystemExit, "release version"):
            probe.main(bad_version)
        staging = list(base)
        staging[1] = "https://staging.example.test"
        with self.assertRaisesRegex(SystemExit, "base-url"):
            probe.main(staging)
        loopback_admin = list(base)
        loopback_admin[3] = "http://127.0.0.1:18444"
        with self.assertRaisesRegex(SystemExit, "admin-url"):
            probe.main(loopback_admin)
        with self.assertRaisesRegex(SystemExit, "load-ladder-requests-per-step"):
            probe.main(base + ["--load-ladder-requests-per-step", "1"])

    def test_filing_mode_records_absent_secret_evidence(self):
        with tempfile.TemporaryDirectory() as tmp:
            output = Path(tmp) / "report.json"
            argv = [
                "--base-url",
                probe.PRODUCTION_BASE_URL,
                "--expected-healthz-version",
                "v1.8.153",
                "--api-key-env",
                "MACPROVIDER_TEST_ABSENT_API_KEY",
                "--admin-url",
                probe.PRODUCTION_ADMIN_URL,
                "--operator-key-env",
                "MACPROVIDER_TEST_ABSENT_OPERATOR_KEY",
                "--statement-account-id",
                "acct_openrouter",
                "--statement-period",
                "2026-09",
                "--filing-mode",
                "--benchmark-requests",
                "100",
                "--saturation-requests",
                "8",
                "--output",
                str(output),
            ]
            with mock.patch.object(probe, "read_json", return_value=(valid_doc(), 200)), mock.patch.object(
                probe, "check_privacy", return_value={"http_status": 200}
            ), mock.patch.object(probe, "check_healthz", return_value={"http_status": 200, "status": "ok", "version": "v1.8.153"}):
                code = probe.main(argv)
            self.assertEqual(code, 1)
            report = json.loads(output.read_text(encoding="utf-8"))
            self.assertFalse(report["checks"]["api_key"]["ok"])
            self.assertFalse(report["checks"]["operator_key"]["ok"])
            self.assertFalse(report["checks"]["pool_topology"]["ok"])

    def test_diagnostic_mode_collects_pool_topology_without_statement_args(self):
        with tempfile.TemporaryDirectory() as tmp:
            output = Path(tmp) / "report.json"
            argv = [
                "--base-url",
                "https://api.example.test",
                "--expected-healthz-version",
                "v1.8.153",
                "--api-key-env",
                "MACPROVIDER_TEST_API_KEY",
                "--admin-url",
                "https://admin.example.test",
                "--operator-key-env",
                "MACPROVIDER_TEST_OPERATOR_KEY",
                "--diagnostic-mode",
                "--output",
                str(output),
            ]
            with mock.patch.dict(
                os.environ,
                {"MACPROVIDER_TEST_API_KEY": "buyer-secret", "MACPROVIDER_TEST_OPERATOR_KEY": "operator-secret"},
                clear=False,
            ), mock.patch.object(probe, "read_json", return_value=(valid_doc(), 200)), mock.patch.object(
                probe, "check_privacy", return_value={"http_status": 200}
            ), mock.patch.object(
                probe, "check_healthz", return_value={"http_status": 200, "status": "ok", "version": "v1.8.153"}
            ), mock.patch.object(
                probe, "check_chat", return_value={"ok": True}
            ), mock.patch.object(
                probe, "run_load_ladder", return_value={"steps": [], "first_blocker": "", "max_clean_concurrency": 4}
            ), mock.patch.object(
                probe, "check_pool_topology", return_value=ready_pool()
            ) as pool_topology:
                code = probe.main(argv)
            self.assertEqual(code, 0)
            pool_topology.assert_called_once()
            report = json.loads(output.read_text(encoding="utf-8"))
            self.assertIn("pool_topology", report["checks"])
            self.assertEqual(
                report["checks"]["wholesale_statement"]["skipped"],
                "admin URL, operator key, account id, or period missing",
            )

    def test_filing_mode_preserves_missing_api_key_file_evidence(self):
        with tempfile.TemporaryDirectory() as tmp:
            output = Path(tmp) / "report.json"
            missing_api_key = Path(tmp) / "missing-api-key"
            argv = [
                "--base-url",
                probe.PRODUCTION_BASE_URL,
                "--expected-healthz-version",
                "v1.8.153",
                "--api-key-env",
                "MACPROVIDER_TEST_API_KEY",
                "--api-key-file",
                str(missing_api_key),
                "--admin-url",
                probe.PRODUCTION_ADMIN_URL,
                "--operator-key-env",
                "MACPROVIDER_TEST_OPERATOR_KEY",
                "--statement-account-id",
                "acct_openrouter",
                "--statement-period",
                "2026-09",
                "--filing-mode",
                "--benchmark-requests",
                "100",
                "--saturation-requests",
                "8",
                "--output",
                str(output),
            ]
            with mock.patch.dict(os.environ, {"MACPROVIDER_TEST_OPERATOR_KEY": "operator-secret"}, clear=False), mock.patch.object(
                probe, "read_json", return_value=(valid_doc(), 200)
            ), mock.patch.object(probe, "check_privacy", return_value={"http_status": 200}), mock.patch.object(
                probe, "check_healthz", return_value={"http_status": 200, "status": "ok", "version": "v1.8.153"}
            ), mock.patch.object(
                probe,
                "check_wholesale_statement",
                return_value={"http_status": 200, "csv_status": 200, "request_count": 1},
            ):
                code = probe.main(argv)
            self.assertEqual(code, 1)
            report = json.loads(output.read_text(encoding="utf-8"))
            for name in ("chat", "chat_free", "benchmark", "load_ladder", "saturation"):
                self.assertFalse(report["checks"][name]["ok"])
                self.assertIn("API key file is not readable", report["checks"][name]["error"])
            self.assertTrue(any("api_key" in error for error in report["errors"]))
            self.assertIn("wholesale_statement", report["checks"])

    def test_plain_mode_unreadable_api_key_file_fails(self):
        with tempfile.TemporaryDirectory() as tmp:
            output = Path(tmp) / "report.json"
            missing_api_key = Path(tmp) / "missing-api-key"
            argv = [
                "--base-url",
                "https://api.example.test",
                "--api-key-env",
                "MACPROVIDER_TEST_API_KEY",
                "--api-key-file",
                str(missing_api_key),
                "--output",
                str(output),
            ]
            with mock.patch.dict(os.environ, {"MACPROVIDER_TEST_API_KEY": "env-secret"}, clear=False), mock.patch.object(
                probe, "check_healthz", return_value={"http_status": 200, "status": "ok", "version": "v1.8.153"}
            ), mock.patch.object(
                probe, "read_json", return_value=(valid_doc(), 200)
            ), mock.patch.object(probe, "check_privacy", return_value={"http_status": 200}):
                code = probe.main(argv)
            self.assertEqual(code, 1)
            report = json.loads(output.read_text(encoding="utf-8"))
            self.assertFalse(report["checks"]["api_key"]["ok"])
            self.assertFalse(report["checks"]["chat"]["ok"])
            self.assertIn("API key file is not readable", report["checks"]["api_key"]["error"])

    def test_filing_mode_continues_after_benchmark_failure_and_records_diagnostics(self):
        with tempfile.TemporaryDirectory() as tmp:
            output = Path(tmp) / "report.json"
            argv = [
                "--base-url",
                probe.PRODUCTION_BASE_URL,
                "--expected-healthz-version",
                "v1.8.153",
                "--api-key-env",
                "MACPROVIDER_TEST_API_KEY",
                "--admin-url",
                probe.PRODUCTION_ADMIN_URL,
                "--operator-key-env",
                "MACPROVIDER_TEST_OPERATOR_KEY",
                "--statement-account-id",
                "acct_openrouter",
                "--statement-period",
                "2026-09",
                "--filing-mode",
                "--benchmark-requests",
                "100",
                "--saturation-requests",
                "8",
                "--output",
                str(output),
            ]
            bench_error = probe.BenchmarkProbeError(
                "benchmark failed",
                {"classification": "upstream_provider_error", "statuses": {"502": 1}},
            )
            with mock.patch.dict(
                os.environ,
                {"MACPROVIDER_TEST_API_KEY": "buyer-secret", "MACPROVIDER_TEST_OPERATOR_KEY": "operator-secret"},
                clear=False,
            ), mock.patch.object(probe, "read_json", return_value=(valid_doc(), 200)), mock.patch.object(
                probe, "check_privacy", return_value={"http_status": 200}
            ), mock.patch.object(
                probe, "check_healthz", return_value={"http_status": 200, "status": "ok", "version": "v1.8.153"}
            ), mock.patch.object(
                probe, "check_chat", return_value={"ok": True}
            ), mock.patch.object(
                probe, "run_benchmark", side_effect=[bench_error, {"requests_sent": 8, "statuses": {"429": 8}, "ok": 0, "shed_429": 8}]
            ), mock.patch.object(
                probe, "run_load_ladder", return_value={"steps": [], "first_blocker": "", "max_clean_concurrency": 4}
            ), mock.patch.object(
                probe, "check_pool_topology", return_value=ready_pool()
            ), mock.patch.object(
                probe,
                "check_wholesale_statement",
                return_value={"csv_ok": True, "request_count": 1, "line_items": 1},
            ):
                code = probe.main(argv)
            self.assertEqual(code, 1)
            report = json.loads(output.read_text(encoding="utf-8"))
            self.assertEqual(report["checks"]["benchmark"]["classification"], "upstream_provider_error")
            self.assertIn("saturation", report["checks"])
            self.assertIn("load_ladder", report["checks"])
            self.assertIn("admin_healthz", report["checks"])
            self.assertIn("pool_topology", report["checks"])
            self.assertIn("wholesale_statement", report["checks"])

    def test_continue_on_error_writes_output_after_unexpected_check_exception(self):
        with tempfile.TemporaryDirectory() as tmp:
            output = Path(tmp) / "report.json"
            argv = [
                "--base-url",
                "https://api.example.test",
                "--expected-healthz-version",
                "test-version",
                "--continue-on-error",
                "--output",
                str(output),
            ]
            with mock.patch.object(probe, "check_healthz", side_effect=ValueError("malformed health payload")), mock.patch.object(
                probe, "read_json", return_value=(valid_doc(), 200)
            ), mock.patch.object(probe, "check_privacy", return_value={"http_status": 200}):
                code = probe.main(argv)
            self.assertEqual(code, 1)
            report = json.loads(output.read_text(encoding="utf-8"))
            self.assertFalse(report["ok"])
            self.assertEqual(report["checks"]["healthz"]["error_code"], "ValueError")
            self.assertIn("malformed health payload", report["checks"]["healthz"]["error"])
            self.assertTrue(any("healthz: ValueError" in error for error in report["errors"]))

    def test_emit_report_creates_private_non_overwritten_file(self):
        with tempfile.TemporaryDirectory() as tmp:
            output = Path(tmp) / "nested" / "report.json"
            probe.emit_report({"ok": True}, str(output))
            self.assertEqual(output.stat().st_mode & 0o777, 0o600)
            with self.assertRaisesRegex(probe.ProbeError, "overwrite"):
                probe.emit_report({"ok": True}, str(output))
            self.assertEqual(os.stat(output).st_size, len('{\n  "ok": true\n}\n'))


if __name__ == "__main__":
    unittest.main()
