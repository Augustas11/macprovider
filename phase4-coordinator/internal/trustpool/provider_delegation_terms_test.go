package trustpool_test

import (
	"context"
	"crypto/ed25519"
	"crypto/rand"
	"encoding/base64"
	"encoding/hex"
	"testing"
	"time"

	"github.com/augstar/macprovider-coordinator/internal/poolmanifest"
	"github.com/augstar/macprovider-coordinator/internal/trustpool"
)

// SPEC-043-R006 (#1816 A-5): a ProviderPoolDelegationV1 grant binds to the
// policy-terms digest, so a rotation that only moves the validity window,
// manifest_version, and prev_manifest_core_hash keeps a delegated member bound,
// while any substantive change drops it until the owner re-delegates. A legacy
// grant naming a full core digest stays bound to that exact core.

type delegationTermsPool struct {
	store *trustpool.Store
	root  rootFixture
	owner ed25519.PrivateKey
	v1    trustpool.DurableEvent
	ts    time.Time
}

// newDelegationTermsPool promotes a candidate pool whose v1 core is active
// for the next hour, with a creator-owned member keeping min_eligible_members.
func newDelegationTermsPool(t *testing.T, base func(*poolmanifest.PolicyCore)) delegationTermsPool {
	t.Helper()
	ctx := context.Background()
	_, owner, err := ed25519.GenerateKey(rand.Reader)
	if err != nil {
		t.Fatalf("GenerateKey: %v", err)
	}
	store, err := trustpool.NewStore(openTrustPoolDB(t),
		trustpool.WithProviderOwnerPublicKeys(map[string][]byte{"provider-d": owner.Public().(ed25519.PublicKey)}),
		trustpool.WithPoolModelAcceptance(acceptAllPoolModels))
	if err != nil {
		t.Fatalf("NewStore: %v", err)
	}
	root := newRootFixture(t)
	ts := testAdminTS(0)
	approveCreator(t, store, "creator-a", "approval-v1", "approval-version-1", "candidate", time.Now().Add(24*time.Hour), trustpool.CreatorStatusEnabled)
	v1 := signedManifestWithPolicyCoreMutation(t, "op-manifest", ts.Add(2*time.Second), root.poolID, 1, root, func(core *poolmanifest.PolicyCore) {
		core.ExpiresAtUnix = uint64(time.Now().Add(time.Hour).Unix())
		if base != nil {
			base(core)
		}
	})
	appendTrustPoolEvents(t, ctx, store,
		ev("op-create", ts, trustpool.EventPoolCreated, root.poolID, func(e *trustpool.DurableEvent) {
			e.CreatorAccountID = "creator-a"
			e.ApprovalRecordID = "approval-v1"
		}),
		signedRootRegistrationForIssue(t, "op-root", ts.Add(time.Second), root.poolID, "creator-a", "approval-v1", issueRootNonce(t, store, "creator-a", "approval-v1", ts.Add(24*time.Hour)), root),
		v1,
		ev("op-member-a", ts.Add(3*time.Second), trustpool.EventMemberAdmitted, root.poolID, func(e *trustpool.DurableEvent) { e.ProviderID = "provider-a" }),
		ev("op-buyer", ts.Add(4*time.Second), trustpool.EventBuyerAuthorized, root.poolID, func(e *trustpool.DurableEvent) { e.BuyerAccountID = "acct-buyer" }),
	)
	if _, _, applied, err := store.PromotePool(ctx, trustpool.DurableEvent{OperationID: "op-promote", PoolID: root.poolID}); err != nil || !applied {
		t.Fatalf("PromotePool applied=%v err=%v", applied, err)
	}
	return delegationTermsPool{store: store, root: root, owner: owner, v1: v1, ts: ts}
}

