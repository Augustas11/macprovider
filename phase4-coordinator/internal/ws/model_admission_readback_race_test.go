package ws

import (
	"bytes"
	"context"
	"crypto/ed25519"
	"crypto/sha256"
	"encoding/base64"
	"encoding/hex"
	"encoding/json"
	"errors"
	"net/http"
	"net/http/httptest"
	"path/filepath"
	"reflect"
	"strings"
	"sync"
	"sync/atomic"
	"testing"
	"time"

	"github.com/augstar/macprovider-coordinator/internal/auth"
	"github.com/augstar/macprovider-coordinator/internal/billing"
	"github.com/augstar/macprovider-coordinator/internal/pool"
	"github.com/gobwas/ws/wsutil"
	"github.com/rs/zerolog"
)

// Only storage scheduling/failure is injected here. Signed HTTP authentication,
// WS probes, pool/session pins, event CAS, and the underlying stores are real.
// Catalog evidence uses the shared WS fixture; this is not signed-feed coverage.
type admissionReadbackStore struct {
	ModelAdmissionStore
	beforePositive func(ModelAdmissionEvent)
	afterPositive  func(ModelAdmissionEvent)
	revoke         func(context.Context, ModelAdmissionEvent) (ModelAdmissionEvent, error)
}

func (s *admissionReadbackStore) AppendGuardedModelAdmissionDecision(ctx context.Context, e ModelAdmissionEvent, guard ModelAdmissionCommitGuard) (ModelAdmissionEvent, error) {
	if s.beforePositive != nil {
		s.beforePositive(e)
	}
	result, err := s.ModelAdmissionStore.(guardedModelAdmissionStore).AppendGuardedModelAdmissionDecision(ctx, e, guard)
	if err == nil && s.afterPositive != nil {
		s.afterPositive(result)
	}
	return result, err
}
func (s *admissionReadbackStore) ObserveModelAdmission(ctx context.Context, p, c string, observe func(ModelAdmissionEvent) (func(), error)) (ModelAdmissionEvent, error) {
	return s.ModelAdmissionStore.(guardedModelAdmissionStore).ObserveModelAdmission(ctx, p, c, observe)
}
func (s *admissionReadbackStore) AppendModelAdmissionDecision(ctx context.Context, e ModelAdmissionEvent) (ModelAdmissionEvent, error) {
	if e.State == modelAdmissionRevoked && s.revoke != nil {
		return s.revoke(ctx, e)
	}
	return s.ModelAdmissionStore.AppendModelAdmissionDecision(ctx, e)
}
func (s *admissionReadbackStore) reserveModelAdmissionRetry(ctx context.Context, e ModelAdmissionEvent) (ModelAdmissionEvent, bool, error) {
	return s.ModelAdmissionStore.(modelAdmissionRetryStore).reserveModelAdmissionRetry(ctx, e)
}
func (s *admissionReadbackStore) completeModelAdmissionRetry(ctx context.Context, e, out ModelAdmissionEvent) error {
	return s.ModelAdmissionStore.(modelAdmissionRetryStore).completeModelAdmissionRetry(ctx, e, out)
}

type admissionReadbackHTTP struct {
	t          *testing.T
	s          *Server
	p          pool.Provider
	ps         *providerSession
	bearer     string
	private    ed25519.PrivateKey
	candidate  string
	original   map[string]any
	afterProbe func()
	probes     atomic.Int32
	makeServer func(ModelAdmissionStore, *pool.Registry) *Server
}
type admissionHTTPResult struct {
	code int
	body map[string]any
}

