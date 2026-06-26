# SPEC-017 IMPL Prompt Code-Mechanics Audit — Round 3

**Target:** `specs/BUILD_SPEC_017_IMPL_PROMPT.md`  
**Lens:** CODE-MECHANICS  
**Controlling contract:** `specs/SPEC-017-network-stats-api.md` v0.1.6 LOCKED  
**Required pattern check:** `phase4-coordinator/internal/explorer/handlers.go`

## Verdict

**NOT READY:** 0 CRITICAL, 4 HIGH, 1 MEDIUM, 1 LOW.

The r3 prompt closes the known r2 code-mechanics issues around partner-key
token length, `partner_keys_writer` `SELECT(id)`, CORS 204, AC-10 storage
fixture, nginx `nodelay` placement, middleware ordering, and metric/log
allowance split. Remaining issues are narrower but still implementation-facing:
two AC tests would fail for the wrong surface, one disabled-mode branch invents
a non-SPEC response shape, and one nginx directive/test pairing is mechanically
inconsistent with AC-8.

## Findings

### CODE-R3-001 — `partner-keys issue --label X` no longer satisfies AC-17

**Severity:** HIGH  
**Category:** D.1, E.8, G.1  
**Location:** `BUILD_SPEC_017_IMPL_PROMPT.md` lines 364-392; `SPEC-017-network-stats-api.md` lines 770-783 and 1820-1826

The IMPL prompt makes `--created-by <text>` required for
`coordinator partner-keys issue`, and its AC-17 test runs:

```bash
coordinator partner-keys issue --label X --created-by ops@example.com
```

The locked SPEC's issuance example and AC-17 command are:

```bash
coordinator partner-keys issue --label X
```

An implementer following the prompt would ship a CLI where the exact AC-17
command can fail argument validation before token generation. The prompt's test
would still pass because it tests a stricter, prompt-only CLI surface rather
than the locked AC surface.

**Fix:** Preserve the SPEC command as a passing path. Make `--created-by`
optional with a deterministic non-empty default from the operator principal or
current OS user, or define a fallback that populates `created_by` when the flag
is omitted. The Step 4.A AC-17 test must execute exactly
`coordinator partner-keys issue --label X` and assert the inserted row has
non-empty `created_by`; a second explicit-flag test may remain additive.

### CODE-R3-002 — Disabled stats subtree invents a non-SPEC 503 body/code

**Severity:** HIGH  
**Category:** D.3, D.4  
**Location:** `BUILD_SPEC_017_IMPL_PROMPT.md` line 45; `SPEC-017-network-stats-api.md` lines 946-983

The prompt says that when `stats.enabled = false`, the stats subtree mounts as:

```json
{"status":"down","reason":"stats_disabled"}
```

The locked SPEC says all non-2xx responses except 304 use the §5.9 error
envelope, and the closed v0.1 code vocabulary is:

```text
bad_request, unauthorized, method_not_allowed, rate_limited, stats_stale, internal
```

`stats_disabled` is not in the vocabulary, and the stub body is not the §5.9
envelope. Because this branch is explicitly under the `/v1/stats/*` subtree, an
implementation author can ship a runtime response shape that violates the
public wire contract.

**Fix:** Remove the `/v1/stats/*` disabled stub from the partner-facing
contract path. If `stats.enabled=false` is a local deploy safety mode, keep the
nginx/public route disabled and do not expose `/v1/stats/*`. If a request can
reach a mounted `/v1/stats/*` path, it must use the locked §5.9 envelope and
closed code set; do not introduce `stats_disabled` without a SPEC revision.

### CODE-R3-003 — AC-16 lint smoke can fail for compiler errors instead of the import/process-exit lint

**Severity:** HIGH  
**Category:** C.1, E.7, G.1, H.1  
**Location:** `BUILD_SPEC_017_IMPL_PROMPT.md` lines 153-154; `phase4-coordinator/go.mod` line 1; `phase4-coordinator/internal/explorer/handlers.go` lines 20-22

The AC-16 lint fixture in the prompt uses:

```go
import "phase4-coordinator/internal/billing"
```