// grant signs a delegation for provider-d bound by field ("manifest_core_digest"
// or "manifest_terms_digest") to digest, appends it, and admits the member.
func (f delegationTermsPool) grant(t *testing.T, field, digest, delegationID string, at time.Time) error {
	t.Helper()
	e := delegationEvent(t, f.owner, f.root.poolID, field, digest, delegationID)
	e.OperationID = "op-grant-" + delegationID
	e.TimestampUTC = at
	ctx := context.Background()
	if _, _, _, err := f.store.AppendValidatedEvent(ctx, e); err != nil {
		return err
	}
	admit := ev("op-admit-"+delegationID, at.Add(time.Second), trustpool.EventMemberAdmitted, f.root.poolID, func(e *trustpool.DurableEvent) {
		e.ProviderID = "provider-d"
		e.DelegationID = delegationID
	})
	_, _, _, err := f.store.AppendValidatedEvent(ctx, admit)
	return err
}

// routes reports whether provider-d is a routeable member at `at`.
func (f delegationTermsPool) routes(t *testing.T, at time.Time) bool {
	t.Helper()
	state, err := f.store.Reconstruct(context.Background())
	if err != nil {
		t.Fatalf("Reconstruct: %v", err)
	}
	state.RouteGateCheckedAt = at.UTC()
	snap := routeableFor(t, state, f.root.poolID)
	if !snap.Routeable {
		t.Fatalf("pool not routeable at %v: %+v", at, snap)
	}
	for _, member := range snap.Members {
		if member == "provider-d" {
			return true
		}
	}
	return false
}

func delegationEvent(t *testing.T, owner ed25519.PrivateKey, poolID, field, digest, delegationID string) trustpool.DurableEvent {
	t.Helper()
	signed := map[string]any{
		"schema_version":             trustpool.ProviderPoolDelegationSchemaVersion,
		"creator_account_id":         "creator-a",
		"pool_id":                    poolID,
		"provider_identity":          "provider-d",
		"delegation_id":              delegationID,
		"operation_id":               "deleg-op-" + delegationID,
		field:                        digest,
		"environment_network_id":     "candidate",
		"coordinator_audience":       trustpool.CoordinatorAudienceForEnvironment("candidate"),
		"provider_owner_key_id":      "provider-d-owner-1",
		"provider_owner_key_version": "1",
		"provider_owner_public_key":  base64.StdEncoding.EncodeToString(owner.Public().(ed25519.PublicKey)),
		"issued_at":                  testAdminTS(10).Format("2006-01-02T15:04:05Z"),
		"expires_at":                 testAdminTS(3600 * 24).Format("2006-01-02T15:04:05Z"),
		"revocation_semantics":       trustpool.ProviderPoolDelegationRevocationSemantics,
	}
	sig, err := trustpool.SignProviderPoolDelegation(owner, signed)
	if err != nil {
		t.Fatalf("SignProviderPoolDelegation: %v", err)
	}
	e := trustpool.DurableEvent{
		EventType:                       trustpool.EventDelegationGranted,
		PoolID:                          poolID,
		CreatorAccountID:                "creator-a",
		ProviderID:                      "provider-d",
		DelegationID:                    delegationID,
		DelegationOperationID:           "deleg-op-" + delegationID,
		EnvironmentNetworkID:            "candidate",
		CoordinatorAudience:             trustpool.CoordinatorAudienceForEnvironment("candidate"),
		ProviderOwnerKeyID:              "provider-d-owner-1",
		ProviderOwnerKeyVersion:         "1",
		ProviderOwnerPublicKey:          signed["provider_owner_public_key"].(string),
		DelegationIssuedAt:              signed["issued_at"].(string),
		DelegationExpiresAt:             signed["expires_at"].(string),
		ProviderPoolDelegationSignature: sig,
	}
	if field == "manifest_terms_digest" {
		e.ManifestTermsDigest = digest
	} else {
		e.ManifestCoreDigest = digest
	}
	return e
}