func newAdmissionReadbackHTTP(t *testing.T, store ModelAdmissionStore, live bool, configure ...func(*admissionReadbackHTTP)) *admissionReadbackHTTP {
	t.Helper()
	seed, p, ps, conn, _ := admissionGuardFixture(t, store)
	tokens, bearer, private := bindModelAdmissionProbeIdentity(t, p.ProviderID)
	f := &admissionReadbackHTTP{t: t, p: p, ps: ps, bearer: bearer, private: private, candidate: "byom_" + strings.Repeat("a", 52)}
	f.makeServer = func(store ModelAdmissionStore, registry *pool.Registry) *Server {
		s := NewServer(modelAdmissionProbeAuthConfig(), registry, zerolog.Nop(), WithTokenValidator(tokens), WithTokenIssuer(tokens), WithBootstrapTokenStore(tokens), WithModelAdmissionStore(store))
		setFixtureModelAdmissionAuthority(s, admissionFixtureResolver)
		return s
	}
	f.s = f.makeServer(store, seed.pool)
	if live {
		f.s.storeProviderSession(sessionKey(p.ProviderID, p.AssignedID), ps)
	}
	for _, setup := range configure {
		setup(f)
	}
	go ps.runWriter()
	done := make(chan struct{})
	go func() {
		defer close(done)
		for {
			raw, _, err := wsutil.ReadServerData(conn)
			if err != nil {
				return
			}
			var request InferenceRequest
			if err = json.Unmarshal(raw, &request); err != nil {
				t.Errorf("decode fixture wire request: %v", err)
				return
			}
			if request.Type != "inference_request" {
				continue
			}
			f.probes.Add(1)
			f.s.handleInferenceChunk(p.ProviderID, p.AssignedID, mustJSON(InferenceResponseChunk{Type: "inference_response_chunk", RequestID: request.RequestID, Seq: 0, Data: `{"choices":[{"message":{"content":"ok"}}]}`}))
			f.s.handleInferenceEnd(p.ProviderID, p.AssignedID, mustJSON(InferenceResponseEnd{Type: "inference_response_end", RequestID: request.RequestID, Status: "complete", ChunksSent: 1}))
			if f.afterProbe != nil {
				f.afterProbe()
			}
		}
	}()
	t.Cleanup(func() {
		ps.close()
		conn.Close()
		select {
		case <-done:
		case <-time.After(3 * time.Second):
			t.Error("fixture wire reader did not stop")
		}
	})
	return f
}
func (f *admissionReadbackHTTP) payload(tag string, extra map[string]any) map[string]any {
	overrides := map[string]any{"runtime_source": "mlx_cache", "catalog_model_key": "fixture-model", "requested_disclosure_class": "catalog_binding_requested", "nonce": "readback-nonce-" + tag, "idempotency_key": "readback-request-" + tag}
	for k, v := range extra {
		overrides[k] = v
	}
	return signedModelAdmissionProbeOffer(f.t, f.p.ProviderID, f.candidate, f.p.ModelID, f.private, overrides)
}
func (f *admissionReadbackHTTP) call(s *Server, path string, payload map[string]any) admissionHTTPResult {
	f.t.Helper()
	method := http.MethodPost
	if payload == nil {
		method = http.MethodGet
	}
	raw, err := json.Marshal(payload)
	if err != nil {
		f.t.Fatal(err)
	}
	ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
	defer cancel()
	request := httptest.NewRequest(method, "/v1/provider/model-admission/"+path, bytes.NewReader(raw)).WithContext(ctx)
	request.Header.Set("Authorization", "Bearer "+f.bearer)
	request.Header.Set("Content-Type", "application/json")
	response := httptest.NewRecorder()
	s.Handler().ServeHTTP(response, request)
	var body map[string]any
	if err = json.Unmarshal(response.Body.Bytes(), &body); err != nil {
		f.t.Fatalf("HTTP %d non-JSON response: %v", response.Code, err)
	}
	return admissionHTTPResult{response.Code, body}
}
func (f *admissionReadbackHTTP) require(result admissionHTTPResult, state string) {
	f.t.Helper()
	if result.code != http.StatusOK || result.body["admission_state"] != state {
		f.t.Fatalf("HTTP result = %d %+v, want %s", result.code, result.body, state)
	}
}
func (f *admissionReadbackHTTP) entry(entry string) (string, map[string]any) {
	original := f.payload("offer", nil)
	f.original = original
	if entry == "offer" {
		return "offers", original
	}
	f.require(f.call(f.s, "offers", original), modelAdmissionOfferSubmitted)
	f.s.storeProviderSession(sessionKey(f.p.ProviderID, f.p.AssignedID), f.ps)
	return "retry", f.payload("retry", nil)
}
func (f *admissionReadbackHTTP) latest(store ModelAdmissionStore) ModelAdmissionEvent {
	f.t.Helper()
	e, ok, err := store.LatestModelAdmissionStatus(context.Background(), f.p.ProviderID, f.candidate)
	if err != nil || !ok {
		f.t.Fatalf("latest missing: %v", err)
	}
	return e
}
func (f *admissionReadbackHTTP) withdraw() admissionHTTPResult {
	body := signedReadbackWithdrawal(f.t, f.p.ProviderID, f.candidate, f.p.ModelID, f.private, map[string]any{"catalog_model_key": "fixture-model"})
	result := f.call(f.s, "withdrawals", body)
	if result.code != http.StatusOK {
		f.t.Fatalf("withdrawal: %d %+v", result.code, result.body)
	}
	return result
}
func admissionReadbackHistory(t *testing.T, store ModelAdmissionStore, candidate string) []ModelAdmissionEvent {
	t.Helper()
	var events []ModelAdmissionEvent
	switch s := store.(type) {
	case *memoryModelAdmissionStore:
		s.mu.Lock()
		defer s.mu.Unlock()
		for _, e := range s.events {
			if e.CandidateID == candidate {
				events = append(events, cloneModelAdmissionEvent(e))
			}
		}
	case *SQLiteModelAdmissionStore:
		rows, err := s.db.QueryContext(context.Background(), modelAdmissionEventSelect(" FROM model_admission_events WHERE candidate_id = ? ORDER BY id"), candidate)
		if err != nil {
			t.Fatal(err)
		}
		defer rows.Close()
		for rows.Next() {
			e, err := scanModelAdmissionEventRow(rows)
			if err != nil {
				t.Fatal(err)
			}
			events = append(events, e)
		}
		if err = rows.Err(); err != nil {
			t.Fatal(err)
		}
	default:
		t.Fatalf("unexpected backing store %T", store)
	}
	return events
}

