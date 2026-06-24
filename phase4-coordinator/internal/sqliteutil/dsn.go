package sqliteutil

import (
	"net/url"
	"strings"
)

// WithPragmas builds a modernc.org/sqlite DSN with the project's standard
// pragma set (busy_timeout, foreign_keys, WAL, synchronous=NORMAL).
//
// ARCH-5: this helper is byte-identical to phase5-gateway/internal/storage/
// sqlite/dsn.go::sqliteDSN. The duplication is intentional — coordinator and
// gateway are deployed as independent Go modules, and introducing a shared
// library would re-couple them on every DSN tweak. See audits/2026-06-10/
// REPO_AUDIT.md (ARCH-5) for the conscious-debt reasoning.
func WithPragmas(path string) string {
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
