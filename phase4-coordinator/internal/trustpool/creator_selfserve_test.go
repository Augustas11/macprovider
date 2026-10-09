package trustpool_test

import (
	"bytes"
	"context"
	"database/sql"
	"encoding/json"
	"fmt"
	"net/http"
	"net/http/httptest"
	"strconv"
	"testing"
	"time"

	"github.com/augstar/macprovider-coordinator/internal/trustpool"
)

const (
	selfServeServiceToken = "gateway-service-token"
	selfServeCreator      = "acct_selfserve_creator"
	selfServeKeyID        = "key_selfserve_1"
	selfServeGitHubID     = int64(4242)
	selfServeOwnedMac     = "mp-owned-mac"
	selfServeOtherMac     = "mp-someone-else"
	selfServeBuyer        = "acct_selfserve_buyer"
)

type selfServeFixture struct {
	handler  http.Handler
	store    *trustpool.Store
	registry *trustpool.Registry
	db       *sql.DB
}

func newSelfServeFixture(t *testing.T, opts ...trustpool.StoreOption) selfServeFixture {
	t.Helper()
	db := openTrustPoolDB(t)
	store, err := trustpool.NewStore(db, opts...)
	if err != nil {
		t.Fatalf("NewStore: %v", err)
	}
	registry := trustpool.NewRegistry()
	handler := trustpool.NewAdminHandler(trustpool.AdminDeps{
		Store:                   store,
		Registry:                registry,
		OperatorKey:             "operator-secret",
		GatewayServiceToken:     selfServeServiceToken,
		CreatorProviderAdmitted: admittedProviderIDs(selfServeOwnedMac, selfServeOtherMac),
		OwnedProviderIDs: func(_ context.Context, githubUserID int64) ([]string, error) {
			if githubUserID == selfServeGitHubID {
				return []string{selfServeOwnedMac}, nil
			}
			return nil, nil
		},
	})
	return selfServeFixture{handler: handler, store: store, registry: registry, db: db}
}

type selfServePrincipal struct {
	account    string
	credential string
	github     int64
}

var defaultSelfServePrincipal = selfServePrincipal{account: selfServeCreator, credential: selfServeKeyID, github: selfServeGitHubID}

func selfServeDo(t *testing.T, h http.Handler, p selfServePrincipal, method, path string, body any, operationID string) *httptest.ResponseRecorder {
	t.Helper()
	var reader *bytes.Reader
	if body == nil {
		reader = bytes.NewReader(nil)
	} else {
		raw, err := json.Marshal(body)
		if err != nil {
			t.Fatalf("marshal body: %v", err)
		}
		reader = bytes.NewReader(raw)
	}
	req := httptest.NewRequest(method, "/internal/creator/trust-pools/"+path, reader)
	req.Header.Set("Authorization", "Bearer "+selfServeServiceToken)
	if p.account != "" {
		req.Header.Set(trustpool.CreatorAccountIDHeader, p.account)
	}
	if p.credential != "" {
		req.Header.Set(trustpool.CreatorCredentialIDHeader, p.credential)
	}
	if p.github > 0 {
		req.Header.Set(trustpool.CreatorGitHubUserIDHeader, strconv.FormatInt(p.github, 10))
	}
	if operationID != "" {
		req.Header.Set("Idempotency-Key", operationID)
	}
	rec := httptest.NewRecorder()
	h.ServeHTTP(rec, req)
	return rec
}

func selfServeExpect(t *testing.T, rec *httptest.ResponseRecorder, want int, label string) {
	t.Helper()
	if rec.Code != want {
		t.Fatalf("%s status=%d body=%s, want %d", label, rec.Code, rec.Body.String(), want)
	}
	assertAdminSchemaVersion(t, rec)
}

func selfServeAgreementBody() map[string]any {
	return map[string]any{
		"creator_agreement_version":       trustpool.SelfServeCreatorAgreementVersion,
		"agreement_terms_digest":          trustpool.SelfServeAgreementTermsDigest(),
		"accept":                          true,
		"public_display_name":             "Studio Pool",
		"legal_support_contact":           "support@example.com",
		"billing_contact":                 "billing@example.com",
		"emergency_notification_endpoint": "mailto:oncall@example.com",
	}
}

func selfServeAgree(t *testing.T, f selfServeFixture) trustpool.CreatorApproval {
	t.Helper()
	rec := selfServeDo(t, f.handler, defaultSelfServePrincipal, http.MethodPost, "agreement", selfServeAgreementBody(), "")
	selfServeExpect(t, rec, http.StatusAccepted, "agreement")
	var decoded struct {
		Creator trustpool.CreatorApproval `json:"creator"`
	}
	if err := json.Unmarshal(rec.Body.Bytes(), &decoded); err != nil {
		t.Fatalf("decode agreement: %v", err)
	}
	return decoded.Creator
}

