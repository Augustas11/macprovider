package router

import (
	"context"
	"path/filepath"
	"testing"

	"github.com/augstar/macprovider-gateway/internal/storage"
	"github.com/augstar/macprovider-gateway/internal/storage/sqlite"
)

// Compile-time assertion: *sqlite.Store satisfies router.ReadStore.
// M2-4 / PERF-4: this is the boundary that makes WithReadStore typed
// safely. If a future change to ReadStore adds a method *sqlite.Store
// doesn't implement, this line stops the build.
var _ ReadStore = (*sqlite.Store)(nil)

// Compile-time assertion: the wider Store also satisfies ReadStore,
// so readStore()'s fallback to s.store is sound.
var _ ReadStore = (Store)(nil)

// TestReadStoreBoundaryRejectsWritesAtCompileTime documents — for any
// future reader — what `readStore() ReadStore` actually buys us.
// Uncommenting the lines marked `// WANT: compile error` MUST refuse
// to build. We don't actually execute write methods through readStore
// here (that would be a runtime test); the value is the type-level
// guard. Removing the ReadStore interface would silently let a write
// compile.
func TestReadStoreBoundaryRejectsWritesAtCompileTime(t *testing.T) {
	ctx := context.Background()
	path := filepath.Join(t.TempDir(), "gateway.db")
	primary, err := sqlite.Open(ctx, path)
	if err != nil {
		t.Fatalf("Open: %v", err)
	}
	defer primary.Close()

	ro, err := sqlite.OpenReadOnly(ctx, path)
	if err != nil {
		t.Fatalf("OpenReadOnly: %v", err)
	}
	defer ro.Close()

	// This is the type guard in action — assigning a *sqlite.Store to
	// a ReadStore variable is fine; the narrow interface only exposes
	// reads.
	var rs ReadStore = ro
	if _, _, err := rs.DailyUsage(ctx, "no-such-account", "2026-05-29"); err != nil {
		t.Fatalf("DailyUsage via ReadStore: %v", err)
	}

	// WANT: compile error. Uncommenting these MUST break the build —
	// they prove ReadStore is a genuine narrow surface, not a wider
	// interface in disguise.
	//
	//   rs.CreateAccount(ctx, storage.Account{AccountID: "x"})
	//   rs.SetCapacityTier(ctx, storage.CapacityTier{Tier: "tier_1"})
	//   rs.ReserveQuota(ctx, storage.ReservationRequest{})
	//   rs.SettleReservation(ctx, storage.ReservationSettlement{})
	//   rs.InsertUsageEvent(ctx, storage.UsageEvent{})
	_ = storage.Account{}
}
