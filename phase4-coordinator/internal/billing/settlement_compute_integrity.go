package billing

import (
	"bytes"
	"context"
	"database/sql"
	"encoding/json"
	"fmt"
	"regexp"
	"time"

	"github.com/augstar/macprovider-coordinator/internal/computeintegrity"
)

var computeIntegrityDigestPattern = regexp.MustCompile(`^sha256:[0-9a-f]{64}$`)

// InsertComputeIntegrityCapture persists the immutable SPEC-036 request-start
// capture for a route snapshot that explicitly requires compute-integrity gating.
func (s *Store) InsertComputeIntegrityCapture(ctx context.Context, id SettlementReceiptIdentity, capture computeintegrity.Capture, requestSamplingProfileCovered bool, routeSnapshotHardwareClassDigest string) (string, error) {
	if s == nil {
		return "", fmt.Errorf("billing store is nil")
	}
	if err := id.validate(); err != nil {
		return "", err
	}
	if !computeIntegrityDigestPattern.MatchString(routeSnapshotHardwareClassDigest) {
		return "", fmt.Errorf("compute integrity route snapshot hardware class digest invalid")
	}
	raw, err := json.Marshal(capture)
	if err != nil {
		return "", err
	}
	digest, err := computeintegrity.RequestStartSnapshotDigest(capture)
	if err != nil {
		return "", err
	}
	if capture.CapturedAtUnixMS <= 0 {
		return "", fmt.Errorf("compute integrity captured_at must be positive")
	}
	_, err = s.db.ExecContext(ctx, `
INSERT INTO settlement_compute_integrity_captures (
    account_scope, request_id, attempt_n, provider_id,
    capture_required, request_sampling_profile_covered, route_snapshot_hardware_class_digest,
    capture_json, request_start_snapshot_digest, captured_at_unix_ms, created_at_utc
) VALUES (?, ?, ?, ?, 1, ?, ?, ?, ?, ?, ?)
`,
		id.AccountScope, id.RequestID, id.AttemptN, id.ProviderID,
		boolInt(requestSamplingProfileCovered), routeSnapshotHardwareClassDigest,
		string(raw), digest, capture.CapturedAtUnixMS, time.Now().UTC().Format(time.RFC3339Nano),
	)
	if err != nil {
		return "", err
	}
	return digest, nil
}

// MarkComputeIntegrityCaptureRequired records that a covered enforce row required
// SPEC-036 request-start capture, but capture material was unavailable/unreadable.
// Settlement consumes this marker as fail-closed compute_integrity_unreadable.
func (s *Store) MarkComputeIntegrityCaptureRequired(ctx context.Context, id SettlementReceiptIdentity, requestSamplingProfileCovered bool, routeSnapshotHardwareClassDigest string) error {
	if s == nil {
		return fmt.Errorf("billing store is nil")
	}
	if err := id.validate(); err != nil {
		return err
	}
	if !computeIntegrityDigestPattern.MatchString(routeSnapshotHardwareClassDigest) {
		return fmt.Errorf("compute integrity route snapshot hardware class digest invalid")
	}
	_, err := s.db.ExecContext(ctx, `
INSERT INTO settlement_compute_integrity_captures (
    account_scope, request_id, attempt_n, provider_id,
    capture_required, request_sampling_profile_covered, route_snapshot_hardware_class_digest,
    capture_json, request_start_snapshot_digest, captured_at_unix_ms, created_at_utc
) VALUES (?, ?, ?, ?, 1, ?, ?, NULL, NULL, NULL, ?)
`,
		id.AccountScope, id.RequestID, id.AttemptN, id.ProviderID,
		boolInt(requestSamplingProfileCovered), routeSnapshotHardwareClassDigest,
		time.Now().UTC().Format(time.RFC3339Nano),
	)
	return err
}

