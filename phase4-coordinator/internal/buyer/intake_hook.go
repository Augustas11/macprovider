package buyer

import (
	"strings"

	"github.com/augstar/macprovider-coordinator/internal/billing"
)

// IntakeObserver receives buyer requests whose model string resolved to no
// admitted catalog key (SPEC-017 v0.2.1 §5.2b.2 step S1). The coordinator's
// SPEC-023 §16.2(a) aggregator implements it; the buyer surface alone
// decides eligibility — authenticated account, not a demo subject, not an
// operator-excluded account, normalized key matching no listed or
// recommendable catalog row — and hands over the raw requested string and
// the authenticated account id, retaining neither.
type IntakeObserver interface {
	Observe(rawModel, accountID string)
}

// WithIntakeObserver wires the SPEC-023 §16.2(a) unmatched-model aggregator.
func WithIntakeObserver(observer IntakeObserver) Option {
	return func(s *Server) {
		s.intakeObserver = observer
	}
}

// WithIntakeExcludedAccounts flags the operator's test, synthetic, and
// internal buyer accounts (SPEC-017 §5.2b.2 item 4). The set lives at this
// boundary only; the aggregator never receives an account identifier.
func WithIntakeExcludedAccounts(accounts []string) Option {
	return func(s *Server) {
		s.intakeExcluded = make(map[string]struct{}, len(accounts))
		for _, id := range accounts {
			if id = strings.TrimSpace(id); id != "" {
				s.intakeExcluded[id] = struct{}{}
			}
		}
	}
}

// demoAccountPrefix marks SPEC-006 demo subjects ("demo:<ip>"); they are
// never intake-eligible (SPEC-017 §5.2b.2 item 2).
const demoAccountPrefix = "demo:"

// intakeUnmatchedCatalogKey reports whether the requested model string
// normalizes onto NO listed or recommendable catalog row of the current
// admitted release — independent of provider advertisement, rate-class
// resolution, or routing outcome (SPEC-017 §5.2b.2 item 5). Without an
// admitted catalog to decide against (feed not loaded) nothing is
// unmatched: the hook fails closed and contributes nothing.
func (s *Server) intakeUnmatchedCatalogKey(rawModel string) bool {
	statuses := s.autotuneFeedsSnapshot().CandidateRowStatuses
	if len(statuses) == 0 {
		return false
	}
	status, ok := statuses[billing.NormalizeModelKey(rawModel)]
	return !ok || (status != "listed" && status != "recommendable")
}

// observeUnmatchedModel applies SPEC-017 §5.2b.2 items 1–4 for one request
// that reached model resolution. A panic inside the aggregator is recovered
// here: intake is stats-owned code on the money path and MUST NOT fail or
// alter the buyer request (SPEC-017 §4.2).
func (s *Server) observeUnmatchedModel(rawModel, accountID string, authenticated bool) {
	if s.intakeObserver == nil || !authenticated {
		return
	}
	// The recover covers the ENTIRE hook body — catalog resolution and the
	// exclusion checks as well as Observe — so no part of the intake path
	// can fail or alter the buyer request (SPEC-017 §5.2b.2). The panic
	// value is never logged: it could carry the request's model or account.
	defer func() {
		if recover() != nil {
			s.log.Warn().Msg("intake hook panicked; request unaffected")
		}
	}()
	accountID = strings.TrimSpace(accountID)
	if accountID == "" || strings.HasPrefix(accountID, demoAccountPrefix) {
		return
	}
	if _, excluded := s.intakeExcluded[accountID]; excluded {
		return
	}
	if !s.intakeUnmatchedCatalogKey(rawModel) {
		return
	}
	s.intakeObserver.Observe(rawModel, accountID)
}
