package poolmanifest

import (
	"crypto/ed25519"
	"encoding/hex"
	"errors"
	"testing"
)

// Fixed seeds derive deterministic keypairs (no crypto/rand) so the golden
// signature vectors below are reproducible. Seed i is 32 bytes all = i+1.
func seedKey(n byte) (SignerKey, ed25519.PrivateKey) {
	seed := make([]byte, ed25519.SeedSize)
	for i := range seed {
		seed[i] = n
	}
	priv := ed25519.NewKeyFromSeed(seed)
	return SignerKey{KeyID: string([]byte{'k', '0' + n}), PublicKey: priv.Public().(ed25519.PublicKey)}, priv
}

// GOLDEN VECTORS — freeze the SPEC-042-R012 policy-core signing preimage and the
// resulting deterministic Ed25519 signatures over the slice-1 sample policy core.
// SIGMSG is policyCoreSigTag ‖ goldenManifestDigest; any change to the signing tag
// or preimage breaks it on purpose.
const (
	goldenPolicyCoreSigMsgHex = "6d616370726f76696465722f737065633034322f706f6c6963792d636f72652d7369672f7631237806f14c4bef1a2a0ec853c0309b24fc3db7c6cd14d5d71b9e186245ead2b6"
	goldenSigKey1Hex          = "dec36e7c2a004833f8f034678e063d6d882fe9b71af583811028b8cb57eb97856ceeb10390ccdbb567a064a179a4572d1f14b2e4c460589509bf8587bd7ef70c"
	goldenSigKey2Hex          = "a95228ca0e8a1007494ed46f887ae79d9b75fa88bd5dc14d8c427998b07c2efb97a942a89b6ee44534e872d586d9f4d2a9858626cbdc683905d30995b5d92700"
	goldenSigKey3Hex          = "2dce54997d2f8b8273900784a8429d846a0a8429f2ea0f352562870d42f554464f5b925e2a1a2a56ff6a7fa07c77f021b2511c5e381aba69dce7fc80c9727d08"
)

func mustHex(s string) []byte {
	b, err := hex.DecodeString(s)
	if err != nil {
		panic(err)
	}
	return b
}

// signerSet3 returns a fixed 3-key set (keys k1,k2,k3) with the given threshold
// and a window that contains the sample policy's not_before (1000), plus the
// three private keys for signing.
func signerSet3(threshold uint32) (SignerSet, [3]ed25519.PrivateKey) {
	k1, p1 := seedKey(1)
	k2, p2 := seedKey(2)
	k3, p3 := seedKey(3)
	return SignerSet{
		Version:       1,
		Keys:          []SignerKey{k1, k2, k3},
		Threshold:     threshold,
		NotBeforeUnix: 500,
		ExpiresAtUnix: 5000,
	}, [3]ed25519.PrivateKey{p1, p2, p3}
}

// signPolicy signs the sample policy core with the given private key.
func signPolicy(t *testing.T, keyID string, priv ed25519.PrivateKey) Signature {
	t.Helper()
	pid, _ := sampleIdentity().PoolID()
	dig := must(samplePolicy(pid).ManifestCoreDigest())
	msg := must(PolicyCoreSigningMessage(dig))
	return Signature{KeyID: keyID, Sig: ed25519.Sign(priv, msg)}
}

func samplePolicyForSig(t *testing.T) PolicyCore {
	t.Helper()
	pid, _ := sampleIdentity().PoolID()
	return samplePolicy(pid)
}

func TestPolicyCoreSigningMessageGolden(t *testing.T) {
	dig := must(samplePolicyForSig(t).ManifestCoreDigest())
	msg := must(PolicyCoreSigningMessage(dig))
	if got := hex.EncodeToString(msg); got != goldenPolicyCoreSigMsgHex {
		t.Fatalf("signing message drifted:\n got=%s\nwant=%s", got, goldenPolicyCoreSigMsgHex)
	}
	// The tag prefixes the digest; the digest suffix is the slice-1 golden digest.
	if got := hex.EncodeToString(dig); got != goldenManifestDigest {
		t.Fatalf("digest changed out from under the signing vector: %s", got)
	}
	// Non-32-byte digest is rejected with its own distinct sentinel.
	if _, err := PolicyCoreSigningMessage([]byte{0x00}); !errors.Is(err, errDigestLen) {
		t.Fatalf("want errDigestLen for short digest, got %v", err)
	}
}

