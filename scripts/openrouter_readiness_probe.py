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
import math
import os
import re
import statistics
import sys
import threading
import time
import urllib.error
import urllib.parse
import urllib.request
import uuid
from concurrent.futures import TimeoutError as FuturesTimeout
from concurrent.futures import ThreadPoolExecutor, as_completed
from pathlib import Path


DEFAULT_MODEL = "mlx-community/Llama-3.2-3B-Instruct-4bit"
DEFAULT_PROMPT = "OpenRouter provider readiness smoke. Reply with OK."
MAX_BENCHMARK_REQUESTS = 200
MAX_BENCHMARK_CONCURRENCY = 8
DEFAULT_MIN_SUCCESS_RATIO = 0.95
DEFAULT_MAX_TTFT_P95_MS = 5000
DEFAULT_MIN_OUTPUT_TOKENS_PER_SECOND = 10.0
DEFAULT_LOAD_LADDER_VALUES = (1, 2, 4, 8)
DEFAULT_LOAD_LADDER = ",".join(str(value) for value in DEFAULT_LOAD_LADDER_VALUES)
DEFAULT_BENCHMARK_CONCURRENCY = 4
DEFAULT_SATURATION_CONCURRENCY = 8
PRODUCTION_BASE_URL = "https://api.malibu.tech"
PRODUCTION_ADMIN_URL = "https://coordinator.malibu.tech"
FILING_MAX_REQUESTS_PER_MINUTE_PER_SLOT = 60
FILING_MAX_TOKENS_PER_MINUTE_PER_SLOT = 120_000
GATEWAY_KEEPALIVE_TICK_SECONDS = 15
BENCHMARK_BATCH_TIMEOUT_SECONDS = 120
LOCAL_AUTH_HOSTS = {"localhost", "127.0.0.1", "::1"}
# Canonical OpenRouter identity for every recommendable priced-v1 catalog row
# (published-2026-09-19-openrouter-priced-v1, 17 rows). The Mac Studio 256GB
# promotion (#1612) added the eight upper-RAM rows (gpt-oss-120b, GLM-4.5-Air,
# Qwen3.5/3.6/3.8 27B + 35B-A3B, Qwen3-30B-Instruct-2507) on top of the nine
# rows #1618 already pinned. Tuple: catalog_key, served pool id, OpenRouter
# slug, dual-free SKU. Slugs are org-prefixed to match the gateway convention
# (cf. the shipped "qwen/qwen3-8b"). The pin only fires for a model that is
# actually present in /v1/openrouter/models, so listing a row here is inert
# until openRouterListings exposes that family; when it does, OpenRouterSlug
# must equal the value below.
CATALOG_OPENROUTER_ROWS = (
    ("meta-llama/llama-3.2-3b-instruct", "mlx-community/Llama-3.2-3B-Instruct-4bit", "meta-llama/llama-3.2-3b-instruct", True),
    ("meta-llama/llama-3.1-8b-instruct", "mlx-community/Meta-Llama-3.1-8B-Instruct-4bit", "meta-llama/llama-3.1-8b-instruct", False),
    ("qwen3-8b", "mlx-community/Qwen3-8B-4bit", "qwen/qwen3-8b", False),
    ("qwen3-32b", "mlx-community/Qwen3-32B-4bit", "qwen/qwen3-32b", False),
    ("qwen2.5-coder-32b-instruct", "mlx-community/Qwen2.5-Coder-32B-Instruct-4bit", "qwen/qwen2.5-coder-32b-instruct", False),
    ("qwen3-coder-30b-a3b-instruct", "mlx-community/Qwen3-Coder-30B-A3B-Instruct-4bit", "qwen/qwen3-coder-30b-a3b-instruct", False),
    ("google-gemma-4-26b-a4b-it", "mlx-community/gemma-4-26b-a4b-it-4bit", "google/gemma-4-26b-a4b-it", False),
    ("openai/gpt-oss-20b", "mlx-community/gpt-oss-20b-MXFP4-Q8", "openai/gpt-oss-20b", False),
    ("nvidia/nemotron-3-nano-30b-a3b", "mlx-community/NVIDIA-Nemotron-3-Nano-30B-A3B-4bit", "nvidia/nemotron-3-nano-30b-a3b", False),
    ("openai/gpt-oss-120b", "mlx-community/gpt-oss-120b-4bit", "openai/gpt-oss-120b", False),
    ("qwen/qwen3-30b-a3b-instruct-2507", "mlx-community/Qwen3-30B-A3B-Instruct-2507-4bit", "qwen/qwen3-30b-a3b-instruct-2507", False),
    ("qwen/qwen3.5-27b", "mlx-community/Qwen3.5-27B-4bit", "qwen/qwen3.5-27b", False),
    ("qwen/qwen3.5-35b-a3b", "mlx-community/Qwen3.5-35B-A3B-4bit", "qwen/qwen3.5-35b-a3b", False),
    ("qwen/qwen3.6-27b", "mlx-community/Qwen3.6-27B-4bit", "qwen/qwen3.6-27b", False),
    ("qwen/qwen3.6-35b-a3b", "mlx-community/Qwen3.6-35B-A3B-4bit", "qwen/qwen3.6-35b-a3b", False),
    ("qwen/qwen3.8-27b", "mlx-community/Qwen3.8-27B-4bit", "qwen/qwen3.8-27b", False),
    ("z-ai/glm-4.5-air", "mlx-community/GLM-4.5-Air-4bit", "z-ai/glm-4.5-air", False),
)
DEFAULT_CATALOG_PATH = Path(__file__).resolve().parents[1] / "phase3-binary/catalog/autotune/autotune-candidates.json"


def _catalog_key_to_model_id() -> dict[str, str]:
    return {catalog_key: model_id for catalog_key, model_id, _slug, _dual_free in CATALOG_OPENROUTER_ROWS}


def _expected_openrouter_slugs() -> dict[str, str]:
    slugs = {}
    for _catalog_key, model_id, slug, dual_free in CATALOG_OPENROUTER_ROWS:
        slugs[model_id] = slug
        if dual_free:
            slugs[model_id + "-free"] = slug + ":free"
    return slugs


CATALOG_KEY_TO_MODEL_ID = _catalog_key_to_model_id()
EXPECTED_OPENROUTER_SLUGS = _expected_openrouter_slugs()


def catalog_paid_model_ids() -> tuple[str, ...]:
    return tuple(model_id for _catalog_key, model_id, _slug, _dual_free in CATALOG_OPENROUTER_ROWS)


def resolve_probe_model(model: str) -> str:
    """Accept a served pool id, catalog key, or already-resolved id."""
    if not isinstance(model, str) or not model:
        return model
    if model in EXPECTED_OPENROUTER_SLUGS:
        return model
    mapped = CATALOG_KEY_TO_MODEL_ID.get(model)
    if mapped:
        return mapped
    if model.endswith("-free"):
        paid = resolve_probe_model(model[: -len("-free")])
        if paid != model[: -len("-free")]:
            return expected_free_model_id(paid)
    return model


def models_equivalent(left: str, right: str) -> bool:
    return resolve_probe_model(left) == resolve_probe_model(right)


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


class BenchmarkProbeError(ProbeError):
    def __init__(self, message: str, evidence: dict | None = None):
        super().__init__(message)
        self.evidence = evidence or {}


class EvidenceProbeError(ProbeError):
    def __init__(self, message: str, evidence: dict | None = None):
        super().__init__(message)
        self.evidence = evidence or {}


class SettlementLagError(ProbeError):
    pass


class BenchmarkResponseTracker:
    def __init__(self):
        self._lock = threading.Lock()
        self._cancelled = False
        self._responses = set()

    def register(self, resp) -> bool:
        with self._lock:
            if self._cancelled:
                close_response(resp)
                return False
            self._responses.add(resp)
            return True

    def unregister(self, resp) -> None:
        with self._lock:
            self._responses.discard(resp)

    def cancelled(self) -> bool:
        with self._lock:
            return self._cancelled

    def cancel(self) -> None:
        with self._lock:
            self._cancelled = True
            responses = list(self._responses)
        for resp in responses:
            close_response(resp)


def close_response(resp) -> None:
    try:
        resp.close()
    except Exception:
        pass


class NoRedirectHandler(urllib.request.HTTPRedirectHandler):
    def redirect_request(self, req, fp, code, msg, headers, newurl):
        raise ProbeError(f"refusing redirect from {req.full_url} to {newurl}")


NO_REDIRECT_OPENER = urllib.request.build_opener(NoRedirectHandler)


def http_request(
    method: str,
    url: str,
    *,
    token: str = "",
    body: object | None = None,
    stream: bool = False,
    timeout: float = 45.0,
    request_id: str = "",
):
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
    if request_id:
        headers["X-Request-ID"] = request_id
    req = urllib.request.Request(url, data=data, headers=headers, method=method)
    try:
        return NO_REDIRECT_OPENER.open(req, timeout=timeout)
    except ProbeError:
        raise
    except urllib.error.HTTPError as exc:
        return exc
    except urllib.error.URLError as exc:
        raise ProbeError(str(exc)) from exc
    except TimeoutError as exc:
        raise ProbeError(f"request timed out: {url}") from exc


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


