package verify

import (
	"encoding/json"
	"fmt"
	"go/ast"
	"go/parser"
	"go/token"
	"io/fs"
	"os"
	"path/filepath"
	"regexp"
	"strconv"
	"strings"
	"testing"
	"unicode"
)

// reservedMarkerRE matches FORWARD-COMPAT or RESERVED only at the start of
// a comment line (optionally after a list-marker prefix like "* " or "- ").
// This rejects leading prose negations such as "NOT RESERVED" or "DEFINITELY
// NOT-RESERVED" while still accepting natural forms like
// "FORWARD-COMPAT v0.3+:", "RESERVED (do not delete)", and "* RESERVED *".
// go/ast.CommentGroup.Text strips comment markers, so each line we match
// against begins with the comment's content.
var reservedMarkerRE = regexp.MustCompile(`(?m)^\s*(?:[*-]\s+)?(FORWARD-COMPAT|RESERVED)(\W|$)`)

// TestReasonEnumBijection enforces a bijection between
//   - reasonXxx string constants declared in this package's non-test source, and
//   - reason values declared in schemas/output.schema.json.
//
// Source of truth: the reasonXxx Go constants, extracted via AST walk of the
// verify package. The schema is checked against this set; SPEC §10.4.2 is
// the spec-side authority and is kept in lock-step with the schema by the
// schema's own commits.
//
// Closes the original #127 gap: a contributor who adds a reasonXxx constant
// but never references it in non-test code now fails the test, UNLESS the
// constant carries a "FORWARD-COMPAT" or "RESERVED" marker in its doc
// comment (e.g. reasonBundlePubkeyProviderMismatch is intentionally reserved
// for a future SPEC revision).
func TestReasonEnumBijection(t *testing.T) {
	fset := token.NewFileSet()
	pkgs, err := parser.ParseDir(fset, ".", func(fi fs.FileInfo) bool {
		return !strings.HasSuffix(fi.Name(), "_test.go")
	}, parser.ParseComments)
	if err != nil {
		t.Fatalf("parse verify package: %v", err)
	}
	pkg, ok := pkgs["verify"]
	if !ok {
		t.Fatalf("verify package not found in current directory")
	}
	schemaBytes, err := os.ReadFile(filepath.Join("..", "..", "schemas", "output.schema.json"))
	if err != nil {
		t.Fatalf("read output schema: %v", err)
	}
	if err := checkReasonEnumBijection(pkg, schemaBytes); err != nil {
		t.Fatalf("bijection check failed: %v", err)
	}
}

