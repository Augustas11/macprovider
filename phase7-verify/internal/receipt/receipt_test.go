package receipt

import (
	"crypto/ed25519"
	"encoding/base64"
	"encoding/json"
	"errors"
	"os"
	"path/filepath"
	"strings"
	"testing"
)

type receiptFixtures struct {
	Provenance                           string `json:"provenance"`
	Pubkey                               string `json:"pubkey"`
	ValidHeader                          string `json:"valid_header"`
	TamperedTupleHeader                  string `json:"tampered_tuple_header"`
	TamperedSignatureHeader              string `json:"tampered_signature_header"`
	NoDotHeader                          string `json:"no_dot_header"`
	TwoDotHeader                         string `json:"two_dot_header"`
	ExtraKeyHeader                       string `json:"extra_key_header"`
	MissingKeyHeader                     string `json:"missing_key_header"`
	WrongTypeHeader                      string `json:"wrong_type_header"`
	NoncanonicalTrailingWhitespaceHeader string `json:"noncanonical_trailing_whitespace_header"`
	NoncanonicalOrderHeader              string `json:"noncanonical_order_header"`
	WrongSigLengthHeader                 string `json:"wrong_sig_length_header"`
}

func TestParseAndVerifyValidReceipt(t *testing.T) {
	fixtures := loadFixtures(t)
	parsed, err := Parse(fixtures.ValidHeader)
	if err != nil {
		t.Fatalf("Parse(valid) error = %v", err)
	}
	pubkey, err := ParsePubkey(fixtures.Pubkey)
	if err != nil {
		t.Fatalf("ParsePubkey(valid) error = %v", err)
	}
	if err := Verify(parsed, pubkey); err != nil {
		t.Fatalf("Verify(valid) error = %v", err)
	}

	if parsed.HeaderValue != fixtures.ValidHeader {
		t.Fatalf("HeaderValue not preserved")
	}
	if parsed.Tuple.ModelID != "fixture-model" {
		t.Fatalf("ModelID = %q", parsed.Tuple.ModelID)
	}
	if parsed.Tuple.PromptHash != strings.Repeat("a", 64) {
		t.Fatalf("PromptHash = %q", parsed.Tuple.PromptHash)
	}
	if parsed.Tuple.OutputHash != strings.Repeat("b", 64) {
		t.Fatalf("OutputHash = %q", parsed.Tuple.OutputHash)
	}
	if parsed.Tuple.ProviderPubkey != fixtures.Pubkey {
		t.Fatalf("ProviderPubkey = %q, want fixture pubkey", parsed.Tuple.ProviderPubkey)
	}
	if parsed.Tuple.TTFTms != 123 || parsed.Tuple.TokensOut != 4 || parsed.Tuple.UnixTS != 1_800_000_000 {
		t.Fatalf("numeric tuple fields = %+v", parsed.Tuple)
	}
	if len(parsed.Signature) != 64 {
		t.Fatalf("signature length = %d, want 64", len(parsed.Signature))
	}

	wantTupleRaw, err := base64.StdEncoding.DecodeString(strings.Split(fixtures.ValidHeader, ".")[0])
	if err != nil {
		t.Fatalf("decode fixture tuple: %v", err)
	}
	if string(parsed.TupleRaw) != string(wantTupleRaw) {
		t.Fatalf("TupleRaw was not preserved from the header")
	}
}

