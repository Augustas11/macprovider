# SPEC-018 v0.1 — Product-design-lane round-1 audit

## Counts
CRITICAL: <n>
HIGH: <n>
MEDIUM: <n>
MINOR: <n>
QUESTIONS: <n>

## Findings
### C-1 / H-1 / M-1 / m-1 / Q-1 — Title
- User impact: who hits this, when, what they see
- SPEC location: §N or AC-N
- Current SPEC framing:
- Reality from anchor example:
- Recommended fix to SPEC body (specific edits):

## Verdict
[READY TO LOCK | FIX REQUIRED]

## Anchor-example walk-through
A user opens Cline. Configures the buyer URL. Issues "refactor this file."
Walk through the first 3 turns of that session against SPEC-018 v0.1 as written.
At which step does it work? At which step does it break or surprise the user?
Conclude with a 2-3 sentence honest assessment of whether v0.1 delivers Ring-1.
```

Lock bar: **0 CRITICAL + 0 HIGH + 0 MEDIUM**. MINORs + QUESTIONS deferrable.

Stay in product-design lane. Code-citation accuracy + security attack surface + architectural altitude all belong to other lanes. Your job: does the user get the product the SPEC promises?

## Final prompt

# SPEC-018 v0.1 — PRODUCT-DESIGN-lane audit

You are the **product-design** lane of a four-lane audit (architect / code / security / product-design) of `specs/SPEC-018-agentic-tool-calling.md` v0.1. Stay narrowly in your lane.

The product-design lens cares about: anchor-example fidelity (does the user's actual workflow work end-to-end against the SPEC as written?), where buyer expectation diverges from SPEC reality, scope-creep risk in §10, overclaim/underclaim language, the "user can grok this from §1" test.

## Scope under audit
- Branch: `spec/018-agentic-tool-calling`
- Worktree: `/Users/augstar/macprovider-spec-018-tool-calling`
- File: `specs/SPEC-018-agentic-tool-calling.md` v0.1 (commit `77c0ec5`)
- This is a **post-hoc ratification SPEC** of cf2f135 + c823a96 + 7b8b1be. Product-design lane: does the ratified surface actually deliver the Ring-1 product, or does it ship a half-product wearing the Ring-1 label?

## The anchor example you're auditing against

A developer (your representative user) opens Cline (or Cursor, Aider, Claude Code, Continue, Zed, OpenCode — any OpenAI-shape agent framework). They configure:

```bash
export OPENAI_BASE_URL=https://api.streamvc.live/v1
export OPENAI_API_KEY=<buyer-token>
```

They pick model `qwen3-coder` (or similar). They tell the agent: "refactor this file, run the tests, commit the result."

The agent runs N turns: read file → suggest edit → apply edit → run test → read failure → suggest next edit → ... The agent loop runs on the user's laptop. The model runs on an M-series Mac on the macprovider network. macprovider is the inference marketplace + transport.

**Your audit question: does SPEC-018 v0.1, as written, deliver THIS workflow?**

## Product-design-lane scope (apply each; stay in lane)

### PD-1. Multi-turn limitation vs. agent-loop reality
§6 + AC-14 + AC-16's footnote ratify that the current phase3 provider **rejects** multi-turn tool-result messages with `unsupported_tool_messages`. A second turn (after the agent executes the tool and tries to send the result back) fails at the provider boundary.

**This is the load-bearing question for the anchor example.** An agent loop is, by definition, multi-turn: assistant emits tool_call → user (framework) executes → user sends `role: "tool"` message with result → assistant emits next tool_call. The current provider fails on step 3.

- Does the SPEC's Ring-1 product framing in §1 ("drop-in OpenAI tool-calling wire for client-side agent frameworks") survive AC-14? Or does §1 overclaim a working product when the as-built only delivers turn 1?
- Cline/Cursor/Aider users would discover this on the second tool call of EVERY session. Is the SPEC honestly representing a "first-turn-only" product as Ring-1 complete?
- If the SPEC v0.1 is "first-turn-only", should §1 say so explicitly ("v0.1 enables single-turn tool-call responses; full agent loops require v0.2 per AC-14's promotion") OR should v0.1 not lock until the provider supports multi-turn?
- Is the right product-design move to:
  - (a) ratify v0.1 as-is, ship the multi-turn fix in v0.2 fast,
  - (b) hold v0.1 until multi-turn lands,
  - (c) re-scope v0.1 to a strict "tool-call wire-shape compatibility certificate" without claiming Ring-1 product delivery?

Take a position. This is the most important finding the product-design lane can make.

### PD-2. Buffered-to-end streaming vs. agent UX
§4 ratifies buffered-to-end streaming for tool calls. A Cline user watching their agent work expects to see *streaming* progress (the tool-call indicator appears, the arguments stream in, the call fires). Buffered-to-end means the user sees a long pause, then a complete tool call.

- For the AI-coding workflow, is buffered-to-end a noticeable UX regression vs. OpenAI / Anthropic APIs (which stream tool-call deltas)? Frame the actual user impact.
- Q1 reserves the promotion to v0.2. Is "v0.2 will fix it" credible product positioning, or a vapor promise without a concrete v0.2 timeline in §10?
- Does the SPEC need a "what users will observe" sub-section in §1 (or §4) calling out this difference vs. OpenAI baseline?

### PD-3. Anchor example coverage — does AC-16 actually verify the product?
AC-16: "An OpenAI Python SDK 1.x client pointed at the buyer URL can parse the first assistant tool-call response for the canonical `get_weather`-style loop without response adapters. SPEC-018 v0.1 does not certify the second provider turn after tool execution because AC-14 ratifies the current provider limitation."

- Is "first turn only" verification adequate? In real agent frameworks, the second turn is where most failures happen (history shape, tool_call_id echo, tool result formatting).
- AC-16 picks a `get_weather`-style demo. Real users run Cline against real code. Should AC-16 (or a new AC) require an end-to-end test against an actual agent framework (Cline / Aider) rather than a hand-rolled OpenAI SDK call?
- §1 promises drop-in compatibility with named frameworks: Cline, Cursor, Aider, Claude Code, Continue, Zed, OpenCode, Vercel AI SDK, LangChain, LlamaIndex, Pydantic-AI, n8n. AC-16 only covers raw OpenAI SDK. Does the SPEC need ≥1 AC per major framework, or is the wire-shape AC sufficient (i.e. "if wire matches OpenAI, all frameworks work by transitivity")?

### PD-4. Model family table — Qwen3-Coder mention
§1 names `qwen3-coder` in the framing. §3 lists Qwen2.5 / Qwen3 native and Qwen coding-tuned. Verify these match the actual model the user would pick.

- If the network actually serves `qwen3-coder-30b` (or similar specific SKU), is the SPEC vague about which exact model SKUs are tool-call-capable in v0.1?
- For an AI-coding-tool user, "which model do I pick" is the load-bearing question. Does §3 give them an answer, or does it require code-reading?
- Should §1 (or a new sub-section) include an explicit "model SKU compatibility table" naming which model IDs the SPEC commits to supporting at v0.1?

### PD-5. Open Questions risk — what gets through to v0.1 users
Of the 9 open questions, which ones will users hit FIRST?
- Q1 (buffered streaming) — every session
- Q3 (multi-turn) — every multi-turn session (i.e., every real session)
- Q6 (content-sentinel detection) — security issue, but invisible to most users
- Q5 (warm-swap mid-tool-call) — rare but data-loss-class

Should §1 or the change log have a "Known v0.1 limitations" callout that names the user-visible items (Q1, Q3) so a SPEC reader knows what they're buying?

### PD-6. The "name a v0.2 release date" question
§10 reserves a long list for v0.2+ (structured output, streaming-incremental, prefix-cache, SDKs, max_tool_calls, malformed_tool_call promotion, second-turn).

If v0.2 is unbounded, §10 is a wishlist. Is there a forcing function — a customer commitment, a public deployment milestone — that anchors v0.2? If not, does the SPEC need an explicit v0.2 roadmap section calling out at least the gating items (multi-turn, streaming)?

### PD-7. §1 product framing — does it match the as-built?
§1 reads: "A buyer MAY point an OpenAI-shaped client at the buyer-side gateway and receive assistant tool-call responses that the client can parse without macprovider-specific response adapters."

Word-by-word audit:
- "receive assistant tool-call responses" — yes, first turn only.
- "without macprovider-specific response adapters" — yes, the wire shape is OpenAI.
- "client" — singular response. The framing avoids saying "agent loop." Is this honest hedging, or is the SPEC framing itself a quiet acknowledgment that Ring-1 v0.1 doesn't actually do the full agent loop?

If the framing is hedged, should §1 be even more explicit ("v0.1 enables agent frameworks to receive their first tool call from a macprovider provider; full multi-turn agent loops are a v0.2 deliverable") so the SPEC doesn't have to be parsed line-by-line for users to understand they're getting a 50% product?

### PD-8. Cross-comparison with industry baseline
Users will compare macprovider to OpenAI, Anthropic, Together, Fireworks, Bedrock for tool-call workloads.

- OpenAI: full multi-turn, token-incremental streaming, native `response_format: json_schema`, parallel tool calls (multiple in one response).
- Anthropic: similar parity, plus computer-use tool, prompt caching.
- Together / Fireworks: model-family-specific support, varies.

What does macprovider v0.1 deliver vs. these baselines?
- ✅ wire-shape parity (first turn)
- ❌ multi-turn
- ❌ token-incremental streaming
- ❌ response_format json_schema
- ❌ prompt caching
- ✅ "your own M4" cost story
- ✅ P2P-marketplace differentiation

Is this an honest competitive position to ratify as "Ring-1 complete," or is the SPEC mislabeling a v0 product as Ring-1?

### PD-9. Scope creep watch in §10
§10's wishlist includes "Promotion of response parse failures from plain-content fallback to a structured `malformed_tool_call` error" and "Full provider-side acceptance of second-turn tool-result request messages."

These are user-visible behaviors that the user-facing product needs. Bundling them in §10 alongside "Python and TypeScript SDK wrappers" (which is convenience) suggests the SPEC treats critical and nice-to-have as equivalent v0.2 items.

Recommend §10 be split into:
- §10a — "Required for full Ring-1 product" (multi-turn, token-incremental streaming, malformed_tool_call promotion)
- §10b — "Reserved for future enhancement" (structured output, prefix-cache, SDKs, max_tool_calls cap)

Does this re-organization help users + roadmap, or is it premature?

### PD-10. The "user-visible upgrade contract"
When v0.2 ships, will an existing v0.1 user's agent framework code keep working? §2 + §3 + §4 are normative; §6 is a partial ratification. Is the SPEC clear that v0.2 changes (e.g. enabling multi-turn) are PURELY additive — i.e. a v0.1 user is not broken by v0.2?

If the answer is yes: state it explicitly as an invariant. If unclear: this is a product-stability question that should be resolved before v0.1 locks.

## Output format

Return a single audit report:

```
# SPEC-018 v0.1 — Product-design-lane round-1 audit

