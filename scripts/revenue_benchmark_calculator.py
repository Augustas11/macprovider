#!/usr/bin/env python3
"""Compute provider-owner revenue from benchmark-complete evidence only (issue #1734).

Reads a benchmark run manifest plus read-only coordinator/gateway SQLite
copies. Every manifest row is classified with classify_benchmark_evidence.py;
only rows it marks "complete" that also pass the ledger cross-checks below
enter the revenue arithmetic. Pending, incomplete, and malformed rows are
counted by reason and contribute zero. Offline only: sends no traffic and does
not produce an autotune recommendation.
"""

import argparse
import importlib.util
import json
import sqlite3
import sys
from collections import Counter
from contextlib import ExitStack, closing
from decimal import Decimal
from pathlib import Path

HERE = Path(__file__).resolve().parent
RUN_SCHEMA = "malibu.revenue_benchmark_run.v1"
REPORT_SCHEMA = "malibu.revenue_benchmark_report.v1"
EVIDENCE_BOUNDARY = "live_buyer_path_benchmark_complete_rows_only"
USDC_BASE_UNITS = Decimal(1_000_000)
MULTIPLIER_DENOM = 1_000_000
TOKENS_PER_MILLION = 1_000_000
SHARE_DENOM = 10_000
SECONDS_PER_DAY = 86_400


def _load(name, filename):
    spec = importlib.util.spec_from_file_location(name, HERE / filename)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


classifier = _load("classify_benchmark_evidence", "classify_benchmark_evidence.py")
workload_lib = _load("revenue_benchmark_workload", "revenue_benchmark_workload.py")


def round_half_even(numerator, denominator):
    """Integer mirror of billing.RoundHalfEven for non-negative operands."""
    q, r = divmod(numerator, denominator)
    twice = 2 * r
    if twice > denominator or (twice == denominator and q % 2 == 1):
        return q + 1
    return q


def expected_credits(credit, cache_hit_rate):
    """Recompute SPEC-005 gross/provider credits from the ledger row's own terms.

    Mirrors billing.ComputeCreditsWithCache (phase4-coordinator/internal/billing/formula.go)
    for provider_reported rows; its worked examples are pinned in the calculator tests.
    """
    prompt = credit["prompt_tokens"]
    cached = credit["cached_prompt_tokens"] or 0
    base = ((prompt - cached) * credit["prompt_rate_per_mtok"]
            + cached * cache_hit_rate
            + credit["completion_tokens"] * credit["completion_rate_per_mtok"])
    gross = round_half_even(base * credit["global_multiplier_ppm"], MULTIPLIER_DENOM * TOKENS_PER_MILLION)
    return gross, round_half_even(gross * credit["provider_share_bps"], SHARE_DENOM)


def usdc(credits):
    return str((Decimal(credits) / USDC_BASE_UNITS).quantize(Decimal("0.000001")))


def usdc_per_day(credits, seconds):
    """Earned USDC scaled to a day over the candidate's whole run, so excluded
    and failed rows count as zero-revenue time rather than vanishing."""
    return usdc(Decimal(credits) * SECONDS_PER_DAY / Decimal(str(seconds)))


def is_int(value):
    return isinstance(value, int) and not isinstance(value, bool)


def request_log_rows(coordinator, account_id, request_id):
    """Return [(ts_utc, latency_seconds)] for every coordinator attempt of one buyer request."""
    return [(classifier.parse_utc(r["ts_utc"]), max(0.0, float(r["latency_ms"])) / 1000) for r in coordinator.execute(
        "SELECT ts_utc, latency_ms FROM request_log WHERE account_id = ? AND external_request_id = ?",
        (account_id, request_id))]


def ledger_credit(coordinator, receipt_scope, attempt):
    return coordinator.execute(
        """SELECT model, prompt_tokens, cached_prompt_tokens, completion_tokens, usage_source, fault_flag,
                  quarantined, prompt_rate_per_mtok, completion_rate_per_mtok, global_multiplier_ppm,
                  gross_credits, provider_share_bps, provider_credits
             FROM ledger_request_credits
            WHERE settlement_account_scope_hash = ? AND request_id = ? AND attempt_n = ? AND provider_id = ?
            ORDER BY id DESC LIMIT 1""",
        (receipt_scope, attempt["internal_request_id"], attempt["attempt_n"], attempt["provider_id"]),
    ).fetchone()


