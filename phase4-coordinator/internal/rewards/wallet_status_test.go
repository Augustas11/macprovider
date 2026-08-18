package rewards

import (
	"context"
	"database/sql"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"
	"time"
)

type readOnlyWalletTokens struct {
	providerID string
	readOnly   int
	marked     int
}

func (f *readOnlyWalletTokens) ValidateTokenReadOnly(context.Context, string) (string, bool, error) {
	f.readOnly++
	return f.providerID, true, nil
}

func (f *readOnlyWalletTokens) ValidateAndMarkTokenUsed(context.Context, string) (string, bool, error) {
	f.marked++
	return f.providerID, true, nil
}

func TestWalletStatusHandlerKeepsMutationGuard(t *testing.T) {
	tokens := &readOnlyWalletTokens{providerID: "provider-a"}
	h := NewWalletStatusHandler(WalletHandlerDeps{
		TokenStore:            tokens,
		RequireProviderTokens: true,
	})

	req := httptest.NewRequest(http.MethodPost, "/v1/provider/wallet", nil)
	rec := httptest.NewRecorder()
	h.ServeHTTP(rec, req)

	if rec.Code != http.StatusNotImplemented {
		t.Fatalf("code=%d body=%s", rec.Code, rec.Body.String())
	}
	if !strings.Contains(rec.Body.String(), "wallet_change_requires_spec_027") {
		t.Fatalf("body=%s, want wallet_change_requires_spec_027", rec.Body.String())
	}
	if tokens.readOnly != 0 || tokens.marked != 0 {
		t.Fatalf("POST must not inspect provider tokens; readOnly=%d marked=%d", tokens.readOnly, tokens.marked)
	}
}

func TestWalletStatusHandlerAuthAndReadOnlyValidation(t *testing.T) {
	tokens := &readOnlyWalletTokens{providerID: "provider-a"}
	h := NewWalletStatusHandler(WalletHandlerDeps{
		TokenStore:            tokens,
		RequireProviderTokens: true,
	})

	unauth := httptest.NewRecorder()
	h.ServeHTTP(unauth, httptest.NewRequest(http.MethodGet, "/v1/provider/wallet", nil))
	if unauth.Code != http.StatusUnauthorized {
		t.Fatalf("unauth code=%d body=%s", unauth.Code, unauth.Body.String())
	}

	req := httptest.NewRequest(http.MethodGet, "/v1/provider/wallet", nil)
	req.Header.Set("Authorization", "Bearer provider-token")
	rec := httptest.NewRecorder()
	h.ServeHTTP(rec, req)
	if rec.Code != http.StatusServiceUnavailable {
		t.Fatalf("code=%d body=%s, want 503 after auth because DB is intentionally nil", rec.Code, rec.Body.String())
	}
	if tokens.readOnly != 1 || tokens.marked != 0 {
		t.Fatalf("validation calls readOnly=%d marked=%d, want read-only only", tokens.readOnly, tokens.marked)
	}
}

func TestWalletStatusHandlerUsesRewardAuditLimiter(t *testing.T) {
	tokens := &readOnlyWalletTokens{providerID: "provider-a"}
	limiter := NewRewardAuditLimiter(1, 1)
	release, ok := limiter.Allow("provider-a", time.Now().UTC())
	if !ok {
		t.Fatal("initial limiter reservation failed")
	}
	defer release()
	h := NewWalletStatusHandler(WalletHandlerDeps{
		TokenStore:            tokens,
		RequireProviderTokens: true,
		Limiter:               limiter,
	})

	req := httptest.NewRequest(http.MethodGet, "/v1/provider/wallet", nil)
	req.Header.Set("Authorization", "Bearer provider-token")
	rec := httptest.NewRecorder()
	h.ServeHTTP(rec, req)

	if rec.Code != http.StatusTooManyRequests {
		t.Fatalf("code=%d body=%s, want 429", rec.Code, rec.Body.String())
	}
	if got := rec.Header().Get("Retry-After"); got != "1" {
		t.Fatalf("Retry-After=%q, want 1", got)
	}
}

