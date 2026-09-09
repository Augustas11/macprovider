package buyer

import (
	"bytes"
	"encoding/json"
	"fmt"
	"math"
	"net/http"
	"sort"
	"strings"
	"time"
)

// SPEC-023 §3.7 artifact feed, served at /v1/catalog-artifacts (+ .sig).
//
// The coordinator relays the signed bytes exactly as it relays the three base
// feeds, and it refuses to serve bytes it cannot bind to the candidate catalog
// of the SAME release: §3.7.2 signer identity equality, §3.7.4 release binding
// (version / generated_at / policy_version / candidate_catalog_sha256), and
// §3.7.5 primary-artifact consistency are checked at load — boot and SIGHUP
// reload alike — so a mismatched feed keeps the prior served set (fail-closed)
// rather than reaching a provider. An unconfigured pair is the pre-activation
// state and answers 404 (§3.7.6 rule 6).
const (
	catalogArtifactsSource      = "operator_curated_autotune_artifact_catalog"
	artifactSnapshotManifestAlg = "macprovider.snapshot-manifest.v1"
	artifactGGUFFileAlg         = "macprovider.gguf-file.v1"
	artifactPrimaryFormat       = "mlx_safetensors"
)

// artifactIdentityRow is one row of the §3.7.4 closed artifact-identity matrix:
// runtime_format determines the only legal hash_algorithm, source_ref.kind, and
// allowed_runtime_sources set. Any other tuple is an integrity failure.
type artifactIdentityRow struct {
	hashAlgorithm  string
	sourceRefKind  string
	runtimeSources map[string]struct{}
}

var (
	artifactIdentityMatrix = map[string]artifactIdentityRow{
		"mlx_safetensors": {
			hashAlgorithm:  artifactSnapshotManifestAlg,
			sourceRefKind:  "huggingface_revision",
			runtimeSources: map[string]struct{}{"mlx_cache": {}},
		},
		"gguf": {
			hashAlgorithm: artifactGGUFFileAlg,
			sourceRefKind: "ollama_library_tag",
			runtimeSources: map[string]struct{}{
				"ollama_loopback":            {},
				"llamacpp_loopback":          {},
				"lmstudio_loopback":          {},
				"openai_compatible_loopback": {},
			},
		},
	}
	artifactRateClasses = map[string]struct{}{
		"class-3b": {}, "class-8b": {}, "class-20b-moe": {}, "class-30b-moe": {},
		"class-32b": {}, "class-70b": {}, "class-120b-moe": {},
	}
	artifactVerificationStatuses = map[string]struct{}{"declared": {}, "verified": {}, "blocked": {}}
)

type catalogArtifactsFeed struct {
	Version                string                          `json:"version"`
	GeneratedAt            string                          `json:"generated_at"`
	PolicyVersion          string                          `json:"policy_version"`
	Source                 string                          `json:"source"`
	ReleaseID              string                          `json:"release_id"`
	CandidateCatalogSHA256 string                          `json:"candidate_catalog_sha256"`
	Models                 map[string]catalogArtifactModel `json:"models"`
}

// presentString is an OPTIONAL string field of the closed §3.7.3 schema.
// Go's decoder maps an absent field and a present JSON null to the same nil
// pointer, but the generator's exact-key validation treats them differently:
// absent is allowed, a present null is a wrong-typed field and fails closed.
// Recording presence keeps the coordinator's closed schema equal to the
// generator's, so a signed feed the generator would refuse is refused here too.
type presentString struct {
	present bool
	value   string
}

func (v *presentString) UnmarshalJSON(raw []byte) error {
	v.present = true
	if bytes.Equal(raw, []byte("null")) {
		return fmt.Errorf("optional string field must be a string when present, not null")
	}
	var value string
	if err := json.Unmarshal(raw, &value); err != nil {
		return err
	}
	v.value = value
	return nil
}

// requiredNullableString is a REQUIRED field whose value may be null
// (`verified_at`: null unless the artifact is verified). Absence is a missing
// required key, which only presence tracking can tell apart from null.
type requiredNullableString struct {
	present bool
	null    bool
	value   string
}

