package trustpool_test

import (
	"context"
	"errors"
	"testing"
	"time"

	"github.com/augstar/macprovider-coordinator/internal/billing"
	"github.com/augstar/macprovider-coordinator/internal/poolmanifest"
	"github.com/augstar/macprovider-coordinator/internal/trustpool"
)

// SPEC-042-R006 conditions 2-4 / SPEC-022-R012.3 (#1690 M4): settlement
// re-derives pool_operator_attested from the durable event log only.
func TestVerifyPoolOperatorAttestationFromDurableRecords(t *testing.T) {
	t.Parallel()
	ctx := context.Background()
	db := openTrustPoolDB(t)
	store, err := trustpool.NewStore(db)
	if err != nil {
		t.Fatalf("NewStore: %v", err)
	}
	ts := time.Unix(1800030000, 0).UTC()
	root := newRootFixture(t)
	approveCreator(t, store, "creator-a", "approval-v1", "approval-version-1", "candidate", time.Now().Add(24*time.Hour), trustpool.CreatorStatusEnabled)
	v1 := signedManifestWithPolicyCoreMutation(t, "op-manifest", ts.Add(2*time.Second), root.poolID, 1, root, func(core *poolmanifest.PolicyCore) {
		core.SettlementMode = "enforce"
	})
	v2 := signedManifestExtendingWithPolicyCoreMutation(t, "op-manifest-2", ts.Add(3*time.Second), v1, root, allowLlamacpp)
	appendTrustPoolEvents(t, ctx, store,
		ev("op-create", ts, trustpool.EventPoolCreated, root.poolID, func(e *trustpool.DurableEvent) {
			e.CreatorAccountID = "creator-a"
			e.ApprovalRecordID = "approval-v1"
		}),
		signedRootRegistrationForIssue(t, "op-root", ts.Add(time.Second), root.poolID, "creator-a", "approval-v1", issueRootNonce(t, store, "creator-a", "approval-v1", ts.Add(time.Hour)), root),
		v1,
		v2,
		ev("op-member-owned", ts.Add(4*time.Second), trustpool.EventMemberAdmitted, root.poolID, func(e *trustpool.DurableEvent) { e.ProviderID = "provider-a" }),
		ev("op-member-b", ts.Add(5*time.Second), trustpool.EventMemberAdmitted, root.poolID, func(e *trustpool.DurableEvent) { e.ProviderID = "provider-b" }),
		ev("op-revoke-b", ts.Add(6*time.Second), trustpool.EventMemberRevoked, root.poolID, func(e *trustpool.DurableEvent) { e.ProviderID = "provider-b" }),
	)
	// A delegated admission (written directly; the signed delegation ledger is
	// out of scope here) is never creator-owned.
	insertPromotedEvent(t, ctx, db, ev("op-member-delegated", ts.Add(7*time.Second), trustpool.EventMemberAdmitted, root.poolID, func(e *trustpool.DurableEvent) {
		e.ProviderID = "provider-d"
		e.DelegationID = "delegation-1"
	}))
	claim := billing.PoolOperatorAttestationClaim{
		PoolID:                root.poolID,
		ManifestVersion:       2,
		ManifestCoreDigest:    v2.ManifestCoreDigest,
		RuntimeSource:         poolmanifest.RuntimeSourceLlamacppLoopback,
		PoolGeneration:        100,
		PoolOperatorAccountID: "creator-a",
		ProviderID:            "provider-a",
	}
	if err := store.VerifyPoolOperatorAttestation(ctx, claim); err != nil {
		t.Fatalf("owned member under an allowlisting v2 core: %v", err)
	}
	for name, mutate := range map[string]func(*billing.PoolOperatorAttestationClaim){
		"operator is not the creator": func(c *billing.PoolOperatorAttestationClaim) { c.PoolOperatorAccountID = "creator-b" },
		"v1 core (native only)": func(c *billing.PoolOperatorAttestationClaim) {
			c.ManifestVersion = 1
			c.ManifestCoreDigest = v1.ManifestCoreDigest
		},
		"runtime not on the allowlist": func(c *billing.PoolOperatorAttestationClaim) {
			c.RuntimeSource = poolmanifest.RuntimeSourceOllamaLoopback
		},
		"digest names no accepted core":   func(c *billing.PoolOperatorAttestationClaim) { c.ManifestCoreDigest = hexDigest("other") },
		"non-member":                      func(c *billing.PoolOperatorAttestationClaim) { c.ProviderID = "provider-z" },
		"revoked before the generation":   func(c *billing.PoolOperatorAttestationClaim) { c.ProviderID = "provider-b" },
		"admitted through a delegation":   func(c *billing.PoolOperatorAttestationClaim) { c.ProviderID = "provider-d" },
		"generation before the admission": func(c *billing.PoolOperatorAttestationClaim) { c.PoolGeneration = 4 },
		"other pool":                      func(c *billing.PoolOperatorAttestationClaim) { c.PoolID = "pool-other" },
	} {
		bad := claim
		mutate(&bad)
		if err := store.VerifyPoolOperatorAttestation(ctx, bad); !errors.Is(err, trustpool.ErrPoolOperatorAttestation) {
			t.Errorf("%s: err=%v, want ErrPoolOperatorAttestation", name, err)
		}
	}
	// A revocation after the fenced generation does not rewrite history, but
	// a generation that covers it fails closed.
	revokedLater := claim
	revokedLater.ProviderID = "provider-b"
	// Event order: 1 create, 2 root, 3 v1, 4 v2, 5 provider-a, 6 provider-b, 7 revoke provider-b.
	revokedLater.PoolGeneration = 6
	if err := store.VerifyPoolOperatorAttestation(ctx, revokedLater); err != nil {
		t.Fatalf("provider-b at generation 6 (before its revocation): %v", err)
	}

	// #1816 F2: the ledger fence reads the durable log through the caller's
	// own transaction and fails only on a revocation since routing, never
	// on the manifest moving on.
	fenceHolds := func(c billing.PoolOperatorAttestationClaim) error {
		t.Helper()
		tx, err := db.BeginTx(ctx, nil)
		if err != nil {
			t.Fatalf("begin ledger tx: %v", err)
		}
		defer func() { _ = tx.Rollback() }()
		return store.PoolRouteFenceHolds(ctx, tx, c)
	}
	routed := claim
	routed.PoolGeneration = 5
	if err := fenceHolds(routed); err != nil {
		t.Fatalf("fence for an unrevoked member: %v", err)
	}
	forged := routed
	forged.ManifestCoreDigest = hexDigest("forged")
	if err := fenceHolds(forged); !errors.Is(err, trustpool.ErrPoolOperatorAttestation) {
		t.Fatalf("fence for a label naming no accepted core: err=%v", err)
	}
	if err := fenceHolds(revokedLater); !errors.Is(err, trustpool.ErrPoolOperatorAttestation) {
		t.Fatalf("fence for provider-b revoked after its routing generation: err=%v", err)
	}
	insertPromotedEvent(t, ctx, db, ev("op-revoke-a", ts.Add(8*time.Second), trustpool.EventMemberRevoked, root.poolID, func(e *trustpool.DurableEvent) { e.ProviderID = "provider-a" }))
	if err := fenceHolds(routed); !errors.Is(err, trustpool.ErrPoolOperatorAttestation) {
		t.Fatalf("fence after provider-a's revocation: err=%v", err)
	}
}
