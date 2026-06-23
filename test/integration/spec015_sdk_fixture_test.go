package integration

import (
	"encoding/json"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"testing"
)

func TestSpec015SDKCompatFixturePinsOpenAISDKs(t *testing.T) {
	root := filepath.Join("spec015", "sdk_compat")
	pyReq, err := os.ReadFile(filepath.Join(root, "python", "requirements.txt"))
	if err != nil {
		t.Fatalf("read python requirements: %v", err)
	}
	if !strings.Contains(string(pyReq), "openai==1.30.1") {
		t.Fatalf("python SDK must be exactly pinned to openai==1.30.1, got %q", string(pyReq))
	}
	pyLock, err := os.ReadFile(filepath.Join(root, "python", "requirements.lock"))
	if err != nil {
		t.Fatalf("read python requirements lock: %v", err)
	}
	pyLockText := string(pyLock)
	if !strings.Contains(pyLockText, "openai==1.30.1") {
		t.Fatalf("python lock must pin openai==1.30.1, got %q", string(pyLock))
	}
	for _, dep := range []string{"anyio==", "distro==", "httpx==", "pydantic==", "sniffio==", "tqdm==", "typing-extensions=="} {
		if !strings.Contains(pyLockText, dep) {
			t.Fatalf("python lock must include transitive dependency %s", dep)
		}
	}
	if strings.Count(pyLockText, "--hash=sha256:") < 8 {
		t.Fatalf("python lock must include sha256 hashes for pinned dependencies")
	}

	packageLock, err := os.ReadFile(filepath.Join(root, "js", "package-lock.json"))
	if err != nil {
		t.Fatalf("read package-lock.json: %v", err)
	}
	if !strings.Contains(string(packageLock), `"node_modules/openai"`) || !strings.Contains(string(packageLock), `"integrity"`) {
		t.Fatalf("package-lock.json must lock openai with integrity metadata")
	}

	packageJSON, err := os.ReadFile(filepath.Join(root, "js", "package.json"))
	if err != nil {
		t.Fatalf("read package.json: %v", err)
	}
	var pkg struct {
		Dependencies map[string]string `json:"dependencies"`
	}
	if err := json.Unmarshal(packageJSON, &pkg); err != nil {
		t.Fatalf("decode package.json: %v", err)
	}
	if got := pkg.Dependencies["openai"]; got != "4.52.7" {
		t.Fatalf("node SDK must be exactly pinned to openai 4.52.7, got %q", got)
	}

	pySmoke, err := os.ReadFile(filepath.Join(root, "python", "smoke_openai_python.py"))
	if err != nil {
		t.Fatalf("read python smoke: %v", err)
	}
	if !strings.Contains(string(pySmoke), "chat.completions.create") || !strings.Contains(string(pySmoke), "stream=True") {
		t.Fatalf("python smoke must exercise chat.completions.create in non-streaming and streaming modes")
	}

	jsSmoke, err := os.ReadFile(filepath.Join(root, "js", "smoke_openai_node.mjs"))
	if err != nil {
		t.Fatalf("read node smoke: %v", err)
	}
	if !strings.Contains(string(jsSmoke), "chat.completions.create") || !strings.Contains(string(jsSmoke), "stream: true") {
		t.Fatalf("node smoke must exercise chat.completions.create in non-streaming and streaming modes")
	}

	runner, err := os.ReadFile(filepath.Join(root, "run.sh"))
	if err != nil {
		t.Fatalf("read SDK compat runner: %v", err)
	}
	if !strings.Contains(string(runner), "--require-hashes") || !strings.Contains(string(runner), "requirements.lock") {
		t.Fatalf("runner must install Python dependencies from the hash-locked requirements lock")
	}
	if !strings.Contains(string(runner), "npm ci") || !strings.Contains(string(runner), "package-lock.json") {
		t.Fatalf("runner must install Node dependencies from package-lock.json with npm ci")
	}
}

func TestSpec015SDKCompatAgainstGateway(t *testing.T) {
	if os.Getenv("SPEC015_SDK_COMPAT_GATEWAY") != "1" {
		t.Skip("set SPEC015_SDK_COMPAT_GATEWAY=1 to run pinned SDK smoke against the real local gateway harness")
	}
	s := newScenario(t, scenarioOpts{seedAccount: true, receiptEnabledProvider: true})
	cmd := exec.Command("bash", filepath.Join("spec015", "sdk_compat", "run.sh"))
	cmd.Env = append(os.Environ(),
		"MACPROVIDER_SPEC015_GATEWAY_URL="+s.gatewayBaseURL,
		"MACPROVIDER_SPEC015_API_KEY="+s.apiKey,
		"MACPROVIDER_SPEC015_MODEL=llama-3.2-3b-instruct",
	)
	out, err := cmd.CombinedOutput()
	if err != nil {
		t.Fatalf("sdk compat against gateway failed: %v\n%s", err, out)
	}
}

func TestSpec015SDKCompatLiveRunner(t *testing.T) {
	if os.Getenv("SPEC015_SDK_COMPAT_LIVE") != "1" {
		t.Skip("set SPEC015_SDK_COMPAT_LIVE=1 and MACPROVIDER_SPEC015_GATEWAY_URL to run pinned SDK smoke against a live local gateway")
	}
	cmd := exec.Command("bash", filepath.Join("spec015", "sdk_compat", "run.sh"))
	cmd.Env = os.Environ()
	out, err := cmd.CombinedOutput()
	if err != nil {
		t.Fatalf("sdk compat runner failed: %v\n%s", err, out)
	}
}