// checkReasonEnumBijection is the testable core. It walks pkg's AST for
// reasonXxx string constants, checks each non-reserved constant is referenced
// in non-test source, and enforces a 1:1 mapping with the schema's reason
// enum. Returns the first violation encountered, or nil on success.
func checkReasonEnumBijection(pkg *ast.Package, schemaBytes []byte) error {
	type reasonDecl struct {
		value    string
		reserved bool
		declPos  token.Pos
	}
	declared := map[string]*reasonDecl{}
	for _, file := range pkg.Files {
		for _, decl := range file.Decls {
			gen, ok := decl.(*ast.GenDecl)
			if !ok || gen.Tok != token.CONST {
				continue
			}
			for _, spec := range gen.Specs {
				vs, ok := spec.(*ast.ValueSpec)
				if !ok {
					continue
				}
				for i, name := range vs.Names {
					if !isReasonConstName(name.Name) {
						continue
					}
					if i >= len(vs.Values) {
						return fmt.Errorf("reason constant %s has no explicit value (iota/carry-forward not supported for reasonXxx constants)", name.Name)
					}
					lit, ok := vs.Values[i].(*ast.BasicLit)
					if !ok || lit.Kind != token.STRING {
						return fmt.Errorf("reason constant %s must be a string literal, got %T", name.Name, vs.Values[i])
					}
					val, err := strconv.Unquote(lit.Value)
					if err != nil {
						return fmt.Errorf("unquote %s value: %w", name.Name, err)
					}
					declared[name.Name] = &reasonDecl{
						value:    val,
						reserved: hasReservedMarker(vs.Doc),
						declPos:  name.Pos(),
					}
				}
			}
		}
	}
	if len(declared) == 0 {
		return fmt.Errorf("no reasonXxx constants found in verify package")
	}

	refCount := map[string]int{}
	for _, file := range pkg.Files {
		ast.Inspect(file, func(n ast.Node) bool {
			ident, ok := n.(*ast.Ident)
			if !ok {
				return true
			}
			decl, exists := declared[ident.Name]
			if !exists {
				return true
			}
			if ident.Pos() == decl.declPos {
				return true
			}
			refCount[ident.Name]++
			return true
		})
	}

	for name, decl := range declared {
		if refCount[name] == 0 && !decl.reserved {
			return fmt.Errorf("reason constant %s (=%q) declared but never referenced in non-test source; either reference it, mark its doc comment with FORWARD-COMPAT/RESERVED, or remove it", name, decl.value)
		}
	}

	expected := make(map[string]string, len(declared))
	for name, decl := range declared {
		if prior, dup := expected[decl.value]; dup {
			return fmt.Errorf("reason constants %s and %s both declare wire value %q; values must be unique", prior, name, decl.value)
		}
		expected[decl.value] = name
	}

	var schema struct {
		OneOf []struct {
			Properties map[string]struct {
				Const string   `json:"const"`
				Enum  []string `json:"enum"`
			} `json:"properties"`
		} `json:"oneOf"`
	}
	if err := json.Unmarshal(schemaBytes, &schema); err != nil {
		return fmt.Errorf("decode output schema: %w", err)
	}
	if len(schema.OneOf) != 3 {
		return fmt.Errorf("schema oneOf branch count = %d, want 3", len(schema.OneOf))
	}

	branchByReason := map[string][]int{}
	for branchIndex, branch := range schema.OneOf {
		prop, ok := branch.Properties["reason"]
		if !ok {
			return fmt.Errorf("schema branch %d missing reason property", branchIndex)
		}
		reasons := prop.Enum
		if prop.Const != "" {
			reasons = append(reasons, prop.Const)
		}
		if len(reasons) == 0 {
			return fmt.Errorf("schema branch %d has no reason const/enum", branchIndex)
		}
		for _, reason := range reasons {
			if _, ok := expected[reason]; !ok {
				return fmt.Errorf("schema reason %q has no matching reasonXxx Go constant", reason)
			}
			branchByReason[reason] = append(branchByReason[reason], branchIndex)
		}
	}

	for value, constName := range expected {
		branches := branchByReason[value]
		if len(branches) != 1 {
			return fmt.Errorf("Go constant %s (=%q) appears in schema branches %v, want exactly one branch", constName, value, branches)
		}
	}
	return nil
}

func isReasonConstName(name string) bool {
	const prefix = "reason"
	if !strings.HasPrefix(name, prefix) || len(name) == len(prefix) {
		return false
	}
	return unicode.IsUpper(rune(name[len(prefix)]))
}

func hasReservedMarker(doc *ast.CommentGroup) bool {
	if doc == nil {
		return false
	}
	return reservedMarkerRE.MatchString(doc.Text())
}

