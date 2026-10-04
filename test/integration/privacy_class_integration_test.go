package integration

import (
	"bytes"
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
)

const (
	privacyCanaryPrompt     = "PRIVACY-CANARY-7f3a"
	privacyCanaryCompletion = "PRIVACY-COMPLETION-9b2c"
	privacyClassHeaderName  = "X-MacProvider-Privacy-Class"
	privacyClassHeaderValue = "operator_constrained_beta_v1"
	// privacyFixtureCDHash is FixturePrivacyPostureProbe.defaultCodeCDHash.
	privacyFixtureCDHash = "f1a7" + "000000000000000000000000000000000000"
	// privacyStaleDelay sits past the harness posture max age (20s) and inside
	// the 30s reservation TTL. The gateway rejects a reservation that expires
	// more than 30s ahead, so the plan's 45s max age cannot be used here.
	privacyStaleDelay = 22 * time.Second
)

type privacyProxyMode int

const (
	privacyProxyObserve privacyProxyMode = iota
	privacyProxyStripChatHeader
	privacyProxyInjectChatHeader
	privacyProxyDelayChat
	privacyProxyTamperCiphertext
	privacyProxyDropFinal
)

type privacyCapture struct {
	mu                sync.Mutex
	buyerKeys         []string
	chatBody          []byte
	chatRequestID     string
	reservationErr    string
	chatErr           string
	reservationStatus int
	chatStatus        int
	chatBodyLen       int
	mutated           bool
}

func (c *privacyCapture) noteRequest(path string, header http.Header, body []byte) {
	if path != "/v1/chat/completions" {
		return
	}
	var envelope struct {
		BuyerKey string `json:"buyer_ephemeral_public_key"`
	}
	_ = json.Unmarshal(body, &envelope)
	c.mu.Lock()
	defer c.mu.Unlock()
	c.chatBody = append([]byte(nil), body...)
	c.chatRequestID = header.Get("X-Request-ID")
	if envelope.BuyerKey != "" {
		c.buyerKeys = append(c.buyerKeys, envelope.BuyerKey)
	}
}

func (c *privacyCapture) noteResponse(path string, status int, body []byte) {
	code := privacyCodeInBody(body)
	c.mu.Lock()
	defer c.mu.Unlock()
	switch path {
	case "/v1/relay-blind/route-reservations":
		c.reservationStatus = status
		if code != "" {
			c.reservationErr = code
		}
	case "/v1/chat/completions":
		c.chatStatus = status
		c.chatBodyLen = len(body)
		if code != "" {
			c.chatErr = code
		}
	}
}

func (c *privacyCapture) markMutated() {
	c.mu.Lock()
	c.mutated = true
	c.mu.Unlock()
}

func (c *privacyCapture) code(which string) string {
	c.mu.Lock()
	defer c.mu.Unlock()
	if which == "chat" {
		return c.chatErr
	}
	return c.reservationErr
}

func (c *privacyCapture) chatMeta() (status, n int) {
	c.mu.Lock()
	defer c.mu.Unlock()
	return c.chatStatus, c.chatBodyLen
}

func (c *privacyCapture) keys() []string {
	c.mu.Lock()
	defer c.mu.Unlock()
	return append([]string(nil), c.buyerKeys...)
}

type privacyStack struct {
	s          *scenario
	fixture    *swiftRelayFixture
	stateDir   string
	providerID string
}

func requirePrivacyDarwin(t *testing.T) {
	t.Helper()
	if runtime.GOOS != "darwin" {
		t.Skip("real Swift InferenceRelay fixture requires macOS")
	}
	if _, err := exec.LookPath("swift"); err != nil {
		t.Skip("Swift toolchain unavailable")
	}
}

type privacyStackOpts struct {
	traced         bool
	omitKeys       bool
	fixtureCDHash  string
	approvedCDHash string
	completion     string
	waitPosture    bool
}

