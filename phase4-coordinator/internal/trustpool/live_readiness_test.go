package trustpool_test

import (
	"bytes"
	"context"
	"crypto/ed25519"
	"crypto/rand"
	"encoding/json"
	"errors"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"
	"time"

	"github.com/augstar/macprovider-coordinator/internal/trustpool"
)

func TestOnCallReadiness_UpsertGetIdempotentAndRejects(t *testing.T) {
	t.Parallel()
	ctx := context.Background()
	store, err := trustpool.NewStore(openTrustPoolDB(t))
	if err != nil {
		t.Fatalf("NewStore: %v", err)
	}
	_, priv, err := ed25519.GenerateKey(rand.Reader)
	if err != nil {
		t.Fatalf("GenerateKey: %v", err)
	}
	allow := trustpool.OnCallAuthorityKeySHA256(priv.Public().(ed25519.PublicKey))
	rec, err := trustpool.SignOnCallReadiness(priv, validOnCallReadiness("op-oncall-1", "launch-candidate"))
	if err != nil {
		t.Fatalf("SignOnCallReadiness: %v", err)
	}

	if _, err := store.UpsertOnCallReadiness(ctx, rec, ""); err == nil || !errors.Is(err, trustpool.ErrOnCallReadiness) {
		t.Fatalf("empty allowlist err=%v, want ErrOnCallReadiness", err)
	}

	stored, err := store.UpsertOnCallReadiness(ctx, rec, allow)
	if err != nil {
		t.Fatalf("UpsertOnCallReadiness: %v", err)
	}
	if stored.RecordRevision != 1 || stored.LaunchEnvironmentID != "launch-candidate" {
		t.Fatalf("stored=%+v, want revision 1 for launch-candidate", stored)
	}
	got, ok, err := store.OnCallReadiness(ctx, "launch-candidate")
	if err != nil || !ok {
		t.Fatalf("OnCallReadiness found=%v err=%v", ok, err)
	}
	if got.OperationID != "op-oncall-1" || got.Expired(time.Now().UTC()) {
		t.Fatalf("got=%+v, want unexpired op-oncall-1", got)
	}

	retry, err := store.UpsertOnCallReadiness(ctx, rec, allow)
	if err != nil {
		t.Fatalf("idempotent retry: %v", err)
	}
	if retry.RecordRevision != 1 || retry.UpdatedAtUTC != got.UpdatedAtUTC {
		t.Fatalf("idempotent retry=%+v, want original %+v", retry, got)
	}

	conflict := rec
	conflict.PrimaryOperatorContact = "ops-other@example.test"
	conflict, err = trustpool.SignOnCallReadiness(priv, conflict)
	if err != nil {
		t.Fatalf("resign conflict: %v", err)
	}
	if _, err := store.UpsertOnCallReadiness(ctx, conflict, allow); err == nil || !errors.Is(err, trustpool.ErrConflictingOperationID) {
		t.Fatalf("same operation_id different body err=%v, want ErrConflictingOperationID", err)
	}

	overTTL := rec
	overTTL.OperationID = "op-oncall-ttl"
	overTTL.ConfirmationTTLSeconds = int64((90*24*time.Hour)/time.Second) + 1
	overTTL, err = trustpool.SignOnCallReadiness(priv, overTTL)
	if err != nil {
		t.Fatalf("resign ttl: %v", err)
	}
	if _, err := store.UpsertOnCallReadiness(ctx, overTTL, allow); err == nil || !errors.Is(err, trustpool.ErrOnCallReadiness) {
		t.Fatalf("ttl>90d err=%v, want ErrOnCallReadiness", err)
	}

	overflowTTL := rec
	overflowTTL.OperationID = "op-oncall-ttl-overflow"
	overflowTTL.ConfirmationTTLSeconds = 18446744074
	overflowTTL, err = trustpool.SignOnCallReadiness(priv, overflowTTL)
	if err != nil {
		t.Fatalf("resign overflow ttl: %v", err)
	}
	if _, err := store.UpsertOnCallReadiness(ctx, overflowTTL, allow); err == nil || !errors.Is(err, trustpool.ErrOnCallReadiness) {
		t.Fatalf("overflow ttl err=%v, want ErrOnCallReadiness", err)
	}

	future := rec
	future.OperationID = "op-oncall-future"
	future.LastConfirmedAtUTC = time.Now().UTC().Add(24 * time.Hour)
	future, err = trustpool.SignOnCallReadiness(priv, future)
	if err != nil {
		t.Fatalf("resign future: %v", err)
	}
	if _, err := store.UpsertOnCallReadiness(ctx, future, allow); err == nil || !errors.Is(err, trustpool.ErrOnCallReadiness) {
		t.Fatalf("future last_confirmed err=%v, want ErrOnCallReadiness", err)
	}

	expired := rec
	expired.OperationID = "op-oncall-expired"
	expired.LastConfirmedAtUTC = time.Now().UTC().Add(-91 * 24 * time.Hour)
	expired, err = trustpool.SignOnCallReadiness(priv, expired)
	if err != nil {
		t.Fatalf("resign expired: %v", err)
	}
	if _, err := store.UpsertOnCallReadiness(ctx, expired, allow); err == nil || !errors.Is(err, trustpool.ErrOnCallReadiness) {
		t.Fatalf("expired upsert err=%v, want ErrOnCallReadiness", err)
	}

	claimed := rec
	claimed.OperationID = "op-oncall-claim"
	claimed.PrimaryOperatorContact = "Privacy Pool on-call"
	claimed, err = trustpool.SignOnCallReadiness(priv, claimed)
	if err != nil {
		t.Fatalf("resign claim: %v", err)
	}
	if _, err := store.UpsertOnCallReadiness(ctx, claimed, allow); err == nil || !errors.Is(err, trustpool.ErrProhibitedPromiseClaim) {
		t.Fatalf("claim-control err=%v, want ErrProhibitedPromiseClaim", err)
	}

	_, otherPriv, err := ed25519.GenerateKey(rand.Reader)
	if err != nil {
		t.Fatalf("GenerateKey other: %v", err)
	}
	wrongKey := rec
	wrongKey.OperationID = "op-oncall-wrong-key"
	wrongKey, err = trustpool.SignOnCallReadiness(otherPriv, wrongKey)
	if err != nil {
		t.Fatalf("sign wrong key: %v", err)
	}
	if _, err := store.UpsertOnCallReadiness(ctx, wrongKey, allow); err == nil || !errors.Is(err, trustpool.ErrOnCallReadiness) {
		t.Fatalf("wrong key err=%v, want ErrOnCallReadiness", err)
	}

	if _, found, err := store.OnCallReadiness(ctx, "missing-env"); err != nil || found {
		t.Fatalf("missing env found=%v err=%v, want false nil", found, err)
	}
}

