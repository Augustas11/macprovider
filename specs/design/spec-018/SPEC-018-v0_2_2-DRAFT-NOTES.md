# SPEC-018 v0.2.2 Draft Notes

Date: 2026-06-27
Purpose: Round-2 absorption notes for `SPEC-018-agentic-tool-calling.md` v0.2.2.

## Absorptions

| # | Finding ID | What changed | Location | Loose interpretation |
|---:|---|---|---|---|
| 1 | Code M-1 / Security m-2 / Product-design MEDIUM-1 | Standardized AC-46 unknown-hash semantics on Option A: every v0.2 response includes `usage.macprovider_model_hash_observed`; known values are lowercase SHA-256 hex and unknown values are `null`. AC-25a transcript evidence now records the field and asserts Cline does not branch on known vs unknown values. | Change log; AC-25a; AC-46; §10d.0.1 | Treated the field as mandatory observation evidence, not a v0.2 registry/security authority. |
| 2 | Architect M-1 | Removed `prompt_echo_blocked` from the buyer-visible v0.2 error-envelope code table and clarified that prompt-echo guard firing returns normal plain assistant content with no synthesized `tool_calls[]`; `prompt_echo_blocked` is only an internal log code in v0.2. | §3.9; AC-49; §10d.0; §10d.1 | Chose the plain-content fallback interpretation already implied by §3.9 and AC-49. |
| 3 | Code H-3 residual | Replaced stale `phase4-coordinator/internal/buyer/server.go:3743-3764` hash-routing citation with verified current ranges for exclusion/eligibility and helper predicates. | §10a item #2 | Kept the historical §10a paragraph intact because the current live ranges still support the infrastructure citation. |
| 4 | Code M-2 | Added AC-50 through AC-55 for aggregate raw request size, aggregate tool-result content bytes, aggregate assistant-history argument bytes, maximum message count, maximum assistant-history tool-call count, and linear `tool_call_id` validation. Added corresponding public v0.2 error codes and §10d.1 failure rows. | AC-50-AC-55; §10d.0; §10d.1 | Counted AC-55 as the validation-performance companion to the aggregate cap ACs rather than a separate strategic deliverable. |
| 5 | Architect m-1 | Added an explanatory §10d note that non-sequential subsection numbering mirrors design-deliverable identifiers from `SPEC-018-v0_2-design-synthesis.md`. | §10d intro | No normative behavior change; reader-orientation only. |
| 6 | Architect m-1 cosmetic | Added a §3.8 editorial note explaining why additive §3.8 physically precedes locked §3.7 and giving the logical reading order. | §3.8 | Avoids moving locked v0.1.5 content. |
| 7 | Security m-1 | Added an inheritance note for `invalid_tools`: it remains a stable pre-existing SPEC-001 / SPEC-002 request-validation code but is not duplicated in the v0.2.X-specific table. | §10d.0 | Chose the "inherited note" option instead of adding `invalid_tools` to the v0.2-specific table to preserve cross-SPEC ownership. |

## Verification Notes

- Live citation check read `phase4-coordinator/internal/buyer/server.go:3291-3324` and `:3873-3913`; those ranges describe the v0.2-relevant hash-status exclusion path and helper predicates.
- Existing AC-1 through AC-49 numbering was preserved. New coverage is appended as AC-50 through AC-55.
- Locked v0.1.5 content was not moved; the §3.8 note documents the intentionally surprising document order instead.
