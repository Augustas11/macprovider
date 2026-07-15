package router

import (
	"go/ast"
	"go/parser"
	"go/token"
	"os"
	"path/filepath"
	"strconv"
	"strings"
	"testing"
)

// gatewayErrorEmitters maps each buyer-facing error-writer function in this
// package to the 0-based index of its `code` string parameter, for the AST
// completeness guard (TestGatewayEmittedLiteralCodesAreClassified).
//
//	writeError(w, status, typ, code, message)             -> 3
//	writeSSEError(w, message, errType, code)              -> 3
//	writeSpec019PreflightError(w, status, code, msg, param) -> 1
//
// The 429 concurrency path passes its code as the `concurrencyErrCode` variable
// (always account_concurrency_exceeded or demo_concurrency_exceeded), which is
// not a literal at the call site and is therefore covered by the hand-curated
// gatewayEmittedErrorCodes inventory rather than this guard.
var gatewayErrorEmitters = map[string]int{
	"writeError":                 3,
	"writeSSEError":              3,
	"writeSpec019PreflightError": 1,
}

// collectLiteralEmittedCodes parses every non-test .go file in the current
// package directory and returns the set of STRING-LITERAL code arguments passed
// to any emitter (keyed by the code-argument index). Variable/selector-routed
// codes are skipped — static AST inspection cannot resolve their runtime value.
func collectLiteralEmittedCodes(t *testing.T, emitters map[string]int) map[string]token.Position {
	t.Helper()
	fset := token.NewFileSet()
	entries, err := os.ReadDir(".")
	if err != nil {
		t.Fatalf("read package dir: %v", err)
	}
	found := map[string]token.Position{}
	parsedAny := false
	for _, entry := range entries {
		name := entry.Name()
		if entry.IsDir() || !strings.HasSuffix(name, ".go") || strings.HasSuffix(name, "_test.go") {
			continue
		}
		file, err := parser.ParseFile(fset, filepath.Clean(name), nil, 0)
		if err != nil {
			t.Fatalf("parse %s: %v", name, err)
		}
		parsedAny = true
		inspectFileForLiteralCodes(file, fset, emitters, found)
	}
	if !parsedAny {
		t.Fatal("no non-test .go files parsed — is the test running from the package directory?")
	}
	return found
}

// inspectFileForLiteralCodes is the AST-walk core, factored out so extraction
// can be exercised against a synthetic snippet as well as the real source.
func inspectFileForLiteralCodes(file *ast.File, fset *token.FileSet, emitters map[string]int, found map[string]token.Position) {
	ast.Inspect(file, func(n ast.Node) bool {
		call, ok := n.(*ast.CallExpr)
		if !ok {
			return true
		}
		ident, ok := call.Fun.(*ast.Ident)
		if !ok {
			return true
		}
		idx, ok := emitters[ident.Name]
		if !ok || idx >= len(call.Args) {
			return true
		}
		lit, ok := call.Args[idx].(*ast.BasicLit)
		if !ok || lit.Kind != token.STRING {
			return true // variable/selector-routed code — covered by the hand-curated inventory
		}
		code, err := strconv.Unquote(lit.Value)
		if err != nil {
			return true
		}
		if _, seen := found[code]; !seen {
			found[code] = fset.Position(lit.Pos())
		}
		return true
	})
}

// TestGatewayEmittedLiteralCodesAreClassified is the AST/registration-based
// completeness guard (runbook item 21). It parses this package's source at test
// time and asserts every STRING-LITERAL `code` argument at an error-writer call
// site (gatewayErrorEmitters) is triaged into EXACTLY one of
// gatewayRetryableByCode / gatewayPermanentCodes — so a new
// `writeError(w, status, typ, "new_code", msg)` fails CI merely by existing,
// with no edit to any hand-curated list. It also cross-checks that the
// hand-curated gatewayEmittedErrorCodes inventory has not gone stale by omitting
// a literal that appears in source (the round-3 failure mode gatewayEmittedErrorCodes
// "almost" fell into).
//
// Residual (documented, SPEC-006 §5.2 "Known carried items" (5)): the 429
// concurrency code reaches writeError through the `concurrencyErrCode` variable
// and is not a literal at the call site; it remains covered by
// gatewayEmittedErrorCodes + TestGatewayErrorCodeCompleteness.
func TestGatewayEmittedLiteralCodesAreClassified(t *testing.T) {
	literals := collectLiteralEmittedCodes(t, gatewayErrorEmitters)
	if len(literals) == 0 {
		t.Fatal("AST scan found no literal error codes — gatewayErrorEmitters names or indices are wrong")
	}
	inventory := make(map[string]bool, len(gatewayEmittedErrorCodes))
	for _, c := range gatewayEmittedErrorCodes {
		inventory[c] = true
	}
	for code, pos := range literals {
		_, inRetryable := gatewayRetryableByCode[code]
		_, inPermanent := gatewayPermanentCodes[code]
		switch {
		case !inRetryable && !inPermanent:
			t.Errorf("emitted literal code %q (%s) is in neither gatewayRetryableByCode nor gatewayPermanentCodes — classify it (this is the future-code guard firing)", code, pos)
		case inRetryable && inPermanent:
			t.Errorf("emitted literal code %q (%s) is in BOTH classification maps — remove it from one", code, pos)
		}
		if !inventory[code] {
			t.Errorf("emitted literal code %q (%s) is missing from gatewayEmittedErrorCodes — the hand-curated inventory went stale", code, pos)
		}
	}
}

// TestGatewayErrorCodeASTGuardCatchesNewLiteral proves the extraction fires on a
// synthetic emitter call with a new literal code (and ignores a variable code
// arg), so an unclassified new code WOULD fail the guard above.
func TestGatewayErrorCodeASTGuardCatchesNewLiteral(t *testing.T) {
	const src = `package router
func f(w any) {
	writeError(w, 500, "api_error", "totally_new_unclassified_code", "boom")
	writeSSEError(w, "msg", "api_error", "another_new_sse_code")
	writeError(w, 429, "rate_limit_exceeded", concurrencyErrCode, "variable code must be ignored")
}`
	fset := token.NewFileSet()
	file, err := parser.ParseFile(fset, "synthetic.go", src, 0)
	if err != nil {
		t.Fatalf("parse synthetic source: %v", err)
	}
	found := map[string]token.Position{}
	inspectFileForLiteralCodes(file, fset, gatewayErrorEmitters, found)
	if _, ok := found["totally_new_unclassified_code"]; !ok {
		t.Error("guard did not extract the literal code from writeError — a new unclassified code would slip through")
	}
	if _, ok := found["another_new_sse_code"]; !ok {
		t.Error("guard did not extract the literal code from writeSSEError")
	}
	if len(found) != 2 {
		t.Errorf("expected exactly 2 literal codes (variable arg must be skipped), got %d: %v", len(found), found)
	}
	for code := range found {
		_, inR := gatewayRetryableByCode[code]
		_, inP := gatewayPermanentCodes[code]
		if inR || inP {
			t.Errorf("synthetic code %q unexpectedly classified", code)
		}
	}
}