func (v *requiredNullableString) UnmarshalJSON(raw []byte) error {
	v.present = true
	if bytes.Equal(raw, []byte("null")) {
		v.null = true
		return nil
	}
	var value string
	if err := json.Unmarshal(raw, &value); err != nil {
		return err
	}
	v.value = value
	return nil
}

type catalogArtifactModel struct {
	RateClass         presentString                   `json:"rate_class"`
	PrimaryArtifactID string                          `json:"primary_artifact_id"`
	Artifacts         map[string]catalogArtifactEntry `json:"artifacts"`
}

// catalogArtifactSourceRef carries both §3.7.4 variants; the validator closes
// the key set per `kind` by PRESENCE, so a null-valued field of the other
// variant is rejected exactly as a non-null one is.
type catalogArtifactSourceRef struct {
	Kind       string        `json:"kind"`
	RepoID     presentString `json:"repo_id"`
	Revision   presentString `json:"revision"`
	LibraryTag presentString `json:"library_tag"`
	Digest     presentString `json:"digest"`
}

type catalogArtifactEntry struct {
	RuntimeFormat         string                    `json:"runtime_format"`
	Quantization          string                    `json:"quantization"`
	SourceRef             *catalogArtifactSourceRef `json:"source_ref"`
	HashAlgorithm         string                    `json:"hash_algorithm"`
	Hash                  string                    `json:"hash"`
	SizeBytes             *int64                    `json:"size_bytes"`
	MinRAMGB              *float64                  `json:"min_ram_gb"`
	AllowedRuntimeSources []string                  `json:"allowed_runtime_sources"`
	VerificationStatus    string                    `json:"verification_status"`
	VerifiedAt            requiredNullableString    `json:"verified_at"`
	Notes                 presentString             `json:"notes"`
}

func (f AutotuneFeeds) catalogArtifactsEnabled() bool {
	return len(f.CatalogArtifactsJSON) > 0 && len(f.CatalogArtifactsSig) > 0
}

// validateCatalogArtifactsFeed is the document-only half of the check: schema
// closure, envelope, and the §3.7.4 identity matrix. Binding to the candidate
// catalog needs both feeds and runs in bindCatalogArtifactsFeed.
func validateCatalogArtifactsFeed(raw []byte, _ string) (feedRelease, error) {
	var feed catalogArtifactsFeed
	if err := decodeStrictJSON(raw, &feed); err != nil {
		return feedRelease{}, err
	}
	release, err := validateFeedEnvelope(feed.Version, feed.PolicyVersion, feed.GeneratedAt, feed.Source, catalogArtifactsSource, len(feed.Models))
	if err != nil {
		return feedRelease{}, err
	}
	if feed.ReleaseID != feed.Version {
		return feedRelease{}, fmt.Errorf("release_id must equal version")
	}
	if !lowerHex64Pattern.MatchString(feed.CandidateCatalogSHA256) {
		return feedRelease{}, fmt.Errorf("candidate_catalog_sha256 must be lowercase 64-hex")
	}
	if err := validateCatalogArtifactModels(feed.Models); err != nil {
		return feedRelease{}, err
	}
	return release, nil
}

func sortedKeys[V any](m map[string]V) []string {
	keys := make([]string, 0, len(m))
	for key := range m {
		keys = append(keys, key)
	}
	sort.Strings(keys)
	return keys
}

