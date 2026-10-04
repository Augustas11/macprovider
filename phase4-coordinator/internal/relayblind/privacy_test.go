package relayblind

import (
	"bytes"
	"crypto/ecdh"
	"crypto/ed25519"
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"os"
	"reflect"
	"sort"
	"strconv"
	"testing"
	"time"
)

const (
	privacyFixtureRel = "../../../test/fixtures/relay-blind/privacy-response-v1.json"
	goldenFixtureRel  = "../../../test/fixtures/relay-blind/golden-v1.json"
	fixtureCDHash     = "0123456789abcdef0123456789abcdef01234567"
	fixtureBinary     = "0.0.0-fixture"
	fixtureTeamID     = "AB12CD34EF"
)

func TestPrivacyGoldenVectorGenerate(t *testing.T) {
	if os.Getenv("MACPROVIDER_REGEN_FIXTURES") != "1" {
		t.Skip("set MACPROVIDER_REGEN_FIXTURES=1 to regenerate privacy-response-v1.json")
	}
	if err := os.WriteFile(privacyFixtureRel, privacyFixtureBytes(t), 0o644); err != nil {
		t.Fatal(err)
	}
}

func TestPrivacyGoldenVector(t *testing.T) {
	want := privacyFixtureBytes(t)
	got, err := os.ReadFile(privacyFixtureRel)
	if err != nil {
		t.Fatal(err)
	}
	if !bytes.Equal(got, want) {
		n := len(got)
		if len(want) < n {
			n = len(want)
		}
		i := 0
		for i < n && got[i] == want[i] {
			i++
		}
		t.Fatalf("privacy fixture mismatch at byte %d (file %d, want %d)", i, len(got), len(want))
	}
	var loaded privacyVector
	if err := json.Unmarshal(got, &loaded); err != nil {
		t.Fatal(err)
	}
	keys, digest, kid, requestID, stream := goldenResponseMaterial(t)
	if loaded.EnvelopeDigest != digest || loaded.KID != kid || loaded.RequestID != requestID || loaded.Stream != stream {
		t.Fatal("fixture context drifted from golden envelope")
	}
	if encodeBase64URL(keys.Key[:]) != loaded.ResponseKey || encodeBase64URL(keys.NoncePrefix[:]) != loaded.NoncePrefix {
		t.Fatal("fixture response keys drifted")
	}
	frames := make([]PrivacyFrame, len(loaded.Frames))
	for i, item := range loaded.Frames {
		frames[i] = item.Frame
		aad := ResponseAAD(digest, kid, requestID, stream, item.Frame.Seq, item.Frame.Final)
		if hex.EncodeToString(aad) != item.AADHex {
			t.Fatalf("frame %d AAD mismatch", i)
		}
		opened, err := OpenFrame(keys, digest, kid, requestID, stream, item.Frame)
		if err != nil {
			t.Fatalf("frame %d: %v", i, err)
		}
		if string(opened) != item.PlaintextUTF8 {
			t.Fatalf("frame %d plaintext mismatch", i)
		}
	}
	if err := ValidatePrivacyFrameSequence(frames); err != nil {
		t.Fatal(err)
	}
	finalRaw := []byte(loaded.Frames[len(loaded.Frames)-1].PlaintextUTF8)
	final, err := ParsePrivacyFinal(finalRaw)
	if err != nil || final.Status != PrivacyFinalStatusComplete || final.PromptTokens != 4 || final.CompletionTokens != 8 {
		t.Fatalf("final frame: %+v %v", final, err)
	}
	framed, err := loaded.Posture.Framing()
	if err != nil || hex.EncodeToString(framed) != loaded.PostureFramingHex {
		t.Fatal("posture framing mismatch")
	}
	if _, err := ParsePostureStatement(mustJSON(t, loaded.Posture)); err != nil {
		t.Fatal(err)
	}
	attestationFramed, err := loaded.KeyAttestation.Framing()
	if err != nil || hex.EncodeToString(attestationFramed) != loaded.KeyAttestationFramingHex {
		t.Fatal("attestation framing mismatch")
	}
	pin := goldenPin(t)
	if err := loaded.KeyAttestation.Verify(pin, loaded.KeyAttestationSignature, loaded.PrivacyKeyRecord.KeyRecord); err != nil {
		t.Fatal(err)
	}
	parsedRecord, err := ParsePrivacyKeyRecord(mustJSON(t, loaded.PrivacyKeyRecord))
	if err != nil || !reflect.DeepEqual(parsedRecord, loaded.PrivacyKeyRecord) {
		t.Fatalf("privacy key record: %v", err)
	}
}

