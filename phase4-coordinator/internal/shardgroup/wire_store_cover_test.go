package shardgroup

import (
	"context"
	"database/sql"
	"errors"
	"path/filepath"
	"reflect"
	"strings"
	"testing"

	"github.com/augstar/macprovider-coordinator/internal/pool"
)

func TestParseHeartbeatAndMemberHealthStrict(t *testing.T) {
	hb := heartbeatPayload(2, true, 500, "thunderbolt")
	msg, err := ParseHeartbeat(hb)
	if err != nil || msg.GroupEpoch != 2 || len(msg.Links) != 2 {
		t.Fatalf("valid heartbeat: %+v %v", msg, err)
	}
	if _, err := ParseHeartbeat([]byte(strings.Replace(string(hb), TypeHeartbeat, TypeStatus, 1))); err == nil {
		t.Error("heartbeat with wrong type accepted")
	}
	if _, err := ParseHeartbeat([]byte(strings.Replace(string(hb), `"version":1`, `"version":2`, 1))); err == nil {
		t.Error("heartbeat with wrong version accepted")
	}
	if _, err := ParseHeartbeat([]byte(`{`)); err == nil {
		t.Error("truncated heartbeat accepted")
	}

	mh := memberHealthPayload("tail", 1, true, "thunderbolt", 400, "head")
	h, err := ParseMemberHealth(mh)
	if err != nil || h.MemberDeviceID != "tail" || !h.Healthy {
		t.Fatalf("valid member health: %+v %v", h, err)
	}
	bad := map[string]string{
		"wrong type":               strings.Replace(string(mh), TypeMemberHealth, TypeHeartbeat, 1),
		"wrong version":            strings.Replace(string(mh), `"version":1`, `"version":3`, 1),
		"healthy w/ reason":        strings.Replace(string(mh), `"reason":""`, `"reason":"link_down"`, 1),
		"unhealthy no reason":      strings.Replace(string(mh), `"healthy":true`, `"healthy":false`, 1),
		"unhealthy unknown reason": strings.Replace(strings.Replace(string(mh), `"healthy":true`, `"healthy":false`, 1), `"reason":""`, `"reason":"bored"`, 1),
	}
	for name, p := range bad {
		if p == string(mh) {
			t.Fatalf("%s: mutation did not apply", name)
		}
		if _, err := ParseMemberHealth([]byte(p)); err == nil {
			t.Errorf("%s accepted", name)
		}
	}
	down := memberHealthPayload("tail", 1, false, "thunderbolt", 400, "head")
	if h, err := ParseMemberHealth(down); err != nil || h.Healthy || h.Reason != "link_down" {
		t.Errorf("unhealthy report with closed reason refused: %+v %v", h, err)
	}
}

func TestParseRegisterAndHelloRefusals(t *testing.T) {
	f := newFixture(t)
	good := f.registerPayload(twoStageRecord(1))
	msg, rec, err := ParseRegister(good)
	if err != nil || msg.Type != TypeRegister || rec.GroupEpoch != 1 || len(rec.Stages) != 2 {
		t.Fatalf("valid register: %v", err)
	}
	for name, p := range map[string]string{
		"wrong type":    strings.Replace(string(good), TypeRegister, TypeHeartbeat, 1),
		"wrong version": strings.Replace(string(good), `"version":1`, `"version":2`, 1),
		"not json":      `nope`,
	} {
		if _, _, err := ParseRegister([]byte(p)); err == nil {
			t.Errorf("%s accepted", name)
		}
	}
	// A malformed inner record (unknown key) is refused even when the
	// envelope is well formed.
	badRec := strings.Replace(string(good), `"schema"`, `"extra":1,"schema"`, 1)
	if badRec == string(good) {
		t.Fatal("mutation did not apply")
	}
	if _, _, err := ParseRegister([]byte(badRec)); err == nil {
		t.Error("record with unknown key accepted")
	}
	hello := helloPayload("tail", 1, 1, 18, 32, "thunderbolt", "head")
	if _, err := ParseMemberHello([]byte(strings.Replace(string(hello), `"version":1`, `"version":9`, 1))); err == nil {
		t.Error("hello with wrong version accepted")
	}
}

func TestDecodeStrictNullAndDuplicateNested(t *testing.T) {
	good := string(heartbeatPayload(1, true, 100, "thunderbolt"))
	// Duplicate key inside a nested array element is refused.
	dup := strings.Replace(good, `"healthy":true`, `"healthy":true,"healthy":true`, 1)
	if _, err := ParseHeartbeat([]byte(dup)); err == nil {
		t.Error("nested duplicate key accepted")
	}
	// A null scalar field is a missing field.
	nul := strings.Replace(good, `"interface_type":"thunderbolt"`, `"interface_type":null`, 1)
	if _, err := ParseHeartbeat([]byte(nul)); err == nil {
		t.Error("null field accepted")
	}
	// A bare scalar is not an object.
	if _, err := ParseHeartbeat([]byte(`7`)); err == nil {
		t.Error("scalar accepted as heartbeat")
	}
}

