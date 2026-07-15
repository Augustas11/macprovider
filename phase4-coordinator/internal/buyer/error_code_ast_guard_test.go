package buyer

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

// coordinatorErrorEmitters maps each buyer-facing error-writer function in this
// package to the 0-based index of its `code` string parameter. It is the
// registry the AST completeness guard (TestCoordinatorEmittedLiteralCodesAreClassified)
// walks the package source for.
//
//	writeError(w, status, code, message)                              -> 2
//	writeErrorWithParam(w, status, code, message, param)              -> 2
//	writeErrorTyped(w, status, typ, code, message)                    -> 3
//	writeErrorTypedParam(w, status, typ, code, message, param)        -> 3
//	writeSSEError(w, message, code, requestID...)                     -> 2
//	writeSSEErrorWithRetryable(w, message, code, override, requestID) -> 2
//	writeProviderStructuredOutputError(w, status, code, message, ret) -> 2
//
// writeRouteError(w, *routeError) carries no code argument — its code travels
// inside the struct as a variable and is therefore covered by the hand-curated
// coordinatorEmittedErrorCodes inventory, not this AST guard.
var coordinatorErrorEmitters = map[string]int{
	"writeError":                         2,
	"writeErrorWithParam":                2,
	"writeErrorTyped":                    3,
	"writeErrorTypedParam":               3,
	"writeSSEError":                      2,
	"writeSSEErrorWithRetryable":         2,
	"writeProviderStructuredOutputError": 2,
}

// collectLiteralEmittedCodes parses every non-test .go file in the current
// package directory and returns the set of STRING-LITERAL code arguments passed
// to any function in emitters (keyed by the code-argument index). A code passed
// as a variable/selector/call (e.g. a validation-helper return, routeError.code,
// a tier-2 blockReason) is not a literal at the call site and is deliberately
// skipped — the AST cannot resolve its runtime value; those remain on the
// hand-curated inventory.
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

// inspectFileForLiteralCodes is the AST-walk core, factored out so the guard's
// extraction can be exercised against a synthetic snippet (see
// TestErrorCodeASTGuardCatchesNewLiteral) as well as the real package source.
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

// TestErrorCodeASTGuardCatchesNewLiteral proves the guard's extraction actually
// fires: a synthetic writeError call with a brand-new literal code is discovered
// by the same inspection the real guard uses, so an unclassified new code WOULD
// fail TestCoordinatorEmittedLiteralCodesAreClassified. Without this, the guard
// passing on clean source would not distinguish "correctly classified" from
// "the AST walk silently matched nothing".
func TestErrorCodeASTGuardCatchesNewLiteral(t *testing.T) {
	const src = `package buyer
func f(w any) {
	writeError(w, 500, "totally_new_unclassified_code", "boom")
	writeSSEError(w, "msg", "another_new_sse_code")
	writeError(w, 500, someVar, "variable code must be ignored")
}`
	fset := token.NewFileSet()
	file, err := parser.ParseFile(fset, "synthetic.go", src, 0)
	if err != nil {
		t.Fatalf("parse synthetic source: %v", err)
	}
	found := map[string]token.Position{}
	inspectFileForLiteralCodes(file, fset, coordinatorErrorEmitters, found)
	if _, ok := found["totally_new_unclassified_code"]; !ok {
		t.Error("guard did not extract the literal code from writeError — a new unclassified code would slip through")
	}
	if _, ok := found["another_new_sse_code"]; !ok {
		t.Error("guard did not extract the literal code from writeSSEError")
	}
	if len(found) != 2 {
		t.Errorf("expected exactly 2 literal codes (variable arg must be skipped), got %d: %v", len(found), found)
	}
	// Confirm these synthetic codes are indeed unclassified, so the real guard
	// would report them.
	for code := range found {
		if _, ok := spec018RetryableByCode[code]; ok {
			t.Errorf("synthetic code %q unexpectedly exists in spec018RetryableByCode", code)
		}
	}
}

// TestCoordinatorEmittedLiteralCodesAreClassified is the AST/registration-based
// completeness guard (runbook item 21) that makes the "a new emitted code fails
// CI" claim literally true for the common case. It parses this package's source
// at test time and asserts every STRING-LITERAL `code` argument at an
// error-writer call site (coordinatorErrorEmitters) has an explicit
// spec018RetryableByCode entry — so a brand-new `writeError(w, status,
// "new_code", msg)` fails CI merely by existing, with no edit to any hand-curated
// list. It also cross-checks that the hand-curated coordinatorEmittedErrorCodes
// inventory has not gone stale by omitting a literal that appears in source
// (the exact round-3 failure mode that let 3 codes ship unclassified).
//
// Residual (documented, SPEC-006 §5.2 "Known carried items" (5)): codes that
// reach an emitter through a variable — validation-helper `(status, code, msg)`
// returns, `routeError.code` via writeRouteError, tier-2 `blockReason` — are not
// literals at the call site and cannot be resolved by static AST inspection.
// Those remain covered by coordinatorEmittedErrorCodes +
// TestCoordinatorErrorCodeCompleteness. This guard closes the far larger
// direct-literal surface, which is how virtually every new code is introduced.
func TestCoordinatorEmittedLiteralCodesAreClassified(t *testing.T) {
	literals := collectLiteralEmittedCodes(t, coordinatorErrorEmitters)
	if len(literals) == 0 {
		t.Fatal("AST scan found no literal error codes — coordinatorErrorEmitters names or indices are wrong")
	}
	inventory := make(map[string]bool, len(coordinatorEmittedErrorCodes))
	for _, c := range coordinatorEmittedErrorCodes {
		inventory[c] = true
	}
	for code, pos := range literals {
		if _, ok := spec018RetryableByCode[code]; !ok {
			t.Errorf("emitted literal code %q (%s) has no explicit spec018RetryableByCode entry — classify it (this is the future-code guard firing)", code, pos)
		}
		if !inventory[code] {
			t.Errorf("emitted literal code %q (%s) is missing from coordinatorEmittedErrorCodes — the hand-curated inventory went stale", code, pos)
		}
	}
}
