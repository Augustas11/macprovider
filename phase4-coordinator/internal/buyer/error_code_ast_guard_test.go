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
// codes.
//
// The set covers the buyer-facing error WRITERS and the retryability CLASSIFIER
// (spec018Retryable): an inline error envelope that computes its `retryable` field
// via spec018Retryable("literal_code") is caught because the classifier call
// carries the code literal. (Inline envelopes are ALSO scanned directly by the
// composite-literal pass, so the emitted `"code"` field is checked even if it is
// decoupled from the classifier argument.)
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

// coordinatorAllowAbsentEmitters lists registered emitters that may legitimately
// have no FuncDecl in the current source — a forward reference to a function an
// in-flight change adds. Every OTHER registered emitter MUST resolve a `code`
// parameter, or the guard fails (a renamed function/parameter must not silently
// drop out of the scan — that recreated the original skipped-emitter defect).
var coordinatorAllowAbsentEmitters = map[string]bool{
	"writeSSEErrorWithRetryable": true, // added by item 20 (#594); absent on origin/main until it merges
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

// funcDeclNames returns the set of top-level (non-method) function names in files.
func funcDeclNames(files []*ast.File) map[string]bool {
	names := map[string]bool{}
	for _, file := range files {
		for _, decl := range file.Decls {
			if fn, ok := decl.(*ast.FuncDecl); ok && fn.Recv == nil {
				names[fn.Name.Name] = true
			}
		}
	}
	return names
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

// unresolvedEmitters returns a problem message for any registered emitter that IS
// declared in source but did not resolve a `code` parameter (renamed
// function/param — the fail-open case), or that matches no declaration and is not
// an allowed forward reference (typo). Empty result means every emitter is
// accounted for. Pure so the fail-open detection is unit-testable.
func unresolvedEmitters(emitters, allowAbsent, declared map[string]bool, codeIdx map[string]int) []string {
	var problems []string
	for name := range emitters {
		_, resolved := codeIdx[name]
		switch {
		case resolved:
			// ok
		case declared[name]:
			problems = append(problems, "emitter "+name+" is declared but no `code` parameter was found — was the parameter renamed? the guard would silently skip its codes")
		case allowAbsent[name]:
			// ok: genuine forward reference, no declaration yet
		default:
			problems = append(problems, "emitter "+name+" resolved no code index and is not a declared function or an allowed forward reference — check the registry name for a typo")
		}
	}
	return problems
}

// inspectFilesForLiteralCodes walks every call in files to a name in codeIdx and
// records the STRING-LITERAL argument at that name's code index. Variable/
// selector-routed codes are skipped — the AST cannot resolve their runtime value.
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

// inspectFilesForEnvelopeCodeLiterals catches inline error envelopes — a map
// composite literal that carries BOTH a string-literal `"code"` field AND a
// `"retryable"` key (the buyer-facing classified-envelope shape, e.g. the
// gateway's writeStructuredOutputTimeoutSSE). This checks the EMITTED `"code"`
// value directly, so it is caught even when decoupled from any classifier call.
// The `"retryable"` sibling requirement scopes it to buyer envelopes and excludes
// operator/explorer maps that carry a literal `"code"` but no retryable field.
func inspectFilesForEnvelopeCodeLiterals(files []*ast.File, fset *token.FileSet) map[string]token.Position {
	found := map[string]token.Position{}
	for _, file := range files {
		ast.Inspect(file, func(n ast.Node) bool {
			cl, ok := n.(*ast.CompositeLit)
			if !ok {
				return true
			}
			var codeLit *ast.BasicLit
			hasRetryable := false
			for _, elt := range cl.Elts {
				kv, ok := elt.(*ast.KeyValueExpr)
				if !ok {
					continue
				}
				key, ok := kv.Key.(*ast.BasicLit)
				if !ok || key.Kind != token.STRING {
					continue
				}
				keyName, err := strconv.Unquote(key.Value)
				if err != nil {
					continue
				}
				switch keyName {
				case "retryable":
					hasRetryable = true
				case "code":
					if v, ok := kv.Value.(*ast.BasicLit); ok && v.Kind == token.STRING {
						codeLit = v
					}
				}
			}
			if hasRetryable && codeLit != nil {
				if code, err := strconv.Unquote(codeLit.Value); err == nil {
					if _, seen := found[code]; !seen {
						found[code] = fset.Position(codeLit.Pos())
					}
				}
			}
			return true
		})
	}
	return found
}

// switchCaseLiteralsInFunc returns every string-literal case expression inside
// the named top-level function's switch statements. Used to pin a finite
// variable-routed allowlist (e.g. isSpec019ProviderDetailCode) directly from
// source, so a newly-added case is covered automatically rather than requiring a
// hand-maintained mirror slice.
func switchCaseLiteralsInFunc(files []*ast.File, funcName string) []string {
	var out []string
	for _, file := range files {
		for _, decl := range file.Decls {
			fn, ok := decl.(*ast.FuncDecl)
			if !ok || fn.Name.Name != funcName || fn.Body == nil {
				continue
			}
			ast.Inspect(fn.Body, func(n ast.Node) bool {
				cc, ok := n.(*ast.CaseClause)
				if !ok {
					return true
				}
				for _, e := range cc.List {
					if lit, ok := e.(*ast.BasicLit); ok && lit.Kind == token.STRING {
						if s, err := strconv.Unquote(lit.Value); err == nil {
							out = append(out, s)
						}
					}
				}
				return true
			})
		}
	}
	return out
}

// TestCoordinatorEmittedLiteralCodesAreClassified is the AST/registration-based
// completeness guard (runbook item 21). It parses this package's source at test
// time, derives each error-writer / classifier's `code` argument index from its
// real signature, extracts every STRING-LITERAL code argument (at emitter call
// sites AND in inline `code`+`retryable` envelopes), and asserts each has an
// explicit spec018RetryableByCode entry — so a new emitted literal code fails CI
// merely by existing, with no edit to any hand-curated list. It also cross-checks
// coordinatorEmittedErrorCodes for staleness, and asserts every registered
// emitter still resolves (no silent per-emitter drop).
//
// Residual (documented, SPEC-006 §5.2 "Known carried items" (5)): codes that
// reach an emitter through a VARIABLE — validation-helper (status, code, msg)
// returns, routeError.code via writeRouteError, tier-2 blockReason, and the
// provider-supplied end.Status forwarded to writeSSEError /
// writeProviderStructuredOutputError — are not literals at the call site. Those
// remain covered by coordinatorEmittedErrorCodes + TestCoordinatorErrorCodeCompleteness;
// the finite provider-detail allowlist is pinned directly from the
// isSpec019ProviderDetailCode switch by TestSpec019ProviderDetailCodesClassifiedAndInventoried.
func TestCoordinatorEmittedLiteralCodesAreClassified(t *testing.T) {
	fset, files := parsePackageFiles(t)
	codeIdx := deriveCodeArgIndices(files, coordinatorErrorEmitters)
	for _, p := range unresolvedEmitters(coordinatorErrorEmitters, coordinatorAllowAbsentEmitters, funcDeclNames(files), codeIdx) {
		t.Error(p)
	}
	if len(codeIdx) == 0 {
		t.Fatal("derived no emitter code-arg indices — coordinatorErrorEmitters names are wrong")
	}
	literals := inspectFilesForLiteralCodes(files, fset, codeIdx)
	for code, pos := range inspectFilesForEnvelopeCodeLiterals(files, fset) {
		if _, ok := literals[code]; !ok {
			literals[code] = pos
		}
	}
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
// provider-detail terminal allowlist, which reaches writeSSEError /
// writeProviderStructuredOutputError through the variable end.Status and so is
// invisible to the literal AST guard. The allowlist is read DIRECTLY from the
// isSpec019ProviderDetailCode switch cases, so a newly-added case is covered
// automatically (no hand-maintained mirror to go stale).
func TestSpec019ProviderDetailCodesClassifiedAndInventoried(t *testing.T) {
	_, files := parsePackageFiles(t)
	detail := switchCaseLiteralsInFunc(files, "isSpec019ProviderDetailCode")
	if len(detail) == 0 {
		t.Fatal("extracted no provider-detail case literals — was isSpec019ProviderDetailCode renamed?")
	}
	inventory := make(map[string]bool, len(coordinatorEmittedErrorCodes))
	for _, c := range coordinatorEmittedErrorCodes {
		inventory[c] = true
	}
	for _, code := range detail {
		if _, ok := spec018RetryableByCode[code]; !ok {
			t.Errorf("provider-detail code %q has no spec018RetryableByCode entry", code)
		}
		if !inventory[code] {
			t.Errorf("provider-detail code %q missing from coordinatorEmittedErrorCodes", code)
		}
	}
}

// TestUnresolvedEmittersDetectsFailOpen proves the strict-resolution check
// (fix for the R2 "derivation fails open" finding): a registered emitter that is
// declared but whose `code` parameter did not resolve, and a registry typo that
// matches no declaration, are both flagged — while a genuine forward reference
// (declared nowhere, on the allow-absent list) is not.
func TestUnresolvedEmittersDetectsFailOpen(t *testing.T) {
	emitters := map[string]bool{"present": true, "renamed": true, "typo": true, "forwardRef": true}
	allowAbsent := map[string]bool{"forwardRef": true}
	declared := map[string]bool{"present": true, "renamed": true} // "typo"/"forwardRef" not declared
	codeIdx := map[string]int{"present": 2}                        // "renamed" declared but code param not found

	problems := unresolvedEmitters(emitters, allowAbsent, declared, codeIdx)
	got := strings.Join(problems, "\n")
	if !strings.Contains(got, "renamed") {
		t.Errorf("declared-but-unresolved emitter not flagged: %q", got)
	}
	if !strings.Contains(got, "typo") {
		t.Errorf("undeclared non-forward-ref emitter not flagged: %q", got)
	}
	if strings.Contains(got, "present") {
		t.Errorf("resolved emitter wrongly flagged: %q", got)
	}
	if strings.Contains(got, "forwardRef") {
		t.Errorf("allowed forward reference wrongly flagged: %q", got)
	}
	if len(problems) != 2 {
		t.Errorf("expected exactly 2 problems (renamed + typo), got %d: %v", len(problems), problems)
	}
}

// TestCoordinatorErrorCodeGuardDerivesAndExtracts is the mechanism test: it runs
// derivation + extraction over a synthetic snippet that DEFINES emitter
// signatures (so indices are derived, not assumed) and calls them, proving a new
// writer literal, a typed-writer literal, an inline classifier literal, and an
// inline `code`+`retryable` envelope literal are all caught while a variable arg
// is ignored.
func TestCoordinatorErrorCodeGuardDerivesAndExtracts(t *testing.T) {
	const src = `package buyer
func writeError(w, status, code, message string) {}
func writeErrorTyped(w, status, typ, code, message string) {}
func spec018Retryable(code string) bool { return false }
func caller(w, x string) {
	writeError(w, x, "new_writer_literal", "boom")
	writeErrorTyped(w, x, "api_error", "new_typed_literal", "boom")
	spec018Retryable("new_inline_classifier_literal")
	_ = map[string]any{"code": "new_envelope_literal", "retryable": false}
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
	for code, pos := range inspectFilesForEnvelopeCodeLiterals(files, fset) {
		found[code] = pos
	}
	for _, want := range []string{"new_writer_literal", "new_typed_literal", "new_inline_classifier_literal", "new_envelope_literal"} {
		if _, ok := found[want]; !ok {
			t.Errorf("guard did not extract %q — a new unclassified code would slip through", want)
		}
	}
	if len(found) != 4 {
		t.Errorf("expected exactly 4 literal codes (variable arg must be skipped), got %d: %v", len(found), found)
	}
}
