package poolmanifest

import (
	"crypto/ed25519"
	"encoding/binary"
	"encoding/hex"
	"errors"
	"reflect"
	"testing"
)

// GOLDEN — freeze the SPEC-042-R011 manifest-snapshot canonical encoding via the
// SHA-256 of the bytes for the fixture snapshot below. Any change to the codec
// breaks this on purpose.
const goldenSnapshotDigest = "1c6b31225a31abda1017302859b95a2c5ef36240871bfd7ef20a4f9f5392932e"

// genesisAuthLog returns the root key, the single genesis authority-log entry (signer
// set v1, keys k1,k2,k3 threshold 2, wide window), and the materialized log.
func genesisAuthLog(t *testing.T) (SignerKey, []AuthorityLogEntry, *AuthorityLog) {
	t.Helper()
	pid := testPoolID(t)
	root, rp := rootIssuerKey()
	k1, _ := seedKey(1)
	k2, _ := seedKey(2)
	k3, _ := seedKey(3)
	g := signEntry(t, AuthorityLogEntry{
		PoolID: pid, SignerSetVersion: 1, PrevAuthorityLogEntryHash: GenesisPrevHash(),
		Keys: []SignerKey{k1, k2, k3}, Threshold: 2, NotBeforeUnix: 0, ExpiresAtUnix: 100000,
		AuthorizingSignerSetVersion: 0,
	}, signer{"root-key-1", rp})
	entries := []AuthorityLogEntry{g}
	log, err := BuildAuthorityLog(sampleIdentity(), root, entries)
	if err != nil {
		t.Fatalf("authlog: %v", err)
	}
	return root, entries, log
}

// revokedV1AuthLog returns an authority log where signer set v1 is REVOKED by v2.
func revokedV1AuthLog(t *testing.T) (SignerKey, []AuthorityLogEntry, *AuthorityLog) {
	t.Helper()
	pid := testPoolID(t)
	root, rp := rootIssuerKey()
	k1, p1 := seedKey(1)
	k2, p2 := seedKey(2)
	k3, _ := seedKey(3)
	k4, _ := seedKey(4)
	k5, _ := seedKey(5)
	v1 := signEntry(t, AuthorityLogEntry{
		PoolID: pid, SignerSetVersion: 1, PrevAuthorityLogEntryHash: GenesisPrevHash(),
		Keys: []SignerKey{k1, k2, k3}, Threshold: 2, NotBeforeUnix: 0, ExpiresAtUnix: 100000,
		AuthorizingSignerSetVersion: 0,
	}, signer{"root-key-1", rp})
	h1 := must(v1.EntryHash())
	v2 := signEntry(t, AuthorityLogEntry{
		PoolID: pid, SignerSetVersion: 2, PrevAuthorityLogEntryHash: h1,
		Keys: []SignerKey{k4, k5}, Threshold: 2, NotBeforeUnix: 0, ExpiresAtUnix: 100000,
		RevokesVersions: []uint64{1}, AuthorizingSignerSetVersion: 1,
	}, signer{"k1", p1}, signer{"k2", p2})
	entries := []AuthorityLogEntry{v1, v2}
	log, err := BuildAuthorityLog(sampleIdentity(), root, entries)
	if err != nil {
		t.Fatalf("authlog: %v", err)
	}
	return root, entries, log
}

// fixtureSnapshot builds a snapshot with the genesis authority log and three chained
// accepted policy records (windows [1000,2000),[2000,3000),[4000,5000)).
func fixtureSnapshot(t *testing.T) ManifestSnapshot {
	t.Helper()
	root, entries, _ := genesisAuthLog(t)
	v1 := policyCore(t, 1, GenesisPrevHash(), 1000, 2000)
	d1 := must(v1.ManifestCoreDigest())
	v2 := policyCore(t, 2, d1, 2000, 3000)
	d2 := must(v2.ManifestCoreDigest())
	v3 := policyCore(t, 3, d2, 4000, 5000)
	return ManifestSnapshot{
		IdentityCore:  sampleIdentity(),
		RootIssuerKey: root,
		AuthorityLog:  entries,
		Policies: []AcceptedPolicyRecord{
			{SignedCore: signPolicy2of3(t, v1), AcceptedAtUnix: 1500},
			{SignedCore: signPolicy2of3(t, v2), AcceptedAtUnix: 2500},
			{SignedCore: signPolicy2of3(t, v3), AcceptedAtUnix: 4500},
		},
	}
}

func TestManifestSnapshotRoundTrip(t *testing.T) {
	snap := fixtureSnapshot(t)
	b, err := snap.CanonicalBytes()
	if err != nil {
		t.Fatalf("CanonicalBytes: %v", err)
	}
	// Determinism: a second encode is byte-identical.
	b2, _ := snap.CanonicalBytes()
	if string(b) != string(b2) {
		t.Fatal("CanonicalBytes is not deterministic")
	}
	got, err := ParseManifestSnapshot(b)
	if err != nil {
		t.Fatalf("ParseManifestSnapshot: %v", err)
	}
	if !reflect.DeepEqual(got, snap) {
		t.Fatalf("round-trip mismatch:\n got=%#v\nwant=%#v", got, snap)
	}
}

