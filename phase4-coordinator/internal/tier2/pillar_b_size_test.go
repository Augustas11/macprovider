package tier2

import (
	"bytes"
	"encoding/json"
	"testing"
)

// SPEC-001-R012: the pre-seal size of a frame equals the sealed size, so the
// coordinator can refuse an over-limit frame without spending a seq or nonce.
func TestPillarBEnvelopeBodyForSizeMatchesSealedLength(t *testing.T) {
	key := bytes.Repeat([]byte{0x22}, 32)
	nonceBase := []byte{9, 8, 7, 6}
	for _, n := range []int{0, 1, 2, 3, 100, 4095, 1 << 20, (1 << 20) + 1} {
		aad := AEADFrameAAD{Type: "inference_request", Direction: "c2p", RequestID: "req-size", ProviderID: "p", AssignedID: "a", Seq: 7}
		plaintext := bytes.Repeat([]byte{'x'}, n)
		sealed, err := SealPillarBFrame(key, nonceBase, "kid-1", 7, aad, plaintext)
		if err != nil {
			t.Fatal(err)
		}
		sized, err := PillarBEnvelopeBodyForSize("kid-1", 7, aad, n)
		if err != nil {
			t.Fatal(err)
		}
		want, _ := json.Marshal(sealed.Enc)
		got, _ := json.Marshal(sized)
		if len(got) != len(want) {
			t.Fatalf("plaintext %d: sized envelope %d bytes, sealed %d", n, len(got), len(want))
		}
	}
	if _, err := PillarBEnvelopeBodyForSize("kid-1", 1, AEADFrameAAD{Seq: 2}, 1); err == nil {
		t.Fatal("seq mismatch accepted")
	}
	if _, err := PillarBEnvelopeBodyForSize("kid-1", 1, AEADFrameAAD{Seq: 1}, -1); err == nil {
		t.Fatal("negative length accepted")
	}
}