func validateCatalogArtifactModels(models map[string]catalogArtifactModel) error {
	type identity struct{ algorithm, hash string }
	seen := map[identity]string{}
	for _, key := range sortedKeys(models) {
		model := models[key]
		if err := validateModelKey(key); err != nil {
			return fmt.Errorf("model %q: %w", key, err)
		}
		if model.RateClass.present {
			if _, ok := artifactRateClasses[model.RateClass.value]; !ok {
				return fmt.Errorf("model %q rate_class %q is not a SPEC-023 §3.3.1 class", key, model.RateClass.value)
			}
		}
		if len(model.Artifacts) == 0 {
			return fmt.Errorf("model %q artifacts must be a non-empty object", key)
		}
		for _, artifactID := range sortedKeys(model.Artifacts) {
			if !artifactIDPattern.MatchString(artifactID) {
				return fmt.Errorf("model %q artifact_id %q does not match ^[a-z0-9][a-z0-9-]{0,63}$", key, artifactID)
			}
			entry := model.Artifacts[artifactID]
			label := fmt.Sprintf("model %q artifact %q", key, artifactID)
			if err := validateCatalogArtifactEntry(label, entry); err != nil {
				return err
			}
			id := identity{entry.HashAlgorithm, entry.Hash}
			if prior, dup := seen[id]; dup {
				return fmt.Errorf("(%s, %s) appears under both %s and %s/%s; one hash must resolve to exactly one identity", id.algorithm, id.hash, prior, key, artifactID)
			}
			seen[id] = key + "/" + artifactID
		}
		primary, ok := model.Artifacts[model.PrimaryArtifactID]
		if !ok {
			return fmt.Errorf("model %q primary_artifact_id %q does not name an artifact of this model", key, model.PrimaryArtifactID)
		}
		if primary.RuntimeFormat != artifactPrimaryFormat {
			return fmt.Errorf("model %q primary_artifact_id must name an %s artifact", key, artifactPrimaryFormat)
		}
	}
	return nil
}

func validateCatalogArtifactEntry(label string, entry catalogArtifactEntry) error {
	row, ok := artifactIdentityMatrix[entry.RuntimeFormat]
	if !ok {
		return fmt.Errorf("%s: unknown runtime_format %q", label, entry.RuntimeFormat)
	}
	if entry.HashAlgorithm != row.hashAlgorithm {
		return fmt.Errorf("%s: runtime_format %q requires hash_algorithm %q, not %q", label, entry.RuntimeFormat, row.hashAlgorithm, entry.HashAlgorithm)
	}
	if strings.TrimSpace(entry.Quantization) == "" {
		return fmt.Errorf("%s: quantization must be a non-empty string", label)
	}
	if !lowerHex64Pattern.MatchString(entry.Hash) {
		return fmt.Errorf("%s: hash must be lowercase 64-hex", label)
	}
	if entry.SizeBytes == nil || *entry.SizeBytes <= 0 {
		return fmt.Errorf("%s: size_bytes must be a measured integer > 0", label)
	}
	if entry.MinRAMGB == nil || math.IsNaN(*entry.MinRAMGB) || math.IsInf(*entry.MinRAMGB, 0) || *entry.MinRAMGB <= 0 {
		return fmt.Errorf("%s: min_ram_gb must be a number > 0", label)
	}
	if len(entry.AllowedRuntimeSources) == 0 {
		return fmt.Errorf("%s: allowed_runtime_sources must be a non-empty array", label)
	}
	distinct := map[string]struct{}{}
	for _, source := range entry.AllowedRuntimeSources {
		if _, dup := distinct[source]; dup {
			return fmt.Errorf("%s: allowed_runtime_sources must not repeat an adapter", label)
		}
		distinct[source] = struct{}{}
		if _, permitted := row.runtimeSources[source]; !permitted {
			return fmt.Errorf("%s: runtime_format %q may not allow runtime source %q", label, entry.RuntimeFormat, source)
		}
	}
	if _, ok := artifactVerificationStatuses[entry.VerificationStatus]; !ok {
		return fmt.Errorf("%s: invalid verification_status %q", label, entry.VerificationStatus)
	}
	if !entry.VerifiedAt.present {
		return fmt.Errorf("%s: verified_at is required (null unless verification_status is verified)", label)
	}
	if entry.VerificationStatus == "verified" {
		if _, loopback := distinct["openai_compatible_loopback"]; loopback {
			return fmt.Errorf("%s: a verified artifact may not allow openai_compatible_loopback", label)
		}
		if entry.VerifiedAt.null || !artifactFullDatePattern.MatchString(entry.VerifiedAt.value) {
			return fmt.Errorf("%s: verified_at must be an RFC3339 full-date when verified", label)
		}
		if _, err := time.Parse("2006-01-02", entry.VerifiedAt.value); err != nil {
			return fmt.Errorf("%s: verified_at is not a real date", label)
		}
	} else if !entry.VerifiedAt.null {
		return fmt.Errorf("%s: verified_at must be null unless verification_status is verified", label)
	}
	if entry.SourceRef == nil {
		return fmt.Errorf("%s: source_ref must be an object", label)
	}
	ref := entry.SourceRef
	if ref.Kind != row.sourceRefKind {
		return fmt.Errorf("%s: runtime_format %q requires source_ref.kind %q, not %q", label, entry.RuntimeFormat, row.sourceRefKind, ref.Kind)
	}
	switch ref.Kind {
	case "huggingface_revision":
		if ref.LibraryTag.present || ref.Digest.present {
			return fmt.Errorf("%s: source_ref carries fields outside {kind, repo_id, revision}", label)
		}
		if !ref.RepoID.present || !modelIDPattern.MatchString(ref.RepoID.value) {
			return fmt.Errorf("%s: source_ref.repo_id must be a HuggingFace repo id", label)
		}
		if !ref.Revision.present || !lowerHex40Pattern.MatchString(ref.Revision.value) {
			return fmt.Errorf("%s: source_ref.revision must be an immutable lowercase 40-hex commit", label)
		}
	default:
		if ref.RepoID.present || ref.Revision.present {
			return fmt.Errorf("%s: source_ref carries fields outside {kind, library_tag, digest}", label)
		}
		if !ref.LibraryTag.present || strings.TrimSpace(ref.LibraryTag.value) == "" {
			return fmt.Errorf("%s: source_ref.library_tag required", label)
		}
		if !ref.Digest.present || ref.Digest.value != "sha256:"+entry.Hash {
			return fmt.Errorf("%s: gguf source_ref.digest must equal 'sha256:' + hash", label)
		}
	}
	return nil
}

