package canon

import (
	"bytes"
	"encoding/base64"
	"encoding/hex"
	"encoding/json"
	"os"
	"testing"
)

func TestCanonParityFixtures(t *testing.T) {
	raw, err := os.ReadFile("../../testdata/canon_fixtures.json")
	if err != nil {
		t.Fatalf("read parity fixtures: %v", err)
	}

	var fixtures struct {
		Prompt []struct {
			ID                   string          `json:"id"`
			Request              json.RawMessage `json:"request"`
			ExpectedCanonicalB64 string          `json:"expected_canonical_b64"`
			ExpectedHashHex      string          `json:"expected_hash_hex"`
		} `json:"prompt"`
		Output []struct {
			ID                   string          `json:"id"`
			Response             json.RawMessage `json:"response"`
			ExpectedCanonicalB64 string          `json:"expected_canonical_b64"`
			ExpectedHashHex      string          `json:"expected_hash_hex"`
		} `json:"output"`
	}
	if err := json.Unmarshal(raw, &fixtures); err != nil {
		t.Fatalf("parse parity fixtures: %v", err)
	}

	for _, fixture := range fixtures.Prompt {
		t.Run("prompt/"+fixture.ID, func(t *testing.T) {
			request := decodeRawObject(t, fixture.Request)
			canonical, hash, err := CanonicalPrompt(request)
			if err != nil {
				t.Fatalf("CanonicalPrompt() error = %v", err)
			}
			assertCanonicalAndHash(t, canonical, hash, fixture.ExpectedCanonicalB64, fixture.ExpectedHashHex)
		})
	}

	for _, fixture := range fixtures.Output {
		t.Run("output/"+fixture.ID, func(t *testing.T) {
			response := decodeRawObject(t, fixture.Response)
			canonical, hash, err := CanonicalOutput(response)
			if err != nil {
				t.Fatalf("CanonicalOutput() error = %v", err)
			}
			assertCanonicalAndHash(t, canonical, hash, fixture.ExpectedCanonicalB64, fixture.ExpectedHashHex)
		})
	}
}

func decodeRawObject(t *testing.T, raw json.RawMessage) map[string]any {
	t.Helper()
	decoder := json.NewDecoder(bytes.NewReader(raw))
	decoder.UseNumber()
	var object map[string]any
	if err := decoder.Decode(&object); err != nil {
		t.Fatalf("decode fixture object: %v", err)
	}
	return object
}

func assertCanonicalAndHash(t *testing.T, canonical []byte, hash [32]byte, expectedCanonicalB64, expectedHashHex string) {
	t.Helper()
	expectedCanonical, err := base64.StdEncoding.DecodeString(expectedCanonicalB64)
	if err != nil {
		t.Fatalf("decode expected canonical b64: %v", err)
	}
	if !bytes.Equal(canonical, expectedCanonical) {
		t.Fatalf("canonical mismatch:\n got:  %s\n want: %s", canonical, expectedCanonical)
	}
	if got := hex.EncodeToString(hash[:]); got != expectedHashHex {
		t.Fatalf("hash = %s, want %s", got, expectedHashHex)
	}
}
