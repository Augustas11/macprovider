package computeintegrity

// SPEC-036 FR-20/FR-23/FR-24 persistence: verification due times, key states
// and scorer exclusions survive coordinator restarts. No prompt, output or token data is
// stored.

import (
	"context"
	"database/sql"
	"encoding/json"
	"errors"
	"fmt"
	"time"
)

var errScoringStoreClosed = errors.New("compute-integrity scoring store is closed")

// ScoringStore persists FR-23 key states and FR-24 scorer exclusions.
type ScoringStore struct {
	db *sql.DB
}

// NewScoringStore migrates the tables and returns the store.
func NewScoringStore(ctx context.Context, db *sql.DB) (*ScoringStore, error) {
	if db == nil {
		return nil, errScoringStoreClosed
	}
	_, err := db.ExecContext(ctx, `
CREATE TABLE IF NOT EXISTS compute_integrity_scoring_keys (
    provider_id    TEXT NOT NULL,
    model_id       TEXT NOT NULL,
    state          TEXT NOT NULL CHECK(state IN ('unverified','passing','suspect','failed','recovering')),
    state_json     TEXT NOT NULL,
    updated_at_utc TEXT NOT NULL,
    PRIMARY KEY(provider_id, model_id)
) WITHOUT ROWID;
CREATE TABLE IF NOT EXISTS compute_integrity_scorer_exclusions (
    provider_id     TEXT PRIMARY KEY,
    excluded_at_utc TEXT NOT NULL
) WITHOUT ROWID;
CREATE TABLE IF NOT EXISTS compute_integrity_probe_schedule (
    provider_id     TEXT NOT NULL,
    model_id        TEXT NOT NULL,
    next_due_at_utc TEXT NOT NULL,
    updated_at_utc  TEXT NOT NULL,
    PRIMARY KEY(provider_id, model_id)
) WITHOUT ROWID;
CREATE INDEX IF NOT EXISTS idx_cips_updated ON compute_integrity_probe_schedule(updated_at_utc);
`)
	if err != nil {
		return nil, err
	}
	if err := ensureVerificationStarts(ctx, db); err != nil {
		return nil, err
	}
	return &ScoringStore{db: db}, nil
}

// ensureVerificationStarts creates the start table and, when it is new,
// backfills it in the same transaction: an earlier build counted starts from
// the reserved cip_ accounts in the request log, so the last two hours carry
// over once. If the backfill fails, the table creation rolls back with it
// and the next start retries both.
func ensureVerificationStarts(ctx context.Context, db *sql.DB) error {
	tx, err := db.BeginTx(ctx, nil)
	if err != nil {
		return err
	}
	defer func() { _ = tx.Rollback() }()
	var exists int
	if err := tx.QueryRowContext(ctx, `SELECT COUNT(*) FROM sqlite_master WHERE type = 'table' AND name = 'compute_integrity_verification_starts'`).Scan(&exists); err != nil {
		return err
	}
	if exists == 1 {
		_, err := tx.ExecContext(ctx, `CREATE INDEX IF NOT EXISTS idx_civs_started ON compute_integrity_verification_starts(started_at_utc)`)
		if err != nil {
			return err
		}
		return tx.Commit()
	}
	if _, err := tx.ExecContext(ctx, `
CREATE TABLE compute_integrity_verification_starts (
    started_at_utc TEXT NOT NULL
);
CREATE INDEX idx_civs_started ON compute_integrity_verification_starts(started_at_utc);
`); err != nil {
		return err
	}
	if err := backfillVerificationStarts(ctx, tx); err != nil {
		return err
	}
	return tx.Commit()
}

