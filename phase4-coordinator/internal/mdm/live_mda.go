package mdm

import (
	"context"
	"crypto/sha256"
	"crypto/subtle"
	"crypto/x509"
	"encoding/json"
	"fmt"
	"io"
	"net"
	"net/http"
	"strings"
	"sync"
	"time"

	"github.com/augstar/macprovider-coordinator/internal/config"
	"github.com/augstar/macprovider-coordinator/internal/pool"
	"github.com/augstar/macprovider-coordinator/internal/tier2"
	"github.com/rs/zerolog"
)

// pendingMDARequest binds an enqueued DeviceInformation attestation to the
// coordinator-owned device binding (not SE-asserted serial). SEC-H1 / R2-H1:
// responses must match ExpectedSerial from the trusted binding before SetMDAProof.
type pendingMDARequest struct {
	ProviderID     string
	AssignedID     string
	ExpectedSerial string
	UDID           string
	CommandUUID    string
	SEKeyHash      []byte
	EnqueuedAt     time.Time
}

// TokenValidator validates a provider Bearer token and returns the provider ID.
// Matches auth.Store.ValidateToken.
type TokenValidator interface {
	ValidateToken(ctx context.Context, raw string) (providerID string, ok bool, err error)
}

// LiveMDAService orchestrates Phase 3 live MDA round-trips. It:
//
//  1. Resolves the coordinator-owned device binding for the provider (never
//     selects MicroMDM targets from SE-asserted serial alone — R2-H1).
//  2. Enqueues a DeviceInformation attestation command (raw plist) with
//     nonce=SHA256(SEPublicKey).
//  3. Records a pending request keyed by command_uuid and UDID.
//  4. On MicroMDM command webhook (acknowledge_event) or AttachCachedMDAProof,
//     re-verifies the MDA chain bound to the SE key + binding serial and
//     upgrades the pool entry's attestation tier to "hardware".
//
// The service operates in observe mode: failures are logged but do not interrupt
// provider auth or routing. Do not flip require_attestation here (Phase 4 gate).
type LiveMDAService struct {
	client   *Client
	cfg      config.Tier2Config
	mdmCfg   config.Tier2MDMConfig
	pool     *pool.Registry
	log      zerolog.Logger
	now      func() time.Time
	bindings *DeviceBindingStore
	tokens   TokenValidator

	mu      sync.Mutex
	pending map[string]pendingMDARequest // keyed by UDID and/or command_uuid
}

// NewLiveMDAService creates a LiveMDAService. Returns (nil, nil) when
// LiveMDAEnabled is false. When LiveMDAEnabled is true, APIURL and APIToken
// must both be non-empty (fail-closed); otherwise returns an error.
func NewLiveMDAService(cfg config.Tier2Config, p *pool.Registry, log zerolog.Logger, now func() time.Time) (*LiveMDAService, error) {
	mdmCfg := cfg.MDM
	if !mdmCfg.LiveMDAEnabled {
		return nil, nil
	}
	if strings.TrimSpace(mdmCfg.APIURL) == "" || strings.TrimSpace(mdmCfg.APIToken) == "" {
		return nil, fmt.Errorf("live_mda: api_url and api_token are required when live_mda_enabled")
	}
	client, err := NewClient(ClientConfig{
		BaseURL:  mdmCfg.APIURL,
		APIToken: mdmCfg.APIToken,
	})
	if err != nil {
		return nil, fmt.Errorf("live_mda: create client: %w", err)
	}
	if now == nil {
		now = func() time.Time { return time.Now().UTC() }
	}
	return &LiveMDAService{
		client:   client,
		cfg:      cfg,
		mdmCfg:   mdmCfg,
		pool:     p,
		log:      log,
		now:      now,
		bindings: NewDeviceBindingStore(),
		pending:  make(map[string]pendingMDARequest),
	}, nil
}

// SetTokenValidator wires provider Bearer validation for POST /v1/mdm/device-binding.
func (s *LiveMDAService) SetTokenValidator(v TokenValidator) {
	if s == nil {
		return
	}
	s.tokens = v
}

// Bindings returns the device binding store (for tests / ops introspection).
func (s *LiveMDAService) Bindings() *DeviceBindingStore {
	if s == nil {
		return nil
	}
	return s.bindings
}

