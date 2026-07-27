package router

import (
	"sync"
	"time"

	"github.com/augstar/macprovider-gateway/internal/settlement/journal"
)

// SettlementJournal is the router-local view of the durable settlement
// journal (issue #763 / seam finding P1-2), in the same spirit as Store and
// ReadStore: the router depends on the narrow behavior it needs, and
// cmd/gateway supplies the real *journal.Journal.
//
// The journal is what makes an after-commit settlement recoverable. The
// effect record is on stable storage BEFORE the settle attempt, so a settle
// that fails logically, crashes the process, or loses power still leaves a
// re-drivable record — the case the H7 tripwire used to certify as a
// permanent loss.
type SettlementJournal interface {
	WriteEffect(rec journal.Record) error
	WriteSeal(key journal.Key, result string) error
	WriteQuarantine(key journal.Key, reason string, attempts int) error
	Scan() (journal.ScanResult, error)
	Prune(before time.Time) (int, error)
	RecordRecovered(result string)
	SetPending(unsealed, quarantined int64)
	MetricsSnapshot() journal.Snapshot
}

// discardSettlementJournal is the no-op journal New falls back to when no
// journal is registered (unit tests, `gateway -check`). It is deliberately a
// silent no-op rather than an error: the settle path must never fail because
// journaling is unavailable. Production cannot reach it — cmd/gateway always
// passes a real journal and exits if it cannot open one, config.Validate
// requires settlement.journal_enabled, and TestGatewayRouterCarriesSettlementJournal
// pins the wiring.
type discardSettlementJournal struct{}

func (discardSettlementJournal) WriteEffect(journal.Record) error    { return nil }
func (discardSettlementJournal) WriteSeal(journal.Key, string) error { return nil }
func (discardSettlementJournal) WriteQuarantine(journal.Key, string, int) error {
	return nil
}
func (discardSettlementJournal) Scan() (journal.ScanResult, error) { return journal.ScanResult{}, nil }
func (discardSettlementJournal) Prune(time.Time) (int, error)      { return 0, nil }
func (discardSettlementJournal) RecordRecovered(string)            {}
func (discardSettlementJournal) SetPending(int64, int64)           {}
func (discardSettlementJournal) MetricsSnapshot() journal.Snapshot {
	return journal.Snapshot{}
}

// WithSettlementJournal registers the durable settlement journal.
func WithSettlementJournal(j SettlementJournal) Option {
	return func(s *Server) {
		if j != nil {
			s.journal = j
		}
	}
}

// settlementJournalAttempts counts conflicted re-drive attempts per effect
// key. It is process-local on purpose: the counter only decides WHEN a
// permanently-conflicted effect is quarantined, and a restart that resets it
// merely delays the quarantine — it can never cause a double bill, because
// every re-drive goes through the idempotent EnsureUsageEvent verify.
type settlementJournalAttempts struct {
	mu     sync.Mutex
	counts map[journal.Key]int
}

func newSettlementJournalAttempts() *settlementJournalAttempts {
	return &settlementJournalAttempts{counts: map[journal.Key]int{}}
}

func (a *settlementJournalAttempts) next(key journal.Key) int {
	if a == nil {
		return 1
	}
	a.mu.Lock()
	defer a.mu.Unlock()
	a.counts[key]++
	return a.counts[key]
}

func (a *settlementJournalAttempts) clear(key journal.Key) {
	if a == nil {
		return
	}
	a.mu.Lock()
	defer a.mu.Unlock()
	delete(a.counts, key)
}
