package rollup

import (
	"context"
	"database/sql"
	"fmt"
	"time"
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
func runOverviewTick(ctx context.Context, db *sql.DB, cfg Config, snap SnapshotProvider) error {
	now := time.Now().UTC()
	live := snap.OverviewSnapshot()

	var tokensIn, tokensOut, requests int64
	if err := queryOverviewCumulatives(ctx, db, cfg.PartialHistorySinceUnix, &tokensIn, &tokensOut, &requests); err != nil {
		return fmt.Errorf("overview cumulatives: %w", err)
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
            unified_ram_gb_total, models_serving
        ) VALUES (
            TRUE, $1,
            $2, $3, $4,
            $5, $6,
            $7, $8,
            $9,
            $10, $11,
            $12, $13
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
            models_serving = EXCLUDED.models_serving
    `
	if _, err := tx.ExecContext(ctx, upsert,
		now,
		tokensIn, tokensOut, requests,
		live.NodesOnline, live.NodesHardwareAttested,
		live.BandwidthGBPerSec, live.NetworkPowerKW,
		live.NetworkUtilizationPct,
		live.GPUCoresTotal, live.CPUCoresTotal,
		live.UnifiedRAMGBTotal, live.ModelsServing,
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
          JOIN provider_tokens pt ON pt.provider_id = lrc.provider_id
         WHERE ($1 = 0 OR EXTRACT(EPOCH FROM lrc.ts_utc) >= $1)
           AND lrc.fault_flag = 'none'
           AND lrc.quarantined = FALSE
    `
	row := db.QueryRowContext(ctx, q, sinceUnix)
	return row.Scan(tokensIn, tokensOut, requests)
}
