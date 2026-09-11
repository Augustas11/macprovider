package buyer

import "strings"

// IntakeObserver receives buyer requests whose model string resolved to no
// admitted catalog key (SPEC-017 v0.2.1 §5.2b.2 step S1). The coordinator's
// SPEC-023 §16.2(a) aggregator implements it; the buyer surface only
// decides eligibility and hands over the raw requested string and the
// authenticated account id, retaining neither.
type IntakeObserver interface {
	Observe(rawModel, accountID string)
}

// WithIntakeObserver wires the SPEC-023 §16.2(a) unmatched-model aggregator.
func WithIntakeObserver(observer IntakeObserver) Option {
	return func(s *Server) {
		s.intakeObserver = observer
	}
}

// demoAccountPrefix marks SPEC-006 demo subjects ("demo:<ip>"); they are
// never intake-eligible (SPEC-017 §5.2b.2 item 2).
const demoAccountPrefix = "demo:"

// observeUnmatchedModel applies SPEC-017 §5.2b.2 items 1–3 at the
// model_not_found rejection: only a request carrying an authenticated
// account (direct buyer-key authentication or a gateway-service-bearer
// authenticated account assertion — both land in the request context as
// the authenticated account) that is not a demo subject reaches the
// aggregator. Item 4 (the operator's excluded-account set) is applied by
// the aggregator itself.
func (s *Server) observeUnmatchedModel(rawModel, accountID string, authenticated bool) {
	if s.intakeObserver == nil || !authenticated {
		return
	}
	accountID = strings.TrimSpace(accountID)
	if accountID == "" || strings.HasPrefix(accountID, demoAccountPrefix) {
		return
	}
	s.intakeObserver.Observe(rawModel, accountID)
}
