# SPEC-017 IMPL Prompt CODE-MECHANICS Audit - Round 1

Audit target: `specs/BUILD_SPEC_017_IMPL_PROMPT.md`  
Controlling contract: `specs/SPEC-017-network-stats-api.md` v0.1.6 LOCKED  
Lens: code mechanics only. The SPEC is not under audit.

## Verdict

**NOT READY for IMPL kickoff.**

Counts: **2 CRITICAL, 10 HIGH, 5 MEDIUM, 1 LOW, 2 INFO**.

The IMPL prompt is generally aligned with the locked SPEC on status codes, partner-key length, CORS 204, error vocabulary, and the normative role names. It still has code-mechanics defects that would send an implementer into wrong columns, wrong command surfaces, wrong package boundaries, incomplete role-isolation tests, and an overbroad AC test plan.

## Findings

### CODE-R1-001 - Wrong fresh-session workspace path

Location: `specs/BUILD_SPEC_017_IMPL_PROMPT.md:3`  
Severity: **HIGH**  
Category: wrong file path

The prompt tells the IMPL author to start in `/Users/augstar/macprovider-poc`, but this audited worktree and all requested output live under `/Users/augstar/macprovider-spec-017`. Following the prompt literally can put implementation work in the wrong checkout or branch before any SPEC verification begins.

Fix: Replace the absolute path with the actual kickoff worktree path, or remove the absolute path and instruct the author to verify `pwd` plus `git status -sb` before editing.

### CODE-R1-002 - `stats_components_health.status` is a nonexistent column

Location: `specs/BUILD_SPEC_017_IMPL_PROMPT.md:84`  
Severity: **CRITICAL**  
Category: wrong table / column name, test-shape correctness

The Step 2 integration test says an SLA breach should result in `stats_components_health.status = 'degraded'`. SPEC §9.1 defines `stats_components_health` with columns `component`, `generated_at`, `last_ok_at`, `last_error_at`, and `last_error_message`; it has no `status` column. SPEC §5.3 derives response-level component status from freshness thresholds, and §9.5 defines those thresholds.

The same bullet also says "kill rollup, observe `stale_after` increment", but stale response fields derive from unchanged `generated_at + s-maxage`; a killed rollup should make lag grow, not advance `stale_after`.

Fix: Rewrite the test to seed or age `stats_components_health.generated_at`, call `/v1/stats/health`, and assert the JSON `status` / component status derived from §5.3 and §9.5. Do not assert a table column named `status`.

### CODE-R1-003 - Partner-key CLI insert omits NOT NULL `created_by`

Location: `specs/BUILD_SPEC_017_IMPL_PROMPT.md:134-135`  
Severity: **CRITICAL**  
Category: wrong table / column mapping, CLI surface

The Step 4 issuance directive says to insert `token_hash`, `prefix`, label, `allowed_origins`, and `rate_limit_*` into `partner_keys`, but SPEC §5.4.1 defines `created_by TEXT NOT NULL`. An implementation that follows only the prompt's listed insert columns will fail at runtime with a NOT NULL violation on the first `coordinator partner-keys issue`.

Fix: Include `created_by` in the CLI contract and tests. The prompt should define where it comes from, for example an operator identity flag, current OS user, or configured operator principal, and AC-17 should assert the row has it.

### CODE-R1-004 - `stats_reader` grant summary accidentally includes `stats_late_events`

Location: `specs/BUILD_SPEC_017_IMPL_PROMPT.md:47`  
Severity: **HIGH**  
Category: Postgres grant shape correctness

The prompt summarizes `stats_reader` as having SELECT on `stats_*` plus `partner_keys` and `provider_visibility`. In SPEC §7.2.1, `stats_reader` must not have `stats_late_events`; §7.2.1 explicitly lists it as rollup-internal only. Because `stats_late_events` matches the `stats_*` shorthand, the prompt's grant summary is overbroad.

Fix: Replace the shorthand with the exact §7.2.1 table list: `stats_overview_current`, both `stats_timeseries_*` tables, all four `stats_leaderboard_*` tables, `stats_components_health`, `provider_visibility`, and `partner_keys`. Explicitly say `stats_late_events` is denied.

### CODE-R1-005 - Step 3 package path conflicts with SPEC §4.2 and explorer pattern

Location: `specs/BUILD_SPEC_017_IMPL_PROMPT.md:39`, `specs/BUILD_SPEC_017_IMPL_PROMPT.md:95`; existing pattern `phase4-coordinator/internal/explorer/handlers.go:1-36`  
Severity: **MEDIUM**  
Category: Go package boundary correctness

SPEC §4.2 names `phase4-coordinator/internal/stats/` as the handler package and `internal/stats/store/` plus `internal/stats/rollup/` as subpackages. The existing explorer pattern is a flat `internal/explorer` package with `handlers.go` and store code in the same package. The IMPL prompt first says to create `internal/stats/`, then Step 3 says handlers live in `internal/stats/handlers/`. Two conforming authors could choose different package layouts.

