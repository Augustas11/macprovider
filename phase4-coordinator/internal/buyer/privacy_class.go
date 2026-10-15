package buyer

import (
	"bytes"
	"context"
	"encoding/json"
	"errors"
	"io"
	"net/http"
	"strings"
	"time"

	"github.com/augstar/macprovider-coordinator/internal/pool"
	"github.com/augstar/macprovider-coordinator/internal/relayblind"
)

const (
	privacyClassHeader             = "X-MacProvider-Privacy-Class"
	privacyPostureVerifiedAtHeader = "X-MacProvider-Privacy-Posture-Verified-At"

	privacyClassDisabled    = "privacy_class_disabled"
	privacyClassUnavailable = "privacy_class_unavailable"
	privacyClassDowngrade   = "privacy_class_downgrade_rejected"
	privacyClassStale       = "privacy_class_posture_stale"
	// privacyClassUnconfirmed is emitted by the gateway when a privacy
	// response is missing the coordinator echo. The coordinator inventory
	// carries it so both sides share one fixture.
	privacyClassUnconfirmed = "privacy_class_unconfirmed"
)

// privacyRequested reports whether the buyer sent the privacy-class header
// and whether that single value is the SPEC-049 marker. A repeated header,
// a list value, or any other token is present and invalid.
func privacyRequested(r *http.Request) (present, valid bool) {
	if r == nil {
		return false, false
	}
	values := r.Header.Values(privacyClassHeader)
	if len(values) == 0 {
		return false, false
	}
	if len(values) != 1 {
		return true, false
	}
	value := strings.TrimSpace(values[0])
	if value == "" || strings.Contains(value, ",") {
		return true, false
	}
	return true, value == relayblind.PrivacyClassV1
}

func privacyErrorMessage(code string) string {
	switch code {
	case privacyClassDisabled:
		return "Privacy class is disabled"
	case privacyClassUnavailable:
		return "Privacy class is unavailable"
	case privacyClassDowngrade:
		return "Privacy class marker does not match the reservation"
	case privacyClassStale:
		return "Privacy class posture is stale"
	case privacyClassUnconfirmed:
		return "Privacy class completion was not confirmed"
	default:
		return "Privacy class is unavailable"
	}
}

func writePrivacyClassError(w http.ResponseWriter, code, message string) {
	if strings.TrimSpace(message) == "" {
		message = privacyErrorMessage(code)
	}
	writeRelayBlindError(w, code, message)
}

// privacyDisabledNow is true when the class is off, unwired, or the kill
// switch cannot be read. A store error fails closed.
func (s *Server) privacyDisabledNow(ctx context.Context) bool {
	return s.privacyDisabledReason(ctx) != ""
}

func (s *Server) privacyDisabledReason(ctx context.Context) string {
	if s == nil || s.privacyAuthority == nil || s.relayBlind == nil || !s.relayBlind.cfg.Enabled || s.relayBlind.store == nil {
		return relayblind.PrivacyRejectClassNotConfigured
	}
	disabled, err := s.relayBlind.store.PrivacyDisabled(ctx)
	if err != nil {
		return relayblind.PrivacyRejectStoreUnavailable
	}
	if disabled {
		return relayblind.PrivacyRejectKillSwitch
	}
	return ""
}

func (s *Server) logPrivacyGateRejection(reason string) {
	if s != nil {
		// Fixed categories only: never log plaintext, IDs, key digests,
		// ciphertext, reservation tokens, or raw store errors here.
		s.log.Info().Str("event", "privacy_gate_rejected").Str("reason", reason).Msg("privacy routing gate rejected")
	}
}

