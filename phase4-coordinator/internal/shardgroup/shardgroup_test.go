package shardgroup

import (
	"context"
	"crypto/ed25519"
	"crypto/sha256"
	"database/sql"
	"encoding/base64"
	"encoding/hex"
	"encoding/json"
	"path/filepath"
	"strings"
	"testing"
	"time"

	_ "modernc.org/sqlite"

	"github.com/augstar/macprovider-coordinator/internal/config"
	"github.com/augstar/macprovider-coordinator/internal/pool"
)

const (
	testPoolModelID = "pool/ijUnc-ZQf-LJeRvkhi-0iQ/deep-model"
	testHash        = "3333333333333333333333333333333333333333333333333333333333333333"
	testModelID     = "example/deep-model-4bit"
	testOwner       = "github:42"
)

type fixture struct {
	t        *testing.T
	reg      *Registry
	store    *Store
	now      time.Time
	keys     map[string]ed25519.PrivateKey
	sessions map[string]pool.Provider
	owners   map[string]string
}

func newFixture(t *testing.T) *fixture {
	t.Helper()
	db, err := sql.Open("sqlite", filepath.Join(t.TempDir(), "shard.db"))
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { _ = db.Close() })
	store, err := NewStore(db)
	if err != nil {
		t.Fatal(err)
	}
	f := &fixture{t: t, store: store, now: time.Unix(1_800_000_000, 0), keys: map[string]ed25519.PrivateKey{}, sessions: map[string]pool.Provider{}, owners: map[string]string{}}
	f.reg = NewRegistry(ConfigFrom(config.DefaultShardGroupsConfig()), store, func() time.Time { return f.now })
	for _, id := range []string{"head", "tail", "mid", "spare"} {
		seed := sha256.Sum256([]byte(id))
		f.keys[id] = ed25519.NewKeyFromSeed(seed[:])
		f.owners[id] = testOwner
		p := pool.Provider{
			ProviderID: id, AssignedID: "s-" + id, ModelID: testModelID,
			ModelHashAlgorithm: "macprovider.snapshot-manifest.v1", ModelHash: testHash,
			InferencePath: pool.InferencePathWSTunneled, State: pool.StateReady, SlotsFree: 4, MaxConcurrency: 4,
			Tier: pool.TierTrusted, ReceiptPubkey: f.keys[id].Public().(ed25519.PublicKey), BinaryVersion: "1.8.300",
		}
		if id == "head" {
			p.ShardGroupHeadV1 = true
		} else {
			p.ShardMemberV1 = true
		}
		f.sessions[id] = p
	}
	return f
}

func (f *fixture) lookup(id string) (pool.Provider, bool) {
	p, ok := f.sessions[id]
	return p, ok
}

func twoStageRecord(epoch uint64) Record {
	return Record{
		Schema: RecordSchema, GroupProviderID: "head", GroupEpoch: epoch,
		ParallelismMode: "pipeline", InterconnectClass: "thunderbolt-ip", FrameProtection: "crc32c", TransportVersion: 1,
		Model:     RecordModel{ModelID: testModelID, PoolModelID: testPoolModelID, ArtifactHashAlgorithm: "macprovider.snapshot-manifest.v1", ArtifactHash: testHash},
		NumLayers: 32, MaxConcurrency: 4,
		Stages:      []Stage{{StageIndex: 0, MemberDeviceID: "head", LayerStart: 0, LayerEnd: 18}, {StageIndex: 1, MemberDeviceID: "tail", LayerStart: 18, LayerEnd: 32}},
		Spares:      []Spare{},
		Supervision: Supervision{HeartbeatIntervalMS: 100, HeartbeatMissLimit: 3, DecodeHopDeadlineMS: 500, PrefillChunkDeadlineMS: 3000, ReplayDeadlineMS: 10000},
	}
}

func sign(t *testing.T, key ed25519.PrivateKey, domain string, raw []byte, withoutSignature bool) string {
	t.Helper()
	msg, err := canonicalSigned(domain, raw, withoutSignature)
	if err != nil {
		t.Fatal(err)
	}
	return base64.StdEncoding.EncodeToString(ed25519.Sign(key, msg))
}

func (f *fixture) registerPayload(rec Record) []byte {
	raw, err := json.Marshal(rec)
	if err != nil {
		f.t.Fatal(err)
	}
	payload, _ := json.Marshal(RegisterMessage{Type: TypeRegister, Version: 1, Record: raw, RecordSignature: sign(f.t, f.keys["head"], recordDomain, raw, false)})
	return payload
}

func (f *fixture) headSession() HeadSession {
	p := f.sessions["head"]
	return HeadSession{ProviderID: "head", AssignedID: p.AssignedID, ModelID: p.ModelID, ModelHashAlgorithm: p.ModelHashAlgorithm, ModelHash: p.ModelHash,
		MaxConcurrency: p.MaxConcurrency, ReceiptKey: p.ReceiptPubkey, ShardGroupHeadV1: true, WSTunneled: true}
}

func (f *fixture) register(rec Record) (Result, []Outbound) {
	return f.reg.Register(context.Background(), f.headSession(), f.registerPayload(rec), f.owners)
}

func helloPayload(member string, epoch uint64, stage, start, end int, iface string, peers ...string) []byte {
	links := make([]MemberLink, 0, len(peers))
	for _, p := range peers {
		links = append(links, MemberLink{PeerMemberDeviceID: p, InterfaceType: iface})
	}
	role := "stage"
	if member == "spare" {
		role = "spare"
	}
	payload, _ := json.Marshal(MemberHello{Type: TypeMemberHello, Version: 1, GroupProviderID: "head", GroupEpoch: epoch, MemberDeviceID: member, Role: role,
		StageIndex: stage, LayerStart: start, LayerEnd: end, TransportVersion: 1, ArtifactHashAlgorithm: "macprovider.snapshot-manifest.v1", ArtifactHash: testHash,
		WeightsVerified: true, StageFits: true, Links: links})
	return payload
}

