package payout_test

// TestSyntheticAlertsCatalog is the load-bearing guard for SPEC-016 §9 cutover
// prerequisite item 6: before `payout.enabled: true`, the operator must verify
// ONE synthetic alert per ENUMERATED PAGE/WARN event name. The enumeration
// lives in dist/synthetic-alerts/catalog.tsv, the single source of truth shared
// with dist/synthetic-alerts/emit.sh.
//
// DESIGN: sound static enumeration of "which zerolog emissions are PAGE/WARN
// alerts" from arbitrary Go is undecidable — an AST scanner can always be fooled
// by another way of routing the event name or severity. So this test does NOT
// try to understand emission. It is a STYLE-AGNOSTIC literal-presence check:
//
//   Every identifier-shaped string literal matching ^(payout_|provider_payout_)
//   [a-z0-9_]+$ in the scanned source MUST be classified as exactly one of:
//     (a) a catalogued alert event      -> dist/synthetic-alerts/catalog.tsv, or
//     (b) a reviewed non-alert string   -> dist/synthetic-alerts/non-alert-allowlist.txt
//
// It does not matter HOW an event is emitted; a new alert event necessarily
// introduces a new event-name literal (or const literal) somewhere, and this
// test fails closed on any unclassified one. Alert event names must be literals
// or consts — dynamically constructed alert names (fmt.Sprintf("payout_%s"),
// "payout_" + x) are forbidden and also fail, keeping the check sound.

import (
	"go/ast"
	"go/parser"
	"go/token"
	"io/fs"
	"os"
	"path/filepath"
	"sort"
	"strconv"
	"strings"
	"testing"
)

// ---------------------------------------------------------------------------
// Catalog + allowlist
// ---------------------------------------------------------------------------

type catalogEntry struct {
	severity    string // PAGE | WARN | INFO (floor severity for page_capable)
	status      string // code | info | spec-only-not-emitted
	pageCapable bool
}

func findRepoRoot(t *testing.T) string {
	t.Helper()
	dir, err := os.Getwd()
	if err != nil {
		t.Fatalf("Getwd: %v", err)
	}
	for {
		if _, err := os.Stat(filepath.Join(dir, "dist", "synthetic-alerts", "catalog.tsv")); err == nil {
			return dir
		}
		parent := filepath.Dir(dir)
		if parent == dir {
			t.Fatalf("could not locate dist/synthetic-alerts/catalog.tsv walking up from working dir")
		}
		dir = parent
	}
}

func loadCatalog(t *testing.T, root string) map[string]catalogEntry {
	t.Helper()
	path := filepath.Join(root, "dist", "synthetic-alerts", "catalog.tsv")
	data, err := os.ReadFile(path)
	if err != nil {
		t.Fatalf("open catalog: %v", err)
	}
	out := make(map[string]catalogEntry)
	for i, line := range strings.Split(string(data), "\n") {
		ln := i + 1
		trimmed := strings.TrimSpace(line)
		if trimmed == "" || strings.HasPrefix(trimmed, "#") {
			continue
		}
		parts := strings.Split(line, "\t")
		if len(parts) != 4 {
			t.Fatalf("catalog.tsv:%d: expected 4 TAB-separated fields, got %d: %q", ln, len(parts), line)
		}
		name, sev, status, page := parts[0], parts[1], parts[2], parts[3]
		switch sev {
		case "PAGE", "WARN", "INFO":
		default:
			t.Fatalf("catalog.tsv:%d: bad severity %q", ln, sev)
		}
		switch status {
		case "code", "info", "spec-only-not-emitted":
		default:
			// `code-untagged` is intentionally NOT accepted: it was a latent
			// bypass of the severity-presence check. An emitted PAGE/WARN alert
			// must carry a severity field regardless of status.
			t.Fatalf("catalog.tsv:%d: bad status %q", ln, status)
		}
		var pageCapable bool
		switch page {
		case "-":
		case "page_capable":
			pageCapable = true
		default:
			t.Fatalf("catalog.tsv:%d: bad page_capable %q", ln, page)
		}
		if _, dup := out[name]; dup {
			t.Fatalf("catalog.tsv:%d: duplicate event %q", ln, name)
		}
		out[name] = catalogEntry{severity: sev, status: status, pageCapable: pageCapable}
	}
	return out
}

func loadAllowlist(t *testing.T, root string) map[string]string {
	t.Helper()
	path := filepath.Join(root, "dist", "synthetic-alerts", "non-alert-allowlist.txt")
	data, err := os.ReadFile(path)
	if err != nil {
		t.Fatalf("open allowlist: %v", err)
	}
	out := make(map[string]string)
	for i, line := range strings.Split(string(data), "\n") {
		trimmed := strings.TrimSpace(line)
		if trimmed == "" || strings.HasPrefix(trimmed, "#") {
			continue
		}
		fields := strings.Fields(trimmed)
		if len(fields) != 2 {
			t.Fatalf("non-alert-allowlist.txt:%d: expected `<literal> <reason>`, got %q", i+1, line)
		}
		out[fields[0]] = fields[1]
	}
	return out
}

// ---------------------------------------------------------------------------
// Scanner: collect payout_/provider_payout_ string literals + dynamic-name uses
// ---------------------------------------------------------------------------

