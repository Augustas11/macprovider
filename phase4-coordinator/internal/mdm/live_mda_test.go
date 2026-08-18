package mdm

import (
	"bytes"
	"crypto/ecdsa"
	"crypto/ed25519"
	"crypto/elliptic"
	"crypto/rand"
	"crypto/sha256"
	"crypto/x509"
	"crypto/x509/pkix"
	"encoding/asn1"
	"encoding/base64"
	"encoding/json"
	"math/big"
	"net/http"
	"net/http/httptest"
	"testing"
	"time"

	"github.com/augstar/macprovider-coordinator/internal/config"
	"github.com/augstar/macprovider-coordinator/internal/pool"
	"github.com/rs/zerolog"
)

func TestNewLiveMDAServiceFailsClosedWithoutToken(t *testing.T) {
	cfg := config.Default().Tier2
	cfg.MDM.LiveMDAEnabled = true
	cfg.MDM.APIURL = "http://127.0.0.1:8080"
	cfg.MDM.APIToken = ""
	_, err := NewLiveMDAService(cfg, pool.NewRegistry(nil), zerolog.Nop(), nil)
	if err == nil {
		t.Fatal("expected error when live_mda_enabled without api_token")
	}
}

func TestNewLiveMDAServiceDisabledReturnsNil(t *testing.T) {
	cfg := config.Default().Tier2
	cfg.MDM.LiveMDAEnabled = false
	svc, err := NewLiveMDAService(cfg, pool.NewRegistry(nil), zerolog.Nop(), nil)
	if err != nil || svc != nil {
		t.Fatalf("want (nil,nil), got (%v,%v)", svc, err)
	}
}

func TestUpgradeFromParsedAttestationNilGuard(t *testing.T) {
	svc := &LiveMDAService{
		pool: pool.NewRegistry(nil),
		log:  zerolog.Nop(),
		now:  func() time.Time { return time.Unix(1716768000, 0).UTC() },
	}
	if svc.UpgradeFromParsedAttestation("p1", "s1", nil) {
		t.Fatal("nil result must not upgrade")
	}
}

func TestMDMRefreshIntervalFloor(t *testing.T) {
	svc := &LiveMDAService{mdmCfg: config.Tier2MDMConfig{MDARefreshIntervalHours: 0}}
	if got := svc.mdmRefreshIntervalHours(); got != 168 {
		t.Fatalf("unset default=%d want 168", got)
	}
	svc.mdmCfg.MDARefreshIntervalHours = 12
	if got := svc.mdmRefreshIntervalHours(); got != 168 {
		t.Fatalf("floor=%d want 168", got)
	}
	svc.mdmCfg.MDARefreshIntervalHours = 48
	if got := svc.mdmRefreshIntervalHours(); got != 168 {
		t.Fatalf("sub-168 clamp=%d want 168", got)
	}
	svc.mdmCfg.MDARefreshIntervalHours = 168
	if got := svc.mdmRefreshIntervalHours(); got != 168 {
		t.Fatalf("passthrough=%d want 168", got)
	}
	svc.mdmCfg.MDARefreshIntervalHours = 200
	if got := svc.mdmRefreshIntervalHours(); got != 200 {
		t.Fatalf("above floor=%d want 200", got)
	}
}

