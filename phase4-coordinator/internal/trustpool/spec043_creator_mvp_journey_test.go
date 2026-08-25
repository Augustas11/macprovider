package trustpool_test

import (
	"bytes"
	"context"
	"crypto/ed25519"
	"crypto/sha256"
	"database/sql"
	"encoding/base64"
	"encoding/hex"
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"os"
	"os/exec"
	"path/filepath"
	"strconv"
	"strings"
	"sync/atomic"
	"testing"
	"time"

	"github.com/augstar/macprovider-coordinator/internal/billing"
	"github.com/augstar/macprovider-coordinator/internal/buyer"
	"github.com/augstar/macprovider-coordinator/internal/config"
	"github.com/augstar/macprovider-coordinator/internal/modelidentity"
	"github.com/augstar/macprovider-coordinator/internal/pool"
	"github.com/augstar/macprovider-coordinator/internal/poolmanifest"
	"github.com/augstar/macprovider-coordinator/internal/requestlog"
	"github.com/augstar/macprovider-coordinator/internal/sqliteutil"
	"github.com/augstar/macprovider-coordinator/internal/tier2"
	"github.com/augstar/macprovider-coordinator/internal/trustpool"
	"github.com/rs/zerolog"
	_ "modernc.org/sqlite"
)

const (
	creatorMVPJourneyID        = "JOURNEY-TRUSTED-POOL-CREATOR-MVP"
	creatorMVPEvidenceSchema   = "macprovider.trusted-pool-creator-mvp-evidence.v1"
	creatorMVPEnvironmentClass = "isolated-candidate-trusted-pool-creator-mvp"
	creatorMVPArtifactID       = "redacted-trusted-pool-creator-mvp"
	creatorMVPModelHash        = "0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef"
	creatorMVPOperatorKey      = "operator-secret"
	creatorMVPCreatorToken     = "creator-token-a"
	creatorMVPBuyerAccount     = "acct-allowed"
	creatorMVPProviderID       = "provider-a"
)

