package main

import (
	"bytes"
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"strings"
	"sync"
	"testing"
)

func TestTrustPoolAdminCLIEventAndExports(t *testing.T) {
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
	seenMu.Lock()
	seenPaths := strings.Join(seen, ",")
	seenMu.Unlock()
	if seenPaths != "POST /admin/trust-pools/events,GET /admin/trust-pools/pools/pool-a/audit" {
		t.Fatalf("paths = %s", seenPaths)
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

func TestTrustPoolAdminCLIReviewedArtifactAndPublicAnnouncement(t *testing.T) {
	t.Parallel()
	const digestA = "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
	const digestB = "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"
	const digestC = "cccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc"
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
		case "/admin/trust-pools/pools/pool-a/reviewed-distribution-artifact":
			if got := r.Header.Get("Idempotency-Key"); got != "op-reviewed" {
				t.Fatalf("reviewed artifact idempotency = %q", got)
			}
			var body map[string]any
			if err := json.NewDecoder(r.Body).Decode(&body); err != nil {
				t.Fatalf("decode reviewed artifact body: %v", err)
			}
			for _, key := range []string{"operation_id", "pool_id", "manifest_core_digest", "reviewed_distribution_artifact_digest", "artifact_uri", "claim_control_artifact_digest", "reviewed_by", "reviewed_at_utc"} {
				if body[key] == nil {
					t.Fatalf("reviewed artifact body missing %s: %+v", key, body)
				}
			}
			if body["operation_id"] != "op-reviewed" || body["pool_id"] != "pool-a" ||
				body["manifest_core_digest"] != digestA || body["reviewed_distribution_artifact_digest"] != digestB ||
				body["artifact_uri"] != "s3://trusted-pools/pool-a/dist.json" ||
				body["claim_control_artifact_digest"] != digestC || body["reviewed_by"] != "operator-a" ||
				body["reviewed_at_utc"] != "2026-08-22T01:00:00Z" {
				t.Fatalf("reviewed artifact body = %+v", body)
			}
			if body["review_revision"] != nil || body["updated_at_utc"] != nil {
				t.Fatalf("reviewed artifact body included derived fields: %+v", body)
			}
			_, _ = w.Write([]byte(`{"schema_version":"macprovider.trustpool-admin.v1","reviewed_distribution_artifact":{"operation_id":"op-reviewed"}}`))
		case "/admin/trust-pools/pools/pool-a/public-announcement":
			if got := r.Header.Get("Idempotency-Key"); got != "op-public" {
				t.Fatalf("public announcement idempotency = %q", got)
			}
			var body map[string]any
			if err := json.NewDecoder(r.Body).Decode(&body); err != nil {
				t.Fatalf("decode public announcement body: %v", err)
			}
			for _, key := range []string{"operation_id", "pool_id", "manifest_core_digest", "reviewed_distribution_artifact_digest", "approval_record_id", "approved_by", "approved_at_utc"} {
				if body[key] == nil {
					t.Fatalf("public announcement body missing %s: %+v", key, body)
				}
			}
			if body["operation_id"] != "op-public" || body["pool_id"] != "pool-a" ||
				body["manifest_core_digest"] != digestA || body["reviewed_distribution_artifact_digest"] != digestB ||
				body["approval_record_id"] != "public-announcement-v1" || body["approved_by"] != "operator-a" ||
				body["approved_at_utc"] != "2026-08-22T01:05:00Z" {
				t.Fatalf("public announcement body = %+v", body)
			}
			for _, key := range []string{"creator_account_id", "creator_approval_record_id", "creator_approval_version", "creator_approval_revision", "public_announcement_revision", "updated_at_utc"} {
				if body[key] != nil {
					t.Fatalf("public announcement body included coordinator-derived %s: %+v", key, body)
				}
			}
			_, _ = w.Write([]byte(`{"schema_version":"macprovider.trustpool-admin.v1","public_announcement":{"operation_id":"op-public"}}`))
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

	var reviewedOut bytes.Buffer
	err := trustPoolAdmin([]string{
		"review-distribution-artifact",
		"--admin-url", admin.URL,
		"--operator-key-env", "OP_KEY",
		"--operation-id", "op-reviewed",
		"--pool-id", "pool-a",
		"--manifest-core-digest", digestA,
		"--reviewed-distribution-artifact-digest", digestB,
		"--artifact-uri", "s3://trusted-pools/pool-a/dist.json",
		"--claim-control-artifact-digest", digestC,
		"--reviewed-by", "operator-a",
		"--reviewed-at", "2026-08-22T01:00:00Z",
	}, getenv, strings.NewReader(""), &reviewedOut)
	if err != nil {
		t.Fatalf("review-distribution-artifact: %v", err)
	}
	if !strings.Contains(reviewedOut.String(), `"reviewed_distribution_artifact"`) {
		t.Fatalf("reviewed output = %s", reviewedOut.String())
	}

	var publicOut bytes.Buffer
	err = trustPoolAdmin([]string{
		"approve-public-announcement",
		"--admin-url", admin.URL,
		"--operator-key-env", "OP_KEY",
		"--operation-id", "op-public",
		"--pool-id", "pool-a",
		"--manifest-core-digest", digestA,
		"--reviewed-distribution-artifact-digest", digestB,
		"--approval-record-id", "public-announcement-v1",
		"--approved-by", "operator-a",
		"--approved-at", "2026-08-22T01:05:00Z",
	}, getenv, strings.NewReader(""), &publicOut)
	if err != nil {
		t.Fatalf("approve-public-announcement: %v", err)
	}
	if !strings.Contains(publicOut.String(), `"public_announcement"`) {
		t.Fatalf("public announcement output = %s", publicOut.String())
	}
	seenMu.Lock()
	seenPaths := strings.Join(seen, ",")
	seenMu.Unlock()
	if seenPaths != "POST /admin/trust-pools/pools/pool-a/reviewed-distribution-artifact,POST /admin/trust-pools/pools/pool-a/public-announcement" {
		t.Fatalf("paths = %s", seenPaths)
	}
}

func TestTrustPoolAdminCLIDoesNotFollowRedirectsWithOperatorBearer(t *testing.T) {
	t.Parallel()
	redirected := make(chan *http.Request, 1)
	destination := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		redirected <- r.Clone(r.Context())
		w.WriteHeader(http.StatusNoContent)
	}))
	defer destination.Close()
	admin := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		http.Redirect(w, r, destination.URL+"/admin/trust-pools/events", http.StatusTemporaryRedirect)
	}))
	defer admin.Close()
	getenv := func(key string) string {
		if key == "OP_KEY" {
			return "operator-secret"
		}
		return ""
	}

	err := trustPoolAdmin([]string{
		"create-pool",
		"--admin-url", admin.URL,
		"--operator-key-env", "OP_KEY",
		"--pool-id", "pool-a",
		"--creator-account-id", "creator-a",
		"--approval-record-id", "approval-v1",
		"--operation-id", "op-create",
	}, getenv, strings.NewReader(""), &bytes.Buffer{})
	if err == nil || !strings.Contains(err.Error(), "returned 307") {
		t.Fatalf("err = %v, want redirect response surfaced without following", err)
	}
	select {
	case req := <-redirected:
		t.Fatalf("redirect destination received %s %s with authorization %q", req.Method, req.URL.Path, req.Header.Get("Authorization"))
	default:
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
