package ws

import (
	"context"
	"database/sql"
	"database/sql/driver"
	"encoding/json"
	"errors"
	"io"
	"net"
	"net/http"
	"strconv"
	"strings"
	"time"

	"github.com/augstar/macprovider-coordinator/internal/onboarding"
	"github.com/augstar/macprovider-coordinator/internal/pool"
	"github.com/google/uuid"
	"github.com/lib/pq"
)

// decodeStrictJSON decodes exactly one JSON object from r into dst, rejecting
// unknown fields and any trailing data. A misspelled field (e.g. an intended
// requested_until that becomes an unknown key) is a hard 400 rather than a
// silently-ignored omission that could create permanent trust (issue #582).
func decodeStrictJSON(r io.Reader, dst any) error {
	dec := json.NewDecoder(r)
	dec.DisallowUnknownFields()
	if err := dec.Decode(dst); err != nil {
		return err
	}
	var extra json.RawMessage
	if err := dec.Decode(&extra); !errors.Is(err, io.EOF) {
		return errors.New("request body must contain a single JSON object")
	}
	return nil
}

// handleHardwareTrustWaiting lists hardware-verification jobs parked in
// status waiting_trust so an operator can pick one to approve (issue #582).
// Results are bounded and cursor-paginated via ?after_id and ?limit.
func (s *Server) handleHardwareTrustWaiting(w http.ResponseWriter, r *http.Request) {
	if r.Method != http.MethodGet {
		w.Header().Set("Allow", http.MethodGet)
		http.Error(w, "method not allowed", http.StatusMethodNotAllowed)
		return
	}
	if _, ok := s.authorizedProviderAuthPolicyOperator(r); !ok {
		writeJSON(w, http.StatusUnauthorized, map[string]any{"error": map[string]any{"message": "unauthorized", "code": "invalid_operator_token"}})
		return
	}
	if s.hardwareTrustAdmin == nil {
		writeHardwareTrustError(w, errHardwareTrustAdminUnavail)
		return
	}
	var afterID int64
	if raw := strings.TrimSpace(r.URL.Query().Get("after_id")); raw != "" {
		parsed, err := strconv.ParseInt(raw, 10, 64)
		if err != nil || parsed < 0 {
			writeJSON(w, http.StatusBadRequest, map[string]any{"error": map[string]any{"message": "after_id must be a non-negative integer", "code": "invalid_request"}})
			return
		}
		afterID = parsed
	}
	limit := onboarding.WaitingTrustJobsPageCap
	if raw := strings.TrimSpace(r.URL.Query().Get("limit")); raw != "" {
		parsed, err := strconv.Atoi(raw)
		if err != nil || parsed <= 0 {
			writeJSON(w, http.StatusBadRequest, map[string]any{"error": map[string]any{"message": "limit must be a positive integer", "code": "invalid_request"}})
			return
		}
		limit = parsed
	}
	if limit > onboarding.WaitingTrustJobsPageCap {
		limit = onboarding.WaitingTrustJobsPageCap
	}
	jobs, err := s.hardwareTrustAdmin.ListWaitingTrustJobs(r.Context(), afterID, limit)
	if err != nil {
		s.log.Warn().Err(err).Msg("list waiting_trust hardware jobs failed")
		// Route through the shared mapper so a store outage is a 503 and a
		// transient DB error is not misreported as a flat 500 (issue #582).
		writeHardwareTrustError(w, err)
		return
	}
	out := make([]map[string]any, 0, len(jobs))
	var maxID int64
	for _, job := range jobs {
		if job.JobID > maxID {
			maxID = job.JobID
		}
		out = append(out, map[string]any{
			"job_id":                 job.JobID,
			"provider_id":            job.ProviderID,
			"chip":                   job.Chip,
			"chip_normalized":        job.ChipNormalized,
			"unified_memory_gb":      job.UnifiedMemoryGB,
			"hardware_identity_hash": job.HardwareIdentityHash,
			"decision_reason":        job.DecisionReason,
			"chip_profile_present":   job.ChipProfilePresent,
			// approvable tells the operator which waiting_trust jobs can complete
			// the operator approval path: only missing_trusted_hardware_identity
			// waits with a hardware_identity_hash and known chip profile can be
			// unblocked by an operator_api trust root. missing chip-profile waits
			// are surfaced too, with approvable=false, so operators can see the
			// full backlog (issue #582 FIX 10).
			"approvable":   hardwareTrustJobApprovable(job.DecisionReason, job.HardwareIdentityHash, job.ChipProfilePresent),
			"submitted_at": job.SubmittedAt.Format(time.RFC3339),
		})
	}
	resp := map[string]any{"waiting_trust": out, "count": len(out), "limit": limit}
	// A full page implies more rows may follow; hand back a next cursor.
	if len(jobs) == limit && maxID > 0 {
		resp["next_after_id"] = maxID
	}
	writeJSON(w, http.StatusOK, resp)
}

