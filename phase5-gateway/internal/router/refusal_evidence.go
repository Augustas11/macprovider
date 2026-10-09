package router

import (
	"bytes"
	"context"
	"crypto/subtle"
	"encoding/json"
	"errors"
	"io"
	"log/slog"
	"net/http"
	"regexp"
	"strings"
	"time"

	"github.com/augstar/macprovider-gateway/internal/sourceevidence"
	"github.com/augstar/macprovider-gateway/internal/storage"
)

// SPEC-006 §5.4.3.3: the gateway records pool-relevant refusals with a
// private-keyed intent commitment, and an operator-only export signs a
// projection of those records bound to a caller-held intent. Neither path
// changes any buyer response, quota decision or timing.

const (
	refusalEvidenceExportPath = "/admin/evidence/source-exports/gateway-v1"
	refusalRecordWriteTimeout = 2 * time.Second
)

var (
	refusalErrorCodeRE = regexp.MustCompile(`^[a-z][a-z0-9_]{0,63}$`)
	refusalRunIDRE     = regexp.MustCompile(`^[A-Za-z0-9._:-]{1,128}$`)
	refusalNonceRE     = regexp.MustCompile(`^[A-Za-z0-9_-]{43}$`)
	refusalLookupRE    = regexp.MustCompile(`^[ -~]{1,128}$`)
	refusalIntentRE    = regexp.MustCompile(`^[ -~]{0,256}$`)
)

// refusalRecordStore is implemented by the sqlite store. It is an optional
// capability so test stores that predate it keep compiling.
type refusalRecordStore interface {
	InsertRefusalRecord(ctx context.Context, rec storage.RefusalRecord, retention time.Duration) error
	ResolveRefusalRecords(ctx context.Context, keys []storage.RefusalRecordKey) ([]storage.ResolvedRefusalRecord, error)
}

type refusalEvidence struct {
	intentKey []byte
	retention time.Duration
	signer    *sourceevidence.Signer
	maxScopes int
}

// WithRefusalEvidence enables the refusal record (and, with a non-nil
// signer, its export). Without it the gateway records nothing.
func WithRefusalEvidence(intentKey []byte, retention time.Duration, signer *sourceevidence.Signer, maxScopes int) Option {
	return func(s *Server) {
		if len(intentKey) == 0 {
			return
		}
		if maxScopes <= 0 || maxScopes > sourceevidence.AbsoluteMaxScopes {
			maxScopes = sourceevidence.DefaultMaxScopes
		}
		s.refusalEvidence = &refusalEvidence{intentKey: append([]byte(nil), intentKey...), retention: retention, signer: signer, maxScopes: maxScopes}
	}
}

// firstSelectorValue is the first non-empty trimmed header value, the same
// value resolvePoolSelection / resolveEngineSelection evaluate first.
func firstSelectorValue(headers http.Header, name string) string {
	for _, raw := range headers.Values(name) {
		if v := strings.TrimSpace(raw); v != "" {
			return v
		}
	}
	return ""
}

// recordRefusal writes the SPEC-006 §5.4.3.3 record for a pool-relevant
// API-key refusal. A failure is logged without request material and changes
// nothing the buyer sees.
func (s *Server) recordRefusal(r *http.Request, subject usageSubject, model, terminal string, status int, code string) {
	ev := s.refusalEvidence
	if ev == nil || subject.AccountID == "" || subject.DemoIdentity != "" || subject.WalletSessionID != "" {
		return
	}
	poolSelect := firstSelectorValue(r.Header, poolSelectHeader)
	if poolSelect == "" && !strings.HasPrefix(model, "pool/") {
		return
	}
	store, ok := s.store.(refusalRecordStore)
	if !ok {
		return
	}
	if !refusalErrorCodeRE.MatchString(code) {
		code = "unclassified"
	}
	intent := sourceevidence.Intent{
		AccountID:         subject.AccountID,
		ExternalRequestID: requestID(r),
		Model:             model,
		PoolSelect:        poolSelect,
		EngineSelect:      firstSelectorValue(r.Header, engineSelectHeader),
	}
	ctx, cancel := context.WithTimeout(context.Background(), refusalRecordWriteTimeout)
	defer cancel()
	err := store.InsertRefusalRecord(ctx, storage.RefusalRecord{
		AccountID:         intent.AccountID,
		ExternalRequestID: intent.ExternalRequestID,
		IntentCommitment:  sourceevidence.IntentCommitment(ev.intentKey, intent),
		TerminalKind:      terminal,
		Status:            status,
		ErrorCode:         code,
		Forwarded:         terminal == storage.RefusalTerminalPostReservation,
		RecordedAt:        s.now().UTC(),
	}, ev.retention)
	if err != nil {
		slog.Warn("gateway refusal record write failed", "terminal_kind", terminal, "error", err)
	}
}

type refusalExportRequest struct {
	SchemaVersion  string                  `json:"schema_version"`
	RunID          string                  `json:"run_id"`
	ChallengeNonce string                  `json:"challenge_nonce"`
	Scopes         []sourceevidence.Intent `json:"scopes"`
}

var errRefusalExportUnprovable = errors.New("refusal export scope is not provable")