def check_decimal(value: object, label: str) -> decimal.Decimal:
    if not isinstance(value, str) or not value or value.startswith("-"):
        raise ProbeError(f"{label} must be a non-negative decimal string")
    try:
        parsed = decimal.Decimal(value)
    except decimal.InvalidOperation as exc:
        raise ProbeError(f"{label} must parse as decimal") from exc
    if not parsed.is_finite() or parsed < 0:
        raise ProbeError(f"{label} must be a finite non-negative decimal string")
    return parsed


def is_non_negative_int(value: object) -> bool:
    return isinstance(value, int) and not isinstance(value, bool) and value >= 0


def is_positive_int(value: object) -> bool:
    return isinstance(value, int) and not isinstance(value, bool) and value >= 1


def usd_micro_string(micro: int) -> str:
    if micro == 0:
        return "0"
    sign = "-" if micro < 0 else ""
    micro = abs(micro)
    return f"{sign}{micro // 1_000_000}.{micro % 1_000_000:06d}"


def is_non_empty_text(value: object) -> bool:
    return isinstance(value, str) and value.strip() != ""


def check_capacity(entries: object, label: str, expected_types: set[str]) -> dict[str, int]:
    if not isinstance(entries, list) or not entries:
        raise ProbeError(f"{label} must be a non-empty capacity array")
    observed_types = set()
    values = {}
    for entry in entries:
        if not isinstance(entry, dict):
            raise ProbeError(f"{label} entries must be objects")
        capacity_type = entry.get("type")
        if capacity_type not in expected_types:
            raise ProbeError(f"{label} type must be one of {sorted(expected_types)}")
        if capacity_type in observed_types:
            raise ProbeError(f"{label} duplicate capacity type {capacity_type}")
        observed_types.add(capacity_type)
        if not is_positive_int(entry.get("value")):
            raise ProbeError(f"{label} value must be a positive integer")
        values[capacity_type] = entry["value"]
        if capacity_type == "concurrency":
            if entry.get("unit") != "request":
                raise ProbeError(f"{label} concurrency unit must be request")
            if "per" in entry:
                raise ProbeError(f"{label} concurrency entries must not declare a per window")
            continue
        expected_unit = "request" if capacity_type == "request" else "token"
        if entry.get("unit") != expected_unit:
            raise ProbeError(f"{label} {capacity_type} unit must be {expected_unit}")
        if entry.get("per") not in {"minute", "hour", "day"}:
            raise ProbeError(f"{label} non-concurrency entries need a valid per window")
    if observed_types != expected_types:
        raise ProbeError(f"{label} must declare capacity types {sorted(expected_types)}")
    return values


def check_pricing(entry: object, label: str, expected_type: str) -> decimal.Decimal:
    if not isinstance(entry, dict):
        raise ProbeError(f"{label} pricing must be an object")
    if entry.get("type") != expected_type:
        raise ProbeError(f"{label} pricing type must be {expected_type}")
    if entry.get("unit") != "token":
        raise ProbeError(f"{label} pricing unit must be token")
    return check_decimal(entry.get("cost_usd"), f"{label} cost_usd")


def validate_supported_parameters(params: dict, model_id: str) -> None:
    max_tokens = params.get("max_tokens")
    if not isinstance(max_tokens, dict) or max_tokens.get("type") != "integer":
        raise ProbeError(f"{model_id} max_tokens supported parameter must be an integer descriptor")
    if not is_positive_int(max_tokens.get("min")) or not is_positive_int(max_tokens.get("max")) or max_tokens["max"] < max_tokens["min"]:
        raise ProbeError(f"{model_id} max_tokens supported parameter must have positive min/max")
    if max_tokens.get("unit") != "token":
        raise ProbeError(f"{model_id} max_tokens supported parameter unit must be token")
    for name in ("temperature", "top_p"):
        param = params.get(name)
        if not isinstance(param, dict) or param.get("type") != "range":
            raise ProbeError(f"{model_id} {name} supported parameter must be a range descriptor")
        low = param.get("min")
        high = param.get("max")
        if not isinstance(low, (int, float)) or isinstance(low, bool) or not isinstance(high, (int, float)) or isinstance(high, bool) or high < low:
            raise ProbeError(f"{model_id} {name} supported parameter must have numeric min/max")
    stop = params.get("stop")
    if not isinstance(stop, dict) or stop.get("type") != "array" or not is_positive_int(stop.get("max_items")):
        raise ProbeError(f"{model_id} stop supported parameter must be an array descriptor")
    stream = params.get("stream")
    if not isinstance(stream, dict) or stream.get("type") != "boolean":
        raise ProbeError(f"{model_id} stream supported parameter must be a boolean descriptor")


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


def privacy_sentences(text: str) -> list[str]:
    return [part.strip() for part in re.split(r"[.!?\n]+", text) if part.strip()]


def privacy_claim_segments(sentence: str) -> list[str]:
    return [part.strip() for part in re.split(r"(?:;|,|\bbut\b|\bhowever\b|\bthough\b)", sentence) if part.strip()]


def sentence_has_privacy_negation(sentence: str) -> bool:
    return bool(re.search(r"\b(no|not|never|without|neither|does not|do not|did not|doesn't|don't|didn't)\b", sentence))


def privacy_claim_is_denial(segment: str, claim_terms: tuple[str, ...]) -> bool:
    if not any(term in segment for term in claim_terms):
        return False
    claim_group = "|".join(re.escape(term) for term in claim_terms)
    denial_patterns = (
        r"\b(?:does not|do not|did not|doesn't|don't|didn't|never|not)\s+"
        r"(?:train|training|fine[- ]?tun(?:e|ing))\b",
        r"\b(?:does not|do not|did not|doesn't|don't|didn't|never|not)\s+"
        r"(?:train|training|fine[- ]?tun(?:e|ing)|use|uses|used|store|stores|stored|retain|retains|retained|keep|keeps|kept)\b"
        r"[^,;]{0,80}\b(" + claim_group + r")\b",
        r"\b(?:is|are|was|were|be|being|been)?\s*(?:never|not)\s+"
        r"(?:used|stored|retained|kept)\b[^,;]{0,80}\b(" + claim_group + r")\b",
        r"\bnot\s+stored\s+as\s+(?:a\s+)?training\s+corpus\b",
    )
    return any(re.search(pattern, segment) for pattern in denial_patterns)


def sentence_refers_to_prompt_records(sentence: str, previous_sentence: str, prompt_terms: tuple[str, ...]) -> bool:
    if any(term in sentence for term in prompt_terms):
        return True
    record_references = ("those records", "the records", "those data", "that data", "this data", "they")
    return any(term in previous_sentence for term in prompt_terms) and any(ref in sentence for ref in record_references)


def catalog_coverage(by_id: dict) -> dict:
    paid_ids = catalog_paid_model_ids()
    listed = [model_id for model_id in paid_ids if model_id in by_id]
    unlisted = [model_id for model_id in paid_ids if model_id not in by_id]
    return {
        "catalog_paid_rows": len(paid_ids),
        "catalog_listed_ids": listed,
        "catalog_unlisted_ids": unlisted,
        "catalog_listed_rows": len(listed),
    }


