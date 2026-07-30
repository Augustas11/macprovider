# SPEC-018 v0.2.2 — r2 Absorption Prompt

## Your task

Absorb 7 round-2 audit findings into `specs/SPEC-018-agentic-tool-calling.md`, bumping the SPEC to v0.2.2.

All r2 findings are MEDIUM-floor or below (Security lane already LOCKED). No strategic decisions — pure mechanical/editorial absorption.

## Authoritative inputs

1. `specs/SPEC-018-agentic-tool-calling.md` — current v0.2.1 SPEC.
2. `specs/SPEC-018-v0_2-r2-audit.md` — r2 narrative covering all 4 lanes.
3. Per-lane r2 audit files:
   - `specs/SPEC-018-v0_2-architect-r2-audit.md`
   - `specs/SPEC-018-v0_2-code-r2-audit.md`
   - `specs/SPEC-018-v0_2-security-r2-audit.md` (READY TO LOCK; review m-1 + m-2 as observation only)
   - `specs/SPEC-018-v0_2-product-design-r2-audit.md`
4. Live repo at `phase4-coordinator/internal/buyer/server.go` for citation re-verification.

## 7 absorptions

### Convergent edits (multi-lane)

**1. AC-46 unknown-hash semantics — fix the inconsistency.** Pick **Option A**: always include `usage.macprovider_model_hash_observed`; use `null` sentinel when unknown.

- Update AC-46 (`specs/SPEC-018-agentic-tool-calling.md:595`): require every v0.2 provider response to include `usage.macprovider_model_hash_observed`. JSON type is `null | "^[a-f0-9]{64}$"` (lowercase hex SHA-256). Missing field → fail. Non-null non-hex → fail. `null` → valid only when provider has no known hash (e.g., model_hash subsystem not yet wired for that provider).
- Update §10d.0.1 (`specs/SPEC-018-agentic-tool-calling.md:695-697`): align with AC-46 — every v0.2 response includes the field; value is null when unknown, hex when known. Non-canonicalized, observation-only. Buyers MUST NOT branch on the value in v0.2; macprovider release evidence + logs MAY capture it for diagnostics and v0.3 registry preparation.
- Add a sentence to §10d.0.1: "Cline and other OpenAI clients need not act on this field in v0.2; macprovider release evidence and logs capture it for diagnostics and v0.3 registry preparation."
- Add AC-46 fixtures: (a) known-hash case → field is lowercase hex; (b) unknown-hash case → field is `null`. Both pass.
- Update AC-25a transcript schema (`specs/SPEC-018-agentic-tool-calling.md:549-553`) to require capturing `usage.macprovider_model_hash_observed` per response. Add assertion: Cline does not branch on the value (i.e., AC-25a session succeeds whether known or unknown).

**2. `prompt_echo_blocked` code-domain disambiguation.** v0.2 must clearly separate buyer-visible error envelope codes from internal plain-content fallback reasons.

- Remove `prompt_echo_blocked` from the §10d.0 stable v0.2 error-envelope code table (`specs/SPEC-018-agentic-tool-calling.md:660-693`).
- Add explicit note to §10d.0 above the code table: "The codes in this table are buyer-visible HTTP/SSE error envelope codes. Internal plain-content fallback reasons (such as the prompt-echo guard firing in §3.9) are NOT buyer-visible error codes in v0.2 — they manifest as the absence of synthesized `tool_calls[]` plus normal plain assistant content. v0.3 will expose these as a structured `usage.macprovider_malformed_tool_call.reason` enum."
- Update §3.9 + AC-49 (`specs/SPEC-018-agentic-tool-calling.md:290-294`, `:601`): clarify that prompt-echo-guard firing produces NO buyer-visible error envelope in v0.2 — only plain-content fallback + internal log code `prompt_echo_blocked`.
- Update §10d.1 failure table (`specs/SPEC-018-agentic-tool-calling.md:721-735`): change the prompt-echo row entry from a buyer-visible code to "Plain-content fallback (no buyer-visible error); internal log code `prompt_echo_blocked`."

### Mechanical edits (single-lane)

**3. Code H-3 residual — fix stale `server.go:3743-3764` citation in §10a v0.2 paragraph.**

Read live `phase4-coordinator/internal/buyer/server.go:3291-3324` and `:3873-3913` to confirm they describe the v0.2-relevant hash-routing exclusion path. Update the §10a paragraph at `specs/SPEC-018-agentic-tool-calling.md:610`:
- Replace `phase4-coordinator/internal/buyer/server.go:3743-3764` with the verified current ranges.
- OR strip the live-code citation from the historical §10a paragraph and add a forward-pointer: "For v0.2.0/v0.2.1 routing semantics, see §10d.0.1 and AC-46. Live-code references for the v0.2 model-hash observation path are deferred to v0.3 IMPL."

