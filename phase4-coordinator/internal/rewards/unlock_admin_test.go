package rewards

import (
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"
)

func TestDualControlReady(t *testing.T) {
	cases := []struct {
		name string
		keys map[string]string
		want bool
	}{
		{"nil", nil, false},
		{"empty", map[string]string{}, false},
		{"single", map[string]string{"alice": "alice-secret"}, false},
		{"two_distinct", map[string]string{"alice": "alice-secret", "bob": "bob-secret"}, true},
		{"shared_secret", map[string]string{"alice": "same", "bob": "same"}, false},
		{"empty_secret", map[string]string{"alice": "alice-secret", "bob": ""}, false},
		{"whitespace_secret", map[string]string{"alice": "alice-secret", "bob": "   "}, false},
	}
	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			if got := dualControlReady(tc.keys); got != tc.want {
				t.Fatalf("dualControlReady(%v) = %v, want %v", tc.keys, got, tc.want)
			}
		})
	}
}

func trustReq(t *testing.T, bearer, actorHeader string) *http.Request {
	t.Helper()
	r := httptest.NewRequest(http.MethodPost, "/admin/trust-promotion/request", nil)
	if bearer != "" {
		r.Header.Set("Authorization", "Bearer "+bearer)
	}
	if actorHeader != "" {
		r.Header.Set("X-Operator-Actor", actorHeader)
	}
	return r
}

// TestAuthorizedTrustOperator_ActorIsCredentialDerived is the SEC-1 regression:
// the acting identity must come from the MATCHED operator key, never from the
// attacker-controllable X-Operator-Actor header. A single key holder therefore
// cannot request as "alice" and approve as "bob".
func TestAuthorizedTrustOperator_ActorIsCredentialDerived(t *testing.T) {
	keys := map[string]string{"alice": "alice-secret", "bob": "bob-secret"}

	// alice-secret always resolves to operator:alice, regardless of a spoofed
	// X-Operator-Actor header claiming to be bob.
	actor, ok := authorizedTrustOperator(trustReq(t, "alice-secret", "bob"), keys)
	if !ok || actor != "operator:alice" {
		t.Fatalf("alice-secret with spoofed X-Operator-Actor: got (%q,%v), want (operator:alice,true)", actor, ok)
	}
	// The only way to act as bob is to hold bob-secret.
	actor, ok = authorizedTrustOperator(trustReq(t, "bob-secret", "alice"), keys)
	if !ok || actor != "operator:bob" {
		t.Fatalf("bob-secret: got (%q,%v), want (operator:bob,true)", actor, ok)
	}
}

func TestAuthorizedTrustOperator_RejectsBadCredential(t *testing.T) {
	keys := map[string]string{"alice": "alice-secret", "bob": "bob-secret"}
	for _, bearer := range []string{"", "wrong-secret", "alice-secre"} {
		if actor, ok := authorizedTrustOperator(trustReq(t, bearer, "alice"), keys); ok {
			t.Fatalf("bearer %q: got (%q,true), want (\"\",false)", bearer, actor)
		}
	}
}

// TestAuthorizedTrustOperator_FailsClosed: without two distinct operator keys
// the route cannot enforce two-person control and must reject everything.
func TestAuthorizedTrustOperator_FailsClosed(t *testing.T) {
	single := map[string]string{"alice": "alice-secret"}
	if _, ok := authorizedTrustOperator(trustReq(t, "alice-secret", ""), single); ok {
		t.Fatal("single-key map must fail closed even with a correct bearer")
	}
	shared := map[string]string{"alice": "same", "bob": "same"}
	if _, ok := authorizedTrustOperator(trustReq(t, "same", ""), shared); ok {
		t.Fatal("shared-secret map must fail closed")
	}
}

func TestNormalizedTrustOperatorActor(t *testing.T) {
	if got := normalizedTrustOperatorActor("alice"); got != "operator:alice" {
		t.Fatalf("got %q", got)
	}
	if got := normalizedTrustOperatorActor("operator:bob"); got != "operator:bob" {
		t.Fatalf("got %q", got)
	}
}