func revocationEvent(t *testing.T, owner ed25519.PrivateKey, poolID, field, digest, delegationID string) trustpool.DurableEvent {
	t.Helper()
	signed := map[string]any{
		"schema_version":             trustpool.ProviderPoolDelegationRevocationSchemaVersion,
		"creator_account_id":         "creator-a",
		"pool_id":                    poolID,
		"provider_identity":          "provider-d",
		"delegation_id":              delegationID,
		"operation_id":               "deleg-revoke-op-" + delegationID,
		field:                        digest,
		"environment_network_id":     "candidate",
		"coordinator_audience":       trustpool.CoordinatorAudienceForEnvironment("candidate"),
		"provider_owner_key_id":      "provider-d-owner-1",
		"provider_owner_key_version": "1",
		"revoked_at":                 testAdminTS(20).Format("2006-01-02T15:04:05Z"),
		"revocation_semantics":       trustpool.ProviderPoolDelegationRevocationSemantics,
	}
	sig, err := trustpool.SignProviderPoolDelegationRevocation(owner, signed)
	if err != nil {
		t.Fatalf("SignProviderPoolDelegationRevocation: %v", err)
	}
	e := trustpool.DurableEvent{
		EventType:               trustpool.EventDelegationRevoked,
		PoolID:                  poolID,
		CreatorAccountID:        "creator-a",
		ProviderID:              "provider-d",
		DelegationID:            delegationID,
		DelegationOperationID:   "deleg-revoke-op-" + delegationID,
		EnvironmentNetworkID:    "candidate",
		CoordinatorAudience:     trustpool.CoordinatorAudienceForEnvironment("candidate"),
		ProviderOwnerKeyID:      "provider-d-owner-1",
		ProviderOwnerKeyVersion: "1",
		DelegationRevokedAt:     signed["revoked_at"].(string),
		ProviderPoolDelegationRevocationSignature: sig,
	}
	if field == "manifest_terms_digest" {
		e.ManifestTermsDigest = digest
	} else {
		e.ManifestCoreDigest = digest
	}
	return e
}

func termsDigestOf(t *testing.T, e trustpool.DurableEvent) string {
	t.Helper()
	digest, err := trustpool.ManifestPolicyTermsDigest(e)
	if err != nil {
		t.Fatalf("ManifestPolicyTermsDigest: %v", err)
	}
	return digest
}

// rotate appends v2 extending v1 (window [v1.expires, +1000s), version and
// chain advanced) after mutate, and returns it with an instant inside its
// window. withSignerSet also appends an authority-log entry for signer set
// version 2, authorized by set 1, and signs the core under it.
func (f delegationTermsPool) rotate(t *testing.T, mutate func(*poolmanifest.PolicyCore), withSignerSet bool) (trustpool.DurableEvent, time.Time) {
	t.Helper()
	var v2 trustpool.DurableEvent
	if withSignerSet {
		v2 = signedManifestRotatingSignerSet(t, "op-manifest-2", f.ts.Add(10*time.Second), f.v1, f.root, mutate)
	} else {
		v2 = signedManifestExtendingWithPolicyCoreMutation(t, "op-manifest-2", f.ts.Add(10*time.Second), f.v1, f.root, mutate)
	}
	if _, _, _, err := f.store.AppendValidatedEvent(context.Background(), v2); err != nil {
		t.Fatalf("append v2: %v", err)
	}
	return v2, time.Now().Add(time.Hour + 10*time.Minute)
}