Fix: Pick one layout in the prompt. The mechanically closest choice to SPEC §4.2 and explorer is `internal/stats` for the HTTP handler, `internal/stats/store` for DAO code, and `internal/stats/rollup` for jobs.

### CODE-R1-006 - AC-2 is cited for limit boundary behavior it does not cover

Location: `specs/BUILD_SPEC_017_IMPL_PROMPT.md:98`  
Severity: **HIGH**  
Category: wrong AC reference

The prompt says `limit=0` and `limit=101` return 400 "per AC-2". AC-2 only covers default `window=24h` and invalid `window=foo`. Limit validation is normative in SPEC §5.2, not AC-2.

Fix: Change the citation to SPEC §5.2 and add an explicit test mapping for limit range validation. Do not attribute limit boundaries to AC-2.

### CODE-R1-007 - Partner-key auth decision table is counted as 6 rows, but SPEC has 7

Location: `specs/BUILD_SPEC_017_IMPL_PROMPT.md:100`  
Severity: **HIGH**  
Category: wire-contract correctness

The prompt describes the §5.4.3 auth flow as a "6-row branch". The locked SPEC §5.4.3 table has seven rows: absent auth, active key with empty allowlist, active key with non-empty allowlist and absent Origin, allowlisted Origin, non-allowlisted Origin, no matching row, and revoked row.

Fix: Say "7-row decision table" and require a table-driven test with one case per row.

### CODE-R1-008 - Rotation CLI surface is wrong

Location: `specs/BUILD_SPEC_017_IMPL_PROMPT.md:138`; SPEC §5.4.4  
Severity: **HIGH**  
Category: wrong CLI surface

The prompt defines `coordinator partner-keys rotate-from --id <id>`, but SPEC §5.4.4 says rotation is performed by issuing a new key with `--rotate-from <existing_id>`. The normative command shape is `coordinator partner-keys issue --rotate-from <existing_id>`, with later revocation through `coordinator partner-keys revoke`.

Fix: Remove the standalone `rotate-from` subcommand and direct implementation/tests to `coordinator partner-keys issue --rotate-from <existing_id>`.

### CODE-R1-009 - Import-graph lint test omits the `internal/auth` boundary

Location: `specs/BUILD_SPEC_017_IMPL_PROMPT.md:39`, `specs/BUILD_SPEC_017_IMPL_PROMPT.md:59`; SPEC §7.6 and AC-16  
Severity: **HIGH**  
Category: Go package boundary correctness, AC test coverage

The Step 1 "What lands" bullet correctly says `internal/stats` must not import `internal/auth` except for a minimal Bearer parser. The Step 1 lint bullet only rejects `internal/billing|internal/explorer|internal/ws`. That lint would not enforce the full AC-16 forbidden set and could allow broad auth-package coupling to land.

Fix: Make the CI rule cover `internal/auth` as well, with an explicit allowlist for the minimal Bearer parser symbol or package if one is created.

### CODE-R1-010 - AC coverage is mapped to the wrong step and misses required fixtures

Location: `specs/BUILD_SPEC_017_IMPL_PROMPT.md:53-59`, `specs/BUILD_SPEC_017_IMPL_PROMPT.md:81-87`, `specs/BUILD_SPEC_017_IMPL_PROMPT.md:113-121`, `specs/BUILD_SPEC_017_IMPL_PROMPT.md:148-153`  
Severity: **HIGH**  
Category: AC test-coverage mapping

The Step 3 test bullet says every AC-1 through AC-21 has a deterministic unit test. Several ACs are not Step 3 unit-testable and need specific coverage elsewhere:

- AC-9 belongs to Step 1 role/grant integration.
- AC-10 needs a provider-portal UPSERT plus audit-row transaction fixture; the prompt has no such test.
- AC-16 belongs to CI import-graph lint, not Step 3 handler unit tests.
- AC-17 belongs to Step 4 CLI integration.
- AC-19 needs a no-row `provider_visibility` fixture and public leaderboard assertion; it is not named in Step 2 or Step 3 specifics.
- AC-20 needs the SPEC-required SQL fixture and CI assertion; the prompt does not direct it.
- AC-8 is split between nginx primary enforcement and in-process fallback, but Step 3 claims all ACs before Step 4 nginx exists.

Fix: Replace the Step 3 "every AC" unit-test bullet with an AC-to-step matrix. Add explicit tests for AC-10, AC-19, and AC-20.

### CODE-R1-011 - Cache-Control values are normative but not mechanically tested

