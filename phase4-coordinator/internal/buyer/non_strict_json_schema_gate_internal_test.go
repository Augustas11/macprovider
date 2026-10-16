package buyer

import (
	"context"
	"net/http"
	"testing"
	"time"

	"github.com/rs/zerolog"

	"github.com/augstar/macprovider-coordinator/internal/pool"
)

const nonStrictInternalBody = `{"model":"model-a","messages":[{"role":"user","content":"hi"}],"response_format":{"type":"json_schema","json_schema":{"name":"person","strict":false,"schema":{"type":"object"}}}}`

func nonStrictInternalRequest(t *testing.T) chatRequest {
	t.Helper()
	req, status, code, msg, _ := validateChatRequestDetailed([]byte(nonStrictInternalBody))
	if status != 0 || req.nonStrictSchemaLegacyRejection == nil {
		t.Fatalf("validate status=%d code=%s msg=%s legacy=%v", status, code, msg, req.nonStrictSchemaLegacyRejection)
	}
	return req
}

// SPEC-019 §1a: the slot queue stores only a provider ID, so a same-ID
// reconnect on a CLI without non-strict support is terminal for the waiter.
func TestNonStrictJSONSchemaRecheckedAtSlotQueuePoll(t *testing.T) {
	for _, tc := range []struct {
		binary string
		want   queuedProviderStatus
	}{
		{"1.8.240", queuedProviderTerminal},
		{"1.8.242-dev", queuedProviderTerminal},
		{"1.8.242", queuedProviderAvailable},
	} {
		t.Run(tc.binary, func(t *testing.T) {
			registry := pool.NewRegistry(nil)
			s := NewServer(registry, zerolog.Nop(), time.Now().UTC())
			provider := versionFloorProvider("p-queued", "model-a", tc.binary)
			registry.Register(&provider, nil)
			waiter, ok := s.slotQueue.enter("p-queued")
			if !ok {
				t.Fatal("enter returned no waiter")
			}
			defer s.slotQueue.leave(waiter)
			state := &forwardState{nonStrictJSONSchema: true}
			if _, status := s.pollQueuedProvider(waiter, "model-a", nil, 100, state); status != tc.want {
				t.Fatalf("poll status = %v, want %v", status, tc.want)
			}
		})
	}
}

// A pin to an incapable provider gets the legacy 400; a pin to a provider of
// another model keeps its existing error.
func TestNonStrictJSONSchemaPinnedProvider(t *testing.T) {
	registry := pool.NewRegistry(nil)
	s := NewServer(registry, zerolog.Nop(), time.Now().UTC())
	old := versionFloorProvider("p-old", "model-a", "1.8.240")
	other := versionFloorProvider("p-other", "model-b", "1.8.240")
	registry.Register(&old, nil)
	registry.Register(&other, nil)
	req := nonStrictInternalRequest(t)
	for _, tc := range []struct {
		header, value, wantCode string
	}{
		{"X-MacProvider-Provider", "p-old", "json_schema_non_strict_unsupported"},
		{"X-MacProvider-Session", "s-p-old", "json_schema_non_strict_unsupported"},
	} {
		headers := http.Header{}
		headers.Set(tc.header, tc.value)
		_, routeErr := s.selectProviderExcluding(context.Background(), "rid", req, headers, nil, "2024-01-01", &forwardState{})
		if routeErr == nil || routeErr.status != http.StatusBadRequest || routeErr.code != tc.wantCode {
			t.Fatalf("%s pin: got %+v, want 400 %s", tc.header, routeErr, tc.wantCode)
		}
	}
	headers := http.Header{}
	headers.Set("X-MacProvider-Provider", "p-other")
	_, routeErr := s.selectProviderExcluding(context.Background(), "rid", req, headers, nil, "2024-01-01", &forwardState{})
	if routeErr == nil || routeErr.code == "json_schema_non_strict_unsupported" {
		t.Fatalf("wrong-model pin: got %+v, want the existing pinned-model error", routeErr)
	}
}