// handleHardwareTrustApproveRequest opens a dual-control request bound to a
// waiting_trust job. The trust tuple is derived server-side from the job row;
// no client-supplied tuple is accepted (issue #582).
func (s *Server) handleHardwareTrustApproveRequest(w http.ResponseWriter, r *http.Request) {
	if r.Method != http.MethodPost {
		w.Header().Set("Allow", http.MethodPost)
		http.Error(w, "method not allowed", http.StatusMethodNotAllowed)
		return
	}
	requestedBy, ok := s.authorizedProviderAuthPolicyOperator(r)
	if !ok {
		writeJSON(w, http.StatusUnauthorized, map[string]any{"error": map[string]any{"message": "unauthorized", "code": "invalid_operator_token"}})
		return
	}
	if s.hardwareTrustAdmin == nil {
		writeHardwareTrustError(w, errHardwareTrustAdminUnavail)
		return
	}
	var body struct {
		JobID          int64  `json:"job_id"`
		RequestedBy    string `json:"requested_by"`
		RequestedUntil string `json:"requested_until"`
		Reason         string `json:"reason"`
		IncidentID     string `json:"incident_id"`
	}
	if err := decodeStrictJSON(r.Body, &body); err != nil {
		writeJSON(w, http.StatusBadRequest, map[string]any{"error": map[string]any{"message": "invalid json", "code": "invalid_request"}})
		return
	}
	body.RequestedBy = strings.TrimSpace(body.RequestedBy)
	body.Reason = strings.TrimSpace(body.Reason)
	body.IncidentID = strings.TrimSpace(body.IncidentID)
	if body.JobID <= 0 {
		writeJSON(w, http.StatusBadRequest, map[string]any{"error": map[string]any{"message": "job_id must be a positive integer", "code": "invalid_request"}})
		return
	}
	if body.RequestedBy != "" && body.RequestedBy != requestedBy {
		writeJSON(w, http.StatusForbidden, map[string]any{"error": map[string]any{"message": "requested_by must match authenticated operator", "code": "operator_actor_mismatch"}})
		return
	}
	if body.Reason == "" {
		writeJSON(w, http.StatusBadRequest, map[string]any{"error": map[string]any{"message": "reason is required", "code": "invalid_request"}})
		return
	}
	var expiresAt *time.Time
	if body.RequestedUntil != "" {
		parsed, err := time.Parse(time.RFC3339, strings.TrimSpace(body.RequestedUntil))
		if err != nil {
			writeJSON(w, http.StatusBadRequest, map[string]any{"error": map[string]any{"message": "requested_until must be RFC3339", "code": "invalid_request"}})
			return
		}
		parsed = parsed.UTC()
		if !parsed.After(s.now()) {
			writeJSON(w, http.StatusBadRequest, map[string]any{"error": map[string]any{"message": "requested_until must be in the future", "code": "invalid_request"}})
			return
		}
		expiresAt = &parsed
	}
	pendingID := s.newUUID()
	if _, err := uuid.Parse(pendingID); err != nil {
		writeHardwareTrustError(w, errors.New("generated pending_id is invalid"))
		return
	}
	providerID, hardwareIdentityHash, chipNormalized, unifiedMemoryGB, err := s.hardwareTrustAdmin.RequestHardwareTrustApproval(r.Context(), pendingID, body.JobID, requestedBy, expiresAt, body.Reason, body.IncidentID)
	if err != nil {
		writeHardwareTrustError(w, err)
		return
	}
	log := s.log.Info().
		Str("admin_action", "hardware_trust_approval_requested").
		Int64("job_id", body.JobID).
		Str("provider_id", providerID).
		Str("pending_id", pendingID).
		Str("actor", requestedBy).
		Str("hardware_identity_hash", hardwareIdentityHash).
		Str("chip_normalized", chipNormalized).
		Int("unified_memory_gb", unifiedMemoryGB).
		Str("reason", body.Reason).
		Str("incident_id", body.IncidentID)
	if expiresAt != nil {
		log = log.Time("expires_at", *expiresAt)
	}
	log.Msg("hardware trust approval requested")
	resp := map[string]any{
		"pending_id":             pendingID,
		"job_id":                 body.JobID,
		"provider_id":            providerID,
		"hardware_identity_hash": hardwareIdentityHash,
		"chip_normalized":        chipNormalized,
		"unified_memory_gb":      unifiedMemoryGB,
		"requested_by":           requestedBy,
		"status":                 "pending",
	}
	if expiresAt != nil {
		resp["requested_until"] = expiresAt.Format(time.RFC3339)
	}
	writeJSON(w, http.StatusAccepted, resp)
}