def check_models_document(doc: dict, expected_model: str = "", require_free_alias: bool = False) -> dict:
    expected_model = resolve_probe_model(expected_model) if expected_model else expected_model
    rows = doc.get("data")
    if not isinstance(rows, list) or not rows:
        raise ProbeError("models document must contain non-empty data array")
    by_id = {}
    capacities_by_id = {}
    for row in rows:
        if not isinstance(row, dict):
            raise ProbeError("model rows must be objects")
        row_id = row.get("id")
        if not isinstance(row_id, str) or not row_id:
            raise ProbeError("model rows must have a non-empty string id")
        if row_id in by_id:
            raise ProbeError(f"duplicate model id: {row_id}")
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
        if not isinstance(max_context, dict) or not is_positive_int(max_context.get("value")) or max_context.get("unit") != "token":
            raise ProbeError(f"{row['id']} text max_context_length must be positive token value")
        max_length = text_out.get("max_length")
        if not isinstance(max_length, dict) or not is_positive_int(max_length.get("value")) or max_length.get("unit") != "token":
            raise ProbeError(f"{row['id']} output max_length must be positive token value")
        input_prices = text_in.get("pricing")
        output_prices = text_out.get("pricing")
        if not isinstance(input_prices, list) or not input_prices:
            raise ProbeError(f"{row['id']} must declare input pricing")
        if not isinstance(output_prices, list) or not output_prices:
            raise ProbeError(f"{row['id']} must declare output pricing")
        input_cost = check_pricing(input_prices[0], f"{row['id']} prompt", "prompt")
        output_cost = check_pricing(output_prices[0], f"{row['id']} completion", "completion")
        if row.get("is_free") is False and (input_cost <= 0 or output_cost <= 0):
            raise ProbeError(f"{row['id']} paid model pricing must be positive")
        if not isinstance(row.get("is_free"), bool):
            raise ProbeError(f"{row['id']} is_free must be boolean")
        if not isinstance(row.get("is_ready"), bool):
            raise ProbeError(f"{row['id']} is_ready must be boolean")
        if text_out.get("streaming") is not True:
            raise ProbeError(f"{row['id']} output streaming must be true")
        if not isinstance(text_out.get("supported_parameters"), dict):
            raise ProbeError(f"{row['id']} output supported_parameters must be an object")
        for param in ("max_tokens", "temperature", "top_p", "stop", "stream"):
            if param not in text_out["supported_parameters"]:
                raise ProbeError(f"{row['id']} missing supported parameter {param}")
        validate_supported_parameters(text_out["supported_parameters"], row["id"])
        root_capacity = check_capacity(row.get("capacity"), f"{row['id']} root capacity", {"request", "concurrency"})
        input_capacity = check_capacity(text_in.get("capacity"), f"{row['id']} input capacity", {"prompt"})
        output_capacity = check_capacity(text_out.get("capacity"), f"{row['id']} output capacity", {"completion"})
        capacities_by_id[row["id"]] = {
            "root": root_capacity,
            "input": input_capacity,
            "output": output_capacity,
        }
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
        if paid.get("is_free") is not False:
            raise ProbeError(f"requested model {expected_model} must be the paid row with is_free=false")
        if require_free_alias and paid.get("is_ready") is not True:
            raise ProbeError(f"requested model {expected_model} must be is_ready=true for filing mode")
    coverage = catalog_coverage(by_id)
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
    result = {"rows": len(rows), "ids": [row["id"] for row in rows], "capacities": capacities_by_id}
    result.update(coverage)
    return result


def check_model_capacity_against_pool(models_check: dict, pool_check: dict, expected_model: str) -> dict:
    expected_model = resolve_probe_model(expected_model)
    capacities = models_check.get("capacities") if isinstance(models_check, dict) else None
    if not isinstance(capacities, dict):
        raise ProbeError("models check missing normalized capacity evidence")
    free_id = expected_free_model_id(expected_model)
    paid = capacities.get(expected_model)
    free = capacities.get(free_id)
    if not isinstance(paid, dict) or not isinstance(free, dict):
        raise ProbeError("models check missing paid/free capacity evidence")
    slots_total = pool_check.get("matching_slots_total") if isinstance(pool_check, dict) else None
    if not is_positive_int(slots_total):
        raise ProbeError("pool topology missing positive matching slot capacity")
    paid_concurrency = paid["root"]["concurrency"]
    free_concurrency = free["root"]["concurrency"]
    combined_concurrency = paid_concurrency + free_concurrency
    max_requests_per_minute = slots_total * FILING_MAX_REQUESTS_PER_MINUTE_PER_SLOT
    max_tokens_per_minute = slots_total * FILING_MAX_TOKENS_PER_MINUTE_PER_SLOT
    paid_requests = paid["root"]["request"]
    free_requests = free["root"]["request"]
    combined_requests = paid_requests + free_requests
    combined_prompt = paid["input"]["prompt"] + free["input"]["prompt"]
    combined_completion = paid["output"]["completion"] + free["output"]["completion"]
    evidence = {
        "expected_model": expected_model,
        "expected_free_model": free_id,
        "matching_slots_total": slots_total,
        "combined_concurrency": combined_concurrency,
        "max_concurrency": slots_total,
        "combined_request_per_minute": combined_requests,
        "max_request_per_minute": max_requests_per_minute,
        "combined_prompt_tokens_per_minute": combined_prompt,
        "combined_completion_tokens_per_minute": combined_completion,
        "max_tokens_per_minute": max_tokens_per_minute,
    }
    if combined_concurrency > slots_total:
        raise EvidenceProbeError("model capacity exceeds live pool concurrency", evidence)
    if combined_requests > max_requests_per_minute:
        raise EvidenceProbeError("model request capacity exceeds conservative live pool bound", evidence)
    if combined_prompt > max_tokens_per_minute or combined_completion > max_tokens_per_minute:
        raise EvidenceProbeError("model token capacity exceeds conservative live pool bound", evidence)
    evidence["classification"] = "model_capacity_consistent"
    return evidence


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
        "enables compliance.zdr",
        "compliance.zdr for all requests",
        "zero-data-retention guarantee is available",
        "opt in to zero data retention",
        "we train foundation models on buyer prompts",
        "may train foundation models on buyer prompts",
        "we train adapters on buyer prompts",
        "buyer prompts train adapters",
        "train adapters on buyer prompts",
        "training adapters on buyer prompts",
        "adapter training on buyer prompts",
        "buyer prompts may be used to fine-tune",
        "buyer prompts are eligible for fine-tuning",
        "buyer prompts are used for fine-tuning",
        "we fine-tune derivative models with buyer prompts",
        "we fine-tune derivative models using buyer prompts",
        "buyer prompts sometimes train adapters",
        "prompt data is incorporated into fine-tuning datasets",
        "prompts may be used to fine-tune",
        "used to fine-tune derivative models",
        "used for fine-tuning derivative models",
        "used to train derivative models",
    )
    for text in forbidden:
        if text in lower:
            raise ProbeError(f"/privacy contains forbidden claim: {text}")
    forbidden_patterns = (
        r"\b(prompt|prompts|buyer prompts|prompt data|prompt records)\b[^.]{0,120}\b(may|can|could|will|used to|use to|used for|use for|used in|eligible for|incorporated into|sometimes)\b[^.]{0,100}\b(fine[- ]?tun(?:e|ing)|train|training|adapters?|datasets?|models?)\b",
        r"\b(fine[- ]?tun(?:e|ing)|train|training|adapters?|datasets?|models?)\b[^.]{0,120}\b(may|can|could|will|used to|use to|used for|use for|using|with|on)\b[^.]{0,100}\b(prompt|prompts|buyer prompts|prompt data|prompt records)\b",
    )
    for sentence in privacy_sentences(lower):
        for segment in privacy_claim_segments(sentence):
            if privacy_claim_is_denial(segment, ("train", "training", "fine-tune", "fine tuning", "fine-tuning")):
                continue
            for pattern in forbidden_patterns:
                if re.search(pattern, segment):
                    raise ProbeError(f"/privacy contains forbidden training/fine-tuning claim matching {pattern}")
    prompt_terms = ("buyer prompts", "prompt data", "prompt records")
    derivative_training_terms = (
        "train adapters",
        "training adapters",
        "adapter training",
        "train our adapters",
        "adapter/training data",
        "training data for adapters",
        "training material for adapters",
        "training data for derivative models",
        "examples for adapter optimization",
        "adapter optimization",
        "derivative model training",
        "fine-tune derivative",
        "fine tuning derivative",
        "fine-tuning derivative",
        "fine-tuning dataset",
        "fine tuning dataset",
        "training material",
        "training materials",
    )
    prior_prompt_context = ""
    for sentence in privacy_sentences(lower):
        prompt_context = prior_prompt_context
        for segment in privacy_claim_segments(sentence):
            if privacy_claim_is_denial(segment, derivative_training_terms):
                continue
            if sentence_refers_to_prompt_records(segment, prompt_context, prompt_terms) and any(
                term in segment for term in derivative_training_terms
            ):
                raise ProbeError("/privacy contains forbidden prompt derivative-training claim")
            if any(term in segment for term in prompt_terms):
                prompt_context = segment
        if any(term in sentence for term in prompt_terms):
            prior_prompt_context = sentence
            continue
        if not any(ref in sentence for ref in ("those records", "the records", "those data", "that data", "this data", "they")):
            prior_prompt_context = ""
    zdr_offer_patterns = (
        r"\b(opt[- ]?in|enable[sd]?|available|offer(?:ed|s)?|provid(?:e|es|ed|ing)?|mode)\b[^.]{0,120}\bzero[- ]?data[- ]?retention\b",
        r"\bzero[- ]?data[- ]?retention\b[^.]{0,120}\b(opt[- ]?in|enable[sd]?|available|offer(?:ed|s)?|provid(?:e|es|ed|ing)?|mode)\b",
        r"\b(opt[- ]?in|enable[sd]?|available|offer(?:ed|s)?|provid(?:e|es|ed|ing)?|mode|request|support)\b[^.]{0,120}\bzdr\b",
        r"\bzdr\b[^.]{0,120}\b(opt[- ]?in|enable[sd]?|available|offer(?:ed|s)?|provid(?:e|es|ed|ing)?|mode|request|support)\b",
    )
    for pattern in zdr_offer_patterns:
        if re.search(pattern, lower):
            raise ProbeError(f"/privacy contains forbidden zero-data-retention offer matching {pattern}")
    return {"http_status": 200, "mentions_90_days": True, "zdr_false": True, "training_corpus_denied": True}


