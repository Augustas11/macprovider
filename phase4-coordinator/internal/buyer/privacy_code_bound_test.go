package buyer

import (
	"context"
	"crypto/ecdsa"
	"crypto/ed25519"
	"crypto/elliptic"
	"crypto/rand"
	"crypto/sha256"
	"encoding/base64"
	"encoding/json"
	"net/http"
	"strings"
	"testing"

	"github.com/augstar/macprovider-coordinator/internal/appattest/appattesttest"
	"github.com/augstar/macprovider-coordinator/internal/relayblind"
)

// codeBoundHarness adds an App Attest key that SPEC-033 recorded for
// provider-a and the posture sequence the next posture uses.
type codeBoundHarness struct {
	*privacyHarness
	appKey  *ecdsa.PrivateKey
	counter uint32
	seq     uint64
}

func newCodeBoundHarness(t *testing.T, cfg privacyHarnessConfig) *codeBoundHarness {
	t.Helper()
	h := &codeBoundHarness{privacyHarness: newPrivacyHarness(t, cfg), seq: 1}
	appKey, err := ecdsa.GenerateKey(elliptic.P256(), rand.Reader)
	if err != nil {
		t.Fatal(err)
	}
	h.appKey = appKey
	public, err := appKey.PublicKey.ECDH()
	if err != nil {
		t.Fatal(err)
	}
	keyID := sha256.Sum256(public.Bytes())
	if err := h.authority.UseCodeBound(relayblind.CodeBoundConfig{
		Lookup: func(_ context.Context, providerID string) ([]byte, []byte, bool, error) {
			return keyID[:], public.Bytes(), providerID == "provider-a", nil
		},
		TeamID: privacyTestTeamID, BundleID: "tech.malibu.app",
	}); err != nil {
		t.Fatal(err)
	}
	return h
}

// posture verifies one more posture for provider-a/session-a, code-bound when
// codeBound is true.
func (h *codeBoundHarness) posture(t *testing.T, codeBound bool) relayblind.CodeBoundOutcome {
	t.Helper()
	h.seq++
	now := h.clock.Now()
	nonce, issued, err := h.authority.BeginChallenge("provider-a", "session-a", now)
	if err != nil {
		t.Fatal(err)
	}
	statement := relayblind.PostureStatement{
		Version: relayblind.PrivacyPostureVersion, PrivacyClass: relayblind.PrivacyClassV1, ProviderID: "provider-a",
		AssignedSession: "session-a", Nonce: nonce, Sequence: h.seq, IssuedAtUnix: issued, BinaryVersion: privacyTestBinary,
		CodeCDHash: privacyTestCDHash, TeamID: privacyTestTeamID, SigningIdentifier: privacyTestSigning,
		HardenedRuntime: true, LibraryValidation: true, PTDenyAttachApplied: true, CoreDumpsDisabled: true, SIPEnabled: true,
		RuntimeSource: relayblind.PrivacyRuntimeSource, DiagnosticEnvClear: true, KVDiskTierDisabled: true,
		SEKeyBackend: relayblind.PrivacySEBackendFile, PrivacyKeyRecordDigests: []string{h.privacyKey.KeyRecordDigest},
	}
	rawStatement, err := json.Marshal(statement)
	if err != nil {
		t.Fatal(err)
	}
	framing, err := statement.Framing()
	if err != nil {
		t.Fatal(err)
	}
	sum := sha256.Sum256(framing)
	seSig, err := ecdsa.SignASN1(rand.Reader, h.seKey, sum[:])
	if err != nil {
		t.Fatal(err)
	}
	wire, err := json.Marshal(map[string]any{
		"type": "privacy_posture_response", "version": 1, "statement": json.RawMessage(rawStatement),
		"se_signature":       base64.RawURLEncoding.EncodeToString(seSig),
		"identity_signature": base64.RawURLEncoding.EncodeToString(ed25519.Sign(h.identity, framing)),
	})
	if err != nil {
		t.Fatal(err)
	}
	var evidence []byte
	if codeBound {
		public, _ := h.appKey.PublicKey.ECDH()
		keyID := sha256.Sum256(public.Bytes())
		cb := relayblind.CodeBoundStatement{
			Version: relayblind.PrivacyCodeBoundVersion, PrivacyClass: relayblind.PrivacyClassV1,
			ProviderID: "provider-a", AssignedSession: "session-a", Nonce: nonce,
			PostureDigest:            base64.RawURLEncoding.EncodeToString(sum[:]),
			SEPublicKey:              base64.StdEncoding.EncodeToString(h.seRaw),
			IdentityPublicKey:        base64.RawURLEncoding.EncodeToString(h.identity.Public().(ed25519.PublicKey)),
			AppAttestKeyID:           base64.RawURLEncoding.EncodeToString(keyID[:]),
			RuntimeTeamID:            privacyTestTeamID,
			RuntimeSigningIdentifier: privacyTestSigning,
			RuntimeCDHash:            privacyTestCDHash,
			RuntimeCSFlags:           0x0001_0301,
			CheckedAtUnix:            now.Unix(),
		}
		cbFraming, err := cb.Framing()
		if err != nil {
			t.Fatal(err)
		}
		hash := sha256.Sum256(cbFraming)
		h.counter++
		assertion, err := appattesttest.Assert(h.appKey, privacyTestTeamID+".tech.malibu.app", h.counter, hash[:])
		if err != nil {
			t.Fatal(err)
		}
		rawCB, _ := json.Marshal(cb)
		evidence, _ = json.Marshal(map[string]any{
			"type": "privacy_code_bound_evidence", "version": 1, "statement": json.RawMessage(rawCB),
			"assertion": base64.RawURLEncoding.EncodeToString(assertion),
		})
	}
	outcome, err := h.authority.VerifyPostureWithEvidence(context.Background(), "provider-a", "session-a", nonce, wire, evidence, h.seRaw, now)
	if err != nil {
		t.Fatal(err)
	}
	return outcome
}

