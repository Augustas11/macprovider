package buyer

import (
	"crypto/ed25519"
	"crypto/sha256"
	"encoding/hex"
	"errors"
	"fmt"
	"io/fs"
	"net/http"
	"os"
	"path/filepath"
	"sort"
	"strings"
	"unicode/utf8"

	"github.com/augstar/macprovider-coordinator/internal/config"
)

// SPEC-023 §3.8 (SPEC-023-R028): the signed release manifest. `release.json`
// binds every feed of a catalog release by digest; `release.json.sig` is one
// detached Ed25519 signature over its exact bytes. Both sit in the release
// directory beside the candidate feed. A release cut before §3.8 carries no
// signature: the routes then answer 404 and the per-feed sidecars remain the
// only authentication, exactly as before.
const (
	releaseManifestFileName    = "release.json"
	releaseManifestSigFileName = "release.json.sig"
	releaseManifestSchema      = "macprovider.autotune-release.v1"
	releaseManifestTier2Feed   = "tier2-catalog.json"
	maxReleaseManifestBytes    = 256 << 10
)

type releaseManifestEntry struct {
	Bytes       *int64 `json:"bytes"`
	SHA256      string `json:"sha256"`
	SignerKeyID string `json:"signer_key_id"`
	Version     string `json:"version"`
}

type releaseManifestDocument struct {
	Feeds         map[string]releaseManifestEntry `json:"feeds"`
	GeneratedAt   string                          `json:"generated_at"`
	PolicyVersion string                          `json:"policy_version"`
	ReleaseID     string                          `json:"release_id"`
	SchemaVersion string                          `json:"schema_version"`
}

// servedReleaseFeed is one feed the coordinator serves, named as release.json
// names it, with the signer its per-feed sidecar proved.
type servedReleaseFeed struct {
	name   string
	body   []byte
	signer string
}

func (f AutotuneFeeds) releaseManifestEnabled() bool {
	return len(f.ReleaseManifestJSON) > 0 && len(f.ReleaseManifestSig) > 0
}

// loadReleaseManifest reads and verifies the release directory's signed
// manifest. Absent signature: nil, nil (a pre-§3.8 release). Present: the
// signature must verify under the static-feed keyring from the candidate
// catalog's signer, the manifest must be the candidate catalog's release, and
// every served feed must match its manifest entry by sha256, bytes and
// signer. Any mismatch fails the load closed so the coordinator never serves
// a manifest that disagrees with the bytes beside it.
func loadReleaseManifest(
	cfg config.AutotuneFeedsConfig,
	keyring map[string]ed25519.PublicKey,
	candidates loadedAutotuneFeed,
	served []servedReleaseFeed,
) (manifestJSON, manifestSig []byte, err error) {
	candidatePath := strings.TrimSpace(cfg.AutotuneCandidatesPath)
	if candidatePath == "" || !candidates.enabled() {
		return nil, nil, nil
	}
	dir := filepath.Dir(candidatePath)
	sigPath := filepath.Join(dir, releaseManifestSigFileName)
	sigBytes, err := os.ReadFile(sigPath)
	if errors.Is(err, fs.ErrNotExist) {
		return nil, nil, nil
	}
	if err != nil {
		return nil, nil, fmt.Errorf("read %s: %w", releaseManifestSigFileName, err)
	}
	manifestBytes, err := os.ReadFile(filepath.Join(dir, releaseManifestFileName))
	if err != nil {
		return nil, nil, fmt.Errorf("%s is present but %s is unreadable: %w", releaseManifestSigFileName, releaseManifestFileName, err)
	}
	if len(sigBytes) == 0 || len(sigBytes) > maxAutotuneSidecarBytes || !utf8.Valid(sigBytes) {
		return nil, nil, fmt.Errorf("%s must be non-empty UTF-8 of at most %d bytes", releaseManifestSigFileName, maxAutotuneSidecarBytes)
	}
	if len(manifestBytes) == 0 || len(manifestBytes) > maxReleaseManifestBytes || !utf8.Valid(manifestBytes) {
		return nil, nil, fmt.Errorf("%s must be non-empty UTF-8 of at most %d bytes", releaseManifestFileName, maxReleaseManifestBytes)
	}
	sidecar, signature, err := parseAutotuneSidecar(sigBytes)
	if err != nil {
		return nil, nil, fmt.Errorf("%s: %w", releaseManifestSigFileName, err)
	}
	publicKey, ok := keyring[sidecar.KeyID]
	if !ok {
		return nil, nil, fmt.Errorf("%s uses unknown key_id %q", releaseManifestSigFileName, sidecar.KeyID)
	}
	if !ed25519.Verify(publicKey, manifestBytes, signature) {
		return nil, nil, fmt.Errorf("%s signature verification failed", releaseManifestSigFileName)
	}
	if sidecar.KeyID != candidates.verification.KeyID {
		return nil, nil, fmt.Errorf("%s signer key_id %q != autotune_candidates signer key_id %q", releaseManifestSigFileName, sidecar.KeyID, candidates.verification.KeyID)
	}
	entries, err := parseReleaseManifest(manifestBytes, sidecar.KeyID, candidates)
	if err != nil {
		return nil, nil, err
	}
	for _, feed := range served {
		entry, ok := entries[feed.name]
		if !ok {
			return nil, nil, fmt.Errorf("%s does not bind served feed %s", releaseManifestFileName, feed.name)
		}
		digest := sha256.Sum256(feed.body)
		if *entry.Bytes != int64(len(feed.body)) || entry.SHA256 != hex.EncodeToString(digest[:]) {
			return nil, nil, fmt.Errorf("%s binding for %s does not match the served bytes", releaseManifestFileName, feed.name)
		}
		if entry.SignerKeyID != feed.signer {
			return nil, nil, fmt.Errorf("%s binds %s to signer %q but its sidecar is signed by %q", releaseManifestFileName, feed.name, entry.SignerKeyID, feed.signer)
		}
	}
	return append([]byte(nil), manifestBytes...), append([]byte(nil), sigBytes...), nil
}