// bindCatalogArtifactsFeed is the §3.7.2/§3.7.4/§3.7.5 release binding between
// the loaded artifact feed and the loaded candidate catalog of one release.
// Every mismatch is a load failure: the coordinator never serves an artifact
// feed it cannot bind to the candidate bytes it serves beside it.
func bindCatalogArtifactsFeed(artifacts, candidates loadedAutotuneFeed) error {
	if artifacts.verification.Version != candidates.verification.Version {
		return fmt.Errorf("autotune feed release mismatch: catalog_artifacts version %q != autotune_candidates version %q",
			artifacts.verification.Version, candidates.verification.Version)
	}
	if artifacts.verification.PolicyVersion != candidates.verification.PolicyVersion {
		return fmt.Errorf("autotune feed release mismatch: catalog_artifacts policy_version %q != autotune_candidates policy_version %q",
			artifacts.verification.PolicyVersion, candidates.verification.PolicyVersion)
	}
	if !artifacts.verification.GeneratedAt.Equal(candidates.verification.GeneratedAt) {
		return fmt.Errorf("autotune feed release mismatch: catalog_artifacts generated_at %q != autotune_candidates generated_at %q",
			artifacts.verification.GeneratedAt.Format(time.RFC3339), candidates.verification.GeneratedAt.Format(time.RFC3339))
	}
	// §3.7.2 signer identity equality: unknown-key rejection alone does not
	// prove one operator key signed both feeds during a rotation bridge.
	if artifacts.verification.KeyID != candidates.verification.KeyID {
		return fmt.Errorf("autotune.catalog_artifacts signer key_id %q != autotune_candidates signer key_id %q (SPEC-023 §3.7.2 signer identity equality)",
			artifacts.verification.KeyID, candidates.verification.KeyID)
	}
	var feed catalogArtifactsFeed
	if err := decodeStrictJSON(artifacts.jsonBytes, &feed); err != nil {
		return fmt.Errorf("autotune.catalog_artifacts schema: %w", err)
	}
	if feed.CandidateCatalogSHA256 != candidates.verification.SHA256 {
		return fmt.Errorf("autotune.catalog_artifacts candidate_catalog_sha256 %q does not match the served autotune_candidates bytes %q",
			feed.CandidateCatalogSHA256, candidates.verification.SHA256)
	}
	var catalog candidateCatalogFeed
	if err := decodeStrictJSON(candidates.jsonBytes, &catalog); err != nil {
		return fmt.Errorf("autotune.autotune_candidates schema: %w", err)
	}
	return requirePrimaryArtifactConsistency(feed.Models, catalog.Rows)
}

