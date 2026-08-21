package trustpool_test

import (
	"bytes"
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"testing"

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

	postAdminEvent(t, handler, "operator-secret", trustpool.DurableEvent{
		EventType:        trustpool.EventPoolCreated,
		PoolID:           "pool-a",
		CreatorAccountID: "creator-a",
		ApprovalRecordID: "approval-v1",
	}, "op-create", http.StatusAccepted)
	postAdminEvent(t, handler, "operator-secret", trustpool.DurableEvent{
		EventType:          trustpool.EventManifestAccepted,
		PoolID:             "pool-a",
		ManifestVersion:    1,
		ManifestCoreDigest: "digest-a",
	}, "op-manifest", http.StatusAccepted)
	postAdminEvent(t, handler, "operator-secret", trustpool.DurableEvent{
		EventType:  trustpool.EventMemberAdmitted,
		PoolID:     "pool-a",
		ProviderID: "provider-a",
	}, "op-member", http.StatusAccepted)
	postAdminEvent(t, handler, "operator-secret", trustpool.DurableEvent{
		EventType:      trustpool.EventBuyerAuthorized,
		PoolID:         "pool-a",
		BuyerAccountID: "acct-allowed",
	}, "op-buyer", http.StatusAccepted)
	postAdminEvent(t, handler, "operator-secret", trustpool.DurableEvent{
		EventType: trustpool.EventLifecycleChanged,
		PoolID:    "pool-a",
		Lifecycle: trustpool.LifecycleActive,
	}, "op-active", http.StatusConflict)

	snap := registry.Snapshot("pool-a")
	if !snap.Exists || snap.Routeable || snap.Generation != 4 {
		t.Fatalf("registry snapshot = %+v, want non-routeable candidate pool generation 4", snap)
	}
	if len(snap.Members) != 0 {
		t.Fatalf("candidate pool exposed routeable members: %v", snap.Members)
	}
	if !registry.BuyerAuthorized("pool-a", "acct-allowed") {
		t.Fatal("acct-allowed should be authorized after admin buyer event")
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
