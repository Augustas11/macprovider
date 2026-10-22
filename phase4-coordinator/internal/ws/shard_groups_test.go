package ws

import (
	"bytes"
	"context"
	"crypto/ed25519"
	"crypto/sha256"
	"database/sql"
	"encoding/base64"
	"encoding/hex"
	"encoding/json"
	"net"
	"path/filepath"
	"strconv"
	"testing"
	"time"

	"github.com/gobwas/ws/wsutil"
	"github.com/rs/zerolog"

	"github.com/augstar/macprovider-coordinator/internal/config"
	"github.com/augstar/macprovider-coordinator/internal/jcs"
	"github.com/augstar/macprovider-coordinator/internal/pool"
	"github.com/augstar/macprovider-coordinator/internal/shardgroup"
)

type fakeShardOwners map[string]string

func (f fakeShardOwners) ProviderOperatorKey(_ context.Context, id string) (string, error) {
	if owner, ok := f[id]; ok {
		return owner, nil
	}
	return "provider:" + id, nil
}

const (
	shardWSModel     = "example/deep-model-4bit"
	shardWSHash      = "3333333333333333333333333333333333333333333333333333333333333333"
	shardWSPoolModel = "pool/ijUnc-ZQf-LJeRvkhi-0iQ/deep-model"
)

type shardWSHarness struct {
	t       *testing.T
	server  *Server
	reg     *pool.Registry
	store   *shardgroup.Store
	keys    map[string]ed25519.PrivateKey
	inbox   map[string]chan map[string]any
	clock   time.Time
	cleanup []net.Conn
}

func signShardDomain(t *testing.T, key ed25519.PrivateKey, domain string, raw []byte, dropSignature bool) string {
	t.Helper()
	dec := json.NewDecoder(bytes.NewReader(raw))
	dec.UseNumber()
	var v any
	if err := dec.Decode(&v); err != nil {
		t.Fatal(err)
	}
	if dropSignature {
		delete(v.(map[string]any), "signature")
	}
	canonical, err := jcs.CanonicalJSONRawStrings(v)
	if err != nil {
		t.Fatal(err)
	}
	return base64.StdEncoding.EncodeToString(ed25519.Sign(key, append([]byte(domain), canonical...)))
}

func newShardWSHarness(t *testing.T) *shardWSHarness {
	t.Helper()
	h := &shardWSHarness{t: t, reg: pool.NewRegistry(nil), keys: map[string]ed25519.PrivateKey{}, inbox: map[string]chan map[string]any{}, clock: time.Unix(1_800_000_000, 0)}
	db, err := sql.Open("sqlite", "file:"+filepath.Join(t.TempDir(), "shard.db")+"?_pragma=busy_timeout(5000)")
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { _ = db.Close() })
	h.store, err = shardgroup.NewStore(db)
	if err != nil {
		t.Fatal(err)
	}
	registry := shardgroup.NewRegistry(shardgroup.ConfigFrom(config.DefaultShardGroupsConfig()), h.store, func() time.Time { return h.clock })
	owners := fakeShardOwners{"head": "github:42", "tail": "github:42"}
	h.server = NewServer(config.Default(), h.reg, zerolog.Nop(), WithNow(func() time.Time { return h.clock }), WithShardGroups(registry, h.store, owners))
	for _, id := range []string{"head", "tail"} {
		seed := sha256.Sum256([]byte(id))
		h.keys[id] = ed25519.NewKeyFromSeed(seed[:])
		p := &pool.Provider{
			ProviderID: id, AssignedID: "s-" + id, ModelID: shardWSModel, ModelHashAlgorithm: "macprovider.snapshot-manifest.v1", ModelHash: shardWSHash,
			InferencePath: pool.InferencePathWSTunneled, State: pool.StateReady, SlotsFree: 4, SlotsTotal: 4, MaxConcurrency: 4,
			Tier: pool.TierTrusted, ReceiptPubkey: h.keys[id].Public().(ed25519.PublicKey), BinaryVersion: "1.8.300",
			ShardGroupHeadV1: id == "head", ShardMemberV1: id == "tail",
		}
		client, server := net.Pipe()
		h.cleanup = append(h.cleanup, client, server)
		h.reg.Register(p, server)
		// The receipt key is published by the post-auth state_update.
		h.reg.ApplyStateUpdate(id, p.AssignedID, pool.StateUpdate{State: pool.StateReady, At: h.clock})
		session := newProviderSession(id, p.AssignedID, server, 16, time.Second)
		h.server.sessions.Store(sessionKey(id, p.AssignedID), session)
		go session.runWriter()
		inbox := make(chan map[string]any, 16)
		h.inbox[id] = inbox
		go func(conn net.Conn) {
			for {
				raw, err := wsutil.ReadServerText(conn)
				if err != nil {
					return
				}
				var msg map[string]any
				if json.Unmarshal(raw, &msg) == nil {
					inbox <- msg
				}
			}
		}(client)
	}
	t.Cleanup(func() {
		for _, c := range h.cleanup {
			_ = c.Close()
		}
	})
	return h
}

