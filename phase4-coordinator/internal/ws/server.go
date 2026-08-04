package ws

import (
	"bytes"
	"context"
	"crypto/ed25519"
	"crypto/rand"
	"encoding/base64"
	"encoding/json"
	"errors"
	"io"
	"math/big"
	"net"
	"net/http"
	"strconv"
	"strings"
	"sync"
	"sync/atomic"
	"time"

	"github.com/augstar/macprovider-coordinator/internal/config"
	"github.com/augstar/macprovider-coordinator/internal/modelidentity"
	"github.com/augstar/macprovider-coordinator/internal/pool"
	"github.com/augstar/macprovider-coordinator/internal/providerevents"
	"github.com/augstar/macprovider-coordinator/internal/providerhttp"
	"github.com/augstar/macprovider-coordinator/internal/tier2"
	"github.com/augstar/macprovider-coordinator/internal/versionfloor"
	gobwas "github.com/gobwas/ws"
	"github.com/gobwas/ws/wsutil"
	"github.com/google/uuid"
	"github.com/rs/zerolog"

	"github.com/augstar/macprovider-coordinator/internal/auth"
	"github.com/augstar/macprovider-coordinator/internal/autotune"
	"github.com/augstar/macprovider-coordinator/internal/onboarding"
	"github.com/augstar/macprovider-coordinator/internal/pow"
)

const (
	CloseUnrecognizedAuthMessage   gobwas.StatusCode = 4000
	CloseInvalidHello              gobwas.StatusCode = 4001
	CloseUnknownProviderID         gobwas.StatusCode = 4002
	CloseTierUnsupported           gobwas.StatusCode = 4003
	CloseIdentitySignatureRequired gobwas.StatusCode = 4003
	CloseVersionUnsupported        gobwas.StatusCode = 4004
	CloseInvalidToken              gobwas.StatusCode = 4005
	CloseProvisionalPoolFull       gobwas.StatusCode = 4007
	CloseProvisionalRateLimited    gobwas.StatusCode = 4008
	CloseBanned                    gobwas.StatusCode = 4009
	CloseTier2AttestationFailed    gobwas.StatusCode = 4012
	CloseTier2KeyExchangeFailed    gobwas.StatusCode = 4013
	ClosePoolFull                  gobwas.StatusCode = 4429
)

const (
	autotuneEvidenceLookupTimeout       = 2 * time.Second
	admissionCeilingEventCooldown       = 5 * time.Minute
	admissionCeilingEventStateTTL       = 24 * time.Hour
	admissionCeilingEventStateMaxKeys   = 4096
	admissionCeilingDiagnosticValueRune = 48
)

type admissionCeilingEventRateState struct {
	last       time.Time
	suppressed uint64
}

type Server struct {
	cfg                       config.Config
	proofOfWeightsAdmissionMu sync.RWMutex
	proofOfWeightsMu          sync.RWMutex
	proofOfWeights            config.ProofOfWeightsConfig
	proofOfWeightsGeneration  uint64
	tier2Mu                   sync.RWMutex
	tier2                     config.Tier2Config
	modelHashLegacyMu         sync.Mutex
	modelHashLegacyTimer      *time.Timer
	modelHashLegacyGeneration uint64
	pool                      *pool.Registry
	log                       zerolog.Logger
	now                       func() time.Time
	newUUID                   func() string
	timers                    sync.Map
	pending                   sync.Map
	warmups                   sync.Map
	canaries                  sync.Map
	canaryDue                 sync.Map
	// canaryRecoveryMu fences operator recovery against canary result
	// application. Epochs invalidate probes that began before a recovery.
	canaryRecoveryMu sync.RWMutex
	canaryEpochs     sync.Map // provider_id -> *atomic.Uint64
	// enforceNextCanary marks provider IDs (presence = true) whose NEXT canary
	// probe must be enforced (no cold-start grace). Set after a graced-neutral
	// probe and cleared after any recorded (enforced) probe, so a graced probe
	// is always followed by an enforced one — a provider cannot arrange (via
	// reconnect / due-timing churn) to only ever be probed under grace and evade
	// the TTFT sanction. Keyed by PROVIDER ID so it survives reconnects.
	enforceNextCanary sync.Map
	// FR-CAN23 live correlation (package canarycorr). Open only while canary is
	// enabled; Pearl production keeps canary disabled under #584. Guarded by
	// canaryCorrMu. canaryBankGeneration is an interim monotonic bank/config
	// generation (FR-CAN26 full hot-reload generation remains a Gap).
	canaryCorrMu                  sync.Mutex
	canaryCorrByModel             map[string]*liveCorrelationEpoch
	canarySharedDispatch          map[string]sharedCanaryDispatch
	canaryBankGeneration          uint64
	losslessnessPending           sync.Map
	losslessnessNonceIndex        sync.Map
	losslessnessDigestIndex       sync.Map
	losslessnessProfilesMu        sync.Mutex
	losslessnessProfiles          map[LosslessnessProfileKey]LosslessnessProfileRecord
	losslessnessStateMu           sync.Mutex
	losslessnessDraftAdmissions   map[losslessnessDraftAdmissionKey]LosslessnessDraftAdmissionRecord
	losslessnessTargetGenerations map[string]int
	losslessnessProfileCursor     map[string]int
	losslessnessTelemetry         []LosslessnessTelemetryEvent
	canarySanctions               CanarySanctionStore
	tokens                        TokenValidator
	// SPEC-003 v0.8 FR-C9.1 — separate issuer field so validator and
	// issuer roles can be wired independently. Production wires the same
	// concrete *auth.Store to both (see main.go), but tests can override
	// mint behavior (e.g. mintFailingStore) without touching the
	// validator. Codex architect review on PR #44 flagged the
	// interface-segregation regression of mixing both on TokenValidator.
	issuer          TokenIssuer
	bootstrapTokens BootstrapTokenStore
	referralPolicy  auth.ReferralPolicy
	authStore       *auth.Store
	githubOAuth     githubOAuthClient
	admission       *AdmissionManager
	sessions        sync.Map
	started         time.Time
	explorer        http.Handler
	unauth          chan struct{}
	// unauthPerIP counts concurrent unauthenticated WS handshakes by remote IP.
	// Defense-in-depth against nginx limit_conn evasion: one host can still
	// burn the global 64-slot semaphore without per-IP shaping (M1-4 / SECU-1).
	unauthPerIPMu sync.Mutex
	unauthPerIP   map[string]int
	version       string
	// SPEC-002 v1.3.5 §7.9 — auth-attempt retention store, 1024 bound
	authAttempts *authAttemptStore
	// catalog holds an explicitly-injected tier2.Catalog for tests that
	// want isolation from the package-singleton; nil means "use
	// tier2.Default()". M3-8d (audit TEST-4). See s.catalogRef().
	catalog                        *tier2.Catalog
	autotuneCatalog                *autotune.Catalog
	autotuneCompatibleCatalogs     map[string]*autotune.Catalog
	autotuneCatalogEnforced        bool
	autotuneCatalogBridgeDeadline  time.Time
	autotuneCatalogBridgeMu        sync.Mutex
	autotuneEvidence               autotune.EvidenceStore
	telemetryDriftMu               sync.RWMutex
	telemetryDrift                 *pow.Evaluator
	telemetryDriftGeneration       uint64
	identitySignatures             IdentitySignatureStore
	authPolicyAdmin                ProviderAuthPolicyAdminStore
	hardwareTrustAdmin             HardwareTrustAdminStore
	providerTrust                  ProviderTrustChecker
	admissionIdentityRecoveryAdmin AdmissionIdentityRecoveryAdminStore
	idlePrewarm                    IdlePrewarmRecorder
	idlePrewarmMetrics             IdlePrewarmMetrics
	modelHashMismatchMetrics       ModelHashMismatchMetrics
	credentialBootstrapMetrics     CredentialBootstrapMetrics
	capacityOverClaimMetrics       CapacityOverClaimMetrics
	connectionEvents               ConnectionEventStore
	connectionEventMetrics         ConnectionEventMetrics
	closeEventMeta                 sync.Map // net.Conn -> closeEventMeta
	connectionEventQueue           chan connectionEventJob
	connectionEventQueueMu         sync.Mutex
	connectionEventWorkerOnce      sync.Once
	connectionEventStopOnce        sync.Once
	connectionEventDone            chan struct{}
	connectionEventsStopped        atomic.Bool
	admissionCeilingEventMu        sync.Mutex
	admissionCeilingEvents         map[string]admissionCeilingEventRateState
	providerConnWG                 sync.WaitGroup
	anonymousEventMu               sync.Mutex
	anonymousEventWindow           time.Time
	anonymousEventCount            int
	lastKnownFlushMu               sync.Mutex
	lastKnownFlush                 map[string]time.Time
	diagnosticLastKnownFlushMu     sync.Mutex
	diagnosticLastKnownFlush       map[string]time.Time
	bootstrapLimiter               *bootstrapMintLimiter
	idlePrewarmLimits              sync.Map
	idlePrewarmQueue               chan idlePrewarmRecord

	// SE liveness (Phase 1, Track P1-C).
	// seLivenessChans maps sessionKey → chan SELivenessResponse for in-flight probes.
	// seLivenessInFlight guards against concurrent probes for the same session.
	seLivenessChans    sync.Map
	seLivenessInFlight sync.Map

	// Trust-revalidation sweep failure accounting (issue #582 FIX C). Bounds the
	// remaining fail-open: a single transient sweep DB error is skipped, but N
	// consecutive failures escalate to a degraded trust-authority signal + a
	// bounded quarantine of established gated sessions, so the coordinator cannot
	// serve indefinitely on an unverifiable trust store. trustSweepFailures is
	// only touched by the single sweep goroutine; trustAuthorityDegraded is read
	// concurrently by /healthz, hence atomic.
	trustSweepFailures     int
	trustAuthorityDegraded atomic.Bool
}

// TokenValidator handles inspection of a Bearer header on the WS connect.
// Intentionally narrow — issuance is a separate concern (see TokenIssuer)
// so test seams can mock validation independently.
//
// SPEC-003 v0.8.4 (fix-pass-5) added `ValidateAndMarkTokenUsed` to close
// the TOCTOU window between `ValidateToken` and `MarkTokenUsed`. Ordinary
// and previously confirmed credentials are marked during that atomic
// validation. Fresh bootstrap credentials remain provisional until every
// provider-ID-bound hello/evidence/admission check succeeds; MarkTokenUsed
// commits that boundary before registration or an accepted response.
//
// `ValidateToken` is retained as a separate method for read-only
// validations that don't need to record use (operator tooling, status).
// `MarkTokenUsed` is retained for backwards compatibility and tests.
type TokenValidator interface {
	ValidateToken(context.Context, string) (string, bool, error)
	MarkTokenUsed(context.Context, string) error
	ValidateAndMarkTokenUsed(context.Context, string) (string, bool, error)
}

// TokenIssuer handles SPEC-003 v0.8 FR-C9.1 self-serve provisional token
// minting plus FR-C9.4 TOFU enforcement. Split from TokenValidator per
// the codex architect review on PR #44 (interface segregation): a future
// deployment may wire a validator backed by a remote service while
// issuance remains local, or vice versa. Production wires the same
// concrete *auth.Store to both, but the two roles are decoupled at the
// interface layer so the seam exists when needed.
type TokenIssuer interface {
	// IssueToken returns (record, cleartext_token, err). On success,
	// only the cleartext is used in the ack frame; the record is
	// logged. On `auth.ErrActiveTokenAlreadyExists` (the partial
	// unique index trapped a duplicate), the caller maps the error
	// to admit-tokenless with AuthBearerlessDuplicate marking — see
	// resolveProvisionalToken in this package and SPEC-003 v0.8.4
	// FR-C9.4 (composed self-heal + race-loss quarantine).
	IssueToken(ctx context.Context, providerID, providerName string) (auth.TokenRecord, string, error)
	// HasActiveTokenForProvider implements the Wave 2 custody gate:
	// when true, the server MUST refuse tokenless mutation for this
	// provider_id and close the connection. Changing an active token now
	// requires proof of the existing token or an operator recovery path.
	HasActiveTokenForProvider(ctx context.Context, providerID string) (bool, error)
}

type BootstrapTokenStore interface {
	MintBootstrapToken(context.Context, auth.BootstrapMintRequest) (auth.BootstrapMint, error)
	LookupBootstrapIdentityPubkey(context.Context, string) ([]byte, bool, error)
	BootstrapIdentityExists(context.Context, string) (bool, error)
}

// admissionIdentityStore is optional so bootstrap-only alternate stores and
// narrow test doubles remain source-compatible. Ordinary provider enrollment
// fails closed when this capability is unavailable.
type admissionIdentityStore interface {
	LookupAdmissionIdentityPubkey(context.Context, string) ([]byte, bool, error)
	AdmissionIdentityExists(context.Context, string) (bool, error)
	BindAdmissionIdentity(context.Context, string, string, []byte, time.Time) error
}

// admissionIdentityRotationStore is optional so narrow test doubles and
// alternate bootstrap stores remain source-compatible. Production *auth.Store
// implements it; a proposed rotation fails closed when the capability is not
// available.
type admissionIdentityRotationStore interface {
	LookupAdmissionIdentityState(context.Context, string, time.Time) (auth.AdmissionIdentityState, bool, error)
	RotateAdmissionIdentity(context.Context, string, string, []byte, []byte, int, time.Time) (auth.AdmissionIdentityState, error)
	RecoverAdmissionIdentity(context.Context, string, string, []byte, []byte, int, time.Time) (auth.AdmissionIdentityState, auth.AdmissionIdentityRecoveryAuthorization, error)
}

type providerAuth struct {
	validated  bool
	providerID string
	token      string
	sourceIP   string
}

type IdentitySignatureStore interface {
	LookupProviderAuthPolicy(ctx context.Context, providerID string) (signatureExemptUntil *time.Time, grantedBy string, ok bool, err error)
	LookupProviderIdentityPubkey(ctx context.Context, providerID string) ([]byte, bool, error)
}

type AdmissionIdentityRecoveryAuthorization = auth.AdmissionIdentityRecoveryAuthorization

type ProviderAuthPolicyAdminStore interface {
	RequestProviderAuthPolicyExemption(ctx context.Context, pendingID, providerID, requestedBy string, requestedUntil time.Time, reason, incidentID string) error
	ApproveProviderAuthPolicyExemption(ctx context.Context, pendingID, approvedBy string) (providerID, requestedBy string, requestedUntil time.Time, reason, incidentID string, err error)
	SeedProviderAuthPolicyCutover(ctx context.Context, cutover time.Time, cliProviderIDs []string) (int64, error)
}

type AdmissionIdentityRecoveryAdminStore interface {
	RequestAdmissionIdentityRecovery(ctx context.Context, authorization AdmissionIdentityRecoveryAuthorization, now time.Time) (AdmissionIdentityRecoveryAuthorization, error)
	ApproveAdmissionIdentityRecovery(ctx context.Context, pendingID, approvedBy string, now time.Time) (AdmissionIdentityRecoveryAuthorization, error)
}

// HardwareTrustAdminStore backs the durable operator hardware-trust approval
// path (issue #582). The request/approve methods route through separate DB
// handles authenticated as the split hardware_trust_requester /
// hardware_trust_approver roles so no single operator key can both request and
// approve a trust root.
type HardwareTrustAdminStore interface {
	RequestHardwareTrustApproval(ctx context.Context, pendingID string, jobID int64, requestedBy string, expiresAt *time.Time, reason, incidentID string) (providerID, hardwareIdentityHash, chipNormalized string, unifiedMemoryGB int, err error)
	ApproveHardwareTrustApproval(ctx context.Context, pendingID, approvedBy string) (providerID, hardwareIdentityHash, chipNormalized string, unifiedMemoryGB int, expiresAt *time.Time, reason, incidentID, source string, effectiveExpiresAt *time.Time, err error)
	RevokeHardwareTrustApproval(ctx context.Context, providerID, hardwareIdentityHash, revokedBy, reason string) (chipNormalized string, unifiedMemoryGB int, nowUntrusted bool, err error)
	ListWaitingTrustJobs(ctx context.Context, afterID int64, limit int) ([]onboarding.WaitingTrustJob, error)
}

// ProviderTrustChecker backs active-session hardware-trust enforcement (issue
// #582 FIX B). SessionsWithoutActiveTrust is the single batched read for the
// bounded revalidation sweep: given each active session's EXACT admitted
// hardware tuple, it returns the subset whose tuple no longer has an active
// trust root. It is read-only against the provider_onboarding role. Wired only
// when the hardware trust hello gate (the admission trust join) is enabled, so
// non-onboarding deployments run no sweep.
//
// There is deliberately NO registration-time re-check (issue #582 FIX A): trust
// is authorized at the hello gate (checkAutotuneHelloGate → LatestVerified),
// which runs BEFORE any durable mutation (token/PairOT/referral). A
// commit-then-refuse recheck after minting is the exact onboarding/recovery
// deadlock #582 exists to remove; the residual hello-gate→register TOCTOU is
// covered by this bounded sweep, which evicts but NEVER refuses a committed session.
type ProviderTrustChecker interface {
	SessionsWithoutActiveTrust(ctx context.Context, admitted []onboarding.AdmittedTuple) ([]onboarding.AdmittedTuple, error)
}

type IdlePrewarmRecorder interface {
	RecordIdlePrewarmEvent(ctx context.Context, providerID, event, reason string) error
}

type IdlePrewarmMetrics interface {
	IncIdlePrewarmEvent(event, reason string)
}

type ModelHashMismatchMetrics interface {
	IncModelHashMismatch()
}

type CredentialBootstrapMetrics interface {
	IncCredentialBootstrap(outcome string)
}

// CapacityOverClaimMetrics receives the issue-#764 tripwire. The counter is
// PERMANENT: it is a process-lifetime prometheus counter that never resets and
// is incremented on EVERY offending frame, not once per provider — a box that
// keeps over-claiming keeps counting, so the rate is itself the signal.
type CapacityOverClaimMetrics interface {
	IncCapacityOverClaim(phase string)
}

// EventProviderCapacityOverClaim is the structured-log event name for a
// provider-reported capacity claim above pool.max_concurrency_ceiling.
const EventProviderCapacityOverClaim = "provider_capacity_over_claim"

// EventProviderBenchmarkQuarantine is the structured-log event name for an
// issue-#765 fail-suspect transition (quarantined / released).
const EventProviderBenchmarkQuarantine = "provider_benchmark_quarantine"

// EventProviderAdmissionCeilingExclusion is the structured-log event name for a
// SPEC-032 FR-HG7 route-exclusion transition.
const EventProviderAdmissionCeilingExclusion = "provider_admission_ceiling_exclusion"

// EventProviderAdmissionEvidenceStale is the structured-log event name for a
// SPEC-032 FR-HG6 session-time evidence TTL route-exclusion transition.
const EventProviderAdmissionEvidenceStale = "provider_admission_evidence_stale"

// capacity-over-claim tripwire phases. Closed set — used as a prometheus label.
const (
	capacityPhaseHello       = "hello"
	capacityPhaseHeartbeat   = "heartbeat"
	capacityPhaseStateUpdate = "state_update"
)

const (
	idlePrewarmEventBurst           = 10
	idlePrewarmEventRefillPerSecond = 1
	idlePrewarmEventQueueSize       = 1024
	idlePrewarmLimiterTTL           = 15 * time.Minute
)

type idlePrewarmLimiter struct {
	mu     sync.Mutex
	tokens int
	last   time.Time
}

type idlePrewarmRecord struct {
	providerID string
	event      string
	reason     string
}

type Option func(*Server)

// WithCatalog injects a specific tier2.Catalog instance for this server.
// Default (nil/unset) is tier2.Default(), the package singleton, so production
// wiring needs no change. Tests can pass an isolated *tier2.Catalog so they
// no longer race against tier2.ResetForTest. M3-8d (audit TEST-4).
func WithCatalog(c *tier2.Catalog) Option {
	return func(s *Server) {
		s.catalog = c
	}
}

// WithAutotuneCatalog wires the verified release used for provider catalog
// compatibility and acknowledgement independently of the optional evidence
// gate.
func WithAutotuneCatalog(catalog *autotune.Catalog, compatible ...*autotune.Catalog) Option {
	return func(s *Server) {
		s.autotuneCatalog = catalog
		s.autotuneCompatibleCatalogs = make(map[string]*autotune.Catalog, len(compatible))
		for _, previous := range compatible {
			if previous != nil && previous.Version != "" && !autotune.IsPermanentlyRejectedReleaseID(previous.Version) && (catalog == nil || previous.Version != catalog.Version) {
				s.autotuneCompatibleCatalogs[previous.Version] = previous
			}
		}
	}
}

// WithAutotuneCatalogEnforcement configures strict admission or an explicitly
// deadline-bounded fleet bridge for metadata-free providers. Config validation
// requires a future deadline no more than 24 hours away whenever enforced is
// false.
func WithAutotuneCatalogEnforcement(enforced bool, bridgeDeadline time.Time) Option {
	return func(s *Server) {
		s.autotuneCatalogEnforced = enforced
		s.autotuneCatalogBridgeDeadline = bridgeDeadline.UTC()
	}
}

// WithAutotuneHelloGate wires Session B proof-of-weights capacity ceiling
// inputs. When cfg.ProofOfWeights.RequireAutotuneHelloGate is true, hello
// admission consults catalog + verified hardware-evidence before registering
// the provider.
func WithAutotuneHelloGate(catalog *autotune.Catalog, store autotune.EvidenceStore) Option {
	return func(s *Server) {
		s.autotuneCatalog = catalog
		s.autotuneEvidence = store
	}
}

func WithAutotuneEvidenceStore(store autotune.EvidenceStore) Option {
	return func(s *Server) {
		s.autotuneEvidence = store
	}
}

func WithTelemetryDriftEvaluator(evaluator *pow.Evaluator) Option {
	return func(s *Server) {
		s.SetTelemetryDriftEvaluator(evaluator)
	}
}

func WithTokenValidator(tokens TokenValidator) Option {
	return func(s *Server) {
		s.tokens = tokens
	}
}

// WithTokenIssuer installs the SPEC-003 v0.8 FR-C9 self-serve issuance
// backend. Separate from WithTokenValidator so tests can inject mint
// failures (mintFailingStore in provider_token_self_serve_test.go)
// without disturbing validator behavior. Production wiring passes the
// same *auth.Store to both options.
func WithTokenIssuer(issuer TokenIssuer) Option {
	return func(s *Server) {
		s.issuer = issuer
	}
}

func WithBootstrapTokenStore(store BootstrapTokenStore) Option {
	return func(s *Server) {
		s.bootstrapTokens = store
	}
}

func WithReferralPolicy(policy auth.ReferralPolicy) Option {
	return func(s *Server) {
		s.referralPolicy = policy
	}
}

func WithGitHubAuthStore(store *auth.Store) Option {
	return func(s *Server) {
		s.authStore = store
	}
}

func WithIdentitySignatureStore(store IdentitySignatureStore) Option {
	return func(s *Server) {
		s.identitySignatures = store
	}
}

func WithProviderAuthPolicyAdminStore(store ProviderAuthPolicyAdminStore) Option {
	return func(s *Server) {
		s.authPolicyAdmin = store
	}
}

func WithAdmissionIdentityRecoveryAdminStore(store AdmissionIdentityRecoveryAdminStore) Option {
	return func(s *Server) {
		s.admissionIdentityRecoveryAdmin = store
	}
}

func WithHardwareTrustAdminStore(store HardwareTrustAdminStore) Option {
	return func(s *Server) {
		s.hardwareTrustAdmin = store
	}
}

// WithProviderTrustChecker installs the active-session hardware-trust
// revalidation backend (issue #582 FIX A/B). Wired alongside the hardware trust
// hello gate; presence gates both the periodic revalidation sweep and the
// registration-time re-check.
func WithProviderTrustChecker(checker ProviderTrustChecker) Option {
	return func(s *Server) {
		s.providerTrust = checker
	}
}

func WithIdlePrewarmRecorder(recorder IdlePrewarmRecorder) Option {
	return func(s *Server) {
		s.idlePrewarm = recorder
	}
}

func WithIdlePrewarmMetrics(metrics IdlePrewarmMetrics) Option {
	return func(s *Server) {
		s.idlePrewarmMetrics = metrics
	}
}

func WithModelHashMismatchMetrics(metrics ModelHashMismatchMetrics) Option {
	return func(s *Server) {
		s.modelHashMismatchMetrics = metrics
	}
}

func WithCredentialBootstrapMetrics(metrics CredentialBootstrapMetrics) Option {
	return func(s *Server) {
		s.credentialBootstrapMetrics = metrics
	}
}

func WithCapacityOverClaimMetrics(metrics CapacityOverClaimMetrics) Option {
	return func(s *Server) {
		s.capacityOverClaimMetrics = metrics
	}
}

func WithGitHubOAuthClient(client githubOAuthClient) Option {
	return func(s *Server) {
		s.githubOAuth = client
	}
}

func WithVersion(v string) Option {
	return func(s *Server) {
		if v != "" {
			s.version = v
		}
	}
}

func WithNow(now func() time.Time) Option {
	return func(s *Server) {
		if now == nil {
			return
		}
		s.now = now
		s.admission = NewAdmissionManager(s.cfg.Admission, s.now)
	}
}

func WithExplorerHandler(handler http.Handler) Option {
	return func(s *Server) {
		s.explorer = handler
	}
}

func WithAdmissionStore(store AdmissionStateStore) Option {
	return func(s *Server) {
		s.admission.SetPersistence(store, func(err error) {
			s.log.Warn().Err(err).Msg("admission state persistence failed")
		})
	}
}

func WithCanarySanctionStore(store CanarySanctionStore) Option {
	return func(s *Server) {
		s.canarySanctions = store
	}
}

// WithAuthAttemptRetentionBound overrides the default 1024-bound
// on the SPEC-002 v1.3.5 §7.9 auth-attempt retention store.
// INTENDED USE: tests that exercise the AC-K.16 retention-bound
// rejection path with a smaller bound (commonly 1). Production
// deployments SHOULD NOT lower the bound below 1024 (per
// SPEC-002 v1.3.5 R-7.9.6 recommended value); lower values
// will reject legitimate auth attempts under normal traffic.
func WithAuthAttemptRetentionBound(maxBound int) Option {
	return func(s *Server) {
		s.authAttempts = newAuthAttemptStore(maxBound)
	}
}

// WithRegistryOptions applies test-facing pool Registry options to the
// server-owned registry. Production wiring installs the heartbeat hash verifier
// automatically in NewServer; tests use this to inject Phase 2C emitters.
func WithRegistryOptions(opts ...pool.RegistryOption) Option {
	return func(s *Server) {
		if s.pool == nil {
			return
		}
		for _, opt := range opts {
			opt(s.pool)
		}
	}
}

// AuthAttemptCount returns the number of in-flight auth-attempt
// retention entries. Test-only — production code MUST NOT
// condition behavior on this value (the retention bound is the
// operational gate per SPEC-002 v1.3.5 R-7.9.6 / AC-K.16).
func (s *Server) AuthAttemptCount() int {
	return s.authAttempts.count()
}

// UnauthenticatedPerIPSnapshot returns the current sum of per-IP unauthenticated
// WS handshake counters. Test-only; lets regression tests wait for handler
// goroutines to actually reserve their slots after gobwas.Dial returns.
func (s *Server) UnauthenticatedPerIPSnapshot() int {
	s.unauthPerIPMu.Lock()
	defer s.unauthPerIPMu.Unlock()
	total := 0
	for _, n := range s.unauthPerIP {
		total += n
	}
	return total
}

type pendingPreflight struct {
	providerID string
	assignedID string
	ch         chan PreflightAck
}

func NewServer(cfg config.Config, registry *pool.Registry, logger zerolog.Logger, opts ...Option) *Server {
	// Config validation guarantees a valid deadline whenever strict provider
	// admission is disabled. Parse defensively here as well: a malformed value
	// becomes a zero deadline, which keeps the runtime fail-closed.
	providerAdmissionBridgeDeadline, _ := cfg.AutotuneFeeds.ProviderAdmissionBridgeDeadlineTime()
	s := &Server{
		cfg:                           cfg,
		proofOfWeights:                cfg.ProofOfWeights,
		tier2:                         cfg.Tier2,
		pool:                          registry,
		log:                           logger,
		now:                           func() time.Time { return time.Now().UTC() },
		newUUID:                       func() string { return uuid.NewString() },
		started:                       time.Now().UTC(),
		unauth:                        make(chan struct{}, cfg.ProviderWSMaxUnauthenticatedConn()),
		unauthPerIP:                   map[string]int{},
		losslessnessProfiles:          map[LosslessnessProfileKey]LosslessnessProfileRecord{},
		losslessnessDraftAdmissions:   map[losslessnessDraftAdmissionKey]LosslessnessDraftAdmissionRecord{},
		losslessnessTargetGenerations: map[string]int{},
		losslessnessProfileCursor:     map[string]int{},
		autotuneCatalogEnforced:       cfg.AutotuneFeeds.EnforceProviderAdmission,
		autotuneCatalogBridgeDeadline: providerAdmissionBridgeDeadline,
		version:                       "dev",
	}
	s.authAttempts = newAuthAttemptStore(1024)
	s.bootstrapLimiter = newBootstrapMintLimiter(cfg.Auth)
	s.admission = NewAdmissionManager(cfg.Admission, s.now)
	for _, opt := range opts {
		opt(s)
	}
	if tier2.ModelHashActive(s.tier2) || strings.TrimSpace(s.tier2.ModelHashLegacyUntil) != "" {
		s.scheduleModelHashLegacyDeadline(s.tier2.ModelHashLegacyUntil)
	}
	if s.idlePrewarm != nil {
		s.idlePrewarmQueue = make(chan idlePrewarmRecord, idlePrewarmEventQueueSize)
		go s.runIdlePrewarmRecorder()
	}
	if registry != nil {
		// M3-8d: route the heartbeat verifier through s.catalogRef() so a
		// caller that overrides the catalog via WithCatalog (and the
		// SIGHUP swap of tier2.Default()) is honored on every heartbeat
		// rather than frozen at NewServer time.
		pool.WithModelIdentityVerifier(func(modelID, expectedHash, reportedHash, reportedAlgorithm string) pool.HashStatus {
			return s.verifyProviderModelIdentity(modelID, expectedHash, reportedHash, reportedAlgorithm)
		})(registry)
	}
	if s.autotuneCatalog != nil && !s.autotuneCatalogEnforced && !s.autotuneCatalogBridgeDeadline.IsZero() && registry != nil {
		go s.runAutotuneCatalogBridgeDeadline()
	}
	if cfg.Pool.CanaryEnabled && registry != nil {
		go s.runCanaryLoop()
	}
	if registry != nil {
		go s.runSELivenessLoop()
	}
	if cfg.Pool.LosslessnessProbe.Enabled && registry != nil {
		go s.runLosslessnessProbeLoop()
	}
	if registry != nil {
		// Inject the request-independent buyer-serving predicate so the FR-CAN22 floor
		// and the redundancy count apply the coordinator's routability gates
		// (RoutingEligible + transport-reachable + positive context + not
		// Tier-2-excluded), not just ServingCapable — a busy, negative-slot, or
		// transport-unreachable peer must not lift the floor. Request-dependent
		// context/quota are omitted (deferred to FR-CAN23, see canaryBuyerServing).
		registry.SetBuyerServingPredicate(s.canaryBuyerServing)
	}
	// Issue #582 FIX A + SPEC-032 FR-HG6/B2: bounded active-session trust
	// revalidation. Hardware-trust checks run when the trust checker is wired;
	// strict autotune evidence TTL checks run only when the hello gate is enabled
	// and its catalog+evidence dependencies are wired. Both use the same 30s
	// sweep cadence.
	if (s.providerTrust != nil || (s.autotuneCatalog != nil && s.autotuneEvidence != nil)) && registry != nil {
		go s.runTrustRevalidationLoop()
	}
	return s
}

