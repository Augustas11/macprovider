package pool

import (
	"bytes"
	"encoding/json"
	"fmt"
	"log/slog"
	"math"
	"net"
	"strings"
	"sync"
	"time"

	"github.com/augstar/macprovider-coordinator/internal/billing"
	"github.com/augstar/macprovider-coordinator/internal/config"
)

type State string
type Tier string
type InferencePath string
type RecoveryReason string
type HashStatus string
type AttestationStatus string

// AuthState records HOW a provider session was admitted. The zero value
// (empty string) is intentionally "no special marking" so pre-FR-C9 providers
// and pinned-tier admissions don't need to set it explicitly. Bearer-validated
// sessions are trusted for routing. Self-minted sessions remain visible but are
// not money-path eligible until they return with a credential proof.
type AuthState string

const (
	StateReady       State = "ready"
	StateBusy        State = "busy"
	StateDegraded    State = "degraded"
	StateDraining    State = "draining"
	StateUnavailable State = "unavailable"

	TierPinned      Tier = "pinned"
	TierProvisional Tier = "provisional"
	TierRejected    Tier = "rejected"

	InferencePathHTTPForwarding InferencePath = "http_forwarding"
	InferencePathWSTunneled     InferencePath = "ws_tunneled"

	RecoveryReasonBreaker         RecoveryReason = "breaker"
	RecoveryReasonProviderFailure RecoveryReason = "provider_failure"
	RecoveryReasonCanary          RecoveryReason = "canary"
	RecoveryReasonOperatorClear   RecoveryReason = "operator_clear"

	HashStatusVerified           HashStatus = "hash_verified"
	HashStatusMismatch           HashStatus = "hash_mismatch"
	HashStatusInvalid            HashStatus = "hash_invalid"
	HashStatusUncatalogued       HashStatus = "uncatalogued"
	HashStatusCatalogUnavailable HashStatus = "catalog_unavailable"

	AttestationStatusAttested    AttestationStatus = "attested"
	AttestationStatusFailed      AttestationStatus = "attestation_failed"
	AttestationStatusStale       AttestationStatus = "attestation_stale"
	AttestationStatusUnsupported AttestationStatus = "unsupported"
	AttestationStatusNotRequired AttestationStatus = "not_required"

	// AttestationTier values (see Provider.AttestationTier). A self-signed SE
	// key proves key custody, not hardware-rooted attestation — only
	// AttestationTierHardware may be surfaced as hardware-attested.
	AttestationTierSelfSigned = "self_signed"
	AttestationTierHardware   = "hardware"

	// AuthBearerValidated — connect arrived with a Bearer header that
	// auth.Store.ValidateToken matched. Post-flag-flip this is the
	// only admitted state.
	AuthBearerValidated AuthState = "bearer_validated"
	// AuthSelfMinted — connect arrived tokenless and the coordinator minted a
	// fresh provider_tokens row + returned the cleartext in the ack frame.
	// Provider can persist it and reconnect authenticated next time. The
	// current tokenless session is not routing or payout eligible.
	AuthSelfMinted AuthState = "self_minted"
	// AuthSelfMintedVerified is reserved for explicit proof-of-ownership
	// challenge completion. Today, the production path reaches equivalent
	// trust by reconnecting with the minted Bearer and becoming
	// AuthBearerValidated.
	AuthSelfMintedVerified AuthState = "self_minted_verified"
	// AuthBearerlessDuplicate — connect arrived tokenless for a
	// provider_id that already has an unrevoked token row in
	// provider_tokens (FR-C9.4 v0.8.3). The connection is admitted
	// (the v0.8.2 hard-reject was a deploy brick — see Entry 66) but
	// excluded from routing + billing + cannot evict an existing
	// session for the same provider_id. Operator MUST revoke the
	// stale row before the legitimate provider can reconnect cleanly.
	AuthBearerlessDuplicate AuthState = "bearerless_duplicate"
	// AuthMintFailed — FR-C9.1 mint attempted but a non-constraint DB
	// error occurred (transient infrastructure failure, not race-loss).
	// SPEC-003 v0.8.4 (fix-pass-5) marks the session distinctly from
	// the pre-FR-C9 / no-issuer empty state so /poolz observers can
	// distinguish "FR-C9 wanted to mint but the DB failed" from
	// "FR-C9 isn't enabled here." The wire treatment is fail-closed
	// (RejectTOFU) because admitting an empty-AuthState session as
	// fully routable would amplify a DB-error storm into a routing
	// admission DoS. See codex security audit MAJOR-1 on PR #69
	// fix-pass-4 + architect Recommended Followup 4.
	AuthMintFailed AuthState = "mint_failed"
)

type Provider struct {
	ProviderID              string  `json:"provider_id"`
	AssignedID              string  `json:"assigned_id"`
	Hostname                string  `json:"hostname"`
	ModelID                 string  `json:"model_id"`
	ModelParamsB            float64 `json:"model_params_b"`
	RAMGB                   int     `json:"ram_gb"`
	MaxContextTokens        int     `json:"max_context_tokens"`
	MaxConcurrency          int     `json:"max_concurrency"`
	SlotsFree               int     `json:"slots_free"`
	SlotsTotal              int     `json:"slots_total"`
	ThroughputTPSEstimate   float64 `json:"throughput_tps_estimate"`
	RequestsServedSinceLast int     `json:"-"`
	ThroughputTPSSinceLast  float64 `json:"-"`
	ModelLoadTimeMs         int64   `json:"model_load_time_ms,omitempty"`
	EndpointURL             string  `json:"endpoint_url"`
	Tier                    Tier    `json:"tier"`
	// AuthState records how the connect was admitted. Empty string
	// preserves pre-v0.8.3 behavior (routable, billable). Set to
	// AuthBearerlessDuplicate by the duplicate-tokenless admit path
	// in resolveProvisionalToken; set to AuthSelfMinted on a fresh
	// FR-C9.1 mint; set to AuthBearerValidated when the connect
	// carried a Bearer header that matched a stored token. The
	// Registry uses this to refuse evicting a routable session in
	// favor of a bearer-less duplicate; buyer routing + billing use
	// it to exclude bearer-less duplicates from money paths.
	AuthState          AuthState     `json:"auth_state,omitempty"`
	InferencePath      InferencePath `json:"inference_path"`
	AdmittedAt         time.Time     `json:"admitted_at"`
	HTTPForwardingOnly bool          `json:"http_forwarding_only,omitempty"`
	State              State         `json:"state"`
	LastHeartbeatAt    time.Time     `json:"last_heartbeat_at"`
	// LastActivityAt is the timestamp of the most recent inbound frame of any
	// kind (heartbeat OR in-flight inference response). The liveness monitor
	// uses this — not LastHeartbeatAt — so a provider actively streaming a
	// long generation is not closed for "missing" heartbeats it cannot send
	// while its single inference slot is busy.
	LastActivityAt        time.Time  `json:"last_activity_at"`
	ConnectedAt           time.Time  `json:"connected_at"`
	BinaryVersion         string     `json:"binary_version"`
	ModelHash             string     `json:"model_hash,omitempty"`
	ModelHashAlgorithm    string     `json:"model_hash_algorithm,omitempty"`
	WeightsManifestSHA256 string     `json:"weights_manifest_sha256,omitempty"`
	WeightsHashAlgorithm  string     `json:"weights_manifest_algorithm,omitempty"`
	ExpectedModelHash     string     `json:"-"`
	HashStatus            HashStatus `json:"hash_status,omitempty"`
	EncryptedLeg          bool       `json:"encrypted_leg,omitempty"`
	// Catalog admission captures the exact signed recommendation envelope that
	// was accepted for this live session. Deployment canaries use these fields
	// to distinguish a current catalog-aware provider from a legacy bridge
	// connection or a bounded previous-release admission.
	CatalogAdmissionMode   string `json:"catalog_admission_mode,omitempty"`
	CatalogReleaseID       string `json:"catalog_release_id,omitempty"`
	CatalogPolicyVersion   string `json:"catalog_policy_version,omitempty"`
	CandidateCatalogSHA256 string `json:"catalog_candidate_sha256,omitempty"`
	CatalogSignerKeyID     string `json:"catalog_signer_key_id,omitempty"`
	CandidateRowIdentity   string `json:"catalog_row_identity,omitempty"`
	// SPEC-015 v0.1.3 / SPEC-001 v1.6 — raw ed25519 public key bytes
	// populated from auth_request.provider_receipt_public_key when present.
	ReceiptPubkey []byte `json:"-"`
	// Previous receipt pubkey retained during the SPEC-015 rotation grace
	// window. /poolz owns the public JSON projection.
	ReceiptPubkeyPrev *ReceiptPubkeyPrevious `json:"-"`
	// PendingReceiptPubkey is a changed receipt key accepted during v2 auth but
	// not yet published to /poolz. The provider publishes it only after its
	// post-auth state_update, which the provider sends after local Keychain
	// commit.
	PendingReceiptPubkey []byte `json:"-"`
	// AttestationStatus is informational unless tier2.require_attestation is
	// enabled. The zero value represents a legacy provider with no claim.
	AttestationStatus AttestationStatus `json:"attestation_status,omitempty"`
	// CanaryFailCount is the current consecutive nonce-echo canary failure
	// count for this live session. Zero is omitted from generic Provider JSON
	// to preserve L-1 default wire compatibility; /poolz adds the field
	// explicitly for every provider.
	CanaryFailCount     int        `json:"canary_fail_count,omitempty"`
	CanaryLastCheckedAt *time.Time `json:"canary_last_checked_at,omitempty"`
	CanaryLastFailedAt  *time.Time `json:"canary_last_failed_at,omitempty"`
	// CanaryLastTTFTMS / CanaryLastSustainedTPS are the wall-time latency
	// metrics of the most recent completed canary probe. They are the only
	// coordinator-measured live TTFT/TPS signal (buyer relays are not timed
	// into the pool), so /poolz uses them for the per-binary_version
	// segmentation that isolates a slow backend build. Zero = never probed.
	CanaryLastTTFTMS       int     `json:"canary_last_ttft_ms,omitempty"`
	CanaryLastSustainedTPS float64 `json:"canary_last_sustained_tps,omitempty"`
	// BenchmarkQuarantined marks a provider that has no verified autotune
	// benchmark while the telemetry-drift quarantine gate is enabled. Absence
	// of a benchmark is a DISTINCT suspect bucket (issue #765): it is not proof
	// of misbehaviour, so the session stays admitted and operator-visible, but
	// it is fail-suspect rather than fail-open and receives no buyer traffic
	// until a benchmark exists. Always false when the gate is off.
	BenchmarkQuarantined bool `json:"benchmark_quarantined,omitempty"`
	// LastBuyerSuccessAt is the most recent coordinator-observed successful
	// buyer relay for this provider (HTTP 2xx / completed stream). Used by
	// FR-CAN23 observed-serving residual so a peer that never served buyers
	// cannot lift the last-provider floor. Omitted from wire JSON.
	LastBuyerSuccessAt  *time.Time      `json:"-"`
	LastAutoupdateEvent json.RawMessage `json:"last_autoupdate_event,omitempty"`
	// HardwareCapacity is live, provider-reported capacity metadata carried on
	// heartbeats for public aggregate stats. It is deliberately separate from
	// AttestationStatus and from verified stats hardware inventory: it can make
	// cores/bandwidth visible without claiming hardware attestation.
	HardwareCapacity *ProviderHardwareCapacity `json:"hardware_capacity,omitempty"`
	// SafetyTelemetry is the latest versioned provider-health observation
	// accepted on this session's heartbeat. /poolz exposes it to authenticated
	// operators so remote canaries can enforce queue, memory, thermal, restart,
	// and runtime invariants without a provider-local network route.
	SafetyTelemetry *ProviderSafetyTelemetry `json:"safety_telemetry,omitempty"`
	// Proof of Weights W2 — coordinator-side autotune admission cap derived
	// from latest verified hardware-evidence benchmarks. Empty/zero when
	// evidence observation is not wired or provider admitted before W2 rollout.
	MaxAdmittedModelKey string `json:"max_admitted_model_class,omitempty"`
	MaxAdmittedModelID  string `json:"max_admitted_model_id,omitempty"`
	MaxAdmittedMinRAMGB int    `json:"max_admitted_min_ram_gb,omitempty"`
	// AdmissionCeilingExcluded marks a live session whose mutable heartbeat
	// model_id is no longer within the autotune admission ceiling captured at
	// hello. The session stays operator-visible, but buyer routing and serving
	// capacity fail closed until the model/evidence revalidates.
	AdmissionCeilingExcluded bool `json:"admission_ceiling_excluded,omitempty"`
	// AdmissionEvidenceStale marks a live session whose admitted autotune
	// evidence could not be revalidated within the configured TTL. Kept
	// separate from AdmissionCeilingExcluded so a heartbeat that returns to an
	// in-ceiling model cannot clear a stale-evidence fail-closed verdict.
	AdmissionEvidenceStale bool `json:"admission_evidence_stale,omitempty"`
	// AdmissionSandboxed marks a strict hello-gate session that connected
	// without verified hardware evidence. The session remains visible and may
	// receive coordinator-owned probes, but it never receives buyer traffic or
	// counts as buyer-serving capacity until proof-of-weights re-gating clears
	// this flag from verified evidence.
	AdmissionSandboxed bool `json:"admission_sandboxed,omitempty"`
	// AdmissionSandboxCredentialBypassed is set only for sessions that entered
	// as sandbox-only and therefore did not receive newly minted durable
	// provider credentials. Gate-disable reloads must not auto-promote these
	// sessions; they need a reconnect or verified re-gating path before they can
	// become buyer-routable.
	AdmissionSandboxCredentialBypassed bool `json:"-"`
	// Admitted hardware-trust tuple (issue #582 FIX B). Captured at the hello
	// gate from the exact verified evidence that authorized this session, so the
	// bounded trust-revalidation sweep can re-check the SAME hardware tuple that
	// admitted the session — not merely "any active trust root for this
	// provider_id". This closes the gap where a second Mac (different
	// hardware_identity_hash, same provider_id) with an active root kept a
	// session alive after the root that actually admitted it was revoked/expired.
	// Empty when the hello gate is disabled (no trust checker wired).
	AdmittedHardwareIdentityHash string `json:"admitted_hardware_identity_hash,omitempty"`
	AdmittedChipNormalized       string `json:"admitted_chip_normalized,omitempty"`
	AdmittedUnifiedMemoryGB      int    `json:"admitted_unified_memory_gb,omitempty"`
	// Proof of Weights W3 — latest model-class OPoI probe outcome when a
	// per-model challenge bank with optional latency gates was used.
	// Omitted when only the global canary bank applies.
	ModelClassOPoIPass *bool `json:"model_class_opoi_pass,omitempty"`

	// SE attestation fields (Phase 1).
	// SEPublicKey holds the raw P-256 public key (64 bytes: 32 X || 32 Y) verified
	// during macprovider-se-p256-v1 auth. Nil when no SE attestation was presented.
	// Not exported in public JSON to avoid leaking key material; set by P1-B verifier.
	SEPublicKey []byte `json:"-"`
	// AttestationTier records the verified attestation strength.
	// Values: "" (legacy/none), "self_signed" (SE P-256 verified), "hardware" (MDA, Phase 3+).
	AttestationTier string `json:"attestation_tier,omitempty"`
	// LastSELivenessAt is the coordinator clock of the most recent successful SE liveness response.
	LastSELivenessAt *time.Time `json:"last_se_liveness_at,omitempty"`
	// SELivenessFailCount is the current consecutive SE liveness failure count.
	// Internal only — not serialised to JSON.
	SELivenessFailCount int `json:"-"`

	// SPEC-002 v1.3.5 §3.X.1 — populated from v2 auth_request initial-stage
	// supported_models[] per SPEC-010 v1.5 R-3.3.1; nil for the L-1 baseline.
	SupportedModels []string `json:"supported_models,omitempty"`
	// SPEC-002 v1.3.5 §3.X.2 — populated from publishes_supported_models per
	// SPEC-010 v1.5 R-3.3.2; gates /v1/status echo per §7.4 R-7.4.1.
	PublishesSupportedModels bool `json:"publishes_supported_models,omitempty"`
	// SPEC-002 v1.3.5 §3.X.4 — sticky last-heartbeat loading flag for the
	// §7.1 R-7.1.6 / §7.10 R-7.10.8 exactly-once operator_model_swap gate.
	LastLoadingState bool `json:"-"`
	// SPEC-002 v1.3.5 §7.10.2 R-7.10.6 — coordinator clock at the first
	// observed loading:true heartbeat; loading_window_ms is computed at
	// swap-completion emission.
	LoadingStartedAt time.Time `json:"-"`

	Tier2Session *Tier2Session `json:"-"`

	conn net.Conn
}

