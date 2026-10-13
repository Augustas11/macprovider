package stakeallowance

import (
	"context"
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"

	"github.com/augstar/macprovider-coordinator/internal/billing"
	"github.com/augstar/macprovider-coordinator/internal/rewards"
	"github.com/rs/zerolog"
)

const testServiceToken = "svc-token-for-stake-tests-0123456789abcdef"

type fakeLedger struct {
	lockReq, unlockReq rewards.StakeRequest
	err                error
}

func (f *fakeLedger) Lock(_ context.Context, req rewards.StakeRequest) (rewards.StakeResult, error) {
	f.lockReq = req
	if f.err != nil {
		return rewards.StakeResult{}, f.err
	}
	return rewards.StakeResult{Events: []rewards.StakeEvent{{ProviderID: "p1", EventType: "lock", AmountUnits: req.AmountUnits, CreatedAt: time.Unix(0, 0)}}}, nil
}

func (f *fakeLedger) Unlock(_ context.Context, req rewards.StakeRequest) (rewards.StakeResult, error) {
	f.unlockReq = req
	if f.err != nil {
		return rewards.StakeResult{}, f.err
	}
	release := time.Unix(3600, 0)
	return rewards.StakeResult{Events: []rewards.StakeEvent{{ProviderID: "p1", EventType: "unlock", AmountUnits: req.AmountUnits, CreatedAt: time.Unix(0, 0), ReleaseAt: &release}}}, nil
}

func (f *fakeLedger) Position(_ context.Context, _ string, owned []string) (rewards.StakePosition, error) {
	release := time.Date(2026, 10, 20, 6, 0, 0, 0, time.UTC)
	return rewards.StakePosition{StakedUnits: 150_000_000, UnlockingUnits: 50_000_000, AvailableUnits: int64(len(owned)) * 100_000_000, NextReleaseAt: &release}, nil
}

type fakeAllowance struct {
	overage map[string]bool
}

func (f *fakeAllowance) SetAllowanceOverage(_ context.Context, account string, enabled bool, _ time.Time) error {
	if f.overage == nil {
		f.overage = map[string]bool{}
	}
	f.overage[account] = enabled
	return nil
}

func (f *fakeAllowance) AllowanceStatusFor(_ context.Context, account string, now time.Time) (billing.AllowanceStatus, error) {
	overage := true
	if v, ok := f.overage[account]; ok {
		overage = v
	}
	return billing.AllowanceStatus{Day: now.Format("2006-01-02"), GrantedCredits: 250_000, SpentCredits: 1_000, HeldCredits: 500,
		RemainingCredits: 248_500, OverageEnabled: overage, NextRefreshAt: billing.NextAllowanceRefresh(now)}, nil
}

func newTestHandler(ledger StakeLedger) http.Handler {
	return NewHandler(Deps{
		GatewayServiceToken: testServiceToken,
		Ledger:              ledger,
		OwnedProviderIDs: func(_ context.Context, gh int64) ([]string, error) {
			if gh == 42 {
				return []string{"p1"}, nil
			}
			return nil, nil
		},
		Logger: zerolog.Nop(),
	})
}

func stakeCall(h http.Handler, path, body string, headers map[string]string) *httptest.ResponseRecorder {
	req := httptest.NewRequest(http.MethodPost, Prefix+path, strings.NewReader(body))
	for k, v := range headers {
		req.Header.Set(k, v)
	}
	rec := httptest.NewRecorder()
	h.ServeHTTP(rec, req)
	return rec
}

func principalHeaders() map[string]string {
	return map[string]string{
		"Authorization":    "Bearer " + testServiceToken,
		AccountIDHeader:    "acct_1",
		GitHubUserIDHeader: "42",
		"Idempotency-Key":  "key-1",
	}
}

func errorCode(t *testing.T, rec *httptest.ResponseRecorder) string {
	t.Helper()
	var body struct {
		Error struct {
			Code string `json:"code"`
		} `json:"error"`
	}
	if err := json.Unmarshal(rec.Body.Bytes(), &body); err != nil {
		t.Fatalf("decode %q: %v", rec.Body.String(), err)
	}
	return body.Error.Code
}