func requireCodeBound(r *http.Request) {
	r.Header.Set(relayblind.PrivacyAssuranceRequiredHeader, relayblind.PrivacyAssuranceCodeBound)
}

// SPEC-049-R034: a code-bound requirement reserves only a session whose
// latest posture is code-bound, binds the label into the row, and the chat
// response carries it; without the requirement the label stays device-bound.
func TestPrivacyCodeBoundRequirementReservesOnlyCodeBoundSessions(t *testing.T) {
	body := privacyTestResponseBody(t)
	h := newCodeBoundHarness(t, privacyHarnessConfig{privacyKey: true, relay: privacySuccessRelay(body, nil, nil)})
	reservationBody := privacyReservationBody("model-a")

	// The harness posture is device-bound.
	response := h.privacyRequest(t, http.MethodPost, "/v1/relay-blind/route-reservations", reservationBody, "", requireCodeBound)
	if response.Code != http.StatusServiceUnavailable || !strings.Contains(response.Body.String(), `"code":"privacy_class_unavailable"`) ||
		response.Header().Get(relayblind.PrivacyRejectReasonHeader) != relayblind.PrivacyRejectAssuranceUnavailable {
		t.Fatalf("device-bound session served a code-bound request: status=%d reason=%q body=%s", response.Code, response.Header().Get(relayblind.PrivacyRejectReasonHeader), response.Body.String())
	}

	if outcome := h.posture(t, true); outcome.Assurance != relayblind.PrivacyAssuranceCodeBound {
		t.Fatalf("code-bound posture outcome = %+v", outcome)
	}
	response = h.privacyRequest(t, http.MethodPost, "/v1/relay-blind/route-reservations", reservationBody, "", requireCodeBound)
	if response.Code != http.StatusOK {
		t.Fatalf("code-bound reservation status=%d body=%s", response.Code, response.Body.String())
	}
	reservation, err := relayblind.ParseReservationResponse(response.Body.Bytes())
	if err != nil || reservation.PrivacyAssurance != relayblind.PrivacyAssuranceCodeBound {
		t.Fatalf("reservation = %+v err=%v", reservation, err)
	}
	if row, err := h.store.LookupReservation(context.Background(), reservation.ProviderBinding); err != nil || row.PrivacyAssurance != relayblind.PrivacyAssuranceCodeBound {
		t.Fatalf("row assurance = %q err=%v", row.PrivacyAssurance, err)
	}
	// Without the requirement the same code-bound session is reserved as
	// device-bound, so an older client never meets the new label.
	if plain := h.reserve(t, true); plain.PrivacyAssurance != relayblind.PrivacyAssurance {
		t.Fatalf("reservation without requirement = %q", plain.PrivacyAssurance)
	}

	raw := h.seal(t, reservation, "privacy-code-bound", h.privacyPrivate)
	response = h.privacyRequest(t, http.MethodPost, "/v1/relay-blind/consume", raw, "", nil)
	if response.Code != http.StatusOK {
		t.Fatalf("consume status=%d body=%s", response.Code, response.Body.String())
	}
	consume, err := relayblind.ParseConsumeResponse(response.Body.Bytes())
	if err != nil {
		t.Fatal(err)
	}
	response = h.privacyRequest(t, http.MethodPost, "/v1/chat/completions", raw, consume.ExecutionAuthorization, nil)
	if response.Code != http.StatusOK || response.Header().Values(privacyAssuranceHeader)[0] != relayblind.PrivacyAssuranceCodeBound || len(response.Header().Values(privacyAssuranceHeader)) != 1 {
		t.Fatalf("chat status=%d assurance=%v body=%s", response.Code, response.Header().Values(privacyAssuranceHeader), response.Body.String())
	}
}

