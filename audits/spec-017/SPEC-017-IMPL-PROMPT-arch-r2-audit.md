# SPEC-017 IMPL prompt — ARCH lane audit, Round 2 (Codex, 2026-06-26T03:36:54Z)

## Summary
- 1 CRITICAL finding
- 3 HIGH findings
- 2 MEDIUM findings
- 1 LOW finding
- 2 INFO

Round 1's ARCH findings are substantially closed: mandatory one-PR sequencing, per-lane `0 CRITICAL + 0 HIGH + 0 MEDIUM` convergence, AC ownership, Step 4 sub-seams, SPEC-014 non-blocking scope, and the operator-no-exact-enable invariant are now explicit. The remaining blockers are v2-introduced or v2-exposed prompt issues, not SPEC defects.

## Category sweep
| Category | Result |
|---|---|
| A. Step decomposition correctness | HIGH finding H1 |
| B. Prerequisite coverage | CRITICAL finding C1; LOW finding L1 |
| C. Cross-step structural integrity | HIGH finding H1; MEDIUM finding M2 |
| D. PR strategy | PASS |
| E. Audit-loop discipline | PASS |
| F. SPEC-prompt fidelity | HIGH findings H2, H3; MEDIUM finding M1 |
| G. Honesty about scope | PASS, except C1 deploy-gate gap |

## CRITICAL findings

C1. Postgres role/DSN readiness is missing from deploy gates while startup is made fail-closed
   **Location:** `BUILD_SPEC_017_IMPL_PROMPT.md` lines 31-47 and 138-143; controlling SPEC §7.2.5 lines 1342-1350 and AC-9 lines 1788-1794.
   **Finding:** The pre-flight section lists DNS, Cloudflare, and nginx as operator-side deploy gates, but omits the operational gate for provisioning the Postgres stats roles, role passwords, DSNs, migrations, and secret/config delivery. Later, Step 1 tells the author to add one DSN per role and a startup smoke that connects with each role and fails deny-list queries. A fresh implementation could therefore merge a coordinator startup path that hard-requires unset `stats_reader_dsn` / `stats_rollup_dsn` / `provider_portal_dsn` / `partner_keys_writer_dsn` credentials before the operator has any named deploy prerequisite to satisfy.
   **Why it matters:** This is a prerequisite coverage bug that can brick the coordinator deploy even though the locked SPEC is implementable. The SPEC requires distinct role pools; the prompt must tell the IMPL author how to introduce that fail-closed behavior without making intermediate step deploys fail from missing operator secrets.
   **Suggested fix:** Add a hard production-deploy gate before nginx/public cutover: Postgres migrations applied, required roles created, role passwords/DSNs installed in coordinator config/secrets, and startup smoke verified in staging. Also state the Step 1 merge strategy explicitly: either gate stats pool startup behind a disabled-by-default `stats.enabled`/equivalent until the operator config is present, or require those DSNs to be present before deploying the Step 1 PR. The prompt should not leave this to author inference.

## HIGH findings

H1. Step 2 still tests and describes handler response behavior before the handler step exists
   **Location:** `BUILD_SPEC_017_IMPL_PROMPT.md` lines 179-204; AC matrix lines 435-457; controlling SPEC §9.7 lines 1728-1753.
   **Finding:** Step 2 says the rollup step implements Path A with `partial_history_since` "field set on `30d`/`all` responses" and its tests assert that `/v1/stats/leaderboard?window=30d` returns or omits that field. But Step 2 is the rollup-pipeline PR; Step 3 owns HTTP handlers and the AC matrix assigns leaderboard response tests to Step 3. This leaks wire-response behavior across the Step 2/Step 3 boundary.
   **Why it matters:** One-PR-per-step only works if Step 2 can go green without landing Step 3 handlers or faking them in a way that later diverges. The current wording pressures the Step 2 author either to add handler code early or to write a pseudo-handler test that loses the audit-lane benefit.
   **Suggested fix:** Keep Step 2 responsible for rollup/backfill state only: config parsing, full vs partial backfill execution, persisted rollup-start metadata or equivalent source needed by the handler, and deterministic table contents. Move the `/v1/stats/leaderboard` `partial_history_since` response assertion to Step 3, with a Step 2 fixture feeding both Path A and Path B cases.

