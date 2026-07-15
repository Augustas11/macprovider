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

// coordinatorErrorEmitters is the SET of functions whose `code` string argument
// must carry a code explicitly classified in spec018RetryableByCode. The 0-based
// index of that argument is DERIVED from each function's real signature at test
// time (the parameter named "code") — never hand-maintained — so a signature
// change or a mis-typed index cannot silently drift the guard past a writer's
// codes (the first cut of this guard hand-indexed a writer wrong and skipped its
// codes entirely).
//
// The set covers the buyer-facing error WRITERS and the retryability CLASSIFIER
// (spec018Retryable): an inline error envelope that computes its `retryable`
// field via spec018Retryable("literal_code") — instead of routing through a
// writer — is still caught, because that classifier call carries the code
// literal. (The gateway's writeStructuredOutputTimeoutSSE is the pattern this
// closes on that side; the coordinator has no such inline emitter today, but the
// classifier registration future-proofs it symmetrically.)
//
// writeSSEErrorWithRetryable is added by item 20 (#594) and is absent on
// origin/main until it merges; the name simply resolves to no FuncDecl and no
// calls here, and auto-covers once #594 lands.
var coordinatorErrorEmitters = map[string]bool{
	"writeError":                         true,
	"writeErrorWithParam":                true,
	"writeErrorTyped":                    true,
	"writeErrorTypedParam":               true,
	"writeSSEError":                      true,
	"writeSSEErrorWithRetryable":         true,
	"writeProviderStructuredOutputError": true,
	"spec018Retryable":                   true,
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
// a hand-written index. Emitters with no FuncDecl in this package (e.g. an
// item-20 forward reference) simply do not appear in the result.
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
// a variable/selector/call (validation-helper returns, routeError.code, tier-2
// blockReason, end.Status) is not a literal at the call site and is skipped — the
// AST cannot resolve its runtime value.
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

// TestCoordinatorEmittedLiteralCodesAreClassified is the AST/registration-based
// completeness guard (runbook item 21). It parses this package's source at test
// time, derives each error-writer / classifier's `code` argument index from its
// real signature, extracts every STRING-LITERAL code argument, and asserts each
// has an explicit spec018RetryableByCode entry — so a new `writeError(w, status,
// "new_code", msg)` (or an inline envelope built with spec018Retryable("new"))
// fails CI merely by existing, with no edit to any hand-curated list. It also
// cross-checks that coordinatorEmittedErrorCodes has not gone stale by omitting a
// literal that appears in source (the round-3 failure mode that let 3 codes ship
// unclassified).
//
// Residual (documented, SPEC-006 §5.2 "Known carried items" (5)): codes that
// reach an emitter through a VARIABLE — validation-helper (status, code, msg)
// returns, routeError.code via writeRouteError, tier-2 blockReason, and the
// provider-supplied end.Status forwarded to writeSSEError /
// writeProviderStructuredOutputError — are not literals at the call site and
// cannot be statically resolved. Those remain covered by
// coordinatorEmittedErrorCodes + TestCoordinatorErrorCodeCompleteness, and the
// finite provider-detail allowlist is pinned by
// TestSpec019ProviderDetailCodesClassifiedAndInventoried below.
func TestCoordinatorEmittedLiteralCodesAreClassified(t *testing.T) {
	fset, files := parsePackageFiles(t)
	codeIdx := deriveCodeArgIndices(files, coordinatorErrorEmitters)
	if len(codeIdx) == 0 {
		t.Fatal("derived no emitter code-arg indices — coordinatorErrorEmitters names are wrong")
	}
	literals := inspectFilesForLiteralCodes(files, fset, codeIdx)
	if len(literals) == 0 {
		t.Fatal("AST scan found no literal error codes — emitter set or derivation is broken")
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

// TestSpec019ProviderDetailCodesClassifiedAndInventoried pins the finite
// provider-detail terminal allowlist (isSpec019ProviderDetailCode), which reaches
// writeSSEError / writeProviderStructuredOutputError through the variable
// end.Status and so is invisible to the literal AST guard. If a future member is
// added to that allowlist it must be classified and inventoried, or this fails.
func TestSpec019ProviderDetailCodesClassifiedAndInventoried(t *testing.T) {
	detail := []string{
		"malformed_json_response",
		"json_schema_validation_failed",
		"response_byte_cap_exceeded",
		"provider_timeout",
	}
	inventory := make(map[string]bool, len(coordinatorEmittedErrorCodes))
	for _, c := range coordinatorEmittedErrorCodes {
		inventory[c] = true
	}
	for _, code := range detail {
		if !isSpec019ProviderDetailCode(code) {
			t.Errorf("provider-detail allowlist drift: %q is no longer isSpec019ProviderDetailCode — reconcile this pinned list", code)
		}
		if _, ok := spec018RetryableByCode[code]; !ok {
			t.Errorf("provider-detail code %q has no spec018RetryableByCode entry", code)
		}
		if !inventory[code] {
			t.Errorf("provider-detail code %q missing from coordinatorEmittedErrorCodes", code)
		}
	}
}

// TestCoordinatorErrorCodeGuardDerivesAndExtracts is the mechanism test: it runs
// the derivation + extraction over a synthetic snippet that DEFINES emitter
// signatures (so the index is derived, not assumed) and calls them, proving a new
// literal code is caught, a classifier literal is caught, and a variable arg is
// ignored. Without this, the real guard passing on clean source would not
// distinguish "correctly classified" from "the walk silently matched nothing".
func TestCoordinatorErrorCodeGuardDerivesAndExtracts(t *testing.T) {
	const src = `package buyer
func writeError(w, status, code, message string) {}
func writeErrorTyped(w, status, typ, code, message string) {}
func spec018Retryable(code string) bool { return false }
func caller(w, x string) {
	writeError(w, x, "new_writer_literal", "boom")
	writeErrorTyped(w, x, "api_error", "new_typed_literal", "boom")
	spec018Retryable("new_inline_classifier_literal")
	writeError(w, x, someVar, "variable code must be ignored")
}`
	fset := token.NewFileSet()
	file, err := parser.ParseFile(fset, "synthetic.go", src, 0)
	if err != nil {
		t.Fatalf("parse synthetic source: %v", err)
	}
	files := []*ast.File{file}
	codeIdx := deriveCodeArgIndices(files, coordinatorErrorEmitters)
	if codeIdx["writeError"] != 2 {
		t.Errorf("derived writeError code index = %d, want 2", codeIdx["writeError"])
	}
	if codeIdx["writeErrorTyped"] != 3 {
		t.Errorf("derived writeErrorTyped code index = %d, want 3", codeIdx["writeErrorTyped"])
	}
	if codeIdx["spec018Retryable"] != 0 {
		t.Errorf("derived spec018Retryable code index = %d, want 0", codeIdx["spec018Retryable"])
	}
	found := inspectFilesForLiteralCodes(files, fset, codeIdx)
	for _, want := range []string{"new_writer_literal", "new_typed_literal", "new_inline_classifier_literal"} {
		if _, ok := found[want]; !ok {
			t.Errorf("guard did not extract %q — a new unclassified code would slip through", want)
		}
	}
	if len(found) != 3 {
		t.Errorf("expected exactly 3 literal codes (variable arg must be skipped), got %d: %v", len(found), found)
	}
	for code := range found {
		if _, ok := spec018RetryableByCode[code]; ok {
			t.Errorf("synthetic code %q unexpectedly exists in spec018RetryableByCode", code)
		}
	}
}
