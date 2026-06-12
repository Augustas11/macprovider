package router

import (
	"context"
	"encoding/json"
	"log/slog"
	"net/http"
	"strings"
	"sync"
	"time"
)

type tier1Disclosure struct {
	Version                 string                    `json:"version"`
	PlaintextToProvider     bool                      `json:"plaintext_to_provider"`
	ModelIdentity           string                    `json:"model_identity"`
	HardwareAttestation     string                    `json:"hardware_attestation"`
	Tier2Milestone          string                    `json:"tier2_milestone"`
	StickyAffinity          *stickyAffinityDisclosure `json:"sticky_affinity"`
	ModelHashVerified       string                    `json:"model_hash_verified,omitempty"`
	ProviderLegEncryption   string                    `json:"provider_leg_encryption,omitempty"`
	UntrustedProviderSafety string                    `json:"untrusted_provider_safety,omitempty"`
	Tier2                   *tier2Disclosure          `json:"tier2,omitempty"`
}

type stickyAffinityDisclosure struct {
	Enabled     bool   `json:"enabled"`
	TTLSeconds  int    `json:"ttl_seconds"`
	Description string `json:"description"`
}

type tier2Disclosure struct {
	Phase            any                        `json:"phase"`
	ModelHash        modelHashDisclosure        `json:"model_hash"`
	EncryptedLeg     encryptedLegDisclosure     `json:"encrypted_leg"`
	Attestation      attestationDisclosure      `json:"attestation"`
	BehavioralSafety behavioralSafetyDisclosure `json:"behavioral_safety"`
}

type modelHashDisclosure struct {
	State                     string `json:"state"`
	VerifiedProviderCount     int    `json:"verified_provider_count"`
	UncataloguedProviderCount int    `json:"uncatalogued_provider_count"`
	Mixed                     bool   `json:"mixed"`
}

type encryptedLegDisclosure struct {
	State                    string `json:"state"`
	EncryptedProviderCount   int    `json:"encrypted_provider_count"`
	UnencryptedProviderCount int    `json:"unencrypted_provider_count"`
	Mixed                    bool   `json:"mixed"`
	Scope                    string `json:"scope"`
}

type attestationDisclosure struct {
	State                    string `json:"state"`
	AttestedProviderCount    int    `json:"attested_provider_count"`
	UnsupportedProviderCount int    `json:"unsupported_provider_count"`
	Mixed                    bool   `json:"mixed"`
}

type behavioralSafetyDisclosure struct {
	State              string `json:"state"`
	SizeCap            bool   `json:"size_cap"`
	EncodingValidation bool   `json:"encoding_validation"`
	TTFTAnomalyLogging bool   `json:"ttft_anomaly_logging"`
}

type coordinatorRoutingMetadata struct {
	Sticky struct {
		Enabled    bool `json:"enabled"`
		TTLSeconds int  `json:"ttl_seconds"`
	} `json:"sticky"`
	Tier2 struct {
		Phase     any `json:"phase"`
		ModelHash struct {
			Active bool   `json:"active"`
			State  string `json:"state"`
		} `json:"model_hash"`
		EncryptedLeg     coordinatorEncryptedLegMetadata     `json:"encrypted_leg"`
		Attestation      coordinatorAttestationMetadata      `json:"attestation"`
		BehavioralSafety coordinatorBehavioralSafetyMetadata `json:"behavioral_safety"`
	} `json:"tier2"`
}

type coordinatorEncryptedLegMetadata struct {
	State                    string `json:"state"`
	EncryptedProviderCount   int    `json:"encrypted_provider_count"`
	UnencryptedProviderCount int    `json:"unencrypted_provider_count"`
	Mixed                    bool   `json:"mixed"`
	Scope                    string `json:"scope"`
}

func (m coordinatorEncryptedLegMetadata) active() bool {
	return m.State != "" && m.State != "none"
}

func (m coordinatorEncryptedLegMetadata) disclosureState() string {
	if !m.active() {
		return "none"
	}
	if m.State == "all" {
		return "all"
	}
	return "partial"
}

