#!/usr/bin/env python3
"""Produce OpenRouter pricing snapshots and non-money-path rate proposals.

The script deliberately has no apply mode.  It can only write a validated
snapshot or a proposal artifact to a caller-selected output directory.
"""

from __future__ import annotations

import argparse
import copy
import hashlib
import http.client
import json
import math
import multiprocessing
import os
import random
import re
import socket
import sys
import tempfile
import threading
import time
from dataclasses import dataclass
from datetime import datetime, timezone
from decimal import Decimal, InvalidOperation, ROUND_HALF_UP
from email.utils import parsedate_to_datetime
from pathlib import Path
from typing import Any, Callable, Mapping, Protocol
from urllib.parse import quote, urlsplit


RANKINGS_URL = "https://openrouter.ai/api/frontend/v1/rankings/models"
MODELS_URL = "https://openrouter.ai/api/v1/models"
ENDPOINTS_URL = "https://openrouter.ai/api/v1/models/{model_id}/endpoints"
SNAPSHOT_SCHEMA_VERSION = 3
PROPOSAL_SCHEMA_VERSION = 1
TOOL_VERSION = "openrouter-pricing-engine-v1"
DEFAULT_POLICY_PATH = Path(__file__).with_name("openrouter_pricing_policy.json")
MODEL_ID_RE = re.compile(r"^[A-Za-z0-9._~:-]+/[A-Za-z0-9._~:-]+$")
# OpenRouter's explicit provider variants (for example `model:free`) are
# valid snapshot identities even when policy leaves them unmapped/blocked.
CANONICAL_ID_RE = re.compile(r"^[a-z0-9][a-z0-9._/:-]*$")
MAX_RESPONSE_BYTES = 5 * 1024 * 1024
RANKING_ROW_KEYS = frozenset({"change", "count", "date", "image_output_requests", "model_permaslug", "num_audio_prompt", "num_media_completion", "num_media_prompt", "num_video_prompt", "requests_with_tool_call_errors", "rerank_documents", "stt_transcript_characters", "total_completion_tokens", "total_native_tokens_cached", "total_native_tokens_reasoning", "total_prompt_tokens", "total_tool_calls", "variant", "variant_permaslug", "video_output_seconds"})
CATALOG_ROW_KEYS = frozenset({"alias_target", "architecture", "benchmarks", "canonical_slug", "context_length", "created", "default_parameters", "description", "expiration_date", "hugging_face_id", "id", "knowledge_cutoff", "links", "name", "per_request_limits", "pricing", "reasoning", "supported_parameters", "supported_voices", "top_provider"})
CATALOG_TOP_LEVEL_KEYS = frozenset({"data", "links", "total_count"})
ENDPOINT_DATA_KEYS = frozenset({"architecture", "created", "description", "endpoints", "id", "name"})
ENDPOINT_ROW_KEYS = frozenset({"context_length", "latency_last_30m", "max_completion_tokens", "max_prompt_tokens", "model_id", "model_name", "name", "pricing", "provider_name", "quantization", "status", "supported_parameters", "supports_implicit_caching", "supports_voice_cloning", "tag", "throughput_last_30m", "uptime_last_1d", "uptime_last_30m", "uptime_last_5m"})
ENDPOINT_PRICING_KEYS = frozenset({
    "audio", "completion", "discount", "image", "image_output", "image_token",
    "input_audio_cache", "input_cache_read", "input_cache_write", "input_cache_write_1h",
    "internal_reasoning", "overrides", "prompt", "web_search",
})


class EngineError(RuntimeError):
    """A fail-closed error which must prevent artifact publication."""


class FetchError(EngineError):
    """A required upstream fetch did not complete safely."""


class ResponseValidationError(FetchError):
    """A received response is unsafe to retry because it violates transport bounds."""


class SchemaError(EngineError):
    """An input response or local artifact violates its required contract."""


class HTTPClient(Protocol):
    def get(self, url: str, timeout_seconds: float) -> "HTTPResponse": ...


@dataclass(frozen=True)
class HTTPResponse:
    status: int
    body: bytes
    headers: Mapping[str, str]


class UrllibHTTPClient:
    """Small production adapter; tests provide an in-memory HTTP client."""

    def __init__(self, resolver: Callable[[float], list[str]] | None = None):
        self._resolver = resolver or resolve_openrouter_addresses
        self._resolved_addresses: list[str] | None = None
        self._next_address_index = 0

    def get(self, url: str, timeout_seconds: float) -> HTTPResponse:
        if not math.isfinite(timeout_seconds) or not 0 < timeout_seconds <= 60:
            raise FetchError("request timeout must be finite, positive, and no more than 60 seconds")
        """Fetch with bounded connect/read operations and no orphan workers."""
        parsed = urlsplit(url)
        if parsed.scheme != "https" or parsed.netloc != "openrouter.ai" or not parsed.path.startswith("/"):
            raise FetchError(f"refusing non-OpenRouter URL {url!r}")
        deadline = time.monotonic() + timeout_seconds
        if self._resolved_addresses is None:
            self._resolved_addresses = self._resolver(timeout_seconds)
        remaining_after_resolution = deadline - time.monotonic()
        if remaining_after_resolution <= 0:
            raise FetchError(f"wall-clock request deadline exceeded after {timeout_seconds} seconds")
        # Rotate cached A/AAAA results across attempts. fetch_json retries a
        # transport failure, so a broken first route cannot pin the run to it.
        resolved_address = self._resolved_addresses[self._next_address_index % len(self._resolved_addresses)]
        self._next_address_index += 1
        connection = http.client.HTTPSConnection("openrouter.ai", timeout=timeout_seconds)
        def create_resolved_connection(address: tuple[str, int], timeout: float | None = None, source_address: Any = None) -> socket.socket:
            return socket.create_connection((resolved_address, address[1]), timeout=timeout, source_address=source_address)
        connection._create_connection = create_resolved_connection  # type: ignore[attr-defined]
        timed_out = threading.Event()

        def abort_at_deadline() -> None:
            """Interrupt connect/TLS/header/body blocking calls at the absolute deadline."""
            timed_out.set()
            active_socket = connection.sock
            if active_socket is not None:
                try:
                    active_socket.shutdown(socket.SHUT_RDWR)
                except OSError:
                    pass
            connection.close()

        watchdog = threading.Timer(remaining_after_resolution, abort_at_deadline)
        watchdog.daemon = True
        watchdog.start()
        try:
            target = parsed.path + (f"?{parsed.query}" if parsed.query else "")
            connection.request("GET", target, headers={"Accept": "application/json", "User-Agent": TOOL_VERSION})
            response = connection.getresponse()
            if timed_out.is_set():
                raise FetchError(f"wall-clock request deadline exceeded after {timeout_seconds} seconds")
            content_length = response.getheader("Content-Length")
            if content_length:
                try:
                    declared_length = int(content_length)
                except ValueError as error:
                    raise ResponseValidationError("response has invalid Content-Length") from error
                if declared_length > MAX_RESPONSE_BYTES:
                    raise ResponseValidationError(f"response exceeds {MAX_RESPONSE_BYTES} byte limit")
            chunks: list[bytes] = []
            size = 0
            while True:
                remaining = deadline - time.monotonic()
                if remaining <= 0:
                    raise FetchError(f"wall-clock request deadline exceeded after {timeout_seconds} seconds")
                if connection.sock is not None:
                    connection.sock.settimeout(remaining)
                chunk = response.read1(min(64 * 1024, MAX_RESPONSE_BYTES + 1 - size))
                if not chunk:
                    break
                size += len(chunk)
                if size > MAX_RESPONSE_BYTES:
                    raise ResponseValidationError(f"response exceeds {MAX_RESPONSE_BYTES} byte limit")
                chunks.append(chunk)
            if time.monotonic() > deadline:
                raise FetchError(f"wall-clock request deadline exceeded after {timeout_seconds} seconds")
            return HTTPResponse(status=response.status, body=b"".join(chunks), headers=dict(response.getheaders()))
        except (http.client.HTTPException, TimeoutError, OSError) as error:
            if timed_out.is_set():
                raise FetchError(f"wall-clock request deadline exceeded after {timeout_seconds} seconds") from error
            raise FetchError(f"transport error fetching {url}: {error}") from error
        finally:
            watchdog.cancel()
            watchdog.join()
            connection.close()