func TestJourneyTrustedPoolCreatorMVPCandidate(t *testing.T) {
	configureCreatorMVPCatalog(t)

	dbPath := filepath.Join(t.TempDir(), "trustpool.sqlite")
	db, err := sql.Open("sqlite", sqliteutil.WithPragmas(dbPath))
	if err != nil {
		t.Fatalf("open sqlite: %v", err)
	}
	db.SetMaxOpenConns(1)
	db.SetMaxIdleConns(1)
	t.Cleanup(func() { _ = db.Close() })
	store, err := trustpool.NewStore(db)
	if err != nil {
		t.Fatalf("NewStore: %v", err)
	}
	registry := trustpool.NewRegistry()
	handler := trustpool.NewAdminHandler(trustpool.AdminDeps{
		Store:                            store,
		Registry:                         registry,
		OperatorKey:                      creatorMVPOperatorKey,
		CreatorAdminCredentials:          creatorCredentials("creator-a", "creator-a-cred", creatorMVPCreatorToken),
		CreatorAdminProviderIDs:          map[string][]string{"creator-a": {creatorMVPProviderID}},
		CreatorAdminProviderDelegatedIDs: map[string][]string{"creator-a": {creatorMVPProviderID}},
		CreatorAdminBuyerAccountIDs:      map[string][]string{"creator-a": {creatorMVPBuyerAccount}},
		CreatorProviderAdmitted:          admittedProviderIDs(creatorMVPProviderID),
	})
	root := newRootFixture(t)
	graceEnds := time.Now().UTC().Add(24 * time.Hour)

	approval := validCreatorApproval("creator-a", "approval-v1", "approval-version-1", "candidate", graceEnds, trustpool.CreatorStatusEnabled)
	postAdminCreator(t, handler, creatorMVPOperatorKey, approval, http.StatusAccepted)
	got, ok, err := store.CreatorApproval(context.Background(), "creator-a")
	if err != nil || !ok || got.ApprovalRecordID != "approval-v1" || got.CreatorAgreementID == "" || got.PricingScheduleID == "" || got.EmergencyNotificationEndpoint == "" {
		t.Fatalf("creator approval = %+v ok=%v err=%v", got, ok, err)
	}

	suspended := validCreatorApproval("creator-a", "approval-v1", "approval-version-1", "candidate", graceEnds, trustpool.CreatorStatusSuspended)
	postAdminCreator(t, handler, creatorMVPOperatorKey, suspended, http.StatusAccepted)
	postCreatorRootRegistrationNonce(t, handler, creatorMVPCreatorToken, trustpool.RootRegistrationNonceIssue{
		OperationID:            "op-nonce-suspended",
		ApprovalRecordID:       "approval-v1",
		CurrentApprovalVersion: "approval-version-1",
		LaunchEnvironment:      "candidate",
		ExpiresAtUTC:           testAdminTS(3600),
	}, http.StatusConflict)
	postAdminCreator(t, handler, creatorMVPOperatorKey, approval, http.StatusAccepted)

	create := creatorPoolCreatedEvent(t, root, "approval-v1")
	postCreatorEvent(t, handler, creatorMVPCreatorToken, create, "op-create", http.StatusAccepted)
	postCreatorEvent(t, handler, creatorMVPCreatorToken, create, "op-create", http.StatusAccepted)

	promoteMissing := httptest.NewRequest(http.MethodPost, "/admin/trust-pools/pools/"+root.poolID+"/promote", nil)
	promoteMissing.Header.Set("Authorization", "Bearer "+creatorMVPOperatorKey)
	promoteMissing.Header.Set("Idempotency-Key", "op-promote-early")
	promoteMissingRec := httptest.NewRecorder()
	handler.ServeHTTP(promoteMissingRec, promoteMissing)
	if promoteMissingRec.Code != http.StatusConflict {
		t.Fatalf("early promote status=%d body=%s, want 409", promoteMissingRec.Code, promoteMissingRec.Body.String())
	}
	assertAdminSchemaVersion(t, promoteMissingRec)

	creatorPromote := httptest.NewRequest(http.MethodPost, "/creator/trust-pools/pools/"+root.poolID+"/promote", bytes.NewReader([]byte(`{}`)))
	creatorPromote.Header.Set("Authorization", "Bearer "+creatorMVPCreatorToken)
	creatorPromoteRec := httptest.NewRecorder()
	handler.ServeHTTP(creatorPromoteRec, creatorPromote)
	if creatorPromoteRec.Code != http.StatusNotFound {
		t.Fatalf("creator promote status=%d body=%s, want 404", creatorPromoteRec.Code, creatorPromoteRec.Body.String())
	}
	assertAdminSchemaVersion(t, creatorPromoteRec)

	nonce := postCreatorRootRegistrationNonce(t, handler, creatorMVPCreatorToken, trustpool.RootRegistrationNonceIssue{
		OperationID:            "op-nonce",
		ApprovalRecordID:       "approval-v1",
		CurrentApprovalVersion: "approval-version-1",
		LaunchEnvironment:      "candidate",
		ExpiresAtUTC:           testAdminTS(3600),
	}, http.StatusCreated)
	replayNonce := signedRootRegistrationForIssue(t, "op-root-replay", testAdminTS(1), root.poolID, "creator-a", "approval-v1", nonce, root)
	postCreatorEvent(t, handler, creatorMVPCreatorToken, signedRootRegistrationForIssue(t, "op-root", testAdminTS(1), root.poolID, "creator-a", "approval-v1", nonce, root), "op-root", http.StatusAccepted)
	postCreatorEvent(t, handler, creatorMVPCreatorToken, replayNonce, "op-root-replay", http.StatusBadRequest)

	postAdminEvent(t, handler, creatorMVPOperatorKey, trustpool.DurableEvent{
		EventType:                      trustpool.EventManifestAccepted,
		PoolID:                         root.poolID,
		ManifestVersion:                1,
		ManifestCoreDigest:             hexDigest("digest-unsigned"),
		RootIssuerKeyID:                "root-key-1",
		RootIssuerPublicKeyFingerprint: root.fingerprint,
	}, "op-manifest-unsigned", http.StatusBadRequest)
	overclaim := signedManifestWithPolicyCoreMutation(t, "op-manifest-overclaim", testAdminTS(2), root.poolID, 1, root, isolatedCreatorMVPPolicy)
	overclaim.ManifestSnapshot = base64.StdEncoding.EncodeToString([]byte(`{"buyer_visible_claim":"anonymous routing"}`))
	overclaimBody, err := json.Marshal(overclaim)
	if err != nil {
		t.Fatalf("marshal overclaim: %v", err)
	}
	overclaimReq := httptest.NewRequest(http.MethodPost, "/creator/trust-pools/events", bytes.NewReader(overclaimBody))
	overclaimReq.Header.Set("Authorization", "Bearer "+creatorMVPCreatorToken)
	overclaimReq.Header.Set("Idempotency-Key", "op-manifest-overclaim")
	overclaimRec := httptest.NewRecorder()
	handler.ServeHTTP(overclaimRec, overclaimReq)
	if overclaimRec.Code != http.StatusBadRequest {
		t.Fatalf("overclaim status=%d body=%s, want 400", overclaimRec.Code, overclaimRec.Body.String())
	}
	assertAdminSchemaVersion(t, overclaimRec)

	manifest := signedManifestWithPolicyCoreMutation(t, "op-manifest", testAdminTS(3), root.poolID, 1, root, isolatedCreatorMVPPolicy)
	postCreatorEvent(t, handler, creatorMVPCreatorToken, manifest, "op-manifest", http.StatusAccepted)

	postCreatorEvent(t, handler, creatorMVPCreatorToken, trustpool.DurableEvent{
		EventType:  trustpool.EventMemberAdmitted,
		PoolID:     root.poolID,
		ProviderID: "provider-undelegated",
	}, "op-member-undelegated", http.StatusForbidden)
	postCreatorEvent(t, handler, creatorMVPCreatorToken, trustpool.DurableEvent{
		EventType:  trustpool.EventMemberAdmitted,
		PoolID:     root.poolID,
		ProviderID: creatorMVPProviderID,
	}, "op-member", http.StatusAccepted)
	postCreatorEvent(t, handler, creatorMVPCreatorToken, trustpool.DurableEvent{
		EventType:      trustpool.EventBuyerAuthorized,
		PoolID:         root.poolID,
		BuyerAccountID: creatorMVPBuyerAccount,
	}, "op-buyer", http.StatusAccepted)

	exports := []string{
		"/creator/trust-pools/pools",
		"/creator/trust-pools/pools/" + root.poolID,
		"/creator/trust-pools/pools/" + root.poolID + "/health",
		"/creator/trust-pools/pools/" + root.poolID + "/distribution",
		"/creator/trust-pools/pools/" + root.poolID + "/audit",
	}
	for _, path := range exports {
		getCreator(t, handler, creatorMVPCreatorToken, path, http.StatusOK)
	}

	postAdminPromote(t, handler, creatorMVPOperatorKey, root.poolID, "op-promote", http.StatusAccepted)
	active := registry.Snapshot(root.poolID)
	if !active.Exists || !active.Routeable || !active.Members[creatorMVPProviderID] {
		t.Fatalf("promoted snapshot = %+v, want routeable member", active)
	}

	reqLog, billingPath := openCreatorMVPRequestLog(t)
	t.Cleanup(func() { _ = reqLog.Close() })
	billingStore, err := billing.NewStore(reqLog.DB())
	if err != nil {
		t.Fatalf("billing.NewStore: %v", err)
	}
	setCreatorMVPSettlementObserve(billingStore)
	rewards := config.Default().Rewards
	snapshotID, err := billingStore.InsertConfigSnapshot(context.Background(), rewards, time.Unix(1716768000, 0).UTC())
	if err != nil {
		t.Fatalf("InsertConfigSnapshot: %v", err)
	}

	var providerCalls atomic.Int64
	provider := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		providerCalls.Add(1)
		w.Header().Set("Content-Type", "application/json")
		_ = json.NewEncoder(w).Encode(map[string]any{
			"id":      "cmpl-test",
			"object":  "chat.completion",
			"choices": []map[string]any{{"message": map[string]any{"role": "assistant", "content": "ok"}}},
			"usage":   map[string]int{"prompt_tokens": 1, "completion_tokens": 1, "total_tokens": 2},
		})
	}))
	defer provider.Close()

	providerRegistry := pool.NewRegistry(nil)
	registerCreatorMVPProvider(providerRegistry, creatorMVPProviderID, "session-member", provider.URL)
	server := buyer.NewServer(
		providerRegistry,
		zerolog.Nop(),
		time.Unix(1716768000, 0).UTC(),
		buyer.WithGatewayServiceToken("gateway-secret"),
		buyer.WithRequireGatewayContext(true),
		buyer.WithRequestLog(reqLog),
		buyer.WithBilling(billingStore, rewards),
		buyer.WithBillingSnapshotID(snapshotID),
		buyer.WithPoolMembership(registry),
		buyer.WithTrustPoolStatusStore(store),
		buyer.WithRoutingConfig(config.RoutingConfig{MaxRetries: 0}),
	)

	chatBody := []byte(`{"model":"model-a","messages":[{"role":"user","content":"hi"}],"temperature":0.000001,"top_p":0.5,"presence_penalty":-0.25,"frequency_penalty":0.125}`)
	unauthorized := postCreatorMVPChat(t, server, chatBody, creatorMVPHeaders("acct-other", root.poolID))
	if unauthorized.Code != http.StatusNotFound && unauthorized.Code != http.StatusServiceUnavailable {
		t.Fatalf("unauthorized pool status=%d body=%s", unauthorized.Code, unauthorized.Body.String())
	}
	if code := creatorMVPErrorCode(t, unauthorized.Body.String()); code != "pool_unavailable" && code != "pool_no_eligible_member" {
		if !strings.Contains(unauthorized.Body.String(), "pool_unavailable") {
			t.Fatalf("unauthorized body=%s, want generic pool denial", unauthorized.Body.String())
		}
	}

	statusReq := httptest.NewRequest(http.MethodGet, "/v1/trust-pools/"+root.poolID+"/pool_status.json", nil)
	statusReq.Header.Set("Authorization", "Bearer gateway-secret")
	statusReq.Header.Set("X-MacProvider-Account", creatorMVPBuyerAccount)
	statusRec := httptest.NewRecorder()
	server.Handler().ServeHTTP(statusRec, statusReq)
	if statusRec.Code != http.StatusOK {
		t.Fatalf("pool status=%d body=%s", statusRec.Code, statusRec.Body.String())
	}
	if got := statusRec.Header().Get("Cache-Control"); got != "no-store" {
		t.Fatalf("status Cache-Control=%q, want no-store", got)
	}
	var statusDoc struct {
		Confidentiality struct {
			Scope string `json:"scope"`
		} `json:"confidentiality"`
		Disclosures []string `json:"disclosures"`
	}
	if err := json.Unmarshal(statusRec.Body.Bytes(), &statusDoc); err != nil {
		t.Fatalf("decode status: %v", err)
	}
	if statusDoc.Confidentiality.Scope != "trusted_pool_not_privacy_pool" {
		t.Fatalf("confidentiality.scope=%q, want trusted_pool_not_privacy_pool", statusDoc.Confidentiality.Scope)
	}
	joined := strings.ToLower(strings.Join(statusDoc.Disclosures, "\n"))
	if !strings.Contains(joined, "not a privacy pool") {
		t.Fatalf("status disclosures missing non-Privacy-Pool disclaimer: %v", statusDoc.Disclosures)
	}
	policyReq := httptest.NewRequest(http.MethodGet, "/v1/trust-pools/"+root.poolID+"/pool_policy.json", nil)
	policyReq.Header.Set("Authorization", "Bearer gateway-secret")
	policyReq.Header.Set("X-MacProvider-Account", creatorMVPBuyerAccount)
	policyRec := httptest.NewRecorder()
	server.Handler().ServeHTTP(policyRec, policyReq)
	if policyRec.Code != http.StatusOK {
		t.Fatalf("pool policy=%d body=%s", policyRec.Code, policyRec.Body.String())
	}
	assertAdminOrDocumentSchema(t, policyRec.Body.Bytes(), "schema_version")

	success := postCreatorMVPChat(t, server, chatBody, creatorMVPHeaders(creatorMVPBuyerAccount, root.poolID))
	if success.Code != http.StatusOK {
		t.Fatalf("pooled request status=%d body=%s", success.Code, success.Body.String())
	}
	if providerCalls.Load() != 1 {
		t.Fatalf("provider calls=%d, want 1", providerCalls.Load())
	}
	routeSnapshots := queryCreatorMVPRouteSnapshots(t, billingPath)
	if len(routeSnapshots) != 1 || routeSnapshots[0].PoolID != root.poolID || routeSnapshots[0].Mode != billing.RouteSnapshotModeObserve {
		t.Fatalf("route snapshots=%#v", routeSnapshots)
	}
	if got := payoutReadyCountAt(t, billingPath); got != 0 {
		t.Fatalf("payout-ready rows=%d, want 0", got)
	}

	postCreatorEvent(t, handler, creatorMVPCreatorToken, trustpool.DurableEvent{
		EventType:  trustpool.EventMemberRevoked,
		PoolID:     root.poolID,
		ProviderID: creatorMVPProviderID,
	}, "op-member-revoke", http.StatusAccepted)
	failClosed := postCreatorMVPChat(t, server, chatBody, creatorMVPHeaders(creatorMVPBuyerAccount, root.poolID))
	if failClosed.Code == http.StatusOK {
		t.Fatalf("revoked-member request succeeded: %s", failClosed.Body.String())
	}
	if providerCalls.Load() != 1 {
		t.Fatalf("provider calls after revoke=%d, want 1", providerCalls.Load())
	}
	postCreatorEvent(t, handler, creatorMVPCreatorToken, trustpool.DurableEvent{
		EventType:  trustpool.EventMemberAdmitted,
		PoolID:     root.poolID,
		ProviderID: creatorMVPProviderID,
	}, "op-member-readmit", http.StatusAccepted)

	emptyRegistry := trustpool.NewRegistry()
	preRebuild := buyer.NewServer(
		providerRegistry,
		zerolog.Nop(),
		time.Unix(1716768000, 0).UTC(),
		buyer.WithGatewayServiceToken("gateway-secret"),
		buyer.WithRequireGatewayContext(true),
		buyer.WithPoolMembership(emptyRegistry),
		buyer.WithRoutingConfig(config.RoutingConfig{MaxRetries: 0}),
	)
	beforeRebuild := postCreatorMVPChat(t, preRebuild, chatBody, creatorMVPHeaders(creatorMVPBuyerAccount, root.poolID))
	if beforeRebuild.Code == http.StatusOK {
		t.Fatalf("request before reconstruction succeeded: %s", beforeRebuild.Body.String())
	}

	state, err := store.Reconstruct(context.Background())
	if err != nil {
		t.Fatalf("Reconstruct: %v", err)
	}
	rebuilt, err := state.BuildRegistry()
	if err != nil {
		t.Fatalf("BuildRegistry: %v", err)
	}
	rebuiltSnap := rebuilt.Snapshot(root.poolID)
	if !rebuiltSnap.Exists || rebuiltSnap.PoolID != root.poolID {
		t.Fatalf("reconstructed snapshot = %+v", rebuiltSnap)
	}

	postAdminLifecycle(t, handler, creatorMVPOperatorKey, root.poolID, "op-pause", trustpool.LifecyclePaused, "maintenance", http.StatusAccepted)
	paused := registry.Snapshot(root.poolID)
	if paused.Routeable || len(paused.Members) != 0 {
		t.Fatalf("paused snapshot = %+v, want fail-closed members", paused)
	}

	suspended = validCreatorApproval("creator-a", "approval-v1", "approval-version-1", "candidate", graceEnds, trustpool.CreatorStatusSuspended)
	postAdminCreator(t, handler, creatorMVPOperatorKey, suspended, http.StatusAccepted)
	postCreatorRootCompromise(t, handler, creatorMVPCreatorToken, root.poolID, root.fingerprint, "op-freeze", http.StatusAccepted)
	staleFreeze, err := json.Marshal(map[string]any{
		"operation_id":                       "op-freeze-backdated",
		"pool_id":                            root.poolID,
		"root_issuer_public_key_fingerprint": root.fingerprint,
		"timestamp_utc":                      "2020-01-01T00:00:00Z",
	})
	if err != nil {
		t.Fatalf("marshal backdated freeze: %v", err)
	}
	staleReq := httptest.NewRequest(http.MethodPost, "/creator/trust-pools/emergency/root-compromise", bytes.NewReader(staleFreeze))
	staleReq.Header.Set("Authorization", "Bearer "+creatorMVPCreatorToken)
	staleReq.Header.Set("Idempotency-Key", "op-freeze-backdated")
	staleRec := httptest.NewRecorder()
	handler.ServeHTTP(staleRec, staleReq)
	if staleRec.Code != http.StatusBadRequest {
		t.Fatalf("backdated freeze status=%d body=%s, want 400", staleRec.Code, staleRec.Body.String())
	}
	postCreatorEvent(t, handler, creatorMVPCreatorToken, trustpool.DurableEvent{
		EventType:                      trustpool.EventRootCompromiseFrozen,
		PoolID:                         root.poolID,
		RootIssuerPublicKeyFingerprint: root.fingerprint,
		Reason:                         trustpool.RootCompromiseFreezeReason,
		TimestampUTC:                   time.Date(2020, 1, 1, 0, 0, 0, 0, time.UTC),
	}, "op-freeze-generic", http.StatusBadRequest)
	postAdminEvent(t, handler, creatorMVPOperatorKey, trustpool.DurableEvent{
		EventType:                      trustpool.EventRootCompromiseFrozen,
		PoolID:                         root.poolID,
		RootIssuerPublicKeyFingerprint: root.fingerprint,
		Reason:                         trustpool.RootCompromiseFreezeReason,
		TimestampUTC:                   time.Date(2020, 1, 1, 0, 0, 0, 0, time.UTC),
	}, "op-freeze-admin-generic", http.StatusBadRequest)
	postCreatorRootRegistrationNonce(t, handler, creatorMVPCreatorToken, trustpool.RootRegistrationNonceIssue{
		OperationID:            "op-nonce-frozen",
		ApprovalRecordID:       "approval-v1",
		CurrentApprovalVersion: "approval-version-1",
		LaunchEnvironment:      "candidate",
		ExpiresAtUTC:           testAdminTS(3600),
	}, http.StatusConflict)
	postAdminCreator(t, handler, creatorMVPOperatorKey, approval, http.StatusAccepted)
	descendant := signedManifestWithPolicyCoreMutation(t, "op-descendant-manifest", testAdminTS(9), root.poolID, 2, root, isolatedCreatorMVPPolicy)
	descendant.RootIssuerKeyID = root.authorityRoot.KeyID
	postCreatorEvent(t, handler, creatorMVPCreatorToken, descendant, "op-descendant-manifest", http.StatusConflict)

	evidence := creatorMVPEvidence(t, creatorMVPEvidenceInput{
		PoolID:                      root.poolID,
		ManifestVersion:             strconv.FormatUint(manifest.ManifestVersion, 10),
		PoolGeneration:              rebuiltSnap.Generation,
		ManifestCoreDigest:          manifest.ManifestCoreDigest,
		RouteSnapshotDigest:         routeSnapshots[0].Digest,
		RootIssuerFingerprint:       root.fingerprint,
		ReviewedDistributionDigest:  sha256Hex("reviewed-distribution-unbound"),
		ApprovalRecordID:            "approval-v1",
		ApprovalRecordVersion:       "approval-version-1",
		CreatorAgreementID:          approval.CreatorAgreementID,
		CreatorAgreementVersion:     approval.CreatorAgreementVersion,
		CreatorAgreementExpiresAt:   approval.CreatorAgreementExpiresAtUTC.UTC().Format("2006-01-02T15:04:05Z"),
		CreatorAgreementGraceEndsAt: approval.CreatorAgreementGraceEndsAtUTC.UTC().Format("2006-01-02T15:04:05Z"),
		PricingScheduleID:           approval.PricingScheduleID,
		PricingScheduleVersion:      approval.PricingScheduleVersion,
		LifecycleState:              trustpool.LifecyclePaused,
		GateCheckID:                 "candidate-promote:op-promote",
		CoordinatorBuildID:          "coordinator-isolated-candidate",
		GatewayBuildID:              "gateway-isolated-candidate",
		ProviderBuildID:             "provider-isolated-candidate",
		EnvironmentID:               "candidate-trusted-pool-creator-mvp",
		BuyerAccountID:              creatorMVPBuyerAccount,
		ProviderID:                  creatorMVPProviderID,
		CreatorAccountID:            "creator-a",
		OperationIDs:                "op-create,op-root,op-manifest,op-member,op-buyer,op-promote,op-pause,op-freeze",
	})
	assertCreatorMVPEvidenceRedacted(t, evidence, chatBody, creatorMVPOperatorKey, creatorMVPCreatorToken, creatorMVPBuyerAccount, creatorMVPProviderID, provider.URL)
	writeCreatorMVPEvidenceIfRequested(t, evidence)
}

