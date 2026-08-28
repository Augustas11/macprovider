package buyer

import (
	"bytes"
	"crypto/ed25519"
	"crypto/sha256"
	"encoding/base64"
	"encoding/hex"
	"encoding/json"
	"fmt"
	"io"
	"math"
	"net/http"
	"os"
	"regexp"
	"strings"
	"time"
	"unicode/utf8"

	"github.com/augstar/macprovider-coordinator/internal/config"
)

const (
	maxAutotuneFeedBytes    = 4 << 20
	maxAutotuneSidecarBytes = 16 << 10
	candidateCatalogSource  = "operator_curated_autotune_candidate_catalog"
	demandRankSource        = "openrouter_completion_token_rank_operator_curated"
	demandSupplySource      = "macprovider_buyer_supply_deficit_v1"

	staticV4SignerKeyID                         = "streamvc-autotune-static-v4"
	transitionMissingProvenanceCandidateRelease = "published-2026-07-10-catalog-recovery-v1"
	transitionMissingProvenanceCandidateSHA256  = "776182f6230eff098345b188322dba0c7fce47a6da46447432991ffdc37eabda"
)

var (
	lowerHex40Pattern = regexp.MustCompile(`^[0-9a-f]{40}$`)
	lowerHex64Pattern = regexp.MustCompile(`^[0-9a-f]{64}$`)
	modelKeyPattern   = regexp.MustCompile(`^[a-z0-9][a-z0-9._/-]{0,127}$`)
	modelIDPattern    = regexp.MustCompile(`^[A-Za-z0-9][A-Za-z0-9._-]*/[A-Za-z0-9][A-Za-z0-9._-]*$`)
)

// AutotuneFeeds holds the literal signed bytes for SPEC-023 recommendation
// inputs. Served on the buyer mux at /v1/rate-card(+ .sig),
// /v1/demand-rank(+ .sig), and /v1/autotune-candidates(+ .sig),
// replacing nginx /static/* hosting.
type AutotuneFeeds struct {
	RateCardJSON                   []byte
	RateCardSig                    []byte
	RateCardVerification           AutotuneFeedVerification
	DemandRankJSON                 []byte
	DemandRankSig                  []byte
	DemandRankVerification         AutotuneFeedVerification
	AutotuneCandidatesJSON         []byte
	AutotuneCandidatesSig          []byte
	AutotuneCandidatesVerification AutotuneFeedVerification
}

// AutotuneFeedVerification records the trust decision for the exact bytes
// retained in AutotuneFeeds. SHA256 is over the literal JSON bytes, not a
// parsed or reserialized representation.
type AutotuneFeedVerification struct {
	KeyID         string
	SHA256        string
	Version       string
	PolicyVersion string
	GeneratedAt   time.Time
	VerifiedAt    time.Time
}

func (f AutotuneFeeds) demandRankEnabled() bool {
	return len(f.DemandRankJSON) > 0 && len(f.DemandRankSig) > 0
}

func (f AutotuneFeeds) rateCardEnabled() bool {
	return len(f.RateCardJSON) > 0 && len(f.RateCardSig) > 0
}

func (f AutotuneFeeds) autotuneCandidatesEnabled() bool {
	return len(f.AutotuneCandidatesJSON) > 0 && len(f.AutotuneCandidatesSig) > 0
}

// LoadAutotuneFeeds reads and verifies signed feed files from cfg paths. Empty
// paths disable the static SPEC-023 feed set. A configured feed set fails
// closed unless every required feed pair is present, each literal JSON body has
// a valid signature from cfg.PublicKeys, and every body passes the locked feed
// schema.
func LoadAutotuneFeeds(cfg config.AutotuneFeedsConfig) (AutotuneFeeds, error) {
	keyring, err := cfg.DecodePublicKeyring()
	if err != nil {
		return AutotuneFeeds{}, err
	}
	rateCard, err := loadAutotuneFeedPair(
		cfg.RateCardPath, cfg.RateCardSigPath, "rate_card", keyring, validateRateCardFeed,
	)
	if err != nil {
		return AutotuneFeeds{}, err
	}
	demand, err := loadAutotuneFeedPair(
		cfg.DemandRankPath, cfg.DemandRankSigPath, "demand_rank", keyring, validateDemandRankFeed,
	)
	if err != nil {
		return AutotuneFeeds{}, err
	}
	candidates, err := loadAutotuneFeedPair(
		cfg.AutotuneCandidatesPath, cfg.AutotuneCandidatesSigPath, "autotune_candidates", keyring, validateCandidateCatalogFeed,
	)
	if err != nil {
		return AutotuneFeeds{}, err
	}
	enabledCount := 0
	for _, feed := range []loadedAutotuneFeed{rateCard, demand, candidates} {
		if feed.enabled() {
			enabledCount++
		}
	}
	if enabledCount > 0 && enabledCount != 3 {
		return AutotuneFeeds{}, fmt.Errorf("autotune feed set incomplete: rate_card, demand_rank, and autotune_candidates must all be configured together")
	}
	if enabledCount == 3 {
		if demand.verification.Version != candidates.verification.Version {
			return AutotuneFeeds{}, fmt.Errorf(
				"autotune feed release mismatch: demand_rank version %q != autotune_candidates version %q",
				demand.verification.Version,
				candidates.verification.Version,
			)
		}
		if demand.verification.PolicyVersion != candidates.verification.PolicyVersion {
			return AutotuneFeeds{}, fmt.Errorf(
				"autotune feed release mismatch: demand_rank policy_version %q != autotune_candidates policy_version %q",
				demand.verification.PolicyVersion,
				candidates.verification.PolicyVersion,
			)
		}
		if !demand.verification.GeneratedAt.Equal(candidates.verification.GeneratedAt) {
			return AutotuneFeeds{}, fmt.Errorf(
				"autotune feed release mismatch: demand_rank generated_at %q != autotune_candidates generated_at %q",
				demand.verification.GeneratedAt.Format(time.RFC3339),
				candidates.verification.GeneratedAt.Format(time.RFC3339),
			)
		}
		if rateCard.verification.PolicyVersion != candidates.verification.PolicyVersion {
			return AutotuneFeeds{}, fmt.Errorf(
				"autotune feed release mismatch: rate_card policy_version %q != autotune_candidates policy_version %q",
				rateCard.verification.PolicyVersion,
				candidates.verification.PolicyVersion,
			)
		}
		if !rateCard.verification.GeneratedAt.Equal(candidates.verification.GeneratedAt) {
			return AutotuneFeeds{}, fmt.Errorf(
				"autotune feed release mismatch: rate_card generated_at %q != autotune_candidates generated_at %q",
				rateCard.verification.GeneratedAt.Format(time.RFC3339),
				candidates.verification.GeneratedAt.Format(time.RFC3339),
			)
		}
	}
	return AutotuneFeeds{
		RateCardJSON:                   rateCard.jsonBytes,
		RateCardSig:                    rateCard.sigBytes,
		RateCardVerification:           rateCard.verification,
		DemandRankJSON:                 demand.jsonBytes,
		DemandRankSig:                  demand.sigBytes,
		DemandRankVerification:         demand.verification,
		AutotuneCandidatesJSON:         candidates.jsonBytes,
		AutotuneCandidatesSig:          candidates.sigBytes,
		AutotuneCandidatesVerification: candidates.verification,
	}, nil
}