func TestPrivacyFrameTamperSeqReorderTruncate(t *testing.T) {
	keys, digest, kid, requestID, stream := goldenResponseMaterial(t)
	plaintexts := [][]byte{
		[]byte(`{"id":"fixture","choices":[{"message":{"content":"one"}}]}`),
		[]byte("data: {\"choices\":[{\"delta\":{\"content\":\"two\"}}]}\n\n"),
		mustFinal(t, PrivacyFinalStatusComplete, 3, 5),
	}
	frames := make([]PrivacyFrame, len(plaintexts))
	for i, plaintext := range plaintexts {
		frame, err := SealFrame(keys, digest, kid, requestID, stream, uint64(i), i == len(plaintexts)-1, plaintext)
		if err != nil {
			t.Fatal(err)
		}
		opened, err := OpenFrame(keys, digest, kid, requestID, stream, frame)
		if err != nil || !bytes.Equal(opened, plaintext) {
			t.Fatalf("frame %d round trip: %v", i, err)
		}
		raw, err := json.Marshal(frame)
		if err != nil {
			t.Fatal(err)
		}
		parsed, err := ParsePrivacyFrame(raw)
		if err != nil || !reflect.DeepEqual(parsed, frame) {
			t.Fatalf("frame %d parse: %v", i, err)
		}
		frames[i] = frame
	}
	if err := ValidatePrivacyFrameSequence(frames); err != nil {
		t.Fatal(err)
	}

	tampered := frames[0]
	sealed, _ := decodeBase64URL(tampered.Ciphertext)
	sealed[0] ^= 0x01
	tampered.Ciphertext = encodeBase64URL(sealed)
	if _, err := OpenFrame(keys, digest, kid, requestID, stream, tampered); err == nil {
		t.Fatal("tampered ciphertext opened")
	}
	short := frames[1]
	sealed, _ = decodeBase64URL(short.Ciphertext)
	short.Ciphertext = encodeBase64URL(sealed[:len(sealed)-1])
	if _, err := OpenFrame(keys, digest, kid, requestID, stream, short); err == nil {
		t.Fatal("truncated ciphertext opened")
	}
	moved := frames[0]
	moved.Seq = 1
	if _, err := OpenFrame(keys, digest, kid, requestID, stream, moved); err == nil {
		t.Fatal("seq-reordered frame opened")
	}
	if _, err := OpenFrame(keys, digest, kid, requestID, !stream, frames[0]); err == nil {
		t.Fatal("stream bit ignored")
	}
	swapped := []PrivacyFrame{frames[1], frames[0], frames[2]}
	if err := ValidatePrivacyFrameSequence(swapped); err == nil {
		t.Fatal("reordered sequence accepted")
	}
	if err := ValidatePrivacyFrameSequence(frames[:len(frames)-1]); err == nil {
		t.Fatal("truncated sequence accepted")
	}
	trailing, err := SealFrame(keys, digest, kid, requestID, stream, uint64(len(frames)), false, []byte("after"))
	if err != nil {
		t.Fatal(err)
	}
	if err := ValidatePrivacyFrameSequence(append(append([]PrivacyFrame{}, frames...), trailing)); err == nil {
		t.Fatal("frame after final accepted")
	}
	if _, err := SealFrame(keys, digest, kid, requestID, stream, 1<<32, false, []byte("x")); err == nil {
		t.Fatal("seq 2^32 accepted")
	}

	raw, _ := json.Marshal(frames[0])
	for name, candidate := range map[string][]byte{
		"unknown":   bytes.Replace(raw, []byte("{"), []byte(`{"extra":1,`), 1),
		"duplicate": bytes.Replace(raw, []byte(`"object":`), []byte(`"object":"x","object":`), 1),
		"null":      bytes.Replace(raw, []byte(`"final":false`), []byte(`"final":null`), 1),
		"float seq": bytes.Replace(raw, []byte(`"seq":0`), []byte(`"seq":0.5`), 1),
		"trailing":  append(append([]byte(nil), raw...), []byte(" true")...),
	} {
		t.Run(name, func(t *testing.T) {
			if _, err := ParsePrivacyFrame(candidate); err == nil {
				t.Fatal("invalid frame accepted")
			}
		})
	}
	finalRaw := mustFinal(t, PrivacyFinalStatusError, 0, 0)
	if _, err := ParsePrivacyFinal(finalRaw); err != nil {
		t.Fatal(err)
	}
	for name, candidate := range map[string][]byte{
		"status":   bytes.Replace(finalRaw, []byte(`"status":"error"`), []byte(`"status":"ok"`), 1),
		"negative": bytes.Replace(finalRaw, []byte(`"prompt_tokens":0`), []byte(`"prompt_tokens":-1`), 1),
		"float":    bytes.Replace(finalRaw, []byte(`"completion_tokens":0`), []byte(`"completion_tokens":1.0`), 1),
		"unknown":  bytes.Replace(finalRaw, []byte("{"), []byte(`{"extra":1,`), 1),
	} {
		t.Run("final_"+name, func(t *testing.T) {
			if _, err := ParsePrivacyFinal(candidate); err == nil {
				t.Fatal("invalid final accepted")
			}
		})
	}
}

