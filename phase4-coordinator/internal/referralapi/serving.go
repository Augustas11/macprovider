package referralapi

import (
	"context"
	"database/sql"
	"fmt"
	"strings"
	"time"

	"github.com/augstar/macprovider-coordinator/internal/auth"
	"github.com/augstar/macprovider-coordinator/internal/sqliteutil"
	_ "modernc.org/sqlite"
)

const defaultServingReconcileBatch = 128

// VerifiedServing is coordinator/buyer evidence that one provider completed a
// closed, verified settlement. EvidenceID is the durable settlement verdict
// identity used to make qualification replay-safe.
type VerifiedServing struct {
	ProviderID string
	EvidenceID string
	ServedAt   time.Time
}

// ServingEvidenceSource is deliberately read-only. Referral state is written
// only through ServingQualificationStore after buyer evidence has closed.
type ServingEvidenceSource interface {
	ListVerifiedServing(context.Context, string, int) ([]VerifiedServing, error)
}

type ServingQualificationStore interface {
	QualifyProviderReferral(context.Context, auth.ReferralPolicy, string, string, time.Time, time.Time) (auth.ProviderReferral, bool, error)
}

// SQLiteServingEvidence reads the money-path verdict database without any
// write capability. Pagination by provider ID ensures a complete bounded scan
// even when already-qualified providers remain in the source database.
type SQLiteServingEvidence struct {
	Path string
}

func (s SQLiteServingEvidence) ListVerifiedServing(ctx context.Context, afterProviderID string, limit int) ([]VerifiedServing, error) {
	if strings.TrimSpace(s.Path) == "" {
		return nil, nil
	}
	if limit <= 0 || limit > 1024 {
		limit = defaultServingReconcileBatch
	}
	db, err := sql.Open("sqlite", sqliteutil.ReadOnlyDSN(s.Path))
	if err != nil {
		return nil, err
	}
	defer db.Close()
	db.SetMaxOpenConns(1)

	rows, err := db.QueryContext(ctx, `
SELECT v.id, v.provider_id, v.received_at_unix_ms
  FROM settlement_receipt_verdicts v
 WHERE v.provider_id > ?
   AND v.provider_id <> ''
   AND v.closed = 1
   AND v.settlement_outcome = 'verified'
   AND v.receipt_result = 'valid'
   AND v.id = (
       SELECT first.id
         FROM settlement_receipt_verdicts first
        WHERE first.provider_id = v.provider_id
          AND first.closed = 1
          AND first.settlement_outcome = 'verified'
          AND first.receipt_result = 'valid'
        ORDER BY first.received_at_unix_ms, first.id
        LIMIT 1
   )
 ORDER BY v.provider_id
 LIMIT ?`, strings.TrimSpace(afterProviderID), limit)
	if err != nil {
		return nil, err
	}
	defer rows.Close()

	var out []VerifiedServing
	for rows.Next() {
		var id int64
		var item VerifiedServing
		var unixMillis int64
		if err := rows.Scan(&id, &item.ProviderID, &unixMillis); err != nil {
			return nil, err
		}
		if id <= 0 || unixMillis <= 0 {
			continue
		}
		item.EvidenceID = fmt.Sprintf("settlement-verdict:%d", id)
		item.ServedAt = time.UnixMilli(unixMillis).UTC()
		out = append(out, item)
	}
	if err := rows.Err(); err != nil {
		return nil, err
	}
	return out, nil
}

// ServingReconciler is the sole bridge from authoritative buyer evidence to
// referral invite qualification. It is safe to run at startup, on a ticker,
// after response loss, and concurrently: the auth store owns the qualification
// and issuer uniqueness transaction.
type ServingReconciler struct {
	Source    ServingEvidenceSource
	Store     ServingQualificationStore
	Policy    auth.ReferralPolicy
	BatchSize int
	Now       func() time.Time
}

func (r ServingReconciler) Reconcile(ctx context.Context) (int, error) {
	if r.Source == nil || r.Store == nil {
		return 0, nil
	}
	batchSize := r.BatchSize
	if batchSize <= 0 || batchSize > 1024 {
		batchSize = defaultServingReconcileBatch
	}
	now := time.Now().UTC()
	if r.Now != nil {
		now = r.Now().UTC()
	}
	after := ""
	qualified := 0
	for {
		items, err := r.Source.ListVerifiedServing(ctx, after, batchSize)
		if err != nil {
			return qualified, err
		}
		if len(items) == 0 {
			return qualified, nil
		}
		for _, item := range items {
			if strings.TrimSpace(item.ProviderID) == "" {
				continue
			}
			_, created, err := r.Store.QualifyProviderReferral(
				ctx, r.Policy, item.ProviderID, item.EvidenceID, item.ServedAt, now,
			)
			if err != nil {
				return qualified, err
			}
			if created {
				qualified++
			}
			after = item.ProviderID
		}
		if len(items) < batchSize {
			return qualified, nil
		}
	}
}