func signedManifestRotatingSignerSet(t *testing.T, op string, ts time.Time, previous trustpool.DurableEvent, root rootFixture, mutate func(*poolmanifest.PolicyCore)) trustpool.DurableEvent {
	t.Helper()
	raw, err := base64.StdEncoding.DecodeString(previous.ManifestSnapshot)
	if err != nil {
		t.Fatalf("decode snapshot: %v", err)
	}
	snapshot, err := poolmanifest.ParseManifestSnapshot(raw)
	if err != nil {
		t.Fatalf("parse snapshot: %v", err)
	}
	prevEntryHash, err := snapshot.AuthorityLog[len(snapshot.AuthorityLog)-1].EntryHash()
	if err != nil {
		t.Fatalf("EntryHash: %v", err)
	}
	entry := poolmanifest.AuthorityLogEntry{
		PoolID:                      root.poolID,
		SignerSetVersion:            2,
		PrevAuthorityLogEntryHash:   prevEntryHash,
		Keys:                        []poolmanifest.SignerKey{root.policySigner},
		Threshold:                   1,
		NotBeforeUnix:               1,
		ExpiresAtUnix:               9999999999,
		AuthorizingSignerSetVersion: 1,
	}
	entryHash, err := entry.EntryHash()
	if err != nil {
		t.Fatalf("EntryHash: %v", err)
	}
	entryMsg, err := poolmanifest.AuthorityLogEntrySigningMessage(entryHash)
	if err != nil {
		t.Fatalf("AuthorityLogEntrySigningMessage: %v", err)
	}
	entry.Signatures = []poolmanifest.Signature{{KeyID: root.policySigner.KeyID, Sig: ed25519.Sign(root.policySignerPrivateKey, entryMsg)}}
	snapshot.AuthorityLog = append(snapshot.AuthorityLog, entry)
	prevDigest, err := hex.DecodeString(previous.ManifestCoreDigest)
	if err != nil {
		t.Fatalf("decode prev digest: %v", err)
	}
	prevCore := snapshot.Policies[len(snapshot.Policies)-1].SignedCore.Core
	core := prevCore
	core.ManifestVersion = previous.ManifestVersion + 1
	core.PrevManifestCoreHash = prevDigest
	core.NotBeforeUnix = prevCore.ExpiresAtUnix
	core.ExpiresAtUnix = prevCore.ExpiresAtUnix + 1000
	core.SignerSetVersion = 2
	if mutate != nil {
		mutate(&core)
	}
	digest, err := core.ManifestCoreDigest()
	if err != nil {
		t.Fatalf("ManifestCoreDigest: %v", err)
	}
	policyMsg, err := core.SigningMessage()
	if err != nil {
		t.Fatalf("SigningMessage: %v", err)
	}
	snapshot.Policies = append(snapshot.Policies, poolmanifest.AcceptedPolicyRecord{
		SignedCore: poolmanifest.SignedPolicyCore{
			Core:       core,
			Signatures: []poolmanifest.Signature{{KeyID: root.policySigner.KeyID, Sig: ed25519.Sign(root.policySignerPrivateKey, policyMsg)}},
		},
		AcceptedAtUnix: uint64(ts.Unix()),
	})
	nextRaw, err := snapshot.CanonicalBytes()
	if err != nil {
		t.Fatalf("snapshot CanonicalBytes: %v", err)
	}
	e := ev(op, ts, trustpool.EventManifestAccepted, previous.PoolID, func(e *trustpool.DurableEvent) {
		e.ManifestVersion = core.ManifestVersion
		e.ManifestCoreDigest = hex.EncodeToString(digest)
		e.RootIssuerKeyID = "root-key-1"
		e.RootIssuerPublicKeyFingerprint = root.fingerprint
		e.ManifestSnapshot = base64.StdEncoding.EncodeToString(nextRaw)
	})
	msg, err := trustpool.ManifestAcceptanceSigningMessage(e)
	if err != nil {
		t.Fatalf("ManifestAcceptanceSigningMessage: %v", err)
	}
	e.ManifestSignature = signP256ASN1(t, root.privateKey, msg)
	return e
}

