package trustpool_test

import (
	"context"
	"crypto/ecdsa"
	"crypto/ed25519"
	"crypto/elliptic"
	"crypto/rand"
	"crypto/sha256"
	"crypto/x509"
	"encoding/base64"
	"encoding/hex"
	"errors"
	"strings"
	"testing"
	"time"

	"github.com/augstar/macprovider-coordinator/internal/poolmanifest"
	"github.com/augstar/macprovider-coordinator/internal/trustpool"
)

type rootFixture struct {
	privateKey             *ecdsa.PrivateKey
	publicDER              string
	fingerprint            string
	authorityRoot          poolmanifest.SignerKey
	authorityPrivateKey    ed25519.PrivateKey
	policySigner           poolmanifest.SignerKey
	policySignerPrivateKey ed25519.PrivateKey
	identityCore           poolmanifest.IdentityCore
	poolID                 string
}

func TestRootIssuerPublicKeyFingerprintIgnoresKeyID(t *testing.T) {
	t.Parallel()
	root := newRootFixture(t)
	a := signedRootRegistration(t, "op-root-a", time.Unix(1800010000, 0).UTC(), "pool-a", "creator-a", "approval-v1", root)
	b := a
	b.RootIssuerKeyID = "renamed-root-key"
	if b.RootIssuerPublicKeyFingerprint != a.RootIssuerPublicKeyFingerprint {
		t.Fatal("test fixture mutated fingerprint unexpectedly")
	}
	if err := trustpool.VerifyRootIssuerRegistrationEvent(a); err != nil {
		t.Fatalf("VerifyRootIssuerRegistrationEvent original: %v", err)
	}
	if err := trustpool.VerifyRootIssuerRegistrationEvent(b); err == nil {
		t.Fatal("renamed key id should invalidate the signed registration bundle")
	}
}

func TestRootIssuerPublicKeyFingerprintRejectsPrivateKeyMaterial(t *testing.T) {
	t.Parallel()
	root := newRootFixture(t)
	privateDER, err := x509.MarshalECPrivateKey(root.privateKey)
	if err != nil {
		t.Fatalf("MarshalECPrivateKey: %v", err)
	}
	if _, err := trustpool.RootIssuerPublicKeyFingerprint(trustpool.RootSignatureAlgorithmP256SHA256, privateDER); err == nil {
		t.Fatal("RootIssuerPublicKeyFingerprint accepted EC private-key material")
	}
}

func TestReconstructEvents_RootRegistrationAndSignedManifestGate(t *testing.T) {
	t.Parallel()
	ts := time.Unix(1800011000, 0).UTC()
	root := newRootFixture(t)
	create := ev("op-create", ts, trustpool.EventPoolCreated, root.poolID, func(e *trustpool.DurableEvent) {
		e.CreatorAccountID = "creator-a"
		e.ApprovalRecordID = "approval-v1"
	})
	registration := signedRootRegistration(t, "op-root", ts.Add(time.Second), root.poolID, "creator-a", "approval-v1", root)
	manifest := signedManifest(t, "op-manifest", ts.Add(2*time.Second), root.poolID, 1, root)
	state, err := trustpool.ReconstructEvents([]trustpool.DurableEvent{create, registration, manifest})
	if err != nil {
		t.Fatalf("ReconstructEvents: %v", err)
	}
	got := state.Pools[root.poolID].RootIssuer
	if got == nil || got.PublicKeyFingerprint != root.fingerprint || got.KeyID != "root-key-1" {
		t.Fatalf("root issuer not replayed: %+v", got)
	}
	if state.Pools[root.poolID].ManifestCoreDigest != manifest.ManifestCoreDigest {
		t.Fatalf("manifest digest not accepted: %+v", state.Pools[root.poolID])
	}
}

