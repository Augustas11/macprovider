package main

import (
	"bytes"
	"encoding/json"
	"flag"
	"fmt"
	"io"
	"net"
	"net/http"
	"net/url"
	"os"
	"strings"
	"time"

	"github.com/augstar/macprovider-coordinator/internal/trustpool"
)

var trustPoolAdminHTTPClient = &http.Client{
	Timeout:       30 * time.Second,
	CheckRedirect: trustPoolAdminRejectRedirect,
}

func trustPoolAdminRejectRedirect(req *http.Request, via []*http.Request) error {
	return http.ErrUseLastResponse
}

func trustPoolAdmin(args []string, getenv func(string) string, stdin io.Reader, stdout io.Writer) error {
	if len(args) == 0 {
		return fmt.Errorf("trust-pool-admin subcommand required")
	}
	switch args[0] {
	case "upsert-creator":
		return trustPoolAdminJSONFile(args[1:], "upsert-creator", http.MethodPost, "/admin/trust-pools/creators", "", getenv, stdin, stdout)
	case "issue-root-nonce":
		return trustPoolAdminIssueRootNonce(args[1:], getenv, stdout)
	case "append-event":
		return trustPoolAdminJSONFile(args[1:], "append-event", http.MethodPost, "/admin/trust-pools/events", "", getenv, stdin, stdout)
	case "submit-policy":
		return trustPoolAdminJSONFile(args[1:], "submit-policy", http.MethodPost, "/admin/trust-pools/events", trustpool.EventManifestAccepted, getenv, stdin, stdout)
	case "create-pool":
		return trustPoolAdminEvent(args[1:], "create-pool", trustpool.EventPoolCreated, getenv, stdout)
	case "admit-provider":
		return trustPoolAdminEvent(args[1:], "admit-provider", trustpool.EventMemberAdmitted, getenv, stdout)
	case "revoke-provider":
		return trustPoolAdminEvent(args[1:], "revoke-provider", trustpool.EventMemberRevoked, getenv, stdout)
	case "authorize-buyer":
		return trustPoolAdminEvent(args[1:], "authorize-buyer", trustpool.EventBuyerAuthorized, getenv, stdout)
	case "remove-buyer-authorization":
		return trustPoolAdminEvent(args[1:], "remove-buyer-authorization", trustpool.EventBuyerAuthorizationRm, getenv, stdout)
	case "set-lifecycle":
		return trustPoolAdminEvent(args[1:], "set-lifecycle", trustpool.EventLifecycleChanged, getenv, stdout)
	case "set-binary-floor":
		return trustPoolAdminEvent(args[1:], "set-binary-floor", trustpool.EventMinBinaryVersionSet, getenv, stdout)
	case "promote":
		return trustPoolAdminPromote(args[1:], getenv, stdout)
	case "review-distribution-artifact":
		return trustPoolAdminReviewDistributionArtifact(args[1:], getenv, stdout)
	case "approve-public-announcement":
		return trustPoolAdminApprovePublicAnnouncement(args[1:], getenv, stdout)
	case "list-pools":
		return trustPoolAdminGET(args[1:], "list-pools", "/admin/trust-pools/pools", getenv, stdout)
	case "get-pool", "pool-status":
		return trustPoolAdminGETPool(args[1:], args[0], "", getenv, stdout)
	case "get-creator":
		return trustPoolAdminGETCreator(args[1:], getenv, stdout)
	case "fetch-health":
		return trustPoolAdminGETPool(args[1:], "fetch-health", "/health", getenv, stdout)
	case "export-audit":
		return trustPoolAdminGETPool(args[1:], "export-audit", "/audit", getenv, stdout)
	case "export-distribution":
		return trustPoolAdminGETPool(args[1:], "export-distribution", "/distribution", getenv, stdout)
	case "rotate-signer-set":
		return fmt.Errorf("rotate-signer-set is not implemented in the SPEC-043 candidate surface; submit a signed SPEC-042 authority-log event through append-event after signer-set support lands")
	default:
		return fmt.Errorf("unknown trust-pool-admin subcommand %q", args[0])
	}
}

