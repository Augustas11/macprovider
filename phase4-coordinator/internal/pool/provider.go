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
	ProviderID            string  `json:"provider_id"`
	AssignedID            string  `json:"assigned_id"`
	Hostname              string  `json:"hostname"`
	ModelID               string  `json:"model_id"`
	ModelParamsB          float64 `json:"model_params_b"`
	RAMGB                 int     `json:"ram_gb"`
	MaxContextTokens      int     `json:"max_context_tokens"`
	MaxConcurrency        int     `json:"max_concurrency"`
	SlotsFree             int     `json:"slots_free"`
	SlotsTotal            int     `json:"slots_total"`
	ThroughputTPSEstimate float64 `json:"throughput_tps_estimate"`
	ModelLoadTimeMs       int64   `json:"model_load_time_ms,omitempty"`
	EndpointURL           string  `json:"endpoint_url"`
	Tier                  Tier    `json:"tier"`
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
	LastActivityAt time.Time  `json:"last_activity_at"`
	ConnectedAt    time.Time  `json:"connected_at"`
	BinaryVersion  string     `json:"binary_version"`
	ModelHash      string     `json:"model_hash,omitempty"`
	HashStatus     HashStatus `json:"hash_status,omitempty"`
	EncryptedLeg   bool       `json:"encrypted_leg,omitempty"`
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
	CanaryFailCount     int             `json:"canary_fail_count,omitempty"`
	CanaryLastCheckedAt *time.Time      `json:"canary_last_checked_at,omitempty"`
	CanaryLastFailedAt  *time.Time      `json:"canary_last_failed_at,omitempty"`
	LastAutoupdateEvent json.RawMessage `json:"last_autoupdate_event,omitempty"`
	// HardwareCapacity is live, provider-reported capacity metadata carried on
	// heartbeats for public aggregate stats. It is deliberately separate from
	// AttestationStatus and from verified stats hardware inventory: it can make
	// cores/bandwidth visible without claiming hardware attestation.
	HardwareCapacity *ProviderHardwareCapacity `json:"hardware_capacity,omitempty"`
	// Proof of Weights W2 — coordinator-side autotune hello gate cap derived
	// from latest verified hardware-evidence benchmarks. Empty when gate off
	// or provider admitted before W2 rollout.
	MaxAdmittedModelKey string `json:"max_admitted_model_class,omitempty"`
	MaxAdmittedModelID  string `json:"max_admitted_model_id,omitempty"`

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
	AEADSuite          string
	C2PKey             []byte
	P2CKey             []byte
	C2PNonceBase       []byte
	P2CNonceBase       []byte
	C2PCounter         uint64
	P2CCounter         uint64
	RequestsDispatched uint64
	KeyID              string
	StartedAt          time.Time
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
// alongside tier2ProviderExcludedStatus to enforce hash policy. Catalog and
// health surfaces separately exclude pending receipt-key publication while
// preserving ready providers that are temporarily out of free slots.
func (p Provider) RoutingEligible() bool {
	if p.AuthState == AuthBearerlessDuplicate || p.AuthState == AuthSelfMinted {
		return false
	}
	if len(p.PendingReceiptPubkey) > 0 {
		return false
	}
	return p.State == StateReady && p.SlotsFree > 0
}

// CapacityEligible reports whether a provider may be counted on serving and
// capacity surfaces. It deliberately omits SlotsFree so busy providers still
// count as online capacity while tokenless, duplicate, and receipt-key-rotation
// sessions stay visible but not advertised as usable serving capacity.
func (p Provider) CapacityEligible() bool {
	if p.AuthState == AuthBearerlessDuplicate || p.AuthState == AuthSelfMinted {
		return false
	}
	if len(p.PendingReceiptPubkey) > 0 {
		return false
	}
	return p.State == StateReady || p.State == StateBusy
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
//     "invalid_token". This branch fires on two SPEC-003 v0.8.4 FR-C9.4
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
// The DB partial unique index alone prevents the attacker from minting
// a parallel bearer, but does NOT prevent these two pool-slot capture
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
	r.recordSeenModelLocked(p.ProviderID, p.ModelID)
	delete(r.breakerFaults, p.ProviderID)
	delete(r.recoveryHolds, p.ProviderID)
	delete(r.lastBreakerRecoveries, p.ProviderID)
	r.applyCanarySanctionLocked(p)
	return old, true, RegisterRefusalNone
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
	Status                State
	ModelID               string
	ModelParamsB          float64
	RAMGB                 int
	MaxContextTokens      int
	MaxConcurrency        int
	SlotsFree             int
	SlotsTotal            int
	ThroughputTPSEstimate float64
	// ModelHash is the raw lowercase hex hash from the heartbeat when
	// ModelHashPresent is true; ignored otherwise. Populated from the SPEC-011
	// v0.5 optional heartbeat field per SPEC-002 v1.3.5 §7.1 R-7.1.4.
	ModelHash        string
	ModelHashPresent bool
	// Loading is the value of the heartbeat's optional `loading` field; absent
	// on the wire (= LoadingPresent false) is equivalent to false per SPEC-011
	// v0.5 R-3.3.4.
	Loading             bool
	LoadingPresent      bool
	LastAutoupdateEvent json.RawMessage
	HardwareCapacity    *ProviderHardwareCapacity
	At                  time.Time
}

