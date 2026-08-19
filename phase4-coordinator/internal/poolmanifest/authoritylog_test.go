package poolmanifest

import (
	"crypto/ed25519"
	"encoding/hex"
	"errors"
	"testing"
)

// GOLDEN VECTORS — freeze the SPEC-042-R012 authority-log-entry content encoding,
// entry hashes, and signing preimage for the fixed genesis -> rotate -> revoke
// chain built below (bound to the sampleIdentity pool_id). Any change to the
// grammar breaks these on purpose.
const (
	goldenGenesisContentHex = "6d616370726f76696465722f737065633034322f617574686f726974792d6c6f672d656e7472792f763100000016696a556e632d5a51662d4c4a6552766b68692d306951000000000000000100000020000000000000000000000000000000000000000000000000000000000000000000000003000000026b31000000208a88e3dd7409f195fd52db2d3cba5d72ca6709bf1d94121bf3748801b40f6f5c000000026b32000000208139770ea87d175f56a35466c34c7ecccb8d8a91b4ee37a25df60f5b8fc9b394000000026b3300000020ed4928c628d1c2c6eae90338905995612959273a5c63f93636c14614ac8737d1000000000000000200000000000003e80000000000002328000000000000000000000000"
	goldenAuthHashV1        = "779b25a1c997957e0bd2a4efcb1a67b7ac6d271c2157911e527c292d3a76736e"
	goldenAuthSigMsgV1      = "6d616370726f76696465722f737065633034322f617574686f726974792d6c6f672d656e7472792d7369672f7631779b25a1c997957e0bd2a4efcb1a67b7ac6d271c2157911e527c292d3a76736e"
	goldenAuthHashV2        = "61b1372a2066d033eff405e22d600eaaf13193cb2dce87bdf76168f143ca19d5"
	goldenAuthHashV3        = "372c5b5afe9926d356f465b13419ebc80dc52b9cfbbea504ae40498c6e4579ec"
)

type signer struct {
	keyID string
	priv  ed25519.PrivateKey
}

// rootIssuerKey returns a fixed root-issuer SignerKey whose id matches the
// sampleIdentity root_issuer_key_id ("root-key-1") so it binds the pool identity.
func rootIssuerKey() (SignerKey, ed25519.PrivateKey) {
	seed := make([]byte, ed25519.SeedSize)
	for i := range seed {
		seed[i] = 100
	}
	priv := ed25519.NewKeyFromSeed(seed)
	return SignerKey{KeyID: "root-key-1", PublicKey: priv.Public().(ed25519.PublicKey)}, priv
}

func testPoolID(t *testing.T) string {
	t.Helper()
	pid, err := sampleIdentity().PoolID()
	if err != nil {
		t.Fatalf("PoolID: %v", err)
	}
	return pid
}

// signEntry returns a copy of e with Signatures set to the given signers' detached
// signatures over the entry's signing message.
func signEntry(t *testing.T, e AuthorityLogEntry, signers ...signer) AuthorityLogEntry {
	t.Helper()
	h, err := e.EntryHash()
	if err != nil {
		t.Fatalf("EntryHash: %v", err)
	}
	msg, err := AuthorityLogEntrySigningMessage(h)
	if err != nil {
		t.Fatalf("sig message: %v", err)
	}
	sigs := make([]Signature, 0, len(signers))
	for _, s := range signers {
		sigs = append(sigs, Signature{KeyID: s.keyID, Sig: ed25519.Sign(s.priv, msg)})
	}
	e.Signatures = sigs
	return e
}

