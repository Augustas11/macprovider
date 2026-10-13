package billing

import (
	"context"
	"database/sql"
	"errors"
	"fmt"
	"math/big"
	"sort"
	"time"
)

// SPEC-050 MALIBU stake allowance: the daily, non-withdrawable inference
// allowance an account receives for staked MALIBU. Allowance amounts are
// SPEC-005 credits. Grants, holds, splits, and overage events live here in
// the coordinator SQLite billing database (SPEC-050-R013); the stake itself
// lives in the rewards Postgres ledger behind AllowanceStakeSource.

// AllowanceUnitsPerMALIBU is the stake unit scale: 1 MALIBU = 1e8 units,
// the NUMERIC(24,8) scale of the SPEC-021 ledger.
const AllowanceUnitsPerMALIBU int64 = 100_000_000

// AllowanceStake is one account's earning stake, in 1e-8 MALIBU units, and
// the GitHub identity that owns the providers behind it.
type AllowanceStake struct {
	AccountID    string
	GitHubUserID int64
	Units        int64
}

// AllowanceStakeSource is the SPEC-050-R001 stake source interface: the
// earning stake of every account for the UTC day starting at dayStart.
type AllowanceStakeSource interface {
	Name() string
	EarningStakes(ctx context.Context, dayStart time.Time, minAge time.Duration) ([]AllowanceStake, error)
}

// AllowancePolicy is the operator sizing of the allowance (SPEC-050 §4).
type AllowancePolicy struct {
	DailyBudgetCredits        int64
	CreditsPerMALIBU          int64
	PerAccountDailyCapCredits int64
	MinStakeAge               time.Duration
}

// AllowanceGrant is one account's allowance for one UTC day.
type AllowanceGrant struct {
	AccountID      string
	GitHubUserID   int64
	StakeUnits     int64
	RawCredits     int64
	GrantedCredits int64
}

// AllowanceRefreshTotals is the run-level audit of one refresh.
type AllowanceRefreshTotals struct {
	TotalStakeUnits     int64
	TotalRawCredits     int64
	TotalGrantedCredits int64
	ScalePPM            int64
}

const allowanceSchema = `
CREATE TABLE IF NOT EXISTS allowance_refresh_runs (
    day TEXT PRIMARY KEY CHECK(length(day) = 10),
    budget_credits INTEGER NOT NULL CHECK(budget_credits >= 0),
    credits_per_malibu INTEGER NOT NULL CHECK(credits_per_malibu >= 0),
    per_account_cap_credits INTEGER NOT NULL CHECK(per_account_cap_credits >= 0),
    stake_source TEXT NOT NULL,
    total_stake_units INTEGER NOT NULL CHECK(total_stake_units >= 0),
    total_raw_credits INTEGER NOT NULL CHECK(total_raw_credits >= 0),
    total_granted_credits INTEGER NOT NULL CHECK(total_granted_credits >= 0 AND total_granted_credits <= budget_credits),
    scale_ppm INTEGER NOT NULL CHECK(scale_ppm BETWEEN 0 AND 1000000),
    account_count INTEGER NOT NULL CHECK(account_count >= 0),
    created_at_utc TEXT NOT NULL
);
CREATE TABLE IF NOT EXISTS allowance_grants (
    account_id TEXT NOT NULL,
    day TEXT NOT NULL REFERENCES allowance_refresh_runs(day),
    github_user_id INTEGER NOT NULL CHECK(github_user_id >= 0),
    stake_units INTEGER NOT NULL CHECK(stake_units >= 0),
    raw_credits INTEGER NOT NULL CHECK(raw_credits >= 0),
    granted_credits INTEGER NOT NULL CHECK(granted_credits >= 0 AND granted_credits <= raw_credits),
    created_at_utc TEXT NOT NULL,
    PRIMARY KEY(account_id, day)
);
CREATE TRIGGER IF NOT EXISTS allowance_refresh_runs_append_only_update
BEFORE UPDATE ON allowance_refresh_runs BEGIN SELECT RAISE(ABORT, 'allowance_refresh_runs is append-only'); END;
CREATE TRIGGER IF NOT EXISTS allowance_refresh_runs_append_only_delete
BEFORE DELETE ON allowance_refresh_runs BEGIN SELECT RAISE(ABORT, 'allowance_refresh_runs is append-only'); END;
CREATE TRIGGER IF NOT EXISTS allowance_grants_append_only_update
BEFORE UPDATE ON allowance_grants BEGIN SELECT RAISE(ABORT, 'allowance_grants is append-only'); END;
CREATE TRIGGER IF NOT EXISTS allowance_grants_append_only_delete
BEFORE DELETE ON allowance_grants BEGIN SELECT RAISE(ABORT, 'allowance_grants is append-only'); END;
`

