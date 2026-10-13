package stakeallowance

import (
	"context"
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"
	"time"

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

func (f *fakeLedger) Position(context.Context, string, []string) (rewards.StakePosition, error) {
	return rewards.StakePosition{}, nil
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
