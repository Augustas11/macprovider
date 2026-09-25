package buyer

import (
	"bytes"
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"net/http"
	"strconv"
	"strings"

	"github.com/augstar/macprovider-coordinator/internal/billing"
	"github.com/augstar/macprovider-coordinator/internal/catalogbind"
	"github.com/augstar/macprovider-coordinator/internal/computeintegrity"
	"github.com/augstar/macprovider-coordinator/internal/config"
	"github.com/augstar/macprovider-coordinator/internal/modelidentity"
	"github.com/augstar/macprovider-coordinator/internal/pool"
	"github.com/augstar/macprovider-coordinator/internal/tier2"
	providerws "github.com/augstar/macprovider-coordinator/internal/ws"
)

const (
	promptHashBasisCoordinatorV1 = "coordinator_prompt_canonical_v1"
	statusClientClosedRequest    = 499
)

// routeSnapshotCatalogMaterial is the ONE Tier-2 route-snapshot material
// lookup. Dispatch (recordRouteSnapshot) and paid-routing eligibility both key
// it by the admitted row (byomMaterialHash), so routing can never select a
// session that dispatch then fails for missing material (#1689).
func routeSnapshotCatalogMaterial(p pool.Provider) (tier2.RouteSnapshotMaterial, bool) {
	return tier2.SnapshotMaterial(p.ModelID, byomMaterialHash(p))
}

// catalogMaterialMissing is the SPEC-022-R002 R-2.7 predicate: the session is
// not bound to a BYOM candidate and its served model has no Tier-2
// route-snapshot material, so under enforce recordRouteSnapshot must fail it
// ("missing catalog material"). BYOM-bound sessions fail closed without
// material on their own paths (dispatch and byomDefaultPaidRoutingEligibility),
// so they are not counted here.
func catalogMaterialMissing(p pool.Provider) bool {
	if byomAdmissionCandidate(p) {
		return false
	}
	_, ok := routeSnapshotCatalogMaterial(p)
	return !ok
}

// catalogMaterialMissingUnderEnforce applies R-2.7 with the live settlement
// mode, read from the same source dispatch reads (a nil billing store is not
// enforce, exactly as dispatch treats it).
func (s *Server) catalogMaterialMissingUnderEnforce(p pool.Provider) bool {
	return s != nil && catalogMaterialMissing(p) && s.settlementEnforceMode()
}

// CatalogMaterialMissingUnderEnforce exports the R-2.7 verdict so the
// provider WS server's /poolz.routing_eligible projection applies the same
// gate buyer routing does (wired in cmd/coordinator).
func (s *Server) CatalogMaterialMissingUnderEnforce(p pool.Provider) bool {
	return s.catalogMaterialMissingUnderEnforce(p)
}

