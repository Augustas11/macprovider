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

// gatewayErrorEmitters is the SET of functions whose `code` string argument must
// be triaged into EXACTLY one of gatewayRetryableByCode / gatewayPermanentCodes.
// The 0-based index of that argument is DERIVED from each function's real
// signature at test time (the parameter named "code") — never hand-maintained —
// so a signature change or a mis-typed index cannot silently drift the guard past
// a writer's codes (the first cut of this guard hand-indexed writeSpec019PreflightError
// wrong and skipped every preflight code).
//
// The set covers the buyer-facing error WRITERS and the retryability CLASSIFIER
// (gatewayRetryable): an inline error envelope that computes its `retryable` field
// via gatewayRetryable("literal_code") — instead of routing through a writer, as
// writeStructuredOutputTimeoutSSE does — is still caught, because that classifier
// call carries the code literal.
var gatewayErrorEmitters = map[string]bool{
	"writeError":                 true,
	"writeSSEError":              true,
	"writeSpec019PreflightError": true,
	"gatewayRetryable":           true,
}

// parsePackageFiles parses every non-test .go file in the current package dir.
func parsePackageFiles(t *testing.T) (*token.FileSet, []*ast.File) {
	t.Helper()
	fset := token.NewFileSet()
	entries, err := os.ReadDir(".")
	if err != nil {
		t.Fatalf("read package dir: %v", err)
	}
	var files []*ast.File
	for _, entry := range entries {
		name := entry.Name()
		if entry.IsDir() || !strings.HasSuffix(name, ".go") || strings.HasSuffix(name, "_test.go") {
			continue
		}
		file, err := parser.ParseFile(fset, filepath.Clean(name), nil, 0)
		if err != nil {
			t.Fatalf("parse %s: %v", name, err)
		}
		files = append(files, file)
	}
	if len(files) == 0 {
		t.Fatal("no non-test .go files parsed — is the test running from the package directory?")
	}
	return fset, files
}

// deriveCodeArgIndices returns, for each emitter name whose FuncDecl is present
// in files, the flattened 0-based index of its parameter named "code". A change
// to any emitter's signature is reflected automatically — the guard never trusts
// a hand-written index.
func deriveCodeArgIndices(files []*ast.File, emitters map[string]bool) map[string]int {
	idx := map[string]int{}
	for _, file := range files {
		for _, decl := range file.Decls {
			fn, ok := decl.(*ast.FuncDecl)
			if !ok || fn.Recv != nil || !emitters[fn.Name.Name] || fn.Type.Params == nil {
				continue
			}
			pos := 0
			for _, field := range fn.Type.Params.List {
				if len(field.Names) == 0 { // unnamed parameter
					pos++
					continue
				}
				for _, name := range field.Names {
					if name.Name == "code" {
						idx[fn.Name.Name] = pos
					}
					pos++
				}
			}
		}
	}
	return idx
}

