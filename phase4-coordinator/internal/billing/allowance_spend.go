package billing

import (
	"context"
	"database/sql"
	"errors"
	"fmt"
	"math/big"
	"time"
)

// SPEC-050-R007/R008: allowance-first spend ordering, the overage setting,
// and the per-request allowance/paid split.
//
// The coordinator chat handler calls AdmitAllowance when a request arrives
// with the gateway's allowance headers, before any provider is dispatched. An
// "allowance" answer holds the request's credit bound against today's grant;
// the handler closes the hold when it ends, writing one split row per ledger
// row of the request and the real spend (sum of gross_credits). Provider
// credits are never touched (SPEC-050-R009).

const (
	AllowanceFundingAllowance = "allowance"
	AllowanceFundingPaid      = "paid"
	AllowanceFundingRefused   = "refused"
)

const allowanceSpendSchema = `
CREATE TABLE IF NOT EXISTS allowance_overage_events (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    account_id TEXT NOT NULL,
    enabled INTEGER NOT NULL CHECK(enabled IN (0,1)),
    created_at_utc TEXT NOT NULL
);
CREATE INDEX IF NOT EXISTS idx_allowance_overage_account ON allowance_overage_events(account_id, id);
CREATE TRIGGER IF NOT EXISTS allowance_overage_events_append_only_update
BEFORE UPDATE ON allowance_overage_events BEGIN SELECT RAISE(ABORT, 'allowance_overage_events is append-only'); END;
CREATE TRIGGER IF NOT EXISTS allowance_overage_events_append_only_delete
BEFORE DELETE ON allowance_overage_events BEGIN SELECT RAISE(ABORT, 'allowance_overage_events is append-only'); END;
CREATE TABLE IF NOT EXISTS allowance_reservations (
    account_id TEXT NOT NULL,
    request_id TEXT NOT NULL,
    day TEXT NOT NULL CHECK(length(day) = 10),
    funding TEXT NOT NULL CHECK(funding IN ('allowance','paid')),
    model TEXT NOT NULL,
    bound_credits INTEGER NOT NULL CHECK(bound_credits >= 0),
    status TEXT NOT NULL CHECK(status IN ('active','closed')),
    spent_credits INTEGER NOT NULL DEFAULT 0 CHECK(spent_credits >= 0),
    created_at_utc TEXT NOT NULL,
    closed_at_utc TEXT NULL,
    PRIMARY KEY(account_id, request_id),
    CHECK(funding = 'allowance' OR (bound_credits = 0 AND spent_credits = 0))
);
CREATE INDEX IF NOT EXISTS idx_allowance_reservations_day ON allowance_reservations(account_id, day, status);
CREATE INDEX IF NOT EXISTS idx_allowance_reservations_status ON allowance_reservations(status, created_at_utc);
CREATE TABLE IF NOT EXISTS allowance_request_splits (
    request_id TEXT NOT NULL,
    attempt_n INTEGER NOT NULL,
    provider_id TEXT NOT NULL,
    account_id TEXT NOT NULL,
    external_request_id TEXT NOT NULL,
    day TEXT NOT NULL,
    funding TEXT NOT NULL CHECK(funding IN ('allowance','paid')),
    gross_credits INTEGER NOT NULL CHECK(gross_credits >= 0),
    allowance_credits INTEGER NOT NULL CHECK(allowance_credits >= 0),
    paid_credits INTEGER NOT NULL CHECK(paid_credits >= 0),
    rewards_excluded INTEGER NOT NULL CHECK(rewards_excluded IN (0,1)),
    created_at_utc TEXT NOT NULL,
    PRIMARY KEY(request_id, attempt_n, provider_id),
    CHECK(allowance_credits + paid_credits = gross_credits),
    CHECK((funding = 'allowance' AND paid_credits = 0) OR (funding = 'paid' AND allowance_credits = 0))
);
CREATE INDEX IF NOT EXISTS idx_allowance_splits_account ON allowance_request_splits(account_id, external_request_id);
CREATE TRIGGER IF NOT EXISTS allowance_request_splits_append_only_update
BEFORE UPDATE ON allowance_request_splits BEGIN SELECT RAISE(ABORT, 'allowance_request_splits is append-only'); END;
CREATE TRIGGER IF NOT EXISTS allowance_request_splits_append_only_delete
BEFORE DELETE ON allowance_request_splits BEGIN SELECT RAISE(ABORT, 'allowance_request_splits is append-only'); END;
`