func (h *shardWSHarness) next(id, wantType string) map[string]any {
	h.t.Helper()
	select {
	case msg := <-h.inbox[id]:
		if msg["type"] != wantType {
			h.t.Fatalf("%s got %v, want %s", id, msg, wantType)
		}
		return msg
	case <-time.After(2 * time.Second):
		h.t.Fatalf("%s: no %s message", id, wantType)
	}
	return nil
}

func (h *shardWSHarness) registerPayload() []byte {
	rec := shardgroup.Record{
		Schema: shardgroup.RecordSchema, GroupProviderID: "head", GroupEpoch: 1, ParallelismMode: "pipeline", InterconnectClass: "thunderbolt-ip",
		FrameProtection: "crc32c", TransportVersion: 1, NumLayers: 32, MaxConcurrency: 4,
		Model:       shardgroup.RecordModel{ModelID: shardWSModel, PoolModelID: shardWSPoolModel, ArtifactHashAlgorithm: "macprovider.snapshot-manifest.v1", ArtifactHash: shardWSHash},
		Stages:      []shardgroup.Stage{{StageIndex: 0, MemberDeviceID: "head", LayerStart: 0, LayerEnd: 18}, {StageIndex: 1, MemberDeviceID: "tail", LayerStart: 18, LayerEnd: 32}},
		Spares:      []shardgroup.Spare{},
		Supervision: shardgroup.Supervision{HeartbeatIntervalMS: 100, HeartbeatMissLimit: 3, DecodeHopDeadlineMS: 500, PrefillChunkDeadlineMS: 3000, ReplayDeadlineMS: 10000},
	}
	raw, _ := json.Marshal(rec)
	payload, _ := json.Marshal(shardgroup.RegisterMessage{Type: shardgroup.TypeRegister, Version: 1, Record: raw, RecordSignature: signShardDomain(h.t, h.keys["head"], "macprovider.shard-group-record.v1\n", raw, false)})
	return payload
}

func shardWSHello() []byte {
	payload, _ := json.Marshal(shardgroup.MemberHello{Type: shardgroup.TypeMemberHello, Version: 1, GroupProviderID: "head", GroupEpoch: 1, MemberDeviceID: "tail",
		Role: "stage", StageIndex: 1, LayerStart: 18, LayerEnd: 32, TransportVersion: 1, ArtifactHashAlgorithm: "macprovider.snapshot-manifest.v1", ArtifactHash: shardWSHash,
		WeightsVerified: true, StageFits: true, Links: []shardgroup.MemberLink{{PeerMemberDeviceID: "head", InterfaceType: "thunderbolt"}}})
	return payload
}

func shardWSHeartbeat() []byte {
	payload, _ := json.Marshal(shardgroup.Heartbeat{Type: shardgroup.TypeHeartbeat, Version: 1, GroupProviderID: "head", GroupEpoch: 1,
		Members: []shardgroup.HeartbeatMember{{MemberDeviceID: "head", Healthy: true}, {MemberDeviceID: "tail", Healthy: true}},
		Links: []shardgroup.HeartbeatLink{
			{FromMemberDeviceID: "head", ToMemberDeviceID: "tail", InterfaceType: "thunderbolt", RTTP99US: 400},
			{FromMemberDeviceID: "tail", ToMemberDeviceID: "head", InterfaceType: "thunderbolt", RTTP99US: 400},
		}})
	return payload
}

