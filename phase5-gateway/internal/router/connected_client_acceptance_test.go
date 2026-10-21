package router

import (
	"bytes"
	"context"
	"crypto/rand"
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"fmt"
	"io"
	"net/http"
	"net/http/httptest"
	"os"
	"os/exec"
	"path/filepath"
	"runtime"
	"strings"
	"sync"
	"syscall"
	"testing"
	"time"

	"github.com/augstar/macprovider-gateway/internal/config"
)

// This opt-in hardware acceptance uses a real client, gateway handler, and
// isolated provider. Its fixture accounting does not establish live billing or
// coordinator routing. The provider owner must make the qualified model ready
// before setting these variables; this test never starts or replaces a provider.
func TestConnectedCodexClientAcceptance(t *testing.T) {
	runConnectedClientAcceptance(t, "codex", "CODEX", "codex-cli 0.163.0", false)
}

func TestConnectedOpenCodeClientAcceptance(t *testing.T) {
	runConnectedClientAcceptance(t, "opencode", "OPENCODE", "1.17.9", false)
}

func TestConnectedGooseClientAcceptance(t *testing.T) {
	runConnectedClientAcceptance(t, "goose", "GOOSE", "1.45.0", false)
}

// Protocol fixtures isolate native client/gateway interoperability from model
// automatic tool selection. They never contact the isolated provider.
func TestConnectedOpenCodeClientProtocol(t *testing.T) {
	runConnectedClientAcceptance(t, "opencode", "OPENCODE", "1.17.9", true)
}

func TestConnectedGooseClientProtocol(t *testing.T) {
	runConnectedClientAcceptance(t, "goose", "GOOSE", "1.45.0", true)
}

