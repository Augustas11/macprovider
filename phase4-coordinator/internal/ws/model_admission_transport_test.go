package ws

import (
	"context"
	"encoding/base64"
	"encoding/json"
	"errors"
	"net"
	"net/http/httptest"
	"runtime"
	"strings"
	"sync"
	"sync/atomic"
	"testing"
	"time"

	"github.com/augstar/macprovider-coordinator/internal/config"
	"github.com/augstar/macprovider-coordinator/internal/onboarding"
	"github.com/augstar/macprovider-coordinator/internal/pool"
	"github.com/augstar/macprovider-coordinator/internal/providerevents"
	"github.com/augstar/macprovider-coordinator/internal/tier2"
	gobwas "github.com/gobwas/ws"
	"github.com/gobwas/ws/wsutil"
	"github.com/rs/zerolog"
)

type admissionCloseConn struct {
	net.Conn
	closed       chan struct{}
	once         sync.Once
	failWrite    atomic.Bool
	failRead     atomic.Bool
	writeHookMu  sync.RWMutex
	beforeWrite  func()
	releaseWrite func()
	onClose      func()
}

func (c *admissionCloseConn) Close() error {
	if c.onClose != nil {
		c.onClose()
	}
	c.once.Do(func() { close(c.closed) })
	c.writeHookMu.RLock()
	release := c.releaseWrite
	c.writeHookMu.RUnlock()
	if release != nil {
		release()
	}
	return c.Conn.Close()
}
func (c *admissionCloseConn) Read(p []byte) (int, error) {
	if c.failRead.Load() {
		return 0, errors.New("deterministic read failure")
	}
	return c.Conn.Read(p)
}
func (c *admissionCloseConn) Write(p []byte) (int, error) {
	if c.failWrite.Load() {
		return 0, errors.New("deterministic writer failure")
	}
	c.writeHookMu.RLock()
	before := c.beforeWrite
	c.writeHookMu.RUnlock()
	if before != nil {
		before()
	}
	return c.Conn.Write(p)
}

type admissionProducer func(*testing.T, *Server, pool.Provider, *providerSession, *admissionCloseConn)

