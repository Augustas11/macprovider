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
	fetchedAt, ok := got["fetched_at"].(string)
	if !ok || fetchedAt == "" {
		t.Fatalf("fetched_at missing or not string: %#v", got["fetched_at"])
	}
	parsed, err := time.Parse(time.RFC3339, fetchedAt)
	if err != nil {
		t.Fatalf("fetched_at %q is not RFC3339: %v", fetchedAt, err)
	}
	if parsed.Location() != time.UTC {
		t.Fatalf("fetched_at %q must be UTC (Z suffix); got location %s", fetchedAt, parsed.Location())
	}
	wantKeys := map[string]bool{"provider_id": true, "receipt_pubkey": true, "receipt_pubkey_prev": true, "fetched_at": true}
	for k := range got {
		if !wantKeys[k] {
			t.Fatalf("response body contains unexpected key %q (full body: %v)", k, got)
		}
	}
	if len(got) != len(wantKeys) {
		t.Fatalf("response body has %d keys, want %d (%v)", len(got), len(wantKeys), got)
	}
	if rr.Header().Get("Cache-Control") != "public, max-age=300" {
		t.Fatalf("Cache-Control = %q", rr.Header().Get("Cache-Control"))
	}
}

func TestReceiptKeysDropsExpiredPreviousKey(t *testing.T) {
	registry := pool.NewRegistry(nil)
	current := bytes.Repeat([]byte{0x44}, 32)
	previous := bytes.Repeat([]byte{0x45}, 32)
	// The handler uses s.now() which is wall-clock real-time (not the startedAt argument).
	// Use clearly-past dates so the test stays stable regardless of when CI runs.
	rotatedAt := time.Date(2020, 1, 1, 0, 0, 0, 0, time.UTC)
	expiresAt := time.Date(2020, 1, 8, 0, 0, 0, 0, time.UTC) // 7-day grace from rotated, but expired years ago
	registerReceiptKeyProvider(registry, "p1", current, &pool.ReceiptPubkeyPrevious{
		Pubkey:    previous,
		RotatedAt: rotatedAt,
		ExpiresAt: expiresAt,
	})
	server := NewServer(registry, zerolog.Nop(), time.Unix(1716768000, 0))

	rr := serveReceiptKeys(server, "p1", "198.51.100.7:12345")

	if rr.Code != http.StatusOK {
		t.Fatalf("status = %d, body=%s", rr.Code, rr.Body.String())
	}
	var got map[string]any
	if err := json.Unmarshal(rr.Body.Bytes(), &got); err != nil {
		t.Fatalf("json: %v", err)
	}
	if got["receipt_pubkey_prev"] != nil {
		t.Fatalf("expired receipt_pubkey_prev MUST serialize as null; got %#v", got["receipt_pubkey_prev"])
	}
	// The expired previous-key bytes MUST NOT appear anywhere in the response body.
	prevB64 := base64.StdEncoding.EncodeToString(previous)
	if bytes.Contains(rr.Body.Bytes(), []byte(prevB64)) {
		t.Fatalf("expired previous pubkey leaked into response body: %s", rr.Body.String())
	}
	if rr.Header().Get("Cache-Control") != "public, max-age=300" {
		t.Fatalf("Cache-Control = %q", rr.Header().Get("Cache-Control"))
	}
}

func TestReceiptKeysReturnsPreviousKeyInGraceWindow(t *testing.T) {
	registry := pool.NewRegistry(nil)
	current := bytes.Repeat([]byte{0x42}, 32)
	previous := bytes.Repeat([]byte{0x43}, 32)
	// `Registry.Register` (called by `registerReceiptKeyProvider`) uses
	// real `time.Now()` internally to gate `activeReceiptPubkeyPrev`
	// at `phase4-coordinator/internal/pool/provider.go:550`. The test's
	// `server.now` override only takes effect AFTER Register completes,
	// so `expiresAt` MUST stay in the real-wall-clock future or the
	// registry drops the previous key before the test can observe it.
	// Use 2099 so this test never time-bombs again.
	rotatedAt := time.Date(2099, 6, 22, 12, 0, 0, 0, time.UTC)
	expiresAt := time.Date(2099, 6, 29, 12, 0, 0, 0, time.UTC)
	registerReceiptKeyProvider(registry, "p1", current, &pool.ReceiptPubkeyPrevious{
		Pubkey:    previous,
		RotatedAt: rotatedAt,
		ExpiresAt: expiresAt,
	})
	server := NewServer(registry, zerolog.Nop(), time.Unix(1716768000, 0))
	frozen := time.Date(2099, 6, 23, 12, 0, 0, 0, time.UTC)
	server.now = func() time.Time { return frozen }

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
	// MINOR-2: parse the timestamps back, assert UTC, and assert the nested object has exactly three keys.
	for _, ts := range []string{got.ReceiptPubkeyPrev.RotatedAt, got.ReceiptPubkeyPrev.ExpiresAt} {
		parsed, err := time.Parse(time.RFC3339, ts)
		if err != nil {
			t.Fatalf("nested timestamp %q is not RFC3339: %v", ts, err)
		}
		if parsed.Location() != time.UTC {
			t.Fatalf("nested timestamp %q must be UTC; got location %s", ts, parsed.Location())
		}
	}
	// Assert nested receipt_pubkey_prev object has exactly {pubkey, rotated_at, expires_at}.
	var nested map[string]any
	if err := json.Unmarshal(rr.Body.Bytes(), &struct {
		Prev *map[string]any `json:"receipt_pubkey_prev"`
	}{Prev: &nested}); err != nil {
		t.Fatalf("nested json: %v", err)
	}
	wantNestedKeys := map[string]bool{"pubkey": true, "rotated_at": true, "expires_at": true}
	for k := range nested {
		if !wantNestedKeys[k] {
			t.Fatalf("receipt_pubkey_prev contains unexpected key %q (full nested: %v)", k, nested)
		}
	}
	if len(nested) != len(wantNestedKeys) {
		t.Fatalf("receipt_pubkey_prev has %d keys, want %d (%v)", len(nested), len(wantNestedKeys), nested)
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
