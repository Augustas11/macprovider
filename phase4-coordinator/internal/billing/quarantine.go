package billing

import (
	"context"
	"database/sql"
	"encoding/json"
	"errors"
	"fmt"
	"net/http"
	"strconv"
	"strings"
	"time"
	"unicode/utf8"

	"github.com/augstar/macprovider-coordinator/internal/auth"
	"modernc.org/sqlite"
	sqlite3errs "modernc.org/sqlite/lib"
)

// SPEC-005 v0.4 §11.6 quarantine VOID admin endpoint.
//
// One POST endpoint: `/admin/ledger/quarantine/{request_credit_id}/force-void`.
// Force-credit is deferred to v0.5 (see SPEC-005 v0.4 changelog
// scope-cut rationale). The resolution_kind enum on
// `ledger_quarantine_resolutions` is constrained to ('force_void')
// in v0.4; v0.5 widens.

const (
	quarantinePathPrefix   = "/admin/ledger/quarantine/"
	forceVoidPathSuffix    = "/force-void"
	maxReasonLen           = 500
	maxOperatorIDLen       = 64
	maxBodyBytes           = 4 * 1024
	operatorAttribution    = "operator_key_self_asserted"
	eventForceVoid         = "ledger_quarantine_force_void"
	eventConfigFlagChanged = "billing_config_flag_changed"
	resolutionKindVoid     = "force_void"
)

// matchQuarantinePath returns (request_credit_id, "force-void", ok)
// when r.URL.Path matches the §11.6 quarantine path shape. ok=false
// otherwise — the dispatcher then routes to 404.
func matchQuarantinePath(path string) (int64, string, bool) {
	if !strings.HasPrefix(path, quarantinePathPrefix) {
		return 0, "", false
	}
	rest := path[len(quarantinePathPrefix):]
	if !strings.HasSuffix(rest, forceVoidPathSuffix) {
		return 0, "", false
	}
	idStr := rest[:len(rest)-len(forceVoidPathSuffix)]
	if idStr == "" {
		return 0, "", false
	}
	// path parameter must be a base-10 int64 — SPEC-005 §11.6.1.1
	// 400 `bad_request` for any non-integer / overflow case.
	for _, c := range idStr {
		if c < '0' || c > '9' {
			return 0, "", false
		}
	}
	id, err := strconv.ParseInt(idStr, 10, 64)
	if err != nil {
		return 0, "", false
	}
	return id, "force-void", true
}