// canaryBuyerServing reports whether p passes the coordinator's REQUEST-INDEPENDENT
// buyer-routability gates, for the FR-CAN22 last-provider floor. It requires:
//   - RoutingEligible() — state ready AND SlotsFree>0 AND auth/catalog/receipt gates
//     (excludes busy [SlotsFree==0] and negative-slot peers, stored verbatim from
//     heartbeats); AND
//   - transport-reachable — a WS-tunneled peer needs a live, open STORED session
//     (storedSessionFor; excludes the registration/disconnect windows where
//     IsWSTunneled holds but no session is stored), else a non-empty EndpointURL;
//     excludes an HTTPForwardingOnly peer with no endpoint; AND
//   - MaxContextTokens > 0 — a sanity gate excluding the degenerate zero window; AND
//   - not Tier-2-excluded (hash/encryption/attestation) — in-memory config + catalog.
//
// It deliberately does NOT evaluate REQUEST-DEPENDENT eligibility, because the floor
// runs without a request in hand:
//   - per-request context sufficiency (ProviderContextSufficient needs
//     MaxContextTokens >= the request's token estimate, so a peer advertising a tiny
//     positive window — e.g. 1 — passes here yet is filtered per request); and
//   - provisional quota (admission.CheckQuota shares the admission mutex with the
//     synchronous DB write in TryReserveRequest, so calling it under the registry
//     lock would couple pool.mu to that DB write — an availability convoy).
//
// A same-model peer that passes these gates but is filtered per-request (tiny
// context, exhausted quota) can therefore still lift the floor, and buyer routing
// SKIPS it without recording an FR-P11a breaker fault — so the breaker is not a
// universal backstop for that case. This is NOT a regression: the floor only ever
// SPARES a provider the prior canary would have removed (it never removes one the
// old code kept), so the adversarial-peer empty-pool outcome equals the pre-floor
// baseline. Adversarial-safe multi-provider peer-genuineness (full request-aware /
// coordinator-observed-serving eligibility) is deferred to FR-CAN23, with NO
// current-prod impact (single provider, canary disabled). See DECISION_CRITERIA
// Entry 180 / SPEC-031 §14.
func (s *Server) canaryBuyerServing(p pool.Provider) bool {
	if !p.RoutingEligible() {
		return false
	}
	// Transport reachability, matching dispatch. A WS-tunneled peer is dispatchable
	// only via a live, open STORED session — dispatch returns ErrRelayClosed otherwise,
	// e.g. during the registration/disconnect windows where IsWSTunneled holds but
	// the session is not yet stored / already deleted (checked via storedSessionFor,
	// which touches only the sessions map — no pool.mu, so it is safe under the
	// floor's registry lock). An HTTP-forwarding peer needs a non-empty endpoint; a
	// provider-controlled `unknown_message_type` NAK can drop IsWSTunneled without
	// establishing one. Either way an unreachable peer must not lift the floor.
	if p.IsWSTunneled() {
		session, ok := s.storedSessionFor(p.ProviderID, p.AssignedID)
		if !ok || !session.isOpen() {
			return false
		}
	} else if strings.TrimSpace(p.EndpointURL) == "" {
		return false
	}
	// Sanity gate: a zero/negative context window can serve no request. NOTE this
	// does NOT make the peer routable — per-request context sufficiency
	// (MaxContextTokens >= the request's token estimate) is request-dependent and is
	// NOT evaluated here; a peer advertising a tiny positive window (e.g. 1) still
	// passes yet is filtered per-request. That request-dependent adversarial case,
	// like provisional quota, is deferred to FR-CAN23 (see SPEC-031 §14). The floor
	// remains a monotonic improvement — it only ever SPARES a provider the prior
	// canary would have removed — so this is not a regression.
	if p.MaxContextTokens <= 0 {
		return false
	}
	if s.tier2WarmupExcluded(p) {
		return false
	}
	// #768: a peer below the per-model version floor is not routable, so it
	// must not count as a buyer-serving peer either. Silent, like the tier2
	// predicate above it: this runs under the pool registry lock and can be
	// evaluated repeatedly per provider, and the same exclusion is already
	// logged once at the warmup gate.
	if !s.modelVersionFloor(p).Allowed {
		return false
	}
	return true
}

func (s *Server) autotuneCatalogBridgeActive() bool {
	return !s.autotuneCatalogEnforced &&
		!s.autotuneCatalogBridgeDeadline.IsZero() &&
		s.now().Before(s.autotuneCatalogBridgeDeadline)
}

func (s *Server) runAutotuneCatalogBridgeDeadline() {
	delay := time.Until(s.autotuneCatalogBridgeDeadline)
	if delay > 0 {
		timer := time.NewTimer(delay)
		defer timer.Stop()
		<-timer.C
	}
	s.autotuneCatalogBridgeMu.Lock()
	updated := s.pool.ExpireLegacyBridgeAdmissions()
	s.autotuneCatalogBridgeMu.Unlock()
	s.log.Warn().
		Time("autotune_provider_admission_bridge_deadline", s.autotuneCatalogBridgeDeadline).
		Int("legacy_sessions_excluded", updated).
		Msg("provider catalog migration bridge deadline reached; metadata-free sessions excluded from buyer serving")
}

// catalogRef returns the *tier2.Catalog this server reads through. Returns
// the explicit override set by WithCatalog when present; otherwise the
// package singleton via tier2.Default(). Safe under SIGHUP reload because
// tier2.Default() is an atomic.Pointer load.
func (s *Server) catalogRef() *tier2.Catalog {
	if s.catalog != nil {
		return s.catalog
	}
	return tier2.Default()
}

func (s *Server) Admission() *AdmissionManager {
	return s.admission
}

// PoolSnapshot returns connected providers for uptime/trust evaluation hooks.
func (s *Server) PoolSnapshot() []pool.Provider {
	if s == nil || s.pool == nil {
		return nil
	}
	return s.pool.Snapshot()
}

func (s *Server) SetTier2Config(cfg config.Tier2Config) {
	s.tier2Mu.Lock()
	s.tier2 = cfg
	s.tier2Mu.Unlock()
	if tier2.ModelHashActive(cfg) || strings.TrimSpace(cfg.ModelHashLegacyUntil) != "" {
		s.scheduleModelHashLegacyDeadline(cfg.ModelHashLegacyUntil)
	} else {
		s.cancelModelHashLegacyDeadline()
	}
}

func (s *Server) proofOfWeightsConfig() config.ProofOfWeightsConfig {
	s.proofOfWeightsMu.RLock()
	defer s.proofOfWeightsMu.RUnlock()
	return s.proofOfWeights
}

func (s *Server) SetTelemetryDriftEvaluator(evaluator *pow.Evaluator) {
	s.telemetryDriftMu.Lock()
	s.telemetryDrift = evaluator
	s.telemetryDriftGeneration++
	s.telemetryDriftMu.Unlock()
}

func (s *Server) ClearBenchmarkQuarantines() int {
	if s == nil || s.pool == nil {
		return 0
	}
	return s.pool.ClearBenchmarkQuarantines()
}

func (s *Server) telemetryDriftEvaluator() (*pow.Evaluator, uint64) {
	s.telemetryDriftMu.RLock()
	defer s.telemetryDriftMu.RUnlock()
	return s.telemetryDrift, s.telemetryDriftGeneration
}

type ProofOfWeightsReloadResult struct {
	Generation            uint64
	PreQuarantined        int
	Revalidated           int
	Sandboxed             int
	RouteExcluded         int
	StillEvidenceStale    int
	ClearedGateExclusions int
}

func (s *Server) SetProofOfWeightsConfig(next config.ProofOfWeightsConfig) ProofOfWeightsReloadResult {
	s.proofOfWeightsAdmissionMu.Lock()
	defer s.proofOfWeightsAdmissionMu.Unlock()

	result := ProofOfWeightsReloadResult{}
	if next.RequireAutotuneHelloGate && s.pool != nil {
		result.PreQuarantined = s.pool.QuarantineForProofOfWeightsReload()
	}

	s.proofOfWeightsMu.Lock()
	s.proofOfWeights = next
	s.proofOfWeightsGeneration++
	result.Generation = s.proofOfWeightsGeneration
	s.proofOfWeightsMu.Unlock()

	if s.pool == nil {
		return result
	}
	if !next.RequireAutotuneHelloGate {
		for _, provider := range s.pool.Snapshot() {
			if !provider.AdmissionSandboxCredentialBypassed && s.pool.SetAdmissionSandboxed(provider.ProviderID, provider.AssignedID, false) {
				result.ClearedGateExclusions++
			}
			if s.pool.SetAdmissionEvidenceStale(provider.ProviderID, provider.AssignedID, false) {
				result.ClearedGateExclusions++
			}
			if s.pool.SetAdmissionCeilingExcluded(provider.ProviderID, provider.AssignedID, false) {
				result.ClearedGateExclusions++
			}
		}
		return result
	}

	return s.revalidateProofOfWeightsAdmissions(next, result)
}

func (s *Server) revalidateProofOfWeightsAdmissions(cfg config.ProofOfWeightsConfig, result ProofOfWeightsReloadResult) ProofOfWeightsReloadResult {
	if s.autotuneCatalog == nil || s.autotuneEvidence == nil || cfg.AutotuneEvidenceTTLDays <= 0 {
		for _, provider := range s.pool.Snapshot() {
			if s.pool.SetAdmissionEvidenceStale(provider.ProviderID, provider.AssignedID, true) {
				result.StillEvidenceStale++
			}
		}
		return result
	}
	ttl := time.Duration(cfg.AutotuneEvidenceTTLDays) * 24 * time.Hour
	ctx, cancel := context.WithTimeout(context.Background(), trustRevalidationSweepDeadlineCap)
	defer cancel()
	for _, provider := range s.pool.Snapshot() {
		if _, ok := s.sessionFor(provider.ProviderID, provider.AssignedID); !ok {
			continue
		}
		result.Revalidated++
		if provider.MaxAdmittedMinRAMGB <= 0 || !providerHasAdmittedTuple(provider) {
			prior, _, ok := s.pool.SetAdmissionGateFlags(provider.ProviderID, provider.AssignedID, pool.AdmissionGateFlags{
				AdmissionSandboxed: true,
			})
			if ok && !prior.AdmissionSandboxed {
				result.Sandboxed++
			}
			continue
		}
		stale, _ := s.admissionEvidenceStaleVerdict(ctx, provider, ttl)
		if stale {
			prior, _, ok := s.pool.SetAdmissionGateFlags(provider.ProviderID, provider.AssignedID, pool.AdmissionGateFlags{
				AdmissionEvidenceStale: true,
			})
			if ok && !prior.AdmissionEvidenceStale {
				result.StillEvidenceStale++
			}
			continue
		}
		verdict := s.admissionCeilingRouteVerdict(provider)
		prior, _, ok := s.pool.SetAdmissionGateFlags(provider.ProviderID, provider.AssignedID, pool.AdmissionGateFlags{
			AdmissionCeilingExcluded: verdict.excluded,
		})
		if ok && verdict.excluded && !prior.AdmissionCeilingExcluded {
			result.RouteExcluded++
		}
	}
	return result
}

func (s *Server) cancelModelHashLegacyDeadline() {
	s.modelHashLegacyMu.Lock()
	defer s.modelHashLegacyMu.Unlock()
	s.modelHashLegacyGeneration++
	if s.modelHashLegacyTimer != nil {
		s.modelHashLegacyTimer.Stop()
		s.modelHashLegacyTimer = nil
	}
}

func (s *Server) scheduleModelHashLegacyDeadline(raw string) {
	deadline, err := modelidentity.ParseLegacyDeadline(raw)
	s.modelHashLegacyMu.Lock()
	s.modelHashLegacyGeneration++
	generation := s.modelHashLegacyGeneration
	if s.modelHashLegacyTimer != nil {
		s.modelHashLegacyTimer.Stop()
		s.modelHashLegacyTimer = nil
	}
	if err != nil {
		s.modelHashLegacyMu.Unlock()
		return
	}
	if deadline.IsZero() {
		s.modelHashLegacyMu.Unlock()
		s.expireLegacyModelHashAdmissions(s.now())
		return
	}
	delay := deadline.Sub(s.now())
	if delay <= 0 {
		s.modelHashLegacyMu.Unlock()
		s.expireLegacyModelHashAdmissions(deadline)
		return
	}
	s.modelHashLegacyTimer = time.AfterFunc(delay, func() {
		s.modelHashLegacyMu.Lock()
		if generation != s.modelHashLegacyGeneration {
			s.modelHashLegacyMu.Unlock()
			return
		}
		s.modelHashLegacyTimer = nil
		s.modelHashLegacyMu.Unlock()
		s.expireLegacyModelHashAdmissions(deadline)
	})
	s.modelHashLegacyMu.Unlock()
}

func (s *Server) expireLegacyModelHashAdmissions(deadline time.Time) {
	if s.pool == nil {
		return
	}
	expired := s.pool.ExpireLegacyModelHashAdmissions()
	for _, provider := range expired {
		s.observeHashStatusTransition(
			provider.HashStatus,
			pool.HashStatusInvalid,
			provider.ProviderID,
			provider.AssignedID,
			provider.ModelID,
			provider.ModelHash,
		)
		if session, ok := s.storedSessionFor(provider.ProviderID, provider.AssignedID); ok {
			s.closeSession(session, CloseInvalidHello, "model_hash_algorithm_required")
		}
	}
	s.log.Warn().
		Time("model_hash_legacy_until", deadline).
		Int("legacy_sessions_fenced", len(expired)).
		Msg("model hash legacy bridge deadline reached")
}

func (s *Server) RefreshTier2HashStatuses() int {
	cfg := s.tier2Config()
	if !tier2.ModelHashActive(cfg) {
		return s.pool.UpdateHashStatuses(func(pool.Provider) pool.HashStatus {
			return ""
		})
	}
	return s.pool.UpdateHashStatuses(func(provider pool.Provider) pool.HashStatus {
		next := s.verifyProviderModelIdentity(provider.ModelID, provider.ExpectedModelHash, provider.ModelHash, provider.ModelHashAlgorithm)
		s.observeHashStatusTransition(provider.HashStatus, next, provider.ProviderID, provider.AssignedID, provider.ModelID, provider.ModelHash)
		if cfg.RequireHashVerified && (next == pool.HashStatusUncatalogued || next == pool.HashStatusCatalogUnavailable) {
			tier2.LogHashRequiredProviderExcluded(s.log, provider.ProviderID, provider.AssignedID, provider.ModelID, provider.ModelHash, next)
		}
		return next
	})
}

func (s *Server) observeHashStatusTransition(prev, next pool.HashStatus, providerID, assignedID, modelID, reportedHash string) {
	if next == prev {
		return
	}
	tier2.LogProviderHashStatus(s.log, providerID, assignedID, modelID, reportedHash, next)
	if next == pool.HashStatusMismatch && s.modelHashMismatchMetrics != nil {
		s.modelHashMismatchMetrics.IncModelHashMismatch()
	}
}

func (s *Server) tier2Config() config.Tier2Config {
	s.tier2Mu.RLock()
	defer s.tier2Mu.RUnlock()
	return s.tier2
}

func (s *Server) verifyProviderModelIdentity(modelID, expectedHash, reportedHash, reportedAlgorithm string) pool.HashStatus {
	cfg := s.tier2Config()
	algorithm := strings.TrimSpace(reportedAlgorithm)
	if algorithm != "" && (algorithm != modelidentity.SnapshotManifestV1 || !modelidentity.ValidSHA256(reportedHash)) {
		return pool.HashStatusInvalid
	}
	if !tier2.ModelHashActive(cfg) {
		return pool.HashStatusUncatalogued
	}
	if algorithm == "" {
		if modelidentity.LegacyMissingAlgorithmAllowed(cfg.ModelHashLegacyUntil, s.now()) {
			return pool.HashStatusUncatalogued
		}
		return pool.HashStatusInvalid
	}
	if expected := strings.TrimSpace(expectedHash); expected != "" {
		if strings.EqualFold(expected, strings.TrimSpace(reportedHash)) {
			return pool.HashStatusVerified
		}
		return pool.HashStatusMismatch
	}
	if s.autotuneCatalog == nil {
		return pool.HashStatusCatalogUnavailable
	}
	return pool.HashStatusUncatalogued
}

func (s *Server) Handler() http.Handler {
	mux := http.NewServeMux()
	if s.cfg.Explorer.Enabled && s.explorer != nil {
		bindPath := s.cfg.Explorer.BindPath
		mux.Handle(bindPath, s.explorer)
		mux.Handle(strings.TrimSuffix(bindPath, "/"), s.explorer)
	}
	mux.HandleFunc("/ws/provider", s.handleProvider)
	mux.HandleFunc("/healthz", s.handleHealthz)
	mux.HandleFunc("/poolz", s.handlePoolz)
	mux.HandleFunc("/admin/blacklist", s.handleBlacklist)
	mux.HandleFunc("/admin/providers", s.handleAdminProviders)
	mux.HandleFunc("/admin/providers/", s.handleAdminProviders)
	mux.HandleFunc("/admin/provisional", s.handleAdminProvisional)
	mux.HandleFunc("/admin/promote/", s.handleAdminPromote)
	mux.HandleFunc("/admin/reject/", s.handleAdminReject)
	mux.HandleFunc("/admin/provider-auth-policy/seed-cutover", s.handleProviderAuthPolicySeedCutover)
	mux.HandleFunc("/admin/provider-auth-policy/exempt", s.handleProviderAuthPolicyExemptRequest)
	mux.HandleFunc("/admin/provider-auth-policy/exempt/", s.handleProviderAuthPolicyExemptApprove)
	mux.HandleFunc("/admin/hardware-trust/waiting", s.handleHardwareTrustWaiting)
	mux.HandleFunc("/admin/hardware-trust/approve", s.handleHardwareTrustApproveRequest)
	mux.HandleFunc("/admin/hardware-trust/approve/", s.handleHardwareTrustApproveApprove)
	mux.HandleFunc("/admin/hardware-trust/revoke", s.handleHardwareTrustRevoke)
	mux.HandleFunc("/admin/provider-admission-identity/recover", s.handleAdmissionIdentityRecoveryRequest)
	mux.HandleFunc("/admin/provider-admission-identity/recover/", s.handleAdmissionIdentityRecoveryApprove)
	if s.cfg.Auth.GitHubOAuth.Enabled {
		mux.HandleFunc("/v1/auth/github/start", s.handleGitHubStart)
		mux.HandleFunc("/v1/auth/github/callback", s.handleGitHubCallback)
		mux.HandleFunc("/v1/auth/me/providers", s.handleAuthMeProviders)
		mux.HandleFunc("/v1/auth/me/providers/bind", s.handleAuthMeProvidersBind)
		mux.HandleFunc("/v1/auth/logout", s.handleAuthLogout)
		mux.HandleFunc("/v1/install/pair/refresh", s.handleInstallPairRefresh)
		return s.redactedRequestLogMiddleware(mux)
	}
	return mux
}

func (s *Server) handleProvider(w http.ResponseWriter, r *http.Request) {
	conn, _, _, err := gobwas.UpgradeHTTP(r, w)
	if err != nil {
		s.log.Warn().Err(err).Msg("provider websocket upgrade failed")
		s.recordConnectionEvent(providerevents.Event{
			Kind:          providerevents.KindUpgradeFailed,
			Outcome:       providerevents.OutcomeFailure,
			FailureReason: providerevents.ReasonUpgradeFailed,
			AuthStage:     providerevents.AuthStageUpgrade,
			MessageFamily: providerevents.MessageFamilyNone,
			Diagnostic:    "websocket_upgrade_failed",
		})
		return
	}
	s.enableProviderTCPKeepAlive(conn)
	// M1-4 / SECU-1: per-IP gate runs first so one source cannot starve all
	// admissions even within the global unauth budget. Proxy-aware (M1-4
	// follow-up): when nginx fronts the coordinator on loopback, X-Real-IP
	// carries the real client IP — otherwise the per-IP bucket collapses
	// to a single shared 127.0.0.1 slot.
	remoteIP := remoteIPForUnauthSemaphore(r.RemoteAddr, r.Header)
	perIPOK, releasePerIP := s.reserveUnauthenticatedConnForIP(remoteIP)
	if !perIPOK {
		s.rememberCloseEvent(conn, closeEventMeta{authStage: providerevents.AuthStageUpgrade, messageFamily: providerevents.MessageFamilyNone})
		s.close(conn, ClosePoolFull, "too_many_unauthenticated_connections_per_ip")
		time.AfterFunc(100*time.Millisecond, func() { _ = conn.Close() })
		return
	}
	if !s.reserveUnauthenticatedConn() {
		s.rememberCloseEvent(conn, closeEventMeta{authStage: providerevents.AuthStageUpgrade, messageFamily: providerevents.MessageFamilyNone})
		s.close(conn, ClosePoolFull, "too_many_unauthenticated_connections")
		releasePerIP()
		time.AfterFunc(100*time.Millisecond, func() { _ = conn.Close() })
		return
	}
	s.setReadDeadline(conn, s.cfg.ProviderWSHandshakeTimeout())
	auth, ok := s.validateProviderToken(r)
	if !ok {
		s.rememberCloseEvent(conn, closeEventMeta{
			providerID:       auth.providerID,
			authStage:        providerevents.AuthStageUpgrade,
			messageFamily:    providerevents.MessageFamilyNone,
			diagnostic:       "bearer_validation_failed",
			identityVerified: false,
		})
		s.close(conn, CloseInvalidToken, "invalid_token")
		s.releaseUnauthenticatedConn()
		releasePerIP()
		time.AfterFunc(100*time.Millisecond, func() { _ = conn.Close() })
		return
	}
	auth.sourceIP = remoteIP
	s.providerConnWG.Add(1)
	go func() {
		defer s.providerConnWG.Done()
		s.handleConn(conn, auth, func() {
			s.releaseUnauthenticatedConn()
			releasePerIP()
		})
	}()
}

func (s *Server) validateProviderToken(r *http.Request) (providerAuth, bool) {
	authz := r.Header.Get("Authorization")
	if s.cfg.Auth.RequireProviderTokens && s.tokens == nil {
		s.log.Error().Msg("provider token validation is required but no token validator is configured")
		return providerAuth{}, false
	}
	// SPEC-003 v0.8 FR-C9.1 — gating semantics changed at v0.8: prior to
	// v0.8, `s.tokens != nil` implied strict enforcement (tokenless
	// always rejected). With self-serve provisional minting, the token
	// store has dual purpose — issuance AND enforcement — so the
	// enforcement gate now depends on `cfg.Auth.RequireProviderTokens`.
	// When the flag is false, tokenless connects are admitted with
	// validated=false so the v1/v2 ack-write path can mint and return
	// `assigned_provider_token`. When the flag is true, the public
	// onboarding path needs the narrower
	// AllowTokenlessProvisionalBootstrap exception to reach the same
	// self-mint/TOFU gate. Pinned-tier providers that fail the tokenless
	// check are still rejected at `prepareProviderAdmission` rather than
	// at this gate — same close code, same reason string, same blast
	// radius.
	if authz == "" {
		if s.cfg.Auth.RequireProviderTokens {
			if !s.cfg.Auth.AllowTokenlessProvisionalBootstrap {
				return providerAuth{}, false
			}
			if s.issuer == nil {
				s.log.Error().Msg("tokenless provisional bootstrap is enabled but no token issuer is configured")
				return providerAuth{}, false
			}
		}
		return providerAuth{}, true
	}
	if s.tokens == nil {
		return providerAuth{}, true
	}
	const prefix = "Bearer "
	if !strings.HasPrefix(authz, prefix) {
		return providerAuth{}, false
	}
	token := strings.TrimSpace(strings.TrimPrefix(authz, prefix))
	// Validate ordinary and confirmed credentials while atomically recording
	// use. A fresh bootstrap credential remains provisional until the admitted
	// provider-ID-bound hello is confirmed immediately before registration.
	providerID, ok, err := s.tokens.ValidateAndMarkTokenUsed(r.Context(), token)
	if err != nil {
		s.log.Warn().Err(err).Msg("provider token validation failed")
		return providerAuth{}, false
	}
	return providerAuth{validated: ok, providerID: providerID, token: token}, ok
}

func (s *Server) handleConn(conn net.Conn, auth providerAuth, releaseUnauthenticated func()) {
	defer conn.Close()
	defer func() { _ = s.takeCloseEvent(conn) }()
	var releaseOnce sync.Once
	releaseUnauth := func() {
		if releaseUnauthenticated != nil {
			releaseOnce.Do(releaseUnauthenticated)
		}
	}
	defer releaseUnauth()
	var providerID string
	var assignedID string
	defer func() {
		if providerID != "" && assignedID != "" {
			s.handleDisconnect(providerID, assignedID)
		}
	}()

	payload, op, err := s.readClientData(conn, s.directControlReply(conn))
	if err != nil {
		s.rememberCloseEvent(conn, closeEventMeta{
			providerID:    auth.providerID,
			authStage:     providerevents.AuthStageFirstMessage,
			messageFamily: providerevents.MessageFamilyMissing,
			diagnostic:    "first_message_read_failed",
		})
		s.close(conn, CloseInvalidHello, "invalid_hello: read")
		return
	}
	if op != gobwas.OpText {
		s.log.Warn().Str("bad_field", "opcode").Msg("provider first auth message rejected")
		s.rememberCloseEvent(conn, closeEventMeta{
			providerID:    auth.providerID,
			authStage:     providerevents.AuthStageFirstMessage,
			messageFamily: providerevents.MessageFamilyOther,
			diagnostic:    "bad_field=opcode",
		})
		s.close(conn, CloseUnrecognizedAuthMessage, "unrecognized auth message")
		return
	}

	typ, version, badField, err := parseFirstAuthMessageWithField(payload)
	if err != nil {
		if badField == "" {
			badField = "unknown"
		}
		s.log.Warn().
			Str("bad_field", badField).
			Str("message_type", firstAuthMessageTypeForLog(typ)).
			Msg("provider first auth message rejected")
		s.rememberCloseEvent(conn, closeEventMeta{
			providerID:    auth.providerID,
			authStage:     providerevents.AuthStageFirstMessage,
			messageFamily: firstAuthMessageTypeForLog(typ),
			diagnostic:    "bad_field=" + badField,
		})
		s.close(conn, CloseUnrecognizedAuthMessage, "unrecognized auth message")
		return
	}
	switch {
	case typ == "hello" && version == 1:
		providerID, assignedID = s.handleV1Conn(conn, auth, payload, releaseUnauth)
	case typ == "auth_request" && version == 2:
		providerID, assignedID = s.handleV2Conn(conn, auth, payload, releaseUnauth)
	default:
		badField := "dispatch"
		switch typ {
		case "hello", "auth_request":
			badField = "version"
		default:
			badField = "type"
		}
		s.log.Warn().
			Str("bad_field", badField).
			Str("message_type", firstAuthMessageTypeForLog(typ)).
			Msg("provider first auth message rejected")
		s.rememberCloseEvent(conn, closeEventMeta{
			providerID:    auth.providerID,
			authStage:     providerevents.AuthStageFirstMessage,
			messageFamily: firstAuthMessageTypeForLog(typ),
			diagnostic:    "bad_field=" + badField,
		})
		s.close(conn, CloseUnrecognizedAuthMessage, "unrecognized auth message")
	}
}

func firstAuthMessageTypeForLog(typ string) string {
	switch typ {
	case "hello", "auth_request":
		return typ
	case "":
		return "missing"
	default:
		return "other"
	}
}

// provisionalTokenOutcome captures the three possible results of a
// tokenless admission's pre-ack mint decision under the v0.8.4 composed
// FR-C9.4 contract:
//
//   - Skip:        admit without minting, optionally with an AuthState
//     marker (BearerValidated / BearerlessDuplicate / empty).
//   - Minted:      admit with a freshly-minted token in the ack frame.
//   - RejectTOFU:  close the connection with CloseInvalidToken. Fires
//     when the existing row has last_used_at IS NOT NULL
//     (credential-capture closure) or a DB error blocked
//     the gate evaluation (fail closed).
//
// The auth state is carried separately via pool.AuthState so registry +
// routing + billing can distinguish bearer-less-duplicate from other
// admit-tokenless cases (PR #69 fix-pass-3 + fix-pass-4 + PR #78
// composition).
type provisionalTokenOutcome int

const (
	// provisionalTokenSkip — caller MUST NOT include assigned_provider_token
	// in the ack and SHOULD proceed with admission. Triggers: no issuer
	// configured, connect arrived with a validated Bearer, IssueToken DB
	// error (admitted bearer-less, binary retries next reconnect), or
	// IssueToken race-loss (admitted with AuthBearerlessDuplicate marking;
	// non-routable, eviction-defended).
	provisionalTokenSkip provisionalTokenOutcome = iota
	// provisionalTokenMinted — caller MUST include the returned token in
	// the ack frame so the binary can persist it (FR-C9.3).
	provisionalTokenMinted
	// provisionalTokenRejectTOFU — caller MUST close the connection with
	// CloseInvalidToken / "invalid_token". Triggers: last_used_at IS NOT NULL
	// on the existing row (strict TOFU credential-capture closure), or the
	// active-token lookup returned an error (fail closed).
	provisionalTokenRejectTOFU
)

