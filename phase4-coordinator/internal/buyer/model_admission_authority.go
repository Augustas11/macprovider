package buyer

import (
	"bytes"
	"context"
	"crypto/sha256"
	"encoding/hex"
	"fmt"
	"time"

	"github.com/augstar/macprovider-coordinator/internal/autotune"
	"github.com/augstar/macprovider-coordinator/internal/billing"
	"github.com/augstar/macprovider-coordinator/internal/config"
	"github.com/augstar/macprovider-coordinator/internal/modelidentity"
	"github.com/augstar/macprovider-coordinator/internal/pool"
	"github.com/augstar/macprovider-coordinator/internal/tier2"
	providerws "github.com/augstar/macprovider-coordinator/internal/ws"
)

// ResolveModelAdmissionAuthority resolves a primary from verified loader bytes,
// independently admitted session identity, Tier2 and the effective billing row.
// It never uses offer hash/price/fit assertions as authority.
func (s *Server) ResolveModelAdmissionAuthority(ctx context.Context, p pool.Provider, event providerws.ModelAdmissionEvent) (providerws.ModelAdmissionEvent, error) {
	return s.resolveModelAdmissionAuthority(ctx, p, event, nil)
}

func (s *Server) resolveModelAdmissionAuthority(ctx context.Context, p pool.Provider, event providerws.ModelAdmissionEvent, capture *admissionAuthorityCapture) (providerws.ModelAdmissionEvent, error) {
	unavailable := func(reason string) (providerws.ModelAdmissionEvent, error) {
		return providerws.ModelAdmissionEvent{}, fmt.Errorf("model admission authority: %s", reason)
	}
	if !s.ModelAdmissionAuthorityReady() || !s.modelAdmissionAvailable(p.ProviderID, p.AssignedID) {
		return unavailable("transport_authority_unavailable")
	}
	live, found := s.pool.Resolve(p.ProviderID, p.AssignedID)
	if !found {
		return unavailable("session_replaced")
	}
	if _, err := s.pool.Conn(p.ProviderID, p.AssignedID); err != nil {
		return unavailable("session_disconnected")
	}
	if live.ModelID != p.ModelID || live.ModelHash != p.ModelHash || live.ExpectedModelHash != p.ExpectedModelHash || live.ModelHashAlgorithm != p.ModelHashAlgorithm ||
		live.CatalogAdmissionMode != p.CatalogAdmissionMode || live.CatalogPolicyVersion != p.CatalogPolicyVersion || live.CatalogSignerKeyID != p.CatalogSignerKeyID ||
		live.CandidateCatalogSHA256 != p.CandidateCatalogSHA256 || live.CatalogReleaseID != p.CatalogReleaseID || live.CandidateRowIdentity != p.CandidateRowIdentity ||
		!bytes.Equal(live.ReceiptPubkey, p.ReceiptPubkey) {
		return unavailable("session_changed")
	}
	// The caller's selection can be stale even when its identity still matches.
	if live.State != pool.StateReady && live.State != pool.StateBusy {
		return unavailable("session_not_ready")
	}
	s.autotuneFeedsMu.RLock()
	feeds, feedGeneration := cloneAdmissionFeeds(s.autotuneFeeds), s.autotuneFeedsGeneration
	s.autotuneFeedsMu.RUnlock()
	now := s.now().UTC()
	if !isLowerHex64(event.DiscoveryDigestSHA256) || !isLowerHex64(event.EvaluationDigestSHA256) || !feeds.admissionAuthorityVerified || event.RuntimeSource != "mlx_cache" || p.ProviderID != event.ProviderID ||
		p.ModelID != event.ServedModelRef || p.AssignedID == "" || !p.IsWSTunneled() || (p.State != pool.StateReady && p.State != pool.StateBusy) ||
		p.ModelHashAlgorithm != modelidentity.SnapshotManifestV1 || p.ModelHash != p.ExpectedModelHash || !isLowerHex64(p.ExpectedModelHash) ||
		p.CatalogAdmissionMode != "current" || len(p.PendingReceiptPubkey) > 0 || p.AuthState == pool.AuthBearerlessDuplicate || p.AuthState == pool.AuthSelfMinted ||
		p.BenchmarkQuarantined || p.AdmissionCeilingExcluded || p.AdmissionEvidenceStale || p.AdmissionSandboxed {
		return unavailable("session_or_feed_unavailable")
	}
	// Mutable admission gates and receipt rotation must come from the current
	// registry snapshot, even when a previously selected session still matches.
	p = live
	if len(p.PendingReceiptPubkey) > 0 || p.AuthState == pool.AuthBearerlessDuplicate || p.AuthState == pool.AuthSelfMinted ||
		p.BenchmarkQuarantined || p.AdmissionCeilingExcluded || p.AdmissionEvidenceStale || p.AdmissionSandboxed {
		return unavailable("current_session_excluded")
	}
	for _, sanction := range s.pool.CanarySanctions() {
		if sanction.ProviderID == p.ProviderID && sanction.FailCount > 0 {
			return unavailable("sanctioned")
		}
	}
	for _, f := range []struct {
		raw   []byte
		proof AutotuneFeedVerification
	}{
		{feeds.AutotuneCandidatesJSON, feeds.AutotuneCandidatesVerification}, {feeds.CatalogArtifactsJSON, feeds.CatalogArtifactsVerification}, {feeds.RateCardJSON, feeds.RateCardVerification},
	} {
		digest := sha256.Sum256(f.raw)
		if len(f.raw) == 0 || hex.EncodeToString(digest[:]) != f.proof.SHA256 || f.proof.KeyID == "" ||
			now.Before(f.proof.GeneratedAt) || !now.Before(f.proof.GeneratedAt.Add(14*24*time.Hour)) {
			return unavailable("feed_stale_or_changed")
		}
	}
	candidateProof, artifactProof, rateProof := feeds.AutotuneCandidatesVerification, feeds.CatalogArtifactsVerification, feeds.RateCardVerification
	if p.CandidateCatalogSHA256 != candidateProof.SHA256 || p.CatalogReleaseID != candidateProof.Version || p.CatalogSignerKeyID != candidateProof.KeyID ||
		p.CatalogPolicyVersion != candidateProof.PolicyVersion || candidateProof.KeyID != artifactProof.KeyID || candidateProof.KeyID != rateProof.KeyID ||
		candidateProof.Version != artifactProof.Version || candidateProof.PolicyVersion != artifactProof.PolicyVersion || candidateProof.PolicyVersion != rateProof.PolicyVersion ||
		!candidateProof.GeneratedAt.Equal(artifactProof.GeneratedAt) || !candidateProof.GeneratedAt.Equal(rateProof.GeneratedAt) {
		return unavailable("release_or_signer_mismatch")
	}
	var candidates candidateCatalogFeed
	var artifacts catalogArtifactsFeed
	var rates rateCardFeed
	if decodeStrictJSON(feeds.AutotuneCandidatesJSON, &candidates) != nil || decodeStrictJSON(feeds.CatalogArtifactsJSON, &artifacts) != nil || decodeStrictJSON(feeds.RateCardJSON, &rates) != nil {
		return unavailable("invalid_feed")
	}
	key := ""
	var row candidateRow
	for candidateKey, candidate := range candidates.Rows {
		if candidate.ModelID == p.ModelID {
			if key != "" {
				return unavailable("ambiguous_model")
			}
			key, row = candidateKey, candidate
		}
	}
	if key == "" || (event.CatalogModelKey != "" && event.CatalogModelKey != key) || row.RuntimeStatus != "recommendable" || row.ModelSHA256 == nil || *row.ModelSHA256 != p.ModelHash || row.ModelRevision == nil {
		return unavailable("primary_candidate_mismatch")
	}
	catalog, err := autotune.ParseCatalog(feeds.AutotuneCandidatesJSON)
	if err != nil {
		return unavailable("candidate_catalog_invalid")
	}
	identity, ok := catalog.RowIdentity(key)
	if !ok || identity != p.CandidateRowIdentity {
		return unavailable("session_row_mismatch")
	}
	model, ok := artifacts.Models[key]
	if !ok {
		return unavailable("artifact_missing")
	}
	artifact, ok := model.Artifacts[model.PrimaryArtifactID]
	if !ok || artifact.VerificationStatus != "verified" || artifact.RuntimeFormat != "mlx_safetensors" || artifact.Hash != p.ModelHash ||
		artifact.HashAlgorithm != modelidentity.SnapshotManifestV1 || artifact.SourceRef == nil || artifact.SourceRef.RepoID.value != p.ModelID || artifact.SourceRef.Revision.value != *row.ModelRevision ||
		len(artifact.AllowedRuntimeSources) != 1 || artifact.AllowedRuntimeSources[0] != "mlx_cache" || artifacts.CandidateCatalogSHA256 != candidateProof.SHA256 || artifacts.ReleaseID != candidateProof.Version {
		return unavailable("primary_artifact_mismatch")
	}
	referenceCatalog := tier2.Default()
	material, ok := referenceCatalog.RouteSnapshotMaterial(p.ModelID, p.ModelHash)
	if !ok || !s.byomSettlementPrereqsReady(p, material) || material.ExpectedModelHashAlgorithm != modelidentity.SnapshotManifestV1 ||
		!now.Before(material.CatalogExpiresAt) {
		return unavailable("settlement_reference_unavailable")
	}
	s.billingMu.RLock()
	store, cfg, snapshotID, billingGeneration := s.billing, cloneAdmissionRewards(s.billingCfg), s.billingSnapshotID, s.billingAuthorityGeneration
	s.billingMu.RUnlock()
	if store == nil || snapshotID <= 0 {
		return unavailable("billing_unavailable")
	}
	signed, ok := rates.Rows[key]
	effective, effectiveOK := cfg.RateCard[key]
	if !ok || !effectiveOK || signed.PromptRatePerMtok == nil || signed.PromptCacheHitRatePerMtok == nil || signed.CompletionRatePerMtok == nil || signed.ProviderShareBPS == nil || signed.GlobalMultiplierPPM == nil {
		return unavailable("explicit_rate_missing")
	}
	receiptKey, err := billing.ReceiptKeyID(p.ReceiptPubkey)
	if err != nil {
		return unavailable("receipt_key_unavailable")
	}
	expires := artifactProof.GeneratedAt.Add(14 * 24 * time.Hour)
	if material.CatalogExpiresAt.Before(expires) {
		expires = material.CatalogExpiresAt
	}
	evidence := billing.ArtifactAdmissionEvidence{
		ArtifactFeedSHA256: artifactProof.SHA256, ArtifactID: model.PrimaryArtifactID, ArtifactHash: artifact.Hash, ArtifactHashAlgorithm: artifact.HashAlgorithm,
		ArtifactFeedSignerKeyID: artifactProof.KeyID, CandidateCatalogSHA256: candidateProof.SHA256, ArtifactReleaseID: artifacts.ReleaseID, CandidateReleaseID: candidateProof.Version,
		CandidateSignerKeyID: candidateProof.KeyID, RateCardSHA256: rateProof.SHA256, RateCardVersion: rates.Version, RateCardSignerKeyID: rateProof.KeyID,
		CatalogModelKey: key, ConfigSnapshotID: snapshotID, PromptRatePerMtok: *signed.PromptRatePerMtok, PromptCacheHitRatePerMtok: *signed.PromptCacheHitRatePerMtok,
		CompletionRatePerMtok: *signed.CompletionRatePerMtok, ProviderShareBPS: *signed.ProviderShareBPS, GlobalMultiplierPPM: *signed.GlobalMultiplierPPM,
		PriceUnit: "credits_per_million_tokens", ProviderSessionID: p.AssignedID, ProviderReceiptKeyID: receiptKey, AuthorityExpiresAtUnixMS: expires.UnixMilli(), ProbeExpiresAtUnixMS: now.Add(10 * time.Minute).UnixMilli(),
	}
	if !evidence.MatchesRates(effective, billing.ParseMultiplierPPM(cfg.GlobalMultiplier), billing.ParseShareBps(cfg.ProviderShare)) || evidence.Validate() != nil {
		return unavailable("effective_rate_mismatch")
	}
	if err := store.VerifyArtifactAdmissionConfig(ctx, evidence); err != nil {
		return unavailable("persisted_rate_mismatch")
	}
	if capture != nil {
		*capture = admissionAuthorityCapture{feedGeneration: feedGeneration, billingGeneration: billingGeneration, store: store, catalog: referenceCatalog, material: material, provider: p, settlement: store.SettlementConfig(config.Default().Settlement)}
		if billing.VerifiedModelSettlementMode(capture.settlement) != billing.RouteSnapshotModeEnforce {
			return unavailable("settlement_mode_changed")
		}
	}
	event.CatalogModelKey = key
	event.CatalogID = material.CatalogID
	event.CatalogBodyDigest = material.CatalogBodyDigest
	event.CatalogSignatureKeyID = material.CatalogSignatureKeyID
	event.CatalogSignaturePubkeyFingerprint = material.CatalogSignaturePubkeyFingerprint
	event.ExpectedCatalogModelHash = material.ExpectedModelHash
	event.ExpectedCatalogModelHashAlgorithm = material.ExpectedModelHashAlgorithm
	event.ArtifactAdmissionEvidence = &evidence
	return event, nil
}
