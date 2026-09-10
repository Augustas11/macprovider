package integration

import (
	"bytes"
	"context"
	"database/sql"
	"encoding/base64"
	"encoding/json"
	"fmt"
	"io"
	"net/http"
	"net/http/httptest"
	"net/http/httputil"
	"net/url"
	"os"
	"os/exec"
	"path/filepath"
	"runtime"
	"strings"
	"sync"
	"testing"
	"time"

	_ "modernc.org/sqlite"
)

const relayBlindReservationBody = `{
  "endpoint_family":"chat_completions",
  "model":"llama-3.2-3b-instruct",
  "stream":false,
  "max_output_tokens":32,
  "input_token_upper_bound":64,
  "encrypted_request_bytes":1024
}`

// These cases use the in-process Go provider deliberately: it has no
// relay-blind key advertisement or opaque inference implementation. They prove
// the real gateway/coordinator boundary fails closed before quota or dispatch;
// successful decryption is covered separately by the Swift fixture journey.
func TestRelayBlindReservationFailClosedAcrossRealServices(t *testing.T) {
	tests := []struct {
		name               string
		gatewayEnabled     bool
		coordinatorEnabled bool
		wantCode           string
	}{
		{name: "default off", wantCode: "relay_blind_disabled"},
		{name: "gateway only mixed version", gatewayEnabled: true, wantCode: "relay_blind_disabled"},
		{name: "provider lacks signed key", gatewayEnabled: true, coordinatorEnabled: true, wantCode: "relay_blind_provider_unsupported"},
	}
	for _, tc := range tests {
		t.Run(tc.name, func(t *testing.T) {
			s := newScenario(t, scenarioOpts{
				seedAccount:                  true,
				gatewayRelayBlindEnabled:     tc.gatewayEnabled,
				coordinatorRelayBlindEnabled: tc.coordinatorEnabled,
			})

			status, headers, body := s.jsonRequest(http.MethodPost, "/v1/relay-blind/route-reservations", nil, relayBlindReservationBody)
			if status != http.StatusServiceUnavailable {
				t.Fatalf("status=%d body=%s, want 503", status, body)
			}
			if got := relayBlindErrorCode(t, body); got != tc.wantCode {
				t.Fatalf("error.code=%q body=%s, want %q", got, body, tc.wantCode)
			}
			if got := headers.Get("Cache-Control"); !strings.Contains(got, "no-store") {
				t.Fatalf("Cache-Control=%q, want no-store", got)
			}
			for _, name := range []string{"X-Provider-Id", "X-MacProvider-Provider"} {
				if got := headers.Get(name); got != "" {
					t.Fatalf("%s exposed stable provider identifier %q", name, got)
				}
			}
			if got := s.countGatewayRows("quota_reservations"); got != 0 {
				t.Fatalf("quota_reservations=%d, want 0 before opaque dispatch", got)
			}
			if got := s.countCoordinatorRows("request_log"); got != 0 {
				t.Fatalf("request_log=%d, want 0 before opaque dispatch", got)
			}
			if got := s.fakeProv.Hits(); got != 0 {
				t.Fatalf("plaintext provider dispatches=%d, want 0", got)
			}
		})
	}
}

func TestRelayBlindDisabledEnvelopeDoesNotLeakOpaqueMaterial(t *testing.T) {
	s := newScenario(t, scenarioOpts{
		seedAccount:        true,
		captureCoordLogs:   true,
		captureGatewayLogs: true,
	})
	plaintextMarker := "integration-plaintext-must-stay-opaque"
	ciphertextMarker := base64.RawURLEncoding.EncodeToString([]byte(plaintextMarker))
	requestID := "relay-blind-disabled-log-scan"
	raw, ephemeralKey := relayBlindOpaqueEnvelope(t, requestID, ciphertextMarker)
	status, _, body := s.jsonRequest(http.MethodPost, "/v1/chat/completions", map[string]string{"X-Request-ID": requestID}, string(raw))
	if status != http.StatusServiceUnavailable && status != http.StatusBadRequest {
		t.Fatalf("status=%d body=%s, want fail-closed rejection", status, body)
	}
	combined := string(body)
	for _, buffer := range []*logBuffer{s.coordLogBuf, s.gatewayLogBuf} {
		combined += "\n" + strings.Join(buffer.snapshot(), "\n")
	}
	for _, forbidden := range []string{plaintextMarker, ciphertextMarker, ephemeralKey} {
		if strings.Contains(combined, forbidden) {
			t.Fatalf("relay output/logs exposed forbidden request material %q", forbidden)
		}
	}
	if got := s.countGatewayRows("quota_reservations"); got != 0 {
		t.Fatalf("quota_reservations=%d, want 0", got)
	}
	if got := s.fakeProv.Hits(); got != 0 {
		t.Fatalf("provider dispatches=%d, want 0", got)
	}
}

