package buyer

// Seam-hardening e2e harness — coordinator-side scenarios H3 and H4.
// Companion to the gateway suite in
// phase5-gateway/internal/router/seam_harness_test.go and the risk register in
// audits/seam-hardening/. These live in phase4-coordinator because provider-health
// attribution and terminal ordering are the coordinator's job.
//
// Run: go test ./internal/buyer/ -run TestSeamH -count=1 -v

import (
	"context"
	"net/http"
	"net/http/httptest"
	"testing"
	"time"

	"github.com/augstar/macprovider-coordinator/internal/pool"
	providerws "github.com/augstar/macprovider-coordinator/internal/ws"
	"github.com/rs/zerolog"
)

// H3 · relay-timeout strikes provider health on a buyer cancel (INV-3).
// EXPECTED: PASS = confirms the bug. The ErrRelayTimeout branch
// (internal/buyer/server.go:2994-2996) calls recordBreakerFault WITHOUT the
// r.Context().Err() buyer-cancel guard that its ErrRelayClosed sibling has
// (:2997-3002). So a buyer/gateway cancel racing a relay timeout penalizes the
// provider. With breakerThreshold=1 a single fault flips it to StateDegraded,
// observed via the registry snapshot. When the guard is added, the provider
// stays StateReady and this test flips red — a regression tripwire for the fix.
func TestSeamH3_RelayTimeoutStrikesOnBuyerCancel(t *testing.T) {
	const providerID, assignedID = "p1", "current"
	at := time.Unix(1716768000, 0).UTC()

	reg := pool.NewRegistry(nil)
	reg.Register(&pool.Provider{
		ProviderID:       providerID,
		AssignedID:       assignedID,
		State:            pool.StateReady, // RecordBreakerFault only acts on Ready/Busy
		SlotsFree:        1,
		SlotsTotal:       1,
		MaxConcurrency:   1,
		MaxContextTokens: 20000,
		LastHeartbeatAt:  at,
		LastActivityAt:   at,
	}, nil)

	// threshold=1 so ONE fault trips Degraded (default is 2).
	s := NewServer(reg, zerolog.Nop(), at, WithBreakerConfig(1, 120*time.Second))
	provider := pool.Provider{ProviderID: providerID, AssignedID: assignedID}

	// Buyer/gateway cancel that races the relay timeout.
	ctx, cancel := context.WithCancel(context.Background())
	cancel()
	r := httptest.NewRequest(http.MethodPost, "/v1/chat/completions", nil).WithContext(ctx)
	w := httptest.NewRecorder()

	// Synthetic relay yielding exactly one ErrRelayTimeout; Chunks/Done nil block
	// harmlessly in the select, cancel func stays nil.
	errCh := make(chan error, 1)
	errCh <- providerws.ErrRelayTimeout
	relay := &providerws.RelayStream{RequestID: "req-h3", Errors: errCh}

	result, attempt := s.forwardWSNonStreaming(w, r, "req-h3", provider, relay, nil, nil, 1)

	if result != wsForwardTimedOut {
		t.Fatalf("expected wsForwardTimedOut, got %v", result)
	}
	if attempt.Status != http.StatusGatewayTimeout {
		t.Fatalf("expected 504 timeout attempt, got %d", attempt.Status)
	}

	var got pool.State
	found := false
	for _, p := range reg.Snapshot() {
		if p.ProviderID == providerID {
			got, found = p.State, true
		}
	}
	if !found {
		t.Fatalf("provider %q not found in registry snapshot", providerID)
	}
	if got != pool.StateDegraded {
		t.Fatalf("H3: expected the provider to be struck to Degraded by a relay-timeout fault "+
			"under a cancelled buyer ctx (the confirmed bug), got state %v. If it stayed Ready, "+
			"the missing r.Context().Err() guard was ADDED at server.go:2994 — update the audit", got)
	}
	t.Logf("CONFIRMED FINDING (INV-3): relay-timeout struck provider health (→Degraded) despite a "+
		"cancelled buyer context — the ErrRelayTimeout branch (server.go:2994) lacks the buyer-cancel "+
		"guard its ErrRelayClosed sibling has (:2997). Fix: add `if r.Context().Err()!=nil { return }` "+
		"before recordBreakerFault. (Streaming twin: forwardWSStreamingBuffered :3299.)")
}

// H4 · single-terminal-wins / paid-while-buyer-told-timeout (INV-6).
// Documented skip: not unit-testable. There is no arbiter/latch joining the two
// terminal paths — billing settlement (billingRecorder.recordRow,
// internal/buyer/billing_recorder.go:220) and the buyer 504 timeout terminal
// (forwardWSNonStreaming, internal/buyer/server.go:2996) are produced by independent
// paths. The "billing completed while the buyer was told it timed out" property is an
// emergent cross-path race, observable only end-to-end and non-deterministically;
// unit-asserting an ordering that no code enforces is not meaningful. Convert to a real
// test once a terminal latch is introduced at the recordRow seam (a single-terminal
// request-arbiter). See audits/seam-hardening/findings.md INV-6/INV-9.
func TestSeamH4_SingleTerminalWins(t *testing.T) {
	t.Skip("INV-6: no single-terminal-wins request actor exists; the billing terminal " +
		"(billing_recorder.go:220) and the buyer 504 terminal (server.go:2996) are independent " +
		"paths with no arbiter. The gap is a cross-path race observable only end-to-end. Attach a " +
		"real test at the recordRow seam once a single-terminal request-arbiter is introduced.")
}
