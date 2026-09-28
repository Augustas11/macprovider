package ws

import (
	"crypto/ed25519"
	"crypto/sha256"
	"encoding/base64"
	"encoding/hex"
	"encoding/json"
	"fmt"
	"os"
	"strings"
	"time"

	"github.com/augstar/macprovider-coordinator/internal/config"
	"github.com/augstar/macprovider-coordinator/internal/pool"
)

type nativeMTPCanaryDetachedSignature struct {
	Alg       string `json:"alg"`
	KeyID     string `json:"key_id"`
	Signature string `json:"signature"`
}

func (s *Server) loadNativeMTPCanaryBank() {
	cfg := s.cfg.Pool.NativeMTPCanary
	if !cfg.Enabled {
		return
	}
	bank, err := loadVerifiedNativeMTPChallengeBank(cfg)
	if err != nil {
		s.log.Warn().Err(err).Msg("native MTP canary disabled; challenge bank verification failed")
		s.nativeMTPCanaryBank = nil
		return
	}
	s.nativeMTPCanaryBank = &bank
}

func loadVerifiedNativeMTPChallengeBank(cfg config.NativeMTPCanaryConfig) (NativeMTPChallengeBank, error) {
	raw, err := os.ReadFile(strings.TrimSpace(cfg.ChallengeBankPath))
	if err != nil {
		return NativeMTPChallengeBank{}, fmt.Errorf("read challenge bank: %w", err)
	}
	sigRaw, err := os.ReadFile(strings.TrimSpace(cfg.SignaturePath))
	if err != nil {
		return NativeMTPChallengeBank{}, fmt.Errorf("read challenge bank signature: %w", err)
	}
	sig, err := parseNativeMTPCanaryDetachedSignature(sigRaw)
	if err != nil {
		return NativeMTPChallengeBank{}, fmt.Errorf("parse challenge bank signature: %w", err)
	}
	if sig.Alg != "Ed25519" || sig.KeyID == "" || sig.KeyID != cfg.SignerKeyID {
		return NativeMTPChallengeBank{}, fmt.Errorf("challenge bank signature key binding mismatch")
	}
	keyring, err := cfg.DecodePublicKeyring()
	if err != nil {
		return NativeMTPChallengeBank{}, err
	}
	pub, ok := keyring[sig.KeyID]
	if !ok {
		return NativeMTPChallengeBank{}, fmt.Errorf("challenge bank signer key %q not trusted", sig.KeyID)
	}
	sigBytes, err := decodeNativeMTPCanarySignature(sig.Signature)
	if err != nil {
		return NativeMTPChallengeBank{}, err
	}
	if !ed25519.Verify(pub, raw, sigBytes) {
		return NativeMTPChallengeBank{}, fmt.Errorf("challenge bank signature verification failed")
	}
	sum := sha256.Sum256(raw)
	return ParseNativeMTPChallengeBank(raw, NativeMTPChallengeBankBinding{
		SignerKeyID:    cfg.SignerKeyID,
		EnvelopeKeyID:  sig.KeyID,
		ExpectedSHA256: hex.EncodeToString(sum[:]),
	})
}

func parseNativeMTPCanaryDetachedSignature(raw []byte) (nativeMTPCanaryDetachedSignature, error) {
	var obj map[string]json.RawMessage
	if err := strictObject(raw, []string{"alg", "key_id", "signature"}, &obj); err != nil {
		return nativeMTPCanaryDetachedSignature{}, err
	}
	alg, err := stringField(obj, "alg")
	if err != nil {
		return nativeMTPCanaryDetachedSignature{}, err
	}
	keyID, err := stringField(obj, "key_id")
	if err != nil {
		return nativeMTPCanaryDetachedSignature{}, err
	}
	signature, err := stringField(obj, "signature")
	if err != nil {
		return nativeMTPCanaryDetachedSignature{}, err
	}
	if containsControlChar(alg) || containsControlChar(keyID) || containsControlChar(signature) {
		return nativeMTPCanaryDetachedSignature{}, fmt.Errorf("control character")
	}
	return nativeMTPCanaryDetachedSignature{Alg: alg, KeyID: keyID, Signature: signature}, nil
}

