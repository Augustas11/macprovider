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
import shutil
import socket
import sys
import tempfile
import threading
import time
from dataclasses import dataclass
from datetime import datetime, timedelta, timezone
from decimal import Decimal, InvalidOperation, ROUND_FLOOR, ROUND_HALF_UP
from email.utils import parsedate_to_datetime
from pathlib import Path
from typing import Any, Callable, Iterable, Mapping, Protocol, Sequence
from urllib.parse import quote, urlsplit


RANKINGS_URL = "https://openrouter.ai/api/v1/datasets/rankings-daily"
MODELS_URL = "https://openrouter.ai/api/v1/models"
ENDPOINTS_URL = "https://openrouter.ai/api/v1/models/{model_id}/endpoints"
PRODUCTION_CATALOG_PATH = Path(__file__).resolve().parents[1] / "phase3-binary" / "catalog" / "autotune" / "autotune-candidates.json"
RECOMMENDABLE_CATALOG_PATH = PRODUCTION_CATALOG_PATH
SNAPSHOT_SCHEMA_VERSION = 6
LEGACY_SNAPSHOT_SCHEMA_VERSION = 5
PROPOSAL_SCHEMA_VERSION = 2
TOOL_VERSION = "openrouter-pricing-engine-v1"
DEFAULT_POLICY_PATH = Path(__file__).with_name("openrouter_pricing_policy.json")
CURRENT_POLICY_KEYS = frozenset({
    "policy_version", "demand_top_n", "undercut_fraction",
    "cache_hit_fraction", "min_endpoint_request_count_30m", "models",
})
LEGACY_POLICY_KEYS = frozenset({
    "policy_version", "demand_top_n", "broad_fleet_undercut_fraction",
    "coding_minimum_undercut_fraction", "coding_premium_fraction", "models",
})
MODEL_ID_RE = re.compile(r"^[A-Za-z0-9._~:-]+/[A-Za-z0-9._~:-]+$")
# OpenRouter's explicit provider variants (for example `model:free`) are
# valid snapshot identities even when policy leaves them unmapped/blocked.
CANONICAL_ID_RE = re.compile(r"^[a-z0-9][a-z0-9._/:-]*$")
KNOWN_MODEL_NAMESPACES = frozenset({"mlx-community", "openai", "google", "meta-llama", "nvidia", "qwen"})
MAX_RESPONSE_BYTES = 5 * 1024 * 1024
RANKING_TOP_LEVEL_KEYS = frozenset({"data", "meta"})
RANKING_ROW_KEYS = frozenset({"date", "model_permaslug", "total_tokens"})
RANKING_META_KEYS = frozenset({"as_of", "end_date", "start_date", "version"})
CATALOG_ROW_KEYS = frozenset({"alias_target", "architecture", "benchmarks", "canonical_slug", "context_length", "created", "default_parameters", "description", "expiration_date", "hugging_face_id", "id", "knowledge_cutoff", "links", "name", "per_request_limits", "pricing", "reasoning", "supported_parameters", "supported_voices", "top_provider"})
CATALOG_TOP_LEVEL_KEYS = frozenset({"data", "links", "total_count"})
ENDPOINT_DATA_KEYS = frozenset({"architecture", "created", "description", "endpoints", "id", "name"})
ENDPOINT_ROW_KEYS = frozenset({"completion_tokens_last_30d", "context_length", "latency_last_30m", "max_completion_tokens", "max_prompt_tokens", "model_id", "model_name", "name", "perf_last_30m_by_workload", "pricing", "provider_name", "quantization", "status", "supported_parameters", "supports_implicit_caching", "supports_tool_choice", "supports_voice_cloning", "tag", "throughput_last_30m", "uptime_last_1d", "uptime_last_30d", "uptime_last_30m", "uptime_last_5m"})
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
    """Small production adapter; tests provide an in-memory HTTP client.

    ``OPENROUTER_API_KEY`` is optional so the tool can use an operator's
    configured OpenRouter credential without ever placing that credential in
    command-line arguments, artifacts, or error messages.
    """

    def __init__(self, resolver: Callable[[float], list[str]] | None = None, api_key: str | None = None):
        self._resolver = resolver or resolve_openrouter_addresses
        self._api_key = os.environ.get("OPENROUTER_API_KEY") if api_key is None else api_key
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
            headers = {"Accept": "application/json", "User-Agent": TOOL_VERSION}
            if self._api_key:
                headers["Authorization"] = f"Bearer {self._api_key}"
            connection.request("GET", target, headers=headers)
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
        raise SchemaError(f"{field} must be OpenRouter daily ranking date YYYY-MM-DD")
    try:
        return datetime.strptime(value, "%Y-%m-%d")
    except ValueError as error:
        raise SchemaError(f"{field} must be OpenRouter daily ranking date YYYY-MM-DD") from error


def is_free_variant(model_id: Any) -> bool:
    return isinstance(model_id, str) and model_id.endswith(":free")


def normalize_model_key(model: str) -> str:
    key = model.strip().lower()
    namespace = ""
    slash = key.find("/")
    if slash >= 0:
        namespace = key[:slash]
        if namespace in KNOWN_MODEL_NAMESPACES:
            key = key[slash + 1:]
    for suffix in ("-free", "-mxfp4-q8", "-4bit", "-8bit"):
        if key.endswith(suffix):
            key = key[: -len(suffix)]

    def served_alias(canonical_vendor: str) -> bool:
        return namespace in {"", "mlx-community", canonical_vendor}

    if served_alias("meta-llama") and key.startswith("llama-"):
        return "meta-llama/" + key
    if served_alias("meta-llama") and key.startswith("meta-llama-"):
        return "meta-llama/" + key[len("meta-"):]
    if served_alias("nvidia") and key.startswith("nvidia-nemotron-"):
        return key[len("nvidia-"):]
    if served_alias("openai") and key.startswith("gpt-oss-"):
        return "openai/" + key
    return key


def rate_row_key(rate_rows: Mapping[str, Any], model_id: str, *, allow_normalized: bool = True) -> str | None:
    if model_id in rate_rows:
        return model_id
    if allow_normalized:
        normalized = normalize_model_key(model_id)
        if normalized != "default" and normalized in rate_rows:
            return normalized
    return None


def canonical_json(value: Any) -> bytes:
    return json.dumps(value, sort_keys=True, separators=(",", ":"), ensure_ascii=False).encode("utf-8")


def sha256_prefixed(value: Any) -> str:
    return "sha256:" + hashlib.sha256(canonical_json(value)).hexdigest()


SCHEMA_CONTRACT_FINGERPRINT = sha256_prefixed(
    {
        "rankings_top_level_keys": sorted(RANKING_TOP_LEVEL_KEYS),
        "rankings_row_keys": sorted(RANKING_ROW_KEYS),
        "rankings_meta_keys": sorted(RANKING_META_KEYS),
        "catalog_row_keys": sorted(CATALOG_ROW_KEYS),
        "catalog_top_level_keys": sorted(CATALOG_TOP_LEVEL_KEYS),
        "endpoint_data_keys": sorted(ENDPOINT_DATA_KEYS),
        "endpoint_row_keys": sorted(ENDPOINT_ROW_KEYS),
        "endpoint_pricing_keys": sorted(ENDPOINT_PRICING_KEYS),
    }
)
LEGACY_SCHEMA_CONTRACT_FINGERPRINT = "sha256:606dd02557e635ea7f0ab640fda22a9352f2c0051f9deef28378fc983f3ed29c"


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


def parse_nonnegative_integer(value: Any, field: str) -> int:
    if isinstance(value, bool) or not isinstance(value, int) or value < 0:
        raise SchemaError(f"{field} must be a non-negative integer")
    return value


def require_allowed_keys(value: Mapping[str, Any], allowed: frozenset[str], location: str) -> None:
    unexpected = sorted(set(value) - allowed)
    if unexpected:
        raise SchemaError(f"{location}: unexpected fields {unexpected}")


def rankings_metadata(document: Mapping[str, Any]) -> Mapping[str, Any]:
    require_allowed_keys(document, RANKING_TOP_LEVEL_KEYS, "rankings response")
    metadata = document.get("meta")
    if not isinstance(metadata, dict):
        raise SchemaError("rankings response: meta must be an object")
    require_allowed_keys(metadata, RANKING_META_KEYS, "rankings response: meta")
    if set(metadata) != RANKING_META_KEYS:
        raise SchemaError("rankings response: meta has missing fields")
    parse_rfc3339_utc(metadata["as_of"], "rankings response: meta.as_of")
    start = parse_ranking_date(metadata["start_date"], "rankings response: meta.start_date")
    end = parse_ranking_date(metadata["end_date"], "rankings response: meta.end_date")
    if start > end or metadata["version"] != "v1":
        raise SchemaError("rankings response: meta has invalid date range or version")
    return metadata


def normalize_rankings(document: Mapping[str, Any], top_n: int) -> list[dict[str, Any]]:
    if isinstance(top_n, bool) or not isinstance(top_n, int) or not 1 <= top_n <= 50:
        raise SchemaError("requested demand cohort must be an integer from 1 through 50")
    metadata = rankings_metadata(document)
    rows = required_list(document, "data", "rankings response")
    totals: dict[str, int] = {}
    dates: dict[str, str] = {}
    seen_daily_models: set[tuple[str, str]] = set()
    for index, row in enumerate(rows):
        if not isinstance(row, dict):
            raise SchemaError(f"rankings response: data[{index}] must be an object")
        require_allowed_keys(row, RANKING_ROW_KEYS, f"rankings response: data[{index}]")
        total_tokens = row.get("total_tokens")
        if not isinstance(total_tokens, str) or not total_tokens.isdigit() or int(total_tokens) <= 0:
            raise SchemaError(f"rankings response: data[{index}].total_tokens must be a positive integer string")
        model_id = row.get("model_permaslug")
        date = row.get("date")
        parsed_date = parse_ranking_date(date, f"rankings response: data[{index}].date")
        if not parse_ranking_date(metadata["start_date"], "rankings response: meta.start_date") <= parsed_date <= parse_ranking_date(metadata["end_date"], "rankings response: meta.end_date"):
            raise SchemaError(f"rankings response: data[{index}].date is outside metadata window")
        if model_id == "other":
            continue
        if not isinstance(model_id, str) or not model_id.strip():
            raise SchemaError(f"rankings response: data[{index}].model_permaslug must be non-empty")
        if not MODEL_ID_RE.fullmatch(model_id):
            raise SchemaError(f"rankings response: data[{index}].model_permaslug has unsafe shape")
        daily_key = (date, model_id)
        if daily_key in seen_daily_models:
            raise SchemaError(f"rankings response: duplicate daily model row {daily_key!r}")
        seen_daily_models.add(daily_key)
        totals[model_id] = totals.get(model_id, 0) + int(total_tokens)
        dates[model_id] = max(date, dates.get(model_id, date))
    ordered = sorted(totals, key=lambda item: (-totals[item], item))[:top_n]
    if len(ordered) != top_n:
        raise SchemaError("rankings response: insufficient documented daily-ranking models for requested cohort")
    return [
        {
            "source_model_id": model_id,
            "rank": rank,
            "total_token_volume": str(totals[model_id]),
            "ranking_date": dates[model_id],
        }
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
    *,
    skipped_sink: list[dict[str, Any]] | None = None,
) -> list[dict[str, Any]]:
    """Resolve ranking permaslugs to the catalog ID accepted by endpoints API.

    OpenRouter rankings can retain a dated permaslug after the catalog exposes
    the same model under a current ID. If the catalog no longer lists a dated
    ranking ID, the endpoint response for that exact dated ID may authoritatively
    return its current ID. When a canonical slug maps to several catalog IDs,
    the endpoint response for the exact ranking permaslug may select one only
    if its returned ID is exactly one of those catalog candidates. All other
    ambiguity is a coverage failure, never a guess.

    A ranked identity that is itself a ``:free`` variant and cannot be pinned to
    a unique paid catalog row is dropped from the returned cohort (a ``:free``
    endpoint has no paid price and no earning potential); each drop is recorded
    in ``skipped_sink`` when supplied. The skip decision depends only on the
    ranking permaslug and catalog, so it is identical whether or not
    ``endpoint_documents`` is provided, keeping the two resolution phases and the
    endpoint-fetch cohort in lockstep. Genuine (non-free) ambiguity and schema
    errors still fail closed.
    """
    canonical_index: dict[str, list[str]] = {}
    for model_id, catalog_row in catalog.items():
        canonical_slug = catalog_row["canonical_slug"]
        canonical_index.setdefault(canonical_slug, []).append(model_id)
    resolved: list[dict[str, Any]] = []
    for demand in rankings:
        ranking_slug = demand["source_model_id"]
        if ranking_slug in catalog and not is_free_variant(ranking_slug):
            catalog_id = ranking_slug
            identity_resolution = "catalog"
        else:
            candidates = canonical_index.get(ranking_slug, [])
            if len(candidates) == 1 and not is_free_variant(candidates[0]):
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
                else:
                    if is_free_variant(ranking_slug):
                        # A :free ranked identity with no unique paid catalog row
                        # cannot be priced (its endpoint is $0) and has no earning
                        # potential. Drop it from the cohort with a logged reason
                        # instead of aborting the whole fetch. This is decided
                        # from ranking_slug + catalog only, so both resolution
                        # passes drop the same rows and the endpoint-fetch set
                        # stays exactly aligned.
                        if skipped_sink is not None:
                            skipped_sink.append(
                                {
                                    "ranking_model_permaslug": ranking_slug,
                                    "reason": "dropped_free_variant",
                                    "rank": demand["rank"],
                                }
                            )
                        continue
                    if endpoint_documents is None:
                        # Fetch the ranking permaslug itself first.  It is a
                        # temporary request identity, not a selected catalog
                        # row; build_snapshot validates the response before
                        # accepting an alias or a candidate.
                        catalog_id = ranking_slug
                        identity_resolution = (
                            "endpoint_alias_pending" if not candidates else "endpoint_candidate_pending"
                        )
                    else:
                        endpoint_document = endpoint_documents.get(ranking_slug)
                        if endpoint_document is None:
                            raise SchemaError(f"partial pull: endpoints response missing for ranked model {ranking_slug!r}")
                        endpoint_id = endpoint_response_model_id(endpoint_document, ranking_slug)
                        if not candidates:
                            if is_free_variant(ranking_slug) or is_free_variant(endpoint_id):
                                raise SchemaError(f"endpoints response for ranked model {ranking_slug!r} resolves a free variant")
                            catalog_id = endpoint_id
                            identity_resolution = "endpoint_alias_fallback"
                        else:
                            matching_candidates = [
                                candidate for candidate in candidates
                                if candidate == endpoint_id and not is_free_variant(candidate) and not is_free_variant(ranking_slug)
                            ]
                            if len(matching_candidates) != 1:
                                raise SchemaError(
                                    f"endpoints response for ranked model {ranking_slug!r} does not uniquely identify a catalog candidate"
                                )
                            catalog_id = matching_candidates[0]
                            identity_resolution = "endpoint_confirmed_catalog_candidate"
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