func (f *fixture) hello(member string, payload []byte) Result {
	p := f.sessions[member]
	return f.reg.MemberHello(context.Background(), MemberSession{ProviderID: member, AssignedID: p.AssignedID, ReceiptKey: p.ReceiptPubkey, ShardMemberV1: p.ShardMemberV1}, payload)
}

func heartbeatPayload(epoch uint64, healthy bool, rtt int, iface string) []byte {
	payload, _ := json.Marshal(Heartbeat{Type: TypeHeartbeat, Version: 1, GroupProviderID: "head", GroupEpoch: epoch,
		Members: []HeartbeatMember{{MemberDeviceID: "head", Healthy: true}, {MemberDeviceID: "tail", Healthy: healthy}},
		Links: []HeartbeatLink{
			{FromMemberDeviceID: "head", ToMemberDeviceID: "tail", InterfaceType: iface, RTTP99US: rtt},
			{FromMemberDeviceID: "tail", ToMemberDeviceID: "head", InterfaceType: iface, RTTP99US: rtt},
		}})
	return payload
}

func memberHealthPayload(member string, epoch uint64, healthy bool, iface string, rtt int, peers ...string) []byte {
	links := make([]MemberHealthLink, 0, len(peers))
	for _, p := range peers {
		links = append(links, MemberHealthLink{PeerMemberDeviceID: p, InterfaceType: iface, RTTP99US: rtt})
	}
	reason := ""
	if !healthy {
		reason = "link_down"
	}
	payload, _ := json.Marshal(MemberHealth{Type: TypeMemberHealth, Version: 1, GroupProviderID: "head", GroupEpoch: epoch, MemberDeviceID: member,
		Healthy: healthy, Reason: reason, Links: links})
	return payload
}

func (f *fixture) memberHealth(member string, payload []byte) bool {
	p := f.sessions[member]
	_, ok := f.reg.MemberHealth(MemberSession{ProviderID: member, AssignedID: p.AssignedID, ReceiptKey: p.ReceiptPubkey, ShardMemberV1: p.ShardMemberV1}, payload)
	return ok
}

func (f *fixture) evaluate() Evaluation {
	ev, ok := f.reg.Evaluate("head", f.lookup, f.owners, 10*time.Second)
	if !ok {
		f.t.Fatal("group unknown")
	}
	return ev
}

func TestStrictParsingRefusesMalformedMessages(t *testing.T) {
	good := helloPayload("tail", 1, 1, 18, 32, "thunderbolt", "head")
	if _, err := ParseMemberHello(good); err != nil {
		t.Fatalf("valid hello refused: %v", err)
	}
	for name, payload := range map[string]string{
		"unknown field":   strings.Replace(string(good), `"type"`, `"extra":1,"type"`, 1),
		"missing field":   strings.Replace(string(good), `"stage_fits":true,`, ``, 1),
		"duplicate field": strings.Replace(string(good), `"type"`, `"role":"stage","type"`, 1),
		"null list":       strings.Replace(string(good), `"links":[{"peer_member_device_id":"head","interface_type":"thunderbolt"}]`, `"links":null`, 1),
		"negative int":    strings.Replace(string(good), `"stage_index":1`, `"stage_index":-1`, 1),
		"huge int":        strings.Replace(string(good), `"group_epoch":1`, `"group_epoch":9007199254740993`, 1),
		"float":           strings.Replace(string(good), `"layer_start":18`, `"layer_start":18.5`, 1),
		"trailing data":   string(good) + `{}`,
		"wrong type":      strings.Replace(string(good), TypeMemberHello, TypeHeartbeat, 1),
	} {
		if payload == string(good) {
			t.Fatalf("%s: mutation did not apply", name)
		}
		if _, err := ParseMemberHello([]byte(payload)); err == nil {
			t.Errorf("%s accepted", name)
		}
	}
}

func TestValidateRecordReasons(t *testing.T) {
	cfg := ConfigFrom(config.DefaultShardGroupsConfig())
	head := HeadView{ProviderID: "head", ModelID: testModelID, ModelHashAlgorithm: "macprovider.snapshot-manifest.v1", ModelHash: testHash, MaxConcurrency: 4}
	if r := ValidateRecord(twoStageRecord(1), cfg, head); r != "" {
		t.Fatalf("valid record refused: %s", r)
	}
	// SPEC-051-R011: Ethernet is accepted with authenticated frames.
	ethernet := twoStageRecord(1)
	ethernet.InterconnectClass, ethernet.FrameProtection = "ethernet", "hmac-sha256"
	if r := ValidateRecord(ethernet, cfg, head); r != "" {
		t.Fatalf("ethernet hmac-sha256 record refused: %s", r)
	}
	cases := map[string]struct {
		mutate func(*Record)
		want   string
	}{
		"tensor":            {func(r *Record) { r.ParallelismMode = "tensor" }, ReasonModeReserved},
		"rdma":              {func(r *Record) { r.InterconnectClass = "rdma-tb5" }, ReasonInterconnectReserved},
		"wifi class":        {func(r *Record) { r.InterconnectClass = "wifi" }, ReasonInvalidRecord},
		"ethernet crc only": {func(r *Record) { r.InterconnectClass = "ethernet" }, ReasonFrameProtectionBelowMinimum},
		"transport 2":       {func(r *Record) { r.TransportVersion = 2 }, ReasonTransportVersionUnsupported},
		"model mismatch":    {func(r *Record) { r.Model.ArtifactHash = strings.Repeat("4", 64) }, ReasonModelMismatch},
		"bad pool model":    {func(r *Record) { r.Model.PoolModelID = "deep-model" }, ReasonInvalidRecord},
		"concurrency":       {func(r *Record) { r.MaxConcurrency = 5 }, ReasonInvalidRecord},
		"supervision":       {func(r *Record) { r.Supervision.HeartbeatIntervalMS = 5 }, ReasonInvalidRecord},
		"layer gap":         {func(r *Record) { r.Stages[1].LayerStart = 19 }, ReasonPlacementInvalid},
		"short cover":       {func(r *Record) { r.NumLayers = 40 }, ReasonPlacementInvalid},
		"stage 0 not head":  {func(r *Record) { r.Stages[0].MemberDeviceID = "other" }, ReasonPlacementInvalid},
		"one stage":         {func(r *Record) { r.Stages = r.Stages[:1]; r.NumLayers = 18 }, ReasonPlacementInvalid},
		"head spare":        {func(r *Record) { r.Spares = []Spare{{MemberDeviceID: "spare", StageIndex: 0}} }, ReasonPlacementInvalid},
		"member twice":      {func(r *Record) { r.Spares = []Spare{{MemberDeviceID: "tail", StageIndex: 1}} }, ReasonPlacementInvalid},
		"other group id":    {func(r *Record) { r.GroupProviderID = "someone" }, ReasonNotGroupHeadSession},
		"zero epoch":        {func(r *Record) { r.GroupEpoch = 0 }, ReasonInvalidRecord},
		"too many members": {func(r *Record) {
			r.Spares = []Spare{{"s1", 1}, {"s2", 1}, {"s3", 1}}
		}, ReasonTooManyMembers},
	}
	for name, tc := range cases {
		rec := twoStageRecord(1)
		tc.mutate(&rec)
		if got := ValidateRecord(rec, cfg, head); got != tc.want {
			t.Errorf("%s: reason %q, want %q", name, got, tc.want)
		}
	}
}

