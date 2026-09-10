package ws

import (
	"context"
	"database/sql"
	"fmt"
	"time"

	"github.com/augstar/macprovider-coordinator/internal/sqliteutil"
)

// modelAdmissionPendingTTL is the SPEC-047-R001 v0.1.5 pending-decision expiry.
const modelAdmissionPendingTTL = 24 * time.Hour

var (
	errModelAdmissionNoPending       = fmt.Errorf("model admission pending decision unknown or invalidated")
	errModelAdmissionPendingExpired  = fmt.Errorf("model admission pending decision expired")
	errModelAdmissionPendingConsumed = fmt.Errorf("model admission pending decision consumed")
)

// Exported for callers and tests outside the package (closed SPEC-047 error
// codes map onto these sentinels).
var (
	ErrModelAdmissionStaleHead       = errModelAdmissionStaleHead
	ErrModelAdmissionReplayConflict  = errModelAdmissionReplayConflict
	ErrModelAdmissionNoPending       = errModelAdmissionNoPending
	ErrModelAdmissionPendingExpired  = errModelAdmissionPendingExpired
	ErrModelAdmissionPendingConsumed = errModelAdmissionPendingConsumed
)

// ---- memory store

func (s *memoryModelAdmissionStore) ensurePending() {
	if s.pending == nil {
		s.pending = map[string]PendingModelAdmissionDecision{}
		s.pendingByReq = map[string]string{}
	}
}

func (s *memoryModelAdmissionStore) invalidatePendingLocked(providerID, candidateID string) {
	s.ensurePending()
	for id, p := range s.pending {
		if p.ProviderID == providerID && p.CandidateID == candidateID && !p.Invalidated && p.ConsumedAt.IsZero() {
			p.Invalidated = true
			s.pending[id] = p
		}
	}
}

// CreatePendingModelAdmissionDecision records a pending decision; a request
// with the same (provider, candidate, request id) and digest replays the
// existing record (replayed=true); the same key with another digest is a
// conflict.
func (s *memoryModelAdmissionStore) CreatePendingModelAdmissionDecision(_ context.Context, p PendingModelAdmissionDecision) (PendingModelAdmissionDecision, bool, error) {
	s.mu.Lock()
	defer s.mu.Unlock()
	s.ensurePending()
	key := p.ProviderID + "|" + p.CandidateID + "|" + p.RequestID
	if id, ok := s.pendingByReq[key]; ok {
		existing := s.pending[id]
		if existing.RequestDigest != p.RequestDigest {
			return PendingModelAdmissionDecision{}, false, errModelAdmissionReplayConflict
		}
		return existing, true, nil
	}
	if p.CreatedAt.IsZero() {
		p.CreatedAt = time.Now().UTC()
	}
	if p.ExpiresAt.IsZero() {
		p.ExpiresAt = p.CreatedAt.Add(modelAdmissionPendingTTL)
	}
	s.pending[p.ID] = p
	s.pendingByReq[key] = p.ID
	return p, false, nil
}

func (s *memoryModelAdmissionStore) PendingModelAdmissionDecisionByRequest(_ context.Context, providerID, candidateID, requestID string) (PendingModelAdmissionDecision, bool, error) {
	s.mu.Lock()
	defer s.mu.Unlock()
	s.ensurePending()
	id, ok := s.pendingByReq[providerID+"|"+candidateID+"|"+requestID]
	if !ok {
		return PendingModelAdmissionDecision{}, false, nil
	}
	p, ok := s.pending[id]
	return p, ok, nil
}

func (s *memoryModelAdmissionStore) PendingModelAdmissionDecision(_ context.Context, id string) (PendingModelAdmissionDecision, bool, error) {
	s.mu.Lock()
	defer s.mu.Unlock()
	s.ensurePending()
	p, ok := s.pending[id]
	return p, ok, nil
}

// consumePendingLocked marks the approved record consumed by the approval
// that appended event (caller holds s.mu; the append already invalidated
// every open record, this one is re-marked consumed instead).
func (s *memoryModelAdmissionStore) consumePendingLocked(approval PendingModelAdmissionApproval, event ModelAdmissionEvent) {
	s.ensurePending()
	p, ok := s.pending[approval.PendingID]
	if !ok {
		return
	}
	p.Invalidated = false
	p.ConsumedAt = event.CreatedAt
	p.ConsumedBy = approval.Actor
	p.ConsumedEventID = event.CoordinatorEventID
	p.ApprovalRequestKey = approval.RequestKey
	p.ApprovalDigest = approval.Digest
	s.pending[approval.PendingID] = p
}

