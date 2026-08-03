package config

import (
	"crypto/ed25519"
	"encoding/base64"
	"encoding/json"
	"fmt"
	"math"
	"net/netip"
	"net/url"
	"os"
	"regexp"
	"sort"
	"strings"
	"time"

	"github.com/augstar/macprovider-coordinator/internal/stats/hardwareverify"
	"github.com/augstar/macprovider-coordinator/internal/versionfloor"
	"gopkg.in/yaml.v3"
)

var providerIDPattern = regexp.MustCompile(`^[a-zA-Z0-9_.-]{1,64}$`)

const (
	maxCompatibilitySetIDBytes   = 256
	maxAcceptedCompatibilitySets = 8
	// maxFirstHopBridgeSets bounds the temporary pre-fix update bridge
	// (#610). It is intentionally smaller than accepted_ids so production
	// cannot silently widen buyer-serving admission via the bridge list.
	maxFirstHopBridgeSets = 4
)

var compatibilitySetIDPattern = regexp.MustCompile(`^[A-Za-z0-9_.-]{1,64}/[A-Za-z0-9_.-]{1,100}:v[0-9]+\.[0-9]+\.[0-9]+@[0-9a-f]{40}$`)

// ValidateProviderID is the canonical validator for ProviderID across every
// registration path. Issue #274: WS self-serve registration previously
// accepted any non-empty / non-control-char string, while configured pinned
// providers were already gated on providerIDPattern. The "/" delimiter used
// by pool.Provider.SortKey (ProviderID + "/" + AssignedID) is only
// unambiguous when no ProviderID contains "/" — so every code path that
// onboards a provider (configured pinned, WS Hello, WS auth_request
// initial/proof, admission IssueToken, MintAdmissionTokenAndPairOT) MUST
// funnel through this helper to keep that invariant.
func ValidateProviderID(s string) error {
	if !providerIDPattern.MatchString(s) {
		return fmt.Errorf("invalid provider_id %q", s)
	}
	return nil
}

// ValidateCompatibilitySetID applies the signed release-manifest identifier
// grammar at the coordinator trust boundary. Admission compares the complete
// identifier exactly; the grammar and byte cap prevent attacker-controlled
// handshake metadata from becoming an unbounded policy or logging input.
func ValidateCompatibilitySetID(s string) error {
	if len([]byte(s)) == 0 || len([]byte(s)) > maxCompatibilitySetIDBytes || !compatibilitySetIDPattern.MatchString(s) {
		return fmt.Errorf("invalid compatibility_set_id %q", s)
	}
	return nil
}

// minAuditLogRetentionDays is the compliance floor for audit_log retention.
// Operators may not set audit_log_retention_days below this value.
const minAuditLogRetentionDays = 90

type Config struct {
	Listen                       ListenConfig                 `yaml:"listen"`
	Coordinator                  CoordinatorConfig            `yaml:"coordinator"`
	Pool                         PoolConfig                   `yaml:"pool"`
	Routing                      RoutingConfig                `yaml:"routing"`
	ProviderHTTP                 ProviderHTTPConfig           `yaml:"provider_http"`
	Limits                       LimitsConfig                 `yaml:"limits"`
	WS                           WSConfig                     `yaml:"ws"`
	Relay                        RelayConfig                  `yaml:"relay"`
	Admission                    AdmissionConfig              `yaml:"admission"`
	Tier2                        Tier2Config                  `yaml:"tier2"`
	CoordinatorAdvertisedVersion CoordinatorAdvertisedVersion `yaml:"coordinator_advertised_version"`
	Auth                         AuthConfig                   `yaml:"auth"`
	Referrals                    ReferralConfig               `yaml:"referrals"`
	Storage                      StorageConfig                `yaml:"storage"`
	Logging                      LoggingConfig                `yaml:"logging"`
	Rewards                      RewardsConfig                `yaml:"rewards"`
	Settlement                   SettlementConfig             `yaml:"settlement"`
	Billing                      BillingConfig                `yaml:"billing"`
	Endpoints                    EndpointsConfig              `yaml:"endpoints"`
	Explorer                     ExplorerConfig               `yaml:"explorer"`
	Stats                        StatsConfig                  `yaml:"stats"`
	Onboarding                   OnboardingConfig             `yaml:"onboarding"`
	MalibuEmission               MalibuEmissionConfig         `yaml:"malibu_emission"`
	AutotuneFeeds                AutotuneFeedsConfig          `yaml:"autotune"`
	ProofOfWeights               ProofOfWeightsConfig         `yaml:"proof_of_weights"`
	Proxy                        ProxyConfig                  `yaml:"proxy"`
	Providers                    []ProviderConfig             `yaml:"providers"`
	// Payout is the SPEC-016 payout-pipeline configuration.
	// Default Enabled=false ships the schema migrations + handlers
	// idle; flipping to true activates the §3.3 endpoint (Step 1)
	// and the runner cycle (Step 2+, not present yet). See SPEC-016
	// §6.5 for the dual-loader namespace split (Step 4).
	Payout PayoutConfig `yaml:"payout"`
}

// PayoutConfig is the operator-facing root of the SPEC-016
// `payout.*` namespace. At Step 1 only the security.hot_wallet_address
// and a single tuning knob (address_cooling_off_period) are read;
// the §6.5 dual-loader split lands in Step 4 with the full key set.
type PayoutConfig struct {
	Enabled  bool                 `yaml:"enabled"`
	Security PayoutSecurityConfig `yaml:"security"`
	Tuning   PayoutTuningConfig   `yaml:"tuning"`
}

// PayoutSecurityConfig holds SPEC-016 §6.5 `payout.security.*` keys
// — the IMMUTABLE-at-startup subset. Step 2 grows this struct with
// caps + RPC URLs + abandon caps; Step 4 will land the full §6.5
// dual-loader split (SIGHUP-only tuning, fsnotify-forbidden, etc.).
// At Step 2 the values are read once at process start and not
// re-loaded; no SIGHUP handler touches these.
type PayoutSecurityConfig struct {
	// HotWalletAddress is the operator hot wallet on Base mainnet.
	// SPEC §3.2 step 5 uses it as the EIP-712 verifyingContract;
	// §3.4 stamps it into provider_payout_addresses.registered_against_hot_wallet
	// on every successful INSERT/UPDATE.
	HotWalletAddress string `yaml:"hot_wallet_address"`

	// RPCURLPrimary / RPCURLSecondary are the two Base mainnet
	// JSON-RPC endpoints. SPEC §4.4 REQUIRES two; single-RPC is
	// REJECTED at v0.1.x. The two MUST be loaded from SEPARATE
	// secrets paths (§4.4 trust-separation requirement); this is
	// enforced operationally via config-file layout, not by IMPL.
	RPCURLPrimary   string `yaml:"rpc_url_primary"`
	RPCURLSecondary string `yaml:"rpc_url_secondary"`

	// PerPayoutCapUSDCBaseUnits is the §5.2 per-payout ceiling.
	// Default $500 = 500_000_000 base units.
	PerPayoutCapUSDCBaseUnits int64 `yaml:"per_payout_cap_usdc_base_units"`

	// PerDayCapUSDCBaseUnits is the §5.3 rolling 24h ceiling.
	// Default $5,000 = 5_000_000_000 base units.
	PerDayCapUSDCBaseUnits int64 `yaml:"per_day_cap_usdc_base_units"`

	// CancelMaxTipMultiplier is the §4.6 cap on the tip multiplier
	// supplied by the operator on /admin/payout/abandon-attempt.
	// Default 5×. Requests above are silently floored with a
	// cap_applied log entry.
	CancelMaxTipMultiplier float64 `yaml:"cancel_max_tip_multiplier"`

	// CancelMaxGasNativeWei is the §4.6 per-cancel gas ceiling.
	// Default 0.01 ETH = 1e16 wei. Requests above 422 reject.
	CancelMaxGasNativeWei int64 `yaml:"cancel_max_gas_native_wei"`

	// CancelMaxGasNativeWeiPer24h is the §4.6 24h aggregate gas
	// ceiling. Default 0.05 ETH = 5e16 wei. SUM over confirmed
	// cancels in the window + the current-request estimate.
	CancelMaxGasNativeWeiPer24h int64 `yaml:"cancel_max_gas_native_wei_per_24h"`

	// AbandonRatePerHour is the §4.6 per-operator-token rate
	// limit on the abandon endpoint. Default 3.
	AbandonRatePerHour int `yaml:"abandon_rate_per_hour"`

	// ChainReconInterval is the §4.4 / §7.4 chain-balance recon
	// cadence (Step 4 wiring, Step 2 reads the value). Default 1h.
	ChainReconInterval time.Duration `yaml:"chain_recon_interval"`

	// ChainReconToleranceUSDCBaseUnits is the §4.4 drift
	// threshold. Default $0.10 = 100_000 base units.
	ChainReconToleranceUSDCBaseUnits int64 `yaml:"chain_recon_tolerance_usdc_base_units"`

	// PauseResumeMinInterval is the §6.4.1 endpoint rate-limit
	// floor. Default 60s. Step 3 wiring.
	PauseResumeMinInterval time.Duration `yaml:"pause_resume_min_interval"`

	// EncryptedWalletPath is the on-disk AES-256-GCM-encrypted
	// secp256k1 wallet file. SPEC §6.3 production path; the
	// runner decrypts at startup using the KEK supplied via
	// systemd LoadCredential= (preferred) or
	// MACPROVIDER_PAYOUT_WALLET_KEK env var. Required when
	// payout.enabled=true unless DevMode is also true.
	EncryptedWalletPath string `yaml:"encrypted_wallet_path"`

	// EncryptedWalletOnDiskHex indicates the wallet file is
	// stored as hex-encoded bytes (vs raw bytes). Default false
	// (raw bytes).
	EncryptedWalletOnDiskHex bool `yaml:"encrypted_wallet_on_disk_hex"`

	// DevMode permits loading the wallet from the dev-only env
	// var (MACPROVIDER_PAYOUT_WALLET_KEY_HEX_DEV_ONLY) instead
	// of the encrypted file + KEK production path. NEVER enable
	// in production. Step 2 [sec:2.3] HIGH closure: dev path
	// MUST be explicitly opted-in.
	DevMode bool `yaml:"dev_mode"`
}

// PayoutTuningConfig holds SPEC-016 §6.5 `payout.tuning.*` keys —
// the SIGHUP-reloadable subset (full hot-reload semantics land in
// Step 4; Step 2 just reads the values at startup). Hard bounds
// per §6.5 are enforced at parse time.
type PayoutTuningConfig struct {
	// AddressCoolingOffPeriod is the §3.3 cooling-off window for
	// freshly-registered or rotated addresses. Default 24h.
	// SPEC §3.1 floor: 1h.
	AddressCoolingOffPeriod time.Duration `yaml:"address_cooling_off_period"`

	// RunInterval is the §4.2 runner cadence. Default 6h.
	// SPEC §6.5 bounds: [5m, 24h].
	RunInterval time.Duration `yaml:"run_interval"`

	// RunNowMinInterval rate-limits the §4.2 admin run-now endpoint.
	// Default 60s. SPEC §6.5 bounds: [10s, 1h].
	RunNowMinInterval time.Duration `yaml:"run_now_min_interval"`

	// ConfirmationBlocks is the §4.3 step 7 receipt-depth threshold
	// for the two-RPC confirm. Default 5. SPEC §6.5 bounds
	// [5, 200] (v0.1.20 round-20 M2 closure widened from [2, 50]).
	ConfirmationBlocks int `yaml:"confirmation_blocks"`

	// MaxRowsPerRun caps the §4.3 step 1 SELECT. Default 50.
	// SPEC §6.5 bounds: [1, 500].
	MaxRowsPerRun int `yaml:"max_rows_per_run"`

	// ReorgPollWindow is the §4.7 re-poll window for already-
	// confirmed rows. Default 24h. SPEC §6.5 bounds [1h, 168h]
	// (v0.1.20 round-20 M1 closure).
	ReorgPollWindow time.Duration `yaml:"reorg_poll_window"`

	// LowBalanceThreshold / LowNativeThreshold drive §6.2 alerts
	// (Step 4 wiring; Step 2 reads). Defaults: 0 (disabled).
	LowBalanceThreshold int64 `yaml:"low_balance_threshold"`
	LowNativeThreshold  int64 `yaml:"low_native_threshold"`

	// RPCURLPrimaryPinSPKI / RPCURLSecondaryPinSPKI are optional
	// SHA-256 SPKI cert pins for the two RPCs (§4.4). 64-hex chars
	// or empty.
	RPCURLPrimaryPinSPKI   string `yaml:"rpc_url_primary_pin_spki"`
	RPCURLSecondaryPinSPKI string `yaml:"rpc_url_secondary_pin_spki"`
}

// ProofOfWeightsConfig gates Session B integrity controls. Defaults keep
// legacy self-declared hello model_id behavior until the operator enables
// the autotune hello gate explicitly.
type ProofOfWeightsConfig struct {
	RequireAutotuneHelloGate bool                 `yaml:"require_autotune_hello_gate"`
	AutotuneEvidenceTTLDays  int                  `yaml:"autotune_evidence_ttl_days"`
	TelemetryDrift           TelemetryDriftConfig `yaml:"telemetry_drift"`
}

// TelemetryDriftConfig enables observe-only operator alerts when live
// provider telemetry diverges from verified autotune evidence or W3 OPoI
// pass-rate baselines. Default-off; does not change routing or sanctions.
type TelemetryDriftConfig struct {
	Enabled                  bool     `yaml:"enabled"`
	TPSRatioThreshold        float64  `yaml:"tps_ratio_threshold"`
	TPSMinAbsolute           float64  `yaml:"tps_min_absolute"`
	TPSMinRequestsWindow     int      `yaml:"tps_min_requests_window"`
	HashAlertOnStatus        []string `yaml:"hash_alert_on_status"`
	HashAlertOnArtifactDrift bool     `yaml:"hash_alert_on_artifact_drift"`
	OPoIPassRateWindow       int      `yaml:"opoi_pass_rate_window"`
	OPoIPassRateThreshold    float64  `yaml:"opoi_pass_rate_threshold"`
	AlertCooldownSeconds     int      `yaml:"alert_cooldown_s"`
	// QuarantineMissingBenchmark turns the "no verified benchmark" observation
	// from a silent pass into a routing quarantine (fail-suspect, not
	// fail-open). It is a SECOND gate on top of Enabled — enabling
	// telemetry_drift alone keeps the existing observe-only posture and only
	// starts emitting the `missing_benchmark` alert. Both flags must be true
	// before an un-benchmarked provider stops receiving buyer traffic, because
	// the verified-evidence pipeline (autotune hardware evidence) does not yet
	// cover the whole fleet and a single-flag rollout could empty the pool.
	QuarantineMissingBenchmark bool `yaml:"quarantine_missing_benchmark"`
}

type CoordinatorConfig struct {
	RequireGatewayContext bool                   `yaml:"require_gateway_context"`
	CompatibilitySet      CompatibilitySetConfig `yaml:"compatibility_set"`
}

// CompatibilitySetConfig is an exact coordinator admission contract. TargetID
// is the set providers should converge on; AcceptedIDs includes that target and
// at least one distinct rollback set so a rollout can be reversed without
// disabling strict compatibility admission.
//
// FirstHopBridgeIDs is the production #610 pre-fix bootstrap: exact set IDs
// (for example the last public pre-fix CLI set v1.8.48) that may open a
// session solely to receive the recommended target admission. Bridge-only
// sessions are never buyer-routable. They are distinct from AcceptedIDs.
type CompatibilitySetConfig struct {
	TargetID          string   `yaml:"target_id"`
	AcceptedIDs       []string `yaml:"accepted_ids"`
	FirstHopBridgeIDs []string `yaml:"first_hop_bridge_ids"`
}

// Configured distinguishes an explicit strict policy from the legacy
// unconfigured mode. Partial configurations fail validation.
func (c CompatibilitySetConfig) Configured() bool {
	return c.TargetID != "" || len(c.AcceptedIDs) != 0 || len(c.FirstHopBridgeIDs) != 0
}

// Accepts performs the exact, case-sensitive compatibility-set comparison for
// buyer-serving admission.
func (c CompatibilitySetConfig) Accepts(id string) bool {
	for _, accepted := range c.AcceptedIDs {
		if id == accepted {
			return true
		}
	}
	return false
}

// IsFirstHopBridge reports whether id is listed for the temporary pre-fix
// update bootstrap. Bridge membership alone never implies Accepts.
func (c CompatibilitySetConfig) IsFirstHopBridge(id string) bool {
	for _, bridge := range c.FirstHopBridgeIDs {
		if id == bridge {
			return true
		}
	}
	return false
}

// IsFirstHopBridgeOnly is true when the set may open an update-only session
// but is not part of the buyer-serving accepted set.
func (c CompatibilitySetConfig) IsFirstHopBridgeOnly(id string) bool {
	return c.IsFirstHopBridge(id) && !c.Accepts(id)
}

// AllowsSession admits either a buyer-serving accepted set or a first-hop
// bridge set through the hello/auth compatibility gate.
func (c CompatibilitySetConfig) AllowsSession(id string) bool {
	return c.Accepts(id) || c.IsFirstHopBridge(id)
}

// OnboardingConfig gates SPEC-026 App-track `/v1/providers/register`.
// Default-off preserves backward-compatible binary rollout; production
// traffic enablement waits for the SPEC-026 §4.3 proof-stage verifier.
type OnboardingConfig struct {
	AppTrackRegisterEnabled bool              `yaml:"app_track_register_enabled"`
	PostgresDSN             string            `yaml:"postgres_dsn"`
	AuthPolicyRequestDSN    string            `yaml:"auth_policy_request_dsn"`
	AuthPolicyApproveDSN    string            `yaml:"auth_policy_approve_dsn"`
	AuthPolicyCutoverDSN    string            `yaml:"auth_policy_cutover_dsn"`
	HardwareTrustRequestDSN string            `yaml:"hardware_trust_request_dsn"`
	HardwareTrustApproveDSN string            `yaml:"hardware_trust_approve_dsn"`
	BundleID                string            `yaml:"bundle_id"`
	AppleTeamID             string            `yaml:"apple_team_id"`
	CoordinatorDomain       string            `yaml:"coordinator_domain"`
	ASNPrefixes             map[string]string `yaml:"asn_prefixes"`
}

// MalibuEmissionConfig gates SPEC-MALIBU-EMISSION-LEDGER bootstrap accrual.
// Default-off; money-path changes require PR + audit.
type MalibuEmissionConfig struct {
	Enabled                     bool     `yaml:"enabled"`
	WriterDSN                   string   `yaml:"writer_dsn"`
	TickIntervalSeconds         int      `yaml:"tick_interval_seconds"`
	ProviderDailyCapMALIBU      float64  `yaml:"provider_daily_cap_malibu"`
	WalletDailyCapMALIBU        float64  `yaml:"wallet_daily_cap_malibu"`
	SQLitePayoutDBPath          string   `yaml:"sqlite_payout_db_path"`
	WalletMirrorIntervalSeconds int      `yaml:"wallet_mirror_interval_seconds"`
	UnlockEvalIntervalSeconds   int      `yaml:"unlock_eval_interval_seconds"`
	MaxSerializableRetries      int      `yaml:"max_serializable_retries"`
	BaseUSDCBalanceRPCURLs      []string `yaml:"base_usdc_balance_rpc_urls"`
}

