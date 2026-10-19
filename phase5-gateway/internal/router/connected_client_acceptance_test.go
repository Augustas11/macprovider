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
	binary, upstream := os.Getenv("MACPROVIDER_TEST_CODEX_BIN"), os.Getenv("MACPROVIDER_TEST_CODEX_UPSTREAM")
	if binary == "" || upstream == "" {
		t.Skip("requires explicit Codex binary and isolated Studio provider URL")
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
		if payload.Model != model || !payload.Stream || r.Header.Get("X-MacProvider-Account") != "codex-fixture" || r.Header.Get(routingGitHubIDsHeader) != "none" {
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
			return nil, fmt.Errorf("client exceeded six inference requests")
		}
		// Preserve the gateway-produced body; only the destination and fixture
		// service headers differ from the normal coordinator transport.
		forward, err := http.NewRequestWithContext(r.Context(), http.MethodPost, upstream+"/v1/chat/completions", bytes.NewReader(body))
		if err != nil {
			return nil, err
		}
		forward.Header.Set("Content-Type", "application/json")
		return transport.RoundTrip(forward)
	})}
	h, store, _, cfg := newTestHarnessConfig(t, fakeOAuth{}, func(cfg *config.Config) {
		enableResponsesWithCoordinator(cfg)
		cfg.Limits.MaxTokensPerRequest = 1024
	}, WithHTTPClient(client))
	key := createAccountAndKey(t, store, cfg, "codex-fixture")
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
	ctx, cancel := context.WithTimeout(context.Background(), 150*time.Second)
	defer cancel()
	version := exec.CommandContext(ctx, binary, "--version")
	version.Env = env
	version.Dir = filepath.Join(root, "workspace")
	gotVersion, err := version.Output()
	if err != nil || strings.TrimSpace(string(gotVersion)) != "codex-cli 0.163.0" {
		t.Fatal("acceptance requires Codex CLI0.163.0")
	}
	finalPath := filepath.Join(root, "final.txt")
	cmd := exec.CommandContext(ctx, binary, "exec", "--skip-git-repo-check", "--ephemeral", "--json", "--sandbox", "read-only",
		"--cd", filepath.Join(root, "workspace"), "--output-last-message", finalPath,
		"-c", `approval_policy="never"`, "-c", `web_search="disabled"`,
		"Use the shell tool to read marker.txt in the current workspace. Do not inspect any other file or use the network. Reply with exactly its contents and nothing else.")
	cmd.Env, cmd.Dir = env, filepath.Join(root, "workspace")
	cmd.SysProcAttr = &syscall.SysProcAttr{Setpgid: true}
	cmd.Cancel = func() error { return syscall.Kill(-cmd.Process.Pid, syscall.SIGKILL) }
	cmd.WaitDelay = 5 * time.Second
	output := &connectedClientOutput{}
	cmd.Stdout, cmd.Stderr = output, output
	if err := cmd.Run(); err != nil {
		t.Fatalf("isolated Codex failed: %v\n%s", err, strings.ReplaceAll(output.String(), key, "[fixture-key]"))
	}
	final, err := os.ReadFile(finalPath)
	if err != nil || strings.TrimSpace(string(final)) != marker {
		t.Fatalf("Codex did not return the fixture marker: %v\n%s", err, strings.ReplaceAll(output.String(), key, "[fixture-key]"))
	}
	mu.Lock()
	defer mu.Unlock()
	if calls < 2 || !streamed || !matchedResult {
		t.Fatalf("missing real streaming tool round trip: requests=%d streamed=%v matched_result=%v", calls, streamed, matchedResult)
	}
	t.Logf("Codex0.163.0 completed Responses streaming and a matching file-tool result through the gateway (%d model requests)", calls)
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
