package relayblind

import (
	"bytes"
	"crypto/ecdh"
	"crypto/ed25519"
	"crypto/sha256"
	"encoding/base64"
	"encoding/hex"
	"encoding/json"
	"os"
	"path/filepath"
	"reflect"
	"strings"
	"testing"
	"time"
)

func TestKeyRecordEnvelopeRoundTrip(t *testing.T) {
	now := time.Unix(1_700_000_000, 0).UTC()
	record, pin, providerPrivate := testRecord(t, now)
	if err := record.Verify(pin, now); err != nil {
		t.Fatalf("Verify: %v", err)
	}
	publicKey, err := record.EncryptionPublicKey()
	if err != nil {
		t.Fatal(err)
	}
	buyerPrivate, err := ecdh.X25519().NewPrivateKey(bytes.Repeat([]byte{0x22}, 32))
	if err != nil {
		t.Fatal(err)
	}
	reservation := testReservation(record, now)
	envelope, err := reservation.NewEnvelope("018f7b7b-7c35-4cf0-8d4e-3f0ab1c2d928", now, bytes.Repeat([]byte{0x55}, 32))
	if err != nil {
		t.Fatal(err)
	}
	plaintext := []byte("{\"model\":\"model-a\",\"messages\":[{\"role\":\"user\",\"content\":\"fixture prompt\"}],\"max_tokens\":32,\"stream\":false}")
	envelope, err = envelope.Encrypt(plaintext, publicKey, buyerPrivate.Bytes())
	if err != nil {
		t.Fatalf("Encrypt: %v", err)
	}
	decrypted, err := envelope.Decrypt(providerPrivate.Bytes())
	if err != nil {
		t.Fatalf("Decrypt: %v", err)
	}
	if !bytes.Equal(decrypted, plaintext) {
		t.Fatalf("plaintext mismatch")
	}
	raw, err := json.Marshal(envelope)
	if err != nil {
		t.Fatal(err)
	}
	parsed, err := ParseEnvelope(raw)
	if err != nil {
		t.Fatalf("ParseEnvelope: %v", err)
	}
	if parsed.BuyerBinding != reservation.BuyerBinding {
		t.Fatalf("buyer binding lost")
	}
	if _, err := parsed.Digest(); err != nil {
		t.Fatalf("Digest: %v", err)
	}

	tampered := parsed
	tampered.Model = "model-b"
	if _, err := tampered.Decrypt(providerPrivate.Bytes()); err == nil {
		t.Fatal("tampered AAD decrypted")
	}
	if _, err := envelope.Encrypt(plaintext, make([]byte, 32), buyerPrivate.Bytes()); err == nil {
		t.Fatal("low-order X25519 peer accepted")
	}
}