func isolatedCreatorMVPPolicy(core *poolmanifest.PolicyCore) {
	core.MinBinaryVersion = "1.8.0"
	core.MinAttestationTier = "self_signed"
	core.RequireEncryptedLeg = false
	core.SettlementMode = billing.RouteSnapshotModeObserve
}

type creatorMVPEvidenceInput struct {
	PoolID                      string
	ManifestVersion             string
	PoolGeneration              uint64
	ManifestCoreDigest          string
	RouteSnapshotDigest         string
	RootIssuerFingerprint       string
	ReviewedDistributionDigest  string
	ApprovalRecordID            string
	ApprovalRecordVersion       string
	CreatorAgreementID          string
	CreatorAgreementVersion     string
	CreatorAgreementExpiresAt   string
	CreatorAgreementGraceEndsAt string
	PricingScheduleID           string
	PricingScheduleVersion      string
	LifecycleState              string
	GateCheckID                 string
	CoordinatorBuildID          string
	GatewayBuildID              string
	ProviderBuildID             string
	EnvironmentID               string
	BuyerAccountID              string
	ProviderID                  string
	CreatorAccountID            string
	OperationIDs                string
}

func creatorMVPEvidence(t *testing.T, in creatorMVPEvidenceInput) map[string]any {
	t.Helper()
	now := time.Now().UTC().Truncate(time.Second)
	commit := creatorMVPGitOutput(t, "rev-parse", "HEAD")
	artifactSet := sha256Hex("artifact-set:" + in.PoolID + ":" + in.ManifestCoreDigest + ":" + in.RouteSnapshotDigest)
	return map[string]any{
		"schema_version":  creatorMVPEvidenceSchema,
		"journey_id":      creatorMVPJourneyID,
		"run_id":          "trusted-pool-creator-mvp-" + now.Format("20060102T150405Z"),
		"captured_at":     now.Format("2006-01-02T15:04:05Z"),
		"expires_at":      now.UTC().Format("2006-01-02"),
		"requirement_ids": []string{"SPEC-043-R001", "SPEC-043-R002", "SPEC-043-R003", "SPEC-043-R004", "SPEC-043-R005", "SPEC-043-R006", "SPEC-043-R007", "SPEC-043-R008", "SPEC-043-R009", "SPEC-043-R010", "SPEC-043-R011", "SPEC-043-R012"},
		"repository": map[string]any{
			"name":   "Augustas11/macprovider",
			"commit": commit,
		},
		"operator": map[string]any{
			"role":                 "acceptance-operator",
			"identity_fingerprint": sha256Hex("trusted-pool-creator-mvp-acceptance-operator"),
		},
		"environment": map[string]any{
			"class":            creatorMVPEnvironmentClass,
			"hardware_profile": "local-redacted",
			"candidate":        "commit:" + commit,
		},
		"harness": map[string]any{
			"id":                       "phase4-coordinator/internal/trustpool:TestJourneyTrustedPoolCreatorMVPCandidate",
			"execution_mode":           creatorMVPEnvironmentClass,
			"isolated_sqlite":          true,
			"real_admin_handler":       true,
			"real_buyer_server":        true,
			"gateway_context_required": true,
			"production_side_effects":  false,
			"evidence_scope":           "isolated candidate create-to-route-to-settle-to-pause proof only; production timing-floor, live creator launch, and production-release key registration remain outside this harness",
		},
		"candidate_identity": map[string]any{
			"approval_record_id":                    in.ApprovalRecordID,
			"approval_record_version":               in.ApprovalRecordVersion,
			"artifact_set_sha256":                   artifactSet,
			"buyer_credential_fingerprint":          sha256Hex(in.BuyerAccountID),
			"clock_skew_allowance_seconds":          60,
			"coordinator_build_id":                  in.CoordinatorBuildID,
			"coordinator_config_sha256":             sha256Hex("coordinator-isolated:" + in.PoolID),
			"creator_account_fingerprint":           sha256Hex(in.CreatorAccountID),
			"creator_agreement_id":                  in.CreatorAgreementID,
			"creator_agreement_expires_at":          in.CreatorAgreementExpiresAt,
			"creator_agreement_grace_ends_at":       in.CreatorAgreementGraceEndsAt,
			"creator_agreement_version":             in.CreatorAgreementVersion,
			"effective_config_digest":               sha256Hex("effective-config:" + in.PoolID),
			"environment_id":                        in.EnvironmentID,
			"feature_flag_digest":                   sha256Hex("feature-flags:trusted-pools-candidate"),
			"gate_check_id":                         in.GateCheckID,
			"gateway_build_id":                      in.GatewayBuildID,
			"gateway_config_sha256":                 sha256Hex("gateway-context-required:" + in.PoolID),
			"governance_file_digest":                sha256Hex("governance:SPEC-043"),
			"lifecycle_state":                       in.LifecycleState,
			"manifest_core_digest":                  in.ManifestCoreDigest,
			"manifest_version":                      in.ManifestVersion,
			"maximum_ttl_seconds":                   86400,
			"operation_ids_fingerprint":             sha256Hex(in.OperationIDs),
			"pool_generation":                       strconv.FormatUint(in.PoolGeneration, 10),
			"pool_id":                               in.PoolID,
			"pricing_schedule_id":                   in.PricingScheduleID,
			"pricing_schedule_version":              in.PricingScheduleVersion,
			"provider_build_id":                     in.ProviderBuildID,
			"provider_identity_fingerprint":         sha256Hex(in.ProviderID),
			"readiness_observations_fingerprint":    sha256Hex("readiness:" + in.PoolID + ":" + in.LifecycleState),
			"reviewed_distribution_artifact_digest": in.ReviewedDistributionDigest,
			"root_issuer_fingerprint":               in.RootIssuerFingerprint,
			"route_snapshot_digest":                 in.RouteSnapshotDigest,
			"verifier_challenge":                    "isolated-candidate-trusted-pool-creator-mvp",
			"verifier_command":                      "phase4-coordinator/internal/trustpool:TestJourneyTrustedPoolCreatorMVPCandidate",
			"verifier_result":                       "pass",
		},
		"steps": []map[string]any{
			creatorMVPStep("step-01-creator-approval", "Approved creator record bound required Agreement and pricing fields; suspension rejected nonce issuance; re-enable restored the candidate path."),
			creatorMVPStep("step-01b-admin-surface-properties", "Admin and creator responses carried schema_version; identical create operation_id was idempotent; creator credentials could not reach promotion."),
			creatorMVPStep("step-02-root-issuer-registration", "Creator-issued nonce plus proof-of-possession root registration accepted; nonce replay failed closed."),
			creatorMVPStep("step-03-manifest-create-accepted", "Signed candidate manifest accepted after pool create; pool stayed non-routeable until promotion."),
			creatorMVPStep("step-04-negative-manifest-cases", "Unsigned manifest and prohibited routing-claim snapshot were rejected before durable append."),
			creatorMVPStep("step-05-provider-membership", "Undelegated provider admission failed; creator-owned admitted member succeeded; later revoke excluded the member from the next routeable snapshot."),
			creatorMVPStep("step-06-buyer-authorization", "Dedicated buyer grant succeeded; unauthorized account selection failed closed with a generic pool denial before provider dispatch."),
			creatorMVPStep("step-07-promise-surfaces", "Authorized policy and status documents used no-store cache control and kept the Trusted Pool confidentiality scope."),
			creatorMVPStep("step-08-activation-gate", "Promotion before root/manifest/membership failed closed; candidate promotion after preflight published a routeable snapshot."),
			creatorMVPStep("step-09-successful-pooled-request", "Authorized pooled chat returned 200 through the admitted member only."),
			creatorMVPStep("step-10-settlement-and-logs", "Route snapshot stored pool_id and digest in observe mode; payout-ready rows stayed zero."),
			creatorMVPStep("step-11-fail-closed-routing", "Unauthorized and post-revoke pool requests failed closed before a second provider dispatch."),
			creatorMVPStep("step-12-restart-reconstruction", "Empty-registry request failed closed; durable reconstruct rebuilt pool identity."),
			creatorMVPStep("step-13-emergency-pause-and-rollback", "Operator pause moved the pool to non-routeable members; creator freeze while suspended rejected later nonce and descendant-signer mutations."),
			creatorMVPStep("step-14-redaction-and-artifacts", "Retained evidence uses fingerprints only; request body, bearer material, and local identities are absent."),
		},
		"redaction": map[string]any{
			"artifact_id":                  creatorMVPArtifactID,
			"secrets_redacted":             true,
			"operator_identity_redacted":   true,
			"local_account_names_redacted": true,
			"raw_prompt_output_redacted":   true,
			"bearer_tokens_redacted":       true,
			"provider_identity_redacted":   true,
			"buyer_credential_redacted":    true,
			"local_endpoint_redacted":      true,
			"private_keys_redacted":        true,
			"redaction_reviewed_by_human":  false,
		},
		"observations": map[string]any{
			"approved_creator_record_bound":                          true,
			"buyer_authorization_enforced":                           true,
			"candidate_manifest_accepted":                            true,
			"creator_admin_authorized_only":                          true,
			"creator_suspension_root_compromise_freeze_verified":     true,
			"delegation_revocation_verified":                         false,
			"descendant_signer_rejection_verified":                   true,
			"emergency_pause_exercised":                              true,
			"fail_closed_no_global_fallback":                         true,
			"isolated_environment":                                   true,
			"no_duplicate_settlement":                                true,
			"no_private_key_upload":                                  true,
			"no_raw_prompt_output_artifact":                          true,
			"pool_existence_oracle_within_threshold":                 false,
			"raw_prompt_output_redacted":                             true,
			"restart_reconstruction_verified":                        true,
			"root_registration_replay_checked":                       true,
			"settlement_labels_bound":                                true,
			"successful_pooled_request":                              true,
			"coordinator_blind_claimed":                              false,
			"global_fallback_observed":                               false,
			"payout_ready_mutated":                                   false,
			"privacy_pool_claimed":                                   false,
			"production_side_effects":                                false,
			"public_announcement_without_reviewed_artifact_observed": false,
			"unrestricted_creator_admin_observed":                    false,
		},
		"result": map[string]any{
			"status":  "pass",
			"summary": "Trusted Pool creator MVP isolated candidate create-to-route-to-settle-to-pause evidence passed without production side effects.",
		},
	}
}

