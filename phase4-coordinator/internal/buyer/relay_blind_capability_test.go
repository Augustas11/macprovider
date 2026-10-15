package buyer

import (
	"bytes"
	"crypto/ecdh"
	"encoding/json"
	"net/http"
	"os"
	"regexp"
	"strings"
	"testing"
	"time"

	"github.com/augstar/macprovider-coordinator/internal/relayblind"
	"github.com/augstar/macprovider-coordinator/internal/versionfloor"
)

var nonStrictRequires = []string{relayblind.CapabilityJSONSchemaNonStrict}

func capabilityReservationBody(requires []string) []byte {
	raw, _ := json.Marshal(relayblind.ReservationRequest{EndpointFamily: relayblind.EndpointChatCompletions, Model: "model-a", MaxOutputTokens: 32, InputTokenUpperBound: 96, EncryptedRequestBytes: 1024, Requires: requires})
	return raw
}

func sealWithRequires(t *testing.T, reservation relayblind.ReservationResponse, requestID string, now time.Time, provider *ecdh.PrivateKey, requires []string) []byte {
	t.Helper()
	envelope, err := reservation.NewEnvelope(requestID, now, bytes.Repeat([]byte{0x44}, 32))
	if err != nil {
		t.Fatal(err)
	}
	envelope.Requires = requires
	buyer, err := ecdh.X25519().GenerateKey(nil)
	if err != nil {
		t.Fatal(err)
	}
	envelope, err = envelope.Encrypt([]byte(`{"model":"model-a","messages":[{"role":"user","content":"secret"}]}`), provider.PublicKey().Bytes(), buyer.Bytes())
	if err != nil {
		t.Fatal(err)
	}
	raw, _ := json.Marshal(envelope)
	return raw
}

func assertCapabilityRefusal(t *testing.T, status int, body string) {
	t.Helper()
	if status != http.StatusBadRequest || !strings.Contains(body, `"code":"json_schema_non_strict_unsupported"`) || !strings.Contains(body, `"retryable":false`) {
		t.Fatalf("status=%d body=%s, want 400 json_schema_non_strict_unsupported", status, body)
	}
}

// SPEC-041-R004: a reservation that declares json_schema_non_strict binds
// only a provider CLI that supports it, and gets the plaintext path's 400
// when the only provider serving the model does not.
func TestRelayBlindReservationRoutesDeclaredCapabilityOnlyToCapableCLI(t *testing.T) {
	now := time.Unix(1_800_100_400, 0).UTC()
	server, _, _, closeStore, provider := relayBlindTestServerWithProvider(t, now, nil)
	defer closeStore()

	provider.BinaryVersion = "1.8.240"
	response := relayBlindRequest(t, server, http.MethodPost, "/v1/relay-blind/route-reservations", capabilityReservationBody(nonStrictRequires), "")
	assertCapabilityRefusal(t, response.Code, response.Body.String())
	if count := countRelayBlindReservations(t, server); count != 0 {
		t.Fatalf("refused reservation created %d rows", count)
	}
	response = relayBlindRequest(t, server, http.MethodPost, "/v1/relay-blind/route-reservations", capabilityReservationBody(nil), "")
	if response.Code != http.StatusOK {
		t.Fatalf("undeclared reservation on old CLI status=%d body=%s", response.Code, response.Body.String())
	}

	provider.BinaryVersion = nonStrictJSONSchemaFirstBinary
	response = relayBlindRequest(t, server, http.MethodPost, "/v1/relay-blind/route-reservations", capabilityReservationBody(nonStrictRequires), "")
	if response.Code != http.StatusOK {
		t.Fatalf("declared reservation on capable CLI status=%d body=%s", response.Code, response.Body.String())
	}

	provider.ModelID = "model-b"
	response = relayBlindRequest(t, server, http.MethodPost, "/v1/relay-blind/route-reservations", capabilityReservationBody(nonStrictRequires), "")
	if response.Code == http.StatusBadRequest || !strings.Contains(response.Body.String(), `"code":"relay_blind_provider_unsupported"`) {
		t.Fatalf("model not served status=%d body=%s, want the unavailable code", response.Code, response.Body.String())
	}
}

