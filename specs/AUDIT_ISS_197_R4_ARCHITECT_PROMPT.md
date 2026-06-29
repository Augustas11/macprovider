You are reviewing branch `spec/iss-197-v1-4-3-clarifications` of the macprovider repo
(working tree `/Users/augstar/macprovider-iss197`), ARCHITECT lane, ROUND 4.

R3 returned 2 MEDIUM + 2 LOW. R4 fixes:

1. (R3 MEDIUM #1: SPEC-005 §1.4 still labeled v1.5.0) Updated to
   `**SPEC-002 v1.5.1:**` plus a new bullet enumerating the per-key
   migration-state surface and the closing-the-books fail-closed MUST.

2. (R3 MEDIUM #2: scope by data-surface contract, not process
   placement) Rewrote the operational-binding paragraph in SPEC-002
   §11 v1.5.1 AND the change-log entry AND the SPEC-005 v0.3.2
   change-log entry to use the data-surface phrasing:
   - **In scope** = any reconciliation surface that performs
     closing-the-books joins between coordinator `request_log` and
     gateway `usage_events` / `audit_events` by composite key —
     out-of-process harnesses AND any future coordinator-hosted
     endpoint exposing the same join.
   - **Out of scope** = coordinator's in-process AttemptN paths
     (`hotpath.go`, `recovery.go`, `endpoints.go`
     `/admin/ledger/reconcile`) which use single-table SQLite `IS`
     clustering.

3. (R3 LOW: deprecate-and-add escape hatch) Added the deprecation
   path to the registry-invariant clause: when a `key` must be
   replaced, deprecate-and-add for one minor SPEC version, then drop
   the old in a later version.

4. (R3 LOW: array order normative) Added explicit "the JSON `keys`
   array order is **normative**" sentence in the registry-invariant
   clause.

## Verify

- Does the SPEC-002 §11 + change-log + SPEC-005 v0.3.2 phrasing
  agree on the data-surface scope? Look for residual "out-of-process"
  language that wasn't replaced.
- Future coordinator-hosted closing-the-books endpoint — is the
  SPEC clear that it IS in scope, even though it lives in the
  coordinator process?
- Does the deprecate-and-add escape hatch handle the case where the
  new `key` covers the SAME composite columns as the old `key` but
  with a different name? Specifically the SPEC says "keep emitting
  the old key for one minor SPEC version" — does that mean both
  keys point to the same index (and indicate the same state), or
  the old key emits a deprecated marker and the new one is the live
  one? Probably the latter, but worth clarifying.
- Is the array-order-normative clause sufficient for stable
  enumeration, or does the SPEC also need to require that consumers
  may rely on the i-th entry being a particular `key` (which is
  stronger)?
- Cross-spec: SPEC-006 (gateway forward contract), SPEC-007
  (explorer) — do they need v1.5.1 dependency updates, or are they
  unaffected (since the new MUST applies only to closing-the-books
  reconciliation, which neither does)?

## Severity rubric

- **CRITICAL**: contradiction with another SPEC remains.
- **HIGH**: ambiguity that splits implementations.
- **MEDIUM**: cross-SPEC pointer / scope gaps.
- **LOW / NIT**: phrasing, edge-case clarifications.

Bar for convergence: 0 CRITICAL / 0 HIGH / 0 MEDIUM.
