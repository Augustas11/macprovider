#!/usr/bin/env python3
"""Validate Malibu's OpenRouter provider-readiness surfaces.

The probe is intentionally dependency-free so operators can run it from a
release host or laptop without changing the repo environment.
"""

from __future__ import annotations

import argparse
import csv
import decimal
import io
import json
import os
import statistics
import sys
import time
import urllib.error
import urllib.parse
import urllib.request
from concurrent.futures import ThreadPoolExecutor, as_completed
from pathlib import Path


DEFAULT_MODEL = "mlx-community/Llama-3.2-3B-Instruct-4bit"
DEFAULT_PROMPT = "OpenRouter provider readiness smoke. Reply with one short sentence."
MAX_BENCHMARK_REQUESTS = 200
MAX_BENCHMARK_CONCURRENCY = 8
DEFAULT_MIN_SUCCESS_RATIO = 0.95
DEFAULT_MAX_TTFT_P95_MS = 5000
DEFAULT_MIN_OUTPUT_TOKENS_PER_SECOND = 10.0
GATEWAY_KEEPALIVE_TICK_SECONDS = 15
LOCAL_AUTH_HOSTS = {"localhost", "127.0.0.1", "::1"}
EXPECTED_OPENROUTER_SLUGS = {
    "mlx-community/Llama-3.2-3B-Instruct-4bit": "meta-llama/llama-3.2-3b-instruct",
    "mlx-community/Llama-3.2-3B-Instruct-4bit-free": "meta-llama/llama-3.2-3b-instruct:free",
    "mlx-community/Qwen3-8B-4bit": "qwen/qwen3-8b",
}
ROOT_FORBIDDEN_MODEL_KEYS = {
    "architecture",
    "context_length",
    "cost_usd",
    "supported_sampling_parameters",
    "supported_features",
    "capacity_tpm",
}
RECURSIVE_FORBIDDEN_DISCLOSURE_KEYS = {
    "compute_integrity",
    "tier1_disclosure",
    "provider_id",
    "provider_ids",
    "provider",
    "providers",
    "host",
    "hostname",
    "ip",
    "ips",
    "endpoint",
    "endpoints",
}


class ProbeError(Exception):
    pass


class NoRedirectHandler(urllib.request.HTTPRedirectHandler):
    def redirect_request(self, req, fp, code, msg, headers, newurl):
        raise ProbeError(f"refusing redirect from {req.full_url} to {newurl}")


NO_REDIRECT_OPENER = urllib.request.build_opener(NoRedirectHandler)


def http_request(method: str, url: str, *, token: str = "", body: object | None = None, stream: bool = False, timeout: float = 45.0):
    parsed = urllib.parse.urlparse(url)
    if parsed.scheme not in {"http", "https"} or not parsed.netloc:
        raise ProbeError(f"invalid URL: {url}")
    if token and parsed.scheme != "https" and parsed.hostname not in LOCAL_AUTH_HOSTS:
        raise ProbeError(f"refusing to send bearer token over non-HTTPS URL: {url}")
    data = None
    headers = {"User-Agent": "macprovider-openrouter-readiness-probe/1.0"}
    if body is not None:
        data = json.dumps(body).encode("utf-8")
        headers["Content-Type"] = "application/json"
    if token:
        headers["Authorization"] = "Bearer " + token
    req = urllib.request.Request(url, data=data, headers=headers, method=method)
    try:
        return NO_REDIRECT_OPENER.open(req, timeout=timeout)
    except ProbeError:
        raise
    except urllib.error.HTTPError as exc:
        return exc
    except urllib.error.URLError as exc:
        raise ProbeError(str(exc)) from exc


def response_status(resp) -> int:
    status = getattr(resp, "status", None)
    if status is None:
        status = getattr(resp, "code", None)
    if status is None:
        raise ProbeError("HTTP response missing status/code")
    return int(status)


def read_json(method: str, url: str, **kwargs):
    with http_request(method, url, **kwargs) as resp:
        raw = resp.read()
        status = response_status(resp)
        if status < 200 or status > 299:
            raise ProbeError(f"{url} returned HTTP {status}")
        return json.loads(raw.decode("utf-8")), status


def normalize_base_url(base_url: str) -> str:
    return base_url.rstrip("/")