// LoadPreviousAutotuneCandidateFeed verifies the deployer-recorded previous
// candidate feed for rollback/compatibility only. Current feed loading remains
// strict; this path exists so an A4 rollout can keep the exact July 10 release
// as previous-target while publishing the in-band provenance release.
func LoadPreviousAutotuneCandidateFeed(cfg config.AutotuneFeedsConfig) (AutotuneFeeds, error) {
	keyring, err := cfg.DecodePublicKeyring()
	if err != nil {
		return AutotuneFeeds{}, err
	}
	candidates, err := loadAutotuneFeedPair(
		cfg.AutotuneCandidatesPath,
		cfg.AutotuneCandidatesSigPath,
		"autotune_candidates",
		keyring,
		validatePreviousCandidateCatalogFeed,
	)
	if err != nil {
		return AutotuneFeeds{}, err
	}
	return AutotuneFeeds{
		AutotuneCandidatesJSON:         candidates.jsonBytes,
		AutotuneCandidatesSig:          candidates.sigBytes,
		AutotuneCandidatesVerification: candidates.verification,
	}, nil
}

type loadedAutotuneFeed struct {
	jsonBytes    []byte
	sigBytes     []byte
	verification AutotuneFeedVerification
}

func (f loadedAutotuneFeed) enabled() bool {
	return len(f.jsonBytes) > 0 && len(f.sigBytes) > 0
}

type feedRelease struct {
	version       string
	policyVersion string
	generatedAt   time.Time
}

type feedValidator func([]byte, string) (feedRelease, error)

func loadAutotuneFeedPair(
	jsonPath, sigPath, label string,
	keyring map[string]ed25519.PublicKey,
	validate feedValidator,
) (loadedAutotuneFeed, error) {
	jsonPath = strings.TrimSpace(jsonPath)
	sigPath = strings.TrimSpace(sigPath)
	if jsonPath == "" && sigPath == "" {
		return loadedAutotuneFeed{}, nil
	}
	if jsonPath == "" || sigPath == "" {
		return loadedAutotuneFeed{}, configPairError(label)
	}
	if len(keyring) == 0 {
		return loadedAutotuneFeed{}, configFeedError("autotune.public_keys must contain at least one Ed25519 public key when a feed is configured")
	}
	jsonBytes, err := os.ReadFile(jsonPath)
	if err != nil {
		return loadedAutotuneFeed{}, fmt.Errorf("read autotune.%s_path: %w", label, err)
	}
	sigBytes, err := os.ReadFile(sigPath)
	if err != nil {
		return loadedAutotuneFeed{}, fmt.Errorf("read autotune.%s_sig_path: %w", label, err)
	}
	if len(jsonBytes) == 0 || len(sigBytes) == 0 {
		return loadedAutotuneFeed{}, configEmptyFeedError(label)
	}
	if len(jsonBytes) > maxAutotuneFeedBytes {
		return loadedAutotuneFeed{}, fmt.Errorf("autotune.%s feed exceeds %d bytes", label, maxAutotuneFeedBytes)
	}
	if len(sigBytes) > maxAutotuneSidecarBytes {
		return loadedAutotuneFeed{}, fmt.Errorf("autotune.%s signature sidecar exceeds %d bytes", label, maxAutotuneSidecarBytes)
	}
	if !utf8.Valid(jsonBytes) {
		return loadedAutotuneFeed{}, fmt.Errorf("autotune.%s feed is not valid UTF-8", label)
	}
	if !utf8.Valid(sigBytes) {
		return loadedAutotuneFeed{}, fmt.Errorf("autotune.%s signature sidecar is not valid UTF-8", label)
	}
	sidecar, signature, err := parseAutotuneSidecar(sigBytes)
	if err != nil {
		return loadedAutotuneFeed{}, fmt.Errorf("autotune.%s signature sidecar: %w", label, err)
	}
	publicKey, ok := keyring[sidecar.KeyID]
	if !ok {
		return loadedAutotuneFeed{}, fmt.Errorf("autotune.%s signature uses unknown key_id %q", label, sidecar.KeyID)
	}
	if !ed25519.Verify(publicKey, jsonBytes, signature) {
		return loadedAutotuneFeed{}, fmt.Errorf("autotune.%s signature verification failed", label)
	}
	release, err := validate(jsonBytes, sidecar.KeyID)
	if err != nil {
		return loadedAutotuneFeed{}, fmt.Errorf("autotune.%s schema: %w", label, err)
	}
	digest := sha256.Sum256(jsonBytes)
	return loadedAutotuneFeed{
		jsonBytes: append([]byte(nil), jsonBytes...),
		sigBytes:  append([]byte(nil), sigBytes...),
		verification: AutotuneFeedVerification{
			KeyID:         sidecar.KeyID,
			SHA256:        hex.EncodeToString(digest[:]),
			Version:       release.version,
			PolicyVersion: release.policyVersion,
			GeneratedAt:   release.generatedAt,
			VerifiedAt:    time.Now().UTC(),
		},
	}, nil
}

