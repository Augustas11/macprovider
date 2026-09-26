package main

import (
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"fmt"
	"io"
	"os"
	"path/filepath"
	"strings"

	"github.com/augstar/macprovider-coordinator/internal/autotune"
	"github.com/augstar/macprovider-coordinator/internal/billing"
	"github.com/augstar/macprovider-coordinator/internal/buyer"
	"github.com/augstar/macprovider-coordinator/internal/config"
	"github.com/augstar/macprovider-coordinator/internal/tier2"
	"github.com/augstar/macprovider-coordinator/internal/ws"
	"github.com/rs/zerolog"
)

// autotuneReleaseValidation is the one-line JSON verdict printed by
// --validate-autotune-release. Slices are always non-nil so consumers see [].
type autotuneReleaseValidation struct {
	OK               bool   `json:"ok"`
	ReleaseID        string `json:"release_id"`
	CandidatesSHA256 string `json:"candidates_sha256"`
	Tier2CatalogID   string `json:"tier2_catalog_id"`
	Tier2SHA256      string `json:"tier2_sha256"`
	// ConfigSHA256 / OverlaySHA256 are the sha256 of the exact config and
	// overlay bytes this dry-load decoded ("" when not loaded / no overlay).
	ConfigSHA256   string               `json:"config_sha256"`
	OverlaySHA256  string               `json:"overlay_sha256"`
	PreviousLoaded []autotuneReleaseRef `json:"previous_loaded"`
	// Admitted is exactly the set of catalogs a provider hello can match
	// after this release reloads: the release itself, every retained
	// previous-target entry, and same-version restamps, as the ws admission
	// map keeps them (tombstones and current-duplicates dropped). Empty
	// whenever ok is false: a reload that fails admits nothing new.
	Admitted []autotuneAdmittedRef `json:"admitted"`
	// RateTableSHA256 is billing.RateTableDigest of the effective config: the
	// sha256 of the rate_card_json the reload's billing snapshot would store.
	// SignedRateCardSHA256 is the sha256 of the release's rate-card feed body
	// ("" for a release without one). Both "" when not loaded.
	RateTableSHA256      string `json:"rate_table_sha256"`
	SignedRateCardSHA256 string `json:"signed_rate_card_sha256"`
	// ModelResolutions answers --resolve-model-names; [] otherwise.
	ModelResolutions []autotuneModelResolution `json:"model_resolutions"`
	Errors           []string                  `json:"errors"`
	Notes            []string                  `json:"notes"`
}

type autotuneAdmittedRef struct {
	ReleaseID        string `json:"release_id"`
	CandidatesSHA256 string `json:"candidates_sha256"`
	Source           string `json:"source"`
}

type autotuneReleaseRef struct {
	ReleaseID        string `json:"release_id"`
	CandidatesSHA256 string `json:"candidates_sha256"`
}

// validateAutotuneReleaseBoundaryNote names the SIGHUP reload steps the
// offline validator deliberately does not run: each needs the running
// process's state or a database, which the validator must never touch.
const validateAutotuneReleaseBoundaryNote = "not checked (needs the live process or a database): tier2 startup-only field drift vs the running process, proof_of_weights telemetry-drift/hello-gate evidence store, trusted_pools creator admin credentials, billing config snapshot write"

func runValidateAutotuneRelease(out io.Writer, configPath, configOverlay, dir, previousTarget string, opts autotuneReleaseValidationOptions) int {
	result := validateAutotuneRelease(configPath, configOverlay, dir, previousTarget, zerolog.New(os.Stderr), opts)
	raw, err := json.Marshal(result)
	if err != nil {
		fmt.Fprintf(os.Stderr, "validate-autotune-release: encode result: %v\n", err)
		return 1
	}
	fmt.Fprintln(out, string(raw))
	if !result.OK {
		return 1
	}
	return 0
}

