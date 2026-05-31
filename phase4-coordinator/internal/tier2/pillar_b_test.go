package tier2

import (
	"bytes"
	"encoding/base64"
	"encoding/json"
	"strings"
	"testing"
)

func TestPillarBX25519PublicKeyParsing(t *testing.T) {
	_, raw, err := NewX25519Keypair()
	if err != nil {
		t.Fatalf("keypair: %v", err)
	}
	encoded := base64.RawURLEncoding.EncodeToString(raw)
	pub, decoded, err := ParseX25519PublicKey(encoded)
	if err != nil {
		t.Fatalf("parse valid public key: %v", err)
	}
	if pub == nil || !bytes.Equal(decoded, raw) {
		t.Fatalf("parsed public key mismatch")
	}
	if _, _, err := ParseX25519PublicKey("not base64!"); err == nil {
		t.Fatal("invalid public key encoding accepted")
	}
	if _, _, err := ParseX25519PublicKey(base64.RawURLEncoding.EncodeToString([]byte("short"))); err == nil {
		t.Fatal("short public key accepted")
	}
}

func TestPillarBKeyDerivationIsDeterministic(t *testing.T) {
	shared := bytes.Repeat([]byte{0x11}, 32)
	providerPub := bytes.Repeat([]byte{0x22}, 32)
	coordinatorPub := bytes.Repeat([]byte{0x33}, 32)

	first, err := DerivePillarBKeysFromSharedSecret(shared, "provider-a", "session-a", providerPub, coordinatorPub, PillarBAEADA256GCM)
	if err != nil {
		t.Fatalf("derive first: %v", err)
	}
	second, err := DerivePillarBKeysFromSharedSecret(shared, "provider-a", "session-a", providerPub, coordinatorPub, PillarBAEADA256GCM)
	if err != nil {
		t.Fatalf("derive second: %v", err)
	}
	if first.AEADSuite != PillarBAEADA256GCM || first.KeyID == "" || strings.Contains(first.KeyID, "=") {
		t.Fatalf("unexpected derived suite/key id: %+v", first)
	}
	if len(first.C2PKey) != 32 || len(first.P2CKey) != 32 || len(first.C2PNonceBase) != 4 || len(first.P2CNonceBase) != 4 || len(first.Transcript) != 32 {
		t.Fatalf("unexpected derived lengths: c2p=%d p2c=%d c2pnonce=%d p2cnonce=%d transcript=%d", len(first.C2PKey), len(first.P2CKey), len(first.C2PNonceBase), len(first.P2CNonceBase), len(first.Transcript))
	}
	if !bytes.Equal(first.C2PKey, second.C2PKey) || !bytes.Equal(first.P2CKey, second.P2CKey) || first.KeyID != second.KeyID {
		t.Fatal("key derivation was not deterministic")
	}
	if bytes.Equal(first.C2PKey, first.P2CKey) {
		t.Fatal("directional AEAD keys must differ")
	}
	if _, err := DerivePillarBKeysFromSharedSecret(shared[:31], "provider-a", "session-a", providerPub, coordinatorPub, PillarBAEADA256GCM); err == nil {
		t.Fatal("short shared secret accepted")
	}
}

func TestPillarBAEADFrameRoundTripAndTamperRejection(t *testing.T) {
	key := bytes.Repeat([]byte{0x41}, 32)
	nonceBase := []byte{1, 2, 3, 4}
	aad := AEADFrameAAD{
		Type:       "chat_request",
		Direction:  "c2p",
		RequestID:  "req-1",
		Stream:     true,
		ProviderID: "provider-a",
		AssignedID: "session-a",
		Seq:        7,
	}
	plaintext := []byte(`{"model":"model-a","messages":[{"role":"user","content":"secret"}]}`)

	envelope, err := SealPillarBFrame(key, nonceBase, "kid-1", 7, aad, plaintext)
	if err != nil {
		t.Fatalf("seal: %v", err)
	}
	if !envelope.Encrypted || envelope.Enc.KID != "kid-1" || envelope.Enc.Seq != 7 {
		t.Fatalf("bad envelope metadata: %+v", envelope)
	}
	raw, err := json.Marshal(envelope)
	if err != nil {
		t.Fatalf("marshal envelope: %v", err)
	}
	if bytes.Contains(raw, []byte("secret")) {
		t.Fatalf("plaintext leaked in envelope JSON: %s", string(raw))
	}
	opened, err := OpenPillarBFrame(key, nonceBase, "kid-1", 7, aad, envelope)
	if err != nil {
		t.Fatalf("open: %v", err)
	}
	if !bytes.Equal(opened, plaintext) {
		t.Fatalf("opened plaintext mismatch: %s", string(opened))
	}
	if _, err := OpenPillarBFrame(key, nonceBase, "kid-1", 8, aad, envelope); err == nil {
		t.Fatal("sequence mismatch accepted")
	}
	tampered := envelope
	tampered.Enc.Tag = base64.RawURLEncoding.EncodeToString(bytes.Repeat([]byte{0}, 16))
	if _, err := OpenPillarBFrame(key, nonceBase, "kid-1", 7, aad, tampered); err == nil {
		t.Fatal("tampered tag accepted")
	}
}