// fixtureChain builds the canonical valid genesis->rotate->revoke chain (bound to
// the sampleIdentity pool) and returns the root issuer key plus the signed entries.
func fixtureChain(t *testing.T) (SignerKey, []AuthorityLogEntry) {
	t.Helper()
	pid := testPoolID(t)
	root, rp := rootIssuerKey()
	k1, p1 := seedKey(1)
	k2, p2 := seedKey(2)
	k3, _ := seedKey(3)
	k4, p4 := seedKey(4)
	k5, p5 := seedKey(5)
	k6, _ := seedKey(6)
	k7, _ := seedKey(7)
	k8, _ := seedKey(8)

	v1 := signEntry(t, AuthorityLogEntry{
		PoolID: pid, SignerSetVersion: 1, PrevAuthorityLogEntryHash: GenesisPrevHash(),
		Keys: []SignerKey{k1, k2, k3}, Threshold: 2, NotBeforeUnix: 1000, ExpiresAtUnix: 9000,
		AuthorizingSignerSetVersion: 0,
	}, signer{"root-key-1", rp})
	h1 := must(v1.EntryHash())

	v2 := signEntry(t, AuthorityLogEntry{
		PoolID: pid, SignerSetVersion: 2, PrevAuthorityLogEntryHash: h1,
		Keys: []SignerKey{k4, k5}, Threshold: 2, NotBeforeUnix: 1000, ExpiresAtUnix: 9000,
		AuthorizingSignerSetVersion: 1,
	}, signer{"k1", p1}, signer{"k2", p2})
	h2 := must(v2.EntryHash())

	v3 := signEntry(t, AuthorityLogEntry{
		PoolID: pid, SignerSetVersion: 3, PrevAuthorityLogEntryHash: h2,
		Keys: []SignerKey{k6, k7, k8}, Threshold: 2, NotBeforeUnix: 1000, ExpiresAtUnix: 9000,
		RevokesVersions: []uint64{2}, AuthorizingSignerSetVersion: 2,
	}, signer{"k4", p4}, signer{"k5", p5})

	return root, []AuthorityLogEntry{v1, v2, v3}
}

func TestAuthorityLogEntryGoldenVectors(t *testing.T) {
	_, entries := fixtureChain(t)
	v1 := entries[0]
	if got := hex.EncodeToString(must(v1.CanonicalContentBytes())); got != goldenGenesisContentHex {
		t.Fatalf("genesis content drifted:\n got=%s\nwant=%s", got, goldenGenesisContentHex)
	}
	if got := hex.EncodeToString(must(v1.EntryHash())); got != goldenAuthHashV1 {
		t.Fatalf("v1 hash=%s want %s", got, goldenAuthHashV1)
	}
	if got := hex.EncodeToString(must(entries[1].EntryHash())); got != goldenAuthHashV2 {
		t.Fatalf("v2 hash=%s want %s", got, goldenAuthHashV2)
	}
	if got := hex.EncodeToString(must(entries[2].EntryHash())); got != goldenAuthHashV3 {
		t.Fatalf("v3 hash=%s want %s", got, goldenAuthHashV3)
	}
	msg := must(AuthorityLogEntrySigningMessage(must(v1.EntryHash())))
	if got := hex.EncodeToString(msg); got != goldenAuthSigMsgV1 {
		t.Fatalf("v1 sig message=%s want %s", got, goldenAuthSigMsgV1)
	}
	if _, err := AuthorityLogEntrySigningMessage([]byte{0x00}); !errors.Is(err, errAuthEntryHashLen) {
		t.Fatalf("want errAuthEntryHashLen for short hash, got %v", err)
	}
}

func TestBuildAuthorityLogReplay(t *testing.T) {
	root, entries := fixtureChain(t)
	log, err := BuildAuthorityLog(sampleIdentity(), root, entries)
	if err != nil {
		t.Fatalf("BuildAuthorityLog: %v", err)
	}
	if log.CurrentVersion() != 3 {
		t.Fatalf("current version=%d want 3", log.CurrentVersion())
	}
	if got := hex.EncodeToString(log.HeadHash()); got != goldenAuthHashV3 {
		t.Fatalf("head hash=%s want %s", got, goldenAuthHashV3)
	}
	v1, ok := log.SignerSet(1)
	if !ok || v1.Revoked {
		t.Fatalf("v1 present=%v revoked=%v, want present & not revoked", ok, v1.Revoked)
	}
	v2, ok := log.SignerSet(2)
	if !ok || !v2.Revoked {
		t.Fatalf("v2 present=%v revoked=%v, want present & revoked", ok, v2.Revoked)
	}
	v3, ok := log.SignerSet(3)
	if !ok || v3.Revoked {
		t.Fatalf("v3 present=%v revoked=%v, want present & not revoked", ok, v3.Revoked)
	}
	if _, ok := log.SignerSet(99); ok {
		t.Fatal("nonexistent version reported present")
	}
}