func TestReconstructEvents_RejectsManifestBeforeRootOrWrongSigner(t *testing.T) {
	t.Parallel()
	ts := time.Unix(1800012000, 0).UTC()
	root := newRootFixture(t)
	otherRoot := newRootFixture(t)
	create := ev("op-create", ts, trustpool.EventPoolCreated, root.poolID, func(e *trustpool.DurableEvent) {
		e.CreatorAccountID = "creator-a"
		e.ApprovalRecordID = "approval-v1"
	})
	manifest := signedManifest(t, "op-manifest", ts.Add(time.Second), root.poolID, 1, root)
	if _, err := trustpool.ReconstructEvents([]trustpool.DurableEvent{create, manifest}); !errors.Is(err, trustpool.ErrMalformedDurableEvent) {
		t.Fatalf("manifest before root error=%v, want ErrMalformedDurableEvent", err)
	}
	rootEvent := signedRootRegistration(t, "op-root", ts.Add(time.Second), root.poolID, "creator-a", "approval-v1", root)
	wrongSigner := signedManifest(t, "op-manifest-wrong", ts.Add(2*time.Second), root.poolID, 1, root)
	msg, err := trustpool.ManifestAcceptanceSigningMessage(wrongSigner)
	if err != nil {
		t.Fatalf("ManifestAcceptanceSigningMessage wrong signer: %v", err)
	}
	wrongSigner.ManifestSignature = signP256ASN1(t, otherRoot.privateKey, msg)
	if _, err := trustpool.ReconstructEvents([]trustpool.DurableEvent{create, rootEvent, wrongSigner}); !errors.Is(err, trustpool.ErrMalformedDurableEvent) {
		t.Fatalf("wrong signer error=%v, want ErrMalformedDurableEvent", err)
	}
}

func TestReconstructEvents_RejectsManifestPositivePromiseOverclaim(t *testing.T) {
	t.Parallel()
	ts := time.Unix(1800012200, 0).UTC()
	root := newRootFixture(t)
	create := ev("op-create", ts, trustpool.EventPoolCreated, root.poolID, func(e *trustpool.DurableEvent) {
		e.CreatorAccountID = "creator-a"
		e.ApprovalRecordID = "approval-v1"
	})
	rootEvent := signedRootRegistration(t, "op-root", ts.Add(time.Second), root.poolID, "creator-a", "approval-v1", root)
	manifest := signedManifest(t, "op-manifest", ts.Add(2*time.Second), root.poolID, 1, root)
	manifest.ManifestSnapshot = base64.StdEncoding.EncodeToString([]byte(`{"buyer_visible_claim":"Privacy Pool with anonymous routing"}`))
	if _, err := trustpool.ReconstructEvents([]trustpool.DurableEvent{create, rootEvent, manifest}); !errors.Is(err, trustpool.ErrProhibitedPromiseClaim) {
		t.Fatalf("overclaim error=%v, want ErrProhibitedPromiseClaim", err)
	}
}

func TestReconstructEvents_RejectsRootIssuerBuyerVisiblePromiseClaims(t *testing.T) {
	t.Parallel()
	ctx := context.Background()
	store, err := trustpool.NewStore(openTrustPoolDB(t))
	if err != nil {
		t.Fatalf("NewStore: %v", err)
	}
	ts := time.Unix(1800012250, 0).UTC()
	root := newRootFixture(t)
	approveCreator(t, store, "creator-a", "approval-v1", "approval-version-1", "candidate", time.Now().Add(time.Hour), trustpool.CreatorStatusEnabled)
	create := ev("op-create", ts, trustpool.EventPoolCreated, root.poolID, func(e *trustpool.DurableEvent) {
		e.CreatorAccountID = "creator-a"
		e.ApprovalRecordID = "approval-v1"
	})
	if _, _, _, err := store.AppendValidatedEvent(ctx, create); err != nil {
		t.Fatalf("AppendValidatedEvent create: %v", err)
	}
	rootEvent := signedRootRegistrationForIssue(t, "op-root", ts.Add(time.Second), root.poolID, "creator-a", "approval-v1", issueRootNonce(t, store, "creator-a", "approval-v1", ts.Add(time.Hour)), root)
	rootEvent.RootIssuerKeyID = "privacy-pool-root"
	if _, _, _, err := store.AppendValidatedEvent(ctx, rootEvent); !errors.Is(err, trustpool.ErrProhibitedPromiseClaim) {
		t.Fatalf("AppendValidatedEvent root issuer overclaim error=%v, want ErrProhibitedPromiseClaim", err)
	}
}