def v1_url(base_url: str, path: str) -> str:
    base = normalize_base_url(base_url)
    if base.endswith("/v1"):
        return base + path
    return base + "/v1" + path


def expected_free_model_id(model: str) -> str:
    if model.endswith("-free"):
        return model
    return model + "-free"


def root_url(base_url: str, path: str) -> str:
    base = normalize_base_url(base_url)
    if base.endswith("/v1"):
        base = base[:-3]
    return base + path


def check_decimal(value: object, label: str) -> None:
    if not isinstance(value, str) or not value or value.startswith("-"):
        raise ProbeError(f"{label} must be a non-negative decimal string")
    try:
        parsed = decimal.Decimal(value)
    except decimal.InvalidOperation as exc:
        raise ProbeError(f"{label} must parse as decimal") from exc
    if not parsed.is_finite() or parsed < 0:
        raise ProbeError(f"{label} must be a finite non-negative decimal string")


def check_capacity(entries: object, label: str) -> None:
    if not isinstance(entries, list) or not entries:
        raise ProbeError(f"{label} must be a non-empty capacity array")
    for entry in entries:
        if not isinstance(entry, dict):
            raise ProbeError(f"{label} entries must be objects")
        if not isinstance(entry.get("value"), int) or entry["value"] < 1:
            raise ProbeError(f"{label} value must be a positive integer")
        if entry.get("type") != "concurrency" and entry.get("per") not in {"minute", "hour", "day"}:
            raise ProbeError(f"{label} non-concurrency entries need a valid per window")


def find_forbidden_key(value: object, path: str = "$") -> str | None:
    if isinstance(value, dict):
        for key, child in value.items():
            if key in RECURSIVE_FORBIDDEN_DISCLOSURE_KEYS:
                return f"{path}.{key}"
            found = find_forbidden_key(child, f"{path}.{key}")
            if found:
                return found
    elif isinstance(value, list):
        for index, child in enumerate(value):
            found = find_forbidden_key(child, f"{path}[{index}]")
            if found:
                return found
    return None


def model_prices(row: dict) -> tuple[object, object]:
    prompt = row.get("input_modalities", [{}])[0].get("pricing", [{}])[0].get("cost_usd")
    completion = row.get("output_modalities", [{}])[0].get("pricing", [{}])[0].get("cost_usd")
    return prompt, completion


