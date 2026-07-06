package rollup

import (
	"context"
	"database/sql"
	"encoding/json"
	"fmt"
	"time"

	"github.com/lib/pq"
	"github.com/rs/zerolog"
)

// runOverviewTick rewrites the singleton `stats_overview_current`
// row from (a) cumulative SPEC-005 ledger sums since rollup-start
// and (b) the live snapshot from the injected SnapshotProvider.
//
// SPEC §9.2 v0.1.7 reminder: `tokens_in`, `tokens_out`,
// `requests` are CUMULATIVE all-time counters (SUM since
// rollup-start), NOT a 24h window. The Path A rollup-start is
// `Config.PartialHistorySinceUnix` (when set); Path B uses 0
// (full history).
//
// The tick + the corresponding stats_components_health UPDATE
// run in ONE transaction (BUILD §B.1) so a panic between the
// data write and the health update cannot lie about freshness.
func runOverviewTick(ctx context.Context, db *sql.DB, cfg Config, snap SnapshotProvider, logger zerolog.Logger) error {
	now := time.Now().UTC()
	live := snap.OverviewSnapshot()

	var tokensIn, tokensOut, requests int64
	if err := queryOverviewCumulatives(ctx, db, cfg.PartialHistorySinceUnix, &tokensIn, &tokensOut, &requests); err != nil {
		return fmt.Errorf("overview cumulatives: %w", err)
	}
	if err := pruneIdlePrewarmEvents(ctx, db); err != nil {
		// Idle-prewarm telemetry is additive. A lock or grant issue on this
		// optional table must not stale the primary overview component.
		logger.Warn().Err(err).Msg("idle prewarm overview prune failed; continuing with primary overview rollup")
	}
	idle, err := queryIdlePrewarmOverview(ctx, db, live.CapacityEligibleProviderIDs)
	if err != nil {
		// Keep the overview contract available with the zero-value
		// idle-prewarm block when optional telemetry cannot be read.
		logger.Warn().Err(err).Msg("idle prewarm overview query failed; returning empty optional block")
		idle = idlePrewarmOverview{SkipsByReasonLast1hJSON: []byte(`{}`)}
	}

	tx, err := db.BeginTx(ctx, nil)
	if err != nil {
		return fmt.Errorf("overview begin: %w", err)
	}
	committed := false
	defer func() {
		if !committed {
			_ = tx.Rollback()
		}
	}()

	const upsert = `
        INSERT INTO stats_overview_current (
            singleton, generated_at,
            tokens_in, tokens_out, requests,
            nodes_online, nodes_hardware_attested,
            bandwidth_gb_per_s, network_power_kw,
            network_utilization_pct,
            gpu_cores_total, cpu_cores_total,
            unified_ram_gb_total, models_serving,
            idle_prewarm_pool_pct_with_b1_active,
            idle_prewarm_skips_by_reason_last_1h
        ) VALUES (
            TRUE, $1,
            $2, $3, $4,
            $5, $6,
            $7, $8,
            $9,
            $10, $11,
            $12, $13,
            $14, $15::jsonb
        )
        ON CONFLICT (singleton) DO UPDATE SET
            generated_at = EXCLUDED.generated_at,
            tokens_in = EXCLUDED.tokens_in,
            tokens_out = EXCLUDED.tokens_out,
            requests = EXCLUDED.requests,
            nodes_online = EXCLUDED.nodes_online,
            nodes_hardware_attested = EXCLUDED.nodes_hardware_attested,
            bandwidth_gb_per_s = EXCLUDED.bandwidth_gb_per_s,
            network_power_kw = EXCLUDED.network_power_kw,
            network_utilization_pct = EXCLUDED.network_utilization_pct,
            gpu_cores_total = EXCLUDED.gpu_cores_total,
            cpu_cores_total = EXCLUDED.cpu_cores_total,
            unified_ram_gb_total = EXCLUDED.unified_ram_gb_total,
            models_serving = EXCLUDED.models_serving,
            idle_prewarm_pool_pct_with_b1_active = EXCLUDED.idle_prewarm_pool_pct_with_b1_active,
            idle_prewarm_skips_by_reason_last_1h = EXCLUDED.idle_prewarm_skips_by_reason_last_1h
    `
	if _, err := tx.ExecContext(ctx, upsert,
		now,
		tokensIn, tokensOut, requests,
		live.NodesOnline, live.NodesHardwareAttested,
		live.BandwidthGBPerSec, live.NetworkPowerKW,
		live.NetworkUtilizationPct,
		live.GPUCoresTotal, live.CPUCoresTotal,
		live.UnifiedRAMGBTotal, live.ModelsServing,
		idle.PoolPctWithB1Active, string(idle.SkipsByReasonLast1hJSON),
	); err != nil {
		return fmt.Errorf("overview upsert: %w", err)
	}

	if err := healthOK(ctx, tx, componentOverview, now); err != nil {
		return fmt.Errorf("overview health: %w", err)
	}

	if err := tx.Commit(); err != nil {
		return fmt.Errorf("overview commit: %w", err)
	}
	committed = true
	return nil
}

