package trustpool

import (
	"context"
	"database/sql"
	"fmt"

	"github.com/augstar/macprovider-coordinator/internal/poolmanifest"
)

// AcceptedCoreKey names one accepted policy core of a pool.
type AcceptedCoreKey struct {
	ManifestVersion    uint64
	ManifestCoreDigest string
}

// AcceptedPoolModelEntries replays one pool's durable event log and returns
// the SPEC-042-R015 pool model entries of every accepted policy core, keyed by
// version and core digest. It reads only immutable manifest_accepted events,
// so an entry is what the core named when it was accepted, whatever the pool
// carries now (SPEC-047-R012 licence agreement). A core whose snapshot does
// not parse is an error: the caller fails closed.
func AcceptedPoolModelEntries(ctx context.Context, q interface {
	QueryContext(context.Context, string, ...any) (*sql.Rows, error)
}, poolID string) (map[AcceptedCoreKey][]poolmanifest.PoolModelEntry, error) {
	events, err := poolEventsFromQueryer(ctx, q, poolID)
	if err != nil {
		return nil, err
	}
	out := map[AcceptedCoreKey][]poolmanifest.PoolModelEntry{}
	for _, pe := range events {
		e := pe.event
		if e.EventType != EventManifestAccepted {
			continue
		}
		core, err := acceptedPolicyCoreFromManifestSnapshot(e)
		if err != nil {
			return nil, fmt.Errorf("trustpool: pool %s manifest %d: %w", poolID, e.ManifestVersion, err)
		}
		if !core.IsV2() {
			continue
		}
		entries, err := core.PoolModelEntries()
		if err != nil {
			return nil, fmt.Errorf("trustpool: pool %s manifest %d entries: %w", poolID, e.ManifestVersion, err)
		}
		out[AcceptedCoreKey{ManifestVersion: e.ManifestVersion, ManifestCoreDigest: e.ManifestCoreDigest}] = poolmanifest.ClonePoolModelEntries(entries)
	}
	return out, nil
}