type AdmissionGateFlags struct {
	AdmissionCeilingExcluded bool
	AdmissionEvidenceStale   bool
	AdmissionSandboxed       bool
}

type ProviderSafetyTelemetry struct {
	SchemaVersion         int      `json:"schema_version"`
	ProviderID            string   `json:"provider_id"`
	ModelID               string   `json:"model_id"`
	ModelLoaded           bool     `json:"model_loaded"`
	RuntimeState          string   `json:"runtime_state"`
	HardwareTier          string   `json:"hardware_tier"`
	RequestsInFlight      int      `json:"requests_in_flight"`
	RequestsQueued        int      `json:"requests_queued"`
	MemoryRSSMB           int      `json:"memory_rss_mb"`
	MemoryCapacityMB      int      `json:"memory_capacity_mb"`
	MemoryPressure        string   `json:"memory_pressure"`
	ThermalState          string   `json:"thermal_state"`
	ThermallyThrottled    bool     `json:"thermally_throttled"`
	RestartCount          int      `json:"restart_count"`
	UptimeS               int      `json:"uptime_s"`
	CoordinatorConnected  bool     `json:"coordinator_connected"`
	CoordinatorSessionID  string   `json:"coordinator_session_id,omitempty"`
	CPUUtilizationPct     *float64 `json:"cpu_utilization_pct"`
	GPUUtilizationPct     *float64 `json:"gpu_utilization_pct"`
	GPUUtilizationScope   string   `json:"gpu_utilization_scope,omitempty"`
	PowerSource           string   `json:"power_source,omitempty"`
	BinaryVersion         string   `json:"binary_version,omitempty"`
	CompatibilitySetID    string   `json:"compatibility_set_id,omitempty"`
	ModelHash             string   `json:"model_hash,omitempty"`
	ModelHashAlgorithm    string   `json:"model_hash_algorithm,omitempty"`
	WeightsManifestSHA256 string   `json:"weights_manifest_sha256,omitempty"`
	WeightsHashAlgorithm  string   `json:"weights_manifest_algorithm,omitempty"`
	ObservationID         string   `json:"observation_id"`
	ObservedAt            string   `json:"observed_at"`
	ValidForMS            int      `json:"valid_for_ms"`
}

func cloneProviderSafetyTelemetry(in *ProviderSafetyTelemetry) *ProviderSafetyTelemetry {
	if in == nil {
		return nil
	}
	out := *in
	return &out
}

type ProviderHardwareCapacity struct {
	Chip              string  `json:"chip,omitempty"`
	BandwidthGBPerSec int64   `json:"bandwidth_gb_per_s,omitempty"`
	NetworkPowerKW    float64 `json:"network_power_kw,omitempty"`
	GPUCoresTotal     int     `json:"gpu_cores_total,omitempty"`
	CPUCoresTotal     int     `json:"cpu_cores_total,omitempty"`
}

const (
	MaxProviderHardwareChipBytes         = 120
	MaxProviderHardwareBandwidthGBPerSec = int64(10_000)
	MaxProviderHardwareNetworkPowerKW    = 10.0
	MaxProviderHardwareGPUCoresTotal     = 4_096
	MaxProviderHardwareCPUCoresTotal     = 1_024
)

func cloneProviderHardwareCapacity(in *ProviderHardwareCapacity) *ProviderHardwareCapacity {
	if in == nil {
		return nil
	}
	out := *in
	return sanitizeProviderHardwareCapacity(&out)
}

func sanitizeProviderHardwareCapacity(in *ProviderHardwareCapacity) *ProviderHardwareCapacity {
	if in == nil {
		return nil
	}
	out := *in
	out.Chip = strings.TrimSpace(out.Chip)
	if len([]byte(out.Chip)) > MaxProviderHardwareChipBytes {
		out.Chip = truncateUTF8Bytes(out.Chip, MaxProviderHardwareChipBytes)
	}
	if out.BandwidthGBPerSec < 0 {
		out.BandwidthGBPerSec = 0
	} else if out.BandwidthGBPerSec > MaxProviderHardwareBandwidthGBPerSec {
		out.BandwidthGBPerSec = MaxProviderHardwareBandwidthGBPerSec
	}
	if out.NetworkPowerKW < 0 || math.IsNaN(out.NetworkPowerKW) || math.IsInf(out.NetworkPowerKW, 0) {
		out.NetworkPowerKW = 0
	} else if out.NetworkPowerKW > MaxProviderHardwareNetworkPowerKW {
		out.NetworkPowerKW = MaxProviderHardwareNetworkPowerKW
	}
	if out.GPUCoresTotal < 0 {
		out.GPUCoresTotal = 0
	} else if out.GPUCoresTotal > MaxProviderHardwareGPUCoresTotal {
		out.GPUCoresTotal = MaxProviderHardwareGPUCoresTotal
	}
	if out.CPUCoresTotal < 0 {
		out.CPUCoresTotal = 0
	} else if out.CPUCoresTotal > MaxProviderHardwareCPUCoresTotal {
		out.CPUCoresTotal = MaxProviderHardwareCPUCoresTotal
	}
	if out.Chip == "" && out.BandwidthGBPerSec == 0 && out.NetworkPowerKW == 0 &&
		out.GPUCoresTotal == 0 && out.CPUCoresTotal == 0 {
		return nil
	}
	return &out
}

func truncateUTF8Bytes(s string, maxBytes int) string {
	if maxBytes <= 0 || len([]byte(s)) <= maxBytes {
		return s
	}
	last := 0
	for i := range s {
		if i > maxBytes {
			break
		}
		last = i
	}
	if last == 0 {
		return ""
	}
	return s[:last]
}

type Tier2Session struct {
	AEADSuite                      string
	ResponseChunkPlaintextEnvelope bool
	InBandAEADRekeyV1              bool
	C2PKey                         []byte
	P2CKey                         []byte
	C2PNonceBase                   []byte
	P2CNonceBase                   []byte
	C2PCounter                     uint64
	P2CCounter                     uint64
	P2CSeen                        map[uint64]struct{}
	RequestsDispatched             uint64
	KeyID                          string
	StartedAt                      time.Time
}

// ReplaceTier2Session atomically advances the encrypted-leg epoch for the
// currently registered assigned session. It cannot mutate a replacement
// connection or a stale rekey attempt because both the assigned ID and prior
// key ID must still match.
func (r *Registry) ReplaceTier2Session(providerID, assignedID, expectedKID string, next *Tier2Session) bool {
	if next == nil || next.KeyID == "" || next.KeyID == expectedKID || len(next.C2PKey) != 32 || len(next.P2CKey) != 32 || len(next.C2PNonceBase) != 4 || len(next.P2CNonceBase) != 4 {
		return false
	}
	r.mu.Lock()
	defer r.mu.Unlock()
	p := r.providers[providerID]
	if p == nil || p.AssignedID != assignedID || r.sessions[assignedID] != p || p.Tier2Session == nil || p.Tier2Session.KeyID != expectedKID {
		return false
	}
	p.Tier2Session = next
	return true
}

type ReceiptPubkeyPrevious struct {
	Pubkey    []byte
	RotatedAt time.Time
	ExpiresAt time.Time
}

// RoutingEligible is the single authority on whether a session may receive
// buyer traffic and serve as a billing identity. It captures credential trust
// (was this session admitted with a credential we trust?) and slot
// availability — NOT Tier-2 hash enforcement, which is operator-configurable
// and lives in Tier-2-aware buyer code.
//
// SPEC-003 v0.8.3 FR-C9.4 — bearer-less duplicate sessions are registered in
// the pool (so they're operator-visible in /poolz) but excluded from routing.
// The provider on the other end thinks they're admitted but receives no buyer
// traffic and accrues no billing identity under the claimed provider_id. The
// legitimate holder of the token row remains routable.
//
// HashStatus filtering used to live here as a defense-in-depth gate. Fix-pass-4
// removed it: when Tier-2 hash enforcement is disabled, hash-mismatched
// providers must still route, and a non-config-aware predicate cannot model
// that. Buyer routing (chat completions, hard-pin) calls RoutingEligible()
// alongside tier2ProviderExcludedStatus to enforce hash policy. Catalog-aware
// deployments also keep metadata-free legacy bridge sessions operator-visible
// and temporarily routable only during the explicitly bounded migration
// window. Once strict admission is enabled or that deadline expires, those
// sessions become legacy and are excluded here. Catalog and health surfaces
// separately exclude pending receipt-key publication while preserving ready
// providers that are temporarily out of free slots. When the strict autotune
// hello gate is enabled, a heartbeat model outside the verified hello cap is an
// integrity violation and is excluded here even when it is the sole provider for
// that model.
func (p Provider) RoutingEligible() bool {
	if p.AuthState == AuthBearerlessDuplicate || p.AuthState == AuthSelfMinted {
		return false
	}
	if p.CatalogAdmissionMode == "legacy" || p.CatalogAdmissionMode == "update_bridge" {
		return false
	}
	if len(p.PendingReceiptPubkey) > 0 {
		return false
	}
	if p.BenchmarkQuarantined {
		return false
	}
	if p.AdmissionCeilingExcluded || p.AdmissionEvidenceStale || p.AdmissionSandboxed {
		return false
	}
	return p.State == StateReady && p.SlotsFree > 0
}

// ServingCapable reports whether an admitted provider is still part of the
// network's buyer-serving capacity. Unlike RoutingEligible it deliberately
// ignores transient free-slot availability: a busy provider remains serving
// capable while finishing buyer work, but cannot receive another route until
// a slot becomes free. Trust, catalog admission, rotation, health, Tier-2, and
// quota gates still apply at their respective call sites.
func (p Provider) ServingCapable() bool {
	if p.AuthState == AuthBearerlessDuplicate || p.AuthState == AuthSelfMinted {
		return false
	}
	if p.CatalogAdmissionMode == "legacy" || p.CatalogAdmissionMode == "update_bridge" {
		return false
	}
	if len(p.PendingReceiptPubkey) > 0 {
		return false
	}
	if p.BenchmarkQuarantined {
		return false
	}
	if p.AdmissionCeilingExcluded || p.AdmissionEvidenceStale || p.AdmissionSandboxed {
		return false
	}
	return p.State == StateReady || p.State == StateBusy
}