func (m coordinatorEncryptedLegMetadata) toDisclosure() encryptedLegDisclosure {
	if !m.active() {
		return encryptedLegDisclosure{State: "none", Scope: "coordinator_to_provider_only"}
	}
	scope := m.Scope
	if scope == "" {
		scope = "coordinator_to_provider_only"
	}
	return encryptedLegDisclosure{
		State:                    m.State,
		EncryptedProviderCount:   m.EncryptedProviderCount,
		UnencryptedProviderCount: m.UnencryptedProviderCount,
		Mixed:                    m.Mixed || m.State == "partial",
		Scope:                    scope,
	}
}

type coordinatorAttestationMetadata struct {
	State                    string `json:"state"`
	AttestedProviderCount    int    `json:"attested_provider_count"`
	UnsupportedProviderCount int    `json:"unsupported_provider_count"`
	Mixed                    bool   `json:"mixed"`
}

func (m coordinatorAttestationMetadata) active() bool {
	return m.State != "" && m.State != "none"
}

func (m coordinatorAttestationMetadata) disclosureState() string {
	switch m.State {
	case "all", "partial", "unsupported":
		return m.State
	default:
		return "none"
	}
}

func (m coordinatorAttestationMetadata) toDisclosure() attestationDisclosure {
	if !m.active() {
		return attestationDisclosure{State: "none"}
	}
	return attestationDisclosure{
		State:                    m.State,
		AttestedProviderCount:    m.AttestedProviderCount,
		UnsupportedProviderCount: m.UnsupportedProviderCount,
		Mixed:                    m.Mixed || m.State == "partial",
	}
}

type coordinatorBehavioralSafetyMetadata struct {
	State              string `json:"state"`
	SizeCap            bool   `json:"size_cap"`
	EncodingValidation bool   `json:"encoding_validation"`
	TTFTAnomalyLogging bool   `json:"ttft_anomaly_logging"`
}

func (m coordinatorBehavioralSafetyMetadata) active() bool {
	return m.State != "" && m.State != "none"
}

func (m coordinatorBehavioralSafetyMetadata) disclosureState() string {
	if !m.active() {
		return "none"
	}
	if m.State == "enforced" {
		return "enforced"
	}
	return "partial"
}

func (m coordinatorBehavioralSafetyMetadata) toDisclosure() behavioralSafetyDisclosure {
	if !m.active() {
		return behavioralSafetyDisclosure{State: "none"}
	}
	return behavioralSafetyDisclosure{
		State:              m.State,
		SizeCap:            m.SizeCap,
		EncodingValidation: m.EncodingValidation,
		TTFTAnomalyLogging: m.TTFTAnomalyLogging,
	}
}

const routingMetaTTL = 5 * time.Second

func (s *Server) coordinatorRoutingMetadata(ctx context.Context) (coordinatorRoutingMetadata, bool) {
	// Per-request roundtrip cost is bad at scale (audit HIGH). 5s TTL is
	// safe for sticky-affinity hints because staleness only affects whether
	// sticky headers are attempted on the next request. Buyer-visible trust
	// disclosure uses coordinatorRoutingMetadataFresh instead.
	s.routingMeta.mu.Lock()
	if s.routingMeta.ok && s.now().Sub(s.routingMeta.fetchedAt) < routingMetaTTL {
		v, ok := s.routingMeta.value, s.routingMeta.ok
		s.routingMeta.mu.Unlock()
		return v, ok
	}
	s.routingMeta.mu.Unlock()

	return s.coordinatorRoutingMetadataFresh(ctx)
}