// (a) A window/version/chain-only rotation keeps a terms-bound member routed
// through the new core's activation without re-delegation.
func TestProviderPoolDelegationTermsSurviveWindowOnlyRotation(t *testing.T) {
	t.Parallel()
	f := newDelegationTermsPool(t, nil)
	if err := f.grant(t, "manifest_terms_digest", termsDigestOf(t, f.v1), "del-d-1", f.ts.Add(5*time.Second)); err != nil {
		t.Fatalf("terms grant: %v", err)
	}
	if !f.routes(t, time.Now()) {
		t.Fatal("terms-bound member not routed under v1")
	}
	v2, active := f.rotate(t, nil, false)
	if v2.ManifestCoreDigest == f.v1.ManifestCoreDigest || termsDigestOf(t, v2) != termsDigestOf(t, f.v1) {
		t.Fatal("window-only rotation must change the core digest and keep the terms digest")
	}
	if !f.routes(t, active) {
		t.Fatal("terms-bound member dropped by a window-only rotation")
	}
	// The grant stays the live grant for later admissions too.
	state, err := f.store.Reconstruct(context.Background())
	if err != nil {
		t.Fatalf("Reconstruct: %v", err)
	}
	if pool := state.Pools[f.root.poolID]; pool.ManifestTermsDigest != termsDigestOf(t, f.v1) || pool.MemberDelegationIDs["provider-d"] != "del-d-1" {
		t.Fatalf("pool after rotation = terms %q delegation %q", pool.ManifestTermsDigest, pool.MemberDelegationIDs["provider-d"])
	}
}

// (b) Any change outside the four rotation-only fields drops the member at
// the new core's activation until the owner re-delegates for the new terms.
func TestProviderPoolDelegationTermsDropOnSubstantiveChange(t *testing.T) {
	t.Parallel()
	enforce := func(core *poolmanifest.PolicyCore) { core.SettlementMode = "enforce" }
	members := []poolmanifest.AttestedMember{{ProviderAccountID: "acct-member-d", RuntimeClasses: []string{poolmanifest.RuntimeSourceLlamacppLoopback}}}
	cases := map[string]struct {
		base       func(*poolmanifest.PolicyCore)
		mutate     func(*poolmanifest.PolicyCore)
		signerSet  bool
		baseModels bool
	}{
		"pricing entry": {baseModels: true, mutate: func(core *poolmanifest.PolicyCore) {
			entries, err := core.PoolModelEntries()
			if err != nil {
				panic(err)
			}
			attested, err := core.PoolAttestedMembers()
			if err != nil {
				panic(err)
			}
			entries[0].Pricing.CompletionRatePerMtok++
			core.Extensions = nil
			if err := core.SetPoolExtensions(entries, attested); err != nil {
				panic(err)
			}
		}},
		"model allowlist": {base: enforce, mutate: func(core *poolmanifest.PolicyCore) { core.ModelAllowlist = []string{"model-a", "model-b"} }},
		"settlement mode": {base: enforce, mutate: func(core *poolmanifest.PolicyCore) { core.SettlementMode = "observe" }},
		"predicate":       {base: enforce, mutate: func(core *poolmanifest.PolicyCore) { core.MinBinaryVersion = "1.8.40" }},
		"signer set":      {base: enforce, signerSet: true},
	}
	for name, tc := range cases {
		t.Run(name, func(t *testing.T) {
			t.Parallel()
			base := tc.base
			if tc.baseModels {
				base = func(core *poolmanifest.PolicyCore) { withPoolModels(core.PoolID, members)(core) }
			}
			f := newDelegationTermsPool(t, base)
			if err := f.grant(t, "manifest_terms_digest", termsDigestOf(t, f.v1), "del-d-1", f.ts.Add(5*time.Second)); err != nil {
				t.Fatalf("terms grant: %v", err)
			}
			v2, active := f.rotate(t, tc.mutate, tc.signerSet)
			if termsDigestOf(t, v2) == termsDigestOf(t, f.v1) {
				t.Fatal("substantive change kept the terms digest")
			}
			if !f.routes(t, time.Now()) {
				t.Fatal("member must keep routing under the still-active v1")
			}
			if f.routes(t, active) {
				t.Fatal("terms-bound member still routed after a substantive change took effect")
			}
			// A grant for the old terms is refused against the new newest core.
			if err := f.grant(t, "manifest_terms_digest", termsDigestOf(t, f.v1), "del-d-stale", f.ts.Add(20*time.Second)); err == nil {
				t.Fatal("grant naming superseded terms accepted")
			}
			ctx := context.Background()
			revoke := revocationEvent(t, f.owner, f.root.poolID, "manifest_terms_digest", termsDigestOf(t, f.v1), "del-d-1")
			revoke.OperationID = "op-revoke-del-d-1"
			revoke.TimestampUTC = f.ts.Add(30 * time.Second)
			if _, _, _, err := f.store.AppendValidatedEvent(ctx, revoke); err != nil {
				t.Fatalf("revoke old terms grant: %v", err)
			}
			if err := f.grant(t, "manifest_terms_digest", termsDigestOf(t, v2), "del-d-2", f.ts.Add(40*time.Second)); err != nil {
				t.Fatalf("re-delegate for new terms: %v", err)
			}
			if !f.routes(t, active) {
				t.Fatal("re-delegated member not routed under the new terms")
			}
		})
	}
}

