# IMPL audit prompt — SPEC-016 Step 1, **ARCHITECTURE REVIEW lane**

Lane 3 of 3 parallel codex audit lanes for SPEC-016 Step 1 IMPL
(branch `impl/spec-016`, current SPEC v0.1.21 LOCKED at `f0152c0`,
Step 1 IMPL commit `1df0235`).

**House practice:** three codex lanes fire in parallel —
`code-reviewer` / `security-reviewer` / `architect`. This is the
architect lane. Findings from all three lanes consolidate at the
end of the round into the fix-pass triage.

Fire via:

```
omc ask codex --agent-prompt architect --prompt "<this file's body>"
```

Expected wall-clock: 25–40 min (architecture concerns are
typically fewer-but-deeper than code review; the cross-step
readiness check is the load-bearing item).

This is **read-only** — codex MUST NOT modify any file, commit,
push, or change git state.

---

```
=== BEGIN PROMPT ===

You are the **architect** lane (3 of 3) auditing SPEC-016 Step 1
IMPL. Two sibling lanes (code-reviewer + security-reviewer) are
firing in parallel; you do NOT need to consider code-style or
adversarial-security concerns — those are explicitly out-of-scope
for your lane so that the three lenses stay independent and
diverse.

## Shared context

Read `specs/AUDIT_SPEC_016_IMPL_STEP_1_PROMPT.md` for the FULL
shared context block (PR consolidation note, version history
v0.1.19 → v0.1.21, Step 1 IMPL ∩ v0.1.21 deltas intersection,
threat model recap, required reading in order, file/LOC catalog of
what Step 1 added, severity scale, discipline rules). Treat that
file's lines 1–247 as your full context preamble.

The SPEC is LOCKED at `specs/SPEC-016-payout-pipeline.md` v0.1.21
on branch `impl/spec-016` at commit `f0152c0`. Step 1 IMPL is
commit `1df0235` on the same branch. Working tree is clean.

**The PR consolidation matters for your lane.** All four steps
land on a SINGLE branch + SINGLE PR. Your architecture review
should weight "Step 2/3/4 readiness" higher than "this step's
internal hygiene" — a Step 1 decision that forces Step 2 to fight
the abstraction is the architecture failure mode that compounds
fastest under a single-PR plan.

## Your lane scope: ARCHITECTURE REVIEW only

From `specs/AUDIT_SPEC_016_IMPL_STEP_1_PROMPT.md`, attend ONLY to
the **Dimension 3: ARCHITECTURE REVIEW** focus areas. Do NOT
report findings in code style or security — those land in the
sibling lanes' files.

The Dimension 3 focus-area list in the master prompt covers:

1. **billing/ → payout/ import direction** (SPEC §4.1 normative).
   Confirm `importgraph_test.go` catches TRANSITIVE imports too
   (not just direct). `go/build` returns transitive deps — walk
   the test and confirm.
2. **Same-`*sql.DB` handle discipline.** SPEC §4.8a / §4.8b require
   one shared `*sql.DB` across runner + endpoints + lease. Step 1
   only mounts the §3.3 handler; confirm the wiring already
   threads the shared handle correctly so Step 2's runner can hook
   in without re-opening the DB.
3. **Config namespace split.** Step 1 ships
   `PayoutConfig{Enabled, Security{HotWalletAddress},
   Tuning{AddressCoolingOffPeriod}}`. SPEC §6.5 dictates a
   three-way split (`payout.security.*` immutable,
   `payout.tuning.*` SIGHUP-reloadable, `runtime.*` closed). Step
   1's struct is the seed; Step 4 grows it. Confirm Step 1 does
   NOT plumb `payout.security.*` through a reload path (no SIGHUP
   / fsnotify watcher on Security). Probe whether a future
   contributor could accidentally hot-reload `HotWalletAddress` by
   adding a setter — comment discipline is the soft enforcement.
4. **chi router placement on the provider listener.** The IMPL
   mounts chi under `/providers/` — replacing the prior direct
   `billingHandler` registration. Verify the existing
   `/providers/{id}/earnings` billing path still resolves through
   the chi fallback. Probe edge cases: `/providers/foo/earnings/`
   (trailing slash), `/providers/`, `/providers/foo` (no /earnings).
5. **payout package internal structure.** Step 1 splits payout/
   into ~13 files. Is the split clean — config, schema, EIP-55,
   EIP-712, deny, errors, addresses, mux, bootstrap, pause,
   migrations? Compare to the SPEC §5 IMPL prompt repo-layout
   table; is anything Step 1 added meant to live elsewhere? Are
   the helpers (`bearerFromHeader`, `clientIP`, `orNone`,
   `statusName`, `writeError`, `writeJSON`, `jsonString`,
   `isUniqueViolation`) properly scoped — or are they too
   package-private to reuse in Steps 2–4?
6. **Testing surface vs SPEC test-corpus list.** The IMPL prompt
   Step 1 test corpus lists 11 minimums. Walk each one against
   the existing test files. Confirm coverage; flag any item
   listed as "deferred to Step 2" that should land now (e.g. the
   co-residency assertion at SPEC §3.3).
7. **DSN durability bump scope tradeoff.** The largest cross-cutting
   change in Step 1. Architecturally, was it the right call to
   land here vs in a separate prep PR vs in a payout-scoped conn
   pool? Quantify alternatives A (current global DSN → FULL),
   B (per-conn callback), C (separate `*sql.DB` for payout, which
   would BREAK SPEC §4.7 / §4.8 / §4.9 same-DB pin). Confirm A is
   the right tradeoff and flag if you disagree.
8. **Step 1 → Step 2 readiness** (the load-bearing concern under
   the single-PR plan):
   - `payout_attempts` schema includes every column Step 2's §4.3
     step 5 INSERT needs?
   - Does `LookupPayoutAddress` return enough info for Step 2's
     §4.3 step 1 SELECT? Or is `LookupPayoutAddress` strictly the
     cross-package read-side mirror for billing, with the runner
     using its own internal SELECT?
   - Is `payout.tuning.address_cooling_off_period` plumbed so Step
     2 / 4 can extend the tuning struct without breaking the Step
     1 wiring?
   - Will Step 2's runner be able to hook into `setupPayout`
     without churn?
9. **Co-residency invariant communication.** SPEC §3.3 demands a
   startup assertion that the runner and the handler are in the
   same process. Step 1 has no runner. Step 2 will install the
   runner; will Step 2's wiring trip if a future operator splits
   handler and runner across processes? Flag if Step 1 should have
   a placeholder assertion.
10. **Documentation discipline.** Verify SPEC §-citations in code
    comments are adequate for a future contributor reading code
    without the SPEC. Walk:
    - `addresses.go` ServePayoutAddress: are the 11 pipeline
      stages well-commented with SPEC §-references?
    - `eip712.go` buildDigest: is the encoding scheme attributable
      to EIP-712 §4?
    - `bootstrap.go` BootstrapRuntimeFlags: does the four-branch
      action table comment match the SPEC L2319–L2336 table?
11. **v0.1.21 architectural implications** (newly in-scope per
    SPEC bump):
    - SPEC v0.1.21 §4.3 step 5 NORMATIVE C3 invariant
      (`amount_base_units == lpr.provider_credits` inside BEGIN
      IMMEDIATE) is Step 2 territory, but Step 1's `payout_attempts`
      schema must already support it. Confirm.
    - SPEC v0.1.21 M1 reorg-poll cadence is Step 2 territory but
      adds RPC budget accounting. Confirm Step 1's schemas + lease
      layout do not assume a fixed cadence that conflicts.
    - SPEC v0.1.21 M4 chain-nonce uniqueness as load-bearing
      means Step 1's `idx_pa_from_nonce_active` partial UNIQUE
      indexes are critical. Confirm the migration ships these and
      the architecture supports Step 2 leveraging them.

Findings format (per master prompt Dimension 3 spec):

```
[arch:N.M] [SEVERITY] <short title>
  What: <one-paragraph description>
  Trade-off: <what's gained vs lost by the current choice>
  Suggestion: <a concrete refactor or follow-up; NOT required for
              merge unless the severity says so>
