package ws

import (
	"bytes"
	"context"
	"crypto/ed25519"
	"encoding/json"
	"net"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"
	"time"

	"github.com/augstar/macprovider-coordinator/internal/billing"
	"github.com/augstar/macprovider-coordinator/internal/modelidentity"
	"github.com/augstar/macprovider-coordinator/internal/pool"
	"github.com/rs/zerolog"
)

// This fixture isolates WS/CAS/storage behavior; signed loader authority is
// separately exercised by buyer and the full integration fixture.
func probeArtifactEvidence(p pool.Provider, now time.Time) *billing.ArtifactAdmissionEvidence {
	key, _ := billing.ReceiptKeyID(p.ReceiptPubkey)
	return &billing.ArtifactAdmissionEvidence{
		ArtifactFeedSHA256: strings.Repeat("a", 64), ArtifactID: "mlx-primary", ArtifactHash: p.ModelHash, ArtifactHashAlgorithm: modelidentity.SnapshotManifestV1,
		ArtifactFeedSignerKeyID: "fixture-key", CandidateCatalogSHA256: strings.Repeat("b", 64), ArtifactReleaseID: "fixture", CandidateReleaseID: "fixture", CandidateSignerKeyID: "fixture-key",
		RateCardSHA256: strings.Repeat("c", 64), RateCardVersion: strings.Repeat("d", 64), RateCardSignerKeyID: "fixture-key", CatalogModelKey: "fixture-model", ConfigSnapshotID: 1,
		PromptRatePerMtok: 700000, PromptCacheHitRatePerMtok: 130000, CompletionRatePerMtok: 1700000, ProviderShareBPS: 8300, GlobalMultiplierPPM: 1200000, PriceUnit: "credits_per_million_tokens",
		ProviderSessionID: p.AssignedID, ProviderReceiptKeyID: key, AuthorityExpiresAtUnixMS: now.Add(time.Hour).UnixMilli(), ProbeExpiresAtUnixMS: now.Add(10 * time.Minute).UnixMilli(),
	}
}
func runAdmissionStores(t *testing.T, run func(*testing.T, ModelAdmissionStore)) {
	t.Helper()
	t.Run("memory", func(t *testing.T) { run(t, NewMemoryModelAdmissionStore()) })
	t.Run("sqlite", func(t *testing.T) {
		db := openProbeAdmissionStore(t)
		store, err := NewSQLiteModelAdmissionStore(db.DB())
		if err != nil {
			t.Fatal(err)
		}
		run(t, store)
	})
}
func TestPrimaryArtifactWireProbePromotionAcrossStores(t *testing.T) {
	for _, drift := range []string{"expired", "disconnected"} {
		t.Run(drift, func(t *testing.T) {
			runAdmissionStores(t, func(t *testing.T, store ModelAdmissionStore) {
				serverConn, providerConn := net.Pipe()
				defer serverConn.Close()
				defer providerConn.Close()
				now := time.Now().UTC()
				p := pool.Provider{ProviderID: "fixture", AssignedID: "fixture-session", ModelID: "mlx-community/Fixture", ModelHash: strings.Repeat("3", 64), ExpectedModelHash: strings.Repeat("3", 64), ModelHashAlgorithm: modelidentity.SnapshotManifestV1,
					State: pool.StateReady, InferencePath: pool.InferencePathWSTunneled, MaxConcurrency: 1, SlotsFree: 1, SlotsTotal: 1, ReceiptPubkey: make([]byte, ed25519.PublicKeySize), LastActivityAt: now, LastHeartbeatAt: now}
				registry := pool.NewRegistry(nil)
				registry.Register(&p, serverConn)
				registry.ApplyStateUpdate(p.ProviderID, p.AssignedID, pool.StateUpdate{State: pool.StateReady, At: now})
				p, _ = registry.Resolve(p.ProviderID, p.AssignedID)
				tokens, bearer, _ := bindModelAdmissionProbeIdentity(t, p.ProviderID)
				server := NewServer(modelAdmissionProbeAuthConfig(), registry, zerolog.Nop(), WithTokenValidator(tokens), WithTokenIssuer(tokens), WithBootstrapTokenStore(tokens), WithModelAdmissionStore(store))
				session := newProviderSession(p.ProviderID, p.AssignedID, serverConn, 1)
				server.sessions.Store(sessionKey(p.ProviderID, p.AssignedID), session)
				go session.runWriter()
				setFixtureModelAdmissionAuthority(server, func(_ context.Context, provider pool.Provider, event ModelAdmissionEvent) (ModelAdmissionEvent, error) {
					event.CatalogModelKey = "fixture-model"
					event.CatalogID = "independent-tier2"
					event.CatalogBodyDigest = strings.Repeat("4", 64)
					event.CatalogSignatureKeyID = "tier2-key"
					event.CatalogSignaturePubkeyFingerprint = "ed25519-sha256:" + strings.Repeat("5", 64)
					event.ExpectedCatalogModelHash = provider.ModelHash
					event.ExpectedCatalogModelHashAlgorithm = modelidentity.SnapshotManifestV1
					event.ArtifactAdmissionEvidence = probeArtifactEvidence(provider, now)
					if err := event.ArtifactAdmissionEvidence.Validate(); err != nil {
						t.Fatalf("fixture invalid: %v %+v", err, event.ArtifactAdmissionEvidence)
					}
					return event, nil
				})
				offer := modelAdmissionProbeOffer("primary", "a")
				offer.ProviderID = p.ProviderID
				offer.ServedModelRef = p.ModelID
				offer.CatalogModelKey = "fixture-model"
				offer.RuntimeSource = "mlx_cache"
				offer.OfferIdentitySHA256 = strings.Repeat("9", 64)
				submitted, _, err := store.AppendModelAdmissionOffer(context.Background(), offer)
				if err != nil {
					t.Fatal(err)
				}
				done := make(chan struct{})
				go func() {
					defer close(done)
					request := readModelAdmissionProbeRequestFrame(t, providerConn)
					server.handleInferenceChunk(p.ProviderID, p.AssignedID, mustJSON(InferenceResponseChunk{Type: "inference_response_chunk", RequestID: request.RequestID, Seq: 0, Data: `{"choices":[{"message":{"content":"ok"}}]}`}))
					server.handleInferenceEnd(p.ProviderID, p.AssignedID, mustJSON(InferenceResponseEnd{Type: "inference_response_end", RequestID: request.RequestID, Status: "complete", ChunksSent: 1}))
				}()
				promoted := server.maybeRunModelAdmissionSyntheticProbeForOffer(context.Background(), submitted, false)
				<-done
				if promoted.State != "settlement_capable" || promoted.PreviousState != "catalog_priced" || promoted.ArtifactAdmissionEvidence == nil {
					t.Fatalf("not promoted: %+v", promoted)
				}
				loaded, found, err := store.LatestModelAdmissionStatus(context.Background(), p.ProviderID, offer.CandidateID)
				if err != nil || !found || loaded.ArtifactAdmissionEvidence == nil || *loaded.ArtifactAdmissionEvidence != *promoted.ArtifactAdmissionEvidence || loaded.RuntimeSource != "mlx_cache" {
					t.Fatalf("authority readback failed: %+v %v", loaded, err)
				}
				getStatus := func() map[string]any {
					request := httptest.NewRequest(http.MethodGet, "/v1/provider/model-admission/status?candidate_id="+offer.CandidateID, nil)
					request.Header.Set("Authorization", "Bearer "+bearer)
					response := httptest.NewRecorder()
					server.Handler().ServeHTTP(response, request)
					if response.Code != http.StatusOK {
						t.Fatalf("status %d %s", response.Code, response.Body.String())
					}
					return decodeModelAdmissionProbeMap(t, response.Body.String())
				}
				if got := getStatus()["admission_state"]; got != "settlement_capable" {
					t.Fatalf("current status %v", got)
				}
				if drift == "expired" {
					server.now = func() time.Time { return now.Add(11 * time.Minute) }
				} else {
					server.sessions.Delete(sessionKey(p.ProviderID, p.AssignedID))
				}
				if got := getStatus()["admission_state"]; got != "revoked" {
					t.Fatalf("stale status %v", got)
				}
				// Original offer replay is read-only; it cannot manufacture another probe.
				replayed := server.maybeRunModelAdmissionSyntheticProbeForOffer(context.Background(), submitted, true)
				if replayed.CoordinatorEventID != submitted.CoordinatorEventID {
					t.Fatal("offer replay changed state")
				}
			})
		})
	}
}
func TestPrimaryArtifactAdmissionCASRejectsWithdrawReofferAndRetryReplay(t *testing.T) {
	runAdmissionStores(t, func(t *testing.T, store ModelAdmissionStore) {
		ctx := context.Background()
		offer := modelAdmissionProbeOffer("cas", "a")
		offer.RuntimeSource = "mlx_cache"
		offer.OfferIdentitySHA256 = strings.Repeat("9", 64)
		submitted, _, err := store.AppendModelAdmissionOffer(ctx, offer)
		if err != nil {
			t.Fatal(err)
		}
		decision, _ := modelAdmissionSandboxProbeDecision(submitted, "synthetic_probe_required", time.Now())
		retries := store.(modelAdmissionRetryStore)
		retry := offer
		retry.RequestID = "retry-a"
		retry.Nonce = "retry-nonce-a"
		retry.PayloadDigestSHA256 = strings.Repeat("b", 64)
		outcome, replay, err := retries.reserveModelAdmissionRetry(ctx, retry)
		if err != nil || replay || outcome.CoordinatorEventID != submitted.CoordinatorEventID {
			t.Fatalf("reserve %v %v", replay, err)
		}
		changed := retry
		changed.RequestID = "retry-b"
		changed.Nonce = "retry-nonce-b"
		changed.OfferIdentitySHA256 = strings.Repeat("c", 64)
		if _, _, err := retries.reserveModelAdmissionRetry(ctx, changed); err == nil {
			t.Fatal("changed tuple retry accepted")
		}
		withdrawal := offer
		withdrawal.RequestID = "withdraw"
		withdrawal.Nonce = "withdraw-nonce"
		withdrawal.PayloadDigestSHA256 = strings.Repeat("d", 64)
		withdrawn, _, err := store.AppendModelAdmissionWithdrawal(ctx, withdrawal)
		if err != nil {
			t.Fatal(err)
		}
		if err := retries.completeModelAdmissionRetry(ctx, retry, withdrawn); err != nil {
			t.Fatal(err)
		}
		replayed, replay, err := retries.reserveModelAdmissionRetry(ctx, retry)
		if err != nil || !replay || replayed.CoordinatorEventID != withdrawn.CoordinatorEventID {
			t.Fatal("retry replay did not return recorded outcome")
		}
		collision := offer
		collision.RequestID = retry.RequestID
		collision.Nonce = "new-offer-colliding-retry"
		if _, _, err := store.AppendModelAdmissionOffer(ctx, collision); err == nil {
			t.Fatal("offer reused reserved retry request")
		}
		collision.RequestID = "new-offer-colliding-retry"
		collision.Nonce = retry.Nonce
		if _, _, err := store.AppendModelAdmissionOffer(ctx, collision); err == nil {
			t.Fatal("offer reused reserved retry nonce")
		}
		reoffer := offer
		reoffer.RequestID = "reoffer"
		reoffer.Nonce = "reoffer-nonce"
		reoffer.DiscoveryDigestSHA256 = strings.Repeat("e", 64)
		reoffer.PayloadDigestSHA256 = strings.Repeat("f", 64)
		if _, _, err := store.AppendModelAdmissionOffer(ctx, reoffer); err != nil {
			t.Fatal(err)
		}
		if _, err := store.AppendModelAdmissionDecision(ctx, decision); err == nil {
			t.Fatal("stale probe overwrote reoffer")
		}
	})
}