func runConnectedClientAcceptance(t *testing.T, kind, envPrefix, expectedVersion string, synthetic bool) {
	task, err := connectedClientTask(os.Getenv("MACPROVIDER_TEST_OPENCODE_TASK"), kind, synthetic)
	if err != nil {
		t.Fatal(err)
	}
	directAnswer := task == "direct-answer"
	binary, upstream := os.Getenv("MACPROVIDER_TEST_"+envPrefix+"_BIN"), os.Getenv("MACPROVIDER_TEST_"+envPrefix+"_UPSTREAM")
	if binary == "" || (!synthetic && upstream == "") || (synthetic && os.Getenv("MACPROVIDER_TEST_"+envPrefix+"_PROTOCOL") != "1") {
		t.Skip("requires explicit client binary and isolated Studio provider URL")
	}
	if (!synthetic && upstream != "http://127.0.0.1:18055") || !filepath.IsAbs(binary) {
		t.Fatal("acceptance requires an absolute client path and the isolated provider on loopback18055")
	}
	if runtime.GOOS != "darwin" {
		t.Fatal("hardware acceptance requires the designated Mac Studio")
	}
	expectedHost := os.Getenv("MACPROVIDER_TEST_STUDIO_HOST")
	if expectedHost == "" {
		t.Fatal("opt-in acceptance requires the designated Studio hostname")
	}
	for command, want := range map[string]string{"/usr/sbin/sysctl": "Mac15,14", "/bin/hostname": expectedHost} {
		args := []string{}
		if strings.HasSuffix(command, "sysctl") {
			args = []string{"-n", "hw.model"}
		}
		got, err := exec.Command(command, args...).Output()
		if err != nil || strings.TrimSpace(string(got)) != want {
			t.Fatalf("execution host verification failed: %s", command)
		}
	}
	privateTrace, err := newConnectedClientPrivateTrace(os.Getenv("MACPROVIDER_TEST_OPENCODE_PRIVATE_TRACE_DIR"), os.Getenv("MACPROVIDER_TEST_OPENCODE_TRACE_TOOL_TURN"), kind, synthetic, upstream, true)
	if err != nil {
		t.Fatal(err)
	}

	model, err := connectedClientModel(os.Getenv("MACPROVIDER_TEST_CLIENT_MODEL"), synthetic)
	if err != nil {
		t.Fatal(err)
	}
	contextTokens, err := connectedClientContext(os.Getenv("MACPROVIDER_TEST_CLIENT_CONTEXT"), synthetic)
	if err != nil {
		t.Fatal(err)
	}
	if !synthetic {
		statusTransport := &http.Transport{Proxy: nil}
		defer statusTransport.CloseIdleConnections()
		statusClient := &http.Client{Transport: statusTransport, Timeout: 5 * time.Second, CheckRedirect: func(*http.Request, []*http.Request) error { return http.ErrUseLastResponse }}
		response, err := statusClient.Get(upstream + "/v1/status")
		if err != nil {
			t.Fatal("isolated provider status unavailable")
		}
		statusBody, readErr := io.ReadAll(io.LimitReader(response.Body, (1<<20)+1))
		response.Body.Close()
		if readErr != nil || len(statusBody) > 1<<20 || response.StatusCode != http.StatusOK || !connectedProviderMatches(statusBody, model, contextTokens) {
			t.Fatal("isolated provider model/context does not match the explicit fixture setting")
		}
	}
	root, err := filepath.EvalSymlinks(t.TempDir())
	if err != nil {
		t.Fatal(err)
	}
	// Native clients resolve cwd physically; use the same path for tool permissions.

	for _, name := range []string{"home", "codex-home", "xdg-config", "xdg-data", "xdg-cache", "tmp", "workspace"} {
		if err := os.Mkdir(filepath.Join(root, name), 0700); err != nil {
			t.Fatal(err)
		}
	}
	var random [16]byte
	if _, err := rand.Read(random[:]); err != nil {
		t.Fatal(err)
	}
	marker := "malibu-" + hex.EncodeToString(random[:])
	write := func(path string, data []byte) {
		t.Helper()
		if err := os.WriteFile(path, data, 0600); err != nil {
			t.Fatal(err)
		}
	}
	write(filepath.Join(root, "workspace", "marker.txt"), []byte(marker+"\n"))

	ctx, cancel := context.WithTimeout(context.Background(), 150*time.Second)
	defer cancel()
	var mu sync.Mutex
	calls, inbound, streamed, matchedResult := 0, 0, false, false
	offeredTools := false
	var clientPrompt string
	transport := &http.Transport{Proxy: nil, ResponseHeaderTimeout: 90 * time.Second}
	defer transport.CloseIdleConnections()
	client := &http.Client{Transport: roundTripFunc(func(r *http.Request) (*http.Response, error) {
		if r.Method != http.MethodPost || r.URL.Path != "/v1/chat/completions" {
			return nil, fmt.Errorf("unexpected fixture upstream path %s", r.URL.Path)
		}
		body, err := io.ReadAll(io.LimitReader(r.Body, connectedClientTraceRequestMax+1))
		if err != nil {
			return nil, err
		}
		if len(body) > connectedClientTraceRequestMax {
			return nil, fmt.Errorf("fixture request exceeded four MiB")
		}
		var payload struct {
			Model             string          `json:"model"`
			Stream            bool            `json:"stream"`
			ToolChoice        json.RawMessage `json:"tool_choice"`
			Temperature       *float64        `json:"temperature"`
			TopP              *float64        `json:"top_p"`
			TopK              *int            `json:"top_k"`
			RepetitionPenalty json.RawMessage `json:"repetition_penalty"`
			Messages          []struct {
				Role       string          `json:"role"`
				Content    json.RawMessage `json:"content"`
				ToolCallID string          `json:"tool_call_id"`
				ToolCalls  []struct {
					ID string `json:"id"`
				} `json:"tool_calls"`
			} `json:"messages"`
			Tools []json.RawMessage `json:"tools"`
		}
		if err := json.Unmarshal(body, &payload); err != nil {
			return nil, err
		}
		if payload.Model != model || !payload.Stream || r.Header.Get("X-MacProvider-Account") != "connected-fixture" || r.Header.Get(routingGitHubIDsHeader) != "none" {
			cancel()
			return nil, fmt.Errorf("unexpected model, streaming mode, or authenticated fixture identity")
		}
		if kind == "opencode" && len(payload.Tools) != 0 && !connectedAutomaticChoice(payload.ToolChoice) {
			cancel()
			return nil, fmt.Errorf("OpenCode acceptance requires unchanged automatic tool choice")
		}
		if kind == "opencode" && len(payload.Tools) != 0 {
			matchedPrompt := false
			matchedPlugin := os.Getenv("MACPROVIDER_TEST_OPENCODE_AGENT_PROFILE") != "qwen-plugin"
			for _, message := range payload.Messages {
				var content string
				if json.Unmarshal(message.Content, &content) != nil {
					continue
				}
				if message.Role == "user" && content == clientPrompt {
					matchedPrompt = true
				}
				if message.Role == "system" && connectedQwenPluginPrompt(content, model) {
					matchedPlugin = true
				}
			}
			if !matchedPrompt {
				cancel()
				return nil, fmt.Errorf("OpenCode changed the literal user task before inference")
			}
			if !matchedPlugin {
				cancel()
				return nil, fmt.Errorf("managed Qwen plugin did not transform the stock request")
			}
		}
		if kind == "opencode" && len(payload.Tools) != 0 && os.Getenv("MACPROVIDER_TEST_OPENCODE_AGENT_PROFILE") != "" {
			wantsPenalty := model == "mlx-community/Qwen3-Coder-30B-A3B-Instruct-4bit"
			var penalty float64
			validPenalty := len(payload.RepetitionPenalty) == 0
			if wantsPenalty {
				validPenalty = json.Unmarshal(payload.RepetitionPenalty, &penalty) == nil && penalty == 1.05
			}
			if payload.Temperature == nil || *payload.Temperature != 0.7 || payload.TopP == nil || *payload.TopP != 0.8 || payload.TopK == nil || *payload.TopK != 20 || !validPenalty {
				cancel()
				return nil, fmt.Errorf("Qwen candidate sampling did not reach the unchanged wire request")
			}
		}
		traceToken, err := privateTrace.captureRequest(body, len(payload.Tools) != 0)
		if err != nil {
			cancel()
			return nil, err
		}
		mu.Lock()
		calls++
		callNumber := calls
		tooMany := calls > 6
		streamed = true
		offeredTools = offeredTools || len(payload.Tools) != 0
		ids := make(map[string]bool)
		for _, message := range payload.Messages {
			for _, call := range message.ToolCalls {
				ids[call.ID] = true
			}
			if message.Role == "tool" && ids[message.ToolCallID] && strings.Contains(string(message.Content), marker) {
				matchedResult = true
			}
		}
		mu.Unlock()
		if tooMany {
			cancel()
			return nil, fmt.Errorf("client exceeded six inference requests")
		}
		t.Logf("upstream request %d shape: %s", callNumber, connectedRequestShape(body))
		if synthetic {
			held, err := connectedSyntheticToolResponse(body, kind, filepath.Join(root, "workspace"), marker)
			if err != nil {
				cancel()
				return nil, err
			}
			if err := validateConnectedToolStream(held, kind, filepath.Join(root, "workspace")); err != nil {
				cancel()
				return nil, err
			}
			return responseWithBody(http.StatusOK, http.Header{"Content-Type": []string{"text/event-stream"}}, string(held)), nil
		}
		// Preserve the gateway-produced body; only the destination and fixture
		// service headers differ from the normal coordinator transport.
		forward, err := http.NewRequestWithContext(r.Context(), http.MethodPost, upstream+"/v1/chat/completions", bytes.NewReader(body))
		if err != nil {
			return nil, err
		}
		forward.Header.Set("Content-Type", "application/json")
		response, err := transport.RoundTrip(forward)
		if err != nil {
			return nil, err
		}
		defer response.Body.Close()
		held, err := io.ReadAll(io.LimitReader(response.Body, (1<<20)+1))
		if err == nil {
			if err := privateTrace.captureResponse(held, traceToken); err != nil {
				cancel()
				return nil, err
			}
		}
		if err != nil || len(held) > 1<<20 || response.StatusCode != http.StatusOK {
			t.Logf("upstream fixture rejected: status=%d size=%d read_error=%t", response.StatusCode, len(held), err != nil)
			cancel()
			return nil, fmt.Errorf("fixture rejected upstream status, size, or incomplete read")
		}
		guardKind := kind
		if directAnswer {
			// The existing guard rejects every tool name for an unknown kind,
			// before any model bytes reach the client or execute a tool.
			guardKind = "direct-answer"
		}
		t.Logf("upstream response %d usage: %s", callNumber, connectedStreamUsage(held))
		if err := validateConnectedToolStream(held, guardKind, filepath.Join(root, "workspace")); err != nil {
			t.Logf("tool guard: %v", err)
			cancel()
			return nil, err
		}
		// Hold all model bytes until every complete tool call is validated. This
		// verifies SSE protocol compatibility, not time-to-first-token latency.
		response.Body = io.NopCloser(bytes.NewReader(held))
		return response, nil
	})}
	h, store, _, cfg := newTestHarnessConfig(t, fakeOAuth{}, func(cfg *config.Config) {
		enableResponsesWithCoordinator(cfg)
		cfg.Limits.MaxTokensPerRequest = 1024
	}, WithHTTPClient(client), WithNow(time.Now))
	key := createAccountAndKey(t, store, cfg, "connected-fixture")
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if r.Method == http.MethodPost && (r.URL.Path == "/v1/chat/completions" || r.URL.Path == "/v1/responses") {
			mu.Lock()
			inbound++
			tooMany := inbound > 12
			mu.Unlock()
			if tooMany {
				cancel()
				http.Error(w, "fixture request limit", http.StatusTooManyRequests)
				return
			}
			body, err := io.ReadAll(io.LimitReader(r.Body, 4<<20))
			if err != nil {
				http.Error(w, "fixture request read failed", http.StatusBadRequest)
				return
			}
			r.Body = io.NopCloser(bytes.NewReader(body))
			var shape struct {
				MaxTokens           int64 `json:"max_tokens"`
				MaxCompletionTokens int64 `json:"max_completion_tokens"`
				MaxOutputTokens     int64 `json:"max_output_tokens"`
			}
			if json.Unmarshal(body, &shape) == nil {
				t.Logf("client request budget: max_tokens=%d max_completion_tokens=%d max_output_tokens=%d", shape.MaxTokens, shape.MaxCompletionTokens, shape.MaxOutputTokens)
			}
		}
		h.ServeHTTP(w, r)
	}))
	defer server.Close()

	// Mirrors ConnectedAppConfiguration's conservative Codex0.163.0 catalog;
	// every context field matches the verified isolated provider capacity.
	catalog, err := json.Marshal(map[string]any{"models": []any{map[string]any{
		"slug": model, "display_name": model,
		"description":                "Isolated gateway acceptance fixture",
		"model_messages":             map[string]any{"instructions_template": "You are a coding assistant. Use the available tools to complete the user's request and verify your work."},
		"supported_reasoning_levels": []any{}, "shell_type": "unified_exec", "visibility": "list",
		"supported_in_api": true, "priority": 1, "support_verbosity": false,
		"truncation_policy":            map[string]any{"mode": "tokens", "limit": min(10000, contextTokens)},
		"experimental_supported_tools": []any{}, "input_modalities": []string{"text"},
		"context_window": contextTokens, "max_context_window": contextTokens, "upgrade": nil, "apply_patch_tool_type": nil,
		"supports_reasoning_summary_parameter": false, "tool_mode": "direct", "node_repl_disabled": true, "use_responses_lite": false,
	}}})
	if err != nil {
		t.Fatal(err)
	}
	catalogPath := filepath.Join(root, "codex-home", "malibu-models.json")
	write(catalogPath, catalog)
	write(filepath.Join(root, "codex-home", "config.toml"), []byte(fmt.Sprintf(`model = %q
model_provider = "malibu"
model_catalog_json = %q
[model_providers.malibu]
name = "Malibu"
base_url = %q
wire_api = "responses"
env_key = "MALIBU_API_KEY"
`, model, catalogPath, server.URL+"/v1")))
	env := []string{"PATH=/usr/bin:/bin:/usr/sbin:/sbin", "HOME=" + filepath.Join(root, "home"), "CODEX_HOME=" + filepath.Join(root, "codex-home"),
		"XDG_CONFIG_HOME=" + filepath.Join(root, "xdg-config"), "XDG_DATA_HOME=" + filepath.Join(root, "xdg-data"),
		"XDG_CACHE_HOME=" + filepath.Join(root, "xdg-cache"), "TMPDIR=" + filepath.Join(root, "tmp"), "MALIBU_API_KEY=" + key}
	version := exec.CommandContext(ctx, binary, "--version")
	version.Env = env
	version.Dir = filepath.Join(root, "workspace")
	gotVersion, err := version.Output()
	if err != nil || strings.TrimSpace(string(gotVersion)) != expectedVersion {
		t.Fatalf("acceptance requires %s", expectedVersion)
	}
	finalPath := filepath.Join(root, "final.txt")
	prompt := connectedClientTaskPrompt(kind, task, filepath.Join(root, "workspace", "marker.txt"))
	clientPrompt = prompt
	var args []string
	switch kind {
	case "codex":
		args = []string{"exec", "--skip-git-repo-check", "--ephemeral", "--json", "--sandbox", "read-only",
			"--cd", filepath.Join(root, "workspace"), "--output-last-message", finalPath,
			"-c", `approval_policy="never"`, "-c", `web_search="disabled"`, prompt}
	case "opencode":
		configPath := filepath.Join(root, "opencode.json")
		configuration := map[string]any{"model": "malibu/" + model, "provider": map[string]any{
			"malibu": map[string]any{"npm": "@ai-sdk/openai-compatible", "name": "Malibu",
				"options": map[string]any{"baseURL": server.URL + "/v1", "apiKey": "{env:MALIBU_API_KEY}"},
				"models":  map[string]any{model: map[string]any{"name": model, "limit": map[string]any{"context": contextTokens, "output": 1024}}}},
		}}
		if err := connectedOpenCodeAgentProfile(configuration, os.Getenv("MACPROVIDER_TEST_OPENCODE_AGENT_PROFILE"), model); err != nil {
			t.Fatal(err)
		}
		data, err := json.Marshal(configuration)
		if err != nil {
			t.Fatal(err)
		}
		write(configPath, data)
		env = append(env, "OPENCODE_CONFIG="+configPath)
		args = []string{"run", "--pure", "--format", "json", "--model", "malibu/" + model, "--dir", filepath.Join(root, "workspace")}
		if os.Getenv("MACPROVIDER_TEST_OPENCODE_AGENT_PROFILE") == "qwen-plugin" {
			// --pure disables explicit config plugins too. The fresh private
			// config/home contains only our managed asset; project config stays off.
			args = append([]string{"run"}, args[2:]...)
		}
	case "goose":
		providerDir := filepath.Join(root, "xdg-config", "goose", "custom_providers")
		if err := os.MkdirAll(providerDir, 0700); err != nil {
			t.Fatal(err)
		}
		data, err := json.Marshal(map[string]any{"name": "malibu", "engine": "openai", "display_name": "Malibu", "description": "Isolated gateway acceptance fixture",
			"api_key_env": "MALIBU_API_KEY", "base_url": server.URL + "/v1/chat/completions", "requires_auth": true, "supports_streaming": true,
			"models": []any{map[string]any{"name": model, "context_limit": contextTokens}}})
		if err != nil {
			t.Fatal(err)
		}
		write(filepath.Join(providerDir, "malibu.json"), data)
		args = []string{"run", "--no-profile", "--no-session", "--max-turns", "3", "--with-builtin", "developer", "--provider", "malibu", "--model", model, "--output-format", "stream-json", "--text", prompt}
	}
	cmd := exec.CommandContext(ctx, binary, args...)
	cmd.Env, cmd.Dir = env, filepath.Join(root, "workspace")
	if kind == "opencode" {
		// v1.17.9 quotes positional arguments containing spaces. Stdin preserves
		// the user's task literally, matching interactive input.
		cmd.Stdin = strings.NewReader(prompt)
	}
	cmd.SysProcAttr = &syscall.SysProcAttr{Setpgid: true}
	cmd.Cancel = func() error { return syscall.Kill(-cmd.Process.Pid, syscall.SIGKILL) }
	cmd.WaitDelay = 5 * time.Second
	output := &connectedClientOutput{}
	cmd.Stdout, cmd.Stderr = output, output
	if err := cmd.Run(); err != nil {
		t.Fatalf("isolated %s failed: %v; %s", kind, err, connectedClientSummary(kind, output.String(), marker))
	}
	var final []byte
	if kind == "codex" {
		final, err = os.ReadFile(finalPath)
	} else {
		final = []byte(connectedClientFinalText(kind, output.String()))
	}
	expectedFinal := marker
	if directAnswer {
		expectedFinal = "4"
	}
	if err != nil || strings.TrimSpace(string(final)) != expectedFinal {
		t.Fatalf("%s did not return the exact expected answer: %v; %s", kind, err, connectedClientSummary(kind, output.String(), marker))
	}
	mu.Lock()
	defer mu.Unlock()
	if directAnswer {
		if calls < 1 || !streamed || matchedResult || !offeredTools {
			t.Fatal("missing tool-free streamed answer")
		}
		t.Log("real OpenCode returned the exact direct answer without executing tools")
		return
	}
	if calls < 2 || !streamed || !matchedResult {
		t.Fatalf("missing real streaming tool round trip: requests=%d streamed=%v matched_result=%v", calls, streamed, matchedResult)
	}
	t.Logf("%s completed streaming and a matching file-tool result through the gateway (synthetic=%v upstream_requests=%d)", expectedVersion, synthetic, calls)
}