def utc_now() -> datetime:
    return datetime.now(timezone.utc)


def rfc3339(value: datetime) -> str:
    if value.tzinfo is None:
        raise ValueError("timestamp must be timezone-aware")
    return value.astimezone(timezone.utc).replace(microsecond=0).isoformat().replace("+00:00", "Z")


def parse_rfc3339_utc(value: Any, field: str) -> datetime:
    if not isinstance(value, str) or not value.endswith("Z"):
        raise SchemaError(f"{field} must be an RFC3339 UTC timestamp")
    try:
        parsed = datetime.fromisoformat(value[:-1] + "+00:00")
    except ValueError as error:
        raise SchemaError(f"{field} must be an RFC3339 UTC timestamp") from error
    if parsed.tzinfo != timezone.utc:
        raise SchemaError(f"{field} must be an RFC3339 UTC timestamp")
    return parsed


def parse_ranking_date(value: Any, field: str) -> datetime:
    if not isinstance(value, str):
        raise SchemaError(f"{field} must be OpenRouter ranking timestamp YYYY-MM-DD HH:MM:SS")
    try:
        return datetime.strptime(value, "%Y-%m-%d %H:%M:%S")
    except ValueError as error:
        raise SchemaError(f"{field} must be OpenRouter ranking timestamp YYYY-MM-DD HH:MM:SS") from error


def canonical_json(value: Any) -> bytes:
    return json.dumps(value, sort_keys=True, separators=(",", ":"), ensure_ascii=False).encode("utf-8")


def sha256_prefixed(value: Any) -> str:
    return "sha256:" + hashlib.sha256(canonical_json(value)).hexdigest()


SCHEMA_CONTRACT_FINGERPRINT = sha256_prefixed(
    {
        "rankings_row_keys": sorted(RANKING_ROW_KEYS),
        "catalog_row_keys": sorted(CATALOG_ROW_KEYS),
        "catalog_top_level_keys": sorted(CATALOG_TOP_LEVEL_KEYS),
        "endpoint_data_keys": sorted(ENDPOINT_DATA_KEYS),
        "endpoint_row_keys": sorted(ENDPOINT_ROW_KEYS),
        "endpoint_pricing_keys": sorted(ENDPOINT_PRICING_KEYS),
    }
)


def parse_decimal(value: Any, field: str, *, allow_zero: bool = True) -> Decimal:
    if not isinstance(value, str) or not value.strip():
        raise SchemaError(f"{field} must be a non-empty decimal string")
    try:
        result = Decimal(value)
    except InvalidOperation as error:
        raise SchemaError(f"{field} is not a decimal: {value!r}") from error
    if not result.is_finite() or result < 0 or (not allow_zero and result == 0):
        raise SchemaError(f"{field} must be finite and {'positive' if not allow_zero else 'non-negative'}")
    return result


def _resolve_host_worker(connection: Any, host: str) -> None:
    """Child-process resolver: a blocked system resolver is terminable by parent."""
    try:
        addresses = []
        for family, _, _, _, sockaddr in socket.getaddrinfo(host, 443, type=socket.SOCK_STREAM):
            if family in {socket.AF_INET, socket.AF_INET6} and sockaddr[0] not in addresses:
                addresses.append(sockaddr[0])
        connection.send((True, addresses))
    except OSError as error:
        connection.send((False, str(error)))
    finally:
        connection.close()


def resolve_openrouter_addresses(timeout_seconds: float) -> list[str]:
    """Resolve with a killable deadline so DNS cannot outlive a fetch generation."""
    context = multiprocessing.get_context("spawn")
    parent, child = context.Pipe(duplex=False)
    process = context.Process(target=_resolve_host_worker, args=(child, "openrouter.ai"))
    process.daemon = True
    process.start()
    child.close()
    try:
        if not parent.poll(timeout_seconds):
            process.terminate()
            process.join()
            raise FetchError(f"DNS resolution deadline exceeded after {timeout_seconds} seconds")
        ok, payload = parent.recv()
        process.join()
        if not ok or not isinstance(payload, list) or not payload:
            raise FetchError(f"DNS resolution failed for openrouter.ai: {payload}")
        return payload
    finally:
        parent.close()
        if process.is_alive():
            process.terminate()
            process.join()


def decimal_string(value: Decimal) -> str:
    rendered = format(value.normalize(), "f")
    return "0" if rendered in {"-0", ""} else rendered


def parse_json(response: HTTPResponse, source: str) -> dict[str, Any]:
    if response.status < 200 or response.status >= 300:
        raise FetchError(f"{source}: HTTP {response.status}")
    try:
        parsed = json.loads(response.body.decode("utf-8"))
    except (UnicodeDecodeError, json.JSONDecodeError) as error:
        raise SchemaError(f"{source}: malformed JSON") from error
    if not isinstance(parsed, dict):
        raise SchemaError(f"{source}: top-level JSON value must be an object")
    return parsed


def retry_after_seconds(headers: Mapping[str, str], *, now: datetime | None = None) -> float | None:
    """Return the RFC 9110 Retry-After delay, including its HTTP-date form."""
    for key, value in headers.items():
        if key.lower() == "retry-after":
            try:
                parsed = float(value)
            except (TypeError, ValueError):
                try:
                    retry_at = parsedate_to_datetime(value)
                except (TypeError, ValueError, IndexError):
                    return None
                if retry_at.tzinfo is None:
                    return None
                reference = now or utc_now()
                return max(0.0, (retry_at - reference).total_seconds())
            return parsed if math.isfinite(parsed) and parsed >= 0 else None
    return None


def fetch_json(
    client: HTTPClient,
    url: str,
    source: str,
    *,
    retries: int,
    timeout_seconds: float,
    sleeper: Callable[[float], None] = time.sleep,
    jitter: Callable[[], float] = random.random,
    deadline: float | None = None,
    clock: Callable[[], float] = time.monotonic,
) -> dict[str, Any]:
    """Fetch JSON with bounded retry/backoff; non-transient failures fail closed."""
    if retries < 0:
        raise ValueError("retries must be non-negative")
    last_error: EngineError | None = None
    for attempt in range(retries + 1):
        if deadline is not None and clock() >= deadline:
            raise FetchError(f"{source}: generation deadline exceeded before request")
        effective_timeout = timeout_seconds if deadline is None else min(timeout_seconds, deadline - clock())
        if effective_timeout <= 0:
            raise FetchError(f"{source}: generation deadline exceeded before request")
        try:
            response = client.get(url, effective_timeout)
        except FetchError as error:
            last_error = error
            retryable = not isinstance(error, ResponseValidationError)
        else:
            if deadline is not None and clock() >= deadline:
                raise FetchError(f"{source}: generation deadline exceeded after request")
            if 200 <= response.status < 300:
                return parse_json(response, source)
            retryable = response.status == 429 or 500 <= response.status < 600
            last_error = FetchError(f"{source}: HTTP {response.status}")
            if response.status == 429:
                requested_delay = retry_after_seconds(response.headers)
            else:
                requested_delay = None
        if not retryable or attempt == retries:
            raise last_error
        if "requested_delay" not in locals() or requested_delay is None:
            delay = min(8.0, 0.5 * (2**attempt)) + (jitter() * 0.1)
        else:
            delay = requested_delay
        if deadline is not None and clock() + delay > deadline:
            raise FetchError(f"{source}: generation deadline would be exceeded during retry backoff")
        sleeper(delay)
        requested_delay = None
    raise AssertionError("retry loop must return or raise")


def required_list(document: Mapping[str, Any], key: str, source: str) -> list[Any]:
    value = document.get(key)
    if not isinstance(value, list):
        raise SchemaError(f"{source}: {key!r} must be a list")
    if not value:
        raise SchemaError(f"{source}: {key!r} must not be empty")
    return value


def require_allowed_keys(value: Mapping[str, Any], allowed: frozenset[str], location: str) -> None:
    unexpected = sorted(set(value) - allowed)
    if unexpected:
        raise SchemaError(f"{location}: unexpected fields {unexpected}")