func TestHandleMDACommandWebhookHappyPathAndSerialMismatch(t *testing.T) {
	now := time.Unix(1716768000, 0).UTC()
	reg := pool.NewRegistry(nil)
	seKey := make([]byte, 64)
	for i := range seKey {
		seKey[i] = byte(i + 3)
	}
	seHash := sha256.Sum256(seKey)

	rootDER, leafDER, cfg := testMDAChainWithSerial(t, now, seHash[:], "C02EXPECTED")

	_, ok, _ := reg.RegisterAtDetailed(&pool.Provider{
		ProviderID:       "prov-1",
		AssignedID:       "asg-1",
		ModelID:          "m",
		State:            pool.StateReady,
		SlotsFree:        1,
		SlotsTotal:       1,
		SEPublicKey:      seKey,
		AuthState:        pool.AuthBearerValidated,
		MaxConcurrency:   1,
		MaxContextTokens: 8000,
	}, nil, now)
	if !ok {
		t.Fatal("register failed")
	}

	svc := &LiveMDAService{
		cfg:      cfg,
		mdmCfg:   config.Tier2MDMConfig{CommandWebhookSecret: "hook-secret", MDARefreshIntervalHours: 168},
		pool:     reg,
		log:      zerolog.Nop(),
		now:      func() time.Time { return now },
		bindings: NewDeviceBindingStore(),
		pending:  make(map[string]pendingMDARequest),
	}
	_ = svc.bindings.Claim("prov-1", "C02EXPECTED")
	svc.recordPending("UDID-1", "cmd-1", pendingMDARequest{
		ProviderID:     "prov-1",
		AssignedID:     "asg-1",
		ExpectedSerial: "C02EXPECTED",
		UDID:           "UDID-1",
		CommandUUID:    "cmd-1",
		SEKeyHash:      seHash[:],
		EnqueuedAt:     now,
	})

	// Legacy flat JSON secondary compat.
	body, _ := json.Marshal(map[string]interface{}{
		"udid": "UDID-1",
		"payload": map[string]interface{}{
			"DeviceAttestation": []interface{}{
				base64.StdEncoding.EncodeToString(leafDER),
				base64.StdEncoding.EncodeToString(rootDER),
			},
		},
	})
	req := httptest.NewRequest(http.MethodPost, "/internal/mdm/command-webhook", bytes.NewReader(body))
	req.Header.Set("X-MDM-Webhook-Secret", "hook-secret")
	req.RemoteAddr = "8.8.8.8:1234"
	rr := httptest.NewRecorder()
	svc.HandleMDACommandWebhook(rr, req)
	if rr.Code != http.StatusNoContent {
		t.Fatalf("happy path status=%d body=%s", rr.Code, rr.Body.String())
	}
	chain, _, _, _, present := reg.MDAProof("prov-1")
	if !present || len(chain) == 0 {
		t.Fatal("expected MDA proof after webhook happy path")
	}
	p, found := reg.Resolve("prov-1", "asg-1")
	if !found || p.AttestationTier != pool.AttestationTierHardware {
		t.Fatalf("tier=%q found=%v want hardware", p.AttestationTier, found)
	}

	// Serial mismatch rejection.
	svc.recordPending("UDID-2", "cmd-2", pendingMDARequest{
		ProviderID:     "prov-1",
		AssignedID:     "asg-1",
		ExpectedSerial: "OTHER-SERIAL",
		UDID:           "UDID-2",
		CommandUUID:    "cmd-2",
		SEKeyHash:      seHash[:],
		EnqueuedAt:     now,
	})
	body2, _ := json.Marshal(map[string]interface{}{
		"udid": "UDID-2",
		"payload": map[string]interface{}{
			"DeviceAttestation": []interface{}{
				base64.StdEncoding.EncodeToString(leafDER),
				base64.StdEncoding.EncodeToString(rootDER),
			},
		},
	})
	req2 := httptest.NewRequest(http.MethodPost, "/internal/mdm/command-webhook", bytes.NewReader(body2))
	req2.Header.Set("X-MDM-Webhook-Secret", "hook-secret")
	rr2 := httptest.NewRecorder()
	svc.HandleMDACommandWebhook(rr2, req2)
	if rr2.Code != http.StatusForbidden {
		t.Fatalf("serial mismatch status=%d want 403", rr2.Code)
	}
}

func TestHandleMDACommandWebhookAcknowledgeEvent(t *testing.T) {
	now := time.Unix(1716768000, 0).UTC()
	reg := pool.NewRegistry(nil)
	seKey := bytes.Repeat([]byte{5}, 64)
	seHash := sha256.Sum256(seKey)
	rootDER, leafDER, cfg := testMDAChainWithSerial(t, now, seHash[:], "C02ACKTEST1")

	reg.RegisterAtDetailed(&pool.Provider{
		ProviderID: "prov-ack", AssignedID: "asg-ack", ModelID: "m", State: pool.StateReady,
		SlotsFree: 1, SlotsTotal: 1, SEPublicKey: seKey, AuthState: pool.AuthBearerValidated,
		MaxConcurrency: 1, MaxContextTokens: 8000,
	}, nil, now)

	// Build a realistic DeviceInformation response plist with DevicePropertiesAttestation.
	plistXML := `<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Status</key>
  <string>Acknowledged</string>
  <key>UDID</key>
  <string>UDID-ACK-1</string>
  <key>CommandUUID</key>
  <string>cmd-ack-uuid</string>
  <key>QueryResponses</key>
  <dict>
    <key>DevicePropertiesAttestation</key>
    <array>
      <data>` + base64.StdEncoding.EncodeToString(leafDER) + `</data>
      <data>` + base64.StdEncoding.EncodeToString(rootDER) + `</data>
    </array>
  </dict>
</dict>
</plist>`

	envelope, _ := json.Marshal(map[string]interface{}{
		"topic": "mdm.Connect",
		"acknowledge_event": map[string]interface{}{
			"udid":         "UDID-ACK-1",
			"status":       "Acknowledged",
			"command_uuid": "cmd-ack-uuid",
			"raw_payload":  base64.StdEncoding.EncodeToString([]byte(plistXML)),
		},
	})

	svc := &LiveMDAService{
		cfg:      cfg,
		mdmCfg:   config.Tier2MDMConfig{CommandWebhookSecret: "hook-secret", MDARefreshIntervalHours: 168},
		pool:     reg,
		log:      zerolog.Nop(),
		now:      func() time.Time { return now },
		bindings: NewDeviceBindingStore(),
		pending:  make(map[string]pendingMDARequest),
	}
	_ = svc.bindings.Claim("prov-ack", "C02ACKTEST1")
	svc.recordPending("UDID-ACK-1", "cmd-ack-uuid", pendingMDARequest{
		ProviderID: "prov-ack", AssignedID: "asg-ack", ExpectedSerial: "C02ACKTEST1",
		UDID: "UDID-ACK-1", CommandUUID: "cmd-ack-uuid", SEKeyHash: seHash[:], EnqueuedAt: now,
	})

	req := httptest.NewRequest(http.MethodPost, "/internal/mdm/command-webhook", bytes.NewReader(envelope))
	req.Header.Set("X-MDM-Webhook-Secret", "hook-secret")
	rr := httptest.NewRecorder()
	svc.HandleMDACommandWebhook(rr, req)
	if rr.Code != http.StatusNoContent {
		t.Fatalf("ack status=%d body=%s", rr.Code, rr.Body.String())
	}
	p, found := reg.Resolve("prov-ack", "asg-ack")
	if !found || p.AttestationTier != pool.AttestationTierHardware {
		t.Fatalf("tier=%q found=%v want hardware", p.AttestationTier, found)
	}
}

