package auth_test

import (
	"bytes"
	"context"
	"crypto/sha256"
	"database/sql"
	"encoding/hex"
	"errors"
	"fmt"
	"net/http"
	"path/filepath"
	"sync"
	"sync/atomic"
	"testing"
	"time"

	"github.com/augstar/macprovider-coordinator/internal/auth"
)

func bootstrapRequest(providerID, sourceIP string, key []byte, now time.Time) auth.BootstrapMintRequest {
	return auth.BootstrapMintRequest{
		ProviderID: bootstrapPrincipal(providerID), ProviderName: providerID + " host", SourceIP: sourceIP,
		ReceiptPubkey: append([]byte(nil), key...), Now: now, TTL: 10 * time.Minute,
		PerIPLimitPerHour: 8, PerProviderPerHour: 3, GlobalLimitPerHour: 128,
		UnconfirmedIDMax: 64, OutstandingTokenMax: 64,
	}
}

func bootstrapPrincipal(label string) string {
	sum := sha256.Sum256([]byte(label))
	return "mp-" + hex.EncodeToString(sum[:16])
}

func TestBootstrapTokenRecoveryRequiresExactUnusedUnexpiredIdentity(t *testing.T) {
	store, err := auth.OpenStore(filepath.Join(t.TempDir(), "coordinator.db"))
	if err != nil {
		t.Fatal(err)
	}
	defer store.Close()
	ctx := context.Background()
	now := time.Now().UTC().Truncate(time.Second)
	key := bytes.Repeat([]byte{0x11}, 32)
	first, err := store.MintBootstrapToken(ctx, bootstrapRequest("bootstrap-owner", "192.0.2.1", key, now))
	if err != nil || first.Replaced || first.ProviderToken == "" {
		t.Fatalf("first mint=%+v err=%v", first, err)
	}

	different := bootstrapRequest("bootstrap-owner", "192.0.2.1", bytes.Repeat([]byte{0x22}, 32), now.Add(time.Second))
	if _, err := store.MintBootstrapToken(ctx, different); !errors.Is(err, auth.ErrBootstrapIdentityMismatch) {
		t.Fatalf("different-key err=%v", err)
	}
	if _, valid, _ := store.ValidateToken(ctx, first.ProviderToken); !valid {
		t.Fatal("different-key attempt mutated the original token")
	}

	recovered, err := store.MintBootstrapToken(ctx, bootstrapRequest("bootstrap-owner", "192.0.2.1", key, now.Add(2*time.Second)))
	if err != nil || !recovered.Replaced || recovered.ProviderToken == first.ProviderToken {
		t.Fatalf("recovered=%+v err=%v", recovered, err)
	}
	if _, valid, _ := store.ValidateToken(ctx, first.ProviderToken); valid {
		t.Fatal("response-loss recovery left the prior token active")
	}
	if err := store.MarkTokenUsed(ctx, recovered.ProviderToken); err != nil {
		t.Fatalf("mark recovered token used: %v", err)
	}
	if _, err := store.MintBootstrapToken(ctx, bootstrapRequest("bootstrap-owner", "192.0.2.1", key, now.Add(3*time.Second))); !errors.Is(err, auth.ErrBootstrapTokenUsed) {
		t.Fatalf("used-token recovery err=%v", err)
	}
}

func TestBootstrapTokenRejectsOrdinaryAndExpiredCredentials(t *testing.T) {
	ctx := context.Background()
	now := time.Date(2026, 7, 10, 16, 0, 0, 0, time.UTC)
	key := bytes.Repeat([]byte{0x33}, 32)

	t.Run("ordinary active token", func(t *testing.T) {
		store, err := auth.OpenStore(filepath.Join(t.TempDir(), "coordinator.db"))
		if err != nil {
			t.Fatal(err)
		}
		defer store.Close()
		providerID := bootstrapPrincipal("ordinary-owner")
		_, token, err := store.IssueToken(ctx, providerID, "ordinary")
		if err != nil {
			t.Fatal(err)
		}
		if _, err := store.MintBootstrapToken(ctx, bootstrapRequest("ordinary-owner", "192.0.2.2", key, now)); !errors.Is(err, auth.ErrBootstrapIdentityMismatch) {
			t.Fatalf("ordinary-token err=%v", err)
		}
		if _, valid, _ := store.ValidateToken(ctx, token); !valid {
			t.Fatal("ordinary token was revoked by bootstrap")
		}
	})

	t.Run("ordinary revoked token", func(t *testing.T) {
		store, err := auth.OpenStore(filepath.Join(t.TempDir(), "coordinator.db"))
		if err != nil {
			t.Fatal(err)
		}
		defer store.Close()
		providerID := bootstrapPrincipal("ordinary-revoked-owner")
		record, _, err := store.IssueToken(ctx, providerID, "ordinary revoked")
		if err != nil {
			t.Fatal(err)
		}
		if _, err := store.RevokeToken(ctx, record.TokenPrefix); err != nil {
			t.Fatal(err)
		}
		if _, err := store.MintBootstrapToken(ctx, bootstrapRequest("ordinary-revoked-owner", "192.0.2.22", key, now)); !errors.Is(err, auth.ErrBootstrapIdentityMismatch) {
			t.Fatalf("revoked ordinary token converted to bootstrap identity: err=%v", err)
		}
	})

	t.Run("expired bootstrap token", func(t *testing.T) {
		store, err := auth.OpenStore(filepath.Join(t.TempDir(), "coordinator.db"))
		if err != nil {
			t.Fatal(err)
		}
		defer store.Close()
		req := bootstrapRequest("expired-owner", "192.0.2.3", key, now)
		req.TTL = time.Minute
		mint, err := store.MintBootstrapToken(ctx, req)
		if err != nil {
			t.Fatal(err)
		}
		different := bootstrapRequest("expired-owner", "192.0.2.3", bytes.Repeat([]byte{0x34}, 32), now.Add(2*time.Minute))
		if _, err := store.MintBootstrapToken(ctx, different); !errors.Is(err, auth.ErrBootstrapIdentityMismatch) {
			t.Fatalf("different key reclaimed expired bootstrap identity: err=%v", err)
		}
		retry := bootstrapRequest("expired-owner", "192.0.2.3", key, now.Add(2*time.Minute))
		replacement, err := store.MintBootstrapToken(ctx, retry)
		if err != nil || !replacement.Replaced || replacement.ProviderToken == "" {
			t.Fatalf("expired same-key principal was not recovered: mint=%+v err=%v", replacement, err)
		}
		if _, valid, _ := store.ValidateToken(ctx, mint.ProviderToken); valid {
			t.Fatal("expired bootstrap token remained active")
		}
	})

	t.Run("operator revoked bootstrap token", func(t *testing.T) {
		store, err := auth.OpenStore(filepath.Join(t.TempDir(), "coordinator.db"))
		if err != nil {
			t.Fatal(err)
		}
		defer store.Close()
		req := bootstrapRequest("operator-revoked-bootstrap", "192.0.2.23", key, now)
		mint, err := store.MintBootstrapToken(ctx, req)
		if err != nil {
			t.Fatal(err)
		}
		if _, err := store.RevokeToken(ctx, mint.TokenRecord.TokenPrefix); err != nil {
			t.Fatal(err)
		}
		if _, err := store.MintBootstrapToken(ctx, bootstrapRequest("operator-revoked-bootstrap", "192.0.2.23", key, now.Add(time.Second))); !errors.Is(err, auth.ErrBootstrapTokenUsed) {
			t.Fatalf("operator-revoked bootstrap token recovered: err=%v", err)
		}
	})
}

