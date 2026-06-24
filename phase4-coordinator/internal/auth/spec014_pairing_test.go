package auth

import (
	"context"
	"errors"
	"path/filepath"
	"sync"
	"testing"
	"time"
)

func TestPairOTExpiresAt_Exactly600s(t *testing.T) {
	store := openSpec014Store(t)
	defer store.Close()
	now := time.Date(2026, 6, 21, 12, 0, 0, 0, time.UTC)
	mint, err := store.MintPairOT(context.Background(), "provider-a", now)
	if err != nil {
		t.Fatalf("MintPairOT: %v", err)
	}
	if got := mint.ExpiresAt.Sub(now); got != 10*time.Minute {
		t.Fatalf("expires delta = %s, want 10m", got)
	}
}

func TestBindRace_TwoCallers_OneSucceeds_OneGets410(t *testing.T) {
	store := openSpec014Store(t)
	defer store.Close()
	ctx := context.Background()
	now := time.Date(2026, 6, 21, 12, 0, 0, 0, time.UTC)
	sessionID, pairOT := seedSpec014SessionAndPairOT(t, store, now)

	var wg sync.WaitGroup
	errs := make(chan error, 2)
	for i := 0; i < 2; i++ {
		wg.Add(1)
		go func() {
			defer wg.Done()
			_, err := store.BindPairOT(ctx, sessionID, pairOT, now.Add(time.Second), nil)
			errs <- err
		}()
	}
	wg.Wait()
	close(errs)
	successes := 0
	gone := 0
	for err := range errs {
		switch {
		case err == nil:
			successes++
		case errors.Is(err, ErrPairOTInvalid):
			gone++
		default:
			t.Fatalf("unexpected bind error: %v", err)
		}
	}
	if successes != 1 || gone != 1 {
		t.Fatalf("successes=%d gone=%d, want 1/1", successes, gone)
	}
}

func TestConsumePendingPairOT_AtomicallyNulled(t *testing.T) {
	store := openSpec014Store(t)
	defer store.Close()
	ctx := context.Background()
	now := time.Date(2026, 6, 21, 12, 0, 0, 0, time.UTC)
	sessionID, pairOT := seedSpec014SessionAndPairOT(t, store, now)
	if _, err := store.DB().ExecContext(ctx, `UPDATE mp_sessions SET pending_pair_ot = ?, pending_pair_ot_expires_at = ? WHERE id = ?`, pairOT, timeText(now.Add(10*time.Minute)), sessionID); err != nil {
		t.Fatalf("seed pending pair_ot: %v", err)
	}
	pending, err := store.ConsumePendingPairOT(ctx, sessionID, now.Add(time.Second))
	if err != nil {
		t.Fatalf("consume pending hint: %v", err)
	}
	if pending != pairOT {
		t.Fatalf("pending pair_ot = %q, want %q", pending, pairOT)
	}
	if _, err := store.BindPairOT(ctx, sessionID, pending, now.Add(time.Second), nil); err != nil {
		t.Fatalf("bind consumed pending hint: %v", err)
	}
	if _, err := store.ConsumePendingPairOT(ctx, sessionID, now.Add(2*time.Second)); !errors.Is(err, ErrPendingPairOTMissing) {
		t.Fatalf("second consume err = %v, want ErrPendingPairOTMissing", err)
	}
}

func TestBindPairOT_EnqueueFailureRollsBackBurnAndOwnership(t *testing.T) {
	store := openSpec014Store(t)
	defer store.Close()
	ctx := context.Background()
	now := time.Date(2026, 6, 21, 12, 0, 0, 0, time.UTC)
	sessionID, pairOT := seedSpec014SessionAndPairOT(t, store, now)
	enqueueErr := errors.New("enqueue failed")

	if _, err := store.BindPairOT(ctx, sessionID, pairOT, now.Add(time.Second), func(BindResult) error {
		return enqueueErr
	}); !errors.Is(err, enqueueErr) {
		t.Fatalf("BindPairOT enqueue err = %v, want %v", err, enqueueErr)
	}
	owned, err := store.HasOwnership(ctx, "provider-a")
	if err != nil {
		t.Fatalf("HasOwnership: %v", err)
	}
	if owned {
		t.Fatalf("ownership should roll back when enqueue fails")
	}
	if _, err := store.BindPairOT(ctx, sessionID, pairOT, now.Add(2*time.Second), nil); err != nil {
		t.Fatalf("BindPairOT after enqueue rollback: %v", err)
	}
}

func TestRateLimit_5PerHour_PersistsAcrossRestart(t *testing.T) {
	dbPath := filepath.Join(t.TempDir(), "coordinator.db")
	store, err := OpenStore(dbPath)
	if err != nil {
		t.Fatalf("OpenStore: %v", err)
	}
	now := time.Date(2026, 6, 21, 12, 0, 0, 0, time.UTC)
	for i := 0; i < 5; i++ {
		if err := store.LogPairOTMint(context.Background(), "provider-a", "127.0.0.1", "test", 200, now.Add(time.Duration(i)*time.Minute)); err != nil {
			t.Fatalf("log mint %d: %v", i, err)
		}
	}
	if err := store.Close(); err != nil {
		t.Fatalf("close: %v", err)
	}
	store, err = OpenStore(dbPath)
	if err != nil {
		t.Fatalf("reopen: %v", err)
	}
	defer store.Close()
	count, _, err := store.CountRecentSuccessfulPairOTRefreshMints(context.Background(), "provider-a", now)
	if err != nil {
		t.Fatalf("count recent: %v", err)
	}
	if count != 5 {
		t.Fatalf("count after restart = %d, want 5", count)
	}
}

func openSpec014Store(t *testing.T) *Store {
	t.Helper()
	store, err := OpenStore(filepath.Join(t.TempDir(), "coordinator.db"))
	if err != nil {
		t.Fatalf("OpenStore: %v", err)
	}
	return store
}

func seedSpec014SessionAndPairOT(t *testing.T, store *Store, now time.Time) (string, string) {
	t.Helper()
	ctx := context.Background()
	if err := store.UpsertGitHubIdentity(ctx, 42, "octo", now); err != nil {
		t.Fatalf("seed identity: %v", err)
	}
	sessionID, err := store.CreateMPSession(ctx, 42, nullString(""), now)
	if err != nil {
		t.Fatalf("seed session: %v", err)
	}
	mint, err := store.MintPairOT(ctx, "provider-a", now)
	if err != nil {
		t.Fatalf("seed pair_ot: %v", err)
	}
	return sessionID, mint.PairOT
}
