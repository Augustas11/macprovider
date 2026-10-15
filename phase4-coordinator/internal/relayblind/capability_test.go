package relayblind

import (
	"bytes"
	"crypto/ecdh"
	"crypto/rand"
	"encoding/hex"
	"encoding/json"
	"os"
	"reflect"
	"testing"
	"time"
)

func TestRequiredCapabilitiesFollowsSPEC019Modes(t *testing.T) {
	strictSchema := `{"type":"object","properties":{"name":{"type":"string"}},"required":["name"],"additionalProperties":false}`
	looseSchema := `{"type":"object","properties":{"name":{"type":"string"}}}`
	body := func(format string) []byte {
		return []byte(`{"model":"model-a","messages":[{"role":"user","content":"hi"}],"max_tokens":8,"response_format":` + format + `}`)
	}
	jsonSchema := func(strict, schema string) []byte {
		spec := `"name":"person","schema":` + schema
		if strict != "" {
			spec += `,"strict":` + strict
		}
		return body(`{"type":"json_schema","json_schema":{` + spec + `}}`)
	}
	nonStrict := []string{CapabilityJSONSchemaNonStrict}
	cases := []struct {
		name string
		body []byte
		want []string
	}{
		{"no response_format", []byte(`{"model":"model-a","messages":[]}`), nil},
		{"text", body(`{"type":"text"}`), nil},
		{"json_object", body(`{"type":"json_object"}`), nil},
		{"strict true subset", jsonSchema("true", strictSchema), nil},
		{"strict true outside subset", jsonSchema("true", looseSchema), nil},
		{"strict absent subset", jsonSchema("", strictSchema), nil},
		{"strict null subset", jsonSchema("null", strictSchema), nil},
		{"strict absent outside subset", jsonSchema("", looseSchema), nonStrict},
		{"strict null outside subset", jsonSchema("null", looseSchema), nonStrict},
		{"strict false subset", jsonSchema("false", strictSchema), nonStrict},
		{"strict false outside subset", jsonSchema("false", looseSchema), nonStrict},
		{"strict not boolean", jsonSchema(`"no"`, looseSchema), nil},
		{"schema missing", body(`{"type":"json_schema","json_schema":{"name":"person"}}`), nil},
		{"json_schema not object", body(`{"type":"json_schema","json_schema":[]}`), nil},
		{"malformed body", []byte(`{`), nil},
		{"absent strict unsupported keyword", jsonSchema("", `{"type":"string","pattern":"^a"}`), nonStrict},
		{"absent strict root $schema", jsonSchema("", `{"$schema":"x","type":"string"}`), nil},
		{"absent strict nested $schema", jsonSchema("", `{"type":"array","items":{"$schema":"x","type":"string"}}`), nonStrict},
		{"absent strict bad bounds", jsonSchema("", `{"type":"integer","minimum":5,"maximum":1}`), nonStrict},
		{"absent strict good bounds", jsonSchema("", `{"type":"number","minimum":1,"maximum":5,"multipleOf":0.5}`), nil},
		{"absent strict enum type mismatch", jsonSchema("", `{"type":"integer","enum":[1,"a"]}`), nonStrict},
		{"absent strict array without items", jsonSchema("", `{"type":"array"}`), nonStrict},
	}
	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			if got := RequiredCapabilities(tc.body); !reflect.DeepEqual(got, tc.want) {
				t.Fatalf("RequiredCapabilities = %v, want %v", got, tc.want)
			}
		})
	}
}

func TestRequiresMemberIsClosed(t *testing.T) {
	for _, valid := range [][]string{nil, {CapabilityJSONSchemaNonStrict}} {
		if !ValidRequires(valid) {
			t.Fatalf("ValidRequires(%v) = false", valid)
		}
	}
	for _, invalid := range [][]string{{}, {"json_schema_strict"}, {CapabilityJSONSchemaNonStrict, CapabilityJSONSchemaNonStrict}, {""}} {
		if ValidRequires(invalid) {
			t.Fatalf("ValidRequires(%v) = true", invalid)
		}
	}

	request := []byte(`{"endpoint_family":"chat_completions","model":"model-a","stream":false,"max_output_tokens":32,"input_token_upper_bound":96,"encrypted_request_bytes":200}`)
	withRequires := bytes.Replace(request, []byte(`}`), []byte(`,"requires":["json_schema_non_strict"]}`), 1)
	parsed, err := ParseReservationRequest(withRequires)
	if err != nil || !RequiresNonStrictJSONSchema(parsed.Requires) {
		t.Fatalf("reservation with requires: %+v %v", parsed, err)
	}
	if parsed, err := ParseReservationRequest(request); err != nil || parsed.Requires != nil {
		t.Fatalf("reservation without requires: %+v %v", parsed, err)
	}
	for _, member := range []string{`[]`, `null`, `["other"]`, `"json_schema_non_strict"`, `["json_schema_non_strict","json_schema_non_strict"]`} {
		candidate := bytes.Replace(request, []byte(`}`), []byte(`,"requires":`+member+`}`), 1)
		if _, err := ParseReservationRequest(candidate); err == nil {
			t.Fatalf("reservation requires %s accepted", member)
		}
	}
	if raw, _ := json.Marshal(ReservationRequest{EndpointFamily: EndpointChatCompletions, Model: "model-a", MaxOutputTokens: 1, InputTokenUpperBound: 1, EncryptedRequestBytes: 1}); bytes.Contains(raw, []byte("requires")) {
		t.Fatalf("absent requires marshalled: %s", raw)
	}
}