func loadComputeIntegrityCaptureConn(ctx context.Context, conn *sql.Conn, id SettlementReceiptIdentity, route RouteSnapshot) (*computeintegrity.Capture, error) {
	if route.RouteSnapshotMode != RouteSnapshotModeEnforce || !route.ComputeIntegrityCaptureRequired {
		return nil, nil
	}
	var captureRequired, samplingCovered int
	var routeSnapshotHardwareDigest string
	var raw, storedDigest sql.NullString
	err := conn.QueryRowContext(ctx, `
SELECT capture_required, request_sampling_profile_covered, route_snapshot_hardware_class_digest,
       capture_json, request_start_snapshot_digest
FROM settlement_compute_integrity_captures
WHERE account_scope = ? AND request_id = ? AND attempt_n = ? AND provider_id = ?`,
		id.AccountScope, id.RequestID, id.AttemptN, id.ProviderID,
	).Scan(&captureRequired, &samplingCovered, &routeSnapshotHardwareDigest, &raw, &storedDigest)
	if err != nil {
		if err == sql.ErrNoRows {
			capture := computeintegrity.Capture{Unreadable: true}
			capture.RequestSamplingProfileCovered = route.ComputeIntegritySamplingCovered
			capture.RouteSnapshotHardwareClassDigest = route.ComputeIntegrityHardwareDigest
			return &capture, nil
		}
		return nil, err
	}
	var capture computeintegrity.Capture
	if captureRequired != 1 || !raw.Valid {
		capture = computeintegrity.Capture{Unreadable: true}
		capture.RequestSamplingProfileCovered = route.ComputeIntegritySamplingCovered
		capture.RouteSnapshotHardwareClassDigest = route.ComputeIntegrityHardwareDigest
		return &capture, nil
	}
	capture, ok := decodeComputeIntegrityCapture(raw.String)
	if !ok {
		capture = computeintegrity.Capture{Unreadable: true}
	}
	capture.RequestSamplingProfileCovered = route.ComputeIntegritySamplingCovered
	capture.RouteSnapshotHardwareClassDigest = route.ComputeIntegrityHardwareDigest
	routeDigest, _, routeErr := route.Digest()
	if routeErr != nil ||
		samplingCovered != boolInt(route.ComputeIntegritySamplingCovered) ||
		routeSnapshotHardwareDigest != route.ComputeIntegrityHardwareDigest ||
		capture.ProviderID != route.ProviderID ||
		capture.ModelID != route.ModelID ||
		capture.TargetModelHash != route.ProviderReportedModelHash ||
		capture.TargetModelHash != route.ExpectedCatalogModelHash ||
		capture.SignedCatalogDigest != "sha256:"+route.CatalogBodyDigest ||
		capture.CapturedAtUnixMS != route.RequestStartTSUnixMS ||
		capture.Spec022PolicyVersion != route.RouteSnapshotPolicyVersion ||
		capture.Spec022PolicyMode != route.RouteSnapshotMode ||
		!capture.Spec022EffectiveEnforce ||
		capture.Spec022RouteSnapshotDigest != routeDigest {
		capture.Unreadable = true
	}
	if !storedDigest.Valid {
		capture.Unreadable = true
		return &capture, nil
	}
	computed, digestErr := computeintegrity.RequestStartSnapshotDigest(capture)
	if digestErr != nil || computed != storedDigest.String {
		capture.Unreadable = true
	}
	return &capture, nil
}

func decodeComputeIntegrityCapture(raw string) (computeintegrity.Capture, bool) {
	var fields map[string]json.RawMessage
	dec := json.NewDecoder(bytes.NewReader([]byte(raw)))
	dec.UseNumber()
	if err := dec.Decode(&fields); err != nil {
		return computeintegrity.Capture{}, false
	}
	if len(fields) == 0 {
		return computeintegrity.Capture{}, false
	}
	dec = json.NewDecoder(bytes.NewReader([]byte(raw)))
	dec.UseNumber()
	dec.DisallowUnknownFields()
	var capture computeintegrity.Capture
	if err := dec.Decode(&capture); err != nil {
		return computeintegrity.Capture{}, false
	}
	if _, ok := fields["circuit_breaker_active"]; ok {
		capture.BreakerFieldsPresent = true
	}
	return capture, true
}
