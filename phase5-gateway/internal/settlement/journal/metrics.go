package journal

import (
	"fmt"
	"sort"
	"strings"
	"sync"
)

// Recovery result labels for gateway_settlement_journal_recovered_total.
const (
	// RecoveredSettled — the re-drive settled the still-active reservation.
	RecoveredSettled = "settled"
	// RecoveredUsageEvent — the reservation was gone or terminal, so the
	// SPEC-006 § 17.7 fallback wrote the usage row instead.
	RecoveredUsageEvent = "usage_event"
	// RecoveredQuarantined — an unresolvable ErrUsageEventConflict.
	RecoveredQuarantined = "quarantined"
	// RecoveredRetry — a conflict that has not yet exhausted its attempts.
	RecoveredRetry = "retry"
	// RecoveredError — a transient failure; the effect stays unsealed and
	// is retried on the next pass.
	RecoveredError = "error"
)

var recoveredLabels = []string{
	RecoveredSettled,
	RecoveredUsageEvent,
	RecoveredQuarantined,
	RecoveredRetry,
	RecoveredError,
}

// Snapshot is a consistent copy of the journal counters, following the
// retry_metrics.go snapshot pattern (take the lock once, render outside it).
type Snapshot struct {
	Effects       int64
	Seals         int64
	Quarantines   int64
	WriteFailures int64
	Unsealed      int64
	Quarantined   int64
	Recovered     map[string]int64
	Bytes         int64
}

type metrics struct {
	mu            sync.Mutex
	effects       int64
	seals         int64
	quarantines   int64
	writeFailures int64
	unsealed      int64
	quarantined   int64
	recovered     map[string]int64
	bytes         int64
}

func (m *metrics) init() {
	m.mu.Lock()
	defer m.mu.Unlock()
	m.recovered = newRecoveredMap()
}

func newRecoveredMap() map[string]int64 {
	out := make(map[string]int64, len(recoveredLabels))
	for _, label := range recoveredLabels {
		out[label] = 0
	}
	return out
}

func (m *metrics) incEffects() {
	m.mu.Lock()
	m.effects++
	m.mu.Unlock()
}

func (m *metrics) incSeals() {
	m.mu.Lock()
	m.seals++
	m.mu.Unlock()
}

func (m *metrics) incQuarantines() {
	m.mu.Lock()
	m.quarantines++
	m.mu.Unlock()
}

func (m *metrics) incWriteFailures() {
	m.mu.Lock()
	m.writeFailures++
	m.mu.Unlock()
}

func (m *metrics) incRecovered(result string) {
	m.mu.Lock()
	defer m.mu.Unlock()
	if m.recovered == nil {
		m.recovered = newRecoveredMap()
	}
	if _, known := m.recovered[result]; !known {
		result = RecoveredError
	}
	m.recovered[result]++
}

func (m *metrics) setPending(unsealed, quarantined int64) {
	m.mu.Lock()
	m.unsealed = unsealed
	m.quarantined = quarantined
	m.mu.Unlock()
}

func (m *metrics) setBytes(bytes int64) {
	m.mu.Lock()
	m.bytes = bytes
	m.mu.Unlock()
}

func (m *metrics) snapshot() Snapshot {
	m.mu.Lock()
	defer m.mu.Unlock()
	recovered := newRecoveredMap()
	for label, count := range m.recovered {
		recovered[label] = count
	}
	return Snapshot{
		Effects:       m.effects,
		Seals:         m.seals,
		Quarantines:   m.quarantines,
		WriteFailures: m.writeFailures,
		Unsealed:      m.unsealed,
		Quarantined:   m.quarantined,
		Recovered:     recovered,
		Bytes:         m.bytes,
	}
}

// Prometheus renders the snapshot in the gateway's /metrics text format.
func (s Snapshot) Prometheus() string {
	var b strings.Builder
	b.WriteString("# HELP gateway_settlement_journal_effects_total Settlement effects durably journaled before the settle attempt.\n")
	b.WriteString("# TYPE gateway_settlement_journal_effects_total counter\n")
	fmt.Fprintf(&b, "gateway_settlement_journal_effects_total %d\n", s.Effects)
	b.WriteString("# HELP gateway_settlement_journal_seals_total Journaled effects sealed after reaching a durable terminal.\n")
	b.WriteString("# TYPE gateway_settlement_journal_seals_total counter\n")
	fmt.Fprintf(&b, "gateway_settlement_journal_seals_total %d\n", s.Seals)
	b.WriteString("# HELP gateway_settlement_journal_quarantines_total Journaled effects quarantined as unresolvable.\n")
	b.WriteString("# TYPE gateway_settlement_journal_quarantines_total counter\n")
	fmt.Fprintf(&b, "gateway_settlement_journal_quarantines_total %d\n", s.Quarantines)
	b.WriteString("# HELP gateway_settlement_journal_write_failures_total Journal record writes that failed (settlement continues fail-open).\n")
	b.WriteString("# TYPE gateway_settlement_journal_write_failures_total counter\n")
	fmt.Fprintf(&b, "gateway_settlement_journal_write_failures_total %d\n", s.WriteFailures)
	b.WriteString("# HELP gateway_settlement_journal_unsealed Unsealed settlement effects observed by the last recovery scan.\n")
	b.WriteString("# TYPE gateway_settlement_journal_unsealed gauge\n")
	fmt.Fprintf(&b, "gateway_settlement_journal_unsealed %d\n", s.Unsealed)
	b.WriteString("# HELP gateway_settlement_journal_quarantined Quarantined settlement effects awaiting operator reconciliation.\n")
	b.WriteString("# TYPE gateway_settlement_journal_quarantined gauge\n")
	fmt.Fprintf(&b, "gateway_settlement_journal_quarantined %d\n", s.Quarantined)
	b.WriteString("# HELP gateway_settlement_journal_recovered_total Settlement effects re-driven by the journal recovery pass.\n")
	b.WriteString("# TYPE gateway_settlement_journal_recovered_total counter\n")
	labels := make([]string, 0, len(s.Recovered))
	for label := range s.Recovered {
		labels = append(labels, label)
	}
	sort.Strings(labels)
	for _, label := range labels {
		fmt.Fprintf(&b, "gateway_settlement_journal_recovered_total{result=%q} %d\n", label, s.Recovered[label])
	}
	b.WriteString("# HELP gateway_settlement_journal_bytes Bytes currently held by settlement journal segments.\n")
	b.WriteString("# TYPE gateway_settlement_journal_bytes gauge\n")
	fmt.Fprintf(&b, "gateway_settlement_journal_bytes %d\n", s.Bytes)
	return b.String()
}
