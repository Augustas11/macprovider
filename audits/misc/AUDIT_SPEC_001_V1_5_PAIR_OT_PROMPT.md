# AUDIT prompt — SPEC-001 v1.5 pair_ot / claim_url / ownership_event amendment

Audit `specs/SPEC-001-phase3-binary.md` for the SPEC-001 v1.5
pairing-wire amendment. This is a spec audit, not an implementation audit.

## Inputs

- Target spec: `specs/SPEC-001-phase3-binary.md`
- Build prompt: `specs/BUILD_SPEC_001_V1_5_PAIR_OT_AMENDMENT_PROMPT.md`
  when available in this branch; if absent, use the operator-corpus copy at
  `/Users/augstar/macprovider-poc/specs/BUILD_SPEC_001_V1_5_PAIR_OT_AMENDMENT_PROMPT.md`
- Companion context:
  - `specs/SPEC-003-open-onboarding.md` FR-C9 and the planned v0.10 FR-C10
    emission-policy ownership
  - `specs/SPEC-014-v0.2-github-auth.md` §4, §5.3, and §6.4 as downstream
    consumer context only; if absent in this branch, use the operator-corpus
    copy at `/Users/augstar/macprovider-poc/specs/SPEC-014-v0.2-github-auth.md`
  - `specs/SPEC-002-coordinator.md` §7.8 for the coordinator-side v2
    auth handshake shape

## Audit Goal

Return findings by severity: CRITICAL, HIGH, MEDIUM, LOW. The gate passes
only at 0 CRITICAL / 0 HIGH / 0 MEDIUM. Prefer precise file references and
quote only short snippets.

## Required Checks

1. Scope: normative edits are limited to SPEC-001 v1.5 header/change log and
   the additive wire surfaces under §6.5, §6.7, and §6.12. No implementation
   files or unrelated spec sections are changed.
2. Compatibility: every new field is optional, absent-field behavior is
   explicitly v1.4-equivalent, and old binaries/coordinators remain safe.
3. Wire shape: `pair_ot`, `claim_url`, `ownership_event`, `ownership_status`,
   and `needs_claim` have clear JSON names, JSON types, requiredness/defaults,
   and examples.
4. Security: no rejected auth response or `auth_challenge` can carry usable
   pairing material; `pair_ot` is described as non-credential pairing material,
   not a provider credential.
5. Boundary discipline: SPEC-001 defines wire shape only. SPEC-003 v0.10
   FR-C10 owns emission policy. SPEC-014 v0.2 is described only as a downstream
   consumer, not as an upstream normative dependency.
6. Carrier discipline: `needs_claim` is C->P on `ownership_status`, not P->C
   on heartbeat and not overloaded onto `ownership_event`.
7. Negative surface: no `request_pair_ot` or other binary-to-coordinator
   pairing-refresh field is introduced.
8. Prose style: section numbering, tables, examples, and RFC-style language
   match the surrounding SPEC-001 style.
9. Citation hygiene: no stale code line numbers are introduced. Existing code
   references are either already present or expressed without brittle line
   numbers.

## Output Format

```
Verdict: PASS | FAIL
Totals: C=<n> H=<n> M=<n> L=<n>

Findings:
- [SEVERITY] <id> <file:line> — <title>
  Evidence: ...
  Impact: ...
  Recommendation: ...

Residual risks:
- ...
```