func TestReconstructEvents_RejectsManifestLayer3PrivacyClaims(t *testing.T) {
	t.Parallel()
	ts := time.Unix(1800012300, 0).UTC()
	root := newRootFixture(t)
	create := ev("op-create", ts, trustpool.EventPoolCreated, root.poolID, func(e *trustpool.DurableEvent) {
		e.CreatorAccountID = "creator-a"
		e.ApprovalRecordID = "approval-v1"
	})
	rootEvent := signedRootRegistration(t, "op-root", ts.Add(time.Second), root.poolID, "creator-a", "approval-v1", root)
	for _, tc := range []struct {
		name   string
		mutate func(*poolmanifest.PolicyCore)
	}{
		{name: "privacy_mode", mutate: func(core *poolmanifest.PolicyCore) { core.PrivacyMode = "relay_blind" }},
		{name: "relay_blind_capable", mutate: func(core *poolmanifest.PolicyCore) { core.RelayBlindCapable = true }},
		{name: "split_execution_status", mutate: func(core *poolmanifest.PolicyCore) { core.SplitExecutionStatus = "executed" }},
		{name: "model_allowlist", mutate: func(core *poolmanifest.PolicyCore) { core.ModelAllowlist = []string{"privacy-pool-model"} }},
	} {
		t.Run(tc.name, func(t *testing.T) {
			manifest := signedManifestWithPolicyCoreMutation(t, "op-manifest-"+tc.name, ts.Add(2*time.Second), root.poolID, 1, root, tc.mutate)
			if _, err := trustpool.ReconstructEvents([]trustpool.DurableEvent{create, rootEvent, manifest}); !errors.Is(err, trustpool.ErrProhibitedPromiseClaim) {
				t.Fatalf("%s error=%v, want ErrProhibitedPromiseClaim", tc.name, err)
			}
		})
	}
}

func TestReconstructEvents_RejectsManifestProhibitedOrInvalidMinBinaryVersion(t *testing.T) {
	t.Parallel()
	ts := time.Unix(1800012400, 0).UTC()
	root := newRootFixture(t)
	create := ev("op-create", ts, trustpool.EventPoolCreated, root.poolID, func(e *trustpool.DurableEvent) {
		e.CreatorAccountID = "creator-a"
		e.ApprovalRecordID = "approval-v1"
	})
	rootEvent := signedRootRegistration(t, "op-root", ts.Add(time.Second), root.poolID, "creator-a", "approval-v1", root)
	for _, tc := range []struct {
		name           string
		version        string
		wantProhibited bool
	}{
		{name: "prohibited claim", version: "privacy-pool", wantProhibited: true},
		{name: "invalid version", version: "not-a-version"},
	} {
		t.Run(tc.name, func(t *testing.T) {
			manifest := signedManifestWithPolicyCoreMutation(t, "op-manifest-"+strings.ReplaceAll(tc.name, " ", "-"), ts.Add(2*time.Second), root.poolID, 1, root, func(core *poolmanifest.PolicyCore) {
				core.MinBinaryVersion = tc.version
			})
			_, err := trustpool.ReconstructEvents([]trustpool.DurableEvent{create, rootEvent, manifest})
			if err == nil {
				t.Fatalf("min_binary_version %q accepted, want rejection", tc.version)
			}
			if tc.wantProhibited && !errors.Is(err, trustpool.ErrProhibitedPromiseClaim) {
				t.Fatalf("min_binary_version %q error=%v, want ErrProhibitedPromiseClaim", tc.version, err)
			}
		})
	}
}

func TestReconstructEvents_RejectsStandaloneHigherVersionManifestFork(t *testing.T) {
	t.Parallel()
	ts := time.Unix(1800012500, 0).UTC()
	root := newRootFixture(t)
	create := ev("op-create", ts, trustpool.EventPoolCreated, root.poolID, func(e *trustpool.DurableEvent) {
		e.CreatorAccountID = "creator-a"
		e.ApprovalRecordID = "approval-v1"
	})
	rootEvent := signedRootRegistration(t, "op-root", ts.Add(time.Second), root.poolID, "creator-a", "approval-v1", root)
	v1 := signedManifest(t, "op-manifest-1", ts.Add(2*time.Second), root.poolID, 1, root)
	standaloneV2 := signedManifest(t, "op-manifest-2-fork", ts.Add(3*time.Second), root.poolID, 2, root)
	if _, err := trustpool.ReconstructEvents([]trustpool.DurableEvent{create, rootEvent, v1, standaloneV2}); !errors.Is(err, trustpool.ErrMalformedDurableEvent) {
		t.Fatalf("standalone v2 fork error=%v, want ErrMalformedDurableEvent", err)
	}
}