// handleHardwareTrustApproveApprove commits a pending hardware-trust request
// as a distinct second operator, writing the operator_api trust root. Actual
// promotion of the bound waiting_trust job to verified is performed
// asynchronously by the hardware verifier on its next pass once the trust root
// exists.
// NOTE(#582): pre-existing verifier fairness limitation, tracked separately —
// the verifier's ORDER BY id LIMIT ... FOR UPDATE SKIP LOCKED batch scan
// (internal/stats/hardwareverify/verify.go) can delay a now-approvable job
// behind a backlog. This is unchanged by this branch and equally affected the
// prior YAML+sync path, so it is not worsened here; carried as a residual.
func (s *Server) handleHardwareTrustApproveApprove(w http.ResponseWriter, r *http.Request) {
	if r.Method != http.MethodPost {
		w.Header().Set("Allow", http.MethodPost)
		http.Error(w, "method not allowed", http.StatusMethodNotAllowed)
		return
	}
	approvedBy, ok := s.authorizedProviderAuthPolicyOperator(r)
	if !ok {
		writeJSON(w, http.StatusUnauthorized, map[string]any{"error": map[string]any{"message": "unauthorized", "code": "invalid_operator_token"}})
		return
	}
	if s.hardwareTrustAdmin == nil {
		writeHardwareTrustError(w, errHardwareTrustAdminUnavail)
		return
	}
	pendingID := strings.TrimPrefix(r.URL.Path, "/admin/hardware-trust/approve/")
	pendingID = strings.TrimSuffix(pendingID, "/approve")
	if pendingID == "" || !strings.HasSuffix(r.URL.Path, "/approve") {
		writeJSON(w, http.StatusNotFound, map[string]any{"error": map[string]any{"message": "admin path not found", "code": "not_found"}})
		return
	}
	if _, err := uuid.Parse(pendingID); err != nil {
		writeJSON(w, http.StatusBadRequest, map[string]any{"error": map[string]any{"message": "pending_id must be UUID", "code": "invalid_request"}})
		return
	}
	var body struct {
		ApprovedBy string `json:"approved_by"`
	}
	if err := decodeStrictJSON(r.Body, &body); err != nil {
		writeJSON(w, http.StatusBadRequest, map[string]any{"error": map[string]any{"message": "invalid json", "code": "invalid_request"}})
		return
	}
	body.ApprovedBy = strings.TrimSpace(body.ApprovedBy)
	if body.ApprovedBy != "" && body.ApprovedBy != approvedBy {
		writeJSON(w, http.StatusForbidden, map[string]any{"error": map[string]any{"message": "approved_by must match authenticated operator", "code": "operator_actor_mismatch"}})
		return
	}
	// The approval rejects an over-age job AT approval time rather than committing
	// a trust root the verifier then rejects as stale_job on its next pass (issue
	// #582 FIX 5). The evidence-age boundary is a definer-owned invariant HARDCODED
	// inside approve_hardware_trust_approval (7 days, kept in sync with
	// hardwareverify.MaxEvidenceAgeDays) rather than a caller parameter, so it
	// cannot be bypassed; the proof-of-weights autotune_evidence_ttl_days config is
	// a distinct admission-side gate and is deliberately NOT reused here.
	providerID, hardwareIdentityHash, chipNormalized, unifiedMemoryGB, expiresAt, reason, incidentID, source, effectiveExpiresAt, err := s.hardwareTrustAdmin.ApproveHardwareTrustApproval(r.Context(), pendingID, approvedBy)
	if err != nil {
		writeHardwareTrustError(w, err)
		return
	}
	// Terminal structural fix (issue #582): approval always writes the operator_api
	// trust row and never rides an inventory root, so the SQL function always reports
	// source='operator_api'. The defensive fallback keeps that contract if a store
	// ever returns an empty source.
	if strings.TrimSpace(source) == "" {
		source = "operator_api"
	}
	log := s.log.Info().
		Str("admin_action", "hardware_trust_approval_approved").
		Str("provider_id", providerID).
		Str("pending_id", pendingID).
		Str("actor", approvedBy).
		Str("hardware_identity_hash", hardwareIdentityHash).
		Str("chip_normalized", chipNormalized).
		Int("unified_memory_gb", unifiedMemoryGB).
		Str("reason", reason).
		Str("incident_id", incidentID).
		Str("source", source)
	if expiresAt != nil {
		log = log.Time("requested_until", *expiresAt)
	}
	if effectiveExpiresAt != nil {
		log = log.Time("effective_expires_at", *effectiveExpiresAt)
	}
	log.Msg("hardware trust approval approved")
	resp := map[string]any{
		"pending_id":             pendingID,
		"provider_id":            providerID,
		"hardware_identity_hash": hardwareIdentityHash,
		"chip_normalized":        chipNormalized,
		"unified_memory_gb":      unifiedMemoryGB,
		"approved_by":            approvedBy,
		"status":                 "committed",
		// Approval always writes the operator_api trust row (issue #582 terminal
		// structural fix), so source is always operator_api and the grant is always
		// operator-revocable via the revoke endpoint.
		"source":             source,
		"operator_revocable": true,
	}
	if expiresAt != nil {
		resp["requested_until"] = expiresAt.Format(time.RFC3339)
	}
	if effectiveExpiresAt != nil {
		resp["effective_expires_at"] = effectiveExpiresAt.Format(time.RFC3339)
	}
	writeJSON(w, http.StatusOK, resp)
}