// forceVoidHandler implements POST /admin/ledger/quarantine/{id}/force-void
// per SPEC-005 v0.4 §11.6.1.
func (h *handler) forceVoidHandler(w http.ResponseWriter, r *http.Request, requestCreditID int64) {
	// Method enforcement (§11.6.1.1).
	if r.Method != http.MethodPost {
		writeError(w, http.StatusMethodNotAllowed, "method_not_allowed", "method not allowed")
		return
	}
	// Auth — operator-key, matches existing §16.1 contract (403 for
	// both missing and wrong key).
	if !auth.OperatorOnlyBearerMatches(r.Header, h.operatorKey) {
		writeError(w, http.StatusForbidden, "forbidden", "operator key required")
		return
	}
	// Route-layer gate (§11.5 launch-gate item 10). Disabled-flag and
	// row-not-found both return 404 with byte-identical bodies — no
	// leak of which case fired.
	if !h.forceVoidEnabled {
		writeError(w, http.StatusNotFound, "not_found", "not found")
		return
	}
	// Body shape pre-checks before reading. §11.6.1.1 names 415 and 413.
	if ct := r.Header.Get("Content-Type"); !isJSONContentType(ct) {
		writeError(w, http.StatusUnsupportedMediaType, "unsupported_media_type", "content-type must be application/json")
		return
	}
	if r.ContentLength > maxBodyBytes {
		writeError(w, http.StatusRequestEntityTooLarge, "request_too_large", "body exceeds 4 KiB")
		return
	}
	// Streaming read with a 4 KiB+1 cap so an oversized body never
	// fully materializes; ContentLength may be -1 or wrong.
	r.Body = http.MaxBytesReader(w, r.Body, maxBodyBytes+1)
	defer r.Body.Close()
	body, ok := decodeForceVoidBody(w, r)
	if !ok {
		return
	}
	// Per-field validation. The §11.6.3 sanitizer is reject-based;
	// any rejection becomes a 422 with the specific code.
	if errCode := validateOperatorID(body.OperatorID); errCode != "" {
		writeValidationError(w, errCode, "operator_id rejected: "+errCode)
		return
	}
	if errCode := validateReason(body.Reason); errCode != "" {
		writeValidationError(w, errCode, "reason rejected: "+errCode)
		return
	}
	operatorID := strings.TrimSpace(body.OperatorID)
	reason := strings.TrimSpace(body.Reason)

	ctx, cancel := context.WithTimeout(r.Context(), 5*time.Second)
	defer cancel()

	// All operational work happens inside one BEGIN IMMEDIATE
	// transaction per SPEC-005 §11.6.2 — the resolution INSERT and
	// the audit_log INSERT share atomicity. The audit row is
	// written via the same *sql.Tx (NOT via audit.Store.Insert)
	// because the audit Store opens a separate *sql.DB handle and
	// cannot participate in this transaction.
	tx, err := h.store.db.BeginTx(ctx, &sql.TxOptions{Isolation: sql.LevelSerializable})
	if err != nil {
		writeError(w, http.StatusInternalServerError, "internal_error", "begin tx: "+err.Error())
		return
	}
	defer tx.Rollback()

	// Base-row preconditions (§11.6.2). These are on
	// ledger_request_credits, NOT on ledger_quarantine_resolutions.
	var baseExists int
	var quarantined int
	var requestID string
	var attemptN int64
	var providerID string
	var quarantineReason sql.NullString
	row := tx.QueryRowContext(ctx, `
SELECT 1, quarantined, request_id, attempt_n, provider_id, quarantine_reason
  FROM ledger_request_credits WHERE id = ?`, requestCreditID)
	if err := row.Scan(&baseExists, &quarantined, &requestID, &attemptN, &providerID, &quarantineReason); err != nil {
		if errors.Is(err, sql.ErrNoRows) {
			writeError(w, http.StatusNotFound, "not_found", "not found")
			return
		}
		writeError(w, http.StatusInternalServerError, "internal_error", "lookup: "+err.Error())
		return
	}
	if quarantined != 1 {
		writeValidationError(w, "not_quarantined", "ledger_request_credits row is not quarantined")
		return
	}

	// Resolution INSERT. Race protection is the UNIQUE constraint
	// (§11.6.6); we do NOT pre-check ledger_quarantine_resolutions.
	now := time.Now().UTC().Format(time.RFC3339Nano)
	_, err = tx.ExecContext(ctx, `
INSERT INTO ledger_quarantine_resolutions
    (request_credit_id, resolution_kind, operator_id, resolution_reason, created_at_utc)
VALUES (?, ?, ?, ?, ?)`, requestCreditID, resolutionKindVoid, operatorID, reason, now)
	if err != nil {
		if isSQLiteUniqueConstraint(err) {
			// Release the conn (MaxOpenConns(1) on the shared *sql.DB
			// — issue #21 / ARCH-3) BEFORE re-reading via h.store.db,
			// otherwise the re-read deadlocks until ctx expires.
			tx.Rollback()
			h.respondAlreadyResolved(w, ctx, nil, requestCreditID)
			return
		}
		writeError(w, http.StatusInternalServerError, "internal_error", "insert resolution: "+err.Error())
		return
	}

	// Audit-log INSERT through the SAME *sql.Tx (§11.6.4
	// insertion-path requirement). Must use json.Marshal — no
	// hand-rolled JSON.
	payload := map[string]any{
		"severity":             "WARN",
		"operator_attribution": operatorAttribution,
		"operator_id":          operatorID,
		"request_credit_id":    requestCreditID,
		"request_id":           requestID,
		"attempt_n":            attemptN,
		"provider_id":          providerID,
		"quarantine_reason":    nullStringOrNil(quarantineReason),
		"resolution_reason":    reason,
		"ts_utc":               now,
	}
	payloadJSON, err := json.Marshal(payload)
	if err != nil {
		writeError(w, http.StatusInternalServerError, "internal_error", "marshal audit payload: "+err.Error())
		return
	}
	if _, err := tx.ExecContext(ctx, `
INSERT INTO audit_log (ts_utc, event_type, provider_id, payload_json)
VALUES (?, ?, ?, ?)`, now, eventForceVoid, providerID, string(payloadJSON)); err != nil {
		writeError(w, http.StatusInternalServerError, "internal_error", "insert audit: "+err.Error())
		return
	}

	if err := tx.Commit(); err != nil {
		writeError(w, http.StatusInternalServerError, "internal_error", "commit: "+err.Error())
		return
	}

	writeJSON(w, http.StatusOK, map[string]any{
		"request_credit_id": requestCreditID,
		"resolution_kind":   resolutionKindVoid,
		"operator_id":       operatorID,
		"resolution_reason": reason,
		"created_at_utc":    now,
	})
}

