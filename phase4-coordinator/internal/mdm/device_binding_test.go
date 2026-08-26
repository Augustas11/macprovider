package mdm

import (
	"bytes"
	"context"
	"crypto/sha256"
	"encoding/base64"
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"path/filepath"
	"strings"
	"sync"
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

func TestOpenMDAStoreWithManualWALCheckpointDisablesAutocheckpoint(t *testing.T) {
	store, err := OpenMDAStoreWithManualWALCheckpoint(filepath.Join(t.TempDir(), "coordinator.db"))
	if err != nil {
		t.Fatal(err)
	}
	defer store.Close()

	var got int
	if err := store.db.QueryRowContext(context.Background(), `PRAGMA wal_autocheckpoint`).Scan(&got); err != nil {
		t.Fatalf("PRAGMA wal_autocheckpoint: %v", err)
	}
	if got != 0 {
		t.Fatalf("wal_autocheckpoint=%d want 0", got)
	}
}

func TestOpenMDAStoreKeepsSQLiteAutocheckpointOwnerDefault(t *testing.T) {
	store, err := OpenMDAStore(filepath.Join(t.TempDir(), "coordinator.db"))
	if err != nil {
		t.Fatal(err)
	}
	defer store.Close()

	var got int
	if err := store.db.QueryRowContext(context.Background(), `PRAGMA wal_autocheckpoint`).Scan(&got); err != nil {
		t.Fatalf("PRAGMA wal_autocheckpoint: %v", err)
	}
	if got == 0 {
		t.Fatal("MDA store disabled wal_autocheckpoint without an explicit checkpoint owner")
	}
}

func TestClaimDeviceRejectsEnrolledUnboundForTokenPath(t *testing.T) {
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		_ = json.NewEncoder(w).Encode(listDevicesResponse{
			Devices: []Device{{UDID: "VICTIM-UDID", SerialNumber: "H2XX74T43X", EnrollmentStatus: true}},
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

func TestClaimDeviceRejectsPendingWhenNotEnrolled(t *testing.T) {
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
	// Token path must reject (R3-H1).
	if err := svc.ClaimDevice(context.Background(), "prov-1", "C02PENDING01", false); err != ErrPendingClaimRejected {
		t.Fatalf("token pending claim err=%v want ErrPendingClaimRejected", err)
	}
	// Internal bootstrap of not-enrolled serial also rejected.
	if err := svc.ClaimDevice(context.Background(), "prov-1", "C02PENDING01", true); err != ErrPendingClaimRejected {
		t.Fatalf("internal pending claim err=%v want ErrPendingClaimRejected", err)
	}
	if _, ok := svc.Bindings().LookupByProvider("prov-1"); ok {
		t.Fatal("no binding should exist after pending reject")
	}
}

func TestClaimDeviceTokenRefreshExistingBinding(t *testing.T) {
	var listCalls atomic.Int32
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		listCalls.Add(1)
		_ = json.NewEncoder(w).Encode(listDevicesResponse{
			Devices: []Device{{UDID: "UDID-REFRESHED", SerialNumber: "C02EXIST001", EnrollmentStatus: true}},
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
	if err := svc.ClaimDevice(context.Background(), "owner", "C02EXIST001", true); err != nil {
		t.Fatalf("internal bootstrap: %v", err)
	}
	// Clear UDID to force refresh path.
	svc.bindings.mu.Lock()
	b := svc.bindings.byProvider["owner"]
	b.UDID = ""
	svc.bindings.byProvider["owner"] = b
	svc.bindings.mu.Unlock()

	if err := svc.ClaimDevice(context.Background(), "owner", "C02EXIST001", false); err != nil {
		t.Fatalf("token refresh: %v", err)
	}
	got, ok := svc.Bindings().LookupByProvider("owner")
	if !ok || got.UDID != "UDID-REFRESHED" {
		t.Fatalf("binding=%v ok=%v want UDID refreshed", got, ok)
	}
	if listCalls.Load() < 2 {
		t.Fatalf("expected FindDeviceBySerial on bootstrap + refresh, calls=%d", listCalls.Load())
	}
}

func TestAttackerCannotPreClaimBeforeVictimEnrolls(t *testing.T) {
	var devices atomic.Value
	devices.Store([]Device(nil))
	var enqueuedUDID atomic.Value
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		switch {
		case r.URL.Path == "/v1/devices":
			devs, _ := devices.Load().([]Device)
			_ = json.NewEncoder(w).Encode(listDevicesResponse{Devices: devs})
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
		ProviderID: "attacker", AssignedID: "asg-a", ModelID: "m", State: pool.StateReady,
		SlotsFree: 1, SlotsTotal: 1, SEPublicKey: seKey, AuthState: pool.AuthBearerValidated,
		MaxConcurrency: 1, MaxContextTokens: 8000,
	}, nil, now)
	reg.RegisterAtDetailed(&pool.Provider{
		ProviderID: "victim", AssignedID: "asg-v", ModelID: "m", State: pool.StateReady,
		SlotsFree: 1, SlotsTotal: 1, SEPublicKey: seKey, AuthState: pool.AuthBearerValidated,
		MaxConcurrency: 1, MaxContextTokens: 8000,
	}, nil, now)

	svc := &LiveMDAService{
		client: client, pool: reg, log: zerolog.Nop(), now: func() time.Time { return now },
		bindings: NewDeviceBindingStore(), pending: make(map[string]pendingMDARequest),
		ledger: make(map[string]enqueueLedgerEntry),
		mdmCfg: config.Tier2MDMConfig{MDARefreshIntervalHours: 168},
	}

	// Attacker tries to pre-claim victim serial before enrollment.
	if err := svc.ClaimDevice(context.Background(), "attacker", "VICTIMSERIAL1", false); err != ErrPendingClaimRejected {
		t.Fatalf("pre-claim err=%v want ErrPendingClaimRejected", err)
	}

	// Victim enrolls in MicroMDM, then rightful internal bootstrap.
	devices.Store([]Device{{UDID: "VICTIM-UDID", SerialNumber: "VICTIMSERIAL1", EnrollmentStatus: true}})
	if err := svc.ClaimDevice(context.Background(), "victim", "VICTIMSERIAL1", true); err != nil {
		t.Fatalf("victim bootstrap: %v", err)
	}

	// Attacker still cannot steal or enqueue.
	if err := svc.ClaimDevice(context.Background(), "attacker", "VICTIMSERIAL1", false); err != ErrSerialAlreadyBound {
		t.Fatalf("post-enroll steal err=%v want ErrSerialAlreadyBound", err)
	}
	svc.RequestAndMaybeUpgrade("attacker", "asg-a", "VICTIMSERIAL1")
	if v := enqueuedUDID.Load(); v != nil {
		t.Fatalf("attacker must not enqueue; got udid=%v", v)
	}
	svc.RequestAndMaybeUpgrade("victim", "asg-v", "VICTIMSERIAL1")
	got, _ := enqueuedUDID.Load().(string)
	if got != "VICTIM-UDID" {
		t.Fatalf("victim enqueue udid=%q want VICTIM-UDID", got)
	}
}

func TestRequestAndMaybeUpgradeNeverEnqueuesVictimFromSESerial(t *testing.T) {
	var enqueuedUDID atomic.Value
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		switch {
		case r.URL.Path == "/v1/devices":
			_ = json.NewEncoder(w).Encode(listDevicesResponse{
				Devices: []Device{
					{UDID: "VICTIM-UDID", SerialNumber: "VICTIMSERIAL1", EnrollmentStatus: true},
					{UDID: "ATTACKER-UDID", SerialNumber: "ATTACKERSER1", EnrollmentStatus: true},
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
		ledger:   make(map[string]enqueueLedgerEntry),
	}
	if err := svc.ClaimDevice(context.Background(), "attacker", "ATTACKERSER1", true); err != nil {
		t.Fatalf("claim: %v", err)
	}
	svc.RequestAndMaybeUpgrade("attacker", "asg-1", "VICTIMSERIAL1")
	if v := enqueuedUDID.Load(); v != nil {
		t.Fatalf("must not enqueue when SE serial mismatches binding; got udid=%v", v)
	}

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
				Devices: []Device{{UDID: "OWN-UDID", SerialNumber: "OWNSERIAL001", EnrollmentStatus: true}},
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
		ledger: make(map[string]enqueueLedgerEntry),
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

func TestRequestAndMaybeUpgradeRateLimitsDoubleEnqueue(t *testing.T) {
	var enqueueCount atomic.Int32
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if r.URL.Path == "/v1/devices" {
			_ = json.NewEncoder(w).Encode(listDevicesResponse{
				Devices: []Device{{UDID: "RATE-UDID", SerialNumber: "RATESERIAL01", EnrollmentStatus: true}},
			})
			return
		}
		enqueueCount.Add(1)
		w.WriteHeader(http.StatusOK)
	}))
	defer srv.Close()
	client, _ := NewClient(ClientConfig{BaseURL: srv.URL, APIToken: "tok"})
	reg := pool.NewRegistry(nil)
	now := time.Unix(1716768000, 0).UTC()
	clock := now
	seKey := make([]byte, 64)
	reg.RegisterAtDetailed(&pool.Provider{
		ProviderID: "rate", AssignedID: "asg-1", ModelID: "m", State: pool.StateReady,
		SlotsFree: 1, SlotsTotal: 1, SEPublicKey: seKey, AuthState: pool.AuthBearerValidated,
		MaxConcurrency: 1, MaxContextTokens: 8000,
	}, nil, now)
	svc := &LiveMDAService{
		client: client, pool: reg, log: zerolog.Nop(),
		now:      func() time.Time { return clock },
		bindings: NewDeviceBindingStore(), pending: make(map[string]pendingMDARequest),
		ledger: make(map[string]enqueueLedgerEntry),
		mdmCfg: config.Tier2MDMConfig{MDARefreshIntervalHours: 168},
	}
	_ = svc.ClaimDevice(context.Background(), "rate", "RATESERIAL01", true)
	svc.RequestAndMaybeUpgrade("rate", "asg-1", "RATESERIAL01")
	svc.RequestAndMaybeUpgrade("rate", "asg-1", "RATESERIAL01")
	if enqueueCount.Load() != 1 {
		t.Fatalf("enqueue count=%d want 1 (second call must reuse/rate-limit)", enqueueCount.Load())
	}
	clock = now.Add(169 * time.Hour)
	svc.RequestAndMaybeUpgrade("rate", "asg-1", "RATESERIAL01")
	if enqueueCount.Load() != 2 {
		t.Fatalf("after interval enqueue count=%d want 2", enqueueCount.Load())
	}
}

func TestDurableMDAProofSurvivesNewService(t *testing.T) {
	dir := t.TempDir()
	dbPath := filepath.Join(dir, "coordinator.db")
	store, err := OpenMDAStore(dbPath)
	if err != nil {
		t.Fatalf("open store: %v", err)
	}
	defer store.Close()

	now := time.Unix(1716768000, 0).UTC()
	seKey := make([]byte, 64)
	for i := range seKey {
		seKey[i] = byte(i + 1)
	}
	seHash := sha256.Sum256(seKey)
	rootDER, leafDER, cfg := testMDAChainWithSerial(t, now, seHash[:], "C02DURABLE1")

	reg1 := pool.NewRegistry(nil)
	reg1.RegisterAtDetailed(&pool.Provider{
		ProviderID: "p-dur", AssignedID: "s1", ModelID: "m", State: pool.StateReady,
		SlotsFree: 1, SlotsTotal: 1, SEPublicKey: seKey, AuthState: pool.AuthBearerValidated,
		MaxConcurrency: 1, MaxContextTokens: 8000,
	}, nil, now)
	svc1 := &LiveMDAService{
		cfg: cfg, mdmCfg: config.Tier2MDMConfig{MDARefreshIntervalHours: 168},
		pool: reg1, log: zerolog.Nop(), now: func() time.Time { return now },
		bindings: NewDeviceBindingStore(),
		ledger:   make(map[string]enqueueLedgerEntry),
	}
	svc1.SetMDAStore(store)
	_ = svc1.bindings.Claim("p-dur", "C02DURABLE1")
	svc1.persistBinding("p-dur")
	if !svc1.verifyAndUpgrade("p-dur", "s1", [][]byte{leafDER, rootDER}, seKey, seHash[:]) {
		t.Fatal("verifyAndUpgrade failed")
	}

	reg2 := pool.NewRegistry(nil)
	reg2.RegisterAtDetailed(&pool.Provider{
		ProviderID: "p-dur", AssignedID: "s2", ModelID: "m", State: pool.StateReady,
		SlotsFree: 1, SlotsTotal: 1, SEPublicKey: seKey, AuthState: pool.AuthBearerValidated,
		MaxConcurrency: 1, MaxContextTokens: 8000,
		AttestationTier: pool.AttestationTierSelfSigned,
	}, nil, now)
	svc2 := &LiveMDAService{
		cfg: cfg, mdmCfg: config.Tier2MDMConfig{MDARefreshIntervalHours: 168},
		pool: reg2, log: zerolog.Nop(), now: func() time.Time { return now },
		bindings: NewDeviceBindingStore(),
		ledger:   make(map[string]enqueueLedgerEntry),
	}
	svc2.SetMDAStore(store)
	if !svc2.AttachCachedMDAProof("p-dur", "s2") {
		t.Fatal("AttachCachedMDAProof should restore hardware from durable store")
	}
	p, found := reg2.Resolve("p-dur", "s2")
	if !found || p.AttestationTier != pool.AttestationTierHardware {
		t.Fatalf("tier=%q found=%v want hardware", p.AttestationTier, found)
	}

	reg3 := pool.NewRegistry(nil)
	reg3.RegisterAtDetailed(&pool.Provider{
		ProviderID: "p-dur", AssignedID: "s3", ModelID: "m", State: pool.StateReady,
		SlotsFree: 1, SlotsTotal: 1, SEPublicKey: seKey, AuthState: pool.AuthBearerValidated,
		MaxConcurrency: 1, MaxContextTokens: 8000,
	}, nil, now)
	later := now.Add(200 * time.Hour)
	svc3 := &LiveMDAService{
		cfg: cfg, mdmCfg: config.Tier2MDMConfig{MDARefreshIntervalHours: 168},
		pool: reg3, log: zerolog.Nop(), now: func() time.Time { return later },
		bindings: NewDeviceBindingStore(),
		ledger:   make(map[string]enqueueLedgerEntry),
	}
	svc3.SetMDAStore(store)
	if svc3.AttachCachedMDAProof("p-dur", "s3") {
		t.Fatal("expired durable proof must not upgrade")
	}
	if _, _, _, _, ok := reg3.MDAProof("p-dur"); ok {
		t.Fatal("expired durable proof must be cleared from pool")
	}
	if _, ok, _ := store.LoadProof(context.Background(), "p-dur"); ok {
		t.Fatal("expired durable proof must be deleted from store")
	}
}

func TestLoadMDAProofCacheDoesNotPublishHardware(t *testing.T) {
	reg := pool.NewRegistry(nil)
	now := time.Unix(1716768000, 0).UTC()
	seHash := sha256.Sum256([]byte("se"))
	reg.RegisterAtDetailed(&pool.Provider{
		ProviderID: "p-load", AssignedID: "s1", ModelID: "m", State: pool.StateReady,
		SlotsFree: 1, SlotsTotal: 1, AuthState: pool.AuthBearerValidated,
		MaxConcurrency: 1, MaxContextTokens: 8000,
		AttestationTier: pool.AttestationTierSelfSigned,
	}, nil, now)
	if !reg.LoadMDAProofCache("p-load", "s1", [][]byte{[]byte("leaf")}, seHash[:], now, "SERIAL") {
		t.Fatal("LoadMDAProofCache failed")
	}
	p, ok := reg.Resolve("p-load", "s1")
	if !ok {
		t.Fatal("resolve failed")
	}
	if p.AttestationTier == pool.AttestationTierHardware {
		t.Fatal("R3-M1/M2: LoadMDAProofCache must not publish hardware tier")
	}
	if len(p.MDACertChain) == 0 {
		t.Fatal("expected proof bytes loaded")
	}
}

func TestClaimDeviceRejectsUnenrolledMicroMDMRow(t *testing.T) {
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		_ = json.NewEncoder(w).Encode(listDevicesResponse{
			Devices: []Device{{UDID: "STALE-UDID", SerialNumber: "STALESERIAL1", EnrollmentStatus: false}},
		})
	}))
	defer srv.Close()
	client, _ := NewClient(ClientConfig{BaseURL: srv.URL, APIToken: "tok"})
	svc := &LiveMDAService{
		client: client, bindings: NewDeviceBindingStore(), log: zerolog.Nop(), now: time.Now,
	}
	if err := svc.ClaimDevice(context.Background(), "prov", "STALESERIAL1", false); err != ErrPendingClaimRejected {
		t.Fatalf("token claim err=%v want ErrPendingClaimRejected", err)
	}
	if err := svc.ClaimDevice(context.Background(), "prov", "STALESERIAL1", true); err != ErrPendingClaimRejected {
		t.Fatalf("internal claim err=%v want ErrPendingClaimRejected", err)
	}
}

func TestClaimDeviceRejectsEnrolledEmptyUDID(t *testing.T) {
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		_ = json.NewEncoder(w).Encode(listDevicesResponse{
			Devices: []Device{{UDID: "", SerialNumber: "EMPTYUDID001", EnrollmentStatus: true}},
		})
	}))
	defer srv.Close()
	client, _ := NewClient(ClientConfig{BaseURL: srv.URL, APIToken: "tok"})
	svc := &LiveMDAService{
		client: client, bindings: NewDeviceBindingStore(), log: zerolog.Nop(), now: time.Now,
	}
	if err := svc.ClaimDevice(context.Background(), "prov", "EMPTYUDID001", true); err != ErrPendingClaimRejected {
		t.Fatalf("empty UDID claim err=%v want ErrPendingClaimRejected", err)
	}
}