type trustPoolAdminFlags struct {
	fs       *flag.FlagSet
	adminURL *string
	keyEnv   *string
}

func newTrustPoolAdminFlags(name string) trustPoolAdminFlags {
	fs := flag.NewFlagSet("trust-pool-admin "+name, flag.ContinueOnError)
	fs.SetOutput(io.Discard)
	return trustPoolAdminFlags{
		fs:       fs,
		adminURL: fs.String("admin-url", "", "coordinator admin base URL; defaults to MACPROVIDER_COORDINATOR_ADMIN_URL"),
		keyEnv:   fs.String("operator-key-env", "MACPROVIDER_OPERATOR_KEY", "environment variable containing operator bearer token"),
	}
}

func (f trustPoolAdminFlags) parse(args []string, getenv func(string) string) (string, string, error) {
	if err := f.fs.Parse(args); err != nil {
		return "", "", err
	}
	if f.fs.NArg() != 0 {
		return "", "", fmt.Errorf("unexpected positional arguments")
	}
	base := strings.TrimSpace(*f.adminURL)
	if base == "" {
		base = strings.TrimSpace(getenv("MACPROVIDER_COORDINATOR_ADMIN_URL"))
	}
	if base == "" {
		return "", "", fmt.Errorf("--admin-url or MACPROVIDER_COORDINATOR_ADMIN_URL is required")
	}
	base, err := validateTrustPoolAdminBaseURL(base)
	if err != nil {
		return "", "", err
	}
	keyEnv := strings.TrimSpace(*f.keyEnv)
	if keyEnv == "" {
		return "", "", fmt.Errorf("--operator-key-env is required")
	}
	key := strings.TrimSpace(getenv(keyEnv))
	if key == "" {
		return "", "", fmt.Errorf("--operator-key-env must name an environment variable containing the operator bearer token")
	}
	return base, key, nil
}

func validateTrustPoolAdminBaseURL(raw string) (string, error) {
	u, err := url.Parse(strings.TrimSpace(raw))
	if err != nil {
		return "", err
	}
	if u.Scheme != "https" && u.Scheme != "http" {
		return "", fmt.Errorf("--admin-url must use https, or http for loopback development")
	}
	if u.Hostname() == "" {
		return "", fmt.Errorf("--admin-url must include a host")
	}
	if u.RawQuery != "" || u.Fragment != "" {
		return "", fmt.Errorf("--admin-url must not include query or fragment")
	}
	if u.Scheme == "http" && !isLoopbackHost(u.Hostname()) {
		return "", fmt.Errorf("--admin-url may use http only for loopback hosts")
	}
	return strings.TrimRight(u.String(), "/"), nil
}

func isLoopbackHost(host string) bool {
	if strings.EqualFold(host, "localhost") {
		return true
	}
	ip := net.ParseIP(host)
	return ip != nil && ip.IsLoopback()
}

func trustPoolAdminJSONFile(args []string, name, method, path, requiredEventType string, getenv func(string) string, stdin io.Reader, stdout io.Writer) error {
	flags := newTrustPoolAdminFlags(name)
	input := flags.fs.String("input", "-", "JSON file path, or - for stdin")
	operationID := flags.fs.String("operation-id", "", "optional idempotency key header")
	base, key, err := flags.parse(args, getenv)
	if err != nil {
		return err
	}
	body, err := readCLIInput(*input, stdin)
	if err != nil {
		return err
	}
	if requiredEventType != "" {
		var event trustpool.DurableEvent
		if err := json.Unmarshal(body, &event); err != nil {
			return fmt.Errorf("invalid event JSON: %w", err)
		}
		if strings.TrimSpace(event.EventType) != requiredEventType {
			return fmt.Errorf("%s requires event_type=%q", name, requiredEventType)
		}
	}
	return trustPoolAdminRequest(method, base+path, key, strings.TrimSpace(*operationID), body, stdout)
}

