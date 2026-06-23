package cli

import (
	"bytes"
	"crypto/ed25519"
	"encoding/base64"
	"encoding/json"
	"fmt"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"strings"
	"sync/atomic"
	"testing"
	"time"

	"github.com/augstar/macprovider/phase7-verify/internal/cache"
	"github.com/augstar/macprovider/phase7-verify/internal/canon"
	"github.com/augstar/macprovider/phase7-verify/internal/version"
)

const testProviderID = "m1-anon"

var cliNow = time.Date(2026, 6, 23, 12, 0, 0, 0, time.UTC)

func TestCLIExitCodesAC25(t *testing.T) {
	fixture := newCLIFixture(t, makeKey(1), cliNow.Unix())
	tests := []struct {
		name   string
		args   func(*httptest.Server, *cliFixture) []string
		body   string
		status int
		cache  bool
		want   int
	}{
		{
			name: "0 valid",
			args: func(server *httptest.Server, f *cliFixture) []string {
				return headerArgs(server.URL, f, "--provider-id", testProviderID)
			},
			status: http.StatusOK,
			want:   exitValid,
		},
		{
			name: "1 invalid",
			args: func(server *httptest.Server, f *cliFixture) []string {
				return headerArgs(server.URL, f, "--provider-id", testProviderID, "--output-hash", strings.Repeat("0", 64))
			},
			status: http.StatusOK,
			want:   exitInvalid,
		},
		{
			name: "2 inconclusive",
			args: func(server *httptest.Server, f *cliFixture) []string {
				return headerArgs(server.URL, f, "--provider-id", testProviderID)
			},
			status: http.StatusInternalServerError,
			want:   exitInconclusive,
		},
		{
			name: "64 usage",
			args: func(server *httptest.Server, f *cliFixture) []string {
				return []string{"--receipt", f.header, "--prompt-hash", f.promptHash}
			},
			want: exitUsage,
		},
		{
			name: "65 input format",
			args: func(server *httptest.Server, f *cliFixture) []string {
				return []string{"--bundle", "-"}
			},
			body: `{"bundle_version":99,"receipt":"x","request":{},"response":{}}`,
			want: exitDataErr,
		},
	}
	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			var calls int32
			server := receiptKeyServer(t, fixture.pub, tt.status, &calls)
			defer server.Close()
			stdout, stderr, c := buffersAndCache(t)
			code := run(tt.args(server, fixture), strings.NewReader(tt.body), stdout, stderr, getenvNone, runConfig{
				httpClient: server.Client(),
				cache:      c,
				now:        func() time.Time { return cliNow },
			})
			if code != tt.want {
				t.Fatalf("exit = %d, want %d; stdout=%q stderr=%q", code, tt.want, stdout.String(), stderr.String())
			}
		})
	}
}

func TestHeaderHashesMode(t *testing.T) {
	fixture := newCLIFixture(t, makeKey(2), cliNow.Unix())
	tests := []struct {
		name       string
		args       []string
		status     int
		wantCode   int
		wantResult string
	}{
		{
			name:       "valid",
			args:       []string{"--provider-id", testProviderID},
			status:     http.StatusOK,
			wantCode:   exitValid,
			wantResult: "valid",
		},
		{
			name:       "invalid via explicit output hash mismatch",
			args:       []string{"--provider-id", testProviderID, "--output-hash", strings.Repeat("0", 64)},
			status:     http.StatusOK,
			wantCode:   exitInvalid,
			wantResult: "invalid",
		},
		{
			name:       "inconclusive on live failure",
			args:       []string{"--provider-id", testProviderID},
			status:     http.StatusInternalServerError,
			wantCode:   exitInconclusive,
			wantResult: "inconclusive",
		},
	}
	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			server := receiptKeyServer(t, fixture.pub, tt.status, nil)
			defer server.Close()
			args := headerArgs(server.URL, fixture, tt.args...)
			stdout, stderr, c := buffersAndCache(t)
			code := run(args, nil, stdout, stderr, getenvNone, runConfig{httpClient: server.Client(), cache: c, now: func() time.Time { return cliNow }})
			if code != tt.wantCode {
				t.Fatalf("exit=%d want=%d stdout=%q stderr=%q", code, tt.wantCode, stdout.String(), stderr.String())
			}
			if !strings.Contains(stdout.String(), tt.wantResult) {
				t.Fatalf("stdout=%q missing %q", stdout.String(), tt.wantResult)
			}
		})
	}
}

