package ws

import (
	"sync"

	"github.com/augstar/macprovider-coordinator/internal/artifactidentity"
	"github.com/augstar/macprovider-coordinator/internal/autotune"
	"github.com/augstar/macprovider-coordinator/internal/tier2"
)

// releaseSnapshotState is the SPEC-047-R001 v0.1.5 release snapshot: the
// identity set of every retained release (SPEC-010-R004 v1.8) plus the
// staging area a SIGHUP reload fills before ONE atomic publication. `mu` is
// the release read-write lock — readers hold it across a whole evaluation,
// the publisher across the whole swap — and `gen` the published generation.
type releaseSnapshotState struct {
	// feedIntegrityFailed records that the current release's artifact feed
	// was present but rejected (SPEC-023 integrity failure) at the last
	// publication, so a feed-path offer pair is `catalog_artifact_feed_integrity_failure`.
	feedIntegrityFailed bool
	mu                  sync.RWMutex
	sets                map[string]*artifactidentity.Index
	gen                 uint64

	staging bool
	stageMu sync.Mutex
	// onReadLocked, when set (tests only), runs right after a reader took
	// mu — the point at which a publisher may queue behind it.
	onReadLocked func()
	// staged parts of the next release, set by the reload before publication
	stagedCatalog    *autotune.Catalog
	stagedCompatible []*autotune.Catalog
	catalogStaged    bool
	stagedTier2      *tier2.Catalog
}

func (r *releaseSnapshotState) stagingEnabled() bool { return r.staging }

func (r *releaseSnapshotState) stageCatalog(catalog *autotune.Catalog, compatible []*autotune.Catalog) {
	r.stageMu.Lock()
	r.stagedCatalog, r.stagedCompatible, r.catalogStaged = catalog, compatible, true
	r.stageMu.Unlock()
}

func (r *releaseSnapshotState) stageTier2(next *tier2.Catalog) {
	r.stageMu.Lock()
	r.stagedTier2 = next
	r.stageMu.Unlock()
}

func (r *releaseSnapshotState) hasStaged() bool {
	r.stageMu.Lock()
	defer r.stageMu.Unlock()
	return r.catalogStaged || r.stagedTier2 != nil
}

// takeStagedCatalog returns and clears the staged catalog half.
func (r *releaseSnapshotState) takeStagedCatalog() (*autotune.Catalog, []*autotune.Catalog, bool) {
	r.stageMu.Lock()
	defer r.stageMu.Unlock()
	catalog, compatible, staged := r.stagedCatalog, r.stagedCompatible, r.catalogStaged
	r.stagedCatalog, r.stagedCompatible, r.catalogStaged = nil, nil, false
	return catalog, compatible, staged
}

// publishLocked installs the sets, promotes any staged Tier-2 material, and
// bumps the generation; the caller holds mu for writing.
func (r *releaseSnapshotState) publishLocked(sets map[string]*artifactidentity.Index, keepSets bool) uint64 {
	if !keepSets {
		if sets == nil {
			sets = map[string]*artifactidentity.Index{}
		}
		r.sets = sets
	} else if r.sets == nil {
		r.sets = map[string]*artifactidentity.Index{}
	}
	r.stageMu.Lock()
	staged := r.stagedTier2
	r.stagedTier2 = nil
	r.stageMu.Unlock()
	if staged != nil {
		tier2.PublishStaged(staged)
	}
	r.gen++
	return r.gen
}

func (r *releaseSnapshotState) generation() uint64 {
	r.mu.RLock()
	defer r.mu.RUnlock()
	return r.gen
}

// generationLocked is generation() for a caller that already holds mu (a
// nested read lock deadlocks against a queued publisher).
func (r *releaseSnapshotState) generationLocked() uint64 { return r.gen }

// setFor and currentSets read the published sets; callers that need a
// consistent snapshot across several reads hold mu themselves
// (Server.withReleaseRead) — these helpers take no lock so they can be used
// inside it, and the map is replaced wholesale on publish, never mutated.
func (r *releaseSnapshotState) setFor(release string) *artifactidentity.Index {
	return r.sets[release]
}

func (r *releaseSnapshotState) currentSets() map[string]*artifactidentity.Index {
	return r.sets
}

// integrityFailed reports whether the current release's artifact feed failed
// integrity at the last publication (read under the release read lock).
func (r *releaseSnapshotState) integrityFailed() bool { return r.feedIntegrityFailed }