def normalize_rankings(document: Mapping[str, Any], top_n: int) -> list[dict[str, Any]]:
    require_allowed_keys(document, frozenset({"data"}), "rankings response")
    rows = required_list(document, "data", "rankings response")
    totals: dict[str, int] = {}
    dates: dict[str, str] = {}
    eligible_rows: list[tuple[dict[str, Any], datetime]] = []
    for index, row in enumerate(rows):
        if not isinstance(row, dict):
            raise SchemaError(f"rankings response: data[{index}] must be an object")
        require_allowed_keys(row, RANKING_ROW_KEYS, f"rankings response: data[{index}]")
        completion_tokens = row.get("total_completion_tokens")
        if isinstance(completion_tokens, bool) or not isinstance(completion_tokens, int) or completion_tokens < 0:
            raise SchemaError(f"rankings response: data[{index}].total_completion_tokens must be non-negative integer")
        # Non-generation rows (for example embedding-only models) have no
        # completion demand and are outside this completion-rate pipeline.
        if completion_tokens == 0:
            continue
        model_id = row.get("model_permaslug")
        date = row.get("date")
        if not isinstance(model_id, str) or not model_id.strip():
            raise SchemaError(f"rankings response: data[{index}].model_permaslug must be non-empty")
        if not MODEL_ID_RE.fullmatch(model_id):
            raise SchemaError(f"rankings response: data[{index}].model_permaslug has unsafe shape")
        parsed_date = parse_ranking_date(date, f"rankings response: data[{index}].date")
        eligible_rows.append((row, parsed_date))
    if not eligible_rows:
        raise SchemaError("rankings response: no completion-demand rows")
    latest_date = max(parsed_date for _, parsed_date in eligible_rows)
    for row, parsed_date in eligible_rows:
        if parsed_date != latest_date:
            continue
        model_id = row["model_permaslug"]
        completion_tokens = row["total_completion_tokens"]
        date = row["date"]
        totals[model_id] = totals.get(model_id, 0) + completion_tokens
        dates[model_id] = max(date, dates.get(model_id, date))
    ordered = sorted(totals, key=lambda item: (-totals[item], item))[:top_n]
    if not ordered:
        raise SchemaError("rankings response: no normalized ranking rows")
    return [
        {"source_model_id": model_id, "rank": rank, "completion_volume": str(totals[model_id]), "ranking_date": dates[model_id]}
        for rank, model_id in enumerate(ordered, start=1)
    ]


def validate_catalog(document: Mapping[str, Any]) -> dict[str, dict[str, Any]]:
    require_allowed_keys(document, CATALOG_TOP_LEVEL_KEYS, "models response")
    rows = required_list(document, "data", "models response")
    result: dict[str, dict[str, Any]] = {}
    for index, row in enumerate(rows):
        if not isinstance(row, dict):
            raise SchemaError(f"models response: data[{index}] must be an object")
        require_allowed_keys(row, CATALOG_ROW_KEYS, f"models response: data[{index}]")
        model_id = row.get("id")
        canonical_slug = row.get("canonical_slug")
        if not isinstance(model_id, str) or not model_id.strip():
            raise SchemaError(f"models response: data[{index}].id must be non-empty")
        if not MODEL_ID_RE.fullmatch(model_id):
            raise SchemaError(f"models response: data[{index}].id has unsafe shape")
        if not isinstance(canonical_slug, str) or not canonical_slug.strip():
            raise SchemaError(f"models response: data[{index}].canonical_slug must be non-empty")
        if model_id in result:
            raise SchemaError(f"models response: duplicate model id {model_id!r}")
        result[model_id] = row
    return result


def resolve_rankings_to_catalog(
    rankings: list[dict[str, Any]],
    catalog: Mapping[str, Mapping[str, Any]],
    endpoint_documents: Mapping[str, Mapping[str, Any]] | None = None,
) -> list[dict[str, Any]]:
    """Resolve ranking permaslugs to the catalog ID accepted by endpoints API.

    OpenRouter rankings can retain a dated permaslug after the catalog exposes
    the same model under a current ID. If the catalog no longer lists a dated
    ranking ID, the endpoint response for that exact dated ID may authoritatively
    return its current ID. All other ambiguity is a coverage failure, never a
    guess.
    """
    canonical_index: dict[str, list[str]] = {}
    for model_id, catalog_row in catalog.items():
        canonical_slug = catalog_row["canonical_slug"]
        canonical_index.setdefault(canonical_slug, []).append(model_id)
    resolved: list[dict[str, Any]] = []
    for demand in rankings:
        ranking_slug = demand["source_model_id"]
        if ranking_slug in catalog:
            catalog_id = ranking_slug
            identity_resolution = "catalog"
        else:
            candidates = canonical_index.get(ranking_slug, [])
            if len(candidates) == 1:
                catalog_id = candidates[0]
                identity_resolution = "catalog"
            else:
                # Rankings aggregate the paid and :free variants under one
                # permaslug. The catalog identifies the paid endpoint by the
                # absence of the explicit :free suffix. This is a narrowly
                # defined resolution rule; all other ambiguity still fails.
                paid_candidates = [candidate for candidate in candidates if not candidate.endswith(":free")]
                if len(paid_candidates) == 1:
                    catalog_id = paid_candidates[0]
                    identity_resolution = "catalog_paid_variant"
                elif not candidates:
                    if endpoint_documents is None:
                        # Fetch the dated endpoint first; build_snapshot will
                        # validate and replace this temporary request identity.
                        catalog_id = ranking_slug
                        identity_resolution = "endpoint_alias_pending"
                    else:
                        endpoint_document = endpoint_documents.get(ranking_slug)
                        if endpoint_document is None:
                            raise SchemaError(f"partial pull: endpoints response missing for ranked model {ranking_slug!r}")
                        catalog_id = endpoint_response_model_id(endpoint_document, ranking_slug)
                        identity_resolution = "endpoint_alias_fallback"
                else:
                    raise SchemaError(
                        f"catalog response cannot uniquely resolve ranked model {ranking_slug!r} to an endpoint model id"
                    )
        normalized = dict(demand)
        normalized["source_model_id"] = catalog_id
        normalized["ranking_model_permaslug"] = ranking_slug
        normalized["_identity_resolution"] = identity_resolution
        resolved.append(normalized)
    return resolved


def endpoint_response_model_id(document: Mapping[str, Any], requested_model_id: str) -> str:
    """Read an endpoint response identity without assuming its request alias."""
    require_allowed_keys(document, frozenset({"data"}), f"endpoints response for {requested_model_id}")
    data = document.get("data")
    if not isinstance(data, dict):
        raise SchemaError(f"endpoints response for {requested_model_id}: data must be an object")
    require_allowed_keys(data, ENDPOINT_DATA_KEYS, f"endpoints response for {requested_model_id}: data")
    model_id = data.get("id")
    if not isinstance(model_id, str) or not MODEL_ID_RE.fullmatch(model_id):
        raise SchemaError(f"endpoints response for {requested_model_id}: response id is invalid")
    return model_id