func TestBundleModeStrictnessAndStdin(t *testing.T) {
	fixture := newCLIFixture(t, makeKey(3), cliNow.Unix())
	tests := []struct {
		name string
		body string
		args []string
		want int
	}{
		{name: "well formed valid bundle", body: fixture.bundleJSON(testProviderID), args: []string{"--bundle", "-"}, want: exitValid},
		{name: "missing bundle version", body: fmt.Sprintf(`{"receipt":%q,"request":{},"response":{}}`, fixture.header), args: []string{"--bundle", "-"}, want: exitDataErr},
		{name: "bundle version wrong", body: `{"bundle_version":99,"receipt":"x","request":{},"response":{}}`, args: []string{"--bundle", "-"}, want: exitDataErr},
		{name: "bundle version two", body: `{"bundle_version":2,"receipt":"x","request":{},"response":{}}`, args: []string{"--bundle", "-"}, want: exitDataErr},
		{name: "bundle version string", body: `{"bundle_version":"1","receipt":"x","request":{},"response":{}}`, args: []string{"--bundle", "-"}, want: exitDataErr},
		{name: "bundle version bool", body: `{"bundle_version":true,"receipt":"x","request":{},"response":{}}`, args: []string{"--bundle", "-"}, want: exitDataErr},
		{name: "unknown top level key", body: `{"bundle_version":1,"receipt":"x","request":{},"response":{},"foo":1}`, args: []string{"--bundle", "-"}, want: exitDataErr},
		{name: "missing receipt", body: `{"bundle_version":1,"request":{},"response":{}}`, args: []string{"--bundle", "-"}, want: exitDataErr},
		{name: "missing request", body: fmt.Sprintf(`{"bundle_version":1,"receipt":%q,"response":{}}`, fixture.header), args: []string{"--bundle", "-"}, want: exitDataErr},
		{name: "missing response", body: fmt.Sprintf(`{"bundle_version":1,"receipt":%q,"request":{}}`, fixture.header), args: []string{"--bundle", "-"}, want: exitDataErr},
		{name: "json not parseable", body: `{`, args: []string{"--bundle", "-"}, want: exitDataErr},
	}
	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			server := receiptKeyServer(t, fixture.pub, http.StatusOK, nil)
			defer server.Close()
			args := append(tt.args, "--coordinator", server.URL)
			stdout, stderr, c := buffersAndCache(t)
			code := run(args, strings.NewReader(tt.body), stdout, stderr, getenvNone, runConfig{httpClient: server.Client(), cache: c, now: func() time.Time { return cliNow }})
			if code != tt.want {
				t.Fatalf("exit=%d want=%d stdout=%q stderr=%q", code, tt.want, stdout.String(), stderr.String())
			}
		})
	}

	t.Run("bundle path", func(t *testing.T) {
		server := receiptKeyServer(t, fixture.pub, http.StatusOK, nil)
		defer server.Close()
		path := filepath.Join(t.TempDir(), "bundle.json")
		if err := os.WriteFile(path, []byte(fixture.bundleJSON(testProviderID)), 0o600); err != nil {
			t.Fatal(err)
		}
		stdout, stderr, c := buffersAndCache(t)
		code := run([]string{"--bundle", path, "--coordinator", server.URL}, nil, stdout, stderr, getenvNone, runConfig{httpClient: server.Client(), cache: c, now: func() time.Time { return cliNow }})
		if code != exitValid {
			t.Fatalf("exit=%d want=%d stdout=%q stderr=%q", code, exitValid, stdout.String(), stderr.String())
		}
	})
}

