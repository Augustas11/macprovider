//go:build integration

package phase7_verify_test

import (
	"bytes"
	"crypto/ed25519"
	"crypto/rand"
	"crypto/rsa"
	"crypto/sha256"
	"crypto/tls"
	"crypto/x509"
	"crypto/x509/pkix"
	"encoding/base64"
	"encoding/binary"
	"encoding/json"
	"encoding/pem"
	"errors"
	"fmt"
	"math/big"
	"net"
	"net/http"
	"net/http/httptest"
	"net/url"
	"os"
	"os/exec"
	"path/filepath"
	"reflect"
	"sort"
	"strings"
	"sync"
	"testing"
	"time"

	"github.com/augstar/macprovider/phase7-verify/internal/schemavalidator"
)

const (
	fixtureSeed      = int64(0xCAFEBABE)
	fixtureProvider  = "m1-anon"
	unknownProvider  = "unknown-provider"
	validFreshUnixTS = int64(1782216000)
)

var verifyBin string

type ReceiptKeysResponse struct {
	ProviderID        string               `json:"provider_id"`
	ReceiptPubkey     string               `json:"receipt_pubkey"`
	ReceiptPubkeyPrev *PreviousKeyResponse `json:"receipt_pubkey_prev"`
	FetchedAt         string               `json:"fetched_at"`
}

type PreviousKeyResponse struct {
	Pubkey    string `json:"pubkey"`
	RotatedAt string `json:"rotated_at"`
	ExpiresAt string `json:"expires_at"`
}

type mockReceiptKeysHandler struct {
	mu      sync.RWMutex
	keys    map[string]ReceiptKeysResponse
	fail404 map[string]bool
	fail5xx map[string]bool
	count   int
}

func TestMain(m *testing.M) {
	tmp, err := os.MkdirTemp("", "macprovider-verify-bin-*")
	if err != nil {
		fmt.Fprintln(os.Stderr, err)
		os.Exit(1)
	}
	defer os.RemoveAll(tmp)

	verifyBin = filepath.Join(tmp, "macprovider-verify")
	cmd := exec.Command("go", "build", "-o", verifyBin, "./cmd/macprovider-verify")
	cmd.Env = append(os.Environ(), "CGO_ENABLED=0")
	if out, err := cmd.CombinedOutput(); err != nil {
		fmt.Fprintf(os.Stderr, "go build ./cmd/macprovider-verify: %v\n%s", err, out)
		os.Exit(1)
	}
	os.Exit(m.Run())
}

