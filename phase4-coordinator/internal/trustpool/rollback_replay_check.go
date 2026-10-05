package trustpool

import (
	"context"
	"database/sql"
	"encoding/json"
	"fmt"
	"maps"
	"slices"

	"github.com/augstar/macprovider-coordinator/internal/poolmanifest"
)

// Rollback target tiers (docs/runbooks/trusted-pool-production-launch.md
// section 9 step 4b): which manifest history an older coordinator can replay
// at start. A coordinator that cannot decode one accepted manifest disables
// every pool (#1816 VM acceptance A-2), so the rollback preflight refuses it.
const (
	RollbackTierV1Only = "v1-only"
	RollbackTierM8     = "m8"
	RollbackTierM9     = "m9"
	RollbackTierP1816  = "p1816"
)

var (
	rollbackTierM9Classes = []string{
		poolmanifest.RuntimeSourceLlamacppLoopback,
		poolmanifest.RuntimeSourceLMStudioLoopback,
		poolmanifest.RuntimeSourceMLXLMLoopback,
		poolmanifest.RuntimeSourceOllamaLoopback,
		poolmanifest.RuntimeSourceOMLXLoopback,
	}
	// rollbackTierClasses is nil for v1-only: that target replays no v2 core.
	rollbackTierClasses = map[string][]string{
		RollbackTierV1Only: nil,
		RollbackTierM8: {
			poolmanifest.RuntimeSourceLlamacppLoopback,
			poolmanifest.RuntimeSourceMLXLMLoopback,
			poolmanifest.RuntimeSourceOllamaLoopback,
		},
		RollbackTierM9:    rollbackTierM9Classes,
		RollbackTierP1816: rollbackTierM9Classes,
	}
	rollbackTierExtensions = map[string][]string{
		RollbackTierP1816: {poolmanifest.ExtensionPoolAttestedMembersV1, poolmanifest.ExtensionPoolModelEntriesV1},
	}
)

// ManifestReplayCheck is the result of CheckManifestHistoryReplay.
type ManifestReplayCheck struct {
	TargetTier     string   `json:"target_tier"`
	Manifests      int      `json:"manifests"`
	V2Snapshots    int      `json:"v2_snapshots"`
	RuntimeClasses []string `json:"runtime_classes"`
	Extensions     []string `json:"extensions"`
	CannotReplay   []string `json:"cannot_replay"`
}

// ValidRollbackTier reports whether tier names a known rollback target tier.
func ValidRollbackTier(tier string) bool {
	_, ok := rollbackTierClasses[tier]
	return ok
}

// CheckManifestHistoryReplay strictly decodes every manifest_accepted
// snapshot in the trust-pool history (read-only) and lists what a coordinator
// of the target tier could not replay. Any undecodable snapshot is an error:
// the caller must treat it as a refusal.
func CheckManifestHistoryReplay(ctx context.Context, db *sql.DB, tier string) (ManifestReplayCheck, error) {
	out := ManifestReplayCheck{TargetTier: tier, RuntimeClasses: []string{}, Extensions: []string{}, CannotReplay: []string{}}
	accepts, ok := rollbackTierClasses[tier]
	if !ok {
		return out, fmt.Errorf("unknown rollback target tier %q", tier)
	}
	var tables int
	if err := db.QueryRowContext(ctx, `SELECT COUNT(*) FROM sqlite_master WHERE type = 'table' AND name = 'trustpool_events'`).Scan(&tables); err != nil {
		return out, err
	}
	if tables == 0 {
		return out, nil
	}
	rows, err := db.QueryContext(ctx, `SELECT id, payload_json FROM trustpool_events WHERE event_type = ? ORDER BY id`, string(EventManifestAccepted))
	if err != nil {
		return out, err
	}
	defer rows.Close()
	classes, extensions := map[string]bool{}, map[string]bool{}
	for rows.Next() {
		var id int64
		var payload string
		if err := rows.Scan(&id, &payload); err != nil {
			return out, err
		}
		var e DurableEvent
		if err := json.Unmarshal([]byte(payload), &e); err != nil {
			return out, fmt.Errorf("manifest event %d: %w", id, err)
		}
		raw, err := canonicalBase64(e.ManifestSnapshot)
		if err != nil {
			return out, fmt.Errorf("manifest event %d: %w", id, err)
		}
		snapshot, err := poolmanifest.ParseManifestSnapshot(raw)
		if err != nil {
			return out, fmt.Errorf("manifest event %d: %w", id, err)
		}
		out.Manifests++
		v2 := false
		for _, p := range snapshot.Policies {
			core := p.SignedCore.Core
			if core.Encoding != 0 {
				v2 = true
			}
			if !core.IsV2() {
				continue
			}
			for _, c := range core.RuntimeAllowlist {
				classes[c] = true
			}
			for _, x := range core.Extensions {
				extensions[x.ID] = true
			}
		}
		if v2 {
			out.V2Snapshots++
		}
	}
	if err := rows.Err(); err != nil {
		return out, err
	}
	out.RuntimeClasses = slices.Sorted(maps.Keys(classes))
	out.Extensions = slices.Sorted(maps.Keys(extensions))
	if accepts == nil && out.V2Snapshots > 0 {
		out.CannotReplay = append(out.CannotReplay, "policy-core v2 snapshots")
	}
	for _, c := range out.RuntimeClasses {
		if !slices.Contains(accepts, c) {
			out.CannotReplay = append(out.CannotReplay, "runtime class "+c)
		}
	}
	for _, x := range out.Extensions {
		if !slices.Contains(rollbackTierExtensions[tier], x) {
			out.CannotReplay = append(out.CannotReplay, "extension "+x)
		}
	}
	return out, nil
}