func (s *memoryModelAdmissionStore) InvalidatePendingModelAdmissionDecisions(_ context.Context, providerID, candidateID string) error {
	s.mu.Lock()
	defer s.mu.Unlock()
	s.invalidatePendingLocked(providerID, candidateID)
	return nil
}

// ---- SQLite store

func ensureSQLitePendingModelAdmissionTable(db *sql.DB) error {
	if _, err := db.ExecContext(context.Background(), `
CREATE TABLE IF NOT EXISTS model_admission_pending_decisions (
    id TEXT PRIMARY KEY,
    provider_id TEXT NOT NULL,
    candidate_id TEXT NOT NULL,
    next_state TEXT NOT NULL,
    reason_code TEXT NOT NULL,
    request_digest TEXT NOT NULL,
    request_id TEXT NOT NULL,
    evaluated_head TEXT NOT NULL,
    requested_by TEXT NOT NULL,
    created_at_utc TEXT NOT NULL,
    expires_at_utc TEXT NOT NULL,
    consumed_at_utc TEXT NOT NULL DEFAULT '',
    consumed_by TEXT NOT NULL DEFAULT '',
    consumed_event_id TEXT NOT NULL DEFAULT '',
    invalidated INTEGER NOT NULL DEFAULT 0,
    approval_request_key TEXT NOT NULL DEFAULT '',
    approval_digest TEXT NOT NULL DEFAULT '',
    admission_state TEXT NOT NULL DEFAULT '',
    served_model_ref TEXT NOT NULL DEFAULT '',
    catalog_model_key TEXT NOT NULL DEFAULT '',
    UNIQUE(provider_id, candidate_id, request_id)
)`); err != nil {
		return err
	}
	rows, err := db.QueryContext(context.Background(), `PRAGMA table_info(model_admission_pending_decisions)`)
	if err != nil {
		return err
	}
	existing := map[string]struct{}{}
	for rows.Next() {
		var cid int
		var name, ctype string
		var notnull, pk int
		var dflt sql.NullString
		if err := rows.Scan(&cid, &name, &ctype, &notnull, &dflt, &pk); err != nil {
			_ = rows.Close()
			return err
		}
		existing[name] = struct{}{}
	}
	if err := rows.Close(); err != nil {
		return err
	}
	for _, column := range []string{"admission_state", "served_model_ref", "catalog_model_key"} {
		if _, ok := existing[column]; ok {
			continue
		}
		if _, err := db.ExecContext(context.Background(), `ALTER TABLE model_admission_pending_decisions ADD COLUMN `+column+` TEXT NOT NULL DEFAULT ''`); err != nil {
			return err
		}
	}
	return nil
}

func invalidateSQLitePendingModelAdmissionDecisions(ctx context.Context, conn *sql.Conn, providerID, candidateID string) error {
	_, err := conn.ExecContext(ctx, `UPDATE model_admission_pending_decisions SET invalidated = 1 WHERE provider_id = ? AND candidate_id = ? AND consumed_at_utc = '' AND invalidated = 0`, providerID, candidateID)
	return err
}

func consumeSQLitePendingModelAdmissionDecision(ctx context.Context, conn *sql.Conn, approval PendingModelAdmissionApproval, event ModelAdmissionEvent) error {
	_, err := conn.ExecContext(ctx, `UPDATE model_admission_pending_decisions SET invalidated = 0, consumed_at_utc = ?, consumed_by = ?, consumed_event_id = ?, approval_request_key = ?, approval_digest = ? WHERE id = ?`,
		event.CreatedAt.UTC().Format(time.RFC3339Nano), approval.Actor, event.CoordinatorEventID, approval.RequestKey, approval.Digest, approval.PendingID)
	return err
}

const sqlitePendingSelect = `SELECT id, provider_id, candidate_id, next_state, reason_code, request_digest, request_id, evaluated_head, requested_by,
       created_at_utc, expires_at_utc, consumed_at_utc, consumed_by, consumed_event_id, invalidated, approval_request_key, approval_digest,
       admission_state, served_model_ref, catalog_model_key
  FROM model_admission_pending_decisions`

type sqlitePendingScanner interface{ Scan(dest ...any) error }

