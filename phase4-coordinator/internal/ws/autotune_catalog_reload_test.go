package ws

import (
	"fmt"
	"sync"
	"testing"

	"github.com/augstar/macprovider-coordinator/internal/autotune"
	"github.com/augstar/macprovider-coordinator/internal/pool"
	"github.com/rs/zerolog"
)

// reloadTestCatalog builds a minimal valid autotune catalog with a caller-chosen
// version so a test can distinguish the active vs. previous release across a
// SetAutotuneCatalog swap.
func reloadTestCatalog(t *testing.T, version string) *autotune.Catalog {
	t.Helper()
	return reloadTestCatalogSHA(t, version, "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa")
}

// reloadTestCatalogSHA builds a minimal valid catalog with a caller-chosen
// version AND model sha so a test can prove which catalog generation an
// admission helper evaluated against.
func reloadTestCatalogSHA(t *testing.T, version, modelSHA string) *autotune.Catalog {
	t.Helper()
	catalog, err := autotune.ParseCatalog([]byte(fmt.Sprintf(`{
		"version":%q,
		"policy_version":"test",
		"source":"operator_curated_autotune_candidate_catalog",
		"rows":{
				"small":{"model_id":"small-model","model_sha256":%q,"min_ram_gb":8,"min_bandwidth_tier":"low","bench_gate":{"min_sustained_tps":1,"max_4k_ttft_ms":1000},"runtime_status":"recommended"}
			}
		}`, version, modelSHA)))
	if err != nil {
		t.Fatalf("parse catalog %q: %v", version, err)
	}
	return catalog
}

// TestSetAutotuneCatalogHotSwap verifies the #1268 SIGHUP swap: the active
// catalog is replaced and the prior release is retained as a compatible
// ("previous"-mode) catalog, with the same dedup rules as construction.
func TestSetAutotuneCatalogHotSwap(t *testing.T) {
	t.Parallel()
	v1 := reloadTestCatalog(t, "cat-v1")
	server := NewServer(admissionCeilingEnforcementConfig(), pool.NewRegistry(nil), zerolog.Nop(),
		WithAutotuneCatalog(v1),
	)

	if got := server.currentAutotuneCatalog(); got == nil || got.Version != "cat-v1" {
		t.Fatalf("initial current = %v, want cat-v1", got)
	}
	if _, compat := server.autotuneCatalogSnapshot(); len(compat) != 0 {
		t.Fatalf("initial compatible = %v, want empty", compat)
	}

	// Swap to a fresh active release, retaining the prior as the compatible set.
	v2 := reloadTestCatalog(t, "cat-v2")
	server.SetAutotuneCatalog(v2, v1)

	cur, compat := server.autotuneCatalogSnapshot()
	if cur == nil || cur.Version != "cat-v2" {
		t.Fatalf("post-swap current = %v, want cat-v2", cur)
	}
	if compat["cat-v1"] == nil {
		t.Fatalf("post-swap compatible = %v, want cat-v1 retained", compat)
	}

	// Dedup: a compatible entry equal to the active version must be dropped, and
	// a permanently-rejected id must never be admitted as compatible.
	server.SetAutotuneCatalog(v2, v2)
	if _, compat := server.autotuneCatalogSnapshot(); len(compat) != 0 {
		t.Fatalf("same-version compatible not deduped: %v", compat)
	}
}

// TestResolveProviderCatalogSurvivesSwap locks in the #1268 HIGH-1 fix: an
// already-admitted session admitted under catalog A as "current" must keep
// resolving to A after a SIGHUP re-stamp swaps in B (retaining A as compatible
// previous), instead of resolving to the new active catalog B and failing its
// evidence/hash. The stored current/previous mode label is deliberately left
// stale, exactly as it would be for a live session.
func TestResolveProviderCatalogSurvivesSwap(t *testing.T) {
	t.Parallel()
	a := reloadTestCatalog(t, "cat-A")
	b := reloadTestCatalog(t, "cat-B")
	server := NewServer(admissionCeilingEnforcementConfig(), pool.NewRegistry(nil), zerolog.Nop(),
		WithAutotuneCatalog(a),
	)
	// A session admitted while A was active: mode "current", release id A.
	session := pool.Provider{
		ProviderID:           "p1",
		AssignedID:           "s1",
		CatalogAdmissionMode: "current",
		CatalogReleaseID:     a.Version,
	}

	resolved, _, isCurrent, ok := server.resolveProviderCatalog(session)
	if !ok || resolved == nil || resolved.Version != "cat-A" || !isCurrent {
		t.Fatalf("pre-swap resolve = (%v, isCurrent=%v, ok=%v), want cat-A/current", resolved, isCurrent, ok)
	}

	// Operator re-stamps: B is the new active catalog, A retained as previous.
	// The live session's stored mode ("current") is now stale.
	server.SetAutotuneCatalog(b, a)

	resolved, current, isCurrent, ok := server.resolveProviderCatalog(session)
	if !ok || resolved == nil || resolved.Version != "cat-A" {
		t.Fatalf("post-swap resolve = %v, want the session's own release cat-A (not the new active cat-B)", resolved)
	}
	if isCurrent {
		t.Fatalf("post-swap session must resolve as a previous release, not current")
	}
	if current == nil || current.Version != "cat-B" {
		t.Fatalf("post-swap active catalog = %v, want cat-B", current)
	}
	// autotuneCatalogForProvider (used by the trust revalidation sweep) must
	// return A, not nil — otherwise the sweep marks the session evidence-stale.
	if got := server.autotuneCatalogForProvider(session); got == nil || got.Version != "cat-A" {
		t.Fatalf("autotuneCatalogForProvider post-swap = %v, want cat-A", got)
	}
}