func TestSelfServeCreatorMountRequiresServiceTokenAndPrincipal(t *testing.T) {
	t.Parallel()
	f := newSelfServeFixture(t)
	cases := map[string]func(*http.Request){
		"no bearer":           func(r *http.Request) { r.Header.Del("Authorization") },
		"operator bearer":     func(r *http.Request) { r.Header.Set("Authorization", "Bearer operator-secret") },
		"wrong bearer":        func(r *http.Request) { r.Header.Set("Authorization", "Bearer nope") },
		"no account":          func(r *http.Request) { r.Header.Del(trustpool.CreatorAccountIDHeader) },
		"no credential":       func(r *http.Request) { r.Header.Del(trustpool.CreatorCredentialIDHeader) },
		"two accounts":        func(r *http.Request) { r.Header.Add(trustpool.CreatorAccountIDHeader, "acct_other") },
		"malformed account":   func(r *http.Request) { r.Header.Set(trustpool.CreatorAccountIDHeader, "acct bad") },
		"non-numeric github":  func(r *http.Request) { r.Header.Set(trustpool.CreatorGitHubUserIDHeader, "12a") },
		"zero github":         func(r *http.Request) { r.Header.Set(trustpool.CreatorGitHubUserIDHeader, "0") },
		"leading zero github": func(r *http.Request) { r.Header.Set(trustpool.CreatorGitHubUserIDHeader, "042") },
	}
	for name, mutate := range cases {
		req := httptest.NewRequest(http.MethodGet, "/internal/creator/trust-pools/agreement", nil)
		req.Header.Set("Authorization", "Bearer "+selfServeServiceToken)
		req.Header.Set(trustpool.CreatorAccountIDHeader, selfServeCreator)
		req.Header.Set(trustpool.CreatorCredentialIDHeader, selfServeKeyID)
		req.Header.Set(trustpool.CreatorGitHubUserIDHeader, "4242")
		mutate(req)
		rec := httptest.NewRecorder()
		f.handler.ServeHTTP(rec, req)
		if rec.Code != http.StatusUnauthorized {
			t.Fatalf("%s: status=%d body=%s, want 401", name, rec.Code, rec.Body.String())
		}
	}

	disabled := trustpool.NewAdminHandler(trustpool.AdminDeps{Store: f.store, Registry: f.registry, OperatorKey: "operator-secret"})
	rec := selfServeDo(t, disabled, defaultSelfServePrincipal, http.MethodGet, "agreement", nil, "")
	if rec.Code != http.StatusUnauthorized {
		t.Fatalf("mount without a configured service token status=%d, want 401", rec.Code)
	}
	// The configured-credential creator surface never accepts the service token.
	req := httptest.NewRequest(http.MethodGet, "/creator/trust-pools/me", nil)
	req.Header.Set("Authorization", "Bearer "+selfServeServiceToken)
	req.Header.Set(trustpool.CreatorAccountIDHeader, selfServeCreator)
	bearerRec := httptest.NewRecorder()
	f.handler.ServeHTTP(bearerRec, req)
	if bearerRec.Code != http.StatusUnauthorized {
		t.Fatalf("bearer creator surface with service token status=%d, want 401", bearerRec.Code)
	}
}

