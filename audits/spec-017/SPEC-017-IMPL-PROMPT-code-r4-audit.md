# SPEC-017 IMPL Prompt Code-Mechanics Audit — Round 4

**Target:** `specs/BUILD_SPEC_017_IMPL_PROMPT.md`  
**Lens:** CODE-MECHANICS  
**Controlling contract:** `specs/SPEC-017-network-stats-api.md` v0.1.6 LOCKED  
**Required pattern check:** `phase4-coordinator/internal/explorer/handlers.go`

## Verdict

**NOT READY:** 1 CRITICAL, 2 HIGH, 1 MEDIUM, 1 LOW.

Round 4 closes the r3 CODE findings called out for this pass:
`--created-by` is now optional with a non-empty default, disabled stats no
longer mounts a custom JSON subtree, AC-16 uses the real module path and
`os.Exit(1)`, middleware state uses `r.Context()` with an unexported typed key,
and the `stats_rollup` grant list is enumerated without the stale count wording.

The remaining blockers are narrower but still implementation-facing. The
largest issue is that Step 4.B tells the IMPL author to ship a no-burst nginx
public rate-limit config even though locked SPEC §5.6 still requires public
burst `120`. Two Step 1/2 mechanics also drift from the locked package/schema
contract: rollup is allowed to import `internal/explorer`, and a Step 2 test
uses a `stats_*.generated_at` shorthand that does not exist on the locked
timeseries tables.

## Findings

### CODE-R4-001 — Step 4.B ships a no-burst nginx config despite locked §5.6 public burst

**Severity:** CRITICAL  
**Category:** D.4, E.2, G.3  
**Location:** `BUILD_SPEC_017_IMPL_PROMPT.md` lines 401-407, 419, 486, 588; `SPEC-017-network-stats-api.md` lines 881-889 and 1785-1787

The prompt correctly identifies the mechanical conflict between locked SPEC
§5.6 (`60 req/min`, burst `120`) and AC-8 (61st request in a 60s window returns
429). It then resolves the conflict inside the IMPL prompt by instructing the
author to configure the public AC-8 surface without `burst=`:

```nginx
limit_req zone=<name> nodelay;
```

That is not an implementation detail. It drops a locked public rate-limit
property from §5.6 and treats the SPEC's `120 burst` as a future v0.2 candidate.
Because the SPEC is locked, the IMPL prompt must not choose between two locked
pins by silently weakening one of them.

**Fix:** Do not tell the IMPL author to ship no-burst production nginx as the
v0.1 resolution. Replace Step 4.B with an implementation-blocking instruction:
the public nginx rate-limit config cannot be finalized until the controlling
contract has one mechanical behavior for both §5.6 and AC-8. If a no-burst
fixture is kept, label it test-only and forbid using it as the shipped §5.6
config.

### CODE-R4-002 — Rollup import allowlist incorrectly includes `internal/explorer`

**Severity:** HIGH  
**Category:** C.1, C.2, C.4, E.7  
**Location:** `BUILD_SPEC_017_IMPL_PROMPT.md` lines 100-107 and 170; `SPEC-017-network-stats-api.md` lines 398-405 and 1815-1819

The locked SPEC allows `phase4-coordinator/internal/stats/rollup/` to import
billing/session/pool packages read-only because it runs out-of-band. It does
not allow the rollup package to import `internal/explorer`. SPEC §4.2 states the
rollup carve-out as billing/session/pool only, while AC-16 names
`internal/explorer` in the forbidden import set for the stats import graph.

The IMPL prompt broadens the carve-out:

```text
Rollup package (`internal/stats/rollup`) — MAY import billing/session/pool/explorer read-only paths
```

An author following that prompt can write code that compiles and runs but fails
a proper AC-16 lint once the lint is applied to the `internal/stats/...` tree.
It also couples the public stats rollup to the admin explorer implementation,
fighting the existing `internal/explorer/handlers.go` pattern, where explorer is
an operator-only surface with its own handler, store, auth, and audit event.