func TestOnCallReadiness_ExpiredMethod(t *testing.T) {
	t.Parallel()
	now := time.Unix(1_800_000_000, 0).UTC()
	rec := trustpool.OnCallReadiness{
		LastConfirmedAtUTC:     now.Add(-24 * time.Hour),
		ConfirmationTTLSeconds: int64((90 * 24 * time.Hour) / time.Second),
	}
	if rec.Expired(now) {
		t.Fatal("90d ttl should not be expired after 1 day")
	}
	if !rec.Expired(now.Add(90 * 24 * time.Hour)) {
		t.Fatal("record must expire at last_confirmed_at + ttl")
	}
	if !(trustpool.OnCallReadiness{}).Expired(now) {
		t.Fatal("zero record must be expired")
	}
}

func TestReviewedArtifactLifecycle_RequiresPoolAndRejectsBadClass(t *testing.T) {
	t.Parallel()
	ctx := context.Background()
	store, err := trustpool.NewStore(openTrustPoolDB(t))
	if err != nil {
		t.Fatalf("NewStore: %v", err)
	}
	due := time.Now().UTC().Add(30 * 24 * time.Hour)
	missing := trustpool.ReviewedArtifactLifecycle{
		OperationID:      "op-lifecycle-missing",
		PoolID:           "pool-missing",
		Owner:            "ops-oncall",
		EnvironmentClass: trustpool.ReviewedArtifactEnvironmentProduction,
		NextReviewDueUTC: due,
	}
	if _, err := store.UpsertReviewedArtifactLifecycle(ctx, missing); err == nil || !errors.Is(err, trustpool.ErrReviewedArtifactLifecycle) {
		t.Fatalf("missing pool err=%v, want ErrReviewedArtifactLifecycle", err)
	}

	root := seedCandidatePool(t, store)
	badClass := trustpool.ReviewedArtifactLifecycle{
		OperationID:      "op-lifecycle-class",
		PoolID:           root.poolID,
		Owner:            "ops-oncall",
		EnvironmentClass: "staging",
		NextReviewDueUTC: due,
	}
	if _, err := store.UpsertReviewedArtifactLifecycle(ctx, badClass); err == nil || !errors.Is(err, trustpool.ErrReviewedArtifactLifecycle) {
		t.Fatalf("bad class err=%v, want ErrReviewedArtifactLifecycle", err)
	}

	pastDue := trustpool.ReviewedArtifactLifecycle{
		OperationID:      "op-lifecycle-past",
		PoolID:           root.poolID,
		Owner:            "ops-oncall",
		EnvironmentClass: trustpool.ReviewedArtifactEnvironmentCandidate,
		NextReviewDueUTC: time.Now().UTC().Add(-time.Hour),
	}
	if _, err := store.UpsertReviewedArtifactLifecycle(ctx, pastDue); err == nil || !errors.Is(err, trustpool.ErrReviewedArtifactLifecycle) {
		t.Fatalf("past due err=%v, want ErrReviewedArtifactLifecycle", err)
	}

	rec := trustpool.ReviewedArtifactLifecycle{
		OperationID:      "op-lifecycle-1",
		PoolID:           root.poolID,
		Owner:            "ops-oncall",
		EnvironmentClass: trustpool.ReviewedArtifactEnvironmentProduction,
		NextReviewDueUTC: due,
		Notes:            "production artifact owner for launch checklist",
	}
	stored, err := store.UpsertReviewedArtifactLifecycle(ctx, rec)
	if err != nil {
		t.Fatalf("UpsertReviewedArtifactLifecycle: %v", err)
	}
	if stored.RecordRevision != 1 || stored.Owner != "ops-oncall" {
		t.Fatalf("stored=%+v", stored)
	}
	retry, err := store.UpsertReviewedArtifactLifecycle(ctx, rec)
	if err != nil {
		t.Fatalf("idempotent lifecycle retry: %v", err)
	}
	if retry.RecordRevision != 1 {
		t.Fatalf("retry revision=%d, want 1", retry.RecordRevision)
	}
	got, ok, err := store.ReviewedArtifactLifecycle(ctx, root.poolID)
	if err != nil || !ok || got.OperationID != "op-lifecycle-1" {
		t.Fatalf("get lifecycle ok=%v err=%v got=%+v", ok, err, got)
	}

	conflict := rec
	conflict.Owner = "other-owner"
	if _, err := store.UpsertReviewedArtifactLifecycle(ctx, conflict); err == nil || !errors.Is(err, trustpool.ErrConflictingOperationID) {
		t.Fatalf("lifecycle operation conflict err=%v", err)
	}

	claimed := rec
	claimed.OperationID = "op-lifecycle-claim"
	claimed.Notes = "Privacy Pool launch owner"
	if _, err := store.UpsertReviewedArtifactLifecycle(ctx, claimed); err == nil || !errors.Is(err, trustpool.ErrProhibitedPromiseClaim) {
		t.Fatalf("lifecycle claim-control err=%v, want ErrProhibitedPromiseClaim", err)
	}
}

