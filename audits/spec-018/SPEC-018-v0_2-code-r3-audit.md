# SPEC-018 v0.2.2 — Code Lane r3 Audit

**Date:** 2026-06-27
**Reviewer:** codex code lane
**Verdict:** READY TO LOCK

## Tally: C/H/M/m/Q

C=0 CRITICAL / H=0 HIGH / M=0 MEDIUM / m=0 minor / Q=0 questions

## Scope

Round-3 code-lens audit of `specs/SPEC-018-agentic-tool-calling.md` v0.2.2 after r2 absorption. Scope was limited to v0.2.2 additions, r2 closure items, and live-code re-verification for the r2 H-3 hash-routing citation.

Authoritative inputs reviewed:

- `specs/SPEC-018-agentic-tool-calling.md`
- `specs/SPEC-018-v0_2-code-r2-audit.md`
- `specs/SPEC-018-v0_2-r2-audit.md`
- `specs/SPEC-018-v0_2-r2-absorption-prompt.md`
- `specs/SPEC-018-v0_2_2-DRAFT-NOTES.md`
- `phase4-coordinator/internal/buyer/server.go`

## Prior r2 Finding Closure

### H-3 residual — stale hash-routing citation: CLOSED

- v0.2.2 location: `specs/SPEC-018-agentic-tool-calling.md:633`.
- Evidence: the stale `phase4-coordinator/internal/buyer/server.go:3743-3764` citation is gone. §10a item #2 now cites `phase4-coordinator/internal/buyer/server.go:3291-3324` for hash-verification routing exclusion/eligibility and `phase4-coordinator/internal/buyer/server.go:3873-3913` for helper predicates.
- Live-code check: `server.go:3291-3324` contains the `effectiveHashStatus` / `tier2ProviderExcludedStatus` candidate exclusion and no-provider route-error branch. `server.go:3873-3913` contains `tier2ProviderExcluded*`, `effectiveHashStatus`, and `tier2.VerifyProviderHash`.
- Code-lens result: citation drift is closed.

### M-1 — AC-46 unknown-hash semantics: CLOSED

- v0.2.2 locations: AC-25a at `specs/SPEC-018-agentic-tool-calling.md:560`; AC-46 at `:606`; §10d.0.1 at `:730`.
- Evidence: AC-46 now requires every v0.2 provider response to include `usage.macprovider_model_hash_observed` with JSON type `null | "^[a-f0-9]{64}$"`. It has explicit known-hash and unknown-hash fixtures, rejects missing/non-hex values, forbids `null` when a provider hash is known, and keeps the field out of SPEC-015 canonical output binding. AC-25a requires transcript capture and asserts Cline does not branch on known-vs-unknown values. §10d.0.1 matches the same contract.
- SDK check: `openai==2.44.0` `ChatCompletion.model_validate(...)` accepts `usage.macprovider_model_hash_observed` as an additive `CompletionUsage` extra field when the value is `null` and when the value is 64 lowercase hex.
- Code-lens result: unknown-hash behavior is mechanically testable and OpenAI-client-compatible.

### M-2 — aggregate request caps and O(N) validation AC coverage: CLOSED

- v0.2.2 locations: AC-50 through AC-55 at `specs/SPEC-018-agentic-tool-calling.md:614-624`; §10d.0 codes at `:713-719`; §10d.1 caps and failure rows at `:744-771`.
- Evidence: AC-50 through AC-54 cover each aggregate cap named in §10d.1: raw request body > 4 MiB, aggregate tool-result content > 1 MiB, aggregate assistant-history arguments > 2 MiB, messages length > 256, and total assistant-history tool calls > 128. AC-55 covers linear cross-message validation with a 256-message / 128-tool-call pass fixture plus a duplicate-ID adversarial fixture and an explicit "not more than 256 x 128 pairwise comparisons or equivalent repeated scans" failure criterion.
- Code-lens result: aggregate request caps and validation complexity are now release-gated by concrete ACs.

## Fresh r3 Code-Lens Sweep

### AC-50 through AC-55 wire-shape consistency: PASS