func TestPrivacyResponseKeysDistinctFromRequestKeys(t *testing.T) {
	fixture := readGolden(t)
	aad, err := hex.DecodeString(jsonString(t, fixture, "aad_hex"))
	if err != nil {
		t.Fatal(err)
	}
	shared := fixtureBytes(t, fixture, "shared_secret")
	requestKey := fixtureBytes(t, fixture, "request_key")
	keys, err := DeriveResponseKeys(shared, aad)
	if err != nil {
		t.Fatal(err)
	}
	if bytes.Equal(keys.Key[:], requestKey) {
		t.Fatal("response key equals request key")
	}
	if len(keys.NoncePrefix) != 4 {
		t.Fatal("nonce prefix length")
	}
	if _, err := DeriveResponseKeys(make([]byte, 32), aad); err == nil {
		t.Fatal("all-zero shared secret accepted")
	}
	if _, err := DeriveResponseKeys(shared[:16], aad); err == nil {
		t.Fatal("short shared secret accepted")
	}
	buyerKeys, digest, _, _, _ := goldenResponseMaterial(t)
	if buyerKeys != keys {
		t.Fatal("buyer response keys differ from shared-secret derivation")
	}
	if _, err := decodeBase64URLFixed(digest, sha256.Size); err != nil {
		t.Fatal(err)
	}
	var envelope Envelope
	if err := json.Unmarshal(fixture["envelope"], &envelope); err != nil {
		t.Fatal(err)
	}
	buyer := fixtureBytes(t, fixture, "buyer_x25519_private_key")
	public, err := goldenRecord(t).EncryptionPublicKey()
	if err != nil {
		t.Fatal(err)
	}
	other, err := ecdh.X25519().NewPrivateKey(bytes.Repeat([]byte{0x44}, 32))
	if err != nil {
		t.Fatal(err)
	}
	if _, err := envelope.DeriveBuyerResponseKeys(other.Bytes(), public); err == nil {
		t.Fatal("mismatched buyer key accepted")
	}
	if _, err := envelope.DeriveBuyerResponseKeys(buyer, make([]byte, 32)); err == nil {
		t.Fatal("low-order provider key accepted")
	}
}

func TestPrivacyReservationVersionClosed(t *testing.T) {
	now := time.Unix(1_700_000_000, 0).UTC()
	relayRecord, _, _ := testRecord(t, now)
	relay := testReservation(relayRecord, now)
	relayRaw := mustJSON(t, relay)
	if _, err := ParseReservationResponse(relayRaw); err != nil {
		t.Fatal(err)
	}
	privacy, pin, identity := testPrivacyReservation(t, now)
	privacyRaw := mustJSON(t, privacy)
	parsed, err := ParseReservationResponse(privacyRaw)
	if err != nil {
		t.Fatal(err)
	}
	if !reflect.DeepEqual(parsed, privacy) {
		t.Fatal("privacy reservation round trip")
	}
	if err := privacy.PrivacyKeyAttestation.Verify(pin, privacy.PrivacyKeyAttestationSignature, privacy.KeyRecord); err != nil {
		t.Fatal(err)
	}

	mixed := privacy
	mixed.Version = ReservationVersion
	if _, err := ParseReservationResponse(mustJSON(t, mixed)); err == nil {
		t.Fatal("relay-blind version accepted privacy fields")
	}
	stripped := privacy
	stripped.Version = PrivacyReservationVersion
	stripped.PrivacyClass = ""
	stripped.PrivacyAssurance = ""
	stripped.PrivacyKeyAttestation = nil
	stripped.PrivacyKeyAttestationSignature = ""
	stripped.PrivacyPostureVerifiedAtUnix = 0
	if _, err := ParseReservationResponse(mustJSON(t, stripped)); err == nil {
		t.Fatal("privacy version without extension accepted")
	}
	badDigest := privacy
	clone := *privacy.PrivacyKeyAttestation
	clone.KeyRecordDigest = encodeBase64URL(bytes.Repeat([]byte{0xab}, 32))
	badDigest.PrivacyKeyAttestation = &clone
	if _, err := ParseReservationResponse(mustJSON(t, badDigest)); err == nil {
		t.Fatal("attestation digest mismatch accepted")
	}
	stamp := []byte(`"privacy_posture_verified_at_unix":`)
	zeroed := bytes.Replace(privacyRaw, append(stamp, []byte("1700000000")...), append(stamp, []byte("0")...), 1)
	if _, err := ParseReservationResponse(zeroed); err == nil {
		t.Fatal("zero posture time accepted")
	}
	floated := bytes.Replace(privacyRaw, append(stamp, []byte("1700000000")...), append(stamp, []byte("1.5")...), 1)
	if _, err := ParseReservationResponse(floated); err == nil {
		t.Fatal("non-integer posture time accepted")
	}
	for name, candidate := range map[string][]byte{
		"unknown":   bytes.Replace(privacyRaw, []byte("{"), []byte(`{"extra":1,`), 1),
		"null":      bytes.Replace(privacyRaw, []byte(`"privacy_class":"`+PrivacyClassV1+`"`), []byte(`"privacy_class":null`), 1),
		"duplicate": bytes.Replace(privacyRaw, []byte(`"privacy_assurance":`), []byte(`"privacy_assurance":"x","privacy_assurance":`), 1),
		"missing":   bytes.Replace(privacyRaw, []byte(`"privacy_assurance":"`+PrivacyAssurance+`",`), nil, 1),
		"injected":  bytes.Replace(relayRaw, []byte(`"failover_policy":"disabled"}`), []byte(`"failover_policy":"disabled","privacy_class":"`+PrivacyClassV1+`"}`), 1),
	} {
		t.Run(name, func(t *testing.T) {
			if _, err := ParseReservationResponse(candidate); err == nil {
				t.Fatal("invalid reservation accepted")
			}
		})
	}

	longRecord, err := NewSignedKeyRecord(mustPublic(t, privacy.KeyRecord), identity, privacy.KeyRecord.Models, privacy.KeyRecord.MaxEncryptedRequestBytes, now, now.Add(time.Duration(MaxPrivacyKeyLifetimeSeconds+1)*time.Second))
	if err != nil {
		t.Fatal(err)
	}
	long := privacy
	long.KeyRecord = longRecord
	long.KeyRecordDigest = longRecord.KeyRecordDigest
	long.KID = longRecord.KID
	longAtt := *privacy.PrivacyKeyAttestation
	longAtt.KeyRecordDigest = longRecord.KeyRecordDigest
	longAtt.NotBeforeUnix = longRecord.NotBeforeUnix
	longAtt.ExpiresAtUnix = longRecord.ExpiresAtUnix
	long.PrivacyKeyAttestation = &longAtt
	if _, err := ParseReservationResponse(mustJSON(t, long)); err == nil {
		t.Fatal("privacy key lifetime above 3600s accepted")
	}
}

