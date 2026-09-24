# Provider-owner revenue benchmark (offline parts)

Issue #1734. These files define the workload and compute revenue from evidence
that already exists. They never send traffic and never change autotune
recommendations.

## Workload

`coding_agent_workload_v1.json` is the fixed coding-agent workload. It has 9
non-streaming, temperature-0 cases (debug, tests, implement, refactor, review,
and one multi-file agent-loop step). Five cases have a completion floor of 512
tokens or more; the agent-loop case needs 1024 or more.

`scripts/revenue_benchmark_workload.py` pins the canonical SHA-256 of each
version. If you edit v1 in place, loading fails. Add a new version file and pin
it instead.

```bash
python3 scripts/revenue_benchmark_workload.py digest
python3 scripts/revenue_benchmark_workload.py plan --run-id rb-20260924-a \
  --candidate incumbent=<model> --candidate challenger=<model>
```

`plan` prints one JSONL request per candidate, case, and repetition, with a
deterministic run-scoped `X-Request-ID`. Every candidate gets the same cases.

## Revenue calculator

`scripts/revenue_benchmark_calculator.py` reads a run manifest
(`malibu.revenue_benchmark_run.v1`, fixture in
`scripts/tests/fixtures/revenue_benchmark/run_manifest.json`) and read-only
copies of the coordinator and gateway databases.

```bash
python3 scripts/revenue_benchmark_calculator.py --manifest run.json \
  --coordinator-db coordinator.db --gateway-db gateway.db \
  [--route-journal-db coordinator.db.route-snapshots] [--now 2026-09-24T12:00:00Z]
```

The manifest must list every planned request for `repetitions` × candidates ×
cases. Failed requests stay in the manifest and earn zero. Omitting them is
rejected, because it would hide the failure rate.

A row counts toward revenue only when all of the following hold. Every other
row earns zero and is counted under its exclusion reason:

- `classify_benchmark_evidence.py` marks it `complete` against the candidate's
  expected provider.
- Its `request_log` timestamps fall inside the candidate's declared
  `started_at`..`finished_at` window.
- It has exactly one attempt.
- The ledger model matches the candidate model.
- Usage is `provider_reported`, has no fault, and is not quarantined.
- Ledger prompt plus completion tokens equal the gateway usage.
- The completion reaches the case floor.
- The stored gross and provider credits equal SPEC-005 credits recomputed from
  the row's own rates, `global_multiplier_ppm`, and `provider_share_bps`.
  The formula mirrors `billing.ComputeCreditsWithCache`, and its Go worked
  examples are pinned in the tests.

A row whose evidence cannot be read (malformed JSON, a missing key, a missing
table) is excluded as `evidence_unreadable:<error>`. It does not abort the run.

### Cache-hit rate

The ledger does not store the cache-hit rate. A candidate with cached prompt
rows must declare `prompt_cache_hit_rate_per_mtok` in the manifest, taken from
the rate card in effect during the run. If the rate card sets no cache-hit
rate, billing charges cached tokens at the full prompt rate, so declare the
prompt rate. A missing or wrong value excludes the affected rows. The declared
value is echoed in the report.

### Report

Per candidate, the report gives token and credit totals, provider USDC
(1 credit = 1 USDC base unit), and USDC per day over the candidate's whole run
window. USDC per day is serial benchmark throughput scaled to a day, not a
demand forecast.

`comparable` is false when either of these holds:

- Payout terms changed during the run.
- A candidate has no counted row for some workload case.