func TestDurableDeviceBindingSurvivesNewService(t *testing.T) {
	dir := t.TempDir()
	dbPath := filepath.Join(dir, "coordinator.db")
	store, err := OpenMDAStore(dbPath)
	if err != nil {
		t.Fatalf("open store: %v", err)
	}
	defer store.Close()

	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if r.URL.Path == "/v1/devices" {
			_ = json.NewEncoder(w).Encode(listDevicesResponse{
				Devices: []Device{{UDID: "BIND-UDID", SerialNumber: "BINDSERIAL01", EnrollmentStatus: true}},
			})
			return
		}
		w.WriteHeader(http.StatusOK)
	}))
	defer srv.Close()
	client, _ := NewClient(ClientConfig{BaseURL: srv.URL, APIToken: "tok"})

	svc1 := &LiveMDAService{
		client: client, bindings: NewDeviceBindingStore(), log: zerolog.Nop(), now: time.Now,
		pending: make(map[string]pendingMDARequest), ledger: make(map[string]enqueueLedgerEntry),
		mdmCfg: config.Tier2MDMConfig{MDARefreshIntervalHours: 168},
	}
	svc1.SetMDAStore(store)
	if err := svc1.ClaimDevice(context.Background(), "owner", "BINDSERIAL01", true); err != nil {
		t.Fatalf("bootstrap: %v", err)
	}

	reg := pool.NewRegistry(nil)
	now := time.Unix(1716768000, 0).UTC()
	seKey := make([]byte, 64)
	reg.RegisterAtDetailed(&pool.Provider{
		ProviderID: "owner", AssignedID: "asg-1", ModelID: "m", State: pool.StateReady,
		SlotsFree: 1, SlotsTotal: 1, SEPublicKey: seKey, AuthState: pool.AuthBearerValidated,
		MaxConcurrency: 1, MaxContextTokens: 8000,
	}, nil, now)

	var enqueued atomic.Value
	srv2 := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if strings.HasPrefix(r.URL.Path, "/v1/commands/") {
			enqueued.Store(r.URL.Path)
		}
		w.WriteHeader(http.StatusOK)
	}))
	defer srv2.Close()
	client2, _ := NewClient(ClientConfig{BaseURL: srv2.URL, APIToken: "tok"})

	svc2 := &LiveMDAService{
		client: client2, pool: reg, bindings: NewDeviceBindingStore(), log: zerolog.Nop(),
		now:     func() time.Time { return now },
		pending: make(map[string]pendingMDARequest), ledger: make(map[string]enqueueLedgerEntry),
		mdmCfg: config.Tier2MDMConfig{MDARefreshIntervalHours: 168},
	}
	svc2.SetMDAStore(store)
	b, ok := svc2.Bindings().LookupByProvider("owner")
	if !ok || b.Serial != "BINDSERIAL01" || b.UDID != "BIND-UDID" {
		t.Fatalf("hydrated binding=%v ok=%v", b, ok)
	}
	svc2.RequestAndMaybeUpgrade("owner", "asg-1", "BINDSERIAL01")
	if got, _ := enqueued.Load().(string); got != "/v1/commands/BIND-UDID" {
		t.Fatalf("enqueue path=%q want /v1/commands/BIND-UDID", got)
	}
}