func creatorMVPStep(id, assertion string) map[string]any {
	return map[string]any{
		"id":        id,
		"status":    "pass",
		"artifacts": []string{creatorMVPArtifactID},
		"assertion": assertion,
	}
}

func assertCreatorMVPEvidenceRedacted(t *testing.T, evidence map[string]any, rawBody []byte, forbidden ...string) {
	t.Helper()
	encoded, err := json.Marshal(evidence)
	if err != nil {
		t.Fatalf("marshal evidence: %v", err)
	}
	for _, value := range append(forbidden, string(rawBody)) {
		if value != "" && strings.Contains(string(encoded), value) {
			t.Fatalf("redacted evidence contains forbidden value %q", value)
		}
	}
}

func writeCreatorMVPEvidenceIfRequested(t *testing.T, evidence map[string]any) {
	t.Helper()
	if os.Getenv("MACPROVIDER_CAPTURE_TRUSTED_POOL_CREATOR_MVP") != "1" {
		return
	}
	root := creatorMVPGitOutput(t, "rev-parse", "--show-toplevel")
	if status := creatorMVPGitOutput(t, "status", "--porcelain"); status != "" {
		t.Fatalf("refusing to capture trusted-pool creator MVP evidence from dirty worktree:\n%s", status)
	}
	encoded, err := json.MarshalIndent(evidence, "", "  ")
	if err != nil {
		t.Fatalf("marshal evidence: %v", err)
	}
	encoded = append(encoded, '\n')
	path := filepath.Join(root, "journeys", "evidence", "trusted-pool-creator-mvp-"+time.Now().UTC().Format("20060102T150405Z")+".redacted.json")
	if err := os.WriteFile(path, encoded, 0o600); err != nil {
		t.Fatalf("write creator MVP evidence: %v", err)
	}
	t.Logf("wrote redacted trusted-pool creator MVP evidence to %s", path)
}