func TestRelayBlindReplaySurvivesGatewayRestartAndEnableCycle(t *testing.T) {
	s := newScenario(t, scenarioOpts{
		seedAccount:                  true,
		coordinatorRelayBlindEnabled: true,
	})
	requestID := "relay-blind-restart-replay"
	raw, _ := relayBlindOpaqueEnvelope(t, requestID, base64.RawURLEncoding.EncodeToString([]byte("replay-fixture")))
	status, _, body := s.jsonRequest(http.MethodPost, "/v1/chat/completions", map[string]string{"X-Request-ID": requestID}, string(raw))
	if status != http.StatusServiceUnavailable || relayBlindErrorCode(t, body) != "relay_blind_disabled" {
		t.Fatalf("initial status=%d body=%s, want relay_blind_disabled", status, body)
	}
	s.stopGateway()
	s.rewriteGatewayRelayBlindEnabled(true)
	s.startGateway(s.rootCtx)
	s.waitForHealth(s.gatewayBaseURL + "/healthz")

	status, _, body = s.jsonRequest(http.MethodPost, "/v1/chat/completions", map[string]string{"X-Request-ID": requestID}, string(raw))
	if status != http.StatusConflict || relayBlindErrorCode(t, body) != "relay_blind_replay" {
		t.Fatalf("replay status=%d body=%s, want relay_blind_replay", status, body)
	}
	if got := s.countGatewayRows("quota_reservations"); got != 0 {
		t.Fatalf("quota_reservations=%d, want 0", got)
	}
	if got := s.fakeProv.Hits(); got != 0 {
		t.Fatalf("provider dispatches=%d, want 0", got)
	}
}

func TestRelayBlindConcurrentEnvelopeAdmitsAtMostOnce(t *testing.T) {
	s := newScenario(t, scenarioOpts{seedAccount: true})
	requestID := "relay-blind-concurrent-replay"
	raw, _ := relayBlindOpaqueEnvelope(t, requestID, base64.RawURLEncoding.EncodeToString([]byte("concurrent-fixture")))
	const attempts = 8
	type result struct {
		status int
		code   string
		err    error
	}
	results := make(chan result, attempts)
	var wg sync.WaitGroup
	for range attempts {
		wg.Add(1)
		go func() {
			defer wg.Done()
			req, err := http.NewRequest(http.MethodPost, s.gatewayBaseURL+"/v1/chat/completions", strings.NewReader(string(raw)))
			if err != nil {
				results <- result{err: err}
				return
			}
			req.Header.Set("Authorization", "Bearer "+s.apiKey)
			req.Header.Set("Content-Type", "application/json")
			req.Header.Set("X-Request-ID", requestID)
			resp, err := http.DefaultClient.Do(req)
			if err != nil {
				results <- result{err: err}
				return
			}
			body, readErr := io.ReadAll(resp.Body)
			resp.Body.Close()
			if readErr != nil {
				results <- result{err: readErr}
				return
			}
			var payload struct {
				Error struct {
					Code string `json:"code"`
				} `json:"error"`
			}
			if err := json.Unmarshal(body, &payload); err != nil {
				results <- result{err: fmt.Errorf("decode response: %w", err)}
				return
			}
			results <- result{status: resp.StatusCode, code: payload.Error.Code}
		}()
	}
	wg.Wait()
	close(results)
	first, replays := 0, 0
	for got := range results {
		if got.err != nil {
			t.Fatal(got.err)
		}
		switch {
		case got.status == http.StatusServiceUnavailable && got.code == "relay_blind_disabled":
			first++
		case got.status == http.StatusConflict && got.code == "relay_blind_replay":
			replays++
		default:
			t.Fatalf("unexpected concurrent result status=%d code=%q", got.status, got.code)
		}
	}
	if first != 1 || replays != attempts-1 {
		t.Fatalf("first=%d replays=%d, want 1/%d", first, replays, attempts-1)
	}
	if got := s.countGatewayRows("quota_reservations"); got != 0 {
		t.Fatalf("quota_reservations=%d, want 0", got)
	}
	if got := s.fakeProv.Hits(); got != 0 {
		t.Fatalf("provider dispatches=%d, want 0", got)
	}
}