func TestReconstructEvents_RejectsManifestGenesisDigestMismatch(t *testing.T) {
	t.Parallel()
	ts := time.Unix(1800012600, 0).UTC()
	root := newRootFixture(t)
	create := ev("op-create", ts, trustpool.EventPoolCreated, root.poolID, func(e *trustpool.DurableEvent) {
		e.CreatorAccountID = "creator-a"
		e.ApprovalRecordID = "approval-v1"
	})
	rootEvent := signedRootRegistration(t, "op-root", ts.Add(time.Second), root.poolID, "creator-a", "approval-v1", root)
	rootEvent.GenesisNonceDigest = hexDigest("wrong-genesis")
	msg, err := trustpool.RootRegistrationSigningMessage(rootEvent)
	if err != nil {
		t.Fatalf("RootRegistrationSigningMessage wrong genesis: %v", err)
	}
	rootEvent.RootRegistrationSignature = signP256ASN1(t, root.privateKey, msg)
	manifest := signedManifest(t, "op-manifest", ts.Add(2*time.Second), root.poolID, 1, root)
	if _, err := trustpool.ReconstructEvents([]trustpool.DurableEvent{create, rootEvent, manifest}); !errors.Is(err, trustpool.ErrMalformedDurableEvent) {
		t.Fatalf("genesis digest mismatch error=%v, want ErrMalformedDurableEvent", err)
	}
}

func TestReconstructEvents_RejectsRootFingerprintReuseAcrossPools(t *testing.T) {
	t.Parallel()
	ts := time.Unix(1800013000, 0).UTC()
	root := newRootFixture(t)
	events := []trustpool.DurableEvent{
		ev("op-create-a", ts, trustpool.EventPoolCreated, root.poolID, func(e *trustpool.DurableEvent) {
			e.CreatorAccountID = "creator-a"
			e.ApprovalRecordID = "approval-v1"
		}),
		signedRootRegistration(t, "op-root-a", ts.Add(time.Second), root.poolID, "creator-a", "approval-v1", root),
		ev("op-create-b", ts.Add(2*time.Second), trustpool.EventPoolCreated, "pool-b", func(e *trustpool.DurableEvent) {
			e.CreatorAccountID = "creator-b"
			e.ApprovalRecordID = "approval-v1"
		}),
		signedRootRegistration(t, "op-root-b", ts.Add(3*time.Second), "pool-b", "creator-b", "approval-v1", root),
	}
	if _, err := trustpool.ReconstructEvents(events); !errors.Is(err, trustpool.ErrMalformedDurableEvent) {
		t.Fatalf("fingerprint reuse error=%v, want ErrMalformedDurableEvent", err)
	}
}

func newRootFixture(t *testing.T) rootFixture {
	t.Helper()
	priv, err := ecdsa.GenerateKey(elliptic.P256(), rand.Reader)
	if err != nil {
		t.Fatalf("GenerateKey: %v", err)
	}
	der, err := x509.MarshalPKIXPublicKey(&priv.PublicKey)
	if err != nil {
		t.Fatalf("MarshalPKIXPublicKey: %v", err)
	}
	fingerprint, err := trustpool.RootIssuerPublicKeyFingerprint(trustpool.RootSignatureAlgorithmP256SHA256, der)
	if err != nil {
		t.Fatalf("RootIssuerPublicKeyFingerprint: %v", err)
	}
	authorityPublic, authorityPrivate, err := ed25519.GenerateKey(rand.Reader)
	if err != nil {
		t.Fatalf("GenerateKey authority: %v", err)
	}
	policyPublic, policyPrivate, err := ed25519.GenerateKey(rand.Reader)
	if err != nil {
		t.Fatalf("GenerateKey policy: %v", err)
	}
	authorityRoot := poolmanifest.SignerKey{KeyID: "manifest-root-1", PublicKey: authorityPublic}
	policySigner := poolmanifest.SignerKey{KeyID: "policy-signer-1", PublicKey: policyPublic}
	genesisNonce := make([]byte, 16)
	if _, err := rand.Read(genesisNonce); err != nil {
		t.Fatalf("read genesis nonce: %v", err)
	}
	identity := poolmanifest.IdentityCore{RootIssuerKeyID: authorityRoot.KeyID, GenesisNonce: genesisNonce}
	poolID, err := identity.PoolID()
	if err != nil {
		t.Fatalf("identity PoolID: %v", err)
	}
	return rootFixture{
		privateKey:             priv,
		publicDER:              base64.StdEncoding.EncodeToString(der),
		fingerprint:            fingerprint,
		authorityRoot:          authorityRoot,
		authorityPrivateKey:    authorityPrivate,
		policySigner:           policySigner,
		policySignerPrivateKey: policyPrivate,
		identityCore:           identity,
		poolID:                 poolID,
	}
}

