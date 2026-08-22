package trustpool_test

import (
	"bytes"
	"encoding/base64"
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"
	"time"

	"github.com/augstar/macprovider-coordinator/internal/poolmanifest"
	"github.com/augstar/macprovider-coordinator/internal/trustpool"
)

func TestAdminHandler_AppendsCandidateEventsAndRejectsActivation(t *testing.T) {
	t.Parallel()
	store, err := trustpool.NewStore(openTrustPoolDB(t))
	if err != nil {
		t.Fatalf("NewStore: %v", err)
	}
	registry := trustpool.NewRegistry()
	handler := trustpool.NewAdminHandler(trustpool.AdminDeps{
		Store:       store,
		Registry:    registry,
		OperatorKey: "operator-secret",
	})
	root := newRootFixture(t)
	approveCreator(t, store, "creator-a", "approval-v1", "approval-version-1", "candidate", time.Now().Add(24*time.Hour), trustpool.CreatorStatusEnabled)

	postAdminEvent(t, handler, "operator-secret", trustpool.DurableEvent{
		EventType:        trustpool.EventPoolCreated,
		PoolID:           root.poolID,
		CreatorAccountID: "creator-a",
		ApprovalRecordID: "approval-v1",
	}, "op-create", http.StatusAccepted)
	postAdminEvent(t, handler, "operator-secret", signedRootRegistrationForIssue(t, "op-root", testAdminTS(1), root.poolID, "creator-a", "approval-v1", issueRootNonce(t, store, "creator-a", "approval-v1", testAdminTS(3600)), root), "op-root", http.StatusAccepted)
	postAdminEvent(t, handler, "operator-secret", signedManifest(t, "op-manifest", testAdminTS(2), root.poolID, 1, root), "op-manifest", http.StatusAccepted)
	postAdminEvent(t, handler, "operator-secret", trustpool.DurableEvent{
		EventType:  trustpool.EventMemberAdmitted,
		PoolID:     root.poolID,
		ProviderID: "provider-a",
	}, "op-member", http.StatusAccepted)
	postAdminEvent(t, handler, "operator-secret", trustpool.DurableEvent{
		EventType:      trustpool.EventBuyerAuthorized,
		PoolID:         root.poolID,
		BuyerAccountID: "acct-allowed",
	}, "op-buyer", http.StatusAccepted)
	postAdminEvent(t, handler, "operator-secret", trustpool.DurableEvent{
		EventType: trustpool.EventLifecycleChanged,
		PoolID:    root.poolID,
		Lifecycle: trustpool.LifecycleActive,
	}, "op-active", http.StatusConflict)

	snap := registry.Snapshot(root.poolID)
	if !snap.Exists || snap.Routeable || snap.Generation != 6 {
		t.Fatalf("registry snapshot = %+v, want non-routeable candidate pool generation 6", snap)
	}
	if len(snap.Members) != 0 {
		t.Fatalf("candidate pool exposed routeable members: %v", snap.Members)
	}
	if !registry.BuyerAuthorized(root.poolID, "acct-allowed") {
		t.Fatal("acct-allowed should be authorized after admin buyer event")
	}

	postAdminPromote(t, handler, "operator-secret", root.poolID, "op-promote", http.StatusAccepted)
	active := registry.Snapshot(root.poolID)
	if !active.Exists || !active.Routeable || !active.Members["provider-a"] || active.Generation != 7 {
		t.Fatalf("registry snapshot after promotion = %+v, want routeable provider-a generation 7", active)
	}
	postAdminPromote(t, handler, "operator-secret", root.poolID, "op-promote", http.StatusAccepted)
	retry := registry.Snapshot(root.poolID)
	if retry.Generation != active.Generation || !retry.Routeable {
		t.Fatalf("idempotent promotion retry snapshot = %+v, want unchanged routeable generation %d", retry, active.Generation)
	}
	postAdminEvent(t, handler, "operator-secret", trustpool.DurableEvent{
		EventType: trustpool.EventLifecycleChanged,
		PoolID:    root.poolID,
		Lifecycle: trustpool.LifecycleActive,
	}, "op-active-after-promote", http.StatusConflict)
}

func TestAdminHandler_PromoteRejectsMissingPrecondition(t *testing.T) {
	t.Parallel()
	store, err := trustpool.NewStore(openTrustPoolDB(t))
	if err != nil {
		t.Fatalf("NewStore: %v", err)
	}
	handler := trustpool.NewAdminHandler(trustpool.AdminDeps{
		Store:       store,
		Registry:    trustpool.NewRegistry(),
		OperatorKey: "operator-secret",
	})
	root := newRootFixture(t)
	approveCreator(t, store, "creator-a", "approval-v1", "approval-version-1", "candidate", time.Now().Add(24*time.Hour), trustpool.CreatorStatusEnabled)
	postAdminEvent(t, handler, "operator-secret", trustpool.DurableEvent{
		EventType:        trustpool.EventPoolCreated,
		PoolID:           root.poolID,
		CreatorAccountID: "creator-a",
		ApprovalRecordID: "approval-v1",
	}, "op-create", http.StatusAccepted)

	req := httptest.NewRequest(http.MethodPost, "/admin/trust-pools/pools/"+root.poolID+"/promote", nil)
	req.Header.Set("Authorization", "Bearer operator-secret")
	req.Header.Set("Idempotency-Key", "op-promote")
	rec := httptest.NewRecorder()
	handler.ServeHTTP(rec, req)
	if rec.Code != http.StatusConflict {
		t.Fatalf("promote status=%d body=%s, want 409", rec.Code, rec.Body.String())
	}
	assertAdminSchemaVersion(t, rec)
	var body struct {
		Error struct {
			Code   string `json:"code"`
			Reason string `json:"reason"`
		} `json:"error"`
	}
	if err := json.Unmarshal(rec.Body.Bytes(), &body); err != nil {
		t.Fatalf("decode promotion error: %v", err)
	}
	if body.Error.Code != "promotion_precondition_failed" || body.Error.Reason != "root_issuer_missing" {
		t.Fatalf("promotion error = %+v, want root_issuer_missing precondition", body.Error)
	}
}

