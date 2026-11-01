#!/usr/bin/env python3
"""Count long-agent-session failure signatures in gateway and provider logs.

Reads log text from files or stdin; makes no network calls. Understands the
gateway's slog lines (text `key=value` or JSON) and the provider's
`event=... key=value` stderr lines. Signatures:

  decode_idle_cut            gateway `deadline_phase=decode_idle` (one per request)
  provider_timeout           any line naming provider_timeout (one per request)
  retry_429_after_timeout    a status=429 from the same account_id within the
                             window after one of that account's timeouts
  capture_skipped_ceiling    provider `action=capture_skipped
                             reason=exceeds_promotion_ceiling`
  conv_cache_empty_long_hit  consecutive long hits for the same key reusing
                             less than 90% of the prompt (legacy signature name)

Prints JSON with counts and example ids. With --fail-on-any, exits 1 when any
signature is present.
"""

from __future__ import annotations

import argparse
import json
import re
import sys
from datetime import datetime, timezone
from typing import Any, Iterable, Iterator

FIELD_RE = re.compile(r'(?:^|[\s{,])"?([A-Za-z_][\w.]*)"?\s*[=:]\s*("(?:[^"\\]|\\.)*"|[^\s,}]+)')
ISO_RE = re.compile(r"\d{4}-\d{2}-\d{2}[T ]\d{2}:\d{2}:\d{2}(?:\.\d+)?(?:Z|[+-]\d{2}:?\d{2})?")
GOLOG_RE = re.compile(r"\d{4}/\d{2}/\d{2} \d{2}:\d{2}:\d{2}(?:\.\d+)?")
SYSLOG_RE = re.compile(r"\b([A-Z][a-z]{2}) +(\d{1,2}) (\d{2}):(\d{2}):(\d{2})\b")
MONTHS = {m: i for i, m in enumerate(("Jan", "Feb", "Mar", "Apr", "May", "Jun", "Jul", "Aug", "Sep", "Oct", "Nov", "Dec"), 1)}
CLIENT_FIELDS = ("account_id", "client_id", "buyer_id", "api_key_id")
STATUS_FIELDS = ("status", "status_code", "http_status")
SIGNATURES = (
    "decode_idle_cut",
    "provider_timeout",
    "retry_429_after_timeout",
    "capture_skipped_ceiling",
    "conv_cache_empty_long_hit",
)
MAX_EXAMPLES = 5


def parse_fields(line: str) -> dict[str, str]:
    fields: dict[str, str] = {}
    for key, raw in FIELD_RE.findall(line):
        if raw.startswith('"'):
            try:
                raw = json.loads(raw)
            except json.JSONDecodeError:
                raw = raw[1:-1]
        fields.setdefault(key, str(raw))
    return fields


def parse_time(line: str, fields: dict[str, str]) -> float | None:
    for candidate in (fields.get("time"), fields.get("ts"), line):
        if not candidate:
            continue
        m = ISO_RE.search(candidate)
        if m:
            text = m.group(0).replace(" ", "T").replace("Z", "+00:00")
            try:
                dt = datetime.fromisoformat(text)
            except ValueError:
                continue
            if dt.tzinfo is None:
                dt = dt.replace(tzinfo=timezone.utc)
            return dt.timestamp()
        m = GOLOG_RE.search(candidate)
        if m:
            fmt = "%Y/%m/%d %H:%M:%S.%f" if "." in m.group(0) else "%Y/%m/%d %H:%M:%S"
            return datetime.strptime(m.group(0), fmt).replace(tzinfo=timezone.utc).timestamp()
        m = SYSLOG_RE.search(candidate)
        if m and m.group(1) in MONTHS:
            # journald short format has no year; deltas within a log stay correct.
            mon, day, hh, mm, ss = MONTHS[m.group(1)], int(m.group(2)), int(m.group(3)), int(m.group(4)), int(m.group(5))
            return datetime(2000, mon, day, hh, mm, ss, tzinfo=timezone.utc).timestamp()
    return None


def _int(value: str | None) -> int | None:
    try:
        return int(value) if value is not None else None
    except ValueError:
        return None


def _client(fields: dict[str, str]) -> str | None:
    for key in CLIENT_FIELDS:
        if fields.get(key):
            return fields[key]
    return None


def _status(fields: dict[str, str]) -> int | None:
    for key in STATUS_FIELDS:
        value = _int(fields.get(key))
        if value is not None:
            return value
    return None


def iter_lines(sources: Iterable[tuple[str, Iterable[str]]]) -> Iterator[tuple[str, int, str]]:
    for name, lines in sources:
        for lineno, line in enumerate(lines, 1):
            yield name, lineno, line.rstrip("\n")


