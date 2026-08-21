package trustpool

import (
	"context"
	"time"
)

const (
	DefaultRefreshInterval = 30 * time.Second
	MaxRefreshInterval     = 60 * time.Second
)

type RefreshResult struct {
	Revision         uint64
	PoolCount        int
	RouteableCount   int
	Changed          bool
	CheckedAtUTC     time.Time
	NextRefreshAtUTC time.Time
}

func RefreshRegistry(ctx context.Context, store *Store, registry *Registry) (RefreshResult, error) {
	if store == nil || registry == nil {
		return RefreshResult{}, ErrStoreClosed
	}
	state, err := store.Reconstruct(ctx)
	if err != nil {
		return RefreshResult{}, err
	}
	snapshots := state.RouteableSnapshots()
	changed, err := registry.RefreshRouteableSnapshotsAtRevision(state.Revision, snapshots)
	if err != nil {
		return RefreshResult{}, err
	}
	return RefreshResult{
		Revision:         state.Revision,
		PoolCount:        len(state.Pools),
		RouteableCount:   routeableSnapshotCount(snapshots),
		Changed:          changed,
		CheckedAtUTC:     state.RouteGateCheckedAt,
		NextRefreshAtUTC: nextRouteableDeadline(snapshots, state.RouteGateCheckedAt),
	}, nil
}

func StartRefreshLoop(ctx context.Context, store *Store, registry *Registry, interval time.Duration, onResult func(RefreshResult, error)) {
	interval = normalizeRefreshInterval(interval)
	go func() {
		delay := time.Duration(0)
		for {
			timer := time.NewTimer(delay)
			select {
			case <-ctx.Done():
				timer.Stop()
				return
			case <-timer.C:
			}

			result, err := RefreshRegistry(ctx, store, registry)
			if onResult != nil {
				onResult(result, err)
			}
			delay = interval
			if err == nil {
				delay = nextRefreshDelay(result.CheckedAtUTC, result.NextRefreshAtUTC, interval)
			}
		}
	}()
}

func normalizeRefreshInterval(interval time.Duration) time.Duration {
	switch {
	case interval <= 0:
		return DefaultRefreshInterval
	case interval > MaxRefreshInterval:
		return MaxRefreshInterval
	default:
		return interval
	}
}

func nextRefreshDelay(now, nextDeadline time.Time, maxInterval time.Duration) time.Duration {
	if maxInterval <= 0 {
		maxInterval = DefaultRefreshInterval
	}
	now = now.UTC()
	if nextDeadline.IsZero() {
		return maxInterval
	}
	nextDeadline = nextDeadline.UTC()
	if !nextDeadline.After(now) {
		return time.Millisecond
	}
	until := nextDeadline.Sub(now)
	if until < maxInterval {
		return until
	}
	return maxInterval
}

func nextRouteableDeadline(snapshots []RouteableSnapshot, now time.Time) time.Time {
	now = now.UTC()
	var next time.Time
	for _, snapshot := range snapshots {
		if snapshot.RouteableUntilUTC.IsZero() || !snapshot.RouteableUntilUTC.After(now) {
			continue
		}
		if next.IsZero() || snapshot.RouteableUntilUTC.Before(next) {
			next = snapshot.RouteableUntilUTC.UTC()
		}
	}
	return next
}

func routeableSnapshotCount(snapshots []RouteableSnapshot) int {
	count := 0
	for _, snapshot := range snapshots {
		if snapshot.Routeable {
			count++
		}
	}
	return count
}