func TestAdminHandler_PromoteRetryRefreshesStaleRegistry(t *testing.T) {
	t.Parallel()
	ctx := t.Context()
	store, err := trustpool.NewStore(openTrustPoolDB(t))
	if err != nil {
		t.Fatalf("NewStore: %v", err)
	}
	registry := trustpool.NewRegistry()
	handler := trustpool.NewAdminHandler(trustpool.AdminDeps{
		Store:       store,
		Registry:    registry,
		OperatorKey: "operator-secret",
	})
	root := newRootFixture(t)
	approveCreator(t, store, "creator-a", "approval-v1", "approval-version-1", "candidate", time.Now().Add(24*time.Hour), trustpool.CreatorStatusEnabled)
	postAdminEvent(t, handler, "operator-secret", trustpool.DurableEvent{
		EventType:        trustpool.EventPoolCreated,
		PoolID:           root.poolID,
		CreatorAccountID: "creator-a",
		ApprovalRecordID: "approval-v1",
	}, "op-create", http.StatusAccepted)
	postAdminEvent(t, handler, "operator-secret", signedRootRegistrationForIssue(t, "op-root", testAdminTS(1), root.poolID, "creator-a", "approval-v1", issueRootNonce(t, store, "creator-a", "approval-v1", testAdminTS(3600)), root), "op-root", http.StatusAccepted)
	postAdminEvent(t, handler, "operator-secret", signedManifest(t, "op-manifest", testAdminTS(2), root.poolID, 1, root), "op-manifest", http.StatusAccepted)
	postAdminEvent(t, handler, "operator-secret", trustpool.DurableEvent{
		EventType:  trustpool.EventMemberAdmitted,
		PoolID:     root.poolID,
		ProviderID: "provider-a",
	}, "op-member", http.StatusAccepted)
	postAdminEvent(t, handler, "operator-secret", trustpool.DurableEvent{
		EventType:      trustpool.EventBuyerAuthorized,
		PoolID:         root.poolID,
		BuyerAccountID: "acct-allowed",
	}, "op-buyer", http.StatusAccepted)

	if _, _, _, err := store.PromotePool(ctx, trustpool.DurableEvent{
		OperationID: "op-promote",
		PoolID:      root.poolID,
	}); err != nil {
		t.Fatalf("direct PromotePool: %v", err)
	}
	stale := registry.Snapshot(root.poolID)
	if stale.Routeable {
		t.Fatalf("registry unexpectedly routeable before retry refresh: %+v", stale)
	}
	postAdminPromote(t, handler, "operator-secret", root.poolID, "op-promote", http.StatusAccepted)
	active := registry.Snapshot(root.poolID)
	if !active.Exists || !active.Routeable || !active.Members["provider-a"] {
		t.Fatalf("registry snapshot after idempotent retry = %+v, want routeable provider-a", active)
	}
}

func TestAdminHandler_RejectsUnsignedManifest(t *testing.T) {
	t.Parallel()
	store, err := trustpool.NewStore(openTrustPoolDB(t))
	if err != nil {
		t.Fatalf("NewStore: %v", err)
	}
	handler := trustpool.NewAdminHandler(trustpool.AdminDeps{
		Store:       store,
		Registry:    trustpool.NewRegistry(),
		OperatorKey: "operator-secret",
	})
	root := newRootFixture(t)
	approveCreator(t, store, "creator-a", "approval-v1", "approval-version-1", "candidate", time.Now().Add(24*time.Hour), trustpool.CreatorStatusEnabled)
	postAdminEvent(t, handler, "operator-secret", trustpool.DurableEvent{
		EventType:        trustpool.EventPoolCreated,
		PoolID:           root.poolID,
		CreatorAccountID: "creator-a",
		ApprovalRecordID: "approval-v1",
	}, "op-create", http.StatusAccepted)
	postAdminEvent(t, handler, "operator-secret", signedRootRegistrationForIssue(t, "op-root", testAdminTS(1), root.poolID, "creator-a", "approval-v1", issueRootNonce(t, store, "creator-a", "approval-v1", testAdminTS(3600)), root), "op-root", http.StatusAccepted)
	postAdminEvent(t, handler, "operator-secret", trustpool.DurableEvent{
		EventType:                      trustpool.EventManifestAccepted,
		PoolID:                         root.poolID,
		ManifestVersion:                1,
		ManifestCoreDigest:             hexDigest("digest-a"),
		RootIssuerKeyID:                "root-key-1",
		RootIssuerPublicKeyFingerprint: root.fingerprint,
	}, "op-manifest-unsigned", http.StatusBadRequest)
}

func TestAdminHandler_RejectsManifestPromiseOverclaim(t *testing.T) {
	t.Parallel()
	store, err := trustpool.NewStore(openTrustPoolDB(t))
	if err != nil {
		t.Fatalf("NewStore: %v", err)
	}
	handler := trustpool.NewAdminHandler(trustpool.AdminDeps{
		Store:       store,
		Registry:    trustpool.NewRegistry(),
		OperatorKey: "operator-secret",
	})
	root := newRootFixture(t)
	approveCreator(t, store, "creator-a", "approval-v1", "approval-version-1", "candidate", time.Now().Add(24*time.Hour), trustpool.CreatorStatusEnabled)
	postAdminEvent(t, handler, "operator-secret", trustpool.DurableEvent{
		EventType:        trustpool.EventPoolCreated,
		PoolID:           root.poolID,
		CreatorAccountID: "creator-a",
		ApprovalRecordID: "approval-v1",
	}, "op-create", http.StatusAccepted)
	postAdminEvent(t, handler, "operator-secret", signedRootRegistrationForIssue(t, "op-root", testAdminTS(1), root.poolID, "creator-a", "approval-v1", issueRootNonce(t, store, "creator-a", "approval-v1", testAdminTS(3600)), root), "op-root", http.StatusAccepted)
	manifest := signedManifest(t, "op-manifest-overclaim", testAdminTS(2), root.poolID, 1, root)
	manifest.ManifestSnapshot = base64.StdEncoding.EncodeToString([]byte(`{"buyer_visible_claim":"Privacy Pool with anonymous routing"}`))
	body, err := json.Marshal(manifest)
	if err != nil {
		t.Fatalf("marshal manifest: %v", err)
	}
	req := httptest.NewRequest(http.MethodPost, "/admin/trust-pools/events", bytes.NewReader(body))
	req.Header.Set("Authorization", "Bearer operator-secret")
	req.Header.Set("Idempotency-Key", "op-manifest-overclaim")
	rec := httptest.NewRecorder()
	handler.ServeHTTP(rec, req)
	if rec.Code != http.StatusBadRequest {
		t.Fatalf("POST overclaim status=%d body=%s, want 400", rec.Code, rec.Body.String())
	}
	assertAdminSchemaVersion(t, rec)
	var got struct {
		Error struct {
			Code string `json:"code"`
		} `json:"error"`
	}
	if err := json.Unmarshal(rec.Body.Bytes(), &got); err != nil {
		t.Fatalf("decode overclaim response: %v", err)
	}
	if got.Error.Code != "prohibited_promise_claim" {
		t.Fatalf("error code=%q body=%s, want prohibited_promise_claim", got.Error.Code, rec.Body.String())
	}
}

