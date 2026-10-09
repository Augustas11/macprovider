package trustpool_test

import (
	"context"
	"encoding/json"
	"errors"
	"net/http"
	"strings"
	"testing"
	"time"

	"github.com/augstar/macprovider-coordinator/internal/trustpool"
)

func selfServeAdmitAndGrant(t *testing.T, f selfServeFixture, poolID string) {
	t.Helper()
	selfServeExpect(t, selfServeDo(t, f.handler, defaultSelfServePrincipal, http.MethodPost, "events", trustpool.DurableEvent{
		EventType: trustpool.EventMemberAdmitted, PoolID: poolID, ProviderID: selfServeOwnedMac,
	}, "op-ss-member"), http.StatusAccepted, "admit owned provider")
	selfServeExpect(t, selfServeDo(t, f.handler, defaultSelfServePrincipal, http.MethodPost, "events", trustpool.DurableEvent{
		EventType: trustpool.EventBuyerAuthorized, PoolID: poolID, BuyerAccountID: selfServeBuyer,
	}, "op-ss-buyer"), http.StatusAccepted, "buyer grant")
}

func selfServePromotionReason(t *testing.T, body string) string {
	t.Helper()
	var decoded struct {
		Error struct {
			Code   string `json:"code"`
			Reason string `json:"reason"`
		} `json:"error"`
	}
	if err := json.Unmarshal([]byte(body), &decoded); err != nil {
		t.Fatalf("decode promotion error: %v (%s)", err, body)
	}
	return decoded.Error.Code + "/" + decoded.Error.Reason
}

func TestSelfServePromotionAppliesTheAutomatedGate(t *testing.T) {
	t.Parallel()
	f := newSelfServeFixture(t)
	_, root := selfServeBuildPool(t, f)

	early := selfServeDo(t, f.handler, defaultSelfServePrincipal, http.MethodPost, "pools/"+root.poolID+"/promote", nil, "op-ss-promote-early")
	selfServeExpect(t, early, http.StatusConflict, "promotion before buyer and member")
	if got := selfServePromotionReason(t, early.Body.String()); got != "promotion_precondition_failed/buyer_authorization_missing" {
		t.Fatalf("early promotion = %s", got)
	}
	selfServeExpect(t, selfServeDo(t, f.handler, defaultSelfServePrincipal, http.MethodPost, "events", trustpool.DurableEvent{
		EventType: trustpool.EventBuyerAuthorized, PoolID: root.poolID, BuyerAccountID: selfServeBuyer,
	}, "op-ss-buyer"), http.StatusAccepted, "buyer grant")
	noMember := selfServeDo(t, f.handler, defaultSelfServePrincipal, http.MethodPost, "pools/"+root.poolID+"/promote", nil, "op-ss-promote-nomember")
	selfServeExpect(t, noMember, http.StatusConflict, "promotion without member")
	if got := selfServePromotionReason(t, noMember.Body.String()); got != "promotion_precondition_failed/member_missing" {
		t.Fatalf("member-less promotion = %s", got)
	}
	selfServeExpect(t, selfServeDo(t, f.handler, defaultSelfServePrincipal, http.MethodPost, "events", trustpool.DurableEvent{
		EventType: trustpool.EventMemberAdmitted, PoolID: root.poolID, ProviderID: selfServeOwnedMac,
	}, "op-ss-member"), http.StatusAccepted, "admit owned provider")

	stranger := selfServePrincipal{account: "acct_stranger", credential: "key_stranger", github: selfServeGitHubID}
	selfServeExpect(t, selfServeDo(t, f.handler, stranger, http.MethodPost, "pools/"+root.poolID+"/promote", nil, "op-ss-promote-stranger"), http.StatusNotFound, "stranger promotion")

	promoted := selfServeDo(t, f.handler, defaultSelfServePrincipal, http.MethodPost, "pools/"+root.poolID+"/promote", map[string]string{"reason": "launch"}, "op-ss-promote")
	selfServeExpect(t, promoted, http.StatusAccepted, "promotion")
	snap := f.registry.Snapshot(root.poolID)
	if !snap.Exists || !snap.Routeable || !snap.Members[selfServeOwnedMac] {
		t.Fatalf("promoted snapshot = %+v", snap)
	}
	if !f.registry.BuyerAuthorized(root.poolID, selfServeBuyer) || f.registry.BuyerAuthorized(root.poolID, "acct_other") {
		t.Fatal("promoted pool buyer authorization does not match the creator's grants")
	}
	selfServeExpect(t, selfServeDo(t, f.handler, defaultSelfServePrincipal, http.MethodPost, "pools/"+root.poolID+"/promote", map[string]string{"reason": "launch"}, "op-ss-promote"), http.StatusAccepted, "idempotent promotion retry")

	// The creator can still pause its own pool; reactivation goes back
	// through the same gate.
	selfServeExpect(t, selfServeDo(t, f.handler, defaultSelfServePrincipal, http.MethodPost, "pools/"+root.poolID+"/lifecycle", map[string]string{"lifecycle": "paused", "reason": "maintenance"}, "op-ss-pause"), http.StatusAccepted, "pause")
	if f.registry.Snapshot(root.poolID).Routeable {
		t.Fatal("paused self-serve pool still routeable")
	}

	// A self-serve private pool can never be publicly announced.
	state, err := f.store.Reconstruct(context.Background())
	if err != nil {
		t.Fatalf("Reconstruct: %v", err)
	}
	digest := state.Pools[root.poolID].ManifestCoreDigest
	if _, err := f.store.UpsertReviewedDistributionArtifact(context.Background(), trustpool.ReviewedDistributionArtifact{
		OperationID:                "op-ss-review",
		PoolID:                     root.poolID,
		ManifestCoreDigest:         digest,
		ReviewedDistributionDigest: strings.Repeat("a", 64),
		ArtifactURI:                "https://example.com/pool",
		ClaimControlDigest:         strings.Repeat("b", 64),
		ReviewedBy:                 "operator",
		ReviewedAtUTC:              time.Now().UTC(),
	}); err != nil {
		t.Fatalf("UpsertReviewedDistributionArtifact: %v", err)
	}
	if _, err := f.store.UpsertPublicAnnouncementApproval(context.Background(), trustpool.PublicAnnouncementApproval{
		OperationID:                "op-ss-announce",
		PoolID:                     root.poolID,
		ManifestCoreDigest:         digest,
		ReviewedDistributionDigest: strings.Repeat("a", 64),
		ApprovalRecordID:           "announce-1",
		ApprovedBy:                 "operator",
		ApprovedAtUTC:              time.Now().UTC(),
	}); !errors.Is(err, trustpool.ErrPublicAnnouncementGate) {
		t.Fatalf("public announcement for a self_serve_private pool err=%v, want ErrPublicAnnouncementGate", err)
	}
}