// handlePrivacyDirectory serves the SPEC-049-R028 signed identity
// directory. A build or signing failure fails closed; it is never partial.
func (s *Server) handlePrivacyDirectory(w http.ResponseWriter, r *http.Request) {
	directory := s.privacyAuthority.IdentityDirectory()
	if directory == nil || s.privacyDisabledNow(r.Context()) {
		writePrivacyClassError(w, privacyClassDisabled, "")
		return
	}
	raw, err := directory.Envelope(r.Context(), s.now())
	if err != nil {
		s.log.Warn().Err(err).Msg("privacy identity directory unavailable")
		writePrivacyClassError(w, privacyClassUnavailable, "")
		return
	}
	setRelayBlindNoStore(w)
	w.Header().Set("Content-Type", "application/json")
	w.WriteHeader(http.StatusOK)
	_, _ = w.Write(raw)
}

// privacyObservedCode keeps disabled stable. Every other gate failure is
// unavailable before consume and posture-stale after it.
func privacyObservedCode(code string, beforeConsume bool) string {
	if code == "" || code == privacyClassDisabled {
		return code
	}
	if beforeConsume {
		return privacyClassUnavailable
	}
	return privacyClassStale
}

// privacyGate re-checks the SPEC-049 conditions for one live session. It
// does not select a different provider. It returns the verification time, the
// §4.9 code, and the SPEC-049-R030 reason of a failure.
func (s *Server) privacyGate(ctx context.Context, provider pool.Provider, keyDigest string) (time.Time, string, string) {
	return s.privacyGateExplain(ctx, provider, keyDigest, true)
}

// privacyGateExplain is privacyGate; explain false skips the store lookup
// that splits an unverified posture into not enrolled, for per-candidate
// selection, which explains once after it fails.
func (s *Server) privacyGateExplain(ctx context.Context, provider pool.Provider, keyDigest string, explain bool) (time.Time, string, string) {
	reject := func(reason, code string) (time.Time, string, string) {
		s.logPrivacyGateRejection(reason)
		return time.Time{}, code, reason
	}
	if reason := s.privacyDisabledReason(ctx); reason != "" {
		return reject(reason, privacyClassDisabled)
	}
	if !s.relayBlindAvailable() {
		return reject(relayblind.PrivacyRejectRelayBlindUnavailable, privacyClassUnavailable)
	}
	current, live := s.pool.Resolve(provider.ProviderID, provider.AssignedID)
	if !live || current.ProviderID == "" || current.AssignedID == "" || !current.IsWSTunneled() || !relayBlindSessionUsable(current) {
		return reject(relayblind.PrivacyRejectLiveSessionUnavailable, privacyClassUnavailable)
	}
	// SPEC-022 R-14.2 / SPEC-049-R021: under enforce the privacy class is a
	// relay-blind lane and needs the same settlement prerequisites.
	if s.relayBlindSettlementPrerequisite(current) != "" {
		return reject(relayblind.PrivacyRejectSettlementPrerequisite, privacyClassUnavailable)
	}
	quarantined, err := s.relayBlind.store.IsQuarantined(ctx, current.ProviderID, s.now())
	if err != nil {
		return reject(relayblind.PrivacyRejectStoreUnavailable, privacyClassUnavailable)
	}
	if quarantined {
		return reject(relayblind.PrivacyRejectProviderQuarantined, privacyClassUnavailable)
	}
	eligibility := s.privacyAuthority.QuickEligibilityReason
	if explain {
		eligibility = s.privacyAuthority.EligibilityReason
	}
	verifiedAt, reason := eligibility(current.ProviderID, current.AssignedID, keyDigest, s.now())
	if reason != "" {
		return reject(reason, privacyClassUnavailable)
	}
	if verifiedAt.Unix() <= 0 {
		return reject(relayblind.PrivacyRejectPostureUnverified, privacyClassUnavailable)
	}
	return verifiedAt, "", ""
}

type privacySelection struct {
	provider    pool.Provider
	key         relayblind.KeyRecord
	attestation relayblind.PrivacyKeyAttestation
	signature   string
	verifiedAt  time.Time
}