type autotuneSidecar struct {
	KeyID     string `json:"key_id"`
	Algorithm string `json:"alg"`
	Signature string `json:"signature"`
}

func parseAutotuneSidecar(raw []byte) (autotuneSidecar, []byte, error) {
	var sidecar autotuneSidecar
	if err := decodeStrictJSON(raw, &sidecar); err != nil {
		return autotuneSidecar{}, nil, err
	}
	if strings.TrimSpace(sidecar.KeyID) == "" || strings.TrimSpace(sidecar.KeyID) != sidecar.KeyID {
		return autotuneSidecar{}, nil, fmt.Errorf("key_id must be a non-empty trimmed string")
	}
	if sidecar.Algorithm != "ed25519" {
		return autotuneSidecar{}, nil, fmt.Errorf("alg must be %q", "ed25519")
	}
	signature, err := base64.StdEncoding.Strict().DecodeString(sidecar.Signature)
	if err != nil || base64.StdEncoding.EncodeToString(signature) != sidecar.Signature {
		return autotuneSidecar{}, nil, fmt.Errorf("signature must be canonical padded base64")
	}
	if len(signature) != ed25519.SignatureSize {
		return autotuneSidecar{}, nil, fmt.Errorf("signature must decode to %d bytes", ed25519.SignatureSize)
	}
	return sidecar, signature, nil
}

type demandRankFeed struct {
	Version             string                   `json:"version"`
	PolicyVersion       string                   `json:"policy_version"`
	GeneratedAt         string                   `json:"generated_at"`
	Source              string                   `json:"source"`
	ColdStartFloor      *float64                 `json:"cold_start_floor"`
	DiversificationBand *float64                 `json:"diversification_band"`
	Rows                map[string]demandRankRow `json:"rows"`
}

type demandRankRow struct {
	DemandWeight            *float64     `json:"demand_weight"`
	Rank                    nullableRank `json:"rank"`
	Recommendable           *bool        `json:"recommendable"`
	MinProviderTarget       *int         `json:"min_provider_target"`
	ReadyProviderCount      *int         `json:"ready_provider_count,omitempty"`
	SupplyDeficitMultiplier *float64     `json:"supply_deficit_multiplier,omitempty"`
	MinDwellHours           *int         `json:"min_dwell_hours,omitempty"`
}

type nullableRank struct {
	present bool
	value   *int
}

func (r *nullableRank) UnmarshalJSON(raw []byte) error {
	r.present = true
	if bytes.Equal(raw, []byte("null")) {
		r.value = nil
		return nil
	}
	var value int
	if err := json.Unmarshal(raw, &value); err != nil {
		return fmt.Errorf("rank must be a positive integer or null: %w", err)
	}
	r.value = &value
	return nil
}

type rateCardFeed struct {
	Version              string                     `json:"version"`
	PolicyVersion        string                     `json:"policy_version"`
	GeneratedAt          string                     `json:"generated_at"`
	USDPerMillionCredits *float64                   `json:"usd_per_million_credits"`
	Rows                 map[string]rateCardFeedRow `json:"rows"`
}

type rateCardFeedRow struct {
	PromptRatePerMtok         *int64 `json:"prompt_rate_per_mtok"`
	PromptCacheHitRatePerMtok *int64 `json:"prompt_cache_hit_rate_per_mtok"`
	CompletionRatePerMtok     *int64 `json:"completion_rate_per_mtok"`
	ProviderShareBPS          *int64 `json:"provider_share_bps"`
	GlobalMultiplierPPM       *int64 `json:"global_multiplier_ppm"`
}

func validateRateCardFeed(raw []byte, _ string) (feedRelease, error) {
	var feed rateCardFeed
	if err := decodeStrictJSON(raw, &feed); err != nil {
		return feedRelease{}, err
	}
	release, err := validateFeedEnvelope(feed.Version, feed.PolicyVersion, feed.GeneratedAt, "", "", len(feed.Rows))
	if err != nil {
		return feedRelease{}, err
	}
	if feed.USDPerMillionCredits == nil || math.IsNaN(*feed.USDPerMillionCredits) || math.IsInf(*feed.USDPerMillionCredits, 0) || *feed.USDPerMillionCredits < 0 {
		return feedRelease{}, fmt.Errorf("usd_per_million_credits must be finite and >= 0")
	}
	for key, row := range feed.Rows {
		if key != "default" {
			if err := validateModelKey(key); err != nil {
				return feedRelease{}, fmt.Errorf("row %q: %w", key, err)
			}
		}
		if row.PromptRatePerMtok == nil || *row.PromptRatePerMtok < 0 {
			return feedRelease{}, fmt.Errorf("row %q prompt_rate_per_mtok must be >= 0", key)
		}
		if row.PromptCacheHitRatePerMtok == nil || *row.PromptCacheHitRatePerMtok < 0 {
			return feedRelease{}, fmt.Errorf("row %q prompt_cache_hit_rate_per_mtok must be >= 0", key)
		}
		if row.CompletionRatePerMtok == nil || *row.CompletionRatePerMtok < 0 {
			return feedRelease{}, fmt.Errorf("row %q completion_rate_per_mtok must be >= 0", key)
		}
		if row.ProviderShareBPS == nil || *row.ProviderShareBPS < 0 || *row.ProviderShareBPS > 10000 {
			return feedRelease{}, fmt.Errorf("row %q provider_share_bps must be in [0,10000]", key)
		}
		if row.GlobalMultiplierPPM == nil || *row.GlobalMultiplierPPM < 0 {
			return feedRelease{}, fmt.Errorf("row %q global_multiplier_ppm must be >= 0", key)
		}
	}
	defaultRow, ok := feed.Rows["default"]
	if !ok {
		return feedRelease{}, fmt.Errorf("default row required")
	}
	rows := make(map[string]recommendationRateCardRow, len(feed.Rows))
	for key, row := range feed.Rows {
		rows[key] = recommendationRateCardRow{
			PromptRatePerMtok:         *row.PromptRatePerMtok,
			PromptCacheHitRatePerMtok: *row.PromptCacheHitRatePerMtok,
			CompletionRatePerMtok:     *row.CompletionRatePerMtok,
			ProviderShareBPS:          *row.ProviderShareBPS,
			GlobalMultiplierPPM:       *row.GlobalMultiplierPPM,
		}
	}
	expectedVersion := recommendationRateCardVersion(
		rows,
		*defaultRow.ProviderShareBPS,
		*defaultRow.GlobalMultiplierPPM,
		*feed.USDPerMillionCredits,
	)
	if feed.Version != expectedVersion {
		return feedRelease{}, fmt.Errorf("version must equal projection hash %q", expectedVersion)
	}
	return release, nil
}