## Counts
CRITICAL: <n>
HIGH: <n>
MEDIUM: <n>
MINOR: <n>
QUESTIONS: <n>

## Findings
### C-1 / H-1 / M-1 / m-1 / Q-1 — Title
- User impact: who hits this, when, what they see
- SPEC location: §N or AC-N
- Current SPEC framing:
- Reality from anchor example:
- Recommended fix to SPEC body (specific edits):

## Verdict
[READY TO LOCK | FIX REQUIRED]

## Anchor-example walk-through
A user opens Cline. Configures the buyer URL. Issues "refactor this file."
Walk through the first 3 turns of that session against SPEC-018 v0.1 as written.
At which step does it work? At which step does it break or surprise the user?
Conclude with a 2-3 sentence honest assessment of whether v0.1 delivers Ring-1.
```

Lock bar: **0 CRITICAL + 0 HIGH + 0 MEDIUM**. MINORs + QUESTIONS deferrable.

Stay in product-design lane. Code-citation accuracy + security attack surface + architectural altitude all belong to other lanes. Your job: does the user get the product the SPEC promises?

## Raw output

```text
# SPEC-018 v0.1 — Product-design-lane round-1 audit

## Counts
CRITICAL: 1  
HIGH: 2  
MEDIUM: 3  
MINOR: 0  
QUESTIONS: 1  