func decodeErr(t *testing.T, rr *httptest.ResponseRecorder) string {
	t.Helper()
	var body struct {
		Error string `json:"error"`
	}
	if err := json.NewDecoder(rr.Body).Decode(&body); err != nil {
		t.Fatalf("decode body: %v", err)
	}
	return body.Error
}

// Handler-level fail-closed and auth-ordering checks (no DB required: the
// dual-control gate and auth run before the DB-nil guard).
func TestTrustPromotionHandlers_FailClosedAndAuth(t *testing.T) {
	twoKeys := map[string]string{"alice": "alice-secret", "bob": "bob-secret"}

	t.Run("request_dual_control_unavailable", func(t *testing.T) {
		h := NewTrustPromotionRequestHandler(TrustAdminDeps{OperatorKeys: map[string]string{"alice": "alice-secret"}})
		rr := httptest.NewRecorder()
		h.ServeHTTP(rr, trustReq(t, "alice-secret", ""))
		if rr.Code != http.StatusServiceUnavailable || decodeErr(t, rr) != "dual_control_unavailable" {
			t.Fatalf("code=%d err=%q", rr.Code, rr.Body.String())
		}
	})

	t.Run("request_unauthorized", func(t *testing.T) {
		h := NewTrustPromotionRequestHandler(TrustAdminDeps{OperatorKeys: twoKeys})
		rr := httptest.NewRecorder()
		h.ServeHTTP(rr, trustReq(t, "nope", ""))
		if rr.Code != http.StatusUnauthorized {
			t.Fatalf("code=%d body=%q", rr.Code, rr.Body.String())
		}
	})

	t.Run("request_valid_auth_reaches_db_guard", func(t *testing.T) {
		// DB nil -> after successful auth the handler returns 503 "unavailable"
		// (distinct from the dual-control 503), proving the credential passed.
		h := NewTrustPromotionRequestHandler(TrustAdminDeps{OperatorKeys: twoKeys})
		rr := httptest.NewRecorder()
		h.ServeHTTP(rr, trustReq(t, "alice-secret", "bob"))
		if rr.Code != http.StatusServiceUnavailable || decodeErr(t, rr) != "unavailable" {
			t.Fatalf("code=%d err=%q", rr.Code, rr.Body.String())
		}
	})

	t.Run("approve_dual_control_unavailable", func(t *testing.T) {
		h := NewTrustPromotionApproveHandler(TrustAdminDeps{OperatorKeys: map[string]string{"alice": "alice-secret"}})
		rr := httptest.NewRecorder()
		req := httptest.NewRequest(http.MethodPost, "/admin/trust-promotion/some-id/approve", nil)
		req.Header.Set("Authorization", "Bearer alice-secret")
		h.ServeHTTP(rr, req)
		if rr.Code != http.StatusServiceUnavailable || decodeErr(t, rr) != "dual_control_unavailable" {
			t.Fatalf("code=%d err=%q", rr.Code, rr.Body.String())
		}
	})

	t.Run("approve_unauthorized", func(t *testing.T) {
		h := NewTrustPromotionApproveHandler(TrustAdminDeps{OperatorKeys: twoKeys})
		rr := httptest.NewRecorder()
		req := httptest.NewRequest(http.MethodPost, "/admin/trust-promotion/some-id/approve", nil)
		req.Header.Set("Authorization", "Bearer nope")
		h.ServeHTTP(rr, req)
		if rr.Code != http.StatusUnauthorized {
			t.Fatalf("code=%d body=%q", rr.Code, rr.Body.String())
		}
	})
}

func TestWriteTrustJSON_NoStore(t *testing.T) {
	rr := httptest.NewRecorder()
	writeTrustJSON(rr, http.StatusOK, map[string]any{"ok": true})
	if got := rr.Header().Get("Cache-Control"); !strings.Contains(got, "no-store") {
		t.Fatalf("Cache-Control=%q", got)
	}
}
