package buyer

import (
	"bytes"
	"crypto/ed25519"
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"errors"
	"fmt"
	"io/fs"
	"net/http"
	"os"
	"path/filepath"
	"slices"
	"sort"
	"strconv"
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
	// The manifest and its signature must change together at a release
	// rollover, so neither may be served from a stale cache.
	releaseManifestCacheControl = "no-cache"
)

type releaseManifestEntry struct {
	Bytes       int64
	SHA256      string
	SignerKeyID string
	Version     string
}

// The closed key sets of release.json, matching scripts/catalog-release.py
// manifest() and the CLI parser: every key is required, none is optional.
var (
	releaseManifestTopLevelKeys = []string{"feeds", "generated_at", "policy_version", "release_id", "schema_version"}
	releaseManifestEntryKeys    = []string{"bytes", "sha256", "signer_key_id", "version"}
)

// ReleaseManifestError is a rejected signed release manifest: present but
// malformed, unverifiable, or disagreeing with the feeds served beside it.
// Every load fails closed on it unless the caller passes
// DropRejectedReleaseManifest (coordinator boot only).
type ReleaseManifestError struct {
	Err error
}

func (e *ReleaseManifestError) Error() string { return "release manifest rejected: " + e.Err.Error() }

func (e *ReleaseManifestError) Unwrap() error { return e.Err }

// AutotuneFeedsLoadOption adjusts LoadAutotuneFeeds.
type AutotuneFeedsLoadOption func(*autotuneFeedsLoadOptions)

type autotuneFeedsLoadOptions struct {
	dropRejectedReleaseManifest bool
	onDroppedReleaseManifest    func(*ReleaseManifestError)
}

// DropRejectedReleaseManifest treats a rejected release manifest as absent:
// the feeds load, the /v1/catalog-release routes answer 404 and CLIs fall
// back to the per-feed sidecars. onDrop (may be nil) receives the rejection.
// Only coordinator boot uses it, so a bad manifest never keeps the
// coordinator down; the release dry-load and the SIGHUP reload stay
// fail-closed.
func DropRejectedReleaseManifest(onDrop func(*ReleaseManifestError)) AutotuneFeedsLoadOption {
	return func(o *autotuneFeedsLoadOptions) {
		o.dropRejectedReleaseManifest = true
		o.onDroppedReleaseManifest = onDrop
	}
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
	defer func() {
		if err != nil {
			err = &ReleaseManifestError{Err: err}
		}
	}()
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
		if entry.Bytes != int64(len(feed.body)) || entry.SHA256 != hex.EncodeToString(digest[:]) {
			return nil, nil, fmt.Errorf("%s binding for %s does not match the served bytes", releaseManifestFileName, feed.name)
		}
		if entry.SignerKeyID != feed.signer {
			return nil, nil, fmt.Errorf("%s binds %s to signer %q but its sidecar is signed by %q", releaseManifestFileName, feed.name, entry.SignerKeyID, feed.signer)
		}
	}
	return append([]byte(nil), manifestBytes...), append([]byte(nil), sigBytes...), nil
}

func parseReleaseManifest(raw []byte, signer string, candidates loadedAutotuneFeed) (map[string]releaseManifestEntry, error) {
	var top map[string]json.RawMessage
	if err := decodeStrictJSON(raw, &top); err != nil {
		return nil, fmt.Errorf("%s schema: %w", releaseManifestFileName, err)
	}
	if err := requireExactJSONKeys(top, releaseManifestTopLevelKeys); err != nil {
		return nil, fmt.Errorf("%s schema: %w", releaseManifestFileName, err)
	}
	var schemaVersion, releaseID, policyVersion, generatedAt string
	for key, dst := range map[string]*string{
		"schema_version": &schemaVersion, "release_id": &releaseID,
		"policy_version": &policyVersion, "generated_at": &generatedAt,
	} {
		value, err := releaseManifestString(top[key])
		if err != nil {
			return nil, fmt.Errorf("%s schema: %s: %w", releaseManifestFileName, key, err)
		}
		*dst = value
	}
	if schemaVersion != releaseManifestSchema {
		return nil, fmt.Errorf("%s schema_version %q != %q", releaseManifestFileName, schemaVersion, releaseManifestSchema)
	}
	if releaseID != candidates.verification.Version {
		return nil, fmt.Errorf("%s release_id %q != autotune_candidates version %q", releaseManifestFileName, releaseID, candidates.verification.Version)
	}
	if policyVersion != candidates.verification.PolicyVersion {
		return nil, fmt.Errorf("%s policy_version %q != autotune_candidates policy_version %q", releaseManifestFileName, policyVersion, candidates.verification.PolicyVersion)
	}
	var rawFeeds map[string]map[string]json.RawMessage
	if err := json.Unmarshal(top["feeds"], &rawFeeds); err != nil {
		return nil, fmt.Errorf("%s schema: feeds: %w", releaseManifestFileName, err)
	}
	if strings.TrimSpace(generatedAt) == "" || len(rawFeeds) == 0 {
		return nil, fmt.Errorf("%s requires generated_at and feeds", releaseManifestFileName)
	}
	names := make([]string, 0, len(rawFeeds))
	for name := range rawFeeds {
		names = append(names, name)
	}
	sort.Strings(names)
	entries := make(map[string]releaseManifestEntry, len(rawFeeds))
	for _, name := range names {
		entry, err := parseReleaseManifestEntry(rawFeeds[name])
		if err != nil {
			return nil, fmt.Errorf("%s feed %s: %w", releaseManifestFileName, name, err)
		}
		// One signature stands for every static feed, so each must name the
		// manifest signer. The Tier-2 catalog keeps its own Tier-2 signer.
		if name != releaseManifestTier2Feed && entry.SignerKeyID != signer {
			return nil, fmt.Errorf("%s binds %s to signer %q, not the manifest signer %q", releaseManifestFileName, name, entry.SignerKeyID, signer)
		}
		entries[name] = entry
	}
	return entries, nil
}

