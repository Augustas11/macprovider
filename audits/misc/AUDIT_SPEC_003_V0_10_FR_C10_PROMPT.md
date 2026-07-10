# AUDIT prompt — SPEC-003 v0.10 FR-C10 pair_ot minting policy

Audit `specs/SPEC-003-open-onboarding.md` for the SPEC-003 v0.10
FR-C10 amendment. This is a spec audit, not an implementation audit.

## Inputs

- Target spec: `specs/SPEC-003-open-onboarding.md`
- Build prompt: `specs/BUILD_SPEC_003_V0_10_FR_C10_AMENDMENT_PROMPT.md`
  when available in this branch; if absent, use the operator-corpus copy at
  `/Users/augstar/macprovider-poc/specs/BUILD_SPEC_003_V0_10_FR_C10_AMENDMENT_PROMPT.md`
- Companion context:
  - `specs/SPEC-001-phase3-binary.md` v1.5 §6.5.1, §6.5.2,
    §6.7.2.1, and §6.12 for wire shape ownership
  - `specs/SPEC-002-coordinator.md` v1.3.5 §7.3 and auth/token-store
    surfaces
  - `specs/SPEC-014-v0.2-github-auth.md` as downstream consumer context
    only; if absent in this branch, use the operator-corpus copy at
    `/Users/augstar/macprovider-poc/specs/SPEC-014-v0.2-github-auth.md`

## Audit Goal

Return findings by severity: CRITICAL, HIGH, MEDIUM, LOW. The gate passes
only at 0 CRITICAL / 0 HIGH / 0 MEDIUM. Prefer precise file references and
quote only short snippets.

## Required Checks

1. Scope: normative edits are limited to the SPEC-003 header/dependency
   bump, the v0.10 change-log block, and the additive FR-C10 family under
   §4. Existing FR-C1 through FR-C9, FR-D*, acceptance criteria, and other
   sections are not semantically changed.
2. Prerequisite: SPEC-001 is v1.5 on the audited branch and contains
   §6.5.1 (`pair_ot` / `claim_url` on `hello_ack`), §6.7.2.1 (accepted
   `auth_response` placement), §6.12 (`ownership_event` /
   `ownership_status`), and §6.5.2 (`needs_claim`).
3. FR-C9 compatibility: FR-C10 does not change when or how
   `assigned_provider_token` is minted, persisted, or gated. With
   `GITHUB_OAUTH_ENABLED=false` or unset, FR-C9 behavior is unchanged.
4. Emission gate completeness: first-connect `pair_ot` / `claim_url`
   requires all three conditions: feature flag true, no ownership row
   exists for v0.10, and the same connect minted a fresh FR-C9 provider
   token.
5. Reconnect discipline: reconnects of already-tokened providers do not
   receive `pair_ot` / `claim_url`; the only reconnect signal is
   `needs_claim: true` on the SPEC-001 ownership status carrier when the
   provider is tokened but unowned.
6. Wire-shape boundary: SPEC-003 cites SPEC-001 v1.5 for field and frame
   shape. It does not author JSON schemas, invented frame types, or a
   binary-to-coordinator `request_pair_ot` field.
7. SPEC-014 boundary: SPEC-014 is described as the downstream consumer.
   References to its routes, tables, config names, and migration behavior
   are informative context only and do not make SPEC-014 a normative
   upstream dependency of SPEC-003.
8. Security: `pair_ot` remains single-use, 600 seconds, CSPRNG-generated,
   and non-credential. Ownership lookup, FR-C9 provider-token minting, and
   pair-OT minting are one transactional decision where required. Failed
   pair-OT minting degrades to plain FR-C9 admission without leaking partial
   pairing material.
9. Operator-key isolation: FR-C10 introduces no operator-key-authenticated
   browser or buyer path. Storage primitives are internal coordinator APIs.
10. Bind-boundary discipline: FR-C10 may name `BurnPairOT` as a storage
   primitive, but it does not republish downstream HTTP bind transaction
   details such as session pending-hints or cross-account conflict behavior.
11. Prose style: wording, table/list density, MUST/SHOULD/MAY usage, and
   storage-primitive style match FR-C9.1 through FR-C9.4.
12. Test obligations: FR-C10.5 covers feature-flag-off, first-tokenless
   emission, reconnect `needs_claim`, bound-provider suppression,
   mint-failure graceful degradation, and bound-event delivery/queueing.

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