func TestGoldenVector(t *testing.T) {
	raw, err := os.ReadFile("../../../test/fixtures/relay-blind/golden-v1.json")
	if err != nil {
		t.Fatal(err)
	}
	var fixture map[string]json.RawMessage
	if err := json.Unmarshal(raw, &fixture); err != nil {
		t.Fatal(err)
	}
	var record KeyRecord
	var pin IdentityPin
	var reservation ReservationResponse
	var wantEnvelope Envelope
	for name, target := range map[string]any{"key_record": &record, "pin": &pin, "reservation": &reservation, "envelope": &wantEnvelope} {
		if err := json.Unmarshal(fixture[name], target); err != nil {
			t.Fatalf("%s: %v", name, err)
		}
	}
	now := time.Unix(wantEnvelope.IssuedAtUnix, 0)
	if err := record.Verify(pin, now); err != nil {
		t.Fatal(err)
	}
	providerPrivate := fixtureBytes(t, fixture, "provider_x25519_private_key")
	buyerPrivate := fixtureBytes(t, fixture, "buyer_x25519_private_key")
	replayNonce := fixtureBytes(t, fixture, "request_replay_nonce")
	var plaintext string
	if err := json.Unmarshal(fixture["plaintext_utf8"], &plaintext); err != nil {
		t.Fatal(err)
	}
	envelope, err := reservation.NewEnvelope(wantEnvelope.RequestID, now, replayNonce)
	if err != nil {
		t.Fatal(err)
	}
	publicKey, _ := record.EncryptionPublicKey()
	envelope, err = envelope.Encrypt([]byte(plaintext), publicKey, buyerPrivate)
	if err != nil {
		t.Fatal(err)
	}
	if !reflect.DeepEqual(envelope, wantEnvelope) {
		t.Fatalf("generated envelope differs from golden fixture")
	}
	decrypted, err := envelope.Decrypt(providerPrivate)
	if err != nil || string(decrypted) != plaintext {
		t.Fatalf("golden decrypt: %v", err)
	}
	aad, _ := envelope.AAD()
	immutable, _ := record.ImmutableFraming()
	signed, _ := record.SignedFraming()
	for name, got := range map[string]string{"aad_hex": hex.EncodeToString(aad), "immutable_framing_hex": hex.EncodeToString(immutable), "signed_framing_hex": hex.EncodeToString(signed)} {
		var want string
		if err := json.Unmarshal(fixture[name], &want); err != nil {
			t.Fatal(err)
		}
		if got != want {
			i := 0
			for i < len(got) && i < len(want) && got[i] == want[i] {
				i++
			}
			endGot, endWant := i+80, i+80
			if endGot > len(got) {
				endGot = len(got)
			}
			if endWant > len(want) {
				endWant = len(want)
			}
			t.Fatalf("%s mismatch at %d (got len %d, want len %d) got=%q want=%q", name, i, len(got), len(want), got[i:endGot], want[i:endWant])
		}
	}
}

func fixtureBytes(t *testing.T, fixture map[string]json.RawMessage, name string) []byte {
	t.Helper()
	var encoded string
	if err := json.Unmarshal(fixture[name], &encoded); err != nil {
		t.Fatal(err)
	}
	decoded, err := base64.RawURLEncoding.Strict().DecodeString(encoded)
	if err != nil {
		t.Fatal(err)
	}
	return decoded
}

func TestClosedJSONAndCanonicalEncoding(t *testing.T) {
	now := time.Unix(1_700_000_000, 0).UTC()
	record, _, _ := testRecord(t, now)
	reservation := testReservation(record, now)
	raw, _ := json.Marshal(reservation)
	cases := map[string][]byte{
		"unknown":          bytes.Replace(raw, []byte("{"), []byte("{\"unknown\":1,"), 1),
		"missing":          bytes.Replace(raw, []byte("\"version\":\"relay-blind-reservation-v1\","), nil, 1),
		"null":             bytes.Replace(raw, []byte("\"provider_binding\":\""+reservation.ProviderBinding+"\""), []byte("\"provider_binding\":null"), 1),
		"duplicate nested": bytes.Replace(raw, []byte("\"alg\":"), []byte("\"alg\":\"bad\",\"alg\":"), 1),
		"padded base64":    bytes.Replace(raw, []byte(reservation.ProviderBinding), []byte(reservation.ProviderBinding+"="), 1),
	}
	for name, candidate := range cases {
		t.Run(name, func(t *testing.T) {
			if _, err := ParseReservationResponse(candidate); err == nil {
				t.Fatal("invalid JSON accepted")
			}
		})
	}

	request := []byte("{\"endpoint_family\":\"chat_completions\",\"model\":\"model-a\",\"stream\":false,\"max_output_tokens\":32,\"input_token_upper_bound\":96,\"encrypted_request_bytes\":200}")
	if _, err := ParseReservationRequest(request); err != nil {
		t.Fatalf("request rejected: %v", err)
	}
	for _, candidate := range [][]byte{
		bytes.Replace(request, []byte("\"stream\":false"), []byte("\"stream\":null"), 1),
		bytes.Replace(request, []byte("\"max_output_tokens\":32"), []byte("\"max_output_tokens\":3.2"), 1),
		bytes.Replace(request, []byte("\"model\":\"model-a\""), []byte("\"model\":\"model-a\",\"model\":\"model-b\""), 1),
	} {
		if _, err := ParseReservationRequest(candidate); err == nil {
			t.Fatal("malformed reservation accepted")
		}
	}
}

