package main

import (
	"bytes"
	"errors"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"

	"github.com/augstar/macprovider-coordinator/internal/buyer"
	"github.com/augstar/macprovider-coordinator/internal/pool"
	"github.com/augstar/macprovider-coordinator/internal/tier2"
	"github.com/rs/zerolog"
)

// writeRejectedReleaseManifest writes a release.json that verifies under the
// release signer but is not a valid manifest (SPEC-023 §3.8).
func writeRejectedReleaseManifest(t *testing.T, dir string) {
	t.Helper()
	writeValidatorSigned(t, filepath.Join(dir, "release.json"), []byte(`{"schema_version":"macprovider.autotune-release.v1"}`))
}

func TestBootTreatsRejectedReleaseManifestAsAbsent(t *testing.T) {
	liveRoot := t.TempDir()
	current := filepath.Join(liveRoot, "current")
	_, _, tier2Pub := writeValidatorRelease(t, current, "release-live", reloadTestHash)
	writeRejectedReleaseManifest(t, current)
	cfg := validatorConfig(liveRoot, tier2Pub)

	var logs bytes.Buffer
	feeds, err := loadBootAutotuneFeeds(cfg.AutotuneFeeds, zerolog.New(&logs))
	if err != nil {
		t.Fatalf("boot load must not fail on a rejected manifest: %v", err)
	}
	if len(feeds.AutotuneCandidatesJSON) == 0 || len(feeds.ReleaseManifestJSON) != 0 || len(feeds.ReleaseManifestSig) != 0 {
		t.Fatalf("boot feeds: candidates=%d manifest=%d sig=%d", len(feeds.AutotuneCandidatesJSON), len(feeds.ReleaseManifestJSON), len(feeds.ReleaseManifestSig))
	}
	if !strings.Contains(logs.String(), `"level":"error"`) || !strings.Contains(logs.String(), "release manifest rejected") ||
		!strings.Contains(logs.String(), "SIGHUP reload of this release stays rejected until the release manifest is fixed") {
		t.Fatalf("boot did not log the rejection: %s", logs.String())
	}
	for path, want := range map[string]int{
		"/v1/catalog-release":         http.StatusNotFound,
		"/v1/catalog-release.sig":     http.StatusNotFound,
		"/v1/autotune-candidates":     http.StatusOK,
		"/v1/autotune-candidates.sig": http.StatusOK,
	} {
		server := buyer.NewServer(pool.NewRegistry(nil), zerolog.Nop(), time.Unix(1716768000, 0), buyer.WithAutotuneFeeds(feeds))
		rr := httptest.NewRecorder()
		server.Handler().ServeHTTP(rr, httptest.NewRequest(http.MethodGet, path, nil))
		if rr.Code != want {
			t.Fatalf("%s status=%d want %d", path, rr.Code, want)
		}
	}
}

func TestBootStillFailsOnNonManifestFeedError(t *testing.T) {
	liveRoot := t.TempDir()
	current := filepath.Join(liveRoot, "current")
	_, _, tier2Pub := writeValidatorRelease(t, current, "release-live", reloadTestHash)
	writeRejectedReleaseManifest(t, current)
	if err := os.WriteFile(filepath.Join(current, "demand-rank.json"), []byte(`{}`), 0o600); err != nil {
		t.Fatal(err)
	}
	_, err := loadBootAutotuneFeeds(validatorConfig(liveRoot, tier2Pub).AutotuneFeeds, zerolog.Nop())
	var rejected *buyer.ReleaseManifestError
	if err == nil || errors.As(err, &rejected) {
		t.Fatalf("boot load error=%v, want a fatal non-manifest feed error", err)
	}
}

func TestReloadAndDryLoadRejectRejectedReleaseManifest(t *testing.T) {
	defer tier2.ResetForTest()
	base := t.TempDir()
	dir := filepath.Join(base, "candidate")
	_, _, tier2Pub := writeValidatorRelease(t, dir, "release-next", reloadTestHash)
	writeRejectedReleaseManifest(t, dir)

	// The SIGHUP reload loads through loadAutotuneCatalogForReload.
	cfg := validatorConfig(base, tier2Pub)
	redirectAutotuneReleasePaths(&cfg, dir)
	_, _, _, err := loadAutotuneCatalogForReload(cfg.AutotuneFeeds)
	var rejected *buyer.ReleaseManifestError
	if !errors.As(err, &rejected) {
		t.Fatalf("reload load error=%v, want *buyer.ReleaseManifestError", err)
	}

	got := validateAutotuneRelease(writeReloadConfig(t, validatorConfig(filepath.Join(base, "live"), tier2Pub)), "", dir, "", zerolog.Nop())
	assertValidatorError(t, got, "release manifest rejected")
}