def check_healthz(base_url: str, expected_version: str = "") -> dict:
    payload, status = read_json("GET", root_url(base_url, "/healthz"))
    service_status = payload.get("status")
    if service_status != "ok":
        raise ProbeError(f"/healthz status={service_status!r}, want 'ok'")
    version = payload.get("version")
    if not isinstance(version, str) or not version:
        raise ProbeError("/healthz missing non-empty version")
    if expected_version and version != expected_version:
        raise ProbeError(f"/healthz version={version!r}, want {expected_version!r}")
    result = {"http_status": status, "status": service_status, "version": version}
    if expected_version:
        result["expected_version"] = expected_version
    return result


def usage_is_valid(value: object) -> bool:
    if not isinstance(value, dict):
        return False
    keys = ("prompt_tokens", "completion_tokens", "total_tokens")
    if not all(is_non_negative_int(value.get(key)) for key in keys):
        return False
    if value["prompt_tokens"] < 1 or value["completion_tokens"] < 1:
        return False
    return value["total_tokens"] == value["prompt_tokens"] + value["completion_tokens"]


def response_content_type(resp: object) -> str:
    getter = getattr(resp, "getheader", None)
    if callable(getter):
        value = getter("Content-Type", "")
        return value.lower() if isinstance(value, str) else ""
    headers = getattr(resp, "headers", {})
    if isinstance(headers, dict):
        value = headers.get("Content-Type") or headers.get("content-type") or ""
        return value.lower() if isinstance(value, str) else ""
    return ""


def content_type_matches(resp: object, expected: str) -> bool:
    content_type = response_content_type(resp)
    return bool(content_type) and content_type.split(";", 1)[0].strip() == expected


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


def payload_error_code(payload: object) -> str:
    if not isinstance(payload, dict) or "error" not in payload:
        return ""
    error = payload.get("error")
    if isinstance(error, str) and error:
        return error
    if isinstance(error, dict):
        for key in ("code", "type", "message"):
            value = error.get(key)
            if isinstance(value, str) and value:
                return value
    return "stream_error"


def is_capacity_shed(result: dict) -> bool:
    return result.get("status") == 429 and result.get("error_code") == "no_provider_available"


def chat_once(
    base_url: str,
    token: str,
    model: str,
    *,
    stream: bool,
    max_tokens: int,
    request_id: str = "",
    response_tracker: BenchmarkResponseTracker | None = None,
) -> dict:
    body = {
        "model": model,
        "messages": [{"role": "user", "content": DEFAULT_PROMPT}],
        "max_tokens": max_tokens,
        "stream": stream,
    }
    if stream:
        body["stream_options"] = {"include_usage": True}
    started = time.perf_counter()
    resp = http_request(
        "POST",
        v1_url(base_url, "/chat/completions"),
        token=token,
        body=body,
        stream=stream,
        timeout=90,
        request_id=request_id,
    )
    response_registered = False
    try:
        if response_tracker is not None:
            response_registered = response_tracker.register(resp)
            if not response_registered:
                raise ProbeError("benchmark request cancelled")
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
            content_type_ok = content_type_matches(resp, "application/json")
            raw = resp.read()
            payload = json.loads(raw.decode("utf-8"))
            content = payload.get("choices", [{}])[0].get("message", {}).get("content")
            usage = payload.get("usage")
            error_code = payload_error_code(payload)
            content_ok = is_non_empty_text(content)
            return {
                "status": 200,
                "ok": content_type_ok and content_ok and usage_is_valid(usage) and not error_code,
                "content_type_ok": content_type_ok,
                "usage_ok": usage_is_valid(usage),
                "content_ok": content_ok,
                "response_error_ok": not bool(error_code),
                "error_code": error_code,
                "output_tokens": usage.get("completion_tokens", 0) if usage_is_valid(usage) else 0,
                "latency_ms": int((time.perf_counter() - started) * 1000),
            }
        content_type_ok = content_type_matches(resp, "text/event-stream")
        saw_content = False
        saw_usage = False
        saw_keepalive = False
        saw_done = False
        stream_error = None
        first_content_ms = None
        usage = None
        for raw_line in resp:
            if response_tracker is not None and response_tracker.cancelled():
                raise ProbeError("benchmark request cancelled")
            line = raw_line.decode("utf-8", "replace").strip()
            if not line:
                continue
            if line.startswith(":"):
                saw_keepalive = True
                continue
            if not line.startswith("data:"):
                continue
            data = line[5:].strip()
            if saw_done:
                stream_error = stream_error or "data_after_done"
                continue
            if data == "[DONE]":
                saw_done = True
                continue
            payload = json.loads(data)
            error_code = payload_error_code(payload)
            if error_code:
                stream_error = error_code
                continue
            if saw_usage:
                stream_error = stream_error or "data_after_usage"
                continue
            if usage_is_valid(payload.get("usage")):
                saw_usage = True
                usage = payload["usage"]
                continue
            choices = payload.get("choices") or []
            if choices and is_non_empty_text(choices[0].get("delta", {}).get("content")):
                saw_content = True
                if first_content_ms is None:
                    first_content_ms = int((time.perf_counter() - started) * 1000)
        latency_ms = int((time.perf_counter() - started) * 1000)
        generation_ms = None
        if first_content_ms is not None:
            generation_ms = max(1, latency_ms - first_content_ms)
        error_code = ""
        if stream_error:
            error_code = str(stream_error)
        return {
            "status": 200,
            "ok": content_type_ok and saw_content and saw_usage and saw_done and stream_error is None,
            "content_type_ok": content_type_ok,
            "usage_ok": saw_usage,
            "content_ok": saw_content,
            "done_ok": saw_done,
            "stream_error_ok": stream_error is None,
            "error_code": error_code,
            "keepalive_observed": saw_keepalive,
            "keepalive_evidence": "observed" if saw_keepalive else ("not_applicable_fast_stream" if latency_ms < GATEWAY_KEEPALIVE_TICK_SECONDS * 1000 else "missing"),
            "ttft_ms": first_content_ms,
            "latency_ms": latency_ms,
            "generation_ms": generation_ms,
            "output_tokens": usage.get("completion_tokens", 0) if usage_is_valid(usage) else 0,
        }
    finally:
        if response_tracker is not None and response_registered:
            response_tracker.unregister(resp)
        close_response(resp)


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


def is_unserved_catalog_chat(result: dict) -> bool:
    status = result.get("status")
    error_code = result.get("error_code") or ""
    if status in {404, 503}:
        return True
    if status == 429 and error_code == "no_provider_available":
        return True
    return error_code in {"no_provider_available", "model_not_found", "invalid_model"}


def check_catalog_chat(base_url: str, token: str, max_tokens: int) -> dict:
    rows = []
    for model_id in catalog_paid_model_ids():
        result = chat_once(base_url, token, model_id, stream=False, max_tokens=max_tokens)
        if result.get("ok"):
            classification = "passed"
        elif is_unserved_catalog_chat(result):
            classification = "not_served"
        else:
            classification = "failed"
        rows.append(
            {
                "id": model_id,
                "ok": classification == "passed",
                "classification": classification,
                "status": result.get("status"),
                "error_code": result.get("error_code") or "",
                "latency_ms": result.get("latency_ms"),
            }
        )
    passed = [row["id"] for row in rows if row["classification"] == "passed"]
    not_served = [row["id"] for row in rows if row["classification"] == "not_served"]
    failed = [row["id"] for row in rows if row["classification"] == "failed"]
    evidence = {
        "catalog_paid_rows": len(rows),
        "passed": passed,
        "not_served": not_served,
        "failed": failed,
        "rows": rows,
    }
    if failed:
        raise EvidenceProbeError(
            f"catalog chat failed for {len(failed)} model(s): {failed}",
            {**evidence, "classification": "catalog_chat_failed"},
        )
    if not passed:
        raise EvidenceProbeError(
            "catalog chat served no recommendable catalog model",
            {**evidence, "classification": "catalog_chat_none_served"},
        )
    evidence["classification"] = "catalog_chat_passed"
    evidence["ok"] = True
    return evidence


def percentile(values: list[int], pct: float) -> int:
    if not values:
        raise ProbeError("cannot compute percentile without samples")
    ordered = sorted(values)
    index = min(len(ordered) - 1, max(0, round((pct / 100) * (len(ordered) - 1))))
    return ordered[index]


def benchmark_evidence(
    requested: int,
    results: list[dict],
    statuses: dict[str, int],
    ok_count: int,
    shed_count: int,
    failed: list[dict],
) -> dict:
    error_codes = sorted(
        {
            failure.get("error_code")
            for failure in failed
            if isinstance(failure, dict) and isinstance(failure.get("error_code"), str) and failure.get("error_code")
        }
    )
    return {
        "requests": requested,
        "requests_sent": len(results),
        "statuses": statuses,
        "ok": ok_count,
        "shed_429": shed_count,
        "non_capacity_failures": len(failed),
        "sample_failures": failed[:3],
        "failure_error_codes": error_codes,
    }


