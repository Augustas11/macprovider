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

// H3-streaming · twin of H3 for the streaming relay paths (#761). The
// ErrRelayTimeout branch in forwardWSStreaming and the relay.Errors case in
// forwardWSStreamingBuffered carry the same buyer-cancel guard as their
// non-streaming sibling. With a cancelled buyer ctx AND a pending relay error
// the select picks either case at random, so each iteration exercises the
// guarded error branch with ~50% probability; 20 iterations make an unguarded
// strike (provider → Degraded at threshold=1) or a mis-attributed failure
// terminal practically certain to be caught. The buffered subtest forces the
// buffered path via the per-request kill-switch env.
func TestSeamH3Streaming_RelayTimeoutNoStrikeOnBuyerCancel(t *testing.T) {
	t.Run("incremental", func(t *testing.T) { seamH3StreamingScenario(t) })
	t.Run("buffered", func(t *testing.T) {
		t.Setenv("COORDINATOR_STREAMING_FORCE_BUFFERED", "1")
		seamH3StreamingScenario(t)
	})
}

func seamH3StreamingScenario(t *testing.T) {
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

// H4 · single-terminal-wins / paid-while-buyer-told-failed (INV-6).
// The documented skip that used to live here is GONE — #766 introduced the
// single-terminal request arbiter (internal/buyer/terminal_arbiter.go), and the
// scenarios now live in seam_h4_test.go:
//
//	TestSeamH4_AgreeingTimeoutTerminal                  — bill-before-write ordering
//	TestSeamH4_PostTerminalBillingRowIsOrderedAndAgrees — write-before-bill ordering
//	TestSeamH4_CreditedWhileBuyerToldFailedIsAConflict  — the INV-6 tripwire
//	TestSeamH4_TerminalArbiterPredicates                — predicate unit table
//	TestSeamH4_ClaimOncePerTransport                    — latch coverage per transport
//
// The skip's premise was half wrong: there is no cross-goroutine race (recordRow
// and every buyer write run on the request goroutine, and the relay layer's
// timeout-vs-completion race is already single-winner arbitrated under activeMu).
// The gap was STRUCTURAL — nothing published "a buyer terminal was admitted", so
// nothing could assert the ledger and the buyer's HTTP status agreed. With the
// arbiter publishing both sides the property is deterministic, and H4-3 forces
// the disagreement without any production-code seam.