func TestAdminHandler_CreatorApprovalEndpointRefreshesRegistry(t *testing.T) {
	t.Parallel()
	ctx := t.Context()
	db := openTrustPoolDB(t)
	store, err := trustpool.NewStore(db)
	if err != nil {
		t.Fatalf("NewStore: %v", err)
	}
	registry := trustpool.NewRegistry()
	handler := trustpool.NewAdminHandler(trustpool.AdminDeps{
		Store:       store,
		Registry:    registry,
		OperatorKey: "operator-secret",
	})
	root := newRootFixture(t)
	approval := approveCreator(t, store, "creator-a", "approval-v1", "approval-version-1", "candidate", time.Now().Add(24*time.Hour), trustpool.CreatorStatusEnabled)
	events := []trustpool.DurableEvent{
		{
			EventType:        trustpool.EventPoolCreated,
			PoolID:           root.poolID,
			CreatorAccountID: "creator-a",
			ApprovalRecordID: "approval-v1",
		},
		signedRootRegistrationForIssue(t, "op-root", testAdminTS(1), root.poolID, "creator-a", "approval-v1", issueRootNonce(t, store, "creator-a", "approval-v1", testAdminTS(3600)), root),
		signedManifestWithPolicyCoreMutation(t, "op-manifest", testAdminTS(2), root.poolID, 1, root, func(core *poolmanifest.PolicyCore) {
			core.MinBinaryVersion = "1.8.33"
		}),
		{
			EventType:  trustpool.EventMemberAdmitted,
			PoolID:     root.poolID,
			ProviderID: "provider-a",
		},
		{
			EventType:      trustpool.EventBuyerAuthorized,
			PoolID:         root.poolID,
			BuyerAccountID: "acct-a",
		},
		{
			EventType: trustpool.EventLifecycleChanged,
			PoolID:    root.poolID,
			Lifecycle: trustpool.LifecycleActive,
		},
	}
	for i, e := range events {
		e.OperationID = []string{"op-create", "op-root", "op-manifest", "op-member", "op-buyer", "op-active"}[i]
		e.TimestampUTC = testAdminTS(int64(i))
		if e.EventType == trustpool.EventLifecycleChanged && e.Lifecycle == trustpool.LifecycleActive {
			insertPromotedEvent(t, ctx, db, e)
			continue
		}
		if _, _, _, err := store.AppendValidatedEvent(ctx, e); err != nil {
			t.Fatalf("AppendValidatedEvent(%s): %v", e.OperationID, err)
		}
	}
	state, err := store.Reconstruct(ctx)
	if err != nil {
		t.Fatalf("Reconstruct: %v", err)
	}
	if err := registry.LoadRouteableSnapshotsAtRevision(state.Revision, state.RouteableSnapshots()); err != nil {
		t.Fatalf("initial registry load: %v", err)
	}
	if snap := registry.Snapshot(root.poolID); !snap.Routeable {
		t.Fatalf("initial snapshot = %+v, want routeable", snap)
	}
	approval.Status = trustpool.CreatorStatusSuspended
	approval.SuspensionReason = "agreement_hold"
	postAdminCreator(t, handler, "operator-secret", approval, http.StatusAccepted)
	snap := registry.Snapshot(root.poolID)
	if !snap.Exists || snap.Routeable || len(snap.Members) != 0 {
		t.Fatalf("snapshot after creator suspension = %+v, want present but non-routeable", snap)
	}
	suspendedGeneration := snap.Generation
	postAdminCreator(t, handler, "operator-secret", approval, http.StatusAccepted)
	retrySnap := registry.Snapshot(root.poolID)
	if retrySnap.Generation != suspendedGeneration {
		t.Fatalf("duplicate creator approval generation = %d, want unchanged %d", retrySnap.Generation, suspendedGeneration)
	}
	req := httptest.NewRequest(http.MethodGet, "/admin/trust-pools/creators/creator-a", nil)
	req.Header.Set("Authorization", "Bearer operator-secret")
	rec := httptest.NewRecorder()
	handler.ServeHTTP(rec, req)
	if rec.Code != http.StatusOK {
		t.Fatalf("GET creator status=%d body=%s, want 200", rec.Code, rec.Body.String())
	}
	assertAdminSchemaVersion(t, rec)

	req = httptest.NewRequest(http.MethodGet, "/admin/trust-pools/pools/"+root.poolID, nil)
	req.Header.Set("Authorization", "Bearer operator-secret")
	rec = httptest.NewRecorder()
	handler.ServeHTTP(rec, req)
	if rec.Code != http.StatusOK {
		t.Fatalf("GET pool status=%d body=%s, want 200", rec.Code, rec.Body.String())
	}
	assertAdminSchemaVersion(t, rec)
	var body struct {
		Pool struct {
			CreatorGateReason     string `json:"creator_gate_reason"`
			RouteableGeneration   uint64 `json:"routeable_generation"`
			RouteGateCheckedAtUTC string `json:"route_gate_checked_at_utc"`
			MinBinaryVersion      string `json:"min_binary_version"`
		} `json:"pool"`
	}
	if err := json.Unmarshal(rec.Body.Bytes(), &body); err != nil {
		t.Fatalf("decode GET pool body: %v", err)
	}
	if body.Pool.CreatorGateReason != "creator_suspended" || body.Pool.RouteableGeneration == 0 || body.Pool.RouteGateCheckedAtUTC == "" {
		t.Fatalf("GET pool gate fields = %+v, want suspended gate status", body.Pool)
	}
	if body.Pool.MinBinaryVersion != "1.8.33" {
		t.Fatalf("GET pool min_binary_version = %q, want manifest-only floor", body.Pool.MinBinaryVersion)
	}
}