type scanResult struct {
	literals map[string]string // identifier literal -> "file:line" of first sighting
	dynamic  []string          // dynamic alert-name constructions (fail-closed)
}

const (
	prefixA = "payout_"
	prefixB = "provider_payout_"
)

func hasPayoutPrefix(v string) bool {
	return strings.HasPrefix(v, prefixA) || strings.HasPrefix(v, prefixB)
}

func isIdentChars(v string) bool {
	for _, r := range v {
		if !(r >= 'a' && r <= 'z' || r >= '0' && r <= '9' || r == '_') {
			return false
		}
	}
	return true
}

// isEventIdentifier reports whether v is shaped exactly like a COMPLETE event
// name: a payout_/provider_payout_ prefix followed only by [a-z0-9_] and NOT
// ending in '_'. A real event name never ends in '_'; a trailing underscore is
// the tell-tale of a concatenation prefix fragment (see isNameFragment).
func isEventIdentifier(v string) bool {
	return hasPayoutPrefix(v) && isIdentChars(v) && !strings.HasSuffix(v, "_")
}

// isNameFragment reports whether v is a payout_-prefixed identifier fragment
// ending in '_' (e.g. "payout_", "payout_flag_") — the shape used to build an
// event name by concatenation across statements/variables (indirect dynamic
// construction). Alert names must be whole literals, so these fail.
func isNameFragment(v string) bool {
	return hasPayoutPrefix(v) && isIdentChars(v) && strings.HasSuffix(v, "_")
}

// isDynamicNameTemplate reports whether v looks like a format template that
// builds a payout_-prefixed event name (e.g. "payout_%s") — a payout_ prefix
// followed only by [a-z0-9_%] and containing at least one '%'. Prose messages
// that merely start with an event name (they contain spaces/`=`/`:`) are NOT
// templates and are ignored.
func isDynamicNameTemplate(v string) bool {
	if !hasPayoutPrefix(v) || !strings.Contains(v, "%") {
		return false
	}
	for _, r := range v {
		if !(r >= 'a' && r <= 'z' || r >= '0' && r <= '9' || r == '_' || r == '%') {
			return false
		}
	}
	return true
}

func scanFiles(fset *token.FileSet, files []*ast.File) scanResult {
	res := scanResult{literals: map[string]string{}}
	for _, f := range files {
		ast.Inspect(f, func(n ast.Node) bool {
			switch x := n.(type) {
			case *ast.BasicLit:
				if x.Kind != token.STRING {
					return true
				}
				v, err := strconv.Unquote(x.Value)
				if err != nil {
					return true
				}
				switch {
				case isEventIdentifier(v):
					if _, seen := res.literals[v]; !seen {
						res.literals[v] = fset.Position(x.Pos()).String()
					}
				case isNameFragment(v):
					res.dynamic = append(res.dynamic,
						fset.Position(x.Pos()).String()+": payout_-prefixed name fragment "+strconv.Quote(v)+
							" — looks like it builds an alert name by concatenation; alert event names MUST be whole string literals/consts")
				case isDynamicNameTemplate(v):
					res.dynamic = append(res.dynamic,
						fset.Position(x.Pos()).String()+": dynamic alert-name template "+strconv.Quote(v)+
							" — alert event names MUST be plain string literals/consts, not fmt-constructed")
				}
			case *ast.BinaryExpr:
				if x.Op != token.ADD {
					return true
				}
				// Flag `"payout_..." + <non-literal>` (dynamic concat of an
				// event name). Constant "a"+"b" concatenation is fine.
				for _, pair := range [][2]ast.Expr{{x.X, x.Y}, {x.Y, x.X}} {
					lit, ok := stringLitValue(pair[0])
					if !ok || !isEventIdentifier(lit) {
						continue
					}
					if _, otherIsLit := stringLitValue(pair[1]); otherIsLit {
						continue // constant concatenation
					}
					res.dynamic = append(res.dynamic,
						fset.Position(x.Pos()).String()+": dynamic alert-name concatenation of "+strconv.Quote(lit)+
							" — alert event names MUST be plain string literals/consts")
				}
			}
			return true
		})
	}
	return res
}

func stringLitValue(e ast.Expr) (string, bool) {
	bl, ok := e.(*ast.BasicLit)
	if !ok || bl.Kind != token.STRING {
		return "", false
	}
	v, err := strconv.Unquote(bl.Value)
	if err != nil {
		return "", false
	}
	return v, true
}

// ---------------------------------------------------------------------------
// Sound severity-PRESENCE audit over the FINITE set of catalogued alert events
// ---------------------------------------------------------------------------
//
// For every catalogued `code` alert event, this asserts that EACH production
// emission carries a `severity` field matching the catalog. Enumerating "which
// arbitrary emission is an alert" is undecidable, but the catalogued names are a
// finite list, so we resolve, for each emitting zerolog chain, the concrete
// event name(s) it produces — via string literals, consts, struct-field
// literals, string-returning helpers, and arguments threaded through emit-helper
// parameters (e.g. serveFlip -> emitFlipEvent) — and pair each with that chain's
// severity. Then, per catalogued event:
//   - if NO emitter is found -> FAIL closed (can't confirm severity), and
//   - if ANY emitting chain lacks/ mismatches the severity -> FAIL with file:line.
// This is fail-closed: an unresolved emission never silently passes a catalogued
// event; it makes the event look un-emitted and fails.

