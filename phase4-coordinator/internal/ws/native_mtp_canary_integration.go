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

	"github.com/augstar/macprovider-coordinator/internal/autotune"
	"github.com/augstar/macprovider-coordinator/internal/billing"
	"github.com/augstar/macprovider-coordinator/internal/config"
	"github.com/augstar/macprovider-coordinator/internal/pool"
)

type nativeMTPCanaryDetachedSignature struct {
	Alg       string `json:"alg"`
	KeyID     string `json:"key_id"`
	Signature string `json:"signature"`
}

// nativeMTPCanaryBankSet is the canary's verified challenge banks: the bank of
// the live release and, across one release transition, one bank of a retained
// compatible-previous release. It is replaced wholesale, never mutated, and
// only together with the admission catalog (under autotuneCatalogMu), so a
// reader that takes nativeMTPCanaryAdmissionSnapshot sees one consistent
// (banks, catalog, compatible) triple.
type nativeMTPCanaryBankSet struct {
	current  *NativeMTPChallengeBank
	previous *NativeMTPChallengeBank
}

// nativeMTPCanaryBankTransition is what a release reload stages for the
// canary: the verified bank of the release about to go live, or nil when that
// release carries no native-MTP admission set (the old current bank is then
// retired). It is applied at release publication, with the catalog.
type nativeMTPCanaryBankTransition struct {
	bank      *NativeMTPChallengeBank
	releaseID string
}

// NativeMTPCanaryServedBank is one release's served self-test bank bytes, as
// the verified AutotuneFeeds snapshot loaded them.
type NativeMTPCanaryServedBank struct {
	ReleaseID string
	BankJSON  []byte
	BankSig   []byte
}

type nativeMTPCanaryBootBanks struct {
	current  NativeMTPCanaryServedBank
	previous []NativeMTPCanaryServedBank
}

// WithNativeMTPCanaryServedBanks binds the boot-time canary bank to the
// served feed snapshot: `current` is the live release's served self-test bank
// and `previous` the retained compatible-previous releases' banks, newest
// first (SPEC-031-R033). Without this option an enabled canary holds no bank
// and admits nothing.
func WithNativeMTPCanaryServedBanks(current NativeMTPCanaryServedBank, previous []NativeMTPCanaryServedBank) Option {
	return func(s *Server) {
		s.nativeMTPCanaryBoot = &nativeMTPCanaryBootBanks{current: current, previous: previous}
	}
}

// loadNativeMTPCanaryBank installs the boot canary banks from the served feed
// snapshot: the current bank must verify under the canary keys, name the
// served release, and (when challenge_bank_path is configured) be the exact
// bytes at that path; otherwise the canary holds no bank and fails closed.
// One retained compatible-previous release's bank is reconstructed too, so a
// provider admitted on that release keeps binding across a restart.
func (s *Server) loadNativeMTPCanaryBank() {
	cfg := s.cfg.Pool.NativeMTPCanary
	if !cfg.Enabled {
		return
	}
	boot := s.nativeMTPCanaryBoot
	if boot == nil {
		s.log.Warn().Msg("native MTP canary holds no challenge bank: no served native-MTP feed snapshot was bound at boot")
		s.nativeMTPCanaryBanks.Store(nil)
		return
	}
	set := &nativeMTPCanaryBankSet{}
	current, err := verifyNativeMTPCanaryBootBank(cfg, boot.current)
	if err != nil {
		s.log.Warn().Err(err).Msg("native MTP canary holds no current challenge bank; served bank verification failed")
	} else {
		set.current = current
	}
	for _, served := range boot.previous {
		if current != nil && served.ReleaseID == current.ReleaseID {
			continue
		}
		bank, err := verifyNativeMTPCanaryReleaseBank(cfg, served.ReleaseID, served.BankJSON, served.BankSig)
		if err != nil || bank == nil {
			s.log.Warn().Err(err).Str("challenge_bank_release_id", served.ReleaseID).Msg("native MTP canary skipped a retained previous release bank")
			continue
		}
		if s.nativeMTPCanaryReleaseAdmitted(bank.ReleaseID) {
			set.previous = bank
			break
		}
	}
	if set.current == nil && set.previous == nil {
		s.nativeMTPCanaryBanks.Store(nil)
		return
	}
	s.nativeMTPCanaryBanks.Store(set)
	s.log.Info().
		Str("event", "native_mtp_canary_bank_loaded").
		Str("challenge_bank_release_id", releaseIDOf(set.current)).
		Str("challenge_bank_sha256", sha256Of(set.current)).
		Str("previous_challenge_bank_release_id", releaseIDOf(set.previous)).
		Str("previous_challenge_bank_sha256", sha256Of(set.previous)).
		Msg("native MTP canary challenge banks bound to the served release feeds")
}

