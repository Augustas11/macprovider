package poolmanifest

import (
	"crypto/ed25519"
	"errors"
	"testing"
)

// policyAuthLog builds a minimal authority log for the sample pool: a single
// genesis signer set v1 (keys k1,k2,k3 threshold 2, wide window) that signs the
// policy cores below. Reuses the slice-3 test helpers.
func policyAuthLog(t *testing.T) *AuthorityLog {
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
	log, err := BuildAuthorityLog(sampleIdentity(), root, []AuthorityLogEntry{g})
	if err != nil {
		t.Fatalf("authlog: %v", err)
	}
	return log
}

// policyCore returns a sample policy core with the given version/window/prev,
// signer_set_version 1.
func policyCore(t *testing.T, version uint64, prev []byte, notBefore, expires uint64) PolicyCore {
	t.Helper()
	pid := testPoolID(t)
	c := samplePolicy(pid)
	c.ManifestVersion = version
	c.PrevManifestCoreHash = prev
	c.SignerSetVersion = 1
	c.NotBeforeUnix = notBefore
	c.ExpiresAtUnix = expires
	return c
}

// signPolicy2of3 signs a policy core with 2 of the v1 signer set (k1,k2).
func signPolicy2of3(t *testing.T, core PolicyCore) SignedPolicyCore {
	t.Helper()
	_, p1 := seedKey(1)
	_, p2 := seedKey(2)
	dig := must(core.ManifestCoreDigest())
	msg := must(PolicyCoreSigningMessage(dig))
	return SignedPolicyCore{Core: core, Signatures: []Signature{
		{KeyID: "k1", Sig: ed25519.Sign(p1, msg)},
		{KeyID: "k2", Sig: ed25519.Sign(p2, msg)},
	}}
}

// fixtureHistory builds the canonical 3-version chain: v1 [1000,2000),
// v2 [2000,3000) (adjacent), v3 [4000,5000) (gap at [3000,4000)).
func fixtureHistory(t *testing.T) *PolicyHistory {
	t.Helper()
	authLog := policyAuthLog(t)
	v1 := policyCore(t, 1, GenesisPrevHash(), 1000, 2000)
	d1 := must(v1.ManifestCoreDigest())
	v2 := policyCore(t, 2, d1, 2000, 3000)
	d2 := must(v2.ManifestCoreDigest())
	v3 := policyCore(t, 3, d2, 4000, 5000)
	h, err := BuildPolicyHistory(sampleIdentity(), authLog, []SignedPolicyCore{
		signPolicy2of3(t, v1), signPolicy2of3(t, v2), signPolicy2of3(t, v3),
	})
	if err != nil {
		t.Fatalf("BuildPolicyHistory: %v", err)
	}
	return h
}

func TestActivePolicySelection(t *testing.T) {
	h := fixtureHistory(t)
	if h.HighestVersion() != 3 {
		t.Fatalf("highest version=%d want 3", h.HighestVersion())
	}
	active := []struct {
		now  uint64
		want uint64
	}{
		{1000, 1}, // genesis boundary belongs to v1
		{1500, 1},
		{1999, 1},
		{2000, 2}, // boundary belongs to the later window
		{2999, 2},
		{4000, 3},
		{4999, 3},
	}
	for _, c := range active {
		got, err := h.ActivePolicy(c.now)
		if err != nil {
			t.Fatalf("now=%d unexpectedly stale: %v", c.now, err)
		}
		if got.ManifestVersion != c.want {
			t.Fatalf("now=%d active version=%d want %d", c.now, got.ManifestVersion, c.want)
		}
	}
	stale := []uint64{999, 3000, 3500, 5000, 100000}
	for _, now := range stale {
		if _, err := h.ActivePolicy(now); !errors.Is(err, errPoolPolicyStale) {
			t.Fatalf("now=%d want pool_policy_stale, got %v", now, err)
		}
	}
}

