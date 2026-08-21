package trustpool_test

import (
	"bytes"
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"testing"
	"time"

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
		signedManifest(t, "op-manifest", testAdminTS(2), root.poolID, 1, root),
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
		} `json:"pool"`
	}
	if err := json.Unmarshal(rec.Body.Bytes(), &body); err != nil {
		t.Fatalf("decode GET pool body: %v", err)
	}
	if body.Pool.CreatorGateReason != "creator_suspended" || body.Pool.RouteableGeneration == 0 || body.Pool.RouteGateCheckedAtUTC == "" {
		t.Fatalf("GET pool gate fields = %+v, want suspended gate status", body.Pool)
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