func TestReservationResponseAllowsTighterRequestBound(t *testing.T) {
	now := time.Unix(1_700_000_000, 0).UTC()
	record, _, _ := testRecord(t, now)
	response := testReservation(record, now)
	request := ReservationRequest{
		EndpointFamily: EndpointChatCompletions, Model: "model-a", Stream: false,
		MaxOutputTokens: 32, InputTokenUpperBound: 96, EncryptedRequestBytes: 200,
	}
	response.MaxEncryptedRequestBytes = 200
	if err := response.Validate(); err != nil {
		t.Fatalf("tighter response bound rejected: %v", err)
	}
	if err := response.MatchesRequest(request); err != nil {
		t.Fatalf("matching request bound rejected: %v", err)
	}
	response.MaxEncryptedRequestBytes = 199
	if err := response.MatchesRequest(request); err == nil {
		t.Fatal("response bound below declared encrypted bytes accepted")
	}
	response.MaxEncryptedRequestBytes = record.MaxEncryptedRequestBytes + 1
	if err := response.Validate(); err == nil {
		t.Fatal("response bound above signed key maximum accepted")
	}
}

func TestClosedStatusMessages(t *testing.T) {
	digest := base64.RawURLEncoding.EncodeToString(bytes.Repeat([]byte{0x42}, sha256.Size))
	requestRaw := []byte(`{"provider_binding_digest":"` + digest + `","envelope_digest":"` + digest + `"}`)
	if _, err := ParseStatusRequest(requestRaw); err != nil {
		t.Fatalf("status request rejected: %v", err)
	}
	for name, raw := range map[string][]byte{
		"unknown":   bytes.Replace(requestRaw, []byte("}"), []byte(`,"extra":true}`), 1),
		"missing":   []byte(`{"provider_binding_digest":"` + digest + `"}`),
		"duplicate": []byte(`{"provider_binding_digest":"` + digest + `","envelope_digest":"` + digest + `","envelope_digest":"` + digest + `"}`),
		"trailing":  append(append([]byte(nil), requestRaw...), []byte(" true")...),
	} {
		t.Run("request_"+name, func(t *testing.T) {
			if _, err := ParseStatusRequest(raw); err == nil {
				t.Fatal("invalid status request accepted")
			}
		})
	}

	input, completion := int64(4), int64(8)
	responses := []StatusResponse{
		{Version: StatusVersion, State: "consumed_predispatch", EffectivePrivacyOutcome: "relay_blind_unavailable", RetryAction: RetryDoNotResubmit},
		{Version: StatusVersion, State: "dispatched", InternalRequestID: "internal-1", Validated: true, InputTokens: &input, EffectivePrivacyOutcome: "relay_blind_satisfied", RetryAction: RetryDoNotResubmit},
		{Version: StatusVersion, State: "terminal", InternalRequestID: "internal-1", Validated: true, InputTokens: &input, CompletionTokens: &completion, EffectivePrivacyOutcome: "relay_blind_satisfied", RetryAction: RetryDoNotResubmit},
	}
	for _, response := range responses {
		raw, err := json.Marshal(response)
		if err != nil {
			t.Fatal(err)
		}
		if _, err := ParseStatusResponse(raw); err != nil {
			t.Fatalf("valid status response rejected: %s: %v", raw, err)
		}
	}

	validRaw, _ := json.Marshal(responses[2])
	invalid := map[string][]byte{
		"unknown":               bytes.Replace(validRaw, []byte("}"), []byte(`,"prompt_tokens":4}`), 1),
		"missing":               bytes.Replace(validRaw, []byte(`,"retry_action":"do_not_resubmit"`), nil, 1),
		"duplicate":             bytes.Replace(validRaw, []byte(`"state":"terminal"`), []byte(`"state":"terminal","state":"dispatched"`), 1),
		"trailing":              append(append([]byte(nil), validRaw...), []byte("{}")...),
		"null_nonnullable":      bytes.Replace(validRaw, []byte(`"state":"terminal"`), []byte(`"state":null`), 1),
		"unvalidated_has_input": bytes.Replace(validRaw, []byte(`"validated":true`), []byte(`"validated":false`), 1),
		"terminal_null_output":  bytes.Replace(validRaw, []byte(`"completion_tokens":8`), []byte(`"completion_tokens":null`), 1),
		"wrong_retry":           bytes.Replace(validRaw, []byte(RetryDoNotResubmit), []byte("none"), 1),
	}
	for name, raw := range invalid {
		t.Run("response_"+name, func(t *testing.T) {
			if _, err := ParseStatusResponse(raw); err == nil {
				t.Fatal("invalid status response accepted")
			}
		})
	}
}