func TestBootstrapTokenDurableRateAndOutstandingLimits(t *testing.T) {
	store, err := auth.OpenStore(filepath.Join(t.TempDir(), "coordinator.db"))
	if err != nil {
		t.Fatal(err)
	}
	defer store.Close()
	ctx := context.Background()
	now := time.Date(2026, 7, 10, 16, 0, 0, 0, time.UTC)

	firstReq := bootstrapRequest("quota-one", "192.0.2.10", bytes.Repeat([]byte{0x41}, 32), now)
	firstReq.PerIPLimitPerHour = 1
	firstReq.PerProviderPerHour = 1
	firstReq.OutstandingTokenMax = 1
	if _, err := store.MintBootstrapToken(ctx, firstReq); err != nil {
		t.Fatal(err)
	}
	if _, err := store.MintBootstrapToken(ctx, firstReq); !errors.Is(err, auth.ErrBootstrapRateLimited) {
		t.Fatalf("provider durable quota err=%v", err)
	}

	ipReq := bootstrapRequest("quota-two", "192.0.2.10", bytes.Repeat([]byte{0x42}, 32), now.Add(time.Second))
	ipReq.PerIPLimitPerHour = 1
	if _, err := store.MintBootstrapToken(ctx, ipReq); !errors.Is(err, auth.ErrBootstrapRateLimited) {
		t.Fatalf("ip durable quota err=%v", err)
	}

	globalReq := bootstrapRequest("quota-three", "192.0.2.11", bytes.Repeat([]byte{0x43}, 32), now.Add(time.Second))
	globalReq.OutstandingTokenMax = 1
	if _, err := store.MintBootstrapToken(ctx, globalReq); !errors.Is(err, auth.ErrBootstrapOutstandingLimit) {
		t.Fatalf("outstanding cap err=%v", err)
	}

	pruneReq := bootstrapRequest("quota-pruned", "192.0.2.12", bytes.Repeat([]byte{0x44}, 32), now.Add(11*time.Minute))
	pruneReq.OutstandingTokenMax = 1
	if _, err := store.MintBootstrapToken(ctx, pruneReq); err != nil {
		t.Fatalf("expired outstanding token was not pruned: %v", err)
	}
}

func TestBootstrapTokenGlobalBudgetAndUnconfirmedIdentityBound(t *testing.T) {
	ctx := context.Background()
	now := time.Date(2026, 7, 10, 16, 0, 0, 0, time.UTC)

	t.Run("rotating ip and id still hits durable global budget", func(t *testing.T) {
		store, err := auth.OpenStore(filepath.Join(t.TempDir(), "coordinator.db"))
		if err != nil {
			t.Fatal(err)
		}
		defer store.Close()
		for i := 0; i < 2; i++ {
			req := bootstrapRequest(fmt.Sprintf("global-%d", i), fmt.Sprintf("192.0.2.%d", 20+i), bytes.Repeat([]byte{byte(0x50 + i)}, 32), now.Add(time.Duration(i)*time.Second))
			req.GlobalLimitPerHour = 2
			if _, err := store.MintBootstrapToken(ctx, req); err != nil {
				t.Fatalf("mint %d: %v", i, err)
			}
		}
		req := bootstrapRequest("global-2", "198.51.100.99", bytes.Repeat([]byte{0x52}, 32), now.Add(2*time.Second))
		req.GlobalLimitPerHour = 2
		if _, err := store.MintBootstrapToken(ctx, req); !errors.Is(err, auth.ErrBootstrapRateLimited) {
			t.Fatalf("rotating global budget err=%v", err)
		}
	})

	t.Run("unconfirmed identity count is explicitly bounded", func(t *testing.T) {
		store, err := auth.OpenStore(filepath.Join(t.TempDir(), "coordinator.db"))
		if err != nil {
			t.Fatal(err)
		}
		defer store.Close()
		first := bootstrapRequest("identity-0", "192.0.2.30", bytes.Repeat([]byte{0x60}, 32), now)
		first.UnconfirmedIDMax = 1
		if _, err := store.MintBootstrapToken(ctx, first); err != nil {
			t.Fatal(err)
		}
		second := bootstrapRequest("identity-1", "192.0.2.31", bytes.Repeat([]byte{0x61}, 32), now.Add(time.Second))
		second.UnconfirmedIDMax = 1
		if _, err := store.MintBootstrapToken(ctx, second); !errors.Is(err, auth.ErrBootstrapOutstandingLimit) {
			t.Fatalf("unconfirmed identity cap err=%v", err)
		}
	})
}