func TestPostureStatementFramingRejectsUnknownAndUnsorted(t *testing.T) {
	now := time.Unix(1_700_000_000, 0).UTC()
	privacy, _, _ := testPrivacyReservation(t, now)
	second := encodeBase64URL(bytes.Repeat([]byte{0x22}, 32))
	digests := []string{privacy.KeyRecordDigest, second}
	sort.Strings(digests)
	if digests[0] == digests[1] || digests[0] > digests[1] {
		t.Fatal("digest fixtures are not strictly ordered")
	}
	statement := testPosture(privacy.KeyRecordDigest)
	statement.PrivacyKeyRecordDigests = append([]string(nil), digests...)
	raw := mustJSON(t, statement)
	parsed, err := ParsePostureStatement(raw)
	if err != nil {
		t.Fatal(err)
	}
	if !reflect.DeepEqual(parsed, statement) {
		t.Fatal("posture round trip")
	}
	framed, err := statement.Framing()
	if err != nil {
		t.Fatal(err)
	}
	again, err := parsed.Framing()
	if err != nil || !bytes.Equal(framed, again) {
		t.Fatal("posture framing unstable")
	}
	reversed := statement
	reversed.PrivacyKeyRecordDigests = []string{digests[1], digests[0]}
	if _, err := ParsePostureStatement(mustJSON(t, reversed)); err == nil {
		t.Fatal("unsorted digests accepted")
	}
	if _, err := reversed.Framing(); err == nil {
		t.Fatal("unsorted framing produced")
	}
	duplicated := statement
	duplicated.PrivacyKeyRecordDigests = []string{digests[0], digests[0]}
	if _, err := ParsePostureStatement(mustJSON(t, duplicated)); err == nil {
		t.Fatal("duplicate digests accepted")
	}
	many := make([]string, MaxPrivacyKeyRecordDigests+1)
	for i := range many {
		many[i] = encodeBase64URL(bytes.Repeat([]byte{byte(i + 1)}, 32))
	}
	sort.Strings(many)
	tooMany := statement
	tooMany.PrivacyKeyRecordDigests = many
	if _, err := ParsePostureStatement(mustJSON(t, tooMany)); err == nil {
		t.Fatal("nine digests accepted")
	}
	empty := statement
	empty.PrivacyKeyRecordDigests = []string{}
	if _, err := ParsePostureStatement(mustJSON(t, empty)); err != nil {
		t.Fatal(err)
	}
	if _, err := empty.Framing(); err != nil {
		t.Fatal(err)
	}
	nullSet := bytes.Replace(mustJSON(t, empty), []byte(`"privacy_key_record_digests":[]`), []byte(`"privacy_key_record_digests":null`), 1)
	if _, err := ParsePostureStatement(nullSet); err == nil {
		t.Fatal("null digest set accepted")
	}
	failing := statement
	failing.CSDebugged = true
	failing.GetTaskAllow = true
	failing.SIPEnabled = false
	if _, err := ParsePostureStatement(mustJSON(t, failing)); err != nil {
		t.Fatal("schema-valid failing posture rejected")
	}
	bad := statement
	bad.Version = "privacy-posture-v0"
	if _, err := ParsePostureStatement(mustJSON(t, bad)); err == nil {
		t.Fatal("wrong posture version accepted")
	}
	bad = statement
	bad.CodeCDHash = "0123456789ABCDEF0123456789ABCDEF01234567"
	if _, err := ParsePostureStatement(mustJSON(t, bad)); err == nil {
		t.Fatal("uppercase cdhash accepted")
	}
	bad = statement
	bad.TeamID = "SHORT"
	if _, err := ParsePostureStatement(mustJSON(t, bad)); err == nil {
		t.Fatal("short team id accepted")
	}
	bad = statement
	bad.Nonce = encodeBase64URL(bytes.Repeat([]byte{0x5a}, 31))
	if _, err := ParsePostureStatement(mustJSON(t, bad)); err == nil {
		t.Fatal("short nonce accepted")
	}
	bad = statement
	bad.RuntimeSource = "loopback"
	if _, err := ParsePostureStatement(mustJSON(t, bad)); err == nil {
		t.Fatal("runtime source accepted")
	}
	bad = statement
	bad.SEKeyBackend = "memory"
	if _, err := ParsePostureStatement(mustJSON(t, bad)); err == nil {
		t.Fatal("key backend accepted")
	}
	for name, candidate := range map[string][]byte{
		"unknown":   bytes.Replace(raw, []byte("{"), []byte(`{"extra":true,`), 1),
		"missing":   bytes.Replace(raw, []byte(`"privacy_class":"`+PrivacyClassV1+`",`), nil, 1),
		"null":      bytes.Replace(raw, []byte(`"hardened_runtime":true`), []byte(`"hardened_runtime":null`), 1),
		"duplicate": bytes.Replace(raw, []byte(`"version":`), []byte(`"version":"x","version":`), 1),
		"float":     bytes.Replace(raw, []byte(`"sequence":1`), []byte(`"sequence":1.5`), 1),
		"bool":      bytes.Replace(raw, []byte(`"sip_enabled":true`), []byte(`"sip_enabled":1`), 1),
	} {
		t.Run(name, func(t *testing.T) {
			if _, err := ParsePostureStatement(candidate); err == nil {
				t.Fatal("invalid posture accepted")
			}
		})
	}
}