func (s *Store) ensureAllowanceSpendTables(ctx context.Context) error {
	if _, err := s.db.ExecContext(ctx, allowanceSpendSchema); err != nil {
		return fmt.Errorf("allowance spend schema: %w", err)
	}
	return nil
}

// AllowanceAdmission is the admission question for one request. Required
// is set when the gateway's paid quota cannot take the request, so only the
// allowance may fund it.
type AllowanceAdmission struct {
	AccountID    string
	RequestID    string
	Model        string
	BoundCredits int64
	Required     bool
	Now          time.Time
}

// AllowanceDecision answers AllowanceAdmission.
type AllowanceDecision struct {
	Funding          string
	HasAllowance     bool
	OverageEnabled   bool
	GrantedCredits   int64
	RemainingCredits int64
	ResetAt          time.Time
}

// AllowanceStatus is the account's allowance for the account view.
type AllowanceStatus struct {
	Day              string
	GrantedCredits   int64
	SpentCredits     int64
	HeldCredits      int64
	RemainingCredits int64
	OverageEnabled   bool
	NextRefreshAt    time.Time
}

var ErrAllowanceInvalidAdmission = errors.New("allowance: invalid admission")

type allowanceDB interface {
	QueryRowContext(ctx context.Context, query string, args ...any) *sql.Row
	QueryContext(ctx context.Context, query string, args ...any) (*sql.Rows, error)
	ExecContext(ctx context.Context, query string, args ...any) (sql.Result, error)
}

func allowanceOverage(ctx context.Context, q allowanceDB, accountID string) (bool, error) {
	var enabled int
	err := q.QueryRowContext(ctx, `SELECT enabled FROM allowance_overage_events WHERE account_id = ? ORDER BY id DESC LIMIT 1`, accountID).Scan(&enabled)
	if errors.Is(err, sql.ErrNoRows) {
		return true, nil // SPEC-050-R007: overage defaults to on
	}
	if err != nil {
		return false, fmt.Errorf("allowance: overage: %w", err)
	}
	return enabled == 1, nil
}

// allowanceBalance is the account's grant, closed spend, and active holds for
// one day. Remaining is floored at zero (SPEC-050-R008).
func allowanceBalance(ctx context.Context, q allowanceDB, accountID, day string) (granted, spent, held int64, err error) {
	if err = q.QueryRowContext(ctx, `SELECT COALESCE((SELECT granted_credits FROM allowance_grants WHERE account_id = ? AND day = ?), 0)`, accountID, day).Scan(&granted); err != nil {
		return 0, 0, 0, fmt.Errorf("allowance: grant: %w", err)
	}
	if err = q.QueryRowContext(ctx, `
SELECT COALESCE(SUM(CASE WHEN status = 'closed' THEN spent_credits ELSE 0 END), 0),
       COALESCE(SUM(CASE WHEN status = 'active' THEN bound_credits ELSE 0 END), 0)
  FROM allowance_reservations
 WHERE account_id = ? AND day = ? AND funding = 'allowance'`, accountID, day).Scan(&spent, &held); err != nil {
		return 0, 0, 0, fmt.Errorf("allowance: balance: %w", err)
	}
	return granted, spent, held, nil
}

func remainingAllowance(granted, spent, held int64) int64 {
	if r := granted - spent - held; r > 0 {
		return r
	}
	return 0
}