func configureCreatorMVPCatalog(t *testing.T) {
	t.Helper()
	seed := bytes.Repeat([]byte{7}, ed25519.SeedSize)
	privateKey := ed25519.NewKeyFromSeed(seed)
	publicKey := privateKey.Public().(ed25519.PublicKey)
	issuedAt := time.Now().UTC().Add(-time.Hour)
	expiresAt := time.Now().UTC().Add(time.Hour)
	type catalogModel struct {
		ArtifactKind string `json:"artifact_kind"`
		HashScope    string `json:"hash_scope"`
		ModelID      string `json:"model_id"`
		SHA256       string `json:"sha256"`
		Source       string `json:"source"`
	}
	type canonicalBody struct {
		CatalogID string         `json:"catalog_id"`
		ExpiresAt string         `json:"expires_at"`
		IssuedAt  string         `json:"issued_at"`
		Models    []catalogModel `json:"models"`
		Version   int            `json:"version"`
	}
	body := canonicalBody{
		CatalogID: "trusted-pool-creator-mvp-catalog",
		ExpiresAt: expiresAt.Format(time.RFC3339),
		IssuedAt:  issuedAt.Format(time.RFC3339),
		Models: []catalogModel{{
			ArtifactKind: "mlx_weight_file",
			HashScope:    "primary_weight_file",
			ModelID:      "model-a",
			SHA256:       creatorMVPModelHash,
			Source:       "operator-curated",
		}},
		Version: 1,
	}
	canonical, err := json.Marshal(body)
	if err != nil {
		t.Fatalf("catalog canonical marshal: %v", err)
	}
	sig := ed25519.Sign(privateKey, canonical)
	file := map[string]any{
		"catalog_id": body.CatalogID,
		"expires_at": body.ExpiresAt,
		"issued_at":  body.IssuedAt,
		"models":     body.Models,
		"signature": map[string]string{
			"alg":    "Ed25519",
			"key_id": "buyer-test-key",
			"sig":    base64.RawURLEncoding.EncodeToString(sig),
		},
		"version": body.Version,
	}
	raw, err := json.Marshal(file)
	if err != nil {
		t.Fatalf("catalog marshal: %v", err)
	}
	path := filepath.Join(t.TempDir(), "catalog.json")
	if err := os.WriteFile(path, raw, 0o600); err != nil {
		t.Fatalf("write catalog: %v", err)
	}
	t.Cleanup(tier2.ResetForTest)
	if err := tier2.Configure(config.Tier2Config{
		ObserveEnabled:      true,
		CatalogPath:         path,
		CatalogPublicKey:    base64.RawURLEncoding.EncodeToString(publicKey),
		RequireHashVerified: true,
	}, zerolog.Nop()); err != nil {
		t.Fatalf("tier2.Configure: %v", err)
	}
}

