# SPEC-019 v0.1.4 round-5 defensive audit -- narrative

Round-5 defensive audit of `specs/SPEC-019-structured-output.md` v0.1.4 after
round-4 absorption. The lens was lock readiness: confirm the §7
`Content-Encoding: identity` carve-out, AC fixture consistency, paired SDK
fixtures, rejected-keyword cleanup, and changelog traceability.

## Aggregate tally

| Lane | C | H | M | m | Q | Verdict |
|---|---|---|---|---|---|---|
| codex architect | 0 | 0 | 1 | 0 | 0 | FIX REQUIRED |
| codex code | 0 | 0 | 0 | 0 | 0 | READY TO LOCK |
| codex security | 0 | 0 | 0 | 1 | 0 | READY TO LOCK |
| codex product-design | 0 | 0 | 0 | 0 | 0 | READY TO LOCK |
| claude critic | 0 | 0 | 0 | 0 | 0 | READY TO LOCK |
| claude narrative | 0 | 0 | 0 | 1 | 0 | READY TO LOCK |
| **r5 TOTAL** | **0** | **0** | **1** | **2** | **0** | **FIX REQUIRED** |

## Lock signal

Five of six lanes returned READY TO LOCK at v0.1.4. Code, security,
product-design, critic, and narrative found no blocking issue. The only
blocking item is a fixture-wording inconsistency in AC-28a, not a new
architecture, money-path, SDK, or security finding.

This pattern matches the SPEC-018 v0.1.4 polish phase: the substantive design
had already converged, and the final round found one acceptance-criteria text
edge that needed to be made unambiguous before lock.

## Single MEDIUM

1. **Architect M-1** -- §7 was fixed in r4 to accept omitted
   `Content-Encoding` and explicit no-op `Content-Encoding: identity`, while
   rejecting every normalized value that is not exactly `identity`. AC-28a
   still began with "any request with a `Content-Encoding` header returns HTTP
   415" and ended by accepting `identity`. A fixture implementer could cite the
   same AC for either an identity-rejection or identity-acceptance test.

Fix: rewrite AC-28a so it defines one coherent fixture: reject when the
normalized field value is not exactly `identity`; accept omitted header and
explicit `identity` after case-insensitive, whitespace-tolerant normalization.
Add adversarial rows for `gzip`, `deflate`, `br`, empty-after-trim,
whitespace-surrounded `identity`, case variants, and multi-value
`identity, gzip` rejection.

## Minor findings

- Security carried one minor posture note: keep the `identity` exception tight
  enough that compressed codings cannot be smuggled into v0.1.0. The AC-28a
  rewrite closes this by requiring an exact normalized value.

- Narrative carried one minor readability issue in §10 bullet shape. It was
  non-blocking in r4 and remains non-blocking at lock posture; no r5 body edit
  is required.

## Recommendation

Absorb r5 into v0.1.5 with the single AC-28a wording fix and matching §12
metadata. Do not reopen implementation, runbook, or broader documentation
scope. After absorption, fire architect-only r5 closure against v0.1.5 to
confirm the expected 0/0/0 result before locking SPEC-019 v0.1.