func (s *Server) coordinatorRoutingMetadataFresh(ctx context.Context) (coordinatorRoutingMetadata, bool) {
	var metadata coordinatorRoutingMetadata
	reqCtx, cancel := context.WithTimeout(ctx, 2*time.Second)
	defer cancel()
	req, err := http.NewRequestWithContext(reqCtx, http.MethodGet, strings.TrimRight(s.cfg.Coordinator.OperatorURL, "/")+"/internal/routing", nil)
	if err != nil {
		return metadata, false
	}
	// M3-2 / SECU-4: prefer ServiceToken when set; falls back to
	// OperatorKey so a not-yet-upgraded coordinator keeps accepting us.
	req.Header.Set("Authorization", "Bearer "+s.cfg.Coordinator.UpstreamCoordinatorBearer())
	resp, err := s.client.Do(req)
	if err != nil {
		return metadata, false
	}
	defer resp.Body.Close()
	if resp.StatusCode < 200 || resp.StatusCode > 299 {
		return metadata, false
	}
	if err := json.NewDecoder(resp.Body).Decode(&metadata); err != nil {
		slog.Warn("coordinator routing metadata decode failed", "error", err.Error())
		return metadata, false
	}

	s.routingMeta.mu.Lock()
	s.routingMeta.value = metadata
	s.routingMeta.ok = true
	s.routingMeta.fetchedAt = s.now()
	s.routingMeta.mu.Unlock()
	return metadata, true
}

func (s *Server) makeTier1Disclosure(ctxs ...context.Context) tier1Disclosure {
	disclosure := tier1Disclosure{
		Version:             "v0.8",
		PlaintextToProvider: true,
		ModelIdentity:       "provider_reported",
		HardwareAttestation: "none",
		Tier2Milestone:      "future",
		StickyAffinity: &stickyAffinityDisclosure{
			Enabled: false, TTLSeconds: 0,
			Description: "Sticky affinity is disabled; related requests are not preferentially routed to the same provider.",
		},
	}
	if s.cfg.Routing.StickyEnabled {
		ctx := context.Background()
		if len(ctxs) > 0 && ctxs[0] != nil {
			ctx = ctxs[0]
		}
		metadata, ok := s.coordinatorRoutingMetadata(ctx)
		if !ok || !metadata.Sticky.Enabled || metadata.Sticky.TTLSeconds != s.cfg.Routing.StickyTTLS {
			return disclosure
		}
		disclosure.StickyAffinity = &stickyAffinityDisclosure{
			Enabled: true, TTLSeconds: metadata.Sticky.TTLSeconds,
			Description: "Related requests with the same conversation tag are preferentially routed to one provider for up to this many seconds, so that provider can observe and correlate more of your traffic than under default routing.",
		}
	}
	return disclosure
}

func (s *Server) makeTier1DisclosureForModels(body map[string]any, ctxs ...context.Context) tier1Disclosure {
	disclosure, _ := s.tier1DisclosureForModels(body, ctxs...)
	return disclosure
}

func (s *Server) tier1DisclosureForModels(body map[string]any, ctxs ...context.Context) (tier1Disclosure, bool) {
	disclosure := s.makeTier1Disclosure(ctxs...)
	bodyActive, state, verified, uncatalogued := tier2ModelHashState(body)
	bodyMetadataActive := tier2BodyMetadataActive(body)
	phase := any(1)
	ctx := context.Background()
	if len(ctxs) > 0 && ctxs[0] != nil {
		ctx = ctxs[0]
	}
	metadata, ok := s.coordinatorRoutingMetadataFresh(ctx)
	if !ok {
		if bodyActive {
			phase = 1
		} else {
			return disclosure, !bodyMetadataActive
		}
	} else if !metadata.Tier2.ModelHash.Active && !metadata.Tier2.EncryptedLeg.active() && !metadata.Tier2.Attestation.active() && !metadata.Tier2.BehavioralSafety.active() {
		return disclosure, !(bodyActive || bodyMetadataActive)
	} else {
		phase = tier2PhaseFromMetadata(metadata.Tier2.Phase)
		if !bodyActive {
			state = disclosureStateFromMetadata(metadata.Tier2.ModelHash.State)
		}
	}
	disclosure.Version = "v0.8+tier2-v0.2"
	disclosure.ModelHashVerified = state
	disclosure.ProviderLegEncryption = metadata.Tier2.EncryptedLeg.disclosureState()
	disclosure.HardwareAttestation = metadata.Tier2.Attestation.disclosureState()
	disclosure.UntrustedProviderSafety = metadata.Tier2.BehavioralSafety.disclosureState()
	disclosure.Tier2 = &tier2Disclosure{
		Phase: phase,
		ModelHash: modelHashDisclosure{
			State:                     state,
			VerifiedProviderCount:     verified,
			UncataloguedProviderCount: uncatalogued,
			Mixed:                     state == "partial",
		},
		EncryptedLeg:     metadata.Tier2.EncryptedLeg.toDisclosure(),
		Attestation:      metadata.Tier2.Attestation.toDisclosure(),
		BehavioralSafety: metadata.Tier2.BehavioralSafety.toDisclosure(),
	}
	return disclosure, true
}