func TestFlagInteractionMatrixRows(t *testing.T) {
	fixture := newCLIFixture(t, makeKey(4), cliNow.Unix())
	pubkey := base64.StdEncoding.EncodeToString(fixture.pub)
	tests := []struct {
		name            string
		args            func(serverURL string) []string
		body            string
		status          int
		wantCode        int
		wantCalls       int32
		wantStderrEmpty bool
		wantWarning     string
	}{
		{
			name: "no pubkey no offline live fetch",
			args: func(serverURL string) []string {
				return headerArgs(serverURL, fixture, "--provider-id", testProviderID)
			},
			status: http.StatusOK, wantCode: exitValid, wantCalls: 1,
		},
		{
			name: "--pubkey online background live divergence no downgrade",
			args: func(serverURL string) []string {
				return headerArgs(serverURL, fixture, "--provider-id", testProviderID, "--pubkey", pubkey)
			},
			status: http.StatusOK, wantCode: exitValid, wantCalls: 1,
		},
		{
			name: "--pubkey offline no live",
			args: func(serverURL string) []string {
				return headerArgs(serverURL, fixture, "--provider-id", testProviderID, "--pubkey", pubkey, "--offline")
			},
			status: http.StatusOK, wantCode: exitValid, wantCalls: 0, wantWarning: "offline_flag",
		},
		{
			name: "--offline no pubkey inconclusive cache miss",
			args: func(serverURL string) []string {
				return headerArgs(serverURL, fixture, "--provider-id", testProviderID, "--offline")
			},
			status: http.StatusOK, wantCode: exitInconclusive, wantCalls: 0, wantWarning: "offline_flag",
		},
		{
			name: "--quiet suppresses stderr",
			args: func(serverURL string) []string {
				return headerArgs(serverURL, fixture, "--provider-id", testProviderID, "--pubkey", pubkey, "--offline", "--quiet")
			},
			status: http.StatusOK, wantCode: exitValid, wantCalls: 0, wantStderrEmpty: true,
		},
		{
			name: "--quiet --json keeps warnings in JSON",
			args: func(serverURL string) []string {
				return headerArgs(serverURL, fixture, "--provider-id", testProviderID, "--pubkey", pubkey, "--offline", "--quiet", "--json")
			},
			status: http.StatusOK, wantCode: exitValid, wantCalls: 0, wantStderrEmpty: true, wantWarning: "offline_flag",
		},
		{
			name: "--explain after valid",
			args: func(serverURL string) []string {
				return headerArgs(serverURL, fixture, "--provider-id", testProviderID, "--pubkey", pubkey, "--offline", "--explain")
			},
			status: http.StatusOK, wantCode: exitValid, wantCalls: 0,
		},
		{
			name: "--quiet --explain suppresses stderr",
			args: func(serverURL string) []string {
				return headerArgs(serverURL, fixture, "--provider-id", testProviderID, "--pubkey", pubkey, "--offline", "--quiet", "--explain")
			},
			status: http.StatusOK, wantCode: exitValid, wantCalls: 0, wantStderrEmpty: true,
		},
		{
			name:   "--bundle stdin",
			args:   func(serverURL string) []string { return []string{"--bundle", "-", "--coordinator", serverURL} },
			body:   fixture.bundleJSON(testProviderID),
			status: http.StatusOK, wantCode: exitValid, wantCalls: 1,
		},
		{
			name: "provider id plus header hashes no pubkey",
			args: func(serverURL string) []string {
				return headerArgs(serverURL, fixture, "--provider-id", testProviderID)
			},
			status: http.StatusOK, wantCode: exitValid, wantCalls: 1,
		},
		{
			name: "provider id plus header hashes plus pubkey",
			args: func(serverURL string) []string {
				return headerArgs(serverURL, fixture, "--provider-id", testProviderID, "--pubkey", pubkey)
			},
			status: http.StatusOK, wantCode: exitValid, wantCalls: 1,
		},
		{
			name: "provider id plus bundle matching",
			args: func(serverURL string) []string {
				return []string{"--bundle", "-", "--provider-id", testProviderID, "--coordinator", serverURL}
			},
			body:   fixture.bundleJSON(testProviderID),
			status: http.StatusOK, wantCode: exitValid, wantCalls: 1,
		},
		{
			name: "provider id plus bundle missing bundle provider",
			args: func(serverURL string) []string {
				return []string{"--bundle", "-", "--provider-id", testProviderID, "--coordinator", serverURL}
			},
			body:   fixture.bundleJSON(""),
			status: http.StatusOK, wantCode: exitValid, wantCalls: 1,
		},
		{
			name:   "header hashes pubkey no provider id",
			args:   func(serverURL string) []string { return headerArgs(serverURL, fixture, "--pubkey", pubkey, "--json") },
			status: http.StatusOK, wantCode: exitValid, wantCalls: 0, wantWarning: "provider_id_unresolvable",
		},
	}
	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			var calls int32
			server := receiptKeyServer(t, fixture.pub, tt.status, &calls)
			defer server.Close()
			stdout, stderr, c := buffersAndCache(t)
			code := run(tt.args(server.URL), strings.NewReader(tt.body), stdout, stderr, getenvNone, runConfig{httpClient: server.Client(), cache: c, now: func() time.Time { return cliNow }})
			if code != tt.wantCode {
				t.Fatalf("exit=%d want=%d stdout=%q stderr=%q", code, tt.wantCode, stdout.String(), stderr.String())
			}
			if got := atomic.LoadInt32(&calls); got != tt.wantCalls {
				t.Fatalf("calls=%d want=%d", got, tt.wantCalls)
			}
			if tt.wantStderrEmpty && stderr.Len() != 0 {
				t.Fatalf("stderr=%q, want empty", stderr.String())
			}
			if tt.wantWarning != "" {
				combined := stdout.String() + stderr.String()
				if !strings.Contains(combined, tt.wantWarning) {
					t.Fatalf("missing warning %q in stdout=%q stderr=%q", tt.wantWarning, stdout.String(), stderr.String())
				}
			}
			if tt.name == "--explain after valid" && !strings.HasSuffix(stderr.String(), explainText+"\n") {
				t.Fatalf("--explain text mismatch; stderr=%q want suffix=%q", stderr.String(), explainText+"\n")
			}
		})
	}
}