func signedRootRegistration(t *testing.T, op string, ts time.Time, poolID, creatorID, approvalID string, root rootFixture) trustpool.DurableEvent {
	t.Helper()
	return signedRootRegistrationWithNonce(t, op, ts, poolID, creatorID, approvalID, "nonce-"+op, ts.Add(time.Hour).Format(time.RFC3339Nano), root)
}

func signedRootRegistrationForIssue(t *testing.T, op string, ts time.Time, poolID, creatorID, approvalID string, issue trustpool.RootRegistrationNonceRecord, root rootFixture) trustpool.DurableEvent {
	t.Helper()
	return signedRootRegistrationForIssueInEnvironment(t, op, ts, poolID, creatorID, approvalID, issue, root, "candidate")
}

func signedRootRegistrationForIssueInEnvironment(t *testing.T, op string, ts time.Time, poolID, creatorID, approvalID string, issue trustpool.RootRegistrationNonceRecord, root rootFixture, environment string) trustpool.DurableEvent {
	t.Helper()
	return signedRootRegistrationWithNonceInEnvironment(t, op, ts, poolID, creatorID, approvalID, issue.Nonce, issue.ExpiresAtUTC.UTC().Format(time.RFC3339Nano), root, environment)
}

func signedRootRegistrationWithNonce(t *testing.T, op string, ts time.Time, poolID, creatorID, approvalID, nonce, nonceExpiry string, root rootFixture) trustpool.DurableEvent {
	t.Helper()
	return signedRootRegistrationWithNonceInEnvironment(t, op, ts, poolID, creatorID, approvalID, nonce, nonceExpiry, root, "candidate")
}

func signedRootRegistrationWithNonceInEnvironment(t *testing.T, op string, ts time.Time, poolID, creatorID, approvalID, nonce, nonceExpiry string, root rootFixture, environment string) trustpool.DurableEvent {
	t.Helper()
	e := ev(op, ts, trustpool.EventRootIssuerRegistered, poolID, func(e *trustpool.DurableEvent) {
		e.CreatorAccountID = creatorID
		e.ApprovalRecordID = approvalID
		e.CurrentApprovalVersion = "approval-version-1"
		e.RootIssuerKeyID = "root-key-1"
		e.RootIssuerPublicKeyDER = root.publicDER
		e.RootIssuerPublicKeyFingerprint = root.fingerprint
		e.RootSignatureAlgorithm = trustpool.RootSignatureAlgorithmP256SHA256
		e.ManifestAuthorityRootKeyID = root.authorityRoot.KeyID
		e.ManifestAuthorityRootPublicKey = base64.StdEncoding.EncodeToString(root.authorityRoot.PublicKey)
		e.StructuredKeyCustodyDisclosureHash = hexDigest("custody")
		e.GenesisNonceDigest = hexBytesDigest(root.identityCore.GenesisNonce)
		e.IntendedPoolDisplayNameHash = hexDigest("display")
		e.LaunchEnvironment = environment
		e.RootRegistrationNonce = nonce
		e.RootRegistrationNonceExpiry = nonceExpiry
		e.RootRegistrationPurpose = trustpool.RootRegistrationPurposeDefault
		e.RootRegistrationEnvironment = environment
	})
	msg, err := trustpool.RootRegistrationSigningMessage(e)
	if err != nil {
		t.Fatalf("RootRegistrationSigningMessage: %v", err)
	}
	e.RootRegistrationSignature = signP256ASN1(t, root.privateKey, msg)
	return e
}

func signedManifest(t *testing.T, op string, ts time.Time, poolID string, version uint64, root rootFixture) trustpool.DurableEvent {
	t.Helper()
	return signedManifestWithPolicyCoreMutation(t, op, ts, poolID, version, root, nil)
}

func signedManifestWithPolicyCoreMutation(t *testing.T, op string, ts time.Time, poolID string, version uint64, root rootFixture, mutate func(*poolmanifest.PolicyCore)) trustpool.DurableEvent {
	t.Helper()
	if poolID != root.poolID {
		t.Fatalf("signedManifest poolID=%q, want fixture pool %q", poolID, root.poolID)
	}
	snapshot, digest := manifestSnapshotWithPolicyCoreMutation(t, version, root, mutate)
	e := ev(op, ts, trustpool.EventManifestAccepted, poolID, func(e *trustpool.DurableEvent) {
		e.ManifestVersion = version
		e.ManifestCoreDigest = digest
		e.RootIssuerKeyID = "root-key-1"
		e.RootIssuerPublicKeyFingerprint = root.fingerprint
		e.ManifestSnapshot = snapshot
	})
	msg, err := trustpool.ManifestAcceptanceSigningMessage(e)
	if err != nil {
		t.Fatalf("ManifestAcceptanceSigningMessage: %v", err)
	}
	e.ManifestSignature = signP256ASN1(t, root.privateKey, msg)
	return e
}