func TestBootstrapGCIsBoundedAuditableAndPreservesConfirmedOwnership(t *testing.T) {
	ctx := context.Background()
	dbPath := filepath.Join(t.TempDir(), "coordinator.db")
	store, err := auth.OpenStore(dbPath)
	if err != nil {
		t.Fatal(err)
	}
	defer store.Close()
	now := time.Now().UTC().Truncate(time.Second)

	expired := bootstrapRequest("gc-expired", "192.0.2.50", bytes.Repeat([]byte{0x80}, 32), now.Add(-2*time.Hour))
	expired.TTL = time.Minute
	if _, err := store.MintBootstrapToken(ctx, expired); err != nil {
		t.Fatal(err)
	}
	confirmed := bootstrapRequest("gc-confirmed", "192.0.2.51", bytes.Repeat([]byte{0x81}, 32), now)
	mint, err := store.MintBootstrapToken(ctx, confirmed)
	if err != nil {
		t.Fatal(err)
	}
	if _, valid, err := store.ValidateAndMarkTokenUsed(ctx, mint.ProviderToken); err != nil || !valid {
		t.Fatalf("validate bootstrap identity valid=%v err=%v", valid, err)
	}
	if err := store.MarkTokenUsed(ctx, mint.ProviderToken); err != nil {
		t.Fatalf("confirm bootstrap identity: %v", err)
	}

	trigger := bootstrapRequest("gc-trigger", "198.51.100.50", bytes.Repeat([]byte{0x82}, 32), now.Add(2*time.Hour))
	if _, err := store.MintBootstrapToken(ctx, trigger); err != nil {
		t.Fatal(err)
	}

	db, err := sql.Open("sqlite", dbPath)
	if err != nil {
		t.Fatal(err)
	}
	defer db.Close()
	var auditRows, removedIdentities, removedTokens, removedLogs int
	if err := db.QueryRowContext(ctx, `
SELECT COUNT(1), total_removed_identities, total_removed_tokens, total_removed_logs
  FROM bootstrap_gc_audit`).Scan(&auditRows, &removedIdentities, &removedTokens, &removedLogs); err != nil {
		t.Fatal(err)
	}
	if auditRows != 1 || removedIdentities != 0 || removedTokens < 1 || removedLogs < 2 {
		t.Fatalf("gc audit rows=%d identities=%d tokens=%d logs=%d", auditRows, removedIdentities, removedTokens, removedLogs)
	}
	var expiredKey []byte
	if err := db.QueryRowContext(ctx, `
SELECT receipt_pubkey FROM provider_bootstrap_identities WHERE provider_id = ?`, expired.ProviderID).Scan(&expiredKey); err != nil {
		t.Fatalf("expired custody binding was collected: %v", err)
	}
	if !bytes.Equal(expiredKey, expired.ReceiptPubkey) {
		t.Fatalf("expired custody key changed: got=%x want=%x", expiredKey, expired.ReceiptPubkey)
	}
	var confirmedAt sql.NullString
	if err := db.QueryRowContext(ctx, `
SELECT confirmed_at FROM provider_bootstrap_identities WHERE provider_id = ?`, confirmed.ProviderID).Scan(&confirmedAt); err != nil {
		t.Fatalf("confirmed identity was collected: %v", err)
	}
	if !confirmedAt.Valid {
		t.Fatal("first bearer use did not durably confirm ownership")
	}
}

func TestBootstrapExpiredFirstUseRevokesButConfirmedTokenSurvivesTTL(t *testing.T) {
	ctx := context.Background()
	now := time.Now().UTC()

	t.Run("expired first use", func(t *testing.T) {
		store, err := auth.OpenStore(filepath.Join(t.TempDir(), "coordinator.db"))
		if err != nil {
			t.Fatal(err)
		}
		defer store.Close()
		req := bootstrapRequest("ttl-first-use", "192.0.2.40", bytes.Repeat([]byte{0x70}, 32), now.Add(-2*time.Hour))
		req.TTL = time.Minute
		mint, err := store.MintBootstrapToken(ctx, req)
		if err != nil {
			t.Fatal(err)
		}
		if providerID, valid, err := store.ValidateAndMarkTokenUsed(ctx, mint.ProviderToken); err != nil || valid || providerID != "" {
			t.Fatalf("expired first use provider=%q valid=%v err=%v", providerID, valid, err)
		}
		if _, valid, err := store.ValidateToken(ctx, mint.ProviderToken); err != nil || valid {
			t.Fatalf("expired first-use token remained active: valid=%v err=%v", valid, err)
		}
	})

	t.Run("confirmed token is ordinary after bootstrap ttl", func(t *testing.T) {
		dbPath := filepath.Join(t.TempDir(), "coordinator.db")
		store, err := auth.OpenStore(dbPath)
		if err != nil {
			t.Fatal(err)
		}
		defer store.Close()
		req := bootstrapRequest("ttl-confirmed", "192.0.2.41", bytes.Repeat([]byte{0x71}, 32), now)
		mint, err := store.MintBootstrapToken(ctx, req)
		if err != nil {
			t.Fatal(err)
		}
		if _, valid, err := store.ValidateAndMarkTokenUsed(ctx, mint.ProviderToken); err != nil || !valid {
			t.Fatalf("pre-admission validation valid=%v err=%v", valid, err)
		}
		if err := store.MarkTokenUsed(ctx, mint.ProviderToken); err != nil {
			t.Fatalf("accepted admission confirmation: %v", err)
		}
		db, err := sql.Open("sqlite", dbPath)
		if err != nil {
			t.Fatal(err)
		}
		defer db.Close()
		if _, err := db.ExecContext(ctx, `UPDATE provider_tokens SET bootstrap_expires_at = ? WHERE id = ?`, timeTextForTest(now.Add(-time.Hour)), mint.TokenRecord.ID); err != nil {
			t.Fatal(err)
		}
		if providerID, valid, err := store.ValidateAndMarkTokenUsed(ctx, mint.ProviderToken); err != nil || !valid || providerID != req.ProviderID {
			t.Fatalf("confirmed post-ttl provider=%q valid=%v err=%v", providerID, valid, err)
		}
	})
}

