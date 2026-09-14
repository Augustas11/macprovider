package ws

import (
	"context"
	"net/http"
	"reflect"
	"runtime"
	"sort"
	"sync"
	"sync/atomic"
	"testing"
	"time"

	"github.com/augstar/macprovider-coordinator/internal/pool"
	gobwas "github.com/gobwas/ws"
)

// The HTTP matrix shares the exact producer table with the owner-level tests.
// The adapter keeps the single real writer running and drives actual write
// failure/timeout boundaries; it does not replace a producer with beginClosing.
type admissionHTTPTeardown struct {
	f               *admissionReadbackHTTP
	conn            *admissionCloseConn
	armed           atomic.Bool
	probeCompleted  chan struct{}
	probeOnce       sync.Once
	queueOnce       sync.Once
	producerEntered chan struct{}
	enterOnce       sync.Once
	timersMu        sync.Mutex
	timers          []func()
}

func newAdmissionHTTPTeardown(t *testing.T, store ModelAdmissionStore, live bool) *admissionHTTPTeardown {
	m := &admissionHTTPTeardown{producerEntered: make(chan struct{}), probeCompleted: make(chan struct{})}
	m.f = newAdmissionReadbackHTTP(t, store, live, func(f *admissionReadbackHTTP) {
		f.afterProbe = func() { m.probeOnce.Do(func() { close(m.probeCompleted) }) }
		m.conn = &admissionCloseConn{Conn: f.ps.conn, closed: make(chan struct{})}
		f.ps.conn = m.conn
		beforeOwner := func() {
			if m.armed.Load() {
				m.enterOnce.Do(func() { close(m.producerEntered) })
			}
		}
		f.ps.beforeClosing = beforeOwner
		f.ps.beforeEnqueue = beforeOwner
		m.conn.onClose = func() {
			if store.(*admissionHTTPMatrixStore).guardHeld.Load() {
				t.Error("socket close occurred while admission pins held")
			}
		}
		f.s.modelAdmissionAfterFunc = func(_ time.Duration, fn func()) {
			if store.(*admissionHTTPMatrixStore).guardHeld.Load() {
				t.Error("close timer armed while admission pins held")
			}
			m.timersMu.Lock()
			m.timers = append(m.timers, fn)
			m.timersMu.Unlock()
		}
	})
	t.Cleanup(func() {
		m.timersMu.Lock()
		timers := append([]func(){}, m.timers...)
		m.timersMu.Unlock()
		for _, finish := range timers {
			finish()
		}
	})
	return m
}
func admissionHTTPProducerNames() []string {
	names := make([]string, 0, len(admissionProducers))
	for name := range admissionProducers {
		names = append(names, name)
	}
	names = append(names, "closeSessionFullQueue")
	sort.Strings(names)
	return names
}

// Establish real queue backpressure before the admission guard/observation.
// The producer itself remains the real closeSession call, rather than queue
// preparation being counted as its attempted authority publication.
func (m *admissionHTTPTeardown) prepare(name string) {
	if name != "closeSessionFullQueue" {
		return
	}
	m.queueOnce.Do(func() {
		admissionReadbackWait(m.f.t, m.probeCompleted)
		entered := make(chan struct{})
		resume, release := admissionHTTPGate(m.f.t)
		var once sync.Once
		m.conn.writeHookMu.Lock()
		m.conn.beforeWrite = func() { once.Do(func() { close(entered) }); <-resume }
		m.conn.releaseWrite = release
		m.conn.writeHookMu.Unlock()
		frame := []byte(`{"type":"fixture_queue_occupied"}`)
		if err := m.f.ps.send(frame); err != nil {
			m.f.t.Fatal(err)
		}
		admissionReadbackWait(m.f.t, entered)
		for i := 0; i < cap(m.f.ps.writeCh); i++ {
			if err := m.f.ps.send(frame); err != nil {
				m.f.t.Fatal(err)
			}
		}
		if len(m.f.ps.writeCh) != cap(m.f.ps.writeCh) {
			m.f.t.Fatal("fixture failed to establish full queue")
		}
	})
}

