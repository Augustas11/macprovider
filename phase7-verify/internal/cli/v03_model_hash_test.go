package cli

import (
	"crypto/ed25519"
	"encoding/base64"
	"strings"
	"testing"
	"time"

	"github.com/augstar/macprovider/phase7-verify/internal/jcs"
)

// A v0.3 header with model_hash null or 64-hex must verify under an
// explicit --pubkey. v1.1.0 exited 65 with
// `input format error: tuple field has wrong type: json: unknown field "model_hash"`
// before the signature check, including when --pubkey was set.
func TestV03ModelHashVerifiesWithExplicitPubkey(t *testing.T) {
	priv := makeKey(9)
	pub := priv.Public().(ed25519.PublicKey)
	pubB64 := base64.StdEncoding.EncodeToString(pub)
	prompt := strings.Repeat("a", 64)
	output := strings.Repeat("b", 64)

	cases := []struct {
		name      string
		modelHash jcs.Value
	}{
		{name: "null", modelHash: jcs.Value{Kind: jcs.KindNull}},
		{name: "hex", modelHash: jcs.Value{Kind: jcs.KindString, String: strings.Repeat("c", 64)}},
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
					"unix_ts":         {Kind: jcs.KindInt, Int: cliNow.Unix()},
				},
			})
			if err != nil {
				t.Fatalf("canonicalize: %v", err)
			}
			header := base64.StdEncoding.EncodeToString(raw) + "." + base64.StdEncoding.EncodeToString(ed25519.Sign(priv, raw))
			stdout, stderr, c := buffersAndCache(t)
			code := run([]string{
				"--receipt", header,
				"--prompt-hash", prompt,
				"--output-hash", output,
				"--pubkey", pubB64,
				"--offline",
				"--json",
			}, nil, stdout, stderr, getenvNone, runConfig{cache: c, now: func() time.Time { return cliNow }})
			if code != exitValid {
				t.Fatalf("exit=%d want=%d stdout=%q stderr=%q", code, exitValid, stdout.String(), stderr.String())
			}
			if strings.Contains(stderr.String(), "unknown field") {
				t.Fatalf("stderr=%q", stderr.String())
			}
			if !strings.Contains(stdout.String(), `"result":"valid"`) {
				t.Fatalf("stdout=%q", stdout.String())
			}
		})
	}
}

func TestMalformedReceiptVersionDoesNotVerifyAsLegacy(t *testing.T) {
	priv := makeKey(11)
	pub := priv.Public().(ed25519.PublicKey)
	pubB64 := base64.StdEncoding.EncodeToString(pub)
	prompt := strings.Repeat("a", 64)
	output := strings.Repeat("b", 64)
	modelHash := strings.Repeat("c", 64)

	sign := func(t *testing.T, version jcs.Value) string {
		t.Helper()
		raw, err := jcs.Canonicalize(jcs.Value{
			Kind: jcs.KindObject,
			Object: map[string]jcs.Value{
				"model_hash":      {Kind: jcs.KindString, String: modelHash},
				"model_id":        {Kind: jcs.KindString, String: "fixture-model"},
				"output_hash":     {Kind: jcs.KindString, String: output},
				"prompt_hash":     {Kind: jcs.KindString, String: prompt},
				"provider_pubkey": {Kind: jcs.KindString, String: pubB64},
				"receipt_version": version,
				"tokens_out":      {Kind: jcs.KindInt, Int: 4},
				"ttft_ms":         {Kind: jcs.KindInt, Int: 123},
				"unix_ts":         {Kind: jcs.KindInt, Int: cliNow.Unix()},
			},
		})
		if err != nil {
			t.Fatalf("canonicalize: %v", err)
		}
		return base64.StdEncoding.EncodeToString(raw) + "." + base64.StdEncoding.EncodeToString(ed25519.Sign(priv, raw))
	}

	t.Run("empty string", func(t *testing.T) {
		stdout, stderr, c := buffersAndCache(t)
		code := run([]string{
			"--receipt", sign(t, jcs.Value{Kind: jcs.KindString, String: ""}),
			"--prompt-hash", prompt,
			"--output-hash", output,
			"--pubkey", pubB64,
			"--offline",
			"--json",
		}, nil, stdout, stderr, getenvNone, runConfig{cache: c, now: func() time.Time { return cliNow }})
		if code != exitInconclusive {
			t.Fatalf("exit=%d want=%d stdout=%q stderr=%q", code, exitInconclusive, stdout.String(), stderr.String())
		}
		if !strings.Contains(stdout.String(), `"reason":"unknown_receipt_version"`) || !strings.Contains(stdout.String(), `"receipt_version":""`) {
			t.Fatalf("stdout=%q", stdout.String())
		}
	})

	t.Run("future version without provider id", func(t *testing.T) {
		stdout, stderr, c := buffersAndCache(t)
		code := run([]string{
			"--receipt", sign(t, jcs.Value{Kind: jcs.KindString, String: "4"}),
			"--prompt-hash", prompt,
			"--output-hash", output,
			"--pubkey", pubB64,
			"--offline",
			"--json",
		}, nil, stdout, stderr, getenvNone, runConfig{cache: c, now: func() time.Time { return cliNow }})
		if code != exitInconclusive {
			t.Fatalf("exit=%d want=%d stdout=%q stderr=%q", code, exitInconclusive, stdout.String(), stderr.String())
		}
		if !strings.Contains(stdout.String(), `"receipt_version":"4"`) {
			t.Fatalf("stdout=%q", stdout.String())
		}
	})

	t.Run("future version without pubkey or provider id", func(t *testing.T) {
		stdout, stderr, c := buffersAndCache(t)
		code := run([]string{
			"--receipt", sign(t, jcs.Value{Kind: jcs.KindString, String: "4"}),
			"--prompt-hash", prompt,
			"--output-hash", output,
			"--offline",
			"--json",
		}, nil, stdout, stderr, getenvNone, runConfig{cache: c, now: func() time.Time { return cliNow }})
		if code != exitInconclusive {
			t.Fatalf("exit=%d want=%d stdout=%q stderr=%q", code, exitInconclusive, stdout.String(), stderr.String())
		}
	})

	t.Run("null", func(t *testing.T) {
		stdout, stderr, c := buffersAndCache(t)
		code := run([]string{
			"--receipt", sign(t, jcs.Value{Kind: jcs.KindNull}),
			"--prompt-hash", prompt,
			"--output-hash", output,
			"--pubkey", pubB64,
			"--offline",
			"--json",
		}, nil, stdout, stderr, getenvNone, runConfig{cache: c, now: func() time.Time { return cliNow }})
		if code != exitDataErr {
			t.Fatalf("exit=%d want=%d stdout=%q stderr=%q", code, exitDataErr, stdout.String(), stderr.String())
		}
		if !strings.Contains(stderr.String(), "receipt_version") {
			t.Fatalf("stderr=%q", stderr.String())
		}
	})
}