func TestSelfServePromotionRunsOnAProductionActivatedCoordinator(t *testing.T) {
	t.Parallel()
	custody := strings.Repeat("c", 64)
	f := newSelfServeFixture(t, trustpool.WithProductionActivationGate(trustpool.ProductionActivationGate{
		AllowedLaunchEnvironments: []string{"production"},
		RootCustodyHashes:         []string{custody},
		RootCustodyClasses:        map[string]string{custody: trustpool.RootCustodyClassHSM},
		EvidenceSHA256:            strings.Repeat("e", 64),
	}))
	f.registry.RejectCandidateLaunchEnvironment()
	_, root := selfServeBuildPool(t, f)
	selfServeAdmitAndGrant(t, f, root.poolID)
	selfServeExpect(t, selfServeDo(t, f.handler, defaultSelfServePrincipal, http.MethodPost, "pools/"+root.poolID+"/promote", nil, "op-ss-promote"), http.StatusAccepted, "promotion on production coordinator")
	snap := f.registry.Snapshot(root.poolID)
	if !snap.Routeable || !snap.Members[selfServeOwnedMac] {
		t.Fatalf("self-serve pool on production coordinator = %+v, want routeable without on-call or production evidence", snap)
	}
	state, err := f.store.Reconstruct(context.Background())
	if err != nil {
		t.Fatalf("Reconstruct: %v", err)
	}
	if err := f.store.ApplyRouteGates(context.Background(), state); err != nil {
		t.Fatalf("ApplyRouteGates: %v", err)
	}
	if reason := state.Pools[root.poolID].ProductionGateReason; reason != "" {
		t.Fatalf("self-serve pool production gate reason = %q", reason)
	}
}