func (m *admissionHTTPTeardown) start(name string) <-chan struct{} {
	// The relay result wakes HTTP before handleInferenceEnd finishes its rekey
	// checks. Fixture producer inputs are changed only after that real handler returns.
	admissionReadbackWait(m.f.t, m.probeCompleted)
	m.armed.Store(true)
	done := make(chan struct{})
	go func() {
		defer close(done)
		if name == "closeSessionFullQueue" {
			if len(m.f.ps.writeCh) != cap(m.f.ps.writeCh) {
				m.f.t.Error("fallback producer did not start with full queue")
				return
			}
			m.f.s.closeSession(m.f.ps, gobwas.StatusNormalClosure, "fixture full-queue fallback")
			if len(m.f.ps.writeCh) != cap(m.f.ps.writeCh) {
				m.f.t.Error("blocked writer unexpectedly consumed full queue")
			}
			m.timersMu.Lock()
			timers := len(m.timers)
			m.timersMu.Unlock()
			if timers != 1 {
				m.f.t.Errorf("fallback scheduled %d close timers, want one", timers)
			}
		} else {
			admissionHTTPProducer(name)(m.f.t, m.f.s, m.f.p, m.f.ps, m.conn)
		}
	}()
	return done
}

// Execute the retained fallback only after all HTTP/history assertions, while
// the original writer is still blocked. Cleanup is not what proves this close.
func (m *admissionHTTPTeardown) finish(name string) {
	if name != "closeSessionFullQueue" {
		return
	}
	if len(m.f.ps.writeCh) != cap(m.f.ps.writeCh) {
		m.f.t.Fatal("fallback queue drained before timer delivery")
	}
	select {
	case <-m.conn.closed:
		m.f.t.Fatal("fallback socket closed before held timer")
	default:
	}
	m.timersMu.Lock()
	timers := append([]func(){}, m.timers...)
	m.timers = nil
	m.timersMu.Unlock()
	if len(timers) != 1 {
		m.f.t.Fatalf("fallback retained %d timers", len(timers))
	}
	timers[0]()
	admissionReadbackWait(m.f.t, m.conn.closed)
}

func (m *admissionHTTPTeardown) awaitOwnerAttempt() {
	t := m.f.t
	t.Helper()
	deadline := time.Now().Add(3 * time.Second)
	for {
		select {
		case <-m.producerEntered:
			return
		default:
		}
		// Some real producers first acquire the registry write lock. A failed
		// TryRLock while our guard owns its read pin proves a writer is pending.
		_, _, release, ok := m.f.s.pool.TryPinModelAdmissionProvider(m.f.p.ProviderID, m.f.p.AssignedID)
		if !ok {
			return
		}
		release()
		if time.Now().After(deadline) {
			t.Fatal("real producer did not reach session/registry owner")
		}
		runtime.Gosched()
	}
}
func (m *admissionHTTPTeardown) assertNoPublication() {
	t := m.f.t
	t.Helper()
	select {
	case <-m.f.ps.closingCh:
		t.Fatal("closing published before pinned observation/commit")
	default:
	}
	select {
	case <-m.conn.closed:
		t.Fatal("socket closed before pinned observation/commit")
	default:
	}
	m.timersMu.Lock()
	count := len(m.timers)
	m.timersMu.Unlock()
	if count != 0 {
		t.Fatal("close timer armed before pinned observation/commit")
	}
}
func (m *admissionHTTPTeardown) assertUnavailable() {
	t := m.f.t
	t.Helper()
	select {
	case <-m.f.ps.closingCh:
	default:
		t.Fatal("real producer did not publish monotonic closing")
	}
	// This is an actual warmup/state publication, not a fixture boolean reset.
	// Terminal producers may intentionally delete the session or change auth.
	m.f.s.pool.ApplyStateUpdate(m.f.p.ProviderID, m.f.p.AssignedID, pool.StateUpdate{State: pool.StateReady, At: time.Now()})
	if m.f.s.ModelAdmissionSessionAvailable(m.f.p.ProviderID, m.f.p.AssignedID) {
		t.Fatal("ready publication revived closing session")
	}
	m.timersMu.Lock()
	timers := len(m.timers)
	m.timersMu.Unlock()
	if timers > 0 {
		// Every scheduled closure is still retained until this leaf's cleanup.
		// No later timer or status request is needed to make transport unavailable.
		if m.f.ps.isOpen() {
			t.Fatal("scheduled close still grants authority")
		}
	}
}
func assertAdmissionHTTPNonPositive(t *testing.T, r admissionHTTPResult) {
	t.Helper()
	if r.body["admission_state"] == "catalog_priced" || r.body["admission_state"] == "settlement_capable" {
		t.Fatalf("stale positive HTTP response: %d %+v", r.code, r.body)
	}
	if r.code == http.StatusOK {
		if r.body["coordinator_event_id"] == nil || r.body["admission_state"] == nil {
			t.Fatalf("successful response omitted current event: %+v", r)
		}
	} else if r.code < 400 || r.body["coordinator_event_id"] != nil {
		t.Fatalf("unavailable response invented authority: %+v", r)
	}
}
func admissionHTTPGate(t *testing.T) (chan struct{}, func()) {
	t.Helper()
	ch := make(chan struct{})
	var once sync.Once
	release := func() { once.Do(func() { close(ch) }) }
	t.Cleanup(release)
	return ch, release
}