func TestAdminHandler_PublicAnnouncementApprovalIsDigestBound(t *testing.T) {
	t.Parallel()
	store, err := trustpool.NewStore(openTrustPoolDB(t))
	if err != nil {
		t.Fatalf("NewStore: %v", err)
	}
	handler := trustpool.NewAdminHandler(trustpool.AdminDeps{
		Store:       store,
		Registry:    trustpool.NewRegistry(),
		OperatorKey: "operator-secret",
	})
	root := newRootFixture(t)
	approveCreator(t, store, "creator-a", "approval-v1", "approval-version-1", "public", time.Now().Add(24*time.Hour), trustpool.CreatorStatusEnabled)
	postAdminEvent(t, handler, "operator-secret", trustpool.DurableEvent{
		EventType:        trustpool.EventPoolCreated,
		PoolID:           root.poolID,
		CreatorAccountID: "creator-a",
		ApprovalRecordID: "approval-v1",
	}, "op-create", http.StatusAccepted)
	postAdminEvent(t, handler, "operator-secret", signedRootRegistrationForIssueInEnvironment(t, "op-root", testAdminTS(1), root.poolID, "creator-a", "approval-v1", issueRootNonceInEnvironment(t, store, "creator-a", "approval-v1", "public", testAdminTS(3600)), root, "public"), "op-root", http.StatusAccepted)
	manifest := signedManifest(t, "op-manifest", testAdminTS(2), root.poolID, 1, root)
	postAdminEvent(t, handler, "operator-secret", manifest, "op-manifest", http.StatusAccepted)
	reviewedArtifactDigest := hexDigest("reviewed-artifact-v1")

	postAdminPublicAnnouncement(t, handler, "operator-secret", root.poolID, trustpool.PublicAnnouncementApproval{
		OperationID:                "op-public-mismatch",
		PoolID:                     "different-pool",
		ManifestCoreDigest:         manifest.ManifestCoreDigest,
		ReviewedDistributionDigest: reviewedArtifactDigest,
		ApprovalRecordID:           "public-announcement-v1",
		ApprovedBy:                 "operator-a",
		ApprovedAtUTC:              testAdminTS(3),
	}, http.StatusBadRequest)
	postAdminPublicAnnouncement(t, handler, "operator-secret", root.poolID, trustpool.PublicAnnouncementApproval{
		OperationID:                "op-public-stale",
		ManifestCoreDigest:         hexDigest("stale-manifest"),
		ReviewedDistributionDigest: reviewedArtifactDigest,
		ApprovalRecordID:           "public-announcement-v1",
		ApprovedBy:                 "operator-a",
		ApprovedAtUTC:              testAdminTS(3),
	}, http.StatusConflict)
	postAdminPublicAnnouncement(t, handler, "operator-secret", root.poolID, trustpool.PublicAnnouncementApproval{
		OperationID:                "op-public-before-review",
		ManifestCoreDigest:         manifest.ManifestCoreDigest,
		ReviewedDistributionDigest: reviewedArtifactDigest,
		ApprovalRecordID:           "public-announcement-v1",
		ApprovedBy:                 "operator-a",
		ApprovedAtUTC:              testAdminTS(3),
	}, http.StatusConflict)
	postAdminReviewedDistributionArtifact(t, handler, "operator-secret", root.poolID, trustpool.ReviewedDistributionArtifact{
		OperationID:                "op-reviewed-artifact-v1",
		ManifestCoreDigest:         manifest.ManifestCoreDigest,
		ReviewedDistributionDigest: reviewedArtifactDigest,
		ArtifactURI:                "https://example.test/trusted-pools/" + root.poolID,
		ClaimControlDigest:         hexDigest("claim-control-v1"),
		ReviewedBy:                 "operator-a",
		ReviewedAtUTC:              testAdminTS(3),
	}, http.StatusAccepted)
	postAdminReviewedDistributionArtifact(t, handler, "operator-secret", root.poolID, trustpool.ReviewedDistributionArtifact{
		OperationID:                "op-reviewed-artifact-v1",
		ManifestCoreDigest:         manifest.ManifestCoreDigest,
		ReviewedDistributionDigest: reviewedArtifactDigest,
		ArtifactURI:                "https://example.test/trusted-pools/" + root.poolID,
		ClaimControlDigest:         hexDigest("claim-control-v1"),
		ReviewedBy:                 "operator-a",
		ReviewedAtUTC:              testAdminTS(3),
	}, http.StatusAccepted)
	postAdminReviewedDistributionArtifact(t, handler, "operator-secret", root.poolID, trustpool.ReviewedDistributionArtifact{
		OperationID:                "op-reviewed-artifact-same-content",
		ManifestCoreDigest:         manifest.ManifestCoreDigest,
		ReviewedDistributionDigest: reviewedArtifactDigest,
		ArtifactURI:                "https://example.test/trusted-pools/" + root.poolID,
		ClaimControlDigest:         hexDigest("claim-control-v1"),
		ReviewedBy:                 "operator-a",
		ReviewedAtUTC:              testAdminTS(3),
	}, http.StatusConflict)
	postAdminPublicAnnouncement(t, handler, "operator-secret", root.poolID, trustpool.PublicAnnouncementApproval{
		OperationID:                "op-reviewed-artifact-v1",
		ManifestCoreDigest:         manifest.ManifestCoreDigest,
		ReviewedDistributionDigest: reviewedArtifactDigest,
		ApprovalRecordID:           "public-announcement-v1",
		ApprovedBy:                 "operator-a",
		ApprovedAtUTC:              testAdminTS(4),
	}, http.StatusConflict)
	postAdminPromote(t, handler, "operator-secret", root.poolID, "op-reviewed-artifact-v1", http.StatusConflict)
	rec := postAdminPublicAnnouncement(t, handler, "operator-secret", root.poolID, trustpool.PublicAnnouncementApproval{
		OperationID:                "op-public-v1",
		ManifestCoreDigest:         manifest.ManifestCoreDigest,
		ReviewedDistributionDigest: reviewedArtifactDigest,
		ApprovalRecordID:           "public-announcement-v1",
		ApprovedBy:                 "operator-a",
		ApprovedAtUTC:              testAdminTS(4),
	}, http.StatusAccepted)
	var body struct {
		PublicAnnouncement trustpool.PublicAnnouncementApproval `json:"public_announcement"`
	}
	if err := json.Unmarshal(rec.Body.Bytes(), &body); err != nil {
		t.Fatalf("decode public announcement response: %v", err)
	}
	if body.PublicAnnouncement.OperationID != "op-public-v1" ||
		body.PublicAnnouncement.PoolID != root.poolID ||
		body.PublicAnnouncement.ManifestCoreDigest != manifest.ManifestCoreDigest ||
		body.PublicAnnouncement.ReviewedDistributionDigest != reviewedArtifactDigest ||
		body.PublicAnnouncement.PublicAnnouncementRevision != 1 {
		t.Fatalf("public announcement response=%+v", body.PublicAnnouncement)
	}
	retry := postAdminPublicAnnouncement(t, handler, "operator-secret", root.poolID, trustpool.PublicAnnouncementApproval{
		OperationID:                "op-public-v1",
		ManifestCoreDigest:         manifest.ManifestCoreDigest,
		ReviewedDistributionDigest: reviewedArtifactDigest,
		ApprovalRecordID:           "public-announcement-v1",
		ApprovedBy:                 "operator-a",
		ApprovedAtUTC:              testAdminTS(4),
	}, http.StatusAccepted)
	var retryBody struct {
		PublicAnnouncement trustpool.PublicAnnouncementApproval `json:"public_announcement"`
	}
	if err := json.Unmarshal(retry.Body.Bytes(), &retryBody); err != nil {
		t.Fatalf("decode public announcement retry response: %v", err)
	}
	if retryBody.PublicAnnouncement.PublicAnnouncementRevision != 1 {
		t.Fatalf("public announcement retry revision=%d, want 1", retryBody.PublicAnnouncement.PublicAnnouncementRevision)
	}
	postAdminPublicAnnouncement(t, handler, "operator-secret", root.poolID, trustpool.PublicAnnouncementApproval{
		OperationID:                "op-public-v1",
		ManifestCoreDigest:         manifest.ManifestCoreDigest,
		ReviewedDistributionDigest: hexDigest("different-reviewed-artifact"),
		ApprovalRecordID:           "public-announcement-v1",
		ApprovedBy:                 "operator-a",
		ApprovedAtUTC:              testAdminTS(4),
	}, http.StatusConflict)
	postAdminReviewedDistributionArtifact(t, handler, "operator-secret", root.poolID, trustpool.ReviewedDistributionArtifact{
		OperationID:                "op-public-v1",
		ManifestCoreDigest:         manifest.ManifestCoreDigest,
		ReviewedDistributionDigest: hexDigest("reviewed-artifact-v2"),
		ArtifactURI:                "https://example.test/trusted-pools/" + root.poolID + "/v2",
		ClaimControlDigest:         hexDigest("claim-control-v2"),
		ReviewedBy:                 "operator-a",
		ReviewedAtUTC:              testAdminTS(5),
	}, http.StatusConflict)
	auditReq := httptest.NewRequest(http.MethodGet, "/admin/trust-pools/pools/"+root.poolID+"/audit", nil)
	auditReq.Header.Set("Authorization", "Bearer operator-secret")
	auditRec := httptest.NewRecorder()
	handler.ServeHTTP(auditRec, auditReq)
	if auditRec.Code != http.StatusOK {
		t.Fatalf("GET audit status=%d body=%s, want 200", auditRec.Code, auditRec.Body.String())
	}
	var auditBody struct {
		ReviewedDistributionArtifactHistory []trustpool.ReviewedDistributionArtifact `json:"reviewed_distribution_artifact_history"`
		PublicAnnouncementHistory           []trustpool.PublicAnnouncementApproval   `json:"public_announcement_history"`
	}
	if err := json.Unmarshal(auditRec.Body.Bytes(), &auditBody); err != nil {
		t.Fatalf("decode audit response: %v", err)
	}
	if len(auditBody.ReviewedDistributionArtifactHistory) != 1 || auditBody.ReviewedDistributionArtifactHistory[0].OperationID != "op-reviewed-artifact-v1" {
		t.Fatalf("reviewed artifact history=%+v, want one immutable op-reviewed-artifact-v1 row", auditBody.ReviewedDistributionArtifactHistory)
	}
	if len(auditBody.PublicAnnouncementHistory) != 1 || auditBody.PublicAnnouncementHistory[0].OperationID != "op-public-v1" {
		t.Fatalf("public announcement history=%+v, want one immutable op-public-v1 row", auditBody.PublicAnnouncementHistory)
	}
	if _, found, err := trustpool.BuildPublicPolicyDocument(t.Context(), store, root.poolID, testAdminTS(5)); err != nil || !found {
		t.Fatalf("BuildPublicPolicyDocument found=%v err=%v, want true nil", found, err)
	}
}

