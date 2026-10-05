package buyer

import (
	"bytes"
	"context"
	"crypto/ecdh"
	"crypto/ed25519"
	"database/sql"
	"encoding/base64"
	"encoding/hex"
	"encoding/json"
	"net/http"
	"path/filepath"
	"sync"
	"testing"
	"time"

	"github.com/augstar/macprovider-coordinator/internal/billing"
	"github.com/augstar/macprovider-coordinator/internal/config"
	"github.com/augstar/macprovider-coordinator/internal/modelidentity"
	"github.com/augstar/macprovider-coordinator/internal/pool"
	"github.com/augstar/macprovider-coordinator/internal/relayblind"
	"github.com/augstar/macprovider-coordinator/internal/requestlog"
	providerws "github.com/augstar/macprovider-coordinator/internal/ws"
	"github.com/rs/zerolog"
)

const relayBlindSettlementTestHash = "0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef"

// relayBlindSettlementProvider is a session that satisfies every SPEC-022
// R-13.2 prerequisite: pinned receipt key, verified canonical model identity,
// Tier-2 material (installed by withModelACatalogMaterial), and the
// SPEC-001-R005 capability.
func relayBlindSettlementProvider(receiptPub ed25519.PublicKey) pool.Provider {
	return pool.Provider{
		ProviderID: "provider-a", AssignedID: "session-a", ModelID: "model-a",
		MaxContextTokens: 4096, MaxConcurrency: 1, SlotsFree: 1, SlotsTotal: 1,
		State: pool.StateReady, AuthState: pool.AuthBearerValidated, InferencePath: pool.InferencePathWSTunneled,
		ModelHash: relayBlindSettlementTestHash, ModelHashAlgorithm: modelidentity.SnapshotManifestV1,
		ExpectedModelHash: relayBlindSettlementTestHash, HashStatus: pool.HashStatusVerified,
		ReceiptPubkey: append([]byte(nil), receiptPub...), RelayBlindSettlementReceiptV1: true,
	}
}

type relayBlindSettlementFixture struct {
	server          *Server
	billing         *billing.Store
	db              *sql.DB
	providerPrivate *ecdh.PrivateKey
	receiptPrivate  ed25519.PrivateKey
	registry        *pool.Registry
}

func newRelayBlindSettlementFixture(t *testing.T, now time.Time, mode, profile string, mutate func(*pool.Provider), relay RelayBlindRelayFunc, opts ...Option) relayBlindSettlementFixture {
	t.Helper()
	withModelACatalogMaterial(t)
	store, err := relayblind.OpenStore(filepath.Join(t.TempDir(), "relay-blind.sqlite"))
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { _ = store.Close() })
	identityPublic, identityPrivate, _ := ed25519.GenerateKey(nil)
	providerPrivate, _ := ecdh.X25519().GenerateKey(nil)
	record, err := relayblind.NewSignedKeyRecord(providerPrivate.PublicKey().Bytes(), identityPrivate, []string{"model-a"}, relayblind.MaxEncryptedRequestBytes, now.Add(-time.Minute), now.Add(time.Hour))
	if err != nil {
		t.Fatal(err)
	}
	authority, err := relayblind.NewAuthority(store, map[string]string{"provider-a": base64.RawURLEncoding.EncodeToString(identityPublic)}, 8)
	if err != nil {
		t.Fatal(err)
	}
	if err := authority.AcceptProviderKeys(context.Background(), "provider-a", "session-a", []relayblind.KeyRecord{record}, now); err != nil {
		t.Fatal(err)
	}
	reqLog, err := requestlog.OpenStore(filepath.Join(t.TempDir(), "coordinator.db"))
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { _ = reqLog.Close() })
	billingStore, err := billing.NewStore(reqLog.DB())
	if err != nil {
		t.Fatal(err)
	}
	settlementCfg := config.Default().Settlement
	settlementCfg.VerifiedModelSettlementMode = mode
	billingStore.SetSettlementConfig(settlementCfg)
	snapshotID, err := billingStore.InsertConfigSnapshot(context.Background(), config.Default().Rewards, now)
	if err != nil {
		t.Fatal(err)
	}
	seed := bytes.Repeat([]byte{0x42}, ed25519.SeedSize)
	receiptPrivate := ed25519.NewKeyFromSeed(seed)
	provider := relayBlindSettlementProvider(receiptPrivate.Public().(ed25519.PublicKey))
	if mutate != nil {
		mutate(&provider)
	}
	registry := pool.NewRegistry(nil)
	if _, registered := registry.RegisterAt(&provider, nil, now); !registered {
		t.Fatal("provider registration rejected")
	}
	// The first state update publishes the staged receipt key.
	slotsFree := 1
	registry.ApplyStateUpdate("provider-a", "session-a", pool.StateUpdate{State: pool.StateReady, SlotsFree: &slotsFree, At: now})
	if relay == nil {
		relay = func(context.Context, pool.Provider, string, []byte, bool, providerws.RelayBlindDispatchContext) (*providerws.RelayStream, error) {
			return nil, context.Canceled
		}
	}
	cfg := config.Default().RelayBlind
	cfg.Enabled = true
	cfg.MaxActiveReservations = 100
	cfg.MetadataRequestsPerMinute = 100
	cfg.EnforceSettlementProfile = profile
	opts = append([]Option{WithGatewayServiceToken("gateway-token"), WithRequireGatewayContext(true),
		WithRequestLog(reqLog), WithBilling(billingStore, config.Default().Rewards), WithBillingSnapshotID(snapshotID), WithRelayBlind(cfg, store, relay)}, opts...)
	server := NewServer(registry, zerolog.Nop(), now, opts...)
	server.now = func() time.Time { return now }
	return relayBlindSettlementFixture{server: server, billing: billingStore, db: reqLog.DB(), providerPrivate: providerPrivate, receiptPrivate: receiptPrivate, registry: registry}
}