func TestKeyRecordRenewalAndSubstitution(t *testing.T) {
	now := time.Unix(1_700_000_000, 0).UTC()
	record, pin, _ := testRecord(t, now)
	seed := make([]byte, ed25519.SeedSize)
	for i := range seed {
		seed[i] = byte(i)
	}
	identityPrivate := ed25519.NewKeyFromSeed(seed)
	publicKey, _ := base64.RawURLEncoding.DecodeString(record.PublicKey)
	renewed, err := NewSignedKeyRecord(publicKey, identityPrivate, record.Models, record.MaxEncryptedRequestBytes, time.Unix(record.NotBeforeUnix, 0), time.Unix(record.ExpiresAtUnix+60, 0))
	if err != nil {
		t.Fatal(err)
	}
	if err := ValidateKeyRenewal(record, renewed, pin, now); err != nil {
		t.Fatalf("renewal rejected: %v", err)
	}
	substituted, err := NewSignedKeyRecord(publicKey, identityPrivate, []string{"model-b"}, record.MaxEncryptedRequestBytes, time.Unix(record.NotBeforeUnix, 0), time.Unix(record.ExpiresAtUnix+60, 0))
	if err != nil {
		t.Fatal(err)
	}
	substituted.KID = record.KID
	if err := ValidateKeyRenewal(record, substituted, pin, now); err == nil {
		t.Fatal("substitution accepted")
	}
}

func TestIdentityPinAndRecordFailClosed(t *testing.T) {
	now := time.Unix(1_700_000_000, 0).UTC()
	record, pin, _ := testRecord(t, now)
	cases := map[string]IdentityPin{
		"revoked":     func() IdentityPin { p := pin; p.Revoked = true; return p }(),
		"expired":     func() IdentityPin { p := pin; p.ExpiresAtUnix = now.Unix(); return p }(),
		"model scope": func() IdentityPin { p := pin; p.Models = []string{"model-b"}; return p }(),
	}
	for name, candidate := range cases {
		t.Run(name, func(t *testing.T) {
			if err := record.Verify(candidate, now); err == nil {
				t.Fatal("invalid pin accepted")
			}
		})
	}
	tampered := record
	tampered.Signature = base64.RawURLEncoding.EncodeToString(bytes.Repeat([]byte{0x99}, ed25519.SignatureSize))
	if err := tampered.Verify(pin, now); err == nil {
		t.Fatal("invalid signature accepted")
	}
}