// selectPrivacyProvider walks serving sessions and keeps only a fresh privacy
// key whose posture gate and stored attestation both pass. It never returns a
// relay-blind key. On failure it returns the §4.9 code and the SPEC-049-R030
// reason of the candidate that came closest to serving the request.
func (s *Server) selectPrivacyProvider(ctx context.Context, accountID, model string, encryptedBytes int64, requires []string) (privacySelection, string, string) {
	if reason := s.privacyDisabledReason(ctx); reason != "" {
		s.logPrivacyGateRejection(reason)
		return privacySelection{}, privacyClassDisabled, reason
	}
	if s.pool == nil || !s.relayBlindAvailable() {
		return privacySelection{}, privacyClassUnavailable, relayblind.PrivacyRejectRelayBlindUnavailable
	}
	var providers []pool.Provider
	var selections []privacySelection
	var keyless []pool.Provider
	var unverified []string
	unverifiedSeen := make(map[string]bool)
	closest := relayblind.PrivacyRejectModelNotServed
	incapable := false
	for _, provider := range s.pool.Snapshot() {
		if !relayBlindBindable(provider) || !provider.IsWSTunneled() || !modelIDEqual(provider.ModelID, model) {
			continue
		}
		records, err := s.relayBlind.store.FreshKeyRecords(ctx, provider.ProviderID, provider.AssignedID, model, encryptedBytes, s.now(), relayblind.KeyClassPrivacy)
		if err != nil {
			s.logPrivacyGateRejection(relayblind.PrivacyRejectStoreUnavailable)
			closest = closerPrivacyReject(closest, relayblind.PrivacyRejectStoreUnavailable)
			continue
		}
		if len(records) == 0 {
			s.logPrivacyGateRejection(relayblind.PrivacyRejectModelNotPrivateCapable)
			closest = closerPrivacyReject(closest, relayblind.PrivacyRejectModelNotPrivateCapable)
			keyless = append(keyless, provider)
			continue
		}
		for _, record := range records {
			verifiedAt, code, reason := s.privacyGateExplain(ctx, provider, record.KeyRecordDigest, false)
			if code != "" {
				if reason == relayblind.PrivacyRejectPostureUnverified && !unverifiedSeen[provider.ProviderID] {
					unverifiedSeen[provider.ProviderID] = true
					unverified = append(unverified, provider.ProviderID)
				}
				closest = closerPrivacyReject(closest, reason)
				continue
			}
			attestation, signature, err := s.relayBlind.store.LookupPrivacyAttestation(ctx, provider.ProviderID, record.KID, record.KeyRecordDigest)
			if err != nil || attestation.KeyRecordDigest != record.KeyRecordDigest || attestation.NotBeforeUnix != record.NotBeforeUnix || attestation.ExpiresAtUnix != record.ExpiresAtUnix {
				s.logPrivacyGateRejection(relayblind.PrivacyRejectKeyAttestationMismatch)
				closest = closerPrivacyReject(closest, relayblind.PrivacyRejectKeyAttestationMismatch)
				continue
			}
			// SPEC-041-R004 capability gate, applied to a fully eligible
			// candidate: it came closest to serving the request.
			if !relayBlindProviderMeetsRequires(provider, requires) {
				incapable = true
				break
			}
			providers = append(providers, provider)
			selections = append(selections, privacySelection{provider: provider, key: record, attestation: attestation, signature: signature, verifiedAt: verifiedAt})
			break
		}
	}
	if order := s.orderRelayBlindCandidates(accountID, providers); len(order) > 0 {
		return selections[order[0]], "", ""
	}
	if incapable {
		return privacySelection{}, relayBlindCapabilityRefusalCode, relayblind.PrivacyRejectCapabilityUnsupported
	}
	switch closest {
	case relayblind.PrivacyRejectModelNotPrivateCapable:
		closest = s.keylessPrivacyReason(ctx, keyless)
	case relayblind.PrivacyRejectPostureUnverified:
		// Explained once, after selection failed: posture_unverified when
		// any such candidate is enrolled, else provider_not_enrolled.
		closest = relayblind.PrivacyRejectProviderNotEnrolled
		for _, providerID := range unverified {
			closest = closerPrivacyReject(closest, s.privacyAuthority.UnverifiedReason(providerID))
		}
	}
	return privacySelection{}, privacyClassUnavailable, closest
}