// SPEC-041-R004: consume rechecks the envelope's declaration against the
// reserved provider, so a reservation made without it cannot carry a
// declared request to an incapable CLI.
func TestRelayBlindConsumeRejectsDeclaredCapabilityOnIncapableReservation(t *testing.T) {
	now := time.Unix(1_800_100_500, 0).UTC()
	server, _, providerPrivate, closeStore, provider := relayBlindTestServerWithProvider(t, now, nil)
	defer closeStore()
	provider.BinaryVersion = "1.8.240"

	response := relayBlindRequest(t, server, http.MethodPost, "/v1/relay-blind/route-reservations", capabilityReservationBody(nil), "")
	reservation, err := relayblind.ParseReservationResponse(response.Body.Bytes())
	if response.Code != http.StatusOK || err != nil {
		t.Fatalf("reservation status=%d err=%v", response.Code, err)
	}
	raw := sealWithRequires(t, reservation, "capability-consume", now, providerPrivate, nonStrictRequires)
	response = relayBlindRequest(t, server, http.MethodPost, "/v1/relay-blind/consume", raw, "")
	assertCapabilityRefusal(t, response.Code, response.Body.String())
	held, err := server.relayBlind.store.LookupReservation(t.Context(), reservation.ProviderBinding)
	if err != nil || held.State != "rejected" {
		t.Fatalf("reservation state=%q err=%v, want rejected", held.State, err)
	}

	provider.BinaryVersion = nonStrictJSONSchemaFirstBinary
	reserve := func(requires []string) relayblind.ReservationResponse {
		t.Helper()
		response := relayBlindRequest(t, server, http.MethodPost, "/v1/relay-blind/route-reservations", capabilityReservationBody(requires), "")
		reservation, err := relayblind.ParseReservationResponse(response.Body.Bytes())
		if response.Code != http.StatusOK || err != nil {
			t.Fatalf("reservation status=%d err=%v", response.Code, err)
		}
		return reservation
	}
	// The envelope must carry exactly the reservation's declaration, in both
	// directions, even on a capable CLI.
	for name, pair := range map[string][2][]string{"reservation only": {nonStrictRequires, nil}, "envelope only": {nil, nonStrictRequires}} {
		reservation := reserve(pair[0])
		raw := sealWithRequires(t, reservation, "capability-mismatch-"+strings.ReplaceAll(name, " ", "-"), now, providerPrivate, pair[1])
		response := relayBlindRequest(t, server, http.MethodPost, "/v1/relay-blind/consume", raw, "")
		assertCapabilityRefusal(t, response.Code, response.Body.String())
		if held, err := server.relayBlind.store.LookupReservation(t.Context(), reservation.ProviderBinding); err != nil || held.State != "rejected" {
			t.Fatalf("%s: reservation state=%q err=%v, want rejected", name, held.State, err)
		}
	}
	reservation = reserve(nonStrictRequires)
	raw = sealWithRequires(t, reservation, "capability-consume-ok", now, providerPrivate, nonStrictRequires)
	if response = relayBlindRequest(t, server, http.MethodPost, "/v1/relay-blind/consume", raw, ""); response.Code != http.StatusOK {
		t.Fatalf("declared consume on capable CLI status=%d body=%s", response.Code, response.Body.String())
	}
}

// SPEC-049-R013/R030: the privacy class applies the same gate and records
// the capability_unsupported reason.
func TestPrivacyReservationAppliesCapabilityGate(t *testing.T) {
	h := newPrivacyHarness(t, privacyHarnessConfig{privacyKey: true})
	h.provider.BinaryVersion = "1.8.240"
	response := h.privacyRequest(t, http.MethodPost, "/v1/relay-blind/route-reservations", capabilityReservationBody(nonStrictRequires), "", nil)
	assertCapabilityRefusal(t, response.Code, response.Body.String())
	if got := response.Header().Get(relayblind.PrivacyRejectReasonHeader); got != relayblind.PrivacyRejectCapabilityUnsupported {
		t.Fatalf("reason header=%q, want capability_unsupported", got)
	}

	response = h.privacyRequest(t, http.MethodPost, "/v1/relay-blind/route-reservations", capabilityReservationBody(nil), "", nil)
	reservation, err := relayblind.ParseReservationResponse(response.Body.Bytes())
	if response.Code != http.StatusOK || err != nil {
		t.Fatalf("undeclared privacy reservation status=%d err=%v body=%s", response.Code, err, response.Body.String())
	}
	raw := sealWithRequires(t, reservation, "privacy-capability-consume", h.clock.Now(), h.privacyPrivate, nonStrictRequires)
	response = h.privacyRequest(t, http.MethodPost, "/v1/relay-blind/consume", raw, "", nil)
	assertCapabilityRefusal(t, response.Code, response.Body.String())
	if got := response.Header().Get(relayblind.PrivacyRejectReasonHeader); got != relayblind.PrivacyRejectCapabilityUnsupported {
		t.Fatalf("consume reason header=%q, want capability_unsupported", got)
	}

	h.provider.BinaryVersion = nonStrictJSONSchemaFirstBinary
	response = h.privacyRequest(t, http.MethodPost, "/v1/relay-blind/route-reservations", capabilityReservationBody(nonStrictRequires), "", nil)
	if reservation, err := relayblind.ParseReservationResponse(response.Body.Bytes()); response.Code != http.StatusOK || err != nil || reservation.Version != relayblind.PrivacyReservationVersion {
		t.Fatalf("declared privacy reservation on capable CLI status=%d err=%v body=%s", response.Code, err, response.Body.String())
	}
}