func TestAdminHandler_OnCallReadiness(t *testing.T) {
	_, priv, err := ed25519.GenerateKey(rand.Reader)
	if err != nil {
		t.Fatalf("GenerateKey: %v", err)
	}
	allow := trustpool.OnCallAuthorityKeySHA256(priv.Public().(ed25519.PublicKey))
	t.Setenv("MACPROVIDER_SPEC043_ONCALL_AUTHORITY_KEY_SHA256", allow)

	store, err := trustpool.NewStore(openTrustPoolDB(t))
	if err != nil {
		t.Fatalf("NewStore: %v", err)
	}
	handler := trustpool.NewAdminHandler(trustpool.AdminDeps{
		Store:       store,
		Registry:    trustpool.NewRegistry(),
		OperatorKey: "operator-secret",
	})
	rec, err := trustpool.SignOnCallReadiness(priv, validOnCallReadiness("op-oncall-admin", "launch-staging"))
	if err != nil {
		t.Fatalf("SignOnCallReadiness: %v", err)
	}

	unauth := httptest.NewRequest(http.MethodPost, "/admin/trust-pools/on-call-readiness", bytes.NewReader([]byte(`{}`)))
	unauth.Header.Set("Authorization", "Bearer wrong")
	unauthRec := httptest.NewRecorder()
	handler.ServeHTTP(unauthRec, unauth)
	if unauthRec.Code != http.StatusUnauthorized {
		t.Fatalf("unauthorized status=%d body=%s, want 401", unauthRec.Code, unauthRec.Body.String())
	}

	postAdminOnCall(t, handler, "operator-secret", rec, http.StatusOK)
	postAdminOnCall(t, handler, "operator-secret", rec, http.StatusOK)

	conflict := rec
	conflict.SecondaryOperatorContact = "ops-secondary-other@example.test"
	conflict, err = trustpool.SignOnCallReadiness(priv, conflict)
	if err != nil {
		t.Fatalf("resign: %v", err)
	}
	postAdminOnCall(t, handler, "operator-secret", conflict, http.StatusConflict)

	getReq := httptest.NewRequest(http.MethodGet, "/admin/trust-pools/on-call-readiness?launch_environment_id=launch-staging", nil)
	getReq.Header.Set("Authorization", "Bearer operator-secret")
	getRec := httptest.NewRecorder()
	handler.ServeHTTP(getRec, getReq)
	if getRec.Code != http.StatusOK {
		t.Fatalf("GET on-call status=%d body=%s, want 200", getRec.Code, getRec.Body.String())
	}
	assertAdminSchemaVersion(t, getRec)
	var body struct {
		OnCallReadiness trustpool.OnCallReadiness `json:"on_call_readiness"`
		Expired         bool                      `json:"expired"`
	}
	if err := json.Unmarshal(getRec.Body.Bytes(), &body); err != nil {
		t.Fatalf("decode GET: %v", err)
	}
	if body.OnCallReadiness.OperationID != "op-oncall-admin" || body.Expired {
		t.Fatalf("GET body=%+v", body)
	}

	missing := httptest.NewRequest(http.MethodGet, "/admin/trust-pools/on-call-readiness?launch_environment_id=missing", nil)
	missing.Header.Set("Authorization", "Bearer operator-secret")
	missingRec := httptest.NewRecorder()
	handler.ServeHTTP(missingRec, missing)
	if missingRec.Code != http.StatusNotFound {
		t.Fatalf("missing GET status=%d body=%s, want 404", missingRec.Code, missingRec.Body.String())
	}
}