// resolveProvisionalToken implements SPEC-003 v0.8.4 FR-C9.1 (mint),
// Wave 2 token-custody strict TOFU (refuse tokenless mutation for any
// identity with an active token), and race-loss admit-tokenless
// quarantine (PR #69, AuthBearerlessDuplicate). It is
// the single decision point the v1 hello_ack and v2 auth_response
// paths both call before constructing their ack frame.
//
// Returns (outcome, cleartextToken, authState):
//   - outcome:        provisionalTokenSkip | provisionalTokenMinted | provisionalTokenRejectTOFU
//   - cleartextToken: populated only when outcome == provisionalTokenMinted
//   - authState:      pool.AuthState assigned to the provider entry —
//     drives registry eviction defense, buyer routing
//     exclusion, and billing exclusion.
//
// Algorithm:
//  1. If the issuer is not wired: return Skip + empty authState (legacy
//     pre-FR-C9 mode; provider is routable as before).
//  2. If the connect arrived with a validated Bearer: return Skip +
//     authState=BearerValidated (no mint needed).
//  3. Call HasActiveTokenForProvider; if true, an active row already exists
//     and any tokenless replacement would mutate credential custody without
//     proof of the existing token. Return RejectTOFU.
//  4. Mint via IssueToken:
//     - success: return Minted + cleartext + authState=SelfMinted.
//     - ErrActiveTokenAlreadyExists: a concurrent connect won the race
//     between our active-token check and our INSERT. Return Skip + authState=
//     BearerlessDuplicate. The connection is admitted bearer-less,
//     but pool.Registry.Register refuses to evict an existing
//     routable session, and buyer routing + billing exclude this
//     entry (PR #69 fix-pass-3 + fix-pass-4).
//     - other DB error: return Skip + empty authState (transient infra
//     failure; binary retries next reconnect).
//
// Settling-window posture:
// validateProviderToken rejects all tokenless connects at the WS
// upgrade gate when RequireProviderTokens=true, so this function is
// only reached for tokenless admissions during the settling window
// (flag=false). The unique index prevents minting a parallel bearer
// for someone else's provider_id. Whoever races first owns the
// bearer; race-losers are quarantined as AuthBearerlessDuplicate.
//
// authParam is renamed to disambiguate from the auth package import.
func (s *Server) resolveProvisionalToken(authParam providerAuth, providerID, providerName, referralCode string) (provisionalTokenOutcome, string, string, string, pool.AuthState) {
	if s.issuer == nil {
		return provisionalTokenSkip, "", "", "", ""
	}
	if authParam.validated {
		return provisionalTokenSkip, "", "", "", pool.AuthBearerValidated
	}
	ctx := context.Background()
	hasActive, err := s.issuer.HasActiveTokenForProvider(ctx, providerID)
	if err != nil {
		s.log.Warn().Err(err).Str("provider_id", providerID).Msg("FR-C9.4 TOFU gate evaluation failed; closing tokenless connect (fail closed)")
		return provisionalTokenRejectTOFU, "", "", "", ""
	}
	if hasActive {
		s.log.Info().Str("provider_id", providerID).Str("event", "fr_c9_4_tofu_reject").Msg("FR-C9.4 TOFU: tokenless connect refused; an active token already exists for this provider_id and mutation requires existing-token proof or operator recovery")
		return provisionalTokenRejectTOFU, "", "", "", ""
	}
	if s.cfg.Auth.GitHubOAuth.Enabled && s.authStore != nil {
		mint, err := s.authStore.MintAdmissionTokenAndPairOTWithReferral(ctx, providerID, providerName, s.now(), referralCode, s.referralPolicy)
		if err == nil {
			claimURL := ""
			if mint.Paired {
				claimURL = s.claimURL(mint.PairOT)
			}
			s.log.Info().Str("provider_id", providerID).Msg("FR-C9.1 self-serve provisional token minted on first tokenless admission")
			return provisionalTokenMinted, mint.ProviderToken, mint.PairOT, claimURL, pool.AuthSelfMinted
		}
		if errors.Is(err, auth.ErrActiveTokenAlreadyExists) {
			s.log.Info().Str("provider_id", providerID).Str("event", "fr_c9_4_race_loss_admit_quarantined").Msg("FR-C9.4 race-loss: concurrent connect won IssueToken; admitting bearer-less-duplicate (non-routable; operator MUST revoke before legitimate provider can reconnect cleanly)")
			return provisionalTokenSkip, "", "", "", pool.AuthBearerlessDuplicate
		}
		s.log.Warn().Err(err).Str("provider_id", providerID).Msg("FR-C10 pair_ot compound mint failed; falling back to plain FR-C9 provider token mint")
	}
	var token string
	if s.referralPolicy.RequireForRegistration {
		referralIssuer, ok := s.issuer.(interface {
			IssueTokenWithReferral(context.Context, string, string, string, auth.ReferralPolicy) (auth.TokenRecord, string, error)
		})
		if !ok {
			err = errors.New("referral-aware token issuer unavailable")
		} else {
			_, token, err = referralIssuer.IssueTokenWithReferral(ctx, providerID, providerName, referralCode, s.referralPolicy)
		}
	} else {
		_, token, err = s.issuer.IssueToken(ctx, providerID, providerName)
	}
	if err != nil {
		if errors.Is(err, auth.ErrActiveTokenAlreadyExists) {
			// SPEC-003 v0.8.4 race-loss path: a concurrent tokenless
			// connect won the IssueToken race after our active-token
			// custody gate passed. Admit bearer-less-duplicate;
			// the registry eviction defense + routing/billing
			// exclusion neutralize impact.
			s.log.Info().Str("provider_id", providerID).Str("event", "fr_c9_4_race_loss_admit_quarantined").Msg("FR-C9.4 race-loss: concurrent connect won IssueToken; admitting bearer-less-duplicate (non-routable; operator MUST revoke before legitimate provider can reconnect cleanly)")
			return provisionalTokenSkip, "", "", "", pool.AuthBearerlessDuplicate
		}
		// SPEC-003 v0.8.4 (fix-pass-5) — fail-closed on transient DB
		// error. Previously this path returned (Skip, "", "") and the
		// empty AuthState was treated as routable, which would amplify
		// a token-store outage into a routing-admission DoS where
		// attackers could be admitted as fully-routable empty-state
		// sessions (codex security MAJOR-1 on fix-pass-4). Now we
		// surface the failure via AuthMintFailed for /poolz observability
		// and close the connection so the binary retries cleanly on
		// next reconnect.
		s.log.Warn().Err(err).Str("provider_id", providerID).Str("event", "fr_c9_1_mint_failed").Msg("FR-C9.1 self-serve mint failed (transient DB error); closing tokenless connect (fail closed)")
		return provisionalTokenRejectTOFU, "", "", "", pool.AuthMintFailed
	}
	s.log.Info().Str("provider_id", providerID).Msg("FR-C9.1 self-serve provisional token minted on first tokenless admission")
	return provisionalTokenMinted, token, "", "", pool.AuthSelfMinted
}

func (s *Server) resolveSandboxAuthState(conn net.Conn, authParam providerAuth, providerID string) (pool.AuthState, bool) {
	if authParam.validated {
		if !s.confirmAdmittedProviderToken(conn, authParam) {
			return "", false
		}
		return pool.AuthBearerValidated, true
	}
	if s.issuer == nil {
		return "", true
	}
	hasActive, err := s.issuer.HasActiveTokenForProvider(context.Background(), providerID)
	if err != nil {
		s.log.Warn().Err(err).Str("provider_id", providerID).Msg("sandbox TOFU gate evaluation failed; closing tokenless connect (fail closed)")
		s.close(conn, CloseInvalidToken, "invalid_token")
		return "", false
	}
	if hasActive {
		s.log.Info().Str("provider_id", providerID).Str("event", "sandbox_tofu_reject").Msg("sandbox tokenless connect refused; an active token already exists for this provider_id and mutation requires existing-token proof or operator recovery")
		s.close(conn, CloseInvalidToken, "invalid_token")
		return "", false
	}
	return "", true
}

func (s *Server) handleV1Conn(conn net.Conn, connectionAuth providerAuth, payload []byte, releaseUnauth func()) (string, string) {
	hello, badField, err := ParseHello(payload)
	if err != nil {
		s.rememberCloseEvent(conn, closeEventMeta{
			providerID:    connectionAuth.providerID,
			authStage:     providerevents.AuthStageFirstMessage,
			messageFamily: providerevents.MessageFamilyHello,
			diagnostic:    "invalid_hello",
		})
		s.close(conn, CloseInvalidHello, "invalid_hello: "+badField)
		return "", ""
	}
	s.rememberCloseEvent(conn, closeEventMeta{
		providerID:       hello.ProviderID,
		authStage:        providerevents.AuthStageFirstMessage,
		messageFamily:    providerevents.MessageFamilyHello,
		binaryVersion:    hello.BinaryVersion,
		identityVerified: connectionAuth.validated && connectionAuth.providerID != "" && connectionAuth.providerID == hello.ProviderID,
	})
	if hello.Version != 1 {
		s.close(conn, CloseVersionUnsupported, "version_unsupported: protocol version "+itoa(hello.Version))
		return "", ""
	}
	if hello.Tier != 1 {
		s.close(conn, CloseTierUnsupported, "tier_unsupported: tier "+itoa(hello.Tier)+" not supported")
		return "", ""
	}
	if !s.requireCompatibleSet(conn, hello.CompatibilitySetID, false) {
		return "", ""
	}
	if s.tier2Config().RequireEncryptedLeg {
		s.close(conn, CloseTier2KeyExchangeFailed, "tier2_encrypted_leg_required")
		return "", ""
	}
	if hello.CredentialBootstrap {
		s.observeCredentialBootstrap("rejected_v1")
		s.close(conn, CloseInvalidHello, "credential_bootstrap_requires_v2")
		return "", ""
	}
	if auth.IsCredentialBootstrapPrincipal(hello.ProviderID) && s.bootstrapTokens != nil {
		exists, lookupErr := s.bootstrapTokens.BootstrapIdentityExists(context.Background(), hello.ProviderID)
		if lookupErr != nil {
			s.log.Warn().Err(lookupErr).Str("provider_id", hello.ProviderID).Msg("bootstrap identity v1 downgrade lookup failed")
			s.close(conn, CloseIdentitySignatureRequired, "bootstrap_identity_lookup_failed")
			return "", ""
		}
		if exists {
			s.close(conn, CloseIdentitySignatureRequired, "bootstrap_identity_requires_v2")
			return "", ""
		}
	}
	if _, found, blocked := s.durableIdentitySignaturePubkey(context.Background(), hello.ProviderID); found || blocked {
		s.close(conn, CloseIdentitySignatureRequired, "durable_identity_requires_v2")
		return "", ""
	}
	s.proofOfWeightsAdmissionMu.RLock()
	admissionLockHeld := true
	defer func() {
		if admissionLockHeld {
			s.proofOfWeightsAdmissionMu.RUnlock()
		}
	}()
	entry, ok := s.prepareProviderAdmission(conn, connectionAuth, hello)
	if !ok {
		return "", ""
	}
	registered := false
	reservedAdmission := false
	defer func() {
		if !registered && reservedAdmission && entry.Tier == pool.TierProvisional {
			s.admission.ReleasePendingProvisional()
		}
	}()
	var assignedProviderToken, pairOT, claimURL string
	var authState pool.AuthState
	// SPEC-003 FR-C9.1/FR-C9.2 plus Wave 2 token custody:
	// reject any tokenless connect for a provider_id that already has
	// an active token; keep the race-loss quarantine for concurrent
	// first-token mints. On RejectTOFU close;
	// on Minted embed the token in hello_ack; on Skip admit with
	// the provided AuthState (BearerValidated / BearerlessDuplicate /
	// empty) and let the registry eviction defense + RoutingEligible
	// gates take over.
	if entry.AdmissionSandboxed {
		if tier, ok := s.reserveProviderAdmission(conn, hello, entry.Tier == pool.TierPinned); !ok {
			return "", ""
		} else {
			entry.Tier = tier
			reservedAdmission = true
		}
		var ok bool
		authState, ok = s.resolveSandboxAuthState(conn, connectionAuth, entry.ProviderID)
		if !ok {
			return "", ""
		}
		entry.AdmissionSandboxCredentialBypassed = authState != pool.AuthBearerValidated
		entry.Tier = s.commitProviderAdmission(hello, entry.Tier == pool.TierPinned)
	} else {
		if tier, ok := s.reserveProviderAdmission(conn, hello, entry.Tier == pool.TierPinned); !ok {
			return "", ""
		} else {
			entry.Tier = tier
			reservedAdmission = true
		}
		outcome, token, ot, url, resolvedAuthState := s.resolveProvisionalToken(connectionAuth, entry.ProviderID, hello.Hostname, hello.ReferralCode)
		if outcome == provisionalTokenRejectTOFU {
			s.close(conn, CloseInvalidToken, "invalid_token")
			return "", ""
		}
		if !s.confirmAdmittedProviderToken(conn, connectionAuth) {
			return "", ""
		}
		assignedProviderToken = token
		pairOT = ot
		claimURL = url
		authState = resolvedAuthState
		entry.Tier = s.commitProviderAdmission(hello, entry.Tier == pool.TierPinned)
	}
	entry.AuthState = authState
	session, _ := s.registerProviderSession(conn, entry)
	if session == nil {
		// Eviction defense fired: bearer-less duplicate tried to
		// displace a routable session for the same provider_id.
		s.close(conn, CloseInvalidToken, "invalid_token")
		return "", ""
	}
	registered = true
	if reservedAdmission && entry.Tier == pool.TierProvisional {
		s.admission.ReleasePendingProvisional()
	}
	releaseUnauth()
	s.proofOfWeightsAdmissionMu.RUnlock()
	admissionLockHeld = false

	ack := HelloAck{
		Type:                      "hello_ack",
		CoordinatorVersion:        1,
		AssignedID:                entry.AssignedID,
		HeartbeatIntervalS:        int(s.cfg.HeartbeatInterval().Seconds()),
		Tier:                      string(entry.Tier),
		RecommendedBinaryVersion:  s.gatedRecommendedBinaryVersion(hello.CompatibilitySetID),
		RequiredBinaryVersion:     s.cfg.CoordinatorAdvertisedVersion.RequiredBinaryVersion,
		AutoupdateDrainExtensions: true,
		AssignedProviderToken:     assignedProviderToken,
		PairOT:                    pairOT,
		ClaimURL:                  claimURL,
		AuthState:                 string(authState),
	}
	s.populateCatalogHelloAck(&ack)
	s.populateCompatibilityHelloAck(&ack, hello.CompatibilitySetID)
	b, err := json.Marshal(ack)
	if err != nil {
		// runWriter is already running for `session`; route the Close through
		// it instead of writing directly to conn so we don't race an in-flight
		// frame on the wire.
		s.closeSession(session, CloseInvalidHello, "invalid_hello: ack")
		return "", ""
	}
	if err := session.send(b); err != nil {
		s.log.Warn().Err(err).Str("provider_id", hello.ProviderID).Msg("hello_ack write failed")
		return "", ""
	}
	if s.cfg.Pool.WarmupGateEnabled {
		s.startWarmupGate(*entry)
	}
	s.readProviderLoop(conn, entry.ProviderID, entry.AssignedID)
	return entry.ProviderID, entry.AssignedID
}

func (s *Server) handleV2Conn(conn net.Conn, connectionAuth providerAuth, payload []byte, releaseUnauth func()) (string, string) {
	initial, initialPresence, badField, err := ParseAuthRequest(payload)
	if err != nil || initial.Stage != "initial" {
		if badField == "" {
			badField = "stage"
		}
		s.log.Warn().Str("bad_field", badField).Msg("provider auth_request initial rejected")
		s.rememberCloseEvent(conn, closeEventMeta{
			providerID:    connectionAuth.providerID,
			authStage:     providerevents.AuthStageFirstMessage,
			messageFamily: providerevents.MessageFamilyAuthRequest,
			diagnostic:    "bad_field=" + badField,
		})
		// SPEC-002 v1.3.5 §11 AC-K.15 / SPEC-010 v1.5 R-3.1.9 — when
		// initial-stage parse fails on a SPEC-010 catalog validation
		// rule, surface the LOCKED reason substring on the wire so
		// the AC-K.15 grep-based test oracle holds. Envelope-level
		// and stage-mismatch failures keep the existing generic
		// rejection.
		if isSpec010CatalogBadField(badField) {
			s.sendAuthRejection(conn, "bad_request", badField)
			s.close(conn, CloseInvalidHello, badField)
			return "", ""
		}
		s.close(conn, CloseUnrecognizedAuthMessage, "unrecognized auth message")
		return "", ""
	}
	s.rememberCloseEvent(conn, closeEventMeta{
		providerID:       initial.ProviderID,
		authStage:        providerevents.AuthStageFirstMessage,
		messageFamily:    providerevents.MessageFamilyAuthRequest,
		binaryVersion:    initial.BinaryVersion,
		identityVerified: connectionAuth.validated && connectionAuth.providerID != "" && connectionAuth.providerID == initial.ProviderID,
	})
	if !s.requireCompatibleSet(conn, initial.CompatibilitySetID, true) {
		return "", ""
	}
	initialTranscriptHash, err := initialAuthTranscriptHash(payload)
	if err != nil {
		s.close(conn, CloseInvalidHello, "invalid_auth_request: transcript")
		return "", ""
	}
	tier2Cfg := s.tier2Config()
	selectedAEAD, ok := negotiateAEAD(initial.Tier2Capabilities.AEADSuites, tier2Cfg)
	if !ok || !initial.Tier2Capabilities.EncryptedLeg {
		s.close(conn, CloseInvalidHello, "no_common_aead_suite")
		return "", ""
	}
	providerPublic, _, err := tier2.ParseX25519PublicKey(initial.ProviderECDHPublicKey)
	if err != nil {
		s.close(conn, CloseTier2KeyExchangeFailed, "tier2_key_exchange_failed")
		return "", ""
	}
	var entry *pool.Provider
	if initial.CredentialBootstrap {
		entry, ok = s.prepareCredentialBootstrap(conn, connectionAuth, initial)
	} else {
		entry, ok = s.prepareProviderAdmission(conn, connectionAuth, initial.Hello())
	}
	if !ok {
		return "", ""
	}
	coordinatorPrivate, coordinatorPublicRaw, err := tier2.NewX25519Keypair()
	if err != nil {
		s.close(conn, CloseTier2KeyExchangeFailed, "tier2_key_exchange_failed")
		return "", ""
	}
	keys, err := tier2.DerivePillarBKeys(coordinatorPrivate, providerPublic, initial.ProviderID, entry.AssignedID, selectedAEAD)
	if err != nil {
		s.close(conn, CloseTier2KeyExchangeFailed, "tier2_key_exchange_failed")
		return "", ""
	}
	challengeBytes, err := randomBytes(32)
	if err != nil {
		s.close(conn, CloseTier2KeyExchangeFailed, "tier2_key_exchange_failed")
		return "", ""
	}
	authAttemptID := "auth-" + s.newUUID()
	s.rememberCloseEvent(conn, closeEventMeta{
		providerID:       initial.ProviderID,
		sessionID:        entry.AssignedID,
		attemptID:        authAttemptID,
		authStage:        providerevents.AuthStageProof,
		messageFamily:    providerevents.MessageFamilyAuthRequest,
		binaryVersion:    initial.BinaryVersion,
		identityVerified: connectionAuth.validated && connectionAuth.providerID != "" && connectionAuth.providerID == initial.ProviderID,
	})
	challengeExpiresAt := s.now().Add(10 * time.Minute).UTC()
	// SPEC-002 v1.3.5 §7.9 + R-7.9.8 — L-1 baseline gate:
	// create retention state only if the initial-stage frame
	// carried at least one SPEC-010 field. Absence of both means
	// a pre-SPEC-010 (or single-entry-default v1.3) binary —
	// no retention entry, no defer, no metric.
	supportedModelsPresent := initialPresence.SupportedModels
	publishesPresent := initialPresence.PublishesSupportedModels
	retainSpec010 := supportedModelsPresent || publishesPresent
	durableAdmissionIdentity := false
	identities, supportsAdmissionIdentity := s.bootstrapTokens.(admissionIdentityStore)
	if !initial.CredentialBootstrap && supportsAdmissionIdentity {
		var lookupErr error
		durableAdmissionIdentity, lookupErr = identities.AdmissionIdentityExists(context.Background(), initial.ProviderID)
		if lookupErr != nil {
			s.log.Warn().Err(lookupErr).Str("provider_id", initial.ProviderID).Msg("admission identity proof requirement lookup failed")
			s.close(conn, CloseIdentitySignatureRequired, "bootstrap_identity_lookup_failed")
			return "", ""
		}
	}
	identityEnrollmentOffered := !initial.CredentialBootstrap && supportsAdmissionIdentity &&
		connectionAuth.validated && connectionAuth.providerID == initial.ProviderID &&
		len(initial.ProviderAdmissionPubkey) == ed25519.PublicKeySize
	identityVerificationRequired := !initial.CredentialBootstrap &&
		(s.identitySignatures != nil || durableAdmissionIdentity || identityEnrollmentOffered)
	retainAuthAttempt := retainSpec010 || identityVerificationRequired || initial.CredentialBootstrap
	if retainAuthAttempt {
		state := AuthAttemptState{
			AuthAttemptID:            authAttemptID,
			ProviderID:               initial.ProviderID,
			SupportedModels:          append([]string(nil), initial.SupportedModels...),
			PublishesSupportedModels: initial.PublishesSupportedModels,
			SupportedModelsPresent:   supportedModelsPresent,
			PublishesPresent:         publishesPresent,
			BinaryVersion:            initial.BinaryVersion,
			ProviderECDHPublicKey:    initial.ProviderECDHPublicKey,
			InitialTranscriptSHA256:  initialTranscriptHash,
			StartedAt:                s.now(),
			ExpiresAt:                challengeExpiresAt,
		}
		// R-7.9.6 / AC-K.16 — defensive 1024 bound. Reject
		// BEFORE creating the entry; tryReserve does the test +
		// insert atomically.
		if !s.authAttempts.tryReserve(state) {
			s.sendAuthRejection(conn, "too_many_auth_attempts", "auth-attempt retention bound exceeded")
			s.close(conn, ClosePoolFull, "too_many_auth_attempts")
			return "", ""
		}
		// R-7.9.7 — defer-based release scoped to the
		// auth-attempt, installed AFTER reserve and BEFORE
		// auth_challenge write. Any terminal path (proof success,
		// proof reject, expiry, disconnect-before-proof, read/
		// parse error, challenge write failure) hits this defer.
		defer s.authAttempts.release(authAttemptID)
	}
	challenge := AuthChallenge{
		Type:                     "auth_challenge",
		Version:                  2,
		AuthAttemptID:            authAttemptID,
		AssignedID:               entry.AssignedID,
		AttestationChallenge:     base64.RawURLEncoding.EncodeToString(challengeBytes),
		AttestationFormats:       append([]string(nil), tier2Cfg.AttestationFormats...),
		CoordinatorECDHPublicKey: base64.RawURLEncoding.EncodeToString(coordinatorPublicRaw),
		SelectedAEADSuite:        selectedAEAD,
		SelectedAEAD:             selectedAEAD,
		KeyID:                    keys.KeyID,
		ExpiresAt:                challengeExpiresAt.Format(time.RFC3339),
	}
	if !initial.CredentialBootstrap && identityVerificationRequired {
		selection := s.durableIdentitySignatureSelection(context.Background(), initial)
		if selection.Found {
			verificationPubkey := selection.VerificationPubkey
			if initial.ProviderAdmissionRecovery &&
				len(initial.ProviderAdmissionPubkey) == ed25519.PublicKeySize &&
				!bytes.Equal(initial.ProviderAdmissionPubkey, selection.ActivePubkey) {
				verificationPubkey = initial.ProviderAdmissionPubkey
			}
			challenge.AdmissionIdentityPubkey = base64.StdEncoding.EncodeToString(verificationPubkey)
			challenge.AdmissionIdentityGeneration = selection.Generation
			if auth.IsCredentialBootstrapPrincipal(initial.ProviderID) {
				challenge.BootstrapIdentityPubkey = challenge.AdmissionIdentityPubkey
			}
		} else if !selection.Blocked && identityEnrollmentOffered {
			challenge.AdmissionIdentityPubkey = base64.StdEncoding.EncodeToString(initial.ProviderAdmissionPubkey)
			challenge.AdmissionIdentityGeneration = 1
		}
	}
	rawChallenge, err := json.Marshal(challenge)
	if err != nil {
		s.close(conn, CloseTier2KeyExchangeFailed, "tier2_key_exchange_failed")
		return "", ""
	}
	if err := s.writeServerText(conn, rawChallenge); err != nil {
		s.log.Warn().Err(err).Str("provider_id", initial.ProviderID).Msg("auth_challenge write failed")
		return "", ""
	}

	s.setReadDeadline(conn, s.cfg.ProviderWSHandshakeTimeout())
	proofPayload, op, err := s.readClientData(conn, s.directControlReply(conn))
	if err != nil {
		s.close(conn, CloseInvalidHello, "invalid_auth_request: read")
		return "", ""
	}
	if op != gobwas.OpText {
		s.close(conn, CloseInvalidHello, "invalid_auth_request: type")
		return "", ""
	}
	proof, proofPresence, badField, err := ParseAuthRequest(proofPayload)
	if err != nil || proof.Stage != "proof" {
		if badField == "" {
			badField = "stage"
		}
		s.log.Warn().Str("bad_field", badField).Msg("provider auth_request proof rejected")
		s.sendAuthRejection(conn, "invalid_auth_request", "invalid auth_request")
		s.close(conn, CloseInvalidHello, "invalid_auth_request: "+badField)
		return "", ""
	}
	if proof.AuthAttemptID != authAttemptID || proof.ProviderID != initial.ProviderID ||
		proof.CredentialBootstrap != initial.CredentialBootstrap || proof.ReferralCode != initial.ReferralCode ||
		s.now().After(challengeExpiresAt) {
		s.sendAuthRejection(conn, "attestation_failed", "attestation failed")
		s.close(conn, CloseTier2AttestationFailed, "tier2_attestation_failed")
		return "", ""
	}
	retained, retainedOK := AuthAttemptState{}, false
	if retainAuthAttempt {
		retained, retainedOK = s.authAttempts.lookup(authAttemptID)
		if !retainedOK {
			s.sendAuthRejection(conn, "attestation_failed", "attestation failed")
			s.close(conn, CloseTier2AttestationFailed, "tier2_attestation_failed")
			return "", ""
		}
	}
	if initial.CredentialBootstrap && (!retainedOK || !verifyCredentialBootstrapIdentity(initial, proof, retained, challenge)) {
		s.observeCredentialBootstrap("rejected_identity")
		s.sendAuthRejection(conn, "bootstrap_identity_proof_required", "bootstrap_identity_proof_required")
		s.close(conn, CloseIdentitySignatureRequired, "bootstrap_identity_proof_required")
		return "", ""
	}
	identityProof := identityProofResult{}
	if identityVerificationRequired {
		identityProof = s.verifyIdentitySignature(context.Background(), initial, proof, retained, connectionAuth)
		if !identityProof.Accepted {
			s.sendAuthRejection(conn, "identity_signature_required", "identity_signature_required")
			s.close(conn, CloseIdentitySignatureRequired, "identity_signature_required")
			return "", ""
		}
	}
	// SPEC-002 v1.3.5 §7.8 R-7.8.7 + AC-K.3 — when proof carries
	// SPEC-010 fields, they MUST byte-identical-compare to the
	// retained initial-stage values after NFC + ASCII case-fold.
	// Absent proof fields = no comparison (accept). The locked
	// test oracle is the exact substring
	// "supported_models mismatch between auth_request stages".
	if retainSpec010 {
		if retainedOK && proofPresence.SupportedModels {
			if !supportedModelsEqualUnderNFCASCIIFold(retained.SupportedModels, proof.SupportedModels) {
				s.sendAuthRejection(conn, "bad_request", "supported_models mismatch between auth_request stages")
				s.close(conn, CloseInvalidHello, "supported_models mismatch between auth_request stages")
				return "", ""
			}
		}
		if retainedOK && proofPresence.PublishesSupportedModels {
			if proof.PublishesSupportedModels != retained.PublishesSupportedModels {
				s.sendAuthRejection(conn, "bad_request", "publishes_supported_models mismatch between auth_request stages")
				s.close(conn, CloseInvalidHello, "publishes_supported_models mismatch between auth_request stages")
				return "", ""
			}
		}
	}
	attestResult := tier2.VerifyAttestationTokenExtWithCatalog(proof.AttestationToken, tier2Cfg, challengeBytes, authAttemptID, initial.ProviderID, initial.ProviderECDHPublicKey, entry.ModelID, s.catalogRef(), s.now(), s.log)
	attestationStatus := attestResult.Status
	if tier2Cfg.RequireAttestation && attestationStatus != pool.AttestationStatusAttested {
		s.sendAuthRejection(conn, string(attestationStatus), string(attestationStatus))
		s.close(conn, CloseTier2AttestationFailed, "tier2_attestation_failed")
		return "", ""
	}
	if initial.CredentialBootstrap {
		if !s.bootstrapLimiter.allow(connectionAuth.sourceIP, entry.ProviderID, s.now()) {
			s.observeCredentialBootstrap("rejected_rate")
			s.sendAuthRejection(conn, "credential_bootstrap_rate_limited", "credential bootstrap rate limited")
			s.close(conn, CloseProvisionalRateLimited, "credential_bootstrap_rate_limited")
			return "", ""
		}
		mint, err := s.bootstrapTokens.MintBootstrapToken(context.Background(), auth.BootstrapMintRequest{
			ProviderID:          entry.ProviderID,
			ProviderName:        initial.Hostname,
			SourceIP:            connectionAuth.sourceIP,
			ReceiptPubkey:       append([]byte(nil), initial.ProviderReceiptPubkey...),
			Now:                 s.now(),
			TTL:                 time.Duration(s.cfg.Auth.CredentialBootstrapTokenTTLS) * time.Second,
			PerIPLimitPerHour:   s.cfg.Auth.CredentialBootstrapMintsPerIPHour,
			PerProviderPerHour:  s.cfg.Auth.CredentialBootstrapMintsPerIDHour,
			GlobalLimitPerHour:  s.cfg.Auth.CredentialBootstrapMintsGlobalHour,
			UnconfirmedIDMax:    s.cfg.Auth.CredentialBootstrapUnconfirmedMax,
			OutstandingTokenMax: s.cfg.Auth.CredentialBootstrapOutstandingMax,
			IdentityRetention:   time.Duration(s.cfg.Auth.CredentialBootstrapIdentityRetentionS) * time.Second,
			ReferralCode:        initial.ReferralCode,
			ReferralPolicy:      s.referralPolicy,
		})
		if err != nil {
			s.rejectCredentialBootstrap(conn, err)
			return "", ""
		}
		response := AuthResponse{
			Type: "auth_response", Version: 2, Status: "accepted", AssignedID: entry.AssignedID,
			HeartbeatIntervalS: int(s.cfg.HeartbeatInterval().Seconds()), Tier: string(pool.TierProvisional),
			AssignedProviderToken: mint.ProviderToken,
			IdentityAdmissionMode: identityAdmissionSignature,
			IdentityGeneration:    1,
			Tier2Session: &AuthTier2Session{
				EncryptedLeg: AuthEncryptedLegSession{
					Enabled: true, Alg: selectedAEAD, KID: keys.KeyID,
					RekeyAfterRequests:             tier2Cfg.EncryptedLegRekeyAfterRequests,
					RekeyAfterSeconds:              tier2Cfg.EncryptedLegRekeyAfterSeconds,
					ResponseChunkPlaintextEnvelope: initial.Tier2Capabilities.ResponseChunkPlaintextEnvelope,
					InBandAEADRekeyV1:              initial.Tier2Capabilities.InBandAEADRekeyV1,
				},
				Attestation: AuthAttestationSession{Status: string(attestationStatus), RAMTierAttested: false},
				ModelHash:   AuthModelHashSession{Status: string(entry.HashStatus)},
			},
		}
		s.populateCatalogAuthResponse(&response)
		s.populateCompatibilityAuthResponse(&response, initial.CompatibilitySetID)
		rawResponse, err := json.Marshal(response)
		if err != nil || s.writeServerText(conn, rawResponse) != nil {
			return "", ""
		}
		if mint.Replaced {
			s.observeCredentialBootstrap("recovered")
		} else {
			s.observeCredentialBootstrap("minted")
		}
		// The unauthenticated global/per-IP semaphores remain held until the
		// credential-bearing response has been completely written.
		releaseUnauth()
		return "", ""
	}
	entry.EncryptedLeg = true
	entry.AttestationStatus = attestationStatus
	if attestResult.SEResult != nil {
		entry.SEPublicKey = append([]byte(nil), attestResult.SEResult.SEPublicKey...)
		entry.AttestationTier = pool.AttestationTierSelfSigned
	}
	if len(initial.ProviderReceiptPubkey) > 0 {
		entry.ReceiptPubkey = append([]byte(nil), initial.ProviderReceiptPubkey...)
	} else {
		s.log.Info().
			Str("provider_id", initial.ProviderID).
			Bool("receipt_omitted", true).
			Str("reason", "no_keypair").
			Msg("provider receipt public key omitted")
	}
	// SPEC-002 v1.3.5 §3.X.1 / §3.X.2 + SPEC-010 v1.5 R-3.3.1 /
	// R-3.3.2 — populate the catalog onto Provider. The fallback
	// synthesis [ModelID] applies when supported_models was
	// absent on the wire OR when the parsed slice is empty
	// (pre-SPEC-010 binary, defensive guard).
	if len(initial.SupportedModels) > 0 {
		entry.SupportedModels = append([]string(nil), initial.SupportedModels...)
	} else {
		entry.SupportedModels = []string{entry.ModelID}
	}
	entry.PublishesSupportedModels = initial.PublishesSupportedModels
	entry.Tier2Session = &pool.Tier2Session{
		AEADSuite:                      selectedAEAD,
		ResponseChunkPlaintextEnvelope: initial.Tier2Capabilities.ResponseChunkPlaintextEnvelope,
		InBandAEADRekeyV1:              initial.Tier2Capabilities.InBandAEADRekeyV1,
		C2PKey:                         keys.C2PKey,
		P2CKey:                         keys.P2CKey,
		C2PNonceBase:                   keys.C2PNonceBase,
		P2CNonceBase:                   keys.P2CNonceBase,
		KeyID:                          keys.KeyID,
		StartedAt:                      s.now(),
	}
	if retainAuthAttempt {
		// SPEC-002 v1.3.5 §7.9 — explicit early release so the
		// retention entry does not persist for the WS-session lifetime
		// (handleV2Conn does not return until readProviderLoop exits,
		// which for a healthy provider is hours or days). The auth-
		// handler-scoped defer at the top of this function remains as
		// the safety net for terminal failure paths between initial
		// parse and proof acceptance. Double-release is a harmless
		// no-op delete.
		s.authAttempts.release(authAttemptID)
	}
	// SPEC-003 v0.8.4 FR-C9.1/FR-C9.2/FR-C9.4 — v2 mirrors v1 composed
	// flow: RejectTOFU closes; Minted embeds; Skip admits with the
	// provided AuthState; eviction defense protects existing routable
	// sessions from bearer-less duplicates.
	s.proofOfWeightsAdmissionMu.RLock()
	admissionLockHeld := true
	defer func() {
		if admissionLockHeld {
			s.proofOfWeightsAdmissionMu.RUnlock()
		}
	}()
	if s.proofOfWeightsConfig().RequireAutotuneHelloGate {
		admissionObservation, gateOK := s.checkAutotuneHelloGate(conn, initial.Hello())
		if !gateOK {
			return "", ""
		}
		entry.MaxAdmittedModelKey = admissionObservation.MaxAdmittedModelKey
		entry.MaxAdmittedModelID = admissionObservation.MaxAdmittedModelID
		entry.MaxAdmittedMinRAMGB = admissionObservation.MaxAdmittedMinRAMGB
		entry.AdmissionSandboxed = admissionObservation.Sandboxed
		// FIX B (issue #582): admitted hardware-trust tuple for the revalidation sweep.
		entry.AdmittedHardwareIdentityHash = admissionObservation.AdmittedTuple.HardwareIdentityHash
		entry.AdmittedChipNormalized = admissionObservation.AdmittedTuple.ChipNormalized
		entry.AdmittedUnifiedMemoryGB = admissionObservation.AdmittedTuple.UnifiedMemoryGB
	}
	registered := false
	reservedAdmission := false
	defer func() {
		if !registered && reservedAdmission && entry.Tier == pool.TierProvisional {
			s.admission.ReleasePendingProvisional()
		}
	}()
	var assignedProviderToken, pairOT, claimURL string
	var authState pool.AuthState
	if entry.AdmissionSandboxed {
		if tier, ok := s.reserveProviderAdmission(conn, initial.Hello(), entry.Tier == pool.TierPinned); !ok {
			return "", ""
		} else {
			entry.Tier = tier
			reservedAdmission = true
		}
		var ok bool
		authState, ok = s.resolveSandboxAuthState(conn, connectionAuth, entry.ProviderID)
		if !ok {
			return "", ""
		}
		entry.AdmissionSandboxCredentialBypassed = authState != pool.AuthBearerValidated
		entry.Tier = s.commitProviderAdmission(initial.Hello(), entry.Tier == pool.TierPinned)
	} else {
		// Reserve after the post-challenge evidence recheck, but defer the durable
		// admission record until credential minting succeeds.
		if tier, ok := s.reserveProviderAdmission(conn, initial.Hello(), entry.Tier == pool.TierPinned); !ok {
			return "", ""
		} else {
			entry.Tier = tier
			reservedAdmission = true
		}
		outcome, token, ot, url, resolvedAuthState := s.resolveProvisionalToken(connectionAuth, entry.ProviderID, initial.Hostname, initial.ReferralCode)
		if outcome == provisionalTokenRejectTOFU {
			s.close(conn, CloseInvalidToken, "invalid_token")
			return "", ""
		}
		if !s.confirmAdmittedProviderToken(conn, connectionAuth) {
			return "", ""
		}
		assignedProviderToken = token
		pairOT = ot
		claimURL = url
		authState = resolvedAuthState
		if len(identityProof.EnrollmentPubkey) > 0 {
			identities, ok := s.bootstrapTokens.(admissionIdentityStore)
			if !ok {
				s.close(conn, CloseIdentitySignatureRequired, "identity_enrollment_unavailable")
				return "", ""
			}
			if err := identities.BindAdmissionIdentity(
				context.Background(), initial.ProviderID, connectionAuth.token,
				identityProof.EnrollmentPubkey, s.now(),
			); err != nil {
				s.log.Warn().Err(err).Str("provider_id", initial.ProviderID).Msg("durable admission identity enrollment failed")
				s.close(conn, CloseIdentitySignatureRequired, "identity_enrollment_failed")
				return "", ""
			}
			s.log.Info().
				Str("provider_id", initial.ProviderID).
				Int("identity_generation", identityProof.Generation).
				Msg("durable admission identity enrolled")
		}
		if len(identityProof.RotationPubkey) > 0 {
			rotations, ok := s.bootstrapTokens.(admissionIdentityRotationStore)
			if !ok {
				s.close(conn, CloseIdentitySignatureRequired, "identity_rotation_unavailable")
				return "", ""
			}
			state, err := rotations.RotateAdmissionIdentity(
				context.Background(), initial.ProviderID, connectionAuth.token,
				identityProof.VerifiedPubkey, identityProof.RotationPubkey,
				identityProof.Generation, s.now(),
			)
			if err != nil {
				s.log.Warn().Err(err).Str("provider_id", initial.ProviderID).Msg("durable admission identity rotation failed")
				s.close(conn, CloseIdentitySignatureRequired, "identity_rotation_failed")
				return "", ""
			}
			identityProof.Generation = state.Generation
			identityProof.ActivePubkey = append([]byte(nil), state.CurrentPublicKey...)
			identityProof.PreviousValidUntil = state.PreviousValidUntil
			s.log.Info().
				Str("provider_id", initial.ProviderID).
				Int("identity_generation", state.Generation).
				Msg("durable admission identity rotated")
		}
		if len(identityProof.RecoveryPubkey) > 0 {
			rotations, ok := s.bootstrapTokens.(admissionIdentityRotationStore)
			if !ok {
				s.close(conn, CloseIdentitySignatureRequired, "identity_recovery_unavailable")
				return "", ""
			}
			state, authorization, err := rotations.RecoverAdmissionIdentity(
				context.Background(), initial.ProviderID, connectionAuth.token,
				identityProof.ActivePubkey, identityProof.RecoveryPubkey,
				identityProof.Generation, s.now(),
			)
			if err != nil {
				s.log.Warn().Err(err).Str("provider_id", initial.ProviderID).Msg("durable admission identity recovery failed")
				s.sendAuthRejection(conn, "identity_signature_required", "identity_signature_required")
				s.close(conn, CloseIdentitySignatureRequired, "identity_recovery_failed")
				return "", ""
			}
			identityProof.Generation = state.Generation
			identityProof.ActivePubkey = append([]byte(nil), state.CurrentPublicKey...)
			identityProof.RecoveryGrantedBy = authorization.ApprovedBy
			s.log.Warn().
				Str("provider_id", initial.ProviderID).
				Str("recovery_authorization_id", authorization.PendingID).
				Str("incident_id", authorization.IncidentID).
				Str("granted_by", identityProof.RecoveryGrantedBy).
				Int("identity_generation", state.Generation).
				Msg("durable admission identity recovered under operator authorization")
		}
		entry.Tier = s.commitProviderAdmission(initial.Hello(), entry.Tier == pool.TierPinned)
	}
	entry.AuthState = authState
	// Issue #582 FIX A: no post-mint hardware-trust re-check. Trust was authorized
	// at the hello gate (checkAutotuneHelloGate) BEFORE resolveProvisionalToken
	// committed the token/PairOT/referral above; refusing here would strand a
	// minted token. The bounded revalidation sweep evicts (never refuses) a
	// session whose trust lapses after commit.
	session, refusal := s.registerProviderSession(conn, entry)
	if session == nil {
		switch refusal {
		case pool.RegisterRefusalReceiptRotationGraceActive:
			s.sendAuthRejection(conn, "receipt_rotation_grace_active", "receipt key rotation already has an active previous-key grace window")
			s.close(conn, CloseInvalidHello, "receipt_key_rotation_grace_active")
		default:
			s.close(conn, CloseInvalidToken, "invalid_token")
		}
		return "", ""
	}
	registered = true
	if reservedAdmission && entry.Tier == pool.TierProvisional {
		s.admission.ReleasePendingProvisional()
	}
	releaseUnauth()
	s.proofOfWeightsAdmissionMu.RUnlock()
	admissionLockHeld = false
	response := AuthResponse{
		Type:                      "auth_response",
		Version:                   2,
		Status:                    "accepted",
		AssignedID:                entry.AssignedID,
		HeartbeatIntervalS:        int(s.cfg.HeartbeatInterval().Seconds()),
		Tier:                      string(entry.Tier),
		RecommendedBinaryVersion:  s.gatedRecommendedBinaryVersion(initial.CompatibilitySetID),
		RequiredBinaryVersion:     s.cfg.CoordinatorAdvertisedVersion.RequiredBinaryVersion,
		AutoupdateDrainExtensions: true,
		AssignedProviderToken:     assignedProviderToken,
		PairOT:                    pairOT,
		ClaimURL:                  claimURL,
		AuthState:                 string(authState),
		IdentityAdmissionMode:     identityProof.AdmissionMode,
		IdentityAdmissionKeyRole:  identityProof.VerifiedKeyRole,
		IdentityGeneration:        identityProof.Generation,
		Tier2Session: &AuthTier2Session{
			EncryptedLeg: AuthEncryptedLegSession{
				Enabled:                        true,
				Alg:                            selectedAEAD,
				KID:                            keys.KeyID,
				RekeyAfterRequests:             tier2Cfg.EncryptedLegRekeyAfterRequests,
				RekeyAfterSeconds:              tier2Cfg.EncryptedLegRekeyAfterSeconds,
				ResponseChunkPlaintextEnvelope: initial.Tier2Capabilities.ResponseChunkPlaintextEnvelope,
				InBandAEADRekeyV1:              initial.Tier2Capabilities.InBandAEADRekeyV1,
			},
			Attestation: AuthAttestationSession{
				Status:          string(attestationStatus),
				RAMTierAttested: false,
			},
			ModelHash: AuthModelHashSession{Status: string(entry.HashStatus)},
		},
	}
	if len(identityProof.ActivePubkey) == ed25519.PublicKeySize {
		response.AdmissionIdentityPubkey = base64.StdEncoding.EncodeToString(identityProof.ActivePubkey)
	}
	if identityProof.PreviousValidUntil != nil {
		response.AdmissionIdentityPreviousValidUntil = identityProof.PreviousValidUntil.UTC().Format(time.RFC3339Nano)
	}
	s.populateCatalogAuthResponse(&response)
	s.populateCompatibilityAuthResponse(&response, initial.CompatibilitySetID)
	rawResponse, err := json.Marshal(response)
	if err != nil {
		// runWriter is already running for `session`; route the Close through
		// it instead of writing directly to conn so we don't race an in-flight
		// frame on the wire.
		s.closeSession(session, CloseInvalidHello, "invalid_auth_response")
		return "", ""
	}
	if err := session.send(rawResponse); err != nil {
		s.log.Warn().Err(err).Str("provider_id", initial.ProviderID).Msg("auth_response write failed")
		return "", ""
	}
	if s.cfg.Pool.WarmupGateEnabled {
		s.startWarmupGate(*entry)
	}
	s.readProviderLoop(conn, entry.ProviderID, entry.AssignedID)
	return entry.ProviderID, entry.AssignedID
}

