package buyer_test

import (
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"
	"time"

	"github.com/augstar/macprovider-coordinator/internal/buyer"
	"github.com/augstar/macprovider-coordinator/internal/config"
	"github.com/augstar/macprovider-coordinator/internal/pool"
	"github.com/augstar/macprovider-coordinator/internal/routing"
	"github.com/rs/zerolog"
)

// SPEC-002-R005 through the real chat handler: a request pinned with
// X-MacProvider-Provider or X-MacProvider-Session records no observation,
// and the same request unpinned does.
func TestPinnedChatRequestRecordsNoPerformance(t *testing.T) {
	content := strings.Repeat("x", 400)
	for _, tc := range []struct {
		name       string
		header     string
		value      string
		wantRecord bool
	}{
		{"unpinned", "", "", true},
		{"provider pin", "X-MacProvider-Provider", "p1", false},
		{"session pin", "X-MacProvider-Session", "s1", false},
	} {
		t.Run(tc.name, func(t *testing.T) {
			upstream := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
				w.Header().Set("Content-Type", "text/event-stream")
				w.WriteHeader(http.StatusOK)
				f, _ := w.(http.Flusher)
				_, _ = w.Write([]byte(`data: {"id":"c","choices":[{"delta":{"content":"` + content + `"}}]}` + "\n\n"))
				f.Flush()
				time.Sleep(20 * time.Millisecond)
				_, _ = w.Write([]byte(`data: {"id":"c","choices":[{"delta":{"content":"` + content + `"}}]}` + "\n\n"))
				_, _ = w.Write([]byte("data: [DONE]\n\n"))
			}))
			defer upstream.Close()
			reqLog, _ := openBuyerRequestLog(t)
			defer reqLog.Close()
			registry := pool.NewRegistry([]config.ProviderConfig{{ProviderID: "p1", EndpointURL: upstream.URL}})
			registerWithEndpoint(registry, "p1", "s1", "model-a", pool.StateReady, 20000, 1, upstream.URL, 20)
			store := routing.NewPerfStore()
			server := buyer.NewServer(registry, zerolog.Nop(), time.Unix(1716768000, 0),
				buyer.WithRequestLog(reqLog),
				buyer.WithPerfStore(store),
			)
			headers := http.Header{}
			if tc.header != "" {
				headers.Set(tc.header, tc.value)
			}
			rr := postChat(t, server, []byte(`{"model":"model-a","messages":[{"role":"user","content":"hello"}],"stream":true}`), headers)
			if rr.Code != http.StatusOK || rr.Header().Get("X-MacProvider-Provider") != "p1" {
				t.Fatalf("status=%d provider=%q body=%s", rr.Code, rr.Header().Get("X-MacProvider-Provider"), rr.Body.String())
			}
			if got := store.Len() > 0; got != tc.wantRecord {
				t.Fatalf("recorded=%v, want %v", got, tc.wantRecord)
			}
		})
	}
}