H2. Middleware ordering is internally contradictory for panic recovery and redaction
   **Location:** `BUILD_SPEC_017_IMPL_PROMPT.md` lines 266-280; controlling SPEC §7.3 lines 1352-1357, AC-11 lines 1799-1801, and AC-15 lines 1812-1814.
   **Finding:** The process-isolation section says the recover middleware wraps the stats subtree as the OUTERMOST middleware before logging and tracing. The next section says the request-scoped redaction layer MUST run BEFORE the recover middleware, BEFORE access logging, and BEFORE tracing. Both orderings cannot be true at the same time.
   **Why it matters:** Recover/redaction ordering is not cosmetic: AC-11 requires panic containment and AC-15 requires no raw `Authorization` value in logs. Two conforming IMPL authors could choose opposite middleware stacks, and the "recover outermost" reading can log panic context before the redaction layer has sanitized it.
   **Suggested fix:** Pin one stack. For example: redaction/sanitization wrapper outermost, then recover middleware that reads only sanitized request context, then logging/tracing, then handlers. If the implementation needs recover to be outermost for process safety, then require recover to perform its own first-line `Authorization` stripping before any log/trace emission and remove the conflicting "redaction before recover" sentence.

H3. The prompt allows token prefix in metric labels despite the SPEC/AC label boundary
   **Location:** `BUILD_SPEC_017_IMPL_PROMPT.md` lines 274-280 and 403-426; controlling SPEC §3.7 lines 361-365, §5.4.6 lines 854-860, and AC-15 lines 1812-1814.
   **Finding:** Step 3 says allowed "log/metric labels" may include `partner_keys.id`, `partner_keys.label`, and optionally the 8-character `prefix`. Step 4 later says metric labels must contain no prefix. The locked SPEC allows `prefix` in logs for correlation, but AC-15 names only `partner_keys.id` and `partner_keys.label`, and the metric contract in the prompt itself pins `stats_partner_key_request_total{partner_key_id}` only.
   **Why it matters:** This is SPEC-prompt fidelity drift on a token-derived value. A fresh author could add `prefix` as a Prometheus label, creating unnecessary cardinality and leaking part of the bearer-token-derived identifier into monitoring despite the stricter metric-label boundary.
   **Suggested fix:** Rewrite the redaction bullet to split logs from metrics: metric labels may use only integer `partner_keys.id` and low-cardinality non-secret dimensions; no prefix, label text, token hash, raw token, or origin string. If the operator wants prefix for manual CLI/list output or tightly controlled logs, scope that separately and do not describe it as a metric label.

## MEDIUM findings

M1. CORS preflight prose can be read as downgrading a keyed disallowed-origin GET to public
   **Location:** `BUILD_SPEC_017_IMPL_PROMPT.md` lines 222-243; controlling SPEC §5.4.3 lines 794-802 and §5.7 lines 912-932.
   **Finding:** The 7-row decision table is correct, but the preflight paragraph says a non-allowlisted Origin gets `*` "AND the public projection on subsequent GET per the §5.4.3 row 1 default." Row 1 applies only when `Authorization` is absent. For a keyed GET with a non-empty allowlist and non-matching Origin, the locked table requires 401.
   **Why it matters:** Two implementers could resolve this differently: one follows the table, another treats disallowed browser GETs as anonymous public projection. The latter would violate the explicit auth decision table and produce inconsistent partner behavior.
   **Suggested fix:** Change the sentence to: "For preflight, a non-allowlisted Origin gets `*`; the subsequent GET is then evaluated by §5.4.3 exactly. If that GET has no Authorization, it receives the public projection; if it has a key with a non-empty allowlist and the Origin is not allowed, it returns 401."