// confirmAdmittedProviderToken runs only after provider-ID binding and every
// hello, evidence, attestation, and admission check, but before the provider is
// registered or an acceptance frame is queued. MarkTokenUsed is confirmation-
// neutral for ordinary credentials and atomically consumes a fresh bootstrap
// credential. A store failure therefore cannot create a routable provider or
// send a false accepted response.
func (s *Server) confirmAdmittedProviderToken(conn net.Conn, connectionAuth providerAuth) bool {
	if !connectionAuth.validated || s.tokens == nil {
		return true
	}
	if err := s.tokens.MarkTokenUsed(context.Background(), connectionAuth.token); err != nil {
		s.log.Warn().Err(err).Str("provider_id", connectionAuth.providerID).Msg("admitted provider token confirmation failed")
		s.close(conn, CloseInvalidToken, "invalid_token")
		return false
	}
	return true
}

// prepareCredentialBootstrap validates the narrow mint-only handshake. It
// deliberately does not reserve admission capacity, evaluate model evidence,
// or create a routable pool entry. The caller must complete the normal v2
// cryptographic proof (when configured), mint a brand-new token, send it, and
// close. A bearer-authenticated or pinned provider can never use this path.
func (s *Server) prepareCredentialBootstrap(conn net.Conn, connectionAuth providerAuth, initial AuthRequest) (*pool.Provider, bool) {
	hello := initial.Hello()
	if connectionAuth.validated || s.bootstrapTokens == nil || connectionAuth.sourceIP == "" {
		s.close(conn, CloseInvalidToken, "invalid_token")
		return nil, false
	}
	if !auth.IsCredentialBootstrapPrincipal(hello.ProviderID) || len(initial.ProviderReceiptPubkey) != ed25519.PublicKeySize {
		s.observeCredentialBootstrap("rejected_identity")
		s.close(conn, CloseIdentitySignatureRequired, "bootstrap_receipt_identity_required")
		return nil, false
	}
	if _, pinned := s.pool.Endpoint(hello.ProviderID); pinned {
		s.close(conn, CloseInvalidToken, "invalid_token")
		return nil, false
	}
	if required := strings.TrimSpace(s.cfg.CoordinatorAdvertisedVersion.RequiredBinaryVersion); required != "" {
		cmp, valid := compareSemver(hello.BinaryVersion, required)
		if !valid || cmp < 0 {
			s.close(conn, CloseVersionUnsupported, "version_unsupported: binary_version "+hello.BinaryVersion+" below required "+required)
			return nil, false
		}
	}
	return &pool.Provider{
		ProviderID: hello.ProviderID,
		AssignedID: s.newUUID(),
		Tier:       pool.TierProvisional,
		ModelID:    hello.ModelID,
	}, true
}

func (s *Server) rejectCredentialBootstrap(conn net.Conn, err error) {
	switch {
	case errors.Is(err, auth.ErrBootstrapIdentityMismatch):
		s.observeCredentialBootstrap("rejected_identity")
		s.close(conn, CloseInvalidToken, "bootstrap_identity_mismatch")
	case errors.Is(err, auth.ErrBootstrapTokenUsed):
		s.observeCredentialBootstrap("rejected_used")
		s.close(conn, CloseInvalidToken, "bootstrap_token_used")
	case errors.Is(err, auth.ErrBootstrapTokenExpired):
		s.observeCredentialBootstrap("rejected_expired")
		s.close(conn, CloseInvalidToken, "bootstrap_token_expired")
	case errors.Is(err, auth.ErrBootstrapRateLimited):
		s.observeCredentialBootstrap("rejected_rate")
		s.close(conn, CloseProvisionalRateLimited, "credential_bootstrap_rate_limited")
	case errors.Is(err, auth.ErrBootstrapOutstandingLimit):
		s.observeCredentialBootstrap("rejected_outstanding")
		s.close(conn, CloseProvisionalPoolFull, "credential_bootstrap_outstanding_full")
	case errors.Is(err, auth.ErrReferralRequired):
		s.observeCredentialBootstrap("rejected_referral_required")
		s.close(conn, CloseInvalidToken, "referral_required")
	case errors.Is(err, auth.ErrReferralInvalid), errors.Is(err, auth.ErrReferralExpired),
		errors.Is(err, auth.ErrReferralRevoked), errors.Is(err, auth.ErrReferralExhausted),
		errors.Is(err, auth.ErrReferralConflict):
		s.observeCredentialBootstrap("rejected_referral")
		s.close(conn, CloseInvalidToken, referralCloseReason(err))
	default:
		s.observeCredentialBootstrap("store_error")
		s.log.Warn().Err(err).Msg("credential bootstrap token transaction failed")
		s.close(conn, CloseInvalidToken, "invalid_token")
	}
}

func referralCloseReason(err error) string {
	switch {
	case errors.Is(err, auth.ErrReferralExpired):
		return "referral_expired"
	case errors.Is(err, auth.ErrReferralRevoked):
		return "referral_revoked"
	case errors.Is(err, auth.ErrReferralExhausted):
		return "referral_exhausted"
	case errors.Is(err, auth.ErrReferralConflict):
		return "referral_conflict"
	default:
		return "referral_invalid"
	}
}

func (s *Server) observeCredentialBootstrap(outcome string) {
	if s.credentialBootstrapMetrics != nil {
		s.credentialBootstrapMetrics.IncCredentialBootstrap(outcome)
	}
}

func (s *Server) prepareProviderAdmission(conn net.Conn, auth providerAuth, hello Hello) (*pool.Provider, bool) {
	// Exact pre-fix sets listed in first_hop_bridge_ids may open an
	// update-only session so public 1.8.48 can persist coordinator
	// compatibility admission and run ordinary `macprovider-cli update`
	// (#610). They never become buyer-routable.
	firstHopOnly := s.cfg.Coordinator.CompatibilitySet.IsFirstHopBridgeOnly(hello.CompatibilitySetID)
	if !firstHopOnly {
		if required := strings.TrimSpace(s.cfg.CoordinatorAdvertisedVersion.RequiredBinaryVersion); required != "" {
			cmp, ok := compareSemver(hello.BinaryVersion, required)
			if !ok || cmp < 0 {
				s.close(conn, CloseVersionUnsupported, "version_unsupported: binary_version "+hello.BinaryVersion+" below required "+required)
				return nil, false
			}
		}
	}
	catalogAdmissionMode, catalogCompatible := s.catalogAdmission(hello)
	if !catalogCompatible {
		if firstHopOnly {
			catalogAdmissionMode = "update_bridge"
		} else {
			s.log.Warn().
				Str("provider_id", hello.ProviderID).
				Str("catalog_release_id", hello.CatalogReleaseID).
				Str("catalog_policy_version", hello.CatalogPolicyVersion).
				Str("catalog_candidate_sha256", hello.CandidateCatalogSHA256).
				Str("catalog_signer_key_id", hello.CatalogSignerKeyID).
				Msg("provider catalog release is incompatible with coordinator")
			s.close(conn, CloseInvalidHello, "catalog_incompatible")
			return nil, false
		}
	} else if firstHopOnly {
		catalogAdmissionMode = "update_bridge"
	}
	now := s.now()
	expectedModelHash := s.expectedAdmissionModelHash(hello, catalogAdmissionMode)
	hashStatus := pool.HashStatus("")
	tier2Cfg := s.tier2Config()
	if tier2.ModelHashActive(tier2Cfg) {
		hashStatus = s.verifyProviderModelIdentity(hello.ModelID, expectedModelHash, hello.ModelHash, hello.ModelHashAlgorithm)
		if hashStatus == pool.HashStatusInvalid {
			s.close(conn, CloseInvalidHello, "invalid_model_hash_identity")
			return nil, false
		}
	}
	providerCfg, pinned := s.pool.Endpoint(hello.ProviderID)
	if s.tokens != nil {
		if auth.validated && auth.providerID != hello.ProviderID {
			s.close(conn, CloseInvalidToken, "invalid_token")
			return nil, false
		}
		if pinned && !auth.validated {
			s.close(conn, CloseInvalidToken, "invalid_token")
			return nil, false
		}
		// Ordinary and confirmed credentials have `last_used_at` stamped by
		// validateProviderToken at upgrade. A fresh bootstrap credential is
		// consumed only after this admission path and all evidence checks pass.
	}
	tier, closeCode, closeReason := s.checkOrRecordAdmission(hello, pinned, false)
	if closeCode != 0 {
		s.close(conn, closeCode, closeReason)
		return nil, false
	}
	endpointURL := ""
	inferencePath := pool.InferencePathWSTunneled
	if pinned {
		if providerCfg.EndpointURL != "" {
			endpointURL = providerCfg.EndpointURL
			if hello.EndpointURL != nil && strings.TrimSpace(*hello.EndpointURL) != "" && strings.TrimSpace(*hello.EndpointURL) != providerCfg.EndpointURL {
				s.log.Warn().
					Str("provider_id", hello.ProviderID).
					Str("configured_endpoint_url", providerCfg.EndpointURL).
					Str("hello_endpoint_url", strings.TrimSpace(*hello.EndpointURL)).
					Msg("pinned provider endpoint_url override ignored")
			}
		} else if hello.EndpointURL != nil && strings.TrimSpace(*hello.EndpointURL) != "" {
			s.log.Warn().
				Str("provider_id", hello.ProviderID).
				Str("hello_endpoint_url", strings.TrimSpace(*hello.EndpointURL)).
				Msg("pinned provider endpoint_url ignored because no configured endpoint_url exists")
		}
		if endpointURL != "" {
			inferencePath = pool.InferencePathHTTPForwarding
		}
	} else if hello.EndpointURL != nil && strings.TrimSpace(*hello.EndpointURL) != "" {
		s.log.Warn().Str("provider_id", hello.ProviderID).Str("endpoint_url", *hello.EndpointURL).Msg("provisional provider sent endpoint_url; ignoring and forcing ws-tunneled mode")
	}

	assignedID := s.newUUID()
	if tier2.ModelHashActive(tier2Cfg) {
		if strings.TrimSpace(hello.ModelHashAlgorithm) == "" &&
			modelidentity.LegacyMissingAlgorithmAllowed(tier2Cfg.ModelHashLegacyUntil, now) {
			s.log.Warn().
				Str("event", "model_hash_algorithm_legacy_bridge").
				Str("provider_id", hello.ProviderID).
				Str("model_id", hello.ModelID).
				Str("legacy_until", tier2Cfg.ModelHashLegacyUntil).
				Msg("provider admitted without a model hash algorithm during the bounded legacy window")
		}
		s.observeHashStatusTransition("", hashStatus, hello.ProviderID, assignedID, hello.ModelID, hello.ModelHash)
		if tier2Cfg.RequireHashVerified && (hashStatus == pool.HashStatusUncatalogued || hashStatus == pool.HashStatusCatalogUnavailable) {
			tier2.LogHashRequiredProviderExcluded(s.log, hello.ProviderID, assignedID, hello.ModelID, hello.ModelHash, hashStatus)
		}
	}
	var (
		maxAdmittedModelKey string
		maxAdmittedModelID  string
		maxAdmittedMinRAMGB int
		admittedTuple       onboarding.AdmittedTuple
		admissionSandboxed  bool
	)
	if firstHopOnly {
		s.log.Info().
			Str("provider_id", hello.ProviderID).
			Str("event", "compatibility_set_first_hop_bridge").
			Str("compatibility_set_id", hello.CompatibilitySetID).
			Str("recommended_compatibility_set_id", s.cfg.Coordinator.CompatibilitySet.TargetID).
			Msg("admitting update-only first-hop bridge session")
	} else {
		var gateOK bool
		admissionObservation, gateOK := s.checkAutotuneHelloGate(conn, hello)
		if !gateOK {
			return nil, false
		}
		maxAdmittedModelKey = admissionObservation.MaxAdmittedModelKey
		maxAdmittedModelID = admissionObservation.MaxAdmittedModelID
		maxAdmittedMinRAMGB = admissionObservation.MaxAdmittedMinRAMGB
		admittedTuple = admissionObservation.AdmittedTuple
		admissionSandboxed = admissionObservation.Sandboxed
	}
	initialState := pool.StateReady
	if s.cfg.Pool.WarmupGateEnabled {
		initialState = pool.StateDegraded
	}
	// Issue #764: clamp the reported capacity BEFORE it enters the registry, so
	// no downstream consumer ever sees the raw claim. A fresh session starts
	// fully free, so the reported triple is (max, max, max).
	capacity := s.clampProviderCapacity(hello.MaxConcurrency, hello.MaxConcurrency, hello.MaxConcurrency)
	if capacity.OverClaimed {
		s.recordCapacityOverClaim(capacityPhaseHello)
		s.log.Warn().
			Str("event", EventProviderCapacityOverClaim).
			Str("provider_id", hello.ProviderID).
			Str("phase", capacityPhaseHello).
			Int("reported_max_concurrency", capacity.ReportedMax).
			Int("ceiling", s.maxConcurrencyCeiling()).
			Int("effective_max_concurrency", capacity.MaxConcurrency).
			Msg("provider capacity claim exceeds the operator ceiling; clamped")
	}
	entry := &pool.Provider{
		ProviderID:             hello.ProviderID,
		AssignedID:             assignedID,
		Hostname:               hello.Hostname,
		ModelID:                hello.ModelID,
		ModelParamsB:           hello.ModelParamsB,
		RAMGB:                  hello.RAMGB,
		MaxContextTokens:       hello.MaxContextTokens,
		MaxConcurrency:         capacity.MaxConcurrency,
		SlotsFree:              capacity.SlotsFree,
		SlotsTotal:             capacity.SlotsTotal,
		ThroughputTPSEstimate:  hello.ThroughputTPSEstimate,
		ModelLoadTimeMs:        hello.ModelLoadTimeMs,
		EndpointURL:            endpointURL,
		Tier:                   tier,
		InferencePath:          inferencePath,
		AdmittedAt:             now,
		State:                  initialState,
		LastHeartbeatAt:        now,
		LastActivityAt:         now,
		ConnectedAt:            now,
		BinaryVersion:          hello.BinaryVersion,
		ModelHash:              hello.ModelHash,
		ModelHashAlgorithm:     hello.ModelHashAlgorithm,
		WeightsManifestSHA256:  hello.WeightsManifestSHA256,
		WeightsHashAlgorithm:   hello.WeightsHashAlgorithm,
		ExpectedModelHash:      expectedModelHash,
		HashStatus:             hashStatus,
		CatalogAdmissionMode:   catalogAdmissionMode,
		CatalogReleaseID:       hello.CatalogReleaseID,
		CatalogPolicyVersion:   hello.CatalogPolicyVersion,
		CandidateCatalogSHA256: hello.CandidateCatalogSHA256,
		CatalogSignerKeyID:     hello.CatalogSignerKeyID,
		CandidateRowIdentity:   hello.CandidateRowIdentity,
		MaxAdmittedModelKey:    maxAdmittedModelKey,
		MaxAdmittedModelID:     maxAdmittedModelID,
		MaxAdmittedMinRAMGB:    maxAdmittedMinRAMGB,
		// FIX B (issue #582): admitted hardware-trust tuple for the sweep.
		AdmittedHardwareIdentityHash: admittedTuple.HardwareIdentityHash,
		AdmittedChipNormalized:       admittedTuple.ChipNormalized,
		AdmittedUnifiedMemoryGB:      admittedTuple.UnifiedMemoryGB,
	}
	if s.proofOfWeightsConfig().RequireAutotuneHelloGate {
		entry.AdmissionCeilingExcluded = s.admissionCeilingRouteVerdict(*entry).excluded
		entry.AdmissionSandboxed = admissionSandboxed
	}
	return entry, true
}

func (s *Server) expectedAdmissionModelHash(hello Hello, admissionMode string) string {
	catalog := s.autotuneCatalog
	if admissionMode == "previous" {
		catalog = s.autotuneCompatibleCatalogs[hello.CatalogReleaseID]
	}
	if catalog == nil || (admissionMode != "current" && admissionMode != "previous") {
		return ""
	}
	_, row, ok := catalog.HighestClaimedTier(hello.ModelID)
	if !ok {
		return ""
	}
	return strings.TrimSpace(row.ModelSHA256)
}

func (s *Server) expectedProviderModelHash(providerID, assignedID, modelID string) string {
	provider, ok := s.pool.Resolve(providerID, assignedID)
	if !ok {
		return ""
	}
	catalog := s.autotuneCatalog
	if provider.CatalogAdmissionMode == "previous" {
		catalog = s.autotuneCompatibleCatalogs[provider.CatalogReleaseID]
	}
	if catalog == nil || (provider.CatalogAdmissionMode != "current" && provider.CatalogAdmissionMode != "previous") {
		return ""
	}
	_, row, ok := catalog.HighestClaimedTier(modelID)
	if !ok {
		return ""
	}
	return strings.TrimSpace(row.ModelSHA256)
}

type autotuneAdmissionObservation struct {
	MaxAdmittedModelKey string
	MaxAdmittedModelID  string
	MaxAdmittedMinRAMGB int
	AdmittedTuple       onboarding.AdmittedTuple
	Sandboxed           bool
}