func TestDurablePendingSurvivesNewServiceWebhook(t *testing.T) {
	dir := t.TempDir()
	dbPath := filepath.Join(dir, "coordinator.db")
	store, err := OpenMDAStore(dbPath)
	if err != nil {
		t.Fatalf("open store: %v", err)
	}
	defer store.Close()

	now := time.Unix(1716768000, 0).UTC()
	seKey := make([]byte, 64)
	for i := range seKey {
		seKey[i] = byte(i + 7)
	}
	seHash := sha256.Sum256(seKey)
	rootDER, leafDER, cfg := testMDAChainWithSerial(t, now, seHash[:], "C02PENDING1")

	reg1 := pool.NewRegistry(nil)
	reg1.RegisterAtDetailed(&pool.Provider{
		ProviderID: "p-pend", AssignedID: "s1", ModelID: "m", State: pool.StateReady,
		SlotsFree: 1, SlotsTotal: 1, SEPublicKey: seKey, AuthState: pool.AuthBearerValidated,
		MaxConcurrency: 1, MaxContextTokens: 8000,
	}, nil, now)
	svc1 := &LiveMDAService{
		cfg: cfg, mdmCfg: config.Tier2MDMConfig{CommandWebhookSecret: "hook-secret", MDARefreshIntervalHours: 168},
		pool: reg1, log: zerolog.Nop(), now: func() time.Time { return now },
		bindings: NewDeviceBindingStore(), pending: make(map[string]pendingMDARequest),
		ledger: make(map[string]enqueueLedgerEntry),
	}
	svc1.SetMDAStore(store)
	_ = svc1.bindings.Claim("p-pend", "C02PENDING1")
	svc1.bindings.SetUDID("C02PENDING1", "UDID-PEND")
	svc1.persistBinding("p-pend")
	svc1.recordPending("UDID-PEND", "cmd-durable-1", pendingMDARequest{
		ProviderID: "p-pend", AssignedID: "s1", ExpectedSerial: "C02PENDING1",
		UDID: "UDID-PEND", CommandUUID: "cmd-durable-1", SEKeyHash: seHash[:], EnqueuedAt: now,
	})
	svc1.markEnqueued(enqueueLedgerKey("p-pend", "C02PENDING1", seHash[:]), "p-pend", "C02PENDING1", seHash[:], "cmd-durable-1")

	reg2 := pool.NewRegistry(nil)
	reg2.RegisterAtDetailed(&pool.Provider{
		ProviderID: "p-pend", AssignedID: "s1", ModelID: "m", State: pool.StateReady,
		SlotsFree: 1, SlotsTotal: 1, SEPublicKey: seKey, AuthState: pool.AuthBearerValidated,
		MaxConcurrency: 1, MaxContextTokens: 8000,
	}, nil, now)
	svc2 := &LiveMDAService{
		cfg: cfg, mdmCfg: config.Tier2MDMConfig{CommandWebhookSecret: "hook-secret", MDARefreshIntervalHours: 168},
		pool: reg2, log: zerolog.Nop(), now: func() time.Time { return now },
		bindings: NewDeviceBindingStore(), pending: make(map[string]pendingMDARequest),
		ledger: make(map[string]enqueueLedgerEntry),
	}
	svc2.SetMDAStore(store)

	body, _ := json.Marshal(map[string]interface{}{
		"udid":         "UDID-PEND",
		"command_uuid": "cmd-durable-1",
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
	svc2.HandleMDACommandWebhook(rr, req)
	if rr.Code != http.StatusNoContent {
		t.Fatalf("webhook status=%d body=%s", rr.Code, rr.Body.String())
	}
	p, found := reg2.Resolve("p-pend", "s1")
	if !found || p.AttestationTier != pool.AttestationTierHardware {
		t.Fatalf("tier=%q found=%v want hardware after restart webhook", p.AttestationTier, found)
	}
}

func TestConcurrentEnqueueOnlyOnce(t *testing.T) {
	var enqueueCount atomic.Int32
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if r.URL.Path == "/v1/devices" {
			_ = json.NewEncoder(w).Encode(listDevicesResponse{
				Devices: []Device{{UDID: "CONC-UDID", SerialNumber: "CONCSERIAL01", EnrollmentStatus: true}},
			})
			return
		}
		enqueueCount.Add(1)
		time.Sleep(20 * time.Millisecond) // widen TOCTOU window without reservation
		w.WriteHeader(http.StatusOK)
	}))
	defer srv.Close()
	client, _ := NewClient(ClientConfig{BaseURL: srv.URL, APIToken: "tok"})
	reg := pool.NewRegistry(nil)
	now := time.Unix(1716768000, 0).UTC()
	seKey := make([]byte, 64)
	reg.RegisterAtDetailed(&pool.Provider{
		ProviderID: "conc", AssignedID: "asg-1", ModelID: "m", State: pool.StateReady,
		SlotsFree: 1, SlotsTotal: 1, SEPublicKey: seKey, AuthState: pool.AuthBearerValidated,
		MaxConcurrency: 1, MaxContextTokens: 8000,
	}, nil, now)
	svc := &LiveMDAService{
		client: client, pool: reg, log: zerolog.Nop(), now: func() time.Time { return now },
		bindings: NewDeviceBindingStore(), pending: make(map[string]pendingMDARequest),
		ledger: make(map[string]enqueueLedgerEntry),
		mdmCfg: config.Tier2MDMConfig{MDARefreshIntervalHours: 168},
	}
	if err := svc.ClaimDevice(context.Background(), "conc", "CONCSERIAL01", true); err != nil {
		t.Fatalf("claim: %v", err)
	}

	const n = 16
	var wg sync.WaitGroup
	wg.Add(n)
	for i := 0; i < n; i++ {
		go func() {
			defer wg.Done()
			svc.RequestAndMaybeUpgrade("conc", "asg-1", "CONCSERIAL01")
		}()
	}
	wg.Wait()
	if enqueueCount.Load() != 1 {
		t.Fatalf("concurrent enqueue count=%d want 1", enqueueCount.Load())
	}
}

