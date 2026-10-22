package poolmanifest

import (
	"encoding/hex"
	"errors"
	"testing"
)

// --- SPEC-051-R028 pool_shard_groups/v1 (#2084) ---

const shardTestPoolID = "ijUnc-ZQf-LJeRvkhi-0iQ"

func shardGroupCore(t *testing.T, groups []PoolShardGroup) PolicyCore {
	t.Helper()
	pc := rawPoolCore(t, shardTestPoolID, sampleEntries(shardTestPoolID), nil)
	if len(groups) > 0 {
		pc.Extensions = append(pc.Extensions, PolicyExtension{ID: ExtensionPoolShardGroupsV1, Body: must(EncodePoolShardGroups(groups))})
	}
	return pc
}

func TestPoolShardGroupsRoundTripAndAcceptance(t *testing.T) {
	pc := rawPoolCore(t, shardTestPoolID, nil, nil)
	groups := []PoolShardGroup{
		{GroupProviderID: "head-a", PoolModelID: "pool/" + pc.PoolID + "/tiny-mlx", MaxMembers: 3},
		{GroupProviderID: "head-b", PoolModelID: "pool/" + pc.PoolID + "/tiny-mlx", MaxMembers: 8},
	}
	core := shardGroupCore(t, groups)
	if err := core.ValidateFullAcceptance(); err != nil {
		t.Fatalf("valid shard group core rejected: %v", err)
	}
	got, err := core.PoolShardGroups()
	if err != nil || len(got) != 2 || got[0] != groups[0] || got[1] != groups[1] {
		t.Fatalf("PoolShardGroups = %+v, %v", got, err)
	}
	body := must(EncodePoolShardGroups(groups[:1]))
	// u32 count, lp("head-a"), lp(pool_model_id), u64 3.
	wantPrefix := "00000001" + "00000006" + hex.EncodeToString([]byte("head-a"))
	if hex.EncodeToString(body)[:len(wantPrefix)] != wantPrefix {
		t.Fatalf("body prefix = %x", body)
	}
	if _, err := DecodePoolShardGroups(append(body, 0)); err == nil {
		t.Fatal("trailing byte accepted")
	}
	// A core without the extension keeps its digest and authorizes nothing.
	plain := shardGroupCore(t, nil)
	if got, err := plain.PoolShardGroups(); err != nil || got != nil {
		t.Fatalf("core without extension = %+v, %v", got, err)
	}
	set := plain
	if err := set.SetPoolShardGroups(groups); err != nil {
		t.Fatal(err)
	}
	if err := set.ValidateFullAcceptance(); err != nil {
		t.Fatalf("SetPoolShardGroups core rejected: %v", err)
	}
	if err := set.SetPoolShardGroups(nil); err != nil {
		t.Fatal(err)
	}
	a, _ := set.CanonicalBytes()
	b, _ := plain.CanonicalBytes()
	if string(a) != string(b) {
		t.Fatal("clearing the extension did not restore the core bytes")
	}
}

func TestPoolShardGroupsRejectionVectors(t *testing.T) {
	pc := rawPoolCore(t, shardTestPoolID, nil, nil)
	native := "pool/" + pc.PoolID + "/tiny-mlx"
	ggufOnly := "pool/" + pc.PoolID + "/mistral-small-q4"
	cases := []struct {
		name   string
		groups []PoolShardGroup
		want   error
		code   string
	}{
		{"out of order", []PoolShardGroup{{"head-b", native, 2}, {"head-a", native, 2}}, errShardGroupsOrder, RejectCodeDuplicate},
		{"duplicate", []PoolShardGroup{{"head-a", native, 2}, {"head-a", native, 2}}, errShardGroupsOrder, RejectCodeDuplicate},
		{"bad id", []PoolShardGroup{{"head a", native, 2}}, errShardGroupID, RejectCodeInvalid},
		{"unknown model", []PoolShardGroup{{"head-a", "pool/" + pc.PoolID + "/absent", 2}}, errShardGroupModel, RejectCodeInvalid},
		{"non-native model", []PoolShardGroup{{"head-a", ggufOnly, 2}}, errShardGroupModel, RejectCodeInvalid},
		{"one member", []PoolShardGroup{{"head-a", native, 1}}, errShardGroupMembers, RejectCodeInvalid},
		{"nine members", []PoolShardGroup{{"head-a", native, 9}}, errShardGroupMembers, RejectCodeInvalid},
	}
	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			err := shardGroupCore(t, tc.groups).ValidateFullAcceptance()
			if !errors.Is(err, tc.want) {
				t.Fatalf("err = %v, want %v", err, tc.want)
			}
			if code := PoolModelRejectCode(err); code != tc.code {
				t.Fatalf("code = %q, want %q", code, tc.code)
			}
		})
	}
	t.Run("observe mode", func(t *testing.T) {
		core := shardGroupCore(t, []PoolShardGroup{{"head-a", native, 2}})
		core.SettlementMode = "observe"
		if err := core.validateShardGroups(); !errors.Is(err, errShardGroupsObserve) {
			t.Fatalf("err = %v", err)
		}
	})
	t.Run("too many entries", func(t *testing.T) {
		groups := make([]PoolShardGroup, MaxPoolShardGroups+1)
		if _, err := EncodePoolShardGroups(groups); !errors.Is(err, errShardGroupsBound) {
			t.Fatalf("err = %v", err)
		}
	})
}

// The SPEC-042-R001 acceptance of ValidateAcceptance is unchanged: it still
// refuses the extension, which only ValidateFullAcceptance implements, and
// ValidateFullAcceptance still refuses every unknown id.
func TestShardGroupsOnlyThroughFullAcceptance(t *testing.T) {
	core := shardGroupCore(t, []PoolShardGroup{{GroupProviderID: "head-a", PoolModelID: "pool/" + shardTestPoolID + "/tiny-mlx", MaxMembers: 2}})
	if err := core.ValidateAcceptance(); !errors.Is(err, errExtensionUnknown) {
		t.Fatalf("ValidateAcceptance err = %v", err)
	}
	if err := core.ValidateFullAcceptance(); err != nil {
		t.Fatalf("ValidateFullAcceptance err = %v", err)
	}
	core.Extensions = append(core.Extensions, PolicyExtension{ID: "pool_zz_unknown/v1", Body: []byte{0}})
	if err := core.ValidateFullAcceptance(); err == nil {
		t.Fatal("unknown extension accepted")
	}
	plain := shardGroupCore(t, nil)
	if a, b := plain.ValidateAcceptance(), plain.ValidateFullAcceptance(); a != nil || b != nil {
		t.Fatalf("core without the extension: %v / %v", a, b)
	}
}
