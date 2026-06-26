package rollup

// SPEC-005 v0.3 effective-completion-tokens semantic, used by
// every rollup token aggregation (overview tokens_out + tpm
// output_tokens + leaderboard tokens + late_events delta_tokens).
//
// SPEC-005 §11.4 / §X-1: ledger rows have one of three
// `usage_source` values:
//
//   - 'provider_reported' → `completion_tokens` is the truth.
//   - 'byte_estimated'    → `completion_tokens` is NULL;
//                           `estimated_completion_tokens` is
//                           the effective count.
//   - 'null_error'        → both columns may be NULL; effective
//                           tokens = 0 (the row carries
//                           gross_credits=0 by SPEC-005 CHECK
//                           constraint).
//
// Round-3 CODE r3 HIGH 1 fix: every rollup query that sums
// completion-token-equivalents MUST use this CASE expression
// instead of `lrc.completion_tokens` directly. Naive
// `COALESCE(SUM(prompt_tokens + completion_tokens), 0)` turns
// `prompt_tokens + NULL` into NULL for byte_estimated rows,
// silently dropping their contribution.

// effectiveCompletionTokensSQL returns the per-row SQL fragment
// for effective completion tokens, given the ledger alias.
//
// Callers paste this fragment into their SELECT list. Kept as a
// function instead of a const so the alias is parameterized
// (the alias `lrc` is conventional but tests may use a
// different alias).
func effectiveCompletionTokensSQL(alias string) string {
	return "(CASE " +
		alias + ".usage_source " +
		"WHEN 'byte_estimated' THEN COALESCE(" + alias + ".estimated_completion_tokens, 0) " +
		"WHEN 'null_error' THEN 0 " +
		"ELSE COALESCE(" + alias + ".completion_tokens, 0) " +
		"END)"
}

// effectivePromptTokensSQL is the per-row SQL fragment for
// prompt tokens. Currently a thin COALESCE — kept as a function
// for symmetry with effectiveCompletionTokensSQL and so future
// SPEC-005 evolutions (e.g. byte-estimated prompts) only need
// one call-site change.
func effectivePromptTokensSQL(alias string) string {
	return "COALESCE(" + alias + ".prompt_tokens, 0)"
}

// authenticatedProvidersRelation is the rollup's SQL fragment
// for the authenticated-provider set, used in place of a raw
// `provider_tokens` JOIN.
//
// Round-8 CODE r8 HIGH 1 fix: the real `provider_tokens` schema
// (`phase4-coordinator/internal/auth/tokens.go:247`) allows
// MULTIPLE rows per `provider_id` over time — one active plus N
// revoked historical rows, enforced via a partial unique index
// only on unrevoked rows. A raw
// `JOIN provider_tokens pt ON pt.provider_id = lrc.provider_id`
// multiplies the LHS by the count of `provider_tokens` rows for
// each provider, inflating overview tokens, leaderboard
// earnings, timeseries buckets, etc., once any provider has any
// revoke/reissue history.
//
// The fix collapses `provider_tokens` to its DISTINCT provider
// IDs before joining. v0.1 IMPL trust-source policy is
// "authenticated-EVER," not "currently-active" — a provider
// with all-revoked tokens has historical activity that SHOULD
// be visible in lifetime leaderboards (`stats_leaderboard_all`).
// v0.2 may pin a stricter "active-only" policy; that would
// change this relation to add `WHERE revoked_at IS NULL`.
//
// Excluding empty provider_id matches the partial-unique-index
// predicate in the auth schema.
const authenticatedProvidersRelation = `(SELECT DISTINCT provider_id FROM provider_tokens WHERE provider_id <> '')`