func TestRegisterSignatureEpochAndOwnership(t *testing.T) {
	f := newFixture(t)
	res, _ := f.register(twoStageRecord(1))
	if !res.Accepted {
		t.Fatalf("register refused: %s", res.Reason)
	}
	// An identical re-registration (reconnect) is acknowledged.
	if res, _ := f.register(twoStageRecord(1)); !res.Accepted {
		t.Fatalf("identical re-registration refused: %s", res.Reason)
	}
	changed := twoStageRecord(1)
	changed.Stages[0].LayerEnd, changed.Stages[1].LayerStart = 16, 16
	if res, _ := f.register(changed); res.Accepted || res.Reason != ReasonEpochNotIncreasing {
		t.Fatalf("changed epoch-1 record: %+v", res)
	}
	stored, ok, err := f.store.LatestRecord(context.Background(), "head")
	if err != nil || !ok || stored.GroupEpoch != 1 {
		t.Fatalf("latest record = %+v %v %v", stored, ok, err)
	}
	// A record signed by another key is refused.
	raw, _ := json.Marshal(twoStageRecord(2))
	payload, _ := json.Marshal(RegisterMessage{Type: TypeRegister, Version: 1, Record: raw, RecordSignature: sign(t, f.keys["tail"], recordDomain, raw, false)})
	if res, _ := f.reg.Register(context.Background(), f.headSession(), payload, f.owners); res.Reason != ReasonSignatureInvalid {
		t.Fatalf("foreign signature: %+v", res)
	}
	// Owner mismatch and unclaimed identities are refused.
	f.owners["tail"] = "github:7"
	if res, _ := f.register(twoStageRecord(2)); res.Reason != ReasonOwnerMismatch {
		t.Fatalf("owner mismatch: %+v", res)
	}
	f.owners["tail"] = ""
	f.owners["head"] = ""
	if res, _ := f.register(twoStageRecord(2)); res.Reason != ReasonOwnerMismatch {
		t.Fatalf("unclaimed: %+v", res)
	}
	// A member session cannot register a group.
	head := f.headSession()
	head.ShardMemberV1 = true
	if res, _ := f.reg.Register(context.Background(), head, f.registerPayload(twoStageRecord(2)), f.owners); res.Reason != ReasonNotGroupHeadSession {
		t.Fatalf("member session register: %+v", res)
	}
}

func TestMemberHelloBindingAndPendingClaims(t *testing.T) {
	f := newFixture(t)
	// A hello before the record is kept and accepted at registration.
	if res := f.hello("tail", helloPayload("tail", 1, 1, 18, 32, "thunderbolt", "head")); res.Accepted || res.Reason != ReasonGroupNotRegistered {
		t.Fatalf("early hello: %+v", res)
	}
	res, out := f.register(twoStageRecord(1))
	if !res.Accepted || len(out) != 1 || out[0].ProviderID != "tail" || !out[0].Message.(Result).Accepted {
		t.Fatalf("register with kept hello: %+v %+v", res, out)
	}
	keys, ok := f.reg.Epochs("head")(1)
	if !ok || keys.StageKeys[1] != base64.StdEncoding.EncodeToString(f.sessions["tail"].ReceiptPubkey) {
		t.Fatalf("tail key not bound: %+v", keys)
	}
	for name, tc := range map[string]struct {
		payload []byte
		want    string
	}{
		"wifi link":     {helloPayload("tail", 1, 1, 18, 32, "wifi", "head"), ReasonLinkInterfaceInvalid},
		"wrong layers":  {helloPayload("tail", 1, 1, 17, 32, "thunderbolt", "head"), ReasonRecordMismatch},
		"missing link":  {helloPayload("tail", 1, 1, 18, 32, "thunderbolt"), ReasonRecordMismatch},
		"future epoch":  {helloPayload("tail", 2, 1, 18, 32, "thunderbolt", "head"), ReasonGroupNotRegistered},
		"not in record": {helloPayload("mid", 1, 1, 18, 32, "thunderbolt", "head"), ReasonRecordMismatch},
	} {
		member := "tail"
		if strings.Contains(string(tc.payload), `"member_device_id":"mid"`) {
			member = "mid"
		}
		if res := f.hello(member, tc.payload); res.Reason != tc.want {
			t.Errorf("%s: %+v, want %s", name, res, tc.want)
		}
	}
	// The head identity is never a member session.
	if res := f.reg.MemberHello(context.Background(), MemberSession{ProviderID: "tail", AssignedID: "s-tail", ReceiptKey: f.sessions["tail"].ReceiptPubkey}, helloPayload("tail", 1, 1, 18, 32, "thunderbolt", "head")); res.Reason != ReasonNotMemberSession {
		t.Fatalf("non-member session: %+v", res)
	}
}

