package buyer

import (
	"crypto/sha256"
	"encoding/hex"

	"github.com/augstar/macprovider-coordinator/internal/billing"
	"github.com/augstar/macprovider-coordinator/internal/config"
)

// economicsSnapshot is the immutable pricing input of one request attempt,
// resolved in one economicsMu read hold.
type economicsSnapshot struct {
	rateEntry        billing.RateCardEntry
	multiplierPPM    int64
	providerShareBps int64
	snapshotID       int64
}

// economicsResolveHookForTest, when set, runs inside the economicsMu read
// hold between capturing the table and resolving the model. Production
// leaves it nil.
var economicsResolveHookForTest func()

// economicsSnapshotForModel resolves the pricing of model against the table
// in force: row, multiplier, share and the snapshot id that committed the
// table, all from one economicsMu read hold (SPEC-005-R013 I2). The recorder
// calls it before its write deadline starts, so waiting for a publication
// never eats the billing insert's budget. It takes only economicsMu and
// billingMu; callers must not hold the ws release read lock.
func (s *Server) economicsSnapshotForModel(model string) economicsSnapshot {
	s.economicsMu.RLock()
	defer s.economicsMu.RUnlock()
	_, cfg, snapshotID := s.billingState()
	if hook := economicsResolveHookForTest; hook != nil {
		hook()
	}
	return economicsSnapshot{
		rateEntry:        billing.RateFor(cfg.RateCard, model),
		multiplierPPM:    billing.ParseMultiplierPPM(cfg.GlobalMultiplier),
		providerShareBps: billing.ParseShareBps(cfg.ProviderShare),
		snapshotID:       snapshotID,
	}
}

// rateCardServeState is what /v1/rate-card(.sig) serve: the signed feed pair
// and, for the unsigned fallback, the table it is derived from.
type rateCardServeState struct {
	feeds   AutotuneFeeds
	rewards config.RewardsConfig
	usdPerM float64
}

// rateCardServeSnapshot captures the served card in one economicsMu read
// hold (then the feed and billing locks) and releases every lock before the
// caller rate-limits or writes the response, so a slow client can never delay
// a publication. The captured byte slices are never mutated after a publish
// swaps them in.
func (s *Server) rateCardServeSnapshot() rateCardServeState {
	s.economicsMu.RLock()
	defer s.economicsMu.RUnlock()
	feeds := s.autotuneFeedsSnapshot()
	rewards, usdPerM := s.recommendationRateCardState()
	return rateCardServeState{feeds: feeds, rewards: rewards, usdPerM: usdPerM}
}

// PublishEconomics publishes a reload's committed pricing table (cfg +
// snapshotID + usd peg) and, when feeds is non-nil, the served signed feeds
// in ONE economicsMu write hold, inside the SPEC-047 release publication the
// feeds observer runs. All fallible and I/O work (feed load, identity-set
// build, billing snapshot COMMIT) must be done before the call; the hold
// itself is pure in-memory assignment. With feeds nil only the table
// switches.
func (s *Server) PublishEconomics(cfg config.RewardsConfig, snapshotID int64, usdPerMillionCredits float64, feeds *AutotuneFeeds) {
	if feeds == nil {
		s.SetBillingConfig(cfg, snapshotID, usdPerMillionCredits)
		return
	}
	s.publishAutotuneFeeds(*feeds, func() {
		s.setBillingConfigLocked(cfg, snapshotID, usdPerMillionCredits)
	})
}

// AppliedEconomics is the pricing state a boot or reload left in force, as
// the applied-config record reports it.
type AppliedEconomics struct {
	RateTableSHA256      string
	SignedRateCardSHA256 string
	AutotuneReleaseID    string
	BillingSnapshotID    int64
}

// AppliedEconomics reads the table and served card in force through the same
// economicsMu read hold the request and rate-card paths use.
func (s *Server) AppliedEconomics() AppliedEconomics {
	s.economicsMu.RLock()
	defer s.economicsMu.RUnlock()
	_, cfg, snapshotID := s.billingState()
	feeds := s.autotuneFeedsSnapshot()
	out := AppliedEconomics{BillingSnapshotID: snapshotID}
	if digest, err := billing.RateTableDigest(cfg); err == nil {
		out.RateTableSHA256 = digest
	}
	if feeds.rateCardEnabled() {
		sum := sha256.Sum256(feeds.RateCardJSON)
		out.SignedRateCardSHA256 = hex.EncodeToString(sum[:])
	}
	if feeds.autotuneCandidatesEnabled() {
		out.AutotuneReleaseID = feeds.AutotuneCandidatesVerification.Version
	}
	return out
}
