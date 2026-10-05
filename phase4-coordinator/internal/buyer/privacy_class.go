package buyer

import (
	"bytes"
	"context"
	"encoding/json"
	"errors"
	"io"
	"net/http"
	"sort"
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
	if s == nil || s.privacyAuthority == nil || s.relayBlind == nil || !s.relayBlind.cfg.Enabled || s.relayBlind.store == nil {
		return true
	}
	disabled, err := s.relayBlind.store.PrivacyDisabled(ctx)
	return err != nil || disabled
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
// does not select a different provider.
func (s *Server) privacyGate(ctx context.Context, provider pool.Provider, keyDigest string) (time.Time, string) {
	if s.privacyDisabledNow(ctx) {
		return time.Time{}, privacyClassDisabled
	}
	if !s.relayBlindAvailable() {
		return time.Time{}, privacyClassUnavailable
	}
	current, live := s.pool.Resolve(provider.ProviderID, provider.AssignedID)
	if !live || current.ProviderID == "" || current.AssignedID == "" || !current.IsWSTunneled() || !relayBlindBindable(current) {
		return time.Time{}, privacyClassUnavailable
	}
	// SPEC-022 R-14.2 / SPEC-049-R021: under enforce the privacy class is a
	// relay-blind lane and needs the same settlement prerequisites.
	if s.relayBlindSettlementPrerequisite(current) != "" {
		return time.Time{}, privacyClassUnavailable
	}
	quarantined, err := s.relayBlind.store.IsQuarantined(ctx, current.ProviderID, s.now())
	if err != nil || quarantined {
		return time.Time{}, privacyClassUnavailable
	}
	verifiedAt, ok := s.privacyAuthority.Eligible(current.ProviderID, current.AssignedID, keyDigest, s.now())
	if !ok || verifiedAt.Unix() <= 0 {
		return time.Time{}, privacyClassUnavailable
	}
	return verifiedAt, ""
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
// relay-blind key.
func (s *Server) selectPrivacyProvider(ctx context.Context, model string, encryptedBytes int64) (privacySelection, string) {
	if s.privacyDisabledNow(ctx) {
		return privacySelection{}, privacyClassDisabled
	}
	if s.pool == nil || !s.relayBlindAvailable() {
		return privacySelection{}, privacyClassUnavailable
	}
	providers := s.pool.Snapshot()
	sort.Slice(providers, func(i, j int) bool { return providers[i].AssignedID < providers[j].AssignedID })
	for _, provider := range providers {
		if !relayBlindBindable(provider) || !provider.IsWSTunneled() || !modelIDEqual(provider.ModelID, model) {
			continue
		}
		records, err := s.relayBlind.store.FreshKeyRecords(ctx, provider.ProviderID, provider.AssignedID, model, encryptedBytes, s.now(), relayblind.KeyClassPrivacy)
		if err != nil || len(records) == 0 {
			continue
		}
		for _, record := range records {
			verifiedAt, code := s.privacyGate(ctx, provider, record.KeyRecordDigest)
			if code != "" {
				continue
			}
			attestation, signature, err := s.relayBlind.store.LookupPrivacyAttestation(ctx, provider.ProviderID, record.KID, record.KeyRecordDigest)
			if err != nil || attestation.KeyRecordDigest != record.KeyRecordDigest || attestation.NotBeforeUnix != record.NotBeforeUnix || attestation.ExpiresAtUnix != record.ExpiresAtUnix {
				continue
			}
			return privacySelection{provider: provider, key: record, attestation: attestation, signature: signature, verifiedAt: verifiedAt}, ""
		}
	}
	return privacySelection{}, privacyClassUnavailable
}

func (s *Server) handlePrivacyClassReservation(w http.ResponseWriter, r *http.Request, accountID, walletSession string) {
	if s.privacyDisabledNow(r.Context()) {
		writePrivacyClassError(w, privacyClassDisabled, "")
		return
	}
	if !s.relayBlindAvailable() {
		writePrivacyClassError(w, privacyClassUnavailable, "")
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
	selected, code := s.selectPrivacyProvider(r.Context(), request.Model, request.EncryptedRequestBytes)
	if code != "" {
		writePrivacyClassError(w, privacyObservedCode(code, true), "")
		return
	}
	// One more gate immediately before the row is written. A failure here
	// does not try another provider.
	verifiedAt, code := s.privacyGate(r.Context(), selected.provider, selected.key.KeyRecordDigest)
	if code != "" {
		writePrivacyClassError(w, privacyObservedCode(code, true), "")
		return
	}
	attestation, signature, err := s.relayBlind.store.LookupPrivacyAttestation(r.Context(), selected.provider.ProviderID, selected.key.KID, selected.key.KeyRecordDigest)
	if err != nil || attestation.KeyRecordDigest != selected.key.KeyRecordDigest || attestation.NotBeforeUnix != selected.key.NotBeforeUnix || attestation.ExpiresAtUnix != selected.key.ExpiresAtUnix || verifiedAt.Unix() <= 0 {
		writePrivacyClassError(w, privacyClassUnavailable, "")
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
		writePrivacyClassError(w, privacyClassUnavailable, "")
		return
	}
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
// privacy-key advertisement, or the kill switch) to its typed SPEC-049 code.
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