func TestNonDefaultCoordinatorWarningJSON(t *testing.T) {
	fixture := newCLIFixture(t, makeKey(44), cliNow.Unix())
	var calls int32
	server := receiptKeyServer(t, fixture.pub, http.StatusOK, &calls)
	defer server.Close()

	stdout, stderr, c := buffersAndCache(t)
	code := run(headerArgs(server.URL, fixture, "--provider-id", testProviderID, "--json"), nil, stdout, stderr, getenvNone, runConfig{
		httpClient: server.Client(),
		cache:      c,
		now:        func() time.Time { return cliNow },
	})
	if code != exitValid {
		t.Fatalf("exit=%d want=%d stdout=%q stderr=%q", code, exitValid, stdout.String(), stderr.String())
	}
	if got := atomic.LoadInt32(&calls); got != 1 {
		t.Fatalf("calls=%d want=1", got)
	}
	var decoded struct {
		Warnings []struct {
			Kind            string `json:"kind"`
			CoordinatorHost string `json:"coordinator_host"`
		} `json:"warnings"`
	}
	if err := json.Unmarshal(bytes.TrimSpace(stdout.Bytes()), &decoded); err != nil {
		t.Fatalf("invalid JSON: %v in %q", err, stdout.String())
	}
	wantHost := normalizedCoordinatorHost(server.URL)
	for _, warning := range decoded.Warnings {
		if warning.Kind == "non_default_coordinator" && warning.CoordinatorHost == wantHost {
			return
		}
	}
	t.Fatalf("missing non_default_coordinator warning for %q in stdout=%q", wantHost, stdout.String())
}

func TestProviderIDHeaderMode404IsInconclusive(t *testing.T) {
	fixture := newCLIFixture(t, makeKey(41), cliNow.Unix())
	var calls int32
	server := receiptKeyServer(t, fixture.pub, http.StatusNotFound, &calls)
	defer server.Close()
	stdout, stderr, c := buffersAndCache(t)
	code := run(headerArgs(server.URL, fixture, "--provider-id", testProviderID), nil, stdout, stderr, getenvNone, runConfig{httpClient: server.Client(), cache: c, now: func() time.Time { return cliNow }})
	if code != exitInconclusive {
		t.Fatalf("exit=%d want=%d stdout=%q stderr=%q", code, exitInconclusive, stdout.String(), stderr.String())
	}
	if got := atomic.LoadInt32(&calls); got != 1 {
		t.Fatalf("calls=%d want=1", got)
	}
	if !strings.Contains(stdout.String(), "provider_id not in coordinator pool") {
		t.Fatalf("stdout=%q missing provider-id-not-in-pool summary", stdout.String())
	}
}