// TestActivePolicyVersionWindowDivergence proves that when manifest_version order
// and window (time) order diverge — a newer version carrying an earlier validity
// window — acceptance still succeeds (overlap is checked against every accepted
// window, not just the previous one) and selection picks the version active at now,
// regardless of its version number.
func TestActivePolicyVersionWindowDivergence(t *testing.T) {
	authLog := policyAuthLog(t)
	// v1 is time-later [4000,5000); v2 is time-earlier [1000,2000). Versions ascend,
	// windows do not overlap, but window order is the reverse of version order.
	v1 := policyCore(t, 1, GenesisPrevHash(), 4000, 5000)
	d1 := must(v1.ManifestCoreDigest())
	v2 := policyCore(t, 2, d1, 1000, 2000)
	h, err := BuildPolicyHistory(sampleIdentity(), authLog, []SignedPolicyCore{
		signPolicy2of3(t, v1), signPolicy2of3(t, v2),
	})
	if err != nil {
		t.Fatalf("BuildPolicyHistory: %v", err)
	}
	got, err := h.ActivePolicy(1500) // inside v2's earlier window
	if err != nil || got.ManifestVersion != 2 {
		t.Fatalf("now=1500 active version=%d err=%v, want version 2", got.ManifestVersion, err)
	}
	got, err = h.ActivePolicy(4500) // inside v1's later window
	if err != nil || got.ManifestVersion != 1 {
		t.Fatalf("now=4500 active version=%d err=%v, want version 1", got.ManifestVersion, err)
	}
	if _, err := h.ActivePolicy(3000); !errors.Is(err, errPoolPolicyStale) {
		t.Fatalf("now=3000 (gap) want pool_policy_stale, got %v", err)
	}
}

// TestPolicyHistoryImmutable proves accepted policy material cannot be mutated
// through the caller's inputs or a returned value.
func TestPolicyHistoryImmutable(t *testing.T) {
	authLog := policyAuthLog(t)
	v1 := policyCore(t, 1, GenesisPrevHash(), 1000, 2000)
	v1.ModelAllowlist = []string{"model-a", "model-b"}
	signed := signPolicy2of3(t, v1)
	h, err := BuildPolicyHistory(sampleIdentity(), authLog, []SignedPolicyCore{signed})
	if err != nil {
		t.Fatalf("BuildPolicyHistory: %v", err)
	}
	// Mutate the caller's slices after build.
	signed.Core.ModelAllowlist[0] = "tampered"
	signed.Core.PrevManifestCoreHash[0] ^= 0xff
	got, err := h.ActivePolicy(1500)
	if err != nil {
		t.Fatalf("active: %v", err)
	}
	if got.ModelAllowlist[0] == "tampered" {
		t.Fatal("model allowlist mutated through caller's input")
	}
	if got.PrevManifestCoreHash[0] != 0 {
		t.Fatal("prev hash mutated through caller's input")
	}
	// Mutate the returned value; a fresh lookup must be unaffected.
	got.ModelAllowlist[0] = "tampered2"
	again, _ := h.ActivePolicy(1500)
	if again.ModelAllowlist[0] == "tampered2" {
		t.Fatal("mutation of a returned policy leaked into the history")
	}
}

