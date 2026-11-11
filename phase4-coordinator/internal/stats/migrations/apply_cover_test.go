package migrations

import (
	"context"
	"database/sql"
	"database/sql/driver"
	"errors"
	"fmt"
	"io"
	"strings"
	"sync/atomic"
	"testing"
)

// fakeDB is a minimal in-memory database/sql driver that records what Apply
// executes, so the runner's control flow can be tested without Postgres.
type fakeDB struct {
	applied    map[int]string // committed schema_migrations_spec017 rows
	bodies     []string       // migration bodies executed, in order
	commits    int
	rollbacks  int
	failBody   string // exec error when a statement contains this text
	failQuery  bool   // fail the applied-versions SELECT
	failLock   bool   // fail pg_advisory_lock
	failBegin  bool
	unlocked   bool
	failCommit bool
	lockKey    any // argument passed to pg_advisory_lock
	unlockKey  any // argument passed to pg_advisory_unlock
	pending    map[int]string
}

type fakeDriver struct{ db *fakeDB }

func (d fakeDriver) Open(string) (driver.Conn, error) { return &fakeConn{db: d.db}, nil }

type fakeConn struct{ db *fakeDB }

func (c *fakeConn) Prepare(string) (driver.Stmt, error) { return nil, errors.New("unsupported") }
func (c *fakeConn) Close() error                        { return nil }
func (c *fakeConn) Begin() (driver.Tx, error) {
	if c.db.failBegin {
		return nil, errors.New("begin boom")
	}
	c.db.pending = map[int]string{}
	return &fakeTx{db: c.db}, nil
}

func (c *fakeConn) ExecContext(_ context.Context, q string, args []driver.NamedValue) (driver.Result, error) {
	switch {
	case strings.Contains(q, "pg_advisory_lock"):
		if c.db.failLock {
			return nil, errors.New("lock boom")
		}
		c.db.lockKey = args[0].Value
	case strings.Contains(q, "pg_advisory_unlock"):
		c.db.unlocked = true
		c.db.unlockKey = args[0].Value
	case strings.Contains(q, "INSERT INTO schema_migrations_spec017"):
		if c.db.failBody == "INSERT" {
			return nil, errors.New("insert boom")
		}
		c.db.pending[int(args[0].Value.(int64))] = args[1].Value.(string)
	case c.db.failBody != "" && strings.Contains(q, c.db.failBody):
		return nil, errors.New("body boom")
	case strings.Contains(q, "CREATE TABLE IF NOT EXISTS schema_migrations_spec017"):
	default:
		c.db.bodies = append(c.db.bodies, q)
	}
	return driver.RowsAffected(0), nil
}

func (c *fakeConn) QueryContext(_ context.Context, q string, _ []driver.NamedValue) (driver.Rows, error) {
	if c.db.failQuery {
		return nil, errors.New("query boom")
	}
	r := &fakeRows{}
	for v, n := range c.db.applied {
		r.rows = append(r.rows, []driver.Value{int64(v), n})
	}
	return r, nil
}

type fakeTx struct{ db *fakeDB }

func (t *fakeTx) Commit() error {
	if t.db.failCommit {
		return errors.New("commit boom")
	}
	t.db.commits++
	for v, n := range t.db.pending {
		t.db.applied[v] = n
	}
	return nil
}
func (t *fakeTx) Rollback() error { t.db.rollbacks++; return nil }

type fakeRows struct {
	rows [][]driver.Value
	i    int
}

func (r *fakeRows) Columns() []string { return []string{"version", "name"} }
func (r *fakeRows) Close() error      { return nil }
func (r *fakeRows) Next(dest []driver.Value) error {
	if r.i >= len(r.rows) {
		return io.EOF
	}
	copy(dest, r.rows[r.i])
	r.i++
	return nil
}

var fakeSeq atomic.Int64

func openFake(t *testing.T, f *fakeDB) *sql.DB {
	t.Helper()
	if f.applied == nil {
		f.applied = map[int]string{}
	}
	name := fmt.Sprintf("fakemig-%d", fakeSeq.Add(1))
	sql.Register(name, fakeDriver{db: f})
	db, err := sql.Open(name, "")
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { _ = db.Close() })
	return db
}

func TestApplyRunsAllMigrationsInOrderAndRecordsThem(t *testing.T) {
	f := &fakeDB{}
	if err := Apply(context.Background(), openFake(t, f)); err != nil {
		t.Fatalf("Apply: %v", err)
	}
	all, err := All()
	if err != nil {
		t.Fatal(err)
	}
	if len(f.bodies) != len(all) || f.commits != len(all) {
		t.Fatalf("bodies=%d commits=%d want %d", len(f.bodies), f.commits, len(all))
	}
	for i, m := range all {
		if f.bodies[i] != m.SQL {
			t.Fatalf("body %d executed out of order (want version %d)", i, m.Version)
		}
		if f.applied[m.Version] != m.Name {
			t.Fatalf("version %d recorded as %q, want %q", m.Version, f.applied[m.Version], m.Name)
		}
	}
	if !f.unlocked {
		t.Fatal("advisory lock was not released")
	}
	if f.lockKey != advisoryLockKey || f.unlockKey != advisoryLockKey {
		t.Fatalf("lock key=%v unlock key=%v, want both %d", f.lockKey, f.unlockKey, advisoryLockKey)
	}
}