## Findings

### C-1 — Ring-1/drop-in framing does not survive the second turn
- User impact: Cline/Cursor/Aider-style users hit this in every real agent session, immediately after the first tool executes. They see the model produce a tool call, the client executes it, then the next provider request fails with `unsupported_tool_messages`.
- SPEC location: §1, §6, AC-14, AC-16, §10.
- Current SPEC framing: §1 says v0.1 is “Ring 1” and “drop-in OpenAI `tool_calls` response wire shape for client-side agent frameworks.”
- Reality from anchor example: v0.1 delivers first assistant tool-call response compatibility only. It does not deliver a working client-side agent loop because the provider rejects `role: "tool"` and assistant-history `tool_calls[]` on the second provider turn.
- Recommended fix to SPEC body: do not lock v0.1 as Ring-1 product delivery as written. Product-design position: choose **(c)** re-scope v0.1 to a strict “first-turn OpenAI tool-call wire-shape compatibility certificate.” If Ring-1 means the anchor agent loop works, choose **(b)** and hold v0.1 until multi-turn lands. Add to §1: “SPEC-018 v0.1 enables single-turn assistant tool-call responses. It does not certify full multi-turn client-side agent loops; second-turn tool-result messages are rejected by the current provider and are required for full Ring-1 product delivery.”