// relayBlindFixtureExecute runs reservation, consume, and chat, returning the
// chat response and the consumed envelope digest.
func relayBlindFixtureExecute(t *testing.T, f relayBlindSettlementFixture, now time.Time, stream bool) (*http.Response, string, int) {
	t.Helper()
	raw, _ := json.Marshal(relayblind.ReservationRequest{EndpointFamily: relayblind.EndpointChatCompletions, Model: "model-a", Stream: stream, MaxOutputTokens: 32, InputTokenUpperBound: 96, EncryptedRequestBytes: 2048})
	response := relayBlindRequest(t, f.server, http.MethodPost, "/v1/relay-blind/route-reservations", raw, "")
	if response.Code != http.StatusOK {
		return response.Result(), "", response.Code
	}
	reservation, err := relayblind.ParseReservationResponse(response.Body.Bytes())
	if err != nil {
		t.Fatal(err)
	}
	envelope, err := reservation.NewEnvelope("external-request-a", now, bytes.Repeat([]byte{0x33}, 32))
	if err != nil {
		t.Fatal(err)
	}
	buyerPrivate, _ := ecdh.X25519().GenerateKey(nil)
	envelope, err = envelope.Encrypt([]byte(`{"model":"model-a","messages":[{"role":"user","content":"secret"}]}`), f.providerPrivate.PublicKey().Bytes(), buyerPrivate.Bytes())
	if err != nil {
		t.Fatal(err)
	}
	envelopeRaw, _ := json.Marshal(envelope)
	response = relayBlindRequest(t, f.server, http.MethodPost, "/v1/relay-blind/consume", envelopeRaw, "")
	if response.Code != http.StatusOK {
		t.Fatalf("consume status=%d body=%s", response.Code, response.Body.String())
	}
	consume, err := relayblind.ParseConsumeResponse(response.Body.Bytes())
	if err != nil {
		t.Fatal(err)
	}
	response = relayBlindRequest(t, f.server, http.MethodPost, "/v1/chat/completions", envelopeRaw, consume.ExecutionAuthorization)
	return response.Result(), consume.EnvelopeDigest, response.Code
}

func TestRelayBlindAvailabilityUnderEnforceNeedsSettlementProfile(t *testing.T) {
	now := time.Unix(1_800_200_000, 0).UTC()
	for _, tc := range []struct {
		mode, profile string
		want          bool
	}{
		{billing.RouteSnapshotModeObserve, "", true},
		{billing.RouteSnapshotModeEnforce, "", false},
		{billing.RouteSnapshotModeEnforce, config.RelayBlindSettlementProfileV1, true},
	} {
		f := newRelayBlindSettlementFixture(t, now, tc.mode, tc.profile, nil, nil)
		if got := f.server.relayBlindAvailable(); got != tc.want {
			t.Fatalf("mode=%s profile=%q available=%v want %v", tc.mode, tc.profile, got, tc.want)
		}
	}
}