def check_models_document(doc: dict, expected_model: str = "", require_free_alias: bool = False) -> dict:
    rows = doc.get("data")
    if not isinstance(rows, list) or not rows:
        raise ProbeError("models document must contain non-empty data array")
    by_id = {}
    for row in rows:
        if not isinstance(row, dict):
            raise ProbeError("model rows must be objects")
        row_id = row.get("id")
        if isinstance(row_id, str):
            by_id[row_id] = row
        missing = {"schema_version", "id", "name", "input_modalities", "output_modalities"} - set(row)
        if missing:
            raise ProbeError(f"{row.get('id', '<unknown>')} missing required keys: {sorted(missing)}")
        bad_root = ROOT_FORBIDDEN_MODEL_KEYS & set(row)
        if bad_root:
            raise ProbeError(f"{row.get('id', '<unknown>')} contains forbidden root keys: {sorted(bad_root)}")
        bad_path = find_forbidden_key(row)
        if bad_path:
            raise ProbeError(f"{row.get('id', '<unknown>')} contains forbidden disclosure key: {bad_path}")
        if row["schema_version"] != "2.4":
            raise ProbeError(f"{row['id']} schema_version={row['schema_version']!r}, want 2.4")
        inputs = row["input_modalities"]
        outputs = row["output_modalities"]
        if not isinstance(inputs, list) or not inputs or inputs[0].get("type") != "text":
            raise ProbeError(f"{row['id']} must declare text input modality")
        if not isinstance(outputs, list) or not outputs or outputs[0].get("type") != "text":
            raise ProbeError(f"{row['id']} must declare text output modality")
        text_in = inputs[0]
        text_out = outputs[0]
        max_context = text_in.get("supported_inputs", {}).get("max_context_length", {})
        if not isinstance(max_context.get("value"), int) or max_context["value"] < 1:
            raise ProbeError(f"{row['id']} text max_context_length must be positive")
        input_prices = text_in.get("pricing")
        output_prices = text_out.get("pricing")
        if not isinstance(input_prices, list) or not input_prices:
            raise ProbeError(f"{row['id']} must declare input pricing")
        if not isinstance(output_prices, list) or not output_prices:
            raise ProbeError(f"{row['id']} must declare output pricing")
        check_decimal(input_prices[0].get("cost_usd"), f"{row['id']} prompt cost_usd")
        check_decimal(output_prices[0].get("cost_usd"), f"{row['id']} completion cost_usd")
        if not isinstance(text_out.get("supported_parameters"), dict):
            raise ProbeError(f"{row['id']} output supported_parameters must be an object")
        for param in ("max_tokens", "temperature", "top_p", "stop", "stream"):
            if param not in text_out["supported_parameters"]:
                raise ProbeError(f"{row['id']} missing supported parameter {param}")
        check_capacity(row.get("capacity"), f"{row['id']} root capacity")
        check_capacity(text_in.get("capacity"), f"{row['id']} input capacity")
        check_capacity(text_out.get("capacity"), f"{row['id']} output capacity")
        if "datacenters" in row:
            raise ProbeError(f"{row['id']} must omit datacenters until verified geography provenance exists")
        if row.get("deployment_region") != "global-volunteer-fleet":
            raise ProbeError(f"{row['id']} deployment_region must be global-volunteer-fleet")
        if row.get("compliance", {}).get("zdr") is not False:
            raise ProbeError(f"{row['id']} must honestly declare compliance.zdr=false")
        slug = row.get("openrouter", {}).get("slug") if isinstance(row.get("openrouter"), dict) else None
        if not isinstance(slug, str) or not slug:
            raise ProbeError(f"{row['id']} must declare openrouter.slug")
        expected_slug = EXPECTED_OPENROUTER_SLUGS.get(row["id"])
        if expected_slug and slug != expected_slug:
            raise ProbeError(f"{row['id']} openrouter.slug={slug!r}, want {expected_slug!r}")
    if expected_model:
        paid = by_id.get(expected_model)
        if paid is None:
            raise ProbeError(f"models document missing requested model {expected_model}")
        if paid.get("is_free") is True:
            raise ProbeError(f"requested model {expected_model} must be the paid row, not free")
        if require_free_alias and paid.get("is_ready") is not True:
            raise ProbeError(f"requested model {expected_model} must be is_ready=true for filing mode")
    if require_free_alias:
        free_id = expected_free_model_id(expected_model)
        free = by_id.get(free_id)
        if free is None:
            raise ProbeError(f"filing-mode models document missing free alias {free_id}")
        if free.get("is_free") is not True:
            raise ProbeError(f"free alias {free_id} must declare is_free=true")
        if free.get("is_ready") is not True:
            raise ProbeError(f"free alias {free_id} must declare is_ready=true")
        prompt, completion = model_prices(free)
        if prompt != "0" or completion != "0":
            raise ProbeError(f"free alias {free_id} must declare zero prompt/completion pricing")
        slug = free.get("openrouter", {}).get("slug") if isinstance(free.get("openrouter"), dict) else ""
        if not isinstance(slug, str) or not slug.endswith(":free"):
            raise ProbeError(f"free alias {free_id} openrouter.slug must end with :free")
    return {"rows": len(rows), "ids": [row["id"] for row in rows]}


def check_privacy(base_url: str) -> dict:
    with http_request("GET", root_url(base_url, "/privacy")) as resp:
        raw = resp.read().decode("utf-8", "replace")
        status = response_status(resp)
        if status != 200:
            raise ProbeError(f"/privacy returned HTTP {status}")
    lower = raw.lower()
    required = (
        "plaintext",
        "no zero-data-retention",
        "compliance.zdr",
        "false",
        "90 days",
        "does not train foundation models on buyer prompts",
        "not stored as a training corpus",
    )
    for text in required:
        if text not in lower:
            raise ProbeError(f"/privacy missing disclosure: {text}")
    forbidden = (
        "private inference guaranteed",
        "zdr guarantee",
        '"zdr": true',
        "compliance.zdr=true",
        "compliance.zdr: true",
        "zero-data-retention guarantee is available",
        "we train foundation models on buyer prompts",
        "may train foundation models on buyer prompts",
    )
    for text in forbidden:
        if text in lower:
            raise ProbeError(f"/privacy contains forbidden claim: {text}")
    return {"http_status": 200, "mentions_90_days": True, "zdr_false": True, "training_corpus_denied": True}