func (b *billingRecorder) recordRouteSnapshot(providerBody []byte, provider pool.Provider) (*providerws.SettlementReceiptMetadata, error) {
	attemptN := b.routeSnapshotAttemptN
	b.routeSnapshotAttemptN++
	b.settlementAttemptN = 0
	b.hasSettlementAttemptN = false
	b.routeSnapshotStorePressure = false
	b.settlementPolicyMode = ""
	b.settlementPolicyVersion = ""
	b.settlementRouteSnapshot = nil
	b.settlementRouteSnapshotDigest = ""
	// A new dispatch: the delivered attempt's own recordRow names the credit
	// an evidence failure may quarantine, never an earlier attempt's.
	b.hasLastProviderAttempt = false

	reportedHash := strings.TrimSpace(provider.ModelHash)
	expectedHash := strings.TrimSpace(provider.ExpectedModelHash)
	// #608 Partial: fail closed on active Tier-2 vs admission-hash conflict
	// before any settlement observe/skip path can mask the disagreement.
	if isLowerHex64(expectedHash) {
		if agrees, present := catalogbind.Tier2AgreesWithAdmittedHash(tier2.Default(), provider.ModelID, expectedHash); present && !agrees {
			return nil, fmt.Errorf("tier2 catalog does not match signed admission row")
		}
	}
	parentCtx := context.Background()
	if b.req != nil {
		parentCtx = b.req.Context()
	}
	ctx, cancel := newRouteSnapshotDispatchContext(parentCtx)
	defer cancel()
	store, _, _ := b.server.billingState()
	if store == nil {
		return nil, nil
	}
	settlementCfg := store.SettlementConfig(config.Default().Settlement)
	routeMode := billing.VerifiedModelSettlementMode(settlementCfg)
	skipOrEnforceError := func(reason string) (*providerws.SettlementReceiptMetadata, error) {
		if routeMode == billing.RouteSnapshotModeEnforce {
			return nil, fmt.Errorf("verified model settlement enforce requires route snapshot: %s", reason)
		}
		return nil, nil
	}
	if len(provider.ReceiptPubkey) == 0 {
		return skipOrEnforceError("missing provider receipt key")
	}
	keyID, err := billing.ReceiptKeyID(provider.ReceiptPubkey)
	if err != nil {
		return skipOrEnforceError("invalid provider receipt key")
	}
	// SPEC-010 v1.7 R007: the expected identity is the artifact member the
	// session resolved through the release-bound feed, else the admitted row.
	expectedAlgorithm := modelidentity.SnapshotManifestV1
	if binding := provider.ArtifactIdentity; binding != nil {
		expectedAlgorithm, expectedHash = binding.Member.HashAlgorithm, binding.Member.Hash
	}
	if !modelidentity.CanonicalAlgorithm(provider.ModelHashAlgorithm) ||
		provider.ModelHashAlgorithm != expectedAlgorithm ||
		!isLowerHex64(reportedHash) ||
		!isLowerHex64(expectedHash) {
		return skipOrEnforceError("invalid canonical provider model identity")
	}
	if reportedHash != expectedHash {
		return skipOrEnforceError("provider model identity does not match signed admission row")
	}
	// Tier-2 material is keyed by the ROW digest; an artifact member looks it
	// up by the row the session was admitted against (byomMaterialHash, the
	// same derivation the routing-eligibility path uses).
	materialHash := byomMaterialHash(provider)
	material, ok := routeSnapshotCatalogMaterial(provider)
	if !ok {
		if byomAdmissionCandidate(provider) {
			return nil, fmt.Errorf("BYOM model admission requires trusted catalog material")
		}
		// catalogMaterialMissing(provider): routing already excludes this
		// session under enforce (R-2.7); this is the fail-closed backstop.
		return skipOrEnforceError("missing catalog material")
	}
	// The tier-2 row must agree with the ROW the session was admitted for
	// (SPEC-010-R004); an artifact member is verified against the feed by the
	// heartbeat path, so its own hash is compared elsewhere, never here.
	admittedRowHash := expectedHash
	if provider.ArtifactIdentity != nil {
		admittedRowHash = materialHash
	}
	if material.HashStatus != pool.HashStatusVerified || material.ExpectedModelHash != admittedRowHash {
		return nil, fmt.Errorf("tier2 catalog does not match signed admission row")
	}
	poolView := b.state.poolRouteView()
	byomBinding, err := b.server.requireBYOMRouteSnapshotBindingForRoute(ctx, provider, material, poolView)
	if err != nil {
		return nil, wrapRouteSnapshotGuardPressure(err)
	}
	// SPEC-022-R012.1: a pool-route external-runtime attempt records the
	// coordinator-derived runtime class (the binding verified that the hello
	// equals the candidate's signed offer class), the fenced generation, and
	// the operator account. Such an attempt requires enforce mode (R-12.3).
	externalRuntime := poolView.externalRuntimeCandidate(provider)
	if externalRuntime && routeMode != billing.RouteSnapshotModeEnforce {
		return nil, fmt.Errorf("pool external runtime attempt requires enforce-mode settlement")
	}
	// SPEC-010-R007(d): a session whose identity resolved through the feed —
	// a GGUF member OR a secondary snapshot member — settles only with the
	// six values, which come from the BYOM admission binding; without an
	// artifact-derived binding the snapshot would carry a member hash with no
	// provenance, indistinguishable from the row-bound primary path.
	if provider.ArtifactIdentity != nil && !byomBinding.ArtifactDerived() {
		return nil, fmt.Errorf("artifact identity requires admission and feed evidence")
	}
	promptHash, err := coordinatorPromptHash(providerBody)
	if err != nil {
		return nil, err
	}
	sessionID := stringPtrOrNil(provider.AssignedID)
	pendingDeadline := settlementCfg.PendingDeadlineSeconds
	if pendingDeadline <= 0 {
		// Fail-open to the SPEC-022 default (300s) rather than fail-closed.
		// Fail-closing emits route_snapshot_failed pre-dispatch. As of item
		// 18 the gateway treats a genuine first-attempt route_snapshot_failed
		// as no-charge (coordinatorPreDispatchNoChargeError refunds the
		// reservation and passes the body through verbatim — no provider was
		// invoked), so the buyer-charge concern that once made fail-open
		// load-bearing is resolved for that case. Fail-open to 300 is still
		// the better default here: it lets the request proceed on the SPEC-022
		// default deadline instead of failing outright on an unvalidated
		// in-memory deadline of 0.
		// Validated YAML config already rejects deadline 0 (config.Validate
		// enforces 1..900); this fallback only guards an unvalidated
		// in-memory caller, where fail-open is benign.
		pendingDeadline = config.Default().Settlement.PendingDeadlineSeconds
	}
	snapshot := billing.RouteSnapshot{
		AccountScope:                       accountScopeForSettlement(b.accountID),
		RequestID:                          b.requestID,
		AttemptN:                           int64(attemptN),
		ProviderID:                         provider.ProviderID,
		ProviderSessionID:                  sessionID,
		ProviderGenerationID:               nil,
		PaidEntrypoint:                     "coordinator_buyer_v1_chat_completions",
		ProviderReceiptKeyID:               keyID,
		ProviderReceiptKeySource:           "auth_session",
		ModelID:                            provider.ModelID,
		ProviderReportedModelHash:          reportedHash,
		ProviderReportedModelHashAlgorithm: expectedAlgorithm,
		ExpectedCatalogModelHash:           expectedHash,
		ExpectedCatalogModelHashAlgorithm:  expectedAlgorithm,
		CatalogID:                          material.CatalogID,
		CatalogBodyDigest:                  material.CatalogBodyDigest,
		CatalogSignatureKeyID:              material.CatalogSignatureKeyID,
		CatalogSignaturePubkeyFingerprint:  material.CatalogSignaturePubkeyFingerprint,
		CatalogExpiresAtUnixMS:             material.CatalogExpiresAt.UnixMilli(),
		Spec008HashStatus:                  string(routeSnapshotHashStatus(provider, material)),
		RouteSnapshotPolicyVersion:         billing.RouteSnapshotPolicyVersion,
		RouteSnapshotMode:                  routeMode,
		RouteDecisionTSUnixMS:              b.state.routingDone.UnixMilli(),
		RequestStartTSUnixMS:               b.startedAt.UnixMilli(),
		PendingDeadlineSeconds:             int64(pendingDeadline),
		PromptHashBasis:                    promptHashBasisCoordinatorV1,
		PromptHash:                         promptHash,
		// SPEC-042 R006: label the settlement route-snapshot with the pool
		// that served the request and its routing-time manifest labels (all
		// empty for global -> omitted from the digest).
		PoolID:             b.state.poolID,
		ManifestVersion:    b.state.poolManifestVersion,
		ManifestCoreDigest: b.state.poolManifestCoreDigest,
	}
	if externalRuntime {
		snapshot.RuntimeSource = provider.RuntimeSource
		snapshot.PoolGeneration = b.state.poolGeneration
		snapshot.PoolOperatorAccountID = poolView.creatorAccountID
	}
	applyBYOMRouteSnapshotBinding(&snapshot, byomBinding)
	computeIntegrityRequired, computeIntegrityCovered, computeIntegrityHardwareDigest, err := computeIntegrityRouteBinding(provider, routeMode)
	if err != nil {
		return nil, err
	}
	snapshot.ComputeIntegrityCaptureRequired = computeIntegrityRequired
	snapshot.ComputeIntegritySamplingCovered = computeIntegrityCovered
	snapshot.ComputeIntegrityHardwareDigest = computeIntegrityHardwareDigest
	var digest string
	insertStorePressure := false
	insertSnapshot := func() error {
		inserted, err := store.InsertRouteSnapshot(ctx, snapshot)
		insertStorePressure = errors.Is(wrapRouteSnapshotGuardPressure(err), billing.ErrRouteSnapshotStorePressure)
		digest = inserted
		return err
	}
	var insertErr error
	if externalRuntime {
		insertErr = b.server.insertPoolBYOMRouteSnapshot(ctx, provider, byomBinding, insertSnapshot)
	} else {
		insertErr = b.server.insertBYOMRouteSnapshot(ctx, provider, byomBinding, b.state, insertSnapshot)
	}
	if err := insertErr; err != nil {
		err = wrapRouteSnapshotGuardPressure(err)
		if routeSnapshotCanSkipStorePressure(routeMode, err, insertStorePressure) {
			b.routeSnapshotStorePressure = true
			b.settlementPolicyMode = routeMode
			b.settlementPolicyVersion = billing.RouteSnapshotPolicyVersion
			b.server.log.Warn().
				Err(err).
				Str("request_id", b.requestID).
				Str("provider_id", provider.ProviderID).
				Str("route_snapshot_mode", routeMode).
				Msg("route snapshot store pressure skipped before provider dispatch")
			return nil, nil
		}
		return nil, err
	}
	b.settlementAttemptN = attemptN
	b.hasSettlementAttemptN = true
	b.settlementRouteSnapshotDigest = digest
	b.settlementPolicyMode = snapshot.RouteSnapshotMode
	b.settlementPolicyVersion = snapshot.RouteSnapshotPolicyVersion
	b.settlementRouteSnapshot = nil
	if snapshot.RuntimeSource != "" {
		recorded := snapshot
		b.settlementRouteSnapshot = &recorded
	}
	meta := &providerws.SettlementReceiptMetadata{
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
		PromptHash:                 snapshot.PromptHash,
		OutputPrefixStartByte:      b.outputCursorByte,
		PendingDeadlineSeconds:     snapshot.PendingDeadlineSeconds,
	}
	// SPEC-015 §N.12: only a SPEC-022-R012 pool attempt carries the
	// per-request authorization, bound to this request attempt, provider, and
	// route snapshot digest. Every other frame is unchanged.
	if snapshot.RuntimeSource != "" {
		meta.PoolRuntimeAuthorization = &providerws.PoolRuntimeAuthorization{
			PoolID:              snapshot.PoolID,
			ManifestCoreDigest:  snapshot.ManifestCoreDigest,
			RuntimeSource:       snapshot.RuntimeSource,
			RequestID:           snapshot.RequestID,
			AttemptN:            snapshot.AttemptN,
			ProviderID:          snapshot.ProviderID,
			RouteSnapshotDigest: digest,
		}
	}
	return meta, nil
}