Location: `specs/BUILD_SPEC_017_IMPL_PROMPT.md:116`, `specs/BUILD_SPEC_017_IMPL_PROMPT.md:139`, `specs/BUILD_SPEC_017_IMPL_PROMPT.md:192`; SPEC §5.1, §5.2, §5.3  
Severity: **HIGH**  
Category: wire-contract correctness, test-shape correctness

The prompt says every GET returns `Cache-Control` per SPEC and nginx uses cache directives per response headers, but the concrete tests only call out JSON shape and nginx validation. SPEC pins `s-maxage=30` for overview, `s-maxage=60` public leaderboard, `s-maxage=30` private leaderboard, and `s-maxage=10` health. No prompt bullet requires asserting those header values.

Fix: Add handler tests asserting the exact `Cache-Control` header for `/overview`, `/leaderboard` public, `/leaderboard` partner-key, and `/health`, plus nginx smoke that confirms partner projections are not cached.

### CODE-R1-012 - Log-redaction tests are narrower than the prompt's own redaction constraint

Location: `specs/BUILD_SPEC_017_IMPL_PROMPT.md:120`, `specs/BUILD_SPEC_017_IMPL_PROMPT.md:136`, `specs/BUILD_SPEC_017_IMPL_PROMPT.md:150`, `specs/BUILD_SPEC_017_IMPL_PROMPT.md:196`; SPEC §3.7, §5.4.6, AC-15, AC-17  
Severity: **HIGH**  
Category: AC test-coverage mapping

The constraints correctly prohibit the raw token, `token_hash`, and substrings of the random portion in logs. The tests only assert no raw `Authorization` value in journald, and Step 4 only checks journald after CLI exit. SPEC §5.4.6 also covers nginx logs, metric labels, trace spans, and `token_hash`. SPEC §3.7 forbids token in response body and metric labels except the one-time CLI stdout.

Fix: Add redaction tests or smoke checks for application logs, nginx access logs, metrics labels, response bodies, and CLI command output transcript. Include `token_hash` and random-substring checks, not just raw header equality.

### CODE-R1-013 - Backfill gate contradicts itself

Location: `specs/BUILD_SPEC_017_IMPL_PROMPT.md:21`, `specs/BUILD_SPEC_017_IMPL_PROMPT.md:27`, `specs/BUILD_SPEC_017_IMPL_PROMPT.md:78`  
Severity: **MEDIUM**  
Category: migration / IMPL-time decision drift

The pre-flight section says backfill posture is a hard prerequisite and the author must be told Path A or Path B before writing `30d` / `all` rollup. Step 2 then says to default to Path A unless the operator selected Path B. That weakens the hard gate and lets an author proceed without the required operator decision.

Fix: Make Step 2 conditional on an explicit recorded decision. If the operator has not selected Path A or B, Step 2 should stop before `30d` / `all` rollup code and tests.

### CODE-R1-014 - Rollup fixture corpus is underspecified

Location: `specs/BUILD_SPEC_017_IMPL_PROMPT.md:83`, `specs/BUILD_SPEC_017_IMPL_PROMPT.md:116`, `specs/BUILD_SPEC_017_IMPL_PROMPT.md:229`  
Severity: **MEDIUM**  
Category: test-shape correctness

The prompt requires deterministic output on a "fixture OLTP corpus" and later a "seeded fixture corpus", but it does not define the corpus shape. Rollup correctness depends on request timestamps, provider IDs, attempts, work credits, operator credits, tokens in/out, late events, visibility rows, and rewards-ledger rows. Two authors can build incompatible fixtures that pass different subsets of §9.

Fix: Add a minimal named fixture corpus with rows for at least two providers, one bucketed/no-row provider, one exact provider, one rewards row, one late event inside 48h, one late event outside 48h, and enough request/token rows to verify all sort axes.

### CODE-R1-015 - Existing DB mechanics are not bridged to SPEC's per-role Postgres pools

Location: `specs/BUILD_SPEC_017_IMPL_PROMPT.md:40`, `specs/BUILD_SPEC_017_IMPL_PROMPT.md:51`, `specs/BUILD_SPEC_017_IMPL_PROMPT.md:55`; current code `phase4-coordinator/cmd/coordinator/main.go:60-88`, `phase4-coordinator/internal/requestlog/store.go:47-74`, `phase4-coordinator/internal/auth/tokens.go:204-229`  
Severity: **MEDIUM**  
Category: idiomatic Go correctness, package mechanics

The current coordinator opens SQLite stores from one `storage.db_path` and shares `reqLogStore.DB()` with billing, explorer, admission, and canary code. The locked SPEC requires Postgres roles and separate `*sql.DB` instances per role. The IMPL prompt says "separate `*sql.DB` instances per role" but does not direct the config shape, driver choice, migration runner, or how the new stats Postgres pools coexist with the current SQLite stores.

