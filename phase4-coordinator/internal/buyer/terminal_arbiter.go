package buyer

import (
	"sync"
	"sync/atomic"
	"time"

	"github.com/augstar/macprovider-coordinator/internal/billing"
	"github.com/rs/zerolog"
)

// terminal_arbiter.go — issue #766 (seam-hardening epic #770).
//
// WHAT THIS IS: a per-request CONSISTENCY arbiter. It publishes the single
// buyer-visible terminal (the first committed HTTP status) and every credited
// billing row, then asserts the two agree. It is OBSERVE-ONLY: package-level
// counters + warn logs, no enforcement, no suppression, no config surface.
//
// WHAT THIS IS NOT: a suppression arbiter. Suppressing a "late" billing row
// would UNDER-BILL every failover retry — the winning 200 row is written after
// the buyer terminal on the WS paths, and forward_loop_test.go scenario 2 pins
// the two-row (502, retried=0) + (200, retried=1) shape as the money contract.
// A suppressed provider credit is invisible and unrecoverable; an over-credit
// is detectable and reversible from the ledger. So: NEVER gate a billing row.
// Only the late BUYER terminal is telemetry-only, which is already true at the
// byte level (net/http discards a second WriteHeader).
//
// WHY IT IS NEEDED despite there being no goroutine race: recordRow and every
// buyer write run on the request goroutine, and the relay layer's
// timeout-vs-completion race is already single-winner arbitrated under
// activeMu (internal/ws/relay.go). The real gap H4 named is STRUCTURAL —
// nothing published "a buyer terminal was admitted", so recordRow could not
// observe whether the ledger and the buyer's HTTP status agreed. Today's
// no-charge-on-timeout property is an ACCIDENT of two independent zeroing
// rules (billing/formula.go FaultBreakerQualifying early-return and
// billing_recorder.go's byte-estimated zeroing); nothing asserts it. This file
// makes the disagreement observable so enforcement (if ever) can be designed
// against real counter data rather than a guess.
//
// Money-path rule encoded here: the buyer terminal wins the BUYER's refund
// decision (the gateway reads settlementNoPriorDispatchHeader, stamped at the
// same latch point); every attempt row is retained for the PROVIDER ledger.

// terminalSourceBuyerWrite is the only claim source today: the first
// buyer-visible write through noPriorDispatchResponseWriter. The field exists
// so a future claim site (e.g. a relay-side terminal) is distinguishable in
// the logs without changing the schema.
const terminalSourceBuyerWrite = "buyer_write"

// Package-level observe-only counters, mirroring the internal/ws/relay.go
// idiom (relayEndFrameAADMismatchTotal / relayBufferExceededTotal). Deliberately
// NOT prometheus: the buyer Server has no metrics handle, and plumbing one is
// out of scope for an observe-only change.
var (
	// buyerTerminalConflictTotal counts requests-events where the buyer's
	// committed HTTP status and a credited billing row disagreed.
	buyerTerminalConflictTotal atomic.Uint64
	// buyerTerminalLateTotal counts buyer writes that arrived after the
	// terminal was already claimed (telemetry-only; net/http drops them).
	buyerTerminalLateTotal atomic.Uint64
)

// terminalClaim is the winning buyer terminal for a request.
type terminalClaim struct {
	Status int
	Source string
	At     time.Time
	Seq    uint64
}

// billableRowEvent is one credited provider row as observed by the arbiter.
// Only rows that reached providerCredited=true are noted — a row that failed
// to persist never credited anyone and is not part of the agreement check.
type billableRowEvent struct {
	Status    int
	AttemptN  int
	FaultFlag string
	Seq       uint64
	// Late is true when the row was noted after the buyer terminal was
	// already claimed. This is NORMAL on the WS paths (write-before-bill)
	// and is recorded for ordering evidence, not as a fault.
	Late bool
	// Conflicted marks a row already counted against the conflict predicate,
	// so the end-of-request sweep does not double-count it.
	Conflicted bool
}

// requestTerminal is the per-request arbiter. One instance per
// billingRecorder, i.e. one per handleChatCompletions invocation. The mutex is
// belt-and-braces: all writers are on the request goroutine today, but the
// latch must stay correct if a future path publishes from a relay goroutine.
type requestTerminal struct {
	mu        sync.Mutex
	log       *zerolog.Logger
	requestID string
	accountID string

	seq          uint64
	buyer        *terminalClaim
	lateBuyer    int
	dispatched   bool
	rows         []billableRowEvent
	conflicts    int
	endEvaluated bool
}