func TestReadIdentityPinRejectsSymlinksAndPermissions(t *testing.T) {
	now := time.Now().UTC()
	_, pin, _ := testRecord(t, now)
	raw, _ := json.Marshal(pin)
	dir := t.TempDir()
	dir, err := filepath.EvalSymlinks(dir)
	if err != nil {
		t.Fatal(err)
	}
	if err := os.Chmod(dir, 0o700); err != nil {
		t.Fatal(err)
	}
	path := filepath.Join(dir, "pin.json")
	if err := os.WriteFile(path, raw, 0o600); err != nil {
		t.Fatal(err)
	}
	if _, err := ReadIdentityPin(path); err != nil {
		t.Fatalf("valid pin rejected: %v", err)
	}
	link := filepath.Join(dir, "link.json")
	if err := os.Symlink(path, link); err != nil {
		t.Fatal(err)
	}
	if _, err := ReadIdentityPin(link); err == nil {
		t.Fatal("symlink pin accepted")
	}
	realParent := filepath.Join(dir, "real")
	if err := os.Mkdir(realParent, 0o700); err != nil {
		t.Fatal(err)
	}
	parentPin := filepath.Join(realParent, "pin.json")
	if err := os.WriteFile(parentPin, raw, 0o600); err != nil {
		t.Fatal(err)
	}
	linkedParent := filepath.Join(dir, "linked")
	if err := os.Symlink(realParent, linkedParent); err != nil {
		t.Fatal(err)
	}
	if _, err := ReadIdentityPin(filepath.Join(linkedParent, "pin.json")); err == nil {
		t.Fatal("symlink parent accepted")
	}
	if err := os.Chmod(path, 0o622); err != nil {
		t.Fatal(err)
	}
	if _, err := ReadIdentityPin(path); err == nil {
		t.Fatal("writable pin accepted")
	}
	if err := os.Chmod(path, 0o600); err != nil {
		t.Fatal(err)
	}
	if err := os.Chmod(dir, 0o722); err != nil {
		t.Fatal(err)
	}
	if _, err := ReadIdentityPin(path); err == nil {
		t.Fatal("writable parent accepted")
	}
	if err := os.Chmod(dir, 0o700); err != nil {
		t.Fatal(err)
	}
	large := filepath.Join(dir, "large.json")
	if err := os.WriteFile(large, []byte(strings.Repeat("x", maxIdentityPinBytes+1)), 0o600); err != nil {
		t.Fatal(err)
	}
	if _, err := ReadIdentityPin(large); err == nil {
		t.Fatal("oversize pin accepted")
	}
}

func testRecord(t *testing.T, now time.Time) (KeyRecord, IdentityPin, *ecdh.PrivateKey) {
	t.Helper()
	seed := make([]byte, ed25519.SeedSize)
	for i := range seed {
		seed[i] = byte(i)
	}
	identityPrivate := ed25519.NewKeyFromSeed(seed)
	providerPrivate, err := ecdh.X25519().NewPrivateKey(bytes.Repeat([]byte{0x11}, 32))
	if err != nil {
		t.Fatal(err)
	}
	record, err := NewSignedKeyRecord(providerPrivate.PublicKey().Bytes(), identityPrivate, []string{"model-a"}, 4096, now.Add(-time.Minute), now.Add(time.Hour))
	if err != nil {
		t.Fatal(err)
	}
	identityPublic := identityPrivate.Public().(ed25519.PublicKey)
	fingerprint := sha256.Sum256(identityPublic)
	pin := IdentityPin{
		Version: PinVersion, IdentityPublicKey: base64.RawURLEncoding.EncodeToString(identityPublic),
		Fingerprint: base64.RawURLEncoding.EncodeToString(fingerprint[:]), Models: []string{"model-a"},
		EndpointFamilies: []string{EndpointChatCompletions}, NotBeforeUnix: now.Add(-time.Hour).Unix(),
		ExpiresAtUnix: now.Add(2 * time.Hour).Unix(), Revoked: false,
	}
	return record, pin, providerPrivate
}

func testReservation(record KeyRecord, now time.Time) ReservationResponse {
	return ReservationResponse{
		Version:         ReservationVersion,
		ProviderBinding: base64.RawURLEncoding.EncodeToString(bytes.Repeat([]byte{0x33}, 32)),
		BuyerBinding:    base64.RawURLEncoding.EncodeToString(bytes.Repeat([]byte{0x44}, 32)),
		KeyRecordDigest: record.KeyRecordDigest, KeyRecord: record, KID: record.KID,
		EndpointFamily: EndpointChatCompletions, Model: "model-a", ProviderModel: "model-a",
		Stream: false, MaxEncryptedRequestBytes: record.MaxEncryptedRequestBytes,
		MaxOutputTokens: 32, InputTokenUpperBound: 96, ReservationTokenCap: 128,
		ExpiresAtUnix: now.Add(30 * time.Second).Unix(), CachePolicy: CachePolicyNoStore,
		FailoverPolicy: FailoverPolicyDisabled,
	}
}