type admissionHTTPMatrixStore struct {
	*admissionReadbackStore
	target           string
	afterGuard       func()
	observe          func()
	observing        atomic.Bool
	inTarget         atomic.Bool
	guardHeld        atomic.Bool
	latestAttempts   atomic.Int32
	observeAttempts  atomic.Int32
	decisionAttempts atomic.Int32
	positiveAttempts atomic.Int32
	retryAttempts    atomic.Int32
}

func (s *admissionHTTPMatrixStore) AppendGuardedModelAdmissionDecision(ctx context.Context, e ModelAdmissionEvent, guard ModelAdmissionCommitGuard) (ModelAdmissionEvent, error) {
	s.positiveAttempts.Add(1)
	s.inTarget.Store(e.State == s.target)
	defer s.inTarget.Store(false)
	original := guard
	guard = func() (func(), error) {
		release, err := original()
		if err != nil {
			return release, err
		}
		s.guardHeld.Store(true)
		if s.afterGuard != nil && e.State == s.target {
			s.afterGuard()
		}
		return func() { s.guardHeld.Store(false); release() }, nil
	}

	return s.admissionReadbackStore.AppendGuardedModelAdmissionDecision(ctx, e, guard)
}
func (s *admissionHTTPMatrixStore) ObserveModelAdmission(ctx context.Context, p, c string, observe func(ModelAdmissionEvent) (func(), error)) (ModelAdmissionEvent, error) {
	s.observeAttempts.Add(1)
	return s.ModelAdmissionStore.(guardedModelAdmissionStore).ObserveModelAdmission(ctx, p, c, func(e ModelAdmissionEvent) (func(), error) {
		release, err := observe(e)
		if err != nil || !artifactPositive(e) {
			return release, err
		}
		s.guardHeld.Store(true)
		if s.observing.Load() && s.observe != nil {
			s.observe()
		}
		return func() { s.guardHeld.Store(false); release() }, nil

	})
}

func (s *admissionHTTPMatrixStore) LatestModelAdmissionStatus(ctx context.Context, p, c string) (ModelAdmissionEvent, bool, error) {
	s.latestAttempts.Add(1)
	return s.ModelAdmissionStore.LatestModelAdmissionStatus(ctx, p, c)
}
func (s *admissionHTTPMatrixStore) AppendModelAdmissionDecision(ctx context.Context, e ModelAdmissionEvent) (ModelAdmissionEvent, error) {
	s.decisionAttempts.Add(1)
	return s.admissionReadbackStore.AppendModelAdmissionDecision(ctx, e)
}
func (s *admissionHTTPMatrixStore) reserveModelAdmissionRetry(ctx context.Context, e ModelAdmissionEvent) (ModelAdmissionEvent, bool, error) {
	s.retryAttempts.Add(1)
	return s.admissionReadbackStore.reserveModelAdmissionRetry(ctx, e)
}

