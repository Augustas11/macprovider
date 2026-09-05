package trustpool

import (
	"context"
	"database/sql"
	"errors"
	"fmt"
	"strings"
	"time"

	"github.com/augstar/macprovider-coordinator/internal/sqliteutil"
)

const (
	ReviewedArtifactEnvironmentCandidate  = "candidate"
	ReviewedArtifactEnvironmentProduction = "production"
)

var ErrReviewedArtifactLifecycle = errors.New("trustpool: reviewed-artifact lifecycle rejected")

// ReviewedArtifactLifecycle assigns production (or candidate) ownership of
// reviewed distribution artifacts without mutating the digest-bound review row.
type ReviewedArtifactLifecycle struct {
	OperationID      string    `json:"operation_id"`
	PoolID           string    `json:"pool_id"`
	Owner            string    `json:"owner"`
	EnvironmentClass string    `json:"environment_class"`
	NextReviewDueUTC time.Time `json:"next_review_due_utc"`
	Notes            string    `json:"notes,omitempty"`
	RecordRevision   uint64    `json:"record_revision,omitempty"`
	UpdatedAtUTC     time.Time `json:"updated_at_utc,omitempty"`
}

func (r ReviewedArtifactLifecycle) Overdue(now time.Time) bool {
	if r.NextReviewDueUTC.IsZero() {
		return true
	}
	return !now.UTC().Before(r.NextReviewDueUTC.UTC())
}

func normalizeReviewedArtifactLifecycle(rec ReviewedArtifactLifecycle) ReviewedArtifactLifecycle {
	rec.OperationID = strings.TrimSpace(rec.OperationID)
	rec.PoolID = strings.TrimSpace(rec.PoolID)
	rec.Owner = strings.TrimSpace(rec.Owner)
	rec.EnvironmentClass = strings.TrimSpace(rec.EnvironmentClass)
	rec.Notes = strings.TrimSpace(rec.Notes)
	if !rec.NextReviewDueUTC.IsZero() {
		rec.NextReviewDueUTC = rec.NextReviewDueUTC.UTC()
	}
	return rec
}

func validateReviewedArtifactLifecycle(rec ReviewedArtifactLifecycle, now time.Time) error {
	if rec.OperationID == "" || rec.PoolID == "" || rec.Owner == "" {
		return fmt.Errorf("%w: missing identity fields", ErrReviewedArtifactLifecycle)
	}
	switch rec.EnvironmentClass {
	case ReviewedArtifactEnvironmentCandidate, ReviewedArtifactEnvironmentProduction:
	default:
		return fmt.Errorf("%w: environment_class must be candidate or production", ErrReviewedArtifactLifecycle)
	}
	if rec.NextReviewDueUTC.IsZero() || !now.UTC().Before(rec.NextReviewDueUTC) {
		return fmt.Errorf("%w: next_review_due_utc must be in the future", ErrReviewedArtifactLifecycle)
	}
	if err := ValidatePromiseClaimsText(rec.PoolID, rec.Owner, rec.Notes); err != nil {
		return err
	}
	return nil
}

