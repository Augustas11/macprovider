package trustpool

import (
	"crypto/sha256"
	"encoding/json"
	"sync"
	"sync/atomic"

	"github.com/augstar/macprovider-coordinator/internal/poolmanifest"
)

// Every manifest_accepted snapshot carries the pool's whole accepted policy
// history, and a durable replay (every pool buyer request, the registry
// refresh, every trust-pool mutation) verified every event, so replay cost
// grew with the square of the history: about 0.4 s for 120 accepted cores
// natively, far more under emulation, all while holding the coordinator's
// single SQLite connection (#1816 VM acceptance A-8). The timeless
// verification is a pure function of the event and its root issuer, so a
// verified result is memoized under a digest of both; changed bytes are a
// different key and verify again. Failures are never cached.
const manifestVerifyCacheMax = 4096

type manifestVerifyResult struct {
	prevDigest string
	core       poolmanifest.PolicyCore
}

var (
	manifestVerifyCacheMu sync.Mutex
	manifestVerifyCache   = map[[sha256.Size]byte]manifestVerifyResult{}
	// manifestVerifications counts uncached verifications (tests).
	manifestVerifications atomic.Int64
)

func verifyManifestAcceptedEventCached(e DurableEvent, root ReconstructedRootIssuer) (string, poolmanifest.PolicyCore, error) {
	key, keyErr := manifestVerifyCacheKey(e, root)
	if keyErr == nil {
		manifestVerifyCacheMu.Lock()
		hit, ok := manifestVerifyCache[key]
		manifestVerifyCacheMu.Unlock()
		if ok {
			return hit.prevDigest, hit.core, nil
		}
	}
	manifestVerifications.Add(1)
	prevDigest, core, err := VerifyManifestAcceptedEvent(e, root)
	if err != nil || keyErr != nil {
		return prevDigest, core, err
	}
	manifestVerifyCacheMu.Lock()
	if len(manifestVerifyCache) >= manifestVerifyCacheMax {
		clear(manifestVerifyCache)
	}
	manifestVerifyCache[key] = manifestVerifyResult{prevDigest: prevDigest, core: core}
	manifestVerifyCacheMu.Unlock()
	return prevDigest, core, nil
}

func manifestVerifyCacheKey(e DurableEvent, root ReconstructedRootIssuer) ([sha256.Size]byte, error) {
	raw, err := json.Marshal(struct {
		Event DurableEvent
		Root  ReconstructedRootIssuer
	}{e, root})
	if err != nil {
		return [sha256.Size]byte{}, err
	}
	return sha256.Sum256(raw), nil
}
