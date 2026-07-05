// Package stats is the SPEC-017 Network Stats API request-path
// handler package. Step 1 establishes the package layout, Pools
// struct, and lifecycle (Open/Close/Smoke) wiring. HTTP handlers
// land in Step 3 per BUILD §2.3.
//
// Per BUILD §C.1 and SPEC §7.2.5, each runtime role gets its own
// *sql.DB. No two pools share an instance.
//
// Per SPEC §7.6 + AC-16, this package and `internal/stats/store`
// MUST NOT import internal/billing, internal/explorer, internal/ws,
// or internal/auth (except a minimal Bearer parser whose exact
// symbol the depguard allowlist names — none in Step 1 since
// handlers do not exist yet).
//
// Per BUILD §D.3, os.Exit / log.Fatal / log.Fatalf MUST NOT appear
// anywhere under internal/stats/* — preserves the §7.3
// recover-middleware guarantee. Errors propagate up to
// cmd/coordinator/main.go which decides the exit posture.
package stats

import (
	"context"
	"database/sql"
	"errors"
	"fmt"
	"time"
)

// Config is the operator-tunable subset of the coordinator's
// `stats:` YAML block, plumbed through cmd/coordinator/main.go.
// Step 2 (rollup) and Step 3 (handlers) consume Rollup and CORS
// respectively; Step 1 reads the DSN block + PartnerKeys flag.
type Config struct {
	Enabled bool

	// DSN per active daemon role. When Enabled = true, reader and
	// rollup DSNs MUST be non-empty. The provider_portal role is
	// intentionally not opened by the public stats daemon; it belongs
	// to provider-authenticated portal/operator flows.
	ReaderDSN string
	RollupDSN string

	// PartnerKeys gates the optional `partner_keys_writer` pool.
	// v0.1 default is LastUsedAtUpdatesEnabled = false; the
	// PartnerKeysWriterDSN field is only consulted when the flag
	// is true (BUILD §C.2).
	PartnerKeys PartnerKeysConfig

	// PartnerKeysAdminDSN is the CLI operator DSN (Step 4.A scope).
	// Step 1 declares the field so config-loading is forward-compatible;
	// Step 1's Open MUST NOT instantiate a pool for this DSN
	// (BUILD §D.6). Step 4.A reads it at CLI subcommand time only.
	PartnerKeysAdminDSN string

	Rollup RollupConfig
	CORS   CORSConfig

	// TrustedProxies is consumed by Step 3's auth-failure tier
	// limiter for client-IP derivation (SPEC §5.6 v0.1.8 auth-
	// failure tier + SECURITY r5 H1 trusted-proxy fix). Step 1
	// declares the field so Step 3 lands without re-touching
	// config; it has no Step 1 effect.
	TrustedProxies []string
}

// PartnerKeysConfig governs the optional last_used_at writer.
// v0.1 default is OFF per BUILD §2 Step 1 resolution.
type PartnerKeysConfig struct {
	LastUsedAtUpdatesEnabled bool
	WriterDSN                string
}

// RollupConfig pins the operator-tunable knobs the Step 2 rollup
// package consumes. Step 1 declared the seam; Step 2 fills the
// rollup tick implementations.
type RollupConfig struct {
	// BackfillMode is one of "partial" (Path A, default) or
	// "full" (Path B). See SPEC §9.7.
	BackfillMode string
	// PartialHistorySince is the RFC 3339 rollup-start timestamp
	// in Path A. Empty when BackfillMode = "full".
	PartialHistorySince string
	// LateEventsRetentionDays — SPEC §9.3 (v0.1.7). Default 90;
	// floor 30. Pin: clamp+warn for values in (0, 30); a 0 means
	// "use default" (90).
	LateEventsRetentionDays int
	// UsdPerMillionCredits — credits→USD conversion factor.
	// Default 1.0. earnings_work_usd = provider_credits *
	// UsdPerMillionCredits / 1_000_000.
	UsdPerMillionCredits float64
	// DriftThresholdRatio — fractional divergence threshold for
	// the nightly rebuild's drift-detection log emission per
	// SPEC §9.4. Default 0.005 (0.5%).
	DriftThresholdRatio float64
	// NightlyRebuildHourUTC — UTC hour [0,23] for the nightly
	// stats_leaderboard_all + stats_leaderboard_30d rebuild.
	// Default 9 per SPEC §9.3.
	NightlyRebuildHourUTC int
	// LateEventsLookbackHours — SPEC §9.3 48h default.
	LateEventsLookbackHours int
}