func TestReceiptBundleFixturesEndToEnd(t *testing.T) {
	schema, err := os.ReadFile(filepath.Join("schemas", "output.schema.json"))
	if err != nil {
		t.Fatal(err)
	}

	current := pubkeyB64(keyFromSeed(fixtureSeed, "current"))
	previous := pubkeyB64(keyFromSeed(fixtureSeed, "previous"))
	mismatch := pubkeyB64(keyFromSeed(fixtureSeed, "mismatch-cache"))

	rotatedAt := time.Unix(validFreshUnixTS, 0).UTC().Add(time.Hour)
	expiresAt := rotatedAt.Add(7 * 24 * time.Hour)
	baseKeys := map[string]ReceiptKeysResponse{
		fixtureProvider: {
			ProviderID:    fixtureProvider,
			ReceiptPubkey: current,
			ReceiptPubkeyPrev: &PreviousKeyResponse{
				Pubkey:    previous,
				RotatedAt: rotatedAt.Format(time.RFC3339),
				ExpiresAt: expiresAt.Format(time.RFC3339),
			},
			FetchedAt: time.Now().UTC().Format(time.RFC3339),
		},
	}

	tests := []struct {
		name          string
		file          string
		exitCode      int
		result        string
		reason        string
		warnings      []string
		fail404       bool
		fail5xx       bool
		seedStale     bool
		seedMismatch  bool
		expectJSON    bool
		expectNetwork bool
	}{
		{name: "valid_fresh", file: "valid_fresh.bundle.json", exitCode: 0, result: "valid", reason: "signature_and_canonicalization_match", warnings: []string{"non_default_coordinator"}, expectJSON: true, expectNetwork: true},
		{name: "valid_prev_key_in_grace", file: "valid_prev_key_in_grace.bundle.json", exitCode: 0, result: "valid", reason: "signature_and_canonicalization_match", warnings: []string{"non_default_coordinator"}, expectJSON: true, expectNetwork: true},
		{name: "invalid_tampered_output", file: "invalid_tampered_output.bundle.json", exitCode: 1, result: "invalid", reason: "output_hash_mismatch", warnings: []string{"non_default_coordinator"}, expectJSON: true, expectNetwork: true},
		{name: "invalid_tampered_prompt", file: "invalid_tampered_prompt.bundle.json", exitCode: 1, result: "invalid", reason: "prompt_hash_mismatch", warnings: []string{"non_default_coordinator"}, expectJSON: true, expectNetwork: true},
		{name: "invalid_tampered_unix_ts", file: "invalid_tampered_unix_ts.bundle.json", exitCode: 1, result: "invalid", reason: "signature_verify_failed", warnings: []string{"non_default_coordinator"}, expectJSON: true, expectNetwork: true},
		{name: "invalid_pubkey_not_endorsed", file: "invalid_pubkey_not_endorsed.bundle.json", exitCode: 1, result: "invalid", reason: "pubkey_not_endorsed", warnings: []string{"non_default_coordinator"}, expectJSON: true, expectNetwork: true},
		{name: "invalid_prev_key_outside_grace", file: "invalid_prev_key_outside_grace.bundle.json", exitCode: 1, result: "invalid", reason: "previous_key_outside_grace_window", warnings: []string{"non_default_coordinator"}, expectJSON: true, expectNetwork: true},
		{name: "inconclusive_pubkey_unresolvable", file: "valid_fresh.bundle.json", exitCode: 2, result: "inconclusive", reason: "pubkey_unresolvable", warnings: []string{"live_check_skipped", "non_default_coordinator"}, fail5xx: true, expectJSON: true, expectNetwork: true},
		{name: "inconclusive_resolver_404", file: "inconclusive_resolver_404.bundle.json", exitCode: 2, result: "inconclusive", reason: "provider_id_not_in_pool", warnings: []string{"non_default_coordinator"}, fail404: true, expectJSON: true, expectNetwork: true},
		{name: "inconclusive_stale_cache_live_fail", file: "inconclusive_stale_cache_live_fail.bundle.json", exitCode: 2, result: "inconclusive", reason: "cache_stale_and_live_unreachable", warnings: []string{"live_check_skipped", "non_default_coordinator"}, fail5xx: true, seedStale: true, expectJSON: true, expectNetwork: true},
		{name: "malformed_bundle", file: "malformed_bundle.bundle.json", exitCode: 65},
		{name: "malformed_receipt", file: "malformed_receipt.bundle.json", exitCode: 65},
		{name: "invalid_bundle_pubkey_provider_mismatch", file: "invalid_bundle_pubkey_provider_mismatch.bundle.json", exitCode: 1, result: "invalid", reason: "bundle_pubkey_provider_mismatch", warnings: []string{"non_default_coordinator"}, seedMismatch: true, expectJSON: true},
	}

	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			handler := &mockReceiptKeysHandler{
				keys:    cloneKeys(baseKeys),
				fail404: map[string]bool{},
				fail5xx: map[string]bool{},
			}
			if tt.fail404 {
				handler.fail404[unknownProvider] = true
			}
			if tt.fail5xx {
				handler.fail5xx[fixtureProvider] = true
			}
			server, certFile := newMockTLSServer(t, handler)
			defer server.Close()

			cacheDir := t.TempDir()
			coordinatorHost := serverHost(t, server.URL)
			if tt.seedStale {
				writeCacheLine(t, cacheDir, coordinatorHost, fixtureProvider, current, time.Now().UTC().Add(-8*24*time.Hour), nil)
			}
			if tt.seedMismatch {
				writeCacheLine(t, cacheDir, coordinatorHost, fixtureProvider, mismatch, time.Now().UTC(), nil)
			}

			stdout, stderr, code := runVerify(t, filepath.Join("testdata", tt.file), server.URL, cacheDir, certFile)
			if code != tt.exitCode {
				t.Fatalf("exit=%d want=%d stdout=%q stderr=%q", code, tt.exitCode, stdout, stderr)
			}
			if !tt.expectJSON {
				if len(stdout) != 0 {
					t.Fatalf("stdout=%q want empty for data error", stdout)
				}
				return
			}
			if !bytes.HasSuffix(stdout, []byte("\n")) || bytes.Count(stdout, []byte("\n")) != 1 {
				t.Fatalf("stdout must be exactly one JSON line ending in newline: %q", stdout)
			}
			if err := schemavalidator.Validate(schema, stdout); err != nil {
				t.Fatalf("schema rejected stdout %s: %v", stdout, err)
			}
			var decoded map[string]any
			decoder := json.NewDecoder(bytes.NewReader(stdout))
			decoder.UseNumber()
			if err := decoder.Decode(&decoded); err != nil {
				t.Fatalf("stdout did not decode as JSON: %v in %q", err, stdout)
			}
			if decoded["result"] != tt.result || decoded["reason"] != tt.reason {
				t.Fatalf("result/reason=(%v,%v), want (%s,%s): %s", decoded["result"], decoded["reason"], tt.result, tt.reason, stdout)
			}
			if got := warningKinds(decoded); !reflect.DeepEqual(got, sortedCopy(tt.warnings)) {
				t.Fatalf("warning kinds=%v want=%v in %s", got, sortedCopy(tt.warnings), stdout)
			}
			if tt.expectNetwork && handler.calls() == 0 {
				t.Fatal("expected mock /v1/receipt-keys to be called")
			}
			if !tt.expectNetwork && handler.calls() != 0 {
				t.Fatalf("mock /v1/receipt-keys calls=%d want 0", handler.calls())
			}
		})
	}
}