var admissionProducers = map[string]admissionProducer{
	"operatorReject": func(t *testing.T, s *Server, p pool.Provider, ps *providerSession, c *admissionCloseConn) {
		s.cfg.Auth.OperatorKey = "fixture-operator"
		r := httptest.NewRequest("POST", "/admin/reject/"+p.ProviderID, strings.NewReader(`{"reason":"fixture"}`))
		r.Header.Set("Authorization", "Bearer fixture-operator")
		w := httptest.NewRecorder()
		s.handleAdminReject(w, r)
		if w.Code != 200 {
			t.Errorf("reject: %d %s", w.Code, w.Body.String())
		}
	},
	"trustRevalidation": func(t *testing.T, s *Server, p pool.Provider, ps *providerSession, c *admissionCloseConn) {
		s.disconnectAdmittedSessionForTrustRevalidation(admittedProviderSession{tuple: onboarding.AdmittedTuple{ProviderID: p.ProviderID}, assignedID: p.AssignedID}, "fixture")
	},
	"tier2RekeyFailure": func(t *testing.T, s *Server, p pool.Provider, ps *providerSession, c *admissionCloseConn) {
		exchange := &tier2RekeyExchange{done: make(chan struct{})}
		ps.rekey = exchange
		s.failTier2Rekey(ps, p.ProviderID, p.AssignedID, exchange, "fixture", ErrRelayAEADFailed)
	},
	"tier2UnencryptedChunk": func(t *testing.T, s *Server, p pool.Provider, ps *providerSession, c *admissionCloseConn) {
		ps.tier2 = &pool.Tier2Session{}
		s.handleInferenceChunk(p.ProviderID, p.AssignedID, []byte(`{"type":"inference_response_chunk","request_id":"fixture","seq":0,"data":"fixture"}`))
	},
	"tier2NAK": func(t *testing.T, s *Server, p pool.Provider, ps *providerSession, c *admissionCloseConn) {
		s.handleNAK(p.ProviderID, p.AssignedID, []byte(`{"type":"nak","in_reply_to":"fixture","error":{"code":"tier2_aead_decrypt_failed"}}`))
	},
	"readLoopFailure": func(t *testing.T, s *Server, p pool.Provider, ps *providerSession, c *admissionCloseConn) {
		c.failRead.Store(true)
		s.readProviderLoop(c, p.ProviderID, p.AssignedID)
	},

	"closeSession": func(t *testing.T, s *Server, p pool.Provider, ps *providerSession, c *admissionCloseConn) {
		s.closeSession(ps, gobwas.StatusNormalClosure, "fixture")
	},
	"heartbeat": func(t *testing.T, s *Server, p pool.Provider, ps *providerSession, c *admissionCloseConn) {
		ticks := make(chan time.Time, 1)
		ticks <- time.Now()
		close(ticks)
		s.modelAdmissionHeartbeatTicks = func(time.Duration) (<-chan time.Time, func()) { return ticks, func() {} }
		s.now = func() time.Time { return p.LastActivityAt.Add(5 * time.Minute) }
		s.monitorHeartbeat(p.ProviderID, p.AssignedID, c)
	},
	"writerFailure": func(t *testing.T, s *Server, p pool.Provider, ps *providerSession, c *admissionCloseConn) {
		c.failWrite.Store(true)
		if err := ps.send([]byte("fixture")); err != nil {
			t.Error(err)
		}
		ps.runWriter()
	},
	"writeFailureHandler": func(t *testing.T, s *Server, p pool.Provider, ps *providerSession, c *admissionCloseConn) {
		s.handleProviderWriteFailure(ps, errors.New("fixture"))
	},
	"probeTimeout": func(t *testing.T, s *Server, p pool.Provider, ps *providerSession, c *admissionCloseConn) {
		ticks := make(chan time.Time, 1)
		ticks <- time.Now()
		ps.probeTimer = func(time.Duration) (<-chan time.Time, func()) { return ticks, func() {} }
		if err := ps.writeProbe([]byte("fixture"), time.Second); !errors.Is(err, ErrRelayClosed) {
			t.Errorf("timeout result %v", err)
		}
	},
	"drainComplete": func(t *testing.T, s *Server, p pool.Provider, ps *providerSession, c *admissionCloseConn) {
		s.handleDrainStatus(c, p.ProviderID, p.AssignedID, []byte(`{"type":"drain_status","phase":"complete","inflight_requests":0,"estimated_drain_seconds":0}`))
	},
	"blacklist": func(t *testing.T, s *Server, p pool.Provider, ps *providerSession, c *admissionCloseConn) {
		s.cfg.Auth.OperatorKey = "fixture-operator"
		r := httptest.NewRequest("POST", "/admin/blacklist", strings.NewReader(`{"provider_id":"`+p.ProviderID+`"}`))
		r.Header.Set("Authorization", "Bearer fixture-operator")
		w := httptest.NewRecorder()
		s.handleBlacklist(w, r)
		if w.Code != 200 {
			t.Errorf("blacklist: %d %s", w.Code, w.Body.String())
		}
	},
	"trustRevocation": func(t *testing.T, s *Server, p pool.Provider, ps *providerSession, c *admissionCloseConn) {
		s.disconnectProviderForTrustRevocation(p.ProviderID, "fixture")
	},
	"shutdown": func(t *testing.T, s *Server, p pool.Provider, ps *providerSession, c *admissionCloseConn) {
		s.CloseAllProviderSessions("fixture")
	},
	"tier2SessionFailure": func(t *testing.T, s *Server, p pool.Provider, ps *providerSession, c *admissionCloseConn) {
		s.closeProviderForTier2SessionFailure(ps, p.ProviderID, p.AssignedID, "fixture", "fixture", ErrRelayAEADFailed)
	},
	"disconnect": func(t *testing.T, s *Server, p pool.Provider, ps *providerSession, c *admissionCloseConn) {
		s.handleDisconnect(p.ProviderID, p.AssignedID)
	},
	"registeredDeferredClose": func(t *testing.T, s *Server, p pool.Provider, ps *providerSession, c *admissionCloseConn) {
		s.registeredSessions.Store(c, ps)
		s.closeConnection(c)
	},
}