// Capture durable retry reservations, not merely the handler's replay flag.
func admissionReadbackRetries(t *testing.T, store ModelAdmissionStore) []byte {
	t.Helper()
	var value any
	switch s := store.(type) {
	case *memoryModelAdmissionStore:
		s.mu.Lock()
		defer s.mu.Unlock()
		value = s.retries
	case *SQLiteModelAdmissionStore:
		rows, err := s.db.Query("SELECT provider_id,request_id,nonce,payload_digest,outcome_json FROM model_admission_retries ORDER BY provider_id,request_id")
		if err != nil {
			t.Fatal(err)
		}
		defer rows.Close()
		records := make([][5]string, 0)
		for rows.Next() {
			var r [5]string
			if err := rows.Scan(&r[0], &r[1], &r[2], &r[3], &r[4]); err != nil {
				t.Fatal(err)
			}
			records = append(records, r)
		}
		if err := rows.Err(); err != nil {
			t.Fatal(err)
		}
		value = records
	default:
		t.Fatalf("unexpected retry backing store %T", store)
	}
	raw, err := json.Marshal(value)
	if err != nil {
		t.Fatal(err)
	}
	return raw
}

func assertReadbackReplayKeysAbsent(t *testing.T, store ModelAdmissionStore, e ModelAdmissionEvent) {
	t.Helper()
	switch s := store.(type) {
	case *memoryModelAdmissionStore:
		s.mu.Lock()
		defer s.mu.Unlock()
		if _, ok := s.requestIDs[e.ProviderID+"|"+e.RequestID]; ok {
			t.Fatal("failed positive reserved request replay key")
		}
		if _, ok := s.nonces[e.ProviderID+"|"+e.Nonce]; ok {
			t.Fatal("failed positive reserved nonce replay key")
		}
	case *SQLiteModelAdmissionStore:
		var count int
		if err := s.db.QueryRow("SELECT COUNT(*) FROM model_admission_events WHERE provider_id=? AND (request_id=? OR nonce=?)", e.ProviderID, e.RequestID, e.Nonce).Scan(&count); err != nil {
			t.Fatal(err)
		}
		if count != 0 {
			t.Fatal("failed positive reserved SQLite replay keys")
		}
	}
}