// checkAutotuneHelloGate is the hardware-trust AUTHORIZATION POINT when the
// strict gate is enabled (issue #582 FIX A). LatestVerified joins live
// hardware_verification_trust and admits only a provider whose verified hardware
// tuple is still backed by an active trust root. When the strict gate is off,
// the same evidence read runs observe-only so heartbeat model changes can be
// compared against the admitted RAM ceiling without affecting routing.
func (s *Server) checkAutotuneHelloGate(conn net.Conn, hello Hello) (autotuneAdmissionObservation, bool) {
	powCfg := s.proofOfWeightsConfig()
	requireGate := powCfg.RequireAutotuneHelloGate
	if s.autotuneCatalog == nil || s.autotuneEvidence == nil {
		if requireGate {
			s.log.Error().Str("provider_id", hello.ProviderID).Msg("autotune hello gate enabled but dependencies are not wired")
			s.close(conn, CloseInvalidHello, "autotune_gate_unavailable")
			return autotuneAdmissionObservation{}, false
		}
		return autotuneAdmissionObservation{}, true
	}
	ttl := time.Duration(powCfg.AutotuneEvidenceTTLDays) * 24 * time.Hour
	ctx, cancel := context.WithTimeout(context.Background(), autotuneEvidenceLookupTimeout)
	defer cancel()
	evidence, ok, err := s.autotuneEvidence.LatestVerified(ctx, hello.ProviderID, ttl)
	if err != nil {
		event := s.log.Warn().Err(err).Str("provider_id", hello.ProviderID)
		if requireGate {
			event.Msg("autotune hello gate evidence lookup failed")
			s.close(conn, CloseInvalidHello, "autotune_gate_unavailable")
			return autotuneAdmissionObservation{}, false
		}
		event.Msg("autotune evidence observation lookup failed")
		return autotuneAdmissionObservation{}, true
	}
	if !ok {
		// SPEC-032 redundancy decision (runbook item 1c): rejecting a would-be
		// second provider for lack of verified hardware evidence is correct — the
		// gate is NOT weakened here. Surface the redundancy cost so an operator sees
		// a rejection that leaves the model non-redundant (the 2026-07-10 air5
		// gated-out condition). NOTE: this is *partial rejection telemetry*, NOT the
		// full SPEC-032 FR-HG5 below-two operator alert (which additionally requires
		// a catalogued-demand-filtered structural count across ALL gate actions +
		// episode dedup/cooldown — still a Gap). Count buyer-serving providers.
		if requireGate {
			serving := s.pool.BuyerServingCountForModel(hello.ModelID)
			event := s.log.Info().
				Str("provider_id", hello.ProviderID).
				Str("event", "autotune_evidence_required").
				Str("model_id", hello.ModelID).
				Int("buyer_serving_for_model", serving)
			if serving < 2 {
				event = event.Bool("pool_redundancy_low", true)
			}
			event.Msg("autotune hello gate sandboxed connect without verified hardware evidence")
			return autotuneAdmissionObservation{Sandboxed: true}, true
		}
		return autotuneAdmissionObservation{}, true
	}
	decision := autotune.EvaluateHelloGateForHello(s.autotuneCatalog, evidence, hello.ModelID, hello.BinaryVersion)
	if !decision.Allowed {
		if !requireGate {
			return autotuneAdmissionObservation{
				MaxAdmittedModelKey: decision.MaxAdmittedModelKey,
				MaxAdmittedModelID:  decision.MaxAdmittedModelID,
				MaxAdmittedMinRAMGB: decision.MaxAdmittedMinRAMGB,
				AdmittedTuple: onboarding.AdmittedTuple{
					ProviderID:           hello.ProviderID,
					HardwareIdentityHash: evidence.HardwareIdentityHash,
					ChipNormalized:       evidence.ChipNormalized,
					UnifiedMemoryGB:      evidence.UnifiedMemoryGB,
				},
			}, true
		}
		s.log.Info().
			Str("provider_id", hello.ProviderID).
			Str("event", decision.Reason).
			Str("model_id", hello.ModelID).
			Str("claimed_model_key", decision.ClaimedModelKey).
			Str("max_admitted_model_class", decision.MaxAdmittedModelKey).
			Str("max_admitted_model_id", decision.MaxAdmittedModelID).
			Int("claimed_min_ram_gb", decision.ClaimedMinRAMGB).
			Int("max_admitted_min_ram_gb", decision.MaxAdmittedMinRAMGB).
			Msg("autotune hello gate rejected provider model claim")
		s.close(conn, CloseInvalidHello, decision.Reason)
		return autotuneAdmissionObservation{}, false
	}
	// FIX B (issue #582): bind the admitted session to the exact trust tuple that
	// authorized it, for the tuple-aware revalidation sweep.
	tuple := onboarding.AdmittedTuple{
		ProviderID:           hello.ProviderID,
		HardwareIdentityHash: evidence.HardwareIdentityHash,
		ChipNormalized:       evidence.ChipNormalized,
		UnifiedMemoryGB:      evidence.UnifiedMemoryGB,
	}
	return autotuneAdmissionObservation{
		MaxAdmittedModelKey: decision.MaxAdmittedModelKey,
		MaxAdmittedModelID:  decision.MaxAdmittedModelID,
		MaxAdmittedMinRAMGB: decision.MaxAdmittedMinRAMGB,
		AdmittedTuple:       tuple,
	}, true
}

func (s *Server) catalogAdmission(hello Hello) (string, bool) {
	catalog := s.autotuneCatalog
	if catalog == nil {
		return "not_required", true
	}
	metadata := []string{
		hello.CatalogReleaseID,
		hello.CatalogPolicyVersion,
		hello.CatalogSignerKeyID,
		hello.CandidateCatalogSHA256,
		hello.CandidateRowIdentity,
	}
	present := 0
	for _, value := range metadata {
		if strings.TrimSpace(value) != "" {
			present++
		}
	}
	// Bridge window: pre-catalog-handshake binaries are admitted through the
	// existing signed-catalog model/evidence gates. Once a client sends any
	// catalog metadata it must send and match the complete release envelope.
	if present == 0 {
		if s.autotuneCatalogBridgeActive() {
			return "legacy_bridge", true
		}
		return "legacy", true
	}
	if present != len(metadata) {
		return "", false
	}
	providerCatalog := catalog
	admissionMode := "current"
	if hello.CatalogReleaseID != catalog.Version {
		providerCatalog = s.autotuneCompatibleCatalogs[hello.CatalogReleaseID]
		admissionMode = "previous"
	}
	if providerCatalog == nil ||
		hello.CatalogPolicyVersion != providerCatalog.PolicyVersion ||
		hello.CatalogSignerKeyID != providerCatalog.SignerKeyID ||
		!strings.EqualFold(hello.CandidateCatalogSHA256, providerCatalog.SHA256) {
		return "", false
	}
	key, _, ok := providerCatalog.HighestClaimedTier(hello.ModelID)
	if !ok {
		return "", false
	}
	providerRowIdentity, ok := providerCatalog.RowIdentity(key)
	if !ok || !strings.EqualFold(hello.CandidateRowIdentity, providerRowIdentity) {
		return "", false
	}
	// A recognized previous release is compatible only while the selected
	// model row identity and policy-bearing structured fields are semantically
	// equivalent to the active release. This permits unrelated catalog updates
	// without admitting stale model artifacts, gates, speculative decoding, or
	// workload policy.
	activeKey, _, ok := catalog.HighestClaimedTier(hello.ModelID)
	if !ok {
		return "", false
	}
	activeRowIdentity, ok := catalog.RowIdentity(activeKey)
	if !ok || !strings.EqualFold(providerRowIdentity, activeRowIdentity) {
		return "", false
	}
	if admissionMode == "previous" && !providerCatalog.PolicyEquivalent(key, catalog, activeKey) {
		return "", false
	}
	return admissionMode, true
}

func (s *Server) populateCatalogHelloAck(ack *HelloAck) {
	if ack == nil || s.autotuneCatalog == nil {
		return
	}
	ack.CatalogCompatible = true
	ack.CatalogReleaseID = s.autotuneCatalog.Version
	ack.CatalogPolicyVersion = s.autotuneCatalog.PolicyVersion
	ack.CandidateCatalogSHA256 = s.autotuneCatalog.SHA256
	ack.CatalogSignerKeyID = s.autotuneCatalog.SignerKeyID
}

func (s *Server) populateCatalogAuthResponse(response *AuthResponse) {
	if response == nil || s.autotuneCatalog == nil {
		return
	}
	response.CatalogCompatible = true
	response.CatalogReleaseID = s.autotuneCatalog.Version
	response.CatalogPolicyVersion = s.autotuneCatalog.PolicyVersion
	response.CandidateCatalogSHA256 = s.autotuneCatalog.SHA256
	response.CatalogSignerKeyID = s.autotuneCatalog.SignerKeyID
}

func (s *Server) requireCompatibleSet(conn net.Conn, providedID string, authV2 bool) bool {
	policy := s.cfg.Coordinator.CompatibilitySet
	if !policy.Configured() {
		return true
	}
	reject := func(code string) bool {
		if authV2 {
			s.sendAuthRejection(conn, code, code)
		}
		s.close(conn, CloseInvalidHello, code)
		return false
	}
	if providedID == "" {
		return reject("compatibility_set_required")
	}
	if err := config.ValidateCompatibilitySetID(providedID); err != nil {
		return reject("compatibility_set_invalid")
	}
	// Buyer-serving accepted sets and the temporary #610 first-hop bridge both
	// pass the hello/auth gate. Bridge-only sessions still receive the
	// recommended target admission but are marked non-routable later.
	if !policy.AllowsSession(providedID) {
		return reject("compatibility_set_unaccepted")
	}
	return true
}

func (s *Server) populateCompatibilityHelloAck(ack *HelloAck, acceptedID string) {
	if ack == nil {
		return
	}
	policy := s.cfg.Coordinator.CompatibilitySet
	if !policy.Configured() {
		ack.CompatibilityPolicy = "unconfigured"
		return
	}
	ack.CompatibilityPolicy = "configured"
	ack.AcceptedCompatibilitySetID = acceptedID
	ack.RecommendedCompatibilitySetID = policy.TargetID
}

func (s *Server) populateCompatibilityAuthResponse(response *AuthResponse, acceptedID string) {
	if response == nil {
		return
	}
	policy := s.cfg.Coordinator.CompatibilitySet
	if !policy.Configured() {
		response.CompatibilityPolicy = "unconfigured"
		return
	}
	response.CompatibilityPolicy = "configured"
	response.AcceptedCompatibilitySetID = acceptedID
	response.RecommendedCompatibilitySetID = policy.TargetID
}

// gatedRecommendedBinaryVersion is a per-connection capability gate for the
// coordinator's advertised `latest_binary_version` (S-H1). The configured
// value (`coordinator_advertised_version.latest_binary_version`) is delivered
// to a provider as `recommended_binary_version` and drives its autoupdater.
//
// Pre-compatibility-set CLIs (<=1.8.32, verified against v1.8.30) ship a
// default-enabled autoupdater that performs a BINARY-ONLY swap when they see a
// newer recommendation — bypassing the operator-assisted full signed
// compatibility-set installer, the only sanctioned recovery path for that
// cohort (DECISION_CRITERIA entries 155/158/161). Those clients do not send
// `compatibility_set_id` in their hello, so an empty capability => legacy =>
// emit no recommendation (the field is `omitempty`, so the wire key is absent;
// the legacy client treats an absent recommendation as a clean no-op).
//
// Providers that declare a compatibility-set identity (v1.8.33+) own a
// full-set updater that performs signed compatibility-set transactions and
// receive the configured recommendation unchanged. `required_binary_version`
// semantics are intentionally untouched — it is a hard admission floor, not an
// autoupdate target, so it is gated separately (or not at all) by design.
func (s *Server) gatedRecommendedBinaryVersion(compatibilitySetID string) string {
	if strings.TrimSpace(compatibilitySetID) == "" {
		return ""
	}
	return s.cfg.CoordinatorAdvertisedVersion.LatestBinaryVersion
}

func (s *Server) reserveProviderAdmission(conn net.Conn, hello Hello, pinned bool) (pool.Tier, bool) {
	tier, closeCode, closeReason := s.admission.ReserveAdmission(hello, pinned, s.connectedProvisional())
	if closeCode != 0 {
		s.close(conn, closeCode, closeReason)
		return "", false
	}
	return tier, true
}

func (s *Server) commitProviderAdmission(hello Hello, pinned bool) pool.Tier {
	return s.admission.CommitReservedAdmission(hello, pinned)
}

func (s *Server) checkOrRecordAdmission(hello Hello, pinned bool, record bool) (pool.Tier, gobwas.StatusCode, string) {
	if record {
		return s.admission.Admit(hello, pinned, s.connectedProvisional())
	}
	return s.admission.CheckAdmit(hello, pinned, s.connectedProvisional())
}

// compareSemver is a thin alias for the coordinator's single version
// comparator. The implementation moved to internal/versionfloor (#768) so the
// per-model floors evaluated in internal/buyer and the global admission floor
// enforced here cannot drift into two different orderings.
func compareSemver(lhs, rhs string) (int, bool) {
	return versionfloor.Compare(lhs, rhs)
}

// modelVersionFloor evaluates the per-model minimum-binary-version floor
// (#768) for a pool provider. Same map, same helper, same verdict as the
// buyer-side routing gates — see versionfloor.Check.
func (s *Server) modelVersionFloor(p pool.Provider) versionfloor.Result {
	return versionfloor.Check(
		s.cfg.CoordinatorAdvertisedVersion.PerModelRequiredBinaryVersion,
		p.ModelID,
		p.BinaryVersion,
	)
}

// belowModelVersionFloor is the warm-pool half of the #768 gate: a provider we
// would refuse to route to must not be warmed or counted as a serving peer.
func (s *Server) belowModelVersionFloor(p pool.Provider, gate string) bool {
	result := s.modelVersionFloor(p)
	if result.Allowed {
		return false
	}
	event := s.log.Info()
	if result.Malformed {
		event = s.log.Warn()
	}
	event.
		Str("event", "model_version_floor_excluded").
		Str("gate", gate).
		Str("provider_id", p.ProviderID).
		Str("assigned_id", p.AssignedID).
		Str("model_id", p.ModelID).
		Str("binary_version", p.BinaryVersion).
		Str("required_binary_version", result.Floor).
		Bool("binary_version_malformed", result.Malformed).
		Msg("provider excluded by per-model binary version floor")
	return true
}

// registerProviderSession installs the WS session in the registry +
// starts heartbeat monitoring. Returns nil with a non-empty refusal when
// registration is refused: bearer-less duplicate eviction defense
// (RegisterRefusalBearerlessDuplicate / BearerDowngrade) or receipt-key rotation
// grace conflicts (RegisterRefusalReceiptRotationGraceActive).
// On refusal the caller MUST close the connection (mapping the refusal to its
// close code, defaulting to CloseInvalidToken / "invalid_token") and not
// advance to ack-write.
//
// Issue #582 FIX A: there is deliberately NO hardware-trust re-check here.
// resolveProvisionalToken has already minted the provider token, PairOT, and
// redeemed any referral by the time this runs, so a trust re-check that refused
// now would strand a durably-committed token that never reaches the provider —
// the exact commit-then-refuse onboarding/recovery deadlock #582 removes. Trust
// is authorized earlier, at the hello gate (checkAutotuneHelloGate →
// LatestVerified), BEFORE any durable mutation; the residual hello-gate→register
// TOCTOU is covered by the bounded revalidation sweep, which evicts (never
// refuses) a session whose trust lapsed after it was committed.
func (s *Server) registerProviderSession(conn net.Conn, entry *pool.Provider) (*providerSession, pool.RegisterRefusal) {
	s.autotuneCatalogBridgeMu.Lock()
	defer s.autotuneCatalogBridgeMu.Unlock()
	if entry.CatalogAdmissionMode == "legacy_bridge" && !s.autotuneCatalogBridgeActive() {
		entry.CatalogAdmissionMode = "legacy"
	}
	old, ok, refusal := s.pool.RegisterAtDetailed(entry, conn, s.now())
	if !ok {
		// SPEC-003 v0.8.3 FR-C9.4 eviction defense fired: a
		// bearer-less duplicate tried to evict an existing routable
		// session for the same provider_id. Log + signal the caller
		// to close.
		s.log.Info().Str("provider_id", entry.ProviderID).Str("refusal", string(refusal)).Msg("provider session registration refused")
		return nil, refusal
	}
	if old != nil {
		_ = old.Close()
	}
	session := newProviderSession(entry.ProviderID, entry.AssignedID, conn, s.cfg.WS.WriteBufferSize, s.cfg.ProviderWSWriteTimeout())
	session.useTier2Session(entry.Tier2Session)
	session.probeWrites = true
	session.onWriteFailure = s.handleProviderWriteFailure
	s.sessions.Store(sessionKey(entry.ProviderID, entry.AssignedID), session)
	_ = s.takeCloseEvent(conn) // successful admission: drop pre-auth close metadata
	s.rememberProviderSnapshot(*entry)
	s.recordConnectionEvent(providerevents.Event{
		ProviderID:    entry.ProviderID,
		SessionID:     entry.AssignedID,
		Kind:          providerevents.KindAuthAccepted,
		Outcome:       providerevents.OutcomeSuccess,
		AuthStage:     providerevents.AuthStagePostAuth,
		MessageFamily: providerevents.MessageFamilyNone,
		BinaryVersion: entry.BinaryVersion,
	})
	go session.runWriter()
	go s.monitorHeartbeat(entry.ProviderID, entry.AssignedID, conn)
	return session, pool.RegisterRefusalNone
}

func (s *Server) readProviderLoop(conn net.Conn, providerID, assignedID string) {
	// Resolve the session once so reactive PONG / Close-echo writes funnel
	// through session.enqueueRaw — i.e. through the single runWriter goroutine.
	// Without this, gobwas's ControlHandler would emit reply frames directly to
	// conn from THIS read goroutine, racing runWriter mid-text-frame and
	// corrupting WS framing on the wire. The race is invisible to -race because
	// net.TCPConn.Write itself is internally locked; the corruption lives one
	// layer up at the WS framing boundary.
	//
	// Fallback to directControlReply when no session is registered (only
	// reachable from tests that drive readProviderLoop without a sessions-map
	// entry) — keeps the historical behaviour for those callers.
	var controlReply func([]byte) error
	if session, ok := s.storedSessionFor(providerID, assignedID); ok {
		controlReply = session.enqueueRaw
	} else {
		controlReply = s.directControlReply(conn)
	}
	for {
		s.setReadDeadline(conn, s.providerReadTimeout(providerID, assignedID))
		payload, op, err := s.readClientData(conn, controlReply)
		if err != nil {
			s.log.Warn().Err(err).Str("provider_id", providerID).Msg("provider websocket read failed")
			return
		}
		if op != gobwas.OpText {
			s.log.Warn().Str("provider_id", providerID).Uint8("op", uint8(op)).Msg("ignoring non-text provider frame")
			continue
		}
		s.handleMessage(conn, providerID, assignedID, payload)
	}
}

func negotiateAEAD(suites []string, cfg config.Tier2Config) (string, bool) {
	supported := strings.TrimSpace(cfg.EncryptedLegAEAD)
	if supported == "" {
		supported = tier2.PillarBAEADA256GCM
	}
	if supported != tier2.PillarBAEADA256GCM {
		return "", false
	}
	for _, suite := range suites {
		if suite == tier2.PillarBAEADA256GCM {
			return tier2.PillarBAEADA256GCM, true
		}
	}
	return "", false
}

func randomBytes(n int) ([]byte, error) {
	b := make([]byte, n)
	if _, err := io.ReadFull(rand.Reader, b); err != nil {
		return nil, err
	}
	return b, nil
}

func (s *Server) sendAuthRejection(conn net.Conn, code, message string) {
	raw, err := json.Marshal(AuthResponse{
		Type:    "auth_response",
		Version: 2,
		Status:  "rejected",
		Error:   &AuthResponseError{Code: code, Message: message},
	})
	if err != nil {
		return
	}
	_ = s.writeServerText(conn, raw)
}

func (s *Server) close(conn net.Conn, code gobwas.StatusCode, reason string) {
	// Log every WS close at warn level so silent failures (like the v1.1.2
	// deploy's invalid_token rejection of M4/M1) are visible in the journal.
	s.log.Warn().Int("close_code", int(code)).Str("reason", reason).Msg("provider websocket closing")
	s.recordCloseEvent(conn, code, reason)
	_ = s.writeServerMessage(conn, gobwas.OpClose, gobwas.NewCloseFrameBody(code, reason))
}

// closeSession is the post-handshake equivalent of close: it enqueues a Close
// frame through the providerSession's writer (so it serializes with any
// in-flight text frame from runWriter instead of racing it on the wire) and
// schedules conn.Close after a short grace period so runWriter can actually
// flush the frame before the TCP conn dies. Callers MUST use this instead of
// close(session.conn, ...) once runWriter is running — i.e. after
// registerProviderSession has returned.
func (s *Server) closeSession(session *providerSession, code gobwas.StatusCode, reason string) {
	s.log.Warn().Int("close_code", int(code)).Str("reason", reason).Msg("provider websocket closing")
	if session != nil {
		session.closeEventOnce.Do(func() {
			meta := closeEventMeta{
				providerID:       session.providerID,
				sessionID:        session.assignedID,
				authStage:        providerevents.AuthStagePostAuth,
				messageFamily:    providerevents.MessageFamilyNone,
				identityVerified: true,
			}
			if p, ok := s.pool.Resolve(session.providerID, session.assignedID); ok {
				meta.binaryVersion = p.BinaryVersion
			}
			// Drop any stale conn-keyed meta so a later takeCloseEvent cannot
			// emit a second unattributed close event for the same socket.
			_ = s.takeCloseEvent(session.conn)
			s.recordCloseEventFromMeta(meta, code, reason)
		})
	}
	body := gobwas.NewCloseFrameBody(code, reason)
	var buf bytes.Buffer
	if err := gobwas.WriteFrame(&buf, gobwas.NewCloseFrame(body)); err != nil {
		// Writing to bytes.Buffer cannot realistically fail; fall back to a
		// hard conn.Close so the session still tears down.
		_ = session.conn.Close()
		return
	}
	_ = session.enqueueRaw(buf.Bytes())
	time.AfterFunc(100*time.Millisecond, func() {
		_ = session.conn.Close()
	})
}

func (s *Server) reserveUnauthenticatedConn() bool {
	select {
	case s.unauth <- struct{}{}:
		return true
	default:
		return false
	}
}

func (s *Server) releaseUnauthenticatedConn() {
	select {
	case <-s.unauth:
	default:
	}
}

// reserveUnauthenticatedConnForIP returns true if the per-IP cap for
// unauthenticated handshakes has room for one more. The release closure
// MUST be called exactly once per successful reservation (defer it at the
// caller). Empty ip is not tracked — pass r.RemoteAddr's host portion.
func (s *Server) reserveUnauthenticatedConnForIP(ip string) (bool, func()) {
	if ip == "" {
		return true, func() {}
	}
	cap := s.cfg.ProviderWSMaxUnauthenticatedConnPerIP()
	s.unauthPerIPMu.Lock()
	if s.unauthPerIP[ip] >= cap {
		s.unauthPerIPMu.Unlock()
		return false, func() {}
	}
	s.unauthPerIP[ip]++
	s.unauthPerIPMu.Unlock()
	return true, func() {
		s.unauthPerIPMu.Lock()
		defer s.unauthPerIPMu.Unlock()
		if s.unauthPerIP[ip] <= 1 {
			delete(s.unauthPerIP, ip)
			return
		}
		s.unauthPerIP[ip]--
	}
}

// remoteIPForUnauthSemaphore extracts the per-source IP for unauth tracking.
// Pre-fix (M1-4 v1) used r.RemoteAddr only, but production sits behind nginx
// on loopback so every public client appeared as 127.0.0.1 and the per-IP
// cap collapsed to one shared bucket (codex security audit, 2026-06-11).
// Fix: when r.RemoteAddr is a loopback address, honor X-Real-IP (which the
// on-host nginx site sets — see nginx-coordinator.streamvc.live.conf).
// Direct, non-loopback hits (no proxy in front) use r.RemoteAddr unchanged.
// Returns "" if parsing fails so the caller skips the per-IP gate (the
// global semaphore still applies).
func remoteIPForUnauthSemaphore(remoteAddr string, header http.Header) string {
	if remoteAddr == "" {
		return ""
	}
	host, _, err := net.SplitHostPort(remoteAddr)
	if err != nil {
		host = remoteAddr
	}
	if isLoopbackHost(host) {
		if realIP := strings.TrimSpace(header.Get("X-Real-IP")); realIP != "" {
			return realIP
		}
	}
	return host
}

// isLoopbackHost reports whether host is an IPv4 or IPv6 loopback address.
// Anything not parseable as an IP is treated as non-loopback so the
// fallback path through r.RemoteAddr stays in play.
func isLoopbackHost(host string) bool {
	ip := net.ParseIP(host)
	if ip == nil {
		return false
	}
	return ip.IsLoopback()
}

func (s *Server) setReadDeadline(conn net.Conn, timeout time.Duration) {
	// Physical socket deadlines MUST use the real wall clock — the OS poller
	// compares SetReadDeadline against time.Now(), not our injectable logical
	// clock. In production s.now() == time.Now().UTC() so this is unchanged, but
	// a test that injects a frozen/offset clock (WithNow) would otherwise hand
	// the poller a deadline in the past, expiring the read immediately and
	// closing the handshake ("read auth_challenge: EOF"). s.now() stays the
	// source of truth for LOGICAL time (token/challenge expiry, epoch age).
	_ = conn.SetReadDeadline(time.Now().Add(timeout))
}

func (s *Server) enableProviderTCPKeepAlive(conn net.Conn) {
	tcp, ok := conn.(*net.TCPConn)
	if !ok {
		return
	}
	if err := tcp.SetKeepAlive(true); err != nil {
		s.log.Warn().Err(err).Msg("provider tcp keepalive enable failed")
	}
	if err := tcp.SetKeepAlivePeriod(30 * time.Second); err != nil {
		s.log.Warn().Err(err).Msg("provider tcp keepalive period failed")
	}
}

func (s *Server) setWriteDeadline(conn net.Conn) {
	// Real wall clock for the physical socket deadline — see setReadDeadline.
	_ = conn.SetWriteDeadline(time.Now().Add(s.cfg.ProviderWSWriteTimeout()))
}

func (s *Server) writeServerText(conn net.Conn, payload []byte) error {
	s.setWriteDeadline(conn)
	return wsutil.WriteServerText(conn, payload)
}

func (s *Server) writeServerMessage(conn net.Conn, op gobwas.OpCode, payload []byte) error {
	s.setWriteDeadline(conn)
	return wsutil.WriteServerMessage(conn, op, payload)
}

// readClientData reads the next data frame from conn, handling any inbound
// control frames inline. Control-frame replies (PONG, Close echo, protocol-
// error Close) are assembled into a single contiguous frame and delivered via
// controlReply.
//
// Two reply paths exist:
//
//   - Pre-handshake (handleConn / handleV2Conn before a providerSession has
//     been registered): callers pass directControlReply, which writes the
//     assembled frame straight to conn after re-arming the write deadline.
//     No runWriter exists yet, so there is no goroutine to race against.
//
//   - Post-handshake (readProviderLoop): callers pass session.enqueueRaw, so
//     the assembled frame is serialized through writeCh and emitted by the
//     single runWriter goroutine. This closes the framing-corruption hazard
//     where gobwas's ControlHandler would otherwise write header+payload in
//     two separate conn.Write calls that could interleave with an in-flight
//     coordinator→provider text frame (inference_request, cancel_request, …).
//
// We capture into a bytes.Buffer rather than writing through ControlHandler's
// destination directly because HandlePing/HandleClose emit the frame as
// TWO underlying Writes (one for the header, one for the body). Buffering
// folds them into a single payload runWriter (or directControlReply) can ship
// with one conn.Write — the unit of atomicity at the WS framing layer.
func (s *Server) readClientData(conn net.Conn, controlReply func([]byte) error) ([]byte, gobwas.OpCode, error) {
	controlHandler := func(hdr gobwas.Header, src io.Reader) error {
		var buf bytes.Buffer
		h := wsutil.ControlHandler{
			Src: src,
			Dst: &buf,
			// src is the enclosing wsutil.Reader which already unmasks the
			// frame payload as it Reads. ControlHandler's own cipher reader
			// would XOR a second time and corrupt the bytes — match the
			// invariant wsutil.ControlFrameHandler relies on.
			DisableSrcCiphering: true,
			State:               gobwas.StateServerSide,
		}
		handleErr := h.Handle(hdr)
		// Always attempt delivery if any reply bytes were assembled. HandleClose
		// returns a wsutil.ClosedError after the echo write succeeds, and the
		// internal protocol-error path returns its error after writing a Close
		// frame — in both cases the bytes still belong on the wire.
		if buf.Len() > 0 {
			reply := append([]byte(nil), buf.Bytes()...)
			if err := controlReply(reply); err != nil && handleErr == nil {
				handleErr = err
			}
		}
		return handleErr
	}
	rd := wsutil.Reader{
		Source:          conn,
		State:           gobwas.StateServerSide,
		CheckUTF8:       true,
		SkipHeaderCheck: false,
		MaxFrameSize:    s.cfg.ProviderWSMaxFrameBytes(),
		OnIntermediate:  controlHandler,
	}
	for {
		hdr, err := rd.NextFrame()
		if err != nil {
			return nil, 0, err
		}
		if hdr.OpCode.IsControl() {
			if err := controlHandler(hdr, &rd); err != nil {
				return nil, 0, err
			}
			continue
		}
		if hdr.OpCode&(gobwas.OpText|gobwas.OpBinary) == 0 {
			if err := rd.Discard(); err != nil {
				return nil, 0, err
			}
			continue
		}
		payload, err := io.ReadAll(&rd)
		return payload, hdr.OpCode, err
	}
}

// directControlReply is the pre-handshake reply path. Writes the fully-assembled
// control frame straight to conn after re-arming the write deadline. Socket
// write deadlines are absolute and are never cleared after a successful write,
// so an idle handshake conn's reactive PONG would otherwise inherit a stale,
// expired deadline and fail instantly with i/o timeout. Used only before a
// providerSession (and its runWriter) exists; once registerProviderSession has
// started runWriter the post-handshake reply path is session.enqueueRaw.
func (s *Server) directControlReply(conn net.Conn) func([]byte) error {
	return func(frame []byte) error {
		s.setWriteDeadline(conn)
		_, err := conn.Write(frame)
		return err
	}
}

func sessionKey(providerID, assignedID string) string {
	return providerID + "/" + assignedID
}

func (s *Server) storedSessionFor(providerID, assignedID string) (*providerSession, bool) {
	v, ok := s.sessions.Load(sessionKey(providerID, assignedID))
	if !ok {
		return nil, false
	}
	session, ok := v.(*providerSession)
	return session, ok
}

func (s *Server) sessionFor(providerID, assignedID string) (*providerSession, bool) {
	if _, ok := s.pool.Resolve(providerID, assignedID); !ok {
		return nil, false
	}
	return s.storedSessionFor(providerID, assignedID)
}

func (s *Server) connectedProvisional() int {
	n := 0
	for _, p := range s.pool.Snapshot() {
		if p.Tier == pool.TierProvisional {
			n++
		}
	}
	return n
}

func (s *Server) handleMessage(conn net.Conn, providerID, assignedID string, payload []byte) {
	var envelope struct {
		Type string `json:"type"`
	}
	if err := json.Unmarshal(payload, &envelope); err != nil {
		s.log.Warn().Err(err).Str("provider_id", providerID).Msg("invalid provider message json")
		return
	}
	// Any well-formed inbound frame (heartbeat OR in-flight inference response)
	// proves the provider is alive and following protocol — record activity so
	// the liveness monitor does not close a provider that cannot heartbeat
	// while its single slot is busy streaming a long generation. Unparseable
	// or non-text frames deliberately do NOT count, so a malfunctioning
	// provider emitting garbage is still reaped after the threshold.
	s.pool.Touch(providerID, assignedID, s.now())
	switch envelope.Type {
	case "heartbeat":
		s.handleHeartbeat(conn, providerID, assignedID, payload)
	case "diagnostic_status":
		s.handleDiagnosticStatus(conn, providerID, assignedID, payload)
	case "idle_prewarm_event":
		s.handleIdlePrewarmEvent(providerID, payload)
	case "state_update":
		s.handleStateUpdate(providerID, assignedID, payload)
	case "preflight_ack":
		s.handlePreflightAck(providerID, assignedID, payload)
	case "aead_rekey_response":
		s.handleAEADRekeyResponse(providerID, assignedID, payload)
	case "aead_rekey_committed":
		s.handleAEADRekeyCommitted(providerID, assignedID, payload)
	case "inference_response_chunk":
		s.handleInferenceChunk(providerID, assignedID, payload)
	case "inference_response_end":
		s.handleInferenceEnd(providerID, assignedID, payload)
	case "nak":
		s.handleNAK(providerID, assignedID, payload)
	case "drain_status":
		s.handleDrainStatus(conn, providerID, assignedID, payload)
	case "se_liveness_response":
		s.handleSELivenessResponse(providerID, assignedID, payload)
	case losslessnessResultType, losslessnessEncryptedResultType:
		s.handleLosslessnessProbeResult(providerID, assignedID, payload)
	default:
		// SPEC-002 v1.5.1 R-2 / issue #197 R5 security: envelope.Type
		// is provider-controlled and reaches structured logs only on
		// this unknown-message path. Reject control characters before
		// logging to defeat terminal-CSI log injection.
		safeType := envelope.Type
		if containsControlChar(safeType) {
			safeType = "[redacted_control_chars]"
		}
		s.log.Warn().Str("provider_id", providerID).Str("type", safeType).Msg("unknown provider message type")
	}
}