func decodeNativeMTPCanarySignature(encoded string) ([]byte, error) {
	encoded = strings.TrimSpace(encoded)
	sig, err := base64.StdEncoding.Strict().DecodeString(encoded)
	if err != nil || base64.StdEncoding.EncodeToString(sig) != encoded {
		return nil, fmt.Errorf("challenge bank signature must be canonical padded base64")
	}
	if len(sig) != ed25519.SignatureSize {
		return nil, fmt.Errorf("challenge bank signature must decode to %d bytes", ed25519.SignatureSize)
	}
	return sig, nil
}

func (s *Server) handleNativeMTPTupleOffer(providerID, assignedID string, payload []byte) {
	offer, field, err := ParseNativeMTPTupleOffer(payload)
	if err != nil {
		s.log.Warn().Err(err).Str("field", field).Str("provider_id", providerID).Msg("invalid native MTP tuple offer")
		return
	}
	if offer.ProviderID != providerID || offer.AssignedID != assignedID {
		s.log.Warn().Str("provider_id", providerID).Msg("native MTP tuple offer rejected: stale session binding")
		return
	}
	if s.nativeMTPCanaryBank == nil || !s.cfg.Pool.NativeMTPCanary.Enabled {
		s.log.Debug().Str("provider_id", providerID).Msg("native MTP tuple offer ignored: canary disabled")
		return
	}
	if offer.ChallengeBankSHA256 != s.nativeMTPCanaryBank.RawSHA256 || offer.ChallengeBankReleaseID != s.nativeMTPCanaryBank.ReleaseID {
		s.sendNativeMTPTupleDisableForOffer(offer, "bank_mismatch")
		s.log.Warn().Str("provider_id", providerID).Msg("native MTP tuple offer rejected: challenge bank mismatch")
		return
	}
	if offer.SidecarDigest != offer.RuntimeTuple.SidecarDigest ||
		offer.NativeMTPRuntimeTupleSHA256 != nativeMTPRuntimeTupleIdentitySHA256(offer.ProviderID, offer.AssignedID, offer.TargetGeneration, offer.NativeMTPAdmissionTupleSHA256, offer.ServedSnapshotID) ||
		offer.TargetGeneration == 0 ||
		offer.SelftestProfile != "native_mtp_selftest_v1" {
		s.log.Warn().Str("provider_id", providerID).Msg("native MTP tuple offer rejected: tuple or selftest mismatch")
		return
	}
	if provider, ok := s.pool.Resolve(providerID, assignedID); !ok ||
		offer.RuntimeTuple.ModelID != provider.ModelID ||
		offer.RuntimeTuple.ModelHash != provider.ModelHash {
		s.log.Warn().Str("provider_id", providerID).Msg("native MTP tuple offer rejected: active session mismatch")
		return
	}
	_, ok := s.pool.SetNativeMTPTupleOffer(providerID, assignedID, pool.NativeMTPTupleOfferUpdate{
		TargetGeneration:              offer.TargetGeneration,
		ProviderRevision:              offer.ProviderRevision,
		RuntimeRevision:               offer.RuntimeRevision,
		NativeMTPAdmissionTupleSHA256: offer.NativeMTPAdmissionTupleSHA256,
		ServedSnapshotID:              offer.ServedSnapshotID,
		NativeMTPRuntimeTupleSHA256:   offer.NativeMTPRuntimeTupleSHA256,
		ChallengeBankSHA256:           offer.ChallengeBankSHA256,
		ChallengeBankReleaseID:        offer.ChallengeBankReleaseID,
		ChallengeCorpusSHA256:         offer.ChallengeCorpusSHA256,
		ModelID:                       offer.RuntimeTuple.ModelID,
		ModelHash:                     offer.RuntimeTuple.ModelHash,
		ModelHashAlgorithm:            offer.RuntimeTuple.ModelHashAlgorithm,
		TokenizerDigest:               offer.RuntimeTuple.TokenizerDigest,
		ArtifactDigest:                offer.RuntimeTuple.ArtifactDigest,
		ManifestDigest:                offer.RuntimeTuple.ManifestDigest,
		SidecarDigest:                 offer.RuntimeTuple.SidecarDigest,
		ProviderBinarySHA256:          offer.RuntimeTuple.ProviderBinarySHA256,
		RuntimeCDHash:                 offer.RuntimeTuple.RuntimeCDHash,
		CacheNamespace:                offer.RuntimeTuple.CacheNamespace,
		StateDigest:                   offer.RuntimeTuple.StateDigest,
		ProposalDepth:                 offer.RuntimeTuple.ProposalDepth,
		OfferedAt:                     s.now(),
	})
	if !ok {
		s.log.Warn().Str("provider_id", providerID).Msg("native MTP tuple offer rejected: provider session not active")
	}
}