func TestFixtureGeneratorIdempotentAndCommitted(t *testing.T) {
	first := t.TempDir()
	second := t.TempDir()
	runGenerator(t, first)
	runGenerator(t, second)

	committed, err := filepath.Glob(filepath.Join("testdata", "*.bundle.json"))
	if err != nil {
		t.Fatal(err)
	}
	if len(committed) != 12 {
		t.Fatalf("committed bundle count=%d want 12", len(committed))
	}
	for _, path := range committed {
		name := filepath.Base(path)
		committedData := readFile(t, path)
		firstData := readFile(t, filepath.Join(first, name))
		secondData := readFile(t, filepath.Join(second, name))
		if !bytes.Equal(firstData, secondData) {
			t.Fatalf("generator output for %s differs across runs", name)
		}
		if !bytes.Equal(committedData, firstData) {
			t.Fatalf("committed fixture %s differs from generator output", name)
		}
	}
}

func runGenerator(t *testing.T, out string) {
	t.Helper()
	cmd := exec.Command("go", "run", "./testdata/generator", "-seed", "0xCAFEBABE", "-out", out)
	if data, err := cmd.CombinedOutput(); err != nil {
		t.Fatalf("run fixture generator: %v\n%s", err, data)
	}
}

func readFile(t *testing.T, path string) []byte {
	t.Helper()
	data, err := os.ReadFile(path)
	if err != nil {
		t.Fatal(err)
	}
	return data
}