func TestValidateTokenRevokesExpiredProvisionalWithoutConfirmingIt(t *testing.T) {
	ctx := context.Background()
	dbPath := filepath.Join(t.TempDir(), "coordinator.db")
	store, err := auth.OpenStore(dbPath)
	if err != nil {
		t.Fatal(err)
	}
	defer store.Close()
	req := bootstrapRequest("readonly-expired", "192.0.2.42", bytes.Repeat([]byte{0x72}, 32), time.Now().UTC().Add(-2*time.Hour))
	req.TTL = time.Minute
	mint, err := store.MintBootstrapToken(ctx, req)
	if err != nil {
		t.Fatal(err)
	}

	if providerID, valid, err := store.ValidateToken(ctx, mint.ProviderToken); err != nil || valid || providerID != "" {
		t.Fatalf("read-only expired validation provider=%q valid=%v err=%v", providerID, valid, err)
	}

	db, err := sql.Open("sqlite", dbPath)
	if err != nil {
		t.Fatal(err)
	}
	defer db.Close()
	var revokedAt, lastUsedAt, confirmedAt sql.NullString
	if err := db.QueryRowContext(ctx, `
SELECT t.revoked_at, t.last_used_at, i.confirmed_at
  FROM provider_tokens t
  JOIN provider_bootstrap_identities i ON i.provider_id = t.provider_id
 WHERE t.id = ?`, mint.TokenRecord.ID).Scan(&revokedAt, &lastUsedAt, &confirmedAt); err != nil {
		t.Fatal(err)
	}
	if !revokedAt.Valid || lastUsedAt.Valid || confirmedAt.Valid {
		t.Fatalf("expired read-only validation state revoked=%v last_used=%v confirmed=%v", revokedAt, lastUsedAt, confirmedAt)
	}
}

func TestLookupBootstrapIdentityPubkeyUsesDurableActiveOrConfirmedBinding(t *testing.T) {
	ctx := context.Background()
	dbPath := filepath.Join(t.TempDir(), "coordinator.db")
	store, err := auth.OpenStore(dbPath)
	if err != nil {
		t.Fatal(err)
	}
	defer store.Close()
	key := bytes.Repeat([]byte{0x73}, 32)
	req := bootstrapRequest("identity-lookup", "192.0.2.43", key, time.Now().UTC())
	mint, err := store.MintBootstrapToken(ctx, req)
	if err != nil {
		t.Fatal(err)
	}

	pubkey, ok, err := store.LookupBootstrapIdentityPubkey(ctx, req.ProviderID)
	if err != nil || !ok || !bytes.Equal(pubkey, key) {
		t.Fatalf("active provisional lookup ok=%v pubkey=%x err=%v", ok, pubkey, err)
	}
	if err := store.MarkTokenUsed(ctx, mint.ProviderToken); err != nil {
		t.Fatalf("confirm bootstrap token: %v", err)
	}
	db, err := sql.Open("sqlite", dbPath)
	if err != nil {
		t.Fatal(err)
	}
	defer db.Close()
	if _, err := db.ExecContext(ctx, `
UPDATE provider_bootstrap_identities SET expires_at = ? WHERE provider_id = ?`, timeTextForTest(time.Now().UTC().Add(-time.Hour)), req.ProviderID); err != nil {
		t.Fatal(err)
	}
	pubkey, ok, err = store.LookupBootstrapIdentityPubkey(ctx, req.ProviderID)
	if err != nil || !ok || !bytes.Equal(pubkey, key) {
		t.Fatalf("confirmed durable lookup ok=%v pubkey=%x err=%v", ok, pubkey, err)
	}
}

func TestBootstrapIdentityExistenceDistinguishesAbsentActiveAndInactive(t *testing.T) {
	ctx := context.Background()
	store, err := auth.OpenStore(filepath.Join(t.TempDir(), "coordinator.db"))
	if err != nil {
		t.Fatal(err)
	}
	defer store.Close()
	providerID := bootstrapPrincipal("identity-states")

	if exists, err := store.BootstrapIdentityExists(ctx, providerID); err != nil || exists {
		t.Fatalf("absent identity exists=%v err=%v", exists, err)
	}
	req := bootstrapRequest("identity-states", "192.0.2.44", bytes.Repeat([]byte{0x74}, 32), time.Now().UTC())
	mint, err := store.MintBootstrapToken(ctx, req)
	if err != nil {
		t.Fatal(err)
	}
	if _, active, err := store.LookupBootstrapIdentityPubkey(ctx, providerID); err != nil || !active {
		t.Fatalf("active identity active=%v err=%v", active, err)
	}
	if exists, err := store.BootstrapIdentityExists(ctx, providerID); err != nil || !exists {
		t.Fatalf("active identity exists=%v err=%v", exists, err)
	}
	if _, err := store.RevokeToken(ctx, mint.TokenRecord.TokenPrefix); err != nil {
		t.Fatalf("revoke provisional token: %v", err)
	}
	if _, active, err := store.LookupBootstrapIdentityPubkey(ctx, providerID); err != nil || active {
		t.Fatalf("inactive identity active=%v err=%v", active, err)
	}
	if exists, err := store.BootstrapIdentityExists(ctx, providerID); err != nil || !exists {
		t.Fatalf("inactive identity exists=%v err=%v", exists, err)
	}
}

