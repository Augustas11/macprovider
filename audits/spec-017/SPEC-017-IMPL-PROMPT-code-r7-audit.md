# SPEC-017 IMPL Prompt Code-Mechanics Audit - Round 7

**Target:** `specs/BUILD_SPEC_017_IMPL_PROMPT.md`  
**Lens:** CODE-MECHANICS  
**Controlling contract:** `specs/SPEC-017-network-stats-api.md` v0.1.7 LOCKED  
**Required pattern check:** `phase4-coordinator/internal/explorer/handlers.go`

## Verdict

**NOT READY:** 1 CRITICAL, 2 HIGH, 5 MEDIUM, 2 LOW.

The v0.1.7 re-anchor mostly landed: partner-key length math, v0.1.7 public/partner projections, the 7-component health split, `blocked_from_partner_projection`, `meta.rewards_populated`, CORS Max-Age 60, 3-way AC-18 timing, and the AC matrix are largely aligned. The remaining blockers are code-mechanics defects in the IMPL prompt itself: a rollup rebuild SQL path that is not executable by the stated `stats_rollup` grants, a Step 4 cache test that contradicts AC-3, and a production escape hatch that permits shipping a locked-SPEC rate-limit divergence.

## Findings

### CODE-R7-001 - CRITICAL - Nightly rebuild SQL cannot execute under the stated `stats_rollup` grant set

**Location:** `specs/BUILD_SPEC_017_IMPL_PROMPT.md:141-146`, `specs/BUILD_SPEC_017_IMPL_PROMPT.md:241-244`  
**SPEC evidence:** `specs/SPEC-017-network-stats-api.md:1530-1551`, `specs/SPEC-017-network-stats-api.md:1997-2019`

**Finding:** The prompt tells Step 2 that `internal/stats/rollup/` uses the `stats_rollup` `*sql.DB`, then offers two nightly rebuild shapes:

- Shape A uses `CREATE TEMP TABLE ... LIKE ...`, `TRUNCATE stats_leaderboard_all`, and `INSERT`.
- Shape B uses `ALTER TABLE ... RENAME` and `DROP TABLE`.

But the stated `stats_rollup` role has only `SELECT, INSERT, UPDATE, DELETE` on the rollup tables plus sequence and source-read grants. PostgreSQL does not let that role `TRUNCATE` a table without `TRUNCATE` privilege, and `ALTER TABLE ... RENAME` / `DROP TABLE` require ownership or stronger DDL authority. Shape A may also depend on database-level temp-table privileges that the prompt does not pin.

**Risk:** A conforming implementation that runs the prompt's rebuild SQL through `stats_rollup` will fail at runtime on the nightly rebuild path. A single integration test running the deliberately aborted rebuild or successful rebuild under the `stats_rollup` DSN would catch this immediately.

**Fix:** The prompt must not tell the implementer to run these DDL/TRUNCATE shapes through the current `stats_rollup` grants without an execution mechanism. Either mark Step 2 rebuild implementation blocked on a SPEC v0.1.8 grant/execution reconciliation, or pin an implementation shape that is executable under the locked grants and still satisfies §9.4 atomicity. Do not silently widen `stats_rollup`; SPEC §7.2.2 says additional write/non-OLTP grants are a contract violation.

### CODE-R7-002 - HIGH - Step 4.B cache test treats invalid `Authorization` as a public cached response

**Location:** `specs/BUILD_SPEC_017_IMPL_PROMPT.md:531`  
**SPEC evidence:** `specs/SPEC-017-network-stats-api.md:633-634`, `specs/SPEC-017-network-stats-api.md:955-963`, `specs/SPEC-017-network-stats-api.md:2121-2123`

**Finding:** The Step 4.B edge-cache test says: "Send a public request with `Authorization: Bearer garbage` followed by a public request with no Authorization; the edge cache SHOULD serve the same cached response to both." That contradicts SPEC §5.2, §5.4.3, and AC-3. Any present but invalid bearer token is a keyed request that must return `401 unauthorized`, not an anonymous public projection.

**Risk:** This would train the implementer or nginx test harness to treat malformed/invalid bearer headers as anonymous cacheable requests. Code that passes this Step 4.B test would fail AC-3 as soon as the locked invalid-token test is run.

**Fix:** Replace that subcase. Use two truly anonymous requests to verify public cache reuse, and separately assert that `Authorization: Bearer garbage` bypasses the public cache and returns `401` with the §5.9 `unauthorized` envelope. If the prompt wants to assert 401 `Vary`, keep it in Step 3, but do not call it a public projection and do not expect the same cached 200 body.