func scanSQLitePending(row sqlitePendingScanner) (PendingModelAdmissionDecision, error) {
	var p PendingModelAdmissionDecision
	var created, expires, consumed string
	var invalidated int
	if err := row.Scan(&p.ID, &p.ProviderID, &p.CandidateID, &p.NextState, &p.ReasonCode, &p.RequestDigest, &p.RequestID, &p.EvaluatedHead, &p.RequestedBy,
		&created, &expires, &consumed, &p.ConsumedBy, &p.ConsumedEventID, &invalidated, &p.ApprovalRequestKey, &p.ApprovalDigest,
		&p.AdmissionState, &p.ServedModelRef, &p.CatalogModelKey); err != nil {
		return PendingModelAdmissionDecision{}, err
	}
	var err error
	if p.CreatedAt, err = time.Parse(time.RFC3339Nano, created); err != nil {
		return PendingModelAdmissionDecision{}, fmt.Errorf("model admission pending decision %s: created_at_utc: %w", p.ID, err)
	}
	if p.ExpiresAt, err = time.Parse(time.RFC3339Nano, expires); err != nil {
		return PendingModelAdmissionDecision{}, fmt.Errorf("model admission pending decision %s: expires_at_utc: %w", p.ID, err)
	}
	if consumed != "" {
		if p.ConsumedAt, err = time.Parse(time.RFC3339Nano, consumed); err != nil {
			return PendingModelAdmissionDecision{}, fmt.Errorf("model admission pending decision %s: consumed_at_utc: %w", p.ID, err)
		}
	}
	p.Invalidated = invalidated == 1
	return p, nil
}

func (s *SQLiteModelAdmissionStore) CreatePendingModelAdmissionDecision(ctx context.Context, p PendingModelAdmissionDecision) (PendingModelAdmissionDecision, bool, error) {
	if p.CreatedAt.IsZero() {
		p.CreatedAt = time.Now().UTC()
	}
	if p.ExpiresAt.IsZero() {
		p.ExpiresAt = p.CreatedAt.Add(modelAdmissionPendingTTL)
	}
	var stored PendingModelAdmissionDecision
	var replayed bool
	err := sqliteutil.Transact(ctx, s.db, func(txCtx context.Context, conn *sql.Conn) error {
		row := conn.QueryRowContext(txCtx, sqlitePendingSelect+` WHERE provider_id = ? AND candidate_id = ? AND request_id = ?`, p.ProviderID, p.CandidateID, p.RequestID)
		existing, err := scanSQLitePending(row)
		if err == nil {
			if existing.RequestDigest != p.RequestDigest {
				return errModelAdmissionReplayConflict
			}
			stored, replayed = existing, true
			return nil
		}
		if err != sql.ErrNoRows {
			return err
		}
		if _, err := conn.ExecContext(txCtx, `INSERT INTO model_admission_pending_decisions(id, provider_id, candidate_id, next_state, reason_code, request_digest, request_id, evaluated_head, requested_by, created_at_utc, expires_at_utc, admission_state, served_model_ref, catalog_model_key)
VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)`, p.ID, p.ProviderID, p.CandidateID, p.NextState, p.ReasonCode, p.RequestDigest, p.RequestID, p.EvaluatedHead, p.RequestedBy,
			p.CreatedAt.UTC().Format(time.RFC3339Nano), p.ExpiresAt.UTC().Format(time.RFC3339Nano), p.AdmissionState, p.ServedModelRef, p.CatalogModelKey); err != nil {
			return err
		}
		stored = p
		return nil
	})
	return stored, replayed, err
}

func (s *SQLiteModelAdmissionStore) PendingModelAdmissionDecisionByRequest(ctx context.Context, providerID, candidateID, requestID string) (PendingModelAdmissionDecision, bool, error) {
	row := s.db.QueryRowContext(ctx, sqlitePendingSelect+` WHERE provider_id = ? AND candidate_id = ? AND request_id = ?`, providerID, candidateID, requestID)
	p, err := scanSQLitePending(row)
	if err == sql.ErrNoRows {
		return PendingModelAdmissionDecision{}, false, nil
	}
	if err != nil {
		return PendingModelAdmissionDecision{}, false, err
	}
	return p, true, nil
}

func (s *SQLiteModelAdmissionStore) PendingModelAdmissionDecision(ctx context.Context, id string) (PendingModelAdmissionDecision, bool, error) {
	row := s.db.QueryRowContext(ctx, sqlitePendingSelect+` WHERE id = ?`, id)
	p, err := scanSQLitePending(row)
	if err == sql.ErrNoRows {
		return PendingModelAdmissionDecision{}, false, nil
	}
	if err != nil {
		return PendingModelAdmissionDecision{}, false, err
	}
	return p, true, nil
}

func (s *SQLiteModelAdmissionStore) InvalidatePendingModelAdmissionDecisions(ctx context.Context, providerID, candidateID string) error {
	_, err := s.db.ExecContext(ctx, `UPDATE model_admission_pending_decisions SET invalidated = 1 WHERE provider_id = ? AND candidate_id = ? AND consumed_at_utc = '' AND invalidated = 0`, providerID, candidateID)
	return err
}
