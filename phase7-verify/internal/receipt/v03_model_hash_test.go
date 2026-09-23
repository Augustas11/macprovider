package receipt

import (
	"crypto/ed25519"
	"encoding/base64"
	"errors"
	"strings"
	"testing"

	"github.com/augstar/macprovider/phase7-verify/internal/jcs"
)

// SPEC-015 §M.0 live buyer receipts carry model_hash as a 64-hex string
// or JSON null, plus receipt_version "3". No captured production header
// is stored in this repo. These fixtures are the provider wire shape from
// ReceiptBuilder.tupleObject: nine keys, JCS canonical bytes, signed over
// those exact bytes.
func TestParseV03ModelHashStringAndNull(t *testing.T) {
	seed := make([]byte, ed25519.SeedSize)
	for i := range seed {
		seed[i] = byte(i + 1)
	}
	priv := ed25519.NewKeyFromSeed(seed)
	pub := priv.Public().(ed25519.PublicKey)
	pubB64 := base64.StdEncoding.EncodeToString(pub)
	prompt := strings.Repeat("a", 64)
	output := strings.Repeat("b", 64)
	modelHash := strings.Repeat("c", 64)

	cases := []struct {
		name      string
		modelHash jcs.Value
		wantNull  bool
		wantHash  string
	}{
		{
			name:      "null",
			modelHash: jcs.Value{Kind: jcs.KindNull},
			wantNull:  true,
		},
		{
			name:      "hex",
			modelHash: jcs.Value{Kind: jcs.KindString, String: modelHash},
			wantHash:  modelHash,
		},
	}
	for _, tt := range cases {
		t.Run(tt.name, func(t *testing.T) {
			raw, err := jcs.Canonicalize(jcs.Value{
				Kind: jcs.KindObject,
				Object: map[string]jcs.Value{
					"model_hash":      tt.modelHash,
					"model_id":        {Kind: jcs.KindString, String: "fixture-model"},
					"output_hash":     {Kind: jcs.KindString, String: output},
					"prompt_hash":     {Kind: jcs.KindString, String: prompt},
					"provider_pubkey": {Kind: jcs.KindString, String: pubB64},
					"receipt_version": {Kind: jcs.KindString, String: "3"},
					"tokens_out":      {Kind: jcs.KindInt, Int: 4},
					"ttft_ms":         {Kind: jcs.KindInt, Int: 123},
					"unix_ts":         {Kind: jcs.KindInt, Int: 1_800_000_000},
				},
			})
			if err != nil {
				t.Fatalf("canonicalize: %v", err)
			}
			// JCS order for the v0.3 tuple. The parser accepts any key
			// order; the signature is over these exact bytes.
			prev := -1
			for _, key := range []string{
				`"model_hash":`,
				`"model_id":`,
				`"output_hash":`,
				`"prompt_hash":`,
				`"provider_pubkey":`,
				`"receipt_version":"3"`,
				`"tokens_out":4`,
				`"ttft_ms":123`,
				`"unix_ts":1800000000`,
			} {
				idx := strings.Index(string(raw), key)
				if idx <= prev {
					t.Fatalf("canonical bytes %s missing %s in order", raw, key)
				}
				prev = idx
			}
			signature := ed25519.Sign(priv, raw)
			header := base64.StdEncoding.EncodeToString(raw) + "." + base64.StdEncoding.EncodeToString(signature)

			parsed, err := Parse(header)
			if err != nil {
				t.Fatalf("Parse() error = %v", err)
			}
			if string(parsed.TupleRaw) != string(raw) {
				t.Fatalf("TupleRaw = %s, want signed bytes %s", parsed.TupleRaw, raw)
			}
			if err := Verify(parsed, pub); err != nil {
				t.Fatalf("Verify() error = %v", err)
			}
			if parsed.Tuple.ReceiptVersion != "3" {
				t.Fatalf("ReceiptVersion = %q", parsed.Tuple.ReceiptVersion)
			}
			if !parsed.Tuple.ModelHashPresent {
				t.Fatal("ModelHashPresent = false")
			}
			if parsed.Tuple.ModelHashNull != tt.wantNull {
				t.Fatalf("ModelHashNull = %v, want %v", parsed.Tuple.ModelHashNull, tt.wantNull)
			}
			if parsed.Tuple.ModelHash != tt.wantHash {
				t.Fatalf("ModelHash = %q, want %q", parsed.Tuple.ModelHash, tt.wantHash)
			}
			if parsed.Tuple.ModelID != "fixture-model" || parsed.Tuple.TTFTms != 123 || parsed.Tuple.TokensOut != 4 {
				t.Fatalf("tuple = %+v", parsed.Tuple)
			}
		})
	}
}

