// Package rewards implements SPEC-MALIBU-EMISSION-LEDGER bootstrap
// accrual: periodic MALIBU emission, per-wallet caps, and withdrawal
// hold enforcement. Money-path code — changes require PR + audit.
package rewards

import (
	"context"
	"database/sql"
	"errors"
	"fmt"
	"sync"
	"time"

	"github.com/rs/zerolog"
)

// Hold reasons — closed vocabulary per spec §2.1.
const (
	HoldTrustTierProvisional = "trust_tier_provisional"
	HoldPerWalletDailyCap    = "per_wallet_daily_cap"
	HoldDemotionCooldown     = "demotion_cooldown"
)

// Trust tiers.
const (
	TierProvisional = "provisional"
	TierTrusted     = "trusted"
)

// Config is the operator-tunable malibu_emission block.
type Config struct {
	Enabled                      bool
	WriterDSN                    string
	TickInterval                 time.Duration
	UsefulWorkEnabled            bool
	UsefulWorkInterval           time.Duration
	ProviderDailyCapMALIBU       float64
	WalletDailyCapMALIBU         float64
	UsefulWorkMALIBUPer1KCredits float64
	SQLitePayoutDBPath           string
	PayoutHotWalletAddress       string
	WalletMirrorInterval         time.Duration
	UnlockEvalInterval           time.Duration
	MaxSerializableRetries       int
	BaseUSDCBalanceRPCURLs       []string
}

// DefaultsApplied fills zero values with spec defaults.
func (c Config) DefaultsApplied() Config {
	out := c
	if out.TickInterval <= 0 {
		out.TickInterval = 15 * time.Minute
	}
	if out.UsefulWorkInterval <= 0 {
		out.UsefulWorkInterval = out.TickInterval
	}
	if out.ProviderDailyCapMALIBU <= 0 {
		out.ProviderDailyCapMALIBU = 25
	}
	if out.WalletDailyCapMALIBU <= 0 {
		out.WalletDailyCapMALIBU = 100
	}
	if out.UsefulWorkMALIBUPer1KCredits <= 0 {
		out.UsefulWorkMALIBUPer1KCredits = 1
	}
	if out.WalletMirrorInterval <= 0 {
		out.WalletMirrorInterval = 5 * time.Minute
	}
	if out.UnlockEvalInterval <= 0 {
		out.UnlockEvalInterval = time.Hour
	}
	if out.MaxSerializableRetries <= 0 {
		out.MaxSerializableRetries = 5
	}
	return out
}

func (c Config) Validate() error {
	if !c.Enabled {
		return nil
	}
	if c.WriterDSN == "" {
		return errors.New("malibu_emission.writer_dsn is required when enabled")
	}
	if c.SQLitePayoutDBPath == "" {
		return errors.New("malibu_emission.sqlite_payout_db_path is required when enabled")
	}
	return nil
}

// Runner orchestrates emission tick, wallet mirror, and unlock evaluation.
type Runner struct {
	db             *sql.DB
	cfg            Config
	logger         zerolog.Logger
	connectivity   ProviderConnectivity
	balanceChecker WalletBalanceChecker
	observerMu     sync.RWMutex
	observer       TrustTierObserver
}

// RunnerDeps optional integrations for Phase C2 unlock evaluation.
type RunnerDeps struct {
	Connectivity   ProviderConnectivity
	BalanceChecker WalletBalanceChecker
	TrustObserver  TrustTierObserver
}

// New constructs a Runner. db MUST be authenticated as rewards_writer.
func New(db *sql.DB, cfg Config, logger zerolog.Logger, deps RunnerDeps) (*Runner, error) {
	if db == nil {
		return nil, errors.New("rewards: db is required")
	}
	applied := cfg.DefaultsApplied()
	if err := applied.Validate(); err != nil {
		return nil, err
	}
	return &Runner{
		db:             db,
		cfg:            applied,
		logger:         logger,
		connectivity:   deps.Connectivity,
		balanceChecker: deps.BalanceChecker,
		observer:       deps.TrustObserver,
	}, nil
}

