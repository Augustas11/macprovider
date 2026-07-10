# SPEC-018 v0.2.3 — Code Lane r4 Defensive Audit

**Date:** 2026-06-28
**Reviewer:** codex code lane
**Verdict:** READY TO LOCK

## Tally: C/H/M/m/Q

C=0 CRITICAL / H=0 HIGH / M=0 MEDIUM / m=0 minor / Q=0 questions

## Scope

Round-4 defensive code-lens audit of `specs/SPEC-018-agentic-tool-calling.md` v0.2.3 after Claude blind-spot absorption. Scope was limited to:

- Confirming the r3 code-lane READY TO LOCK verdict still holds against v0.2.3.
- Sweeping the v0.2.3 additions: §3.9 deletion, §10c.1 lock-amendment discipline, AC-48a/AC-48b split, AC-45 tuple-scoped auto-downgrade, AC-44 skew correction, AC-56 prompt aggregate cap, AC-46 reframe, §10a reader note, AC-number stability, and AC-25a SPEC-018 self-reading coverage.

Authoritative inputs reviewed:

- `specs/SPEC-018-agentic-tool-calling.md`
- `specs/SPEC-018-v0_2-code-r3-audit.md`
- `specs/SPEC-018-v0_2-blindspot-audit.md`
- `specs/SPEC-018-v0_2-blindspot-absorption-prompt.md`
- `specs/SPEC-018-v0_2_3-DRAFT-NOTES.md`
- `phase4-coordinator/internal/buyer/server.go` hash-routing citation targets

## r3 Verdict Regression Check

### H-3 residual — stale hash-routing citation: STILL CLOSED

- v0.2.3 location: `specs/SPEC-018-agentic-tool-calling.md:651`.
- Evidence: the stale `phase4-coordinator/internal/buyer/server.go:3743-3764` citation remains absent. §10a item #2 still cites `server.go:3291-3324` and `server.go:3873-3913`.
- Live-code spot check: `server.go:3291-3324` still contains `effectiveHashStatus` / `tier2ProviderExcludedStatus` candidate exclusion and no-provider route-error logic. `server.go:3873-3913` still contains `tier2ProviderExcluded*`, `effectiveHashStatus`, and `tier2.VerifyProviderHash`.

### M-1 — AC-46 unknown-hash semantics: STILL CLOSED

- v0.2.3 locations: AC-46 at `specs/SPEC-018-agentic-tool-calling.md:620`; §10d.0.1 at `:768`.
- Evidence: AC-46 is now stricter as a release contract: buyer-visible behavior is field-present plus JSON type `null | "^[a-f0-9]{64}$"`, while known-vs-unknown correctness is a provider-side self-test against the local `model_hash` subsystem. The field remains additive, under `usage`, non-canonicalized, and forbidden from driving v0.2 parser selection or settlement.
- Code-lens result: the r3 SDK-compatibility conclusion still holds because the wire shape did not become less compatible; the branch truth assertion moved to provider-local release evidence where it is mechanically checkable.

### M-2 — aggregate request caps and O(N) validation AC coverage: STILL CLOSED

- v0.2.3 locations: AC-50 through AC-56 at `specs/SPEC-018-agentic-tool-calling.md:628-640`; §10d.0 code table at `:755`; §10d.1 cap/failure rows at `:787` and `:809`.
- Evidence: AC-50 through AC-55 remain aligned with the §10d.1 cap rows and code table. AC-56 adds the new total decoded prompt aggregate cap, mapping >6 MiB to HTTP 413 `prompt_aggregate_too_large`.
- Code-lens result: the cap surface is now more complete and remains mechanically testable.

### `prompt_echo_blocked` public-code cleanup: STILL CLOSED

- v0.2.3 locations: change-log amendment at `specs/SPEC-018-agentic-tool-calling.md:29`; §10c amendment at `:686`; §10d.0 note at `:740`; v0.3 deferral at `:976`.
- Evidence: active §3.9 is deleted, AC-49 is absent, and §10d.0 now says v0.2.3 has no `prompt_echo_blocked` buyer-visible or internal guard-trigger code path. Remaining `prompt_echo_blocked` mentions are historical v0.2.2 change-log text, not active normative behavior.
- Code-lens result: no public-code or internal-code ambiguity remains for v0.2.3.

