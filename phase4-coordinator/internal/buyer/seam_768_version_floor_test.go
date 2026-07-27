package buyer

import (
	"testing"
	"time"

	"github.com/augstar/macprovider-coordinator/internal/pool"
	"github.com/augstar/macprovider-coordinator/internal/routing"
	"github.com/rs/zerolog"
)

const (
	floorModelID   = "mlx-community/Qwen3-Coder-30B-A3B-Instruct-4bit"
	unflooredModel = "mlx-community/Qwen2.5-7B-Instruct-4bit"
)

func versionFloorServer(t *testing.T, floors map[string]string) *Server {
	t.Helper()
	registry := pool.NewRegistry(nil)
	return NewServer(
		registry,
		zerolog.Nop(),
		time.Now().UTC(),
		WithModelVersionFloors(floors),
	)
}

func versionFloorProvider(providerID, modelID, binaryVersion string) pool.Provider {
	return pool.Provider{
		ProviderID:       providerID,
		AssignedID:       "s-" + providerID,
		ModelID:          modelID,
		BinaryVersion:    binaryVersion,
		State:            pool.StateReady,
		Tier:             pool.TierPinned,
		MaxContextTokens: 50000,
		MaxConcurrency:   1,
		SlotsTotal:       1,
		SlotsFree:        1,
		EndpointURL:      "https://" + providerID + ".example",
		InferencePath:    pool.InferencePathHTTPForwarding,
		LastHeartbeatAt:  time.Now().UTC(),
		ConnectedAt:      time.Now().UTC(),
	}
}

func versionFloorChecker(s *Server, model string) *eligibilityCtx {
	return &eligibilityCtx{s: s, model: model, estimatedTokens: 100, tier2Cfg: s.tier2Config()}
}

// TestModelVersionFloorGate is the #768 unit contract on the SHARED helper:
// same map, same verdict, in every gate.
func TestModelVersionFloorGate(t *testing.T) {
	s := versionFloorServer(t, map[string]string{floorModelID: "1.8.60"})
	for _, tc := range []struct {
		name    string
		model   string
		version string
		want    bool
	}{
		{name: "below floor excluded", model: floorModelID, version: "1.8.59", want: false},
		{name: "at floor admitted", model: floorModelID, version: "1.8.60", want: true},
		{name: "above floor admitted", model: floorModelID, version: "1.8.65", want: true},
		{name: "unfloored model untouched", model: unflooredModel, version: "0.1.0", want: true},
		// A provider reporting a version we cannot parse while a floor is in
		// force is suspect, so it fails SAFE (gated out), not open.
		{name: "malformed version fails safe", model: floorModelID, version: "1.8.65-dev", want: false},
		{name: "empty version fails safe", model: floorModelID, version: "", want: false},
	} {
		t.Run(tc.name, func(t *testing.T) {
			p := versionFloorProvider("p", tc.model, tc.version)
			if got := s.providerMeetsModelVersionFloor(p); got != tc.want {
				t.Fatalf("providerMeetsModelVersionFloor(%q@%q) = %v, want %v", tc.model, tc.version, got, tc.want)
			}
		})
	}
}

// TestModelVersionFloorExcludesFromPublicRouting covers gate 1 of 3.
func TestModelVersionFloorExcludesFromPublicRouting(t *testing.T) {
	s := versionFloorServer(t, map[string]string{floorModelID: "1.8.60"})
	providers := []pool.Provider{
		versionFloorProvider("old", floorModelID, "1.8.59"),
		versionFloorProvider("new", floorModelID, "1.8.65"),
	}
	res := routing.EligibleCandidates(
		providers,
		routing.NewExcluded(0),
		pool.Provider.SortKey,
		versionFloorChecker(s, floorModelID),
	)
	if len(res.Eligible) != 1 || res.Eligible[0].ProviderID != "new" {
		t.Fatalf("eligible = %+v, want only the above-floor provider", res.Eligible)
	}
	if got := res.Counts[routing.ReasonModelVersionFloor]; got != 1 {
		t.Fatalf("ReasonModelVersionFloor count = %d, want 1 (counts=%v)", got, res.Counts)
	}
}

// TestModelVersionFloorExcludesFromSelfRoutePreflight covers gate 2 of 3: the
// pinned / self-route path bypasses routing.EligibleCandidates entirely, so it
// must re-apply the floor or a hard pin is a hole through the public gate.
func TestModelVersionFloorExcludesFromSelfRoutePreflight(t *testing.T) {
	s := versionFloorServer(t, map[string]string{floorModelID: "1.8.60"})
	old := versionFloorProvider("old", floorModelID, "1.8.59")
	_, routeErr := s.validatePinnedProviderForRequest(old, floorModelID, 100, "Pinned provider not available", nil)
	if routeErr == nil {
		t.Fatal("validatePinnedProviderForRequest accepted a below-floor pinned provider")
	}
	if routeErr.code != "model_version_floor_unmet" {
		t.Fatalf("route error code = %q, want model_version_floor_unmet", routeErr.code)
	}
	if routeErr.status != 503 {
		t.Fatalf("route error status = %d, want 503", routeErr.status)
	}

	fresh := versionFloorProvider("new", floorModelID, "1.8.65")
	if _, routeErr := s.validatePinnedProviderForRequest(fresh, floorModelID, 100, "Pinned provider not available", nil); routeErr != nil {
		t.Fatalf("above-floor pinned provider rejected: %+v", routeErr)
	}
}