// AutotuneFeedsConfig points at the signed SPEC-023 recommendation feeds
// served on the buyer mux (/v1/rate-card, /v1/demand-rank,
// /v1/autotune-candidates, and their .sig sidecars). Empty paths disable that
// feed (404).
type AutotuneFeedsConfig struct {
	RateCardPath              string `yaml:"rate_card_path"`
	RateCardSigPath           string `yaml:"rate_card_sig_path"`
	DemandRankPath            string `yaml:"demand_rank_path"`
	DemandRankSigPath         string `yaml:"demand_rank_sig_path"`
	AutotuneCandidatesPath    string `yaml:"autotune_candidates_path"`
	AutotuneCandidatesSigPath string `yaml:"autotune_candidates_sig_path"`
	// EnforceProviderAdmission is the shared strict-mode switch for signed
	// catalog compatibility and challenge-bound provider identity. Disabling it
	// opens only the deadline-bounded migration bridge below.
	EnforceProviderAdmission        bool              `yaml:"enforce_provider_admission"`
	ProviderAdmissionBridgeDeadline string            `yaml:"provider_admission_bridge_deadline"`
	PublicKeys                      map[string]string `yaml:"public_keys"`
}

const maxProviderAdmissionBridgeDuration = 24 * time.Hour

// ProviderAdmissionBridgeDeadlineTime parses the absolute deadline that bounds
// the metadata-free provider migration bridge. Strict admission does not need a
// deadline; a configured value is still parsed so stale operator typos cannot
// hide in an otherwise-valid config.
func (c AutotuneFeedsConfig) ProviderAdmissionBridgeDeadlineTime() (time.Time, error) {
	raw := c.ProviderAdmissionBridgeDeadline
	if raw == "" {
		return time.Time{}, nil
	}
	if strings.TrimSpace(raw) != raw {
		return time.Time{}, fmt.Errorf("autotune.provider_admission_bridge_deadline must be a trimmed RFC3339 timestamp")
	}
	deadline, err := time.Parse(time.RFC3339, raw)
	if err != nil {
		return time.Time{}, fmt.Errorf("autotune.provider_admission_bridge_deadline must be RFC3339: %w", err)
	}
	return deadline.UTC(), nil
}

// DecodePublicKeyring validates and decodes the configured key-ID-to-Ed25519
// trust map. Keys use canonical padded standard base64 so operator mistakes do
// not silently select a different decoder or byte representation.
func (c AutotuneFeedsConfig) DecodePublicKeyring() (map[string]ed25519.PublicKey, error) {
	keyIDs := make([]string, 0, len(c.PublicKeys))
	for keyID := range c.PublicKeys {
		keyIDs = append(keyIDs, keyID)
	}
	sort.Strings(keyIDs)

	keyring := make(map[string]ed25519.PublicKey, len(c.PublicKeys))
	for _, keyID := range keyIDs {
		if keyID == "" || strings.TrimSpace(keyID) != keyID {
			return nil, fmt.Errorf("autotune.public_keys contains an invalid key ID %q", keyID)
		}
		encoded := c.PublicKeys[keyID]
		decoded, err := base64.StdEncoding.Strict().DecodeString(encoded)
		if err != nil || base64.StdEncoding.EncodeToString(decoded) != encoded {
			return nil, fmt.Errorf("autotune.public_keys.%s must be canonical padded base64", keyID)
		}
		if len(decoded) != ed25519.PublicKeySize {
			return nil, fmt.Errorf("autotune.public_keys.%s must decode to %d bytes", keyID, ed25519.PublicKeySize)
		}
		keyring[keyID] = ed25519.PublicKey(append([]byte(nil), decoded...))
	}
	return keyring, nil
}

// StatsConfig is the SPEC-017 Network Stats API config block.
//
// All DSN fields are sourced from env at deploy time per the
// existing config-loader env-override pattern; storing plaintext
// DSNs in coordinator.yaml is a SECURITY violation and the
// validator MAY refuse to start if a DSN appears literal-shaped
// in the YAML file. v0.1 IMPL trusts the env-override path; the
// validator does not pattern-match against the YAML body
// (operator-managed secret hygiene).
//
// Stats.Enabled defaults to false so existing coordinator
// deployments continue to function unchanged at upgrade time —
// the /v1/stats/* mux subtree is not registered until the
// operator flips this flag (BUILD §C.4).
type StatsConfig struct {
	Enabled bool `yaml:"enabled"`

	// DSNs per active daemon role. When Enabled = true, the
	// reader and rollup DSNs MUST be non-empty. ProviderPortalDSN
	// is retained for portal/operator tooling compatibility but
	// is not opened by the public stats daemon.
	ReaderDSN         string `yaml:"reader_dsn"`
	RollupDSN         string `yaml:"rollup_dsn"`
	ProviderPortalDSN string `yaml:"provider_portal_dsn"`

	// PartnerKeys gates the optional partner_keys_writer pool.
	// v0.1 default: LastUsedAtUpdatesEnabled=false; WriterDSN
	// unused (BUILD §C.2).
	PartnerKeys StatsPartnerKeysConfig `yaml:"partner_keys"`

	// PartnerKeysAdminDSN is the CLI operator DSN (Step 4.A).
	// Step 1 declares the field; coordinator startup MUST NOT
	// open a pool for it (BUILD §D.6 / SECURITY §B.1).
	PartnerKeysAdminDSN string `yaml:"partner_keys_admin_dsn"`

	Rollup           StatsRollupConfig           `yaml:"rollup"`
	CORS             StatsCORSConfig             `yaml:"cors"`
	RateLimit        StatsRateLimitConfig        `yaml:"rate_limit"`
	StreamingMetrics StatsStreamingMetricsConfig `yaml:"streaming_metrics"`

	// TrustedProxies — operator-allowlisted X-Forwarded-For
	// trusted hops, consumed by Step 3's auth-failure tier
	// limiter for client-IP derivation (SPEC §5.6 v0.1.8 +
	// SECURITY r5 H1). Step 1 declares; Step 3 consumes.
	TrustedProxies  []string `yaml:"trusted_proxies"`
	TrustDirectPeer bool     `yaml:"trust_direct_peer"`
}

type StatsRateLimitConfig struct {
	MaxBuckets              int `yaml:"max_buckets"`
	IdleTTLSeconds          int `yaml:"idle_ttl_seconds"`
	EvictionIntervalSeconds int `yaml:"eviction_interval_seconds"`
	PreflightRPM            int `yaml:"preflight_rpm"`
}

type StatsStreamingMetricsConfig struct {
	MaxSamples int `yaml:"max_samples"`
}

type StatsPartnerKeysConfig struct {
	LastUsedAtUpdatesEnabled bool   `yaml:"last_used_at_updates_enabled"`
	WriterDSN                string `yaml:"writer_dsn"`

	// ProductionSignoffPath is the v0.1.8 erratum
	// (2026-06-26) mechanical gate for SPEC §6.6.2's
	// launch-sequencing precondition. When this field is set
	// on a deployed coordinator config, `partner-keys issue`
	// reads the file at this path AND requires its content
	// to match the SPEC-014 SHA + YYYY-MM-DD sign-off
	// template (see OPS.md §10.5). Issuance fails closed if
	// the file is missing, empty, or malformed.
	//
	// When this field is UNSET (empty), the coordinator is
	// treated as staging — no preconditions apply, and
	// `partner-keys issue` operates against fixture DSNs
	// without sign-off. Production deploys MUST set this
	// field in coordinator.yaml; staging / test fixtures
	// MUST NOT.
	//
	// ARCH r3 CRITICAL closure: the gate is config-driven
	// (rather than opt-in via a `--production` CLI flag) so
	// a wrapper-script automation that forgets the flag
	// cannot accidentally bypass the runbook sign-off. The
	// deployed config is the source of truth for
	// "is this coordinator production".
	ProductionSignoffPath string `yaml:"production_signoff_path"`
}

type StatsRollupConfig struct {
	// BackfillMode is "partial" (Path A, default per
	// [[macprovider-vercel-demo]] thin-ship pattern) or "full"
	// (Path B). See SPEC §9.7.
	BackfillMode string `yaml:"backfill_mode"`
	// PartialHistorySince is the RFC 3339 rollup-start
	// timestamp. Empty when BackfillMode = "full". Step 2/3
	// consume.
	PartialHistorySince string `yaml:"partial_history_since"`
	// LateEventsRetentionDays — SPEC §9.3 (v0.1.7). Default 90;
	// floor 30. Step 2 floor-clamps with a WARN log; below-floor
	// values DO NOT fail startup (chosen pin: clamp+warn).
	LateEventsRetentionDays int `yaml:"late_events_retention_days"`
	// UsdPerMillionCredits — credits→USD conversion factor.
	// SPEC-005 v0.3 stores `ledger_request_credits.provider_credits`
	// as INTEGER credits; SPEC-016 v0.1.19 has not normatively
	// pinned a credit→USD ratio. SPEC-017 v0.1 IMPL exposes this
	// as a single operator-tunable factor: rollup computes
	// `earnings_work_usd = provider_credits * UsdPerMillionCredits
	// / 1_000_000`. Default 1.0 (1 USD per million credits).
	// Operator MAY override per ramp; the formula is documented
	// in OPS.md.
	UsdPerMillionCredits float64 `yaml:"usd_per_million_credits"`
	// DriftThresholdRatio — fractional divergence (>0.005 = >0.5%
	// per SPEC §9.4) at which the nightly rebuild emits
	// `stats_rollup_drift_detected`. Operator MAY tune within
	// [0.001, 0.05]; default 0.005.
	DriftThresholdRatio float64 `yaml:"drift_threshold_ratio"`
	// NightlyRebuildHourUTC — UTC hour [0,23] for the nightly
	// `stats_leaderboard_all` + `stats_leaderboard_30d` rebuild.
	// Default 9 per SPEC §9.3 (operator-pin off-hours).
	NightlyRebuildHourUTC int `yaml:"nightly_rebuild_hour_utc"`
	// LateEventsLookbackHours — SPEC §9.3 48h default; operator
	// MAY raise to 72/96. Lower than 24 breaks the 1× SPEC-005
	// reconciliation-margin invariant.
	LateEventsLookbackHours int `yaml:"late_events_lookback_hours"`
}

type StatsCORSConfig struct {
	// AccessControlMaxAgeSeconds — SPEC §5.7 v0.1.7 default 60,
	// operator may raise via runtime config to ≤300; >300
	// requires a SPEC bump. Step 3 consumes; Step 1 only
	// declares.
	AccessControlMaxAgeSeconds int      `yaml:"access_control_max_age_seconds"`
	PartnerOriginAllowlist     []string `yaml:"partner_origin_allowlist"`
}

// ProxyConfig configures how the coordinator interprets `X-Forwarded-For` /
// `X-Real-IP` headers when deriving per-buyer rate-limit keys. Issue #125
// (post-PR-#124 follow-up): production sits behind nginx on loopback, so
// the default trusted-proxies list `["127.0.0.0/8", "::1/128"]` covers
// that topology. Operators deploying behind a remote LB or non-loopback
// reverse proxy MUST add the proxy's CIDR(s) here; otherwise the
// coordinator will treat the proxy as untrusted and key the rate-limit
// bucket on the proxy's IP — collapsing all upstream buyers into one
// shared bucket. Conversely, expanding this list to non-actual-proxy
// CIDRs lets attackers in those CIDRs spoof their bucket key via
// `X-Forwarded-For`; treat the list as security-sensitive.
type ProxyConfig struct {
	// TrustedProxies is a list of CIDR ranges whose `X-Forwarded-For` /
	// `X-Real-IP` headers the coordinator will honor when deriving the
	// per-source rate-limit key for `/v1/pool/check`, `/v1/receipt-keys/*`,
	// and `/catalog/*`. Default `["127.0.0.0/8", "::1/128"]` matches the
	// production nginx-on-localhost topology (see
	// `phase4-coordinator/dist/nginx-coordinator.streamvc.live.conf`).
	// Invalid CIDRs and default-route prefixes (`0.0.0.0/0`, `::/0`)
	// fail `config.Load` at startup via `TrustedProxyPrefixes`.
	TrustedProxies []string `yaml:"trusted_proxies"`
}

type ListenConfig struct {
	BuyerPort    int    `yaml:"buyer_port"`
	ProviderPort int    `yaml:"provider_port"`
	BindAddress  string `yaml:"bind_address"`
}

type PoolConfig struct {
	HeartbeatIntervalS     int `yaml:"heartbeat_interval_s"`
	DisconnectGracePeriodS int `yaml:"disconnect_grace_period_s"`
	// HeartbeatMissThresholdS bounds how long a provider may go without ANY
	// inbound frame (heartbeat OR in-flight inference response) before the
	// liveness monitor closes its WebSocket. It MUST be generous relative to
	// HeartbeatIntervalS: a provider doing single-threaded MLX inference may
	// not emit a heartbeat for the duration of a generation, but its response
	// chunks count as activity and keep the socket alive. Decoupled from
	// routing.failover_timeout_s (which governs replacement selection, not
	// liveness). Defaults to 90s (3x the 30s heartbeat interval).
	HeartbeatMissThresholdS int `yaml:"heartbeat_miss_threshold_s"`
	// MaxConcurrencyCeiling caps the provider-reported `max_concurrency` (and
	// the derived slot counts) at ingest (issue #764). Without it a box
	// reporting 9999 is granted 9999 admission slots and out-ranks the honest
	// fleet.
	//
	// The default 8 is the LARGEST value the honest fleet can produce: the
	// provider CLI derives max_concurrency from the RAM tier and its top tier
	// (64GB+) is exactly 8 (phase3-binary/.../ProviderStatus.swift `defaults(
	// forPhysicalMemoryGB:)` — 8GB→1, 16GB→2, 32GB→4, 64GB+→8). The autotune
	// recommender is stricter still, refusing to publish a
	// `max_concurrency_override` above 1 (internal/buyer/autotune_feeds.go),
	// because these are Macs running MLX where a generation saturates
	// unified-memory bandwidth and requests effectively serialize. So 8 clamps
	// nothing a current honest provider reports while making a 9999 claim
	// inert. Raise it only alongside a provider-side tier that legitimately
	// exceeds it.
	//
	// An over-claiming provider is NOT rejected (it may simply be running an
	// old or misconfigured build) — it is clamped and counted by the permanent
	// over-claim tripwire. 0 disables the clamp entirely.
	MaxConcurrencyCeiling int `yaml:"max_concurrency_ceiling"`
	WakeGapThresholdS     int `yaml:"wake_gap_threshold_s"`
	// WakeGapThresholdMs, when > 0, overrides WakeGapThresholdS for
	// millisecond-precision test scenarios. Not for production use.
	WakeGapThresholdMs      int  `yaml:"wake_gap_threshold_ms"`
	WarmupFallbackS         int  `yaml:"warmup_fallback_s"`
	WarmupGateEnabled       bool `yaml:"warmup_gate_enabled"`
	WarmupGateTimeoutS      int  `yaml:"warmup_gate_timeout_s"`
	WarmupGateMaxTokens     int  `yaml:"warmup_gate_max_tokens"`
	DegradedBackoffS        int  `yaml:"degraded_backoff_s"`
	DegradedMaxRetries      int  `yaml:"degraded_max_retries"`
	DegradedProbeAfter502   bool `yaml:"degraded_probe_after_502"`
	BreakerFailureThreshold int  `yaml:"breaker_failure_threshold"`
	BreakerWindowS          int  `yaml:"breaker_window_s"`
	CanaryEnabled           bool `yaml:"canary_enabled"`
	CanaryIntervalS         int  `yaml:"canary_interval_s"`
	CanaryTimeoutS          int  `yaml:"canary_timeout_s"`
	CanaryMaxTokens         int  `yaml:"canary_max_tokens"`
	CanaryFailureThreshold  int  `yaml:"canary_failure_threshold"`
	// CanaryColdStartGraceS relaxes the WALL-TIME latency gates (max_ttft_ms and
	// min_sustained_tps) for the first grace-window seconds after a provider
	// connects. Canary probes are non-streaming, so both metrics are measured
	// over wall time and are dominated by a cold large-model load; a
	// correct-but-slow answer must not trip a latency sanction on (re)connect.
	// 0 (default) disables it. The nonce-correctness gate is NEVER relaxed, a
	// graced probe is neutral for the sanction counter, and it forces the next
	// probe to be enforced — so this cannot be used to evade sanctions. Size it
	// to cover a cold large-model load (observed ~8s TTFT for a cold 30B; a full
	// load can take tens of seconds).
	CanaryColdStartGraceS int `yaml:"canary_cold_start_grace_s"`
	// CanaryLatencyEnforcement controls whether the WALL-TIME latency gates
	// (max_ttft_ms / min_sustained_tps) SANCTION a provider or are observe-only.
	// Canary probes are non-streaming (stream:false), so these wall-time metrics
	// are structurally unreliable — measured TTFT/TPS swing widely for the same
	// healthy provider depending on relay chunk timing. Default "observe": a
	// latency breach on a nonce-correct probe is logged (canary_latency_observed)
	// but does NOT count as a canary failure. "enforce": a latency breach fails
	// the probe (subject to CanaryColdStartGraceS). The nonce-correctness gate is
	// ALWAYS enforced in both modes. Empty = "observe".
	CanaryLatencyEnforcement string                             `yaml:"canary_latency_enforcement"`
	CanaryChallenges         []CanaryChallengeConfig            `yaml:"canary_challenges"`
	ModelClassChallenges     map[string][]CanaryChallengeConfig `yaml:"model_class_challenges"`
	LosslessnessProbe        LosslessnessProbeConfig            `yaml:"losslessness_probe"`
}

// CanaryLatencyMode normalizes CanaryLatencyEnforcement (empty defaults to
// observe).
func (p PoolConfig) CanaryLatencyMode() string {
	if strings.EqualFold(strings.TrimSpace(p.CanaryLatencyEnforcement), "enforce") {
		return "enforce"
	}
	return "observe"
}

// CanaryLatencyEnforced reports whether latency-gate breaches sanction the
// provider (enforce mode) or are observe-only (default).
func (p PoolConfig) CanaryLatencyEnforced() bool {
	return p.CanaryLatencyMode() == "enforce"
}

type CanaryChallengeConfig struct {
	Prompt          string  `yaml:"prompt"`
	Expected        string  `yaml:"expected"`
	MaxTTFTMS       int     `yaml:"max_ttft_ms,omitempty"`
	MinSustainedTPS float64 `yaml:"min_sustained_tps,omitempty"`
}

func validateCanaryChallengeList(prefix string, challenges []CanaryChallengeConfig) error {
	for i, challenge := range challenges {
		if strings.TrimSpace(challenge.Prompt) == "" || strings.TrimSpace(challenge.Expected) == "" {
			return fmt.Errorf("%s[%d] prompt and expected must not be empty", prefix, i)
		}
		if !strings.Contains(challenge.Prompt, "{nonce}") || !strings.Contains(challenge.Expected, "{nonce}") {
			return fmt.Errorf("%s[%d] prompt and expected must contain {nonce}", prefix, i)
		}
		if challenge.MaxTTFTMS < 0 {
			return fmt.Errorf("%s[%d] max_ttft_ms must be >= 0", prefix, i)
		}
		if math.IsNaN(challenge.MinSustainedTPS) || math.IsInf(challenge.MinSustainedTPS, 0) || challenge.MinSustainedTPS < 0 {
			return fmt.Errorf("%s[%d] min_sustained_tps is invalid", prefix, i)
		}
	}
	return nil
}

func (p PoolConfig) CanaryChallengesForModel(modelID string) ([]CanaryChallengeConfig, bool) {
	modelID = strings.TrimSpace(modelID)
	if modelID == "" {
		return p.CanaryChallenges, false
	}
	if bank, ok := p.ModelClassChallenges[modelID]; ok && len(bank) > 0 {
		return bank, true
	}
	for key, bank := range p.ModelClassChallenges {
		if strings.EqualFold(strings.TrimSpace(key), modelID) && len(bank) > 0 {
			return bank, true
		}
	}
	return p.CanaryChallenges, false
}

