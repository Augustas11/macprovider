package shardgroup

import (
	"bytes"
	"context"
	"database/sql"
	"encoding/base64"
	"encoding/json"
	"os"
	"path/filepath"
	"testing"
	"time"

	"github.com/augstar/macprovider-coordinator/internal/config"
	"github.com/augstar/macprovider-coordinator/internal/pool"
)

// goldenPath is the cross-language fixture the provider's
// ShardGroupWireGoldenTests writes and checks (SPEC-051-R029, R019).
const goldenPath = "../../../test/fixtures/shard-group/wire-golden-v1.json"

type goldenVectors struct {
	HeadPublicKey string          `json:"head_public_key"`
	TailPublicKey string          `json:"tail_public_key"`
	Receipt       string          `json:"receipt"`
	Register      json.RawMessage `json:"shard_group_register"`
	Heartbeat     json.RawMessage `json:"shard_group_heartbeat"`
	MemberHello   json.RawMessage `json:"shard_member_hello"`
	MemberHealth  json.RawMessage `json:"shard_member_health"`
	Attestation   json.RawMessage `json:"group_attestation"`
}

func loadGolden(t *testing.T) goldenVectors {
	t.Helper()
	raw, err := os.ReadFile(goldenPath)
	if err != nil {
		t.Fatalf("read golden vectors: %v", err)
	}
	var g goldenVectors
	if err := decodeStrict(raw, &g); err != nil {
		t.Fatalf("golden vectors file: %v", err)
	}
	return g
}

func goldenKey(t *testing.T, b64 string) []byte {
	t.Helper()
	key, err := base64.StdEncoding.Strict().DecodeString(b64)
	if err != nil || len(key) != 32 {
		t.Fatalf("golden key %q: %v", b64, err)
	}
	return key
}