def endpoint_set_is_empty(document: Mapping[str, Any], requested_model_id: str) -> bool:
    """Validate the response envelope and report an explicit empty provider set."""
    endpoint_response_model_id(document, requested_model_id)
    data = document["data"]
    endpoints = data.get("endpoints")
    if not isinstance(endpoints, list):
        raise SchemaError(f"endpoints response for {requested_model_id}: endpoints must be an array")
    return not endpoints


def weighted_median(
    priced: list[tuple[Decimal, Decimal, str, int, str]],
    value_index: int,
) -> tuple[Decimal, tuple[Decimal, Decimal, str, int, str]]:
    ordered = sorted(priced, key=lambda item: item[value_index])
    total = sum(item[3] for item in ordered)
    cumulative = 0
    for item in ordered:
        cumulative += item[3]
        if cumulative * 2 >= total:
            return item[value_index], item
    return ordered[-1][value_index], ordered[-1]


def endpoint_request_activity(endpoint: Mapping[str, Any], model_id: str, index: int) -> int | None:
    """Recent per-endpoint TEXT request activity from ``perf_last_30m_by_workload``.

    OpenRouter removed the per-endpoint 30-day token volume
    (``completion_tokens_last_30d``). The surviving per-endpoint activity signal
    is ``perf_last_30m_by_workload.text_generation.request_count`` -- a 30-minute
    request count. We read ONLY the ``text_generation`` workload: an endpoint's
    non-text traffic (tool_use, embeddings, etc.) must not qualify it for the text
    price. Returns ``None`` when no text ``request_count`` is reported (the
    endpoint is treated as not text-serving and excluded); malformed values fail
    closed. This is an ELIGIBILITY signal only -- it is never used as a price
    weight (see ``endpoint_price_median``).
    """
    perf = endpoint.get("perf_last_30m_by_workload")
    if perf is None:
        return None
    if not isinstance(perf, dict):
        raise SchemaError(f"endpoints response for {model_id}: endpoints[{index}].perf_last_30m_by_workload must be an object")
    stats = perf.get("text_generation")
    if stats is None:
        return None
    if not isinstance(stats, dict):
        raise SchemaError(f"endpoints response for {model_id}: endpoints[{index}].perf_last_30m_by_workload['text_generation'] must be an object")
    count = stats.get("request_count")
    if count is None:
        return None
    if isinstance(count, bool) or not isinstance(count, int) or count < 0:
        raise SchemaError(f"endpoints response for {model_id}: endpoints[{index}].perf_last_30m_by_workload['text_generation'].request_count is invalid")
    return count


