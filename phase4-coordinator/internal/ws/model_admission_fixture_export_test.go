package ws

import (
	"fmt"
	"net"
	"testing"
	"time"

	"github.com/augstar/macprovider-coordinator/internal/config"
	"github.com/augstar/macprovider-coordinator/internal/pool"
	"github.com/rs/zerolog"
)

// NewHTTPAdmissionTransportFixtureForTest exposes a real WS owner only to the
// external package test binary. No artifact eligibility or resolver is seeded.
func NewHTTPAdmissionTransportFixtureForTest(t *testing.T, endpoint string, conn net.Conn) (*Server, *pool.Registry, pool.Provider, func() error) {
	t.Helper()
	registry := pool.NewRegistry([]config.ProviderConfig{{ProviderID: "http-failure-provider", EndpointURL: endpoint}})
	p := pool.Provider{ProviderID: "http-failure-provider", AssignedID: "http-failure-session", ModelID: "model-a", EndpointURL: endpoint,
		InferencePath: pool.InferencePathHTTPForwarding, State: pool.StateReady, MaxContextTokens: 20000, MaxConcurrency: 1, SlotsFree: 1, SlotsTotal: 1, ThroughputTPSEstimate: 20}
	if _, ok := registry.RegisterAt(&p, conn, time.Now()); !ok {
		t.Fatal("register fixture session")
	}
	server := NewServer(config.Default(), registry, zerolog.Nop())
	session := newProviderSession(p.ProviderID, p.AssignedID, conn, 4)
	server.storeProviderSession(sessionKey(p.ProviderID, p.AssignedID), session)
	t.Cleanup(session.close)
	// Called from inside the recording socket Close: successful exclusive pins
	// prove the close publisher holds neither owner lock across socket IO.
	assertStoredAndUnpinned := func() error {
		if !server.sessionPublicationMu.TryLock() {
			return fmt.Errorf("socket Close under WS map publication pin")
		}
		defer server.sessionPublicationMu.Unlock()
		actual, ok := server.sessions.Load(sessionKey(p.ProviderID, p.AssignedID))
		if !ok || actual != session {
			return fmt.Errorf("exact stored WS session was removed or replaced")
		}
		if !session.writeMu.TryLock() {
			return fmt.Errorf("socket Close under session publication pin")
		}
		defer session.writeMu.Unlock()
		if !session.closing || session.closed {
			return fmt.Errorf("want closing publication before terminal cleanup")
		}
		return nil
	}
	return server, registry, p, assertStoredAndUnpinned
}