func TestSelfServeAgreementCreatesBoundedSelfServeApproval(t *testing.T) {
	t.Parallel()
	f := newSelfServeFixture(t)

	terms := selfServeDo(t, f.handler, defaultSelfServePrincipal, http.MethodGet, "agreement", nil, "")
	selfServeExpect(t, terms, http.StatusOK, "agreement terms")
	var published struct {
		Agreement map[string]any `json:"agreement"`
		Digest    string         `json:"agreement_terms_digest"`
	}
	if err := json.Unmarshal(terms.Body.Bytes(), &published); err != nil {
		t.Fatalf("decode terms: %v", err)
	}
	if published.Digest != trustpool.SelfServeAgreementTermsDigest() {
		t.Fatalf("published digest %q, want %q", published.Digest, trustpool.SelfServeAgreementTermsDigest())
	}
	// SPEC-043-R006/R013/R014 creator disclosures are part of the published text.
	for _, field := range []string{"external_runtime_accountability", "pool_model_accountability", "shared_supply_disclosure"} {
		if text, _ := published.Agreement[field].(string); text == "" {
			t.Fatalf("agreement omits %s: %v", field, published.Agreement)
		}
	}

	notAccepted := selfServeAgreementBody()
	notAccepted["accept"] = false
	selfServeExpect(t, selfServeDo(t, f.handler, defaultSelfServePrincipal, http.MethodPost, "agreement", notAccepted, ""), http.StatusBadRequest, "unaccepted agreement")
	stale := selfServeAgreementBody()
	stale["creator_agreement_version"] = "1999-01-01"
	selfServeExpect(t, selfServeDo(t, f.handler, defaultSelfServePrincipal, http.MethodPost, "agreement", stale, ""), http.StatusBadRequest, "stale agreement version")
	unbound := selfServeAgreementBody()
	unbound["agreement_terms_digest"] = "00"
	selfServeExpect(t, selfServeDo(t, f.handler, defaultSelfServePrincipal, http.MethodPost, "agreement", unbound, ""), http.StatusBadRequest, "agreement not bound to the published terms")
	smuggled := selfServeAgreementBody()
	smuggled["approved_by"] = "operator"
	selfServeExpect(t, selfServeDo(t, f.handler, defaultSelfServePrincipal, http.MethodPost, "agreement", smuggled, ""), http.StatusBadRequest, "agreement with unknown field")
	overclaim := selfServeAgreementBody()
	overclaim["public_display_name"] = "Privacy Pool"
	selfServeExpect(t, selfServeDo(t, f.handler, defaultSelfServePrincipal, http.MethodPost, "agreement", overclaim, ""), http.StatusBadRequest, "prohibited display name")

	approval := selfServeAgree(t, f)
	if approval.ApprovedBy != trustpool.SelfServeApprovalActor || approval.AllowedLaunchEnvironment != trustpool.LaunchEnvironmentSelfServePrivate ||
		approval.CreatorAccountID != selfServeCreator || approval.CreatorAgreementVersion != trustpool.SelfServeCreatorAgreementVersion ||
		approval.Status != trustpool.CreatorStatusEnabled || !approval.ValidFor(approval.ApprovalRecordID, approval.CurrentApprovalVersion, trustpool.LaunchEnvironmentSelfServePrivate, time.Now()) {
		t.Fatalf("self-serve approval = %+v", approval)
	}
	if approval.ValidFor(approval.ApprovalRecordID, approval.CurrentApprovalVersion, "candidate", time.Now()) {
		t.Fatal("self-serve approval must not authorize the candidate environment")
	}
	repeat := selfServeDo(t, f.handler, defaultSelfServePrincipal, http.MethodPost, "agreement", selfServeAgreementBody(), "")
	selfServeExpect(t, repeat, http.StatusOK, "repeat agreement")
	got, _, err := f.store.CreatorApproval(context.Background(), selfServeCreator)
	if err != nil || got.ApprovalRevision != approval.ApprovalRevision {
		t.Fatalf("repeat agreement changed revision: %+v err=%v", got, err)
	}
	selfServeExpect(t, selfServeDo(t, f.handler, defaultSelfServePrincipal, http.MethodGet, "me", nil, ""), http.StatusOK, "me")

	// An operator-approved creator id can never be driven or replaced from
	// the self-serve mount.
	approveCreator(t, f.store, "acct_operator_creator", "approval-v1", "approval-version-1", "candidate", time.Now().Add(24*time.Hour), trustpool.CreatorStatusEnabled)
	operatorCreator := selfServePrincipal{account: "acct_operator_creator", credential: selfServeKeyID, github: selfServeGitHubID}
	for _, path := range []string{"me", "pools"} {
		rec := selfServeDo(t, f.handler, operatorCreator, http.MethodGet, path, nil, "")
		if rec.Code != http.StatusForbidden {
			t.Fatalf("operator creator %s via self-serve status=%d body=%s, want 403", path, rec.Code, rec.Body.String())
		}
	}
	rec := selfServeDo(t, f.handler, operatorCreator, http.MethodPost, "agreement", selfServeAgreementBody(), "")
	selfServeExpect(t, rec, http.StatusForbidden, "agreement over operator approval")
	if kept, _, _ := f.store.CreatorApproval(context.Background(), "acct_operator_creator"); kept.ApprovedBy == trustpool.SelfServeApprovalActor {
		t.Fatal("self-serve agreement replaced an operator approval")
	}

	// A suspended self-serve creator cannot re-enable itself.
	suspended := got
	suspended.Status = trustpool.CreatorStatusSuspended
	suspended.SuspensionReason = "abuse_review"
	if _, err := f.store.UpsertCreatorApproval(context.Background(), suspended); err != nil {
		t.Fatalf("suspend: %v", err)
	}
	selfServeExpect(t, selfServeDo(t, f.handler, defaultSelfServePrincipal, http.MethodPost, "agreement", selfServeAgreementBody(), ""), http.StatusConflict, "agreement while suspended")
	if after, _, _ := f.store.CreatorApproval(context.Background(), selfServeCreator); after.Status != trustpool.CreatorStatusSuspended {
		t.Fatalf("suspended creator re-enabled itself: %+v", after)
	}
}