// SPEC-043-R005 0.3.0: an acceptance records which account and API key
// accepted which terms, on the approval and in an append-only audit record.
func TestSelfServeAgreementRecordsCredentialProvenance(t *testing.T) {
	t.Parallel()
	f := newSelfServeFixture(t)
	approval := selfServeAgree(t, f)
	if approval.ApprovedByCredentialID != selfServeKeyID {
		t.Fatalf("approval credential = %q, want %q", approval.ApprovedByCredentialID, selfServeKeyID)
	}
	// A contact change from a second key of the same account is a new,
	// separately attributed acceptance.
	secondKey := selfServePrincipal{account: selfServeCreator, credential: "key_selfserve_2", github: selfServeGitHubID}
	changed := selfServeAgreementBody()
	changed["billing_contact"] = "finance@example.com"
	selfServeExpect(t, selfServeDo(t, f.handler, secondKey, http.MethodPost, "agreement", changed, ""), http.StatusAccepted, "second-key acceptance")
	got, _, err := f.store.CreatorApproval(context.Background(), selfServeCreator)
	if err != nil || got.ApprovedByCredentialID != "key_selfserve_2" {
		t.Fatalf("approval after second key = %+v err=%v", got, err)
	}
	records, err := f.store.SelfServeAgreementAcceptances(context.Background(), selfServeCreator)
	if err != nil {
		t.Fatalf("SelfServeAgreementAcceptances: %v", err)
	}
	if len(records) != 2 {
		t.Fatalf("acceptance records = %+v, want 2", records)
	}
	for i, want := range []string{selfServeKeyID, "key_selfserve_2"} {
		r := records[i]
		if r.CreatorAccountID != selfServeCreator || r.CreatorCredentialID != want || r.AgreementTermsDigest != trustpool.SelfServeAgreementTermsDigest() ||
			r.CreatorAgreementVersion != trustpool.SelfServeCreatorAgreementVersion || r.ApprovalRevision != uint64(i+1) {
			t.Fatalf("acceptance record %d = %+v", i, r)
		}
	}
}

// An Agreement past its grace end with an active pool renews through
// self-service: the renewal pauses the pool in the same transaction, and the
// creator promotes it again through the gate.
func TestSelfServeRenewalAfterGracePausesActivePools(t *testing.T) {
	t.Parallel()
	f := newSelfServeFixture(t)
	_, root := selfServeBuildPool(t, f)
	selfServeAdmitAndGrant(t, f, root.poolID)
	selfServeExpect(t, selfServeDo(t, f.handler, defaultSelfServePrincipal, http.MethodPost, "pools/"+root.poolID+"/promote", nil, "op-ss-promote"), http.StatusAccepted, "promotion")

	lapsed, _, err := f.store.CreatorApproval(context.Background(), selfServeCreator)
	if err != nil {
		t.Fatalf("CreatorApproval: %v", err)
	}
	lapsed.CreatorAgreementExpiresAtUTC = time.Now().UTC().Add(-48 * time.Hour)
	lapsed.CreatorAgreementGraceEndsAtUTC = time.Now().UTC().Add(-time.Hour)
	if _, err := f.store.UpsertCreatorApproval(context.Background(), lapsed); err != nil {
		t.Fatalf("lapse agreement: %v", err)
	}
	// The lapsed creator cannot pause by itself.
	selfServeExpect(t, selfServeDo(t, f.handler, defaultSelfServePrincipal, http.MethodPost, "pools/"+root.poolID+"/lifecycle", map[string]string{"lifecycle": "paused"}, "op-ss-pause-lapsed"), http.StatusConflict, "pause under lapsed agreement")

	renewal := selfServeDo(t, f.handler, defaultSelfServePrincipal, http.MethodPost, "agreement", selfServeAgreementBody(), "")
	selfServeExpect(t, renewal, http.StatusAccepted, "renewal after grace")
	var decoded struct {
		Creator    trustpool.CreatorApproval              `json:"creator"`
		Acceptance trustpool.SelfServeAgreementAcceptance `json:"acceptance"`
	}
	if err := json.Unmarshal(renewal.Body.Bytes(), &decoded); err != nil {
		t.Fatalf("decode renewal: %v", err)
	}
	if len(decoded.Acceptance.PausedPoolIDs) != 1 || decoded.Acceptance.PausedPoolIDs[0] != root.poolID {
		t.Fatalf("renewal paused = %v, want [%s]", decoded.Acceptance.PausedPoolIDs, root.poolID)
	}
	if !decoded.Creator.ValidFor(decoded.Creator.ApprovalRecordID, decoded.Creator.CurrentApprovalVersion, trustpool.LaunchEnvironmentSelfServePrivate, time.Now()) {
		t.Fatalf("renewed approval invalid: %+v", decoded.Creator)
	}
	state, err := f.store.Reconstruct(context.Background())
	if err != nil {
		t.Fatalf("Reconstruct: %v", err)
	}
	if p := state.Pools[root.poolID]; p.Lifecycle != trustpool.LifecyclePaused || p.LifecycleReason != trustpool.SelfServeRenewalPauseReason {
		t.Fatalf("pool after renewal lifecycle=%s reason=%s", p.Lifecycle, p.LifecycleReason)
	}
	if f.registry.Snapshot(root.poolID).Routeable {
		t.Fatal("renewal reactivated the pool")
	}
	selfServeExpect(t, selfServeDo(t, f.handler, defaultSelfServePrincipal, http.MethodPost, "pools/"+root.poolID+"/promote", nil, "op-ss-repromote"), http.StatusAccepted, "promotion after renewal")
	if !f.registry.Snapshot(root.poolID).Routeable {
		t.Fatal("re-promoted pool not routeable")
	}
}

