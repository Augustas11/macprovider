// Tests for the M3-8d Catalog DI refactor (audit finding TEST-4).
// Verifies that:
//   * Independent *Catalog instances do not share state.
//   * VerifyProviderHash is race-free across them under -race.
//   * setDefault is an atomic pointer swap — readers in flight against the
//     old singleton complete cleanly and the next call sees the new one.
package tier2

import (
	"fmt"
	"sync"
	"sync/atomic"
	"testing"
	"time"

	"github.com/augstar/macprovider-coordinator/internal/config"
	"github.com/augstar/macprovider-coordinator/internal/pool"
	"github.com/rs/zerolog"
)

// TestCatalogParallel constructs N independent *Catalog instances, configures
// each with a distinct model+hash, then drives concurrent VerifyProviderHash
// calls across all of them. Each instance must report Verified for its own
// (model, hash) pair and Mismatch when crossed with another instance's hash —
// no cross-contamination, no race detected. Closes audit TEST-4: parallel
// tests are now safe without ResetForTest serialization.
func TestCatalogParallel(t *testing.T) {
	t.Parallel()

	const N = 8

	// Independent hashes (one per instance, all valid sha256-shaped).
	hashes := make([]string, N)
	for i := 0; i < N; i++ {
		hashes[i] = fmt.Sprintf("%064x", uint64(i+1))
	}

	cats := make([]*Catalog, N)
	for i := 0; i < N; i++ {
		raw, publicKey := signedCatalogFixture(t, time.Now().UTC().Add(time.Hour), hashes[i])
		path := writeTempCatalog(t, raw)

		cfg := config.Default().Tier2
		cfg.CatalogPath = path
		cfg.CatalogPublicKey = publicKey

		c := NewCatalog()
		if err := c.Configure(cfg, zerolog.Nop()); err != nil {
			t.Fatalf("instance %d Configure: %v", i, err)
		}
		if !c.Active() {
			t.Fatalf("instance %d not active", i)
		}
		cats[i] = c
	}

	// Concurrent fan-out. Each goroutine drives one instance for several
	// iterations and checks own-hash Verified + foreign-hash Mismatch.
	var wg sync.WaitGroup
	wg.Add(N)
	for i := 0; i < N; i++ {
		i := i
		go func() {
			defer wg.Done()
			for iter := 0; iter < 64; iter++ {
				if got := cats[i].VerifyProviderHash("model-a", hashes[i]); got != pool.HashStatusVerified {
					t.Errorf("instance %d iter %d own hash=%q want %q", i, iter, got, pool.HashStatusVerified)
					return
				}
				foreign := hashes[(i+1)%N]
				if got := cats[i].VerifyProviderHash("model-a", foreign); got != pool.HashStatusMismatch {
					t.Errorf("instance %d iter %d foreign hash=%q want %q", i, iter, got, pool.HashStatusMismatch)
					return
				}
			}
		}()
	}
	wg.Wait()
}