func TestAdminHandler_IssuesRootNonceAndExportsPoolArtifacts(t *testing.T) {
	t.Parallel()
	store, err := trustpool.NewStore(openTrustPoolDB(t))
	if err != nil {
		t.Fatalf("NewStore: %v", err)
	}
	handler := trustpool.NewAdminHandler(trustpool.AdminDeps{
		Store:       store,
		Registry:    trustpool.NewRegistry(),
		OperatorKey: "operator-secret",
	})
	root := newRootFixture(t)
	approveCreator(t, store, "creator-a", "approval-v1", "approval-version-1", "candidate", time.Now().Add(24*time.Hour), trustpool.CreatorStatusEnabled)

	nonceBody, err := json.Marshal(trustpool.RootRegistrationNonceIssue{
		OperationID:            "op-nonce",
		CreatorAccountID:       "creator-a",
		ApprovalRecordID:       "approval-v1",
		CurrentApprovalVersion: "approval-version-1",
		LaunchEnvironment:      "candidate",
		ExpiresAtUTC:           testAdminTS(3600),
	})
	if err != nil {
		t.Fatalf("marshal nonce issue: %v", err)
	}
	req := httptest.NewRequest(http.MethodPost, "/admin/trust-pools/root-registration-nonces", bytes.NewReader(nonceBody))
	req.Header.Set("Authorization", "Bearer operator-secret")
	rec := httptest.NewRecorder()
	handler.ServeHTTP(rec, req)
	if rec.Code != http.StatusCreated {
		t.Fatalf("POST nonce status=%d body=%s, want 201", rec.Code, rec.Body.String())
	}
	assertAdminSchemaVersion(t, rec)
	var nonceResp struct {
		RootRegistrationNonce trustpool.RootRegistrationNonceRecord `json:"root_registration_nonce"`
	}
	if err := json.Unmarshal(rec.Body.Bytes(), &nonceResp); err != nil {
		t.Fatalf("decode nonce response: %v", err)
	}
	if nonceResp.RootRegistrationNonce.Nonce == "" || nonceResp.RootRegistrationNonce.CreatorAccountID != "creator-a" {
		t.Fatalf("nonce response = %+v", nonceResp.RootRegistrationNonce)
	}
	retryReq := httptest.NewRequest(http.MethodPost, "/admin/trust-pools/root-registration-nonces", bytes.NewReader(nonceBody))
	retryReq.Header.Set("Authorization", "Bearer operator-secret")
	retryRec := httptest.NewRecorder()
	handler.ServeHTTP(retryRec, retryReq)
	if retryRec.Code != http.StatusCreated {
		t.Fatalf("POST nonce retry status=%d body=%s, want 201", retryRec.Code, retryRec.Body.String())
	}
	var retryNonceResp struct {
		RootRegistrationNonce trustpool.RootRegistrationNonceRecord `json:"root_registration_nonce"`
	}
	if err := json.Unmarshal(retryRec.Body.Bytes(), &retryNonceResp); err != nil {
		t.Fatalf("decode retry nonce response: %v", err)
	}
	if retryNonceResp.RootRegistrationNonce.Nonce != nonceResp.RootRegistrationNonce.Nonce {
		t.Fatalf("retry nonce = %q, want original %q", retryNonceResp.RootRegistrationNonce.Nonce, nonceResp.RootRegistrationNonce.Nonce)
	}

	postAdminEvent(t, handler, "operator-secret", trustpool.DurableEvent{
		EventType:        trustpool.EventPoolCreated,
		PoolID:           root.poolID,
		CreatorAccountID: "creator-a",
		ApprovalRecordID: "approval-v1",
	}, "op-create", http.StatusAccepted)
	postAdminEvent(t, handler, "operator-secret", signedRootRegistrationForIssue(t, "op-root", testAdminTS(1), root.poolID, "creator-a", "approval-v1", nonceResp.RootRegistrationNonce, root), "op-root", http.StatusAccepted)
	postAdminEvent(t, handler, "operator-secret", signedManifest(t, "op-manifest", testAdminTS(2), root.poolID, 1, root), "op-manifest", http.StatusAccepted)
	postAdminEvent(t, handler, "operator-secret", trustpool.DurableEvent{
		EventType:  trustpool.EventMemberAdmitted,
		PoolID:     root.poolID,
		ProviderID: "provider-a",
	}, "op-member", http.StatusAccepted)
	postAdminEvent(t, handler, "operator-secret", trustpool.DurableEvent{
		EventType:      trustpool.EventBuyerAuthorized,
		PoolID:         root.poolID,
		BuyerAccountID: "acct-a",
	}, "op-buyer", http.StatusAccepted)

	root2 := newRootFixture(t)
	nonceBody2, err := json.Marshal(trustpool.RootRegistrationNonceIssue{
		OperationID:            "op-nonce-2",
		CreatorAccountID:       "creator-a",
		ApprovalRecordID:       "approval-v1",
		CurrentApprovalVersion: "approval-version-1",
		LaunchEnvironment:      "candidate",
		ExpiresAtUTC:           testAdminTS(7200),
	})
	if err != nil {
		t.Fatalf("marshal second nonce issue: %v", err)
	}
	req2 := httptest.NewRequest(http.MethodPost, "/admin/trust-pools/root-registration-nonces", bytes.NewReader(nonceBody2))
	req2.Header.Set("Authorization", "Bearer operator-secret")
	rec2 := httptest.NewRecorder()
	handler.ServeHTTP(rec2, req2)
	if rec2.Code != http.StatusCreated {
		t.Fatalf("POST second nonce status=%d body=%s, want 201", rec2.Code, rec2.Body.String())
	}
	var nonceResp2 struct {
		RootRegistrationNonce trustpool.RootRegistrationNonceRecord `json:"root_registration_nonce"`
	}
	if err := json.Unmarshal(rec2.Body.Bytes(), &nonceResp2); err != nil {
		t.Fatalf("decode second nonce response: %v", err)
	}
	postAdminEvent(t, handler, "operator-secret", trustpool.DurableEvent{
		EventType:        trustpool.EventPoolCreated,
		PoolID:           root2.poolID,
		CreatorAccountID: "creator-a",
		ApprovalRecordID: "approval-v1",
	}, "op-create-2", http.StatusAccepted)
	postAdminEvent(t, handler, "operator-secret", signedRootRegistrationForIssue(t, "op-root-2", testAdminTS(3), root2.poolID, "creator-a", "approval-v1", nonceResp2.RootRegistrationNonce, root2), "op-root-2", http.StatusAccepted)

	for _, tc := range []struct {
		path        string
		wants       []string
		wantsAbsent []string
	}{
		{
			path: "/admin/trust-pools/pools/" + root.poolID + "/audit",
			wants: []string{
				`"events"`,
				`"creator_approval"`,
				`"root_registration_nonces"`,
				`"nonce_sha256"`,
				`"operation_id":"op-nonce"`,
			},
			wantsAbsent: []string{`op-nonce-2`},
		},
		{path: "/admin/trust-pools/pools/" + root.poolID + "/health", wants: []string{`"health_events"`}},
		{
			path: "/admin/trust-pools/pools/" + root.poolID + "/distribution",
			wants: []string{
				`"distribution_package"`,
				`"candidate_only":true`,
				`"production_ready":false`,
				`"launch_environment":"candidate"`,
			},
		},
	} {
		req := httptest.NewRequest(http.MethodGet, tc.path, nil)
		req.Header.Set("Authorization", "Bearer operator-secret")
		rec := httptest.NewRecorder()
		handler.ServeHTTP(rec, req)
		if rec.Code != http.StatusOK {
			t.Fatalf("GET %s status=%d body=%s, want 200", tc.path, rec.Code, rec.Body.String())
		}
		assertAdminSchemaVersion(t, rec)
		if got := rec.Header().Get("Cache-Control"); got != "no-store" {
			t.Fatalf("GET %s Cache-Control=%q, want no-store", tc.path, got)
		}
		for _, want := range tc.wants {
			if !strings.Contains(rec.Body.String(), want) {
				t.Fatalf("GET %s body=%s missing %s", tc.path, rec.Body.String(), want)
			}
		}
		for _, wantAbsent := range tc.wantsAbsent {
			if strings.Contains(rec.Body.String(), wantAbsent) {
				t.Fatalf("GET %s body=%s unexpectedly included %s", tc.path, rec.Body.String(), wantAbsent)
			}
		}
	}
}