// ClaimDevice exclusively binds serial to providerID with enrollment policy:
//
//   - Token-auth path (allowEnrolledUnbound=false): rejects claiming an already-
//     enrolled unbound serial (blocks remote MDA borrow).
//   - Internal/ops path (allowEnrolledUnbound=true): allows first-time bind of
//     already-enrolled fleet devices (H2XX74T43X bootstrap).
//   - Device not yet in MicroMDM: pending claim allowed (UDID filled later).
//   - Same-provider re-claim of own serial is always OK.
func (s *LiveMDAService) ClaimDevice(ctx context.Context, providerID, serial string, allowEnrolledUnbound bool) error {
	if s == nil || s.bindings == nil {
		return fmt.Errorf("mdm: binding store unavailable")
	}
	providerID = strings.TrimSpace(providerID)
	serial = NormalizeSerial(serial)
	if providerID == "" {
		return ErrEmptyProviderID
	}
	if serial == "" {
		return ErrEmptySerial
	}

	if existing, ok := s.bindings.LookupBySerial(serial); ok && existing.ProviderID != providerID {
		return ErrSerialAlreadyBound
	}
	// Same provider already owns this serial — refresh UDID if possible.
	if existing, ok := s.bindings.LookupByProvider(providerID); ok && existing.Serial == serial {
		if existing.UDID == "" && s.client != nil {
			if device, found, err := s.client.FindDeviceBySerial(ctx, serial); err == nil && found && device.UDID != "" {
				s.bindings.SetUDID(serial, device.UDID)
			}
		}
		return nil
	}

	var enrolled bool
	var udid string
	if s.client != nil {
		device, found, err := s.client.FindDeviceBySerial(ctx, serial)
		if err != nil {
			return fmt.Errorf("mdm claim: find device: %w", err)
		}
		if found {
			enrolled = true
			udid = strings.TrimSpace(device.UDID)
		}
	}
	if enrolled {
		if _, bound := s.bindings.LookupBySerial(serial); !bound && !allowEnrolledUnbound {
			return ErrEnrolledUnboundRejected
		}
	}
	if err := s.bindings.Claim(providerID, serial); err != nil {
		return err
	}
	if udid != "" {
		s.bindings.SetUDID(serial, udid)
	}
	return nil
}

// RequestAndMaybeUpgrade is the main Phase 3 observe-mode entry point.
// It should be called in a goroutine (go svc.RequestAndMaybeUpgrade(...))
// after successful SE attestation auth so it never blocks the auth path.
//
// If the provider already has a valid, fresh MDA proof bound to the current SE
// key, the tier is upgraded immediately without a new MDM round-trip. Otherwise
// a DeviceInformation attestation command is enqueued for the *bound* device
// (best-effort) and a pending bind is recorded for webhook ingest.
//
// seSerial is the device serial from SE attestation claims. It is only used as
// a mismatch check against the coordinator-owned binding — never for MicroMDM
// target selection (R2-H1).
func (s *LiveMDAService) RequestAndMaybeUpgrade(providerID, assignedID, seSerial string) {
	ctx, cancel := context.WithTimeout(context.Background(), 30*time.Second)
	defer cancel()

	sePub := s.pool.ProviderSEPublicKey(providerID)
	if len(sePub) == 0 {
		s.log.Debug().
			Str("provider_id", providerID).
			Str("reason", "no_se_key").
			Msg("live_mda: skipping — no SE public key recorded")
		return
	}

	seKeyHash := sha256.Sum256(sePub)

	// 1. Try to upgrade from cached MDA proof.
	if s.tryUpgradeFromCache(ctx, providerID, assignedID, sePub, seKeyHash[:]) {
		return
	}

	// 2. Cache miss or stale — resolve coordinator-owned binding only.
	binding, ok := s.bindings.LookupByProvider(providerID)
	if !ok || binding.Serial == "" {
		s.log.Info().
			Str("provider_id", providerID).
			Str("reason", "no_device_binding").
			Msg("live_mda: cannot enqueue — provider has no claimed device binding")
		return
	}
	if se := strings.TrimSpace(seSerial); se != "" && !serialEqualFold(se, binding.Serial) {
		s.log.Warn().
			Str("provider_id", providerID).
			Str("se_serial", se).
			Str("binding_serial", binding.Serial).
			Msg("live_mda: SE serial does not match device binding — refusing enqueue")
		return
	}

	udid := strings.TrimSpace(binding.UDID)
	if udid == "" {
		device, found, err := s.client.FindDeviceBySerial(ctx, binding.Serial)
		if err != nil {
			s.log.Warn().Err(err).
				Str("provider_id", providerID).
				Str("serial", binding.Serial).
				Msg("live_mda: FindDeviceBySerial for binding failed")
			return
		}
		if !found || strings.TrimSpace(device.UDID) == "" {
			s.log.Info().
				Str("provider_id", providerID).
				Str("serial", binding.Serial).
				Msg("live_mda: bound serial has no MicroMDM UDID yet — skip enqueue")
			return
		}
		udid = strings.TrimSpace(device.UDID)
		s.bindings.SetUDID(binding.Serial, udid)
		if sn := strings.TrimSpace(device.SerialNumber); sn != "" {
			binding.Serial = NormalizeSerial(sn)
		}
	}

	commandUUID, err := s.client.EnqueueDeviceInformationAttestation(ctx, udid, seKeyHash[:])
	if err != nil {
		s.log.Warn().Err(err).
			Str("provider_id", providerID).
			Str("udid", udid).
			Msg("live_mda: EnqueueDeviceInformationAttestation failed (best-effort, ignoring)")
		return
	}

	s.recordPending(udid, commandUUID, pendingMDARequest{
		ProviderID:     providerID,
		AssignedID:     assignedID,
		ExpectedSerial: binding.Serial,
		UDID:           udid,
		CommandUUID:    commandUUID,
		SEKeyHash:      append([]byte(nil), seKeyHash[:]...),
		EnqueuedAt:     s.now(),
	})

	s.log.Info().
		Str("provider_id", providerID).
		Str("udid", udid).
		Str("serial", binding.Serial).
		Str("command_uuid", commandUUID).
		Msg("live_mda: DeviceInformation attestation command enqueued (awaiting webhook)")
}