func TestPromotionLocalTeardownProducerSerialization(t *testing.T) {
	for name, produce := range admissionProducers {
		t.Run(name, func(t *testing.T) {
			orders := []string{"invalidate-first", "guard-first"}
			for _, boundary := range []string{"catalog_priced", "settlement_capable"} {
				t.Run(boundary, func(t *testing.T) {
					for _, order := range orders {
						t.Run(order, func(t *testing.T) {
							runAdmissionStores(t, func(t *testing.T, store ModelAdmissionStore) {
								s, p, ps, _, e := admissionGuardFixture(t, store)
								if boundary == "settlement_capable" {
									e = fixturePriced(t, s, p, e)
								}
								conn := &admissionCloseConn{Conn: ps.conn, closed: make(chan struct{})}
								ps.conn = conn
								var scheduled func()
								s.modelAdmissionAfterFunc = func(_ time.Duration, fn func()) {
									if !ps.writeMu.TryLock() {
										t.Error("schedule under session pin")
									} else {
										ps.writeMu.Unlock()
									}
									scheduled = fn
								}
								conn.onClose = func() {
									if !ps.writeMu.TryLock() {
										t.Error("socket close under session pin")
									} else {
										ps.writeMu.Unlock()
									}
								}
								if order == "invalidate-first" {
									produce(t, s, p, ps, conn)
								} else {
									entered, resume, closingStarted, done := make(chan struct{}), make(chan struct{}), make(chan struct{}), make(chan struct{})
									var once sync.Once
									ps.beforeClosing = func() { once.Do(func() { close(closingStarted) }) }
									ps.beforeEnqueue = ps.beforeClosing
									original := s.modelAdmissionPrepare
									_ = s.SetModelAdmissionAuthority(admissionFixtureResolver, func(ctx context.Context, p pool.Provider, e ModelAdmissionEvent) (PreparedModelAdmissionAuthority, error) {
										a, err := original(ctx, p, e)
										a.TryPin = func() (func(), error) { close(entered); <-resume; return func() {}, nil }
										return a, err
									})
									committed := make(chan struct{})
									go func() { fixturePriced(t, s, p, e); close(committed) }()
									select {
									case <-entered:
									case <-time.After(2 * time.Second):
										t.Fatal("guard did not enter")
									}
									go func() { produce(t, s, p, ps, conn); close(done) }()
									deadline := time.Now().Add(2 * time.Second)
									for {
										select {
										case <-closingStarted:
											goto producerBlocked
										default:
										}
										_, _, release, ok := s.pool.TryPinModelAdmissionProvider(p.ProviderID, p.AssignedID)
										if !ok {
											break
										}
										release()
										if time.Now().After(deadline) {
											close(resume)
											t.Fatal("producer did not enter session or registry owner")
										}
										runtime.Gosched()
									}
								producerBlocked:

									select {
									case <-conn.closed:
										t.Fatal("socket closed before commit")
									default:
									}
									close(resume)
									<-committed
									<-done
								}
								s.pool.ApplyStateUpdate(p.ProviderID, p.AssignedID, pool.StateUpdate{State: pool.StateReady, At: time.Now()})
								if s.ModelAdmissionSessionAvailable(p.ProviderID, p.AssignedID) {
									t.Fatal("ready update revived closing authority")
								}
								observed, err := s.refreshArtifactAdmissionStatus(context.Background(), e)
								if err == nil && artifactPositive(observed) {
									t.Fatal("closing returned positive")
								}
								if order == "invalidate-first" {
									before, _, _ := store.LatestModelAdmissionStatus(context.Background(), p.ProviderID, e.CandidateID)
									s.promoteModelAdmission(context.Background(), e, p, time.Now())
									after, _, _ := store.LatestModelAdmissionStatus(context.Background(), p.ProviderID, e.CandidateID)
									if before.CoordinatorEventID != after.CoordinatorEventID {
										t.Fatal("closing minted event")
									}
								}
								_ = scheduled
							})
						})
					}
				})
			}
		})
	}
}