func TestParseErrors(t *testing.T) {
	fixtures := loadFixtures(t)
	tests := []struct {
		name   string
		header string
		want   error
	}{
		{name: "no dot", header: fixtures.NoDotHeader, want: ErrHeaderShape},
		{name: "two dots", header: fixtures.TwoDotHeader, want: ErrHeaderShape},
		// Tuple base64 with invalid alphabet bytes (length multiple of 4 to pass length check first).
		{name: "malformed tuple base64", header: "%%%%.AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA", want: ErrBase64Decode},
		// Signature base64 with invalid alphabet bytes (exactly 88 chars, the required wire length).
		{name: "malformed signature base64", header: "e30=." + strings.Repeat("%", 88), want: ErrBase64Decode},
		// Signature segment too short — caught by length check before alphabet validation.
		{name: "signature segment too short", header: "e30=.%%%", want: ErrSigLength},
		{name: "signature wrong length", header: fixtures.WrongSigLengthHeader, want: ErrSigLength},
		{name: "tuple extra key", header: fixtures.ExtraKeyHeader, want: ErrTupleExtraKey},
		{name: "tuple missing key", header: fixtures.MissingKeyHeader, want: ErrTupleMissingKey},
		{name: "tuple wrong type", header: fixtures.WrongTypeHeader, want: ErrTupleWrongType},
		{name: "tuple trailing whitespace", header: fixtures.NoncanonicalTrailingWhitespaceHeader, want: ErrTupleJSON},
		{name: "tuple invalid json", header: headerFromTuple("not-json"), want: ErrTupleJSON},
		{name: "tuple duplicate key", header: headerFromTuple(`{"model_id":"a","model_id":"b"}`), want: ErrTupleJSON},

		// MAJOR-4 (round-1 audit): added adversarial header-shape cases.
		{name: "empty header", header: "", want: ErrHeaderShape},
		{name: "dot at position 0", header: "." + strings.Repeat("A", 88), want: ErrHeaderShape},
		{name: "dot at final byte", header: "e30=.", want: ErrHeaderShape},
		// 65-byte signature: 87 chars of 'A' + '=' decodes to a 65-byte slice; length check still passes
		// because 88 chars total, but the post-decode ed25519.SignatureSize check (64) rejects it.
		{
			name:   "signature decodes to 65 bytes",
			header: "e30=." + strings.Repeat("A", 86) + "Q=",
			want:   ErrSigLength,
		},
		// CRITICAL (round-1 audit): CR/LF/whitespace/control bytes in segments
		// MUST be rejected pre-decode. stdlib base64 silently strips CR/LF;
		// SPEC-015 §3.4 forbids any whitespace in the wire value.
		// Each adversarial segment is exactly 88 chars (sig length) or 4-byte
		// multiple (tuple length) so the length gate doesn't preempt the
		// alphabet gate.
		{name: "CR in tuple segment", header: "e3\r0=." + strings.Repeat("A", 86) + "==", want: ErrBase64Decode},
		{name: "LF in tuple segment", header: "e3\n0=." + strings.Repeat("A", 86) + "==", want: ErrBase64Decode},
		// Signature segments below are exactly 88 chars with the bad byte
		// substituted (not appended) so the length gate passes first.
		{name: "CR in signature segment", header: "e30=." + strings.Repeat("A", 86) + "=\r", want: ErrBase64Decode},
		{name: "LF in signature segment", header: "e30=." + strings.Repeat("A", 86) + "=\n", want: ErrBase64Decode},
		{name: "tab in signature segment", header: "e30=." + strings.Repeat("A", 86) + "\t=", want: ErrBase64Decode},
		{name: "space in signature segment", header: "e30=." + strings.Repeat("A", 86) + " =", want: ErrBase64Decode},
		{name: "null byte in signature segment", header: "e30=." + strings.Repeat("A", 86) + "\x00=", want: ErrBase64Decode},
		// JSON adversarials inside the tuple body — encoding/json must reject all of these.
		{name: "tuple NaN literal", header: headerFromTuple(`{"model_id":NaN}`), want: ErrTupleJSON},
		{name: "tuple Infinity literal", header: headerFromTuple(`{"model_id":Infinity}`), want: ErrTupleJSON},
		{name: "tuple trailing comma", header: headerFromTuple(`{"model_id":"x",}`), want: ErrTupleJSON},
		{name: "tuple js comment", header: headerFromTuple(`{"model_id":"x"/*comment*/}`), want: ErrTupleJSON},
		{name: "tuple exponent integer", header: headerFromTuple(`{"model_id":"x","ttft_ms":1e3,"tokens_out":0,"unix_ts":0,"prompt_hash":"` + strings.Repeat("a", 64) + `","output_hash":"` + strings.Repeat("b", 64) + `","provider_pubkey":"A6EHv/POEL4dcN0Y50vAmWfk1jCbpQ1fHdyGZBJVMbg="}`), want: ErrTupleWrongType},
	}
	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			_, err := Parse(tt.header)
			if !errors.Is(err, tt.want) {
				t.Fatalf("Parse() error = %v, want %v", err, tt.want)
			}
		})
	}
}

