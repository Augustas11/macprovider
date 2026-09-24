package buyer

import (
	"context"
	"testing"

	"github.com/augstar/macprovider-coordinator/internal/pool"
)

// Freeze audit R1 (#1690) SECURITY H1: a loopback runtime session is never
// eligible for paid global routing, whether or not the strict hello gate
// sandboxed it and whether or not it is bound to a BYOM candidate.
func TestLoopbackRuntimeNeverPaidGlobalRoutingEligible(t *testing.T) {
	s := &Server{}
	for _, source := range []string{"llamacpp_loopback", "ollama_loopback", "lmstudio_loopback", "openai_compatible_loopback"} {
		p := pool.Provider{ProviderID: "provider-a", RuntimeSource: source}
		if s.byomDefaultPaidRoutingEligibilityWithContext(context.Background(), p).eligible {
			t.Fatalf("%s session is paid-routing eligible", source)
		}
		p.ModelAdmissionCandidateID = "cand-1"
		if s.byomDefaultPaidRoutingEligibilityWithContext(context.Background(), p).eligible {
			t.Fatalf("%s bound session is paid-routing eligible", source)
		}
	}
	for _, source := range []string{"", "mlx_cache"} {
		if !s.byomDefaultPaidRoutingEligibilityWithContext(context.Background(), pool.Provider{ProviderID: "provider-a", RuntimeSource: source}).eligible {
			t.Fatalf("native session %q lost paid-routing eligibility", source)
		}
	}
}