def endpoint_price_median(
    priced: list[tuple[Decimal, Decimal, str, int, str]],
    value_index: int,
) -> tuple[Decimal, tuple[Decimal, Decimal, str, int, str]]:
    """UNWEIGHTED median price over the eligible (active, paid) endpoints.

    Each eligible endpoint counts once, so no endpoint can move the pegged price
    by inflating its API-reported ``request_count`` (that value gates eligibility,
    it is not a weight). The deterministic LOWER median selects a real endpoint's
    quote (never an average) -- conservative for a peg we then undercut -- tie
    broken by provider then model id."""
    ordered = sorted(priced, key=lambda item: (item[value_index], item[2], item[4]))
    chosen = ordered[(len(ordered) - 1) // 2]
    return chosen[value_index], chosen


def cheapest_endpoint_pricing(document: Mapping[str, Any], model_id: str, *, min_request_count_30m: int = 1) -> dict[str, Any] | None:
    require_allowed_keys(document, frozenset({"data"}), f"endpoints response for {model_id}")
    data = document.get("data")
    if not isinstance(data, dict):
        raise SchemaError(f"endpoints response for {model_id}: data must be an object")
    require_allowed_keys(data, ENDPOINT_DATA_KEYS, f"endpoints response for {model_id}: data")
    if data.get("id") != model_id:
        raise SchemaError(f"endpoints response for {model_id}: response id mismatch")
    if is_free_variant(model_id) or is_free_variant(data.get("id")):
        return None
    endpoints = data.get("endpoints")
    if not isinstance(endpoints, list):
        raise SchemaError(f"endpoints response for {model_id}: endpoints must be an array")
    if not endpoints:
        return None
    priced: list[tuple[Decimal, Decimal, str, int, str]] = []
    for index, endpoint in enumerate(endpoints):
        if not isinstance(endpoint, dict):
            raise SchemaError(f"endpoints response for {model_id}: endpoints[{index}] must be an object")
        require_allowed_keys(endpoint, ENDPOINT_ROW_KEYS, f"endpoints response for {model_id}: endpoints[{index}]")
        status = endpoint.get("status")
        if isinstance(status, bool) or not isinstance(status, int):
            raise SchemaError(f"endpoints response for {model_id}: endpoints[{index}].status must be an integer")
        provider = endpoint.get("provider_name")
        pricing = endpoint.get("pricing")
        if not isinstance(provider, str) or not provider.strip() or not isinstance(pricing, dict):
            raise SchemaError(f"endpoints response for {model_id}: endpoint[{index}] missing provider/pricing")
        require_allowed_keys(pricing, ENDPOINT_PRICING_KEYS, f"endpoints response for {model_id}: endpoints[{index}].pricing")
        prompt = parse_decimal(pricing.get("prompt"), f"endpoints response for {model_id}: prompt")
        completion = parse_decimal(pricing.get("completion"), f"endpoints response for {model_id}: completion")
        if is_free_variant(endpoint.get("model_id")) or is_free_variant(endpoint.get("tag")):
            continue
        endpoint_model_id = endpoint.get("model_id")
        if endpoint_model_id is None:
            endpoint_model_id = model_id
        if not isinstance(endpoint_model_id, str) or not MODEL_ID_RE.fullmatch(endpoint_model_id):
            raise SchemaError(f"endpoints response for {model_id}: endpoints[{index}].model_id is invalid")
        activity = endpoint_request_activity(endpoint, model_id, index)
        if activity is None:
            continue
        if status != 0 or prompt == 0 or completion == 0 or activity < min_request_count_30m:
            continue
        priced.append((completion, prompt, provider, activity, endpoint_model_id))
    if not priced:
        return None
    completion, completion_endpoint = endpoint_price_median(priced, 0)
    prompt, prompt_endpoint = endpoint_price_median(priced, 1)
    _, _, provider, selected_activity, _ = completion_endpoint
    _, _, prompt_provider, prompt_activity, _ = prompt_endpoint
    liquidity_candidates = [
        {
            "endpoint_status": status,
            "endpoint_model_id": candidate_model_id,
            "provider_name": candidate_provider,
            "prompt_usd_per_mtok": decimal_string(candidate_prompt * Decimal("1000000")),
            "completion_usd_per_mtok": decimal_string(candidate_completion * Decimal("1000000")),
            "request_count_last_30m": candidate_activity,
        }
        for status, candidate_model_id, candidate_provider, candidate_prompt, candidate_completion, candidate_activity in (
            (0, item[4], item[2], item[1], item[0], item[3]) for item in priced
        )
    ]
    return {
        "input_per_token": decimal_string(prompt),
        "completion_per_token": decimal_string(completion),
        "input_per_mtok": decimal_string(prompt * Decimal("1000000")),
        "completion_per_mtok": decimal_string(completion * Decimal("1000000")),
        "currency": "USD",
        "benchmark_provider": provider,
        "liquidity_filter": {
            "endpoint_status": 0,
            "paid_prices": True,
            "liquidity_signal": "openrouter_request_count_last_30m",
            "minimum_request_count_last_30m": min_request_count_30m,
            "request_count_last_30m": selected_activity,
            "price_median_method": "unweighted_over_active_endpoints",
            "selected_prompt_provider": prompt_provider,
            "selected_prompt_request_count_last_30m": prompt_activity,
            "eligible_endpoint_liquidity": liquidity_candidates,
        },
    }


def snapshot_digest_payload(snapshot: Mapping[str, Any]) -> dict[str, Any]:
    payload = copy.deepcopy(dict(snapshot))
    payload.pop("content_digest", None)
    payload.pop("fetched_at", None)
    return payload


def validate_snapshot(snapshot: Mapping[str, Any]) -> None:
    schema_version = snapshot.get("schema_version")
    if schema_version not in {SNAPSHOT_SCHEMA_VERSION, LEGACY_SNAPSHOT_SCHEMA_VERSION} or snapshot.get("snapshot_type") != "openrouter-pricing":
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
    expected_fingerprint = SCHEMA_CONTRACT_FINGERPRINT if schema_version == SNAPSHOT_SCHEMA_VERSION else LEGACY_SCHEMA_CONTRACT_FINGERPRINT
    if source["observed_schema_version_or_fingerprint"] != expected_fingerprint or not isinstance(source["generator_version"], str):
        raise SchemaError("snapshot source schema/generator provenance is invalid")
    fetch_metadata = source["fetch_metadata"]
    required_fetch_metadata = {"successful_source_count", "observed_model_count", "requested_top_n", "demand_window_days", "ranking_window_start_date", "ranking_window_end_date", "demand_metric"}
    if schema_version == SNAPSHOT_SCHEMA_VERSION:
        # Current snapshots record every :free row dropped from the requested
        # top-N so the observed shortfall is auditable, not merely trusted.
        required_fetch_metadata = required_fetch_metadata | {"skipped_free_ranked_models"}
    if not isinstance(fetch_metadata, dict) or set(fetch_metadata) != required_fetch_metadata:
        raise SchemaError("snapshot fetch_metadata has missing or unexpected fields")
    if schema_version == SNAPSHOT_SCHEMA_VERSION:
        skipped_free = fetch_metadata["skipped_free_ranked_models"]
        if not isinstance(skipped_free, list):
            raise SchemaError("snapshot fetch_metadata.skipped_free_ranked_models must be an array")
        for entry in skipped_free:
            if not isinstance(entry, dict) or set(entry) != {"ranking_model_permaslug", "reason", "rank"}:
                raise SchemaError("snapshot fetch_metadata.skipped_free_ranked_models entry has invalid fields")
            if entry["reason"] != "dropped_free_variant" or not is_free_variant(entry["ranking_model_permaslug"]):
                raise SchemaError("snapshot fetch_metadata.skipped_free_ranked_models entry is not a dropped free variant")
            if isinstance(entry["rank"], bool) or not isinstance(entry["rank"], int) or entry["rank"] < 1:
                raise SchemaError("snapshot fetch_metadata.skipped_free_ranked_models entry has an invalid rank")
        # Completeness: every requested top-N row is either observed or a recorded
        # free drop. This is what makes the market-peg coverage gate auditable --
        # a truncated snapshot cannot pass by claiming an unexplained shortfall.
        if fetch_metadata["observed_model_count"] + len(skipped_free) != fetch_metadata["requested_top_n"]:
            raise SchemaError("snapshot fetch_metadata: observed_model_count + skipped_free_ranked_models must equal requested_top_n")
    for key in ("successful_source_count", "observed_model_count", "requested_top_n", "demand_window_days"):
        if isinstance(fetch_metadata[key], bool) or not isinstance(fetch_metadata[key], int) or fetch_metadata[key] < 1:
            raise SchemaError(f"snapshot fetch_metadata.{key} must be a positive integer")
    if fetch_metadata["requested_top_n"] > 50 or fetch_metadata["demand_window_days"] > 31 or fetch_metadata["demand_metric"] != "aggregated_daily_total_tokens":
        raise SchemaError("snapshot fetch_metadata has invalid demand cohort metadata")
    start = parse_ranking_date(fetch_metadata["ranking_window_start_date"], "snapshot fetch_metadata.ranking_window_start_date")
    end = parse_ranking_date(fetch_metadata["ranking_window_end_date"], "snapshot fetch_metadata.ranking_window_end_date")
    if start > end or (end - start).days + 1 != fetch_metadata["demand_window_days"]:
        raise SchemaError("snapshot fetch_metadata has invalid ranking window")
    if fetch_metadata["observed_model_count"] != len(rows):
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
        expected_demand_keys = {"source_model_id", "rank", "total_token_volume", "ranking_date", "ranking_model_permaslug"}
        if not isinstance(demand, dict) or set(demand) != expected_demand_keys:
            raise SchemaError(f"snapshot.rows[{index}] has invalid demand")
        if demand["source_model_id"] != source_id or not isinstance(demand.get("rank"), int) or demand["rank"] < 1 or not isinstance(demand.get("total_token_volume"), str) or not demand["total_token_volume"].isdigit() or int(demand["total_token_volume"]) <= 0 or not isinstance(demand.get("ranking_model_permaslug"), str) or not MODEL_ID_RE.fullmatch(demand["ranking_model_permaslug"]):
            raise SchemaError(f"snapshot.rows[{index}] has invalid demand")
        parse_ranking_date(demand.get("ranking_date"), f"snapshot.rows[{index}].demand.ranking_date")
        if demand["ranking_model_permaslug"] in seen_ranking_slugs:
            raise SchemaError(f"snapshot has duplicate ranking model permaslug {demand['ranking_model_permaslug']!r}")
        seen_ranking_slugs.add(demand["ranking_model_permaslug"])
        ranks.add(demand["rank"])
        if pricing_status not in {"active_priced", "no_active_priced_endpoint", "no_provider_endpoints"}:
            raise SchemaError(f"snapshot.rows[{index}] has invalid pricing status")
        if pricing_status in {"no_active_priced_endpoint", "no_provider_endpoints"}:
            if pricing is not None:
                raise SchemaError(f"snapshot.rows[{index}] unavailable pricing must be null")
        elif pricing is not None:
            expected_pricing_keys = {"input_per_token", "completion_per_token", "input_per_mtok", "completion_per_mtok", "currency", "benchmark_provider", "liquidity_filter"}
            if schema_version == LEGACY_SNAPSHOT_SCHEMA_VERSION:
                expected_pricing_keys.discard("liquidity_filter")
            if not isinstance(pricing, dict) or set(pricing) != expected_pricing_keys:
                raise SchemaError(f"snapshot.rows[{index}] has invalid pricing")
        expected_pricing_keys = {"input_per_token", "completion_per_token", "input_per_mtok", "completion_per_mtok", "currency", "benchmark_provider", "liquidity_filter"}
        if schema_version == LEGACY_SNAPSHOT_SCHEMA_VERSION:
            expected_pricing_keys.discard("liquidity_filter")
        if pricing_status == "active_priced" and (not isinstance(pricing, dict) or set(pricing) != expected_pricing_keys):
            raise SchemaError(f"snapshot.rows[{index}] has invalid pricing")
        if pricing_status == "active_priced" and (pricing["currency"] != "USD" or not isinstance(pricing["benchmark_provider"], str) or not pricing["benchmark_provider"]):
            raise SchemaError(f"snapshot.rows[{index}] has invalid pricing provenance")
        if pricing_status == "active_priced" and schema_version != LEGACY_SNAPSHOT_SCHEMA_VERSION and (
            is_free_variant(source_id) or is_free_variant(row["demand"]["ranking_model_permaslug"])
        ):
            raise SchemaError(f"snapshot.rows[{index}] active pricing cannot derive from a free variant")
        if pricing_status == "active_priced" and schema_version != LEGACY_SNAPSHOT_SCHEMA_VERSION:
            liquidity = pricing.get("liquidity_filter")
            required_liquidity = {"endpoint_status", "paid_prices", "liquidity_signal", "minimum_request_count_last_30m", "request_count_last_30m", "price_median_method", "selected_prompt_provider", "selected_prompt_request_count_last_30m", "eligible_endpoint_liquidity"}
            if not isinstance(liquidity, dict) or set(liquidity) != required_liquidity:
                raise SchemaError(f"snapshot.rows[{index}] has invalid liquidity filter")
            if liquidity["endpoint_status"] != 0 or liquidity["paid_prices"] is not True or liquidity["price_median_method"] != "unweighted_over_active_endpoints" or liquidity["liquidity_signal"] != "openrouter_request_count_last_30m":
                raise SchemaError(f"snapshot.rows[{index}] liquidity filter does not match the policy thresholds")
            try:
                selected_prompt = Decimal(pricing["input_per_mtok"])
                selected_completion = Decimal(pricing["completion_per_mtok"])
                candidates = liquidity.get("eligible_endpoint_liquidity")
                if not isinstance(candidates, list) or not candidates:
                    raise SchemaError(f"snapshot.rows[{index}].liquidity_filter.eligible_endpoint_liquidity must be a non-empty array")
                required_candidate = {"endpoint_status", "endpoint_model_id", "provider_name", "prompt_usd_per_mtok", "completion_usd_per_mtok", "request_count_last_30m"}
                weighted_candidates: list[tuple[Decimal, Decimal, str, int, str]] = []
                for candidate_index, candidate in enumerate(candidates):
                    if not isinstance(candidate, dict) or set(candidate) != required_candidate:
                        raise SchemaError(f"snapshot.rows[{index}].liquidity_filter.eligible_endpoint_liquidity[{candidate_index}] has invalid fields")
                    if candidate["endpoint_status"] != 0 or not isinstance(candidate["provider_name"], str) or not candidate["provider_name"]:
                        raise SchemaError(f"snapshot.rows[{index}].liquidity_filter.eligible_endpoint_liquidity[{candidate_index}] is invalid")
                    endpoint_model_id = candidate["endpoint_model_id"]
                    if not isinstance(endpoint_model_id, str) or not MODEL_ID_RE.fullmatch(endpoint_model_id) or is_free_variant(endpoint_model_id):
                        raise SchemaError(f"snapshot.rows[{index}].liquidity_filter.eligible_endpoint_liquidity[{candidate_index}].endpoint_model_id is invalid")
                    for field in ("prompt_usd_per_mtok", "completion_usd_per_mtok"):
                        try:
                            if Decimal(candidate[field]) <= 0:
                                raise SchemaError
                        except (InvalidOperation, ValueError, TypeError, SchemaError):
                            raise SchemaError(f"snapshot.rows[{index}].liquidity_filter.eligible_endpoint_liquidity[{candidate_index}].{field} is invalid")
                    candidate_activity = candidate.get("request_count_last_30m")
                    if isinstance(candidate_activity, bool) or not isinstance(candidate_activity, int) or candidate_activity < 0:
                        raise SchemaError(f"snapshot.rows[{index}].liquidity_filter.eligible_endpoint_liquidity[{candidate_index}].request_count_last_30m is invalid")
                    weighted_candidates.append(
                        (
                            Decimal(candidate["completion_usd_per_mtok"]),
                            Decimal(candidate["prompt_usd_per_mtok"]),
                            candidate["provider_name"],
                            candidate_activity,
                            endpoint_model_id,
                        )
                    )
                selected_activity = parse_nonnegative_integer(liquidity["request_count_last_30m"], f"snapshot.rows[{index}].liquidity_filter.request_count_last_30m")
                minimum_activity = parse_nonnegative_integer(liquidity["minimum_request_count_last_30m"], f"snapshot.rows[{index}].liquidity_filter.minimum_request_count_last_30m")
                selected_prompt_activity = parse_nonnegative_integer(liquidity["selected_prompt_request_count_last_30m"], f"snapshot.rows[{index}].liquidity_filter.selected_prompt_request_count_last_30m")
            except (InvalidOperation, ValueError) as error:
                raise SchemaError(f"snapshot.rows[{index}] liquidity/pricing values are invalid") from error
            if not isinstance(liquidity["selected_prompt_provider"], str) or not liquidity["selected_prompt_provider"] or selected_prompt <= 0 or selected_completion <= 0 or minimum_activity < 1 or selected_activity < minimum_activity or selected_prompt_activity < minimum_activity:
                raise SchemaError(f"snapshot.rows[{index}] liquidity-selected endpoint is not paid and active")
            if any(candidate[3] < minimum_activity for candidate in weighted_candidates):
                raise SchemaError(f"snapshot.rows[{index}] liquidity filter includes an inactive endpoint")
            expected_completion, completion_endpoint = endpoint_price_median(weighted_candidates, 0)
            expected_prompt, prompt_endpoint = endpoint_price_median(weighted_candidates, 1)
            if selected_completion != expected_completion or selected_prompt != expected_prompt:
                raise SchemaError(f"snapshot.rows[{index}] liquidity-filtered median price is invalid")
            if pricing["benchmark_provider"] != completion_endpoint[2] or selected_activity != completion_endpoint[3]:
                raise SchemaError(f"snapshot.rows[{index}] liquidity-filtered completion endpoint is invalid")
            if liquidity["selected_prompt_provider"] != prompt_endpoint[2] or selected_prompt_activity != prompt_endpoint[3]:
                raise SchemaError(f"snapshot.rows[{index}] liquidity-filtered prompt endpoint is invalid")
        if not isinstance(row.get("source_metadata"), dict) or set(row["source_metadata"]) != {"ranking_model_permaslug", "catalog_canonical_slug", "catalog_name", "identity_resolution", "endpoint_set_confirmation"}:
            raise SchemaError(f"snapshot.rows[{index}] has invalid source metadata")
        source_metadata = row["source_metadata"]
        if not isinstance(source_metadata["ranking_model_permaslug"], str) or not MODEL_ID_RE.fullmatch(source_metadata["ranking_model_permaslug"]):
            raise SchemaError(f"snapshot.rows[{index}] has invalid ranking provenance")
        if source_metadata["catalog_canonical_slug"] is not None and not isinstance(source_metadata["catalog_canonical_slug"], str):
            raise SchemaError(f"snapshot.rows[{index}] has invalid catalog provenance")
        if source_metadata["catalog_name"] is not None and not isinstance(source_metadata["catalog_name"], str):
            raise SchemaError(f"snapshot.rows[{index}] has invalid catalog provenance")
        if source_metadata["identity_resolution"] not in {
            "catalog",
            "catalog_paid_variant",
            "endpoint_alias_fallback",
            "endpoint_confirmed_catalog_candidate",
        }:
            raise SchemaError(f"snapshot.rows[{index}] has invalid identity resolution")
        confirmation = source_metadata["endpoint_set_confirmation"]
        if confirmation not in {"not_required", "confirmed_empty_second_fetch", "recovered_nonempty_on_confirmation"}:
            raise SchemaError(f"snapshot.rows[{index}] has invalid endpoint-set confirmation")
        if pricing_status == "no_provider_endpoints" and confirmation != "confirmed_empty_second_fetch":
            raise SchemaError(f"snapshot.rows[{index}] empty provider set lacks bounded confirmation")
        if confirmation == "confirmed_empty_second_fetch" and pricing_status != "no_provider_endpoints":
            raise SchemaError(f"snapshot.rows[{index}] confirmed empty provider set has inconsistent status")
        if confirmation == "recovered_nonempty_on_confirmation" and pricing_status == "no_provider_endpoints":
            raise SchemaError(f"snapshot.rows[{index}] recovered provider set has inconsistent status")
        if pricing_status == "active_priced":
            parse_decimal(pricing.get("input_per_mtok"), f"snapshot.rows[{index}].pricing.input_per_mtok")
            parse_decimal(pricing.get("completion_per_mtok"), f"snapshot.rows[{index}].pricing.completion_per_mtok")
    if ranks != set(range(1, len(rows) + 1)):
        raise SchemaError("snapshot ranks must be contiguous from 1 through row count")
    confirmation_count = sum(
        row["source_metadata"]["endpoint_set_confirmation"] != "not_required" for row in rows
    )
    if fetch_metadata["successful_source_count"] != 2 + len(rows) + confirmation_count:
        raise SchemaError("snapshot fetch_metadata source count does not include endpoint confirmations")


def build_snapshot(
    rankings_document: Mapping[str, Any],
    catalog_document: Mapping[str, Any],
    endpoints_documents: Mapping[str, Mapping[str, Any]],
    policy: Mapping[str, Any],
    *,
    now: datetime,
    top_n: int,
    demand_window_days: int | None = None,
    endpoint_confirmations: Mapping[str, str] | None = None,
) -> dict[str, Any]:
    rankings = normalize_rankings(rankings_document, top_n)
    ranking_meta = rankings_metadata(rankings_document)
    observed_window_days = (parse_ranking_date(ranking_meta["end_date"], "rankings response: meta.end_date") - parse_ranking_date(ranking_meta["start_date"], "rankings response: meta.start_date")).days + 1
    if demand_window_days is not None and demand_window_days != observed_window_days:
        raise SchemaError("rankings response metadata does not match the requested demand window")
    resolved_window_days = observed_window_days
    catalog = validate_catalog(catalog_document)
    endpoint_requests = resolve_rankings_to_catalog(rankings, catalog)
    requested_endpoint_ids = {demand["source_model_id"] for demand in endpoint_requests}
    if set(endpoints_documents) != requested_endpoint_ids:
        raise SchemaError("endpoints response set does not exactly match selected ranking models")
    confirmations = dict(endpoint_confirmations or {})
    if not set(confirmations).issubset(requested_endpoint_ids):
        raise SchemaError("endpoint confirmation set contains an unrequested model")
    if any(value not in {"confirmed_empty_second_fetch", "recovered_nonempty_on_confirmation"} for value in confirmations.values()):
        raise SchemaError("endpoint confirmation provenance is invalid")
    skipped_free_ranked_models: list[dict[str, Any]] = []
    rankings = resolve_rankings_to_catalog(rankings, catalog, endpoints_documents, skipped_sink=skipped_free_ranked_models)
    # Free-only ranked models are dropped by the resolver. Re-compact the
    # surviving cohort to contiguous demand ranks (1..N) so the snapshot keeps
    # its rank-contiguity invariant while preserving demand order and each
    # model's absolute total_token_volume. This is a no-op when nothing dropped.
    # The dropped rows (with their ORIGINAL rank) are recorded in fetch_metadata
    # so the observed shortfall is auditable: `observed + skipped == requested`.
    rankings.sort(key=lambda demand: demand["rank"])
    for new_rank, demand in enumerate(rankings, start=1):
        demand["rank"] = new_rank
    skipped_free_ranked_models.sort(key=lambda entry: entry["rank"])
    resolved_endpoints: dict[str, Mapping[str, Any]] = {}
    for demand in rankings:
        request_id = (
            demand["ranking_model_permaslug"]
            if demand["_identity_resolution"] in {"endpoint_alias_fallback", "endpoint_confirmed_catalog_candidate"}
            else demand["source_model_id"]
        )
        source_model_id = demand["source_model_id"]
        if source_model_id in resolved_endpoints:
            raise SchemaError(f"endpoint alias resolution produced duplicate model id {source_model_id!r}")
        resolved_endpoints[source_model_id] = endpoints_documents[request_id]
    policy_models = policy_model_index(policy)
    min_request_count_30m = policy.get("min_endpoint_request_count_30m", 1)
    normalized_rows: list[dict[str, Any]] = []
    for demand in rankings:
        source_model_id = demand["source_model_id"]
        if source_model_id not in resolved_endpoints:
            raise SchemaError(f"partial pull: endpoints response missing for {source_model_id!r}")
        endpoint_document = resolved_endpoints[source_model_id]
        endpoint_pricing = cheapest_endpoint_pricing(
            endpoint_document,
            source_model_id,
            min_request_count_30m=min_request_count_30m,
        )
        request_id = (
            demand["ranking_model_permaslug"]
            if demand["_identity_resolution"] in {"endpoint_alias_fallback", "endpoint_confirmed_catalog_candidate"}
            else source_model_id
        )
        confirmation = confirmations.get(request_id, "not_required")
        empty_provider_set = endpoint_set_is_empty(endpoint_document, source_model_id)
        if empty_provider_set and confirmation != "confirmed_empty_second_fetch":
            raise SchemaError(f"endpoints response for {source_model_id}: empty provider set was not confirmed")
        if not empty_provider_set and confirmation == "confirmed_empty_second_fetch":
            raise SchemaError(f"endpoints response for {source_model_id}: confirmation provenance contradicts provider set")
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
                "pricing_status": (
                    "no_provider_endpoints"
                    if empty_provider_set
                    else "active_priced"
                    if endpoint_pricing
                    else "no_active_priced_endpoint"
                ),
                "source_metadata": {
                    "ranking_model_permaslug": demand["ranking_model_permaslug"],
                    "catalog_canonical_slug": catalog_row["canonical_slug"] if catalog_row else None,
                    "catalog_name": catalog_row.get("name") if catalog_row else None,
                    "identity_resolution": demand["_identity_resolution"],
                    "endpoint_set_confirmation": confirmation,
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
                "successful_source_count": 2 + len(endpoints_documents) + len(confirmations),
                "observed_model_count": len(normalized_rows),
                "requested_top_n": top_n,
                "demand_window_days": resolved_window_days,
                "ranking_window_start_date": ranking_meta["start_date"],
                "ranking_window_end_date": ranking_meta["end_date"],
                "demand_metric": "aggregated_daily_total_tokens",
                "skipped_free_ranked_models": skipped_free_ranked_models,
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
        expected_keys.add("coding_specialist")
        expected_keys.add("general_purpose_baseline_per_mtok")
        if model.get("coding_specialist") is not True:
            raise SchemaError(f"policy.models[{index}].coding_specialist must be true")
    if not set(model).issubset(expected_keys):
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
    if set(policy) not in (CURRENT_POLICY_KEYS, LEGACY_POLICY_KEYS):
        raise SchemaError("policy has missing or unexpected fields")
    if not isinstance(policy.get("policy_version"), str) or not policy["policy_version"]:
        raise SchemaError("policy.policy_version must be non-empty")
    demand_top_n = policy.get("demand_top_n")
    if demand_top_n != 50:
        raise SchemaError("policy.demand_top_n must be exactly 50 for the documented daily rankings dataset")
    if set(policy) == LEGACY_POLICY_KEYS:
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
        return
    undercut = parse_decimal(
        policy.get("undercut_fraction"),
        "policy undercut_fraction", allow_zero=False,
    )
    if not Decimal("0.10") <= undercut <= Decimal("0.30"):
        raise SchemaError("policy undercut fraction must be within 10%-30%")
    cache_hit_fraction = policy.get("cache_hit_fraction")
    if cache_hit_fraction is not None:
        parsed_cache_hit_fraction = parse_decimal(cache_hit_fraction, "policy cache_hit_fraction", allow_zero=True)
        if not Decimal("0") <= parsed_cache_hit_fraction <= Decimal("1"):
            raise SchemaError("policy cache_hit_fraction must be within 0-1")
    elif set(policy) == CURRENT_POLICY_KEYS:
        raise SchemaError("policy cache_hit_fraction is required")
    # Minimum per-endpoint 30-minute request activity for an endpoint to enter
    # the priced cohort. Replaces the removed 30-day token-volume liquidity
    # floor; the request-weighted median still provides manipulation resistance.
    min_requests = policy.get("min_endpoint_request_count_30m")
    if isinstance(min_requests, bool) or not isinstance(min_requests, int) or min_requests < 1:
        raise SchemaError("policy min_endpoint_request_count_30m must be an integer of at least 1")
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
    allowed_top_level = {"version", "policy_version", "generated_at", "usd_per_million_credits", "rows"}
    required_top_level = allowed_top_level
    if not set(rate_card) <= allowed_top_level or not required_top_level <= set(rate_card):
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


def current_rates(rate_rows: Mapping[str, Any], model_id: str, *, legacy: bool = False) -> dict[str, int] | None:
    current_key = rate_row_key(rate_rows, model_id, allow_normalized=not legacy)
    if current_key is None:
        return None
    current = rate_rows.get(current_key)
    if not isinstance(current, dict):
        raise SchemaError(f"rate card row {current_key!r} must be an object")
    completion = current.get("completion_rate_per_mtok")
    if isinstance(completion, bool) or not isinstance(completion, int) or completion < 0:
        raise SchemaError(f"rate card row {current_key!r} has invalid completion rate")
    if legacy:
        return {"rate_card_completion_rate_per_mtok": completion}
    rates = {}
    for field in ("prompt_rate_per_mtok", "prompt_cache_hit_rate_per_mtok"):
        value = current.get(field)
        if isinstance(value, bool) or not isinstance(value, int) or value < 0:
            raise SchemaError(f"rate card row {current_key!r} has invalid {field}")
        rates[f"rate_card_{field}"] = value
    rates["rate_card_completion_rate_per_mtok"] = completion
    return rates


def rate_card_economics(rate_card: Mapping[str, Any], model_id: str) -> tuple[Decimal, Decimal, Decimal, str]:
    """Return USD conversion, multiplier, share, and the row used as basis."""
    rows = rate_card["rows"]
    basis_id = rate_row_key(rows, model_id) or "default"
    basis = rows[basis_id]
    return (
        Decimal(str(rate_card["usd_per_million_credits"])),
        Decimal(basis["global_multiplier_ppm"]),
        Decimal(basis["provider_share_bps"]),
        basis_id,
    )


def legacy_rate_card_economics(rate_card: Mapping[str, Any], model_id: str) -> tuple[Decimal, Decimal, Decimal, str]:
    rows = rate_card["rows"]
    basis_id = model_id if model_id in rows else "default"
    basis = rows[basis_id]
    return (
        Decimal(str(rate_card["usd_per_million_credits"])),
        Decimal(basis["global_multiplier_ppm"]),
        Decimal(basis["provider_share_bps"]),
        basis_id,
    )


def internal_rate(value: Decimal, rate_card: Mapping[str, Any], model_id: str) -> int:
    """Convert buyer USD/MTok to the reference card's credits/MTok encoding."""
    usd_per_million_credits, _, _, _ = rate_card_economics(rate_card, model_id)
    credits_per_mtok = value * Decimal("1000000") / usd_per_million_credits
    return int(credits_per_mtok.quantize(Decimal("1"), rounding=ROUND_FLOOR))


def completion_rate_to_internal(value: Decimal, rate_card: Mapping[str, Any], model_id: str) -> int:
    return internal_rate(value, rate_card, model_id)


def legacy_completion_rate_to_internal(value: Decimal, rate_card: Mapping[str, Any], model_id: str) -> int:
    usd_per_million_credits, multiplier_ppm, _, _ = legacy_rate_card_economics(rate_card, model_id)
    credits_per_mtok = value * Decimal("1000000000000") / (multiplier_ppm * usd_per_million_credits)
    return int(credits_per_mtok.quantize(Decimal("1"), rounding=ROUND_HALF_UP))


def provider_hourly_usd(internal_rate_per_mtok: int, tps: Decimal, rate_card: Mapping[str, Any], model_id: str) -> Decimal:
    """Provider net USD/hour under the exact reference-card conversion/share."""
    usd_per_million_credits, multiplier_ppm, provider_share_bps, _ = rate_card_economics(rate_card, model_id)
    buyer_usd_per_mtok = Decimal(internal_rate_per_mtok) * multiplier_ppm * usd_per_million_credits / Decimal("1000000000000")
    return buyer_usd_per_mtok * provider_share_bps / Decimal("10000") * tps * Decimal("3600") / Decimal("1000000")


def legacy_provider_hourly_usd(internal_rate_per_mtok: int, tps: Decimal, rate_card: Mapping[str, Any], model_id: str) -> Decimal:
    usd_per_million_credits, multiplier_ppm, provider_share_bps, _ = legacy_rate_card_economics(rate_card, model_id)
    buyer_usd_per_mtok = Decimal(internal_rate_per_mtok) * multiplier_ppm * usd_per_million_credits / Decimal("1000000000000")
    return buyer_usd_per_mtok * provider_share_bps / Decimal("10000") * tps * Decimal("3600") / Decimal("1000000")


def validate_policy_matches_snapshot_schema(snapshot: Mapping[str, Any], policy: Mapping[str, Any]) -> None:
    policy_keys = set(policy)
    if snapshot.get("schema_version") == LEGACY_SNAPSHOT_SCHEMA_VERSION:
        if policy_keys != LEGACY_POLICY_KEYS:
            raise SchemaError("legacy snapshot requires legacy pricing policy")
    elif policy_keys != CURRENT_POLICY_KEYS:
        raise SchemaError("current snapshot requires current pricing policy")


def static_policy_block_reasons(model: Mapping[str, Any]) -> list[str]:
    """Serving/license failures that block a row regardless of demand observation.

    These are the same fatal, market-independent conditions eligibility() checks,
    extracted so the cohort-absence branch can also honour them: a served model
    whose serving path or commercial license is no longer verified must be
    surfaced for human intervention (blocked), never silently retained.
    """
    reasons: list[str] = []
    serving = model.get("serving_path")
    if not isinstance(serving, dict) or serving.get("verification_status") != "verified":
        reasons.append("MLX/GGUF serving path is not verified")
    license_info = model.get("license")
    if not isinstance(license_info, dict) or license_info.get("commercial_permitted") is not True:
        reasons.append("commercial license is not verified as permitted")
    return reasons


def eligibility(model: Mapping[str, Any], row: Mapping[str, Any], policy: Mapping[str, Any]) -> tuple[bool, list[str], Decimal | None]:
    reasons: list[str] = []
    rank = row["demand"]["rank"]
    if rank > 50:
        reasons.append(f"demand rank {rank} is outside the documented daily top-50 demand gate")
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
    if row.get("pricing_status") == "no_provider_endpoints":
        reasons.append("OpenRouter reports no provider endpoints after bounded confirmation")
        return False, reasons, None
    if row.get("pricing_status") != "active_priced" or not isinstance(pricing, dict):
        reasons.append("no active priced OpenRouter endpoint is available")
        return False, reasons, None
    completion = parse_decimal(pricing.get("completion_per_mtok"), "snapshot completion price")
    if completion == 0:
        reasons.append("cheapest active completion endpoint is free; no paid-market undercut can be computed")
    return not reasons, reasons, completion


def market_peg_eligibility(model: Mapping[str, Any], row: Mapping[str, Any]) -> tuple[bool, list[str], Decimal]:
    """v0.12 market-peg pricing treats policy mappings as prior intake output."""
    static_reasons = static_policy_block_reasons(model)
    if static_reasons:
        raise SchemaError(
            f"catalog-integrity: mapped recommendable {model['canonical_model_id']!r} "
            + "; ".join(static_reasons)
        )
    pricing = row.get("pricing")
    if row.get("pricing_status") == "no_provider_endpoints":
        raise SchemaError("OpenRouter reports no provider endpoints after bounded confirmation")
    if row.get("pricing_status") != "active_priced" or not isinstance(pricing, dict):
        raise SchemaError("no active priced OpenRouter endpoint is available")
    completion = parse_decimal(pricing.get("completion_per_mtok"), "snapshot completion price")
    if completion == 0:
        raise SchemaError("cheapest active completion endpoint is free; no paid-market undercut can be computed")
    return True, [], completion


def validate_market_peg_snapshot_requirements(snapshot: Mapping[str, Any], policy: Mapping[str, Any], *, now: datetime) -> None:
    required_top_n = policy["demand_top_n"]
    coverage = snapshot["source"]["fetch_metadata"]
    # Coverage is asserted on the REQUESTED cohort, not observed_model_count.
    # The fetch requests the full top-N demand cohort; :free-variant ranked
    # models are then dropped (they have no paid price), so observed_model_count
    # is legitimately below required_top_n whenever the live top-N contains free
    # variants. Every other reason a requested row would not be observed (partial
    # endpoint pull, ambiguous identity, schema drift) already fails closed in
    # build_snapshot before a snapshot exists, so requested_top_n >= required is
    # a sufficient and honest coverage guarantee.
    if coverage["requested_top_n"] < required_top_n:
        raise SchemaError("snapshot does not contain the policy-required top-demand coverage")
    if snapshot.get("schema_version") == LEGACY_SNAPSHOT_SCHEMA_VERSION:
        return
    # Coverage on the requested cohort is only trustworthy because the snapshot
    # is proven complete (validate_snapshot enforces observed + skipped == requested).
    # Assert it explicitly here too: the OBSERVED cohort plus the recorded free
    # drops must still cover the required top-N.
    skipped_free = coverage.get("skipped_free_ranked_models")
    if not isinstance(skipped_free, list):
        raise SchemaError("snapshot fetch_metadata is missing the skipped_free_ranked_models provenance")
    if coverage["observed_model_count"] + len(skipped_free) < required_top_n:
        raise SchemaError("snapshot observed cohort plus recorded free drops does not cover the policy-required top-demand")
    # Bind the snapshot's pricing basis to THIS compute policy: every active-priced
    # row must have been priced under the current request-count floor, so a snapshot
    # produced under a looser floor cannot be repriced under a stricter policy.
    policy_floor = policy.get("min_endpoint_request_count_30m", 1)
    for index, row in enumerate(snapshot.get("rows", [])):
        if not isinstance(row, dict) or row.get("pricing_status") != "active_priced":
            continue
        recorded_floor = ((row.get("pricing") or {}).get("liquidity_filter") or {}).get("minimum_request_count_last_30m")
        if recorded_floor != policy_floor:
            raise SchemaError(f"snapshot.rows[{index}] priced under request-count floor {recorded_floor!r} but policy floor is {policy_floor!r}; re-fetch under the current policy")
    ranking_end_date = coverage["ranking_window_end_date"]
    # ranking_window_end_date is date-typed, so reject at two calendar days
    # old to keep the accepted window within SPEC's 48-hour intent.
    if now.date() - parse_ranking_date(ranking_end_date, "snapshot ranking_window_end_date").date() >= timedelta(days=2):
        raise SchemaError("snapshot ranking window is older than 48 hours; market-pegged compute emits no proposals")


def proposed_price(
    model: Mapping[str, Any],
    market: Mapping[str, Any],
    policy: Mapping[str, Any],
    rate_card: Mapping[str, Any],
    model_id: str,
    *,
    enforce_coding_floor: bool = True,
) -> tuple[Decimal, int, Decimal, int, int, list[str]]:
    profile = model["profile"]
    kind = profile["kind"]
    market_completion = parse_decimal(market.get("completion_per_mtok"), "snapshot completion price")
    market_prompt = parse_decimal(market.get("input_per_mtok"), "snapshot prompt price", allow_zero=False)
    if kind not in {"broad_fleet", "coding_dense"}:
        raise SchemaError(f"unsupported profile kind {kind!r}")
    undercut = parse_decimal(policy.get("undercut_fraction", policy.get("broad_fleet_undercut_fraction")), "policy undercut_fraction")
    target = market_completion * (Decimal("1") - undercut)
    target_prompt = market_prompt * (Decimal("1") - undercut)
    completion_internal = internal_rate(target, rate_card, model_id)
    prompt_internal = internal_rate(target_prompt, rate_card, model_id)
    if completion_internal == 0 or prompt_internal == 0:
        raise SchemaError(f"rate card row {model_id!r} market credit rounds to zero")
    cache_hit_fraction = parse_decimal(policy.get("cache_hit_fraction", "0.25"), "policy cache_hit_fraction", allow_zero=True)
    cache_hit_internal = int((prompt_internal * cache_hit_fraction).to_integral_value(rounding=ROUND_FLOOR))
    if cache_hit_internal == 0 and cache_hit_fraction > 0:
        raise SchemaError(f"rate card row {model_id!r} cache-hit credit rounds to zero")
    if cache_hit_internal > prompt_internal:
        raise SchemaError(f"rate card row {model_id!r} cache-hit credit exceeds prompt credit")
    if kind == "broad_fleet" or not enforce_coding_floor:
        return (
            target,
            completion_internal,
            target_prompt,
            prompt_internal,
            cache_hit_internal,
            [f"undercut fraction {decimal_string(undercut)} on OpenRouter liquidity-filtered prompt and completion prices"],
        )
    coding_internal_rate = completion_internal
    tps = parse_decimal(profile["projected_tps"], "coding model projected_tps", allow_zero=False)
    provider_hourly = provider_hourly_usd(coding_internal_rate, tps, rate_card, model_id)
    if provider_hourly < Decimal("0.10"):
        raise SchemaError("coding-dense target does not meet the $0.10/hour provider economics floor")
    _, _, _, basis_id = rate_card_economics(rate_card, model_id)
    return (
        target,
        coding_internal_rate,
        target_prompt,
        prompt_internal,
        cache_hit_internal,
        [
            f"undercut fraction {decimal_string(undercut)} on OpenRouter liquidity-filtered completion price",
            f"provider net hourly USD {decimal_string(provider_hourly)} using rate-card economics row {basis_id}",
            f"prompt undercut fraction {decimal_string(undercut)} on OpenRouter liquidity-filtered prompt price",
        ],
    )


def proposed_completion_price(
    model: Mapping[str, Any],
    market_completion: Decimal,
    policy: Mapping[str, Any],
    rate_card: Mapping[str, Any],
    model_id: str,
) -> tuple[Decimal, int, list[str]]:
    profile = model["profile"]
    kind = profile["kind"]
    if kind == "broad_fleet":
        undercut = parse_decimal(policy["broad_fleet_undercut_fraction"], "policy broad_fleet_undercut_fraction")
        target = market_completion * (Decimal("1") - undercut)
        return target, legacy_completion_rate_to_internal(target, rate_card, model_id), [f"broad-fleet undercut fraction {decimal_string(undercut)}"]
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
    internal = legacy_completion_rate_to_internal(target, rate_card, model_id)
    tps = parse_decimal(profile["projected_tps"], "coding model projected_tps", allow_zero=False)
    provider_hourly = legacy_provider_hourly_usd(internal, tps, rate_card, model_id)
    if provider_hourly < Decimal("0.10"):
        raise SchemaError("coding-dense target does not meet the $0.10/hour provider economics floor")
    _, _, _, basis_id = legacy_rate_card_economics(rate_card, model_id)
    return target, internal, [
        f"coding premium fraction {decimal_string(premium)}",
        f"coding market undercut fraction {decimal_string(undercut)}",
        f"provider net hourly USD {decimal_string(provider_hourly)} using rate-card economics row {basis_id}",
    ]


def build_proposal(
    snapshot: Mapping[str, Any], policy: Mapping[str, Any], rate_card: Mapping[str, Any], *, now: datetime
) -> dict[str, Any]:
    validate_snapshot(snapshot)
    legacy_snapshot = snapshot.get("schema_version") == LEGACY_SNAPSHOT_SCHEMA_VERSION
    validate_policy(policy)
    validate_policy_matches_snapshot_schema(snapshot, policy)
    validate_rate_card(rate_card)
    validate_market_peg_snapshot_requirements(snapshot, policy, now=now)
    rate_rows = rate_card["rows"]
    policy_models = policy_model_index(policy)
    rows_by_source = {row["source_model_id"]: row for row in snapshot["rows"]}
    buckets = ("added", "changed", "dropped", "blocked", "unchanged")
    if legacy_snapshot:
        buckets = (*buckets[:3], "retained", *buckets[3:])
    result: dict[str, list[dict[str, Any]]] = {key: [] for key in buckets}
    assessed_current_ids: set[str] = set()

    def market_unavailable() -> dict[str, None]:
        return {"demand_rank": None, "total_token_volume": None, "benchmark_provider": None, "completion_per_mtok": None}

    def market_from_snapshot_row(row: Mapping[str, Any]) -> dict[str, Any]:
        pricing = row.get("pricing")
        if row.get("pricing_status") != "active_priced" or not isinstance(pricing, dict):
            return {"demand_rank": row["demand"]["rank"], "total_token_volume": row["demand"]["total_token_volume"], "benchmark_provider": None, "completion_per_mtok": None}
        return {
            "demand_rank": row["demand"]["rank"],
            "total_token_volume": row["demand"]["total_token_volume"],
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
            row_reasons = ["no verified policy metadata/mapping for this OpenRouter model"]
            if row["pricing_status"] == "no_provider_endpoints":
                row_reasons.append("OpenRouter reports no provider endpoints after bounded confirmation")
            elif row["pricing_status"] == "no_active_priced_endpoint":
                row_reasons.append("no active priced OpenRouter endpoint is available")
            result["blocked"].append(
                {
                    "model_id": row["canonical_model_id"],
                    "source_model_id": row["source_model_id"],
                    "action": "blocked",
                    "market": market_from_snapshot_row(row),
                    "eligibility": {"eligible": False, "reasons": row_reasons},
                    "policy_evidence": policy_evidence(None),
                    "reasons": row_reasons,
                }
            )

    for source_model_id, model in sorted(policy_models.items()):
        canonical_id = model["canonical_model_id"]
        if canonical_id in rate_rows:
            assessed_current_ids.add(canonical_id)
        row = rows_by_source.get(source_model_id)
        if row is None:
            absent_reason = (
                "absent from the documented daily top-50 demand cohort; no demand signal to reprice, "
                "and absence is not evidence to delist a served model"
            )
            if legacy_snapshot:
                static_blockers = static_policy_block_reasons(model)
                if canonical_id in rate_rows and canonical_id != "default" and not static_blockers:
                    result["retained"].append(
                        {
                            "model_id": canonical_id,
                            "source_model_id": source_model_id,
                            "action": "retained",
                            "current_completion_rate": current_rates(rate_rows, canonical_id, legacy=legacy_snapshot),
                            "eligibility": {"eligible": False, "reasons": [absent_reason]},
                            "market": market_unavailable(),
                            "policy_evidence": policy_evidence(model),
                            "reasons": [absent_reason],
                        }
                    )
                elif canonical_id in rate_rows and canonical_id != "default":
                    blocked_reasons = static_blockers + [absent_reason]
                    result["blocked"].append(
                        {
                            "model_id": canonical_id,
                            "source_model_id": source_model_id,
                            "action": "blocked",
                            "current_completion_rate": current_rates(rate_rows, canonical_id, legacy=legacy_snapshot),
                            "eligibility": {"eligible": False, "reasons": blocked_reasons},
                            "market": market_unavailable(),
                            "policy_evidence": policy_evidence(model),
                            "reasons": blocked_reasons,
                        }
                    )
                else:
                    result["blocked"].append(
                        {
                            "model_id": canonical_id,
                            "source_model_id": source_model_id,
                            "action": "blocked",
                            "market": market_unavailable(),
                            "eligibility": {"eligible": False, "reasons": [absent_reason]},
                            "policy_evidence": policy_evidence(model),
                            "reasons": [absent_reason],
                        }
                    )
                continue
            raise SchemaError(
                "mapped recommendable model is absent from the documented daily top-50 demand cohort; "
                "market-pegged compute emits no proposals"
            )
        if legacy_snapshot:
            allowed, reasons, market_completion = eligibility(model, row, policy)
        else:
            allowed, reasons, market_completion = market_peg_eligibility(model, row)
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
                "OpenRouter reports no provider endpoints after bounded confirmation",
                "cheapest active completion endpoint is free; no paid-market undercut can be computed",
            }
            if not legacy_snapshot and any(reason in block_reasons for reason in reasons):
                illiquid_reasons = block_reasons - {"MLX/GGUF serving path is not verified", "commercial license is not verified as permitted"}
                if any(reason in illiquid_reasons for reason in reasons):
                    raise SchemaError("; ".join(reasons))
            action = (
                "blocked"
                if any(reason in block_reasons for reason in reasons)
                else "retained"
                if legacy_snapshot and canonical_id in rate_rows and canonical_id != "default"
                else "blocked"
            )
            base.update({"action": action, "reasons": reasons})
            if canonical_id in rate_rows:
                base["current_completion_rate"] = current_rates(rate_rows, canonical_id, legacy=legacy_snapshot)
            result[base["action"]].append(base)
            continue
        try:
            if legacy_snapshot:
                target, proposed_internal, formula_reasons = proposed_completion_price(
                    model, market_completion, policy, rate_card, canonical_id
                )
            else:
                target, proposed_internal, target_prompt, proposed_prompt_internal, proposed_cache_hit_internal, formula_reasons = proposed_price(
                    model,
                    row["pricing"],
                    policy,
                    rate_card,
                    canonical_id,
                    enforce_coding_floor=False,
                )
        except SchemaError as error:
            if not legacy_snapshot:
                raise
            base.update({"action": "blocked", "reasons": [str(error)]})
            result["blocked"].append(base)
            continue
        if legacy_snapshot:
            base["proposed_completion_rate"] = {
                "usd_per_mtok": decimal_string(target),
                "rate_card_completion_rate_per_mtok": proposed_internal,
                "formula_reasons": formula_reasons,
            }
        else:
            base["proposed_rates"] = {
                "completion_usd_per_mtok": decimal_string(target),
                "completion_rate_per_mtok": proposed_internal,
                "prompt_usd_per_mtok": decimal_string(target_prompt),
                "prompt_rate_per_mtok": proposed_prompt_internal,
                "prompt_cache_hit_rate_per_mtok": proposed_cache_hit_internal,
                "formula_reasons": formula_reasons,
            }
        if legacy_snapshot:
            usd_per_million_credits, multiplier_ppm, provider_share_bps, basis_id = legacy_rate_card_economics(rate_card, canonical_id)
        else:
            usd_per_million_credits, multiplier_ppm, provider_share_bps, basis_id = rate_card_economics(rate_card, canonical_id)
        base["rate_card_economics"] = {
            "basis_row": basis_id,
            "usd_per_million_credits": decimal_string(usd_per_million_credits),
            "global_multiplier_ppm": decimal_string(multiplier_ppm),
            "provider_share_bps": decimal_string(provider_share_bps),
        }
        current_rate_pair = current_rates(rate_rows, canonical_id, legacy=legacy_snapshot)
        if current_rate_pair is None:
            base["action"] = "added"
            result["added"].append(base)
            continue
        base["current_completion_rate"] = current_rate_pair
        if legacy_snapshot:
            if current_rate_pair["rate_card_completion_rate_per_mtok"] == proposed_internal:
                base["action"] = "unchanged"
                result["unchanged"].append(base)
            else:
                base["action"] = "changed"
                result["changed"].append(base)
            continue
        if current_rate_pair["rate_card_completion_rate_per_mtok"] == proposed_internal and current_rate_pair["rate_card_prompt_rate_per_mtok"] == proposed_prompt_internal and current_rate_pair["rate_card_prompt_cache_hit_rate_per_mtok"] == proposed_cache_hit_internal:
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
                "current_completion_rate": current_rates(rate_rows, model_id, legacy=legacy_snapshot),
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
        **({"source_snapshot": {"content_digest": snapshot["content_digest"]}} if snapshot.get("schema_version") != LEGACY_SNAPSHOT_SCHEMA_VERSION else {}),
        "policy_version": policy["policy_version"],
        "rate_card_reference_digest": rate_card_digest(rate_card),
        "summary": summary,
        **result,
    }


def build_demand_proposal(
    snapshot: Mapping[str, Any],
    policy: Mapping[str, Any],
    *,
    min_provider_targets: Mapping[str, int],
    catalog_path: Path | None = None,
    recommendable_catalog: Mapping[str, Any] | None = None,
    now: datetime | None = None,
) -> dict[str, Any]:
    validate_snapshot(snapshot)
    validate_policy(policy)
    policy_models = policy_model_index(policy)
    models_by_canonical = {model["canonical_model_id"]: model for model in policy["models"]}
    if catalog_path is not None and recommendable_catalog is not None:
        raise SchemaError("recommendable catalog must be supplied by path or object, not both")
    if recommendable_catalog is None:
        resolved_catalog_path = PRODUCTION_CATALOG_PATH if catalog_path is None else catalog_path
        catalog = json.loads(resolved_catalog_path.read_text(encoding="utf-8"))
    else:
        catalog = recommendable_catalog
    recommendable_keys = {key for key, row in catalog["rows"].items() if row.get("runtime_status") == "recommendable"}
    expected_target_keys = set(models_by_canonical)
    if expected_target_keys != recommendable_keys:
        raise SchemaError("policy mappings must exactly cover the recommendable candidate catalog")
    if not isinstance(min_provider_targets, dict) or set(min_provider_targets) != expected_target_keys or any(isinstance(value, bool) or not isinstance(value, int) or value < 0 for value in min_provider_targets.values()):
        raise SchemaError("minimum provider targets must exactly cover mapped canonical model IDs with non-negative integers")
    models_by_source = {model["source_model_id"]: model for model in policy["models"]}
    rows_by_source = {row["source_model_id"]: row for row in snapshot["rows"]}
    if snapshot.get("schema_version") != LEGACY_SNAPSHOT_SCHEMA_VERSION:
        validate_market_peg_snapshot_requirements(snapshot, policy, now=utc_now() if now is None else now)
        missing_sources = sorted(source_id for source_id in models_by_source if source_id not in rows_by_source)
        if missing_sources:
            raise SchemaError(
                "mapped recommendable model is absent from the documented daily top-50 demand cohort; "
                "market-pegged compute emits no proposals"
            )
        for source_id, model in sorted(models_by_source.items()):
            market_peg_eligibility(model, rows_by_source[source_id])
    tokens = {
        model["canonical_model_id"]: int(rows_by_source[source_id]["demand"]["total_token_volume"])
        for source_id, model in models_by_source.items()
        if source_id in rows_by_source
    }
    tokens.update({canonical_id: 0 for canonical_id in expected_target_keys if canonical_id not in tokens})
    max_tokens = max(tokens.values(), default=0)
    rows: dict[str, dict[str, Any]] = {}
    for canonical_id in sorted(tokens):
        model = models_by_canonical[canonical_id]
        row = rows_by_source.get(model["source_model_id"])
        demand = row["demand"] if row is not None else {"rank": None, "total_token_volume": "0"}
        rows[canonical_id] = {
            "demand_weight": tokens[canonical_id] / max_tokens if max_tokens else 0,
            "rank": demand["rank"],
            "recommendable": True,
            "min_provider_target": min_provider_targets[canonical_id],
            "or_completion_tokens_30d": int(demand["total_token_volume"]),
            "or_requests_30d": 0,
        }
    return {
        "schema_version": 1,
        "proposal_type": "openrouter-demand-rank-proposal",
        "generated_at": snapshot["fetched_at"],
        "snapshot_digest": snapshot["content_digest"],
        **({"source_snapshot": {"content_digest": snapshot["content_digest"]}} if snapshot.get("schema_version") != LEGACY_SNAPSHOT_SCHEMA_VERSION else {}),
        "policy_version": policy["policy_version"],
        "source": "openrouter_completion_token_rank_operator_curated",
        "cold_start_floor": 0.15,
        "diversification_band": 0.85,
        "rows": rows,
    }

def normalize_min_provider_targets(document: Mapping[str, Any]) -> dict[str, int]:
    if "rows" in document:
        rows = document.get("rows")
        if not isinstance(rows, dict):
            raise SchemaError("minimum provider targets rows must be an object")
        return {key: row["min_provider_target"] for key, row in rows.items() if isinstance(row, dict) and "min_provider_target" in row}
    return dict(document)


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


def atomic_write_json_pair(first: tuple[Path, Mapping[str, Any]], second: tuple[Path, Mapping[str, Any]]) -> None:
    prepared: list[tuple[Path, str]] = []
    linked: list[Path] = []
    try:
        for path, value in (first, second):
            path.parent.mkdir(parents=True, exist_ok=True)
            if path.exists():
                raise EngineError(f"refusing to overwrite existing artifact {path}")
            descriptor, temporary_name = tempfile.mkstemp(prefix=f".{path.name}.", suffix=".tmp", dir=path.parent)
            try:
                with os.fdopen(descriptor, "wb") as handle:
                    handle.write(canonical_json(value))
                    handle.write(b"\n")
                    handle.flush()
                    os.fsync(handle.fileno())
            except BaseException:
                try:
                    os.close(descriptor)
                except OSError:
                    pass
                try:
                    os.unlink(temporary_name)
                except FileNotFoundError:
                    pass
                raise
            prepared.append((path, temporary_name))
        for path, temporary_name in prepared:
            try:
                os.link(temporary_name, path)
            except FileExistsError as error:
                raise EngineError(f"refusing to overwrite existing artifact {path}") from error
            linked.append(path)
    except BaseException:
        for path in linked:
            try:
                os.unlink(path)
            except FileNotFoundError:
                pass
        raise
    finally:
        for _, temporary_name in prepared:
            try:
                os.unlink(temporary_name)
            except FileNotFoundError:
                pass


def fsync_directory(path: Path) -> None:
    descriptor = os.open(path, os.O_RDONLY)
    try:
        os.fsync(descriptor)
    finally:
        os.close(descriptor)


def atomic_publish_json_directory(target_dir: Path, artifacts: Mapping[str, Mapping[str, Any]]) -> None:
    if target_dir.exists():
        raise EngineError(f"refusing to overwrite existing artifact directory {target_dir}")
    target_dir.parent.mkdir(parents=True, exist_ok=True)
    staging_dir = Path(tempfile.mkdtemp(prefix=f".{target_dir.name}.", suffix=".tmp", dir=target_dir.parent))
    published = False
    try:
        for name, value in artifacts.items():
            if Path(name).name != name or not name.endswith(".json"):
                raise EngineError(f"invalid artifact name {name!r}")
            path = staging_dir / name
            with path.open("wb") as handle:
                handle.write(canonical_json(value))
                handle.write(b"\n")
                handle.flush()
                os.fsync(handle.fileno())
        fsync_directory(staging_dir)
        fsync_directory(target_dir.parent)
        try:
            os.symlink(staging_dir.name, target_dir, target_is_directory=True)
        except FileExistsError as error:
            raise EngineError(f"refusing to overwrite existing artifact directory {target_dir}") from error
        published = True
        fsync_directory(target_dir.parent)
    except BaseException:
        if not published and staging_dir.exists():
            shutil.rmtree(staging_dir)
        raise


def artifact_suffix(value: Mapping[str, Any]) -> str:
    return sha256_prefixed(value).split(":", 1)[1][:16]


def snapshot_filename(now: datetime, snapshot: Mapping[str, Any]) -> str:
    return "openrouter-pricing-snapshot-" + now.astimezone(timezone.utc).strftime("%Y-%m-%dT%H-%M-%SZ-") + artifact_suffix(snapshot) + ".json"


def rate_card_proposal_filename(now: datetime, proposal: Mapping[str, Any]) -> str:
    return "openrouter-rate-card-proposal-" + now.astimezone(timezone.utc).strftime("%Y-%m-%dT%H-%M-%SZ-") + artifact_suffix(proposal) + ".json"


def demand_proposal_filename(now: datetime, proposal: Mapping[str, Any]) -> str:
    return "openrouter-demand-rank-proposal-" + now.astimezone(timezone.utc).strftime("%Y-%m-%dT%H-%M-%SZ-") + artifact_suffix(proposal) + ".json"


def proposal_filename(now: datetime, proposal: Mapping[str, Any]) -> str:
    return "openrouter-rate-card-proposal-" + now.astimezone(timezone.utc).strftime("%Y-%m-%dT%H-%M-%SZ-") + artifact_suffix(proposal) + ".json"


def daily_rankings_url(reference_time: datetime, demand_window_days: int) -> str:
    if not isinstance(demand_window_days, int) or isinstance(demand_window_days, bool) or not 1 <= demand_window_days <= 31:
        raise FetchError("demand window must be an integer from 1 through 31 days")
    end_date = reference_time.astimezone(timezone.utc).date() - timedelta(days=1)
    start_date = end_date - timedelta(days=demand_window_days - 1)
    return f"{RANKINGS_URL}?start_date={start_date.isoformat()}&end_date={end_date.isoformat()}"


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
    demand_window_days: int = 30,
) -> Path:
    if isinstance(top_n, bool) or not isinstance(top_n, int) or not 1 <= top_n <= 50:
        raise FetchError("top_n must be an integer between 1 and 50")
    if not math.isfinite(timeout_seconds) or not 0 < timeout_seconds <= 60:
        raise FetchError("request timeout must be finite, positive, and no more than 60 seconds")
    if not math.isfinite(generation_timeout_seconds) or not 1 <= generation_timeout_seconds <= 3600:
        raise FetchError("generation timeout must be finite, at least one second, and no more than one hour")
    if client is None:
        if not os.environ.get("OPENROUTER_API_KEY"):
            raise FetchError("OPENROUTER_API_KEY is required for the documented OpenRouter APIs")
        client = UrllibHTTPClient()
    deadline = clock() + generation_timeout_seconds
    rankings_url = daily_rankings_url(now(), demand_window_days)
    rankings = fetch_json(client, rankings_url, "daily rankings", retries=retries, timeout_seconds=timeout_seconds, sleeper=sleeper, deadline=deadline, clock=clock)
    catalog = fetch_json(client, MODELS_URL, "models catalog", retries=retries, timeout_seconds=timeout_seconds, sleeper=sleeper, deadline=deadline, clock=clock)
    catalog_index = validate_catalog(catalog)
    skipped_ranked_models: list[dict[str, Any]] = []
    ranking_rows = resolve_rankings_to_catalog(
        normalize_rankings(rankings, top_n), catalog_index, skipped_sink=skipped_ranked_models
    )
    for entry in skipped_ranked_models:
        print(
            "openrouter pricing engine: skipped free-only ranked model "
            f"{entry['ranking_model_permaslug']!r} ({entry['reason']})",
            file=sys.stderr,
        )
    endpoints: dict[str, Mapping[str, Any]] = {}
    endpoint_confirmations: dict[str, str] = {}
    for demand in ranking_rows:
        model_id = demand["source_model_id"]
        # The documented endpoint is /models/{provider}/{model}/endpoints; the
        # one validated provider/model slash must remain a path separator.
        url = ENDPOINTS_URL.format(model_id=quote(model_id, safe="/"))
        first_document = fetch_json(client, url, f"endpoints {model_id}", retries=retries, timeout_seconds=timeout_seconds, sleeper=sleeper, deadline=deadline, clock=clock)
        if endpoint_set_is_empty(first_document, model_id):
            first_response_id = endpoint_response_model_id(first_document, model_id)
            confirmation_document = fetch_json(client, url, f"endpoints {model_id} empty-set confirmation", retries=retries, timeout_seconds=timeout_seconds, sleeper=sleeper, deadline=deadline, clock=clock)
            confirmation_response_id = endpoint_response_model_id(confirmation_document, model_id)
            if confirmation_response_id != first_response_id:
                raise SchemaError(f"endpoints response for {model_id}: empty-set confirmation id mismatch")
            if endpoint_set_is_empty(confirmation_document, model_id):
                endpoint_confirmations[model_id] = "confirmed_empty_second_fetch"
            else:
                endpoint_confirmations[model_id] = "recovered_nonempty_on_confirmation"
            endpoints[model_id] = confirmation_document
        else:
            endpoints[model_id] = first_document
    fetched_at = now()
    snapshot = build_snapshot(rankings, catalog, endpoints, policy, now=fetched_at, top_n=top_n, demand_window_days=demand_window_days, endpoint_confirmations=endpoint_confirmations)
    target = output_dir / snapshot_filename(fetched_at, snapshot)
    atomic_write_json(target, snapshot)
    return target