func registerCreatorMVPProvider(registry *pool.Registry, providerID, assignedID, endpointURL string) {
	now := time.Now().UTC()
	registry.Register(&pool.Provider{
		ProviderID:            providerID,
		AssignedID:            assignedID,
		Hostname:              providerID + ".local",
		ModelID:               "model-a",
		ModelParamsB:          7,
		RAMGB:                 16,
		MaxContextTokens:      20000,
		MaxConcurrency:        1,
		SlotsFree:             1,
		SlotsTotal:            1,
		ThroughputTPSEstimate: 25,
		EndpointURL:           endpointURL,
		Tier:                  pool.TierPinned,
		InferencePath:         pool.InferencePathHTTPForwarding,
		State:                 pool.StateReady,
		LastHeartbeatAt:       now,
		ConnectedAt:           now,
		BinaryVersion:         "1.8.0",
		ModelHash:             creatorMVPModelHash,
		ModelHashAlgorithm:    modelidentity.SnapshotManifestV1,
		ExpectedModelHash:     creatorMVPModelHash,
		HashStatus:            pool.HashStatusVerified,
		ReceiptPubkey:         bytes.Repeat([]byte("r"), 32),
		TrustedPoolV1:         true,
	}, nil)
	slotsFree := 1
	registry.ApplyStateUpdate(providerID, assignedID, pool.StateUpdate{State: pool.StateReady, SlotsFree: &slotsFree, At: now})
}