func admissionReadbackWait(t *testing.T, ready <-chan struct{}) {
	t.Helper()
	select {
	case <-ready:
	case <-time.After(5 * time.Second):
		t.Fatal("admission boundary not reached")
	}
}
func admissionReadbackReceive(t *testing.T, done <-chan admissionHTTPResult) admissionHTTPResult {
	t.Helper()
	select {
	case result := <-done:
		return result
	case <-time.After(6 * time.Second):
		t.Fatal("HTTP admission did not finish")
		return admissionHTTPResult{}
	}
}

func TestPromotionCASWinnerReadback(t *testing.T) {
	for _, boundary := range []string{"catalog_priced", "settlement_capable"} {
		t.Run(boundary, func(t *testing.T) {
			for _, entry := range []string{"offer", "retry"} {
				t.Run(entry, func(t *testing.T) {
					for _, winner := range []string{"withdrawal", "reoffer", "revocation"} {
						t.Run(winner, func(t *testing.T) {
							runAdmissionStores(t, func(t *testing.T, base ModelAdmissionStore) {
								wrapped := &admissionReadbackStore{ModelAdmissionStore: base}
								f := newAdmissionReadbackHTTP(t, wrapped, entry == "offer")
								path, payload := f.entry(entry)
								reached, resume := make(chan struct{}), make(chan struct{})
								var resumeOnce sync.Once
								release := func() { resumeOnce.Do(func() { close(resume) }) }
								t.Cleanup(release)
								var once sync.Once
								var attempted ModelAdmissionEvent
								wrapped.beforePositive = func(e ModelAdmissionEvent) {
									if e.State == boundary {
										once.Do(func() { attempted = e; close(reached); <-resume })
									}
								}
								done := make(chan admissionHTTPResult, 1)
								go func() { done <- f.call(f.s, path, payload) }()
								admissionReadbackWait(t, reached)
								if winner == "revocation" {
									current := f.latest(base)
									if _, err := base.AppendModelAdmissionDecision(context.Background(), ModelAdmissionAuthorityRevocation(current, time.Now())); err != nil {
										release()
										t.Fatal(err)
									}
								} else {
									f.withdraw()
									if winner == "reoffer" {
										// A fresh authenticated offer reaches a coordinator without a live
										// transport, so it remains pending while the old CAS is outstanding.
										other := f.makeServer(base, pool.NewRegistry(nil))
										f.require(f.call(other, "offers", f.payload("fresh", map[string]any{"evaluation_digest_sha256": strings.Repeat("e", 64)})), modelAdmissionOfferSubmitted)
									}
								}
								current := f.latest(base)
								before := admissionReadbackHistory(t, base, f.candidate)
								release()
								result := admissionReadbackReceive(t, done)
								f.require(result, current.State)
								if result.body["coordinator_event_id"] != current.CoordinatorEventID {
									t.Fatal("HTTP did not return CAS winner")
								}
								if got := admissionReadbackHistory(t, base, f.candidate); !reflect.DeepEqual(got, before) {
									t.Fatal("stale promotion appended after winning event")
								}
								assertReadbackReplayKeysAbsent(t, base, attempted)
								reservations := admissionReadbackRetries(t, base)
								replay := f.call(f.s, path, payload)
								if !bytes.Equal(reservations, admissionReadbackRetries(t, base)) {
									t.Fatal("replay changed retry reservation")
								}
								f.require(replay, current.State)
								if replay.body["coordinator_event_id"] != current.CoordinatorEventID || f.probes.Load() != 1 {
									t.Fatalf("replay changed winner or repeated probe: %+v probes=%d", replay, f.probes.Load())
								}
								positives := 0
								for _, e := range before {
									if artifactPositive(e) {
										positives++
									}
								}
								want := 0
								if boundary == "settlement_capable" {
									want = 1
								}
								if positives != want {
									t.Fatalf("positive history count=%d want=%d", positives, want)
								}
							})
						})
					}
				})
			}
		})
	}
}