func newRequestTerminal(log *zerolog.Logger, requestID, accountID string) *requestTerminal {
	return &requestTerminal{log: log, requestID: requestID, accountID: accountID}
}

// setRequestID follows the post-idempotency-reservation request-id rewrite so
// conflict logs join against the id the ledger actually used.
func (t *requestTerminal) setRequestID(requestID string) {
	if t == nil {
		return
	}
	t.mu.Lock()
	defer t.mu.Unlock()
	t.requestID = requestID
}

// claimBuyer latches the buyer-visible terminal. Returns true for the FIRST
// caller only; a later caller is recorded as a late (telemetry-only) write.
func (t *requestTerminal) claimBuyer(code int) bool {
	if t == nil {
		return false
	}
	t.mu.Lock()
	defer t.mu.Unlock()
	if t.buyer != nil {
		t.noteLateBuyerWriteLocked(code)
		return false
	}
	t.buyer = &terminalClaim{
		Status: code,
		Source: terminalSourceBuyerWrite,
		At:     time.Now().UTC(),
		Seq:    t.nextSeqLocked(),
	}
	return true
}

// noteLateBuyerWrite records a buyer write that lost the latch race.
func (t *requestTerminal) noteLateBuyerWrite(code int) {
	if t == nil {
		return
	}
	t.mu.Lock()
	defer t.mu.Unlock()
	t.noteLateBuyerWriteLocked(code)
}

func (t *requestTerminal) noteLateBuyerWriteLocked(code int) {
	t.lateBuyer++
	t.nextSeqLocked()
	buyerTerminalLateTotal.Add(1)
	winner := 0
	if t.buyer != nil {
		winner = t.buyer.Status
	}
	t.warnLocked().
		Str("event", "buyer_terminal_late").
		Int("buyer_status", winner).
		Int("row_status", 0).
		Int("attempt_n", -1).
		Str("fault_flag", "").
		Bool("late", true).
		Int("late_status", code).
		Int("late_writes", t.lateBuyer).
		Msg("buyer terminal already claimed; later write is telemetry-only")
}

// noteDispatch records that at least one attempt reached a provider relay.
// Monotonic for the whole request — deliberately NOT the per-attempt
// billingRecorder.dispatchedThisAttempt, which resets on every failover
// iteration and would make the end-of-request "served but unpaid" predicate
// fire spuriously on any request whose last attempt did not dispatch.
func (t *requestTerminal) noteDispatch() {
	if t == nil {
		return
	}
	t.mu.Lock()
	defer t.mu.Unlock()
	t.dispatched = true
}

// noteBillableRow publishes a durably-credited provider row. Called from
// recordRow immediately after providerCredited is set on BOTH credit sites.
func (t *requestTerminal) noteBillableRow(status, attemptN int, faultFlag string) {
	if t == nil {
		return
	}
	t.mu.Lock()
	defer t.mu.Unlock()
	row := billableRowEvent{
		Status:    status,
		AttemptN:  attemptN,
		FaultFlag: faultFlag,
		Seq:       t.nextSeqLocked(),
		Late:      t.buyer != nil,
	}
	t.rows = append(t.rows, row)
	idx := len(t.rows) - 1
	// Predicate I-1 can only be decided once the buyer terminal is known. On
	// the WS write-before-bill paths it already is; on the bill-before-write
	// paths the end-of-request sweep picks the row up.
	if t.buyer != nil && t.rowConflictsLocked(t.rows[idx]) {
		t.rows[idx].Conflicted = true
		t.recordConflictLocked(conflictCreditedWhileBuyerFailed, t.rows[idx])
	}
}

const (
	// conflictCreditedWhileBuyerFailed: the provider was paid for an attempt
	// the buyer was told failed with a 5xx, and the row carries no
	// breaker-qualifying fault flag (which is what billing/formula.go relies
	// on to zero the credit). This is the "paid while buyer told timeout"
	// property H4/INV-6 names.
	conflictCreditedWhileBuyerFailed = "credited_row_while_buyer_terminal_failed"
	// conflictServedWithoutCredit: the buyer got a 2xx off a dispatched
	// attempt but no provider row ever credited. The provider served and was
	// not paid.
	conflictServedWithoutCredit = "served_2xx_without_credited_row"
)