def command_fetch(args: argparse.Namespace) -> int:
    policy = load_json_file(Path(args.policy), "policy")
    validate_policy(policy)
    result = fetch_live_snapshot(policy, output_dir=Path(args.output_dir), top_n=args.top_n, retries=args.retries, timeout_seconds=args.timeout_seconds, generation_timeout_seconds=args.generation_timeout_seconds, demand_window_days=args.demand_window_days)
    print(result)
    return 0


def command_compute(args: argparse.Namespace) -> int:
    snapshot = load_json_file(Path(args.snapshot), "snapshot")
    policy = load_json_file(Path(args.policy), "policy")
    rate_card = load_json_file(Path(args.rate_card), "rate card")
    candidate_catalog = Path(args.candidate_catalog)
    min_provider_targets = normalize_min_provider_targets(
        load_json_file(Path(args.min_provider_targets), "minimum provider targets")
    )
    now = utc_now()
    rate_card_proposal = build_proposal(snapshot, policy, rate_card, now=now)
    demand_proposal = build_demand_proposal(
        snapshot,
        policy,
        min_provider_targets=min_provider_targets,
        catalog_path=candidate_catalog,
        now=now,
    )
    output_dir = Path(args.output_dir)
    rate_card_name = rate_card_proposal_filename(now, rate_card_proposal)
    demand_name = demand_proposal_filename(now, demand_proposal)
    atomic_publish_json_directory(
        output_dir,
        {
            rate_card_name: rate_card_proposal,
            demand_name: demand_proposal,
        },
    )
    rate_card_target = output_dir / rate_card_name
    demand_target = output_dir / demand_name
    print(rate_card_target)
    print(demand_target)
    return 0