func parseReleaseManifestEntry(fields map[string]json.RawMessage) (releaseManifestEntry, error) {
	if err := requireExactJSONKeys(fields, releaseManifestEntryKeys); err != nil {
		return releaseManifestEntry{}, err
	}
	var entry releaseManifestEntry
	decoder := json.NewDecoder(bytes.NewReader(fields["bytes"]))
	decoder.UseNumber()
	var bytesValue any
	if err := decoder.Decode(&bytesValue); err != nil {
		return releaseManifestEntry{}, fmt.Errorf("bytes: %w", err)
	}
	number, ok := bytesValue.(json.Number)
	if !ok {
		return releaseManifestEntry{}, fmt.Errorf("bytes must be a number")
	}
	// ParseInt rejects every non-integer spelling (1.0, 1e3) as well as
	// out-of-range values.
	parsed, err := strconv.ParseInt(number.String(), 10, 64)
	if err != nil || parsed <= 0 {
		return releaseManifestEntry{}, fmt.Errorf("bytes must be a positive integer, got %s", number)
	}
	entry.Bytes = parsed
	for key, dst := range map[string]*string{
		"sha256": &entry.SHA256, "signer_key_id": &entry.SignerKeyID, "version": &entry.Version,
	} {
		value, err := releaseManifestString(fields[key])
		if err != nil {
			return releaseManifestEntry{}, fmt.Errorf("%s: %w", key, err)
		}
		*dst = value
	}
	if !lowerHex64Pattern.MatchString(entry.SHA256) || strings.TrimSpace(entry.SignerKeyID) == "" || strings.TrimSpace(entry.Version) == "" {
		return releaseManifestEntry{}, fmt.Errorf("needs a lowercase sha256, signer_key_id and version")
	}
	return entry, nil
}

// requireExactJSONKeys rejects an object (nil for JSON null) whose key set is
// not exactly want.
func requireExactJSONKeys(object map[string]json.RawMessage, want []string) error {
	if object == nil {
		return fmt.Errorf("must be an object")
	}
	for _, key := range want {
		if _, ok := object[key]; !ok {
			return fmt.Errorf("missing key %q", key)
		}
	}
	if len(object) != len(want) {
		for key := range object {
			if !slices.Contains(want, key) {
				return fmt.Errorf("unknown key %q", key)
			}
		}
	}
	return nil
}

func releaseManifestString(raw json.RawMessage) (string, error) {
	var value any
	if err := json.Unmarshal(raw, &value); err != nil {
		return "", err
	}
	text, ok := value.(string)
	if !ok {
		return "", fmt.Errorf("must be a string")
	}
	return text, nil
}

func (s *Server) handleCatalogRelease(w http.ResponseWriter, r *http.Request) {
	feeds := s.autotuneFeedsSnapshot()
	s.serveAutotuneFeedBytesWithCacheControl(w, r, feeds.ReleaseManifestJSON, feeds.releaseManifestEnabled(), releaseManifestCacheControl)
}

func (s *Server) handleCatalogReleaseSig(w http.ResponseWriter, r *http.Request) {
	feeds := s.autotuneFeedsSnapshot()
	s.serveAutotuneFeedBytesWithCacheControl(w, r, feeds.ReleaseManifestSig, feeds.releaseManifestEnabled(), releaseManifestCacheControl)
}
