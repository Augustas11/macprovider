package integration

import (
	"bufio"
	"context"
	"crypto/ed25519"
	"encoding/base64"
	"encoding/json"
	"fmt"
	"io"
	"net"
	"net/http"
	"net/url"
	"os"
	"os/exec"
	"path/filepath"
	"reflect"
	"runtime"
	"strings"
	"sync"
	"testing"
	"time"

	gobwas "github.com/gobwas/ws"
	"github.com/gobwas/ws/wsutil"
)

var (
	swiftRelayBuildOnce sync.Once
	swiftRelayBinary    string
	swiftRelayBuildErr  error
)

type swiftRelayDescriptor struct {
	Type                  string         `json:"type"`
	Version               string         `json:"version"`
	BodyEncoding          string         `json:"body_encoding"`
	AssignedSession       string         `json:"assigned_session"`
	IdentityPublicKey     string         `json:"identity_public_key"`
	KeyRecord             map[string]any `json:"relay_blind_key_record"`
	ContinuousBatchReplay bool           `json:"continuous_batch_replay"`
	ProviderID            string         `json:"provider_id"`
	ModelID               string         `json:"model_id"`
	ModelHash             string         `json:"model_hash"`
	ReceiptPublicKey      string         `json:"provider_receipt_public_key"`
	ReceiptKeyID          string         `json:"provider_receipt_key_id"`
	ReplayStore           string         `json:"replay_store"`
}

type swiftRelayFixture struct {
	t                 *testing.T
	cmd               *exec.Cmd
	stdin             io.WriteCloser
	stdout            *bufio.Scanner
	descriptor        swiftRelayDescriptor
	inputMu           sync.Mutex
	stateDir          string
	model             string
	streamDelayMS     int
	crashReplayResult chan error
}

func buildSwiftRelayBinary(t *testing.T) string {
	t.Helper()
	if override := strings.TrimSpace(os.Getenv("MACPROVIDER_RELAY_BLIND_FIXTURE_BINARY")); override != "" {
		absolute, err := filepath.Abs(override)
		if err != nil {
			t.Fatalf("resolve Swift relay fixture override: %v", err)
		}
		info, err := os.Stat(absolute)
		if err != nil || info.IsDir() || info.Mode()&0o111 == 0 {
			t.Fatalf("Swift relay fixture override is not executable: %s", absolute)
		}
		return absolute
	}
	swiftRelayBuildOnce.Do(func() {
		root, err := findRepoRoot()
		if err != nil {
			swiftRelayBuildErr = err
			return
		}
		dir := filepath.Join(root, "phase3-binary")
		build := exec.Command("swift", "build", "--product", "macprovider-cli")
		build.Dir = dir
		if out, err := build.CombinedOutput(); err != nil {
			swiftRelayBuildErr = fmt.Errorf("swift fixture build: %w\n%s", err, out)
			return
		}
		show := exec.Command("swift", "build", "--show-bin-path")
		show.Dir = dir
		out, err := show.CombinedOutput()
		if err != nil {
			swiftRelayBuildErr = fmt.Errorf("swift fixture bin path: %w\n%s", err, out)
			return
		}
		swiftRelayBinary = filepath.Join(strings.TrimSpace(string(out)), "macprovider-cli")
	})
	if swiftRelayBuildErr != nil {
		t.Fatal(swiftRelayBuildErr)
	}
	return swiftRelayBinary
}

func startSwiftRelayFixture(t *testing.T, stateDir, model string) *swiftRelayFixture {
	return startSwiftRelayFixtureWithDelay(t, stateDir, model, 0)
}

func startSwiftRelayFixtureWithDelay(t *testing.T, stateDir, model string, streamDelayMS int) *swiftRelayFixture {
	t.Helper()
	fixture := &swiftRelayFixture{t: t, stateDir: stateDir, model: model, streamDelayMS: streamDelayMS}
	fixture.start("")
	t.Cleanup(fixture.stop)
	return fixture
}

