package billing

import (
	"context"
	"database/sql"
	"errors"
	"fmt"

	"github.com/augstar/macprovider-coordinator/internal/modelidentity"
)

// ArtifactAdmissionEvidence is coordinator-captured authority, never a provider
// assertion. It is an optional, all-or-none extension: old snapshots omit it.
// The Tier2 catalog digest remains in RouteSnapshot.CatalogBodyDigest.
type ArtifactAdmissionEvidence struct {
	ArtifactFeedSHA256        string `json:"artifact_feed_sha256"`
	ArtifactID                string `json:"artifact_id"`
	ArtifactHash              string `json:"artifact_hash"`
	ArtifactHashAlgorithm     string `json:"artifact_hash_algorithm"`
	ArtifactFeedSignerKeyID   string `json:"artifact_feed_signer_key_id"`
	CandidateCatalogSHA256    string `json:"candidate_catalog_sha256"`
	ArtifactReleaseID         string `json:"artifact_release_id"`
	CandidateReleaseID        string `json:"candidate_release_id"`
	CandidateSignerKeyID      string `json:"candidate_signer_key_id"`
	RateCardSHA256            string `json:"admission_rate_card_sha256"`
	RateCardVersion           string `json:"admission_rate_card_version"`
	RateCardSignerKeyID       string `json:"admission_rate_card_signer_key_id"`
	CatalogModelKey           string `json:"admission_rate_model_key"`
	ConfigSnapshotID          int64  `json:"admission_billing_config_snapshot_id"`
	PromptRatePerMtok         int64  `json:"admission_prompt_rate_per_mtok"`
	PromptCacheHitRatePerMtok int64  `json:"admission_prompt_cache_hit_rate_per_mtok"`
	CompletionRatePerMtok     int64  `json:"admission_completion_rate_per_mtok"`
	ProviderShareBPS          int64  `json:"admission_provider_share_bps"`
	GlobalMultiplierPPM       int64  `json:"admission_global_multiplier_ppm"`
	PriceUnit                 string `json:"admission_price_unit"`
	ProviderSessionID         string `json:"admission_provider_session_id"`
	ProviderReceiptKeyID      string `json:"admission_provider_receipt_key_id"`
	AuthorityExpiresAtUnixMS  int64  `json:"admission_authority_expires_at_unix_ms"`
	ProbeExpiresAtUnixMS      int64  `json:"admission_probe_expires_at_unix_ms"`
}

func (e ArtifactAdmissionEvidence) Validate() error {
	for _, v := range []string{e.ArtifactFeedSHA256, e.ArtifactHash, e.CandidateCatalogSHA256, e.RateCardSHA256, e.RateCardVersion} {
		if !hex64Pattern.MatchString(v) {
			return fmt.Errorf("invalid artifact admission digest")
		}
	}
	if e.ArtifactID == "" || e.CatalogModelKey == "" || e.CatalogModelKey == "default" ||
		e.ArtifactHashAlgorithm != modelidentity.SnapshotManifestV1 || e.ArtifactReleaseID == "" ||
		e.ArtifactReleaseID != e.CandidateReleaseID || e.ArtifactFeedSignerKeyID == "" ||
		e.ArtifactFeedSignerKeyID != e.CandidateSignerKeyID || e.RateCardSignerKeyID != e.CandidateSignerKeyID ||
		e.ConfigSnapshotID <= 0 || e.PriceUnit != "credits_per_million_tokens" || e.ProviderSessionID == "" ||
		!receiptKeyIDPattern.MatchString(e.ProviderReceiptKeyID) || e.AuthorityExpiresAtUnixMS <= 0 || e.ProbeExpiresAtUnixMS <= 0 ||
		e.PromptRatePerMtok < 0 || e.PromptCacheHitRatePerMtok < 0 || e.CompletionRatePerMtok < 0 ||
		e.ProviderShareBPS < 0 || e.ProviderShareBPS > 10000 || e.GlobalMultiplierPPM < 0 {
		return fmt.Errorf("incomplete or inconsistent artifact admission authority")
	}
	return nil
}

func (e ArtifactAdmissionEvidence) RateEntry() RateCardEntry {
	rate := RateCardEntry{PromptCreditsPerMtok: e.PromptRatePerMtok, CompletionCreditsPerMtok: e.CompletionRatePerMtok}
	rate.SetPromptCacheHitCreditsPerMtok(e.PromptCacheHitRatePerMtok)
	return rate
}

func (e ArtifactAdmissionEvidence) MatchesRates(rate RateCardEntry, multiplier, share int64) bool {
	return e.PromptRatePerMtok == rate.PromptCreditsPerMtok && e.PromptCacheHitRatePerMtok == rate.EffectivePromptCacheHitCreditsPerMtok() &&
		e.CompletionRatePerMtok == rate.CompletionCreditsPerMtok && e.GlobalMultiplierPPM == multiplier && e.ProviderShareBPS == share
}

// VerifyArtifactAdmissionConfig checks the immutable billing row captured for
// this attempt. It never substitutes a current feed or default rate.
func (s *Store) VerifyArtifactAdmissionConfig(ctx context.Context, e ArtifactAdmissionEvidence) error {
	return verifyArtifactAdmissionConfig(ctx, s.db, e)
}
func verifyArtifactAdmissionConfig(ctx context.Context, q snapshotQueryer, e ArtifactAdmissionEvidence) error {
	cfg, multiplier, share, err := snapshotByIDQueryer(ctx, q, e.ConfigSnapshotID)
	if err != nil {
		return err
	}
	rate, ok := cfg.RateCard[e.CatalogModelKey]
	if !ok || !e.MatchesRates(rate, multiplier, share) {
		return fmt.Errorf("artifact admission billing snapshot mismatch")
	}
	return nil
}

// loadArtifactAdmissionForAttempt preserves legacy recovery behavior when the
// extension is absent from an intact route. Stored snapshots must pass their
// immutable digest before extension absence can select legacy rates.
func loadArtifactAdmissionForAttempt(ctx context.Context, q snapshotQueryer, id SettlementReceiptIdentity) (*ArtifactAdmissionEvidence, error) {
	var present int
	err := q.QueryRowContext(ctx, `SELECT 1 FROM settlement_route_snapshots WHERE account_scope=? AND request_id=? AND attempt_n=? AND provider_id=?`, id.AccountScope, id.RequestID, id.AttemptN, id.ProviderID).Scan(&present)
	if errors.Is(err, sql.ErrNoRows) {
		// Legacy requests may lack a route, but a retained receipt verdict
		// proves this attempt had settlement evidence that is now missing.
		var verdictPresent int
		lookupErr := q.QueryRowContext(ctx, `SELECT 1 FROM settlement_receipt_verdicts WHERE account_scope_hash=? AND request_id=? AND attempt_n=? AND provider_id=?`, SettlementAccountScopeHash(id.AccountScope), id.RequestID, id.AttemptN, id.ProviderID).Scan(&verdictPresent)
		if lookupErr == nil {
			return nil, fmt.Errorf("settlement route snapshot missing for retained receipt verdict")
		}
		if !errors.Is(lookupErr, sql.ErrNoRows) {
			return nil, lookupErr
		}
		return nil, nil
	}
	if err != nil {
		return nil, err
	}
	route, _, err := loadSettlementRouteSnapshotConn(ctx, q, id)
	if err != nil {
		return nil, err
	}
	return route.ArtifactAdmissionEvidence, nil
}