// CapacityEligible is retained for existing capacity/statistics call sites.
// New buyer-serving verdicts should use ServingCapable so they do not imply
// that a currently busy provider is immediately RoutingEligible.
func (p Provider) CapacityEligible() bool {
	return p.ServingCapable()
}

func (p Provider) IsWSTunneled() bool {
	return p.InferencePath == InferencePathWSTunneled && !p.HTTPForwardingOnly
}

// SortKey returns the stable per-provider identity string used by
// the routing pipeline as a map key (e.g. for `excluded` sets, per-
// candidate score maps, and faulted-route tracking). The format is
// `<ProviderID>/<AssignedID>` so two providers that share a model+
// endpoint but were issued different AssignedIDs by the session
// manager remain distinct.
//
// Centralised here in #266 T3a — pre-T3a both `buyer.routeKey` and
// `routing.providerSortKey` derived the same string in parallel,
// and `startRecoveryProbe` had its own inline concat. A single
// pool method eliminates the divergence trap (R1 ARCH-L1 audit
// finding on PR #273).
//
// PRECONDITION: ProviderID MUST NOT contain "/", otherwise the
// delimiter is ambiguous and two different (ProviderID, AssignedID)
// pairs could collide on the same key. The invariant is enforced at
// every registration site by `config.ValidateProviderID` (issue
// #274). AssignedID is a coordinator-issued UUID and similarly may
// not contain "/"; if the AssignedID format ever changes, this
// docstring AND the key encoding must be revisited.
func (p Provider) SortKey() string {
	return p.ProviderID + "/" + p.AssignedID
}

type Registry struct {
	mu        sync.RWMutex
	providers map[string]*Provider
	sessions  map[string]*Provider
	endpoints map[string]config.ProviderConfig
	// buyerServing, when set, decides whether a provider passes the coordinator's
	// REQUEST-INDEPENDENT buyer-routability gates (RoutingEligible + transport-
	// reachable + positive context window + not Tier-2-excluded) for the FR-CAN22
	// last-provider floor and the redundancy count. Injected by the ws layer via
	// SetBuyerServingPredicate because the transport (session) and Tier-2 gates need
	// state/config outside the pool package. Request-dependent context/quota are NOT
	// evaluated (deferred to FR-CAN23 — see canaryBuyerServing). Nil falls back to
	// RoutingEligible + positive context (omitting the ws-only transport/Tier-2
	// gates) — used only in registry unit tests; production injects the full
	// predicate so a busy, negative-slot, transport-unreachable, or Tier-2-excluded
	// peer cannot falsely lift the floor and empty the real routable pool.
	buyerServing func(Provider) bool
	// seenModelsByProvider tracks the model IDs ever reported by each
	// currently-connected provider. M2-5 / PERF-5: previously a single
	// registry-wide `seenModels map[string]struct{}` accumulated forever
	// (no cleanup on provider removal); per the 2026-06-10 audit it could
	// outgrow the pool unboundedly. Now keyed by providerID and dropped
	// on RemoveIfSession / RemoveIfSessionState, with a per-provider cap
	// to bound a single provider's contribution.
	seenModelsByProvider map[string]map[string]struct{}
	// seenModelsLifetime is the SPEC-002 v1.4.1 § 7.2 pool-lifetime
	// model history: any model id ever advertised during this coordinator
	// process lifetime, retained even after the advertising provider
	// disconnects. Issue #185: the M2-5 cleanup of seenModelsByProvider
	// on provider disconnect inadvertently shrank `ModelKnown`'s answer
	// to "currently-connected only", which made cold-start races (only
	// provider for a model disconnects, buyer asks for that model)
	// return 404 model_not_found instead of the spec-mandated 503
	// no_provider_available. seenModelsLifetime is append-only within a
	// hard cap (maxSeenModelsLifetime) so the PERF-5 memory bound
	// still holds — beyond cap, further model ids are silently dropped,
	// which degrades cold-start races to the legacy 404 behavior for
	// rare/transient models without crashing.
	seenModelsLifetime map[string]struct{}
	// lifetimeContribByProvider tracks how many DISTINCT model ids a
	// given provider_id has contributed to seenModelsLifetime over
	// the entire coordinator process lifetime — NOT reset on session
	// replacement or disconnect. This bounds churn-via-reconnect: a
	// malicious provider cannot consume the lifetime cap by repeatedly
	// disconnecting and reconnecting with new model ids. Capped per
	// provider at maxLifetimeContribPerProvider (4x the per-session
	// budget). ISS-185 R2 security-lane MAJOR.
	lifetimeContribByProvider map[string]int
	// lifetimeCapWarnedOnce gates the warn-log so the operator gets
	// one signal at first cap exhaustion, not per-heartbeat spam.
	lifetimeCapWarnedOnce bool
	// lifetimeCapDroppedCount counts model-id inserts that were
	// dropped because seenModelsLifetime was at cap. Exposed via
	// LifetimeCapStats() so explorer / metrics can scrape it; nonzero
	// = either runaway provider churn or a legitimate catalog larger
	// than expected.
	lifetimeCapDroppedCount uint64
	breakerFaults           map[string][]time.Time
	recoveryHolds           map[string]recoveryHold
	canarySanctions         map[string]canarySanction
	lastBreakerRecoveries   map[string]time.Time
	maxProvider             int
	hashVerifier            HeartbeatHashVerifier
	modelIdentityVerifier   ModelIdentityVerifier
	swapEmitter             SwapEventEmitter
	receiptRotationEmitter  ReceiptRotationEventEmitter
}

// maxSeenModelsPerProvider caps the seenModelsByProvider inner set so a
// single misbehaving provider can't blow up memory. 32 is several orders
// of magnitude above legitimate use (a real provider serves 1-2 models
// at a time); reaching this cap silently drops further model IDs.
// M2-5 / PERF-5.
const maxSeenModelsPerProvider = 32

// maxSeenModelsLifetime caps the pool-lifetime model-id accumulator that
// implements SPEC-002 § 7.2's 404-vs-503 distinction. 4096 is several
// orders of magnitude above any realistic mac-provider catalog — most
// deployments serve 5-50 distinct model ids — so reaching the cap means
// a buggy provider is churning model ids. At the cap further inserts
// are dropped (logged via warn-once + counter), which degrades cold-
// start races to the legacy 404 behavior for the dropped ids without
// unbounded growth. Issue #185 / SPEC-002 § 7.2 + PERF-5 / 2026-06-10
// audit reconciliation.
const maxSeenModelsLifetime = 4096

// maxModelIDByteLen bounds the size of a single model_id string that
// gets persisted into the lifetime / per-provider seen-model maps.
// ISS-185 R1 security-lane CRITICAL: without this bound a provider
// could advertise very-large model_id strings and force the
// coordinator to retain them in seenModelsLifetime for the process
// lifetime, since `requireString` in
// phase4-coordinator/internal/ws/messages.go does not byte-cap the
// raw string. 256 bytes aligns with the existing `supported_models`
// byte cap precedent and is several KB above realistic model ids
// (e.g. "mlx-community/Qwen3-32B-4bit" is 28 bytes). Oversize ids
// are not persisted; routing requests for them fall through to the
// "never seen" 404 path.
const maxModelIDByteLen = 256

// maxLifetimeContribPerProvider bounds how many DISTINCT model ids
// a single provider_id can contribute to seenModelsLifetime over
// the entire coordinator process lifetime, surviving disconnect and
// session replacement. This bounds churn-via-reconnect by a
// malicious provider while keeping the per-session attribution map
// (seenModelsByProvider, capped at maxSeenModelsPerProvider = 32)
// free to fill independently each session. 128 is 4x the per-session
// cap — generous enough that a legitimate provider rebooting many
// times across the process lifetime won't be capped, but tight
// enough that one malicious provider cannot consume more than
// 128/4096 ≈ 3% of total lifetime budget. ISS-185 R2 security-lane
// MAJOR (per-provider gating must survive reconnect).
const maxLifetimeContribPerProvider = 128

// ReceiptRotationGrace is the SPEC-015 overlap window during which buyers may
// validate receipts signed by the previous provider receipt key.
const ReceiptRotationGrace = 7 * 24 * time.Hour

type recoveryHold struct {
	assignedID string
	reason     RecoveryReason
}

type canarySanction struct {
	failCount     int
	lastCheckedAt *time.Time
	lastFailedAt  *time.Time
}

type CanarySanctionSnapshot struct {
	ProviderID    string
	FailCount     int
	LastCheckedAt *time.Time
	LastFailedAt  *time.Time
}

func NewRegistry(providers []config.ProviderConfig, opts ...RegistryOption) *Registry {
	endpoints := make(map[string]config.ProviderConfig, len(providers))
	for _, p := range providers {
		endpoints[p.ProviderID] = p
	}
	r := &Registry{
		providers:                 map[string]*Provider{},
		sessions:                  map[string]*Provider{},
		endpoints:                 endpoints,
		seenModelsByProvider:      map[string]map[string]struct{}{},
		seenModelsLifetime:        map[string]struct{}{},
		lifetimeContribByProvider: map[string]int{},
		breakerFaults:             map[string][]time.Time{},
		recoveryHolds:             map[string]recoveryHold{},
		canarySanctions:           map[string]canarySanction{},
		lastBreakerRecoveries:     map[string]time.Time{},
	}
	for _, opt := range opts {
		opt(r)
	}
	return r
}

func (r *Registry) LoadCanarySanctions(snapshots []CanarySanctionSnapshot) {
	r.mu.Lock()
	defer r.mu.Unlock()
	for _, snapshot := range snapshots {
		if strings.TrimSpace(snapshot.ProviderID) == "" || snapshot.FailCount <= 0 {
			continue
		}
		r.canarySanctions[snapshot.ProviderID] = canarySanction{
			failCount:     snapshot.FailCount,
			lastCheckedAt: cloneTimePtr(snapshot.LastCheckedAt),
			lastFailedAt:  cloneTimePtr(snapshot.LastFailedAt),
		}
	}
}

func (r *Registry) CanarySanctions() []CanarySanctionSnapshot {
	r.mu.RLock()
	defer r.mu.RUnlock()
	out := make([]CanarySanctionSnapshot, 0, len(r.canarySanctions))
	for providerID, sanction := range r.canarySanctions {
		out = append(out, CanarySanctionSnapshot{
			ProviderID:    providerID,
			FailCount:     sanction.failCount,
			LastCheckedAt: cloneTimePtr(sanction.lastCheckedAt),
			LastFailedAt:  cloneTimePtr(sanction.lastFailedAt),
		})
	}
	return out
}

// ClearCanarySanction removes coordinator-owned canary failure state for a
// provider after an authenticated operator recovery action. A live session is
// deliberately left in its current state; a fresh reconnect + warmup must
// prove it routable again.
func (r *Registry) ClearCanarySanction(providerID string) bool {
	r.mu.Lock()
	defer r.mu.Unlock()

	_, hadPersistedSanction := r.canarySanctions[providerID]
	delete(r.canarySanctions, providerID)

	hadRuntimeState := false
	p := r.providers[providerID]
	if p != nil {
		hadRuntimeState = p.CanaryFailCount > 0 || p.CanaryLastFailedAt != nil
		p.CanaryFailCount = 0
		p.CanaryLastFailedAt = nil
	}
	if hold, held := r.recoveryHolds[providerID]; held && hold.reason == RecoveryReasonCanary {
		hadRuntimeState = true
		if p != nil && p.AssignedID == hold.assignedID && p.State == StateDegraded {
			// Keep this exact session unroutable until reconnect + warmup proves
			// it healthy. Converting the reason also makes repeated operator
			// clears idempotent.
			r.recoveryHolds[providerID] = recoveryHold{
				assignedID: hold.assignedID,
				reason:     RecoveryReasonOperatorClear,
			}
		} else {
			delete(r.recoveryHolds, providerID)
		}
	}
	return hadPersistedSanction || hadRuntimeState
}

func cloneTimePtr(t *time.Time) *time.Time {
	if t == nil {
		return nil
	}
	cloned := *t
	return &cloned
}

func (r *Registry) Endpoint(providerID string) (config.ProviderConfig, bool) {
	r.mu.RLock()
	defer r.mu.RUnlock()
	p, ok := r.endpoints[providerID]
	return p, ok
}

// Register installs a provider session, replacing any prior session
// for the same provider_id. Returns (oldConn, registered):
//
//   - registered==true: session installed; oldConn is the displaced
//     connection (nil if no prior session existed) and the caller
//     SHOULD close it after the new ack frame is written.
//
//   - registered==false: registration was REFUSED. Caller MUST NOT
//     proceed and MUST close `conn` with CloseInvalidToken /
//     "invalid_token". This branch fires on three SPEC-003 v0.8.4 FR-C9.4
//     defense layers:
//
//     1. **Bearer-less duplicate rule (fix-pass-3):** an incoming
//     AuthBearerlessDuplicate is refused whenever a session already
//     exists for the same provider_id — no incoming bearer-less
//     connection may displace any other session.
//
//     2. **Proven-session protection (fix-pass-5):** an incoming
//     non-Bearer-validated session (AuthSelfMinted / AuthMintFailed /
//     empty) is refused whenever the existing session is a routing-
//     eligible AuthBearerValidated session. Without this rule, a
//     tokenless admission racing a proven session could register as
//     AuthSelfMinted, last-writer-wins evicting the victim's
//     validated session.
//     Bearer-validated incoming connects always succeed because
//     their proof-of-bearer is independently strong.
//
//     3. **Sandbox credential-bypass protection (SPEC-032 B5):** an
//     incoming strict hello-gate sandbox session that bypassed credential
//     proof is refused whenever the existing session is credential-bearing
//     (Bearer-validated, self-minted, or self-minted-verified).
//
// The DB partial unique index alone prevents the attacker from minting
// a parallel bearer, but does NOT prevent these pool-slot capture
// shapes. These checks close them at the registry layer.
func (r *Registry) Register(p *Provider, conn net.Conn) (old net.Conn, registered bool) {
	return r.RegisterAt(p, conn, time.Now().UTC())
}

