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

	// beacon builds a topology beacon (no new restart) from a correlated new
	// instance, for advancing dwell continuity.
	beacon := func(provider, boot string, seq, restartSeq, restarts int64, current string, serving bool, at time.Time) SupervisorEventRecord {
		return SupervisorEventRecord{
			ProviderID: provider, BootID: boot, Schema: "macprovider.supervisor-event.v1",
			Kind: "beacon", Seq: seq, SupervisorLabel: "provider-watchdog", SupervisorVersion: "1.0",
			RestartsTotal: restarts, LastRestartSeq: restartSeq, LastRestartInstance: "inst-A",
			CurrentServiceInstance: current, ServingEligible: serving,
			ObservedAt: at, DwellThreshold: time.Second, StalenessThreshold: 30 * time.Second,
		}
	}

	// --- held path: restart, then CONTINUOUS serving observation of a new
	// correlated instance spanning the dwell threshold (two beacons: start timing,
	// then clear the threshold). A single later beacon must NOT back-fill held.
	if err := store.RecordSupervisorEvent(ctx, restart("prov-1", "BOOT-A", 1, 1, 1, "inst-A", "inst-A", t0)); err != nil {
		t.Fatalf("record r1: %v", err)
	}
	if r := read("prov-1", "BOOT-A"); r.dwellState != "correlated_pending" || r.restarts != 1 || r.lastRestartSeq != 1 || !r.restartObserved.Valid {
		t.Fatalf("after first restart: %+v", r)
	}
	// beacon@+0.5s begins timing the correlated inst-B (not held yet).
	if err := store.RecordSupervisorEvent(ctx, beacon("prov-1", "BOOT-A", 2, 1, 1, "inst-B", true, t0.Add(500*time.Millisecond))); err != nil {
		t.Fatalf("record held-start: %v", err)
	}
	if r := read("prov-1", "BOOT-A"); r.dwellState != "correlated_pending" {
		t.Fatalf("dwell should still be pending after first serving beacon: %+v", r)
	}
	// beacon@+2s: continuously serving-eligible for >= threshold -> held.
	if err := store.RecordSupervisorEvent(ctx, beacon("prov-1", "BOOT-A", 3, 1, 1, "inst-B", true, t0.Add(2*time.Second))); err != nil {
		t.Fatalf("record held: %v", err)
	}
	if r := read("prov-1", "BOOT-A"); r.dwellState != "held" || r.lastSeq != 3 || r.prevRestarts != 1 || !r.prevObserved.Valid {
		t.Fatalf("after held promotion: %+v", r)
	}

	// --- staleness gap must NOT back-fill held: begin timing, then a beacon after
	// a > staleness gap resets continuity even though elapsed >= dwell threshold.
	if err := store.RecordSupervisorEvent(ctx, restart("prov-4", "BOOT-D", 1, 1, 1, "inst-A", "inst-A", t0)); err != nil {
		t.Fatalf("record p4 r1: %v", err)
	}
	if err := store.RecordSupervisorEvent(ctx, beacon("prov-4", "BOOT-D", 2, 1, 1, "inst-B", true, t0.Add(500*time.Millisecond))); err != nil {
		t.Fatalf("record p4 start: %v", err)
	}
	// 45s gap > 30s staleness threshold: continuity broken, stays pending.
	if err := store.RecordSupervisorEvent(ctx, beacon("prov-4", "BOOT-D", 3, 1, 1, "inst-B", true, t0.Add(45*time.Second))); err != nil {
		t.Fatalf("record p4 gap: %v", err)
	}
	if r := read("prov-4", "BOOT-D"); r.dwellState != "correlated_pending" {
		t.Fatalf("staleness gap back-filled held: %+v", r)
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
	// Begin timing, then clear the threshold; the held-check finds the swap in the
	// restart window and classifies artifact_confounded instead of held.
	if err := store.RecordSupervisorEvent(ctx, beacon("prov-3", "BOOT-C", 2, 1, 1, "inst-B", true, t0.Add(500*time.Millisecond))); err != nil {
		t.Fatalf("record confound-start: %v", err)
	}
	if err := store.RecordSupervisorEvent(ctx, beacon("prov-3", "BOOT-C", 3, 1, 1, "inst-B", true, t0.Add(2*time.Second))); err != nil {
		t.Fatalf("record confound: %v", err)
	}
	if r := read("prov-3", "BOOT-C"); r.dwellState != "artifact_confounded" {
		t.Fatalf("expected artifact_confounded, got: %+v", r)
	}

	// --- counter regression on a higher seq is skipped non-blockingly.
	regress := restart("prov-2", "BOOT-B", 3, 2, 1 /* < stored 2 */, "inst-B", "inst-C", t0.Add(2*time.Second))
	if err := store.RecordSupervisorEvent(ctx, regress); err != nil {
		t.Fatalf("record regress: %v", err)
	}
	if r := read("prov-2", "BOOT-B"); r.lastSeq != 2 || r.restarts != 2 {
		t.Fatalf("counter regression adopted: %+v", r)
	}

	// --- deferral counter/detail consistency: a new last_deferral.seq without an
	// advanced deferrals_total is inconsistent and must be dropped non-blockingly.
	deferral := func(seq, deferralSeq, deferrals int64, at time.Time) SupervisorEventRecord {
		return SupervisorEventRecord{
			ProviderID: "prov-5", BootID: "BOOT-E", Schema: "macprovider.supervisor-event.v1",
			Kind: "deferral", Seq: seq, SupervisorLabel: "provider-watchdog", SupervisorVersion: "1.0",
			DeferralsTotal: deferrals, LastDeferralSeq: deferralSeq, LastDeferralTS: at.Format(time.RFC3339),
			ObservedAt: at, DwellThreshold: time.Second,
		}
	}
	if err := store.RecordSupervisorEvent(ctx, deferral(1, 1, 1, t0)); err != nil {
		t.Fatalf("record p5 d1: %v", err)
	}
	// seq advances, last_deferral.seq advances, but deferrals_total does NOT -> drop.
	if err := store.RecordSupervisorEvent(ctx, deferral(2, 2, 1, t0.Add(time.Second))); err != nil {
		t.Fatalf("record p5 inconsistent: %v", err)
	}
	var (
		p5Seq, p5DefSeq, p5Deferrals int64
	)
	if err := db.QueryRowContext(ctx, `
SELECT last_seq, last_deferral_seq, deferrals_total FROM provider_supervisor_events
 WHERE provider_id='prov-5' AND boot_id='BOOT-E'`).Scan(&p5Seq, &p5DefSeq, &p5Deferrals); err != nil {
		t.Fatalf("read p5: %v", err)
	}
	if p5Seq != 1 || p5DefSeq != 1 || p5Deferrals != 1 {
		t.Fatalf("inconsistent deferral adopted: last_seq=%d last_deferral_seq=%d deferrals_total=%d", p5Seq, p5DefSeq, p5Deferrals)
	}

	topo := func(provider, boot string, seq, restarts int64, at time.Time) SupervisorEventRecord {
		return SupervisorEventRecord{
			ProviderID: provider, BootID: boot, Schema: "macprovider.supervisor-event.v1",
			Kind: "beacon", Seq: seq, SupervisorLabel: "provider-watchdog", SupervisorVersion: "1.0",
			RestartsTotal: restarts, ServingEligible: true, ObservedAt: at, DwellThreshold: time.Second,
		}
	}

	// --- H1: same-boot state reset (watchdog state wiped) is adopted, not dropped.
	if err := store.RecordSupervisorEvent(ctx, topo("prov-6", "BOOT-F", 5000, 2, t0)); err != nil {
		t.Fatalf("record p6 high: %v", err)
	}
	// Fresh state: seq restarts at 1, counters at 0 under the SAME boot_id.
	if err := store.RecordSupervisorEvent(ctx, topo("prov-6", "BOOT-F", 1, 0, t0.Add(time.Second))); err != nil {
		t.Fatalf("record p6 reset: %v", err)
	}
	var p6Seq, p6Restarts int64
	if err := db.QueryRowContext(ctx, `
SELECT last_seq, restarts_total FROM provider_supervisor_events
 WHERE provider_id='prov-6' AND boot_id='BOOT-F'`).Scan(&p6Seq, &p6Restarts); err != nil {
		t.Fatalf("read p6: %v", err)
	}
	if p6Seq != 1 || p6Restarts != 0 {
		t.Fatalf("state reset not adopted: last_seq=%d restarts_total=%d (want 1, 0)", p6Seq, p6Restarts)
	}

	// --- M-3: first insert with a large seq (long-uptime first contact) is NOT
	// rejected by the step ceiling (only the absolute cap + consistency apply).
	if err := store.RecordSupervisorEvent(ctx, topo("prov-7", "BOOT-G", 200000, 1, t0)); err != nil {
		t.Fatalf("record p7 first-large: %v", err)
	}
	var p7Seq int64
	if err := db.QueryRowContext(ctx, `
SELECT last_seq FROM provider_supervisor_events WHERE provider_id='prov-7' AND boot_id='BOOT-G'`).Scan(&p7Seq); err != nil {
		t.Fatalf("read p7: %v", err)
	}
	if p7Seq != 200000 {
		t.Fatalf("large first-insert seq rejected: last_seq=%d (want 200000)", p7Seq)
	}

	// --- carve-out is INTENTIONAL and does NOT double-count a flap. A replay at
	// seq <= supervisorFreshStateSeqMax whose counters do not exceed the stored
	// high-water is a mid-boot state reset (adopted per SPEC-025 §5.4), not a stale
	// no-op; flaps_total is preserved, and a restart the coordinator ALREADY observed
	// before the reset must not be re-counted as a new flap by the next real beacon.
	if err := store.RecordSupervisorEvent(ctx, restart("prov-8", "BOOT-H", 1, 1, 1, "inst-A", "inst-A", t0)); err != nil {
		t.Fatalf("record p8 r1: %v", err)
	}
	if err := store.RecordSupervisorEvent(ctx, restart("prov-8", "BOOT-H", 2, 2, 2, "inst-B", "inst-B", t0.Add(200*time.Millisecond))); err != nil {
		t.Fatalf("record p8 r2 (flap): %v", err)
	}
	// advance above the carve-out bound so the replay below is unambiguously a reset.
	if err := store.RecordSupervisorEvent(ctx, beacon("prov-8", "BOOT-H", 5, 2, 2, "inst-C", true, t0.Add(400*time.Millisecond))); err != nil {
		t.Fatalf("record p8 advance: %v", err)
	}
	if err := store.RecordSupervisorEvent(ctx, restart("prov-8", "BOOT-H", 1, 1, 1, "inst-A", "inst-B", t0.Add(time.Second))); err != nil {
		t.Fatalf("record p8 reset replay: %v", err)
	}
	if r := read("prov-8", "BOOT-H"); r.lastSeq != 1 || r.restarts != 1 || r.flaps != 1 {
		t.Fatalf("carve-out replay not adopted (or flaps not preserved): %+v", r)
	}
	// The next real restart must NOT finalize the already-known restart#1 as a flap.
	if err := store.RecordSupervisorEvent(ctx, restart("prov-8", "BOOT-H", 6, 3, 2, "inst-D", "inst-E", t0.Add(2*time.Second))); err != nil {
		t.Fatalf("record p8 next: %v", err)
	}
	if r := read("prov-8", "BOOT-H"); r.flaps != 1 {
		t.Fatalf("flap double-counted after carve-out replay: flaps=%d (want 1)", r.flaps)
	}

	// --- stale seq ABOVE the carve-out bound is a full no-op (never a reset).
	if err := store.RecordSupervisorEvent(ctx, restart("prov-9", "BOOT-I", 5, 1, 1, "inst-A", "inst-A", t0)); err != nil {
		t.Fatalf("record p9 base: %v", err)
	}
	if err := store.RecordSupervisorEvent(ctx, restart("prov-9", "BOOT-I", 4, 1, 1, "inst-A", "inst-A", t0.Add(time.Second))); err != nil {
		t.Fatalf("record p9 stale: %v", err)
	}
	if r := read("prov-9", "BOOT-I"); r.lastSeq != 5 || r.restarts != 1 {
		t.Fatalf("stale seq above carve-out bound mutated state: %+v", r)
	}

	// --- a SAME-seq NON-serving observation (a sub-tick serving flip: heartbeat
	// cadence < watchdog tick) breaks dwell continuity and must not be swallowed into
	// a false held (SPEC-025 §5.4: reset dwell on any non-serving state).
	if err := store.RecordSupervisorEvent(ctx, restart("prov-10", "BOOT-J", 1, 1, 1, "inst-A", "inst-A", t0)); err != nil {
		t.Fatalf("record p10 r1: %v", err)
	}
	if err := store.RecordSupervisorEvent(ctx, beacon("prov-10", "BOOT-J", 2, 1, 1, "inst-B", true, t0.Add(500*time.Millisecond))); err != nil {
		t.Fatalf("record p10 timing-start: %v", err)
	}
	// SAME seq 2, now NON-serving: resets the dwell timer, stays pending.
	if err := store.RecordSupervisorEvent(ctx, beacon("prov-10", "BOOT-J", 2, 1, 1, "inst-B", false, t0.Add(time.Second))); err != nil {
		t.Fatalf("record p10 non-serving: %v", err)
	}
	// seq 3 serving past the dwell threshold begins timing FRESH (not held here).
	if err := store.RecordSupervisorEvent(ctx, beacon("prov-10", "BOOT-J", 3, 1, 1, "inst-B", true, t0.Add(3*time.Second))); err != nil {
		t.Fatalf("record p10 resume: %v", err)
	}
	if r := read("prov-10", "BOOT-J"); r.dwellState != "correlated_pending" {
		t.Fatalf("same-seq non-serving did not break dwell (false held risk): %+v", r)
	}

	// --- a SAME-seq wipe (seq unchanged but a counter REGRESSED) is adopted as a
	// mid-boot state reset; strict `<` alone left this same-seq case unrecoverable.
	if err := store.RecordSupervisorEvent(ctx, topo("prov-11", "BOOT-K", 2, 2, t0)); err != nil {
		t.Fatalf("record p11 base: %v", err)
	}
	if err := store.RecordSupervisorEvent(ctx, topo("prov-11", "BOOT-K", 2, 1, t0.Add(time.Second))); err != nil {
		t.Fatalf("record p11 same-seq wipe: %v", err)
	}
	if r := read("prov-11", "BOOT-K"); r.lastSeq != 2 || r.restarts != 1 {
		t.Fatalf("same-seq wipe not adopted as reset: %+v", r)
	}
}