**Fix:** Remove `explorer` from the rollup import allowlist. The carve-out
should be exactly billing/session/pool read-only. If rollup needs data currently
exposed only through explorer helpers, factor those helpers into a neutral
read-only package or query through the rollup DAO/SQL layer instead.

### CODE-R4-003 — Step 2's `stats_*.generated_at` test is not mechanically writable against §9.1

**Severity:** HIGH  
**Category:** G.1, I.2  
**Location:** `BUILD_SPEC_017_IMPL_PROMPT.md` line 211; `SPEC-017-network-stats-api.md` lines 1496-1568

Step 2 says:

```text
Integration: a rollup tick advances `stats_*.generated_at`; `stats_components_health` rows update accordingly.
```

The locked §9.1 schema does not have `generated_at` on every `stats_*` table.
`stats_timeseries_rpm_30m` has `bucket_start, requests`; 
`stats_timeseries_tpm_30m` has `bucket_start, input_tokens, output_tokens`;
`stats_late_events` has `recorded_at, event_unix_ts, provider_id, ...`.
Only `stats_overview_current`, the `stats_leaderboard_*` tables, and
`stats_components_health` have `generated_at`.

A literal test written from the prompt would either query nonexistent columns or
push the implementer to add prompt-only columns outside the locked DDL.

**Fix:** Replace the shorthand with per-table assertions:
`stats_overview_current.generated_at` advances; each `stats_leaderboard_*`
table's `generated_at` advances at its cadence; `stats_timeseries_*` advances by
inserting/updating the expected newest `bucket_start`; and
`stats_components_health.generated_at/last_ok_at` updates for each component.

### CODE-R4-004 — AC-7 health-status assertion still allows two incompatible expected values

**Severity:** MEDIUM  
**Category:** D.4, E.4, G.1, H.2  
**Location:** `BUILD_SPEC_017_IMPL_PROMPT.md` line 322; `SPEC-017-network-stats-api.md` lines 681-687 and 1701-1711

The Step 3 AC-7 bullet seeds `stats_components_health` with
`component = 'overview'` and `generated_at = now - 130s`, then says to assert
JSON `status = "down"`:

```text
(or `"degraded"` depending on the budget; pin per §5.3 thresholds)
```

For this exact fixture, the locked thresholds are not ambiguous. SPEC §5.3 says
`down` when `overview` is beyond its §5.8 503 budget, and §9.5 sets the
overview 503 budget at `120s`. `now - 130s` is therefore `down`, not
`degraded`.

Two conforming prompt readers could still write different tests because the
parenthetical explicitly permits `"degraded"`. That is a test-shape ambiguity,
not a SPEC ambiguity.

**Fix:** Delete the escape hatch. The test should assert `status = "down"` for
`overview.generated_at = now - 130s`. Add a separate `degraded` fixture if
needed, e.g. `overview.generated_at = now - 45s`, which is beyond the 30s target
but within the 120s 503 budget.

### CODE-R4-005 — SPEC-005 ledger-table citation points readers at the wrong external section

**Severity:** LOW  
**Category:** A.1, F.1, I.2  
**Location:** `BUILD_SPEC_017_IMPL_PROMPT.md` lines 126 and 519; `SPEC-005-billing.md` lines 247-320, 373-390, and 701-728

The prompt twice tells the IMPL author that SPEC-005 ledger tables are in
`§10`. In the current locked SPEC-005 v0.3 file, the table definitions are in
§4.3 through §4.8, while §10 is crash recovery and reconciliation. The prompt
does list the core table names correctly and tells the author to re-verify
line-3 dependency versions at IMPL time, so this is reference hygiene rather
than a grant/table blocker.

**Fix:** Point the reading list and rollup source-grant note at SPEC-005 v0.3
§4.3-§4.8 for table definitions, with §10 only for recovery/reconciliation
behavior that may affect source-row interpretation.