// RegisterAt is Register with an injected coordinator clock for tests and
// server-level time control.
func (r *Registry) RegisterAt(p *Provider, conn net.Conn, now time.Time) (old net.Conn, registered bool) {
	old, registered, _ = r.RegisterAtDetailed(p, conn, now)
	return old, registered
}

type RegisterRefusal string

const (
	RegisterRefusalNone                       RegisterRefusal = ""
	RegisterRefusalBearerlessDuplicate        RegisterRefusal = "bearerless_duplicate"
	RegisterRefusalBearerDowngrade            RegisterRefusal = "bearer_downgrade"
	RegisterRefusalSandboxCredentialBypass    RegisterRefusal = "sandbox_credential_bypass"
	RegisterRefusalReceiptRotationGraceActive RegisterRefusal = "receipt_rotation_grace_active"
)

func (r *Registry) RegisterAtDetailed(p *Provider, conn net.Conn, now time.Time) (old net.Conn, registered bool, refusal RegisterRefusal) {
	r.mu.Lock()
	defer r.mu.Unlock()
	existing := r.providers[p.ProviderID]
	if existing != nil {
		// SPEC-003 v0.8.4 FR-C9.4 — refuse to evict ANY existing
		// session in favor of a bearer-less duplicate. This closes the
		// pool-slot capture vector from the PR #69 codex security audit
		// MAJOR-1. A legitimate reconnect after a NAT blip will find
		// the existing session already reaped (readProviderLoop
		// cleanup); only an attacker racing while the legitimate
		// provider is still in the pool would hit this branch.
		if p.AuthState == AuthBearerlessDuplicate {
			return nil, false, RegisterRefusalBearerlessDuplicate
		}
		// A strict hello-gate sandbox admitted without credential proof must
		// not replace a session that already proved or just minted credential
		// custody. This closes the mint-to-registration race where a tokenless
		// sandbox observes no active token, a concurrent admission mints one,
		// and the sandbox then evicts the self-minted session before the
		// cleartext token reaches the legitimate provider.
		if p.AdmissionSandboxCredentialBypassed && p.AuthState != AuthBearerValidated && providerCredentialBearing(existing.AuthState) {
			return nil, false, RegisterRefusalSandboxCredentialBypass
		}
		// Protect proven (Bearer-validated, routing-eligible) sessions
		// from non-Bearer-validated replacement. Without this check, a
		// tokenless admission could last-writer-wins evict the
		// legitimate Bearer-validated session. A legitimate provider
		// reconnect with a valid Bearer always wins because their
		// AuthState is AuthBearerValidated.
		if existing.AuthState == AuthBearerValidated &&
			existing.RoutingEligible() &&
			p.AuthState != AuthBearerValidated {
			return nil, false, RegisterRefusalBearerDowngrade
		}
		if r.stageReceiptPublicationLocked(existing, p, now) == RegisterRefusalReceiptRotationGraceActive {
			return nil, false, RegisterRefusalReceiptRotationGraceActive
		}
		old = existing.conn
		delete(r.sessions, existing.AssignedID)
		// M2-5: this is a session replacement (same provider_id, new
		// assigned_id). Drop the prior session's per-provider model-id
		// attribution so per-provider explorer / debug queries reflect
		// only the current session. RemoveIfSession{,State} only fire
		// on clean disconnect, not on this direct replacement path.
		// (Codex code-audit 2026-06-11 #47.)
		//
		// ISS-185: the obsolete pre-185 form of this comment said the
		// delete was required to keep `ModelKnown` from over-reporting.
		// That is no longer true: ModelKnown reads from
		// `seenModelsLifetime`, which is the SPEC-002 § 7.2 pool-
		// lifetime accumulator (append-only) and SHOULD retain
		// prior-session model ids so cold-start races route to 503
		// `no_provider_available` instead of 404 `model_not_found`.
		// The invariant this delete still preserves is per-provider
		// attribution only.
		delete(r.seenModelsByProvider, p.ProviderID)
	} else {
		if r.stageReceiptPublicationLocked(nil, p, now) == RegisterRefusalReceiptRotationGraceActive {
			return nil, false, RegisterRefusalReceiptRotationGraceActive
		}
	}
	p.conn = conn
	if p.Tier == "" {
		p.Tier = TierPinned
	}
	if p.InferencePath == "" {
		if p.EndpointURL != "" {
			p.InferencePath = InferencePathHTTPForwarding
		} else {
			p.InferencePath = InferencePathWSTunneled
		}
	}
	r.providers[p.ProviderID] = p
	r.sessions[p.AssignedID] = p
	// SPEC-010 v1.5 R-3.3.4: seed the seen-model index with the union of
	// the served model_id AND every declared supported_models entry.
	r.recordSeenModelsUnionLocked(p.ProviderID, p.ModelID, p.SupportedModels)
	delete(r.breakerFaults, p.ProviderID)
	delete(r.recoveryHolds, p.ProviderID)
	delete(r.lastBreakerRecoveries, p.ProviderID)
	r.applyCanarySanctionLocked(p)
	return old, true, RegisterRefusalNone
}

func providerCredentialBearing(auth AuthState) bool {
	switch auth {
	case AuthBearerValidated, AuthSelfMinted, AuthSelfMintedVerified:
		return true
	default:
		return false
	}
}

func (r *Registry) stageReceiptPublicationLocked(existing, incoming *Provider, now time.Time) RegisterRefusal {
	now = now.UTC()
	incomingKey := cloneBytes(incoming.ReceiptPubkey)
	incomingPrev := activeReceiptPubkeyPrev(incoming, now)
	incoming.ReceiptPubkey = nil
	incoming.PendingReceiptPubkey = nil
	incoming.ReceiptPubkeyPrev = nil
	if existing == nil {
		if incomingPrev != nil {
			incoming.ReceiptPubkey = cloneBytes(incomingKey)
			incoming.ReceiptPubkeyPrev = cloneReceiptPubkeyPrevious(incomingPrev)
			return RegisterRefusalNone
		}
		incoming.PendingReceiptPubkey = cloneBytes(incomingKey)
		return RegisterRefusalNone
	}
	activePrev := activeReceiptPubkeyPrev(existing, now)
	if len(incomingKey) == 0 {
		return RegisterRefusalNone
	}
	if len(existing.ReceiptPubkey) == 0 {
		if len(existing.PendingReceiptPubkey) > 0 {
			if bytes.Equal(existing.PendingReceiptPubkey, incomingKey) {
				incoming.PendingReceiptPubkey = cloneBytes(existing.PendingReceiptPubkey)
				return RegisterRefusalNone
			}
			return RegisterRefusalReceiptRotationGraceActive
		}
		incoming.PendingReceiptPubkey = cloneBytes(incomingKey)
		return RegisterRefusalNone
	}
	if bytes.Equal(existing.ReceiptPubkey, incomingKey) {
		incoming.ReceiptPubkey = cloneBytes(existing.ReceiptPubkey)
		incoming.ReceiptPubkeyPrev = cloneReceiptPubkeyPrevious(activePrev)
		return RegisterRefusalNone
	}
	if len(existing.PendingReceiptPubkey) > 0 {
		if bytes.Equal(existing.PendingReceiptPubkey, incomingKey) {
			incoming.ReceiptPubkey = cloneBytes(existing.ReceiptPubkey)
			incoming.ReceiptPubkeyPrev = cloneReceiptPubkeyPrevious(activePrev)
			incoming.PendingReceiptPubkey = cloneBytes(existing.PendingReceiptPubkey)
			return RegisterRefusalNone
		}
		return RegisterRefusalReceiptRotationGraceActive
	}
	if activePrev != nil {
		return RegisterRefusalReceiptRotationGraceActive
	}
	incoming.PendingReceiptPubkey = cloneBytes(incomingKey)
	incoming.ReceiptPubkey = cloneBytes(existing.ReceiptPubkey)
	return RegisterRefusalNone
}

func activeReceiptPubkeyPrev(p *Provider, now time.Time) *ReceiptPubkeyPrevious {
	if p == nil || p.ReceiptPubkeyPrev == nil || !now.Before(p.ReceiptPubkeyPrev.ExpiresAt) {
		return nil
	}
	return p.ReceiptPubkeyPrev
}

func (r *Registry) commitPendingReceiptPubkeyLocked(p *Provider, now time.Time) *ReceiptRotationEvent {
	now = now.UTC()
	if p.ReceiptPubkeyPrev != nil && !now.Before(p.ReceiptPubkeyPrev.ExpiresAt) {
		p.ReceiptPubkeyPrev = nil
	}
	if len(p.PendingReceiptPubkey) == 0 {
		return nil
	}
	var event *ReceiptRotationEvent
	if len(p.ReceiptPubkey) > 0 && !bytes.Equal(p.ReceiptPubkey, p.PendingReceiptPubkey) {
		oldPubkey := cloneBytes(p.ReceiptPubkey)
		newPubkey := cloneBytes(p.PendingReceiptPubkey)
		p.ReceiptPubkeyPrev = &ReceiptPubkeyPrevious{
			Pubkey:    oldPubkey,
			RotatedAt: now,
			ExpiresAt: now.Add(ReceiptRotationGrace),
		}
		event = &ReceiptRotationEvent{
			ProviderID: p.ProviderID,
			OldPubkey:  cloneBytes(oldPubkey),
			NewPubkey:  newPubkey,
			RotatedAt:  now,
		}
	}
	p.ReceiptPubkey = cloneBytes(p.PendingReceiptPubkey)
	p.PendingReceiptPubkey = nil
	return event
}

func cloneReceiptPubkeyPrevious(prev *ReceiptPubkeyPrevious) *ReceiptPubkeyPrevious {
	if prev == nil {
		return nil
	}
	return &ReceiptPubkeyPrevious{
		Pubkey:    cloneBytes(prev.Pubkey),
		RotatedAt: prev.RotatedAt,
		ExpiresAt: prev.ExpiresAt,
	}
}

func cloneBytes(in []byte) []byte {
	if len(in) == 0 {
		return nil
	}
	out := make([]byte, len(in))
	copy(out, in)
	return out
}

// recordSeenModelLocked records a model id under a provider's set
// AND in the pool-lifetime accumulator. Caller must hold r.mu in
// WRITE mode.
//
// The two maps are gated INDEPENDENTLY (ISS-185 R2 architect/code/
// security-lane MAJORs):
//
//   - seenModelsByProvider[provider_id] holds the current session's
//     attribution, capped per session at maxSeenModelsPerProvider
//     and cleared on RemoveIfSession / session-replacement.
//   - seenModelsLifetime is the SPEC-002 § 7.2 pool-lifetime model
//     history, capped overall at maxSeenModelsLifetime and per-
//     provider at maxLifetimeContribPerProvider (the latter counter
//     SURVIVES disconnect/session-replacement, so churn-via-
//     reconnect cannot consume more lifetime than that per-provider
//     budget).
//
// seenModelsLifetime keys are the lowercase canonical form of the
// model id; ModelKnown's lookup is then O(1).
func (r *Registry) recordSeenModelLocked(providerID, modelID string) {
	if providerID == "" || modelID == "" {
		return
	}
	// ISS-185 R1 security-lane CRITICAL: bound the persisted byte
	// size. `requireString` in internal/ws/messages.go does not cap
	// model_id length.
	if len(modelID) > maxModelIDByteLen {
		return
	}

	// 1. Per-session attribution map (M2-5 / audit #47 invariant).
	set, ok := r.seenModelsByProvider[providerID]
	if !ok {
		set = map[string]struct{}{}
		r.seenModelsByProvider[providerID] = set
	}
	if _, already := set[modelID]; !already && len(set) < maxSeenModelsPerProvider {
		set[modelID] = struct{}{}
	}

	// 2. Pool-lifetime accumulator (SPEC-002 § 7.2).
	canonical := strings.ToLower(modelID)
	if _, already := r.seenModelsLifetime[canonical]; already {
		return
	}
	// 2a. Per-provider lifetime contribution budget (survives
	// disconnect/replacement so reconnects can't fill the cap).
	if r.lifetimeContribByProvider[providerID] >= maxLifetimeContribPerProvider {
		r.lifetimeCapDroppedCount++
		return
	}
	// 2b. Global lifetime cap (PERF-5 bound).
	if len(r.seenModelsLifetime) >= maxSeenModelsLifetime {
		r.lifetimeCapDroppedCount++
		if !r.lifetimeCapWarnedOnce {
			r.lifetimeCapWarnedOnce = true
			slog.Warn("pool: seenModelsLifetime cap reached; further model_ids will be silently dropped, degrading SPEC-002 § 7.2 cold-start race recovery to legacy 404 for the dropped ids",
				"cap", maxSeenModelsLifetime,
				"provider_id", providerID,
				"dropped_model_id", modelID,
			)
		}
		return
	}
	r.seenModelsLifetime[canonical] = struct{}{}
	r.lifetimeContribByProvider[providerID]++
}