def cheapest_endpoint_pricing(document: Mapping[str, Any], model_id: str) -> dict[str, str] | None:
    require_allowed_keys(document, frozenset({"data"}), f"endpoints response for {model_id}")
    data = document.get("data")
    if not isinstance(data, dict):
        raise SchemaError(f"endpoints response for {model_id}: data must be an object")
    require_allowed_keys(data, ENDPOINT_DATA_KEYS, f"endpoints response for {model_id}: data")
    if data.get("id") != model_id:
        raise SchemaError(f"endpoints response for {model_id}: response id mismatch")
    endpoints = data.get("endpoints")
    if not isinstance(endpoints, list) or not endpoints:
        raise SchemaError(f"endpoints response for {model_id}: endpoints must be a non-empty list")
    priced: list[tuple[Decimal, Decimal, str]] = []
    for index, endpoint in enumerate(endpoints):
        if not isinstance(endpoint, dict):
            raise SchemaError(f"endpoints response for {model_id}: endpoints[{index}] must be an object")
        require_allowed_keys(endpoint, ENDPOINT_ROW_KEYS, f"endpoints response for {model_id}: endpoints[{index}]")
        status = endpoint.get("status")
        if isinstance(status, bool) or not isinstance(status, int):
            raise SchemaError(f"endpoints response for {model_id}: endpoints[{index}].status must be an integer")
        if status != 0:
            continue
        provider = endpoint.get("provider_name")
        pricing = endpoint.get("pricing")
        if not isinstance(provider, str) or not provider.strip() or not isinstance(pricing, dict):
            raise SchemaError(f"endpoints response for {model_id}: active endpoint[{index}] missing provider/pricing")
        require_allowed_keys(pricing, ENDPOINT_PRICING_KEYS, f"endpoints response for {model_id}: endpoints[{index}].pricing")
        prompt = parse_decimal(pricing.get("prompt"), f"endpoints response for {model_id}: prompt")
        completion = parse_decimal(pricing.get("completion"), f"endpoints response for {model_id}: completion")
        priced.append((completion, prompt, provider))
    if not priced:
        return None
    completion, prompt, provider = min(priced, key=lambda item: (item[0], item[1], item[2]))
    return {
        "input_per_token": decimal_string(prompt),
        "completion_per_token": decimal_string(completion),
        "input_per_mtok": decimal_string(prompt * Decimal("1000000")),
        "completion_per_mtok": decimal_string(completion * Decimal("1000000")),
        "currency": "USD",
        "benchmark_provider": provider,
    }


def snapshot_digest_payload(snapshot: Mapping[str, Any]) -> dict[str, Any]:
    payload = copy.deepcopy(dict(snapshot))
    payload.pop("content_digest", None)
    payload.pop("fetched_at", None)
    return payload


def validate_snapshot(snapshot: Mapping[str, Any]) -> None:
    if snapshot.get("schema_version") != SNAPSHOT_SCHEMA_VERSION or snapshot.get("snapshot_type") != "openrouter-pricing":
        raise SchemaError("snapshot has unsupported schema version or type")
    parse_rfc3339_utc(snapshot.get("fetched_at"), "snapshot.fetched_at")
    expected_digest = sha256_prefixed(snapshot_digest_payload(snapshot))
    if snapshot.get("content_digest") != expected_digest:
        raise SchemaError("snapshot content_digest does not match normalized payload")
    source = snapshot.get("source")
    rows = snapshot.get("rows")
    if not isinstance(source, dict) or not isinstance(rows, list) or not rows:
        raise SchemaError("snapshot source must be object and rows must be non-empty list")
    required_source = {"rankings_url", "pricing_url_or_urls", "observed_schema_version_or_fingerprint", "generator_version", "fetch_metadata"}
    if set(source) != required_source:
        raise SchemaError("snapshot source has missing or unexpected provenance fields")
    if source["rankings_url"] != RANKINGS_URL or not isinstance(source["pricing_url_or_urls"], list) or not all(isinstance(url, str) and url.startswith("https://openrouter.ai/") for url in source["pricing_url_or_urls"]):
        raise SchemaError("snapshot source endpoints are invalid")
    if source["observed_schema_version_or_fingerprint"] != SCHEMA_CONTRACT_FINGERPRINT or not isinstance(source["generator_version"], str):
        raise SchemaError("snapshot source schema/generator provenance is invalid")
    fetch_metadata = source["fetch_metadata"]
    if not isinstance(fetch_metadata, dict) or set(fetch_metadata) != {"successful_source_count", "observed_model_count", "requested_top_n"}:
        raise SchemaError("snapshot fetch_metadata has missing or unexpected fields")
    for key in ("successful_source_count", "observed_model_count", "requested_top_n"):
        if isinstance(fetch_metadata[key], bool) or not isinstance(fetch_metadata[key], int) or fetch_metadata[key] < 1:
            raise SchemaError(f"snapshot fetch_metadata.{key} must be a positive integer")
    if fetch_metadata["observed_model_count"] != len(rows) or fetch_metadata["successful_source_count"] != 2 + len(rows):
        raise SchemaError("snapshot fetch_metadata counts do not match rows")
    seen: set[str] = set()
    seen_source_ids: set[str] = set()
    seen_ranking_slugs: set[str] = set()
    ranks: set[int] = set()
    for index, row in enumerate(rows):
        if not isinstance(row, dict):
            raise SchemaError(f"snapshot.rows[{index}] must be object")
        source_id = row.get("source_model_id")
        canonical_id = row.get("canonical_model_id")
        demand = row.get("demand")
        pricing = row.get("pricing")
        pricing_status = row.get("pricing_status")
        if not isinstance(source_id, str) or not MODEL_ID_RE.fullmatch(source_id) or not isinstance(canonical_id, str) or not CANONICAL_ID_RE.fullmatch(canonical_id) or canonical_id == "default":
            raise SchemaError(f"snapshot.rows[{index}] has invalid model identity")
        if row.get("mapping_status") not in {"exact", "alias", "unmapped", "rejected"}:
            raise SchemaError(f"snapshot.rows[{index}] has invalid mapping_status")
        if canonical_id in seen:
            raise SchemaError(f"snapshot has duplicate canonical model id {canonical_id!r}")
        if source_id in seen_source_ids:
            raise SchemaError(f"snapshot has duplicate source model id {source_id!r}")
        seen.add(canonical_id)
        seen_source_ids.add(source_id)
        if not isinstance(demand, dict) or set(demand) != {"source_model_id", "rank", "completion_volume", "ranking_date", "ranking_model_permaslug"}:
            raise SchemaError(f"snapshot.rows[{index}] has invalid demand")
        if demand["source_model_id"] != source_id or not isinstance(demand.get("rank"), int) or demand["rank"] < 1 or not isinstance(demand.get("completion_volume"), str) or not demand["completion_volume"].isdigit() or int(demand["completion_volume"]) <= 0 or not isinstance(demand.get("ranking_model_permaslug"), str) or not MODEL_ID_RE.fullmatch(demand["ranking_model_permaslug"]):
            raise SchemaError(f"snapshot.rows[{index}] has invalid demand")
        parse_ranking_date(demand.get("ranking_date"), f"snapshot.rows[{index}].demand.ranking_date")
        if demand["ranking_model_permaslug"] in seen_ranking_slugs:
            raise SchemaError(f"snapshot has duplicate ranking model permaslug {demand['ranking_model_permaslug']!r}")
        seen_ranking_slugs.add(demand["ranking_model_permaslug"])
        ranks.add(demand["rank"])
        if pricing_status not in {"active_priced", "no_active_priced_endpoint"}:
            raise SchemaError(f"snapshot.rows[{index}] has invalid pricing status")
        if pricing_status == "no_active_priced_endpoint":
            if pricing is not None:
                raise SchemaError(f"snapshot.rows[{index}] unavailable pricing must be null")
        elif not isinstance(pricing, dict) or set(pricing) != {"input_per_token", "completion_per_token", "input_per_mtok", "completion_per_mtok", "currency", "benchmark_provider"}:
            raise SchemaError(f"snapshot.rows[{index}] has invalid pricing")
        if pricing_status == "active_priced" and (pricing["currency"] != "USD" or not isinstance(pricing["benchmark_provider"], str) or not pricing["benchmark_provider"]):
            raise SchemaError(f"snapshot.rows[{index}] has invalid pricing provenance")
        if not isinstance(row.get("source_metadata"), dict) or set(row["source_metadata"]) != {"ranking_model_permaslug", "catalog_canonical_slug", "catalog_name", "identity_resolution"}:
            raise SchemaError(f"snapshot.rows[{index}] has invalid source metadata")
        source_metadata = row["source_metadata"]
        if not isinstance(source_metadata["ranking_model_permaslug"], str) or not MODEL_ID_RE.fullmatch(source_metadata["ranking_model_permaslug"]):
            raise SchemaError(f"snapshot.rows[{index}] has invalid ranking provenance")
        if source_metadata["catalog_canonical_slug"] is not None and not isinstance(source_metadata["catalog_canonical_slug"], str):
            raise SchemaError(f"snapshot.rows[{index}] has invalid catalog provenance")
        if source_metadata["catalog_name"] is not None and not isinstance(source_metadata["catalog_name"], str):
            raise SchemaError(f"snapshot.rows[{index}] has invalid catalog provenance")
        if source_metadata["identity_resolution"] not in {"catalog", "catalog_paid_variant", "endpoint_alias_fallback"}:
            raise SchemaError(f"snapshot.rows[{index}] has invalid identity resolution")
        if pricing_status == "active_priced":
            parse_decimal(pricing.get("input_per_mtok"), f"snapshot.rows[{index}].pricing.input_per_mtok")
            parse_decimal(pricing.get("completion_per_mtok"), f"snapshot.rows[{index}].pricing.completion_per_mtok")
    if ranks != set(range(1, len(rows) + 1)):
        raise SchemaError("snapshot ranks must be contiguous from 1 through row count")