type LosslessnessProbeConfig struct {
	Enabled                  bool `yaml:"enabled"`
	IntervalS                int  `yaml:"interval_s"`
	TimeoutS                 int  `yaml:"timeout_s"`
	MaxConcurrentPerProvider int  `yaml:"max_concurrent_per_provider"`
	MaxPromptsPerProbe       int  `yaml:"max_prompts_per_probe"`
	MaxStochasticPositions   int  `yaml:"max_stochastic_positions"`
	ProfileFreshnessTTLHours int  `yaml:"profile_freshness_ttl_hours"`
	EvidenceRetentionDays    int  `yaml:"evidence_retention_days"`
	BackoffMaxS              int  `yaml:"backoff_max_s"`
}

type RoutingConfig struct {
	PreflightThresholdTokens      int                         `yaml:"preflight_threshold_tokens"`
	PreflightTimeoutS             int                         `yaml:"preflight_timeout_s"`
	RequestTimeoutS               int                         `yaml:"request_timeout_s"`
	FailoverEnabled               bool                        `yaml:"failover_enabled"`
	FailoverTimeoutS              int                         `yaml:"failover_timeout_s"`
	TiebreakRandomize             bool                        `yaml:"tiebreak_randomize"`
	TiebreakEpsilon               float64                     `yaml:"tiebreak_epsilon"`
	MaxRetries                    int                         `yaml:"max_retries"`
	RetryPerAttemptTimeoutS       int                         `yaml:"retry_per_attempt_timeout_s"`
	MaxProvidersFaultedPerRequest int                         `yaml:"max_providers_faulted_per_request"`
	StickyEnabled                 bool                        `yaml:"sticky_enabled"`
	StickyTTLS                    int                         `yaml:"sticky_ttl_s"`
	StickyMaxEntries              int                         `yaml:"sticky_max_entries"`
	ModelClasses                  map[string]ModelClassConfig `yaml:"model_classes"`
}

type ModelClassConfig struct {
	Members   []string `yaml:"members"`
	Models    []string `yaml:"models"`
	Objective string   `yaml:"objective"`
}

type ProviderHTTPConfig struct {
	TimeoutS int `yaml:"timeout_s"`
}

type LimitsConfig struct {
	MaxChatRequestBodyBytes int64 `yaml:"max_chat_request_body_bytes"`
}

type WSConfig struct {
	WriteBufferSize        int   `yaml:"write_buffer_size"`
	HandshakeTimeoutS      int   `yaml:"handshake_timeout_s"`
	WriteTimeoutS          int   `yaml:"write_timeout_s"`
	MaxFrameBytes          int64 `yaml:"max_frame_bytes"`
	MaxUnauthenticatedConn int   `yaml:"max_unauthenticated_conn"`
	// MaxUnauthenticatedConnPerIP caps concurrent unauthenticated WS
	// handshakes from a single remote IP. Defense-in-depth against a single
	// host starving all provider readmissions even if it slips past nginx's
	// limit_conn (M1-4 / SECU-1). Default 4. Must be > 0.
	MaxUnauthenticatedConnPerIP int `yaml:"max_unauthenticated_conn_per_ip"`
}

type RelayConfig struct {
	MaxRequestBufferBytes int64 `yaml:"max_request_buffer_bytes"`
}

type AdmissionConfig struct {
	PinnedOnly                      bool    `yaml:"pinned_only"`
	ProvisionalAdmissionRatePerHour int     `yaml:"provisional_admission_rate_per_hour"`
	ProvisionalPoolMax              int     `yaml:"provisional_pool_max"`
	ProvisionalQuotaPerHour         int     `yaml:"provisional_quota_per_hour"`
	ProvisionalTierWeight           float64 `yaml:"provisional_tier_weight"`
	ProvisionalRetentionDays        int     `yaml:"provisional_retention_days"`
}

type Tier2Config struct {
	ObserveEnabled bool `yaml:"observe_enabled"`

	CatalogPath         string `yaml:"catalog_path"`
	CatalogPublicKey    string `yaml:"catalog_public_key"`
	RequireHashVerified bool   `yaml:"require_hash_verified"`
	// ModelHashLegacyUntil is the explicit, finite RFC3339 deadline during
	// which providers that omit model_hash_algorithm are treated as legacy
	// untyped evidence and are never compared to the canonical catalog hash.
	// Empty or expired means algorithm enforcement is active.
	ModelHashLegacyUntil string `yaml:"model_hash_legacy_until"`
	// PublicCatalogBaseURL is the public base URL the coordinator
	// advertises for SPEC-015 §M.4 catalog endpoints
	// (`GET /catalog/<catalog_id>` and `GET /catalog/pubkey`). When
	// non-empty, `/poolz` emits absolute catalog URLs derived from
	// this base (trailing slashes trimmed). When empty, `/poolz`
	// falls back to deriving an absolute URL from the inbound
	// request's scheme + `Host` header. If neither source yields a
	// usable base (catalog_id present but no host available),
	// `catalog_url` and `catalog_pubkey_url` are OMITTED from the
	// `/poolz` response — only `catalog_id` is emitted, so a
	// verifier invoked with `--catalog <path>` + `--catalog-pubkey`
	// (file-based, no URL resolution) still works.
	PublicCatalogBaseURL string `yaml:"public_catalog_base_url"`

	RequireEncryptedLeg            bool   `yaml:"require_encrypted_leg"`
	EncryptedLegAEAD               string `yaml:"encrypted_leg_aead"`
	EncryptedLegRekeyAfterRequests int    `yaml:"encrypted_leg_rekey_after_requests"`
	EncryptedLegRekeyAfterSeconds  int    `yaml:"encrypted_leg_rekey_after_seconds"`

	RequireAttestation   bool     `yaml:"require_attestation"`
	AttestationRoots     []string `yaml:"attestation_roots"`
	AttestationMaxAgeS   int      `yaml:"attestation_max_age_s"`
	AttestationFormats   []string `yaml:"attestation_formats"`
	AllowMockAttestation bool     `yaml:"allow_mock_attestation"`

	// SE liveness challenge settings (Phase 1, Track P1-C).
	// Only sent to providers whose SE pubkey is recorded (attestation_tier=self_signed).
	SELivenessIntervalS   int `yaml:"se_liveness_interval_s"`
	SELivenessTimeoutS    int `yaml:"se_liveness_timeout_s"`
	SELivenessMaxFailures int `yaml:"se_liveness_max_failures"`

	// MDM enrollment profile generation (Phase 2, Track P2-A, Scenario B).
	// Profile generation is enabled when MDM.EnrollmentBaseURL is non-empty.
	MDM Tier2MDMConfig `yaml:"mdm"`

	BehavioralSafetyEnabled    bool    `yaml:"behavioral_safety_enabled"`
	OutputSizeCapBytes         int64   `yaml:"output_size_cap_bytes"`
	OutputBytesPerTokenCeiling int     `yaml:"output_bytes_per_token_ceiling"`
	DefaultOutputSizeCapBytes  int64   `yaml:"default_output_size_cap_bytes"`
	EncodingValidationEnabled  bool    `yaml:"encoding_validation_enabled"`
	ResponseTimeAnomalyEnabled bool    `yaml:"response_time_anomaly_enabled"`
	ResponseTimeAnomalyFactor  float64 `yaml:"response_time_anomaly_factor"`
	ResponseTimeAnomalyMinMS   int64   `yaml:"response_time_anomaly_min_ms"`
}

// Tier2MDMConfig holds Phase 2 Track P2-A MDM enrollment profile settings.
// All fields are optional — profile generation is disabled when
// EnrollmentBaseURL is empty. Signer fields are optional; profiles are served
// unsigned (with a loud error log) when signing is not configured or fails.
type Tier2MDMConfig struct {
	// EnrollmentBaseURL is the canonical HTTPS base URL used to build SCEP and
	// MDM connect URLs inside the generated .mobileconfig. MUST be set
	// explicitly; the coordinator never derives this from the inbound request's
	// Host header — a client-controlled Host would let an attacker obtain a
	// coordinator-signed profile pointing enrollment at their own server.
	EnrollmentBaseURL string `yaml:"enrollment_base_url"`

	// MDMServerURL is the full MicroMDM /mdm/connect URL. When empty, falls
	// back to EnrollmentBaseURL + "/mdm/connect".
	MDMServerURL string `yaml:"mdm_server_url"`

	// SCEPUrl is the full SCEP endpoint URL. When empty, falls back to
	// EnrollmentBaseURL + "/scep".
	SCEPUrl string `yaml:"scep_url"`

	// PushTopic is the APNs push topic tied to the MDM push certificate,
	// e.g. "com.apple.mgmt.External.<uuid>". This is a placeholder until the
	// macprovider APNs certificate is provisioned; the profile is syntactically
	// valid without it but push-based MDM commands will not function.
	PushTopic string `yaml:"push_topic"`

	// ProfileSignerCertPath and ProfileSignerKeyPath point to PEM-encoded
	// signing cert + private key for optional CMS signing of generated
	// profiles. When empty, profiles are served unsigned (macOS will show
	// "Unsigned" in the install prompt, which is acceptable for enrollment).
	ProfileSignerCertPath string `yaml:"profile_signer_cert_path"`
	ProfileSignerKeyPath  string `yaml:"profile_signer_key_path"`
}

type CoordinatorAdvertisedVersion struct {
	LatestBinaryVersion   string `yaml:"latest_binary_version"`
	RequiredBinaryVersion string `yaml:"required_binary_version"`
	// PerModelRequiredBinaryVersion is the #768 per-model minimum binary
	// version floor: model_id -> minimum version. It sits BESIDE the
	// per-model hardware-tier gate (the signed autotune candidate catalog's
	// min_ram_gb / min_bandwidth_tier rows), which answers "is this box big
	// enough" but never "is this build new enough for the engine this model
	// needs".
	//
	// Unset (nil/empty) is the default posture and is byte-identical to
	// pre-#768 routing. Keys are matched case-insensitively against the
	// provider's advertised model_id. Values are validated at load; an
	// unparseable floor is a config error, not a silent fence.
	//
	// Unlike RequiredBinaryVersion (a hard ADMISSION floor enforced at the
	// provider hello with a 4004 close), these floors are ROUTING floors: a
	// below-floor provider stays connected and can still self-update, it just
	// is not routed to, warmed, or counted as a serving peer for that model.
	PerModelRequiredBinaryVersion map[string]string `yaml:"per_model_required_binary_version"`
}

type AuthConfig struct {
	OperatorKey  string            `yaml:"operator_key"`
	OperatorKeys map[string]string `yaml:"operator_keys"`
	// GatewayServiceToken is the REQUIRED service-to-service credential
	// the gateway uses when calling /internal/* coordinator endpoints
	// (M3-2 / SECU-4). After PR #172 merges, the coordinator
	// accepts ONLY GatewayServiceToken on the internal-bearer auth path
	// — the legacy operator_key fallback is removed by PR #172 (issue
	// #87 item 3). Must be non-empty AND distinct from every operator
	// credential:
	// equal values defeat the operator-vs-service credential split
	// because the operator credential would still authenticate
	// /internal/* by value.
	GatewayServiceToken string `yaml:"gateway_service_token"`
	// RequireProviderTokens fails closed for public provider WebSocket
	// exposure. Disable only for isolated local development or one-off
	// migrations where anonymous pinned-provider admission is acceptable.
	RequireProviderTokens bool `yaml:"require_provider_tokens"`
	// AllowTokenlessProvisionalBootstrap keeps RequireProviderTokens
	// fail-closed for normal reconnects while allowing a first tokenless
	// provisional provider to reach the self-serve mint/TOFU path. Existing
	// used-token identities still reject tokenless reconnects; enable only
	// for public onboarding.
	AllowTokenlessProvisionalBootstrap    bool              `yaml:"allow_tokenless_provisional_bootstrap"`
	CredentialBootstrapMintsPerIPHour     int               `yaml:"credential_bootstrap_mints_per_ip_hour"`
	CredentialBootstrapMintsPerIDHour     int               `yaml:"credential_bootstrap_mints_per_id_hour"`
	CredentialBootstrapMintsGlobalHour    int               `yaml:"credential_bootstrap_mints_global_hour"`
	CredentialBootstrapUnconfirmedMax     int               `yaml:"credential_bootstrap_unconfirmed_max"`
	CredentialBootstrapOutstandingMax     int               `yaml:"credential_bootstrap_outstanding_max"`
	CredentialBootstrapTokenTTLS          int               `yaml:"credential_bootstrap_token_ttl_s"`
	CredentialBootstrapIdentityRetentionS int               `yaml:"credential_bootstrap_identity_retention_s"`
	GitHubOAuth                           GitHubOAuthConfig `yaml:"github_oauth"`
}

// ReferralConfig owns pre-beta admission policy. All launch flags default
// off; HMAC material supports env:NAME indirection and never needs to be
// written to the credential database.
type ReferralConfig struct {
	RequireForRegistration   bool              `yaml:"require_for_registration"`
	EnablePublicValidation   bool              `yaml:"enable_public_validation"`
	EnableJoinLinks          bool              `yaml:"enable_join_links"`
	EnableSocialInviteBonus  bool              `yaml:"enable_social_invite_bonus"`
	Campaign                 string            `yaml:"campaign"`
	PolicyVersion            string            `yaml:"policy_version"`
	GrandfatherBefore        string            `yaml:"grandfather_before"`
	CurrentKeyID             string            `yaml:"current_key_id"`
	HMACKeys                 map[string]string `yaml:"hmac_keys"`
	ProviderBaseUses         int               `yaml:"provider_base_uses"`
	SocialBonusUses          int               `yaml:"social_bonus_uses"`
	ChallengeTTLS            int               `yaml:"challenge_ttl_s"`
	SocialVerificationDwellS int               `yaml:"social_verification_dwell_s"`
	JoinBaseURL              string            `yaml:"join_base_url"`
	XAPIBearerToken          string            `yaml:"x_api_bearer_token"`
	RequestAccessURL         string            `yaml:"request_access_url"`
}

type GitHubOAuthConfig struct {
	Enabled             bool   `yaml:"enabled"`
	ClientID            string `yaml:"client_id"`
	ClientSecret        string `yaml:"client_secret"`
	RedirectURI         string `yaml:"redirect_uri"`
	PortalBaseURL       string `yaml:"portal_base_url"`
	SessionCookieDomain string `yaml:"session_cookie_domain"`
}

type StorageConfig struct {
	DBPath                  string `yaml:"db_path"`
	SnapshotIntervalS       int    `yaml:"snapshot_interval_s"`
	RequestLogRetentionDays int    `yaml:"request_log_retention_days"`
	// SPEC-002 v1.3.5 §7.10.1 R-7.10.2 — retention for the
	// operator_model_swap audit_log table (and any future audit event
	// types). Default 90 days mirrors request_log_retention_days.
	AuditLogRetentionDays int `yaml:"audit_log_retention_days"`
}

type LoggingConfig struct {
	Level  string `yaml:"level"`
	Format string `yaml:"format"`
}

type RateCardEntry struct {
	PromptCreditsPerMtok         int64 `yaml:"prompt_credits_per_mtok"`
	PromptCacheHitCreditsPerMtok int64 `yaml:"prompt_cache_hit_credits_per_mtok"`
	CompletionCreditsPerMtok     int64 `yaml:"completion_credits_per_mtok"`

	promptCacheHitRateSet bool
}

func (e RateCardEntry) EffectivePromptCacheHitCreditsPerMtok() int64 {
	if e.promptCacheHitRateSet || e.PromptCacheHitCreditsPerMtok != 0 || e.PromptCreditsPerMtok == 0 {
		return e.PromptCacheHitCreditsPerMtok
	}
	return e.PromptCreditsPerMtok
}

func (e *RateCardEntry) SetPromptCacheHitCreditsPerMtok(v int64) {
	e.PromptCacheHitCreditsPerMtok = v
	e.promptCacheHitRateSet = true
}

func (e RateCardEntry) MarshalJSON() ([]byte, error) {
	return json.Marshal(struct {
		PromptRatePerMtok         int64 `json:"prompt_rate_per_mtok"`
		PromptCacheHitRatePerMtok int64 `json:"prompt_cache_hit_rate_per_mtok"`
		CompletionRatePerMtok     int64 `json:"completion_rate_per_mtok"`
	}{
		PromptRatePerMtok:         e.PromptCreditsPerMtok,
		PromptCacheHitRatePerMtok: e.EffectivePromptCacheHitCreditsPerMtok(),
		CompletionRatePerMtok:     e.CompletionCreditsPerMtok,
	})
}

func (e *RateCardEntry) UnmarshalJSON(data []byte) error {
	var raw struct {
		PromptCreditsPerMtok         *int64 `json:"PromptCreditsPerMtok"`
		PromptRatePerMtok            *int64 `json:"prompt_rate_per_mtok"`
		PromptCreditsPerMtokSnake    *int64 `json:"prompt_credits_per_mtok"`
		PromptCacheHitCreditsPerMtok *int64 `json:"PromptCacheHitCreditsPerMtok"`
		PromptCacheHitRatePerMtok    *int64 `json:"prompt_cache_hit_rate_per_mtok"`
		PromptCacheHitCreditsSnake   *int64 `json:"prompt_cache_hit_credits_per_mtok"`
		CompletionCreditsPerMtok     *int64 `json:"CompletionCreditsPerMtok"`
		CompletionRatePerMtok        *int64 `json:"completion_rate_per_mtok"`
		CompletionCreditsSnake       *int64 `json:"completion_credits_per_mtok"`
	}
	if err := json.Unmarshal(data, &raw); err != nil {
		return err
	}
	if raw.PromptRatePerMtok != nil {
		e.PromptCreditsPerMtok = *raw.PromptRatePerMtok
	} else if raw.PromptCreditsPerMtokSnake != nil {
		e.PromptCreditsPerMtok = *raw.PromptCreditsPerMtokSnake
	} else if raw.PromptCreditsPerMtok != nil {
		e.PromptCreditsPerMtok = *raw.PromptCreditsPerMtok
	}
	if raw.CompletionRatePerMtok != nil {
		e.CompletionCreditsPerMtok = *raw.CompletionRatePerMtok
	} else if raw.CompletionCreditsSnake != nil {
		e.CompletionCreditsPerMtok = *raw.CompletionCreditsSnake
	} else if raw.CompletionCreditsPerMtok != nil {
		e.CompletionCreditsPerMtok = *raw.CompletionCreditsPerMtok
	}
	switch {
	case raw.PromptCacheHitRatePerMtok != nil:
		e.PromptCacheHitCreditsPerMtok = *raw.PromptCacheHitRatePerMtok
		e.promptCacheHitRateSet = true
	case raw.PromptCacheHitCreditsSnake != nil:
		e.PromptCacheHitCreditsPerMtok = *raw.PromptCacheHitCreditsSnake
		e.promptCacheHitRateSet = true
	case raw.PromptCacheHitCreditsPerMtok != nil:
		e.PromptCacheHitCreditsPerMtok = *raw.PromptCacheHitCreditsPerMtok
		e.promptCacheHitRateSet = true
	default:
		e.PromptCacheHitCreditsPerMtok = e.PromptCreditsPerMtok
		e.promptCacheHitRateSet = false
	}
	return nil
}

