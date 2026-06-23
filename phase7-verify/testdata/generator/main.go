package main

import (
	"crypto/ed25519"
	"crypto/sha256"
	"encoding/base64"
	"encoding/binary"
	"encoding/json"
	"flag"
	"fmt"
	"os"
	"path/filepath"
	"strings"
	"time"

	"github.com/augstar/macprovider/phase7-verify/internal/canon"
	"github.com/augstar/macprovider/phase7-verify/internal/jcs"
)

const (
	defaultSeed      = int64(0xCAFEBABE)
	providerID       = "m1-anon"
	unknownProvider  = "unknown-provider"
	modelID          = "fixture-model"
	ttftMS           = int64(123)
	tokensOut        = int64(9)
	bundleVersion    = 1
	validFreshUnixTS = int64(1782216000) // 2026-06-23T12:00:00Z
)

type bundle struct {
	BundleVersion int            `json:"bundle_version"`
	Receipt       string         `json:"receipt"`
	ProviderID    string         `json:"provider_id,omitempty"`
	Request       map[string]any `json:"request"`
	Response      map[string]any `json:"response"`
}

type tuple struct {
	ModelID        string
	PromptHash     string
	OutputHash     string
	ProviderPubkey string
	TTFTms         int64
	TokensOut      int64
	UnixTS         int64
}

func main() {
	seed := flag.Int64("seed", defaultSeed, "deterministic fixture seed")
	out := flag.String("out", "phase7-verify/testdata", "fixture output directory")
	flag.Parse()

	if err := os.MkdirAll(*out, 0o755); err != nil {
		fatal(err)
	}
	if err := generate(*seed, *out); err != nil {
		fatal(err)
	}
}

func generate(seed int64, out string) error {
	current := keyFromSeed(seed, "current")
	previous := keyFromSeed(seed, "previous")
	foreign := keyFromSeed(seed, "foreign")

	validFresh, err := signedBundle(current, providerID, validFreshUnixTS)
	if err != nil {
		return err
	}
	if err := writeBundle(out, "valid_fresh.bundle.json", validFresh); err != nil {
		return err
	}

	rotatedAt := time.Unix(validFreshUnixTS, 0).UTC().Add(time.Hour)
	expiresAt := rotatedAt.Add(7 * 24 * time.Hour)
	validPrev, err := signedBundle(previous, providerID, rotatedAt.Add(-30*time.Second).Unix())
	if err != nil {
		return err
	}
	if err := writeBundle(out, "valid_prev_key_in_grace.bundle.json", validPrev); err != nil {
		return err
	}

	tamperedOutput := cloneBundle(validFresh)
	choice0(tamperedOutput.Response)["message"].(map[string]any)["content"] = "Receipt verification proves signed output."
	if err := writeBundle(out, "invalid_tampered_output.bundle.json", tamperedOutput); err != nil {
		return err
	}

	tamperedPrompt := cloneBundle(validFresh)
	tamperedPrompt.Request["messages"].([]any)[0].(map[string]any)["content"] = "Explain receipt verification in two sentences."
	if err := writeBundle(out, "invalid_tampered_prompt.bundle.json", tamperedPrompt); err != nil {
		return err
	}

	tamperedUnixTS := cloneBundle(validFresh)
	tamperedUnixTS.Receipt, err = mutateTupleUnixTS(tamperedUnixTS.Receipt, validFreshUnixTS)
	if err != nil {
		return err
	}
	if err := writeBundle(out, "invalid_tampered_unix_ts.bundle.json", tamperedUnixTS); err != nil {
		return err
	}

	pubkeyNotEndorsed, err := signedBundle(foreign, providerID, validFreshUnixTS)
	if err != nil {
		return err
	}
	if err := writeBundle(out, "invalid_pubkey_not_endorsed.bundle.json", pubkeyNotEndorsed); err != nil {
		return err
	}

	prevOutside, err := signedBundle(previous, providerID, expiresAt.Add(time.Second).Unix())
	if err != nil {
		return err
	}
	if err := writeBundle(out, "invalid_prev_key_outside_grace.bundle.json", prevOutside); err != nil {
		return err
	}

	resolver404 := cloneBundle(validFresh)
	resolver404.ProviderID = unknownProvider
	if err := writeBundle(out, "inconclusive_resolver_404.bundle.json", resolver404); err != nil {
		return err
	}

	staleCache := cloneBundle(validFresh)
	staleCache.ProviderID = ""
	if err := writeBundle(out, "inconclusive_stale_cache_live_fail.bundle.json", staleCache); err != nil {
		return err
	}

	if err := writeMalformedBundle(out, validFresh); err != nil {
		return err
	}

	malformedReceipt := cloneBundle(validFresh)
	malformedReceipt.Receipt = "receipt-without-dot"
	if err := writeBundle(out, "malformed_receipt.bundle.json", malformedReceipt); err != nil {
		return err
	}

	if err := writeBundle(out, "invalid_bundle_pubkey_provider_mismatch.bundle.json", validFresh); err != nil {
		return err
	}
	return nil
}

