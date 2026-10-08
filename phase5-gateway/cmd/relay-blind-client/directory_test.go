package main

import (
	"bytes"
	"context"
	"crypto/ed25519"
	"net/http"
	"net/http/httptest"
	"strings"
	"sync/atomic"
	"testing"
	"time"

	"github.com/augstar/macprovider-gateway/internal/relayblind"
)

// SPEC-049-R028: with no --identity-pin, the client pins the provider from
// the signed directory and completes the privacy-class run.
func TestPrivacyClientAutoPinsFromSignedDirectory(t *testing.T) {
	for _, tc := range []struct {
		name           string
		stream, wallet bool
	}{
		{name: "nonstream"},
		{name: "stream", stream: true},
	} {
		t.Run(tc.name, func(t *testing.T) {
			content := privacyContent(tc.stream)
			stdout, stderr, calls, err := runPrivacyClient(t, privacyClientSpec{stream: tc.stream, wallet: tc.wallet, content: content, directory: true})
			if err != nil {
				t.Fatalf("run: %v", err)
			}
			if stdout != string(content) {
				t.Fatalf("stdout=%q", stdout)
			}
			assertPrivacyStderr(t, stderr)
			if !strings.Contains(stderr, "identity_pin_source: signed_directory directory_key_id="+relayblind.PublicKeyFingerprint(cliDirectoryKey.Public().(ed25519.PublicKey))) {
				t.Fatalf("stderr does not name the directory pin source: %q", stderr)
			}
			if calls != 3 {
				t.Fatalf("calls=%d, want directory + reservation + chat", calls)
			}
		})
	}
}

func TestPrivacyClientDirectoryRejections(t *testing.T) {
	other := ed25519.NewKeyFromSeed(bytes.Repeat([]byte{0x45}, ed25519.SeedSize))
	for _, tc := range []struct {
		name      string
		spec      privacyClientSpec
		wantCalls int32
		want      string
	}{
		{name: "signed by another key", spec: privacyClientSpec{directory: true, directorySigner: other}, wantCalls: 1, want: "privacy identity directory rejected"},
		{name: "tampered", spec: privacyClientSpec{directory: true, directoryBytes: func(raw []byte) []byte {
			return bytes.Replace(raw, []byte(`"payload":"`), []byte(`"payload":"A`), 1)
		}}, wantCalls: 1, want: "privacy identity directory rejected"},
		{name: "expired", spec: privacyClientSpec{directory: true, directoryEdit: func(d *relayblind.IdentityDirectory) {
			d.IssuedAtUnix -= 400
			d.ExpiresAtUnix -= 400
		}}, wantCalls: 1, want: "privacy identity directory rejected"},
		{name: "identity revoked", spec: privacyClientSpec{directory: true, directoryEdit: func(d *relayblind.IdentityDirectory) {
			d.Entries[0].Revoked = true
		}}, wantCalls: 2, want: "provider identity rejected"},
		{name: "identity absent", spec: privacyClientSpec{directory: true, directoryEdit: func(d *relayblind.IdentityDirectory) {
			d.Entries = []relayblind.IdentityDirectoryEntry{}
		}}, wantCalls: 2, want: "provider identity rejected"},
	} {
		t.Run(tc.name, func(t *testing.T) {
			stdout, _, calls, err := runPrivacyClient(t, tc.spec)
			if err == nil || !strings.Contains(err.Error(), tc.want) {
				t.Fatalf("err=%v, want %q", err, tc.want)
			}
			if calls != tc.wantCalls {
				t.Fatalf("calls=%d want %d; nothing may be encrypted or sent after a directory rejection", calls, tc.wantCalls)
			}
			if stdout != "" {
				t.Fatalf("stdout=%q", stdout)
			}
		})
	}
}

func TestPrivacyClientDirectoryRefusesWalletSessionBeforeNetwork(t *testing.T) {
	_, _, calls, err := runPrivacyClient(t, privacyClientSpec{directory: true, wallet: true})
	if err == nil || !strings.Contains(err.Error(), "--identity-pin") {
		t.Fatalf("wallet directory run err=%v", err)
	}
	if calls != 0 {
		t.Fatalf("calls=%d; network used before the wallet refusal", calls)
	}
}

func TestPrivacyClientDirectoryKeyRequiredBeforeNetwork(t *testing.T) {
	var calls atomic.Int32
	server := httptest.NewServer(http.HandlerFunc(func(http.ResponseWriter, *http.Request) { calls.Add(1) }))
	defer server.Close()
	opts := options{baseURL: server.URL, model: "model-a", input: "-", maxOutputTokens: 32, inputTokenUpperBound: 96, privacyClass: true, apiKeyEnv: "KEY", walletSessionKeyEnv: "WALLET", timeout: time.Minute}
	for _, key := range []string{"", "not-a-key", strings.Repeat("A", 44)} {
		opts.directoryPublicKey = key
		var stdout, stderr bytes.Buffer
		err := run(context.Background(), opts, strings.NewReader(`{"model":"model-a","messages":[],"max_tokens":32}`), &stdout, &stderr, func(name string) string {
			if name == "KEY" {
				return "bearer-secret"
			}
			return ""
		})
		if err == nil {
			t.Fatalf("directory key %q accepted", key)
		}
	}
	if calls.Load() != 0 {
		t.Fatalf("calls=%d; network used before the directory key was validated", calls.Load())
	}
}