func verifyNativeMTPCanaryBootBank(cfg config.NativeMTPCanaryConfig, served NativeMTPCanaryServedBank) (*NativeMTPChallengeBank, error) {
	if len(served.BankJSON) == 0 {
		return nil, fmt.Errorf("the served release carries no native-MTP self-test bank")
	}
	bank, err := verifyNativeMTPCanaryReleaseBank(cfg, served.ReleaseID, served.BankJSON, served.BankSig)
	if err != nil {
		return nil, err
	}
	if path := strings.TrimSpace(cfg.ChallengeBankPath); path != "" {
		raw, err := os.ReadFile(path)
		if err != nil {
			return nil, fmt.Errorf("read challenge bank: %w", err)
		}
		sum := sha256.Sum256(raw)
		if hex.EncodeToString(sum[:]) != bank.RawSHA256 {
			return nil, fmt.Errorf("challenge_bank_path bytes are not the served native-MTP self-test bank")
		}
	}
	return bank, nil
}

// currentNativeMTPCanaryBank is the bank of the live release, or nil.
func (s *Server) currentNativeMTPCanaryBank() *NativeMTPChallengeBank {
	if set := s.nativeMTPCanaryBanks.Load(); set != nil {
		return set.current
	}
	return nil
}

// nativeMTPCanaryHasBank reports whether the canary holds any bank.
func (s *Server) nativeMTPCanaryHasBank() bool {
	set := s.nativeMTPCanaryBanks.Load()
	return set != nil && (set.current != nil || set.previous != nil)
}

// nativeMTPCanaryAdmissionSnapshot returns the banks and the admission
// catalog under one read lock: the release publication swaps them under the
// same write lock, so no reader pairs a new bank with an old catalog.
func (s *Server) nativeMTPCanaryAdmissionSnapshot() (*nativeMTPCanaryBankSet, *autotune.Catalog, map[string]*autotune.Catalog) {
	s.autotuneCatalogMu.RLock()
	defer s.autotuneCatalogMu.RUnlock()
	return s.nativeMTPCanaryBanks.Load(), s.autotuneCatalog, s.autotuneCompatibleCatalogs
}

// nativeMTPCanaryBankFor returns the verified bank with exactly this digest and
// release, or nil. Either bank matches only while its release is admitted by
// the same snapshot: the live catalog release or a retained
// compatible-previous one. A provider admitted on the previous release holds
// that bank and cannot fetch another one without restarting onto the new
// release (SPEC-031-R033).
func (s *Server) nativeMTPCanaryBankFor(sha256Hex, releaseID string) *NativeMTPChallengeBank {
	set, current, compatible := s.nativeMTPCanaryAdmissionSnapshot()
	if set == nil || !nativeMTPCanaryReleaseAdmittedBy(current, compatible, releaseID) {
		return nil
	}
	for _, bank := range []*NativeMTPChallengeBank{set.current, set.previous} {
		if bank != nil && bank.RawSHA256 == sha256Hex && bank.ReleaseID == releaseID {
			return bank
		}
	}
	return nil
}

// nativeMTPCanaryReleaseAdmitted reports whether a provider session may still
// be admitted on releaseID: the live catalog release or a retained
// compatible-previous one.
func (s *Server) nativeMTPCanaryReleaseAdmitted(releaseID string) bool {
	current, compatible := s.autotuneCatalogSnapshot()
	return nativeMTPCanaryReleaseAdmittedBy(current, compatible, releaseID)
}

func nativeMTPCanaryReleaseAdmittedBy(current *autotune.Catalog, compatible map[string]*autotune.Catalog, releaseID string) bool {
	if releaseID == "" {
		return false
	}
	if current != nil && current.Version == releaseID {
		return true
	}
	previous, ok := compatible[releaseID]
	return ok && previous != nil && previous.Version == releaseID
}