func openCreatorMVPRequestLog(t *testing.T) (*requestlog.Store, string) {
	t.Helper()
	dbPath := filepath.Join(t.TempDir(), "coordinator.db")
	store, err := requestlog.OpenStore(dbPath)
	if err != nil {
		t.Fatalf("open request log: %v", err)
	}
	if _, err := store.DB().Exec(`
CREATE TABLE IF NOT EXISTS audit_log (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    ts_utc TEXT NOT NULL,
    event_type TEXT NOT NULL,
    provider_id TEXT,
    payload_json TEXT NOT NULL
);`); err != nil {
		t.Fatalf("create audit_log: %v", err)
	}
	return store, dbPath
}

func setCreatorMVPSettlementObserve(store *billing.Store) {
	cfg := config.Default().Settlement
	cfg.VerifiedModelSettlementMode = billing.RouteSnapshotModeObserve
	store.SetSettlementConfig(cfg)
}

func postCreatorMVPChat(t *testing.T, server *buyer.Server, body []byte, headers http.Header) *httptest.ResponseRecorder {
	t.Helper()
	req := httptest.NewRequest(http.MethodPost, "/v1/chat/completions", bytes.NewReader(body))
	for key, values := range headers {
		for _, value := range values {
			req.Header.Add(key, value)
		}
	}
	rec := httptest.NewRecorder()
	server.Handler().ServeHTTP(rec, req)
	return rec
}