func (e *RateCardEntry) UnmarshalYAML(value *yaml.Node) error {
	var raw struct {
		PromptCreditsPerMtok         int64  `yaml:"prompt_credits_per_mtok"`
		PromptCacheHitCreditsPerMtok *int64 `yaml:"prompt_cache_hit_credits_per_mtok"`
		CompletionCreditsPerMtok     int64  `yaml:"completion_credits_per_mtok"`
	}
	if err := value.Decode(&raw); err != nil {
		return err
	}
	e.PromptCreditsPerMtok = raw.PromptCreditsPerMtok
	e.CompletionCreditsPerMtok = raw.CompletionCreditsPerMtok
	if raw.PromptCacheHitCreditsPerMtok != nil {
		e.PromptCacheHitCreditsPerMtok = *raw.PromptCacheHitCreditsPerMtok
		e.promptCacheHitRateSet = true
	} else {
		e.PromptCacheHitCreditsPerMtok = raw.PromptCreditsPerMtok
		e.promptCacheHitRateSet = false
	}
	return nil
}

type RewardsConfig struct {
	GlobalMultiplier float64                  `yaml:"global_multiplier"`
	ProviderShare    float64                  `yaml:"provider_share"`
	RateCard         map[string]RateCardEntry `yaml:"rate_card"`
}

type SettlementConfig struct {
	CadenceDays                 int    `yaml:"cadence_days"`
	MinPayoutCredits            int64  `yaml:"min_payout_credits"`
	StartupReconcileWindowHours int    `yaml:"startup_reconcile_window_hours"`
	NightlyReconcileWindowDays  int    `yaml:"nightly_reconcile_window_days"`
	RecoveryGraceSeconds        int    `yaml:"recovery_grace_seconds"`
	PendingDeadlineSeconds      int    `yaml:"pending_deadline_seconds"`
	VerifiedModelSettlementMode string `yaml:"verified_model_settlement_mode"`
	JobEnabled                  bool   `yaml:"job_enabled"`
}

// BillingConfig is the SPEC-005 billing-side operator-toggleable surface.
type BillingConfig struct {
	// QuarantineResolutionForceVoidEnabled gates POST
	// /admin/ledger/quarantine/{id}/force-void (SPEC-005 v0.4
	// §11.6.1). Default false — the endpoint returns HTTP 404
	// `not_found` (route-layer gate per §11.5 launch-gate item
	// 10) until the operator explicitly flips this to true via
	// the existing config-reload primitive.
	QuarantineResolutionForceVoidEnabled bool `yaml:"quarantine_resolution_force_void_enabled"`
	// QuarantineResolutionForceCreditEnabled gates POST
	// /admin/ledger/quarantine/{id}/force-credit. Default false.
	QuarantineResolutionForceCreditEnabled bool `yaml:"quarantine_resolution_force_credit_enabled"`
	// ForceCreditSettlementHoldSeconds is the pre-payout hold for
	// force-credit resolutions. Zero means the SPEC-005 v0.5 default
	// of 24 hours.
	ForceCreditSettlementHoldSeconds int `yaml:"force_credit_settlement_hold_seconds"`
}

type EndpointsConfig struct {
	ProviderEarnings EndpointsProviderEarningsConfig `yaml:"provider_earnings"`
}

type EndpointsProviderEarningsConfig struct {
	RateLimitPerMinute int `yaml:"rate_limit_per_minute"`
}

type ExplorerConfig struct {
	Enabled                       bool   `yaml:"enabled"`
	BindPath                      string `yaml:"bind_path"`
	GatewayBaseURL                string `yaml:"gateway_base_url"`
	GatewayTimeoutMs              int    `yaml:"gateway_timeout_ms"`
	QueryTimeoutMs                int    `yaml:"query_timeout_ms"`
	PollMinIntervalSeconds        int    `yaml:"poll_min_interval_seconds"`
	ActivityMaxWindowDays         int    `yaml:"activity_max_window_days"`
	ActivityDefaultWindowHours    int    `yaml:"activity_default_window_hours"`
	BuyersMaxWindowDays           int    `yaml:"buyers_max_window_days"`
	BuyersDefaultWindowHours      int    `yaml:"buyers_default_window_hours"`
	LedgerMaxWindowDays           int    `yaml:"ledger_max_window_days"`
	LedgerDefaultWindowHours      int    `yaml:"ledger_default_window_hours"`
	SessionsMaxWindowDays         int    `yaml:"sessions_max_window_days"`
	SessionsDefaultWindowHours    int    `yaml:"sessions_default_window_hours"`
	SettlementsMaxWindowDays      int    `yaml:"settlements_max_window_days"`
	SettlementsDefaultWindowHours int    `yaml:"settlements_default_window_hours"`
	RequestsPerMinuteCap          int    `yaml:"requests_per_minute_cap"`
}

type ProviderConfig struct {
	ProviderID  string `yaml:"provider_id"`
	EndpointURL string `yaml:"endpoint_url"`
	DisplayName string `yaml:"display_name"`
}

func Default() Config {
	return Config{
		Listen: ListenConfig{
			BuyerPort:    8443,
			ProviderPort: 8444,
			BindAddress:  "127.0.0.1",
		},
		Coordinator: CoordinatorConfig{
			RequireGatewayContext: true,
		},
		Pool: PoolConfig{
			HeartbeatIntervalS:      30,
			DisconnectGracePeriodS:  30,
			HeartbeatMissThresholdS: 90,
			MaxConcurrencyCeiling:   8,
			WakeGapThresholdS:       120,
			WarmupFallbackS:         60,
			WarmupGateEnabled:       true,
			WarmupGateTimeoutS:      90,
			WarmupGateMaxTokens:     2,
			DegradedBackoffS:        30,
			DegradedMaxRetries:      3,
			DegradedProbeAfter502:   true,
			BreakerFailureThreshold: 2,
			BreakerWindowS:          120,
			CanaryEnabled:           false,
			CanaryIntervalS:         300,
			CanaryTimeoutS:          30,
			CanaryMaxTokens:         32,
			CanaryFailureThreshold:  3,
			LosslessnessProbe: LosslessnessProbeConfig{
				Enabled:                  false,
				IntervalS:                3600,
				TimeoutS:                 60,
				MaxConcurrentPerProvider: 1,
				MaxPromptsPerProbe:       4,
				MaxStochasticPositions:   8,
				ProfileFreshnessTTLHours: 24,
				EvidenceRetentionDays:    30,
				BackoffMaxS:              21600,
			},
		},
		Routing: RoutingConfig{
			PreflightThresholdTokens:      4096,
			PreflightTimeoutS:             5,
			RequestTimeoutS:               900,
			FailoverEnabled:               true,
			FailoverTimeoutS:              5,
			TiebreakRandomize:             false,
			TiebreakEpsilon:               0,
			MaxRetries:                    0,
			RetryPerAttemptTimeoutS:       60,
			MaxProvidersFaultedPerRequest: 0,
			StickyEnabled:                 false,
			StickyTTLS:                    1800,
			StickyMaxEntries:              10000,
			ModelClasses:                  map[string]ModelClassConfig{},
		},
		ProviderHTTP: ProviderHTTPConfig{
			TimeoutS: 900,
		},
		Limits: LimitsConfig{
			MaxChatRequestBodyBytes: 1 << 20,
		},
		WS: WSConfig{
			WriteBufferSize:             64,
			HandshakeTimeoutS:           10,
			WriteTimeoutS:               10,
			MaxFrameBytes:               4 << 20,
			MaxUnauthenticatedConn:      64,
			MaxUnauthenticatedConnPerIP: 4,
		},
		Relay: RelayConfig{
			MaxRequestBufferBytes: 16 * 1024 * 1024,
		},
		Admission: AdmissionConfig{
			PinnedOnly:                      false,
			ProvisionalAdmissionRatePerHour: 10,
			ProvisionalPoolMax:              100,
			ProvisionalQuotaPerHour:         100,
			ProvisionalTierWeight:           0.3,
			ProvisionalRetentionDays:        30,
		},
		ProofOfWeights: ProofOfWeightsConfig{
			RequireAutotuneHelloGate: false,
			AutotuneEvidenceTTLDays:  30,
			TelemetryDrift: TelemetryDriftConfig{
				Enabled:                  false,
				TPSRatioThreshold:        0.70,
				TPSMinAbsolute:           5.0,
				TPSMinRequestsWindow:     2,
				HashAlertOnStatus:        []string{"hash_mismatch", "hash_invalid"},
				HashAlertOnArtifactDrift: true,
				OPoIPassRateWindow:       10,
				OPoIPassRateThreshold:    0.80,
				AlertCooldownSeconds:     900,
			},
		},
		AutotuneFeeds: AutotuneFeedsConfig{
			// Strict is the durable safe default. Operators must opt into the
			// compatibility bridge with an explicit, near-term deadline.
			EnforceProviderAdmission: true,
		},
		Tier2: Tier2Config{
			SELivenessIntervalS:            300,
			SELivenessTimeoutS:             30,
			SELivenessMaxFailures:          3,
			ObserveEnabled:                 false,
			CatalogPath:                    "",
			CatalogPublicKey:               "",
			RequireHashVerified:            false,
			RequireEncryptedLeg:            false,
			EncryptedLegAEAD:               "A256GCM",
			EncryptedLegRekeyAfterRequests: 10000,
			EncryptedLegRekeyAfterSeconds:  3600,
			RequireAttestation:             false,
			AttestationRoots:               []string{},
			AttestationMaxAgeS:             600,
			AttestationFormats:             []string{"apple-managed-device-attestation-acme-v1", "macprovider-se-p256-v1"},
			AllowMockAttestation:           false,
			BehavioralSafetyEnabled:        false,
			OutputSizeCapBytes:             0,
			OutputBytesPerTokenCeiling:     16,
			DefaultOutputSizeCapBytes:      1048576,
			EncodingValidationEnabled:      false,
			ResponseTimeAnomalyEnabled:     false,
			ResponseTimeAnomalyFactor:      5.0,
			ResponseTimeAnomalyMinMS:       10000,
		},
		Storage: StorageConfig{
			DBPath:                  "coordinator.db",
			SnapshotIntervalS:       300,
			RequestLogRetentionDays: 90,
			AuditLogRetentionDays:   90,
		},
		Logging: LoggingConfig{
			Level:  "info",
			Format: "json",
		},
		Rewards: RewardsConfig{
			GlobalMultiplier: 1.0,
			ProviderShare:    0.90,
			RateCard: map[string]RateCardEntry{
				"default": {
					PromptCreditsPerMtok:         500000,
					PromptCacheHitCreditsPerMtok: 500000,
					CompletionCreditsPerMtok:     1000000,
				},
			},
		},
		Settlement: SettlementConfig{
			CadenceDays:                 7,
			MinPayoutCredits:            500000,
			StartupReconcileWindowHours: 24,
			NightlyReconcileWindowDays:  7,
			RecoveryGraceSeconds:        30,
			PendingDeadlineSeconds:      300,
			VerifiedModelSettlementMode: "observe",
			JobEnabled:                  true,
		},
		Endpoints: EndpointsConfig{
			ProviderEarnings: EndpointsProviderEarningsConfig{
				RateLimitPerMinute: 60,
			},
		},
		Stats: StatsConfig{
			Enabled: false,
			Rollup: StatsRollupConfig{
				BackfillMode:            "partial",
				LateEventsRetentionDays: 90,
				UsdPerMillionCredits:    1.0,
				DriftThresholdRatio:     0.005,
				NightlyRebuildHourUTC:   9,
				LateEventsLookbackHours: 48,
			},
			CORS: StatsCORSConfig{
				AccessControlMaxAgeSeconds: 60,
			},
			RateLimit: StatsRateLimitConfig{
				MaxBuckets:              100000,
				IdleTTLSeconds:          15 * 60,
				EvictionIntervalSeconds: 60,
				PreflightRPM:            10,
			},
			StreamingMetrics: StatsStreamingMetricsConfig{
				MaxSamples: 10000,
			},
			TrustedProxies: []string{"127.0.0.0/8", "::1/128"},
		},
		Onboarding: OnboardingConfig{
			AppTrackRegisterEnabled: false,
			BundleID:                "tech.malibu.app",
			CoordinatorDomain:       "coordinator.streamvc.live",
		},
		MalibuEmission: MalibuEmissionConfig{
			Enabled:                     false,
			TickIntervalSeconds:         900,
			ProviderDailyCapMALIBU:      25,
			WalletDailyCapMALIBU:        100,
			WalletMirrorIntervalSeconds: 300,
			UnlockEvalIntervalSeconds:   3600,
			MaxSerializableRetries:      5,
		},
		Explorer: ExplorerConfig{
			Enabled:                       false,
			BindPath:                      "/admin/explorer/",
			GatewayTimeoutMs:              1500,
			QueryTimeoutMs:                3000,
			PollMinIntervalSeconds:        5,
			ActivityMaxWindowDays:         7,
			ActivityDefaultWindowHours:    24,
			BuyersMaxWindowDays:           31,
			BuyersDefaultWindowHours:      168,
			LedgerMaxWindowDays:           31,
			LedgerDefaultWindowHours:      168,
			SessionsMaxWindowDays:         7,
			SessionsDefaultWindowHours:    24,
			SettlementsMaxWindowDays:      180,
			SettlementsDefaultWindowHours: 720,
			RequestsPerMinuteCap:          60,
		},
		Auth: AuthConfig{
			RequireProviderTokens:                 true,
			CredentialBootstrapMintsPerIPHour:     8,
			CredentialBootstrapMintsPerIDHour:     3,
			CredentialBootstrapMintsGlobalHour:    128,
			CredentialBootstrapUnconfirmedMax:     64,
			CredentialBootstrapOutstandingMax:     64,
			CredentialBootstrapTokenTTLS:          600,
			CredentialBootstrapIdentityRetentionS: 604800,
		},
		Referrals: ReferralConfig{
			ProviderBaseUses:         1,
			SocialBonusUses:          2,
			ChallengeTTLS:            900,
			SocialVerificationDwellS: 1800,
			JoinBaseURL:              "https://malibu.tech/j",
			PolicyVersion:            "v1",
			HMACKeys:                 map[string]string{},
		},
		Proxy: ProxyConfig{
			// Default trusts loopback only. Production sits behind nginx on
			// localhost, so the default keys rate-limit buckets on the
			// X-Real-IP / X-Forwarded-For headers nginx sets. Operators with
			// a remote LB MUST add the proxy CIDR(s) explicitly; spoofing
			// risk if anything else is added. Issue #125.
			TrustedProxies: []string{"127.0.0.0/8", "::1/128"},
		},
		Payout: PayoutConfig{
			Enabled: false,
			Security: PayoutSecurityConfig{
				PerPayoutCapUSDCBaseUnits:        500_000_000,   // $500
				PerDayCapUSDCBaseUnits:           5_000_000_000, // $5,000
				CancelMaxTipMultiplier:           5.0,
				CancelMaxGasNativeWei:            10_000_000_000_000_000, // 0.01 ETH (1e16)
				CancelMaxGasNativeWeiPer24h:      50_000_000_000_000_000, // 0.05 ETH (5e16)
				AbandonRatePerHour:               3,
				ChainReconInterval:               time.Hour,
				ChainReconToleranceUSDCBaseUnits: 100_000, // $0.10
				PauseResumeMinInterval:           60 * time.Second,
			},
			Tuning: PayoutTuningConfig{
				AddressCoolingOffPeriod: 24 * time.Hour,
				RunInterval:             6 * time.Hour,
				RunNowMinInterval:       60 * time.Second,
				ConfirmationBlocks:      5,
				MaxRowsPerRun:           50,
				ReorgPollWindow:         24 * time.Hour,
			},
		},
	}
}

func Load(path string) (Config, error) {
	return LoadWithOverlay(path, "")
}

// LoadWithOverlay reads basePath into defaults, then merges overlayPath when
// non-empty (overlay keys override). Used for OPoI v0 staging overlays without
// editing production coordinator.yaml.
func LoadWithOverlay(basePath, overlayPath string) (Config, error) {
	cfg := Default()
	if err := unmarshalYAMLFile(basePath, &cfg); err != nil {
		return Config{}, fmt.Errorf("base config %s: %w", basePath, err)
	}
	if strings.TrimSpace(overlayPath) != "" {
		if err := unmarshalYAMLFile(overlayPath, &cfg); err != nil {
			return Config{}, fmt.Errorf("overlay config %s: %w", overlayPath, err)
		}
	}
	if err := finalizeLoadedConfig(&cfg); err != nil {
		return Config{}, err
	}
	return cfg, nil
}

// payoutTuningOnlyWrapper is a minimal YAML envelope that surfaces
// only the payout.tuning.* namespace. Used by LoadPayoutTuningOnly
// so SIGHUP parsing cannot accidentally read or validate payout.security.*.
type payoutTuningOnlyWrapper struct {
	Payout struct {
		Tuning PayoutTuningConfig `yaml:"tuning"`
	} `yaml:"payout"`
}

// LoadPayoutTuningOnly parses ONLY the `payout.tuning.*` keys from
// the YAML at basePath — merged with overlayPath when non-empty, with
// the same overlay-keys-override semantics as LoadWithOverlay — and
// returns the validated snapshot. It intentionally does NOT read
// `payout.security.*`, does NOT call resolveEnv on any other field,
// and does NOT run full Config.Validate.
//
// Merge-audit 2026-07-30 (convergent code+security HIGH): the SIGHUP
// path MUST read the same effective base+overlay source as startup's
// LoadWithOverlay. The shipped systemd unit passes --config-overlay;
// reading only the base file here would let a SIGHUP silently revert
// overlay-sourced tuning — including clearing non-empty SPKI pins,
// which validate as empty and would drop RPC certificate pinning on
// the payout money path.
//
// Step 4 r1 [code:r1-3] MEDIUM closure: the SIGHUP loader MUST NOT
// couple tuning-reload success to immutable security fields. Callers
// that need the full config should use Load instead.
//
// Bound enforcement mirrors the §6.5 sub-set that applies to the
// tuning namespace only. The per_day_cap cross-check on
// low_balance_threshold is skipped because the security config is
// deliberately not loaded here; the bound is enforced by Validate at
// startup. On SIGHUP, TuningProvider.Reload applies its own in-memory
// cap check using the startup PerDayCapUSDCBaseUnits.
func LoadPayoutTuningOnly(basePath, overlayPath string) (PayoutTuningConfig, error) {
	b, err := os.ReadFile(basePath)
	if err != nil {
		return PayoutTuningConfig{}, err
	}
	// Start from defaults so missing keys inherit the startup values.
	defaults := Default()
	wrapper := payoutTuningOnlyWrapper{}
	wrapper.Payout.Tuning = defaults.Payout.Tuning
	if err := yaml.Unmarshal(b, &wrapper); err != nil {
		return PayoutTuningConfig{}, err
	}
	if strings.TrimSpace(overlayPath) != "" {
		ob, err := os.ReadFile(overlayPath)
		if err != nil {
			return PayoutTuningConfig{}, fmt.Errorf("overlay config %s: %w", overlayPath, err)
		}
		// Unmarshal into the SAME wrapper: keys present in the overlay
		// override; keys absent inherit base (mirrors LoadWithOverlay).
		if err := yaml.Unmarshal(ob, &wrapper); err != nil {
			return PayoutTuningConfig{}, fmt.Errorf("overlay config %s: %w", overlayPath, err)
		}
	}
	t := wrapper.Payout.Tuning
	// §6.5 tuning-namespace bound matrix — same as Validate's payout.tuning.* block.
	if t.AddressCoolingOffPeriod < time.Hour {
		return PayoutTuningConfig{}, fmt.Errorf("payout.tuning.address_cooling_off_period must be >= 1h (SPEC-016 §3.1)")
	}
	if t.RunInterval < 5*time.Minute || t.RunInterval > 24*time.Hour {
		return PayoutTuningConfig{}, fmt.Errorf("payout.tuning.run_interval must be in [5m, 24h] (SPEC-016 §6.5)")
	}
	if t.RunNowMinInterval < 10*time.Second || t.RunNowMinInterval > time.Hour {
		return PayoutTuningConfig{}, fmt.Errorf("payout.tuning.run_now_min_interval must be in [10s, 1h] (SPEC-016 §6.5)")
	}
	if t.ConfirmationBlocks < 5 || t.ConfirmationBlocks > 200 {
		return PayoutTuningConfig{}, fmt.Errorf("payout.tuning.confirmation_blocks must be in [5, 200] (SPEC-016 §6.5)")
	}
	if t.MaxRowsPerRun < 1 || t.MaxRowsPerRun > 500 {
		return PayoutTuningConfig{}, fmt.Errorf("payout.tuning.max_rows_per_run must be in [1, 500] (SPEC-016 §6.5)")
	}
	if t.ReorgPollWindow < time.Hour || t.ReorgPollWindow > 168*time.Hour {
		return PayoutTuningConfig{}, fmt.Errorf("payout.tuning.reorg_poll_window must be in [1h, 168h] (SPEC-016 §6.5)")
	}
	if t.LowBalanceThreshold < 0 {
		return PayoutTuningConfig{}, fmt.Errorf("payout.tuning.low_balance_threshold must be >= 0")
	}
	if t.LowNativeThreshold < 0 || t.LowNativeThreshold > 1_000_000_000_000_000_000 {
		return PayoutTuningConfig{}, fmt.Errorf("payout.tuning.low_native_threshold must be in [0, 1e18] (SPEC-016 §6.5)")
	}
	if err := validateSPKIPin(t.RPCURLPrimaryPinSPKI, "payout.tuning.rpc_url_primary_pin_spki"); err != nil {
		return PayoutTuningConfig{}, err
	}
	if err := validateSPKIPin(t.RPCURLSecondaryPinSPKI, "payout.tuning.rpc_url_secondary_pin_spki"); err != nil {
		return PayoutTuningConfig{}, err
	}
	return t, nil
}