func newPrivacyStack(t *testing.T, opts privacyStackOpts) *privacyStack {
	t.Helper()
	requirePrivacyDarwin(t)
	stateDir := t.TempDir()
	if err := os.Chmod(stateDir, 0o700); err != nil {
		t.Fatal(err)
	}
	resolved, err := filepath.EvalSymlinks(stateDir)
	if err != nil {
		t.Fatal(err)
	}
	stateDir = resolved
	providerID := "prov-swift-privacy-" + randHex(t, 4)
	fixture := startSwiftPrivacyFixture(t, stateDir, defaultFakeModelID, swiftPrivacyFixtureOpts{
		ProviderID: providerID,
		CDHash:     opts.fixtureCDHash,
		Traced:     opts.traced,
		Completion: opts.completion,
		OmitKeys:   opts.omitKeys,
	})
	approved := opts.approvedCDHash
	if approved == "" {
		approved = fixture.descriptor.CodeCDHash
	}
	s := newScenario(t, scenarioOpts{
		seedAccount:                  true,
		providerID:                   providerID,
		externalWebSocketProvider:    true,
		gatewayRelayBlindEnabled:     true,
		coordinatorRelayBlindEnabled: true,
		relayBlindIdentityPublicKeys: map[string]string{providerID: fixture.descriptor.IdentityPublicKey},
		coordinatorPrivacyClass: &coordinatorPrivacyClassOpts{
			SEPublicKey:       fixture.descriptor.SEPublicKey,
			TeamID:            fixture.descriptor.TeamID,
			SigningIdentifier: fixture.descriptor.SigningIdentifier,
			CDHash:            approved,
		},
		gatewayPrivacyClass: true,
		captureCoordLogs:    true,
		captureGatewayLogs:  true,
	})
	connectSwiftRelayProvider(t, s.rootCtx, s, fixture)
	s.waitForProviderReady(providerID)
	if opts.waitPosture {
		fixture.waitPosture(25 * time.Second)
	}
	return &privacyStack{s: s, fixture: fixture, stateDir: stateDir, providerID: providerID}
}

func (p *privacyStack) pinPath(t *testing.T) string {
	t.Helper()
	path := filepath.Join(p.stateDir, "buyer-pin.json")
	pin := map[string]any{
		"version":             "relay-blind-pilot-pin-v1",
		"identity_public_key": p.fixture.descriptor.IdentityPublicKey,
		"fingerprint":         p.fixture.descriptor.KeyRecord["identity_fingerprint"],
		"models":              []string{defaultFakeModelID},
		"endpoint_families":   []string{"chat_completions"},
		"not_before_unix":     p.fixture.descriptor.KeyRecord["not_before_unix"],
		"expires_at_unix":     p.fixture.descriptor.KeyRecord["expires_at_unix"],
		"revoked":             false,
	}
	raw, err := json.Marshal(pin)
	if err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(path, raw, 0o600); err != nil {
		t.Fatal(err)
	}
	return path
}

func runPrivacyClient(t *testing.T, apiKey, baseURL, pinPath, prompt string, stream, privacy bool) (string, string, error) {
	t.Helper()
	args := []string{
		"--base-url", baseURL,
		"--identity-pin", pinPath,
		"--model", defaultFakeModelID,
		"--max-output-tokens", "32",
		"--input-token-upper-bound", "64",
		"--input", "-",
	}
	if stream {
		args = append(args, "--stream")
	}
	if privacy {
		args = append(args, "--privacy-class")
	}
	cmd := exec.Command(relayBlindClientBin, args...)
	cmd.Env = append(os.Environ(), "MACPROVIDER_API_KEY="+apiKey)
	cmd.Stdin = strings.NewReader(fmt.Sprintf(`{"model":%q,"messages":[{"role":"user","content":%q}],"stream":%t,"max_tokens":32}`, defaultFakeModelID, prompt, stream))
	var stdout, stderr strings.Builder
	cmd.Stdout = &stdout
	cmd.Stderr = &stderr
	err := cmd.Run()
	return stdout.String(), stderr.String(), err
}

func privacyClientDetail(stderr string) string {
	if strings.Contains(stderr, privacyCanaryPrompt) || strings.Contains(stderr, privacyCanaryCompletion) {
		return "stderr contains a canary"
	}
	if len(stderr) > 400 {
		return fmt.Sprintf("stderr_len=%d", len(stderr))
	}
	return strings.TrimSpace(stderr)
}