func TestAdmissionReadbackAfterPromotionRace(t *testing.T) {
	for _, entry := range []string{"offer", "retry"} {
		for _, failure := range []bool{false, true} {
			name := "post-promotion/" + entry + "/revoke-success"
			if failure {
				name = "post-promotion/" + entry + "/cas-then-store-error"
			}
			t.Run(name, func(t *testing.T) {
				runAdmissionStores(t, func(t *testing.T, base ModelAdmissionStore) {
					wrapped := &admissionReadbackStore{ModelAdmissionStore: base}
					f := newAdmissionReadbackHTTP(t, wrapped, entry == "offer")
					path, payload := f.entry(entry)
					reached, resume := make(chan struct{}), make(chan struct{})
					var resumeOnce sync.Once
					release := func() { resumeOnce.Do(func() { close(resume) }) }
					t.Cleanup(release)
					wrapped.afterPositive = func(e ModelAdmissionEvent) {
						if e.State == "settlement_capable" {
							close(reached)
							<-resume
						}
					}
					attempts := 0
					if failure {
						wrapped.revoke = func(context.Context, ModelAdmissionEvent) (ModelAdmissionEvent, error) {
							attempts++
							if attempts%2 == 1 {
								return ModelAdmissionEvent{}, errModelAdmissionReplayConflict
							}
							return ModelAdmissionEvent{}, errors.New("fixture revocation storage unavailable")
						}
					}
					done := make(chan admissionHTTPResult, 1)
					go func() { done <- f.call(f.s, path, payload) }()
					admissionReadbackWait(t, reached)
					if !artifactPositive(f.latest(base)) {
						t.Fatal("barrier preceded durable positive commit")
					}
					before := admissionReadbackHistory(t, base, f.candidate)
					f.ps.beginClosing()
					release()
					result := admissionReadbackReceive(t, done)
					reservations := admissionReadbackRetries(t, base)
					replay := f.call(f.s, path, payload)
					if failure {
						for _, r := range []admissionHTTPResult{result, replay} {
							if r.code != http.StatusServiceUnavailable || r.body["coordinator_event_id"] != nil || r.body["admission_state"] != nil {
								t.Fatalf("failed final observation returned authority: %+v", r)
							}
						}
						if attempts != 4 || !reflect.DeepEqual(before, admissionReadbackHistory(t, base, f.candidate)) {
							t.Fatal("failed final observation changed durable events or bypassed revoke retry")
						}
					} else {
						f.require(result, modelAdmissionRevoked)
						f.require(replay, modelAdmissionRevoked)
					}
					if f.probes.Load() != 1 || !bytes.Equal(reservations, admissionReadbackRetries(t, base)) {
						t.Fatal("replay repeated probe or changed retry reservation")
					}
				})
			})
		}
	}

	for _, path := range []string{"offers", "retry", "status", "throttled-retry"} {
		t.Run(path, func(t *testing.T) {
			for _, failure := range []string{"none", "cas-winner", "cas-then-store-error"} {
				if path == "throttled-retry" && failure != "none" {
					continue
				}
				t.Run(failure, func(t *testing.T) {
					runAdmissionStores(t, func(t *testing.T, base ModelAdmissionStore) {
						wrapped := &admissionReadbackStore{ModelAdmissionStore: base}
						f := newAdmissionReadbackHTTP(t, wrapped, false)
						_, retry := f.entry("retry")
						f.require(f.call(f.s, "retry", retry), "settlement_capable")
						positive := f.latest(base)
						reservations := admissionReadbackRetries(t, base)
						before := admissionReadbackHistory(t, base, f.candidate)
						f.ps.beginClosing()
						attempts := 0
						wrapped.revoke = func(ctx context.Context, e ModelAdmissionEvent) (ModelAdmissionEvent, error) {
							attempts++
							if failure == "cas-winner" {
								f.withdraw()
								return ModelAdmissionEvent{}, errModelAdmissionReplayConflict
							}
							if failure == "cas-then-store-error" {
								if attempts == 1 {
									return ModelAdmissionEvent{}, errModelAdmissionReplayConflict
								}
								return ModelAdmissionEvent{}, errors.New("fixture revocation storage unavailable")
							}
							return base.AppendModelAdmissionDecision(ctx, e)
						}
						requestPath, payload := path, retry
						if path == "offers" {
							payload = f.original
						}
						if path == "status" {
							requestPath = "status?candidate_id=" + f.candidate
							payload = nil
						}
						if path == "throttled-retry" {
							requestPath = "retry"
							f.s.modelAdmissionAttemptMu.Lock()
							f.s.modelAdmissionAttempts[f.p.ProviderID] = make([]time.Time, modelAdmissionMaxEvents)
							for i := range f.s.modelAdmissionAttempts[f.p.ProviderID] {
								f.s.modelAdmissionAttempts[f.p.ProviderID][i] = time.Now()
							}
							f.s.modelAdmissionAttemptMu.Unlock()
						}
						result := f.call(f.s, requestPath, payload)
						if path == "throttled-retry" || failure == "cas-then-store-error" {
							want := http.StatusServiceUnavailable
							if path == "throttled-retry" {
								want = http.StatusTooManyRequests
							}
							if result.code != want || result.body["coordinator_event_id"] != nil || result.body["admission_state"] != nil {
								t.Fatalf("unavailable readback claimed event: %+v", result)
							}
							if !reflect.DeepEqual(before, admissionReadbackHistory(t, base, f.candidate)) || f.latest(base).CoordinatorEventID != positive.CoordinatorEventID {
								t.Fatal("failed readback invented durable event")
							}
							if path == "throttled-retry" && attempts != 0 {
								t.Fatal("throttled request reached revocation store")
							}
							if path != "throttled-retry" && attempts != 2 {
								t.Fatalf("revocation attempts=%d", attempts)
							}
						} else {
							want := modelAdmissionRevoked
							if failure == "cas-winner" {
								want = modelAdmissionWithdrawn
							}
							f.require(result, want)
							if result.body["coordinator_event_id"] != f.latest(base).CoordinatorEventID {
								t.Fatal("response not current event")
							}
						}
						if !bytes.Equal(reservations, admissionReadbackRetries(t, base)) {
							t.Fatal("readback changed retry reservation")
						}
						if f.probes.Load() != 1 {
							t.Fatal("readback repeated wire probe")
						}
					})
				})
			}
		})
	}
}

