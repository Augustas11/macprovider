package buyer

import (
	"context"
	"encoding/base64"
	"encoding/hex"
	"fmt"
	"strings"

	"github.com/augstar/macprovider-coordinator/internal/billing"
	"github.com/augstar/macprovider-coordinator/internal/catalogbind"
	"github.com/augstar/macprovider-coordinator/internal/config"
	"github.com/augstar/macprovider-coordinator/internal/pool"
	"github.com/augstar/macprovider-coordinator/internal/relayblind"
	"github.com/augstar/macprovider-coordinator/internal/routing"
	"github.com/augstar/macprovider-coordinator/internal/tier2"
	providerws "github.com/augstar/macprovider-coordinator/internal/ws"
)

// relayBlindSettlementProfileConfigured reports whether the operator enabled
// the SPEC-022 R-13 lane, the only way relay-blind runs under enforce.
func (s *Server) relayBlindSettlementProfileConfigured() bool {
	return s != nil && s.relayBlind != nil && s.relayBlind.cfg.EnforceSettlementProfile == config.RelayBlindSettlementProfileV1
}

// relayBlindSettlementPrerequisite is the SPEC-022 R-13.2 session gate. Under
// enforce it applies to relay-blind work the content-independent
// prerequisites plaintext routing applies (routeSnapshotRejection, the R-2.3
// to R-2.5 hash-verified predicate, the shared route-snapshot identity
// prerequisites) plus the SPEC-001-R005 capability. It returns "" when the
// session is eligible, and always "" outside enforce.
func (s *Server) relayBlindSettlementPrerequisite(p pool.Provider) string {
	if !s.settlementEnforceMode() {
		return ""
	}
	if p.HandshakeAckPending {
		return "handshake_ack_pending"
	}
	switch routeSnapshotRejection(p) {
	case 0:
	case routing.ReasonCatalogMaterialMissing:
		return "catalog_material_missing"
	default:
		return "receipt_key_missing"
	}
	cfg := s.tier2Config()
	if s.effectiveHashStatus(p, cfg) != pool.HashStatusVerified || s.tier2ProviderExcludedForConfig(p, cfg) {
		return "hash_not_verified"
	}
	if expected := strings.TrimSpace(p.ExpectedModelHash); isLowerHex64(expected) {
		if agrees, present := catalogbind.Tier2AgreesWithAdmittedHash(tier2.Default(), p.ModelID, expected); present && !agrees {
			return "catalog_admission_conflict"
		}
	}
	if _, skip, err := routeSnapshotPrerequisites(p); skip != "" || err != nil {
		return "route_snapshot_unavailable"
	}
	if !p.RelayBlindSettlementReceiptV1 {
		return "relay_blind_settlement_capability_missing"
	}
	return ""
}

// relayBlindEnvelopeDigestHex re-encodes the SPEC-041 envelope_digest (43-byte
// canonical unpadded base64url) as the 64 lowercase hex snapshot prompt_hash.
func relayBlindEnvelopeDigestHex(digest string) (string, error) {
	raw, err := base64.RawURLEncoding.Strict().DecodeString(digest)
	if err != nil || len(raw) != 32 || base64.RawURLEncoding.EncodeToString(raw) != digest {
		return "", fmt.Errorf("relay-blind envelope digest is not canonical base64url SHA-256")
	}
	return hex.EncodeToString(raw), nil
}