func privacyCodeInBody(body []byte) string {
	var payload struct {
		Error struct {
			Code string `json:"code"`
		} `json:"error"`
	}
	if json.Unmarshal(body, &payload) == nil && payload.Error.Code != "" {
		return payload.Error.Code
	}
	for _, code := range []string{
		"privacy_class_downgrade_rejected",
		"privacy_class_unavailable",
		"privacy_class_posture_stale",
		"privacy_class_disabled",
		"privacy_class_unconfirmed",
		"relay_blind_replay",
	} {
		if bytes.Contains(body, []byte(`"`+code+`"`)) {
			return code
		}
	}
	return ""
}

// privacyPlaintextHas reports whether decrypted provider plaintext contains
// needle. Stream frames are SSE events, and the fixture splits a completion
// across two content deltas, so the needle is not one contiguous substring
// of the concatenated frames.
func privacyPlaintextHas(stdout, needle string) bool {
	if strings.Contains(stdout, needle) {
		return true
	}
	var assembled strings.Builder
	collect := func(raw string) {
		var payload struct {
			Choices []struct {
				Delta struct {
					Content string `json:"content"`
				} `json:"delta"`
				Message struct {
					Content string `json:"content"`
				} `json:"message"`
			} `json:"choices"`
		}
		if json.Unmarshal([]byte(raw), &payload) != nil {
			return
		}
		for _, choice := range payload.Choices {
			assembled.WriteString(choice.Delta.Content)
			assembled.WriteString(choice.Message.Content)
		}
	}
	if strings.Contains(stdout, "data:") {
		for _, line := range strings.Split(stdout, "\n") {
			line = strings.TrimSpace(line)
			if !strings.HasPrefix(line, "data:") {
				continue
			}
			data := strings.TrimSpace(strings.TrimPrefix(line, "data:"))
			if data == "" || data == "[DONE]" {
				continue
			}
			collect(data)
		}
	} else {
		collect(stdout)
	}
	return strings.Contains(assembled.String(), needle)
}

func privacyErrorCode(t *testing.T, body []byte) string {
	t.Helper()
	var payload struct {
		Error struct {
			Code string `json:"code"`
		} `json:"error"`
	}
	if json.Unmarshal(body, &payload) != nil || payload.Error.Code == "" {
		t.Fatalf("response missing error code, body_len=%d", len(body))
	}
	return payload.Error.Code
}

func startPrivacyProxy(t *testing.T, upstream string, mode privacyProxyMode) (string, *privacyCapture) {
	t.Helper()
	target, err := url.Parse(upstream)
	if err != nil {
		t.Fatal(err)
	}
	capture := &privacyCapture{}
	proxy := httputil.NewSingleHostReverseProxy(target)
	original := proxy.Director
	proxy.Director = func(req *http.Request) {
		original(req)
		if req.Body != nil && (req.URL.Path == "/v1/chat/completions" || req.URL.Path == "/v1/relay-blind/route-reservations") {
			raw, readErr := io.ReadAll(req.Body)
			_ = req.Body.Close()
			if readErr == nil {
				capture.noteRequest(req.URL.Path, req.Header, raw)
				req.Body = io.NopCloser(bytes.NewReader(raw))
				req.ContentLength = int64(len(raw))
				req.GetBody = func() (io.ReadCloser, error) {
					return io.NopCloser(bytes.NewReader(raw)), nil
				}
			}
		}
		if req.URL.Path != "/v1/chat/completions" {
			return
		}
		switch mode {
		case privacyProxyStripChatHeader:
			req.Header.Del(privacyClassHeaderName)
		case privacyProxyInjectChatHeader:
			req.Header.Set(privacyClassHeaderName, privacyClassHeaderValue)
		case privacyProxyDelayChat:
			time.Sleep(privacyStaleDelay)
		}
	}
	proxy.ModifyResponse = func(resp *http.Response) error {
		path := ""
		if resp.Request != nil && resp.Request.URL != nil {
			path = resp.Request.URL.Path
		}
		raw, err := io.ReadAll(resp.Body)
		_ = resp.Body.Close()
		if err != nil {
			return err
		}
		mutated := raw
		if resp.StatusCode >= 200 && resp.StatusCode < 300 && path == "/v1/chat/completions" {
			switch mode {
			case privacyProxyTamperCiphertext:
				if next, ok := tamperFirstCiphertext(raw); ok {
					mutated = next
					capture.markMutated()
				}
			case privacyProxyDropFinal:
				if next, ok := dropFinalPrivacyEvent(raw); ok {
					mutated = next
					capture.markMutated()
				}
			}
		}
		capture.noteResponse(path, resp.StatusCode, mutated)
		resp.Body = io.NopCloser(bytes.NewReader(mutated))
		resp.ContentLength = int64(len(mutated))
		resp.Header.Del("Content-Encoding")
		return nil
	}
	server := httptest.NewServer(proxy)
	t.Cleanup(server.Close)
	return server.URL, capture
}