// keylessPrivacyReason refines "no fresh privacy key" for sessions that serve
// the model: a refused advertisement or a quarantine names the real cause.
// It runs only after selection found no eligible provider.
func (s *Server) keylessPrivacyReason(ctx context.Context, keyless []pool.Provider) string {
	closest := relayblind.PrivacyRejectModelNotPrivateCapable
	for _, provider := range keyless {
		reason := s.privacyAuthority.AdvertisementRejection(provider.ProviderID, provider.AssignedID)
		switch reason {
		case relayblind.PrivacyRejectCodeIdentityUnapproved, relayblind.PrivacyRejectProviderNotEnrolled, relayblind.PrivacyRejectProviderQuarantined:
		default:
			// Only the three SPEC-049-R030 item 1 refinements name a cause.
			reason = ""
		}
		if reason == "" {
			quarantined, err := s.relayBlind.store.IsQuarantined(ctx, provider.ProviderID, s.now())
			switch {
			case err != nil:
				reason = relayblind.PrivacyRejectStoreUnavailable
			case quarantined:
				reason = relayblind.PrivacyRejectProviderQuarantined
			default:
				continue
			}
		}
		closest = closerPrivacyReject(closest, reason)
	}
	return closest
}

func (s *Server) handlePrivacyClassReservation(w http.ResponseWriter, r *http.Request, accountID, walletSession string) {
	const phase = relayblind.PrivacyRejectPhaseReservation
	if reason := s.privacyDisabledReason(r.Context()); reason != "" {
		s.writePrivacyRouteError(w, r, phase, privacyClassDisabled, reason)
		return
	}
	if !s.relayBlindAvailable() {
		s.writePrivacyRouteError(w, r, phase, privacyClassUnavailable, relayblind.PrivacyRejectRelayBlindUnavailable)
		return
	}
	if !s.relayBlindMetadataAllowed(accountID + "\x00" + walletSession) {
		writeRelayBlindError(w, "relay_blind_metadata_rate_limited", "Relay-blind metadata rate limit exceeded")
		return
	}
	body, err := io.ReadAll(io.LimitReader(r.Body, (16<<10)+1))
	if err != nil || len(body) > 16<<10 {
		writeRelayBlindError(w, "relay_blind_route_reservation_invalid", "Invalid route reservation")
		return
	}
	request, err := relayblind.ParseReservationRequest(body)
	if err != nil {
		writeRelayBlindError(w, "relay_blind_route_reservation_invalid", "Invalid route reservation")
		return
	}
	unlockSelection := s.relayBlind.lockAccountSelection(accountID)
	defer func() { unlockSelection() }()
	selected, code, reason := s.selectPrivacyProvider(r.Context(), accountID, request.Model, request.EncryptedRequestBytes, request.Requires)
	if code == relayBlindCapabilityRefusalCode {
		s.writeRelayBlindCapabilityRefusal(w, r, phase, true)
		return
	}
	if code != "" {
		s.writePrivacyRouteError(w, r, phase, privacyObservedCode(code, true), reason)
		return
	}
	// One more gate immediately before the row is written. A failure here
	// does not try another provider.
	verifiedAt, code, reason := s.privacyGate(r.Context(), selected.provider, selected.key.KeyRecordDigest)
	if code != "" {
		s.writePrivacyRouteError(w, r, phase, privacyObservedCode(code, true), reason)
		return
	}
	attestation, signature, err := s.relayBlind.store.LookupPrivacyAttestation(r.Context(), selected.provider.ProviderID, selected.key.KID, selected.key.KeyRecordDigest)
	if err != nil || attestation.KeyRecordDigest != selected.key.KeyRecordDigest || attestation.NotBeforeUnix != selected.key.NotBeforeUnix || attestation.ExpiresAtUnix != selected.key.ExpiresAtUnix || verifiedAt.Unix() <= 0 {
		reason := relayblind.PrivacyRejectKeyAttestationMismatch
		if err != nil {
			reason = relayblind.PrivacyRejectStoreUnavailable
		}
		s.writePrivacyRouteError(w, r, phase, privacyClassUnavailable, reason)
		return
	}
	expires := s.now().Add(time.Duration(s.relayBlind.cfg.ReservationTTLSeconds) * time.Second).Unix()
	if selected.key.ExpiresAtUnix < expires {
		expires = selected.key.ExpiresAtUnix
	}
	reservation, err := s.relayBlind.store.CreateReservation(r.Context(), relayblind.ReservationCreate{
		AccountID: accountID, WalletSession: walletSession, ProviderID: selected.provider.ProviderID, AssignedSession: selected.provider.AssignedID,
		KeyRecord: selected.key, Model: request.Model, ProviderModel: selected.provider.ModelID, Stream: request.Stream,
		MaxEncryptedRequestBytes: request.EncryptedRequestBytes, MaxOutputTokens: request.MaxOutputTokens,
		InputTokenUpperBound: request.InputTokenUpperBound, ExpiresAtUnix: expires, MaxActive: s.relayBlind.cfg.MaxActiveReservations,
		ReplayRetention: time.Duration(s.relayBlind.cfg.ReplayRetentionSeconds) * time.Second, PrivacyClass: true,
	}, s.now())
	if err != nil {
		if errors.Is(err, relayblind.ErrCapacity) {
			writeRelayBlindError(w, "relay_blind_metadata_rate_limited", "Could not create relay-blind reservation")
			return
		}
		s.writePrivacyRouteError(w, r, phase, privacyClassUnavailable, relayblind.PrivacyRejectStoreUnavailable)
		return
	}
	s.relayBlind.notePending(accountID, selected.provider.ProviderID, reservation.ProviderBinding, expires, s.now())
	unlockSelection()
	unlockSelection = func() {}
	response := relayblind.ReservationResponse{
		Version: relayblind.PrivacyReservationVersion, ProviderBinding: reservation.ProviderBinding, BuyerBinding: reservation.BuyerBinding,
		KeyRecordDigest: selected.key.KeyRecordDigest, KeyRecord: selected.key, KID: selected.key.KID, EndpointFamily: relayblind.EndpointChatCompletions,
		Model: request.Model, ProviderModel: selected.provider.ModelID, Stream: request.Stream, MaxEncryptedRequestBytes: uint64(request.EncryptedRequestBytes),
		MaxOutputTokens: request.MaxOutputTokens, InputTokenUpperBound: request.InputTokenUpperBound,
		ReservationTokenCap: request.InputTokenUpperBound + request.MaxOutputTokens, ExpiresAtUnix: expires,
		CachePolicy: relayblind.CachePolicyNoStore, FailoverPolicy: relayblind.FailoverPolicyDisabled,
		PrivacyClass: relayblind.PrivacyClassV1, PrivacyAssurance: relayblind.PrivacyAssurance,
		PrivacyKeyAttestation: &attestation, PrivacyKeyAttestationSignature: signature, PrivacyPostureVerifiedAtUnix: verifiedAt.Unix(),
	}
	w.Header().Set("Content-Type", "application/json")
	_ = json.NewEncoder(w).Encode(response)
}