func startSwiftContinuousBatchReplayFixture(t *testing.T, stateDir, model string) *swiftRelayFixture {
	t.Helper()
	fixture := &swiftRelayFixture{t: t, stateDir: stateDir, model: model}
	fixture.startWithMode("", true)
	t.Cleanup(fixture.stop)
	return fixture
}

func (f *swiftRelayFixture) start(assignedSession string) {
	f.startWithMode(assignedSession, false)
}

func (f *swiftRelayFixture) startWithMode(assignedSession string, continuousBatchReplay bool) {
	f.t.Helper()
	args := []string{"relay-blind-fixture", "--state-dir", f.stateDir, "--model", f.model}
	if f.streamDelayMS > 0 {
		args = append(args, "--stream-delay-ms", fmt.Sprint(f.streamDelayMS))
	}
	if assignedSession != "" {
		args = append(args, "--assigned-session", assignedSession)
	}
	if continuousBatchReplay {
		args = append(args, "--continuous-batch-replay")
	}
	cmd := exec.Command(buildSwiftRelayBinary(f.t), args...)
	cmd.Env = append(os.Environ(), "MACPROVIDER_ALLOW_TEST_FIXTURES=1")
	stdin, err := cmd.StdinPipe()
	if err != nil {
		f.t.Fatal(err)
	}
	stdoutPipe, err := cmd.StdoutPipe()
	if err != nil {
		f.t.Fatal(err)
	}
	stderr, err := cmd.StderrPipe()
	if err != nil {
		f.t.Fatal(err)
	}
	if err := cmd.Start(); err != nil {
		f.t.Fatalf("start Swift relay fixture: %v", err)
	}
	go pumpLogs(f.t, "swift-relay.err", stderr, nil)
	scanner := bufio.NewScanner(stdoutPipe)
	scanner.Buffer(make([]byte, 64<<10), 2<<20)
	if !scanner.Scan() {
		_ = cmd.Process.Kill()
		f.t.Fatalf("Swift relay fixture produced no descriptor: %v", scanner.Err())
	}
	var descriptor swiftRelayDescriptor
	if err := json.Unmarshal(scanner.Bytes(), &descriptor); err != nil {
		_ = cmd.Process.Kill()
		f.t.Fatalf("decode Swift relay descriptor: %v: %s", err, scanner.Bytes())
	}
	if descriptor.Type != "relay_blind_fixture_descriptor" || descriptor.Version != "relay-blind-request-v1" || descriptor.BodyEncoding != "relay-blind-request-v1" || descriptor.AssignedSession == "" || descriptor.IdentityPublicKey == "" || len(descriptor.KeyRecord) == 0 {
		_ = cmd.Process.Kill()
		f.t.Fatalf("invalid Swift relay descriptor: %+v", descriptor)
	}
	f.cmd = cmd
	f.stdin = stdin
	f.stdout = scanner
	f.descriptor = descriptor
}

func (f *swiftRelayFixture) reconnectRelayBoundary() {
	f.t.Helper()
	f.inputMu.Lock()
	defer f.inputMu.Unlock()
	if _, err := f.stdin.Write([]byte("{\"type\":\"relay_fixture_reconnect\"}\n")); err != nil {
		f.t.Fatalf("write Swift relay reconnect control: %v", err)
	}
	if !f.stdout.Scan() {
		f.t.Fatalf("Swift relay reconnect control produced no response: %v", f.stdout.Err())
	}
	var response struct {
		Type string `json:"type"`
	}
	if err := json.Unmarshal(f.stdout.Bytes(), &response); err != nil || response.Type != "relay_fixture_reconnected" {
		f.t.Fatalf("invalid Swift relay reconnect response: err=%v body=%s", err, f.stdout.Bytes())
	}
}

