package billing

// SPEC-022 R-16 compute-integrity earnings holds (SPEC-036 FR-23/FR-25).
//
// A held hold removes a provider's credits for one model inside its window
// from the payable view and from the weekly settlement selection. Nothing is
// voided, quarantined or burned, and a hold never expires: it is released
// only by SPEC-036 recovery (recovery holds) or by an audited operator
// release. Every hold write bumps the earnings rollup buckets of the credits
// it covers, inside the writer's statement (triggers below).

import (
	"context"
	"database/sql"
	"errors"
	"fmt"
	"strings"
	"time"

	"github.com/augstar/macprovider-coordinator/internal/computeintegrity"
)

// ErrComputeIntegrityHoldNotFound is returned when a release names no hold.
var ErrComputeIntegrityHoldNotFound = computeintegrity.ErrHoldNotFound

// ErrComputeIntegrityHoldReleased is returned when a release names a hold
// that is already released.
var ErrComputeIntegrityHoldReleased = computeintegrity.ErrHoldAlreadyReleased

func (s *Store) ensureComputeIntegrityHolds(ctx context.Context) error {
	_, err := s.db.ExecContext(ctx, `
CREATE TABLE IF NOT EXISTS compute_integrity_earnings_holds (
    id               INTEGER PRIMARY KEY AUTOINCREMENT,
    provider_id      TEXT NOT NULL,
    model_id         TEXT NOT NULL,
    kind             TEXT NOT NULL CHECK(kind IN ('failure','recovery')),
    window_start_utc TEXT NOT NULL,
    window_end_utc   TEXT NULL,
    reason           TEXT NOT NULL,
    status           TEXT NOT NULL CHECK(status IN ('held','released')),
    created_at_utc   TEXT NOT NULL,
    released_at_utc  TEXT NULL,
    released_by      TEXT NULL,
    release_reason   TEXT NULL,
    CHECK(window_end_utc IS NULL OR window_end_utc >= window_start_utc),
    CHECK((status = 'held') = (released_at_utc IS NULL))
);
CREATE INDEX IF NOT EXISTS idx_cieh_provider_model ON compute_integrity_earnings_holds(provider_id, model_id, status);
CREATE INDEX IF NOT EXISTS idx_lrc_provider_model_ts ON ledger_request_credits(provider_id, model, ts_utc);
`)
	return err
}

// computeIntegrityHoldExclusionSQL is the SPEC-022 R-16.2 predicate over a
// ledger_request_credits alias. The payable view and the weekly settlement
// selection share it. A credit already settled into a payout is never
// withheld (R-16.3), so a hold cannot invalidate or strand a payout.
func computeIntegrityHoldExclusionSQL(alias string) string {
	return `(` + alias + `.settled = 1 OR NOT EXISTS (
       SELECT 1
         FROM compute_integrity_earnings_holds cieh
        WHERE cieh.status = 'held'
          AND cieh.provider_id = ` + alias + `.provider_id
          AND cieh.model_id = ` + alias + `.model
          AND ` + alias + `.ts_utc >= cieh.window_start_utc
          AND (cieh.window_end_utc IS NULL OR ` + alias + `.ts_utc <= cieh.window_end_utc)
   ))`
}

func computeIntegrityHoldCreditMatchSQL(row string) string {
	return `c.provider_id = ` + row + `.provider_id
       AND c.model = ` + row + `.model_id
       AND c.ts_utc >= ` + row + `.window_start_utc
       AND (` + row + `.window_end_utc IS NULL OR c.ts_utc <= ` + row + `.window_end_utc)`
}