func (s *Server) runNativeMTPCanaryLoop() {
	s.runNativeMTPCanarySweep()
	ticker := time.NewTicker(s.nativeMTPCanarySweepCadence())
	defer ticker.Stop()
	for range ticker.C {
		s.runNativeMTPCanarySweep()
	}
}

func (s *Server) runNativeMTPCanarySweep() {
	if s.nativeMTPCanaryBank == nil || s.nativeMTPCanaryStore == nil {
		return
	}
	now := s.now()
	for _, provider := range s.pool.Snapshot() {
		s.maybeDispatchNativeMTPCanary(provider, now)
	}
}

func (s *Server) maybeDispatchNativeMTPCanary(provider pool.Provider, now time.Time) bool {
	diag := provider.NativeMTPCanary
	if diag == nil || !diag.Offered || diag.Status == string(NativeMTPCanaryTupleDisabled) {
		return false
	}
	key := nativeMTPTupleKeyFromProvider(provider)
	if !key.valid() {
		return false
	}
	if _, err := s.nativeMTPCanaryStore.ExpireNativeMTPCanary(key, now); err != nil {
		return false
	}
	if state, ok := s.nativeMTPCanaryStore.NativeMTPCanaryState(key, now); ok {
		if updated, ok := s.recordNativeMTPCanaryState(provider.ProviderID, provider.AssignedID, key.RuntimeTupleSHA256, state); ok {
			if state.Status == NativeMTPCanaryTupleDisabled {
				s.sendNativeMTPTupleDisableOnce(updated, state.DisabledReason, state.DisabledAt)
			}
		}
		if state.InFlight != nil && now.Before(state.InFlightDeadline) {
			return false
		}
		if state.Status == NativeMTPCanaryTupleFresh && now.Before(state.NextDueAt) {
			return false
		}
		if state.Status == NativeMTPCanaryTupleDisabled {
			return false
		}
		if !state.NextDueAt.IsZero() && now.Before(state.NextDueAt) {
			return false
		}
	}
	record, ok := s.nativeMTPChallengeForProvider(provider)
	if !ok {
		return false
	}
	req, err := NewNativeMTPCanaryCoreRequest(key, record, now)
	if err != nil {
		return false
	}
	session, ok := s.storedSessionFor(provider.ProviderID, provider.AssignedID)
	if !ok {
		return false
	}
	wire := nativeMTPCanaryWireRequest(provider, record, req)
	raw, err := json.Marshal(wire)
	if err != nil {
		return false
	}
	if err := s.nativeMTPCanaryStore.BeginNativeMTPCanary(key, req, now); err != nil {
		return false
	}
	if err := session.send(raw); err != nil {
		_ = s.nativeMTPCanaryStore.CompleteNativeMTPCanary(key, req, NativeMTPCanaryCoreResult{}, NativeMTPCanaryEvaluation{
			Outcome:        NativeMTPCanaryReschedule,
			Reason:         "dispatch_send_failed",
			TrustSemantics: "observe_only",
		}, s.nativeMTPCanaryInterval(), now)
		return false
	}
	return true
}

