package payout

import (
	"context"
	"database/sql"
	"errors"
	"fmt"
	"time"

	"github.com/rs/zerolog"
)

// Sentinel errors returned by the runtime_flags write path so the
// §6.4.1 endpoint can map them to HTTP status codes without
// re-interpreting opaque SQL errors.
var (
	// ErrFlagAlreadyAtTarget is returned by WriteFlagWithAudit when
	// the requested value matches the current value — the §6.4.1
	// endpoint translates this to 409 Conflict ("already paused"
	// or "already running").
	ErrFlagAlreadyAtTarget = errors.New("payout: runtime flag already at target value")
	// ErrFlagRateLimited is returned by WriteFlagWithAudit when the
	// caller-supplied minInterval bound has not elapsed since the
	// most recent audit row for this flag. Maps to 429.
	ErrFlagRateLimited = errors.New("payout: pause_resume_min_interval not elapsed")
	// ErrFlagMissing is returned when the closed-set flag row is
	// missing entirely — the §4.8a invariant check at startup is
	// supposed to halt the process before this can happen, so this
	// is a 500 / invariant violation, not a 4xx.
	ErrFlagMissing = errors.New("payout: runtime flag row missing (SPEC §4.8a invariant)")
)

// FlagWriteResult is returned to the §6.4.1 endpoint after a
// successful commit. The handler uses AuditID + OldValue +
// NewValue to synthesise the §7.1 event after the post-commit
// CAS claim succeeds.
type FlagWriteResult struct {
	AuditID  int64
	OldValue int
	NewValue int
	Actor    string
	Reason   string
	When     time.Time
}

// RuntimeFlagWriter encapsulates the SPEC §4.8a write+audit+sync-
// emit pipeline so the §6.4.1 endpoints don't reimplement the
// CAS-claim discipline. The reaper at §4.8a step 2 uses the same
// ClaimEmitOnce helper for orphaned audit rows.
type RuntimeFlagWriter struct {
	db  *sql.DB
	log zerolog.Logger
}

// NewRuntimeFlagWriter binds the writer to the shared *sql.DB
// handle. The same handle MUST cover runtime_flags +
// runtime_flag_audit so the BEGIN IMMEDIATE transaction is
// atomic across both tables (same-DB pin per §4.8a).
func NewRuntimeFlagWriter(db *sql.DB, log zerolog.Logger) (*RuntimeFlagWriter, error) {
	if db == nil {
		return nil, fmt.Errorf("payout.NewRuntimeFlagWriter: db is required")
	}
	return &RuntimeFlagWriter{db: db, log: log}, nil
}