// AdmitAllowance decides how one request is funded (SPEC-050-R007), in one
// BEGIN IMMEDIATE transaction so two concurrent requests cannot both hold the
// same allowance. A repeated request id (a gateway retry) returns its first
// decision and keeps its hold.
func (s *Store) AdmitAllowance(ctx context.Context, in AllowanceAdmission) (AllowanceDecision, error) {
	if in.AccountID == "" || in.RequestID == "" || len(in.RequestID) > 256 || in.BoundCredits < 0 {
		return AllowanceDecision{}, ErrAllowanceInvalidAdmission
	}
	if in.Now.IsZero() {
		in.Now = time.Now().UTC()
	}
	day := allowanceDay(in.Now)
	decision := AllowanceDecision{ResetAt: NextAllowanceRefresh(in.Now)}
	// Fast path, read-only: an account without an allowance today takes no
	// write lock. Grants are append-only and fixed for the day, so the
	// answer cannot change under a concurrent writer.
	var granted int64
	if err := s.db.QueryRowContext(ctx, `SELECT COALESCE((SELECT granted_credits FROM allowance_grants WHERE account_id = ? AND day = ?), 0)`,
		in.AccountID, day).Scan(&granted); err != nil {
		return AllowanceDecision{}, fmt.Errorf("allowance: grant: %w", err)
	}
	if granted <= 0 {
		overage, err := allowanceOverage(ctx, s.db, in.AccountID)
		if err != nil {
			return AllowanceDecision{}, err
		}
		decision.OverageEnabled = overage
		decision.Funding = AllowanceFundingRefused
		if overage && !in.Required {
			decision.Funding = AllowanceFundingPaid
		}
		return decision, nil
	}
	err := s.withImmediateTx(ctx, func(conn *sql.Conn) error {
		overage, err := allowanceOverage(ctx, conn, in.AccountID)
		if err != nil {
			return err
		}
		decision.OverageEnabled = overage
		granted, spent, held, err := allowanceBalance(ctx, conn, in.AccountID, day)
		if err != nil {
			return err
		}
		decision.GrantedCredits = granted
		decision.HasAllowance = granted > 0
		var existing string
		switch err := conn.QueryRowContext(ctx, `SELECT funding FROM allowance_reservations WHERE account_id = ? AND request_id = ?`, in.AccountID, in.RequestID).Scan(&existing); {
		case err == nil:
			decision.Funding = existing
			decision.RemainingCredits = remainingAllowance(granted, spent, held)
			return nil
		case !errors.Is(err, sql.ErrNoRows):
			return fmt.Errorf("allowance: reservation lookup: %w", err)
		}
		remaining := remainingAllowance(granted, spent, held)
		funding := AllowanceFundingRefused
		switch {
		case granted > 0 && in.BoundCredits <= remaining:
			funding = AllowanceFundingAllowance
		case overage && !in.Required:
			funding = AllowanceFundingPaid
		}
		decision.Funding = funding
		decision.RemainingCredits = remaining
		// Only accounts with an allowance today get a reservation row; a
		// paid request of any other account leaves no trace here.
		if granted <= 0 || funding == AllowanceFundingRefused {
			return nil
		}
		bound := int64(0)
		if funding == AllowanceFundingAllowance {
			bound = in.BoundCredits
			decision.RemainingCredits = remaining - bound
		}
		_, err = conn.ExecContext(ctx, `
INSERT INTO allowance_reservations (account_id, request_id, day, funding, model, bound_credits, status, created_at_utc)
VALUES (?, ?, ?, ?, ?, ?, 'active', ?)`, in.AccountID, in.RequestID, day, funding, in.Model, bound, in.Now.UTC().Format(time.RFC3339Nano))
		if err != nil {
			return fmt.Errorf("allowance: insert reservation: %w", err)
		}
		return nil
	})
	if err != nil {
		return AllowanceDecision{}, err
	}
	return decision, nil
}