type chainSev struct {
	present bool // a `severity` field is set in the chain
	lits    map[string]bool
	dynPage bool // severity is a runtime value that can be "PAGE"
}

type emitter struct {
	sev chainSev
	pos string
}

type sinkKey struct {
	fn    *ast.FuncDecl
	param string
}

// resolveEmitters returns, for every event name emitted anywhere in the scanned
// source, the list of emitting chains (with each chain's severity + position).
// It also returns "unresolved" findings: payout-package emission chains whose
// event NAME cannot be reduced to concrete values AND which carry NO severity
// field — a chain that could be an untagged alert the harness can't verify.
// These fail the audit CLOSED (never silently skipped).
func resolveEmitters(fset *token.FileSet, files []*ast.File) (map[string][]emitter, []string) {
	funcByName := map[string][]*ast.FuncDecl{}
	stringConsts := map[string]string{}
	var calls []callRec
	for _, f := range files {
		for _, d := range f.Decls {
			switch decl := d.(type) {
			case *ast.FuncDecl:
				funcByName[decl.Name.Name] = append(funcByName[decl.Name.Name], decl)
			case *ast.GenDecl:
				if decl.Tok == token.CONST {
					for _, spec := range decl.Specs {
						if vs, ok := spec.(*ast.ValueSpec); ok {
							for i, nm := range vs.Names {
								if i < len(vs.Values) {
									if v, ok := stringLitValue(vs.Values[i]); ok {
										stringConsts[nm.Name] = v
									}
								}
							}
						}
					}
				}
			}
		}
	}

	// Collect every call site with its enclosing named func.
	for _, f := range files {
		for _, d := range f.Decls {
			fd, ok := d.(*ast.FuncDecl)
			if !ok || fd.Body == nil {
				continue
			}
			ast.Inspect(fd.Body, func(n ast.Node) bool {
				if ce, ok := n.(*ast.CallExpr); ok {
					if name := calleeName(ce); name != "" {
						calls = append(calls, callRec{name: name, args: ce.Args, enc: fd})
					}
				}
				return true
			})
		}
	}

	funcReturnStrings := func(name string) (lits []string, allLiteral bool) {
		recs := funcByName[name]
		if len(recs) == 0 {
			return nil, false
		}
		allLiteral, saw := true, false
		for _, rec := range recs {
			if rec.Body == nil {
				continue
			}
			ast.Inspect(rec.Body, func(n ast.Node) bool {
				if _, ok := n.(*ast.FuncLit); ok {
					return false
				}
				if ret, ok := n.(*ast.ReturnStmt); ok {
					for _, r := range ret.Results {
						saw = true
						if v, ok := stringLitValue(r); ok {
							lits = append(lits, v)
						} else {
							allLiteral = false
						}
					}
				}
				return true
			})
		}
		if !saw {
			return nil, false
		}
		return lits, allLiteral
	}

	// resolveExpr reduces an event-name expression to concrete names, a sink to
	// thread, or unresolved.
	var resolveExpr func(e ast.Expr, enc *ast.FuncDecl) ([]string, *sinkKey, bool)
	resolveExpr = func(e ast.Expr, enc *ast.FuncDecl) ([]string, *sinkKey, bool) {
		switch x := e.(type) {
		case *ast.BasicLit:
			if v, ok := stringLitValue(x); ok {
				return []string{v}, nil, true
			}
		case *ast.Ident:
			if v, ok := stringConsts[x.Name]; ok {
				return []string{v}, nil, true
			}
			if rhs := localVarRHS(enc, x.Name); len(rhs) > 0 {
				var names []string
				for _, r := range rhs {
					if v, ok := stringLitValue(r); ok {
						names = append(names, v)
						continue
					}
					if ce, ok := r.(*ast.CallExpr); ok {
						if lits, all := funcReturnStrings(calleeName(ce)); all && len(lits) > 0 {
							names = append(names, lits...)
							continue
						}
					}
					return nil, nil, false
				}
				return names, nil, true
			}
			if enc != nil && paramIndex(enc, x.Name) >= 0 {
				return nil, &sinkKey{fn: enc, param: x.Name}, true
			}
		case *ast.CallExpr:
			if lits, all := funcReturnStrings(calleeName(x)); all && len(lits) > 0 {
				return lits, nil, true
			}
		case *ast.SelectorExpr:
			if base, ok := x.X.(*ast.Ident); ok {
				if v, ok := compositeFieldLit(enc, base.Name, x.Sel.Name); ok {
					return []string{v}, nil, true
				}
			}
		}
		return nil, nil, false
	}

	out := map[string][]emitter{}
	var unresolved []string
	add := func(name string, sev chainSev, pos string) {
		out[name] = append(out[name], emitter{sev: sev, pos: pos})
	}
	// flagUnresolved records an inconclusive emission that lacks severity. Scoped
	// to package "payout" (where every event is a payout alert-or-info) so it
	// cannot false-fail on unrelated `package main` coordinator logging.
	flagUnresolved := func(pkg string, sev chainSev, pos string) {
		if pkg == "payout" && !sev.present {
			unresolved = append(unresolved,
				pos+": emission sets an `event` field whose name the harness cannot resolve, and the chain has NO severity — "+
					"cannot verify it is not an untagged alert; use a literal/const event name, or add a literal Str(\"severity\",...) the check can see")
		}
	}

	// Walk chains; resolve their event expr(s) and attach the chain's severity.
	visitChains(files, func(pkg string, enc *ast.FuncDecl, eventExprs []ast.Expr, sev chainSev, pos string) {
		for _, e := range eventExprs {
			names, sink, ok := resolveExpr(e, enc)
			if !ok {
				flagUnresolved(pkg, sev, pos) // inconclusive + no severity => fail closed
				continue
			}
			if sink == nil {
				for _, n := range names {
					add(n, sev, pos)
				}
				continue
			}
			// Thread the sink parameter to its call-site values (to a fixpoint),
			// attaching THIS chain's severity to whatever names resolve.
			visited := map[sinkKey]bool{}
			queue := []sinkKey{*sink}
			for len(queue) > 0 {
				sk := queue[0]
				queue = queue[1:]
				if visited[sk] {
					continue
				}
				visited[sk] = true
				idx := paramIndex(sk.fn, sk.param)
				arity := len(flatParams(sk.fn))
				for _, c := range calls {
					if c.name != sk.fn.Name.Name || len(c.args) != arity || idx < 0 || idx >= len(c.args) {
						continue
					}
					n2, sink2, ok2 := resolveExpr(c.args[idx], c.enc)
					if !ok2 {
						// A call site feeds this emit-helper an event name the
						// harness can't resolve. If the helper chain lacks
						// severity, the emission could be an untagged alert.
						flagUnresolved(pkg, sev, pos)
						continue
					}
					if sink2 != nil {
						queue = append(queue, *sink2)
						continue
					}
					for _, n := range n2 {
						add(n, sev, pos)
					}
				}
			}
		}
	})
	return out, unresolved
}

