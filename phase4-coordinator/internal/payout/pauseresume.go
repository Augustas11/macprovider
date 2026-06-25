package payout

import (
	"context"
	"encoding/json"
	"errors"
	"io"
	"net/http"
	"strings"
	"time"

	"github.com/rs/zerolog"
)

// PauseResumeService backs the §6.4.1 pause/resume admin
// endpoints. Both endpoints share the §4.8a write+audit+sync-emit
// pipeline; the only differences are the new value (1 vs 0), the
// 409 conflict event name, and the §7.1 event name.
type PauseResumeService struct {
	writer      *RuntimeFlagWriter
	minInterval time.Duration
	log         zerolog.Logger
	nowFn       func() time.Time
}

// PauseResumeOptions bundles the dependencies the service needs.
// MinInterval is the rate-limit floor from
// payout.security.pause_resume_min_interval (default 60s, immutable).
type PauseResumeOptions struct {
	Writer      *RuntimeFlagWriter
	MinInterval time.Duration
	Logger      zerolog.Logger
	// NowFn is injected for tests; defaults to time.Now.
	NowFn func() time.Time
}

// NewPauseResumeService returns a service ready to wire into the
// chi router. Caller is responsible for installing the operator-
// key auth middleware in front of the handlers.
func NewPauseResumeService(opts PauseResumeOptions) (*PauseResumeService, error) {
	if opts.Writer == nil {
		return nil, errors.New("payout.NewPauseResumeService: Writer required")
	}
	if opts.MinInterval < 0 {
		return nil, errors.New("payout.NewPauseResumeService: MinInterval must be non-negative")
	}
	nowFn := opts.NowFn
	if nowFn == nil {
		nowFn = time.Now
	}
	return &PauseResumeService{
		writer:      opts.Writer,
		minInterval: opts.MinInterval,
		log:         opts.Logger,
		nowFn:       nowFn,
	}, nil
}

// pauseResumeRequest is the shared request body for both endpoints.
// SPEC §6.4.1: "reason" is required, free-text, logged.
type pauseResumeRequest struct {
	Reason string `json:"reason"`
}

// ServePause handles POST /admin/payout/pause-registration.
//
// Maps to §6.4.1 response table:
//   - 200 OK + payout_registration_paused (PAGE) event on success.
//   - 400 missing_field when reason is empty.
//   - 409 already_paused when the flag is already 1.
//   - 429 rate_limited when pause_resume_min_interval has not elapsed.
//   - 500 internal_error on DB faults.
func (s *PauseResumeService) ServePause(w http.ResponseWriter, r *http.Request, actor string) {
	s.serveFlip(w, r, actor, 1, "payout_registration_paused", "already_paused")
}

// ServeResume handles POST /admin/payout/resume-registration.
//
//   - 200 OK + payout_registration_resumed (PAGE) event.
//   - 400 missing_field when reason is empty.
//   - 409 already_running when the flag is already 0.
//   - 429 rate_limited.
//   - 500 internal_error.
func (s *PauseResumeService) ServeResume(w http.ResponseWriter, r *http.Request, actor string) {
	s.serveFlip(w, r, actor, 0, "payout_registration_resumed", "already_running")
}

func (s *PauseResumeService) serveFlip(
	w http.ResponseWriter,
	r *http.Request,
	actor string,
	newValue int,
	eventName string,
	conflictCode string,
) {
	body, err := io.ReadAll(http.MaxBytesReader(w, r.Body, 16*1024))
	if err != nil {
		writeError(w, http.StatusBadRequest, "bad_format")
		return
	}
	var req pauseResumeRequest
	if err := json.Unmarshal(body, &req); err != nil {
		writeError(w, http.StatusBadRequest, "bad_format")
		return
	}
	reason := strings.TrimSpace(req.Reason)
	if reason == "" {
		writeError(w, http.StatusBadRequest, "missing_field")
		return
	}

	result, err := s.writer.WriteFlagWithAudit(
		r.Context(),
		"registration_paused",
		newValue,
		actor,
		reason,
		s.minInterval,
		s.nowFn(),
	)
	if err != nil {
		switch {
		case errors.Is(err, ErrFlagAlreadyAtTarget):
			writeError(w, http.StatusConflict, conflictCode)
		case errors.Is(err, ErrFlagRateLimited):
			writeError(w, http.StatusTooManyRequests, "rate_limited")
		case errors.Is(err, ErrFlagMissing):
			// SPEC §4.8a invariant: the bootstrap-sentinel check
			// at startup must HALT the process before this can
			// happen. Reaching this branch is a 500 + invariant
			// violation event.
			s.emitInvariantViolation("runtime_flag missing", "registration_paused", "flag row absent on §6.4.1 write")
			writeError(w, http.StatusInternalServerError, "internal_error")
		default:
			s.log.Error().Err(err).
				Str("event", "payout_runtime_flag_write_failed").
				Str("flag", "registration_paused").
				Send()
			writeError(w, http.StatusInternalServerError, "internal_error")
		}
		return
	}

	// Post-commit CAS claim + sync emit. If the CAS returns 0
	// rows the reaper has already claimed (unreachable from
	// here in practice — we are the only writer to this id),
	// emit is skipped and we still return 200 because the audit
	// row IS committed.
	if err := s.writer.ClaimAndEmit(r.Context(), result.AuditID, func(row AuditRow) {
		s.emitFlipEvent(eventName, row)
	}); err != nil {
		// CAS claim failed AFTER the parent txn committed. The
		// reaper picks up the orphaned row; we still return 200
		// because the state change is durable.
		s.log.Warn().Err(err).
			Int64("audit_id", result.AuditID).
			Str("event", "payout_runtime_flag_sync_emit_failed").
			Send()
	}

	writeJSON(w, http.StatusOK, map[string]any{
		"ok":        true,
		"flag":      "registration_paused",
		"old_value": result.OldValue,
		"new_value": result.NewValue,
		"audit_id":  result.AuditID,
	})
}