func TestExplicitVsLiveDivergenceWarningDoesNotDowngrade(t *testing.T) {
	fixture := newCLIFixture(t, makeKey(42), cliNow.Unix())
	liveDifferentPubkey := makeKey(43).Public().(ed25519.PublicKey)
	var calls int32
	server := receiptKeyServer(t, liveDifferentPubkey, http.StatusOK, &calls)
	defer server.Close()
	stdout, stderr, c := buffersAndCache(t)
	code := run(headerArgs(server.URL, fixture,
		"--provider-id", testProviderID,
		"--pubkey", base64.StdEncoding.EncodeToString(fixture.pub),
		"--json",
	), nil, stdout, stderr, getenvNone, runConfig{httpClient: server.Client(), cache: c, now: func() time.Time { return cliNow }})
	if code != exitValid {
		t.Fatalf("exit=%d want=%d stdout=%q stderr=%q", code, exitValid, stdout.String(), stderr.String())
	}
	if got := atomic.LoadInt32(&calls); got != 1 {
		t.Fatalf("calls=%d want=1", got)
	}
	if !strings.Contains(stdout.String(), "explicit_vs_live_divergence") {
		t.Fatalf("stdout=%q missing divergence warning", stdout.String())
	}
}

func TestUsageBoundaries(t *testing.T) {
	fixture := newCLIFixture(t, makeKey(5), cliNow.Unix())
	pubkey := base64.StdEncoding.EncodeToString(fixture.pub)
	tests := []struct {
		name        string
		args        []string
		body        string
		want        int
		wantMessage string
	}{
		{name: "bundle plus receipt", args: append(headerArgs("https://example.test", fixture, "--bundle", "-"), "--provider-id", testProviderID), body: fixture.bundleJSON(testProviderID), want: exitUsage},
		{name: "provider id bundle mismatch", args: []string{"--bundle", "-", "--provider-id", "other"}, body: fixture.bundleJSON(testProviderID), want: exitUsage, wantMessage: "--provider-id"},
		{name: "header hashes no provider id no pubkey", args: headerArgs("https://example.test", fixture), want: exitUsage, wantMessage: "--provider-id"},
		{name: "unknown flag", args: []string{"--unknown-flag"}, want: exitUsage},
		{name: "pubkey malformed base64", args: append(headerArgs("https://example.test", fixture, "--provider-id", testProviderID), "--pubkey", "not-base64!@#"), want: exitUsage},
		{name: "pubkey wrong length", args: append(headerArgs("https://example.test", fixture, "--provider-id", testProviderID), "--pubkey", base64.StdEncoding.EncodeToString(make([]byte, 31))), want: exitUsage},
		{name: "bundle no provider id no pubkey", args: []string{"--bundle", "-"}, body: fixture.bundleJSON(""), want: exitUsage, wantMessage: "--provider-id"},
		{name: "bundle stdin no provider id no pubkey", args: []string{"--bundle", "-"}, body: fixture.bundleJSON(""), want: exitUsage, wantMessage: "--provider-id"},
		{name: "matching cache recovers provider id", args: headerArgs("https://example.test", fixture, "--offline"), want: exitValid},
		{name: "ambiguous cache falls through to missing provider id", args: headerArgs("https://example.test", fixture), want: exitUsage, wantMessage: "--provider-id"},
		{name: "header hashes pubkey no provider id is valid with null provider", args: headerArgs("https://example.test", fixture, "--pubkey", pubkey, "--json"), want: exitValid, wantMessage: `"provider_id":null`},
	}
	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			stdout, stderr, c := buffersAndCache(t)
			if tt.name == "matching cache recovers provider id" {
				if err := c.Put(normalizedCoordinatorHost("https://example.test"), testProviderID, cache.ResolverResponse{ProviderID: testProviderID, ReceiptPubkey: fixture.pub}); err != nil {
					t.Fatal(err)
				}
			}
			if tt.name == "ambiguous cache falls through to missing provider id" {
				for _, providerID := range []string{"provider-a", "provider-b"} {
					if err := c.Put(normalizedCoordinatorHost("https://example.test"), providerID, cache.ResolverResponse{ProviderID: providerID, ReceiptPubkey: fixture.pub}); err != nil {
						t.Fatal(err)
					}
				}
			}
			code := run(tt.args, strings.NewReader(tt.body), stdout, stderr, getenvNone, runConfig{cache: c, now: func() time.Time { return cliNow }})
			if code != tt.want {
				t.Fatalf("exit=%d want=%d stdout=%q stderr=%q", code, tt.want, stdout.String(), stderr.String())
			}
			if tt.wantMessage != "" && !strings.Contains(stdout.String()+stderr.String(), tt.wantMessage) {
				t.Fatalf("missing %q in stdout=%q stderr=%q", tt.wantMessage, stdout.String(), stderr.String())
			}
		})
	}
}

