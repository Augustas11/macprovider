package referralapi

import (
	"context"
	"database/sql"
	"errors"
	"time"

	"github.com/augstar/macprovider-coordinator/internal/sqliteutil"
	_ "modernc.org/sqlite"
)

type SQLiteServingEvidence struct {
	Path string
}

func (s SQLiteServingEvidence) FirstVerifiedServing(ctx context.Context, providerID string) (time.Time, bool, error) {
	if s.Path == "" {
		return time.Time{}, false, nil
	}
	db, err := sql.Open("sqlite", sqliteutil.ReadOnlyDSN(s.Path))
	if err != nil {
		return time.Time{}, false, err
	}
	defer db.Close()
	db.SetMaxOpenConns(1)
	var unixMS sql.NullInt64
	err = db.QueryRowContext(ctx, `
SELECT MIN(received_at_unix_ms)
  FROM settlement_receipt_verdicts
 WHERE provider_id = ?
   AND closed = 1
   AND settlement_outcome = 'verified'
   AND receipt_result = 'valid'`, providerID).Scan(&unixMS)
	if err != nil {
		if errors.Is(err, sql.ErrNoRows) {
			return time.Time{}, false, nil
		}
		return time.Time{}, false, err
	}
	if !unixMS.Valid || unixMS.Int64 <= 0 {
		return time.Time{}, false, nil
	}
	return time.UnixMilli(unixMS.Int64).UTC(), true, nil
}
