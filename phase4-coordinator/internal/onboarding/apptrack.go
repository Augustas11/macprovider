// Package onboarding implements SPEC-026 App-track provider onboarding.
//
// The primary entry point is HandleAppTrackRegister (SPEC-026 §4.1). The
// full contract is documented in specs/SPEC-026-browserless-provider-onboarding.md.
package onboarding

import (
	"context"
	"crypto/ed25519"
	"crypto/sha256"
	"encoding/base32"
	"encoding/base64"
	"encoding/hex"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"net"
	"net/http"
	"net/netip"
	"strconv"
	"strings"
	"time"

	"github.com/augstar/macprovider-coordinator/internal/auth"
	"github.com/augstar/macprovider-coordinator/internal/billing"
)

// RegisterRequest is the JSON body of POST /v1/providers/register.
// SPEC-026 §4.1. All fields required except AppAttestObject / AppAttestKeyID.
type RegisterRequest struct {
	ProviderID      string          `json:"provider_id"`
	IdentityPubkey  string          `json:"identity_pubkey"` // base64 32-byte Ed25519
	HardwareSummary HardwareSummary `json:"hardware_summary"`
	AppAttestObject *string         `json:"app_attest_object,omitempty"` // base64 CBOR
	AppAttestKeyID  *string         `json:"app_attest_key_id,omitempty"` // base64 32-byte
	Nonce           string          `json:"nonce"`                       // 64-hex = 32 random bytes
	TSUTC           string          `json:"ts_utc"`                      // RFC3339
	Signature       string          `json:"signature"`                   // base64 64-byte Ed25519 over JCS(body\signature)
}

type HardwareSummary struct {
	Chip            string `json:"chip"`
	UnifiedMemoryGB int    `json:"unified_memory_gb"`
	MacOSVersion    string `json:"macos_version"`
	AppVersion      string `json:"app_version"`
}

func (h *HardwareSummary) UnmarshalJSON(body []byte) error {
	var wire struct {
		Chip            string          `json:"chip"`
		UnifiedMemoryGB json.RawMessage `json:"unified_memory_gb"`
		MacOSVersion    string          `json:"macos_version"`
		AppVersion      string          `json:"app_version"`
	}
	if err := json.Unmarshal(body, &wire); err != nil {
		return err
	}
	h.Chip = wire.Chip
	h.MacOSVersion = wire.MacOSVersion
	h.AppVersion = wire.AppVersion
	if len(wire.UnifiedMemoryGB) == 0 || string(wire.UnifiedMemoryGB) == "null" {
		h.UnifiedMemoryGB = 0
		return nil
	}
	var memoryGB int
	if err := json.Unmarshal(wire.UnifiedMemoryGB, &memoryGB); err == nil {
		h.UnifiedMemoryGB = memoryGB
		return nil
	}
	var memoryString string
	if err := json.Unmarshal(wire.UnifiedMemoryGB, &memoryString); err != nil {
		return fmt.Errorf("unified_memory_gb must be a number or numeric string")
	}
	memoryString = strings.TrimSpace(memoryString)
	if memoryString == "" {
		h.UnifiedMemoryGB = 0
		return nil
	}
	parsed, err := strconv.Atoi(memoryString)
	if err != nil {
		return fmt.Errorf("unified_memory_gb must be a number or numeric string")
	}
	h.UnifiedMemoryGB = parsed
	return nil
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
	Attested        bool   `json:"attested"`
	RateLimitBucket string `json:"rate_limit_bucket"`
}

// Handler wires SPEC-026 §4.1 dependencies. Fields are populated at
// coordinator boot when onboarding.app_track_register_enabled is true.
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
	TrustedProxies    []netip.Prefix

	// Rate limiter (SPEC-026 §4.1 step 4)
	IPRateLimiter  IPRateLimiter
	ASNRateLimiter ASNRateLimiter
	ASNResolver    ASNResolver

	// App Attest verification seam. Production verifier validates the
	// Apple attestation object; tests use a fake verifier for replay and
	// outage behavior.
	AppAttestVerifier AppAttestVerifier
	AppAttestConfig   AppAttestConfig

	// Metrics
	Metrics Metrics

	// Clock (test seam)
	Now func() time.Time

	// HardwareProfilePersistSlots bounds optional async hardware writes.
	// Nil uses the process-wide default lane; tests may inject a private lane.
	HardwareProfilePersistSlots chan struct{}
}

