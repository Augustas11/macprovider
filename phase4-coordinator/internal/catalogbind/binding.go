// Package catalogbind enforces that autotune admission identity and the
// Tier-2 attestation catalog do not disagree about model/hash rows while
// both authorities remain loaded (#608 Partial).
//
// Entry 170 / #609 keep admission identity sourced exclusively from the
// signed autotune row. This package does not introduce a Tier-2 fallback;
// it only fail-closes when an active Tier-2 row conflicts with the
// autotune row that admission would use for the same model_id.
package catalogbind

import (
	"fmt"
	"sort"
	"strings"

	"github.com/augstar/macprovider-coordinator/internal/autotune"
	"github.com/augstar/macprovider-coordinator/internal/tier2"
)

// Conflict describes one model_id where Tier-2 and autotune disagree on
// the artifact hash used for active-release identity.
type Conflict struct {
	ModelID         string
	AutotuneKey     string
	AutotuneSHA256  string
	Tier2SHA256     string
	AutotuneRelease string
	Tier2CatalogID  string
}

func (c Conflict) Error() string {
	return fmt.Sprintf(
		"model_id %q autotune(%s/%s)=%s conflicts with tier2(%s)=%s",
		c.ModelID,
		c.AutotuneRelease,
		c.AutotuneKey,
		c.AutotuneSHA256,
		c.Tier2CatalogID,
		c.Tier2SHA256,
	)
}

// Conflicts returns every overlapping model_id where both catalogs carry a
// non-empty artifact hash and those hashes differ. Tier-2-only or
// autotune-only rows are ignored (subset catalogs remain allowed until the
// full single-file authority lands). When either catalog is nil or Tier-2
// is not active, the result is empty.
func Conflicts(auto *autotune.Catalog, t2 *tier2.Catalog) []Conflict {
	if auto == nil || t2 == nil || !t2.Active() {
		return nil
	}
	modelIDs := t2.ModelIDs()
	out := make([]Conflict, 0)
	for _, modelID := range modelIDs {
		tier2Hash, ok := t2.ExpectedHash(modelID)
		if !ok {
			continue
		}
		tier2Hash = normalizeHash(tier2Hash)
		if tier2Hash == "" {
			continue
		}
		key, row, found := auto.HighestClaimedTier(modelID)
		if !found {
			continue
		}
		autoHash := normalizeHash(row.ModelSHA256)
		if autoHash == "" {
			continue
		}
		if autoHash == tier2Hash {
			continue
		}
		out = append(out, Conflict{
			ModelID:         modelID,
			AutotuneKey:     key,
			AutotuneSHA256:  autoHash,
			Tier2SHA256:     tier2Hash,
			AutotuneRelease: auto.Version,
			Tier2CatalogID:  t2.CatalogID(),
		})
	}
	sort.Slice(out, func(i, j int) bool {
		return out[i].ModelID < out[j].ModelID
	})
	return out
}

// RequireActiveReleaseBinding fail-closes when Conflicts is non-empty.
func RequireActiveReleaseBinding(auto *autotune.Catalog, t2 *tier2.Catalog) error {
	conflicts := Conflicts(auto, t2)
	if len(conflicts) == 0 {
		return nil
	}
	parts := make([]string, 0, len(conflicts))
	for _, c := range conflicts {
		parts = append(parts, c.Error())
	}
	return fmt.Errorf(
		"autotune/tier2 identity conflict on %d model(s): %s",
		len(conflicts),
		strings.Join(parts, "; "),
	)
}

// Tier2AgreesWithAdmittedHash reports whether an active Tier-2 row for
// modelID carries expectedHash. ok=false means Tier-2 is inactive or the
// model is not catalogued there (caller decides fail-open vs enforce).
// When ok=true and agrees=false, the catalogs conflict and callers must
// fail closed.
func Tier2AgreesWithAdmittedHash(t2 *tier2.Catalog, modelID, expectedHash string) (agrees bool, ok bool) {
	if t2 == nil || !t2.Active() {
		return false, false
	}
	tier2Hash, found := t2.ExpectedHash(modelID)
	if !found {
		return false, false
	}
	return normalizeHash(tier2Hash) == normalizeHash(expectedHash), true
}

func normalizeHash(raw string) string {
	return strings.ToLower(strings.TrimSpace(raw))
}