func TestCLIReceiptParseBoundariesExit65(t *testing.T) {
	fixture := newCLIFixture(t, makeKey(51), cliNow.Unix())
	validLengthSignature := base64.StdEncoding.EncodeToString(make([]byte, ed25519.SignatureSize))
	tests := []struct {
		name string
		args []string
		body string
	}{
		{
			name: "receipt header no dot",
			args: []string{
				"--receipt", "no-dot-anywhere",
				"--prompt-hash", fixture.promptHash,
				"--output-hash", fixture.outputHash,
				"--provider-id", testProviderID,
			},
		},
		{
			name: "receipt tuple malformed base64",
			args: []string{
				"--receipt", "%%%%." + validLengthSignature,
				"--prompt-hash", fixture.promptHash,
				"--output-hash", fixture.outputHash,
				"--provider-id", testProviderID,
			},
		},
		{
			name: "bundle embedded receipt no dot",
			args: []string{"--bundle", "-", "--provider-id", testProviderID},
			body: `{"bundle_version":1,"receipt":"no-dot-anywhere","request":{},"response":{}}`,
		},
	}
	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			stdout, stderr, c := buffersAndCache(t)
			code := run(tt.args, strings.NewReader(tt.body), stdout, stderr, getenvNone, runConfig{cache: c, now: func() time.Time { return cliNow }})
			if code != exitDataErr {
				t.Fatalf("exit=%d want=%d stdout=%q stderr=%q", code, exitDataErr, stdout.String(), stderr.String())
			}
		})
	}
}

func TestCoordinatorEnvAndOverride(t *testing.T) {
	fixture := newCLIFixture(t, makeKey(6), cliNow.Unix())
	c := openTempCache(t)
	opts, err := parseOptions(headerArgs("", fixture, "--provider-id", testProviderID), ioDiscard(), ioDiscard(), func(key string) string {
		if key == "MACPROVIDER_COORDINATOR" {
			return "https://other.example"
		}
		return ""
	})
	if err != nil {
		t.Fatal(err)
	}
	_, verifyOpts, preflight, err := optionsToVerifyArgs(opts, nil, getenvNone, runConfig{cache: c})
	if err != nil {
		t.Fatal(err)
	}
	if preflight != nil {
		t.Fatalf("unexpected preflight result: %#v", preflight)
	}
	if got := normalizedCoordinatorHost(verifyOpts.CoordinatorHost); got != "other.example" {
		t.Fatalf("coordinator host=%q want other.example", got)
	}

	opts, err = parseOptions(headerArgs("https://override.example", fixture, "--provider-id", testProviderID), ioDiscard(), ioDiscard(), func(key string) string {
		if key == "MACPROVIDER_COORDINATOR" {
			return "https://other.example"
		}
		return ""
	})
	if err != nil {
		t.Fatal(err)
	}
	_, verifyOpts, preflight, err = optionsToVerifyArgs(opts, nil, getenvNone, runConfig{cache: c})
	if err != nil {
		t.Fatal(err)
	}
	if preflight != nil {
		t.Fatalf("unexpected preflight result: %#v", preflight)
	}
	if got := normalizedCoordinatorHost(verifyOpts.CoordinatorHost); got != "override.example" {
		t.Fatalf("coordinator host=%q want override.example", got)
	}
}