M2. `stats_components_health` first-failure bootstrap is underspecified
   **Location:** `BUILD_SPEC_017_IMPL_PROMPT.md` lines 110 and 177-200; controlling SPEC §9.1 lines 1552-1561 and §9.6 lines 1712-1726.
   **Finding:** The prompt correctly says `stats_components_health` has no `status` column and has NOT NULL `generated_at` / `last_ok_at`. It then says each job UPSERTs `generated_at` + `last_ok_at` on success, OR `last_error_at` + `last_error_message` on failure. It does not say how the first failure before any success creates a valid row with the NOT NULL fields populated.
   **Why it matters:** This is a non-trivial structural ambiguity in the rollup/health seam. One implementation may fail to record first-run failures; another may invent sentinel timestamps; a third may pre-seed component rows. All can pass different subsets of Step 2/3 tests unless the prompt pins the bootstrap expectation.
   **Suggested fix:** Add a Step 2 bootstrap rule: migrations or scheduler startup pre-seed the six component rows with a defined initial `generated_at` / `last_ok_at`, or first-failure handling writes explicit safe values accepted by the health derivation. Then add a test for "first tick fails before any success" and assert `/v1/stats/health` derives the expected component status without violating NOT NULL constraints.

## LOW findings

L1. The pre-flight count text is internally inconsistent
   **Location:** `BUILD_SPEC_017_IMPL_PROMPT.md` lines 31-47.
   **Finding:** The prompt says there are "two operator-action items" and "four HARD prereqs before production cutover," but the visible structure has two confirmation items, two verify-before-kickoff items, and three numbered deploy gates. This is likely residue from the v2 rewrite.
   **Why it matters:** It does not change implementation behavior, but it makes a load-bearing checklist harder to audit.
   **Suggested fix:** Rename/count the buckets explicitly after C1's Postgres deploy gate is added.

## INFO

I1. Round-1 ARCH C1/H1/H2/H3/H4/H5/M1/M2/M3 are closed in substance. The v2 prompt now forbids operator exact-enable, mandates one PR per step, distinguishes handler vs rollup import boundaries, owns ACs in a matrix, makes SPEC-014/UI non-blocking, pins the audit target at 0/0/0 for CRITICAL/HIGH/MEDIUM, and splits Step 4 internally.

I2. The §6 deferral list includes §11 Q1 through Q13. I found no missing v0.2 question in `BUILD_SPEC_017_IMPL_PROMPT.md` lines 501-518.

## Operator questions

q1. None requiring a SPEC design decision. All findings are IMPL-prompt rewrite issues against the locked SPEC-017 v0.1.6 contract.

## Verdict

- READY WITH FIX PASS

The IMPL prompt should not lock at round 2. The fix pass can stay entirely in the kickoff prompt: add the Postgres deploy/boot gate, move handler-response assertions out of Step 2, and remove the contradictory redaction/middleware/token-label wording. No additional SPEC design round is needed.

## Self-verification
- [x] Read `BUILD_SPEC_017_IMPL_PROMPT.md` fully.
- [x] Read `SPEC-017-network-stats-api.md` fully.
- [x] Read `BUILD_SPEC_016_PAYOUT_IMPL_PROMPT.md` and compared process/step/audit structure.
- [x] Read `SPEC-017-advisor-round-2026-06-25.md`.
- [x] Skimmed `SPEC-017-r2-audit.md` through `SPEC-017-r7-audit.md` for why the locked MUSTs exist, and compared round-1 ARCH prompt audit closure.
- [x] Walked each Category A through G.
- [x] Severity for each finding chosen against the prompt's definitions.
- [x] Location line range included on every finding.
- [x] Suggested fix included for every CRITICAL and HIGH finding.
- [x] Verdict included.
