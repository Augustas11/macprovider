package ws

import (
	"strings"

	"github.com/augstar/macprovider-coordinator/internal/autotune"
	"github.com/augstar/macprovider-coordinator/internal/billing"
	"github.com/augstar/macprovider-coordinator/internal/tier2"
)

// SPEC-042-R015 / SPEC-047-R011 (#1816): pool-manifest admission. This file
// holds the catalog-identity probes the trust-pool store applies at manifest
// acceptance; the binding itself lives next to the catalog binding.

// IsCatalogModelID reports whether id equals or normalizes onto a SPEC-010
// canonical id in the live catalog (the autotune release catalog or the
// Tier-2 catalog). A pool_model_id or its slug that does is rejected at
// manifest acceptance (SPEC-042-R015 shadowing rule).
func (s *Server) IsCatalogModelID(id string) bool {
	id = strings.TrimSpace(id)
	if id == "" {
		return false
	}
	if tier2.Catalogued(id) {
		return true
	}
	current, _ := s.autotuneCatalogSnapshot()
	return catalogShadowsModelID(current, id)
}

func catalogShadowsModelID(current *autotune.Catalog, id string) bool {
	if current == nil {
		return false
	}
	if _, _, ok := current.HighestClaimedTier(id); ok {
		return true
	}
	normalized := billing.NormalizeModelKey(strings.ToLower(id))
	for _, key := range current.Keys() {
		row, _ := current.Row(key)
		if billing.NormalizeModelKey(strings.ToLower(row.ModelID)) == normalized ||
			billing.NormalizeModelKey(strings.ToLower(key)) == normalized {
			return true
		}
	}
	return false
}

// ArtifactPairInCatalog reports whether an exact artifact pair already
// resolves to a global catalog identity: a catalog row's snapshot hash or a
// member of the release-bound artifact identity set. When it does, the
// catalog path wins and a pool entry for the same pair is rejected at
// manifest acceptance and is never routed (#1816 design rule).
func (s *Server) ArtifactPairInCatalog(algorithm, hash string) bool {
	hash = strings.ToLower(strings.TrimSpace(hash))
	if algorithm == "" || hash == "" {
		return false
	}
	resolved := false
	s.withReleaseRead(func() {
		current, _ := s.autotuneCatalogSnapshot()
		set := s.usableIdentitySetLocked(current)
		resolved = intakeModelKeyForOffer(current, set, map[string]string{algorithm: hash}) != "" ||
			catalogRowsCarryHash(current, hash)
	})
	return resolved
}

// catalogRowsCarryHash reports whether any catalog row (even an ambiguous
// pair of rows, which intake resolution refuses to name) carries hash.
func catalogRowsCarryHash(current *autotune.Catalog, hash string) bool {
	if current == nil {
		return false
	}
	for _, key := range current.Keys() {
		if row, _ := current.Row(key); strings.TrimSpace(row.ModelSHA256) == hash {
			return true
		}
	}
	return false
}