func TestTryUpgradeFromCacheClearsOnExpiry(t *testing.T) {
	now := time.Unix(1716768000, 0).UTC()
	reg := pool.NewRegistry(nil)
	seKey := bytes.Repeat([]byte{7}, 64)
	seHash := sha256.Sum256(seKey)
	reg.RegisterAtDetailed(&pool.Provider{
		ProviderID: "p-exp", AssignedID: "s1", ModelID: "m", State: pool.StateReady,
		SlotsFree: 1, SlotsTotal: 1, SEPublicKey: seKey, AuthState: pool.AuthBearerValidated,
		MaxConcurrency: 1, MaxContextTokens: 8000,
	}, nil, now)
	reg.SetMDAProof("p-exp", "s1", [][]byte{[]byte("stale")}, seHash[:], now.Add(-200*time.Hour), "")

	svc := &LiveMDAService{
		mdmCfg: config.Tier2MDMConfig{MDARefreshIntervalHours: 168},
		pool:   reg,
		log:    zerolog.Nop(),
		now:    func() time.Time { return now },
	}
	if svc.tryUpgradeFromCache(nil, "p-exp", "s1", seKey, seHash[:]) {
		t.Fatal("expired cache should not upgrade")
	}
	if _, _, _, _, ok := reg.MDAProof("p-exp"); ok {
		t.Fatal("expired cache must ClearMDAProof")
	}
	p, _ := reg.Resolve("p-exp", "s1")
	if p.AttestationTier != pool.AttestationTierSelfSigned {
		t.Fatalf("tier=%q want self_signed after expiry clear", p.AttestationTier)
	}
}

func testMDAChainWithSerial(t *testing.T, now time.Time, freshness []byte, serial string) (rootDER, leafDER []byte, cfg config.Tier2Config) {
	t.Helper()
	rootPub, rootPriv, err := ed25519.GenerateKey(rand.Reader)
	if err != nil {
		t.Fatalf("root key: %v", err)
	}
	root := &x509.Certificate{
		SerialNumber:          big.NewInt(1),
		Subject:               pkix.Name{CommonName: "Apple Enterprise Attestation Root CA"},
		NotBefore:             now.Add(-time.Hour),
		NotAfter:              now.Add(24 * time.Hour),
		KeyUsage:              x509.KeyUsageCertSign | x509.KeyUsageCRLSign,
		IsCA:                  true,
		BasicConstraintsValid: true,
	}
	rootDER, err = x509.CreateCertificate(rand.Reader, root, root, rootPub, rootPriv)
	if err != nil {
		t.Fatalf("root cert: %v", err)
	}
	leafKey, err := ecdsa.GenerateKey(elliptic.P256(), rand.Reader)
	if err != nil {
		t.Fatalf("leaf key: %v", err)
	}
	serialEnc, err := asn1.Marshal(serial)
	if err != nil {
		t.Fatalf("serial asn1: %v", err)
	}
	leaf := &x509.Certificate{
		SerialNumber:          big.NewInt(2),
		Subject:               pkix.Name{CommonName: "Managed Device Attestation Leaf"},
		NotBefore:             now.Add(-time.Hour),
		NotAfter:              now.Add(24 * time.Hour),
		KeyUsage:              x509.KeyUsageDigitalSignature,
		BasicConstraintsValid: true,
		ExtraExtensions: []pkix.Extension{
			{Id: asn1.ObjectIdentifier{1, 2, 840, 113635, 100, 8, 11, 1}, Value: freshness},
			{Id: asn1.ObjectIdentifier{1, 2, 840, 113635, 100, 8, 9, 1}, Value: serialEnc},
			{Id: asn1.ObjectIdentifier{1, 2, 840, 113635, 100, 8, 10, 1}, Value: []byte("macOS 14.5")},
		},
	}
	leafDER, err = x509.CreateCertificate(rand.Reader, leaf, root, &leafKey.PublicKey, rootPriv)
	if err != nil {
		t.Fatalf("leaf cert: %v", err)
	}
	cfg = config.Default().Tier2
	cfg.AttestationRoots = []string{base64.StdEncoding.EncodeToString(rootDER)}
	return rootDER, leafDER, cfg
}