type callRec struct {
	name string
	args []ast.Expr
	enc  *ast.FuncDecl
}

func calleeName(call *ast.CallExpr) string {
	switch fn := call.Fun.(type) {
	case *ast.Ident:
		return fn.Name
	case *ast.SelectorExpr:
		return fn.Sel.Name
	}
	return ""
}

func flatParams(fd *ast.FuncDecl) []string {
	var out []string
	if fd == nil || fd.Type == nil || fd.Type.Params == nil {
		return out
	}
	for _, field := range fd.Type.Params.List {
		if len(field.Names) == 0 {
			out = append(out, "")
			continue
		}
		for _, nm := range field.Names {
			out = append(out, nm.Name)
		}
	}
	return out
}

func paramIndex(fd *ast.FuncDecl, name string) int {
	for i, p := range flatParams(fd) {
		if p == name {
			return i
		}
	}
	return -1
}

func localVarRHS(fd *ast.FuncDecl, name string) []ast.Expr {
	var out []ast.Expr
	if fd == nil || fd.Body == nil {
		return out
	}
	ast.Inspect(fd.Body, func(n ast.Node) bool {
		as, ok := n.(*ast.AssignStmt)
		if !ok || len(as.Lhs) != len(as.Rhs) {
			return true
		}
		for i, lhs := range as.Lhs {
			if id, ok := lhs.(*ast.Ident); ok && id.Name == name {
				out = append(out, as.Rhs[i])
			}
		}
		return true
	})
	return out
}

func compositeFieldLit(fd *ast.FuncDecl, varName, fieldName string) (string, bool) {
	if fd == nil || fd.Body == nil {
		return "", false
	}
	var found string
	var ok bool
	ast.Inspect(fd.Body, func(n ast.Node) bool {
		as, isAssign := n.(*ast.AssignStmt)
		if !isAssign {
			return true
		}
		for i, lhs := range as.Lhs {
			id, isID := lhs.(*ast.Ident)
			if !isID || id.Name != varName || i >= len(as.Rhs) {
				continue
			}
			cl, isCL := as.Rhs[i].(*ast.CompositeLit)
			if !isCL {
				continue
			}
			for _, elt := range cl.Elts {
				kv, isKV := elt.(*ast.KeyValueExpr)
				if !isKV {
					continue
				}
				if key, isKey := kv.Key.(*ast.Ident); isKey && key.Name == fieldName {
					if v, isStr := stringLitValue(kv.Value); isStr {
						found, ok = v, true
					}
				}
			}
		}
		return true
	})
	return found, ok
}

// strFieldArg returns the value expression of a `.Str("<field>", X)` call.
func strFieldArg(call *ast.CallExpr, field string) (ast.Expr, bool) {
	sel, ok := call.Fun.(*ast.SelectorExpr)
	if !ok || sel.Sel.Name != "Str" || len(call.Args) != 2 {
		return nil, false
	}
	if key, ok := stringLitValue(call.Args[0]); !ok || key != field {
		return nil, false
	}
	return call.Args[1], true
}

func localStringAssignments(fd *ast.FuncDecl, name string) []string {
	var out []string
	if fd == nil || fd.Body == nil {
		return out
	}
	ast.Inspect(fd.Body, func(n ast.Node) bool {
		as, ok := n.(*ast.AssignStmt)
		if !ok {
			return true
		}
		for i, lhs := range as.Lhs {
			id, ok := lhs.(*ast.Ident)
			if !ok || id.Name != name || i >= len(as.Rhs) {
				continue
			}
			if v, ok := stringLitValue(as.Rhs[i]); ok {
				out = append(out, v)
			}
		}
		return true
	})
	return out
}