func validateDemandRankFeed(raw []byte, _ string) (feedRelease, error) {
	var feed demandRankFeed
	if err := decodeStrictJSON(raw, &feed); err != nil {
		return feedRelease{}, err
	}
	normalizedSource := feed.Source
	if normalizedSource == demandSupplySource {
		normalizedSource = demandRankSource
	}
	release, err := validateFeedEnvelope(feed.Version, feed.PolicyVersion, feed.GeneratedAt, normalizedSource, demandRankSource, len(feed.Rows))
	if err != nil {
		return feedRelease{}, err
	}
	if feed.ColdStartFloor == nil || *feed.ColdStartFloor != 0.15 {
		return feedRelease{}, fmt.Errorf("cold_start_floor must equal 0.15")
	}
	if feed.DiversificationBand == nil || *feed.DiversificationBand != 0.85 {
		return feedRelease{}, fmt.Errorf("diversification_band must equal 0.85")
	}
	for key, row := range feed.Rows {
		if err := validateModelKey(key); err != nil {
			return feedRelease{}, fmt.Errorf("row %q: %w", key, err)
		}
		if row.DemandWeight == nil || math.IsNaN(*row.DemandWeight) || math.IsInf(*row.DemandWeight, 0) || *row.DemandWeight < 0 || *row.DemandWeight > 1 {
			return feedRelease{}, fmt.Errorf("row %q demand_weight must be finite and in [0,1]", key)
		}
		if !row.Rank.present || (row.Rank.value != nil && *row.Rank.value <= 0) {
			return feedRelease{}, fmt.Errorf("row %q rank must be a positive integer or null", key)
		}
		if row.Recommendable == nil {
			return feedRelease{}, fmt.Errorf("row %q recommendable is required", key)
		}
		if row.MinProviderTarget == nil || *row.MinProviderTarget < 0 {
			return feedRelease{}, fmt.Errorf("row %q min_provider_target must be >= 0", key)
		}
		if row.ReadyProviderCount != nil && *row.ReadyProviderCount < 0 {
			return feedRelease{}, fmt.Errorf("row %q ready_provider_count must be >= 0", key)
		}
		if row.SupplyDeficitMultiplier != nil &&
			(math.IsNaN(*row.SupplyDeficitMultiplier) || math.IsInf(*row.SupplyDeficitMultiplier, 0) ||
				*row.SupplyDeficitMultiplier < 0.5 || *row.SupplyDeficitMultiplier > 2.0) {
			return feedRelease{}, fmt.Errorf("row %q supply_deficit_multiplier must be finite and in [0.5,2.0]", key)
		}
		if row.MinDwellHours != nil && (*row.MinDwellHours < 0 || *row.MinDwellHours > 720) {
			return feedRelease{}, fmt.Errorf("row %q min_dwell_hours must be in [0,720]", key)
		}
	}
	return release, nil
}

type candidateCatalogFeed struct {
	Version       string                  `json:"version"`
	PolicyVersion string                  `json:"policy_version"`
	GeneratedAt   string                  `json:"generated_at"`
	Source        string                  `json:"source"`
	Rows          map[string]candidateRow `json:"rows"`
}

type candidateRow struct {
	ModelID          string                                         `json:"model_id"`
	ModelRevision    *string                                        `json:"model_revision"`
	ModelSHA256      *string                                        `json:"model_sha256"`
	MinRAMGB         *int                                           `json:"min_ram_gb"`
	MinBandwidthTier string                                         `json:"min_bandwidth_tier"`
	BenchGate        *candidateBenchGate                            `json:"bench_gate"`
	RuntimeStatus    string                                         `json:"runtime_status"`
	Notes            *string                                        `json:"notes,omitempty"`
	DraftCandidates  []candidateDraftCandidate                      `json:"draft_candidates,omitempty"`
	WorkloadProfiles map[string]map[string]candidateWorkloadProfile `json:"workload_profiles,omitempty"`
}

type candidateDraftCandidate struct {
	DraftModel          *string `json:"draft_model"`
	DraftArtifactSHA256 *string `json:"draft_model_artifact_sha256"`
}

type candidateWorkloadRecommended struct {
	KVBits                 *int    `json:"kv_bits"`
	MaxContextOverride     *int    `json:"max_context_override"`
	MaxConcurrencyOverride *int    `json:"max_concurrency_override"`
	DraftModel             *string `json:"draft_model,omitempty"`
	DraftArtifactSHA256    *string `json:"draft_model_artifact_sha256,omitempty"`
	NumDraftTokens         *int    `json:"num_draft_tokens,omitempty"`
}

type requiredNullableFloat struct {
	present bool
	value   *float64
}

func (v *requiredNullableFloat) UnmarshalJSON(raw []byte) error {
	v.present = true
	if bytes.Equal(raw, []byte("null")) {
		v.value = nil
		return nil
	}
	var value float64
	if err := json.Unmarshal(raw, &value); err != nil {
		return err
	}
	v.value = &value
	return nil
}

type candidateWorkloadGatePolicy struct {
	MinSamples           *int                  `json:"min_samples"`
	MaxP95TTFTMS         *int                  `json:"max_p95_ttft_ms"`
	MaxStopTokenLeakRate *float64              `json:"max_stop_token_leak_rate"`
	MinMedianTPS         requiredNullableFloat `json:"min_median_tps"`
}

