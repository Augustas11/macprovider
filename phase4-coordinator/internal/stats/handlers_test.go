package stats

import (
	"database/sql"
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"testing"
	"time"

	"github.com/augstar/macprovider-coordinator/internal/stats/store"
	_ "modernc.org/sqlite"
)

func TestProviderBoundKeyCannotUseBroadPartnerLeaderboard(t *testing.T) {
	h := &Handler{Now: func() time.Time { return time.Unix(1_700_000_000, 0).UTC() }}
	req := httptest.NewRequest(http.MethodGet, "/v1/stats/leaderboard", nil)
	req = req.WithContext(withPartnerProjectionContext(req.Context()))
	rec := httptest.NewRecorder()

	h.handleLeaderboard(rec, req, authResult{
		projection: "partner",
		matchedKey: &store.PartnerKey{
			ID:         17,
			ProviderID: sql.NullString{String: "p_provider_bound", Valid: true},
		},
	})

	if rec.Code != http.StatusForbidden {
		t.Fatalf("status=%d want 403 body=%s", rec.Code, rec.Body.String())
	}
	if got := rec.Header().Get("Cache-Control"); got != "private, max-age=30, s-maxage=30" {
		t.Fatalf("Cache-Control=%q want private partner error row", got)
	}
}

func TestProviderNoRowUsesFreshComponentSnapshot(t *testing.T) {
	now := time.Unix(1_700_000_000, 0).UTC()
	h := providerNoRowHandler(t, now)
	req := httptest.NewRequest(http.MethodGet, "/v1/stats/provider/p_empty?window=30d", nil)
	rec := httptest.NewRecorder()

	h.handleProvider(rec, req, authResult{
		projection:    "partner",
		originPresent: true,
		originValue:   "https://console.streamvc.live",
		matchedKey: &store.PartnerKey{
			ID:         17,
			ProviderID: sql.NullString{String: "p_empty", Valid: true},
		},
	})

	if rec.Code != http.StatusOK {
		t.Fatalf("status=%d want 200 body=%s", rec.Code, rec.Body.String())
	}
	var resp providerStatsResponse
	if err := json.Unmarshal(rec.Body.Bytes(), &resp); err != nil {
		t.Fatalf("decode response: %v", err)
	}
	if resp.ProviderID != "p_empty" || resp.Row.Tokens != 0 || resp.Row.Jobs != 0 || resp.Row.EarningsBucket != "-" {
		t.Fatalf("zero provider response = %+v", resp)
	}
}

func TestProviderNoRowReturnsStaleWhenComponentStale(t *testing.T) {
	now := time.Unix(1_700_000_000, 0).UTC()
	h := providerNoRowHandler(t, now.Add(-40*24*time.Hour))
	req := httptest.NewRequest(http.MethodGet, "/v1/stats/provider/p_empty?window=30d", nil)
	rec := httptest.NewRecorder()

	h.handleProvider(rec, req, authResult{
		projection: "partner",
		matchedKey: &store.PartnerKey{
			ID:         17,
			ProviderID: sql.NullString{String: "p_empty", Valid: true},
		},
	})

	if rec.Code != http.StatusServiceUnavailable {
		t.Fatalf("status=%d want 503 body=%s", rec.Code, rec.Body.String())
	}
}

func providerNoRowHandler(t *testing.T, generatedAt time.Time) *Handler {
	t.Helper()
	db, err := sql.Open("sqlite", ":memory:")
	if err != nil {
		t.Fatalf("open sqlite: %v", err)
	}
	t.Cleanup(func() { _ = db.Close() })
	stmts := []string{
		`CREATE TABLE stats_leaderboard_30d (
            provider_id TEXT PRIMARY KEY,
            pseudonym TEXT,
            generated_at TIMESTAMP,
            rank_earnings INTEGER,
            rank_tokens INTEGER,
            rank_jobs INTEGER,
            earnings_usd TEXT,
            earnings_work_usd TEXT,
            earnings_rewards_usd TEXT,
            earnings_bucket TEXT,
            tokens INTEGER,
            jobs INTEGER,
            first_seen_at TIMESTAMP NULL,
            last_seen_at TIMESTAMP NULL
        )`,
		`CREATE TABLE provider_visibility (
            provider_id TEXT PRIMARY KEY,
            mode TEXT,
            blocked_from_partner_projection BOOLEAN
        )`,
		`CREATE TABLE stats_components_health (
            component TEXT PRIMARY KEY,
            generated_at TIMESTAMP
        )`,
		`INSERT INTO stats_components_health (component, generated_at) VALUES ('leaderboard_30d', ?)`,
	}
	for i, stmt := range stmts {
		if i == len(stmts)-1 {
			if _, err := db.Exec(stmt, generatedAt); err != nil {
				t.Fatalf("exec fixture stmt %d: %v", i, err)
			}
			continue
		}
		if _, err := db.Exec(stmt); err != nil {
			t.Fatalf("exec fixture stmt %d: %v", i, err)
		}
	}
	return &Handler{
		Store: store.New(db),
		Now:   func() time.Time { return time.Unix(1_700_000_000, 0).UTC() },
	}
}