func (s *Store) UpsertReviewedArtifactLifecycle(ctx context.Context, rec ReviewedArtifactLifecycle) (ReviewedArtifactLifecycle, error) {
	if s == nil || s.db == nil {
		return ReviewedArtifactLifecycle{}, ErrStoreClosed
	}
	rec = normalizeReviewedArtifactLifecycle(rec)
	now := time.Now().UTC()
	if err := validateReviewedArtifactLifecycle(rec, now); err != nil {
		return ReviewedArtifactLifecycle{}, err
	}
	rec.UpdatedAtUTC = now
	err := sqliteutil.Transact(ctx, s.db, func(ctx context.Context, conn *sql.Conn) error {
		if existing, ok, err := reviewedArtifactLifecycleByOperationID(ctx, conn, rec.OperationID); err != nil {
			return err
		} else if ok {
			if reviewedArtifactLifecycleMatchesOperation(existing, rec) {
				rec = existing
				return nil
			}
			return ErrConflictingOperationID
		}
		if used, err := operationIDExists(ctx, conn, rec.OperationID); err != nil {
			return err
		} else if used {
			return ErrConflictingOperationID
		}
		events, err := eventsFromQueryer(ctx, conn)
		if err != nil {
			return err
		}
		approvals, err := creatorApprovalsFromQueryer(ctx, conn)
		if err != nil {
			return err
		}
		state, err := reconstructEventsWithApprovals(events, approvals, now)
		if err != nil {
			return err
		}
		if state.Pools[rec.PoolID] == nil {
			return fmt.Errorf("%w: pool_not_found", ErrReviewedArtifactLifecycle)
		}
		current, err := reviewedArtifactLifecycleFromQueryer(ctx, conn)
		if err != nil {
			return err
		}
		if existing, ok := current[rec.PoolID]; ok && sameReviewedArtifactLifecycleExceptRevision(existing, rec) {
			if existing.OperationID == rec.OperationID {
				rec = existing
				return nil
			}
			return ErrConflictingOperationID
		}
		rec.RecordRevision = current[rec.PoolID].RecordRevision + 1
		if _, err := conn.ExecContext(ctx, `
INSERT INTO trustpool_reviewed_artifact_lifecycle_history (
    operation_id, pool_id, owner, environment_class, next_review_due_utc, notes, record_revision, updated_at_utc
) VALUES (?, ?, ?, ?, ?, ?, ?, ?)`,
			rec.OperationID,
			rec.PoolID,
			rec.Owner,
			rec.EnvironmentClass,
			rec.NextReviewDueUTC.Format(time.RFC3339Nano),
			rec.Notes,
			rec.RecordRevision,
			rec.UpdatedAtUTC.Format(time.RFC3339Nano),
		); err != nil {
			return err
		}
		_, err = conn.ExecContext(ctx, `
INSERT INTO trustpool_reviewed_artifact_lifecycle (
    pool_id, operation_id, owner, environment_class, next_review_due_utc, notes, record_revision, updated_at_utc
) VALUES (?, ?, ?, ?, ?, ?, ?, ?)
ON CONFLICT(pool_id) DO UPDATE SET
    operation_id=excluded.operation_id,
    owner=excluded.owner,
    environment_class=excluded.environment_class,
    next_review_due_utc=excluded.next_review_due_utc,
    notes=excluded.notes,
    record_revision=excluded.record_revision,
    updated_at_utc=excluded.updated_at_utc
`,
			rec.PoolID,
			rec.OperationID,
			rec.Owner,
			rec.EnvironmentClass,
			rec.NextReviewDueUTC.Format(time.RFC3339Nano),
			rec.Notes,
			rec.RecordRevision,
			rec.UpdatedAtUTC.Format(time.RFC3339Nano),
		)
		return err
	})
	if err != nil {
		return ReviewedArtifactLifecycle{}, err
	}
	return rec, nil
}

func (s *Store) ReviewedArtifactLifecycle(ctx context.Context, poolID string) (ReviewedArtifactLifecycle, bool, error) {
	if s == nil || s.db == nil {
		return ReviewedArtifactLifecycle{}, false, ErrStoreClosed
	}
	var rec ReviewedArtifactLifecycle
	var found bool
	err := sqliteutil.Transact(ctx, s.db, func(ctx context.Context, conn *sql.Conn) error {
		current, err := reviewedArtifactLifecycleFromQueryer(ctx, conn)
		if err != nil {
			return err
		}
		rec, found = current[strings.TrimSpace(poolID)]
		return nil
	})
	return rec, found, err
}

func reviewedArtifactLifecycleFromQueryer(ctx context.Context, q eventQueryer) (map[string]ReviewedArtifactLifecycle, error) {
	rows, err := q.QueryContext(ctx, `
SELECT operation_id, pool_id, owner, environment_class, next_review_due_utc, notes, record_revision, updated_at_utc
FROM trustpool_reviewed_artifact_lifecycle`)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	out := map[string]ReviewedArtifactLifecycle{}
	for rows.Next() {
		rec, err := scanReviewedArtifactLifecycle(rows)
		if err != nil {
			return nil, err
		}
		out[rec.PoolID] = rec
	}
	return out, rows.Err()
}

