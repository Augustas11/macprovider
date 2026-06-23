package receipt

import (
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
		{name: "malformed tuple base64", header: "%%%.AAAA", want: ErrBase64Decode},
		{name: "malformed signature base64", header: "e30=.%%%", want: ErrBase64Decode},
		{name: "signature wrong length", header: fixtures.WrongSigLengthHeader, want: ErrSigLength},
		{name: "tuple extra key", header: fixtures.ExtraKeyHeader, want: ErrTupleExtraKey},
		{name: "tuple missing key", header: fixtures.MissingKeyHeader, want: ErrTupleMissingKey},
		{name: "tuple wrong type", header: fixtures.WrongTypeHeader, want: ErrTupleWrongType},
		{name: "tuple trailing whitespace", header: fixtures.NoncanonicalTrailingWhitespaceHeader, want: ErrTupleJSON},
		{name: "tuple invalid json", header: headerFromTuple("not-json"), want: ErrTupleJSON},
		{name: "tuple duplicate key", header: headerFromTuple(`{"model_id":"a","model_id":"b"}`), want: ErrTupleJSON},
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