// AttachCachedMDAProof attempts to re-verify and attach a cached MDA proof for
// providerID on reconnect. Call this after SE attestation succeeds so that a
// provider whose MDA chain was verified in a prior session immediately gets
// hardware tier without waiting for a new MDM round-trip.
//
// Returns true when the proof was attached and the tier upgraded.
func (s *LiveMDAService) AttachCachedMDAProof(providerID, assignedID string) bool {
	sePub := s.pool.ProviderSEPublicKey(providerID)
	if len(sePub) == 0 {
		return false
	}
	seKeyHash := sha256.Sum256(sePub)
	return s.tryUpgradeFromCache(context.Background(), providerID, assignedID, sePub, seKeyHash[:])
}

// UpgradeFromParsedAttestation verifies a fresh DeviceAttestationResult (from
// ParseDeviceAttestationFromPlist) against the provider's SE key and upgrades
// the pool entry on success. Returns true when the tier was upgraded.
//
// Prefer HandleMDACommandWebhook for production ingest — it enforces the
// pending UDID→serial bind (SEC-H1). Direct callers must already know the
// provider identity; this path does not trust SE-asserted serial alone.
func (s *LiveMDAService) UpgradeFromParsedAttestation(providerID, assignedID string, result *DeviceAttestationResult) bool {
	if result == nil {
		s.log.Warn().Str("provider_id", providerID).Msg("live_mda: upgrade failed — nil DeviceAttestationResult")
		return false
	}
	sePub := s.pool.ProviderSEPublicKey(providerID)
	if len(sePub) == 0 {
		s.log.Warn().Str("provider_id", providerID).Msg("live_mda: upgrade failed — no SE key")
		return false
	}
	seKeyHash := sha256.Sum256(sePub)
	if len(result.CertificateChain) == 0 {
		s.log.Warn().Str("provider_id", providerID).Msg("live_mda: empty certificate chain")
		return false
	}
	return s.verifyAndUpgrade(providerID, assignedID, result.CertificateChain, sePub, seKeyHash[:])
}