// inspectFilesForLiteralCodes walks every call in files to a name in codeIdx and
// records the STRING-LITERAL argument at that name's code index. A code passed as
// a variable/selector/call (the gateway concurrencyErrCode) is not a literal at
// the call site and is skipped — the AST cannot resolve its runtime value.
func inspectFilesForLiteralCodes(files []*ast.File, fset *token.FileSet, codeIdx map[string]int) map[string]token.Position {
	found := map[string]token.Position{}
	for _, file := range files {
		ast.Inspect(file, func(n ast.Node) bool {
			call, ok := n.(*ast.CallExpr)
			if !ok {
				return true
			}
			ident, ok := call.Fun.(*ast.Ident)
			if !ok {
				return true
			}
			idx, ok := codeIdx[ident.Name]
			if !ok || idx >= len(call.Args) {
				return true
			}
			lit, ok := call.Args[idx].(*ast.BasicLit)
			if !ok || lit.Kind != token.STRING {
				return true
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
	return found
}

// TestGatewayEmittedLiteralCodesAreClassified is the AST/registration-based
// completeness guard (runbook item 21). It parses this package's source at test
// time, derives each error-writer / classifier's `code` argument index from its
// real signature, extracts every STRING-LITERAL code argument, and asserts each
// is triaged into EXACTLY one of gatewayRetryableByCode / gatewayPermanentCodes —
// so a new `writeError(w, status, typ, "new_code", msg)` (or an inline envelope
// built with gatewayRetryable("new"), e.g. writeStructuredOutputTimeoutSSE) fails
// CI merely by existing, with no edit to any hand-curated list. It also
// cross-checks that gatewayEmittedErrorCodes has not gone stale by omitting a
// literal that appears in source (the round-3 failure mode gatewayEmittedErrorCodes
// "almost" fell into).
//
// Residual (documented, SPEC-006 §5.2 "Known carried items" (5)): the 429
// concurrency code reaches writeError through the `concurrencyErrCode` variable
// and is not a literal at the call site; it remains covered by
// gatewayEmittedErrorCodes + TestGatewayErrorCodeCompleteness, and its finite
// value set is pinned by TestGatewayConcurrencyCodesClassifiedAndInventoried.
func TestGatewayEmittedLiteralCodesAreClassified(t *testing.T) {
	fset, files := parsePackageFiles(t)
	codeIdx := deriveCodeArgIndices(files, gatewayErrorEmitters)
	if len(codeIdx) == 0 {
		t.Fatal("derived no emitter code-arg indices — gatewayErrorEmitters names are wrong")
	}
	literals := inspectFilesForLiteralCodes(files, fset, codeIdx)
	if len(literals) == 0 {
		t.Fatal("AST scan found no literal error codes — emitter set or derivation is broken")
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

// TestGatewayConcurrencyCodesClassifiedAndInventoried pins the finite value set
// of the concurrencyErrCode variable (account_concurrency_exceeded /
// demo_concurrency_exceeded), which reaches writeError as a variable and so is
// invisible to the literal AST guard.
func TestGatewayConcurrencyCodesClassifiedAndInventoried(t *testing.T) {
	inventory := make(map[string]bool, len(gatewayEmittedErrorCodes))
	for _, c := range gatewayEmittedErrorCodes {
		inventory[c] = true
	}
	for _, code := range []string{"account_concurrency_exceeded", "demo_concurrency_exceeded"} {
		_, inR := gatewayRetryableByCode[code]
		_, inP := gatewayPermanentCodes[code]
		if !inR && !inP {
			t.Errorf("concurrency code %q is classified in neither map", code)
		}
		if !inventory[code] {
			t.Errorf("concurrency code %q missing from gatewayEmittedErrorCodes", code)
		}
	}
}

// TestGatewayErrorCodeGuardDerivesAndExtracts is the mechanism test: it runs the
// derivation + extraction over a synthetic snippet that DEFINES emitter
// signatures (so the index is derived, not assumed) and calls them, proving a new
// writer literal, a preflight literal, and an inline classifier literal are all
// caught while a variable arg is ignored.
func TestGatewayErrorCodeGuardDerivesAndExtracts(t *testing.T) {
	const src = `package router
func writeError(w, status, typ, code, message string) {}
func writeSpec019PreflightError(w, status, code, message, param string) {}
func gatewayRetryable(code string) bool { return false }
func caller(w, x string) {
	writeError(w, x, "api_error", "new_writer_literal", "boom")
	writeSpec019PreflightError(w, x, "new_preflight_literal", "boom", "p")
	gatewayRetryable("new_inline_classifier_literal")
	writeError(w, x, "api_error", concurrencyErrCode, "variable code must be ignored")
}`
	fset := token.NewFileSet()
	file, err := parser.ParseFile(fset, "synthetic.go", src, 0)
	if err != nil {
		t.Fatalf("parse synthetic source: %v", err)
	}
	files := []*ast.File{file}
	codeIdx := deriveCodeArgIndices(files, gatewayErrorEmitters)
	if codeIdx["writeError"] != 3 {
		t.Errorf("derived writeError code index = %d, want 3", codeIdx["writeError"])
	}
	if codeIdx["writeSpec019PreflightError"] != 2 {
		t.Errorf("derived writeSpec019PreflightError code index = %d, want 2 (the R1 bug had it at 1)", codeIdx["writeSpec019PreflightError"])
	}
	if codeIdx["gatewayRetryable"] != 0 {
		t.Errorf("derived gatewayRetryable code index = %d, want 0", codeIdx["gatewayRetryable"])
	}
	found := inspectFilesForLiteralCodes(files, fset, codeIdx)
	for _, want := range []string{"new_writer_literal", "new_preflight_literal", "new_inline_classifier_literal"} {
		if _, ok := found[want]; !ok {
			t.Errorf("guard did not extract %q — a new unclassified code would slip through", want)
		}
	}
	if len(found) != 3 {
		t.Errorf("expected exactly 3 literal codes (variable arg must be skipped), got %d: %v", len(found), found)
	}
	for code := range found {
		_, inR := gatewayRetryableByCode[code]
		_, inP := gatewayPermanentCodes[code]
		if inR || inP {
			t.Errorf("synthetic code %q unexpectedly classified", code)
		}
	}
}