func TestPrivacyKeyAttestationBindsDigest(t *testing.T) {
	now := time.Unix(1_700_000_000, 0).UTC()
	privacy, pin, identity := testPrivacyReservation(t, now)
	attestation := *privacy.PrivacyKeyAttestation
	if err := attestation.Verify(pin, privacy.PrivacyKeyAttestationSignature, privacy.KeyRecord); err != nil {
		t.Fatal(err)
	}
	otherPublic := bytes.Repeat([]byte{0x23}, 32)
	other, err := NewSignedKeyRecord(otherPublic, identity, privacy.KeyRecord.Models, privacy.KeyRecord.MaxEncryptedRequestBytes, now, now.Add(1800*time.Second))
	if err != nil {
		t.Fatal(err)
	}
	if other.KeyRecordDigest == privacy.KeyRecordDigest {
		t.Fatal("distinct records produced one digest")
	}
	if err := attestation.Verify(pin, privacy.PrivacyKeyAttestationSignature, other); err == nil {
		t.Fatal("attestation verified against a different record")
	}
	rebound := attestation
	rebound.KeyRecordDigest = other.KeyRecordDigest
	rebound.NotBeforeUnix = other.NotBeforeUnix
	rebound.ExpiresAtUnix = other.ExpiresAtUnix
	resigned := signAttestation(t, identity, rebound)
	if err := rebound.Verify(pin, resigned, privacy.KeyRecord); err == nil {
		t.Fatal("re-signed digest accepted for the original record")
	}
	if err := rebound.Verify(pin, resigned, other); err != nil {
		t.Fatal(err)
	}
	sig, _ := decodeBase64URL(privacy.PrivacyKeyAttestationSignature)
	sig[0] ^= 0xff
	if err := attestation.Verify(pin, encodeBase64URL(sig), privacy.KeyRecord); err == nil {
		t.Fatal("tampered signature accepted")
	}
	revoked := pin
	revoked.Revoked = true
	if err := attestation.Verify(revoked, privacy.PrivacyKeyAttestationSignature, privacy.KeyRecord); err == nil {
		t.Fatal("revoked pin accepted")
	}
	long := attestation
	long.ExpiresAtUnix = long.NotBeforeUnix + MaxPrivacyKeyLifetimeSeconds + 1
	if _, err := long.Framing(); err == nil {
		t.Fatal("lifetime above 3600s framed")
	}
	exact := attestation
	exact.ExpiresAtUnix = exact.NotBeforeUnix + MaxPrivacyKeyLifetimeSeconds
	exact.KeyRecordDigest = privacy.KeyRecordDigest
	if privacy.KeyRecord.ExpiresAtUnix-privacy.KeyRecord.NotBeforeUnix != MaxPrivacyKeyLifetimeSeconds {
		t.Fatal("fixture window is not exactly 3600s")
	}
	if _, err := exact.Framing(); err != nil {
		t.Fatal(err)
	}
}

type privacyVector struct {
	Version                  string                `json:"version"`
	SourceFixture            string                `json:"source_fixture"`
	EnvelopeDigest           string                `json:"envelope_digest"`
	ResponseKey              string                `json:"response_key"`
	NoncePrefix              string                `json:"nonce_prefix"`
	RequestID                string                `json:"request_id"`
	KID                      string                `json:"kid"`
	Stream                   bool                  `json:"stream"`
	Frames                   []privacyVectorFrame  `json:"frames"`
	Posture                  PostureStatement      `json:"posture"`
	PostureFramingHex        string                `json:"posture_framing_hex"`
	KeyAttestation           PrivacyKeyAttestation `json:"key_attestation"`
	KeyAttestationFramingHex string                `json:"key_attestation_framing_hex"`
	KeyAttestationSignature  string                `json:"key_attestation_signature"`
	PrivacyKeyRecord         PrivacyKeyRecord      `json:"privacy_key_record"`
}

type privacyVectorFrame struct {
	PlaintextUTF8 string       `json:"plaintext_utf8"`
	AADHex        string       `json:"aad_hex"`
	Frame         PrivacyFrame `json:"frame"`
}

func privacyFixtureBytes(t *testing.T) []byte {
	t.Helper()
	vector := buildPrivacyVector(t)
	raw, err := json.MarshalIndent(vector, "", "  ")
	if err != nil {
		t.Fatal(err)
	}
	return append(raw, '\n')
}