func TestStakeHandlerRequiresServiceTokenAndPrincipal(t *testing.T) {
	h := newTestHandler(&fakeLedger{})
	for name, mutate := range map[string]func(map[string]string){
		"no token":           func(m map[string]string) { delete(m, "Authorization") },
		"wrong token":        func(m map[string]string) { m["Authorization"] = "Bearer nope" },
		"no account":         func(m map[string]string) { delete(m, AccountIDHeader) },
		"bad account":        func(m map[string]string) { m[AccountIDHeader] = "acct 1" },
		"bad github id":      func(m map[string]string) { m[GitHubUserIDHeader] = "042" },
		"negative github":    func(m map[string]string) { m[GitHubUserIDHeader] = "-1" },
		"non-numeric github": func(m map[string]string) { m[GitHubUserIDHeader] = "abc" },
	} {
		t.Run(name, func(t *testing.T) {
			headers := principalHeaders()
			mutate(headers)
			rec := stakeCall(h, "lock", `{"amount_malibu":"1"}`, headers)
			if rec.Code != http.StatusUnauthorized {
				t.Fatalf("status %d body %s", rec.Code, rec.Body.String())
			}
		})
	}
}

func TestStakeHandlerLockUsesOwnedProvidersAndDerivedPrincipal(t *testing.T) {
	ledger := &fakeLedger{}
	h := newTestHandler(ledger)
	rec := stakeCall(h, "lock", `{"amount_malibu":"1.5"}`, principalHeaders())
	if rec.Code != http.StatusOK {
		t.Fatalf("status %d body %s", rec.Code, rec.Body.String())
	}
	if ledger.lockReq.AccountID != "acct_1" || ledger.lockReq.GitHubUserID != 42 || ledger.lockReq.AmountUnits != 150_000_000 || ledger.lockReq.IdempotencyKey != "key-1" {
		t.Fatalf("lock request %+v", ledger.lockReq)
	}
	if len(ledger.lockReq.OwnedProviderIDs) != 1 || ledger.lockReq.OwnedProviderIDs[0] != "p1" {
		t.Fatalf("owned providers %v", ledger.lockReq.OwnedProviderIDs)
	}
	var body map[string]any
	_ = json.Unmarshal(rec.Body.Bytes(), &body)
	if body["disclosure"] != Disclosure {
		t.Fatalf("missing disclosure: %s", rec.Body.String())
	}
	rec = stakeCall(h, "unlock", `{"amount_malibu":"0.5"}`, principalHeaders())
	if rec.Code != http.StatusOK || !strings.Contains(rec.Body.String(), `"release_at"`) {
		t.Fatalf("unlock status %d body %s", rec.Code, rec.Body.String())
	}
}

func TestStakeHandlerRefusals(t *testing.T) {
	cases := []struct {
		name   string
		ledger StakeLedger
		body   string
		mutate func(map[string]string)
		status int
		code   string
	}{
		{"no ledger", nil, `{"amount_malibu":"1"}`, nil, 503, "stake_source_unavailable"},
		{"no idempotency key", &fakeLedger{}, `{"amount_malibu":"1"}`, func(m map[string]string) { delete(m, "Idempotency-Key") }, 400, "idempotency_key_required"},
		{"no github identity", &fakeLedger{}, `{"amount_malibu":"1"}`, func(m map[string]string) { delete(m, GitHubUserIDHeader) }, 403, "github_identity_required"},
		{"bad amount", &fakeLedger{}, `{"amount_malibu":"1.000000001"}`, nil, 400, "invalid_amount"},
		{"unknown field", &fakeLedger{}, `{"amount_malibu":"1","account_id":"x"}`, nil, 400, "invalid_body"},
		{"insufficient", &fakeLedger{err: rewards.ErrStakeInsufficient}, `{"amount_malibu":"1"}`, nil, 409, "insufficient_malibu"},
		{"key reused", &fakeLedger{err: rewards.ErrStakeIdempotencyReused}, `{"amount_malibu":"1"}`, nil, 409, "idempotency_key_reused"},
		{"no owned provider", &fakeLedger{err: rewards.ErrStakeNoOwnedProviders}, `{"amount_malibu":"1"}`, nil, 409, "no_owned_provider"},
	}
	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			headers := principalHeaders()
			if tc.mutate != nil {
				tc.mutate(headers)
			}
			rec := stakeCall(newTestHandler(tc.ledger), "lock", tc.body, headers)
			if rec.Code != tc.status || errorCode(t, rec) != tc.code {
				t.Fatalf("status %d body %s, want %d %s", rec.Code, rec.Body.String(), tc.status, tc.code)
			}
		})
	}
}