def classify_benchmark_evidence(evidence: dict, *, require_429: bool = False, min_success_ratio: float = 0.0) -> str:
    statuses = evidence.get("statuses") if isinstance(evidence, dict) else {}
    error_codes = set(evidence.get("failure_error_codes") or [])
    if evidence.get("non_capacity_failures", 0) > 0:
        if "upstream_provider_error" in error_codes or int(statuses.get("502", 0) or 0) > 0:
            return "upstream_provider_error"
        if "benchmark_timeout" in error_codes:
            return "benchmark_timeout"
        if int(statuses.get("exception", 0) or 0) > 0:
            return "client_or_network_exception"
        return "non_capacity_failure"
    if require_429 and int(evidence.get("shed_429", 0) or 0) < 1:
        return "saturation_did_not_shed"
    if min_success_ratio > 0 and float(evidence.get("success_ratio", 0.0) or 0.0) < min_success_ratio:
        if int(evidence.get("shed_429", 0) or 0) > 0:
            return "capacity_shed_below_success_ratio"
        return "success_ratio_below_threshold"
    if int(evidence.get("shed_429", 0) or 0) > 0:
        return "clean_capacity_shed"
    return "passed"


def benchmark_failure(
    message: str,
    requested: int,
    results: list[dict],
    statuses: dict[str, int],
    ok_count: int,
    shed_count: int,
    failed: list[dict],
    *,
    require_429: bool = False,
    min_success_ratio: float = 0.0,
) -> BenchmarkProbeError:
    evidence = benchmark_evidence(requested, results, statuses, ok_count, shed_count, failed)
    evidence["success_ratio"] = round(ok_count / max(len(results), 1), 3)
    evidence["classification"] = classify_benchmark_evidence(
        evidence,
        require_429=require_429,
        min_success_ratio=min_success_ratio,
    )
    return BenchmarkProbeError(f"{message}: {evidence}", evidence)


