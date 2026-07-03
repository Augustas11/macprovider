// Package onboarding implements SPEC-026 v0.11 App-track provider onboarding.
//
// The primary entry point is HandleAppTrackRegister (SPEC-026 §4.1). The
// full contract is documented in the spec + BUILD prompt at
// specs/BUILD_SPEC_026_IMPL_STEP_1_COORD_REGISTER_PROMPT.md — the
// implementation body of the handler is intentionally left as a
// stub in this scaffold PR; codex fills it in via the audit-loop pass.
package onboarding

import (
	"context"
	"encoding/base32"
	"encoding/base64"
	"errors"
	"net/http"
	"strings"
	"time"
)

// RegisterRequest is the JSON body of POST /v1/providers/register.
// SPEC-026 §4.1. All fields required except AppAttestObject / AppAttestKeyID.
type RegisterRequest struct {
	ProviderID       string          `json:"provider_id"`
	IdentityPubkey   string          `json:"identity_pubkey"`   // base64 32-byte Ed25519
	HardwareSummary  HardwareSummary `json:"hardware_summary"`
	AppAttestObject  *string         `json:"app_attest_object,omitempty"`  // base64 CBOR
	AppAttestKeyID   *string         `json:"app_attest_key_id,omitempty"`  // base64 32-byte
	Nonce            string          `json:"nonce"`             // 64-hex = 32 random bytes
	TSUTC            string          `json:"ts_utc"`            // RFC3339
	Signature        string          `json:"signature"`         // base64 64-byte Ed25519 over JCS(body\signature)
}

type HardwareSummary struct {
	Chip             string `json:"chip"`
	UnifiedMemoryGB  int    `json:"unified_memory_gb"`
	MacOSVersion     string `json:"macos_version"`
	AppVersion       string `json:"app_version"`
}

// RegisterResponse is the 200 body. SPEC-026 §4.1 step 8.
type RegisterResponse struct {
	ProviderID       string     `json:"provider_id"`
	ProviderToken    string     `json:"provider_token"`
	TrustTier        string     `json:"trust_tier"` // always "provisional" at register time
	Trust            TrustState `json:"trust"`
	CoordinatorWSURL string     `json:"coordinator_ws_url"`
}

type TrustState struct {
	Attested         bool   `json:"attested"`
	RateLimitBucket  string `json:"rate_limit_bucket"`
}

// Handler wires SPEC-026 §4.1 dependencies. Concrete impl to follow the
// BUILD prompt. Fields populated at coordinator boot.
type Handler struct {
	// Postgres stats DB — for provider_identities, provider_auth_policy,
	// nonce replay cache, App Attest key uniqueness.
	StatsDB StatsDB

	// SQLite auth DB — for provider_tokens mint. Reuses existing
	// phase4-coordinator/internal/auth store.
	AuthTokenStore AuthTokenStore

	// Coordinator config
	CoordinatorDomain string
	CoordinatorWSURL  string

	// Rate limiter (SPEC-026 §4.1 step 4)
	IPRateLimiter  IPRateLimiter
	ASNRateLimiter ASNRateLimiter

	// Metrics
	Metrics Metrics

	// Clock (test seam)
	Now func() time.Time
}

// StatsDB is the Postgres-side dependency surface.
type StatsDB interface {
	// UpsertProviderIdentity inserts or updates a provider_identities row.
	// Returns ErrTOFUConflict if a row exists with a different identity_pubkey.
	UpsertProviderIdentity(ctx context.Context, providerID string, identityPubkey []byte, attested bool, appAttestKeyID []byte) error

	// InsertRegisterNonce records (provider_id, nonce, ts_utc_bucket)
	// with a 65s TTL. Returns ErrNonceReplay on duplicate.
	InsertRegisterNonce(ctx context.Context, providerID string, nonce string, tsUtc time.Time) error

	// CheckAppAttestKeyIDUnique returns nil if the key ID is not yet
	// bound to a different provider_id; ErrAttestKeyReused otherwise.
	CheckAppAttestKeyIDUnique(ctx context.Context, keyID []byte, providerID string) error
}

// AuthTokenStore is the SQLite-side dependency (existing
// phase4-coordinator/internal/auth/tokens.go).
type AuthTokenStore interface {
	// MintProviderTokenAppTrack mints per SPEC-026 §4.1 step 7 semantics:
	// same-identity_pubkey duplicate register rotates the token; different
	// identity_pubkey rejects with ErrProviderIDPubkeyMismatch.
	//
	// The `current_provider_token` bearer-proof path is enforced against
	// last_used_at IS NOT NULL rows: caller must pass the raw cleartext
	// so this store can SHA-256 hash and compare against token_hash.
	//
	// provider_name is the tenant literal "malibu-app" for App-track.
	MintProviderTokenAppTrack(ctx context.Context, providerID string, currentBearer *string) (cleartext string, err error)
}

