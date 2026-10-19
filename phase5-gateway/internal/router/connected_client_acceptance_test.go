package router

import (
	"bytes"
	"context"
	"crypto/rand"
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
	runConnectedClientAcceptance(t, "codex", "CODEX", "codex-cli 0.163.0")
}

func TestConnectedOpenCodeClientAcceptance(t *testing.T) {
	runConnectedClientAcceptance(t, "opencode", "OPENCODE", "1.17.9")
}

func TestConnectedGooseClientAcceptance(t *testing.T) {
	runConnectedClientAcceptance(t, "goose", "GOOSE", "1.45.0")
}

func runConnectedClientAcceptance(t *testing.T, kind, envPrefix, expectedVersion string) {
	binary, upstream := os.Getenv("MACPROVIDER_TEST_"+envPrefix+"_BIN"), os.Getenv("MACPROVIDER_TEST_"+envPrefix+"_UPSTREAM")
	if binary == "" || upstream == "" {
		t.Skip("requires explicit client binary and isolated Studio provider URL")
	}
	if upstream != "http://127.0.0.1:18055" || !filepath.IsAbs(binary) {
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

	const model = "mlx-community/Qwen3-30B-A3B-Instruct-2507-4bit"
	root := t.TempDir()
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
	calls, streamed, matchedResult := 0, false, false
	transport := &http.Transport{Proxy: nil, ResponseHeaderTimeout: 90 * time.Second}
	defer transport.CloseIdleConnections()
	client := &http.Client{Transport: roundTripFunc(func(r *http.Request) (*http.Response, error) {
		if r.Method != http.MethodPost || r.URL.Path != "/v1/chat/completions" {
			return nil, fmt.Errorf("unexpected fixture upstream path %s", r.URL.Path)
		}
		body, err := io.ReadAll(io.LimitReader(r.Body, 4<<20))
		if err != nil {
			return nil, err
		}
		var payload struct {
			Model    string `json:"model"`
			Stream   bool   `json:"stream"`
			Messages []struct {
				Role       string          `json:"role"`
				Content    json.RawMessage `json:"content"`
				ToolCallID string          `json:"tool_call_id"`
				ToolCalls  []struct {
					ID string `json:"id"`
				} `json:"tool_calls"`
			} `json:"messages"`
		}
		if err := json.Unmarshal(body, &payload); err != nil {
			return nil, err
		}
		if payload.Model != model || !payload.Stream || r.Header.Get("X-MacProvider-Account") != "connected-fixture" || r.Header.Get(routingGitHubIDsHeader) != "none" {
			cancel()
			return nil, fmt.Errorf("unexpected model, streaming mode, or authenticated fixture identity")
		}
		mu.Lock()
		calls++
		tooMany := calls > 6
		streamed = true
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
		if err != nil || len(held) > 1<<20 || response.StatusCode != http.StatusOK {
			t.Logf("upstream fixture rejected: status=%d size=%d read_error=%t", response.StatusCode, len(held), err != nil)
			cancel()
			return nil, fmt.Errorf("fixture rejected upstream status, size, or incomplete read")
		}
		if err := validateConnectedToolStream(held, kind, filepath.Join(root, "workspace")); err != nil {
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
	}, WithHTTPClient(client))
	key := createAccountAndKey(t, store, cfg, "connected-fixture")
	server := httptest.NewServer(h)
	defer server.Close()

	// Mirrors ConnectedAppConfiguration's conservative Codex0.163.0 catalog;
	// the 8192 context is the isolated provider's qualified cap.
	catalog, err := json.Marshal(map[string]any{"models": []any{map[string]any{
		"slug": model, "display_name": model,
		"description":                "Isolated gateway acceptance fixture",
		"model_messages":             map[string]any{"instructions_template": "You are a coding assistant. Use the available tools to complete the user's request and verify your work."},
		"supported_reasoning_levels": []any{}, "shell_type": "unified_exec", "visibility": "list",
		"supported_in_api": true, "priority": 1, "support_verbosity": false,
		"truncation_policy":            map[string]any{"mode": "tokens", "limit": 8192},
		"experimental_supported_tools": []any{}, "input_modalities": []string{"text"},
		"context_window": 8192, "max_context_window": 8192, "upgrade": nil, "apply_patch_tool_type": nil,
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
	prompt := "Use exec_command with exactly cmd=cat marker.txt to read the current workspace marker. Do not inspect any other file or use the network. Reply with exactly its contents and nothing else."
	if kind != "codex" {
		prompt = "Read only " + filepath.Join(root, "workspace", "marker.txt") + " using the read tool (or text_editor view for Goose). Do not inspect any other file, execute a shell command, or use the network. Reply with exactly its contents and nothing else."
	}
	var args []string
	switch kind {
	case "codex":
		args = []string{"exec", "--skip-git-repo-check", "--ephemeral", "--json", "--sandbox", "read-only",
			"--cd", filepath.Join(root, "workspace"), "--output-last-message", finalPath,
			"-c", `approval_policy="never"`, "-c", `web_search="disabled"`, prompt}
	case "opencode":
		configPath := filepath.Join(root, "opencode.json")
		data, err := json.Marshal(map[string]any{"model": "malibu/" + model, "provider": map[string]any{
			"malibu": map[string]any{"npm": "@ai-sdk/openai-compatible", "name": "Malibu",
				"options": map[string]any{"baseURL": server.URL + "/v1", "apiKey": "{env:MALIBU_API_KEY}"},
				"models":  map[string]any{model: map[string]any{"name": model}}},
		}})
		if err != nil {
			t.Fatal(err)
		}
		write(configPath, data)
		env = append(env, "OPENCODE_CONFIG="+configPath)
		args = []string{"run", "--pure", "--format", "json", "--model", "malibu/" + model, "--dir", filepath.Join(root, "workspace"), prompt}
	case "goose":
		providerDir := filepath.Join(root, "xdg-config", "goose", "custom_providers")
		if err := os.MkdirAll(providerDir, 0700); err != nil {
			t.Fatal(err)
		}
		data, err := json.Marshal(map[string]any{"name": "malibu", "engine": "openai", "display_name": "Malibu", "description": "Isolated gateway acceptance fixture",
			"api_key_env": "MALIBU_API_KEY", "base_url": server.URL + "/v1/chat/completions", "requires_auth": true, "supports_streaming": true,
			"models": []any{map[string]any{"name": model, "context_limit": 8192}}})
		if err != nil {
			t.Fatal(err)
		}
		write(filepath.Join(providerDir, "malibu.json"), data)
		args = []string{"run", "--no-profile", "--no-session", "--max-turns", "3", "--with-builtin", "developer", "--provider", "malibu", "--model", model, "--output-format", "stream-json", "--text", prompt}
	}
	cmd := exec.CommandContext(ctx, binary, args...)
	cmd.Env, cmd.Dir = env, filepath.Join(root, "workspace")
	cmd.SysProcAttr = &syscall.SysProcAttr{Setpgid: true}
	cmd.Cancel = func() error { return syscall.Kill(-cmd.Process.Pid, syscall.SIGKILL) }
	cmd.WaitDelay = 5 * time.Second
	output := &connectedClientOutput{}
	cmd.Stdout, cmd.Stderr = output, output
	if err := cmd.Run(); err != nil {
		t.Fatalf("isolated %s failed: %v (client output withheld)", kind, err)
	}
	var final []byte
	if kind == "codex" {
		final, err = os.ReadFile(finalPath)
	} else {
		final = []byte(connectedClientFinalText(kind, output.String()))
	}
	if err != nil || strings.TrimSpace(string(final)) != marker {
		t.Fatalf("%s did not return the exact fixture marker: %v (client output withheld)", kind, err)
	}
	mu.Lock()
	defer mu.Unlock()
	if calls < 2 || !streamed || !matchedResult {
		t.Fatalf("missing real streaming tool round trip: requests=%d streamed=%v matched_result=%v", calls, streamed, matchedResult)
	}
	t.Logf("%s completed streaming and a matching file-tool result through the gateway (%d model requests)", expectedVersion, calls)
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
			if json.Unmarshal(event["message"], &message) != nil || message.Role != "assistant" {
				continue
			}
			for _, content := range message.Content {
				if content.Type == "text" {
					final = content.Text
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
		if name != "developer__text_editor" || stringArg("command") != "view" || stringArg("path") != filepath.Join(workspace, "marker.txt") {
			return reject("check16")
		}
		allowed = map[string]bool{"command": true, "path": true}
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
		{"view", "goose", "developer__text_editor", `{"command":"view","path":"/fixture/workspace/marker.txt"}`, true},
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