def build_snapshot(
    rankings_document: Mapping[str, Any],
    catalog_document: Mapping[str, Any],
    endpoints_documents: Mapping[str, Mapping[str, Any]],
    policy: Mapping[str, Any],
    *,
    now: datetime,
    top_n: int,
) -> dict[str, Any]:
    rankings = normalize_rankings(rankings_document, top_n)
    catalog = validate_catalog(catalog_document)
    endpoint_requests = resolve_rankings_to_catalog(rankings, catalog)
    requested_endpoint_ids = {demand["source_model_id"] for demand in endpoint_requests}
    if set(endpoints_documents) != requested_endpoint_ids:
        raise SchemaError("endpoints response set does not exactly match selected ranking models")
    rankings = resolve_rankings_to_catalog(rankings, catalog, endpoints_documents)
    resolved_endpoints: dict[str, Mapping[str, Any]] = {}
    for demand in rankings:
        request_id = demand["ranking_model_permaslug"] if demand["_identity_resolution"] == "endpoint_alias_fallback" else demand["source_model_id"]
        source_model_id = demand["source_model_id"]
        if source_model_id in resolved_endpoints:
            raise SchemaError(f"endpoint alias resolution produced duplicate model id {source_model_id!r}")
        resolved_endpoints[source_model_id] = endpoints_documents[request_id]
    policy_models = policy_model_index(policy)
    normalized_rows: list[dict[str, Any]] = []
    for demand in rankings:
        source_model_id = demand["source_model_id"]
        if source_model_id not in resolved_endpoints:
            raise SchemaError(f"partial pull: endpoints response missing for {source_model_id!r}")
        endpoint_pricing = cheapest_endpoint_pricing(resolved_endpoints[source_model_id], source_model_id)
        catalog_row = catalog.get(source_model_id)
        if catalog_row is None and demand["_identity_resolution"] != "endpoint_alias_fallback":
            raise SchemaError(f"catalog response lacks ranked model {source_model_id!r}")
        metadata = policy_models.get(source_model_id)
        snapshot_demand = {key: value for key, value in demand.items() if key != "_identity_resolution"}
        normalized_rows.append(
            {
                "source_model_id": source_model_id,
                "canonical_model_id": metadata["canonical_model_id"] if metadata else source_model_id,
                "mapping_status": (
                    "exact"
                    if metadata and metadata["canonical_model_id"] == source_model_id
                    else "alias"
                    if metadata
                    else "unmapped"
                ),
                "demand": snapshot_demand,
                "pricing": endpoint_pricing,
                "pricing_status": "active_priced" if endpoint_pricing else "no_active_priced_endpoint",
                "source_metadata": {
                    "ranking_model_permaslug": demand["ranking_model_permaslug"],
                    "catalog_canonical_slug": catalog_row["canonical_slug"] if catalog_row else None,
                    "catalog_name": catalog_row.get("name") if catalog_row else None,
                    "identity_resolution": demand["_identity_resolution"],
                },
            }
        )
    normalized_rows.sort(key=lambda row: (row["demand"]["rank"], row["source_model_id"]))
    snapshot: dict[str, Any] = {
        "schema_version": SNAPSHOT_SCHEMA_VERSION,
        "snapshot_type": "openrouter-pricing",
        "fetched_at": rfc3339(now),
        "source": {
            "rankings_url": RANKINGS_URL,
            "pricing_url_or_urls": [MODELS_URL, ENDPOINTS_URL],
            "observed_schema_version_or_fingerprint": SCHEMA_CONTRACT_FINGERPRINT,
            "generator_version": TOOL_VERSION,
            "fetch_metadata": {
                "successful_source_count": 2 + len(endpoints_documents),
                "observed_model_count": len(normalized_rows),
                "requested_top_n": top_n,
            },
        },
        "rows": normalized_rows,
    }
    snapshot["content_digest"] = sha256_prefixed(snapshot_digest_payload(snapshot))
    validate_snapshot(snapshot)
    return snapshot


def nonempty_https_url(value: Any, field: str) -> None:
    if not isinstance(value, str) or not value.startswith("https://") or len(value) <= len("https://"):
        raise SchemaError(f"{field} must be a non-empty https URL")


def validate_policy_model(model: Mapping[str, Any], index: int) -> None:
    source_id = model.get("source_model_id")
    canonical_id = model.get("canonical_model_id")
    if not isinstance(source_id, str) or not MODEL_ID_RE.fullmatch(source_id):
        raise SchemaError(f"policy.models[{index}].source_model_id is invalid")
    if not isinstance(canonical_id, str) or not CANONICAL_ID_RE.fullmatch(canonical_id) or canonical_id == "default":
        raise SchemaError(f"policy.models[{index}].canonical_model_id is invalid")
    profile = model.get("profile")
    if not isinstance(profile, dict) or set(profile) != {"kind", "active_params_b", "residency_gb", "projected_tps"}:
        raise SchemaError(f"policy.models[{index}].profile has missing or unexpected fields")
    if profile.get("kind") not in {"broad_fleet", "coding_dense"}:
        raise SchemaError(f"policy.models[{index}].profile.kind is invalid")
    for field in ("active_params_b", "residency_gb", "projected_tps"):
        parse_decimal(profile.get(field), f"policy.models[{index}].profile.{field}")
    serving = model.get("serving_path")
    if not isinstance(serving, dict) or set(serving) != {"verification_status", "reference"}:
        raise SchemaError(f"policy.models[{index}].serving_path has missing or unexpected fields")
    if serving.get("verification_status") not in {"verified", "unverified"}:
        raise SchemaError(f"policy.models[{index}].serving_path.verification_status is invalid")
    nonempty_https_url(serving.get("reference"), f"policy.models[{index}].serving_path.reference")
    license_info = model.get("license")
    if not isinstance(license_info, dict) or set(license_info) != {"commercial_permitted", "source_url", "verification_note"}:
        raise SchemaError(f"policy.models[{index}].license has missing or unexpected fields")
    if not isinstance(license_info.get("commercial_permitted"), bool):
        raise SchemaError(f"policy.models[{index}].license.commercial_permitted must be boolean")
    nonempty_https_url(license_info.get("source_url"), f"policy.models[{index}].license.source_url")
    if not isinstance(license_info.get("verification_note"), str) or not license_info["verification_note"].strip():
        raise SchemaError(f"policy.models[{index}].license.verification_note must be non-empty")
    expected_keys = {"source_model_id", "canonical_model_id", "serving_path", "license", "profile"}
    if profile["kind"] == "coding_dense":
        expected_keys |= {"coding_specialist", "general_purpose_baseline_per_mtok"}
        if model.get("coding_specialist") is not True:
            raise SchemaError(f"policy.models[{index}].coding_specialist must be true")
        parse_decimal(model.get("general_purpose_baseline_per_mtok"), f"policy.models[{index}].general_purpose_baseline_per_mtok", allow_zero=False)
    if set(model) != expected_keys:
        raise SchemaError(f"policy.models[{index}] has missing or unexpected fields")


def policy_model_index(policy: Mapping[str, Any]) -> dict[str, Mapping[str, Any]]:
    models = policy.get("models")
    if not isinstance(models, list):
        raise SchemaError("policy.models must be a list")
    result: dict[str, Mapping[str, Any]] = {}
    canonical_ids: set[str] = set()
    for index, model in enumerate(models):
        if not isinstance(model, dict):
            raise SchemaError(f"policy.models[{index}] must be an object")
        validate_policy_model(model, index)
        source_id = model["source_model_id"]
        canonical_id = model["canonical_model_id"]
        if source_id in result:
            raise SchemaError(f"policy duplicate source_model_id {source_id!r}")
        if canonical_id in canonical_ids:
            raise SchemaError(f"policy duplicate canonical_model_id {canonical_id!r}")
        result[source_id] = model
        canonical_ids.add(canonical_id)
    return result