func TestManifestSnapshotGoldenDigest(t *testing.T) {
	dig, err := fixtureSnapshot(t).SnapshotDigest()
	if err != nil {
		t.Fatalf("SnapshotDigest: %v", err)
	}
	if got := hex.EncodeToString(dig); got != goldenSnapshotDigest {
		t.Fatalf("snapshot digest=%s want %s", got, goldenSnapshotDigest)
	}
}

func TestParseManifestSnapshotStrict(t *testing.T) {
	b := must(fixtureSnapshot(t).CanonicalBytes())
	// Truncated.
	if _, err := ParseManifestSnapshot(b[:len(b)-1]); !errors.Is(err, errSnapshotTruncated) {
		t.Fatalf("want errSnapshotTruncated, got %v", err)
	}
	// Trailing bytes.
	if _, err := ParseManifestSnapshot(append(append([]byte(nil), b...), 0x00)); !errors.Is(err, errSnapshotTrailing) {
		t.Fatalf("want errSnapshotTrailing, got %v", err)
	}
	// Bad domain tag.
	bad := append([]byte(nil), b...)
	bad[0] ^= 0xff
	if _, err := ParseManifestSnapshot(bad); !errors.Is(err, errSnapshotTag) {
		t.Fatalf("want errSnapshotTag, got %v", err)
	}
	// Empty input.
	if _, err := ParseManifestSnapshot(nil); err == nil {
		t.Fatal("empty input accepted")
	}
}

func TestDecoderRejectsMalformedPrimitives(t *testing.T) {
	// A boolean byte other than 0x00/0x01 is rejected.
	d := &decoder{buf: []byte{0x02}}
	d.boolean()
	if d.err == nil {
		t.Fatal("invalid boolean byte accepted")
	}
	// A list count above the cap is rejected before any allocation.
	over := make([]byte, 4)
	binary.BigEndian.PutUint32(over, maxSnapshotElements+1)
	d = &decoder{buf: over}
	if d.count(); !errors.Is(d.err, errSnapshotTooLarge) {
		t.Fatalf("want errSnapshotTooLarge, got %v", d.err)
	}
	// A count that cannot fit even one byte per element in the buffer is rejected.
	small := make([]byte, 4)
	binary.BigEndian.PutUint32(small, 1000)
	d = &decoder{buf: small}
	if d.count(); !errors.Is(d.err, errSnapshotTruncated) {
		t.Fatalf("want errSnapshotTruncated, got %v", d.err)
	}
}

// TestSnapshotEmptySliceCanonicalization documents that count-zero lists decode to
// nil (empty and nil slices are canonically identical in a snapshot).
func TestSnapshotEmptySliceCanonicalization(t *testing.T) {
	snap := ManifestSnapshot{
		IdentityCore:  sampleIdentity(),
		RootIssuerKey: SignerKey{KeyID: "root-key-1", PublicKey: make([]byte, ed25519.PublicKeySize)},
		AuthorityLog:  []AuthorityLogEntry{}, // empty, non-nil
		Policies:      []AcceptedPolicyRecord{},
	}
	got, err := ParseManifestSnapshot(must(snap.CanonicalBytes()))
	if err != nil {
		t.Fatalf("parse: %v", err)
	}
	if got.AuthorityLog != nil || got.Policies != nil {
		t.Fatalf("empty slices did not canonicalize to nil: authlog=%v policies=%v", got.AuthorityLog, got.Policies)
	}
}

// TestSnapshotDecodeNoAliasing proves decoded byte fields are copies, not views into
// the input buffer.
func TestSnapshotDecodeNoAliasing(t *testing.T) {
	b := must(fixtureSnapshot(t).CanonicalBytes())
	got, err := ParseManifestSnapshot(b)
	if err != nil {
		t.Fatalf("parse: %v", err)
	}
	nonceBefore := append([]byte(nil), got.IdentityCore.GenesisNonce...)
	for i := range b { // scribble over the whole input buffer
		b[i] ^= 0xff
	}
	if !bytesEqual(got.IdentityCore.GenesisNonce, nonceBefore) {
		t.Fatal("decoded GenesisNonce aliased the input buffer")
	}
}

func bytesEqual(a, b []byte) bool {
	if len(a) != len(b) {
		return false
	}
	for i := range a {
		if a[i] != b[i] {
			return false
		}
	}
	return true
}