def usage_is_valid(value: object) -> bool:
    if not isinstance(value, dict):
        return False
    keys = ("prompt_tokens", "completion_tokens", "total_tokens")
    return all(isinstance(value.get(key), int) and value[key] >= 0 for key in keys)


def extract_error_code(raw: bytes) -> str:
    try:
        payload = json.loads(raw.decode("utf-8"))
    except (UnicodeDecodeError, json.JSONDecodeError):
        return ""
    error = payload.get("error") if isinstance(payload, dict) else None
    if isinstance(error, dict):
        for key in ("code", "type"):
            value = error.get(key)
            if isinstance(value, str):
                return value
    return ""


def is_capacity_shed(result: dict) -> bool:
    return result.get("status") == 429 and result.get("error_code") == "no_provider_available"


def chat_once(base_url: str, token: str, model: str, *, stream: bool, max_tokens: int) -> dict:
    body = {
        "model": model,
        "messages": [{"role": "user", "content": DEFAULT_PROMPT}],
        "max_tokens": max_tokens,
        "stream": stream,
    }
    if stream:
        body["stream_options"] = {"include_usage": True}
    started = time.perf_counter()
    resp = http_request("POST", v1_url(base_url, "/chat/completions"), token=token, body=body, stream=stream, timeout=90)
    try:
        status = response_status(resp)
        if status != 200:
            raw = resp.read()
            return {
                "status": status,
                "ok": False,
                "error_code": extract_error_code(raw),
                "latency_ms": int((time.perf_counter() - started) * 1000),
            }
        if not stream:
            raw = resp.read()
            payload = json.loads(raw.decode("utf-8"))
            content = payload.get("choices", [{}])[0].get("message", {}).get("content")
            usage = payload.get("usage")
            return {
                "status": 200,
                "ok": bool(content) and usage_is_valid(usage),
                "usage_ok": usage_is_valid(usage),
                "content_ok": bool(content),
                "output_tokens": usage.get("completion_tokens", 0) if usage_is_valid(usage) else 0,
                "latency_ms": int((time.perf_counter() - started) * 1000),
            }
        saw_content = False
        saw_usage = False
        saw_keepalive = False
        first_content_ms = None
        usage = None
        for raw_line in resp:
            line = raw_line.decode("utf-8", "replace").strip()
            if not line:
                continue
            if line.startswith(":"):
                saw_keepalive = True
                continue
            if not line.startswith("data:"):
                continue
            data = line[5:].strip()
            if data == "[DONE]":
                break
            payload = json.loads(data)
            if usage_is_valid(payload.get("usage")):
                saw_usage = True
                usage = payload["usage"]
            choices = payload.get("choices") or []
            if choices and choices[0].get("delta", {}).get("content"):
                saw_content = True
                if first_content_ms is None:
                    first_content_ms = int((time.perf_counter() - started) * 1000)
        latency_ms = int((time.perf_counter() - started) * 1000)
        generation_ms = None
        if first_content_ms is not None:
            generation_ms = max(1, latency_ms - first_content_ms)
        return {
            "status": 200,
            "ok": saw_content and saw_usage,
            "usage_ok": saw_usage,
            "content_ok": saw_content,
            "keepalive_observed": saw_keepalive,
            "keepalive_evidence": "observed" if saw_keepalive else ("not_applicable_fast_stream" if latency_ms < GATEWAY_KEEPALIVE_TICK_SECONDS * 1000 else "missing"),
            "ttft_ms": first_content_ms,
            "latency_ms": latency_ms,
            "generation_ms": generation_ms,
            "output_tokens": usage.get("completion_tokens", 0) if usage_is_valid(usage) else 0,
        }
    finally:
        resp.close()


def check_chat(base_url: str, token: str, model: str, max_tokens: int) -> dict:
    non_stream = chat_once(base_url, token, model, stream=False, max_tokens=max_tokens)
    stream = chat_once(base_url, token, model, stream=True, max_tokens=max_tokens)
    if not non_stream.get("ok"):
        raise ProbeError(f"non-stream chat usage/content check failed: {non_stream}")
    if not stream.get("ok"):
        raise ProbeError(f"stream chat usage/content check failed: {stream}")
    if stream.get("keepalive_evidence") == "missing":
        raise ProbeError(f"stream lasted past keepalive tick without SSE comment keepalive: {stream}")
    return {"non_stream": non_stream, "stream": stream}