// AC-022-68: under enforce a session without the capability, without a
// pinned receipt key, or failing any R-2.2 to R-2.7 predicate is never
// reserved for relay-blind work. Observe keeps its behavior.
func TestRelayBlindEnforceSelectionAppliesSettlementPrerequisites(t *testing.T) {
	now := time.Unix(1_800_200_100, 0).UTC()
	cases := []struct {
		name   string
		mutate func(*pool.Provider)
		reason string
	}{
		{name: "eligible", reason: ""},
		{name: "no capability", mutate: func(p *pool.Provider) { p.RelayBlindSettlementReceiptV1 = false }, reason: "relay_blind_settlement_capability_missing"},
		{name: "no receipt key", mutate: func(p *pool.Provider) { p.ReceiptPubkey = nil }, reason: "receipt_key_missing"},
		{name: "hash mismatch", mutate: func(p *pool.Provider) { p.HashStatus = pool.HashStatusMismatch }, reason: "hash_not_verified"},
		{name: "hash uncatalogued", mutate: func(p *pool.Provider) { p.HashStatus = pool.HashStatusUncatalogued }, reason: "hash_not_verified"},
		{name: "identity drift", mutate: func(p *pool.Provider) { p.ModelHash = "f" + relayBlindSettlementTestHash[1:] }, reason: "route_snapshot_unavailable"},
		{name: "pre-ack", mutate: func(p *pool.Provider) { p.HandshakeAckPending = true }, reason: "handshake_ack_pending"},
	}
	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			f := newRelayBlindSettlementFixture(t, now, billing.RouteSnapshotModeEnforce, config.RelayBlindSettlementProfileV1, tc.mutate, nil)
			provider, _ := f.registry.Resolve("provider-a", "session-a")
			if got := f.server.relayBlindSettlementPrerequisite(provider); got != tc.reason {
				t.Fatalf("prerequisite=%q want %q", got, tc.reason)
			}
			_, _, found := f.server.selectRelayBlindProvider(context.Background(), "model-a", 2048, false, relayblind.KeyClassRelayBlind)
			if found != (tc.reason == "") {
				t.Fatalf("selected=%v want %v", found, tc.reason == "")
			}
			observe := newRelayBlindSettlementFixture(t, now, billing.RouteSnapshotModeObserve, "", tc.mutate, nil)
			observed, _ := observe.registry.Resolve("provider-a", "session-a")
			if got := observe.server.relayBlindSettlementPrerequisite(observed); got != "" {
				t.Fatalf("observe prerequisite=%q, want none", got)
			}
		})
	}
	t.Run("no catalog material", func(t *testing.T) {
		f := newRelayBlindSettlementFixture(t, now, billing.RouteSnapshotModeEnforce, config.RelayBlindSettlementProfileV1, nil, nil)
		withoutCatalogMaterial(t)
		provider, _ := f.registry.Resolve("provider-a", "session-a")
		if got := f.server.relayBlindSettlementPrerequisite(provider); got != "catalog_material_missing" {
			t.Fatalf("prerequisite=%q", got)
		}
		raw, _ := json.Marshal(relayblind.ReservationRequest{EndpointFamily: relayblind.EndpointChatCompletions, Model: "model-a", MaxOutputTokens: 32, InputTokenUpperBound: 96, EncryptedRequestBytes: 2048})
		response := relayBlindRequest(t, f.server, http.MethodPost, "/v1/relay-blind/route-reservations", raw, "")
		if response.Code != http.StatusServiceUnavailable || !bytes.Contains(response.Body.Bytes(), []byte("relay_blind_provider_unsupported")) {
			t.Fatalf("reservation status=%d body=%s", response.Code, response.Body.String())
		}
	})
}

