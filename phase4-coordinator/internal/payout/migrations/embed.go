// Package migrations holds the SPEC-016 schema migrations as
// embedded files so the migration runner can apply them in
// lexicographic order from a single shared *sql.DB handle.
package migrations

import "embed"

//go:embed *.sql
var FS embed.FS
