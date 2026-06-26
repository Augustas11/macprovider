// SPEC-017 §7.3 + BUILD §D.3 — forbidigo rule fixture for
// os.Exit / log.Fatal usage anywhere under `internal/stats/*`.
//
// Under the `linttest_fixture` build tag this file compiles and
// calls os.Exit; the AC-16-adjacent TestForbidigoOSExitRule test
// invokes golangci-lint with the tag and asserts the forbidigo
// diagnostic fires.

//go:build linttest_fixture

package stats

import "os"

func _forbidigoFixtureOSExit() {
	os.Exit(1)
}