func shardWSMemberHealth() []byte {
	payload, _ := json.Marshal(shardgroup.MemberHealth{Type: shardgroup.TypeMemberHealth, Version: 1, GroupProviderID: "head", GroupEpoch: 1,
		MemberDeviceID: "tail", Healthy: true, Reason: "",
		Links: []shardgroup.MemberHealthLink{{PeerMemberDeviceID: "head", InterfaceType: "thunderbolt", RTTP99US: 300}}})
	return payload
}

func (h *shardWSHarness) available() bool {
	p, _ := h.reg.Resolve("head", "")
	return p.ShardGroupAvailable
}

// SPEC-051-R015/R029: a head registers, the member joins, the group heartbeat
// makes the group available and routing-state eligible, and losing the
// member makes it unavailable again, with shard_group_status on each change.
func TestShardGroupLifecycleOverWire(t *testing.T) {
	h := newShardWSHarness(t)
	h.server.handleMessage(nil, "head", "s-head", h.registerPayload())
	if res := h.next("head", shardgroup.TypeRegisterResult); res["accepted"] != true {
		t.Fatalf("register result %v", res)
	}
	if st := h.next("head", shardgroup.TypeStatus); st["available"] != false || st["reason"] != shardgroup.ReasonMemberNotJoined {
		t.Fatalf("status %v", st)
	}
	h.server.handleMessage(nil, "tail", "s-tail", shardWSHello())
	if res := h.next("tail", shardgroup.TypeMemberHelloResult); res["accepted"] != true {
		t.Fatalf("hello result %v", res)
	}
	if st := h.next("head", shardgroup.TypeStatus); st["reason"] != shardgroup.ReasonGroupHeartbeatStale {
		t.Fatalf("status %v", st)
	}
	if h.available() {
		t.Fatal("available before the group heartbeat")
	}
	h.server.handleMessage(nil, "head", "s-head", shardWSHeartbeat())
	if st := h.next("head", shardgroup.TypeStatus); st["reason"] != shardgroup.ReasonMemberHealthStale {
		t.Fatalf("status before the member's own report %v", st)
	}
	h.server.handleMessage(nil, "tail", "s-tail", shardWSMemberHealth())
	if st := h.next("head", shardgroup.TypeStatus); st["available"] != true {
		hp, _ := h.reg.Resolve("head", "")
		tp, _ := h.reg.Resolve("tail", "")
		t.Fatalf("status %v head=%+v admissible=%v tail admissible=%v", st, hp, hp.ShardMemberAdmissible(), tp.ShardMemberAdmissible())
	}
	head, _ := h.reg.Resolve("head", "")
	if !head.ShardGroupAvailable || !head.RoutingEligible() || len(head.ShardGroupMembers) != 1 || head.ShardGroupMembers[0].ProviderID != "tail" {
		t.Fatalf("head after heartbeat: %+v", head)
	}
	tail, _ := h.reg.Resolve("tail", "")
	if tail.RoutingEligible() {
		t.Fatal("member session routable")
	}
	// A member session cannot register a group.
	h.server.handleMessage(nil, "tail", "s-tail", h.registerPayload())
	if res := h.next("tail", shardgroup.TypeRegisterResult); res["accepted"] != false || res["reason"] != shardgroup.ReasonNotGroupHeadSession {
		t.Fatalf("member register %v", res)
	}
	h.server.handleDisconnect("tail", "s-tail")
	if st := h.next("head", shardgroup.TypeStatus); st["available"] != false {
		t.Fatalf("status after member loss %v", st)
	}
	if h.available() {
		t.Fatal("group available after member loss")
	}
}

func shardWSDigest(s string) string {
	sum := sha256.Sum256([]byte(s))
	return hex.EncodeToString(sum[:])
}