// HandleDeviceBinding is POST /v1/mdm/device-binding — provider Bearer auth.
// Body: {"serial_number":"..."}. Rejects enrolled-unbound claims (R2-H1).
func (s *LiveMDAService) HandleDeviceBinding(w http.ResponseWriter, r *http.Request) {
	if r.Method != http.MethodPost {
		http.Error(w, "method not allowed", http.StatusMethodNotAllowed)
		return
	}
	if s.tokens == nil {
		http.Error(w, "token validation unavailable", http.StatusServiceUnavailable)
		return
	}
	raw := bearerFromAuthorization(r.Header.Get("Authorization"))
	if raw == "" {
		http.Error(w, "unauthorized", http.StatusUnauthorized)
		return
	}
	providerID, ok, err := s.tokens.ValidateToken(r.Context(), raw)
	if err != nil || !ok || strings.TrimSpace(providerID) == "" {
		http.Error(w, "unauthorized", http.StatusUnauthorized)
		return
	}
	body, err := io.ReadAll(io.LimitReader(r.Body, 4<<10))
	if err != nil {
		http.Error(w, "bad request", http.StatusBadRequest)
		return
	}
	var req struct {
		SerialNumber string `json:"serial_number"`
	}
	if err := json.Unmarshal(body, &req); err != nil {
		http.Error(w, "invalid json", http.StatusBadRequest)
		return
	}
	if err := s.ClaimDevice(r.Context(), providerID, req.SerialNumber, false); err != nil {
		writeClaimError(w, err)
		return
	}
	b, _ := s.bindings.LookupByProvider(providerID)
	w.Header().Set("Content-Type", "application/json")
	w.WriteHeader(http.StatusOK)
	_ = json.NewEncoder(w).Encode(map[string]string{
		"provider_id":   providerID,
		"serial_number": b.Serial,
		"udid":          b.UDID,
	})
}

// HandleInternalDeviceBinding is POST /internal/mdm/device-binding — ops
// bootstrap with the same webhook secret / loopback gate as command-webhook.
// Body: {"provider_id":"...","serial_number":"..."}. Allows enrolled-unbound
// first claim (fleet bootstrap).
func (s *LiveMDAService) HandleInternalDeviceBinding(w http.ResponseWriter, r *http.Request) {
	if r.Method != http.MethodPost {
		http.Error(w, "method not allowed", http.StatusMethodNotAllowed)
		return
	}
	if !s.authorizeWebhook(r) {
		s.log.Warn().Str("remote", r.RemoteAddr).Msg("live_mda: internal binding rejected — auth failed")
		http.Error(w, "forbidden", http.StatusForbidden)
		return
	}
	body, err := io.ReadAll(io.LimitReader(r.Body, 4<<10))
	if err != nil {
		http.Error(w, "bad request", http.StatusBadRequest)
		return
	}
	var req struct {
		ProviderID   string `json:"provider_id"`
		SerialNumber string `json:"serial_number"`
	}
	if err := json.Unmarshal(body, &req); err != nil {
		http.Error(w, "invalid json", http.StatusBadRequest)
		return
	}
	if err := s.ClaimDevice(r.Context(), req.ProviderID, req.SerialNumber, true); err != nil {
		writeClaimError(w, err)
		return
	}
	b, _ := s.bindings.LookupByProvider(strings.TrimSpace(req.ProviderID))
	w.Header().Set("Content-Type", "application/json")
	w.WriteHeader(http.StatusOK)
	_ = json.NewEncoder(w).Encode(map[string]string{
		"provider_id":   b.ProviderID,
		"serial_number": b.Serial,
		"udid":          b.UDID,
	})
}

func writeClaimError(w http.ResponseWriter, err error) {
	switch err {
	case ErrSerialAlreadyBound:
		http.Error(w, err.Error(), http.StatusConflict)
	case ErrEnrolledUnboundRejected:
		http.Error(w, err.Error(), http.StatusForbidden)
	case ErrEmptySerial, ErrEmptyProviderID:
		http.Error(w, err.Error(), http.StatusBadRequest)
	default:
		http.Error(w, err.Error(), http.StatusBadRequest)
	}
}

func bearerFromAuthorization(h string) string {
	const prefix = "Bearer "
	trimmed := strings.TrimSpace(h)
	if !strings.HasPrefix(trimmed, prefix) {
		return ""
	}
	return strings.TrimSpace(trimmed[len(prefix):])
}