## v0.2.3 Fresh Sweep

### §3.9 deletion and AC-25a self-reading coverage: PASS

The deleted minimal echo guard no longer creates an implementation path that can self-DoS Cline when reading SPEC-018. AC-25a now requires the fixture workspace to include `specs/SPEC-018-agentic-tool-calling.md` as a possible `read_file` target and fails if SPEC-018 self-reading breaks a legitimate follow-up tool call (`:574`).

### §10c.1 lock-amendment discipline: PASS

§10c.1 names the amendment discipline, requires clause naming, rationale, replacement mitigation or residual-risk documentation, and an `AMENDED v<X.Y.Z>` paragraph at the original clause location. It also enumerates Amendment 1 and Amendment 2 and states AC-number stability (`:692-705`). Code-lens result: this is a spec-process guard, not runtime behavior, and it does not introduce an implementation ambiguity.

### AC-48a / AC-48b split: PASS

AC-48a gates the openai-python streaming-reader ecosystem, while AC-48b gates Cline v4.0.0 through `@ai-sdk/openai-compatible` / Vercel AI SDK and requires no dispatchable `tool_calls[]` reach Cline `AgentRuntime` after terminal final-close failure (`:624-626`). §10d.4 repeats that Cline is not openai-python and routes Cline behavior to AC-48b (`:828`). Code-lens result: the money-path question is now gated on the actual Cline stack.

### AC-45 per-(buyer, provider) auto-downgrade: PASS

AC-45 and §10d.4 key downgrade state by `(buyer, provider)`, set the threshold at 3 malformed streams in 5 minutes, require recovery after 10 clean minutes, and add AC-45c to prove one adversarial buyer does not downgrade other buyers on the same provider (`:618`, `:824-826`). Code-lens result: the state tuple and recovery behavior are concrete enough for implementation and tests.

### AC-44 skew-corrected timing: PASS

AC-44 defines required timestamps, an NTP-anchored `|t_provider - t_gateway| <= 100 ms` precondition verified via heartbeat, a measured `clock_skew_offset`, skew-corrected p95 formula, and fail conditions for missing skew verification or target misses (`:616`). Code-lens result: timing evidence is now mechanically auditable instead of crossing unsynchronized clock domains.

### AC-56 total decoded prompt aggregate cap: PASS

AC-56 uses the same decoded UTF-8 domain as §10d.1: `messages[].content`, assistant-history `tool_calls[].function.arguments`, and `role:"tool".content`. The error mapping is consistent across AC-56, §10d.0, and §10d.1: HTTP 413, code `prompt_aggregate_too_large`, non-retryable `invalid_request_error` (`:640`, `:755`, `:787`, `:809`). Code-lens result: no status/code/domain mismatch found.

## Fresh Findings

None.

## Verified Checks

- Re-read r3 code audit and confirmed all r3 closure claims still hold under v0.2.3.
- Confirmed active §3.9 and AC-49 are removed; remaining §3.9 references are historical/amendment references.
- Confirmed `prompt_echo_blocked` is absent from the active v0.2 code table and no longer names any v0.2.3 guard-trigger code path.
- Confirmed AC-48a/AC-48b split separates openai-python from Cline/Vercel AI SDK.
- Confirmed AC-45, AC-44, AC-46, and AC-56 align with their corresponding §10d normative text and error table rows.
- Re-checked live hash-routing citation targets in `phase4-coordinator/internal/buyer/server.go`.

## Verdict Justification

No r3 code-lane regression was found, and the v0.2.3 additions introduce no new CRITICAL, HIGH, or MEDIUM code-lens findings. The lock candidate remains mechanically implementable and testable from the code lane.

Result: **0 CRITICAL + 0 HIGH + 0 MEDIUM = READY TO LOCK from code lens**.