func (s *Store) ensureAllowanceTables(ctx context.Context) error {
	if _, err := s.db.ExecContext(ctx, allowanceSchema); err != nil {
		return fmt.Errorf("allowance schema: %w", err)
	}
	return s.ensureAllowanceSpendTables(ctx)
}

// allowanceDay is the UTC calendar day of t as YYYY-MM-DD.
func allowanceDay(t time.Time) string { return t.UTC().Format("2006-01-02") }

// allowanceDayStart is 00:00 UTC of t's day.
func allowanceDayStart(t time.Time) time.Time {
	u := t.UTC()
	return time.Date(u.Year(), u.Month(), u.Day(), 0, 0, 0, 0, time.UTC)
}

// NextAllowanceRefresh is the next 00:00 UTC after t.
func NextAllowanceRefresh(t time.Time) time.Time { return allowanceDayStart(t).Add(24 * time.Hour) }

// ComputeAllowanceGrants applies SPEC-050-R005: raw = min(floor(stake *
// rate), cap) per account; when the raw total exceeds the budget every grant
// is floor(raw * budget / total). Integer arithmetic only; a stake in 1e-8
// MALIBU units is converted with floor division.
func ComputeAllowanceGrants(stakes []AllowanceStake, policy AllowancePolicy) ([]AllowanceGrant, AllowanceRefreshTotals) {
	unitsPerToken := big.NewInt(AllowanceUnitsPerMALIBU)
	rate := big.NewInt(policy.CreditsPerMALIBU)
	capCredits := big.NewInt(policy.PerAccountDailyCapCredits)
	grants := make([]AllowanceGrant, 0, len(stakes))
	totalRaw := new(big.Int)
	totalStake := new(big.Int)
	var totals AllowanceRefreshTotals
	for _, s := range stakes {
		if s.Units <= 0 || s.AccountID == "" {
			continue
		}
		totalStake.Add(totalStake, big.NewInt(s.Units))
		raw := new(big.Int).Mul(big.NewInt(s.Units), rate)
		raw.Quo(raw, unitsPerToken)
		if raw.Cmp(capCredits) > 0 {
			raw.Set(capCredits)
		}
		if raw.Sign() < 0 {
			raw.SetInt64(0)
		}
		// Every earning account gets a grant row, a zero one included, so
		// the run's audit lists every stake it saw (SPEC-050-R006).
		totalRaw.Add(totalRaw, raw)
		grants = append(grants, AllowanceGrant{AccountID: s.AccountID, GitHubUserID: s.GitHubUserID, StakeUnits: s.Units, RawCredits: raw.Int64()})
	}
	budget := big.NewInt(policy.DailyBudgetCredits)
	scaled := totalRaw.Cmp(budget) > 0
	totals.ScalePPM = 1_000_000
	if scaled {
		ppm := new(big.Int).Mul(budget, big.NewInt(1_000_000))
		totals.ScalePPM = ppm.Quo(ppm, totalRaw).Int64()
	}
	totals.TotalRawCredits = clampBigInt64(totalRaw)
	totals.TotalStakeUnits = clampBigInt64(totalStake)
	out := grants[:0]
	for _, g := range grants {
		granted := g.RawCredits
		if scaled && totalRaw.Sign() > 0 {
			v := new(big.Int).Mul(big.NewInt(g.RawCredits), budget)
			granted = v.Quo(v, totalRaw).Int64()
		}
		g.GrantedCredits = granted
		totals.TotalGrantedCredits += granted
		out = append(out, g)
	}
	sort.Slice(out, func(i, j int) bool { return out[i].AccountID < out[j].AccountID })
	return out, totals
}

func clampBigInt64(v *big.Int) int64 {
	if v.IsInt64() {
		return v.Int64()
	}
	return 1<<63 - 1
}