# --- propose mode: build a best-in-class servable catalog proposal ------------
#
# The `fetch`/`compute` pipeline selects by OpenRouter top-50 demand rank, then
# prices. Verified 2026-09-18, that is the wrong universe: the highest-yield
# MLX-servable models (Qwen a3b/27B at $1-2.2/Mtok, GLM-4.5-Air, Mistral-Small,
# Gemma-3-27B) sit OUTSIDE OpenRouter's top-50 demand rank, yet OpenRouter prices
# them all by id. `propose` flips to a yield-first scan over an explicit
# candidate universe: price each model by id (request-weighted median), gauge
# demand from 30m request_count, resolve MLX servability + residency, bucket by
# Mac RAM tier, and rank by yield within tier. It emits a reviewable proposal;
# it never applies, signs, or deploys.
CATALOG_PROPOSAL_SCHEMA_VERSION = 1
CATALOG_RAM_TIERS_GB = (32, 48, 64, 96, 128, 192, 256)
CATALOG_SAFETY_MARGIN_GB = 4
# Open-weight vendors that publish (or have community) MLX builds. Closed-weight
# API vendors and closed model families are excluded from the default universe;
# the HF servability resolver is the authoritative servability gate downstream.
OPEN_WEIGHT_VENDORS = frozenset({
    "qwen", "google", "meta-llama", "nvidia", "mistralai", "deepseek", "openai",
    "microsoft", "z-ai", "zhipu", "01-ai", "allenai", "cohere", "ibm-granite",
    "baidu", "moonshotai", "inclusionai", "stepfun", "nousresearch",
})
CLOSED_MODEL_MARKERS = ("gemini", "gpt-5", "gpt-6", "gpt-4", "grok", "claude", "o1-", "o3-", "o4-")
# Vision-language pipeline tags whose models are, in practice, served for TEXT via
# mlx-vlm and are top-yield earners (the Qwen3-VL and Gemma-3 families). The
# servability resolver conservatively marks them `unresolved` (it will not certify
# a text-only path from remote metadata); `propose` includes them as a flagged
# text-serving class so the highest-yield families are not silently dropped.
VISION_LANGUAGE_TEXT_TAGS = frozenset({"image-text-to-text"})


