# IMPL audit prompt — SPEC-016 Step 1, **ARCHITECTURE REVIEW lane, round 2**

Round 2 of the architect lane against the Step 1 r1 fix-pass.
Branch `impl/spec-016` HEAD after fix-pass: `fc3bf56`.

Fire via:

```
omc ask codex --agent-prompt architect --prompt "<this file's body>"
```

This is **read-only** — codex MUST NOT modify any file.

---

```
=== BEGIN PROMPT ===

You are the **architect** lane (3 of 3) auditing SPEC-016 Step 1
IMPL — round 2. Round 1 returned 1 MAJOR + 2 MEDIUMs (see
`specs/SPEC-016-IMPL-STEP_1-arch-r1-audit.md`). The fix-pass
landed in commit `fc3bf56` on branch `impl/spec-016` and:

- Closed [arch:1.2] (transitive import-graph walk)
- Closed [arch:1.3] (co-residency assertion hook)
- Deferred [arch:1.1] (SPEC v0.1.21 §4.7 query references
  non-existent columns) as a SPEC v0.1.22 candidate per
  `specs/SPEC-016-IMPL-STEP_1-r1-deferrals.md` — operator-side
  resolution, not Step 1 IMPL.

Your round 2 job: verify [arch:1.2] + [arch:1.3] are properly
closed, validate the [arch:1.1] deferral rationale, and scan for
architecture regressions or new defects introduced by the
fix-pass.

## Shared context

See `specs/AUDIT_SPEC_016_IMPL_STEP_1_PROMPT.md` for the shared
context preamble. Same SPEC version (v0.1.21 LOCKED at
`f0152c0`). The single-PR plan still stands; your lens is still
"what does Step 2 / 3 / 4 have to fight."

Branch HEAD: `fc3bf56`. Fix-pass diff: `git show fc3bf56`.

## Your r2 verification scope

### Verify [arch:1.2] closure — transitive import-graph walk

The new `importgraph_test.go`:

- DFS over `pkg.Imports + pkg.TestImports + pkg.XTestImports`
- In-module deps walked recursively; third-party / stdlib deps
  stop at one level.
- `TestImportGraph_BillingDoesNotImportPayout` asserts the
  visited set never includes `internal/payout` or any subpkg.

Probe:

1. Run the test — does it pass? Force a regression: temporarily
   add `import "github.com/augstar/macprovider-coordinator/internal/payout"`
   to a billing-side file (without committing) and confirm the
   test trips.
2. Confirm the recursion correctly handles cycles via the
   `visited` set.
3. Confirm `XTestImports` is included (external test packages
   could import payout/ and that would also be a violation).
4. The companion `TestImportGraph_PayoutToBillingPermitted` is
   forward-compat for Step 2's ClaimPayoutReady call site —
   confirm the test name + comment do not mislead a future
   contributor into thinking the import is required NOW.

### Verify [arch:1.3] closure — co-residency assertion hook

The new `topology.go`:

- `PayoutRuntimeTopology` struct + `AssertPayoutRuntimeTopology`
  function.
- `setupPayout` invokes it BEFORE building any service.
- Step 1 wires `HandlerEnabled=true`, `RunnerCoResident=false`,
  `LinuxRequired=false`.

Probe:

1. Confirm Step 2's runner introduction has a clean hook: when
   Step 2 sets `RunnerCoResident=true`, the existing branch
   structure trivially supports it (no refactor required).
2. The `LinuxRequired=false` at Step 1 is the right posture
   (handler-only works on darwin / linux). Confirm Step 2's
   runner introduction will be able to flip
   `LinuxRequired=true` without breaking Step 1's existing
   topology hook semantics.
3. The comment in `addresses.go` `NewAddressesService` previously
   said "Co-residency assertions ... live in main.go" — it was a
   lie. Confirm the updated comment now points correctly to
   `topology.go` AND that no other comment in the payout package
   still claims a hook that doesn't exist.
4. Probe `setupPayout` startup sequencing: the topology assertion
   runs AFTER `LoadSecurityConfig` (so `sec.HotWalletAddress` is
   canonicalised) but BEFORE `NewDenyList` / `NewPauseReader` /
   `NewAddressesService`. Confirm this ordering is correct — a
   downstream dependency on the asserted topology cannot be
   built before the assertion runs.

### Validate [arch:1.1] deferral rationale

Read `specs/SPEC-016-IMPL-STEP_1-r1-deferrals.md` and the original
[arch:1.1] finding in
`specs/SPEC-016-IMPL-STEP_1-arch-r1-audit.md`.

The deferral claim: the §4.7 query in SPEC v0.1.21 references
columns (`payout_attempts.id`, `payout_external_id`) that don't
exist in §4.5's `payout_attempts` schema. Step 1's migration
matches §4.5 byte-for-byte; the IMPL is not wrong, the SPEC is
wrong (or the SPEC author intended a different column name).

Probe:

1. Confirm the SPEC drift exists: read SPEC §4.5 (line ~1400)
   AND SPEC §4.7 line 1896, surface any contradiction.
2. Confirm the deferral note correctly identifies the SPEC line
   number that needs amendment.
3. Confirm the deferral cites a Step 2 IMPL author's
   perspective — the column reference would surface as a "no
   such column: id" error at query prepare time. Is the deferred
   defect blocking enough that Step 2 IMPL cannot begin until
   resolved? Or can Step 2 IMPL fork an alternate query shape
   pending SPEC v0.1.22 resolution?

If the deferral is well-founded, mark it as VALIDATED. If you
disagree (e.g. you think Step 1 SHOULD have amended the migration
to add an `id` column or a `payout_external_id` column to match
the §4.7 query), flag as a NEW Step 1 finding.

### Regression sweep — architecture cleanliness

1. The new `topology.go` file: does it belong in `payout/`? Or
   should it live in `payout/runtime/` or `internal/topology/`?
   Apply the same "future-step readiness" lens — Step 2 will
   extend the topology hook; is the current home defensible?
2. The new `existingPayoutAllowed sql.NullInt64` in
   `addresses.go`: does the type choice (nullable int64) match
   the schema (NOT NULL DEFAULT 1)? In practice the column is
   always present when `existingAddress.Valid == true`. Confirm
   the nullable type is defensive-coding, not a sign of a
   missing schema invariant.
3. The two new regression tests
   (`RotationPreservesPayoutAllowed_Zero` / `_One`) use a raw
   SQL INSERT to seed the disabled row. Is this the right
   testing pattern for Step 1 (no helper exists yet) vs Step 2
   (where the §6.4.1 endpoint will offer a write-side API)?
   Flag if Step 1 should have introduced a helper now to avoid
   churn at Step 2.

### Step 1 → Step 2 readiness — re-assess

The r1 architect lane assessed:

- Same `*sql.DB` discipline — READY
- `payout_attempts` schema supports §4.3 + C3 — READY
- §4.7 reorg poll field names — FRICTION (the arch:1.1 SPEC
  drift) — STILL DEFERRED
- `LookupPayoutAddress` cross-package boundary — READY
- Co-residency assertion — FRICTION (was missing) → now CLOSED

Re-confirm each row holds after the fix-pass.

### Output

Write findings to `specs/SPEC-016-IMPL-STEP_1-arch-r2-audit.md`
with the same structure as r1:

```
# SPEC-016 IMPL Step 1 — codex ARCHITECTURE REVIEW lane, round 2