### CODE-R7-003 - HIGH - Path R2 permits a production implementation that knowingly fails either §5.6 or AC-8

**Location:** `specs/BUILD_SPEC_017_IMPL_PROMPT.md:508-517`, `specs/BUILD_SPEC_017_IMPL_PROMPT.md:529`  
**SPEC evidence:** `specs/SPEC-017-network-stats-api.md:1063-1071`, `specs/SPEC-017-network-stats-api.md:2144-2146`

**Finding:** The prompt correctly identifies that plain nginx `rate=60r/m burst=120 nodelay` does not make the 61st request return 429. But Path R2 then allows the operator to record a divergence and ship either `burst=0` (AC-8-correct, §5.6-wrong) or `burst=120` (§5.6-correct, AC-8-wrong), with the audit lane surfacing only an INFO finding.

**Risk:** The SPEC is locked and AC-8 is mandatory. A production path that knowingly violates either the normative rate-limit table or AC-8 will compile and deploy, but fail the corresponding acceptance or contract test.

**Fix:** Remove R2 as a production implementation path. Step 4.B should remain blocked until the controlling contract is reconciled, or until the prompt pins a mechanism that satisfies both locked requirements without operator waiver. The test-only no-burst harness may remain clearly labeled as non-production.

### CODE-R7-004 - MEDIUM - `partner_keys_writer` is skipped, but DB mechanics still demand its DSN and pool

**Location:** `specs/BUILD_SPEC_017_IMPL_PROMPT.md:152-164`, `specs/BUILD_SPEC_017_IMPL_PROMPT.md:256`  
**SPEC evidence:** `specs/SPEC-017-network-stats-api.md:1461-1465`, `specs/SPEC-017-network-stats-api.md:1597-1608`

**Finding:** The prompt says v0.1 must skip `partner_keys_writer`: do not create the role, do not start the worker, and leave `last_used_at` NULL. A few lines later, the DB mechanics list "one DSN per role" including `partner_keys_writer_dsn`, "one `*sql.DB` per role", and a startup smoke for each pool. That turns an omitted optional role into a possibly required startup input.

**Risk:** Two conforming implementers could diverge: one omits the writer role as directed, another makes `stats.enabled=true` fail startup when `partner_keys_writer_dsn` is absent. The latter breaks the prompt's own default-off v0.1 posture.

**Fix:** Mark `partner_keys_writer_dsn` and its pool as conditional: only configured, opened, and smoked when `stats.partner_keys.last_used_at_updates_enabled=true` or equivalent future flag is enabled. For v0.1 default-off, there is no role, no DSN, no pool, and no startup failure.

### CODE-R7-005 - MEDIUM - Partner-key CLI INSERT has no executable DB role/DSN guidance

**Location:** `specs/BUILD_SPEC_017_IMPL_PROMPT.md:477-483`  
**SPEC evidence:** `specs/SPEC-017-network-stats-api.md:895-902`

**Finding:** Step 4.A directs `coordinator partner-keys issue` to `INSERT` into `partner_keys`, but it does not tell the implementation which DSN or role the CLI uses. The runtime roles listed in Step 1 cannot do that insert: `stats_reader` has SELECT only, `stats_rollup` is explicitly denied `partner_keys`, `provider_portal` has no `partner_keys` grant, and `partner_keys_writer` is skipped and would only have column-scoped UPDATE anyway. The SPEC explicitly says the CLI runs as database superuser or a dedicated migration role outside the runtime role inventory.

**Risk:** One author may wire the CLI to an existing runtime DSN and fail AC-17 at INSERT time. Another may invent an operator DSN/config shape. The prompt leaves that mechanical integration point underspecified.

**Fix:** Add a Step 4.A DB mechanics paragraph: the CLI must use an operator/migration/superuser DSN outside the four runtime role pools, matching SPEC §5.4.1. Pin config naming and test setup enough that AC-17 can run without accidentally using `stats_reader` or `partner_keys_writer`.

### CODE-R7-006 - MEDIUM - Malformed Origin test leaves a locked §5.4.3 branch open to implementer choice

**Location:** `specs/BUILD_SPEC_017_IMPL_PROMPT.md:435`  
**SPEC evidence:** `specs/SPEC-017-network-stats-api.md:991-1004`, `specs/SPEC-017-network-stats-api.md:955-963`