// PrepareNativeMTPCanaryBankReload verifies, for the native-MTP canary, the
// exact self-test bank bytes a release reload is about to serve, so the canary
// bank and the served release move together (SPEC-031-R033). The returned
// stage function stages the bank transition into the release snapshot; the
// bank is installed by the same publication that installs the catalog and the
// served feed bytes, never ahead of them. A release that carries no native-MTP
// admission set stages a transition that retires the current bank. An error
// means the release must not go live. With the canary disabled, stage is a
// no-op.
func (s *Server) PrepareNativeMTPCanaryBankReload(releaseID string, bankJSON, bankSig []byte) (func(), error) {
	verified, err := verifyNativeMTPCanaryReleaseBank(s.cfg.Pool.NativeMTPCanary, releaseID, bankJSON, bankSig)
	if err != nil {
		return nil, err
	}
	if !s.cfg.Pool.NativeMTPCanary.Enabled {
		return func() {}, nil
	}
	transition := &nativeMTPCanaryBankTransition{bank: verified, releaseID: releaseID}
	return func() { s.artifactIdentitySets.stageCanaryBank(transition) }, nil
}

// applyNativeMTPCanaryBankTransitionLocked installs a staged bank transition
// against the catalog snapshot being published; the caller holds
// autotuneCatalogMu for writing and has already swapped the catalog. The new
// bank becomes current; the replaced current bank (or, failing that, the
// prior previous bank) stays as the one previous bank only while its release
// is admitted by the new snapshot, otherwise it is dropped.
func (s *Server) applyNativeMTPCanaryBankTransitionLocked(t *nativeMTPCanaryBankTransition) {
	if t == nil {
		return
	}
	prior := s.nativeMTPCanaryBanks.Load()
	next := &nativeMTPCanaryBankSet{current: t.bank}
	if prior != nil {
		if t.bank != nil && sameNativeMTPCanaryBank(prior.current, t.bank) {
			next.current = prior.current
		}
		for _, bank := range []*NativeMTPChallengeBank{prior.current, prior.previous} {
			if bank == nil || sameNativeMTPCanaryBank(bank, t.bank) {
				continue
			}
			if nativeMTPCanaryReleaseAdmittedBy(s.autotuneCatalog, s.autotuneCompatibleCatalogs, bank.ReleaseID) {
				next.previous = bank
				break
			}
		}
	}
	if prior != nil && prior.current == next.current && prior.previous == next.previous {
		return
	}
	if next.current == nil && next.previous == nil {
		s.nativeMTPCanaryBanks.Store(nil)
	} else {
		s.nativeMTPCanaryBanks.Store(next)
	}
	s.log.Info().
		Str("event", "native_mtp_canary_bank_reloaded").
		Str("release_id", t.releaseID).
		Str("challenge_bank_release_id", releaseIDOf(next.current)).
		Str("challenge_bank_sha256", sha256Of(next.current)).
		Str("previous_challenge_bank_release_id", releaseIDOf(next.previous)).
		Str("retired_challenge_bank_release_id", retiredNativeMTPCanaryBankRelease(prior, next)).
		Msg("native MTP canary challenge bank moved with the release")
}

func sameNativeMTPCanaryBank(a, b *NativeMTPChallengeBank) bool {
	return a != nil && b != nil && a.RawSHA256 == b.RawSHA256 && a.ReleaseID == b.ReleaseID
}

func retiredNativeMTPCanaryBankRelease(prior, next *nativeMTPCanaryBankSet) string {
	if prior == nil || prior.current == nil || prior.current == next.current || prior.current == next.previous {
		return ""
	}
	return prior.current.ReleaseID
}

// ValidateNativeMTPCanaryReleaseBank runs the reload's canary-bank check
// offline, so a release preflight refuses a release the reload would refuse.
func ValidateNativeMTPCanaryReleaseBank(cfg config.NativeMTPCanaryConfig, releaseID string, bankJSON, bankSig []byte) error {
	_, err := verifyNativeMTPCanaryReleaseBank(cfg, releaseID, bankJSON, bankSig)
	return err
}