// TestReasonEnumBijection_DetectsDrift exercises checkReasonEnumBijection
// against synthetic fixtures to verify each drift scenario it must catch.
func TestReasonEnumBijection_DetectsDrift(t *testing.T) {
	// schemaABC builds a three-branch schema with one reason value per branch.
	schemaABC := func(a, b, c string) []byte {
		return []byte(fmt.Sprintf(`{
  "oneOf": [
    {"properties": {"result": {"const": "valid"}, "reason": {"const": "%s"}}},
    {"properties": {"result": {"const": "invalid"}, "reason": {"enum": ["%s"]}}},
    {"properties": {"result": {"const": "inconclusive"}, "reason": {"enum": ["%s"]}}}
  ]
}`, a, b, c))
	}

	cases := []struct {
		name        string
		source      string
		schema      []byte
		wantErrFrag string
	}{
		{
			// Four Go constants, schema covers only three; one Go constant is missing
			// from any schema branch. Tests the "Go const has no schema branch" check.
			name: "go constant missing from schema",
			source: `package verify
const (
	reasonA = "av"
	reasonB = "bv"
	reasonC = "cv"
	reasonD = "dv"
)
var _ = []string{reasonA, reasonB, reasonC, reasonD}
`,
			schema:      schemaABC("av", "bv", "cv"),
			wantErrFrag: `Go constant reasonD`,
		},
		{
			// Schema references a reason value with no matching Go constant.
			name: "schema reason missing from Go constants",
			source: `package verify
const (
	reasonA = "av"
	reasonB = "bv"
	reasonC = "cv"
)
var _ = []string{reasonA, reasonB, reasonC}
`,
			schema:      schemaABC("av", "bv", "ghost_value"),
			wantErrFrag: `schema reason "ghost_value" has no matching`,
		},
		{
			// Go constant declared but never referenced in non-test source AND not marked reserved.
			name: "unused non-reserved constant fails",
			source: `package verify
const (
	reasonA      = "av"
	reasonB      = "bv"
	reasonC      = "cv"
	reasonUnused = "dangling"
)
var _ = []string{reasonA, reasonB, reasonC}
`,
			schema: func() []byte {
				return []byte(`{
  "oneOf": [
    {"properties": {"result": {"const": "valid"}, "reason": {"const": "av"}}},
    {"properties": {"result": {"const": "invalid"}, "reason": {"enum": ["bv", "dangling"]}}},
    {"properties": {"result": {"const": "inconclusive"}, "reason": {"enum": ["cv"]}}}
  ]
}`)
			}(),
			wantErrFrag: `reasonUnused`,
		},
		{
			// Same shape as previous case, but constant carries the FORWARD-COMPAT marker → must pass.
			name: "unused reserved constant passes (no error)",
			source: `package verify
const (
	reasonA = "av"
	reasonB = "bv"
	reasonC = "cv"
	// FORWARD-COMPAT: reserved for a future spec revision.
	reasonReserved = "dangling"
)
var _ = []string{reasonA, reasonB, reasonC}
`,
			schema: func() []byte {
				return []byte(`{
  "oneOf": [
    {"properties": {"result": {"const": "valid"}, "reason": {"const": "av"}}},
    {"properties": {"result": {"const": "invalid"}, "reason": {"enum": ["bv", "dangling"]}}},
    {"properties": {"result": {"const": "inconclusive"}, "reason": {"enum": ["cv"]}}}
  ]
}`)
			}(),
			wantErrFrag: "",
		},
		{
			// Two Go constants declare the same wire value → silent-collapse violation.
			name: "two go constants with the same wire value",
			source: `package verify
const (
	reasonA      = "av"
	reasonB      = "bv"
	reasonC      = "cv"
	reasonAlias  = "av"
)
var _ = []string{reasonA, reasonB, reasonC, reasonAlias}
`,
			schema:      schemaABC("av", "bv", "cv"),
			wantErrFrag: `both declare wire value`,
		},
		{
			// reasonXxx constant declared without an explicit string-literal value.
			name: "reason constant without explicit value",
			source: `package verify
const (
	reasonA = "av"
	reasonB = "bv"
	reasonC = "cv"
	reasonNoLit
)
var _ = []string{reasonA, reasonB, reasonC, reasonNoLit}
`,
			schema:      schemaABC("av", "bv", "cv"),
			wantErrFrag: `reasonNoLit has no explicit value`,
		},
		{
			// reasonXxx constant whose value is a non-string literal.
			name: "reason constant with non-string-literal value",
			source: `package verify
const (
	reasonA       = "av"
	reasonB       = "bv"
	reasonC       = "cv"
	reasonNonStr  = 42
)
var _ = []string{reasonA, reasonB, reasonC, reasonNonStr}
`,
			schema:      schemaABC("av", "bv", "cv"),
			wantErrFrag: `must be a string literal`,
		},
		{
			// Reserved-marker check requires the marker at line start —
			// "NOT RESERVED" / "DEFINITELY NOT-RESERVED" / "NOT FORWARD-COMPATIBLE"
			// must not silence the unused-constant check.
			name: "negated reserved-marker prose still flags unused constant",
			source: `package verify
const (
	reasonA = "av"
	reasonB = "bv"
	reasonC = "cv"
	// This constant is DEFINITELY NOT-RESERVED and not FORWARD-COMPATIBLE.
	// NOT RESERVED in any spec revision.
	reasonNegated = "dangling"
)
var _ = []string{reasonA, reasonB, reasonC}
`,
			schema: func() []byte {
				return []byte(`{
  "oneOf": [
    {"properties": {"result": {"const": "valid"}, "reason": {"const": "av"}}},
    {"properties": {"result": {"const": "invalid"}, "reason": {"enum": ["bv", "dangling"]}}},
    {"properties": {"result": {"const": "inconclusive"}, "reason": {"enum": ["cv"]}}}
  ]
}`)
			}(),
			wantErrFrag: `reasonNegated`,
		},
		{
			// Same constant value appears in two schema branches → bijection violation.
			name: "go constant appears in multiple schema branches",
			source: `package verify
const (
	reasonA = "av"
	reasonB = "bv"
	reasonC = "cv"
)
var _ = []string{reasonA, reasonB, reasonC}
`,
			schema: func() []byte {
				return []byte(`{
  "oneOf": [
    {"properties": {"result": {"const": "valid"}, "reason": {"const": "av"}}},
    {"properties": {"result": {"const": "invalid"}, "reason": {"enum": ["bv", "av"]}}},
    {"properties": {"result": {"const": "inconclusive"}, "reason": {"enum": ["cv"]}}}
  ]
}`)
			}(),
			wantErrFrag: `want exactly one branch`,
		},
	}

	for _, tc := range cases {
		tc := tc
		t.Run(tc.name, func(t *testing.T) {
			fset := token.NewFileSet()
			file, err := parser.ParseFile(fset, "fake.go", tc.source, parser.ParseComments)
			if err != nil {
				t.Fatalf("parse synthetic source: %v", err)
			}
			pkg := &ast.Package{Name: "verify", Files: map[string]*ast.File{"fake.go": file}}
			err = checkReasonEnumBijection(pkg, tc.schema)
			if tc.wantErrFrag == "" {
				if err != nil {
					t.Fatalf("expected nil error, got %v", err)
				}
				return
			}
			if err == nil {
				t.Fatalf("expected error containing %q, got nil", tc.wantErrFrag)
			}
			if !strings.Contains(err.Error(), tc.wantErrFrag) {
				t.Fatalf("expected error containing %q, got %q", tc.wantErrFrag, err.Error())
			}
		})
	}
}

