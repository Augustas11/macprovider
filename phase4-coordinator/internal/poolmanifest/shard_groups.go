package poolmanifest

// SPEC-051-R028 (#2084): the `pool_shard_groups/v1` extension of the v2
// policy core. It names the multi-Mac shard groups (by the head's provider
// identity) a creator allows to serve one of the core's native pool model
// entries. Like the R015/R016 extensions it is trust-bearing core data inside
// the v2 digest and signature, and a core without it keeps its exact bytes.

import (
	"bytes"
	"errors"
	"regexp"
	"sort"
)

// ExtensionPoolShardGroupsV1 is the SPEC-051-R028 extension id.
const ExtensionPoolShardGroupsV1 = "pool_shard_groups/v1"

// Closed bounds (SPEC-051-R028).
const (
	MaxPoolShardGroups    = 64
	MinShardGroupMembers  = 2
	MaxShardGroupMembers  = 8
	maxShardGroupIDLength = 64
)

var shardGroupProviderIDPattern = regexp.MustCompile(`^[a-zA-Z0-9_.-]{1,64}$`)

var (
	errShardGroupsBound    = errors.New("poolmanifest: pool_shard_groups exceeds 64 entries")
	errShardGroupsOrder    = errors.New("poolmanifest: pool_shard_groups must be strictly ascending by group_provider_id with no duplicates")
	errShardGroupID        = errors.New("poolmanifest: group_provider_id is not a provider id")
	errShardGroupModel     = errors.New("poolmanifest: shard group pool_model_id names no native pool_model_entries entry")
	errShardGroupMembers   = errors.New("poolmanifest: shard group max_members must be in [2, 8]")
	errShardGroupsObserve  = errors.New("poolmanifest: pool_shard_groups requires settlement mode enforce")
	errShardGroupsEmptyArg = errors.New("poolmanifest: an empty pool_shard_groups list must be omitted, not encoded")
)

// PoolShardGroup is one SPEC-051-R028 entry, encoded in this field order.
type PoolShardGroup struct {
	GroupProviderID string
	PoolModelID     string
	MaxMembers      uint64
}

// ClonePoolShardGroups returns an independent copy (nil for an empty list).
func ClonePoolShardGroups(in []PoolShardGroup) []PoolShardGroup {
	if len(in) == 0 {
		return nil
	}
	return append([]PoolShardGroup(nil), in...)
}

// EncodePoolShardGroups is the canonical pool_shard_groups/v1 body: u32
// count, then each entry's group_provider_id, pool_model_id, max_members.
func EncodePoolShardGroups(groups []PoolShardGroup) ([]byte, error) {
	if len(groups) == 0 {
		return nil, errShardGroupsEmptyArg
	}
	if len(groups) > MaxPoolShardGroups {
		return nil, errShardGroupsBound
	}
	e := &encoder{}
	e.u32count(len(groups))
	for _, g := range groups {
		e.str(g.GroupProviderID)
		e.str(g.PoolModelID)
		e.u64(g.MaxMembers)
	}
	if e.err != nil {
		return nil, e.err
	}
	return e.buf, nil
}

// DecodePoolShardGroups is the strict inverse of EncodePoolShardGroups.
func DecodePoolShardGroups(body []byte) ([]PoolShardGroup, error) {
	d := &decoder{buf: body}
	n := d.count()
	if d.err == nil && n > MaxPoolShardGroups {
		return nil, errShardGroupsBound
	}
	var out []PoolShardGroup
	for i := 0; i < n && d.err == nil; i++ {
		var g PoolShardGroup
		g.GroupProviderID = d.str()
		g.PoolModelID = d.str()
		g.MaxMembers = d.u64()
		out = append(out, g)
	}
	if err := d.done(); err != nil {
		return nil, errExtensionBody
	}
	if len(out) == 0 {
		return nil, errExtensionEmptyList
	}
	if again, err := EncodePoolShardGroups(out); err != nil || !bytes.Equal(again, body) {
		return nil, errExtensionBody
	}
	return out, nil
}

