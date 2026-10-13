package computeintegrity

// SPEC-036 FR-23/FR-24 persistence: verification key states and scorer
// exclusions survive coordinator restarts. No prompt, output or token data is
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
`)
	if err != nil {
		return nil, err
	}
	return &ScoringStore{db: db}, nil
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