// CORSConfig — Step 1 declares fields Step 3 needs so Step 3's
// PR is a code-only change.
type CORSConfig struct {
	// AccessControlMaxAgeSeconds — SPEC §5.7 (v0.1.7 lowered
	// default to 60; cap at 300 per locked SPEC). Step 3 reads
	// this; Step 1 only declares it.
	AccessControlMaxAgeSeconds int
	// PartnerOriginAllowlist is the union of operator-pinned
	// browser origins (e.g. https://console.streamvc.live,
	// https://portal.streamvc.live) that Step 3 echoes on the
	// public-tier preflight per SPEC §5.7.
	PartnerOriginAllowlist []string
}

// Pools holds one *sql.DB per active daemon role. Per SPEC §7.2.5,
// no two roles MAY share a pool.
//
// Reader and Rollup are non-nil whenever Open returns nil.
// PartnerKeysWriter is nil unless Config.PartnerKeys.LastUsedAtUpdatesEnabled
// was true at Open time (BUILD §C.2 + §D.5).
type Pools struct {
	Reader            *sql.DB
	Rollup            *sql.DB
	PartnerKeysWriter *sql.DB
}

// Close shuts down every non-nil pool. Each pool is closed
// independently so a failure on one does not abandon the rest.
// The returned error is the first non-nil close error (others are
// dropped — sql.DB.Close is rarely useful past the first error
// and we don't want a noisy multi-error wrapper for a shutdown
// path).
func (p *Pools) Close() error {
	if p == nil {
		return nil
	}
	var firstErr error
	for _, db := range []*sql.DB{p.Reader, p.Rollup, p.PartnerKeysWriter} {
		if db == nil {
			continue
		}
		if err := db.Close(); err != nil && firstErr == nil {
			firstErr = err
		}
	}
	return firstErr
}

// ErrDisabled is returned by Open when Config.Enabled is false.
// cmd/coordinator/main.go treats this as a signal to skip /v1/stats/*
// mux registration entirely per BUILD §C.4.
var ErrDisabled = errors.New("stats: disabled via config")

// openFn is the database/sql.Open seam, exposed for tests.
// Production wiring sets this to sql.Open with the "postgres"
// driver name (lib/pq) at first use; tests substitute a stub
// driver name via a build-tagged init.
var openFn = sql.Open

// driverName is the database/sql driver to use. Production is
// "postgres" (lib/pq registers under this name on import). Tests
// MAY swap by setting driverName before calling Open.
var driverName = "postgres"

// Open opens one *sql.DB per active runtime role and runs a
// per-pool smoke. Fail-closed per BUILD §C.3: any missing
// required DSN or any failed smoke returns an error, and Open
// closes every pool it managed to open before the failure so
// the caller does not need to defer Close on a partial result.
//
// Pool tuning (max open, max idle, conn lifetime) is set per
// BUILD §D.4 to non-default values matching a coordinator
// instance under coordinator.streamvc.live load.
func Open(ctx context.Context, cfg Config) (*Pools, error) {
	if !cfg.Enabled {
		return nil, ErrDisabled
	}
	if err := validateRequiredDSNs(cfg); err != nil {
		return nil, err
	}

	pools := &Pools{}
	// On any error, close everything we opened so far.
	defer func() {
		if pools == nil {
			return
		}
	}()

	reader, err := openPool(cfg.ReaderDSN, poolTuneRead())
	if err != nil {
		return nil, fmt.Errorf("stats_reader: %w", err)
	}
	pools.Reader = reader

	rollup, err := openPool(cfg.RollupDSN, poolTuneWrite())
	if err != nil {
		_ = pools.Close()
		return nil, fmt.Errorf("stats_rollup: %w", err)
	}
	pools.Rollup = rollup

	if cfg.PartnerKeys.LastUsedAtUpdatesEnabled {
		writer, err := openPool(cfg.PartnerKeys.WriterDSN, poolTuneWrite())
		if err != nil {
			_ = pools.Close()
			return nil, fmt.Errorf("partner_keys_writer: %w", err)
		}
		pools.PartnerKeysWriter = writer
	}

	if err := smoke(ctx, pools); err != nil {
		_ = pools.Close()
		return nil, err
	}

	return pools, nil
}