// privacyClassConflict reports a downgrade or disabled decision for a parsed
// envelope. reject is true when a held row must be burned.
func (s *Server) privacyClassConflict(ctx context.Context, held relayblind.Reservation, heldOK, present, valid bool) (code string, reject bool) {
	if present && !valid {
		return privacyClassDowngrade, heldOK
	}
	if heldOK && present != held.PrivacyClass {
		return privacyClassDowngrade, true
	}
	privacyRow := heldOK && held.PrivacyClass
	if present && valid && s.privacyDisabledNow(ctx) && (!heldOK || privacyRow) {
		return privacyClassDisabled, privacyRow
	}
	return "", false
}

type privacyCapabilityCounts struct {
	CapableProviderCount   int `json:"capable_provider_count"`
	IncapableProviderCount int `json:"incapable_provider_count"`
}

func (s *Server) privacyCapabilityModels(ctx context.Context) (bool, map[string]privacyCapabilityCounts) {
	enabled := !s.privacyDisabledNow(ctx)
	models := make(map[string]privacyCapabilityCounts)
	if s.pool == nil {
		return enabled, models
	}
	for _, provider := range s.pool.Snapshot() {
		if !provider.ServingCapable() || !provider.IsWSTunneled() {
			continue
		}
		value := models[provider.ModelID]
		capable := false
		if enabled && s.relayBlind != nil && s.relayBlind.store != nil && s.privacyAuthority != nil {
			records, err := s.relayBlind.store.FreshKeyRecords(ctx, provider.ProviderID, provider.AssignedID, provider.ModelID, 1, s.now(), relayblind.KeyClassPrivacy)
			if err == nil {
				for _, record := range records {
					if _, ok := s.privacyAuthority.Eligible(provider.ProviderID, provider.AssignedID, record.KeyRecordDigest, s.now()); ok {
						capable = true
						break
					}
				}
			}
		}
		if capable {
			value.CapableProviderCount++
		} else {
			value.IncapableProviderCount++
		}
		models[provider.ModelID] = value
	}
	return enabled, models
}

