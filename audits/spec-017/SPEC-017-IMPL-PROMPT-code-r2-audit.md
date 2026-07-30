# SPEC-017 IMPL Prompt CODE-MECHANICS Audit - Round 2

Audit target: `specs/BUILD_SPEC_017_IMPL_PROMPT.md`  
Controlling contract: `specs/SPEC-017-network-stats-api.md` v0.1.6 LOCKED  
Lens: code mechanics only. The SPEC is not under audit.

## Verdict

**NOT READY for IMPL kickoff.**

Counts: **1 CRITICAL, 4 HIGH, 2 MEDIUM, 0 LOW, 2 INFO**.

Round 2 closes the round-1 CODE findings called out by the operator: `stats_components_health.status` is no longer directed as a column, `partner_keys.created_by` is wired into the CLI, rotation uses `issue --rotate-from`, the partner-key decision table is seven rows, the role list no longer uses `stats_*` shorthand for `stats_reader`, and the AC-to-step matrix exists. The remaining defects are narrower but still implementation-blocking: one optional grant path is not mechanically executable as described, one health test seeds the wrong table, CORS preflight wording reverses the allowlist behavior, AC-10 is still not backed by a concrete Step 1 test, and nginx / middleware directives contain implementation-shaping ambiguities.

## Findings

### CODE-R2-001 - `partner_keys_writer` cannot perform the intended row-targeted update with the prompt's grant/test shape

Location: `specs/BUILD_SPEC_017_IMPL_PROMPT.md:132-133`, `:149`, `:181`; controlling SPEC: `specs/SPEC-017-network-stats-api.md:1325-1335`  
Severity: **CRITICAL**  
Category: Postgres grant shape correctness

The prompt correctly repeats the locked SPEC grant as column-scoped `UPDATE (last_used_at) ON partner_keys`, and then directs a worker consuming `(partner_keys.id, observed_at)` pairs to update `last_used_at`. A real row-targeted PostgreSQL update such as:

```sql
UPDATE partner_keys SET last_used_at = $1 WHERE id = $2;
```

requires reading `id` in the `WHERE` condition. The prompt's Step 1 test only says "`UPDATE on partner_keys.last_used_at` succeeds", which can be satisfied by a non-targeted update and will not catch the runtime permission failure of the actual worker shape.

Fix: Make the prompt require a realistic integration test that runs the actual worker SQL under `partner_keys_writer`, including `WHERE id = ...`. If that fails under the locked grants, the prompt must surface the SPEC conflict before implementation rather than letting the worker be written against an unexecutable permission set.

### CODE-R2-002 - Health SLA test seeds `stats_overview_current` instead of `stats_components_health`

Location: `specs/BUILD_SPEC_017_IMPL_PROMPT.md:177`, `:200`, `:220`; controlling SPEC: `specs/SPEC-017-network-stats-api.md:660-696`, `:1552-1560`  
Severity: **HIGH**  
Category: table / column mapping, test-shape correctness

The prompt says `/v1/stats/health` derives status from `stats_components_health` rows, which matches SPEC §5.3 and §9.1. But the Step 2 health test tells the author to freeze `stats_overview_current.generated_at` at `now - 130s` and then expect `/v1/stats/health` to return `"down"`.

That test targets the overview endpoint's stale source, not the health component table. A conforming health handler that reads `stats_components_health.generated_at` will not necessarily change status when only `stats_overview_current.generated_at` is aged.

Fix: Rewrite the Step 2 test to age the `stats_components_health` row for `component = 'overview'` (and, if needed, `leaderboard_24h`) beyond the §5.8 budget, then assert `/v1/stats/health` derives `"down"` from that row. Keep `stats_overview_current.generated_at > 120s` for the AC-14 `/overview` 503 test only.

### CODE-R2-003 - CORS preflight wording reverses the global allowlist behavior

Location: `specs/BUILD_SPEC_017_IMPL_PROMPT.md:243`; controlling SPEC: `specs/SPEC-017-network-stats-api.md:918-927`  
Severity: **HIGH**  
Category: wire-contract correctness

The SPEC says preflight must echo `Origin` and emit `Access-Control-Allow-Credentials: true` when the `Origin` matches the global partner-origin allowlist; otherwise it emits `*`. The IMPL prompt says "`Allow-Origin` echoed per the §5.7 table ... (or `*` if Origin is on the global partner allowlist union; non-allowlisted Origin gets `*` ...)", which makes the allowlisted case read as `*`.

Following that wording would break credentialed browser preflight for allowlisted partner origins and drift from SPEC §5.7.

Fix: Replace the parenthetical with the exact SPEC rule: allowlisted global origins echo `Origin` and include `Access-Control-Allow-Credentials: true`; non-allowlisted origins emit `*`.

### CODE-R2-004 - AC-10 remains unmapped to a concrete Step 1 test

Location: `specs/BUILD_SPEC_017_IMPL_PROMPT.md:145-154`, `:316-323`, `:431-455`; controlling SPEC: `specs/SPEC-017-network-stats-api.md:1795-1798`  
Severity: **HIGH**  
Category: AC test-coverage mapping

The new matrix assigns AC-10 to Step 1 as "SQL fixture + transaction test", and Step 3 explicitly disclaims ownership. But the Step 1 test list never describes that transaction test. It only verifies `provider_portal` can insert into `provider_visibility_audit`.

AC-10 is more specific: toggling `provider_visibility.mode` via the portal candidate handler must UPSERT the visibility row and insert exactly one audit row with `actor_kind = 'provider'` transactionally. The prompt still allows an implementation to ship Step 1 without testing the UPSERT + audit-row atomicity or old/new-mode behavior.