func isLowerHex64(value string) bool {
	if len(value) != 64 {
		return false
	}
	for _, ch := range value {
		if (ch < '0' || ch > '9') && (ch < 'a' || ch > 'f') {
			return false
		}
	}
	return true
}

func computeIntegrityRouteBinding(provider pool.Provider, routeMode string) (required bool, samplingProfileCovered bool, hardwareDigest string, err error) {
	if routeMode != billing.RouteSnapshotModeEnforce {
		return false, false, "", nil
	}
	policy := computeintegrity.NewDefaultPolicy()
	deps := computeintegrity.ActivationDeps{
		SPEC022Enforce:             true,
		SPEC022CoverageSubset:      true,
		AllModelsSignedCatalog:     true,
		SettlementStorageReady:     true,
		BillingExcludesNonVerified: true,
	}
	// SPEC-036 v0.1 enforce is explicitly maintainer-gated. Until an
	// authoritative compute_integrity_settlement policy and activation dependency
	// source are wired here, the safe default policy remains observe-only and
	// production route snapshots stay dormant.
	if policy.Mode != computeintegrity.ModeEnforce || !computeintegrity.CanActivateEnforce(policy, deps) {
		return false, false, "", nil
	}
	value := map[string]any{
		"schema_version":               "compute_integrity_route_hardware_runtime_class_v1",
		"provider_id":                  provider.ProviderID,
		"assigned_id":                  provider.AssignedID,
		"model_id":                     provider.ModelID,
		"binary_version":               provider.BinaryVersion,
		"attestation_tier":             provider.AttestationTier,
		"admitted_chip_normalized":     provider.AdmittedChipNormalized,
		"admitted_unified_memory_gb":   provider.AdmittedUnifiedMemoryGB,
		"max_admitted_model_key":       provider.MaxAdmittedModelKey,
		"max_admitted_model_id":        provider.MaxAdmittedModelID,
		"max_admitted_min_ram_gb":      provider.MaxAdmittedMinRAMGB,
		"provider_reported_model_hash": strings.TrimSpace(provider.ModelHash),
		"provider_reported_capacity":   nil,
	}
	if provider.HardwareCapacity != nil {
		value["provider_reported_capacity"] = map[string]any{
			"chip":               provider.HardwareCapacity.Chip,
			"bandwidth_gb_per_s": provider.HardwareCapacity.BandwidthGBPerSec,
			"network_power_kw":   provider.HardwareCapacity.NetworkPowerKW,
			"gpu_cores_total":    provider.HardwareCapacity.GPUCoresTotal,
			"cpu_cores_total":    provider.HardwareCapacity.CPUCoresTotal,
		}
	}
	digest, _, err := billing.CanonicalSHA256Hex(value)
	if err != nil {
		return false, false, "", fmt.Errorf("compute integrity route hardware digest: %w", err)
	}
	return true, true, "sha256:" + digest, nil
}