func reviewedArtifactLifecycleByOperationID(ctx context.Context, q eventQueryer, operationID string) (ReviewedArtifactLifecycle, bool, error) {
	rows, err := q.QueryContext(ctx, `
SELECT operation_id, pool_id, owner, environment_class, next_review_due_utc, notes, record_revision, updated_at_utc
FROM trustpool_reviewed_artifact_lifecycle_history WHERE operation_id = ? LIMIT 1`, operationID)
	if err != nil {
		return ReviewedArtifactLifecycle{}, false, err
	}
	defer rows.Close()
	if !rows.Next() {
		return ReviewedArtifactLifecycle{}, false, rows.Err()
	}
	rec, err := scanReviewedArtifactLifecycle(rows)
	return rec, err == nil, err
}

func scanReviewedArtifactLifecycle(row onCallScanner) (ReviewedArtifactLifecycle, error) {
	var rec ReviewedArtifactLifecycle
	var due, updated string
	if err := row.Scan(
		&rec.OperationID,
		&rec.PoolID,
		&rec.Owner,
		&rec.EnvironmentClass,
		&due,
		&rec.Notes,
		&rec.RecordRevision,
		&updated,
	); err != nil {
		return ReviewedArtifactLifecycle{}, err
	}
	var err error
	rec.NextReviewDueUTC, err = time.Parse(time.RFC3339Nano, due)
	if err != nil {
		return ReviewedArtifactLifecycle{}, err
	}
	rec.UpdatedAtUTC, err = time.Parse(time.RFC3339Nano, updated)
	if err != nil {
		return ReviewedArtifactLifecycle{}, err
	}
	return rec, nil
}

func reviewedArtifactLifecycleMatchesOperation(existing, incoming ReviewedArtifactLifecycle) bool {
	incoming.RecordRevision = existing.RecordRevision
	incoming.UpdatedAtUTC = existing.UpdatedAtUTC
	return sameReviewedArtifactLifecycleExceptRevision(existing, incoming) && existing.OperationID == incoming.OperationID
}

func sameReviewedArtifactLifecycleExceptRevision(a, b ReviewedArtifactLifecycle) bool {
	return a.PoolID == b.PoolID &&
		a.Owner == b.Owner &&
		a.EnvironmentClass == b.EnvironmentClass &&
		a.NextReviewDueUTC.Equal(b.NextReviewDueUTC) &&
		a.Notes == b.Notes
}

// RequireReviewedArtifactLifecycleForPromotion fail-closes operator HTTP/CLI
// production promote when the reconstructed pool is non-candidate and it has no
// current production reviewed-artifact lifecycle owner. Candidate pools skip
// this check so the isolated-candidate journey stays valid. Missing pools and
// pools without a root issuer are left to PromotePool preconditions. Mirrors
// RequireOnCallReadinessForPromotion: an unmapped wrapper gate that is not
// inside the evidence-mapped PromotePool transaction.
func (s *Store) RequireReviewedArtifactLifecycleForPromotion(ctx context.Context, poolID string) error {
	poolID = strings.TrimSpace(poolID)
	if poolID == "" {
		return nil
	}
	state, err := s.Reconstruct(ctx)
	if err != nil {
		return err
	}
	if state == nil {
		return nil
	}
	p := state.Pools[poolID]
	if p == nil || p.RootIssuer == nil {
		return nil
	}
	environment := strings.TrimSpace(p.RootIssuer.LaunchEnvironment)
	if environment == "" || environment == promotionLaunchEnvironmentCandidate {
		return nil
	}
	rec, ok, err := s.ReviewedArtifactLifecycle(ctx, poolID)
	if err != nil {
		return err
	}
	if !ok {
		return fmt.Errorf("%w: production promotion requires a reviewed-artifact lifecycle owner for %s", ErrReviewedArtifactLifecycle, poolID)
	}
	if rec.EnvironmentClass != ReviewedArtifactEnvironmentProduction {
		return fmt.Errorf("%w: production promotion requires a production reviewed-artifact lifecycle owner for %s", ErrReviewedArtifactLifecycle, poolID)
	}
	if rec.Overdue(time.Now().UTC()) {
		return fmt.Errorf("%w: reviewed-artifact lifecycle review overdue for %s", ErrReviewedArtifactLifecycle, poolID)
	}
	return nil
}