func (s *Server) handleNativeMTPCanaryResult(providerID, assignedID string, payload []byte) {
	result, field, err := ParseNativeMTPCanaryResult(payload)
	if err != nil {
		s.log.Warn().Err(err).Str("field", field).Str("provider_id", providerID).Msg("invalid native MTP canary result")
		return
	}
	if result.ProviderID != providerID || result.AssignedID != assignedID {
		s.log.Warn().Str("provider_id", providerID).Msg("native MTP canary result rejected: stale session binding")
		return
	}
	provider, ok := s.pool.Resolve(providerID, assignedID)
	if !ok {
		return
	}
	key := nativeMTPTupleKeyFromProvider(provider)
	if !key.valid() ||
		result.TargetGeneration != key.TargetGeneration ||
		result.NativeMTPRuntimeTupleSHA256 != key.RuntimeTupleSHA256 ||
		result.ChallengeBankSHA256 != key.ChallengeBankSHA256 {
		s.log.Warn().Str("provider_id", providerID).Msg("native MTP canary result rejected: tuple binding mismatch")
		return
	}
	state, ok := s.nativeMTPCanaryStore.NativeMTPCanaryState(key, s.now())
	if !ok || state.InFlight == nil {
		s.log.Warn().Str("provider_id", providerID).Msg("native MTP canary result rejected: no in-flight tuple request")
		return
	}
	record, ok := s.nativeMTPChallengeForProvider(provider)
	if !ok || record.ChallengeID != result.ChallengeID {
		s.log.Warn().Str("provider_id", providerID).Msg("native MTP canary result rejected: challenge mismatch")
		return
	}
	core := nativeMTPCanaryCoreResultFromWire(result)
	eval := EvaluateNativeMTPCanaryCoreResult(*state.InFlight, record, core, s.now())
	if err := s.nativeMTPCanaryStore.CompleteNativeMTPCanary(key, *state.InFlight, core, eval, s.nativeMTPCanaryInterval(), s.now()); err != nil {
		s.log.Warn().Err(err).Str("provider_id", providerID).Msg("native MTP canary result rejected")
		return
	}
	if state, ok := s.nativeMTPCanaryStore.NativeMTPCanaryState(key, s.now()); ok {
		if updated, ok := s.recordNativeMTPCanaryState(providerID, assignedID, key.RuntimeTupleSHA256, state); ok {
			if state.Status == NativeMTPCanaryTupleDisabled {
				s.sendNativeMTPTupleDisableOnce(updated, state.DisabledReason, state.DisabledAt)
			}
		}
	}
}

func (s *Server) nativeMTPChallengeForProvider(provider pool.Provider) (NativeMTPChallengeRecord, bool) {
	if s.nativeMTPCanaryBank == nil {
		return NativeMTPChallengeRecord{}, false
	}
	for _, record := range s.nativeMTPCanaryBank.Entries {
		modelID := provider.ModelID
		modelHash := provider.ModelHash
		if provider.NativeMTPCanary != nil {
			modelID = provider.NativeMTPCanary.ModelID
			modelHash = provider.NativeMTPCanary.ModelHash
		}
		if record.ModelID == modelID && strings.EqualFold(record.ModelHash, modelHash) {
			return record, true
		}
	}
	return NativeMTPChallengeRecord{}, false
}

func nativeMTPTupleKeyFromProvider(provider pool.Provider) NativeMTPCanaryTupleKey {
	diag := provider.NativeMTPCanary
	if diag == nil {
		return NativeMTPCanaryTupleKey{}
	}
	return NativeMTPCanaryTupleKey{
		ProviderID:          provider.ProviderID,
		AssignedID:          provider.AssignedID,
		TargetGeneration:    diag.TargetGeneration,
		RuntimeTupleSHA256:  diag.NativeMTPRuntimeTupleSHA256,
		ChallengeBankSHA256: diag.ChallengeBankSHA256,
	}
}