func creatorMVPHeaders(accountID, poolID string) http.Header {
	return http.Header{
		"Authorization":         {"Bearer gateway-secret"},
		"X-MacProvider-Account": {accountID},
		"X-MacProvider-Pool":    {poolID},
	}
}

func creatorMVPErrorCode(t *testing.T, body string) string {
	t.Helper()
	var decoded struct {
		Error struct {
			Code string `json:"code"`
		} `json:"error"`
	}
	if err := json.Unmarshal([]byte(body), &decoded); err != nil {
		return ""
	}
	return decoded.Error.Code
}

type creatorMVPRouteSnapshotRow struct {
	ProviderID string
	PoolID     string
	Mode       string
	Digest     string
}

func queryCreatorMVPRouteSnapshots(t *testing.T, dbPath string) []creatorMVPRouteSnapshotRow {
	t.Helper()
	db, err := sql.Open("sqlite", dbPath)
	if err != nil {
		t.Fatalf("open db: %v", err)
	}
	defer db.Close()
	rows, err := db.Query(`
SELECT provider_id, COALESCE(pool_id, ''), route_snapshot_mode, route_snapshot_digest
FROM settlement_route_snapshots
ORDER BY attempt_n ASC`)
	if err != nil {
		t.Fatalf("query route snapshots: %v", err)
	}
	defer rows.Close()
	var got []creatorMVPRouteSnapshotRow
	for rows.Next() {
		var row creatorMVPRouteSnapshotRow
		if err := rows.Scan(&row.ProviderID, &row.PoolID, &row.Mode, &row.Digest); err != nil {
			t.Fatalf("scan route snapshots: %v", err)
		}
		got = append(got, row)
	}
	if err := rows.Err(); err != nil {
		t.Fatalf("route snapshots: %v", err)
	}
	return got
}

func payoutReadyCountAt(t *testing.T, dbPath string) int {
	t.Helper()
	db, err := sql.Open("sqlite", dbPath)
	if err != nil {
		t.Fatalf("open db: %v", err)
	}
	defer db.Close()
	var count int
	if err := db.QueryRow(`SELECT COUNT(*) FROM ledger_payout_ready`).Scan(&count); err != nil {
		t.Fatalf("count payout-ready: %v", err)
	}
	return count
}

func assertAdminOrDocumentSchema(t *testing.T, raw []byte, field string) {
	t.Helper()
	var body map[string]any
	if err := json.Unmarshal(raw, &body); err != nil {
		t.Fatalf("document is not JSON: %v", err)
	}
	if _, ok := body[field]; !ok {
		t.Fatalf("document missing %s: %s", field, string(raw))
	}
}

func creatorMVPGitOutput(t *testing.T, args ...string) string {
	t.Helper()
	cmd := exec.Command("git", args...)
	out, err := cmd.Output()
	if err != nil {
		t.Fatalf("git %s: %v", strings.Join(args, " "), err)
	}
	return strings.TrimSpace(string(out))
}

func sha256Hex(value string) string {
	sum := sha256.Sum256([]byte(value))
	return hex.EncodeToString(sum[:])
}