func TestParseV03EmptyReceiptVersionIsNotLegacy(t *testing.T) {
	raw := []byte(`{"model_hash":null,"model_id":"fixture-model","output_hash":"` + strings.Repeat("b", 64) + `","prompt_hash":"` + strings.Repeat("a", 64) + `","provider_pubkey":"AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA=","receipt_version":"","tokens_out":4,"ttft_ms":123,"unix_ts":1800000000}`)
	parsed, err := Parse(headerFromTuple(string(raw)))
	if err != nil {
		t.Fatalf("Parse() error = %v", err)
	}
	if !parsed.Tuple.ReceiptVersionPresent {
		t.Fatal("empty receipt_version was treated as absent")
	}
	if parsed.Tuple.ReceiptVersion != "" {
		t.Fatalf("ReceiptVersion = %q", parsed.Tuple.ReceiptVersion)
	}
	if parsed.Tuple.ModelHashPresent {
		t.Fatal("unknown version must return before model_hash interpretation")
	}
}

func TestParseV03ModelHashRejectsBadValues(t *testing.T) {
	pub := "AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA="
	base := func(modelHash string) string {
		return headerFromTuple(`{"model_hash":` + modelHash + `,"model_id":"fixture-model","output_hash":"` + strings.Repeat("b", 64) + `","prompt_hash":"` + strings.Repeat("a", 64) + `","provider_pubkey":"` + pub + `","receipt_version":"3","tokens_out":4,"ttft_ms":123,"unix_ts":1800000000}`)
	}
	tests := []struct {
		name   string
		header string
		want   error
	}{
		{name: "number", header: base("1"), want: ErrTupleWrongType},
		{name: "bool", header: base("true"), want: ErrTupleWrongType},
		{name: "empty string", header: base(`""`), want: ErrTupleWrongType},
		{name: "uppercase hex", header: base(`"` + strings.Repeat("A", 64) + `"`), want: ErrTupleWrongType},
		{name: "short hex", header: base(`"abcd"`), want: ErrTupleWrongType},
		{
			name:   "exponent integer survives the model_hash strip",
			header: headerFromTuple(`{"model_hash":null,"model_id":"fixture-model","output_hash":"` + strings.Repeat("b", 64) + `","prompt_hash":"` + strings.Repeat("a", 64) + `","provider_pubkey":"` + pub + `","receipt_version":"3","tokens_out":4,"ttft_ms":1e3,"unix_ts":1800000000}`),
			want:   ErrTupleWrongType,
		},
		{
			name:   "extra key",
			header: headerFromTuple(`{"extra":1,"model_hash":null,"model_id":"fixture-model","output_hash":"` + strings.Repeat("b", 64) + `","prompt_hash":"` + strings.Repeat("a", 64) + `","provider_pubkey":"` + pub + `","receipt_version":"3","tokens_out":4,"ttft_ms":123,"unix_ts":1800000000}`),
			want:   ErrTupleExtraKey,
		},
		{
			name:   "null receipt_version",
			header: headerFromTuple(`{"model_hash":null,"model_id":"fixture-model","output_hash":"` + strings.Repeat("b", 64) + `","prompt_hash":"` + strings.Repeat("a", 64) + `","provider_pubkey":"` + pub + `","receipt_version":null,"tokens_out":4,"ttft_ms":123,"unix_ts":1800000000}`),
			want:   ErrTupleWrongType,
		},
		{
			name:   "numeric receipt_version",
			header: headerFromTuple(`{"model_hash":null,"model_id":"fixture-model","output_hash":"` + strings.Repeat("b", 64) + `","prompt_hash":"` + strings.Repeat("a", 64) + `","provider_pubkey":"` + pub + `","receipt_version":3,"tokens_out":4,"ttft_ms":123,"unix_ts":1800000000}`),
			want:   ErrTupleWrongType,
		},
		{
			name:   "missing model_hash",
			header: headerFromTuple(`{"model_id":"fixture-model","output_hash":"` + strings.Repeat("b", 64) + `","prompt_hash":"` + strings.Repeat("a", 64) + `","provider_pubkey":"` + pub + `","receipt_version":"3","tokens_out":4,"ttft_ms":123,"unix_ts":1800000000}`),
			want:   ErrTupleMissingKey,
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
