package main

import (
	"bytes"
	"encoding/json"
	"io"
	"log"
	"net"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"

	gobwas "github.com/gobwas/ws"
	"github.com/gobwas/ws/wsutil"
)

func TestCurrentHeartbeatUsesOverrideFile(t *testing.T) {
	dir := t.TempDir()
	overridePath := filepath.Join(dir, "heartbeat.json")
	if err := os.WriteFile(overridePath, []byte(`{"model_id":" mlx-community/Canary-32B ","model_params_b":32}`), 0o600); err != nil {
		t.Fatalf("write override: %v", err)
	}

	hb := currentHeartbeat(config{
		model:       "mlx-community/Canary-7B",
		ramGB:       16,
		maxContext:  8192,
		slots:       1,
		hbModelFile: overridePath,
	}, log.New(io.Discard, "", 0), nil)

	if hb.ModelID != "mlx-community/Canary-32B" {
		t.Fatalf("ModelID = %q, want override", hb.ModelID)
	}
	if hb.ModelParamsB != 32 {
		t.Fatalf("ModelParamsB = %v, want 32", hb.ModelParamsB)
	}
}

func TestCurrentHeartbeatFallsBackOnEmptyOverrideFile(t *testing.T) {
	dir := t.TempDir()
	overridePath := filepath.Join(dir, "heartbeat.json")
	if err := os.WriteFile(overridePath, []byte(" \n"), 0o600); err != nil {
		t.Fatalf("write override: %v", err)
	}

	hb := currentHeartbeat(config{
		model:       "mlx-community/Canary-7B",
		ramGB:       16,
		maxContext:  8192,
		slots:       1,
		hbModelFile: overridePath,
	}, log.New(io.Discard, "", 0), nil)

	if hb.ModelID != "mlx-community/Canary-7B" {
		t.Fatalf("ModelID = %q, want configured model", hb.ModelID)
	}
	if hb.ModelParamsB != 7 {
		t.Fatalf("ModelParamsB = %v, want default", hb.ModelParamsB)
	}
}

func TestReadHeartbeatOverrideRejectsUnknownFields(t *testing.T) {
	dir := t.TempDir()
	overridePath := filepath.Join(dir, "heartbeat.json")
	if err := os.WriteFile(overridePath, []byte(`{"model_id":"model-a","unexpected":true}`), 0o600); err != nil {
		t.Fatalf("write override: %v", err)
	}

	if _, _, err := readHeartbeatOverride(overridePath); err == nil {
		t.Fatal("readHeartbeatOverride accepted an unknown field")
	}
}

func TestReadHeartbeatOverrideRejectsNonRegularFile(t *testing.T) {
	dir := t.TempDir()

	if _, _, err := readHeartbeatOverride(dir); err == nil {
		t.Fatal("readHeartbeatOverride accepted a directory")
	}
}

func TestReadHeartbeatOverrideRejectsOversizedFile(t *testing.T) {
	dir := t.TempDir()
	overridePath := filepath.Join(dir, "heartbeat.json")
	large := make([]byte, maxHeartbeatOverrideBytes+1)
	if err := os.WriteFile(overridePath, large, 0o600); err != nil {
		t.Fatalf("write override: %v", err)
	}

	if _, _, err := readHeartbeatOverride(overridePath); err == nil {
		t.Fatal("readHeartbeatOverride accepted an oversized file")
	}
}

func TestReadProviderTokenTrimsTokenFile(t *testing.T) {
	dir := t.TempDir()
	tokenPath := filepath.Join(dir, "provider.token")
	if err := os.WriteFile(tokenPath, []byte("canary-token\n"), 0o600); err != nil {
		t.Fatalf("write token: %v", err)
	}

	token, ok, err := readProviderToken(tokenPath)
	if err != nil {
		t.Fatalf("readProviderToken: %v", err)
	}
	if !ok {
		t.Fatal("readProviderToken did not report a token")
	}
	if token != "canary-token" {
		t.Fatalf("token = %q, want trimmed token", token)
	}
}

func TestReadProviderTokenRejectsEmptyFile(t *testing.T) {
	dir := t.TempDir()
	tokenPath := filepath.Join(dir, "provider.token")
	if err := os.WriteFile(tokenPath, []byte(" \n"), 0o600); err != nil {
		t.Fatalf("write token: %v", err)
	}

	if _, _, err := readProviderToken(tokenPath); err == nil {
		t.Fatal("readProviderToken accepted an empty token file")
	}
}

