package buyer_test

import (
	"bytes"
	"context"
	"encoding/json"
	"errors"
	"net"
	"net/http"
	"net/http/httptest"
	"strings"
	"sync"
	"testing"
	"time"

	"github.com/augstar/macprovider-coordinator/internal/buyer"
	"github.com/augstar/macprovider-coordinator/internal/config"
	"github.com/augstar/macprovider-coordinator/internal/pool"
	providerws "github.com/augstar/macprovider-coordinator/internal/ws"
	gobwas "github.com/gobwas/ws"
	"github.com/gobwas/ws/wsutil"
	"github.com/rs/zerolog"
)

type observedAdmissionStore struct {
	providerws.ModelAdmissionStore
	failRevocations bool
	mu              sync.Mutex
	attempts        []providerws.ModelAdmissionEvent
	committed       []providerws.ModelAdmissionEvent
}

func (s *observedAdmissionStore) recordCommitted(event providerws.ModelAdmissionEvent) {
	s.mu.Lock()
	s.committed = append(s.committed, event)
	s.mu.Unlock()
}

func (s *observedAdmissionStore) AppendModelAdmissionOffer(ctx context.Context, event providerws.ModelAdmissionEvent) (providerws.ModelAdmissionEvent, bool, error) {
	stored, replay, err := s.ModelAdmissionStore.AppendModelAdmissionOffer(ctx, event)
	if err == nil && !replay {
		s.recordCommitted(stored)
	}
	return stored, replay, err
}

func (s *observedAdmissionStore) AppendModelAdmissionDecision(ctx context.Context, event providerws.ModelAdmissionEvent) (providerws.ModelAdmissionEvent, error) {
	s.mu.Lock()
	s.attempts = append(s.attempts, event)
	s.mu.Unlock()
	if s.failRevocations && event.State == "revoked" {
		return providerws.ModelAdmissionEvent{}, errors.New("injected revocation failure")
	}
	stored, err := s.ModelAdmissionStore.AppendModelAdmissionDecision(ctx, event)
	if err == nil {
		s.recordCommitted(stored)
	}
	return stored, err
}

func (s *observedAdmissionStore) AppendGuardedModelAdmissionDecision(ctx context.Context, event providerws.ModelAdmissionEvent, guard providerws.ModelAdmissionCommitGuard) (providerws.ModelAdmissionEvent, error) {
	guarded, ok := s.ModelAdmissionStore.(interface {
		AppendGuardedModelAdmissionDecision(context.Context, providerws.ModelAdmissionEvent, providerws.ModelAdmissionCommitGuard) (providerws.ModelAdmissionEvent, error)
	})
	if !ok {
		return providerws.ModelAdmissionEvent{}, errors.New("guarded append unavailable")
	}
	stored, err := guarded.AppendGuardedModelAdmissionDecision(ctx, event, guard)
	if err == nil {
		s.recordCommitted(stored)
	}
	return stored, err
}

func (s *observedAdmissionStore) revocationAttempts() []providerws.ModelAdmissionEvent {
	s.mu.Lock()
	defer s.mu.Unlock()
	var out []providerws.ModelAdmissionEvent
	for _, event := range s.attempts {
		if event.State == "revoked" {
			out = append(out, event)
		}
	}
	return out
}

func (s *observedAdmissionStore) committedStates() []string {
	s.mu.Lock()
	defer s.mu.Unlock()
	states := make([]string, len(s.committed))
	for i, event := range s.committed {
		states[i] = event.State
	}
	return states
}

func newObservedAdmissionStore(t *testing.T, kind string, failRevocations bool) *observedAdmissionStore {
	t.Helper()
	var base providerws.ModelAdmissionStore
	switch kind {
	case "memory":
		base = providerws.NewMemoryModelAdmissionStore()
	case "sqlite":
		reqLog, _ := openBuyerRequestLog(t)
		t.Cleanup(func() { _ = reqLog.Close() })
		store, err := providerws.NewSQLiteModelAdmissionStore(reqLog.DB())
		if err != nil {
			t.Fatal(err)
		}
		base = store
	default:
		t.Fatalf("unknown admission store %q", kind)
	}
	return &observedAdmissionStore{ModelAdmissionStore: base, failRevocations: failRevocations}
}