func TestBuildPolicyHistoryRejects(t *testing.T) {
	authLog := policyAuthLog(t)
	ic := sampleIdentity()
	genesis := func() PolicyCore { return policyCore(t, 1, GenesisPrevHash(), 1000, 2000) }
	d1 := must(genesis().ManifestCoreDigest())

	t.Run("pool_id mismatch", func(t *testing.T) {
		c := genesis()
		c.PoolID = "some-other-pool-idxxxx"
		if _, err := BuildPolicyHistory(ic, authLog, []SignedPolicyCore{signPolicy2of3(t, c)}); !errors.Is(err, errPolicyPoolID) {
			t.Fatalf("want errPolicyPoolID, got %v", err)
		}
	})

	t.Run("inverted window", func(t *testing.T) {
		c := policyCore(t, 1, GenesisPrevHash(), 2000, 1000)
		if _, err := BuildPolicyHistory(ic, authLog, []SignedPolicyCore{signPolicy2of3(t, c)}); !errors.Is(err, errPolicyWindow) {
			t.Fatalf("want errPolicyWindow, got %v", err)
		}
	})

	t.Run("manifest_version zero", func(t *testing.T) {
		c := policyCore(t, 0, GenesisPrevHash(), 1000, 2000)
		if _, err := BuildPolicyHistory(ic, authLog, []SignedPolicyCore{signPolicy2of3(t, c)}); !errors.Is(err, errPolicyVersionZero) {
			t.Fatalf("want errPolicyVersionZero, got %v", err)
		}
	})

	t.Run("non-genesis first prev", func(t *testing.T) {
		c := policyCore(t, 1, d1, 1000, 2000) // prev != zeros on the first core
		if _, err := BuildPolicyHistory(ic, authLog, []SignedPolicyCore{signPolicy2of3(t, c)}); !errors.Is(err, errPolicyGenesisPrev) {
			t.Fatalf("want errPolicyGenesisPrev, got %v", err)
		}
	})

	t.Run("version rollback", func(t *testing.T) {
		v1 := genesis()
		v2 := policyCore(t, 1, must(v1.ManifestCoreDigest()), 2000, 3000) // version not increasing
		if _, err := BuildPolicyHistory(ic, authLog, []SignedPolicyCore{signPolicy2of3(t, v1), signPolicy2of3(t, v2)}); !errors.Is(err, errPolicyRollback) {
			t.Fatalf("want errPolicyRollback, got %v", err)
		}
	})

	t.Run("chain broken", func(t *testing.T) {
		v1 := genesis()
		v2 := policyCore(t, 2, make([]byte, 32), 2000, 3000) // wrong prev
		if _, err := BuildPolicyHistory(ic, authLog, []SignedPolicyCore{signPolicy2of3(t, v1), signPolicy2of3(t, v2)}); !errors.Is(err, errPolicyChainBroken) {
			t.Fatalf("want errPolicyChainBroken, got %v", err)
		}
	})

	t.Run("overlapping window", func(t *testing.T) {
		v1 := genesis() // [1000,2000)
		v2 := policyCore(t, 2, must(v1.ManifestCoreDigest()), 1500, 2500)
		if _, err := BuildPolicyHistory(ic, authLog, []SignedPolicyCore{signPolicy2of3(t, v1), signPolicy2of3(t, v2)}); !errors.Is(err, errPolicyWindowOverlap) {
			t.Fatalf("want errPolicyWindowOverlap, got %v", err)
		}
	})

	t.Run("unknown signer set version", func(t *testing.T) {
		c := genesis()
		c.SignerSetVersion = 5 // authority log only has v1
		if _, err := BuildPolicyHistory(ic, authLog, []SignedPolicyCore{signPolicy2of3(t, c)}); !errors.Is(err, errPolicyUnknownSignerSet) {
			t.Fatalf("want errPolicyUnknownSignerSet, got %v", err)
		}
	})

	t.Run("bad signature (below threshold)", func(t *testing.T) {
		c := genesis()
		_, p1 := seedKey(1)
		dig := must(c.ManifestCoreDigest())
		msg := must(PolicyCoreSigningMessage(dig))
		spc := SignedPolicyCore{Core: c, Signatures: []Signature{{KeyID: "k1", Sig: ed25519.Sign(p1, msg)}}}
		if _, err := BuildPolicyHistory(ic, authLog, []SignedPolicyCore{spc}); !errors.Is(err, errThresholdNotMet) {
			t.Fatalf("want errThresholdNotMet, got %v", err)
		}
	})

	t.Run("empty history is stale", func(t *testing.T) {
		if _, err := BuildPolicyHistory(ic, authLog, nil); !errors.Is(err, errPoolPolicyStale) {
			t.Fatalf("want errPoolPolicyStale, got %v", err)
		}
	})

	t.Run("nil authority log", func(t *testing.T) {
		v1 := genesis()
		if _, err := BuildPolicyHistory(ic, nil, []SignedPolicyCore{signPolicy2of3(t, v1)}); !errors.Is(err, errAuthEmpty) {
			t.Fatalf("want errAuthEmpty, got %v", err)
		}
	})

	t.Run("policy signed under a revoked signer set is rejected", func(t *testing.T) {
		// Full rotate->revoke authority log: signer set v2 is revoked. A policy core
		// naming signer_set_version 2 must be rejected via VerifyPolicyCore.
		root, entries := fixtureChain(t)
		revLog, err := BuildAuthorityLog(sampleIdentity(), root, entries)
		if err != nil {
			t.Fatalf("authlog: %v", err)
		}
		c := genesis()
		c.SignerSetVersion = 2
		_, p4 := seedKey(4)
		_, p5 := seedKey(5)
		dig := must(c.ManifestCoreDigest())
		msg := must(PolicyCoreSigningMessage(dig))
		spc := SignedPolicyCore{Core: c, Signatures: []Signature{
			{KeyID: "k4", Sig: ed25519.Sign(p4, msg)}, {KeyID: "k5", Sig: ed25519.Sign(p5, msg)},
		}}
		if _, err := BuildPolicyHistory(ic, revLog, []SignedPolicyCore{spc}); !errors.Is(err, errSignerSetRevoked) {
			t.Fatalf("want errSignerSetRevoked, got %v", err)
		}
	})
}
