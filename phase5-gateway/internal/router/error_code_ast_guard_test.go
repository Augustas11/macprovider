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
// a writer's codes.
//
// The set covers the buyer-facing error WRITERS and the retryability CLASSIFIER
// (gatewayRetryable). Inline error envelopes (e.g. writeStructuredOutputTimeoutSSE)
// are ALSO scanned directly by the composite-literal pass, so the emitted `"code"`
// field is checked even when it is decoupled from the classifier argument.
var gatewayErrorEmitters = map[string]bool{
	"writeError":                 true,
	"writeSSEError":              true,
	"writeSpec019PreflightError": true,
	"gatewayRetryable":           true,
}

// gatewayAllowAbsentEmitters lists registered emitters that may legitimately have
// no FuncDecl in the current source. The gateway has none today (every emitter is
// declared in this package); the map exists so assertEmittersResolve stays
// symmetric with the coordinator guard.
var gatewayAllowAbsentEmitters = map[string]bool{}

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
// in files, the flattened 0-based index of its parameter named "code".
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
				if len(field.Names) == 0 {
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
// accounted for.
func unresolvedEmitters(emitters, allowAbsent, declared map[string]bool, codeIdx map[string]int) []string {
	var problems []string
	for name := range emitters {
		_, resolved := codeIdx[name]
		switch {
		case resolved:
		case declared[name]:
			problems = append(problems, "emitter "+name+" is declared but no `code` parameter was found — was the parameter renamed? the guard would silently skip its codes")
		case allowAbsent[name]:
		default:
			problems = append(problems, "emitter "+name+" resolved no code index and is not a declared function or an allowed forward reference — check the registry name for a typo")
		}
	}
	return problems
}

// inspectFilesForLiteralCodes walks every call in files to a name in codeIdx and
// records the STRING-LITERAL argument at that name's code index.
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
// composite literal carrying BOTH a string-literal `"code"` field AND a
// `"retryable"` key (the buyer-facing classified-envelope shape, e.g.
// writeStructuredOutputTimeoutSSE). It checks the EMITTED `"code"` value
// directly, so a code decoupled from any classifier call is still caught. The
// `"retryable"` sibling requirement excludes operator/explorer maps that carry a
// literal `"code"` but no retryable field.
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

// stringAssignLiterals returns every string-literal value assigned to the named
// variable (`=` or `:=`) across files. Used to pin a finite variable-routed value
// set (e.g. concurrencyErrCode) directly from source, so a new assignment is
// covered automatically rather than needing a hand-maintained mirror slice.
func stringAssignLiterals(files []*ast.File, varName string) []string {
	var out []string
	for _, file := range files {
		ast.Inspect(file, func(n ast.Node) bool {
			as, ok := n.(*ast.AssignStmt)
			if !ok {
				return true
			}
			for i, lhs := range as.Lhs {
				id, ok := lhs.(*ast.Ident)
				if !ok || id.Name != varName || i >= len(as.Rhs) {
					continue
				}
				if lit, ok := as.Rhs[i].(*ast.BasicLit); ok && lit.Kind == token.STRING {
					if s, err := strconv.Unquote(lit.Value); err == nil {
						out = append(out, s)
					}
				}
			}
			return true
		})
	}
	return out
}

// TestGatewayEmittedLiteralCodesAreClassified is the AST/registration-based
// completeness guard (runbook item 21). It parses this package's source, derives
// each error-writer / classifier's `code` argument index from its real signature,
// extracts every STRING-LITERAL code argument (at emitter call sites AND in inline
// `code`+`retryable` envelopes), and asserts each is triaged into EXACTLY one of
// gatewayRetryableByCode / gatewayPermanentCodes — so a new emitted literal code
// fails CI merely by existing. It also cross-checks gatewayEmittedErrorCodes for
// staleness and asserts every registered emitter still resolves.
//
// Residual (documented, SPEC-006 §5.2 "Known carried items" (5)): the 429
// concurrency code reaches writeError through the `concurrencyErrCode` variable
// and is not a literal at the call site; its finite value set is pinned directly
// from the assignments by TestGatewayConcurrencyCodesClassifiedAndInventoried.
func TestGatewayEmittedLiteralCodesAreClassified(t *testing.T) {
	fset, files := parsePackageFiles(t)
	codeIdx := deriveCodeArgIndices(files, gatewayErrorEmitters)
	for _, p := range unresolvedEmitters(gatewayErrorEmitters, gatewayAllowAbsentEmitters, funcDeclNames(files), codeIdx) {
		t.Error(p)
	}
	if len(codeIdx) == 0 {
		t.Fatal("derived no emitter code-arg indices — gatewayErrorEmitters names are wrong")
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

// TestGatewayConcurrencyCodesClassifiedAndInventoried pins the finite value set of
// the concurrencyErrCode variable (read DIRECTLY from its assignments, so a new
// assignment is covered automatically), which reaches writeError as a variable
// and so is invisible to the literal AST guard.
func TestGatewayConcurrencyCodesClassifiedAndInventoried(t *testing.T) {
	_, files := parsePackageFiles(t)
	codes := stringAssignLiterals(files, "concurrencyErrCode")
	if len(codes) == 0 {
		t.Fatal("extracted no concurrencyErrCode assignments — variable renamed?")
	}
	inventory := make(map[string]bool, len(gatewayEmittedErrorCodes))
	for _, c := range gatewayEmittedErrorCodes {
		inventory[c] = true
	}
	for _, code := range codes {
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

// TestGatewayErrorCodeGuardDerivesAndExtracts is the mechanism test: it runs
// derivation + extraction over a synthetic snippet that DEFINES the emitter
// signatures (so indices are derived, e.g. writeSpec019PreflightError=2 which the
// R1 bug had at 1) and exercises writer / preflight / inline-classifier /
// inline-envelope / variable-arg cases.
func TestGatewayErrorCodeGuardDerivesAndExtracts(t *testing.T) {
	const src = `package router
func writeError(w, status, typ, code, message string) {}
func writeSpec019PreflightError(w, status, code, message, param string) {}
func gatewayRetryable(code string) bool { return false }
func caller(w, x string) {
	writeError(w, x, "api_error", "new_writer_literal", "boom")
	writeSpec019PreflightError(w, x, "new_preflight_literal", "boom", "p")
	gatewayRetryable("new_inline_classifier_literal")
	_ = map[string]any{"code": "new_envelope_literal", "retryable": false}
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
	for code, pos := range inspectFilesForEnvelopeCodeLiterals(files, fset) {
		found[code] = pos
	}
	for _, want := range []string{"new_writer_literal", "new_preflight_literal", "new_inline_classifier_literal", "new_envelope_literal"} {
		if _, ok := found[want]; !ok {
			t.Errorf("guard did not extract %q — a new unclassified code would slip through", want)
		}
	}
	if len(found) != 4 {
		t.Errorf("expected exactly 4 literal codes (variable arg must be skipped), got %d: %v", len(found), found)
	}
}