func (s *Server) handleDiagnosticStatus(conn net.Conn, providerID, assignedID string, payload []byte) {
	diag, field, err := ParseDiagnosticStatus(payload)
	if err != nil {
		s.log.Warn().Err(err).Str("field", field).Str("provider_id", providerID).Msg("invalid diagnostic_status")
		return
	}
	if diag.ProviderID != providerID {
		s.log.Warn().Str("provider_id", providerID).Msg("diagnostic_status provider_id mismatch")
		return
	}
	if diag.AssignedID == "" || diag.AssignedID != assignedID {
		s.log.Warn().Str("provider_id", providerID).Msg("diagnostic_status assigned_id mismatch")
		return
	}
	state := pool.State(diag.Status)
	if !validState(state) {
		s.log.Warn().Str("state", diag.Status).Str("provider_id", providerID).Msg("invalid diagnostic_status state")
		return
	}
	live, ok := s.pool.Resolve(providerID, assignedID)
	if !ok {
		s.log.Warn().Str("provider_id", providerID).Str("assigned_id", assignedID).Msg("diagnostic_status inactive session")
		return
	}
	activeConn, err := s.pool.Conn(providerID, assignedID)
	if err != nil || activeConn != conn {
		s.log.Warn().Err(err).Str("provider_id", providerID).Str("assigned_id", assignedID).Msg("diagnostic_status stale session")
		return
	}
	now := s.now().UTC()
	var observedAt *time.Time
	if diag.ObservedAt != "" {
		if parsed, parseErr := time.Parse(time.RFC3339Nano, diag.ObservedAt); parseErr == nil {
			t := parsed.UTC()
			observedAt = &t
		}
	}
	lastFailure, diagnosticAt := diagnosticFailureSummary(diag.LastConnectionFailure)
	if lastFailure != "" && diagnosticAt == nil {
		if observedAt != nil {
			diagnosticAt = observedAt
		} else {
			t := now
			diagnosticAt = &t
		}
	}
	lastKnown := providerevents.LastKnown{
		ProviderID:      providerID,
		AssignedID:      assignedID,
		BinaryVersion:   diag.BinaryVersion,
		ModelID:         diag.ModelID,
		ModelLoaded:     diag.ModelLoaded,
		ModelHash:       diag.ModelHash,
		State:           diag.Status,
		LastSeenAt:      now,
		RoutingEligible: state == pool.StateReady || state == pool.StateBusy,
		Presence:        "connected",
		Diagnostic:      lastFailure,
		DiagnosticAt:    diagnosticAt,
	}
	lastKnown.RoutingEligible = live.RoutingEligible()
	lastKnown.AuthState = string(live.AuthState)
	if lastKnown.BinaryVersion == "" {
		lastKnown.BinaryVersion = live.BinaryVersion
	}
	if !live.ConnectedAt.IsZero() {
		t := live.ConnectedAt.UTC()
		lastKnown.ConnectedAt = &t
	}
	if !live.LastHeartbeatAt.IsZero() {
		t := live.LastHeartbeatAt.UTC()
		lastKnown.LastHeartbeatAt = &t
	}
	if !live.LastActivityAt.IsZero() {
		t := live.LastActivityAt.UTC()
		lastKnown.LastActivityAt = &t
	}
	s.enqueueDiagnosticLastKnown(lastKnown)
}

func diagnosticFailureSummary(raw json.RawMessage) (string, *time.Time) {
	if len(raw) == 0 || string(raw) == "null" {
		return "", nil
	}
	var object struct {
		At         string `json:"at"`
		Diagnostic string `json:"diagnostic"`
	}
	if err := json.Unmarshal(raw, &object); err != nil {
		return "", nil
	}
	var failureAt *time.Time
	if object.At != "" {
		if parsed, err := time.Parse(time.RFC3339Nano, object.At); err == nil {
			t := parsed.UTC()
			failureAt = &t
		}
	}
	return providerevents.RedactDiagnostic(object.Diagnostic, providerevents.DefaultMaxDiagnostic), failureAt
}

func (s *Server) handleSELivenessResponse(providerID, assignedID string, payload []byte) {
	var resp SELivenessResponse
	if err := json.Unmarshal(payload, &resp); err != nil {
		s.log.Warn().Err(err).Str("provider_id", providerID).Msg("se_liveness: invalid response json")
		return
	}
	s.deliverSELivenessResponse(providerID, assignedID, resp)
}

func (s *Server) handleIdlePrewarmEvent(providerID string, payload []byte) {
	if s.idlePrewarm == nil {
		return
	}
	ev, field, err := ParseIdlePrewarmEvent(payload)
	if err != nil {
		s.log.Warn().Err(err).Str("field", field).Str("provider_id", providerID).Msg("invalid idle_prewarm_event")
		return
	}
	if !s.allowIdlePrewarmEvent(providerID) {
		s.log.Warn().Str("provider_id", providerID).Str("event", ev.Event).Msg("idle prewarm event rate limited")
		return
	}
	if s.idlePrewarmMetrics != nil {
		s.idlePrewarmMetrics.IncIdlePrewarmEvent(ev.Event, ev.Reason)
	}
	record := idlePrewarmRecord{providerID: providerID, event: ev.Event, reason: ev.Reason}
	select {
	case s.idlePrewarmQueue <- record:
	default:
		s.log.Warn().Str("provider_id", providerID).Str("event", ev.Event).Msg("idle prewarm event queue full; dropped")
	}
}

func (s *Server) runIdlePrewarmRecorder() {
	for record := range s.idlePrewarmQueue {
		ctx, cancel := context.WithTimeout(context.Background(), 2*time.Second)
		err := s.idlePrewarm.RecordIdlePrewarmEvent(ctx, record.providerID, record.event, record.reason)
		cancel()
		if err != nil {
			s.log.Warn().Err(err).Str("provider_id", record.providerID).Str("event", record.event).Msg("idle prewarm event record failed")
		}
	}
}

func (s *Server) allowIdlePrewarmEvent(providerID string) bool {
	now := s.now()
	s.pruneIdlePrewarmLimits(now)
	v, _ := s.idlePrewarmLimits.LoadOrStore(providerID, &idlePrewarmLimiter{
		tokens: idlePrewarmEventBurst,
		last:   now,
	})
	limiter := v.(*idlePrewarmLimiter)
	limiter.mu.Lock()
	defer limiter.mu.Unlock()
	if now.Before(limiter.last) {
		limiter.last = now
	}
	elapsed := int(now.Sub(limiter.last).Seconds())
	if elapsed > 0 {
		limiter.tokens += elapsed * idlePrewarmEventRefillPerSecond
		if limiter.tokens > idlePrewarmEventBurst {
			limiter.tokens = idlePrewarmEventBurst
		}
		limiter.last = limiter.last.Add(time.Duration(elapsed) * time.Second)
	}
	if limiter.tokens <= 0 {
		return false
	}
	limiter.tokens--
	return true
}

func (s *Server) pruneIdlePrewarmLimits(now time.Time) {
	s.idlePrewarmLimits.Range(func(key, value any) bool {
		limiter, ok := value.(*idlePrewarmLimiter)
		if !ok {
			s.idlePrewarmLimits.Delete(key)
			return true
		}
		limiter.mu.Lock()
		expired := now.Sub(limiter.last) > idlePrewarmLimiterTTL
		limiter.mu.Unlock()
		if expired {
			s.idlePrewarmLimits.Delete(key)
		}
		return true
	})
}

func (s *Server) handleDrainStatus(conn net.Conn, providerID, assignedID string, payload []byte) {
	status, field, err := ParseDrainStatus(payload)
	if err != nil {
		s.log.Warn().Err(err).Str("field", field).Str("provider_id", providerID).Msg("invalid drain_status")
		return
	}
	if status.Phase == "starting" {
		s.pool.MarkState(providerID, assignedID, pool.StateDraining)
	}
	s.log.Info().
		Str("provider_id", providerID).
		Str("phase", status.Phase).
		Int("inflight_requests", status.InflightRequests).
		Int("estimated_drain_seconds", status.EstimatedDrainSeconds).
		Msg("provider drain progress")
	if status.Phase == "complete" {
		_ = conn.Close()
	}
}

func (s *Server) Preflight(provider pool.Provider, requestID string, estimatedTokens int, timeout time.Duration) (PreflightAck, bool, error) {
	session, ok := s.sessionFor(provider.ProviderID, provider.AssignedID)
	if !ok {
		return PreflightAck{}, false, ErrRelayClosed
	}
	ch := make(chan PreflightAck, 1)
	s.pending.Store(requestID, pendingPreflight{providerID: provider.ProviderID, assignedID: provider.AssignedID, ch: ch})
	defer s.pending.Delete(requestID)
	msg := map[string]any{
		"type":             "preflight",
		"request_id":       requestID,
		"estimated_tokens": estimatedTokens,
	}
	payload, err := json.Marshal(msg)
	if err != nil {
		return PreflightAck{}, false, err
	}
	if err := session.sendProbe(payload, providerDispatchWriteProbeTimeout); err != nil {
		if errors.Is(err, ErrRelayClosed) {
			s.handleProviderWriteFailure(session, err)
		}
		return PreflightAck{}, false, err
	}
	timer := time.NewTimer(timeout)
	defer timer.Stop()
	select {
	case ack := <-ch:
		return ack, true, nil
	case <-timer.C:
		return PreflightAck{}, false, nil
	}
}

func (s *Server) startWarmupGate(provider pool.Provider) {
	s.warmups.Store(provider.ProviderID, provider.AssignedID)
	go s.runWarmupGate(provider)
}

func (s *Server) runWarmupGate(provider pool.Provider) {
	defer s.clearWarmupGate(provider.ProviderID, provider.AssignedID)
	attempts := s.cfg.Pool.DegradedMaxRetries
	if attempts <= 0 {
		attempts = config.Default().Pool.DegradedMaxRetries
	}
	delay := s.degradedBackoff()
	for attempt := 1; attempt <= attempts; attempt++ {
		if attempt > 1 {
			time.Sleep(delay)
			delay *= 2
		}
		if !s.warmupGateCurrent(provider.ProviderID, provider.AssignedID) {
			return
		}
		if s.runWarmupGateAttempt(provider, attempt) {
			s.clearWarmupGate(provider.ProviderID, provider.AssignedID)
			if s.pool.MarkState(provider.ProviderID, provider.AssignedID, pool.StateReady) {
				s.log.Info().Str("provider_id", provider.ProviderID).Int("attempt", attempt).Msg("warmup gate passed")
			}
			return
		}
		s.log.Warn().Str("provider_id", provider.ProviderID).Int("attempt", attempt).Str("reason", "warmup_failed").Msg("warmup gate attempt failed")
		s.recordConnectionEvent(providerevents.Event{
			ProviderID:    provider.ProviderID,
			SessionID:     provider.AssignedID,
			Kind:          providerevents.KindWarmupFailed,
			Outcome:       providerevents.OutcomeFailure,
			FailureReason: providerevents.ReasonWarmupFailed,
			AuthStage:     providerevents.AuthStageWarmup,
			MessageFamily: providerevents.MessageFamilyNone,
			BinaryVersion: provider.BinaryVersion,
			Diagnostic:    "warmup_attempt_failed",
		})
	}
	if s.pool.MarkState(provider.ProviderID, provider.AssignedID, pool.StateUnavailable) {
		s.log.Warn().Str("provider_id", provider.ProviderID).Str("reason", "warmup_failed").Msg("provider marked unavailable after warmup gate failures")
		s.recordConnectionEvent(providerevents.Event{
			ProviderID:    provider.ProviderID,
			SessionID:     provider.AssignedID,
			Kind:          providerevents.KindWarmupFailed,
			Outcome:       providerevents.OutcomeFailure,
			FailureReason: providerevents.ReasonWarmupFailed,
			AuthStage:     providerevents.AuthStageWarmup,
			MessageFamily: providerevents.MessageFamilyNone,
			BinaryVersion: provider.BinaryVersion,
			Diagnostic:    "warmup_gate_exhausted",
		})
	}
}

func (s *Server) runWarmupGateAttempt(provider pool.Provider, attempt int) bool {
	// #768 warm-pool candidate gate: we never warm a box we won't route to.
	// Checked here (not in the WS-only branch) so the HTTP-forwarding path is
	// covered by the same verdict.
	if s.belowModelVersionFloor(provider, "warmup_gate") {
		return false
	}
	if provider.AdmissionCeilingExcluded || provider.AdmissionEvidenceStale {
		return false
	}
	body, err := json.Marshal(map[string]any{
		"model": providerProbeModelID(provider),
		"messages": []map[string]string{{
			"role":    "user",
			"content": "Reply with ok.",
		}},
		"max_tokens": s.warmupGateMaxTokens(),
		"stream":     false,
	})
	if err != nil {
		return false
	}
	ctx, cancel := context.WithTimeout(context.Background(), s.warmupGateTimeout())
	defer cancel()
	if !provider.IsWSTunneled() {
		return s.runHTTPWarmupGateAttempt(ctx, provider, body)
	}
	return s.runWSWarmupGateAttempt(ctx, provider, attempt, body)
}

func providerProbeModelID(provider pool.Provider) string {
	if modelKey := strings.TrimSpace(provider.MaxAdmittedModelKey); modelKey != "" {
		return modelKey
	}
	return provider.ModelID
}

func (s *Server) runWSWarmupGateAttempt(ctx context.Context, provider pool.Provider, attempt int, body []byte) bool {
	if s.tier2WarmupExcluded(provider) {
		return false
	}
	requestID := "warmup-gate-" + provider.AssignedID + "-" + itoa(attempt)
	relay, err := s.DispatchInference(ctx, provider, requestID, body, false)
	if err != nil {
		return false
	}
	chunks := relay.Chunks
	observedOutput := false
	for {
		select {
		case chunk, ok := <-chunks:
			if !ok {
				chunks = nil
				continue
			}
			if warmupChunkHasOutput(chunk.Data) {
				observedOutput = true
			}
		case end := <-relay.Done:
			return warmupGatePassed(end, observedOutput)
		case <-relay.Errors:
			return false
		case <-ctx.Done():
			return false
		}
	}
}

func (s *Server) tier2WarmupExcluded(provider pool.Provider) bool {
	cfg := s.tier2Config()
	if tier2.ModelHashActive(cfg) {
		status := provider.HashStatus
		if status == "" {
			status = s.verifyProviderModelIdentity(provider.ModelID, provider.ExpectedModelHash, provider.ModelHash, provider.ModelHashAlgorithm)
		}
		if tier2.IsHashPredicateFailure(status, cfg.RequireHashVerified) {
			return true
		}
	}
	if cfg.RequireEncryptedLeg && !provider.EncryptedLeg {
		return true
	}
	if cfg.RequireAttestation && provider.AttestationStatus != pool.AttestationStatusAttested {
		return true
	}
	return false
}

func (s *Server) runHTTPWarmupGateAttempt(ctx context.Context, provider pool.Provider, body []byte) bool {
	endpoint := strings.TrimRight(strings.TrimSpace(provider.EndpointURL), "/")
	if endpoint == "" {
		return false
	}
	req, err := http.NewRequestWithContext(ctx, http.MethodPost, endpoint+"/v1/chat/completions", bytes.NewReader(body))
	if err != nil {
		return false
	}
	req.Header.Set("Content-Type", "application/json")
	resp, err := providerhttp.Client.Do(req)
	if err != nil {
		return false
	}
	defer resp.Body.Close()
	if resp.StatusCode != http.StatusOK {
		return false
	}
	raw, err := io.ReadAll(io.LimitReader(resp.Body, 1<<20))
	if err != nil {
		return false
	}
	return warmupPayloadHasOutput(raw) && warmupCompletionUsagePassed(raw)
}

func (s *Server) runCanaryLoop() {
	s.runCanarySweep()
	ticker := time.NewTicker(s.canarySweepCadence())
	defer ticker.Stop()
	for range ticker.C {
		s.runCanarySweep()
	}
}

func (s *Server) runCanarySweep() {
	// FR-CAN23: resolve any open multi-provider epochs whose FR-CAN12 window elapsed.
	s.expireCanaryCorrelationWindows()
	now := s.now()
	activeKeys := map[string]struct{}{}
	for _, provider := range shuffledProviders(s.pool.Snapshot()) {
		dueKey := provider.ProviderID
		activeKeys[dueKey] = struct{}{}
		nextDue, scheduled := s.canaryDue.Load(dueKey)
		if !scheduled {
			s.scheduleNextCanaryProbe(dueKey, now)
			continue
		}
		if due, ok := nextDue.(time.Time); ok && now.Before(due) {
			continue
		}
		// Eligibility and epoch capture are one recovery-fenced decision.
		// Once the read lock is released, any operator recovery increments the
		// epoch before this probe can apply its result.
		s.canaryRecoveryMu.RLock()
		if !s.canaryProbeEligible(provider) {
			s.canaryRecoveryMu.RUnlock()
			continue
		}
		key := sessionKey(provider.ProviderID, provider.AssignedID)
		if _, loaded := s.canaries.LoadOrStore(key, struct{}{}); loaded {
			s.canaryRecoveryMu.RUnlock()
			continue
		}
		epoch := s.canaryEpoch(provider.ProviderID).Load()
		s.canaryRecoveryMu.RUnlock()
		go func(provider pool.Provider, key, dueKey string, epoch uint64) {
			defer s.canaries.Delete(key)
			if s.runCanaryProbeAtEpoch(provider, epoch) {
				s.scheduleNextCanaryProbe(dueKey, s.now())
			}
		}(provider, key, dueKey, epoch)
	}
	s.canaryDue.Range(func(key, _ any) bool {
		typedKey, ok := key.(string)
		if !ok {
			s.canaryDue.Delete(key)
			return true
		}
		if _, active := activeKeys[typedKey]; !active {
			s.canaryDue.Delete(key)
		}
		return true
	})
}

func (s *Server) scheduleNextCanaryProbe(key string, from time.Time) {
	s.canaryDue.Store(key, from.Add(jitteredCanaryInterval(s.canaryInterval())))
}

func (s *Server) canaryProbeEligible(provider pool.Provider) bool {
	if s.pool.CanaryRecoveryEligible(provider.ProviderID, provider.AssignedID) {
		if provider.State != pool.StateDegraded {
			return false
		}
	} else if !provider.RoutingEligible() && !provider.AdmissionSandboxed {
		return false
	}
	if provider.SlotsFree <= 0 {
		return false
	}
	if s.warmupGatePending(provider.ProviderID) {
		return false
	}
	if provider.IsWSTunneled() {
		_, ok := s.sessionFor(provider.ProviderID, provider.AssignedID)
		return ok
	}
	return strings.TrimSpace(provider.EndpointURL) != ""
}

type canaryProbeOutcome string

const (
	canaryProbePass canaryProbeOutcome = "pass"
	canaryProbeFail canaryProbeOutcome = "fail"
	canaryProbeSkip canaryProbeOutcome = "skip"
)

func (s *Server) runCanaryProbe(provider pool.Provider) bool {
	return s.runCanaryProbeAtEpoch(provider, s.canaryEpoch(provider.ProviderID).Load())
}

func (s *Server) runCanaryProbeAtEpoch(provider pool.Provider, epoch uint64) bool {
	attempt := s.runCanaryProbeAttempt(provider)
	s.canaryRecoveryMu.RLock()
	defer s.canaryRecoveryMu.RUnlock()
	if s.canaryEpoch(provider.ProviderID).Load() != epoch {
		s.log.Info().
			Str("provider_id", provider.ProviderID).
			Msg("discarding canary result invalidated by operator recovery")
		return false
	}
	outcome := attempt.outcome
	// Issue #764: the canary is the coordinator's only live TTFT/TPS
	// measurement. Recording it on the pool entry is what makes /poolz able to
	// segment latency by binary_version and isolate a slow backend build.
	s.pool.RecordCanaryLatency(provider.ProviderID, provider.AssignedID, attempt.metrics.TTFTMS, attempt.metrics.SustainedTPS)
	if attempt.modelClassBank {
		pass := outcome == canaryProbePass
		s.pool.SetModelClassOPoIPass(provider.ProviderID, provider.AssignedID, &pass)
		if telemetryDrift, _ := s.telemetryDriftEvaluator(); telemetryDrift != nil {
			s.logTelemetryDriftAlerts(telemetryDrift.RecordModelClassCanary(provider, pass))
		}
	}
	if outcome == canaryProbeSkip {
		s.log.Debug().Str("provider_id", provider.ProviderID).Msg("provider canary skipped")
		return false
	}
	// Observe mode (default): a nonce-correct probe that breaches a wall-time
	// latency gate is NOT sanctioned (the non-streaming metric is unreliable),
	// but the breach is logged so operators keep the signal. TPS drift is also
	// tracked via proof_of_weights.telemetry_drift.
	if outcome == canaryProbePass && attempt.modelClassBank && !s.cfg.Pool.CanaryLatencyEnforced() &&
		challengeLatencyBreach(attempt.challenge, attempt.metrics) {
		s.log.Info().
			Str("provider_id", provider.ProviderID).
			Str("canary_latency_reason", string(latencyBreachReason(attempt.challenge, attempt.metrics))).
			Int("canary_ttft_ms", attempt.metrics.TTFTMS).
			Int("max_ttft_ms", attempt.challenge.MaxTTFTMS).
			Float64("canary_sustained_tps", attempt.metrics.SustainedTPS).
			Float64("min_sustained_tps", attempt.challenge.MinSustainedTPS).
			Msg("provider canary latency breach observed (not enforced)")
	}
	// Neutral only when the probe PASSED because of grace. LatencyGraced is set
	// on a latency breach before the correctness check, so a wrong-nonce answer
	// that is also latency-breaching would otherwise be neutralized here and
	// partially waive the correctness gate (R3 SECURITY/ARCHITECT HIGH). A
	// failing (wrong-nonce) probe must fall through and be recorded as a failure.
	if outcome == canaryProbePass && attempt.metrics.LatencyGraced {
		s.log.Info().
			Str("provider_id", provider.ProviderID).
			Int("canary_ttft_ms", attempt.metrics.TTFTMS).
			Int("max_ttft_ms", attempt.challenge.MaxTTFTMS).
			Dur("connected_age", s.now().Sub(provider.ConnectedAt)).
			Msg("provider canary TTFT gate waived during cold-start grace window")
		// A graced (correct-but-TTFT-slow) probe is NEUTRAL for the canary
		// sanction counter: it is not recorded, so it neither counts as a
		// failure nor CLEARS failures accrued on enforced probes (R2 SECURITY
		// HIGH). It also FORCES the next probe to be enforced, so a
		// chronically-slow provider cannot arrange (via reconnect / due-timing
		// churn) to only ever be probed under grace (R3 SECURITY HIGH).
		// Correctness + model-class OPoI liveness (NOT a weight-identity proof;
		// see SPEC-032 FR-PW1) were already recorded above.
		s.enforceNextCanary.Store(provider.ProviderID, struct{}{})
		return true
	}
	class := mapCanaryFailClass(outcome, attempt.metrics.FailReason)
	if s.shouldRouteThroughCorrelation(provider, class) {
		return s.applyCanaryViaCorrelation(provider, attempt, class, epoch)
	}
	// Snapshot members of an open epoch must never sanction outside resolve.
	if s.providerInOpenCorrelation(provider.ProviderID) {
		s.log.Info().
			Str("provider_id", provider.ProviderID).
			Msg("holding canary result for open FR-CAN23 epoch (no immediate apply)")
		return true
	}
	return s.applyCanaryImmediate(provider, attempt, epoch)
}

// applyCanaryImmediate records a canary result on the ordinary FR-CAN11/22 path
// (no multi-provider correlation staging).
func (s *Server) applyCanaryImmediate(provider pool.Provider, attempt canaryAttemptResult, recoveryEpoch uint64) bool {
	_ = recoveryEpoch // fencing already applied by runCanaryProbeAtEpoch
	passed := attempt.outcome == canaryProbePass
	return s.applyCanaryRecord(provider.ProviderID, provider.AssignedID, passed, attempt, false)
}

func (s *Server) saveCanarySanction(snapshot pool.CanarySanctionSnapshot) {
	if s.canarySanctions == nil {
		return
	}
	ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
	defer cancel()
	if err := s.canarySanctions.UpsertCanarySanction(ctx, snapshot); err != nil {
		s.log.Warn().Err(err).Str("provider_id", snapshot.ProviderID).Msg("canary sanction persistence failed")
	}
}

func (s *Server) deleteCanarySanction(providerID string) error {
	if s.canarySanctions == nil {
		return nil
	}
	ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
	defer cancel()
	if err := s.canarySanctions.DeleteCanarySanction(ctx, providerID); err != nil {
		s.log.Warn().Err(err).Str("provider_id", providerID).Msg("canary sanction deletion failed")
		return err
	}
	return nil
}

func (s *Server) canaryEpoch(providerID string) *atomic.Uint64 {
	epoch, _ := s.canaryEpochs.LoadOrStore(providerID, &atomic.Uint64{})
	return epoch.(*atomic.Uint64)
}

func (s *Server) runCanaryProbeAttempt(provider pool.Provider) canaryAttemptResult {
	probeModelID := providerProbeModelID(provider)
	challenges, modelClassBank := s.cfg.Pool.CanaryChallengesForModel(probeModelID)
	var probe canaryBuiltProbe
	var sharedBankGen uint64
	var shared sharedCanaryDispatch
	var hadShared bool
	if d, ok := s.takeSharedCanaryDispatch(provider.ProviderID); ok {
		// FR-CAN23: re-dispatch the same challenge fingerprint as the open epoch.
		shared = d
		hadShared = true
		probe = d.probe
		sharedBankGen = d.bankGeneration
		if probe.ModelClassBank {
			modelClassBank = true
		}
	} else {
		built, err := buildCanaryProbe(probeModelID, s.canaryMaxTokens(), challenges, modelClassBank)
		if err != nil {
			return canaryAttemptResult{outcome: canaryProbeSkip}
		}
		probe = built
	}
	ctx, cancel := context.WithTimeout(context.Background(), s.canaryTimeout())
	defer cancel()
	var outcome canaryProbeOutcome
	var metrics canaryProbeMetrics
	if !provider.IsWSTunneled() {
		outcome, metrics = s.runHTTPCanaryProbeAttempt(ctx, provider, probe)
	} else {
		outcome, metrics = s.runWSCanaryProbeAttempt(ctx, provider, probe)
	}
	if outcome == canaryProbeSkip && hadShared {
		s.requeueSharedCanaryDispatch(provider.ProviderID, shared)
	}
	if challengeHasLatencyGates(probe.Challenge) {
		metrics.LatencyGated = true
	}
	return canaryAttemptResult{
		outcome:        outcome,
		metrics:        metrics,
		modelClassBank: probe.ModelClassBank || modelClassBank,
		challenge:      probe.Challenge,
		probe:          probe,
		sharedBankGen:  sharedBankGen,
	}
}

func (s *Server) runWSCanaryProbeAttempt(ctx context.Context, provider pool.Provider, probe canaryBuiltProbe) (canaryProbeOutcome, canaryProbeMetrics) {
	if s.tier2WarmupExcluded(provider) {
		return canaryProbeSkip, canaryProbeMetrics{}
	}
	requestID := s.newUUID()
	start := time.Now()
	relay, err := s.DispatchInference(ctx, provider, requestID, probe.Body, false)
	if err != nil {
		return canaryProbeSkip, canaryProbeMetrics{}
	}
	chunks := relay.Chunks
	var output strings.Builder
	var firstTokenAt time.Time
	var rawResponse strings.Builder
	for {
		select {
		case chunk, ok := <-chunks:
			if !ok {
				chunks = nil
				continue
			}
			if firstTokenAt.IsZero() {
				firstTokenAt = time.Now()
			}
			rawResponse.WriteString(chunk.Data)
			output.WriteString(canaryChunkContent(chunk.Data))
		case end := <-relay.Done:
			completedAt := time.Now()
			metrics := canaryProbeMetrics{}
			if challengeHasLatencyGates(probe.Challenge) {
				tokens := canaryCompletionTokens([]byte(rawResponse.String()))
				if tokens == 0 {
					tokens = len(strings.Fields(output.String()))
					if tokens == 0 {
						tokens = 1
					}
				}
				metrics = canaryMetricsFromTiming(start, firstTokenAt, completedAt, tokens)
			}
			if end.Status != "complete" {
				metrics.FailReason = canaryFailIncomplete
				return canaryProbeFail, metrics
			}
			enforceLatency := s.cfg.Pool.CanaryLatencyEnforced()
			grace := enforceLatency && s.canaryColdStartActive(provider)
			if grace && challengeLatencyBreach(probe.Challenge, metrics) {
				metrics.LatencyGraced = true
			}
			outcome, reason := evaluateCanaryProbe(probe.Challenge, output.String(), probe.Expected, metrics, grace, enforceLatency)
			metrics.FailReason = reason
			return outcome, metrics
		case <-relay.Errors:
			return canaryProbeFail, canaryProbeMetrics{FailReason: canaryFailRelay}
		case <-ctx.Done():
			return canaryProbeFail, canaryProbeMetrics{FailReason: canaryFailRelay}
		}
	}
}