Pick whichever is more accurate after reading the live repo.

**4. Code M-2 — add AC coverage for aggregate request caps.**

Add new ACs (in the AC list after AC-49):

- **AC-50:** request body raw bytes > 4 MiB → HTTP 413 `request_body_too_large` (or aligned with SPEC-006 buyer-API code).
- **AC-51:** sum of all `role:"tool".content` UTF-8 byte lengths > 1 MiB → HTTP 413 `tool_results_aggregate_too_large`.
- **AC-52:** sum of all assistant-history `tool_calls[].function.arguments` UTF-8 byte lengths > 2 MiB → HTTP 413 `tool_call_arguments_aggregate_too_large`.
- **AC-53:** `messages[]` array length > 256 → HTTP 400 `messages_too_long`.
- **AC-54:** sum of all assistant `tool_calls[]` entries across all messages > 128 → HTTP 400 `too_many_tool_calls`.
- **AC-55:** cross-message tool_call_id validation MUST be O(messages[] + tool_calls[]). Test fixture: a request with 256 messages including 128 assistant tool calls (each with unique IDs) MUST complete validation in bounded time (specify constant bound or describe as "linear time profile"). Adversarial fixture with 128 duplicate IDs MUST fail with `duplicate_tool_call_id` AND validation MUST NOT iterate >256 × 128 operations (i.e., NOT O(N²)).

Add error codes (`request_body_too_large`, `tool_results_aggregate_too_large`, `tool_call_arguments_aggregate_too_large`, `messages_too_long`, `too_many_tool_calls`) to the §10d.0 stable v0.2 error-envelope code table. All non-retryable.

**5. Architect m-1 — §10d subsection numbering explanatory note.**

Add a sentence at the beginning of §10d (immediately after the "v0.2.0 reader note" and the "Why Cline gates v0.2" paragraph): "§10d subsection numbers (§10d.1, §10d.4, §10d.6, §10d.7, plus pre-deliverable §10d.0 / §10d.0.1 and post-deliverable §10d.8) intentionally mirror the design-deliverable identifiers from `specs/SPEC-018-v0_2-design-synthesis.md`. The non-sequential numbering is intentional. Reader convenience: §10d.1 = Multi-turn provider acceptance; §10d.4 = Streaming; §10d.6 = tool_call_id validation; §10d.7 = byte cap."

**6. Architect m-1 (cosmetic) — §3.8 doc-order note.**

Add a one-line note at §3.8 (`specs/SPEC-018-agentic-tool-calling.md:220-221`): "Editorial note: §3.8 (v0.2 additive) physically precedes §3.7 (locked v0.1.5 'Adding a new family') in document order. This is intentional to avoid moving locked v0.1.5 content. Logical reading order is §3.7 first (family-table additions), then §3.8 (prompt-template profile for multi-turn render direction)."

**7. Security m-1 — `invalid_tools` table inheritance note.**

Add a sentence to §10d.0 (after the stable code table): "The code `invalid_tools` used in §5 and §10d.1 for malformed assistant `tool_calls[]` request-shape failures is INHERITED from pre-existing SPEC-001 / SPEC-002 request validation. It remains stable but is not enumerated in the v0.2.X-specific code table above to avoid duplicating cross-SPEC ownership."

## Version bump + change-log

- Header `**Version:**` → `0.2.2 (2026-06-27, r2 absorption — AC-46 unknown-hash semantics + prompt_echo_blocked code domain + 5 mechanical edits)`.
- Status: `Draft`.
- Add v0.2.2 change-log entry at top, before v0.2.1.
- Buyer-visible delta bullets (read this if skimming): AC-46 `null` sentinel for unknown hash; `prompt_echo_blocked` is internal-only fallback (not buyer-visible code); 5 new aggregate-cap ACs (AC-50 through AC-55).

## Additional output

Write `specs/SPEC-018-v0_2_2-DRAFT-NOTES.md` listing each absorption with: finding ID, what changed, location, any loose interpretation.

## Constraints

- Do NOT alter locked v0.1.5 content.
- Do NOT alter v0.2.1 content unless explicitly directed (item 1 updates AC-46 + §10d.0.1; item 2 updates §10d.0 + §3.9 + §10d.1; item 3 updates one citation; items 5/6/7 are additive notes).
- AC-50 through AC-55 are additive ACs; do NOT renumber existing AC-1 through AC-49.
- Money-path settlement protection MUST be preserved.

## What this produces

A v0.2.2 draft ready for round-3 4-lane audit. Expected r3 outcome: 0/0/0 across all 4 lanes given the small, mechanical absorption scope. If r3 returns clean, proceed to Claude blind-spot pass; if not, r4 (unlikely).