## Verdict (architecture review lane only)

<one-line summary: CLEAN | FIX-THEN-PROCEED | BLOCK>

## Counts

| CRITICAL | MAJOR | MEDIUM | LOW |
|----------|-------|--------|-----|
| <N>      | <N>   | <N>    | <N> |

## r1 closures verified

| r1 ID    | Status   | Notes |
|----------|----------|-------|
| arch:1.1 | DEFERRED-VALIDATED / DEFERRED-REJECTED | <one-line> |
| arch:1.2 | CLOSED / PARTIAL / NOT_CLOSED | <one-line> |
| arch:1.3 | CLOSED / PARTIAL / NOT_CLOSED | <one-line> |

## Step 1 → Step 2 readiness (re-assessment)

| Row | r1 verdict | r2 verdict |
|-----|------------|------------|
| Same *sql.DB discipline | READY | ? |
| payout_attempts schema for §4.3/C3 | READY | ? |
| §4.7 reorg poll field names | FRICTION | ? |
| LookupPayoutAddress | READY | ? |
| Co-residency assertion | FRICTION | ? |

## New findings (if any)

[arch:2.1] [SEVERITY] ...

## Cross-cutting architecture observations

<patterns + long-horizon implications>
```

## Discipline

- Be specific. Cite `<file>:<line>` for every finding.
- Frame every finding through "what does Step 2 / 3 / 4 have to
  fight?".
- A CLEAN verdict requires r1 closures VERIFIED, the [arch:1.1]
  deferral VALIDATED, and zero new architecture findings.
- BLOCK only if r1 closures are themselves wrong or you find a
  new architecture CRITICAL.

You may run shell commands. You MUST NOT modify any file.

You may take up to 30 minutes wall-clock.

=== END PROMPT ===
```

---

🤖 Generated with [Claude Code](https://claude.com/claude-code) (Opus
4.7) for the SPEC-016 v0.1.21 IMPL Step 1 round 2.