func (s *Server) runHTTPCanaryProbeAttempt(ctx context.Context, provider pool.Provider, probe canaryBuiltProbe) (canaryProbeOutcome, canaryProbeMetrics) {
	endpoint := strings.TrimRight(strings.TrimSpace(provider.EndpointURL), "/")
	if endpoint == "" {
		return canaryProbeSkip, canaryProbeMetrics{}
	}
	start := time.Now()
	req, err := http.NewRequestWithContext(ctx, http.MethodPost, endpoint+"/v1/chat/completions", bytes.NewReader(probe.Body))
	if err != nil {
		return canaryProbeSkip, canaryProbeMetrics{}
	}
	req.Header.Set("Content-Type", "application/json")
	resp, err := providerhttp.Client.Do(req)
	if err != nil {
		return canaryProbeFail, canaryProbeMetrics{FailReason: canaryFailRelay}
	}
	defer resp.Body.Close()
	if resp.StatusCode != http.StatusOK {
		return canaryProbeFail, canaryProbeMetrics{FailReason: canaryFailRelay}
	}
	raw, err := io.ReadAll(io.LimitReader(resp.Body, 1<<20))
	if err != nil {
		return canaryProbeFail, canaryProbeMetrics{FailReason: canaryFailRelay}
	}
	completedAt := time.Now()
	output := strings.Join(canaryPayloadContents(raw), "")
	metrics := canaryProbeMetrics{}
	if challengeHasLatencyGates(probe.Challenge) {
		tokens := canaryCompletionTokens(raw)
		if tokens == 0 {
			tokens = len(strings.Fields(output))
			if tokens == 0 {
				tokens = 1
			}
		}
		metrics = canaryMetricsFromTiming(start, time.Time{}, completedAt, tokens)
	}
	enforceLatency := s.cfg.Pool.CanaryLatencyEnforced()
	grace := enforceLatency && s.canaryColdStartActive(provider)
	if grace && challengeLatencyBreach(probe.Challenge, metrics) {
		metrics.LatencyGraced = true
	}
	outcome, reason := evaluateCanaryProbe(probe.Challenge, output, probe.Expected, metrics, grace, enforceLatency)
	metrics.FailReason = reason
	return outcome, metrics
}

// canaryColdStartActive reports whether the next canary probe for this provider
// should waive the wall-time latency gates (a freshly (re)connected provider may
// still be cold-loading a large model). Grace applies only while the provider is
// within the configured window since ConnectedAt AND its NEXT probe is not
// flagged for enforcement. The nonce-correctness gate is never relaxed (see
// evaluateCanaryProbe), and a graced probe is neutral for sanctions and forces
// the following probe to be enforced (see runCanaryProbe), so a chronically-slow
// provider cannot evade the TTFT sanction via reconnect / due-timing churn — it
// still fails the interleaved enforced probes and accrues canary failures.
func (s *Server) canaryColdStartActive(provider pool.Provider) bool {
	grace := s.cfg.Pool.CanaryColdStartGraceS
	if grace <= 0 || provider.ConnectedAt.IsZero() || strings.TrimSpace(provider.ProviderID) == "" {
		return false
	}
	age := s.now().Sub(provider.ConnectedAt)
	// Only a genuinely recent, non-future connect is within the cold-start window.
	if age < 0 || age >= time.Duration(grace)*time.Second {
		return false
	}
	// A graced probe must be followed by an enforced one before grace re-arms.
	if _, mustEnforce := s.enforceNextCanary.Load(provider.ProviderID); mustEnforce {
		return false
	}
	return true
}

func (s *Server) buildCanaryBody(modelID string, maxTokens int) ([]byte, string, error) {
	challenges, _ := s.cfg.Pool.CanaryChallengesForModel(modelID)
	body, expected, _, err := buildCanaryBodyFromBank(modelID, maxTokens, challenges)
	return body, expected, err
}

func buildCanaryBody(modelID string, maxTokens int, challenges []config.CanaryChallengeConfig) ([]byte, string, error) {
	body, expected, _, err := buildCanaryBodyFromBank(modelID, maxTokens, challenges)
	return body, expected, err
}

func buildCanaryBodyFromRandom(modelID string, maxTokens int, challenges []config.CanaryChallengeConfig, random []byte) ([]byte, string, error) {
	body, expected, _, err := buildCanaryBodyFromRandomWithChallenge(modelID, maxTokens, challenges, random)
	return body, expected, err
}

func canaryAnswerMatches(output, expected string) bool {
	return strings.TrimSpace(output) == expected
}

func jitteredCanaryInterval(base time.Duration) time.Duration {
	if base <= 0 {
		return 0
	}
	spread := int64(base)
	offset, err := randomInt64(spread)
	if err != nil {
		return base
	}
	return base/2 + time.Duration(offset)
}

func shuffledProviders(providers []pool.Provider) []pool.Provider {
	shuffled := append([]pool.Provider(nil), providers...)
	for i := len(shuffled) - 1; i > 0; i-- {
		j, err := randomInt(i + 1)
		if err != nil {
			return shuffled
		}
		shuffled[i], shuffled[j] = shuffled[j], shuffled[i]
	}
	return shuffled
}

func randomInt(max int) (int, error) {
	n, err := randomInt64(int64(max))
	return int(n), err
}

func randomInt64(max int64) (int64, error) {
	if max <= 0 {
		return 0, errors.New("random bound must be positive")
	}
	n, err := rand.Int(rand.Reader, big.NewInt(max))
	if err != nil {
		return 0, err
	}
	return n.Int64(), nil
}

func canaryChunkContent(data string) string {
	var out strings.Builder
	hasDataLines := false
	for _, line := range strings.Split(data, "\n") {
		line = strings.TrimSpace(line)
		if !strings.HasPrefix(line, "data:") {
			continue
		}
		hasDataLines = true
		payload := strings.TrimSpace(strings.TrimPrefix(line, "data:"))
		if payload == "" || payload == "[DONE]" {
			continue
		}
		out.WriteString(strings.Join(canaryPayloadContents([]byte(payload)), ""))
	}
	if hasDataLines {
		return out.String()
	}
	return strings.Join(canaryPayloadContents([]byte(data)), "")
}

func canaryPayloadContents(raw []byte) []string {
	var resp struct {
		Choices []struct {
			Message struct {
				Content json.RawMessage `json:"content"`
			} `json:"message"`
			Delta struct {
				Content json.RawMessage `json:"content"`
			} `json:"delta"`
			Text json.RawMessage `json:"text"`
		} `json:"choices"`
	}
	if err := json.Unmarshal(raw, &resp); err != nil {
		return nil
	}
	var out []string
	for _, choice := range resp.Choices {
		out = append(out, rawJSONTextValues(choice.Message.Content)...)
		out = append(out, rawJSONTextValues(choice.Delta.Content)...)
		out = append(out, rawJSONTextValues(choice.Text)...)
	}
	return out
}

func rawJSONTextValues(raw json.RawMessage) []string {
	if len(raw) == 0 || string(raw) == "null" {
		return nil
	}
	var value any
	if err := json.Unmarshal(raw, &value); err != nil {
		return nil
	}
	return textValues(value)
}

func textValues(value any) []string {
	switch v := value.(type) {
	case string:
		return []string{v}
	case []any:
		var out []string
		for _, item := range v {
			out = append(out, textValues(item)...)
		}
		return out
	case map[string]any:
		var out []string
		for _, key := range []string{"text", "content"} {
			out = append(out, textValues(v[key])...)
		}
		return out
	default:
		return nil
	}
}

func warmupGatePassed(end InferenceResponseEnd, observedOutput bool) bool {
	if end.Status != "complete" {
		return false
	}
	if !observedOutput {
		return false
	}
	return warmupUsagePassed(end.Usage)
}

func warmupUsagePassed(raw json.RawMessage) bool {
	if len(raw) == 0 {
		return false
	}
	var usage struct {
		CompletionTokens int `json:"completion_tokens"`
	}
	if err := json.Unmarshal(raw, &usage); err != nil {
		return false
	}
	return usage.CompletionTokens > 0
}

func warmupCompletionUsagePassed(raw []byte) bool {
	var resp struct {
		Usage json.RawMessage `json:"usage"`
	}
	if err := json.Unmarshal(raw, &resp); err != nil {
		return false
	}
	return warmupUsagePassed(resp.Usage)
}

func warmupChunkHasOutput(data string) bool {
	hasDataLines := false
	for _, line := range strings.Split(data, "\n") {
		line = strings.TrimSpace(line)
		if !strings.HasPrefix(line, "data:") {
			continue
		}
		hasDataLines = true
		payload := strings.TrimSpace(strings.TrimPrefix(line, "data:"))
		if payload == "" || payload == "[DONE]" {
			continue
		}
		if warmupPayloadHasOutput([]byte(payload)) {
			return true
		}
	}
	if hasDataLines {
		return false
	}
	return warmupPayloadHasOutput([]byte(data))
}

func warmupPayloadHasOutput(raw []byte) bool {
	var resp struct {
		Choices []struct {
			Message struct {
				Content json.RawMessage `json:"content"`
			} `json:"message"`
			Delta struct {
				Content json.RawMessage `json:"content"`
			} `json:"delta"`
			Text json.RawMessage `json:"text"`
		} `json:"choices"`
	}
	if err := json.Unmarshal(raw, &resp); err != nil {
		return false
	}
	for _, choice := range resp.Choices {
		if rawJSONHasText(choice.Message.Content) || rawJSONHasText(choice.Delta.Content) || rawJSONHasText(choice.Text) {
			return true
		}
	}
	return false
}

func rawJSONHasText(raw json.RawMessage) bool {
	if len(raw) == 0 || string(raw) == "null" {
		return false
	}
	var value any
	if err := json.Unmarshal(raw, &value); err != nil {
		return false
	}
	return valueHasText(value)
}

func valueHasText(value any) bool {
	switch v := value.(type) {
	case string:
		return strings.TrimSpace(v) != ""
	case []any:
		for _, item := range v {
			if valueHasText(item) {
				return true
			}
		}
	case map[string]any:
		for _, key := range []string{"text", "content"} {
			if valueHasText(v[key]) {
				return true
			}
		}
	}
	return false
}

func (s *Server) warmupGateCurrent(providerID, assignedID string) bool {
	value, ok := s.warmups.Load(providerID)
	return ok && value.(string) == assignedID
}

func (s *Server) warmupGatePending(providerID string) bool {
	_, ok := s.warmups.Load(providerID)
	return ok
}

func (s *Server) clearWarmupGate(providerID, assignedID string) {
	value, ok := s.warmups.Load(providerID)
	if ok && value.(string) == assignedID {
		s.warmups.Delete(providerID)
	}
}

func (s *Server) DrainAll(reason string) {
	for _, provider := range s.pool.Snapshot() {
		session, ok := s.sessionFor(provider.ProviderID, provider.AssignedID)
		if !ok {
			continue
		}
		if err := session.send([]byte(`{"type":"drain"}`)); err != nil {
			s.log.Warn().Err(err).Str("provider_id", provider.ProviderID).Str("reason", reason).Msg("drain write failed")
			continue
		}
		s.pool.MarkState(provider.ProviderID, provider.AssignedID, pool.StateDraining)
		s.log.Info().Str("provider_id", provider.ProviderID).Str("reason", reason).Msg("provider drain sent")
	}
}

// CloseAllProviderSessions tears down hijacked provider sockets so final
// disconnect events can still enqueue before FlushConnectionEvents.
func (s *Server) CloseAllProviderSessions(reason string) {
	if s == nil {
		return
	}
	s.sessions.Range(func(key, value any) bool {
		session, ok := value.(*providerSession)
		if !ok || session == nil {
			return true
		}
		s.log.Info().
			Str("provider_id", session.providerID).
			Str("reason", reason).
			Msg("closing provider session for shutdown")
		_ = s.takeCloseEvent(session.conn)
		session.close()
		s.sessions.Delete(key)
		if session.conn != nil {
			_ = session.conn.Close()
		}
		return true
	})
}

// WaitProviderConnections blocks until in-flight provider WS handlers exit or
// the timeout elapses. Used before journal flush on shutdown.
func (s *Server) WaitProviderConnections(timeout time.Duration) {
	if s == nil {
		return
	}
	done := make(chan struct{})
	go func() {
		s.providerConnWG.Wait()
		close(done)
	}()
	if timeout <= 0 {
		timeout = 2 * time.Second
	}
	select {
	case <-done:
	case <-time.After(timeout):
		s.log.Warn().Msg("provider websocket handlers did not quiesce before journal flush")
	}
}

func (s *Server) handlePreflightAck(providerID, assignedID string, payload []byte) {
	ack, field, err := ParsePreflightAck(payload)
	if err != nil {
		s.log.Warn().Err(err).Str("field", field).Str("provider_id", providerID).Msg("invalid preflight_ack")
		return
	}
	if pending, ok := s.pending.Load(ack.RequestID); ok {
		pf := pending.(pendingPreflight)
		if pf.providerID != providerID || pf.assignedID != assignedID {
			s.log.Warn().Str("provider_id", providerID).Str("expected_provider_id", pf.providerID).Str("request_id", ack.RequestID).Msg("preflight_ack from wrong provider")
			return
		}
		if _, ok := s.sessionFor(providerID, assignedID); !ok {
			s.log.Warn().Str("provider_id", providerID).Str("assigned_id", assignedID).Str("request_id", ack.RequestID).Msg("preflight_ack from stale provider session")
			return
		}
		select {
		case pf.ch <- ack:
		default:
		}
		return
	}
	s.log.Warn().Str("provider_id", providerID).Str("request_id", ack.RequestID).Msg("unexpected preflight_ack")
}

// maxConcurrencyCeiling is the operator cap on provider-reported concurrency.
// 0 (or negative, which Validate rejects) disables the clamp.
func (s *Server) maxConcurrencyCeiling() int {
	return s.cfg.Pool.MaxConcurrencyCeiling
}

// clampProviderCapacity applies the ceiling to one provider-reported triple.
// Every provider-controlled capacity ingest point MUST route through this.
func (s *Server) clampProviderCapacity(maxConcurrency, slotsTotal, slotsFree int) pool.ClampedCapacity {
	return pool.ClampCapacity(maxConcurrency, slotsTotal, slotsFree, s.maxConcurrencyCeiling())
}

// recordCapacityOverClaim fires the permanent tripwire. It is called once per
// offending frame and never decrements; the counter is monotonic for the
// process lifetime by construction (prometheus.Counter).
func (s *Server) recordCapacityOverClaim(phase string) {
	if s.capacityOverClaimMetrics != nil {
		s.capacityOverClaimMetrics.IncCapacityOverClaim(phase)
	}
}

// applyBenchmarkQuarantine translates the issue-#765 verdict into the pool's
// fail-suspect flag. BenchmarkVerdictUnknown (gate off, evaluator off, or an
// evidence-store error) deliberately leaves the flag untouched.
func (s *Server) applyBenchmarkQuarantine(providerID, assignedID, modelID string, verdict pow.BenchmarkVerdict, telemetryGeneration uint64) {
	var quarantined bool
	switch verdict {
	case pow.BenchmarkVerdictMissing:
		quarantined = true
	case pow.BenchmarkVerdictVerified:
		quarantined = false
	default:
		return
	}
	s.telemetryDriftMu.RLock()
	defer s.telemetryDriftMu.RUnlock()
	if s.telemetryDriftGeneration != telemetryGeneration {
		return
	}
	if !s.pool.SetBenchmarkQuarantine(providerID, assignedID, quarantined) {
		return
	}
	s.log.Warn().
		Str("event", EventProviderBenchmarkQuarantine).
		Str("provider_id", providerID).
		Str("assigned_id", assignedID).
		Str("model_id", modelID).
		Bool("quarantined", quarantined).
		Msg("provider verified-benchmark quarantine state changed")
}

func (s *Server) handleHeartbeat(conn net.Conn, providerID, assignedID string, payload []byte) {
	hb, presence, field, err := ParseHeartbeat(payload)
	if err != nil {
		s.log.Warn().Err(err).Str("field", field).Str("provider_id", providerID).Msg("invalid heartbeat")
		if field == "model_hash" || field == "model_hash_algorithm" {
			s.fenceInvalidModelIdentity(conn, providerID, assignedID)
		}
		return
	}
	state := pool.State(hb.Status)
	if !validState(state) {
		s.log.Warn().Str("state", hb.Status).Str("provider_id", providerID).Msg("invalid heartbeat state")
		return
	}
	if state == pool.StateReady && s.warmupGatePending(providerID) {
		state = pool.StateDegraded
	}
	if hb.SafetyTelemetry != nil && hb.SafetyTelemetry.ProviderID != providerID {
		s.log.Warn().Str("provider_id", providerID).Msg("heartbeat safety telemetry provider_id mismatch")
		return
	}
	if hb.SafetyTelemetry != nil && hb.SafetyTelemetry.SchemaVersion == 2 &&
		hb.SafetyTelemetry.CoordinatorSessionID != assignedID {
		s.log.Warn().Str("provider_id", providerID).Msg("heartbeat safety telemetry coordinator session mismatch")
		return
	}
	expectedModelHash := s.expectedProviderModelHash(providerID, assignedID, hb.ModelID)
	if tier2.ModelHashActive(s.tier2Config()) {
		status := s.verifyProviderModelIdentity(hb.ModelID, expectedModelHash, hb.ModelHash, hb.ModelHashAlgorithm)
		if status == pool.HashStatusInvalid {
			s.fenceInvalidModelIdentity(conn, providerID, assignedID)
			return
		}
	}
	// Issue #764: clamp before ApplyHeartbeat, which assigns MaxConcurrency /
	// SlotsTotal / SlotsFree onto the pool entry verbatim. Clamping here (rather
	// than inside the registry) keeps the ceiling a single ingest-side concern
	// and covers the relay's admission check, which reads
	// provider.MaxConcurrency straight off the pool entry.
	capacity := s.clampProviderCapacity(hb.MaxConcurrency, hb.SlotsTotal, hb.SlotsFree)
	if capacity.OverClaimed {
		s.recordCapacityOverClaim(capacityPhaseHeartbeat)
		s.log.Warn().
			Str("event", EventProviderCapacityOverClaim).
			Str("provider_id", providerID).
			Str("phase", capacityPhaseHeartbeat).
			Int("reported_max_concurrency", capacity.ReportedMax).
			Int("reported_slots_total", hb.SlotsTotal).
			Int("ceiling", s.maxConcurrencyCeiling()).
			Int("effective_max_concurrency", capacity.MaxConcurrency).
			Int("effective_slots_total", capacity.SlotsTotal).
			Msg("provider capacity claim exceeds the operator ceiling; clamped")
	}
	heartbeatResult := s.pool.ApplyHeartbeatDetailed(providerID, assignedID, pool.HeartbeatUpdate{
		Status:                    state,
		ModelID:                   hb.ModelID,
		ModelParamsB:              hb.ModelParamsB,
		RAMGB:                     hb.RAMGB,
		MaxContextTokens:          hb.MaxContextTokens,
		MaxConcurrency:            capacity.MaxConcurrency,
		SlotsFree:                 capacity.SlotsFree,
		SlotsTotal:                capacity.SlotsTotal,
		ThroughputTPSEstimate:     hb.ThroughputTPSEstimate,
		RequestsServedSinceLast:   hb.RequestsServedSinceLast,
		ThroughputTPSSinceLast:    hb.ThroughputTPSSinceLast,
		ModelHash:                 hb.ModelHash,
		ModelHashPresent:          presence.ModelHash,
		ModelHashAlgorithm:        hb.ModelHashAlgorithm,
		ModelHashAlgorithmPresent: presence.ModelHashAlgorithm,
		WeightsManifestSHA256:     hb.WeightsManifestSHA256,
		WeightsHashAlgorithm:      hb.WeightsHashAlgorithm,
		ExpectedModelHash:         expectedModelHash,
		Loading:                   hb.Loading,
		LoadingPresent:            presence.Loading,
		LastAutoupdateEvent:       hb.LastAutoupdateEvent,
		HardwareCapacity:          poolHardwareCapacity(hb.HardwareSummary),
		SafetyTelemetry:           hb.SafetyTelemetry,
		At:                        s.now(),
	})
	entry, gap, ok := heartbeatResult.Provider, heartbeatResult.Gap, heartbeatResult.OK
	if !ok {
		s.log.Warn().Str("provider_id", providerID).Msg("heartbeat for unknown provider")
		return
	}
	if heartbeatResult.ModelIDChanged {
		s.observeAdmissionCeilingDrift(*entry, heartbeatResult.PriorModelID)
	}
	s.applyAdmissionCeilingRouteExclusion(entry, "heartbeat")
	s.rememberProviderSnapshotCoalesced(*entry)
	threshold := s.cfg.HeartbeatInterval() + s.cfg.HeartbeatInterval()/2
	if gap > threshold {
		s.log.Warn().Str("provider_id", providerID).Dur("gap", gap).Dur("threshold", threshold).Msg("provider heartbeat stale")
		s.recordConnectionEvent(providerevents.Event{
			ProviderID:    providerID,
			SessionID:     assignedID,
			Kind:          providerevents.KindHeartbeatStale,
			Outcome:       providerevents.OutcomeFailure,
			FailureReason: providerevents.ReasonHeartbeatStale,
			AuthStage:     providerevents.AuthStageLiveness,
			MessageFamily: providerevents.MessageFamilyNone,
			BinaryVersion: entry.BinaryVersion,
			Diagnostic:    "heartbeat_gap",
		})
	}
	if gap > s.wakeGapThreshold() && !s.warmupGatePending(providerID) {
		s.log.Info().Str("provider_id", providerID).Dur("gap", gap).Msg("provider wake detected")
		s.markDegradedForWarmup(providerID, assignedID)
		session, ok := s.sessionFor(providerID, assignedID)
		if !ok {
			return
		}
		if err := session.send([]byte(`{"type":"warm_up"}`)); err != nil {
			s.log.Warn().Err(err).Str("provider_id", providerID).Msg("warm_up write failed")
		}
	} else {
		s.log.Debug().
			Str("provider_id", providerID).
			Str("state", string(entry.State)).
			Int("slots_free", entry.SlotsFree).
			Int("slots_total", entry.SlotsTotal).
			Msg("provider heartbeat")
	}
	if telemetryDrift, telemetryGeneration := s.telemetryDriftEvaluator(); telemetryDrift != nil {
		alerts, verdict := telemetryDrift.EvaluateHeartbeatWithVerdict(context.Background(), *entry)
		s.logTelemetryDriftAlerts(alerts)
		// Issue #765: absence of a verified benchmark is fail-suspect, not
		// fail-open. Dormant unless BOTH telemetry_drift.enabled and
		// telemetry_drift.quarantine_missing_benchmark are set, in which case
		// the verdict is Unknown and routing is untouched.
		s.applyBenchmarkQuarantine(providerID, assignedID, entry.ModelID, verdict, telemetryGeneration)
	}
}

func (s *Server) observeAdmissionCeilingDrift(provider pool.Provider, priorModelID string) {
	if provider.MaxAdmittedMinRAMGB <= 0 {
		s.recordAdmissionCeilingEvent(provider, priorModelID, 0, providerevents.KindMissingAdmissionCap)
		return
	}
	verdict := s.admissionCeilingRouteVerdict(provider)
	if !verdict.excluded {
		return
	}
	s.recordAdmissionCeilingEvent(provider, priorModelID, verdict.claimedMinRAMGB, providerevents.KindModelCeilingDrift)
}

func (s *Server) catalogMinRAMForProviderModel(provider pool.Provider, modelID string) (int, bool) {
	catalog := s.autotuneCatalog
	if catalog == nil {
		return 0, false
	}
	if provider.CatalogAdmissionMode == "previous" {
		previousCatalog := s.autotuneCompatibleCatalogs[provider.CatalogReleaseID]
		if previousCatalog == nil {
			return 0, false
		}
		previousKey, _, ok := previousCatalog.HighestClaimedTier(modelID)
		if !ok {
			return 0, false
		}
		activeKey, activeRow, ok := catalog.HighestClaimedTier(modelID)
		if !ok {
			return 0, false
		}
		previousIdentity, ok := previousCatalog.RowIdentity(previousKey)
		if !ok {
			return 0, false
		}
		activeIdentity, ok := catalog.RowIdentity(activeKey)
		if !ok || !strings.EqualFold(previousIdentity, activeIdentity) {
			return 0, false
		}
		if !previousCatalog.PolicyEquivalent(previousKey, catalog, activeKey) {
			return 0, false
		}
		return activeRow.MinRAMGB, true
	}
	_, row, ok := catalog.HighestClaimedTier(modelID)
	if !ok {
		return 0, false
	}
	return row.MinRAMGB, true
}

func (s *Server) autotuneCatalogForProvider(provider pool.Provider) *autotune.Catalog {
	if provider.CatalogAdmissionMode == "previous" {
		return s.autotuneCompatibleCatalogs[provider.CatalogReleaseID]
	}
	return s.autotuneCatalog
}

type admissionCeilingRouteVerdict struct {
	excluded        bool
	reason          string
	claimedMinRAMGB int
}

func (s *Server) admissionCeilingRouteVerdict(provider pool.Provider) admissionCeilingRouteVerdict {
	if provider.MaxAdmittedMinRAMGB <= 0 {
		return admissionCeilingRouteVerdict{reason: "admission_cap_missing"}
	}
	claimedMinRAMGB, ok := s.catalogMinRAMForProviderModel(provider, provider.ModelID)
	if !ok {
		return admissionCeilingRouteVerdict{excluded: true, reason: "autotune_model_uncatalogued"}
	}
	if claimedMinRAMGB > provider.MaxAdmittedMinRAMGB {
		return admissionCeilingRouteVerdict{excluded: true, reason: "autotune_model_cap_exceeded", claimedMinRAMGB: claimedMinRAMGB}
	}
	return admissionCeilingRouteVerdict{reason: "admission_ceiling_valid", claimedMinRAMGB: claimedMinRAMGB}
}

func (s *Server) applyAdmissionCeilingRouteExclusion(provider *pool.Provider, actor string) {
	if provider == nil {
		return
	}
	if !s.proofOfWeightsConfig().RequireAutotuneHelloGate {
		if s.pool.SetAdmissionCeilingExcluded(provider.ProviderID, provider.AssignedID, false) {
			provider.AdmissionCeilingExcluded = false
		}
		return
	}
	verdict := s.admissionCeilingRouteVerdict(*provider)
	if !s.pool.SetAdmissionCeilingExcluded(provider.ProviderID, provider.AssignedID, verdict.excluded) {
		provider.AdmissionCeilingExcluded = verdict.excluded
		return
	}
	provider.AdmissionCeilingExcluded = verdict.excluded
	logger := s.log.Info()
	message := "provider admission ceiling route exclusion cleared"
	if verdict.excluded {
		logger = s.log.Warn()
		message = "provider route-excluded by admission ceiling"
	}
	logger.
		Str("event", EventProviderAdmissionCeilingExclusion).
		Str("provider_id", provider.ProviderID).
		Str("assigned_id", provider.AssignedID).
		Str("actor", actor).
		Str("model_id", provider.ModelID).
		Str("reason", verdict.reason).
		Bool("excluded", verdict.excluded).
		Int("claimed_min_ram_gb", verdict.claimedMinRAMGB).
		Int("max_admitted_min_ram_gb", provider.MaxAdmittedMinRAMGB).
		Msg(message)
}

func (s *Server) recordAdmissionCeilingEvent(provider pool.Provider, priorModelID string, claimedMinRAMGB int, kind string) {
	suppressed, ok := s.reserveAdmissionCeilingEvent(provider.ProviderID, kind)
	if !ok {
		return
	}
	logger := s.log.Warn().
		Str("event", kind).
		Str("provider_id", provider.ProviderID).
		Str("assigned_id", provider.AssignedID).
		Str("from_model_id", priorModelID).
		Str("to_model_id", provider.ModelID).
		Int("claimed_min_ram_gb", claimedMinRAMGB).
		Int("max_admitted_min_ram_gb", provider.MaxAdmittedMinRAMGB)
	if provider.MaxAdmittedModelID != "" {
		logger = logger.Str("max_admitted_model_id", provider.MaxAdmittedModelID)
	}
	if suppressed > 0 {
		logger = logger.Uint64("suppressed_events", suppressed)
	}
	if kind == providerevents.KindMissingAdmissionCap {
		logger.Msg("provider heartbeat changed model without an observed admission cap")
	} else if claimedMinRAMGB == 0 {
		logger.Msg("provider heartbeat model is uncatalogued under observed admission cap")
	} else {
		logger.Msg("provider heartbeat model exceeds observed admission cap")
	}
	s.recordConnectionEvent(providerevents.Event{
		ProviderID:    provider.ProviderID,
		SessionID:     provider.AssignedID,
		Kind:          kind,
		Outcome:       providerevents.OutcomeFailure,
		FailureReason: providerevents.ReasonOther,
		AuthStage:     providerevents.AuthStageLiveness,
		MessageFamily: providerevents.MessageFamilyNone,
		BinaryVersion: provider.BinaryVersion,
		Diagnostic:    admissionCeilingDiagnostic(priorModelID, provider.ModelID, claimedMinRAMGB, provider.MaxAdmittedMinRAMGB, suppressed),
	})
}

func (s *Server) reserveAdmissionCeilingEvent(providerID, kind string) (uint64, bool) {
	now := s.now().UTC()
	key := providerID + "\x00" + kind
	s.admissionCeilingEventMu.Lock()
	defer s.admissionCeilingEventMu.Unlock()
	if s.admissionCeilingEvents == nil {
		s.admissionCeilingEvents = make(map[string]admissionCeilingEventRateState)
	}
	if len(s.admissionCeilingEvents) >= admissionCeilingEventStateMaxKeys {
		s.pruneAdmissionCeilingEventsLocked(now)
	}
	state := s.admissionCeilingEvents[key]
	if now.Before(state.last) {
		state = admissionCeilingEventRateState{}
	}
	if !state.last.IsZero() && now.Sub(state.last) < admissionCeilingEventCooldown {
		state.suppressed++
		s.admissionCeilingEvents[key] = state
		return 0, false
	}
	suppressed := state.suppressed
	s.admissionCeilingEvents[key] = admissionCeilingEventRateState{last: now}
	return suppressed, true
}

func (s *Server) pruneAdmissionCeilingEventsLocked(now time.Time) {
	for key, state := range s.admissionCeilingEvents {
		if state.last.IsZero() || now.Before(state.last) || now.Sub(state.last) > admissionCeilingEventStateTTL {
			delete(s.admissionCeilingEvents, key)
		}
	}
	for len(s.admissionCeilingEvents) >= admissionCeilingEventStateMaxKeys {
		var oldestKey string
		var oldest time.Time
		for key, state := range s.admissionCeilingEvents {
			if oldestKey == "" || state.last.Before(oldest) {
				oldestKey = key
				oldest = state.last
			}
		}
		if oldestKey == "" {
			return
		}
		delete(s.admissionCeilingEvents, oldestKey)
	}
}

func admissionCeilingDiagnostic(fromModelID, toModelID string, claimedMinRAMGB, maxAdmittedMinRAMGB int, suppressed uint64) string {
	diagnostic := "from_model_id=" + compactDiagnosticValue(fromModelID, admissionCeilingDiagnosticValueRune) +
		" to_model_id=" + compactDiagnosticValue(toModelID, admissionCeilingDiagnosticValueRune) +
		" claimed_min_ram_gb=" + strconv.Itoa(claimedMinRAMGB) +
		" max_admitted_min_ram_gb=" + strconv.Itoa(maxAdmittedMinRAMGB)
	if suppressed > 0 {
		diagnostic += " suppressed_events=" + strconv.FormatUint(suppressed, 10)
	}
	return diagnostic
}

func compactDiagnosticValue(value string, maxRunes int) string {
	value = strings.TrimSpace(value)
	if maxRunes <= 0 || len([]rune(value)) <= maxRunes {
		return value
	}
	runes := []rune(value)
	return string(runes[:maxRunes])
}

func (s *Server) fenceInvalidModelIdentity(conn net.Conn, providerID, assignedID string) {
	s.pool.MarkHashStatusIfSession(providerID, assignedID, pool.HashStatusInvalid)
	if session, ok := s.storedSessionFor(providerID, assignedID); ok {
		s.closeSession(session, CloseInvalidHello, "invalid_model_hash_identity")
		return
	}
	_ = conn.Close()
}

