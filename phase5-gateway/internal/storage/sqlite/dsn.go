package sqlite

import (
	"net/url"
	"strings"
)

// sqliteDSN builds a modernc.org/sqlite DSN with the project's standard
// pragma set (busy_timeout, foreign_keys, WAL, synchronous=NORMAL).
//
// ARCH-5: this helper is byte-identical to phase4-coordinator/internal/
// sqliteutil/dsn.go::WithPragmas. The duplication is intentional — gateway
// and coordinator are deployed as independent Go modules, and introducing a
// shared library would re-couple them on every DSN tweak. See audits/
// 2026-06-10/REPO_AUDIT.md (ARCH-5) for the conscious-debt reasoning.
func sqliteDSN(path string) string {
	values := url.Values{}
	for _, pragma := range []string{
		"busy_timeout=5000",
		"foreign_keys=1",
		"journal_mode(WAL)",
		"synchronous(NORMAL)",
	} {
		values.Add("_pragma", pragma)
	}
	separator := "?"
	if strings.Contains(path, "?") {
		separator = "&"
	}
	return path + separator + values.Encode()
}

// sqliteReadOnlyDSN returns a read-only DSN for the same file in WAL mode.
// Used by Open's `OpenReadOnly` counterpart (M2-4 / PERF-4) so the gateway
// can route GET-only handlers (explorer, usage) through a separate handle
// with a larger conn cap, while the primary handle stays capped at 1 to
// serialize `BEGIN IMMEDIATE` writes.
//
// modernc.org/sqlite parses the standard `mode=ro` URI parameter for
// open-time read-only intent. We also assert `query_only=1` as a
// per-connection pragma so every connection in the pool is locked into
// read mode at the SQLite engine level (defense in depth against an
// accidental write routed through readStore()).
func sqliteReadOnlyDSN(path string) string {
	values := url.Values{}
	values.Add("mode", "ro")
	for _, pragma := range []string{
		"busy_timeout=5000",
		"foreign_keys=1",
		// journal_mode is set by the primary writer; the read handle
		// follows. synchronous pinned to NORMAL for parity.
		"synchronous(NORMAL)",
		"query_only(1)",
	} {
		values.Add("_pragma", pragma)
	}
	separator := "?"
	if strings.Contains(path, "?") {
		separator = "&"
	}
	return path + separator + values.Encode()
}
