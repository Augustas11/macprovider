package buyer

import (
	"bytes"
	"encoding/base64"
	"encoding/json"
	"fmt"
	"net/http"
	"net/http/httptest"
	"reflect"
	"sync"
	"testing"
	"time"

	"github.com/augstar/macprovider-coordinator/internal/pool"
	"github.com/rs/zerolog"
)

func TestReceiptKeysReturnsCurrentKeyOnly(t *testing.T) {
	registry := pool.NewRegistry(nil)
	current := bytes.Repeat([]byte{0x41}, 32)
	registerReceiptKeyProvider(registry, "p1", current, nil)
	server := NewServer(registry, zerolog.Nop(), time.Unix(1716768000, 0))

	rr := serveReceiptKeys(server, "p1", "198.51.100.1:12345")

	if rr.Code != http.StatusOK {
		t.Fatalf("status = %d, body=%s", rr.Code, rr.Body.String())
	}
	var got map[string]any
	if err := json.Unmarshal(rr.Body.Bytes(), &got); err != nil {
		t.Fatalf("json: %v", err)
	}
	if got["provider_id"] != "p1" {
		t.Fatalf("provider_id = %v", got["provider_id"])
	}
	if got["receipt_pubkey"] != base64.StdEncoding.EncodeToString(current) {
		t.Fatalf("receipt_pubkey = %v", got["receipt_pubkey"])
	}
	if got["receipt_pubkey_prev"] != nil {
		t.Fatalf("receipt_pubkey_prev = %#v, want null", got["receipt_pubkey_prev"])
	}
	if got["fetched_at"] == "" {
		t.Fatalf("fetched_at missing")
	}
	if rr.Header().Get("Cache-Control") != "public, max-age=300" {
		t.Fatalf("Cache-Control = %q", rr.Header().Get("Cache-Control"))
	}
}

func TestReceiptKeysReturnsPreviousKeyInGraceWindow(t *testing.T) {
	registry := pool.NewRegistry(nil)
	current := bytes.Repeat([]byte{0x42}, 32)
	previous := bytes.Repeat([]byte{0x43}, 32)
	rotatedAt := time.Date(2026, 6, 22, 12, 0, 0, 0, time.UTC)
	expiresAt := time.Date(2026, 6, 29, 12, 0, 0, 0, time.UTC)
	registerReceiptKeyProvider(registry, "p1", current, &pool.ReceiptPubkeyPrevious{
		Pubkey:    previous,
		RotatedAt: rotatedAt,
		ExpiresAt: expiresAt,
	})
	server := NewServer(registry, zerolog.Nop(), time.Unix(1716768000, 0))

	rr := serveReceiptKeys(server, "p1", "198.51.100.2:12345")

	if rr.Code != http.StatusOK {
		t.Fatalf("status = %d, body=%s", rr.Code, rr.Body.String())
	}
	var got struct {
		ReceiptPubkeyPrev *struct {
			Pubkey    string `json:"pubkey"`
			RotatedAt string `json:"rotated_at"`
			ExpiresAt string `json:"expires_at"`
		} `json:"receipt_pubkey_prev"`
	}
	if err := json.Unmarshal(rr.Body.Bytes(), &got); err != nil {
		t.Fatalf("json: %v", err)
	}
	if got.ReceiptPubkeyPrev == nil {
		t.Fatalf("receipt_pubkey_prev = nil")
	}
	if got.ReceiptPubkeyPrev.Pubkey != base64.StdEncoding.EncodeToString(previous) {
		t.Fatalf("prev pubkey = %q", got.ReceiptPubkeyPrev.Pubkey)
	}
	if got.ReceiptPubkeyPrev.RotatedAt != rotatedAt.Format(time.RFC3339) || got.ReceiptPubkeyPrev.ExpiresAt != expiresAt.Format(time.RFC3339) {
		t.Fatalf("prev times = %#v", got.ReceiptPubkeyPrev)
	}
}

