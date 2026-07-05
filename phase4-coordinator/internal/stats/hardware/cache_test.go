package hardware

import (
	"context"
	"database/sql"
	"testing"
	"time"

	_ "modernc.org/sqlite"
)

func TestCacheRefreshAndLookup(t *testing.T) {
	db := openTestDB(t)
	execTestSQL(t, db, `
CREATE TABLE provider_hardware_profiles (
    provider_id TEXT PRIMARY KEY,
    chip_normalized TEXT NOT NULL,
    verified BOOLEAN NOT NULL DEFAULT FALSE
);
CREATE TABLE chip_hardware_profiles (
    chip_normalized TEXT PRIMARY KEY,
    memory_bandwidth_gb_per_s BIGINT NOT NULL,
    network_power_kw DOUBLE PRECISION NOT NULL,
    gpu_cores INT NOT NULL,
    cpu_cores INT NOT NULL
);
INSERT INTO provider_hardware_profiles (provider_id, chip_normalized, verified)
VALUES ('provider-a', 'm4 max', TRUE), ('provider-b', 'unknown', TRUE), ('provider-c', 'm4 max', FALSE);
INSERT INTO chip_hardware_profiles (
    chip_normalized, memory_bandwidth_gb_per_s, network_power_kw, gpu_cores, cpu_cores
) VALUES ('m4 max', 546, 0.075, 40, 16);
`)

	cache := NewCache(db)
	if err := cache.Refresh(context.Background()); err != nil {
		t.Fatalf("Refresh: %v", err)
	}
	got, ok := cache.LookupProviderHardware("provider-a")
	if !ok {
		t.Fatal("provider-a hardware missing")
	}
	if got.BandwidthGBPerSec != 546 || got.NetworkPowerKW != 0.075 ||
		got.GPUCoresTotal != 40 || got.CPUCoresTotal != 16 {
		t.Fatalf("unexpected capacity: %+v", got)
	}
	if _, ok := cache.LookupProviderHardware("provider-b"); ok {
		t.Fatal("provider-b should be absent without trusted chip profile")
	}
	if _, ok := cache.LookupProviderHardware("provider-c"); ok {
		t.Fatal("provider-c should be absent until hardware row is verified")
	}
}

func TestRefreshFailureKeepsPreviousSnapshot(t *testing.T) {
	db := openTestDB(t)
	execTestSQL(t, db, `
CREATE TABLE provider_hardware_profiles (
    provider_id TEXT PRIMARY KEY,
    chip_normalized TEXT NOT NULL,
    verified BOOLEAN NOT NULL DEFAULT FALSE
);
CREATE TABLE chip_hardware_profiles (
    chip_normalized TEXT PRIMARY KEY,
    memory_bandwidth_gb_per_s BIGINT NOT NULL,
    network_power_kw DOUBLE PRECISION NOT NULL,
    gpu_cores INT NOT NULL,
    cpu_cores INT NOT NULL
);
INSERT INTO provider_hardware_profiles (provider_id, chip_normalized, verified)
VALUES ('provider-a', 'm4', TRUE);
INSERT INTO chip_hardware_profiles (
    chip_normalized, memory_bandwidth_gb_per_s, network_power_kw, gpu_cores, cpu_cores
) VALUES ('m4', 120, 0.035, 10, 10);
`)

	cache := NewCache(db)
	if err := cache.Refresh(context.Background()); err != nil {
		t.Fatalf("initial Refresh: %v", err)
	}
	execTestSQL(t, db, `DROP TABLE chip_hardware_profiles;`)
	if err := cache.Refresh(context.Background()); err == nil {
		t.Fatal("expected refresh failure")
	}
	got, ok := cache.LookupProviderHardware("provider-a")
	if !ok || got.BandwidthGBPerSec != 120 {
		t.Fatalf("previous snapshot not preserved: %+v ok=%v", got, ok)
	}
}

func TestLookupDoesNotBlockOnSlowRefresh(t *testing.T) {
	db := openTestDB(t)
	cache := NewCache(db)
	cache.profiles = map[string]Capacity{"provider-a": {GPUCoresTotal: 10}}
	cache.SetQueryTimeout(time.Nanosecond)

	_, _ = cache.LookupProviderHardware("provider-a")
}

func openTestDB(t *testing.T) *sql.DB {
	t.Helper()
	db, err := sql.Open("sqlite", ":memory:")
	if err != nil {
		t.Fatalf("open sqlite: %v", err)
	}
	t.Cleanup(func() { _ = db.Close() })
	return db
}

func execTestSQL(t *testing.T, db *sql.DB, sqlText string) {
	t.Helper()
	if _, err := db.Exec(sqlText); err != nil {
		t.Fatalf("exec test sql: %v", err)
	}
}