func seedTransportAuthority(t *testing.T, s *buyer.Server, store *observedAdmissionStore, p pool.Provider, e providerws.ModelAdmissionEvent) providerws.ModelAdmissionEvent {
	return seedTransportAuthorityNamed(t, s, store, p, e, "transport")
}

func seedTransportAuthorityNamed(t *testing.T, s *buyer.Server, store *observedAdmissionStore, p pool.Provider, e providerws.ModelAdmissionEvent, prefix string) providerws.ModelAdmissionEvent {
	t.Helper()
	e.RequestID = prefix + "-offer"
	e.Nonce = prefix + "-offer"
	e.PayloadDigestSHA256 = strings.Repeat("d", 64)
	e, _, err := store.AppendModelAdmissionOffer(context.Background(), e)
	if err != nil {
		t.Fatal(err)
	}
	for _, state := range []string{"catalog_priced", "settlement_capable"} {
		a, err := s.PrepareModelAdmissionAuthority(context.Background(), p, e)
		if err != nil {
			t.Fatal(err)
		}
		a.Event.ExpectedCurrentEventID = e.CoordinatorEventID
		a.Event.State = state
		a.Event.RequestID = prefix + "-" + state
		a.Event.Nonce = prefix + "-" + state
		a.Event.PayloadDigestSHA256 = strings.Repeat("e", 64)
		e, err = store.AppendGuardedModelAdmissionDecision(context.Background(), a.Event, a.TryPin)
		if err != nil {
			t.Fatal(err)
		}
	}
	return e
}

// A real accepted WS socket remains open behind Close until the route assertion
// finishes; read-loop/registry cleanup cannot manufacture the negative result.
type routeCloseBarrier struct {
	entered     chan struct{}
	allow       chan struct{}
	once        sync.Once
	releaseOnce sync.Once
}

func (b *routeCloseBarrier) release() { b.releaseOnce.Do(func() { close(b.allow) }) }

type routeBarrierConn struct {
	net.Conn
	barrier *routeCloseBarrier
}

func (c *routeBarrierConn) Close() error {
	c.barrier.once.Do(func() { close(c.barrier.entered) })
	<-c.barrier.allow
	return c.Conn.Close()
}

type routeBarrierListener struct {
	net.Listener
	barrier *routeCloseBarrier
}

func (l routeBarrierListener) Accept() (net.Conn, error) {
	c, e := l.Listener.Accept()
	if e != nil {
		return nil, e
	}
	return &routeBarrierConn{Conn: c, barrier: l.barrier}, nil
}

func realPrimaryRouteTransport(t *testing.T, registry *pool.Registry, original pool.Provider) (*providerws.Server, pool.Provider, *routeCloseBarrier, func() pool.Provider) {
	t.Helper()
	cfg := config.Default()
	cfg.Auth.RequireProviderTokens = false
	cfg.Pool.WarmupGateEnabled = false
	cfg.Providers = []config.ProviderConfig{{ProviderID: original.ProviderID, EndpointURL: "https://fixture.invalid"}}
	owner := providerws.NewServer(cfg, registry, zerolog.Nop())
	barrier := &routeCloseBarrier{entered: make(chan struct{}), allow: make(chan struct{})}
	httpServer := httptest.NewUnstartedServer(owner.Handler())
	httpServer.Listener = routeBarrierListener{Listener: httpServer.Listener, barrier: barrier}
	httpServer.Start()
	t.Cleanup(func() { barrier.release(); owner.CloseAllProviderSessions("fixture cleanup"); httpServer.Close() })
	connect := func() pool.Provider {
		conn, _, _, err := gobwas.Dial(context.Background(), "ws"+strings.TrimPrefix(httpServer.URL, "http")+"/ws/provider")
		if err != nil {
			t.Fatal(err)
		}
		t.Cleanup(func() { conn.Close() })
		_ = conn.SetDeadline(time.Now().Add(2 * time.Second))
		hello := map[string]any{"type": "hello", "version": 1, "tier": 1, "provider_id": original.ProviderID, "hostname": "fixture.local", "model_id": original.ModelID, "model_params_b": 7.0, "ram_gb": 16, "max_context_tokens": 100000, "max_concurrency": 1, "throughput_tps_estimate": 20, "binary_version": "0.1.0", "attestation": nil}
		raw, _ := json.Marshal(hello)
		if err := wsutil.WriteClientText(conn, raw); err != nil {
			t.Fatal(err)
		}
		raw, _, err = wsutil.ReadServerData(conn)
		if err != nil {
			t.Fatal(err)
		}
		var ack providerws.HelloAck
		if err := json.Unmarshal(raw, &ack); err != nil || ack.AssignedID == "" {
			t.Fatalf("real handshake: %s %v", raw, err)
		}
		_ = conn.SetDeadline(time.Time{})
		current := original
		current.AssignedID = ack.AssignedID
		current.MaxContextTokens = 100000
		liveConn, err := registry.Conn(current.ProviderID, current.AssignedID)
		if err != nil {
			t.Fatal(err)
		}
		if _, ok := registry.Register(&current, liveConn); !ok {
			t.Fatal("restore independently verified fixture metadata")
		}
		registry.ApplyStateUpdate(current.ProviderID, current.AssignedID, pool.StateUpdate{State: pool.StateReady})
		current, _ = registry.Resolve(current.ProviderID, current.AssignedID)
		if !owner.ModelAdmissionSessionAvailable(current.ProviderID, current.AssignedID) {
			t.Fatal("real WS not available after handshake")
		}
		return current
	}
	return owner, connect(), barrier, connect
}