Fix: Add a Step 1 mechanics bullet for stats DB configuration: explicit DSNs per role, driver import, pool settings, initialization ownership, and a test that handlers receive the `stats_reader` pool while rollup receives `stats_rollup`.

### CODE-R1-016 - Smoke test says "all four endpoints" but SPEC has three endpoints

Location: `specs/BUILD_SPEC_017_IMPL_PROMPT.md:153`; SPEC §1.2 and §4.3  
Severity: **MEDIUM**  
Category: wire-contract correctness

The Step 4 smoke test says "verify all four endpoints serve". SPEC §1.2 and §4.3 define three endpoints: `/overview`, `/leaderboard`, and `/health`. The wording can send implementers looking for or inventing a fourth endpoint.

Fix: Change to "all three endpoints" and list them explicitly.

### CODE-R1-017 - Recover middleware shape is under-specified for a subtree-level invariant

Location: `specs/BUILD_SPEC_017_IMPL_PROMPT.md:110`, `specs/BUILD_SPEC_017_IMPL_PROMPT.md:121`; SPEC §7.3 and AC-11  
Severity: **MEDIUM**  
Category: idiomatic Go correctness

The prompt requires recover middleware but does not specify middleware order, whether it wraps `OPTIONS` / 405 paths too, whether it preserves the §5.9 JSON content type, or how the panic logger avoids leaking stack or SQL details. AC-11 only asserts process survival and `event=stats_handler_panic`, so different authors could satisfy it with different error behavior.

Fix: Define the middleware contract: wrap the entire `/v1/stats/*` subtree outermost, recover all methods including CORS and 405 paths, log `event=stats_handler_panic` without raw token/SQL/stack in public logs, and return `500` with `code:"internal"` using the §5.9 envelope.

### CODE-R1-018 - "No §9 equivalent" wording is citation hygiene drift

Location: `specs/BUILD_SPEC_017_IMPL_PROMPT.md:18`  
Severity: **LOW**  
Category: section number drift / naming hygiene

The prompt says there is "no §9 equivalent for SPEC-017" while SPEC-017 has a substantial §9 Rollup pipeline. The sentence appears to mean "no operator-prerequisite section equivalent to SPEC-016", not that §9 is absent. This is not an implementation-breaking citation, but it is confusing in a prompt that asks the author to verify every section reference.

Fix: Reword to "SPEC-017 has no operator-prerequisite section analogous to SPEC-016's hot-wallet gate."

## Positive Checks

- Partner-key length math in Step 4 is correct: 32 random bytes encoded with unpadded base64url yields 43 characters, plus `mpk_` equals 47 total.
- CORS preflight is pinned to exactly 204 and does not allow a 200 fallback.
- Error vocabulary matches SPEC §5.9: `bad_request`, `unauthorized`, `method_not_allowed`, `rate_limited`, `stats_stale`, `internal`.
- Role names are consistent: `stats_reader`, `stats_rollup`, `provider_portal`, and optional `partner_keys_writer`.
- Event names proposed for stats observability do not collide with the existing explorer's `internal_bearer_accepted` event.

## Self-Verification

- [x] Walked every `§X.Y` citation in the IMPL prompt against SPEC-017 v0.1.6.
- [x] Walked every `AC-N` citation in the IMPL prompt against SPEC §10.
- [x] Walked every grant summary / role directive in the IMPL prompt against SPEC §7.2 and §9.1 / §9.1a / §6.1 / §6.5 / §5.4.1.
- [x] Walked Categories A through I from the audit prompt.
- [x] Severity chosen against the provided definitions.
- [x] Verdict provided.

## 200-Word Handback Summary

The IMPL prompt is close enough to the locked SPEC to be repairable, but it is not ready for kickoff. The biggest code-mechanics defects are concrete: Step 2 tells authors to assert `stats_components_health.status`, a column the SPEC never defines; Step 4's partner-key insert omits `created_by`, which is NOT NULL; and the rotation CLI is named differently from the SPEC's `issue --rotate-from` command. The grant summary also uses `stats_*` for `stats_reader`, which accidentally sweeps in `stats_late_events`, a table §7.2.1 explicitly denies to the request path.

The test plan needs reshaping. It claims all AC-1 through AC-21 are Step 3 unit tests, but AC-9, AC-16, AC-17, AC-20, nginx rate limiting, and portal visibility auditing belong to other steps or CI fixtures. AC-10, AC-19, and AC-20 are effectively unmapped. Cache headers and redaction surfaces are normative but not tested deeply enough.

The prompt also needs package and DB mechanics tightened against the current coordinator pattern: the repo uses flat explorer handlers and SQLite-backed shared stores today, while SPEC-017 introduces stats package boundaries plus per-role Postgres `*sql.DB` pools. A small prompt fix pass can preserve the SPEC exactly while making implementation steps mechanically unambiguous and testable.