def validate_policy(policy: Mapping[str, Any]) -> None:
    expected_keys = {
        "policy_version", "demand_top_n", "broad_fleet_undercut_fraction",
        "coding_minimum_undercut_fraction", "coding_premium_fraction", "models",
    }
    if set(policy) != expected_keys:
        raise SchemaError("policy has missing or unexpected fields")
    if not isinstance(policy.get("policy_version"), str) or not policy["policy_version"]:
        raise SchemaError("policy.policy_version must be non-empty")
    demand_top_n = policy.get("demand_top_n")
    if demand_top_n != 100:
        raise SchemaError("policy.demand_top_n must be exactly 100")
    undercut = parse_decimal(policy.get("broad_fleet_undercut_fraction"), "policy.broad_fleet_undercut_fraction", allow_zero=False)
    if not Decimal("0.10") <= undercut <= Decimal("0.30"):
        raise SchemaError("policy broad-fleet undercut fraction must be within 10%-30%")
    coding_min = parse_decimal(policy.get("coding_minimum_undercut_fraction"), "policy.coding_minimum_undercut_fraction", allow_zero=False)
    if coding_min < Decimal("0.10"):
        raise SchemaError("policy coding minimum undercut fraction must be at least 10%")
    premium = parse_decimal(policy.get("coding_premium_fraction"), "policy coding_premium_fraction", allow_zero=False)
    if not Decimal("0.10") <= premium <= Decimal("0.30"):
        raise SchemaError("policy coding premium fraction must be within 10%-30%")
    policy_model_index(policy)


def load_json_file(path: Path, description: str) -> dict[str, Any]:
    try:
        value = json.loads(path.read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError) as error:
        raise SchemaError(f"could not read {description} {path}: {error}") from error
    if not isinstance(value, dict):
        raise SchemaError(f"{description} must be a JSON object")
    return value


def rate_card_digest(rate_card: Mapping[str, Any]) -> str:
    return sha256_prefixed(rate_card)


def validate_rate_card(rate_card: Mapping[str, Any]) -> None:
    expected_top_level = {"version", "policy_version", "generated_at", "usd_per_million_credits", "rows"}
    if set(rate_card) != expected_top_level:
        raise SchemaError("rate card has missing or unexpected top-level fields")
    for field in ("version", "policy_version", "generated_at"):
        if not isinstance(rate_card.get(field), str) or not rate_card[field].strip():
            raise SchemaError(f"rate card {field} must be non-empty string")
    credits = rate_card.get("usd_per_million_credits")
    if isinstance(credits, bool) or not isinstance(credits, (int, float)) or not math.isfinite(float(credits)) or credits <= 0:
        raise SchemaError("rate card usd_per_million_credits must be finite positive number")
    rows = rate_card.get("rows")
    if not isinstance(rows, dict) or not rows or "default" not in rows:
        raise SchemaError("rate card rows must be non-empty object with default row")
    required_row_fields = {"prompt_rate_per_mtok", "prompt_cache_hit_rate_per_mtok", "completion_rate_per_mtok", "provider_share_bps", "global_multiplier_ppm"}
    for model_id, row in rows.items():
        if not isinstance(model_id, str) or (model_id != "default" and not CANONICAL_ID_RE.fullmatch(model_id)):
            raise SchemaError(f"rate card has invalid model id {model_id!r}")
        if not isinstance(row, dict) or set(row) != required_row_fields:
            raise SchemaError(f"rate card row {model_id!r} has missing or unexpected fields")
        for field, value in row.items():
            if isinstance(value, bool) or not isinstance(value, int) or value < 0:
                raise SchemaError(f"rate card row {model_id!r}.{field} must be non-negative integer")
        if row["provider_share_bps"] > 10000 or row["global_multiplier_ppm"] == 0:
            raise SchemaError(f"rate card row {model_id!r} has invalid share or multiplier")


def current_completion_rate(rate_rows: Mapping[str, Any], model_id: str) -> dict[str, int] | None:
    current = rate_rows.get(model_id)
    if current is None:
        return None
    if not isinstance(current, dict):
        raise SchemaError(f"rate card row {model_id!r} must be an object")
    value = current.get("completion_rate_per_mtok")
    if isinstance(value, bool) or not isinstance(value, int) or value < 0:
        raise SchemaError(f"rate card row {model_id!r} has invalid completion_rate_per_mtok")
    return {"rate_card_completion_rate_per_mtok": value}


def rate_card_economics(rate_card: Mapping[str, Any], model_id: str) -> tuple[Decimal, Decimal, Decimal, str]:
    """Return USD conversion, multiplier, share, and the row used as basis."""
    rows = rate_card["rows"]
    basis_id = model_id if model_id in rows else "default"
    basis = rows[basis_id]
    return (
        Decimal(str(rate_card["usd_per_million_credits"])),
        Decimal(basis["global_multiplier_ppm"]),
        Decimal(basis["provider_share_bps"]),
        basis_id,
    )


def completion_rate_to_internal(value: Decimal, rate_card: Mapping[str, Any], model_id: str) -> int:
    """Convert buyer USD/MTok to the reference card's credits/MTok encoding."""
    usd_per_million_credits, multiplier_ppm, _, _ = rate_card_economics(rate_card, model_id)
    credits_per_mtok = value * Decimal("1000000000000") / (multiplier_ppm * usd_per_million_credits)
    return int(credits_per_mtok.quantize(Decimal("1"), rounding=ROUND_HALF_UP))


def provider_hourly_usd(internal_rate_per_mtok: int, tps: Decimal, rate_card: Mapping[str, Any], model_id: str) -> Decimal:
    """Provider net USD/hour under the exact reference-card conversion/share."""
    usd_per_million_credits, multiplier_ppm, provider_share_bps, _ = rate_card_economics(rate_card, model_id)
    buyer_usd_per_mtok = Decimal(internal_rate_per_mtok) * multiplier_ppm * usd_per_million_credits / Decimal("1000000000000")
    return buyer_usd_per_mtok * provider_share_bps / Decimal("10000") * tps * Decimal("3600") / Decimal("1000000")


def eligibility(model: Mapping[str, Any], row: Mapping[str, Any], policy: Mapping[str, Any]) -> tuple[bool, list[str], Decimal | None]:
    reasons: list[str] = []
    rank = row["demand"]["rank"]
    if rank > 100:
        reasons.append(f"demand rank {rank} is outside the top-100 completion-token gate")
    serving = model.get("serving_path")
    if not isinstance(serving, dict) or serving.get("verification_status") != "verified":
        reasons.append("MLX/GGUF serving path is not verified")
    license_info = model.get("license")
    if not isinstance(license_info, dict) or license_info.get("commercial_permitted") is not True:
        reasons.append("commercial license is not verified as permitted")
    profile = model.get("profile")
    if not isinstance(profile, dict):
        reasons.append("model profile is missing")
        return False, reasons, None
    kind = profile.get("kind")
    active = profile.get("active_params_b")
    residency = profile.get("residency_gb")
    tps = profile.get("projected_tps")
    try:
        active_d = Decimal(str(active))
        residency_d = Decimal(str(residency))
        tps_d = Decimal(str(tps))
    except (InvalidOperation, ValueError) as error:
        raise SchemaError(f"policy profile for {model['source_model_id']} has invalid numeric value") from error
    if kind == "broad_fleet":
        if active_d > Decimal("8"):
            reasons.append("broad-fleet active parameters exceed 8B")
        if residency_d > Decimal("18"):
            reasons.append("broad-fleet 4-bit residency exceeds 18 GB")
        if tps_d < Decimal("30"):
            reasons.append("broad-fleet projected M-base TPS is below 30")
    elif kind == "coding_dense":
        if residency_d > Decimal("45"):
            reasons.append("coding-dense 4-bit residency exceeds 45 GB")
        if tps_d < Decimal("20"):
            reasons.append("coding-dense projected M-Max TPS is below 20")
        if model.get("coding_specialist") is not True:
            reasons.append("coding-dense profile is not marked coding-specialist")
    else:
        reasons.append("model profile kind is not eligible")
    pricing = row.get("pricing")
    if row.get("pricing_status") != "active_priced" or not isinstance(pricing, dict):
        reasons.append("no active priced OpenRouter endpoint is available")
        return False, reasons, None
    completion = parse_decimal(pricing.get("completion_per_mtok"), "snapshot completion price")
    if completion == 0:
        reasons.append("cheapest active completion endpoint is free; no paid-market undercut can be computed")
    return not reasons, reasons, completion