func TestSignedAdmissionRetryResumesPendingLiveSessionAndRejectsChangedTuple(t *testing.T) {
	runAdmissionStores(t, func(t *testing.T, admissions ModelAdmissionStore) {
		const providerID = "fixture-retry-provider"
		tokens, bearer, private := bindModelAdmissionProbeIdentity(t, providerID)
		registry := pool.NewRegistry(nil)
		server := NewServer(modelAdmissionProbeAuthConfig(), registry, zerolog.Nop(), WithTokenValidator(tokens), WithTokenIssuer(tokens), WithBootstrapTokenStore(tokens), WithModelAdmissionStore(admissions))
		candidate := "byom_" + strings.Repeat("a", 52)
		original := signedModelAdmissionProbeOffer(t, providerID, candidate, "ollama:fixture", private, nil)
		status, body := postModelAdmissionProbeOffer(t, server, bearer, original)
		if status != http.StatusOK || decodeModelAdmissionProbeMap(t, body)["admission_state"] != "offer_submitted" {
			t.Fatalf("pending offer %d %s", status, body)
		}
		postRetry := func(payload map[string]any) (int, string) {
			raw, _ := json.Marshal(payload)
			request := httptest.NewRequest(http.MethodPost, "/v1/provider/model-admission/retry", bytes.NewReader(raw))
			request.Header.Set("Authorization", "Bearer "+bearer)
			response := httptest.NewRecorder()
			server.Handler().ServeHTTP(response, request)
			return response.Code, response.Body.String()
		}
		changed := signedModelAdmissionProbeOffer(t, providerID, candidate, "ollama:fixture", private, map[string]any{"nonce": "changed", "idempotency_key": "changed", "discovery_digest_sha256": strings.Repeat("f", 64)})
		if status, body := postRetry(changed); status != http.StatusConflict {
			t.Fatalf("changed pending tuple %d %s", status, body)
		}
		serverConn, providerConn := net.Pipe()
		defer serverConn.Close()
		defer providerConn.Close()
		p := pool.Provider{ProviderID: providerID, AssignedID: "retry-session", ModelID: "ollama:fixture", State: pool.StateReady, InferencePath: pool.InferencePathWSTunneled, MaxConcurrency: 1, SlotsFree: 1, SlotsTotal: 1, LastActivityAt: time.Now(), LastHeartbeatAt: time.Now()}
		registry.Register(&p, serverConn)
		session := newProviderSession(providerID, p.AssignedID, serverConn, 1)
		server.sessions.Store(sessionKey(providerID, p.AssignedID), session)
		go session.runWriter()
		done := make(chan struct{})
		go func() {
			defer close(done)
			request := readModelAdmissionProbeRequestFrame(t, providerConn)
			server.handleInferenceChunk(providerID, p.AssignedID, mustJSON(InferenceResponseChunk{Type: "inference_response_chunk", RequestID: request.RequestID, Seq: 0, Data: `{"choices":[{"message":{"content":"ok"}}]}`}))
			server.handleInferenceEnd(providerID, p.AssignedID, mustJSON(InferenceResponseEnd{Type: "inference_response_end", RequestID: request.RequestID, Status: "complete", ChunksSent: 1}))
		}()
		retry := signedModelAdmissionProbeOffer(t, providerID, candidate, "ollama:fixture", private, map[string]any{"nonce": "retry-fresh", "idempotency_key": "retry-fresh"})
		status, body = postRetry(retry)
		<-done
		if status != http.StatusOK || decodeModelAdmissionProbeMap(t, body)["admission_state"] != "network_admitted_unsettled" {
			t.Fatalf("retry %d %s", status, body)
		}
		eventID := decodeModelAdmissionProbeMap(t, body)["coordinator_event_id"]
		status, body = postRetry(retry)
		if status != http.StatusOK || decodeModelAdmissionProbeMap(t, body)["coordinator_event_id"] != eventID {
			t.Fatalf("retry replay %d %s", status, body)
		}
		forged := signedModelAdmissionProbeOffer(t, providerID, candidate, "ollama:fixture", private, map[string]any{"nonce": "forged", "idempotency_key": "forged"})
		forged["runtime_source"] = "mlx_cache"
		if status, _ := postRetry(forged); status == http.StatusOK {
			t.Fatal("unsigned runtime alteration accepted")
		}
	})
}