// StatsDB is the Postgres-side dependency surface.
type StatsDB interface {
	// UpsertProviderIdentity inserts or updates a provider_identities row.
	// Returns ErrTOFUConflict if a row exists with a different identity_pubkey.
	UpsertProviderIdentity(ctx context.Context, providerID string, identityPubkey []byte, attested bool, appAttestKeyID []byte) error

	// UpsertProviderHardwareProfile persists provider-reported hardware identity
	// for async stats enrichment. This must only run after rate-limit checks pass.
	UpsertProviderHardwareProfile(ctx context.Context, providerID string, summary HardwareSummary, observedAt time.Time) error

	// InsertRegisterNonce records both (provider_id, nonce) and
	// (source_ip, nonce) replay keys with true 65s semantics. Returns
	// ErrNonceReplay when either dimension was seen recently.
	InsertRegisterNonce(ctx context.Context, providerID, sourceIP, nonce string, tsUtc time.Time) error

	// CheckAppAttestKeyIDUnique returns nil if the key ID is not yet
	// bound to a different provider_id; ErrAttestKeyReused otherwise.
	CheckAppAttestKeyIDUnique(ctx context.Context, keyID []byte, providerID string) error
}

// AuthTokenStore is the SQLite-side dependency (existing
// phase4-coordinator/internal/auth/tokens.go).
type AuthTokenStore interface {
	// MintProviderTokenAppTrack mints per SPEC-026 §4.1 step 7 semantics.
	// Duplicate registration with any active token requires bearer proof from
	// the Authorization header; request bodies must never carry bearer material.
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

type ASNResolver interface {
	ResolveASN(ctx context.Context, ip netip.Addr) (asn string, ok bool, err error)
}

type AppAttestConfig struct {
	CoordinatorDomain string
	BundleID          string
	TeamID            string
}

type AppAttestEvidence struct {
	Object         []byte
	KeyID          []byte
	ClientDataHash [32]byte
}

type AppAttestVerifier interface {
	Verify(ctx context.Context, evidence AppAttestEvidence) (bool, error)
}

// Metrics exposes /admin/metrics counters per SPEC-026 §10 step 6.
type Metrics interface {
	IncRegisterRateLimitHit(scope string) // scope = "ip" | "asn"
	IncRegisterSource(track string)       // track = "app" | "cli" | "portal"
	IncRegisterHardwareProfileError()
}

// Sentinel errors surfaced by StatsDB / AuthTokenStore. The HTTP handler
// maps each to the right status per SPEC-026 §4.1.
var (
	ErrTOFUConflict             = errors.New("provider_id already registered with a different identity_pubkey")
	ErrNonceReplay              = errors.New("(provider_id, nonce) replay")
	ErrAttestKeyReused          = errors.New("app_attest_key_id already bound to a different provider_id")
	ErrProviderIDPubkeyMismatch = errors.New("provider_tokens row exists for a different identity_pubkey")
	ErrExistingTokenNoProof     = errors.New("existing active token requires current_token_proof")
	ErrAppAttestBinding         = errors.New("app attest binding failure")
	ErrAppAttestTransient       = errors.New("app attest transient verification failure")
)

const hardwareProfilePersistTimeout = 2 * time.Second
const hardwareProfilePersistConcurrency = 2

var defaultHardwareProfilePersistSlots = make(chan struct{}, hardwareProfilePersistConcurrency)

// HandleAppTrackRegister is the SPEC-026 §4.1 endpoint. Full contract:
// specs/BUILD_SPEC_026_IMPL_STEP_1_COORD_REGISTER_PROMPT.md.
func (h *Handler) HandleAppTrackRegister(w http.ResponseWriter, r *http.Request) {
	if r.Method != http.MethodPost {
		w.Header().Set("Allow", http.MethodPost)
		writeJSONError(w, http.StatusMethodNotAllowed, "method_not_allowed", "method not allowed")
		return
	}
	if h.StatsDB == nil || h.AuthTokenStore == nil {
		writeJSONError(w, http.StatusServiceUnavailable, "unavailable", "onboarding dependencies unavailable")
		return
	}
	body, err := readBoundedBody(w, r, 8*1024)
	if err != nil {
		writeJSONError(w, http.StatusRequestEntityTooLarge, "request_too_large", "body exceeds 8 KiB")
		return
	}
	var raw map[string]any
	if err := json.Unmarshal(body, &raw); err != nil {
		writeJSONError(w, http.StatusBadRequest, "bad_request", "invalid json body")
		return
	}
	if _, ok := raw["current_provider_token"]; ok {
		writeJSONError(w, http.StatusBadRequest, "bearer_proof_in_body", "current_provider_token is not allowed in request body")
		return
	}
	var req RegisterRequest
	if err := json.Unmarshal(body, &req); err != nil {
		writeJSONError(w, http.StatusBadRequest, "bad_request", "invalid request body")
		return
	}

	pubkey, err := DecodeIdentityPubkey(req.IdentityPubkey)
	if err != nil {
		writeJSONError(w, http.StatusBadRequest, "bad_request", "invalid identity_pubkey")
		return
	}
	if want := ProviderIDForIdentityPubkey(pubkey); req.ProviderID != want {
		writeJSONError(w, http.StatusBadRequest, "provider_id_mismatch", "provider_id does not match identity_pubkey")
		return
	}
	if len(req.Nonce) != 64 || !isLowerHex(req.Nonce) {
		writeJSONError(w, http.StatusBadRequest, "bad_request", "nonce must be 64 lowercase hex chars")
		return
	}
	tsUTC, err := time.Parse(time.RFC3339, req.TSUTC)
	if err != nil {
		writeJSONError(w, http.StatusBadRequest, "bad_request", "ts_utc must be RFC3339")
		return
	}
	now := time.Now().UTC()
	if h.Now != nil {
		now = h.Now().UTC()
	}
	if delta := now.Sub(tsUTC); delta > time.Minute || delta < -time.Minute {
		writeJSONError(w, http.StatusBadRequest, "timestamp_skew", "ts_utc outside allowed skew")
		return
	}
	signature, err := base64.StdEncoding.DecodeString(req.Signature)
	if err != nil || len(signature) != ed25519.SignatureSize {
		writeJSONError(w, http.StatusBadRequest, "bad_request", "invalid signature encoding")
		return
	}
	delete(raw, "signature")
	canonical, err := billing.CanonicalJSON(raw)
	if err != nil {
		writeJSONError(w, http.StatusBadRequest, "bad_request", "body is not JCS canonicalizable")
		return
	}
	if !ed25519.Verify(ed25519.PublicKey(pubkey), canonical, signature) {
		writeJSONError(w, http.StatusUnauthorized, "invalid_signature", "signature verification failed")
		return
	}

	sourceIP := clientIP(r, h.TrustedProxies)
	if h.IPRateLimiter != nil && !h.IPRateLimiter.Allow(sourceIP) {
		if h.Metrics != nil {
			h.Metrics.IncRegisterRateLimitHit("ip")
		}
		w.Header().Set("Retry-After", "60")
		writeJSONError(w, http.StatusTooManyRequests, "rate_limited", "ip rate limit exceeded")
		return
	}
	if h.ASNResolver != nil && h.ASNRateLimiter != nil {
		asn := "unknown"
		if addr, ok := parseIPAddr(sourceIP); ok {
			if resolved, ok, err := h.ASNResolver.ResolveASN(r.Context(), addr); err != nil {
				writeJSONError(w, http.StatusInternalServerError, "internal_error", "asn resolver failed")
				return
			} else if ok && strings.TrimSpace(resolved) != "" {
				asn = strings.TrimSpace(resolved)
			}
		}
		if !h.ASNRateLimiter.Allow(asn) {
			if h.Metrics != nil {
				h.Metrics.IncRegisterRateLimitHit("asn")
			}
			w.Header().Set("Retry-After", "60")
			writeJSONError(w, http.StatusTooManyRequests, "rate_limited", "asn rate limit exceeded")
			return
		}
	}
	if err := h.StatsDB.InsertRegisterNonce(r.Context(), req.ProviderID, sourceIP, req.Nonce, now); err != nil {
		if errors.Is(err, ErrNonceReplay) {
			writeJSONError(w, http.StatusConflict, "nonce_replay", "register nonce replay")
			return
		}
		writeJSONError(w, http.StatusInternalServerError, "internal_error", "nonce replay check failed")
		return
	}

	attested := false
	var appAttestKeyID []byte
	if req.AppAttestObject != nil {
		obj, err := base64.StdEncoding.DecodeString(*req.AppAttestObject)
		if err != nil {
			writeJSONError(w, http.StatusBadRequest, "bad_request", "malformed app_attest_object")
			return
		}
		if len(obj) > 4*1024 {
			writeJSONError(w, http.StatusRequestEntityTooLarge, "request_too_large", "app_attest_object exceeds 4 KiB")
			return
		}
		if req.AppAttestKeyID == nil {
			writeJSONError(w, http.StatusBadRequest, "bad_request", "app_attest_key_id is required with app_attest_object")
			return
		}
		appAttestKeyID, err = base64.StdEncoding.DecodeString(*req.AppAttestKeyID)
		if err != nil || len(appAttestKeyID) != 32 {
			writeJSONError(w, http.StatusBadRequest, "bad_request", "invalid app_attest_key_id")
			return
		}
		if err := h.StatsDB.CheckAppAttestKeyIDUnique(r.Context(), appAttestKeyID, req.ProviderID); err != nil {
			if errors.Is(err, ErrAttestKeyReused) {
				writeJSONError(w, http.StatusConflict, "app_attest_key_reused", "app_attest_key_id already bound")
				return
			}
			writeJSONError(w, http.StatusInternalServerError, "internal_error", "app attest key check failed")
			return
		}
		if h.AppAttestVerifier == nil {
			writeJSONError(w, http.StatusBadRequest, "app_attest_unverified", "app attest verifier unavailable")
			return
		}
		if strings.TrimSpace(h.AppAttestConfig.TeamID) == "" || strings.TrimSpace(h.AppAttestConfig.BundleID) == "" {
			writeJSONError(w, http.StatusServiceUnavailable, "app_attest_pin_unconfigured", "app attest team and bundle pins are required")
			return
		}
		verifyCtx, cancelVerify := context.WithTimeout(r.Context(), 2*time.Second)
		ok, err := h.AppAttestVerifier.Verify(verifyCtx, AppAttestEvidence{
			Object:         obj,
			KeyID:          appAttestKeyID,
			ClientDataHash: h.clientDataHash(req),
		})
		cancelVerify()
		switch {
		case err == nil:
			attested = ok
		case errors.Is(err, ErrAppAttestTransient), errors.Is(err, context.Canceled), errors.Is(err, context.DeadlineExceeded):
			attested = false
		case errors.Is(err, ErrAppAttestBinding):
			writeJSONError(w, http.StatusBadRequest, "app_attest_binding_failed", "app attest binding failed")
			return
		default:
			writeJSONError(w, http.StatusBadRequest, "app_attest_invalid", "app attest verification failed")
			return
		}
	}
	if err := h.StatsDB.UpsertProviderIdentity(r.Context(), req.ProviderID, pubkey, attested, appAttestKeyID); err != nil {
		switch {
		case errors.Is(err, ErrTOFUConflict):
			writeJSONError(w, http.StatusConflict, "provider_id_pubkey_mismatch", "provider_id already registered with a different identity_pubkey")
		case errors.Is(err, ErrAttestKeyReused):
			writeJSONError(w, http.StatusConflict, "app_attest_key_reused", "app_attest_key_id already bound")
		default:
			writeJSONError(w, http.StatusInternalServerError, "internal_error", "provider identity upsert failed")
		}
		return
	}
	currentBearer := bearerFromRequest(r)
	token, err := h.AuthTokenStore.MintProviderTokenAppTrack(r.Context(), req.ProviderID, currentBearer)
	if err != nil {
		switch {
		case errors.Is(err, auth.ErrAppTrackExistingTokenNoProof):
			writeJSONError(w, http.StatusConflict, "existing_active_token_no_proof", "existing active token requires proof")
		case errors.Is(err, auth.ErrAppTrackReissueCooldown):
			w.Header().Set("Retry-After", "300")
			writeJSONError(w, http.StatusTooManyRequests, "reissue_cooldown", "provider token reissue cooldown active")
		default:
			writeJSONError(w, http.StatusInternalServerError, "internal_error", "provider token mint failed")
		}
		return
	}
	h.persistHardwareProfileAsync(req.ProviderID, req.HardwareSummary, now)
	if h.Metrics != nil {
		h.Metrics.IncRegisterSource("app")
	}
	writeJSON(w, http.StatusOK, RegisterResponse{
		ProviderID:       req.ProviderID,
		ProviderToken:    token,
		TrustTier:        "provisional",
		Trust:            TrustState{Attested: attested, RateLimitBucket: "new_ip"},
		CoordinatorWSURL: h.CoordinatorWSURL,
	})
}

func (h *Handler) persistHardwareProfileAsync(providerID string, summary HardwareSummary, observedAt time.Time) {
	statsDB := h.StatsDB
	if statsDB == nil {
		return
	}
	if strings.TrimSpace(summary.Chip) == "" {
		return
	}
	metrics := h.Metrics
	slots := h.HardwareProfilePersistSlots
	if slots == nil {
		slots = defaultHardwareProfilePersistSlots
	}
	select {
	case slots <- struct{}{}:
	default:
		if metrics != nil {
			metrics.IncRegisterHardwareProfileError()
		}
		return
	}
	go func() {
		defer func() { <-slots }()
		ctx, cancel := context.WithTimeout(context.Background(), hardwareProfilePersistTimeout)
		defer cancel()
		if err := statsDB.UpsertProviderHardwareProfile(ctx, providerID, summary, observedAt); err != nil && metrics != nil {
			metrics.IncRegisterHardwareProfileError()
		}
	}()
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

func ProviderIDForIdentityPubkey(pubkey []byte) string {
	sum := sha256.Sum256(pubkey)
	return "p_" + strings.ToLower(providerIDBase32Encoding().EncodeToString(sum[:]))
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

func readBoundedBody(w http.ResponseWriter, r *http.Request, max int64) ([]byte, error) {
	r.Body = http.MaxBytesReader(w, r.Body, max+1)
	body, err := io.ReadAll(r.Body)
	if err != nil {
		return nil, err
	}
	if int64(len(body)) > max {
		return nil, fmt.Errorf("body too large")
	}
	return body, nil
}

func (h *Handler) clientDataHash(req RegisterRequest) [32]byte {
	ts := int64(0)
	if parsed, err := time.Parse(time.RFC3339, req.TSUTC); err == nil {
		ts = parsed.UTC().Unix()
	}
	domain := strings.ToLower(strings.TrimSuffix(strings.TrimSpace(h.AppAttestConfig.CoordinatorDomain), "/"))
	if domain == "" {
		domain = strings.ToLower(strings.TrimSuffix(strings.TrimSpace(h.CoordinatorDomain), "/"))
	}
	tuple := map[string]any{
		"provider_id":        req.ProviderID,
		"identity_pubkey":    req.IdentityPubkey,
		"register_nonce":     req.Nonce,
		"coordinator_domain": domain,
		"bundle_id":          h.AppAttestConfig.BundleID,
		"team_id":            h.AppAttestConfig.TeamID,
		"ts_utc":             ts,
	}
	canonical, err := billing.CanonicalJSON(tuple)
	if err != nil {
		return sha256.Sum256(nil)
	}
	return sha256.Sum256(canonical)
}

func bearerFromRequest(r *http.Request) *string {
	raw := strings.TrimSpace(r.Header.Get("Authorization"))
	token, ok := strings.CutPrefix(raw, "Bearer ")
	if !ok {
		return nil
	}
	token = strings.TrimSpace(token)
	if token == "" {
		return nil
	}
	return &token
}

func writeJSON(w http.ResponseWriter, status int, v any) {
	w.Header().Set("Content-Type", "application/json")
	w.WriteHeader(status)
	_ = json.NewEncoder(w).Encode(v)
}

func writeJSONError(w http.ResponseWriter, status int, code, message string) {
	writeJSON(w, status, map[string]any{"error": map[string]any{"code": code, "message": message}})
}

func isLowerHex(s string) bool {
	if _, err := hex.DecodeString(s); err != nil {
		return false
	}
	return strings.ToLower(s) == s
}

func clientIP(r *http.Request, trusted []netip.Prefix) string {
	host, _, err := net.SplitHostPort(r.RemoteAddr)
	if err != nil || host == "" {
		host = r.RemoteAddr
	}
	addr, ok := parseIPAddr(host)
	if !ok || !isTrusted(addr, trusted) {
		return host
	}
	if xff := strings.TrimSpace(r.Header.Get("X-Forwarded-For")); xff != "" {
		if client := rightmostUntrustedXFF(xff, trusted); client != "" {
			return client
		}
	}
	if xrip := strings.TrimSpace(r.Header.Get("X-Real-IP")); xrip != "" {
		if addr, ok := parseIPAddr(xrip); ok {
			return addr.String()
		}
	}
	return host
}

func parseIPAddr(s string) (netip.Addr, bool) {
	addr, err := netip.ParseAddr(strings.TrimSpace(s))
	return addr, err == nil
}

func isTrusted(addr netip.Addr, trusted []netip.Prefix) bool {
	for _, p := range trusted {
		if p.Contains(addr) {
			return true
		}
	}
	return false
}

func rightmostUntrustedXFF(header string, trusted []netip.Prefix) string {
	hops := strings.Split(header, ",")
	for i := len(hops) - 1; i >= 0; i-- {
		host := strings.TrimSpace(hops[i])
		if host == "" {
			continue
		}
		if h, _, err := net.SplitHostPort(host); err == nil {
			host = h
		}
		host = strings.Trim(host, "[]")
		addr, ok := parseIPAddr(host)
		if !ok {
			continue
		}
		if !isTrusted(addr, trusted) {
			return addr.String()
		}
	}
	return ""
}