func TestReceiptKeysReturnsNullCurrentKeyForLegacyProvider(t *testing.T) {
	registry := pool.NewRegistry(nil)
	registerReceiptKeyProvider(registry, "legacy", nil, nil)
	server := NewServer(registry, zerolog.Nop(), time.Unix(1716768000, 0))

	rr := serveReceiptKeys(server, "legacy", "198.51.100.3:12345")

	if rr.Code != http.StatusOK {
		t.Fatalf("status = %d, body=%s", rr.Code, rr.Body.String())
	}
	var got map[string]any
	if err := json.Unmarshal(rr.Body.Bytes(), &got); err != nil {
		t.Fatalf("json: %v", err)
	}
	if got["receipt_pubkey"] != nil {
		t.Fatalf("receipt_pubkey = %#v, want null", got["receipt_pubkey"])
	}
}

func TestReceiptKeysUnknownProvider404(t *testing.T) {
	registry := pool.NewRegistry(nil)
	server := NewServer(registry, zerolog.Nop(), time.Unix(1716768000, 0))

	rr := serveReceiptKeys(server, "missing", "198.51.100.4:12345")

	if rr.Code != http.StatusNotFound {
		t.Fatalf("status = %d, body=%s", rr.Code, rr.Body.String())
	}
	if rr.Header().Get("Cache-Control") != "" {
		t.Fatalf("Cache-Control = %q, want absent", rr.Header().Get("Cache-Control"))
	}
	var got struct {
		Error struct {
			Code string `json:"code"`
		} `json:"error"`
	}
	if err := json.Unmarshal(rr.Body.Bytes(), &got); err != nil {
		t.Fatalf("json: %v", err)
	}
	if got.Error.Code != "provider_not_found" {
		t.Fatalf("error.code = %q", got.Error.Code)
	}
}

func TestReceiptKeysRateLimitsAfterTenRequestsPerSecond(t *testing.T) {
	registry := pool.NewRegistry(nil)
	registerReceiptKeyProvider(registry, "p1", bytes.Repeat([]byte{0x44}, 32), nil)
	server := NewServer(registry, zerolog.Nop(), time.Unix(1716768000, 0))
	now := time.Date(2026, 6, 23, 12, 0, 0, 0, time.UTC)
	server.now = func() time.Time { return now }

	for i := 1; i <= 11; i++ {
		rr := serveReceiptKeys(server, "p1", "198.51.100.5:12345")
		want := http.StatusOK
		if i == 11 {
			want = http.StatusTooManyRequests
		}
		if rr.Code != want {
			t.Fatalf("request %d status = %d, want %d body=%s", i, rr.Code, want, rr.Body.String())
		}
		if i == 11 {
			if rr.Header().Get("Retry-After") != "1" {
				t.Fatalf("Retry-After = %q", rr.Header().Get("Retry-After"))
			}
			if rr.Header().Get("Cache-Control") != "" {
				t.Fatalf("Cache-Control = %q, want absent", rr.Header().Get("Cache-Control"))
			}
		}
	}
}

func TestReceiptKeysResponseWhitelistExcludesProviderFields(t *testing.T) {
	registry := pool.NewRegistry(nil)
	registerReceiptKeyProvider(registry, "p1", bytes.Repeat([]byte{0x45}, 32), nil)
	server := NewServer(registry, zerolog.Nop(), time.Unix(1716768000, 0))

	rr := serveReceiptKeys(server, "p1", "198.51.100.6:12345")

	if rr.Code != http.StatusOK {
		t.Fatalf("status = %d, body=%s", rr.Code, rr.Body.String())
	}
	var got map[string]any
	if err := json.Unmarshal(rr.Body.Bytes(), &got); err != nil {
		t.Fatalf("json: %v", err)
	}
	keys := make([]string, 0, len(got))
	for key := range got {
		keys = append(keys, key)
	}
	want := []string{"fetched_at", "provider_id", "receipt_pubkey", "receipt_pubkey_prev"}
	sortStrings(keys)
	if !reflect.DeepEqual(keys, want) {
		t.Fatalf("keys = %#v, want %#v", keys, want)
	}
	for _, forbidden := range []string{"endpoint_url", "hostname", "connected_at", "slots_total", "slots_free", "throughput_tps_estimate", "model_id"} {
		if _, ok := got[forbidden]; ok {
			t.Fatalf("forbidden key %q present in response", forbidden)
		}
	}
}