type transportRouteFixture struct {
	server    *buyer.Server
	registry  *pool.Registry
	owner     *providerws.Server
	provider  pool.Provider
	positive  providerws.ModelAdmissionEvent
	seedEvent providerws.ModelAdmissionEvent
	store     *observedAdmissionStore
	barrier   *routeCloseBarrier
	reconnect func() pool.Provider
	options   []buyer.Option
}

func newTransportRouteFixture(t *testing.T, storeKind string, failRevocations bool) *transportRouteFixture {
	t.Helper()
	var registry *pool.Registry
	_, p, event, feeds, rewards, billingStore := primaryAdmissionFixture(t, &registry)
	owner, p, barrier, reconnect := realPrimaryRouteTransport(t, registry, p)
	options := []buyer.Option{
		buyer.WithAutotuneFeeds(feeds),
		buyer.WithBilling(billingStore, rewards),
		buyer.WithBillingSnapshotID(1),
		buyer.WithModelAdmissionTransport(owner.ModelAdmissionSessionAvailable, owner.CloseModelAdmissionTransport),
	}
	authorityServer := buyer.NewServer(registry, zerolog.Nop(), time.Now(), options...)
	store := newObservedAdmissionStore(t, storeKind, failRevocations)
	positive := seedTransportAuthority(t, authorityServer, store, p, event)
	options = append(options,
		buyer.WithBillingSnapshotID(positive.ArtifactAdmissionEvidence.ConfigSnapshotID),
		buyer.WithModelAdmissionStore(store),
	)
	return &transportRouteFixture{
		server:   buyer.NewServer(registry, zerolog.Nop(), time.Now(), options...),
		registry: registry, owner: owner, provider: p, positive: positive,
		seedEvent: event, store: store, barrier: barrier, reconnect: reconnect,
		options: options,
	}
}

func (f *transportRouteFixture) assertLiveInputs(t *testing.T, wantTransport bool) {
	t.Helper()
	live, ok := f.registry.Resolve(f.provider.ProviderID, f.provider.AssignedID)
	if !ok || (live.State != pool.StateReady && live.State != pool.StateBusy) {
		t.Fatalf("registry tuple unavailable: found=%v state=%q", ok, live.State)
	}
	if _, err := f.registry.Conn(f.provider.ProviderID, f.provider.AssignedID); err != nil {
		t.Fatalf("registry connection unavailable: %v", err)
	}
	if live.ModelID != f.provider.ModelID || live.ModelHash != f.provider.ModelHash || live.CandidateCatalogSHA256 != f.provider.CandidateCatalogSHA256 || live.CandidateRowIdentity != f.provider.CandidateRowIdentity {
		t.Fatal("captured provider authority drifted")
	}
	evidence := f.positive.ArtifactAdmissionEvidence
	if evidence == nil || evidence.ProviderSessionID != f.provider.AssignedID || evidence.AuthorityExpiresAtUnixMS <= time.Now().UnixMilli() || evidence.ProbeExpiresAtUnixMS <= time.Now().UnixMilli() {
		t.Fatal("captured admission leases or exact session are invalid")
	}
	if got := f.owner.ModelAdmissionSessionAvailable(f.provider.ProviderID, f.provider.AssignedID); got != wantTransport {
		t.Fatalf("transport available=%v want=%v", got, wantTransport)
	}
}