func TestSwiftRelayContinuousBatchDurableTerminalReplay(t *testing.T) {
	if runtime.GOOS != "darwin" {
		t.Skip("real Swift InferenceRelay fixture requires macOS")
	}
	stateDir := t.TempDir()
	if err := os.Chmod(stateDir, 0o700); err != nil {
		t.Fatal(err)
	}
	const model = "mlx-community/Qwen-Test"
	fixture := startSwiftContinuousBatchReplayFixture(t, stateDir, model)
	if !fixture.descriptor.ContinuousBatchReplay || fixture.descriptor.ProviderID == "" ||
		fixture.descriptor.ModelID != model ||
		fixture.descriptor.ModelHash == "" || fixture.descriptor.ReceiptPublicKey == "" ||
		fixture.descriptor.ReceiptKeyID == "" || fixture.descriptor.ReplayStore == "" {
		t.Fatalf("incomplete continuous-batch replay descriptor: %+v", fixture.descriptor)
	}

	const requestID = "relay-stable-m5-terminal-replay"
	body := fmt.Sprintf(`{"model":%q,"messages":[{"role":"user","content":"M5 durable replay"}],"stream":false,"max_tokens":2,"temperature":0,"top_p":1}`, model)
	frame, err := json.Marshal(map[string]any{
		"type":       "inference_request",
		"request_id": requestID,
		"stream":     false,
		"body":       body,
		"settlement": map[string]any{
			"account_scope":                 "integration-account",
			"request_id":                    requestID,
			"attempt_n":                     1,
			"provider_id":                   fixture.descriptor.ProviderID,
			"provider_receipt_key_id":       fixture.descriptor.ReceiptKeyID,
			"model_id":                      model,
			"expected_catalog_model_hash":   fixture.descriptor.ModelHash,
			"catalog_id":                    "integration-catalog",
			"catalog_body_digest":           strings.Repeat("c", 64),
			"route_snapshot_digest":         strings.Repeat("d", 64),
			"route_snapshot_policy_version": "integration-v1",
			"route_snapshot_mode":           "observe",
			"prompt_hash":                   strings.Repeat("e", 64),
			"output_prefix_start_byte":      0,
			"pending_deadline_seconds":      120,
		},
	})
	if err != nil {
		t.Fatal(err)
	}

	first := collectSwiftRelayFrames(t, fixture, frame)
	firstEnd := terminalSwiftRelayFrame(t, first)
	if got := intJSON(firstEnd["fixture_generation_count"]); got != 1 {
		t.Fatalf("first generation count=%d, want 1: terminal=%v", got, firstEnd)
	}
	if got := firstEnd["fixture_settlement_disposition"]; got != "eligible_owner" {
		t.Fatalf("first settlement disposition=%v, want eligible_owner", got)
	}
	firstReceipt, ok := firstEnd["receipt"].(string)
	if !ok || firstReceipt == "" {
		t.Fatalf("first terminal omitted settlement receipt: %v", firstEnd)
	}
	verifySwiftFixtureReceipt(t, firstReceipt, fixture.descriptor, requestID, firstEnd)

	fixture.reconnectRelayBoundary()
	replay := collectSwiftRelayFrames(t, fixture, frame)
	replayEnd := terminalSwiftRelayFrame(t, replay)
	if got := intJSON(replayEnd["fixture_generation_count"]); got != 1 {
		t.Fatalf("replay generation count=%d, want retained result without re-inference: terminal=%v", got, replayEnd)
	}
	if got := replayEnd["fixture_settlement_disposition"]; got != "non_settling_replay" {
		t.Fatalf("replay settlement disposition=%v, want non_settling_replay", got)
	}
	if receipt, present := replayEnd["receipt"]; present {
		t.Fatalf("non-settling replay emitted duplicate receipt: %v", receipt)
	}
	firstUsage, firstUsagePresent := firstEnd["usage"].(map[string]any)
	replayUsage, replayUsagePresent := replayEnd["usage"].(map[string]any)
	if !firstUsagePresent || !replayUsagePresent || !reflect.DeepEqual(firstUsage, replayUsage) {
		t.Fatalf("replay usage=%v, want retained first usage=%v", replayEnd["usage"], firstEnd["usage"])
	}
	assertDurableReplayClaim(t, fixture.descriptor.ReplayStore)
}