// HandleMDACommandWebhook is the MicroMDM command-webhook receiver. Point
// MicroMDM `-command-webhook-url` at this path (default
// `/internal/mdm/command-webhook` on the provider listener).
//
// Auth: if tier2.mdm.command_webhook_secret is set, require matching
// X-MDM-Webhook-Secret header; otherwise require a loopback remote address.
//
// Primary body shape: topic=mdm.Connect + acknowledge_event with base64
// raw_payload plist (R2-H3). Legacy flat JSON DeviceAttestation remains as
// secondary compat.
func (s *LiveMDAService) HandleMDACommandWebhook(w http.ResponseWriter, r *http.Request) {
	if r.Method != http.MethodPost {
		http.Error(w, "method not allowed", http.StatusMethodNotAllowed)
		return
	}
	if !s.authorizeWebhook(r) {
		s.log.Warn().Str("remote", r.RemoteAddr).Msg("live_mda: webhook rejected — auth failed")
		http.Error(w, "forbidden", http.StatusForbidden)
		return
	}
	body, err := io.ReadAll(io.LimitReader(r.Body, 1<<20))
	if err != nil {
		http.Error(w, "bad request", http.StatusBadRequest)
		return
	}
	parsed, err := ParseAcknowledgeEvent(body)
	if err != nil {
		s.log.Warn().Err(err).Msg("live_mda: webhook parse failed")
		http.Error(w, "parse failed", http.StatusBadRequest)
		return
	}
	udid := strings.TrimSpace(parsed.UDID)
	commandUUID := strings.TrimSpace(parsed.CommandUUID)
	if udid == "" && commandUUID == "" {
		s.log.Warn().Msg("live_mda: webhook missing UDID and command_uuid")
		http.Error(w, "udid required", http.StatusBadRequest)
		return
	}
	pending, ok := s.takePending(commandUUID, udid)
	if !ok {
		s.log.Info().
			Str("udid", udid).
			Str("command_uuid", commandUUID).
			Msg("live_mda: webhook ignored — no pending request")
		w.WriteHeader(http.StatusNoContent)
		return
	}
	if parsed.Result == nil || len(parsed.Result.CertificateChain) == 0 {
		s.log.Warn().
			Str("udid", udid).
			Str("provider_id", pending.ProviderID).
			Msg("live_mda: webhook DeviceAttestation missing")
		s.recordPending(pending.UDID, pending.CommandUUID, pending)
		http.Error(w, "no device attestation", http.StatusBadRequest)
		return
	}
	result := parsed.Result
	leaf, err := x509.ParseCertificate(result.CertificateChain[0])
	if err != nil {
		s.log.Warn().Err(err).Str("udid", udid).Msg("live_mda: webhook leaf parse failed")
		s.recordPending(pending.UDID, pending.CommandUUID, pending)
		http.Error(w, "bad leaf", http.StatusBadRequest)
		return
	}
	mdaSerial := tier2.ExtractMDASerialNumber(leaf)
	if mdaSerial == "" {
		s.log.Warn().
			Str("udid", udid).
			Str("provider_id", pending.ProviderID).
			Msg("live_mda: webhook rejected — MDA leaf missing serial number extension")
		http.Error(w, "serial missing", http.StatusForbidden)
		return
	}
	if !serialEqualFold(mdaSerial, pending.ExpectedSerial) {
		s.log.Warn().
			Str("udid", udid).
			Str("provider_id", pending.ProviderID).
			Str("expected_serial", pending.ExpectedSerial).
			Str("mda_serial", mdaSerial).
			Msg("live_mda: webhook rejected — MDA serial does not match enrolled device (possible serial borrow)")
		http.Error(w, "serial mismatch", http.StatusForbidden)
		return
	}
	sePub := s.pool.ProviderSEPublicKey(pending.ProviderID)
	if len(sePub) == 0 {
		s.log.Warn().Str("provider_id", pending.ProviderID).Msg("live_mda: webhook upgrade skipped — provider offline / no SE key")
		s.recordPending(pending.UDID, pending.CommandUUID, pending)
		w.WriteHeader(http.StatusAccepted)
		return
	}
	seKeyHash := sha256.Sum256(sePub)
	if len(pending.SEKeyHash) > 0 && subtle.ConstantTimeCompare(pending.SEKeyHash, seKeyHash[:]) != 1 {
		s.log.Warn().
			Str("provider_id", pending.ProviderID).
			Msg("live_mda: webhook rejected — SE key rotated since enqueue")
		http.Error(w, "se key mismatch", http.StatusForbidden)
		return
	}
	if !s.verifyAndUpgrade(pending.ProviderID, pending.AssignedID, result.CertificateChain, sePub, seKeyHash[:]) {
		s.log.Warn().
			Str("provider_id", pending.ProviderID).
			Str("udid", udid).
			Msg("live_mda: webhook chain verify/upgrade failed")
		http.Error(w, "verify failed", http.StatusUnprocessableEntity)
		return
	}
	s.log.Info().
		Str("provider_id", pending.ProviderID).
		Str("udid", udid).
		Str("serial", mdaSerial).
		Str("command_uuid", commandUUID).
		Msg("live_mda: webhook upgrade succeeded")
	w.WriteHeader(http.StatusNoContent)
}