func TestClosingPreservesGracefulCloseFrame(t *testing.T) {
	s, p, ps, peer, _ := admissionGuardFixture(t, NewMemoryModelAdmissionStore())
	var finish func()
	s.modelAdmissionAfterFunc = func(_ time.Duration, fn func()) { finish = fn }
	go ps.runWriter()
	s.closeSession(ps, gobwas.StatusNormalClosure, "graceful")
	if s.ModelAdmissionSessionAvailable(p.ProviderID, p.AssignedID) {
		t.Fatal("closing remained available")
	}
	select {
	case <-ps.closedCh:
		t.Fatal("graceful close terminated writer early")
	default:
	}
	_ = peer.SetReadDeadline(time.Now().Add(time.Second))
	frame, err := gobwas.ReadFrame(peer)
	if err != nil {
		t.Fatal(err)
	}
	code, reason := gobwas.ParseCloseFrameData(frame.Payload)
	if frame.Header.OpCode != gobwas.OpClose || code != gobwas.StatusNormalClosure || reason != "graceful" {
		t.Fatalf("close frame: %+v %d %s", frame, code, reason)
	}
	if finish == nil {
		t.Fatal("grace timer missing")
	}
	finish()
	ps.close()
}

func TestClosingPreservesPendingFramesAndExactlyOneGracefulClose(t *testing.T) {
	s, p, ps, peer, _ := admissionGuardFixture(t, NewMemoryModelAdmissionStore())
	conn := &admissionCloseConn{Conn: ps.conn, closed: make(chan struct{})}
	ps.conn = conn
	ps.onWriteFailure = s.handleProviderWriteFailure
	entered, resume := make(chan struct{}), make(chan struct{})
	var enterOnce sync.Once
	conn.beforeWrite = func() { enterOnce.Do(func() { close(entered) }); <-resume }
	var finish func()
	s.modelAdmissionAfterFunc = func(_ time.Duration, fn func()) { finish = fn }
	go ps.runWriter()
	if err := ps.send([]byte("in-flight")); err != nil {
		t.Fatal(err)
	}
	select {
	case <-entered:
	case <-time.After(time.Second):
		t.Fatal("first data frame never entered writer")
	}
	if err := ps.send([]byte("pending")); err != nil {
		t.Fatal(err)
	}
	s.closeSession(ps, gobwas.StatusNormalClosure, "graceful pending")
	if s.ModelAdmissionSessionAvailable(p.ProviderID, p.AssignedID) {
		t.Fatal("closing remained available")
	}
	close(resume)
	for i, want := range []struct {
		opcode gobwas.OpCode
		text   string
	}{{gobwas.OpText, "in-flight"}, {gobwas.OpText, "pending"}, {gobwas.OpClose, "graceful pending"}} {
		_ = peer.SetReadDeadline(time.Now().Add(time.Second))
		frame, err := gobwas.ReadFrame(peer)
		if err != nil {
			t.Fatalf("frame %d: %v", i, err)
		}
		if frame.Header.OpCode != want.opcode {
			t.Fatalf("frame %d opcode=%v want=%v", i, frame.Header.OpCode, want.opcode)
		}
		if want.opcode == gobwas.OpClose {
			code, reason := gobwas.ParseCloseFrameData(frame.Payload)
			if code != gobwas.StatusNormalClosure || reason != want.text {
				t.Fatalf("close=%d %q", code, reason)
			}
		} else if string(frame.Payload) != want.text {
			t.Fatalf("frame %d payload=%q want=%q", i, frame.Payload, want.text)
		}
	}
	if finish == nil {
		t.Fatal("grace timer missing")
	}
	finish()
	select {
	case <-conn.closed:
	case <-time.After(time.Second):
		t.Fatal("grace timer did not close transport")
	}
	ps.close()
}