// WriteFlagWithAudit performs the SPEC §4.8a write pipeline in
// ONE BEGIN IMMEDIATE transaction:
//
//  1. SELECT current value (lock the runtime_flags row).
//  2. Rate-limit check: most recent runtime_flag_audit row for
//     this flag MUST be older than minInterval (or absent).
//  3. UPDATE runtime_flags SET value = new, updated_at_utc,
//     updated_by_actor, updated_reason WHERE name = flag.
//  4. INSERT INTO runtime_flag_audit (..., emitted_to_log=0).
//  5. COMMIT.
//
// After commit, the caller MUST invoke ClaimAndEmit(audit_id) to
// run the post-commit CAS claim per SPEC §4.8a step 1-2. The
// two-phase split is required because Go's database/sql cannot
// dispatch a follow-on UPDATE inside the SAME txn that returns
// the row id to the caller; CAS-claim must run after the parent
// txn's COMMIT becomes visible to other readers (otherwise the
// reaper could observe emitted_to_log=0 and double-claim).
//
// minInterval == 0 disables rate-limiting (used by tests).
func (w *RuntimeFlagWriter) WriteFlagWithAudit(
	ctx context.Context,
	flag string,
	newValue int,
	actor string,
	reason string,
	minInterval time.Duration,
	now time.Time,
) (FlagWriteResult, error) {
	if newValue != 0 && newValue != 1 {
		return FlagWriteResult{}, fmt.Errorf("payout.WriteFlagWithAudit: newValue must be 0 or 1, got %d", newValue)
	}
	if actor == "" {
		return FlagWriteResult{}, fmt.Errorf("payout.WriteFlagWithAudit: actor required")
	}
	conn, err := w.db.Conn(ctx)
	if err != nil {
		return FlagWriteResult{}, fmt.Errorf("acquire conn: %w", err)
	}
	defer conn.Close()
	if _, err := conn.ExecContext(ctx, `BEGIN IMMEDIATE`); err != nil {
		return FlagWriteResult{}, fmt.Errorf("begin immediate: %w", err)
	}
	committed := false
	defer func() {
		if !committed {
			_, _ = conn.ExecContext(context.Background(), `ROLLBACK`)
		}
	}()

	// Step 1: read current value, row-locked.
	var oldValue int
	err = conn.QueryRowContext(ctx,
		`SELECT value FROM runtime_flags WHERE name = ?`, flag,
	).Scan(&oldValue)
	if err != nil {
		if errors.Is(err, sql.ErrNoRows) {
			return FlagWriteResult{}, ErrFlagMissing
		}
		return FlagWriteResult{}, fmt.Errorf("read %q: %w", flag, err)
	}
	if oldValue == newValue {
		return FlagWriteResult{}, ErrFlagAlreadyAtTarget
	}

	// Step 2: rate-limit against most recent audit row.
	if minInterval > 0 {
		var lastUTC sql.NullString
		err = conn.QueryRowContext(ctx,
			`SELECT occurred_at_utc FROM runtime_flag_audit WHERE flag_name = ? ORDER BY id DESC LIMIT 1`,
			flag,
		).Scan(&lastUTC)
		if err != nil && !errors.Is(err, sql.ErrNoRows) {
			return FlagWriteResult{}, fmt.Errorf("read last audit %q: %w", flag, err)
		}
		if lastUTC.Valid {
			last, parseErr := time.Parse(time.RFC3339Nano, lastUTC.String)
			if parseErr == nil && now.Sub(last) < minInterval {
				return FlagWriteResult{}, ErrFlagRateLimited
			}
		}
	}

	stamp := now.UTC().Format(time.RFC3339Nano)

	// Step 3: UPDATE runtime_flags.
	if _, err := conn.ExecContext(ctx,
		`UPDATE runtime_flags
		    SET value = ?,
		        updated_at_utc = ?,
		        updated_by_actor = ?,
		        updated_reason = ?
		  WHERE name = ?`,
		newValue, stamp, actor, reason, flag,
	); err != nil {
		return FlagWriteResult{}, fmt.Errorf("update %q: %w", flag, err)
	}

	// Step 4: INSERT runtime_flag_audit.
	res, err := conn.ExecContext(ctx,
		`INSERT INTO runtime_flag_audit
		    (flag_name, old_value, new_value, actor, reason, occurred_at_utc, emitted_to_log)
		 VALUES (?, ?, ?, ?, ?, ?, 0)`,
		flag, oldValue, newValue, actor, reason, stamp,
	)
	if err != nil {
		return FlagWriteResult{}, fmt.Errorf("insert audit %q: %w", flag, err)
	}
	auditID, err := res.LastInsertId()
	if err != nil {
		return FlagWriteResult{}, fmt.Errorf("audit row id: %w", err)
	}

	// Step 5: COMMIT.
	if _, err := conn.ExecContext(ctx, `COMMIT`); err != nil {
		return FlagWriteResult{}, fmt.Errorf("commit flag write: %w", err)
	}
	committed = true

	return FlagWriteResult{
		AuditID:  auditID,
		OldValue: oldValue,
		NewValue: newValue,
		Actor:    actor,
		Reason:   reason,
		When:     now,
	}, nil
}