Fix: Add a Step 1 test bullet that performs the visibility toggle transaction against `provider_visibility` and `provider_visibility_audit` using the intended role/surface, asserts exactly one audit row, asserts `actor_kind = 'provider'`, and asserts rollback leaves neither side half-written.

### CODE-R2-005 - nginx `nodelay` is attached to the wrong directive

Location: `specs/BUILD_SPEC_017_IMPL_PROMPT.md:375`, `:386-389`  
Severity: **HIGH**  
Category: CLI / config surface correctness

The prompt lists "`limit_req_zone` per endpoint with `nodelay`". In nginx, `nodelay` belongs on the `limit_req` directive that applies a zone, not on `limit_req_zone` itself. The later tests correctly care about prompt rejection rather than queueing, but the directive bullet can lead an implementer to write a config that fails `nginx -t` or misplaces the burst behavior.

Fix: Split the directive requirement: define one `limit_req_zone` per endpoint, then apply each zone with `limit_req zone=<name> burst=<n> nodelay;` and `limit_req_status 429`.

### CODE-R2-006 - Recover middleware and redaction middleware ordering contradict each other

Location: `specs/BUILD_SPEC_017_IMPL_PROMPT.md:266-276`  
Severity: **MEDIUM**  
Category: Go middleware shape, log-redaction mechanics

The recover contract says it wraps the entire `/v1/stats/*` subtree as the outermost middleware before logging and tracing. The redaction contract then says the redaction layer must run before the recover middleware, before access logging, and before tracing. Both cannot be outer/before the other in a single ordinary Go middleware chain.

Two conforming authors could choose different orders. One may satisfy "recover outermost"; another may satisfy "redaction before recover". The choice matters because panic logging must not leak `Authorization` or token material.

Fix: Define the exact chain in one place, for example: redaction context extraction first at the entrypoint, then recover uses only the redacted context, then logging/tracing, then handler. Alternatively state that recover is outermost but must call the same redaction helper before any panic log emission.

### CODE-R2-007 - Prompt both permits and forbids partner-key `prefix` in metric labels

Location: `specs/BUILD_SPEC_017_IMPL_PROMPT.md:274-280`, `:403-426`; controlling SPEC: `specs/SPEC-017-network-stats-api.md:340-365`, `:854-861`  
Severity: **MEDIUM**  
Category: log / metric label hygiene

The central redaction section allows log/metric labels to reference the 8-character `prefix`. The Step 4 metrics section later says `stats_partner_key_request_total` has integer `partner_key_id` only, and the metric-label hygiene test asserts no metric label contains `prefix`.

That contradiction matters because `prefix` includes `mpk_` plus four characters from the random token body. The SPEC permits prefix in logs for correlation, but the prompt's metrics section correctly avoids it as a metric label.

Fix: Narrow the earlier allowance to logs only. Metric labels should remain integer IDs / bounded enums only, with no prefix, token hash, raw token, origin string, or operator-provided label text.

## Positive Checks

- Round-1 CODE-R1-002 is closed: the prompt no longer tells authors to create or assert `stats_components_health.status`.
- Round-1 CODE-R1-003 and CODE-R1-008 are closed: `created_by` is explicit and rotation uses `coordinator partner-keys issue --rotate-from`.
- Round-1 CODE-R1-004, CODE-R1-005, CODE-R1-007, CODE-R1-009, and CODE-R1-010 are materially improved: `stats_reader` grants are enumerated, handlers live in flat `internal/stats`, the auth table is seven rows, `internal/auth` is in the lint boundary, and an AC matrix exists.
- Partner-key length math remains correct: 32 random bytes encode to 43 unpadded base64url characters, plus `mpk_` = 47 total.
- Error vocabulary, 405 envelope, CORS 204 status, cache header values, and `X-Stats-Generated-At` directives match the locked SPEC at the top-level contract.

## Self-Verification

- [x] Walked every `§X.Y` citation in the IMPL prompt against SPEC-017 v0.1.6.
- [x] Walked every `AC-N` citation in the IMPL prompt against SPEC §10.
- [x] Walked every grant summary / role directive in the IMPL prompt against SPEC §7.2 and §9.1 / §9.1a / §6.1 / §6.5 / §5.4.1.
- [x] Walked Categories A through I from the audit prompt.
- [x] Severity chosen against the provided definitions.
- [x] Verdict provided.

## 200-Word Handback Summary

Round 2 is much tighter than round 1, but it is not ready for kickoff. The named round-1 CODE fixes are mostly closed: the nonexistent `stats_components_health.status` column is gone, `created_by` is in the CLI, rotation uses `issue --rotate-from`, the partner-key table has seven rows, the handler package path matches the flat explorer pattern, and the AC matrix exists.

The remaining issues are narrower and more mechanical. The biggest blocker is `partner_keys_writer`: the prompt directs a worker to update a row by `partner_keys.id`, but the locked grant is only column-scoped `UPDATE(last_used_at)`. A realistic `WHERE id = ...` update is not covered by the prompt's test and is likely to fail under PostgreSQL privileges. Step 2 also seeds the wrong table for health-status derivation: `/health` reads `stats_components_health`, not `stats_overview_current`.

CORS preflight wording reverses the allowlisted-Origin behavior, AC-10 is assigned to Step 1 without a concrete UPSERT-plus-audit transaction test, and the nginx `nodelay` directive is attached to the wrong nginx directive. Two medium issues remain in middleware and metric-label wording: recover/redaction ordering conflicts, and `prefix` is both allowed and forbidden in metric labels. Fix these before implementation kickoff. Each should be resolved in the kickoff prompt before any implementation branch starts for safety.