func TestBundlePubkeyProviderMismatchPreflight(t *testing.T) {
	fixture := newCLIFixture(t, makeKey(20), cliNow.Unix())
	mismatchedPubkey := []byte(makeKey(21).Public().(ed25519.PublicKey))

	t.Run("bundle mode returns reserved mismatch reason before verify", func(t *testing.T) {
		stdout, stderr, c := buffersAndCache(t)
		if err := c.Put(defaultCoordinator, testProviderID, cache.ResolverResponse{ProviderID: testProviderID, ReceiptPubkey: mismatchedPubkey}); err != nil {
			t.Fatal(err)
		}
		code := run([]string{"--bundle", "-", "--json"}, strings.NewReader(fixture.bundleJSON(testProviderID)), stdout, stderr, getenvNone, runConfig{
			cache: c,
			now:   func() time.Time { return cliNow },
		})
		if code != exitInvalid {
			t.Fatalf("exit=%d want=%d stdout=%q stderr=%q", code, exitInvalid, stdout.String(), stderr.String())
		}
		var decoded map[string]any
		if err := json.Unmarshal(bytes.TrimSpace(stdout.Bytes()), &decoded); err != nil {
			t.Fatalf("stdout not JSON: %v in %q", err, stdout.String())
		}
		if decoded["reason"] != "bundle_pubkey_provider_mismatch" {
			t.Fatalf("reason=%v want bundle_pubkey_provider_mismatch in %s", decoded["reason"], stdout.String())
		}
	})

	t.Run("header mode with same cache mismatch stays in orchestrator path", func(t *testing.T) {
		stdout, stderr, c := buffersAndCache(t)
		if err := c.Put(defaultCoordinator, testProviderID, cache.ResolverResponse{ProviderID: testProviderID, ReceiptPubkey: mismatchedPubkey}); err != nil {
			t.Fatal(err)
		}
		code := run(headerArgs(defaultCoordinator, fixture, "--provider-id", testProviderID, "--json"), nil, stdout, stderr, getenvNone, runConfig{
			cache: c,
			now:   func() time.Time { return cliNow },
		})
		if code != exitInvalid {
			t.Fatalf("exit=%d want=%d stdout=%q stderr=%q", code, exitInvalid, stdout.String(), stderr.String())
		}
		var decoded map[string]any
		if err := json.Unmarshal(bytes.TrimSpace(stdout.Bytes()), &decoded); err != nil {
			t.Fatalf("stdout not JSON: %v in %q", err, stdout.String())
		}
		if decoded["reason"] == "bundle_pubkey_provider_mismatch" {
			t.Fatalf("header mode triggered bundle-only reason: %s", stdout.String())
		}
		if decoded["reason"] != "pubkey_not_endorsed" {
			t.Fatalf("reason=%v want pubkey_not_endorsed in %s", decoded["reason"], stdout.String())
		}
	})
}

func TestHelpVersionAndJSONOutput(t *testing.T) {
	t.Run("help", func(t *testing.T) {
		stdout, stderr, _ := buffersAndCache(t)
		code := run([]string{"--help"}, nil, stdout, stderr, getenvNone, runConfig{})
		if code != exitValid || !strings.Contains(stdout.String(), "Usage:") {
			t.Fatalf("code=%d stdout=%q stderr=%q", code, stdout.String(), stderr.String())
		}
	})
	t.Run("version", func(t *testing.T) {
		stdout, stderr, _ := buffersAndCache(t)
		code := run([]string{"--version"}, nil, stdout, stderr, getenvNone, runConfig{})
		want := fmt.Sprintf("macprovider-verify %s\n", version.BinaryVersion)
		if code != exitValid || stdout.String() != want {
			t.Fatalf("code=%d stdout=%q want=%q stderr=%q", code, stdout.String(), want, stderr.String())
		}
	})
	t.Run("json valid single line no warnings", func(t *testing.T) {
		fixture := newCLIFixture(t, makeKey(7), cliNow.Unix())
		stdout, stderr, c := buffersAndCache(t)
		if err := c.Put(defaultCoordinator, testProviderID, cache.ResolverResponse{ProviderID: testProviderID, ReceiptPubkey: fixture.pub}); err != nil {
			t.Fatal(err)
		}
		code := run(headerArgs(defaultCoordinator, fixture, "--provider-id", testProviderID, "--json"), nil, stdout, stderr, getenvNone, runConfig{cache: c, now: func() time.Time { return cliNow }})
		if code != exitValid {
			t.Fatalf("exit=%d stdout=%q stderr=%q", code, stdout.String(), stderr.String())
		}
		if strings.Count(stdout.String(), "\n") != 1 || strings.Contains(stdout.String(), "warnings") {
			t.Fatalf("stdout=%q, want one JSON line without warnings", stdout.String())
		}
		var decoded map[string]any
		if err := json.Unmarshal(bytes.TrimSpace(stdout.Bytes()), &decoded); err != nil {
			t.Fatalf("invalid JSON: %v in %q", err, stdout.String())
		}
	})
}