type candidateWorkloadMetrics struct {
	MedianTPS                requiredNullableFloat `json:"median_tps"`
	P95TTFTMS                requiredNullableFloat `json:"p95_ttft_ms"`
	StopTokenLeakRate        requiredNullableFloat `json:"stop_token_leak_rate"`
	SpecDecodeAcceptanceRate requiredNullableFloat `json:"spec_decode_acceptance_rate"`
	SampleCount              *int                  `json:"sample_count"`
}

type candidateWorkloadProfile struct {
	Status          *string                       `json:"status,omitempty"`
	NoWinnerReason  *string                       `json:"no_winner_reason,omitempty"`
	Recommended     *candidateWorkloadRecommended `json:"recommended,omitempty"`
	GatePolicy      *candidateWorkloadGatePolicy  `json:"gate_policy"`
	ProfileMetrics  *candidateWorkloadMetrics     `json:"profile_metrics"`
	Source          *string                       `json:"source"`
	CandidateSource *string                       `json:"candidate_source,omitempty"`
}

type candidateBenchGate struct {
	MinSustainedTPS *float64                  `json:"min_sustained_tps"`
	Max4KTTFTMS     *int                      `json:"max_4k_ttft_ms"`
	Provenance      *candidateBenchProvenance `json:"provenance"`
}

type candidateBenchProvenance struct {
	Source     string                   `json:"source"`
	Hardware   optionalProvenanceString `json:"hardware,omitempty"`
	MeasuredAt optionalProvenanceString `json:"measured_at,omitempty"`
	Notes      optionalProvenanceString `json:"notes,omitempty"`
}

type optionalProvenanceString struct {
	present bool
	value   string
}

func (v *optionalProvenanceString) UnmarshalJSON(raw []byte) error {
	v.present = true
	if bytes.Equal(raw, []byte("null")) {
		return fmt.Errorf("must be a non-null string")
	}
	var value string
	if err := json.Unmarshal(raw, &value); err != nil {
		return err
	}
	v.value = value
	return nil
}

func validateCandidateCatalogFeed(raw []byte, signerKeyID string) (feedRelease, error) {
	return validateCandidateCatalogFeedWithTransition(raw, signerKeyID, false)
}

func validatePreviousCandidateCatalogFeed(raw []byte, signerKeyID string) (feedRelease, error) {
	return validateCandidateCatalogFeedWithTransition(raw, signerKeyID, true)
}

func validateCandidateCatalogFeedWithTransition(raw []byte, signerKeyID string, allowPinnedMissingProvenance bool) (feedRelease, error) {
	var feed candidateCatalogFeed
	if err := decodeStrictJSON(raw, &feed); err != nil {
		return feedRelease{}, err
	}
	release, err := validateFeedEnvelope(feed.Version, feed.PolicyVersion, feed.GeneratedAt, feed.Source, candidateCatalogSource, len(feed.Rows))
	if err != nil {
		return feedRelease{}, err
	}
	digest := sha256.Sum256(raw)
	digestHex := hex.EncodeToString(digest[:])
	allowedStatuses := map[string]struct{}{
		"candidate":     {},
		"listed":        {},
		"recommendable": {},
		"blocked":       {},
	}
	allowedBandwidthTiers := map[string]struct{}{"C": {}, "B": {}, "A": {}, "S": {}}
	for key, row := range feed.Rows {
		if err := validateModelKey(key); err != nil {
			return feedRelease{}, fmt.Errorf("row %q: %w", key, err)
		}
		if !modelIDPattern.MatchString(row.ModelID) {
			return feedRelease{}, fmt.Errorf("row %q model_id must be an org/repo identifier", key)
		}
		if _, ok := allowedStatuses[row.RuntimeStatus]; !ok {
			return feedRelease{}, fmt.Errorf("row %q runtime_status is invalid", key)
		}
		if row.ModelRevision != nil && !lowerHex40Pattern.MatchString(*row.ModelRevision) {
			return feedRelease{}, fmt.Errorf("row %q model_revision must be lowercase 40-hex", key)
		}
		if row.ModelSHA256 != nil && !lowerHex64Pattern.MatchString(*row.ModelSHA256) {
			return feedRelease{}, fmt.Errorf("row %q model_sha256 must be lowercase 64-hex", key)
		}
		if row.RuntimeStatus != "blocked" && (row.ModelRevision == nil || row.ModelSHA256 == nil) {
			return feedRelease{}, fmt.Errorf("row %q downloadable model requires model_revision and model_sha256", key)
		}
		if row.MinRAMGB == nil || *row.MinRAMGB < 0 {
			return feedRelease{}, fmt.Errorf("row %q min_ram_gb must be >= 0", key)
		}
		if _, ok := allowedBandwidthTiers[row.MinBandwidthTier]; !ok {
			return feedRelease{}, fmt.Errorf("row %q min_bandwidth_tier must be one of C, B, A, S", key)
		}
		if row.BenchGate == nil || row.BenchGate.MinSustainedTPS == nil ||
			math.IsNaN(valueOrNaN(row.BenchGate.MinSustainedTPS)) || math.IsInf(valueOrNaN(row.BenchGate.MinSustainedTPS), 0) ||
			*row.BenchGate.MinSustainedTPS < 0 {
			return feedRelease{}, fmt.Errorf("row %q bench_gate.min_sustained_tps must be finite and >= 0", key)
		}
		if row.BenchGate.Max4KTTFTMS == nil || *row.BenchGate.Max4KTTFTMS < 0 {
			return feedRelease{}, fmt.Errorf("row %q bench_gate.max_4k_ttft_ms must be >= 0", key)
		}
		if err := validateCandidateBenchGateProvenance(release.version, digestHex, signerKeyID, key, row.BenchGate.Provenance, allowPinnedMissingProvenance); err != nil {
			return feedRelease{}, err
		}
		if err := validateCandidateWorkloads(key, row); err != nil {
			return feedRelease{}, err
		}
	}
	return release, nil
}