// recordSeenModelsUnionLocked records the SPEC-010 v1.5 R-3.3.4 union of
// the currently-served modelID and every entry the provider declared in
// supportedModels into the seen-model indexes. It makes ModelKnown()
// return true for a model that some provider DECLARES supporting but is
// not currently serving (cold), so a buyer request for such a model falls
// through to the existing 503 no_provider_available (transient/retryable)
// path instead of 404 model_not_found (see buyer/server.go's ModelKnown
// gate).
//
// Each entry flows through recordSeenModelLocked, so:
//   - supported-model entries share EXACTLY the same normalization
//     (strings.ToLower canonical key for the lifetime accumulator, raw
//     id for the per-session attribution set) as the served model_id;
//   - they share the same lifecycle: dropped from seenModelsByProvider
//     on disconnect / session-replacement (M2-5 / PERF-5), and retained
//     append-only in seenModelsLifetime for the coordinator process
//     lifetime (SPEC-002 § 7.2 cold-start-race survival). No separate
//     removal path is introduced — a declared-cold model ages exactly as
//     the served model_id does.
//
// Per R-3.1.5 a legacy provider carries supportedModels == [modelID]
// (synthesized in ws/server.go), so the union collapses to {modelID} and
// this is byte-identical to pre-SPEC-010 for any provider that did not
// declare models beyond its served one (R-4.1 / R-3.5.1 guarantee).
func (r *Registry) recordSeenModelsUnionLocked(providerID, modelID string, supportedModels []string) {
	r.recordSeenModelLocked(providerID, modelID)
	for _, supported := range supportedModels {
		r.recordSeenModelLocked(providerID, supported)
	}
}

// LifetimeCapStats returns the current size of the pool-lifetime
// model-id accumulator and the cumulative number of model_id
// inserts dropped because either the global or per-provider lifetime
// cap was at the limit. Operators can scrape these via explorer /
// metrics surfaces — nonzero `dropped` is the security-relevant
// signal of either runaway provider churn or a catalog larger than
// the configured budget. ISS-185 R2 code/security-lane MINOR
// (observability).
func (r *Registry) LifetimeCapStats() (size int, dropped uint64) {
	r.mu.RLock()
	defer r.mu.RUnlock()
	return len(r.seenModelsLifetime), r.lifetimeCapDroppedCount
}

func (r *Registry) SetTier(providerID string, tier Tier) (Provider, bool) {
	r.mu.Lock()
	defer r.mu.Unlock()
	p := r.providers[providerID]
	if p == nil {
		return Provider{}, false
	}
	p.Tier = tier
	cp := *p
	cp.conn = nil
	return cp, true
}

func (r *Registry) UpdateHashStatuses(statusFor func(Provider) HashStatus) int {
	r.mu.Lock()
	defer r.mu.Unlock()
	updated := 0
	for _, p := range r.providers {
		cp := *p
		cp.conn = nil
		next := statusFor(cp)
		if p.HashStatus != next {
			updated++
		}
		p.HashStatus = next
	}
	return updated
}

// ExpireLegacyBridgeAdmissions atomically removes every metadata-free bridge
// session from buyer routing/capacity without disconnecting it from operator
// visibility. The WS server calls this at the configured absolute deadline.
func (r *Registry) ExpireLegacyBridgeAdmissions() int {
	r.mu.Lock()
	defer r.mu.Unlock()
	updated := 0
	for _, p := range r.providers {
		if p.CatalogAdmissionMode == "legacy_bridge" {
			p.CatalogAdmissionMode = "legacy"
			updated++
		}
	}
	return updated
}

// ExpireLegacyModelHashAdmissions atomically fences every connected session
// that still lacks the named canonical model-identity algorithm. The caller
// closes the returned sessions after routing is already disabled.
func (r *Registry) ExpireLegacyModelHashAdmissions() []Provider {
	r.mu.Lock()
	defer r.mu.Unlock()
	var expired []Provider
	for _, p := range r.providers {
		if strings.TrimSpace(p.ModelHashAlgorithm) != "" {
			continue
		}
		cp := *p
		cp.conn = nil
		expired = append(expired, cp)
		p.HashStatus = HashStatusInvalid
	}
	return expired
}

func (r *Registry) MarkHashStatusIfSession(providerID, assignedID string, status HashStatus) bool {
	r.mu.Lock()
	defer r.mu.Unlock()
	p := r.providers[providerID]
	if p == nil || p.AssignedID != assignedID {
		return false
	}
	p.HashStatus = status
	return true
}

func (r *Registry) MarkHTTPForwardingOnly(providerID, assignedID string) bool {
	r.mu.Lock()
	defer r.mu.Unlock()
	p := r.providers[providerID]
	if p == nil || p.AssignedID != assignedID {
		return false
	}
	p.HTTPForwardingOnly = true
	return true
}

func (r *Registry) MarkState(providerID, assignedID string, state State) bool {
	r.mu.Lock()
	defer r.mu.Unlock()
	p := r.providers[providerID]
	if p == nil || p.AssignedID != assignedID {
		return false
	}
	if !r.canSetCoordinatorStateLocked(p, state) {
		return false
	}
	r.setStateLocked(p, state)
	return true
}

func (r *Registry) MarkDegradedForRecovery(providerID, assignedID string, reason RecoveryReason) bool {
	r.mu.Lock()
	defer r.mu.Unlock()
	p := r.providers[providerID]
	if p == nil || p.AssignedID != assignedID {
		return false
	}
	if hold, held := r.recoveryHolds[providerID]; held && hold.assignedID == assignedID && hold.reason == RecoveryReasonCanary {
		return false
	}
	r.setStateLocked(p, StateDegraded)
	r.recoveryHolds[providerID] = recoveryHold{assignedID: assignedID, reason: reason}
	return true
}

func (r *Registry) MarkRecovered(providerID, assignedID string, at time.Time) bool {
	if at.IsZero() {
		at = time.Now().UTC()
	}
	r.mu.Lock()
	defer r.mu.Unlock()
	p := r.providers[providerID]
	if p == nil || p.AssignedID != assignedID {
		return false
	}
	hold, held := r.recoveryHolds[providerID]
	if !held || hold.assignedID != assignedID {
		return false
	}
	if hold.reason == RecoveryReasonCanary {
		return false
	}
	r.setStateLocked(p, StateReady)
	delete(r.breakerFaults, providerID)
	delete(r.recoveryHolds, providerID)
	if hold.reason == RecoveryReasonBreaker {
		r.lastBreakerRecoveries[providerID] = at
	}
	return true
}

func (r *Registry) CanaryRecoveryEligible(providerID, assignedID string) bool {
	r.mu.RLock()
	defer r.mu.RUnlock()
	hold, held := r.recoveryHolds[providerID]
	return held && hold.assignedID == assignedID && hold.reason == RecoveryReasonCanary
}

type BreakerTripState string

const (
	BreakerTripNone        BreakerTripState = ""
	BreakerTripDegraded    BreakerTripState = "degraded"
	BreakerTripUnavailable BreakerTripState = "unavailable"
)

type BreakerFaultResult struct {
	Count     int
	Threshold int
	Tripped   BreakerTripState
}

type CanaryTripState string

const (
	CanaryTripNone        CanaryTripState = ""
	CanaryTripDegraded    CanaryTripState = "degraded"
	CanaryTripUnavailable CanaryTripState = "unavailable"
	// CanaryTripFloorHeld means the provider reached the failure threshold but was
	// spared because it is the sole buyer-serving provider for its model
	// (SPEC-031 FR-CAN22 last-provider floor). It stays routable and keeps
	// accruing CanaryFailCount; the caller MUST emit an operator alert.
	CanaryTripFloorHeld CanaryTripState = "floor_held"
)

type CanaryResult struct {
	Current         bool
	Passed          bool
	Count           int
	Threshold       int
	Tier            Tier
	Tripped         CanaryTripState
	SanctionCleared bool
}

func (r *Registry) RecordCanaryResult(providerID, assignedID string, passed bool, at time.Time, threshold int) CanaryResult {
	return r.recordCanaryResult(providerID, assignedID, passed, at, threshold, false)
}

// RecordCanaryResultForceFloorHeld accrues a canary failure (or pass) like
// RecordCanaryResult, but when the failure reaches threshold it ALWAYS returns
// CanaryTripFloorHeld without degrading/banning — used by FR-CAN23 when
// canarycorr residual says no observed-serving peer capacity remains even if
// request-independent BuyerServing peers would lift the FR-CAN22 floor.
func (r *Registry) RecordCanaryResultForceFloorHeld(providerID, assignedID string, passed bool, at time.Time, threshold int) CanaryResult {
	return r.recordCanaryResult(providerID, assignedID, passed, at, threshold, true)
}

func (r *Registry) recordCanaryResult(providerID, assignedID string, passed bool, at time.Time, threshold int, forceFloorHeld bool) CanaryResult {
	if threshold <= 0 {
		threshold = 3
	}
	if at.IsZero() {
		at = time.Now().UTC()
	}
	r.mu.Lock()
	defer r.mu.Unlock()
	p := r.providers[providerID]
	if p == nil || p.AssignedID != assignedID {
		return CanaryResult{Threshold: threshold}
	}
	if p.State == StateDraining || p.State == StateUnavailable {
		return CanaryResult{Current: true, Passed: passed, Threshold: threshold, Tier: p.Tier}
	}
	if hold, held := r.recoveryHolds[providerID]; held && hold.assignedID == assignedID && hold.reason == RecoveryReasonCanary && p.State != StateDegraded {
		return CanaryResult{Current: true, Passed: passed, Threshold: threshold, Tier: p.Tier}
	}
	checkedAt := at
	p.CanaryLastCheckedAt = &checkedAt
	result := CanaryResult{
		Current:   true,
		Passed:    passed,
		Threshold: threshold,
		Tier:      p.Tier,
	}
	if passed {
		p.CanaryFailCount = 0
		if _, held := r.canarySanctions[providerID]; held {
			result.SanctionCleared = true
		}
		delete(r.canarySanctions, providerID)
		if hold, held := r.recoveryHolds[providerID]; held && hold.assignedID == assignedID && hold.reason == RecoveryReasonCanary {
			result.SanctionCleared = true
			delete(r.recoveryHolds, providerID)
			r.setStateLocked(p, StateReady)
		}
		result.Count = 0
		return result
	}
	p.CanaryFailCount++
	failedAt := at
	p.CanaryLastFailedAt = &failedAt
	result.Count = p.CanaryFailCount
	if result.Count < threshold {
		return result
	}
	// FR-CAN22 (SPEC-031 §10) last-provider floor: a canary-only signal MUST NOT
	// remove the sole buyer-serving provider for a model. A canary probe is a
	// fingerprintable synthetic request, so a failed echo does not prove ordinary
	// buyer traffic is failing; removing the last provider on it is the
	// self-inflicted total outage of incidents #1/#2 (2026-07-09/10). The provider
	// keeps accruing CanaryFailCount and stays routable; the caller emits an
	// operator alert (CanaryTripFloorHeld). Removing a sole provider requires
	// evidence independent of the canary — the FR-P11a buyer-path breaker, a
	// confirmed transport death, or item-9 weight evidence — none of which flow
	// through this canary path. Applies to both tiers (provisional ban and pinned
	// degrade), since it precedes the tier branch. "Sole" is keyed on the ACTIVE
	// buyer-routing model (providerServesActiveModel, not declared SupportedModels)
	// AND the injected request-independent buyer-serving predicate (RoutingEligible
	// + transport + context + not Tier-2-excluded); request-dependent context/quota
	// residual is closed by FR-CAN23 forceFloorHeld when no observed-serving peer
	// capacity remains (ghost BuyerServing peers must not lift the floor).
	if forceFloorHeld || (r.isBuyerServingLocked(p) && !r.hasOtherBuyerServingForModelLocked(providerID, p.ModelID)) {
		result.Tripped = CanaryTripFloorHeld
		return result
	}
	if p.Tier == TierProvisional {
		r.setStateLocked(p, StateUnavailable)
		result.Tripped = CanaryTripUnavailable
		return result
	}
	r.setStateLocked(p, StateDegraded)
	r.recoveryHolds[providerID] = recoveryHold{assignedID: assignedID, reason: RecoveryReasonCanary}
	r.canarySanctions[providerID] = canarySanction{
		failCount:     p.CanaryFailCount,
		lastCheckedAt: p.CanaryLastCheckedAt,
		lastFailedAt:  p.CanaryLastFailedAt,
	}
	result.Tripped = CanaryTripDegraded
	return result
}

// providerServesActiveModel reports whether p's ACTIVE loaded model is modelID
// under exact case-folded identity. Unlike buyer routing's modelIDEqual
// (billing.ModelsEquivalent after #900), this stays EqualFold-only: canary
// sole-provider floor and redundancy telemetry compare provider-to-provider
// served ModelIDs (HF form), and deliberately treat quantization / catalog
// aliases as distinct so the floor stays conservative. It does NOT consult
// `SupportedModels`: a declared-but-cold model is buyer-unroutable (SPEC-031 §9 /
// SPEC-010 R-3.3.4 — "known but temporarily unavailable", it 503s), so counting
// it as live capacity would let a peer serving a different model falsely lift the
// last-provider floor and empty the model's real pool. Pure; no locking. Model
// classes are not resolved here (the registry has no class config), so for a
// class-routed model the floor is conservatively over-protective (a same-class
// peer with a different ModelID is not counted) — the safe direction.
func providerServesActiveModel(p *Provider, modelID string) bool {
	return p != nil && strings.EqualFold(p.ModelID, modelID)
}