func (s *Server) logTelemetryDriftAlerts(alerts []pow.Alert) {
	for _, alert := range alerts {
		event := s.log.Warn().
			Str("event", pow.EventTelemetryDriftDetected).
			Str("signal", alert.Signal).
			Str("provider_id", alert.ProviderID).
			Str("assigned_id", alert.AssignedID).
			Str("model_id", alert.ModelID)
		if alert.LiveTPS > 0 || alert.BaselineTPS > 0 {
			event = event.
				Float64("live_tps", alert.LiveTPS).
				Float64("baseline_tps", alert.BaselineTPS).
				Float64("tps_threshold", alert.TPSThreshold)
		}
		if alert.HashStatus != "" {
			event = event.Str("hash_status", string(alert.HashStatus))
		}
		if alert.LiveModelHash != "" {
			event = event.Str("live_model_hash_prefix", prefixHex(alert.LiveModelHash, 8))
		}
		if alert.ExpectedArtifactHash != "" {
			event = event.Str("expected_artifact_hash_prefix", prefixHex(alert.ExpectedArtifactHash, 8))
		}
		if alert.OPoIPassRateWindow > 0 {
			event = event.
				Float64("opoi_pass_rate", alert.OPoIPassRate).
				Int("opoi_pass_rate_window", alert.OPoIPassRateWindow).
				Int("opoi_pass_count", alert.OPoIPassCount)
		}
		if alert.SwapDetected {
			event = event.Bool("swap_detected", true)
		}
		event.Msg("proof-of-weights telemetry drift detected")
	}
}

func prefixHex(value string, n int) string {
	value = strings.TrimSpace(value)
	if n <= 0 || len(value) <= n {
		return value
	}
	return value[:n]
}

func poolHardwareCapacity(summary *HardwareSummary) *pool.ProviderHardwareCapacity {
	if summary == nil {
		return nil
	}
	return &pool.ProviderHardwareCapacity{
		Chip:              summary.Chip,
		BandwidthGBPerSec: summary.BandwidthGBPerSec,
		NetworkPowerKW:    summary.NetworkPowerKW,
		GPUCoresTotal:     summary.GPUCoresTotal,
		CPUCoresTotal:     summary.CPUCoresTotal,
	}
}

// clampStateUpdateSlots applies the capacity ceiling to a state_update's
// optional slot pair. state_update carries no max_concurrency, so the
// reference total is the provider's LIVE (already ingest-clamped) cap — not
// the global ceiling: a provider admitted at MaxConcurrency=2 must not hold
// slots_total=8 via state_update until the next heartbeat repairs it (#764
// audit R1, security lane; HTTP-forwarding providers have no relay-side
// active limiter, so inflated slots there are real over-admission). The
// ceiling is the fallback reference when the provider is unknown. Absent
// (nil) fields stay absent — the clamp never materializes a value the
// provider did not send.
func (s *Server) clampStateUpdateSlots(providerID string, slotsTotal, slotsFree *int) (*int, *int) {
	ceiling := s.maxConcurrencyCeiling()
	if ceiling <= 0 || (slotsTotal == nil && slotsFree == nil) {
		return slotsTotal, slotsFree
	}
	reference := ceiling
	if live, ok := s.pool.CurrentMaxConcurrency(providerID); ok && live > 0 && live < reference {
		reference = live
	}
	total, free := reference, reference
	if slotsTotal != nil {
		total = *slotsTotal
	}
	if slotsFree != nil {
		free = *slotsFree
	}
	clamped := pool.ClampCapacity(reference, total, free, reference)
	if clamped.SlotsTotal == total && clamped.SlotsFree == free {
		return slotsTotal, slotsFree
	}
	s.recordCapacityOverClaim(capacityPhaseStateUpdate)
	s.log.Warn().
		Str("event", EventProviderCapacityOverClaim).
		Str("provider_id", providerID).
		Str("phase", capacityPhaseStateUpdate).
		Int("reported_slots_total", total).
		Int("reported_slots_free", free).
		Int("ceiling", ceiling).
		Int("effective_slots_total", clamped.SlotsTotal).
		Int("effective_slots_free", clamped.SlotsFree).
		Msg("provider capacity claim exceeds the operator ceiling; clamped")
	outTotal, outFree := slotsTotal, slotsFree
	if slotsTotal != nil {
		v := clamped.SlotsTotal
		outTotal = &v
	}
	if slotsFree != nil {
		v := clamped.SlotsFree
		outFree = &v
	}
	return outTotal, outFree
}

func (s *Server) handleStateUpdate(providerID, assignedID string, payload []byte) {
	update, field, err := ParseStateUpdate(payload)
	if err != nil {
		s.log.Warn().Err(err).Str("field", field).Str("provider_id", providerID).Msg("invalid state_update")
		return
	}
	state := pool.State(update.State)
	if !validState(state) {
		s.log.Warn().Str("state", update.State).Str("provider_id", providerID).Msg("invalid provider state")
		return
	}
	if state == pool.StateReady && s.warmupGatePending(providerID) {
		state = pool.StateDegraded
	}
	// Issue #764: state_update is the THIRD provider-controlled capacity ingest
	// (after hello and heartbeat) — it writes SlotsFree/SlotsTotal straight onto
	// the pool entry. Leaving it unclamped would let a provider restore an
	// inflated free-slot count immediately after a clamped heartbeat, so the
	// ceiling applies here too.
	slotsTotal, slotsFree := s.clampStateUpdateSlots(providerID, update.MetricsSnapshot.SlotsTotal, update.MetricsSnapshot.SlotsFree)
	entry, ok := s.pool.ApplyStateUpdate(providerID, assignedID, pool.StateUpdate{
		State:               state,
		SlotsFree:           slotsFree,
		SlotsTotal:          slotsTotal,
		LastAutoupdateEvent: update.LastAutoupdateEvent,
		At:                  s.now(),
	})
	if !ok {
		s.log.Warn().Str("provider_id", providerID).Msg("state_update for unknown provider")
		return
	}
	if state == pool.StateReady {
		if timer, ok := s.timers.LoadAndDelete(providerID); ok {
			timer.(*time.Timer).Stop()
		}
	}
	s.log.Info().
		Str("provider_id", providerID).
		Str("state", string(entry.State)).
		Str("reason", update.Reason).
		Str("since", update.Since).
		Msg("provider state transition")
}

func (s *Server) markDegradedForWarmup(providerID, assignedID string) {
	s.pool.MarkState(providerID, assignedID, pool.StateDegraded)
	if timer, ok := s.timers.LoadAndDelete(providerID); ok {
		timer.(*time.Timer).Stop()
	}
	timer := time.AfterFunc(s.warmupFallback(), func() {
		if s.warmupGatePending(providerID) {
			s.timers.Delete(providerID)
			return
		}
		if s.pool.MarkState(providerID, assignedID, pool.StateReady) {
			s.log.Warn().Str("provider_id", providerID).Dur("timeout", s.warmupFallback()).Msg("warm_up timed out; allowing routing")
		}
		s.timers.Delete(providerID)
	})
	s.timers.Store(providerID, timer)
}

func (s *Server) handleDisconnect(providerID, assignedID string) {
	s.clearWarmupGate(providerID, assignedID)
	s.pruneIdlePrewarmLimits(s.now())
	binaryVersion := ""
	var conn net.Conn
	if session, ok := s.storedSessionFor(providerID, assignedID); ok {
		conn = session.conn
	}
	if provider, ok := s.pool.Resolve(providerID, assignedID); ok {
		provider.State = pool.StateUnavailable
		binaryVersion = provider.BinaryVersion
		s.rememberProviderSnapshot(provider)
	}
	if conn != nil {
		_ = s.takeCloseEvent(conn)
	}
	s.recordConnectionEvent(providerevents.Event{
		ProviderID:    providerID,
		SessionID:     assignedID,
		Kind:          providerevents.KindDisconnect,
		Outcome:       providerevents.OutcomeFailure,
		FailureReason: providerevents.ReasonProviderWebsocketDisconnected,
		AuthStage:     providerevents.AuthStagePostAuth,
		MessageFamily: providerevents.MessageFamilyNone,
		BinaryVersion: binaryVersion,
	})
	if session, ok := s.storedSessionFor(providerID, assignedID); ok {
		session.close()
		s.sessions.Delete(sessionKey(providerID, assignedID))
	}
	if s.pool.RemoveIfSessionState(providerID, assignedID, pool.StateDraining) {
		s.log.Info().Str("provider_id", providerID).Msg("draining provider removed after websocket close")
		return
	}
	if !s.pool.MarkState(providerID, assignedID, pool.StateUnavailable) {
		return
	}
	grace := s.disconnectGracePeriod()
	s.log.Warn().Str("provider_id", providerID).Dur("grace", grace).Msg("provider websocket disconnected")
	time.AfterFunc(grace, func() {
		if s.pool.RemoveIfSession(providerID, assignedID) {
			s.log.Warn().Str("provider_id", providerID).Msg("provider removed after disconnect grace period")
		}
	})
}

func (s *Server) handleProviderWriteFailure(session *providerSession, err error) {
	if session == nil {
		return
	}
	session.rekeyMu.Lock()
	exchange := session.rekey
	session.rekeyMu.Unlock()
	if exchange != nil && s.failTier2Rekey(session, session.providerID, session.assignedID, exchange, "write_failed", ErrRelayClosed) {
		return
	}
	s.clearWarmupGate(session.providerID, session.assignedID)
	_ = session.conn.Close()
	session.close()
	s.sessions.Delete(sessionKey(session.providerID, session.assignedID))
	if s.pool.MarkState(session.providerID, session.assignedID, pool.StateUnavailable) {
		s.log.Warn().
			Err(err).
			Str("provider_id", session.providerID).
			Str("assigned_id", session.assignedID).
			Msg("provider websocket write failed; marked unavailable")
	}
}

func (s *Server) monitorHeartbeat(providerID, assignedID string, conn net.Conn) {
	tick := s.cfg.FailoverTimeout() / 2
	if tick <= 0 {
		tick = time.Second
	}
	if tick > time.Second {
		tick = time.Second
	}
	ticker := time.NewTicker(tick)
	defer ticker.Stop()
	for range ticker.C {
		provider, ok := s.pool.Resolve(providerID, assignedID)
		if !ok {
			return
		}
		// Liveness is measured from the last inbound frame of ANY type, not
		// just heartbeats: a provider streaming a long inference response is
		// demonstrably alive even though it cannot emit heartbeats while its
		// single slot is busy. Fall back to LastHeartbeatAt for safety if a
		// provider predates activity tracking.
		last := provider.LastActivityAt
		if last.IsZero() {
			last = provider.LastHeartbeatAt
		}
		threshold := s.providerLivenessThreshold(provider)
		if s.now().Sub(last) <= threshold {
			continue
		}
		if s.providerHasActiveRelay(providerID, assignedID) {
			continue
		}
		s.log.Warn().
			Str("provider_id", providerID).
			Dur("gap", s.now().Sub(last)).
			Dur("threshold", threshold).
			Msg("provider inactive past threshold; closing websocket")
		s.recordConnectionEvent(providerevents.Event{
			ProviderID:    providerID,
			SessionID:     assignedID,
			Kind:          providerevents.KindHeartbeatStale,
			Outcome:       providerevents.OutcomeFailure,
			FailureReason: providerevents.ReasonHeartbeatStale,
			AuthStage:     providerevents.AuthStageLiveness,
			MessageFamily: providerevents.MessageFamilyNone,
			BinaryVersion: provider.BinaryVersion,
			Diagnostic:    "liveness_threshold_exceeded",
		})
		_ = conn.Close()
		return
	}
}

func (s *Server) providerReadTimeout(providerID, assignedID string) time.Duration {
	provider, ok := s.pool.Resolve(providerID, assignedID)
	if !ok {
		return s.cfg.HeartbeatMissThreshold()
	}
	if s.providerHasActiveRelay(providerID, assignedID) {
		return s.activeRelayReadTimeout(provider)
	}
	return s.providerLivenessThreshold(provider)
}

func (s *Server) extendProviderReadDeadlineForActive(provider pool.Provider) {
	session, ok := s.storedSessionFor(provider.ProviderID, provider.AssignedID)
	if !ok || !session.hasActive() {
		return
	}
	s.setReadDeadline(session.conn, s.activeRelayReadTimeout(provider))
}

func (s *Server) providerHasActiveRelay(providerID, assignedID string) bool {
	session, ok := s.storedSessionFor(providerID, assignedID)
	return ok && session.hasActive()
}

func (s *Server) activeRelayReadTimeout(provider pool.Provider) time.Duration {
	threshold := s.providerLivenessThreshold(provider)
	requestTimeout := time.Duration(s.cfg.Routing.RequestTimeoutS) * time.Second
	if requestTimeout > threshold {
		return requestTimeout
	}
	return threshold
}

func (s *Server) providerLivenessThreshold(provider pool.Provider) time.Duration {
	threshold := s.cfg.HeartbeatMissThreshold()
	if providerSupportsInternalActivityLiveness(provider.BinaryVersion) {
		if internalActivityThreshold := 60 * time.Second; threshold > internalActivityThreshold {
			threshold = internalActivityThreshold
		}
	}
	return threshold
}

func providerSupportsInternalActivityLiveness(binaryVersion string) bool {
	cmp, ok := compareSemver(binaryVersion, "1.8.1")
	return ok && cmp >= 0
}

func validState(state pool.State) bool {
	switch state {
	case pool.StateReady, pool.StateBusy, pool.StateDegraded, pool.StateDraining, pool.StateUnavailable:
		return true
	default:
		return false
	}
}

func (s *Server) wakeGapThreshold() time.Duration {
	if ms := s.cfg.Pool.WakeGapThresholdMs; ms > 0 {
		return time.Duration(ms) * time.Millisecond
	}
	seconds := s.cfg.Pool.WakeGapThresholdS
	if seconds <= 0 {
		seconds = config.Default().Pool.WakeGapThresholdS
	}
	return time.Duration(seconds) * time.Second
}

func (s *Server) warmupFallback() time.Duration {
	seconds := s.cfg.Pool.WarmupFallbackS
	if seconds <= 0 {
		seconds = config.Default().Pool.WarmupFallbackS
	}
	return time.Duration(seconds) * time.Second
}

func (s *Server) disconnectGracePeriod() time.Duration {
	seconds := s.cfg.Pool.DisconnectGracePeriodS
	if seconds <= 0 {
		seconds = config.Default().Pool.DisconnectGracePeriodS
	}
	return time.Duration(seconds) * time.Second
}

func (s *Server) warmupGateTimeout() time.Duration {
	seconds := s.cfg.Pool.WarmupGateTimeoutS
	if seconds <= 0 {
		seconds = config.Default().Pool.WarmupGateTimeoutS
	}
	return time.Duration(seconds) * time.Second
}

func (s *Server) warmupGateMaxTokens() int {
	tokens := s.cfg.Pool.WarmupGateMaxTokens
	if tokens <= 0 {
		tokens = config.Default().Pool.WarmupGateMaxTokens
	}
	return tokens
}

func (s *Server) degradedBackoff() time.Duration {
	seconds := s.cfg.Pool.DegradedBackoffS
	if seconds <= 0 {
		seconds = config.Default().Pool.DegradedBackoffS
	}
	return time.Duration(seconds) * time.Second
}

func (s *Server) canaryInterval() time.Duration {
	seconds := s.cfg.Pool.CanaryIntervalS
	if seconds <= 0 {
		seconds = config.Default().Pool.CanaryIntervalS
	}
	return time.Duration(seconds) * time.Second
}

func (s *Server) canarySweepCadence() time.Duration {
	cadence := s.canaryInterval() / 10
	if cadence < time.Second {
		return time.Second
	}
	if cadence > 30*time.Second {
		return 30 * time.Second
	}
	return cadence
}

func (s *Server) canaryTimeout() time.Duration {
	seconds := s.cfg.Pool.CanaryTimeoutS
	if seconds <= 0 {
		seconds = config.Default().Pool.CanaryTimeoutS
	}
	return time.Duration(seconds) * time.Second
}

func (s *Server) canaryMaxTokens() int {
	tokens := s.cfg.Pool.CanaryMaxTokens
	if tokens <= 0 {
		tokens = config.Default().Pool.CanaryMaxTokens
	}
	return tokens
}

func (s *Server) canaryFailureThreshold() int {
	threshold := s.cfg.Pool.CanaryFailureThreshold
	if threshold <= 0 {
		threshold = config.Default().Pool.CanaryFailureThreshold
	}
	return threshold
}

func (s *Server) handleHealthz(w http.ResponseWriter, r *http.Request) {
	// HEAD returns the same status/headers as GET with no body (Go's server
	// discards the body for HEAD), so probes using curl -I / k8s / UptimeRobot
	// are not rejected with 405.
	if r.Method != http.MethodGet && r.Method != http.MethodHead {
		w.Header().Set("Allow", http.MethodGet+", "+http.MethodHead)
		http.Error(w, "method not allowed", http.StatusMethodNotAllowed)
		return
	}
	providers := s.pool.Snapshot()
	resp := struct {
		Status                   string `json:"status"`
		UptimeS                  int64  `json:"uptime_s"`
		PoolSize                 int    `json:"pool_size"`
		PoolReady                int    `json:"pool_ready"`
		PoolDegraded             int    `json:"pool_degraded"`
		PoolDraining             int    `json:"pool_draining"`
		PoolUnavailable          int    `json:"pool_unavailable"`
		PoolPolicyReady          int    `json:"pool_policy_ready"`
		RequestsTotal            int    `json:"requests_total"`
		RequestsActive           int    `json:"requests_active"`
		Version                  string `json:"version"`
		RecommendedBinaryVersion string `json:"recommended_binary_version"`
		// RequiredBinaryVersion mirrors the hard admission floor so
		// `macprovider-cli doctor` can tell an operator WHY a build is being
		// closed with 4004 without inventing a new coordinator endpoint
		// (#767). Empty when no floor is configured. Like the recommendation
		// above it is NOT capability-gated: /healthz is an operator/monitoring
		// mirror, and no legacy CLI code path reads it to drive an autoupdate
		// — a floor is a rejection reason, never an update target.
		RequiredBinaryVersion string `json:"required_binary_version,omitempty"`
		// TrustAuthorityDegraded is true when the hardware-trust revalidation
		// sweep has failed to read the trust store for trustSweepDegradedThreshold
		// consecutive ticks (issue #582 FIX C). It signals operators that active
		// gated sessions are being quarantined because trust can no longer be
		// verified — the bound on the sweep's fail-open. Always false when the
		// hardware-trust hello gate (and thus the sweep) is not enabled.
		TrustAuthorityDegraded bool `json:"trust_authority_degraded"`
	}{
		Status:   "ok",
		UptimeS:  int64(s.now().Sub(s.started).Seconds()),
		PoolSize: len(providers),
		Version:  s.version,
		// S-H1: NOT capability-gated. /healthz is a public operator/monitoring
		// mirror, not a per-connection provider surface. No legacy CLI code
		// path (verified against v1.8.30 sources: no `/healthz` reference in
		// SelfUpdate/CoordinatorClient/AutoUpdater/HTTPServer) fetches this
		// endpoint to drive an autoupdate — the autoupdater is fed exclusively
		// by the WebSocket hello_ack / auth_response `recommended_binary_version`
		// field, which IS gated above. Gating this monitoring value would blind
		// operators with no security benefit.
		RecommendedBinaryVersion: s.cfg.CoordinatorAdvertisedVersion.LatestBinaryVersion,
		RequiredBinaryVersion:    strings.TrimSpace(s.cfg.CoordinatorAdvertisedVersion.RequiredBinaryVersion),
		TrustAuthorityDegraded:   s.trustAuthorityDegraded.Load(),
	}
	for _, p := range providers {
		switch p.State {
		case pool.StateReady:
			if providerPublishedReady(p) {
				resp.PoolReady++
			}
			if s.providerTier2PolicyEligible(p, s.tier2Config()) {
				resp.PoolPolicyReady++
			}
		case pool.StateDegraded:
			resp.PoolDegraded++
		case pool.StateDraining:
			resp.PoolDraining++
		case pool.StateUnavailable:
			resp.PoolUnavailable++
		}
	}
	w.Header().Set("Content-Type", "application/json")
	_ = json.NewEncoder(w).Encode(resp)
}

func (s *Server) handlePoolz(w http.ResponseWriter, r *http.Request) {
	if r.Method != http.MethodGet {
		w.Header().Set("Allow", http.MethodGet)
		http.Error(w, "method not allowed", http.StatusMethodNotAllowed)
		return
	}
	if !s.authorizedOperator(r) {
		w.Header().Set("Content-Type", "application/json")
		w.WriteHeader(http.StatusUnauthorized)
		_, _ = w.Write([]byte(`{"error":{"message":"unauthorized","code":"invalid_operator_token"}}`))
		return
	}

	providers := s.pool.Snapshot()
	if !tier2.ModelHashActive(s.tier2Config()) {
		for i := range providers {
			providers[i].ModelHash = ""
			providers[i].HashStatus = ""
		}
	} else {
		for i := range providers {
			providers[i].HashStatus = s.verifyProviderModelIdentity(providers[i].ModelID, providers[i].ExpectedModelHash, providers[i].ModelHash, providers[i].ModelHashAlgorithm)
		}
	}
	modelSet := map[string]struct{}{}
	summary := struct {
		TotalProviders int      `json:"total_providers"`
		Ready          int      `json:"ready"`
		PolicyReady    int      `json:"policy_ready"`
		TotalSlots     int      `json:"total_slots"`
		FreeSlots      int      `json:"free_slots"`
		Models         []string `json:"models"`
		// Issue #764 — additive per-binary_version TTFT/TPS + capacity
		// breakdown. New key only; the six fields above keep their shapes.
		ByBinaryVersion map[string]poolzVersionSegment `json:"by_binary_version"`
	}{TotalProviders: len(providers), ByBinaryVersion: poolzVersionSegments(providers)}
	cfg := s.tier2Config()
	for _, p := range providers {
		// SPEC-015 §7 / TestProviderAuthV2ReceiptRotationCandidateWithout
		// StateUpdateDoesNotPublish: FreeSlots aggregates buyer-usable
		// capacity only, gated by providerPublishedReady, so a pending
		// rotation does NOT contribute. TotalSlots stays top-level because
		// it represents absolute fleet capacity for capacity planning.
		// The two summary fields have intentionally different semantics.
		if providerPublishedReady(p) {
			summary.Ready++
			summary.FreeSlots += p.SlotsFree
		}
		if s.providerTier2PolicyEligible(p, cfg) {
			summary.PolicyReady++
		}
		summary.TotalSlots += p.SlotsTotal
		if _, ok := modelSet[p.ModelID]; !ok {
			modelSet[p.ModelID] = struct{}{}
			summary.Models = append(summary.Models, p.ModelID)
		}
	}

	w.Header().Set("Content-Type", "application/json")
	type poolzReceiptPubkeyPrev struct {
		Pubkey    string `json:"pubkey"`
		RotatedAt int64  `json:"rotated_at"`
		ExpiresAt int64  `json:"expires_at"`
	}
	type poolzProvider struct {
		pool.Provider
		RoutingEligible   bool                    `json:"routing_eligible"`
		CanaryFailCount   int                     `json:"canary_fail_count"`
		ReceiptPubkey     *string                 `json:"receipt_pubkey"`
		ReceiptPubkeyPrev *poolzReceiptPubkeyPrev `json:"receipt_pubkey_prev"`
	}
	now := s.now()
	poolz := make([]poolzProvider, 0, len(providers))
	for _, provider := range providers {
		var receiptPubkey *string
		if len(provider.ReceiptPubkey) > 0 {
			encoded := base64.StdEncoding.EncodeToString(provider.ReceiptPubkey)
			receiptPubkey = &encoded
		}
		var receiptPubkeyPrev *poolzReceiptPubkeyPrev
		if provider.ReceiptPubkeyPrev != nil && now.Before(provider.ReceiptPubkeyPrev.ExpiresAt) {
			receiptPubkeyPrev = &poolzReceiptPubkeyPrev{
				Pubkey:    base64.StdEncoding.EncodeToString(provider.ReceiptPubkeyPrev.Pubkey),
				RotatedAt: provider.ReceiptPubkeyPrev.RotatedAt.Unix(),
				ExpiresAt: provider.ReceiptPubkeyPrev.ExpiresAt.Unix(),
			}
		}
		poolz = append(poolz, poolzProvider{
			Provider:          provider,
			RoutingEligible:   provider.RoutingEligible(),
			CanaryFailCount:   provider.CanaryFailCount,
			ReceiptPubkey:     receiptPubkey,
			ReceiptPubkeyPrev: receiptPubkeyPrev,
		})
	}
	// SPEC-015 §M.4 — SPEC-002 v1.6 candidate annotation. The three
	// `catalog_*` fields are present iff the catalog is effectively
	// active: (a) Tier2Config.CatalogPath is configured, (b) the
	// catalog parsed cleanly, (c) its signature verified. The
	// `s.catalogRef().Active()` predicate captures all three.
	type poolzResponse struct {
		Pool             []poolzProvider `json:"pool"`
		Summary          any             `json:"summary"`
		CatalogID        *string         `json:"catalog_id,omitempty"`
		CatalogURL       *string         `json:"catalog_url,omitempty"`
		CatalogPubkeyURL *string         `json:"catalog_pubkey_url,omitempty"`
	}
	resp := poolzResponse{Pool: poolz, Summary: summary}
	if s.catalogRef().Active() {
		catalogID := s.catalogRef().CatalogID()
		if catalogID != "" {
			resp.CatalogID = &catalogID
			base := strings.TrimSpace(cfg.PublicCatalogBaseURL)
			if base == "" {
				// Fallback: derive from the inbound request host so a
				// verifier reading `/poolz` from the same coordinator
				// can resolve the URLs even when the operator hasn't
				// pinned a public base.
				if r.Host != "" {
					scheme := "https"
					if r.TLS == nil {
						scheme = "http"
					}
					base = scheme + "://" + r.Host
				}
			} else {
				base = strings.TrimRight(base, "/")
			}
			if base != "" {
				catalogURL := base + "/catalog/" + catalogID
				pubkeyURL := base + "/catalog/pubkey"
				resp.CatalogURL = &catalogURL
				resp.CatalogPubkeyURL = &pubkeyURL
			}
		}
	}
	_ = json.NewEncoder(w).Encode(resp)
}

func providerPublishedReady(p pool.Provider) bool {
	return p.State == pool.StateReady && p.CapacityEligible()
}

func (s *Server) providerTier2PolicyEligible(p pool.Provider, cfg config.Tier2Config) bool {
	if !providerPublishedReady(p) {
		return false
	}
	if !tier2.ConfigActive(cfg) {
		return true
	}
	if tier2.ModelHashActive(cfg) && tier2.IsHashPredicateFailure(s.verifyProviderModelIdentity(p.ModelID, p.ExpectedModelHash, p.ModelHash, p.ModelHashAlgorithm), cfg.RequireHashVerified) {
		return false
	}
	if cfg.RequireEncryptedLeg && !p.EncryptedLeg {
		return false
	}
	if cfg.RequireAttestation && p.AttestationStatus != pool.AttestationStatusAttested {
		return false
	}
	return true
}

func (s *Server) handleBlacklist(w http.ResponseWriter, r *http.Request) {
	if r.Method != http.MethodPost {
		w.Header().Set("Allow", http.MethodPost)
		http.Error(w, "method not allowed", http.StatusMethodNotAllowed)
		return
	}
	if !s.authorizedOperator(r) {
		writeJSON(w, http.StatusUnauthorized, map[string]any{"error": map[string]any{"message": "unauthorized", "code": "invalid_operator_token"}})
		return
	}
	var req struct {
		ProviderID string `json:"provider_id"`
		AssignedID string `json:"assigned_id"`
		Reason     string `json:"reason"`
	}
	if err := json.NewDecoder(r.Body).Decode(&req); err != nil {
		writeJSON(w, http.StatusBadRequest, map[string]any{"error": map[string]any{"message": "invalid json", "code": "invalid_request"}})
		return
	}
	provider, ok := s.pool.Resolve(req.ProviderID, req.AssignedID)
	if !ok {
		id := req.ProviderID
		if id == "" {
			id = req.AssignedID
		}
		writeJSON(w, http.StatusNotFound, map[string]any{"error": map[string]any{"message": "provider " + id + " not in pool", "code": "provider_not_found"}})
		return
	}
	session, ok := s.sessionFor(provider.ProviderID, provider.AssignedID)
	if !ok {
		writeJSON(w, http.StatusNotFound, map[string]any{"error": map[string]any{"message": "provider " + provider.ProviderID + " not in pool", "code": "provider_not_found"}})
		return
	}
	drainSent := true
	if err := session.send([]byte(`{"type":"drain"}`)); err != nil {
		drainSent = false
		s.log.Warn().Err(err).Str("provider_id", provider.ProviderID).Msg("drain write failed during blacklist")
	}
	s.pool.MarkState(provider.ProviderID, provider.AssignedID, pool.StateDraining)
	time.AfterFunc(time.Minute, func() {
		_ = session.conn.Close()
	})
	s.log.Warn().Str("provider_id", provider.ProviderID).Str("assigned_id", provider.AssignedID).Str("reason", req.Reason).Msg("provider blacklisted")
	writeJSON(w, http.StatusOK, map[string]any{
		"status":      "draining",
		"provider_id": provider.ProviderID,
		"assigned_id": provider.AssignedID,
		"drain_sent":  drainSent,
	})
}

// authorizedOperator returns true when the request's Bearer token
// matches the configured operator key. This guards HUMAN-ADMIN
// endpoints (`/poolz`, `/admin/blacklist`, `/admin/promote`,
// `/admin/reject`, `/admin/provisional`) and intentionally does NOT
// accept gateway_service_token: the codex security audit on PR #73
// (HIGH-1) flagged that admin endpoints accepting the service-token
// silently grant human-admin power to the gateway once the operator
// rotates the legacy operator_key. Operator-class endpoints are
// reachable only from a human operator's machine, so the legacy single
// credential is sufficient and the dual-credential bridge stays scoped
// to the `/internal/*` paths the gateway actually calls.
//
// Empty operator_key still means DENY (M1-5 / SECU-5 preserved). The
// service-to-service `/internal/*` paths under buyer.Server use the
// auth.GatewayInternalBearerMatches helper instead, which accepts the
// gateway_service_token ONLY after PR #87 item 3. Operator-only endpoints
// here keep the operator_key.
func (s *Server) authorizedOperator(r *http.Request) bool {
	if !auth.OperatorOnlyBearerMatches(r.Header, s.cfg.Auth.OperatorKey) {
		return false
	}
	s.log.Info().
		Str("event", "internal_bearer_accepted").
		Str("key", "operator_key").
		Str("path", r.URL.Path).
		Str("remote_addr", r.RemoteAddr).
		Msg("internal bearer accepted")
	return true
}

func writeJSON(w http.ResponseWriter, status int, body any) {
	w.Header().Set("Content-Type", "application/json")
	w.WriteHeader(status)
	_ = json.NewEncoder(w).Encode(body)
}

func itoa(n int) string {
	if n == 0 {
		return "0"
	}
	var b [20]byte
	i := len(b)
	neg := n < 0
	if neg {
		n = -n
	}
	for n > 0 {
		i--
		b[i] = byte('0' + n%10)
		n /= 10
	}
	if neg {
		i--
		b[i] = '-'
	}
	return string(b[i:])
}
