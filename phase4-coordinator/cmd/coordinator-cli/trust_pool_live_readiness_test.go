package main

import (
	"bytes"
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"strings"
	"sync"
	"testing"
	"time"
)

func TestTrustPoolOnCallCLIUpsertAndGet(t *testing.T) {
	t.Parallel()
	var seen []string
	var seenMu sync.Mutex
	admin := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if got := r.Header.Get("Authorization"); got != "Bearer operator-secret" {
			t.Fatalf("authorization = %q", got)
		}
		seenMu.Lock()
		seen = append(seen, r.Method+" "+r.URL.Path)
		seenMu.Unlock()
		w.Header().Set("Content-Type", "application/json")
		switch {
		case r.Method == http.MethodPost && r.URL.Path == "/admin/trust-pools/on-call-readiness":
			if got := r.Header.Get("Idempotency-Key"); got != "op-oncall" {
				t.Fatalf("idempotency = %q", got)
			}
			var body map[string]any
			if err := json.NewDecoder(r.Body).Decode(&body); err != nil {
				t.Fatalf("decode on-call body: %v", err)
			}
			for _, key := range []string{
				"operation_id", "launch_environment_id", "record_version",
				"primary_operator_contact", "secondary_operator_contact",
				"break_glass_escalation_path", "compromise_notification_channel",
				"creator_agreement_notification_commitment_ack",
				"creator_emergency_notification_mechanism",
				"last_confirmed_at_utc", "confirmation_ttl_seconds",
				"operations_authority_public_key", "operations_authority_signature",
			} {
				if body[key] == nil {
					t.Fatalf("on-call body missing %s: %+v", key, body)
				}
			}
			if body["operation_id"] != "op-oncall" || body["launch_environment_id"] != "launch-staging" {
				t.Fatalf("on-call body = %+v", body)
			}
			if body["record_revision"] != nil || body["updated_at_utc"] != nil {
				t.Fatalf("on-call body included derived fields: %+v", body)
			}
			_, _ = w.Write([]byte(`{"schema_version":"macprovider.trustpool-admin.v1","on_call_readiness":{"operation_id":"op-oncall"}}`))
		case r.Method == http.MethodGet && r.URL.Path == "/admin/trust-pools/on-call-readiness":
			if r.URL.Query().Get("launch_environment_id") != "launch-staging" {
				t.Fatalf("query = %s", r.URL.RawQuery)
			}
			_, _ = w.Write([]byte(`{"schema_version":"macprovider.trustpool-admin.v1","on_call_readiness":{"launch_environment_id":"launch-staging"},"expired":false}`))
		default:
			t.Fatalf("unexpected %s %s", r.Method, r.URL.Path)
		}
	}))
	defer admin.Close()
	getenv := func(key string) string {
		if key == "OP_KEY" {
			return "operator-secret"
		}
		return ""
	}

	payload := onCallReadinessRequest{
		OperationID:                           "op-oncall",
		LaunchEnvironmentID:                   "launch-staging",
		RecordVersion:                         "oncall-v1",
		PrimaryOperatorContact:                "ops-primary@example.test",
		SecondaryOperatorContact:              "ops-secondary@example.test",
		BreakGlassEscalationPath:              "page break-glass",
		CompromiseNotificationChannel:         "security-alerts@example.test",
		CreatorAgreementNotificationAck:       "ack-v1",
		CreatorEmergencyNotificationMechanism: "creator-emergency-webhook",
		LastConfirmedAtUTC:                    time.Date(2026, 8, 27, 1, 0, 0, 0, time.UTC),
		ConfirmationTTLSeconds:                7776000,
		OperationsAuthorityPublicKey:          "AQID",
		OperationsAuthoritySignature:          "BAUG",
	}
	raw, err := json.Marshal(payload)
	if err != nil {
		t.Fatalf("marshal payload: %v", err)
	}
	var upsertOut bytes.Buffer
	if err := trustPoolOnCall([]string{
		"upsert",
		"--admin-url", admin.URL,
		"--operator-key-env", "OP_KEY",
		"--json-file", "-",
	}, getenv, bytes.NewReader(raw), &upsertOut); err != nil {
		t.Fatalf("upsert: %v", err)
	}
	if !strings.Contains(upsertOut.String(), `"on_call_readiness"`) {
		t.Fatalf("upsert output = %s", upsertOut.String())
	}

	var getOut bytes.Buffer
	if err := trustPoolOnCall([]string{
		"get",
		"--admin-url", admin.URL,
		"--operator-key-env", "OP_KEY",
		"--launch-environment-id", "launch-staging",
	}, getenv, strings.NewReader(""), &getOut); err != nil {
		t.Fatalf("get: %v", err)
	}
	if !strings.Contains(getOut.String(), `"expired":false`) {
		t.Fatalf("get output = %s", getOut.String())
	}
	seenMu.Lock()
	seenPaths := strings.Join(seen, ",")
	seenMu.Unlock()
	if seenPaths != "POST /admin/trust-pools/on-call-readiness,GET /admin/trust-pools/on-call-readiness" {
		t.Fatalf("paths = %s", seenPaths)
	}
}