func signedManifestExtendingWithPolicyCoreMutation(t *testing.T, op string, ts time.Time, previous trustpool.DurableEvent, root rootFixture, mutate func(*poolmanifest.PolicyCore)) trustpool.DurableEvent {
	t.Helper()
	raw, err := base64.StdEncoding.DecodeString(previous.ManifestSnapshot)
	if err != nil {
		t.Fatalf("decode previous manifest snapshot: %v", err)
	}
	snapshot, err := poolmanifest.ParseManifestSnapshot(raw)
	if err != nil {
		t.Fatalf("parse previous manifest snapshot: %v", err)
	}
	if len(snapshot.Policies) == 0 {
		t.Fatal("previous manifest snapshot has no policies")
	}
	prevDigest, err := hex.DecodeString(previous.ManifestCoreDigest)
	if err != nil {
		t.Fatalf("decode previous manifest digest: %v", err)
	}
	prevCore := snapshot.Policies[len(snapshot.Policies)-1].SignedCore.Core
	core := prevCore
	core.ManifestVersion = previous.ManifestVersion + 1
	core.PrevManifestCoreHash = prevDigest
	core.NotBeforeUnix = prevCore.ExpiresAtUnix
	core.ExpiresAtUnix = prevCore.ExpiresAtUnix + 1000
	if mutate != nil {
		mutate(&core)
	}
	digest, err := core.ManifestCoreDigest()
	if err != nil {
		t.Fatalf("ManifestCoreDigest extending: %v", err)
	}
	policyMsg, err := poolmanifest.PolicyCoreSigningMessage(digest)
	if err != nil {
		t.Fatalf("PolicyCoreSigningMessage extending: %v", err)
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
		t.Fatalf("extended ManifestSnapshot CanonicalBytes: %v", err)
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
		t.Fatalf("ManifestAcceptanceSigningMessage extending: %v", err)
	}
	e.ManifestSignature = signP256ASN1(t, root.privateKey, msg)
	return e
}

func manifestSnapshot(t *testing.T, version uint64, root rootFixture) (string, string) {
	t.Helper()
	return manifestSnapshotWithPolicyCoreMutation(t, version, root, nil)
}

func manifestSnapshotWithPolicyCoreMutation(t *testing.T, version uint64, root rootFixture, mutate func(*poolmanifest.PolicyCore)) (string, string) {
	t.Helper()
	authEntry := poolmanifest.AuthorityLogEntry{
		PoolID:                      root.poolID,
		SignerSetVersion:            1,
		PrevAuthorityLogEntryHash:   poolmanifest.GenesisPrevHash(),
		Keys:                        []poolmanifest.SignerKey{root.policySigner},
		Threshold:                   1,
		NotBeforeUnix:               1,
		ExpiresAtUnix:               9999999999,
		AuthorizingSignerSetVersion: 0,
	}
	authHash, err := authEntry.EntryHash()
	if err != nil {
		t.Fatalf("authority EntryHash: %v", err)
	}
	authMsg, err := poolmanifest.AuthorityLogEntrySigningMessage(authHash)
	if err != nil {
		t.Fatalf("AuthorityLogEntrySigningMessage: %v", err)
	}
	authEntry.Signatures = []poolmanifest.Signature{{KeyID: root.authorityRoot.KeyID, Sig: ed25519.Sign(root.authorityPrivateKey, authMsg)}}

	core := poolmanifest.PolicyCore{
		PoolID:               root.poolID,
		ManifestVersion:      version,
		PrevManifestCoreHash: poolmanifest.GenesisPrevHash(),
		SignerSetVersion:     1,
		ModelAllowlist:       []string{"model-a"},
		MinBinaryVersion:     "1.8.33",
		MinAttestationTier:   "hardware",
		RequireEncryptedLeg:  true,
		SettlementMode:       "pool_label_only",
		RevenueSplitBps:      0,
		SplitExecutionStatus: "declared_not_executed",
		RetentionPolicyID:    "retention-test",
		MinEligibleMembers:   1,
		PrivacyMode:          "none",
		MetadataVisible:      "standard",
		DowngradePolicy:      "reject",
		NotBeforeUnix:        2,
		ExpiresAtUnix:        9999999999,
	}
	if mutate != nil {
		mutate(&core)
	}
	digest, err := core.ManifestCoreDigest()
	if err != nil {
		t.Fatalf("ManifestCoreDigest: %v", err)
	}
	policyMsg, err := poolmanifest.PolicyCoreSigningMessage(digest)
	if err != nil {
		t.Fatalf("PolicyCoreSigningMessage: %v", err)
	}
	snapshot := poolmanifest.ManifestSnapshot{
		IdentityCore:  root.identityCore,
		RootIssuerKey: root.authorityRoot,
		AuthorityLog:  []poolmanifest.AuthorityLogEntry{authEntry},
		Policies: []poolmanifest.AcceptedPolicyRecord{{
			SignedCore: poolmanifest.SignedPolicyCore{
				Core:       core,
				Signatures: []poolmanifest.Signature{{KeyID: root.policySigner.KeyID, Sig: ed25519.Sign(root.policySignerPrivateKey, policyMsg)}},
			},
			AcceptedAtUnix: uint64(time.Now().Unix()),
		}},
	}
	raw, err := snapshot.CanonicalBytes()
	if err != nil {
		t.Fatalf("ManifestSnapshot CanonicalBytes: %v", err)
	}
	return base64.StdEncoding.EncodeToString(raw), hex.EncodeToString(digest)
}