func backfillVerificationStarts(ctx context.Context, db interface {
	QueryRowContext(context.Context, string, ...any) *sql.Row
	ExecContext(context.Context, string, ...any) (sql.Result, error)
}) error {
	var present int
	if err := db.QueryRowContext(ctx, `SELECT COUNT(*) FROM sqlite_master WHERE type = 'table' AND name = 'request_log'`).Scan(&present); err != nil || present == 0 {
		return err
	}
	since := time.Now().Add(-2 * time.Hour).UTC().Format(verificationStartFormat)
	_, err := db.ExecContext(ctx, `
INSERT INTO compute_integrity_verification_starts (started_at_utc)
SELECT ts_utc FROM request_log WHERE account_id LIKE 'cip\_%' ESCAPE '\' AND ts_utc >= ?`, since)
	return err
}

// LoadKeyStates returns every persisted key state. A row whose JSON does not
// decode or names an unknown state fails the load: the caller must not
// silently forget a failed key.
func (s *ScoringStore) LoadKeyStates(ctx context.Context) ([]*KeyState, error) {
	if s == nil || s.db == nil {
		return nil, errScoringStoreClosed
	}
	rows, err := s.db.QueryContext(ctx, `SELECT provider_id, model_id, state_json FROM compute_integrity_scoring_keys`)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	var out []*KeyState
	for rows.Next() {
		var providerID, modelID, raw string
		if err := rows.Scan(&providerID, &modelID, &raw); err != nil {
			return nil, err
		}
		var k KeyState
		if err := json.Unmarshal([]byte(raw), &k); err != nil {
			return nil, fmt.Errorf("compute-integrity key state %s/%s: %w", providerID, modelID, err)
		}
		if k.ProviderID != providerID || k.ModelID != modelID || !k.State.Known() {
			return nil, fmt.Errorf("compute-integrity key state %s/%s is inconsistent", providerID, modelID)
		}
		out = append(out, &k)
	}
	return out, rows.Err()
}

// BeginTx opens a transaction on the store's database. A state transition
// writes its SPEC-022 R-16 hold change and the new state in one transaction
// (the hold table lives in the same database).
func (s *ScoringStore) BeginTx(ctx context.Context) (*sql.Tx, error) {
	if s == nil || s.db == nil {
		return nil, errScoringStoreClosed
	}
	return s.db.BeginTx(ctx, nil)
}

type scoringExecutor interface {
	ExecContext(context.Context, string, ...any) (sql.Result, error)
}

// UpsertKeyState persists one key state.
func (s *ScoringStore) UpsertKeyState(ctx context.Context, k *KeyState, now time.Time) error {
	if s == nil || s.db == nil {
		return errScoringStoreClosed
	}
	return upsertKeyStateExec(ctx, s.db, k, now)
}

// UpsertKeyStateTx persists one key state inside tx.
func (s *ScoringStore) UpsertKeyStateTx(ctx context.Context, tx *sql.Tx, k *KeyState, now time.Time) error {
	if s == nil || tx == nil {
		return errScoringStoreClosed
	}
	return upsertKeyStateExec(ctx, tx, k, now)
}

func upsertKeyStateExec(ctx context.Context, db scoringExecutor, k *KeyState, now time.Time) error {
	if k == nil || !k.State.Known() {
		return fmt.Errorf("compute-integrity key state is invalid")
	}
	raw, err := json.Marshal(k)
	if err != nil {
		return err
	}
	_, err = db.ExecContext(ctx, `
INSERT INTO compute_integrity_scoring_keys (provider_id, model_id, state, state_json, updated_at_utc)
VALUES (?, ?, ?, ?, ?)
ON CONFLICT(provider_id, model_id) DO UPDATE SET
    state = excluded.state, state_json = excluded.state_json, updated_at_utc = excluded.updated_at_utc`,
		k.ProviderID, k.ModelID, string(k.State), string(raw), now.UTC().Format(time.RFC3339Nano))
	return err
}