// SPEC-049-R034 item 3: a code-bound reservation whose session falls back to
// a device-bound posture before dispatch is burned as posture_stale.
func TestPrivacyCodeBoundReservationLapsesBeforeDispatch(t *testing.T) {
	h := newCodeBoundHarness(t, privacyHarnessConfig{privacyKey: true, relay: privacySuccessRelay(privacyTestResponseBody(t), nil, nil)})
	h.posture(t, true)
	response := h.privacyRequest(t, http.MethodPost, "/v1/relay-blind/route-reservations", privacyReservationBody("model-a"), "", requireCodeBound)
	if response.Code != http.StatusOK {
		t.Fatalf("reservation status=%d body=%s", response.Code, response.Body.String())
	}
	reservation, err := relayblind.ParseReservationResponse(response.Body.Bytes())
	if err != nil {
		t.Fatal(err)
	}
	raw := h.seal(t, reservation, "privacy-code-bound-lapse", h.privacyPrivate)
	response = h.privacyRequest(t, http.MethodPost, "/v1/relay-blind/consume", raw, "", nil)
	if response.Code != http.StatusOK {
		t.Fatalf("consume status=%d body=%s", response.Code, response.Body.String())
	}
	consume, err := relayblind.ParseConsumeResponse(response.Body.Bytes())
	if err != nil {
		t.Fatal(err)
	}
	// Malibu.app quit: the next posture carries no evidence.
	if outcome := h.posture(t, false); outcome.Assurance != relayblind.PrivacyAssurance {
		t.Fatalf("outcome = %+v", outcome)
	}
	response = h.privacyRequest(t, http.MethodPost, "/v1/chat/completions", raw, consume.ExecutionAuthorization, nil)
	if response.Code != http.StatusServiceUnavailable || !strings.Contains(response.Body.String(), `"code":"privacy_class_posture_stale"`) ||
		response.Header().Get(relayblind.PrivacyRejectReasonHeader) != relayblind.PrivacyRejectAssuranceUnavailable || response.Header().Get(privacyAssuranceHeader) != "" {
		t.Fatalf("chat status=%d reason=%q body=%s", response.Code, response.Header().Get(relayblind.PrivacyRejectReasonHeader), response.Body.String())
	}
	if row, err := h.store.LookupReservation(context.Background(), reservation.ProviderBinding); err != nil || row.State != relayblind.ReservationStateRejected {
		t.Fatalf("row=%+v err=%v", row, err)
	}
}

// SPEC-049-R034 item 1 at the coordinator: the requirement is valid only as
// one code_bound_attested value with the privacy-class marker.
func TestPrivacyAssuranceRequirementIsClosed(t *testing.T) {
	h := newCodeBoundHarness(t, privacyHarnessConfig{privacyKey: true, relayKey: true})
	h.posture(t, true)
	for name, mutate := range map[string]func(*http.Request){
		"other value": func(r *http.Request) {
			r.Header.Set(relayblind.PrivacyAssuranceRequiredHeader, relayblind.PrivacyAssurance)
		},
		"repeated": func(r *http.Request) {
			r.Header.Add(relayblind.PrivacyAssuranceRequiredHeader, relayblind.PrivacyAssuranceCodeBound)
			r.Header.Add(relayblind.PrivacyAssuranceRequiredHeader, relayblind.PrivacyAssuranceCodeBound)
		},
		"without the privacy marker": func(r *http.Request) {
			r.Header.Del(privacyClassHeader)
			requireCodeBound(r)
		},
	} {
		t.Run(name, func(t *testing.T) {
			response := h.privacyRequest(t, http.MethodPost, "/v1/relay-blind/route-reservations", privacyReservationBody("model-a"), "", mutate)
			if response.Code != http.StatusBadRequest || !strings.Contains(response.Body.String(), `"code":"privacy_class_downgrade_rejected"`) {
				t.Fatalf("status=%d body=%s", response.Code, response.Body.String())
			}
		})
	}
}