// handleHardwareTrustRevoke inactivates a granted operator_api trust root with
// an audit trail. Trust-reducing (fail-safe), so a single operator actor is
// acceptable, but it is operator-authenticated and ledgered (issue #582).
func (s *Server) handleHardwareTrustRevoke(w http.ResponseWriter, r *http.Request) {
	if r.Method != http.MethodPost {
		w.Header().Set("Allow", http.MethodPost)
		http.Error(w, "method not allowed", http.StatusMethodNotAllowed)
		return
	}
	revokedBy, ok := s.authorizedProviderAuthPolicyOperator(r)
	if !ok {
		writeJSON(w, http.StatusUnauthorized, map[string]any{"error": map[string]any{"message": "unauthorized", "code": "invalid_operator_token"}})
		return
	}
	if s.hardwareTrustAdmin == nil {
		writeHardwareTrustError(w, errHardwareTrustAdminUnavail)
		return
	}
	var body struct {
		ProviderID           string `json:"provider_id"`
		HardwareIdentityHash string `json:"hardware_identity_hash"`
		RevokedBy            string `json:"revoked_by"`
		Reason               string `json:"reason"`
	}
	if err := decodeStrictJSON(r.Body, &body); err != nil {
		writeJSON(w, http.StatusBadRequest, map[string]any{"error": map[string]any{"message": "invalid json", "code": "invalid_request"}})
		return
	}
	body.ProviderID = strings.TrimSpace(body.ProviderID)
	body.HardwareIdentityHash = strings.TrimSpace(body.HardwareIdentityHash)
	body.RevokedBy = strings.TrimSpace(body.RevokedBy)
	body.Reason = strings.TrimSpace(body.Reason)
	if body.RevokedBy != "" && body.RevokedBy != revokedBy {
		writeJSON(w, http.StatusForbidden, map[string]any{"error": map[string]any{"message": "revoked_by must match authenticated operator", "code": "operator_actor_mismatch"}})
		return
	}
	if body.ProviderID == "" {
		writeJSON(w, http.StatusBadRequest, map[string]any{"error": map[string]any{"message": "provider_id is required", "code": "invalid_request"}})
		return
	}
	if body.HardwareIdentityHash == "" {
		writeJSON(w, http.StatusBadRequest, map[string]any{"error": map[string]any{"message": "hardware_identity_hash is required", "code": "invalid_request"}})
		return
	}
	if body.Reason == "" {
		writeJSON(w, http.StatusBadRequest, map[string]any{"error": map[string]any{"message": "reason is required", "code": "invalid_request"}})
		return
	}
	chipNormalized, unifiedMemoryGB, nowUntrusted, err := s.hardwareTrustAdmin.RevokeHardwareTrustApproval(r.Context(), body.ProviderID, body.HardwareIdentityHash, revokedBy, body.Reason)
	if err != nil {
		writeHardwareTrustError(w, err)
		return
	}
	s.log.Info().
		Str("admin_action", "hardware_trust_approval_revoked").
		Str("provider_id", body.ProviderID).
		Str("actor", revokedBy).
		Str("hardware_identity_hash", body.HardwareIdentityHash).
		Str("chip_normalized", chipNormalized).
		Int("unified_memory_gb", unifiedMemoryGB).
		Bool("now_untrusted", nowUntrusted).
		Str("reason", body.Reason).
		Msg("hardware trust approval revoked")
	// FIX 1 (round-8, issue #582): the admission gate (LatestVerified) now re-checks
	// live trust, but a provider already connected keeps serving on its existing
	// session until it reconnects. Now that the trust root is expired in the DB
	// above, evict any ACTIVE websocket session for this provider so it must
	// reconnect and be re-admitted — and then rejected by the trust join. Reuse the
	// existing operator-disconnect path (drain → mark draining → CloseBanned) rather
	// than any new transport. Best-effort: if the provider is not currently
	// connected this is a no-op.
	//
	// FIX 1 (round-12, issue #582): under per-source trust rows, revoking the
	// operator_api root leaves the provider trusted when an active inventory root
	// still backs the SAME hardware tuple — the SQL demotion correctly keeps
	// verified=true in that case. Evicting the session then would needlessly drain
	// and close a still-valid, inventory-trusted connection. Only evict when the
	// provider is now FULLY untrusted (no active trust root of any source remains);
	// otherwise remove the operator grant but leave the session connected.
	if nowUntrusted {
		s.disconnectProviderForTrustRevocation(body.ProviderID, revokedBy)
	} else {
		s.log.Info().
			Str("admin_action", "hardware_trust_approval_revoked").
			Str("provider_id", body.ProviderID).
			Str("actor", revokedBy).
			Str("hardware_identity_hash", body.HardwareIdentityHash).
			Msg("operator trust grant revoked but provider still backed by active inventory trust root; leaving session connected")
	}
	writeJSON(w, http.StatusOK, map[string]any{
		"provider_id":            body.ProviderID,
		"hardware_identity_hash": body.HardwareIdentityHash,
		"chip_normalized":        chipNormalized,
		"unified_memory_gb":      unifiedMemoryGB,
		"revoked_by":             revokedBy,
		"status":                 "revoked",
		"source":                 "operator_api",
	})
}