```

Severity scale (from master prompt):

- **CRITICAL** — a Step 1 architectural choice that BLOCKS Step
  2/3/4 from implementing the SPEC correctly. MUST be fixed before
  Step 2 begins. Concrete failure mode at the future step
  describable in one sentence.
- **MAJOR** — architectural friction that Step 2/3/4 will have to
  fight; not a blocker but a real cost. SHOULD be addressed before
  the single PR opens.
- **MEDIUM** — observable architecture-level SPEC deviation that
  survives but does not block downstream steps. Fix before merge
  OR Appendix B.
- **LOW** — style / convention drift / suggestion. MAY be
  deferred.

The audit-loop discipline at `specs/BUILD_SPEC_016_PAYOUT_IMPL_PROMPT.md`
§3 requires 0 CRITICAL / 0 MAJOR / 0 MEDIUM across **all three
lanes combined** before push/PR.

## Output

Write findings to `specs/SPEC-016-IMPL-STEP_1-arch-audit.md` with
this structure:

```
# SPEC-016 IMPL Step 1 — codex ARCHITECTURE REVIEW lane, round 1

## Verdict (architecture review lane only)

<one-line summary: CLEAN | FIX-THEN-PROCEED | BLOCK>

## Counts

| CRITICAL | MAJOR | MEDIUM | LOW |
|----------|-------|--------|-----|
| <N>      | <N>   | <N>    | <N> |