// validateAutotuneRelease loads the config as a SIGHUP reload does, redirects
// every configured feed path and the Tier-2 catalog path into dir, and runs
// the reload's own load/verify functions against it. It starts no server,
// opens no database, and never publishes into the tier2 singleton.
func validateAutotuneRelease(configPath, configOverlay, dir, previousTarget string, logger zerolog.Logger, opts ...autotuneReleaseValidationOptions) autotuneReleaseValidation {
	r := autotuneReleaseValidation{PreviousLoaded: []autotuneReleaseRef{}, Admitted: []autotuneAdmittedRef{}, ModelResolutions: []autotuneModelResolution{}, Errors: []string{}, Notes: []string{}}
	fail := func(format string, args ...any) { r.Errors = append(r.Errors, fmt.Sprintf(format, args...)) }

	cfg, digests, err := config.LoadForSIGHUPReloadWithOverlayDigests(configPath, configOverlay)
	if err != nil {
		fail("config: %v", err)
		return r
	}
	r.ConfigSHA256, r.OverlaySHA256 = digests.ConfigSHA256, digests.OverlaySHA256
	if digest, err := billing.RateTableDigest(cfg.Rewards); err != nil {
		fail("rate table digest: %v", err)
	} else {
		r.RateTableSHA256 = digest
	}
	if info, err := os.Stat(dir); err != nil || !info.IsDir() {
		fail("release dir %q is not a readable directory", dir)
		return r
	}
	if strings.TrimSpace(cfg.AutotuneFeeds.AutotuneCandidatesPath) == "" {
		fail("config has no autotune.autotune_candidates_path; a SIGHUP reload would keep the live catalog")
		return r
	}
	if strings.TrimSpace(cfg.Tier2.CatalogPath) == "" {
		fail("config has no tier2.catalog_path; the release's Tier-2 catalog would not be loaded")
	}
	redirectAutotuneReleasePaths(&cfg, dir)
	if strings.TrimSpace(cfg.AutotuneFeeds.CatalogArtifactsPath) == "" {
		if _, err := os.Stat(filepath.Join(dir, "autotune-artifacts.json")); err == nil {
			r.Notes = append(r.Notes, "release dir has autotune-artifacts.json but config sets no autotune.catalog_artifacts_path; a SIGHUP reload serves this release rate-card-bound")
		}
	}
	if previousTarget == "" {
		cfg.AutotuneFeeds.PreviousTargetPath = os.DevNull
		r.Notes = append(r.Notes, "no --previous-target: validated with no retained previous releases and no restamp scan")
	} else {
		cfg.AutotuneFeeds.PreviousTargetPath = previousTarget
		r.Notes = append(r.Notes, fmt.Sprintf("retained releases resolved from %s relative to %s", previousTarget, filepath.Dir(previousTarget)))
	}

	feeds, catalog, compatible, err := loadAutotuneCatalogForReload(cfg.AutotuneFeeds)
	if err != nil {
		fail("autotune feed reload: %v", err)
		return r
	}
	r.ReleaseID = catalog.Version
	r.CandidatesSHA256 = catalog.SHA256
	if len(feeds.RateCardJSON) > 0 {
		sum := sha256.Sum256(feeds.RateCardJSON)
		r.SignedRateCardSHA256 = hex.EncodeToString(sum[:])
	}
	for _, previous := range compatible {
		r.PreviousLoaded = append(r.PreviousLoaded, autotuneReleaseRef{ReleaseID: previous.Version, CandidatesSHA256: previous.SHA256})
	}
	// loadCompatibleAutotuneCatalogs returns the previous-target entries
	// first (all of them, or an error), then the restamp leftovers.
	retainedDirs, err := buyer.PreviousAutotuneReleaseTargets(cfg.AutotuneFeeds)
	if err != nil {
		fail("retained previous release targets: %v", err)
	}
	admitted := admittedAutotuneCatalogs(catalog, compatible, len(retainedDirs))
	// The release-published observer degrades (warns) on these at SIGHUP;
	// before activation every retained entry must load, so they fail here.
	previousFeeds, err := buyer.LoadPreviousAutotuneFeeds(cfg.AutotuneFeeds)
	if err != nil {
		fail("retained previous release feeds: %v", err)
	}
	if _, errs := buyer.BuildArtifactIdentitySets(feeds, previousFeeds); len(errs) > 0 {
		for _, err := range errs {
			fail("artifact identity set: %v", err)
		}
	}
	if err := validateAutotuneRuntimeEconomics(feeds, cfg); err != nil {
		fail("autotune runtime economics: %v", err)
	}
	for _, o := range opts {
		validatePricingRelease(&r, o, configPath, configOverlay, cfg, feeds)
	}
	next, err := tier2.BuildStrict(cfg.Tier2, logger, activeReleaseBindingGuard(catalog))
	if err != nil {
		fail("tier2: %v", err)
	} else {
		r.Tier2CatalogID, r.Tier2SHA256 = tier2CatalogIdentity(next)
		if r.Tier2CatalogID == "" {
			fail("tier2: no active catalog loaded (unset, expired, or failed to load)")
		}
	}
	r.Notes = append(r.Notes, validateAutotuneReleaseBoundaryNote)
	r.OK = len(r.Errors) == 0
	if r.OK {
		r.Admitted = admitted
	}
	return r
}

// admittedAutotuneCatalogs lists current plus every compatible catalog the ws
// admission map (ws.CompatibleCatalogSet, the map a reload installs) reaches
// by candidate sha, the key a provider hello must match. compatible[:retained]
// came from .previous-target; RowContinuityOnly entries came from
// .row-continuity-target and admit only an unchanged selected row
// (SPEC-023-R010); the rest are same-version restamps.
func admittedAutotuneCatalogs(current *autotune.Catalog, compatible []*autotune.Catalog, retained int) []autotuneAdmittedRef {
	currentSHA := strings.ToLower(strings.TrimSpace(current.SHA256))
	out := []autotuneAdmittedRef{{ReleaseID: current.Version, CandidatesSHA256: currentSHA, Source: "current"}}
	set := ws.CompatibleCatalogSet(current, compatible)
	seen := map[string]bool{currentSHA: true}
	for i, c := range compatible {
		if c == nil {
			continue
		}
		sha := strings.ToLower(strings.TrimSpace(c.SHA256))
		if seen[sha] || set[sha] == nil {
			continue
		}
		seen[sha] = true
		source := "restamp"
		if i < retained {
			source = "retained"
		} else if c.RowContinuityOnly {
			source = "row_continuity"
		}
		out = append(out, autotuneAdmittedRef{ReleaseID: set[sha].Version, CandidatesSHA256: sha, Source: source})
	}
	return out
}

// redirectAutotuneReleasePaths points every configured feed path, and the
// Tier-2 catalog path, at the same file name inside dir. Unconfigured paths
// stay unset so the feed set shape is exactly what the live config reloads.
func redirectAutotuneReleasePaths(cfg *config.Config, dir string) {
	redirect := func(p *string) {
		if strings.TrimSpace(*p) != "" {
			*p = filepath.Join(dir, filepath.Base(*p))
		}
	}
	feeds := &cfg.AutotuneFeeds
	for _, p := range []*string{
		&feeds.RateCardPath, &feeds.RateCardSigPath,
		&feeds.DemandRankPath, &feeds.DemandRankSigPath,
		&feeds.AutotuneCandidatesPath, &feeds.AutotuneCandidatesSigPath,
		&feeds.CatalogArtifactsPath, &feeds.CatalogArtifactsSigPath,
		&cfg.Tier2.CatalogPath,
	} {
		redirect(p)
	}
}