func trustPoolAdminIssueRootNonce(args []string, getenv func(string) string, stdout io.Writer) error {
	flags := newTrustPoolAdminFlags("issue-root-nonce")
	creatorID := flags.fs.String("creator-account-id", "", "creator account id")
	approvalID := flags.fs.String("approval-record-id", "", "approval record id")
	approvalVersion := flags.fs.String("approval-version", "", "current approval version")
	environment := flags.fs.String("launch-environment", "", "launch environment")
	purpose := flags.fs.String("purpose", "", "nonce purpose; defaults to coordinator policy")
	expiresAtRaw := flags.fs.String("expires-at", "", "RFC3339/RFC3339Nano nonce expiry")
	operationID := flags.fs.String("operation-id", "", "idempotency key")
	base, key, err := flags.parse(args, getenv)
	if err != nil {
		return err
	}
	expiresAt, err := time.Parse(time.RFC3339Nano, strings.TrimSpace(*expiresAtRaw))
	if err != nil {
		return fmt.Errorf("--expires-at must be RFC3339/RFC3339Nano: %w", err)
	}
	if strings.TrimSpace(*operationID) == "" {
		return fmt.Errorf("--operation-id is required")
	}
	issue := trustpool.RootRegistrationNonceIssue{
		OperationID:            strings.TrimSpace(*operationID),
		CreatorAccountID:       strings.TrimSpace(*creatorID),
		ApprovalRecordID:       strings.TrimSpace(*approvalID),
		CurrentApprovalVersion: strings.TrimSpace(*approvalVersion),
		LaunchEnvironment:      strings.TrimSpace(*environment),
		Purpose:                strings.TrimSpace(*purpose),
		ExpiresAtUTC:           expiresAt,
	}
	body, err := json.Marshal(issue)
	if err != nil {
		return err
	}
	return trustPoolAdminRequest(http.MethodPost, base+"/admin/trust-pools/root-registration-nonces", key, strings.TrimSpace(*operationID), body, stdout)
}

func trustPoolAdminEvent(args []string, name, eventType string, getenv func(string) string, stdout io.Writer) error {
	flags := newTrustPoolAdminFlags(name)
	operationID := flags.fs.String("operation-id", "", "idempotency key")
	poolID := flags.fs.String("pool-id", "", "pool id")
	creatorID := flags.fs.String("creator-account-id", "", "creator account id")
	approvalID := flags.fs.String("approval-record-id", "", "approval record id")
	providerID := flags.fs.String("provider-id", "", "provider id")
	buyerAccountID := flags.fs.String("buyer-account-id", "", "buyer account id")
	lifecycle := flags.fs.String("lifecycle", "", "lifecycle value")
	reason := flags.fs.String("reason", "", "reason code")
	minBinary := flags.fs.String("min-binary-version", "", "minimum provider binary version")
	base, key, err := flags.parse(args, getenv)
	if err != nil {
		return err
	}
	event := trustpool.DurableEvent{
		OperationID:      strings.TrimSpace(*operationID),
		EventType:        eventType,
		PoolID:           strings.TrimSpace(*poolID),
		CreatorAccountID: strings.TrimSpace(*creatorID),
		ApprovalRecordID: strings.TrimSpace(*approvalID),
		ProviderID:       strings.TrimSpace(*providerID),
		BuyerAccountID:   strings.TrimSpace(*buyerAccountID),
		Lifecycle:        strings.TrimSpace(*lifecycle),
		Reason:           strings.TrimSpace(*reason),
		MinBinaryVersion: strings.TrimSpace(*minBinary),
	}
	body, err := json.Marshal(event)
	if err != nil {
		return err
	}
	return trustPoolAdminRequest(http.MethodPost, base+"/admin/trust-pools/events", key, event.OperationID, body, stdout)
}