// visitChains calls fn once per zerolog chain (ExprStmt) that sets an `event`
// field, passing the enclosing named func, the event value expression(s), the
// chain's severity, and the source position of the first event field.
func visitChains(files []*ast.File, fn func(pkg string, enc *ast.FuncDecl, eventExprs []ast.Expr, sev chainSev, pos string)) {
	// position printing needs a FileSet; recover it from the file set the
	// parser used by carrying positions through the shared set below.
	for _, f := range files {
		pkg := ""
		if f.Name != nil {
			pkg = f.Name.Name
		}
		for _, d := range f.Decls {
			fd, ok := d.(*ast.FuncDecl)
			if !ok || fd.Body == nil {
				continue
			}
			ast.Inspect(fd.Body, func(n ast.Node) bool {
				stmt, ok := n.(*ast.ExprStmt)
				if !ok {
					return true
				}
				var events []ast.Expr
				var sevLits []string
				var sevIdents []string
				var firstEventPos token.Pos
				ast.Inspect(stmt, func(m ast.Node) bool {
					call, ok := m.(*ast.CallExpr)
					if !ok {
						return true
					}
					if e, ok := strFieldArg(call, "event"); ok {
						if len(events) == 0 {
							firstEventPos = e.Pos()
						}
						events = append(events, e)
					}
					if sv, ok := strFieldArg(call, "severity"); ok {
						if v, ok := stringLitValue(sv); ok {
							sevLits = append(sevLits, v)
						} else if id, ok := sv.(*ast.Ident); ok {
							sevIdents = append(sevIdents, id.Name)
						} else {
							sevIdents = append(sevIdents, "") // dynamic, non-ident
						}
					}
					return true
				})
				if len(events) == 0 {
					return true
				}
				sev := chainSev{lits: map[string]bool{}}
				if len(sevLits) > 0 || len(sevIdents) > 0 {
					sev.present = true
				}
				for _, s := range sevLits {
					sev.lits[s] = true
				}
				for _, id := range sevIdents {
					if id == "" {
						sev.dynPage = true
						continue
					}
					for _, v := range localStringAssignments(fd, id) {
						sev.lits[v] = true
						if v == "PAGE" {
							sev.dynPage = true
						}
					}
				}
				fn(pkg, fd, events, sev, chainPos(firstEventPos))
				return true
			})
		}
	}
}

// chainPos is set by auditCatalogSeverity via a package-level FileSet pointer so
// visitChains can print positions without threading the set everywhere.
var curFset *token.FileSet

func chainPos(p token.Pos) string {
	if curFset == nil || p == token.NoPos {
		return "<pos?>"
	}
	return curFset.Position(p).String()
}

// auditCatalogSeverity is the sound per-site check: every catalogued `code`
// event must be emitted, and every one of its emitting chains must carry a
// matching severity field.
func auditCatalogSeverity(fset *token.FileSet, files []*ast.File, catalog map[string]catalogEntry) []string {
	curFset = fset
	defer func() { curFset = nil }()
	emitters, unresolved := resolveEmitters(fset, files)

	// Fail closed on any payout emission the harness could not analyze.
	var errs []string
	errs = append(errs, unresolved...)
	for name, entry := range catalog {
		// The severity requirement is gated on the CATALOG SEVERITY, not the
		// status, so no status value (e.g. a resurrected `code-untagged`) can
		// exempt an emitted PAGE/WARN alert. INFO events are not alerts;
		// spec-only-not-emitted events are intentionally not emitted (the
		// literal-presence reverse guard asserts their absence).
		if entry.severity == "INFO" || entry.status == "spec-only-not-emitted" {
			continue
		}
		ems := emitters[name]
		if len(ems) == 0 {
			errs = append(errs, "catalogued alert "+name+" ("+entry.severity+") has no resolvable production emission — "+
				"the harness cannot confirm its severity; emit it via a literal/const/known helper carrying Str(\"severity\",...)")
			continue
		}
		for _, em := range ems {
			if !em.sev.present {
				errs = append(errs, em.pos+": catalogued alert "+name+" is emitted WITHOUT a severity field — "+
					"add Str(\"severity\",\""+entry.severity+"\") to this zerolog chain")
				continue
			}
			if entry.pageCapable {
				for s := range em.sev.lits {
					if s != "WARN" && s != "PAGE" {
						errs = append(errs, em.pos+": page_capable event "+name+" emits unexpected severity "+s)
					}
				}
				continue
			}
			if em.sev.dynPage && entry.severity != "PAGE" {
				errs = append(errs, em.pos+": event "+name+" can emit severity=PAGE dynamically but catalog says "+
					entry.severity+" without page_capable")
			}
			for s := range em.sev.lits {
				if s != entry.severity {
					errs = append(errs, em.pos+": severity mismatch for "+name+": code emits "+s+", catalog says "+entry.severity)
				}
			}
		}
	}
	sort.Strings(errs)
	return errs
}

// ---------------------------------------------------------------------------
// Loading the scanned sources
// ---------------------------------------------------------------------------

