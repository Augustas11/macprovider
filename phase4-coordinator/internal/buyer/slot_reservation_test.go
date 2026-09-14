package buyer

import (
	"context"
	"net/http"
	"testing"
	"time"

	"github.com/augstar/macprovider-coordinator/internal/pool"
)

func TestSelectProviderReservesDirectSlot(t *testing.T) {
	s, registry, _ := poolIsolationServer(t)
	provider := poolProvider("p-one")
	registry.Register(&provider, nil)

	state := &forwardState{slotReservationsEnabled: true}
	got, routeErr := s.selectProviderExcluding(context.Background(), "rid-1", poolChatReq(""), http.Header{}, nil, "2026-09-14", state)
	if routeErr != nil {
		t.Fatalf("first selection rejected: %+v", routeErr)
	}
	if got.ProviderID != provider.ProviderID {
		t.Fatalf("selected provider %q, want %q", got.ProviderID, provider.ProviderID)
	}
	if state.queuedSlotProviderID != provider.ProviderID {
		t.Fatalf("reservation provider %q, want %q", state.queuedSlotProviderID, provider.ProviderID)
	}

	blockedState := &forwardState{slotReservationsEnabled: true}
	_, routeErr = s.selectProviderExcluding(context.Background(), "rid-2", poolChatReq(""), http.Header{}, nil, "2026-09-14", blockedState)
	if routeErr == nil || routeErr.status != http.StatusServiceUnavailable || routeErr.code != "no_provider_available" {
		t.Fatalf("second selection with slot reserved: want 503 no_provider_available, got %+v", routeErr)
	}

	s.releaseQueuedSlotReservation(state)
	got, routeErr = s.selectProviderExcluding(context.Background(), "rid-3", poolChatReq(""), http.Header{}, nil, "2026-09-14", &forwardState{slotReservationsEnabled: true})
	if routeErr != nil || got.ProviderID != provider.ProviderID {
		t.Fatalf("selection after release provider=%q err=%+v, want %q nil", got.ProviderID, routeErr, provider.ProviderID)
	}
}

func TestSelectProviderReservationsShedAfterAllSlotsTaken(t *testing.T) {
	s, registry, _ := poolIsolationServer(t)
	first := poolProvider("p-one")
	second := poolProvider("p-two")
	registry.Register(&first, nil)
	registry.Register(&second, nil)

	state1 := &forwardState{slotReservationsEnabled: true}
	selected1, routeErr := s.selectProviderExcluding(context.Background(), "rid-1", poolChatReq(""), http.Header{}, nil, "2026-09-14", state1)
	if routeErr != nil {
		t.Fatalf("first selection rejected: %+v", routeErr)
	}

	state2 := &forwardState{slotReservationsEnabled: true}
	selected2, routeErr := s.selectProviderExcluding(context.Background(), "rid-2", poolChatReq(""), http.Header{}, nil, "2026-09-14", state2)
	if routeErr != nil {
		t.Fatalf("second selection rejected: %+v", routeErr)
	}
	if selected2.ProviderID == selected1.ProviderID {
		t.Fatalf("second selection reused reserved provider %q", selected1.ProviderID)
	}

	_, routeErr = s.selectProviderExcluding(context.Background(), "rid-3", poolChatReq(""), http.Header{}, nil, "2026-09-14", &forwardState{slotReservationsEnabled: true})
	if routeErr == nil || routeErr.status != http.StatusServiceUnavailable || routeErr.code != "no_provider_available" {
		t.Fatalf("third selection with all slots reserved: want 503 no_provider_available, got %+v", routeErr)
	}
}

func TestSelectProviderReleasesDirectSlotOnPreflightReject(t *testing.T) {
	s, registry, _ := poolIsolationServer(t)
	provider := poolProvider("p-one")
	registry.Register(&provider, nil)
	s.preflightThreshold = 1
	s.preflightTimeout = time.Second
	s.preflight = func(_ pool.Provider, _ string, _ int, _ time.Duration) (PreflightResult, bool, error) {
		return PreflightResult{Accepted: false, Reason: "busy"}, true, nil
	}

	state := &forwardState{slotReservationsEnabled: true}
	_, routeErr := s.selectProviderExcluding(context.Background(), "rid-1", poolChatReq(""), http.Header{}, nil, "2026-09-14", state)
	if routeErr == nil || routeErr.status != http.StatusServiceUnavailable || routeErr.code != "preflight_rejected" {
		t.Fatalf("preflight reject: want 503 preflight_rejected, got %+v", routeErr)
	}
	if state.queuedSlotProviderID != "" {
		t.Fatalf("reservation leaked after preflight rejection: %q", state.queuedSlotProviderID)
	}

	s.preflight = nil
	got, routeErr := s.selectProviderExcluding(context.Background(), "rid-2", poolChatReq(""), http.Header{}, nil, "2026-09-14", &forwardState{slotReservationsEnabled: true})
	if routeErr != nil || got.ProviderID != provider.ProviderID {
		t.Fatalf("selection after preflight release provider=%q err=%+v, want %q nil", got.ProviderID, routeErr, provider.ProviderID)
	}
}