// respondAlreadyResolved reads the existing resolution row and emits
// the SPEC-005 §11.6.2 409 envelope. tx may be the same transaction
// (which will be rolled back by the defer); we don't need a fresh
// reader because the row is committed by definition.
func (h *handler) respondAlreadyResolved(w http.ResponseWriter, ctx context.Context, _ *sql.Tx, requestCreditID int64) {
	// Use the DB handle (not the failing tx) so the SELECT sees the
	// committed winner row even though our tx is about to roll back.
	var (
		kind      string
		opID      string
		reason    string
		createdAt string
	)
	err := h.store.db.QueryRowContext(ctx, `
SELECT resolution_kind, operator_id, resolution_reason, created_at_utc
  FROM ledger_quarantine_resolutions WHERE request_credit_id = ?`,
		requestCreditID).Scan(&kind, &opID, &reason, &createdAt)
	if err != nil {
		// UNIQUE fired but the row vanished? Treat as 500 — should
		// never happen because the constraint precludes deletion.
		writeError(w, http.StatusInternalServerError, "internal_error", "re-read existing resolution: "+err.Error())
		return
	}
	body := map[string]any{
		"error": map[string]any{
			"code":    "already_resolved",
			"message": "row already resolved",
			"existing_resolution": map[string]any{
				"request_credit_id": requestCreditID,
				"resolution_kind":   kind,
				"operator_id":       opID,
				"resolution_reason": reason,
				"created_at_utc":    createdAt,
			},
		},
	}
	writeJSON(w, http.StatusConflict, body)
}

type forceVoidBody struct {
	OperatorID string `json:"operator_id"`
	Reason     string `json:"reason"`
}

// decodeForceVoidBody parses + validates the JSON shape (presence of
// fields, no unknown keys, no duplicate keys) per §11.6.1.1.
func decodeForceVoidBody(w http.ResponseWriter, r *http.Request) (forceVoidBody, bool) {
	var raw map[string]json.RawMessage
	dec := json.NewDecoder(r.Body)
	dec.DisallowUnknownFields()
	if err := dec.Decode(&raw); err != nil {
		// http.MaxBytesError → 413; any other JSON error → 400.
		var mbErr *http.MaxBytesError
		if errors.As(err, &mbErr) {
			writeError(w, http.StatusRequestEntityTooLarge, "request_too_large", "body exceeds 4 KiB")
		} else {
			writeError(w, http.StatusBadRequest, "bad_request", "invalid json body")
		}
		return forceVoidBody{}, false
	}
	if dec.More() {
		writeError(w, http.StatusBadRequest, "bad_request", "body must contain a single JSON object")
		return forceVoidBody{}, false
	}
	body := forceVoidBody{}
	if raw == nil {
		writeError(w, http.StatusBadRequest, "bad_request", "body must be a JSON object")
		return body, false
	}
	opRaw, hasOp := raw["operator_id"]
	if !hasOp {
		writeValidationError(w, "missing_field", "operator_id is required")
		return body, false
	}
	reasonRaw, hasReason := raw["reason"]
	if !hasReason {
		writeValidationError(w, "missing_field", "reason is required")
		return body, false
	}
	if err := json.Unmarshal(opRaw, &body.OperatorID); err != nil {
		writeValidationError(w, "bad_operator_id", "operator_id must be a JSON string")
		return body, false
	}
	if err := json.Unmarshal(reasonRaw, &body.Reason); err != nil {
		writeValidationError(w, "unsanitized_reason", "reason must be a JSON string")
		return body, false
	}
	return body, true
}

// validateOperatorID returns the 422 `code` string for the first
// rejection condition, or "" if valid.
func validateOperatorID(s string) string {
	if !utf8.ValidString(s) {
		return "invalid_utf8"
	}
	t := strings.TrimSpace(s)
	if t == "" || len(t) > maxOperatorIDLen {
		return "bad_operator_id"
	}
	for _, r := range t {
		switch {
		case r >= 'A' && r <= 'Z':
		case r >= 'a' && r <= 'z':
		case r >= '0' && r <= '9':
		case r == '_' || r == '.' || r == '-':
		default:
			return "bad_operator_id"
		}
	}
	return ""
}

// validateReason returns the 422 `code` string for the first
// rejection condition, or "" if valid. Per SPEC-005 v0.4 §11.6.3.
func validateReason(s string) string {
	if !utf8.ValidString(s) {
		return "invalid_utf8"
	}
	t := strings.TrimSpace(s)
	if t == "" {
		return "empty_reason"
	}
	if utf8.RuneCountInString(t) > maxReasonLen {
		return "reason_too_long"
	}
	for _, r := range t {
		if isRejectedCodepoint(r) {
			return "unsanitized_reason"
		}
	}
	return ""
}