func TestBootstrapValidationDoesNotConsumeRejectedSessionAndGCReclaimsIt(t *testing.T) {
	ctx := context.Background()
	dbPath := filepath.Join(t.TempDir(), "coordinator.db")
	store, err := auth.OpenStore(dbPath)
	if err != nil {
		t.Fatal(err)
	}
	defer store.Close()
	now := time.Now().UTC().Truncate(time.Second)
	req := bootstrapRequest("rejected-session", "192.0.2.70", bytes.Repeat([]byte{0x91}, 32), now)
	req.TTL = time.Minute
	mint, err := store.MintBootstrapToken(ctx, req)
	if err != nil {
		t.Fatal(err)
	}
	if providerID, valid, err := store.ValidateAndMarkTokenUsed(ctx, mint.ProviderToken); err != nil || !valid || providerID != req.ProviderID {
		t.Fatalf("provisional validation provider=%q valid=%v err=%v", providerID, valid, err)
	}

	db, err := sql.Open("sqlite", dbPath)
	if err != nil {
		t.Fatal(err)
	}
	defer db.Close()
	var lastUsed, confirmedAt sql.NullString
	if err := db.QueryRowContext(ctx, `
SELECT t.last_used_at, i.confirmed_at
  FROM provider_tokens t
  JOIN provider_bootstrap_identities i ON i.provider_id = t.provider_id
 WHERE t.id = ?`, mint.TokenRecord.ID).Scan(&lastUsed, &confirmedAt); err != nil {
		t.Fatal(err)
	}
	if lastUsed.Valid || confirmedAt.Valid {
		t.Fatalf("rejected-session validation consumed bootstrap row: last_used=%v confirmed=%v", lastUsed, confirmedAt)
	}

	trigger := bootstrapRequest("rejected-session-gc-trigger", "192.0.2.71", bytes.Repeat([]byte{0x92}, 32), now.Add(2*time.Minute))
	if _, err := store.MintBootstrapToken(ctx, trigger); err != nil {
		t.Fatalf("trigger bounded GC: %v", err)
	}
	var tokenCount, identityCount int
	if err := db.QueryRowContext(ctx, `SELECT COUNT(1) FROM provider_tokens WHERE id = ?`, mint.TokenRecord.ID).Scan(&tokenCount); err != nil {
		t.Fatal(err)
	}
	if err := db.QueryRowContext(ctx, `SELECT COUNT(1) FROM provider_bootstrap_identities WHERE provider_id = ?`, req.ProviderID).Scan(&identityCount); err != nil {
		t.Fatal(err)
	}
	if tokenCount != 0 || identityCount != 1 {
		t.Fatalf("expired rejected-session token was not reclaimed with custody retained: tokens=%d identities=%d", tokenCount, identityCount)
	}
}

func timeTextForTest(value time.Time) string {
	return value.UTC().Format("2006-01-02T15:04:05Z")
}

func TestBearerTokenMatchesHeader(t *testing.T) {
	headers := http.Header{}
	headers.Set("Authorization", "Bearer operator-secret")
	if !auth.BearerTokenMatchesHeader(headers, "operator-secret") {
		t.Fatal("valid bearer token rejected")
	}
	headers.Set("Authorization", "Bearer wrong-secret")
	if auth.BearerTokenMatchesHeader(headers, "operator-secret") {
		t.Fatal("invalid bearer token accepted")
	}
	headers.Set("Authorization", "Basic operator-secret")
	if auth.BearerTokenMatchesHeader(headers, "operator-secret") {
		t.Fatal("non-bearer authorization accepted")
	}
	if auth.BearerTokenMatchesHeader(headers, "") {
		t.Fatal("empty expected token accepted")
	}
}

// TestOperatorOnlyBearerMatches pins the codex PR #73 HIGH-1 fix at the
// helper level: admin endpoints accept the operator key and ONLY the
// operator key. Empty operator key denies (M1-5 / SECU-5).
func TestOperatorOnlyBearerMatches(t *testing.T) {
	headers := http.Header{}
	headers.Set("Authorization", "Bearer operator-secret")
	if !auth.OperatorOnlyBearerMatches(headers, "operator-secret") {
		t.Fatal("operator key not accepted")
	}
	if auth.OperatorOnlyBearerMatches(headers, "") {
		t.Fatal("empty operator key accepted (M1-5 regression)")
	}
	// service token is structurally identical but must not be accepted
	// by this helper; the gateway-internal class lives elsewhere.
	headers.Set("Authorization", "Bearer service-secret")
	if auth.OperatorOnlyBearerMatches(headers, "operator-secret") {
		t.Fatal("service_token-shaped bearer matched operator-only helper")
	}
}

// TestGatewayInternalBearerMatchesScoping pins the codex PR #73 HIGH-1
// fix at the helper level for the gateway-internal class: BOTH the
// operator key and the gateway service token are accepted. The kind
// return identifies which one matched so the call-site can audit-log
// correctly.
func TestGatewayInternalBearerMatchesScoping(t *testing.T) {
	cases := []struct {
		name     string
		bearer   string
		want     auth.InternalBearerKind
		wantName string
	}{
		{name: "service_token preferred", bearer: "service-secret", want: auth.BearerKindServiceToken, wantName: "service_token"},
		{name: "operator_key fallback", bearer: "operator-secret", want: auth.BearerKindOperatorKey, wantName: "operator_key"},
		{name: "no match", bearer: "wrong", want: auth.BearerKindNone, wantName: ""},
	}
	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			headers := http.Header{}
			headers.Set("Authorization", "Bearer "+tc.bearer)
			got := auth.GatewayInternalBearerMatches(headers, "operator-secret", "service-secret")
			if got != tc.want {
				t.Fatalf("kind=%v want=%v", got, tc.want)
			}
			if got.String() != tc.wantName {
				t.Fatalf("name=%q want=%q", got.String(), tc.wantName)
			}
		})
	}
}

// TestGatewayInternalBearerMatchesEmptyConfigs ensures that an empty
// gateway_service_token cannot widen the auth surface (matches the
// invariant in M3-2 / SECU-4), and that an empty operator_key denies
// even when the request's bearer is also empty.
func TestGatewayInternalBearerMatchesEmptyConfigs(t *testing.T) {
	headers := http.Header{}
	headers.Set("Authorization", "Bearer operator-secret")

	// Empty service_token, valid operator_key → accept under operator.
	if got := auth.GatewayInternalBearerMatches(headers, "operator-secret", ""); got != auth.BearerKindOperatorKey {
		t.Fatalf("empty service_token broke operator fallback: %v", got)
	}
	// Empty operator_key, valid service_token → accept under service.
	headers.Set("Authorization", "Bearer service-secret")
	if got := auth.GatewayInternalBearerMatches(headers, "", "service-secret"); got != auth.BearerKindServiceToken {
		t.Fatalf("empty operator_key broke service accept: %v", got)
	}
	// Both empty → always deny, even when the request also has empty bearer.
	empty := http.Header{}
	if got := auth.GatewayInternalBearerMatches(empty, "", ""); got != auth.BearerKindNone {
		t.Fatalf("both empty configs admitted: %v", got)
	}
}