// PruneStaleKeyStates deletes durable unverified and passing rows not
// updated since cutoff. Adverse states are never pruned.
func (s *ScoringStore) PruneStaleKeyStates(ctx context.Context, cutoff time.Time) (int64, error) {
	if s == nil || s.db == nil {
		return 0, errScoringStoreClosed
	}
	res, err := s.db.ExecContext(ctx, `
DELETE FROM compute_integrity_scoring_keys
 WHERE state IN ('unverified', 'passing') AND updated_at_utc < ?`, cutoff.UTC().Format(time.RFC3339Nano))
	if err != nil {
		return 0, err
	}
	return res.RowsAffected()
}

// verificationStartFormat is fixed-width so text order is time order.
const verificationStartFormat = "2006-01-02T15:04:05.000000000Z"

// RecordVerificationStart persists the start time FR-20 counts one
// verification request at, so the rolling hourly bound survives a restart.
func (s *ScoringStore) RecordVerificationStart(ctx context.Context, at time.Time) error {
	if s == nil || s.db == nil {
		return errScoringStoreClosed
	}
	_, err := s.db.ExecContext(ctx, `INSERT INTO compute_integrity_verification_starts (started_at_utc) VALUES (?)`,
		at.UTC().Format(verificationStartFormat))
	return err
}

// PruneVerificationStarts deletes start times before cutoff; the table only
// ever needs the last hour.
func (s *ScoringStore) PruneVerificationStarts(ctx context.Context, cutoff time.Time) error {
	if s == nil || s.db == nil {
		return errScoringStoreClosed
	}
	_, err := s.db.ExecContext(ctx, `DELETE FROM compute_integrity_verification_starts WHERE started_at_utc < ?`,
		cutoff.UTC().Format(verificationStartFormat))
	return err
}

// RecentVerificationRequests returns the recorded FR-20 verification start
// times since since, newest first and at most limit of them. It reads a
// dedicated table pruned to the last hour, so a restart never scans buyer
// traffic. An unreadable start time is an error.
func (s *ScoringStore) RecentVerificationRequests(ctx context.Context, since time.Time, limit int) ([]time.Time, error) {
	if s == nil || s.db == nil {
		return nil, errScoringStoreClosed
	}
	if limit <= 0 {
		return nil, nil
	}
	rows, err := s.db.QueryContext(ctx, `
SELECT started_at_utc FROM compute_integrity_verification_starts
 WHERE started_at_utc >= ? ORDER BY started_at_utc DESC LIMIT ?`,
		since.UTC().Format(verificationStartFormat), limit)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	var out []time.Time
	for rows.Next() {
		var ts string
		if err := rows.Scan(&ts); err != nil {
			return nil, err
		}
		t, err := time.Parse(time.RFC3339Nano, ts)
		if err != nil {
			// An unreadable start cannot be placed in the window; the caller
			// fails the hourly bound closed.
			return nil, fmt.Errorf("verification start time %w", err)
		}
		out = append(out, t)
	}
	return out, rows.Err()
}

// ProbeDue is the FR-20 next due time of one verification key. A zero Due
// in a SaveProbeSchedule batch deletes the key's row. UpdatedAt is set by
// LoadProbeSchedule only.
type ProbeDue struct {
	ProviderID string
	ModelID    string
	Due        time.Time
	UpdatedAt  time.Time
}

// LoadProbeSchedule returns every persisted due time. An unreadable row
// fails the load.
func (s *ScoringStore) LoadProbeSchedule(ctx context.Context) ([]ProbeDue, error) {
	if s == nil || s.db == nil {
		return nil, errScoringStoreClosed
	}
	rows, err := s.db.QueryContext(ctx, `SELECT provider_id, model_id, next_due_at_utc, updated_at_utc FROM compute_integrity_probe_schedule`)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	var out []ProbeDue
	for rows.Next() {
		var d ProbeDue
		var due, updated string
		if err := rows.Scan(&d.ProviderID, &d.ModelID, &due, &updated); err != nil {
			return nil, err
		}
		if d.Due, err = time.Parse(time.RFC3339Nano, due); err != nil {
			return nil, fmt.Errorf("compute-integrity due time %w", err)
		}
		if d.UpdatedAt, err = time.Parse(time.RFC3339Nano, updated); err != nil {
			return nil, fmt.Errorf("compute-integrity due update time %w", err)
		}
		out = append(out, d)
	}
	return out, rows.Err()
}

