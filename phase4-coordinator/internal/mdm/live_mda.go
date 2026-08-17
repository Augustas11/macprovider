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
// MicroMDM device that was looked up at enqueue time. SEC-H1: responses must
// match this expected serial (from the MDA leaf) before SetMDAProof.
type pendingMDARequest struct {
	ProviderID     string
	AssignedID     string
	ExpectedSerial string
	SEKeyHash      []byte
	EnqueuedAt     time.Time
}

// LiveMDAService orchestrates Phase 3 live MDA round-trips. It:
//
//  1. Looks up the enrolled device in MicroMDM by serial number.
//  2. Enqueues a DeviceInformation attestation command with nonce=SHA256(SEPublicKey).
//  3. Records a pending request keyed by UDID (serial-bound).
//  4. On MicroMDM command webhook (or AttachCachedMDAProof), re-verifies the
//     MDA chain bound to the SE key + enrolled serial and upgrades the pool
//     entry's attestation tier to "hardware".
//
// The service operates in observe mode: failures are logged but do not interrupt
// provider auth or routing. Do not flip require_attestation here (Phase 4 gate).
type LiveMDAService struct {
	client  *Client
	cfg     config.Tier2Config
	mdmCfg  config.Tier2MDMConfig
	pool    *pool.Registry
	log     zerolog.Logger
	now     func() time.Time

	mu       sync.Mutex
	pending  map[string]pendingMDARequest // keyed by UDID
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
		client:  client,
		cfg:     cfg,
		mdmCfg:  mdmCfg,
		pool:    p,
		log:     log,
		now:     now,
		pending: make(map[string]pendingMDARequest),
	}, nil
}

// RequestAndMaybeUpgrade is the main Phase 3 observe-mode entry point.
// It should be called in a goroutine (go svc.RequestAndMaybeUpgrade(...))
// after successful SE attestation auth so it never blocks the auth path.
//
// If the provider already has a valid, fresh MDA proof bound to the current SE
// key, the tier is upgraded immediately without a new MDM round-trip. Otherwise
// a DeviceInformation attestation command is enqueued for the enrolled device
// (best-effort) and a pending bind is recorded for webhook ingest.
//
// serial is the device serial number from attestation claims (may be empty, in
// which case MDM lookup is skipped and only the cached proof path runs).
func (s *LiveMDAService) RequestAndMaybeUpgrade(providerID, assignedID, serial string) {
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

	// 2. Cache miss or stale — enqueue new DeviceInformation attestation.
	if serial = strings.TrimSpace(serial); serial == "" {
		s.log.Debug().
			Str("provider_id", providerID).
			Str("reason", "no_serial").
			Msg("live_mda: cannot enqueue — no device serial")
		return
	}
	device, found, err := s.client.FindDeviceBySerial(ctx, serial)
	if err != nil {
		s.log.Warn().Err(err).
			Str("provider_id", providerID).
			Str("serial", serial).
			Msg("live_mda: FindDeviceBySerial failed")
		return
	}
	if !found {
		s.log.Info().
			Str("provider_id", providerID).
			Str("serial", serial).
			Msg("live_mda: device not found in MicroMDM — not enrolled yet")
		return
	}

	if err := s.client.EnqueueDeviceInformationAttestation(ctx, device.UDID, seKeyHash[:]); err != nil {
		s.log.Warn().Err(err).
			Str("provider_id", providerID).
			Str("udid", device.UDID).
			Msg("live_mda: EnqueueDeviceInformationAttestation failed (best-effort, ignoring)")
		return
	}

	expectedSerial := strings.TrimSpace(device.SerialNumber)
	if expectedSerial == "" {
		expectedSerial = serial
	}
	s.recordPending(device.UDID, pendingMDARequest{
		ProviderID:     providerID,
		AssignedID:     assignedID,
		ExpectedSerial: expectedSerial,
		SEKeyHash:      append([]byte(nil), seKeyHash[:]...),
		EnqueuedAt:     s.now(),
	})

	s.log.Info().
		Str("provider_id", providerID).
		Str("udid", device.UDID).
		Str("serial", expectedSerial).
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

// HandleMDACommandWebhook is the MicroMDM command-webhook receiver. Point
// MicroMDM `-command-webhook-url` at this path (default
// `/internal/mdm/command-webhook` on the provider listener).
//
// Auth: if tier2.mdm.command_webhook_secret is set, require matching
// X-MDM-Webhook-Secret header; otherwise require a loopback remote address.
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
	udid := extractWebhookUDID(body)
	if udid == "" {
		s.log.Warn().Msg("live_mda: webhook missing UDID")
		http.Error(w, "udid required", http.StatusBadRequest)
		return
	}
	pending, ok := s.takePending(udid)
	if !ok {
		s.log.Info().Str("udid", udid).Msg("live_mda: webhook ignored — no pending request for UDID")
		w.WriteHeader(http.StatusNoContent)
		return
	}
	result, err := ParseDeviceAttestationFromPlist(body)
	if err != nil {
		s.log.Warn().Err(err).
			Str("udid", udid).
			Str("provider_id", pending.ProviderID).
			Msg("live_mda: webhook DeviceAttestation parse failed")
		// Re-queue pending so a later delivery can succeed.
		s.recordPending(udid, pending)
		http.Error(w, "no device attestation", http.StatusBadRequest)
		return
	}
	if len(result.CertificateChain) == 0 {
		s.recordPending(udid, pending)
		http.Error(w, "empty chain", http.StatusBadRequest)
		return
	}
	leaf, err := x509.ParseCertificate(result.CertificateChain[0])
	if err != nil {
		s.log.Warn().Err(err).Str("udid", udid).Msg("live_mda: webhook leaf parse failed")
		s.recordPending(udid, pending)
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
		s.recordPending(udid, pending)
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

func (s *LiveMDAService) recordPending(udid string, req pendingMDARequest) {
	udid = strings.TrimSpace(udid)
	if udid == "" {
		return
	}
	s.mu.Lock()
	defer s.mu.Unlock()
	if s.pending == nil {
		s.pending = make(map[string]pendingMDARequest)
	}
	s.pending[udid] = req
}

func (s *LiveMDAService) takePending(udid string) (pendingMDARequest, bool) {
	s.mu.Lock()
	defer s.mu.Unlock()
	req, ok := s.pending[strings.TrimSpace(udid)]
	if !ok {
		return pendingMDARequest{}, false
	}
	delete(s.pending, strings.TrimSpace(udid))
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
