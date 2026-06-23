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