func (s *Server) recordNativeMTPCanaryState(providerID, assignedID, tupleSHA string, state NativeMTPCanaryTupleState) (pool.Provider, bool) {
	if !s.pool.UpdateNativeMTPCanaryStatus(providerID, assignedID, tupleSHA, pool.NativeMTPCanaryStatusUpdate{
		Status:         string(state.Status),
		LastOutcome:    string(state.LastOutcome),
		LastReason:     state.LastReason,
		LastCheckedAt:  state.LastCheckedAt,
		FreshUntil:     state.FreshUntil,
		NextDueAt:      state.NextDueAt,
		DisabledAt:     state.DisabledAt,
		DisabledReason: state.DisabledReason,
	}) {
		return pool.Provider{}, false
	}
	return s.pool.Resolve(providerID, assignedID)
}

func (s *Server) nativeMTPCanarySweepCadence() time.Duration {
	cadence := s.nativeMTPCanaryInterval() / 10
	if cadence < time.Second {
		return time.Second
	}
	if cadence > 30*time.Second {
		return 30 * time.Second
	}
	return cadence
}

func (s *Server) nativeMTPCanaryInterval() time.Duration {
	base := s.cfg.Pool.NativeMTPCanary.Interval()
	if s.nativeMTPCanaryJitter == nil {
		return base
	}
	jittered := s.nativeMTPCanaryJitter(base)
	if jittered < nativeMTPCanaryMinimumInterval {
		return nativeMTPCanaryMinimumInterval
	}
	return jittered
}

func nativeMTPCanaryWireRequest(provider pool.Provider, record NativeMTPChallengeRecord, req NativeMTPCanaryCoreRequest) NativeMTPCanaryRequest {
	diag := provider.NativeMTPCanary
	runtimeTuple := NativeMTPRuntimeTuple{
		ModelID:              diag.ModelID,
		ModelHash:            diag.ModelHash,
		ModelHashAlgorithm:   diag.ModelHashAlgorithm,
		ProviderRevision:     diag.ProviderRevision,
		RuntimeRevision:      diag.RuntimeRevision,
		TokenizerDigest:      diag.TokenizerDigest,
		ArtifactDigest:       diag.ArtifactDigest,
		ManifestDigest:       diag.ManifestDigest,
		SidecarDigest:        diag.SidecarDigest,
		ProviderBinarySHA256: diag.ProviderBinarySHA256,
		RuntimeCDHash:        diag.RuntimeCDHash,
		CacheNamespace:       diag.CacheNamespace,
		StateDigest:          diag.StateDigest,
		ProposalDepth:        diag.ProposalDepth,
	}
	tokens := make([]int, 0, len(req.PromptTokenIDs))
	for _, token := range req.PromptTokenIDs {
		tokens = append(tokens, int(token))
	}
	return NativeMTPCanaryRequest{
		Type:                          "native_mtp_canary_request_v1",
		Version:                       1,
		RequestID:                     req.RequestDigestSHA256,
		ProviderID:                    provider.ProviderID,
		AssignedID:                    provider.AssignedID,
		ModelID:                       record.ModelID,
		ModelHash:                     record.ModelHash,
		ModelHashAlgorithm:            "sha256",
		ProviderRevision:              diag.ProviderRevision,
		RuntimeRevision:               diag.RuntimeRevision,
		TargetGeneration:              req.TargetGeneration,
		TokenizerDigest:               record.TokenizerSHA256,
		ArtifactDigest:                record.ArtifactSHA256,
		ManifestDigest:                record.MTPManifestSHA256,
		SidecarDigest:                 diag.SidecarDigest,
		ProviderBinarySHA256:          diag.ProviderBinarySHA256,
		RuntimeCDHash:                 diag.RuntimeCDHash,
		CacheNamespace:                diag.CacheNamespace,
		StateDigest:                   diag.StateDigest,
		RuntimeTuple:                  runtimeTuple,
		ChallengeID:                   req.ChallengeID,
		ChallengeCorpusSHA256:         diag.ChallengeCorpusSHA256,
		ChallengeBankSHA256:           req.ChallengeBankSHA256,
		NativeMTPAdmissionTupleSHA256: diag.NativeMTPAdmissionTupleSHA256,
		ServedSnapshotID:              diag.ServedSnapshotID,
		NativeMTPRuntimeTupleSHA256:   req.RuntimeTupleSHA256,
		ExpectedTokenIDSHA256:         req.ExpectedTokenIDSHA256,
		ExpectedTerminalReason:        req.ExpectedTerminalReason,
		ExpectedCounters:              nativeMTPCountersFromCore(req.ExpectedCounters),
		ExpectedCommittedStateSHA256:  record.ExpectedCommittedStateSHA256,
		Nonce:                         req.Nonce,
		RequestDigest:                 req.RequestDigestSHA256,
		IssuedAt:                      req.IssuedAt.UTC().Format(time.RFC3339),
		ExpiresAt:                     req.ExpiresAt.UTC().Format(time.RFC3339),
		PromptTokenIDs:                tokens,
		MaxCompletionTokens:           int(req.MaxCompletionTokens),
		ProposalDepth:                 int(req.FixedProposalDepth),
	}
}