func TestStoreAcceptRecordEpochRules(t *testing.T) {
	f := newFixture(t)
	ctx := context.Background()
	rec := StoredRecord{GroupProviderID: "g", GroupEpoch: 2, RecordJSON: "{}", RecordDigest: "d2", RecordSignature: "s"}
	if created, err := f.store.AcceptRecord(ctx, rec, 1); err != nil || !created {
		t.Fatalf("first accept: %v %v", created, err)
	}
	if created, err := f.store.AcceptRecord(ctx, rec, 2); err != nil || created {
		t.Fatalf("identical re-accept: created=%v err=%v", created, err)
	}
	same := rec
	same.RecordDigest = "other"
	if _, err := f.store.AcceptRecord(ctx, same, 3); !errors.Is(err, ErrEpochNotIncreasing) {
		t.Errorf("same epoch different digest: %v", err)
	}
	lower := rec
	lower.GroupEpoch = 1
	lower.RecordDigest = "d1"
	if _, err := f.store.AcceptRecord(ctx, lower, 4); !errors.Is(err, ErrEpochNotIncreasing) {
		t.Errorf("lower epoch: %v", err)
	}
	higher := rec
	higher.GroupEpoch = 3
	higher.RecordDigest = "d3"
	if created, err := f.store.AcceptRecord(ctx, higher, 5); err != nil || !created {
		t.Fatalf("higher epoch: %v %v", created, err)
	}
	got, ok, err := f.store.LatestRecord(ctx, "g")
	if err != nil || !ok || got.GroupEpoch != 3 || got.RecordDigest != "d3" {
		t.Errorf("latest = %+v %v %v", got, ok, err)
	}
	if _, ok, err := f.store.LatestRecord(ctx, "absent"); err != nil || ok {
		t.Errorf("absent group: ok=%v err=%v", ok, err)
	}
}

func TestStoreNilDBAndClosedDBErrors(t *testing.T) {
	if _, err := NewStore(nil); err == nil {
		t.Error("nil db accepted")
	}
	db, err := sql.Open("sqlite", filepath.Join(t.TempDir(), "x.db"))
	if err != nil {
		t.Fatal(err)
	}
	s, err := NewStore(db)
	if err != nil {
		t.Fatal(err)
	}
	ctx := context.Background()
	if err := s.RecordAttestation(ctx, AttestationRecord{RequestID: "r", AttemptN: 1, GroupProviderID: "g", Verified: true, TakeoverFromEpoch: 4, TakeoverReason: "member_fault"}, 1); err != nil {
		t.Fatal(err)
	}
	got, ok, err := s.Attestation(ctx, "r", 1, "g")
	if err != nil || !ok || !got.Verified || got.TakeoverFromEpoch != 4 || got.TakeoverReason != "member_fault" {
		t.Fatalf("stored attestation: %+v %v %v", got, ok, err)
	}
	if _, ok, _ := s.Attestation(ctx, "r", 2, "g"); ok {
		t.Error("unknown attempt found")
	}
	_ = db.Close()
	if _, _, err := s.LatestRecord(ctx, "g"); err == nil {
		t.Error("LatestRecord on closed db returned no error")
	}
	if _, _, err := s.Attestation(ctx, "r", 1, "g"); err == nil {
		t.Error("Attestation on closed db returned no error")
	}
	if _, err := s.AcceptRecord(ctx, StoredRecord{GroupProviderID: "g", GroupEpoch: 1}, 1); err == nil {
		t.Error("AcceptRecord on closed db returned no error")
	}
}