def percentile(values: list[int], pct: float) -> int:
    if not values:
        raise ProbeError("cannot compute percentile without samples")
    ordered = sorted(values)
    index = min(len(ordered) - 1, max(0, round((pct / 100) * (len(ordered) - 1))))
    return ordered[index]


def run_benchmark(
    base_url: str,
    token: str,
    model: str,
    requests: int,
    concurrency: int,
    max_tokens: int,
    min_success_ratio: float,
    max_ttft_p95_ms: int,
    min_output_tokens_per_second: float,
    require_429: bool = False,
) -> dict:
    if requests < 1:
        raise ProbeError("benchmark requests must be positive")
    if requests > MAX_BENCHMARK_REQUESTS:
        raise ProbeError(f"benchmark requests must be <= {MAX_BENCHMARK_REQUESTS}")
    if concurrency < 1 or concurrency > MAX_BENCHMARK_CONCURRENCY:
        raise ProbeError(f"benchmark concurrency must be in [1,{MAX_BENCHMARK_CONCURRENCY}]")
    if max_tokens < 1 or max_tokens > 128:
        raise ProbeError("benchmark max_tokens must be in [1,128]")
    started = time.perf_counter()
    results = []
    remaining = requests
    while remaining > 0:
        batch_size = min(concurrency, remaining)
        batch = []
        with ThreadPoolExecutor(max_workers=batch_size) as executor:
            futures = [executor.submit(chat_once, base_url, token, model, stream=True, max_tokens=max_tokens) for _ in range(batch_size)]
            for future in as_completed(futures):
                result = future.result()
                batch.append(result)
                results.append(result)
        remaining -= batch_size
        if require_429 and any(is_capacity_shed(result) for result in batch):
            break
    elapsed = max(time.perf_counter() - started, 0.001)
    statuses = {}
    ttfts = []
    generation_seconds = 0.0
    output_tokens = 0
    for result in results:
        statuses[str(result["status"])] = statuses.get(str(result["status"]), 0) + 1
        if result.get("ttft_ms") is not None:
            ttfts.append(result["ttft_ms"])
        if result.get("ok"):
            output_tokens += int(result.get("output_tokens") or 0)
            generation_seconds += max((int(result.get("generation_ms") or 0) / 1000), 0.001)
    ok_count = sum(1 for result in results if result.get("ok"))
    shed_count = sum(1 for result in results if is_capacity_shed(result))
    failed = [result for result in results if not result.get("ok") and not is_capacity_shed(result)]
    if failed:
        raise ProbeError(f"benchmark had non-capacity-shed failures: {failed[:3]}")
    success_ratio = ok_count / len(results)
    if success_ratio < min_success_ratio:
        raise ProbeError(f"benchmark success ratio {success_ratio:.3f} below required {min_success_ratio:.3f}; statuses={statuses}")
    if require_429 and shed_count < 1:
        raise ProbeError(f"saturation benchmark did not observe an early HTTP 429; statuses={statuses}")
    if require_429 and shed_count > 0 and ok_count == 0:
        return {
            "requests": requests,
            "requests_sent": len(results),
            "concurrency": concurrency,
            "elapsed_s": round(elapsed, 3),
            "requests_per_second": round(len(results) / elapsed, 3),
            "statuses": statuses,
            "ok": ok_count,
            "shed_429": shed_count,
            "success_ratio": round(success_ratio, 3),
            "ttft_ms_p50": None,
            "ttft_ms_p95": None,
            "ttft_ms_max": None,
            "output_tokens": output_tokens,
            "output_tokens_per_second": None,
        }
    if not ttfts:
        raise ProbeError("benchmark produced no successful TTFT samples")
    ttft_p95 = percentile(ttfts, 95)
    if max_ttft_p95_ms > 0 and ttft_p95 > max_ttft_p95_ms:
        raise ProbeError(f"benchmark TTFT p95 {ttft_p95}ms exceeds required {max_ttft_p95_ms}ms")
    generated_tokens_per_second = output_tokens / max(generation_seconds, 0.001)
    if min_output_tokens_per_second > 0 and generated_tokens_per_second < min_output_tokens_per_second:
        raise ProbeError(
            "benchmark generated-token throughput "
            f"{generated_tokens_per_second:.3f} tokens/s below required {min_output_tokens_per_second:.3f} tokens/s"
        )
    return {
        "requests": requests,
        "requests_sent": len(results),
        "concurrency": concurrency,
        "elapsed_s": round(elapsed, 3),
        "requests_per_second": round(len(results) / elapsed, 3),
        "statuses": statuses,
        "ok": ok_count,
        "shed_429": shed_count,
        "success_ratio": round(success_ratio, 3),
        "ttft_ms_p50": int(statistics.median(ttfts)) if ttfts else None,
        "ttft_ms_p95": ttft_p95,
        "ttft_ms_max": max(ttfts) if ttfts else None,
        "output_tokens": output_tokens,
        "output_tokens_per_second": round(generated_tokens_per_second, 3),
    }