func TestAdminHandler_RejectsUnauthorized(t *testing.T) {
	t.Parallel()
	store, err := trustpool.NewStore(openTrustPoolDB(t))
	if err != nil {
		t.Fatalf("NewStore: %v", err)
	}
	handler := trustpool.NewAdminHandler(trustpool.AdminDeps{Store: store, Registry: trustpool.NewRegistry(), OperatorKey: "operator-secret"})
	body, _ := json.Marshal(trustpool.DurableEvent{EventType: trustpool.EventPoolCreated, PoolID: "pool-a"})
	req := httptest.NewRequest(http.MethodPost, "/admin/trust-pools/events", bytes.NewReader(body))
	req.Header.Set("Authorization", "Bearer wrong")
	rec := httptest.NewRecorder()
	handler.ServeHTTP(rec, req)
	if rec.Code != http.StatusUnauthorized {
		t.Fatalf("status = %d body=%s, want 401", rec.Code, rec.Body.String())
	}
	assertAdminSchemaVersion(t, rec)
}

func TestAdminHandler_ReplayChecksBeforeAppend(t *testing.T) {
	t.Parallel()
	store, err := trustpool.NewStore(openTrustPoolDB(t))
	if err != nil {
		t.Fatalf("NewStore: %v", err)
	}
	handler := trustpool.NewAdminHandler(trustpool.AdminDeps{
		Store:       store,
		Registry:    trustpool.NewRegistry(),
		OperatorKey: "operator-secret",
	})
	approveCreator(t, store, "creator-a", "approval-v1", "approval-version-1", "candidate", time.Now().Add(24*time.Hour), trustpool.CreatorStatusEnabled)

	postAdminEvent(t, handler, "operator-secret", trustpool.DurableEvent{
		EventType:        trustpool.EventPoolCreated,
		PoolID:           "pool-a",
		CreatorAccountID: "creator-a",
		ApprovalRecordID: "approval-v1",
	}, "op-create", http.StatusAccepted)
	postAdminEvent(t, handler, "operator-secret", trustpool.DurableEvent{
		EventType: trustpool.EventLifecycleChanged,
		PoolID:    "pool-a",
		Lifecycle: trustpool.LifecycleActive,
	}, "op-bad-active", http.StatusConflict)

	reconstructed, err := store.Reconstruct(t.Context())
	if err != nil {
		t.Fatalf("history should remain reconstructable after rejected append: %v", err)
	}
	if reconstructed.Pools["pool-a"].Generation != 1 {
		t.Fatalf("generation = %d, want only the accepted create event", reconstructed.Pools["pool-a"].Generation)
	}
}