func TestReadProviderTokenRejectsNonRegularFile(t *testing.T) {
	dir := t.TempDir()

	if _, _, err := readProviderToken(dir); err == nil {
		t.Fatal("readProviderToken accepted a directory")
	}
}

func TestReadProviderTokenRejectsOversizedFile(t *testing.T) {
	dir := t.TempDir()
	tokenPath := filepath.Join(dir, "provider.token")
	large := make([]byte, maxProviderTokenBytes+1)
	if err := os.WriteFile(tokenPath, large, 0o600); err != nil {
		t.Fatalf("write token: %v", err)
	}

	if _, _, err := readProviderToken(tokenPath); err == nil {
		t.Fatal("readProviderToken accepted an oversized file")
	}
}

func TestReadProviderTokenRejectsGroupReadableFile(t *testing.T) {
	dir := t.TempDir()
	tokenPath := filepath.Join(dir, "provider.token")
	if err := os.WriteFile(tokenPath, []byte("canary-token\n"), 0o600); err != nil {
		t.Fatalf("write token: %v", err)
	}
	if err := os.Chmod(tokenPath, 0o640); err != nil {
		t.Fatalf("chmod token: %v", err)
	}

	if _, _, err := readProviderToken(tokenPath); err == nil {
		t.Fatal("readProviderToken accepted a group-readable file")
	}
}

func TestReadProviderTokenRejectsSymlink(t *testing.T) {
	dir := t.TempDir()
	targetPath := filepath.Join(dir, "target.token")
	linkPath := filepath.Join(dir, "provider.token")
	if err := os.WriteFile(targetPath, []byte("canary-token\n"), 0o600); err != nil {
		t.Fatalf("write token: %v", err)
	}
	if err := os.Symlink(targetPath, linkPath); err != nil {
		t.Fatalf("symlink token: %v", err)
	}

	if _, _, err := readProviderToken(linkPath); err == nil {
		t.Fatal("readProviderToken accepted a symlink")
	}
}

func TestParseProviderTokenRejectsEmbeddedNewline(t *testing.T) {
	if _, err := parseProviderToken([]byte("first\nsecond\n")); err == nil {
		t.Fatal("parseProviderToken accepted embedded newline")
	}
}

func TestParseProviderTokenRejectsWhitespace(t *testing.T) {
	if _, err := parseProviderToken([]byte("canary token\n")); err == nil {
		t.Fatal("parseProviderToken accepted whitespace inside token")
	}
}

func TestRunReturnsNonZeroForInvalidProviderTokenFile(t *testing.T) {
	dir := t.TempDir()
	var output bytes.Buffer

	code := run(config{
		providerID:        "mock-A",
		providerTokenFile: filepath.Join(dir, "missing.token"),
	}, &output)

	if code == 0 {
		t.Fatal("run returned 0 for an invalid provider token file")
	}
	if !strings.Contains(output.String(), "startup config error:") {
		t.Fatalf("output = %q, want startup config error", output.String())
	}
}

func TestRunReturnsNonZeroForUnsafeProviderTokenTransport(t *testing.T) {
	dir := t.TempDir()
	tokenPath := filepath.Join(dir, "provider.token")
	if err := os.WriteFile(tokenPath, []byte("canary-token\n"), 0o600); err != nil {
		t.Fatalf("write token: %v", err)
	}
	var output bytes.Buffer

	code := run(config{
		coordURL:          "ws://coordinator.malibu.tech/ws/provider",
		providerID:        "mock-A",
		providerTokenFile: tokenPath,
	}, &output)

	if code == 0 {
		t.Fatal("run returned 0 for unsafe provider token transport")
	}
	if !strings.Contains(output.String(), "startup config error:") {
		t.Fatalf("output = %q, want startup config error", output.String())
	}
}