func validateCandidateBenchGateProvenance(releaseVersion, candidateSHA256, signerKeyID, rowKey string, provenance *candidateBenchProvenance, allowPinnedMissingProvenance bool) error {
	if provenance == nil {
		if allowPinnedMissingProvenance &&
			signerKeyID == staticV4SignerKeyID &&
			releaseVersion == transitionMissingProvenanceCandidateRelease &&
			candidateSHA256 == transitionMissingProvenanceCandidateSHA256 &&
			transitionMissingProvenanceCandidateRows[rowKey] {
			return nil
		}
		return fmt.Errorf("row %q bench_gate.provenance is required", rowKey)
	}
	allowedSources := map[string]struct{}{
		"measured_single_host":   {},
		"runtime_validated_only": {},
		"policy":                 {},
		"no_throughput_bench":    {},
		"never_benched":          {},
		"legacy_unverified":      {},
	}
	if _, ok := allowedSources[provenance.Source]; !ok {
		return fmt.Errorf("row %q bench_gate.provenance.source is invalid", rowKey)
	}
	for field, value := range map[string]optionalProvenanceString{
		"hardware":    provenance.Hardware,
		"measured_at": provenance.MeasuredAt,
		"notes":       provenance.Notes,
	} {
		if value.present && strings.TrimSpace(value.value) == "" {
			return fmt.Errorf("row %q bench_gate.provenance.%s must be non-empty when present", rowKey, field)
		}
	}
	return nil
}

var transitionMissingProvenanceCandidateRows = map[string]bool{
	"google-gemma-4-26b-a4b-it":        true,
	"meta-llama/llama-3.1-8b-instruct": true,
	"meta-llama/llama-3.2-3b-instruct": true,
	"nvidia/nemotron-3-nano-30b-a3b":   true,
	"openai/gpt-oss-20b":               true,
	"qwen2.5-coder-32b-instruct":       true,
	"qwen3-32b":                        true,
	"qwen3-8b":                         true,
	"qwen3-coder-30b-a3b-instruct":     true,
}

func validateCandidateWorkloads(rowKey string, row candidateRow) error {
	for index, draft := range row.DraftCandidates {
		if draft.DraftModel == nil || draft.DraftArtifactSHA256 == nil {
			return fmt.Errorf("row %q draft_candidates[%d] requires draft_model and draft_model_artifact_sha256", rowKey, index)
		}
	}
	allowedWorkloads := map[string]int{
		"short_chat": 8000, "medium_with_system": 12000, "long_context": 60000,
		"code_completion": 12000, "agent_style": 20000,
	}
	contextCaps := map[string]int{"8gb": 8192, "16gb": 20000, "32gb": 50000, "64gb_plus": 120000}
	for workload, tiers := range row.WorkloadProfiles {
		expectedTTFT, ok := allowedWorkloads[workload]
		if !ok || len(tiers) == 0 {
			return fmt.Errorf("row %q workload_profiles workload or tiers is invalid", rowKey)
		}
		for tier, profile := range tiers {
			cap, ok := contextCaps[tier]
			if !ok {
				return fmt.Errorf("row %q workload_profiles tier %q is invalid", rowKey, tier)
			}
			if err := validateCandidateWorkloadProfile(rowKey, expectedTTFT, cap, profile, row.DraftCandidates); err != nil {
				return err
			}
		}
	}
	return nil
}

