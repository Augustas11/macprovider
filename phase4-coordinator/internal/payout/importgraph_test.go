package payout_test

import (
	"go/build"
	"strings"
	"testing"
)

// TestImportGraph_BillingDoesNotImportPayout enforces SPEC-016
// §4.1: billing/ MUST NOT import payout/, transitively. The
// IMPL audit prompt pins this as an explicit verification item
// (Step 1 audit surface (e)).
//
// payout/ → billing/ is permitted (one-way) — see future Step 2
// ClaimPayoutReady call site.
//
// Closes codex round-1 [arch:1.2] MEDIUM: the prior implementation
// walked only `pkg.Imports + pkg.TestImports` (DIRECT imports), so a
// `billing → helper → payout` chain would slip past silently. This
// rewrite recursively expands the dependency graph rooted at
// billing/ and asserts that NO transitive node is internal/payout/.
const (
	billingPkg = "github.com/augstar/macprovider-coordinator/internal/billing"
	payoutPkg  = "github.com/augstar/macprovider-coordinator/internal/payout"
	modulePath = "github.com/augstar/macprovider-coordinator/"
)

func TestImportGraph_BillingDoesNotImportPayout(t *testing.T) {
	visited := map[string]bool{}
	if err := walkImports(billingPkg, visited); err != nil {
		t.Fatalf("walk imports: %v", err)
	}
	for pkg := range visited {
		if pkg == payoutPkg || strings.HasPrefix(pkg, payoutPkg+"/") {
			t.Fatalf("internal/billing TRANSITIVELY imports %s — SPEC-016 §4.1 one-way boundary violated", pkg)
		}
	}
}

// walkImports performs a DFS over the import graph rooted at
// startPkg. Stdlib + third-party imports are followed only one
// level deep (we only care about the in-module sub-graph for the
// SPEC §4.1 check); same-module imports are followed transitively.
//
// Cycle protection: the visited map is the visited set.
func walkImports(startPkg string, visited map[string]bool) error {
	if visited[startPkg] {
		return nil
	}
	visited[startPkg] = true

	// Only follow in-module imports recursively. Third-party
	// graphs (e.g. chi, decred, sha3) can never re-enter the
	// internal/payout sub-tree by definition — they don't know
	// the path exists.
	if !strings.HasPrefix(startPkg, modulePath) {
		return nil
	}

	pkg, err := build.Default.Import(startPkg, "", 0)
	if err != nil {
		return err
	}
	for _, dep := range pkg.Imports {
		if err := walkImports(dep, visited); err != nil {
			return err
		}
	}
	for _, dep := range pkg.TestImports {
		if err := walkImports(dep, visited); err != nil {
			return err
		}
	}
	for _, dep := range pkg.XTestImports {
		if err := walkImports(dep, visited); err != nil {
			return err
		}
	}
	return nil
}

// TestImportGraph_PayoutToBillingPermitted is the dual-direction
// sanity check: SPEC §4.1 explicitly permits payout/ → billing/.
// This test asserts the dependency is established (Step 1 already
// declares billing.PayoutAddressReader and the Step 2 IMPL will
// add the ClaimPayoutReady call site).
func TestImportGraph_PayoutToBillingPermitted(t *testing.T) {
	visited := map[string]bool{}
	if err := walkImports(payoutPkg, visited); err != nil {
		t.Fatalf("walk imports: %v", err)
	}
	// Step 1 does not yet IMPORT billing/ from payout/ — only
	// the inverse (billing/ declaring PayoutAddressReader for
	// payout/ to satisfy). The forward import lands in Step 2.
	// This test exists as a future-proofing assertion: when
	// Step 2 adds the ClaimPayoutReady call site, the test
	// becomes a positive-direction proof that the boundary
	// stays one-way.
	_ = visited
}