func collectSwiftRelayFrames(t *testing.T, fixture *swiftRelayFixture, frame []byte) []map[string]any {
	t.Helper()
	var frames []map[string]any
	if err := fixture.serveFrame(frame, func(raw []byte) error {
		var decoded map[string]any
		if err := json.Unmarshal(raw, &decoded); err != nil {
			return err
		}
		frames = append(frames, decoded)
		return nil
	}); err != nil {
		t.Fatalf("serve Swift relay frame: %v", err)
	}
	return frames
}

func terminalSwiftRelayFrame(t *testing.T, frames []map[string]any) map[string]any {
	t.Helper()
	for i := len(frames) - 1; i >= 0; i-- {
		if frames[i]["type"] == "inference_response_end" {
			return frames[i]
		}
	}
	t.Fatalf("missing terminal frame: %+v", frames)
	return nil
}

func verifySwiftFixtureReceipt(t *testing.T, receipt string, descriptor swiftRelayDescriptor, requestID string, terminal map[string]any) {
	t.Helper()
	parts := strings.Split(receipt, ".")
	if len(parts) != 2 {
		t.Fatalf("receipt envelope has %d parts, want 2", len(parts))
	}
	tuple, err := base64.StdEncoding.DecodeString(parts[0])
	if err != nil {
		t.Fatalf("decode receipt tuple: %v", err)
	}
	signature, err := base64.StdEncoding.DecodeString(parts[1])
	if err != nil {
		t.Fatalf("decode receipt signature: %v", err)
	}
	publicKey, err := base64.StdEncoding.DecodeString(descriptor.ReceiptPublicKey)
	if err != nil || len(publicKey) != ed25519.PublicKeySize {
		t.Fatalf("decode receipt public key: len=%d err=%v", len(publicKey), err)
	}
	if !ed25519.Verify(ed25519.PublicKey(publicKey), tuple, signature) {
		t.Fatal("first settlement receipt signature is invalid")
	}
	var payload map[string]any
	if err := json.Unmarshal(tuple, &payload); err != nil {
		t.Fatalf("decode receipt tuple JSON: %v", err)
	}
	if payload["receipt_version"] != "4" || payload["request_id"] != requestID {
		t.Fatalf("receipt tuple version/request=%v/%v, want 4/%s", payload["receipt_version"], payload["request_id"], requestID)
	}
	if payload["provider_id"] != descriptor.ProviderID || payload["model_id"] != descriptor.ModelID ||
		payload["model_hash"] != descriptor.ModelHash || payload["expected_catalog_model_hash"] != descriptor.ModelHash {
		t.Fatalf("receipt identity provider/model/hash=%v/%v/%v expected_hash=%v, want %s/%s/%s",
			payload["provider_id"], payload["model_id"], payload["model_hash"], payload["expected_catalog_model_hash"],
			descriptor.ProviderID, descriptor.ModelID, descriptor.ModelHash)
	}
	if payload["terminal_state"] != "normal_done" || intJSON(payload["terminal_state_ts_unix_ms"]) != intJSON(terminal["terminal_state_ts_unix_ms"]) {
		t.Fatalf("receipt terminal state/timestamp=%v/%v, want normal_done/%v",
			payload["terminal_state"], payload["terminal_state_ts_unix_ms"], terminal["terminal_state_ts_unix_ms"])
	}
	terminalUsage, ok := terminal["usage"].(map[string]any)
	if !ok {
		t.Fatalf("first terminal omitted usage: %v", terminal)
	}
	receiptUsage, ok := payload["usage"].(map[string]any)
	if !ok {
		t.Fatalf("receipt omitted signed usage: %v", payload)
	}
	wantPrompt := intJSON(terminalUsage["prompt_tokens"])
	wantCompletion := intJSON(terminalUsage["completion_tokens"])
	if intJSON(receiptUsage["observed_input_tokens"]) != wantPrompt ||
		intJSON(receiptUsage["billable_input_tokens"]) != wantPrompt ||
		intJSON(receiptUsage["observed_output_tokens"]) != wantCompletion ||
		intJSON(receiptUsage["billable_output_tokens"]) != wantCompletion {
		t.Fatalf("receipt usage=%v, want observed/billable input=%d output=%d from first terminal", receiptUsage, wantPrompt, wantCompletion)
	}
}