func TestRelayBlindSwiftProviderNonstreamEndToEnd(t *testing.T) {
	runRelayBlindSwiftProviderEndToEnd(t, false, false)
}

func TestRelayBlindSwiftProviderStreamEndToEnd(t *testing.T) {
	runRelayBlindSwiftProviderEndToEnd(t, true, false)
}

func TestRelayBlindSwiftProviderReconnectRecovery(t *testing.T) {
	runRelayBlindSwiftProviderEndToEnd(t, false, true)
}

func TestRelayBlindSwiftProviderDisconnectBoundaries(t *testing.T) {
	for _, fault := range []string{"disconnect_before_dispatch", "disconnect_after_first_chunk", "buyer_cancel_after_first_chunk", "process_crash_after_first_chunk", "underdeclared_input_bound", "tampered_aead"} {
		t.Run(fault, func(t *testing.T) { runRelayBlindSwiftProviderInterrupted(t, fault) })
	}
}

func runRelayBlindSwiftProviderInterrupted(t *testing.T, fault string) {
	t.Helper()
	if runtime.GOOS != "darwin" {
		t.Skip("real Swift InferenceRelay fixture requires macOS")
	}
	stateDir, err := filepath.EvalSymlinks(t.TempDir())
	if err != nil {
		t.Fatal(err)
	}
	if err := os.Chmod(stateDir, 0o700); err != nil {
		t.Fatal(err)
	}
	fixtureDelayMS := 0
	if fault == "process_crash_after_first_chunk" {
		fixtureDelayMS = 2_000
	}
	fixture := startSwiftRelayFixtureWithDelay(t, stateDir, defaultFakeModelID, fixtureDelayMS)
	if fault == "process_crash_after_first_chunk" {
		fixture.crashReplayResult = make(chan error, 1)
	}
	providerID := "prov-swift-fault-" + randHex(t, 4)
	s := newScenario(t, scenarioOpts{
		seedAccount: true, providerID: providerID, externalWebSocketProvider: true,
		gatewayRelayBlindEnabled: true, coordinatorRelayBlindEnabled: true,
		relayBlindIdentityPublicKeys:       map[string]string{providerID: fixture.descriptor.IdentityPublicKey},
		settlementReconcileIntervalSeconds: 1,
	})
	var observed chan struct{}
	if fault == "buyer_cancel_after_first_chunk" {
		observed = make(chan struct{})
	}
	connectSwiftRelayProviderWithFaultSignal(t, s.rootCtx, s, fixture, fault, observed)
	s.waitForProviderReady(providerID)
	pinPath := filepath.Join(stateDir, "buyer-pin.json")
	pinRaw, err := json.Marshal(map[string]any{
		"version": "relay-blind-pilot-pin-v1", "identity_public_key": fixture.descriptor.IdentityPublicKey,
		"fingerprint": fixture.descriptor.KeyRecord["identity_fingerprint"], "models": []string{defaultFakeModelID},
		"endpoint_families": []string{"chat_completions"}, "not_before_unix": fixture.descriptor.KeyRecord["not_before_unix"],
		"expires_at_unix": fixture.descriptor.KeyRecord["expires_at_unix"], "revoked": false,
	})
	if err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(pinPath, pinRaw, 0o600); err != nil {
		t.Fatal(err)
	}
	inner := fmt.Sprintf(`{"model":%q,"messages":[{"role":"user","content":"interrupted-private-prompt"}],"stream":true,"max_tokens":32}`, defaultFakeModelID)
	clientCtx, cancelClient := context.WithTimeout(context.Background(), 20*time.Second)
	defer cancelClient()
	inputBound := "64"
	if fault == "underdeclared_input_bound" {
		inputBound = "1"
	}
	clientBaseURL := s.gatewayBaseURL
	observedErrorCode := func() string { return "" }
	if fault == "underdeclared_input_bound" || fault == "tampered_aead" {
		clientBaseURL, observedErrorCode = relayBlindFailureProxy(t, s.gatewayBaseURL, fault == "tampered_aead")
	}
	cmd := exec.CommandContext(clientCtx, relayBlindClientBin, "--base-url", clientBaseURL, "--identity-pin", pinPath,
		"--model", defaultFakeModelID, "--max-output-tokens", "32", "--input-token-upper-bound", inputBound, "--stream", "--input", "-")
	cmd.Env = append(os.Environ(), "MACPROVIDER_API_KEY="+s.apiKey)
	cmd.Stdin = strings.NewReader(inner)
	var output bytes.Buffer
	cmd.Stdout, cmd.Stderr = &output, &output
	var runErr error
	if observed == nil {
		runErr = cmd.Run()
	} else {
		if err := cmd.Start(); err != nil {
			t.Fatal(err)
		}
		select {
		case <-observed:
			cancelClient()
		case <-time.After(10 * time.Second):
			cancelClient()
			t.Fatal("timed out waiting for first encrypted stream chunk before buyer cancellation")
		}
		runErr = cmd.Wait()
	}
	if runErr == nil {
		t.Fatalf("interrupted relay client unexpectedly succeeded: %s", output.String())
	}
	if fixture.crashReplayResult != nil {
		select {
		case err := <-fixture.crashReplayResult:
			if err != nil {
				t.Fatal(err)
			}
		case <-time.After(10 * time.Second):
			t.Fatal("timed out waiting for restarted Swift fixture to reject the old envelope")
		}
	}
	if (fault == "underdeclared_input_bound" || fault == "tampered_aead") && observedErrorCode() != "relay_blind_ciphertext_invalid" {
		t.Fatalf("%s error.code=%q output=%s, want relay_blind_ciphertext_invalid", fault, observedErrorCode(), output.String())
	}
	if strings.Contains(output.String(), "interrupted-private-prompt") {
		t.Fatal("interrupted relay diagnostics exposed plaintext")
	}
	if got := s.countGatewayRows("quota_reservations"); got != 1 {
		t.Fatalf("quota_reservations=%d, want exactly one for interrupted envelope", got)
	}
	wantSettledTokens := int64(0)
	if fault == "disconnect_after_first_chunk" || fault == "process_crash_after_first_chunk" {
		// The provider terminal frame is lost, so the gateway cannot use the
		// encrypted stream's terminal usage and conservatively charges the known
		// validated input plus the clear output cap exactly once.
		wantSettledTokens = 5 + 32
	} else if fault == "buyer_cancel_after_first_chunk" {
		// The trusted validation preframe established the input count before the
		// buyer canceled; no terminal completion count was delivered.
		wantSettledTokens = 5
	}
	wantQuotaStatus := "settled"
	if fault == "underdeclared_input_bound" || fault == "tampered_aead" {
		wantQuotaStatus = "refunded"
	}
	status, settledTokens, hold := waitLatestQuotaTerminal(t, s.gatewayDB, 8*time.Second)
	if status != wantQuotaStatus || settledTokens != wantSettledTokens || hold != 0 {
		t.Fatalf("interrupted quota status/tokens/hold=%s/%d/%d, want %s/%d/0", status, settledTokens, hold, wantQuotaStatus, wantSettledTokens)
	}
	wantSettledRows := 1
	if fault == "underdeclared_input_bound" || fault == "tampered_aead" {
		wantSettledRows = 0
	}
	if got := countGatewayQuotaStatus(t, s.gatewayDB, "settled"); got != wantSettledRows {
		t.Fatalf("settled quota reservations=%d, want %d", got, wantSettledRows)
	}
	if got := s.countCoordinatorRows("request_log"); got != 1 {
		t.Fatalf("request_log=%d, want exactly one dispatch record", got)
	}
	journalFiles, err := filepath.Glob(filepath.Join(stateDir, "execution-journal", "*.json"))
	if err != nil {
		t.Fatal(err)
	}
	wantJournal := 0
	if fault == "disconnect_after_first_chunk" || fault == "buyer_cancel_after_first_chunk" || fault == "process_crash_after_first_chunk" || fault == "underdeclared_input_bound" || fault == "tampered_aead" {
		wantJournal = 1
	}
	if len(journalFiles) != wantJournal {
		t.Fatalf("Swift execution journal files=%d, want %d at %s", len(journalFiles), wantJournal, fault)
	}
	for _, path := range journalFiles {
		raw, err := os.ReadFile(path)
		if err != nil {
			t.Fatal(err)
		}
		var entry struct {
			State                string `json:"state"`
			EnvelopeDigest       string `json:"envelope_digest"`
			CreatedAtUnix        int64  `json:"created_at_unix"`
			UpdatedAtUnix        int64  `json:"updated_at_unix"`
			InputTokenUpperBound int64  `json:"input_token_upper_bound"`
			MaxOutputTokens      int64  `json:"max_output_tokens"`
			InputTokens          int64  `json:"input_tokens"`
		}
		wantState := "terminal"
		if fault == "process_crash_after_first_chunk" {
			wantState = "unknown_postdispatch"
		}
		if err := json.Unmarshal(raw, &entry); err != nil || entry.State != wantState {
			t.Fatalf("interrupted Swift journal state=%q err=%v, want %s", entry.State, err, wantState)
		}
		if fault == "process_crash_after_first_chunk" && (entry.EnvelopeDigest == "" || entry.CreatedAtUnix == 0 || entry.UpdatedAtUnix < entry.CreatedAtUnix || entry.InputTokenUpperBound != 64 || entry.MaxOutputTokens != 32 || entry.InputTokens != 5) {
			t.Fatalf("recovered crash journal lost original claim/validation fields: %+v", entry)
		}
	}
}