// LoadForSIGHUPReload reads the config for the GENERAL coordinator
// SIGHUP reload path (tier2 / billing / proof-of-weights consumers in
// reloadCoordinatorConfig). Identical to Load EXCEPT the payout.*
// namespace is reset to defaults (enabled=false) after unmarshal and
// before env resolution + validation, so on SIGHUP:
//   - payout.security.* env: sentinels are never resolved (SPEC-016
//     v0.1.23 §6.5: the security namespace is startup-immutable and
//     MUST NOT be parsed on any SIGHUP path; the dedicated payout
//     listener uses LoadPayoutTuningOnly), and
//   - a payout.* key edited invalidly on disk cannot reject an
//     otherwise-valid tier2/billing reload (no cross-namespace
//     reload-success coupling — merge-audit 2026-07-30 architect HIGH).
//
// Safe because the general reload path never applies payout fields:
// the payout runtime consumes config only via its startup snapshot
// plus the §6.5 tuning-only SIGHUP listener.
func LoadForSIGHUPReload(path string) (Config, error) {
	b, err := os.ReadFile(path)
	if err != nil {
		return Config{}, fmt.Errorf("base config %s: %w", path, err)
	}
	// Merge-audit r2 (convergent code+architect HIGH): strip the payout
	// subtree BEFORE typed decode. Resetting cfg.Payout after a typed
	// unmarshal is not enough — a type-malformed payout.* scalar (e.g. a
	// non-numeric cancel_max_tip_multiplier) would fail the Config decode
	// itself and reject the whole reload before any reset runs.
	//
	// Merge-audit r3 (code HIGH): the strip must happen at the yaml.Node
	// level, NOT via a map[string]interface{} decode + re-marshal — that
	// round-trip resolves unquoted timestamp-like scalars (2026-07-19)
	// into time.Time and re-emits them RFC3339-normalized, so the reload
	// would ACCEPT deadline strings (tier2.model_hash_legacy_until,
	// referrals.grandfather_before) that startup Load rejects. Removing
	// the payout mapping entry from the parsed node tree leaves every
	// other scalar byte-identical to what Load would see.
	var doc yaml.Node
	if err := yaml.Unmarshal(b, &doc); err != nil {
		return Config{}, fmt.Errorf("base config %s: %w", path, err)
	}
	if len(doc.Content) > 0 && doc.Content[0].Kind == yaml.MappingNode {
		m := doc.Content[0]
		// Merge-audit r4 (code HIGH): strip EVERY top-level payout entry —
		// YAML permits duplicate keys at this layer, and a second payout
		// block would otherwise reach typed decode.
		kept := make([]*yaml.Node, 0, len(m.Content))
		for i := 0; i+1 < len(m.Content); i += 2 {
			if m.Content[i].Value == "payout" {
				continue
			}
			kept = append(kept, m.Content[i], m.Content[i+1])
		}
		m.Content = kept
	}
	cfg := Default()
	if len(doc.Content) > 0 {
		if err := doc.Decode(&cfg); err != nil {
			return Config{}, fmt.Errorf("base config %s: %w", path, err)
		}
	}
	// Belt-and-braces: the payout namespace stays at defaults regardless
	// of what the document contained.
	cfg.Payout = Default().Payout
	if err := finalizeLoadedConfig(&cfg); err != nil {
		return Config{}, err
	}
	return cfg, nil
}

func unmarshalYAMLFile(path string, cfg *Config) error {
	b, err := os.ReadFile(path)
	if err != nil {
		return err
	}
	return yaml.Unmarshal(b, cfg)
}

func finalizeLoadedConfig(cfg *Config) error {
	if err := cfg.resolveEnv(); err != nil {
		return err
	}
	if err := cfg.Validate(); err != nil {
		return err
	}
	if err := validateOperatorSecretStrength("auth.operator_key", cfg.Auth.OperatorKey); err != nil {
		return err
	}
	for name, key := range cfg.Auth.OperatorKeys {
		if err := validateOperatorSecretStrength("auth.operator_keys."+name, key); err != nil {
			return err
		}
	}
	return nil
}

// resolveEnv expands "env:NAME" sentinels in secret-bearing fields by
// reading the named environment variable. Mirrors the gateway-side
// resolver (M3-2 / DEVE-7) but is intentionally duplicated to avoid a
// cross-module import; the audit recorded "intentional duplication" as
// the house pattern for config plumbing.
//
// FAIL-CLOSED contract: when the YAML uses an env: sentinel and the
// referenced variable is unset OR empty, Load returns an error. Silent
// fall-through to "" would let the coordinator boot with an empty
// operator_key in places where Validate's "must be set" guard does not
// catch the substitution (e.g. future fields added to this resolver).
func (c *Config) resolveEnv() error {
	if v, err := resolveEnvValue("auth.operator_key", c.Auth.OperatorKey); err != nil {
		return err
	} else {
		c.Auth.OperatorKey = v
	}
	if v, err := resolveEnvValue("auth.gateway_service_token", c.Auth.GatewayServiceToken); err != nil {
		return err
	} else {
		c.Auth.GatewayServiceToken = v
	}
	for name, raw := range c.Auth.OperatorKeys {
		v, err := resolveEnvValue("auth.operator_keys."+name, raw)
		if err != nil {
			return err
		}
		c.Auth.OperatorKeys[name] = v
	}
	for keyID, raw := range c.Referrals.HMACKeys {
		v, err := resolveEnvValue("referrals.hmac_keys."+keyID, raw)
		if err != nil {
			return err
		}
		c.Referrals.HMACKeys[keyID] = v
	}
	if v, err := resolveEnvValue("referrals.x_api_bearer_token", c.Referrals.XAPIBearerToken); err != nil {
		return err
	} else {
		c.Referrals.XAPIBearerToken = v
	}
	if v, err := resolveEnvValue("tier2.model_hash_legacy_until", c.Tier2.ModelHashLegacyUntil); err != nil {
		return err
	} else {
		c.Tier2.ModelHashLegacyUntil = v
	}
	// Round-1 SECURITY r1 MEDIUM 1: stats DSN fields go through
	// the same env-indirection resolver. Operators inject DSNs
	// at deploy time as `env:STATS_READER_DSN` etc.; storing
	// plaintext DSNs in coordinator.yaml is a SECURITY footgun.
	statsDSNs := []struct {
		field string
		dst   *string
	}{
		{"stats.reader_dsn", &c.Stats.ReaderDSN},
		{"stats.rollup_dsn", &c.Stats.RollupDSN},
		{"stats.provider_portal_dsn", &c.Stats.ProviderPortalDSN},
		{"stats.partner_keys.writer_dsn", &c.Stats.PartnerKeys.WriterDSN},
		{"stats.partner_keys_admin_dsn", &c.Stats.PartnerKeysAdminDSN},
		{"malibu_emission.writer_dsn", &c.MalibuEmission.WriterDSN},
	}
	for _, f := range statsDSNs {
		v, err := resolveEnvValue(f.field, *f.dst)
		if err != nil {
			return err
		}
		*f.dst = v
	}
	onboardingSecrets := []struct {
		field string
		dst   *string
	}{
		{"onboarding.postgres_dsn", &c.Onboarding.PostgresDSN},
		{"onboarding.auth_policy_request_dsn", &c.Onboarding.AuthPolicyRequestDSN},
		{"onboarding.auth_policy_approve_dsn", &c.Onboarding.AuthPolicyApproveDSN},
		{"onboarding.auth_policy_cutover_dsn", &c.Onboarding.AuthPolicyCutoverDSN},
		{"onboarding.hardware_trust_request_dsn", &c.Onboarding.HardwareTrustRequestDSN},
		{"onboarding.hardware_trust_approve_dsn", &c.Onboarding.HardwareTrustApproveDSN},
		{"onboarding.apple_team_id", &c.Onboarding.AppleTeamID},
	}
	for _, f := range onboardingSecrets {
		v, err := resolveEnvValue(f.field, *f.dst)
		if err != nil {
			return err
		}
		*f.dst = v
	}
	if raw, ok := os.LookupEnv("GITHUB_OAUTH_ENABLED"); ok {
		switch raw {
		case "true":
			c.Auth.GitHubOAuth.Enabled = true
		case "false":
			c.Auth.GitHubOAuth.Enabled = false
		default:
			return fmt.Errorf("GITHUB_OAUTH_ENABLED must be \"true\" or \"false\"")
		}
	}
	if c.Auth.GitHubOAuth.Enabled {
		if v := strings.TrimSpace(os.Getenv("GITHUB_OAUTH_CLIENT_ID")); v != "" {
			c.Auth.GitHubOAuth.ClientID = v
		}
		if v := strings.TrimSpace(os.Getenv("GITHUB_OAUTH_CLIENT_SECRET")); v != "" {
			c.Auth.GitHubOAuth.ClientSecret = v
		}
		if v := strings.TrimSpace(os.Getenv("GITHUB_OAUTH_REDIRECT_URI")); v != "" {
			c.Auth.GitHubOAuth.RedirectURI = v
		}
		if v := strings.TrimSpace(os.Getenv("PORTAL_BASE_URL")); v != "" {
			c.Auth.GitHubOAuth.PortalBaseURL = strings.TrimRight(v, "/")
		}
		if v := strings.TrimSpace(os.Getenv("MP_SESSION_COOKIE_DOMAIN")); v != "" {
			c.Auth.GitHubOAuth.SessionCookieDomain = v
		}
	}
	// Step 4 r1 [sec:r1-4] MEDIUM closure: payout.security.* string
	// fields must honor the env:NAME indirection rule. The deploy gate
	// already validates env: presence; without this resolver the
	// coordinator boots with literal "env:..." RPC/wallet strings.
	if c.Payout.Enabled {
		if v, err := resolveEnvValue("payout.security.rpc_url_primary", c.Payout.Security.RPCURLPrimary); err != nil {
			return err
		} else {
			c.Payout.Security.RPCURLPrimary = v
		}
		if v, err := resolveEnvValue("payout.security.rpc_url_secondary", c.Payout.Security.RPCURLSecondary); err != nil {
			return err
		} else {
			c.Payout.Security.RPCURLSecondary = v
		}
		if v, err := resolveEnvValue("payout.security.hot_wallet_address", c.Payout.Security.HotWalletAddress); err != nil {
			return err
		} else {
			c.Payout.Security.HotWalletAddress = v
		}
		if v, err := resolveEnvValue("payout.security.encrypted_wallet_path", c.Payout.Security.EncryptedWalletPath); err != nil {
			return err
		} else {
			c.Payout.Security.EncryptedWalletPath = v
		}
	}
	return nil
}

func resolveEnvValue(field, v string) (string, error) {
	if !strings.HasPrefix(v, "env:") {
		return v, nil
	}
	name := strings.TrimPrefix(v, "env:")
	resolved := os.Getenv(name)
	if resolved == "" {
		return "", fmt.Errorf("%s references env:%s but the environment variable is unset or empty", field, name)
	}
	return resolved, nil
}

var weakOperatorKeyDenylist = map[string]struct{}{
	"":            {},
	"changeme":    {},
	"placeholder": {},
	"test":        {},
	"secret":      {},
	"password":    {},
	"admin":       {},
}

func validateOperatorSecretStrength(field, key string) error {
	trimmed := strings.TrimSpace(key)
	if _, denied := weakOperatorKeyDenylist[strings.ToLower(trimmed)]; denied {
		return fmt.Errorf("%s strength check failed: placeholder_denied", field)
	}
	if len([]byte(trimmed)) < 32 {
		return fmt.Errorf("%s strength check failed: too_short (minimum 32 bytes)", field)
	}
	allZero := true
	for _, b := range []byte(trimmed) {
		if b != 0 && b != '0' {
			allZero = false
			break
		}
	}
	if allZero {
		return fmt.Errorf("%s strength check failed: repeated_zero", field)
	}
	if entropyBitsPerByte(trimmed) < 3.5 {
		return fmt.Errorf("%s strength check failed: low_entropy", field)
	}
	return nil
}

func entropyBitsPerByte(s string) float64 {
	data := []byte(s)
	if len(data) == 0 {
		return 0
	}
	counts := make(map[byte]int, len(data))
	for _, b := range data {
		counts[b]++
	}
	var entropy float64
	n := float64(len(data))
	for _, count := range counts {
		p := float64(count) / n
		entropy -= p * math.Log2(p)
	}
	return entropy
}

func (c Config) HeartbeatInterval() time.Duration {
	seconds := c.Pool.HeartbeatIntervalS
	if seconds <= 0 {
		seconds = Default().Pool.HeartbeatIntervalS
	}
	return time.Duration(seconds) * time.Second
}

func (c Config) FailoverTimeout() time.Duration {
	seconds := c.Routing.FailoverTimeoutS
	if seconds <= 0 {
		seconds = Default().Routing.FailoverTimeoutS
	}
	return time.Duration(seconds) * time.Second
}

// HeartbeatMissThreshold is how long a provider may go without any inbound
// frame before the liveness monitor closes its WebSocket. See PoolConfig.
func (c Config) HeartbeatMissThreshold() time.Duration {
	seconds := c.Pool.HeartbeatMissThresholdS
	if seconds <= 0 {
		seconds = Default().Pool.HeartbeatMissThresholdS
	}
	return time.Duration(seconds) * time.Second
}

func (c Config) ProviderWSHandshakeTimeout() time.Duration {
	seconds := c.WS.HandshakeTimeoutS
	if seconds <= 0 {
		seconds = Default().WS.HandshakeTimeoutS
	}
	return time.Duration(seconds) * time.Second
}

func (c Config) ProviderWSWriteTimeout() time.Duration {
	seconds := c.WS.WriteTimeoutS
	if seconds <= 0 {
		seconds = Default().WS.WriteTimeoutS
	}
	return time.Duration(seconds) * time.Second
}

func (c Config) ProviderWSMaxFrameBytes() int64 {
	bytes := c.WS.MaxFrameBytes
	if bytes <= 0 {
		bytes = Default().WS.MaxFrameBytes
	}
	return bytes
}

func (c Config) ProviderWSMaxUnauthenticatedConn() int {
	count := c.WS.MaxUnauthenticatedConn
	if count <= 0 {
		count = Default().WS.MaxUnauthenticatedConn
	}
	return count
}

func (c Config) ProviderWSMaxUnauthenticatedConnPerIP() int {
	count := c.WS.MaxUnauthenticatedConnPerIP
	if count <= 0 {
		count = Default().WS.MaxUnauthenticatedConnPerIP
	}
	return count
}

func (c Config) RelayMaxRequestBufferBytes() int64 {
	bytes := c.Relay.MaxRequestBufferBytes
	if bytes <= 0 {
		bytes = Default().Relay.MaxRequestBufferBytes
	}
	return bytes
}

// TrustedProxyPrefixes parses c.Proxy.TrustedProxies into a slice of
// netip.Prefix values for the buyer Server's rate-limit-key derivation.
// Returns an error if any CIDR is malformed OR if the operator has
// listed a default-route prefix (0.0.0.0/0, ::/0); those would let
// every public caller spoof their bucket key via X-Forwarded-For —
// almost certainly a config bug, never a deliberate posture, so
// reject at Validate time. Issue #125 security-lane finding.
//
// Callers should invoke this at startup (config.Load already calls
// it via Validate) so the hot path never re-parses. An empty
// TrustedProxies list returns a nil slice (callers treat as "no
// proxy is trusted; always use r.RemoteAddr").
func (c Config) TrustedProxyPrefixes() ([]netip.Prefix, error) {
	if len(c.Proxy.TrustedProxies) == 0 {
		return nil, nil
	}
	out := make([]netip.Prefix, 0, len(c.Proxy.TrustedProxies))
	for _, raw := range c.Proxy.TrustedProxies {
		trimmed := strings.TrimSpace(raw)
		if trimmed == "" {
			continue
		}
		p, err := netip.ParsePrefix(trimmed)
		if err != nil {
			return nil, fmt.Errorf("proxy.trusted_proxies[%q]: %w", raw, err)
		}
		// Reject default-route prefixes — trusting every IP means
		// every caller can spoof their bucket key. Issue #125
		// security-lane L2.
		if p.Bits() == 0 {
			return nil, fmt.Errorf("proxy.trusted_proxies[%q]: default-route prefix is not a valid trusted proxy (every caller would be header-trusted)", raw)
		}
		out = append(out, p)
	}
	return out, nil
}

func (c Config) StatsTrustedProxyPrefixes() ([]netip.Prefix, error) {
	return parseTrustedProxyCIDRs("stats.trusted_proxies", c.Stats.TrustedProxies)
}

func parseTrustedProxyCIDRs(name string, cidrs []string) ([]netip.Prefix, error) {
	if len(cidrs) == 0 {
		return nil, nil
	}
	out := make([]netip.Prefix, 0, len(cidrs))
	for _, raw := range cidrs {
		trimmed := strings.TrimSpace(raw)
		if trimmed == "" {
			continue
		}
		p, err := netip.ParsePrefix(trimmed)
		if err != nil {
			return nil, fmt.Errorf("%s[%q]: %w", name, raw, err)
		}
		if p.Bits() == 0 {
			return nil, fmt.Errorf("%s[%q]: default-route prefix is not a valid trusted proxy (every caller would be header-trusted)", name, raw)
		}
		out = append(out, p)
	}
	return out, nil
}

func (c Config) ProviderByID() map[string]ProviderConfig {
	out := make(map[string]ProviderConfig, len(c.Providers))
	for _, p := range c.Providers {
		out[p.ProviderID] = p
	}
	return out
}