// computeIntegrityHoldRollupTriggers bump the earnings rollup of every
// credit a hold covers before and after each write (SPEC-022 R-16.6).
func computeIntegrityHoldRollupTriggers() []earningsRollupTrigger {
	mark := func(row string) string {
		return earningsMarkSQL("ledger_request_credits c", computeIntegrityHoldCreditMatchSQL(row))
	}
	return []earningsRollupTrigger{
		{"trg_per_cieh_insert", `CREATE TRIGGER trg_per_cieh_insert AFTER INSERT ON compute_integrity_earnings_holds
BEGIN
    ` + mark("NEW") + `
END`},
		{"trg_per_cieh_update", `CREATE TRIGGER trg_per_cieh_update AFTER UPDATE ON compute_integrity_earnings_holds
BEGIN
    ` + mark("OLD") + `
    ` + mark("NEW") + `
END`},
		{"trg_per_cieh_delete", `CREATE TRIGGER trg_per_cieh_delete AFTER DELETE ON compute_integrity_earnings_holds
BEGIN
    ` + mark("OLD") + `
END`},
		// The hold predicate reads settled, which the credit triggers do not
		// watch: a held credit whose settled flag changes changes the view,
		// so bump its bucket when a held hold covers it.
		{"trg_per_cieh_lrc_settled", `CREATE TRIGGER trg_per_cieh_lrc_settled AFTER UPDATE OF settled ON ledger_request_credits
WHEN OLD.settled IS NOT NEW.settled AND EXISTS (
    SELECT 1 FROM compute_integrity_earnings_holds cieh
     WHERE cieh.status = 'held' AND cieh.provider_id = NEW.provider_id AND cieh.model_id = NEW.model
       AND NEW.ts_utc >= cieh.window_start_utc
       AND (cieh.window_end_utc IS NULL OR NEW.ts_utc <= cieh.window_end_utc))
BEGIN
    ` + earningsMarkBucketSQL("NEW.provider_id", "NEW.ts_utc") + `
END`},
	}
}

type holdExecutor interface {
	ExecContext(context.Context, string, ...any) (sql.Result, error)
}

// ApplyComputeIntegrityHoldAction applies one SPEC-036 FR-23 hold action
// inside tx, so the hold and the verification state commit together. tx must
// be on this store's database.
func (s *Store) ApplyComputeIntegrityHoldAction(ctx context.Context, tx *sql.Tx, providerID, modelID string, action computeintegrity.HoldAction, reason string, now time.Time) error {
	if s == nil || tx == nil {
		return errors.New("compute-integrity hold: store and transaction are required")
	}
	switch action.Kind {
	case computeintegrity.HoldActionNone:
		return nil
	case computeintegrity.HoldActionOpenFailure:
		end := action.End
		_, err := openComputeIntegrityHoldExec(ctx, tx, providerID, modelID, computeintegrity.HoldKindFailure, action.Start, &end, reason, now)
		return err
	case computeintegrity.HoldActionOpenRecovery:
		_, err := openComputeIntegrityHoldExec(ctx, tx, providerID, modelID, computeintegrity.HoldKindRecovery, action.Start, nil, reason, now)
		return err
	case computeintegrity.HoldActionReleaseRecovery:
		return closeComputeIntegrityRecoveryHoldExec(ctx, tx, providerID, modelID, action.End, true, now)
	case computeintegrity.HoldActionCloseRecovery:
		return closeComputeIntegrityRecoveryHoldExec(ctx, tx, providerID, modelID, action.End, false, now)
	}
	return fmt.Errorf("compute-integrity hold: unknown action %q", action.Kind)
}

// OpenComputeIntegrityHold creates a held hold. end nil leaves the window
// open (a recovery hold).
func (s *Store) OpenComputeIntegrityHold(ctx context.Context, providerID, modelID string, kind computeintegrity.HoldKind, start time.Time, end *time.Time, reason string, now time.Time) (int64, error) {
	if s == nil {
		return 0, errors.New("billing store is nil")
	}
	tx, err := s.db.BeginTx(ctx, nil)
	if err != nil {
		return 0, err
	}
	defer func() { _ = tx.Rollback() }()
	id, err := openComputeIntegrityHoldExec(ctx, tx, providerID, modelID, kind, start, end, reason, now)
	if err != nil {
		return 0, err
	}
	return id, tx.Commit()
}