func connectedClientTask(raw, kind string, synthetic bool) (string, error) {
	if raw == "" {
		return "read", nil
	}
	if kind != "opencode" || synthetic {
		return "", fmt.Errorf("task controls require actual OpenCode model acceptance")
	}
	switch raw {
	case "read", "read-natural", "direct-answer":
		return raw, nil
	default:
		return "", fmt.Errorf("OpenCode task must be read, read-natural or direct-answer")
	}
}

// This diagnostic changes only the user wording. Both read tasks keep the same
// exact marker answer, actual tool/result matching, permissions and tool guard.
func connectedClientTaskPrompt(kind, task, markerPath string) string {
	if task == "direct-answer" {
		return "What is 2 + 2? Answer with just the number."
	}
	if task == "read-natural" {
		return "What does the file " + markerPath + " contain? After reading it, reply with only its contents."
	}
	if kind == "opencode" {
		return "Read only " + markerPath + " using the read tool. Do not inspect any other file, execute a shell command, or use the network. Reply with exactly its contents and nothing else."
	}
	if kind == "goose" {
		return "Use shell with exactly command=cat marker.txt to read the current workspace marker. Do not inspect any other file or use the network. Reply with exactly its contents and nothing else."
	}
	return "Use exec_command with exactly cmd=cat marker.txt to read the current workspace marker. Do not inspect any other file or use the network. Reply with exactly its contents and nothing else."
}