func (c Config) Validate() error {
	if c.Auth.OperatorKey == "" {
		return fmt.Errorf("auth.operator_key must be set")
	}
	// After PR #172 (issue #87 item 3), the legacy
	// operator_key fallback on /internal/* is gone, so the coordinator
	// MUST have a distinct gateway_service_token or every /internal/*
	// gateway call fails 401.
	serviceToken := strings.TrimSpace(c.Auth.GatewayServiceToken)
	if serviceToken == "" {
		return fmt.Errorf("auth.gateway_service_token must be set (post-M3-2 cutover: required for /internal/* gateway auth)")
	}
	// Compare after TrimSpace: auth.BearerTokenMatchesHeader trims both
	// sides before matching, so "X" and "X " (or "X\n") collapse to the
	// same value at runtime. A strict == on the raw fields would let an
	// operator pass distinctness while still effectively reusing the
	// operator credential on /internal/*.
	if serviceToken == strings.TrimSpace(c.Auth.OperatorKey) {
		return fmt.Errorf("auth.gateway_service_token must differ from auth.operator_key (rotation discipline: equal values — including whitespace-equivalent — defeat the operator-vs-service credential split)")
	}
	for name, operatorKey := range c.Auth.OperatorKeys {
		if serviceToken == strings.TrimSpace(operatorKey) {
			return fmt.Errorf("auth.gateway_service_token must differ from auth.operator_keys.%s (service credentials must not grant a named operator identity)", name)
		}
	}
	if err := c.validateCompatibilitySet(); err != nil {
		return err
	}
	if err := c.validateAdvertisedVersions(); err != nil {
		return err
	}
	if _, err := c.TrustedProxyPrefixes(); err != nil {
		return err
	}
	if err := c.validateGitHubOAuth(); err != nil {
		return err
	}
	if c.Auth.CredentialBootstrapMintsPerIPHour <= 0 || c.Auth.CredentialBootstrapMintsPerIDHour <= 0 ||
		c.Auth.CredentialBootstrapMintsGlobalHour <= 0 || c.Auth.CredentialBootstrapUnconfirmedMax <= 0 ||
		c.Auth.CredentialBootstrapOutstandingMax <= 0 || c.Auth.CredentialBootstrapTokenTTLS <= 0 ||
		c.Auth.CredentialBootstrapIdentityRetentionS <= 0 {
		return fmt.Errorf("auth credential-bootstrap mint limits, outstanding max, token ttl, and identity retention must be > 0")
	}
	if c.Auth.CredentialBootstrapIdentityRetentionS <= c.Auth.CredentialBootstrapTokenTTLS {
		return fmt.Errorf("auth.credential_bootstrap_identity_retention_s must exceed auth.credential_bootstrap_token_ttl_s")
	}
	if err := c.validateReferrals(); err != nil {
		return err
	}
	if c.WS.WriteBufferSize <= 0 {
		return fmt.Errorf("ws.write_buffer_size must be > 0")
	}
	if c.WS.HandshakeTimeoutS <= 0 || c.WS.WriteTimeoutS <= 0 || c.WS.MaxFrameBytes <= 0 || c.WS.MaxUnauthenticatedConn <= 0 {
		return fmt.Errorf("ws handshake, write, frame, and unauthenticated connection limits must be > 0")
	}
	if c.WS.MaxUnauthenticatedConnPerIP <= 0 {
		return fmt.Errorf("ws.max_unauthenticated_conn_per_ip must be > 0")
	}
	if c.WS.MaxFrameBytes > 64<<20 {
		return fmt.Errorf("ws.max_frame_bytes must be <= 67108864")
	}
	if c.Relay.MaxRequestBufferBytes <= 0 {
		return fmt.Errorf("relay.max_request_buffer_bytes must be > 0")
	}
	if c.Relay.MaxRequestBufferBytes > 128<<20 {
		return fmt.Errorf("relay.max_request_buffer_bytes must be <= 134217728")
	}
	if c.Routing.PreflightTimeoutS <= 0 || c.Routing.RequestTimeoutS <= 0 || c.Routing.FailoverTimeoutS <= 0 {
		return fmt.Errorf("routing timeouts must be > 0")
	}
	if c.Routing.TiebreakEpsilon < 0 {
		return fmt.Errorf("routing.tiebreak_epsilon must be >= 0")
	}
	if c.Routing.MaxRetries < 0 {
		return fmt.Errorf("routing.max_retries must be >= 0")
	}
	if c.Routing.RetryPerAttemptTimeoutS <= 0 {
		return fmt.Errorf("routing.retry_per_attempt_timeout_s must be > 0")
	}
	if c.Routing.MaxProvidersFaultedPerRequest < 0 {
		return fmt.Errorf("routing.max_providers_faulted_per_request must be >= 0")
	}
	if c.Routing.StickyTTLS <= 0 || c.Routing.StickyMaxEntries <= 0 {
		return fmt.Errorf("routing sticky settings must be > 0")
	}
	if c.ProviderHTTP.TimeoutS <= 0 {
		return fmt.Errorf("provider_http.timeout_s must be > 0")
	}
	if c.Limits.MaxChatRequestBodyBytes <= 0 {
		return fmt.Errorf("limits.max_chat_request_body_bytes must be > 0")
	}
	if c.Limits.MaxChatRequestBodyBytes > 128<<20 {
		return fmt.Errorf("limits.max_chat_request_body_bytes must be <= 128 MiB")
	}
	for name, class := range c.Routing.ModelClasses {
		if name == "" {
			return fmt.Errorf("routing.model_classes name must not be empty")
		}
		switch class.Objective {
		case "fast", "balanced", "accurate":
		default:
			return fmt.Errorf("routing.model_classes.%s.objective must be fast, balanced, or accurate", name)
		}
		if len(class.Members) == 0 && len(class.Models) == 0 {
			return fmt.Errorf("routing.model_classes.%s.models must not be empty", name)
		}
		if len(class.Members) > 0 && len(class.Models) > 0 {
			return fmt.Errorf("routing.model_classes.%s must not set both members and models", name)
		}
	}
	if c.Pool.DegradedBackoffS <= 0 || c.Pool.DegradedMaxRetries <= 0 {
		return fmt.Errorf("pool degraded recovery settings must be > 0")
	}
	if c.Pool.WarmupFallbackS <= 0 {
		return fmt.Errorf("pool warmup_fallback_s must be > 0")
	}
	// 0 is the explicit "no ceiling" escape hatch (pre-clamp behavior);
	// negatives are always an operator typo.
	if c.Pool.MaxConcurrencyCeiling < 0 {
		return fmt.Errorf("pool.max_concurrency_ceiling must be >= 0 (0 disables the clamp)")
	}
	if c.Pool.WarmupGateEnabled && (c.Pool.WarmupGateTimeoutS <= 0 || c.Pool.WarmupGateMaxTokens <= 0) {
		return fmt.Errorf("pool warmup gate settings must be > 0 when enabled")
	}
	if c.Pool.BreakerFailureThreshold <= 0 || c.Pool.BreakerWindowS <= 0 {
		return fmt.Errorf("pool breaker settings must be > 0")
	}
	if c.Pool.CanaryEnabled && (c.Pool.CanaryIntervalS <= 0 || c.Pool.CanaryTimeoutS <= 0 || c.Pool.CanaryMaxTokens <= 0 || c.Pool.CanaryFailureThreshold <= 0) {
		return fmt.Errorf("pool canary settings must be > 0 when enabled")
	}
	if c.Pool.CanaryColdStartGraceS < 0 {
		return fmt.Errorf("pool canary_cold_start_grace_s must be >= 0")
	}
	switch strings.ToLower(strings.TrimSpace(c.Pool.CanaryLatencyEnforcement)) {
	case "", "observe", "enforce":
	default:
		return fmt.Errorf("pool canary_latency_enforcement must be \"observe\" or \"enforce\"")
	}
	if c.Pool.CanaryEnabled {
		if len(c.Pool.CanaryChallenges) == 0 && len(c.Pool.ModelClassChallenges) == 0 {
			return fmt.Errorf("pool canary_challenges or model_class_challenges must not be empty when enabled")
		}
		if err := validateCanaryChallengeList("pool.canary_challenges", c.Pool.CanaryChallenges); err != nil {
			return err
		}
		for modelID, challenges := range c.Pool.ModelClassChallenges {
			if strings.TrimSpace(modelID) == "" {
				return fmt.Errorf("pool.model_class_challenges model id must not be empty")
			}
			if err := validateCanaryChallengeList("pool.model_class_challenges."+modelID, challenges); err != nil {
				return err
			}
		}
	}
	if c.Pool.LosslessnessProbe.Enabled {
		lp := c.Pool.LosslessnessProbe
		if lp.IntervalS != 3600 || lp.TimeoutS != 60 || lp.MaxConcurrentPerProvider != 1 ||
			lp.MaxPromptsPerProbe <= 0 || lp.MaxPromptsPerProbe > 4 ||
			lp.MaxStochasticPositions <= 0 || lp.MaxStochasticPositions > 8 ||
			lp.ProfileFreshnessTTLHours != 24 || lp.EvidenceRetentionDays != 30 ||
			lp.BackoffMaxS <= 0 || lp.BackoffMaxS > 21600 {
			return fmt.Errorf("pool.losslessness_probe settings violate SPEC-029 v0.1-draft prototype bounds")
		}
	}
	if c.Admission.ProvisionalAdmissionRatePerHour <= 0 {
		return fmt.Errorf("admission.provisional_admission_rate_per_hour must be > 0")
	}
	if c.Admission.ProvisionalPoolMax <= 0 {
		return fmt.Errorf("admission.provisional_pool_max must be > 0")
	}
	if c.Admission.ProvisionalQuotaPerHour <= 0 {
		return fmt.Errorf("admission.provisional_quota_per_hour must be > 0")
	}
	if c.Admission.ProvisionalTierWeight <= 0 {
		return fmt.Errorf("admission.provisional_tier_weight must be > 0")
	}
	if c.Tier2.CatalogPath != "" && c.Tier2.CatalogPublicKey == "" {
		return fmt.Errorf("tier2.catalog_public_key must be set when tier2.catalog_path is set")
	}
	if c.Tier2.RequireHashVerified && (c.Tier2.CatalogPath == "" || c.Tier2.CatalogPublicKey == "") {
		return fmt.Errorf("tier2.require_hash_verified requires a valid signed catalog configuration")
	}
	if raw := strings.TrimSpace(c.Tier2.ModelHashLegacyUntil); raw != "" {
		if _, err := time.Parse(time.RFC3339, raw); err != nil {
			return fmt.Errorf("tier2.model_hash_legacy_until must be RFC3339")
		}
	}
	if c.Tier2.EncryptedLegAEAD != "A256GCM" {
		return fmt.Errorf("tier2.encrypted_leg_aead must be A256GCM")
	}
	if c.Tier2.EncryptedLegRekeyAfterRequests <= 0 {
		return fmt.Errorf("tier2.encrypted_leg_rekey_after_requests must be > 0")
	}
	if c.Tier2.EncryptedLegRekeyAfterSeconds <= 0 {
		return fmt.Errorf("tier2.encrypted_leg_rekey_after_seconds must be > 0")
	}
	if c.Tier2.RequireAttestation && len(c.Tier2.AttestationRoots) == 0 {
		return fmt.Errorf("tier2.require_attestation requires at least one attestation root")
	}
	for _, root := range c.Tier2.AttestationRoots {
		if c.Tier2.RequireAttestation && root == "mock-root" {
			return fmt.Errorf("tier2.attestation_roots must not include mock-root when tier2.require_attestation is true")
		}
		if root == "mock-root" && !c.Tier2.AllowMockAttestation {
			return fmt.Errorf("tier2.attestation_roots must not include mock-root unless tier2.allow_mock_attestation is true")
		}
	}
	if c.Tier2.AttestationMaxAgeS <= 0 {
		return fmt.Errorf("tier2.attestation_max_age_s must be > 0")
	}
	if c.Tier2.OutputSizeCapBytes < 0 {
		return fmt.Errorf("tier2.output_size_cap_bytes must be >= 0")
	}
	if c.Tier2.OutputBytesPerTokenCeiling <= 0 {
		return fmt.Errorf("tier2.output_bytes_per_token_ceiling must be > 0")
	}
	if c.Tier2.DefaultOutputSizeCapBytes <= 0 {
		return fmt.Errorf("tier2.default_output_size_cap_bytes must be > 0")
	}
	if c.Tier2.ResponseTimeAnomalyFactor <= 1.0 {
		return fmt.Errorf("tier2.response_time_anomaly_factor must be > 1.0")
	}
	if c.Tier2.ResponseTimeAnomalyMinMS < 0 {
		return fmt.Errorf("tier2.response_time_anomaly_min_ms must be >= 0")
	}
	if c.Rewards.ProviderShare < 0 || c.Rewards.ProviderShare > 1 {
		return fmt.Errorf("rewards.provider_share must be in [0.0, 1.0]")
	}
	if c.Rewards.GlobalMultiplier <= 0 {
		return fmt.Errorf("rewards.global_multiplier must be > 0")
	}
	if c.Settlement.CadenceDays <= 0 {
		return fmt.Errorf("settlement.cadence_days must be > 0")
	}
	if c.Settlement.MinPayoutCredits < 0 {
		return fmt.Errorf("settlement.min_payout_credits must be >= 0")
	}
	if c.Settlement.StartupReconcileWindowHours <= 0 {
		return fmt.Errorf("settlement.startup_reconcile_window_hours must be > 0")
	}
	if c.Settlement.NightlyReconcileWindowDays <= 0 {
		return fmt.Errorf("settlement.nightly_reconcile_window_days must be > 0")
	}
	if c.Settlement.RecoveryGraceSeconds < 0 {
		return fmt.Errorf("settlement.recovery_grace_seconds must be >= 0")
	}
	if c.Settlement.RecoveryGraceSeconds > 900 {
		return fmt.Errorf("settlement.recovery_grace_seconds must be <= 900")
	}
	if c.Settlement.PendingDeadlineSeconds < 1 {
		return fmt.Errorf("settlement.pending_deadline_seconds must be >= 1")
	}
	if c.Settlement.PendingDeadlineSeconds > 900 {
		return fmt.Errorf("settlement.pending_deadline_seconds must be <= 900")
	}
	if c.Settlement.VerifiedModelSettlementMode != "observe" && c.Settlement.VerifiedModelSettlementMode != "enforce" {
		return fmt.Errorf("settlement.verified_model_settlement_mode must be observe or enforce")
	}
	if c.Storage.RequestLogRetentionDays <= 0 {
		return fmt.Errorf("storage.request_log_retention_days must be > 0")
	}
	if c.Storage.AuditLogRetentionDays < minAuditLogRetentionDays {
		return fmt.Errorf("storage.audit_log_retention_days must be >= %d (compliance floor)", minAuditLogRetentionDays)
	}
	if c.Storage.RequestLogRetentionDays < c.Settlement.NightlyReconcileWindowDays {
		return fmt.Errorf("storage.request_log_retention_days must be >= settlement.nightly_reconcile_window_days")
	}
	if c.Endpoints.ProviderEarnings.RateLimitPerMinute <= 0 {
		return fmt.Errorf("endpoints.provider_earnings.rate_limit_per_minute must be > 0")
	}
	if err := c.validateExplorer(); err != nil {
		return err
	}
	if err := c.validateStats(); err != nil {
		return err
	}
	if err := c.validateOnboarding(); err != nil {
		return err
	}
	if err := c.validateMalibuEmission(); err != nil {
		return err
	}
	if err := c.validateAutotuneFeeds(); err != nil {
		return err
	}
	if err := c.validateProofOfWeights(); err != nil {
		return err
	}
	if _, ok := c.Rewards.RateCard["default"]; !ok {
		return fmt.Errorf("rewards.rate_card must contain default")
	}
	for model, entry := range c.Rewards.RateCard {
		cacheRate := entry.EffectivePromptCacheHitCreditsPerMtok()
		if entry.PromptCreditsPerMtok < 0 || entry.CompletionCreditsPerMtok < 0 || cacheRate < 0 {
			return fmt.Errorf("rewards.rate_card.%s rates must be >= 0", model)
		}
		if cacheRate > entry.PromptCreditsPerMtok {
			return fmt.Errorf("rewards.rate_card.%s prompt_cache_hit_credits_per_mtok must be <= prompt_credits_per_mtok", model)
		}
	}
	seen := map[string]struct{}{}
	for _, p := range c.Providers {
		if err := ValidateProviderID(p.ProviderID); err != nil {
			return err
		}
		if _, ok := seen[p.ProviderID]; ok {
			return fmt.Errorf("duplicate provider_id %q", p.ProviderID)
		}
		seen[p.ProviderID] = struct{}{}
		if p.EndpointURL != "" {
			if err := ValidateEndpointURL(p.EndpointURL); err != nil {
				return fmt.Errorf("provider %q endpoint_url must be a valid https URL (http allowed only for 127.0.0.1/localhost)", p.ProviderID)
			}
		}
	}
	if c.Payout.Enabled {
		if c.Payout.Security.HotWalletAddress == "" {
			return fmt.Errorf("payout.security.hot_wallet_address must be set when payout.enabled is true")
		}
		if c.Payout.Security.RPCURLPrimary == "" || c.Payout.Security.RPCURLSecondary == "" {
			return fmt.Errorf("payout.security.rpc_url_primary and rpc_url_secondary must both be set (SPEC-016 §4.4 two-RPC discipline)")
		}
		// FULL-r1 [full-sec:r1-1] HIGH closure: payout RPC URLs are
		// the trust root for the §4.4 two-RPC discipline. An
		// attacker-controlled origin can return agreeing chain IDs,
		// receipts, and balanceOf results — defeating
		// ReceiptsAgree / chain-balance drift detection. Enforce
		// https-only (TLS+SPKI pin runs only on https handshakes),
		// no userinfo (avoids credential leak in URL logs), no
		// loopback/private/link-local/unspecified targets (SSRF +
		// internal-pivot defense), and distinct hostnames between
		// primary and secondary (independent providers).
		priURL, err := validatePayoutRPCURL("payout.security.rpc_url_primary", c.Payout.Security.RPCURLPrimary)
		if err != nil {
			return err
		}
		secURL, err := validatePayoutRPCURL("payout.security.rpc_url_secondary", c.Payout.Security.RPCURLSecondary)
		if err != nil {
			return err
		}
		if strings.EqualFold(priURL.Hostname(), secURL.Hostname()) {
			return fmt.Errorf("payout.security.rpc_url_primary and rpc_url_secondary must use distinct hostnames (SPEC-016 §4.4 independent-providers trust separation)")
		}
		if c.Payout.Security.PerPayoutCapUSDCBaseUnits <= 0 {
			return fmt.Errorf("payout.security.per_payout_cap_usdc_base_units must be > 0")
		}
		if c.Payout.Security.PerDayCapUSDCBaseUnits <= 0 {
			return fmt.Errorf("payout.security.per_day_cap_usdc_base_units must be > 0")
		}
		if c.Payout.Security.PerDayCapUSDCBaseUnits < c.Payout.Security.PerPayoutCapUSDCBaseUnits {
			return fmt.Errorf("payout.security.per_day_cap_usdc_base_units must be >= per_payout_cap_usdc_base_units")
		}
		if c.Payout.Security.CancelMaxTipMultiplier < 1.0 {
			return fmt.Errorf("payout.security.cancel_max_tip_multiplier must be >= 1.0")
		}
		if c.Payout.Security.CancelMaxGasNativeWei <= 0 {
			return fmt.Errorf("payout.security.cancel_max_gas_native_wei must be > 0")
		}
		if c.Payout.Security.CancelMaxGasNativeWeiPer24h < c.Payout.Security.CancelMaxGasNativeWei {
			return fmt.Errorf("payout.security.cancel_max_gas_native_wei_per_24h must be >= cancel_max_gas_native_wei")
		}
		if c.Payout.Security.AbandonRatePerHour <= 0 {
			return fmt.Errorf("payout.security.abandon_rate_per_hour must be > 0")
		}
		if c.Payout.Security.ChainReconInterval < time.Minute {
			return fmt.Errorf("payout.security.chain_recon_interval must be >= 1m")
		}
		if c.Payout.Security.ChainReconToleranceUSDCBaseUnits <= 0 {
			return fmt.Errorf("payout.security.chain_recon_tolerance_usdc_base_units must be > 0")
		}
		if c.Payout.Security.PauseResumeMinInterval < time.Second {
			return fmt.Errorf("payout.security.pause_resume_min_interval must be >= 1s")
		}
		if !c.Payout.Security.DevMode && c.Payout.Security.EncryptedWalletPath == "" {
			return fmt.Errorf("payout.security.encrypted_wallet_path must be set when payout.enabled=true (SPEC §6.3); set payout.security.dev_mode=true ONLY for non-production hosts")
		}
		if c.Payout.Tuning.AddressCoolingOffPeriod < time.Hour {
			return fmt.Errorf("payout.tuning.address_cooling_off_period must be >= 1h (SPEC-016 §3.1)")
		}
		if c.Payout.Tuning.RunInterval < 5*time.Minute || c.Payout.Tuning.RunInterval > 24*time.Hour {
			return fmt.Errorf("payout.tuning.run_interval must be in [5m, 24h] (SPEC-016 §6.5)")
		}
		if c.Payout.Tuning.RunNowMinInterval < 10*time.Second || c.Payout.Tuning.RunNowMinInterval > time.Hour {
			return fmt.Errorf("payout.tuning.run_now_min_interval must be in [10s, 1h] (SPEC-016 §6.5)")
		}
		if c.Payout.Tuning.ConfirmationBlocks < 5 || c.Payout.Tuning.ConfirmationBlocks > 200 {
			return fmt.Errorf("payout.tuning.confirmation_blocks must be in [5, 200] (SPEC-016 §6.5 v0.1.20 round-20 M2 closure widened from [2, 50])")
		}
		if c.Payout.Tuning.MaxRowsPerRun < 1 || c.Payout.Tuning.MaxRowsPerRun > 500 {
			return fmt.Errorf("payout.tuning.max_rows_per_run must be in [1, 500] (SPEC-016 §6.5)")
		}
		if c.Payout.Tuning.ReorgPollWindow < time.Hour || c.Payout.Tuning.ReorgPollWindow > 168*time.Hour {
			return fmt.Errorf("payout.tuning.reorg_poll_window must be in [1h, 168h] (SPEC-016 §6.5 v0.1.20 round-20 M1 closure)")
		}
		if c.Payout.Tuning.LowBalanceThreshold < 0 {
			return fmt.Errorf("payout.tuning.low_balance_threshold must be >= 0")
		}
		if c.Payout.Tuning.LowBalanceThreshold > 0 && c.Payout.Tuning.LowBalanceThreshold > 2*c.Payout.Security.PerDayCapUSDCBaseUnits {
			return fmt.Errorf("payout.tuning.low_balance_threshold must be <= 2 * per_day_cap_usdc_base_units (SPEC-016 §6.5)")
		}
		if c.Payout.Tuning.LowNativeThreshold < 0 || c.Payout.Tuning.LowNativeThreshold > 1_000_000_000_000_000_000 {
			return fmt.Errorf("payout.tuning.low_native_threshold must be in [0, 1e18] (SPEC-016 §6.5)")
		}
		if err := validateSPKIPin(c.Payout.Tuning.RPCURLPrimaryPinSPKI, "payout.tuning.rpc_url_primary_pin_spki"); err != nil {
			return err
		}
		if err := validateSPKIPin(c.Payout.Tuning.RPCURLSecondaryPinSPKI, "payout.tuning.rpc_url_secondary_pin_spki"); err != nil {
			return err
		}
	}
	return nil
}