// selfServeRootRegistration signs a root registration bound to the
// self-serve approval version and launch environment.
func selfServeRootRegistration(t *testing.T, op string, approval trustpool.CreatorApproval, nonce trustpool.RootRegistrationNonceRecord, root rootFixture) trustpool.DurableEvent {
	t.Helper()
	e := signedRootRegistrationForIssueInEnvironment(t, op, testAdminTS(1), root.poolID, approval.CreatorAccountID, approval.ApprovalRecordID, nonce, root, nonce.LaunchEnvironment)
	e.CurrentApprovalVersion = approval.CurrentApprovalVersion
	msg, err := trustpool.RootRegistrationSigningMessage(e)
	if err != nil {
		t.Fatalf("RootRegistrationSigningMessage: %v", err)
	}
	e.RootRegistrationSignature = signP256ASN1(t, root.privateKey, msg)
	return e
}

// selfServeBuildPool drives agreement, nonce, pool creation, root
// registration, and a signed manifest through the self-serve mount.
func selfServeBuildPool(t *testing.T, f selfServeFixture) (trustpool.CreatorApproval, rootFixture) {
	t.Helper()
	approval := selfServeAgree(t, f)
	nonceRec := selfServeDo(t, f.handler, defaultSelfServePrincipal, http.MethodPost, "root-registration-nonces", map[string]any{}, "op-ss-nonce")
	selfServeExpect(t, nonceRec, http.StatusCreated, "root nonce")
	var decoded struct {
		Nonce trustpool.RootRegistrationNonceRecord `json:"root_registration_nonce"`
	}
	if err := json.Unmarshal(nonceRec.Body.Bytes(), &decoded); err != nil {
		t.Fatalf("decode nonce: %v", err)
	}
	if decoded.Nonce.LaunchEnvironment != trustpool.LaunchEnvironmentSelfServePrivate || decoded.Nonce.ApprovalRecordID != approval.ApprovalRecordID ||
		decoded.Nonce.CurrentApprovalVersion != approval.CurrentApprovalVersion || decoded.Nonce.CreatorCredentialID != selfServeKeyID {
		t.Fatalf("self-serve nonce = %+v", decoded.Nonce)
	}
	root := newRootFixture(t)
	selfServeExpect(t, selfServeDo(t, f.handler, defaultSelfServePrincipal, http.MethodPost, "events", creatorPoolCreatedEvent(t, root, approval.ApprovalRecordID), "op-ss-create"), http.StatusAccepted, "pool create")
	selfServeExpect(t, selfServeDo(t, f.handler, defaultSelfServePrincipal, http.MethodPost, "events", selfServeRootRegistration(t, "op-ss-root", approval, decoded.Nonce, root), "op-ss-root"), http.StatusAccepted, "root registration")
	manifest := signedManifestWithPolicyCoreMutation(t, "op-ss-manifest", testAdminTS(3), root.poolID, 1, root, isolatedCreatorMVPPolicy)
	selfServeExpect(t, selfServeDo(t, f.handler, defaultSelfServePrincipal, http.MethodPost, "events", manifest, "op-ss-manifest"), http.StatusAccepted, "manifest")
	return approval, root
}

