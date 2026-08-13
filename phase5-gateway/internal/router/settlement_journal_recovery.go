package router

import (
	"context"
	"errors"
	"log/slog"
	"time"

	"github.com/augstar/macprovider-gateway/internal/settlement/journal"
	"github.com/augstar/macprovider-gateway/internal/storage"
)

// Settlement-journal recovery (issue #763 / seam finding P1-2).
//
// The journal's effect records are only worth writing if something re-drives
// them. This is that something. It mirrors the SPEC-022 reconciler
// (settlement_reconcile.go) in shape — a bounded, idempotent pass exposed as
// a method so cmd/gateway can run it once at startup and then on a ticker —
// but it is deliberately a SEPARATE loop with its own knobs. The SPEC-022
// reconciler only ever sees reservations that are still active with
// settlement_hold=1; the effects this pass recovers are precisely the ones
// that are invisible to it (already refunded, or with a reservation row that
// is gone).
//
// STARTUP IS NOT ENOUGH. The failure that motivated the journal (H7) is a
// LOGICAL double failure inside a running process, not a crash: nothing would
// ever restart the gateway to trigger a startup-only scan. Hence the periodic
// loop.

const (
	defaultSettlementJournalRecoveryLimit = 100
	maxSettlementJournalRecoveryLimit     = 500
	walletSessionClaimRecoveryMinAge      = 30 * time.Second
	// settlementJournalMaxConflictAttempts bounds how many passes an
	// ErrUsageEventConflict effect is retried before it is quarantined.
	// A conflict means the durable row disagrees with the journaled payload,
	// which no amount of retrying resolves; the counter exists so a
	// transient-looking conflict is not quarantined on its first sighting.
	settlementJournalMaxConflictAttempts = 10
)

// SettlementJournalRecoverySummary reports one recovery pass.
type SettlementJournalRecoverySummary struct {
	// Scanned counts effects the pass attempted to re-drive.
	Scanned int `json:"scanned"`
	// Recovered counts effects that reached a durable terminal in this pass
	// (settled + usage_event).
	Recovered   int `json:"recovered"`
	Settled     int `json:"settled"`
	UsageEvents int `json:"usage_events"`
	Quarantined int `json:"quarantined"`
	// Skipped counts effects held back by the grace window.
	Skipped int `json:"skipped"`
	// Retried counts conflicted effects left for a later pass.
	Retried int `json:"retried"`
	Errors  int `json:"errors"`
	Pruned  int `json:"pruned"`
	// DispatchHeld counts wallet-session dispatch arms whose buyer response
	// never reached a durable settlement effect before the grace window.
	DispatchHeld int64 `json:"dispatch_held"`
	// ClaimsRefunded counts wallet-session reservations that never armed
	// dispatch before their stale-claim recovery window elapsed.
	ClaimsRefunded int64 `json:"claims_refunded"`
	// Malformed and Unsealed describe the journal as scanned, before the
	// pass ran.
	Malformed int `json:"malformed"`
	Unsealed  int `json:"unsealed"`
}

