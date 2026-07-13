//go:build integration

package onboarding

// FIX-570 A1 (ADV-C2) regression — the durable provider_register_attempts marker
// must let ProviderRegistrationPrepared prove a committed App-track registration
// even after the operator-prunable provider_register_nonces replay cache is
// cleared in the 65s..2min reconcile window. Pre-fix ProviderRegistrationPrepared
// JOINed the replay cache, so pruning the nonce flipped a committed attempt to
// prepared=false and destructively compensated a live credential.
//
// Build-tagged so the default `go test ./...` lane on a Docker-less host does not
// require Postgres; the coordinator PG integration CI lane runs it.

import (
	"context"
	"crypto/ed25519"
	"crypto/rand"
	"database/sql"
	"testing"
	"time"

	_ "github.com/lib/pq"
	tc "github.com/testcontainers/testcontainers-go"
	tcpg "github.com/testcontainers/testcontainers-go/modules/postgres"
	"github.com/testcontainers/testcontainers-go/wait"

	statsmigrations "github.com/augstar/macprovider-coordinator/internal/stats/migrations"
)

const (
	a1PgImage       = "postgres:16.4-alpine3.20@sha256:5660c2cbfea50c7a9127d17dc4e48543eedd3d7a41a595a2dfa572471e37e64c"
	a1AdminPassword = "fix570-a1-admin-password"
)

func TestProviderRegistrationPreparedSurvivesNoncePrune(t *testing.T) {
	ctx, cancel := context.WithTimeout(context.Background(), 90*time.Second)
	defer cancel()
	container, err := tcpg.Run(ctx, a1PgImage,
		tcpg.WithDatabase("fix570_a1"),
		tcpg.WithUsername("postgres"),
		tcpg.WithPassword(a1AdminPassword),
		tc.WithWaitStrategy(
			wait.ForLog("database system is ready to accept connections").
				WithOccurrence(2).
				WithStartupTimeout(60*time.Second),
		),
	)
	if err != nil {
		t.Fatalf("start postgres: %v", err)
	}
	t.Cleanup(func() {
		bg, c := context.WithTimeout(context.Background(), 30*time.Second)
		defer c()
		_ = container.Terminate(bg)
	})
	dsn, err := container.ConnectionString(ctx, "sslmode=disable")
	if err != nil {
		t.Fatalf("connection string: %v", err)
	}
	adminDB, err := sql.Open("postgres", dsn)
	if err != nil {
		t.Fatalf("open admin: %v", err)
	}
	t.Cleanup(func() { _ = adminDB.Close() })
	mctx, mcancel := context.WithTimeout(ctx, 60*time.Second)
	defer mcancel()
	if err := statsmigrations.Apply(mctx, adminDB); err != nil {
		t.Fatalf("apply migrations: %v", err)
	}

	store := &PGStore{db: adminDB}
	pub, _, err := ed25519.GenerateKey(rand.Reader)
	if err != nil {
		t.Fatal(err)
	}
	providerID := "p_fix570a1"
	sourceIP := "203.0.113.7"
	nonce := "aa11bb22cc33"
	observedAt := time.Now().UTC().Truncate(time.Second)
	// FIX-570 C1: attemptTS (signed ts_utc) is the replay-invariant marker key;
	// here it differs from observedAt to prove ProviderRegistrationPrepared keys
	// on attemptTS, not the server-time nonce window.
	attemptTS := observedAt.Add(-30 * time.Second)

	if err := store.PrepareProviderRegistration(ctx, providerID, sourceIP, nonce, observedAt, attemptTS, pub, false, nil); err != nil {
		t.Fatalf("prepare: %v", err)
	}

	// Simulate the replay-nonce pruner running inside the reconcile window.
	if _, err := adminDB.ExecContext(ctx, `DELETE FROM provider_register_nonces`); err != nil {
		t.Fatalf("prune nonces: %v", err)
	}

	prepared, err := store.ProviderRegistrationPrepared(ctx, providerID, nonce, attemptTS)
	if err != nil {
		t.Fatalf("prepared: %v", err)
	}
	if !prepared {
		t.Fatal("committed attempt reported prepared=false after nonce prune (A1 regression)")
	}

	// FIX-570 C1a: an identical signed replay arriving from a DIFFERENT source IP
	// (NAT/proxy churn) must still resolve to the same committed marker. source_ip
	// is non-authoritative metadata and is not part of the match key.
	preparedDifferentIP, err := store.ProviderRegistrationPrepared(ctx, providerID, nonce, attemptTS)
	if err != nil {
		t.Fatalf("prepared(different source ip): %v", err)
	}
	if !preparedDifferentIP {
		t.Fatal("committed attempt reported prepared=false for a signed replay from a different source IP (C1a regression)")
	}

	// The server-time observedAt must NOT match the attempt marker (C1: the marker
	// is keyed on the signed attemptTS, replay-invariant).
	if wrongKey, err := store.ProviderRegistrationPrepared(ctx, providerID, nonce, observedAt); err != nil {
		t.Fatalf("prepared(observedAt): %v", err)
	} else if wrongKey {
		t.Fatal("attempt marker matched server-time observedAt; must key on signed attemptTS")
	}

	// A genuinely un-prepared attempt (no attempt row) must still report false so
	// reconciliation still compensates a true non-commit.
	notPrepared, err := store.ProviderRegistrationPrepared(ctx, "p_never", "ffffffffffff", attemptTS)
	if err != nil {
		t.Fatalf("prepared(missing): %v", err)
	}
	if notPrepared {
		t.Fatal("non-existent attempt reported prepared=true")
	}
}