func TestSelfServeCreatorCeilingsComeFromOwnershipAndOwnGrants(t *testing.T) {
	t.Parallel()
	f := newSelfServeFixture(t)
	_, root := selfServeBuildPool(t, f)

	providers := selfServeDo(t, f.handler, defaultSelfServePrincipal, http.MethodGet, "providers", nil, "")
	selfServeExpect(t, providers, http.StatusOK, "providers")
	var listed struct {
		Linked    bool `json:"github_identity_linked"`
		Providers []struct {
			ProviderID     string `json:"provider_id"`
			ServingCapable bool   `json:"serving_capable"`
		} `json:"providers"`
	}
	if err := json.Unmarshal(providers.Body.Bytes(), &listed); err != nil {
		t.Fatalf("decode providers: %v", err)
	}
	if !listed.Linked || len(listed.Providers) != 1 || listed.Providers[0].ProviderID != selfServeOwnedMac || !listed.Providers[0].ServingCapable {
		t.Fatalf("providers = %+v", listed)
	}

	admit := func(provider string) trustpool.DurableEvent {
		return trustpool.DurableEvent{EventType: trustpool.EventMemberAdmitted, PoolID: root.poolID, ProviderID: provider}
	}
	selfServeExpect(t, selfServeDo(t, f.handler, defaultSelfServePrincipal, http.MethodPost, "events", admit(selfServeOtherMac), "op-ss-other"), http.StatusForbidden, "admit unowned provider")
	noGitHub := selfServePrincipal{account: selfServeCreator, credential: selfServeKeyID}
	selfServeExpect(t, selfServeDo(t, f.handler, noGitHub, http.MethodPost, "events", admit(selfServeOwnedMac), "op-ss-nogh"), http.StatusForbidden, "admit without GitHub identity")
	otherGitHub := selfServePrincipal{account: selfServeCreator, credential: selfServeKeyID, github: 7}
	selfServeExpect(t, selfServeDo(t, f.handler, otherGitHub, http.MethodPost, "events", admit(selfServeOwnedMac), "op-ss-othergh"), http.StatusForbidden, "admit with another GitHub identity")
	selfServeExpect(t, selfServeDo(t, f.handler, defaultSelfServePrincipal, http.MethodPost, "events", admit(selfServeOwnedMac), "op-ss-member"), http.StatusAccepted, "admit owned provider")

	selfServeExpect(t, selfServeDo(t, f.handler, defaultSelfServePrincipal, http.MethodPost, "events", trustpool.DurableEvent{
		EventType: trustpool.EventDelegationGranted, PoolID: root.poolID, ProviderID: selfServeOtherMac, DelegationID: "d-1",
	}, "op-ss-deleg"), http.StatusForbidden, "delegation on self-serve")

	selfServeExpect(t, selfServeDo(t, f.handler, defaultSelfServePrincipal, http.MethodPost, "events", trustpool.DurableEvent{
		EventType: trustpool.EventBuyerAuthorized, PoolID: root.poolID, BuyerAccountID: "acct bad",
	}, "op-ss-buyer-bad"), http.StatusForbidden, "malformed buyer grant")
	selfServeExpect(t, selfServeDo(t, f.handler, defaultSelfServePrincipal, http.MethodPost, "events", trustpool.DurableEvent{
		EventType: trustpool.EventBuyerAuthorized, PoolID: root.poolID, BuyerAccountID: selfServeBuyer,
	}, "op-ss-buyer"), http.StatusAccepted, "buyer grant")

	state, err := f.store.Reconstruct(context.Background())
	if err != nil {
		t.Fatalf("Reconstruct: %v", err)
	}
	pool := state.Pools[root.poolID]
	if pool == nil || !pool.Members[selfServeOwnedMac] || pool.Members[selfServeOtherMac] || !pool.BuyerAccounts[selfServeBuyer] {
		t.Fatalf("pool state = %+v", pool)
	}
	if pool.RootIssuer == nil || pool.RootIssuer.LaunchEnvironment != trustpool.LaunchEnvironmentSelfServePrivate {
		t.Fatalf("root issuer = %+v, want self_serve_private", pool.RootIssuer)
	}
	events, err := f.store.Events(context.Background())
	if err != nil {
		t.Fatalf("Events: %v", err)
	}
	for _, e := range events {
		if e.PoolID == root.poolID && (e.CreatorAccountID != selfServeCreator || e.CreatorCredentialID != selfServeKeyID) {
			t.Fatalf("self-serve event %s attributed to %q/%q", e.OperationID, e.CreatorAccountID, e.CreatorCredentialID)
		}
	}

	// Another gateway account never sees or mutates this creator's pool.
	stranger := selfServePrincipal{account: "acct_stranger", credential: "key_stranger", github: selfServeGitHubID}
	selfServeExpect(t, selfServeDo(t, f.handler, stranger, http.MethodGet, "pools/"+root.poolID, nil, ""), http.StatusNotFound, "stranger pool read")
	selfServeExpect(t, selfServeDo(t, f.handler, stranger, http.MethodPost, "events", admit(selfServeOwnedMac), "op-ss-stranger"), http.StatusNotFound, "stranger mutation")
}

