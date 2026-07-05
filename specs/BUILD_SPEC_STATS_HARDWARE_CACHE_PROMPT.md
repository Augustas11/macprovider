# BUILD_SPEC — Network Stats Hardware Cache

Implement dashboard-ready hardware capacity fields for the existing
Network Stats API without adding synchronous stats work to buyer,
routing, token streaming, or heartbeat paths.

## Source of truth

- `specs/SPEC-017-network-stats-api.md` v0.1.8 owns
  `/v1/stats/overview` and its 14 network fields.
- `phase4-coordinator/internal/stats/handlers.go` already serves the
  dashboard-shaped overview response from precomputed `stats_*` rows.
- `phase4-coordinator/internal/stats/rollup/overview.go` already writes
  traffic counters and live snapshot fields asynchronously.
- `phase4-coordinator/internal/stats/poolsnapshot/poolsnapshot.go`
  already derives live nodes, RAM, utilization, models, and attestation
  from the in-process provider pool, but intentionally leaves bandwidth,
  power, GPU cores, and CPU cores at zero until a trusted hardware source
  exists.
- `phase4-coordinator/internal/onboarding/apptrack.go` already accepts
  `hardware_summary` during App-track registration, but the current
  Postgres identity schema does not persist it.

## Non-negotiable performance invariant

Stats are a derived telemetry plane. No stats path may synchronously
participate in:

- buyer request routing
- token streaming
- provider selection
- provider heartbeat processing
- buyer/gateway auth
- billing settlement hot path

Hardware enrichment must be persisted during provider onboarding or
operator maintenance, refreshed asynchronously by the stats rollup side,
and consumed by `/v1/stats/overview` only as precomputed data.

## Scope IN

1. Persist App-track provider hardware summaries in Postgres.
2. Add a trusted operator-populated chip profile table.
3. Add a stats-side in-memory hardware cache refreshed from the rollup
   database on a fixed interval.
4. Extend the existing pool snapshot adapter to read that in-memory
   cache while iterating the already-copied provider registry snapshot.
5. Keep the public `/v1/stats/overview` wire contract unchanged.
6. Add tests proving missing profiles degrade to zero hardware totals
   and that snapshot-time enrichment uses a memory-only lookup.

## Scope OUT

- No new public stats endpoint.
- No provider-submitted bandwidth, power, GPU, or CPU totals.
- No external API calls for chip enrichment.
- No DB queries from stats HTTP handlers.
- No DB queries from buyer routing, token streaming, provider selection,
  or heartbeat handling.
- No hardcoded Apple chip capacity guesses in code. Trusted capacity
  values live in the operator-populated `chip_hardware_profiles` table.

## Data model

Add two SPEC-017 stats DB tables:

### `provider_hardware_profiles`

Provider-reported hardware identity, written by onboarding and later by
compatible provider-registration paths.

- `provider_id TEXT PRIMARY KEY`
- `chip TEXT NOT NULL`
- `chip_normalized TEXT NOT NULL`
- `unified_memory_gb INT NOT NULL`
- `macos_version TEXT NOT NULL DEFAULT ''`
- `app_version TEXT NOT NULL DEFAULT ''`
- `source TEXT NOT NULL CHECK (...)`
- `verified BOOLEAN NOT NULL DEFAULT FALSE`
- `last_reported_at TIMESTAMPTZ NOT NULL`

### `chip_hardware_profiles`

Operator-trusted hardware capacity constants.

- `chip_normalized TEXT PRIMARY KEY`
- `display_chip TEXT NOT NULL`
- `memory_bandwidth_gb_per_s BIGINT NOT NULL`
- `network_power_kw DOUBLE PRECISION NOT NULL`
- `gpu_cores INT NOT NULL`
- `cpu_cores INT NOT NULL`
- `updated_at TIMESTAMPTZ NOT NULL`

The rollup role may read both tables. The stats reader role must not.

## Runtime design

At coordinator boot, when stats are enabled:

1. Create a hardware cache backed by `statsPools.Rollup`.
2. Run one immediate refresh with a bounded timeout.
3. Start a background refresh loop.
4. Pass the cache as an optional in-memory hardware source to
   `poolsnapshot`.
5. Stop the refresh loop through the existing coordinator shutdown
   context.

At overview rollup time:

1. The existing rollup calls `SnapshotProvider.OverviewSnapshot()`.
2. `poolsnapshot` iterates `pool.Registry.Snapshot()` as it does today.
3. For each capacity-eligible live provider, it performs an in-memory
   lookup by `provider_id`.
4. If the cache has a verified provider hardware row and a trusted chip
   profile, it adds bandwidth, power, GPU cores, and CPU cores.
5. Unverified provider hardware, missing provider hardware, or missing
   chip capacity profile contributes zero to those four fields but does
   not remove the provider from nodes, RAM, models, or utilization totals.

## Acceptance criteria

- AC-1: `/v1/stats/overview` response shape is unchanged.
- AC-2: app-track registration persists `hardware_summary` to
  `provider_hardware_profiles`.
- AC-3: hardware persistence is not attempted before IP/ASN rate-limit
  checks pass.
- AC-4: `stats_reader` has no grants on provider/chip hardware tables.
- AC-5: `stats_rollup` can read provider/chip hardware tables.
- AC-6: `poolsnapshot` fills bandwidth, power, GPU cores, and CPU cores
  from an in-memory source only.
- AC-7: providers without hardware rows or trusted chip profiles keep
  existing live stats behavior and contribute zero hardware capacity.
- AC-7a: provider-reported chip identity contributes zero hardware
  capacity until the row is explicitly marked verified by an operator
  workflow.
- AC-8: the hardware cache refresh path has context timeouts and a small
  DB footprint.
- AC-9: no buyer, routing, streaming, heartbeat, auth, or billing hot-path
  code imports or calls the hardware cache.
- AC-10: focused tests cover persistence, cache refresh, snapshot sums,
  missing-profile degradation, and migration/grant shape.

## Verification

Run at minimum:

```bash
cd phase4-coordinator
go test -count=1 ./internal/onboarding ./internal/stats/poolsnapshot ./internal/stats/hardware ./internal/stats/migrations
go test -count=1 ./internal/stats ./cmd/coordinator
go test -count=1 ./...
go vet ./internal/onboarding ./internal/stats/hardware ./internal/stats/poolsnapshot ./internal/stats/migrations ./cmd/coordinator
git diff --check
```

Integration tests with the `integration` build tag remain the grant
authority when a Docker-capable environment is available.

## Audit gates

Before treating the implementation as complete, run three Codex audit
lanes:

- code lane: correctness, tests, regressions
- security/performance lane: grants, trust boundary, hot-path isolation
- architecture lane: boundaries, lifecycle, operational rollback

Fix and re-audit until all three lanes report:

- 0 CRITICAL
- 0 HIGH
- 0 MEDIUM

LOW/INFO findings may be carried only if explicitly documented.