func (s *Server) handleRefusalEvidenceExport(w http.ResponseWriter, r *http.Request) {
	w.Header().Set("Cache-Control", "no-store")
	if r.Method != http.MethodPost {
		writeError(w, http.StatusMethodNotAllowed, "invalid_request_error", "method_not_allowed", "Method not allowed")
		return
	}
	if !s.operatorAuthorized(w, r) {
		return
	}
	ev := s.refusalEvidence
	store, ok := s.store.(refusalRecordStore)
	if ev == nil || ev.signer == nil || !ok {
		writeError(w, http.StatusServiceUnavailable, "service_unavailable", "source_export_unavailable", "Source export unavailable")
		return
	}
	var req refusalExportRequest
	if err := decodeStrictBody(r, sourceevidence.DefaultMaxBodyBytes, &req); err != nil || !validRefusalExportRequest(req, ev.maxScopes) {
		writeError(w, http.StatusBadRequest, "invalid_request_error", "invalid_source_export_request", "Invalid source export request")
		return
	}
	envelope, err := s.exportRefusalRecords(r.Context(), store, ev, req)
	if err != nil {
		writeError(w, http.StatusConflict, "invalid_request_error", "source_export_not_provable", "Source export not provable")
		return
	}
	writeJSON(w, http.StatusOK, envelope)
}

func validRefusalExportRequest(req refusalExportRequest, maxScopes int) bool {
	if req.SchemaVersion != sourceevidence.RequestSchema || !refusalRunIDRE.MatchString(req.RunID) || !refusalNonceRE.MatchString(req.ChallengeNonce) {
		return false
	}
	if len(req.Scopes) == 0 || len(req.Scopes) > maxScopes {
		return false
	}
	seen := map[storage.RefusalRecordKey]struct{}{}
	for _, scope := range req.Scopes {
		if !refusalLookupRE.MatchString(scope.AccountID) || !refusalLookupRE.MatchString(scope.ExternalRequestID) ||
			!refusalIntentRE.MatchString(scope.Model) || !refusalIntentRE.MatchString(scope.PoolSelect) || !refusalIntentRE.MatchString(scope.EngineSelect) {
			return false
		}
		key := storage.RefusalRecordKey{AccountID: scope.AccountID, ExternalRequestID: scope.ExternalRequestID}
		if _, dup := seen[key]; dup {
			return false
		}
		seen[key] = struct{}{}
	}
	return true
}

// exportRefusalRecords proves every scope or none: a missing record, an
// intent mismatch or any quota/debit predicate failure fails the export.
func (s *Server) exportRefusalRecords(ctx context.Context, store refusalRecordStore, ev *refusalEvidence, req refusalExportRequest) (map[string]any, error) {
	keys := make([]storage.RefusalRecordKey, len(req.Scopes))
	for i, scope := range req.Scopes {
		keys[i] = storage.RefusalRecordKey{AccountID: scope.AccountID, ExternalRequestID: scope.ExternalRequestID}
	}
	resolved, err := store.ResolveRefusalRecords(ctx, keys)
	if err != nil || len(resolved) != len(req.Scopes) {
		return nil, errRefusalExportUnprovable
	}
	generatedAt := ev.signer.Now()
	records := make([]map[string]any, 0, len(resolved))
	for i, res := range resolved {
		scope := req.Scopes[i]
		want := sourceevidence.IntentCommitment(ev.intentKey, scope)
		if subtle.ConstantTimeCompare([]byte(want), []byte(res.Record.IntentCommitment)) != 1 {
			return nil, errRefusalExportUnprovable
		}
		reservation, ok := provenRefusalQuota(res)
		if !ok || res.Record.RecordedAt.After(generatedAt) {
			return nil, errRefusalExportUnprovable
		}
		records = append(records, map[string]any{
			"schema_version":           sourceevidence.RecordSchema,
			"source":                   sourceevidence.ProducerName,
			"record_kind":              sourceevidence.ProducerRole,
			"request_scope_commitment": sourceevidence.IntentBinding(req.RunID, req.ChallengeNonce, scope),
			"terminal_kind":            res.Record.TerminalKind,
			"status":                   res.Record.Status,
			"error_code":               res.Record.ErrorCode,
			"forwarded_to_coordinator": res.Record.Forwarded,
			"quota": map[string]any{
				"reservation":     reservation,
				"settled_tokens":  0,
				"settlement_hold": 0,
			},
			"usage_debit_tokens": 0,
			"privacy": map[string]any{
				"raw_account_id_emitted":          false,
				"raw_external_request_id_emitted": false,
				"raw_rejected_model_emitted":      false,
				"raw_selector_emitted":            false,
			},
			"recorded_at": sourceevidence.UTCMillis(res.Record.RecordedAt),
		})
	}
	return ev.signer.Sign(req.RunID, req.ChallengeNonce, generatedAt, records)
}

// provenRefusalQuota applies the §5.4.3.3 predicates: a pre-quota refusal
// has no reservation and no usage row; a post-reservation refusal has
// exactly one refunded, zero-settled, unheld reservation and zero-token
// usage rows.
func provenRefusalQuota(res storage.ResolvedRefusalRecord) (string, bool) {
	switch res.Record.TerminalKind {
	case storage.RefusalTerminalPreQuota:
		if res.Record.Forwarded || res.ReservationCount != 0 || res.UsageRows != 0 {
			return "", false
		}
		return "none", true
	case storage.RefusalTerminalPostReservation:
		if !res.Record.Forwarded || res.ReservationCount != 1 || res.ReservationStatus != "refunded" ||
			res.ReservationSettled != 0 || res.ReservationHold != 0 || res.UsageTokens != 0 {
			return "", false
		}
		return "refunded", true
	}
	return "", false
}

func decodeStrictBody(r *http.Request, maxBytes int64, dst any) error {
	body, err := io.ReadAll(io.LimitReader(r.Body, maxBytes+1))
	if err != nil {
		return err
	}
	if int64(len(body)) > maxBytes {
		return errors.New("source export request too large")
	}
	dec := json.NewDecoder(bytes.NewReader(body))
	dec.DisallowUnknownFields()
	if err := dec.Decode(dst); err != nil {
		return err
	}
	if _, err := dec.Token(); err != io.EOF {
		return errors.New("source export request has trailing data")
	}
	return nil
}