// SaveProbeSchedule writes a batch of due times in one transaction.
func (s *ScoringStore) SaveProbeSchedule(ctx context.Context, batch []ProbeDue, now time.Time) error {
	if s == nil || s.db == nil {
		return errScoringStoreClosed
	}
	tx, err := s.db.BeginTx(ctx, nil)
	if err != nil {
		return err
	}
	defer func() { _ = tx.Rollback() }()
	for _, d := range batch {
		if d.Due.IsZero() {
			_, err = tx.ExecContext(ctx, `DELETE FROM compute_integrity_probe_schedule WHERE provider_id = ? AND model_id = ?`, d.ProviderID, d.ModelID)
		} else {
			_, err = tx.ExecContext(ctx, `
INSERT INTO compute_integrity_probe_schedule (provider_id, model_id, next_due_at_utc, updated_at_utc)
VALUES (?, ?, ?, ?)
ON CONFLICT(provider_id, model_id) DO UPDATE SET
    next_due_at_utc = excluded.next_due_at_utc, updated_at_utc = excluded.updated_at_utc`,
				d.ProviderID, d.ModelID, d.Due.UTC().Format(verificationStartFormat), now.UTC().Format(verificationStartFormat))
		}
		if err != nil {
			return err
		}
	}
	return tx.Commit()
}

// PruneProbeSchedule deletes due times neither written nor due since cutoff.
// Both columns use the fixed-width verificationStartFormat, so text order
// is time order.
func (s *ScoringStore) PruneProbeSchedule(ctx context.Context, cutoff time.Time) error {
	if s == nil || s.db == nil {
		return errScoringStoreClosed
	}
	c := cutoff.UTC().Format(verificationStartFormat)
	_, err := s.db.ExecContext(ctx, `DELETE FROM compute_integrity_probe_schedule WHERE updated_at_utc < ? AND next_due_at_utc < ?`, c, c)
	return err
}

// LoadScorerExclusions returns every FR-24 scorer-excluded provider.
func (s *ScoringStore) LoadScorerExclusions(ctx context.Context) ([]string, error) {
	if s == nil || s.db == nil {
		return nil, errScoringStoreClosed
	}
	rows, err := s.db.QueryContext(ctx, `SELECT provider_id FROM compute_integrity_scorer_exclusions ORDER BY provider_id`)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	var out []string
	for rows.Next() {
		var id string
		if err := rows.Scan(&id); err != nil {
			return nil, err
		}
		out = append(out, id)
	}
	return out, rows.Err()
}

// ExcludeScorer persists an FR-24 scorer exclusion.
func (s *ScoringStore) ExcludeScorer(ctx context.Context, providerID string, now time.Time) error {
	if s == nil || s.db == nil {
		return errScoringStoreClosed
	}
	_, err := s.db.ExecContext(ctx, `
INSERT INTO compute_integrity_scorer_exclusions (provider_id, excluded_at_utc) VALUES (?, ?)
ON CONFLICT(provider_id) DO NOTHING`, providerID, now.UTC().Format(time.RFC3339Nano))
	return err
}

// ClearScorerExclusion removes an FR-24 scorer exclusion (operator action).
func (s *ScoringStore) ClearScorerExclusion(ctx context.Context, providerID string) error {
	if s == nil || s.db == nil {
		return errScoringStoreClosed
	}
	_, err := s.db.ExecContext(ctx, `DELETE FROM compute_integrity_scorer_exclusions WHERE provider_id = ?`, providerID)
	return err
}
