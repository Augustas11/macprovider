package billing

// requestLogIDOrdinalSQL is the attempt ordinal of request_log row `alias`
// derived by id order within its (account_id, request_id) scope — the value
// the hot path computes as COUNT(*)-1 right after inserting the row
// (hotpath.go). SQLite `IS` makes NULL account_id rows cluster with NULL
// account_id rows only.
func requestLogIDOrdinalSQL(alias string) string {
	return `(
         SELECT COUNT(*) - 1 FROM request_log prior
          WHERE prior.account_id IS ` + alias + `.account_id
            AND prior.request_id = ` + alias + `.request_id
            AND prior.id <= ` + alias + `.id
       )`
}

// requestLogAttemptOrdinalSQL is the one attempt-ordinal expression every
// reader of request_log uses (recovery orphan scan, recovery join, admin
// reconcile, wholesale generation lookup): the persisted monotonic
// attempt_n when non-NULL (SPEC-002 v1.5.2 / SPEC-005 v0.3.3, issue #168),
// else the id-order derivation for legacy NULL rows.
func requestLogAttemptOrdinalSQL(alias string) string {
	return `COALESCE(` + alias + `.attempt_n, ` + requestLogIDOrdinalSQL(alias) + `, 0)`
}