// openComputeIntegrityHoldExec writes a held hold and raises the billing
// compatibility floor to contract 5 in the same transaction, so no binary
// that would pay held credits can open the database afterwards.
func openComputeIntegrityHoldExec(ctx context.Context, db holdExecutor, providerID, modelID string, kind computeintegrity.HoldKind, start time.Time, end *time.Time, reason string, now time.Time) (int64, error) {
	if providerID == "" || modelID == "" || start.IsZero() {
		return 0, errors.New("compute-integrity hold: provider, model and window start are required")
	}
	if kind != computeintegrity.HoldKindFailure && kind != computeintegrity.HoldKindRecovery {
		return 0, fmt.Errorf("compute-integrity hold: unknown kind %q", kind)
	}
	var endText any
	if end != nil {
		if end.Before(start) {
			return 0, errors.New("compute-integrity hold: window end before start")
		}
		endText = sqliteTimeText(*end)
	}
	if err := recordBillingCompatFloorExec(ctx, db, billingCompatContractComputeIntegrityHold); err != nil {
		return 0, err
	}
	res, err := db.ExecContext(ctx, `
INSERT INTO compute_integrity_earnings_holds (provider_id, model_id, kind, window_start_utc, window_end_utc, reason, status, created_at_utc)
VALUES (?, ?, ?, ?, ?, ?, 'held', ?)`,
		providerID, modelID, string(kind), sqliteTimeText(start), endText, reason, sqliteTimeText(now))
	if err != nil {
		return 0, err
	}
	return res.LastInsertId()
}

// CloseComputeIntegrityRecoveryHold closes the open recovery hold of one key
// at end, and releases it when release is set (SPEC-036 FR-23 recovery).
func (s *Store) CloseComputeIntegrityRecoveryHold(ctx context.Context, providerID, modelID string, end time.Time, release bool, now time.Time) error {
	if s == nil {
		return errors.New("billing store is nil")
	}
	return closeComputeIntegrityRecoveryHoldExec(ctx, s.db, providerID, modelID, end, release, now)
}

func closeComputeIntegrityRecoveryHoldExec(ctx context.Context, db holdExecutor, providerID, modelID string, end time.Time, release bool, now time.Time) error {
	endText := sqliteTimeText(end)
	if release {
		_, err := db.ExecContext(ctx, `
UPDATE compute_integrity_earnings_holds
   SET window_end_utc = MAX(?, window_start_utc), status = 'released', released_at_utc = ?,
       released_by = 'compute_integrity_recovery', release_reason = 'recovery_passed'
 WHERE provider_id = ? AND model_id = ? AND kind = 'recovery' AND window_end_utc IS NULL AND status = 'held'`,
			endText, sqliteTimeText(now), providerID, modelID)
		return err
	}
	_, err := db.ExecContext(ctx, `
UPDATE compute_integrity_earnings_holds
   SET window_end_utc = MAX(?, window_start_utc)
 WHERE provider_id = ? AND model_id = ? AND kind = 'recovery' AND window_end_utc IS NULL AND status = 'held'`,
		endText, providerID, modelID)
	return err
}

// ReleaseComputeIntegrityHold is the audited operator release (SPEC-022
// R-16.4 (b)).
func (s *Store) ReleaseComputeIntegrityHold(ctx context.Context, holdID int64, operatorID, reason string, now time.Time) (computeintegrity.EarningsHold, error) {
	if s == nil {
		return computeintegrity.EarningsHold{}, errors.New("billing store is nil")
	}
	if strings.TrimSpace(operatorID) == "" || strings.TrimSpace(reason) == "" {
		return computeintegrity.EarningsHold{}, errors.New("compute-integrity hold release: operator_id and reason are required")
	}
	res, err := s.db.ExecContext(ctx, `
UPDATE compute_integrity_earnings_holds
   SET status = 'released', released_at_utc = ?, released_by = ?, release_reason = ?
 WHERE id = ? AND status = 'held'`, sqliteTimeText(now), operatorID, reason, holdID)
	if err != nil {
		return computeintegrity.EarningsHold{}, err
	}
	n, err := res.RowsAffected()
	if err != nil {
		return computeintegrity.EarningsHold{}, err
	}
	hold, found, err := s.computeIntegrityHold(ctx, holdID)
	if err != nil {
		return computeintegrity.EarningsHold{}, err
	}
	if !found {
		return computeintegrity.EarningsHold{}, ErrComputeIntegrityHoldNotFound
	}
	if n == 0 {
		return hold, ErrComputeIntegrityHoldReleased
	}
	return hold, nil
}