func TestTrustPoolArtifactLifecycleCLIUpsertAndGet(t *testing.T) {
	t.Parallel()
	var seen []string
	var seenMu sync.Mutex
	admin := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if got := r.Header.Get("Authorization"); got != "Bearer operator-secret" {
			t.Fatalf("authorization = %q", got)
		}
		seenMu.Lock()
		seen = append(seen, r.Method+" "+r.URL.Path)
		seenMu.Unlock()
		w.Header().Set("Content-Type", "application/json")
		switch r.URL.Path {
		case "/admin/trust-pools/pools/pool-a/reviewed-artifact-lifecycle":
			if r.Method == http.MethodPost {
				if got := r.Header.Get("Idempotency-Key"); got != "op-lifecycle" {
					t.Fatalf("idempotency = %q", got)
				}
				var body map[string]any
				if err := json.NewDecoder(r.Body).Decode(&body); err != nil {
					t.Fatalf("decode lifecycle body: %v", err)
				}
				if body["operation_id"] != "op-lifecycle" || body["pool_id"] != "pool-a" ||
					body["owner"] != "ops-oncall" || body["environment_class"] != "production" ||
					body["next_review_due_utc"] != "2026-09-26T00:00:00Z" {
					t.Fatalf("lifecycle body = %+v", body)
				}
				if body["record_revision"] != nil || body["updated_at_utc"] != nil {
					t.Fatalf("lifecycle body included derived fields: %+v", body)
				}
				_, _ = w.Write([]byte(`{"schema_version":"macprovider.trustpool-admin.v1","reviewed_artifact_lifecycle":{"operation_id":"op-lifecycle"}}`))
				return
			}
			if r.Method != http.MethodGet {
				t.Fatalf("method = %s", r.Method)
			}
			_, _ = w.Write([]byte(`{"schema_version":"macprovider.trustpool-admin.v1","reviewed_artifact_lifecycle":{"owner":"ops-oncall"}}`))
		default:
			t.Fatalf("unexpected path %s", r.URL.Path)
		}
	}))
	defer admin.Close()
	getenv := func(key string) string {
		if key == "OP_KEY" {
			return "operator-secret"
		}
		return ""
	}

	var upsertOut bytes.Buffer
	if err := trustPoolArtifactLifecycle([]string{
		"upsert",
		"--admin-url", admin.URL,
		"--operator-key-env", "OP_KEY",
		"--operation-id", "op-lifecycle",
		"--pool-id", "pool-a",
		"--owner", "ops-oncall",
		"--environment-class", "production",
		"--next-review-due", "2026-09-26T00:00:00Z",
	}, getenv, strings.NewReader(""), &upsertOut); err != nil {
		t.Fatalf("upsert: %v", err)
	}
	if !strings.Contains(upsertOut.String(), `"reviewed_artifact_lifecycle"`) {
		t.Fatalf("upsert output = %s", upsertOut.String())
	}
	var getOut bytes.Buffer
	if err := trustPoolArtifactLifecycle([]string{
		"get",
		"--admin-url", admin.URL,
		"--operator-key-env", "OP_KEY",
		"--pool-id", "pool-a",
	}, getenv, strings.NewReader(""), &getOut); err != nil {
		t.Fatalf("get: %v", err)
	}
	if !strings.Contains(getOut.String(), `"ops-oncall"`) {
		t.Fatalf("get output = %s", getOut.String())
	}
	seenMu.Lock()
	seenPaths := strings.Join(seen, ",")
	seenMu.Unlock()
	if seenPaths != "POST /admin/trust-pools/pools/pool-a/reviewed-artifact-lifecycle,GET /admin/trust-pools/pools/pool-a/reviewed-artifact-lifecycle" {
		t.Fatalf("paths = %s", seenPaths)
	}
}

func TestTrustPoolOnCallCLIRejectsUnknownSubcommand(t *testing.T) {
	t.Parallel()
	err := trustPoolOnCall([]string{"promote"}, func(string) string { return "" }, strings.NewReader(""), &bytes.Buffer{})
	if err == nil || !strings.Contains(err.Error(), "unknown trust-pool-oncall subcommand") {
		t.Fatalf("err = %v", err)
	}
}