func trustPoolAdminPromote(args []string, getenv func(string) string, stdout io.Writer) error {
	flags := newTrustPoolAdminFlags("promote")
	poolID := flags.fs.String("pool-id", "", "pool id")
	operationID := flags.fs.String("operation-id", "", "idempotency key")
	reason := flags.fs.String("reason", "", "promotion reason")
	base, key, err := flags.parse(args, getenv)
	if err != nil {
		return err
	}
	if strings.TrimSpace(*poolID) == "" {
		return fmt.Errorf("--pool-id is required")
	}
	body, err := json.Marshal(map[string]string{
		"operation_id": strings.TrimSpace(*operationID),
		"reason":       strings.TrimSpace(*reason),
	})
	if err != nil {
		return err
	}
	return trustPoolAdminRequest(http.MethodPost, base+"/admin/trust-pools/pools/"+url.PathEscape(strings.TrimSpace(*poolID))+"/promote", key, strings.TrimSpace(*operationID), body, stdout)
}

func trustPoolAdminReviewDistributionArtifact(args []string, getenv func(string) string, stdout io.Writer) error {
	flags := newTrustPoolAdminFlags("review-distribution-artifact")
	operationID := flags.fs.String("operation-id", "", "idempotency key")
	poolID := flags.fs.String("pool-id", "", "pool id")
	manifestDigest := flags.fs.String("manifest-core-digest", "", "current manifest_core_digest")
	reviewedDigest := flags.fs.String("reviewed-distribution-artifact-digest", "", "reviewed distribution artifact SHA-256 digest")
	artifactURI := flags.fs.String("artifact-uri", "", "reviewed distribution artifact URI")
	claimControlDigest := flags.fs.String("claim-control-artifact-digest", "", "claim-control artifact SHA-256 digest")
	reviewedBy := flags.fs.String("reviewed-by", "", "review actor id")
	reviewedAtRaw := flags.fs.String("reviewed-at", "", "RFC3339/RFC3339Nano review timestamp")
	base, key, err := flags.parse(args, getenv)
	if err != nil {
		return err
	}
	reviewedAt, err := parseTrustPoolAdminTimeFlag("reviewed-at", *reviewedAtRaw)
	if err != nil {
		return err
	}
	artifact := trustpool.ReviewedDistributionArtifact{
		OperationID:                strings.TrimSpace(*operationID),
		PoolID:                     strings.TrimSpace(*poolID),
		ManifestCoreDigest:         strings.TrimSpace(*manifestDigest),
		ReviewedDistributionDigest: strings.TrimSpace(*reviewedDigest),
		ArtifactURI:                strings.TrimSpace(*artifactURI),
		ClaimControlDigest:         strings.TrimSpace(*claimControlDigest),
		ReviewedBy:                 strings.TrimSpace(*reviewedBy),
		ReviewedAtUTC:              reviewedAt,
	}
	if err := requireTrustPoolAdminFields([]trustPoolAdminRequiredField{
		{name: "operation-id", value: artifact.OperationID},
		{name: "pool-id", value: artifact.PoolID},
		{name: "manifest-core-digest", value: artifact.ManifestCoreDigest},
		{name: "reviewed-distribution-artifact-digest", value: artifact.ReviewedDistributionDigest},
		{name: "artifact-uri", value: artifact.ArtifactURI},
		{name: "claim-control-artifact-digest", value: artifact.ClaimControlDigest},
		{name: "reviewed-by", value: artifact.ReviewedBy},
	}); err != nil {
		return err
	}
	type reviewedArtifactRequest struct {
		OperationID                string    `json:"operation_id"`
		PoolID                     string    `json:"pool_id"`
		ManifestCoreDigest         string    `json:"manifest_core_digest"`
		ReviewedDistributionDigest string    `json:"reviewed_distribution_artifact_digest"`
		ArtifactURI                string    `json:"artifact_uri"`
		ClaimControlDigest         string    `json:"claim_control_artifact_digest"`
		ReviewedBy                 string    `json:"reviewed_by"`
		ReviewedAtUTC              time.Time `json:"reviewed_at_utc"`
	}
	body, err := json.Marshal(reviewedArtifactRequest{
		OperationID:                artifact.OperationID,
		PoolID:                     artifact.PoolID,
		ManifestCoreDigest:         artifact.ManifestCoreDigest,
		ReviewedDistributionDigest: artifact.ReviewedDistributionDigest,
		ArtifactURI:                artifact.ArtifactURI,
		ClaimControlDigest:         artifact.ClaimControlDigest,
		ReviewedBy:                 artifact.ReviewedBy,
		ReviewedAtUTC:              artifact.ReviewedAtUTC,
	})
	if err != nil {
		return err
	}
	return trustPoolAdminRequest(http.MethodPost, base+"/admin/trust-pools/pools/"+url.PathEscape(artifact.PoolID)+"/reviewed-distribution-artifact", key, artifact.OperationID, body, stdout)
}

