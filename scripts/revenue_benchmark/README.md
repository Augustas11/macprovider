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

A row counts toward revenue only when all of the following hold. Every other
row earns zero and is counted under its exclusion reason:

- `classify_benchmark_evidence.py` marks it `complete` against the candidate's
  expected provider.
- It has exactly one attempt.
- The ledger model matches the candidate model.
- Usage is `provider_reported`, has no fault, and is not quarantined.
- Ledger prompt plus completion tokens equal the gateway usage.
- The completion reaches the case floor.
- The stored gross and provider credits equal SPEC-005 credits recomputed from
  the row's own rates, `global_multiplier_ppm`, and `provider_share_bps`. A row
  with cached prompt tokens also needs a declared
  `prompt_cache_hit_rate_per_mtok`.

Per candidate, the report gives token and credit totals, provider USDC
(1 credit = 1 USDC base unit), and USDC per day over the candidate's whole run
window. `comparable` is false if any of these holds:

- Candidates attempted different case sets.
- Payout terms changed during the run.
- A candidate has no counted row for some workload case.