func TestSignatureGoldenVectors(t *testing.T) {
	// The fixed-seed keys reproduce the pinned signatures exactly (Ed25519 is
	// deterministic), and each verifies under VerifyPolicyCore in a 1-of-1 set.
	golden := []string{goldenSigKey1Hex, goldenSigKey2Hex, goldenSigKey3Hex}
	for i := byte(1); i <= 3; i++ {
		key, priv := seedKey(i)
		sig := signPolicy(t, key.KeyID, priv)
		if got := hex.EncodeToString(sig.Sig); got != golden[i-1] {
			t.Fatalf("key %d signature drifted:\n got=%s\nwant=%s", i, got, golden[i-1])
		}
		ss := SignerSet{Version: 1, Keys: []SignerKey{key}, Threshold: 1, NotBeforeUnix: 500, ExpiresAtUnix: 5000}
		if err := VerifyPolicyCore(samplePolicyForSig(t), []Signature{sig}, ss); err != nil {
			t.Fatalf("golden 1-of-1 verify failed for key %d: %v", i, err)
		}
		// The pinned signature bytes verify too (guards the vector, not just re-signing).
		ss2 := ss
		if err := VerifyPolicyCore(samplePolicyForSig(t), []Signature{{KeyID: key.KeyID, Sig: mustHex(golden[i-1])}}, ss2); err != nil {
			t.Fatalf("pinned signature bytes failed to verify for key %d: %v", i, err)
		}
	}
}

func TestVerifyPolicyCoreAccept(t *testing.T) {
	// 2-of-3: two distinct authorized signatures satisfy threshold 2.
	ss, priv := signerSet3(2)
	sigs := []Signature{signPolicy(t, "k1", priv[0]), signPolicy(t, "k3", priv[2])}
	if err := VerifyPolicyCore(samplePolicyForSig(t), sigs, ss); err != nil {
		t.Fatalf("2-of-3 accept failed: %v", err)
	}
	// All three also accept (count exceeds threshold is fine).
	all := []Signature{signPolicy(t, "k1", priv[0]), signPolicy(t, "k2", priv[1]), signPolicy(t, "k3", priv[2])}
	if err := VerifyPolicyCore(samplePolicyForSig(t), all, ss); err != nil {
		t.Fatalf("3-of-3 accept failed: %v", err)
	}
}