// SetConnectivity wires live pool heartbeat state after the WS server starts.
func (r *Runner) SetConnectivity(c ProviderConnectivity) {
	if r != nil {
		r.connectivity = c
	}
}

func (r *Runner) SetTrustTierObserver(observer TrustTierObserver) {
	if r == nil {
		return
	}
	r.observerMu.Lock()
	defer r.observerMu.Unlock()
	r.observer = observer
}

// Start launches background goroutines until ctx is cancelled.
func (r *Runner) Start(ctx context.Context) {
	go r.loop(ctx, r.cfg.TickInterval, "emission_tick", r.runEmissionTick)
	if r.cfg.UsefulWorkEnabled {
		go r.loop(ctx, r.cfg.UsefulWorkInterval, "useful_work_accrual", r.runUsefulWorkAccrual)
	}
	go r.loop(ctx, r.cfg.WalletMirrorInterval, "wallet_mirror", r.runWalletMirror)
	go r.loop(ctx, r.cfg.UnlockEvalInterval, "unlock_eval", r.runUnlockEval)
}

func (r *Runner) loop(ctx context.Context, interval time.Duration, name string, fn func(context.Context) error) {
	ticker := time.NewTicker(interval)
	defer ticker.Stop()
	log := r.logger.With().Str("job", name).Logger()
	for {
		select {
		case <-ctx.Done():
			return
		case <-ticker.C:
			if err := fn(ctx); err != nil {
				log.Warn().Err(err).Msg("rewards job failed")
			}
		}
	}
}

// EnsureProviderState seeds emission state for a provider (idempotent).
func EnsureProviderState(ctx context.Context, db *sql.DB, providerID string) error {
	if providerID == "" {
		return errors.New("provider_id is required")
	}
	_, err := db.ExecContext(ctx, `
        INSERT INTO provider_emission_state (provider_id, trust_tier)
        VALUES ($1, $2)
        ON CONFLICT (provider_id) DO NOTHING
    `, providerID, TierProvisional)
	return err
}

// AccrualBalance returns total and withdrawable MALIBU for a provider.
type AccrualBalance struct {
	AccruedMALIBU       string
	WithdrawableMALIBU  string
	HeldMALIBU          string
	TrustTier           string
	HoldReasons         []string
	ProviderDailyCapped bool
	ProviderDailyCap    float64
	WalletDailyCap      float64
}