### H-1 — AC-16 verifies a demo surface, not the product workflow
- User impact: a raw OpenAI Python SDK parse smoke test can pass while Cline/Aider fail on the next request. This gives a buyer false confidence.
- SPEC location: AC-16, AC-14, §1.
- Current SPEC framing: AC-16 certifies only first assistant response parsing for a `get_weather`-style loop and explicitly excludes the second turn.
- Reality from anchor example: the second turn is where agent frameworks prove compatibility: `tool_call_id` echo, history shape, tool-result formatting, and next tool-call generation.
- Recommended fix to SPEC body: either rename AC-16 to “first-turn wire-shape smoke test” or add a required AC for a real framework: configure at least one of Cline/Aider/OpenCode/Continue against `OPENAI_BASE_URL=https://api.streamvc.live/v1`, run a two-tool-turn coding workflow, and require no response adapters. If v0.1 remains first-turn-only, §1 must not imply framework-level drop-in operation.

### H-2 — §10 mixes Ring-1 blockers with nice-to-have future work
- User impact: buyers cannot tell whether multi-turn and streaming are imminent product blockers or just wishlist items beside SDK wrappers and prefix cache.
- SPEC location: §10, Q1, Q3, Q8.
- Current SPEC framing: “Reserved for v0.2+” puts second-turn provider acceptance, token-incremental streaming, `malformed_tool_call`, SDK wrappers, structured output, prefix cache, and caps in one bucket.
- Reality from anchor example: multi-turn is required for the product to function; SDK wrappers are convenience.
- Recommended fix to SPEC body: split §10 into “Required for full Ring-1 product” and “Future enhancements.” Required: second-turn tool-result acceptance, token-incremental or honestly degraded streaming semantics, and structured `malformed_tool_call` behavior. Enhancements: SDK wrappers, prefix cache, structured output, `max_tool_calls`.

### M-1 — Buffered-to-end streaming is a visible agent UX regression
- User impact: in streaming mode, users see a pause until generation completes, then the full tool call appears at once. Compared with OpenAI/Anthropic-style tool-call deltas, the agent feels stalled and less debuggable.
- SPEC location: §4, AC-8, AC-9, Q1.
- Current SPEC framing: §4 accurately says tool-call streaming is buffered-to-end, but this is buried in wire semantics.
- Reality from anchor example: coding-agent users expect live progress indicators and arguments streaming before the tool fires.
- Recommended fix to SPEC body: add a §1 or §4 “What users observe in v0.1” callout: “For tool-enabled streaming requests, macprovider does not stream tool-call arguments incrementally; clients receive the complete tool call only after provider generation finishes.”

### M-2 — Model SKU guidance is not buyer-actionable
- User impact: the user’s first practical question is “which model ID do I select?” §3 describes grammar families, not committed v0.1 SKUs.
- SPEC location: §3, AC-18.
- Current SPEC framing: §3 says Qwen2.5/Qwen3 native and Qwen coding-tuned grammars; AC-18 says “Qwen3-Coder-class.”
- Reality from repo evidence: local references include concrete IDs such as `mlx-community/Qwen3-32B-4bit`, `mlx-community/Qwen2.5-Coder-32B-Instruct-4bit`, and `mlx-community/Qwen2.5-Coder-7B-Instruct-4bit`; the SPEC does not name an exact v0.1 buyer-facing `qwen3-coder` SKU.
- Recommended fix to SPEC body: add a model compatibility table: buyer model ID, provider/HF model ID, grammar family, tool-call support status, gateway e2e status, and minimum hardware class. AC-18 should name the exact SKU tested.

### M-3 — Known v0.1 limitations are discoverable only after careful reading
- User impact: readers can miss the two user-visible limitations they will hit first: no second tool-result turn and buffered streaming.
- SPEC location: §1, §10, §11.
- Current SPEC framing: limitations are present, but distributed across §4, §6, AC-14, AC-16, and open questions.
- Reality from anchor example: these are not edge cases; Q1 and Q3 are ordinary-session behavior.
- Recommended fix to SPEC body: add “Known v0.1 limitations” near the top, naming: first-turn-only tool-call compatibility, no provider acceptance of `role:"tool"` results, buffered-to-end tool-call streaming, no structured `malformed_tool_call`.

### Q-1 — Is v0.2 explicitly additive for existing v0.1 clients?
- User impact: buyers need to know whether adopting v0.1 wire shape creates migration risk when multi-turn support ships.
- SPEC location: §2, §3, §4, §6, §10.
- Current SPEC framing: v0.2 changes appear likely additive, but no product invariant says so.
- Reality from anchor example: enabling `role:"tool"` acceptance should not break first-turn users, but streaming promotion could affect clients that assume the current single-fragment delta behavior.
- Recommended fix to SPEC body: add an invariant: “Future SPEC-018 versions that add multi-turn support MUST preserve v0.1 non-streaming response shape. Streaming improvements MAY add incremental deltas but MUST preserve OpenAI-compatible delta concatenation semantics.”

## Verdict
FIX REQUIRED

