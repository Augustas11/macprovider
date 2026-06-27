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
export BUYER_TOKEN="..."     # scenarios use ${BUYER_TOKEN} so it's never committed
./harness run scenarios/smoke.yaml --out artifacts/smoke-run-1
```

Scenario YAML supports `${VAR}` expansion. Required secrets (`BUYER_TOKEN`,
optionally `OPERATOR_TOKEN`) are read from the environment at load time.
Unset vars expand to empty and `Validate()` rejects empty required fields.

Exit codes:

| Code | Meaning |
|---|---|
| 0 | Scenario ran, all hard invariants passed |
| 1 | Runtime error (scenario malformed, gateway unreachable, DB unreadable) |
| 2 | Usage error |
| 10 | Scenario ran but one or more hard invariants failed — triage `invariants.json` |

## Pointing at different stacks

The harness does **not** spawn coordinator/gateway. Caller is responsible.

**Default for phase A is the live network** at `https://api.streamvc.live`
with the user's own M-series providers attached. All committed scenarios
target this. I1 is marked SKIPPED on live (no read access to Pearl's
SQLite DBs from the harness machine); the other three invariants run.

Other targets are supported by editing `target.gateway_url` /
`target.coordinator_url` in a scenario:

- **Local stack (real M-series provider)** — start coordinator+gateway
  locally, attach `macprovider-cli serve` over WS. Set `coordinator_db_path`
  + `gateway_db_path` to the local SQLite files to enable I1.
- **Local stack (synthetic provider)** — via `test/integration` helpers.
  Best for harness self-validation, but won't catch real-model quirks.

## Cost discipline

Scenarios target the live network and consume real provider time. The
committed scenarios use conservative `max_tokens` (16–32) and small
buyer fleets — a full pass of all 4 scenarios costs cents, not dollars.
Before scaling a scenario up (e.g., 100 buyers, longer outputs), think
about the bill. Pearl logs every settled request; don't run 10× the
same scenario without reading the artifact bundle first.

## Chaos lane (deferred)

Two scenarios from the original phase-A plan require lifecycle control
we don't have remote-yank-able against live providers:

- **Mid-stream provider drop** — kill a provider's WS connection at
  token N of M and observe whether the gateway returns `stream_truncated`
  (current behavior per `chat_proxy.go:495`), reroutes, or hangs.
- **Cold-start race** — buyer prompt fires while a provider has just
  connected (hello sent, model not yet loaded). Observable error vs.
  queue vs. silent hang.

Both are deferred to a future "chaos lane" PR that either runs against
a local stack with a scripted provider WS kill, or coordinates with the
operator to manually restart a Mac during a scripted scenario. Phase A
proceeds without them; phase B triage will tell us how high to prioritize
the chaos lane.

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

## Scenarios committed

Run in order. Each captures a finding into its artifact bundle; phase B
triage reads them as a set.

| File | Shape | What it surfaces |
|---|---|---|
| [`scenarios/smoke.yaml`](scenarios/smoke.yaml) | 1 buyer × 3 prompts | Harness pipeline + basic reachability |
| [`scenarios/01_happy_path_concurrent.yaml`](scenarios/01_happy_path_concurrent.yaml) | 5 buyers × 2 requests | Routing distribution under modest concurrency, two-model parity |
| [`scenarios/02_capacity_contention.yaml`](scenarios/02_capacity_contention.yaml) | 10 buyers, burst at t=0 | Capacity-exhaustion behavior (queue / fail-fast / preflight reject) |
| [`scenarios/03_sticky_multi_turn.yaml`](scenarios/03_sticky_multi_turn.yaml) | 3 buyers × 5 sequential | Whether sticky affinity is active in production |
| [`scenarios/04_wrong_model.yaml`](scenarios/04_wrong_model.yaml) | 3 buyers, nonexistent model | Negative-path error code + no-charge guarantee |

See [`internal/scenario/schema.go`](internal/scenario/schema.go) for the
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
