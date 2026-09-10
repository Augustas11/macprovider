//go:build integration

package rewards_test

import (
	"context"
	"testing"
	"time"

	"github.com/augstar/macprovider-coordinator/internal/autotune"
)

// The coordinator constructs its evidence reader over the onboarding database,
// not the rewards_writer database. Keep this direct reader check separate from
// useful-work journeys: it exercises every selected/joined column in
// PGEvidenceStore.LatestVerified with the deployed onboarding role.
func TestPGEvidenceStoreReadsAsProviderOnboardingRole(t *testing.T) {
	_, db := startPostgres(t)
	ctx := context.Background()

	// SET ROLE is connection-local. A one-connection pool makes the subsequent
	// concrete PGEvidenceStore call use this exact session without introducing a
	// test-only constructor or credentials.
	db.SetMaxOpenConns(1)
	db.SetMaxIdleConns(1)
	if _, err := db.ExecContext(ctx, "SET ROLE provider_onboarding"); err != nil {
		t.Fatalf("set provider_onboarding role: %v", err)
	}
	t.Cleanup(func() {
		_, _ = db.ExecContext(context.Background(), "RESET ROLE")
	})

	var currentUser string
	if err := db.QueryRowContext(ctx, "SELECT current_user").Scan(&currentUser); err != nil {
		t.Fatalf("read current role: %v", err)
	}
	if currentUser != "provider_onboarding" {
		t.Fatalf("current role = %q, want provider_onboarding", currentUser)
	}

	_, ok, err := autotune.NewPGEvidenceStore(db).LatestVerified(ctx, "provider-without-evidence", 24*time.Hour)
	if err != nil {
		t.Fatalf("latest verified evidence as provider_onboarding: %v", err)
	}
	if ok {
		t.Fatal("missing provider unexpectedly has verified evidence")
	}
}