// TestModelVersionFloorExcludesFromSlotQueue covers the slot queue, which
// re-derives the public routing gate list by hand.
func TestModelVersionFloorExcludesFromSlotQueue(t *testing.T) {
	s := versionFloorServer(t, map[string]string{floorModelID: "1.8.60"})
	busy := func(providerID, version string) pool.Provider {
		p := versionFloorProvider(providerID, floorModelID, version)
		p.SlotsFree = 0 // slot-queue eligibility requires a saturated provider
		return p
	}
	providers := []pool.Provider{busy("old", "1.8.59"), busy("new", "1.8.65")}
	got := s.slotQueueCandidates(providers, routing.NewExcluded(0), versionFloorChecker(s, floorModelID))
	if len(got) != 1 || got[0].ProviderID != "new" {
		t.Fatalf("slotQueueCandidates = %+v, want only the above-floor provider", got)
	}
}

// TestModelVersionFloorUnconfiguredIsByteIdentical is the default-posture
// guarantee: with no floors configured, every gate behaves exactly as it did
// before #768 — including for a provider whose version is unparseable.
func TestModelVersionFloorUnconfiguredIsByteIdentical(t *testing.T) {
	s := versionFloorServer(t, nil)
	providers := []pool.Provider{
		versionFloorProvider("ancient", floorModelID, "0.1.0"),
		versionFloorProvider("garbled", floorModelID, "not-a-version"),
		versionFloorProvider("blank", floorModelID, ""),
	}
	res := routing.EligibleCandidates(
		providers,
		routing.NewExcluded(0),
		pool.Provider.SortKey,
		versionFloorChecker(s, floorModelID),
	)
	if len(res.Eligible) != len(providers) {
		t.Fatalf("eligible = %d, want all %d (unconfigured floors must not filter)", len(res.Eligible), len(providers))
	}
	if got := res.Counts[routing.ReasonModelVersionFloor]; got != 0 {
		t.Fatalf("ReasonModelVersionFloor count = %d, want 0", got)
	}
	for _, p := range providers {
		if _, routeErr := s.validatePinnedProviderForRequest(p, floorModelID, 100, "unavailable", nil); routeErr != nil {
			t.Fatalf("pinned %q rejected with no floors configured: %+v", p.ProviderID, routeErr)
		}
	}
}

// TestModelVersionFloorErrorCodeIsClassified keeps the new buyer-visible code
// inside the SPEC-006 §5.2 retryability contract the AST guard enforces.
func TestModelVersionFloorErrorCodeIsClassified(t *testing.T) {
	if !spec018Retryable("model_version_floor_unmet") {
		t.Fatal("model_version_floor_unmet must be retryable=true: the fleet self-updates, so the same request can succeed later")
	}
}

// TestModelVersionFloorRecheckedAtSlotQueuePoll pins the #768 audit R1
// finding (security+architect MEDIUM): the waiter stores only providerID, so
// the provider polled off the queue may not be the one that passed
// slotQueueCandidates — a same-ID reconnect below the per-model floor must
// terminate the wait (model_version_floor_unmet path), never be served.
func TestModelVersionFloorRecheckedAtSlotQueuePoll(t *testing.T) {
	registry := pool.NewRegistry(nil)
	s := NewServer(
		registry,
		zerolog.Nop(),
		time.Now().UTC(),
		WithModelVersionFloors(map[string]string{floorModelID: "1.8.60"}),
	)
	// The provider now registered under the queued ID is BELOW the floor —
	// the same-ID-reconnect shape.
	below := versionFloorProvider("p-queued", floorModelID, "1.8.50")
	registry.Register(&below, nil)

	waiter, ok := s.slotQueue.enter("p-queued")
	if !ok {
		t.Fatal("enter returned no waiter")
	}
	defer s.slotQueue.leave(waiter)

	_, status := s.pollQueuedProvider(waiter, floorModelID, nil, 100)
	if status != queuedProviderTerminal {
		t.Fatalf("pollQueuedProvider status = %v, want terminal — a below-floor same-ID "+
			"replacement must not be served off the slot queue", status)
	}

	// Control: the same poll serves an above-floor provider.
	registry2 := pool.NewRegistry(nil)
	s2 := NewServer(registry2, zerolog.Nop(), time.Now().UTC(),
		WithModelVersionFloors(map[string]string{floorModelID: "1.8.60"}))
	above := versionFloorProvider("p-queued", floorModelID, "1.8.65")
	registry2.Register(&above, nil)
	w2, _ := s2.slotQueue.enter("p-queued")
	defer s2.slotQueue.leave(w2)
	got, status2 := s2.pollQueuedProvider(w2, floorModelID, nil, 100)
	if status2 != queuedProviderAvailable || got.ProviderID != "p-queued" {
		t.Fatalf("control poll = (%q, %v), want the above-floor provider available", got.ProviderID, status2)
	}
}