func TestClosingDuplicateAndOldSessionIsolation(t *testing.T) {
	s, p, old, _, _ := admissionGuardFixture(t, NewMemoryModelAdmissionStore())
	var finish func()
	s.modelAdmissionAfterFunc = func(_ time.Duration, fn func()) { finish = fn }
	s.closeSession(old, gobwas.StatusNormalClosure, "old")
	a, b := net.Pipe()
	defer a.Close()
	defer b.Close()
	replacement := p
	replacement.AssignedID = "replacement"
	s.pool.Register(&replacement, a)
	s.pool.ApplyStateUpdate(p.ProviderID, replacement.AssignedID, pool.StateUpdate{State: pool.StateReady})
	next := newProviderSession(p.ProviderID, replacement.AssignedID, a, 2)
	s.storeProviderSession(sessionKey(p.ProviderID, replacement.AssignedID), next)
	finish()
	old.closeTransport()
	old.close()
	old.close()
	if s.ModelAdmissionSessionAvailable(p.ProviderID, p.AssignedID) {
		t.Fatal("old available")
	}
	if !s.ModelAdmissionSessionAvailable(p.ProviderID, replacement.AssignedID) {
		t.Fatal("old timer closed replacement")
	}
	for _, ids := range [][2]string{{"", replacement.AssignedID}, {p.ProviderID, ""}, {p.ProviderID, "missing"}} {
		if s.ModelAdmissionSessionAvailable(ids[0], ids[1]) {
			t.Fatal("inexact identity available")
		}
	}
}

func TestClosingFullQueueFallbackAndOverlaps(t *testing.T) {
	s, p, ps, _, _ := admissionGuardFixture(t, NewMemoryModelAdmissionStore())
	for i := 0; i < cap(ps.writeCh); i++ {
		if err := ps.send([]byte("occupied")); err != nil {
			t.Fatal(err)
		}
	}
	var mu sync.Mutex
	var timers []func()
	s.modelAdmissionAfterFunc = func(_ time.Duration, fn func()) { mu.Lock(); timers = append(timers, fn); mu.Unlock() }
	s.closeSession(ps, gobwas.StatusNormalClosure, "full queue")
	if s.ModelAdmissionSessionAvailable(p.ProviderID, p.AssignedID) {
		t.Fatal("full queue deferred logical closing")
	}
	var done sync.WaitGroup
	for i := 0; i < 16; i++ {
		done.Add(1)
		go func() {
			defer done.Done()
			s.closeSession(ps, gobwas.StatusNormalClosure, "overlap")
			ps.closeTransport()
			ps.close()
		}()
	}
	done.Wait()
	mu.Lock()
	callbacks := append([]func(){}, timers...)
	mu.Unlock()
	if len(callbacks) == 0 {
		t.Fatal("full queue omitted bounded fallback")
	}
	for _, fn := range callbacks {
		fn()
	}
	if !ps.closed || !ps.closing {
		t.Fatal("overlapping terminal close incomplete")
	}
}