func (r *Registry) ApplyHeartbeat(providerID, assignedID string, hb HeartbeatUpdate) (*Provider, time.Duration, bool) {
	cp, gap, ok, swap, hasSwap := r.applyHeartbeatLocked(providerID, assignedID, hb)
	// M2-2 / ARCH-2: emit AFTER releasing r.mu. The audit SQLite write
	// can stall on busy_timeout; running it under the global pool lock
	// stalled all routing/liveness. The emitter contract is now relaxed
	// — see SwapEventEmitter doc — and cmd/coordinator dispatches onto
	// a buffered channel drained by a dedicated goroutine.
	if hasSwap && r.swapEmitter != nil {
		r.swapEmitter(swap)
	}
	return cp, gap, ok
}

func (r *Registry) applyHeartbeatLocked(providerID, assignedID string, hb HeartbeatUpdate) (*Provider, time.Duration, bool, SwapEvent, bool) {
	r.mu.Lock()
	defer r.mu.Unlock()
	p := r.providers[providerID]
	if p == nil || p.AssignedID != assignedID {
		return nil, 0, false, SwapEvent{}, false
	}
	prev := p.LastHeartbeatAt
	priorModelID := p.ModelID
	priorModelHash := p.ModelHash
	priorLoadingState := p.LastLoadingState
	priorLoadingStartedAt := p.LoadingStartedAt
	p.LastHeartbeatAt = hb.At

	modelIDChanged := !strings.EqualFold(priorModelID, hb.ModelID)
	if !hb.ModelHashPresent {
		if modelIDChanged {
			p.ModelHash = ""
			p.HashStatus = HashStatusUncatalogued
		}
	} else if modelIDChanged || !strings.EqualFold(priorModelHash, hb.ModelHash) {
		p.ModelHash = hb.ModelHash
		if r.hashVerifier != nil {
			p.HashStatus = r.hashVerifier(hb.ModelID, hb.ModelHash)
		} else {
			p.HashStatus = HashStatusUncatalogued
		}
	}

	p.ModelID = hb.ModelID
	p.ModelParamsB = hb.ModelParamsB
	p.RAMGB = hb.RAMGB
	p.MaxContextTokens = hb.MaxContextTokens
	p.MaxConcurrency = hb.MaxConcurrency
	p.SlotsFree = hb.SlotsFree
	p.SlotsTotal = hb.SlotsTotal
	p.ThroughputTPSEstimate = hb.ThroughputTPSEstimate
	if len(hb.LastAutoupdateEvent) > 0 {
		p.LastAutoupdateEvent = append(p.LastAutoupdateEvent[:0], hb.LastAutoupdateEvent...)
	}
	if hb.HardwareCapacity != nil {
		p.HardwareCapacity = sanitizeProviderHardwareCapacity(hb.HardwareCapacity)
	}
	r.recordSeenModelLocked(p.ProviderID, hb.ModelID)
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
	return &cp, gap, true, swap, swapCompleted
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
	canonical := strings.ToLower(modelID)
	r.mu.RLock()
	defer r.mu.RUnlock()
	if _, ok := r.seenModelsLifetime[canonical]; ok {
		return true
	}
	// Non-ASCII / case-folding-edge fallback: EqualFold scan of
	// lifetime keys. Bounded by maxSeenModelsLifetime = 4096; only
	// pays the cost on the never-recorded path (i.e., the 404
	// candidate).
	for stored := range r.seenModelsLifetime {
		if strings.EqualFold(stored, modelID) {
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
		if strings.EqualFold(p.ModelID, modelID) {
			return true
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
			if strings.EqualFold(stored, modelID) {
				return true
			}
		}
	}
	return false
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

func (r *Registry) Snapshot() []Provider {
	r.mu.RLock()
	defer r.mu.RUnlock()
	out := make([]Provider, 0, len(r.providers))
	for _, p := range r.providers {
		cp := *p
		cp.conn = nil
		cp.HardwareCapacity = cloneProviderHardwareCapacity(p.HardwareCapacity)
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