The actual Go module path is:

```text
github.com/augstar/macprovider-coordinator
```

Existing code imports internal packages as
`github.com/augstar/macprovider-coordinator/internal/...`. The prompt's fixture
can fail `make lint` because the import path is unresolved, not because the
import-graph rule catches a forbidden dependency. The next bullet has the same
test-shape problem:

```go
os.Exit("test")
```

`os.Exit` takes an `int`, so this can fail typechecking before proving the
process-termination lint rule exists.

**Fix:** Use compilable fixtures that can only fail for the intended lint
diagnostic:

```go
import "github.com/augstar/macprovider-coordinator/internal/billing"
```

and:

```go
os.Exit(1)
```

Require the test to assert the lint diagnostic/rule name, not just a non-zero
`make lint` exit. Repeat with the real auth module path and the named Bearer
parser allowlist.

### CODE-R3-004 — Nginx `burst=<n> nodelay` does not mechanically prove AC-8's 61st-request rejection

**Severity:** HIGH  
**Category:** D.4, E.2, G.3  
**Location:** `BUILD_SPEC_017_IMPL_PROMPT.md` lines 400-415; `SPEC-017-network-stats-api.md` lines 883-889 and 1785-1787

The prompt requires:

```nginx
limit_req zone=<name> burst=<n> nodelay;
```

and then requires AC-8 to prove that 60 requests within 60 seconds succeed and
the 61st returns 429. In nginx, a positive `burst` allows excess requests above
the steady rate; `nodelay` sends those burst requests immediately instead of
delaying them. If the author maps the SPEC's public burst value (`120`) into
`burst=<n>`, the 61st request can be accepted instead of rejected, so the
directive shape and the AC-8 smoke are mechanically inconsistent.

**Fix:** The prompt must explicitly reconcile the locked AC with nginx
semantics before implementation. If AC-8 is controlling, require the public
`/v1/stats/overview` AC surface to omit `burst` or use an effective zero-burst
configuration so the 61st request is rejected. If the public burst of 120 is
intended to be honored, the AC test threshold must move beyond the burst, but
that requires a SPEC revision because AC-8 is locked.

### CODE-R3-005 — "goroutine-local handle" is not an idiomatic or concrete Go handoff primitive

**Severity:** MEDIUM  
**Category:** H.2, H.3  
**Location:** `BUILD_SPEC_017_IMPL_PROMPT.md` lines 287-298; `phase4-coordinator/internal/explorer/handlers.go` lines 33-95

The middleware stack tells the redaction-context middleware to store the parsed
Bearer token in a "goroutine-local handle" for the auth dispatcher. Go has no
standard goroutine-local storage primitive, and the existing explorer handler
pattern passes request state explicitly through `*http.Request`, handler
fields, and helper calls.

Two conforming authors could resolve this differently: request context with a
private typed key, a closure-captured auth state, a package-level map keyed by
goroutine id, or a global mutable handle. The latter two would be risky and
non-idiomatic, especially under concurrent HTTP serving.

**Fix:** Replace "goroutine-local handle" with a concrete Go shape. Preferred:
store the parsed token in `r.Context()` under an unexported typed key after
redacting the logging context, or pass an explicit `authState` struct through
the middleware chain. State that the raw token holder must never be logged or
attached to metric labels.

### CODE-R3-006 — `stats_rollup` table-count wording double-counts `stats_late_events`

**Severity:** LOW  
**Category:** B.1, I.2  
**Location:** `BUILD_SPEC_017_IMPL_PROMPT.md` lines 122-126; `SPEC-017-network-stats-api.md` lines 1271-1281

The prompt says `stats_rollup` gets `SELECT, INSERT, UPDATE, DELETE` on:

```text
the eight stats_* tables plus stats_components_health plus stats_late_events
```

The locked SPEC's actual grant list is seven projection tables plus
`stats_components_health` plus `stats_late_events`. `stats_late_events` is
itself a `stats_*` table, so the prompt's "eight stats_* ... plus
stats_late_events" wording double-counts it. The surrounding DDL list and SPEC
grant list are clear enough that this is unlikely to produce a wrong table
name, but it is grant-inventory hygiene drift.