// verifyNativeMTPCanaryReleaseBank returns nil, nil when the canary is disabled
// or the release carries no native-MTP admission set.
func verifyNativeMTPCanaryReleaseBank(cfg config.NativeMTPCanaryConfig, releaseID string, bankJSON, bankSig []byte) (*NativeMTPChallengeBank, error) {
	if !cfg.Enabled || (len(bankJSON) == 0 && len(bankSig) == 0) {
		return nil, nil
	}
	bank, err := verifyNativeMTPChallengeBank(cfg, bankJSON, bankSig)
	if err != nil {
		return nil, fmt.Errorf("native MTP canary challenge bank: %w", err)
	}
	if bank.ReleaseID != releaseID {
		return nil, fmt.Errorf("native MTP canary challenge bank release_id %q != reloaded release %q", bank.ReleaseID, releaseID)
	}
	return &bank, nil
}

func releaseIDOf(bank *NativeMTPChallengeBank) string {
	if bank == nil {
		return ""
	}
	return bank.ReleaseID
}

func sha256Of(bank *NativeMTPChallengeBank) string {
	if bank == nil {
		return ""
	}
	return bank.RawSHA256
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
	return verifyNativeMTPChallengeBank(cfg, raw, sigRaw)
}

func verifyNativeMTPChallengeBank(cfg config.NativeMTPCanaryConfig, raw, sigRaw []byte) (NativeMTPChallengeBank, error) {
	sig, err := parseNativeMTPCanaryDetachedSignature(sigRaw)
	if err != nil {
		return NativeMTPChallengeBank{}, fmt.Errorf("parse challenge bank signature: %w", err)
	}
	// The bank is a SPEC-023 static release feed: its detached signature is
	// the static-feed sidecar the release signer writes, `alg` "ed25519".
	if sig.Alg != "ed25519" || sig.KeyID == "" || sig.KeyID != cfg.SignerKeyID {
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
	if !s.nativeMTPCanaryHasBank() || !s.cfg.Pool.NativeMTPCanary.Enabled {
		s.log.Info().Str("provider_id", providerID).Msg("native MTP tuple offer ignored: canary disabled")
		return
	}
	current := s.currentNativeMTPCanaryBank()
	bank := s.nativeMTPCanaryBankFor(offer.ChallengeBankSHA256, offer.ChallengeBankReleaseID)
	if bank == nil {
		s.sendNativeMTPTupleDisableForOffer(offer, "bank_mismatch")
		s.log.Warn().
			Str("provider_id", providerID).
			Str("offered_challenge_bank_release_id", offer.ChallengeBankReleaseID).
			Str("canary_challenge_bank_release_id", releaseIDOf(current)).
			Msg("native MTP tuple offer rejected: challenge bank mismatch")
		return
	}
	if offer.SidecarDigest != offer.RuntimeTuple.SidecarDigest ||
		offer.NativeMTPRuntimeTupleSHA256 != nativeMTPRuntimeTupleIdentitySHA256(offer.ProviderID, offer.AssignedID, offer.TargetGeneration, offer.NativeMTPAdmissionTupleSHA256, offer.ServedSnapshotID) ||
		offer.TargetGeneration == 0 ||
		offer.SelftestProfile != "native_mtp_selftest_v1" {
		s.log.Warn().Str("provider_id", providerID).Msg("native MTP tuple offer rejected: tuple or selftest mismatch")
		return
	}
	// The tuple names the catalog key (the bank's model_id); the session
	// carries the served wire id (e.g. the MLX repo id). Routing treats the
	// two as one model through the same normalization (#900).
	if provider, ok := s.pool.Resolve(providerID, assignedID); !ok ||
		!billing.ModelsEquivalent(offer.RuntimeTuple.ModelID, provider.ModelID) ||
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
		return
	}
	s.log.Info().
		Str("provider_id", providerID).
		Str("assigned_id", assignedID).
		Uint64("target_generation", offer.TargetGeneration).
		Str("native_mtp_runtime_tuple_sha256", offer.NativeMTPRuntimeTupleSHA256).
		Str("challenge_bank_release_id", offer.ChallengeBankReleaseID).
		Bool("previous_release_bank", bank != current).
		Msg("native MTP tuple offer accepted")
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
	if !s.nativeMTPCanaryHasBank() || s.nativeMTPCanaryStore == nil {
		return
	}
	now := s.now()
	for _, provider := range s.pool.Snapshot() {
		s.maybeDispatchNativeMTPCanary(provider, now)
	}
}

