package main

import (
	"bytes"
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"
)

func TestTrustPoolAdminCLIEventAndExports(t *testing.T) {
	t.Parallel()
	var seen []string
	admin := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if got := r.Header.Get("Authorization"); got != "Bearer operator-secret" {
			t.Fatalf("authorization = %q", got)
		}
		seen = append(seen, r.Method+" "+r.URL.Path)
		w.Header().Set("Content-Type", "application/json")
		switch r.URL.Path {
		case "/admin/trust-pools/events":
			if got := r.Header.Get("Idempotency-Key"); got != "op-create" {
				t.Fatalf("idempotency = %q", got)
			}
			var body map[string]any
			if err := json.NewDecoder(r.Body).Decode(&body); err != nil {
				t.Fatalf("decode event body: %v", err)
			}
			if body["event_type"] != "pool_created" || body["pool_id"] != "pool-a" ||
				body["creator_account_id"] != "creator-a" || body["approval_record_id"] != "approval-v1" {
				t.Fatalf("event body = %+v", body)
			}
			_, _ = w.Write([]byte(`{"schema_version":"macprovider.trustpool-admin.v1","event":{"operation_id":"op-create"}}`))
		case "/admin/trust-pools/pools/pool-a/audit":
			_, _ = w.Write([]byte(`{"schema_version":"macprovider.trustpool-admin.v1","events":[]}`))
		default:
			t.Fatalf("unexpected path %s", r.URL.Path)
		}
	}))
	defer admin.Close()
	getenv := func(key string) string {
		switch key {
		case "MACPROVIDER_COORDINATOR_ADMIN_URL":
			return admin.URL
		case "MACPROVIDER_OPERATOR_KEY":
			return "operator-secret"
		default:
			return ""
		}
	}

	var createOut bytes.Buffer
	if err := trustPoolAdmin([]string{"create-pool", "--pool-id", "pool-a", "--creator-account-id", "creator-a", "--approval-record-id", "approval-v1", "--operation-id", "op-create"}, getenv, strings.NewReader(""), &createOut); err != nil {
		t.Fatalf("create-pool: %v", err)
	}
	if !strings.Contains(createOut.String(), `"event"`) {
		t.Fatalf("create output = %s", createOut.String())
	}
	var auditOut bytes.Buffer
	if err := trustPoolAdmin([]string{"export-audit", "--pool-id", "pool-a"}, getenv, strings.NewReader(""), &auditOut); err != nil {
		t.Fatalf("export-audit: %v", err)
	}
	if !strings.Contains(auditOut.String(), `"events"`) {
		t.Fatalf("audit output = %s", auditOut.String())
	}
	if strings.Join(seen, ",") != "POST /admin/trust-pools/events,GET /admin/trust-pools/pools/pool-a/audit" {
		t.Fatalf("paths = %v", seen)
	}
}

func TestTrustPoolAdminCLIIssueRootNonceUsesStructuredJSON(t *testing.T) {
	t.Parallel()
	admin := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if r.URL.Path != "/admin/trust-pools/root-registration-nonces" {
			t.Fatalf("path = %q", r.URL.Path)
		}
		if got := r.Header.Get("Idempotency-Key"); got != "op-nonce" {
			t.Fatalf("idempotency = %q", got)
		}
		var body map[string]any
		if err := json.NewDecoder(r.Body).Decode(&body); err != nil {
			t.Fatalf("decode nonce body: %v", err)
		}
		for _, key := range []string{"operation_id", "creator_account_id", "approval_record_id", "current_approval_version", "launch_environment", "expires_at_utc"} {
			if body[key] == nil {
				t.Fatalf("nonce body missing %s: %+v", key, body)
			}
		}
		if body["operation_id"] != "op-nonce" {
			t.Fatalf("operation_id = %+v", body["operation_id"])
		}
		_, _ = w.Write([]byte(`{"schema_version":"macprovider.trustpool-admin.v1","root_registration_nonce":{"nonce":"n"}}`))
	}))
	defer admin.Close()
	getenv := func(key string) string {
		if key == "OP_KEY" {
			return "operator-secret"
		}
		return ""
	}
	var out bytes.Buffer
	err := trustPoolAdmin([]string{
		"issue-root-nonce",
		"--admin-url", admin.URL,
		"--operator-key-env", "OP_KEY",
		"--creator-account-id", "creator-a",
		"--approval-record-id", "approval-v1",
		"--approval-version", "approval-version-1",
		"--launch-environment", "candidate",
		"--expires-at", "2026-08-21T15:00:00Z",
		"--operation-id", "op-nonce",
	}, getenv, strings.NewReader(""), &out)
	if err != nil {
		t.Fatalf("issue-root-nonce: %v", err)
	}
	if !strings.Contains(out.String(), `"root_registration_nonce"`) {
		t.Fatalf("output = %s", out.String())
	}
}

func TestTrustPoolAdminCLIRejectsInlineOperatorKey(t *testing.T) {
	t.Parallel()
	err := trustPoolAdmin([]string{
		"list-pools",
		"--admin-url", "https://coordinator.example",
		"--operator-key", "operator-secret",
	}, func(string) string { return "" }, strings.NewReader(""), &bytes.Buffer{})
	if err == nil || !strings.Contains(err.Error(), "flag provided but not defined") {
		t.Fatalf("err = %v, want inline operator key flag rejected", err)
	}
}

func TestTrustPoolAdminCLIRejectsCleartextNonLoopbackAdminURL(t *testing.T) {
	t.Parallel()
	err := trustPoolAdmin([]string{
		"list-pools",
		"--admin-url", "http://coordinator.example",
		"--operator-key-env", "OP_KEY",
	}, func(key string) string {
		if key == "OP_KEY" {
			return "operator-secret"
		}
		return ""
	}, strings.NewReader(""), &bytes.Buffer{})
	if err == nil || !strings.Contains(err.Error(), "http only for loopback") {
		t.Fatalf("err = %v, want cleartext non-loopback URL rejected", err)
	}
}

func TestTrustPoolAdminCLIUnsupportedSignerRotationIsExplicit(t *testing.T) {
	t.Parallel()
	err := trustPoolAdmin([]string{"rotate-signer-set"}, func(string) string { return "" }, strings.NewReader(""), &bytes.Buffer{})
	if err == nil || !strings.Contains(err.Error(), "not implemented") {
		t.Fatalf("err = %v, want explicit unsupported signer rotation", err)
	}
}
