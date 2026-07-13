//go:build integration

package onboarding

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
	referralAttemptPGImage = "postgres:16.4-alpine3.20@sha256:5660c2cbfea50c7a9127d17dc4e48543eedd3d7a41a595a2dfa572471e37e64c"
	referralAttemptPGPass  = "referral-attempt-test-password"
)

func TestProviderRegistrationPreparedSurvivesNoncePrune(t *testing.T) {
	ctx, cancel := context.WithTimeout(context.Background(), 90*time.Second)
	defer cancel()
	container, err := tcpg.Run(ctx, referralAttemptPGImage,
		tcpg.WithDatabase("referral_attempt"),
		tcpg.WithUsername("postgres"),
		tcpg.WithPassword(referralAttemptPGPass),
		tc.WithWaitStrategy(wait.ForLog("database system is ready to accept connections").WithOccurrence(2).WithStartupTimeout(60*time.Second)),
	)
	if err != nil {
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
	publicKey, _, err := ed25519.GenerateKey(rand.Reader)
	if err != nil {
		t.Fatal(err)
	}
	observedAt := time.Now().UTC().Truncate(time.Second)
	attemptTS := observedAt.Add(-30 * time.Second)
	if err := store.PrepareProviderRegistration(
		ctx, "provider-a", "203.0.113.7", "nonce-a", observedAt, attemptTS,
		publicKey, false, nil,
	); err != nil {
		t.Fatalf("prepare: %v", err)
	}
	if _, err := db.ExecContext(ctx, `DELETE FROM provider_register_nonces`); err != nil {
		t.Fatalf("prune nonces: %v", err)
	}
	prepared, err := store.ProviderRegistrationPrepared(ctx, "provider-a", "nonce-a", attemptTS)
	if err != nil || !prepared {
		t.Fatalf("prepared=%v err=%v after nonce prune", prepared, err)
	}
	if wrong, err := store.ProviderRegistrationPrepared(ctx, "provider-a", "nonce-a", observedAt); err != nil || wrong {
		t.Fatalf("server observed timestamp matched signed marker: prepared=%v err=%v", wrong, err)
	}
	if missing, err := store.ProviderRegistrationPrepared(ctx, "provider-missing", "nonce-z", attemptTS); err != nil || missing {
		t.Fatalf("missing attempt prepared=%v err=%v", missing, err)
	}
}
