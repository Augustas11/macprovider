package buyer_test

import (
	"context"
	"database/sql"
	"encoding/json"
	"strings"
	"sync"
	"testing"
	"time"

	"github.com/augstar/macprovider-coordinator/internal/buyer"
	providerws "github.com/augstar/macprovider-coordinator/internal/ws"
)

// SPEC-036 FR-20: a verification request takes the ordinary paid dispatch
// path. The provider receives ordinary settlement metadata whose account
// scope is fresh per request, no buyer
// is debited (the gateway is never involved), and the provider's attempt is
// written to the ledger like any buyer request.
func TestComputeIntegrityProbeUsesOrdinaryPaidDispatch(t *testing.T) {
	var mu sync.Mutex
	var scopes []string
	h := newBuyerCancelHarness(t, "compute-integrity-probe", func(h *buyerCancelHarness, ctx context.Context, requestID string, meta *providerws.SettlementReceiptMetadata) *providerws.RelayStream {
		mu.Lock()
		scopes = append(scopes, meta.AccountScope)
		mu.Unlock()
		chunks := make(chan providerws.InferenceResponseChunk, 1)
		done := make(chan providerws.InferenceResponseEnd, 1)
		chunks <- providerws.InferenceResponseChunk{Type: "inference_response_chunk", RequestID: requestID, Data: deliveredOnlyCompletion}
		close(chunks)
		done <- providerws.InferenceResponseEnd{Type: "inference_response_end", RequestID: requestID, Status: "complete", ChunksSent: 1, Usage: json.RawMessage(`{"prompt_tokens":5,"completion_tokens":4,"total_tokens":9}`)}
		return &providerws.RelayStream{RequestID: requestID, Chunks: chunks, Done: done, Errors: make(chan error, 1)}
	})
	body := []byte(`{"model":"model-a","messages":[{"role":"system","content":"You are a helpful assistant."},{"role":"user","content":"Why is the sky blue?"}],"max_tokens":96,"temperature":0,"top_p":1,"stream":false}`)
	for i := 0; i < 2; i++ {
		got, err := h.server.DispatchComputeIntegrityProbe(h.ctx, "p1", body, 96)
		if err != nil {
			t.Fatalf("probe %d: %v", i, err)
		}
		if got.OutputText != "Hello world" || !got.Complete {
			t.Fatalf("probe %d: unexpected result %+v", i, got)
		}
	}
	mu.Lock()
	defer mu.Unlock()
	if len(scopes) != 2 {
		t.Fatalf("expected two dispatches, got %d", len(scopes))
	}
	for _, scope := range scopes {
		if !strings.HasPrefix(scope, "acct_sha256:") {
			t.Fatalf("account scope must look like any authenticated buyer's, got %q", scope)
		}
	}
	if scopes[0] == scopes[1] {
		t.Fatal("each verification request must use a fresh account scope")
	}

	db, err := sql.Open("sqlite", h.dbPath)
	if err != nil {
		t.Fatal(err)
	}
	defer db.Close()
	var credits, providerCredits int64
	if err := db.QueryRow(`SELECT COUNT(*), COALESCE(SUM(provider_credits), 0) FROM ledger_request_credits WHERE provider_id = 'p1'`).Scan(&credits, &providerCredits); err != nil {
		t.Fatal(err)
	}
	if credits != 2 || providerCredits <= 0 {
		t.Fatalf("provider must be credited for both requests: rows=%d provider_credits=%d", credits, providerCredits)
	}
	var cipAccounts int
	if err := db.QueryRow(`SELECT COUNT(*) FROM request_log WHERE account_id LIKE ?`, buyer.ComputeIntegrityAccountPrefix+"%").Scan(&cipAccounts); err != nil {
		t.Fatal(err)
	}
	if cipAccounts != 2 {
		t.Fatalf("verification requests must log under reserved accounts, got %d", cipAccounts)
	}
}

func TestComputeIntegrityProbeRejectsUnknownProvider(t *testing.T) {
	h := newBuyerCancelHarness(t, "compute-integrity-probe-missing", func(*buyerCancelHarness, context.Context, string, *providerws.SettlementReceiptMetadata) *providerws.RelayStream {
		t.Fatal("no dispatch for an unknown provider")
		return nil
	})
	ctx, cancel := context.WithTimeout(h.ctx, 5*time.Second)
	defer cancel()
	body := []byte(`{"model":"model-a","messages":[{"role":"user","content":"hi"}],"max_tokens":96,"stream":false}`)
	if _, err := h.server.DispatchComputeIntegrityProbe(ctx, "nobody", body, 96); err == nil {
		t.Fatal("a probe pinned to a provider that is not connected must fail")
	}
}
