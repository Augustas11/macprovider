package billing

import (
	"context"
	"database/sql"
	"path/filepath"
	"testing"
	"time"

	"github.com/augstar/macprovider-coordinator/internal/requestlog"
	"github.com/augstar/macprovider-coordinator/internal/sqliteutil"
	_ "modernc.org/sqlite"
)

func TestSetReadDBRoutesAuditOutboxStatsAroundHeldWriterConnection(t *testing.T) {
	path := filepath.Join(t.TempDir(), "billing.db")
	requestLogStore, err := requestlog.OpenStore(path)
	if err != nil {
		t.Fatal(err)
	}
	defer requestLogStore.Close()
	writer := requestLogStore.DB()
	writer.SetMaxOpenConns(1)
	writer.SetMaxIdleConns(1)
	store, err := NewStore(writer)
	if err != nil {
		t.Fatal(err)
	}

	reader, err := sql.Open("sqlite", sqliteutil.ReadOnlyDSN(path))
	if err != nil {
		t.Fatal(err)
	}
	defer reader.Close()
	reader.SetMaxOpenConns(4)
	store.SetReadDB(reader)

	conn, err := writer.Conn(context.Background())
	if err != nil {
		t.Fatal(err)
	}
	defer conn.Close()
	if _, err := conn.ExecContext(context.Background(), `BEGIN IMMEDIATE`); err != nil {
		t.Fatal(err)
	}
	defer conn.ExecContext(context.Background(), `ROLLBACK`)

	ctx, cancel := context.WithTimeout(context.Background(), 250*time.Millisecond)
	defer cancel()
	stats, err := store.SettlementReceiptAuditOutboxStats(ctx)
	if err != nil {
		t.Fatalf("read through independent pool while writer connection held: %v", err)
	}
	if stats.PendingRows != 0 || stats.PoisonedRows != 0 || stats.RetainedPoisonedRows != 0 {
		t.Fatalf("unexpected empty outbox stats: %+v", stats)
	}
}
