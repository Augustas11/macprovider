package main

import (
	"encoding/json"
	"fmt"
	"io"
	"net/http"
	"net/url"
	"strings"
	"time"

	"github.com/augstar/macprovider-coordinator/internal/trustpool"
)

func trustPoolOnCall(args []string, getenv func(string) string, stdin io.Reader, stdout io.Writer) error {
	if len(args) == 0 {
		return fmt.Errorf("trust-pool-oncall subcommand required")
	}
	switch args[0] {
	case "sign":
		return trustPoolOnCallSign(args[1:], getenv, stdin, stdout)
	case "upsert":
		return trustPoolOnCallUpsert(args[1:], getenv, stdin, stdout)
	case "get":
		return trustPoolOnCallGet(args[1:], getenv, stdout)
	default:
		return fmt.Errorf("unknown trust-pool-oncall subcommand %q", args[0])
	}
}

func trustPoolArtifactLifecycle(args []string, getenv func(string) string, stdin io.Reader, stdout io.Writer) error {
	if len(args) == 0 {
		return fmt.Errorf("trust-pool-artifact-lifecycle subcommand required")
	}
	switch args[0] {
	case "upsert":
		return trustPoolArtifactLifecycleUpsert(args[1:], getenv, stdout)
	case "get":
		return trustPoolArtifactLifecycleGet(args[1:], getenv, stdout)
	default:
		return fmt.Errorf("unknown trust-pool-artifact-lifecycle subcommand %q", args[0])
	}
}

func trustPoolOnCallUpsert(args []string, getenv func(string) string, stdin io.Reader, stdout io.Writer) error {
	flags := newTrustPoolAdminFlags("oncall-upsert")
	jsonFile := flags.fs.String("json-file", "", "signed on-call readiness JSON; use - for stdin")
	base, key, err := flags.parse(args, getenv)
	if err != nil {
		return err
	}
	if strings.TrimSpace(*jsonFile) == "" {
		return fmt.Errorf("--json-file is required")
	}
	raw, err := readCLIInput(*jsonFile, stdin)
	if err != nil {
		return err
	}
	var rec trustpool.OnCallReadiness
	if err := json.Unmarshal(raw, &rec); err != nil {
		return fmt.Errorf("on-call readiness JSON: %w", err)
	}
	if strings.TrimSpace(rec.OperationID) == "" {
		return fmt.Errorf("operation_id is required")
	}
	body, err := json.Marshal(onCallReadinessRequest{
		OperationID:                           rec.OperationID,
		LaunchEnvironmentID:                   rec.LaunchEnvironmentID,
		RecordVersion:                         rec.RecordVersion,
		PrimaryOperatorContact:                rec.PrimaryOperatorContact,
		SecondaryOperatorContact:              rec.SecondaryOperatorContact,
		BreakGlassEscalationPath:              rec.BreakGlassEscalationPath,
		CompromiseNotificationChannel:         rec.CompromiseNotificationChannel,
		CreatorAgreementNotificationAck:       rec.CreatorAgreementNotificationAck,
		CreatorEmergencyNotificationMechanism: rec.CreatorEmergencyNotificationMechanism,
		LastConfirmedAtUTC:                    rec.LastConfirmedAtUTC,
		ConfirmationTTLSeconds:                rec.ConfirmationTTLSeconds,
		OperationsAuthorityPublicKey:          rec.OperationsAuthorityPublicKey,
		OperationsAuthoritySignature:          rec.OperationsAuthoritySignature,
	})
	if err != nil {
		return err
	}
	return trustPoolAdminRequest(http.MethodPost, base+"/admin/trust-pools/on-call-readiness", key, rec.OperationID, body, stdout)
}

func trustPoolOnCallGet(args []string, getenv func(string) string, stdout io.Writer) error {
	flags := newTrustPoolAdminFlags("oncall-get")
	envID := flags.fs.String("launch-environment-id", "", "launch environment id")
	base, key, err := flags.parse(args, getenv)
	if err != nil {
		return err
	}
	if strings.TrimSpace(*envID) == "" {
		return fmt.Errorf("--launch-environment-id is required")
	}
	target := base + "/admin/trust-pools/on-call-readiness?launch_environment_id=" + url.QueryEscape(strings.TrimSpace(*envID))
	return trustPoolAdminRequest(http.MethodGet, target, key, "", nil, stdout)
}