// recordRelayBlindRouteSnapshot commits the SPEC-022 R-3.1 relay-blind route
// snapshot before dispatch (R-13.3) and returns the SPEC-001-R005
// relay_blind_settlement metadata bound to it. It runs only under enforce;
// every failure is fatal for this dispatch, never a skip, because a dispatch
// without the metadata produces no receipt and can never settle.
func (b *billingRecorder) recordRelayBlindRouteSnapshot(ctx context.Context, provider pool.Provider, reservation relayblind.Reservation) (*providerws.RelayBlindSettlementMetadata, error) {
	attemptN := b.beginRouteSnapshotAttempt()
	store, _, _ := b.server.billingState()
	if store == nil {
		return nil, fmt.Errorf("relay-blind settlement requires the billing store")
	}
	settlementCfg := store.SettlementConfig(config.Default().Settlement)
	routeMode := billing.VerifiedModelSettlementMode(settlementCfg)
	if routeMode != billing.RouteSnapshotModeEnforce {
		return nil, fmt.Errorf("relay-blind route snapshot requires enforce mode")
	}
	if reason := b.server.relayBlindSettlementPrerequisite(provider); reason != "" {
		return nil, fmt.Errorf("relay-blind settlement prerequisite failed: %s", reason)
	}
	// R-2.1: the snapshot model is the selected session's served model, and
	// it must agree with the envelope's canonical and provider models.
	if !modelIDEqual(provider.ModelID, reservation.ProviderModel) || !modelIDEqual(provider.ModelID, reservation.Model) {
		return nil, fmt.Errorf("relay-blind served model does not match the reservation")
	}
	promptHash, err := relayBlindEnvelopeDigestHex(reservation.EnvelopeDigest)
	if err != nil {
		return nil, err
	}
	prereq, skip, err := routeSnapshotPrerequisites(provider)
	if err != nil {
		return nil, err
	}
	if skip != "" {
		return nil, fmt.Errorf("verified model settlement enforce requires route snapshot: %s", skip)
	}
	ctx, cancel := newRouteSnapshotDispatchContext(ctx)
	defer cancel()
	poolView := b.state.poolRouteView()
	if poolView.externalRuntimeCandidate(provider) {
		return nil, fmt.Errorf("relay-blind settlement is global-pool only")
	}
	byomBinding, err := b.server.requireBYOMRouteSnapshotBindingForRoute(ctx, provider, prereq.material, poolView)
	if err != nil {
		return nil, wrapRouteSnapshotGuardPressure(err)
	}
	if provider.ArtifactIdentity != nil && !byomBinding.ArtifactDerived() {
		return nil, fmt.Errorf("artifact identity requires admission and feed evidence")
	}
	snapshot := b.routeSnapshotFor(provider, prereq, routeMode, attemptN, settlementCfg.PendingDeadlineSeconds)
	snapshot.PaidEntrypoint = billing.PaidEntrypointRelayBlindChat
	snapshot.PromptHashBasis = billing.PromptHashBasisRelayBlindEnvelopeV1
	snapshot.PromptHash = promptHash
	applyBYOMRouteSnapshotBinding(&snapshot, byomBinding)
	required, covered, hardwareDigest, err := computeIntegrityRouteBinding(provider, routeMode)
	if err != nil {
		return nil, err
	}
	snapshot.ComputeIntegrityCaptureRequired = required
	snapshot.ComputeIntegritySamplingCovered = covered
	snapshot.ComputeIntegrityHardwareDigest = hardwareDigest
	digest, recorded, err := b.commitSettlementRouteSnapshot(ctx, store, provider, byomBinding, false, attemptN, snapshot)
	if err != nil {
		return nil, err
	}
	if !recorded {
		// Plaintext enforce may continue without a snapshot under store
		// pressure; relay-blind may not, since no receipt could bind it.
		b.routeSnapshotStorePressure = false
		b.settlementPolicyMode = ""
		b.settlementPolicyVersion = ""
		return nil, fmt.Errorf("%w: relay-blind route snapshot not recorded", billing.ErrRouteSnapshotStorePressure)
	}
	meta := &providerws.RelayBlindSettlementMetadata{
		AccountScope:               snapshot.AccountScope,
		RequestID:                  snapshot.RequestID,
		AttemptN:                   snapshot.AttemptN,
		ProviderID:                 snapshot.ProviderID,
		ProviderReceiptKeyID:       snapshot.ProviderReceiptKeyID,
		ModelID:                    snapshot.ModelID,
		ExpectedCatalogModelHash:   snapshot.ExpectedCatalogModelHash,
		CatalogID:                  snapshot.CatalogID,
		CatalogBodyDigest:          snapshot.CatalogBodyDigest,
		RouteSnapshotDigest:        digest,
		RouteSnapshotPolicyVersion: snapshot.RouteSnapshotPolicyVersion,
		RouteSnapshotMode:          snapshot.RouteSnapshotMode,
		PendingDeadlineSeconds:     snapshot.PendingDeadlineSeconds,
		PaidEntrypoint:             snapshot.PaidEntrypoint,
		PromptHashBasis:            snapshot.PromptHashBasis,
		RelayBlindEnvelopeDigest:   reservation.EnvelopeDigest,
	}
	b.relayBlindSettlement = meta
	return meta, nil
}