func tamperFirstCiphertext(raw []byte) ([]byte, bool) {
	const marker = `"ciphertext":"`
	idx := bytes.Index(raw, []byte(marker))
	if idx < 0 || idx+len(marker) >= len(raw) {
		return raw, false
	}
	at := idx + len(marker)
	out := append([]byte(nil), raw...)
	if out[at] == 'A' {
		out[at] = 'B'
	} else {
		out[at] = 'A'
	}
	return out, true
}

func dropFinalPrivacyEvent(raw []byte) ([]byte, bool) {
	text := string(raw)
	if !strings.Contains(text, "data:") {
		return raw, false
	}
	parts := strings.Split(text, "\n\n")
	kept := make([]string, 0, len(parts))
	dropped := false
	for _, part := range parts {
		if part == "" {
			continue
		}
		if strings.Contains(part, `"final":true`) || strings.Contains(part, `"final": true`) {
			dropped = true
			continue
		}
		kept = append(kept, part)
	}
	if !dropped {
		return raw, false
	}
	return []byte(strings.Join(kept, "\n\n") + "\n\n"), true
}

func runPrivacyCLI(t *testing.T, args ...string) string {
	t.Helper()
	var output []byte
	var err error
	for attempt := 0; attempt < 5; attempt++ {
		cmd := exec.Command(coordinatorCLIBin, args...)
		output, err = cmd.CombinedOutput()
		if err == nil {
			return string(output)
		}
		text := string(output)
		if strings.Contains(text, "locked") || strings.Contains(text, "busy") || strings.Contains(text, "SQLITE_BUSY") {
			time.Sleep(100 * time.Millisecond)
			continue
		}
		if strings.Contains(text, privacyCanaryPrompt) || strings.Contains(text, privacyCanaryCompletion) {
			t.Fatalf("coordinator-cli failed and its output contains a canary: %v", err)
		}
		t.Fatalf("coordinator-cli failed: %v: %s", err, strings.TrimSpace(text))
	}
	t.Fatal("coordinator-cli remained busy")
	return ""
}

func privacyStatusValue(status, key string) string {
	prefix := key + "="
	for _, line := range strings.Split(status, "\n") {
		if strings.HasPrefix(line, prefix) {
			return strings.TrimPrefix(line, prefix)
		}
	}
	return ""
}

func assertClientFailed(t *testing.T, err error, stderr string, wantDoNotResubmit bool) {
	t.Helper()
	if err == nil {
		t.Fatal("privacy client succeeded")
	}
	if wantDoNotResubmit && !strings.Contains(stderr, "do not resubmit") {
		t.Fatalf("client exit missing do-not-resubmit: %s", privacyClientDetail(stderr))
	}
}

func assertDispatches(t *testing.T, fixture *swiftRelayFixture, want int32) {
	t.Helper()
	if got := fixture.dispatches.Load(); got != want {
		t.Fatalf("fixture dispatches=%d, want %d", got, want)
	}
}