// hardwareTrustJobApprovable reports whether a waiting_trust job can complete
// the operator hardware-trust approval path. The bound job must carry a
// hardware_identity_hash, a known chip profile, and its decision_reason (stored
// version-prefixed, e.g. "hardware-verifier.v2:missing_trusted_hardware_identity")
// must reduce to missing_trusted_hardware_identity; missing chip-profile waits
// are listed but not approvable (issue #582 FIX 10).
func hardwareTrustJobApprovable(decisionReason, hardwareIdentityHash string, chipProfilePresent bool) bool {
	if strings.TrimSpace(hardwareIdentityHash) == "" {
		return false
	}
	if !chipProfilePresent {
		return false
	}
	bare := decisionReason
	if idx := strings.LastIndex(bare, ":"); idx >= 0 {
		bare = bare[idx+1:]
	}
	return bare == "missing_trusted_hardware_identity"
}

// disconnectProviderForTrustRevocation best-effort evicts the provider's ACTIVE
// websocket session after its hardware-trust root has been revoked, so it must
// reconnect and be re-admitted (and rejected by the live-trust admission join).
// It reuses the same operator-disconnect mechanism as handleAdminReject /
// handleBlacklist (drain frame → mark draining → CloseBanned close frame) rather
// than inventing a new transport path. A provider that is not currently connected
// is a silent no-op (issue #582 FIX 1).
func (s *Server) disconnectProviderForTrustRevocation(providerID, actor string) {
	provider, ok := s.pool.Resolve(providerID, "")
	if !ok {
		return
	}
	session, ok := s.sessionFor(provider.ProviderID, provider.AssignedID)
	if !ok {
		return
	}
	_ = session.send([]byte(`{"type":"drain"}`))
	s.pool.MarkState(provider.ProviderID, provider.AssignedID, pool.StateDraining)
	s.log.Info().
		Str("admin_action", "hardware_trust_provider_evicted").
		Str("provider_id", provider.ProviderID).
		Str("assigned_id", provider.AssignedID).
		Str("actor", actor).
		Msg("evicting provider session after hardware trust revocation")
	time.AfterFunc(200*time.Millisecond, func() {
		s.closeSession(session, CloseBanned, "hardware trust revoked for provider "+provider.ProviderID)
	})
}