func TestVerifyPolicyCoreRejects(t *testing.T) {
	base := samplePolicyForSig(t)

	t.Run("wrong signer_set_version", func(t *testing.T) {
		ss, priv := signerSet3(1)
		ss.Version = 2 // policy core carries SignerSetVersion=1
		err := VerifyPolicyCore(base, []Signature{signPolicy(t, "k1", priv[0])}, ss)
		if !errors.Is(err, errSignerSetVersion) {
			t.Fatalf("want errSignerSetVersion, got %v", err)
		}
	})

	t.Run("revoked signer set", func(t *testing.T) {
		ss, priv := signerSet3(1)
		ss.Revoked = true
		err := VerifyPolicyCore(base, []Signature{signPolicy(t, "k1", priv[0])}, ss)
		if !errors.Is(err, errSignerSetRevoked) {
			t.Fatalf("want errSignerSetRevoked, got %v", err)
		}
	})

	t.Run("not_before below signer-set window", func(t *testing.T) {
		ss, priv := signerSet3(1)
		ss.NotBeforeUnix = 1500 // policy not_before is 1000 < 1500
		err := VerifyPolicyCore(base, []Signature{signPolicy(t, "k1", priv[0])}, ss)
		if !errors.Is(err, errSignerSetInactive) {
			t.Fatalf("want errSignerSetInactive, got %v", err)
		}
	})

	t.Run("not_before at/after signer-set expiry", func(t *testing.T) {
		ss, priv := signerSet3(1)
		ss.NotBeforeUnix = 100
		ss.ExpiresAtUnix = 1000 // half-open: policy not_before 1000 == expires -> inactive
		err := VerifyPolicyCore(base, []Signature{signPolicy(t, "k1", priv[0])}, ss)
		if !errors.Is(err, errSignerSetInactive) {
			t.Fatalf("want errSignerSetInactive, got %v", err)
		}
	})

	t.Run("below threshold", func(t *testing.T) {
		ss, priv := signerSet3(2)
		err := VerifyPolicyCore(base, []Signature{signPolicy(t, "k1", priv[0])}, ss)
		if !errors.Is(err, errThresholdNotMet) {
			t.Fatalf("want errThresholdNotMet, got %v", err)
		}
	})

	t.Run("empty signature list is unsigned", func(t *testing.T) {
		ss, _ := signerSet3(1)
		err := VerifyPolicyCore(base, nil, ss)
		if !errors.Is(err, errThresholdNotMet) {
			t.Fatalf("want errThresholdNotMet, got %v", err)
		}
	})

	t.Run("duplicate key id does not count twice", func(t *testing.T) {
		ss, priv := signerSet3(2)
		s := signPolicy(t, "k1", priv[0])
		err := VerifyPolicyCore(base, []Signature{s, s}, ss) // same key twice
		if !errors.Is(err, errDuplicateSigner) {
			t.Fatalf("want errDuplicateSigner, got %v", err)
		}
	})

	t.Run("signature from key outside the set", func(t *testing.T) {
		ss, _ := signerSet3(1)
		outsideKey, outsidePriv := seedKey(9)
		err := VerifyPolicyCore(base, []Signature{signPolicy(t, outsideKey.KeyID, outsidePriv)}, ss)
		if !errors.Is(err, errUnknownSigner) {
			t.Fatalf("want errUnknownSigner, got %v", err)
		}
	})

	t.Run("signature over a tampered digest", func(t *testing.T) {
		ss, priv := signerSet3(1)
		// Sign the sample message, then verify against a DIFFERENT policy core.
		good := signPolicy(t, "k1", priv[0])
		tampered := base
		tampered.RevenueSplitBps = 999 // changes manifest_core_digest
		err := VerifyPolicyCore(tampered, []Signature{good}, ss)
		if !errors.Is(err, errBadSignature) {
			t.Fatalf("want errBadSignature, got %v", err)
		}
	})

	t.Run("truncated signature bytes", func(t *testing.T) {
		ss, priv := signerSet3(1)
		s := signPolicy(t, "k1", priv[0])
		s.Sig = s.Sig[:10]
		err := VerifyPolicyCore(base, []Signature{s}, ss)
		if !errors.Is(err, errBadSignature) {
			t.Fatalf("want errBadSignature, got %v", err)
		}
	})
}