**Fix:** Replace the count-based wording with the literal table list from
SPEC §7.2.2:
`stats_overview_current`, the two `stats_timeseries_*` tables, the four
`stats_leaderboard_*` tables, `stats_components_health`, and
`stats_late_events`.

## Category Walk

- **A. Section number drift:** No unresolved SPEC-017 section-number drift found. `§5.1`, `§5.2`, `§5.3`, `§5.4.x`, `§5.6`-`§5.9`, `§6.x`, `§7.x`, `§8.5`, `§9.x`, `§10`, and `§11 Qx` references resolve to the intended sections. AC drift remains in CODE-R3-001, CODE-R3-003, and CODE-R3-004.
- **B. Postgres grant shape correctness:** Role/table names and sequence grants match the locked SPEC. `partner_keys_writer`'s added `SELECT(id)` is mechanically correct for the worker `WHERE id = $2` pattern. Count wording issue recorded as CODE-R3-006.
- **C. Go package boundary correctness:** Filesystem package layout matches SPEC §4.2 and the existing flat explorer pattern. AC-16 fixture import path issue recorded as CODE-R3-003.
- **D. Wire-contract correctness:** Partner-key length, CORS 204, status codes, cache directives, and `X-Stats-Generated-At` coverage are otherwise aligned. Disabled-mode stub and nginx rate-limit mechanics recorded as CODE-R3-002 and CODE-R3-004.
- **E. AC test-coverage mapping:** AC-1 through AC-21 are assigned. AC-16, AC-17, and AC-8 have test-surface/mechanics issues recorded above.
- **F. Migration / IMPL-time decision drift:** Prompt correctly gates SPEC-016 reward-source recheck, operator backfill mode, and hostname pattern; no finding.
- **G. Test-shape correctness:** Fixture corpus is now concrete. Lint smoke and nginx smoke issues recorded above.
- **H. Idiomatic Go correctness:** Per-role `*sql.DB` isolation matches SPEC §7.2.5. Recover ordering is pinned. `partner_keys.last_used_at` buffered channel is concrete. Goroutine-local wording recorded as CODE-R3-005.
- **I. Naming hygiene:** Role names and table names are consistent, apart from the `stats_rollup` count wording. New event names do not collide with existing explorer `event=internal_bearer_accepted`.

## Self-Verification

- [x] Walked every `§X.Y` citation against SPEC-017 v0.1.6.
- [x] Walked every AC-N citation against §10.
- [x] Walked every GRANT line / grant inventory item.
- [x] Walked Categories A through I.
- [x] Severity per finding chosen against requested definitions.
- [x] Verdict recorded.

## 200-Word Handback Summary

Round 3 is substantially cleaner than r2, but it is not at the requested
0C/0H/0M lock target. I found no CRITICAL issues. The remaining HIGH issues are
all concrete implementation mechanics. First, Step 4 makes `--created-by`
required and tests `partner-keys issue --label X --created-by ...`, while locked
AC-17 requires `partner-keys issue --label X` to work. Second, the disabled
stats subtree introduces a `{"status":"down","reason":"stats_disabled"}` 503
body outside the §5.9 envelope and closed code set. Third, the AC-16 lint smoke
uses an invalid Go import path and `os.Exit("test")`, so `make lint` can fail
for compiler/type errors instead of proving the intended depguard/process-exit
rules. Fourth, the nginx `burst=<n> nodelay` directive is inconsistent with
AC-8's 61st-request rejection if `<n>` is positive, because `nodelay` allows
burst traffic through immediately. One MEDIUM remains: "goroutine-local handle"
is not a concrete Go mechanism; request context or an explicit auth state should
be specified. One LOW naming issue remains in the `stats_rollup` table-count
wording. Section references, grant names, role names, CORS 204, cache values,
and partner-key length math otherwise check out.
I did not draft a fix prompt; this file is limited to audit evidence, severity,
and direct repair guidance for the IMPL prompt author only, for review now.