func TestAdminHandler_ReviewedArtifactLifecycle(t *testing.T) {
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
	root := seedCandidatePoolViaAdmin(t, handler, store)
	rec := trustpool.ReviewedArtifactLifecycle{
		OperationID:      "op-lifecycle-admin",
		PoolID:           root.poolID,
		Owner:            "ops-oncall",
		EnvironmentClass: trustpool.ReviewedArtifactEnvironmentCandidate,
		NextReviewDueUTC: time.Now().UTC().Add(14 * 24 * time.Hour),
		Notes:            "candidate artifact owner",
	}
	postAdminReviewedArtifactLifecycle(t, handler, "operator-secret", root.poolID, rec, http.StatusOK)
	postAdminReviewedArtifactLifecycle(t, handler, "operator-secret", root.poolID, rec, http.StatusOK)

	mismatch := rec
	mismatch.OperationID = "op-lifecycle-mismatch"
	mismatch.PoolID = "other-pool"
	postAdminReviewedArtifactLifecycle(t, handler, "operator-secret", root.poolID, mismatch, http.StatusBadRequest)

	getReq := httptest.NewRequest(http.MethodGet, "/admin/trust-pools/pools/"+root.poolID+"/reviewed-artifact-lifecycle", nil)
	getReq.Header.Set("Authorization", "Bearer operator-secret")
	getRec := httptest.NewRecorder()
	handler.ServeHTTP(getRec, getReq)
	if getRec.Code != http.StatusOK {
		t.Fatalf("GET lifecycle status=%d body=%s, want 200", getRec.Code, getRec.Body.String())
	}
	assertAdminSchemaVersion(t, getRec)
	var body struct {
		ReviewedArtifactLifecycle trustpool.ReviewedArtifactLifecycle `json:"reviewed_artifact_lifecycle"`
	}
	if err := json.Unmarshal(getRec.Body.Bytes(), &body); err != nil {
		t.Fatalf("decode GET lifecycle: %v", err)
	}
	if body.ReviewedArtifactLifecycle.Owner != "ops-oncall" || body.ReviewedArtifactLifecycle.RecordRevision != 1 {
		t.Fatalf("GET lifecycle=%+v", body.ReviewedArtifactLifecycle)
	}
}

