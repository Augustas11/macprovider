package ws

import (
	"context"
	"database/sql"
	"database/sql/driver"
	"errors"
	"fmt"
	"net"
	"net/http"
	"testing"

	"github.com/lib/pq"
)

// TestHardwareTrustErrorStatusClassification pins the precise HTTP status/code
// mapping for the hardware-trust error surface (issue #582 FIX 6 + FIX 8):
// enumerated P0001 RAISE messages classify to validation → 400, chip-profile
// reason → 422, over-deadline pending → 410, dual-control/job/pending/incident
// conflicts → 409, not-found → 404. Classification is gated on SQLSTATE:
// operational classes (08/53/57/40001) and connectivity/nil-store → 503, an
// unexpected DB SQLSTATE or a coordinator-side invariant (non-pq) → 500, and an
// operational SQLSTATE whose message happens to contain a RAISE needle still
// maps by SQLSTATE (never by stray text).
func TestHardwareTrustErrorStatusClassification(t *testing.T) {
	cases := []struct {
		name       string
		err        error
		wantStatus int
		wantCode   string
	}{
		{"missing_field", &pq.Error{Code: "P0001", Message: "reason is required"}, http.StatusBadRequest, "invalid_request"},
		{"bad_actor", &pq.Error{Code: "P0001", Message: "requested_by must use operator:<admin_id>"}, http.StatusBadRequest, "invalid_request"},
		{"expiry_past", &pq.Error{Code: "P0001", Message: "requested_until must be in the future"}, http.StatusBadRequest, "invalid_request"},
		{"reason_unsupported", &pq.Error{Code: "P0001", Message: "job not approvable via hardware trust: hardware-verifier.v2:missing_trusted_chip_profile"}, http.StatusUnprocessableEntity, "hardware_trust_job_reason_unsupported"},
		{"dual_control", &pq.Error{Code: "P0001", Message: "dual_control_required"}, http.StatusConflict, "dual_control_required"},
		{"job_not_waiting", &pq.Error{Code: "P0001", Message: "job not waiting_trust"}, http.StatusConflict, "hardware_trust_job_not_waiting"},
		{"tuple_changed", &pq.Error{Code: "P0001", Message: "job tuple changed since request"}, http.StatusConflict, "hardware_trust_job_not_waiting"},
		{"already_committed", &pq.Error{Code: "P0001", Message: "pending approval already committed"}, http.StatusConflict, "hardware_trust_already_committed"},
		{"pending_cancelled", &pq.Error{Code: "P0001", Message: "pending approval cancelled"}, http.StatusConflict, "hardware_trust_pending_cancelled"},
		{"incident_conflict", &pq.Error{Code: "P0001", Message: "incident_id already used"}, http.StatusConflict, "hardware_trust_incident_conflict"},
		{"pending_not_found", &pq.Error{Code: "P0001", Message: "pending approval not found"}, http.StatusNotFound, "hardware_trust_pending_not_found"},
		{"root_not_found", &pq.Error{Code: "P0001", Message: "active operator_api trust root not found"}, http.StatusNotFound, "hardware_trust_root_not_found"},
		{"pending_expired", &pq.Error{Code: "P0001", Message: "hardware_trust_pending_expired"}, http.StatusGone, "hardware_trust_pending_expired"},
		// FIX 5: an evidence-stale job rejected AT approval maps to 409 resubmit-required.
		{"evidence_stale", &pq.Error{Code: "P0001", Message: "hardware_trust_job_evidence_stale"}, http.StatusConflict, "hardware_trust_job_evidence_stale"},
		{"connection_class", &pq.Error{Code: "08006", Message: "connection failure"}, http.StatusServiceUnavailable, "hardware_trust_store_unavailable"},
		// FIX 8: an operational SQLSTATE whose driver message happens to contain a
		// P0001 needle ("not found") must still classify by SQLSTATE → 503, never 404.
		{"operational_msg_has_needle", &pq.Error{Code: "08006", Message: "connection not found to host"}, http.StatusServiceUnavailable, "hardware_trust_store_unavailable"},
		{"resources_class", &pq.Error{Code: "53300", Message: "too many connections"}, http.StatusServiceUnavailable, "hardware_trust_store_unavailable"},
		{"operator_intervention", &pq.Error{Code: "57P01", Message: "admin shutdown"}, http.StatusServiceUnavailable, "hardware_trust_store_unavailable"},
		{"serialization", &pq.Error{Code: "40001", Message: "could not serialize"}, http.StatusServiceUnavailable, "hardware_trust_store_unavailable"},
		{"duplicate_pending", &pq.Error{Code: "23505", Message: "duplicate key value violates unique constraint \"idx_hardware_trust_pending_open_identity\""}, http.StatusConflict, "hardware_trust_pending_conflict"},
		// FIX 7: only genuine connectivity/context sentinels among non-pq errors
		// are transient → 503.
		{"context_deadline", context.DeadlineExceeded, http.StatusServiceUnavailable, "hardware_trust_store_unavailable"},
		{"context_canceled", context.Canceled, http.StatusServiceUnavailable, "hardware_trust_store_unavailable"},
		{"conn_done", sql.ErrConnDone, http.StatusServiceUnavailable, "hardware_trust_store_unavailable"},
		{"bad_conn", driver.ErrBadConn, http.StatusServiceUnavailable, "hardware_trust_store_unavailable"},
		{"wrapped_deadline", fmt.Errorf("query hardware trust: %w", context.DeadlineExceeded), http.StatusServiceUnavailable, "hardware_trust_store_unavailable"},
		// FIX 7: a real coordinator-vs-Postgres dial failure is *net.OpError
		// (net.Error), not driver.ErrBadConn, and must still map to 503.
		{"net_op_error", &net.OpError{Op: "dial", Net: "tcp", Err: errors.New("connect: connection refused")}, http.StatusServiceUnavailable, "hardware_trust_store_unavailable"},
		// FIX 7: every OTHER non-pq error is a deterministic defect → 500, so a
		// permanent failure does not invite a retry storm behind a 503. This
		// includes sql.ErrNoRows, scan failures, nil-store wiring bugs, opaque
		// dial errors, and coordinator-side invariant violations.
		{"no_rows", sql.ErrNoRows, http.StatusInternalServerError, "hardware_trust_internal_error"},
		{"opaque_non_pq", errors.New("dial tcp 127.0.0.1:5432: connect: connection refused"), http.StatusInternalServerError, "hardware_trust_internal_error"},
		{"nil_store", errors.New("hardware trust approve postgres store is nil"), http.StatusInternalServerError, "hardware_trust_internal_error"},
		{"generated_id_invariant", errors.New("generated pending_id is invalid"), http.StatusInternalServerError, "hardware_trust_internal_error"},
		{"unexpected_sqlstate", &pq.Error{Code: "22023", Message: "invalid parameter value"}, http.StatusInternalServerError, "hardware_trust_internal_error"},
		{"admin_unavailable", errHardwareTrustAdminUnavail, http.StatusServiceUnavailable, "hardware_trust_admin_unavailable"},
	}
	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			status, code := hardwareTrustErrorStatus(tc.err)
			if status != tc.wantStatus || code != tc.wantCode {
				t.Fatalf("status=%d code=%q, want status=%d code=%q", status, code, tc.wantStatus, tc.wantCode)
			}
		})
	}
}