func (s *LiveMDAService) authorizeWebhook(r *http.Request) bool {
	secret := strings.TrimSpace(s.mdmCfg.CommandWebhookSecret)
	if secret != "" {
		got := strings.TrimSpace(r.Header.Get("X-MDM-Webhook-Secret"))
		if got == "" || subtle.ConstantTimeCompare([]byte(got), []byte(secret)) != 1 {
			return false
		}
		return true
	}
	host, _, err := net.SplitHostPort(r.RemoteAddr)
	if err != nil {
		host = r.RemoteAddr
	}
	ip := net.ParseIP(host)
	return ip != nil && ip.IsLoopback()
}

func (s *LiveMDAService) recordPending(udid, commandUUID string, req pendingMDARequest) {
	udid = strings.TrimSpace(udid)
	commandUUID = strings.TrimSpace(commandUUID)
	if udid == "" && commandUUID == "" {
		return
	}
	if req.UDID == "" {
		req.UDID = udid
	}
	if req.CommandUUID == "" {
		req.CommandUUID = commandUUID
	}
	s.mu.Lock()
	defer s.mu.Unlock()
	if s.pending == nil {
		s.pending = make(map[string]pendingMDARequest)
	}
	if udid != "" {
		s.pending[udid] = req
	}
	if commandUUID != "" {
		s.pending[commandUUID] = req
	}
}

func (s *LiveMDAService) takePending(commandUUID, udid string) (pendingMDARequest, bool) {
	s.mu.Lock()
	defer s.mu.Unlock()
	commandUUID = strings.TrimSpace(commandUUID)
	udid = strings.TrimSpace(udid)
	var req pendingMDARequest
	var ok bool
	if commandUUID != "" {
		req, ok = s.pending[commandUUID]
	}
	if !ok && udid != "" {
		req, ok = s.pending[udid]
	}
	if !ok {
		return pendingMDARequest{}, false
	}
	// Remove all aliases for this pending request.
	if req.CommandUUID != "" {
		delete(s.pending, req.CommandUUID)
	}
	if req.UDID != "" {
		delete(s.pending, req.UDID)
	}
	if commandUUID != "" {
		delete(s.pending, commandUUID)
	}
	if udid != "" {
		delete(s.pending, udid)
	}
	return req, true
}

func extractWebhookUDID(body []byte) string {
	var flat map[string]json.RawMessage
	if err := json.Unmarshal(body, &flat); err != nil {
		return ""
	}
	for _, key := range []string{"udid", "UDID"} {
		if raw, ok := flat[key]; ok {
			var s string
			if json.Unmarshal(raw, &s) == nil && strings.TrimSpace(s) != "" {
				return strings.TrimSpace(s)
			}
		}
	}
	if raw, ok := flat["payload"]; ok {
		var nested map[string]json.RawMessage
		if json.Unmarshal(raw, &nested) == nil {
			for _, key := range []string{"udid", "UDID"} {
				if v, ok := nested[key]; ok {
					var s string
					if json.Unmarshal(v, &s) == nil && strings.TrimSpace(s) != "" {
						return strings.TrimSpace(s)
					}
				}
			}
		}
	}
	if raw, ok := flat["acknowledge_event"]; ok {
		var nested map[string]json.RawMessage
		if json.Unmarshal(raw, &nested) == nil {
			for _, key := range []string{"udid", "UDID"} {
				if v, ok := nested[key]; ok {
					var s string
					if json.Unmarshal(v, &s) == nil && strings.TrimSpace(s) != "" {
						return strings.TrimSpace(s)
					}
				}
			}
		}
	}
	return ""
}