func TestReconstructMatchesOnline(t *testing.T) {
	root, entries, authLog := genesisAuthLog(t)
	v1 := policyCore(t, 1, GenesisPrevHash(), 1000, 2000)
	d1 := must(v1.ManifestCoreDigest())
	v2 := policyCore(t, 2, d1, 2000, 3000)
	online, err := BuildPolicyHistory(sampleIdentity(), authLog, []SignedPolicyCore{
		signPolicy2of3(t, v1), signPolicy2of3(t, v2),
	})
	if err != nil {
		t.Fatalf("online build: %v", err)
	}
	snap := ManifestSnapshot{
		IdentityCore: sampleIdentity(), RootIssuerKey: root, AuthorityLog: entries,
		Policies: []AcceptedPolicyRecord{
			{SignedCore: signPolicy2of3(t, v1), AcceptedAtUnix: 1500},
			{SignedCore: signPolicy2of3(t, v2), AcceptedAtUnix: 2500},
		},
	}
	rp, err := ReconstructPool(snap)
	if err != nil {
		t.Fatalf("ReconstructPool: %v", err)
	}
	for _, now := range []uint64{1500, 2000, 2999} {
		o, oerr := online.ActivePolicy(now)
		r, rerr := rp.PolicyHistory.ActivePolicy(now)
		if oerr != nil || rerr != nil || o.ManifestVersion != r.ManifestVersion {
			t.Fatalf("now=%d online=v%d(%v) reconstructed=v%d(%v)", now, o.ManifestVersion, oerr, r.ManifestVersion, rerr)
		}
	}
	if rp.AuthorityLog.CurrentVersion() != 1 {
		t.Fatalf("reconstructed authlog current version=%d want 1", rp.AuthorityLog.CurrentVersion())
	}
}

// TestReconstructGrandfathersRevokedSigner is the load-bearing vector: a policy
// accepted under signer set v1 (now revoked by v2) is REJECTED by the online build
// but ACCEPTED on reconstruction, and is returned by ActivePolicy in its window.
func TestReconstructGrandfathersRevokedSigner(t *testing.T) {
	root, entries, authLog := revokedV1AuthLog(t)
	// Policy signed under signer set v1 (which is now revoked).
	pol := policyCore(t, 1, GenesisPrevHash(), 1000, 2000) // SignerSetVersion 1
	signed := signPolicy2of3(t, pol)                       // signed by k1,k2 (v1 members)

	// Online build rejects it: v1 is revoked.
	if _, err := BuildPolicyHistory(sampleIdentity(), authLog, []SignedPolicyCore{signed}); !errors.Is(err, errSignerSetRevoked) {
		t.Fatalf("online build should reject revoked-signer policy, got %v", err)
	}

	// Reconstruction from the recorded verdict accepts it (grandfathered).
	snap := ManifestSnapshot{
		IdentityCore: sampleIdentity(), RootIssuerKey: root, AuthorityLog: entries,
		Policies: []AcceptedPolicyRecord{{SignedCore: signed, AcceptedAtUnix: 1500}},
	}
	rp, err := ReconstructPool(snap)
	if err != nil {
		t.Fatalf("ReconstructPool should grandfather the recorded verdict, got %v", err)
	}
	got, err := rp.PolicyHistory.ActivePolicy(1500)
	if err != nil || got.ManifestVersion != 1 {
		t.Fatalf("grandfathered policy not active: v%d err=%v", got.ManifestVersion, err)
	}
	// The authority log still reflects v1 as revoked (reconstruction did not alter it).
	if ss, ok := rp.AuthorityLog.SignerSet(1); !ok || !ss.Revoked {
		t.Fatalf("v1 should be present and revoked in the reconstructed log")
	}
}

// TestReconstructCorruptionCaught proves the timeless signature re-verification still
// runs: a recorded policy whose signature is tampered is rejected on reconstruction.
func TestReconstructCorruptionCaught(t *testing.T) {
	root, entries, _ := genesisAuthLog(t)
	pol := policyCore(t, 1, GenesisPrevHash(), 1000, 2000)
	signed := signPolicy2of3(t, pol)
	signed.Signatures[0].Sig[0] ^= 0xff // corrupt one signature
	snap := ManifestSnapshot{
		IdentityCore: sampleIdentity(), RootIssuerKey: root, AuthorityLog: entries,
		Policies: []AcceptedPolicyRecord{{SignedCore: signed, AcceptedAtUnix: 1500}},
	}
	if _, err := ReconstructPool(snap); !errors.Is(err, errBadSignature) {
		t.Fatalf("corrupted signature should be caught on reconstruction, got %v", err)
	}
}

// TestReconstructRejectsTamperedAuthorityLog proves the authority log is fully
// re-verified: a tampered entry (broken chain) fails reconstruction.
func TestReconstructRejectsTamperedAuthorityLog(t *testing.T) {
	root, entries, _ := revokedV1AuthLog(t)
	entries[1].PrevAuthorityLogEntryHash = make([]byte, 32) // break the chain
	snap := ManifestSnapshot{
		IdentityCore: sampleIdentity(), RootIssuerKey: root, AuthorityLog: entries,
		Policies: nil,
	}
	if _, err := ReconstructPool(snap); !errors.Is(err, errAuthChainBroken) {
		t.Fatalf("tampered authority log should fail reconstruction, got %v", err)
	}
}
