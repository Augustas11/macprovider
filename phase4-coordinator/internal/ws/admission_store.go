package ws

import (
	"context"
	"database/sql"
	"encoding/json"
	"fmt"
	"time"
)

const admissionStateKey = "provisional_admission"

type AdmissionStateStore interface {
	LoadAdmissionState(context.Context) (AdmissionState, error)
	SaveAdmissionState(context.Context, AdmissionState) error
}

type AdmissionState struct {
	Admissions     []time.Time                   `json:"admissions"`
	Records        map[string]*ProvisionalRecord `json:"records"`
	Rejected       map[string]string             `json:"rejected"`
	RequestWindows map[string][]time.Time        `json:"request_windows"`
}

type SQLiteAdmissionStore struct {
	db *sql.DB
}

func NewSQLiteAdmissionStore(db *sql.DB) (*SQLiteAdmissionStore, error) {
	if db == nil {
		return nil, fmt.Errorf("db is required")
	}
	s := &SQLiteAdmissionStore{db: db}
	if _, err := db.ExecContext(context.Background(), `
CREATE TABLE IF NOT EXISTS admission_state (
	key TEXT PRIMARY KEY,
	value TEXT NOT NULL,
	updated_at_utc TEXT NOT NULL
)`); err != nil {
		return nil, err
	}
	return s, nil
}

func (s *SQLiteAdmissionStore) LoadAdmissionState(ctx context.Context) (AdmissionState, error) {
	var raw string
	err := s.db.QueryRowContext(ctx, `SELECT value FROM admission_state WHERE key = ?`, admissionStateKey).Scan(&raw)
	if err == sql.ErrNoRows {
		return AdmissionState{}, nil
	}
	if err != nil {
		return AdmissionState{}, err
	}
	var state AdmissionState
	if err := json.Unmarshal([]byte(raw), &state); err != nil {
		return AdmissionState{}, err
	}
	return state, nil
}

func (s *SQLiteAdmissionStore) SaveAdmissionState(ctx context.Context, state AdmissionState) error {
	raw, err := json.Marshal(state)
	if err != nil {
		return err
	}
	_, err = s.db.ExecContext(ctx, `
INSERT INTO admission_state(key, value, updated_at_utc)
VALUES(?, ?, ?)
ON CONFLICT(key) DO UPDATE SET value = excluded.value, updated_at_utc = excluded.updated_at_utc`,
		admissionStateKey,
		string(raw),
		time.Now().UTC().Format(time.RFC3339Nano),
	)
	return err
}