// SetBuyerServingPredicate injects the request-independent buyer-serving predicate
// (RoutingEligible + transport-reachable [live open WS session, else endpoint] +
// positive context window + not Tier-2-excluded; request-dependent context/quota
// omitted) used by the FR-CAN22 floor and the redundancy count. The ws layer wires
// this at construction; nil restores the RoutingEligible+context fallback (which
// omits the ws-only transport/Tier-2 gates). It never mutates
// routing/admission — the predicate
// is read-only w.r.t. the sanction decision.
func (r *Registry) SetBuyerServingPredicate(fn func(Provider) bool) {
	r.mu.Lock()
	defer r.mu.Unlock()
	r.buyerServing = fn
}

// isBuyerServingLocked applies the injected buyer-serving predicate, or a
// routability-based fallback, to p. Caller MUST hold r.mu (read or write). The
// fallback (used only when no ws predicate is injected — i.e. registry unit tests)
// mirrors the request-independent core of `canaryBuyerServing`: RoutingEligible (ready +
// free slots) AND a positive context window, so a busy, degraded, negative-slot,
// zero-free-slot, or zero-context peer never lifts the floor. It omits the transport + Tier-2
// gate, which requires ws config the pool package cannot see.
func (r *Registry) isBuyerServingLocked(p *Provider) bool {
	if r.buyerServing != nil {
		return r.buyerServing(*p)
	}
	return p.RoutingEligible() && p.MaxContextTokens > 0
}

// hasOtherBuyerServingForModelLocked reports whether some provider other than
// excludeID is buyer-serving and actively serves modelID. Caller MUST hold r.mu.
// Backs the FR-CAN22 last-provider floor in RecordCanaryResult: when this returns
// false, callers must still verify the excluded provider is itself buyer-serving
// before treating it as the sole buyer-serving provider for the model. Uses the
// injected request-independent predicate (RoutingEligible + positive context +
// not Tier-2-excluded) so a
// busy, degraded, negative-slot, transport-unreachable, or Tier-2-excluded peer
// does not falsely lift the floor (transport + Tier-2 are ws-only gates).
func (r *Registry) hasOtherBuyerServingForModelLocked(excludeID, modelID string) bool {
	for id, p := range r.providers {
		if id == excludeID {
			continue
		}
		if providerServesActiveModel(p, modelID) && r.isBuyerServingLocked(p) {
			return true
		}
	}
	return false
}

// BuyerServingCountForModel returns the number of buyer-serving providers actively
// serving modelID. Backs the redundancy telemetry on the hello-gate rejection and
// canary floor-held paths (below-two operator visibility); it never affects
// admission or routing. This is a raw structural count, NOT the full SPEC-032
// FR-HG5 below-two alert (which additionally requires catalogued-demand filtering +
// episode dedup/cooldown across all gate actions — still a Gap).
func (r *Registry) BuyerServingCountForModel(modelID string) int {
	r.mu.RLock()
	defer r.mu.RUnlock()
	n := 0
	for _, p := range r.providers {
		if providerServesActiveModel(p, modelID) && r.isBuyerServingLocked(p) {
			n++
		}
	}
	return n
}

// BuyerServingProviderIDsForModel returns the provider IDs that currently pass
// the injected buyer-serving predicate for modelID. Used to freeze FR-CAN23
// pre-sweep snapshots. Order is not stable.
func (r *Registry) BuyerServingProviderIDsForModel(modelID string) []string {
	r.mu.RLock()
	defer r.mu.RUnlock()
	ids := make([]string, 0)
	for id, p := range r.providers {
		if providerServesActiveModel(p, modelID) && r.isBuyerServingLocked(p) {
			ids = append(ids, id)
		}
	}
	return ids
}

// NoteBuyerSuccess records a coordinator-observed successful buyer relay for
// FR-CAN23 observed-serving residual. No-op when the provider is unknown.
func (r *Registry) NoteBuyerSuccess(providerID string, at time.Time) {
	if r == nil || strings.TrimSpace(providerID) == "" {
		return
	}
	if at.IsZero() {
		at = time.Now().UTC()
	} else {
		at = at.UTC()
	}
	r.mu.Lock()
	defer r.mu.Unlock()
	p := r.providers[providerID]
	if p == nil {
		return
	}
	t := at
	p.LastBuyerSuccessAt = &t
}

// LastBuyerSuccessAt returns a copy of the provider's last buyer-success stamp.
func (r *Registry) LastBuyerSuccessAt(providerID string) time.Time {
	if r == nil {
		return time.Time{}
	}
	r.mu.RLock()
	defer r.mu.RUnlock()
	p := r.providers[providerID]
	if p == nil || p.LastBuyerSuccessAt == nil {
		return time.Time{}
	}
	return *p.LastBuyerSuccessAt
}

// SELivenessResult is returned by RecordSELivenessResult.
type SELivenessResult struct {
	// Current is false when the provider session no longer exists in the registry.
	Current bool
	Passed  bool
	// FailCount is the consecutive failure count after this result.
	FailCount int
	// Stale is true when FailCount reached maxFailures and AttestationStatus was set to stale.
	Stale bool
}

// RecordSELivenessResult records a SE liveness challenge outcome and updates
// the provider's SELivenessFailCount and AttestationStatus.
// On pass: resets fail count, updates LastSELivenessAt.
// On fail: increments fail count; at maxFailures sets AttestationStatusStale.
func (r *Registry) RecordSELivenessResult(providerID, assignedID string, passed bool, at time.Time, maxFailures int) SELivenessResult {
	if maxFailures <= 0 {
		maxFailures = 3
	}
	if at.IsZero() {
		at = time.Now().UTC()
	}
	r.mu.Lock()
	defer r.mu.Unlock()
	p := r.providers[providerID]
	if p == nil || p.AssignedID != assignedID {
		return SELivenessResult{}
	}
	result := SELivenessResult{Current: true, Passed: passed}
	if passed {
		p.SELivenessFailCount = 0
		ts := at
		p.LastSELivenessAt = &ts
		return result
	}
	p.SELivenessFailCount++
	result.FailCount = p.SELivenessFailCount
	if p.SELivenessFailCount >= maxFailures {
		p.AttestationStatus = AttestationStatusStale
		result.Stale = true
	}
	return result
}

// SetSEPublicKey stores the SE public key and attestation tier on a live provider
// session. Called by P1-B coordinator verifier after a successful
// macprovider-se-p256-v1 attestation verification.
func (r *Registry) SetSEPublicKey(providerID, assignedID string, pubkey []byte, tier string) bool {
	r.mu.Lock()
	defer r.mu.Unlock()
	p := r.providers[providerID]
	if p == nil || p.AssignedID != assignedID {
		return false
	}
	p.SEPublicKey = append([]byte(nil), pubkey...)
	p.AttestationTier = tier
	return true
}

func (r *Registry) SetModelClassOPoIPass(providerID, assignedID string, pass *bool) {
	r.mu.Lock()
	defer r.mu.Unlock()
	p := r.providers[providerID]
	if p == nil || p.AssignedID != assignedID {
		return
	}
	p.ModelClassOPoIPass = pass
}

// RecordCanaryLatency stores the wall-time metrics of a completed canary probe
// so /poolz can segment live TTFT/TPS by binary_version. Non-positive values
// are ignored (a skipped or transport-failed probe measured nothing), which
// keeps the last real observation rather than zeroing it.
func (r *Registry) RecordCanaryLatency(providerID, assignedID string, ttftMS int, sustainedTPS float64) {
	if ttftMS <= 0 {
		return
	}
	r.mu.Lock()
	defer r.mu.Unlock()
	p := r.providers[providerID]
	if p == nil || p.AssignedID != assignedID {
		return
	}
	p.CanaryLastTTFTMS = ttftMS
	if sustainedTPS > 0 && !math.IsNaN(sustainedTPS) && !math.IsInf(sustainedTPS, 0) {
		p.CanaryLastSustainedTPS = sustainedTPS
	}
}

// SetBenchmarkQuarantine flips the issue-#765 fail-suspect bucket for a live
// session. Returns true when the flag CHANGED, so the caller can log the
// transition once instead of on every heartbeat.
func (r *Registry) SetBenchmarkQuarantine(providerID, assignedID string, quarantined bool) bool {
	r.mu.Lock()
	defer r.mu.Unlock()
	p := r.providers[providerID]
	if p == nil || p.AssignedID != assignedID {
		return false
	}
	if p.BenchmarkQuarantined == quarantined {
		return false
	}
	p.BenchmarkQuarantined = quarantined
	return true
}

// SetAdmissionCeilingExcluded flips the SPEC-032 FR-HG7 route-exclusion bucket
// for a live session. Returns true only when the flag changed so callers can log
// the transition once while still revalidating on every heartbeat/sweep.
func (r *Registry) SetAdmissionCeilingExcluded(providerID, assignedID string, excluded bool) bool {
	r.mu.Lock()
	defer r.mu.Unlock()
	p := r.providers[providerID]
	if p == nil || p.AssignedID != assignedID {
		return false
	}
	if p.AdmissionCeilingExcluded == excluded {
		return false
	}
	p.AdmissionCeilingExcluded = excluded
	return true
}

// SetAdmissionEvidenceStale flips the session-time autotune evidence TTL gate
// for a live session. Returns true only when the flag changed.
func (r *Registry) SetAdmissionEvidenceStale(providerID, assignedID string, stale bool) bool {
	r.mu.Lock()
	defer r.mu.Unlock()
	p := r.providers[providerID]
	if p == nil || p.AssignedID != assignedID {
		return false
	}
	if p.AdmissionEvidenceStale == stale {
		return false
	}
	p.AdmissionEvidenceStale = stale
	return true
}

// SetAdmissionSandboxed flips the strict hello-gate sandbox bucket for a live
// session. Returns true only when the flag changed.
func (r *Registry) SetAdmissionSandboxed(providerID, assignedID string, sandboxed bool) bool {
	r.mu.Lock()
	defer r.mu.Unlock()
	p := r.providers[providerID]
	if p == nil || p.AssignedID != assignedID {
		return false
	}
	if p.AdmissionSandboxed == sandboxed {
		return false
	}
	p.AdmissionSandboxed = sandboxed
	if !sandboxed {
		p.AdmissionSandboxCredentialBypassed = false
	}
	return true
}

// SetAdmissionGateFlags atomically publishes every proof-of-weights route
// exclusion flag for one live session. It prevents routing from observing an
// intermediate all-clear state while a strict-gate revalidation moves a
// provider between stale, sandboxed, and ceiling-excluded states.
func (r *Registry) SetAdmissionGateFlags(providerID, assignedID string, flags AdmissionGateFlags) (AdmissionGateFlags, bool, bool) {
	r.mu.Lock()
	defer r.mu.Unlock()
	p := r.providers[providerID]
	if p == nil || p.AssignedID != assignedID {
		return AdmissionGateFlags{}, false, false
	}
	prior := AdmissionGateFlags{
		AdmissionCeilingExcluded: p.AdmissionCeilingExcluded,
		AdmissionEvidenceStale:   p.AdmissionEvidenceStale,
		AdmissionSandboxed:       p.AdmissionSandboxed,
	}
	changed := prior != flags
	p.AdmissionCeilingExcluded = flags.AdmissionCeilingExcluded
	p.AdmissionEvidenceStale = flags.AdmissionEvidenceStale
	p.AdmissionSandboxed = flags.AdmissionSandboxed
	if !flags.AdmissionSandboxed {
		p.AdmissionSandboxCredentialBypassed = false
	}
	return prior, changed, true
}

// QuarantineForProofOfWeightsReload marks every live session fail-closed before
// a proof_of_weights hot reload is published. The post-publish revalidation pass
// clears sessions that prove under the new generation.
func (r *Registry) QuarantineForProofOfWeightsReload() int {
	r.mu.Lock()
	defer r.mu.Unlock()
	updated := 0
	for _, p := range r.providers {
		if !p.AdmissionEvidenceStale {
			p.AdmissionEvidenceStale = true
			updated++
		}
	}
	return updated
}

// ClearBenchmarkQuarantines clears telemetry-drift benchmark quarantines when
// that enforcement surface is disabled or reloaded into observe-only mode.
func (r *Registry) ClearBenchmarkQuarantines() int {
	r.mu.Lock()
	defer r.mu.Unlock()
	updated := 0
	for _, p := range r.providers {
		if p.BenchmarkQuarantined {
			p.BenchmarkQuarantined = false
			updated++
		}
	}
	return updated
}

func (r *Registry) applyCanarySanctionLocked(p *Provider) {
	sanction, ok := r.canarySanctions[p.ProviderID]
	if !ok || p.Tier != TierPinned {
		return
	}
	p.CanaryFailCount = sanction.failCount
	p.CanaryLastCheckedAt = sanction.lastCheckedAt
	p.CanaryLastFailedAt = sanction.lastFailedAt
	r.setStateLocked(p, StateDegraded)
	r.recoveryHolds[p.ProviderID] = recoveryHold{assignedID: p.AssignedID, reason: RecoveryReasonCanary}
}