func TestMemberCannotJoinTwoGroups(t *testing.T) {
	f := newFixture(t)
	if res, _ := f.register(twoStageRecord(1)); !res.Accepted {
		t.Fatal(res.Reason)
	}
	// A second head naming "tail" is refused while tail is in head's group.
	seed := sha256.Sum256([]byte("head2"))
	key := ed25519.NewKeyFromSeed(seed[:])
	rec := twoStageRecord(1)
	rec.GroupProviderID, rec.Stages[0].MemberDeviceID = "head2", "head2"
	raw, _ := json.Marshal(rec)
	payload, _ := json.Marshal(RegisterMessage{Type: TypeRegister, Version: 1, Record: raw, RecordSignature: sign(t, key, recordDomain, raw, false)})
	head := f.headSession()
	head.ProviderID, head.ReceiptKey = "head2", key.Public().(ed25519.PublicKey)
	f.owners["head2"] = testOwner
	if res, _ := f.reg.Register(context.Background(), head, payload, f.owners); res.Reason != ReasonMemberConflict {
		t.Fatalf("second group: %+v", res)
	}
}

func TestEvaluateAvailability(t *testing.T) {
	f := newFixture(t)
	if res, _ := f.register(twoStageRecord(1)); !res.Accepted {
		t.Fatal(res.Reason)
	}
	if ev := f.evaluate(); ev.Available || ev.Reason != ReasonMemberNotJoined || !ev.Changed {
		t.Fatalf("before join: %+v", ev)
	}
	if res := f.hello("tail", helloPayload("tail", 1, 1, 18, 32, "thunderbolt", "head")); !res.Accepted {
		t.Fatal(res.Reason)
	}
	if ev := f.evaluate(); ev.Reason != ReasonGroupHeartbeatStale {
		t.Fatalf("before heartbeat: %+v", ev)
	}
	if !f.reg.Heartbeat("head", "s-head", heartbeatPayload(1, true, 400, "thunderbolt")) {
		t.Fatal("heartbeat dropped")
	}
	// SPEC-051-R015 item 8: the member's own report is required too.
	if ev := f.evaluate(); ev.Reason != ReasonMemberHealthStale {
		t.Fatalf("before the member's own report: %+v", ev)
	}
	if !f.memberHealth("tail", memberHealthPayload("tail", 1, true, "thunderbolt", 300, "head")) {
		t.Fatal("member health dropped")
	}
	ev := f.evaluate()
	if !ev.Available || len(ev.Members) != 1 || ev.Members[0].ProviderID != "tail" || !ev.Changed {
		t.Fatalf("available: %+v", ev)
	}
	if again := f.evaluate(); again.Changed {
		t.Fatal("unchanged evaluation reported a change")
	}

	checks := []struct {
		name   string
		mutate func()
		undo   func()
		want   string
	}{
		{"member disconnected", func() { delete(f.sessions, "tail") }, nil, ReasonMemberSessionMissing},
		{"member reconnected under a new session", func() { p := f.sessions["tail"]; p.AssignedID = "s-tail-2"; f.sessions["tail"] = p }, nil, ReasonMemberSessionMissing},
		{"member quarantined", func() { p := f.sessions["tail"]; p.BenchmarkQuarantined = true; f.sessions["tail"] = p }, nil, ReasonMemberNotAdmissible},
		{"member degraded", func() { p := f.sessions["tail"]; p.State = pool.StateDegraded; f.sessions["tail"] = p }, nil, ReasonMemberNotAdmissible},
		{"member lower tier", func() { p := f.sessions["tail"]; p.Tier = pool.TierProvisional; f.sessions["tail"] = p }, nil, ReasonTrustLabelAboveMember},
		{"head attested, member not", func() {
			h := f.sessions["head"]
			h.AttestationTier = pool.AttestationTierHardware
			f.sessions["head"] = h
		}, nil, ReasonTrustLabelAboveMember},
		{"owner changed", func() { f.owners["tail"] = "github:9" }, nil, ReasonOwnerMismatch},
		{"head lost its session", func() { p := f.sessions["head"]; p.AssignedID = "s-head-2"; f.sessions["head"] = p }, nil, ReasonHeadSessionInvalid},
		{"head swapped model", func() { p := f.sessions["head"]; p.ModelHash = strings.Repeat("5", 64); f.sessions["head"] = p }, nil, ReasonHeadSessionInvalid},
		{"heartbeat stale", func() { f.now = f.now.Add(31 * time.Second) }, nil, ReasonGroupHeartbeatStale},
		{"member unhealthy", func() { f.reg.Heartbeat("head", "s-head", heartbeatPayload(1, false, 400, "thunderbolt")) }, nil, ReasonMemberUnhealthy},
		{"wifi link", func() { f.reg.Heartbeat("head", "s-head", heartbeatPayload(1, true, 400, "wifi")) }, nil, ReasonLinkInterfaceInvalid},
		{"slow link", func() { f.reg.Heartbeat("head", "s-head", heartbeatPayload(1, true, 2500, "thunderbolt")) }, nil, ReasonLinkRTTExceeded},
		{"member report stale", func() {
			f.now = f.now.Add(31 * time.Second)
			f.reg.Heartbeat("head", "s-head", heartbeatPayload(1, true, 400, "thunderbolt"))
		}, nil, ReasonMemberHealthStale},
		{"member reports itself unhealthy", func() { f.memberHealth("tail", memberHealthPayload("tail", 1, false, "thunderbolt", 300, "head")) }, nil, ReasonMemberSelfUnhealthy},
		{"member sees wifi", func() { f.memberHealth("tail", memberHealthPayload("tail", 1, true, "wifi", 300, "head")) }, nil, ReasonLinkInterfaceInvalid},
		{"member sees a slow link", func() { f.memberHealth("tail", memberHealthPayload("tail", 1, true, "thunderbolt", 2600, "head")) }, nil, ReasonLinkRTTExceeded},
	}
	for _, c := range checks {
		saved := map[string]pool.Provider{}
		for k, v := range f.sessions {
			saved[k] = v
		}
		savedOwners := map[string]string{}
		for k, v := range f.owners {
			savedOwners[k] = v
		}
		savedNow := f.now
		c.mutate()
		if ev := f.evaluate(); ev.Available || ev.Reason != c.want || ev.Members != nil {
			t.Errorf("%s: %+v, want %s", c.name, ev, c.want)
		}
		f.sessions, f.owners, f.now = saved, savedOwners, savedNow
		f.reg.Heartbeat("head", "s-head", heartbeatPayload(1, true, 400, "thunderbolt"))
		f.memberHealth("tail", memberHealthPayload("tail", 1, true, "thunderbolt", 300, "head"))
		if ev := f.evaluate(); !ev.Available {
			t.Fatalf("%s: did not recover: %+v", c.name, ev)
		}
	}
	// A heartbeat from a stale session, for another epoch, or missing a link
	// is dropped.
	if f.reg.Heartbeat("head", "s-other", heartbeatPayload(1, true, 400, "thunderbolt")) ||
		f.reg.Heartbeat("head", "s-head", heartbeatPayload(2, true, 400, "thunderbolt")) {
		t.Fatal("foreign heartbeat accepted")
	}
	// A member report from another session, another epoch, another member,
	// with a missing link, or self-contradictory, is dropped.
	for name, tc := range map[string]struct {
		session string
		payload []byte
	}{
		"other session": {"s-other", memberHealthPayload("tail", 1, true, "thunderbolt", 300, "head")},
		"other epoch":   {"s-tail", memberHealthPayload("tail", 2, true, "thunderbolt", 300, "head")},
		"missing link":  {"s-tail", memberHealthPayload("tail", 1, true, "thunderbolt", 300)},
		"extra link":    {"s-tail", memberHealthPayload("tail", 1, true, "thunderbolt", 300, "head", "mid")},
		"healthy with reason": {"s-tail", []byte(strings.Replace(string(memberHealthPayload("tail", 1, true, "thunderbolt", 300, "head")),
			`"reason":""`, `"reason":"link_down"`, 1))},
		"unknown reason": {"s-tail", []byte(strings.Replace(string(memberHealthPayload("tail", 1, false, "thunderbolt", 300, "head")),
			`"link_down"`, `"bored"`, 1))},
	} {
		p := f.sessions["tail"]
		if _, ok := f.reg.MemberHealth(MemberSession{ProviderID: "tail", AssignedID: tc.session, ReceiptKey: p.ReceiptPubkey, ShardMemberV1: true}, tc.payload); ok {
			t.Errorf("%s: member health kept", name)
		}
	}
	short, _ := json.Marshal(Heartbeat{Type: TypeHeartbeat, Version: 1, GroupProviderID: "head", GroupEpoch: 1,
		Members: []HeartbeatMember{{"head", true}, {"tail", true}}, Links: []HeartbeatLink{{"head", "tail", "thunderbolt", 400}}})
	if f.reg.Heartbeat("head", "s-head", short) {
		t.Fatal("heartbeat missing the return link accepted")
	}
}