// ClaimAndEmit runs the SPEC §4.8a post-commit CAS claim against
// the named audit row. If the CAS UPDATE returns 1 row, the caller
// has the right to emit the §7.1 zerolog event and this function
// invokes emit(). If 0 rows, another emitter (sync or reaper) has
// already claimed the row and emit is skipped.
//
// emit MUST be deterministic given (auditID, flagName, oldValue,
// newValue, actor, reason, occurredAtUTC) read from the audit row;
// the reaper invokes the same closure to honor the at-most-once
// contract via CAS.
func (w *RuntimeFlagWriter) ClaimAndEmit(
	ctx context.Context,
	auditID int64,
	emit func(row AuditRow),
) error {
	conn, err := w.db.Conn(ctx)
	if err != nil {
		return fmt.Errorf("acquire conn: %w", err)
	}
	defer conn.Close()
	if _, err := conn.ExecContext(ctx, `BEGIN IMMEDIATE`); err != nil {
		return fmt.Errorf("begin immediate: %w", err)
	}
	committed := false
	defer func() {
		if !committed {
			_, _ = conn.ExecContext(context.Background(), `ROLLBACK`)
		}
	}()

	var got int64
	err = conn.QueryRowContext(ctx,
		`UPDATE runtime_flag_audit
		    SET emitted_to_log = 1
		  WHERE id = ? AND emitted_to_log = 0
		 RETURNING id`,
		auditID,
	).Scan(&got)
	if err != nil {
		if errors.Is(err, sql.ErrNoRows) {
			// Another emitter beat us. Commit the no-op txn and
			// return without invoking emit.
			if _, cerr := conn.ExecContext(ctx, `COMMIT`); cerr != nil {
				return fmt.Errorf("commit empty cas: %w", cerr)
			}
			committed = true
			return nil
		}
		return fmt.Errorf("cas claim: %w", err)
	}

	// Read the row INSIDE the same transaction so the emit
	// payload reflects the committed audit record verbatim.
	row, err := readAuditRowTx(ctx, conn, got)
	if err != nil {
		return fmt.Errorf("read audit row %d: %w", got, err)
	}

	if _, err := conn.ExecContext(ctx, `COMMIT`); err != nil {
		return fmt.Errorf("commit cas: %w", err)
	}
	committed = true

	if emit != nil {
		emit(row)
	}
	return nil
}

// AuditRow is the committed runtime_flag_audit payload used to
// synthesise §7.1 events. The reaper and the §6.4.1 sync emitter
// both go through this struct so the wire format is identical.
type AuditRow struct {
	ID            int64
	FlagName      string
	OldValue      int
	NewValue      int
	Actor         string
	Reason        string
	OccurredAtUTC string
}

// readAuditRowTx reads a runtime_flag_audit row inside an open
// connection transaction. Used by ClaimAndEmit after the CAS
// returns 1 row.
func readAuditRowTx(ctx context.Context, conn *sql.Conn, id int64) (AuditRow, error) {
	var r AuditRow
	err := conn.QueryRowContext(ctx,
		`SELECT id, flag_name, old_value, new_value, actor, reason, occurred_at_utc
		   FROM runtime_flag_audit
		  WHERE id = ?`, id,
	).Scan(&r.ID, &r.FlagName, &r.OldValue, &r.NewValue, &r.Actor, &r.Reason, &r.OccurredAtUTC)
	if err != nil {
		return AuditRow{}, err
	}
	return r, nil
}

// ListUnemittedOlderThan returns all runtime_flag_audit rows with
// emitted_to_log = 0 AND occurred_at_utc < cutoff. The reaper
// (§4.8a) consumes this list and CAS-claims each row before
// emitting.
func (w *RuntimeFlagWriter) ListUnemittedOlderThan(ctx context.Context, cutoff time.Time) ([]int64, error) {
	cutoffStr := cutoff.UTC().Format(time.RFC3339Nano)
	rows, err := w.db.QueryContext(ctx,
		`SELECT id FROM runtime_flag_audit
		  WHERE emitted_to_log = 0
		    AND occurred_at_utc < ?
		  ORDER BY id ASC`, cutoffStr,
	)
	if err != nil {
		return nil, fmt.Errorf("list unemitted: %w", err)
	}
	defer rows.Close()
	var out []int64
	for rows.Next() {
		var id int64
		if err := rows.Scan(&id); err != nil {
			return nil, err
		}
		out = append(out, id)
	}
	if err := rows.Err(); err != nil {
		return nil, err
	}
	return out, nil
}
