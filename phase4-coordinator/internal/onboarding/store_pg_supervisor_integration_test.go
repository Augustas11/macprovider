//go:build integration

package onboarding

import (
	"context"
	"database/sql"
	"testing"
	"time"

	_ "github.com/lib/pq"
	tc "github.com/testcontainers/testcontainers-go"
	tcpg "github.com/testcontainers/testcontainers-go/modules/postgres"
	"github.com/testcontainers/testcontainers-go/wait"

	statsmigrations "github.com/augstar/macprovider-coordinator/internal/stats/migrations"
)

// RFC-001 §7 / F5 (#1386): the provider_supervisor_events upsert is latest-wins
// by seq, keeps high-water counters, anchors last_restart_observed_at to
// coordinator wall-clock, and finalizes a prior restart as held vs flap.
func TestRecordSupervisorEventUpsertAndFlapFinalization(t *testing.T) {
	ctx, cancel := context.WithTimeout(context.Background(), 90*time.Second)
	defer cancel()
	container, err := tcpg.Run(ctx, referralAttemptPGImage,
		tcpg.WithDatabase("supervisor_events"),
		tcpg.WithUsername("postgres"),
		tcpg.WithPassword(referralAttemptPGPass),
		tc.WithWaitStrategy(wait.ForLog("database system is ready to accept connections").WithOccurrence(2).WithStartupTimeout(60*time.Second)),
	)
	if err != nil {
		skipOnMissingDocker(t, err)
		t.Fatalf("start postgres: %v", err)
	}
	t.Cleanup(func() {
		cleanup, cleanupCancel := context.WithTimeout(context.Background(), 30*time.Second)
		defer cleanupCancel()
		_ = container.Terminate(cleanup)
	})
	dsn, err := container.ConnectionString(ctx, "sslmode=disable")
	if err != nil {
		t.Fatal(err)
	}
	db, err := sql.Open("postgres", dsn)
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { _ = db.Close() })
	if err := statsmigrations.Apply(ctx, db); err != nil {
		t.Fatalf("apply migrations: %v", err)
	}
	store := &PGStore{db: db}

	type row struct {
		lastSeq         int64
		restarts        int64
		prevRestarts    int64
		lastRestartSeq  int64
		flaps           int64
		dwellState      string
		restartObserved sql.NullTime
		prevObserved    sql.NullTime
	}
	read := func(provider, boot string) row {
		var r row
		err := db.QueryRowContext(ctx, `
SELECT last_seq, restarts_total, prev_restarts_total, last_restart_seq, flaps_total,
       last_restart_dwell_state, last_restart_observed_at, prev_observed_at
  FROM provider_supervisor_events WHERE provider_id=$1 AND boot_id=$2`, provider, boot).Scan(
			&r.lastSeq, &r.restarts, &r.prevRestarts, &r.lastRestartSeq, &r.flaps,
			&r.dwellState, &r.restartObserved, &r.prevObserved)
		if err != nil {
			t.Fatalf("read row (%s,%s): %v", provider, boot, err)
		}
		return r
	}

	t0 := time.Now().UTC().Truncate(time.Second)
	restart := func(provider, boot string, seq, restartSeq, restarts int64, oldInstance, current string, at time.Time) SupervisorEventRecord {
		return SupervisorEventRecord{
			ProviderID: provider, BootID: boot, Schema: "macprovider.supervisor-event.v1",
			Kind: "restart", Seq: seq, SupervisorLabel: "provider-watchdog", SupervisorVersion: "1.0",
			RestartsTotal: restarts, LastRestartSeq: restartSeq, LastRestartTS: at.Format(time.RFC3339),
			LastRestartCooldown: "armed", LastRestartInstance: oldInstance,
			CurrentServiceInstance: current, ServingEligible: true, ObservedAt: at, DwellThreshold: time.Second,
		}
	}

	// --- held path: restart, then a later beacon from a NEW instance past dwell.
	if err := store.RecordSupervisorEvent(ctx, restart("prov-1", "BOOT-A", 1, 1, 1, "inst-A", "inst-A", t0)); err != nil {
		t.Fatalf("record r1: %v", err)
	}
	if r := read("prov-1", "BOOT-A"); r.dwellState != "correlated_pending" || r.restarts != 1 || r.lastRestartSeq != 1 || !r.restartObserved.Valid {
		t.Fatalf("after first restart: %+v", r)
	}
	// Topology beacon seq=2, same last_restart_seq, NEW current instance, > threshold later.
	held := SupervisorEventRecord{
		ProviderID: "prov-1", BootID: "BOOT-A", Schema: "macprovider.supervisor-event.v1",
		Kind: "beacon", Seq: 2, SupervisorLabel: "provider-watchdog", SupervisorVersion: "1.0",
		RestartsTotal: 1, LastRestartSeq: 1, LastRestartInstance: "inst-A",
		CurrentServiceInstance: "inst-B", ServingEligible: true,
		ObservedAt: t0.Add(2 * time.Second), DwellThreshold: time.Second,
	}
	if err := store.RecordSupervisorEvent(ctx, held); err != nil {
		t.Fatalf("record held: %v", err)
	}
	if r := read("prov-1", "BOOT-A"); r.dwellState != "held" || r.lastSeq != 2 || r.prevRestarts != 1 || !r.prevObserved.Valid {
		t.Fatalf("after held promotion: %+v", r)
	}

	// --- flap path: two restarts within the dwell threshold.
	if err := store.RecordSupervisorEvent(ctx, restart("prov-2", "BOOT-B", 1, 1, 1, "inst-A", "inst-A", t0)); err != nil {
		t.Fatalf("record p2 r1: %v", err)
	}
	if err := store.RecordSupervisorEvent(ctx, restart("prov-2", "BOOT-B", 2, 2, 2, "inst-B", "inst-B", t0.Add(200*time.Millisecond))); err != nil {
		t.Fatalf("record p2 r2: %v", err)
	}
	if r := read("prov-2", "BOOT-B"); r.flaps != 1 || r.dwellState != "correlated_pending" || r.restarts != 2 || r.lastRestartSeq != 2 {
		t.Fatalf("after flap: %+v", r)
	}

	// --- artifact_confounded: an artifact-write autoupdate event in the restart
	// window makes the recovery non-clean (not held/flap).
	if err := store.RecordSupervisorEvent(ctx, restart("prov-3", "BOOT-C", 1, 1, 1, "inst-A", "inst-A", t0)); err != nil {
		t.Fatalf("record p3 r1: %v", err)
	}
	if _, err := db.ExecContext(ctx, `
INSERT INTO provider_autoupdate_events (provider_id, observed_at, phase, outcome)
VALUES ('prov-3', $1, 'swap', 'success')`, t0.Add(300*time.Millisecond)); err != nil {
		t.Fatalf("insert autoupdate event: %v", err)
	}
	confound := SupervisorEventRecord{
		ProviderID: "prov-3", BootID: "BOOT-C", Schema: "macprovider.supervisor-event.v1",
		Kind: "beacon", Seq: 2, SupervisorLabel: "provider-watchdog", SupervisorVersion: "1.0",
		RestartsTotal: 1, LastRestartSeq: 1, LastRestartInstance: "inst-A",
		CurrentServiceInstance: "inst-B", ServingEligible: true,
		ObservedAt: t0.Add(2 * time.Second), DwellThreshold: time.Second,
	}
	if err := store.RecordSupervisorEvent(ctx, confound); err != nil {
		t.Fatalf("record confound: %v", err)
	}
	if r := read("prov-3", "BOOT-C"); r.dwellState != "artifact_confounded" {
		t.Fatalf("expected artifact_confounded, got: %+v", r)
	}

	// --- stale seq is a full no-op.
	stale := restart("prov-2", "BOOT-B", 1, 1, 1, "inst-A", "inst-A", t0.Add(time.Second))
	if err := store.RecordSupervisorEvent(ctx, stale); err != nil {
		t.Fatalf("record stale: %v", err)
	}
	if r := read("prov-2", "BOOT-B"); r.lastSeq != 2 || r.restarts != 2 || r.flaps != 1 {
		t.Fatalf("stale seq mutated state: %+v", r)
	}

	// --- counter regression on a higher seq is skipped non-blockingly.
	regress := restart("prov-2", "BOOT-B", 3, 2, 1 /* < stored 2 */, "inst-B", "inst-C", t0.Add(2*time.Second))
	if err := store.RecordSupervisorEvent(ctx, regress); err != nil {
		t.Fatalf("record regress: %v", err)
	}
	if r := read("prov-2", "BOOT-B"); r.lastSeq != 2 || r.restarts != 2 {
		t.Fatalf("counter regression adopted: %+v", r)
	}
}