func (f *transportRouteFixture) beginClosing(t *testing.T) {
	t.Helper()
	done := make(chan struct{})
	go func() {
		_ = f.owner.CloseModelAdmissionTransport(f.provider.ProviderID, f.provider.AssignedID, "fixture closing")
		close(done)
	}()
	select {
	case <-f.barrier.entered:
	case <-time.After(time.Second):
		t.Fatal("real socket close boundary absent")
	}
	t.Cleanup(func() { f.barrier.release(); <-done })
	// Readiness is reversible and must not erase monotonic WS closing state.
	f.registry.ApplyStateUpdate(f.provider.ProviderID, f.provider.AssignedID, pool.StateUpdate{State: pool.StateReady})
	f.assertLiveInputs(t, false)
	latest, found, err := f.store.LatestModelAdmissionStatus(context.Background(), f.positive.ProviderID, f.positive.CandidateID)
	if err != nil || !found || latest.CoordinatorEventID != f.positive.CoordinatorEventID || latest.State != "settlement_capable" {
		t.Fatalf("historical positive changed before route call: found=%v state=%q err=%v", found, latest.State, err)
	}
}

func assertRevocationAttempt(t *testing.T, f *transportRouteFixture, wantCommitted bool) {
	t.Helper()
	attempts := f.store.revocationAttempts()
	if len(attempts) == 0 {
		t.Fatal("revocation was not attempted")
	}
	for _, attempt := range attempts {
		if attempt.ExpectedCurrentEventID != f.positive.CoordinatorEventID || attempt.ProviderID != f.positive.ProviderID || attempt.CandidateID != f.positive.CandidateID {
			t.Fatalf("revocation CAS/tuple mismatch: %+v", attempt)
		}
	}
	latest, found, err := f.store.LatestModelAdmissionStatus(context.Background(), f.positive.ProviderID, f.positive.CandidateID)
	if err != nil || !found {
		t.Fatalf("fresh readback: found=%v err=%v", found, err)
	}
	if wantCommitted {
		if len(attempts) != 1 {
			t.Fatalf("successful revocation attempts=%d want=1", len(attempts))
		}
		if latest.State != "revoked" || latest.ExpectedCurrentEventID != f.positive.CoordinatorEventID {
			t.Fatalf("latest=%q expected=%q", latest.State, latest.ExpectedCurrentEventID)
		}
		want := []string{"offer_submitted", "catalog_priced", "settlement_capable", "revoked"}
		got := f.store.committedStates()
		if strings.Join(got, ",") != strings.Join(want, ",") {
			t.Fatalf("complete history=%v want=%v", got, want)
		}
		return
	}
	if latest.CoordinatorEventID != f.positive.CoordinatorEventID || latest.State != "settlement_capable" {
		t.Fatal("revocation failure did not retain the exact positive event")
	}
}

func TestArtifactRouteRejectsClosingBeforeReadback(t *testing.T) {
	paths := []string{
		"direct resolver",
		"direct binding",
		"require binding",
		"actual selectProvider default",
		"actual selectProvider pinned",
		"queue poll",
	}
	for _, storeKind := range []string{"memory", "sqlite"} {
		for _, path := range paths {
			t.Run(storeKind+"/"+path, func(t *testing.T) {
				f := newTransportRouteFixture(t, storeKind, true)
				f.beginClosing(t)
				buyer.AssertArtifactRoutePathsWithEventForTest(t, f.server, f.provider, f.positive, false, path)
				if path == "direct resolver" {
					if got := len(f.store.revocationAttempts()); got != 0 {
						t.Fatalf("direct resolver unexpectedly attempted %d revocations", got)
					}
					return
				}
				assertRevocationAttempt(t, f, false)
			})
		}
	}
}

func TestArtifactPaidSelectionRejectsClosingBeforeReadback(t *testing.T) {
	for _, storeKind := range []string{"memory", "sqlite"} {
		for _, path := range []string{"direct binding", "actual selectProvider default", "actual selectProvider pinned"} {
			t.Run(storeKind+"/"+path, func(t *testing.T) {
				f := newTransportRouteFixture(t, storeKind, false)
				f.beginClosing(t)
				buyer.AssertArtifactRoutePathsWithEventForTest(t, f.server, f.provider, f.positive, false, path)
				assertRevocationAttempt(t, f, true)
				buyer.AssertArtifactRoutePathsWithEventForTest(t, f.server, f.provider, f.positive, false, path)
			})
		}
	}
}

