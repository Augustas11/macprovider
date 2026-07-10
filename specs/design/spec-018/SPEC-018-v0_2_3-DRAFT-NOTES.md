# SPEC-018 v0.2.3 Draft Notes

Date: 2026-06-27
Purpose: Claude blind-spot absorption notes for `SPEC-018-agentic-tool-calling.md` v0.2.3.

## Absorptions

| # | Finding ID | What changed | Location | Loose interpretation |
|---:|---|---|---|---|
| 1 | Critic H-2 | Deleted the v0.2.1 minimal prompt-echo guard and AC-49. Added explicit v0.2.3 amendment text documenting no v0.2 prompt-echo mitigation, residual same-family echo risk, and v0.3 full-guard requirements. | Change log; deleted §3.9; deleted AC-49; §10c; §10c.1; §10d.0; §10d.8 | Treated Path (a) as an honesty amendment: no replacement mitigation in v0.2, only documented residual risk and v0.3 deferral. |
| 2 | Critic M-4 + Narrative M-2 | Promoted lock-amendment discipline to named §10c.1 with (a)-(d) rules, amendment log, AC-number stability, and future-v0.2-invariant coverage. | §10c.1 | Kept the rule process-focused and version-local rather than adding stricter approval gates not requested in the absorption prompt. |
| 3 | Critic H-1 | Split impossible "openai-python + Cline" AC-48 into AC-48a for openai-python and AC-48b for Cline via Vercel AI SDK `@ai-sdk/openai-compatible`; updated AC-39 and §10d.4 Cline note. | AC-39; AC-48a; AC-48b; §10d.4 | Left AC-43's openai-python baseline intact, with §10d.4 clarifying it is not the Cline-stack regression. |
| 4 | Critic H-3 | Changed streaming auto-downgrade from per-provider to per-(buyer, provider), with 3 malformed streams / 5 minutes threshold and 10-minute clean recovery; added AC-45c adversarial-buyer fixture. | AC-45; §10d.4 | Used the concrete threshold/recovery values from the prompt rather than the critic's alternative N/W/R recommendations. |
| 5 | Critic M-1 | Added NTP-anchored skew assumption, heartbeat verification, and skew-corrected p95 calculation for AC-44. | AC-44 | Treated SPEC-006 NTP sync as inherited precondition rather than introducing a new SPEC-018 deployment requirement. |
| 6 | Critic M-2 | Added 6 MiB total decoded prompt cap, `prompt_aggregate_too_large` code, failure table row, and AC-56. | AC-56; §10d.0; §10d.1 | Count domain follows prompt text exactly: decoded `messages[].content`, assistant-history arguments, and tool-result content. |
| 7 | Critic M-3 | Reframed `usage.macprovider_model_hash_observed` as buyer-visible field-present/type-correct behavior plus provider-side known/unknown self-test. | AC-46; §10d.0.1 | Preserved the field in `usage`; did not move extension placement because the requested absorption did not choose that optional critic minor. |
| 8 | Narrative H-1 | Inserted Quick orientation block immediately after Status and before Change log. | Header / Quick orientation | Adjusted the lock-amendment sentence to "2 invariants" so it does not conflict with the explicit constraint that §3.9 deletion is v0.2.1-content, not v0.1.5-content. |
| 9 | Narrative M-1 | Added v0.2.3 buyer-visible deltas led by "codex-converged + Claude-blind-spot-absorbed lock candidate." | Change log | Treated v0.2.3 as the new lock-candidate lede rather than rewriting historical v0.2.2 bullets. |
| 10 | Narrative M-3 | Added a reader note directly under §10a pointing to §10d.0 and §10c.1 for active v0.2.0+ scope and amendment status. | §10a | Did not rewrite §10a locked historical content beyond the requested reader note. |
| 11 | Critic m-1, m-2, m-3; Narrative m-1, m-2, Q-1; Critic Q-1, Q-2 | Added AC stability sentence, `messages[]` >256 user-actionable note, Status line update, AC-25a SPEC-018 self-reading requirement, and future-other-v0.2-invariant sentence in §10c.1. | Status; AC-22; AC-25a; §10c.1; §10d.1 | Treated Critic m-3 as fully covered by AC-44 skew correction and Narrative m-1 as closed by §3.9 deletion with no extra edit. |

## Verification Notes

- Active §3.9 section removed; remaining `§3.9` references are historical/amendment references only.
- AC-49 removed; AC-48 now has AC-48a/AC-48b suffixes and AC-50+ numbering remains stable.
- Money-path settlement language remains unchanged for final-close failure: `FaultBreakerQualifying`, zero provider-positive credits, no receipt, and no sticky-route success write.