func serialEqualFold(a, b string) bool {
	return strings.EqualFold(strings.TrimSpace(a), strings.TrimSpace(b))
}

// tryUpgradeFromCache checks whether the pool already holds a valid, fresh MDA
// proof bound to the current SE key. Returns true and upgrades if so.
// On expiry or failed re-verification, clears the proof and downgrades
// hardware → self_signed (ARCH-M2).
func (s *LiveMDAService) tryUpgradeFromCache(ctx context.Context, providerID, assignedID string, sePub, seKeyHash []byte) bool {
	_ = ctx
	chain, verifiedAt, boundHash, ok := s.pool.MDAProof(providerID)
	if !ok || len(chain) == 0 {
		return false
	}
	// Verify SE key hasn't rotated since the proof was bound.
	if subtle.ConstantTimeCompare(boundHash, seKeyHash) != 1 {
		s.log.Info().Str("provider_id", providerID).Msg("live_mda: SE key rotated — clearing stale MDA proof")
		s.pool.ClearMDAProof(providerID, assignedID)
		return false
	}
	// Verify proof is within the refresh interval.
	refreshInterval := time.Duration(s.mdmRefreshIntervalHours()) * time.Hour
	age := s.now().Sub(verifiedAt)
	if age > refreshInterval {
		s.log.Info().
			Str("provider_id", providerID).
			Dur("age", age).
			Dur("limit", refreshInterval).
			Msg("live_mda: cached MDA proof expired — clearing and will re-request")
		s.pool.ClearMDAProof(providerID, assignedID)
		return false
	}
	// Re-verify chain freshness in-process without a new MDM round-trip.
	if !s.verifyAndUpgrade(providerID, assignedID, chain, sePub, seKeyHash) {
		s.log.Info().Str("provider_id", providerID).Msg("live_mda: cached MDA re-verify failed — clearing proof")
		s.pool.ClearMDAProof(providerID, assignedID)
		return false
	}
	return true
}

// verifyAndUpgrade verifies the certificate chain against configured roots and
// the SE public key freshness, then upgrades the pool entry's attestation tier.
func (s *LiveMDAService) verifyAndUpgrade(providerID, assignedID string, chain [][]byte, sePub, seKeyHash []byte) bool {
	if len(chain) == 0 {
		return false
	}
	// Check leaf certificate expiry before doing expensive chain verify.
	leaf, err := x509.ParseCertificate(chain[0])
	if err != nil {
		s.log.Warn().Err(err).Str("provider_id", providerID).Msg("live_mda: parse leaf certificate failed")
		return false
	}
	now := s.now()
	if now.After(leaf.NotAfter) {
		s.log.Info().Str("provider_id", providerID).Msg("live_mda: cached MDA leaf certificate expired")
		return false
	}

	ok, seKeyUsed := tier2.VerifyMDACertChainWithSEKey(chain, s.cfg, sePub, now, s.log)
	if !ok || !seKeyUsed {
		s.log.Info().
			Str("provider_id", providerID).
			Bool("chain_ok", ok).
			Bool("se_key_used", seKeyUsed).
			Msg("live_mda: chain re-verify failed")
		return false
	}

	h := sha256.Sum256(sePub)
	if len(seKeyHash) > 0 && subtle.ConstantTimeCompare(h[:], seKeyHash) != 1 {
		// Defensive: caller-supplied hash must match current SE key.
		s.log.Warn().Str("provider_id", providerID).Msg("live_mda: seKeyHash mismatch")
		return false
	}
	if !s.pool.SetMDAProof(providerID, assignedID, chain, h[:], now) {
		s.log.Warn().Str("provider_id", providerID).Msg("live_mda: SetMDAProof: provider not found (reconnect race?)")
		return false
	}
	s.log.Info().
		Str("provider_id", providerID).
		Str("attestation_tier", pool.AttestationTierHardware).
		Msg("live_mda: attestation_tier upgraded to hardware")
	return true
}

func (s *LiveMDAService) mdmRefreshIntervalHours() int {
	h := s.mdmCfg.MDARefreshIntervalHours
	if h <= 0 {
		return 168 // default 7 days when unset
	}
	if h < 24 {
		return 24 // floor per docs
	}
	return h
}
