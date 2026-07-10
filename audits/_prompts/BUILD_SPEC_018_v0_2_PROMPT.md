# BUILD_SPEC_018_v0_2_PROMPT — Draft SPEC-018 v0.2 from the design synthesis

## Your task

Draft **SPEC-018 v0.2.0** as an incremental version bump on locked SPEC-018 v0.1.5. Edit `specs/SPEC-018-agentic-tool-calling.md` in place. Preserve all v0.1.5 content (it is LOCKED). Add v0.2 content in:

- A new top-of-file change-log entry for v0.2.0.
- A new §10d **"v0.2 deliverables"** section sitting between v0.1.5's §10c (forward-compat) and §11.
- Updates to ACs (add AC-25 through AC-45 per the synthesis table).
- §8.4 split (incremental-open + final-close validators) — extend, do not replace.
- §3.x family-renderer section (new sub-section) — addition, not rewrite.

You MUST NOT alter the locked v0.1.5 normative claims. You MUST NOT renumber existing ACs. v0.1.5 is sealed.

## Context

You are codex, advising on SPEC-018 v0.2 design after a 4-deliverable scope-narrowing decision. The product framing:

- v0.1.5 LOCKED = "first-turn OpenAI tool-call wire-shape compatibility certificate"
- **v0.2.0 = "Cline drop-in works"** — Cline (https://github.com/cline/cline) is the v0.2 release-gate framework
- v0.3+ = governance + defense-in-depth (model-hash registry, prompt-echo guard, structured malformed signal) — designed but deferred

The narrow scope is intentional. Earlier 7-deliverable v0.2 design was too broad for Ring 1 evidence. v0.3 deliverable design files are preserved at `specs/v0_3-design/` for reference but MUST NOT be referenced in v0.2 SPEC body except as "v0.3 candidate" forward-pointers.

## Authoritative input — read these first

1. **`specs/SPEC-018-agentic-tool-calling.md`** — the locked v0.1.5 SPEC you are extending. Do NOT modify v0.1.5 content; ADD v0.2 content alongside it.
2. **`specs/SPEC-018-v0_2-design-synthesis.md`** — the design synthesis you must encode normatively. This is your decision source. When in doubt, prefer the synthesis.
3. **`specs/DESIGN_SPEC_018_v0_2_01_MULTI_TURN.md`** — codex Deliverable #1 design pass (your prior pass).
4. **`specs/DESIGN_SPEC_018_v0_2_04_STREAMING.md`** — codex Deliverable #4 design pass.
5. **`specs/DESIGN_SPEC_018_v0_2_06_TOOL_CALL_ID.md`** — codex Deliverable #6 design pass (includes normative rules already in-place).
6. **`specs/DESIGN_SPEC_018_v0_2_07_ARGS_BYTE_CAP.md`** — codex Deliverable #7 design pass.

You will NOT use `specs/v0_3-design/` content in v0.2 except as "v0.3 candidate" forward-pointers in a §10d "out of v0.2 scope" note.

## The 4 deliverables to encode normatively

### Deliverable #1 — Multi-turn provider acceptance (closes AC-14)

**Posture:** stateless OpenAI-replay-compatible. Buyer replays full `messages[]` each turn. Provider validates in-request tool-call chain. No session-scoped state.

**Required SPEC content:**
- **§10d.1 normative paragraph**: provider MUST accept `role:"tool"` messages with valid `content` + `tool_call_id`. Provider MUST accept assistant-history `tool_calls[]` and render them into the model's native chat template (option b from synthesis §3).
- **Family-renderer separation**: parser-family registry (v0.1.5 §3.1) handles OUTPUT parse direction. v0.2 adds a **tool prompt-template profile** (new §3.7) for the INPUT render direction, keyed by family using modelID-match in v0.2 (same rule as §3.2). v0.3 will move profile keys to verified `model_hash`.
- **Tool-result content size cap**: 256 KiB UTF-8 per individual `role:"tool"` message `content`. Failure: HTTP 413 `tool_result_too_large`, OpenAI-style error envelope, `param: "messages[i].content"`. Reject whole request — MUST NOT truncate.
- **Assistant-history `function.arguments` cap**: aligned to deliverable #7's 1 MiB (same domain). Failure: HTTP 413 `tool_call_arguments_too_large`.
- **Request-side failure mode table** (lift verbatim from synthesis §3 "Failure mode table"). 9 rows. HTTP codes specified.
- **Receipt canonicalization**: no schema change. `PromptCanonicalizer.swift:5` already canonicalizes `tool_call_id` and `tool_calls`. Specify regression-test obligation: multi-turn `prompt_hash` MUST change when `tool_call_id` or assistant-history `tool_calls[]` changes (IMPL test obligation).
- **AC-14 transition**: explicitly note AC-14 changes from "error path" to "success path" for v0.2; this is forward-compat additive per §10c.

### Deliverable #4 — Token-incremental streaming promotion

**Posture:** streaming-default for Cline-targeted compatible models. Operator kill switch forces buffered-to-end. Per-provider downgrade on malformed streams.

**Required SPEC content:**
- **§10d.4 normative paragraph**: provider streams `function.arguments` incrementally per OpenAI wire format (`tool_calls[].index` keyed accumulator; first delta carries `id`/`type`/`function.name`; subsequent deltas carry `function.arguments` fragments).
- **Byte-equivalence invariant**: streaming concatenation MUST equal non-streaming canonical output byte-for-byte. Single canonical output builder for both modes. Chunk boundaries are transport-only and MUST NOT affect final accumulated `function.arguments`.
- **§8.4 v0.2 split** (extend §8.4, do not replace v0.1.5 content):
  - **§8.4.1 incremental-open validator** (NEW) — runs before emitting ANY `tool_calls[]` chunk. Checks: verified model family, non-empty declared `function.name`, stable `index`, minted `id`, `type:"function"`, first argument fragment is a JSON-string fragment.
  - **§8.4.2 final-close validator** (NEW) — runs at end-of-stream. Checks: concatenated `arguments` parses as JSON object, depth ≤ 32, per-call bytes ≤ 1 MiB, per-response bytes ≤ 2 MiB.
  - **§8.4.3 no withdrawal** (NEW) — once any `tool_calls[]` delta is emitted, provider MUST NOT fall back to plain content. If final-close validator fails after emission, terminate stream with structured error frame (OpenAI-style `error` object on terminating SSE event, followed by `data: [DONE]`).
- **Money-path commit split**: buyer-visible streaming commit happens on incremental-open. **Money-path settlement commit** happens only on final-close. Mid-stream cap-cross or final-close failure → `FaultBreakerQualifying` + zero provider-positive credits via existing `billing_recorder.go:176` + `formula.go:112` paths (unchanged).
- **Coordinator pass-through (streaming side)**: add streaming-side analogue to v0.1.5 AC-24 — provider SSE bytes containing split `tool_calls[].function.arguments` MUST reach buyer byte-identical for both `forwardWSStreaming` (`server.go:2119`) and `forwardStreaming` (`server.go:2279`). Note: current `:2674` validator INCOMPATIBLE with OpenAI incremental fragments; v0.2 splits per §8.4.1/§8.4.2.
- **AC-23s**: streaming forward-compat regression — extends v0.1.5 AC-23 with streaming variant. Pin `openai==2.44.0` baseline. Mock `/v1/chat/completions`. Same request returns non-streaming response + streaming SSE response splitting same `arguments` string. Accumulate streaming with pinned reader. Assert byte-equivalence.
- **Operator kill switch**: MUST be available; disables streaming (forces buffered-to-end). Per-provider downgrade triggered automatically on malformed incremental streams. Configurability NOT exposed on public wire.

### Deliverable #6 — Multi-turn `tool_call_id` validation rule

**Posture:** format-only stateless. Provider-emitted IDs preserve v0.1.5 `^call_[a-f0-9]{32}$`. Request-accepted IDs broader `^call_[A-Za-z0-9]{16,64}$`.

**Required SPEC content** (lift verbatim from `specs/DESIGN_SPEC_018_v0_2_06_TOOL_CALL_ID.md` which is already SPEC-shaped):
- **§10d.6 normative**: format-only stateless validation; two distinct regex domains (provider-emitted vs request-accepted).
- **§10d.6 cross-message consistency**: 7 rules from synthesis §4. Pass + fail cases as code examples.
- **§10d.6 failure response shape**: HTTP 400 + `type: "invalid_request_error"`. 4 normative codes: `invalid_tool_call_id`, `tool_call_id_not_found`, `duplicate_tool_call_id`, `tool_call_result_out_of_order`. NOT fault-breaker-qualifying. No credits. No receipt.
- **Cross-session reuse acceptance**: explicit MUST. Cline conversation resume across fresh provider process / fresh WS connection. Release-gating.
- **Buyer-fabricated ID acceptance**: explicit MUST (if format-valid + request-internally consistent). No money-path implication; buyer pays for inference.

### Deliverable #7 — Per-call `function.arguments` byte cap

**Posture:** raise v0.1.5 256 KiB cap to 1 MiB per-call + 2 MiB per-response. Identical at parser + coordinator. UTF-8 byte length of unescaped final argument string. Inclusive comparison.

**Required SPEC content** (most already SPEC-shaped in `specs/DESIGN_SPEC_018_v0_2_07_ARGS_BYTE_CAP.md`):
- **§10d.7 normative**: constants table (1_048_576 / 2_097_152 / depth 32 unchanged); byte-length domain (UTF-8 unescaped final string); inclusive boundary.
- **Parser ↔ coordinator alignment**: identical constants and identical byte-counting function. Stricter on either side is non-compliant.
- **Multi-call**: BOTH limits enforced. Per-call ≤ 1 MiB. Sum ≤ 2 MiB. Per-call failure: `byte_cap_exceeded`. Aggregate: `response_byte_cap_exceeded`.
- **Streaming incremental enforcement**: per-call + per-response accumulators decoded incrementally. Cap-cross chunk MUST NOT be forwarded. Settlement final only at end-of-stream after all closes pass.
- **Configurability**: NONE on public wire in v0.2. Operator MAY run private experiments; advertising v0.2 compliance requires identical values.
- **§10c forward-compat**: future v0.2.x MAY raise caps; MUST NOT lower; MUST NOT change inclusive boundary or byte-counting domain.

## SPEC structure changes

### Header

Update `**Version:**` line: `0.2.0 (2026-06-27, narrow Cline-drop-in v0.2 — closes AC-14 multi-turn; adds streaming; raises arg cap to 1 MiB)`.

Update `**Depends on:**` line: keep all v0.1.5 deps; no new dep (model-hash registry deferred to v0.3, so SPEC-008/SPEC-011 dependency remains "referenced" not "binding").

Update `**Status:**` line: `Draft — extends locked v0.1.5; pending v0.2.0 IMPL absorption; codex 4-lane audit + Claude blind-spot pass per [[feedback-three-lane-codex-audits]] convention.`

### New top-of-file change-log entry

Lead with one paragraph summarizing v0.2.0 product narrative. Then **buyer-visible deltas** bullet list (read this if skimming). Then full change-log entry per the v0.1.5 precedent — list every normative change concretely with citations to code locations.

Specifically call out:
- AC-14 success-path transition
- §8.4 split (incremental-open + final-close)
- Byte cap raise (256 KiB → 1 MiB per-call + 2 MiB per-response)
- Streaming-default + operator kill switch + per-provider auto-downgrade
- Cross-message tool_call_id consistency rules
- v0.3 deferred items pinned

### New §3.7 — Tool prompt-template profile (multi-turn input rendering)

New section. Family-keyed (v0.2 modelID-match per §3.2; v0.3 will move to verified model_hash). Renders OpenAI `messages[]` (including assistant-history `tool_calls[]` and `role:"tool"` results) into the model's native chat-template markup. Separate from parser-family registry (§3.1) which handles output parse direction.

### Extension to §8.4 (do not replace)

Add §8.4.1 (incremental-open validator), §8.4.2 (final-close validator), §8.4.3 (no-withdrawal rule). Existing §8.4 v0.1.5 content describes the non-streaming + buffered-streaming validator behavior; v0.2 splits it for incremental streaming.

### New §10d — v0.2 deliverables (between §10c and §11)

Four sub-sections, one per deliverable. Each lifts from the design synthesis verbatim where possible.

### AC additions (AC-25 through AC-45)

21 new ACs. Each tied to a deliverable. Each with concrete pass/fail behavior. Numbering MUST NOT collide with v0.1.5 (last used AC-24).

Use the synthesis §9 AC numbering table as the canonical mapping. Each AC needs:
- Deliverable tag (#1/#4/#6/#7)
- Concrete pass condition
- Concrete fail condition (where applicable)
- Test fixture description (where applicable)

### v0.3 deferred forward-pointer

At end of §10d, add a paragraph naming the v0.3 deliverables (#2 registry, #3 echo guard, #5 malformed signal) with one-line description each. Cite `specs/v0_3-design/0N-*.md` files. Note that the failure reasons used internally in v0.2 (§8.4 split, §10d.4 streaming termination, §10d.7 caps) map to v0.3's structured `usage.macprovider_malformed_tool_call.reason` enum but v0.2 does not yet expose the structured signal — internal logs only.

## Constraints

- **DO NOT modify v0.1.5 content.** All v0.1.5 sections, ACs (AC-1 through AC-24), and forward-compat invariants are LOCKED.
- **DO NOT introduce content from v0.3 deferred deliverables.** No `usage.macprovider_malformed_tool_call` schema. No model-hash registry. No prompt-echo guard. Only forward-pointers naming these as v0.3.
- **DO NOT change SPEC-008 or SPEC-011 status.** They are referenced in v0.1.5; no new binding dependency in v0.2.
- **DO preserve §10c forward-compat invariant.** v0.2 MUST be additive on top of v0.1.3 wire shape. AC-23 (and AC-23s extension) verify this mechanically.
- **DO preserve money-path settlement protection.** All v0.2 changes go through existing `billing_recorder.go:176` + `formula.go:112` + `FaultBreakerQualifying` flag.

## Output

A single rewritten `specs/SPEC-018-agentic-tool-calling.md` file at v0.2.0, with:
- All v0.1.5 content preserved verbatim (do not edit existing prose)
- New v0.2 change-log entry at top
- New §3.7 tool prompt-template profile section
- Extended §8.4 with sub-sections .1/.2/.3
- New §10d v0.2 deliverables section (between §10c and §11)
- AC-25 through AC-45 added to AC list
- Status / Version / Change-log header updated

When done, additionally write `specs/SPEC-018-v0_2_0-DRAFT-NOTES.md` listing every editorial decision you made (e.g., "I placed §10d.4 streaming after §10d.1 multi-turn because…"), every place you had to interpret the synthesis loosely, and every concrete code location citation you encoded. This is for the audit-loop reviewers.

## What this produces

A v0.2.0 draft ready for codex 4-lane audit (architect / code / security / product-design) per [[feedback-three-lane-codex-audits]]. Audit loops until 0/0/0. Then Claude blind-spot pass (critic + narrative analyst) per the v0.1.5 precedent which caught 3 lock-blocking HIGH issues codex's 4 lanes missed. Then lock + open SPEC PR (alone, not bundled — v0.2 is scope expansion).

The IMPL prompt is the next step after SPEC lock.