// --- attestation ---

func digest(s string) string {
	sum := sha256.Sum256([]byte(s))
	return hex.EncodeToString(sum[:])
}

func receiptEnvelope(t *testing.T, requestID string, attempt int, provider string) (string, string) {
	t.Helper()
	tuple := []byte(`{"attempt_n":` + jsonInt(attempt) + `,"provider_id":"` + provider + `","request_id":"` + requestID + `"}`)
	sum := sha256.Sum256(tuple)
	return base64.StdEncoding.EncodeToString(tuple) + "." + base64.StdEncoding.EncodeToString(make([]byte, 64)), hex.EncodeToString(sum[:])
}

func jsonInt(n int) string { b, _ := json.Marshal(n); return string(b) }

func (f *fixture) subReceipt(member string, epoch uint64, stage, start, end int, requestID, in, out string) SignedSubReceipt {
	sr := SubReceipt{MemberDeviceID: member, GroupEpoch: epoch, StageIndex: stage, LayerStart: start, LayerEnd: end, RequestID: requestID,
		PromptTokens: 12, DecodeSteps: 8, InDigest: in, OutDigest: out}
	raw, _ := json.Marshal(sr)
	return SignedSubReceipt{SubReceipt: sr, PublicKey: base64.StdEncoding.EncodeToString(f.keys[member].Public().(ed25519.PublicKey)), Signature: sign(f.t, f.keys[member], subReceiptDomain, raw, false)}
}

func (f *fixture) attestation(segments []AttestationSegment, requestID string, attempt int, tupleSHA string) json.RawMessage {
	return f.takeoverAttestation(segments, requestID, attempt, tupleSHA, nil)
}

func (f *fixture) takeoverAttestation(segments []AttestationSegment, requestID string, attempt int, tupleSHA string, takeover *Takeover) json.RawMessage {
	att := Attestation{Schema: AttestationSchema, GroupProviderID: "head", RequestID: requestID, AttemptN: attempt, ReceiptTupleSHA256: tupleSHA, Segments: segments, Takeover: takeover}
	raw, _ := json.Marshal(att)
	att.Signature = sign(f.t, f.keys["head"], attestationDomain, raw, true)
	out, _ := json.Marshal(att)
	return out
}