// R5-M1: pending AssignedID=s1 survives reconnect as s2; webhook upgrades s2.
func TestWebhookUpgradeUsesCurrentAssignedIDAfterReconnect(t *testing.T) {
	now := time.Unix(1716768000, 0).UTC()
	seKey := make([]byte, 64)
	for i := range seKey {
		seKey[i] = byte(i + 11)
	}
	seHash := sha256.Sum256(seKey)
	rootDER, leafDER, cfg := testMDAChainWithSerial(t, now, seHash[:], "C02RECONN01")

	reg := pool.NewRegistry(nil)
	reg.RegisterAtDetailed(&pool.Provider{
		ProviderID: "p-reconn", AssignedID: "s2", ModelID: "m", State: pool.StateReady,
		SlotsFree: 1, SlotsTotal: 1, SEPublicKey: seKey, AuthState: pool.AuthBearerValidated,
		MaxConcurrency: 1, MaxContextTokens: 8000,
		AttestationTier: pool.AttestationTierSelfSigned,
	}, nil, now)

	svc := &LiveMDAService{
		cfg: cfg, mdmCfg: config.Tier2MDMConfig{CommandWebhookSecret: "hook-secret", MDARefreshIntervalHours: 168},
		pool: reg, log: zerolog.Nop(), now: func() time.Time { return now },
		bindings: NewDeviceBindingStore(), pending: make(map[string]pendingMDARequest),
		ledger: make(map[string]enqueueLedgerEntry),
	}
	_ = svc.bindings.Claim("p-reconn", "C02RECONN01")
	// Stale pending session from pre-reconnect enqueue.
	svc.recordPending("UDID-RECONN", "cmd-reconn-1", pendingMDARequest{
		ProviderID: "p-reconn", AssignedID: "s1", ExpectedSerial: "C02RECONN01",
		UDID: "UDID-RECONN", CommandUUID: "cmd-reconn-1", SEKeyHash: seHash[:], EnqueuedAt: now,
	})

	body, _ := json.Marshal(map[string]interface{}{
		"udid":         "UDID-RECONN",
		"command_uuid": "cmd-reconn-1",
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
		t.Fatalf("webhook status=%d body=%s", rr.Code, rr.Body.String())
	}
	p, found := reg.Resolve("p-reconn", "s2")
	if !found || p.AttestationTier != pool.AttestationTierHardware {
		t.Fatalf("tier=%q found=%v want hardware on current session s2", p.AttestationTier, found)
	}
	if _, foundOld := reg.Resolve("p-reconn", "s1"); foundOld {
		t.Fatal("stale session s1 must not be live")
	}
}

// R5-M2: cached reattach without a device binding must not publish hardware.
func TestCachedMDARefusesWithoutBinding(t *testing.T) {
	now := time.Unix(1716768000, 0).UTC()
	seKey := make([]byte, 64)
	for i := range seKey {
		seKey[i] = byte(i + 21)
	}
	seHash := sha256.Sum256(seKey)
	rootDER, leafDER, cfg := testMDAChainWithSerial(t, now, seHash[:], "C02NOBIND01")

	reg := pool.NewRegistry(nil)
	reg.RegisterAtDetailed(&pool.Provider{
		ProviderID: "p-nobind", AssignedID: "s1", ModelID: "m", State: pool.StateReady,
		SlotsFree: 1, SlotsTotal: 1, SEPublicKey: seKey, AuthState: pool.AuthBearerValidated,
		MaxConcurrency: 1, MaxContextTokens: 8000,
		AttestationTier: pool.AttestationTierSelfSigned,
	}, nil, now)
	if !reg.LoadMDAProofCache("p-nobind", "s1", [][]byte{leafDER, rootDER}, seHash[:], now, "C02NOBIND01") {
		t.Fatal("LoadMDAProofCache failed")
	}

	svc := &LiveMDAService{
		cfg: cfg, mdmCfg: config.Tier2MDMConfig{MDARefreshIntervalHours: 168},
		pool: reg, log: zerolog.Nop(), now: func() time.Time { return now },
		bindings: NewDeviceBindingStore(),
	}
	if svc.AttachCachedMDAProof("p-nobind", "s1") {
		t.Fatal("R5-M2: cached upgrade without binding must fail")
	}
	p, found := reg.Resolve("p-nobind", "s1")
	if !found || p.AttestationTier == pool.AttestationTierHardware {
		t.Fatalf("tier=%q found=%v want non-hardware when binding absent", p.AttestationTier, found)
	}
	if _, _, _, _, ok := reg.MDAProof("p-nobind"); !ok {
		t.Fatal("binding-absent refuse should leave cache bytes (not clear)")
	}
}

// R5-M2: binding serial change refuses cached hardware and clears proof.
func TestCachedMDARefusesBindingSerialMismatch(t *testing.T) {
	now := time.Unix(1716768000, 0).UTC()
	seKey := make([]byte, 64)
	for i := range seKey {
		seKey[i] = byte(i + 31)
	}
	seHash := sha256.Sum256(seKey)
	rootDER, leafDER, cfg := testMDAChainWithSerial(t, now, seHash[:], "C02OLDDEV01")

	reg := pool.NewRegistry(nil)
	reg.RegisterAtDetailed(&pool.Provider{
		ProviderID: "p-mismatch", AssignedID: "s1", ModelID: "m", State: pool.StateReady,
		SlotsFree: 1, SlotsTotal: 1, SEPublicKey: seKey, AuthState: pool.AuthBearerValidated,
		MaxConcurrency: 1, MaxContextTokens: 8000,
		AttestationTier: pool.AttestationTierSelfSigned,
	}, nil, now)
	if !reg.LoadMDAProofCache("p-mismatch", "s1", [][]byte{leafDER, rootDER}, seHash[:], now, "C02OLDDEV01") {
		t.Fatal("LoadMDAProofCache failed")
	}

	svc := &LiveMDAService{
		cfg: cfg, mdmCfg: config.Tier2MDMConfig{MDARefreshIntervalHours: 168},
		pool: reg, log: zerolog.Nop(), now: func() time.Time { return now },
		bindings: NewDeviceBindingStore(),
	}
	_ = svc.bindings.Claim("p-mismatch", "C02NEWDEV99")
	if svc.AttachCachedMDAProof("p-mismatch", "s1") {
		t.Fatal("R5-M2: binding serial mismatch must refuse cached upgrade")
	}
	p, found := reg.Resolve("p-mismatch", "s1")
	if !found || p.AttestationTier == pool.AttestationTierHardware {
		t.Fatalf("tier=%q found=%v want non-hardware after mismatch", p.AttestationTier, found)
	}
	if _, _, _, _, ok := reg.MDAProof("p-mismatch"); ok {
		t.Fatal("serial mismatch should ClearMDAProof")
	}
}

// R5-M2: matching binding allows cached hardware upgrade.
func TestCachedMDAAllowsMatchingBinding(t *testing.T) {
	now := time.Unix(1716768000, 0).UTC()
	seKey := make([]byte, 64)
	for i := range seKey {
		seKey[i] = byte(i + 41)
	}
	seHash := sha256.Sum256(seKey)
	rootDER, leafDER, cfg := testMDAChainWithSerial(t, now, seHash[:], "C02MATCH001")

	reg := pool.NewRegistry(nil)
	reg.RegisterAtDetailed(&pool.Provider{
		ProviderID: "p-match", AssignedID: "s1", ModelID: "m", State: pool.StateReady,
		SlotsFree: 1, SlotsTotal: 1, SEPublicKey: seKey, AuthState: pool.AuthBearerValidated,
		MaxConcurrency: 1, MaxContextTokens: 8000,
		AttestationTier: pool.AttestationTierSelfSigned,
	}, nil, now)
	if !reg.LoadMDAProofCache("p-match", "s1", [][]byte{leafDER, rootDER}, seHash[:], now, "C02MATCH001") {
		t.Fatal("LoadMDAProofCache failed")
	}

	svc := &LiveMDAService{
		cfg: cfg, mdmCfg: config.Tier2MDMConfig{MDARefreshIntervalHours: 168},
		pool: reg, log: zerolog.Nop(), now: func() time.Time { return now },
		bindings: NewDeviceBindingStore(),
	}
	_ = svc.bindings.Claim("p-match", "c02match001") // case-insensitive
	if !svc.AttachCachedMDAProof("p-match", "s1") {
		t.Fatal("matching binding should allow cached hardware upgrade")
	}
	p, found := reg.Resolve("p-match", "s1")
	if !found || p.AttestationTier != pool.AttestationTierHardware {
		t.Fatalf("tier=%q found=%v want hardware", p.AttestationTier, found)
	}
}

// R6-M1: enqueue pending for serial A, rebind provider to B, deliver webhook for A
// → must not publish hardware (rebind TOCTOU).
func TestWebhookRefusesAfterRebindSerialChange(t *testing.T) {
	now := time.Unix(1716768000, 0).UTC()
	seKey := make([]byte, 64)
	for i := range seKey {
		seKey[i] = byte(i + 51)
	}
	seHash := sha256.Sum256(seKey)
	rootDER, leafDER, cfg := testMDAChainWithSerial(t, now, seHash[:], "C02SERIAL-A")

	reg := pool.NewRegistry(nil)
	reg.RegisterAtDetailed(&pool.Provider{
		ProviderID: "p-rebind", AssignedID: "s1", ModelID: "m", State: pool.StateReady,
		SlotsFree: 1, SlotsTotal: 1, SEPublicKey: seKey, AuthState: pool.AuthBearerValidated,
		MaxConcurrency: 1, MaxContextTokens: 8000,
		AttestationTier: pool.AttestationTierSelfSigned,
	}, nil, now)

	svc := &LiveMDAService{
		cfg: cfg, mdmCfg: config.Tier2MDMConfig{CommandWebhookSecret: "hook-secret", MDARefreshIntervalHours: 168},
		pool: reg, log: zerolog.Nop(), now: func() time.Time { return now },
		bindings: NewDeviceBindingStore(), pending: make(map[string]pendingMDARequest),
		ledger: make(map[string]enqueueLedgerEntry),
	}
	_ = svc.bindings.Claim("p-rebind", "C02SERIAL-A")
	svc.recordPending("UDID-A", "cmd-rebind-a", pendingMDARequest{
		ProviderID: "p-rebind", AssignedID: "s1", ExpectedSerial: "C02SERIAL-A",
		UDID: "UDID-A", CommandUUID: "cmd-rebind-a", SEKeyHash: seHash[:], EnqueuedAt: now,
	})
	// Ops rebind A→B while webhook for A is still pending.
	_ = svc.bindings.Claim("p-rebind", "C02SERIAL-B")

	body, _ := json.Marshal(map[string]interface{}{
		"udid":         "UDID-A",
		"command_uuid": "cmd-rebind-a",
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
	if rr.Code != http.StatusForbidden {
		t.Fatalf("R6-M1: rebind webhook status=%d want 403, body=%s", rr.Code, rr.Body.String())
	}
	p, found := reg.Resolve("p-rebind", "s1")
	if !found || p.AttestationTier == pool.AttestationTierHardware {
		t.Fatalf("R6-M1: tier=%q found=%v want non-hardware after A webhook post-rebind-to-B", p.AttestationTier, found)
	}
	if _, _, _, _, ok := reg.MDAProof("p-rebind"); ok {
		t.Fatal("R6-M1: must not SetMDAProof after binding rebind mismatch")
	}
}

// R7-M1: after SetMDAProof/hardware for serial A, ClaimDevice to B must clear
// live+durable MDA proof, downgrade tier, and refuse a stale A webhook.
func TestClaimDeviceClearsHardwareOnSerialRebind(t *testing.T) {
	dir := t.TempDir()
	store, err := OpenMDAStore(filepath.Join(dir, "coordinator.db"))
	if err != nil {
		t.Fatalf("open store: %v", err)
	}
	defer store.Close()

	now := time.Unix(1716768000, 0).UTC()
	seKey := make([]byte, 64)
	for i := range seKey {
		seKey[i] = byte(i + 61)
	}
	seHash := sha256.Sum256(seKey)
	rootDER, leafDER, cfg := testMDAChainWithSerial(t, now, seHash[:], "C02SERIAL-A")

	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		_ = json.NewEncoder(w).Encode(listDevicesResponse{
			Devices: []Device{
				{UDID: "UDID-A", SerialNumber: "C02SERIAL-A", EnrollmentStatus: true},
				{UDID: "UDID-B", SerialNumber: "C02SERIAL-B", EnrollmentStatus: true},
			},
		})
	}))
	defer srv.Close()
	client, _ := NewClient(ClientConfig{BaseURL: srv.URL, APIToken: "tok"})

	reg := pool.NewRegistry(nil)
	reg.RegisterAtDetailed(&pool.Provider{
		ProviderID: "p-r7", AssignedID: "s1", ModelID: "m", State: pool.StateReady,
		SlotsFree: 1, SlotsTotal: 1, SEPublicKey: seKey, AuthState: pool.AuthBearerValidated,
		MaxConcurrency: 1, MaxContextTokens: 8000,
		AttestationTier: pool.AttestationTierSelfSigned,
	}, nil, now)

	svc := &LiveMDAService{
		client: client,
		cfg:    cfg, mdmCfg: config.Tier2MDMConfig{CommandWebhookSecret: "hook-secret", MDARefreshIntervalHours: 168},
		pool: reg, log: zerolog.Nop(), now: func() time.Time { return now },
		bindings: NewDeviceBindingStore(), pending: make(map[string]pendingMDARequest),
		ledger: make(map[string]enqueueLedgerEntry),
	}
	svc.SetMDAStore(store)

	if err := svc.ClaimDevice(context.Background(), "p-r7", "C02SERIAL-A", true); err != nil {
		t.Fatalf("claim A: %v", err)
	}
	if !svc.verifyAndUpgrade("p-r7", "s1", [][]byte{leafDER, rootDER}, seKey, seHash[:]) {
		t.Fatal("verifyAndUpgrade A failed")
	}
	p, found := reg.Resolve("p-r7", "s1")
	if !found || p.AttestationTier != pool.AttestationTierHardware {
		t.Fatalf("pre-rebind tier=%q found=%v want hardware", p.AttestationTier, found)
	}
	if _, ok, err := store.LoadProof(context.Background(), "p-r7"); err != nil || !ok {
		t.Fatalf("pre-rebind durable proof ok=%v err=%v", ok, err)
	}

	svc.recordPending("UDID-A", "cmd-r7-a", pendingMDARequest{
		ProviderID: "p-r7", AssignedID: "s1", ExpectedSerial: "C02SERIAL-A",
		UDID: "UDID-A", CommandUUID: "cmd-r7-a", SEKeyHash: seHash[:], EnqueuedAt: now,
	})

	if err := svc.ClaimDevice(context.Background(), "p-r7", "C02SERIAL-B", true); err != nil {
		t.Fatalf("rebind claim B: %v", err)
	}

	p, found = reg.Resolve("p-r7", "s1")
	if !found || p.AttestationTier == pool.AttestationTierHardware {
		t.Fatalf("R7-M1: tier=%q found=%v want non-hardware after rebind A→B", p.AttestationTier, found)
	}
	if _, _, _, _, ok := reg.MDAProof("p-r7"); ok {
		t.Fatal("R7-M1: in-memory MDAProof must be cleared after rebind")
	}
	if _, ok, err := store.LoadProof(context.Background(), "p-r7"); err != nil {
		t.Fatalf("durable load: %v", err)
	} else if ok {
		t.Fatal("R7-M1: durable MDA proof must be deleted after rebind")
	}
	b, ok := svc.Bindings().LookupByProvider("p-r7")
	if !ok || b.Serial != "C02SERIAL-B" {
		t.Fatalf("binding after rebind=%v ok=%v want C02SERIAL-B", b, ok)
	}

	// Stale A webhook must not restore hardware (pending cleared and/or binding mismatch).
	body, _ := json.Marshal(map[string]interface{}{
		"udid":         "UDID-A",
		"command_uuid": "cmd-r7-a",
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
	if rr.Code == http.StatusOK {
		t.Fatalf("R7-M1: stale A webhook status=%d must not succeed", rr.Code)
	}
	p, found = reg.Resolve("p-r7", "s1")
	if !found || p.AttestationTier == pool.AttestationTierHardware {
		t.Fatalf("R7-M1: tier=%q after stale A webhook want non-hardware", p.AttestationTier)
	}
	if _, _, _, _, ok := reg.MDAProof("p-r7"); ok {
		t.Fatal("R7-M1: stale A webhook must not SetMDAProof")
	}
}