func (r *Registry) RecordBreakerFault(providerID, assignedID string, at time.Time, threshold int, window time.Duration) BreakerFaultResult {
	if threshold <= 0 {
		threshold = 2
	}
	if window <= 0 {
		window = 120 * time.Second
	}
	if at.IsZero() {
		at = time.Now().UTC()
	}
	r.mu.Lock()
	defer r.mu.Unlock()
	p := r.providers[providerID]
	if p == nil || p.AssignedID != assignedID {
		return BreakerFaultResult{Threshold: threshold}
	}
	if p.State != StateReady && p.State != StateBusy {
		return BreakerFaultResult{Threshold: threshold}
	}
	cutoff := at.Add(-window)
	faults := r.breakerFaults[providerID]
	kept := faults[:0]
	for _, faultAt := range faults {
		if !faultAt.Before(cutoff) {
			kept = append(kept, faultAt)
		}
	}
	kept = append(kept, at)
	r.breakerFaults[providerID] = kept
	result := BreakerFaultResult{Count: len(kept), Threshold: threshold}
	if result.Count < threshold {
		return result
	}
	if recoveredAt := r.lastBreakerRecoveries[providerID]; !recoveredAt.IsZero() && at.Sub(recoveredAt) <= window {
		r.setStateLocked(p, StateUnavailable)
		result.Tripped = BreakerTripUnavailable
		return result
	}
	r.setStateLocked(p, StateDegraded)
	r.recoveryHolds[providerID] = recoveryHold{assignedID: assignedID, reason: RecoveryReasonBreaker}
	result.Tripped = BreakerTripDegraded
	return result
}

// canSetCoordinatorStateLocked guards COORDINATOR-initiated state changes
// (admin drain/blacklist, warm-up, recovery). It is deliberately more
// permissive than canApplyProviderStateLocked: the coordinator is trusted to
// drain a held provider (the provider is then leaving the pool), so only the
// `ready` promotion is gated by an active hold. Keep these two guards separate
// — the provider-path one must stay strict (see canApplyProviderStateLocked).
func (r *Registry) canSetCoordinatorStateLocked(p *Provider, next State) bool {
	if next != StateReady {
		return true
	}
	if hold, ok := r.recoveryHolds[p.ProviderID]; ok && hold.assignedID == p.AssignedID {
		return false
	}
	return p.State != StateUnavailable
}

// canApplyProviderStateLocked guards PROVIDER-originated state changes
// (heartbeat status + state_update). It is intentionally STRICTER than the
// coordinator-path guard (canSetCoordinatorStateLocked): while a
// coordinator-owned recovery/breaker hold is live for this session, the
// provider's own telemetry may ONLY re-affirm `degraded`. It must not be able
// to launder itself back to routable by self-reporting an intermediate state.
// Specifically, without this a faulting, breaker-held provider could escape
// degradation by reporting `draining` and then `ready`. A hold is cleared only
// by a fresh session (Register), a coordinator recovery (MarkRecovered), or the
// provider becoming terminally `unavailable` / removed — never by a reversible
// provider-reported transition such as `draining`. (drain_status routes through
// the coordinator MarkState path; applyStateCleanupLocked no longer clears a
// hold on `draining`, so that vector is closed at the cleanup boundary too.)
func (r *Registry) canApplyProviderStateLocked(p *Provider, next State) bool {
	if hold, ok := r.recoveryHolds[p.ProviderID]; ok && hold.assignedID == p.AssignedID {
		return next == StateDegraded
	}
	if next != StateReady {
		return true
	}
	return p.State != StateUnavailable
}

func (r *Registry) setStateLocked(p *Provider, next State) {
	p.State = next
	r.applyStateCleanupLocked(p.ProviderID, next)
}

func (r *Registry) applyStateCleanupLocked(providerID string, next State) {
	// Only a TERMINAL transition clears a coordinator-owned breaker/recovery
	// hold. `draining` is deliberately NOT included: it is reversible and
	// reachable from provider-controlled messages (state_update, heartbeat, and
	// — via the coordinator path — drain_status), so clearing a hold on
	// `draining` would let a faulting, held provider launder itself back to
	// routable (draining clears the hold, then `ready`). A held provider that
	// genuinely shuts down does so by disconnecting, which removes it (and its
	// hold) via RemoveIfSession / RemoveIfSessionState below.
	if next == StateUnavailable {
		r.clearBreakerStateLocked(providerID)
	}
}

func (r *Registry) clearBreakerStateLocked(providerID string) {
	delete(r.breakerFaults, providerID)
	delete(r.recoveryHolds, providerID)
	delete(r.lastBreakerRecoveries, providerID)
}

func (r *Registry) Count() int {
	r.mu.RLock()
	defer r.mu.RUnlock()
	return len(r.providers)
}

// HeartbeatHashVerifier verifies a (model_id, reported_hash) pair against
// the SPEC-008 v0.3 §5.5 five-state enum. Injected into Registry via
// WithHeartbeatHashVerifier so the pool package stays decoupled from the
// tier2 catalog package; post-M3-8d DI, the production wiring at
// internal/ws/server.go binds the *tier2.Catalog instance passed via
// ws.WithCatalog (default: tier2.Default()) so SIGHUP reload through
// tier2.ConfigureDefaultStrict swaps the underlying state atomically.
type HeartbeatHashVerifier func(modelID, reportedHash string) HashStatus

// ModelIdentityVerifier is the algorithm-aware production verifier. The
// legacy two-argument verifier remains available only to preserve focused
// package tests and old embedders while the wire migration is bounded.
type ModelIdentityVerifier func(modelID, expectedHash, reportedHash, reportedAlgorithm string) HashStatus

// SwapEvent carries the per-swap data needed for the operator_model_swap audit
// event per SPEC-002 v1.3.5 §7.10. Phase 2C only populates and emits this
// event; Phase 2E adds the SQLite write + payload schema + F-1.5 invariants.
type SwapEvent struct {
	ProviderID             string
	AssignedID             string
	FromModelID            string
	FromModelHash          string
	ToModelID              string
	ToModelHash            string
	HashVerificationResult HashStatus
	LoadingStartedAt       time.Time
	CompletedAt            time.Time
}

// SwapEventEmitter is called from ApplyHeartbeat when a SPEC-011 PATH
// heartbeat completes a swap (prior heartbeat had loading:true; current
// heartbeat has loading:false AND carries model_hash AND reports a new
// model_id). Default nil = no-op. Phase 2E registers the SQLite emitter
// via WithSwapEmitter.
//
// CONCURRENCY CONTRACT (M2-2 / ARCH-2): the emitter is invoked AFTER
// ApplyHeartbeat releases Registry.mu. Implementations MAY:
//   - call back into Registry methods (no longer deadlocks the global
//     lock the way the pre-M2-2 design did).
//
// Implementations that block in the emitter callback DO pay that
// latency on the calling goroutine — usually the WS heartbeat handler.
// The pool contract makes that safe in the sense that no other
// heartbeat is stalled, but it is NOT the same as a non-blocking
// emitter: the calling goroutine itself waits. For true non-blocking
// semantics the implementation MUST dispatch off the call path, e.g.
// via a buffered channel + dedicated drain goroutine like the
// cmd/coordinator wiring does (the production path). A naive
// synchronous SQLite write here will still delay this provider's next
// heartbeat ack by up to busy_timeout seconds.
//
// Per SPEC-002 v1.3.5 §7.10 R-7.10.8, audit-write failures are
// best-effort and MUST NOT block heartbeat processing or drop the
// provider; a panic still propagates and crashes the heartbeat
// handler, matching the v1.3.4 default failure mode.
type SwapEventEmitter func(event SwapEvent)

// ReceiptRotationEvent carries the coordinator-side audit fields emitted when
// a provider reconnect publishes a different receipt pubkey and that pending
// key commits on state_update. Pubkeys are public trust roots and are included
// per SPEC-015 §11; receipt bodies, hashes, and signatures are never present.
type ReceiptRotationEvent struct {
	ProviderID string
	OldPubkey  []byte
	NewPubkey  []byte
	RotatedAt  time.Time
}

// ReceiptRotationEventEmitter is invoked after Registry.mu is released.
type ReceiptRotationEventEmitter func(event ReceiptRotationEvent)

type HeartbeatUpdate struct {
	Status                  State
	ModelID                 string
	ModelParamsB            float64
	RAMGB                   int
	MaxContextTokens        int
	MaxConcurrency          int
	SlotsFree               int
	SlotsTotal              int
	ThroughputTPSEstimate   float64
	RequestsServedSinceLast int
	ThroughputTPSSinceLast  float64
	// ModelHash is the raw lowercase hex hash from the heartbeat when
	// ModelHashPresent is true; ignored otherwise. Populated from the SPEC-011
	// v0.5 optional heartbeat field per SPEC-002 v1.3.5 §7.1 R-7.1.4.
	ModelHash                 string
	ModelHashPresent          bool
	ModelHashAlgorithm        string
	ModelHashAlgorithmPresent bool
	WeightsManifestSHA256     string
	WeightsHashAlgorithm      string
	ExpectedModelHash         string
	// Loading is the value of the heartbeat's optional `loading` field; absent
	// on the wire (= LoadingPresent false) is equivalent to false per SPEC-011
	// v0.5 R-3.3.4.
	Loading             bool
	LoadingPresent      bool
	LastAutoupdateEvent json.RawMessage
	HardwareCapacity    *ProviderHardwareCapacity
	SafetyTelemetry     *ProviderSafetyTelemetry
	At                  time.Time
}

func (r *Registry) ApplyHeartbeat(providerID, assignedID string, hb HeartbeatUpdate) (*Provider, time.Duration, bool) {
	result := r.ApplyHeartbeatDetailed(providerID, assignedID, hb)
	return result.Provider, result.Gap, result.OK
}

type HeartbeatResult struct {
	Provider       *Provider
	Gap            time.Duration
	OK             bool
	ModelIDChanged bool
	PriorModelID   string
}

func (r *Registry) ApplyHeartbeatDetailed(providerID, assignedID string, hb HeartbeatUpdate) HeartbeatResult {
	cp, gap, ok, modelIDChanged, priorModelID, swap, hasSwap := r.applyHeartbeatLocked(providerID, assignedID, hb)
	// M2-2 / ARCH-2: emit AFTER releasing r.mu. The audit SQLite write
	// can stall on busy_timeout; running it under the global pool lock
	// stalled all routing/liveness. The emitter contract is now relaxed
	// — see SwapEventEmitter doc — and cmd/coordinator dispatches onto
	// a buffered channel drained by a dedicated goroutine.
	if hasSwap && r.swapEmitter != nil {
		r.swapEmitter(swap)
	}
	return HeartbeatResult{
		Provider:       cp,
		Gap:            gap,
		OK:             ok,
		ModelIDChanged: modelIDChanged,
		PriorModelID:   priorModelID,
	}
}

func (r *Registry) applyHeartbeatLocked(providerID, assignedID string, hb HeartbeatUpdate) (*Provider, time.Duration, bool, bool, string, SwapEvent, bool) {
	r.mu.Lock()
	defer r.mu.Unlock()
	p := r.providers[providerID]
	if p == nil || p.AssignedID != assignedID {
		return nil, 0, false, false, "", SwapEvent{}, false
	}
	prev := p.LastHeartbeatAt
	priorModelID := p.ModelID
	priorModelHash := p.ModelHash
	priorLoadingState := p.LastLoadingState
	priorLoadingStartedAt := p.LoadingStartedAt
	p.LastHeartbeatAt = hb.At

	modelIDChanged := !strings.EqualFold(priorModelID, hb.ModelID)
	if !hb.ModelHashPresent {
		p.ModelHash = ""
		p.ModelHashAlgorithm = ""
		p.WeightsManifestSHA256 = ""
		p.WeightsHashAlgorithm = ""
		p.HashStatus = HashStatusUncatalogued
	} else {
		p.ModelHash = hb.ModelHash
		p.ModelHashAlgorithm = hb.ModelHashAlgorithm
		p.WeightsManifestSHA256 = hb.WeightsManifestSHA256
		p.WeightsHashAlgorithm = hb.WeightsHashAlgorithm
		if r.modelIdentityVerifier != nil {
			p.HashStatus = r.modelIdentityVerifier(hb.ModelID, hb.ExpectedModelHash, hb.ModelHash, hb.ModelHashAlgorithm)
		} else if r.hashVerifier != nil {
			p.HashStatus = r.hashVerifier(hb.ModelID, hb.ModelHash)
		} else {
			p.HashStatus = HashStatusUncatalogued
		}
	}
	if hb.WeightsManifestSHA256 != "" {
		p.WeightsManifestSHA256 = hb.WeightsManifestSHA256
		p.WeightsHashAlgorithm = hb.WeightsHashAlgorithm
	}
	p.ExpectedModelHash = hb.ExpectedModelHash

	p.ModelID = hb.ModelID
	p.ModelParamsB = hb.ModelParamsB
	p.RAMGB = hb.RAMGB
	p.MaxContextTokens = hb.MaxContextTokens
	p.MaxConcurrency = hb.MaxConcurrency
	p.SlotsFree = hb.SlotsFree
	p.SlotsTotal = hb.SlotsTotal
	p.ThroughputTPSEstimate = hb.ThroughputTPSEstimate
	p.RequestsServedSinceLast = hb.RequestsServedSinceLast
	p.ThroughputTPSSinceLast = hb.ThroughputTPSSinceLast
	if len(hb.LastAutoupdateEvent) > 0 {
		p.LastAutoupdateEvent = append(p.LastAutoupdateEvent[:0], hb.LastAutoupdateEvent...)
	}
	if hb.HardwareCapacity != nil {
		p.HardwareCapacity = sanitizeProviderHardwareCapacity(hb.HardwareCapacity)
	}
	if hb.SafetyTelemetry == nil {
		p.SafetyTelemetry = nil
	} else {
		telemetry := *hb.SafetyTelemetry
		// Coordinator receipt time is authoritative for freshness. Provider
		// clocks are not trusted to make stale observations look current.
		telemetry.ObservedAt = hb.At.UTC().Format(time.RFC3339Nano)
		p.SafetyTelemetry = &telemetry
	}
	// SPEC-010 v1.5 R-3.3.4: union the heartbeat's served model_id with
	// the provider's declared supported_models. Heartbeat frames do not
	// carry supported_models, so p.SupportedModels (populated at
	// registration) is the authoritative declared set.
	r.recordSeenModelsUnionLocked(p.ProviderID, hb.ModelID, p.SupportedModels)
	if hb.Status != "" && hb.Status != p.State {
		if r.canApplyProviderStateLocked(p, hb.Status) {
			r.setStateLocked(p, hb.Status)
		}
	}
	if hb.LoadingPresent {
		if !priorLoadingState && hb.Loading {
			p.LoadingStartedAt = hb.At
		}
		p.LastLoadingState = hb.Loading
	}
	// SPEC-002 v1.3.5 §7.1 R-7.1.6 + §7.10 R-7.10.6 gate the audit
	// emission on "the FIRST observed heartbeat with loading:false
	// carrying the NEW model_id" — i.e. the post-swap heartbeat
	// MUST report a model_id different from the prior heartbeat's.
	// Without the modelIDChanged guard, a malicious provider could
	// send loading:true → loading:false on the same model_id and
	// forge spurious operator_model_swap events.
	swapCompleted := hb.ModelHashPresent &&
		priorLoadingState &&
		hb.LoadingPresent && !hb.Loading &&
		modelIDChanged
	var swap SwapEvent
	if swapCompleted {
		swap = SwapEvent{
			ProviderID:             p.ProviderID,
			AssignedID:             p.AssignedID,
			FromModelID:            priorModelID,
			FromModelHash:          priorModelHash,
			ToModelID:              p.ModelID,
			ToModelHash:            p.ModelHash,
			HashVerificationResult: p.HashStatus,
			LoadingStartedAt:       priorLoadingStartedAt,
			CompletedAt:            hb.At,
		}
	}
	cp := *p
	var gap time.Duration
	if !prev.IsZero() {
		gap = hb.At.Sub(prev)
	}
	return &cp, gap, true, modelIDChanged, priorModelID, swap, swapCompleted
}