func assertDurableReplayClaim(t *testing.T, store string) {
	t.Helper()
	claims := 0
	err := filepath.WalkDir(store, func(path string, entry os.DirEntry, err error) error {
		if err != nil {
			return err
		}
		info, err := entry.Info()
		if err != nil {
			return err
		}
		if entry.IsDir() {
			if info.Mode().Perm() != 0o700 {
				return fmt.Errorf("replay directory %s mode=%#o, want 0700", path, info.Mode().Perm())
			}
			return nil
		}
		if filepath.Ext(path) == ".json" {
			claims++
			if info.Mode().Perm() != 0o600 {
				return fmt.Errorf("replay claim %s mode=%#o, want 0600", path, info.Mode().Perm())
			}
		}
		return nil
	})
	if err != nil {
		t.Fatalf("inspect durable replay store: %v", err)
	}
	if claims != 1 {
		t.Fatalf("durable replay claim count=%d, want 1", claims)
	}
}

func intJSON(value any) int {
	if number, ok := value.(float64); ok {
		return int(number)
	}
	return 0
}

func (f *swiftRelayFixture) stop() {
	f.inputMu.Lock()
	defer f.inputMu.Unlock()
	if f.stdin != nil {
		_ = f.stdin.Close()
	}
	if f.cmd != nil && f.cmd.Process != nil {
		_ = f.cmd.Process.Kill()
		_ = f.cmd.Wait()
	}
	f.cmd = nil
	f.stdin = nil
	f.stdout = nil
}

func (f *swiftRelayFixture) restartForAssignedSession(assignedSession string) {
	f.t.Helper()
	f.inputMu.Lock()
	defer f.inputMu.Unlock()
	priorIdentity := f.descriptor.IdentityPublicKey
	priorKey, err := json.Marshal(f.descriptor.KeyRecord)
	if err != nil {
		f.t.Fatal(err)
	}
	if f.stdin != nil {
		_ = f.stdin.Close()
	}
	if f.cmd != nil && f.cmd.Process != nil {
		_ = f.cmd.Process.Kill()
		_ = f.cmd.Wait()
	}
	f.start(assignedSession)
	currentKey, err := json.Marshal(f.descriptor.KeyRecord)
	if err != nil {
		f.t.Fatal(err)
	}
	if f.descriptor.AssignedSession != assignedSession {
		f.t.Fatalf("Swift relay assigned_session=%q, want coordinator assignment %q", f.descriptor.AssignedSession, assignedSession)
	}
	if f.descriptor.IdentityPublicKey != priorIdentity {
		f.t.Fatal("Swift relay fixture changed its persisted identity after assigned-session restart")
	}
	if string(currentKey) != string(priorKey) {
		var prior map[string]any
		_ = json.Unmarshal(priorKey, &prior)
		changed := make([]string, 0)
		for key, value := range prior {
			if key != "signature" && fmt.Sprint(value) != fmt.Sprint(f.descriptor.KeyRecord[key]) {
				changed = append(changed, key)
			}
		}
		if len(changed) != 0 {
			f.t.Fatalf("Swift relay fixture changed persisted key-record fields after assigned-session restart: %v", changed)
		}
	}
}