func assertUsageTokens(t *testing.T, s *scenario) {
	t.Helper()
	usage, ok := s.readLatestUsageEvent()
	if !ok || usage.PromptTokens != 5 || usage.CompletionTokens != 4 || usage.TotalTokens != 9 {
		t.Fatalf("usage tokens prompt=%d completion=%d total=%d found=%v", usage.PromptTokens, usage.CompletionTokens, usage.TotalTokens, ok)
	}
}

func TestPrivacyClassSwiftProviderStreamEndToEnd(t *testing.T) {
	runPrivacyClassSwiftEndToEnd(t, true)
}

func TestPrivacyClassSwiftProviderNonstreamEndToEnd(t *testing.T) {
	runPrivacyClassSwiftEndToEnd(t, false)
}

func runPrivacyClassSwiftEndToEnd(t *testing.T, stream bool) {
	t.Helper()
	stack := newPrivacyStack(t, privacyStackOpts{
		completion:  privacyCanaryCompletion,
		waitPosture: true,
	})
	stdout, stderr, err := runPrivacyClient(t, stack.s.apiKey, stack.s.gatewayBaseURL, stack.pinPath(t), "privacy-class end to end", stream, true)
	if err != nil {
		t.Fatalf("privacy client: %v (%s)", err, privacyClientDetail(stderr))
	}
	if !privacyPlaintextHas(stdout, privacyCanaryCompletion) {
		t.Fatalf("decrypted plaintext missing completion, stdout_len=%d", len(stdout))
	}
	if !strings.Contains(stderr, "privacy class satisfied") {
		t.Fatal("client did not report privacy class satisfied")
	}
	assertDispatches(t, stack.fixture, 1)
	assertUsageTokens(t, stack.s)
}

func TestPrivacyClassRedactionNoCanaryInAnyArtifact(t *testing.T) {
	stack := newPrivacyStack(t, privacyStackOpts{
		completion:  privacyCanaryCompletion,
		waitPosture: true,
	})
	base, capture := startPrivacyProxy(t, stack.s.gatewayBaseURL, privacyProxyObserve)
	pin := stack.pinPath(t)
	for _, stream := range []bool{true, false} {
		stdout, stderr, err := runPrivacyClient(t, stack.s.apiKey, base, pin, privacyCanaryPrompt, stream, true)
		if err != nil {
			t.Fatalf("privacy client stream=%t: %v (%s)", stream, err, privacyClientDetail(stderr))
		}
		if !privacyPlaintextHas(stdout, privacyCanaryCompletion) {
			t.Fatalf("decrypted plaintext missing completion, stream=%t stdout_len=%d", stream, len(stdout))
		}
	}
	assertDispatches(t, stack.fixture, 2)
	keys := capture.keys()
	if len(keys) != 2 {
		t.Fatalf("captured buyer keys=%d, want 2", len(keys))
	}
	needles := []struct {
		class string
		text  string
	}{
		{"prompt canary", privacyCanaryPrompt},
		{"completion canary", privacyCanaryCompletion},
	}
	for _, key := range keys {
		if len(key) < 43 {
			t.Fatalf("buyer key length %d is shorter than a 32-byte base64url value", len(key))
		}
		needles = append(needles, struct {
			class string
			text  string
		}{"buyer key", key})
	}
	assertPrivacyNeedlesAbsent(t, stack, needles)
}