// TestGatewayInternalBearerMatchesEvaluatesBoth asserts the MEDIUM
// timing-oracle fix from codex PR #73: the helper must evaluate BOTH
// credentials before branching. We can't directly observe the branch
// at this level, but we can pin the public contract that no short-
// circuit is exposed by checking the helper succeeds when EITHER
// credential is correct and only the OTHER is configured. (A naive
// implementation that broke on empty would fail one of these.)
func TestGatewayInternalBearerMatchesEvaluatesBoth(t *testing.T) {
	headers := http.Header{}
	// service_token matches; operator_key is non-empty but unmatched.
	headers.Set("Authorization", "Bearer svc")
	if got := auth.GatewayInternalBearerMatches(headers, "op", "svc"); got != auth.BearerKindServiceToken {
		t.Fatalf("svc match: %v", got)
	}
	// operator_key matches; service_token is non-empty but unmatched.
	headers.Set("Authorization", "Bearer op")
	if got := auth.GatewayInternalBearerMatches(headers, "op", "svc"); got != auth.BearerKindOperatorKey {
		t.Fatalf("op match: %v", got)
	}
	// Neither matches.
	headers.Set("Authorization", "Bearer nope")
	if got := auth.GatewayInternalBearerMatches(headers, "op", "svc"); got != auth.BearerKindNone {
		t.Fatalf("nope: %v", got)
	}
}

func TestCreateOAuthStateBoundRateLimitIsConcurrentSafe(t *testing.T) {
	store, err := auth.OpenStore(filepath.Join(t.TempDir(), "coordinator.db"))
	if err != nil {
		t.Fatalf("open store: %v", err)
	}
	t.Cleanup(func() { _ = store.Close() })
	now := time.Date(2026, 7, 4, 12, 0, 0, 0, time.UTC)
	const attempts = 50
	var wg sync.WaitGroup
	errs := make(chan error, attempts)
	for i := 0; i < attempts; i++ {
		wg.Add(1)
		go func(i int) {
			defer wg.Done()
			errs <- store.CreateOAuthStateBound(context.Background(), "state-"+string(rune('a'+i)), "/", nil, "origin", now)
		}(i)
	}
	wg.Wait()
	close(errs)

	var created, limited int
	for err := range errs {
		switch {
		case err == nil:
			created++
		case errors.Is(err, auth.ErrOAuthStateRateLimited):
			limited++
		default:
			t.Fatalf("unexpected error: %v", err)
		}
	}
	if created != 20 || limited != attempts-20 {
		t.Fatalf("created=%d limited=%d, want 20/%d", created, limited, attempts-20)
	}
}

func TestTokenIssueValidateRevokeAndList(t *testing.T) {
	store, err := auth.OpenStore(filepath.Join(t.TempDir(), "coordinator.db"))
	if err != nil {
		t.Fatalf("open store: %v", err)
	}
	defer store.Close()
	ctx := context.Background()

	record, token, err := store.IssueToken(ctx, "m4-anon", "M4 Provider")
	if err != nil {
		t.Fatalf("issue token: %v", err)
	}
	if len(token) != 64 {
		t.Fatalf("token len = %d, want 64", len(token))
	}
	if record.TokenPrefix != token[:12] {
		t.Fatalf("prefix = %q, want %q", record.TokenPrefix, token[:12])
	}
	if record.ProviderID != "m4-anon" {
		t.Fatalf("provider_id = %q, want m4-anon", record.ProviderID)
	}

	providerID, ok, err := store.ValidateToken(ctx, token)
	if err != nil || !ok || providerID != "m4-anon" {
		t.Fatalf("validate issued token provider_id=%q ok=%v err=%v", providerID, ok, err)
	}
	records, err := store.ListTokens(ctx)
	if err != nil {
		t.Fatalf("list tokens before use: %v", err)
	}
	if len(records) != 1 || records[0].LastUsedAt.Valid {
		t.Fatalf("records before mark used = %#v", records)
	}
	if err := store.MarkTokenUsed(ctx, token); err != nil {
		t.Fatalf("mark token used: %v", err)
	}
	providerID, ok, err = store.ValidateToken(ctx, "bad-token")
	if err != nil || ok {
		t.Fatalf("validate bad token provider_id=%q ok=%v err=%v", providerID, ok, err)
	}

	revoked, err := store.RevokeToken(ctx, record.TokenPrefix)
	if err != nil {
		t.Fatalf("revoke token: %v", err)
	}
	if !revoked.RevokedAt.Valid {
		t.Fatal("revoked_at not set")
	}
	providerID, ok, err = store.ValidateToken(ctx, token)
	if err != nil || ok {
		t.Fatalf("validate revoked token provider_id=%q ok=%v err=%v", providerID, ok, err)
	}

	records, err = store.ListTokens(ctx)
	if err != nil {
		t.Fatalf("list tokens: %v", err)
	}
	if len(records) != 1 || records[0].TokenPrefix != record.TokenPrefix || records[0].ProviderID != "m4-anon" || !records[0].LastUsedAt.Valid {
		t.Fatalf("records = %#v", records)
	}
}

