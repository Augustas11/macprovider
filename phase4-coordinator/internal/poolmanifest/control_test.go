package poolmanifest

import (
	"crypto/ed25519"
	"errors"
	"testing"
)

func testEmergencyControl(t *testing.T, snapshot ManifestSnapshot) EmergencyLifecycleControl {
	t.Helper()
	if len(snapshot.Policies) == 0 {
		t.Fatal("fixture snapshot has no policies")
	}
	last := snapshot.Policies[len(snapshot.Policies)-1].SignedCore.Core
	digest := must(last.ManifestCoreDigest())
	return EmergencyLifecycleControl{
		PoolID:             testPoolID(t),
		ManifestVersion:    last.ManifestVersion,
		ManifestCoreDigest: digest,
		SignerSetVersion:   1,
		OperationID:        "op-emergency-pause",
		Action:             EmergencyLifecyclePaused,
		Reason:             "incident",
		IssuedAtUnix:       1500,
		ExpiresAtUnix:      1600,
	}
}

func signEmergencyControl(t *testing.T, control EmergencyLifecycleControl, signers ...signer) []Signature {
	t.Helper()
	digest, err := control.Digest()
	if err != nil {
		t.Fatalf("control Digest: %v", err)
	}
	msg, err := EmergencyLifecycleControlSigningMessage(digest)
	if err != nil {
		t.Fatalf("control signing message: %v", err)
	}
	sigs := make([]Signature, 0, len(signers))
	for _, s := range signers {
		sigs = append(sigs, Signature{KeyID: s.keyID, Sig: ed25519.Sign(s.priv, msg)})
	}
	return sigs
}

func TestVerifyEmergencyLifecycleControlOperationalSignerSet(t *testing.T) {
	snapshot := fixtureSnapshot(t)
	control := testEmergencyControl(t, snapshot)
	_, p1 := seedKey(1)
	_, p2 := seedKey(2)
	sigs := signEmergencyControl(t, control, signer{"k1", p1}, signer{"k2", p2})
	if err := VerifyEmergencyLifecycleControl(control, sigs, snapshot, 1550); err != nil {
		t.Fatalf("VerifyEmergencyLifecycleControl: %v", err)
	}
}

func TestVerifyEmergencyLifecycleControlRootIssuer(t *testing.T) {
	snapshot := fixtureSnapshot(t)
	control := testEmergencyControl(t, snapshot)
	control.SignerSetVersion = 0
	_, rootPriv := rootIssuerKey()
	sigs := signEmergencyControl(t, control, signer{"root-key-1", rootPriv})
	if err := VerifyEmergencyLifecycleControl(control, sigs, snapshot, 1550); err != nil {
		t.Fatalf("VerifyEmergencyLifecycleControl root: %v", err)
	}
}

func TestVerifyEmergencyLifecycleControlRejectsStaleAndBadProofs(t *testing.T) {
	snapshot := fixtureSnapshot(t)
	control := testEmergencyControl(t, snapshot)
	_, p1 := seedKey(1)
	_, p2 := seedKey(2)
	sigs := signEmergencyControl(t, control, signer{"k1", p1}, signer{"k2", p2})

	expired := control
	if err := VerifyEmergencyLifecycleControl(expired, sigs, snapshot, expired.ExpiresAtUnix); !errors.Is(err, errEmergencyControlExpired) {
		t.Fatalf("expired err=%v, want errEmergencyControlExpired", err)
	}

	wrongPool := control
	wrongPool.PoolID = "pool-other"
	if err := VerifyEmergencyLifecycleControl(wrongPool, sigs, snapshot, 1550); !errors.Is(err, errEmergencyControlPoolID) {
		t.Fatalf("wrong pool err=%v, want errEmergencyControlPoolID", err)
	}

	staleManifest := control
	staleManifest.ManifestVersion++
	staleSigs := signEmergencyControl(t, staleManifest, signer{"k1", p1}, signer{"k2", p2})
	if err := VerifyEmergencyLifecycleControl(staleManifest, staleSigs, snapshot, 1550); !errors.Is(err, errEmergencyControlManifest) {
		t.Fatalf("stale manifest err=%v, want errEmergencyControlManifest", err)
	}

	badSig := append([]Signature(nil), sigs...)
	badSig[0].Sig = append([]byte(nil), badSig[0].Sig...)
	badSig[0].Sig[0] ^= 0xff
	if err := VerifyEmergencyLifecycleControl(control, badSig, snapshot, 1550); !errors.Is(err, errBadSignature) {
		t.Fatalf("bad signature err=%v, want errBadSignature", err)
	}
}
