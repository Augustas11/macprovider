package mdm

import (
	"context"
	"crypto/sha256"
	"crypto/subtle"
	"crypto/x509"
	"encoding/hex"
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
	"github.com/google/uuid"
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

// enqueueLedgerEntry is the in-memory view of per-key DeviceInformation
// enqueue rate limits (R3-M3). Keyed by provider|serial|hex(se_key_hash).
type enqueueLedgerEntry struct {
	LastEnqueueAt      time.Time
	PendingCommandUUID string
	TerminalOutcome    string // "" | "success" | "failed"
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
//     nonce=SHA256(SEPublicKey), rate-limited per R3-M3.
//  3. Records a pending request keyed by command_uuid and UDID.
//  4. On MicroMDM command webhook (acknowledge_event) or AttachCachedMDAProof,
//     re-verifies the MDA chain bound to the SE key + binding serial and
//     upgrades the pool entry's attestation tier to "hardware".
//  5. Persists verified proofs in MDAStore for reconnect/restart (R3-M2).
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
	store    *MDAStore

	mu           sync.Mutex
	pending      map[string]pendingMDARequest // keyed by UDID and/or command_uuid
	ledger       map[string]enqueueLedgerEntry
	enqueueMu    sync.Mutex
	enqueueLocks map[string]*sync.Mutex // per ledger-key reservation locks (R4-M4)
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
		ledger:   make(map[string]enqueueLedgerEntry),
	}, nil
}

// SetMDAStore wires durable MDA proof, enqueue ledger, pending correlation,
// and device binding persistence (R3-M2/M3, R4-M1/M2). Hydrates bindings.
func (s *LiveMDAService) SetMDAStore(store *MDAStore) {
	if s == nil {
		return
	}
	s.store = store
	s.hydrateBindings(context.Background())
}

func (s *LiveMDAService) hydrateBindings(ctx context.Context) {
	if s.store == nil || s.bindings == nil {
		return
	}
	recs, err := s.store.LoadAllBindings(ctx)
	if err != nil {
		s.log.Warn().Err(err).Msg("live_mda: durable binding hydrate failed")
		return
	}
	for _, rec := range recs {
		if err := s.bindings.Restore(Binding{
			ProviderID: rec.ProviderID,
			Serial:     rec.Serial,
			UDID:       rec.UDID,
			ClaimedAt:  rec.ClaimedAt,
		}); err != nil {
			s.log.Warn().Err(err).
				Str("provider_id", rec.ProviderID).
				Str("serial", rec.Serial).
				Msg("live_mda: durable binding restore skipped")
		}
	}
	if len(recs) > 0 {
		s.log.Info().Int("count", len(recs)).Msg("live_mda: hydrated durable device bindings")
	}
}

func (s *LiveMDAService) persistBinding(providerID string) {
	if s == nil || s.store == nil || s.bindings == nil {
		return
	}
	b, ok := s.bindings.LookupByProvider(providerID)
	if !ok {
		return
	}
	if err := s.store.SaveBinding(context.Background(), DeviceBindingRecord{
		ProviderID: b.ProviderID,
		Serial:     b.Serial,
		UDID:       b.UDID,
		ClaimedAt:  b.ClaimedAt,
	}); err != nil {
		s.log.Warn().Err(err).Str("provider_id", providerID).Msg("live_mda: durable binding save failed")
	}
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
//   - R3-H1: neither path may create a new binding for a serial that is not
//     already enrolled in MicroMDM (no pending UDID-empty squat).
//   - R4-M3: enrolled means EnrollmentStatus==true AND non-empty UDID.
//   - Token-auth path (allowEnrolledUnbound=false): rejects enrolled-unbound
//     new claims (ErrEnrolledUnboundRejected). May refresh UDID on an existing
//     same-provider binding.
//   - Internal/ops path (allowEnrolledUnbound=true): creates the first binding
//     only for already-enrolled devices (fleet bootstrap).
//   - Same-provider re-claim / UDID refresh of an existing binding is always OK.
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
			if device, found, err := s.client.FindDeviceBySerial(ctx, serial); err == nil && found && isEnrolledDevice(device) {
				s.bindings.SetUDID(serial, device.UDID)
				s.persistBinding(providerID)
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
		if found && isEnrolledDevice(device) {
			enrolled = true
			udid = strings.TrimSpace(device.UDID)
		}
	}
	// R3-H1 / R4-M3: never create a pending or unenrolled binding.
	if !enrolled {
		return ErrPendingClaimRejected
	}
	if _, bound := s.bindings.LookupBySerial(serial); !bound && !allowEnrolledUnbound {
		return ErrEnrolledUnboundRejected
	}
	if err := s.bindings.Claim(providerID, serial); err != nil {
		return err
	}
	if udid != "" {
		s.bindings.SetUDID(serial, udid)
	}
	s.persistBinding(providerID)
	return nil
}

