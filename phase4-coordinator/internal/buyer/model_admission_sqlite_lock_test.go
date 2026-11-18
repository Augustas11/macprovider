package buyer

import (
	"context"
	"database/sql"
	"net/http"
	"path/filepath"
	"testing"
	"time"

	"github.com/augstar/macprovider-coordinator/internal/sqliteutil"
	providerws "github.com/augstar/macprovider-coordinator/internal/ws"
	_ "modernc.org/sqlite"
)

// TestCatalogSessionLegacyEligibilityUnderSQLiteLocks pins what a money-db
// reader does while other connections hold the locks a pricing reload can
// meet. An unbound catalog session (no candidate, no artifact, empty
// admission log) is the J2 provider shape. Its paid-routing check reads
// model_admission_events on the read-only connection before the eligibility
// cache. In WAL mode a reserved write (BEGIN IMMEDIATE, the billing
// snapshot) and BEGIN EXCLUSIVE both leave that read free to select the
// provider. A wal_checkpoint(TRUNCATE) that is still waiting on some other
// reader's mark must leave it free too: the checkpointer gives up the
// exclusive step instead of parking buyer reads.
func TestCatalogSessionLegacyEligibilityUnderSQLiteLocks(t *testing.T) {
	path := filepath.Join(t.TempDir(), "coordinator.db")
	writer, err := sql.Open("sqlite", sqliteutil.WithManualWALCheckpointPragmas(path))
	if err != nil {
		t.Fatal(err)
	}
	writer.SetMaxOpenConns(1)
	writer.SetMaxIdleConns(1)
	t.Cleanup(func() { _ = writer.Close() })
	if _, err := providerws.NewSQLiteModelAdmissionStore(writer); err != nil {
		t.Fatal(err)
	}

	reader, err := sql.Open("sqlite", sqliteutil.ReadOnlyDSN(path))
	if err != nil {
		t.Fatal(err)
	}
	reader.SetMaxOpenConns(1)
	reader.SetMaxIdleConns(1)
	t.Cleanup(func() { _ = reader.Close() })
	// Shorter than the 5s DSN default so a blocked read fails inside this
	// test, and shorter than the admission context so the sqlite busy result
	// is what selection classifies.
	if _, err := reader.Exec(`PRAGMA busy_timeout = 200`); err != nil {
		t.Fatal(err)
	}
	readStore, err := providerws.NewSQLiteModelAdmissionReadStore(reader)
	if err != nil {
		t.Fatal(err)
	}

	s, registry, _ := poolIsolationServer(t)
	s.modelAdmissionStore = readStore
	provider := poolProvider("catalog")
	registry.Register(&provider, nil)

	selectCatalog := func() (*routeError, time.Duration) {
		t.Helper()
		started := time.Now()
		_, routeErr := s.selectProviderExcluding(context.Background(), "rid", poolChatReq(""), http.Header{}, nil, "2026-09-15", &forwardState{})
		return routeErr, time.Since(started)
	}
	if routeErr, _ := selectCatalog(); routeErr != nil {
		t.Fatalf("empty admission log rejected the catalog session: %+v", routeErr)
	}

	holder, err := sql.Open("sqlite", sqliteutil.WithManualWALCheckpointPragmas(path))
	if err != nil {
		t.Fatal(err)
	}
	holder.SetMaxOpenConns(1)
	holder.SetMaxIdleConns(1)
	t.Cleanup(func() { _ = holder.Close() })
	conn, err := holder.Conn(context.Background())
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() {
		_, _ = conn.ExecContext(context.Background(), `ROLLBACK`)
		_ = conn.Close()
	})

	if _, err := conn.ExecContext(context.Background(), `BEGIN IMMEDIATE`); err != nil {
		t.Fatal(err)
	}
	if _, err := conn.ExecContext(context.Background(), `CREATE TABLE IF NOT EXISTS lock_probe (n INTEGER)`); err != nil {
		t.Fatal(err)
	}
	if routeErr, elapsed := selectCatalog(); routeErr != nil {
		t.Fatalf("BEGIN IMMEDIATE rejected the catalog session after %s: %+v", elapsed, routeErr)
	}
	if _, err := conn.ExecContext(context.Background(), `ROLLBACK`); err != nil {
		t.Fatal(err)
	}

	// WAL mode treats BEGIN EXCLUSIVE like BEGIN IMMEDIATE for other
	// connections: readers are not excluded. Selection must still succeed.
	beginCtx, beginCancel := context.WithTimeout(context.Background(), 2*time.Second)
	defer beginCancel()
	if _, err := conn.ExecContext(beginCtx, `BEGIN EXCLUSIVE`); err != nil {
		t.Fatal(err)
	}
	if routeErr, elapsed := selectCatalog(); routeErr != nil {
		t.Fatalf("BEGIN EXCLUSIVE rejected the catalog session after %s: %+v", elapsed, routeErr)
	}
	if _, err := conn.ExecContext(context.Background(), `ROLLBACK`); err != nil {
		t.Fatal(err)
	}

	// Hold a read mark so wal_checkpoint(TRUNCATE) cannot finish, then select
	// while that checkpoint is waiting. TRUNCATE is the money-checkpointer's
	// exclusive step; this is the lock a billing write does not take.
	readHold, err := sql.Open("sqlite", sqliteutil.WithPragmas(path))
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { _ = readHold.Close() })
	readConn, err := readHold.Conn(context.Background())
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() {
		_, _ = readConn.ExecContext(context.Background(), `ROLLBACK`)
		_ = readConn.Close()
	})
	if _, err := readConn.ExecContext(context.Background(), `BEGIN`); err != nil {
		t.Fatal(err)
	}
	var n int
	if err := readConn.QueryRowContext(context.Background(), `SELECT COUNT(*) FROM model_admission_events`).Scan(&n); err != nil {
		t.Fatal(err)
	}

	checkpointStarted := make(chan struct{})
	checkpointDone := make(chan error, 1)
	go func() {
		checkpointDB, err := sql.Open("sqlite", sqliteutil.WithManualWALCheckpointPragmas(path))
		if err != nil {
			checkpointDone <- err
			return
		}
		defer checkpointDB.Close()
		checkpointDB.SetMaxOpenConns(1)
		if _, err := checkpointDB.Exec(`PRAGMA busy_timeout = 3000`); err != nil {
			checkpointDone <- err
			return
		}
		close(checkpointStarted)
		_, err = checkpointDB.Exec(`PRAGMA wal_checkpoint(TRUNCATE)`)
		checkpointDone <- err
	}()
	select {
	case <-checkpointStarted:
	case err := <-checkpointDone:
		t.Fatalf("wal_checkpoint(TRUNCATE) returned before it could wait: %v", err)
	case <-time.After(2 * time.Second):
		t.Fatal("wal_checkpoint(TRUNCATE) did not start")
	}
	// The checkpoint is inside Exec. Give it time to block on the read mark
	// so the selection below overlaps that wait.
	time.Sleep(150 * time.Millisecond)
	select {
	case err := <-checkpointDone:
		t.Fatalf("wal_checkpoint(TRUNCATE) finished before selection: %v", err)
	default:
	}
	routeErr, elapsed := selectCatalog()
	select {
	case err := <-checkpointDone:
		t.Fatalf("wal_checkpoint(TRUNCATE) finished during selection after %s: checkpoint=%v route=%v", elapsed, err, routeErr)
	default:
	}
	if routeErr != nil {
		t.Fatalf("TRUNCATE waiting on another reader rejected the catalog session after %s: %+v", elapsed, routeErr)
	}
	if _, err := readConn.ExecContext(context.Background(), `COMMIT`); err != nil {
		t.Fatal(err)
	}
	select {
	case err := <-checkpointDone:
		if err != nil {
			t.Fatalf("wal_checkpoint(TRUNCATE) after the read mark was released: %v", err)
		}
	case <-time.After(5 * time.Second):
		t.Fatal("wal_checkpoint(TRUNCATE) did not return after the read mark was released")
	}
}