// writeHardwareTrustError maps hardware-trust store/SQL errors to their own
// sentinels and HTTP statuses rather than routing through the auth-policy
// mapper (issue #582). A non-protocol error (driver/connectivity/internal) maps
// to 503 so a DB outage never masquerades as a 400 client error.
func writeHardwareTrustError(w http.ResponseWriter, err error) {
	status, code := hardwareTrustErrorStatus(err)
	writeJSON(w, status, map[string]any{"error": map[string]any{"message": err.Error(), "code": code}})
}

func hardwareTrustErrorStatus(err error) (int, string) {
	if errors.Is(err, errHardwareTrustAdminUnavail) {
		return http.StatusServiceUnavailable, "hardware_trust_admin_unavailable"
	}

	// Classify strictly by SQLSTATE first (issue #582 FIX 8): a function RAISE
	// message is only trusted as a protocol result when the error is a P0001
	// raise_exception. Scanning arbitrary text before inspecting SQLSTATE would
	// mis-map an operational error whose driver message happens to contain a
	// needle (e.g. "not found") to a client status.
	var pqErr *pq.Error
	if errors.As(err, &pqErr) {
		code := string(pqErr.Code)
		// P0001 raise_exception — the class every function RAISE surfaces as — is
		// the ONLY SQLSTATE whose message is a trusted protocol result.
		if code == "P0001" {
			return classifyHardwareTrustRaise(pqErr.Message)
		}
		// Operational SQLSTATE classes → 503. Guard the length so a malformed
		// (empty/short) code never panics pq.ErrorCode.Class.
		if len(code) >= 2 {
			switch code[:2] {
			case "08", // connection exception
				"53", // insufficient resources
				"57": // operator intervention / shutdown
				return http.StatusServiceUnavailable, "hardware_trust_store_unavailable"
			}
		}
		switch pqErr.Code {
		case "40001": // serialization_failure
			return http.StatusServiceUnavailable, "hardware_trust_store_unavailable"
		case "23505": // unique_violation — an open pending already exists for this
			// (provider, hardware_identity_hash) or (provider, incident_id) domain
			// and is still active (not stale), so it correctly blocks the duplicate.
			return http.StatusConflict, "hardware_trust_pending_conflict"
		}
		// The DB processed the call but raised an SQLSTATE we do not enumerate
		// (invariant violation, bad parameter, etc.) — a server-side error, 500.
		return http.StatusInternalServerError, "hardware_trust_internal_error"
	}

	// Non-pq errors (issue #582 FIX 7): only GENUINE connectivity/context
	// failures are transient and worth a 503 retry hint. Everything else —
	// sql.ErrNoRows, scan/decode failures, nil-store wiring bugs, and
	// coordinator-side invariant violations (a generated/echoed pending_id that
	// failed to round-trip) — is a deterministic server defect that retries
	// cannot fix, so it maps to 500 rather than inviting a retry storm on a
	// permanent error.
	if errors.Is(err, context.DeadlineExceeded) ||
		errors.Is(err, context.Canceled) ||
		errors.Is(err, sql.ErrConnDone) ||
		errors.Is(err, driver.ErrBadConn) {
		return http.StatusServiceUnavailable, "hardware_trust_store_unavailable"
	}
	// A genuine network-layer failure (dial refused, connection reset, I/O
	// timeout) surfaces as net.Error rather than one of the sentinels above — a
	// real coordinator-vs-Postgres outage is *net.OpError, not driver.ErrBadConn.
	// It is transient → 503, keeping the store-outage contract intact while the
	// default below still sends deterministic defects to 500 (issue #582 FIX 7).
	var netErr net.Error
	if errors.As(err, &netErr) {
		return http.StatusServiceUnavailable, "hardware_trust_store_unavailable"
	}
	return http.StatusInternalServerError, "hardware_trust_internal_error"
}