func buildPrivacyVector(t *testing.T) privacyVector {
	t.Helper()
	fixture := readGolden(t)
	keys, digest, kid, requestID, stream := goldenResponseMaterial(t)
	var goldenRecord KeyRecord
	if err := json.Unmarshal(fixture["key_record"], &goldenRecord); err != nil {
		t.Fatal(err)
	}
	public, err := goldenRecord.EncryptionPublicKey()
	if err != nil {
		t.Fatal(err)
	}
	identity := ed25519.NewKeyFromSeed(fixtureBytes(t, fixture, "identity_seed"))
	notBefore := time.Unix(goldenRecord.NotBeforeUnix, 0)
	expires := notBefore.Add(time.Duration(MaxPrivacyKeyLifetimeSeconds) * time.Second)
	record, err := NewSignedKeyRecord(public, identity, goldenRecord.Models, goldenRecord.MaxEncryptedRequestBytes, notBefore, expires)
	if err != nil {
		t.Fatal(err)
	}
	if record.KID != goldenRecord.KID {
		t.Fatal("privacy record changed the golden immutable key")
	}
	pin := goldenPin(t)
	if err := record.Verify(pin, time.Unix(1700000000, 0)); err != nil {
		t.Fatal(err)
	}
	attestation := PrivacyKeyAttestation{
		Version: PrivacyKeyAttestationVersion, KeyRecordDigest: record.KeyRecordDigest,
		PrivacyClass: PrivacyClassV1, Assurance: PrivacyAssurance, BinaryVersion: fixtureBinary,
		CodeCDHash: fixtureCDHash, NotBeforeUnix: record.NotBeforeUnix, ExpiresAtUnix: record.ExpiresAtUnix,
	}
	signature := signAttestation(t, identity, attestation)
	if err := attestation.Verify(pin, signature, record); err != nil {
		t.Fatal(err)
	}
	attestationFraming, err := attestation.Framing()
	if err != nil {
		t.Fatal(err)
	}
	posture := testPosture(record.KeyRecordDigest)
	postureFraming, err := posture.Framing()
	if err != nil {
		t.Fatal(err)
	}
	finalBody := mustFinal(t, PrivacyFinalStatusComplete, 4, 8)
	plaintexts := [][]byte{
		[]byte(`{"id":"fixture","object":"chat.completion","choices":[{"message":{"role":"assistant","content":"ok"}}]}`),
		[]byte("data: {\"object\":\"chat.completion.chunk\",\"choices\":[{\"delta\":{\"content\":\"ok\"}}]}\n\n"),
		finalBody,
	}
	frames := make([]privacyVectorFrame, len(plaintexts))
	sealed := make([]PrivacyFrame, len(plaintexts))
	var previous []byte
	for i, plaintext := range plaintexts {
		final := i == len(plaintexts)-1
		frame, err := SealFrame(keys, digest, kid, requestID, stream, uint64(i), final, plaintext)
		if err != nil {
			t.Fatal(err)
		}
		opened, err := OpenFrame(keys, digest, kid, requestID, stream, frame)
		if err != nil || !bytes.Equal(opened, plaintext) {
			t.Fatalf("frame %d: %v", i, err)
		}
		aad := ResponseAAD(digest, kid, requestID, stream, uint64(i), final)
		if bytes.Equal(aad, previous) {
			t.Fatal("frame AAD repeated")
		}
		previous = append([]byte(nil), aad...)
		sealed[i] = frame
		frames[i] = privacyVectorFrame{PlaintextUTF8: string(plaintext), AADHex: hex.EncodeToString(aad), Frame: frame}
	}
	if err := ValidatePrivacyFrameSequence(sealed); err != nil {
		t.Fatal(err)
	}
	privacyRecord := PrivacyKeyRecord{KeyRecord: record, Attestation: attestation, Signature: signature}
	if _, err := ParsePrivacyKeyRecord(mustJSON(t, privacyRecord)); err != nil {
		t.Fatal(err)
	}
	requestKey := fixtureBytes(t, fixture, "request_key")
	if bytes.Equal(keys.Key[:], requestKey) {
		t.Fatal("response key collides with request key")
	}
	return privacyVector{
		Version: PrivacyResponseVersion, SourceFixture: "golden-v1.json", EnvelopeDigest: digest,
		ResponseKey: encodeBase64URL(keys.Key[:]), NoncePrefix: encodeBase64URL(keys.NoncePrefix[:]),
		RequestID: requestID, KID: kid, Stream: stream, Frames: frames, Posture: posture,
		PostureFramingHex: hex.EncodeToString(postureFraming), KeyAttestation: attestation,
		KeyAttestationFramingHex: hex.EncodeToString(attestationFraming), KeyAttestationSignature: signature,
		PrivacyKeyRecord: privacyRecord,
	}
}

