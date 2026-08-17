package mdm

import (
	"context"
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"sync/atomic"
	"testing"
	"time"

	"github.com/augstar/macprovider-coordinator/internal/config"
	"github.com/augstar/macprovider-coordinator/internal/pool"
	"github.com/rs/zerolog"
)

func TestDeviceBindingStoreExclusiveClaim(t *testing.T) {
	s := NewDeviceBindingStore()
	if err := s.Claim("prov-a", "c02abc"); err != nil {
		t.Fatalf("claim a: %v", err)
	}
	if err := s.Claim("prov-b", "C02ABC"); err != ErrSerialAlreadyBound {
		t.Fatalf("second claim err=%v want ErrSerialAlreadyBound", err)
	}
	if err := s.Claim("prov-a", "c02abc"); err != nil {
		t.Fatalf("same-provider reclaim: %v", err)
	}
	b, ok := s.LookupByProvider("prov-a")
	if !ok || b.Serial != "C02ABC" {
		t.Fatalf("lookup=%v ok=%v", b, ok)
	}
}

func TestClaimDeviceRejectsEnrolledUnboundForTokenPath(t *testing.T) {
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		_ = json.NewEncoder(w).Encode(listDevicesResponse{
			Devices: []Device{{UDID: "VICTIM-UDID", SerialNumber: "H2XX74T43X"}},
		})
	}))
	defer srv.Close()
	client, _ := NewClient(ClientConfig{BaseURL: srv.URL, APIToken: "tok"})
	svc := &LiveMDAService{
		client:   client,
		bindings: NewDeviceBindingStore(),
		log:      zerolog.Nop(),
		now:      time.Now,
	}
	err := svc.ClaimDevice(context.Background(), "attacker", "H2XX74T43X", false)
	if err != ErrEnrolledUnboundRejected {
		t.Fatalf("token claim err=%v want ErrEnrolledUnboundRejected", err)
	}
	// Internal bootstrap allowed.
	if err := svc.ClaimDevice(context.Background(), "rightful", "H2XX74T43X", true); err != nil {
		t.Fatalf("internal claim: %v", err)
	}
	b, ok := svc.Bindings().LookupByProvider("rightful")
	if !ok || b.UDID != "VICTIM-UDID" {
		t.Fatalf("binding=%v ok=%v", b, ok)
	}
	// Second provider still cannot steal.
	if err := svc.ClaimDevice(context.Background(), "attacker", "H2XX74T43X", true); err != ErrSerialAlreadyBound {
		t.Fatalf("steal err=%v want ErrSerialAlreadyBound", err)
	}
}

func TestClaimDeviceAllowsPendingWhenNotEnrolled(t *testing.T) {
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		_ = json.NewEncoder(w).Encode(listDevicesResponse{Devices: nil})
	}))
	defer srv.Close()
	client, _ := NewClient(ClientConfig{BaseURL: srv.URL, APIToken: "tok"})
	svc := &LiveMDAService{
		client:   client,
		bindings: NewDeviceBindingStore(),
		log:      zerolog.Nop(),
		now:      time.Now,
	}
	if err := svc.ClaimDevice(context.Background(), "prov-1", "C02PENDING01", false); err != nil {
		t.Fatalf("pending claim: %v", err)
	}
	b, ok := svc.Bindings().LookupByProvider("prov-1")
	if !ok || b.Serial != "C02PENDING01" || b.UDID != "" {
		t.Fatalf("binding=%v ok=%v", b, ok)
	}
}

