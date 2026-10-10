package billing

import (
	"context"
	"errors"
	"net/http"
	"time"

	"github.com/augstar/macprovider-coordinator/internal/auth"
)

// SPEC-022 R-15 operator surface (#1793). GET reports a dry run (or, with
// ?report=last, the last run's report); POST .../run starts one run in the
// background. Both are operator-bearer only and admin rate limited. Runs
// refuse while billing.retention.enabled is false.
const (
	evidenceRetentionPath    = "/admin/ledger/settlement-evidence-retention"
	evidenceRetentionRunPath = "/admin/ledger/settlement-evidence-retention/run"
	// evidenceRetentionDryRunTimeout bounds a dry run served inline.
	evidenceRetentionDryRunTimeout = 2 * time.Minute
	// evidenceRetentionRunTimeout bounds a run started from the admin route.
	evidenceRetentionRunTimeout = 6 * time.Hour
)

func (h *handler) evidenceRetentionHandler(w http.ResponseWriter, r *http.Request) {
	if !auth.OperatorOnlyBearerMatches(r.Header, h.operatorKey) {
		writeError(w, http.StatusForbidden, "forbidden", "operator key required")
		return
	}
	if !h.allowAdminRequest(w) {
		return
	}
	opts, configured := h.store.evidenceRetentionOptions()
	if !configured {
		writeError(w, http.StatusServiceUnavailable, "retention_not_configured", "settlement evidence retention is not configured")
		return
	}
	switch {
	case r.URL.Path == evidenceRetentionPath && r.Method == http.MethodGet:
		if r.URL.Query().Get("report") == "last" {
			report, ok := h.store.LastEvidenceRetentionReport()
			if !ok {
				writeError(w, http.StatusNotFound, "not_found", "no retention run has completed in this process")
				return
			}
			writeJSON(w, http.StatusOK, report)
			return
		}
		ctx, cancel := context.WithTimeout(r.Context(), evidenceRetentionDryRunTimeout)
		defer cancel()
		report, err := h.store.DryRunEvidenceRetention(ctx, opts)
		if err != nil {
			h.log.Warn().Err(err).Msg("settlement evidence retention dry run failed")
			writeError(w, http.StatusInternalServerError, "retention_dry_run_failed", "settlement evidence retention dry run failed")
			return
		}
		writeJSON(w, http.StatusOK, report)
	case r.URL.Path == evidenceRetentionRunPath && r.Method == http.MethodPost:
		if !opts.Enabled {
			writeError(w, http.StatusConflict, "retention_disabled", "billing.retention.enabled is false")
			return
		}
		if !h.store.evidenceRetentionRun.TryLock() {
			writeError(w, http.StatusConflict, "retention_busy", ErrEvidenceRetentionBusy.Error())
			return
		}
		// Release the probe lock; RunEvidenceRetention takes it itself. A
		// concurrent starter that wins the gap gets ErrEvidenceRetentionBusy
		// in the background and logs it.
		h.store.evidenceRetentionRun.Unlock()
		go func() {
			ctx, cancel := context.WithTimeout(context.Background(), evidenceRetentionRunTimeout)
			defer cancel()
			report, err := h.store.RunEvidenceRetention(ctx, opts)
			logEvidenceRetention(h, report, err)
		}()
		writeJSON(w, http.StatusAccepted, map[string]any{"status": "started", "report_path": evidenceRetentionPath + "?report=last"})
	default:
		writeError(w, http.StatusMethodNotAllowed, "method_not_allowed", "method not allowed")
	}
}

func logEvidenceRetention(h *handler, report EvidenceRetentionReport, err error) {
	event := h.log.Info()
	if err != nil {
		if errors.Is(err, ErrEvidenceRetentionBusy) {
			event = h.log.Warn()
		} else {
			event = h.log.Error().Err(err)
		}
	}
	event.Str("event", "settlement_evidence_retention").
		Str("status", report.Status).
		Int("eligible_requests", report.EligibleRequests).
		Int("deleted_requests", report.DeletedRequests).
		Int64("archive_id", report.ArchiveID).
		Str("archive_sha256", report.ArchiveSHA256).
		Msg("settlement evidence retention run finished")
}