func TestTupleFormatChecks(t *testing.T) {
	fixtures := loadFixtures(t)
	validPubkey := fixtures.Pubkey
	valid := func(fields string) string {
		return headerFromTuple("{" + fields + "}")
	}

	tests := []struct {
		name   string
		header string
		want   error
	}{
		{
			name:   "empty model",
			header: valid(`"model_id":"","output_hash":"` + strings.Repeat("b", 64) + `","prompt_hash":"` + strings.Repeat("a", 64) + `","provider_pubkey":"` + validPubkey + `","tokens_out":4,"ttft_ms":123,"unix_ts":1800000000`),
			want:   ErrTupleWrongType,
		},
		{
			name:   "uppercase prompt hash",
			header: valid(`"model_id":"fixture-model","output_hash":"` + strings.Repeat("b", 64) + `","prompt_hash":"` + strings.Repeat("A", 64) + `","provider_pubkey":"` + validPubkey + `","tokens_out":4,"ttft_ms":123,"unix_ts":1800000000`),
			want:   ErrTupleWrongType,
		},
		{
			name:   "short output hash",
			header: valid(`"model_id":"fixture-model","output_hash":"` + strings.Repeat("b", 63) + `","prompt_hash":"` + strings.Repeat("a", 64) + `","provider_pubkey":"` + validPubkey + `","tokens_out":4,"ttft_ms":123,"unix_ts":1800000000`),
			want:   ErrTupleWrongType,
		},
		{
			name:   "provider pubkey url safe",
			header: valid(`"model_id":"fixture-model","output_hash":"` + strings.Repeat("b", 64) + `","prompt_hash":"` + strings.Repeat("a", 64) + `","provider_pubkey":"` + strings.ReplaceAll(validPubkey, "/", "_") + `","tokens_out":4,"ttft_ms":123,"unix_ts":1800000000`),
			want:   ErrTupleWrongType,
		},
		{
			name:   "negative integer",
			header: valid(`"model_id":"fixture-model","output_hash":"` + strings.Repeat("b", 64) + `","prompt_hash":"` + strings.Repeat("a", 64) + `","provider_pubkey":"` + validPubkey + `","tokens_out":-1,"ttft_ms":123,"unix_ts":1800000000`),
			want:   ErrTupleWrongType,
		},
		{
			name:   "fractional integer",
			header: valid(`"model_id":"fixture-model","output_hash":"` + strings.Repeat("b", 64) + `","prompt_hash":"` + strings.Repeat("a", 64) + `","provider_pubkey":"` + validPubkey + `","tokens_out":4.0,"ttft_ms":123,"unix_ts":1800000000`),
			want:   ErrTupleWrongType,
		},
		// MAJOR-1 (round-1 audit): SPEC-015 §3.1 mandates verifiers reject
		// non-ASCII model_id. Two cases: raw UTF-8 byte in JSON, and \uXXXX
		// escape that decodes to non-ASCII.
		{
			name:   "model_id non-ASCII raw UTF-8 byte",
			header: valid(`"model_id":"café","output_hash":"` + strings.Repeat("b", 64) + `","prompt_hash":"` + strings.Repeat("a", 64) + `","provider_pubkey":"` + validPubkey + `","tokens_out":4,"ttft_ms":123,"unix_ts":1800000000`),
			want:   ErrTupleWrongType,
		},
		{
			name:   "model_id non-ASCII via JSON \\u escape",
			header: valid(`"model_id":"café","output_hash":"` + strings.Repeat("b", 64) + `","prompt_hash":"` + strings.Repeat("a", 64) + `","provider_pubkey":"` + validPubkey + `","tokens_out":4,"ttft_ms":123,"unix_ts":1800000000`),
			want:   ErrTupleWrongType,
		},
	}
	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			_, err := Parse(tt.header)
			if !errors.Is(err, tt.want) {
				t.Fatalf("Parse() error = %v, want %v", err, tt.want)
			}
		})
	}
}

func TestVerifyFailures(t *testing.T) {
	fixtures := loadFixtures(t)
	pubkey, err := ParsePubkey(fixtures.Pubkey)
	if err != nil {
		t.Fatalf("ParsePubkey(valid) error = %v", err)
	}
	tests := []struct {
		name   string
		header string
	}{
		{name: "tampered tuple", header: fixtures.TamperedTupleHeader},
		{name: "tampered signature", header: fixtures.TamperedSignatureHeader},
		{name: "noncanonical order", header: fixtures.NoncanonicalOrderHeader},
	}
	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			parsed, err := Parse(tt.header)
			if err != nil {
				t.Fatalf("Parse() error = %v", err)
			}
			if err := Verify(parsed, pubkey); !errors.Is(err, ErrSignatureFailed) {
				t.Fatalf("Verify() error = %v, want %v", err, ErrSignatureFailed)
			}
		})
	}
}

// TestVerifyRejectsAlternatePubkey: MAJOR-4 (round-1 audit) — confirm a
// valid receipt fails against a different but well-formed 32-byte pubkey.
// This guards against a verifier that accidentally accepts any well-formed
// pubkey (e.g. via a constant-time bug or a wrong key-source variable).
func TestVerifyRejectsAlternatePubkey(t *testing.T) {
	fixtures := loadFixtures(t)
	parsed, err := Parse(fixtures.ValidHeader)
	if err != nil {
		t.Fatalf("Parse(valid) error = %v", err)
	}
	// Use ed25519.NewKeyFromSeed with seed 0xFF...FF to produce a deterministic
	// but distinct pubkey from the fixture pubkey (seed 0x00...1F).
	altSeed := make([]byte, 32)
	for i := range altSeed {
		altSeed[i] = 0xFF
	}
	altPriv := ed25519.NewKeyFromSeed(altSeed)
	altPub := altPriv.Public().(ed25519.PublicKey)
	if err := Verify(parsed, altPub); !errors.Is(err, ErrSignatureFailed) {
		t.Fatalf("Verify(alt-pubkey) error = %v, want %v", err, ErrSignatureFailed)
	}
}

