package routing_test

import (
	"encoding/json"
	"strings"
	"testing"

	"github.com/augstar/macprovider-coordinator/internal/routing"
)

// TestRewriteModel pins the byte-identical JSON-surgical model-field
// rewrite extracted from buyer.dispatchBodyForProvider in #266 T2.

func TestRewriteModel_PreservesBodyWhenModelMatches(t *testing.T) {
	body := []byte(`{"model":"qwen3-32b","messages":[]}`)
	got, err := routing.RewriteModel(body, "qwen3-32b", "qwen3-32b")
	if err != nil {
		t.Fatalf("unexpected err: %v", err)
	}
	if string(got) != string(body) {
		t.Fatalf("byte-identical expected; got %s", got)
	}
}

func TestRewriteModel_CaseInsensitiveMatchSkipsRewrite(t *testing.T) {
	body := []byte(`{"model":"Qwen3-32B","messages":[]}`)
	got, err := routing.RewriteModel(body, "QWEN3-32B", "qwen3-32b")
	if err != nil {
		t.Fatalf("unexpected err: %v", err)
	}
	if string(got) != string(body) {
		t.Fatalf("EqualFold-matched buyer model should NOT rewrite; got %s", got)
	}
}

func TestRewriteModel_ReplacesModelValuePreservingWhitespace(t *testing.T) {
	body := []byte(`{ "model"  :  "fast-class"  , "messages": [] }`)
	got, err := routing.RewriteModel(body, "fast-class", "qwen3-32b")
	if err != nil {
		t.Fatalf("unexpected err: %v", err)
	}
	if !strings.Contains(string(got), `"qwen3-32b"`) {
		t.Fatalf("expected provider model to appear; got %s", got)
	}
	if !strings.Contains(string(got), `"messages": [] `) {
		t.Fatalf("expected surrounding whitespace + fields preserved; got %s", got)
	}
}

func TestRewriteModel_ReplacesModelValuePreservingByteIdentityOutsideModelField(t *testing.T) {
	body := []byte(`{"model":"alias","temperature":0.7,"messages":[{"role":"user","content":"hi"}]}`)
	got, err := routing.RewriteModel(body, "alias", "qwen3-32b")
	if err != nil {
		t.Fatalf("unexpected err: %v", err)
	}
	var parsed map[string]json.RawMessage
	if err := json.Unmarshal(got, &parsed); err != nil {
		t.Fatalf("rewritten body must still parse: %v", err)
	}
	if got, want := string(parsed["model"]), `"qwen3-32b"`; got != want {
		t.Fatalf("expected model=%q, got %s", want, got)
	}
	if string(parsed["temperature"]) != "0.7" {
		t.Fatalf("temperature must be preserved verbatim; got %s", parsed["temperature"])
	}
}

func TestRewriteModel_RejectsNonObjectBody(t *testing.T) {
	body := []byte(`[1,2,3]`)
	_, err := routing.RewriteModel(body, "a", "b")
	if err == nil || !strings.Contains(err.Error(), "JSON object") {
		t.Fatalf("expected JSON-object error, got %v", err)
	}
}

func TestRewriteModel_RejectsMissingModelField(t *testing.T) {
	body := []byte(`{"messages":[]}`)
	_, err := routing.RewriteModel(body, "a", "b")
	if err == nil || !strings.Contains(err.Error(), "missing model field") {
		t.Fatalf("expected missing-model error, got %v", err)
	}
}

func TestRewriteModel_RejectsDuplicateModelField(t *testing.T) {
	body := []byte(`{"model":"a","model":"b"}`)
	_, err := routing.RewriteModel(body, "a", "x")
	if err == nil || !strings.Contains(err.Error(), "duplicate model") {
		t.Fatalf("expected duplicate-model error, got %v", err)
	}
}

func TestRewriteModel_RejectsNonCanonicalCasing(t *testing.T) {
	// "Model" must be rejected — defense against header-smuggling
	// where a downstream layer might match case-insensitively.
	body := []byte(`{"Model":"a","messages":[]}`)
	_, err := routing.RewriteModel(body, "a", "b")
	if err == nil || !strings.Contains(err.Error(), "non-canonical model field") {
		t.Fatalf("expected non-canonical-case error, got %v", err)
	}
}

func TestRewriteModel_EmptyProviderModelIDIsLiteralRewrite(t *testing.T) {
	// Empty provider model_id is a degenerate but valid input — the
	// rewritten body should contain "" as the model value.
	body := []byte(`{"model":"alias"}`)
	got, err := routing.RewriteModel(body, "alias", "")
	if err != nil {
		t.Fatalf("unexpected err: %v", err)
	}
	if string(got) != `{"model":""}` {
		t.Fatalf("expected empty model rewrite, got %s", got)
	}
}

func TestRewriteModel_CopiesInputWhenSkippingRewrite(t *testing.T) {
	// Match-skip path returns a FRESH slice so callers can mutate
	// the rawBody for retry use without corrupting the dispatch body.
	body := []byte(`{"model":"a"}`)
	got, err := routing.RewriteModel(body, "a", "a")
	if err != nil {
		t.Fatalf("unexpected err: %v", err)
	}
	got[0] = 'X'
	if body[0] == 'X' {
		t.Fatalf("returned slice must not alias input")
	}
}