func TestArtifactPaidSelectionNoDrift(t *testing.T) {
	for _, storeKind := range []string{"memory", "sqlite"} {
		for _, path := range []string{"actual selectProvider default", "actual selectProvider pinned"} {
			t.Run(storeKind+"/"+path, func(t *testing.T) {
				f := newTransportRouteFixture(t, storeKind, false)
				f.assertLiveInputs(t, true)
				buyer.AssertArtifactRoutePathsWithEventForTest(t, f.server, f.provider, f.positive, true, path)
				if got := len(f.store.revocationAttempts()); got != 0 {
					t.Fatalf("positive control attempted %d revocations", got)
				}
			})
		}
	}
}

func TestArtifactRouteMissingTransportWiring(t *testing.T) {
	for _, missing := range []string{"read", "close"} {
		for _, path := range []string{"direct resolver", "direct binding", "actual selectProvider default", "actual selectProvider pinned"} {
			t.Run(missing+"/"+path, func(t *testing.T) {
				f := newTransportRouteFixture(t, "memory", true)
				available := f.owner.ModelAdmissionSessionAvailable
				closeTransport := f.owner.CloseModelAdmissionTransport
				if missing == "read" {
					available = nil
				} else {
					closeTransport = nil
				}
				// Rebuild only the transport wiring; all signed/store/billing owners remain identical.
				f.server = buyer.NewServer(f.registry, zerolog.Nop(), time.Now(),
					buyer.WithModelAdmissionStore(f.store),
					buyer.WithModelAdmissionTransport(available, closeTransport),
				)
				if f.server.ModelAdmissionAuthorityReady() {
					t.Fatal("partial transport constructor enabled artifact authority")
				}
				buyer.AssertArtifactRoutePathsWithEventForTest(t, f.server, f.provider, f.positive, false, path)
			})
		}
	}
}

func TestArtifactRouteReplacementEventRejectsStaleRevocation(t *testing.T) {
	for _, storeKind := range []string{"memory", "sqlite"} {
		t.Run(storeKind, func(t *testing.T) {
			f := newTransportRouteFixture(t, storeKind, false)
			oldProvider, oldPositive := f.provider, f.positive
			f.beginClosing(t)
			buyer.AssertArtifactRoutePathsWithEventForTest(t, f.server, oldProvider, oldPositive, false, "direct binding")
			assertRevocationAttempt(t, f, true)

			// Finish only the old socket close, then establish an independently
			// accepted replacement and re-offer the same candidate.
			f.barrier.release()
			f.provider = f.reconnect()
			if f.owner.ModelAdmissionSessionAvailable(oldProvider.ProviderID, oldProvider.AssignedID) {
				t.Fatal("old exact session remained available after replacement")
			}
			if !f.owner.ModelAdmissionSessionAvailable(f.provider.ProviderID, f.provider.AssignedID) {
				t.Fatal("replacement exact session unavailable")
			}
			replacementSeed := f.seedEvent
			replacementSeed.DiscoveryDigestSHA256 = strings.Repeat("6", 64)
			replacementSeed.EvaluationDigestSHA256 = strings.Repeat("7", 64)
			replacement := seedTransportAuthorityNamed(t, f.server, f.store, f.provider, replacementSeed, "replacement")
			f.positive = replacement
			f.assertLiveInputs(t, true)
			buyer.AssertArtifactRoutePathsWithEventForTest(t, f.server, f.provider, replacement, true, "actual selectProvider pinned")

			// Delayed old readback work may replay its already-committed old
			// revocation, but it must not append again or revoke the newer event.
			if _, err := f.store.AppendModelAdmissionDecision(context.Background(), providerws.ModelAdmissionAuthorityRevocation(oldPositive, time.Now())); err != nil {
				t.Fatalf("old revocation replay: %v", err)
			}
			stale := providerws.ModelAdmissionAuthorityRevocation(oldPositive, time.Now())
			stale.RequestID += "_stale"
			stale.Nonce += "_stale"
			stale.PayloadDigestSHA256 = strings.Repeat("5", 64)
			if _, err := f.store.AppendModelAdmissionDecision(context.Background(), stale); err == nil {
				t.Fatal("distinct stale old-session CAS unexpectedly committed")
			}
			latest, found, err := f.store.LatestModelAdmissionStatus(context.Background(), replacement.ProviderID, replacement.CandidateID)
			if err != nil || !found || latest.CoordinatorEventID != replacement.CoordinatorEventID || latest.State != "settlement_capable" {
				t.Fatalf("replacement event lost after stale CAS: found=%v state=%q id=%q err=%v", found, latest.State, latest.CoordinatorEventID, err)
			}
			buyer.AssertArtifactRoutePathsWithEventForTest(t, f.server, f.provider, replacement, true, "actual selectProvider default")
		})
	}
}

