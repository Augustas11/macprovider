You are reviewing branch `spec/iss-197-v1-4-3-clarifications` of the macprovider repo
(working tree `/Users/augstar/macprovider-iss197`), ARCHITECT lane, ROUND 3.

R2 returned 1 MEDIUM + 2 LOW. R3 fixes:

1. (R2 MEDIUM: SPEC-005 alignment) Bumped SPEC-005 v0.3.1 → v0.3.2.
   - `Depends on:` now pins `SPEC-002 v1.5.1`.
   - New change-log entry at top describing the per-key migration-
     state dependency and the `legacy | unindexed | indexed` MUST
     for out-of-process reconciliation tooling.
   - §10.4 "missing indexes in fixture MAY scan, but production
     startup MUST fail the schema check" rewritten to reference the
     per-key state contract and the
     `coordinator migrate-indexes --check --format json` surface.

2. (R2 LOW: zero-key edge) New SPEC clause: "Registry invariant —
   `migrationKeyDefs` MUST be non-empty; append-only; consumers MUST
   match by `key` and tolerate additional entries (forward-compat)."

3. (R2 LOW: registry-extension docs) Same clause names `migrationKeyDefs`
   as the registry and pins the contract on `key` strings as stable.

4. (R2 architect cross-finding from code lane: scope of operational
   binding) R3 sharpened §11 + the change-log entry: the
   `MUST fail closed on unindexed` rule applies to **out-of-process
   reconciliation tooling** (SPEC-005 v0.3+ closing-the-books surface),
   NOT to coordinator's in-process `RecoverLedger` / admin reconcile /
   hot-path AttemptN derivation. The latter use SQLite `IS` clustering
   and are correct (just unindexed-slow) under state `unindexed`. The
   daemon-startup `unindexed` rollout window is by design and the
   daemon must serve traffic in it.

## Verify

- Does SPEC-002 §11 and the v1.5.1 change-log entry now consistently
  carve in/out the same scope? Look for any remaining sentence that
  would force in-process recovery to fail closed.
- Is SPEC-005 v0.3.2 internally consistent with the new SPEC-002
  v1.5.1 dependency? Specifically, the §10.4 rewrite — does it
  still leave any ambiguity about whether RecoverLedger itself
  reads `MigrationState`?
- Does the SPEC-005 v0.3.2 change-log entry need to also mention
  that v0.3.1 stays the production-shipping version on the
  pre-v0.3.2 reconciliation tooling, and v0.3.2 is the contract
  for new tooling? Or is in-place version evolution sufficient
  (existing tooling presumed updated)?
- Is the "out-of-process tooling" scope sufficiently bounded that an
  implementer can tell what counts? Examples:
  - The harness reconciler (issue #226) — out-of-process? Yes.
  - A future `/admin/explorer/reconcile` HTTP endpoint that returns
    composite-key joins — out-of-process? It's a coordinator endpoint
    serving an external auditor — ambiguous.
- Does the registry-invariant clause foreclose future SPEC versions
  from RENAMING a `key` string (which would break consumers)? Is
  there a versioning path if a key REALLY must be renamed (e.g.
  deprecate-and-add)? Probably not in scope of v1.5.1, but flag.
- Does the SPEC text adequately distinguish "registry order is
  normative" (so the JSON array is stable) from "consumers MUST
  tolerate additional entries"?

## Severity rubric

- **CRITICAL**: contradiction with another normative SPEC remains.
- **HIGH**: ambiguity that would split conformant implementations.
- **MEDIUM**: cross-SPEC pointer gaps, scope-clarity issues.
- **LOW / NIT**: phrasing, versioning notes.

Bar for convergence: 0 CRITICAL / 0 HIGH / 0 MEDIUM.