func TestClosingRealGracefulProbeTimeoutWriterFailureOverlap(t *testing.T) {
	s, p, ps, _, _ := admissionGuardFixture(t, NewMemoryModelAdmissionStore())
	events := &recordingConnectionEventStore{}
	s.connectionEvents = events
	s.ensureConnectionEventWorker()
	conn := &admissionCloseConn{Conn: ps.conn, closed: make(chan struct{})}
	ps.conn = conn
	ps.onWriteFailure = s.handleProviderWriteFailure
	entered := make(chan struct{})
	var enterOnce sync.Once
	conn.beforeWrite = func() { enterOnce.Do(func() { close(entered) }); <-conn.closed }
	ticks := make(chan time.Time, 1)
	ps.probeTimer = func(time.Duration) (<-chan time.Time, func()) { return ticks, func() {} }
	var timersMu sync.Mutex
	var timers []func()
	s.modelAdmissionAfterFunc = func(_ time.Duration, fn func()) {
		timersMu.Lock()
		timers = append(timers, fn)
		timersMu.Unlock()
	}
	go ps.runWriter()
	probeDone := make(chan error, 1)
	go func() {
		frame, err := providerWriteProbeFrame()
		if err != nil {
			probeDone <- err
			return
		}
		probeDone <- ps.writeProbe(frame, time.Second)
	}()
	select {
	case <-entered:
	case <-time.After(time.Second):
		t.Fatal("real writer did not enter probe write")
	}
	s.closeSession(ps, gobwas.StatusNormalClosure, "overlap")
	ticks <- time.Now()
	if err := <-probeDone; !errors.Is(err, ErrRelayClosed) {
		t.Fatalf("probe timeout=%v", err)
	}
	select {
	case <-ps.closedCh:
	case <-time.After(time.Second):
		t.Fatal("terminal cleanup did not complete")
	}
	deadline := time.Now().Add(time.Second)
	for {
		if _, ok := s.storedSessionFor(p.ProviderID, p.AssignedID); !ok {
			break
		}
		if time.Now().After(deadline) {
			t.Fatal("real writer-failure cleanup did not delete session")
		}
		runtime.Gosched()
	}
	timersMu.Lock()
	captured := append([]func(){}, timers...)
	timersMu.Unlock()
	if len(captured) != 1 {
		t.Fatalf("grace timers=%d want=1", len(captured))
	}
	for _, fn := range captured {
		fn()
	}
	ps.close()
	s.FlushConnectionEvents(time.Second)
	closeEvents := 0
	for _, event := range events.snapshot() {
		if event.CloseCode == int(gobwas.StatusNormalClosure) && event.CloseReason == "overlap" {
			closeEvents++
		}
	}
	if closeEvents != 1 {
		t.Fatalf("normal close events=%d want=1", closeEvents)
	}
}

type acknowledgmentFailureStore struct {
	recordingConnectionEventStore
	server        *Server
	conn          net.Conn
	writerEntered chan struct{}
	writerResume  chan struct{}
	installed     chan *providerSession
	captured      atomic.Pointer[providerSession]
	once          sync.Once
}

func (s *acknowledgmentFailureStore) UpsertLastKnown(_ context.Context, snap providerevents.LastKnown) error {
	s.once.Do(func() {
		value, ok := s.server.registeredSessions.Load(s.conn)
		if !ok {
			close(s.installed)
			return
		}
		ps := value.(*providerSession)
		s.captured.Store(ps)
		wrapped := s.conn.(*admissionCloseConn)
		var writerOnce sync.Once
		wrapped.beforeWrite = func() { writerOnce.Do(func() { close(s.writerEntered) }); <-s.writerResume }
		var releaseWriterOnce sync.Once
		wrapped.releaseWrite = func() { releaseWriterOnce.Do(func() { close(s.writerResume) }) }
		ps.beforeEnqueue = func() {
			ps.beforeEnqueue = nil
			ps.writeCh <- providerFrame{payload: []byte("first occupied frame")}
			<-s.writerEntered
			ps.writeCh <- providerFrame{payload: []byte("second occupied frame")}
		}
		s.installed <- ps
		close(s.installed)
	})
	return nil
}