def check_wholesale_statement(admin_url: str, token: str, account_id: str, period: str, require_free_line: bool = False) -> dict:
    endpoint = normalize_base_url(admin_url) + "/admin/ledger/wholesale-statements"
    statement, _ = read_json("POST", endpoint, token=token, body={"account_id": account_id, "period": period})
    statement_id = statement.get("wholesale_statement_id")
    if not isinstance(statement_id, str) or not statement_id:
        raise ProbeError("wholesale statement response missing wholesale_statement_id")
    if statement.get("account_id") != account_id:
        raise ProbeError(f"wholesale statement account_id mismatch: {statement.get('account_id')!r}")
    if statement.get("period") != period:
        raise ProbeError(f"wholesale statement period mismatch: {statement.get('period')!r}")
    if not isinstance(statement.get("usd_micro"), int) or statement["usd_micro"] < 0:
        raise ProbeError("wholesale statement usd_micro must be a non-negative integer")
    line_items = statement.get("line_items")
    if not isinstance(line_items, list) or not line_items:
        raise ProbeError("wholesale statement line_items must be a non-empty array")
    total_request_count = 0
    total_gross_credits = 0
    has_free_line = False
    positive_free_credit = False
    expected_by_model = {}
    for item in line_items:
        if not isinstance(item, dict):
            raise ProbeError("wholesale statement line item must be an object")
        model = item.get("model")
        if not isinstance(model, str) or not model:
            raise ProbeError(f"line item model must be non-empty: {item}")
        if model in expected_by_model:
            raise ProbeError(f"duplicate line item model: {model}")
        if item.get("is_free") is True:
            has_free_line = True
        if item.get("is_free") is True and item.get("usd_micro") != 0:
            raise ProbeError(f"free SKU line item charged non-zero usd_micro: {item}")
        if not isinstance(item.get("request_count"), int) or item["request_count"] < 0:
            raise ProbeError(f"line item request_count must be non-negative: {item}")
        if not isinstance(item.get("gross_credits"), int) or item["gross_credits"] < 0:
            raise ProbeError(f"line item gross_credits must be non-negative: {item}")
        if item["request_count"] > 0 and item["gross_credits"] <= 0:
            raise ProbeError(f"settled line item must carry positive gross_credits: {item}")
        if item.get("is_free") is True and item["request_count"] > 0 and item["gross_credits"] > 0:
            positive_free_credit = True
        total_request_count += item["request_count"]
        total_gross_credits += item["gross_credits"]
        expected_by_model[model] = item
    if total_request_count < 1:
        raise ProbeError("wholesale statement must include at least one settled request")
    if total_gross_credits < 1:
        raise ProbeError("wholesale statement must include positive provider credit evidence")
    if require_free_line and not has_free_line:
        raise ProbeError("filing-mode wholesale statement must include a free SKU line item")
    if require_free_line and not positive_free_credit:
        raise ProbeError("filing-mode wholesale statement must include a free SKU line item with positive provider credits")
    csv_url = endpoint + "/" + urllib.parse.quote(statement_id) + "?format=csv"
    with http_request("GET", csv_url, token=token) as resp:
        csv_body = resp.read().decode("utf-8", "replace")
        status = response_status(resp)
        if status != 200:
            raise ProbeError(f"statement CSV returned HTTP {status}")
    if "wholesale_statement_id" not in csv_body:
        raise ProbeError("statement CSV missing wholesale_statement_id header")
    if "invoice_id" in csv_body or "buyer_invoice" in csv_body:
        raise ProbeError("statement CSV leaked forbidden invoice naming")
    csv_rows = list(csv.DictReader(io.StringIO(csv_body)))
    if len(csv_rows) != len(line_items):
        raise ProbeError(f"statement CSV row count {len(csv_rows)} does not match JSON line items {len(line_items)}")
    for row in csv_rows:
        if row.get("wholesale_statement_id") != statement_id:
            raise ProbeError(f"statement CSV id mismatch: {row}")
        if row.get("account_id") != account_id:
            raise ProbeError(f"statement CSV account mismatch: {row}")
        if row.get("period") != period:
            raise ProbeError(f"statement CSV period mismatch: {row}")
        model = row.get("model", "")
        expected = expected_by_model.get(model)
        if expected is None:
            raise ProbeError(f"statement CSV has unexpected model row: {row}")
        for key in ("request_count", "gross_credits", "usd_micro"):
            try:
                parsed = int(row.get(key, ""))
            except ValueError as exc:
                raise ProbeError(f"statement CSV {key} must be integer: {row}") from exc
            if parsed != expected[key]:
                raise ProbeError(f"statement CSV {key} mismatch for {model}: {parsed} != {expected[key]}")
        if str(expected["is_free"]).lower() != row.get("is_free", "").lower():
            raise ProbeError(f"statement CSV is_free mismatch for {model}: {row}")
    return {
        "wholesale_statement_id": statement_id,
        "account_id": account_id,
        "period": period,
        "line_items": len(line_items),
        "request_count": total_request_count,
        "gross_credits": total_gross_credits,
        "has_free_line": has_free_line,
        "positive_free_credit": positive_free_credit,
        "usd_micro": statement["usd_micro"],
        "csv_ok": True,
    }