const computeIntegrityHoldColumns = `
SELECT h.id, h.provider_id, h.model_id, h.kind, h.window_start_utc, h.window_end_utc, h.reason, h.status,
       h.created_at_utc, h.released_at_utc, COALESCE(h.released_by, ''), COALESCE(h.release_reason, ''),
       COALESCE((SELECT SUM(c.provider_credits)
                   FROM ledger_request_credits c
                  WHERE c.settled = 0 AND ` + "c.provider_id = h.provider_id AND c.model = h.model_id AND c.ts_utc >= h.window_start_utc AND (h.window_end_utc IS NULL OR c.ts_utc <= h.window_end_utc)" + `), 0)
  FROM compute_integrity_earnings_holds h`

func scanComputeIntegrityHold(scan func(...any) error) (computeintegrity.EarningsHold, error) {
	var h computeintegrity.EarningsHold
	var kind, status, start, created string
	var end, released sql.NullString
	if err := scan(&h.ID, &h.ProviderID, &h.ModelID, &kind, &start, &end, &h.Reason, &status, &created, &released, &h.ReleasedBy, &h.ReleaseReason, &h.HeldCredits); err != nil {
		return h, err
	}
	h.Kind = computeintegrity.HoldKind(kind)
	h.Status = computeintegrity.HoldStatus(status)
	var err error
	if h.WindowStart, err = time.Parse(time.RFC3339Nano, start); err != nil {
		return h, err
	}
	if h.CreatedAt, err = time.Parse(time.RFC3339Nano, created); err != nil {
		return h, err
	}
	if end.Valid {
		t, err := time.Parse(time.RFC3339Nano, end.String)
		if err != nil {
			return h, err
		}
		h.WindowEnd = &t
	}
	if released.Valid {
		t, err := time.Parse(time.RFC3339Nano, released.String)
		if err != nil {
			return h, err
		}
		h.ReleasedAt = &t
	}
	if h.Status == computeintegrity.HoldReleased {
		h.HeldCredits = 0
	}
	return h, nil
}

func (s *Store) computeIntegrityHold(ctx context.Context, holdID int64) (computeintegrity.EarningsHold, bool, error) {
	row := s.db.QueryRowContext(ctx, computeIntegrityHoldColumns+` WHERE h.id = ?`, holdID)
	h, err := scanComputeIntegrityHold(row.Scan)
	if errors.Is(err, sql.ErrNoRows) {
		return h, false, nil
	}
	return h, err == nil, err
}

// ComputeIntegrityHolds lists a provider's holds, newest first, with the
// provider credits each held hold currently withholds (SPEC-022 R-16.7).
func (s *Store) ComputeIntegrityHolds(ctx context.Context, providerID string) ([]computeintegrity.EarningsHold, error) {
	if s == nil {
		return nil, errors.New("billing store is nil")
	}
	rows, err := s.db.QueryContext(ctx, computeIntegrityHoldColumns+` WHERE h.provider_id = ? ORDER BY h.id DESC LIMIT 100`, providerID)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	var out []computeintegrity.EarningsHold
	for rows.Next() {
		h, err := scanComputeIntegrityHold(rows.Scan)
		if err != nil {
			return nil, err
		}
		out = append(out, h)
	}
	return out, rows.Err()
}

// CountHeldComputeIntegrityHolds is the FR-25 gauge source.
func (s *Store) CountHeldComputeIntegrityHolds(ctx context.Context) (int, error) {
	if s == nil {
		return 0, errors.New("billing store is nil")
	}
	var n int
	err := s.db.QueryRowContext(ctx, `SELECT COUNT(*) FROM compute_integrity_earnings_holds WHERE status = 'held'`).Scan(&n)
	return n, err
}