// Embedding only the public interface deliberately omits the guarded capability.
type admissionUnguardedStore struct{ ModelAdmissionStore }

func TestAdmissionGuardCompatibilityAndReopen(t *testing.T) {
	t.Run("positive-and-exact-replay", func(t *testing.T) {
		runAdmissionStores(t, func(t *testing.T, base ModelAdmissionStore) {
			f := newAdmissionReadbackHTTP(t, base, true)
			payload := f.payload("offer", nil)
			f.require(f.call(f.s, "offers", payload), "settlement_capable")
			history := admissionReadbackHistory(t, base, f.candidate)
			if len(history) != 5 {
				t.Fatalf("history has %d events, want offer/probe/network/two positive", len(history))
			}
			if history[3].State != "catalog_priced" || history[4].State != "settlement_capable" || history[3].ExpectedCurrentEventID != history[2].CoordinatorEventID || history[4].ExpectedCurrentEventID != history[3].CoordinatorEventID {
				t.Fatal("positive CAS chain mismatch")
			}
			a, _ := json.Marshal(history[3].ArtifactAdmissionEvidence)
			b, _ := json.Marshal(history[4].ArtifactAdmissionEvidence)
			if !bytes.Equal(a, b) {
				t.Fatal("positive transitions changed captured evidence")
			}
			f.require(f.call(f.s, "offers", payload), "settlement_capable")
			f.withdraw()
			winning := f.latest(base)
			after := admissionReadbackHistory(t, base, f.candidate)
			replay := f.call(f.s, "offers", payload)
			f.require(replay, modelAdmissionWithdrawn)
			if replay.body["coordinator_event_id"] != winning.CoordinatorEventID || f.probes.Load() != 1 || !reflect.DeepEqual(after, admissionReadbackHistory(t, base, f.candidate)) {
				t.Fatal("positive replay bypassed withdrawal or repeated work")
			}
		})
	})
	t.Run("unsupported-capability", func(t *testing.T) {
		runAdmissionStores(t, func(t *testing.T, base ModelAdmissionStore) {
			f := newAdmissionReadbackHTTP(t, admissionUnguardedStore{base}, true)
			f.require(f.call(f.s, "offers", f.payload("offer", nil)), "network_admitted_unsettled")
			for _, e := range admissionReadbackHistory(t, base, f.candidate) {
				if artifactPositive(e) {
					t.Fatal("unguarded store minted positive")
				}
			}
		})
	})
	t.Run("legacy", func(t *testing.T) {
		runAdmissionStores(t, func(t *testing.T, base ModelAdmissionStore) {
			f := newAdmissionReadbackHTTP(t, base, false)
			legacy := f.payload("legacy", map[string]any{"runtime_source": "ollama_loopback", "catalog_model_key": "", "requested_disclosure_class": "non_earning_provider_asserted"})
			f.require(f.call(f.s, "offers", legacy), modelAdmissionOfferSubmitted)
			e := f.latest(base)
			for _, state := range []string{"sandbox_probe_only", "network_admitted_unsettled"} {
				var err error
				e, err = base.AppendModelAdmissionDecision(context.Background(), modelAdmissionCoordinatorDecisionFromCurrent(e, state, "synthetic_probe_passed", "legacy-fixture", state, time.Now()))
				if err != nil {
					t.Fatal(err)
				}
			}
			for _, state := range []string{"catalog_priced", "settlement_capable"} {
				d := modelAdmissionCoordinatorDecisionFromCurrent(e, state, "legacy_catalog_verified", "legacy-fixture", state, time.Now())
				d.CatalogModelKey = "fixture-model"
				d.CatalogID = "legacy-tier2"
				d.CatalogBodyDigest = strings.Repeat("4", 64)
				d.CatalogSignatureKeyID = "legacy-key"
				d.CatalogSignaturePubkeyFingerprint = "ed25519-sha256:" + strings.Repeat("5", 64)
				d.ExpectedCatalogModelHash = f.p.ModelHash
				d.ExpectedCatalogModelHashAlgorithm = f.p.ModelHashAlgorithm
				var err error
				e, err = base.AppendModelAdmissionDecision(context.Background(), d)
				if err != nil {
					t.Fatal(err)
				}
			}
			if e.ArtifactAdmissionEvidence != nil {
				t.Fatal("legacy fixture acquired artifact evidence")
			}
			before := admissionReadbackHistory(t, base, f.candidate)
			f.s.modelAdmissions = admissionUnguardedStore{base}
			result := f.call(f.s, "status?candidate_id="+f.candidate, nil)
			f.require(result, e.State)
			if result.body["coordinator_event_id"] != e.CoordinatorEventID || !reflect.DeepEqual(e, f.latest(base)) || !reflect.DeepEqual(before, admissionReadbackHistory(t, base, f.candidate)) {
				t.Fatal("legacy HTTP read changed state/digests")
			}

		})
	})
	t.Run("sqlite-reopen-no-session", func(t *testing.T) {
		path := filepath.Join(t.TempDir(), "reopen.db")
		db, err := auth.OpenStore(path)
		if err != nil {
			t.Fatal(err)
		}
		defer db.Close()
		base, err := NewSQLiteModelAdmissionStore(db.DB())
		if err != nil {
			t.Fatal(err)
		}
		f := newAdmissionReadbackHTTP(t, base, true)
		payload := f.payload("offer", nil)
		f.require(f.call(f.s, "offers", payload), "settlement_capable")
		before := admissionReadbackHistory(t, base, f.candidate)
		if err = db.Close(); err != nil {
			t.Fatal(err)
		}
		reopened, err := auth.OpenStore(path)
		if err != nil {
			t.Fatal(err)
		}
		defer reopened.Close()
		store, err := NewSQLiteModelAdmissionStore(reopened.DB())
		if err != nil {
			t.Fatal(err)
		}
		if !reflect.DeepEqual(before, admissionReadbackHistory(t, store, f.candidate)) {
			t.Fatal("reopen changed durable evidence")
		}
		fresh := f.makeServer(store, pool.NewRegistry(nil))
		f.require(f.call(fresh, "status?candidate_id="+f.candidate, nil), modelAdmissionRevoked)
		f.require(f.call(fresh, "offers", payload), modelAdmissionRevoked)
		if f.probes.Load() != 1 {
			t.Fatal("reopen replay dispatched old transport")
		}
	})
}

