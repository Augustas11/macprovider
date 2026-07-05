package hardware

import (
	"context"
	"database/sql"
	"errors"
	"fmt"
	"strings"
	"sync"
	"time"
)

const (
	defaultRefreshInterval = 60 * time.Second
	defaultQueryTimeout    = 2 * time.Second
)

// Capacity is an operator-trusted hardware tuple for one provider.
type Capacity struct {
	BandwidthGBPerSec int64
	NetworkPowerKW    float64
	GPUCoresTotal     int
	CPUCoresTotal     int
}

// Cache refreshes provider hardware capacity from Postgres on the stats
// rollup side and exposes memory-only lookups to the live pool snapshot.
type Cache struct {
	db              *sql.DB
	refreshInterval time.Duration
	queryTimeout    time.Duration

	mu       sync.RWMutex
	profiles map[string]Capacity
}

// NewCache returns a hardware cache backed by db. The db must be the
// stats_rollup pool; callers pass nil to disable hardware enrichment.
func NewCache(db *sql.DB) *Cache {
	return &Cache{
		db:              db,
		refreshInterval: defaultRefreshInterval,
		queryTimeout:    defaultQueryTimeout,
		profiles:        map[string]Capacity{},
	}
}

// SetRefreshInterval is a test seam. Production uses the default.
func (c *Cache) SetRefreshInterval(interval time.Duration) {
	if interval > 0 {
		c.refreshInterval = interval
	}
}

// SetQueryTimeout is a test seam. Production uses the default.
func (c *Cache) SetQueryTimeout(timeout time.Duration) {
	if timeout > 0 {
		c.queryTimeout = timeout
	}
}

// Start runs the background refresh loop until ctx is cancelled.
func (c *Cache) Start(ctx context.Context, onError func(error)) {
	if c == nil || c.db == nil {
		return
	}
	go func() {
		ticker := time.NewTicker(c.refreshInterval)
		defer ticker.Stop()
		for {
			select {
			case <-ctx.Done():
				return
			case <-ticker.C:
				if err := c.Refresh(ctx); err != nil && onError != nil {
					onError(err)
				}
			}
		}
	}()
}

// Refresh reloads the in-memory provider capacity map. Failed refreshes leave
// the previous successful snapshot in place.
func (c *Cache) Refresh(ctx context.Context) error {
	if c == nil || c.db == nil {
		return errors.New("hardware cache db is nil")
	}
	timeout := c.queryTimeout
	if timeout <= 0 {
		timeout = defaultQueryTimeout
	}
	queryCtx, cancel := context.WithTimeout(ctx, timeout)
	defer cancel()

	rows, err := c.db.QueryContext(queryCtx, `
SELECT ph.provider_id,
       ch.memory_bandwidth_gb_per_s,
       ch.network_power_kw,
       ch.gpu_cores,
       ch.cpu_cores
  FROM provider_hardware_profiles ph
  JOIN chip_hardware_profiles ch
    ON ch.chip_normalized = ph.chip_normalized
 WHERE ph.provider_id <> ''
   AND ph.verified = TRUE`)
	if err != nil {
		return fmt.Errorf("refresh hardware cache: %w", err)
	}
	defer rows.Close()

	next := map[string]Capacity{}
	for rows.Next() {
		var providerID string
		var cap Capacity
		if err := rows.Scan(
			&providerID,
			&cap.BandwidthGBPerSec,
			&cap.NetworkPowerKW,
			&cap.GPUCoresTotal,
			&cap.CPUCoresTotal,
		); err != nil {
			return fmt.Errorf("scan hardware cache row: %w", err)
		}
		providerID = strings.TrimSpace(providerID)
		if providerID == "" {
			continue
		}
		next[providerID] = cap
	}
	if err := rows.Err(); err != nil {
		return fmt.Errorf("iterate hardware cache rows: %w", err)
	}

	c.mu.Lock()
	c.profiles = next
	c.mu.Unlock()
	return nil
}

// LookupProviderHardware returns the cached trusted capacity for providerID.
// It never performs database or network work.
func (c *Cache) LookupProviderHardware(providerID string) (Capacity, bool) {
	if c == nil {
		return Capacity{}, false
	}
	providerID = strings.TrimSpace(providerID)
	if providerID == "" {
		return Capacity{}, false
	}
	c.mu.RLock()
	defer c.mu.RUnlock()
	cap, ok := c.profiles[providerID]
	return cap, ok
}