func issueRootNonce(t *testing.T, store *trustpool.Store, creatorID, approvalID string, expiresAt time.Time) trustpool.RootRegistrationNonceRecord {
	t.Helper()
	return issueRootNonceInEnvironment(t, store, creatorID, approvalID, "candidate", expiresAt)
}

func issueRootNonceInEnvironment(t *testing.T, store *trustpool.Store, creatorID, approvalID, environment string, expiresAt time.Time) trustpool.RootRegistrationNonceRecord {
	t.Helper()
	if approval, ok, err := store.CreatorApproval(context.Background(), creatorID); err != nil {
		t.Fatalf("CreatorApproval: %v", err)
	} else if !ok || !approval.ValidFor(approvalID, "approval-version-1", environment, time.Now()) {
		approveCreator(t, store, creatorID, approvalID, "approval-version-1", environment, time.Now().Add(24*time.Hour), trustpool.CreatorStatusEnabled)
	}
	var operationBytes [8]byte
	if _, err := rand.Read(operationBytes[:]); err != nil {
		t.Fatalf("rand operation id: %v", err)
	}
	nonce, err := store.IssueRootRegistrationNonce(context.Background(), trustpool.RootRegistrationNonceIssue{
		OperationID:            "op-nonce-" + base64.RawURLEncoding.EncodeToString(operationBytes[:]),
		CreatorAccountID:       creatorID,
		ApprovalRecordID:       approvalID,
		CurrentApprovalVersion: "approval-version-1",
		LaunchEnvironment:      environment,
		Purpose:                trustpool.RootRegistrationPurposeDefault,
		ExpiresAtUTC:           expiresAt,
	})
	if err != nil {
		t.Fatalf("IssueRootRegistrationNonce: %v", err)
	}
	return nonce
}

func approveCreator(t *testing.T, store *trustpool.Store, creatorID, approvalID, approvalVersion, environment string, graceEndsAt time.Time, status string) trustpool.CreatorApproval {
	t.Helper()
	approval, err := store.UpsertCreatorApproval(context.Background(), validCreatorApproval(creatorID, approvalID, approvalVersion, environment, graceEndsAt, status))
	if err != nil {
		t.Fatalf("UpsertCreatorApproval: %v", err)
	}
	return approval
}

func approvePublicAnnouncement(t *testing.T, store *trustpool.Store, poolID, manifestCoreDigest string) trustpool.PublicAnnouncementApproval {
	t.Helper()
	artifact := approveReviewedDistributionArtifact(t, store, poolID, manifestCoreDigest)
	var operationBytes [8]byte
	if _, err := rand.Read(operationBytes[:]); err != nil {
		t.Fatalf("rand public announcement operation id: %v", err)
	}
	approval, err := store.UpsertPublicAnnouncementApproval(context.Background(), trustpool.PublicAnnouncementApproval{
		OperationID:                "op-public-announcement-" + base64.RawURLEncoding.EncodeToString(operationBytes[:]),
		PoolID:                     poolID,
		ManifestCoreDigest:         manifestCoreDigest,
		ReviewedDistributionDigest: artifact.ReviewedDistributionDigest,
		ApprovalRecordID:           "public-announcement-v1",
		ApprovedBy:                 "operator-a",
		ApprovedAtUTC:              time.Unix(1800000100, 0).UTC(),
	})
	if err != nil {
		t.Fatalf("UpsertPublicAnnouncementApproval: %v", err)
	}
	return approval
}