func signedBundle(priv ed25519.PrivateKey, bundleProviderID string, unixTS int64) (bundle, error) {
	request := baseRequest()
	response := baseResponse()
	_, promptHash, err := canon.CanonicalPrompt(request)
	if err != nil {
		return bundle{}, fmt.Errorf("canonical prompt: %w", err)
	}
	_, outputHash, err := canon.CanonicalOutput(response)
	if err != nil {
		return bundle{}, fmt.Errorf("canonical output: %w", err)
	}
	pub := priv.Public().(ed25519.PublicKey)
	tupleRaw, err := canonicalTuple(tuple{
		ModelID:        modelID,
		PromptHash:     fmt.Sprintf("%x", promptHash),
		OutputHash:     fmt.Sprintf("%x", outputHash),
		ProviderPubkey: base64.StdEncoding.EncodeToString(pub),
		TTFTms:         ttftMS,
		TokensOut:      tokensOut,
		UnixTS:         unixTS,
	})
	if err != nil {
		return bundle{}, err
	}
	sig := ed25519.Sign(priv, tupleRaw)
	return bundle{
		BundleVersion: bundleVersion,
		Receipt:       base64.StdEncoding.EncodeToString(tupleRaw) + "." + base64.StdEncoding.EncodeToString(sig),
		ProviderID:    bundleProviderID,
		Request:       request,
		Response:      response,
	}, nil
}

func canonicalTuple(t tuple) ([]byte, error) {
	return jcs.Canonicalize(jcs.Value{Kind: jcs.KindObject, Object: map[string]jcs.Value{
		"model_id":        {Kind: jcs.KindString, String: t.ModelID},
		"prompt_hash":     {Kind: jcs.KindString, String: t.PromptHash},
		"output_hash":     {Kind: jcs.KindString, String: t.OutputHash},
		"provider_pubkey": {Kind: jcs.KindString, String: t.ProviderPubkey},
		"ttft_ms":         {Kind: jcs.KindInt, Int: t.TTFTms},
		"tokens_out":      {Kind: jcs.KindInt, Int: t.TokensOut},
		"unix_ts":         {Kind: jcs.KindInt, Int: t.UnixTS},
	}})
}

func baseRequest() map[string]any {
	return map[string]any{
		"model": "fixture-model",
		"messages": []any{
			map[string]any{
				"role":    "system",
				"content": "Answer concisely.",
			},
			map[string]any{
				"role":    "user",
				"content": "Explain receipt verification in one sentence.",
			},
		},
		"temperature":       json.Number("0.2"),
		"top_p":             json.Number("0.95"),
		"max_tokens":        json.Number("64"),
		"presence_penalty":  json.Number("0"),
		"frequency_penalty": json.Number("0"),
		"n":                 json.Number("1"),
	}
}

func baseResponse() map[string]any {
	return map[string]any{
		"id":      "chatcmpl-fixture",
		"object":  "chat.completion",
		"created": json.Number(fmt.Sprintf("%d", validFreshUnixTS)),
		"model":   modelID,
		"choices": []any{
			map[string]any{
				"index": json.Number("0"),
				"message": map[string]any{
					"role":    "assistant",
					"content": "Receipt verification proves signed prompt and output hashes.",
				},
				"finish_reason": "stop",
			},
		},
		"usage": map[string]any{
			"prompt_tokens":     json.Number("7"),
			"completion_tokens": json.Number(fmt.Sprintf("%d", tokensOut)),
			"total_tokens":      json.Number("16"),
		},
	}
}

func mutateTupleUnixTS(header string, unixTS int64) (string, error) {
	parts := strings.Split(header, ".")
	if len(parts) != 2 {
		return "", fmt.Errorf("receipt header does not contain one dot")
	}
	tupleRaw, err := base64.StdEncoding.DecodeString(parts[0])
	if err != nil {
		return "", err
	}
	from := []byte(fmt.Sprintf(`"unix_ts":%d`, unixTS))
	to := []byte(fmt.Sprintf(`"unix_ts":%d`, unixTS+1))
	if !strings.Contains(string(tupleRaw), string(from)) {
		return "", fmt.Errorf("tuple missing unix_ts fragment %q", from)
	}
	mutated := strings.Replace(string(tupleRaw), string(from), string(to), 1)
	return base64.StdEncoding.EncodeToString([]byte(mutated)) + "." + parts[1], nil
}

func keyFromSeed(seed int64, label string) ed25519.PrivateKey {
	var buf [8]byte
	binary.LittleEndian.PutUint64(buf[:], uint64(seed))
	sum := sha256.Sum256(append(buf[:], []byte(label)...))
	return ed25519.NewKeyFromSeed(sum[:])
}

func cloneBundle(in bundle) bundle {
	data, err := json.Marshal(in)
	if err != nil {
		panic(err)
	}
	var out bundle
	decoder := json.NewDecoder(strings.NewReader(string(data)))
	decoder.UseNumber()
	if err := decoder.Decode(&out); err != nil {
		panic(err)
	}
	return out
}

func choice0(response map[string]any) map[string]any {
	return response["choices"].([]any)[0].(map[string]any)
}

func writeBundle(out, name string, b bundle) error {
	return writeJSON(out, name, b)
}

func writeMalformedBundle(out string, b bundle) error {
	data, err := json.Marshal(b)
	if err != nil {
		return err
	}
	var object map[string]any
	decoder := json.NewDecoder(strings.NewReader(string(data)))
	decoder.UseNumber()
	if err := decoder.Decode(&object); err != nil {
		return err
	}
	object["unexpected"] = true
	return writeJSON(out, "malformed_bundle.bundle.json", object)
}

func writeJSON(out, name string, value any) error {
	data, err := json.MarshalIndent(value, "", "  ")
	if err != nil {
		return err
	}
	data = append(data, '\n')
	return os.WriteFile(filepath.Join(out, name), data, 0o644)
}

func fatal(err error) {
	fmt.Fprintln(os.Stderr, err)
	os.Exit(1)
}