## Category Walk

- **A. Section number drift:** SPEC-017 citations resolve to the intended
  sections. External SPEC-005 ledger-table section hygiene is recorded as
  CODE-R4-005.
- **B. Postgres grant shape correctness:** SPEC-017-owned role grants, sequence
  grants, table names, and optional `partner_keys_writer` default-off posture
  match the locked §7.2 inventory. No invalid PostgreSQL grant shape found.
- **C. Go package boundary correctness:** Request-path layout matches the
  existing flat explorer handler pattern, but rollup's prompt allowlist
  incorrectly includes `internal/explorer`; see CODE-R4-002.
- **D. Wire-contract correctness:** Partner-key 47-character math, CORS 204,
  error vocabulary, 405 envelope, cache directives, `X-Stats-Generated-At`,
  redaction rules, and 304 shape otherwise align. Nginx rate-limit conflict is
  CODE-R4-001; health-status test ambiguity is CODE-R4-004.
- **E. AC test-coverage mapping:** AC-1 through AC-21 are assigned in §2.4.
  AC-8 is blocked by CODE-R4-001. AC-16 is weakened by CODE-R4-002. AC-7's
  derived health-status assertion is ambiguous in CODE-R4-004.
- **F. Migration / IMPL-time decision drift:** The prompt correctly directs
  IMPL-time re-verification of SPEC-016 rewards-source deferral and
  SPEC-002/SPEC-005 OLTP source grants. Hostname and backfill modes both remain
  implemented in code with operator cutover selection.
- **G. Test-shape correctness:** Fixture corpus is concrete. Step 2's
  `stats_*.generated_at` assertion is not mechanically writable; see
  CODE-R4-003.
- **H. Idiomatic Go correctness:** Per-role `*sql.DB` isolation is pinned and
  compatible with the coordinator's current explicit DB-handle pattern.
  Recover middleware shape and request-context bearer handoff are concrete.
  `partner_keys.last_used_at` has no v0.1 worker/channel, matching the prompt's
  default-off resolution.
- **I. Naming hygiene:** Role names, event names, and SPEC-017-owned table
  names are consistent. Existing explorer event name
  `internal_bearer_accepted` does not collide with the new `stats_*` events.

## Self-Verification

- [x] Walked every `§X.Y` citation against SPEC-017 v0.1.6.
- [x] Walked every AC-N citation against §10.
- [x] Walked every GRANT line / grant inventory item.
- [x] Walked Categories A through I.
- [x] Severity per finding chosen against requested definitions.
- [x] Verdict recorded.

## 200-Word Handback Summary

Round 4 is cleaner than r3 but is not at the 0C/0H/0M lock target after a full
section, AC, grant, and package walk. I verified
the r3 CODE fixes are absorbed: AC-17's bare `partner-keys issue --label X`
path now works through a default `created_by`; disabled stats no longer creates
a prompt-only JSON response; the AC-16 fixtures use the real Go module path and
`os.Exit(1)`; request token handoff uses `r.Context()` with an unexported typed
key; and the rollup grant inventory is enumerated.

The remaining CRITICAL issue is Step 4.B resolving the locked §5.6 vs AC-8
conflict by shipping no-burst nginx public rate limiting. The SPEC still says
public burst is 120, so the IMPL prompt must not silently drop it and defer the
contract mismatch to v0.2. Two HIGH issues remain: the rollup import carve-out
allows `internal/explorer`, which is outside the locked billing/session/pool
carve-out and can violate AC-16; and the Step 2 test says
`stats_*.generated_at`, but locked timeseries and late-event tables do not have
that column. One MEDIUM remains because AC-7 still says the same 130s overview
fixture may assert either `down` or `degraded`. One LOW external citation points
readers to SPEC-005 §10 for table definitions that actually live in §4.3-§4.8.
