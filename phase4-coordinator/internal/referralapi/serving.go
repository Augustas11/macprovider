package referralapi

import (
	"context"
	"database/sql"
	"errors"
	"strings"
	"time"

	"github.com/augstar/macprovider-coordinator/internal/sqliteutil"
	_ "modernc.org/sqlite"
)

// SQLiteServingEvidence derives advocacy eligibility from a closed, verified
// settlement receipt. A connection is opened read-only so this endpoint cannot
// mutate the money-path database.
type SQLiteServingEvidence struct {
	Path string
}

func (s SQLiteServingEvidence) FirstVerifiedServing(ctx context.Context, providerID string) (time.Time, bool, error) {
	if strings.TrimSpace(s.Path) == "" {
		return time.Time{}, false, nil
	}
	db, err := sql.Open("sqlite", sqliteutil.ReadOnlyDSN(s.Path))
	if err != nil {
		return time.Time{}, false, err
	}
	defer db.Close()
	db.SetMaxOpenConns(1)
	var receivedAt sql.NullInt64
	err = db.QueryRowContext(ctx, `
SELECT MIN(received_at_unix_ms)
  FROM settlement_receipt_verdicts
 WHERE provider_id = ?
   AND closed = 1
   AND settlement_outcome = 'verified'
   AND receipt_result = 'valid'`, providerID).Scan(&receivedAt)
	if err != nil {
		if errors.Is(err, sql.ErrNoRows) {
			return time.Time{}, false, nil
		}
		return time.Time{}, false, err
	}
	if !receivedAt.Valid || receivedAt.Int64 <= 0 {
		return time.Time{}, false, nil
	}
	return time.UnixMilli(receivedAt.Int64).UTC(), true, nil
}