func goldenResponseMaterial(t *testing.T) (ResponseKeys, string, string, string, bool) {
	t.Helper()
	fixture := readGolden(t)
	var envelope Envelope
	if err := json.Unmarshal(fixture["envelope"], &envelope); err != nil {
		t.Fatal(err)
	}
	aad, err := envelope.AAD()
	if err != nil {
		t.Fatal(err)
	}
	if hex.EncodeToString(aad) != jsonString(t, fixture, "aad_hex") {
		t.Fatal("golden envelope AAD mismatch")
	}
	digest, err := envelope.Digest()
	if err != nil {
		t.Fatal(err)
	}
	public, err := goldenRecord(t).EncryptionPublicKey()
	if err != nil {
		t.Fatal(err)
	}
	buyer := fixtureBytes(t, fixture, "buyer_x25519_private_key")
	keys, err := envelope.DeriveBuyerResponseKeys(buyer, public)
	if err != nil {
		t.Fatal(err)
	}
	shared := fixtureBytes(t, fixture, "shared_secret")
	direct, err := DeriveResponseKeys(shared, aad)
	if err != nil {
		t.Fatal(err)
	}
	if direct != keys {
		t.Fatal("derived response keys disagree")
	}
	return keys, digest, envelope.KID, envelope.RequestID, envelope.Stream
}

func readGolden(t *testing.T) map[string]json.RawMessage {
	t.Helper()
	raw, err := os.ReadFile(goldenFixtureRel)
	if err != nil {
		t.Fatal(err)
	}
	var fixture map[string]json.RawMessage
	if err := json.Unmarshal(raw, &fixture); err != nil {
		t.Fatal(err)
	}
	return fixture
}

func goldenRecord(t *testing.T) KeyRecord {
	t.Helper()
	var record KeyRecord
	if err := json.Unmarshal(readGolden(t)["key_record"], &record); err != nil {
		t.Fatal(err)
	}
	return record
}

func goldenPin(t *testing.T) IdentityPin {
	t.Helper()
	var pin IdentityPin
	if err := json.Unmarshal(readGolden(t)["pin"], &pin); err != nil {
		t.Fatal(err)
	}
	return pin
}

func jsonString(t *testing.T, fixture map[string]json.RawMessage, name string) string {
	t.Helper()
	var value string
	if err := json.Unmarshal(fixture[name], &value); err != nil {
		t.Fatal(err)
	}
	return value
}

func testPrivacyReservation(t *testing.T, now time.Time) (ReservationResponse, IdentityPin, ed25519.PrivateKey) {
	t.Helper()
	record, pin, identity := testPrivacyMaterial(t, now)
	attestation := PrivacyKeyAttestation{
		Version: PrivacyKeyAttestationVersion, KeyRecordDigest: record.KeyRecordDigest,
		PrivacyClass: PrivacyClassV1, Assurance: PrivacyAssurance, BinaryVersion: fixtureBinary,
		CodeCDHash: fixtureCDHash, NotBeforeUnix: record.NotBeforeUnix, ExpiresAtUnix: record.ExpiresAtUnix,
	}
	signature := signAttestation(t, identity, attestation)
	reservation := testReservation(record, now)
	reservation.Version = PrivacyReservationVersion
	reservation.PrivacyClass = PrivacyClassV1
	reservation.PrivacyAssurance = PrivacyAssurance
	reservation.PrivacyKeyAttestation = &attestation
	reservation.PrivacyKeyAttestationSignature = signature
	reservation.PrivacyPostureVerifiedAtUnix = now.Unix()
	return reservation, pin, identity
}

func testPrivacyMaterial(t *testing.T, now time.Time) (KeyRecord, IdentityPin, ed25519.PrivateKey) {
	t.Helper()
	seed := make([]byte, ed25519.SeedSize)
	for i := range seed {
		seed[i] = byte(i)
	}
	identity := ed25519.NewKeyFromSeed(seed)
	provider, err := ecdh.X25519().NewPrivateKey(bytes.Repeat([]byte{0x11}, 32))
	if err != nil {
		t.Fatal(err)
	}
	record, err := NewSignedKeyRecord(provider.PublicKey().Bytes(), identity, []string{"model-a"}, 4096, now, now.Add(time.Duration(MaxPrivacyKeyLifetimeSeconds)*time.Second))
	if err != nil {
		t.Fatal(err)
	}
	public := identity.Public().(ed25519.PublicKey)
	sum := sha256.Sum256(public)
	pin := IdentityPin{
		Version: PinVersion, IdentityPublicKey: encodeBase64URL(public), Fingerprint: encodeBase64URL(sum[:]),
		Models: []string{"model-a"}, EndpointFamilies: []string{EndpointChatCompletions},
		NotBeforeUnix: now.Add(-time.Hour).Unix(), ExpiresAtUnix: now.Add(2 * time.Hour).Unix(),
	}
	return record, pin, identity
}

func testPosture(digest string) PostureStatement {
	return PostureStatement{
		Version: PrivacyPostureVersion, PrivacyClass: PrivacyClassV1, ProviderID: "provider-fixture",
		AssignedSession: "session-fixture", Nonce: encodeBase64URL(bytes.Repeat([]byte{0x5a}, 32)),
		Sequence: 1, IssuedAtUnix: 1700000000, BinaryVersion: fixtureBinary, CodeCDHash: fixtureCDHash,
		TeamID: fixtureTeamID, SigningIdentifier: "live.malibu.provider.cli", HardenedRuntime: true,
		LibraryValidation: true, GetTaskAllow: false, CSDebugged: false, PTraced: false,
		PTDenyAttachApplied: true, CoreDumpsDisabled: true, SIPEnabled: true, RuntimeSource: PrivacyRuntimeSource,
		DiagnosticEnvClear: true, KVDiskTierDisabled: true, SEKeyBackend: PrivacySEBackendFile,
		PrivacyKeyRecordDigests: []string{digest},
	}
}

