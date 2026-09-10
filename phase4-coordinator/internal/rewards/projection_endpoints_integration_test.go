//go:build integration

package rewards_test

import (
	"context"
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"path/filepath"
	"reflect"
	"testing"
	"time"

	"github.com/augstar/macprovider-coordinator/internal/autotune"
	"github.com/augstar/macprovider-coordinator/internal/rewards"
)

type projectionTokens struct{}

func (projectionTokens) ValidateTokenReadOnly(context.Context, string) (string, bool, error) {
	return "projection-provider", true, nil
}

func (projectionTokens) ValidateAndMarkTokenUsed(context.Context, string) (string, bool, error) {
	return "projection-provider", true, nil
}

type projectionHardware struct{ calls int }

func (s *projectionHardware) LatestVerified(context.Context, string, time.Duration) (autotune.VerifiedEvidence, bool, error) {
	s.calls++
	return autotune.VerifiedEvidence{GeneratedAt: time.Now().UTC()}, true, nil
}

func TestRewardEndpointsShareAuthoritativeProjection(t *testing.T) {
	_, db := startPostgres(t)
	if _, err := db.Exec(`INSERT INTO provider_emission_state (provider_id, trust_tier) VALUES ('projection-provider', 'trusted')`); err != nil {
		t.Fatal(err)
	}
	hardware := &projectionHardware{}
	config := rewards.Config{SQLitePayoutDBPath: filepath.Join(t.TempDir(), "unavailable-payout.sqlite")}
	accrual := rewards.NewAccrualHandler(rewards.AccrualHandlerDeps{
		Config: config,
		DB:     db, TokenStore: projectionTokens{}, RequireProviderTokens: true,
		HardwareEvidence: hardware, HardwareEvidenceTTL: time.Hour,
	})
	wallet := rewards.NewWalletStatusHandler(rewards.WalletHandlerDeps{
		Config:    config,
		RewardsDB: db, TokenStore: projectionTokens{}, RequireProviderTokens: true,
		HardwareEvidence: hardware, HardwareEvidenceTTL: time.Hour,
	})
	read := func(handler http.Handler, path string) map[string]any {
		t.Helper()
		req := httptest.NewRequest(http.MethodGet, path, nil)
		req.Header.Set("Authorization", "Bearer test-provider-token")
		rec := httptest.NewRecorder()
		handler.ServeHTTP(rec, req)
		if rec.Code != http.StatusOK {
			t.Fatalf("%s: status %d: %s", path, rec.Code, rec.Body.String())
		}
		var result map[string]any
		if err := json.Unmarshal(rec.Body.Bytes(), &result); err != nil {
			t.Fatal(err)
		}
		return result
	}
	a := read(accrual, "/v1/provider/malibu-accrual")
	w := read(wallet, "/v1/provider/wallet")
	if hardware.calls != 2 {
		t.Fatalf("both endpoints must consult the hardware owner; calls=%d", hardware.calls)
	}
	for _, field := range []string{"provider_id", "wallet_bound", "wallet_mismatch", "reward_eligibility"} {
		if !reflect.DeepEqual(a[field], w[field]) {
			t.Fatalf("%s differs: accrual=%v wallet=%v", field, a[field], w[field])
		}
	}
	amounts := w["reward_amounts"].(map[string]any)
	for _, field := range []string{"accrued_malibu", "withdrawable_malibu", "held_malibu"} {
		if a[field] != amounts[field] {
			t.Fatalf("%s differs: accrual=%v wallet=%v", field, a[field], amounts[field])
		}
	}
	if a["trust_tier"] != w["eligibility_inputs"].(map[string]any)["trust_tier"] {
		t.Fatal("trust projection differs")
	}
	eligibility := a["reward_eligibility"].(map[string]any)
	if eligibility["earning_state"] != "unavailable" || eligibility["withdrawal_state"] != "ineligible" {
		t.Fatalf("hardware alone cannot prove earning or a missing wallet: %v", eligibility)
	}
	for _, response := range []map[string]any{a, w} {
		generated, err := time.Parse(time.RFC3339, response["reward_projection_generated_at"].(string))
		if err != nil {
			t.Fatal(err)
		}
		stale, err := time.Parse(time.RFC3339, response["reward_projection_stale_after"].(string))
		if err != nil || stale.Sub(generated) > time.Minute || stale.Before(generated) {
			t.Fatalf("invalid projection freshness envelope: %v", response)
		}
	}
}
