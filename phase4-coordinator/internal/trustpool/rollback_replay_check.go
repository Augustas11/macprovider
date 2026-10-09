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
	// RollbackTierP1880 is the #1880 build: it also replays SPEC-042 0.0.42
	// supersession (a later policy window overlapping an earlier one) and
	// honors a model-admission offer's requested_pool_model_id.
	RollbackTierP1880 = "p1880"
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
		RollbackTierP1880: rollbackTierM9Classes,
	}
	rollbackTierExtensions = map[string][]string{
		RollbackTierP1816: {poolmanifest.ExtensionPoolAttestedMembersV1, poolmanifest.ExtensionPoolModelEntriesV1},
		RollbackTierP1880: {poolmanifest.ExtensionPoolAttestedMembersV1, poolmanifest.ExtensionPoolModelEntriesV1},
	}
)

// rollbackTierSupportsP1880 reports whether the target replays overlapping
// (superseding) policy windows and reads requested_pool_model_id. Every tier
// before p1880 rejects an overlapping window while rebuilding a pool's
// history (disabling the pool) and ignores the selector column.
func rollbackTierSupportsP1880(tier string) bool { return tier == RollbackTierP1880 }

// ManifestReplayCheck is the result of CheckManifestHistoryReplay.
type ManifestReplayCheck struct {
	TargetTier     string   `json:"target_tier"`
	Manifests      int      `json:"manifests"`
	V2Snapshots    int      `json:"v2_snapshots"`
	RuntimeClasses []string `json:"runtime_classes"`
	Extensions     []string `json:"extensions"`
	// SupersededWindows names each pool whose accepted history has a later
	// policy window overlapping an earlier one (SPEC-042 0.0.42).
	SupersededWindows []string `json:"superseded_windows"`
	CannotReplay      []string `json:"cannot_replay"`
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
	out := ManifestReplayCheck{TargetTier: tier, RuntimeClasses: []string{}, Extensions: []string{}, SupersededWindows: []string{}, CannotReplay: []string{}}
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
	rows, err := db.QueryContext(ctx, `SELECT id, pool_id, payload_json FROM trustpool_events WHERE event_type = ? ORDER BY id`, string(EventManifestAccepted))
	if err != nil {
		return out, err
	}
	defer rows.Close()
	classes, extensions, superseded := map[string]bool{}, map[string]bool{}, map[string]bool{}
	for rows.Next() {
		var id int64
		var poolID, payload string
		if err := rows.Scan(&id, &poolID, &payload); err != nil {
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
		for i, a := range snapshot.Policies {
			for _, b := range snapshot.Policies[i+1:] {
				ac, bc := a.SignedCore.Core, b.SignedCore.Core
				if ac.NotBeforeUnix < bc.ExpiresAtUnix && bc.NotBeforeUnix < ac.ExpiresAtUnix {
					superseded[fmt.Sprintf("pool %s (manifest versions %d and %d)", poolID, ac.ManifestVersion, bc.ManifestVersion)] = true
				}
			}
		}
	}
	if err := rows.Err(); err != nil {
		return out, err
	}
	out.RuntimeClasses = slices.Sorted(maps.Keys(classes))
	out.Extensions = slices.Sorted(maps.Keys(extensions))
	out.SupersededWindows = slices.Sorted(maps.Keys(superseded))
	if !rollbackTierSupportsP1880(tier) {
		for _, w := range out.SupersededWindows {
			out.CannotReplay = append(out.CannotReplay, "superseded policy window in "+w)
		}
	}
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

// PoolSelectionRollbackCheck is the result of CheckPoolSelectionRollback.
type PoolSelectionRollbackCheck struct {
	TargetTier string `json:"target_tier"`
	// LiveSelectorOffers lists, as provider_id/candidate_id -> pool model
	// id, every model-admission candidate whose current (non-terminal) head
	// names a pool entry in requested_pool_model_id.
	LiveSelectorOffers []string `json:"live_selector_offers"`
	Blocked            bool     `json:"blocked"`
}

// CheckPoolSelectionRollback lists the live model-admission offers that name
// a pool entry (#1880 requested_pool_model_id). A pre-p1880 coordinator
// ignores that column and could bind such an offer to another pool with the
// same artifact, so any of them blocks a rollback to such a target until the
// offer is withdrawn (or re-offered without pool_model_id). Read-only.
func CheckPoolSelectionRollback(ctx context.Context, db *sql.DB, tier string) (PoolSelectionRollbackCheck, error) {
	out := PoolSelectionRollbackCheck{TargetTier: tier, LiveSelectorOffers: []string{}}
	if !ValidRollbackTier(tier) {
		return out, fmt.Errorf("unknown rollback target tier %q", tier)
	}
	var columns int
	if err := db.QueryRowContext(ctx, `SELECT COUNT(*) FROM pragma_table_info('model_admission_events') WHERE name = 'requested_pool_model_id'`).Scan(&columns); err != nil {
		return out, err
	}
	if columns == 0 {
		return out, nil
	}
	rows, err := db.QueryContext(ctx, `
SELECT e.provider_id, e.candidate_id, e.requested_pool_model_id
  FROM model_admission_events e
  JOIN (SELECT MAX(id) AS id FROM model_admission_events GROUP BY provider_id, candidate_id) head ON head.id = e.id
 WHERE e.requested_pool_model_id <> ''
   AND e.state NOT IN ('offer_rejected', 'withdrawn', 'revoked')
 ORDER BY e.provider_id, e.candidate_id`)
	if err != nil {
		return out, err
	}
	defer rows.Close()
	for rows.Next() {
		var providerID, candidateID, requested string
		if err := rows.Scan(&providerID, &candidateID, &requested); err != nil {
			return out, err
		}
		out.LiveSelectorOffers = append(out.LiveSelectorOffers, providerID+"/"+candidateID+" -> "+requested)
	}
	if err := rows.Err(); err != nil {
		return out, err
	}
	out.Blocked = len(out.LiveSelectorOffers) > 0 && !rollbackTierSupportsP1880(tier)
	return out, nil
}