// An uncatalogued BYOM member is not serving-capable until its offer binds
// to the pool, and binding needs membership: self-serve admission therefore
// checks token-authenticated presence, not serving capability.
func TestSelfServeAdmissionUsesTokenAuthenticatedPresence(t *testing.T) {
	t.Parallel()
	store, err := trustpool.NewStore(openTrustPoolDB(t))
	if err != nil {
		t.Fatalf("NewStore: %v", err)
	}
	handler := trustpool.NewAdminHandler(trustpool.AdminDeps{
		Store:                     store,
		Registry:                  trustpool.NewRegistry(),
		GatewayServiceToken:       selfServeServiceToken,
		CreatorProviderAdmitted:   admittedProviderIDs(),
		SelfServeProviderAdmitted: admittedProviderIDs(selfServeOwnedMac),
		OwnedProviderIDs: func(_ context.Context, githubUserID int64) ([]string, error) {
			if githubUserID == selfServeGitHubID {
				return []string{selfServeOwnedMac, "mp-owned-offline"}, nil
			}
			return nil, nil
		},
	})
	f := selfServeFixture{handler: handler, store: store}
	_, root := selfServeBuildPool(t, f)
	listed := selfServeDo(t, handler, defaultSelfServePrincipal, http.MethodGet, "providers", nil, "")
	selfServeExpect(t, listed, http.StatusOK, "providers")
	var doc struct {
		Providers []struct {
			ProviderID     string `json:"provider_id"`
			Admissible     bool   `json:"admissible"`
			ServingCapable bool   `json:"serving_capable"`
		} `json:"providers"`
	}
	if err := json.Unmarshal(listed.Body.Bytes(), &doc); err != nil {
		t.Fatalf("decode providers: %v", err)
	}
	if len(doc.Providers) != 2 || !doc.Providers[0].Admissible || doc.Providers[0].ServingCapable || doc.Providers[1].Admissible {
		t.Fatalf("providers = %+v", doc.Providers)
	}
	selfServeExpect(t, selfServeDo(t, handler, defaultSelfServePrincipal, http.MethodPost, "events", trustpool.DurableEvent{
		EventType: trustpool.EventMemberAdmitted, PoolID: root.poolID, ProviderID: "mp-owned-offline",
	}, "op-ss-offline"), http.StatusForbidden, "admit owned but disconnected provider")
	selfServeExpect(t, selfServeDo(t, handler, defaultSelfServePrincipal, http.MethodPost, "events", trustpool.DurableEvent{
		EventType: trustpool.EventMemberAdmitted, PoolID: root.poolID, ProviderID: selfServeOwnedMac,
	}, "op-ss-member"), http.StatusAccepted, "admit owned, token-authenticated provider")
}

func TestSelfServeRateLimitIsPerAccountAndPrecedesWork(t *testing.T) {
	t.Parallel()
	f := newSelfServeFixture(t)
	rejected := selfServeAgreementBody()
	rejected["accept"] = false
	for i := 0; i < trustpool.SelfServeMaxWritesPerWindow; i++ {
		selfServeExpect(t, selfServeDo(t, f.handler, defaultSelfServePrincipal, http.MethodPost, "agreement", rejected, ""), http.StatusBadRequest, "budgeted write")
	}
	limited := selfServeDo(t, f.handler, defaultSelfServePrincipal, http.MethodPost, "agreement", selfServeAgreementBody(), "")
	selfServeExpect(t, limited, http.StatusTooManyRequests, "write over budget")
	if limited.Header().Get("Retry-After") == "" {
		t.Fatal("rate-limited response has no Retry-After")
	}
	if _, ok, _ := f.store.CreatorApproval(context.Background(), selfServeCreator); ok {
		t.Fatal("rate-limited acceptance was recorded")
	}
	// Reads keep their own, larger budget; another account is unaffected.
	selfServeExpect(t, selfServeDo(t, f.handler, defaultSelfServePrincipal, http.MethodGet, "agreement", nil, ""), http.StatusOK, "read under write limit")
	other := selfServePrincipal{account: "acct_other_creator", credential: "key_other", github: 9}
	selfServeExpect(t, selfServeDo(t, f.handler, other, http.MethodPost, "agreement", selfServeAgreementBody(), ""), http.StatusAccepted, "other account")
}

// fillSelfServeHistory inserts placeholder rows that only the cap counters
// read; the caps reject before any replay would see them.
func fillSelfServeHistory(t *testing.T, db *sql.DB, n int, poolID, eventType, creator, approvalID string) {
	t.Helper()
	for i := 0; i < n; i++ {
		if _, err := db.Exec(`INSERT INTO trustpool_events (operation_id, ts_utc, event_type, pool_id, creator_account_id, approval_record_id, payload_json) VALUES (?, ?, ?, ?, ?, ?, '{}')`,
			fmt.Sprintf("filler-%s-%s-%d", eventType, poolID, i), time.Now().UTC().Format(time.RFC3339Nano), eventType, poolID, creator, approvalID); err != nil {
			t.Fatalf("fill history: %v", err)
		}
	}
}