func relayBlindFailureProxy(t *testing.T, upstream string, tamper bool) (string, func() string) {
	t.Helper()
	target, err := url.Parse(upstream)
	if err != nil {
		t.Fatal(err)
	}
	proxy := httputil.NewSingleHostReverseProxy(target)
	originalDirector := proxy.Director
	proxy.Director = func(req *http.Request) {
		originalDirector(req)
		if !tamper || req.URL.Path != "/v1/chat/completions" {
			return
		}
		raw, err := io.ReadAll(req.Body)
		if err != nil {
			return
		}
		var envelope map[string]any
		if json.Unmarshal(raw, &envelope) == nil {
			if ciphertext, ok := envelope["ciphertext"].(string); ok && ciphertext != "" {
				replacement := "A"
				if ciphertext[:1] == replacement {
					replacement = "B"
				}
				envelope["ciphertext"] = replacement + ciphertext[1:]
				raw, _ = json.Marshal(envelope)
			}
		}
		req.Body = io.NopCloser(bytes.NewReader(raw))
		req.ContentLength = int64(len(raw))
	}
	var mu sync.Mutex
	errorCode := ""
	proxy.ModifyResponse = func(resp *http.Response) error {
		if resp.Request.URL.Path != "/v1/chat/completions" {
			return nil
		}
		raw, err := io.ReadAll(resp.Body)
		if err != nil {
			return err
		}
		resp.Body = io.NopCloser(bytes.NewReader(raw))
		var payload struct {
			Error struct {
				Code string `json:"code"`
			} `json:"error"`
		}
		if json.Unmarshal(raw, &payload) == nil {
			mu.Lock()
			errorCode = payload.Error.Code
			mu.Unlock()
		}
		return nil
	}
	server := httptest.NewServer(proxy)
	t.Cleanup(server.Close)
	return server.URL, func() string {
		mu.Lock()
		defer mu.Unlock()
		return errorCode
	}
}

