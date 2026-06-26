// SPEC-017 AC-16 lint fixture (BUILD §D.4 / §E.4).
//
// This file is a VALID Go file that imports a forbidden package
// (`internal/billing`) from inside `internal/stats/`. The build
// tag below excludes it from normal `go build` / `go vet` /
// `golangci-lint run` invocations so the main lint pass stays
// clean.
//
// The AC-16 test (`lint_test.go`) invokes golangci-lint with the
// `linttest_fixture` build tag enabled and asserts the depguard
// rule named "stats-request-path" fires with the diagnostic
// containing "internal/billing". This proves (i) the fixture
// path is REAL and (ii) the lint rule WOULD reject the
// production import.
//
// Per BUILD §E.4, the fixture MUST be COMPILABLE so the failure
// is a lint diagnostic, NOT a compiler error from a bad import
// path. The blank import below is syntactically valid Go.

//go:build linttest_fixture

package stats

import _ "github.com/augstar/macprovider-coordinator/internal/billing"