func accountScopeForSettlement(accountID string) string {
	return billing.AccountScopeForSettlement(accountID)
}

func stringPtrOrNil(value string) *string {
	if strings.TrimSpace(value) == "" {
		return nil
	}
	v := value
	return &v
}

func writeRouteSnapshotError(w http.ResponseWriter, rec *billingRecorder, err error) {
	rec.server.log.Warn().Err(err).Str("request_id", rec.requestID).Msg("route snapshot insert failed before provider dispatch")
	if errors.Is(err, context.Canceled) {
		rec.logBuyerFailure(statusClientClosedRequest, "Buyer canceled before route snapshot dispatch")
		writeError(w, statusClientClosedRequest, "request_canceled", "Request canceled before provider dispatch")
		return
	}
	if routeSnapshotShouldCapacityShed(err) {
		rec.logBuyerFailure(http.StatusServiceUnavailable, "Route snapshot guard is temporarily unavailable")
		w.Header().Set(routeSnapshotPressureHeader, "1")
		writeError(w, http.StatusServiceUnavailable, "no_provider_available", "No provider available for this model")
		return
	}
	rec.logBuyerFailure(http.StatusInternalServerError, "Could not durably record route snapshot")
	// The item-18 positive no-prior-dispatch marker is stamped centrally by
	// noPriorDispatchResponseWriter at WriteHeader time (based on the ledger-exact
	// rec.providerCredited signal). route_snapshot_failed is pre-dispatch — no
	// provider relayed this attempt — so the marker is present here iff no
	// provider was billably credited earlier in this request.
	writeError(w, http.StatusInternalServerError, "route_snapshot_failed", "Could not durably record route snapshot")
}