func TestSelfServeHistoryCapsRejectBeforeReplay(t *testing.T) {
	t.Parallel()
	f := newSelfServeFixture(t)
	approval, root := selfServeBuildPool(t, f)

	// Another account can never create a pool under this pool id.
	stranger := selfServePrincipal{account: "acct_stranger", credential: "key_stranger", github: selfServeGitHubID}
	selfServeExpect(t, selfServeDo(t, f.handler, stranger, http.MethodPost, "events", creatorPoolCreatedEvent(t, root, "self-serve:acct_stranger"), "op-ss-stranger-create"), http.StatusNotFound, "pool_created over a foreign pool id")

	// Per-pool event cap.
	fillSelfServeHistory(t, f.db, trustpool.SelfServeMaxEventsPerPool, root.poolID, "test_filler", "", "")
	capped := selfServeDo(t, f.handler, defaultSelfServePrincipal, http.MethodPost, "events", trustpool.DurableEvent{
		EventType: trustpool.EventBuyerAuthorized, PoolID: root.poolID, BuyerAccountID: selfServeBuyer,
	}, "op-ss-buyer-capped")
	selfServeExpect(t, capped, http.StatusConflict, "event over the per-pool cap")
	if !bytes.Contains(capped.Body.Bytes(), []byte("events_per_pool")) {
		t.Fatalf("per-pool cap body = %s", capped.Body.String())
	}
	selfServeExpect(t, selfServeDo(t, f.handler, defaultSelfServePrincipal, http.MethodPost, "pools/"+root.poolID+"/promote", nil, "op-ss-promote-capped"), http.StatusConflict, "promotion over the per-pool cap")

	// Per-creator pool cap.
	fillSelfServeHistory(t, f.db, trustpool.SelfServeMaxPoolsPerCreator-1, "filler-pool", trustpool.EventPoolCreated, selfServeCreator, approval.ApprovalRecordID)
	next := newRootFixture(t)
	over := selfServeDo(t, f.handler, defaultSelfServePrincipal, http.MethodPost, "events", creatorPoolCreatedEvent(t, next, approval.ApprovalRecordID), "op-ss-create-over")
	selfServeExpect(t, over, http.StatusConflict, "pool over the per-creator cap")
	if !bytes.Contains(over.Body.Bytes(), []byte("pools_per_creator")) {
		t.Fatalf("per-creator cap body = %s", over.Body.String())
	}
}

func selfServePoolEventCount(t *testing.T, db *sql.DB, poolID string) int {
	t.Helper()
	var n int
	if err := db.QueryRow(`SELECT COUNT(*) FROM trustpool_events WHERE pool_id = ?`, poolID).Scan(&n); err != nil {
		t.Fatalf("count events: %v", err)
	}
	return n
}

// fillReplayableBuyerGrants pads a pool with real, replayable buyer grants.
func fillReplayableBuyerGrants(t *testing.T, db *sql.DB, poolID string, n int) {
	t.Helper()
	for i := 0; i < n; i++ {
		e := trustpool.DurableEvent{
			OperationID: fmt.Sprintf("pad-%s-%d", poolID, i), TimestampUTC: time.Now().UTC(),
			EventType: trustpool.EventBuyerAuthorized, PoolID: poolID, BuyerAccountID: selfServeBuyer,
		}
		payload, err := json.Marshal(e)
		if err != nil {
			t.Fatalf("marshal pad: %v", err)
		}
		if _, err := db.Exec(`INSERT INTO trustpool_events (operation_id, ts_utc, event_type, pool_id, buyer_account_id, payload_json) VALUES (?, ?, ?, ?, ?, ?)`,
			e.OperationID, e.TimestampUTC.Format(time.RFC3339Nano), e.EventType, poolID, selfServeBuyer, string(payload)); err != nil {
			t.Fatalf("pad history: %v", err)
		}
	}
}