// privacyStreamRelay reassembles provider chunks into whole SSE events and
// releases only the events the SPEC-049 §4.8 stream gate accepts. Ciphertext
// is not decrypted, logged, or rewritten.
type privacyStreamRelay struct {
	gate    relayblind.PrivacyStreamGate
	pending []byte
}

var errPrivacyStreamShape = errors.New("privacy stream event is not one data line")

// accept returns the complete accepted events in data. Any event outside the
// closed privacy stream shape fails the whole stream.
func (p *privacyStreamRelay) accept(data string) (string, error) {
	p.pending = append(p.pending, data...)
	var out strings.Builder
	for {
		idx := bytes.Index(p.pending, []byte("\n\n"))
		if idx < 0 {
			return out.String(), nil
		}
		event := string(p.pending[:idx])
		p.pending = p.pending[idx+2:]
		value, ok := strings.CutPrefix(event, "data: ")
		if !ok || strings.ContainsAny(value, "\r\n") {
			return "", errPrivacyStreamShape
		}
		if _, err := p.gate.Observe(value); err != nil {
			return "", err
		}
		out.WriteString(event)
		out.WriteString("\n\n")
	}
}

// complete requires no partial event and a finished privacy stream.
func (p *privacyStreamRelay) complete() error {
	if len(p.pending) != 0 {
		return errPrivacyStreamShape
	}
	return p.gate.Complete()
}

// privacyInvalidatedCode maps a privacy reservation that the control plane
// rejected before dispatch (quarantine, privacy-key revocation or an empty
// privacy-key advertisement, an identity key rotation, or the kill switch)
// to its typed SPEC-049 code.
// Expired, consumed, dispatched, and terminal reservations stay replays.
func privacyInvalidatedCode(r relayblind.Reservation, now time.Time) string {
	if !r.PrivacyClass || r.State != relayblind.ReservationStateRejected || r.ExpiresAtUnix <= now.Unix() {
		return ""
	}
	switch r.TerminalCode {
	case "relay_blind_key_expired":
		return privacyClassUnavailable
	case privacyClassDisabled:
		return privacyClassDisabled
	case relayblind.PrivacyKeyRotatedTerminalCode:
		// SPEC-049-R031 item 9: retryable with a new reservation.
		return privacyClassStale
	}
	return ""
}

// privacyInvalidatedAuthorization is privacyInvalidatedCode for the
// reservation behind an execution authorization.
func (s *Server) privacyInvalidatedAuthorization(ctx context.Context, accountID, walletSession, authorization string) string {
	peeked, err := s.relayBlind.store.PeekAuthorization(ctx, accountID, walletSession, authorization)
	if err != nil {
		return ""
	}
	return privacyInvalidatedCode(peeked, s.now())
}