func trustPoolAdminApprovePublicAnnouncement(args []string, getenv func(string) string, stdout io.Writer) error {
	flags := newTrustPoolAdminFlags("approve-public-announcement")
	operationID := flags.fs.String("operation-id", "", "idempotency key")
	poolID := flags.fs.String("pool-id", "", "pool id")
	manifestDigest := flags.fs.String("manifest-core-digest", "", "current manifest_core_digest")
	reviewedDigest := flags.fs.String("reviewed-distribution-artifact-digest", "", "reviewed distribution artifact SHA-256 digest")
	approvalRecordID := flags.fs.String("approval-record-id", "", "public announcement approval record id")
	approvedBy := flags.fs.String("approved-by", "", "approval actor id")
	approvedAtRaw := flags.fs.String("approved-at", "", "RFC3339/RFC3339Nano approval timestamp")
	base, key, err := flags.parse(args, getenv)
	if err != nil {
		return err
	}
	approvedAt, err := parseTrustPoolAdminTimeFlag("approved-at", *approvedAtRaw)
	if err != nil {
		return err
	}
	approval := trustpool.PublicAnnouncementApproval{
		OperationID:                strings.TrimSpace(*operationID),
		PoolID:                     strings.TrimSpace(*poolID),
		ManifestCoreDigest:         strings.TrimSpace(*manifestDigest),
		ReviewedDistributionDigest: strings.TrimSpace(*reviewedDigest),
		ApprovalRecordID:           strings.TrimSpace(*approvalRecordID),
		ApprovedBy:                 strings.TrimSpace(*approvedBy),
		ApprovedAtUTC:              approvedAt,
	}
	if err := requireTrustPoolAdminFields([]trustPoolAdminRequiredField{
		{name: "operation-id", value: approval.OperationID},
		{name: "pool-id", value: approval.PoolID},
		{name: "manifest-core-digest", value: approval.ManifestCoreDigest},
		{name: "reviewed-distribution-artifact-digest", value: approval.ReviewedDistributionDigest},
		{name: "approval-record-id", value: approval.ApprovalRecordID},
		{name: "approved-by", value: approval.ApprovedBy},
	}); err != nil {
		return err
	}
	type publicAnnouncementRequest struct {
		OperationID                string    `json:"operation_id"`
		PoolID                     string    `json:"pool_id"`
		ManifestCoreDigest         string    `json:"manifest_core_digest"`
		ReviewedDistributionDigest string    `json:"reviewed_distribution_artifact_digest"`
		ApprovalRecordID           string    `json:"approval_record_id"`
		ApprovedBy                 string    `json:"approved_by"`
		ApprovedAtUTC              time.Time `json:"approved_at_utc"`
	}
	body, err := json.Marshal(publicAnnouncementRequest{
		OperationID:                approval.OperationID,
		PoolID:                     approval.PoolID,
		ManifestCoreDigest:         approval.ManifestCoreDigest,
		ReviewedDistributionDigest: approval.ReviewedDistributionDigest,
		ApprovalRecordID:           approval.ApprovalRecordID,
		ApprovedBy:                 approval.ApprovedBy,
		ApprovedAtUTC:              approval.ApprovedAtUTC,
	})
	if err != nil {
		return err
	}
	return trustPoolAdminRequest(http.MethodPost, base+"/admin/trust-pools/pools/"+url.PathEscape(approval.PoolID)+"/public-announcement", key, approval.OperationID, body, stdout)
}