func (s *Server) maybeDispatchNativeMTPCanary(provider pool.Provider, now time.Time) bool {
	diag := provider.NativeMTPCanary
	if diag == nil || !diag.Offered {
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
	s.log.Info().
		Str("provider_id", providerID).
		Str("assigned_id", assignedID).
		Str("outcome", string(eval.Outcome)).
		Str("reason", eval.Reason).
		Msg("native MTP canary result recorded")
	if state, ok := s.nativeMTPCanaryStore.NativeMTPCanaryState(key, s.now()); ok {
		if updated, ok := s.recordNativeMTPCanaryState(providerID, assignedID, key.RuntimeTupleSHA256, state); ok {
			if state.Status == NativeMTPCanaryTupleDisabled {
				s.sendNativeMTPTupleDisableOnce(updated, state.DisabledReason, state.DisabledAt)
			}
		}
	}
}

func (s *Server) nativeMTPChallengeForProvider(provider pool.Provider) (NativeMTPChallengeRecord, bool) {
	diag := provider.NativeMTPCanary
	if diag == nil {
		return NativeMTPChallengeRecord{}, false
	}
	bank := s.nativeMTPCanaryBankFor(diag.ChallengeBankSHA256, diag.ChallengeBankReleaseID)
	if bank == nil {
		return NativeMTPChallengeRecord{}, false
	}
	for _, record := range bank.Entries {
		if nativeMTPChallengeRecordMatchesTuple(record, diag) {
			return record, true
		}
	}
	return NativeMTPChallengeRecord{}, false
}

func nativeMTPChallengeRecordMatchesTuple(record NativeMTPChallengeRecord, diag *pool.NativeMTPCanaryDiagnostics) bool {
	return diag != nil &&
		record.ModelID == diag.ModelID &&
		strings.EqualFold(record.ModelHash, diag.ModelHash) &&
		record.TokenizerSHA256 == diag.TokenizerDigest &&
		record.ArtifactSHA256 == diag.ArtifactDigest &&
		record.MTPManifestSHA256 == diag.ManifestDigest &&
		int(record.FixedProposalDepth) == diag.ProposalDepth
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
		RuntimeTuple:        nativeMTPRuntimeTupleFromDiagnostics(diag),
		ChallengeBankSHA256: diag.ChallengeBankSHA256,
	}
}

func nativeMTPRuntimeTupleFromDiagnostics(diag *pool.NativeMTPCanaryDiagnostics) NativeMTPRuntimeTuple {
	if diag == nil {
		return NativeMTPRuntimeTuple{}
	}
	return NativeMTPRuntimeTuple{
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
	runtimeTuple := req.RuntimeTuple
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
	core := NativeMTPCanaryCoreResult{
		Profile:                    nativeMTPCanaryProfile,
		RequestID:                  result.RequestID,
		ProviderID:                 result.ProviderID,
		AssignedID:                 result.AssignedID,
		TargetGeneration:           result.TargetGeneration,
		ProviderRevision:           result.ProviderRevision,
		RuntimeRevision:            result.RuntimeRevision,
		RuntimeTupleSHA256:         result.NativeMTPRuntimeTupleSHA256,
		ChallengeBankSHA256:        result.ChallengeBankSHA256,
		ChallengeID:                result.ChallengeID,
		Nonce:                      result.Nonce,
		RequestDigestSHA256:        result.RequestDigest,
		ActualDecodePath:           result.ActualDecodePath,
		FallbackUsed:               result.FallbackUsed,
		CapacityUnavailable:        result.ActualDecodePath == "unavailable",
		ExpectedTokenIDSHA256:      result.ExpectedTokenIDSHA256,
		ActualTokenIDSHA256:        result.ActualTokenIDSHA256,
		ActualTerminalReason:       result.TerminalReason,
		ActualCounters:             nativeMTPCountersToCore(result.Counters),
		ActualCommittedStateSHA256: result.CommittedStateSHA256,
		RuntimeTuple:               result.RuntimeTuple,
		Diagnostic:                 result.Diagnostic,
		ResultDigestSHA256:         result.ResultDigest,
	}
	return core
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
	if !s.sendNativeMTPTupleDisable(nativeMTPTupleDisableFromDiagnostics(provider, nativeMTPTupleDisableReason(reason), issuedAt)) {
		return false
	}
	if !s.pool.MarkNativeMTPTupleDisableSent(provider.ProviderID, provider.AssignedID, diag.NativeMTPRuntimeTupleSHA256, issuedAt) {
		return false
	}
	return true
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