func TestRunReturnsNonZeroForWebSocketFailure(t *testing.T) {
	ln, err := net.Listen("tcp", "127.0.0.1:0")
	if err != nil {
		t.Fatalf("listen: %v", err)
	}
	addr := ln.Addr().String()
	if err := ln.Close(); err != nil {
		t.Fatalf("close listener: %v", err)
	}
	var output bytes.Buffer

	code := run(config{
		coordURL:   "ws://" + addr + "/ws/provider",
		providerID: "mock-A",
		httpPort:   0,
	}, &output)

	if code == 0 {
		t.Fatal("run returned 0 for a websocket failure")
	}
	if !strings.Contains(output.String(), "ws loop exited:") {
		t.Fatalf("output = %q, want websocket failure", output.String())
	}
}

func TestRunReturnsZeroForCoordinatorDrain(t *testing.T) {
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		conn, _, _, err := gobwas.UpgradeHTTP(r, w)
		if err != nil {
			t.Errorf("upgrade: %v", err)
			return
		}
		defer conn.Close()

		if _, _, err := wsutil.ReadClientData(conn); err != nil {
			t.Errorf("read hello: %v", err)
			return
		}
		ack, _ := json.Marshal(helloAck{
			Type:               "hello_ack",
			AssignedID:         "assigned-canary",
			HeartbeatIntervalS: 1,
		})
		if err := wsutil.WriteServerText(conn, ack); err != nil {
			t.Errorf("write ack: %v", err)
			return
		}

		sawComplete := false
		drain, _ := json.Marshal(map[string]string{"type": "drain"})
		if err := wsutil.WriteServerText(conn, drain); err != nil {
			t.Errorf("write drain: %v", err)
			return
		}
		deadline := time.Now().Add(5 * time.Second)
		for time.Now().Before(deadline) {
			payload, _, err := wsutil.ReadClientData(conn)
			if err != nil {
				break
			}
			var status drainStatus
			if err := json.Unmarshal(payload, &status); err != nil || status.Type != "drain_status" {
				continue
			}
			if status.Phase == "complete" {
				sawComplete = true
				break
			}
		}
		if !sawComplete {
			t.Error("mockprovider did not send drain_status complete")
		}
	}))
	defer srv.Close()
	coordURL := "ws://" + strings.TrimPrefix(srv.URL, "http://") + "/ws/provider"
	var output bytes.Buffer

	code := run(config{
		coordURL:        coordURL,
		providerID:      "mock-A",
		httpPort:        0,
		drainDelayS:     1,
		maxContext:      8192,
		slots:           1,
		omitEndpointURL: true,
	}, &output)

	if code != 0 {
		t.Fatalf("run returned %d for coordinator drain; output=%q", code, output.String())
	}
}

func TestProviderAuthHeaderWritesBearer(t *testing.T) {
	header := providerAuthHeader(" canary-token ")
	if header == nil {
		t.Fatal("providerAuthHeader returned nil for a token")
	}

	var buf bytes.Buffer
	if _, err := header.WriteTo(&buf); err != nil {
		t.Fatalf("WriteTo: %v", err)
	}
	if got := buf.String(); !strings.Contains(got, "Authorization: Bearer canary-token\r\n") {
		t.Fatalf("header = %q, want Authorization bearer header", got)
	}
}

func TestProviderAuthHeaderSkipsBlankToken(t *testing.T) {
	if header := providerAuthHeader(" \n"); header != nil {
		t.Fatal("providerAuthHeader returned a header for a blank token")
	}
}

func TestValidateTokenTransportAllowsWSS(t *testing.T) {
	if err := validateTokenTransport("wss://coordinator.example.test/ws/provider"); err != nil {
		t.Fatalf("validateTokenTransport rejected wss: %v", err)
	}
}

func TestValidateTokenTransportAllowsLoopbackWS(t *testing.T) {
	for _, coordURL := range []string{
		"ws://127.0.0.1:8444/ws/provider",
		"ws://[::1]:8444/ws/provider",
		"ws://localhost:8444/ws/provider",
	} {
		if err := validateTokenTransport(coordURL); err != nil {
			t.Fatalf("validateTokenTransport rejected %s: %v", coordURL, err)
		}
	}
}

func TestValidateTokenTransportRejectsNonLoopbackWS(t *testing.T) {
	if err := validateTokenTransport("ws://coordinator.malibu.tech/ws/provider"); err == nil {
		t.Fatal("validateTokenTransport accepted token-bearing non-loopback ws")
	}
}