func wrapRouteSnapshotGuardPressure(err error) error {
	if err == nil || errors.Is(err, billing.ErrRouteSnapshotStorePressure) {
		return err
	}
	if billing.IsRouteSnapshotStorePressure(err) {
		return fmt.Errorf("%w: %w", billing.ErrRouteSnapshotStorePressure, err)
	}
	return err
}

func routeSnapshotShouldCapacityShed(err error) bool {
	if err == nil {
		return false
	}
	return errors.Is(err, billing.ErrRouteSnapshotStorePressure) || errors.Is(err, providerws.ErrModelAdmissionRouteDrift)
}

func routeSnapshotCanSkipStorePressure(routeMode string, err error, insertStorePressure bool) bool {
	switch routeMode {
	case billing.RouteSnapshotModeObserve, billing.RouteSnapshotModeEnforce:
		return errors.Is(err, billing.ErrRouteSnapshotStorePressure)
	default:
		return false
	}
}

func newRouteSnapshotDispatchContext(parent context.Context) (context.Context, context.CancelFunc) {
	if parent == nil {
		parent = context.Background()
	}
	return context.WithTimeout(parent, routeSnapshotDispatchTimeout)
}

const (
	settlementOutcomeHeader       = "X-MacProvider-Settlement-Outcome"
	settlementReceiptResultHeader = "X-MacProvider-Settlement-Receipt-Result"
	settlementReasonHeader        = "X-MacProvider-Settlement-Reason"
	settlementClosedHeader        = "X-MacProvider-Settlement-Closed"
	settlementModeHeader          = "X-MacProvider-Settlement-Mode"
	settlementPolicyVersionHeader = "X-MacProvider-Settlement-Policy-Version"
	settlementPendingUntilHeader  = "X-MacProvider-Settlement-Pending-Deadline-Unix-Ms"
	// settlementNoPriorDispatchHeader is the item-18 POSITIVE no-charge marker,
	// stamped centrally by noPriorDispatchResponseWriter on any terminal
	// response written while no provider has been billably credited for this
	// request (ledger-exact rec.providerCredited, plus dispatchedThisAttempt for
	// the current terminal). The gateway refunds a route_snapshot_failed / treats
	// a retried no_provider 503 as cold ONLY when this marker is present, so an
	// unmarked response (a legacy/rolled-back coordinator, or one that followed a
	// billed provider dispatch) settles on the estimate instead of wrongly
	// refunding. Known limitation (documented, carried): on the write-before-bill
	// streaming/WS paths the marker is decided from the outward wire status, which
	// can render a non-billable 503 as 502 — see SPEC-006 §17.7.
	settlementNoPriorDispatchHeader = "X-MacProvider-Settlement-No-Prior-Dispatch"
	// routeSnapshotPressureHeader marks a pre-dispatch no_provider 503 caused by
	// route-snapshot store pressure. Gateways preserve the existing no_provider
	// settlement/refund contract but must not retry these overloaded attempts.
	routeSnapshotPressureHeader = "X-MacProvider-Route-Snapshot-Pressure"
)

