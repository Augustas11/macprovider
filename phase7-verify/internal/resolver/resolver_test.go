package resolver

import (
	"encoding/base64"
	"encoding/json"
	"errors"
	"net/http"
	"net/http/httptest"
	"net/url"
	"os"
	"path/filepath"
	"strings"
	"sync/atomic"
	"testing"
	"time"

	"github.com/augstar/macprovider/phase7-verify/internal/cache"
)

const providerID = "m1-anon"

var fixedNow = time.Date(2026, 6, 23, 12, 0, 0, 0, time.UTC)

func TestResolveExplicitOfflineNoNetwork(t *testing.T) {
	var calls int32
	server := receiptKeyServer(t, testKey(2), http.StatusOK, &calls)
	defer server.Close()

	root, err := Resolve(providerID, testKey(1), ResolveOpts{
		Offline:         true,
		CoordinatorHost: server.URL,
		HTTPClient:      server.Client(),
		Now:             func() time.Time { return fixedNow },
	})
	if err != nil {
		t.Fatalf("Resolve: %v", err)
	}
	assertSource(t, root, SourceExplicit)
	assertWarning(t, root, "live_check_skipped", "reason", "offline_flag")
	if atomic.LoadInt32(&calls) != 0 {
		t.Fatalf("network calls = %d, want 0", calls)
	}
}

func TestResolveExplicitOnlineLiveMatch(t *testing.T) {
	key := testKey(3)
	var calls int32
	server := receiptKeyServer(t, key, http.StatusOK, &calls)
	defer server.Close()
	c := openTempCache(t)

	root, err := Resolve(providerID, key, ResolveOpts{
		CoordinatorHost: server.URL,
		HTTPClient:      server.Client(),
		Cache:           c,
		Now:             func() time.Time { return fixedNow },
	})
	if err != nil {
		t.Fatalf("Resolve: %v", err)
	}
	assertSource(t, root, SourceExplicit)
	assertNoWarning(t, root, "explicit_vs_live_divergence")
	if atomic.LoadInt32(&calls) != 1 {
		t.Fatalf("network calls = %d, want 1", calls)
	}
	if got, _, err := c.Lookup(serverHost(t, server), providerID, key); err != nil || got == nil {
		t.Fatalf("live success did not populate cache: got=%#v err=%v", got, err)
	}
}

func TestResolveExplicitOnlineLiveDiffers(t *testing.T) {
	explicit := testKey(4)
	live := testKey(5)
	var calls int32
	server := receiptKeyServer(t, live, http.StatusOK, &calls)
	defer server.Close()

	root, err := Resolve(providerID, explicit, ResolveOpts{
		CoordinatorHost: server.URL,
		HTTPClient:      server.Client(),
		Now:             func() time.Time { return fixedNow },
	})
	if err != nil {
		t.Fatalf("Resolve: %v", err)
	}
	assertSource(t, root, SourceExplicit)
	assertWarning(t, root, "explicit_vs_live_divergence", "live_pubkey", b64(live))
}

func TestResolveExplicitOnlineLiveUnreachable(t *testing.T) {
	server := receiptKeyServer(t, testKey(6), http.StatusOK, nil)
	client := server.Client()
	url := server.URL
	server.Close()

	root, err := Resolve(providerID, testKey(7), ResolveOpts{
		CoordinatorHost: url,
		HTTPClient:      client,
		Now:             func() time.Time { return fixedNow },
	})
	if err != nil {
		t.Fatalf("Resolve: %v", err)
	}
	assertSource(t, root, SourceExplicit)
	assertWarning(t, root, "live_check_skipped", "reason", "network_unreachable")
}

func TestResolveNoExplicitFreshCacheSkipsLive(t *testing.T) {
	var calls int32
	server := receiptKeyServer(t, testKey(8), http.StatusOK, &calls)
	defer server.Close()
	c := openTempCache(t)
	cached := testKey(9)
	if err := c.Put(serverHost(t, server), providerID, cache.ResolverResponse{ProviderID: providerID, ReceiptPubkey: cached}); err != nil {
		t.Fatalf("Put cache: %v", err)
	}

	root, err := Resolve(providerID, nil, ResolveOpts{
		CoordinatorHost: server.URL,
		HTTPClient:      server.Client(),
		Cache:           c,
		Now:             func() time.Time { return fixedNow },
	})
	if err != nil {
		t.Fatalf("Resolve: %v", err)
	}
	assertSource(t, root, SourceCache)
	if atomic.LoadInt32(&calls) != 0 {
		t.Fatalf("network calls = %d, want 0", calls)
	}
	if b64(root.Pubkey) != b64(cached) {
		t.Fatalf("root pubkey = %s, want cached %s", b64(root.Pubkey), b64(cached))
	}
}