func (h *mockReceiptKeysHandler) ServeHTTP(w http.ResponseWriter, r *http.Request) {
	h.mu.Lock()
	defer h.mu.Unlock()
	h.count++

	if r.Method != http.MethodGet {
		http.Error(w, "method not allowed", http.StatusMethodNotAllowed)
		return
	}
	const prefix = "/v1/receipt-keys/"
	if !strings.HasPrefix(r.URL.Path, prefix) {
		http.NotFound(w, r)
		return
	}
	providerID := strings.TrimPrefix(r.URL.Path, prefix)
	if h.fail5xx[providerID] {
		http.Error(w, "coordinator unavailable", http.StatusServiceUnavailable)
		return
	}
	if h.fail404[providerID] {
		w.WriteHeader(http.StatusNotFound)
		_ = json.NewEncoder(w).Encode(map[string]any{"error": map[string]any{"code": "provider_not_found"}})
		return
	}
	resp, ok := h.keys[providerID]
	if !ok {
		w.WriteHeader(http.StatusNotFound)
		_ = json.NewEncoder(w).Encode(map[string]any{"error": map[string]any{"code": "provider_not_found"}})
		return
	}
	resp.FetchedAt = time.Now().UTC().Format(time.RFC3339)
	w.Header().Set("Cache-Control", "public, max-age=300")
	_ = json.NewEncoder(w).Encode(resp)
}

func (h *mockReceiptKeysHandler) calls() int {
	h.mu.RLock()
	defer h.mu.RUnlock()
	return h.count
}

func runVerify(t *testing.T, bundlePath, coordinator, cacheDir, certFile string) ([]byte, []byte, int) {
	t.Helper()
	cmd := exec.Command(verifyBin, "--bundle", bundlePath, "--coordinator", coordinator, "--json")
	cmd.Env = append(os.Environ(),
		"MACPROVIDER_CACHE_DIR="+cacheDir,
		"SSL_CERT_FILE="+certFile,
		"MACPROVIDER_VERIFY_TLS_CA_FILE="+certFile,
		"GODEBUG=x509usefallbackroots=1",
	)
	stdout, stderr := bytes.Buffer{}, bytes.Buffer{}
	cmd.Stdout = &stdout
	cmd.Stderr = &stderr
	err := cmd.Run()
	code := 0
	if err != nil {
		var exitErr *exec.ExitError
		if errors.As(err, &exitErr) {
			code = exitErr.ExitCode()
		} else {
			t.Fatalf("run verifier: %v stderr=%q", err, stderr.String())
		}
	}
	return stdout.Bytes(), stderr.Bytes(), code
}

func newMockTLSServer(t *testing.T, handler http.Handler) (*httptest.Server, string) {
	t.Helper()
	caCert, caKey := newCA(t)
	serverCert := newServerCert(t, caCert, caKey)
	server := httptest.NewUnstartedServer(handler)
	server.TLS = &tls.Config{Certificates: []tls.Certificate{serverCert}, MinVersion: tls.VersionTLS12}
	server.StartTLS()

	path := filepath.Join(t.TempDir(), "mock-ca.pem")
	data := pem.EncodeToMemory(&pem.Block{Type: "CERTIFICATE", Bytes: caCert.Raw})
	if err := os.WriteFile(path, data, 0o600); err != nil {
		t.Fatal(err)
	}
	return server, path
}

func newCA(t *testing.T) (*x509.Certificate, *rsa.PrivateKey) {
	t.Helper()
	key, err := rsa.GenerateKey(rand.Reader, 2048)
	if err != nil {
		t.Fatal(err)
	}
	template := &x509.Certificate{
		SerialNumber:          big.NewInt(1),
		Subject:               pkix.Name{CommonName: "macprovider verify fixture CA"},
		NotBefore:             time.Now().Add(-time.Hour),
		NotAfter:              time.Now().Add(time.Hour),
		KeyUsage:              x509.KeyUsageCertSign | x509.KeyUsageDigitalSignature,
		BasicConstraintsValid: true,
		IsCA:                  true,
	}
	der, err := x509.CreateCertificate(rand.Reader, template, template, &key.PublicKey, key)
	if err != nil {
		t.Fatal(err)
	}
	cert, err := x509.ParseCertificate(der)
	if err != nil {
		t.Fatal(err)
	}
	return cert, key
}