func validOnCallReadiness(operationID, envID string) trustpool.OnCallReadiness {
	return trustpool.OnCallReadiness{
		OperationID:                           operationID,
		LaunchEnvironmentID:                   envID,
		RecordVersion:                         "oncall-v1",
		PrimaryOperatorContact:                "ops-primary@example.test",
		SecondaryOperatorContact:              "ops-secondary@example.test",
		BreakGlassEscalationPath:              "page break-glass on-call",
		CompromiseNotificationChannel:         "security-alerts@example.test",
		CreatorAgreementNotificationAck:       "creator-agreement-notify-ack-v1",
		CreatorEmergencyNotificationMechanism: "creator-emergency-webhook",
		LastConfirmedAtUTC:                    time.Now().UTC().Add(-time.Minute),
		ConfirmationTTLSeconds:                int64((90 * 24 * time.Hour) / time.Second),
	}
}

func seedCandidatePool(t *testing.T, store *trustpool.Store) rootFixture {
	t.Helper()
	ctx := context.Background()
	ts := time.Unix(1800000600, 0).UTC()
	root := newRootFixture(t)
	approveCreator(t, store, "creator-a", "approval-v1", "approval-version-1", "candidate", ts.Add(24*time.Hour), trustpool.CreatorStatusEnabled)
	events := []trustpool.DurableEvent{
		ev("op-create", ts, trustpool.EventPoolCreated, root.poolID, func(e *trustpool.DurableEvent) {
			e.CreatorAccountID = "creator-a"
			e.ApprovalRecordID = "approval-v1"
		}),
		signedRootRegistrationForIssue(t, "op-root", ts.Add(time.Second), root.poolID, "creator-a", "approval-v1", issueRootNonce(t, store, "creator-a", "approval-v1", ts.Add(time.Hour)), root),
		signedManifest(t, "op-manifest", ts.Add(2*time.Second), root.poolID, 1, root),
		ev("op-member", ts.Add(3*time.Second), trustpool.EventMemberAdmitted, root.poolID, func(e *trustpool.DurableEvent) {
			e.ProviderID = "provider-a"
		}),
		ev("op-buyer", ts.Add(4*time.Second), trustpool.EventBuyerAuthorized, root.poolID, func(e *trustpool.DurableEvent) {
			e.BuyerAccountID = "acct-a"
		}),
	}
	for _, e := range events {
		if _, _, _, err := store.AppendValidatedEvent(ctx, e); err != nil {
			t.Fatalf("AppendValidatedEvent(%s): %v", e.OperationID, err)
		}
	}
	return root
}

func seedCandidatePoolViaAdmin(t *testing.T, handler http.Handler, store *trustpool.Store) rootFixture {
	t.Helper()
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
	return root
}

func postAdminOnCall(t *testing.T, h http.Handler, operatorKey string, rec trustpool.OnCallReadiness, want int) *httptest.ResponseRecorder {
	t.Helper()
	body, err := json.Marshal(rec)
	if err != nil {
		t.Fatalf("marshal on-call: %v", err)
	}
	req := httptest.NewRequest(http.MethodPost, "/admin/trust-pools/on-call-readiness", bytes.NewReader(body))
	req.Header.Set("Authorization", "Bearer "+operatorKey)
	req.Header.Set("Idempotency-Key", rec.OperationID)
	recw := httptest.NewRecorder()
	h.ServeHTTP(recw, req)
	if recw.Code != want {
		t.Fatalf("POST on-call status=%d body=%s, want %d", recw.Code, recw.Body.String(), want)
	}
	assertAdminSchemaVersion(t, recw)
	return recw
}

func postAdminReviewedArtifactLifecycle(t *testing.T, h http.Handler, operatorKey, poolID string, rec trustpool.ReviewedArtifactLifecycle, want int) *httptest.ResponseRecorder {
	t.Helper()
	body, err := json.Marshal(rec)
	if err != nil {
		t.Fatalf("marshal reviewed artifact lifecycle: %v", err)
	}
	req := httptest.NewRequest(http.MethodPost, "/admin/trust-pools/pools/"+poolID+"/reviewed-artifact-lifecycle", bytes.NewReader(body))
	req.Header.Set("Authorization", "Bearer "+operatorKey)
	req.Header.Set("Idempotency-Key", rec.OperationID)
	recw := httptest.NewRecorder()
	h.ServeHTTP(recw, req)
	if recw.Code != want {
		t.Fatalf("POST reviewed artifact lifecycle status=%d body=%s, want %d", recw.Code, recw.Body.String(), want)
	}
	assertAdminSchemaVersion(t, recw)
	if recw.Code < 300 && !strings.Contains(recw.Body.String(), `"reviewed_artifact_lifecycle"`) {
		t.Fatalf("success body missing reviewed_artifact_lifecycle: %s", recw.Body.String())
	}
	return recw
}