func nativeMTPCanaryCoreResultFromWire(result NativeMTPCanaryResult) NativeMTPCanaryCoreResult {
	return NativeMTPCanaryCoreResult{
		Profile:                    nativeMTPCanaryProfile,
		ProviderID:                 result.ProviderID,
		AssignedID:                 result.AssignedID,
		TargetGeneration:           result.TargetGeneration,
		RuntimeTupleSHA256:         result.NativeMTPRuntimeTupleSHA256,
		ChallengeBankSHA256:        result.ChallengeBankSHA256,
		ChallengeID:                result.ChallengeID,
		Nonce:                      result.Nonce,
		RequestDigestSHA256:        result.RequestDigest,
		ActualDecodePath:           result.ActualDecodePath,
		FallbackUsed:               result.FallbackUsed,
		CapacityUnavailable:        result.ActualDecodePath == "unavailable",
		ActualTokenIDSHA256:        result.ActualTokenIDSHA256,
		ActualTerminalReason:       result.TerminalReason,
		ActualCounters:             nativeMTPCountersToCore(result.Counters),
		ActualCommittedStateSHA256: result.CommittedStateSHA256,
		ResultDigestSHA256:         result.ResultDigest,
	}
}

func (s *Server) sendNativeMTPTupleDisableOnce(provider pool.Provider, reason string, disabledAt time.Time) bool {
	diag := provider.NativeMTPCanary
	if diag == nil || diag.TupleDisableSentAt.IsZero() == false {
		return false
	}
	issuedAt := disabledAt
	if issuedAt.IsZero() {
		issuedAt = s.now()
	}
	if !s.pool.MarkNativeMTPTupleDisableSent(provider.ProviderID, provider.AssignedID, diag.NativeMTPRuntimeTupleSHA256, issuedAt) {
		return false
	}
	return s.sendNativeMTPTupleDisable(nativeMTPTupleDisableFromDiagnostics(provider, nativeMTPTupleDisableReason(reason), issuedAt))
}

func (s *Server) sendNativeMTPTupleDisableForOffer(offer NativeMTPTupleOffer, reason string) bool {
	return s.sendNativeMTPTupleDisable(nativeMTPTupleDisableFromOffer(offer, nativeMTPTupleDisableReason(reason), s.now()))
}