func assertPrivacyNeedlesAbsent(t *testing.T, stack *privacyStack, needles []struct {
	class string
	text  string
}) {
	t.Helper()
	buffers := []struct {
		name string
		buf  *logBuffer
	}{
		{"coordinator", stack.s.coordLogBuf},
		{"gateway", stack.s.gatewayLogBuf},
		{"fixture-stdout", stack.fixture.stdoutLog},
		{"fixture-stderr", stack.fixture.stderrLog},
	}
	for _, item := range buffers {
		if item.buf == nil {
			t.Fatalf("%s log buffer was not captured", item.name)
		}
		text := strings.Join(item.buf.snapshot(), "\n")
		for _, needle := range needles {
			if strings.Contains(text, needle.text) {
				t.Fatalf("%s log contains %s", item.name, needle.class)
			}
		}
	}
	for _, root := range []string{stack.s.tempDir, stack.stateDir} {
		resolved, err := filepath.EvalSymlinks(root)
		if err != nil {
			t.Fatal(err)
		}
		err = filepath.WalkDir(resolved, func(path string, entry os.DirEntry, walkErr error) error {
			if walkErr != nil {
				return walkErr
			}
			if entry.Type()&os.ModeSymlink != 0 {
				if entry.IsDir() {
					return filepath.SkipDir
				}
				return nil
			}
			if entry.IsDir() {
				return nil
			}
			data, readErr := os.ReadFile(path)
			if readErr != nil {
				return readErr
			}
			for _, needle := range needles {
				if bytes.Contains(data, []byte(needle.text)) {
					rel, relErr := filepath.Rel(resolved, path)
					if relErr != nil {
						rel = entry.Name()
					}
					t.Fatalf("%s contains %s", rel, needle.class)
				}
			}
			return nil
		})
		if err != nil {
			t.Fatal(err)
		}
	}
}