var settlementOutcomeHeaderNames = []string{
	settlementOutcomeHeader,
	settlementReceiptResultHeader,
	settlementReasonHeader,
	settlementClosedHeader,
	settlementModeHeader,
	settlementPolicyVersionHeader,
	settlementPendingUntilHeader,
}

func (b *billingRecorder) ingestSettlementReceipt(provider pool.Provider, header string) (billing.SettlementReceiptState, bool, error) {
	header = normalizeReceiptHeaderValue(header)
	if len(provider.ReceiptPubkey) == 0 || !b.hasSettlementAttemptN {
		return billing.SettlementReceiptState{}, false, nil
	}
	store, _, _ := b.server.billingState()
	if store == nil {
		return billing.SettlementReceiptState{}, false, nil
	}
	if b.settlementOutputMissingAfterCredit {
		// The credit is already durable. Failing the buyer here is what turns
		// a served completion into gateway prompt-only settlement (#1675).
		b.server.log.Warn().
			Str("request_id", b.requestID).
			Str("provider_id", provider.ProviderID).
			Str("event", "settlement_output_persist_failed_after_credit").
			Msg("skipping settlement receipt ingest after settlement output persist failure")
		return billing.SettlementReceiptState{}, false, nil
	}
	ctx, cancel := context.WithTimeout(context.Background(), settlementReceiptSynchronousTimeout)
	defer cancel()
	identity := billing.SettlementReceiptIdentity{
		AccountScope: accountScopeForSettlement(b.accountID),
		RequestID:    b.requestID,
		AttemptN:     int64(b.settlementAttemptN),
		ProviderID:   provider.ProviderID,
	}
	input := settlementReceiptRecoveryInput{
		identity:              identity,
		header:                header,
		providerReceiptPubkey: append([]byte(nil), provider.ReceiptPubkey...),
		poolLabels:            b.settlementPoolLabels(),
		receivedAtUnixMS:      store.ReceiptObservedAtUnixMS(),
	}
	if header == "" {
		// #1578: a leg the coordinator deliberately never settled — a 503
		// provider queue-full / no-capacity attempt — has no billing row and
		// no settlement_attempt_outputs row, so a missing-receipt verdict can
		// only ever fail with "settlement attempt output missing". Skip it:
		// there is no receipt to be missing when nothing was served and
		// nothing is owed. A BILLABLE leg still takes the path below, so a
		// genuinely absent attempt output on a served request stays loud.
		if !b.lastRecordedSettlementSubject {
			return billing.SettlementReceiptState{}, false, nil
		}
		state, err := b.server.persistSettlementReceipt(ctx, store, input)
		if err != nil {
			if settlementOutputPersistFailedAfterCredit(err) {
				if b.server.deferSettlementReceiptRecovery(input) {
					b.server.log.Warn().Err(err).Str("request_id", b.requestID).Str("provider_id", provider.ProviderID).Msg("missing settlement receipt recording deferred")
					return b.deferredSettlementReceiptState(input), true, nil
				}
				b.server.log.Error().Err(err).Str("request_id", b.requestID).Str("provider_id", provider.ProviderID).Msg("missing settlement receipt recovery queue unavailable")
				return billing.SettlementReceiptState{}, false, err
			}
			b.server.log.Warn().Err(err).Str("request_id", b.requestID).Str("provider_id", provider.ProviderID).Msg("missing settlement receipt recording failed")
		}
		return state, err == nil, err
	}
	state, err := b.server.persistSettlementReceipt(ctx, store, input)
	if err != nil {
		if settlementReceiptRetryable(err) {
			if b.server.deferSettlementReceiptRecovery(input) {
				b.server.log.Warn().Err(err).Str("request_id", b.requestID).Str("provider_id", provider.ProviderID).Msg("settlement receipt ingestion deferred")
				return b.deferredSettlementReceiptState(input), true, nil
			}
			b.server.log.Error().Err(err).Str("request_id", b.requestID).Str("provider_id", provider.ProviderID).Msg("settlement receipt recovery queue unavailable")
			return billing.SettlementReceiptState{}, false, err
		}
		b.server.log.Warn().Err(err).Str("request_id", b.requestID).Str("provider_id", provider.ProviderID).Msg("settlement receipt ingestion failed")
	}
	return state, err == nil, err
}