func (f *fixture) joinedGroup() {
	if res, _ := f.register(twoStageRecord(1)); !res.Accepted {
		f.t.Fatal(res.Reason)
	}
	if res := f.hello("tail", helloPayload("tail", 1, 1, 18, 32, "thunderbolt", "head")); !res.Accepted {
		f.t.Fatal(res.Reason)
	}
}

func TestVerifyAttestation(t *testing.T) {
	f := newFixture(t)
	f.joinedGroup()
	envelope, tupleSHA := receiptEnvelope(t, "req-1", 0, "head")
	a, b := digest("activations"), digest("tokens")
	good := []AttestationSegment{{GroupEpoch: 1, StepStart: 0, StepEnd: 8, SubReceipts: []SignedSubReceipt{
		f.subReceipt("head", 1, 0, 0, 18, "req-1", b, a),
		f.subReceipt("tail", 1, 1, 18, 32, "req-1", a, b),
	}}}
	headKey := f.sessions["head"].ReceiptPubkey
	verify := func(raw json.RawMessage, env string) Verdict {
		return VerifyAttestation(raw, env, "head", headKey, f.reg.Epochs("head"))
	}
	if v := verify(f.attestation(good, "req-1", 0, tupleSHA), envelope); !v.Verified() || v.ReceiptTupleSHA256 != tupleSHA {
		t.Fatalf("valid attestation: %+v", v)
	}
	if v := verify(nil, envelope); v.FaultKind != FaultMissing {
		t.Fatalf("missing: %+v", v)
	}
	if v := verify(f.attestation(good, "req-1", 1, tupleSHA), envelope); v.FaultKind != FaultReceiptMismatch {
		t.Fatalf("attempt mismatch: %+v", v)
	}
	if v := verify(f.attestation(good, "req-1", 0, digest("other")), envelope); v.FaultKind != FaultReceiptMismatch {
		t.Fatalf("tuple digest mismatch: %+v", v)
	}
	tampered := f.attestation(good, "req-1", 0, tupleSHA)
	tampered = json.RawMessage(strings.Replace(string(tampered), `"step_end":8`, `"step_end":9`, 1))
	if v := verify(tampered, envelope); v.FaultKind != FaultHeadSignature {
		t.Fatalf("tampered: %+v", v)
	}
	broken := []AttestationSegment{{GroupEpoch: 1, StepStart: 0, StepEnd: 8, SubReceipts: []SignedSubReceipt{
		f.subReceipt("head", 1, 0, 0, 18, "req-1", b, a),
		f.subReceipt("tail", 1, 1, 18, 32, "req-1", digest("forged"), b),
	}}}
	if v := verify(f.attestation(broken, "req-1", 0, tupleSHA), envelope); v.FaultKind != FaultDigestChainBreak || v.FaultMemberDeviceID != "tail" {
		t.Fatalf("chain break: %+v", v)
	}
	wrongKey := []AttestationSegment{{GroupEpoch: 1, StepStart: 0, StepEnd: 8, SubReceipts: []SignedSubReceipt{
		f.subReceipt("head", 1, 0, 0, 18, "req-1", b, a),
		f.subReceipt("mid", 1, 1, 18, 32, "req-1", a, b),
	}}}
	wrongKey[0].SubReceipts[1].SubReceipt.MemberDeviceID = "tail"
	if v := verify(f.attestation(wrongKey, "req-1", 0, tupleSHA), envelope); v.FaultKind != FaultKeyMismatch || v.FaultMemberDeviceID != "tail" {
		t.Fatalf("wrong key: %+v", v)
	}
	unknownEpoch := []AttestationSegment{{GroupEpoch: 2, StepStart: 0, StepEnd: 8, SubReceipts: good[0].SubReceipts}}
	if v := verify(f.attestation(unknownEpoch, "req-1", 0, tupleSHA), envelope); v.FaultKind != FaultUnknownEpoch {
		t.Fatalf("unknown epoch: %+v", v)
	}
	gap := []AttestationSegment{{GroupEpoch: 1, StepStart: 1, StepEnd: 8, SubReceipts: good[0].SubReceipts}}
	if v := verify(f.attestation(gap, "req-1", 0, tupleSHA), envelope); v.FaultKind != FaultSegments {
		t.Fatalf("segment gap: %+v", v)
	}
	otherProvider, otherSHA := receiptEnvelope(t, "req-1", 0, "tail")
	if v := verify(f.attestation(good, "req-1", 0, otherSHA), otherProvider); v.FaultKind != FaultReceiptMismatch {
		t.Fatalf("receipt from another provider: %+v", v)
	}
}