// TestReservedMarkerRE pins the marker-recognition contract: which doc-comment
// forms count as a "reserved" annotation and which do not. Future contributors
// adjusting reservedMarkerRE must keep these cases passing.
func TestReservedMarkerRE(t *testing.T) {
	mustReserve := []string{
		// The live verify.go form.
		"FORWARD-COMPAT v0.3+: reserved enum value.\nNext line.",
		"RESERVED (do not delete)",
		"* RESERVED *",
		"- RESERVED for SPEC-016",
		"FORWARD-COMPAT: pending v0.4",
		"context line\nRESERVED for future revision",
	}
	mustNotReserve := []string{
		"NOT RESERVED",
		"DEFINITELY NOT-RESERVED and not FORWARD-COMPATIBLE.",
		"NOT FORWARD-COMPAT yet",
		"may someday be RESERVED",       // marker not at line start
		"intentionally UNRESERVED",      // not the marker token
		"this RESERVED-LIKE thing",      // marker not at line start
		"",
	}
	for _, in := range mustReserve {
		if !reservedMarkerRE.MatchString(in) {
			t.Errorf("expected reserved match for %q", in)
		}
	}
	for _, in := range mustNotReserve {
		if reservedMarkerRE.MatchString(in) {
			t.Errorf("expected NO reserved match for %q", in)
		}
	}
}

func TestIsReasonConstName(t *testing.T) {
	cases := []struct {
		name string
		want bool
	}{
		{"reasonValid", true},
		{"reasonModelHashMismatch", true},
		{"reason", false},        // bare prefix
		{"reasonable", false},    // not exported camelCase under prefix
		{"warningFoo", false},    // wrong prefix
		{"resultValid", false},   // wrong prefix
		{"Reason", false},        // wrong case start
		{"", false},
	}
	for _, tc := range cases {
		if got := isReasonConstName(tc.name); got != tc.want {
			t.Errorf("isReasonConstName(%q) = %v, want %v", tc.name, got, tc.want)
		}
	}
}