// #1880 item 4: a self-serve creator revokes a member and walks its pool
// through draining to retired on the self-serve mount (the gateway's
// /v1/creator/events and /v1/creator/pools/<pool_id>/lifecycle), under the
// verified principal; a stranger cannot.
func TestSelfServeMemberRevokeAndLifecycle(t *testing.T) {
	t.Parallel()
	f := newSelfServeFixture(t)
	_, root := selfServeBuildPool(t, f)
	selfServeAdmitAndGrant(t, f, root.poolID)
	selfServeExpect(t, selfServeDo(t, f.handler, defaultSelfServePrincipal, http.MethodPost, "pools/"+root.poolID+"/promote", map[string]string{"reason": "launch"}, "op-ss-promote"), http.StatusAccepted, "promotion")

	stranger := selfServePrincipal{account: "acct_stranger", credential: "key_stranger", github: selfServeGitHubID}
	selfServeExpect(t, selfServeDo(t, f.handler, stranger, http.MethodPost, "events", trustpool.DurableEvent{
		EventType: trustpool.EventMemberRevoked, PoolID: root.poolID, ProviderID: selfServeOwnedMac,
	}, "op-ss-revoke-stranger"), http.StatusNotFound, "stranger member revoke")
	selfServeExpect(t, selfServeDo(t, f.handler, stranger, http.MethodPost, "pools/"+root.poolID+"/lifecycle", map[string]string{"lifecycle": "retired"}, "op-ss-retire-stranger"), http.StatusNotFound, "stranger retire")

	selfServeExpect(t, selfServeDo(t, f.handler, defaultSelfServePrincipal, http.MethodPost, "events", trustpool.DurableEvent{
		EventType: trustpool.EventMemberRevoked, PoolID: root.poolID, ProviderID: selfServeOwnedMac,
	}, "op-ss-revoke"), http.StatusAccepted, "member revoke")
	if f.registry.Snapshot(root.poolID).Members[selfServeOwnedMac] {
		t.Fatal("revoked member still in the routeable snapshot")
	}
	for _, step := range []struct{ lifecycle, op string }{{"draining", "op-ss-drain"}, {"retired", "op-ss-retire"}} {
		selfServeExpect(t, selfServeDo(t, f.handler, defaultSelfServePrincipal, http.MethodPost, "pools/"+root.poolID+"/lifecycle", map[string]string{"lifecycle": step.lifecycle, "reason": "creator"}, step.op), http.StatusAccepted, step.lifecycle)
		state, err := f.store.Reconstruct(context.Background())
		if err != nil {
			t.Fatalf("Reconstruct: %v", err)
		}
		if got := state.Pools[root.poolID].Lifecycle; got != step.lifecycle {
			t.Fatalf("lifecycle after %s = %s", step.lifecycle, got)
		}
	}
	if f.registry.Snapshot(root.poolID).Routeable {
		t.Fatal("retired self-serve pool still routeable")
	}
	selfServeExpect(t, selfServeDo(t, f.handler, defaultSelfServePrincipal, http.MethodPost, "pools/"+root.poolID+"/lifecycle", map[string]string{"lifecycle": "active"}, "op-ss-reactivate"), http.StatusConflict, "lifecycle active is promotion-only")
}