func TestResolveNoExplicitNoCacheLiveSuccessWritesCache(t *testing.T) {
	live := testKey(10)
	var calls int32
	server := receiptKeyServer(t, live, http.StatusOK, &calls)
	defer server.Close()
	c := openTempCache(t)

	root, err := Resolve(providerID, nil, ResolveOpts{
		CoordinatorHost: server.URL,
		HTTPClient:      server.Client(),
		Cache:           c,
		Now:             func() time.Time { return fixedNow },
	})
	if err != nil {
		t.Fatalf("Resolve: %v", err)
	}
	assertSource(t, root, SourceLive)
	if atomic.LoadInt32(&calls) != 1 {
		t.Fatalf("network calls = %d, want 1", calls)
	}
	if got, fresh, err := c.Lookup(serverHost(t, server), providerID, live); err != nil || got == nil || !fresh {
		t.Fatalf("cache lookup after live got=%#v fresh=%v err=%v", got, fresh, err)
	}
}

func TestResolveNoExplicitStaleCacheLiveSuccessUsesLive(t *testing.T) {
	stale := testKey(11)
	live := testKey(12)
	var calls int32
	server := receiptKeyServer(t, live, http.StatusOK, &calls)
	defer server.Close()
	c := openTempCache(t)
	writeCacheEntry(t, c, serverHost(t, server), stale, fixedNow.Add(-8*24*time.Hour))

	root, err := Resolve(providerID, nil, ResolveOpts{
		CoordinatorHost: server.URL,
		HTTPClient:      server.Client(),
		Cache:           c,
		Now:             func() time.Time { return fixedNow },
	})
	if err != nil {
		t.Fatalf("Resolve: %v", err)
	}
	assertSource(t, root, SourceLive)
	if b64(root.Pubkey) != b64(live) {
		t.Fatalf("root pubkey = %s, want live %s", b64(root.Pubkey), b64(live))
	}
}

func TestResolveNoExplicitStaleCacheLiveFailureReturnsNone(t *testing.T) {
	server := receiptKeyServer(t, testKey(13), http.StatusInternalServerError, nil)
	defer server.Close()
	c := openTempCache(t)
	writeCacheEntry(t, c, serverHost(t, server), testKey(14), fixedNow.Add(-8*24*time.Hour))

	root, err := Resolve(providerID, nil, ResolveOpts{
		CoordinatorHost: server.URL,
		HTTPClient:      server.Client(),
		Cache:           c,
		Now:             func() time.Time { return fixedNow },
	})
	if err != nil {
		t.Fatalf("Resolve: %v", err)
	}
	assertSource(t, root, SourceNone)
	assertWarning(t, root, "live_check_skipped", "reason", "network_unreachable")
}

func TestResolveNoExplicitNoCacheLiveFailureReturnsNone(t *testing.T) {
	server := receiptKeyServer(t, testKey(15), http.StatusInternalServerError, nil)
	defer server.Close()

	root, err := Resolve(providerID, nil, ResolveOpts{
		CoordinatorHost: server.URL,
		HTTPClient:      server.Client(),
		Now:             func() time.Time { return fixedNow },
	})
	if err != nil {
		t.Fatalf("Resolve: %v", err)
	}
	assertSource(t, root, SourceNone)
	assertWarning(t, root, "live_check_skipped", "reason", "network_unreachable")
}

func TestResolveProviderNotInPool(t *testing.T) {
	server := receiptKeyServer(t, testKey(16), http.StatusNotFound, nil)
	defer server.Close()

	root, err := Resolve(providerID, nil, ResolveOpts{
		CoordinatorHost: server.URL,
		HTTPClient:      server.Client(),
		Now:             func() time.Time { return fixedNow },
	})
	if !errors.Is(err, ErrProviderNotInPool) {
		t.Fatalf("err = %v, want ErrProviderNotInPool", err)
	}
	assertSource(t, root, SourceNone)
}

func TestResolve429And5xxAreFetchFailuresNoRetry(t *testing.T) {
	for _, status := range []int{http.StatusTooManyRequests, http.StatusBadGateway} {
		t.Run(http.StatusText(status), func(t *testing.T) {
			var calls int32
			server := receiptKeyServer(t, testKey(byte(status)), status, &calls)
			defer server.Close()

			root, err := Resolve(providerID, nil, ResolveOpts{
				CoordinatorHost: server.URL,
				HTTPClient:      server.Client(),
				Now:             func() time.Time { return fixedNow },
			})
			if err != nil {
				t.Fatalf("Resolve: %v", err)
			}
			assertSource(t, root, SourceNone)
			assertWarning(t, root, "live_check_skipped", "reason", "network_unreachable")
			if atomic.LoadInt32(&calls) != 1 {
				t.Fatalf("network calls = %d, want 1", calls)
			}
		})
	}
}