def proposed_completion_price(
    model: Mapping[str, Any], market_completion: Decimal, policy: Mapping[str, Any], rate_card: Mapping[str, Any], model_id: str
) -> tuple[Decimal, int, list[str]]:
    profile = model["profile"]
    kind = profile["kind"]
    if kind == "broad_fleet":
        undercut = parse_decimal(policy["broad_fleet_undercut_fraction"], "policy broad_fleet_undercut_fraction")
        target = market_completion * (Decimal("1") - undercut)
        return target, completion_rate_to_internal(target, rate_card, model_id), [f"broad-fleet undercut fraction {decimal_string(undercut)}"]
    if kind != "coding_dense":
        raise SchemaError(f"unsupported profile kind {kind!r}")
    undercut = parse_decimal(policy["coding_minimum_undercut_fraction"], "policy coding_minimum_undercut_fraction")
    baseline = parse_decimal(model.get("general_purpose_baseline_per_mtok"), "coding model general_purpose_baseline_per_mtok", allow_zero=False)
    premium = parse_decimal(policy.get("coding_premium_fraction"), "policy coding_premium_fraction")
    if premium < Decimal("0.10") or premium > Decimal("0.30"):
        raise SchemaError("policy coding premium fraction must be within 10%-30%")
    premium_price = baseline * (Decimal("1") + premium)
    market_cap = market_completion * (Decimal("1") - undercut)
    target = min(premium_price, market_cap)
    internal_rate = completion_rate_to_internal(target, rate_card, model_id)
    tps = parse_decimal(profile["projected_tps"], "coding model projected_tps", allow_zero=False)
    provider_hourly = provider_hourly_usd(internal_rate, tps, rate_card, model_id)
    if provider_hourly < Decimal("0.10"):
        raise SchemaError("coding-dense target does not meet the $0.10/hour provider economics floor")
    _, _, _, basis_id = rate_card_economics(rate_card, model_id)
    return target, internal_rate, [
        f"coding premium fraction {decimal_string(premium)}",
        f"coding market undercut fraction {decimal_string(undercut)}",
        f"provider net hourly USD {decimal_string(provider_hourly)} using rate-card economics row {basis_id}",
    ]


def build_proposal(
    snapshot: Mapping[str, Any], policy: Mapping[str, Any], rate_card: Mapping[str, Any], *, now: datetime
) -> dict[str, Any]:
    validate_snapshot(snapshot)
    validate_policy(policy)
    validate_rate_card(rate_card)
    required_top_n = policy["demand_top_n"]
    coverage = snapshot["source"]["fetch_metadata"]
    if coverage["requested_top_n"] < required_top_n or coverage["observed_model_count"] < required_top_n:
        raise SchemaError("snapshot does not contain the policy-required top-demand coverage")
    rate_rows = rate_card["rows"]
    policy_models = policy_model_index(policy)
    rows_by_source = {row["source_model_id"]: row for row in snapshot["rows"]}
    result: dict[str, list[dict[str, Any]]] = {key: [] for key in ("added", "changed", "dropped", "blocked", "unchanged")}
    assessed_current_ids: set[str] = set()

    def market_unavailable() -> dict[str, None]:
        return {"demand_rank": None, "completion_volume": None, "benchmark_provider": None, "completion_per_mtok": None}

    def market_from_snapshot_row(row: Mapping[str, Any]) -> dict[str, Any]:
        pricing = row.get("pricing")
        if row.get("pricing_status") != "active_priced" or not isinstance(pricing, dict):
            return {"demand_rank": row["demand"]["rank"], "completion_volume": row["demand"]["completion_volume"], "benchmark_provider": None, "completion_per_mtok": None}
        return {
            "demand_rank": row["demand"]["rank"],
            "completion_volume": row["demand"]["completion_volume"],
            "benchmark_provider": pricing["benchmark_provider"],
            "completion_per_mtok": pricing["completion_per_mtok"],
        }

    def policy_evidence(model: Mapping[str, Any] | None) -> dict[str, Any]:
        if model is None:
            return {"policy_version": policy["policy_version"], "available": False, "license_source_url": None, "license_verification_note": None, "serving_path": None}
        return {
            "policy_version": policy["policy_version"], "available": True,
            "license_source_url": model["license"]["source_url"],
            "license_verification_note": model["license"]["verification_note"],
            "serving_path": model["serving_path"]["reference"],
        }

    # Keep unknown top-demand rows visible to reviewers. They are intentionally
    # blocked rather than guessed into an internal model identity or price.
    for row in snapshot["rows"]:
        if row["source_model_id"] not in policy_models:
            result["blocked"].append(
                {
                    "model_id": row["canonical_model_id"],
                    "source_model_id": row["source_model_id"],
                    "action": "blocked",
                    "market": market_from_snapshot_row(row),
                    "eligibility": {"eligible": False, "reasons": ["no verified policy metadata/mapping for this OpenRouter model"]},
                    "policy_evidence": policy_evidence(None),
                    "reasons": ["no verified policy metadata/mapping for this OpenRouter model"],
                }
            )

    for source_model_id, model in sorted(policy_models.items()):
        canonical_id = model["canonical_model_id"]
        if canonical_id in rate_rows:
            assessed_current_ids.add(canonical_id)
        row = rows_by_source.get(source_model_id)
        if row is None:
            if canonical_id in rate_rows and canonical_id != "default":
                result["dropped"].append(
                    {
                        "model_id": canonical_id,
                        "source_model_id": source_model_id,
                        "action": "dropped",
                        "current_completion_rate": current_completion_rate(rate_rows, canonical_id),
                        "eligibility": {"eligible": False, "reasons": ["model is absent from complete top-100 demand snapshot"]},
                        "market": market_unavailable(),
                        "policy_evidence": policy_evidence(model),
                        "reasons": ["model is absent from complete top-100 demand snapshot"],
                    }
                )
            else:
                result["blocked"].append(
                    {"model_id": canonical_id, "source_model_id": source_model_id, "action": "blocked", "market": market_unavailable(), "eligibility": {"eligible": False, "reasons": ["model is absent from complete top-100 demand snapshot"]}, "policy_evidence": policy_evidence(model), "reasons": ["model is absent from complete top-100 demand snapshot"]}
                )
            continue
        allowed, reasons, market_completion = eligibility(model, row, policy)
        base = {
            "model_id": canonical_id,
            "source_model_id": source_model_id,
            "market": market_from_snapshot_row(row),
            "eligibility": {"eligible": allowed, "reasons": reasons},
            "policy_evidence": policy_evidence(model),
        }
        if not allowed:
            block_reasons = {
                "MLX/GGUF serving path is not verified",
                "commercial license is not verified as permitted",
                "no active priced OpenRouter endpoint is available",
                "cheapest active completion endpoint is free; no paid-market undercut can be computed",
            }
            action = "blocked" if any(reason in block_reasons for reason in reasons) else "dropped" if canonical_id in rate_rows else "blocked"
            base.update({"action": action, "reasons": reasons})
            if canonical_id in rate_rows:
                base["current_completion_rate"] = current_completion_rate(rate_rows, canonical_id)
            result[base["action"]].append(base)
            continue
        try:
            target, proposed_internal, formula_reasons = proposed_completion_price(model, market_completion, policy, rate_card, canonical_id)
        except SchemaError as error:
            base.update({"action": "blocked", "reasons": [str(error)]})
            result["blocked"].append(base)
            continue
        base["proposed_completion_rate"] = {
            "usd_per_mtok": decimal_string(target),
            "rate_card_completion_rate_per_mtok": proposed_internal,
            "formula_reasons": formula_reasons,
        }
        usd_per_million_credits, multiplier_ppm, provider_share_bps, basis_id = rate_card_economics(rate_card, canonical_id)
        base["rate_card_economics"] = {
            "basis_row": basis_id,
            "usd_per_million_credits": decimal_string(usd_per_million_credits),
            "global_multiplier_ppm": decimal_string(multiplier_ppm),
            "provider_share_bps": decimal_string(provider_share_bps),
        }
        current_completion = current_completion_rate(rate_rows, canonical_id)
        if current_completion is None:
            base["action"] = "added"
            result["added"].append(base)
            continue
        base["current_completion_rate"] = current_completion
        if current_completion["rate_card_completion_rate_per_mtok"] == proposed_internal:
            base["action"] = "unchanged"
            result["unchanged"].append(base)
        else:
            base["action"] = "changed"
            result["changed"].append(base)

    for model_id in sorted(rate_rows):
        if model_id == "default" or model_id in assessed_current_ids:
            continue
        result["blocked"].append(
            {
                "model_id": model_id,
                "action": "blocked",
                "current_completion_rate": current_completion_rate(rate_rows, model_id),
                "eligibility": {"eligible": False, "reasons": ["no verified policy metadata/mapping for current rate-card row"]},
                "market": market_unavailable(),
                "policy_evidence": policy_evidence(None),
                "reasons": ["no verified policy metadata/mapping for current rate-card row"],
            }
        )

    summary = {"eligible": len(result["added"]) + len(result["changed"]) + len(result["unchanged"])}
    summary.update({key: len(result[key]) for key in result})
    return {
        "schema_version": PROPOSAL_SCHEMA_VERSION,
        "proposal_type": "openrouter-rate-card-proposal",
        "generated_at": rfc3339(now),
        "snapshot_digest": snapshot["content_digest"],
        "policy_version": policy["policy_version"],
        "rate_card_reference_digest": rate_card_digest(rate_card),
        "summary": summary,
        **result,
    }