func TestRegistryAccessorsAndConfigReload(t *testing.T) {
	f := newFixture(t)
	if _, ok := f.reg.GroupFor("head"); ok {
		t.Error("group known before registration")
	}
	if ids := f.reg.MemberIDs("head"); ids != nil {
		t.Errorf("MemberIDs of unknown group = %v", ids)
	}
	if res, _ := f.register(twoStageRecord(1)); !res.Accepted {
		t.Fatalf("register refused: %s", res.Reason)
	}
	f.hello("tail", helloPayload("tail", 1, 1, 18, 32, "thunderbolt", "head"))
	if g, ok := f.reg.GroupFor("head"); !ok || g != "head" {
		t.Errorf("GroupFor(head) = %q %v", g, ok)
	}
	if g, ok := f.reg.GroupFor("tail"); !ok || g != "head" {
		t.Errorf("GroupFor(tail) = %q %v", g, ok)
	}
	if _, ok := f.reg.GroupFor("stranger"); ok {
		t.Error("stranger mapped to a group")
	}
	if got := f.reg.GroupIDs(); !reflect.DeepEqual(got, []string{"head"}) {
		t.Errorf("GroupIDs = %v", got)
	}
	if got := f.reg.MemberIDs("head"); !reflect.DeepEqual(got, []string{"head", "tail"}) {
		t.Errorf("MemberIDs = %v", got)
	}
	cfg := f.reg.Config()
	cfg.MaxMembers += 7
	f.reg.SetConfig(cfg)
	if f.reg.Config().MaxMembers != cfg.MaxMembers {
		t.Error("SetConfig did not replace the configuration")
	}
}

func TestEvaluationStatusMessage(t *testing.T) {
	ev := Evaluation{GroupProviderID: "head", GroupEpoch: 5, Available: false, Reason: ReasonGroupNotRegistered}
	want := Status{Type: TypeStatus, Version: WireVersion, GroupProviderID: "head", GroupEpoch: 5, Available: false, Reason: ReasonGroupNotRegistered}
	if got := ev.Status(); got != want {
		t.Errorf("Status() = %+v, want %+v", got, want)
	}
	if _, ok := newFixture(t).reg.Evaluate("nope", nil, nil, 0); ok {
		t.Error("Evaluate of unknown group reported ok")
	}
}

func TestLabelsAtLeastOrdering(t *testing.T) {
	base := pool.Provider{Tier: pool.TierTrusted, AttestationTier: pool.AttestationTierSelfSigned}
	cases := []struct {
		name         string
		member, head pool.Provider
		want         bool
	}{
		{"equal", base, base, true},
		{"lower tier", pool.Provider{Tier: pool.TierProvisional, AttestationTier: pool.AttestationTierSelfSigned}, base, false},
		{"higher tier", pool.Provider{Tier: pool.TierPinned, AttestationTier: pool.AttestationTierSelfSigned}, base, true},
		{"unknown member tier", pool.Provider{Tier: "weird"}, base, false},
		{"lower attestation tier", pool.Provider{Tier: pool.TierTrusted}, base, false},
		{"higher attestation tier", pool.Provider{Tier: pool.TierTrusted, AttestationTier: pool.AttestationTierHardware}, base, true},
		{"unknown attestation tier", pool.Provider{Tier: pool.TierTrusted, AttestationTier: "x"}, base, false},
		{"missing encrypted leg", base, pool.Provider{Tier: pool.TierTrusted, AttestationTier: pool.AttestationTierSelfSigned, EncryptedLeg: true}, false},
		{"member extra encrypted leg", pool.Provider{Tier: pool.TierTrusted, AttestationTier: pool.AttestationTierSelfSigned, EncryptedLeg: true}, base, true},
		{"missing attested status", base, pool.Provider{Tier: pool.TierTrusted, AttestationTier: pool.AttestationTierSelfSigned, AttestationStatus: pool.AttestationStatusAttested}, false},
		{"attested both", pool.Provider{Tier: pool.TierTrusted, AttestationTier: pool.AttestationTierSelfSigned, AttestationStatus: pool.AttestationStatusAttested},
			pool.Provider{Tier: pool.TierTrusted, AttestationTier: pool.AttestationTierSelfSigned, AttestationStatus: pool.AttestationStatusAttested}, true},
	}
	for _, c := range cases {
		if got := labelsAtLeast(c.member, c.head); got != c.want {
			t.Errorf("%s: labelsAtLeast = %v, want %v", c.name, got, c.want)
		}
	}
}

func TestMemberLinkPeers(t *testing.T) {
	rec := twoStageRecord(1)
	rec.Spares = []Spare{{MemberDeviceID: "spare"}}
	if got := rec.memberLinkPeers("head"); !reflect.DeepEqual(got, []string{"tail"}) {
		t.Errorf("two-stage head peers = %v", got)
	}
	if got := rec.memberLinkPeers("spare"); !reflect.DeepEqual(got, []string{"head"}) {
		t.Errorf("spare peers = %v", got)
	}
	if got := rec.memberLinkPeers("stranger"); got != nil {
		t.Errorf("stranger peers = %v", got)
	}
	rec.Stages = append(rec.Stages, Stage{StageIndex: 2, MemberDeviceID: "mid"})
	if got := rec.memberLinkPeers("tail"); !reflect.DeepEqual(got, []string{"head", "mid"}) {
		t.Errorf("three-stage middle peers = %v", got)
	}
}