func approveReviewedDistributionArtifact(t *testing.T, store *trustpool.Store, poolID, manifestCoreDigest string) trustpool.ReviewedDistributionArtifact {
	t.Helper()
	wantDigest := hexDigest("reviewed-distribution-" + poolID + "-" + manifestCoreDigest)
	if artifact, ok, err := store.ReviewedDistributionArtifact(context.Background(), poolID); err != nil {
		t.Fatalf("ReviewedDistributionArtifact: %v", err)
	} else if ok && artifact.ManifestCoreDigest == manifestCoreDigest && artifact.ReviewedDistributionDigest == wantDigest {
		return artifact
	}
	var operationBytes [8]byte
	if _, err := rand.Read(operationBytes[:]); err != nil {
		t.Fatalf("rand reviewed artifact operation id: %v", err)
	}
	artifact, err := store.UpsertReviewedDistributionArtifact(context.Background(), trustpool.ReviewedDistributionArtifact{
		OperationID:                "op-reviewed-artifact-" + base64.RawURLEncoding.EncodeToString(operationBytes[:]),
		PoolID:                     poolID,
		ManifestCoreDigest:         manifestCoreDigest,
		ReviewedDistributionDigest: wantDigest,
		ArtifactURI:                "https://example.test/trusted-pools/" + poolID,
		ClaimControlDigest:         hexDigest("claim-control-" + poolID + "-" + manifestCoreDigest),
		ReviewedBy:                 "operator-a",
		ReviewedAtUTC:              time.Unix(1800000050, 0).UTC(),
	})
	if err != nil {
		t.Fatalf("UpsertReviewedDistributionArtifact: %v", err)
	}
	return artifact
}

func validCreatorApproval(creatorID, approvalID, approvalVersion, environment string, graceEndsAt time.Time, status string) trustpool.CreatorApproval {
	return trustpool.CreatorApproval{
		CreatorAccountID:                  creatorID,
		ApprovalRecordID:                  approvalID,
		CurrentApprovalVersion:            approvalVersion,
		PublicDisplayName:                 "Creator " + creatorID,
		LegalSupportContact:               "legal@example.test",
		BillingContact:                    "billing@example.test",
		EmergencyNotificationEndpoint:     "https://example.test/emergency",
		AcknowledgedMaxResponseTime:       "15m",
		AllowedProductCategory:            "design-partner",
		DataRetentionCategory:             "standard",
		SupportOwner:                      "ops",
		AllowedLaunchEnvironment:          environment,
		CreatorAgreementID:                "agreement-" + approvalID,
		CreatorAgreementVersion:           "v1",
		CreatorAgreementExpiresAtUTC:      graceEndsAt.Add(-time.Hour),
		CreatorAgreementGraceEndsAtUTC:    graceEndsAt,
		PricingScheduleID:                 "pricing-" + approvalID,
		PricingScheduleVersion:            "v1",
		ProhibitedClaimAcknowledgmentHash: hexDigest("claims-" + creatorID),
		BuyerDisclosureCommitmentHash:     hexDigest("disclosure-" + creatorID),
		ApprovalCriteriaHash:              hexDigest("criteria-" + creatorID),
		ApprovedBy:                        "operator-a",
		ApprovedAtUTC:                     time.Unix(1800000000, 0).UTC(),
		Status:                            status,
		SuspensionReason:                  suspensionReasonForStatus(status),
	}
}

func suspensionReasonForStatus(status string) string {
	if status == trustpool.CreatorStatusSuspended {
		return "test_suspension"
	}
	return ""
}

func signP256ASN1(t *testing.T, key *ecdsa.PrivateKey, msg []byte) string {
	t.Helper()
	digest := sha256.Sum256(msg)
	sig, err := ecdsa.SignASN1(rand.Reader, key, digest[:])
	if err != nil {
		t.Fatalf("SignASN1: %v", err)
	}
	return base64.StdEncoding.EncodeToString(sig)
}

func hexDigest(v string) string {
	sum := sha256.Sum256([]byte(v))
	return strings.ToLower(hex.EncodeToString(sum[:]))
}

func hexBytesDigest(v []byte) string {
	sum := sha256.Sum256(v)
	return strings.ToLower(hex.EncodeToString(sum[:]))
}