func TestResolveRedirectOffHostFails(t *testing.T) {
	server := httptest.NewTLSServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		http.Redirect(w, r, "https://example.invalid/v1/receipt-keys/"+providerID, http.StatusFound)
	}))
	defer server.Close()

	root, err := Resolve(providerID, nil, ResolveOpts{
		CoordinatorHost: server.URL,
		HTTPClient:      server.Client(),
		Now:             func() time.Time { return fixedNow },
	})
	if err != nil {
		t.Fatalf("Resolve: %v", err)
	}
	assertSource(t, root, SourceNone)
	assertWarning(t, root, "live_check_skipped", "reason", "network_unreachable")
}

func TestResolveRedirectSameHostSucceeds(t *testing.T) {
	key := testKey(17)
	var calls int32
	server := httptest.NewTLSServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		atomic.AddInt32(&calls, 1)
		if r.URL.Query().Get("redirected") == "" {
			http.Redirect(w, r, "/v1/receipt-keys/"+providerID+"?redirected=1", http.StatusFound)
			return
		}
		writeResolverResponse(t, w, key)
	}))
	defer server.Close()

	root, err := Resolve(providerID, nil, ResolveOpts{
		CoordinatorHost: server.URL,
		HTTPClient:      server.Client(),
		Now:             func() time.Time { return fixedNow },
	})
	if err != nil {
		t.Fatalf("Resolve: %v", err)
	}
	assertSource(t, root, SourceLive)
	if atomic.LoadInt32(&calls) != 2 {
		t.Fatalf("network calls = %d, want initial+redirect", calls)
	}
}

func TestResolveNonDefaultCoordinatorWarningAllPaths(t *testing.T) {
	t.Run("explicit offline", func(t *testing.T) {
		root, err := Resolve(providerID, testKey(18), ResolveOpts{
			Offline:         true,
			CoordinatorHost: "https://custom.example",
			Now:             func() time.Time { return fixedNow },
		})
		if err != nil {
			t.Fatalf("Resolve: %v", err)
		}
		assertWarning(t, root, "non_default_coordinator", "coordinator_host", "custom.example")
	})
	t.Run("cache", func(t *testing.T) {
		c := openTempCache(t)
		if err := c.Put("custom.example", providerID, cache.ResolverResponse{ProviderID: providerID, ReceiptPubkey: testKey(19)}); err != nil {
			t.Fatalf("Put: %v", err)
		}
		root, err := Resolve(providerID, nil, ResolveOpts{
			CoordinatorHost: "https://custom.example",
			Cache:           c,
			Now:             func() time.Time { return fixedNow },
		})
		if err != nil {
			t.Fatalf("Resolve: %v", err)
		}
		assertSource(t, root, SourceCache)
		assertWarning(t, root, "non_default_coordinator", "coordinator_host", "custom.example")
	})
	t.Run("live", func(t *testing.T) {
		server := receiptKeyServer(t, testKey(20), http.StatusOK, nil)
		defer server.Close()
		root, err := Resolve(providerID, nil, ResolveOpts{
			CoordinatorHost: server.URL,
			HTTPClient:      server.Client(),
			Now:             func() time.Time { return fixedNow },
		})
		if err != nil {
			t.Fatalf("Resolve: %v", err)
		}
		assertSource(t, root, SourceLive)
		assertWarning(t, root, "non_default_coordinator", "coordinator_host", serverHost(t, server))
	})
	t.Run("none", func(t *testing.T) {
		root, err := Resolve(providerID, nil, ResolveOpts{
			Offline:         true,
			CoordinatorHost: "https://custom.example",
			Now:             func() time.Time { return fixedNow },
		})
		if err != nil {
			t.Fatalf("Resolve: %v", err)
		}
		assertSource(t, root, SourceNone)
		assertWarning(t, root, "non_default_coordinator", "coordinator_host", "custom.example")
	})
}

func TestResolveRejectsHTTPAndInvalidProviderID(t *testing.T) {
	if _, err := Resolve(providerID, nil, ResolveOpts{CoordinatorHost: "http://coordinator.example"}); !errors.Is(err, ErrInsecureScheme) {
		t.Fatalf("http coordinator err = %v, want ErrInsecureScheme", err)
	}
	for _, bad := range []string{"bad/id", "bad?query", ".."} {
		t.Run(bad, func(t *testing.T) {
			_, err := Resolve(bad, nil, ResolveOpts{
				CoordinatorHost: "https://coordinator.example",
				Now:             func() time.Time { return fixedNow },
			})
			if !errors.Is(err, ErrInvalidProviderID) {
				t.Fatalf("err = %v, want ErrInvalidProviderID", err)
			}
		})
	}
}

