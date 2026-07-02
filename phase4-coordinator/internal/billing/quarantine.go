package billing

import (
	"bytes"
	"context"
	"database/sql"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"net/http"
	"strconv"
	"strings"
	"time"
	"unicode/utf8"

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

// quarantinePathMatch distinguishes three cases:
//   - matched=false: path doesn't look like /admin/ledger/quarantine/.../force-void;
//     dispatcher should fall through to existing routing.
//   - matched=true, badID=true: the route shape matches but the id is
//     malformed (non-decimal or int64 overflow). SPEC-005 §11.6.1.1
//     requires HTTP 400 `bad_request`.
//   - matched=true, badID=false: id parsed cleanly; handler proceeds.
type quarantinePathMatch struct {
	matched bool
	badID   bool
	id      int64
	kind    string
}

func matchQuarantinePath(path string) quarantinePathMatch {
	if !strings.HasPrefix(path, quarantinePathPrefix) {
		return quarantinePathMatch{}
	}
	rest := path[len(quarantinePathPrefix):]
	if !strings.HasSuffix(rest, forceVoidPathSuffix) {
		return quarantinePathMatch{}
	}
	idStr := rest[:len(rest)-len(forceVoidPathSuffix)]
	// At this point the path SHAPE matches the force-void route.
	// Anything wrong with the id field is now a §11.6.1.1 400, not a
	// 404 fall-through.
	if idStr == "" {
		return quarantinePathMatch{matched: true, badID: true, kind: "force-void"}
	}
	for _, c := range idStr {
		if c < '0' || c > '9' {
			return quarantinePathMatch{matched: true, badID: true, kind: "force-void"}
		}
	}
	id, err := strconv.ParseInt(idStr, 10, 64)
	if err != nil {
		return quarantinePathMatch{matched: true, badID: true, kind: "force-void"}
	}
	return quarantinePathMatch{matched: true, badID: false, id: id, kind: "force-void"}
}

// forceVoidHandler implements POST /admin/ledger/quarantine/{id}/force-void
// per SPEC-005 v0.4 §11.6.1.
func (h *handler) forceVoidHandler(w http.ResponseWriter, r *http.Request, requestCreditID int64) {
	// The dispatcher has already enforced the route launch gate,
	// operator auth, admin rate limit, method, and id shape before
	// entering this mutation handler.
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
	operatorID := trimSpaceASCII(body.OperatorID)
	reason := trimSpaceASCII(body.Reason)

	ctx, cancel := context.WithTimeout(r.Context(), 5*time.Second)
	defer cancel()

	// All operational work happens inside one BEGIN IMMEDIATE
	// transaction per SPEC-005 §11.6.2 — the resolution INSERT and
	// the audit_log INSERT share atomicity. The audit row is
	// written via the same *sql.Tx (NOT via audit.Store.Insert)
	// because the audit Store opens a separate *sql.DB handle and
	// cannot participate in this transaction.
	//
	// modernc.org/sqlite's `BeginTx(LevelSerializable)` does NOT map
	// to `BEGIN IMMEDIATE` unless the driver is configured with
	// `?_txlock=immediate` in the DSN. We don't control the DSN here
	// (shared with requestlog), so we acquire a dedicated conn and
	// execute `BEGIN IMMEDIATE` explicitly. The same conn is then
	// used for the resolution + audit INSERTs and the COMMIT.
	conn, err := h.store.db.Conn(ctx)
	if err != nil {
		writeError(w, http.StatusInternalServerError, "internal_error", "acquire conn: "+err.Error())
		return
	}
	defer conn.Close()
	if _, err := conn.ExecContext(ctx, `BEGIN IMMEDIATE`); err != nil {
		writeError(w, http.StatusInternalServerError, "internal_error", "begin immediate: "+err.Error())
		return
	}
	committed := false
	defer func() {
		if !committed {
			_, _ = conn.ExecContext(context.Background(), `ROLLBACK`)
		}
	}()

	// Base-row preconditions (§11.6.2). These are on
	// ledger_request_credits, NOT on ledger_quarantine_resolutions.
	var baseExists int
	var quarantined int
	var requestID string
	var attemptN int64
	var providerID string
	var quarantineReason sql.NullString
	row := conn.QueryRowContext(ctx, `
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
	_, err = conn.ExecContext(ctx, `
INSERT INTO ledger_quarantine_resolutions
    (request_credit_id, resolution_kind, operator_id, resolution_reason, created_at_utc)
VALUES (?, ?, ?, ?, ?)`, requestCreditID, resolutionKindVoid, operatorID, reason, now)
	if err != nil {
		if isSQLiteUniqueConstraint(err) {
			// ROLLBACK + release conn (MaxOpenConns(1) on the shared
			// *sql.DB — issue #21 / ARCH-3) BEFORE re-reading via
			// h.store.db, otherwise the re-read deadlocks until ctx
			// expires.
			_, _ = conn.ExecContext(ctx, `ROLLBACK`)
			committed = true // suppress the deferred ROLLBACK
			conn.Close()
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
	if _, err := conn.ExecContext(ctx, `
INSERT INTO audit_log (ts_utc, event_type, provider_id, payload_json)
VALUES (?, ?, ?, ?)`, now, eventForceVoid, providerID, string(payloadJSON)); err != nil {
		writeError(w, http.StatusInternalServerError, "internal_error", "insert audit: "+err.Error())
		return
	}

	if _, err := conn.ExecContext(ctx, `COMMIT`); err != nil {
		writeError(w, http.StatusInternalServerError, "internal_error", "commit: "+err.Error())
		return
	}
	committed = true

	writeJSON(w, http.StatusOK, map[string]any{
		"request_credit_id": requestCreditID,
		"resolution_kind":   resolutionKindVoid,
		"operator_id":       operatorID,
		"resolution_reason": reason,
		"created_at_utc":    now,
	})
}

// respondAlreadyResolved reads the existing resolution row and emits
// the SPEC-005 §11.6.2 409 envelope. The caller MUST release the
// transaction's connection BEFORE calling this — re-reading via
// `h.store.db` while a tx still holds the only conn deadlocks at
// `MaxOpenConns(1)` (issue #21 / ARCH-3).
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

// decodeForceVoidBody enforces §11.6.1.1 JSON strictness:
//   - reject invalid UTF-8 in the raw body (BEFORE json decode would
//     normalize to U+FFFD)
//   - reject duplicate top-level keys (json.Decoder + map silently
//     collapses; we token-scan to catch them)
//   - reject unknown top-level keys (DisallowUnknownFields only
//     applies to struct decode; map decode ignores it)
//   - reject non-object top-level / multi-value bodies
//   - distinguish 413 (body too large) from 400 (other JSON errors).
func decodeForceVoidBody(w http.ResponseWriter, r *http.Request) (forceVoidBody, bool) {
	body := forceVoidBody{}
	raw, err := io.ReadAll(r.Body)
	if err != nil {
		var mbErr *http.MaxBytesError
		if errors.As(err, &mbErr) {
			writeError(w, http.StatusRequestEntityTooLarge, "request_too_large", "body exceeds 4 KiB")
		} else {
			writeError(w, http.StatusBadRequest, "bad_request", "failed to read body")
		}
		return body, false
	}
	// R2 fix (SEC-M1 / CODE-H2): MaxBytesReader is set to
	// maxBodyBytes+1 above so a body of exactly 4097 bytes returns
	// without a MaxBytesError, but SPEC §11.6.1.1 rejects bodies
	// strictly greater than 4 KiB. Explicit post-read length check
	// closes the off-by-one for chunked / unknown-length requests.
	if len(raw) > maxBodyBytes {
		writeError(w, http.StatusRequestEntityTooLarge, "request_too_large", "body exceeds 4 KiB")
		return body, false
	}
	// SPEC §11.6.3 rule 1: UTF-8 well-formedness BEFORE any
	// JSON-induced normalization (json.Unmarshal silently replaces
	// invalid UTF-8 with U+FFFD).
	if !utf8.Valid(raw) {
		writeValidationError(w, "invalid_utf8", "body is not valid UTF-8")
		return body, false
	}
	// Token-scan the top-level object to enforce SPEC §11.6.1.1
	// duplicate / unknown key rules.
	dec := json.NewDecoder(bytes.NewReader(raw))
	tok, err := dec.Token()
	if err != nil {
		writeError(w, http.StatusBadRequest, "bad_request", "invalid json body")
		return body, false
	}
	if d, ok := tok.(json.Delim); !ok || d != '{' {
		writeError(w, http.StatusBadRequest, "bad_request", "body must be a JSON object")
		return body, false
	}
	seenKeys := map[string]bool{}
	allowedKeys := map[string]bool{"operator_id": true, "reason": true}
	rawFields := map[string]json.RawMessage{}
	for dec.More() {
		keyTok, err := dec.Token()
		if err != nil {
			writeError(w, http.StatusBadRequest, "bad_request", "invalid json body")
			return body, false
		}
		key, ok := keyTok.(string)
		if !ok {
			writeError(w, http.StatusBadRequest, "bad_request", "invalid json body")
			return body, false
		}
		if seenKeys[key] {
			writeError(w, http.StatusBadRequest, "bad_request", "duplicate key: "+key)
			return body, false
		}
		seenKeys[key] = true
		if !allowedKeys[key] {
			writeError(w, http.StatusBadRequest, "bad_request", "unknown key: "+key)
			return body, false
		}
		var val json.RawMessage
		if err := dec.Decode(&val); err != nil {
			writeError(w, http.StatusBadRequest, "bad_request", "invalid json value for "+key)
			return body, false
		}
		rawFields[key] = val
	}
	// Closing `}`.
	if tok, err := dec.Token(); err != nil {
		writeError(w, http.StatusBadRequest, "bad_request", "invalid json body")
		return body, false
	} else if d, ok := tok.(json.Delim); !ok || d != '}' {
		writeError(w, http.StatusBadRequest, "bad_request", "invalid json body")
		return body, false
	}
	// R2 fix (CODE-H3): dec.More() only reports remaining elements
	// inside the current array/object; once we've consumed the
	// top-level `}` we must explicitly require io.EOF, otherwise
	// `{...} {}` or `{...} 42` would be accepted.
	if _, err := dec.Token(); err != io.EOF {
		writeError(w, http.StatusBadRequest, "bad_request", "body must contain a single JSON object")
		return body, false
	}
	opRaw, hasOp := rawFields["operator_id"]
	if !hasOp {
		writeValidationError(w, "missing_field", "operator_id is required")
		return body, false
	}
	reasonRaw, hasReason := rawFields["reason"]
	if !hasReason {
		writeValidationError(w, "missing_field", "reason is required")
		return body, false
	}
	// R5 fix (CODE-M1): wrong field TYPES are body-shape errors, not
	// value-content validation errors. Mapping them to 400 bad_request
	// (rather than 422 bad_operator_id / unsanitized_reason) is the
	// semantically correct posture: the body's JSON structure is
	// malformed, not the operator's chosen identity. 422 is reserved
	// for cases where the JSON shape is valid but the field value is
	// rejected by the §11.6.3 sanitizer (control chars, charset,
	// length, etc.).
	if err := json.Unmarshal(opRaw, &body.OperatorID); err != nil {
		writeError(w, http.StatusBadRequest, "bad_request", "operator_id must be a JSON string")
		return body, false
	}
	if err := json.Unmarshal(reasonRaw, &body.Reason); err != nil {
		writeError(w, http.StatusBadRequest, "bad_request", "reason must be a JSON string")
		return body, false
	}
	// Defense-in-depth: even though we pre-validated raw body UTF-8,
	// the post-unmarshal value MAY contain U+FFFD from a
	// well-formed-UTF-8 JSON `\uXXXX` escape that decodes to a lone
	// surrogate. Reject as `invalid_utf8` so the audit log byte
	// content matches the operator's input.
	if strings.ContainsRune(body.OperatorID, utf8.RuneError) {
		writeValidationError(w, "invalid_utf8", "operator_id contains invalid surrogate escape")
		return body, false
	}
	if strings.ContainsRune(body.Reason, utf8.RuneError) {
		writeValidationError(w, "invalid_utf8", "reason contains invalid surrogate escape")
		return body, false
	}
	return body, true
}

// trimSpaceASCII trims ONLY the §11.6.3 whitespace set (`\t \n \r
// \v \f` + ASCII space 0x20). Avoids `strings.TrimSpace`, which
// removes Unicode whitespace like U+0085 (NEL) — those bytes are
// part of the C1 control range that §11.6.3 wants the sanitizer to
// REJECT, not silently strip.
func trimSpaceASCII(s string) string {
	start := 0
	for start < len(s) {
		c := s[start]
		if c == ' ' || c == '\t' || c == '\n' || c == '\r' || c == '\v' || c == '\f' {
			start++
			continue
		}
		break
	}
	end := len(s)
	for end > start {
		c := s[end-1]
		if c == ' ' || c == '\t' || c == '\n' || c == '\r' || c == '\v' || c == '\f' {
			end--
			continue
		}
		break
	}
	return s[start:end]
}

// validateOperatorID returns the 422 `code` string for the first
// rejection condition, or "" if valid.
func validateOperatorID(s string) string {
	if !utf8.ValidString(s) {
		return "invalid_utf8"
	}
	t := trimSpaceASCII(s)
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
	t := trimSpaceASCII(s)
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