// validateAdvertisedVersions rejects unparseable version floors at load. A
// typo in `required_binary_version` would fence the whole fleet at hello
// (compareSemver reports invalid, and invalid is treated as below-floor); a
// typo in a per-model floor would silently unroute one model. Both are config
// errors, so they fail the process at startup instead of in production.
func (c Config) validateAdvertisedVersions() error {
	advertised := c.CoordinatorAdvertisedVersion
	if required := strings.TrimSpace(advertised.RequiredBinaryVersion); required != "" && !versionfloor.Valid(required) {
		return fmt.Errorf("coordinator_advertised_version.required_binary_version %q must be a bare numeric version (e.g. 1.8.33)", required)
	}
	if latest := strings.TrimSpace(advertised.LatestBinaryVersion); latest != "" && !versionfloor.Valid(latest) {
		return fmt.Errorf("coordinator_advertised_version.latest_binary_version %q must be a bare numeric version (e.g. 1.8.65)", latest)
	}
	for modelID, floor := range advertised.PerModelRequiredBinaryVersion {
		if strings.TrimSpace(modelID) == "" {
			return fmt.Errorf("coordinator_advertised_version.per_model_required_binary_version has an empty model_id key")
		}
		if !versionfloor.Valid(floor) {
			return fmt.Errorf("coordinator_advertised_version.per_model_required_binary_version[%q] = %q must be a bare numeric version (e.g. 1.8.33)", modelID, floor)
		}
	}
	return nil
}

func (c Config) validateCompatibilitySet() error {
	policy := c.Coordinator.CompatibilitySet
	if !policy.Configured() {
		return nil
	}
	if err := ValidateCompatibilitySetID(policy.TargetID); err != nil {
		return fmt.Errorf("coordinator.compatibility_set.target_id: %w", err)
	}
	if len(policy.AcceptedIDs) < 2 {
		return fmt.Errorf("coordinator.compatibility_set.accepted_ids must contain the target and at least one rollback set")
	}
	if len(policy.AcceptedIDs) > maxAcceptedCompatibilitySets {
		return fmt.Errorf("coordinator.compatibility_set.accepted_ids must contain at most %d entries", maxAcceptedCompatibilitySets)
	}
	seen := make(map[string]struct{}, len(policy.AcceptedIDs))
	for i, id := range policy.AcceptedIDs {
		if err := ValidateCompatibilitySetID(id); err != nil {
			return fmt.Errorf("coordinator.compatibility_set.accepted_ids[%d]: %w", i, err)
		}
		if _, duplicate := seen[id]; duplicate {
			return fmt.Errorf("coordinator.compatibility_set.accepted_ids contains duplicate %q", id)
		}
		seen[id] = struct{}{}
	}
	if _, ok := seen[policy.TargetID]; !ok {
		return fmt.Errorf("coordinator.compatibility_set.accepted_ids must contain target_id")
	}
	if len(policy.FirstHopBridgeIDs) > maxFirstHopBridgeSets {
		return fmt.Errorf("coordinator.compatibility_set.first_hop_bridge_ids must contain at most %d entries", maxFirstHopBridgeSets)
	}
	bridgeSeen := make(map[string]struct{}, len(policy.FirstHopBridgeIDs))
	for i, id := range policy.FirstHopBridgeIDs {
		if err := ValidateCompatibilitySetID(id); err != nil {
			return fmt.Errorf("coordinator.compatibility_set.first_hop_bridge_ids[%d]: %w", i, err)
		}
		if _, duplicate := bridgeSeen[id]; duplicate {
			return fmt.Errorf("coordinator.compatibility_set.first_hop_bridge_ids contains duplicate %q", id)
		}
		bridgeSeen[id] = struct{}{}
		if id == policy.TargetID {
			return fmt.Errorf("coordinator.compatibility_set.first_hop_bridge_ids must not contain target_id")
		}
		if _, overlap := seen[id]; overlap {
			return fmt.Errorf("coordinator.compatibility_set.first_hop_bridge_ids must not overlap accepted_ids (%q)", id)
		}
	}
	return nil
}

var referralConfigPartPattern = regexp.MustCompile(`^[A-Za-z0-9_]{1,32}$`)

func (c Config) validateReferrals() error {
	r := c.Referrals
	// The read-only validation response may advertise this URL even while the
	// referral gate is disabled, so validate it independently of launch flags.
	if raw := strings.TrimSpace(r.RequestAccessURL); raw != "" {
		reqURL, err := url.Parse(raw)
		if err != nil ||
			reqURL.Scheme != "https" ||
			reqURL.Host == "" ||
			reqURL.User != nil ||
			reqURL.Port() != "" ||
			reqURL.Fragment != "" ||
			reqURL.EscapedPath() == "" ||
			reqURL.Hostname() != strings.ToLower(reqURL.Hostname()) ||
			reqURL.String() != raw {
			return fmt.Errorf("referrals.request_access_url must be a canonical absolute https URL without credentials, port, or fragment when set")
		}
	}
	if !r.RequireForRegistration && (c.Auth.AllowTokenlessProvisionalBootstrap || c.Onboarding.AppTrackRegisterEnabled) {
		return fmt.Errorf("referrals.require_for_registration must be true when fresh provider registration mint surfaces are enabled")
	}
	if r.EnableJoinLinks {
		if !r.RequireForRegistration {
			return fmt.Errorf("referrals.enable_join_links requires require_for_registration=true")
		}
		if !r.EnablePublicValidation {
			return fmt.Errorf("referrals.enable_join_links requires enable_public_validation=true")
		}
	}
	if r.EnableSocialInviteBonus && (!r.RequireForRegistration || !r.EnableJoinLinks || !r.EnablePublicValidation) {
		return fmt.Errorf("referrals.enable_social_invite_bonus requires referral admission, public validation, and join links")
	}
	if !r.RequireForRegistration && !r.EnablePublicValidation && !r.EnableJoinLinks && !r.EnableSocialInviteBonus {
		return nil
	}
	if !referralConfigPartPattern.MatchString(r.Campaign) {
		return fmt.Errorf("referrals.campaign must contain 1-32 letters, digits, or underscores")
	}
	if !referralConfigPartPattern.MatchString(r.PolicyVersion) {
		return fmt.Errorf("referrals.policy_version must contain 1-32 letters, digits, or underscores")
	}
	if raw := strings.TrimSpace(r.GrandfatherBefore); raw != "" {
		if _, err := time.Parse(time.RFC3339, raw); err != nil {
			return fmt.Errorf("referrals.grandfather_before must be RFC3339: %w", err)
		}
	}
	if !referralConfigPartPattern.MatchString(r.CurrentKeyID) {
		return fmt.Errorf("referrals.current_key_id must contain 1-32 letters, digits, or underscores")
	}
	secret := r.HMACKeys[r.CurrentKeyID]
	if len(secret) < 32 {
		return fmt.Errorf("referrals.hmac_keys.%s must be at least 32 bytes", r.CurrentKeyID)
	}
	for keyID, value := range r.HMACKeys {
		if !referralConfigPartPattern.MatchString(keyID) || len(value) < 32 {
			return fmt.Errorf("referrals.hmac_keys.%s is invalid or shorter than 32 bytes", keyID)
		}
	}
	if r.ProviderBaseUses <= 0 {
		return fmt.Errorf("referrals.provider_base_uses must be > 0")
	}
	if r.EnableSocialInviteBonus {
		if r.SocialBonusUses <= 0 || r.ChallengeTTLS <= 0 || r.SocialVerificationDwellS <= 0 {
			return fmt.Errorf("referrals social_bonus_uses, challenge_ttl_s, and social_verification_dwell_s must be > 0")
		}
		if strings.TrimSpace(r.XAPIBearerToken) == "" {
			return fmt.Errorf("referrals.x_api_bearer_token must be set when social invite bonus is enabled")
		}
	}
	if strings.TrimSpace(r.JoinBaseURL) != "https://malibu.tech/j" {
		return fmt.Errorf("referrals.join_base_url must be exactly https://malibu.tech/j")
	}
	return nil
}

func (c Config) validateProofOfWeights() error {
	p := c.ProofOfWeights
	if p.AutotuneEvidenceTTLDays < 0 {
		return fmt.Errorf("proof_of_weights.autotune_evidence_ttl_days must be >= 0")
	}
	if p.RequireAutotuneHelloGate {
		if p.AutotuneEvidenceTTLDays <= 0 {
			return fmt.Errorf("proof_of_weights.autotune_evidence_ttl_days must be > 0 when require_autotune_hello_gate is true")
		}
		// FIX 2 (issue #582): the hello-gate admission window (LatestVerified filters
		// evidence to AutotuneEvidenceTTLDays) must be at least as wide as the
		// approve/verifier evidence-age limit (hardwareverify.MaxEvidenceAgeDays). If
		// the TTL is set lower, a job whose evidence has aged past it is still
		// approvable+promotable (approval gates on MaxEvidenceAgeDays, not the TTL) yet
		// LatestVerified excludes it — so admission stays blocked even though every
		// operator action "succeeded" (a false success). Requiring TTL >= the verifier
		// limit closes that window.
		if p.AutotuneEvidenceTTLDays < hardwareverify.MaxEvidenceAgeDays {
			return fmt.Errorf("proof_of_weights.autotune_evidence_ttl_days (%d) must be >= hardwareverify.MaxEvidenceAgeDays (%d) when require_autotune_hello_gate is true, else evidence approvable within the verifier's %d-day window is excluded from the hello-gate admission window and admission stays blocked", p.AutotuneEvidenceTTLDays, hardwareverify.MaxEvidenceAgeDays, hardwareverify.MaxEvidenceAgeDays)
		}
		if err := c.requireAutotuneEvidenceFeeds(); err != nil {
			return err
		}
	}
	if !p.TelemetryDrift.Enabled {
		// The quarantine is a second gate ON TOP of the drift evaluator; it
		// cannot run without it. Rejecting the combination here (rather than
		// silently ignoring it) keeps a half-configured overlay from reading
		// as "enforcement on".
		if p.TelemetryDrift.QuarantineMissingBenchmark {
			return fmt.Errorf("proof_of_weights.telemetry_drift.quarantine_missing_benchmark requires telemetry_drift.enabled")
		}
		return nil
	}
	if p.AutotuneEvidenceTTLDays <= 0 {
		return fmt.Errorf("proof_of_weights.autotune_evidence_ttl_days must be > 0 when telemetry_drift.enabled is true")
	}
	if err := c.requireAutotuneEvidenceFeeds(); err != nil {
		return err
	}
	d := p.TelemetryDrift
	if d.TPSRatioThreshold <= 0 || d.TPSRatioThreshold > 1 || math.IsNaN(d.TPSRatioThreshold) || math.IsInf(d.TPSRatioThreshold, 0) {
		return fmt.Errorf("proof_of_weights.telemetry_drift.tps_ratio_threshold must be in (0,1]")
	}
	if d.TPSMinAbsolute < 0 || math.IsNaN(d.TPSMinAbsolute) || math.IsInf(d.TPSMinAbsolute, 0) {
		return fmt.Errorf("proof_of_weights.telemetry_drift.tps_min_absolute must be >= 0")
	}
	if d.TPSMinRequestsWindow < 0 {
		return fmt.Errorf("proof_of_weights.telemetry_drift.tps_min_requests_window must be >= 0")
	}
	if d.OPoIPassRateWindow < 0 {
		return fmt.Errorf("proof_of_weights.telemetry_drift.opoi_pass_rate_window must be >= 0")
	}
	if d.OPoIPassRateThreshold < 0 || d.OPoIPassRateThreshold > 1 || math.IsNaN(d.OPoIPassRateThreshold) || math.IsInf(d.OPoIPassRateThreshold, 0) {
		return fmt.Errorf("proof_of_weights.telemetry_drift.opoi_pass_rate_threshold must be in [0,1]")
	}
	if d.AlertCooldownSeconds < 0 {
		return fmt.Errorf("proof_of_weights.telemetry_drift.alert_cooldown_s must be >= 0")
	}
	for _, status := range d.HashAlertOnStatus {
		switch strings.TrimSpace(status) {
		case "hash_mismatch", "hash_invalid", "hash_verified", "uncatalogued", "catalog_unavailable":
		default:
			return fmt.Errorf("proof_of_weights.telemetry_drift.hash_alert_on_status contains unsupported value %q", status)
		}
	}
	if !c.Pool.CanaryEnabled && d.OPoIPassRateWindow > 0 {
		return fmt.Errorf("proof_of_weights.telemetry_drift.opoi_pass_rate_window requires pool.canary_enabled when > 0")
	}
	return nil
}

func (c Config) requireAutotuneEvidenceFeeds() error {
	a := c.AutotuneFeeds
	if strings.TrimSpace(a.AutotuneCandidatesPath) == "" || strings.TrimSpace(a.AutotuneCandidatesSigPath) == "" {
		return fmt.Errorf("proof_of_weights autotune evidence requires autotune.autotune_candidates_path and autotune.autotune_candidates_sig_path")
	}
	if !c.Onboarding.AppTrackRegisterEnabled || strings.TrimSpace(c.Onboarding.PostgresDSN) == "" {
		return fmt.Errorf("proof_of_weights autotune evidence requires onboarding.app_track_register_enabled and onboarding.postgres_dsn")
	}
	return nil
}

func (c Config) validateAutotuneFeeds() error {
	a := c.AutotuneFeeds
	bridgeDeadline, err := a.ProviderAdmissionBridgeDeadlineTime()
	if err != nil {
		return err
	}
	if !a.EnforceProviderAdmission {
		if bridgeDeadline.IsZero() {
			return fmt.Errorf("autotune.provider_admission_bridge_deadline is required when enforce_provider_admission is false")
		}
		now := time.Now().UTC()
		if !bridgeDeadline.After(now) {
			return fmt.Errorf("autotune.provider_admission_bridge_deadline must be in the future when enforce_provider_admission is false")
		}
		if bridgeDeadline.Sub(now) > maxProviderAdmissionBridgeDuration {
			return fmt.Errorf("autotune.provider_admission_bridge_deadline must be no more than 24 hours in the future")
		}
	}
	configured := false
	var missingPairs []string
	pairs := []struct {
		label    string
		jsonPath string
		sigPath  string
	}{
		{"rate_card", a.RateCardPath, a.RateCardSigPath},
		{"demand_rank", a.DemandRankPath, a.DemandRankSigPath},
		{"autotune_candidates", a.AutotuneCandidatesPath, a.AutotuneCandidatesSigPath},
	}
	for _, p := range pairs {
		jsonPath := strings.TrimSpace(p.jsonPath)
		sigPath := strings.TrimSpace(p.sigPath)
		if jsonPath == "" && sigPath == "" {
			missingPairs = append(missingPairs, p.label)
			continue
		}
		if jsonPath == "" || sigPath == "" {
			return fmt.Errorf("autotune.%s_path and autotune.%s_sig_path must both be set", p.label, p.label)
		}
		configured = true
	}
	if configured && len(missingPairs) > 0 {
		label := missingPairs[0]
		return fmt.Errorf("autotune.%s_path and autotune.%s_sig_path are required when any autotune feed is configured", label, label)
	}
	keyring, err := a.DecodePublicKeyring()
	if err != nil {
		return err
	}
	if configured && len(keyring) == 0 {
		return fmt.Errorf("autotune.public_keys must contain at least one Ed25519 public key when a feed is configured")
	}
	return nil
}