// isEnrolledDevice is true only when MicroMDM reports enrollment_status and a UDID (R4-M3).
func isEnrolledDevice(d Device) bool {
	return d.EnrollmentStatus && strings.TrimSpace(d.UDID) != ""
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

	// 0. Hydrate durable cache into pool (bytes only — no hardware tier).
	s.hydrateDurableProof(ctx, providerID, assignedID)

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
		if !found || !isEnrolledDevice(device) {
			s.log.Info().
				Str("provider_id", providerID).
				Str("serial", binding.Serial).
				Msg("live_mda: bound serial has no enrolled MicroMDM UDID yet — skip enqueue")
			return
		}
		udid = strings.TrimSpace(device.UDID)
		s.bindings.SetUDID(binding.Serial, udid)
		s.persistBinding(providerID)
		if sn := strings.TrimSpace(device.SerialNumber); sn != "" {
			binding.Serial = NormalizeSerial(sn)
		}
	}

	ledgerKey := enqueueLedgerKey(providerID, binding.Serial, seKeyHash[:])
	keyMu := s.lockEnqueueKey(ledgerKey)
	defer keyMu.Unlock()

	if allow, reason := s.enqueueAllowed(ledgerKey); !allow {
		s.log.Info().
			Str("provider_id", providerID).
			Str("serial", binding.Serial).
			Str("reason", reason).
			Msg("live_mda: skipping DeviceInformation enqueue (rate limit / pending)")
		return
	}

	// R4-M4: reserve durable pending/ledger before outbound HTTP.
	provisionalUUID := uuid.New().String()
	pendingReq := pendingMDARequest{
		ProviderID:     providerID,
		AssignedID:     assignedID,
		ExpectedSerial: binding.Serial,
		UDID:           udid,
		CommandUUID:    provisionalUUID,
		SEKeyHash:      append([]byte(nil), seKeyHash[:]...),
		EnqueuedAt:     s.now(),
	}
	s.recordPending(udid, provisionalUUID, pendingReq)
	s.markEnqueued(ledgerKey, providerID, binding.Serial, seKeyHash[:], provisionalUUID)

	commandUUID, err := s.client.EnqueueDeviceInformationAttestation(ctx, udid, seKeyHash[:])
	if err != nil {
		s.releaseEnqueueReservation(ledgerKey, provisionalUUID, udid)
		s.log.Warn().Err(err).
			Str("provider_id", providerID).
			Str("udid", udid).
			Msg("live_mda: EnqueueDeviceInformationAttestation failed (best-effort, ignoring)")
		return
	}

	s.confirmEnqueue(ledgerKey, providerID, binding.Serial, seKeyHash[:], provisionalUUID, commandUUID, pendingReq)

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
	ctx := context.Background()
	s.hydrateDurableProof(ctx, providerID, assignedID)
	sePub := s.pool.ProviderSEPublicKey(providerID)
	if len(sePub) == 0 {
		return false
	}
	seKeyHash := sha256.Sum256(sePub)
	return s.tryUpgradeFromCache(ctx, providerID, assignedID, sePub, seKeyHash[:])
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
	case ErrEnrolledUnboundRejected, ErrPendingClaimRejected:
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
		s.markEnqueueFailed(pending)
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
		s.markEnqueueFailed(pending)
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
		s.markEnqueueFailed(pending)
		http.Error(w, "se key mismatch", http.StatusForbidden)
		return
	}
	if !s.verifyAndUpgrade(pending.ProviderID, pending.AssignedID, result.CertificateChain, sePub, seKeyHash[:]) {
		s.log.Warn().
			Str("provider_id", pending.ProviderID).
			Str("udid", udid).
			Msg("live_mda: webhook chain verify/upgrade failed")
		s.markEnqueueFailed(pending)
		http.Error(w, "verify failed", http.StatusUnprocessableEntity)
		return
	}
	s.markEnqueueSuccess(pending)
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
	if s.pending == nil {
		s.pending = make(map[string]pendingMDARequest)
	}
	if udid != "" {
		s.pending[udid] = req
	}
	if commandUUID != "" {
		s.pending[commandUUID] = req
	}
	s.mu.Unlock()
	s.persistPending(req)
}