func TestConnectedClientTaskSelection(t *testing.T) {
	for _, kind := range []string{"opencode", "codex", "goose"} {
		for _, synthetic := range []bool{false, true} {
			if task, err := connectedClientTask("", kind, synthetic); err != nil || task != "read" {
				t.Fatal("default read task changed")
			}
			for _, raw := range []string{"read", "read-natural", "direct-answer"} {
				task, err := connectedClientTask(raw, kind, synthetic)
				allowed := kind == "opencode" && !synthetic
				if allowed && (err != nil || task != raw) || !allowed && (err == nil || task != "") {
					t.Fatal("task control escaped actual OpenCode scope or rejected a valid task")
				}
			}
		}
	}
	for _, raw := range []string{"natural", "READ", "read-natural ", " read-natural", "read-natural\n", "read-other"} {
		if task, err := connectedClientTask(raw, "opencode", false); err == nil || task != "" {
			t.Fatal("accepted a task outside the exact enum")
		}
	}
}

func TestConnectedClientTaskPrompts(t *testing.T) {
	const markerPath = "/private/fixture/workspace/marker.txt"
	for _, tc := range []struct{ kind, task, want string }{
		{"opencode", "read-natural", "What does the file /private/fixture/workspace/marker.txt contain? After reading it, reply with only its contents."},
		{"opencode", "read", "Read only /private/fixture/workspace/marker.txt using the read tool. Do not inspect any other file, execute a shell command, or use the network. Reply with exactly its contents and nothing else."},
		{"opencode", "direct-answer", "What is 2 + 2? Answer with just the number."},
		{"codex", "read", "Use exec_command with exactly cmd=cat marker.txt to read the current workspace marker. Do not inspect any other file or use the network. Reply with exactly its contents and nothing else."},
		{"goose", "read", "Use shell with exactly command=cat marker.txt to read the current workspace marker. Do not inspect any other file or use the network. Reply with exactly its contents and nothing else."},
	} {
		if got := connectedClientTaskPrompt(tc.kind, tc.task, markerPath); got != tc.want {
			t.Fatal("diagnostic task prompt changed")
		}
	}
}