func runRelayBlindSwiftProviderEndToEnd(t *testing.T, stream, reconnect bool) {
	t.Helper()
	if runtime.GOOS != "darwin" {
		t.Skip("real Swift InferenceRelay fixture requires macOS")
	}
	if _, err := exec.LookPath("swift"); err != nil {
		t.Skip("Swift toolchain unavailable")
	}
	stateDir := t.TempDir()
	if err := os.Chmod(stateDir, 0o700); err != nil {
		t.Fatal(err)
	}
	resolvedStateDir, err := filepath.EvalSymlinks(stateDir)
	if err != nil {
		t.Fatal(err)
	}
	stateDir = resolvedStateDir
	fixture := startSwiftRelayFixture(t, stateDir, defaultFakeModelID)
	providerID := "prov-swift-relay-" + randHex(t, 4)
	s := newScenario(t, scenarioOpts{
		seedAccount:                  true,
		providerID:                   providerID,
		externalWebSocketProvider:    true,
		gatewayRelayBlindEnabled:     true,
		coordinatorRelayBlindEnabled: true,
		relayBlindIdentityPublicKeys: map[string]string{providerID: fixture.descriptor.IdentityPublicKey},
		captureCoordLogs:             true,
		captureGatewayLogs:           true,
	})
	disconnect := connectSwiftRelayProvider(t, s.rootCtx, s, fixture)
	s.waitForProviderReady(providerID)

	pinPath := filepath.Join(stateDir, "buyer-pin.json")
	pin := map[string]any{
		"version":             "relay-blind-pilot-pin-v1",
		"identity_public_key": fixture.descriptor.IdentityPublicKey,
		"fingerprint":         fixture.descriptor.KeyRecord["identity_fingerprint"],
		"models":              []string{defaultFakeModelID},
		"endpoint_families":   []string{"chat_completions"},
		"not_before_unix":     fixture.descriptor.KeyRecord["not_before_unix"],
		"expires_at_unix":     fixture.descriptor.KeyRecord["expires_at_unix"],
		"revoked":             false,
	}
	pinRaw, err := json.Marshal(pin)
	if err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(pinPath, pinRaw, 0o600); err != nil {
		t.Fatal(err)
	}
	plaintextMarker := "swift-inference-relay-private-prompt"
	inner := fmt.Sprintf(`{"model":%q,"messages":[{"role":"user","content":%q}],"stream":%t,"max_tokens":32}`, defaultFakeModelID, plaintextMarker, stream)
	args := []string{
		"--base-url", s.gatewayBaseURL,
		"--identity-pin", pinPath,
		"--model", defaultFakeModelID,
		"--max-output-tokens", "32",
		"--input-token-upper-bound", "64",
		"--input", "-",
	}
	if stream {
		args = append(args, "--stream")
	}
	attempts := 1
	if reconnect {
		attempts = 2
	}
	for attempt := range attempts {
		cmd := exec.Command(relayBlindClientBin, args...)
		cmd.Env = append(os.Environ(), "MACPROVIDER_API_KEY="+s.apiKey)
		cmd.Stdin = strings.NewReader(inner)
		var stdout, stderr strings.Builder
		cmd.Stdout = &stdout
		cmd.Stderr = &stderr
		if err := cmd.Run(); err != nil {
			t.Fatalf("relay-blind client attempt %d: %v\nstdout=%s\nstderr=%s", attempt+1, err, stdout.String(), stderr.String())
		}
		if !stream && !strings.Contains(stdout.String(), "relay-blind fixture response") {
			t.Fatalf("response missing Swift fixture output: %s", stdout.String())
		}
		if stream && (!strings.Contains(stdout.String(), "data:") || !strings.Contains(stdout.String(), "relay-blind ") || !strings.Contains(stdout.String(), "fixture response") || !strings.Contains(stdout.String(), "[DONE]")) {
			t.Fatalf("stream response missing SSE framing or terminal marker: %s", stdout.String())
		}
		if !strings.Contains(stderr.String(), "relay-blind satisfied") {
			t.Fatalf("client did not confirm verified relay-blind outcome: %s", stderr.String())
		}
		if strings.Contains(stderr.String(), plaintextMarker) {
			t.Fatalf("client diagnostics exposed plaintext marker")
		}
		if reconnect && attempt == 0 {
			disconnect()
			disconnect = connectSwiftRelayProvider(t, s.rootCtx, s, fixture)
			s.waitForProviderReady(providerID)
		}
	}
	usage, ok := s.readLatestUsageEvent()
	if !ok {
		t.Fatal("missing gateway usage event")
	}
	wantOutcome := "ok"
	if stream {
		wantOutcome = "unverified_streaming"
	}
	if usage.PromptTokens != 5 || usage.CompletionTokens != 4 || usage.TotalTokens != 9 || usage.Outcome != wantOutcome {
		t.Fatalf("gateway usage event=%+v, want provider-reported 5+4 success", usage)
	}
	quota, ok := s.readQuotaReservation(usage.RequestID)
	if !ok || quota.Status != "settled" || quota.SettledTokens != 9 {
		t.Fatalf("gateway quota=%+v found=%v, want settled 9", quota, ok)
	}
	requestLog, ok := s.readLatestRequestLog()
	wantStream := 0
	if stream {
		wantStream = 1
	}
	if !ok || requestLog.Status != http.StatusOK || !requestLog.TotalTokens.Valid || requestLog.TotalTokens.Int64 != 9 || requestLog.Stream != wantStream {
		t.Fatalf("coordinator request_log=%+v found=%v, want HTTP 200 total 9", requestLog, ok)
	}
	if verdicts := s.readSettlementReceiptVerdicts(); len(verdicts) != 0 {
		t.Fatalf("relay-blind request created positive receipt verdicts: %+v", verdicts)
	}
	combinedLogs := strings.Join(s.coordLogBuf.snapshot(), "\n") + "\n" + strings.Join(s.gatewayLogBuf.snapshot(), "\n")
	if strings.Contains(combinedLogs, plaintextMarker) {
		t.Fatal("gateway/coordinator logs exposed decrypted prompt marker")
	}
	if got := s.countGatewayRows("quota_reservations"); got != attempts {
		t.Fatalf("quota_reservations=%d, want exactly one per successful envelope (%d)", got, attempts)
	}
	if got := countGatewayQuotaStatus(t, s.gatewayDB, "settled"); got != attempts {
		t.Fatalf("settled quota reservations=%d, want %d", got, attempts)
	}
	if got := s.countCoordinatorRows("request_log"); got != attempts {
		t.Fatalf("request_log=%d, want exactly one per successful envelope (%d)", got, attempts)
	}
	journalFiles, err := filepath.Glob(filepath.Join(stateDir, "execution-journal", "*.json"))
	if err != nil || len(journalFiles) != attempts {
		t.Fatalf("Swift execution journal files=%d err=%v, want %d", len(journalFiles), err, attempts)
	}
	for _, path := range journalFiles {
		raw, err := os.ReadFile(path)
		if err != nil {
			t.Fatal(err)
		}
		var entry struct {
			State       string `json:"state"`
			InputTokens int    `json:"input_tokens"`
		}
		if err := json.Unmarshal(raw, &entry); err != nil || entry.State != "terminal" || entry.InputTokens != 5 {
			t.Fatalf("Swift execution journal entry state=%q input_tokens=%d err=%v, want terminal/5", entry.State, entry.InputTokens, err)
		}
	}
}