func TestStakeHandlerAccountViewAndOverage(t *testing.T) {
	allowance := &fakeAllowance{}
	h := NewHandler(Deps{
		GatewayServiceToken: testServiceToken,
		Ledger:              &fakeLedger{},
		Allowance:           allowance,
		OwnedProviderIDs: func(_ context.Context, gh int64) ([]string, error) {
			return []string{"p1", "p2"}, nil
		},
		PayoutAddresses: func(context.Context, []string) ([]string, error) {
			return []string{"0x00000000000000000000000000000000000000aa"}, nil
		},
		Now:    func() time.Time { return time.Date(2026, 10, 13, 15, 0, 0, 0, time.UTC) },
		Logger: zerolog.Nop(),
	})
	get := func(headers map[string]string) map[string]any {
		t.Helper()
		req := httptest.NewRequest(http.MethodGet, Prefix+"account", nil)
		for k, v := range headers {
			req.Header.Set(k, v)
		}
		rec := httptest.NewRecorder()
		h.ServeHTTP(rec, req)
		if rec.Code != http.StatusOK || rec.Header().Get("Cache-Control") != "no-store" {
			t.Fatalf("account status %d body %s", rec.Code, rec.Body.String())
		}
		var view map[string]any
		if err := json.Unmarshal(rec.Body.Bytes(), &view); err != nil {
			t.Fatal(err)
		}
		return view
	}
	view := get(principalHeaders())
	want := map[string]any{
		"staked_malibu": "1.50000000", "unlocking_malibu": "0.50000000", "available_to_stake_malibu": "2.00000000",
		"next_unlock_release_at": "2026-10-20T06:00:00Z", "allowance_day": "2026-10-13", "next_refresh_at": "2026-10-14T00:00:00Z",
		"overage_enabled": true, "github_linked": true, "stake_source": "ledger_malibu_v1", "disclosure": Disclosure,
	}
	for k, v := range want {
		if view[k] != v {
			t.Fatalf("%s = %v want %v (view %v)", k, view[k], v, view)
		}
	}
	for k, v := range map[string]float64{"allowance_credits": 250_000, "allowance_spent_credits": 1_000, "allowance_held_credits": 500, "allowance_remaining_credits": 248_500} {
		if view[k] != v {
			t.Fatalf("%s = %v want %v", k, view[k], v)
		}
	}
	if wallets, _ := view["linked_wallets"].([]any); len(wallets) != 1 {
		t.Fatalf("linked_wallets %v", view["linked_wallets"])
	}
	rec := stakeCall(h, "overage", `{"enabled":false}`, principalHeaders())
	if rec.Code != http.StatusOK || allowance.overage["acct_1"] {
		t.Fatalf("overage status %d body %s", rec.Code, rec.Body.String())
	}
	if view := get(principalHeaders()); view["overage_enabled"] != false {
		t.Fatalf("overage not reflected: %v", view["overage_enabled"])
	}
	if rec := stakeCall(h, "overage", `{}`, principalHeaders()); rec.Code != http.StatusBadRequest {
		t.Fatalf("overage without enabled status %d", rec.Code)
	}
	noGitHub := principalHeaders()
	delete(noGitHub, GitHubUserIDHeader)
	if view := get(noGitHub); view["github_linked"] != false || view["available_to_stake_malibu"] != "0.00000000" {
		t.Fatalf("no-identity view %v", view)
	}
}

// SPEC-050-R012: no yield language on any stake or allowance surface.
func TestStakeSurfacesCarryNoYieldLanguage(t *testing.T) {
	for _, banned := range []string{"apy", "apr", "yield", "interest", "dividend", "return on"} {
		if strings.Contains(strings.ToLower(Disclosure), banned) {
			t.Fatalf("disclosure uses %q", banned)
		}
	}
	for _, needed := range []string{"cannot be withdrawn, transferred, or sold", "expires at 00:00 UTC", "unlock cooldown"} {
		if !strings.Contains(Disclosure, needed) {
			t.Fatalf("disclosure missing %q", needed)
		}
	}
}

func TestDisclosureMatchesSpec(t *testing.T) {
	raw, err := os.ReadFile(filepath.Join("..", "..", "..", "specs", "SPEC-050-malibu-stake-allowance.md"))
	if err != nil {
		t.Fatal(err)
	}
	spec := strings.Join(strings.Fields(string(raw)), " ")
	if !strings.Contains(spec, `"`+Disclosure+`"`) {
		t.Fatal("coordinator stake disclosure drifted from SPEC-050-R012")
	}
}
