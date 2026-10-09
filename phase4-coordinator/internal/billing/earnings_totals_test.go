package billing

import (
	"context"
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"reflect"
	"strings"
	"testing"
	"time"
)

// The single-pass payable read must return exactly what the former separate
// SUM/SUM/SUM/DISTINCT reads over spec022_payable_request_credits returned.
func TestEarningsSinglePassMatchesSeparatePayableReads(t *testing.T) {
	_, store := newRequestAndBillingStores(t)
	now := time.Now().UTC()
	week := currentMondayUTC(now)
	today := time.Date(now.Year(), now.Month(), now.Day(), 0, 0, 0, 0, time.UTC)
	seed := []struct {
		provider    string
		at          time.Time
		credits     int64
		model       string
		quarantined bool
	}{
		{"provider-a", today.Add(time.Minute), 11, "model-b", false},
		{"provider-a", today.Add(2 * time.Minute), 13, "model-a", false},
		{"provider-a", week.Add(-time.Minute), 17, "model-a", false},
		{"provider-a", week.AddDate(0, -2, 0), 19, "model-c", false},
		{"provider-a", week.AddDate(0, -3, 0), 23, "model-z", true}, // not payable
		{"provider-a", today.Add(3 * time.Minute), 29, "model-q", true},
		{"provider-b", today.Add(time.Minute), 31, "model-a", false},
	}
	for _, row := range seed {
		insertCredit(t, store.db, row.provider, row.at, row.credits)
		requestID := row.provider + "-" + row.at.UTC().Format("20060102150405.000000000") + "-req"
		quarantined := 0
		if row.quarantined {
			quarantined = 1
		}
		if _, err := store.db.Exec(`UPDATE ledger_request_credits SET model = ?, quarantined = ? WHERE request_id = ?`, row.model, quarantined, requestID); err != nil {
			t.Fatal(err)
		}
	}

	h := &handler{store: store}
	ctx := context.Background()
	for _, tc := range []struct {
		name     string
		from, to time.Time
		hasRange bool
	}{
		{name: "lifetime"},
		{name: "range", from: week.AddDate(0, -2, -1), to: today.AddDate(0, 0, 1), hasRange: true},
		{name: "narrow range", from: week.AddDate(0, -1, 0), to: today, hasRange: true},
	} {
		t.Run(tc.name, func(t *testing.T) {
			rangeSQL, rangeArgs := earningsRangeFilter(tc.from, tc.to, tc.hasRange)
			weekText, todayText := sqliteTimeText(week), sqliteTimeText(today)
			got, err := h.providerPayableTotals(ctx, "provider-a", weekText, todayText, rangeSQL, rangeArgs...)
			if err != nil {
				t.Fatal(err)
			}
			ref := func(query string, args ...any) int64 {
				t.Helper()
				n, err := sumOn(ctx, store.db, query, args...)
				if err != nil {
					t.Fatal(err)
				}
				return n
			}
			wantTotal := ref(`SELECT SUM(provider_credits) FROM spec022_payable_request_credits WHERE provider_id=?`+rangeSQL, append([]any{"provider-a"}, rangeArgs...)...)
			wantWeek := ref(`SELECT SUM(provider_credits) FROM spec022_payable_request_credits WHERE provider_id=? AND ts_utc >= ?`+rangeSQL, append([]any{"provider-a", weekText}, rangeArgs...)...)
			wantToday := ref(`SELECT SUM(provider_credits) FROM spec022_payable_request_credits WHERE provider_id=? AND ts_utc >= ?`+rangeSQL, append([]any{"provider-a", todayText}, rangeArgs...)...)
			rows, err := store.db.Query(`SELECT DISTINCT model FROM spec022_payable_request_credits WHERE provider_id=?`+rangeSQL+` ORDER BY model`, append([]any{"provider-a"}, rangeArgs...)...)
			if err != nil {
				t.Fatal(err)
			}
			wantModels := []string{}
			for rows.Next() {
				var m string
				if err := rows.Scan(&m); err != nil {
					t.Fatal(err)
				}
				wantModels = append(wantModels, m)
			}
			rows.Close()
			if got.total != wantTotal || got.week != wantWeek || got.today != wantToday || !reflect.DeepEqual(got.models, wantModels) {
				t.Fatalf("single pass = %+v; separate reads total=%d week=%d today=%d models=%v", got, wantTotal, wantWeek, wantToday, wantModels)
			}
			if tc.name == "lifetime" && (wantTotal != 11+13+17+19 || len(wantModels) != 3) {
				t.Fatalf("fixture lost its payable/non-payable mix: total=%d models=%v", wantTotal, wantModels)
			}
		})
	}
}

// A failed or timed-out read must answer a retryable 503, never a zero
// balance and never "provider not found".
func TestEarningsEndpointReadFailureIsRetryable503(t *testing.T) {
	_, store := newRequestAndBillingStores(t)
	insertCredit(t, store.db, "provider-a", time.Now().UTC(), 500)
	handler := store.Handlers("operator", fakeTokens{"good": "provider-a"}, true, 60)

	hit := func(ctx context.Context) *httptest.ResponseRecorder {
		req := httptest.NewRequest(http.MethodGet, "/providers/provider-a/earnings", nil).WithContext(ctx)
		req.Header.Set("Authorization", "Bearer good")
		rec := httptest.NewRecorder()
		handler.ServeHTTP(rec, req)
		return rec
	}
	assert503 := func(rec *httptest.ResponseRecorder) {
		t.Helper()
		if rec.Code != http.StatusServiceUnavailable || rec.Header().Get("Retry-After") == "" {
			t.Fatalf("status=%d retry-after=%q body=%s; want retryable 503", rec.Code, rec.Header().Get("Retry-After"), rec.Body.String())
		}
		var body struct {
			Error struct {
				Code string `json:"code"`
			} `json:"error"`
		}
		if err := json.Unmarshal(rec.Body.Bytes(), &body); err != nil || body.Error.Code != "unavailable" {
			t.Fatalf("body=%s; want code unavailable", rec.Body.String())
		}
		if strings.Contains(rec.Body.String(), "total_credits") {
			t.Fatal("failed read must not render balances")
		}
	}

	// Expired request context: the provider lookup fails (formerly a 404).
	ctx, cancel := context.WithCancel(context.Background())
	cancel()
	assert503(hit(ctx))

	// Payable view unreadable after the provider lookup succeeded (formerly 0).
	if _, err := store.db.Exec(`DROP VIEW spec022_payable_request_credits`); err != nil {
		t.Fatal(err)
	}
	assert503(hit(context.Background()))
}