func signedReadbackWithdrawal(t *testing.T, providerID, candidateID, servedModelRef string, priv ed25519.PrivateKey, overrides map[string]any) map[string]any {
	t.Helper()
	pubkey := priv.Public().(ed25519.PublicKey)
	pubkeyDigest := sha256.Sum256(pubkey)
	signedFields := map[string]any{
		"generated_at":       time.Now().UTC().Format(time.RFC3339Nano),
		"cli_version":        "1.8.111",
		"signature_domain":   "macprovider.model_admission.withdraw.v1",
		"provider_id":        providerID,
		"candidate_id":       candidateID,
		"served_model_ref":   servedModelRef,
		"catalog_model_key":  nil,
		"idempotency_key":    "withdraw_request_" + candidateID,
		"nonce":              "withdraw_nonce_" + candidateID,
		"timestamp":          time.Now().UTC().Format(time.RFC3339Nano),
		"reason_code":        "provider_requested",
		"signing_key_digest": hex.EncodeToString(pubkeyDigest[:]),
	}
	for key, value := range overrides {
		signedFields[key] = value
	}
	canonical, err := billing.CanonicalJSON(map[string]any{
		"signature_domain":   signedFields["signature_domain"],
		"provider_id":        signedFields["provider_id"],
		"candidate_id":       signedFields["candidate_id"],
		"served_model_ref":   signedFields["served_model_ref"],
		"catalog_model_key":  signedFields["catalog_model_key"],
		"idempotency_key":    signedFields["idempotency_key"],
		"nonce":              signedFields["nonce"],
		"timestamp":          signedFields["timestamp"],
		"reason_code":        signedFields["reason_code"],
		"signing_key_digest": signedFields["signing_key_digest"],
		"cli_version":        signedFields["cli_version"],
	})
	if err != nil {
		t.Fatal(err)
	}
	signature := ed25519.Sign(priv, canonical)
	request := map[string]any{"schema": "model_admission_withdraw_request.v1"}
	for key, value := range signedFields {
		request[key] = value
	}
	request["signature_algorithm"] = "ed25519"
	request["provider_signature"] = base64.StdEncoding.EncodeToString(signature)
	return request
}