// serveFrame feeds one coordinator inference frame through the real Swift
// InferenceRelay and forwards every resulting provider frame to the WS shim.
func (f *swiftRelayFixture) serveFrame(raw []byte, send func([]byte) error) error {
	return f.serveFrameUntil(raw, send, "")
}

func (f *swiftRelayFixture) serveFrameUntil(raw []byte, send func([]byte) error, stopAfterType string) error {
	f.inputMu.Lock()
	defer f.inputMu.Unlock()
	if _, err := f.stdin.Write(append(append([]byte(nil), raw...), '\n')); err != nil {
		return err
	}
	for f.stdout.Scan() {
		line := append([]byte(nil), f.stdout.Bytes()...)
		var header struct {
			Type string `json:"type"`
		}
		if err := json.Unmarshal(line, &header); err != nil {
			return fmt.Errorf("decode Swift provider frame: %w", err)
		}
		if err := send(line); err != nil {
			return err
		}
		if header.Type == stopAfterType {
			return nil
		}
		if header.Type == "inference_response_end" || header.Type == "relay_blind_fixture_error" {
			return nil
		}
	}
	return fmt.Errorf("Swift relay fixture output closed: %v", f.stdout.Err())
}

func connectSwiftRelayProvider(t *testing.T, ctx context.Context, s *scenario, fixture *swiftRelayFixture) func() {
	return connectSwiftRelayProviderWithFault(t, ctx, s, fixture, "")
}

func connectSwiftRelayProviderWithFault(t *testing.T, ctx context.Context, s *scenario, fixture *swiftRelayFixture, fault string) func() {
	return connectSwiftRelayProviderWithFaultSignal(t, ctx, s, fixture, fault, nil)
}