def evaluate_row(candidate, case, evidence, coordinator, receipt_scope, log_rows):
    """Return (reasons, economics). Empty reasons means the row counts toward revenue."""
    if evidence["classification"] != "complete":
        return [evidence["classification"]], None
    if not log_rows or any(t < candidate["started"] or t > candidate["finished"] for t, _ in log_rows):
        return ["outside_candidate_window"], None
    if len(evidence["attempts"]) != 1:
        return ["multiple_attempts"], None
    credit = ledger_credit(coordinator, receipt_scope, evidence["attempts"][0])
    if credit is None:
        return ["ledger_credit_missing"], None
    reasons = []
    if credit["model"] != candidate["model"]:
        reasons.append("candidate_model_mismatch")
    if credit["usage_source"] != "provider_reported" or credit["fault_flag"] != "none" or credit["quarantined"]:
        reasons.append("ledger_usage_not_clean")
    if credit["prompt_tokens"] is None or credit["completion_tokens"] is None:
        return reasons + ["ledger_usage_missing"], None
    if credit["prompt_tokens"] + credit["completion_tokens"] != evidence["gateway_usage_tokens"]:
        reasons.append("ledger_gateway_usage_mismatch")
    if credit["completion_tokens"] < case["min_completion_tokens"]:
        reasons.append("completion_below_case_floor")
    cached = credit["cached_prompt_tokens"] or 0
    cache_rate = candidate.get("prompt_cache_hit_rate_per_mtok")
    if cached and cache_rate is None:
        reasons.append("cache_hit_rate_undeclared")
    elif expected_credits(credit, cache_rate or 0) != (credit["gross_credits"], credit["provider_credits"]):
        reasons.append("credit_formula_mismatch")
    economics = {
        "prompt_tokens": credit["prompt_tokens"],
        "cached_prompt_tokens": cached,
        "completion_tokens": credit["completion_tokens"],
        "gross_credits": credit["gross_credits"],
        "provider_credits": credit["provider_credits"],
        "payout_terms": (credit["global_multiplier_ppm"], credit["provider_share_bps"]),
    }
    return reasons, economics


def validate_manifest(manifest, doc):
    if manifest.get("schema") != RUN_SCHEMA:
        raise ValueError("manifest schema must be " + RUN_SCHEMA)
    if manifest.get("workload") != workload_lib.identity(doc):
        raise ValueError("manifest workload does not match the pinned workload identity")
    run_id = manifest.get("run_id")
    if not isinstance(run_id, str) or not workload_lib.RUN_ID_RE.match(run_id):
        raise ValueError("manifest run_id is invalid")
    if not isinstance(manifest.get("account_id"), str) or not manifest["account_id"].strip():
        raise ValueError("manifest account_id is required")
    repetitions = manifest.get("repetitions")
    if not is_int(repetitions) or repetitions < 1:
        raise ValueError("manifest repetitions must be a positive integer")
    if not isinstance(manifest.get("candidates"), list) or not isinstance(manifest.get("requests"), list):
        raise ValueError("manifest candidates and requests must be lists")
    candidates = {}
    for candidate in manifest["candidates"]:
        cid = candidate.get("candidate_id") if isinstance(candidate, dict) else None
        if not isinstance(cid, str) or cid in candidates or not workload_lib.SLUG_RE.match(cid):
            raise ValueError("candidate ids must be unique slugs")
        for key in ("model", "expected_provider_id", "started_at", "finished_at"):
            if not isinstance(candidate.get(key), str) or not candidate[key]:
                raise ValueError("candidate {} missing {}".format(cid, key))
        started = classifier.parse_utc(candidate["started_at"])
        finished = classifier.parse_utc(candidate["finished_at"])
        if finished <= started:
            raise ValueError("candidate {} window must be positive".format(cid))
        rate = candidate.get("prompt_cache_hit_rate_per_mtok")
        if rate is not None and (not isinstance(rate, int) or isinstance(rate, bool) or rate < 0):
            raise ValueError("candidate {} prompt_cache_hit_rate_per_mtok must be a non-negative integer".format(cid))
        candidates[cid] = dict(candidate, started=started, finished=finished,
                               window_seconds=(finished - started).total_seconds())
    if not candidates:
        raise ValueError("manifest has no candidates")
    cases = workload_lib.cases_by_id(doc)
    seen = set()
    for row in manifest["requests"]:
        if not isinstance(row, dict):
            raise ValueError("manifest requests must be objects")
        cid, case_id, rep, rid = row.get("candidate_id"), row.get("case_id"), row.get("repetition"), row.get("request_id")
        if (not isinstance(cid, str) or cid not in candidates or not isinstance(case_id, str)
                or case_id not in cases or not is_int(rep) or not 0 <= rep < repetitions):
            raise ValueError("request {} has unknown candidate, case, or repetition".format(rid))
        if rid != workload_lib.request_id(doc, run_id, cid, case_id, rep):
            raise ValueError("request {} is not the planned run-scoped request id".format(rid))
        if (cid, case_id, rep) in seen:
            raise ValueError("request {} appears more than once".format(rid))
        seen.add((cid, case_id, rep))
    # Failed requests stay in the manifest as zero-revenue rows; omitting them
    # would hide the failure rate.
    missing = len(candidates) * len(cases) * repetitions - len(seen)
    if missing:
        raise ValueError("manifest omits {} planned request(s); list every planned request".format(missing))
    return candidates, cases