// TestAuthorityLogMaterializedSetsAreImmutable proves the log's signer material
// cannot be mutated through the caller's entries nor through a returned lookup.
func TestAuthorityLogMaterializedSetsAreImmutable(t *testing.T) {
	root, entries := fixtureChain(t)
	log, err := BuildAuthorityLog(sampleIdentity(), root, entries)
	if err != nil {
		t.Fatalf("BuildAuthorityLog: %v", err)
	}
	// Mutating the caller's original entry key bytes must not change the log.
	entries[0].Keys[0].PublicKey[0] ^= 0xff
	got, _ := log.SignerSet(1)
	orig, _ := seedKey(1)
	found := false
	for _, k := range got.Keys {
		if k.KeyID == orig.KeyID {
			found = true
			if k.PublicKey[0] != orig.PublicKey[0] {
				t.Fatal("log signer key mutated through caller's entry slice")
			}
		}
	}
	if !found {
		t.Fatal("expected key not present in materialized set")
	}
	// Mutating a returned SignerSet must not affect a later lookup.
	got.Keys[0].PublicKey[0] ^= 0xff
	again, _ := log.SignerSet(1)
	if again.Keys[0].PublicKey[0] == got.Keys[0].PublicKey[0] {
		t.Fatal("mutation of a returned signer set leaked into the log")
	}
}

// TestAuthorityLogFeedsPolicyVerification closes the loop with slice 2: a policy
// core signed under an active materialized set verifies, and one under the revoked
// set is rejected as revoked.
func TestAuthorityLogFeedsPolicyVerification(t *testing.T) {
	root, entries := fixtureChain(t)
	log, err := BuildAuthorityLog(sampleIdentity(), root, entries)
	if err != nil {
		t.Fatalf("BuildAuthorityLog: %v", err)
	}
	pid, _ := sampleIdentity().PoolID()
	_, p1 := seedKey(1)
	_, p2 := seedKey(2)

	core := samplePolicy(pid)
	core.SignerSetVersion = 1
	core.NotBeforeUnix = 1000
	core.ExpiresAtUnix = 2000
	dig := must(core.ManifestCoreDigest())
	msg := must(PolicyCoreSigningMessage(dig))
	sigs := []Signature{{KeyID: "k1", Sig: ed25519.Sign(p1, msg)}, {KeyID: "k2", Sig: ed25519.Sign(p2, msg)}}
	ssV1, _ := log.SignerSet(1)
	if err := VerifyPolicyCore(core, sigs, ssV1); err != nil {
		t.Fatalf("policy under active v1 rejected: %v", err)
	}

	_, p4 := seedKey(4)
	_, p5 := seedKey(5)
	core2 := core
	core2.SignerSetVersion = 2
	dig2 := must(core2.ManifestCoreDigest())
	msg2 := must(PolicyCoreSigningMessage(dig2))
	sigs2 := []Signature{{KeyID: "k4", Sig: ed25519.Sign(p4, msg2)}, {KeyID: "k5", Sig: ed25519.Sign(p5, msg2)}}
	ssV2, _ := log.SignerSet(2)
	if err := VerifyPolicyCore(core2, sigs2, ssV2); !errors.Is(err, errSignerSetRevoked) {
		t.Fatalf("policy under revoked v2 not rejected as revoked: %v", err)
	}
}

