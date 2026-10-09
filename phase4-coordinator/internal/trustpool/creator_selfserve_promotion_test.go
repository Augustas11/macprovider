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