func countGatewayQuotaStatus(t *testing.T, databasePath, status string) int {
	t.Helper()
	db, err := sql.Open("sqlite", databasePath)
	if err != nil {
		t.Fatal(err)
	}
	defer db.Close()
	var count int
	if err := db.QueryRow(`SELECT COUNT(*) FROM quota_reservations WHERE status = ?`, status).Scan(&count); err != nil {
		t.Fatal(err)
	}
	return count
}

func waitLatestQuotaTerminal(t *testing.T, databasePath string, timeout time.Duration) (string, int64, int) {
	t.Helper()
	deadline := time.Now().Add(timeout)
	for {
		db, err := sql.Open("sqlite", databasePath)
		if err != nil {
			t.Fatal(err)
		}
		var status string
		var settled int64
		var hold int
		err = db.QueryRow(`SELECT status, settled_tokens, settlement_hold FROM quota_reservations ORDER BY created_at DESC LIMIT 1`).Scan(&status, &settled, &hold)
		db.Close()
		if err == nil && status != "active" && hold == 0 {
			return status, settled, hold
		}
		if time.Now().After(deadline) {
			if err != nil {
				t.Fatalf("read terminal relay-blind quota: %v", err)
			}
			return status, settled, hold
		}
		time.Sleep(100 * time.Millisecond)
	}
}

