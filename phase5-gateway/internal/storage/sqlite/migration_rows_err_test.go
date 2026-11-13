package sqlite

import (
	"context"
	"database/sql"
	"database/sql/driver"
	"errors"
	"path/filepath"
	"strings"
	"sync"
	"testing"
)

// The migration probes read PRAGMA table_info (or a whole table) row by row
// and then decide what to alter. A read error in the middle of that loop ends
// rows.Next() early; database/sql reports it only through rows.Err(). A probe
// that skips rows.Err() acts on a truncated column list. These tests inject
// such an error through a wrapping driver and require every probe to return
// it.

var errInjectedRowFault = errors.New("injected row iteration fault")

const rowFaultDriverName = "sqlite_rowfault_test"

var rowFault struct {
	sync.Mutex
	match     string // substring of the query to fault; empty = disarmed
	rowsFirst int    // rows to deliver before the fault
	fired     bool
}

func armRowFault(match string, rowsFirst int) {
	rowFault.Lock()
	defer rowFault.Unlock()
	rowFault.match, rowFault.rowsFirst, rowFault.fired = match, rowsFirst, false
}

func disarmRowFault() (fired bool) {
	rowFault.Lock()
	defer rowFault.Unlock()
	fired = rowFault.fired
	rowFault.match, rowFault.fired = "", false
	return fired
}

type rowFaultDriver struct{ inner driver.Driver }

func (d *rowFaultDriver) Open(name string) (driver.Conn, error) {
	conn, err := d.inner.Open(name)
	if err != nil {
		return nil, err
	}
	return &rowFaultConn{Conn: conn}, nil
}

type rowFaultConn struct{ driver.Conn }

func (c *rowFaultConn) ExecContext(ctx context.Context, query string, args []driver.NamedValue) (driver.Result, error) {
	return c.Conn.(driver.ExecerContext).ExecContext(ctx, query, args)
}

func (c *rowFaultConn) BeginTx(ctx context.Context, opts driver.TxOptions) (driver.Tx, error) {
	return c.Conn.(driver.ConnBeginTx).BeginTx(ctx, opts)
}

func (c *rowFaultConn) QueryContext(ctx context.Context, query string, args []driver.NamedValue) (driver.Rows, error) {
	rows, err := c.Conn.(driver.QueryerContext).QueryContext(ctx, query, args)
	if err != nil {
		return nil, err
	}
	rowFault.Lock()
	defer rowFault.Unlock()
	if rowFault.match != "" && strings.Contains(query, rowFault.match) {
		return &rowFaultRows{Rows: rows, remaining: rowFault.rowsFirst}, nil
	}
	return rows, nil
}

type rowFaultRows struct {
	driver.Rows
	remaining int
}

func (r *rowFaultRows) Next(dest []driver.Value) error {
	if r.remaining == 0 {
		rowFault.Lock()
		rowFault.fired = true
		rowFault.Unlock()
		return errInjectedRowFault
	}
	r.remaining--
	return r.Rows.Next(dest)
}

var registerRowFaultDriver = sync.OnceFunc(func() {
	probe, err := sql.Open("sqlite", "")
	if err != nil {
		panic(err)
	}
	inner := probe.Driver()
	_ = probe.Close()
	sql.Register(rowFaultDriverName, &rowFaultDriver{inner: inner})
})

func TestMigrationProbesReturnRowIterationErrors(t *testing.T) {
	ctx := context.Background()
	path := filepath.Join(t.TempDir(), "gateway.db")
	migrated, err := Open(ctx, path)
	if err != nil {
		t.Fatalf("open: %v", err)
	}
	if err := migrated.Close(); err != nil {
		t.Fatalf("close: %v", err)
	}

	registerRowFaultDriver()
	db, err := sql.Open(rowFaultDriverName, sqliteDSN(path))
	if err != nil {
		t.Fatalf("open fault db: %v", err)
	}
	db.SetMaxOpenConns(1)
	t.Cleanup(func() { _ = db.Close() })
	s := &Store{db: db}

	cases := []struct {
		name      string
		query     string
		rowsFirst int
		run       func(context.Context) error
	}{
		{"quota reservation funding source", "table_info(quota_reservations)", 1, s.ensureQuotaReservationFundingSource},
		{"relay-blind settlement dispatch columns", "table_info(quota_reservations)", 1, s.ensureRelayBlindSettlementDispatchColumns},
		{"demand events observation columns", "table_info(demand_events)", 1, s.ensureDemandEventsObservationColumns},
		{"demand events serving telemetry columns", "table_info(demand_events)", 1, s.ensureDemandEventsServingTelemetryColumns},
		// The table is empty here, so the fault is the first read.
		{"demand events privacy buckets", "FROM demand_events", 0, s.ensureDemandEventsPrivacyBuckets},
		{"relay-blind accounting columns", "table_info(usage_events)", 1, s.ensureRelayBlindAccountingColumns},
		{"settlement reconcile backlog columns", "table_info(settlement_reconcile_attempts)", 1, s.ensureSettlementReconcileBacklogColumns},
		{"usage events composite key", "table_info(usage_events)", 1, s.ensureUsageEventsCompositePK},
		{"demo usage events composite key", "table_info(demo_usage_events)", 1, s.ensureDemoUsageEventsCompositePK},
	}
	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			// Control: on a migrated database the probe is a no-op. This
			// also proves the probe runs through the wrapping driver.
			if err := tc.run(ctx); err != nil {
				t.Fatalf("probe without fault: %v", err)
			}
			armRowFault(tc.query, tc.rowsFirst)
			err := tc.run(ctx)
			if fired := disarmRowFault(); !fired {
				t.Fatalf("fault for %q never fired; the test did not exercise the loop", tc.query)
			}
			if !errors.Is(err, errInjectedRowFault) {
				t.Fatalf("probe returned %v, want the row iteration error", err)
			}
		})
	}
}