func TestRequestAndMaybeUpgradeNeverEnqueuesVictimFromSESerial(t *testing.T) {
	var enqueuedUDID atomic.Value
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		switch {
		case r.URL.Path == "/v1/devices":
			_ = json.NewEncoder(w).Encode(listDevicesResponse{
				Devices: []Device{
					{UDID: "VICTIM-UDID", SerialNumber: "VICTIMSERIAL1"},
					{UDID: "ATTACKER-UDID", SerialNumber: "ATTACKERSER1"},
				},
			})
		case len(r.URL.Path) > len("/v1/commands/"):
			enqueuedUDID.Store(r.URL.Path[len("/v1/commands/"):])
			w.WriteHeader(http.StatusOK)
		default:
			http.NotFound(w, r)
		}
	}))
	defer srv.Close()

	client, _ := NewClient(ClientConfig{BaseURL: srv.URL, APIToken: "tok"})
	reg := pool.NewRegistry(nil)
	now := time.Unix(1716768000, 0).UTC()
	seKey := make([]byte, 64)
	reg.RegisterAtDetailed(&pool.Provider{
		ProviderID: "attacker", AssignedID: "asg-1", ModelID: "m", State: pool.StateReady,
		SlotsFree: 1, SlotsTotal: 1, SEPublicKey: seKey, AuthState: pool.AuthBearerValidated,
		MaxConcurrency: 1, MaxContextTokens: 8000,
	}, nil, now)

	svc := &LiveMDAService{
		client:   client,
		cfg:      config.Default().Tier2,
		mdmCfg:   config.Tier2MDMConfig{MDARefreshIntervalHours: 168},
		pool:     reg,
		log:      zerolog.Nop(),
		now:      func() time.Time { return now },
		bindings: NewDeviceBindingStore(),
		pending:  make(map[string]pendingMDARequest),
	}
	// Attacker binds their own serial, but presents victim SE serial.
	if err := svc.ClaimDevice(context.Background(), "attacker", "ATTACKERSER1", true); err != nil {
		t.Fatalf("claim: %v", err)
	}
	svc.RequestAndMaybeUpgrade("attacker", "asg-1", "VICTIMSERIAL1")
	if v := enqueuedUDID.Load(); v != nil {
		t.Fatalf("must not enqueue when SE serial mismatches binding; got udid=%v", v)
	}

	// Matching SE serial enqueues attacker's UDID only.
	svc.RequestAndMaybeUpgrade("attacker", "asg-1", "ATTACKERSER1")
	got, _ := enqueuedUDID.Load().(string)
	if got != "ATTACKER-UDID" {
		t.Fatalf("enqueued UDID=%q want ATTACKER-UDID", got)
	}
}

func TestRequestAndMaybeUpgradeWorksWithMatchingBinding(t *testing.T) {
	var enqueuedPath string
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if r.URL.Path == "/v1/devices" {
			_ = json.NewEncoder(w).Encode(listDevicesResponse{
				Devices: []Device{{UDID: "OWN-UDID", SerialNumber: "OWNSERIAL001"}},
			})
			return
		}
		enqueuedPath = r.URL.Path
		w.WriteHeader(http.StatusOK)
	}))
	defer srv.Close()
	client, _ := NewClient(ClientConfig{BaseURL: srv.URL, APIToken: "tok"})
	reg := pool.NewRegistry(nil)
	now := time.Unix(1716768000, 0).UTC()
	seKey := make([]byte, 64)
	reg.RegisterAtDetailed(&pool.Provider{
		ProviderID: "owner", AssignedID: "asg-1", ModelID: "m", State: pool.StateReady,
		SlotsFree: 1, SlotsTotal: 1, SEPublicKey: seKey, AuthState: pool.AuthBearerValidated,
		MaxConcurrency: 1, MaxContextTokens: 8000,
	}, nil, now)
	svc := &LiveMDAService{
		client: client, pool: reg, log: zerolog.Nop(), now: func() time.Time { return now },
		bindings: NewDeviceBindingStore(), pending: make(map[string]pendingMDARequest),
		mdmCfg: config.Tier2MDMConfig{MDARefreshIntervalHours: 168},
	}
	_ = svc.ClaimDevice(context.Background(), "owner", "OWNSERIAL001", true)
	svc.RequestAndMaybeUpgrade("owner", "asg-1", "OWNSERIAL001")
	if enqueuedPath != "/v1/commands/OWN-UDID" {
		t.Fatalf("path=%q want /v1/commands/OWN-UDID", enqueuedPath)
	}
	svc.mu.Lock()
	_, okUDID := svc.pending["OWN-UDID"]
	svc.mu.Unlock()
	if !okUDID {
		t.Fatal("pending should be keyed by UDID")
	}
}