func (c Config) validateOnboarding() error {
	o := c.Onboarding
	if strings.TrimSpace(o.BundleID) == "" {
		return fmt.Errorf("onboarding.bundle_id must be set")
	}
	if strings.TrimSpace(o.CoordinatorDomain) == "" {
		return fmt.Errorf("onboarding.coordinator_domain must be set")
	}
	if strings.Contains(o.CoordinatorDomain, "://") || strings.HasSuffix(o.CoordinatorDomain, "/") {
		return fmt.Errorf("onboarding.coordinator_domain must be a bare lowercase host with no scheme or trailing slash")
	}
	if o.CoordinatorDomain != strings.ToLower(o.CoordinatorDomain) {
		return fmt.Errorf("onboarding.coordinator_domain must be lowercase")
	}
	if !o.AppTrackRegisterEnabled {
		// Named operator maps are also used by optional admin routes. Preserve
		// compatibility for CLI-only deployments with a partially provisioned
		// map: every dual-control route independently fails closed with
		// dual_control_unavailable until two distinct actors and secrets exist.
		return nil
	}
	if strings.TrimSpace(o.PostgresDSN) == "" {
		return fmt.Errorf("onboarding.postgres_dsn must be set when onboarding.app_track_register_enabled is true")
	}
	if strings.TrimSpace(o.AuthPolicyRequestDSN) == "" {
		return fmt.Errorf("onboarding.auth_policy_request_dsn must be set when onboarding.app_track_register_enabled is true")
	}
	if strings.TrimSpace(o.AuthPolicyApproveDSN) == "" {
		return fmt.Errorf("onboarding.auth_policy_approve_dsn must be set when onboarding.app_track_register_enabled is true")
	}
	if strings.TrimSpace(o.AuthPolicyCutoverDSN) == "" {
		return fmt.Errorf("onboarding.auth_policy_cutover_dsn must be set when onboarding.app_track_register_enabled is true")
	}
	if strings.TrimSpace(o.HardwareTrustRequestDSN) == "" {
		return fmt.Errorf("onboarding.hardware_trust_request_dsn must be set when onboarding.app_track_register_enabled is true")
	}
	if strings.TrimSpace(o.HardwareTrustApproveDSN) == "" {
		return fmt.Errorf("onboarding.hardware_trust_approve_dsn must be set when onboarding.app_track_register_enabled is true")
	}
	if strings.TrimSpace(o.AppleTeamID) == "" {
		return fmt.Errorf("onboarding.apple_team_id must be set when onboarding.app_track_register_enabled is true")
	}
	if strings.TrimSpace(c.Auth.OperatorKey) == "" {
		return fmt.Errorf("auth.operator_key must be set when onboarding.app_track_register_enabled is true")
	}
	if len(o.ASNPrefixes) == 0 {
		return fmt.Errorf("onboarding.asn_prefixes must be set when onboarding.app_track_register_enabled is true")
	}
	for prefix, asn := range o.ASNPrefixes {
		if _, err := netip.ParsePrefix(strings.TrimSpace(prefix)); err != nil {
			return fmt.Errorf("onboarding.asn_prefixes contains invalid CIDR %q: %w", prefix, err)
		}
		if strings.TrimSpace(asn) == "" {
			return fmt.Errorf("onboarding.asn_prefixes[%q] must be non-empty", prefix)
		}
	}
	return validateOperatorKeyMap(c.Auth.OperatorKeys)
}

func (c Config) validateMalibuEmission() error {
	m := c.MalibuEmission
	if !m.Enabled {
		return nil
	}
	if strings.TrimSpace(m.WriterDSN) == "" {
		return fmt.Errorf("malibu_emission.writer_dsn must be set when malibu_emission.enabled is true")
	}
	if m.TickIntervalSeconds <= 0 {
		return fmt.Errorf("malibu_emission.tick_interval_seconds must be > 0")
	}
	if m.ProviderDailyCapMALIBU <= 0 {
		return fmt.Errorf("malibu_emission.provider_daily_cap_malibu must be > 0")
	}
	if m.WalletDailyCapMALIBU <= 0 {
		return fmt.Errorf("malibu_emission.wallet_daily_cap_malibu must be > 0")
	}
	if m.WalletMirrorIntervalSeconds <= 0 {
		return fmt.Errorf("malibu_emission.wallet_mirror_interval_seconds must be > 0")
	}
	if m.UnlockEvalIntervalSeconds <= 0 {
		return fmt.Errorf("malibu_emission.unlock_eval_interval_seconds must be > 0")
	}
	if m.MaxSerializableRetries <= 0 {
		return fmt.Errorf("malibu_emission.max_serializable_retries must be > 0")
	}
	return nil
}

func validateOperatorKeyMap(keys map[string]string) error {
	if len(keys) < 2 {
		return fmt.Errorf("auth.operator_keys must contain at least two operators")
	}
	seenSecrets := map[string]string{}
	for actor, secret := range keys {
		trimmedActor := strings.TrimSpace(actor)
		if trimmedActor == "" || strings.ContainsAny(trimmedActor, " \t\r\n") {
			return fmt.Errorf("auth.operator_keys contains invalid operator id %q", actor)
		}
		if strings.HasPrefix(trimmedActor, "operator:") {
			trimmedActor = strings.TrimPrefix(trimmedActor, "operator:")
			if trimmedActor == "" || strings.ContainsAny(trimmedActor, " \t\r\n") {
				return fmt.Errorf("auth.operator_keys contains invalid operator id %q", actor)
			}
		}
		secret = strings.TrimSpace(secret)
		if secret == "" {
			return fmt.Errorf("auth.operator_keys.%s must be non-empty", actor)
		}
		if previous, ok := seenSecrets[secret]; ok {
			return fmt.Errorf("auth.operator_keys.%s must not reuse secret from auth.operator_keys.%s", actor, previous)
		}
		seenSecrets[secret] = actor
	}
	return nil
}

func (c Config) validateGitHubOAuth() error {
	oauth := c.Auth.GitHubOAuth
	if !oauth.Enabled {
		return nil
	}
	if strings.TrimSpace(oauth.ClientID) == "" {
		return fmt.Errorf("GITHUB_OAUTH_CLIENT_ID must be set when GITHUB_OAUTH_ENABLED=true")
	}
	if strings.TrimSpace(oauth.ClientSecret) == "" {
		return fmt.Errorf("GITHUB_OAUTH_CLIENT_SECRET must be set when GITHUB_OAUTH_ENABLED=true")
	}
	redirect, err := url.Parse(strings.TrimSpace(oauth.RedirectURI))
	if err != nil || redirect.Scheme != "https" || redirect.Host == "" || redirect.Path != "/v1/auth/github/callback" || redirect.RawQuery != "" || redirect.Fragment != "" {
		return fmt.Errorf("GITHUB_OAUTH_REDIRECT_URI must be https://.../v1/auth/github/callback when GITHUB_OAUTH_ENABLED=true")
	}
	portal, err := url.Parse(strings.TrimSpace(oauth.PortalBaseURL))
	if err != nil || portal.Scheme != "https" || portal.Host == "" || portal.Path != "" || portal.RawQuery != "" || portal.Fragment != "" || portal.User != nil {
		return fmt.Errorf("PORTAL_BASE_URL must be https://<host>[:<port>] with no path or query when GITHUB_OAUTH_ENABLED=true")
	}
	if oauth.SessionCookieDomain != "" {
		domain := strings.TrimPrefix(strings.ToLower(strings.TrimSpace(oauth.SessionCookieDomain)), ".")
		host := strings.ToLower(portal.Hostname())
		if domain == "" || host != domain && !strings.HasSuffix(host, "."+domain) {
			return fmt.Errorf("MP_SESSION_COOKIE_DOMAIN must match PORTAL_BASE_URL host scope")
		}
	}
	return nil
}

func (c Config) validateExplorer() error {
	if c.Explorer.Enabled && c.Auth.OperatorKey == "" {
		return fmt.Errorf("auth.operator_key must be set when explorer.enabled is true")
	}
	if !strings.HasPrefix(c.Explorer.BindPath, "/admin/explorer/") || !strings.HasSuffix(c.Explorer.BindPath, "/") {
		return fmt.Errorf("explorer.bind_path must begin with /admin/explorer/ and end with /")
	}
	if err := validateExplorerWindow("explorer.activity", c.Explorer.ActivityMaxWindowDays, c.Explorer.ActivityDefaultWindowHours, 1, 31); err != nil {
		return err
	}
	if err := validateExplorerWindow("explorer.buyers", c.Explorer.BuyersMaxWindowDays, c.Explorer.BuyersDefaultWindowHours, 1, 31); err != nil {
		return err
	}
	if err := validateExplorerWindow("explorer.ledger", c.Explorer.LedgerMaxWindowDays, c.Explorer.LedgerDefaultWindowHours, 1, 31); err != nil {
		return err
	}
	if err := validateExplorerWindow("explorer.sessions", c.Explorer.SessionsMaxWindowDays, c.Explorer.SessionsDefaultWindowHours, 1, 31); err != nil {
		return err
	}
	if err := validateExplorerWindow("explorer.settlements", c.Explorer.SettlementsMaxWindowDays, c.Explorer.SettlementsDefaultWindowHours, 31, 365); err != nil {
		return err
	}
	if c.Explorer.GatewayTimeoutMs < 100 || c.Explorer.GatewayTimeoutMs > 5000 {
		return fmt.Errorf("explorer.gateway_timeout_ms must be between 100 and 5000")
	}
	if c.Explorer.QueryTimeoutMs < 100 || c.Explorer.QueryTimeoutMs > 5000 {
		return fmt.Errorf("explorer.query_timeout_ms must be between 100 and 5000")
	}
	if c.Explorer.PollMinIntervalSeconds < 1 || c.Explorer.PollMinIntervalSeconds > 60 {
		return fmt.Errorf("explorer.poll_min_interval_seconds must be between 1 and 60")
	}
	if c.Explorer.RequestsPerMinuteCap < 1 || c.Explorer.RequestsPerMinuteCap > 60 {
		return fmt.Errorf("explorer.requests_per_minute_cap must be between 1 and 60")
	}
	if c.Explorer.Enabled && c.Explorer.GatewayBaseURL != "" {
		u, err := url.Parse(c.Explorer.GatewayBaseURL)
		if err != nil || u.Scheme == "" || u.Host == "" {
			return fmt.Errorf("explorer.gateway_base_url must be an absolute URL when set")
		}
		if u.User != nil {
			return fmt.Errorf("explorer.gateway_base_url must not contain userinfo")
		}
		if u.Scheme != "https" && !(u.Scheme == "http" && isLoopbackHost(u.Hostname())) {
			return fmt.Errorf("explorer.gateway_base_url must use https unless targeting loopback")
		}
	}
	return nil
}

// validateStats enforces the SPEC-017 §7.2 + BUILD §C structural
// constraints on the stats config block.
//
// Stats.Enabled=false (the v0.1 default) skips ALL validation
// below; an operator that has not flipped the gate cannot brick
// startup by leaving Stats fields empty.
//
// When Stats.Enabled=true the required daemon DSNs MUST be set
// (fail-closed per BUILD §C.3). PartnerKeys.WriterDSN is
// only required when last_used_at_updates_enabled=true. The CLI
// admin DSN is OPTIONAL even when stats is enabled (BUILD §B.2).
//
// Numeric ranges:
//   - LateEventsRetentionDays — SPEC §9.3 v0.1.7 floor 30; default 90.
//   - AccessControlMaxAgeSeconds — SPEC §5.7 v0.1.7 cap 300; default 60.
//   - BackfillMode — SPEC §9.7 enum {"partial","full"}; default "partial".
func (c Config) validateStats() error {
	s := c.Stats
	if !s.Enabled {
		return nil
	}
	// Final adversarial audit (codex SECURITY MEDIUM 1) — when
	// stats are enabled, `/metrics` is mounted on the provider
	// mux at provider-port. The Prometheus metric
	// `stats_partner_key_request_total{partner_key_id=...}`
	// is a partner-key enumeration oracle if it ever lands on
	// a public interface, so fail closed at config-validation
	// time: refuse to start if listen.bind_address is not a
	// loopback host. Pearl deploy runs `127.0.0.1:8444`; a
	// future operator who mis-types `0.0.0.0` or `::` gets a
	// clear startup error instead of an exposed enumeration
	// surface.
	bindHost := strings.TrimSpace(c.Listen.BindAddress)
	if bindHost == "" {
		return fmt.Errorf("listen.bind_address must be set (loopback required when stats.enabled is true)")
	}
	if !isLoopbackHost(bindHost) {
		return fmt.Errorf("stats.enabled=true requires listen.bind_address to be a loopback host (127.0.0.1, ::1, or localhost); got %q. The /metrics endpoint mounts on the provider port and a non-loopback bind exposes the stats_partner_key_request_total enumeration oracle. Place the coordinator behind a reverse proxy that terminates the public surface (e.g. nginx) and keep the binary bound to loopback", bindHost)
	}
	if strings.TrimSpace(s.ReaderDSN) == "" {
		return fmt.Errorf("stats.reader_dsn must be set when stats.enabled is true")
	}
	if strings.TrimSpace(s.RollupDSN) == "" {
		return fmt.Errorf("stats.rollup_dsn must be set when stats.enabled is true")
	}
	if s.PartnerKeys.LastUsedAtUpdatesEnabled && strings.TrimSpace(s.PartnerKeys.WriterDSN) == "" {
		return fmt.Errorf("stats.partner_keys.writer_dsn must be set when stats.partner_keys.last_used_at_updates_enabled is true")
	}
	switch s.Rollup.BackfillMode {
	case "", "partial", "full":
	default:
		return fmt.Errorf("stats.rollup.backfill_mode must be one of {partial, full} (got %q)", s.Rollup.BackfillMode)
	}
	// LateEventsRetentionDays: chosen pin per BUILD §2 Step 2 is
	// CLAMP+WARN (handled at rollup boot, not config validation).
	// We still reject below 30 here ONLY if explicitly set to
	// a negative value; zero = use default (90). A value in
	// (0, 30) is permitted but will be clamped to 30 by the
	// rollup with a WARN log.
	if s.Rollup.LateEventsRetentionDays < 0 {
		return fmt.Errorf("stats.rollup.late_events_retention_days must be >= 0 (0 = default 90, values in (0,30) clamped to 30 with WARN)")
	}
	if s.Rollup.UsdPerMillionCredits < 0 {
		return fmt.Errorf("stats.rollup.usd_per_million_credits must be >= 0")
	}
	if s.Rollup.DriftThresholdRatio != 0 && (s.Rollup.DriftThresholdRatio < 0.001 || s.Rollup.DriftThresholdRatio > 0.05) {
		return fmt.Errorf("stats.rollup.drift_threshold_ratio must be in [0.001, 0.05] when set (SPEC §9.4 default 0.005)")
	}
	if s.Rollup.NightlyRebuildHourUTC < 0 || s.Rollup.NightlyRebuildHourUTC > 23 {
		return fmt.Errorf("stats.rollup.nightly_rebuild_hour_utc must be in [0, 23]")
	}
	if s.Rollup.LateEventsLookbackHours != 0 && s.Rollup.LateEventsLookbackHours < 24 {
		return fmt.Errorf("stats.rollup.late_events_lookback_hours must be >= 24 (SPEC §9.3 1× reconciliation-margin floor)")
	}
	if s.CORS.AccessControlMaxAgeSeconds < 0 || s.CORS.AccessControlMaxAgeSeconds > 300 {
		return fmt.Errorf("stats.cors.access_control_max_age_seconds must be between 0 and 300 (SPEC §5.7)")
	}
	prefixes, err := c.StatsTrustedProxyPrefixes()
	if err != nil {
		return err
	}
	if len(prefixes) == 0 && !s.TrustDirectPeer {
		return fmt.Errorf("stats.trusted_proxies must be set when stats.enabled is true; set stats.trust_direct_peer=true only for direct-client deployments")
	}
	if s.RateLimit.MaxBuckets < 0 {
		return fmt.Errorf("stats.rate_limit.max_buckets must be >= 0")
	}
	if s.RateLimit.IdleTTLSeconds < 0 {
		return fmt.Errorf("stats.rate_limit.idle_ttl_seconds must be >= 0")
	}
	if s.RateLimit.EvictionIntervalSeconds < 0 {
		return fmt.Errorf("stats.rate_limit.eviction_interval_seconds must be >= 0")
	}
	if s.RateLimit.PreflightRPM < 0 {
		return fmt.Errorf("stats.rate_limit.preflight_rpm must be >= 0")
	}
	if s.StreamingMetrics.MaxSamples < 0 {
		return fmt.Errorf("stats.streaming_metrics.max_samples must be >= 0")
	}
	return nil
}

func isLoopbackHost(host string) bool {
	switch strings.ToLower(host) {
	case "localhost", "127.0.0.1", "::1":
		return true
	default:
		return false
	}
}

func validateExplorerWindow(prefix string, maxDays, defaultHours, minDays, maxDaysAllowed int) error {
	if maxDays < minDays || maxDays > maxDaysAllowed {
		return fmt.Errorf("%s_max_window_days must be between %d and %d", prefix, minDays, maxDaysAllowed)
	}
	if defaultHours < 1 || defaultHours > maxDays*24 {
		return fmt.Errorf("%s_default_window_hours must be between 1 and %d", prefix, maxDays*24)
	}
	return nil
}

// validateSPKIPin checks SPEC-016 §6.5 syntactic bounds on a
// pinned SHA-256 SPKI fingerprint. Empty disables pinning;
// otherwise the value MUST be exactly 64 hex chars (lowercase
// or uppercase). Content-correctness (the value actually matching
// the RPC's served cert) is operational, not parse-time.
func validateSPKIPin(value, name string) error {
	if value == "" {
		return nil
	}
	if len(value) != 64 {
		return fmt.Errorf("%s must be empty or 64 hex chars (got %d chars)", name, len(value))
	}
	for _, r := range value {
		if (r >= '0' && r <= '9') || (r >= 'a' && r <= 'f') || (r >= 'A' && r <= 'F') {
			continue
		}
		return fmt.Errorf("%s must be empty or a valid 64-hex-char SHA-256", name)
	}
	return nil
}

// validatePayoutRPCURL enforces the SPEC-016 §4.4 trust-root
// constraints on payout RPC URLs. Closes FULL-r1 [full-sec:r1-1]
// HIGH: an unconstrained RPC URL defeats two-RPC discipline.
//
// MUST:
//   - parse as a URL with a non-empty hostname,
//   - use https (TLS+SPKI pin verification only fires on https),
//   - have NO userinfo (credential URLs leak into logs),
//   - resolve to a non-loopback / non-private / non-link-local /
//     non-unspecified IP if the host is a literal IP (SSRF +
//     internal-pivot defense; hostnames are validated at TLS time
//     via the SPKI pin, which is the runtime trust root).
func validatePayoutRPCURL(name, raw string) (*url.URL, error) {
	u, err := url.Parse(strings.TrimSpace(raw))
	if err != nil || u.Hostname() == "" {
		return nil, fmt.Errorf("%s must be a valid URL with a hostname", name)
	}
	if u.Scheme != "https" {
		return nil, fmt.Errorf("%s must use https (SPEC-016 §4.4 + SPKI pin)", name)
	}
	if u.User != nil {
		return nil, fmt.Errorf("%s must not contain userinfo (credential leak in logs)", name)
	}
	if ip, err := netip.ParseAddr(u.Hostname()); err == nil {
		if ip.IsLoopback() || ip.IsPrivate() || ip.IsLinkLocalUnicast() || ip.IsUnspecified() {
			return nil, fmt.Errorf("%s must not target loopback / private / link-local / unspecified IPs (SSRF defense)", name)
		}
	}
	return u, nil
}

func ValidateEndpointURL(endpoint string) error {
	u, err := url.Parse(endpoint)
	if err != nil || u.Host == "" {
		return fmt.Errorf("endpoint_url must be a valid URL")
	}
	isLocal := u.Hostname() == "127.0.0.1" || u.Hostname() == "localhost"
	if u.Scheme != "https" && !(u.Scheme == "http" && isLocal) {
		return fmt.Errorf("endpoint_url must be a valid https URL")
	}
	return nil
}