func TestRequiresIsBoundIntoEnvelopeAAD(t *testing.T) {
	now := time.Unix(1_700_000_000, 0).UTC()
	record, _, provider := testRecord(t, now)
	reservation := testReservation(record, now)
	providerPrivate := provider.Bytes()
	publicKey, err := record.EncryptionPublicKey()
	if err != nil {
		t.Fatal(err)
	}
	buyer, err := ecdh.X25519().GenerateKey(rand.Reader)
	if err != nil {
		t.Fatal(err)
	}
	nonce := bytes.Repeat([]byte{7}, 32)
	plain, err := reservation.NewEnvelope("request-a", now, nonce)
	if err != nil {
		t.Fatal(err)
	}
	framed := plain
	framed.BuyerEphemeralPublicKey = encodeBase64URL(buyer.PublicKey().Bytes())
	legacyAAD, _ := framed.AAD()
	framed.Requires = []string{CapabilityJSONSchemaNonStrict}
	declaredAAD, _ := framed.AAD()
	declared := plain
	declared.Requires = []string{CapabilityJSONSchemaNonStrict}
	if len(legacyAAD) == 0 || !bytes.HasPrefix(declaredAAD, legacyAAD) || len(declaredAAD) <= len(legacyAAD) {
		t.Fatal("requires must append to the unchanged v0.5 AAD")
	}
	sealed, err := declared.Encrypt([]byte(`{"model":"model-a"}`), publicKey, buyer.Bytes())
	if err != nil {
		t.Fatal(err)
	}
	raw, _ := json.Marshal(sealed)
	parsed, err := ParseEnvelope(raw)
	if err != nil || !RequiresNonStrictJSONSchema(parsed.Requires) {
		t.Fatalf("ParseEnvelope with requires: %v", err)
	}
	if _, err := parsed.Decrypt(providerPrivate); err != nil {
		t.Fatalf("declared envelope did not decrypt: %v", err)
	}
	stripped := parsed
	stripped.Requires = nil
	if _, err := stripped.Decrypt(providerPrivate); err == nil {
		t.Fatal("stripping requires left the envelope authentic")
	}
	undeclared, err := plain.Encrypt([]byte(`{"model":"model-a"}`), publicKey, buyer.Bytes())
	if err != nil {
		t.Fatal(err)
	}
	forged := undeclared
	forged.Requires = []string{CapabilityJSONSchemaNonStrict}
	if _, err := forged.Decrypt(providerPrivate); err == nil {
		t.Fatal("forging requires left the envelope authentic")
	}
	for _, member := range []string{`[]`, `null`, `["other"]`} {
		candidate := bytes.Replace(raw, []byte(`"requires":["json_schema_non_strict"]`), []byte(`"requires":`+member), 1)
		if _, err := ParseEnvelope(candidate); err == nil {
			t.Fatalf("envelope requires %s accepted", member)
		}
	}
}

func TestRequiresGoldenVector(t *testing.T) {
	raw, err := os.ReadFile("../../../test/fixtures/relay-blind/golden-v1.json")
	if err != nil {
		t.Fatal(err)
	}
	var fixture map[string]json.RawMessage
	if err := json.Unmarshal(raw, &fixture); err != nil {
		t.Fatal(err)
	}
	rawVector, err := os.ReadFile("../../../test/fixtures/relay-blind/golden-v1-requires.json")
	if err != nil {
		t.Fatal(err)
	}
	var vector struct {
		Requires []string        `json:"requires"`
		Envelope json.RawMessage `json:"envelope"`
		AADHex   string          `json:"aad_hex"`
	}
	if err := json.Unmarshal(rawVector, &vector); err != nil {
		t.Fatal(err)
	}
	want, err := ParseEnvelope(vector.Envelope)
	if err != nil {
		t.Fatal(err)
	}
	var record KeyRecord
	var reservation ReservationResponse
	var plaintext string
	for name, target := range map[string]any{"key_record": &record, "reservation": &reservation, "plaintext_utf8": &plaintext} {
		if err := json.Unmarshal(fixture[name], target); err != nil {
			t.Fatalf("%s: %v", name, err)
		}
	}
	envelope, err := reservation.NewEnvelope(want.RequestID, time.Unix(want.IssuedAtUnix, 0), fixtureBytes(t, fixture, "request_replay_nonce"))
	if err != nil {
		t.Fatal(err)
	}
	envelope.Requires = vector.Requires
	publicKey, _ := record.EncryptionPublicKey()
	envelope, err = envelope.Encrypt([]byte(plaintext), publicKey, fixtureBytes(t, fixture, "buyer_x25519_private_key"))
	if err != nil {
		t.Fatal(err)
	}
	if !reflect.DeepEqual(envelope, want) {
		t.Fatal("generated envelope differs from the requires golden vector")
	}
	aad, _ := envelope.AAD()
	if hex.EncodeToString(aad) != vector.AADHex {
		t.Fatal("requires AAD differs from the golden vector")
	}
	decrypted, err := want.Decrypt(fixtureBytes(t, fixture, "provider_x25519_private_key"))
	if err != nil || string(decrypted) != plaintext {
		t.Fatalf("golden decrypt: %v", err)
	}
}