func (s *LiveMDAService) persistPending(req pendingMDARequest) {
	if s.store == nil || strings.TrimSpace(req.CommandUUID) == "" {
		return
	}
	if err := s.store.SavePending(context.Background(), PendingMDARecord{
		ProviderID:  req.ProviderID,
		AssignedID:  req.AssignedID,
		Serial:      req.ExpectedSerial,
		UDID:        req.UDID,
		SEKeyHash:   req.SEKeyHash,
		CommandUUID: req.CommandUUID,
		EnqueuedAt:  req.EnqueuedAt,
	}); err != nil {
		s.log.Warn().Err(err).
			Str("command_uuid", req.CommandUUID).
			Msg("live_mda: durable pending save failed")
	}
}

func (s *LiveMDAService) clearDurablePending(req pendingMDARequest) {
	if s.store == nil {
		return
	}
	if err := s.store.DeletePending(context.Background(), req.CommandUUID, req.UDID); err != nil {
		s.log.Warn().Err(err).
			Str("command_uuid", req.CommandUUID).
			Msg("live_mda: durable pending delete failed")
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
	// R4-M1: hydrate from durable store on memory miss (restart).
	if !ok && s.store != nil {
		ctx := context.Background()
		var rec PendingMDARecord
		var found bool
		var err error
		if commandUUID != "" {
			rec, found, err = s.store.LoadPendingByCommandUUID(ctx, commandUUID)
		}
		if (err != nil || !found) && udid != "" {
			rec, found, err = s.store.LoadPendingByUDID(ctx, udid)
		}
		if err == nil && found {
			req = pendingMDARequest{
				ProviderID:     rec.ProviderID,
				AssignedID:     rec.AssignedID,
				ExpectedSerial: rec.Serial,
				UDID:           rec.UDID,
				CommandUUID:    rec.CommandUUID,
				SEKeyHash:      append([]byte(nil), rec.SEKeyHash...),
				EnqueuedAt:     rec.EnqueuedAt,
			}
			ok = true
		}
	}
	if !ok {
		return pendingMDARequest{}, false
	}
	// Remove all aliases for this pending request (memory + durable).
	if s.pending != nil {
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
	}
	if s.store != nil {
		_ = s.store.DeletePending(context.Background(), req.CommandUUID, req.UDID)
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
		s.clearMDAProof(providerID, assignedID)
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
		s.clearMDAProof(providerID, assignedID)
		return false
	}
	// Re-verify chain freshness in-process without a new MDM round-trip.
	if !s.verifyAndUpgrade(providerID, assignedID, chain, sePub, seKeyHash) {
		s.log.Info().Str("provider_id", providerID).Msg("live_mda: cached MDA re-verify failed — clearing proof")
		s.clearMDAProof(providerID, assignedID)
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
	serial := ""
	if binding, ok := s.bindings.LookupByProvider(providerID); ok {
		serial = binding.Serial
	}
	if serial == "" {
		serial = tier2.ExtractMDASerialNumber(leaf)
	}
	s.persistMDAProof(providerID, serial, chain, h[:], now)
	s.log.Info().
		Str("provider_id", providerID).
		Str("attestation_tier", pool.AttestationTierHardware).
		Msg("live_mda: attestation_tier upgraded to hardware")
	return true
}

func (s *LiveMDAService) mdmRefreshIntervalHours() int {
	h := s.mdmCfg.MDARefreshIntervalHours
	if h < 168 {
		return 168 // R4-M5: Apple ~7-day DeviceAttestation budget floor
	}
	return h
}

func (s *LiveMDAService) clearMDAProof(providerID, assignedID string) {
	s.pool.ClearMDAProof(providerID, assignedID)
	if s.store != nil {
		if err := s.store.DeleteProof(context.Background(), providerID); err != nil {
			s.log.Warn().Err(err).Str("provider_id", providerID).Msg("live_mda: durable proof delete failed")
		}
	}
}

func (s *LiveMDAService) persistMDAProof(providerID, serial string, chain [][]byte, seKeyHash []byte, verifiedAt time.Time) {
	if s.store == nil {
		return
	}
	if err := s.store.SaveProof(context.Background(), MDAProofRecord{
		ProviderID:     providerID,
		Serial:         serial,
		MDACertChain:   chain,
		BoundSEKeyHash: seKeyHash,
		VerifiedAt:     verifiedAt,
	}); err != nil {
		s.log.Warn().Err(err).Str("provider_id", providerID).Msg("live_mda: durable proof save failed")
	}
}

// hydrateDurableProof loads a persisted MDA proof into the pool without
// publishing hardware tier (same contract as MigrateMDAProofFrom).
func (s *LiveMDAService) hydrateDurableProof(ctx context.Context, providerID, assignedID string) {
	if s.store == nil {
		return
	}
	if _, _, _, ok := s.pool.MDAProof(providerID); ok {
		return
	}
	rec, ok, err := s.store.LoadProof(ctx, providerID)
	if err != nil {
		s.log.Warn().Err(err).Str("provider_id", providerID).Msg("live_mda: durable proof load failed")
		return
	}
	if !ok || len(rec.MDACertChain) == 0 {
		return
	}
	if !s.pool.LoadMDAProofCache(providerID, assignedID, rec.MDACertChain, rec.BoundSEKeyHash, rec.VerifiedAt) {
		return
	}
	s.log.Debug().
		Str("provider_id", providerID).
		Time("verified_at", rec.VerifiedAt).
		Msg("live_mda: hydrated durable MDA proof (tier pending re-verify)")
}

func enqueueLedgerKey(providerID, serial string, seKeyHash []byte) string {
	return strings.TrimSpace(providerID) + "|" + NormalizeSerial(serial) + "|" + hex.EncodeToString(seKeyHash)
}

// enqueueAllowed returns whether a new DeviceInformation enqueue is allowed
// under R3-M3 rate limits. reason is "reuse" or "rate_limited" when blocked.
func (s *LiveMDAService) enqueueAllowed(ledgerKey string) (allow bool, reason string) {
	interval := time.Duration(s.mdmRefreshIntervalHours()) * time.Hour
	now := s.now()
	entry, ok := s.loadLedger(ledgerKey)
	if !ok || entry.LastEnqueueAt.IsZero() {
		return true, ""
	}
	if now.Sub(entry.LastEnqueueAt) >= interval {
		return true, ""
	}
	if strings.TrimSpace(entry.PendingCommandUUID) != "" {
		return false, "reuse"
	}
	return false, "rate_limited"
}

func (s *LiveMDAService) loadLedger(ledgerKey string) (enqueueLedgerEntry, bool) {
	s.mu.Lock()
	defer s.mu.Unlock()
	if s.ledger == nil {
		s.ledger = make(map[string]enqueueLedgerEntry)
	}
	if e, ok := s.ledger[ledgerKey]; ok {
		return e, true
	}
	if s.store != nil {
		rec, ok, err := s.store.LoadEnqueueLedger(context.Background(), ledgerKey)
		if err == nil && ok {
			e := enqueueLedgerEntry{
				LastEnqueueAt:      rec.LastEnqueueAt,
				PendingCommandUUID: rec.PendingCommandUUID,
				TerminalOutcome:    rec.TerminalOutcome,
			}
			s.ledger[ledgerKey] = e
			return e, true
		}
	}
	return enqueueLedgerEntry{}, false
}

func (s *LiveMDAService) markEnqueued(ledgerKey, providerID, serial string, seKeyHash []byte, commandUUID string) {
	now := s.now()
	entry := enqueueLedgerEntry{
		LastEnqueueAt:      now,
		PendingCommandUUID: commandUUID,
		TerminalOutcome:    "",
	}
	s.mu.Lock()
	if s.ledger == nil {
		s.ledger = make(map[string]enqueueLedgerEntry)
	}
	s.ledger[ledgerKey] = entry
	s.mu.Unlock()
	if s.store != nil {
		_ = s.store.SaveEnqueueLedger(context.Background(), EnqueueLedgerRecord{
			LedgerKey:          ledgerKey,
			ProviderID:         providerID,
			Serial:             serial,
			SEKeyHash:          seKeyHash,
			LastEnqueueAt:      now,
			PendingCommandUUID: commandUUID,
			TerminalOutcome:    "",
		})
	}
}

// lockEnqueueKey returns a per-ledger-key mutex held by the caller (R4-M4).
func (s *LiveMDAService) lockEnqueueKey(ledgerKey string) *sync.Mutex {
	s.enqueueMu.Lock()
	if s.enqueueLocks == nil {
		s.enqueueLocks = make(map[string]*sync.Mutex)
	}
	m, ok := s.enqueueLocks[ledgerKey]
	if !ok {
		m = &sync.Mutex{}
		s.enqueueLocks[ledgerKey] = m
	}
	s.enqueueMu.Unlock()
	m.Lock()
	return m
}

// confirmEnqueue replaces a provisional reservation with the real MicroMDM command UUID.
func (s *LiveMDAService) confirmEnqueue(ledgerKey, providerID, serial string, seKeyHash []byte, provisionalUUID, commandUUID string, req pendingMDARequest) {
	provisionalUUID = strings.TrimSpace(provisionalUUID)
	commandUUID = strings.TrimSpace(commandUUID)
	if commandUUID == "" {
		commandUUID = provisionalUUID
	}
	req.CommandUUID = commandUUID
	// Drop provisional memory alias before recording the real UUID.
	s.mu.Lock()
	if s.pending != nil && provisionalUUID != "" && provisionalUUID != commandUUID {
		delete(s.pending, provisionalUUID)
	}
	s.mu.Unlock()
	if s.store != nil && provisionalUUID != "" && provisionalUUID != commandUUID {
		_ = s.store.DeletePending(context.Background(), provisionalUUID, "")
	}
	s.recordPending(req.UDID, commandUUID, req)
	s.markEnqueued(ledgerKey, providerID, serial, seKeyHash, commandUUID)
}

// releaseEnqueueReservation undoes a pre-HTTP reservation after enqueue failure.
func (s *LiveMDAService) releaseEnqueueReservation(ledgerKey, provisionalUUID, udid string) {
	provisionalUUID = strings.TrimSpace(provisionalUUID)
	udid = strings.TrimSpace(udid)
	s.mu.Lock()
	if s.pending != nil {
		if provisionalUUID != "" {
			delete(s.pending, provisionalUUID)
		}
		if udid != "" {
			delete(s.pending, udid)
		}
	}
	if s.ledger != nil {
		delete(s.ledger, ledgerKey)
	}
	s.mu.Unlock()
	if s.store != nil {
		_ = s.store.DeletePending(context.Background(), provisionalUUID, udid)
		_ = s.store.DeleteEnqueueLedger(context.Background(), ledgerKey)
	}
}

func (s *LiveMDAService) markEnqueueSuccess(pending pendingMDARequest) {
	key := enqueueLedgerKey(pending.ProviderID, pending.ExpectedSerial, pending.SEKeyHash)
	s.mu.Lock()
	if s.ledger == nil {
		s.ledger = make(map[string]enqueueLedgerEntry)
	}
	e := s.ledger[key]
	if e.LastEnqueueAt.IsZero() {
		e.LastEnqueueAt = pending.EnqueuedAt
	}
	e.PendingCommandUUID = ""
	e.TerminalOutcome = "success"
	s.ledger[key] = e
	s.mu.Unlock()
	s.clearDurablePending(pending)
	if s.store != nil {
		_ = s.store.SaveEnqueueLedger(context.Background(), EnqueueLedgerRecord{
			LedgerKey:          key,
			ProviderID:         pending.ProviderID,
			Serial:             pending.ExpectedSerial,
			SEKeyHash:          pending.SEKeyHash,
			LastEnqueueAt:      e.LastEnqueueAt,
			PendingCommandUUID: "",
			TerminalOutcome:    "success",
		})
	}
}

func (s *LiveMDAService) markEnqueueFailed(pending pendingMDARequest) {
	key := enqueueLedgerKey(pending.ProviderID, pending.ExpectedSerial, pending.SEKeyHash)
	s.mu.Lock()
	if s.ledger == nil {
		s.ledger = make(map[string]enqueueLedgerEntry)
	}
	e := s.ledger[key]
	if e.LastEnqueueAt.IsZero() {
		e.LastEnqueueAt = pending.EnqueuedAt
	}
	e.PendingCommandUUID = ""
	e.TerminalOutcome = "failed"
	s.ledger[key] = e
	s.mu.Unlock()
	s.clearDurablePending(pending)
	if s.store != nil {
		_ = s.store.SaveEnqueueLedger(context.Background(), EnqueueLedgerRecord{
			LedgerKey:          key,
			ProviderID:         pending.ProviderID,
			Serial:             pending.ExpectedSerial,
			SEKeyHash:          pending.SEKeyHash,
			LastEnqueueAt:      e.LastEnqueueAt,
			PendingCommandUUID: "",
			TerminalOutcome:    "failed",
		})
	}
}

// HandleCheckInWebhook is an optional MicroMDM check-in / Authenticate receiver.
// It only SetUDIDs an existing binding when serial matches — never creates a
// binding from serial alone (R3-H1).
func (s *LiveMDAService) HandleCheckInWebhook(w http.ResponseWriter, r *http.Request) {
	if r.Method != http.MethodPost {
		http.Error(w, "method not allowed", http.StatusMethodNotAllowed)
		return
	}
	if !s.authorizeWebhook(r) {
		http.Error(w, "forbidden", http.StatusForbidden)
		return
	}
	body, err := io.ReadAll(io.LimitReader(r.Body, 1<<20))
	if err != nil {
		http.Error(w, "bad request", http.StatusBadRequest)
		return
	}
	var envelope struct {
		Topic           string `json:"topic"`
		CheckinEvent    *struct {
			UDID         string `json:"udid"`
			URLParams    map[string]string `json:"url_params"`
			RawPayload   string `json:"raw_payload"`
			MessageType  string `json:"message_type"`
		} `json:"checkin_event"`
		UDID         string `json:"udid"`
		SerialNumber string `json:"serial_number"`
		Serial       string `json:"SerialNumber"`
	}
	_ = json.Unmarshal(body, &envelope)
	udid := strings.TrimSpace(envelope.UDID)
	serial := strings.TrimSpace(envelope.SerialNumber)
	if serial == "" {
		serial = strings.TrimSpace(envelope.Serial)
	}
	if envelope.CheckinEvent != nil {
		if udid == "" {
			udid = strings.TrimSpace(envelope.CheckinEvent.UDID)
		}
		if serial == "" && envelope.CheckinEvent.URLParams != nil {
			serial = strings.TrimSpace(envelope.CheckinEvent.URLParams["serial"])
		}
	}
	// Best-effort extract from flat/plist-ish JSON keys.
	if serial == "" || udid == "" {
		var flat map[string]json.RawMessage
		if json.Unmarshal(body, &flat) == nil {
			for _, key := range []string{"SerialNumber", "serial_number", "serial"} {
				if raw, ok := flat[key]; ok {
					var s string
					if json.Unmarshal(raw, &s) == nil && strings.TrimSpace(s) != "" {
						serial = strings.TrimSpace(s)
						break
					}
				}
			}
			if udid == "" {
				for _, key := range []string{"UDID", "udid"} {
					if raw, ok := flat[key]; ok {
						var s string
						if json.Unmarshal(raw, &s) == nil && strings.TrimSpace(s) != "" {
							udid = strings.TrimSpace(s)
							break
						}
					}
				}
			}
		}
	}
	serial = NormalizeSerial(serial)
	if serial == "" || udid == "" {
		w.WriteHeader(http.StatusNoContent)
		return
	}
	if _, ok := s.bindings.LookupBySerial(serial); !ok {
		s.log.Info().
			Str("serial", serial).
			Str("udid", udid).
			Msg("live_mda: check-in ignored — no existing binding for serial")
		w.WriteHeader(http.StatusNoContent)
		return
	}
	s.bindings.SetUDID(serial, udid)
	if b, ok := s.bindings.LookupBySerial(serial); ok {
		s.persistBinding(b.ProviderID)
	}
	s.log.Info().
		Str("serial", serial).
		Str("udid", udid).
		Msg("live_mda: check-in SetUDID on existing binding")
	w.WriteHeader(http.StatusNoContent)
}