**Finding:** The prompt's RFC 6454 test says malformed origins with trailing slash or query are treated as absent, then says to "fall to row 3/4/7 of §5.4.3 — pin the expected branch per your normalization rule." With the seeded active key and non-empty `allowed_origins = ARRAY['https://acme.example']`, the locked expected branch is not open-ended: malformed Origin becomes absent Origin, and absent Origin with non-empty allowlist is row 3, returning `401 unauthorized` after hash+SELECT.

**Risk:** This leaves a normative status-code expectation to the implementation author. One author could incorrectly pin a 200 partner projection for `https://acme.example/`, undermining the RFC 6454 rule.

**Fix:** Pin the test expectation: for a valid active key with non-empty allowlist, `Origin: https://acme.example/` and `Origin: https://acme.example?foo=bar` must be treated as absent and return row-3 `401 unauthorized` after the same hash+SELECT work. If the prompt wants empty-allowlist or revoked-key malformed-Origin variants, list them as separate fixtures.

### CODE-R7-007 - MEDIUM - HEAD support is required but not mechanically tested

**Location:** `specs/BUILD_SPEC_017_IMPL_PROMPT.md:294-308`, `specs/BUILD_SPEC_017_IMPL_PROMPT.md:353`, `specs/BUILD_SPEC_017_IMPL_PROMPT.md:408-460`  
**SPEC evidence:** `specs/SPEC-017-network-stats-api.md:502-504`

**Finding:** SPEC §4.3 requires `HEAD` support on every `GET`. The prompt lists only `GET` handlers and says non-GET/HEAD/OPTIONS verbs return 405, but the Step 3 test list does not include a HEAD case. In Go, HEAD is not automatically correct if the handler's method switch only accepts `GET`.

**Risk:** A fresh handler implementation could accidentally return 405 or write a body on HEAD while still satisfying every listed Step 3 AC bullet. Two authors would resolve the gap differently.

**Fix:** Add Step 3 handler and test directives for `HEAD /v1/stats/overview`, `/leaderboard`, and `/health`: status and headers match the corresponding GET success/error path, and the response body is empty.

### CODE-R7-008 - LOW - v0.1.7 launch-sequencing gate is assigned to Step 4.A in the delta list, but delivered in Step 4.C later

**Location:** `specs/BUILD_SPEC_017_IMPL_PROMPT.md:32`, `specs/BUILD_SPEC_017_IMPL_PROMPT.md:566-577`

**Finding:** The v0.1.7 delta list says "Step 4.A is hard-gated" on the §6.6.2 launch sequencing precondition. Later, the prompt correctly places the production partner-key issuance gate under Step 4.C observability/runbooks. The user-provided re-anchor note also says Step 4.C owns launch sequencing.

**Risk:** Minor scope hygiene issue. It could make a reader think CLI implementation itself is blocked by SPEC-014 v0.9, even though the later text permits staging keys and gates only production issuance.

**Fix:** Change the delta bullet to "Step 4.C is hard-gated" or "Step 4.C owns the production issuance gate; Step 4.A still implements and tests staging/CI issuance."

### CODE-R7-009 - LOW - Required-reading list is stale for the v0.1.7 re-anchor round

**Location:** `specs/BUILD_SPEC_017_IMPL_PROMPT.md:633-634`

**Finding:** Section 4 tells the implementer to read SPEC audit files "r1 through r7" and only `SPEC-017-IMPL-PROMPT-{arch,code,security}-r1-audit.md`. Earlier in the same prompt, the v0.1.7 control section correctly names SPEC r1 through r8 and per-round prompt audits. The Section 4 list is stale.

**Risk:** Minor reference hygiene. An implementer following Section 4 literally may skip the r8 v0.1.7 rationale and prompt-audit closure history beyond r1.

**Fix:** Update Section 4 to `SPEC-017-r1-audit.md` through `SPEC-017-r8-audit.md`, and reference the latest available `SPEC-017-IMPL-PROMPT-{arch,code,security}-rN-audit.md` files rather than only r1.

## Evidence Checked