// Restrictive lifecycle transitions keep a small headroom over the per-pool
// cap so a creator can always pause a capped pool, and the headroom is
// itself capped; every self-serve lifecycle event names its account.
func TestSelfServeLifecycleRouteIsCappedWithRestrictiveHeadroom(t *testing.T) {
	t.Parallel()
	f := newSelfServeFixture(t)
	_, root := selfServeBuildPool(t, f)
	selfServeAdmitAndGrant(t, f, root.poolID)
	selfServeExpect(t, selfServeDo(t, f.handler, defaultSelfServePrincipal, http.MethodPost, "pools/"+root.poolID+"/promote", nil, "op-ss-promote"), http.StatusAccepted, "promotion")
	fillReplayableBuyerGrants(t, f.db, root.poolID, trustpool.SelfServeMaxEventsPerPool-selfServePoolEventCount(t, f.db, root.poolID))

	selfServeExpect(t, selfServeDo(t, f.handler, defaultSelfServePrincipal, http.MethodPost, "events", trustpool.DurableEvent{
		EventType: trustpool.EventBuyerAuthorizationRm, PoolID: root.poolID, BuyerAccountID: selfServeBuyer,
	}, "op-ss-buyer-rm-capped"), http.StatusConflict, "grant change at the cap")
	selfServeExpect(t, selfServeDo(t, f.handler, defaultSelfServePrincipal, http.MethodPost, "pools/"+root.poolID+"/lifecycle", map[string]string{"lifecycle": "paused", "reason": "maintenance"}, "op-ss-pause-capped"), http.StatusAccepted, "pause at the cap")
	existing, ok, err := f.store.ExistingEvent(context.Background(), "op-ss-pause-capped")
	if err != nil || !ok || existing.CreatorAccountID != selfServeCreator || existing.CreatorCredentialID != selfServeKeyID {
		t.Fatalf("pause event = %+v ok=%v err=%v", existing, ok, err)
	}

	if _, err := f.db.Exec(`INSERT INTO trustpool_events (operation_id, ts_utc, event_type, pool_id, payload_json)
		SELECT 'headroom-' || id, ts_utc, 'test_filler', pool_id, '{}' FROM trustpool_events WHERE pool_id = ? LIMIT ?`, root.poolID, trustpool.SelfServeRestrictiveHeadroom); err != nil {
		t.Fatalf("fill headroom: %v", err)
	}
	selfServeExpect(t, selfServeDo(t, f.handler, defaultSelfServePrincipal, http.MethodPost, "pools/"+root.poolID+"/lifecycle", map[string]string{"lifecycle": "draining"}, "op-ss-drain-capped"), http.StatusConflict, "lifecycle beyond the headroom")
}

// A repeat compromise report for an already-frozen root never appends: the
// emergency route stays uncapped for the first report, and repeats cannot
// grow history.
func TestSelfServeRepeatRootCompromiseReportDoesNotAppend(t *testing.T) {
	t.Parallel()
	f := newSelfServeFixture(t)
	_, root := selfServeBuildPool(t, f)
	fillReplayableBuyerGrants(t, f.db, root.poolID, trustpool.SelfServeMaxEventsPerPool+trustpool.SelfServeRestrictiveHeadroom)
	selfServeExpect(t, selfServeDo(t, f.handler, defaultSelfServePrincipal, http.MethodPost, "emergency/root-compromise", map[string]string{"pool_id": root.poolID}, "op-ss-compromise-1"), http.StatusAccepted, "first compromise report over the cap")
	before := selfServePoolEventCount(t, f.db, root.poolID)
	for i := 2; i <= 4; i++ {
		selfServeExpect(t, selfServeDo(t, f.handler, defaultSelfServePrincipal, http.MethodPost, "emergency/root-compromise", map[string]string{"pool_id": root.poolID}, fmt.Sprintf("op-ss-compromise-%d", i)), http.StatusAccepted, "repeat compromise report")
	}
	if after := selfServePoolEventCount(t, f.db, root.poolID); after != before {
		t.Fatalf("repeat compromise reports grew history %d -> %d", before, after)
	}
}

// After the write budget is spent, a retry of an already-committed operation
// still gets its replay answer instead of 429.
func TestSelfServeReplayOfCommittedOperationSkipsTheWriteBudget(t *testing.T) {
	t.Parallel()
	f := newSelfServeFixture(t)
	_, root := selfServeBuildPool(t, f)
	admit := trustpool.DurableEvent{EventType: trustpool.EventMemberAdmitted, PoolID: root.poolID, ProviderID: selfServeOwnedMac}
	selfServeExpect(t, selfServeDo(t, f.handler, defaultSelfServePrincipal, http.MethodPost, "events", admit, "op-ss-member"), http.StatusAccepted, "admit")
	rejected := selfServeAgreementBody()
	rejected["accept"] = false
	for {
		rec := selfServeDo(t, f.handler, defaultSelfServePrincipal, http.MethodPost, "agreement", rejected, "")
		if rec.Code == http.StatusTooManyRequests {
			break
		}
		selfServeExpect(t, rec, http.StatusBadRequest, "spend write budget")
	}
	selfServeExpect(t, selfServeDo(t, f.handler, defaultSelfServePrincipal, http.MethodPost, "events", admit, "op-ss-member"), http.StatusAccepted, "replay after the write budget")
	selfServeExpect(t, selfServeDo(t, f.handler, defaultSelfServePrincipal, http.MethodPost, "events", admit, "op-ss-member-new"), http.StatusTooManyRequests, "new write after the write budget")
}