func scannedGoFiles(t *testing.T, root string) []string {
	t.Helper()
	var out []string
	payoutRoot := filepath.Join(root, "phase4-coordinator", "internal", "payout")
	if err := filepath.WalkDir(payoutRoot, func(path string, d fs.DirEntry, err error) error {
		if err != nil {
			return err
		}
		if d.IsDir() || !strings.HasSuffix(path, ".go") || strings.HasSuffix(path, "_test.go") {
			return nil
		}
		out = append(out, path)
		return nil
	}); err != nil {
		t.Fatalf("walk payout: %v", err)
	}
	cmdGlob := filepath.Join(root, "phase4-coordinator", "cmd", "coordinator", "*.go")
	matches, err := filepath.Glob(cmdGlob)
	if err != nil {
		t.Fatalf("glob coordinator: %v", err)
	}
	for _, m := range matches {
		if !strings.HasSuffix(m, "_test.go") {
			out = append(out, m)
		}
	}
	if len(out) < 10 {
		t.Fatalf("scannedGoFiles found too few files (%d) — layout changed?", len(out))
	}
	sort.Strings(out)
	return out
}

func parseFiles(t *testing.T, paths []string) (*token.FileSet, []*ast.File) {
	t.Helper()
	fset := token.NewFileSet()
	var files []*ast.File
	for _, p := range paths {
		f, err := parser.ParseFile(fset, p, nil, 0)
		if err != nil {
			t.Fatalf("parse %s: %v", p, err)
		}
		files = append(files, f)
	}
	return fset, files
}

// ---------------------------------------------------------------------------
// Validation (shared by the real test and the fixtures)
// ---------------------------------------------------------------------------

func validate(res scanResult, catalog map[string]catalogEntry, allowlist map[string]string) []string {
	var errs []string

	// Fail closed on any dynamically constructed alert name.
	errs = append(errs, res.dynamic...)

	// FORWARD (completeness): every payout_ identifier literal must be either a
	// catalogued alert OR an allowlisted non-alert string.
	for lit, pos := range res.literals {
		_, inCatalog := catalog[lit]
		_, inAllow := allowlist[lit]
		switch {
		case inCatalog && inAllow:
			errs = append(errs, lit+" is in BOTH catalog.tsv and the non-alert allowlist — pick one")
		case !inCatalog && !inAllow:
			errs = append(errs, pos+": unclassified payout literal "+strconv.Quote(lit)+
				" — classify it as an ALERT event in dist/synthetic-alerts/catalog.tsv, "+
				"or as a NON-ALERT string in dist/synthetic-alerts/non-alert-allowlist.txt")
		}
	}

	// REVERSE (typo / rot guard): every catalog alert name must appear as a
	// literal in the scanned source, EXCEPT spec-only-not-emitted rows (which
	// must stay absent until the emission is wired).
	for name, entry := range catalog {
		_, present := res.literals[name]
		if entry.status == "spec-only-not-emitted" {
			if present {
				errs = append(errs, "catalog marks "+name+" spec-only-not-emitted, but a literal now exists in the source — "+
					"reclassify it to code (with a severity field) in catalog.tsv")
			}
			continue
		}
		if !present {
			errs = append(errs, "catalog entry "+name+" (status "+entry.status+") does not appear as a string literal in the scanned source — "+
				"likely a typo in catalog.tsv or a removed event")
		}
	}

	sort.Strings(errs)
	return errs
}

// ---------------------------------------------------------------------------
// The real test
// ---------------------------------------------------------------------------

func TestSyntheticAlertsCatalog(t *testing.T) {
	root := findRepoRoot(t)
	catalog := loadCatalog(t, root)
	allowlist := loadAllowlist(t, root)

	paths := scannedGoFiles(t, root)
	fset, files := parseFiles(t, paths)
	res := scanFiles(fset, files)

	if len(res.literals) == 0 {
		t.Fatal("scanner found zero payout literals — scan is broken")
	}

	for _, e := range validate(res, catalog, allowlist) {
		t.Error(e)
	}

	// Sound per-site severity-presence: every catalogued alert must be emitted
	// with a matching severity field at every emission site.
	for _, e := range auditCatalogSeverity(fset, files, catalog) {
		t.Error(e)
	}
}

// ---------------------------------------------------------------------------
// Negative fixtures: prove the check fails on each escape path.
// ---------------------------------------------------------------------------

func scanSrc(t *testing.T, src string) scanResult {
	t.Helper()
	fset := token.NewFileSet()
	f, err := parser.ParseFile(fset, "fixture.go", src, 0)
	if err != nil {
		t.Fatalf("parse fixture: %v", err)
	}
	return scanFiles(fset, []*ast.File{f})
}

func hasErrorContaining(errs []string, sub string) bool {
	for _, e := range errs {
		if strings.Contains(e, sub) {
			return true
		}
	}
	return false
}

