package store

import (
	"database/sql"

	"github.com/lib/pq"
)

// pqArray is the lib/pq TEXT[] scanner. Wrapping the variadic
// dest avoids the temptation to import lib/pq into every store
// file — only this one names the dependency.
func pqArray(dest *[]string) sql.Scanner {
	return pq.Array(dest)
}