// TestSetDefaultAtomicSwap verifies that setDefault is a safe pointer swap
// under concurrent readers. One goroutine swaps the package singleton
// repeatedly between two pre-configured *Catalog instances while a second
// goroutine drives VerifyProviderHash through Default() in a tight loop.
// The reader must only ever observe one of two valid statuses for the model
// — either the "v1" catalog's Verified (for hash A) or the "v2" catalog's
// Verified (for hash B); under no schedule may it panic or see torn state.
//
// Closes audit TEST-4: SIGHUP reload is now an atomic.Pointer swap instead
// of an in-place mutation under sync.RWMutex.
func TestSetDefaultAtomicSwap(t *testing.T) {
	t.Parallel()

	// Save and restore the package singleton so this test does not bleed
	// into other tests in the same binary.
	prev := Default()
	defer setDefaultForTest(prev)

	hashA := "1111111111111111111111111111111111111111111111111111111111111111"
	hashB := "2222222222222222222222222222222222222222222222222222222222222222"

	mkCatalog := func(sha string) *Catalog {
		raw, publicKey := signedCatalogFixture(t, time.Now().UTC().Add(time.Hour), sha)
		path := writeTempCatalog(t, raw)
		cfg := config.Default().Tier2
		cfg.CatalogPath = path
		cfg.CatalogPublicKey = publicKey
		c := NewCatalog()
		if err := c.Configure(cfg, zerolog.Nop()); err != nil {
			t.Fatalf("Configure: %v", err)
		}
		return c
	}

	v1 := mkCatalog(hashA)
	v2 := mkCatalog(hashB)
	setDefaultForTest(v1)

	var stop atomic.Bool
	var swaps, reads atomic.Uint64
	var observedV1, observedV2 atomic.Uint64

	// Swapper goroutine: bounces the singleton between v1 and v2.
	var wg sync.WaitGroup
	wg.Add(1)
	go func() {
		defer wg.Done()
		toggle := false
		for !stop.Load() {
			toggle = !toggle
			if toggle {
				setDefaultForTest(v2)
			} else {
				setDefaultForTest(v1)
			}
			swaps.Add(1)
		}
	}()

	// Reader goroutines: hammer VerifyProviderHash via the package shim,
	// which loads Default() atomically on every call.
	const readers = 4
	for r := 0; r < readers; r++ {
		wg.Add(1)
		go func() {
			defer wg.Done()
			for !stop.Load() {
				// Probe with hashA: must be Verified on v1, Mismatch on v2.
				got := VerifyProviderHash("model-a", hashA)
				switch got {
				case pool.HashStatusVerified:
					observedV1.Add(1)
				case pool.HashStatusMismatch:
					observedV2.Add(1)
				default:
					t.Errorf("unexpected status under hashA probe: %q", got)
					return
				}
				reads.Add(1)
			}
		}()
	}

	// Let the schedule churn for a bit.
	time.Sleep(50 * time.Millisecond)
	stop.Store(true)
	wg.Wait()

	if swaps.Load() == 0 {
		t.Fatal("swapper never ran")
	}
	if reads.Load() == 0 {
		t.Fatal("readers never ran")
	}
	// We expect to have observed both states across the run; if not, the
	// swap was effectively single-threaded, which means we lost the race
	// we wanted to expose.
	if observedV1.Load() == 0 || observedV2.Load() == 0 {
		t.Logf("swaps=%d reads=%d v1=%d v2=%d — coverage warning, race not exercised",
			swaps.Load(), reads.Load(), observedV1.Load(), observedV2.Load())
	}
}

// TestCatalogIndependentInstances asserts the most basic property of the
// refactor: configuring instance A does not affect instance B. Pre-M3-8d
// this could not be expressed at all because the state was file-scoped.
func TestCatalogIndependentInstances(t *testing.T) {
	t.Parallel()

	rawA, publicKey := signedCatalogFixture(t, time.Now().UTC().Add(time.Hour), testHash)
	pathA := writeTempCatalog(t, rawA)

	a := NewCatalog()
	b := NewCatalog()

	cfgA := config.Default().Tier2
	cfgA.CatalogPath = pathA
	cfgA.CatalogPublicKey = publicKey
	if err := a.Configure(cfgA, zerolog.Nop()); err != nil {
		t.Fatalf("a Configure: %v", err)
	}

	if !a.Active() {
		t.Fatal("a not active")
	}
	if b.Active() {
		t.Fatal("b active without Configure")
	}
	if a.CatalogID() != "test-catalog" {
		t.Fatalf("a catalog_id=%q", a.CatalogID())
	}
	if b.CatalogID() != "" {
		t.Fatalf("b catalog_id leak=%q", b.CatalogID())
	}
	if got := a.VerifyProviderHash("model-a", testHash); got != pool.HashStatusVerified {
		t.Fatalf("a hash status=%q want %q", got, pool.HashStatusVerified)
	}
	if got := b.VerifyProviderHash("model-a", testHash); got != pool.HashStatusUncatalogued {
		t.Fatalf("b hash status=%q want %q", got, pool.HashStatusUncatalogued)
	}
}

// TestDefaultIsAtomicPointer asserts that Default() does not return nil even
// before any explicit Configure call, and that setDefault(nil) is rejected.
func TestDefaultIsAtomicPointer(t *testing.T) {
	prev := Default()
	defer setDefaultForTest(prev)

	if prev == nil {
		t.Fatal("Default() returned nil at package init")
	}
	setDefaultForTest(nil)
	if Default() != prev {
		t.Fatal("setDefault(nil) replaced the singleton")
	}
}

