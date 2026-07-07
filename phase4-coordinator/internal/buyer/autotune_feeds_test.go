package buyer_test

import (
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"

	"github.com/augstar/macprovider-coordinator/internal/buyer"
	"github.com/augstar/macprovider-coordinator/internal/config"
	"github.com/augstar/macprovider-coordinator/internal/pool"
	"github.com/rs/zerolog"
)

func TestAutotuneFeedsServeLiteralSignedBytes(t *testing.T) {
	t.Parallel()
	staticDir := filepath.Join("..", "..", "..", "phase3-binary", "dist", "static")
	demandJSON, err := os.ReadFile(filepath.Join(staticDir, "demand-rank.json"))
	if err != nil {
		t.Fatalf("read demand-rank.json: %v", err)
	}
	demandSig, err := os.ReadFile(filepath.Join(staticDir, "demand-rank.json.sig"))
	if err != nil {
		t.Fatalf("read demand-rank.json.sig: %v", err)
	}
	candidatesJSON, err := os.ReadFile(filepath.Join(staticDir, "autotune-candidates.json"))
	if err != nil {
		t.Fatalf("read autotune-candidates.json: %v", err)
	}
	candidatesSig, err := os.ReadFile(filepath.Join(staticDir, "autotune-candidates.json.sig"))
	if err != nil {
		t.Fatalf("read autotune-candidates.json.sig: %v", err)
	}

	feeds, err := buyer.LoadAutotuneFeeds(config.AutotuneFeedsConfig{
		DemandRankPath:            filepath.Join(staticDir, "demand-rank.json"),
		DemandRankSigPath:         filepath.Join(staticDir, "demand-rank.json.sig"),
		AutotuneCandidatesPath:    filepath.Join(staticDir, "autotune-candidates.json"),
		AutotuneCandidatesSigPath: filepath.Join(staticDir, "autotune-candidates.json.sig"),
	})
	if err != nil {
		t.Fatalf("LoadAutotuneFeeds: %v", err)
	}

	server := buyer.NewServer(
		pool.NewRegistry(nil),
		zerolog.Nop(),
		time.Unix(1716768000, 0),
		buyer.WithAutotuneFeeds(feeds),
	)
	handler := server.Handler()

	cases := []struct {
		path string
		want []byte
	}{
		{"/v1/demand-rank", demandJSON},
		{"/v1/demand-rank.sig", demandSig},
		{"/v1/autotune-candidates", candidatesJSON},
		{"/v1/autotune-candidates.sig", candidatesSig},
	}
	for _, tc := range cases {
		tc := tc
		t.Run(tc.path, func(t *testing.T) {
			t.Parallel()
			req := httptest.NewRequest(http.MethodGet, tc.path, nil)
			rr := httptest.NewRecorder()
			handler.ServeHTTP(rr, req)
			if rr.Code != http.StatusOK {
				t.Fatalf("status=%d body=%s", rr.Code, rr.Body.String())
			}
			if got := rr.Body.Bytes(); string(got) != string(tc.want) {
				t.Fatalf("body mismatch: got %d bytes want %d bytes", len(got), len(tc.want))
			}
			if cc := rr.Header().Get("Cache-Control"); cc != "public, max-age=300" {
				t.Fatalf("Cache-Control=%q", cc)
			}
		})
	}
}

func TestAutotuneFeedsDisabledWhenUnset(t *testing.T) {
	t.Parallel()
	server := buyer.NewServer(pool.NewRegistry(nil), zerolog.Nop(), time.Unix(1716768000, 0))
	handler := server.Handler()

	for _, path := range []string{
		"/v1/demand-rank",
		"/v1/demand-rank.sig",
		"/v1/autotune-candidates",
		"/v1/autotune-candidates.sig",
	} {
		req := httptest.NewRequest(http.MethodGet, path, nil)
		rr := httptest.NewRecorder()
		handler.ServeHTTP(rr, req)
		if rr.Code != http.StatusNotFound {
			t.Fatalf("%s status=%d want 404", path, rr.Code)
		}
	}
}

func TestNginxAutotuneFeedsAllowThroughBeforeV1CatchAll(t *testing.T) {
	t.Parallel()
	b, err := os.ReadFile(filepath.Join("..", "..", "dist", "nginx-coordinator.streamvc.live.conf"))
	if err != nil {
		t.Fatalf("read nginx config: %v", err)
	}
	cfg := string(b)
	catchAll := strings.Index(cfg, "location /v1/ {\n        return 404;")
	if catchAll < 0 {
		t.Fatalf("/v1/ 404 catch-all missing")
	}
	beforeCatchAll := cfg[:catchAll]
	for _, location := range []string{
		"location = /v1/rate-card",
		"location = /v1/demand-rank",
		"location = /v1/demand-rank.sig",
		"location = /v1/autotune-candidates",
		"location = /v1/autotune-candidates.sig",
	} {
		if !strings.Contains(beforeCatchAll, location) {
			t.Fatalf("%s missing before /v1/ catch-all", location)
		}
	}
	if strings.Contains(beforeCatchAll, "location /static/") {
		t.Fatalf("legacy /static/ nginx alias should be removed")
	}
}