def assign_ram_tier(required_gb: Decimal, tiers: Sequence[int] = CATALOG_RAM_TIERS_GB, safety_margin_gb: int = CATALOG_SAFETY_MARGIN_GB) -> int | None:
    """Smallest RAM tier whose usable capacity holds the runtime residency."""
    for tier in sorted(tiers):
        if required_gb <= Decimal(tier - safety_margin_gb):
            return int(tier)
    return None


def model_demand_activity(endpoints_document: Mapping[str, Any]) -> int:
    """Advisory model-level demand gauge: sum of 30m request_count across every
    endpoint and workload. OpenRouter removed 30-day token volume, so this is the
    surviving activity proxy. Lenient by design (skips malformed telemetry) --
    it is review context, not a money value; the price path stays fail-closed.
    """
    data = endpoints_document.get("data")
    endpoints = data.get("endpoints") if isinstance(data, dict) else None
    if not isinstance(endpoints, list):
        return 0
    total = 0
    for endpoint in endpoints:
        if not isinstance(endpoint, dict):
            continue
        perf = endpoint.get("perf_last_30m_by_workload")
        if not isinstance(perf, dict):
            continue
        for stats in perf.values():
            if isinstance(stats, dict):
                count = stats.get("request_count")
                if isinstance(count, int) and not isinstance(count, bool) and count >= 0:
                    total += count
    return total