## Findings

[arch:1.1] [SEVERITY] ...
[arch:1.2] [SEVERITY] ...

## Step 1 → Step 2 readiness assessment

<explicit walk through every Step 2 dependency Step 1 was
supposed to seed; mark each as READY / FRICTION / BLOCKED>

## SPEC drift catalog (architecture-side only)

<any normative SPEC §-paragraph Step 1 architecture does not
honor faithfully; cite SPEC line numbers + IMPL file:line>

## What I didn't review

<files/areas you intentionally skipped, with rationale>

## Cross-cutting architecture observations

<patterns spanning multiple findings; long-horizon implications
for Step 2 / 3 / 4>

## Note on sibling lanes

You are explicitly NOT reporting code-style or security findings
here. If an architecture observation overlaps with code or
security concerns, note the overlap in "Cross-cutting architecture
observations" but defer the verdict to the sibling lane.
```

## Discipline

- Be specific. Cite `<file>:<line>` for every finding.
- Frame every finding through "what does Step 2 / 3 / 4 have to
  fight as a result?" — that is your unique architectural lens.
- Be conservative on CRITICAL — a Step 1 architectural choice is
  CRITICAL only if you can name the SPEC §-rule a future step
  cannot implement faithfully without first un-winding Step 1's
  choice.
- Honest uncertainty: MAJOR + "needs design review" tag when you
  can't confirm the future-step impact without doing Step 2 work.
- Cite the binding SPEC rule for every drift claim.

You may run shell commands (git log, grep, find, `go vet`,
`go build ./...`, dependency-graph analysis). You MUST NOT modify
any file.

You may take up to 40 minutes wall-clock. If you finish earlier
with a clean report, that's fine — do not pad.

=== END PROMPT ===
```

---

## Operator notes (out-of-band)

- This is **Lane 3 of 3** in the parallel codex audit fan-out.
  Sibling lanes:
  - `AUDIT_SPEC_016_IMPL_STEP_1_CODE_PROMPT.md` — code-reviewer lane
  - `AUDIT_SPEC_016_IMPL_STEP_1_SECURITY_PROMPT.md` — security-reviewer lane
- Findings files:
  - `specs/SPEC-016-IMPL-STEP_1-code-audit.md`
  - `specs/SPEC-016-IMPL-STEP_1-security-audit.md`
  - `specs/SPEC-016-IMPL-STEP_1-arch-audit.md` (this lane)
- Loop until **all three lanes combined** return
  0 CRITICAL / 0 MAJOR / 0 MEDIUM before push/PR.

🤖 Generated with [Claude Code](https://claude.com/claude-code) (Opus
4.7) for the SPEC-016 v0.1.21 IMPL Step 1.