- Read `specs/BUILD_SPEC_017_IMPL_PROMPT.md` fully.
- Read `specs/SPEC-017-network-stats-api.md` v0.1.7 fully, with focused checks on §3.7, §4.3, §5.1-§5.9, §6, §7.2, §7.6, §9.1, §9.1a, §9.2-§9.7, and §10 AC-1 through AC-21.
- Read `phase4-coordinator/internal/explorer/handlers.go`; the prompt's flat `internal/stats` handler package plus `store` and `rollup` subpackages does not fight the existing explorer pattern, but HEAD still needs explicit tests because the explorer method switch is GET-centric.
- Verified `phase4-coordinator/go.mod` module path is `github.com/augstar/macprovider-coordinator`; the prompt's lint-fixture guidance can use that path.
- Verified SPEC-005 v0.3 contains the AC-9 ledger tables named by the prompt: `ledger_request_credits`, `ledger_operator_credits`, `ledger_payout_ready`, and `ledger_reconciliation_runs`.
- Verified SPEC-002 v1.4 contains `provider_tokens`, matching the prompt's implementation-time source-grant and provider-identity trust checks.

## Category Walk

- **A. Section number drift:** Mostly PASS. § citations resolve to the intended v0.1.7 sections. LOW drift remains in required-reading references, which omit r8 in Section 4.
- **B. Postgres grant shape correctness:** FAIL. The listed role grants are syntactically valid, but the Step 2 rebuild SQL uses operations not executable by `stats_rollup`. The optional writer DSN/pool text also conflicts with the default-off writer posture.
- **C. Go package boundary correctness:** PASS. Request-path and rollup boundaries are consistent with SPEC §7.6 and the existing explorer pattern. No `internal/stats/handlers/` subpackage drift is present; the prompt uses flat `internal/stats/`.
- **D. Wire-contract correctness:** FAIL. Partner-key token math, CORS 204, closed error vocabulary, cache-control values, Vary rules, and v0.1.7 projection fields are largely correct. The malformed-Origin test leaves the branch ambiguous, and Step 4.B contradicts AC-3 for invalid bearer headers.
- **E. AC test-coverage mapping:** FAIL. AC-1 through AC-21 are mapped, but Step 4.B's cache test would break AC-3, Path R2 permits failing AC-8, and HEAD support lacks a mechanical test despite SPEC §4.3.
- **F. Migration / IMPL-time decision drift:** MIXED. OLTP source grants are correctly implementation-authored against line-3 dependency versions, and backfill/hostname choices are cutover-time choices. The rebuild grant/execution mismatch must be reconciled before implementation.
- **G. Test-shape correctness:** MIXED. The fixture corpus is concrete and v0.1.7 tests are mostly writable. The rebuild test cannot pass under current grants if it uses the prompt's SQL, and the invalid-Authorization cache test has the wrong expected behavior.
- **H. Idiomatic Go correctness:** MIXED. Role-scoped `*sql.DB` pools and middleware order are pinned. The prompt should make the optional writer pool conditional, pin the CLI operator DSN, and add HEAD tests.
- **I. Naming hygiene:** PASS with LOW nits. Role names, table names, error codes, and event names are consistent. The Step 4.A/4.C launch-gate label and stale audit-reading list should be corrected.

## Self-Verification

- [x] Walked every `§X.Y` citation against the SPEC.
- [x] Walked every AC-N citation against §10.
- [x] Walked every GRANT line and grant-dependent SQL path.
- [x] Walked Categories A through I.
- [x] Severity per finding chosen against definitions.
- [x] Verdict recorded.

## 200-Word Handback Summary

Round 7 does not reach the code-mechanics lock target. The v0.1.7 re-anchor is broadly present: public leaderboard totals no longer expose earnings, per-axis buckets are stripped, `meta.rewards_populated` and `partial_history_since` are included, health has seven components, CORS Max-Age is 60, partner-key projection never uses ACAO `*`, and AC-18 is a three-way timing test. I found 1 CRITICAL, 2 HIGH, 5 MEDIUM, and 2 LOW issues in the IMPL prompt itself.

The critical blocker is Step 2 rebuild SQL: the prompt says the rollup job uses `stats_rollup`, but the offered §9.4 SQL shapes require `TRUNCATE`, `ALTER`, and `DROP` authority not granted to that role. That will runtime-fail under the locked grants. High findings: Step 4.B incorrectly expects `Authorization: Bearer garbage` to behave as an anonymous public cached response, contradicting AC-3, and Path R2 allows an operator-recorded production divergence that knowingly fails either §5.6 or AC-8. Medium issues cover optional `partner_keys_writer` DSN/pool ambiguity, missing CLI operator-DSN guidance, malformed-Origin expected-branch ambiguity, and untested HEAD support. Low issues are Step 4.A/4.C launch-gate labeling and stale reading-list hygiene.

Do not draft a fix prompt yet; the next pass should first correct these prompt mechanics.
