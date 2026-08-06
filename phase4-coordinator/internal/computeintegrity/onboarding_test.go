package computeintegrity

import "testing"

// AC-7: onboarding gate.
func TestAC07_OnboardingGate(t *testing.T) {
	base := int64(1_000_000)
	spread := onboardingMinElapsedMs

	fivePasses := []int64{base, base + spread/4, base + spread/2, base + 3*spread/4, base + spread + 1}

	t.Run("5 passes over >=30 minutes verifies onboarding", func(t *testing.T) {
		s := NewStore()
		k := winKey("a", 1, "temp-0.7")
		r := s.EvaluateOnboarding(k, ModeEnforce, fivePasses)
		if r.Status != OnboardingVerified {
			t.Fatalf("want verified, got %s", r.Status)
		}
	})

	t.Run("fewer than 5 passes stays pending", func(t *testing.T) {
		s := NewStore()
		k := winKey("a", 1, "temp-0.7")
		r := s.EvaluateOnboarding(k, ModeEnforce, fivePasses[:3])
		if r.Status != OnboardingPending {
			t.Fatalf("want pending, got %s", r.Status)
		}
	})

	t.Run("5 passes within <30 minutes stays pending", func(t *testing.T) {
		s := NewStore()
		k := winKey("a", 1, "temp-0.7")
		quick := []int64{base, base + 1, base + 2, base + 3, base + 4}
		if r := s.EvaluateOnboarding(k, ModeEnforce, quick); r.Status != OnboardingPending {
			t.Fatalf("want pending for <30min, got %s", r.Status)
		}
	})

	t.Run("enforce blocks billable routing until onboarding verified", func(t *testing.T) {
		s := NewStore()
		k := winKey("a", 1, "temp-0.7")
		pending := s.EvaluateOnboarding(k, ModeEnforce, fivePasses[:2])
		if !OnboardingBlocksRouting(ModeEnforce, pending) {
			t.Fatal("enforce must block routing while onboarding pending")
		}
		verified := s.EvaluateOnboarding(k, ModeEnforce, fivePasses)
		if OnboardingBlocksRouting(ModeEnforce, verified) {
			t.Fatal("enforce must not block a verified onboarding")
		}
	})

	t.Run("warn_only does not block billable routing on onboarding", func(t *testing.T) {
		s := NewStore()
		k := winKey("a", 1, "temp-0.7")
		pending := s.EvaluateOnboarding(k, ModeWarnOnly, fivePasses[:1])
		if OnboardingBlocksRouting(ModeWarnOnly, pending) {
			t.Fatal("warn_only must not block routing on an onboarding verdict")
		}
	})

	t.Run("an active provider-attributable overlay still excludes the key regardless of mode", func(t *testing.T) {
		s := NewStore()
		k := winKey("a", 1, "temp-0.7")
		s.SetOverlayAdverse(k.Overlay(), StateQuarantinedDrift, OriginEnforcePreserved)
		r := s.EvaluateOnboarding(k, ModeWarnOnly, fivePasses)
		if r.InheritedOverlay != StateQuarantinedDrift {
			t.Fatalf("onboarding must inherit an active overlay, got %s", r.InheritedOverlay)
		}
		if !OnboardingBlocksRouting(ModeWarnOnly, r) {
			t.Fatal("inherited provider-attributable overlay must block even in warn_only")
		}
	})

	t.Run("onboarding never bypasses an active overlay quarantine", func(t *testing.T) {
		s := NewStore()
		k := winKey("a", 1, "temp-0.7")
		s.SetOverlayAdverse(k.Overlay(), StateQuarantinedDrift, OriginEnforcePreserved)
		r := s.EvaluateOnboarding(k, ModeEnforce, fivePasses) // even with 5 passes
		if r.Status == OnboardingVerified {
			t.Fatal("onboarding must not verify over an active overlay quarantine")
		}
	})
}