func TestReceiptKeysConcurrentDifferentIPs(t *testing.T) {
	registry := pool.NewRegistry(nil)
	registerReceiptKeyProvider(registry, "p1", bytes.Repeat([]byte{0x46}, 32), nil)
	server := NewServer(registry, zerolog.Nop(), time.Unix(1716768000, 0))

	var wg sync.WaitGroup
	errs := make(chan string, 32)
	for i := 1; i <= 32; i++ {
		i := i
		wg.Add(1)
		go func() {
			defer wg.Done()
			rr := serveReceiptKeys(server, "p1", fmt.Sprintf("198.51.100.%d:12345", i))
			if rr.Code != http.StatusOK {
				errs <- fmt.Sprintf("ip %d status = %d body=%s", i, rr.Code, rr.Body.String())
			}
		}()
	}
	wg.Wait()
	close(errs)
	for err := range errs {
		t.Error(err)
	}
}

func serveReceiptKeys(server *Server, providerID, remoteAddr string) *httptest.ResponseRecorder {
	req := httptest.NewRequest(http.MethodGet, "/v1/receipt-keys/"+providerID, nil)
	req.RemoteAddr = remoteAddr
	rr := httptest.NewRecorder()
	server.Handler().ServeHTTP(rr, req)
	return rr
}

func registerReceiptKeyProvider(registry *pool.Registry, providerID string, receiptPubkey []byte, prev *pool.ReceiptPubkeyPrevious) {
	now := time.Now().UTC()
	assignedID := providerID + "-session"
	registry.Register(&pool.Provider{
		ProviderID:            providerID,
		AssignedID:            assignedID,
		Hostname:              providerID + ".local",
		ModelID:               "model-a",
		ModelParamsB:          7,
		RAMGB:                 16,
		MaxContextTokens:      20000,
		MaxConcurrency:        1,
		SlotsFree:             1,
		SlotsTotal:            1,
		ThroughputTPSEstimate: 20,
		EndpointURL:           "https://" + providerID + ".example",
		Tier:                  pool.TierPinned,
		InferencePath:         pool.InferencePathHTTPForwarding,
		State:                 pool.StateReady,
		LastHeartbeatAt:       now,
		LastActivityAt:        now,
		ConnectedAt:           now,
		BinaryVersion:         "0.1.0",
		ReceiptPubkey:         append([]byte(nil), receiptPubkey...),
		ReceiptPubkeyPrev:     cloneTestReceiptPubkeyPrevious(prev),
	}, nil)
	slotsFree := 1
	registry.ApplyStateUpdate(providerID, assignedID, pool.StateUpdate{State: pool.StateReady, SlotsFree: &slotsFree, At: now})
}

func cloneTestReceiptPubkeyPrevious(prev *pool.ReceiptPubkeyPrevious) *pool.ReceiptPubkeyPrevious {
	if prev == nil {
		return nil
	}
	return &pool.ReceiptPubkeyPrevious{
		Pubkey:    append([]byte(nil), prev.Pubkey...),
		RotatedAt: prev.RotatedAt,
		ExpiresAt: prev.ExpiresAt,
	}
}

func sortStrings(values []string) {
	for i := 1; i < len(values); i++ {
		for j := i; j > 0 && values[j] < values[j-1]; j-- {
			values[j], values[j-1] = values[j-1], values[j]
		}
	}
}
