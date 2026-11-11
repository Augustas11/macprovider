package prewarm

import (
	"context"
	"database/sql"
	"path/filepath"
	"testing"
	"time"

	_ "modernc.org/sqlite"
)

func newTestDB(t *testing.T) *sql.DB {
	t.Helper()
	db, err := sql.Open("sqlite", filepath.Join(t.TempDir(), "p.db"))
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { db.Close() })
	db.SetMaxOpenConns(1)
	if _, err := db.Exec(`CREATE TABLE stats_idle_prewarm_events (
		provider_id TEXT NOT NULL, event TEXT NOT NULL, reason TEXT,
		recorded_at TIMESTAMP NOT NULL DEFAULT CURRENT_TIMESTAMP)`); err != nil {
		t.Fatal(err)
	}
	return db
}

func TestRecorderStoresReasonAndNullReason(t *testing.T) {
	db := newTestDB(t)
	rec := NewRecorder(db)
	ctx := context.Background()
	if err := rec.RecordIdlePrewarmEvent(ctx, "p1", "idle_prewarm_started", ""); err != nil {
		t.Fatal(err)
	}
	if err := rec.RecordIdlePrewarmEvent(ctx, "p1", "idle_prewarm_skipped", "busy"); err != nil {
		t.Fatal(err)
	}
	var reason sql.NullString
	if err := db.QueryRow(`SELECT reason FROM stats_idle_prewarm_events WHERE event='idle_prewarm_started'`).Scan(&reason); err != nil {
		t.Fatal(err)
	}
	if reason.Valid {
		t.Fatalf("empty reason must be stored as NULL, got %q", reason.String)
	}
	if err := db.QueryRow(`SELECT reason FROM stats_idle_prewarm_events WHERE event='idle_prewarm_skipped'`).Scan(&reason); err != nil {
		t.Fatal(err)
	}
	if !reason.Valid || reason.String != "busy" {
		t.Fatalf("reason = %+v, want busy", reason)
	}
}

func TestRecorderErrorsAndNilReceiver(t *testing.T) {
	var nilRec *Recorder
	if err := nilRec.RecordIdlePrewarmEvent(context.Background(), "p", "e", "r"); err != nil {
		t.Fatalf("nil recorder: %v", err)
	}
	if err := NewRecorder(nil).RecordIdlePrewarmEvent(context.Background(), "p", "e", ""); err != nil {
		t.Fatalf("nil db: %v", err)
	}
	db := newTestDB(t)
	if _, err := db.Exec(`DROP TABLE stats_idle_prewarm_events`); err != nil {
		t.Fatal(err)
	}
	rec := NewRecorder(db)
	if err := rec.RecordIdlePrewarmEvent(context.Background(), "p", "e", ""); err == nil {
		t.Fatal("expected error for missing table (null reason)")
	}
	if err := rec.RecordIdlePrewarmEvent(context.Background(), "p", "e", "r"); err == nil {
		t.Fatal("expected error for missing table (with reason)")
	}
}

func TestReaderAggregatesPerProviderWithinLastHour(t *testing.T) {
	db := newTestDB(t)
	now := time.Now().UTC()
	ins := func(provider, event string, reason any, at time.Time) {
		t.Helper()
		if _, err := db.Exec(`INSERT INTO stats_idle_prewarm_events (provider_id, event, reason, recorded_at) VALUES ($1,$2,$3,$4)`,
			provider, event, reason, at); err != nil {
			t.Fatal(err)
		}
	}
	recent := now.Add(-10 * time.Minute)
	ins("p1", "idle_prewarm_started", nil, recent)
	ins("p1", "idle_prewarm_started", nil, recent)
	ins("p1", "idle_prewarm_skipped", "busy", recent)
	ins("p1", "idle_prewarm_skipped", "busy", recent)
	ins("p1", "idle_prewarm_skipped", "thermal", recent)
	ins("p1", "idle_prewarm_skipped", nil, recent)
	ins("p1", "idle_prewarm_started", nil, now.Add(-2*time.Hour)) // too old
	ins("p1", "idle_prewarm_skipped", "old", now.Add(-2*time.Hour))
	ins("p2", "idle_prewarm_started", nil, recent) // other provider
	ins("p2", "idle_prewarm_skipped", "other", recent)

	got, err := NewReader(db).ProviderIdlePrewarm(context.Background(), "p1")
	if err != nil {
		t.Fatal(err)
	}
	if got.EventsLast1h["idle_prewarm_started"] != 2 || got.EventsLast1h["idle_prewarm_skipped"] != 4 || len(got.EventsLast1h) != 2 {
		t.Fatalf("events = %v", got.EventsLast1h)
	}
	if len(got.SkipsByReasonLast1h) != 2 || got.SkipsByReasonLast1h["busy"] != 2 || got.SkipsByReasonLast1h["thermal"] != 1 {
		t.Fatalf("skips = %v", got.SkipsByReasonLast1h)
	}
}

func TestReaderNilAndErrorPaths(t *testing.T) {
	ctx := context.Background()
	for _, r := range []*Reader{nil, NewReader(nil)} {
		got, err := r.ProviderIdlePrewarm(ctx, "p")
		if err != nil || got.EventsLast1h == nil || got.SkipsByReasonLast1h == nil || len(got.EventsLast1h) != 0 {
			t.Fatalf("got %+v err %v, want empty non-nil maps", got, err)
		}
	}
	db := newTestDB(t)
	if _, err := db.Exec(`DROP TABLE stats_idle_prewarm_events`); err != nil {
		t.Fatal(err)
	}
	got, err := NewReader(db).ProviderIdlePrewarm(ctx, "p")
	if err == nil {
		t.Fatal("expected select error")
	}
	if got.EventsLast1h == nil {
		t.Fatal("maps must stay non-nil on error")
	}
}
