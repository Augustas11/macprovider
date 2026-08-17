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
	if got := svc.mdmRefreshIntervalHours(); got != 24 {
		t.Fatalf("floor=%d want 24", got)
	}
	svc.mdmCfg.MDARefreshIntervalHours = 48
	if got := svc.mdmRefreshIntervalHours(); got != 48 {
		t.Fatalf("passthrough=%d want 48", got)
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
		cfg:    cfg,
		mdmCfg: config.Tier2MDMConfig{CommandWebhookSecret: "hook-secret", MDARefreshIntervalHours: 168},
		pool:   reg,
		log:    zerolog.Nop(),
		now:    func() time.Time { return now },
		pending: map[string]pendingMDARequest{
			"UDID-1": {
				ProviderID:     "prov-1",
				AssignedID:     "asg-1",
				ExpectedSerial: "C02EXPECTED",
				SEKeyHash:      seHash[:],
				EnqueuedAt:     now,
			},
		},
	}

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
	chain, _, _, present := reg.MDAProof("prov-1")
	if !present || len(chain) == 0 {
		t.Fatal("expected MDA proof after webhook happy path")
	}
	p, found := reg.Resolve("prov-1", "asg-1")
	if !found || p.AttestationTier != pool.AttestationTierHardware {
		t.Fatalf("tier=%q found=%v want hardware", p.AttestationTier, found)
	}

	// Serial mismatch rejection.
	svc.pending = map[string]pendingMDARequest{
		"UDID-2": {
			ProviderID:     "prov-1",
			AssignedID:     "asg-1",
			ExpectedSerial: "OTHER-SERIAL",
			SEKeyHash:      seHash[:],
			EnqueuedAt:     now,
		},
	}
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
	reg.SetMDAProof("p-exp", "s1", [][]byte{[]byte("stale")}, seHash[:], now.Add(-200*time.Hour))

	svc := &LiveMDAService{
		mdmCfg: config.Tier2MDMConfig{MDARefreshIntervalHours: 168},
		pool:   reg,
		log:    zerolog.Nop(),
		now:    func() time.Time { return now },
	}
	if svc.tryUpgradeFromCache(nil, "p-exp", "s1", seKey, seHash[:]) {
		t.Fatal("expired cache should not upgrade")
	}
	if _, _, _, ok := reg.MDAProof("p-exp"); ok {
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