func TestScanner_NegativeFixtures(t *testing.T) {
	emptyCat := map[string]catalogEntry{}
	emptyAllow := map[string]string{}

	t.Run("unclassified_literal_fails", func(t *testing.T) {
		// A brand-new event literal, emitted via any mechanism, that is in
		// neither the catalog nor the allowlist.
		src := `package p
func f(log L, name string) { log.Error().Str("event", name).Send() }
func use(log L) { f(log, "payout_xyz_totally_new") }`
		res := scanSrc(t, src)
		if _, ok := res.literals["payout_xyz_totally_new"]; !ok {
			t.Fatal("literal was not collected")
		}
		if !hasErrorContaining(validate(res, emptyCat, emptyAllow), "payout_xyz_totally_new") {
			t.Fatal("expected unclassified-literal failure")
		}
		// Classified as an alert -> passes; classified as non-alert -> passes.
		cat := map[string]catalogEntry{"payout_xyz_totally_new": {severity: "PAGE", status: "code"}}
		if hasErrorContaining(validate(res, cat, emptyAllow), "payout_xyz_totally_new") {
			t.Fatal("catalogued literal should not fail forward")
		}
		allow := map[string]string{"payout_xyz_totally_new": "info-event"}
		if hasErrorContaining(validate(res, emptyCat, allow), "unclassified") {
			t.Fatal("allowlisted literal should not fail forward")
		}
	})

	t.Run("dynamic_sprintf_name_fails", func(t *testing.T) {
		src := `package p
import "fmt"
func f(log L, tier string) { log.Error().Str("event", fmt.Sprintf("payout_%s_tripped", tier)).Send() }`
		res := scanSrc(t, src)
		if len(res.dynamic) == 0 || !hasErrorContaining(validate(res, emptyCat, emptyAllow), "dynamic alert-name template") {
			t.Fatalf("expected dynamic-template failure, dynamic=%v", res.dynamic)
		}
	})

	t.Run("dynamic_concat_name_fails", func(t *testing.T) {
		src := `package p
func f(log L, tier string) { ev := "payout_" + tier; log.Error().Str("event", ev).Send() }`
		res := scanSrc(t, src)
		if len(validate(res, emptyCat, emptyAllow)) == 0 {
			t.Fatalf("expected dynamic-concat failure, dynamic=%v", res.dynamic)
		}
	})

	t.Run("indirect_fragment_name_fails", func(t *testing.T) {
		// One-more-indirection: prefix stored in a var, concatenated later.
		// The "payout_" fragment literal must fail even though the "+" operands
		// are both variables.
		src := `package p
func f(log L, suffix string) {
	p := "payout_"
	ev := p + suffix
	log.Error().Str("event", ev).Send()
}`
		res := scanSrc(t, src)
		if !hasErrorContaining(res.dynamic, "name fragment") {
			t.Fatalf("expected fragment failure, dynamic=%v", res.dynamic)
		}
		if len(validate(res, emptyCat, emptyAllow)) == 0 {
			t.Fatal("indirect fragment must cause a validation failure")
		}
	})

	t.Run("prose_message_not_flagged", func(t *testing.T) {
		// A payout_-prefixed ERROR MESSAGE (not an event name) must NOT be
		// mistaken for a dynamic alert name (regression guard for bootstrap.go).
		src := `package p
import "fmt"
func e(where, msg string) string { return fmt.Sprintf("payout_invariant_violation where=%q: %s", where, msg) }`
		res := scanSrc(t, src)
		if len(res.dynamic) != 0 {
			t.Fatalf("prose message wrongly flagged as dynamic name: %v", res.dynamic)
		}
		if len(res.literals) != 0 {
			t.Fatalf("prose message wrongly collected as identifier literal: %v", res.literals)
		}
	})

	t.Run("catalog_typo_fails", func(t *testing.T) {
		// Catalog names a code event that does not exist as a literal.
		src := `package p
func f(log L) { log.Warn().Str("event", "payout_low_balance").Str("severity", "WARN").Send() }`
		res := scanSrc(t, src)
		cat := map[string]catalogEntry{
			"payout_low_balance": {severity: "WARN", status: "code"},
			"payout_low_balancx": {severity: "WARN", status: "code"}, // typo
		}
		allow := map[string]string{}
		if !hasErrorContaining(validate(res, cat, allow), "payout_low_balancx") {
			t.Fatal("expected reverse typo failure")
		}
	})

	t.Run("spec_only_present_fails", func(t *testing.T) {
		// A spec-only-not-emitted event that now appears as a literal must fail.
		src := `package p
func f(log L) { log.Error().Str("event", "payout_nonce_gap").Str("severity", "WARN").Send() }`
		res := scanSrc(t, src)
		cat := map[string]catalogEntry{"payout_nonce_gap": {severity: "WARN", status: "spec-only-not-emitted"}}
		allow := map[string]string{}
		if !hasErrorContaining(validate(res, cat, allow), "spec-only-not-emitted") {
			t.Fatal("expected spec-only-present failure")
		}
	})
}

func auditSevSrc(t *testing.T, src string, catalog map[string]catalogEntry) []string {
	t.Helper()
	fset := token.NewFileSet()
	f, err := parser.ParseFile(fset, "fixture.go", src, 0)
	if err != nil {
		t.Fatalf("parse fixture: %v", err)
	}
	return auditCatalogSeverity(fset, []*ast.File{f}, catalog)
}

