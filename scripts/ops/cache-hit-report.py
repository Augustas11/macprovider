#!/usr/bin/env python3
"""Read operator-only coordinator cache telemetry; never contact providers.

Example: MACPROVIDER_OPERATOR_TOKEN=... cache-hit-report.py --coordinator URL
History is bounded and volatile. Rates cover observed adjacent samples only;
process restarts and missing baselines are excluded rather than counted as misses.
"""

import argparse
from datetime import datetime, timedelta, timezone
import json
import os
import sys
from urllib.parse import urlencode, urlsplit
from urllib.request import HTTPRedirectHandler, Request, build_opener


class NoRedirect(HTTPRedirectHandler):
    def redirect_request(self, request, fp, code, message, headers, new_url):
        # Operator credentials belong only to the explicitly selected origin.
        return None


urlopen = build_opener(NoRedirect()).open


def timestamp(value):
    return datetime.fromisoformat(value.replace("Z", "+00:00"))


def summarize(providers, window_seconds, now=None):
    now = now or datetime.now(timezone.utc)
    cutoff = now - timedelta(seconds=window_seconds)
    totals = {}
    excluded = 0
    for provider in providers:
        samples = sorted(provider.get("conversation_cache_history") or [],
                         key=lambda sample: timestamp(sample["observed_at"]))
        for before, after in zip(samples, samples[1:]):
            start, end = timestamp(before["observed_at"]), timestamp(after["observed_at"])
            # Never include traffic preceding the requested window or guess
            # how traffic was distributed across a partially observed interval.
            if start < cutoff or end > now or end <= start:
                continue
            if not before.get("process_id") or before["process_id"] != after.get("process_id"):
                excluded += 1
                continue
            old_models = {model["model_id"]: model for model in before.get("models", [])}
            for model in after.get("models", []):
                model_id = model["model_id"]
                old = old_models.get(model_id)
                if old is None:
                    excluded += 1
                    continue
                scalars = ("lookups", "hits", "cached_prompt_tokens")
                delta = {key: model.get(key, 0) - old.get(key, 0) for key in scalars}
                reasons = {}
                for key in ("misses", "evictions"):
                    previous, current = old.get(key, {}), model.get(key, {})
                    reasons[key] = {reason: current.get(reason, 0) - previous.get(reason, 0)
                                    for reason in previous.keys() | current.keys()}
                if any(value < 0 for value in delta.values()) or any(
                        value < 0 for group in reasons.values() for value in group.values()):
                    excluded += 1
                    continue
                row = totals.setdefault(model_id, dict(lookups=0, hits=0, cached_prompt_tokens=0,
                                                      misses={}, evictions={}, providers=set(),
                                                      observed_start=start, observed_end=end,
                                                      provider_seconds=0))
                for key, value in delta.items():
                    row[key] += value
                for key, group in reasons.items():
                    for reason, value in group.items():
                        row[key][reason] = row[key].get(reason, 0) + value
                row["providers"].add(provider["provider_id"])
                row["observed_start"] = min(row["observed_start"], start)
                row["observed_end"] = max(row["observed_end"], end)
                row["provider_seconds"] += (end - start).total_seconds()
    result = []
    for model_id, row in sorted(totals.items()):
        row["model_id"] = model_id
        row["providers"] = sorted(row["providers"])
        row["observed_start"] = row["observed_start"].isoformat()
        row["observed_end"] = row["observed_end"].isoformat()
        row["hit_rate"] = row["hits"] / row["lookups"] if row["lookups"] else None
        row["cached_tokens_per_request"] = (row["cached_prompt_tokens"] / row["lookups"]
                                            if row["lookups"] else None)
        result.append(row)
    return dict(window_seconds=window_seconds, models=result, excluded_intervals=excluded,
                coverage="observed intervals only; bounded volatile coordinator history; "
                         "no traffic inferred across process resets or missing baselines")


def fetch_providers(base, token):
    parsed = urlsplit(base)
    if parsed.scheme not in ("http", "https") or not parsed.netloc or parsed.username or parsed.password:
        raise ValueError("coordinator must be an HTTP(S) origin without credentials")
    if parsed.scheme == "http" and parsed.hostname not in ("localhost", "127.0.0.1", "::1"):
        raise ValueError("remote coordinator requires HTTPS")
    providers, seen = [], set()
    query = {"cache_history": "1"}
    while True:
        url = base.rstrip("/") + "/admin/providers"
        if query:
            url += "?" + urlencode(query)
        request = Request(url, headers={"Authorization": "Bearer " + token})
        with urlopen(request, timeout=20) as response:
            page = json.load(response)
        providers.extend(page.get("providers", []))
        cursor = (page.get("next_after"), page.get("next_after_seen"))
        if not cursor[0]:
            return providers
        if cursor in seen:
            raise ValueError("coordinator repeated pagination cursor")
        seen.add(cursor)
        query = dict(cache_history="1", after=cursor[0], after_seen=cursor[1])


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--coordinator", required=True, help="coordinator origin (operator endpoint)")
    parser.add_argument("--window-seconds", type=int, default=3600)
    parser.add_argument("--json", action="store_true", help="emit machine-readable report")
    args = parser.parse_args()
    if args.window_seconds <= 0 or args.window_seconds > 86400:
        parser.error("window must be between 1 and 86400 seconds")
    token = os.environ.get("MACPROVIDER_OPERATOR_TOKEN")
    if not token:
        parser.error("set MACPROVIDER_OPERATOR_TOKEN")
    try:
        report = summarize(fetch_providers(args.coordinator, token), args.window_seconds)
    except Exception as error:
        # Avoid echoing URL/header credentials from transport exceptions.
        print("cache report failed: " + type(error).__name__, file=sys.stderr)
        return 1
    if args.json:
        print(json.dumps(report, sort_keys=True, indent=2))
        return 0
    print(report["coverage"])
    for row in report["models"]:
        rate = f'{row["hit_rate"]:.2%}' if row["hit_rate"] is not None else "n/a"
        tokens = (f'{row["cached_tokens_per_request"]:.2f}'
                  if row["cached_tokens_per_request"] is not None else "n/a")
        print(f'{json.dumps(row["model_id"])}: hit_rate={rate} cached_tokens/request={tokens} '
              f'lookups={row["lookups"]} hits={row["hits"]} '
              f'observed={row["observed_start"]}..{row["observed_end"]} '
              f'provider_seconds={row["provider_seconds"]:g}')
        print("  misses=" + json.dumps(row["misses"], sort_keys=True))
        print("  evictions=" + json.dumps(row["evictions"], sort_keys=True))
    if not report["models"]:
        print("No paired telemetry samples in this window; rates unavailable.")
    print(f'excluded_intervals={report["excluded_intervals"]}')
    return 0


if __name__ == "__main__":
    sys.exit(main())