// AC-022-67 (dispatch half): under enforce a capable session gets an R-3.1
// relay-blind snapshot before dispatch, and the dispatch carries the
// SPEC-001-R005 metadata bound to it. The credit is an enforce credit.
func TestRelayBlindEnforceRecordsSnapshotBeforeDispatch(t *testing.T) {
	for _, stream := range []bool{false, true} {
		t.Run(map[bool]string{false: "nonstream", true: "stream"}[stream], func(t *testing.T) {
			now := time.Unix(1_800_200_200, 0).UTC()
			var mu sync.Mutex
			var captured providerws.RelayBlindDispatchContext
			var snapshotsAtDispatch int
			var f relayBlindSettlementFixture
			f = newRelayBlindSettlementFixture(t, now, billing.RouteSnapshotModeEnforce, config.RelayBlindSettlementProfileV1, nil,
				func(_ context.Context, _ pool.Provider, requestID string, _ []byte, _ bool, relayContext providerws.RelayBlindDispatchContext) (*providerws.RelayStream, error) {
					mu.Lock()
					captured = relayContext
					_ = f.db.QueryRow(`SELECT COUNT(*) FROM settlement_route_snapshots`).Scan(&snapshotsAtDispatch)
					mu.Unlock()
					return relayBlindFixtureStream(requestID, relayContext, stream), nil
				})
			result, envelopeDigest, code := relayBlindFixtureExecute(t, f, now, stream)
			if code != http.StatusOK {
				t.Fatalf("chat status=%d", code)
			}
			_ = result
			mu.Lock()
			defer mu.Unlock()
			if snapshotsAtDispatch != 1 {
				t.Fatalf("journaled snapshots at dispatch=%d want 1", snapshotsAtDispatch)
			}
			meta := captured.Settlement
			if meta == nil {
				t.Fatal("dispatch carried no relay_blind_settlement metadata")
			}
			raw, _ := base64.RawURLEncoding.DecodeString(envelopeDigest)
			var entrypoint, basis, promptHash, digest, mode string
			if err := f.db.QueryRow(`SELECT paid_entrypoint, prompt_hash_basis, prompt_hash, route_snapshot_digest, route_snapshot_mode FROM settlement_route_snapshots`).Scan(&entrypoint, &basis, &promptHash, &digest, &mode); err != nil {
				t.Fatal(err)
			}
			if entrypoint != billing.PaidEntrypointRelayBlindChat || basis != billing.PromptHashBasisRelayBlindEnvelopeV1 || promptHash != hex.EncodeToString(raw) || mode != billing.RouteSnapshotModeEnforce {
				t.Fatalf("snapshot entrypoint=%s basis=%s prompt_hash=%s mode=%s", entrypoint, basis, promptHash, mode)
			}
			if meta.PaidEntrypoint != entrypoint || meta.PromptHashBasis != basis || meta.RelayBlindEnvelopeDigest != envelopeDigest ||
				meta.RouteSnapshotDigest != digest || meta.RouteSnapshotMode != mode || meta.ProviderID != "provider-a" ||
				meta.ExpectedCatalogModelHash != relayBlindSettlementTestHash || meta.AttemptN != 0 || meta.PendingDeadlineSeconds <= 0 {
				t.Fatalf("metadata=%+v", meta)
			}
			if meta.RequestID == captured.RequestID {
				t.Fatalf("settlement request_id must be the coordinator ledger id, not the envelope request_id %q", captured.RequestID)
			}
			var policy string
			if err := f.db.QueryRow(`SELECT settlement_policy_mode FROM ledger_request_credits`).Scan(&policy); err != nil {
				t.Fatal(err)
			}
			if policy != billing.RouteSnapshotModeEnforce {
				t.Fatalf("ledger settlement_policy_mode=%q want enforce", policy)
			}
		})
	}
}

// relayBlindLegacyRouteGuard is the SPEC-047-R001 legacy compare-and-insert
// guard a production coordinator wires: it records each expectation.
type relayBlindLegacyRouteGuard struct {
	mu      sync.Mutex
	expects []providerws.ModelAdmissionRouteExpectation
}

func (g *relayBlindLegacyRouteGuard) ModelAdmissionBindingGeneration(string) uint64 { return 7 }

func (g *relayBlindLegacyRouteGuard) CompareAndInsertModelAdmissionRouteSnapshot(_ context.Context, expect providerws.ModelAdmissionRouteExpectation, insert func() error) error {
	g.mu.Lock()
	g.expects = append(g.expects, expect)
	g.mu.Unlock()
	if expect.CandidateID != "" {
		return providerws.ErrModelAdmissionRouteStale
	}
	return insert()
}

// With the model-admission store and route guard wired, as in production, the
// relay-blind snapshot evaluates and remembers the legacy admission route
// expectation itself, because relay-blind selects its session at reservation
// and never runs the plaintext selection that records it.
func TestRelayBlindEnforceSnapshotWithModelAdmissionGuard(t *testing.T) {
	now := time.Unix(1_800_200_300, 0).UTC()
	guard := &relayBlindLegacyRouteGuard{}
	var snapshotsAtDispatch int
	var f relayBlindSettlementFixture
	f = newRelayBlindSettlementFixture(t, now, billing.RouteSnapshotModeEnforce, config.RelayBlindSettlementProfileV1, nil,
		func(_ context.Context, _ pool.Provider, requestID string, _ []byte, _ bool, relayContext providerws.RelayBlindDispatchContext) (*providerws.RelayStream, error) {
			_ = f.db.QueryRow(`SELECT COUNT(*) FROM settlement_route_snapshots`).Scan(&snapshotsAtDispatch)
			return relayBlindFixtureStream(requestID, relayContext, false), nil
		},
		WithModelAdmissionStore(providerws.NewMemoryModelAdmissionStore()), WithModelAdmissionRouteGuard(guard))
	if _, _, code := relayBlindFixtureExecute(t, f, now, false); code != http.StatusOK {
		t.Fatalf("chat status=%d", code)
	}
	if snapshotsAtDispatch != 1 {
		t.Fatalf("journaled snapshots at dispatch=%d want 1", snapshotsAtDispatch)
	}
	guard.mu.Lock()
	defer guard.mu.Unlock()
	if len(guard.expects) != 1 || guard.expects[0].ProviderID != "provider-a" || guard.expects[0].CandidateID != "" {
		t.Fatalf("route guard expectations=%+v want one legacy expectation for provider-a", guard.expects)
	}
}

