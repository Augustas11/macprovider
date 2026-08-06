package computeintegrity

import (
	"go/ast"
	"go/parser"
	"go/token"
	"os"
	"path/filepath"
	"strings"
	"testing"
)

// AC-6: compatibility. No compute-integrity fields are added to SPEC-015 v0.4 receipts
// or usage, and all three SPEC-036 workload classes create no buyer debit, provider
// credit, earnings, payout readiness, or uncapped reward accrual.
func TestAC06_Compatibility(t *testing.T) {
	t.Run("no SPEC-036 workload is billable or appears in SPEC-015 usage", func(t *testing.T) {
		for _, w := range []WorkloadClass{WorkloadProviderProbe, WorkloadReferenceForwardPass, WorkloadConsensusTelemetry} {
			if IsBillable(w) {
				t.Fatalf("workload %s must be non-billable", w)
			}
			if AppearsInSpec015Usage(w) {
				t.Fatalf("workload %s must not appear in SPEC-015 usage", w)
			}
		}
	})

	t.Run("any compensation uses a capped, anti-Sybil, non-buyer instrument", func(t *testing.T) {
		if ValidCompensationInstrument(CappedInstrument{PerProviderDailyCap: 10, AntiSybilEligible: true, BuyerFunded: true}) {
			t.Fatal("buyer-funded compensation must be rejected")
		}
		if ValidCompensationInstrument(CappedInstrument{PerProviderDailyCap: 10, AntiSybilEligible: true, UncappedRewardFunded: true}) {
			t.Fatal("uncapped-reward-funded compensation must be rejected")
		}
		if ValidCompensationInstrument(CappedInstrument{PerProviderDailyCap: 0, AntiSybilEligible: true}) {
			t.Fatal("an uncapped instrument must be rejected")
		}
		if !ValidCompensationInstrument(CappedInstrument{PerProviderDailyCap: 10, AntiSybilEligible: true}) {
			t.Fatal("a capped, anti-Sybil, operator-funded instrument should be valid")
		}
	})

	t.Run("the compute-integrity package defines no SPEC-015 receipt/usage fields", func(t *testing.T) {
		// The package is a self-contained coordinator-owned gate; it must not introduce
		// receipt/usage-bearing struct fields (which would live on the SPEC-015 receipt).
		// Assert no exported struct field name matches a receipt/usage prefix.
		fset := token.NewFileSet()
		forbidden := []string{"receipt", "usage", "billable", "buyer_debit", "provider_credit"}
		files, _ := filepath.Glob("*.go")
		for _, f := range files {
			if strings.HasSuffix(f, "_test.go") {
				continue
			}
			src, err := os.ReadFile(f)
			if err != nil {
				t.Fatal(err)
			}
			node, err := parser.ParseFile(fset, f, src, 0)
			if err != nil {
				t.Fatal(err)
			}
			ast.Inspect(node, func(n ast.Node) bool {
				st, ok := n.(*ast.StructType)
				if !ok {
					return true
				}
				for _, field := range st.Fields.List {
					for _, name := range field.Names {
						lc := strings.ToLower(name.Name)
						for _, p := range forbidden {
							// Allow settlement-outcome fields that reference SPEC-022 (e.g.
							// spec022*) but forbid receipt/usage-bearing field names.
							if strings.Contains(lc, strings.ReplaceAll(p, "_", "")) &&
								!strings.HasPrefix(lc, "spec022") {
								t.Errorf("%s: field %q looks like a SPEC-015 receipt/usage field", f, name.Name)
							}
						}
					}
				}
				return true
			})
		}
	})
}