func (s *Server) sendNativeMTPTupleDisable(disable NativeMTPTupleDisable) bool {
	raw, err := json.Marshal(disable)
	if err != nil {
		return false
	}
	session, ok := s.storedSessionFor(disable.ProviderID, disable.AssignedID)
	if !ok {
		return false
	}
	return session.send(raw) == nil
}

func nativeMTPTupleDisableFromDiagnostics(provider pool.Provider, reason string, issuedAt time.Time) NativeMTPTupleDisable {
	diag := provider.NativeMTPCanary
	disable := NativeMTPTupleDisable{
		Type:                          "native_mtp_tuple_disable_v1",
		Version:                       1,
		ProviderID:                    provider.ProviderID,
		AssignedID:                    provider.AssignedID,
		TargetGeneration:              diag.TargetGeneration,
		NativeMTPAdmissionTupleSHA256: diag.NativeMTPAdmissionTupleSHA256,
		ServedSnapshotID:              diag.ServedSnapshotID,
		NativeMTPRuntimeTupleSHA256:   diag.NativeMTPRuntimeTupleSHA256,
		Reason:                        reason,
		Nonce:                         nativeMTPTupleDisableNonce(provider.ProviderID, provider.AssignedID, diag.NativeMTPRuntimeTupleSHA256, reason, issuedAt),
		IssuedAt:                      issuedAt.UTC().Format(time.RFC3339),
	}
	disable.RequestDigest = nativeMTPTupleDisableRequestDigest(disable)
	return disable
}

func nativeMTPTupleDisableFromOffer(offer NativeMTPTupleOffer, reason string, issuedAt time.Time) NativeMTPTupleDisable {
	disable := NativeMTPTupleDisable{
		Type:                          "native_mtp_tuple_disable_v1",
		Version:                       1,
		ProviderID:                    offer.ProviderID,
		AssignedID:                    offer.AssignedID,
		TargetGeneration:              offer.TargetGeneration,
		NativeMTPAdmissionTupleSHA256: offer.NativeMTPAdmissionTupleSHA256,
		ServedSnapshotID:              offer.ServedSnapshotID,
		NativeMTPRuntimeTupleSHA256:   offer.NativeMTPRuntimeTupleSHA256,
		Reason:                        reason,
		Nonce:                         nativeMTPTupleDisableNonce(offer.ProviderID, offer.AssignedID, offer.NativeMTPRuntimeTupleSHA256, reason, issuedAt),
		IssuedAt:                      issuedAt.UTC().Format(time.RFC3339),
	}
	disable.RequestDigest = nativeMTPTupleDisableRequestDigest(disable)
	return disable
}

func nativeMTPTupleDisableReason(reason string) string {
	switch reason {
	case "timeout":
		return "timeout"
	case "expired_result":
		return "expired"
	case "unsupported_path_fallback":
		return "fallback"
	case "ordinary_or_classic":
		return "ordinary_or_classic"
	case "bank_mismatch":
		return "bank_mismatch"
	case "operator":
		return "operator"
	default:
		return "mismatch"
	}
}

func nativeMTPTupleDisableNonce(providerID, assignedID, tupleSHA, reason string, issuedAt time.Time) string {
	sum := sha256.Sum256([]byte(providerID + "\x00" + assignedID + "\x00" + tupleSHA + "\x00" + reason + "\x00" + issuedAt.UTC().Format(time.RFC3339Nano)))
	return hex.EncodeToString(sum[:16])
}

func nativeMTPCountersFromCore(c NativeMTPCanaryExpectedCounters) NativeMTPCanaryCounters {
	return NativeMTPCanaryCounters{Accepted: c.Accepted, Rejected: c.Rejected, Bonus: c.Bonus, Committed: c.Committed}
}

func nativeMTPCountersToCore(c NativeMTPCanaryCounters) NativeMTPCanaryExpectedCounters {
	return NativeMTPCanaryExpectedCounters{Accepted: c.Accepted, Rejected: c.Rejected, Bonus: c.Bonus, Committed: c.Committed}
}