// Keep client diagnostics bounded even if a client loops or emits verbose logs.
type connectedClientOutput struct {
	mu sync.Mutex
	b  bytes.Buffer
}

func (o *connectedClientOutput) Write(p []byte) (int, error) {
	o.mu.Lock()
	defer o.mu.Unlock()
	n := len(p)
	remaining := (64 << 10) - o.b.Len()
	if remaining > 0 {
		o.b.Write(p[:min(n, remaining)])
	}
	return n, nil
}

func (o *connectedClientOutput) String() string {
	o.mu.Lock()
	defer o.mu.Unlock()
	return o.b.String()
}

// Extract assistant text only; a marker printed in a tool result is not a final answer.
func connectedClientFinalText(kind, output string) string {
	final := ""
	for _, line := range strings.Split(output, "\n") {
		var event map[string]json.RawMessage
		if json.Unmarshal([]byte(line), &event) != nil {
			continue
		}
		if kind == "opencode" {
			var typ string
			_ = json.Unmarshal(event["type"], &typ)
			if typ != "text" {
				continue
			}
			var part struct {
				Text string `json:"text"`
			}
			if json.Unmarshal(event["part"], &part) == nil {
				final = part.Text
			}
		} else {
			var message struct {
				Role    string `json:"role"`
				Content []struct {
					Type string `json:"type"`
					Text string `json:"text"`
				} `json:"content"`
			}
			if json.Unmarshal(event["message"], &message) != nil {
				continue
			}
			if message.Role != "assistant" {
				final = ""
				continue
			}
			for _, content := range message.Content {
				if content.Type == "text" {
					final += content.Text
				} else {
					final = ""
				}
			}
		}
	}
	return strings.TrimSpace(final)
}

// Validate the complete response before releasing even the first tool delta to
// a client. Only one literal marker read is permitted; no generic shell parser.
func validateConnectedToolStream(body []byte, kind, workspace string) error {
	reject := func(code string) error { return fmt.Errorf("fixture rejected model tool stream at %s", code) }
	done, finished, hasCall := false, false, false
	name, arguments, id := "", "", ""
	for _, line := range strings.Split(strings.ReplaceAll(string(body), "\r\n", "\n"), "\n") {
		if line == "" || strings.HasPrefix(line, ":") {
			continue
		}
		if !strings.HasPrefix(line, "data:") || done {
			return reject("check01")
		}
		data := strings.TrimSpace(strings.TrimPrefix(line, "data:"))
		if data == "[DONE]" {
			done = true
			continue
		}
		if !json.Valid([]byte(data)) || anthropicRawHasDuplicateKeys([]byte(data)) {
			return reject("check02")
		}
		var chunk struct {
			Error   json.RawMessage `json:"error"`
			Choices []struct {
				Index        int             `json:"index"`
				Message      json.RawMessage `json:"message"`
				FinishReason *string         `json:"finish_reason"`
				Delta        struct {
					FunctionCall json.RawMessage `json:"function_call"`
					ToolCalls    []struct {
						Index    int    `json:"index"`
						ID       string `json:"id"`
						Type     string `json:"type"`
						Function struct {
							Name      string `json:"name"`
							Arguments string `json:"arguments"`
						} `json:"function"`
					} `json:"tool_calls"`
				} `json:"delta"`
			} `json:"choices"`
		}
		if json.Unmarshal([]byte(data), &chunk) != nil || len(chunk.Error) != 0 || len(chunk.Choices) > 1 {
			return reject("check03")
		}
		for _, choice := range chunk.Choices {
			if finished || choice.Index != 0 || len(choice.Message) != 0 || len(choice.Delta.FunctionCall) != 0 || len(choice.Delta.ToolCalls) > 1 {
				return reject("check04")
			}
			for _, call := range choice.Delta.ToolCalls {
				if call.Index != 0 || (call.Type != "" && call.Type != "function") {
					return reject("check05")
				}
				if call.ID != "" {
					if id != "" {
						return reject("check06")
					}
					id = call.ID
				}
				hasCall = true
				name += call.Function.Name
				arguments += call.Function.Arguments
			}
			if choice.FinishReason != nil {
				if (hasCall && *choice.FinishReason != "tool_calls") || (!hasCall && *choice.FinishReason != "stop") {
					return reject("check07")
				}
				finished = true
			}
		}
	}
	if !done || !finished {
		return reject("check08")
	}
	if !hasCall {
		return nil
	}
	if id == "" || !json.Valid([]byte(arguments)) || anthropicRawHasDuplicateKeys([]byte(arguments)) {
		return reject("check09")
	}
	var args map[string]json.RawMessage
	if json.Unmarshal([]byte(arguments), &args) != nil || args == nil {
		return reject("check10")
	}
	stringArg := func(key string) string { var value string; _ = json.Unmarshal(args[key], &value); return value }
	numericArg := func(key string, max int) bool {
		if _, ok := args[key]; !ok {
			return true
		}
		var value int
		return json.Unmarshal(args[key], &value) == nil && value >= 0 && value <= max
	}
	allowed := map[string]bool{}
	switch kind {
	case "codex":
		if name != "exec_command" && name != "functions.exec_command" {
			return reject("check11")
		}
		command := stringArg("cmd")
		if command != "cat marker.txt" && command != "cat ./marker.txt" && command != "/bin/cat marker.txt" && command != "/bin/cat ./marker.txt" {
			return reject("check12")
		}
		if _, ok := args["workdir"]; ok && stringArg("workdir") != workspace {
			return reject("check13")
		}
		if !numericArg("yield_time_ms", 10000) || !numericArg("max_output_tokens", 4096) {
			return reject("check14")
		}
		allowed = map[string]bool{"cmd": true, "workdir": true, "yield_time_ms": true, "max_output_tokens": true}
	case "opencode":
		if name != "read" || stringArg("filePath") != filepath.Join(workspace, "marker.txt") || !numericArg("offset", 1) || !numericArg("limit", 100) {
			return reject("check15")
		}
		allowed = map[string]bool{"filePath": true, "offset": true, "limit": true}
	case "goose":
		command := stringArg("command")
		if name != "shell" || (command != "cat marker.txt" && command != "cat ./marker.txt" && command != "/bin/cat marker.txt" && command != "/bin/cat ./marker.txt") || !numericArg("timeout_secs", 10) {
			return reject("check16")
		}
		allowed = map[string]bool{"command": true, "timeout_secs": true}
	default:
		return reject("check17")
	}
	for key := range args {
		if !allowed[key] {
			return reject("check18")
		}
	}
	return nil
}

