package payout_test

import (
	"go/build"
	"strings"
	"testing"
)

// TestImportGraph_BillingDoesNotImportPayout enforces SPEC-016
// §4.1: billing/ MUST NOT import payout/. The IMPL audit prompt
// pins this as an explicit verification item (Step 1 audit
// surface (e)).
//
// payout/ → billing/ is permitted (one-way) — see future Step 2
// ClaimPayoutReady call site.
func TestImportGraph_BillingDoesNotImportPayout(t *testing.T) {
	pkg, err := build.Default.Import(
		"github.com/augstar/macprovider-coordinator/internal/billing",
		"", 0,
	)
	if err != nil {
		t.Fatalf("import billing: %v", err)
	}
	deps := allImports(pkg)
	if contains(deps, "github.com/augstar/macprovider-coordinator/internal/payout") {
		t.Fatalf("internal/billing transitively imports internal/payout — SPEC-016 §4.1 boundary violated")
	}
}

func allImports(pkg *build.Package) []string {
	out := make([]string, 0, len(pkg.Imports)+len(pkg.TestImports))
	out = append(out, pkg.Imports...)
	out = append(out, pkg.TestImports...)
	return out
}

func contains(slice []string, needle string) bool {
	for _, s := range slice {
		if s == needle || strings.HasPrefix(s, needle+"/") {
			return true
		}
	}
	return false
}
