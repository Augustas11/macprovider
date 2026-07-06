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
  (per-matched-pair semantics since #226; the `drift_basis` field in
  `ledger_reconcile.json` pins which algorithm produced the sums.
  I1 fails on any of:
    1. unmatched harness successes (`UnmatchedSuccesses`),
    2. unmatched gateway "ok" rows (`UnmatchedGatewayOKRows`),
    3. unmatched coord 2xx rows (`UnmatchedCoordinator2xxRows`),
    4. gateway-ok pairs with no coord row (`MatchedCoordMissing`;
       fallback outcomes legitimately lack coord rows and are excluded),
    5. positive gateway-vs-harness overbill across pairs
       (`GatewayOverbillVsHarnessTokens` > 0; "ok" outcomes always count,
       and fallback outcomes count unless the buyer ALSO received the
       gateway's terminal SSE error envelope — the corroboration check
       that closes the #232 trust gap. Pure fallback exclusion was the
       R5 behavior and a `fallback` label alone is no longer a free
       pass for gateway/coord overbill),
    6. absolute gateway-vs-coord mismatch across pairs
       (`AbsGatewayCoordinatorMismatchTokens` > 0; both directions, since
       gateway and coord are both settlement systems and must agree).
  Gateway-vs-harness underbill alone is allowed — gateway-side streaming
  rounding is legitimate.)
- **I2** — no 5xx response without a billing settlement entry
  (gateway must echo a request id on every 5xx; orphaning is a billing-bypass risk)
- **I3** — no charged-tokens > delivered-tokens
  (phase-A structural check; the DB-level overcharge signal lives in
  `ledger_reconcile.json` → `overbilled_pairs` and `gateway_overbill_*_tokens`)
- **I4** — no silent hang
  (a streaming response that stays open past `silent_hang_threshold` with no bytes and no `data: [DONE]` is a UX failure regardless of what the contract says about latency)

Everything else (routing distribution, sticky behavior, capacity-exhaustion
error code, mid-stream failover) is **recorded** in phase A and **judged**
in phase B.

## Running

```
go build -o harness ./cmd/harness

# Required for buyer-fleet scenarios:
export BUYER_TOKEN="..."         # committed YAML uses ${BUYER_TOKEN}

./harness run scenarios/smoke.yaml --out artifacts/smoke-run-1

# Convenience wrapper: builds the binary, resolves scenario mode safely,
# reads BUYER_TOKEN from .env.harness or ~/.config/macprovider/buyer-api-key,
# and writes a timestamped artifacts/<scenario>-<utc>/ bundle.
./run-scenario.sh smoke.yaml
```

Scenario YAML supports `${VAR}` expansion at load time. Unset vars expand to empty
and `Validate()` rejects empty required fields. SSH targets are passed through
verbatim to `ssh` and `scp` when remote DB reconciliation is configured.
Committed live scenarios use the `pearl:` SSH alias; configure that in
`~/.ssh/config` rather than exporting a separate SSH target variable.

Exit codes:

| Code | Meaning |
|---|---|
| 0 | Scenario ran, all hard invariants passed |
| 1 | Runtime error (scenario malformed, gateway unreachable, DB unreadable) |
| 2 | Usage error |
| 10 | Scenario ran but one or more hard invariants failed — triage `invariants.json` |

## Pointing at different stacks

The harness does **not** deploy production services. The buyer fleet runs
in-process inside the harness binary against the configured
`target.gateway_url`. Caller is responsible for pointing that URL at a
live stack or at test binaries booted by `test/integration` helpers.

**Default for phase A is the live network** at `https://api.streamvc.live`
with the user's own M-series providers attached. All committed buyer-fleet
scenarios target this. **I1 runs only when DB sources are configured**:
local file paths use `target.coordinator_db_path` / `target.gateway_db_path`;
live runs use `target.coordinator_db_ssh` / `target.gateway_db_ssh`.

Other targets supported by editing `target.gateway_url` / `target.coordinator_url`:

- **Local stack (real M-series provider)** — start coordinator+gateway
  locally, attach `macprovider-cli serve` over WS. Use `coordinator_db_path`
  + `gateway_db_path` instead of `_ssh` variants for local files.
- **Local stack (synthetic provider)** — via `test/integration` helpers.
  Best for harness self-validation, but won't catch real-model quirks.

## DB snapshot mechanics

When `target.coordinator_db_ssh` / `target.gateway_db_ssh` are set, the
reconciler runs three SSH operations per DB:

```
ssh user@host "sqlite3 /path/to.db 'VACUUM INTO /tmp/harness-snap.db'"
scp user@host:/tmp/harness-snap.db /tmp/<local-tmp>.db
ssh user@host "rm -f /tmp/harness-snap.db"
```

This produces a transactionally consistent snapshot without disturbing
live writers. The local temp file is deleted after reconciliation. If
the SSH target requires a non-default key, set it in your `~/.ssh/config`
under the matching host alias; the harness inherits.