func TestConnectedClientToolGuard(t *testing.T) {
	workspace := "/fixture/workspace"
	stream := func(name, arguments string) []byte {
		first, _ := json.Marshal(map[string]any{"choices": []any{map[string]any{"index": 0, "delta": map[string]any{"tool_calls": []any{map[string]any{"index": 0, "id": "call_fixture", "type": "function", "function": map[string]any{"name": name, "arguments": arguments}}}}}}})
		return []byte("data: " + string(first) + "\n\ndata: {\"choices\":[{\"index\":0,\"delta\":{},\"finish_reason\":\"tool_calls\"}]}\n\ndata: [DONE]\n\n")
	}
	for _, tc := range []struct {
		name, kind, tool, args string
		valid                  bool
	}{
		{"literal shell", "codex", "exec_command", `{"cmd":"cat marker.txt"}`, true},
		{"outside shell path", "codex", "exec_command", `{"cmd":"cat /private/secret"}`, false},
		{"shell operator", "codex", "exec_command", `{"cmd":"cat marker.txt; env"}`, false},
		{"extra key", "codex", "exec_command", `{"cmd":"cat marker.txt","shell":"/bad"}`, false},
		{"outside cwd", "codex", "exec_command", `{"cmd":"cat marker.txt","workdir":"/private"}`, false},
		{"duplicate key", "codex", "exec_command", `{"cmd":"cat marker.txt","cmd":"env"}`, false},
		{"unknown tool", "codex", "other", `{"cmd":"cat marker.txt"}`, false},
		{"read", "opencode", "read", `{"filePath":"/fixture/workspace/marker.txt"}`, true},
		{"outside read", "opencode", "read", `{"filePath":"/private/secret"}`, false},
		{"direct answer must not call", "direct-answer", "read", `{"filePath":"/fixture/workspace/marker.txt"}`, false},
		{"goose-read", "goose", "shell", `{"command":"cat marker.txt","timeout_secs":5}`, true},
		{"goose-outside", "goose", "shell", `{"command":"cat /etc/passwd"}`, false},
		{"goose-metacharacters", "goose", "shell", `{"command":"cat marker.txt;env"}`, false},
		{"goose-cwd", "goose", "shell", `{"command":"cat marker.txt","workdir":"/tmp"}`, false},
		{"goose-timeout", "goose", "shell", `{"command":"cat marker.txt","timeout_secs":11}`, false},
		{"edit", "goose", "developer__text_editor", `{"command":"create","path":"/fixture/workspace/marker.txt"}`, false},
	} {
		t.Run(tc.name, func(t *testing.T) {
			if got := validateConnectedToolStream(stream(tc.tool, tc.args), tc.kind, workspace); (got == nil) != tc.valid {
				t.Fatalf("guard valid=%v error=%v", tc.valid, got)
			}
		})
	}
	valid := stream("exec_command", `{"cmd":"cat marker.txt"}`)
	if err := validateConnectedToolStream(append([]byte(": macprovider_tool_call_open unix_ms=1\n\n"), valid...), "codex", workspace); err != nil {
		t.Fatalf("SSE comment must not be interpreted as tool data: %v", err)
	}
	if validateConnectedToolStream(bytes.ReplaceAll(valid, []byte("data: [DONE]"), nil), "codex", workspace) == nil {
		t.Fatal("accepted incomplete stream")
	}
	fragmented := []byte(`data: {"choices":[{"index":0,"delta":{"tool_calls":[{"index":0,"id":"call_fixture","type":"function","function":{"name":"exec_command","arguments":"{\"cmd\":\"cat "}}]}}]}

data: {"choices":[{"index":0,"delta":{"tool_calls":[{"index":0,"function":{"arguments":"marker.txt\"}"}}]}}]}

data: {"choices":[{"index":0,"delta":{},"finish_reason":"tool_calls"}]}

data: [DONE]

`)
	if err := validateConnectedToolStream(fragmented, "codex", workspace); err != nil {
		t.Fatalf("fragmented safe call: %v", err)
	}
	unsafe := bytes.ReplaceAll(fragmented, []byte("marker.txt"), []byte("marker.txt;env"))
	if validateConnectedToolStream(unsafe, "codex", workspace) == nil {
		t.Fatal("accepted fragmented unsafe call")
	}
}

func TestConnectedClientFinalText(t *testing.T) {
	// Goose1.45.0 emits incremental Message events, not a single final object:
	// https://github.com/block/goose/blob/v1.45.0/crates/goose-cli/src/session/mod.rs
	goose := `{"type":"message","message":{"role":"assistant","content":[{"type":"text","text":"Reading"}]}}
{"type":"message","message":{"role":"assistant","content":[{"type":"toolRequest"}]}}
{"type":"message","message":{"role":"user","content":[{"type":"toolResponse","text":"marker-secret"}]}}
{"type":"message","message":{"role":"assistant","content":[{"type":"text","text":"marker-"}]}}
{"type":"message","message":{"role":"assistant","content":[{"type":"text","text":"secret"}]}}
{"type":"complete"}`
	if got := connectedClientFinalText("goose", goose); got != "marker-secret" {
		t.Fatalf("Goose final text=%q", got)
	}
	if got := connectedClientFinalText("goose", `{"type":"message","message":{"role":"user","content":[{"type":"toolResponse","text":"marker-secret"}]}}`); got != "" {
		t.Fatal("tool result counted as final answer")
	}
}

