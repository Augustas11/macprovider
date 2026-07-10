# AUDIT_SPEC_017_IMPL_PROMPT — Code lane

Operator-paste prompt to audit `BUILD_SPEC_017_IMPL_PROMPT.md` from the code-mechanics lens.

Severity model: CRITICAL / HIGH / MEDIUM / LOW / INFO. Lock target: 0 CRITICAL + 0 HIGH + 0 MEDIUM.

Each round writes a fresh file: `specs/SPEC-017-IMPL-PROMPT-code-rN-audit.md`.

---

```
=== BEGIN PROMPT ===

You are auditing the IMPL kickoff prompt
/Users/augstar/macprovider-spec-017/specs/BUILD_SPEC_017_IMPL_PROMPT.md
from the CODE-MECHANICS lens.

Your audit target is the IMPL prompt itself, NOT the SPEC. The SPEC
(`specs/SPEC-017-network-stats-api.md` v0.1.6) is LOCKED. Your job is
to find concrete code-mechanics errors in the IMPL prompt — wrong file
paths, wrong package boundaries, wrong AC references, wrong table or
column names, wrong RFC citations, wrong Go-idiom guidance, wrong
SQL grant shape, wrong CLI surface, wrong test-coverage mapping.

Output: /Users/augstar/macprovider-spec-017/specs/SPEC-017-IMPL-PROMPT-code-r1-audit.md
(round N writes SPEC-017-IMPL-PROMPT-code-rN-audit.md; new file each round.)

Severity:
- **CRITICAL** — would cause IMPL author to ship runtime-broken
  code that even one test would catch (wrong table name, wrong
  HTTP status, wrong field type, wrong base64url length, wrong
  SQL grant shape that fails to execute).
- **HIGH** — would cause IMPL author to write code that compiles
  and runs but fails an AC test once the test is written (wrong
  AC reference, wrong cache-control directive, wrong CORS header).
- **MEDIUM** — ambiguity in the IMPL prompt that two conforming
  authors would resolve differently in code (which package owns
  the rate-limit bucket, which connection pool gets which role).
- **LOW** — minor reference / citation / naming hygiene.
- **INFO** — observations.

## Critical constraints to honor while auditing

1. The SPEC is LOCKED. Any finding that would require a SPEC change
   is HIGH or CRITICAL.
2. The IMPL prompt cites SPEC sections by number (§5.1, §7.2.2,
   §9.1, etc.). Verify each citation resolves to the right section
   in the current SPEC file. Drift in section numbers since the
   SPEC went through 7 audit rounds is plausible.
3. The IMPL prompt cites Postgres grant shapes (GRANT ... ON ...
   TO ...). Verify each grant is syntactically valid PostgreSQL
   and semantically matches the SPEC's role table.
4. The IMPL prompt cites Go package paths
   (`internal/stats/`, `internal/stats/rollup/`,
   `internal/stats/handlers/`). Verify these are consistent with
   the existing `phase4-coordinator/internal/explorer/` pattern.
5. The IMPL prompt cites AC numbers (AC-1 through AC-21). Verify
   each AC reference matches the AC content in the SPEC.

## Required reading

1. `/Users/augstar/macprovider-spec-017/specs/BUILD_SPEC_017_IMPL_PROMPT.md`
   — the document under audit. Read fully.
2. `/Users/augstar/macprovider-spec-017/specs/SPEC-017-network-stats-api.md`
   v0.1.6 LOCKED — the controlling contract. Read fully, focus on
   §3.7 partner-key format, §4 mount paths, §5 endpoints, §6
   visibility, §7.2 grants, §9.1 table schemas, §10 ACs.
3. `/Users/augstar/macprovider-spec-017/phase4-coordinator/internal/explorer/handlers.go`
   — existing handler pattern. Verify the IMPL prompt's directives
   don't fight against this pattern.

## Code-mechanics audit categories

### A. Section number drift
A.1  Every §X.Y citation in the IMPL prompt resolves to the right
     section in SPEC-017 v0.1.6. Walk each one; mismatches = HIGH.
A.2  Every AC-N reference in the IMPL prompt's Tests bullets
     matches an AC in §10 of the SPEC. Mismatches = HIGH.

### B. Postgres grant shape correctness
B.1  Every GRANT line cited in the IMPL prompt:
     - Names a table that exists in SPEC §9.1 / §6.1 / §6.5 /
       §5.4.1 / §9.1a.
     - Uses a valid grant kind (SELECT / INSERT / UPDATE / DELETE /
       USAGE / column-scoped UPDATE).
     - Names a role that the IMPL prompt previously creates.
     - Uses syntactically valid PostgreSQL (e.g. `GRANT USAGE,
       SELECT ON SEQUENCE foo_seq TO role;` not
       `GRANT USAGE ON SEQUENCE foo_seq TO role;` if SELECT is
       needed).
B.2  Every backing-sequence grant (USAGE on `*_id_seq`) matches a
     BIGSERIAL column in the corresponding table.
B.3  Connection-pool isolation: each role gets its own `*sql.DB`.
     Verify the IMPL prompt doesn't accidentally permit two roles
     to share a pool.

### C. Go package boundary correctness
C.1  `internal/stats/` MUST NOT import `internal/billing/`,
     `internal/explorer/`, `internal/ws/`, or `internal/auth/`
     beyond a minimal Bearer parser (§7.6). Verify the IMPL prompt's
     directives are consistent with this boundary.
C.2  `internal/stats/rollup/` MAY import billing/session/pool
     read-only. Verify the IMPL prompt doesn't accidentally extend
     this to write paths.
C.3  `internal/stats/handlers/` ONLY uses the `stats_reader` role.
     Verify the IMPL prompt's handler directives are consistent.
C.4  Package-path naming: SPEC-017 vs SPEC-016 used different
     conventions. Pick one and verify the IMPL prompt is consistent.

### D. Wire-contract correctness
D.1  Partner-key format: §3.7 says `mpk_` + 43-char unpadded
     base64url = 47 chars total. AC-17 verifies the same. Verify
     the IMPL prompt §2 step 4 CLI directive produces exactly
     47-char tokens (32 bytes random → unpadded base64url
     length should be `4 * ceil(32 / 3) = ceil(128/3) = 43`).
D.2  CORS preflight per §5.7: returns 204 only (NOT 200). Verify
     the IMPL prompt doesn't permit the 200 escape hatch.
D.3  Error envelope per §5.9 closed vocabulary: `bad_request`,
     `unauthorized`, `method_not_allowed`, `rate_limited`,
     `stats_stale`, `internal`. Verify the IMPL prompt doesn't
     introduce a new code anywhere.
D.4  Status codes: every status code cited in the IMPL prompt
     matches §5.9 or another normative SPEC section.
D.5  Cache directives: `s-maxage=30/60/10` per §5.1/§5.2/§5.3.
     Verify the IMPL prompt nginx config and test directives
     match these values.
D.6  Header names: `X-Stats-Generated-At` on every `/v1/stats/*`
     response. Verify the IMPL prompt's directives don't permit
     omission on `/leaderboard` or `/health`.

### E. AC test-coverage mapping
E.1  Walk AC-1 through AC-21. For each, identify which step's
     Tests section is supposed to cover it. Gaps = HIGH.
E.2  AC-8 rate-limit (60th vs 61st request) — verify the IMPL
     prompt's nginx-tier vs in-process-tier directives are
     consistent.
E.3  AC-9 stats_reader permission-denied — verify the IMPL prompt
     directs the test against a real locked SPEC-005 v0.3 ledger
     table.
E.4  AC-11 panic recovery — verify the IMPL prompt's recover
     middleware directive is consistent with §7.3.
E.5  AC-12 304 round-trip — verify the IMPL prompt directs ETag =
     weak `sha256(body)` computed once per snapshot.
E.6  AC-15 log redaction — verify the IMPL prompt prohibits the
     raw token from EVERY surface (logs, metrics, response,
     transcript).
E.7  AC-16 import-graph lint — verify the IMPL prompt directs CI
     enforcement, not just a one-time check.
E.8  AC-17 partner-key CLI — verify the IMPL prompt's CLI
     directives produce a token that satisfies the AC-17 length /
     prefix / regex assertions.
E.9  AC-18 timing-attack — verify the IMPL prompt directs the
     statistical-test variant, not just a one-shot latency probe.
E.10 AC-19 visibility default — verify the IMPL prompt directs
     the left-join-with-default-bucketed semantics.
E.11 AC-20 operator-exact constraint — verify the IMPL prompt
     directs a CI SQL fixture-and-assertion test.
E.12 AC-21 405 envelope — verify the IMPL prompt step 3 directives
     include the §5.9 error envelope + `Allow` header.

### F. Migration / IMPL-time decision drift
F.1  §7.2.2 (rollup OLTP source grants) is normatively
     implementation-authored. Verify the IMPL prompt directs the
     author to enumerate against the locked SPEC-002 v1.4 + SPEC-005
     v0.3 line-3 versions at IMPL TIME, not against the line-3 at
     SPEC-017 write time.
F.2  Backfill posture (§9.7) is operator-decided between Path A
     and Path B. Verify the IMPL prompt §1 prereq 2 unambiguously
     gates step 2 rollup code on the decision.
F.3  Hostname pattern (§7.1) is operator-decided. Verify the IMPL
     prompt §1 prereq 1 unambiguously gates step 4 nginx config on
     the decision.

### G. Test-shape correctness
G.1  Integration tests cited in Steps 1-4 — verify each is
     mechanically writable against the SPEC's normative contract.
     Hand-wavy "test the surface" = HIGH.
G.2  Fixture corpus for rollup tests — is it specified anywhere?
     If not, MEDIUM finding.
G.3  Smoke tests cited in step 4 — verify each is achievable
     against a staging Pearl-equivalent VPS.

### H. Idiomatic Go correctness
H.1  The IMPL prompt directs use of `*sql.DB` per role. Verify
     this matches the existing `phase4-coordinator/` patterns
     (driver, connection-pool config, etc.).
H.2  Recover middleware: does the IMPL prompt direct a specific
     middleware shape, or leave it open? If open, MEDIUM.
H.3  Background channel for `partner_keys.last_used_at` updates:
     does the IMPL prompt direct a specific concurrency primitive
     (buffered channel, NATS subject, etc.)?

### I. Naming hygiene
I.1  Role names: `stats_reader`, `stats_rollup`, `provider_portal`,
     `partner_keys_writer`. Consistent across the IMPL prompt?
I.2  Table names: consistent with §9.1 / §9.1a / §6.1 / §6.5 /
     §5.4.1?
I.3  Event names cited in step 4 observability: `stats_request_served`,
     `stats_rollup_tick_completed`, etc. — verify these don't
     collide with existing event names in
     `phase4-coordinator/internal/explorer/handlers.go` (which uses
     `event=internal_bearer_accepted` etc.).

## Output format

Same shape as ARCH lane: per-finding location, severity, fix.

## Self-verification before declaring complete

- [ ] Walked every §X.Y citation against the SPEC.
- [ ] Walked every AC-N citation against §10.
- [ ] Walked every GRANT line.
- [ ] Walked Categories A through I.
- [ ] Severity per finding chosen against definitions.
- [ ] Verdict.

Print a 200-word handback summary. Do NOT begin drafting a fix
prompt.

=== END PROMPT ===
```