func TestMintProviderTokenAppTrackRequiresProofForAnyActiveToken(t *testing.T) {
	store, err := auth.OpenStore(filepath.Join(t.TempDir(), "coordinator.db"))
	if err != nil {
		t.Fatalf("open store: %v", err)
	}
	defer store.Close()
	ctx := context.Background()
	const providerID = "p_apptrackprovider"

	first, err := store.MintProviderTokenAppTrack(ctx, providerID, nil)
	if err != nil {
		t.Fatalf("first app-track mint: %v", err)
	}
	if len(first) != 64 {
		t.Fatalf("first token len=%d want 64", len(first))
	}

	if _, err := store.MintProviderTokenAppTrack(ctx, providerID, nil); !errors.Is(err, auth.ErrAppTrackExistingTokenNoProof) {
		t.Fatalf("unused active without proof err=%v want ErrAppTrackExistingTokenNoProof", err)
	}
	if provider, ok, err := store.ValidateToken(ctx, first); err != nil || !ok || provider != providerID {
		t.Fatalf("first token should remain active provider=%q ok=%v err=%v", provider, ok, err)
	}
	wrong := "wrong-token"
	if _, err := store.MintProviderTokenAppTrack(ctx, providerID, &wrong); !errors.Is(err, auth.ErrAppTrackExistingTokenNoProof) {
		t.Fatalf("active token with wrong proof err=%v want ErrAppTrackExistingTokenNoProof", err)
	}

	second, err := store.MintProviderTokenAppTrack(ctx, providerID, &first)
	if err != nil {
		t.Fatalf("active token with current proof should reissue: %v", err)
	}
	if second == first {
		t.Fatal("proof reissue returned same token")
	}
	if err := store.MarkTokenUsed(ctx, second); err != nil {
		t.Fatalf("mark second used: %v", err)
	}
	if _, err := store.MintProviderTokenAppTrack(ctx, providerID, &second); !errors.Is(err, auth.ErrAppTrackReissueCooldown) {
		t.Fatalf("cooldown reissue err=%v want ErrAppTrackReissueCooldown", err)
	}
}

func TestRevokeTokenRejectsAmbiguousPrefix(t *testing.T) {
	dbPath := filepath.Join(t.TempDir(), "coordinator.db")
	store, err := auth.OpenStore(dbPath)
	if err != nil {
		t.Fatalf("open store: %v", err)
	}
	defer store.Close()
	ctx := context.Background()

	db, err := sql.Open("sqlite", dbPath)
	if err != nil {
		t.Fatalf("open sqlite fixture handle: %v", err)
	}
	defer db.Close()
	for _, row := range []struct {
		hash       string
		providerID string
		name       string
	}{
		{hash: "hash-a", providerID: "m4-a", name: "M4 A"},
		{hash: "hash-b", providerID: "m4-b", name: "M4 B"},
	} {
		if _, err := db.ExecContext(ctx, `INSERT INTO provider_tokens (token_hash, token_prefix, provider_id, provider_name, created_at) VALUES (?, ?, ?, ?, ?)`, row.hash, "abcdef123456", row.providerID, row.name, "2026-06-07T00:00:00Z"); err != nil {
			t.Fatalf("insert fixture token %s: %v", row.providerID, err)
		}
	}

	_, err = store.RevokeToken(ctx, "abcdef")
	if err == nil {
		t.Fatal("ambiguous prefix unexpectedly revoked token")
	}
	records, err := store.ListTokens(ctx)
	if err != nil {
		t.Fatalf("list tokens: %v", err)
	}
	for _, record := range records {
		if record.RevokedAt.Valid {
			t.Fatalf("record %d revoked despite ambiguous prefix: %#v", record.ID, record)
		}
	}
}

// SPEC-003 v0.8.2 FR-C9.4 — the partial unique index installed by
// ensureActiveProviderIDUniqueness MUST prevent two unrevoked tokens
// from existing simultaneously for the same provider_id. The codex
// security re-audit MAJOR-1 finding on PR #44 showed that the prior
// `SELECT COUNT` + later `INSERT` sequence had a TOCTOU window: two
// concurrent tokenless connects could both pass the gate before either
// committed. This test races N concurrent IssueToken calls for the same
// provider_id and asserts that EXACTLY ONE succeeds; the rest must
// receive ErrActiveTokenAlreadyExists (mapped to TOFU close on the wire
// by ws/server.go resolveProvisionalToken).
func TestIssueTokenRefusesConcurrentDuplicateForSameProviderID(t *testing.T) {
	store, err := auth.OpenStore(filepath.Join(t.TempDir(), "coordinator.db"))
	if err != nil {
		t.Fatalf("open store: %v", err)
	}
	defer store.Close()
	ctx := context.Background()

	const racers = 16
	var (
		wg            sync.WaitGroup
		startGate     = make(chan struct{})
		successes     int32
		dupRejections int32
		otherErrors   atomic.Value
	)
	for i := 0; i < racers; i++ {
		wg.Add(1)
		go func() {
			defer wg.Done()
			<-startGate
			_, _, err := store.IssueToken(ctx, "race-target", "racer hostname")
			switch {
			case err == nil:
				atomic.AddInt32(&successes, 1)
			case errors.Is(err, auth.ErrActiveTokenAlreadyExists):
				atomic.AddInt32(&dupRejections, 1)
			default:
				otherErrors.Store(err)
			}
		}()
	}
	close(startGate)
	wg.Wait()

	if other := otherErrors.Load(); other != nil {
		t.Fatalf("unexpected non-TOFU error during concurrent IssueToken: %v", other)
	}
	if successes != 1 {
		t.Fatalf("got %d successes, want exactly 1 (the TOCTOU gate must elect a single winner)", successes)
	}
	if dupRejections != racers-1 {
		t.Fatalf("got %d ErrActiveTokenAlreadyExists rejections, want %d (one per loser)", dupRejections, racers-1)
	}

	// And the DB must reflect exactly one unrevoked row for race-target.
	records, err := store.ListTokens(ctx)
	if err != nil {
		t.Fatalf("list tokens: %v", err)
	}
	active := 0
	for _, r := range records {
		if r.ProviderID == "race-target" && !r.RevokedAt.Valid {
			active++
		}
	}
	if active != 1 {
		t.Fatalf("active rows for race-target = %d, want 1: %#v", active, records)
	}
}