func connectSwiftRelayProviderWithFaultSignal(t *testing.T, ctx context.Context, s *scenario, fixture *swiftRelayFixture, fault string, observed chan<- struct{}) func() {
	t.Helper()
	u, err := url.Parse(s.coordProvURL)
	if err != nil {
		t.Fatal(err)
	}
	header := http.Header{}
	header.Set("Authorization", "Bearer "+s.providerToken)
	dialer := gobwas.Dialer{Timeout: 5 * time.Second, Header: gobwas.HandshakeHeaderHTTP(header)}
	var conn net.Conn
	deadline := time.Now().Add(10 * time.Second)
	for time.Now().Before(deadline) {
		conn, _, _, err = dialer.Dial(ctx, "ws://"+u.Host+"/ws/provider")
		if err == nil {
			break
		}
		time.Sleep(100 * time.Millisecond)
	}
	if conn == nil {
		t.Fatalf("connect Swift relay provider: %v", err)
	}
	t.Cleanup(func() { _ = conn.Close() })
	var writeMu sync.Mutex
	send := func(raw []byte) error {
		writeMu.Lock()
		defer writeMu.Unlock()
		return wsutil.WriteClientText(conn, raw)
	}
	hello := map[string]any{
		"type":                    "hello",
		"version":                 1,
		"tier":                    1,
		"provider_id":             s.providerID,
		"hostname":                "swift-relay-fixture",
		"model_id":                defaultFakeModelID,
		"model_params_b":          3.0,
		"ram_gb":                  16,
		"max_context_tokens":      8192,
		"max_concurrency":         1,
		"throughput_tps_estimate": 20.0,
		"binary_version":          "relay-blind-local-fixture",
		"attestation":             nil,
		"relay_blind_key_records": []any{fixture.descriptor.KeyRecord},
	}
	rawHello, _ := json.Marshal(hello)
	if err := send(rawHello); err != nil {
		t.Fatalf("send Swift provider hello: %v", err)
	}
	ackRaw, _, err := wsutil.ReadServerData(conn)
	if err != nil {
		t.Fatalf("read Swift provider hello ack: %v", err)
	}
	var ack struct {
		AssignedID string `json:"assigned_id"`
	}
	if err := json.Unmarshal(ackRaw, &ack); err != nil || ack.AssignedID == "" {
		t.Fatalf("decode Swift provider hello ack: %v: %s", err, ackRaw)
	}
	fixture.restartForAssignedSession(ack.AssignedID)
	ready := readyStateUpdate(defaultFakeModelID, "")
	ready["relay_blind_key_records"] = []any{fixture.descriptor.KeyRecord}
	rawReady, _ := json.Marshal(ready)
	if err := send(rawReady); err != nil {
		t.Fatalf("send Swift provider ready: %v", err)
	}

	go func() {
		for {
			raw, _, err := wsutil.ReadServerData(conn)
			if err != nil {
				return
			}
			var header struct {
				Type string `json:"type"`
			}
			if json.Unmarshal(raw, &header) != nil || header.Type != "inference_request" {
				continue
			}
			if fault == "disconnect_before_dispatch" {
				_ = conn.Close()
				return
			}
			stopAfter := ""
			if fault == "disconnect_after_first_chunk" || fault == "buyer_cancel_after_first_chunk" || fault == "process_crash_after_first_chunk" {
				stopAfter = "inference_response_chunk"
			}
			if err := fixture.serveFrameUntil(raw, send, stopAfter); err != nil && ctx.Err() == nil {
				t.Errorf("Swift relay fixture dispatch: %v", err)
				return
			}
			if stopAfter != "" {
				if fault == "process_crash_after_first_chunk" {
					fixture.restartForAssignedSession(ack.AssignedID)
					var replayFrames [][]byte
					replayErr := fixture.serveFrame(raw, func(frame []byte) error {
						replayFrames = append(replayFrames, append([]byte(nil), frame...))
						return nil
					})
					if replayErr == nil {
						replayErr = validateSwiftCrashReplay(replayFrames)
					}
					if fixture.crashReplayResult != nil {
						fixture.crashReplayResult <- replayErr
					}
					_ = conn.Close()
					return
				}
				if observed != nil {
					close(observed)
				}
				if fault == "buyer_cancel_after_first_chunk" {
					return
				}
				_ = conn.Close()
				return
			}
		}
	}()
	go func() {
		ticker := time.NewTicker(time.Second)
		defer ticker.Stop()
		for {
			select {
			case <-ctx.Done():
				return
			case <-ticker.C:
				hb := map[string]any{
					"type": "heartbeat", "status": "ready", "model_id": defaultFakeModelID,
					"model_params_b": 3.0, "ram_gb": 16, "max_context_tokens": 8192,
					"max_concurrency": 1, "slots_free": 1, "slots_total": 1,
					"throughput_tps_estimate": 20.0, "requests_served_since_last": 0,
					"avg_latency_ms_since_last": 0.0, "throughput_tps_since_last": 0.0,
					"relay_blind_key_records": []any{fixture.descriptor.KeyRecord},
				}
				raw, _ := json.Marshal(hb)
				if send(raw) != nil {
					return
				}
			}
		}
	}()
	return func() { _ = conn.Close() }
}

func validateSwiftCrashReplay(frames [][]byte) error {
	if len(frames) == 0 {
		return fmt.Errorf("replayed crashed envelope emitted no provider frame")
	}
	foundReplay := false
	for _, raw := range frames {
		var frame struct {
			Type   string `json:"type"`
			Status string `json:"status"`
			Code   string `json:"code"`
		}
		if err := json.Unmarshal(raw, &frame); err != nil {
			return fmt.Errorf("decode replay frame: %w", err)
		}
		if frame.Type == "inference_response_chunk" {
			return fmt.Errorf("replayed crashed envelope generated a second output chunk")
		}
		if frame.Status == "relay_blind_replay" || frame.Code == "relay_blind_replay" {
			foundReplay = true
		}
	}
	if !foundReplay {
		return fmt.Errorf("replayed crashed envelope lacked relay_blind_replay terminal: %s", frames[len(frames)-1])
	}
	return nil
}