// CloseAllowanceReservation writes one split row per ledger row of the
// request and records its spend (SPEC-050-R008). It is idempotent and
// re-entrant: closing again after a gateway retry adds the new attempts'
// splits and recomputes the spend from the append-only split rows.
func (s *Store) CloseAllowanceReservation(ctx context.Context, accountID, requestID string, now time.Time) error {
	if accountID == "" || requestID == "" {
		return nil
	}
	return s.withImmediateTx(ctx, func(conn *sql.Conn) error {
		return closeAllowanceReservationTx(ctx, conn, accountID, requestID, now)
	})
}

type allowanceLedgerRow struct {
	requestID       string
	attemptN        int64
	providerID      string
	grossCredits    int64
	rewardsExcluded int64
}

func closeAllowanceReservationTx(ctx context.Context, conn allowanceDB, accountID, requestID string, now time.Time) error {
	var funding, status, day string
	err := conn.QueryRowContext(ctx, `SELECT funding, status, day FROM allowance_reservations WHERE account_id = ? AND request_id = ?`, accountID, requestID).Scan(&funding, &status, &day)
	if errors.Is(err, sql.ErrNoRows) {
		return nil
	}
	if err != nil {
		return fmt.Errorf("allowance: close lookup: %w", err)
	}
	rows, err := conn.QueryContext(ctx, `
SELECT lrc.request_id, lrc.attempt_n, lrc.provider_id, lrc.gross_credits, lrc.rewards_excluded
  FROM ledger_request_credits lrc
 WHERE lrc.request_id IN (
       SELECT rl.request_id FROM request_log rl
        WHERE rl.account_id = ? AND rl.external_request_id = ?)
 ORDER BY lrc.request_id, lrc.attempt_n, lrc.provider_id`, accountID, requestID)
	if err != nil {
		return fmt.Errorf("allowance: ledger rows: %w", err)
	}
	var ledger []allowanceLedgerRow
	for rows.Next() {
		var r allowanceLedgerRow
		if err := rows.Scan(&r.requestID, &r.attemptN, &r.providerID, &r.grossCredits, &r.rewardsExcluded); err != nil {
			rows.Close()
			return err
		}
		ledger = append(ledger, r)
	}
	if err := rows.Err(); err != nil {
		rows.Close()
		return err
	}
	rows.Close()
	createdAt := now.UTC().Format(time.RFC3339Nano)
	for _, r := range ledger {
		allowanceCredits, paidCredits := int64(0), r.grossCredits
		if funding == AllowanceFundingAllowance {
			allowanceCredits, paidCredits = r.grossCredits, 0
		}
		if _, err := conn.ExecContext(ctx, `
INSERT OR IGNORE INTO allowance_request_splits (request_id, attempt_n, provider_id, account_id, external_request_id, day, funding,
    gross_credits, allowance_credits, paid_credits, rewards_excluded, created_at_utc)
VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)`,
			r.requestID, r.attemptN, r.providerID, accountID, requestID, day, funding,
			r.grossCredits, allowanceCredits, paidCredits, r.rewardsExcluded, createdAt); err != nil {
			return fmt.Errorf("allowance: insert split: %w", err)
		}
	}
	var spent int64
	if err := conn.QueryRowContext(ctx, `
SELECT COALESCE(SUM(allowance_credits), 0) FROM allowance_request_splits
 WHERE account_id = ? AND external_request_id = ?`, accountID, requestID).Scan(&spent); err != nil {
		return fmt.Errorf("allowance: spent: %w", err)
	}
	if _, err := conn.ExecContext(ctx, `
UPDATE allowance_reservations SET status = 'closed', spent_credits = ?, closed_at_utc = COALESCE(closed_at_utc, ?)
 WHERE account_id = ? AND request_id = ? AND status IN ('active', 'closed')`, spent, createdAt, accountID, requestID); err != nil {
		return fmt.Errorf("allowance: close: %w", err)
	}
	return nil
}