// RecoverSettlementJournal re-drives unsealed settlement effects.
//
// It is idempotent by construction: every ladder rung is an idempotent store
// call keyed by (account_id, request_id), so running it twice — or racing it
// against the SPEC-022 reconciler — cannot bill twice. A second pass over an
// already-recovered journal recovers nothing.
func (s *Server) RecoverSettlementJournal(ctx context.Context, limit int) (SettlementJournalRecoverySummary, error) {
	if limit <= 0 {
		limit = defaultSettlementJournalRecoveryLimit
	}
	if limit > maxSettlementJournalRecoveryLimit {
		limit = maxSettlementJournalRecoveryLimit
	}
	scan, err := s.journal.Scan()
	if err != nil {
		return SettlementJournalRecoverySummary{}, err
	}
	summary := SettlementJournalRecoverySummary{
		Malformed: scan.Malformed,
		Unsealed:  len(scan.Unsealed),
	}
	s.journal.SetPending(int64(len(scan.Unsealed)), int64(scan.Quarantined))

	now := s.now().UTC()
	grace := time.Duration(s.cfg.Settlement.JournalRecoveryGraceSeconds) * time.Second
	for _, rec := range scan.Unsealed {
		if summary.Scanned >= limit {
			break
		}
		if ctx.Err() != nil {
			break
		}
		// GRACE WINDOW: an effect written moments ago is probably still in
		// flight on its request goroutine — the arm happens BEFORE the
		// settle. Re-driving it there would race the live settle for the
		// same reservation. Waiting costs nothing: the effect is durable.
		if grace > 0 && now.Sub(rec.WrittenAt()) < grace {
			summary.Skipped++
			continue
		}
		summary.Scanned++
		result, err := s.redriveSettlementEffect(ctx, rec)
		if err != nil {
			summary.Errors++
			s.journal.RecordRecovered(journal.RecoveredError)
			slog.Error("gateway settlement journal re-drive failed; effect stays unsealed for the next pass",
				"account_id", rec.AccountID,
				"request_id", rec.RequestID,
				"effect", rec.Effect,
				"error", err,
			)
			continue
		}
		s.journal.RecordRecovered(result)
		switch result {
		case journal.RecoveredSettled:
			summary.Settled++
			summary.Recovered++
		case journal.RecoveredUsageEvent:
			summary.UsageEvents++
			summary.Recovered++
		case journal.RecoveredQuarantined:
			summary.Quarantined++
		case journal.RecoveredRetry:
			summary.Retried++
		}
	}
	if held, err := s.store.HoldStaleWalletSessionDispatchArms(ctx, now.Add(-grace), now); err != nil {
		summary.Errors++
		slog.Error("gateway wallet-session stale dispatch-arm recovery failed", "error", err)
		s.recordWalletSessionAudit(ctx, "", "", "wallet_session_settlement_reconcile_failed", "gateway", map[string]any{
			"phase": "dispatch_arm_recovery",
			"error": safeAuditError(err),
		})
	} else {
		summary.DispatchHeld = held
	}
	claimGrace := grace
	if claimGrace < walletSessionClaimRecoveryMinAge {
		claimGrace = walletSessionClaimRecoveryMinAge
	}
	if refunded, err := s.store.RefundStaleWalletSessionClaims(ctx, now.Add(-claimGrace), now); err != nil {
		summary.Errors++
		slog.Error("gateway wallet-session stale claim recovery failed", "error", err)
		s.recordWalletSessionAudit(ctx, "", "", "wallet_session_settlement_reconcile_failed", "gateway", map[string]any{
			"phase": "claim_recovery",
			"error": safeAuditError(err),
		})
	} else {
		summary.ClaimsRefunded = refunded
	}

	if retention := time.Duration(s.cfg.Settlement.JournalRetentionHours) * time.Hour; retention > 0 {
		pruned, err := s.journal.Prune(now.Add(-retention))
		if err != nil {
			slog.Warn("gateway settlement journal prune failed", "error", err)
		}
		summary.Pruned = pruned
	}
	return summary, nil
}