// 18 real producers plus the closeSession full-queue fallback variant, each
// at two positive boundaries × offer/retry × both stores.
// SQLite adds a distinct post-insert/pre-COMMIT ordering, in addition to the
// same after-guard ordering exercised in memory: 380 actual HTTP leaves.
func TestAdmissionHTTPTeardownPromotionMatrix(t *testing.T) {
	names := admissionHTTPProducerNames()
	if len(admissionProducers) != 18 || len(names) != 19 {
		t.Fatalf("producer/variant inventory changed: %d/%d", len(admissionProducers), len(names))
	}
	for _, name := range names {
		t.Run(name, func(t *testing.T) {
			for _, boundary := range []string{"catalog_priced", "settlement_capable"} {
				t.Run(boundary, func(t *testing.T) {
					for _, entry := range []string{"offer", "retry"} {
						t.Run(entry, func(t *testing.T) {
							runAdmissionStores(t, func(t *testing.T, base ModelAdmissionStore) {
								orders := []string{"invalidate-first", "guard-first"}
								if _, ok := base.(*SQLiteModelAdmissionStore); ok {
									orders = append(orders, "post-insert")
								}
								// Each ordering needs fresh durable identity/replay state, so delegate
								// the actual leaf to a separately allocated store of the same kind.
								for _, order := range orders {
									t.Run(order, func(t *testing.T) {
										var store ModelAdmissionStore
										if _, ok := base.(*SQLiteModelAdmissionStore); ok {
											db := openProbeAdmissionStore(t)
											var err error
											store, err = NewSQLiteModelAdmissionStore(db.DB())
											if err != nil {
												t.Fatal(err)
											}
										} else {
											store = NewMemoryModelAdmissionStore()
										}
										runAdmissionHTTPPromotionLeaf(t, name, boundary, entry, order, store)
									})
								}
							})
						})
					}
				})
			}
		})
	}
}
func runAdmissionHTTPPromotionLeaf(t *testing.T, name, boundary, entry, order string, base ModelAdmissionStore) {
	wrapped := &admissionHTTPMatrixStore{admissionReadbackStore: &admissionReadbackStore{ModelAdmissionStore: base}, target: boundary}
	m := newAdmissionHTTPTeardown(t, wrapped, entry == "offer")
	f := m.f
	path, payload := f.entry(entry)
	reached := make(chan struct{})
	resume, release := admissionHTTPGate(t)
	committed := make(chan struct{})
	finish, releaseFinish := admissionHTTPGate(t)
	var reachedOnce, committedOnce sync.Once
	pause := func() { reachedOnce.Do(func() { close(reached); <-resume }) }
	var attempted ModelAdmissionEvent
	wrapped.beforePositive = func(e ModelAdmissionEvent) {
		if e.State == boundary {
			m.prepare(name)
			attempted = e
			if order == "invalidate-first" {
				pause()
			}
		}
	}
	if order == "guard-first" {
		wrapped.afterGuard = pause
	}
	if order == "post-insert" {
		base.(*SQLiteModelAdmissionStore).commitTestHooks = &modelAdmissionCommitTestHooks{afterInsert: func() error {
			if wrapped.inTarget.Load() {
				pause()
			}
			return nil
		}}
	}
	wrapped.afterPositive = func(e ModelAdmissionEvent) {
		if e.State == boundary {
			committedOnce.Do(func() { close(committed); <-finish })
		}
	}
	done := make(chan admissionHTTPResult, 1)
	go func() { done <- f.call(f.s, path, payload) }()
	admissionReadbackWait(t, reached)
	producerDone := m.start(name)
	if order == "invalidate-first" {
		admissionReadbackWait(t, producerDone)
		m.assertUnavailable()
		release()
	} else {
		m.awaitOwnerAttempt()
		m.assertNoPublication()
		release()
		admissionReadbackWait(t, committed)
		admissionReadbackWait(t, producerDone)
		m.assertUnavailable()
		releaseFinish()
	}
	result := admissionReadbackReceive(t, done)
	assertAdmissionHTTPNonPositive(t, result)
	history := admissionReadbackHistory(t, base, f.candidate)
	expectedStates := []string{modelAdmissionOfferSubmitted, "sandbox_probe_only", "network_admitted_unsettled"}
	if boundary == "settlement_capable" || order != "invalidate-first" {
		expectedStates = append(expectedStates, "catalog_priced")
	}
	if boundary == "settlement_capable" && order != "invalidate-first" {
		expectedStates = append(expectedStates, "settlement_capable")
	}
	if len(expectedStates) > 3 {
		expectedStates = append(expectedStates, modelAdmissionRevoked)
	}
	assertAdmissionHTTPHistory(t, history, expectedStates)
	if f.latest(base).CoordinatorEventID != history[len(history)-1].CoordinatorEventID {
		t.Fatal("latest event differs from durable history")
	}
	positives := 0
	for _, e := range history {
		if artifactPositive(e) {
			positives++
		}
	}
	want := 0
	if boundary == "settlement_capable" {
		want = 1
	}
	if order != "invalidate-first" {
		want++
	}
	if positives != want {
		t.Fatalf("positive commits=%d want=%d at %s/%s", positives, want, boundary, order)
	}
	if order == "invalidate-first" {
		assertReadbackReplayKeysAbsent(t, base, attempted)
	}
	reservations := admissionReadbackRetries(t, base)
	assertAdmissionHTTPNonPositive(t, f.call(f.s, path, payload))
	assertAdmissionHTTPNonPositive(t, f.call(f.s, "status?candidate_id="+f.candidate, nil))
	if !reflect.DeepEqual(history, admissionReadbackHistory(t, base, f.candidate)) {
		t.Fatal("post-teardown replay/status appended another event")
	}
	if string(reservations) != string(admissionReadbackRetries(t, base)) || f.probes.Load() != 1 {
		t.Fatal("post-teardown replay changed reservation or repeated synthetic probe")
	}
	m.finish(name)
}