// TestProviderGoldenVectorsVerify runs the provider-encoded group messages
// through the coordinator exactly as a live head and member session would:
// strict parsing, the record signature, record validation, registration, the
// member hello, the heartbeat, availability, and the group attestation. A
// change on either side of the wire that the other does not share fails here.
func TestProviderGoldenVectorsVerify(t *testing.T) {
	g := loadGolden(t)
	headKey, tailKey := goldenKey(t, g.HeadPublicKey), goldenKey(t, g.TailPublicKey)

	msg, rec, err := ParseRegister(g.Register)
	if err != nil {
		t.Fatalf("register refused by the strict parser: %v", err)
	}
	if !VerifyRecordSignature(msg.Record, msg.RecordSignature, headKey) {
		t.Fatal("record signature does not verify under the head key")
	}
	// The Go record type carries exactly the provider's fields: re-encoding it
	// yields the same JCS bytes the head signed.
	reencoded, err := json.Marshal(rec)
	if err != nil {
		t.Fatal(err)
	}
	want, err := canonicalSigned("", msg.Record, false)
	if err != nil {
		t.Fatal(err)
	}
	got, err := canonicalSigned("", reencoded, false)
	if err != nil {
		t.Fatal(err)
	}
	if !bytes.Equal(want, got) {
		t.Fatalf("record round trip drifted:\nprovider %s\ncoordinator %s", want, got)
	}
	cfg := ConfigFrom(config.DefaultShardGroupsConfig())
	head := HeadView{
		ProviderID: rec.GroupProviderID, ModelID: rec.Model.ModelID, ModelHashAlgorithm: rec.Model.ArtifactHashAlgorithm,
		ModelHash: rec.Model.ArtifactHash, MaxConcurrency: rec.MaxConcurrency,
	}
	if reason := ValidateRecord(rec, cfg, head); reason != "" {
		t.Fatalf("provider record refused: %s", reason)
	}
	hello, err := ParseMemberHello(g.MemberHello)
	if err != nil {
		t.Fatalf("member hello refused by the strict parser: %v", err)
	}
	if _, err := ParseHeartbeat(g.Heartbeat); err != nil {
		t.Fatalf("heartbeat refused by the strict parser: %v", err)
	}
	if _, err := ParseMemberHealth(g.MemberHealth); err != nil {
		t.Fatalf("member health refused by the strict parser: %v", err)
	}

	db, err := sql.Open("sqlite", filepath.Join(t.TempDir(), "golden.db"))
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { _ = db.Close() })
	store, err := NewStore(db)
	if err != nil {
		t.Fatal(err)
	}
	now := time.Unix(1_800_000_000, 0)
	reg := NewRegistry(cfg, store, func() time.Time { return now })
	headID, memberID := rec.GroupProviderID, hello.MemberDeviceID
	owners := map[string]string{headID: testOwner, memberID: testOwner}
	session := func(id string, key []byte, isHead bool) pool.Provider {
		return pool.Provider{
			ProviderID: id, AssignedID: "s-" + id, ModelID: rec.Model.ModelID,
			ModelHashAlgorithm: rec.Model.ArtifactHashAlgorithm, ModelHash: rec.Model.ArtifactHash,
			InferencePath: pool.InferencePathWSTunneled, State: pool.StateReady, SlotsFree: 4, MaxConcurrency: rec.MaxConcurrency,
			Tier: pool.TierTrusted, ReceiptPubkey: key, BinaryVersion: "1.8.300",
			ShardGroupHeadV1: isHead, ShardMemberV1: !isHead,
		}
	}
	sessions := map[string]pool.Provider{headID: session(headID, headKey, true), memberID: session(memberID, tailKey, false)}

	res, _ := reg.Register(context.Background(), HeadSession{
		ProviderID: headID, AssignedID: "s-" + headID, ModelID: rec.Model.ModelID, ModelHashAlgorithm: rec.Model.ArtifactHashAlgorithm,
		ModelHash: rec.Model.ArtifactHash, MaxConcurrency: rec.MaxConcurrency, ReceiptKey: headKey, ShardGroupHeadV1: true, WSTunneled: true,
	}, g.Register, func([]string) map[string]string { return owners })
	if !res.Accepted {
		t.Fatalf("provider registration refused: %s", res.Reason)
	}
	if res := reg.MemberHello(context.Background(), MemberSession{ProviderID: memberID, AssignedID: "s-" + memberID, ReceiptKey: tailKey, ShardMemberV1: true}, g.MemberHello); !res.Accepted {
		t.Fatalf("provider member hello refused: %s", res.Reason)
	}
	if !reg.Heartbeat(headID, "s-"+headID, g.Heartbeat) {
		t.Fatal("provider heartbeat dropped")
	}
	if _, kept := reg.MemberHealth(MemberSession{ProviderID: memberID, AssignedID: "s-" + memberID, ReceiptKey: tailKey, ShardMemberV1: true}, g.MemberHealth); !kept {
		t.Fatal("provider member health dropped")
	}
	ev, ok := reg.Evaluate(headID, func(id string) (pool.Provider, bool) { p, ok := sessions[id]; return p, ok }, owners, 10*time.Second)
	if !ok || !ev.Available {
		t.Fatalf("group not available from provider messages: %+v", ev)
	}

	verdict := VerifyAttestation(g.Attestation, g.Receipt, headID, headKey, reg.Epochs(headID))
	if !verdict.Verified() {
		t.Fatalf("provider attestation refused: %s (member %s)", verdict.FaultKind, verdict.FaultMemberDeviceID)
	}
	// One flipped digest byte breaks the head signature over the attestation.
	tampered := bytes.Replace(g.Attestation, []byte(`"a1a1`), []byte(`"a1a0`), 1)
	if bytes.Equal(tampered, g.Attestation) {
		t.Fatal("tamper mutation did not apply")
	}
	if v := VerifyAttestation(tampered, g.Receipt, headID, headKey, reg.Epochs(headID)); v.Verified() {
		t.Fatal("tampered attestation verified")
	}
}
