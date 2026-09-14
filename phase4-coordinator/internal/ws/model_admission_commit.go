package ws

import (
	"context"
	"database/sql"
	"errors"
	"time"

	"github.com/augstar/macprovider-coordinator/internal/sqliteutil"
)

var errModelAdmissionAuthorityUnavailable = errors.New("model admission authority unavailable")

// ModelAdmissionCommitGuard is coordinator-owned and never serialized. Its
// release remains owned by the store until the transaction has completed.
type ModelAdmissionCommitGuard func() (release func(), err error)

type guardedModelAdmissionStore interface {
	AppendGuardedModelAdmissionDecision(context.Context, ModelAdmissionEvent, ModelAdmissionCommitGuard) (ModelAdmissionEvent, error)
	ObserveModelAdmission(context.Context, string, string, func(ModelAdmissionEvent) (func(), error)) (ModelAdmissionEvent, error)
}

func artifactPositive(e ModelAdmissionEvent) bool {
	return e.ArtifactAdmissionEvidence != nil && (e.State == "catalog_priced" || e.State == "settlement_capable")
}

func artifactDecisionExpired(e ModelAdmissionEvent, now time.Time) bool {
	return artifactPositive(e) && (now.UnixMilli() >= e.ArtifactAdmissionEvidence.AuthorityExpiresAtUnixMS || now.UnixMilli() >= e.ArtifactAdmissionEvidence.ProbeExpiresAtUnixMS)
}

func (s *memoryModelAdmissionStore) AppendGuardedModelAdmissionDecision(ctx context.Context, e ModelAdmissionEvent, guard ModelAdmissionCommitGuard) (ModelAdmissionEvent, error) {
	if err := ctx.Err(); err != nil {
		return ModelAdmissionEvent{}, err
	}
	stored, _, err := s.appendCoordinatorModelAdmissionEvent(cloneModelAdmissionEvent(e), guard)
	return cloneModelAdmissionEvent(stored), err
}

func (s *SQLiteModelAdmissionStore) AppendGuardedModelAdmissionDecision(ctx context.Context, e ModelAdmissionEvent, guard ModelAdmissionCommitGuard) (ModelAdmissionEvent, error) {
	stored, _, err := s.appendCoordinatorModelAdmissionEvent(ctx, e, guard)
	return stored, err
}

func (s *memoryModelAdmissionStore) ObserveModelAdmission(ctx context.Context, providerID, candidateID string, observe func(ModelAdmissionEvent) (func(), error)) (ModelAdmissionEvent, error) {
	if err := ctx.Err(); err != nil {
		return ModelAdmissionEvent{}, err
	}
	s.mu.Lock()
	defer s.mu.Unlock()
	e, ok := s.latest[providerID+"|"+candidateID]
	if !ok {
		return ModelAdmissionEvent{}, errModelAdmissionAuthorityUnavailable
	}
	release, err := observe(cloneModelAdmissionEvent(e))
	if release != nil {
		defer release()
	}
	if err != nil {
		return ModelAdmissionEvent{}, err
	}
	return cloneModelAdmissionEvent(e), nil
}

func (s *SQLiteModelAdmissionStore) ObserveModelAdmission(ctx context.Context, providerID, candidateID string, observe func(ModelAdmissionEvent) (func(), error)) (ModelAdmissionEvent, error) {
	var e ModelAdmissionEvent
	var release func()
	defer func() {
		if release != nil {
			release()
		}
	}()
	err := sqliteutil.Transact(ctx, s.db, func(txCtx context.Context, conn *sql.Conn) error {
		var found bool
		var err error
		e, found, err = scanModelAdmissionEvent(txCtx, conn, modelAdmissionEventSelect(` FROM model_admission_events WHERE provider_id = ? AND candidate_id = ? ORDER BY id DESC LIMIT 1`), providerID, candidateID)
		if err != nil {
			return err
		}
		if !found {
			return errModelAdmissionAuthorityUnavailable
		}
		release, err = observe(e)
		return err
	})
	return e, err
}

// Private seams share one controllable clock with server fixtures and pause at
// actual insertion boundaries. Nil keeps the production wall clock and path.
type modelAdmissionCommitTestHooks struct {
	now          func() time.Time
	beforeInsert func()
	afterInsert  func() error
}

func (h *modelAdmissionCommitTestHooks) clock() time.Time {
	if h != nil && h.now != nil {
		return h.now()
	}
	return time.Now()
}
func (h *modelAdmissionCommitTestHooks) beforeInsertion() {
	if h != nil && h.beforeInsert != nil {
		h.beforeInsert()
	}
}