func TestAdminHandler_IdempotencyConflict(t *testing.T) {
	t.Parallel()
	store, err := trustpool.NewStore(openTrustPoolDB(t))
	if err != nil {
		t.Fatalf("NewStore: %v", err)
	}
	handler := trustpool.NewAdminHandler(trustpool.AdminDeps{
		Store:       store,
		Registry:    trustpool.NewRegistry(),
		OperatorKey: "operator-secret",
	})
	approveCreator(t, store, "creator-a", "approval-v1", "approval-version-1", "candidate", time.Now().Add(24*time.Hour), trustpool.CreatorStatusEnabled)

	create := trustpool.DurableEvent{
		EventType:        trustpool.EventPoolCreated,
		PoolID:           "pool-a",
		CreatorAccountID: "creator-a",
		ApprovalRecordID: "approval-v1",
	}
	postAdminEvent(t, handler, "operator-secret", create, "op-create", http.StatusAccepted)
	postAdminEvent(t, handler, "operator-secret", create, "op-create", http.StatusAccepted)
	create.CreatorAccountID = "creator-b"
	postAdminEvent(t, handler, "operator-secret", create, "op-create", http.StatusConflict)
}

func TestAdminHandler_ConflictingOperationIDSourcesRejected(t *testing.T) {
	t.Parallel()
	store, err := trustpool.NewStore(openTrustPoolDB(t))
	if err != nil {
		t.Fatalf("NewStore: %v", err)
	}
	handler := trustpool.NewAdminHandler(trustpool.AdminDeps{
		Store:       store,
		Registry:    trustpool.NewRegistry(),
		OperatorKey: "operator-secret",
	})
	body, err := json.Marshal(trustpool.DurableEvent{
		OperationID:      "body-op",
		EventType:        trustpool.EventPoolCreated,
		PoolID:           "pool-a",
		CreatorAccountID: "creator-a",
		ApprovalRecordID: "approval-v1",
	})
	if err != nil {
		t.Fatalf("marshal: %v", err)
	}
	req := httptest.NewRequest(http.MethodPost, "/admin/trust-pools/events", bytes.NewReader(body))
	req.Header.Set("Authorization", "Bearer operator-secret")
	req.Header.Set("Idempotency-Key", "different-op")
	rec := httptest.NewRecorder()
	handler.ServeHTTP(rec, req)
	if rec.Code != http.StatusConflict {
		t.Fatalf("status=%d body=%s, want 409", rec.Code, rec.Body.String())
	}
	assertAdminSchemaVersion(t, rec)
}