func TestApplyCommitFailureIsWrappedAndNotRecorded(t *testing.T) {
	all, err := All()
	if err != nil {
		t.Fatal(err)
	}
	f := &fakeDB{failCommit: true}
	err = Apply(context.Background(), openFake(t, f))
	want := fmt.Sprintf("migration %03d_%s: commit", all[0].Version, all[0].Name)
	if err == nil || !strings.Contains(err.Error(), want) {
		t.Fatalf("err=%v, want containing %q", err, want)
	}
	if len(f.applied) != 0 {
		t.Fatalf("applied=%d, want 0", len(f.applied))
	}
}

func TestApplySkipsAlreadyAppliedVersions(t *testing.T) {
	all, err := All()
	if err != nil {
		t.Fatal(err)
	}
	f := &fakeDB{applied: map[int]string{}}
	for _, m := range all[:3] {
		f.applied[m.Version] = m.Name
	}
	if err := Apply(context.Background(), openFake(t, f)); err != nil {
		t.Fatalf("Apply: %v", err)
	}
	if want := len(all) - 3; len(f.bodies) != want {
		t.Fatalf("ran %d bodies, want %d", len(f.bodies), want)
	}
	if f.bodies[0] != all[3].SQL {
		t.Fatal("first executed body is not the first unapplied migration")
	}
	// Fully applied: a second run executes nothing.
	f.bodies = nil
	if err := Apply(context.Background(), openFake(t, f)); err != nil {
		t.Fatal(err)
	}
	if len(f.bodies) != 0 {
		t.Fatalf("idempotent rerun executed %d bodies", len(f.bodies))
	}
}

func TestApplyRefusesRecordedNameDrift(t *testing.T) {
	all, err := All()
	if err != nil {
		t.Fatal(err)
	}
	f := &fakeDB{applied: map[int]string{all[0].Version: "some_other_migration"}}
	err = Apply(context.Background(), openFake(t, f))
	if err == nil || !strings.Contains(err.Error(), "refusing to proceed") {
		t.Fatalf("err=%v, want name-drift refusal", err)
	}
	if len(f.bodies) != 0 {
		t.Fatal("migrations ran despite name drift")
	}
}

func TestApplyBodyFailureRollsBackAndNamesMigration(t *testing.T) {
	all, err := All()
	if err != nil {
		t.Fatal(err)
	}
	f := &fakeDB{failBody: all[1].SQL}
	err = Apply(context.Background(), openFake(t, f))
	if err == nil {
		t.Fatal("expected error")
	}
	want := fmt.Sprintf("migration %03d_%s", all[1].Version, all[1].Name)
	if !strings.Contains(err.Error(), want) || !strings.Contains(err.Error(), "exec body") {
		t.Fatalf("err=%v, want it to name %q", err, want)
	}
	if f.rollbacks != 1 || f.commits != 1 {
		t.Fatalf("rollbacks=%d commits=%d, want 1/1", f.rollbacks, f.commits)
	}
	if _, ok := f.applied[all[1].Version]; ok {
		t.Fatal("failed migration was recorded as applied")
	}
	if !f.unlocked {
		t.Fatal("lock not released after failure")
	}
}

func TestApplyRecordFailureRollsBack(t *testing.T) {
	f := &fakeDB{failBody: "INSERT"}
	err := Apply(context.Background(), openFake(t, f))
	if err == nil || !strings.Contains(err.Error(), "record version") {
		t.Fatalf("err=%v, want record version error", err)
	}
	if f.commits != 0 || f.rollbacks != 1 || len(f.applied) != 0 {
		t.Fatalf("commits=%d rollbacks=%d applied=%d", f.commits, f.rollbacks, len(f.applied))
	}
}

func TestApplySetupErrorsAreWrapped(t *testing.T) {
	cases := []struct {
		name string
		db   *fakeDB
		want string
	}{
		{"lock", &fakeDB{failLock: true}, "acquire pg_advisory_lock"},
		{"load applied", &fakeDB{failQuery: true}, "query schema_migrations_spec017"},
		{"begin", &fakeDB{failBegin: true}, "begin"},
	}
	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			err := Apply(context.Background(), openFake(t, tc.db))
			if err == nil || !strings.Contains(err.Error(), tc.want) {
				t.Fatalf("err=%v, want containing %q", err, tc.want)
			}
			if len(tc.db.bodies) != 0 {
				t.Fatal("migration bodies ran after setup failure")
			}
		})
	}
}

func TestParseFilenameRejectsMalformedNames(t *testing.T) {
	ver, name, err := parseFilename("012_malibu_emission_ledger.up.sql")
	if err != nil || ver != 12 || name != "malibu_emission_ledger" {
		t.Fatalf("got %d %q %v", ver, name, err)
	}
	for _, bad := range []string{"nounderscore.up.sql", "abc_name.up.sql"} {
		if _, _, err := parseFilename(bad); err == nil {
			t.Errorf("parseFilename(%q) accepted a malformed name", bad)
		}
	}
}
