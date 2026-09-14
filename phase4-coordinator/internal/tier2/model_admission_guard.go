package tier2

// TryPinSnapshotMaterial pins both current-default identity and its material
// through the caller's serialized admission decision. It never waits for an
// owner lock or invokes a locking catalog getter. Failure releases every pin;
// success requires exactly one release by the caller after commit/rollback.
func TryPinSnapshotMaterial(expected *Catalog, modelID, reportedHash string) (material RouteSnapshotMaterial, release func(), ok bool) {
	if expected == nil || !defaultPublicationMu.TryRLock() {
		return RouteSnapshotMaterial{}, nil, false
	}
	if defaultCatalog.Load() != expected || !expected.mu.TryRLock() {
		defaultPublicationMu.RUnlock()
		return RouteSnapshotMaterial{}, nil, false
	}
	material, ok = expected.routeSnapshotMaterialLocked(modelID, reportedHash)
	if !ok {
		expected.mu.RUnlock()
		defaultPublicationMu.RUnlock()
		return RouteSnapshotMaterial{}, nil, false
	}
	return material, func() {
		expected.mu.RUnlock()
		defaultPublicationMu.RUnlock()
	}, true
}
