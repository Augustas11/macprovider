# AUDIT_SPEC_015_v0_4_IMPL_FULL_ARCHITECT_PROMPT

You are the Codex architecture audit lane for the full SPEC-015 v0.4.2
implementation.

Worktree: `/Users/augstar/macprovider-impl-spec-015-v0-4`
Branch: `impl/spec-015-v0-4-settlement-receipts`

Scope: read-only architecture review of the full current worktree diff for
`BUILD_SPEC_015_v0_4_SETTLEMENT_RECEIPTS_IMPL_PROMPT.md` Steps 1 through 8.
Do not modify files.

Required reading:

- `CLAUDE.md`
- `specs/BUILD_SPEC_015_v0_4_SETTLEMENT_RECEIPTS_IMPL_PROMPT.md`
- `specs/SPEC-015-receipts.md` v0.4.2, especially §N and AC-43 through AC-71
- `specs/SPEC-015-v0-4-audit.md`
- `specs/SPEC-022-verified-model-settlement.md`
- `specs/BUILD_SPEC_022_VERIFIED_MODEL_SETTLEMENT_IMPL_PROMPT.md`
- `implementation-notes-spec-015-v0-4.md`
- `specs/AUDIT_SPEC_015_v0_4_IMPL_STEP_{1,2,3,4,5,6,7,8}.md` where present
- `scripts/verify-spec015-v04-step8.sh`

Architecture questions:

1. Do Steps 1-8 compose into a coherent product prerequisite for SPEC-022:
   signed v0.4 receipt, route-time catalog/model snapshot, provider receipt
   key, output/usage evidence, verifier outcome, stored verdict, diagnostics,
   and executable cross-phase acceptance?
2. Are Swift provider, coordinator, gateway, and phase7 verifier boundaries
   clean, with no illegal `internal` coupling and no ambiguous ownership of
   canonicalization or settlement evidence?
3. Is streaming first-class architecturally, including `[DONE]`, trailers/end
   frames, OpenAI-compatible body semantics, terminal timestamp ownership, and
   partial-prefix handling?
4. Are retry/failover attempts modeled consistently with zero-based
   `attempt_n`, provider-attempt output prefixes, and duplicate/overlap
   prevention?
5. Does the state machine expose enough authorization evidence for SPEC-022
   without prematurely implementing money movement?
6. Are model-verification limits expressed truthfully in product surfaces and
   diagnostics so buyers can trust what is actually proven?
7. Are AC-43 through AC-71 and the full Step 8 acceptance target strong enough
   to prevent this implementation from becoming a checklist that can pass while
   cross-phase behavior regresses?
8. Identify the remaining E2E testing gap, if any, between current test
   coverage and a real buyer-to-provider network run.

Report architectural defects or material design/test gaps. Use severity
Critical, High, Medium, Low. Include file/line evidence, impact on SPEC-015 or
SPEC-022, and exact remediation. End with:

Critical: N
High: N
Medium: N
Low: N

Then list validation you ran.