// redriveSettlementEffect replays one journaled effect through the SAME
// ladder settleAfterCommit uses, in the same order:
//
//	SettleReservation (or SettleDemoReservation)      → seal "settled"
//	  ↳ reservation missing/terminal:
//	     EnsureUsageEvent (+EnsureDemoUsageEvent)
//	     then RefundReservation (no-op when terminal)  → seal "usage_event"
//	       ↳ ErrUsageEventConflict: NO seal, quarantine after N attempts
//
// The payload comes verbatim from the journal, which is why the effect record
// must carry every field EnsureUsageEvent's verify compares (created_at
// excluded): a re-drive of an effect whose settle ALREADY landed must match
// the existing row and return nil, not conflict. That is the no-double-bill
// proof (TestSettlementJournal_SettleLandedButSealLost).
func (s *Server) redriveSettlementEffect(ctx context.Context, rec journal.Record) (string, error) {
	key := rec.Key()
	if rec.Effect != journal.EffectSettle {
		// A future effect kind written by a newer build. Leave it alone
		// rather than guessing at its ladder.
		return journal.RecoveredRetry, nil
	}
	if !rec.TokensConsistent() {
		// The store rejects total != prompt+completion, so this effect can
		// never settle. Retrying forever would pin its segment; quarantine
		// makes it operator-visible instead.
		return s.quarantineSettlementEffect(key, "token_totals_inconsistent", 0), nil
	}

	settlement := storage.ReservationSettlement{
		AccountID:        rec.AccountID,
		RequestID:        rec.RequestID,
		PromptTokens:     rec.PromptTokens,
		CompletionTokens: rec.CompletionTokens,
		TotalTokens:      rec.TotalTokens,
		MaxTotalTokens:   rec.MaxTotalTokens,
		TokenSource:      rec.TokenSource,
		Outcome:          rec.Outcome,
		SettledAt:        s.now(),
	}
	var settleErr error
	if rec.DemoIdentity != "" {
		settleErr = s.store.SettleDemoReservation(ctx, settlement, storage.DemoUsageEvent{
			RequestID:     rec.RequestID,
			ClientIP:      rec.DemoIdentity,
			DemoTokenHash: rec.DemoTokenHash,
			CreatedAt:     s.now(),
		})
	} else if rec.WalletSessionID != "" {
		settleErr = s.store.FinalizeWalletSessionReservation(ctx, storage.WalletSessionReservationSettlement{
			SessionID:        rec.WalletSessionID,
			AccountID:        rec.AccountID,
			RequestID:        rec.RequestID,
			PromptTokens:     rec.PromptTokens,
			CompletionTokens: rec.CompletionTokens,
			TotalTokens:      rec.TotalTokens,
			MaxTotalTokens:   rec.MaxTotalTokens,
			TokenSource:      rec.TokenSource,
			Outcome:          rec.Outcome,
			SettledAt:        s.now(),
		})
	} else {
		settleErr = s.store.SettleReservation(ctx, settlement)
	}
	if settleErr == nil {
		s.sealSettlementEffect(key, journal.SealSettled)
		s.journalAttempts.clear(key)
		return journal.RecoveredSettled, nil
	}
	// Audit R1 (code HIGH): do NOT bail out on an unclassified settle error.
	// The §17.7 crash window (EnsureUsageEvent succeeded, crash before the
	// refund) leaves an ACTIVE reservation plus an existing usage row, so
	// SettleReservation fails on the usage_events PK with an error that is
	// neither NotFound nor Terminal — and would wedge here forever while
	// DailyUsage double-counts. Fall through to the idempotent rung instead:
	// EnsureUsageEvent verifies-or-inserts, the refund releases the hold, and
	// the seal lands. If the settle failure was transient DB pathology, the
	// fallback rung either completes the equivalent §17.7 outcome or fails
	// too, leaving the effect unsealed for the next tick.

	ev := storage.UsageEvent{
		RequestID:        rec.RequestID,
		AccountID:        rec.AccountID,
		DemoIdentity:     rec.DemoIdentity,
		WindowDate:       rec.WindowDate,
		PromptTokens:     rec.PromptTokens,
		CompletionTokens: rec.CompletionTokens,
		TotalTokens:      rec.TotalTokens,
		TokenSource:      rec.TokenSource,
		Outcome:          rec.Outcome,
		CreatedAt:        s.now(),
	}
	if err := s.store.EnsureUsageEvent(ctx, ev); err != nil {
		if !errors.Is(err, storage.ErrUsageEventConflict) {
			return "", err
		}
		// Audit R2 (architect MEDIUM): a conflicting durable row means SOME
		// bill exists for this request — the money question goes to
		// retry/quarantine below, but the quota HOLD must not keep
		// double-counting against the buyer while it does. Best-effort
		// release; already-terminal is the benign sentinel.
		var refundErr error
		if rec.WalletSessionID != "" {
			refundErr = s.store.RefundWalletSessionReservation(ctx, rec.AccountID, rec.WalletSessionID, rec.RequestID, s.now())
		} else {
			refundErr = s.store.RefundReservation(ctx, rec.AccountID, rec.RequestID, s.now().Unix())
		}
		if refundErr != nil &&
			!errors.Is(refundErr, storage.ErrReservationNotFound) && !errors.Is(refundErr, storage.ErrReservationTerminal) {
			// Audit R3 (architect MEDIUM): a failed hold release must NOT
			// consume a conflict attempt — quarantining on the final attempt
			// with the hold still active would suppress the re-drive that
			// releases it. Retry without counting; the conflict clock only
			// advances once the hold is off the books.
			slog.Warn("gateway settlement journal conflict-path refund failed; retrying before counting the attempt",
				"account_id", rec.AccountID,
				"request_id", rec.RequestID,
				"error", refundErr,
			)
			return journal.RecoveredRetry, nil
		}
		attempts := s.journalAttempts.next(key)
		if attempts < settlementJournalMaxConflictAttempts {
			slog.Warn("gateway settlement journal re-drive conflicts with the durable usage row; retrying",
				"account_id", rec.AccountID,
				"request_id", rec.RequestID,
				"attempts", attempts,
				"max_attempts", settlementJournalMaxConflictAttempts,
			)
			return journal.RecoveredRetry, nil
		}
		return s.quarantineSettlementEffect(key, "usage_event_conflict", attempts), nil
	}
	if rec.DemoIdentity != "" {
		if demoErr := s.store.EnsureDemoUsageEvent(ctx, storage.DemoUsageEvent{
			RequestID:     rec.RequestID,
			ClientIP:      rec.DemoIdentity,
			DemoTokenHash: rec.DemoTokenHash,
			WindowDate:    rec.WindowDate,
			TotalTokens:   rec.TotalTokens,
			CreatedAt:     s.now(),
		}); demoErr != nil {
			// Non-fatal, exactly as in settleAfterCommit: usage_events is the
			// load-bearing money-path row.
			slog.Warn("gateway settlement journal re-drive demo_usage_events insert failed (usage_events row is OK)",
				"account_id", rec.AccountID,
				"request_id", rec.RequestID,
				"demo_identity", rec.DemoIdentity,
				"error", demoErr,
			)
		}
	}
	// Release any still-active hold so DailyUsage does not double-count the
	// buyer's quota. An already-terminal/missing reservation surfaces as
	// ErrReservationNotFound (the UPDATE matches only status='active' rows)
	// and is the benign common case; anything else is a real DB failure. The seal is GATED on it (audit R2, code
	// MEDIUM — the mirror of the settleAfterCommit gate): sealing past a
	// failed refund would suppress this very re-drive and leave the active
	// hold double-counting until the reaper.
	var refundErr error
	if rec.WalletSessionID != "" {
		refundErr = s.store.SealWalletSessionUsageEvent(ctx, rec.AccountID, rec.WalletSessionID, rec.RequestID, rec.TotalTokens, s.now())
	} else {
		refundErr = s.store.RefundReservation(ctx, rec.AccountID, rec.RequestID, s.now().Unix())
	}
	if refundErr != nil &&
		!errors.Is(refundErr, storage.ErrReservationNotFound) && !errors.Is(refundErr, storage.ErrReservationTerminal) {
		slog.Warn("gateway settlement journal re-drive refund failed; leaving effect unsealed",
			"account_id", rec.AccountID,
			"request_id", rec.RequestID,
			"error", refundErr,
		)
		if rec.WalletSessionID != "" {
			s.recordWalletSessionAudit(ctx, rec.AccountID, rec.WalletSessionID, "wallet_session_settlement_reconcile_failed", "gateway", map[string]any{
				"request_id": rec.RequestID,
				"phase":      "journal_usage_event_release",
				"error":      safeAuditError(refundErr),
			})
		}
		return journal.RecoveredRetry, nil
	}
	s.sealSettlementEffect(key, journal.SealUsageEvent)
	s.journalAttempts.clear(key)
	slog.Warn("gateway settlement journal recovered a dropped settlement via the SPEC-006 § 17.7 fallback",
		"account_id", rec.AccountID,
		"request_id", rec.RequestID,
		"window_date", rec.WindowDate,
		"total_tokens", rec.TotalTokens,
		"token_source", rec.TokenSource,
		"outcome", rec.Outcome,
	)
	return journal.RecoveredUsageEvent, nil
}

func (s *Server) sealSettlementEffect(key journal.Key, result string) {
	if err := s.journal.WriteSeal(key, result); err != nil {
		// A lost seal costs one idempotent re-drive on the next pass, never
		// a bill — the whole reason seals are not fsynced.
		slog.Warn("gateway settlement journal seal write failed; the effect will be re-driven idempotently",
			"account_id", key.AccountID,
			"request_id", key.RequestID,
			"result", result,
			"error", err,
		)
	}
}

func (s *Server) quarantineSettlementEffect(key journal.Key, reason string, attempts int) string {
	if err := s.journal.WriteQuarantine(key, reason, attempts); err != nil {
		slog.Error("gateway settlement journal quarantine write failed",
			"account_id", key.AccountID,
			"request_id", key.RequestID,
			"reason", reason,
			"error", err,
		)
	}
	s.journalAttempts.clear(key)
	slog.Error("CRITICAL gateway settlement journal quarantined an unrecoverable effect; reconcile from the coordinator request_log",
		"account_id", key.AccountID,
		"request_id", key.RequestID,
		"effect", key.Effect,
		"reason", reason,
		"attempts", attempts,
	)
	return journal.RecoveredQuarantined
}