// queryOverviewCumulatives sums tokens_in / tokens_out /
// requests from `ledger_request_credits` since the rollup-start
// boundary. `ledger_request_credits.ts_utc` is a Postgres-shape
// TIMESTAMPTZ in the SPEC-005 OLTP mirror (the live production
// store is SQLite TEXT but Step 2's rollup queries the
// Postgres mirror per the operator-side migration plan; see
// the trust-source decision record + OPS.md).
//
// `prompt_tokens` and `completion_tokens` map to `tokens_in`
// and `tokens_out` per SPEC §5.1.1 + SPEC-005 §11.4 tokens-out
// accounting.
//
// `requests` is COUNT(DISTINCT request_id) since the same
// request may produce multiple credit rows on retry; the
// public stats are about unique requests, not credit rows.
func queryOverviewCumulatives(ctx context.Context, db *sql.DB, sinceUnix int64, tokensIn, tokensOut, requests *int64) error {
	// CODE r3 HIGH 1 fix: use SPEC-005 effective-token semantic
	// so byte_estimated rows (completion_tokens=NULL) don't
	// silently undercount via the NULL-arithmetic path.
	q := `
        SELECT
            COALESCE(SUM(` + effectivePromptTokensSQL("lrc") + `), 0)::BIGINT,
            COALESCE(SUM(` + effectiveCompletionTokensSQL("lrc") + `), 0)::BIGINT,
            COUNT(DISTINCT lrc.request_id)::BIGINT
          FROM ledger_request_credits lrc
          JOIN ` + authenticatedProvidersRelation + ` pt ON pt.provider_id = lrc.provider_id
         WHERE ($1 = 0 OR EXTRACT(EPOCH FROM lrc.ts_utc) >= $1)
           AND lrc.fault_flag = 'none'
           AND lrc.quarantined = FALSE
    `
	row := db.QueryRowContext(ctx, q, sinceUnix)
	return row.Scan(tokensIn, tokensOut, requests)
}

func pruneIdlePrewarmEvents(ctx context.Context, db *sql.DB) error {
	cutoff := time.Now().UTC().Add(-24 * time.Hour)
	_, err := db.ExecContext(ctx, `
        DELETE FROM stats_idle_prewarm_events
         WHERE recorded_at < $1
    `, cutoff)
	return err
}

type idlePrewarmOverview struct {
	PoolPctWithB1Active     int
	SkipsByReasonLast1hJSON []byte
}

func queryIdlePrewarmOverview(ctx context.Context, db *sql.DB, capacityEligibleProviderIDs []string) (idlePrewarmOverview, error) {
	out := idlePrewarmOverview{SkipsByReasonLast1hJSON: []byte(`{}`)}
	if len(capacityEligibleProviderIDs) == 0 {
		return out, nil
	}
	cutoff := time.Now().UTC().Add(-time.Hour)
	var activeProviders int64
	if err := db.QueryRowContext(ctx, `
        SELECT COUNT(DISTINCT provider_id)
          FROM stats_idle_prewarm_events
         WHERE event = 'idle_prewarm_fired'
           AND recorded_at >= $1
           AND provider_id = ANY($2)
    `, cutoff, pq.Array(capacityEligibleProviderIDs)).Scan(&activeProviders); err != nil {
		return out, err
	}
	if activeProviders > 0 {
		out.PoolPctWithB1Active = int((activeProviders * 100) / int64(len(capacityEligibleProviderIDs)))
		if out.PoolPctWithB1Active > 100 {
			out.PoolPctWithB1Active = 100
		}
	}

	rows, err := db.QueryContext(ctx, `
        SELECT reason, COUNT(*)
          FROM stats_idle_prewarm_events
         WHERE event = 'idle_prewarm_skipped'
           AND reason IS NOT NULL
           AND recorded_at >= $1
           AND provider_id = ANY($2)
         GROUP BY reason
    `, cutoff, pq.Array(capacityEligibleProviderIDs))
	if err != nil {
		return out, err
	}
	defer rows.Close()
	reasons := map[string]int64{}
	for rows.Next() {
		var reason string
		var count int64
		if err := rows.Scan(&reason, &count); err != nil {
			return out, err
		}
		reasons[reason] = count
	}
	if err := rows.Err(); err != nil {
		return out, err
	}
	encoded, err := json.Marshal(reasons)
	if err != nil {
		return out, err
	}
	out.SkipsByReasonLast1hJSON = encoded
	return out, nil
}