// ReapAllowanceReservations closes holds still open after maxAge, for
// example after a coordinator crash between admission and the handler's
// close (SPEC-050-R008). By then any recovered ledger rows are in place.
func (s *Store) ReapAllowanceReservations(ctx context.Context, now time.Time, maxAge time.Duration) (int64, error) {
	rows, err := s.db.QueryContext(ctx, `
SELECT account_id, request_id FROM allowance_reservations
 WHERE status = 'active' AND created_at_utc < ?
 LIMIT 500`, now.Add(-maxAge).UTC().Format(time.RFC3339Nano))
	if err != nil {
		return 0, fmt.Errorf("allowance: reap: %w", err)
	}
	type key struct{ account, request string }
	var stale []key
	for rows.Next() {
		var k key
		if err := rows.Scan(&k.account, &k.request); err != nil {
			rows.Close()
			return 0, err
		}
		stale = append(stale, k)
	}
	if err := rows.Err(); err != nil {
		rows.Close()
		return 0, err
	}
	rows.Close()
	var closed int64
	for _, k := range stale {
		if err := s.CloseAllowanceReservation(ctx, k.account, k.request, now); err != nil {
			return closed, err
		}
		closed++
	}
	return closed, nil
}

// SetAllowanceOverage appends the account's overage setting.
func (s *Store) SetAllowanceOverage(ctx context.Context, accountID string, enabled bool, now time.Time) error {
	if accountID == "" {
		return ErrAllowanceInvalidAdmission
	}
	v := 0
	if enabled {
		v = 1
	}
	_, err := s.db.ExecContext(ctx, `INSERT INTO allowance_overage_events (account_id, enabled, created_at_utc) VALUES (?, ?, ?)`,
		accountID, v, now.UTC().Format(time.RFC3339Nano))
	return err
}

// AllowanceStatusFor reports the account's allowance for the UTC day of now.
func (s *Store) AllowanceStatusFor(ctx context.Context, accountID string, now time.Time) (AllowanceStatus, error) {
	day := allowanceDay(now)
	overage, err := allowanceOverage(ctx, s.db, accountID)
	if err != nil {
		return AllowanceStatus{}, err
	}
	granted, spent, held, err := allowanceBalance(ctx, s.db, accountID, day)
	if err != nil {
		return AllowanceStatus{}, err
	}
	return AllowanceStatus{
		Day: day, GrantedCredits: granted, SpentCredits: spent, HeldCredits: held,
		RemainingCredits: remainingAllowance(granted, spent, held),
		OverageEnabled:   overage, NextRefreshAt: NextAllowanceRefresh(now),
	}, nil
}

// AllowanceCreditBound is a request's SPEC-050 credit bound: gross credits of
// promptTokens uncached prompt tokens and completionTokens completion tokens
// at rate and multiplierPPM, rounded up so it is never below the gross the
// ledger later records for the same or fewer tokens. Unlike the ledger
// formula it applies no usage validation: an out-of-range count gives a large
// bound, never a zero one. The result saturates at the int64 maximum.
func AllowanceCreditBound(rate RateCardEntry, multiplierPPM, promptTokens, completionTokens int64) int64 {
	if promptTokens < 0 {
		promptTokens = 0
	}
	if completionTokens < 0 {
		completionTokens = 0
	}
	n := new(big.Int).Mul(big.NewInt(promptTokens), big.NewInt(rate.PromptCreditsPerMtok))
	n.Add(n, new(big.Int).Mul(big.NewInt(completionTokens), big.NewInt(rate.CompletionCreditsPerMtok)))
	n.Mul(n, big.NewInt(multiplierPPM))
	d := big.NewInt(1_000_000_000_000)
	n.Add(n, new(big.Int).Sub(d, big.NewInt(1)))
	n.Quo(n, d)
	if n.Sign() < 0 {
		return 0
	}
	return clampBigInt64(n)
}