// Diagnostics expose fixed schema counters and error fingerprints only, never
// arbitrary client messages, model output, tool results, paths, or credentials.
func connectedClientSummary(kind, output, marker string) string {
	counts := map[string]int{}
	errors := []string{}
	for _, line := range strings.Split(output, "\n") {
		var event struct {
			Type    string `json:"type"`
			Error   string `json:"error"`
			Message struct {
				Role    string `json:"role"`
				Content []struct {
					Type string `json:"type"`
					Text string `json:"text"`
				} `json:"content"`
			} `json:"message"`
		}
		if json.Unmarshal([]byte(line), &event) != nil {
			counts["non_json_lines"]++
			continue
		}
		switch event.Type {
		case "message", "error", "complete", "text", "step_start", "step_finish", "tool_use":
			counts[event.Type]++
		default:
			counts["other_event"]++
		}
		if event.Error != "" {
			sum := sha256.Sum256([]byte(event.Error))
			errors = append(errors, hex.EncodeToString(sum[:]))
			for _, word := range []string{"missing field", "invalid type", "EOF", "unexpected end", "tool", "stream", "decode", "parse", "context", "rate limit", "function", "tokens", "400", "403", "429"} {
				if strings.Contains(strings.ToLower(event.Error), strings.ToLower(word)) {
					counts["error_has_"+word]++
				}
			}
		}
		if event.Message.Role == "assistant" {
			counts["assistant_messages"]++
			for _, item := range event.Message.Content {
				if item.Type == "text" {
					counts["assistant_text_bytes"] += len(item.Text)
				} else {
					counts["assistant_non_text"]++
				}
			}
		}
	}
	counts["extracted_final_bytes"] = len(connectedClientFinalText(kind, output))
	summary, _ := json.Marshal(map[string]any{"schema_counts": counts, "error_sha256": errors, "output_contains_marker": strings.Contains(output, marker)})
	return string(summary)
}

// Report only schema counts and known tool availability, never request content.
func connectedRequestShape(body []byte) string {
	var payload struct {
		Messages []struct {
			Role string `json:"role"`
		} `json:"messages"`
		Tools []struct {
			Function struct {
				Name string `json:"name"`
			} `json:"function"`
		} `json:"tools"`
	}
	counts := map[string]int{}
	if json.Unmarshal(body, &payload) != nil {
		return `{"invalid_json":1}`
	}
	for _, message := range payload.Messages {
		switch message.Role {
		case "system", "developer", "user", "assistant", "tool":
			counts[message.Role]++
		default:
			counts["other_role"]++
		}
	}
	counts["tools"] = len(payload.Tools)
	for _, tool := range payload.Tools {
		switch tool.Function.Name {
		case "read", "shell", "exec_command", "functions.exec_command":
			counts[tool.Function.Name]++
		}
	}
	data, _ := json.Marshal(counts)
	return string(data)
}

func connectedSyntheticToolResponse(body []byte, kind, workspace, marker string) ([]byte, error) {
	var payload struct {
		Messages []struct {
			Role    string          `json:"role"`
			Content json.RawMessage `json:"content"`
		} `json:"messages"`
		Tools []struct {
			Function struct {
				Name string `json:"name"`
			} `json:"function"`
		} `json:"tools"`
	}
	if json.Unmarshal(body, &payload) != nil {
		return nil, fmt.Errorf("invalid synthetic request")
	}
	toolName := "read"
	arguments := map[string]any{"filePath": filepath.Join(workspace, "marker.txt")}
	if kind == "goose" {
		toolName = "shell"
		arguments = map[string]any{"command": "cat marker.txt"}
	}
	hasTool, hasResult := false, false
	for _, tool := range payload.Tools {
		hasTool = hasTool || tool.Function.Name == toolName
	}
	for _, message := range payload.Messages {
		hasResult = hasResult || (message.Role == "tool" && strings.Contains(string(message.Content), marker))
	}
	delta := map[string]any{"role": "assistant", "content": "Fixture title"}
	finish := "stop"
	if hasResult {
		delta["content"] = marker
	} else if hasTool {
		encoded, _ := json.Marshal(arguments)
		delete(delta, "content")
		delta["tool_calls"] = []any{map[string]any{"index": 0, "id": "call_fixture", "type": "function", "function": map[string]any{"name": toolName, "arguments": string(encoded)}}}
		finish = "tool_calls"
	} else if len(payload.Tools) != 0 {
		return nil, fmt.Errorf("synthetic request missing expected marker read tool")
	}
	frame, _ := json.Marshal(map[string]any{"id": "chatcmpl_fixture", "object": "chat.completion.chunk", "created": 1, "model": "mlx-community/Qwen3-30B-A3B-Instruct-2507-4bit", "choices": []any{map[string]any{"index": 0, "delta": delta, "finish_reason": finish}}, "usage": map[string]int{"prompt_tokens": 4, "completion_tokens": 8, "total_tokens": 12}})
	return []byte("data: " + string(frame) + "\n\ndata: [DONE]\n\n"), nil
}

func TestConnectedClientSyntheticProtocol(t *testing.T) {
	for _, kind := range []string{"opencode", "goose"} {
		name := "read"
		if kind == "goose" {
			name = "shell"
		}
		body := []byte(fmt.Sprintf(`{"messages":[{"role":"user","content":"private"}],"tools":[{"type":"function","function":{"name":%q}}]}`, name))
		response, err := connectedSyntheticToolResponse(body, kind, "/fixture", "marker-secret")
		if err != nil || validateConnectedToolStream(response, kind, "/fixture") != nil {
			t.Fatalf("synthetic tool guard: kind=%s error=%v", kind, err)
		}
		if strings.Contains(connectedRequestShape(body), "private") {
			t.Fatal("request diagnostics exposed content")
		}
		final, err := connectedSyntheticToolResponse([]byte(`{"messages":[{"role":"tool","content":"marker-secret"}]}`), kind, "/fixture", "marker-secret")
		if err != nil || !bytes.Contains(final, []byte("marker-secret")) || validateConnectedToolStream(final, kind, "/fixture") != nil {
			t.Fatal("synthetic final response invalid")
		}
	}
}

func connectedClientModel(raw string, synthetic bool) (string, error) {
	const instruct = "mlx-community/Qwen3-30B-A3B-Instruct-2507-4bit"
	const coder = "mlx-community/Qwen3-Coder-30B-A3B-Instruct-4bit"
	if synthetic || raw == "" {
		return instruct, nil
	}
	if raw == instruct || raw == coder {
		return raw, nil
	}
	return "", fmt.Errorf("fixture model must match one of the two qualified exact identities")
}