func relayBlindOpaqueEnvelope(t *testing.T, requestID, ciphertext string) ([]byte, string) {
	t.Helper()
	b64 := func(fill byte, n int) string {
		return base64.RawURLEncoding.EncodeToString([]byte(strings.Repeat(string(fill), n)))
	}
	ephemeralKey := b64('e', 32)
	envelope := map[string]any{
		"version":                    "relay-blind-request-v1",
		"mode":                       "required",
		"endpoint_family":            "chat_completions",
		"model":                      "llama-3.2-3b-instruct",
		"provider_model":             "llama-3.2-3b-instruct",
		"stream":                     false,
		"request_id":                 requestID,
		"max_output_tokens":          32,
		"input_token_upper_bound":    64,
		"reservation_token_cap":      96,
		"provider_binding":           b64('p', 32),
		"buyer_binding":              b64('b', 32),
		"key_record_digest":          b64('d', 32),
		"kid":                        b64('k', 16),
		"buyer_ephemeral_public_key": ephemeralKey,
		"request_replay_nonce":       b64('n', 32),
		"issued_at_unix":             time.Now().Unix(),
		"algorithm":                  "x25519-hkdf-sha256-a256gcm-v1",
		"ciphertext":                 ciphertext,
		"tag":                        b64('t', 16),
	}
	raw, err := json.Marshal(envelope)
	if err != nil {
		t.Fatal(err)
	}
	return raw, ephemeralKey
}