func tier2BodyMetadataActive(body map[string]any) bool {
	tier2Raw, _ := body["tier2"].(map[string]any)
	if tier2Raw == nil {
		return false
	}
	modelHash, _ := tier2Raw["model_hash"].(map[string]any)
	active, _ := modelHash["active"].(bool)
	if active {
		return true
	}
	encryptedLeg, _ := tier2Raw["encrypted_leg"].(map[string]any)
	state, _ := encryptedLeg["state"].(string)
	if state != "" && state != "none" {
		return true
	}
	attestation, _ := tier2Raw["attestation"].(map[string]any)
	state, _ = attestation["state"].(string)
	if state != "" && state != "none" {
		return true
	}
	behavioralSafety, _ := tier2Raw["behavioral_safety"].(map[string]any)
	state, _ = behavioralSafety["state"].(string)
	return state != "" && state != "none"
}

func disclosureStateFromMetadata(state string) string {
	switch state {
	case "all", "partial", "none":
		return state
	case "required":
		return "none"
	default:
		return "none"
	}
}

func tier2PhaseFromMetadata(phase any) any {
	switch v := phase.(type) {
	case string:
		if v == "mixed" {
			return v
		}
	case float64:
		if v == 0 || v == 1 || v == 2 || v == 3 {
			return int(v)
		}
	case json.Number:
		i, err := v.Int64()
		if err == nil && i >= 0 && i <= 3 {
			return int(i)
		}
	}
	return 0
}

func tier2ModelHashState(body map[string]any) (active bool, state string, verified int, uncatalogued int) {
	state = "none"
	data, _ := body["data"].([]any)
	nonVerified := 0
	for _, item := range data {
		entry, _ := item.(map[string]any)
		if entry == nil {
			continue
		}
		hvRaw, hashFieldPresent := entry["hash_verified"]
		hv, ok := entry["hash_verification"].(map[string]any)
		if !ok {
			if hashFieldPresent {
				active = true
				if b, ok := hvRaw.(bool); ok && b {
					verified++
				} else {
					nonVerified++
				}
			}
			continue
		}
		active = true
		v := intFromModelField(hv["verified_provider_count"])
		u := intFromModelField(hv["uncatalogued_provider_count"])
		m := intFromModelField(hv["mismatch_provider_count"])
		invalid := intFromModelField(hv["invalid_provider_count"])
		verified += v
		uncatalogued += u
		nonVerified += u + m + invalid
		if b, ok := hvRaw.(bool); ok && !b && u+m+invalid == 0 {
			nonVerified++
		}
		if s, ok := hv["status"].(string); ok && s == "catalog_unavailable" {
			nonVerified++
		}
	}
	switch {
	case !active:
		return false, "", 0, 0
	case verified > 0 && nonVerified == 0:
		state = "all"
	case verified > 0:
		state = "partial"
	default:
		state = "none"
	}
	return active, state, verified, uncatalogued
}

func intFromModelField(v any) int {
	switch n := v.(type) {
	case float64:
		return int(n)
	case json.Number:
		i, _ := n.Int64()
		return int(i)
	default:
		return 0
	}
}

type routingMetaCache struct {
	mu        sync.Mutex
	value     coordinatorRoutingMetadata
	ok        bool
	fetchedAt time.Time
}