// PoolShardGroups decodes the core's pool_shard_groups/v1 extension. A core
// without it authorizes no group.
func (pc PolicyCore) PoolShardGroups() ([]PoolShardGroup, error) {
	body, ok := pc.extensionBody(ExtensionPoolShardGroupsV1)
	if !ok {
		return nil, nil
	}
	return DecodePoolShardGroups(body)
}

// SetPoolShardGroups replaces the core's pool_shard_groups/v1 extension with
// the canonical encoding of groups (omitted when empty) and keeps the
// extension list strictly ascending. The core must use the v2 encoding.
func (pc *PolicyCore) SetPoolShardGroups(groups []PoolShardGroup) error {
	if !pc.IsV2() {
		return errV1CarriesV2Fields
	}
	kept := pc.Extensions[:0:0]
	for _, ext := range pc.Extensions {
		if ext.ID != ExtensionPoolShardGroupsV1 {
			kept = append(kept, ext)
		}
	}
	if len(groups) > 0 {
		body, err := EncodePoolShardGroups(groups)
		if err != nil {
			return err
		}
		kept = append(kept, PolicyExtension{ID: ExtensionPoolShardGroupsV1, Body: body})
	}
	sort.SliceStable(kept, func(i, j int) bool { return kept[i].ID < kept[j].ID })
	pc.Extensions = kept
	return nil
}

// ValidateFullAcceptance is the acceptance check every manifest path runs:
// the SPEC-042-R001 rules of ValidateAcceptance over the core without its
// SPEC-051-R028 pool_shard_groups/v1 extension, then the grammar of the full
// core (extension id order included) and the closed shard group rules. A core
// without the extension gets exactly ValidateAcceptance.
func (pc PolicyCore) ValidateFullAcceptance() error {
	if _, ok := pc.extensionBody(ExtensionPoolShardGroupsV1); !ok {
		return pc.ValidateAcceptance()
	}
	base := pc
	base.Extensions = make([]PolicyExtension, 0, len(pc.Extensions))
	for _, ext := range pc.Extensions {
		if ext.ID != ExtensionPoolShardGroupsV1 {
			base.Extensions = append(base.Extensions, ext)
		}
	}
	if err := base.ValidateAcceptance(); err != nil {
		return err
	}
	if _, err := pc.CanonicalBytes(); err != nil {
		return err
	}
	return pc.validateShardGroups()
}

// validateShardGroups applies the closed SPEC-051-R028 rules: ascending
// unique provider ids, each naming a native (mlx_cache) entry of the same
// core's pool_model_entries/v1, a member bound in [2, 8], and enforce mode.
func (pc PolicyCore) validateShardGroups() error {
	groups, err := pc.PoolShardGroups()
	if err != nil || len(groups) == 0 {
		return err
	}
	if pc.SettlementMode != "enforce" {
		return errShardGroupsObserve
	}
	entries, err := pc.PoolModelEntries()
	if err != nil {
		return err
	}
	native := make(map[string]bool, len(entries))
	for _, m := range entries {
		if m.AllowsRuntimeSource(RuntimeSourceNativeMLX) {
			native[m.PoolModelID] = true
		}
	}
	for i, g := range groups {
		if i > 0 && g.GroupProviderID <= groups[i-1].GroupProviderID {
			return errShardGroupsOrder
		}
		if len(g.GroupProviderID) > maxShardGroupIDLength || !shardGroupProviderIDPattern.MatchString(g.GroupProviderID) {
			return errShardGroupID
		}
		if !native[g.PoolModelID] {
			return errShardGroupModel
		}
		if g.MaxMembers < MinShardGroupMembers || g.MaxMembers > MaxShardGroupMembers {
			return errShardGroupMembers
		}
	}
	return nil
}