func trustPoolArtifactLifecycleUpsert(args []string, getenv func(string) string, stdout io.Writer) error {
	flags := newTrustPoolAdminFlags("artifact-lifecycle-upsert")
	operationID := flags.fs.String("operation-id", "", "idempotency key")
	poolID := flags.fs.String("pool-id", "", "pool id")
	owner := flags.fs.String("owner", "", "lifecycle owner")
	envClass := flags.fs.String("environment-class", "", "candidate or production")
	dueRaw := flags.fs.String("next-review-due", "", "RFC3339/RFC3339Nano next review timestamp")
	notes := flags.fs.String("notes", "", "optional operator notes")
	base, key, err := flags.parse(args, getenv)
	if err != nil {
		return err
	}
	due, err := parseTrustPoolAdminTimeFlag("next-review-due", *dueRaw)
	if err != nil {
		return err
	}
	rec := trustpool.ReviewedArtifactLifecycle{
		OperationID:      strings.TrimSpace(*operationID),
		PoolID:           strings.TrimSpace(*poolID),
		Owner:            strings.TrimSpace(*owner),
		EnvironmentClass: strings.TrimSpace(*envClass),
		NextReviewDueUTC: due,
		Notes:            strings.TrimSpace(*notes),
	}
	if err := requireTrustPoolAdminFields([]trustPoolAdminRequiredField{
		{name: "operation-id", value: rec.OperationID},
		{name: "pool-id", value: rec.PoolID},
		{name: "owner", value: rec.Owner},
		{name: "environment-class", value: rec.EnvironmentClass},
	}); err != nil {
		return err
	}
	body, err := json.Marshal(reviewedArtifactLifecycleRequest{
		OperationID:      rec.OperationID,
		PoolID:           rec.PoolID,
		Owner:            rec.Owner,
		EnvironmentClass: rec.EnvironmentClass,
		NextReviewDueUTC: rec.NextReviewDueUTC,
		Notes:            rec.Notes,
	})
	if err != nil {
		return err
	}
	return trustPoolAdminRequest(http.MethodPost, base+"/admin/trust-pools/pools/"+url.PathEscape(rec.PoolID)+"/reviewed-artifact-lifecycle", key, rec.OperationID, body, stdout)
}

func trustPoolArtifactLifecycleGet(args []string, getenv func(string) string, stdout io.Writer) error {
	flags := newTrustPoolAdminFlags("artifact-lifecycle-get")
	poolID := flags.fs.String("pool-id", "", "pool id")
	base, key, err := flags.parse(args, getenv)
	if err != nil {
		return err
	}
	if strings.TrimSpace(*poolID) == "" {
		return fmt.Errorf("--pool-id is required")
	}
	return trustPoolAdminRequest(http.MethodGet, base+"/admin/trust-pools/pools/"+url.PathEscape(strings.TrimSpace(*poolID))+"/reviewed-artifact-lifecycle", key, "", nil, stdout)
}

type onCallReadinessRequest struct {
	OperationID                           string    `json:"operation_id"`
	LaunchEnvironmentID                   string    `json:"launch_environment_id"`
	RecordVersion                         string    `json:"record_version"`
	PrimaryOperatorContact                string    `json:"primary_operator_contact"`
	SecondaryOperatorContact              string    `json:"secondary_operator_contact"`
	BreakGlassEscalationPath              string    `json:"break_glass_escalation_path"`
	CompromiseNotificationChannel         string    `json:"compromise_notification_channel"`
	CreatorAgreementNotificationAck       string    `json:"creator_agreement_notification_commitment_ack"`
	CreatorEmergencyNotificationMechanism string    `json:"creator_emergency_notification_mechanism"`
	LastConfirmedAtUTC                    time.Time `json:"last_confirmed_at_utc"`
	ConfirmationTTLSeconds                int64     `json:"confirmation_ttl_seconds"`
	OperationsAuthorityPublicKey          string    `json:"operations_authority_public_key"`
	OperationsAuthoritySignature          string    `json:"operations_authority_signature"`
}

type reviewedArtifactLifecycleRequest struct {
	OperationID      string    `json:"operation_id"`
	PoolID           string    `json:"pool_id"`
	Owner            string    `json:"owner"`
	EnvironmentClass string    `json:"environment_class"`
	NextReviewDueUTC time.Time `json:"next_review_due_utc"`
	Notes            string    `json:"notes,omitempty"`
}