func setSettlementOutcomeHeaders(dst http.Header, state billing.SettlementReceiptState) {
	dst.Set(settlementOutcomeHeader, state.SettlementOutcome)
	dst.Set(settlementReceiptResultHeader, state.ReceiptResult)
	dst.Set(settlementReasonHeader, state.Reason)
	dst.Set(settlementClosedHeader, strconv.FormatBool(state.Closed))
	dst.Set(settlementModeHeader, state.RouteSnapshotMode)
	dst.Set(settlementPolicyVersionHeader, state.RouteSnapshotPolicyVersion)
	if state.PendingDeadlineUnixMS > 0 {
		dst.Set(settlementPendingUntilHeader, strconv.FormatInt(state.PendingDeadlineUnixMS, 10))
	}
}

func setInternalSettlementOutcomeHeaders(dst http.Header, rec *billingRecorder, state billing.SettlementReceiptState) {
	if rec == nil || rec.accountID == "" {
		return
	}
	setSettlementOutcomeHeaders(dst, state)
	setSettlementFinalityMAC(dst, rec)
}

func declareInternalSettlementOutcomeTrailers(dst http.Header, rec *billingRecorder) {
	if rec == nil || rec.accountID == "" {
		return
	}
	for _, header := range settlementOutcomeHeaderNames {
		dst.Add("Trailer", header)
	}
}

func coordinatorPromptHash(raw json.RawMessage) (string, error) {
	value, err := canonicalPromptObject(raw)
	if err != nil {
		return "", err
	}
	digest, _, err := billing.CanonicalSHA256Hex(value)
	return digest, err
}

func canonicalPromptObject(raw json.RawMessage) (map[string]any, error) {
	root, err := decodeJSONObject(raw)
	if err != nil {
		return nil, err
	}
	messages, err := canonicalMessages(root["messages"])
	if err != nil {
		return nil, err
	}
	tools, err := canonicalTools(root["tools"])
	if err != nil {
		return nil, err
	}
	return map[string]any{
		"model":             root["model"],
		"messages":          messages,
		"tools":             tools,
		"temperature":       jcsOrNull(root["temperature"]),
		"top_p":             jcsOrNull(root["top_p"]),
		"max_tokens":        jcsOrNull(root["max_tokens"]),
		"stop":              jcsOrNull(root["stop"]),
		"seed":              jcsOrNull(root["seed"]),
		"response_format":   jcsOrNull(root["response_format"]),
		"tool_choice":       jcsOrNull(root["tool_choice"]),
		"presence_penalty":  jcsOrNull(root["presence_penalty"]),
		"frequency_penalty": jcsOrNull(root["frequency_penalty"]),
		"logit_bias":        jcsOrNull(root["logit_bias"]),
		"logprobs":          jcsOrNull(root["logprobs"]),
		"top_logprobs":      jcsOrNull(root["top_logprobs"]),
		"n":                 jcsOrNull(root["n"]),
	}, nil
}

func canonicalMessages(value any) ([]any, error) {
	items, ok := value.([]any)
	if !ok {
		return nil, fmt.Errorf("messages must be array")
	}
	out := make([]any, 0, len(items))
	for _, item := range items {
		obj, ok := item.(map[string]any)
		if !ok {
			return nil, fmt.Errorf("message must be object")
		}
		role, ok := obj["role"].(string)
		if !ok {
			return nil, fmt.Errorf("message role must be string")
		}
		content, err := canonicalContent(obj["content"])
		if err != nil {
			return nil, err
		}
		toolCalls, err := canonicalToolCalls(obj["tool_calls"])
		if err != nil {
			return nil, err
		}
		out = append(out, map[string]any{
			"role":         role,
			"content":      content,
			"name":         jcsOrNull(obj["name"]),
			"tool_call_id": jcsOrNull(obj["tool_call_id"]),
			"tool_calls":   toolCalls,
		})
	}
	return out, nil
}

func canonicalContent(value any) (any, error) {
	switch x := value.(type) {
	case nil:
		return nil, nil
	case string:
		return normalizeLineEndings(x), nil
	case []any:
		out := make([]any, 0, len(x))
		for _, item := range x {
			part, err := canonicalContentPart(item)
			if err != nil {
				return nil, err
			}
			out = append(out, part)
		}
		return out, nil
	default:
		return nil, fmt.Errorf("unsupported message content")
	}
}