func TestSeverityAudit_NegativeFixtures(t *testing.T) {
	t.Run("catalogued_event_without_severity_fails", func(t *testing.T) {
		src := `package p
func f(log L) { log.Error().Str("event", "payout_x_alert").Send() }`
		cat := map[string]catalogEntry{"payout_x_alert": {severity: "PAGE", status: "code"}}
		if !hasErrorContaining(auditSevSrc(t, src, cat), "WITHOUT a severity field") {
			t.Fatal("expected missing-severity failure")
		}
	})

	t.Run("wrong_severity_fails", func(t *testing.T) {
		src := `package p
func f(log L) { log.Warn().Str("event", "payout_x_alert").Str("severity", "WARN").Send() }`
		cat := map[string]catalogEntry{"payout_x_alert": {severity: "PAGE", status: "code"}}
		if !hasErrorContaining(auditSevSrc(t, src, cat), "severity mismatch") {
			t.Fatal("expected severity mismatch failure")
		}
		catOK := map[string]catalogEntry{"payout_x_alert": {severity: "WARN", status: "code"}}
		if len(auditSevSrc(t, src, catOK)) != 0 {
			t.Fatal("matching severity should pass")
		}
	})

	t.Run("helper_emitted_without_severity_fails", func(t *testing.T) {
		// Event name reaches the .Str("event", …) site only as a helper
		// parameter (variable). The check must trace the helper and still catch
		// the missing severity.
		src := `package p
func emit(log L, name string) { log.Error().Str("event", name).Send() }
func use(log L) { emit(log, "payout_x_alert") }`
		cat := map[string]catalogEntry{"payout_x_alert": {severity: "PAGE", status: "code"}}
		if !hasErrorContaining(auditSevSrc(t, src, cat), "WITHOUT a severity field") {
			t.Fatal("expected helper missing-severity failure")
		}
		// With severity in the helper chain -> passes.
		srcOK := `package p
func emit(log L, name string) { log.Error().Str("event", name).Str("severity", "PAGE").Send() }
func use(log L) { emit(log, "payout_x_alert") }`
		if len(auditSevSrc(t, srcOK, cat)) != 0 {
			t.Fatal("helper WITH severity should pass")
		}
	})

	t.Run("no_emission_fails_closed", func(t *testing.T) {
		// Catalogued alert never emitted anywhere -> fail-closed.
		src := `package p
func f(log L) { log.Error().Str("event", "payout_other").Str("severity", "PAGE").Send() }`
		cat := map[string]catalogEntry{"payout_missing_alert": {severity: "PAGE", status: "code"}}
		if !hasErrorContaining(auditSevSrc(t, src, cat), "no resolvable production emission") {
			t.Fatal("expected fail-closed no-emission failure")
		}
	})

	t.Run("status_does_not_exempt_from_severity", func(t *testing.T) {
		// MEDIUM-1: a catalogued PAGE alert emitted without severity must FAIL
		// regardless of status — a resurrected `code-untagged` (or any status)
		// cannot bypass the severity requirement. Gate is severity-based.
		src := `package p
func f(log L) { log.Error().Str("event", "payout_x_alert").Send() }`
		for _, status := range []string{"code", "code-untagged", "whatever"} {
			cat := map[string]catalogEntry{"payout_x_alert": {severity: "PAGE", status: status}}
			if !hasErrorContaining(auditSevSrc(t, src, cat), "WITHOUT a severity field") {
				t.Fatalf("status %q must not exempt an emitted alert from the severity check", status)
			}
		}
		// INFO severity is genuinely exempt (not an alert).
		catInfo := map[string]catalogEntry{"payout_x_alert": {severity: "INFO", status: "info"}}
		if len(auditSevSrc(t, src, catInfo)) != 0 {
			t.Fatal("INFO event should not require a severity field")
		}
	})

	t.Run("unresolvable_emitted_alert_fails_closed_not_skipped", func(t *testing.T) {
		// MEDIUM-2: a payout emission whose event NAME the harness cannot
		// resolve AND which lacks severity must FAIL (not be silently skipped).
		src := `package payout
func f(log L, in string) { log.Error().Str("event", computeName(in)).Send() }`
		cat := map[string]catalogEntry{}
		if !hasErrorContaining(auditSevSrc(t, src, cat), "cannot resolve") {
			t.Fatal("expected fail-closed on an unresolvable, severity-less payout emission")
		}
		// The same emission WITH a literal severity is verifiable -> no failure.
		srcOK := `package payout
func f(log L, in string) { log.Error().Str("event", computeName(in)).Str("severity", "PAGE").Send() }`
		if len(auditSevSrc(t, srcOK, cat)) != 0 {
			t.Fatal("an unresolvable name WITH a visible severity should not fail")
		}
		// Outside package payout (e.g. general coordinator logging) it is not
		// flagged, avoiding false positives on non-payout events.
		srcMain := `package main
func f(log L, in string) { log.Error().Str("event", computeName(in)).Send() }`
		if len(auditSevSrc(t, srcMain, cat)) != 0 {
			t.Fatal("non-payout package must not trip the unresolved check")
		}
	})

	t.Run("page_capable_dynamic_ok_but_warn_only_catalog_fails", func(t *testing.T) {
		src := `package p
func f(log L, ceil bool) {
	sev := "WARN"
	if ceil { sev = "PAGE" }
	log.Warn().Str("event", "payout_dyn_alert").Str("severity", sev).Send()
}`
		cat := map[string]catalogEntry{"payout_dyn_alert": {severity: "WARN", status: "code"}}
		if !hasErrorContaining(auditSevSrc(t, src, cat), "page_capable") {
			t.Fatal("expected page_capable failure")
		}
		catOK := map[string]catalogEntry{"payout_dyn_alert": {severity: "WARN", status: "code", pageCapable: true}}
		if len(auditSevSrc(t, src, catOK)) != 0 {
			t.Fatal("page_capable catalog should pass")
		}
	})
}