// QueryAccrualBalance reads ledger aggregates for the provider read API.
func QueryAccrualBalance(ctx context.Context, db *sql.DB, providerID string, cfg Config) (AccrualBalance, error) {
	cfg = cfg.DefaultsApplied()
	var tier string
	err := db.QueryRowContext(ctx, `
        SELECT COALESCE(trust_tier, $2)
          FROM provider_emission_state
         WHERE provider_id = $1
    `, providerID, TierProvisional).Scan(&tier)
	if err == sql.ErrNoRows {
		tier = TierProvisional
	} else if err != nil {
		return AccrualBalance{}, fmt.Errorf("trust tier: %w", err)
	}

	var accrued, withdrawable string
	if err := db.QueryRowContext(ctx, `
        SELECT COALESCE(SUM(amount_malibu), 0)::TEXT,
               COALESCE(SUM(amount_malibu) FILTER (WHERE withdrawal_hold_reason IS NULL), 0)::TEXT
          FROM provider_rewards_ledger
         WHERE provider_id = $1 AND amount_malibu IS NOT NULL
    `, providerID).Scan(&accrued, &withdrawable); err != nil {
		return AccrualBalance{}, fmt.Errorf("ledger sum: %w", err)
	}

	rows, err := db.QueryContext(ctx, `
        SELECT DISTINCT withdrawal_hold_reason
          FROM provider_rewards_ledger
         WHERE provider_id = $1
           AND amount_malibu IS NOT NULL
           AND amount_malibu > 0
           AND withdrawal_hold_reason IS NOT NULL
    `, providerID)
	if err != nil {
		return AccrualBalance{}, fmt.Errorf("hold reasons: %w", err)
	}
	defer rows.Close()
	var holds []string
	for rows.Next() {
		var h string
		if err := rows.Scan(&h); err != nil {
			return AccrualBalance{}, err
		}
		holds = append(holds, h)
	}
	if err := rows.Err(); err != nil {
		return AccrualBalance{}, err
	}

	walletCapAppliedToday, err := walletDailyCapAppliedToday(ctx, db, providerID)
	if err != nil {
		return AccrualBalance{}, fmt.Errorf("wallet cap audit state: %w", err)
	}
	if walletCapAppliedToday && !containsReason(holds, HoldPerWalletDailyCap) {
		holds = append(holds, HoldPerWalletDailyCap)
	}
	providerDailyCapped, err := providerDailyCapActiveToday(ctx, db, providerID, cfg.ProviderDailyCapMALIBU)
	if err != nil {
		return AccrualBalance{}, fmt.Errorf("provider cap state: %w", err)
	}

	held := subtractDecimalStrings(accrued, withdrawable)
	return AccrualBalance{
		AccruedMALIBU:       accrued,
		WithdrawableMALIBU:  withdrawable,
		HeldMALIBU:          held,
		TrustTier:           tier,
		HoldReasons:         holds,
		ProviderDailyCapped: providerDailyCapped,
		ProviderDailyCap:    cfg.ProviderDailyCapMALIBU,
		WalletDailyCap:      cfg.WalletDailyCapMALIBU,
	}, nil
}

func providerDailyCapActiveToday(ctx context.Context, db *sql.DB, providerID string, cap float64) (bool, error) {
	if cap <= 0 {
		return false, nil
	}
	var exists bool
	err := db.QueryRowContext(ctx, `
        SELECT EXISTS (
            SELECT 1
              FROM provider_emission_state
             WHERE provider_id = $1
               AND emission_day = $2
               AND provider_day_malibu >= $3::NUMERIC(24,8)
        )
    `, providerID, utcDay(time.Now().UTC()), formatMALIBU(cap)).Scan(&exists)
	return exists, err
}

func walletDailyCapAppliedToday(ctx context.Context, db *sql.DB, providerID string) (bool, error) {
	var exists bool
	err := db.QueryRowContext(ctx, `
        SELECT EXISTS (
            SELECT 1
              FROM malibu_reward_audit_events applied
             WHERE applied.provider_id = $1
               AND applied.event_type = $2
               AND applied.occurred_at >= $3
               AND NOT EXISTS (
                   SELECT 1
                     FROM malibu_reward_audit_events cleared
                    WHERE cleared.provider_id = applied.provider_id
                      AND cleared.ledger_id = applied.ledger_id
                      AND cleared.event_type = $4
                      AND cleared.withdrawal_hold_reason = $5
                      AND cleared.id > applied.id
               )
        )
    `, providerID, AuditEventWalletDailyCapApplied, utcDay(time.Now().UTC()), AuditEventMalibuHoldCleared, HoldPerWalletDailyCap).Scan(&exists)
	return exists, err
}

func subtractDecimalStrings(a, b string) string {
	// Simple numeric subtraction via Postgres-compatible formatting in caller tests;
	// for display we use a lightweight approach when b <= a.
	if a == "" || a == "0" {
		return "0"
	}
	if b == "" || b == "0" {
		return a
	}
	// Delegate to SQL in production path when needed; inline for read API is fine
	// since both values come from the same SUM query above.
	var held string
	_ = held
	// Use fmt for common case
	var af, bf float64
	fmt.Sscanf(a, "%f", &af)
	fmt.Sscanf(b, "%f", &bf)
	diff := af - bf
	if diff < 0 {
		diff = 0
	}
	return fmt.Sprintf("%.8f", diff)
}