func TestPrivacyClassAdversarial(t *testing.T) {
	t.Run("plaintext_downgrade", func(t *testing.T) {
		stack := newPrivacyStack(t, privacyStackOpts{})
		status, _, body := stack.s.chatRequest(map[string]string{
			privacyClassHeaderName: privacyClassHeaderValue,
		}, fmt.Sprintf(`{"model":%q,"messages":[{"role":"user","content":"plaintext"}],"stream":false}`, defaultFakeModelID))
		if status != http.StatusBadRequest {
			t.Fatalf("status=%d, want 400", status)
		}
		if got := privacyErrorCode(t, body); got != "privacy_class_downgrade_rejected" {
			t.Fatalf("error code %q, want privacy_class_downgrade_rejected", got)
		}
		assertDispatches(t, stack.fixture, 0)
	})

	t.Run("strip_header_at_proxy", func(t *testing.T) {
		stack := newPrivacyStack(t, privacyStackOpts{completion: privacyCanaryCompletion, waitPosture: true})
		base, capture := startPrivacyProxy(t, stack.s.gatewayBaseURL, privacyProxyStripChatHeader)
		_, stderr, err := runPrivacyClient(t, stack.s.apiKey, base, stack.pinPath(t), "strip header", true, true)
		assertClientFailed(t, err, stderr, false)
		if got := capture.code("chat"); got != "privacy_class_downgrade_rejected" {
			t.Fatalf("chat error code %q, want privacy_class_downgrade_rejected", got)
		}
		assertDispatches(t, stack.fixture, 0)
	})

	t.Run("inject_header_relay_blind", func(t *testing.T) {
		// The store primary key is (provider_id, kid). A privacy advertisement
		// of the same record replaces key_class, so an ordinary reservation
		// cannot see it. Production privacy mode never also advertises that
		// key as relay_blind. This subtest advertises only the relay-blind
		// record, then the proxy adds the privacy header on the chat.
		stack := newPrivacyStack(t, privacyStackOpts{omitKeys: true})
		base, capture := startPrivacyProxy(t, stack.s.gatewayBaseURL, privacyProxyInjectChatHeader)
		_, stderr, err := runPrivacyClient(t, stack.s.apiKey, base, stack.pinPath(t), "inject header", false, false)
		assertClientFailed(t, err, stderr, false)
		if got := capture.code("chat"); got != "privacy_class_downgrade_rejected" {
			status, n := capture.chatMeta()
			t.Fatalf("chat error code %q status=%d body_len=%d reservation=%q (%s), want privacy_class_downgrade_rejected", got, status, n, capture.code("reservation"), privacyClientDetail(stderr))
		}
		assertDispatches(t, stack.fixture, 0)
	})

	t.Run("replay_envelope", func(t *testing.T) {
		stack := newPrivacyStack(t, privacyStackOpts{completion: privacyCanaryCompletion, waitPosture: true})
		base, capture := startPrivacyProxy(t, stack.s.gatewayBaseURL, privacyProxyObserve)
		stdout, stderr, err := runPrivacyClient(t, stack.s.apiKey, base, stack.pinPath(t), "replay first", false, true)
		if err != nil {
			t.Fatalf("first privacy client: %v (%s)", err, privacyClientDetail(stderr))
		}
		if !privacyPlaintextHas(stdout, privacyCanaryCompletion) {
			t.Fatalf("first response missing completion, stdout_len=%d", len(stdout))
		}
		capture.mu.Lock()
		body := append([]byte(nil), capture.chatBody...)
		requestID := capture.chatRequestID
		capture.mu.Unlock()
		if requestID == "" || len(body) == 0 {
			t.Fatal("proxy did not capture the chat envelope")
		}
		status, _, replayBody := stack.s.jsonRequest(http.MethodPost, "/v1/chat/completions", map[string]string{
			"X-Request-ID":         requestID,
			privacyClassHeaderName: privacyClassHeaderValue,
		}, string(body))
		if status < 400 {
			t.Fatalf("replay status=%d, want an error", status)
		}
		if got := privacyErrorCode(t, replayBody); got != "relay_blind_replay" {
			t.Fatalf("replay error code %q, want relay_blind_replay", got)
		}
		assertDispatches(t, stack.fixture, 1)
	})

	t.Run("wrong_key_record", func(t *testing.T) {
		stack := newPrivacyStack(t, privacyStackOpts{omitKeys: true})
		base, capture := startPrivacyProxy(t, stack.s.gatewayBaseURL, privacyProxyObserve)
		_, stderr, err := runPrivacyClient(t, stack.s.apiKey, base, stack.pinPath(t), "wrong key", false, true)
		assertClientFailed(t, err, stderr, false)
		if got := capture.code("reservation"); got != "privacy_class_unavailable" {
			t.Fatalf("reservation error code %q, want privacy_class_unavailable", got)
		}
		assertDispatches(t, stack.fixture, 0)
	})

	t.Run("stale_posture", func(t *testing.T) {
		stack := newPrivacyStack(t, privacyStackOpts{completion: privacyCanaryCompletion, waitPosture: true})
		stack.fixture.holdPosture.Store(true)
		base, capture := startPrivacyProxy(t, stack.s.gatewayBaseURL, privacyProxyDelayChat)
		_, stderr, err := runPrivacyClient(t, stack.s.apiKey, base, stack.pinPath(t), "stale posture", false, true)
		assertClientFailed(t, err, stderr, false)
		if got := capture.code("chat"); got != "privacy_class_posture_stale" {
			t.Fatalf("chat error code %q, want privacy_class_posture_stale", got)
		}
		assertDispatches(t, stack.fixture, 0)
	})

	t.Run("revoked_quarantined", func(t *testing.T) {
		stack := newPrivacyStack(t, privacyStackOpts{waitPosture: true})
		status := runPrivacyCLI(t, "privacy-class", "quarantine",
			"--config", stack.s.coordYAML,
			"--provider", stack.providerID,
			"--reason", "integration quarantine",
			"--seconds", "3600")
		if privacyStatusValue(status, "quarantine.provider_id") != stack.providerID {
			t.Fatalf("quarantine status missing provider, count=%s", privacyStatusValue(status, "quarantine_count"))
		}
		base, capture := startPrivacyProxy(t, stack.s.gatewayBaseURL, privacyProxyObserve)
		_, stderr, err := runPrivacyClient(t, stack.s.apiKey, base, stack.pinPath(t), "quarantined", false, true)
		assertClientFailed(t, err, stderr, false)
		if got := capture.code("reservation"); got != "privacy_class_unavailable" {
			t.Fatalf("reservation error code %q, want privacy_class_unavailable", got)
		}
		assertDispatches(t, stack.fixture, 0)
	})

	t.Run("unapproved_cdhash", func(t *testing.T) {
		stack := newPrivacyStack(t, privacyStackOpts{
			fixtureCDHash:  strings.Repeat("a", 40),
			approvedCDHash: privacyFixtureCDHash,
		})
		status := runPrivacyCLI(t, "privacy-class", "status", "--config", stack.s.coordYAML)
		if privacyStatusValue(status, "quarantine.provider_id") != stack.providerID || privacyStatusValue(status, "quarantine.reason") != "posture_unapproved_code_identity" {
			t.Fatalf("quarantine count=%s reason=%s", privacyStatusValue(status, "quarantine_count"), privacyStatusValue(status, "quarantine.reason"))
		}
		base, capture := startPrivacyProxy(t, stack.s.gatewayBaseURL, privacyProxyObserve)
		_, stderr, err := runPrivacyClient(t, stack.s.apiKey, base, stack.pinPath(t), "unapproved", false, true)
		assertClientFailed(t, err, stderr, false)
		if got := capture.code("reservation"); got != "privacy_class_unavailable" {
			t.Fatalf("reservation error code %q, want privacy_class_unavailable", got)
		}
		assertDispatches(t, stack.fixture, 0)
	})

	t.Run("debugger_attached_posture", func(t *testing.T) {
		stack := newPrivacyStack(t, privacyStackOpts{traced: true})
		status := runPrivacyCLI(t, "privacy-class", "status", "--config", stack.s.coordYAML)
		if privacyStatusValue(status, "quarantine_count") != "0" {
			t.Fatalf("quarantine_count=%s, want 0", privacyStatusValue(status, "quarantine_count"))
		}
		base, capture := startPrivacyProxy(t, stack.s.gatewayBaseURL, privacyProxyObserve)
		_, stderr, err := runPrivacyClient(t, stack.s.apiKey, base, stack.pinPath(t), "traced", false, true)
		assertClientFailed(t, err, stderr, false)
		if got := capture.code("reservation"); got != "privacy_class_unavailable" {
			t.Fatalf("reservation error code %q, want privacy_class_unavailable", got)
		}
		assertDispatches(t, stack.fixture, 0)
	})

	t.Run("tampered_response", func(t *testing.T) {
		runPrivacyMutation(t, privacyProxyTamperCiphertext)
	})

	t.Run("truncated_response", func(t *testing.T) {
		runPrivacyMutation(t, privacyProxyDropFinal)
	})

	t.Run("kill_switch", func(t *testing.T) {
		stack := newPrivacyStack(t, privacyStackOpts{waitPosture: true})
		status := runPrivacyCLI(t, "privacy-class", "disable",
			"--config", stack.s.coordYAML,
			"--reason", "integration kill switch")
		if privacyStatusValue(status, "disabled") != "1" {
			t.Fatalf("kill switch disabled=%s", privacyStatusValue(status, "disabled"))
		}
		base, capture := startPrivacyProxy(t, stack.s.gatewayBaseURL, privacyProxyObserve)
		_, stderr, err := runPrivacyClient(t, stack.s.apiKey, base, stack.pinPath(t), "kill switch", false, true)
		assertClientFailed(t, err, stderr, false)
		if got := capture.code("reservation"); got != "privacy_class_disabled" {
			t.Fatalf("reservation error code %q, want privacy_class_disabled", got)
		}
		assertDispatches(t, stack.fixture, 0)
	})
}

func runPrivacyMutation(t *testing.T, mode privacyProxyMode) {
	t.Helper()
	stack := newPrivacyStack(t, privacyStackOpts{completion: privacyCanaryCompletion, waitPosture: true})
	base, capture := startPrivacyProxy(t, stack.s.gatewayBaseURL, mode)
	_, stderr, err := runPrivacyClient(t, stack.s.apiKey, base, stack.pinPath(t), "mutate response", true, true)
	assertClientFailed(t, err, stderr, true)
	capture.mu.Lock()
	mutated := capture.mutated
	chatErr := capture.chatErr
	capture.mu.Unlock()
	if !mutated {
		t.Fatal("proxy did not mutate the privacy response")
	}
	if chatErr == "privacy_class_unconfirmed" {
		t.Fatal("mutated response surfaced privacy_class_unconfirmed")
	}
	assertDispatches(t, stack.fixture, 1)
}