func TestSignerSetValidate(t *testing.T) {
	k1, _ := seedKey(1)
	k2, _ := seedKey(2)
	valid := SignerSet{Version: 1, Keys: []SignerKey{k1, k2}, Threshold: 2, NotBeforeUnix: 1, ExpiresAtUnix: 2}
	if err := valid.Validate(); err != nil {
		t.Fatalf("valid set rejected: %v", err)
	}
	cases := []struct {
		name string
		mut  func(*SignerSet)
		want error
	}{
		{"no keys", func(s *SignerSet) { s.Keys = nil }, errSignerSetEmpty},
		{"threshold zero", func(s *SignerSet) { s.Threshold = 0 }, errThresholdRange},
		{"threshold exceeds N", func(s *SignerSet) { s.Threshold = 3 }, errThresholdRange},
		{"empty key id", func(s *SignerSet) { s.Keys[0].KeyID = "" }, errSignerKeyID},
		{"duplicate key id", func(s *SignerSet) { s.Keys[1].KeyID = s.Keys[0].KeyID }, errSignerKeyID},
		{"bad key length", func(s *SignerSet) { s.Keys[0].PublicKey = []byte{0x00} }, errSignerKeyLen},
		{"duplicate public key under distinct ids", func(s *SignerSet) { s.Keys[1].PublicKey = s.Keys[0].PublicKey }, errSignerKeyDup},
		{"empty window", func(s *SignerSet) { s.NotBeforeUnix = 5; s.ExpiresAtUnix = 5 }, errSignerSetWindow},
		{"inverted window", func(s *SignerSet) { s.NotBeforeUnix = 9; s.ExpiresAtUnix = 1 }, errSignerSetWindow},
	}
	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			s := SignerSet{Version: 1, Keys: []SignerKey{k1, k2}, Threshold: 2, NotBeforeUnix: 1, ExpiresAtUnix: 2}
			tc.mut(&s)
			if err := s.Validate(); !errors.Is(err, tc.want) {
				t.Fatalf("want %v, got %v", tc.want, err)
			}
		})
	}
	// VerifyPolicyCore rejects when the signer set itself is malformed.
	bad := SignerSet{Version: 1, Keys: []SignerKey{k1}, Threshold: 5, NotBeforeUnix: 1, ExpiresAtUnix: 2}
	if err := VerifyPolicyCore(samplePolicyForSig(t), nil, bad); !errors.Is(err, errThresholdRange) {
		t.Fatalf("malformed signer set not rejected first: %v", err)
	}
}

// TestDuplicatePublicKeyCannotCollapseThreshold proves that one private key cannot
// satisfy a 2-of-N threshold by appearing under two key ids sharing its public key:
// such a signer set is rejected outright, so the single-key holder's signature
// (valid under both ids) never reaches the threshold count.
func TestDuplicatePublicKeyCannotCollapseThreshold(t *testing.T) {
	k1, p1 := seedKey(1)
	// A second "identity" that reuses k1's public key.
	twin := SignerKey{KeyID: "k1-twin", PublicKey: k1.PublicKey}
	ss := SignerSet{
		Version:       1,
		Keys:          []SignerKey{k1, twin},
		Threshold:     2,
		NotBeforeUnix: 500,
		ExpiresAtUnix: 5000,
	}
	if err := ss.Validate(); !errors.Is(err, errSignerKeyDup) {
		t.Fatalf("duplicate-pubkey signer set not rejected by Validate: %v", err)
	}
	// The same valid signature presented under both ids must NOT verify: the
	// malformed set is rejected before any threshold counting.
	sig := signPolicy(t, "k1", p1)
	twinSig := Signature{KeyID: "k1-twin", Sig: sig.Sig}
	if err := VerifyPolicyCore(samplePolicyForSig(t), []Signature{sig, twinSig}, ss); !errors.Is(err, errSignerKeyDup) {
		t.Fatalf("one key satisfied 2-of-N via duplicate public key: %v", err)
	}
}

func TestVerifyPoolIDBinding(t *testing.T) {
	ic := sampleIdentity()
	pid, _ := ic.PoolID()
	if err := VerifyPoolIDBinding(ic, pid); err != nil {
		t.Fatalf("correct pool_id rejected: %v", err)
	}
	if err := VerifyPoolIDBinding(ic, "not-the-right-pool-idxx"); !errors.Is(err, errPoolIDMismatch) {
		t.Fatalf("want errPoolIDMismatch, got %v", err)
	}
	// A different identity core yields a different pool_id, so the old binding fails.
	other := IdentityCore{RootIssuerKeyID: "root-key-2", GenesisNonce: []byte("x")}
	if err := VerifyPoolIDBinding(other, pid); !errors.Is(err, errPoolIDMismatch) {
		t.Fatalf("want errPoolIDMismatch for mismatched identity, got %v", err)
	}
}
