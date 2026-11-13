package router

import (
	"net/http"
	"strconv"
	"strings"
)

// servedPathResponseHeader is the coordinator's internal SPEC-002-R007
// served-path label. It is in the X-MacProvider-* namespace that
// copyCleanHeadersFiltered removes from every buyer response, and the
// gateway forwards no coordinator trailer, so it never reaches a buyer. It
// is stored only as a demand-row label (SPEC-006-R028).
const servedPathResponseHeader = "X-MacProvider-Internal-Served-Path"

// parseServedPath returns the path and rows of a value that byte-exactly
// matches the SPEC-002-R007 grammar. rows is nil for path=unknown.
func parseServedPath(value string) (string, *int64, bool) {
	rest, ok := strings.CutPrefix(value, "v=1; path=")
	if !ok {
		return "", nil, false
	}
	path, rows, ok := strings.Cut(rest, "; rows=")
	if !ok {
		return "", nil, false
	}
	switch path {
	case "unknown":
		if rows != "unknown" {
			return "", nil, false
		}
		return path, nil, true
	case "serial", "continuous_batching", "native_mtp", "shard_group":
	default:
		return "", nil, false
	}
	if rows == "" || len(rows) > 3 || rows[0] == '0' {
		return "", nil, false
	}
	for _, c := range rows {
		if c < '0' || c > '9' {
			return "", nil, false
		}
	}
	n, err := strconv.ParseInt(rows, 10, 64)
	if err != nil || n < 1 || n > 256 {
		return "", nil, false
	}
	return path, &n, true
}

// observeServedPath keeps the last valid value; a header or trailer that
// fails the grammar changes nothing.
func (t *gatewayPhaseTiming) observeServedPath(h http.Header) {
	if t == nil {
		return
	}
	for _, value := range h.Values(servedPathResponseHeader) {
		if path, rows, ok := parseServedPath(value); ok {
			t.servedPath, t.servedRows = path, rows
			return
		}
	}
}
