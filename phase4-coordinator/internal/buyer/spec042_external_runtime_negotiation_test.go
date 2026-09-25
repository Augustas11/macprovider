package buyer_test

import (
	"database/sql"
	"encoding/json"
	"net/http"
	"testing"
)

// E2E-F10 (SPEC-022 R-12.8): an external-runtime pool member settles
// pool_operator_attested, which only a gateway that negotiated signed
// settlement finality can settle. A caller that did not negotiate (an older
// gateway) fails closed before dispatch: nothing reaches the provider, no
// route snapshot or ledger credit is written, and the error says why. Before
// the fix the request was served and credited while the old gateway held
// the buyer reservation forever.
func TestSPEC042ExternalRuntimeRefusedWithoutSettlementTrailerNegotiation(t *testing.T) {
	for _, tc := range []struct {
		name     string
		headers  func(poolID string) http.Header
		wantCode string
	}{
		{
			name:     "no-selection",
			headers:  func(poolID string) http.Header { return trustedPoolLayer2Headers(externalRuntimePoolAccount, poolID) },
			wantCode: "byom_non_settlement_unavailable",
		},
		{
			name: "engine-selected",
			headers: func(poolID string) http.Header {
				return withEngine(trustedPoolLayer2Headers(externalRuntimePoolAccount, poolID), "llamacpp_loopback")
			},
			wantCode: "engine_unavailable",
		},
	} {
		t.Run(tc.name, func(t *testing.T) {
			h := newExternalRuntimeHarness(t, defaultExternalRuntimeFixture())
			rec := postChat(t, h.server, externalRuntimeBody, tc.headers(h.poolID))
			if rec.Code != http.StatusServiceUnavailable {
				t.Fatalf("status=%d body=%s, want 503 before dispatch", rec.Code, rec.Body.String())
			}
			var body struct {
				Error struct {
					Code    string `json:"code"`
					Message string `json:"message"`
				} `json:"error"`
			}
			if err := json.Unmarshal(rec.Body.Bytes(), &body); err != nil {
				t.Fatalf("decode: %v body=%s", err, rec.Body.String())
			}
			if body.Error.Code != tc.wantCode || body.Error.Message != "External-runtime pool members serve only through a gateway that negotiates signed settlement finality" {
				t.Fatalf("error=%+v, want %s naming the settlement-finality negotiation", body.Error, tc.wantCode)
			}
			if got := h.settlementMetadata(); len(got) != 0 {
				t.Fatalf("provider received %d requests, want none", len(got))
			}
			db, err := sql.Open("sqlite", h.dbPath)
			if err != nil {
				t.Fatal(err)
			}
			defer db.Close()
			for _, table := range []string{"settlement_route_snapshots", "ledger_request_credits"} {
				var n int
				if err := db.QueryRow(`SELECT COUNT(*) FROM ` + table).Scan(&n); err != nil {
					t.Fatal(err)
				}
				if n != 0 {
					t.Fatalf("%s has %d rows, want none", table, n)
				}
			}
		})
	}
	// The same pool, negotiated, is served (the rest of the suite covers
	// the settlement itself).
	h := newExternalRuntimeHarness(t, defaultExternalRuntimeFixture())
	if rec := postChat(t, h.server, externalRuntimeBody, externalRuntimePoolHeaders(h.poolID)); rec.Code != http.StatusOK {
		t.Fatalf("negotiated status=%d body=%s", rec.Code, rec.Body.String())
	}
}