func TestRelayBlindReservationRejectsPoolSelectionBeforeQuota(t *testing.T) {
	s := newScenario(t, scenarioOpts{
		seedAccount:                  true,
		gatewayRelayBlindEnabled:     true,
		coordinatorRelayBlindEnabled: true,
	})
	status, _, body := s.jsonRequest(http.MethodPost, "/v1/relay-blind/route-reservations", map[string]string{
		"X-MacProvider-Pool-Select": "pool-not-authorized-for-relay-blind",
	}, relayBlindReservationBody)
	if status != http.StatusBadRequest {
		t.Fatalf("status=%d body=%s, want 400", status, body)
	}
	if got := relayBlindErrorCode(t, body); got != "relay_blind_downgrade_rejected" {
		t.Fatalf("error.code=%q body=%s, want relay_blind_downgrade_rejected", got, body)
	}
	if got := s.countGatewayRows("quota_reservations"); got != 0 {
		t.Fatalf("quota_reservations=%d, want 0", got)
	}
	if got := s.fakeProv.Hits(); got != 0 {
		t.Fatalf("provider dispatches=%d, want 0", got)
	}
}

func relayBlindErrorCode(t *testing.T, body []byte) string {
	t.Helper()
	var payload struct {
		Error struct {
			Code string `json:"code"`
		} `json:"error"`
	}
	if err := json.Unmarshal(body, &payload); err != nil {
		t.Fatalf("decode error body: %v: %s", err, body)
	}
	return payload.Error.Code
}

func (s *scenario) countGatewayRows(table string) int {
	s.t.Helper()
	return countSQLiteRows(s.t, s.gatewayDB, table)
}

func (s *scenario) countCoordinatorRows(table string) int {
	s.t.Helper()
	return countSQLiteRows(s.t, s.coordinatorDB, table)
}

func countSQLiteRows(t *testing.T, path, table string) int {
	t.Helper()
	allowed := map[string]bool{"quota_reservations": true, "request_log": true}
	if !allowed[table] {
		t.Fatalf("integration row counter called for unapproved table %q", table)
	}
	db, err := sql.Open("sqlite", path)
	if err != nil {
		t.Fatalf("open sqlite %s: %v", path, err)
	}
	defer db.Close()
	var count int
	if err := db.QueryRow("SELECT COUNT(*) FROM " + table).Scan(&count); err != nil {
		t.Fatalf("count %s: %v", table, err)
	}
	return count
}