// classifyHardwareTrustRaise maps an enumerated SECURITY DEFINER RAISE message
// (SQLSTATE P0001 only) to its HTTP status/code: validation (400), chip-profile
// reason (422), over-deadline pending (410), dual-control/job/pending/incident
// conflicts (409), or not-found (404). An unrecognized P0001 is still a
// deliberate protocol result, but an unknown one is treated as a server error
// (500) rather than a misleading 400 (issue #582 FIX 8).
func classifyHardwareTrustRaise(message string) (int, string) {
	msg := strings.ToLower(message)
	switch {
	case strings.Contains(msg, "dual_control_required"):
		return http.StatusConflict, "dual_control_required"
	case strings.Contains(msg, "hardware_trust_pending_expired"):
		// The 7-day abandonment deadline elapsed before approval (issue #582
		// FIX 6); the pending is gone and the operator must re-request.
		return http.StatusGone, "hardware_trust_pending_expired"
	case strings.Contains(msg, "hardware_trust_job_evidence_stale"):
		// The bound job's evidence aged past the verifier's limit
		// (MaxEvidenceAgeDays) during the dual-control window (issue #582 FIX 5), or
		// the OLDEST benchmark timestamp is stale within the promotion runway (round-8
		// FIX 4). Approving would commit a trust root the verifier immediately rejects
		// as stale_job/stale_benchmark; 409 signals the operator to have the provider
		// resubmit fresh evidence and re-request.
		return http.StatusConflict, "hardware_trust_job_evidence_stale"
	case strings.Contains(msg, "hardware_trust_chip_profile_missing"):
		// The bound job's chip profile was removed after the job was evaluated (or the
		// job lacked one all along); approving on the stored identity reason would let
		// the verifier re-park it for missing_trusted_chip_profile (round-8 FIX 3). 409
		// signals the operator to restore the chip profile, then re-request.
		return http.StatusConflict, "hardware_trust_chip_profile_missing"
	case strings.Contains(msg, "hardware_trust_promotion_runway_insufficient"):
		// The requested expiry or the 7-day evidence boundary is within ~5 minutes
		// of the effective trust root, but the verifier timer can run up to ~90s
		// later — so approving would commit a root the verifier re-parks/rejects
		// almost immediately (issue #582 FIX 6). 409 signals the operator to extend
		// requested_until or have the provider resubmit fresh evidence, then
		// re-request.
		return http.StatusConflict, "hardware_trust_promotion_runway_insufficient"
	case strings.Contains(msg, "not approvable via hardware trust"):
		// waiting_trust for a chip-profile reason cannot be unblocked by a
		// hardware-identity trust root (issue #582 FIX C/FIX 7).
		return http.StatusUnprocessableEntity, "hardware_trust_job_reason_unsupported"
	case strings.Contains(msg, "job not waiting_trust"),
		strings.Contains(msg, "job no longer waiting_trust"),
		strings.Contains(msg, "job tuple changed"):
		return http.StatusConflict, "hardware_trust_job_not_waiting"
	case strings.Contains(msg, "job evidence missing"):
		return http.StatusConflict, "hardware_trust_job_incomplete"
	case strings.Contains(msg, "already committed"):
		return http.StatusConflict, "hardware_trust_already_committed"
	case strings.Contains(msg, "pending approval cancelled"):
		return http.StatusConflict, "hardware_trust_pending_cancelled"
	case strings.Contains(msg, "incident_id already used"):
		return http.StatusConflict, "hardware_trust_incident_conflict"
	case strings.Contains(msg, "trust root not found"):
		return http.StatusNotFound, "hardware_trust_root_not_found"
	case strings.Contains(msg, "not found"):
		return http.StatusNotFound, "hardware_trust_pending_not_found"
	case strings.Contains(msg, "is required"),
		strings.Contains(msg, "must use operator:"),
		strings.Contains(msg, "must be in the future"):
		return http.StatusBadRequest, "invalid_request"
	}
	return http.StatusInternalServerError, "hardware_trust_internal_error"
}