type cliFixture struct {
	header     string
	request    map[string]any
	response   map[string]any
	pub        []byte
	promptHash string
	outputHash string
}

func newCLIFixture(t *testing.T, priv ed25519.PrivateKey, unixTS int64) *cliFixture {
	t.Helper()
	pub := priv.Public().(ed25519.PublicKey)
	request := map[string]any{"model": "fixture-model", "messages": []any{map[string]any{"role": "user", "content": "hello"}}}
	response := map[string]any{"choices": []any{map[string]any{"message": map[string]any{"content": "world"}, "finish_reason": "stop"}}}
	_, promptHash, err := canon.CanonicalPrompt(request)
	if err != nil {
		t.Fatal(err)
	}
	_, outputHash, err := canon.CanonicalOutput(response)
	if err != nil {
		t.Fatal(err)
	}
	tupleRaw := []byte(fmt.Sprintf(
		`{"model_id":"fixture-model","prompt_hash":"%x","output_hash":"%x","provider_pubkey":"%s","ttft_ms":123,"tokens_out":4,"unix_ts":%d}`,
		promptHash,
		outputHash,
		base64.StdEncoding.EncodeToString(pub),
		unixTS,
	))
	signature := ed25519.Sign(priv, tupleRaw)
	return &cliFixture{
		header:     base64.StdEncoding.EncodeToString(tupleRaw) + "." + base64.StdEncoding.EncodeToString(signature),
		request:    request,
		response:   response,
		pub:        pub,
		promptHash: fmt.Sprintf("%x", promptHash),
		outputHash: fmt.Sprintf("%x", outputHash),
	}
}

func (f *cliFixture) bundleJSON(providerID string) string {
	body := map[string]any{
		"bundle_version": 1,
		"receipt":        f.header,
		"request":        f.request,
		"response":       f.response,
	}
	if providerID != "" {
		body["provider_id"] = providerID
	}
	data, _ := json.Marshal(body)
	return string(data)
}

func headerArgs(coordinator string, f *cliFixture, extra ...string) []string {
	args := []string{"--receipt", f.header, "--prompt-hash", f.promptHash, "--output-hash", f.outputHash}
	if coordinator != "" {
		args = append(args, "--coordinator", coordinator)
	}
	for i := 0; i < len(extra); i++ {
		if extra[i] == "--output-hash" {
			args[5] = extra[i+1]
			i++
			continue
		}
		args = append(args, extra[i])
	}
	return args
}

func receiptKeyServer(t *testing.T, pubkey []byte, status int, calls *int32) *httptest.Server {
	t.Helper()
	if status == 0 {
		status = http.StatusOK
	}
	return httptest.NewTLSServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if calls != nil {
			atomic.AddInt32(calls, 1)
		}
		if r.URL.Path != "/v1/receipt-keys/"+testProviderID {
			t.Fatalf("path=%s", r.URL.Path)
		}
		if status != http.StatusOK {
			w.WriteHeader(status)
			return
		}
		_ = json.NewEncoder(w).Encode(map[string]any{
			"provider_id":         testProviderID,
			"receipt_pubkey":      base64.StdEncoding.EncodeToString(pubkey),
			"receipt_pubkey_prev": nil,
			"fetched_at":          cliNow.Format(time.RFC3339),
		})
	}))
}

func makeKey(seedByte byte) ed25519.PrivateKey {
	seed := make([]byte, ed25519.SeedSize)
	for i := range seed {
		seed[i] = seedByte + byte(i)
	}
	return ed25519.NewKeyFromSeed(seed)
}

func buffersAndCache(t *testing.T) (*bytes.Buffer, *bytes.Buffer, *cache.Cache) {
	t.Helper()
	c := openTempCache(t)
	return &bytes.Buffer{}, &bytes.Buffer{}, c
}

func openTempCache(t *testing.T) *cache.Cache {
	t.Helper()
	c, err := cache.Open(filepath.Join(t.TempDir(), "verify-cache.jsonl"))
	if err != nil {
		t.Fatal(err)
	}
	return c
}

func getenvNone(string) string { return "" }

func ioDiscard() *bytes.Buffer { return &bytes.Buffer{} }