func TestPostRegistrationAcknowledgmentEnqueueFailureCapturesClosingSession(t *testing.T) {
	for _, version := range []int{1, 2} {
		t.Run("v"+itoa(version), func(t *testing.T) {
			serverSide, clientSide := net.Pipe()
			defer clientSide.Close()
			wrapped := &admissionCloseConn{Conn: serverSide, closed: make(chan struct{})}
			writerEntered := make(chan struct{})
			resumeWriter := make(chan struct{})
			cfg := config.Default()
			cfg.Auth.RequireProviderTokens = false
			cfg.Pool.WarmupGateEnabled = false
			cfg.WS.WriteBufferSize = 1
			cfg.Providers = []config.ProviderConfig{{ProviderID: "ack-failure", EndpointURL: "https://fixture.invalid"}}
			registry := pool.NewRegistry(cfg.Providers)
			store := &acknowledgmentFailureStore{conn: wrapped, writerEntered: writerEntered, writerResume: resumeWriter, installed: make(chan *providerSession, 1)}
			s := NewServer(cfg, registry, zerolog.Nop(), WithConnectionEventStore(store))
			store.server = s
			t.Cleanup(func() { s.FlushConnectionEvents(time.Second) })
			closedChecked := make(chan struct{})
			var closeCheckedOnce sync.Once
			wrapped.onClose = func() {
				closeCheckedOnce.Do(func() {
					ps := store.captured.Load()
					if ps == nil {
						t.Error("raw connection closed without captured registered session")
					} else {
						if ps.isOpen() {
							t.Error("raw connection closed before captured session published closing")
						}
						if actual, ok := s.storedSessionFor(ps.providerID, ps.assignedID); !ok || actual != ps {
							t.Error("eventual map cleanup ran before empty-ID deferred close")
						}
					}
					close(closedChecked)
				})
			}
			var providerID, assignedID string
			done := make(chan struct{})
			go func() {
				defer close(done)
				defer s.closeConnection(wrapped)
				if version == 1 {
					payload, _ := json.Marshal(admissionValidV1Hello("ack-failure"))
					providerID, assignedID = s.handleV1Conn(wrapped, providerAuth{}, payload, func() {})
					return
				}
				payload, _ := json.Marshal(admissionValidV2Initial(t, "ack-failure"))
				providerID, assignedID = s.handleV2Conn(wrapped, providerAuth{}, payload, func() {})
			}()
			if version == 2 {
				challengePayload, _, err := wsutil.ReadServerData(clientSide)
				if err != nil {
					t.Fatalf("read auth challenge: %v", err)
				}
				var challenge AuthChallenge
				if err := json.Unmarshal(challengePayload, &challenge); err != nil {
					t.Fatal(err)
				}
				proof := map[string]any{"type": "auth_request", "version": 2, "stage": "proof", "auth_attempt_id": challenge.AuthAttemptID, "provider_id": "ack-failure", "attestation_token": nil}
				if err := wsutil.WriteClientText(clientSide, mustJSON(proof)); err != nil {
					t.Fatal(err)
				}
			}
			ps := <-store.installed
			if ps == nil {
				t.Fatal("real registration was not captured")
			}
			select {
			case <-done:
			case <-time.After(2 * time.Second):
				t.Fatal("ack enqueue failure did not return")
			}
			if providerID != "" || assignedID != "" {
				t.Fatalf("ack enqueue failure returned IDs %q/%q", providerID, assignedID)
			}
			select {
			case <-closedChecked:
			case <-time.After(time.Second):
				t.Fatal("deferred raw close did not run")
			}
			if ps.isOpen() || s.ModelAdmissionSessionAvailable(ps.providerID, ps.assignedID) {
				t.Fatal("captured failed-ack session remained available")
			}
		})
	}
}

func TestRefusedRegistrationAndPreauthCloseDoNotInvalidateIncumbent(t *testing.T) {
	s, p, incumbent, _, _ := admissionGuardFixture(t, NewMemoryModelAdmissionStore())
	refused, refusedPeer := net.Pipe()
	defer refusedPeer.Close()
	incoming := p
	incoming.AssignedID = "refused-replacement"
	incoming.AuthState = pool.AuthBearerlessDuplicate
	if session, refusal := s.registerProviderSession(refused, &incoming); session != nil || refusal == pool.RegisterRefusalNone {
		t.Fatalf("replacement session=%p refusal=%q", session, refusal)
	}
	s.closeConnection(refused)
	preauth, preauthPeer := net.Pipe()
	defer preauthPeer.Close()
	s.closeConnection(preauth)
	if !incumbent.isOpen() || !s.ModelAdmissionSessionAvailable(p.ProviderID, p.AssignedID) {
		t.Fatal("refused or pre-auth connection invalidated incumbent")
	}
}

