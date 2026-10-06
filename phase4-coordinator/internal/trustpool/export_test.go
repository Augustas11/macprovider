package trustpool

// ManifestVerificationsForTest is the count of uncached manifest
// acceptance verifications.
func ManifestVerificationsForTest() int64 { return manifestVerifications.Load() }