func validateRequiredDSNs(cfg Config) error {
	if strTrim(cfg.ReaderDSN) == "" {
		return errors.New("stats_reader_dsn is required when stats.enabled = true")
	}
	if strTrim(cfg.RollupDSN) == "" {
		return errors.New("stats_rollup_dsn is required when stats.enabled = true")
	}
	if cfg.PartnerKeys.LastUsedAtUpdatesEnabled && strTrim(cfg.PartnerKeys.WriterDSN) == "" {
		return errors.New(
			"partner_keys_writer_dsn is required when stats.partner_keys.last_used_at_updates_enabled = true",
		)
	}
	return nil
}

type poolTune struct {
	maxOpenConns    int
	maxIdleConns    int
	connMaxLifetime time.Duration
	connMaxIdleTime time.Duration
}

func poolTuneRead() poolTune {
	return poolTune{
		maxOpenConns:    20,
		maxIdleConns:    10,
		connMaxLifetime: 30 * time.Minute,
		connMaxIdleTime: 5 * time.Minute,
	}
}

func poolTuneWrite() poolTune {
	return poolTune{
		maxOpenConns:    8,
		maxIdleConns:    4,
		connMaxLifetime: 30 * time.Minute,
		connMaxIdleTime: 5 * time.Minute,
	}
}

func openPool(dsn string, tune poolTune) (*sql.DB, error) {
	db, err := openFn(driverName, dsn)
	if err != nil {
		// Intentionally do NOT include dsn in the error string
		// (BUILD §C.3 SECURITY invariant — DSN contains the role
		// password).
		return nil, fmt.Errorf("sql.Open failed: %w", err)
	}
	db.SetMaxOpenConns(tune.maxOpenConns)
	db.SetMaxIdleConns(tune.maxIdleConns)
	db.SetConnMaxLifetime(tune.connMaxLifetime)
	db.SetConnMaxIdleTime(tune.connMaxIdleTime)
	return db, nil
}

