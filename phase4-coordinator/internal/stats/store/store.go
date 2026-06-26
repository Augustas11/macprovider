package store

import (
	"context"
	"database/sql"
	"fmt"
	"time"
)

// Store is the SPEC-017 request-path DAO. It reads via the
// `stats_reader` role's *sql.DB. Per SPEC §7.2.1 the
// stats_reader role has SELECT on stats_overview_current,
// stats_timeseries_{rpm,tpm}_30m, stats_leaderboard_*,
// stats_components_health, stats_rewards_populated,
// partner_keys, provider_visibility — and is explicitly
// DENIED on ledger_* + provider_rewards_ledger +
// provider_tokens + provider_visibility_audit. The Step 1
// grants migration enforces this; the handler stack relies on
// it.
//
// Store methods MUST NOT issue INSERT / UPDATE / DELETE. v0.1
// IMPL emits no writes from the handler path; `last_used_at`
// updates are deferred per the §7.2.4 default-off resolution.
type Store struct {
	db *sql.DB
}

// New wraps a *sql.DB authenticated as stats_reader.
func New(db *sql.DB) *Store {
	return &Store{db: db}
}

// DB returns the underlying *sql.DB for direct queries by test
// code. Production code SHOULD use the typed methods.
func (s *Store) DB() *sql.DB { return s.db }

// PartnerKey is the subset of `partner_keys` columns the Step 3
// auth dispatcher consumes per SPEC §5.4.3.
type PartnerKey struct {
	ID             int64
	Label          string
	Prefix         string
	AllowedOrigins []string
	RateLimitRPM   int
	RevokedAt      sql.NullTime
}

// LookupPartnerKeyByHash performs the §5.4.3 hash-keyed SELECT.
// Returns (nil, nil) on no match — distinguished from error so
// the dispatcher can branch to row 6 of the decision table.
// Per the v0.1.7 timing-equivalence rule (§5.4.3 rule 4), the
// caller MUST NOT early-return before this SELECT on Origin
// mismatch or prefix mismatch — every keyed request runs the
// same hash + SELECT.
func (s *Store) LookupPartnerKeyByHash(ctx context.Context, tokenHash []byte) (*PartnerKey, error) {
	const q = `
        SELECT id, label, prefix, allowed_origins, rate_limit_rpm, revoked_at
          FROM partner_keys
         WHERE token_hash = $1
         LIMIT 1
    `
	var pk PartnerKey
	if err := s.db.QueryRowContext(ctx, q, tokenHash).Scan(
		&pk.ID, &pk.Label, &pk.Prefix, pqArray(&pk.AllowedOrigins), &pk.RateLimitRPM, &pk.RevokedAt,
	); err != nil {
		if err == sql.ErrNoRows {
			return nil, nil
		}
		return nil, fmt.Errorf("lookup partner_key: %w", err)
	}
	return &pk, nil
}

// OverviewRow is the singleton snapshot row read by
// /v1/stats/overview. Field names mirror the locked §5.1 JSON
// keys to make the marshal mapping unambiguous.
type OverviewRow struct {
	GeneratedAt           time.Time
	TokensIn              int64
	TokensOut             int64
	Requests              int64
	NodesOnline           int
	NodesHardwareAttested int
	BandwidthGBPerSec     int64
	NetworkPowerKW        float64
	NetworkUtilizationPct int
	GPUCoresTotal         int
	CPUCoresTotal         int
	UnifiedRAMGBTotal     int
	ModelsServing         int
}

func (s *Store) Overview(ctx context.Context) (*OverviewRow, error) {
	const q = `
        SELECT generated_at,
               tokens_in, tokens_out, requests,
               nodes_online, nodes_hardware_attested,
               bandwidth_gb_per_s, network_power_kw,
               network_utilization_pct,
               gpu_cores_total, cpu_cores_total,
               unified_ram_gb_total, models_serving
          FROM stats_overview_current
         WHERE singleton = TRUE
         LIMIT 1
    `
	var r OverviewRow
	if err := s.db.QueryRowContext(ctx, q).Scan(
		&r.GeneratedAt,
		&r.TokensIn, &r.TokensOut, &r.Requests,
		&r.NodesOnline, &r.NodesHardwareAttested,
		&r.BandwidthGBPerSec, &r.NetworkPowerKW,
		&r.NetworkUtilizationPct,
		&r.GPUCoresTotal, &r.CPUCoresTotal,
		&r.UnifiedRAMGBTotal, &r.ModelsServing,
	); err != nil {
		if err == sql.ErrNoRows {
			return nil, nil
		}
		return nil, fmt.Errorf("overview select: %w", err)
	}
	return &r, nil
}

// TimeseriesRow is one minute bucket. Missing minutes (NO row
// in the 30-minute window) MUST render as JSON `null` in the
// handler per §5.1 — NOT as zero. The handler fills the
// 30-point array by aligning Bucket against the rolling
// window and emitting null for absent minutes.
type TimeseriesRow struct {
	Bucket time.Time
	Value  int64 // requests for rpm; combined inTok/outTok via two fields below for tpm
	InTok  int64
	OutTok int64
}

func (s *Store) RpmTimeseries(ctx context.Context) ([]TimeseriesRow, error) {
	const q = `
        SELECT bucket_start, requests
          FROM stats_timeseries_rpm_30m
         ORDER BY bucket_start
    `
	rows, err := s.db.QueryContext(ctx, q)
	if err != nil {
		return nil, fmt.Errorf("rpm select: %w", err)
	}
	defer rows.Close()
	var out []TimeseriesRow
	for rows.Next() {
		var t TimeseriesRow
		if err := rows.Scan(&t.Bucket, &t.Value); err != nil {
			return nil, err
		}
		out = append(out, t)
	}
	return out, rows.Err()
}

func (s *Store) TpmTimeseries(ctx context.Context) ([]TimeseriesRow, error) {
	const q = `
        SELECT bucket_start, input_tokens, output_tokens
          FROM stats_timeseries_tpm_30m
         ORDER BY bucket_start
    `
	rows, err := s.db.QueryContext(ctx, q)
	if err != nil {
		return nil, fmt.Errorf("tpm select: %w", err)
	}
	defer rows.Close()
	var out []TimeseriesRow
	for rows.Next() {
		var t TimeseriesRow
		if err := rows.Scan(&t.Bucket, &t.InTok, &t.OutTok); err != nil {
			return nil, err
		}
		out = append(out, t)
	}
	return out, rows.Err()
}
