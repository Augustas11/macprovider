package auth_test

import (
	"context"
	"database/sql"
	"errors"
	"net/http"
	"path/filepath"
	"sync"
	"sync/atomic"
	"testing"

	"github.com/augstar/macprovider-coordinator/internal/auth"
)

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