// rowConflictsLocked is predicate I-1. A credited row with a success-shaped
// status (<400) under a >=5xx buyer terminal is a conflict UNLESS the row is
// flagged breaker-qualifying — that flag is the existing (accidental, but
// real) zeroing rule in billing/formula.go, so such a row does not actually
// move money.
func (t *requestTerminal) rowConflictsLocked(row billableRowEvent) bool {
	if t.buyer == nil || t.buyer.Status < 500 {
		return false
	}
	if row.Status >= 400 {
		return false
	}
	return row.FaultFlag != billing.FaultBreakerQualifying
}

// evaluateEndOfRequest runs once, after handleChatCompletions has fully
// returned, so it sees the WS paths' post-write billing rows.
//
// billingEnabled gates the "served but unpaid" predicate: a coordinator with
// no billing store (or no request log) never credits anybody by design, and
// reporting every 200 as unpaid would be pure noise.
func (t *requestTerminal) evaluateEndOfRequest(billingEnabled bool) {
	if t == nil {
		return
	}
	t.mu.Lock()
	defer t.mu.Unlock()
	if t.endEvaluated {
		return
	}
	t.endEvaluated = true
	if t.buyer == nil {
		return
	}
	// I-1 sweep for rows credited BEFORE the buyer terminal was claimed
	// (HTTP paths bill before the write; the WS success path bills inside
	// logSuccess and can then fail the terminal with a 500).
	for i := range t.rows {
		if t.rows[i].Conflicted {
			continue
		}
		if t.rowConflictsLocked(t.rows[i]) {
			t.rows[i].Conflicted = true
			t.recordConflictLocked(conflictCreditedWhileBuyerFailed, t.rows[i])
		}
	}
	// I-2: served-but-unpaid. Evaluated once, at the end, against the
	// monotonic dispatch + credit signals.
	if !billingEnabled || !t.dispatched {
		return
	}
	if t.buyer.Status < 200 || t.buyer.Status >= 300 {
		return
	}
	// Audit R1 (code MEDIUM): the suppressor must be a row that actually PAYS,
	// not merely any recorded row — a zero-credit breaker-qualifying row from
	// a failed earlier attempt (which billing/formula.go zeroes) must not mask
	// a served-but-unpaid final attempt.
	for i := range t.rows {
		if t.rows[i].Status < 400 && t.rows[i].FaultFlag != billing.FaultBreakerQualifying {
			return
		}
	}
	t.recordConflictLocked(conflictServedWithoutCredit, billableRowEvent{AttemptN: -1})
}

func (t *requestTerminal) recordConflictLocked(reason string, row billableRowEvent) {
	t.conflicts++
	buyerTerminalConflictTotal.Add(1)
	buyerStatus := 0
	if t.buyer != nil {
		buyerStatus = t.buyer.Status
	}
	t.warnLocked().
		Str("event", "terminal_conflict").
		Str("reason", reason).
		Int("buyer_status", buyerStatus).
		Int("row_status", row.Status).
		Int("attempt_n", row.AttemptN).
		Str("fault_flag", row.FaultFlag).
		Bool("late", row.Late).
		Int("credited_rows", len(t.rows)).
		Msg("buyer terminal and billing rows disagree")
}

func (t *requestTerminal) nextSeqLocked() uint64 {
	t.seq++
	return t.seq
}

func (t *requestTerminal) warnLocked() *zerolog.Event {
	logger := t.log
	if logger == nil {
		nop := zerolog.Nop()
		logger = &nop
	}
	return logger.Warn().
		Str("request_id", t.requestID).
		Str("account_id", t.accountID)
}

// claimedBuyer returns the winning terminal claim, if any.
func (t *requestTerminal) claimedBuyer() (terminalClaim, bool) {
	if t == nil {
		return terminalClaim{}, false
	}
	t.mu.Lock()
	defer t.mu.Unlock()
	if t.buyer == nil {
		return terminalClaim{}, false
	}
	return *t.buyer, true
}

// Conflicts returns the number of buyer-terminal/billing-row disagreements.
func (t *requestTerminal) Conflicts() int {
	if t == nil {
		return 0
	}
	t.mu.Lock()
	defer t.mu.Unlock()
	return t.conflicts
}

// Rows returns a copy of the credited-row events, in observation order.
func (t *requestTerminal) Rows() []billableRowEvent {
	if t == nil {
		return nil
	}
	t.mu.Lock()
	defer t.mu.Unlock()
	return append([]billableRowEvent(nil), t.rows...)
}

// LateBuyerWrites returns the count of buyer writes that lost the latch.
func (t *requestTerminal) LateBuyerWrites() int {
	if t == nil {
		return 0
	}
	t.mu.Lock()
	defer t.mu.Unlock()
	return t.lateBuyer
}