// TestAdmissionHelpersPinPassedCatalogGeneration locks in the #1268 MED-2 fix:
// the *WithCatalog admission helpers must evaluate against the catalog
// generation the caller pins, not a fresh live snapshot. prepareProviderAdmission
// takes ONE snapshot and threads it through catalogAdmission, the expected model
// hash, and the hello gate, so a SIGHUP swap between those reads cannot classify
// a hello against one generation and hash it against another.
func TestAdmissionHelpersPinPassedCatalogGeneration(t *testing.T) {
	t.Parallel()
	const shaA = "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
	const shaB = "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"
	a := reloadTestCatalogSHA(t, "cat-A", shaA)
	b := reloadTestCatalogSHA(t, "cat-B", shaB)
	server := NewServer(admissionCeilingEnforcementConfig(), pool.NewRegistry(nil), zerolog.Nop(),
		WithAutotuneCatalog(a),
	)
	hello := Hello{ModelID: "small-model"}

	// Pin generation A, then SIGHUP-swap the live catalog to B mid-admission.
	pinnedCurrent, pinnedCompatible := server.autotuneCatalogSnapshot()
	server.SetAutotuneCatalog(b)

	// The pinned-generation helper still answers against A...
	if got := server.expectedAdmissionModelHashWithCatalog(hello, "current", pinnedCurrent, pinnedCompatible); got != shaA {
		t.Fatalf("pinned expected hash = %q, want cat-A sha %q (must not follow the live swap)", got, shaA)
	}
	// ...while the snapshot-taking wrapper now sees the swapped-in B, proving the
	// wrapper re-snapshots and the *WithCatalog seam is what pins the generation.
	if got := server.expectedAdmissionModelHash(hello, "current"); got != shaB {
		t.Fatalf("live expected hash = %q, want swapped-in cat-B sha %q", got, shaB)
	}
}

// TestSetAutotuneCatalogConcurrentReadSwap exercises the getter/setter under the
// race detector: concurrent admission-path reads must never observe a torn
// (current, compatible) pair while a SIGHUP swap runs. Run with `-race`.
func TestSetAutotuneCatalogConcurrentReadSwap(t *testing.T) {
	t.Parallel()
	v1 := reloadTestCatalog(t, "cat-v1")
	server := NewServer(admissionCeilingEnforcementConfig(), pool.NewRegistry(nil), zerolog.Nop(),
		WithAutotuneCatalog(v1),
	)
	v2 := reloadTestCatalog(t, "cat-v2")

	var wg sync.WaitGroup
	const readers = 8
	const iterations = 500
	stop := make(chan struct{})

	for i := 0; i < readers; i++ {
		wg.Add(1)
		go func() {
			defer wg.Done()
			for {
				select {
				case <-stop:
					return
				default:
				}
				cur, compat := server.autotuneCatalogSnapshot()
				if cur == nil {
					t.Errorf("snapshot returned nil active catalog during swap")
					return
				}
				// Reading the compatible map concurrently must be safe because
				// SetAutotuneCatalog replaces it wholesale, never mutates it.
				_ = compat[cur.Version]
				_ = server.currentAutotuneCatalog()
			}
		}()
	}

	wg.Add(1)
	go func() {
		defer wg.Done()
		for i := 0; i < iterations; i++ {
			if i%2 == 0 {
				server.SetAutotuneCatalog(v2, v1)
			} else {
				server.SetAutotuneCatalog(v1, v2)
			}
		}
		close(stop)
	}()

	wg.Wait()
}