// IPRateLimiter and ASNRateLimiter both wrap the coordinator's existing
// rate-limit infrastructure. SPEC-026 §4.1 step 4: 5/min/IP, 30/min/ASN.
type IPRateLimiter interface {
	Allow(ip string) bool
}
type ASNRateLimiter interface {
	Allow(asn string) bool
}

// Metrics exposes /admin/metrics counters per SPEC-026 §10 step 6.
type Metrics interface {
	IncRegisterRateLimitHit(scope string) // scope = "ip" | "asn"
	IncRegisterSource(track string)       // track = "app" | "cli" | "portal"
}

// Sentinel errors surfaced by StatsDB / AuthTokenStore. The HTTP handler
// maps each to the right status per SPEC-026 §4.1.
var (
	ErrTOFUConflict            = errors.New("provider_id already registered with a different identity_pubkey")
	ErrNonceReplay             = errors.New("(provider_id, nonce) replay")
	ErrAttestKeyReused         = errors.New("app_attest_key_id already bound to a different provider_id")
	ErrProviderIDPubkeyMismatch = errors.New("provider_tokens row exists for a different identity_pubkey")
	ErrExistingTokenNoProof    = errors.New("existing active token requires current_token_proof")
)

// HandleAppTrackRegister is the SPEC-026 §4.1 endpoint.
//
// IMPLEMENTER: This scaffold intentionally leaves the handler body as a
// stub. Fill in per the ordered steps in SPEC-026 §4.1:
//   1. Parse + size-gate request (≤ 8 KiB body, ≤ 4 KiB app_attest_object).
//   2. Verify provider_id == "p_" + base32_lc(sha256(identity_pubkey)) — 400 on mismatch.
//   3. Verify Ed25519 signature under identity_pubkey over JCS(body\signature) — 401 on failure.
//   4. Reject |now - ts_utc| > 60s (400) or replayed (provider_id, nonce) (409). See SPEC-026 §4.1 step 3.
//   5. Rate limit per-IP 5/min and per-ASN 30/min — 429 with Retry-After.
//   6. If app_attest_object present: verify against Apple root using clientDataHash
//      binding from SPEC-026 §5.3, then check app_attest_key_id uniqueness.
//   7. Upsert into provider_identities. TOFU conflict → 409.
//   8. Mint provider_token via AuthTokenStore.MintProviderTokenAppTrack.
//      Handle current_token_proof for last_used_at IS NOT NULL rows.
//   9. Emit metrics.IncRegisterSource("app").
//  10. Return 200 with RegisterResponse.
//
// Full contract: SPEC-026 v0.11 §4.1 lines ~700-810 in
// specs/SPEC-026-browserless-provider-onboarding.md.
//
// JCS canonicalization: phase4-coordinator/internal/billing.CanonicalJSON
// (mirror parity fixture at phase4-coordinator/test/jcs_fixtures/spec026_register.json
// per SPEC-026 §10 step 2).
func (h *Handler) HandleAppTrackRegister(w http.ResponseWriter, r *http.Request) {
	// SCAFFOLD: not yet implemented; codex fills in the ordered steps.
	http.Error(w, "SPEC-026 §4.1 handler not yet implemented; see BUILD prompt", http.StatusNotImplemented)
}

// Base32AlphabetLowercase is RFC 4648 §6 lowercased, no padding.
// SPEC-026 §3.3. Both Swift (RFC8785JCS-adjacent helper) and this Go side
// MUST use the same alphabet byte-for-byte; parity fixture verifies.
const Base32AlphabetLowercase = "abcdefghijklmnopqrstuvwxyz234567"

// providerIDBase32Encoding returns the canonical no-pad encoder for
// SPEC-026 provider_id derivation.
func providerIDBase32Encoding() *base32.Encoding {
	return base32.NewEncoding(Base32AlphabetLowercase).WithPadding(base32.NoPadding)
}

// DecodeIdentityPubkey parses the base64-encoded 32-byte Ed25519 public key
// from the JSON body. Returns an error on wrong length.
func DecodeIdentityPubkey(s string) ([]byte, error) {
	b, err := base64.StdEncoding.DecodeString(s)
	if err != nil {
		return nil, err
	}
	if len(b) != 32 {
		return nil, errors.New("identity_pubkey must be 32 bytes")
	}
	return b, nil
}

// IsAppTrackProviderID returns true if the given provider_id is
// App-track (starts with "p_"). Cross-track auth policy in
// provider_auth_policy uses this to tag the row's `kind` column.
func IsAppTrackProviderID(providerID string) bool {
	return strings.HasPrefix(providerID, "p_")
}
