# Gateway Demand Telemetry

Issue #1807 uses gateway demand telemetry to measure model demand before any
8GB/16GB catalog migration. The raw `demand_events` table is a short-lived
observation feed, not a buyer support or content-inspection log.

## Stored Data

`demand_events` stores request metadata only:

- request id
- keyed buyer hash derived from the authenticated account id and scoped by the
  14-day raw-row retention window
- requested/routed model, limited to public catalog/test ids or fixed
  `unknown_model_id` / `invalid_model_id` buckets
- provider id when the coordinator supplied a bounded public provider id
- pool and engine routing classes
- stream/structured/tools flags
- requested prompt/output token exposure and served token counts, including
  cached prompt and reasoning tokens when provider usage reports them
- terminal result, failure reason, provider-existence flag, substitution flag
- coordinator admission queue latency, provider prefill/decode timing, total
  gateway latency, and event timestamp
- the SPEC-006-R028 serving telemetry: `gw_first_reasoning_ms`,
  `gw_first_answer_ms` and `gw_output_tps_millitokens` (`NULL` when absent,
  never `0`; recorded only for `incremental` streams), the `streaming_mode`
  and `serving_engine` labels, and bounded provider-reported timing labels
  (`provider_reported_queue_ms`, `provider_reported_first_token_ms`,
  `provider_reported_first_answer_ms`, `provider_reported_decode_ms`)
- legacy `time_to_first_token_ms` and `output_tps_millitokens`, still written
  unchanged. They are not defined quantities: the first ends at the first
  output delta with reasoning included (or sums coordinator phase headers),
  the second divides the provider-reported completion count by the
  coordinator's first-byte-to-done header. Use the R028 columns for new
  reports.

It must not store raw account id, API keys, prompts, messages, completions,
request bodies, response bodies, or wallet/private-key material.

## Access And Retention

Raw demand rows are operator analytics data. Access is limited to operators with
gateway database access for fleet planning, catalog migration analysis, and
incident validation.

Keep raw rows only for the active observation window: 14 days for the #1807
observation run. The gateway prunes rows older than that window on startup and
then periodically via `PruneDemandEvents`; each gateway maintenance call
deletes a bounded batch so telemetry retention does not monopolize the shared
auth/billing/settlement SQLite writer, then attempts a passive WAL checkpoint
that will be retried by later prune calls. The writable gateway handle opens
with `secure_delete=ON`, so row deletion overwrites freed content in the main
DB file without running hourly `VACUUM` or truncating WAL checkpoints on the
request path. Database snapshots, filesystem backups, WAL files, and operator
exports that include raw `demand_events` must use the same retention window or
be treated as separate operator-retained analytics data. Run any explicit WAL
truncation or compaction as off-path maintenance, not from the hourly gateway
pruner. Preserve longer-lived latency reporting through saved responses of
the `GET /admin/demand-latency` read (below), and demand counts through
`DemandRouteSummary`, not by retaining per-request rows indefinitely.
`DemandSummary` timing averages are legacy (`Legacy`-prefixed fields).

`demand_events` rejects updates so rows cannot be rewritten in place. Deletes
are allowed only for retention pruning.

## Issue #1807 Gate Sequence

Use one working PR for the issue. Do not publish or sign catalog changes merely
because request telemetry has landed.

1. Deploy demand telemetry and confirm it captures attempted demand, including
   unserved and capacity-constrained requests.
2. Validate `Qwen3.5-9B-4bit` on 16GB and
   `Ministral-3-3B-Instruct-2512-4bit` on 8GB on the designated Mac Studio.
   Do not run the hardware campaign on the operator's primary Mac, and do not connect
   an unreleased local CLI to the live Malibu coordinator.
3. Preserve limited Llama coverage during the trial:
   keep Llama 3.1 8B on part of the 16GB fleet, keep minimal Llama 3.2 3B
   coverage for compatibility and existing buyers, do not add Qwen3 8B while
   its OpenRouter route is scheduled for 2026-10-09 deprecation, and do not
   prioritize Gemma 3 4B or Qwen2.5-Coder 7B without new Malibu demand evidence.
4. If validation passes, prepare the reversible trial allocation:
   16GB at 60% Qwen3.5-9B / 40% Llama 3.1 8B, and 8GB at 80%
   Ministral 3 3B / 20% Llama 3.2 3B. Keep one inference slot per machine
   initially, advertise only validated context limits, and attach the rollback
   evidence package before signing.
5. Hand off catalog signing and publication only after the validation evidence,
   Llama coverage floor, allocation math, and rollback plan are attached to the
   issue/PR. The signing session owns the signed catalog bytes and release
   mechanics; this telemetry runbook owns the measurement and evidence gates.
6. Start the 14-day observation window only after candidates pass, the
   allocation is live and stable, telemetry is complete enough, and provider
   availability is high.
7. Publish the dated decision artifact with the raw window, queries,
   exclusions, gaps, and recommendation before pruning or reallocating Llama
   coverage.

## Serving Latency Read

`GET /admin/demand-latency?window=24h|7d|14d` (operator key) returns nearest-
rank p50 and p95 of the three R028 quantities per requested model and
`serving_engine`, with sample counts. p50 is null below 5 samples, p95 below
20; `unknown_model_id` and `invalid_model_id` are excluded. `serving_engine`
is the first-selected provider's engine family from the route trace, not the
path the request ran, so a cell does not separate failover, active rows or
shard groups. These numbers never feed routing; the coordinator's routing
store is SPEC-002-R005.

The output rate is the answer bytes divided by 4, minus one, over the window
from the first to the last answer delta: an estimate on the same basis for
every model family, counting answer text only. It includes buyer write
backpressure, because the gateway writes each frame before it reads the next.

## Reporting Scope

Current gateway summaries report requested, served, unmet,
capacity-constrained, substituted, timing, reasoning-token, and route/outcome
demand by model and traffic class. Hardware class, provider-hour, revenue,
payout, and margin reports must join these rows by request id, provider id, and
event time with authoritative provider-inventory and settlement sources. The
gateway does not fabricate economics fields it cannot authoritatively observe.