def select_open_weight_candidates(model_ids: Iterable[str]) -> list[str]:
    """Filter an OpenRouter /models id list to the default open-weight universe."""
    result: list[str] = []
    for model_id in model_ids:
        if not isinstance(model_id, str) or "/" not in model_id:
            continue
        lowered = model_id.lower()
        if lowered.endswith(":free") or ":" in model_id.split("/", 1)[1]:
            continue
        vendor = model_id.split("/", 1)[0].lower()
        if vendor not in OPEN_WEIGHT_VENDORS:
            continue
        if vendor == "openai" and not model_id.split("/", 1)[1].startswith("gpt-oss"):
            continue
        if any(marker in lowered for marker in CLOSED_MODEL_MARKERS):
            continue
        result.append(model_id)
    return sorted(dict.fromkeys(result))


def build_catalog_proposal(
    records: list[Mapping[str, Any]],
    policy: Mapping[str, Any],
    *,
    now: datetime,
    yield_floor_completion_per_mtok: Decimal,
    demand_floor_request_count_30m: int,
    tiers: Sequence[int] = CATALOG_RAM_TIERS_GB,
) -> dict[str, Any]:
    """Pure core: gate priced+servable records by yield/demand/servability, bucket
    by RAM tier, rank by yield within tier. Emits selected + an excluded audit
    trail. Every input record was produced by the network stage below."""
    undercut = parse_decimal(policy.get("undercut_fraction"), "policy undercut_fraction")
    selected: list[dict[str, Any]] = []
    excluded: list[dict[str, Any]] = []
    for record in records:
        model_id = record["model_id"]
        pricing = record.get("pricing")
        servability = record.get("servability") or {}
        demand = int(record.get("demand_request_count_30m") or 0)
        if pricing is None:
            excluded.append({"model_id": model_id, "reason": "no active priced OpenRouter endpoint"})
            continue
        completion = parse_decimal(pricing["completion_per_mtok"], f"{model_id} completion price")
        prompt = parse_decimal(pricing["input_per_mtok"], f"{model_id} prompt price")
        if completion < yield_floor_completion_per_mtok:
            excluded.append({"model_id": model_id, "reason": f"completion yield {completion}/Mtok below floor {yield_floor_completion_per_mtok}/Mtok"})
            continue
        if demand < demand_floor_request_count_30m:
            excluded.append({"model_id": model_id, "reason": f"demand {demand} req/30m below floor {demand_floor_request_count_30m}"})
            continue
        verdict = servability.get("verdict")
        pipeline_tag = servability.get("pipeline_tag")
        is_multimodal_text = pipeline_tag in VISION_LANGUAGE_TEXT_TAGS or servability.get("serving_class") == "multimodal_text"
        if verdict == "review":
            serving_path = "text"
            servability_note = (servability.get("reasons") or [""])[0]
        elif verdict == "unresolved" and is_multimodal_text and servability.get("required_gb") is not None:
            # Vision-language model served for TEXT (Qwen3-VL / Gemma-3 families):
            # a top-yield earner in practice, not dropped for the VL pipeline tag.
            # required_gb already counts the vision tower, so the tier fit stays
            # conservative; the operator confirms the mlx-vlm text serving path.
            serving_path = "vision_language_text"
            servability_note = f"vision-language model ({pipeline_tag}) served for text via mlx-vlm; confirm the text serving path before pricing"
        else:
            excluded.append({"model_id": model_id, "reason": f"not servable ({verdict}): {(servability.get('reasons') or [''])[0]}"})
            continue
        try:
            required_gb = Decimal(str(servability.get("required_gb")))
        except (InvalidOperation, TypeError, ValueError):
            excluded.append({"model_id": model_id, "reason": "servability record has no numeric required_gb"})
            continue
        if not required_gb.is_finite() or required_gb <= 0:
            excluded.append({"model_id": model_id, "reason": f"servability required_gb is not a positive finite value ({required_gb})"})
            continue
        tier = assign_ram_tier(required_gb, tiers)
        if tier is None:
            excluded.append({"model_id": model_id, "reason": f"runtime residency {required_gb} GB exceeds largest tier {max(tiers)} GB"})
            continue
        selected.append({
            "model_id": model_id,
            "min_ram_gb_tier": tier,
            "required_residency_gb": decimal_string(required_gb),
            "serving_path": serving_path,
            "mlx_repo": servability.get("mlx_repo"),
            "quant": servability.get("quant"),
            "market_completion_per_mtok": pricing["completion_per_mtok"],
            "market_input_per_mtok": pricing["input_per_mtok"],
            "proposed_completion_per_mtok": decimal_string(completion * (Decimal("1") - undercut)),
            "proposed_input_per_mtok": decimal_string(prompt * (Decimal("1") - undercut)),
            "benchmark_provider": pricing["benchmark_provider"],
            "demand_request_count_30m": demand,
            "endpoint_count": int(record.get("endpoint_count") or 0),
            "servability_note": servability_note,
            # A proposal never assigns a rate_class or promotes a row: SPEC-023
            # §3.3.1 keeps the enum closed and §16 requires an explicit operator
            # decision. These machine-readable gates say so.
            "rate_class_required_before_promotion": True,
            "manual_serving_verification_required": serving_path == "vision_language_text",
        })
    selected.sort(key=lambda row: (row["min_ram_gb_tier"], -Decimal(row["market_completion_per_mtok"]), row["model_id"]))
    excluded.sort(key=lambda row: row["model_id"])
    return {
        "proposal_type": "openrouter-catalog-proposal",
        "schema_version": CATALOG_PROPOSAL_SCHEMA_VERSION,
        # Machine-readable: this artifact is a review input only. It is never a
        # signed feed, is never applied, and every recommendable promotion still
        # requires an explicit operator decision (SPEC-023 §16).
        "status": "proposal_only_never_applied",
        "generated_at": rfc3339(now),
        "generator_version": TOOL_VERSION,
        "policy_version": policy["policy_version"],
        "selection": {
            "undercut_fraction": decimal_string(undercut),
            "yield_floor_completion_per_mtok": decimal_string(yield_floor_completion_per_mtok),
            "demand_floor_request_count_30m": demand_floor_request_count_30m,
            "ram_tiers_gb": [int(t) for t in sorted(tiers)],
            "liquidity_signal": "openrouter_request_count_last_30m",
        },
        "selected": selected,
        "excluded": excluded,
    }