// isRejectedCodepoint returns true for code points SPEC-005 v0.4
// §11.6.3 rejects: C0 / DEL, C1 controls, Unicode bidi / format,
// zero-width / BOM, variation selectors, tag chars, private-use,
// plus the full Unicode 16.0 Default_Ignorable_Code_Point set.
func isRejectedCodepoint(r rune) bool {
	// C0 controls (allow tab / newline / CR per §11.6.3 #2).
	if r < 0x20 {
		switch r {
		case '\t', '\n', '\r':
			return false
		default:
			return true
		}
	}
	if r == 0x7F { // DEL
		return true
	}
	// C1 controls.
	if r >= 0x80 && r <= 0x9F {
		return true
	}
	// Default-ignorable + bidi + zero-width + format ranges per §11.6.3.
	// Sourced from Unicode 16.0 DerivedCoreProperties.txt
	// (Default_Ignorable_Code_Point=Yes).
	switch {
	case r == 0x00AD: // SOFT HYPHEN
		return true
	case r == 0x034F: // COMBINING GRAPHEME JOINER
		return true
	case r == 0x061C: // ARABIC LETTER MARK
		return true
	case r == 0x115F, r == 0x1160: // HANGUL fillers
		return true
	case r == 0x17B4, r == 0x17B5: // KHMER inherent markers
		return true
	case r >= 0x180B && r <= 0x180F: // Mongolian variation selectors + MVS + free VS
		return true
	case r >= 0x200B && r <= 0x200F: // ZWSP/ZWNJ/ZWJ/LRM/RLM
		return true
	case r >= 0x202A && r <= 0x202E: // bidi formatting
		return true
	case r >= 0x2060 && r <= 0x2064: // WORD JOINER + invisible operators
		return true
	case r == 0x2065: // reserved
		return true
	case r >= 0x2066 && r <= 0x2069: // bidi isolates
		return true
	case r >= 0x206A && r <= 0x206F: // deprecated format
		return true
	case r == 0x3164: // HANGUL FILLER
		return true
	case r >= 0xFE00 && r <= 0xFE0F: // variation selectors
		return true
	case r == 0xFEFF: // ZWNBSP / BOM
		return true
	case r == 0xFFA0: // HALFWIDTH HANGUL FILLER
		return true
	case r >= 0xFFF0 && r <= 0xFFF8: // reserved
		return true
	case r >= 0xE000 && r <= 0xF8FF: // BMP private-use
		return true
	case r >= 0x1BCA0 && r <= 0x1BCA3: // Duployan shorthand format
		return true
	case r >= 0x1D173 && r <= 0x1D17A: // musical notation format
		return true
	case r >= 0xE0000 && r <= 0xE007F: // tag chars (incl. LANGUAGE TAG)
		return true
	case r >= 0xE0080 && r <= 0xE00FF: // reserved tag range
		return true
	case r >= 0xE0100 && r <= 0xE01EF: // variation selectors supplement
		return true
	case r >= 0xE01F0 && r <= 0xE0FFF: // reserved supplementary tag plane
		return true
	case r >= 0xF0000 && r <= 0xFFFFD: // supplementary private-use plane A
		return true
	case r >= 0x100000 && r <= 0x10FFFD: // supplementary private-use plane B
		return true
	}
	return false
}

func isJSONContentType(ct string) bool {
	// Accept "application/json" with optional ;charset / params.
	semi := strings.IndexByte(ct, ';')
	base := ct
	if semi >= 0 {
		base = ct[:semi]
	}
	return strings.EqualFold(strings.TrimSpace(base), "application/json")
}

func isSQLiteUniqueConstraint(err error) bool {
	if err == nil {
		return false
	}
	var sqErr *sqlite.Error
	if errors.As(err, &sqErr) {
		switch sqErr.Code() {
		case sqlite3errs.SQLITE_CONSTRAINT_UNIQUE, sqlite3errs.SQLITE_CONSTRAINT_PRIMARYKEY:
			return true
		}
	}
	// Defensive fallback for drivers that don't expose Code() —
	// modernc.org/sqlite does, but if the wrapper changes:
	return strings.Contains(strings.ToLower(fmt.Sprint(err)), "unique constraint")
}

func nullStringOrNil(s sql.NullString) any {
	if !s.Valid {
		return nil
	}
	return s.String
}

// writeValidationError emits a 422 with the SPEC-005 v0.4 §11.6.1.1
// `code` enum.
func writeValidationError(w http.ResponseWriter, code, msg string) {
	writeError(w, http.StatusUnprocessableEntity, code, msg)
}