def calculate(manifest, coordinator, gateway, journal=None, now=None, doc=None):
    workload = manifest.get("workload")
    doc = doc or workload_lib.load(workload.get("version") if isinstance(workload, dict) else None)
    candidates, cases = validate_manifest(manifest, doc)
    _, receipt_scope = classifier.evidence_scopes(manifest["account_id"])
    totals = {cid: {"attempted": 0, "counted": 0, "excluded": Counter(), "prompt_tokens": 0,
                    "cached_prompt_tokens": 0, "completion_tokens": 0, "gross_credits": 0,
                    "provider_credits": 0, "busy_seconds": 0.0, "payout_terms": set(), "cases_counted": set()}
              for cid in candidates}
    rows = []
    for row in manifest["requests"]:
        candidate, case = candidates[row["candidate_id"]], cases[row["case_id"]]
        try:
            evidence = classifier.classify(coordinator, gateway, manifest["account_id"], row["request_id"],
                                           journal, now=now, expected_provider_id=candidate["expected_provider_id"])
            log_rows = request_log_rows(coordinator, manifest["account_id"], row["request_id"])
        except ValueError as exc:
            if not str(exc).startswith("no successful provider-bound request"):
                evidence = {"classification": "evidence_unreadable:" + type(exc).__name__, "missing": [], "pending": []}
            else:
                evidence = {"classification": "no_successful_provider_request", "missing": [], "pending": []}
            log_rows = []
        except (TypeError, KeyError, sqlite3.Error) as exc:
            evidence = {"classification": "evidence_unreadable:" + type(exc).__name__, "missing": [], "pending": []}
            log_rows = []
        reasons, economics = evaluate_row(candidate, case, evidence, coordinator, receipt_scope, log_rows)
        bucket = totals[row["candidate_id"]]
        bucket["attempted"] += 1
        bucket["busy_seconds"] += sum(latency for _, latency in log_rows)
        if reasons:
            bucket["excluded"].update(reasons)
        else:
            bucket["counted"] += 1
            bucket["cases_counted"].add(row["case_id"])
            bucket["payout_terms"].add(economics["payout_terms"])
            for key in ("prompt_tokens", "cached_prompt_tokens", "completion_tokens", "gross_credits", "provider_credits"):
                bucket[key] += economics[key]
        rows.append({
            "candidate_id": row["candidate_id"],
            "case_id": row["case_id"],
            "repetition": row["repetition"],
            "request_id": row["request_id"],
            "classification": evidence["classification"],
            "evidence_missing": evidence.get("missing", []),
            "evidence_pending": evidence.get("pending", []),
            "counted": not reasons,
            "excluded_reasons": sorted(set(reasons)),
            "provider_credits": economics["provider_credits"] if economics and not reasons else 0,
        })

    all_cases = set(cases)
    report_candidates = []
    all_terms = set()
    for cid, bucket in totals.items():
        candidate = candidates[cid]
        all_terms |= bucket["payout_terms"]
        report_candidates.append({
            "candidate_id": cid,
            "model": candidate["model"],
            "expected_provider_id": candidate["expected_provider_id"],
            "declared_prompt_cache_hit_rate_per_mtok": candidate.get("prompt_cache_hit_rate_per_mtok"),
            "attempted_rows": bucket["attempted"],
            "counted_rows": bucket["counted"],
            "excluded_rows_by_reason": dict(sorted(bucket["excluded"].items())),
            "cases_without_counted_rows": sorted(all_cases - bucket["cases_counted"]),
            "prompt_tokens": bucket["prompt_tokens"],
            "cached_prompt_tokens": bucket["cached_prompt_tokens"],
            "completion_tokens": bucket["completion_tokens"],
            "gross_credits": bucket["gross_credits"],
            "provider_credits": bucket["provider_credits"],
            "provider_usdc": usdc(bucket["provider_credits"]),
            "window_seconds": candidate["window_seconds"],
            "busy_seconds": round(bucket["busy_seconds"], 3),
            # The declared window cannot be shorter than the coordinator-recorded serial
            # busy time, so shrinking it cannot inflate the per-day figure.
            "provider_usdc_per_day_over_window": usdc_per_day(
                bucket["provider_credits"], max(candidate["window_seconds"], bucket["busy_seconds"])),
            "payout_terms": [{"global_multiplier_ppm": m, "provider_share_bps": s}
                             for m, s in sorted(bucket["payout_terms"])],
        })

    blockers = []
    if len(all_terms) > 1:
        blockers.append("payout_terms_changed_during_run")
    for entry in report_candidates:
        if entry["window_seconds"] < entry["busy_seconds"]:
            blockers.append("declared_window_shorter_than_busy_time:" + entry["candidate_id"])
        if entry["counted_rows"] == 0:
            blockers.append("candidate_without_counted_rows:" + entry["candidate_id"])
        elif entry["cases_without_counted_rows"]:
            blockers.append("candidate_missing_case_coverage:" + entry["candidate_id"])
    return {
        "schema": REPORT_SCHEMA,
        "evidence_boundary": EVIDENCE_BOUNDARY,
        "run_id": manifest["run_id"],
        "workload": workload_lib.identity(doc),
        "comparable": not blockers,
        "comparison_blockers": blockers,
        "candidates": report_candidates,
        "rows": rows,
    }