// (c) A legacy grant naming the full core digest behaves exactly as before:
// any rotation, even window-only, drops it at activation, and it can neither
// be relabeled as a terms grant nor carry both bindings.
func TestProviderPoolDelegationLegacyCoreGrantUnchanged(t *testing.T) {
	t.Parallel()
	f := newDelegationTermsPool(t, nil)
	terms := termsDigestOf(t, f.v1)
	// Relabeling: a signature over manifest_core_digest never verifies as a
	// manifest_terms_digest grant (nor the reverse), so neither widens.
	relabeled := delegationEvent(t, f.owner, f.root.poolID, "manifest_core_digest", f.v1.ManifestCoreDigest, "del-d-x")
	relabeled.ManifestTermsDigest, relabeled.ManifestCoreDigest = terms, ""
	relabeled.OperationID, relabeled.TimestampUTC = "op-grant-relabeled", f.ts.Add(4*time.Second)
	if _, _, _, err := f.store.AppendValidatedEvent(context.Background(), relabeled); err == nil {
		t.Fatal("core-signed grant accepted as a terms grant")
	}
	both := delegationEvent(t, f.owner, f.root.poolID, "manifest_core_digest", f.v1.ManifestCoreDigest, "del-d-y")
	both.ManifestTermsDigest = terms
	both.OperationID, both.TimestampUTC = "op-grant-both", f.ts.Add(4*time.Second)
	if _, _, _, err := f.store.AppendValidatedEvent(context.Background(), both); err == nil {
		t.Fatal("grant naming both manifest bindings accepted")
	}
	if err := f.grant(t, "manifest_core_digest", f.v1.ManifestCoreDigest, "del-d-1", f.ts.Add(5*time.Second)); err != nil {
		t.Fatalf("legacy grant: %v", err)
	}
	if !f.routes(t, time.Now()) {
		t.Fatal("legacy member not routed under its core")
	}
	_, active := f.rotate(t, nil, false)
	if !f.routes(t, time.Now()) {
		t.Fatal("legacy member must keep routing while its core is active")
	}
	if f.routes(t, active) {
		t.Fatal("legacy core-bound member survived a rotation")
	}
	// A legacy revocation names the core digest it was granted under.
	wrong := revocationEvent(t, f.owner, f.root.poolID, "manifest_terms_digest", terms, "del-d-1")
	wrong.OperationID, wrong.TimestampUTC = "op-revoke-wrong", f.ts.Add(30*time.Second)
	if _, _, _, err := f.store.AppendValidatedEvent(context.Background(), wrong); err == nil {
		t.Fatal("legacy grant revoked by a terms-bound revocation")
	}
	revoke := revocationEvent(t, f.owner, f.root.poolID, "manifest_core_digest", f.v1.ManifestCoreDigest, "del-d-1")
	revoke.OperationID, revoke.TimestampUTC = "op-revoke", f.ts.Add(31*time.Second)
	if _, _, _, err := f.store.AppendValidatedEvent(context.Background(), revoke); err != nil {
		t.Fatalf("legacy revocation: %v", err)
	}
}