func canonicalContentPart(value any) (map[string]any, error) {
	obj, ok := value.(map[string]any)
	if !ok {
		return nil, fmt.Errorf("content part must be object")
	}
	typ, ok := obj["type"].(string)
	if !ok {
		return nil, fmt.Errorf("content part type must be string")
	}
	switch typ {
	case "text":
		text, ok := obj["text"].(string)
		if !ok {
			return nil, fmt.Errorf("text content must be string")
		}
		return map[string]any{"type": "text", "text": normalizeLineEndings(text)}, nil
	case "image_url":
		imageURL, ok := obj["image_url"].(map[string]any)
		if !ok {
			return nil, fmt.Errorf("image_url must be object")
		}
		url, ok := imageURL["url"].(string)
		if !ok {
			return nil, fmt.Errorf("image_url.url must be string")
		}
		return map[string]any{
			"type": "image_url",
			"image_url": map[string]any{
				"url":    url,
				"detail": jcsOrNull(imageURL["detail"]),
			},
		}, nil
	case "input_audio":
		audio, ok := obj["input_audio"].(map[string]any)
		if !ok {
			return nil, fmt.Errorf("input_audio must be object")
		}
		data, dataOK := audio["data"].(string)
		format, formatOK := audio["format"].(string)
		if !dataOK || !formatOK {
			return nil, fmt.Errorf("input_audio data and format must be strings")
		}
		return map[string]any{
			"type": "input_audio",
			"input_audio": map[string]any{
				"data":   data,
				"format": format,
			},
		}, nil
	default:
		return nil, fmt.Errorf("unsupported content part type %q", typ)
	}
}

func canonicalTools(value any) (any, error) {
	if value == nil {
		return nil, nil
	}
	items, ok := value.([]any)
	if !ok {
		return nil, fmt.Errorf("tools must be array")
	}
	out := make([]any, 0, len(items))
	for _, item := range items {
		obj, ok := item.(map[string]any)
		if !ok {
			return nil, fmt.Errorf("tool must be object")
		}
		function, ok := obj["function"].(map[string]any)
		if !ok {
			return nil, fmt.Errorf("tool.function must be object")
		}
		name, ok := function["name"].(string)
		if !ok {
			return nil, fmt.Errorf("tool.function.name must be string")
		}
		out = append(out, map[string]any{
			"type": "function",
			"function": map[string]any{
				"name":        name,
				"description": jcsOrNull(function["description"]),
				"parameters":  jcsOrNull(function["parameters"]),
			},
		})
	}
	return out, nil
}

func canonicalToolCalls(value any) (any, error) {
	if value == nil {
		return nil, nil
	}
	items, ok := value.([]any)
	if !ok {
		return nil, fmt.Errorf("tool_calls must be array")
	}
	out := make([]any, 0, len(items))
	for _, item := range items {
		obj, ok := item.(map[string]any)
		if !ok {
			return nil, fmt.Errorf("tool_call must be object")
		}
		id, idOK := obj["id"].(string)
		function, fnOK := obj["function"].(map[string]any)
		if !idOK || !fnOK {
			return nil, fmt.Errorf("tool_call id and function are required")
		}
		name, nameOK := function["name"].(string)
		arguments, argsOK := function["arguments"].(string)
		if !nameOK || !argsOK {
			return nil, fmt.Errorf("tool_call function name and arguments are required")
		}
		out = append(out, map[string]any{
			"id":   id,
			"type": "function",
			"function": map[string]any{
				"name":      name,
				"arguments": billing.RawJSONString(arguments),
			},
		})
	}
	return out, nil
}

func decodeJSONObject(raw json.RawMessage) (map[string]any, error) {
	dec := json.NewDecoder(bytes.NewReader(raw))
	dec.UseNumber()
	var value any
	if err := dec.Decode(&value); err != nil {
		return nil, err
	}
	obj, ok := value.(map[string]any)
	if !ok {
		return nil, fmt.Errorf("request must be object")
	}
	return obj, nil
}

func jcsOrNull(value any) any {
	if value == nil {
		return nil
	}
	return value
}

func normalizeLineEndings(value string) string {
	value = strings.ReplaceAll(value, "\r\n", "\n")
	return strings.ReplaceAll(value, "\r", "\n")
}

// routeSnapshotHashStatus is the SPEC-008 status the snapshot records: the
// tier-2 row comparison on the primary path; on the SPEC-010 v1.7 artifact
// path the session's verdict, which the heartbeat verifier reached by exact
// member equality against the release-bound feed (tier-2 material holds only
// the row digest and cannot judge a secondary member).
func routeSnapshotHashStatus(provider pool.Provider, material tier2.RouteSnapshotMaterial) pool.HashStatus {
	if provider.ArtifactIdentity != nil {
		return provider.HashStatus
	}
	return material.HashStatus
}
