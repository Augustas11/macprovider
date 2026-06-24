package canon

import (
	"crypto/ed25519"
	"encoding/base64"
	"encoding/hex"
	"fmt"
	"testing"

	"github.com/augstar/macprovider/phase7-verify/internal/receipt"
)

func TestCanonicalHashesMatchParsedReceiptTuple(t *testing.T) {
	request := decodeMap(t, `{
		"model":"llama-3.2-3b-instruct",
		"max_tokens":32,
		"messages":[{"role":"user","content":"SPEC-015 cross-service receipt"}]
	}`)
	response := decodeMap(t, `{
		"id":"chatcmpl-fake-integration",
		"object":"chat.completion",
		"created":1780000000,
		"model":"llama-3.2-3b-instruct",
		"usage":{"prompt_tokens":8,"completion_tokens":12,"total_tokens":20},
		"choices":[{"index":0,"message":{"role":"assistant","content":"hello from fake provider"},"finish_reason":"stop"}]
	}`)

	_, promptHash, err := CanonicalPrompt(request)
	if err != nil {
		t.Fatalf("CanonicalPrompt() error = %v", err)
	}
	_, outputHash, err := CanonicalOutput(response)
	if err != nil {
		t.Fatalf("CanonicalOutput() error = %v", err)
	}

	pubkey, privkey, err := ed25519KeyFixture()
	if err != nil {
		t.Fatalf("ed25519 fixture: %v", err)
	}
	header := receiptHeaderFixture(
		hex.EncodeToString(promptHash[:]),
		hex.EncodeToString(outputHash[:]),
		base64.StdEncoding.EncodeToString(pubkey),
		privkey,
	)

	parsed, err := receipt.Parse(header)
	if err != nil {
		t.Fatalf("receipt.Parse() error = %v", err)
	}
	if err := receipt.Verify(parsed, pubkey); err != nil {
		t.Fatalf("receipt.Verify() error = %v", err)
	}
	if got, want := parsed.Tuple.PromptHash, hex.EncodeToString(promptHash[:]); got != want {
		t.Fatalf("prompt_hash = %s, want %s", got, want)
	}
	if got, want := parsed.Tuple.OutputHash, hex.EncodeToString(outputHash[:]); got != want {
		t.Fatalf("output_hash = %s, want %s", got, want)
	}
}

func ed25519KeyFixture() (ed25519.PublicKey, ed25519.PrivateKey, error) {
	seed := make([]byte, ed25519.SeedSize)
	for i := range seed {
		seed[i] = byte(i)
	}
	privkey := ed25519.NewKeyFromSeed(seed)
	return privkey.Public().(ed25519.PublicKey), privkey, nil
}

func receiptHeaderFixture(promptHash, outputHash, pubkey string, privkey ed25519.PrivateKey) string {
	tuple := fmt.Sprintf(
		`{"model_id":"llama-3.2-3b-instruct","output_hash":"%s","prompt_hash":"%s","provider_pubkey":"%s","tokens_out":12,"ttft_ms":0,"unix_ts":1780000000}`,
		outputHash,
		promptHash,
		pubkey,
	)
	signature := ed25519.Sign(privkey, []byte(tuple))
	return base64.StdEncoding.EncodeToString([]byte(tuple)) + "." + base64.StdEncoding.EncodeToString(signature)
}