func TestArtifactRouteObservationReleasesPinsBeforeDispatch(t *testing.T) {
	f := newTransportRouteFixture(t, "sqlite", false)
	f.assertLiveInputs(t, true)
	reqLog, _ := openBuyerRequestLog(t)
	t.Cleanup(func() { _ = reqLog.Close() })
	dispatchEntered := make(chan struct{})
	releaseDispatch := make(chan struct{})
	options := append([]buyer.Option(nil), f.options...)
	blockingRelay := func(context.Context, pool.Provider, string, []byte, bool, *providerws.SettlementReceiptMetadata) (*providerws.RelayStream, error) {
		close(dispatchEntered)
		<-releaseDispatch
		return nil, providerws.ErrRelayClosed
	}
	options = append(options,
		buyer.WithRequestLog(reqLog),
		buyer.WithGatewayServiceToken("fixture-gateway"),
		buyer.WithAdmission(providerws.NewAdmissionManager(config.Default().Admission, time.Now), 0.3),
		buyer.WithRelay(func(context.Context, pool.Provider, string, []byte, bool) (*providerws.RelayStream, error) {
			return nil, errors.New("unexpected non-settlement relay")
		}, time.Second),
		buyer.WithSettlementRelay(blockingRelay),
	)
	server := buyer.NewServer(f.registry, zerolog.Nop(), time.Now(), options...)
	body := []byte(`{"model":"mlx-community/Test-Model-4bit","messages":[{"role":"user","content":"hello"}]}`)
	req := httptest.NewRequest(http.MethodPost, "/v1/chat/completions", bytes.NewReader(body))
	req.Header.Set("Content-Type", "application/json")
	req.Header.Set("Authorization", "Bearer fixture-gateway")
	req.Header.Set("X-MacProvider-Account", "fixture-account")
	rr := httptest.NewRecorder()
	handlerDone := make(chan struct{})
	go func() {
		server.Handler().ServeHTTP(rr, req)
		close(handlerDone)
	}()
	select {
	case <-dispatchEntered:
		// The settlement relay is reachable only after route-snapshot
		// persistence, so route observation and its durable write completed.
	case <-handlerDone:
		t.Fatalf("paid route stopped before dispatch: status=%d body=%s", rr.Code, rr.Body.String())
	case <-time.After(2 * time.Second):
		t.Fatal("paid route did not reach the blocked dispatch boundary")
	}

	closeDone := make(chan struct{})
	go func() {
		_ = f.owner.CloseModelAdmissionTransport(f.provider.ProviderID, f.provider.AssignedID, "dispatch barrier")
		close(closeDone)
	}()
	select {
	case <-f.barrier.entered:
		if f.owner.ModelAdmissionSessionAvailable(f.provider.ProviderID, f.provider.AssignedID) {
			t.Fatal("closing publication was not visible while dispatch remained blocked")
		}
	case <-time.After(time.Second):
		t.Fatal("closing publication was blocked by downstream dispatch")
	}
	latest, found, err := f.store.LatestModelAdmissionStatus(context.Background(), f.positive.ProviderID, f.positive.CandidateID)
	if err != nil || !found || latest.CoordinatorEventID != f.positive.CoordinatorEventID {
		t.Fatalf("closing relied on downstream readback: found=%v id=%q err=%v", found, latest.CoordinatorEventID, err)
	}
	close(releaseDispatch)
	f.barrier.release()
	select {
	case <-closeDone:
	case <-time.After(time.Second):
		t.Fatal("socket close did not finish")
	}
	select {
	case <-handlerDone:
	case <-time.After(2 * time.Second):
		t.Fatal("buyer request did not finish")
	}
}