func TestPayoutWalletStatusFiltersCurrentHotWallet(t *testing.T) {
	ctx := context.Background()
	db, err := sql.Open("sqlite", ":memory:")
	if err != nil {
		t.Fatalf("open sqlite: %v", err)
	}
	t.Cleanup(func() { _ = db.Close() })
	_, err = db.ExecContext(ctx, `
CREATE TABLE provider_payout_addresses (
    provider_id TEXT NOT NULL,
    chain TEXT NOT NULL,
    address TEXT NOT NULL,
    payout_allowed INTEGER NOT NULL,
    pending_until_utc TEXT,
    rotated_from TEXT,
    registered_at_utc TEXT,
    registered_against_hot_wallet TEXT NOT NULL
)`)
	if err != nil {
		t.Fatalf("create provider_payout_addresses: %v", err)
	}
	_, err = db.ExecContext(ctx, `
INSERT INTO provider_payout_addresses
    (provider_id, chain, address, payout_allowed, registered_at_utc, registered_against_hot_wallet)
VALUES
    ('provider-a', 'base-mainnet', '0xOldWallet', 1, '2026-08-18T00:00:00Z', '0xOldHot'),
    ('provider-a', 'base-mainnet', '0xCurrentWallet', 1, '2026-08-18T01:00:00Z', '0xCurrentHot')`)
	if err != nil {
		t.Fatalf("insert provider_payout_addresses: %v", err)
	}

	missing, err := queryPayoutWalletStatus(ctx, db, "provider-a", "")
	if err != nil {
		t.Fatalf("empty hot wallet query: %v", err)
	}
	if missing != nil {
		t.Fatalf("empty hot wallet returned %+v, want nil", missing)
	}

	stale, err := queryPayoutWalletStatus(ctx, db, "provider-a", "0xOldHot")
	if err != nil {
		t.Fatalf("stale hot wallet query: %v", err)
	}
	if stale == nil || stale.Address != "0xOldWallet" {
		t.Fatalf("stale hot wallet returned %+v, want old row", stale)
	}

	current, err := queryPayoutWalletStatus(ctx, db, "provider-a", "0xCurrentHot")
	if err != nil {
		t.Fatalf("current hot wallet query: %v", err)
	}
	if current == nil {
		t.Fatal("current hot wallet returned nil")
	}
	if current.Address != "0xCurrentWallet" {
		t.Fatalf("address=%q, want current row", current.Address)
	}
	if current.RegisteredAgainstHotWallet != "0xCurrentHot" {
		t.Fatalf("registered_against_hot_wallet=%q, want current hot wallet", current.RegisteredAgainstHotWallet)
	}
}

func TestCurrentWalletBindingFailsClosedOnStaleHotWalletProjection(t *testing.T) {
	bound, mismatch := currentWalletBinding(nil, rewardWalletProjection{Address: "0xOldWallet"})
	if bound {
		t.Fatal("stale reward projection without a current payout wallet reported wallet_bound=true")
	}
	if !mismatch {
		t.Fatal("stale reward projection without a current payout wallet did not report mismatch")
	}

	pending := &ProviderPayoutWalletStatus{Address: "0xCurrentWallet", PayoutAllowed: false}
	bound, mismatch = currentWalletBinding(pending, rewardWalletProjection{Address: "0xCurrentWallet"})
	if bound {
		t.Fatal("pending current payout wallet reported wallet_bound=true")
	}
	if mismatch {
		t.Fatal("pending current payout wallet matching reward projection reported mismatch")
	}

	current := &ProviderPayoutWalletStatus{Address: "0xCurrentWallet", PayoutAllowed: true}
	bound, mismatch = currentWalletBinding(current, rewardWalletProjection{})
	if !bound || !mismatch {
		t.Fatalf("current payout wallet missing reward projection got bound=%v mismatch=%v, want true/true", bound, mismatch)
	}

	bound, mismatch = currentWalletBinding(current, rewardWalletProjection{Address: "0xCurrentWallet"})
	if !bound || mismatch {
		t.Fatalf("current payout wallet binding got bound=%v mismatch=%v, want true/false", bound, mismatch)
	}
}

func TestTrustCriteriaWithWalletBindingRecomputesCriteria(t *testing.T) {
	trust := TrustCriteriaStatus{
		VerifiedReceiptCount: minVerifiedReceipts,
		WalletBound:          true,
		WalletBalanceOK:      true,
		OperatorPromoted:     true,
		UptimeOK:             true,
		AppAttested:          true,
		EconomicSatisfied:    []string{CriterionE1Receipts, CriterionE2WalletEconomic, CriterionE3Operator},
		AdditionalSatisfied:  []string{CriterionE1Receipts, CriterionWalletBalance72h, CriterionUptime72h, CriterionAppAttest},
		CriteriaMet:          5,
		CriteriaRequired:     2,
	}

	got := trustCriteriaWithWalletBinding(trust, false)
	if got.WalletBound || got.WalletBalanceOK {
		t.Fatalf("wallet flags got bound=%v balance=%v, want false/false", got.WalletBound, got.WalletBalanceOK)
	}
	for _, criterion := range append(got.EconomicSatisfied, got.AdditionalSatisfied...) {
		if criterion == CriterionE2WalletEconomic || criterion == CriterionWalletBalance72h {
			t.Fatalf("stale wallet criterion %q remained in %+v", criterion, got)
		}
	}
	if got.CriteriaMet != 4 {
		t.Fatalf("criteria_met=%d, want 4 after wallet criteria are removed", got.CriteriaMet)
	}
}