// Every producer also runs against a previously committed positive admission
// through original offer replay, retry replay and status. Both invalidation-
// first and observation-first run against both stores (228 HTTP leaves, including the full-queue variant).
func TestAdmissionHTTPTeardownReadbackMatrix(t *testing.T) {
	for _, name := range admissionHTTPProducerNames() {
		t.Run(name, func(t *testing.T) {
			for _, path := range []string{"offer-replay", "retry-replay", "status"} {
				t.Run(path, func(t *testing.T) {
					for _, order := range []string{"invalidate-first", "observation-first"} {
						t.Run(order, func(t *testing.T) {
							runAdmissionStores(t, func(t *testing.T, base ModelAdmissionStore) { runAdmissionHTTPReadbackLeaf(t, name, path, order, base) })
						})
					}
				})
			}
		})
	}
}
func runAdmissionHTTPReadbackLeaf(t *testing.T, name, path, order string, base ModelAdmissionStore) {
	wrapped := &admissionHTTPMatrixStore{admissionReadbackStore: &admissionReadbackStore{ModelAdmissionStore: base}}
	m := newAdmissionHTTPTeardown(t, wrapped, false)
	f := m.f
	_, retry := f.entry("retry")
	f.require(f.call(f.s, "retry", retry), "settlement_capable")
	if !artifactPositive(f.latest(base)) {
		t.Fatal("readback fixture has no committed positive admission")
	}
	m.prepare(name)
	originalHistory := admissionReadbackHistory(t, base, f.candidate)
	assertAdmissionHTTPHistory(t, originalHistory, []string{modelAdmissionOfferSubmitted, "sandbox_probe_only", "network_admitted_unsettled", "catalog_priced", "settlement_capable"})
	requestPath, payload := "retry", retry
	switch path {
	case "offer-replay":
		requestPath, payload = "offers", f.original
	case "status":
		requestPath, payload = "status?candidate_id="+f.candidate, nil
	}
	reached := make(chan struct{})
	resume, release := admissionHTTPGate(t)
	var once sync.Once
	wrapped.observe = func() { once.Do(func() { close(reached); <-resume }) }
	reservations := admissionReadbackRetries(t, base)
	if order == "invalidate-first" {
		done := m.start(name)
		admissionReadbackWait(t, done)
		m.assertUnavailable()
	} else {
		wrapped.observing.Store(true)
		response := make(chan admissionHTTPResult, 1)
		go func() { response <- f.call(f.s, requestPath, payload) }()
		admissionReadbackWait(t, reached)
		done := m.start(name)
		m.awaitOwnerAttempt()
		m.assertNoPublication()
		release()
		// This observation serialized before the mutation. A historical successful
		// response is permitted; the next HTTP observation must refuse authority.
		f.require(admissionReadbackReceive(t, response), "settlement_capable")
		admissionReadbackWait(t, done)
		m.assertUnavailable()
		wrapped.observing.Store(false)
	}
	if !reflect.DeepEqual(originalHistory, admissionReadbackHistory(t, base, f.candidate)) {
		t.Fatal("teardown producer changed admission history before HTTP readback")
	}
	assertAdmissionHTTPNonPositive(t, f.call(f.s, requestPath, payload))
	assertAdmissionHTTPNonPositive(t, f.call(f.s, "status?candidate_id="+f.candidate, nil))
	// A distinct request on an already-positive tuple is not a new admission:
	// actual protocol conflict/auth rejection must carry no authority or probe.
	for _, freshPath := range []string{"offers", "retry"} {
		r := f.call(f.s, freshPath, f.payload("fresh-"+freshPath, nil))
		assertAdmissionHTTPNonPositive(t, r)
	}
	finalHistory := admissionReadbackHistory(t, base, f.candidate)
	assertAdmissionHTTPHistory(t, finalHistory, []string{modelAdmissionOfferSubmitted, "sandbox_probe_only", "network_admitted_unsettled", "catalog_priced", "settlement_capable", modelAdmissionRevoked})
	if !reflect.DeepEqual(originalHistory, finalHistory[:len(originalHistory)]) {
		t.Fatal("readback changed historical positive evidence")
	}
	if f.latest(base).CoordinatorEventID != finalHistory[len(finalHistory)-1].CoordinatorEventID {
		t.Fatal("readback did not retain latest revocation")
	}
	if f.probes.Load() != 1 || string(reservations) != string(admissionReadbackRetries(t, base)) {
		t.Fatal("readback/fresh conflict repeated probe or changed retry reservation")
	}
	m.finish(name)
}