func TestResolveExplicitOnlineNoProviderIDSkipsLive(t *testing.T) {
	root, err := Resolve("", testKey(21), ResolveOpts{
		CoordinatorHost: "https://coordinator.streamvc.live",
		Now:             func() time.Time { return fixedNow },
	})
	if err != nil {
		t.Fatalf("Resolve: %v", err)
	}
	assertSource(t, root, SourceExplicit)
	assertWarning(t, root, "live_check_skipped", "reason", "provider_id_unresolvable")
}

func receiptKeyServer(t *testing.T, key []byte, status int, calls *int32) *httptest.Server {
	t.Helper()
	return httptest.NewTLSServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if calls != nil {
			atomic.AddInt32(calls, 1)
		}
		if r.Method != http.MethodGet {
			t.Fatalf("method = %s, want GET", r.Method)
		}
		if r.URL.Path != "/v1/receipt-keys/"+providerID {
			t.Fatalf("path = %s, want /v1/receipt-keys/%s", r.URL.Path, providerID)
		}
		if ua := r.Header.Get("User-Agent"); !strings.HasPrefix(ua, "macprovider-verify/") {
			t.Fatalf("User-Agent = %q, want macprovider-verify/<version>", ua)
		}
		if status != http.StatusOK {
			w.WriteHeader(status)
			_, _ = w.Write([]byte(`{"error":{"code":"provider_not_found"}}`))
			return
		}
		writeResolverResponse(t, w, key)
	}))
}

func writeResolverResponse(t *testing.T, w http.ResponseWriter, key []byte) {
	t.Helper()
	w.Header().Set("Content-Type", "application/json")
	if err := json.NewEncoder(w).Encode(map[string]any{
		"provider_id":         providerID,
		"receipt_pubkey":      b64(key),
		"receipt_pubkey_prev": nil,
		"fetched_at":          fixedNow.Format(time.RFC3339),
	}); err != nil {
		t.Fatalf("encode response: %v", err)
	}
}

func openTempCache(t *testing.T) *cache.Cache {
	t.Helper()
	c, err := cache.Open(filepath.Join(t.TempDir(), "verify-cache.jsonl"))
	if err != nil {
		t.Fatalf("cache Open: %v", err)
	}
	return c
}

func writeCacheEntry(t *testing.T, c *cache.Cache, coordinatorHost string, key []byte, fetchedAt time.Time) {
	t.Helper()
	line := map[string]any{
		"coordinator_host":    coordinatorHost,
		"provider_id":         providerID,
		"receipt_pubkey":      b64(key),
		"receipt_pubkey_prev": nil,
		"fetched_at":          fetchedAt.UTC().Format(time.RFC3339),
	}
	data, err := json.Marshal(line)
	if err != nil {
		t.Fatalf("marshal cache line: %v", err)
	}
	if err := osWriteFile(c.Path(), append(data, '\n')); err != nil {
		t.Fatalf("write cache line: %v", err)
	}
}

func serverHost(t *testing.T, server *httptest.Server) string {
	t.Helper()
	parsed, err := url.Parse(server.URL)
	if err != nil {
		t.Fatalf("parse server URL: %v", err)
	}
	return parsed.Host
}

func osWriteFile(path string, data []byte) error {
	return os.WriteFile(path, data, 0o600)
}

func testKey(seed byte) []byte {
	key := make([]byte, 32)
	for i := range key {
		key[i] = seed + byte(i)
	}
	return key
}

func b64(raw []byte) string {
	return base64.StdEncoding.EncodeToString(raw)
}

func assertSource(t *testing.T, root ResolvedRoot, want Source) {
	t.Helper()
	if root.TrustSource != want {
		t.Fatalf("TrustSource = %s, want %s (root=%#v)", root.TrustSource, want, root)
	}
}

func assertWarning(t *testing.T, root ResolvedRoot, kind, field string, want any) {
	t.Helper()
	for _, warning := range root.Warnings {
		if warning.Kind == kind && warning.Fields[field] == want {
			return
		}
	}
	t.Fatalf("missing warning %s with %s=%v in %#v", kind, field, want, root.Warnings)
}

func assertNoWarning(t *testing.T, root ResolvedRoot, kind string) {
	t.Helper()
	for _, warning := range root.Warnings {
		if warning.Kind == kind {
			t.Fatalf("unexpected warning %s in %#v", kind, root.Warnings)
		}
	}
}
