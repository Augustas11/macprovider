# #1689 round-4 fix check (narrow, closure verification)

Method: first-party software-correctness review of our own code; read source/tests/SPEC text; describe failure scenarios in prose with file:line; do not author exploit payloads.

Repo worktree: `/Users/augstar/macprovider-1689-status`, branch `feat/1689-honest-status`, base `origin/main` = `57022da8`. Full diff: `git diff 57022da8...HEAD`. Context for the whole epic: `audits/2026-09-23-1689-operator-ux/_SHARED_CONTEXT.md`.

An independent round-4 review found these; this revision claims to fix them. Verify each fix is real, complete, and introduces no new defect. Scope is these fixes and code they touch — not a full re-review.

1. MEDIUM A (regression): new context writers ignored SPEC-028's draft-model context cap, so a provider with `draft_model` set would fail serve startup (`runSpecDecodeCapacityPreflight` exits 2 on override > draft cap, and on >1 slot). Claimed fix: single `ProviderCapacity.draftModelContextLimit(physicalMemoryGB:draftModel:)` (ProviderStatus.swift) used by `AutotuneRecommendHardware.recommendedMaxContext` (required `draftModel:`), `AutotuneCommand.recommendationCoreForConfig` (also pins maxBatch=1 with a draft model), `ModelsAdoptRecommendationCommand.validateSignedContextAuthority`, `provider context set` (refuse above cap before any write), `provider context explain` (Draft cap line, under-use math), `ModelSwitchContext.recomputedContext`, `ModelsSwitchCommand.contextNotice`. SPEC-023 R018 item 8 + AC-47, SPEC-001 FR-20b. Check: is there ANY remaining writer/recompute path that can emit a context or slot count serve's preflight would reject with a draft model configured? Is the draft model resolved from the right config (the adopting/target config, not a stale one)? Does a blank draft_model count as none everywhere consistently?
2. MEDIUM B: `provider context explain` / `rollback` used the invoking shell environment as config. Claimed fix: `ProviderContextWorkflow.loadConfig()` reads the file with an empty environment; the shell's `MACPROVIDER_MAX_CONTEXT_OVERRIDE` shown only as a labeled overlay line. Check no remaining path mixes the shell env into file-derived values or rollback expectations.
3. LOW C: switch-back labelled `recommendation_adoption` → `ModelRuntimeAdoptionServeKnobs.contextSource` + `configuredMaxContextTokens`; switch back reports `recommendation_apply`. Check adoption semantics unchanged.
4. LOW D: SPEC-001 FR-20 rewritten to match code (serve probe 8 tokens, self-test 4; failed probe ⇒ 0 and serve keeps running). Check against code.

Verification claimed: full Swift suite 3264 / 0 failures (bounded, temp roots), spec governance, contract lock, spec index check+lint, test-dist — all pass. No Go changed.

Output: findings as CRITICAL / HIGH / MEDIUM / LOW / INFO with file:line and a concrete failure scenario; per-fix verdict (closed / partially closed / not closed); final line exactly `GATE: <n> CRITICAL, <n> HIGH, <n> MEDIUM`.