func assertAdmissionHTTPHistory(t *testing.T, events []ModelAdmissionEvent, states []string) {
	t.Helper()
	if len(events) != len(states) {
		t.Fatalf("history length=%d want=%d", len(events), len(states))
	}
	ids := map[string]bool{}
	for i, e := range events {
		if e.State != states[i] || e.CoordinatorEventID == "" || ids[e.CoordinatorEventID] {
			t.Fatalf("history[%d] invalid state/identity: %s", i, e.State)
		}
		ids[e.CoordinatorEventID] = true
		if i > 0 && (e.PreviousState != events[i-1].State || e.ExpectedCurrentEventID != events[i-1].CoordinatorEventID) {
			t.Fatalf("history[%d] broke state/event CAS chain", i)
		}
	}
}

// Throttling returns before admission storage/guard observation. Therefore the
// only reachable ordering is producer publication followed by the HTTP retry;
// manufacturing an observation-first guard would bypass the actual handler.
func TestAdmissionHTTPTeardownThrottledRetryMatrix(t *testing.T) {
	for _, name := range admissionHTTPProducerNames() {
		t.Run(name, func(t *testing.T) {
			runAdmissionStores(t, func(t *testing.T, base ModelAdmissionStore) {
				wrapped := &admissionHTTPMatrixStore{admissionReadbackStore: &admissionReadbackStore{ModelAdmissionStore: base}}
				m := newAdmissionHTTPTeardown(t, wrapped, false)
				f := m.f
				_, retry := f.entry("retry")
				f.require(f.call(f.s, "retry", retry), "settlement_capable")
				original := admissionReadbackHistory(t, base, f.candidate)
				assertAdmissionHTTPHistory(t, original, []string{modelAdmissionOfferSubmitted, "sandbox_probe_only", "network_admitted_unsettled", "catalog_priced", "settlement_capable"})
				reservations := admissionReadbackRetries(t, base)
				m.prepare(name)
				done := m.start(name)
				admissionReadbackWait(t, done)
				m.assertUnavailable()
				wrapped.latestAttempts.Store(0)
				wrapped.observeAttempts.Store(0)
				wrapped.decisionAttempts.Store(0)
				wrapped.positiveAttempts.Store(0)
				wrapped.retryAttempts.Store(0)
				f.s.modelAdmissionAttemptMu.Lock()
				f.s.modelAdmissionAttempts[f.p.ProviderID] = make([]time.Time, modelAdmissionMaxEvents)
				for i := range f.s.modelAdmissionAttempts[f.p.ProviderID] {
					f.s.modelAdmissionAttempts[f.p.ProviderID][i] = time.Now()
				}
				f.s.modelAdmissionAttemptMu.Unlock()
				result := f.call(f.s, "retry", retry)
				errorBody, _ := result.body["error"].(map[string]any)
				if result.code != http.StatusTooManyRequests || errorBody["code"] != "rate_limited" || result.body["admission_state"] != nil || result.body["coordinator_event_id"] != nil {
					t.Fatalf("throttled retry returned authority: %+v", result)
				}
				if wrapped.latestAttempts.Load() != 0 || wrapped.observeAttempts.Load() != 0 || wrapped.decisionAttempts.Load() != 0 || wrapped.positiveAttempts.Load() != 0 || wrapped.retryAttempts.Load() != 0 {
					t.Fatal("throttled handler reached admission storage/guard")
				}
				if !reflect.DeepEqual(original, admissionReadbackHistory(t, base, f.candidate)) || string(reservations) != string(admissionReadbackRetries(t, base)) || f.probes.Load() != 1 {
					t.Fatal("throttled retry changed history/reservations or repeated probe")
				}
				m.finish(name)
			})
		})
	}
}
