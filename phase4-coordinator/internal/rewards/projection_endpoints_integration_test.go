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
func TestQueryRecentVerifiedWorkUsesOnlyFreshVerifiedEnforceMirrorRows(t *testing.T) {
	ctx := context.Background()
	_, db := startPostgres(t)
	if _, err := db.ExecContext(ctx, `
CREATE TABLE ledger_request_credits (
    provider_id TEXT NOT NULL,
    ts_utc TIMESTAMP NOT NULL,
    spec022_verified BOOLEAN NOT NULL,
    settlement_policy_mode TEXT NOT NULL,
    quarantined BOOLEAN NOT NULL,
    provider_credits INTEGER NOT NULL
)`); err != nil {
		t.Fatalf("create mirror: %v", err)
	}
	now := time.Date(2026, time.September, 10, 12, 0, 0, 0, time.UTC)
	rows := []struct {
		provider    string
		at          time.Time
		verified    bool
		mode        string
		quarantined bool
		credits     int
	}{
		{"provider-a", now.Add(-rewards.RecentVerifiedWorkWindow - time.Second), true, "enforce", false, 1},
		{"provider-a", now.Add(-time.Minute), false, "enforce", false, 1},
		{"provider-a", now.Add(-time.Minute), true, "observe", false, 1},
		{"provider-a", now.Add(-time.Minute), true, "enforce", true, 1},
		{"provider-a", now.Add(-time.Minute), true, "enforce", false, 0},
		{"provider-a", now.Add(-2 * time.Minute), true, "enforce", false, 7},
		{"provider-a", now.Add(time.Minute), true, "enforce", false, 7},
	}
	for _, row := range rows {
		if _, err := db.ExecContext(ctx, `INSERT INTO ledger_request_credits VALUES ($1, $2, $3, $4, $5, $6)`, row.provider, row.at, row.verified, row.mode, row.quarantined, row.credits); err != nil {
			t.Fatalf("insert mirror row: %v", err)
		}
	}
	config := rewards.Config{SQLitePayoutDBPath: filepath.Join(t.TempDir(), "unavailable-payout.sqlite")}
	recent := func(provider string) *time.Time {
		t.Helper()
		projection, err := rewards.BuildProviderRewardProjection(ctx, provider, rewards.ProviderRewardProjectionDeps{
			RewardsDB: db, Config: config, Now: func() time.Time { return now },
		})
		if err != nil {
			t.Fatal(err)
		}
		if projection.RecentWorkAt == nil {
			for _, reason := range projection.Eligibility.Reasons {
				if reason == rewards.ReasonEarningVerifiedWork {
					t.Fatal("absent observation claimed earning")
				}
			}
		}
		return projection.RecentWorkAt
	}
	got := recent("provider-a")
	if got == nil || !got.Equal(now.Add(-2*time.Minute)) {
		t.Fatalf("recent verified work = %v, want %v", got, now.Add(-2*time.Minute))
	}
	missing := recent("provider-b")
	if missing != nil {
		t.Fatalf("missing provider = %v; want nil", missing)
	}

	// A missing column above models an older mirror. With the new column,
	// excluded rows must neither replace an older valid observation nor create one.
	if _, err := db.ExecContext(ctx, "ALTER TABLE ledger_request_credits ADD COLUMN rewards_excluded BOOLEAN"); err != nil {
		t.Fatal(err)
	}
	for _, provider := range []string{"provider-a", "provider-excluded"} {
		if _, err := db.ExecContext(ctx, `INSERT INTO ledger_request_credits VALUES ($1, $2, TRUE, 'enforce', FALSE, 7, TRUE)`, provider, now.Add(-time.Minute)); err != nil {
			t.Fatal(err)
		}
	}
	if got := recent("provider-a"); got == nil || !got.Equal(now.Add(-2*time.Minute)) {
		t.Fatalf("excluded row replaced valid observation: %v", got)
	}
	if got := recent("provider-excluded"); got != nil {
		t.Fatalf("excluded-only provider has positive work observation: %v", got)
	}
	for _, flag := range []any{false, nil} {
		if _, err := db.ExecContext(ctx, "UPDATE ledger_request_credits SET rewards_excluded = $1 WHERE provider_id = 'provider-excluded'", flag); err != nil {
			t.Fatal(err)
		}
		if got := recent("provider-excluded"); got == nil || !got.Equal(now.Add(-time.Minute)) {
			t.Fatalf("nonexcluded legacy flag %v lost valid work: %v", flag, got)
		}
	}
}