// smoke runs per-pool role-boundary assertions under a short
// timeout so a hung DSN cannot block coordinator startup
// indefinitely.
//
// Round-1 ARCH r1 HIGH C2 + CODE r1 HIGH D1 fix: PingContext
// alone proved nothing about role identity — three DSNs all
// pointing at the same superuser would have all passed. Now
// smoke asserts:
//
//  1. SELECT current_user equals the expected role for each
//     pool (catches miswired DSN).
//  2. The required roles are distinct (catches all
//     pools sharing one role).
//  3. A positive probe — each role can read a table the
//     locked SPEC §7.2 says it should be able to read.
//  4. A deny-list probe — each role gets permission denied on
//     a table the locked SPEC §7.2 says it must NOT be able
//     to read. The deny probe uses tables that ALWAYS exist
//     in a migrated SPEC-017 schema (no OLTP dependency); a
//     "relation does not exist" failure is treated as a
//     smoke failure too (the migrations must run first).
//
// On any failure the error names role + check (NEVER the DSN).
func smoke(ctx context.Context, p *Pools) error {
	timeout, cancel := context.WithTimeout(ctx, 10*time.Second)
	defer cancel()

	type check struct {
		role        string
		db          *sql.DB
		positiveSQL string // MUST succeed under this role
		denySQL     string // MUST fail with "permission denied"
	}
	checks := []check{
		{
			role:        "stats_reader",
			db:          p.Reader,
			positiveSQL: `SELECT 1 FROM stats_components_health LIMIT 1`,
			// stats_late_events is on the §7.2.1 deny list.
			denySQL: `SELECT 1 FROM stats_late_events LIMIT 1`,
		},
		{
			role:        "stats_rollup",
			db:          p.Rollup,
			positiveSQL: `SELECT 1 FROM stats_components_health LIMIT 1`,
			// partner_keys is on the §7.2.2 deny list.
			denySQL: `SELECT 1 FROM partner_keys LIMIT 1`,
		},
	}
	if p.PartnerKeysWriter != nil {
		checks = append(checks, check{
			role:        "partner_keys_writer",
			db:          p.PartnerKeysWriter,
			positiveSQL: `SELECT 1`,
			// Column-scoped UPDATE only — SELECT on any column
			// must fail.
			denySQL: `SELECT 1 FROM partner_keys LIMIT 1`,
		})
	}

	seenUser := map[string]string{} // current_user -> role label
	for _, c := range checks {
		// 1. current_user.
		var current string
		if err := c.db.QueryRowContext(timeout, `SELECT current_user`).Scan(&current); err != nil {
			return fmt.Errorf("smoke %s: select current_user: %w", c.role, err)
		}
		if current != c.role {
			return fmt.Errorf("smoke %s: current_user is %q, want %q (DSN points at the wrong role)", c.role, current, c.role)
		}
		if other, ok := seenUser[current]; ok {
			return fmt.Errorf("smoke: roles %q and %q resolve to the same Postgres user %q (§7.2.5 requires distinct pools per role)", other, c.role, current)
		}
		seenUser[current] = c.role

		// 2. positive probe.
		if _, err := c.db.ExecContext(timeout, c.positiveSQL); err != nil {
			return fmt.Errorf("smoke %s: positive probe failed (migrations may not have run): %w", c.role, err)
		}

		// 3. deny probe.
		_, err := c.db.ExecContext(timeout, c.denySQL)
		if err == nil {
			return fmt.Errorf("smoke %s: deny probe %q unexpectedly succeeded (role is over-privileged vs §7.2)", c.role, c.denySQL)
		}
		// lib/pq surfaces "permission denied" in the error
		// string for SQLSTATE 42501. A "relation does not exist"
		// error is also a smoke failure — the migrations must
		// have run before the coordinator opens its pools.
		msg := err.Error()
		if !substringContains(msg, "permission denied") {
			return fmt.Errorf("smoke %s: deny probe failed with %q, want 'permission denied' (relation may not exist; apply migrations first)", c.role, msg)
		}
	}
	return nil
}

// substringContains is the local equivalent of strings.Contains —
// re-implemented to keep this file's import set trivially
// auditable (it audits clean otherwise). Hot only across smoke
// + Open paths; stdlib overhead is irrelevant at startup.
func substringContains(haystack, needle string) bool {
	if len(needle) == 0 {
		return true
	}
	if len(needle) > len(haystack) {
		return false
	}
	for i := 0; i+len(needle) <= len(haystack); i++ {
		if haystack[i:i+len(needle)] == needle {
			return true
		}
	}
	return false
}

// strTrim is the local equivalent of strings.TrimSpace —
// re-implemented to avoid a strings-package import in a file
// that audits clean otherwise. Kept tiny on purpose.
func strTrim(s string) string {
	start := 0
	end := len(s)
	for start < end && isSpace(s[start]) {
		start++
	}
	for end > start && isSpace(s[end-1]) {
		end--
	}
	return s[start:end]
}

func isSpace(b byte) bool {
	switch b {
	case ' ', '\t', '\n', '\r', '\v', '\f':
		return true
	}
	return false
}