// emitFlipEvent writes the §7.1 PAGE event. Event field set per
// SPEC §7.1 row:
//   - payout_registration_paused: actor, reason, ts_utc.
//   - payout_registration_resumed: actor, reason, ts_utc.
//
// Both also carry event_id = audit row id for downstream dedupe
// per §4.8a.
func (s *PauseResumeService) emitFlipEvent(eventName string, row AuditRow) {
	s.log.Warn().
		Str("event", eventName).
		Int64("event_id", row.ID).
		Str("actor", row.Actor).
		Str("reason", row.Reason).
		Str("ts_utc", row.OccurredAtUTC).
		Str("severity", "PAGE").
		Send()
}

func (s *PauseResumeService) emitInvariantViolation(where, name, message string) {
	s.log.Error().
		Str("event", "payout_invariant_violation").
		Str("where", where).
		Str("name", name).
		Str("severity", "PAGE").
		Msg(message)
}

// ReapOnce runs ONE pass over the §4.8a runtime_flag_audit table
// looking for orphaned audit rows. Called by reaper.go's
// background loop at payout.tuning.run_interval cadence.
//
// Per SPEC §4.8a: scan rows where emitted_to_log = 0 AND
// occurred_at_utc < now - 5 minutes; CAS-claim each via the
// shared ClaimAndEmit helper; emit + increment
// payout_flag_audit_reaped (severity=WARN) on successful claim.
//
// 5-minute lag is fixed per SPEC §4.8a wording; intentionally
// NOT a config knob.
func (s *PauseResumeService) ReapOnce(ctx context.Context) (int, error) {
	now := s.nowFn()
	cutoff := now.Add(-5 * time.Minute)
	ids, err := s.writer.ListUnemittedOlderThan(ctx, cutoff)
	if err != nil {
		return 0, err
	}
	reaped := 0
	for _, id := range ids {
		if ctx.Err() != nil {
			// Codex Step 3 r1 [code:1.6] LOW closure: graceful
			// shutdown is not a reaper error. Return reaped, nil
			// so the outer reaper loop logs success.
			return reaped, nil
		}
		err := s.writer.ClaimAndEmit(ctx, id, func(row AuditRow) {
			// The reaped event emits the original §7.1 event
			// first (so downstream consumers see the same row
			// as the sync path would have), then the WARN
			// counter event.
			eventName := flagFlipEventName(row.NewValue)
			s.emitFlipEvent(eventName, row)
			// Codex Step 3 r1 [code:1.2] MEDIUM closure: emit
			// the full §7.1 field set for payout_flag_audit_reaped.
			occurred, _ := time.Parse(time.RFC3339Nano, row.OccurredAtUTC)
			lagSec := int64(0)
			if !occurred.IsZero() {
				lagSec = int64(s.nowFn().Sub(occurred).Seconds())
			}
			s.log.Warn().
				Str("event", "payout_flag_audit_reaped").
				Int64("event_id", row.ID).
				Int64("flag_audit_id", row.ID).
				Str("flag_name", row.FlagName).
				Int("old_value", row.OldValue).
				Int("new_value", row.NewValue).
				Str("occurred_at_utc", row.OccurredAtUTC).
				Int64("reap_lag_seconds", lagSec).
				Str("ts_utc", s.nowFn().UTC().Format(time.RFC3339Nano)).
				Str("severity", "WARN").
				Send()
			reaped++
		})
		if err != nil {
			s.log.Error().Err(err).
				Int64("audit_id", id).
				Str("event", "payout_flag_audit_reaper_claim_failed").
				Send()
		}
	}
	return reaped, nil
}

// flagFlipEventName maps a runtime_flag_audit row's new_value to
// the §7.1 event name. registration_paused is the only closed-set
// flag in v0.1.x; future flags would extend this switch.
func flagFlipEventName(newValue int) string {
	if newValue == 1 {
		return "payout_registration_paused"
	}
	return "payout_registration_resumed"
}
