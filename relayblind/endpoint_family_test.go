package relayblind

import (
	"bytes"
	"crypto/ed25519"
	"testing"
	"time"
)

func TestEndpointFamiliesSignedScopeAndLegacyFraming(t *testing.T) {
	now := time.Unix(1_800_000_000, 0).UTC()
	legacy, pin, provider := testRecord(t, now)
	seed := make([]byte, ed25519.SeedSize)
	for i := range seed {
		seed[i] = byte(i)
	}
	identity := ed25519.NewKeyFromSeed(seed)
	explicit, err := NewSignedKeyRecordForFamilies(provider.PublicKey().Bytes(), identity, legacy.Models, []string{EndpointChatCompletions}, legacy.MaxEncryptedRequestBytes, time.Unix(legacy.NotBeforeUnix, 0), time.Unix(legacy.ExpiresAtUnix, 0))
	if err != nil {
		t.Fatal(err)
	}
	if explicit.KID != legacy.KID || explicit.KeyRecordDigest != legacy.KeyRecordDigest || explicit.Signature != legacy.Signature {
		t.Fatal("legacy Chat framing changed")
	}
	families := []string{EndpointChatCompletions, EndpointMessages, EndpointResponses}
	record, err := NewSignedKeyRecordForFamilies(provider.PublicKey().Bytes(), identity, legacy.Models, families, 4096, now.Add(-time.Minute), now.Add(time.Hour))
	if err != nil {
		t.Fatal(err)
	}
	if err := record.Verify(pin, now); err == nil {
		t.Fatal("Chat-only pin authorized additional families")
	}
	pin.EndpointFamilies = append([]string(nil), families...)
	if err := record.Verify(pin, now); err != nil {
		t.Fatal(err)
	}
	tampered := record
	tampered.EndpointFamilies = []string{EndpointChatCompletions}
	if err := tampered.Verify(pin, now); err == nil {
		t.Fatal("signed family substitution accepted")
	}
	for _, invalid := range [][]string{nil, {EndpointResponses, EndpointMessages}, {EndpointMessages, EndpointMessages}, {"unknown"}} {
		if _, err := NewSignedKeyRecordForFamilies(provider.PublicKey().Bytes(), identity, legacy.Models, invalid, 4096, now.Add(-time.Minute), now.Add(time.Hour)); err == nil {
			t.Fatalf("invalid families accepted: %v", invalid)
		}
	}
}

func TestEndpointFamilyBoundIntoCiphertext(t *testing.T) {
	now := time.Unix(1_800_000_000, 0).UTC()
	record, _, provider := testRecord(t, now)
	for _, family := range []string{EndpointChatCompletions, EndpointMessages, EndpointResponses} {
		t.Run(family, func(t *testing.T) {
			envelope, err := testReservation(record, now).NewEnvelope("family-bound-request", now, bytes.Repeat([]byte{0x55}, 32))
			if err != nil {
				t.Fatal(err)
			}
			envelope.EndpointFamily = family
			original := []byte("{ \"model\": \"model-a\", \"original-body\": true }\n")
			envelope, err = envelope.Encrypt(original, provider.PublicKey().Bytes(), bytes.Repeat([]byte{0x22}, 32))
			if err != nil {
				t.Fatal(err)
			}
			clear, err := envelope.Decrypt(provider.Bytes())
			if err != nil || !bytes.Equal(clear, original) {
				t.Fatalf("original bytes changed: %v", err)
			}
			if family == EndpointResponses {
				envelope.EndpointFamily = EndpointMessages
			} else {
				envelope.EndpointFamily = EndpointResponses
			}
			if _, err := envelope.Decrypt(provider.Bytes()); err == nil {
				t.Fatal("family substitution decrypted")
			}
		})
	}
}

func TestResponsesCapabilityDeclarationPreservesStrictRouting(t *testing.T) {
	body := []byte(`{"text":{"format":{"type":"json_schema","name":"result","strict":false,"schema":{"type":"object"}}}}`)
	got := RequiredCapabilitiesForFamily(body, EndpointResponses)
	if len(got) != 1 || got[0] != CapabilityJSONSchemaNonStrict {
		t.Fatalf("missing Responses declaration: %v", got)
	}
	if got := RequiredCapabilitiesForFamily(body, EndpointChatCompletions); got != nil {
		t.Fatalf("Responses fields affected Chat: %v", got)
	}
}
