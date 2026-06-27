# network-harness — internal e2e scenario runner

Phase-A descriptive harness for internal pre-beta validation of the
macprovider network. Fires a scenario-driven concurrent buyer fleet at
a running coordinator+gateway stack, captures structured artifacts, and
enforces four hard invariants that hold regardless of routing policy.

## Why this exists

Before opening external beta we need to:

1. Exercise the network with realistic concurrent buyer load against
   real providers (M1 + M4 today, more later).
2. Catch the failure modes that don't show up in unit tests or the
   existing `test/integration` happy-path scenarios — capacity
   exhaustion, mid-stream provider drops, multi-model routing fairness,
   billing drift under concurrency.
3. Produce evidence we can triage into a written routing-contract
   addendum to `SPEC-002`.

The harness is intentionally **descriptive**, not assertive, on routing
behavior. We run scenarios first, collect artifacts, then codify what
the network actually does into a contract. Only four hard invariants
fail-loud regardless of design — see below.

## Phase A → B → C flow

| Phase | What the harness does | Output |
|---|---|---|
| **A — discover** | Run scenarios, collect artifacts, fail only on the 4 hard invariants | `per_request.jsonl`, `metrics_summary.json`, `ledger_reconcile.json`, `invariants.json` |
| **B — codify** | (Human) triage artifacts → keep / fix / decide → write SPEC-002 routing-contract addendum | `specs/SPEC-002-routing-contract-addendum.md` |
| **C — regress** | Re-run with addendum clauses (`R-1`, `R-2`, …) cited in each scenario's `expected_shape`, now asserted | CI-gated |

We are in phase A.

## The four hard invariants

These fail the run (exit 10) regardless of any contract:

- **I1** — billing-ledger reconciliation drift == 0
  (no harness-successful request missing on coordinator request_log or gateway usage_events; coordinator and gateway agree on completion tokens)
- **I2** — no 5xx response without a billing settlement entry
  (gateway must echo a request id on every 5xx; orphaning is a billing-bypass risk)
- **I3** — no charged-tokens > delivered-tokens
  (phase-A structural check; the DB-level overcharge signal lives in `ledger_reconcile.json` → `token_mismatches`)
- **I4** — no silent hang
  (a streaming response that stays open past `silent_hang_threshold` with no bytes and no `data: [DONE]` is a UX failure regardless of what the contract says about latency)

Everything else (routing distribution, sticky behavior, capacity-exhaustion
error code, mid-stream failover) is **recorded** in phase A and **judged**
in phase B.

## Running

```
go build -o harness ./cmd/harness
./harness run scenarios/smoke.yaml --out artifacts/smoke-run-1
```

Exit codes:

| Code | Meaning |
|---|---|
| 0 | Scenario ran, all hard invariants passed |
| 1 | Runtime error (scenario malformed, gateway unreachable, DB unreadable) |
| 2 | Usage error |
| 10 | Scenario ran but one or more hard invariants failed — triage `invariants.json` |

## Pointing at different stacks

The harness does **not** spawn coordinator/gateway. Caller is responsible.
Three typical targets:

- **Local stack (synthetic provider)** — start via `test/integration`
  helpers or `make dev-stack`. Use `127.0.0.1` URLs and `/tmp` DB paths.
  Best for harness self-validation and fast iteration.
- **Local stack (real M-series provider)** — same coordinator+gateway,
  but with an actual `macprovider-cli serve` attached over WS. Catches
  real model timing / sleep / thermal quirks.
- **Pearl coordinator + remote providers** — full-fidelity. Leave
  `coordinator_db_path` / `gateway_db_path` unset; I1 will mark skipped
  (we don't read prod DBs from the harness machine). Other invariants
  still run.

## Artifact bundle

After a run, `--out` contains:

```
scenario.yaml          # verbatim copy of the input
run_meta.json          # scenario name, UTC window, git sha
per_request.jsonl      # one row per request — the raw evidence
metrics_summary.json   # aggregated histograms + route distribution
ledger_reconcile.json  # three-way drift report (omitted when skipped)
invariants.json        # the 4 hard verdicts
```

For phase-B triage, the artifact bundle is the input. Read
`metrics_summary.json` for routing distribution and latency shape;
`ledger_reconcile.json` for billing drift; `per_request.jsonl` for any
case the summaries elide.

## Scenario YAML

See [`scenarios/smoke.yaml`](scenarios/smoke.yaml) for the minimal example
and [`internal/scenario/schema.go`](internal/scenario/schema.go) for the
authoritative field reference.

Key fields:

- `target.gateway_url` — required
- `target.buyer_token` OR `target.demo_identity` — required
- `target.coordinator_db_path` + `target.gateway_db_path` — required for I1
- `buyers.count`, `buyers.pattern` (`constant` | `interval` | `ramp` | `burst`)
- `prompts[]` — rotated round-robin across the buyer fleet
- `expected_shape` — free-text "what we're looking to learn" (phase A: recorded only)

## Composing with `test/integration`

`test/integration` continues to own real-binary functional regression
tests. This harness is layered on top for *network-behavior* testing
(concurrency, routing, billing under load) — the two coexist.

Future PRs may add a `make smoke-network-harness` target that:

1. Boots a local stack via `test/integration` helpers
2. Runs `scenarios/smoke.yaml`
3. Tears down

For phase A we run manually.