func admissionValidV1Hello(providerID string) map[string]any {
	return map[string]any{"type": "hello", "version": 1, "tier": 1, "provider_id": providerID, "hostname": "provider.local", "model_id": "mlx-community/Qwen2.5-7B-Instruct-4bit", "model_params_b": 7.0, "ram_gb": 16, "max_context_tokens": 50000, "max_concurrency": 1, "throughput_tps_estimate": 19.8, "binary_version": "0.1.0", "attestation": nil}
}

func admissionValidV2Initial(t *testing.T, providerID string) map[string]any {
	t.Helper()
	_, public, err := tier2.NewX25519Keypair()
	if err != nil {
		t.Fatal(err)
	}
	h := admissionValidV1Hello(providerID)
	h["type"], h["version"], h["stage"] = "auth_request", 2, "initial"
	delete(h, "tier")
	delete(h, "attestation")
	h["provider_ecdh_public_key"] = base64.RawURLEncoding.EncodeToString(public)
	h["tier2_capabilities"] = map[string]any{"encrypted_leg": true, "attestation": true, "aead_suites": []string{tier2.PillarBAEADA256GCM}, "response_chunk_plaintext_envelope": true, "in_band_aead_rekey_v1": true}
	return h
}

func TestAdmissionTransportObservationRetainsNoPins(t *testing.T) {
	s, p, ps, _, _ := admissionGuardFixture(t, NewMemoryModelAdmissionStore())
	ps.writeMu.Lock()
	s.sessionPublicationMu.Lock()
	observed := make(chan bool, 1)
	go func() { observed <- s.ModelAdmissionSessionAvailable(p.ProviderID, p.AssignedID) }()
	select {
	case open := <-observed:
		if !open {
			t.Error("open exact session unavailable")
		}
	case <-time.After(time.Second):
		t.Error("availability recursively acquired a publication/session pin")
	}
	s.sessionPublicationMu.Unlock()
	ps.writeMu.Unlock()
	if !ps.writeMu.TryLock() {
		t.Fatal("observation retained session pin")
	}
	ps.writeMu.Unlock()
	if !s.sessionPublicationMu.TryLock() {
		t.Fatal("observation retained publication pin")
	}
	s.sessionPublicationMu.Unlock()
}

// Shares real producers with the literal authenticated HTTP matrix. Its fixture
// already owns the writer; only deterministic IO/timer delivery is adapted.
func admissionHTTPProducer(name string) admissionProducer {
	switch name {
	case "writerFailure":
		return func(t *testing.T, s *Server, p pool.Provider, ps *providerSession, c *admissionCloseConn) {
			c.failWrite.Store(true)
			if err := ps.send([]byte("fixture write failure")); err != nil {
				t.Errorf("queue failure frame: %v", err)
				return
			}
			select {
			case <-c.closed:
			case <-time.After(2 * time.Second):
				t.Error("real writer did not publish failure close")
			}
		}
	case "probeTimeout":
		return func(t *testing.T, s *Server, p pool.Provider, ps *providerSession, c *admissionCloseConn) {
			entered, resume := make(chan struct{}), make(chan struct{})
			var enterOnce, releaseOnce sync.Once
			c.writeHookMu.Lock()
			c.beforeWrite = func() { enterOnce.Do(func() { close(entered) }); <-resume }
			c.releaseWrite = func() { releaseOnce.Do(func() { close(resume) }) }
			c.writeHookMu.Unlock()
			ticks := make(chan time.Time, 1)
			ps.probeTimer = func(time.Duration) (<-chan time.Time, func()) { return ticks, func() {} }
			timerDone := make(chan struct{})
			go func() {
				defer close(timerDone)
				select {
				case <-entered:
					ticks <- time.Now()
				case <-ps.closedCh:
				}
			}()
			frame, err := providerWriteProbeFrame()
			if err != nil {
				t.Fatal(err)
			}
			if err := ps.writeProbe(frame, time.Second); !errors.Is(err, ErrRelayClosed) {
				t.Errorf("probe timeout=%v", err)
			}
			<-timerDone
		}
	default:
		return admissionProducers[name]
	}
}