// The reference client's classifier (relayblind.RequiredCapabilities) must
// declare non-strict mode exactly when this coordinator's plaintext parser
// routes the same body through the SPEC-019 §1a non-strict gate.
func TestRelayBlindRequiredCapabilitiesAgreesWithCoordinatorSchemaMode(t *testing.T) {
	schemas := []string{
		`{"type":"object","properties":{"name":{"type":"string"}},"required":["name"],"additionalProperties":false}`,
		`{"type":"object","properties":{"name":{"type":"string"}}}`,
		`{"type":"object","properties":{"name":{"type":"string"}},"required":["name"],"additionalProperties":true}`,
		`{"type":"object","properties":{"a":{"type":"string"}},"required":["a","a"],"additionalProperties":false}`,
		`{"type":"string","pattern":"^a"}`,
		`{"$schema":"https://json-schema.org/draft/2020-12/schema","type":"string"}`,
		`{"type":"array","items":{"$schema":"x","type":"string"}}`,
		`{"type":"array"}`,
		`{"type":"array","items":{"type":"integer"},"required":[]}`,
		`{"type":"integer","minimum":5,"maximum":1}`,
		`{"type":"number","minimum":1,"maximum":5,"multipleOf":0.5}`,
		`{"type":"number","multipleOf":0}`,
		`{"type":"string","minimum":1}`,
		`{"type":"integer","enum":[1,2,3]}`,
		`{"type":"integer","enum":[1,"a"]}`,
		`{"type":"integer","const":1.5}`,
		`{"type":"boolean","const":true}`,
		`{"type":"null","enum":[null]}`,
		`{"type":"string","items":{"type":"string"}}`,
		`{"type":"unknown"}`,
		`{"description":"no type"}`,
		`{"type":"object","properties":{"nested":{"type":"object","properties":{"x":{"type":"number"}},"required":["x"],"additionalProperties":false}},"required":["nested"],"additionalProperties":false}`,
		`{"type":"object","properties":{"nested":{"type":"object","properties":{"x":{"type":"number"}}}},"required":["nested"],"additionalProperties":false}`,
		deepStrictSchema(33),
		deepStrictSchema(31),
	}
	for _, strict := range []string{"", `,"strict":null`, `,"strict":true`, `,"strict":false`} {
		for _, schema := range schemas {
			format := `{"type":"json_schema","json_schema":{"name":"person","schema":` + schema + strict + `}}`
			body := []byte(`{"model":"model-a","messages":[{"role":"user","content":"hi"}],"max_tokens":8,"response_format":` + format + `}`)
			legacy, status, _, _ := validateResponseFormatSchema(json.RawMessage(format), false)
			if status != 0 {
				continue
			}
			declared := relayblind.RequiresNonStrictJSONSchema(relayblind.RequiredCapabilities(body))
			if declared != (legacy != nil) {
				t.Fatalf("strict%q schema %s: client declares %v, coordinator non-strict %v", strict, schema, declared, legacy != nil)
			}
		}
	}
}

func deepStrictSchema(depth int) string {
	schema := `{"type":"string"}`
	for i := 1; i < depth; i++ {
		schema = `{"type":"array","items":` + schema + `}`
	}
	return schema
}

func countRelayBlindReservations(t *testing.T, server *Server) int {
	t.Helper()
	count, err := server.relayBlind.store.CountReservations(t.Context())
	if err != nil {
		t.Fatal(err)
	}
	return count
}

// The requires floor must name a CLI that parses requires (SPEC-041 v0.6.0):
// a provider source tree whose binaryVersion is at or above the floor must
// contain the R003 parser and the R005 check, and the floor is never below
// the SPEC-019 §1a non-strict floor.
func TestRelayBlindRequiresFloorMatchesProviderSource(t *testing.T) {
	if cmp, ok := versionfloor.Compare(relayBlindRequiresFirstBinary, nonStrictJSONSchemaFirstBinary); !ok || cmp < 0 {
		t.Fatalf("requires floor %s is below the non-strict floor %s", relayBlindRequiresFirstBinary, nonStrictJSONSchemaFirstBinary)
	}
	client, err := os.ReadFile("../../../phase3-binary/Sources/macprovider-cli/CoordinatorClient.swift")
	if err != nil {
		t.Fatal(err)
	}
	match := regexp.MustCompile(`static let binaryVersion = "([0-9.]+)"`).FindSubmatch(client)
	if match == nil {
		t.Fatal("provider binaryVersion not found")
	}
	provider, err := os.ReadFile("../../../phase3-binary/Sources/macprovider-cli/RelayBlindProvider.swift")
	if err != nil {
		t.Fatal(err)
	}
	parses := bytes.Contains(provider, []byte(`static let requiresKey = "requires"`)) && bytes.Contains(provider, []byte(`!envelope.requires.contains(RelayBlindEnvelope.capabilityJSONSchemaNonStrict)`))
	if !parses {
		t.Fatal("provider source lacks the SPEC-041 v0.6.0 requires parser or R005 check")
	}
	if cmp, ok := versionfloor.Compare(string(match[1]), relayBlindRequiresFirstBinary); !ok {
		t.Fatalf("provider binaryVersion %q does not parse", match[1])
	} else if cmp < 0 {
		t.Logf("provider source %s is below the requires floor %s", match[1], relayBlindRequiresFirstBinary)
	}
}