def benchmark_metric_failure(
    message: str,
    requested: int,
    results: list[dict],
    statuses: dict[str, int],
    ok_count: int,
    shed_count: int,
    failed: list[dict],
    classification: str,
    *,
    require_429: bool = False,
    min_success_ratio: float = 0.0,
    metrics: dict | None = None,
) -> BenchmarkProbeError:
    exc = benchmark_failure(
        message,
        requested,
        results,
        statuses,
        ok_count,
        shed_count,
        failed,
        require_429=require_429,
        min_success_ratio=min_success_ratio,
    )
    exc.evidence["classification"] = classification
    if metrics:
        exc.evidence.update(metrics)
    return exc


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
    allow_all_shed: bool = False,
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
        executor = ThreadPoolExecutor(max_workers=batch_size)
        futures = []
        pending = set()
        response_tracker = BenchmarkResponseTracker()
        try:
            futures = [
                executor.submit(
                    chat_once,
                    base_url,
                    token,
                    model,
                    stream=True,
                    max_tokens=max_tokens,
                    request_id=str(uuid.uuid4()),
                    response_tracker=response_tracker,
                )
                for _ in range(batch_size)
            ]
            pending = set(futures)
            try:
                for future in as_completed(futures, timeout=BENCHMARK_BATCH_TIMEOUT_SECONDS):
                    pending.discard(future)
                    try:
                        result = future.result()
                    except Exception as exc:
                        result = {
                            "status": "exception",
                            "ok": False,
                            "error_code": type(exc).__name__,
                            "error": str(exc),
                        }
                    batch.append(result)
                    results.append(result)
            except FuturesTimeout:
                response_tracker.cancel()
                for future in list(pending):
                    future.cancel()
                    result = {
                        "status": "exception",
                        "ok": False,
                        "error_code": "benchmark_timeout",
                        "error": f"benchmark request did not finish within {BENCHMARK_BATCH_TIMEOUT_SECONDS}s batch timeout",
                    }
                    batch.append(result)
                    results.append(result)
        finally:
            executor.shutdown(wait=False, cancel_futures=True)
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
        raise benchmark_failure(
            "benchmark had non-capacity-shed failures",
            requests,
            results,
            statuses,
            ok_count,
            shed_count,
            failed,
            require_429=require_429,
            min_success_ratio=min_success_ratio,
        )
    success_ratio = ok_count / len(results)
    if success_ratio < min_success_ratio:
        raise benchmark_failure(
            f"benchmark success ratio {success_ratio:.3f} below required {min_success_ratio:.3f}",
            requests,
            results,
            statuses,
            ok_count,
            shed_count,
            failed,
            require_429=require_429,
            min_success_ratio=min_success_ratio,
        )
    if require_429 and shed_count < 1:
        raise benchmark_failure(
            "saturation benchmark did not observe an early HTTP 429",
            requests,
            results,
            statuses,
            ok_count,
            shed_count,
            failed,
            require_429=require_429,
            min_success_ratio=min_success_ratio,
        )
    if shed_count > 0 and ok_count == 0 and (require_429 or allow_all_shed):
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
        raise benchmark_metric_failure(
            "benchmark produced no successful TTFT samples",
            requests,
            results,
            statuses,
            ok_count,
            shed_count,
            failed,
            "no_successful_ttft_samples",
            require_429=require_429,
            min_success_ratio=min_success_ratio,
            metrics={"ttft_sample_count": 0, "ttft_p95_ms": None, "max_ttft_p95_ms": max_ttft_p95_ms},
        )
    ttft_p95 = percentile(ttfts, 95)
    if max_ttft_p95_ms > 0 and ttft_p95 > max_ttft_p95_ms:
        raise benchmark_metric_failure(
            f"benchmark TTFT p95 {ttft_p95}ms exceeds required {max_ttft_p95_ms}ms",
            requests,
            results,
            statuses,
            ok_count,
            shed_count,
            failed,
            "ttft_p95_above_threshold",
            require_429=require_429,
            min_success_ratio=min_success_ratio,
            metrics={"ttft_p95_ms": ttft_p95, "max_ttft_p95_ms": max_ttft_p95_ms},
        )
    generated_tokens_per_second = output_tokens / max(generation_seconds, 0.001)
    if min_output_tokens_per_second > 0 and generated_tokens_per_second < min_output_tokens_per_second:
        raise benchmark_metric_failure(
            "benchmark generated-token throughput "
            f"{generated_tokens_per_second:.3f} tokens/s below required {min_output_tokens_per_second:.3f} tokens/s",
            requests,
            results,
            statuses,
            ok_count,
            shed_count,
            failed,
            "throughput_below_threshold",
            require_429=require_429,
            min_success_ratio=min_success_ratio,
            metrics={
                "output_tokens_per_second": round(generated_tokens_per_second, 3),
                "min_output_tokens_per_second": min_output_tokens_per_second,
            },
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


def run_load_ladder(
    base_url: str,
    token: str,
    model: str,
    concurrencies: list[int],
    max_tokens: int,
    requests_per_step: int,
    max_ttft_p95_ms: int,
) -> dict:
    steps = []
    for concurrency in concurrencies:
        step_requests = max(concurrency, requests_per_step)
        try:
            result = run_benchmark(
                base_url,
                token,
                model,
                step_requests,
                concurrency,
                max_tokens,
                0.0,
                max_ttft_p95_ms,
                0.0,
                allow_all_shed=True,
            )
            result["concurrency"] = concurrency
            result["classification"] = "passed" if result.get("shed_429", 0) == 0 else "clean_capacity_shed"
            steps.append(result)
        except BenchmarkProbeError as exc:
            evidence = dict(exc.evidence)
            evidence["concurrency"] = concurrency
            evidence["ok"] = False
            evidence["error"] = str(exc)
            steps.append(evidence)
        except ProbeError as exc:
            steps.append({"concurrency": concurrency, "ok": False, "classification": "probe_error", "error": str(exc)})
    blocker = next((step for step in steps if not step.get("ok") and step.get("classification") != "clean_capacity_shed"), None)
    result = {
        "steps": steps,
        "first_blocker": blocker.get("classification") if blocker else "",
        "max_clean_concurrency": max((step.get("concurrency", 0) for step in steps if step.get("classification") == "passed"), default=0),
    }
    if not blocker and result["max_clean_concurrency"] < 1:
        result["first_blocker"] = "no_clean_capacity"
        raise EvidenceProbeError("load ladder did not observe any successful clean-capacity step", result)
    if blocker:
        raise EvidenceProbeError(f"load ladder observed blocker {blocker.get('classification')}", result)
    return result


def normalize_pool_entries(payload: object) -> list[dict]:
    if isinstance(payload, dict):
        pool = payload.get("pool")
    else:
        pool = payload
    if not isinstance(pool, list):
        raise ProbeError("/poolz must return a pool array or object with pool array")
    if any(not isinstance(entry, dict) for entry in pool):
        raise ProbeError("/poolz entries must be objects")
    return pool


def poolz_entry_counts_toward_buyer_capacity(entry: dict) -> bool:
    routing_eligible = entry.get("routing_eligible")
    if isinstance(routing_eligible, bool):
        return routing_eligible
    if "routing_eligible" not in entry:
        raise ProbeError("/poolz provider rows must expose routing_eligible")
    raise ProbeError("/poolz routing_eligible must be boolean")


def validate_pool_slots(entry: dict) -> None:
    total = entry.get("slots_total")
    free = entry.get("slots_free")
    if not isinstance(total, int) or isinstance(total, bool) or total < 0:
        raise ProbeError("/poolz slots_total must be a non-negative integer")
    if not isinstance(free, int) or isinstance(free, bool) or free < 0:
        raise ProbeError("/poolz slots_free must be a non-negative integer")
    if free > total:
        raise ProbeError("/poolz slots_free cannot exceed slots_total")


def check_pool_topology(admin_url: str, token: str, expected_model: str, benchmark_concurrency: int = 0) -> dict:
    expected_model = resolve_probe_model(expected_model)
    payload, status = read_json("GET", normalize_base_url(admin_url) + "/poolz", token=token)
    entries = normalize_pool_entries(payload)
    routable = [entry for entry in entries if poolz_entry_counts_toward_buyer_capacity(entry)]
    ready = [entry for entry in routable if entry.get("state") == "ready"]
    matching = [
        entry
        for entry in ready
        if isinstance(entry.get("model_id"), str) and models_equivalent(entry.get("model_id"), expected_model)
    ]
    for entry in entries:
        validate_pool_slots(entry)
    slots_total = sum(entry["slots_total"] for entry in matching)
    slots_free = sum(entry["slots_free"] for entry in matching)
    throughput_samples = [
        float(entry.get("throughput_tps_estimate"))
        for entry in matching
        if (
            isinstance(entry.get("throughput_tps_estimate"), (int, float))
            and not isinstance(entry.get("throughput_tps_estimate"), bool)
            and math.isfinite(float(entry.get("throughput_tps_estimate")))
            and float(entry.get("throughput_tps_estimate")) >= 0
        )
    ]
    by_model: dict[str, dict[str, int]] = {}
    for entry in ready:
        model = entry.get("model_id")
        if not isinstance(model, str) or not model:
            model = "<unknown>"
        row = by_model.setdefault(model, {"ready": 0, "slots_total": 0, "slots_free": 0})
        row["ready"] += 1
        row["slots_total"] += entry["slots_total"]
        row["slots_free"] += entry["slots_free"]
    result = {
        "http_status": status,
        "providers": len(entries),
        "routable_providers": len(routable),
        "ready_providers": len(ready),
        "expected_model": expected_model,
        "matching_ready_providers": len(matching),
        "matching_slots_total": slots_total,
        "matching_slots_free": slots_free,
        "benchmark_concurrency": benchmark_concurrency,
        "benchmark_has_slot_slack": slots_free >= benchmark_concurrency if benchmark_concurrency > 0 else None,
        "models": by_model,
    }
    if throughput_samples:
        result["matching_tps_min"] = round(min(throughput_samples), 3)
        result["matching_tps_median"] = round(statistics.median(throughput_samples), 3)
        result["matching_tps_max"] = round(max(throughput_samples), 3)
    if not matching:
        result["classification"] = "expected_model_not_ready"
    elif benchmark_concurrency > 0 and slots_free < benchmark_concurrency:
        result["classification"] = "insufficient_model_available_capacity"
    else:
        result["classification"] = "model_pool_ready"
    if result["classification"] != "model_pool_ready":
        raise EvidenceProbeError(f"pool topology blocker {result['classification']}", result)
    return result


def check_wholesale_statement(
    admin_url: str,
    token: str,
    account_id: str,
    period: str,
    require_free_line: bool = False,
    expected_model: str = "",
    *,
    attempts: int = 1,
    wait_seconds: float = 0.0,
) -> dict:
    attempts = max(1, attempts)
    last_error = None
    for attempt in range(1, attempts + 1):
        try:
            result = check_wholesale_statement_once(admin_url, token, account_id, period, require_free_line, expected_model)
            result["attempts"] = attempt
            return result
        except SettlementLagError as exc:
            last_error = exc
            if attempt < attempts:
                time.sleep(max(0.0, wait_seconds))
        except ProbeError as exc:
            raise exc
    raise last_error if last_error is not None else ProbeError("wholesale statement check failed")


def check_wholesale_statement_once(
    admin_url: str,
    token: str,
    account_id: str,
    period: str,
    require_free_line: bool = False,
    expected_model: str = "",
) -> dict:
    endpoint = normalize_base_url(admin_url) + "/admin/ledger/wholesale-statements"
    statement, _ = read_json("POST", endpoint, token=token, body={"account_id": account_id, "period": period})
    statement_id = statement.get("wholesale_statement_id")
    if not isinstance(statement_id, str) or not statement_id:
        raise ProbeError("wholesale statement response missing wholesale_statement_id")
    if statement.get("account_id") != account_id:
        raise ProbeError(f"wholesale statement account_id mismatch: {statement.get('account_id')!r}")
    if statement.get("period") != period:
        raise ProbeError(f"wholesale statement period mismatch: {statement.get('period')!r}")
    if not is_non_negative_int(statement.get("usd_micro")):
        raise ProbeError("wholesale statement usd_micro must be a non-negative integer")
    for key in ("request_count", "prompt_tokens", "completion_tokens", "gross_credits"):
        if not is_non_negative_int(statement.get(key)):
            raise ProbeError(f"wholesale statement {key} must be a non-negative integer")
    line_items = statement.get("line_items")
    if not isinstance(line_items, list):
        raise ProbeError("wholesale statement line_items must be an array")
    if not line_items:
        raise SettlementLagError("wholesale statement line_items must be a non-empty array")
    total_request_count = 0
    total_prompt_tokens = 0
    total_completion_tokens = 0
    total_gross_credits = 0
    total_usd_micro = 0
    has_free_line = False
    positive_free_credit = False
    expected_paid_line = None
    expected_free_line = None
    expected_free_id = expected_free_model_id(expected_model) if expected_model else ""
    expected_by_model = {}
    for item in line_items:
        if not isinstance(item, dict):
            raise ProbeError("wholesale statement line item must be an object")
        model = item.get("model")
        if not isinstance(model, str) or not model:
            raise ProbeError(f"line item model must be non-empty: {item}")
        if model in expected_by_model:
            raise ProbeError(f"duplicate line item model: {model}")
        if not isinstance(item.get("is_free"), bool):
            raise ProbeError(f"line item is_free must be boolean: {item}")
        is_free = item["is_free"]
        if is_free:
            has_free_line = True
        if is_free and item.get("usd_micro") != 0:
            raise ProbeError(f"free SKU line item charged non-zero usd_micro: {item}")
        if not is_non_negative_int(item.get("request_count")):
            raise ProbeError(f"line item request_count must be non-negative: {item}")
        if not is_non_negative_int(item.get("prompt_tokens")):
            raise ProbeError(f"line item prompt_tokens must be non-negative: {item}")
        if not is_non_negative_int(item.get("completion_tokens")):
            raise ProbeError(f"line item completion_tokens must be non-negative: {item}")
        if not is_non_negative_int(item.get("gross_credits")):
            raise ProbeError(f"line item gross_credits must be non-negative: {item}")
        if not is_non_negative_int(item.get("usd_micro")):
            raise ProbeError(f"line item usd_micro must be non-negative: {item}")
        usd_text = item.get("usd")
        if not isinstance(usd_text, str) or usd_text != usd_micro_string(item["usd_micro"]):
            raise ProbeError(f"line item usd text mismatch: {item}")
        if item["request_count"] > 0 and item["gross_credits"] <= 0:
            raise ProbeError(f"settled line item must carry positive gross_credits: {item}")
        if is_free and item["request_count"] > 0 and item["gross_credits"] > 0:
            positive_free_credit = True
        total_request_count += item["request_count"]
        total_prompt_tokens += item["prompt_tokens"]
        total_completion_tokens += item["completion_tokens"]
        total_gross_credits += item["gross_credits"]
        total_usd_micro += item["usd_micro"]
        expected_by_model[model] = item
        if expected_model and model == expected_model:
            expected_paid_line = item
        if expected_free_id and model == expected_free_id:
            expected_free_line = item
    expected_totals = {
        "request_count": total_request_count,
        "prompt_tokens": total_prompt_tokens,
        "completion_tokens": total_completion_tokens,
        "gross_credits": total_gross_credits,
        "usd_micro": total_usd_micro,
    }
    for key, expected in expected_totals.items():
        if statement[key] != expected:
            raise ProbeError(f"wholesale statement {key} total mismatch: {statement[key]} != {expected}")
    if statement.get("usd") != usd_micro_string(statement["usd_micro"]):
        raise ProbeError("wholesale statement usd text mismatch")
    if total_request_count < 1:
        raise SettlementLagError("wholesale statement must include at least one settled request")
    if total_gross_credits < 1:
        raise SettlementLagError("wholesale statement must include positive provider credit evidence")
    if require_free_line and not has_free_line:
        raise SettlementLagError("filing-mode wholesale statement must include a free SKU line item")
    if require_free_line and not positive_free_credit:
        raise SettlementLagError("filing-mode wholesale statement must include a free SKU line item with positive provider credits")
    if expected_model:
        if expected_paid_line is None:
            raise SettlementLagError(f"filing-mode wholesale statement must include paid SKU line item {expected_model}")
        if expected_paid_line["is_free"] is not False:
            raise ProbeError(f"paid SKU line item {expected_model} must declare is_free=false")
        if expected_paid_line["request_count"] < 1 or expected_paid_line["gross_credits"] < 1 or expected_paid_line["usd_micro"] < 1:
            raise SettlementLagError(f"paid SKU line item {expected_model} must include settled billable usage")
        if expected_free_line is None:
            raise SettlementLagError(f"filing-mode wholesale statement must include expected free SKU line item {expected_free_id}")
        if expected_free_line["is_free"] is not True:
            raise ProbeError(f"free SKU line item {expected_free_id} must declare is_free=true")
        if expected_free_line["request_count"] < 1 or expected_free_line["gross_credits"] < 1:
            raise SettlementLagError(f"free SKU line item {expected_free_id} must include settled provider credit evidence")
        if expected_free_line["usd_micro"] != 0:
            raise ProbeError(f"free SKU line item {expected_free_id} must have zero usd_micro")
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
    seen_csv_models = set()
    for row in csv_rows:
        if row.get("wholesale_statement_id") != statement_id:
            raise ProbeError(f"statement CSV id mismatch: {row}")
        if row.get("account_id") != account_id:
            raise ProbeError(f"statement CSV account mismatch: {row}")
        if row.get("period") != period:
            raise ProbeError(f"statement CSV period mismatch: {row}")
        model = row.get("model", "")
        if model in seen_csv_models:
            raise ProbeError(f"statement CSV duplicate model row: {model}")
        seen_csv_models.add(model)
        expected = expected_by_model.get(model)
        if expected is None:
            raise ProbeError(f"statement CSV has unexpected model row: {row}")
        for key in ("request_count", "prompt_tokens", "completion_tokens", "gross_credits", "usd_micro"):
            try:
                parsed = int(row.get(key, ""))
            except ValueError as exc:
                raise ProbeError(f"statement CSV {key} must be integer: {row}") from exc
            if parsed != expected[key]:
                raise ProbeError(f"statement CSV {key} mismatch for {model}: {parsed} != {expected[key]}")
        csv_is_free = row.get("is_free", "").lower()
        if csv_is_free not in {"true", "false"}:
            raise ProbeError(f"statement CSV is_free must be boolean text for {model}: {row}")
        if str(expected["is_free"]).lower() != csv_is_free:
            raise ProbeError(f"statement CSV is_free mismatch for {model}: {row}")
        if row.get("usd") != expected["usd"]:
            raise ProbeError(f"statement CSV usd mismatch for {model}: {row}")
    missing_csv_models = set(expected_by_model) - seen_csv_models
    if missing_csv_models:
        raise ProbeError(f"statement CSV missing model rows: {sorted(missing_csv_models)}")
    return {
        "wholesale_statement_id": statement_id,
        "account_id": account_id,
        "period": period,
        "line_items": len(line_items),
        "request_count": total_request_count,
        "prompt_tokens": total_prompt_tokens,
        "completion_tokens": total_completion_tokens,
        "gross_credits": total_gross_credits,
        "has_free_line": has_free_line,
        "positive_free_credit": positive_free_credit,
        "usd_micro": statement["usd_micro"],
        "csv_ok": True,
    }


def load_token(env_name: str, path: str, label: str) -> str:
    if path:
        try:
            return Path(path).read_text(encoding="utf-8").strip()
        except OSError as exc:
            raise ProbeError(f"{label} file is not readable: {path}") from exc
    token = os.environ.get(env_name, "")
    if token:
        return token.strip()
    return ""


def missing_token_error(env_name: str, path: str, label: str) -> str:
    if path:
        return f"{label} is empty: {path}"
    return f"{label} is missing: set {env_name} or pass --{label.lower().replace(' ', '-')}-file"


def main(argv: list[str]) -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--base-url", default="https://api.malibu.tech")
    parser.add_argument("--api-key-env", default="MACPROVIDER_SPEC015_API_KEY")
    parser.add_argument("--api-key-file", default="")
    parser.add_argument("--model", default=DEFAULT_MODEL)
    parser.add_argument(
        "--catalog-chat",
        action="store_true",
        help="smoke chat every recommendable catalog model; unserved rows are recorded as not_served, not failures",
    )
    parser.add_argument("--expected-healthz-version", default="", help="fail if /healthz.version does not match this exact value")
    parser.add_argument("--max-tokens", type=int, default=16)
    parser.add_argument("--benchmark-requests", type=int, default=0)
    parser.add_argument("--benchmark-concurrency", type=int, default=DEFAULT_BENCHMARK_CONCURRENCY)
    parser.add_argument("--min-success-ratio", type=float, default=DEFAULT_MIN_SUCCESS_RATIO)
    parser.add_argument("--max-ttft-p95-ms", type=int, default=DEFAULT_MAX_TTFT_P95_MS)
    parser.add_argument("--min-output-tokens-per-second", type=float, default=DEFAULT_MIN_OUTPUT_TOKENS_PER_SECOND)
    parser.add_argument("--saturation-requests", type=int, default=0)
    parser.add_argument("--saturation-concurrency", type=int, default=DEFAULT_SATURATION_CONCURRENCY)
    parser.add_argument("--admin-url", default="")
    parser.add_argument("--operator-key-env", default="OPERATOR_KEY")
    parser.add_argument("--operator-key-file", default="")
    parser.add_argument("--statement-account-id", default="")
    parser.add_argument("--statement-period", default="")
    parser.add_argument(
        "--diagnostic-mode",
        action="store_true",
        help="collect topology and load-ladder evidence and continue collecting after failed checks",
    )
    parser.add_argument(
        "--load-ladder",
        default="",
        help="comma-separated concurrency ladder to run as diagnostic evidence, for example 1,2,4,8",
    )
    parser.add_argument("--load-ladder-requests-per-step", type=int, default=8)
    parser.add_argument("--wholesale-statement-attempts", type=int, default=1)
    parser.add_argument("--wholesale-statement-wait-seconds", type=float, default=5.0)
    parser.add_argument("--continue-on-error", action="store_true", help="collect later checks even when an earlier check fails")
    parser.add_argument("--filing-mode", action="store_true", help="fail unless chat, benchmark, and statement evidence are all collected")
    parser.add_argument("--output", default="", help="write the JSON report to this path")
    args = parser.parse_args(argv)
    args.model = resolve_probe_model(args.model)
    if not math.isfinite(args.min_success_ratio) or args.min_success_ratio < 0 or args.min_success_ratio > 1:
        raise SystemExit("--min-success-ratio must be in [0,1]")
    if not math.isfinite(args.min_output_tokens_per_second) or args.min_output_tokens_per_second < 0:
        raise SystemExit("--min-output-tokens-per-second must be a finite non-negative number")
    if not math.isfinite(args.wholesale_statement_wait_seconds) or args.wholesale_statement_wait_seconds < 0:
        raise SystemExit("--wholesale-statement-wait-seconds must be finite and non-negative")
    if args.filing_mode:
        if not args.expected_healthz_version:
            raise SystemExit("--filing-mode requires --expected-healthz-version")
        if not re.fullmatch(r"v\d+\.\d+\.\d+(?:[-+][A-Za-z0-9._-]+)?", args.expected_healthz_version):
            raise SystemExit("--filing-mode requires --expected-healthz-version to be a release version like v1.8.153")
        if normalize_base_url(args.base_url) != PRODUCTION_BASE_URL:
            raise SystemExit(f"--filing-mode requires --base-url {PRODUCTION_BASE_URL}")
        if normalize_base_url(args.admin_url) != PRODUCTION_ADMIN_URL:
            raise SystemExit(f"--filing-mode requires --admin-url {PRODUCTION_ADMIN_URL}")
        if args.benchmark_requests < 100:
            raise SystemExit("--filing-mode requires --benchmark-requests >= 100")
        if args.benchmark_concurrency < DEFAULT_BENCHMARK_CONCURRENCY:
            raise SystemExit(f"--filing-mode requires --benchmark-concurrency >= {DEFAULT_BENCHMARK_CONCURRENCY}")
        if args.max_tokens < 16:
            raise SystemExit("--filing-mode requires --max-tokens >= 16")
        if args.saturation_requests < 1:
            raise SystemExit("--filing-mode requires --saturation-requests > 0")
        if args.saturation_concurrency < DEFAULT_SATURATION_CONCURRENCY:
            raise SystemExit(f"--filing-mode requires --saturation-concurrency >= {DEFAULT_SATURATION_CONCURRENCY}")
        if args.saturation_requests < args.saturation_concurrency:
            raise SystemExit("--filing-mode requires --saturation-requests >= --saturation-concurrency")
        if not (args.admin_url and args.statement_account_id and args.statement_period):
            raise SystemExit("--filing-mode requires --admin-url, --statement-account-id, and --statement-period")
        if args.min_success_ratio < DEFAULT_MIN_SUCCESS_RATIO:
            raise SystemExit(f"--filing-mode requires --min-success-ratio >= {DEFAULT_MIN_SUCCESS_RATIO}")
        if args.max_ttft_p95_ms <= 0 or args.max_ttft_p95_ms > DEFAULT_MAX_TTFT_P95_MS:
            raise SystemExit(f"--filing-mode requires --max-ttft-p95-ms in [1,{DEFAULT_MAX_TTFT_P95_MS}]")
        if args.min_output_tokens_per_second < DEFAULT_MIN_OUTPUT_TOKENS_PER_SECOND:
            raise SystemExit(
                f"--filing-mode requires --min-output-tokens-per-second >= {DEFAULT_MIN_OUTPUT_TOKENS_PER_SECOND}"
            )
    if args.load_ladder_requests_per_step < 1:
        raise SystemExit("--load-ladder-requests-per-step must be positive")
    if args.filing_mode and args.load_ladder_requests_per_step < 8:
        raise SystemExit("--filing-mode requires --load-ladder-requests-per-step >= 8")
    if args.wholesale_statement_attempts < 1:
        raise SystemExit("--wholesale-statement-attempts must be positive")
    if args.wholesale_statement_wait_seconds < 0:
        raise SystemExit("--wholesale-statement-wait-seconds must be non-negative")
    load_ladder_concurrencies = []
    load_ladder_value = args.load_ladder
    if (args.filing_mode or args.diagnostic_mode) and not load_ladder_value:
        load_ladder_value = DEFAULT_LOAD_LADDER
    if load_ladder_value:
        try:
            load_ladder_concurrencies = [int(part.strip()) for part in load_ladder_value.split(",") if part.strip()]
        except ValueError as exc:
            raise SystemExit("--load-ladder must contain only comma-separated integers") from exc
        if not load_ladder_concurrencies or any(value < 1 or value > MAX_BENCHMARK_CONCURRENCY for value in load_ladder_concurrencies):
            raise SystemExit(f"--load-ladder values must be in [1,{MAX_BENCHMARK_CONCURRENCY}]")
        if args.filing_mode and not set(DEFAULT_LOAD_LADDER_VALUES).issubset(set(load_ladder_concurrencies)):
            raise SystemExit(f"--filing-mode requires --load-ladder to include {DEFAULT_LOAD_LADDER}")

    report = {"base_url": args.base_url, "admin_url": args.admin_url, "model": args.model, "checks": {}}
    errors = []
    continue_after_error = args.continue_on_error or args.filing_mode or args.diagnostic_mode

    def record_check(name: str, fn):
        try:
            report["checks"][name] = fn()
        except ProbeError as exc:
            report["checks"][name] = {"ok": False, "error": str(exc)}
            if isinstance(exc, (BenchmarkProbeError, EvidenceProbeError)) and exc.evidence:
                report["checks"][name]["evidence"] = exc.evidence
                report["checks"][name]["classification"] = exc.evidence.get("classification", "")
            errors.append(f"{name}: {exc}")
            if not continue_after_error:
                raise
        except Exception as exc:
            report["checks"][name] = {
                "ok": False,
                "error_code": type(exc).__name__,
                "error": str(exc),
            }
            errors.append(f"{name}: {type(exc).__name__}: {exc}")
            if not continue_after_error:
                raise

    try:
        record_check("healthz", lambda: check_healthz(args.base_url, args.expected_healthz_version))
        record_check(
            "models",
            lambda: check_models_document(
                read_json("GET", v1_url(args.base_url, "/openrouter/models"))[0],
                args.model,
                args.filing_mode,
            ),
        )
        record_check("privacy", lambda: check_privacy(args.base_url))
        try:
            token = load_token(args.api_key_env, args.api_key_file, "API key")
        except ProbeError as exc:
            token = ""
            token_error = str(exc)
        else:
            token_error = "" if token else missing_token_error(args.api_key_env, args.api_key_file, "API key")
        if token_error and (
            args.api_key_file or args.filing_mode or args.diagnostic_mode or args.catalog_chat or args.benchmark_requests > 0 or args.saturation_requests > 0
        ):
            report["checks"]["api_key"] = {"ok": False, "error": token_error}
            report["checks"]["chat"] = {"ok": False, "error": token_error}
            if args.filing_mode:
                report["checks"]["chat_free"] = {"ok": False, "error": token_error}
            report["checks"]["benchmark"] = {"ok": False, "error": token_error}
            if load_ladder_concurrencies:
                report["checks"]["load_ladder"] = {"ok": False, "error": token_error}
            report["checks"]["saturation"] = {"ok": False, "error": token_error}
            errors.append(f"api_key: {token_error}")
            if not continue_after_error:
                raise ProbeError(token_error)
        if token:
            record_check("chat", lambda: check_chat(args.base_url, token, args.model, args.max_tokens))
            if args.filing_mode:
                record_check("chat_free", lambda: check_chat(args.base_url, token, expected_free_model_id(args.model), args.max_tokens))
            if args.catalog_chat:
                record_check(
                    "catalog_chat",
                    lambda: check_catalog_chat(args.base_url, token, args.max_tokens),
                )
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
            if load_ladder_concurrencies:
                record_check(
                    "load_ladder",
                    lambda: run_load_ladder(
                        args.base_url,
                        token,
                        args.model,
                        load_ladder_concurrencies,
                        args.max_tokens,
                        args.load_ladder_requests_per_step,
                        args.max_ttft_p95_ms,
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
            for name in ("chat", "benchmark", "saturation"):
                if name not in report["checks"]:
                    report["checks"][name] = {"skipped": "missing API key"}
            if args.filing_mode and "chat_free" not in report["checks"]:
                report["checks"]["chat_free"] = {"skipped": "missing API key"}
            if load_ladder_concurrencies and "load_ladder" not in report["checks"]:
                report["checks"]["load_ladder"] = {"skipped": "missing API key"}
            if args.filing_mode:
                errors.append("filing mode requires API key")
        if args.admin_url and (args.filing_mode or args.diagnostic_mode):
            record_check("admin_healthz", lambda: check_healthz(args.admin_url, args.expected_healthz_version))
        try:
            operator_token = load_token(args.operator_key_env, args.operator_key_file, "operator key")
        except ProbeError as exc:
            operator_token = ""
            operator_token_error = str(exc)
        else:
            operator_token_error = "" if operator_token else missing_token_error(
                args.operator_key_env,
                args.operator_key_file,
                "operator key",
            )
        if operator_token_error and (args.filing_mode or args.diagnostic_mode or args.admin_url):
            report["checks"]["operator_key"] = {"ok": False, "error": operator_token_error}
            report["checks"]["wholesale_statement"] = {"ok": False, "error": operator_token_error}
            if args.admin_url and (args.filing_mode or args.diagnostic_mode):
                report["checks"]["pool_topology"] = {"ok": False, "error": operator_token_error}
            errors.append(f"wholesale_statement: {operator_token_error}")
            if not continue_after_error:
                raise ProbeError(operator_token_error)
        if args.admin_url and operator_token and (args.filing_mode or args.diagnostic_mode):
            record_check(
                "pool_topology",
                lambda: check_pool_topology(args.admin_url, operator_token, args.model, args.benchmark_concurrency),
            )
            if args.filing_mode and report["checks"].get("models", {}).get("ids") and report["checks"].get("pool_topology", {}).get("classification"):
                record_check(
                    "model_capacity",
                    lambda: check_model_capacity_against_pool(
                        report["checks"]["models"],
                        report["checks"]["pool_topology"],
                        args.model,
                    ),
                )
        if args.admin_url and operator_token and args.statement_account_id and args.statement_period:
            record_check(
                "wholesale_statement",
                lambda: check_wholesale_statement(
                    args.admin_url,
                    operator_token,
                    args.statement_account_id,
                    args.statement_period,
                    args.filing_mode,
                    args.model if args.filing_mode else "",
                    attempts=max(args.wholesale_statement_attempts, 3 if args.diagnostic_mode else 1),
                    wait_seconds=args.wholesale_statement_wait_seconds,
                ),
            )
        else:
            if "wholesale_statement" not in report["checks"]:
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