func validateCandidateWorkloadProfile(rowKey string, expectedTTFT, contextCap int, profile candidateWorkloadProfile, drafts []candidateDraftCandidate) error {
	gate, metrics := profile.GatePolicy, profile.ProfileMetrics
	if profile.Source == nil || *profile.Source == "" || gate == nil || metrics == nil ||
		gate.MinSamples == nil || *gate.MinSamples != 20 || gate.MaxP95TTFTMS == nil || *gate.MaxP95TTFTMS != expectedTTFT ||
		gate.MaxStopTokenLeakRate == nil || *gate.MaxStopTokenLeakRate != 0 || !gate.MinMedianTPS.present || gate.MinMedianTPS.value != nil ||
		!metrics.MedianTPS.present || !metrics.P95TTFTMS.present || !metrics.StopTokenLeakRate.present || !metrics.SpecDecodeAcceptanceRate.present || metrics.SampleCount == nil {
		return fmt.Errorf("row %q workload profile required policy or metric fields are invalid", rowKey)
	}
	for label, value := range map[string]*float64{
		"median_tps": metrics.MedianTPS.value, "p95_ttft_ms": metrics.P95TTFTMS.value,
		"stop_token_leak_rate": metrics.StopTokenLeakRate.value, "spec_decode_acceptance_rate": metrics.SpecDecodeAcceptanceRate.value,
	} {
		if value != nil && (math.IsNaN(*value) || math.IsInf(*value, 0) || *value < 0) {
			return fmt.Errorf("row %q workload profile %s is invalid", rowKey, label)
		}
	}
	if metrics.StopTokenLeakRate.value != nil && *metrics.StopTokenLeakRate.value > 1 ||
		metrics.SpecDecodeAcceptanceRate.value != nil && *metrics.SpecDecodeAcceptanceRate.value > 1 || *metrics.SampleCount < 0 {
		return fmt.Errorf("row %q workload profile bounded metrics are invalid", rowKey)
	}
	status := ""
	if profile.Status != nil {
		status = *profile.Status
	}
	if status == "no_winner" {
		allowedReasons := map[string]bool{"insufficient_samples": true, "gate_unmet": true, "hard_failure": true, "no_cells_evaluated": true}
		if profile.NoWinnerReason == nil || !allowedReasons[*profile.NoWinnerReason] || profile.Recommended != nil ||
			metrics.MedianTPS.value != nil || metrics.P95TTFTMS.value != nil || metrics.StopTokenLeakRate.value != nil || metrics.SpecDecodeAcceptanceRate.value != nil {
			return fmt.Errorf("row %q workload no_winner profile is invalid", rowKey)
		}
		switch *profile.NoWinnerReason {
		case "no_cells_evaluated", "hard_failure":
			if *metrics.SampleCount != 0 {
				return fmt.Errorf("row %q workload no_winner sample_count is invalid", rowKey)
			}
		case "insufficient_samples":
			if *metrics.SampleCount <= 0 || *metrics.SampleCount >= *gate.MinSamples {
				return fmt.Errorf("row %q workload no_winner sample_count is invalid", rowKey)
			}
		case "gate_unmet":
			if *metrics.SampleCount < *gate.MinSamples {
				return fmt.Errorf("row %q workload no_winner sample_count is invalid", rowKey)
			}
		}
		return nil
	}
	if status != "" && status != "winner" || profile.NoWinnerReason != nil || profile.Recommended == nil {
		return fmt.Errorf("row %q workload winner status is invalid", rowKey)
	}
	recommended := profile.Recommended
	if recommended.KVBits == nil || *recommended.KVBits < 0 || recommended.MaxContextOverride == nil || *recommended.MaxContextOverride <= 0 ||
		recommended.MaxConcurrencyOverride == nil || *recommended.MaxConcurrencyOverride <= 0 || metrics.P95TTFTMS.value == nil ||
		*metrics.P95TTFTMS.value > float64(*gate.MaxP95TTFTMS) || metrics.StopTokenLeakRate.value == nil ||
		*metrics.StopTokenLeakRate.value > *gate.MaxStopTokenLeakRate || *metrics.SampleCount < *gate.MinSamples {
		return fmt.Errorf("row %q workload winner metrics are invalid", rowKey)
	}
	hasDraft := recommended.DraftModel != nil || recommended.DraftArtifactSHA256 != nil || recommended.NumDraftTokens != nil
	if !hasDraft {
		return nil
	}
	if recommended.DraftModel == nil || recommended.DraftArtifactSHA256 == nil || !lowerHex64Pattern.MatchString(*recommended.DraftArtifactSHA256) ||
		recommended.NumDraftTokens == nil || *recommended.NumDraftTokens < 1 || *recommended.NumDraftTokens > 16 ||
		*recommended.MaxConcurrencyOverride > 1 || *recommended.MaxContextOverride > contextCap || profile.CandidateSource == nil ||
		!(strings.HasPrefix(*profile.CandidateSource, "static_draft_candidates:") || strings.HasPrefix(*profile.CandidateSource, "research_fixture:") || strings.HasPrefix(*profile.CandidateSource, "local_operator_override:")) {
		return fmt.Errorf("row %q workload speculative recommendation is invalid", rowKey)
	}
	if strings.HasPrefix(*profile.CandidateSource, "static_draft_candidates:") {
		for _, draft := range drafts {
			if draft.DraftModel != nil && draft.DraftArtifactSHA256 != nil && *draft.DraftModel == *recommended.DraftModel && *draft.DraftArtifactSHA256 == *recommended.DraftArtifactSHA256 {
				return nil
			}
		}
		return fmt.Errorf("row %q workload speculative recommendation is not bound to draft_candidates", rowKey)
	}
	return nil
}

func valueOrNaN(value *float64) float64 {
	if value == nil {
		return math.NaN()
	}
	return *value
}

func validateFeedEnvelope(version, policyVersion, generatedAt, source, expectedSource string, rowCount int) (feedRelease, error) {
	if strings.TrimSpace(version) == "" || strings.TrimSpace(version) != version {
		return feedRelease{}, fmt.Errorf("version must be a non-empty trimmed string")
	}
	if strings.TrimSpace(policyVersion) == "" || strings.TrimSpace(policyVersion) != policyVersion {
		return feedRelease{}, fmt.Errorf("policy_version must be a non-empty trimmed string")
	}
	parsedGeneratedAt, err := time.Parse(time.RFC3339, generatedAt)
	if err != nil {
		return feedRelease{}, fmt.Errorf("generated_at must be RFC3339: %w", err)
	}
	if source != expectedSource {
		return feedRelease{}, fmt.Errorf("source must be %q", expectedSource)
	}
	if rowCount == 0 {
		return feedRelease{}, fmt.Errorf("rows must not be empty")
	}
	return feedRelease{version: version, policyVersion: policyVersion, generatedAt: parsedGeneratedAt}, nil
}

func validateModelKey(key string) error {
	if !modelKeyPattern.MatchString(key) || strings.Contains(key, "//") {
		return fmt.Errorf("model key must be a normalized lowercase identifier")
	}
	return nil
}

func decodeStrictJSON(raw []byte, dst any) error {
	if err := rejectDuplicateJSONKeys(raw); err != nil {
		return err
	}
	decoder := json.NewDecoder(bytes.NewReader(raw))
	decoder.DisallowUnknownFields()
	if err := decoder.Decode(dst); err != nil {
		return err
	}
	if err := requireJSONEOF(decoder); err != nil {
		return err
	}
	return nil
}

func rejectDuplicateJSONKeys(raw []byte) error {
	decoder := json.NewDecoder(bytes.NewReader(raw))
	decoder.UseNumber()
	if err := scanJSONValue(decoder); err != nil {
		return err
	}
	if _, err := decoder.Token(); err != io.EOF {
		if err == nil {
			return fmt.Errorf("trailing JSON data")
		}
		return fmt.Errorf("trailing JSON data: %w", err)
	}
	return nil
}

func scanJSONValue(decoder *json.Decoder) error {
	token, err := decoder.Token()
	if err != nil {
		return err
	}
	delim, ok := token.(json.Delim)
	if !ok {
		return nil
	}
	switch delim {
	case '{':
		seen := make(map[string]struct{})
		for decoder.More() {
			keyToken, err := decoder.Token()
			if err != nil {
				return err
			}
			key, ok := keyToken.(string)
			if !ok {
				return fmt.Errorf("JSON object key must be a string")
			}
			if _, duplicate := seen[key]; duplicate {
				return fmt.Errorf("duplicate JSON field %q", key)
			}
			seen[key] = struct{}{}
			if err := scanJSONValue(decoder); err != nil {
				return err
			}
		}
		closing, err := decoder.Token()
		if err != nil {
			return err
		}
		if closing != json.Delim('}') {
			return fmt.Errorf("invalid JSON object closing delimiter")
		}
	case '[':
		for decoder.More() {
			if err := scanJSONValue(decoder); err != nil {
				return err
			}
		}
		closing, err := decoder.Token()
		if err != nil {
			return err
		}
		if closing != json.Delim(']') {
			return fmt.Errorf("invalid JSON array closing delimiter")
		}
	default:
		return fmt.Errorf("unexpected JSON delimiter %q", delim)
	}
	return nil
}