// withImmediateTx runs fn inside one BEGIN IMMEDIATE transaction on a
// dedicated connection (modernc sqlite's BeginTx does not take the write lock
// up front).
func (s *Store) withImmediateTx(ctx context.Context, fn func(conn *sql.Conn) error) error {
	conn, err := s.db.Conn(ctx)
	if err != nil {
		return err
	}
	defer conn.Close()
	if _, err := conn.ExecContext(ctx, `BEGIN IMMEDIATE`); err != nil {
		return err
	}
	committed := false
	defer func() {
		if !committed {
			_, _ = conn.ExecContext(context.Background(), `ROLLBACK`)
		}
	}()
	if err := fn(conn); err != nil {
		return err
	}
	if _, err := conn.ExecContext(ctx, `COMMIT`); err != nil {
		return err
	}
	committed = true
	return nil
}

// ErrAllowanceStakeSourceUnavailable means no stake source is wired; the
// refresh records nothing and retries (SPEC-050-R005).
var ErrAllowanceStakeSourceUnavailable = errors.New("allowance: stake source unavailable")

// RefreshAllowanceDay computes and records the allowance for the UTC day
// containing now. It is idempotent per day: if the day's run exists it
// returns (false, nil) and changes nothing (SPEC-050-R005). The run record
// and every grant commit in one transaction (SPEC-050-R006).
func (s *Store) RefreshAllowanceDay(ctx context.Context, now time.Time, src AllowanceStakeSource, policy AllowancePolicy) (bool, AllowanceRefreshTotals, error) {
	day := allowanceDay(now)
	exists, err := s.allowanceRunExists(ctx, s.db, day)
	if err != nil || exists {
		return false, AllowanceRefreshTotals{}, err
	}
	if src == nil {
		return false, AllowanceRefreshTotals{}, ErrAllowanceStakeSourceUnavailable
	}
	stakes, err := src.EarningStakes(ctx, allowanceDayStart(now), policy.MinStakeAge)
	if err != nil {
		return false, AllowanceRefreshTotals{}, fmt.Errorf("allowance: stake source: %w", err)
	}
	grants, totals := ComputeAllowanceGrants(stakes, policy)
	created := false
	err = s.withImmediateTx(ctx, func(conn *sql.Conn) error {
		exists, err := s.allowanceRunExists(ctx, conn, day)
		if err != nil || exists {
			return err
		}
		createdAt := now.UTC().Format(time.RFC3339Nano)
		if _, err := conn.ExecContext(ctx, `
INSERT INTO allowance_refresh_runs (day, budget_credits, credits_per_malibu, per_account_cap_credits, stake_source,
    total_stake_units, total_raw_credits, total_granted_credits, scale_ppm, account_count, created_at_utc)
VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)`,
			day, policy.DailyBudgetCredits, policy.CreditsPerMALIBU, policy.PerAccountDailyCapCredits, src.Name(),
			totals.TotalStakeUnits, totals.TotalRawCredits, totals.TotalGrantedCredits, totals.ScalePPM, len(grants), createdAt); err != nil {
			return fmt.Errorf("allowance: insert run: %w", err)
		}
		for _, g := range grants {
			if _, err := conn.ExecContext(ctx, `
INSERT INTO allowance_grants (account_id, day, github_user_id, stake_units, raw_credits, granted_credits, created_at_utc)
VALUES (?, ?, ?, ?, ?, ?, ?)`, g.AccountID, day, g.GitHubUserID, g.StakeUnits, g.RawCredits, g.GrantedCredits, createdAt); err != nil {
				return fmt.Errorf("allowance: insert grant: %w", err)
			}
		}
		created = true
		return nil
	})
	if err != nil {
		return false, AllowanceRefreshTotals{}, err
	}
	return created, totals, nil
}

type allowanceQueryer interface {
	QueryRowContext(ctx context.Context, query string, args ...any) *sql.Row
}

func (s *Store) allowanceRunExists(ctx context.Context, q allowanceQueryer, day string) (bool, error) {
	var n int
	if err := q.QueryRowContext(ctx, `SELECT COUNT(1) FROM allowance_refresh_runs WHERE day = ?`, day).Scan(&n); err != nil {
		return false, fmt.Errorf("allowance: run lookup: %w", err)
	}
	return n > 0, nil
}

// AllowanceGrantFor returns the account's granted credits for the UTC day of
// now (0 when none).
func (s *Store) AllowanceGrantFor(ctx context.Context, accountID string, now time.Time) (int64, error) {
	var granted int64
	err := s.db.QueryRowContext(ctx, `SELECT granted_credits FROM allowance_grants WHERE account_id = ? AND day = ?`, accountID, allowanceDay(now)).Scan(&granted)
	if errors.Is(err, sql.ErrNoRows) {
		return 0, nil
	}
	return granted, err
}