// TestVerifyPositiveRawBytesInvariant: MAJOR-3 (round-1 audit) — proves
// that a syntactically-valid noncanonical tuple verifies successfully
// when the signature was generated over THOSE noncanonical bytes. This is
// the positive raw-bytes invariant: the verifier does NOT re-canonicalize
// before signature verification; it signs/verifies the exact bytes the
// producer emitted.
//
// We build a tuple in noncanonical key order (intentionally NOT sorted),
// sign those exact bytes with a known ed25519 key, assemble the wire-format
// header, and confirm Parse + Verify succeed against the corresponding pubkey.
func TestVerifyPositiveRawBytesInvariant(t *testing.T) {
	// Same seed pattern as the fixture (0x00..0x1F) for determinism.
	seed := make([]byte, 32)
	for i := range seed {
		seed[i] = byte(i)
	}
	priv := ed25519.NewKeyFromSeed(seed)
	pub := priv.Public().(ed25519.PublicKey)
	pubB64 := base64.StdEncoding.EncodeToString(pub)

	// NONCANONICAL key order: model_id, prompt_hash, output_hash, etc. would
	// be the canonical (lexicographic) order. Here we put them in INSERTION
	// order — model_id first, then prompt_hash, output_hash, provider_pubkey,
	// ttft_ms, tokens_out, unix_ts — which differs from sorted order at the
	// JCS canonicalizer's output. Crucially, the signature is generated over
	// THIS byte sequence, not the canonical one.
	tupleBytes := []byte(`{"model_id":"fixture-model","prompt_hash":"` + strings.Repeat("a", 64) + `","output_hash":"` + strings.Repeat("b", 64) + `","provider_pubkey":"` + pubB64 + `","ttft_ms":123,"tokens_out":4,"unix_ts":1800000000}`)
	sig := ed25519.Sign(priv, tupleBytes)
	header := base64.StdEncoding.EncodeToString(tupleBytes) + "." + base64.StdEncoding.EncodeToString(sig)

	parsed, err := Parse(header)
	if err != nil {
		t.Fatalf("Parse(noncanonical-but-signed) error = %v", err)
	}
	if err := Verify(parsed, pub); err != nil {
		t.Fatalf("Verify(noncanonical-but-signed) error = %v; the raw-bytes invariant is BROKEN — the verifier appears to be re-canonicalizing before verification", err)
	}
}

func TestVerifyRejectsWrongPubkeyLength(t *testing.T) {
	fixtures := loadFixtures(t)
	parsed, err := Parse(fixtures.ValidHeader)
	if err != nil {
		t.Fatalf("Parse(valid) error = %v", err)
	}
	err = Verify(parsed, make([]byte, 31))
	if !errors.Is(err, ErrPubkeyLength) {
		t.Fatalf("Verify(short pubkey) error = %v, want %v", err, ErrPubkeyLength)
	}
}

func TestParsePubkey(t *testing.T) {
	fixtures := loadFixtures(t)
	pubkey, err := ParsePubkey(fixtures.Pubkey)
	if err != nil {
		t.Fatalf("ParsePubkey(valid) error = %v", err)
	}
	if len(pubkey) != 32 {
		t.Fatalf("pubkey length = %d, want 32", len(pubkey))
	}

	if _, err := ParsePubkey("not base64"); !errors.Is(err, ErrBase64Decode) {
		t.Fatalf("ParsePubkey(invalid base64) error = %v, want %v", err, ErrBase64Decode)
	}
	if _, err := ParsePubkey(base64.StdEncoding.EncodeToString(make([]byte, 31))); !errors.Is(err, ErrPubkeyLength) {
		t.Fatalf("ParsePubkey(short) error = %v, want %v", err, ErrPubkeyLength)
	}
}

func loadFixtures(t *testing.T) receiptFixtures {
	t.Helper()
	path := filepath.Join("..", "..", "testdata", "receipt_fixtures.json")
	data, err := os.ReadFile(path)
	if err != nil {
		t.Fatalf("read fixtures: %v", err)
	}
	var fixtures receiptFixtures
	if err := json.Unmarshal(data, &fixtures); err != nil {
		t.Fatalf("decode fixtures: %v", err)
	}
	if fixtures.Provenance == "" {
		t.Fatalf("fixture provenance missing")
	}
	return fixtures
}

func headerFromTuple(tuple string) string {
	return base64.StdEncoding.EncodeToString([]byte(tuple)) + "." + base64.StdEncoding.EncodeToString(make([]byte, 64))
}