func requireJSONEOF(decoder *json.Decoder) error {
	var trailing any
	if err := decoder.Decode(&trailing); err != io.EOF {
		if err == nil {
			return fmt.Errorf("trailing JSON data")
		}
		return fmt.Errorf("trailing JSON data: %w", err)
	}
	return nil
}

type configFeedError string

func (e configFeedError) Error() string { return string(e) }

func configPairError(label string) error {
	return configFeedError("autotune." + label + "_path and autotune." + label + "_sig_path must both be set")
}

func configEmptyFeedError(label string) error {
	return configFeedError("autotune." + label + " feed file is empty")
}

func WithAutotuneFeeds(feeds AutotuneFeeds) Option {
	return func(s *Server) {
		s.autotuneFeedsMu.Lock()
		defer s.autotuneFeedsMu.Unlock()
		s.autotuneFeeds = feeds
	}
}

// SetAutotuneFeeds atomically swaps the served signed feed bytes. The SIGHUP
// reload calls this only after the new feeds are loaded and signature-verified
// (LoadAutotuneFeeds); on any failure the caller keeps the prior feeds
// (fail-closed), so /v1/rate-card etc. never serve unverified bytes.
func (s *Server) SetAutotuneFeeds(feeds AutotuneFeeds) {
	s.autotuneFeedsMu.Lock()
	defer s.autotuneFeedsMu.Unlock()
	s.autotuneFeeds = feeds
}

func (s *Server) autotuneFeedsSnapshot() AutotuneFeeds {
	s.autotuneFeedsMu.RLock()
	defer s.autotuneFeedsMu.RUnlock()
	return s.autotuneFeeds
}

func (s *Server) handleDemandRank(w http.ResponseWriter, r *http.Request) {
	feeds := s.autotuneFeedsSnapshot()
	s.serveAutotuneFeedBytes(w, r, feeds.DemandRankJSON, feeds.demandRankEnabled())
}

func (s *Server) handleDemandRankSig(w http.ResponseWriter, r *http.Request) {
	feeds := s.autotuneFeedsSnapshot()
	s.serveAutotuneFeedBytes(w, r, feeds.DemandRankSig, feeds.demandRankEnabled())
}

func (s *Server) handleAutotuneCandidates(w http.ResponseWriter, r *http.Request) {
	feeds := s.autotuneFeedsSnapshot()
	s.serveAutotuneFeedBytes(w, r, feeds.AutotuneCandidatesJSON, feeds.autotuneCandidatesEnabled())
}

func (s *Server) handleAutotuneCandidatesSig(w http.ResponseWriter, r *http.Request) {
	feeds := s.autotuneFeedsSnapshot()
	s.serveAutotuneFeedBytes(w, r, feeds.AutotuneCandidatesSig, feeds.autotuneCandidatesEnabled())
}

func (s *Server) handleAutotuneRelease(w http.ResponseWriter, r *http.Request) {
	if !s.allowReceiptKeys(r) {
		w.Header().Set("Retry-After", "1")
		writeError(w, http.StatusTooManyRequests, "rate_limited", "Autotune feed endpoint rate limit exceeded")
		return
	}
	feeds := s.autotuneFeedsSnapshot()
	if !feeds.rateCardEnabled() || !feeds.demandRankEnabled() || !feeds.autotuneCandidatesEnabled() {
		writeError(w, http.StatusNotFound, "autotune_feed_not_found", "Autotune release not found")
		return
	}
	feedStatus := map[string]any{
		"autotune_candidates": map[string]any{
			"sha256":        feeds.AutotuneCandidatesVerification.SHA256,
			"signer_key_id": feeds.AutotuneCandidatesVerification.KeyID,
			"verified_at":   feeds.AutotuneCandidatesVerification.VerifiedAt.Format(time.RFC3339Nano),
		},
		"demand_rank": map[string]any{
			"sha256":        feeds.DemandRankVerification.SHA256,
			"signer_key_id": feeds.DemandRankVerification.KeyID,
			"verified_at":   feeds.DemandRankVerification.VerifiedAt.Format(time.RFC3339Nano),
		},
	}
	if feeds.rateCardEnabled() {
		feedStatus["rate_card"] = map[string]any{
			"sha256":        feeds.RateCardVerification.SHA256,
			"signer_key_id": feeds.RateCardVerification.KeyID,
			"verified_at":   feeds.RateCardVerification.VerifiedAt.Format(time.RFC3339Nano),
		}
	}
	w.Header().Set("Content-Type", "application/json")
	w.Header().Set("Cache-Control", "no-store")
	_ = json.NewEncoder(w).Encode(map[string]any{
		"status":         "live_verified",
		"release_id":     feeds.AutotuneCandidatesVerification.Version,
		"policy_version": feeds.AutotuneCandidatesVerification.PolicyVersion,
		"generated_at":   feeds.AutotuneCandidatesVerification.GeneratedAt.Format(time.RFC3339),
		"feeds":          feedStatus,
	})
}

func (s *Server) serveAutotuneFeedBytes(w http.ResponseWriter, r *http.Request, body []byte, enabled bool) {
	if !s.allowReceiptKeys(r) {
		w.Header().Set("Retry-After", "1")
		writeError(w, http.StatusTooManyRequests, "rate_limited", "Autotune feed endpoint rate limit exceeded")
		return
	}
	if !enabled {
		writeError(w, http.StatusNotFound, "autotune_feed_not_found", "Autotune feed not found")
		return
	}
	w.Header().Set("Content-Type", "application/json")
	w.Header().Set("Cache-Control", "public, max-age=300")
	if _, err := w.Write(body); err != nil {
		s.log.Warn().Err(err).Msg("write autotune feed response failed")
	}
}