func TestVerifyAttestationAcrossSpareReplay(t *testing.T) {
	f := newFixture(t)
	rec := twoStageRecord(1)
	rec.Spares = []Spare{{MemberDeviceID: "spare", StageIndex: 1}}
	if res, _ := f.register(rec); !res.Accepted {
		t.Fatal(res.Reason)
	}
	if res := f.hello("tail", helloPayload("tail", 1, 1, 18, 32, "thunderbolt", "head")); !res.Accepted {
		t.Fatal(res.Reason)
	}
	// The spare replaces the tail in epoch 2 (SPEC-051-R022).
	next := twoStageRecord(2)
	next.Stages[1].MemberDeviceID = "spare"
	if res, _ := f.register(next); !res.Accepted {
		t.Fatal(res.Reason)
	}
	if res := f.hello("spare", helloPayload("spare", 2, 1, 18, 32, "thunderbolt", "head")); res.Reason != ReasonRecordMismatch {
		t.Fatalf("spare hello with role spare for an active stage: %+v", res)
	}
	payload := strings.Replace(string(helloPayload("spare", 2, 1, 18, 32, "thunderbolt", "head")), `"role":"spare"`, `"role":"stage"`, 1)
	if res := f.hello("spare", []byte(payload)); !res.Accepted {
		t.Fatalf("spare as stage: %+v", res)
	}
	envelope, tupleSHA := receiptEnvelope(t, "req-2", 0, "head")
	a1, b1, a2, b2 := digest("a1"), digest("b1"), digest("a2"), digest("b2")
	segments := []AttestationSegment{
		{GroupEpoch: 1, StepStart: 0, StepEnd: 5, SubReceipts: []SignedSubReceipt{
			f.subReceipt("head", 1, 0, 0, 18, "req-2", b1, a1), f.subReceipt("tail", 1, 1, 18, 32, "req-2", a1, b1)}},
		{GroupEpoch: 2, StepStart: 5, StepEnd: 9, SubReceipts: []SignedSubReceipt{
			f.subReceipt("head", 2, 0, 0, 18, "req-2", b2, a2), f.subReceipt("spare", 2, 1, 18, 32, "req-2", a2, b2)}},
	}
	v := VerifyAttestation(f.attestation(segments, "req-2", 0, tupleSHA), envelope, "head", f.sessions["head"].ReceiptPubkey, f.reg.Epochs("head"))
	if !v.Verified() || len(v.GroupEpochs) != 2 {
		t.Fatalf("replay attestation: %+v", v)
	}
	segments[1].StepStart = 6
	if v := VerifyAttestation(f.attestation(segments, "req-2", 0, tupleSHA), envelope, "head", f.sessions["head"].ReceiptPubkey, f.reg.Epochs("head")); v.FaultKind != FaultSegments {
		t.Fatalf("non-contiguous segments: %+v", v)
	}
}

func TestStoreAttestationFirstVerdictKept(t *testing.T) {
	f := newFixture(t)
	ctx := context.Background()
	rec := AttestationRecord{RequestID: "req", AttemptN: 0, GroupProviderID: "head", ReceiptTupleSHA256: digest("t"), Verified: false, FaultKind: FaultDigestChainBreak, FaultMemberDeviceID: "tail", AttestationJSON: "{}"}
	if err := f.store.RecordAttestation(ctx, rec, 1); err != nil {
		t.Fatal(err)
	}
	rec.Verified, rec.FaultKind, rec.FaultMemberDeviceID = true, "", ""
	if err := f.store.RecordAttestation(ctx, rec, 2); err != nil {
		t.Fatal(err)
	}
	got, ok, err := f.store.Attestation(ctx, "req", 0, "head")
	if err != nil || !ok || got.Verified || got.FaultMemberDeviceID != "tail" {
		t.Fatalf("stored = %+v %v %v", got, ok, err)
	}
}