def main(argv=None):
    if sys.version_info < (3, 11):
        # Older fromisoformat rejects the coordinator's nanosecond ts_utc, which
        # would silently exclude every row as unreadable.
        raise SystemExit("revenue_benchmark_calculator.py requires Python 3.11+")
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--manifest", required=True, help="benchmark run manifest JSON")
    parser.add_argument("--coordinator-db", required=True)
    parser.add_argument("--gateway-db", required=True)
    parser.add_argument("--route-journal-db")
    parser.add_argument("--now", help="RFC3339 evaluation time; defaults to the current time")
    args = parser.parse_args(argv)
    with open(args.manifest, encoding="utf-8") as f:
        manifest = json.load(f)
    now = classifier.parse_utc(args.now) if args.now else None
    with ExitStack() as stack:
        coordinator = stack.enter_context(closing(classifier.open_readonly(args.coordinator_db)))
        gateway = stack.enter_context(closing(classifier.open_readonly(args.gateway_db)))
        journal = None
        if args.route_journal_db:
            journal = stack.enter_context(closing(classifier.open_readonly(args.route_journal_db)))
        report = calculate(manifest, coordinator, gateway, journal, now=now)
    print(json.dumps(report, sort_keys=True, indent=2))
    return 0


if __name__ == "__main__":
    sys.exit(main())