func signAttestation(t *testing.T, key ed25519.PrivateKey, attestation PrivacyKeyAttestation) string {
	t.Helper()
	framed, err := attestation.Framing()
	if err != nil {
		t.Fatal(err)
	}
	return encodeBase64URL(ed25519.Sign(key, framed))
}

func mustFinal(t *testing.T, status string, prompt, completion int64) []byte {
	t.Helper()
	raw, err := (PrivacyFinal{Version: PrivacyFinalVersion, Status: status, PromptTokens: prompt, CompletionTokens: completion}).Marshal()
	if err != nil {
		t.Fatal(err)
	}
	return raw
}

func mustJSON(t *testing.T, value any) []byte {
	t.Helper()
	raw, err := json.Marshal(value)
	if err != nil {
		t.Fatal(err)
	}
	return raw
}

func mustPublic(t *testing.T, record KeyRecord) []byte {
	t.Helper()
	public, err := record.EncryptionPublicKey()
	if err != nil {
		t.Fatal(err)
	}
	return public
}

func privacyOpaqueCiphertext() string {
	return encodeBase64URL(bytes.Repeat([]byte{0x11}, privacyGCMTagSize))
}

func privacyOpaqueFrame(seq uint64, final bool) PrivacyFrame {
	return PrivacyFrame{
		Object: PrivacyFrameObject, Version: PrivacyResponseVersion,
		Seq: seq, Final: final, Ciphertext: privacyOpaqueCiphertext(),
	}
}

func privacyOpaqueResponse(prompt, completion int64) []byte {
	frame0, _ := json.Marshal(privacyOpaqueFrame(0, false))
	frame1, _ := json.Marshal(privacyOpaqueFrame(1, true))
	return []byte(`{"object":"` + PrivacyResponseObject + `","version":"` + PrivacyResponseVersion + `","frames":[` + string(frame0) + `,` + string(frame1) + `],"usage":{"prompt_tokens":` + strconv.FormatInt(prompt, 10) + `,"completion_tokens":` + strconv.FormatInt(completion, 10) + `,"total_tokens":` + strconv.FormatInt(prompt+completion, 10) + `}}`)
}

func TestPrivacyResponseShapeRejectsClearContent(t *testing.T) {
	body := privacyOpaqueResponse(4, 2)
	if err := ValidatePrivacyResponseBody(body); err != nil {
		t.Fatal(err)
	}
	clear := []byte(`{"object":"chat.completion","choices":[{"message":{"content":"CANARY"}}],"usage":{"prompt_tokens":4,"completion_tokens":2,"total_tokens":6}}`)
	if err := ValidatePrivacyResponseBody(clear); err == nil {
		t.Fatal("clear non-stream body accepted")
	}
	if err := ValidatePrivacyResponseBody([]byte(`{"object":"` + PrivacyResponseObject + `","version":"` + PrivacyResponseVersion + `","frames":[],"usage":{"prompt_tokens":1,"completion_tokens":1,"total_tokens":2}}`)); err == nil {
		t.Fatal("empty frame list accepted")
	}
	mismatched := bytes.Replace(body, []byte(`"total_tokens":6`), []byte(`"total_tokens":7`), 1)
	if err := ValidatePrivacyResponseBody(mismatched); err == nil {
		t.Fatal("usage total mismatch accepted")
	}

	var gate PrivacyStreamGate
	frame0, _ := json.Marshal(privacyOpaqueFrame(0, false))
	frame1, _ := json.Marshal(privacyOpaqueFrame(1, true))
	usage := `{"object":"chat.completion.chunk","model":"model-a","choices":[],"usage":{"prompt_tokens":4,"completion_tokens":2,"total_tokens":6}}`
	for _, event := range []struct {
		data string
		kind PrivacyStreamEvent
	}{
		{string(frame0), PrivacyStreamFrame},
		{string(frame1), PrivacyStreamFrame},
		{usage, PrivacyStreamUsage},
		{"[DONE]", PrivacyStreamDone},
	} {
		kind, err := gate.Observe(event.data)
		if err != nil || kind != event.kind {
			t.Fatalf("observe %s kind=%d err=%v", event.data, kind, err)
		}
	}
	if err := gate.Complete(); err != nil {
		t.Fatal(err)
	}
	if _, err := gate.Observe(`{"choices":[{"delta":{"content":"CANARY"}}]}`); err == nil {
		t.Fatal("data after DONE accepted")
	}

	var refused PrivacyStreamGate
	if _, err := refused.Observe(`{"choices":[{"delta":{"content":"CANARY","tool_calls":[]}}]}`); err == nil {
		t.Fatal("clear stream content accepted")
	}
	if err := refused.Complete(); err == nil {
		t.Fatal("incomplete stream completed")
	}
	kind, err := refused.Observe(string(frame0))
	if err != nil || kind != PrivacyStreamFrame {
		t.Fatalf("frame after refusal kind=%d err=%v", kind, err)
	}
	if _, err := refused.Observe(`{"object":"chat.completion.chunk","model":"model-a","choices":[{"delta":{"content":"CANARY"}}],"usage":{"prompt_tokens":1,"completion_tokens":1,"total_tokens":2}}`); err == nil {
		t.Fatal("content-bearing usage chunk accepted")
	}
}