// SPEC-051-R019: a verified attestation keeps the receipt and is stored; a
// broken chain drops the receipt and records the faulty member.
func TestShardGroupAttestationOnTerminalFrame(t *testing.T) {
	h := newShardWSHarness(t)
	h.server.handleMessage(nil, "head", "s-head", h.registerPayload())
	h.server.handleMessage(nil, "tail", "s-tail", shardWSHello())
	tuple := []byte(`{"attempt_n":0,"provider_id":"head","request_id":"req-1"}`)
	sum := sha256.Sum256(tuple)
	receipt := base64.StdEncoding.EncodeToString(tuple) + "." + base64.StdEncoding.EncodeToString(make([]byte, 64))
	a, b := shardWSDigest("act"), shardWSDigest("tok")
	sub := func(member string, stage, start, end int, in, out string) shardgroup.SignedSubReceipt {
		sr := shardgroup.SubReceipt{MemberDeviceID: member, GroupEpoch: 1, StageIndex: stage, LayerStart: start, LayerEnd: end, RequestID: "req-1", PromptTokens: 5, DecodeSteps: 2, InDigest: in, OutDigest: out}
		raw, _ := json.Marshal(sr)
		return shardgroup.SignedSubReceipt{SubReceipt: sr, PublicKey: base64.StdEncoding.EncodeToString(h.keys[member].Public().(ed25519.PublicKey)), Signature: signShardDomain(t, h.keys[member], "macprovider.shard-sub-receipt.v1\n", raw, false)}
	}
	attestation := func(tailIn string) json.RawMessage {
		att := shardgroup.Attestation{Schema: shardgroup.AttestationSchema, GroupProviderID: "head", RequestID: "req-1", AttemptN: 0, ReceiptTupleSHA256: hex.EncodeToString(sum[:]),
			Segments: []shardgroup.AttestationSegment{{GroupEpoch: 1, StepStart: 0, StepEnd: 3, SubReceipts: []shardgroup.SignedSubReceipt{sub("head", 0, 0, 18, b, a), sub("tail", 1, 18, 32, tailIn, b)}}}}
		raw, _ := json.Marshal(att)
		att.Signature = signShardDomain(t, h.keys["head"], "macprovider.shard-group-attestation.v1\n", raw, true)
		out, _ := json.Marshal(att)
		return out
	}
	end := h.server.applyShardGroupAttestation("head", "s-head", InferenceResponseEnd{RequestID: "req-1", Status: "complete", Receipt: receipt, GroupAttestation: attestation(a)})
	if end.Receipt != receipt || end.GroupAttestation != nil {
		t.Fatalf("verified attestation dropped the receipt: %+v", end)
	}
	stored, ok, err := h.store.Attestation(context.Background(), "req-1", 0, "head")
	if err != nil || !ok || !stored.Verified {
		t.Fatalf("stored verdict %+v %v %v", stored, ok, err)
	}
	broken := h.server.applyShardGroupAttestation("head", "s-head", InferenceResponseEnd{RequestID: "req-2", Status: "complete", Receipt: receipt, GroupAttestation: attestation(shardWSDigest("forged"))})
	if broken.Receipt != "" {
		t.Fatal("broken chain kept the receipt")
	}
	missing := h.server.applyShardGroupAttestation("head", "s-head", InferenceResponseEnd{RequestID: "req-3", Status: "complete", Receipt: receipt})
	if missing.Receipt != "" {
		t.Fatal("receipt without attestation kept")
	}
	// A session that is not a head is untouched.
	plain := h.server.applyShardGroupAttestation("tail", "s-tail", InferenceResponseEnd{RequestID: "req-4", Status: "complete", Receipt: receipt})
	if plain.Receipt != receipt {
		t.Fatal("non-head receipt dropped")
	}
}

// SEC-05: the owner cache never holds more than its cap; expired entries go
// first and a full cache of fresh entries stops caching.
func TestShardGroupOwnerCacheIsBounded(t *testing.T) {
	w := &shardGroupWiring{ownerCache: make(map[string]shardGroupOwnerEntry)}
	start := time.Unix(1_800_000_000, 0)
	for i := 0; i < shardGroupOwnerCacheCap+10; i++ {
		w.cacheOwnerLocked("old-"+strconv.Itoa(i), shardGroupOwnerEntry{fetched: start}, start)
	}
	if len(w.ownerCache) != shardGroupOwnerCacheCap {
		t.Fatalf("cache holds %d entries, cap %d", len(w.ownerCache), shardGroupOwnerCacheCap)
	}
	later := start.Add(shardGroupOwnerTTL + time.Second)
	w.cacheOwnerLocked("new", shardGroupOwnerEntry{fetched: later}, later)
	if len(w.ownerCache) != 1 {
		t.Fatalf("expired entries kept: %d", len(w.ownerCache))
	}
}