def scan(sources: Iterable[tuple[str, Iterable[str]]], window_seconds: float = 60.0, long_prompt_tokens: int = 65536) -> dict[str, Any]:
    examples: dict[str, list[str]] = {s: [] for s in SIGNATURES}
    counts = {s: 0 for s in SIGNATURES}
    decode_idle: set[str] = set()
    provider_timeout: set[str] = set()
    timeouts: dict[str, float | None] = {}  # request_id -> earliest time
    statuses_429: dict[str, float | None] = {}
    client_of: dict[str, str] = {}
    low_reuse_by_key: dict[str, bool] = {}
    lines_scanned = 0

    def note(sig: str, ident: str) -> None:
        counts[sig] += 1
        if len(examples[sig]) < MAX_EXAMPLES and ident not in examples[sig]:
            examples[sig].append(ident)

    for name, lineno, line in iter_lines(sources):
        lines_scanned += 1
        if not line.strip():
            continue
        fields = parse_fields(line)
        rid = fields.get("request_id")
        ident = rid or fields.get("key_hash") or f"{name}:{lineno}"
        when = parse_time(line, fields)
        client = _client(fields)
        if rid and client:
            client_of.setdefault(rid, client)

        if fields.get("deadline_phase") == "decode_idle" or "deadline_phase=decode_idle" in line:
            key = rid or ident
            if key not in decode_idle:
                decode_idle.add(key)
                note("decode_idle_cut", ident)
            if rid:
                timeouts[rid] = when if timeouts.get(rid) is None else timeouts[rid]
        if re.search(r"\bprovider_timeout\b", line):
            key = rid or ident
            if key not in provider_timeout:
                provider_timeout.add(key)
                note("provider_timeout", ident)
            if rid:
                timeouts[rid] = when if timeouts.get(rid) is None else timeouts[rid]
        if _status(fields) == 429 and rid and rid not in statuses_429:
            statuses_429[rid] = when
        if fields.get("action") == "capture_skipped" and fields.get("reason") == "exceeds_promotion_ceiling":
            note("capture_skipped_ceiling", ident)
        if fields.get("event") == "conv_cache" and fields.get("action") == "hit":
            key = fields.get("key_hash")
            prompt = _int(fields.get("prompt_tokens"))
            cached = _int(fields.get("cached_prompt_tokens"))
            low_reuse = (prompt is not None and prompt > long_prompt_tokens and prompt > 0
                         and cached is not None and 0 <= cached < prompt * 0.9)
            # The active cache entry is leased out before a hit logs the
            # remaining entries. Zero is healthy for one active conversation.
            # Repeated static-prefix-only hits expose lost turn retention,
            # including the hit -> LRU eviction -> ceiling skip -> hit cycle.
            if key and low_reuse and low_reuse_by_key.get(key, False):
                note("conv_cache_empty_long_hit", ident)
            if key:
                low_reuse_by_key[key] = low_reuse
        elif fields.get("event") == "conv_cache" and fields.get("action") == "miss":
            # A miss breaks consecutive hits; LRU eviction between turns does
            # not, since that is precisely the retention failure being found.
            low_reuse_by_key.pop(fields.get("key_hash"), None)

    # A 429 counts once, against the most recent earlier timeout of the same client.
    timeout_events = sorted(
        (t, client_of[r], r) for r, t in timeouts.items() if t is not None and r in client_of
    )
    for rid, t429 in sorted(statuses_429.items(), key=lambda kv: (kv[1] is None, kv[1] or 0)):
        client = client_of.get(rid)
        if t429 is None or client is None:
            continue
        for t_out, c_out, rid_out in reversed(timeout_events):
            if c_out == client and rid_out != rid and 0 <= t429 - t_out <= window_seconds:
                note("retry_429_after_timeout", rid)
                break

    return {
        "lines_scanned": lines_scanned,
        "window_seconds": window_seconds,
        "long_prompt_tokens": long_prompt_tokens,
        "signatures": {s: {"count": counts[s], "examples": examples[s]} for s in SIGNATURES},
        "total": sum(counts.values()),
    }



def main(argv: list[str] | None = None) -> int:
    p = argparse.ArgumentParser(description=__doc__.split("\n\n")[0])
    p.add_argument("files", nargs="*", help="log files; stdin when none")
    p.add_argument("--window-seconds", type=float, default=60.0, help="429-after-timeout window")
    p.add_argument("--long-prompt-tokens", type=int, default=65536, help="conv_cache hits above this prompt size are checked")
    p.add_argument("--fail-on-any", action="store_true", help="exit 1 when any signature is found")
    args = p.parse_args(argv)
    handles = []
    try:
        if args.files:
            for path in args.files:
                handles.append((path, open(path, encoding="utf-8", errors="replace")))
        else:
            handles.append(("<stdin>", sys.stdin))
        result = scan(handles, args.window_seconds, args.long_prompt_tokens)
    except OSError as exc:
        print(f"error: {exc}", file=sys.stderr)
        return 2
    finally:
        for name, handle in handles:
            if handle is not sys.stdin:
                handle.close()
    print(json.dumps(result, indent=2))
    return 1 if args.fail_on_any and result["total"] else 0


if __name__ == "__main__":
    sys.exit(main())
