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

// H3 · relay-timeout must NOT strike provider health on a buyer cancel (INV-3,
// fixed by #761). The ErrRelayTimeout branch in forwardWSNonStreaming now
// carries the same r.Context().Err() buyer-cancel guard as its ErrRelayClosed
// sibling (streaming twin guarded in forwardWSStreamingBuffered), so a
// buyer/gateway cancel racing a relay timeout is attributed to the buyer, not
// the provider. With breakerThreshold=1 a single wrongly-recorded fault would
// flip the provider to StateDegraded — this asserts the cancel terminal is
// returned and the provider stays StateReady. Regression tripwire for #761.
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

	if result != wsForwardCancelled {
		t.Fatalf("expected wsForwardCancelled (buyer-cancel guard, #761), got %v", result)
	}
	if attempt.Status != http.StatusOK {
		t.Fatalf("expected cancel attempt status 200, got %d", attempt.Status)
	}
	if attempt.FaultFlag != "" {
		t.Fatalf("expected no breaker-qualifying fault flag on a buyer cancel, got %q", attempt.FaultFlag)
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
	if got != pool.StateReady {
		t.Fatalf("H3 REGRESSION (INV-3/#761): a relay timeout racing a cancelled buyer ctx struck "+
			"provider health (state %v, want Ready). The ErrRelayTimeout branch in "+
			"forwardWSNonStreaming must check r.Context().Err() before recordBreakerFault, "+
			"mirroring its ErrRelayClosed sibling.", got)
	}
}

// H3-streaming · twin of H3 for the streaming relay path (#761). The
// forwardWSStreaming ErrRelayTimeout branch carries the same buyer-cancel
// guard. With a cancelled buyer ctx AND a pending ErrRelayTimeout the select
// picks either case at random, so each iteration exercises the guarded timeout
// branch with ~50% probability; 20 iterations make an unguarded strike
// (provider → Degraded at threshold=1) practically certain to be caught.
func TestSeamH3Streaming_RelayTimeoutNoStrikeOnBuyerCancel(t *testing.T) {
	const providerID, assignedID = "p1", "current"
	at := time.Unix(1716768000, 0).UTC()

	for i := 0; i < 20; i++ {
		reg := pool.NewRegistry(nil)
		reg.Register(&pool.Provider{
			ProviderID:       providerID,
			AssignedID:       assignedID,
			State:            pool.StateReady,
			SlotsFree:        1,
			SlotsTotal:       1,
			MaxConcurrency:   1,
			MaxContextTokens: 20000,
			LastHeartbeatAt:  at,
			LastActivityAt:   at,
		}, nil)
		s := NewServer(reg, zerolog.Nop(), at, WithBreakerConfig(1, 120*time.Second))
		provider := pool.Provider{ProviderID: providerID, AssignedID: assignedID}

		ctx, cancel := context.WithCancel(context.Background())
		cancel()
		r := httptest.NewRequest(http.MethodPost, "/v1/chat/completions", nil).WithContext(ctx)
		w := httptest.NewRecorder()

		errCh := make(chan error, 1)
		errCh <- providerws.ErrRelayTimeout
		relay := &providerws.RelayStream{RequestID: "req-h3s", Errors: errCh}

		result, attempt := s.forwardWSStreaming(w, r, "req-h3s", provider, relay, nil, 1)

		if result != wsForwardCancelled {
			t.Fatalf("iter %d: expected wsForwardCancelled, got %v", i, result)
		}
		if attempt.Status != http.StatusOK {
			t.Fatalf("iter %d: expected cancel attempt status 200, got %d", i, attempt.Status)
		}
		for _, p := range reg.Snapshot() {
			if p.ProviderID == providerID && p.State != pool.StateReady {
				t.Fatalf("iter %d: H3-streaming REGRESSION (#761): relay timeout racing a cancelled "+
					"buyer ctx struck provider health (state %v, want Ready) — the ErrRelayTimeout "+
					"branch in forwardWSStreaming must check r.Context().Err() before "+
					"recordBreakerFault", i, p.State)
			}
		}
	}
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