When `target.coordinator_db_path` / `target.gateway_db_path` are set,
the reconciler opens those local SQLite files directly. This is the
preferred path for in-process local stacks booted by integration helpers.

## Chaos events

A scenario can include a `chaos_events` timeline:

```yaml
chaos_events:
  - at: 5s
    description: "Kill provider mid-stream"
    command: launchctl kickstart -k gui/$(id -u)/live.streamvc.macprovider
  - at: 30s
    description: "Restart provider"
    command: launchctl kickstart gui/$(id -u)/live.streamvc.macprovider
```

Each entry runs via `/bin/sh -c` at the specified offset from scenario
start, in parallel with the buyer fleet. Stdout, stderr, exit code, and
scheduled vs. actual fire time are captured into `chaos_events.json` in
the artifact bundle so triage can correlate harness-injected failures
with what buyers observed.

**Important**: chaos commands are committed YAML and trust the operator.
Edit the launchd label / pkill pattern in scenarios 05 and 06 to match
your provider's actual start mechanism before running them. The
trailing restart events in those scenarios are best-effort — if they
fail, run the same launchd recovery command locally on the affected Mac
to bring the provider back up.

## Cost discipline

Scenarios target the live network and consume real provider time. The
committed smoke and routing-discovery scenarios use conservative
`max_tokens` (16-32) and small buyer fleets, while benchmark and
settlement-regression scenarios intentionally use longer outputs. Before
scaling a scenario up (e.g., 100 buyers, longer outputs), think about the
bill. Pearl logs every settled request; don't run 10x the same scenario
without reading the artifact bundle first.

## Artifact bundle

After a run, `--out` contains:

```
scenario.yaml             # verbatim copy of the input
run_meta.json             # scenario name, UTC window, git sha
per_request.jsonl         # one row per request — the raw evidence
metrics_summary.json      # aggregated histograms, route distribution, invalid-2xx count
ledger_reconcile.json     # three-way drift report (omitted when skipped)
invariants.json           # the 4 hard verdicts
benchmark_summary.json    # B-invariants source data (only when benchmark.enabled)
benchmark_verdict.json    # B-invariant PASS/WARN/FAIL list (only when benchmark.enabled)
```

For phase-B triage, the artifact bundle is the input. Read
`metrics_summary.json` for routing distribution and latency shape;
`ledger_reconcile.json` for billing drift; `per_request.jsonl` for any
case the summaries elide.

## Phase-B benchmark suite (B1-B7)

Scenarios that declare a `benchmark:` block evaluate the network-
performance invariants from `specs/SPEC-NETWORK-BENCHMARK-v0.1.md`
alongside I1-I4. The benchmark is REPORTING-ONLY — FAIL verdicts log
but do not change the harness exit code (I1-I4 still gate via exit 10).

```yaml
benchmark:
  enabled: true
  invariants: [B1, B2, B3, B4, B5, B6]
  pricing_source: pearl:/opt/macprovider/coordinator.yaml      # only needed for B6 (or .json fallback)
  provider_slots: 3                                             # default 3 (Pearl AccountConcurrency)
```

| ID | Title | PASS target | Bare-min | SKIP when |
|---|---|---|---|---|
| B1 | TTFT p50 | ≤ 800ms | ≤ 2000ms | no streaming samples |
| B2 | Streaming TPS p50 | ≥ 30 tok/s | ≥ 15 tok/s | non-streaming scenario |
| B3 | Tail ratio p99/p50 | ≤ 3.0 | ≤ 5.0 | no TTFT distribution |
| B4 | Error rate /1000 | ≤ 5 | ≤ 25 | 0 requests |
| B5 | Slot utilization % | ≥ 40 | ≥ 15 | no X-Provider-Id attribution |
| B6 | Earnings $/hr | ≥ $1.00 | ≥ $0.30 | no pricing manifest or attribution |
| B7 | Cold/warm TTFT ratio | ≤ 2.0 | ≤ 5.0 | scenario didn't use cold_warm_pairs |

The `cold_warm_pairs` buyer pattern (used by scenario 08) fires
`requests_per_buyer / 2` pairs of (cold, warm) requests. Each pair
sleeps `inter_pair_idle_seconds` before the cold request, then fires
the warm request immediately. The harness tags results with
`phase: cold|warm` so B7 can compute the p50 ratio.

Pricing sources are loaded via local path or `host:/path` SSH spec.
The loader distinguishes by extension:

- **`*.yaml` / `*.yml`** — coordinator config file. Derives provider-net
  USD/1k rates from `rewards.rate_card × global_multiplier ×
  provider_share × stats.rollup.usd_per_million_credits` — the exact
  formula coord uses to settle. **Recommended** for production runs
  (issue #223 fix): pricing tracks the live coordinator. Unset coord
  fields fall back to the defaults in
  `phase4-coordinator/internal/config/config.go:528`. Unknown models
  fall back to the `default` rate-card entry, matching coord's
  `RateFor` behavior.
- **`*.json`** — frozen pricing manifest. Three accepted shapes
  (array of `{model, price_per_1k_*}`, `{models: [...]}` wrapper, or
  `{model_id: {...}}` map). Useful for offline reproducibility or
  bench-against-hypothetical-rates analysis. Unknown models contribute
  zero earnings and are recorded in `UnknownModels` for triage.

## Scenarios committed

Run in order. Each captures a finding into its artifact bundle; phase B
triage reads them as a set.

| File | Shape | What it surfaces | Env needed |
|---|---|---|---|
| [`scenarios/smoke.yaml`](scenarios/smoke.yaml) | 1 buyer × 3 prompts | Harness pipeline + basic reachability | BUYER_TOKEN, `pearl` SSH alias |
| [`scenarios/01_happy_path_concurrent.yaml`](scenarios/01_happy_path_concurrent.yaml) | 5 buyers × 2 requests | Routing distribution under modest concurrency, two-model parity | BUYER_TOKEN, `pearl` SSH alias |
| [`scenarios/02_capacity_contention.yaml`](scenarios/02_capacity_contention.yaml) | 10 buyers, burst at t=0 | Capacity-exhaustion behavior (queue / fail-fast / preflight reject) | BUYER_TOKEN, `pearl` SSH alias |
| [`scenarios/03_sticky_multi_turn.yaml`](scenarios/03_sticky_multi_turn.yaml) | 3 buyers × 5 sequential | Whether sticky affinity is active in production | BUYER_TOKEN, `pearl` SSH alias |
| [`scenarios/04_wrong_model.yaml`](scenarios/04_wrong_model.yaml) | 3 buyers, nonexistent model | Negative-path error code + no-charge guarantee | BUYER_TOKEN, `pearl` SSH alias |
| [`scenarios/05_mid_stream_drop.yaml`](scenarios/05_mid_stream_drop.yaml) | 1 streaming buyer + local launchd chaos at t=5s | Gateway behavior on mid-stream provider loss; billing of partial tokens | BUYER_TOKEN, `pearl` SSH alias, local launchd label |
| [`scenarios/06_cold_start_race.yaml`](scenarios/06_cold_start_race.yaml) | Restart provider, buyer waits 2s, then fires before model loads | Cold-start window: queue / error / reroute / hang | BUYER_TOKEN, `pearl` SSH alias, local launchd label |
| [`scenarios/07_sustained_throughput.yaml`](scenarios/07_sustained_throughput.yaml) | 2 buyers, paced streaming load | Benchmark TTFT, TPS, tail ratio, error rate, and slot utilization | BUYER_TOKEN, `pearl` SSH alias |
| [`scenarios/08_cold_warm_compare.yaml`](scenarios/08_cold_warm_compare.yaml) | 10 cold/warm request pairs | Benchmark cold-start TTFT penalty | BUYER_TOKEN, `pearl` SSH alias |
| [`scenarios/09_streaming_ttft_distribution.yaml`](scenarios/09_streaming_ttft_distribution.yaml) | 100 paced short streams | Benchmark TTFT histogram and tail ratio | BUYER_TOKEN, `pearl` SSH alias |
| [`scenarios/10_provider_session_economics.yaml`](scenarios/10_provider_session_economics.yaml) | 10-minute low-load session | Benchmark provider slot utilization and earnings/hr | BUYER_TOKEN, `pearl` SSH alias |
| [`scenarios/11_sku_earn_viability.yaml`](scenarios/11_sku_earn_viability.yaml) | Hardware matrix simulation | SKU-economics gate against live rate card | Packaged CLI, public coordinator |
| [`scenarios/12_moe_mid_stream_projection.yaml`](scenarios/12_moe_mid_stream_projection.yaml) | MoE streaming regression | #303 Path A: premature `stream_output_exceeded` before provider usage | BUYER_TOKEN, `pearl` SSH alias, required MoE model rows |
| [`scenarios/13_dense_token_count_regression.yaml`](scenarios/13_dense_token_count_regression.yaml) | Dense coding streams | #303 Path B: dense-content token downclamp drift | BUYER_TOKEN, `pearl` SSH alias, Qwen2.5-Coder-32B row |
| [`scenarios/14_sparse_provider_reported_tokens.yaml`](scenarios/14_sparse_provider_reported_tokens.yaml) | Sparse English streams | #303 Path C: provider-reported tokens must beat byte estimates | BUYER_TOKEN, `pearl` SSH alias, Llama 3.1 8B row |

See [`internal/scenario/schema.go`](internal/scenario/schema.go) for the
authoritative field reference.

Key fields:

- `target.gateway_url` — required
- `target.buyer_token` OR `target.demo_identity` — required
- `target.coordinator_db_path` + `target.gateway_db_path` — required for I1
- `target.coordinator_db_ssh` + `target.gateway_db_ssh` — remote snapshot alternative for I1
- `buyers.count`, `buyers.pattern` (`constant` | `interval` | `ramp` | `burst` | `cold_warm_pairs`)
- `buyers.initial_delay` — optional fleet-wide delay before first request
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
