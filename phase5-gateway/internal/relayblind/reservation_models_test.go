package relayblind

import (
	"encoding/json"
	"testing"
	"time"
)

func TestReservationResponseAcceptsSignedModelGroup(t *testing.T) {
	now := time.Unix(1_700_000_000, 0).UTC()
	models := []string{"mlx-community/Qwen3.6-35B-A3B-4bit", "qwen/qwen3.6-35b-a3b"}
	for _, privacy := range []bool{false, true} {
		response, pin, identity := testPrivacyReservation(t, now)
		public, err := response.KeyRecord.EncryptionPublicKey()
		if err != nil {
			t.Fatal(err)
		}
		record, err := NewSignedKeyRecord(public, identity, models, response.KeyRecord.MaxEncryptedRequestBytes, now, time.Unix(response.KeyRecord.ExpiresAtUnix, 0))
		if err != nil {
			t.Fatal(err)
		}
		pin.Models = models
		if err := record.Verify(pin, now); err != nil {
			t.Fatalf("signed group verification: %v", err)
		}
		response.KeyRecord = record
		response.KeyRecordDigest = record.KeyRecordDigest
		response.KID = record.KID
		response.ProviderModel = models[0]
		if privacy {
			response.PrivacyKeyAttestation.KeyRecordDigest = record.KeyRecordDigest
			response.PrivacyKeyAttestationSignature = signAttestation(t, identity, *response.PrivacyKeyAttestation)
			if err := response.PrivacyKeyAttestation.Verify(pin, response.PrivacyKeyAttestationSignature, record); err != nil {
				t.Fatalf("signed group attestation: %v", err)
			}
		} else {
			response.Version = ReservationVersion
			response.PrivacyClass = ""
			response.PrivacyAssurance = ""
			response.PrivacyKeyAttestation = nil
			response.PrivacyKeyAttestationSignature = ""
			response.PrivacyPostureVerifiedAtUnix = 0
		}
		for _, model := range models {
			response.Model = model
			raw, err := json.Marshal(response)
			if err != nil {
				t.Fatal(err)
			}
			parsed, err := ParseReservationResponse(raw)
			if err != nil {
				t.Fatalf("privacy=%t model=%s grouped reservation rejected: %v", privacy, model, err)
			}
			request := ReservationRequest{EndpointFamily: response.EndpointFamily, Model: model, Stream: response.Stream, MaxOutputTokens: response.MaxOutputTokens, InputTokenUpperBound: response.InputTokenUpperBound, EncryptedRequestBytes: int64(response.MaxEncryptedRequestBytes)}
			if err := parsed.MatchesRequest(request); err != nil {
				t.Fatalf("matching exact model rejected: %v", err)
			}
			request.Model = models[0]
			if request.Model == model {
				request.Model = models[1]
			}
			if err := parsed.MatchesRequest(request); err == nil {
				t.Fatal("different signed alias substituted for exact request model")
			}
			request.Model = "qwen/qwen3.6-35b-a3b-unknown"
			if err := parsed.MatchesRequest(request); err == nil {
				t.Fatal("model outside exact request binding accepted")
			}
		}
		response.Model = "qwen/qwen3.6-35b-a3b-unknown"
		if err := response.Validate(); err == nil {
			t.Fatal("model outside signed key scope accepted")
		}
		response.Model = models[0]
		response.KeyRecord.Models = []string{models[0], models[0]}
		if err := response.Validate(); err == nil {
			t.Fatal("duplicate key scope accepted")
		}
		response.KeyRecord.Models = []string{models[1], models[0]}
		if err := response.Validate(); err == nil {
			t.Fatal("noncanonical key scope accepted")
		}
	}
}
