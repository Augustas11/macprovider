package trustpool_test

import (
	"context"
	"database/sql"
	"path/filepath"
	"strings"
	"testing"
	"time"

	"github.com/augstar/macprovider-coordinator/internal/poolmanifest"
	"github.com/augstar/macprovider-coordinator/internal/sqliteutil"
	"github.com/augstar/macprovider-coordinator/internal/trustpool"
)

// #1880 round-2 audit (Arch M1): a pre-#1880 coordinator rejects an
// overlapping policy window while rebuilding a pool's history, so a history
// with a SPEC-042 0.0.42 supersession blocks every rollback tier but p1880.
func TestManifestReplayCheckBlocksSupersessionBeforeP1880(t *testing.T) {
	ctx := context.Background()
	build := func(supersede bool) *sql.DB {
		path := filepath.Join(t.TempDir(), "coordinator.db")
		db, err := sql.Open("sqlite", sqliteutil.WithPragmas(path))
		if err != nil {
			t.Fatal(err)
		}
		db.SetMaxOpenConns(1)
		t.Cleanup(func() { _ = db.Close() })
		store, err := trustpool.NewStore(db, trustpool.WithPoolModelAcceptance(acceptAllPoolModels))
		if err != nil {
			t.Fatal(err)
		}
		ts := time.Unix(1800040000, 0).UTC()
		root := newRootFixture(t)
		approveCreator(t, store, "creator-a", "approval-v1", "approval-version-1", "candidate", time.Now().Add(24*time.Hour), trustpool.CreatorStatusEnabled)
		v1 := signedManifestWithPolicyCoreMutation(t, "op-manifest", ts.Add(2*time.Second), root.poolID, 1, root, func(core *poolmanifest.PolicyCore) {
			core.SettlementMode = "enforce"
		})
		v2 := signedManifestExtendingWithPolicyCoreMutation(t, "op-manifest-2", ts.Add(3*time.Second), v1, root, func(core *poolmanifest.PolicyCore) {
			allowLlamacpp(core)
			if supersede {
				// Start inside v1's window: v2 supersedes v1 from here on.
				core.NotBeforeUnix -= 10
			}
		})
		appendTrustPoolEvents(t, ctx, store,
			ev("op-create", ts, trustpool.EventPoolCreated, root.poolID, func(e *trustpool.DurableEvent) {
				e.CreatorAccountID = "creator-a"
				e.ApprovalRecordID = "approval-v1"
			}),
			signedRootRegistrationForIssue(t, "op-root", ts.Add(time.Second), root.poolID, "creator-a", "approval-v1", issueRootNonce(t, store, "creator-a", "approval-v1", ts.Add(time.Hour)), root),
			v1,
			v2,
		)
		return db
	}

	superseding := build(true)
	for _, tier := range []string{trustpool.RollbackTierM8, trustpool.RollbackTierM9, trustpool.RollbackTierP1816, trustpool.RollbackTierP1880} {
		got, err := trustpool.CheckManifestHistoryReplay(ctx, superseding, tier)
		if err != nil {
			t.Fatalf("tier %s: %v", tier, err)
		}
		if len(got.SupersededWindows) != 1 || !strings.Contains(got.SupersededWindows[0], "manifest versions 1 and 2") {
			t.Fatalf("tier %s: superseded_windows=%v", tier, got.SupersededWindows)
		}
		blocked := false
		for _, reason := range got.CannotReplay {
			if strings.HasPrefix(reason, "superseded policy window in pool ") {
				blocked = true
			}
		}
		if want := tier != trustpool.RollbackTierP1880; blocked != want {
			t.Fatalf("tier %s: blocked by supersession=%v want %v (%v)", tier, blocked, want, got.CannotReplay)
		}
	}

	adjacent := build(false)
	got, err := trustpool.CheckManifestHistoryReplay(ctx, adjacent, trustpool.RollbackTierP1816)
	if err != nil {
		t.Fatal(err)
	}
	if len(got.SupersededWindows) != 0 || len(got.CannotReplay) != 0 {
		t.Fatalf("adjacent windows: superseded=%v cannot_replay=%v, want replayable", got.SupersededWindows, got.CannotReplay)
	}
}

// #1880 round-2 audit (Arch M2): a pre-#1880 coordinator ignores
// requested_pool_model_id, so a live offer naming a pool entry blocks a
// rollback to it; terminal heads and unnamed offers do not.
func TestPoolSelectionRollbackBlocksLiveSelectorOffers(t *testing.T) {
	ctx := context.Background()
	db, err := sql.Open("sqlite", filepath.Join(t.TempDir(), "coordinator.db"))
	if err != nil {
		t.Fatal(err)
	}
	defer db.Close()
	// Before the column exists (a pre-#1880 database) nothing blocks.
	if _, err := db.ExecContext(ctx, `CREATE TABLE model_admission_events (id INTEGER PRIMARY KEY AUTOINCREMENT, provider_id TEXT NOT NULL, candidate_id TEXT NOT NULL, state TEXT NOT NULL)`); err != nil {
		t.Fatal(err)
	}
	if got, err := trustpool.CheckPoolSelectionRollback(ctx, db, trustpool.RollbackTierP1816); err != nil || got.Blocked {
		t.Fatalf("pre-#1880 schema: %+v err=%v", got, err)
	}
	if _, err := db.ExecContext(ctx, `ALTER TABLE model_admission_events ADD COLUMN requested_pool_model_id TEXT NOT NULL DEFAULT ''`); err != nil {
		t.Fatal(err)
	}
	insert := func(provider, candidate, state, requested string) {
		t.Helper()
		if _, err := db.ExecContext(ctx, `INSERT INTO model_admission_events (provider_id, candidate_id, state, requested_pool_model_id) VALUES (?, ?, ?, ?)`, provider, candidate, state, requested); err != nil {
			t.Fatal(err)
		}
	}
	const pool = "pool/AAAAAAAAAAAAAAAAAAAAAA/m"
	insert("p1", "live", "offer_submitted", pool)
	insert("p1", "withdrawn", "offer_submitted", pool)
	insert("p1", "withdrawn", "withdrawn", pool)
	insert("p1", "unnamed", "catalog_priced", "")
	insert("p2", "bound", "offer_submitted", pool)
	insert("p2", "bound", "catalog_priced", pool)

	got, err := trustpool.CheckPoolSelectionRollback(ctx, db, trustpool.RollbackTierP1816)
	if err != nil {
		t.Fatal(err)
	}
	want := []string{"p1/live -> " + pool, "p2/bound -> " + pool}
	if !got.Blocked || strings.Join(got.LiveSelectorOffers, ",") != strings.Join(want, ",") {
		t.Fatalf("p1816: %+v, want blocked by %v", got, want)
	}
	if got, err := trustpool.CheckPoolSelectionRollback(ctx, db, trustpool.RollbackTierP1880); err != nil || got.Blocked || len(got.LiveSelectorOffers) != 2 {
		t.Fatalf("p1880 target: %+v err=%v, want listed but not blocked", got, err)
	}
	if _, err := trustpool.CheckPoolSelectionRollback(ctx, db, "p9999"); err == nil {
		t.Fatal("unknown tier accepted")
	}
}
