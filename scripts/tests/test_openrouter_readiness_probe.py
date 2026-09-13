#!/usr/bin/env python3
"""Offline tests for the OpenRouter readiness probe."""

from __future__ import annotations

import copy
import os
import sys
import tempfile
import unittest
from unittest import mock
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
SCRIPTS = ROOT / "scripts"
if str(SCRIPTS) not in sys.path:
    sys.path.insert(0, str(SCRIPTS))

import openrouter_readiness_probe as probe  # noqa: E402


class FakeHTTPResponse:
    def __init__(self, body: bytes, status: int = 200):
        self._body = body
        self.status = status

    def __enter__(self):
        return self

    def __exit__(self, exc_type, exc, tb):
        return False

    def read(self):
        return self._body


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


class OpenRouterReadinessProbeTests(unittest.TestCase):
    def test_valid_schema_24_native_document_passes(self):
        got = probe.check_models_document(valid_doc(), "mlx-community/Llama-3.2-3B-Instruct-4bit")
        self.assertEqual(got["rows"], 1)
        self.assertEqual(got["ids"], ["mlx-community/Llama-3.2-3B-Instruct-4bit"])

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

    def test_price_strings_must_be_finite_decimals(self):
        for bad in ("", "-0.1", "NaN", "Infinity", "-Infinity"):
            with self.subTest(bad=bad):
                with self.assertRaises(probe.ProbeError):
                    probe.check_decimal(bad, "cost")

    def test_stream_usage_validator_requires_all_token_counts(self):
        self.assertTrue(probe.usage_is_valid({"prompt_tokens": 1, "completion_tokens": 2, "total_tokens": 3}))
        self.assertFalse(probe.usage_is_valid({"prompt_tokens": 1, "completion_tokens": 2}))

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

    def test_privacy_requires_no_training_and_rejects_zdr_contradictions(self):
        good = (
            "Prompts are plaintext. There is no zero-data-retention guarantee. "
            "The OpenRouter ingest document sets compliance.zdr to false. "
            "Request metadata is retained for 90 days. "
            "Mac Provider does not train foundation models on buyer prompts. "
            "Prompt and completion bodies are not stored as a training corpus."
        )
        with mock.patch.object(probe, "http_request", return_value=FakeHTTPResponse(good.encode())):
            got = probe.check_privacy("https://api.example.test")
        self.assertTrue(got["training_corpus_denied"])
        bad = good + " compliance.zdr: true"
        with mock.patch.object(probe, "http_request", return_value=FakeHTTPResponse(bad.encode())):
            with self.assertRaisesRegex(probe.ProbeError, "forbidden claim"):
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

    def test_saturation_does_not_count_account_limit_429_as_capacity_shed(self):
        account_limit = {"status": 429, "ok": False, "error_code": "account_rate_limited", "latency_ms": 1}
        with mock.patch.object(probe, "chat_once", side_effect=[account_limit]):
            with self.assertRaisesRegex(probe.ProbeError, "non-capacity-shed"):
                probe.run_benchmark("https://api.example.test", "secret", "model", 1, 1, 16, 0.0, 5000, 0.0, True)

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
            with self.assertRaisesRegex(probe.ProbeError, "TTFT p95"):
                probe.run_benchmark("https://api.example.test", "secret", "model", 1, 1, 16, 1.0, 5000, 1.0)
        low_throughput = {
            "status": 200,
            "ok": True,
            "ttft_ms": 20,
            "latency_ms": 10020,
            "generation_ms": 10000,
            "output_tokens": 1,
        }
        with mock.patch.object(probe, "chat_once", side_effect=[low_throughput]):
            with self.assertRaisesRegex(probe.ProbeError, "throughput"):
                probe.run_benchmark("https://api.example.test", "secret", "model", 1, 1, 16, 1.0, 5000, 1.0)

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
                    "usd_micro": 0,
                    "line_items": [],
                },
                200,
            ),
        ):
            with self.assertRaisesRegex(probe.ProbeError, "non-empty"):
                probe.check_wholesale_statement("https://admin.example.test", "operator", "acct_openrouter", "2026-09")

    def test_filing_mode_requires_free_sku_statement_line(self):
        class FakeCSV:
            status = 200

            def __enter__(self):
                return self

            def __exit__(self, exc_type, exc, tb):
                return False

            def read(self):
                return b"wholesale_statement_id,account_id\nstmt_1,acct_openrouter\n"

        statement = {
            "wholesale_statement_id": "stmt_1",
            "account_id": "acct_openrouter",
            "period": "2026-09",
            "usd_micro": 10,
            "line_items": [{"model": "paid-model", "is_free": False, "usd_micro": 10, "request_count": 1, "gross_credits": 10}],
        }
        with mock.patch.object(probe, "read_json", return_value=(statement, 200)), mock.patch.object(probe, "http_request", return_value=FakeCSV()):
            with self.assertRaisesRegex(probe.ProbeError, "free SKU"):
                probe.check_wholesale_statement("https://admin.example.test", "operator", "acct_openrouter", "2026-09", True)

    def test_wholesale_statement_matches_csv_rows_and_free_credit(self):
        statement = {
            "wholesale_statement_id": "stmt_1",
            "account_id": "acct_openrouter",
            "period": "2026-09",
            "usd_micro": 10,
            "line_items": [
                {"model": "paid-model", "is_free": False, "usd_micro": 10, "request_count": 1, "gross_credits": 10},
                {"model": "free-model-free", "is_free": True, "usd_micro": 0, "request_count": 1, "gross_credits": 5},
            ],
        }
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

    def test_wholesale_statement_rejects_csv_mismatches(self):
        statement = {
            "wholesale_statement_id": "stmt_1",
            "account_id": "acct_openrouter",
            "period": "2026-09",
            "usd_micro": 10,
            "line_items": [{"model": "paid-model", "is_free": False, "usd_micro": 10, "request_count": 1, "gross_credits": 10}],
        }
        csv_body = (
            "wholesale_statement_id,account_id,period,model,is_free,request_count,prompt_tokens,completion_tokens,gross_credits,usd_micro,usd\n"
            "stmt_1,acct_openrouter,2026-09,paid-model,false,1,2,3,10,9,0.000009\n"
        )
        with mock.patch.object(probe, "read_json", return_value=(statement, 200)), mock.patch.object(
            probe, "http_request", return_value=FakeHTTPResponse(csv_body.encode())
        ):
            with self.assertRaisesRegex(probe.ProbeError, "usd_micro mismatch"):
                probe.check_wholesale_statement("https://admin.example.test", "operator", "acct_openrouter", "2026-09")

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