// TestSignatureDomainSeparation freezes the guarantee that a policy-core signature
// cannot be replayed as an authority-log-entry signature or vice versa, even when
// the two structures hash to the same 32 bytes.
func TestSignatureDomainSeparation(t *testing.T) {
	_, p1 := seedKey(1)
	// A shared 32-byte digest fed to both signing-message builders.
	digest := make([]byte, 32)
	for i := range digest {
		digest[i] = byte(i)
	}
	polMsg := must(PolicyCoreSigningMessage(digest))
	authMsg := must(AuthorityLogEntrySigningMessage(digest))
	if string(polMsg) == string(authMsg) {
		t.Fatal("policy-core and authority-log signing messages are identical")
	}
	// A signature over the policy-core message must NOT verify over the
	// authority-log message and vice versa.
	pub := p1.Public().(ed25519.PublicKey)
	polSig := ed25519.Sign(p1, polMsg)
	authSig := ed25519.Sign(p1, authMsg)
	if ed25519.Verify(pub, authMsg, polSig) {
		t.Fatal("policy-core signature verified as an authority-log signature")
	}
	if ed25519.Verify(pub, polMsg, authSig) {
		t.Fatal("authority-log signature verified as a policy-core signature")
	}
}

func TestBuildAuthorityLogRejects(t *testing.T) {
	pid := testPoolID(t)
	root, rp := rootIssuerKey()
	ic := sampleIdentity()
	k1, p1 := seedKey(1)
	k2, p2 := seedKey(2)
	k3, _ := seedKey(3)
	k4, p4 := seedKey(4)
	k5, p5 := seedKey(5)
	_, wrongPriv := seedKey(9)

	genesis := func() AuthorityLogEntry {
		return signEntry(t, AuthorityLogEntry{
			PoolID: pid, SignerSetVersion: 1, PrevAuthorityLogEntryHash: GenesisPrevHash(),
			Keys: []SignerKey{k1, k2, k3}, Threshold: 2, NotBeforeUnix: 1000, ExpiresAtUnix: 9000,
			AuthorizingSignerSetVersion: 0,
		}, signer{"root-key-1", rp})
	}

	t.Run("empty log", func(t *testing.T) {
		if _, err := BuildAuthorityLog(ic, root, nil); !errors.Is(err, errAuthEmpty) {
			t.Fatalf("want errAuthEmpty, got %v", err)
		}
	})

	t.Run("malformed root key", func(t *testing.T) {
		bad := SignerKey{KeyID: "root-key-1", PublicKey: []byte{0x00}}
		if _, err := BuildAuthorityLog(ic, bad, []AuthorityLogEntry{genesis()}); !errors.Is(err, errAuthRootKey) {
			t.Fatalf("want errAuthRootKey, got %v", err)
		}
	})

	t.Run("root key does not bind identity core", func(t *testing.T) {
		other := SignerKey{KeyID: "not-the-root", PublicKey: root.PublicKey}
		if _, err := BuildAuthorityLog(ic, other, []AuthorityLogEntry{genesis()}); !errors.Is(err, errAuthRootMismatch) {
			t.Fatalf("want errAuthRootMismatch, got %v", err)
		}
	})

	t.Run("entry pool_id mismatch", func(t *testing.T) {
		e := signEntry(t, AuthorityLogEntry{
			PoolID: "some-other-pool-idxxxx", SignerSetVersion: 1, PrevAuthorityLogEntryHash: GenesisPrevHash(),
			Keys: []SignerKey{k1, k2, k3}, Threshold: 2, NotBeforeUnix: 1000, ExpiresAtUnix: 9000,
		}, signer{"root-key-1", rp})
		if _, err := BuildAuthorityLog(ic, root, []AuthorityLogEntry{e}); !errors.Is(err, errAuthPoolID) {
			t.Fatalf("want errAuthPoolID, got %v", err)
		}
	})

	t.Run("signer set version zero", func(t *testing.T) {
		e := signEntry(t, AuthorityLogEntry{
			PoolID: pid, SignerSetVersion: 0, PrevAuthorityLogEntryHash: GenesisPrevHash(),
			Keys: []SignerKey{k1, k2, k3}, Threshold: 2, NotBeforeUnix: 1000, ExpiresAtUnix: 9000,
		}, signer{"root-key-1", rp})
		if _, err := BuildAuthorityLog(ic, root, []AuthorityLogEntry{e}); !errors.Is(err, errSignerSetVersionZero) {
			t.Fatalf("want errSignerSetVersionZero, got %v", err)
		}
	})

	t.Run("genesis prev not zero", func(t *testing.T) {
		e := AuthorityLogEntry{
			PoolID: pid, SignerSetVersion: 1, PrevAuthorityLogEntryHash: must(genesis().EntryHash()),
			Keys: []SignerKey{k1, k2, k3}, Threshold: 2, NotBeforeUnix: 1000, ExpiresAtUnix: 9000,
		}
		e = signEntry(t, e, signer{"root-key-1", rp})
		if _, err := BuildAuthorityLog(ic, root, []AuthorityLogEntry{e}); !errors.Is(err, errAuthGenesisPrev) {
			t.Fatalf("want errAuthGenesisPrev, got %v", err)
		}
	})

	t.Run("genesis bad root sig", func(t *testing.T) {
		e := AuthorityLogEntry{
			PoolID: pid, SignerSetVersion: 1, PrevAuthorityLogEntryHash: GenesisPrevHash(),
			Keys: []SignerKey{k1, k2, k3}, Threshold: 2, NotBeforeUnix: 1000, ExpiresAtUnix: 9000,
		}
		e = signEntry(t, e, signer{"root-key-1", wrongPriv})
		if _, err := BuildAuthorityLog(ic, root, []AuthorityLogEntry{e}); !errors.Is(err, errAuthRootSig) {
			t.Fatalf("want errAuthRootSig, got %v", err)
		}
	})

	t.Run("rollback non-monotonic version", func(t *testing.T) {
		g := genesis()
		h1 := must(g.EntryHash())
		e2 := signEntry(t, AuthorityLogEntry{
			PoolID: pid, SignerSetVersion: 1, PrevAuthorityLogEntryHash: h1,
			Keys: []SignerKey{k4, k5}, Threshold: 2, NotBeforeUnix: 1000, ExpiresAtUnix: 9000,
			AuthorizingSignerSetVersion: 1,
		}, signer{"k1", p1}, signer{"k2", p2})
		if _, err := BuildAuthorityLog(ic, root, []AuthorityLogEntry{g, e2}); !errors.Is(err, errAuthRollback) {
			t.Fatalf("want errAuthRollback, got %v", err)
		}
	})

	t.Run("chain broken", func(t *testing.T) {
		g := genesis()
		e2 := signEntry(t, AuthorityLogEntry{
			PoolID: pid, SignerSetVersion: 2, PrevAuthorityLogEntryHash: make([]byte, 32),
			Keys: []SignerKey{k4, k5}, Threshold: 2, NotBeforeUnix: 1000, ExpiresAtUnix: 9000,
			AuthorizingSignerSetVersion: 1,
		}, signer{"k1", p1}, signer{"k2", p2})
		if _, err := BuildAuthorityLog(ic, root, []AuthorityLogEntry{g, e2}); !errors.Is(err, errAuthChainBroken) {
			t.Fatalf("want errAuthChainBroken, got %v", err)
		}
	})

	t.Run("threshold exceeds N", func(t *testing.T) {
		e := signEntry(t, AuthorityLogEntry{
			PoolID: pid, SignerSetVersion: 1, PrevAuthorityLogEntryHash: GenesisPrevHash(),
			Keys: []SignerKey{k1, k2}, Threshold: 3, NotBeforeUnix: 1000, ExpiresAtUnix: 9000,
		}, signer{"root-key-1", rp})
		if _, err := BuildAuthorityLog(ic, root, []AuthorityLogEntry{e}); !errors.Is(err, errThresholdRange) {
			t.Fatalf("want errThresholdRange, got %v", err)
		}
	})

	t.Run("duplicate public key in entry", func(t *testing.T) {
		twin := SignerKey{KeyID: "k1-twin", PublicKey: k1.PublicKey}
		e := AuthorityLogEntry{
			PoolID: pid, SignerSetVersion: 1, PrevAuthorityLogEntryHash: GenesisPrevHash(),
			Keys: []SignerKey{k1, twin}, Threshold: 2, NotBeforeUnix: 1000, ExpiresAtUnix: 9000,
		}
		if _, err := BuildAuthorityLog(ic, root, []AuthorityLogEntry{e}); !errors.Is(err, errSignerKeyDup) {
			t.Fatalf("want errSignerKeyDup, got %v", err)
		}
	})

	t.Run("authorized by revoked set", func(t *testing.T) {
		g := genesis()
		h1 := must(g.EntryHash())
		e2 := signEntry(t, AuthorityLogEntry{
			PoolID: pid, SignerSetVersion: 2, PrevAuthorityLogEntryHash: h1,
			Keys: []SignerKey{k4, k5}, Threshold: 2, NotBeforeUnix: 1000, ExpiresAtUnix: 9000,
			RevokesVersions: []uint64{1}, AuthorizingSignerSetVersion: 1,
		}, signer{"k1", p1}, signer{"k2", p2})
		h2 := must(e2.EntryHash())
		e3 := signEntry(t, AuthorityLogEntry{
			PoolID: pid, SignerSetVersion: 3, PrevAuthorityLogEntryHash: h2,
			Keys: []SignerKey{k2, k3}, Threshold: 2, NotBeforeUnix: 1000, ExpiresAtUnix: 9000,
			AuthorizingSignerSetVersion: 1,
		}, signer{"k1", p1}, signer{"k2", p2})
		if _, err := BuildAuthorityLog(ic, root, []AuthorityLogEntry{g, e2, e3}); !errors.Is(err, errAuthByRevokedSet) {
			t.Fatalf("want errAuthByRevokedSet, got %v", err)
		}
	})

	t.Run("self/forward authorize", func(t *testing.T) {
		g := genesis()
		h1 := must(g.EntryHash())
		e2 := signEntry(t, AuthorityLogEntry{
			PoolID: pid, SignerSetVersion: 2, PrevAuthorityLogEntryHash: h1,
			Keys: []SignerKey{k4, k5}, Threshold: 2, NotBeforeUnix: 1000, ExpiresAtUnix: 9000,
			AuthorizingSignerSetVersion: 2,
		}, signer{"k4", p4}, signer{"k5", p5})
		if _, err := BuildAuthorityLog(ic, root, []AuthorityLogEntry{g, e2}); !errors.Is(err, errAuthSelfAuthorize) {
			t.Fatalf("want errAuthSelfAuthorize, got %v", err)
		}
	})

	t.Run("unknown authorizing version", func(t *testing.T) {
		g := genesis()
		h1 := must(g.EntryHash())
		e2 := signEntry(t, AuthorityLogEntry{
			PoolID: pid, SignerSetVersion: 3, PrevAuthorityLogEntryHash: h1,
			Keys: []SignerKey{k4, k5}, Threshold: 2, NotBeforeUnix: 1000, ExpiresAtUnix: 9000,
			AuthorizingSignerSetVersion: 2,
		}, signer{"k1", p1}, signer{"k2", p2})
		if _, err := BuildAuthorityLog(ic, root, []AuthorityLogEntry{g, e2}); !errors.Is(err, errAuthUnknownAuth) {
			t.Fatalf("want errAuthUnknownAuth, got %v", err)
		}
	})

	t.Run("revoke self or future version", func(t *testing.T) {
		g := genesis()
		h1 := must(g.EntryHash())
		e2 := signEntry(t, AuthorityLogEntry{
			PoolID: pid, SignerSetVersion: 2, PrevAuthorityLogEntryHash: h1,
			Keys: []SignerKey{k4, k5}, Threshold: 2, NotBeforeUnix: 1000, ExpiresAtUnix: 9000,
			RevokesVersions: []uint64{2}, AuthorizingSignerSetVersion: 1,
		}, signer{"k1", p1}, signer{"k2", p2})
		if _, err := BuildAuthorityLog(ic, root, []AuthorityLogEntry{g, e2}); !errors.Is(err, errAuthRevokesTarget) {
			t.Fatalf("want errAuthRevokesTarget, got %v", err)
		}
	})

	t.Run("revokes not ascending/distinct", func(t *testing.T) {
		g := genesis()
		h1 := must(g.EntryHash())
		e2 := AuthorityLogEntry{
			PoolID: pid, SignerSetVersion: 2, PrevAuthorityLogEntryHash: h1,
			Keys: []SignerKey{k4, k5}, Threshold: 2, NotBeforeUnix: 1000, ExpiresAtUnix: 9000,
			RevokesVersions: []uint64{1, 1}, AuthorizingSignerSetVersion: 1,
		}
		if _, err := BuildAuthorityLog(ic, root, []AuthorityLogEntry{g, e2}); !errors.Is(err, errAuthRevokesOrder) {
			t.Fatalf("want errAuthRevokesOrder, got %v", err)
		}
	})

	t.Run("authorizing set window excludes not_before", func(t *testing.T) {
		g := genesis() // v1 window [1000,9000)
		h1 := must(g.EntryHash())
		e2 := signEntry(t, AuthorityLogEntry{
			PoolID: pid, SignerSetVersion: 2, PrevAuthorityLogEntryHash: h1,
			Keys: []SignerKey{k4, k5}, Threshold: 2, NotBeforeUnix: 500, ExpiresAtUnix: 9000,
			AuthorizingSignerSetVersion: 1,
		}, signer{"k1", p1}, signer{"k2", p2})
		if _, err := BuildAuthorityLog(ic, root, []AuthorityLogEntry{g, e2}); !errors.Is(err, errAuthSetInactive) {
			t.Fatalf("want errAuthSetInactive, got %v", err)
		}
	})

	t.Run("below threshold authorization", func(t *testing.T) {
		g := genesis()
		h1 := must(g.EntryHash())
		e2 := signEntry(t, AuthorityLogEntry{
			PoolID: pid, SignerSetVersion: 2, PrevAuthorityLogEntryHash: h1,
			Keys: []SignerKey{k4, k5}, Threshold: 2, NotBeforeUnix: 1000, ExpiresAtUnix: 9000,
			AuthorizingSignerSetVersion: 1,
		}, signer{"k1", p1})
		if _, err := BuildAuthorityLog(ic, root, []AuthorityLogEntry{g, e2}); !errors.Is(err, errThresholdNotMet) {
			t.Fatalf("want errThresholdNotMet, got %v", err)
		}
	})

	t.Run("extra root signature rejected", func(t *testing.T) {
		e := AuthorityLogEntry{
			PoolID: pid, SignerSetVersion: 1, PrevAuthorityLogEntryHash: GenesisPrevHash(),
			Keys: []SignerKey{k1, k2, k3}, Threshold: 2, NotBeforeUnix: 1000, ExpiresAtUnix: 9000,
		}
		e = signEntry(t, e, signer{"root-key-1", rp}, signer{"k1", p1})
		if _, err := BuildAuthorityLog(ic, root, []AuthorityLogEntry{e}); !errors.Is(err, errAuthRootSig) {
			t.Fatalf("want errAuthRootSig, got %v", err)
		}
	})
}

func TestBindsRootIssuer(t *testing.T) {
	root, _ := rootIssuerKey()
	ic := sampleIdentity() // RootIssuerKeyID "root-key-1"
	if !ic.BindsRootIssuer(root) {
		t.Fatal("matching root issuer not bound")
	}
	if ic.BindsRootIssuer(SignerKey{KeyID: "other", PublicKey: root.PublicKey}) {
		t.Fatal("mismatched key id bound")
	}
	if ic.BindsRootIssuer(SignerKey{KeyID: "root-key-1", PublicKey: []byte{0x00}}) {
		t.Fatal("malformed key bound")
	}
}