func newServerCert(t *testing.T, caCert *x509.Certificate, caKey *rsa.PrivateKey) tls.Certificate {
	t.Helper()
	key, err := rsa.GenerateKey(rand.Reader, 2048)
	if err != nil {
		t.Fatal(err)
	}
	template := &x509.Certificate{
		SerialNumber: big.NewInt(2),
		Subject:      pkix.Name{CommonName: "localhost"},
		NotBefore:    time.Now().Add(-time.Hour),
		NotAfter:     time.Now().Add(time.Hour),
		KeyUsage:     x509.KeyUsageDigitalSignature | x509.KeyUsageKeyEncipherment,
		ExtKeyUsage:  []x509.ExtKeyUsage{x509.ExtKeyUsageServerAuth},
		DNSNames:     []string{"localhost"},
		IPAddresses:  []net.IP{net.ParseIP("127.0.0.1"), net.ParseIP("::1")},
	}
	der, err := x509.CreateCertificate(rand.Reader, template, caCert, &key.PublicKey, caKey)
	if err != nil {
		t.Fatal(err)
	}
	certPEM := pem.EncodeToMemory(&pem.Block{Type: "CERTIFICATE", Bytes: der})
	keyPEM := pem.EncodeToMemory(&pem.Block{Type: "RSA PRIVATE KEY", Bytes: x509.MarshalPKCS1PrivateKey(key)})
	cert, err := tls.X509KeyPair(certPEM, keyPEM)
	if err != nil {
		t.Fatal(err)
	}
	return cert
}

func writeCacheLine(t *testing.T, cacheDir, coordinatorHost, providerID, pubkey string, fetchedAt time.Time, prev *PreviousKeyResponse) {
	t.Helper()
	if err := os.MkdirAll(cacheDir, 0o700); err != nil {
		t.Fatal(err)
	}
	line := map[string]any{
		"coordinator_host":    coordinatorHost,
		"provider_id":         providerID,
		"receipt_pubkey":      pubkey,
		"receipt_pubkey_prev": prev,
		"fetched_at":          fetchedAt.UTC().Format(time.RFC3339),
	}
	data, err := json.Marshal(line)
	if err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(cacheDir, "verify-cache.jsonl"), append(data, '\n'), 0o600); err != nil {
		t.Fatal(err)
	}
}

func keyFromSeed(seed int64, label string) ed25519.PrivateKey {
	var buf [8]byte
	binary.LittleEndian.PutUint64(buf[:], uint64(seed))
	sum := sha256.Sum256(append(buf[:], []byte(label)...))
	return ed25519.NewKeyFromSeed(sum[:])
}

func pubkeyB64(priv ed25519.PrivateKey) string {
	return base64.StdEncoding.EncodeToString(priv.Public().(ed25519.PublicKey))
}

func serverHost(t *testing.T, raw string) string {
	t.Helper()
	parsed, err := url.Parse(raw)
	if err != nil {
		t.Fatal(err)
	}
	return parsed.Host
}

func cloneKeys(in map[string]ReceiptKeysResponse) map[string]ReceiptKeysResponse {
	out := make(map[string]ReceiptKeysResponse, len(in))
	for key, value := range in {
		out[key] = value
	}
	return out
}

func warningKinds(decoded map[string]any) []string {
	raw, ok := decoded["warnings"].([]any)
	if !ok {
		return nil
	}
	kinds := make([]string, 0, len(raw))
	for _, item := range raw {
		object, ok := item.(map[string]any)
		if !ok {
			continue
		}
		kind, _ := object["kind"].(string)
		if kind != "" {
			kinds = append(kinds, kind)
		}
	}
	sort.Strings(kinds)
	return kinds
}

func sortedCopy(in []string) []string {
	out := append([]string(nil), in...)
	sort.Strings(out)
	return out
}