// The provider's spare flow end to end: the spare joins epoch 1 as a spare and
// sends its takeover hello for epoch 2 at once, which is kept; the head's
// heartbeat carries the spare's standby link; an unreachable spare never stops
// the group; at the takeover the head registers epoch 2 and the spare's key is
// bound, so a request the spare finished verifies as one epoch-2 segment.
func TestSpareStandbyTakeoverFlow(t *testing.T) {
	f := newFixture(t)
	rec := twoStageRecord(1)
	rec.Spares = []Spare{{MemberDeviceID: "spare", StageIndex: 1}}
	if res, _ := f.register(rec); !res.Accepted {
		t.Fatal(res.Reason)
	}
	if res := f.hello("tail", helloPayload("tail", 1, 1, 18, 32, "thunderbolt", "head")); !res.Accepted {
		t.Fatal(res.Reason)
	}
	if res := f.hello("spare", helloPayload("spare", 1, 1, 18, 32, "thunderbolt", "head")); !res.Accepted {
		t.Fatalf("spare hello: %+v", res)
	}
	takeover := []byte(strings.Replace(string(helloPayload("spare", 2, 1, 18, 32, "thunderbolt", "head")), `"role":"spare"`, `"role":"stage"`, 1))
	if res := f.hello("spare", takeover); res.Reason != ReasonGroupNotRegistered {
		t.Fatalf("takeover hello before the takeover: %+v", res)
	}
	beat := func(spareHealthy bool, spareInterface string) []byte {
		payload, _ := json.Marshal(Heartbeat{Type: TypeHeartbeat, Version: 1, GroupProviderID: "head", GroupEpoch: 1,
			Members: []HeartbeatMember{{MemberDeviceID: "head", Healthy: true}, {MemberDeviceID: "tail", Healthy: true}, {MemberDeviceID: "spare", Healthy: spareHealthy}},
			Links: []HeartbeatLink{
				{FromMemberDeviceID: "head", ToMemberDeviceID: "tail", InterfaceType: "thunderbolt", RTTP99US: 400},
				{FromMemberDeviceID: "tail", ToMemberDeviceID: "head", InterfaceType: "thunderbolt", RTTP99US: 400},
				{FromMemberDeviceID: "head", ToMemberDeviceID: "spare", InterfaceType: spareInterface, RTTP99US: 0},
			}})
		return payload
	}
	for name, tc := range map[string]struct {
		healthy bool
		iface   string
		want    string
	}{
		"spare reachable":   {true, "thunderbolt", ""},
		"spare unreachable": {false, "other", ""},
		"spare on wifi":     {true, "wifi", ReasonLinkInterfaceInvalid},
	} {
		if !f.reg.Heartbeat("head", "s-head", beat(tc.healthy, tc.iface)) {
			t.Fatalf("%s: heartbeat dropped", name)
		}
		if !f.memberHealth("tail", memberHealthPayload("tail", 1, true, "thunderbolt", 300, "head")) {
			t.Fatalf("%s: member health dropped", name)
		}
		if ev := f.evaluate(); ev.Reason != tc.want {
			t.Errorf("%s: reason %q, want %q", name, ev.Reason, tc.want)
		}
	}
	// A heartbeat that leaves the spare out does not describe the record.
	if f.reg.Heartbeat("head", "s-head", heartbeatPayload(1, true, 400, "thunderbolt")) {
		t.Fatal("heartbeat without the spare accepted")
	}

	next := twoStageRecord(2)
	next.Stages[1].MemberDeviceID = "spare"
	res, out := f.register(next)
	if !res.Accepted || len(out) != 1 || out[0].ProviderID != "spare" || !out[0].Message.(Result).Accepted {
		t.Fatalf("takeover registration: %+v %+v", res, out)
	}
	keys, ok := f.reg.Epochs("head")(2)
	if !ok || keys.StageKeys[1] != base64.StdEncoding.EncodeToString(f.sessions["spare"].ReceiptPubkey) {
		t.Fatalf("spare key not bound to epoch 2: %+v", keys)
	}
	envelope, tupleSHA := receiptEnvelope(t, "req-3", 0, "head")
	a, b := digest("a"), digest("b")
	segments := []AttestationSegment{{GroupEpoch: 2, StepStart: 0, StepEnd: 9, SubReceipts: []SignedSubReceipt{
		f.subReceipt("head", 2, 0, 0, 18, "req-3", b, a), f.subReceipt("spare", 2, 1, 18, 32, "req-3", a, b)}}}
	verify := func(raw json.RawMessage) Verdict {
		return VerifyAttestation(raw, envelope, "head", f.sessions["head"].ReceiptPubkey, f.reg.Epochs("head"))
	}
	if v := verify(f.attestation(segments, "req-3", 0, tupleSHA)); !v.Verified() {
		t.Fatalf("replayed request attestation: %+v", v)
	}
	// SPEC-051-R019 takeover attestation: one new-epoch segment from step 0,
	// recorded with the epoch it took over from and why.
	v := verify(f.takeoverAttestation(segments, "req-3", 0, tupleSHA, &Takeover{FromGroupEpoch: 1, Reason: "peer_closed"}))
	if !v.Verified() || v.TakeoverFromEpoch != 1 || v.TakeoverReason != "peer_closed" {
		t.Fatalf("takeover attestation: %+v", v)
	}
	old := []SignedSubReceipt{f.subReceipt("head", 1, 0, 0, 18, "req-3", b, a), f.subReceipt("tail", 1, 1, 18, 32, "req-3", a, b)}
	if res := f.hello("tail", helloPayload("tail", 1, 1, 18, 32, "thunderbolt", "head")); res.Reason != ReasonEpochSuperseded {
		t.Fatalf("tail hello for the superseded epoch: %+v", res)
	}
	for name, tc := range map[string]struct {
		segments []AttestationSegment
		takeover Takeover
	}{
		"two segments":   {[]AttestationSegment{{GroupEpoch: 1, StepStart: 0, StepEnd: 4, SubReceipts: old}, {GroupEpoch: 2, StepStart: 4, StepEnd: 9, SubReceipts: segments[0].SubReceipts}}, Takeover{1, "peer_closed"}},
		"unknown reason": {segments, Takeover{1, "bored"}},
		"same epoch":     {segments, Takeover{2, "peer_dead"}},
		"unknown from":   {segments, Takeover{0, "peer_dead"}},
	} {
		if v := verify(f.takeoverAttestation(tc.segments, "req-3", 0, tupleSHA, &tc.takeover)); v.FaultKind != FaultTakeover {
			t.Errorf("%s: %+v", name, v)
		}
	}
	// A null takeover is malformed, not absent.
	raw := f.attestation(segments, "req-3", 0, tupleSHA)
	nulled := strings.Replace(string(raw), `"signature"`, `"takeover":null,"signature"`, 1)
	if v := verify(json.RawMessage(nulled)); v.FaultKind != FaultMalformed {
		t.Fatalf("null takeover: %+v", v)
	}
	// The store keeps the takeover with the verdict.
	ctx := context.Background()
	stored := AttestationRecord{RequestID: "req-3", AttemptN: 0, GroupProviderID: "head", ReceiptTupleSHA256: v.ReceiptTupleSHA256, Verified: true,
		AttestationJSON: "{}", TakeoverFromEpoch: v.TakeoverFromEpoch, TakeoverReason: v.TakeoverReason}
	if err := f.store.RecordAttestation(ctx, stored, 1); err != nil {
		t.Fatal(err)
	}
	got, ok, err := f.store.Attestation(ctx, "req-3", 0, "head")
	if err != nil || !ok || got.TakeoverFromEpoch != 1 || got.TakeoverReason != "peer_closed" {
		t.Fatalf("stored takeover = %+v %v %v", got, ok, err)
	}
}

// SPEC-051-R023: after a takeover at epoch 2 the head rebuilds at 3, which
// registers; rebuilding at an epoch the coordinator already accepted is refused.
func TestRebuildAfterTakeoverRegistersAboveTheTakeoverEpoch(t *testing.T) {
	f := newFixture(t)
	if res, _ := f.register(twoStageRecord(1)); !res.Accepted {
		t.Fatal(res.Reason)
	}
	takeover := twoStageRecord(2)
	takeover.Stages[1].MemberDeviceID = "spare"
	if res, _ := f.register(takeover); !res.Accepted {
		t.Fatalf("takeover: %+v", res)
	}
	for _, stale := range []uint64{1, 2} {
		rec := twoStageRecord(stale)
		if stale == 2 {
			rec.Stages[0].LayerEnd, rec.Stages[1].LayerStart = 16, 16
		}
		if res, _ := f.register(rec); res.Reason != ReasonEpochNotIncreasing {
			t.Fatalf("rebuild at seen epoch %d: %+v", stale, res)
		}
	}
	if res, _ := f.register(twoStageRecord(3)); !res.Accepted {
		t.Fatalf("rebuild at epoch 3: %+v", res)
	}
	stored, ok, err := f.store.LatestRecord(context.Background(), "head")
	if err != nil || !ok || stored.GroupEpoch != 3 {
		t.Fatalf("latest record = %+v %v %v", stored, ok, err)
	}
}