def load_token(env_name: str, path: str) -> str:
    token = os.environ.get(env_name, "")
    if token:
        return token.strip()
    if path:
        return Path(path).read_text(encoding="utf-8").strip()
    return ""


def main(argv: list[str]) -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--base-url", default="https://api.malibu.tech")
    parser.add_argument("--api-key-env", default="MACPROVIDER_SPEC015_API_KEY")
    parser.add_argument("--api-key-file", default="")
    parser.add_argument("--model", default=DEFAULT_MODEL)
    parser.add_argument("--max-tokens", type=int, default=16)
    parser.add_argument("--benchmark-requests", type=int, default=0)
    parser.add_argument("--benchmark-concurrency", type=int, default=4)
    parser.add_argument("--min-success-ratio", type=float, default=DEFAULT_MIN_SUCCESS_RATIO)
    parser.add_argument("--max-ttft-p95-ms", type=int, default=DEFAULT_MAX_TTFT_P95_MS)
    parser.add_argument("--min-output-tokens-per-second", type=float, default=DEFAULT_MIN_OUTPUT_TOKENS_PER_SECOND)
    parser.add_argument("--saturation-requests", type=int, default=0)
    parser.add_argument("--saturation-concurrency", type=int, default=8)
    parser.add_argument("--admin-url", default="")
    parser.add_argument("--operator-key-env", default="OPERATOR_KEY")
    parser.add_argument("--operator-key-file", default="")
    parser.add_argument("--statement-account-id", default="")
    parser.add_argument("--statement-period", default="")
    parser.add_argument("--continue-on-error", action="store_true", help="collect later checks even when an earlier check fails")
    parser.add_argument("--filing-mode", action="store_true", help="fail unless chat, benchmark, and statement evidence are all collected")
    parser.add_argument("--output", default="", help="write the JSON report to this path")
    args = parser.parse_args(argv)
    if args.min_success_ratio < 0 or args.min_success_ratio > 1:
        raise SystemExit("--min-success-ratio must be in [0,1]")
    if args.filing_mode:
        if args.benchmark_requests < 100:
            raise SystemExit("--filing-mode requires --benchmark-requests >= 100")
        if args.saturation_requests < 1:
            raise SystemExit("--filing-mode requires --saturation-requests > 0")
        if not (args.admin_url and args.statement_account_id and args.statement_period):
            raise SystemExit("--filing-mode requires --admin-url, --statement-account-id, and --statement-period")

    report = {"base_url": args.base_url, "model": args.model, "checks": {}}
    errors = []

    def record_check(name: str, fn):
        try:
            report["checks"][name] = fn()
        except ProbeError as exc:
            report["checks"][name] = {"ok": False, "error": str(exc)}
            errors.append(f"{name}: {exc}")
            if not args.continue_on_error:
                raise

    try:
        record_check(
            "models",
            lambda: check_models_document(
                read_json("GET", v1_url(args.base_url, "/openrouter/models"))[0],
                args.model,
                args.filing_mode,
            ),
        )
        record_check("privacy", lambda: check_privacy(args.base_url))
        token = load_token(args.api_key_env, args.api_key_file)
        if token:
            record_check("chat", lambda: check_chat(args.base_url, token, args.model, args.max_tokens))
            if args.filing_mode:
                record_check("chat_free", lambda: check_chat(args.base_url, token, expected_free_model_id(args.model), args.max_tokens))
            if args.benchmark_requests > 0:
                record_check(
                    "benchmark",
                    lambda: run_benchmark(
                        args.base_url,
                        token,
                        args.model,
                        args.benchmark_requests,
                        args.benchmark_concurrency,
                        args.max_tokens,
                        args.min_success_ratio,
                        args.max_ttft_p95_ms,
                        args.min_output_tokens_per_second,
                    ),
                )
            if args.saturation_requests > 0:
                record_check(
                    "saturation",
                    lambda: run_benchmark(
                        args.base_url,
                        token,
                        args.model,
                        args.saturation_requests,
                        args.saturation_concurrency,
                        args.max_tokens,
                        0.0,
                        args.max_ttft_p95_ms,
                        0.0,
                        True,
                    ),
                )
        else:
            report["checks"]["chat"] = {"skipped": "missing API key"}
            report["checks"]["benchmark"] = {"skipped": "missing API key"}
            report["checks"]["saturation"] = {"skipped": "missing API key"}
            if args.filing_mode:
                errors.append("filing mode requires API key")
        operator_token = load_token(args.operator_key_env, args.operator_key_file)
        if args.admin_url and operator_token and args.statement_account_id and args.statement_period:
            record_check(
                "wholesale_statement",
                lambda: check_wholesale_statement(
                    args.admin_url,
                    operator_token,
                    args.statement_account_id,
                    args.statement_period,
                    args.filing_mode,
                ),
            )
        else:
            report["checks"]["wholesale_statement"] = {"skipped": "admin URL, operator key, account id, or period missing"}
            if args.filing_mode:
                errors.append("filing mode requires wholesale statement evidence")
    except ProbeError as exc:
        report["ok"] = False
        report["error"] = str(exc)
        return finish(report, args.output, 1)
    if errors:
        report["ok"] = False
        report["errors"] = errors
        return finish(report, args.output, 1)
    report["ok"] = True
    return finish(report, args.output, 0)


def finish(report: dict, output: str, code: int) -> int:
    try:
        emit_report(report, output)
    except ProbeError as exc:
        report["ok"] = False
        report["output_error"] = str(exc)
        print(json.dumps(report, indent=2, sort_keys=True))
        return 1
    return code


def emit_report(report: dict, output: str) -> None:
    rendered = json.dumps(report, indent=2, sort_keys=True)
    if output:
        path = Path(output)
        path.parent.mkdir(mode=0o700, parents=True, exist_ok=True)
        flags = os.O_WRONLY | os.O_CREAT | os.O_EXCL
        if hasattr(os, "O_NOFOLLOW"):
            flags |= os.O_NOFOLLOW
        try:
            fd = os.open(path, flags, 0o600)
        except FileExistsError as exc:
            raise ProbeError(f"refusing to overwrite existing report: {path}") from exc
        except OSError as exc:
            raise ProbeError(f"cannot create report safely at {path}: {exc}") from exc
        with os.fdopen(fd, "w", encoding="utf-8") as handle:
            handle.write(rendered + "\n")
    print(rendered)


if __name__ == "__main__":
    raise SystemExit(main(sys.argv[1:]))