// A capable session that loses a prerequisite between consume and dispatch
// is not dispatched: the reservation burns with no snapshot and no credit.
func TestRelayBlindEnforcePreDispatchRecheckBurnsReservation(t *testing.T) {
	now := time.Unix(1_800_200_300, 0).UTC()
	var dispatched bool
	var f relayBlindSettlementFixture
	f = newRelayBlindSettlementFixture(t, now, billing.RouteSnapshotModeEnforce, config.RelayBlindSettlementProfileV1, nil,
		func(_ context.Context, _ pool.Provider, requestID string, _ []byte, stream bool, relayContext providerws.RelayBlindDispatchContext) (*providerws.RelayStream, error) {
			dispatched = true
			return relayBlindFixtureStream(requestID, relayContext, stream), nil
		})
	raw, _ := json.Marshal(relayblind.ReservationRequest{EndpointFamily: relayblind.EndpointChatCompletions, Model: "model-a", MaxOutputTokens: 32, InputTokenUpperBound: 96, EncryptedRequestBytes: 2048})
	response := relayBlindRequest(t, f.server, http.MethodPost, "/v1/relay-blind/route-reservations", raw, "")
	reservation, err := relayblind.ParseReservationResponse(response.Body.Bytes())
	if err != nil {
		t.Fatalf("reservation status=%d err=%v", response.Code, err)
	}
	envelope, _ := reservation.NewEnvelope("external-request-b", now, bytes.Repeat([]byte{0x34}, 32))
	buyerPrivate, _ := ecdh.X25519().GenerateKey(nil)
	envelope, _ = envelope.Encrypt([]byte(`{"model":"model-a","messages":[]}`), f.providerPrivate.PublicKey().Bytes(), buyerPrivate.Bytes())
	envelopeRaw, _ := json.Marshal(envelope)
	response = relayBlindRequest(t, f.server, http.MethodPost, "/v1/relay-blind/consume", envelopeRaw, "")
	consume, err := relayblind.ParseConsumeResponse(response.Body.Bytes())
	if err != nil {
		t.Fatalf("consume status=%d", response.Code)
	}
	f.registry.MarkHashStatusIfSession("provider-a", "session-a", pool.HashStatusMismatch)
	response = relayBlindRequest(t, f.server, http.MethodPost, "/v1/chat/completions", envelopeRaw, consume.ExecutionAuthorization)
	if response.Code == http.StatusOK || dispatched {
		t.Fatalf("status=%d dispatched=%v", response.Code, dispatched)
	}
	var snapshots int
	_ = f.db.QueryRow(`SELECT COUNT(*) FROM settlement_route_snapshots`).Scan(&snapshots)
	if snapshots != 0 {
		t.Fatalf("snapshots=%d want 0", snapshots)
	}
}

func relayBlindFixtureStream(requestID string, relayContext providerws.RelayBlindDispatchContext, stream bool) *providerws.RelayStream {
	chunks := make(chan providerws.InferenceResponseChunk)
	done := make(chan providerws.InferenceResponseEnd, 1)
	validations := make(chan providerws.RelayBlindValidation, 1)
	validations <- relayBlindValidationForContext(relayContext, "validated", 11)
	terminal := relayBlindValidationForContext(relayContext, "terminal", 11)
	go func() {
		if stream {
			chunks <- providerws.InferenceResponseChunk{RequestID: requestID, Seq: 0, Data: "data: {\"choices\":[]}\n\n"}
		} else {
			chunks <- providerws.InferenceResponseChunk{RequestID: requestID, Seq: 0, Data: "{\"choices\":[]}"}
		}
		close(chunks)
		done <- providerws.InferenceResponseEnd{RequestID: requestID, Status: "complete", Usage: json.RawMessage(`{"prompt_tokens":11,"completion_tokens":3,"total_tokens":14}`), RelayBlindValidation: &terminal}
	}()
	return &providerws.RelayStream{RequestID: requestID, Chunks: chunks, Done: done, Errors: make(chan error, 1), Validations: validations}
}