func connectedClientContext(raw string, synthetic bool) (int, error) {
	if synthetic || raw == "" || raw == "8192" {
		return 8192, nil
	}
	if raw == "16384" {
		return 16384, nil
	}
	return 0, fmt.Errorf("fixture context must be 8192 or 16384")
}

func connectedProviderMatches(body []byte, model string, contextTokens int) bool {
	var status struct {
		Model    string `json:"model"`
		Capacity struct {
			MaxContextTokens int `json:"max_context_tokens"`
		} `json:"capacity"`
	}
	return !anthropicRawHasDuplicateKeys(body) && json.Unmarshal(body, &status) == nil && status.Model == model && status.Capacity.MaxContextTokens == contextTokens
}

// SSE may contain sensitive text, including malformed finish reasons. Retain
// only numeric usage and a closed finish-reason enum, even before validation.
func connectedStreamUsage(body []byte) string {
	var usage struct {
		Prompt     int `json:"prompt_tokens"`
		Completion int `json:"completion_tokens"`
		Total      int `json:"total_tokens"`
	}
	found := false
	finishReason := "absent"
	for _, line := range strings.Split(string(body), "\n") {
		if !strings.HasPrefix(line, "data:") {
			continue
		}
		var frame struct {
			Usage   json.RawMessage `json:"usage"`
			Choices []struct {
				FinishReason *string `json:"finish_reason"`
			} `json:"choices"`
		}
		if json.Unmarshal([]byte(strings.TrimSpace(strings.TrimPrefix(line, "data:"))), &frame) != nil {
			continue
		}
		for _, choice := range frame.Choices {
			if choice.FinishReason == nil {
				continue
			}
			reason := "other"
			switch *choice.FinishReason {
			case "stop", "tool_calls", "length", "content_filter", "function_call":
				reason = *choice.FinishReason
			}
			if finishReason == "absent" {
				finishReason = reason
			} else if finishReason != reason {
				finishReason = "multiple"
			}
		}
		if len(frame.Usage) > 0 && string(frame.Usage) != "null" && json.Unmarshal(frame.Usage, &usage) == nil {
			found = true
		}
	}
	encoded, _ := json.Marshal(map[string]any{"present": found, "prompt_tokens": usage.Prompt, "completion_tokens": usage.Completion, "total_tokens": usage.Total, "finish_reason": finishReason})
	return string(encoded)
}

func TestConnectedClientStreamUsageSanitizesFinishReason(t *testing.T) {
	for _, tc := range []struct {
		reasons []any
		want    string
	}{
		{nil, "absent"}, {[]any{nil}, "absent"},
		{[]any{"stop"}, "stop"}, {[]any{"tool_calls"}, "tool_calls"},
		{[]any{"length"}, "length"}, {[]any{"content_filter"}, "content_filter"},
		{[]any{"function_call"}, "function_call"}, {[]any{"private-output\nsecret"}, "other"},
		{[]any{"length", "stop"}, "multiple"}, {[]any{"length", "length"}, "length"},
	} {
		var body []byte
		for _, reason := range tc.reasons {
			frame, err := json.Marshal(map[string]any{
				"choices": []any{map[string]any{"finish_reason": reason, "delta": map[string]any{"content": "private-output"}}},
				"usage":   map[string]any{"prompt_tokens": 12, "completion_tokens": 3, "total_tokens": 15},
			})
			if err != nil {
				t.Fatal(err)
			}
			body = append(body, []byte("data: "+string(frame)+"\n\n")...)
		}
		summary := connectedStreamUsage(body)
		var got struct {
			FinishReason string `json:"finish_reason"`
		}
		if json.Unmarshal([]byte(summary), &got) != nil || got.FinishReason != tc.want || strings.Contains(summary, "private") || strings.Contains(summary, "secret") {
			t.Fatal("finish-reason diagnostic was incorrect or leaked model text")
		}
	}
}

func TestConnectedClientContextBinding(t *testing.T) {
	const instruct = "mlx-community/Qwen3-30B-A3B-Instruct-2507-4bit"
	const coder = "mlx-community/Qwen3-Coder-30B-A3B-Instruct-4bit"
	for _, tc := range []struct {
		raw       string
		synthetic bool
		want      string
	}{{"", false, instruct}, {instruct, false, instruct}, {coder, false, coder}, {coder, true, instruct}, {"Qwen3-Coder", false, ""}, {"other/model", false, ""}, {coder + " ", false, ""}} {
		got, err := connectedClientModel(tc.raw, tc.synthetic)
		if got != tc.want || (err != nil) != (tc.want == "") {
			t.Fatal("unexpected fixture model resolution")
		}
	}
	for _, tc := range []struct {
		raw       string
		synthetic bool
		want      int
	}{{"", false, 8192}, {"16384", false, 16384}, {"16384", true, 8192}, {"32768", false, 0}} {
		got, err := connectedClientContext(tc.raw, tc.synthetic)
		if got != tc.want || (err != nil) != (tc.want == 0) {
			t.Fatal("unexpected fixture context resolution")
		}
	}
	good := []byte(`{"model":"fixture-model","capacity":{"max_context_tokens":16384}}`)
	if !connectedProviderMatches(good, "fixture-model", 16384) || connectedProviderMatches(good, "other", 16384) || connectedProviderMatches(good, "fixture-model", 8192) {
		t.Fatal("provider identity/capacity binding failed")
	}
	if connectedProviderMatches([]byte(`{"model":"other","model":"fixture-model","capacity":{"max_context_tokens":16384}}`), "fixture-model", 16384) {
		t.Fatal("accepted duplicate status identity")
	}
	usage := connectedStreamUsage([]byte("data: {\"choices\":[{\"delta\":{\"content\":\"private\"}}]}\n\ndata: {\"usage\":{\"prompt_tokens\":7300,\"completion_tokens\":20,\"total_tokens\":7320}}\n\ndata: [DONE]\n"))
	if strings.Contains(usage, "private") || !strings.Contains(usage, `"total_tokens":7320`) {
		t.Fatal("numeric usage diagnostics failed")
	}
}