func parseTrustPoolAdminTimeFlag(name, raw string) (time.Time, error) {
	value := strings.TrimSpace(raw)
	if value == "" {
		return time.Time{}, fmt.Errorf("--%s is required", name)
	}
	parsed, err := time.Parse(time.RFC3339Nano, value)
	if err != nil {
		return time.Time{}, fmt.Errorf("--%s must be RFC3339/RFC3339Nano: %w", name, err)
	}
	return parsed, nil
}

type trustPoolAdminRequiredField struct {
	name  string
	value string
}

func requireTrustPoolAdminFields(fields []trustPoolAdminRequiredField) error {
	for _, field := range fields {
		if strings.TrimSpace(field.value) == "" {
			return fmt.Errorf("--%s is required", field.name)
		}
	}
	return nil
}

func trustPoolAdminGET(args []string, name, path string, getenv func(string) string, stdout io.Writer) error {
	flags := newTrustPoolAdminFlags(name)
	base, key, err := flags.parse(args, getenv)
	if err != nil {
		return err
	}
	return trustPoolAdminRequest(http.MethodGet, base+path, key, "", nil, stdout)
}

func trustPoolAdminGETCreator(args []string, getenv func(string) string, stdout io.Writer) error {
	flags := newTrustPoolAdminFlags("get-creator")
	creatorID := flags.fs.String("creator-account-id", "", "creator account id")
	base, key, err := flags.parse(args, getenv)
	if err != nil {
		return err
	}
	if strings.TrimSpace(*creatorID) == "" {
		return fmt.Errorf("--creator-account-id is required")
	}
	return trustPoolAdminRequest(http.MethodGet, base+"/admin/trust-pools/creators/"+url.PathEscape(strings.TrimSpace(*creatorID)), key, "", nil, stdout)
}

func trustPoolAdminGETPool(args []string, name, suffix string, getenv func(string) string, stdout io.Writer) error {
	flags := newTrustPoolAdminFlags(name)
	poolID := flags.fs.String("pool-id", "", "pool id")
	base, key, err := flags.parse(args, getenv)
	if err != nil {
		return err
	}
	if strings.TrimSpace(*poolID) == "" {
		return fmt.Errorf("--pool-id is required")
	}
	return trustPoolAdminRequest(http.MethodGet, base+"/admin/trust-pools/pools/"+url.PathEscape(strings.TrimSpace(*poolID))+suffix, key, "", nil, stdout)
}

func trustPoolAdminRequest(method, target, operatorKey, operationID string, body []byte, stdout io.Writer) error {
	var reader io.Reader
	if len(body) > 0 {
		reader = bytes.NewReader(body)
	}
	req, err := http.NewRequest(method, target, reader)
	if err != nil {
		return err
	}
	req.Header.Set("Authorization", "Bearer "+operatorKey)
	if len(body) > 0 {
		req.Header.Set("Content-Type", "application/json")
	}
	if strings.TrimSpace(operationID) != "" {
		req.Header.Set("Idempotency-Key", strings.TrimSpace(operationID))
	}
	resp, err := trustPoolAdminHTTPClient.Do(req)
	if err != nil {
		return err
	}
	defer resp.Body.Close()
	respBody, err := io.ReadAll(io.LimitReader(resp.Body, 1<<20))
	if err != nil {
		return err
	}
	if resp.StatusCode < 200 || resp.StatusCode >= 300 {
		return fmt.Errorf("%s %s returned %d: %s", method, target, resp.StatusCode, strings.TrimSpace(string(respBody)))
	}
	if _, err := stdout.Write(respBody); err != nil {
		return err
	}
	if len(respBody) == 0 || respBody[len(respBody)-1] != '\n' {
		_, err = fmt.Fprintln(stdout)
	}
	return err
}

func readCLIInput(path string, stdin io.Reader) ([]byte, error) {
	if strings.TrimSpace(path) == "-" {
		return io.ReadAll(io.LimitReader(stdin, 1<<20))
	}
	return os.ReadFile(path)
}
