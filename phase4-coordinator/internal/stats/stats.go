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

	// DSN per active runtime role. When Enabled = true, the three
	// always-required DSNs MUST be non-empty.
	ReaderDSN         string
	RollupDSN         string
	ProviderPortalDSN string

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

// RollupConfig — Step 1 declares fields Step 2 needs so Step 2's
// PR is a code-only change. Step 1 itself does not consume Rollup.
type RollupConfig struct {
	// BackfillMode is one of "partial" (Path A, default) or
	// "full" (Path B). See SPEC §9.7.
	BackfillMode string
	// PartialHistorySince is the RFC 3339 rollup-start timestamp
	// in Path A. Empty when BackfillMode = "full".
	PartialHistorySince string
	// LateEventsRetentionDays — SPEC §9.3 (v0.1.7). Default 90;
	// floor 30. The rollup refuses to start (or clamps + warns)
	// if below floor (Step 2 decides the failure mode).
	LateEventsRetentionDays int
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

// Pools holds one *sql.DB per active runtime role. Per SPEC §7.2.5,
// no two roles MAY share a pool.
//
// Reader, Rollup, ProviderPortal are non-nil whenever Open returns
// nil. PartnerKeysWriter is nil unless
// Config.PartnerKeys.LastUsedAtUpdatesEnabled was true at Open
// time (BUILD §C.2 + §D.5).
type Pools struct {
	Reader            *sql.DB
	Rollup            *sql.DB
	ProviderPortal    *sql.DB
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
	for _, db := range []*sql.DB{p.Reader, p.Rollup, p.ProviderPortal, p.PartnerKeysWriter} {
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

	portal, err := openPool(cfg.ProviderPortalDSN, poolTuneWrite())
	if err != nil {
		_ = pools.Close()
		return nil, fmt.Errorf("provider_portal: %w", err)
	}
	pools.ProviderPortal = portal

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
	if strTrim(cfg.ProviderPortalDSN) == "" {
		return errors.New("provider_portal_dsn is required when stats.enabled = true")
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

// smoke runs a per-pool PingContext under a short timeout so a
// hung DSN cannot block coordinator startup indefinitely.
func smoke(ctx context.Context, p *Pools) error {
	timeout, cancel := context.WithTimeout(ctx, 5*time.Second)
	defer cancel()
	pools := []struct {
		name string
		db   *sql.DB
	}{
		{"stats_reader", p.Reader},
		{"stats_rollup", p.Rollup},
		{"provider_portal", p.ProviderPortal},
	}
	if p.PartnerKeysWriter != nil {
		pools = append(pools, struct {
			name string
			db   *sql.DB
		}{"partner_keys_writer", p.PartnerKeysWriter})
	}
	for _, item := range pools {
		if err := item.db.PingContext(timeout); err != nil {
			// Include role name + driver error class, NEVER the
			// DSN. BUILD §C.3 SECURITY invariant.
			return fmt.Errorf("smoke %s: %w", item.name, err)
		}
	}
	return nil
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