// SPEC-003 v0.8.2 FR-C9.4 — the partial unique index migration step
// MUST collapse pre-existing duplicate active rows down to one (keeping
// the most recently created) so that the unique index can be created
// without aborting on legacy data from the v0.8 pre-TOFU era. This test
// seeds two unrevoked rows for the same provider_id BEFORE the unique
// index exists, then opens a fresh Store on the same DB and verifies
// the migration revoked the older duplicate.
func TestIssueTokenMigrationRevokesPreexistingDuplicates(t *testing.T) {
	dbPath := filepath.Join(t.TempDir(), "coordinator.db")
	// Phase 1: open store, but bypass the unique constraint by writing
	// two raw rows BEFORE we let the migration install the index.
	rawDB, err := sql.Open("sqlite", dbPath)
	if err != nil {
		t.Fatalf("open raw db: %v", err)
	}
	if _, err := rawDB.ExecContext(context.Background(), `
CREATE TABLE provider_tokens (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    token_hash TEXT NOT NULL UNIQUE,
    token_prefix TEXT NOT NULL,
    provider_id TEXT NOT NULL DEFAULT '',
    provider_name TEXT NOT NULL,
    created_at TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%SZ', 'now')),
    revoked_at TEXT DEFAULT NULL,
    last_used_at TEXT DEFAULT NULL
);
`); err != nil {
		t.Fatalf("seed schema: %v", err)
	}
	for _, h := range []string{"legacy-hash-1", "legacy-hash-2"} {
		if _, err := rawDB.ExecContext(context.Background(), `INSERT INTO provider_tokens (token_hash, token_prefix, provider_id, provider_name, created_at) VALUES (?, ?, ?, ?, ?)`, h, h[:12], "legacy-dup", "legacy provider", "2026-06-01T00:00:00Z"); err != nil {
			t.Fatalf("seed dup row %s: %v", h, err)
		}
	}
	_ = rawDB.Close()

	// Phase 2: open through auth.OpenStore. Its migrate() must collapse
	// the duplicates and install the index without erroring out.
	store, err := auth.OpenStore(dbPath)
	if err != nil {
		t.Fatalf("open store post-seed: %v", err)
	}
	defer store.Close()

	records, err := store.ListTokens(context.Background())
	if err != nil {
		t.Fatalf("list tokens: %v", err)
	}
	active := 0
	revoked := 0
	for _, r := range records {
		if r.ProviderID != "legacy-dup" {
			continue
		}
		if r.RevokedAt.Valid {
			revoked++
		} else {
			active++
		}
	}
	if active != 1 || revoked != 1 {
		t.Fatalf("after migration: legacy-dup active=%d revoked=%d, want 1/1: %#v", active, revoked, records)
	}
}

// SPEC-003 v0.8.3 FR-C9.4 unused-token self-heal — Store layer
// contract for the three input states the resolveProvisionalToken
// caller will encounter. Direct unit coverage on top of the
// end-to-end ws-level tests so a future refactor that changes the
// SQL/semantics of this primitive fails here loudly.
func TestRevokeUnusedTokenForProvider(t *testing.T) {
	store, err := auth.OpenStore(filepath.Join(t.TempDir(), "coordinator.db"))
	if err != nil {
		t.Fatalf("open store: %v", err)
	}
	defer store.Close()
	ctx := context.Background()

	t.Run("no row → false, no error", func(t *testing.T) {
		revoked, err := store.RevokeUnusedTokenForProvider(ctx, "nonexistent")
		if err != nil {
			t.Fatalf("err = %v, want nil", err)
		}
		if revoked {
			t.Fatalf("revoked = true, want false (no row exists)")
		}
	})

	t.Run("unused row → true, row revoked", func(t *testing.T) {
		seed, _, err := store.IssueToken(ctx, "unused-provider", "unused hostname")
		if err != nil {
			t.Fatalf("seed: %v", err)
		}
		revoked, err := store.RevokeUnusedTokenForProvider(ctx, "unused-provider")
		if err != nil {
			t.Fatalf("err = %v, want nil", err)
		}
		if !revoked {
			t.Fatalf("revoked = false, want true (unused row should be self-healed)")
		}
		row, err := lookupTokenRow(ctx, t, store, seed.ID)
		if err != nil {
			t.Fatalf("get row post-revoke: %v", err)
		}
		if !row.RevokedAt.Valid {
			t.Fatalf("row.RevokedAt = %v, want non-NULL after self-heal", row.RevokedAt)
		}
	})

	t.Run("used row → false, row preserved", func(t *testing.T) {
		seed, cleartext, err := store.IssueToken(ctx, "used-provider", "used hostname")
		if err != nil {
			t.Fatalf("seed: %v", err)
		}
		if err := store.MarkTokenUsed(ctx, cleartext); err != nil {
			t.Fatalf("mark used: %v", err)
		}
		revoked, err := store.RevokeUnusedTokenForProvider(ctx, "used-provider")
		if err != nil {
			t.Fatalf("err = %v, want nil", err)
		}
		if revoked {
			t.Fatalf("revoked = true, want false (used row MUST NOT be auto-revoked — codex MAJOR-1 surface)")
		}
		row, err := lookupTokenRow(ctx, t, store, seed.ID)
		if err != nil {
			t.Fatalf("get row post-no-op: %v", err)
		}
		if row.RevokedAt.Valid {
			t.Fatalf("row.RevokedAt = %v, want NULL (used row must not be touched)", row.RevokedAt)
		}
	})

	t.Run("empty provider_id rejected", func(t *testing.T) {
		_, err := store.RevokeUnusedTokenForProvider(ctx, "   ")
		if err == nil {
			t.Fatalf("err = nil, want non-nil for empty provider_id")
		}
	})
}

func lookupTokenRow(ctx context.Context, t *testing.T, store *auth.Store, id int64) (auth.TokenRecord, error) {
	t.Helper()
	rows, err := store.ListTokens(ctx)
	if err != nil {
		return auth.TokenRecord{}, err
	}
	for _, r := range rows {
		if r.ID == id {
			return r, nil
		}
	}
	t.Fatalf("token id=%d not found in ListTokens output", id)
	return auth.TokenRecord{}, nil
}