- AC-50 matches §10d.1 raw body cap and failure row: > 4 MiB maps to HTTP 413 `request_body_too_large`. SPEC-006 owns a stricter gateway default and uses `request_too_large`, but SPEC-018's v0.2 provider/coordinator row remains single-valued in §10d.0/§10d.1.
- AC-51 matches §10d.1 aggregate decoded tool-result content cap: > 1 MiB maps to HTTP 413 `tool_results_aggregate_too_large`.
- AC-52 matches §10d.1 aggregate assistant-history argument cap: > 2 MiB maps to HTTP 413 `tool_call_arguments_aggregate_too_large`.
- AC-53 matches §10d.1 maximum `messages[]` length: > 256 maps to HTTP 400 `messages_too_long`.
- AC-54 matches §10d.1 maximum assistant-history `tool_calls[]`: > 128 maps to HTTP 400 `too_many_tool_calls`.
- AC-55 matches §10d.1's O(messages[] + tool_calls[]) validation requirement and §10d.6's canonical `duplicate_tool_call_id` code.

### HTTP code mapping: PASS

The new cap mappings are internally consistent:

- Byte-size caps use HTTP 413: AC-50, AC-51, AC-52.
- Count/shape validation caps use HTTP 400: AC-53, AC-54, AC-55 duplicate-ID failure.
- All new public codes are present in §10d.0 as non-retryable `invalid_request_error` values.

### AC-55 O(N) fixture concreteness: PASS

AC-55 is concrete enough for implementation gating. It names the pass fixture size, adversarial duplicate-ID case, canonical failure code, and an operation-counter/benchmark-threshold mechanism. The explicit prohibition on more than `256 x 128` pairwise comparisons gives test authors a measurable upper bound against O(N^2) repeated scans.

### `prompt_echo_blocked` public-code cleanup: PASS

- §10d.0 explicitly separates buyer-visible error-envelope codes from internal plain-content fallback reasons and does not enumerate `prompt_echo_blocked`.
- §3.9, AC-49, and §10d.1 consistently describe prompt-echo firing as plain assistant content with no buyer-visible HTTP/SSE error envelope, while allowing `prompt_echo_blocked` only as an internal log code.
- No AC now requires `prompt_echo_blocked` as a public error-envelope code.

### `usage.macprovider_model_hash_observed: null` compatibility: PASS

- The SPEC's `null | lowercase-hex` contract is valid JSON schema shape for an additive field.
- Local verification installed `openai==2.44.0` into `/tmp/openai244` and parsed a `ChatCompletion` fixture with `usage.macprovider_model_hash_observed: null`; parsing succeeded and the extra field round-tripped through `CompletionUsage.model_dump()`. The same fixture also parsed with a 64-character lowercase hex value.

## Fresh Findings

None.

## Verified Citations And Checks

- Confirmed no stale `server.go:3743-3764` citation remains in `specs/SPEC-018-agentic-tool-calling.md`.
- Verified live hash-routing citation replacements against `phase4-coordinator/internal/buyer/server.go:3291-3324` and `:3873-3913`.
- Verified AC-46 / §10d.0.1 / AC-25a use a single mandatory-field `null | hex` contract.
- Verified AC-50 through AC-55 align with §10d.1 cap definitions and §10d.0 public code table.
- Verified `prompt_echo_blocked` is absent from the §10d.0 buyer-visible code table and appears only as internal-log/plain-content-fallback language.
- Verified `openai==2.44.0` tolerates the additive `usage.macprovider_model_hash_observed` field with both `null` and lowercase-hex values.

## Verdict Justification

All r2 code-lane blockers are closed, and the r3 code-lens sweep found no new CRITICAL, HIGH, or MEDIUM issues. AC-50 through AC-55 are mechanically testable, HTTP status/code mappings are coherent, `prompt_echo_blocked` is no longer a public error-envelope code, and the AC-46 `null` sentinel is both schema-valid and tolerated by the pinned OpenAI Python SDK.

Result: **0 CRITICAL + 0 HIGH + 0 MEDIUM = READY TO LOCK from code lens**.