CATALOG_PROPOSAL_TOP_KEYS = frozenset({
    "proposal_type", "schema_version", "status", "generated_at", "generator_version",
    "policy_version", "selection", "selected", "excluded",
})
CATALOG_PROPOSAL_SELECTED_KEYS = frozenset({
    "model_id", "min_ram_gb_tier", "required_residency_gb", "serving_path", "mlx_repo",
    "quant", "market_completion_per_mtok", "market_input_per_mtok",
    "proposed_completion_per_mtok", "proposed_input_per_mtok", "benchmark_provider",
    "demand_request_count_30m", "endpoint_count", "servability_note",
    "rate_class_required_before_promotion", "manual_serving_verification_required",
})


def validate_catalog_proposal(proposal: Mapping[str, Any]) -> None:
    """Closed-schema validation of a catalog proposal artifact (fail-closed).

    A proposal is a review input, never a signed/applied feed. This rejects
    unknown fields and malformed rows so downstream automation cannot mistake a
    drifted artifact for a valid one."""
    if not isinstance(proposal, dict) or set(proposal) != CATALOG_PROPOSAL_TOP_KEYS:
        raise SchemaError("catalog proposal has missing or unexpected top-level fields")
    if proposal["proposal_type"] != "openrouter-catalog-proposal" or proposal["schema_version"] != CATALOG_PROPOSAL_SCHEMA_VERSION:
        raise SchemaError("catalog proposal type/schema_version is invalid")
    if proposal["status"] != "proposal_only_never_applied":
        raise SchemaError("catalog proposal status must be proposal_only_never_applied")
    if not isinstance(proposal["selected"], list) or not isinstance(proposal["excluded"], list):
        raise SchemaError("catalog proposal selected/excluded must be arrays")
    for index, row in enumerate(proposal["selected"]):
        if not isinstance(row, dict) or set(row) != CATALOG_PROPOSAL_SELECTED_KEYS:
            raise SchemaError(f"catalog proposal selected[{index}] has missing or unexpected fields")
        if not isinstance(row["model_id"], str) or not MODEL_ID_RE.fullmatch(row["model_id"]):
            raise SchemaError(f"catalog proposal selected[{index}].model_id is invalid")
        if row["serving_path"] not in {"text", "vision_language_text"}:
            raise SchemaError(f"catalog proposal selected[{index}].serving_path is invalid")
        if row["rate_class_required_before_promotion"] is not True:
            raise SchemaError(f"catalog proposal selected[{index}] must require a rate_class before promotion")
        if row["serving_path"] == "vision_language_text" and row["manual_serving_verification_required"] is not True:
            raise SchemaError(f"catalog proposal selected[{index}] vision_language_text row must require manual serving verification")
        for field in ("proposed_completion_per_mtok", "market_completion_per_mtok"):
            parse_decimal(row.get(field), f"catalog proposal selected[{index}].{field}", allow_zero=True)
        if isinstance(row["min_ram_gb_tier"], bool) or not isinstance(row["min_ram_gb_tier"], int) or row["min_ram_gb_tier"] < 1:
            raise SchemaError(f"catalog proposal selected[{index}].min_ram_gb_tier is invalid")
    for index, row in enumerate(proposal["excluded"]):
        if not isinstance(row, dict) or set(row) != {"model_id", "reason"}:
            raise SchemaError(f"catalog proposal excluded[{index}] has missing or unexpected fields")


def fetch_catalog_records(
    candidate_ids: Sequence[str],
    policy: Mapping[str, Any],
    *,
    or_client: HTTPClient,
    servability_resolver: Callable[[str, Decimal], Mapping[str, Any]],
    tiers: Sequence[int] = CATALOG_RAM_TIERS_GB,
    retries: int = 2,
    timeout_seconds: float = 15.0,
    sleeper: Callable[[float], None] = time.sleep,
    clock: Callable[[], float] = time.monotonic,
    generation_timeout_seconds: float = 1800.0,
) -> list[dict[str, Any]]:
    """Network stage: per candidate, fetch OpenRouter endpoints -> request-weighted
    price + demand gauge, and resolve MLX servability/residency. A per-candidate
    error is recorded in the record (surfaced in the proposal's excluded trail),
    never aborting the whole scan -- a proposal is reviewed by a human."""
    min_endpoint_requests = policy.get("min_endpoint_request_count_30m", 1)
    max_residency = Decimal(str(max(tiers)))
    deadline = clock() + generation_timeout_seconds
    records: list[dict[str, Any]] = []
    for model_id in candidate_ids:
        record: dict[str, Any] = {"model_id": model_id, "pricing": None, "demand_request_count_30m": 0, "endpoint_count": 0, "servability": {}}
        if clock() >= deadline:
            # The wall-clock budget is exhausted; record the remaining candidates
            # as skipped (surfaced in the proposal's excluded trail) rather than
            # running unbounded OpenRouter + HuggingFace probes past the budget.
            record["servability"] = {"verdict": "error", "reasons": ["scan budget exhausted before this candidate was probed"]}
            records.append(record)
            continue
        url = ENDPOINTS_URL.format(model_id=quote(model_id, safe="/"))
        try:
            document = fetch_json(or_client, url, f"endpoints {model_id}", retries=retries, timeout_seconds=timeout_seconds, sleeper=sleeper, deadline=deadline, clock=clock)
            record["demand_request_count_30m"] = model_demand_activity(document)
            data = document.get("data") if isinstance(document, dict) else None
            endpoints = data.get("endpoints") if isinstance(data, dict) else None
            record["endpoint_count"] = len(endpoints) if isinstance(endpoints, list) else 0
            record["pricing"] = cheapest_endpoint_pricing(document, model_id, min_request_count_30m=min_endpoint_requests)
        except EngineError as error:
            record["servability"] = {"verdict": "error", "reasons": [f"OpenRouter endpoint pricing failed: {error}"]}
            records.append(record)
            continue
        if clock() >= deadline:
            record["servability"] = {"verdict": "error", "reasons": ["scan budget exhausted before the servability probe"]}
            records.append(record)
            continue
        try:
            record["servability"] = dict(servability_resolver(model_id, max_residency))
        except Exception as error:  # servability probe is best-effort; surface, don't abort
            record["servability"] = {"verdict": "error", "reasons": [f"servability probe failed: {type(error).__name__}: {error}"]}
        records.append(record)
    return records


def command_propose(args: argparse.Namespace) -> int:
    policy = load_json_file(Path(args.policy), "policy")
    validate_policy(policy)
    if not os.environ.get("OPENROUTER_API_KEY"):
        raise FetchError("OPENROUTER_API_KEY is required for the documented OpenRouter APIs")
    # Always pull /models to build the id -> hugging_face_id map: the resolver
    # uses the canonical HF id as its servability search stem (OpenRouter slugs
    # and HF repo names diverge, e.g. mistral-small-2603 vs Mistral-Small-4-119B).
    catalog = fetch_json(UrllibHTTPClient(), MODELS_URL, "models catalog", retries=args.retries, timeout_seconds=args.timeout_seconds, sleeper=time.sleep, deadline=time.monotonic() + 120, clock=time.monotonic)
    catalog_rows = [row for row in catalog.get("data", []) if isinstance(row, dict) and isinstance(row.get("id"), str)]
    hf_id_by_model = {row["id"]: row.get("hugging_face_id") for row in catalog_rows}
    if args.candidates:
        loaded = json.loads(Path(args.candidates).read_text(encoding="utf-8"))
        candidate_ids = loaded["models"] if isinstance(loaded, dict) else loaded
        if not isinstance(candidate_ids, list) or not all(isinstance(m, str) for m in candidate_ids):
            raise SchemaError("candidates file must be a JSON list of model ids or {\"models\": [...]}")
        candidate_ids = sorted(dict.fromkeys(candidate_ids))
    else:
        candidate_ids = select_open_weight_candidates(row["id"] for row in catalog_rows)
    # Every candidate must be a well-formed OpenRouter model id BEFORE it reaches
    # URL construction: the host stays pinned, but this also constrains the path
    # to the documented {provider}/{model} shape (no extra-slash injection).
    for model_id in candidate_ids:
        if not MODEL_ID_RE.fullmatch(model_id):
            raise SchemaError(f"candidate model id has unsafe shape: {model_id!r}")
    if not candidate_ids:
        raise SchemaError("no candidate models to propose")
    if len(candidate_ids) > args.max_candidates:
        raise SchemaError(f"candidate universe {len(candidate_ids)} exceeds --max-candidates {args.max_candidates}; narrow the candidate set")
    import openrouter_mlx_candidates as mlx  # lazy: servability resolver, avoids import cycle
    hf_client = mlx.real_client(args.hf_timeout_seconds)
    def resolver(model_id: str, max_residency: Decimal) -> Mapping[str, Any]:
        return mlx.resolve_row(model_id, max_residency, hf_client, hugging_face_id=hf_id_by_model.get(model_id))
    records = fetch_catalog_records(
        candidate_ids, policy,
        or_client=UrllibHTTPClient(),
        servability_resolver=resolver,
        retries=args.retries,
        timeout_seconds=args.timeout_seconds,
        generation_timeout_seconds=args.generation_timeout_seconds,
    )
    proposal = build_catalog_proposal(
        records, policy,
        now=utc_now(),
        yield_floor_completion_per_mtok=parse_decimal(args.yield_floor_per_mtok, "yield floor", allow_zero=True),
        demand_floor_request_count_30m=args.demand_floor_request_count,
    )
    validate_catalog_proposal(proposal)
    output_dir = Path(args.output_dir)
    name = f"openrouter-catalog-proposal-{proposal['generated_at'].replace(':', '-')}.json"
    atomic_publish_json_directory(output_dir, {name: proposal})
    print(output_dir / name)
    return 0


def parser() -> argparse.ArgumentParser:
    result = argparse.ArgumentParser(description=__doc__)
    subcommands = result.add_subparsers(dest="command", required=True)
    fetch = subcommands.add_parser("fetch", help="fetch and validate a live OpenRouter snapshot")
    fetch.add_argument("--policy", default=str(DEFAULT_POLICY_PATH))
    fetch.add_argument("--output-dir", required=True)
    fetch.add_argument("--top-n", type=int, default=50)
    fetch.add_argument("--demand-window-days", type=int, default=30)
    fetch.add_argument("--retries", type=int, default=3)
    fetch.add_argument("--timeout-seconds", type=float, default=20.0)
    fetch.add_argument("--generation-timeout-seconds", type=float, default=900.0)
    fetch.set_defaults(handler=command_fetch)
    compute = subcommands.add_parser("compute", help="compute a proposal from a validated snapshot")
    compute.add_argument("--snapshot", required=True)
    compute.add_argument("--policy", default=str(DEFAULT_POLICY_PATH))
    compute.add_argument("--rate-card", required=True)
    compute.add_argument("--candidate-catalog", default=str(PRODUCTION_CATALOG_PATH))
    compute.add_argument("--min-provider-targets", required=True)
    compute.add_argument("--output-dir", required=True)
    compute.set_defaults(handler=command_compute)
    propose = subcommands.add_parser("propose", help="propose a best-in-class servable catalog by yield-first by-id scan")
    propose.add_argument("--policy", default=str(DEFAULT_POLICY_PATH))
    propose.add_argument("--output-dir", required=True)
    propose.add_argument("--candidates", default=None, help="JSON file of model ids to consider; omit to pull+filter the OpenRouter models catalog")
    propose.add_argument("--yield-floor-per-mtok", default="0.30", help="minimum request-weighted completion price ($/Mtok) to select")
    propose.add_argument("--demand-floor-request-count", type=int, default=500, help="minimum summed 30m request_count to select")
    propose.add_argument("--retries", type=int, default=2)
    propose.add_argument("--timeout-seconds", type=float, default=15.0)
    propose.add_argument("--hf-timeout-seconds", type=float, default=15.0)
    propose.add_argument("--max-candidates", type=int, default=200, help="hard cap on candidates scanned (bounds OpenRouter+HF probes)")
    propose.add_argument("--generation-timeout-seconds", type=float, default=1800.0, help="overall wall-clock budget for the scan")
    propose.set_defaults(handler=command_propose)
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
