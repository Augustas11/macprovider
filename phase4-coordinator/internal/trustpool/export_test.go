package trustpool

// ManifestVerificationsForTest is the count of uncached manifest
// acceptance verifications.
func ManifestVerificationsForTest() int64 { return manifestVerifications.Load() }

// SetBeforeManifestAcceptanceCommitForTest installs fn inside the manifest
// acceptance transaction, after the witness is planned and before COMMIT.
// Callers must not run in parallel and must call the returned restore.
func SetBeforeManifestAcceptanceCommitForTest(fn func() error) (restore func()) {
	prev := beforeManifestAcceptanceCommit
	beforeManifestAcceptanceCommit = fn
	return func() { beforeManifestAcceptanceCommit = prev }
}

// SetPublishManifestAcceptanceWitnessForTest replaces the post-commit witness
// writer. Callers must not run in parallel and must call the returned restore.
func SetPublishManifestAcceptanceWitnessForTest(fn func(string, map[string]ManifestAcceptanceProjection) error) (restore func()) {
	prev := publishManifestAcceptanceWitness
	publishManifestAcceptanceWitness = fn
	return func() { publishManifestAcceptanceWitness = prev }
}