// requirePrimaryArtifactConsistency is SPEC-023 §3.7.5: every listed or
// recommendable candidate row has a model entry whose primary artifact is
// verified and identity-identical to the row; a candidate row's primary may
// stay declared but must still correspond; blocked rows are out of scope.
func requirePrimaryArtifactConsistency(models map[string]catalogArtifactModel, rows map[string]candidateRow) error {
	for _, key := range sortedKeys(models) {
		if _, ok := rows[key]; !ok {
			return fmt.Errorf("autotune.catalog_artifacts model %q is absent from the candidate catalog", key)
		}
	}
	for _, key := range sortedKeys(rows) {
		row := rows[key]
		if row.RuntimeStatus == "blocked" {
			continue
		}
		model, ok := models[key]
		if !ok {
			if row.RuntimeStatus == "candidate" {
				continue
			}
			return fmt.Errorf("autotune.catalog_artifacts: %s candidate row %q has no artifact-feed model entry", row.RuntimeStatus, key)
		}
		primary := model.Artifacts[model.PrimaryArtifactID]
		if row.ModelSHA256 == nil || primary.Hash != *row.ModelSHA256 {
			return fmt.Errorf("autotune.catalog_artifacts model %q primary artifact hash does not equal the candidate model_sha256", key)
		}
		if primary.SourceRef == nil || !primary.SourceRef.RepoID.present || primary.SourceRef.RepoID.value != row.ModelID {
			return fmt.Errorf("autotune.catalog_artifacts model %q primary artifact repo_id does not equal the candidate model_id", key)
		}
		if row.ModelRevision == nil || !primary.SourceRef.Revision.present || primary.SourceRef.Revision.value != *row.ModelRevision {
			return fmt.Errorf("autotune.catalog_artifacts model %q primary artifact revision does not equal the candidate model_revision", key)
		}
		if row.MinRAMGB == nil || primary.MinRAMGB == nil || *primary.MinRAMGB != float64(*row.MinRAMGB) {
			return fmt.Errorf("autotune.catalog_artifacts model %q primary artifact min_ram_gb does not equal the candidate min_ram_gb", key)
		}
		if row.RuntimeStatus != "candidate" && primary.VerificationStatus != "verified" {
			return fmt.Errorf("autotune.catalog_artifacts: %s candidate row %q requires a verified primary artifact", row.RuntimeStatus, key)
		}
		if row.RuntimeStatus == "recommendable" && !model.RateClass.present {
			return fmt.Errorf("autotune.catalog_artifacts: recommendable candidate row %q must declare a rate_class", key)
		}
	}
	return nil
}

func (s *Server) handleCatalogArtifacts(w http.ResponseWriter, r *http.Request) {
	feeds := s.autotuneFeedsSnapshot()
	s.serveAutotuneFeedBytes(w, r, feeds.CatalogArtifactsJSON, feeds.catalogArtifactsEnabled())
}

func (s *Server) handleCatalogArtifactsSig(w http.ResponseWriter, r *http.Request) {
	feeds := s.autotuneFeedsSnapshot()
	s.serveAutotuneFeedBytes(w, r, feeds.CatalogArtifactsSig, feeds.catalogArtifactsEnabled())
}