def atomic_write_json(path: Path, value: Mapping[str, Any]) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    descriptor, temporary_name = tempfile.mkstemp(prefix=f".{path.name}.", suffix=".tmp", dir=path.parent)
    try:
        with os.fdopen(descriptor, "wb") as handle:
            handle.write(canonical_json(value))
            handle.write(b"\n")
            handle.flush()
            os.fsync(handle.fileno())
        try:
            # link() creates the final name atomically and never replaces an
            # existing artifact, unlike os.replace().  The temporary file and
            # final path are deliberately in the same output directory.
            os.link(temporary_name, path)
        except FileExistsError as error:
            raise EngineError(f"refusing to overwrite existing artifact {path}") from error
        os.unlink(temporary_name)
    except BaseException:
        try:
            os.unlink(temporary_name)
        except FileNotFoundError:
            pass
        raise


def artifact_suffix(value: Mapping[str, Any]) -> str:
    return sha256_prefixed(value).split(":", 1)[1][:16]


def snapshot_filename(now: datetime, snapshot: Mapping[str, Any]) -> str:
    return "openrouter-pricing-snapshot-" + now.astimezone(timezone.utc).strftime("%Y-%m-%dT%H-%M-%SZ-") + artifact_suffix(snapshot) + ".json"


def proposal_filename(now: datetime, proposal: Mapping[str, Any]) -> str:
    return "openrouter-rate-card-proposal-" + now.astimezone(timezone.utc).strftime("%Y-%m-%dT%H-%M-%SZ-") + artifact_suffix(proposal) + ".json"


def fetch_live_snapshot(
    policy: Mapping[str, Any],
    *,
    output_dir: Path,
    top_n: int,
    retries: int,
    timeout_seconds: float,
    client: HTTPClient | None = None,
    now: Callable[[], datetime] = utc_now,
    sleeper: Callable[[float], None] = time.sleep,
    generation_timeout_seconds: float = 900.0,
    clock: Callable[[], float] = time.monotonic,
) -> Path:
    if isinstance(top_n, bool) or not isinstance(top_n, int) or not 1 <= top_n <= 100:
        raise FetchError("top_n must be an integer between 1 and 100")
    if not math.isfinite(timeout_seconds) or not 0 < timeout_seconds <= 60:
        raise FetchError("request timeout must be finite, positive, and no more than 60 seconds")
    if not math.isfinite(generation_timeout_seconds) or not 1 <= generation_timeout_seconds <= 3600:
        raise FetchError("generation timeout must be finite, at least one second, and no more than one hour")
    client = client or UrllibHTTPClient()
    deadline = clock() + generation_timeout_seconds
    rankings = fetch_json(client, RANKINGS_URL, "rankings", retries=retries, timeout_seconds=timeout_seconds, sleeper=sleeper, deadline=deadline, clock=clock)
    catalog = fetch_json(client, MODELS_URL, "models catalog", retries=retries, timeout_seconds=timeout_seconds, sleeper=sleeper, deadline=deadline, clock=clock)
    catalog_index = validate_catalog(catalog)
    ranking_rows = resolve_rankings_to_catalog(normalize_rankings(rankings, top_n), catalog_index)
    endpoints: dict[str, Mapping[str, Any]] = {}
    for demand in ranking_rows:
        model_id = demand["source_model_id"]
        # The documented endpoint is /models/{provider}/{model}/endpoints; the
        # one validated provider/model slash must remain a path separator.
        url = ENDPOINTS_URL.format(model_id=quote(model_id, safe="/"))
        endpoints[model_id] = fetch_json(client, url, f"endpoints {model_id}", retries=retries, timeout_seconds=timeout_seconds, sleeper=sleeper, deadline=deadline, clock=clock)
    fetched_at = now()
    snapshot = build_snapshot(rankings, catalog, endpoints, policy, now=fetched_at, top_n=top_n)
    target = output_dir / snapshot_filename(fetched_at, snapshot)
    atomic_write_json(target, snapshot)
    return target


def command_fetch(args: argparse.Namespace) -> int:
    policy = load_json_file(Path(args.policy), "policy")
    validate_policy(policy)
    result = fetch_live_snapshot(policy, output_dir=Path(args.output_dir), top_n=args.top_n, retries=args.retries, timeout_seconds=args.timeout_seconds, generation_timeout_seconds=args.generation_timeout_seconds)
    print(result)
    return 0


def command_compute(args: argparse.Namespace) -> int:
    snapshot = load_json_file(Path(args.snapshot), "snapshot")
    policy = load_json_file(Path(args.policy), "policy")
    rate_card = load_json_file(Path(args.rate_card), "rate card")
    now = utc_now()
    proposal = build_proposal(snapshot, policy, rate_card, now=now)
    target = Path(args.output_dir) / proposal_filename(now, proposal)
    atomic_write_json(target, proposal)
    print(target)
    return 0


def parser() -> argparse.ArgumentParser:
    result = argparse.ArgumentParser(description=__doc__)
    subcommands = result.add_subparsers(dest="command", required=True)
    fetch = subcommands.add_parser("fetch", help="fetch and validate a live OpenRouter snapshot")
    fetch.add_argument("--policy", default=str(DEFAULT_POLICY_PATH))
    fetch.add_argument("--output-dir", required=True)
    fetch.add_argument("--top-n", type=int, default=100)
    fetch.add_argument("--retries", type=int, default=3)
    fetch.add_argument("--timeout-seconds", type=float, default=20.0)
    fetch.add_argument("--generation-timeout-seconds", type=float, default=900.0)
    fetch.set_defaults(handler=command_fetch)
    compute = subcommands.add_parser("compute", help="compute a proposal from a validated snapshot")
    compute.add_argument("--snapshot", required=True)
    compute.add_argument("--policy", default=str(DEFAULT_POLICY_PATH))
    compute.add_argument("--rate-card", required=True)
    compute.add_argument("--output-dir", required=True)
    compute.set_defaults(handler=command_compute)
    return result


def main(argv: list[str] | None = None) -> int:
    args = parser().parse_args(argv)
    try:
        return args.handler(args)
    except EngineError as error:
        print(f"openrouter pricing engine: {error}", file=sys.stderr)
        return 2


if __name__ == "__main__":
    raise SystemExit(main())