// Touch records that an inbound frame was received from the provider,
// resetting its liveness clock. Called for every frame (any type) so that
// in-flight inference response chunks keep an otherwise-heartbeat-silent
// provider alive. Safe to call for an unregistered provider (no-op).
func (r *Registry) Touch(providerID, assignedID string, at time.Time) {
	r.mu.Lock()
	defer r.mu.Unlock()
	var p *Provider
	if providerID != "" {
		p = r.providers[providerID]
	} else if assignedID != "" {
		p = r.sessions[assignedID]
	}
	if p != nil && (assignedID == "" || p.AssignedID == assignedID) {
		p.LastActivityAt = at
	}
}

// ModelKnown implements SPEC-002 § 7.2's pool-lifetime "has the
// coordinator ever seen this model id" check that drives the 404 vs
// 503 distinction on the buyer port. Returns true iff the model id has
// been advertised by ANY provider at ANY point during this coordinator
// process lifetime (within the maxSeenModelsLifetime cap), whether or
// not the advertising provider is still connected.
//
// Issue #185: a previous implementation iterated seenModelsByProvider
// only, which the M2-5 / PERF-5 audit had wired up to drop on
// provider disconnect. Cold-start races (only provider for a model
// disconnects, buyer asks for that model ~200ms later) returned 404
// model_not_found instead of 503 no_provider_available, leading
// OpenAI-compatible clients to abandon the model as misconfigured
// instead of backing off and retrying. The lifetime accumulator added
// in #185 is append-only with a hard cap, so PERF-5's memory bound
// still holds while SPEC § 7.2's behavior is restored.
func (r *Registry) ModelKnown(modelID string) bool {
	if modelID == "" {
		return false
	}
	// ISS-185 R3 code-lane MAJOR: strings.ToLower is NOT equivalent to
	// strings.EqualFold for Turkish/Greek edges (e.g.
	// EqualFold("Σ","ς")==true but ToLower differs;
	// EqualFold("İ","i")==false but ToLower agrees). Preserve the
	// existing EqualFold contract by:
	// 1. Fast O(1) hit on strings.ToLower canonical key (covers the
	//    ASCII/Latin common case, ~all realistic model ids).
	// 2. On miss, EqualFold scan the lifetime accumulator before
	//    falling through to the live/per-session paths.
	//
	// Issue #900: also accept rate-card / catalog keys that normalize
	// to the same catalog identity as a seen or live HF model id
	// (openai/gpt-oss-20b ↔ mlx-community/gpt-oss-20b-MXFP4-Q8).
	canonical := strings.ToLower(modelID)
	// Hoist query normalization once; fallback scans only normalize
	// stored ids (issue #900 audit: avoid re-allocating on the buyer
	// string inside every EqualFold-miss iteration under RLock).
	normalizedQuery := billing.NormalizeModelKey(modelID)
	r.mu.RLock()
	defer r.mu.RUnlock()
	if _, ok := r.seenModelsLifetime[canonical]; ok {
		return true
	}
	// Non-ASCII / case-folding-edge fallback: EqualFold scan of
	// lifetime keys. Bounded by maxSeenModelsLifetime = 4096; only
	// pays the cost on the never-recorded path (i.e., the 404
	// candidate). Catalog-key equivalence uses the same bound.
	for stored := range r.seenModelsLifetime {
		if modelKnownMatch(stored, modelID, normalizedQuery) {
			return true
		}
	}
	// Fallback paths cover the case where lifetime was at one of its
	// caps (global maxSeenModelsLifetime or per-provider
	// maxLifetimeContribPerProvider) when the model was first
	// advertised, so it was dropped from lifetime even though the
	// provider that advertised it may still be connected.
	//
	// 1. Live providers' current ModelID field.
	for _, p := range r.providers {
		if modelKnownMatch(p.ModelID, modelID, normalizedQuery) {
			return true
		}
	}
	// 1b. SPEC-010 v1.5 R-3.3.4 correctness core: live providers'
	// declared SupportedModels. recordSeenModelsUnionLocked's seen-index
	// union (per-session cap maxSeenModelsPerProvider=32, per-provider
	// lifetime cap maxLifetimeContribPerProvider=128, global lifetime
	// cap maxSeenModelsLifetime=4096) is a best-effort accumulator that
	// can silently drop a declared model under cap pressure — e.g. a
	// provider with a catalog wider than 32 entries. Without this scan,
	// a model beyond those caps would 404 forever even though a
	// CURRENTLY-CONNECTED provider is declaring it right now. A served
	// ModelID never has this gap (step 1 above always covers it
	// regardless of cap state); declared-but-cold models need the same
	// unconditional guarantee while the declaring provider is live.
	for _, p := range r.providers {
		for _, supported := range p.SupportedModels {
			if modelKnownMatch(supported, modelID, normalizedQuery) {
				return true
			}
		}
	}
	// 2. Per-session attribution map. ISS-185 R2 code-lane MAJOR: a
	// provider may have previously advertised this model id via
	// heartbeat (it's in their per-session set) while their CURRENT
	// ModelID is something else. Without this iteration, ModelKnown
	// would return false → 404 even though a connected provider has
	// the model id in its session history.
	for _, set := range r.seenModelsByProvider {
		if _, ok := set[modelID]; ok {
			return true
		}
		for stored := range set {
			if modelKnownMatch(stored, modelID, normalizedQuery) {
				return true
			}
		}
	}
	return false
}

func modelKnownMatch(stored, modelID, normalizedQuery string) bool {
	if strings.EqualFold(stored, modelID) {
		return true
	}
	return billing.MatchesNormalizedKey(stored, normalizedQuery)
}

type StateUpdate struct {
	State               State
	SlotsFree           *int
	SlotsTotal          *int
	LastAutoupdateEvent json.RawMessage
	At                  time.Time
}

func (r *Registry) ApplyStateUpdate(providerID, assignedID string, update StateUpdate) (*Provider, bool) {
	r.mu.Lock()
	p := r.providers[providerID]
	if p == nil || p.AssignedID != assignedID {
		r.mu.Unlock()
		return nil, false
	}
	if r.canApplyProviderStateLocked(p, update.State) {
		r.setStateLocked(p, update.State)
	}
	if update.SlotsFree != nil {
		p.SlotsFree = *update.SlotsFree
	}
	if update.SlotsTotal != nil {
		p.SlotsTotal = *update.SlotsTotal
	}
	if len(update.LastAutoupdateEvent) > 0 {
		p.LastAutoupdateEvent = append(p.LastAutoupdateEvent[:0], update.LastAutoupdateEvent...)
	}
	at := update.At
	if at.IsZero() {
		at = time.Now().UTC()
	}
	rotationEvent := r.commitPendingReceiptPubkeyLocked(p, at)
	cp := *p
	emitter := r.receiptRotationEmitter
	r.mu.Unlock()
	if rotationEvent != nil && emitter != nil {
		emitter(*rotationEvent)
	}
	return &cp, true
}

func (r *Registry) RemoveIfSession(providerID, assignedID string) bool {
	r.mu.Lock()
	defer r.mu.Unlock()
	p := r.providers[providerID]
	if p == nil || p.AssignedID != assignedID {
		return false
	}
	delete(r.providers, providerID)
	delete(r.sessions, assignedID)
	delete(r.seenModelsByProvider, providerID)
	r.clearBreakerStateLocked(providerID)
	return true
}

func (r *Registry) RemoveIfSessionState(providerID, assignedID string, state State) bool {
	r.mu.Lock()
	defer r.mu.Unlock()
	p := r.providers[providerID]
	if p == nil || p.AssignedID != assignedID || p.State != state {
		return false
	}
	delete(r.providers, providerID)
	delete(r.sessions, assignedID)
	delete(r.seenModelsByProvider, providerID)
	r.clearBreakerStateLocked(providerID)
	return true
}

func (r *Registry) Resolve(providerID, assignedID string) (Provider, bool) {
	r.mu.RLock()
	defer r.mu.RUnlock()
	var p *Provider
	if providerID != "" {
		p = r.providers[providerID]
	} else if assignedID != "" {
		p = r.sessions[assignedID]
	}
	if p == nil || (assignedID != "" && p.AssignedID != assignedID) {
		return Provider{}, false
	}
	cp := *p
	cp.conn = nil
	return cp, true
}

func (r *Registry) Conn(providerID, assignedID string) (net.Conn, error) {
	r.mu.RLock()
	defer r.mu.RUnlock()
	p := r.providers[providerID]
	if p == nil || p.AssignedID != assignedID || p.conn == nil {
		return nil, fmt.Errorf("provider session not connected")
	}
	return p.conn, nil
}

// CurrentMaxConcurrency returns the live (already ingest-clamped) concurrency
// cap for a registered provider. Used by the state_update slot clamp so a
// provider cannot report slot counts above its own admitted capacity (#764
// audit R1, security lane).
func (r *Registry) CurrentMaxConcurrency(providerID string) (int, bool) {
	r.mu.RLock()
	defer r.mu.RUnlock()
	p := r.providers[providerID]
	if p == nil {
		return 0, false
	}
	return p.MaxConcurrency, true
}

func (r *Registry) Snapshot() []Provider {
	r.mu.RLock()
	defer r.mu.RUnlock()
	out := make([]Provider, 0, len(r.providers))
	for _, p := range r.providers {
		cp := *p
		cp.conn = nil
		cp.HardwareCapacity = cloneProviderHardwareCapacity(p.HardwareCapacity)
		cp.SafetyTelemetry = cloneProviderSafetyTelemetry(p.SafetyTelemetry)
		out = append(out, cp)
	}
	return out
}

type RegistryOption func(*Registry)

// WithHeartbeatHashVerifier injects the SPEC-008 v0.3 Pillar A verifier used
// by the SPEC-011 PATH of ApplyHeartbeat per SPEC-002 v1.3.5 §7.1 R-7.1.5.
// If never set, the SPEC-011 PATH defaults to HashStatusUncatalogued (the
// conservative fallback for an un-injected Registry — tests typically either
// inject a stub or never exercise the SPEC-011 PATH).
func WithHeartbeatHashVerifier(fn HeartbeatHashVerifier) RegistryOption {
	return func(r *Registry) { r.hashVerifier = fn }
}

func WithModelIdentityVerifier(fn ModelIdentityVerifier) RegistryOption {
	return func(r *Registry) { r.modelIdentityVerifier = fn }
}

// WithSwapEmitter injects the operator_model_swap callback per SPEC-002
// v1.3.5 §7.10. Default nil = no-op (Phase 2C ships the detection logic; Phase
// 2E ships the SQLite writer).
func WithSwapEmitter(fn SwapEventEmitter) RegistryOption {
	return func(r *Registry) { r.swapEmitter = fn }
}

// WithReceiptRotationEmitter injects the SPEC-015 receipt_rotation_detected
// audit callback. Default nil = no-op.
func WithReceiptRotationEmitter(fn ReceiptRotationEventEmitter) RegistryOption {
	return func(r *Registry) { r.receiptRotationEmitter = fn }
}