func parseReleaseManifest(raw []byte, signer string, candidates loadedAutotuneFeed) (map[string]releaseManifestEntry, error) {
	var doc releaseManifestDocument
	if err := decodeStrictJSON(raw, &doc); err != nil {
		return nil, fmt.Errorf("%s schema: %w", releaseManifestFileName, err)
	}
	if doc.SchemaVersion != releaseManifestSchema {
		return nil, fmt.Errorf("%s schema_version %q != %q", releaseManifestFileName, doc.SchemaVersion, releaseManifestSchema)
	}
	if doc.ReleaseID != candidates.verification.Version {
		return nil, fmt.Errorf("%s release_id %q != autotune_candidates version %q", releaseManifestFileName, doc.ReleaseID, candidates.verification.Version)
	}
	if doc.PolicyVersion != candidates.verification.PolicyVersion {
		return nil, fmt.Errorf("%s policy_version %q != autotune_candidates policy_version %q", releaseManifestFileName, doc.PolicyVersion, candidates.verification.PolicyVersion)
	}
	if strings.TrimSpace(doc.GeneratedAt) == "" || len(doc.Feeds) == 0 {
		return nil, fmt.Errorf("%s requires generated_at and feeds", releaseManifestFileName)
	}
	names := make([]string, 0, len(doc.Feeds))
	for name := range doc.Feeds {
		names = append(names, name)
	}
	sort.Strings(names)
	for _, name := range names {
		entry := doc.Feeds[name]
		if entry.Bytes == nil || *entry.Bytes <= 0 || !lowerHex64Pattern.MatchString(entry.SHA256) ||
			strings.TrimSpace(entry.SignerKeyID) == "" || strings.TrimSpace(entry.Version) == "" {
			return nil, fmt.Errorf("%s feed %s needs bytes, a lowercase sha256, signer_key_id and version", releaseManifestFileName, name)
		}
		// One signature stands for every static feed, so each must name the
		// manifest signer. The Tier-2 catalog keeps its own Tier-2 signer.
		if name != releaseManifestTier2Feed && entry.SignerKeyID != signer {
			return nil, fmt.Errorf("%s binds %s to signer %q, not the manifest signer %q", releaseManifestFileName, name, entry.SignerKeyID, signer)
		}
	}
	return doc.Feeds, nil
}

func (s *Server) handleCatalogRelease(w http.ResponseWriter, r *http.Request) {
	feeds := s.autotuneFeedsSnapshot()
	s.serveAutotuneFeedBytes(w, r, feeds.ReleaseManifestJSON, feeds.releaseManifestEnabled())
}

func (s *Server) handleCatalogReleaseSig(w http.ResponseWriter, r *http.Request) {
	feeds := s.autotuneFeedsSnapshot()
	s.serveAutotuneFeedBytes(w, r, feeds.ReleaseManifestSig, feeds.releaseManifestEnabled())
}