func postAdminEvent(t *testing.T, h http.Handler, operatorKey string, e trustpool.DurableEvent, operationID string, want int) {
	t.Helper()
	body, err := json.Marshal(e)
	if err != nil {
		t.Fatalf("marshal: %v", err)
	}
	req := httptest.NewRequest(http.MethodPost, "/admin/trust-pools/events", bytes.NewReader(body))
	req.Header.Set("Authorization", "Bearer "+operatorKey)
	req.Header.Set("Idempotency-Key", operationID)
	rec := httptest.NewRecorder()
	h.ServeHTTP(rec, req)
	if rec.Code != want {
		t.Fatalf("POST event %s status=%d body=%s, want %d", operationID, rec.Code, rec.Body.String(), want)
	}
	assertAdminSchemaVersion(t, rec)
}

func postAdminCreator(t *testing.T, h http.Handler, operatorKey string, approval trustpool.CreatorApproval, want int) {
	t.Helper()
	body, err := json.Marshal(approval)
	if err != nil {
		t.Fatalf("marshal creator approval: %v", err)
	}
	req := httptest.NewRequest(http.MethodPost, "/admin/trust-pools/creators", bytes.NewReader(body))
	req.Header.Set("Authorization", "Bearer "+operatorKey)
	rec := httptest.NewRecorder()
	h.ServeHTTP(rec, req)
	if rec.Code != want {
		t.Fatalf("POST creator status=%d body=%s, want %d", rec.Code, rec.Body.String(), want)
	}
	assertAdminSchemaVersion(t, rec)
}

func postAdminPublicAnnouncement(t *testing.T, h http.Handler, operatorKey, poolID string, approval trustpool.PublicAnnouncementApproval, want int) *httptest.ResponseRecorder {
	t.Helper()
	body, err := json.Marshal(approval)
	if err != nil {
		t.Fatalf("marshal public announcement approval: %v", err)
	}
	req := httptest.NewRequest(http.MethodPost, "/admin/trust-pools/pools/"+poolID+"/public-announcement", bytes.NewReader(body))
	req.Header.Set("Authorization", "Bearer "+operatorKey)
	rec := httptest.NewRecorder()
	h.ServeHTTP(rec, req)
	if rec.Code != want {
		t.Fatalf("POST public announcement status=%d body=%s, want %d", rec.Code, rec.Body.String(), want)
	}
	assertAdminSchemaVersion(t, rec)
	return rec
}

func postAdminReviewedDistributionArtifact(t *testing.T, h http.Handler, operatorKey, poolID string, artifact trustpool.ReviewedDistributionArtifact, want int) *httptest.ResponseRecorder {
	t.Helper()
	body, err := json.Marshal(artifact)
	if err != nil {
		t.Fatalf("marshal reviewed distribution artifact: %v", err)
	}
	req := httptest.NewRequest(http.MethodPost, "/admin/trust-pools/pools/"+poolID+"/reviewed-distribution-artifact", bytes.NewReader(body))
	req.Header.Set("Authorization", "Bearer "+operatorKey)
	rec := httptest.NewRecorder()
	h.ServeHTTP(rec, req)
	if rec.Code != want {
		t.Fatalf("POST reviewed distribution artifact status=%d body=%s, want %d", rec.Code, rec.Body.String(), want)
	}
	assertAdminSchemaVersion(t, rec)
	return rec
}

func postAdminPromote(t *testing.T, h http.Handler, operatorKey, poolID, operationID string, want int) {
	t.Helper()
	req := httptest.NewRequest(http.MethodPost, "/admin/trust-pools/pools/"+poolID+"/promote", nil)
	req.Header.Set("Authorization", "Bearer "+operatorKey)
	req.Header.Set("Idempotency-Key", operationID)
	rec := httptest.NewRecorder()
	h.ServeHTTP(rec, req)
	if rec.Code != want {
		t.Fatalf("POST promote %s status=%d body=%s, want %d", operationID, rec.Code, rec.Body.String(), want)
	}
	assertAdminSchemaVersion(t, rec)
}

func assertAdminSchemaVersion(t *testing.T, rec *httptest.ResponseRecorder) {
	t.Helper()
	var body map[string]any
	if err := json.Unmarshal(rec.Body.Bytes(), &body); err != nil {
		t.Fatalf("admin response is not JSON: %v body=%s", err, rec.Body.String())
	}
	if body["schema_version"] != trustpool.AdminSchemaVersion {
		t.Fatalf("schema_version=%v, want %s; body=%s", body["schema_version"], trustpool.AdminSchemaVersion, rec.Body.String())
	}
}

func testAdminTS(offset int64) time.Time {
	return time.Unix(1800020000+offset, 0).UTC()
}
