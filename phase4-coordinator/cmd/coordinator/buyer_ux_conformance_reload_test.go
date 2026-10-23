package main

import (
	"bytes"
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"strings"
	"testing"

	"github.com/augstar/macprovider-coordinator/internal/config"
	"github.com/rs/zerolog"
)

const reloadConformanceRecord = `{"schema_version":"macprovider.buyer-ux-conformance.v1","records":{"meta-llama/llama-3.2-3b-instruct":{"model":"mlx-community/Llama-3.2-3B-Instruct-4bit","capabilities":{"base":true,"tools":false,"tool_choice":[],"reasoning":true,"response_format":true,"messages":true,"responses":true}}}}`

// SPEC-023 §16.11: routing.buyer_ux_conformance_path applies on SIGHUP, and
// /healthz reports the record file in force so catalog-activate.sh can prove
// an install without a restart. A file that goes bad keeps the records in
// force; clearing the path clears them.
func TestReloadCoordinatorConfigAppliesBuyerUXConformance(t *testing.T) {
	startup, _, wsServer, buyerServer := reloadTestServers(config.Default())
	wsServer.SetBuyerUXConformanceStatus(buyerServer.BuyerUXConformanceStatus)
	healthz := func() map[string]any {
		t.Helper()
		rec := httptest.NewRecorder()
		wsServer.Handler().ServeHTTP(rec, httptest.NewRequest(http.MethodGet, "/healthz", nil))
		var body map[string]any
		if err := json.Unmarshal(rec.Body.Bytes(), &body); err != nil {
			t.Fatalf("healthz body %q: %v", rec.Body.String(), err)
		}
		return body
	}
	body := healthz()
	if body["buyer_ux_conformance_reloads"] != true || body["buyer_ux_conformance_records"] != float64(0) {
		t.Fatalf("healthz before any record file: %v", body)
	}
	if _, ok := body["buyer_ux_conformance_sha256"]; ok {
		t.Fatalf("healthz names a record file before one is loaded: %v", body)
	}

	path := filepath.Join(t.TempDir(), "buyer-ux-conformance.json")
	if err := os.WriteFile(path, []byte(reloadConformanceRecord), 0o600); err != nil {
		t.Fatal(err)
	}
	sum := sha256.Sum256([]byte(reloadConformanceRecord))
	want := hex.EncodeToString(sum[:])
	next := startup
	next.Routing.BuyerUXConformancePath = path
	var logs bytes.Buffer
	reloadCoordinatorConfig(writeReloadConfig(t, next), "", startup.Tier2, zerolog.New(&logs), wsServer, buyerServer, nil, nil, nil)
	if !strings.Contains(logs.String(), "conformance records changed") || !strings.Contains(logs.String(), want) {
		t.Fatalf("reload log lacks the record change: %s", logs.String())
	}
	body = healthz()
	if body["buyer_ux_conformance_sha256"] != want || body["buyer_ux_conformance_records"] != float64(1) {
		t.Fatalf("healthz after the reload: %v", body)
	}

	// The same bytes again: applied, not reported as a change.
	logs.Reset()
	reloadCoordinatorConfig(writeReloadConfig(t, next), "", startup.Tier2, zerolog.New(&logs), wsServer, buyerServer, nil, nil, nil)
	if strings.Contains(logs.String(), "buyer_ux_conformance_reload") {
		t.Fatalf("an unchanged record file logged a reload event: %s", logs.String())
	}

	// A malformed file, then a missing one: the records in force stay, the
	// rest of the reload still applies.
	for name, mutate := range map[string]func(){
		"malformed": func() { _ = os.WriteFile(path, []byte(`{"schema_version":`), 0o600) },
		"missing":   func() { _ = os.Remove(path) },
	} {
		mutate()
		logs.Reset()
		reloadCoordinatorConfig(writeReloadConfig(t, next), "", startup.Tier2, zerolog.New(&logs), wsServer, buyerServer, nil, nil, nil)
		if !strings.Contains(logs.String(), "keeping the conformance records in force") {
			t.Fatalf("%s record file: reload log lacks the error: %s", name, logs.String())
		}
		if !strings.Contains(logs.String(), "tier2/proof_of_weights config reloaded") {
			t.Fatalf("%s record file rejected the rest of the reload: %s", name, logs.String())
		}
		if body = healthz(); body["buyer_ux_conformance_sha256"] != want || body["buyer_ux_conformance_records"] != float64(1) {
			t.Fatalf("%s record file dropped the records in force: %v", name, body)
		}
	}

	// Removing the key clears the records.
	next.Routing.BuyerUXConformancePath = ""
	reloadCoordinatorConfig(writeReloadConfig(t, next), "", startup.Tier2, zerolog.Nop(), wsServer, buyerServer, nil, nil, nil)
	body = healthz()
	if _, ok := body["buyer_ux_conformance_sha256"]; ok || body["buyer_ux_conformance_records"] != float64(0) {
		t.Fatalf("healthz after the path was cleared: %v", body)
	}
}
